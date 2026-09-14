output "mirror_project_name" {
  value       = aws_codebuild_project.mirror.name
  description = "Run with: aws codebuild start-build --project-name <this>"
}

output "image_digest_parameter_prefix" {
  value       = "/${var.name_prefix}/images"
  description = "SSM path holding repo@digest references for every mirrored image."
}
