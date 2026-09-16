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
    # Phase 3: the pipeline's claim and sweep functions are zipped from
    # lambda/pipeline, the same way the intake recorder is in modules/platform.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
