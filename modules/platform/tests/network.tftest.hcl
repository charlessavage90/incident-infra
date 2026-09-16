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

# Both statements are load-bearing. The account condition stops a compromised
# instance copying evidence to another account's bucket; the service statement
# keeps the OS working, because Amazon Linux repos are fetched anonymously and
# ECR layers come via presigned URLs signed with AWS's own credentials. Either
# alone is broken. Both failures were observed during Phase 1 acceptance.
run "s3_endpoint_policy_allows_aws_owned_buckets" {
  command = plan

  assert {
    condition     = strcontains(aws_vpc_endpoint.s3.policy, "aws:PrincipalAccount")
    error_message = "S3 endpoint must restrict this account's own principals."
  }

  assert {
    condition     = strcontains(aws_vpc_endpoint.s3.policy, "al2023-repos-")
    error_message = "S3 endpoint must allow Amazon Linux repos, which are fetched anonymously - otherwise dnf gets 403."
  }

  assert {
    condition     = strcontains(aws_vpc_endpoint.s3.policy, "starport-layer-bucket")
    error_message = "S3 endpoint must allow ECR layer buckets, which are presigned by AWS - otherwise docker pull gets 403."
  }
}

# Gateway endpoints are route-table entries: free, and unaffected by dormancy.
# The Batch worker writes timeline_id and event_count to the manifest from
# inside the VPC, and an interface endpoint for DynamoDB would both bill per ENI
# and -- living in the analysis layer -- disappear when dormant.
run "dynamodb_reachable_without_an_interface_endpoint" {
  command = plan

  assert {
    condition     = aws_vpc_endpoint.dynamodb.vpc_endpoint_type == "Gateway"
    error_message = "A DynamoDB interface endpoint would bill per ENI and would be destroyed by dormancy; a gateway endpoint is free and permanent."
  }

  # Not symmetry with the S3 endpoint for its own sake. Without the condition, a
  # compromised worker could reach a table in an ATTACKER's account through this
  # endpoint -- to stage exfiltrated metadata, or to take instructions. D2
  # isolates this account from the environment under investigation, and that
  # holds whichever way the bytes flow.
  assert {
    condition     = jsondecode(aws_vpc_endpoint.dynamodb.policy).Statement[0].Condition.StringEquals["aws:PrincipalAccount"] == data.aws_caller_identity.current.account_id
    error_message = "An endpoint with no principal condition is usable by any account that can reach it, which undercuts D2's isolation."
  }
}
