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
    # Packages the intake recorder. Runs locally at plan time -- no credentials,
    # no network -- so it does not break the offline test discipline.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
