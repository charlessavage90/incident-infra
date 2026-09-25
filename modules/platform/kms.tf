# An explicit key policy replaces the default.
#
# The default policy grants the account root, and IAM policies then delegate from
# there. That covers every principal in this account -- but NOT an AWS service
# principal, which is not an account principal. Two of them need naming here:
#
#   - CloudTrail. Without its statement the trail fails at apply with an error
#     that does not name the key.
#   - CloudWatch Logs, which encrypts the intake recorder's log group. Without
#     its statement CreateLogGroup returns AccessDenied naming the log group
#     ARN, and likewise never the key. This one failed the Phase 2 acceptance
#     apply, after the CloudTrail statement had already been written.
#
# The pattern generalises: any CMK-encrypted resource owned by a service, not by
# a principal in this account, needs a statement of its own.
#
# The root statement is not optional. A key policy that omits it cannot be
# edited by anyone, and the key becomes unusable and undeletable except by
# scheduling deletion. Do not "tidy" it away.
locals {
  autoscaling_service_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
}

resource "aws_kms_key" "main" {
  description             = "${var.name_prefix} IR platform key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogsEncrypt"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      },
      {
        Sid       = "AllowCloudTrailEncrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringLike = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"
          }
        }
      },
      # The plaso fleet's root volumes are encrypted with this key, and EC2 Auto
      # Scaling launches them as its service-linked role. That role's
      # permissions are AWS-managed, so the root statement's delegation never
      # reaches it. Without these two statements every Batch instance is
      # terminated before InService with Client.InvalidKMSKey.InvalidState --
      # which names neither the key nor the role (Phase 3 acceptance, defect 5).
      #
      # Principal "*" pinned by aws:PrincipalArn rather than naming the role:
      # KMS rejects a policy naming a principal that does not exist, and this
      # role is only created on an account's first Auto Scaling use. Naming it
      # would fail the first platform apply in a fresh IR account.
      {
        Sid       = "AllowAutoScalingEbsEncrypt"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:PrincipalArn" = local.autoscaling_service_role_arn }
        }
      },
      {
        Sid       = "AllowAutoScalingEbsGrant"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = "kms:CreateGrant"
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:PrincipalArn" = local.autoscaling_service_role_arn }
          Bool         = { "kms:GrantIsForAWSResource" = "true" }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}
