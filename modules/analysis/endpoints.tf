data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  common_tags = merge(var.tags, {
    ManagedBy = "opentofu"
    Component = "ir-analysis"
    Posture   = var.posture
  })

  # Destroyed when dormant.
  #
  # These bill hourly whether used or not and are the largest avoidable dormant
  # line item (spec 3.2). Destroying them does not strand the environment:
  # starting the appliance is an EC2 control-plane call, not an SSM call, and
  # activation recreates the endpoints before any responder connects. Only the
  # interactive path depends on them.
  #
  # ecr.api and ecr.dkr are not sufficient on their own: ECR image layers are
  # fetched from S3, which is why the platform layer holds an unconditional S3
  # gateway endpoint.
  interface_endpoint_services = var.posture == "active" ? toset([
    "ssm",
    "ssmmessages",
    "ec2messages",
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
    "kms",
  ]) : toset([])
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-endpoints"
  description = "VPC interface endpoints"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-endpoints" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from within the VPC"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoint_services

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  # Without an explicit policy an endpoint is usable by any principal that can
  # reach it, including principals outside this account. Scope it to this
  # account: the IR account is deliberately isolated from the environment under
  # investigation (D2), and an endpoint open to other accounts undercuts that.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "*"
      Resource  = "*"
      Condition = {
        StringEquals = {
          "aws:PrincipalAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}" })
}
