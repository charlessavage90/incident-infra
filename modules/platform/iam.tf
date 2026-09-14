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
