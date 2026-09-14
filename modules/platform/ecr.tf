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
