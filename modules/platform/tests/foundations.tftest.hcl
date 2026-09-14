mock_provider "aws" {
  # mock_provider invents values for computed attributes, but the AWS provider
  # validates some of them (ARNs especially) and rejects the invented ones.
  # OpenTofu 1.12 has no shared-mock `source` argument, so this block is repeated
  # in each test file in this module. Keep the four in sync.
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
}
mock_provider "random" {}

variables {
  name_prefix         = "ir-test"
  monthly_budget_usd  = 200
  budget_alert_emails = ["responder@example.com"]
}

run "kms_key_rotates_annually" {
  command = plan

  assert {
    condition     = aws_kms_key.main.enable_key_rotation == true
    error_message = "Platform CMK must have automatic key rotation enabled."
  }
}

run "budget_alerts_before_overspend" {
  command = plan

  assert {
    condition     = aws_budgets_budget.monthly.limit_amount == "200"
    error_message = "Budget limit must come from var.monthly_budget_usd."
  }

  assert {
    condition     = length(aws_budgets_budget.monthly.notification) == 2
    error_message = "Budget must notify at both a forecast and an actual threshold."
  }
}
