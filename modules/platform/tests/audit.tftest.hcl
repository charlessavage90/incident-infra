mock_provider "aws" {
  # mock_provider invents values for computed attributes, but the AWS provider
  # validates some of them (ARNs especially) and rejects the invented ones.
  # OpenTofu 1.12 has no shared-mock `source` argument, so this block is repeated
  # in each test file in this module. Keep them in sync.
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      key_id = "11111111-2222-3333-4444-555555555555"
    }
  }

  mock_resource "aws_ecr_repository" {
    defaults = {
      arn = "arn:aws:ecr:us-east-1:111122223333:repository/ir-test/placeholder"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::ir-test-mock"
    }
  }
}
mock_provider "random" {}

variables {
  name_prefix         = "ir-test"
  budget_alert_emails = ["responder@example.com"]
}

# Spec 5.1: Object Lock buckets cannot receive S3 server access logs, so
# object-level read/write auditing is CloudTrail data events instead.
run "data_events_cover_every_evidence_bucket" {
  command = plan

  assert {
    condition     = length(aws_cloudtrail.data_events.advanced_event_selector) == 1
    error_message = "One selector covers all four buckets; splitting them multiplies cost for no benefit."
  }

  assert {
    condition = length(flatten([
      for sel in aws_cloudtrail.data_events.advanced_event_selector : [
        for f in sel.field_selector : f if f.field == "resources.ARN"
      ]
    ])) == 1
    error_message = "The selector must scope to bucket ARNs, or it bills for every S3 object event in the account."
  }
}

run "trail_validates_its_own_log_files" {
  command = plan

  assert {
    condition     = aws_cloudtrail.data_events.enable_log_file_validation
    error_message = "An audit log that cannot be shown to be unmodified is not evidence of anything."
  }
}

run "audit_bucket_is_versioned_and_encrypted" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.audit.versioning_configuration[0].status == "Enabled"
    error_message = "Overwriting an audit log must leave a trace."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.audit.rule).apply_server_side_encryption_by_default).kms_master_key_id == aws_kms_key.main.arn
    error_message = "Audit logs name artifacts and principals; they take the platform CMK."
  }
}

# The default key policy grants the account root, which does not cover an AWS
# service principal. Without an explicit grant CloudTrail cannot encrypt, and
# the trail fails at apply time with a message that does not name the key.
run "key_policy_lets_cloudtrail_encrypt_and_keeps_root" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.main.policy).Statement : s if s.Sid == "EnableRootAccountAccess"
    ]) == 1
    error_message = "An explicit key policy without a root statement is an unrecoverable lockout."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.main.policy).Statement : s if s.Sid == "AllowCloudTrailEncrypt"
    ]) == 1
    error_message = "CloudTrail is a service principal, not an account principal, so the default key policy does not reach it."
  }
}
