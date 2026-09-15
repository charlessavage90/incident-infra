"""Replace the mock preamble in every platform test file with one canonical block.

OpenTofu 1.12 has no `source` argument on mock_provider, so the block genuinely
has to be duplicated per file. Duplicated by hand it drifts -- which is exactly
what just broke: only intake.tftest.hcl mocked aws_iam_role, so every other file
handed the provider an invented value it rejects as an invalid ARN.
"""

import pathlib
import sys

CANONICAL = '''mock_provider "aws" {
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

tests = pathlib.Path("C:/dev/incident-infra/modules/platform/tests")

for path in sorted(tests.glob("*.tftest.hcl")):
    text = path.read_text(encoding="utf-8")
    marker = "\nvariables {"
    idx = text.find(marker)
    if idx == -1:
        sys.exit("FAIL %s: no top-level variables block to anchor on" % path.name)
    path.write_text(CANONICAL + text[idx + 1:], encoding="utf-8", newline="\n")
    print("ok:", path.name)
