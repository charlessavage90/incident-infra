mock_provider "aws" {
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

variables {
  name_prefix                     = "ir-test"
  vpc_id                          = "vpc-00000000000000000"
  vpc_cidr                        = "10.90.0.0/16"
  private_subnet_ids              = ["subnet-00000000000000001", "subnet-00000000000000002"]
  data_volume_id                  = "vol-00000000000000000"
  data_volume_availability_zone   = "us-east-1a"
  kms_key_arn                     = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
  appliance_instance_profile_name = "ir-test-appliance"
  appliance_security_group_id     = "sg-00000000000000000"
  private_zone_id                 = "Z00000000000000000000"
  private_zone_name               = "ir.internal"
  image_digest_parameter_prefix   = "/ir-test/images"
  responders                      = ["responder"]

  evidence_bucket     = "ir-test-evidence-111122223333"
  evidence_bucket_arn = "arn:aws:s3:::ir-test-evidence-111122223333"
  plaso_bucket        = "ir-test-plaso-111122223333"
  plaso_bucket_arn    = "arn:aws:s3:::ir-test-plaso-111122223333"
  artifacts_table     = "ir-test-artifacts"
  artifacts_table_arn = "arn:aws:dynamodb:us-east-1:111122223333:table/ir-test-artifacts"
}

run "active_creates_interface_endpoints" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 11
    error_message = "Active posture must create all eleven interface endpoints: eight the appliance needs, plus ecs/ecs-agent/ecs-telemetry without which Batch instances never join the compute environment."
  }
}

# Interface endpoints bill hourly whether used or not and are the largest
# avoidable dormant line item (spec 3.2).
run "dormant_destroys_interface_endpoints" {
  command = plan

  variables {
    posture = "dormant"
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 0
    error_message = "Dormant posture must create no interface endpoints."
  }
}

run "ssm_endpoints_are_present_when_active" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition = alltrue([
      for s in ["ssm", "ssmmessages", "ec2messages"] :
      contains(keys(aws_vpc_endpoint.interface), s)
    ])
    error_message = "SSM Session Manager needs all three of ssm, ssmmessages, and ec2messages."
  }
}

run "posture_rejects_invalid_values" {
  command = plan

  variables {
    posture = "hibernating"
  }

  expect_failures = [var.posture]
}

# Interface endpoints bill per ENI: per endpoint, per AZ. The appliance is a
# single instance pinned to subnet 0 by the data volume's AZ, so a second ENI
# per endpoint doubles the largest active-cost line item for no availability gain.
run "endpoints_occupy_one_az_only" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition = alltrue([
      for e in aws_vpc_endpoint.interface : length(e.subnet_ids) == 1
    ])
    error_message = "Interface endpoints must sit in one AZ; a second ENI per endpoint is pure cost."
  }

  assert {
    condition = alltrue([
      for e in aws_vpc_endpoint.interface : tolist(e.subnet_ids)[0] == var.private_subnet_ids[0]
    ])
    error_message = "Endpoints must be in the same subnet as the appliance."
  }
}
