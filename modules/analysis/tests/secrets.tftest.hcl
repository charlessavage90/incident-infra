mock_provider "aws" {
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
}
mock_provider "random" {}

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
