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
