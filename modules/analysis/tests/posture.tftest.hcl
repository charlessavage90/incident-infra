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
  responders                      = ["responder"]
}

run "active_creates_interface_endpoints" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 8
    error_message = "Active posture must create all eight interface endpoints."
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
