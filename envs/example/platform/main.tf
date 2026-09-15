terraform {
  required_version = "~> 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.64.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "budget_alert_emails" {
  type        = list(string)
  description = "Set this. Idle cost is the failure mode it guards (spec 5.2.2)."
}

module "platform" {
  source = "../../../modules/platform"

  name_prefix         = "ir-dev"
  budget_alert_emails = var.budget_alert_emails
  monthly_budget_usd  = 200

  # Smaller than the 500 GB production default; this is a development deployment.
  data_volume_gb = 100

  # Phase 2. GOVERNANCE is the only safe value outside a production IR account:
  # compliance-locked objects cannot be deleted before expiry by anyone, and this
  # deployment gets torn down (spec 5.2.2).
  object_lock_mode = "GOVERNANCE"
  retention_years  = 3

  # Development deployments get torn down; the manifest here is disposable.
  # Never set this false in production.
  manifest_deletion_protection = false

  tags = {
    Environment = "development"
  }
}

output "platform" {
  value = module.platform
}

# Flattened pass-throughs.
#
# `tofu output -raw <name>` cannot reach into the object above, and every
# reference in docs/acceptance/phase-2.md, CLAUDE.md and irctl's own error
# messages assumes the flat form. Adding one here and forgetting these is
# exactly what happened once already: the acceptance run's first command failed
# with `Output "intake_bucket" not found`.

output "intake_bucket" {
  value       = module.platform.intake_bucket
  description = "export IR_INTAKE_BUCKET"
}

output "evidence_bucket" {
  value = module.platform.evidence_bucket
}

output "plaso_bucket" {
  value = module.platform.plaso_bucket
}

output "audit_bucket" {
  value = module.platform.audit_bucket
}

output "cases_table" {
  value       = module.platform.cases_table
  description = "export IR_CASES_TABLE"
}

output "artifacts_table" {
  value = module.platform.artifacts_table
}

output "retention_years" {
  value       = module.platform.retention_years
  description = "export IR_RETENTION_YEARS"
}

output "responder_policy_arn" {
  value = module.platform.responder_policy_arn
}
