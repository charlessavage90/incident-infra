locals {
  mirrored_images = toset(["timesketch", "opensearch", "postgres", "redis", "nginx"])
}

resource "aws_ecr_repository" "mirror" {
  for_each = local.mirrored_images

  name = "${var.name_prefix}/${each.key}"

  # Immutable tags underpin the spec 4.5 version-parity invariant: a re-push
  # must not be able to change what an existing tag resolves to.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }

  tags = local.common_tags
}

# Keep the mirror small: expire untagged layers left behind by re-pushes.
resource "aws_ecr_lifecycle_policy" "mirror" {
  for_each = aws_ecr_repository.mirror

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

# The plaso worker image (spec 4.5).
#
# Built, not mirrored: it is `FROM <timesketch>@<digest>` with log2timeline as
# the entrypoint, so it cannot join local.mirrored_images -- the mirror's
# idempotency rule is "tag exists, skip", which for a derived image would hide a
# stale base. Tagging is by the BASE digest rather than by timesketch_version,
# so a new base is always a new tag and can never be silently skipped. That is
# the mechanism that left postgres:13.0-alpine in place after the pin moved.
resource "aws_ecr_repository" "worker" {
  name                 = "${var.name_prefix}/plaso-worker"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }

  tags = local.common_tags
}

# Keep the last few builds rather than expiring untagged layers: every tag here
# is a base digest someone might need to reproduce a timeline from.
resource "aws_ecr_lifecycle_policy" "worker" {
  repository = aws_ecr_repository.worker.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the ten most recent worker builds"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
