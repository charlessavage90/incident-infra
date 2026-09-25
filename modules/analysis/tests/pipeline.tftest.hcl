mock_provider "aws" {
  # mock_provider invents values for computed attributes, but the AWS provider
  # VALIDATES some of them -- ARNs especially -- and rejects the invented ones.
  # Anything returned as a list must be mocked too, or it arrives empty.
  #
  # OpenTofu 1.12 has no `source` argument on mock_provider, so this block is
  # duplicated across every test file in this module. IT MUST BE KEPT IN SYNC:
  # a resource mocked in one file and not another fails only in the OTHER files,
  # with an error that names the ARN rather than the missing mock.
  #
  # Regenerate all of them rather than editing one:
  #   python scripts/sync-test-mocks.py
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

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/placeholder@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      availability_zone = "us-east-1a"
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id = "ami-00000000000000000"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
    }
  }

  # From Phase 3. The Batch compute environment validates both of these as ARNs
  # before it will plan, and neither is something this module can invent.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/ir-test-mock"
    }
  }

  mock_resource "aws_iam_instance_profile" {
    defaults = {
      arn = "arn:aws:iam::111122223333:instance-profile/ir-test-mock"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:111122223333:secret:ir-test-mock"
    }
  }

  # The Batch job queue validates the compute environment ARN it is handed, and
  # the Lambda permission validates the rule ARN. Neither error names the
  # missing mock -- both print the invented value and "cannot be parsed as an
  # ARN", which is why these are here rather than discovered one test run at a
  # time.
  mock_resource "aws_batch_compute_environment" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:111122223333:compute-environment/ir-test-mock"
    }
  }

  mock_resource "aws_batch_job_queue" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:111122223333:job-queue/ir-test-mock"
    }
  }

  mock_resource "aws_batch_job_definition" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:111122223333:job-definition/ir-test-mock:1"
    }
  }

  mock_resource "aws_sfn_state_machine" {
    defaults = {
      arn = "arn:aws:states:us-east-1:111122223333:stateMachine:ir-test-mock"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:111122223333:ir-test-mock"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:111122223333:function:ir-test-mock"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:111122223333:rule/ir-test-mock"
    }
  }
}
mock_provider "random" {}
mock_provider "archive" {}

variables {
  name_prefix                     = "ir-test"
  vpc_id                          = "vpc-00000000000000000"
  vpc_cidr                        = "10.90.0.0/16"
  private_subnet_ids              = ["subnet-00000000000000001", "subnet-00000000000000002"]
  data_volume_id                  = "vol-00000000000000000"
  data_volume_availability_zone   = "us-east-1a"
  kms_key_arn                     = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
  appliance_instance_profile_name = "ir-test-appliance"
  appliance_security_group_id     = "sg-00000000000000000"
  private_zone_id                 = "Z00000000000000000000"
  private_zone_name               = "ir.internal"
  image_digest_parameter_prefix   = "/ir-test/images"
  responders                      = ["responder"]

  evidence_bucket     = "ir-test-evidence-111122223333"
  evidence_bucket_arn = "arn:aws:s3:::ir-test-evidence-111122223333"
  plaso_bucket        = "ir-test-plaso-111122223333"
  plaso_bucket_arn    = "arn:aws:s3:::ir-test-plaso-111122223333"
  artifacts_table     = "ir-test-artifacts"
  artifacts_table_arn = "arn:aws:dynamodb:us-east-1:111122223333:table/ir-test-artifacts"
}

# Dormancy stops compute; it never destroys it (spec 3.2).
run "dormant_disables_the_compute_environment" {
  command = plan

  variables {
    posture = "dormant"
  }

  assert {
    condition     = aws_batch_compute_environment.worker.state == "DISABLED"
    error_message = "A dormant environment that still scales up EC2 defeats the whole cost argument for dormancy."
  }
}

run "active_enables_the_compute_environment" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition     = aws_batch_compute_environment.worker.state == "ENABLED"
    error_message = "An active environment whose Batch fleet is DISABLED leaves every job in RUNNABLE with no error to read."
  }
}

# The second reader of the evidence store, and the first that legitimately reads
# it (spec 5.5, amendment A7 -- restated as a boundary in amendment A12).
#
# Assert on ACTIONS, not on resources: mock_resource defaults apply to every
# instance of a type, so any assertion of the form "this policy does not mention
# the evidence bucket" passes vacuously and proves nothing.
run "worker_can_read_evidence_and_never_destroy_it" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.worker.policy).Statement :
      s if s.Sid == "ReadEvidence"
    ]) == 1
    error_message = "The worker must read evidence; the timeline is produced from the immutable copy, never from intake."
  }

  assert {
    condition = length(flatten([
      for s in jsondecode(aws_iam_role_policy.worker.policy).Statement :
      [for a in s.Action : a if startswith(a, "s3:Delete")]
    ])) == 0
    error_message = "Nothing in the pipeline deletes from a locked bucket. A keyed DeleteObject writes a delete marker that hides evidence from every read-by-key path (amendment A8)."
  }

  assert {
    condition = length(flatten([
      for s in jsondecode(aws_iam_role_policy.worker.policy).Statement :
      [for a in s.Action : a if a == "s3:PutObjectLegalHold"]
    ])) == 0
    error_message = "Legal holds are the recorder's at PUT and Phase 4's at case close. A worker that can set one can also be made to clear one."
  }
}

# Spec 4.5. The SSM parameter holds a repo@sha256 reference; a tag here would
# let the worker's plaso drift from the appliance's.
run "job_definition_references_a_digest" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition     = strcontains(jsondecode(aws_batch_job_definition.worker.container_properties).image, "@sha256:")
    error_message = "A tag reference on the path to the worker breaks the spec 4.5 parity invariant silently -- Timesketch simply rejects the .plaso months later."
  }
}

# Batch on EC2 gives no per-task isolation, so a container that can reach IMDS
# can assume the instance role. Hop limit 1 stops it at the host; the job role
# arrives over the ECS task credential endpoint instead. This is the
# compensating control for choosing EC2 over Fargate (amendment A9).
run "containers_cannot_reach_the_instance_metadata_service" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition     = one(aws_launch_template.worker.metadata_options).http_put_response_hop_limit == 1
    error_message = "This fleet handles live malware. A hop limit above 1 hands the instance role to anything running in a container."
  }

  assert {
    condition     = one(aws_launch_template.worker.metadata_options).http_tokens == "required"
    error_message = "IMDSv1 is SSRF-exploitable."
  }
}

# AWS Batch appends its ECS_CLUSTER configuration to the template's user data,
# and can only do so if it is already a MIME multipart archive. A plain script
# is replaced rather than merged: instances launch, never join the cluster, and
# jobs sit in RUNNABLE with no error anywhere.
run "launch_template_user_data_is_mime_multipart" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.worker.user_data), "Content-Type: multipart/mixed")
    error_message = "Batch cannot append its ECS_CLUSTER config to a plain shell script; the instances would never join the compute environment."
  }
}

# Spec 3.2's "ingest pipeline trigger", and A4's insistence that it is one of
# TWO triggers. Intake recording is never gated; this is.
run "dormant_disables_both_pipeline_triggers" {
  command = plan
  variables { posture = "dormant" }

  assert {
    condition     = aws_cloudwatch_event_rule.evidence_created.state == "DISABLED"
    error_message = "A dormant environment must not start executions it cannot run: the Batch fleet is DISABLED and the appliance is stopped."
  }

  assert {
    condition     = aws_cloudwatch_event_rule.sweep.state == "DISABLED"
    error_message = "The sweep would start an execution per recorded artifact every fifteen minutes against a fleet that cannot run them."
  }
}

# The whole point of the sweep existing.
run "active_enables_the_reconciler_that_drains_the_dormant_backlog" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_cloudwatch_event_rule.sweep.state == "ENABLED"
    error_message = "An artifact recorded while dormant generated its S3 event while the rule was DISABLED. That event is gone; only the sweep will ever timeline it."
  }
}

# The event pattern deliberately does NOT filter on detail.reason.
#
# The recorder's server-side copy is a CopyObject below 5 GB and a
# CompleteMultipartUpload above it, so a reason filter would silently skip
# exactly the large artifacts that most need timelining.
run "trigger_matches_every_way_the_recorder_writes" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = !strcontains(aws_cloudwatch_event_rule.evidence_created.event_pattern, "reason")
    error_message = "Filtering on detail.reason drops artifacts over 5 GB, which arrive as CompleteMultipartUpload rather than CopyObject."
  }
}

# batch:submitJob.sync is not a plain SubmitJob.
#
# Step Functions implements the .sync wait by creating a MANAGED EventBridge
# rule, so the state machine role needs events:PutRule / PutTargets /
# DescribeRule as well as the Batch actions. Without them every execution fails
# at the first Batch state with an error naming EventBridge, not Batch -- the
# same class of authorisation failure that produced all three Phase 2
# acceptance defects. Only a real execution proves the grant is sufficient;
# this asserts it is present.
run "state_machine_can_run_the_sync_pattern" {
  command = plan
  variables { posture = "active" }

  assert {
    condition = length(flatten([
      for s in jsondecode(aws_iam_role_policy.state_machine.policy).Statement :
      [for a in s.Action : a if a == "events:PutRule"]
    ])) == 1
    error_message = "batch:submitJob.sync creates a managed EventBridge rule; without events:PutRule every execution fails at the first Batch state."
  }
}

# Spec 4.3: plaso returning zero events falls back and flags for a responder.
run "zero_events_is_flagged_not_silently_recorded" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = strcontains(aws_sfn_state_machine.pipeline.definition, "needs_triage")
    error_message = "An artifact plaso found nothing in must reach a human, not sit in the manifest looking finished."
  }
}

# The claim function must not be able to start executions, and the sweep must
# not be able to read evidence. Neither touches S3 at all.
# create_before_destroy builds the replacement while the original still exists,
# and Batch compute environment names are unique.
run "compute_environment_can_be_replaced" {
  command = plan

  assert {
    condition     = aws_batch_compute_environment.worker.name_prefix == "ir-test-plaso-"
    error_message = "With create_before_destroy, a fixed name makes every replacement of the compute environment fail on a name conflict."
  }
}

run "neither_pipeline_function_can_reach_the_evidence_store" {
  command = plan
  variables { posture = "active" }

  assert {
    condition = length(flatten([
      for s in jsondecode(aws_iam_role_policy.claim.policy).Statement :
      [for a in s.Action : a if startswith(a, "s3:")]
    ])) == 0
    error_message = "The claim step resolves a digest from the manifest precisely so it never needs s3:GetObject on evidence (amendment A12)."
  }

  assert {
    condition = length(flatten([
      for s in jsondecode(aws_iam_role_policy.sweep.policy).Statement :
      [for a in s.Action : a if startswith(a, "s3:")]
    ])) == 0
    error_message = "The sweep reads the manifest and starts executions. It has no business in the evidence store."
  }
}
