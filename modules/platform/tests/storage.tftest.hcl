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
  data_volume_gb      = 500
}

run "data_volume_is_encrypted_with_platform_key" {
  command = plan

  assert {
    condition     = aws_ebs_volume.data.encrypted == true
    error_message = "The data volume holds evidence-derived indices and must be encrypted."
  }

  assert {
    condition     = aws_ebs_volume.data.kms_key_id == aws_kms_key.main.arn
    error_message = "Data volume must use the platform CMK, not an AWS-managed key."
  }

  assert {
    condition     = aws_ebs_volume.data.size == 500
    error_message = "Data volume size must come from var.data_volume_gb."
  }

  assert {
    condition     = aws_ebs_volume.data.type == "gp3"
    error_message = "Data volume must be gp3."
  }
}

# EBS volumes attach only within a single availability zone. If the volume and
# the appliance's subnet disagree, the attachment fails at apply time with an
# error that does not name the cause.
run "data_volume_is_in_the_appliance_availability_zone" {
  command = plan

  assert {
    condition     = aws_ebs_volume.data.availability_zone == aws_subnet.private[0].availability_zone
    error_message = "EBS volumes attach only within one AZ. The data volume must match subnet 0."
  }
}

run "ecr_repositories_scan_on_push" {
  command = plan

  assert {
    condition = alltrue([
      for r in aws_ecr_repository.mirror : r.image_scanning_configuration[0].scan_on_push
    ])
    error_message = "Mirrored images must be scanned on push."
  }

  assert {
    condition     = length(aws_ecr_repository.mirror) == 5
    error_message = "Five images are mirrored: timesketch, opensearch, postgres, redis, nginx."
  }
}

# Spec 4.5: the appliance and the plaso worker must run the same plaso binary.
# Mutable tags would let a re-push silently change what a tag resolves to.
run "ecr_tags_are_immutable" {
  command = plan

  assert {
    condition = alltrue([
      for r in aws_ecr_repository.mirror : r.image_tag_mutability == "IMMUTABLE"
    ])
    error_message = "Image tags must be immutable to support the version-parity invariant."
  }
}

run "private_zone_is_attached_to_the_ir_vpc" {
  command = plan

  assert {
    condition     = aws_route53_zone.private.name == "ir.internal"
    error_message = "Private zone name must come from var.private_zone_name."
  }
}

# The worker image is BUILT from the mirrored Timesketch image, not mirrored, so
# it needs its own repository rather than a sixth entry in local.mirrored_images:
# a built image wants "keep the last N", where a mirror wants "expire untagged".
run "worker_repository_is_immutable" {
  command = plan

  assert {
    condition     = aws_ecr_repository.worker.image_tag_mutability == "IMMUTABLE"
    error_message = "A mutable worker tag would let a re-push change what an existing job definition resolves to, which is what spec 4.5 forbids."
  }

  assert {
    condition     = aws_ecr_repository.worker.name == "ir-test/plaso-worker"
    error_message = "The images module and the analysis job definition both address this repository by name."
  }
}
