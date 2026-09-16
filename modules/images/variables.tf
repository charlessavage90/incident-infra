variable "name_prefix" {
  type        = string
  description = "Prefix from the platform layer."
}

variable "ecr_repository_urls" {
  type        = map(string)
  description = "Map of image name to ECR repository URL, from the platform layer."

  validation {
    condition = alltrue([
      for k in ["timesketch", "opensearch", "postgres", "redis", "nginx", "plaso-worker"] :
      contains(keys(var.ecr_repository_urls), k)
    ])
    error_message = "ecr_repository_urls must contain timesketch, opensearch, postgres, redis, nginx, and plaso-worker."
  }
}

variable "kms_key_arn" {
  type        = string
  description = "Platform CMK, from the platform layer."
}

# These MUST match https://github.com/google/timesketch/blob/master/docker/release/config.env
# exactly. Drift here is how the spec 4.5 version-parity invariant gets broken.
variable "timesketch_version" {
  type        = string
  description = "Timesketch release tag."
  default     = "20260630"
}

variable "opensearch_version" {
  type        = string
  description = "OpenSearch version, per Timesketch config.env."
  default     = "2.19.5"
}

variable "postgres_version" {
  type        = string
  description = <<-EOT
    PostgreSQL version. Timesketch's config.env pins 13.0-alpine, but that exact
    2020 patch release is not carried by ECR Public, and Docker Hub rate-limits
    anonymous pulls. 13-alpine is the same major version with six years of
    security fixes. Major version is what Timesketch compatibility depends on;
    the parity invariant in spec 4.5 concerns the Timesketch image, not this one.
  EOT
  default     = "13-alpine"
}

variable "redis_version" {
  type        = string
  description = "Redis version, per Timesketch config.env."
  default     = "7.2.11-alpine"
}

variable "nginx_version" {
  type        = string
  description = "nginx version, per Timesketch config.env."
  default     = "1.25.5-alpine-slim"
}

variable "tooling_bucket" {
  type        = string
  description = "Bucket for mirrored tooling binaries, from the platform layer."
}

variable "docker_compose_version" {
  type        = string
  description = "Docker Compose v2 release to mirror. AL2023 packages no compose plugin."
  default     = "v5.5.1"
}
