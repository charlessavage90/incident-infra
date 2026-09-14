mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  # The provider validates service_role as an ARN and rejects an invented one.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/ir-test-image-mirror"
    }
  }
}

variables {
  name_prefix = "ir-test"
  ecr_repository_urls = {
    timesketch = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/timesketch"
    opensearch = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/opensearch"
    postgres   = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/postgres"
    redis      = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/redis"
    nginx      = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/nginx"
  }
  kms_key_arn    = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
  tooling_bucket = "ir-test-tooling-111122223333"
}

# The IR VPC has no route to the internet. CodeBuild's managed network does.
# Attaching this project to the VPC would break the mirror entirely.
run "mirror_runs_outside_the_vpc" {
  command = plan

  assert {
    condition     = length(aws_codebuild_project.mirror.vpc_config) == 0
    error_message = "The mirror must run outside the IR VPC (spec 3.3)."
  }
}

run "mirror_can_run_docker" {
  command = plan

  assert {
    condition     = aws_codebuild_project.mirror.environment[0].privileged_mode == true
    error_message = "Pulling and pushing images requires privileged mode."
  }
}

# These must match google/timesketch docker/release/config.env exactly. Drift
# here is how the spec 4.5 version-parity invariant gets broken.
run "image_versions_match_upstream_config_env" {
  command = plan

  assert {
    condition     = var.timesketch_version == "20260630"
    error_message = "Timesketch version must match upstream config.env exactly."
  }

  assert {
    condition     = var.opensearch_version == "2.19.5"
    error_message = "OpenSearch version must match upstream config.env exactly."
  }

  assert {
    condition     = var.postgres_version == "13-alpine"
    error_message = "PostgreSQL must be major version 13. Exact 13.0-alpine is unavailable on a non-rate-limited registry."
  }

  assert {
    condition     = var.redis_version == "7.2.11-alpine"
    error_message = "Redis version must match upstream config.env exactly."
  }

  assert {
    condition     = var.nginx_version == "1.25.5-alpine-slim"
    error_message = "nginx version must match upstream config.env exactly."
  }
}

run "mirror_publishes_digests_under_the_deployment_prefix" {
  command = plan

  assert {
    condition     = output.image_digest_parameter_prefix == "/ir-test/images"
    error_message = "Digest parameters must live under /<name_prefix>/images."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.mirror.policy, "parameter/ir-test/images/*")
    error_message = "The mirror may write only its own deployment's image parameters."
  }
}

# The buildspec resolves every tag to a digest and publishes repo@sha256:...
# A tag reference reaching the appliance would defeat the parity invariant.
run "mirror_is_idempotent_and_avoids_docker_hub" {
  command = plan

  assert {
    condition     = strcontains(aws_codebuild_project.mirror.source[0].buildspec, "already mirrored")
    error_message = "Tags are IMMUTABLE, so the mirror must skip images it has already pushed or a re-run fails."
  }

  assert {
    condition     = !strcontains(aws_codebuild_project.mirror.source[0].buildspec, "\"postgres:$POSTGRES_VERSION\"")
    error_message = "Images must come from ECR Public, not Docker Hub, which rate-limits anonymous pulls."
  }

  assert {
    condition     = strcontains(aws_codebuild_project.mirror.source[0].buildspec, "public.ecr.aws")
    error_message = "Images must be sourced from ECR Public."
  }
}

run "buildspec_resolves_tags_to_digests" {
  command = plan

  assert {
    condition     = strcontains(aws_codebuild_project.mirror.source[0].buildspec, "imageDigest")
    error_message = "The buildspec must resolve tags to digests via describe-images."
  }

  assert {
    condition     = strcontains(aws_codebuild_project.mirror.source[0].buildspec, "put-parameter")
    error_message = "The buildspec must publish resolved digests to SSM."
  }
}

# AL2023 packages no Docker Compose and this VPC has no internet route, so the
# binary is mirrored here and served over the S3 gateway endpoint. Upstream's
# published checksum is verified both on mirror and on install.
run "mirror_brings_in_docker_compose" {
  command = plan

  assert {
    condition     = strcontains(aws_codebuild_project.mirror.source[0].buildspec, "docker-compose-linux-x86_64.sha256")
    error_message = "The mirror must fetch and verify upstream's published checksum."
  }

  assert {
    condition     = strcontains(aws_codebuild_project.mirror.source[0].buildspec, "docker-compose-sha256")
    error_message = "The mirror must publish the checksum so the appliance can verify what it downloads."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.mirror.policy, "ir-test-tooling-111122223333")
    error_message = "The mirror must be able to write to the tooling bucket."
  }
}
