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

  tags = {
    Environment = "development"
  }
}

output "platform" {
  value = module.platform
}
