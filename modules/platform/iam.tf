# Policies are built with jsonencode rather than aws_iam_policy_document.
#
# The data source's rendered .json is a computed attribute, which mock_provider
# replaces with an invented string. That both breaks plan-time validation and
# makes any assertion about policy content a test of the mock rather than of this
# module. jsonencode evaluates locally, so the tests read what actually ships.
# Nothing here needs the data source's merge or override features.

resource "aws_iam_role" "appliance" {
  name = "${var.name_prefix}-appliance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

# SSM Session Manager is the entire access path (D6). Without this the appliance
# is unreachable: there is no public ingress, no bastion, and no SSH key.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each = toset(["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"])

  role       = aws_iam_role.appliance.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "appliance" {
  name = "${var.name_prefix}-appliance"
  role = aws_iam_role.appliance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken cannot be resource-scoped.
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [for r in aws_ecr_repository.mirror : r.arn]
      },
      {
        # Decrypt the data volume and the application secrets.
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
        Resource = aws_kms_key.main.arn
      },
      {
        # Read mirrored tooling binaries (Docker Compose; Phase 3 plaso tooling).
        Sid      = "ToolingRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.tooling.arn}/*"
      },
      {
        # Read the generated secrets written by the analysis layer.
        Sid      = "SecretsRead"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:*:*:secret:${var.name_prefix}/*"
      },
      {
        # Read the image digest manifest published by the mirror pipeline (spec 4.5).
        Sid      = "SsmReadImageDigests"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:*:*:parameter/${var.name_prefix}/images/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "appliance" {
  name = "${var.name_prefix}-appliance"
  role = aws_iam_role.appliance.name
  tags = local.common_tags
}

# --- Phase 2: evidence store principals ---

# Break glass (spec 5.2).
#
# GOVERNANCE mode differs from COMPLIANCE mode only because some principal can
# bypass it. That principal is this role, and it is created only when someone is
# named to assume it -- a standing bypass role nobody asked for is a standing
# privilege.
#
# Spec 5.2.2: without this, `tofu destroy` fails against any bucket holding
# locked objects, which a development deployment needs.
resource "aws_iam_role" "break_glass" {
  count = length(var.break_glass_principal_arns) > 0 ? 1 : 0

  name = "${var.name_prefix}-break-glass"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = var.break_glass_principal_arns }
    }]
  })

  tags = merge(local.common_tags, {
    Purpose = "operator-error-recovery"
  })
}

resource "aws_iam_role_policy" "break_glass" {
  count = length(var.break_glass_principal_arns) > 0 ? 1 : 0

  name = "${var.name_prefix}-break-glass"
  role = aws_iam_role.break_glass[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BypassGovernanceRetention"
        Effect = "Allow"
        Action = [
          "s3:BypassGovernanceRetention",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:PutObjectLegalHold",
          "s3:PutObjectRetention",
          "s3:GetObjectLegalHold",
          "s3:GetObjectRetention",
        ]
        Resource = [
          "${aws_s3_bucket.evidence.arn}/*",
          "${aws_s3_bucket.plaso.arn}/*",
        ]
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.main.arn
      },
    ]
  })
}

# The responder surface (D12).
#
# Attached by the deployer to whichever principal responders actually use. It is
# deliberately narrow: upload to intake, read and open cases. Everything past
# intake belongs to the recorder, so a compromised responder credential cannot
# read the evidence store or rewrite the manifest.
resource "aws_iam_policy" "responder" {
  name        = "${var.name_prefix}-responder"
  description = "Upload artifacts to intake and open cases. Attach to responder principals."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IntakeUpload"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.intake.arn}/*"
      },
      {
        Sid      = "IntakeListForMultipart"
        Effect   = "Allow"
        Action   = ["s3:ListBucketMultipartUploads"]
        Resource = aws_s3_bucket.intake.arn
      },
      {
        Sid    = "CaseReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
        ]
        Resource = aws_dynamodb_table.cases.arn
      },
      {
        # Read-only: a responder can see what has been recorded but cannot write
        # a custody entry by hand.
        Sid      = "ArtifactRead"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.artifacts.arn
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.main.arn
      },
    ]
  })
}
