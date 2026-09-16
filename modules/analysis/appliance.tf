data "aws_subnet" "appliance" {
  id = var.private_subnet_ids[0]
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

# Digest-pinned image references published by the images module (spec 4.5).
data "aws_ssm_parameter" "image" {
  for_each = toset(["timesketch", "opensearch", "postgres", "redis", "plaso-worker"])
  name     = "${var.image_digest_parameter_prefix}/${each.key}"
}

locals {
  # Upstream rule from Timesketch config.env: RAM / 2, capped at 32GB.
  instance_memory_gb = {
    "r6i.large"   = 16
    "r6i.xlarge"  = 32
    "r6i.2xlarge" = 64
    "r6i.4xlarge" = 128
  }

  instance_vcpus = {
    "r6i.large"   = 2
    "r6i.xlarge"  = 4
    "r6i.2xlarge" = 8
    "r6i.4xlarge" = 16
  }

  opensearch_heap_gb = min(32, floor(lookup(local.instance_memory_gb, var.instance_type, 16) / 2))

  # Upstream rule from Timesketch config.env: (num cores * 2) + 1
  num_wsgi_workers = (lookup(local.instance_vcpus, var.instance_type, 2) * 2) + 1

  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"

  # Named once. The Batch job definition, the cloud-init account creation and
  # LOCAL_AUTH_ALLOWED_USERS must all agree, and three string literals would not.
  pipeline_user = "pipeline"

  timesketch_conf = templatefile("${path.module}/templates/timesketch.conf.tftpl", {
    secret_key               = random_password.timesketch_secret_key.result
    postgres_password        = random_password.postgres.result
    local_auth_allowed_users = join(", ", [for u in var.responders : "'${u}'"])
  })

  docker_compose = templatefile("${path.module}/templates/docker-compose.yml.tftpl", {
    timesketch_image   = data.aws_ssm_parameter.image["timesketch"].value
    opensearch_image   = data.aws_ssm_parameter.image["opensearch"].value
    postgres_image     = data.aws_ssm_parameter.image["postgres"].value
    redis_image        = data.aws_ssm_parameter.image["redis"].value
    postgres_password  = random_password.postgres.result
    opensearch_heap_gb = local.opensearch_heap_gb
    num_wsgi_workers   = local.num_wsgi_workers
  })
}

resource "aws_instance" "appliance" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type

  # Must be the subnet that shares the data volume's AZ. EBS attaches only
  # within one AZ, and a mismatch fails at apply with an unhelpful error.
  subnet_id = var.private_subnet_ids[0]

  iam_instance_profile   = var.appliance_instance_profile_name
  vpc_security_group_ids = [var.appliance_security_group_id]

  # No public ingress, ever (D6).
  associate_public_ip_address = false

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_arn
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only; IMDSv1 is SSRF-exploitable
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    data_volume_id                = var.data_volume_id
    region                        = data.aws_region.current.region
    ecr_registry                  = local.ecr_registry
    image_digest_parameter_prefix = var.image_digest_parameter_prefix
    timesketch_conf               = local.timesketch_conf
    docker_compose                = local.docker_compose
    responders                    = var.responders
    name_prefix                   = var.name_prefix
  })

  # A changed template means a replaced instance. That is safe here precisely
  # because the data volume belongs to the platform layer: nothing is orphaned
  # and no evidence is lost.
  user_data_replace_on_change = true

  # Nothing in the resource graph otherwise forces the endpoints to exist before
  # the instance boots. Without this the instance can come up into a VPC with no
  # route to SSM, ECR, or Secrets Manager; cloud-init then fails and never runs
  # again, leaving a running instance with no Timesketch on it. Observed during
  # Phase 1 acceptance.
  depends_on = [aws_vpc_endpoint.interface]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-appliance" })

  lifecycle {
    # EBS attaches only within one availability zone. Without this check the
    # mismatch surfaces later, as a volume-attachment failure whose message does
    # not mention availability zones at all.
    precondition {
      condition     = data.aws_subnet.appliance.availability_zone == var.data_volume_availability_zone
      error_message = "Appliance subnet is in ${data.aws_subnet.appliance.availability_zone} but the data volume is in ${var.data_volume_availability_zone}. EBS attaches only within one AZ."
    }
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = var.data_volume_id
  instance_id = aws_instance.appliance.id

  # Without this, destroying the analysis layer hangs waiting for a graceful
  # detach that a stopped instance will never perform.
  force_detach = true
}

# Dormancy stops the instance; it never destroys it (spec 3.2).
resource "aws_ec2_instance_state" "appliance" {
  instance_id = aws_instance.appliance.id
  state       = var.posture == "active" ? "running" : "stopped"

  # This dependency matters more than the one on aws_instance, and is easy to
  # miss. On reactivation the instance already exists, so the only thing that
  # changes is this resource -- meaning without an explicit dependency Terraform
  # may start the instance before the interface endpoints are back.
  #
  # The consequence is not a slow start, it is an hour-long one: the SSM agent
  # finds no route to ssm.<region>.amazonaws.com and logs "entering hibernation
  # due to error", after which it backs off for up to an hour. For a system whose
  # entire promise is "dormant to queryable in minutes", that is the difference
  # between working and not. Observed during Phase 1 acceptance.
  depends_on = [aws_vpc_endpoint.interface]
}

# A stable name, because connector application segments should reference a name
# that survives instance replacement rather than an IP that does not (spec 3.3).
resource "aws_route53_record" "timesketch" {
  zone_id = var.private_zone_id
  name    = "timesketch.${var.private_zone_name}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.appliance.private_ip]
}
