data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"

  build_env = {
    NAME_PREFIX            = var.name_prefix
    IMAGE_TAG              = var.timesketch_version
    ECR_REGISTRY           = local.ecr_registry
    ECR_TIMESKETCH         = var.ecr_repository_urls["timesketch"]
    ECR_OPENSEARCH         = var.ecr_repository_urls["opensearch"]
    ECR_POSTGRES           = var.ecr_repository_urls["postgres"]
    ECR_REDIS              = var.ecr_repository_urls["redis"]
    ECR_NGINX              = var.ecr_repository_urls["nginx"]
    TIMESKETCH_VERSION     = var.timesketch_version
    OPENSEARCH_VERSION     = var.opensearch_version
    POSTGRES_VERSION       = var.postgres_version
    REDIS_VERSION          = var.redis_version
    NGINX_VERSION          = var.nginx_version
    TOOLING_BUCKET         = var.tooling_bucket
    DOCKER_COMPOSE_VERSION = var.docker_compose_version
  }
}

resource "aws_codebuild_project" "mirror" {
  name         = "${var.name_prefix}-image-mirror"
  description  = "Mirrors upstream images into ECR and publishes their digests"
  service_role = aws_iam_role.mirror.arn

  # Deliberately NOT attached to the IR VPC.
  #
  # CodeBuild's managed network has internet access; the IR VPC has none by
  # design (spec 3.3). Adding a vpc_config here would break the mirror and, with
  # it, every image the appliance depends on.

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_MEDIUM"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    # Required to run docker pull/push.
    privileged_mode = true

    dynamic "environment_variable" {
      for_each = local.build_env

      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/buildspec.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/${var.name_prefix}-image-mirror"
    }
  }
}
