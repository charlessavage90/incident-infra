"""Replace the mock preamble in every test file of a module with one canonical block.

OpenTofu 1.12 has no `source` argument on mock_provider, so the block genuinely
has to be duplicated per file. Duplicated by hand it drifts -- which is exactly
what broke twice: in modules/platform only intake.tftest.hcl mocked
aws_iam_role, and in modules/analysis nothing did until the Batch fleet arrived
in Phase 3. Both times the provider rejected an invented value as an invalid
ARN, in files nobody had touched, with an error naming the ARN rather than the
missing mock.

Each module gets its own canonical block because their needs differ: platform
mocks buckets and ECR repositories it owns, analysis mocks the SSM parameters
and AMI lookups it reads. What must not differ is the block WITHIN a module.
"""

import pathlib
import sys

PLATFORM = '''mock_provider "aws" {
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

'''

ANALYSIS = '''mock_provider "aws" {
  # mock_provider invents values for computed attributes, but the AWS provider
  # VALIDATES some of them -- ARNs especially -- and rejects the invented ones.
  # Anything returned as a list must be mocked too, or it arrives empty.
  #
  # OpenTofu 1.12 has no `source` argument on mock_provider, so this block is
  # duplicated across every test file in this module. IT MUST BE KEPT IN SYNC:
  # a resource mocked in one file and not another fails only in the OTHER files,
  # with an error that names the ARN rather than the missing mock.
  #
  # Regenerate all of them rather than editing one:
  #   python scripts/sync-test-mocks.py
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/placeholder@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      availability_zone = "us-east-1a"
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id = "ami-00000000000000000"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
    }
  }

  # From Phase 3. The Batch compute environment validates both of these as ARNs
  # before it will plan, and neither is something this module can invent.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/ir-test-mock"
    }
  }

  mock_resource "aws_iam_instance_profile" {
    defaults = {
      arn = "arn:aws:iam::111122223333:instance-profile/ir-test-mock"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:111122223333:secret:ir-test-mock"
    }
  }

  # The Batch job queue validates the compute environment ARN it is handed, and
  # the Lambda permission validates the rule ARN. Neither error names the
  # missing mock -- both print the invented value and "cannot be parsed as an
  # ARN", which is why these are here rather than discovered one test run at a
  # time.
  mock_resource "aws_batch_compute_environment" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:111122223333:compute-environment/ir-test-mock"
    }
  }

  mock_resource "aws_batch_job_queue" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:111122223333:job-queue/ir-test-mock"
    }
  }

  mock_resource "aws_batch_job_definition" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:111122223333:job-definition/ir-test-mock:1"
    }
  }

  mock_resource "aws_sfn_state_machine" {
    defaults = {
      arn = "arn:aws:states:us-east-1:111122223333:stateMachine:ir-test-mock"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:111122223333:ir-test-mock"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:111122223333:function:ir-test-mock"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:111122223333:rule/ir-test-mock"
    }
  }
}
mock_provider "random" {}
mock_provider "archive" {}

'''

MODULES = {
    "platform": PLATFORM,
    "analysis": ANALYSIS,
}

root = pathlib.Path(__file__).resolve().parent.parent

for module, canonical in MODULES.items():
    tests = root / "modules" / module / "tests"
    for path in sorted(tests.glob("*.tftest.hcl")):
        text = path.read_text(encoding="utf-8")
        marker = "\nvariables {"
        idx = text.find(marker)
        if idx == -1:
            sys.exit("FAIL %s/%s: no top-level variables block to anchor on" % (module, path.name))
        path.write_text(canonical + text[idx + 1:], encoding="utf-8", newline="\n")
        print("ok: %s/%s" % (module, path.name))
