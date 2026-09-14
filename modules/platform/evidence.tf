# The evidence store (spec 5.1).
#
# These buckets live in the permanent platform layer, like the data volume and
# for the same reason: `tofu destroy` against modules/analysis must lose nothing.
#
# Object Lock is enabled at bucket level and NO default retention is configured.
# That omission is load-bearing. A default retention stamps a retain-until date
# at PUT; spec 5.2 requires the clock to start when the case closes, which is
# what the legal-hold-then-retention sequence achieves. If you add a
# `rule { default_retention { ... } }` block below, you have silently converted
# the retention model into "N years from upload" and nothing will tell you.
#
# Bucket names carry the account ID as well as the prefix, because bucket names
# are globally unique -- matching aws_s3_bucket.tooling.
#
# Snyk findings accepted here, left VISIBLE rather than suppressed, following the
# precedent set on the tooling bucket in storage.tf:
#
#   SNYK-CC-TF-45 (no server access logging) x3 -- evidence and plaso are Object
#     Lock buckets, and S3 *cannot* deliver server access logs to one. That is the
#     whole reason spec 5.1 specifies CloudTrail data events, which audit.tf now
#     builds over all three buckets. The rule looks for aws_s3_bucket_logging, so
#     it reports regardless of the control actually being present.
#   SNYK-CC-TF-127 (no MFA delete) x3 -- cannot be set by Terraform at all; it
#     needs root credentials presenting an MFA token via the CLI. On evidence and
#     plaso it is also the weaker control: a legal hold cannot be cleared by
#     presenting a TOTP code, which is the point of Object Lock.
#   SNYK-CC-TF-124 (versioning disabled on intake) -- deliberate, and the comment
#     on that bucket explains it. Versioning intake would retain a delete marker
#     and a noncurrent version of every artifact the recorder files, which is both
#     billed storage and a second copy of evidence outside the locked bucket.

resource "aws_s3_bucket" "evidence" {
  bucket              = "${var.name_prefix}-evidence-${data.aws_caller_identity.current.account_id}"
  object_lock_enabled = true

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-evidence"
    Content = "raw-artifacts"
  })

  # Spec 5.2.1. Compliance mode is the only genuinely irreversible action in
  # this module, so it cannot be reached by editing one variable.
  lifecycle {
    precondition {
      condition     = var.object_lock_mode != "COMPLIANCE" || var.acknowledge_compliance_mode_is_irreversible
      error_message = "object_lock_mode is COMPLIANCE but acknowledge_compliance_mode_is_irreversible is false. Compliance-locked objects cannot be deleted before expiry by anyone, including the account root, and this bucket cannot be destroyed while they exist. Set the acknowledgement only in a production IR account."
    }
  }
}

resource "aws_s3_bucket" "plaso" {
  bucket              = "${var.name_prefix}-plaso-${data.aws_caller_identity.current.account_id}"
  object_lock_enabled = true

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-plaso"
    Content = "derived-timelines"
  })

  lifecycle {
    precondition {
      condition     = var.object_lock_mode != "COMPLIANCE" || var.acknowledge_compliance_mode_is_irreversible
      error_message = "object_lock_mode is COMPLIANCE but acknowledge_compliance_mode_is_irreversible is false. See the evidence bucket for the full consequence."
    }
  }
}

# Object Lock requires versioning, and versioning can never be suspended on a
# bucket that has it.
resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "plaso" {
  bucket = aws_s3_bucket.plaso.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Declared with no `rule` block on purpose. See the header comment.
resource "aws_s3_bucket_object_lock_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
}

resource "aws_s3_bucket_object_lock_configuration" "plaso" {
  bucket = aws_s3_bucket.plaso.id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "plaso" {
  bucket = aws_s3_bucket.plaso.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "plaso" {
  bucket = aws_s3_bucket.plaso.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Intake: the quarantine boundary (spec 5.1).
#
# S3 verifies the client's SHA-256 at PUT (spec 4.2), so this bucket is no
# longer where transfer corruption is caught -- that never reaches storage. What
# it still catches is an artifact that transferred perfectly and is filed against
# the wrong case. Under GOVERNANCE the break-glass role can undo that; under the
# per-case COMPLIANCE mode of spec 5.2 nobody can. One server-side copy is a
# cheap price for somewhere to be wrong.
#
# Deliberately NOT Object Lock and NOT versioned: the recorder deletes what it
# has filed, and a locked intake bucket would defeat the purpose.
resource "aws_s3_bucket" "intake" {
  bucket = "${var.name_prefix}-intake-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-intake"
    Content = "unverified-landing-zone"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "intake" {
  bucket = aws_s3_bucket.intake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "intake" {
  bucket = aws_s3_bucket.intake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "intake" {
  bucket = aws_s3_bucket.intake.id

  rule {
    id     = "expire-unrecorded-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = var.intake_expiry_days
    }

    # An abandoned multipart upload is billed storage that no object listing
    # shows. Uploads here are large and interruptible, so this matters.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "intake" {
  bucket = aws_s3_bucket.intake.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.intake.arn,
          "${aws_s3_bucket.intake.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}
