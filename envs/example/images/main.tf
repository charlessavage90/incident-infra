terraform {
  required_version = "~> 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.64.0"
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

data "terraform_remote_state" "platform" {
  backend = "local"
  config  = { path = "../platform/terraform.tfstate" }
}

module "images" {
  source = "../../../modules/images"

  name_prefix         = data.terraform_remote_state.platform.outputs.platform.name_prefix
  ecr_repository_urls = data.terraform_remote_state.platform.outputs.platform.ecr_repository_urls
  kms_key_arn         = data.terraform_remote_state.platform.outputs.platform.kms_key_arn
}

output "mirror_project_name" {
  value = module.images.mirror_project_name
}

output "image_digest_parameter_prefix" {
  value = module.images.image_digest_parameter_prefix
}
