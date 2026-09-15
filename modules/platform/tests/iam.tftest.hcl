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

run "instance_role_can_be_managed_by_ssm" {
  command = plan

  assert {
    condition = contains(
      [for a in aws_iam_role_policy_attachment.ssm_core : a.policy_arn],
      "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    )
    error_message = "SSM is the only access path (D6). Without this the appliance is unreachable."
  }
}

run "instance_role_is_assumable_only_by_ec2" {
  command = plan

  assert {
    condition     = strcontains(aws_iam_role.appliance.assume_role_policy, "ec2.amazonaws.com")
    error_message = "The appliance role must trust the EC2 service."
  }

  assert {
    condition     = !strcontains(aws_iam_role.appliance.assume_role_policy, "\"AWS\"")
    error_message = "The appliance role must not trust arbitrary AWS principals."
  }
}

run "instance_policy_scopes_secrets_to_this_deployment" {
  command = plan

  assert {
    condition     = strcontains(aws_iam_role_policy.appliance.policy, "secret:ir-test/")
    error_message = "Secret access must be scoped by name_prefix, not account-wide."
  }
}

run "instance_profile_wraps_the_appliance_role" {
  command = plan

  assert {
    condition     = aws_iam_instance_profile.appliance.role == aws_iam_role.appliance.name
    error_message = "The instance profile must reference the appliance role."
  }
}
