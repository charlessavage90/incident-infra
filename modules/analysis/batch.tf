# The plaso fleet (D14, re-argued as amendment A9; spec 4.6).
#
# Batch on EC2 on-demand. D14's original reasoning leaned partly on Fargate's
# 200 GiB ephemeral cap, which no longer holds -- Fargate attaches EBS at task
# launch. The live argument is I/O: plaso is disk-bound, D8 targets 100 GB to
# 1 TB per incident, and instance-store NVMe is both faster than a per-task
# network volume and included in the instance price.
#
# What EC2 costs is Fargate's per-task microVM isolation, which matters for a
# fleet that processes live malware. It is bought back two ways: a job sized to
# a whole instance, so two cases never share a kernel, and an IMDS hop limit of
# 1, so a container cannot reach the instance role.
#
# On-demand rather than Spot, unchanged from D14: incidents are infrequent, and
# a reclaim partway through a multi-hour disk image costs more in incident time
# than the discount saves. At zero desired vCPUs this fleet costs nothing, which
# is why dormancy only has to DISABLE it rather than destroy it.

resource "aws_security_group" "worker" {
  name        = "${var.name_prefix}-worker"
  description = "plaso workers. Reaches VPC endpoints and the appliance; this VPC has no internet route."
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-worker" })
}

# "All egress" here reaches VPC endpoints, the appliance, and nothing else.
# There is no internet gateway and no NAT (spec 3.3), which is the actual
# control; narrowing this to endpoint prefix lists would add maintenance without
# adding a boundary.
resource "aws_vpc_security_group_egress_rule" "worker_all" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "VPC endpoints and the appliance; this VPC has no internet route"
}

# The one ingress the pipeline needs. Source is the worker security group, not a
# CIDR: worker addresses are ephemeral, and a subnet CIDR would admit anything
# that ever lands in that subnet.
#
# This rule lives in the analysis layer although the group it attaches to
# belongs to platform. That is deliberate -- it references the worker group,
# which dormancy destroys along with the rest of the fleet. The platform layer's
# group survives every cycle; only the rule goes.
resource "aws_vpc_security_group_ingress_rule" "appliance_from_worker" {
  security_group_id            = var.appliance_security_group_id
  referenced_security_group_id = aws_security_group.worker.id
  from_port                    = 5000
  to_port                      = 5000
  ip_protocol                  = "tcp"
  description                  = "Timesketch REST API, for timeline import by the plaso worker"
}

# --- Roles ---

resource "aws_iam_role" "batch_instance" {
  name = "${var.name_prefix}-batch-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

# The HOST's role: join the cluster and pull images. It holds nothing about
# evidence. That separation is what the IMDS hop limit protects -- the container
# gets the job role over the ECS task credential endpoint instead, and cannot
# reach this one.
resource "aws_iam_role_policy_attachment" "batch_instance" {
  role       = aws_iam_role.batch_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "batch_instance" {
  name = "${var.name_prefix}-batch-instance"
  role = aws_iam_role.batch_instance.name
  tags = local.common_tags
}

resource "aws_iam_role" "worker" {
  name = "${var.name_prefix}-plaso-worker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

# The second reader of the evidence store (amendment A12).
#
# The recorder's asymmetry -- read on intake, write-and-lock on evidence, never
# read on evidence -- is a property of the RECORDER, not of the bucket. Nothing
# enforces anything for a second reader but this policy, so it is written to be
# read: the worker reads evidence, reads and writes .plaso, and updates two
# manifest fields. No delete of any kind, and no legal hold.
#
# s3:DeleteObject in particular would be worse than it looks: on a versioned
# bucket it writes a delete marker rather than failing, and S3 permits that over
# a legal hold (amendment A8). The bucket policy denies it and this role does
# not ask for it -- two independent reasons, which is the right number for
# something that hides evidence without destroying it.
resource "aws_iam_role_policy" "worker" {
  name = "${var.name_prefix}-plaso-worker"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadEvidence"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.evidence_bucket_arn}/*"
      },
      {
        # Read as well as write: the import job pulls back the .plaso the
        # timeline job produced.
        Sid      = "WriteAndReadPlaso"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = "${var.plaso_bucket_arn}/*"
      },
      {
        # Only timeline_id and event_count. Status belongs to the state machine,
        # so a retried job and the machine's catch handler cannot disagree.
        Sid      = "RecordTimeline"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = var.artifacts_table_arn
      },
      {
        Sid      = "ReadPipelineCredential"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.pipeline.arn
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

# --- Fleet ---

resource "aws_launch_template" "worker" {
  name        = "${var.name_prefix}-worker"
  description = "plaso workers: instance-store scratch, IMDS closed to containers"

  user_data = base64encode(templatefile("${path.module}/templates/scratch.sh.tftpl", {}))

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.worker_root_volume_gb
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = var.kms_key_arn
    }
  }

  metadata_options {
    http_tokens = "required" # IMDSv1 is SSRF-exploitable

    # One hop reaches the host and stops there. A container is two hops away, so
    # it cannot read the instance role; the job role arrives over the ECS task
    # credential endpoint instead. This is the compensating control for choosing
    # EC2 over Fargate for a fleet that handles live malware (amendment A9).
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.name_prefix}-worker" })
  }
}

resource "aws_batch_compute_environment" "worker" {
  # A prefix, not a fixed name, because of create_before_destroy below: the
  # replacement is created while the original still holds its name, and Batch
  # names are unique. A fixed name made every replacement fail on the name
  # conflict (Phase 3 acceptance, defect 3).
  name_prefix = "${var.name_prefix}-plaso-"
  type        = "MANAGED"

  # Dormancy is a variable, never a destroy (spec 3.2). DISABLED holds the fleet
  # at zero without losing the queue, the job definition, or anything a queued
  # job refers to.
  state = var.posture == "active" ? "ENABLED" : "DISABLED"

  # No service_role: Batch uses its service-linked role, AWSServiceRoleForBatch,
  # creating it on first use. A custom role created in the same apply lost an
  # IAM propagation race -- Batch assumed it before its policy attachment was
  # visible, and the environment went INVALID on ecs:DescribeClusters with no
  # retry (Phase 3 acceptance, defect 2). depends_on cannot close that window;
  # the service-linked role removes it.

  compute_resources {
    type = "EC2"

    allocation_strategy = "BEST_FIT_PROGRESSIVE"

    min_vcpus     = 0
    desired_vcpus = 0
    max_vcpus     = var.worker_max_vcpus

    instance_type      = var.worker_instance_types
    instance_role      = aws_iam_instance_profile.batch_instance.arn
    security_group_ids = [aws_security_group.worker.id]

    # Pinned to the appliance's subnet while the interface endpoints are
    # single-AZ. Spanning AZs here would strand workers in an AZ with no
    # endpoint ENI to reach ECR or Secrets Manager through; see endpoints.tf.
    subnets = [var.private_subnet_ids[0]]

    launch_template {
      launch_template_id = aws_launch_template.worker.id
      version            = "$Latest"
    }

    tags = local.common_tags
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_job_queue" "worker" {
  name     = "${var.name_prefix}-plaso"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.worker.arn
  }

  # The QUEUE stays enabled while dormant on purpose. A job submitted against a
  # disabled compute environment waits; a job submitted against a disabled queue
  # is rejected outright. Waiting is the behaviour spec 5.5 wants -- the artifact
  # is already recorded, immutable and under legal hold, and only its timeline
  # is deferred.
}

resource "aws_batch_job_definition" "worker" {
  name                  = "${var.name_prefix}-plaso-worker"
  type                  = "container"
  platform_capabilities = ["EC2"]

  # A failed job leaves the artifact in evidence regardless (spec 4.7). One
  # retry covers an ECS agent hiccup or a lost instance; beyond that the failure
  # is real and the state machine records it.
  retry_strategy {
    attempts = 2
  }

  timeout {
    # plaso over a 1 TB disk image is measured in hours. This is a ceiling
    # against a runaway parser, not a target. It is also the window after which
    # the reconciler may re-claim a row still marked `timelining` -- see
    # STALE_CLAIM_HOURS in lambda/pipeline/handler.py, which must stay in step.
    attempt_duration_seconds = 43200
  }

  container_properties = jsonencode({
    image      = data.aws_ssm_parameter.image["plaso-worker"].value
    vcpus      = var.worker_job_vcpus
    memory     = var.worker_job_memory_mib
    jobRoleArn = aws_iam_role.worker.arn

    volumes = [{
      name = "scratch"
      host = { sourcePath = "/scratch" }
    }]

    mountPoints = [{
      sourceVolume  = "scratch"
      containerPath = "/scratch"
      readOnly      = false
    }]

    environment = [
      { name = "EVIDENCE_BUCKET", value = var.evidence_bucket },
      { name = "PLASO_BUCKET", value = var.plaso_bucket },
      { name = "ARTIFACTS_TABLE", value = var.artifacts_table },
      { name = "SCRATCH_DIR", value = "/scratch" },
      { name = "TIMESKETCH_URL", value = "http://timesketch.${var.private_zone_name}:5000" },
      { name = "TIMESKETCH_USER", value = local.pipeline_user },
      { name = "TIMESKETCH_SECRET_ID", value = aws_secretsmanager_secret.pipeline.name },
      { name = "AWS_DEFAULT_REGION", value = data.aws_region.current.region },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.worker.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "plaso"
      }
    }
  })
}

# If this fails at apply with CreateLogGroup: AccessDeniedException, the CMK
# policy is missing AllowCloudWatchLogsEncrypt -- the same failure the intake
# recorder hit as Phase 2 acceptance defect 1. The error names the log group
# ARN, never the key.
resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/batch/${var.name_prefix}-plaso-worker"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = local.common_tags
}
