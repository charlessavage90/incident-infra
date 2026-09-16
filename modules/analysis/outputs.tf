output "appliance_instance_id" {
  value       = aws_instance.appliance.id
  description = "Use with: aws ssm start-session --target <this>"
}

output "timesketch_private_dns" {
  value       = aws_route53_record.timesketch.name
  description = "Stable name for org-managed connector application segments."
}

output "posture" {
  value       = var.posture
  description = "Current posture."
}

output "ssm_port_forward_command" {
  value = join(" ", [
    "aws ssm start-session",
    "--target ${aws_instance.appliance.id}",
    "--document-name AWS-StartPortForwardingSession",
    "--parameters '{\"portNumber\":[\"5000\"],\"localPortNumber\":[\"5000\"]}'",
  ])
  description = "Run this, then open http://localhost:5000"
}

output "responder_secret_ids" {
  value       = { for k, s in aws_secretsmanager_secret.responder : k => s.name }
  description = "Retrieve a login with: aws secretsmanager get-secret-value --secret-id <this>"
}

# --- Phase 3: the ingest pipeline ---

output "state_machine_arn" {
  value       = aws_sfn_state_machine.pipeline.arn
  description = "Ingest pipeline. Start one by hand with: aws stepfunctions start-execution --state-machine-arn <this> --input '{\"case_id\":\"...\",\"sha256\":\"...\",\"evidence_key\":\"...\"}'"
}

output "job_queue_arn" {
  value       = aws_batch_job_queue.worker.arn
  description = "plaso job queue. Stays ENABLED while dormant so a submitted job waits rather than being rejected."
}

output "pipeline_topic_arn" {
  value       = aws_sns_topic.pipeline.arn
  description = "Pipeline notifications: timelined, needs_triage, failed."
}
