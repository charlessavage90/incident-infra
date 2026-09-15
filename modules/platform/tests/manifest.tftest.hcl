mock_provider "aws" {
  # mock_provider invents values for computed attributes, but the AWS provider
  # VALIDATES some of them -- ARNs especially -- and rejects the invented ones.
  # Anything returned as a list must be mocked too, or it arrives empty.
  #
  # OpenTofu 1.12 has no `source` argument on mock_provider, so this block is
  # duplicated across every test file in this module. IT MUST BE KEPT IN SYNC:
  # a resource mocked in one file and not another fails only in the other files,
  # with an error that names the ARN rather than the missing mock.
  #
  # Regenerate all of them rather than editing one:
  #   python scripts/sync-test-mocks.py
  #
  # NOTE: mock_resource defaults apply to EVERY instance of a type, so all four
  # S3 buckets share one mocked ARN. Never assert that a policy does or does not
  # mention a particular bucket -- it passes vacuously. Assert on actions, which
  # are literal config.
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

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/ir-test-mock"
    }
  }
}
mock_provider "random" {}
mock_provider "archive" {}

variables {
  name_prefix         = "ir-test"
  budget_alert_emails = ["responder@example.com"]
}

# Spec 4.2: deduplication. A composite key of (case_id, sha256) lets the
# recorder write conditionally on attribute_not_exists(sha256), which makes
# "have I seen this before" atomic. A read-then-write check is not: two
# concurrent recorder invocations on the same artifact would both pass the read.
run "artifacts_are_keyed_by_case_and_digest" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.artifacts.hash_key == "case_id"
    error_message = "Deduplication is scoped within a case: the same file on two engagements is two custody chains."
  }

  assert {
    condition     = aws_dynamodb_table.artifacts.range_key == "sha256"
    error_message = "The digest must be the sort key, so a conditional write gives atomic deduplication."
  }
}

run "cases_are_keyed_by_case_id" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.cases.hash_key == "case_id"
    error_message = "Case state is looked up by case ID on every intake."
  }
}

# The manifest is the only thing here that cannot be reconstructed. Evidence can
# be re-hashed; a chain of custody cannot be re-derived.
run "manifest_survives_accidents" {
  command = plan

  assert {
    condition     = one([for p in aws_dynamodb_table.cases.point_in_time_recovery : p.enabled])
    error_message = "A custody chain cannot be re-derived, so it needs point-in-time recovery."
  }

  assert {
    condition     = one([for p in aws_dynamodb_table.artifacts.point_in_time_recovery : p.enabled])
    error_message = "A custody chain cannot be re-derived, so it needs point-in-time recovery."
  }

  assert {
    condition     = aws_dynamodb_table.cases.deletion_protection_enabled
    error_message = "Deletion protection defaults on; spec 5.2.2's development teardown turns it off deliberately."
  }
}

run "manifest_is_encrypted_with_the_platform_key" {
  command = plan

  assert {
    condition     = one([for s in aws_dynamodb_table.artifacts.server_side_encryption : s.kms_key_arn]) == aws_kms_key.main.arn
    error_message = "The manifest names artifacts and cases; it takes the platform CMK, not an AWS-managed key."
  }
}

# Incidents are infrequent and the tables hold hundreds of rows. Provisioned
# capacity would bill continuously for a workload that is idle by design.
run "manifest_bills_per_request" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.cases.billing_mode == "PAY_PER_REQUEST"
    error_message = "This environment is dormant most of the time; provisioned capacity would bill through the gaps."
  }

  assert {
    condition     = aws_dynamodb_table.artifacts.billing_mode == "PAY_PER_REQUEST"
    error_message = "This environment is dormant most of the time; provisioned capacity would bill through the gaps."
  }
}

run "deletion_protection_can_be_released_for_teardown" {
  command = plan

  variables {
    manifest_deletion_protection = false
  }

  assert {
    condition     = aws_dynamodb_table.artifacts.deletion_protection_enabled == false
    error_message = "Spec 5.2.2 develops against a non-dedicated account, which must be able to tear down."
  }
}
