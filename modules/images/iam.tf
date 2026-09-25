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
        # BatchGetImage and GetDownloadUrlForLayer are for PULLING, not pushing,
        # and the worker build needs them: it is FROM the timesketch image that
        # this same build just pushed to private ECR.
        Sid    = "EcrPushAndPullOwnBase"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = "arn:aws:ecr:*:*:repository/${var.name_prefix}/*"
      },
      {
        # Scoped to this deployment's parameters only.
        #
        # GetParameter is not symmetry: the worker build reads back the
        # timesketch digest this build published moments earlier, which is how
        # the spec 4.5 parity invariant is enforced within one run rather than
        # across two.
        Sid    = "PublishAndReadImageDigests"
        Effect = "Allow"
        Action = ["ssm:PutParameter", "ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:*:*:parameter/${var.name_prefix}/images/*",
          "arn:aws:ssm:*:*:parameter/${var.name_prefix}/tooling/*",
        ]
      },
      {
        # GetObject is for the worker's build context, which OpenTofu stages
        # here because CodeBuild is NO_SOURCE and has nothing to check out.
        Sid      = "MirrorTooling"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "arn:aws:s3:::${var.tooling_bucket}/*"
      },
      {
        # `aws s3 cp --recursive` fetches the worker's build context by listing
        # the prefix first, and ListObjectsV2 is authorised on the BUCKET ARN,
        # not the object ARN above. Without this the build fails at AccessDenied
        # on ListBucket (Phase 3 acceptance, defect 1). Scoped to the context
        # prefix so the role still cannot enumerate the rest of the bucket.
        Sid      = "ListWorkerBuildContext"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.tooling_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = ["${local.worker_source_prefix}/*"] }
        }
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
