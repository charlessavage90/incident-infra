mock_provider "aws" {}
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
