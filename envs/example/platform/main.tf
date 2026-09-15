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
