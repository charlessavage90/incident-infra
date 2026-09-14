# Bucket-level access auditing (spec 5.1).
#
# S3 server access logging cannot target an Object Lock bucket, and two of the
# three evidence buckets are Object Lock buckets, so object-level auditing is
# CloudTrail data events. The selector also covers the tooling bucket, which
# gives SNYK-CC-TF-45 a real compensating control -- though that rule looks for
# aws_s3_bucket_logging specifically and will keep reporting.

resource "aws_s3_bucket" "audit" {
  bucket = "${var.name_prefix}-audit-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-audit"
    Content = "cloudtrail-data-events"
  })
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  trail_arn = "arn:aws:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/${var.name_prefix}-data-events"
}

# The aws:SourceArn conditions are the confused-deputy guard: without them any
# account's CloudTrail could be pointed at this bucket.
resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.audit.arn
        Condition = {
          StringEquals = { "aws:SourceArn" = local.trail_arn }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.audit.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.trail_arn
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.audit.arn,
          "${aws_s3_bucket.audit.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

resource "aws_cloudtrail" "data_events" {
  name           = "${var.name_prefix}-data-events"
  s3_bucket_name = aws_s3_bucket.audit.id
  kms_key_id     = aws_kms_key.main.arn

  # Management events are not the point here and would multiply cost; this trail
  # exists to record who touched which object.
  include_global_service_events = false
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  advanced_event_selector {
    name = "S3 object access in the evidence store"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    # Scoped to these buckets. Unscoped, this bills for every S3 object event in
    # the account.
    field_selector {
      field = "resources.ARN"
      starts_with = [
        "${aws_s3_bucket.intake.arn}/",
        "${aws_s3_bucket.evidence.arn}/",
        "${aws_s3_bucket.plaso.arn}/",
        "${aws_s3_bucket.tooling.arn}/",
      ]
    }
  }

  # CloudTrail validates it can write to the bucket at creation time.
  depends_on = [aws_s3_bucket_policy.audit]
}
