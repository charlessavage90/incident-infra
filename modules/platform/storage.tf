# The keystone of spec 3.1.
#
# This volume lives in the permanent platform layer, not the toggleable analysis
# layer, so that `tofu destroy` against modules/analysis loses no warm data.
# Indices and evidence sit on the other side of that boundary. It is also what
# makes a colder dormancy tier available later at no additional design cost.
resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.private[0].availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = aws_kms_key.main.arn

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-data"
    Role = "opensearch-and-postgres"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# Mirrored tooling binaries.
#
# Amazon Linux 2023 ships no Docker Compose package, and the upstream binary is
# a GitHub download -- which this VPC deliberately cannot reach. The images
# module (which runs in CodeBuild, outside the VPC, with internet) fetches it and
# writes it here; the appliance reads it back over the S3 gateway endpoint.
#
# This is the same shape as the container-image mirror, and Phase 3 will need it
# for plaso worker tooling.
resource "aws_s3_bucket" "tooling" {
  bucket = "${var.name_prefix}-tooling-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "tooling" {
  bucket = aws_s3_bucket.tooling.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tooling" {
  bucket = aws_s3_bucket.tooling.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

# Two low Snyk findings are accepted here and left VISIBLE rather than
# suppressed, because a scoped ignore could not be made to match and a blanket
# one would silently exempt Phase 2's evidence buckets, where both controls
# genuinely matter:
#
#   SNYK-CC-TF-127 (no MFA delete) - cannot be set by Terraform at all; it needs
#     root credentials presenting an MFA token via the CLI.
#   SNYK-CC-TF-45 (no server access logging) - would add a second bucket to audit
#     reads of a public binary.
#
# This bucket holds one public, reproducible artifact, and the appliance verifies
# its SHA-256 against an SSM parameter before executing it, so integrity does not
# depend on the bucket. Revisit if it ever holds anything non-public.
resource "aws_s3_bucket_public_access_block" "tooling" {
  bucket = aws_s3_bucket.tooling.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
