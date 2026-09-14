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

# --- S3 gateway endpoint ---
#
# Free, and always present regardless of posture. ECR image layers are stored in
# S3, so ecr.api and ecr.dkr interface endpoints are not sufficient on their own.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-s3" })
}

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
