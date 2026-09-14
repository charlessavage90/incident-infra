resource "aws_iam_role" "mirror" {
  name = "${var.name_prefix}-image-mirror"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "mirror" {
  name = "${var.name_prefix}-image-mirror"
  role = aws_iam_role.mirror.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:log-group:/aws/codebuild/${var.name_prefix}-image-mirror*"
      },
      {
        # Private ECR for pushing; ECR Public for pulling upstream images.
        # ECR Public auth additionally requires sts:GetServiceBearerToken.
        Sid    = "EcrAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr-public:GetAuthorizationToken",
          "sts:GetServiceBearerToken",
        ]
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = "arn:aws:ecr:*:*:repository/${var.name_prefix}/*"
      },
      {
        # Scoped to this deployment's parameters only.
        Sid    = "PublishImageDigests"
        Effect = "Allow"
        Action = "ssm:PutParameter"
        Resource = [
          "arn:aws:ssm:*:*:parameter/${var.name_prefix}/images/*",
          "arn:aws:ssm:*:*:parameter/${var.name_prefix}/tooling/*",
        ]
      },
      {
        Sid      = "MirrorTooling"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.tooling_bucket}/*"
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = var.kms_key_arn
      },
    ]
  })
}
