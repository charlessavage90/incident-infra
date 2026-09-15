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

# Spec 5.2: GOVERNANCE is only meaningfully different from COMPLIANCE if some
# principal can actually bypass it. Ingesting the wrong client's data is the
# case this exists for.
run "break_glass_role_is_absent_until_a_principal_is_named" {
  command = plan

  assert {
    condition     = length(aws_iam_role.break_glass) == 0
    error_message = "A bypass role nobody asked for is a standing privilege; it appears only when a principal is named."
  }
}

run "break_glass_role_can_bypass_governance_retention" {
  command = plan

  variables {
    break_glass_principal_arns = ["arn:aws:iam::111122223333:role/incident-lead"]
  }

  assert {
    condition     = length(aws_iam_role.break_glass) == 1
    error_message = "Naming a principal must create the role."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(one(aws_iam_role_policy.break_glass).policy).Statement :
      contains(s.Action, "s3:BypassGovernanceRetention")
    ])
    error_message = "Without this permission a governance-locked object cannot be removed and tofu destroy fails (spec 5.2.2)."
  }
}

# A responder uploads. A responder does not read the evidence bucket, delete
# from it, or write the manifest -- the recorder does that.
run "responder_policy_can_upload_but_not_reach_evidence" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_policy.responder.policy).Statement :
      s.Sid == "IntakeUpload"
    ])
    error_message = "A responder must be able to put an artifact into intake."
  }

  # Asserted on ACTIONS, not resource ARNs. mock_resource defaults give every
  # aws_s3_bucket the same invented ARN, so any assertion of the form "no
  # statement mentions the evidence bucket" passes vacuously under test and
  # proves nothing. Actions are literal config and are genuinely checked.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_policy.responder.policy).Statement :
      !contains(s.Action, "s3:GetObject") &&
      !contains(s.Action, "s3:DeleteObject") &&
      !contains(s.Action, "s3:PutObjectLegalHold")
    ])
    error_message = "A responder uploads. Reading, deleting and locking evidence all belong to the recorder."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_policy.responder.policy).Statement :
      s.Sid == "ArtifactRead" ? !contains(s.Action, "dynamodb:PutItem") : true
    ])
    error_message = "A responder must not be able to write a custody entry by hand."
  }
}

# Spec 5.5. In-VPC placement would put the recorder behind the interface
# endpoints that dormancy destroys, which would couple the chain of custody to
# the posture toggle -- artifacts arriving between incidents would go unrecorded.
run "recorder_is_not_attached_to_the_vpc" {
  command = plan

  assert {
    condition     = length(aws_lambda_function.intake.vpc_config) == 0
    error_message = "A VPC-attached recorder stops working while the environment is dormant, and the gap is silent."
  }
}

# It reads metadata and drives a server-side copy. It never reads object bytes,
# which is what makes running it outside the VPC defensible.
run "recorder_cannot_read_object_content" {
  command = plan

  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.intake.policy).Statement :
      contains(s.Action, "s3:GetObject")
    ])
    error_message = "A component that cannot read evidence cannot leak it. HeadObject and a server-side CopyObject are enough."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.intake.policy).Statement :
      contains(s.Action, "s3:PutObjectLegalHold")
    ])
    error_message = "The recorder applies the hold that makes an artifact immutable (spec 5.2)."
  }
}

run "recorder_is_triggered_by_intake_arrivals" {
  command = plan

  assert {
    condition     = one([for l in aws_s3_bucket_notification.intake.lambda_function : l.events]) == toset(["s3:ObjectCreated:*"])
    error_message = "Recording must begin the moment an object lands, whatever the posture."
  }
}

run "recorder_has_the_full_timeout" {
  command = plan

  assert {
    condition     = aws_lambda_function.intake.timeout == 900
    error_message = "The server-side copy of a large artifact needs the whole window; the ceiling is documented, not hidden."
  }
}
