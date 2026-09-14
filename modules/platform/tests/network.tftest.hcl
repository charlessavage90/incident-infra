mock_provider "aws" {
  # mock_provider invents values for computed attributes, but the AWS provider
  # validates some of them (ARNs especially) and rejects the invented ones.
  # OpenTofu 1.12 has no shared-mock `source` argument, so this block is repeated
  # in each test file in this module. Keep the four in sync.
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
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
}
mock_provider "random" {}

variables {
  name_prefix         = "ir-test"
  budget_alert_emails = ["responder@example.com"]
  vpc_cidr            = "10.90.0.0/16"
}

run "no_internet_gateway_by_default" {
  command = plan

  assert {
    condition     = length(aws_internet_gateway.main) == 0
    error_message = "The IR VPC must have no internet gateway unless enable_internet_egress is true."
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 0
    error_message = "The IR VPC must have no NAT gateway unless enable_internet_egress is true."
  }
}

run "egress_is_available_when_explicitly_enabled" {
  command = plan

  variables {
    enable_internet_egress = true
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 1
    error_message = "enable_internet_egress must provision a NAT gateway for org-managed connectors."
  }
}

run "two_private_subnets_across_azs" {
  command = plan

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "Two private subnets are required across two availability zones."
  }
}

run "private_subnets_never_assign_public_ips" {
  command = plan

  assert {
    condition     = alltrue([for s in aws_subnet.private : s.map_public_ip_on_launch == false])
    error_message = "No public ingress (D6). Private subnets must not auto-assign public IPs."
  }
}

run "appliance_security_group_denies_ingress_by_default" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.appliance_https) == 0
    error_message = "With no allowed_ingress_* inputs, the appliance SG must have zero ingress rules."
  }
}

run "connector_cidrs_open_only_443" {
  command = plan

  variables {
    allowed_ingress_cidrs = ["10.10.0.0/24", "10.11.0.0/24"]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.appliance_https) == 2
    error_message = "One ingress rule per allowed CIDR."
  }

  assert {
    condition = alltrue([
      for r in aws_vpc_security_group_ingress_rule.appliance_https :
      r.from_port == 443 && r.to_port == 443
    ])
    error_message = "Connectors get 443 only, never a wider range."
  }
}

run "s3_gateway_endpoint_exists" {
  command = plan

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway"
    error_message = "S3 must use a gateway endpoint. ECR image layers are fetched from S3."
  }
}
