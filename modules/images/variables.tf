variable "name_prefix" {
  type        = string
  description = "Prefix from the platform layer."
}

variable "ecr_repository_urls" {
  type        = map(string)
  description = "Map of image name to ECR repository URL, from the platform layer."

  validation {
    condition = alltrue([
      for k in ["timesketch", "opensearch", "postgres", "redis", "nginx"] :
      contains(keys(var.ecr_repository_urls), k)
    ])
    error_message = "ecr_repository_urls must contain timesketch, opensearch, postgres, redis, and nginx."
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
  description = "PostgreSQL version, per Timesketch config.env."
  default     = "13.0-alpine"
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
