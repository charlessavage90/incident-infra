mock_provider "aws" {
  # mock_provider invents values for computed attributes, but the AWS provider
  # validates some of them (ARNs especially) and rejects the invented ones.
  # OpenTofu 1.12 has no shared-mock `source` argument, so this block is repeated
  # in each test file in this module. Keep them in sync.
  #
  # NOTE: mock_resource defaults apply to EVERY instance of a type, so all four
  # buckets share one mocked ARN. Never assert on bucket ARN equality here --
  # assert on `.bucket`, which is configured and therefore known at plan time.
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

run "evidence_bucket_has_object_lock_enabled" {
  command = plan

  assert {
    condition     = aws_s3_bucket.evidence.object_lock_enabled == true
    error_message = "Without Object Lock an artifact can be deleted before its case closes, which is the guarantee this bucket exists to make."
  }

  assert {
    condition     = aws_s3_bucket_versioning.evidence.versioning_configuration[0].status == "Enabled"
    error_message = "Object Lock requires versioning, and versioning can never be suspended afterwards."
  }
}

# Spec 5.2: the retain-until date is computed at case close, not at upload.
# A bucket-level default retention would stamp one at PUT and silently defeat
# the entire retention model.
run "evidence_bucket_has_no_default_retention" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_object_lock_configuration.evidence.rule) == 0
    error_message = "A default retention would start every artifact's clock at upload instead of at case close."
  }

  assert {
    condition     = length(aws_s3_bucket_object_lock_configuration.plaso.rule) == 0
    error_message = "Derived evidence follows the same retention model as raw evidence."
  }
}

run "evidence_buckets_are_encrypted_with_the_platform_key" {
  command = plan

  # `rule` is a set, not a list -- set elements have no addressable keys, so
  # rule[0] is a plan-time error rather than a failing assertion.
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.evidence.rule).apply_server_side_encryption_by_default).kms_master_key_id == aws_kms_key.main.arn
    error_message = "Evidence must be encrypted with the platform CMK, not an AWS-managed key."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.plaso.rule).apply_server_side_encryption_by_default).kms_master_key_id == aws_kms_key.main.arn
    error_message = "Generated timelines are derived evidence and get the same key."
  }
}

run "evidence_buckets_block_public_access" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.evidence.block_public_acls,
      aws_s3_bucket_public_access_block.evidence.block_public_policy,
      aws_s3_bucket_public_access_block.evidence.ignore_public_acls,
      aws_s3_bucket_public_access_block.evidence.restrict_public_buckets,
    ])
    error_message = "There is no public ingress anywhere in this design (D6), least of all to evidence."
  }
}

# Spec 5.2.1. Compliance mode is the only irreversible action in this module:
# a locked object cannot be deleted before expiry by anyone including account
# root, and the bucket cannot be destroyed while one exists.
run "compliance_mode_requires_explicit_acknowledgement" {
  command = plan

  variables {
    object_lock_mode = "COMPLIANCE"
    # acknowledge_compliance_mode_is_irreversible deliberately left at false
  }

  # Both buckets are guarded, and both must refuse. Listing only one here would
  # pass while leaving the other reachable.
  expect_failures = [
    aws_s3_bucket.evidence,
    aws_s3_bucket.plaso,
  ]
}

run "compliance_mode_is_allowed_once_acknowledged" {
  command = plan

  variables {
    object_lock_mode                            = "COMPLIANCE"
    acknowledge_compliance_mode_is_irreversible = true
  }

  assert {
    condition     = aws_s3_bucket.evidence.object_lock_enabled == true
    error_message = "An acknowledged compliance-mode deployment must still plan cleanly."
  }
}

run "object_lock_mode_rejects_an_unknown_value" {
  command = plan

  variables {
    object_lock_mode = "guvnor"
  }

  expect_failures = [var.object_lock_mode]
}
