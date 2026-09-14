# The case store (spec 5.3).
#
# This exists because evidence objects are immutable. Everything worth knowing
# about an artifact changes after it lands -- custody events accumulate, the case
# opens and closes, the legal hold flag toggles, retention is set, and phase 3
# attaches a timeline ID and an event count. None of that can be written onto an
# object that is under a legal hold from the moment it arrives.
#
# Only the key schema is declared. DynamoDB is schemaless beyond its keys, and
# declaring non-key attributes here would create indexes nobody asked for.
#
# Attributes written by the recorder and by irctl:
#   cases      case_id, status, opened_at, closed_at, sketch_id, retention_years,
#              object_lock_mode, legal_hold, cost_tag
#   artifacts  case_id, sha256, status, source, size_bytes, received_at,
#              evidence_key, custody (list), timeline_id, event_count

resource "aws_dynamodb_table" "cases" {
  name         = "${var.name_prefix}-cases"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "case_id"

  attribute {
    name = "case_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  deletion_protection_enabled = var.manifest_deletion_protection

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-cases"
  })
}

resource "aws_dynamodb_table" "artifacts" {
  name         = "${var.name_prefix}-artifacts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "case_id"
  range_key    = "sha256"

  attribute {
    name = "case_id"
    type = "S"
  }

  attribute {
    name = "sha256"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  deletion_protection_enabled = var.manifest_deletion_protection

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-artifacts"
  })
}
