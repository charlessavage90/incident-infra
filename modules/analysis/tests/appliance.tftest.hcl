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

run "appliance_has_no_public_ip" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_instance.appliance.associate_public_ip_address == false
    error_message = "No public ingress (D6). The appliance must never have a public IP."
  }
}

run "active_posture_runs_the_instance" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_ec2_instance_state.appliance.state == "running"
    error_message = "Active posture must run the appliance."
  }
}

# The whole point of warm dormancy: stop, never destroy.
run "dormant_posture_stops_but_does_not_destroy" {
  command = plan
  variables { posture = "dormant" }

  assert {
    condition     = aws_ec2_instance_state.appliance.state == "stopped"
    error_message = "Dormant posture stops the appliance."
  }

  assert {
    condition     = aws_volume_attachment.data.volume_id == var.data_volume_id
    error_message = "The data volume stays attached while dormant; it is never detached or deleted."
  }
}

run "default_instance_type_is_r6i_large" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_instance.appliance.instance_type == "r6i.large"
    error_message = "Default must be r6i.large. r6i.2xlarge costs roughly $368/month."
  }
}

run "root_volume_is_encrypted_and_imdsv2_enforced" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_instance.appliance.root_block_device[0].encrypted == true
    error_message = "Root volume must be encrypted with the platform CMK."
  }

  assert {
    condition     = aws_instance.appliance.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required; IMDSv1 is SSRF-exploitable."
  }
}

# EBS attaches only within one AZ. A mismatch fails at apply with an error that
# does not name the cause.
run "appliance_launches_in_the_data_volume_availability_zone" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_instance.appliance.subnet_id == var.private_subnet_ids[0]
    error_message = "The appliance must launch in subnet 0, which shares the data volume's AZ."
  }
}

# Spec 3.4: OpenSearch heap is RAM/2 capped at 32GB; wsgi workers are cores*2+1.
run "resources_scale_with_instance_type" {
  command = plan
  variables {
    posture       = "active"
    instance_type = "r6i.2xlarge"
  }

  assert {
    condition     = local.opensearch_heap_gb == 32
    error_message = "r6i.2xlarge has 64 GiB, so OpenSearch heap should be 32 GiB."
  }

  assert {
    condition     = local.num_wsgi_workers == 17
    error_message = "r6i.2xlarge has 8 vCPU, so wsgi workers should be (8*2)+1 = 17."
  }
}

run "default_instance_resources_are_sized_correctly" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = local.opensearch_heap_gb == 8
    error_message = "r6i.large has 16 GiB, so OpenSearch heap should be 8 GiB."
  }

  assert {
    condition     = local.num_wsgi_workers == 5
    error_message = "r6i.large has 2 vCPU, so wsgi workers should be (2*2)+1 = 5."
  }
}

# The three cloud-init gotchas. Each one silently breaks dormancy if dropped.
run "cloud_init_handles_the_three_gotchas" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = strcontains(aws_instance.appliance.user_data, "vm.max_map_count=262144")
    error_message = "OpenSearch will not start without vm.max_map_count=262144."
  }

  assert {
    condition     = strcontains(aws_instance.appliance.user_data, "blkid")
    error_message = "mkfs MUST be guarded by blkid: cloud-init runs on every boot, and an unguarded format destroys all evidence on the second activation."
  }

  assert {
    condition     = strcontains(aws_instance.appliance.user_data, "nvme")
    error_message = "On Nitro instances the data volume must be resolved by volume ID, not a guessed device path."
  }
}

run "dns_record_points_at_the_appliance" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_route53_record.timesketch.name == "timesketch.ir.internal"
    error_message = "Connector app segments reference this name; it must be stable."
  }
}

# The guard must actually fire. An unused variable would lint clean but leave
# the AZ mismatch to surface as an opaque volume-attachment failure.
run "az_mismatch_is_caught_before_apply" {
  command = plan

  variables {
    posture                       = "active"
    data_volume_availability_zone = "us-east-1c"
  }

  expect_failures = [aws_instance.appliance]
}

# Without an explicit dependency the instance can boot into a VPC that has no
# route to SSM, ECR, or Secrets Manager. cloud-init then fails and never runs
# again, leaving a running instance with no Timesketch on it.
run "appliance_waits_for_vpc_endpoints" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = strcontains(aws_instance.appliance.user_data, "retry 10 dnf install")
    error_message = "Package installation must retry; cloud-init runs once and a transient failure is unrecoverable."
  }
}

# gunicorn opens /var/log/timesketch/wsgi_error.log at startup and exits if the
# directory is missing, crash-looping the web container. Upstream mounts this
# (TIMESKETCH_LOGS_PATH); omitting it was observed during Phase 1 acceptance.
run "timesketch_logs_directory_is_mounted" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = strcontains(local.docker_compose, "/mnt/data/logs:/var/log/timesketch")
    error_message = "Timesketch needs its log directory mounted or gunicorn exits on startup."
  }

  assert {
    condition     = strcontains(aws_instance.appliance.user_data, "/mnt/data/logs")
    error_message = "cloud-init must create the logs directory on the data volume."
  }
}

# set -x is on throughout cloud-init, so a generated password would otherwise be
# written to /var/log/cloud-init-output.log in plaintext.
run "responder_passwords_do_not_reach_the_cloud_init_log" {
  command = plan
  variables {
    posture    = "active"
    responders = ["alice"]
  }

  assert {
    condition     = strcontains(aws_instance.appliance.user_data, "set +x")
    error_message = "Tracing must be disabled around secret handling or passwords land in cloud-init logs."
  }
}

# The reactivation path is the one that bites. On dormant -> active the instance
# already exists, so only aws_ec2_instance_state changes; without an explicit
# dependency Terraform starts it before the endpoints are back, the SSM agent
# finds no route and hibernates for up to an hour.
run "instance_state_waits_for_endpoints_on_reactivation" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 8
    error_message = "Activation must create the endpoints the instance start depends on."
  }

  assert {
    condition     = aws_ec2_instance_state.appliance.state == "running"
    error_message = "Active posture must run the appliance."
  }
}

# Dormancy destroys the endpoints; activation recreates them. The SSM agent
# starts before the new ENI forwards packets, hibernates, and backs off for up to
# an hour. Terraform ordering does not fix it (the endpoint reports "available"
# before it is usable), and cloud-init does not re-run on stop/start - so the
# guard must be a systemd unit that fires on every boot.
run "ssm_agent_recovers_on_every_reactivation" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = strcontains(aws_instance.appliance.user_data, "ssm-endpoint-wait.service")
    error_message = "A boot-time unit must restart the SSM agent once its endpoint is reachable, or reactivation can take an hour."
  }

  assert {
    condition     = strcontains(aws_instance.appliance.user_data, "systemctl enable ssm-endpoint-wait.service")
    error_message = "The unit must be enabled so it runs on stop/start, not just on first boot."
  }
}
