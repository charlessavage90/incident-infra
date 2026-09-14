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

variable "posture" {
  type        = string
  description = "active or dormant. Defaults to dormant so a forgotten apply costs nothing."
  default     = "dormant"
}

variable "instance_type" {
  type        = string
  description = "Per-incident dial. Raise for a large case, drop back afterwards."
  default     = "r6i.large"
}

variable "responders" {
  type        = list(string)
  description = "Timesketch usernames to provision."
  default     = []
}

data "terraform_remote_state" "platform" {
  backend = "local"
  config  = { path = "../platform/terraform.tfstate" }
}

locals {
  p = data.terraform_remote_state.platform.outputs.platform
}

module "analysis" {
  source = "../../../modules/analysis"

  posture       = var.posture
  instance_type = var.instance_type
  responders    = var.responders

  name_prefix                     = local.p.name_prefix
  vpc_id                          = local.p.vpc_id
  vpc_cidr                        = local.p.vpc_cidr
  private_subnet_ids              = local.p.private_subnet_ids
  data_volume_id                  = local.p.data_volume_id
  data_volume_availability_zone   = local.p.data_volume_availability_zone
  kms_key_arn                     = local.p.kms_key_arn
  appliance_instance_profile_name = local.p.appliance_instance_profile_name
  appliance_security_group_id     = local.p.appliance_security_group_id
  private_zone_id                 = local.p.private_zone_id
  private_zone_name               = local.p.private_zone_name
  image_digest_parameter_prefix   = "/${local.p.name_prefix}/images"

  tags = {
    Environment = "development"
  }
}

output "ssm_port_forward_command" {
  value = module.analysis.ssm_port_forward_command
}

output "appliance_instance_id" {
  value = module.analysis.appliance_instance_id
}

output "responder_secret_ids" {
  value = module.analysis.responder_secret_ids
}
