# --- Attachment surface (spec 3.3) ---
#
# An organisation wires its own connector (ZPA, Tailscale, TGW, Client VPN)
# using these outputs, without editing this module. The module does not own
# connectivity (D7).
#
# These are stable across dormancy cycles by design: dormant mode never
# destroys the VPC, subnets, route tables, security groups, or private DNS,
# so a connector attaches once and survives every cycle.

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "IR VPC. Attach org-managed connectors here."
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "Private subnets. No public IPs are assigned."
}

output "vpc_cidr" {
  value       = var.vpc_cidr
  description = "VPC CIDR, for connector route configuration."
}

output "route_table_id" {
  value       = aws_route_table.private.id
  description = "Private route table, for connector route propagation."
}

output "appliance_security_group_id" {
  value       = aws_security_group.appliance.id
  description = "Authorise a connector SG on 443 via allowed_ingress_security_group_ids."
}

output "private_zone_id" {
  value       = aws_route53_zone.private.zone_id
  description = "Private hosted zone for the stable Timesketch DNS name."
}

output "private_zone_name" {
  value       = var.private_zone_name
  description = "Zone name, e.g. ir.internal."
}

# --- Consumed by modules/analysis ---

output "kms_key_arn" {
  value       = aws_kms_key.main.arn
  description = "Platform CMK."
}

output "data_volume_id" {
  value       = aws_ebs_volume.data.id
  description = "Persistent data volume. Attached by the analysis layer, owned here."
}

output "data_volume_availability_zone" {
  value       = aws_ebs_volume.data.availability_zone
  description = "The appliance must launch in this AZ to attach the volume."
}

output "appliance_instance_profile_name" {
  value       = aws_iam_instance_profile.appliance.name
  description = "Instance profile granting SSM, ECR pull, and secret read."
}

output "ecr_repository_urls" {
  value       = { for k, r in aws_ecr_repository.mirror : k => r.repository_url }
  description = "Map of image name to ECR repository URL."
}

output "name_prefix" {
  value       = var.name_prefix
  description = "Passed through so the analysis layer names resources consistently."
}
