data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# The worker's build context, staged in S3.
#
# CodeBuild here is NO_SOURCE with an inline buildspec, so there is no checkout
# to build from. Rendering these through templatefile() would be worse than it
# looks: every ${...} in the Python would be interpolated by OpenTofu and the
# plan would fail naming the template rather than the line. Uploading them keeps
# worker.py a real file with real pytest tests, and reuses the Phase 1
# CodeBuild -> S3 path that CLAUDE.md nominates for exactly this.
#
# The path reaches outside the module deliberately: spec 7 puts the container
# source at the repository root, and duplicating it under modules/ would give
# the parity invariant two places to drift.
locals {
  worker_source_prefix = "plaso-worker/src"

  worker_source_files = {
    "worker.py"            = "${path.module}/../../containers/plaso-worker/worker.py"
    "timesketch_client.py" = "${path.module}/../../containers/plaso-worker/timesketch_client.py"
    "Dockerfile"           = "${path.module}/../../containers/plaso-worker/Dockerfile"
  }
}

resource "aws_s3_object" "worker_source" {
  for_each = local.worker_source_files

  bucket = var.tooling_bucket
  key    = "${local.worker_source_prefix}/${each.key}"
  source = each.value

  # source_hash, not etag. The tooling bucket is KMS-encrypted and S3 does not
  # return an MD5 etag for a KMS-encrypted object, so an etag here would show a
  # diff on every plan forever. Without either, an edited worker.py would be
  # uploaded once and never refreshed -- and would build into an image still
  # carrying the old one.
  source_hash = filemd5(each.value)
}

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
    ECR_PLASO_WORKER       = var.ecr_repository_urls["plaso-worker"]
    WORKER_SOURCE_PREFIX   = local.worker_source_prefix
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
