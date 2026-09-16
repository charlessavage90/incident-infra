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
  responders                      = ["alice", "bob"]

  evidence_bucket     = "ir-test-evidence-111122223333"
  evidence_bucket_arn = "arn:aws:s3:::ir-test-evidence-111122223333"
  plaso_bucket        = "ir-test-plaso-111122223333"
  plaso_bucket_arn    = "arn:aws:s3:::ir-test-plaso-111122223333"
  artifacts_table     = "ir-test-artifacts"
  artifacts_table_arn = "arn:aws:dynamodb:us-east-1:111122223333:table/ir-test-artifacts"
}

run "one_secret_per_responder" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = length(aws_secretsmanager_secret.responder) == 2
    error_message = "Each responder gets a named account and its own generated password (spec 3.4)."
  }
}

run "secrets_use_the_platform_key" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_secretsmanager_secret.postgres.kms_key_id == var.kms_key_arn
    error_message = "Secrets must be encrypted with the platform CMK, not an AWS-managed key."
  }

  assert {
    condition     = aws_secretsmanager_secret.timesketch_secret_key.kms_key_id == var.kms_key_arn
    error_message = "The Flask SECRET_KEY must be encrypted with the platform CMK."
  }
}

run "generated_passwords_are_long" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = random_password.postgres.length >= 32
    error_message = "Generated passwords must be at least 32 characters."
  }

  assert {
    condition     = random_password.timesketch_secret_key.length >= 32
    error_message = "The Flask SECRET_KEY signs cookies and must be long."
  }
}

# Timesketch builds a PostgreSQL URI from this value; special characters would
# need escaping and silently break the connection string.
run "postgres_password_avoids_uri_hazards" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = random_password.postgres.special == false
    error_message = "The PostgreSQL password goes into a URI; special characters are a hazard."
  }
}

run "secrets_are_namespaced_by_deployment" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_secretsmanager_secret.postgres.name == "ir-test/postgres"
    error_message = "Secrets must be namespaced under name_prefix so dev and prod can coexist."
  }
}

# The worker authenticates to Timesketch as a named account, not as a responder.
# Timesketch attributes every timeline to a user, and attribution is the reason
# responder logins are never shared (spec 3.4) -- the pipeline is no different.
run "pipeline_has_its_own_account" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_secretsmanager_secret.pipeline.name == "ir-test/pipeline"
    error_message = "The worker reads this secret by name from its job definition environment; the two must agree."
  }

  assert {
    condition     = random_password.pipeline.length >= 32
    error_message = "Generated passwords must be at least 32 characters."
  }
}
