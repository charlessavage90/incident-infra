data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # No public IPs. Ever. (D6)
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-private-${count.index}" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-private" })
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Optional egress, off by default (spec 3.3) ---
#
# The IR VPC has no route to the internet unless an operator explicitly asks for
# one. plaso workers handle live malware; an environment with no egress cannot
# be used to exfiltrate evidence or call home. Organisations running an outbound
# connector (ZPA, Tailscale) turn this on.

resource "aws_internet_gateway" "main" {
  count = var.enable_internet_egress ? 1 : 0

  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  count = var.enable_internet_egress ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 100)
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route_table" "public" {
  count = var.enable_internet_egress ? 1 : 0

  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route" "public_igw" {
  count = var.enable_internet_egress ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main[0].id
}

resource "aws_route_table_association" "public" {
  count = var.enable_internet_egress ? 1 : 0

  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_eip" "nat" {
  count  = var.enable_internet_egress ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-nat" })
}

resource "aws_nat_gateway" "main" {
  count = var.enable_internet_egress ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]
  tags       = merge(local.common_tags, { Name = "${var.name_prefix}-nat" })
}

resource "aws_route" "private_egress" {
  count = var.enable_internet_egress ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

# --- DynamoDB gateway endpoint ---
#
# Free, like the S3 one, and in the permanent layer for the same reason: the
# Batch worker updates the artifact manifest from inside the VPC, and a control
# path that dormancy can destroy has no business in the chain of custody.
#
# No policy. Unlike S3, nothing in this design writes evidence to DynamoDB, so
# there is no cross-account exfiltration path to close here -- and an endpoint
# policy scoped to this account's tables would have to be kept in step with
# every table Phase 4 adds.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-dynamodb" })
}

# --- S3 gateway endpoint ---
#
# Free, and always present regardless of posture. ECR image layers are stored in
# S3, so ecr.api and ecr.dkr interface endpoints are not sufficient on their own.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  # Two statements, and both are load-bearing.
  #
  # The account condition is the point of having a policy at all: without it a
  # compromised instance inside this VPC could use the endpoint to copy evidence
  # into an attacker-controlled bucket in another account. From Phase 2 this
  # endpoint carries evidence, so that matters.
  #
  # But the account condition cannot be the ONLY statement, because the two
  # things this instance must fetch over S3 do not carry this account's
  # principal at all:
  #
  #   - Amazon Linux package repositories are fetched as ANONYMOUS requests.
  #     There is no principal, so the condition never matches and dnf gets 403.
  #   - ECR serves image layers via PRESIGNED URLs signed with AWS's own
  #     credentials, not the caller's, so docker pull gets 403 too.
  #
  # Both were observed during Phase 1 acceptance. The service statement below is
  # scoped to AWS-owned buckets and read-only, so it does not reopen the
  # exfiltration path the first statement closes.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ThisAccountOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = "*"
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "AwsOwnedServiceBuckets"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject"]
        Resource = [
          # Amazon Linux 2023 package repositories (anonymous)
          "arn:aws:s3:::al2023-repos-${data.aws_region.current.region}-*/*",
          "arn:aws:s3:::amazonlinux-2-repos-${data.aws_region.current.region}/*",
          "arn:aws:s3:::packages.${data.aws_region.current.region}.amazonaws.com/*",
          "arn:aws:s3:::repo.${data.aws_region.current.region}.amazonaws.com/*",
          # ECR image layers (presigned with AWS credentials)
          "arn:aws:s3:::prod-${data.aws_region.current.region}-starport-layer-bucket/*",
          # SSM agent updates
          "arn:aws:s3:::amazon-ssm-${data.aws_region.current.region}/*",
        ]
      },
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-s3" })
}

data "aws_caller_identity" "current" {}

# --- Appliance security group: the attachment surface (spec 3.3) ---
#
# An organisation authorises its own connector here via the allowed_ingress_*
# variables, without editing this module.

resource "aws_security_group" "appliance" {
  name        = "${var.name_prefix}-appliance"
  description = "Timesketch appliance. Ingress only from org-managed connectors."
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-appliance" })
}

resource "aws_vpc_security_group_ingress_rule" "appliance_https" {
  count = length(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.appliance.id
  cidr_ipv4         = var.allowed_ingress_cidrs[count.index]
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Org-managed connector"
}

resource "aws_vpc_security_group_ingress_rule" "appliance_https_sg" {
  count = length(var.allowed_ingress_security_group_ids)

  security_group_id            = aws_security_group.appliance.id
  referenced_security_group_id = var.allowed_ingress_security_group_ids[count.index]
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Org-managed connector security group"
}

# Outbound to VPC endpoints. No internet route exists unless enable_internet_egress.
resource "aws_vpc_security_group_egress_rule" "appliance_all" {
  security_group_id = aws_security_group.appliance.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound to VPC endpoints; no internet route exists by default"
}
