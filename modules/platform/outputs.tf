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

# The worker repository is in this map although it is built rather than
# mirrored: modules/images needs its URL to push to, and the example
# environment passes this map wholesale. Leaving it out fails the images
# module's variable validation at apply rather than here.
output "ecr_repository_urls" {
  value = merge(
    { for k, r in aws_ecr_repository.mirror : k => r.repository_url },
    { "plaso-worker" = aws_ecr_repository.worker.repository_url },
  )
  description = "Map of image name to ECR repository URL."
}

output "name_prefix" {
  value       = var.name_prefix
  description = "Passed through so the analysis layer names resources consistently."
}

output "tooling_bucket" {
  value       = aws_s3_bucket.tooling.bucket
  description = "Mirrored tooling binaries. AL2023 has no Docker Compose package and this VPC has no internet."
}

# --- Phase 2: evidence store (spec 5) ---
#
# irctl is configured from these; so is the acceptance gate.

output "intake_bucket" {
  value       = aws_s3_bucket.intake.bucket
  description = "Upload target. Objects are recorded and removed from here automatically."
}

output "evidence_bucket" {
  value       = aws_s3_bucket.evidence.bucket
  description = "Raw artifacts under Object Lock and legal hold. Not written to directly."
}

output "plaso_bucket" {
  value       = aws_s3_bucket.plaso.bucket
  description = "Generated timelines. Written by the phase 3 pipeline."
}

output "audit_bucket" {
  value       = aws_s3_bucket.audit.bucket
  description = "CloudTrail data events over the evidence store."
}

output "cases_table" {
  value       = aws_dynamodb_table.cases.name
  description = "Case state: status, retention policy, legal hold flag."
}

output "artifacts_table" {
  value       = aws_dynamodb_table.artifacts.name
  description = "Custody chain, keyed by (case_id, sha256)."
}

output "responder_policy_arn" {
  value       = aws_iam_policy.responder.arn
  description = "Attach to responder principals. Upload and case access only."
}

output "break_glass_role_arn" {
  value       = one(aws_iam_role.break_glass[*].arn)
  description = "Holds s3:BypassGovernanceRetention. Null unless break_glass_principal_arns is set."
}

# The deployment's retention policy, consumed by irctl when it opens a case.
#
# Terraform applies nothing with this -- the clock starts at case close, which is
# phase 4 work. Exposing it is still the point: without it the policy would live
# only as a default in the CLI, and a deployment configured for seven years
# would quietly record three on every case it opened.
output "retention_years" {
  value       = var.retention_years
  description = "Years an artifact is retained after its case closes (D10). Export as IR_RETENTION_YEARS."
}

# --- Phase 3: what the pipeline layer consumes ---

output "evidence_bucket_arn" {
  value       = aws_s3_bucket.evidence.arn
  description = "Evidence bucket ARN. The Batch worker is the first component that legitimately reads it (amendment A12)."
}

output "plaso_bucket_arn" {
  value       = aws_s3_bucket.plaso.arn
  description = "Destination for .plaso files produced by the worker."
}

output "cases_table_arn" {
  value       = aws_dynamodb_table.cases.arn
  description = "Case store ARN."
}

output "artifacts_table_arn" {
  value       = aws_dynamodb_table.artifacts.arn
  description = "Artifact manifest ARN, for the claim step and the worker's finalisation."
}
