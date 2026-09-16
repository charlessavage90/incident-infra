# The ingest pipeline (spec 4.1). Posture-gated, unlike intake recording (A4).
#
# TWO triggers, and the distinction matters:
#
#   - aws_cloudwatch_event_rule.evidence_created is the LATENCY path. An
#     artifact lands in evidence, EventBridge fires, a timeline exists in
#     seconds.
#   - aws_cloudwatch_event_rule.sweep is the CORRECTNESS path. An artifact
#     recorded while the environment was dormant produced its S3 event at a
#     moment when the rule above was DISABLED, and that event is gone. Nothing
#     else would ever timeline it.
#
# Both converge on the claim function's conditional write, so they cannot
# double-process. Dropping the first would cost latency; dropping the second
# would silently strand every artifact that arrived between incidents -- which
# is most of them, because accumulating those is what an evidence store is for.

data "archive_file" "pipeline" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/pipeline"
  output_path = "${path.module}/build/pipeline.zip"
  excludes    = ["test_handler.py", "__pycache__"]
}

# --- Notifications (spec 4.7) ---
#
# No SQS dead-letter queue. The artifact remains in the evidence bucket
# regardless of pipeline outcome, and the manifest row is the durable record of
# what happened to it -- a queue holding a copy of the same information would be
# a component to maintain with no consumer.

resource "aws_sns_topic" "pipeline" {
  name              = "${var.name_prefix}-pipeline"
  kms_master_key_id = var.kms_key_arn
  tags              = local.common_tags
}

resource "aws_sns_topic_subscription" "pipeline" {
  for_each = toset(var.pipeline_notification_emails)

  topic_arn = aws_sns_topic.pipeline.arn
  protocol  = "email"
  endpoint  = each.value
}

# --- Claim and sweep ---

resource "aws_iam_role" "claim" {
  name = "${var.name_prefix}-pipeline-claim"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "claim_logs" {
  role       = aws_iam_role.claim.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB only.
#
# The claim step resolves a missing digest by querying the manifest rather than
# reading object metadata, precisely so that s3:GetObject on the evidence bucket
# stays confined to the Batch worker (amendment A12). It also cannot start an
# execution: only the sweep does that, and only the state machine decides what
# happens next.
resource "aws_iam_role_policy" "claim" {
  name = "${var.name_prefix}-pipeline-claim"
  role = aws_iam_role.claim.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ClaimArtifact"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = var.artifacts_table_arn
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

resource "aws_iam_role" "sweep" {
  name = "${var.name_prefix}-pipeline-sweep"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "sweep_logs" {
  role       = aws_iam_role.sweep.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "sweep" {
  name = "${var.name_prefix}-pipeline-sweep"
  role = aws_iam_role.sweep.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read-only on the manifest. The sweep decides what to start; the claim
        # step inside the machine decides whether it may proceed.
        Sid      = "FindUntimelinedArtifacts"
        Effect   = "Allow"
        Action   = ["dynamodb:Scan"]
        Resource = var.artifacts_table_arn
      },
      {
        Sid      = "StartPipeline"
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = aws_sfn_state_machine.pipeline.arn
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

resource "aws_lambda_function" "claim" {
  function_name = "${var.name_prefix}-pipeline-claim"
  role          = aws_iam_role.claim.arn
  handler       = "handler.claim_handler"
  runtime       = "python3.12"

  filename         = data.archive_file.pipeline.output_path
  source_code_hash = data.archive_file.pipeline.output_base64sha256

  timeout     = 30
  memory_size = 256

  environment {
    variables = {
      ARTIFACTS_TABLE = var.artifacts_table
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "sweep" {
  function_name = "${var.name_prefix}-pipeline-sweep"
  role          = aws_iam_role.sweep.arn
  handler       = "handler.sweep_handler"
  runtime       = "python3.12"

  filename         = data.archive_file.pipeline.output_path
  source_code_hash = data.archive_file.pipeline.output_base64sha256

  # A full scan of the manifest plus one StartExecution per row. Generous,
  # because the first sweep after a long dormancy is the largest one this
  # ever does.
  timeout     = 300
  memory_size = 256

  environment {
    variables = {
      ARTIFACTS_TABLE   = var.artifacts_table
      STATE_MACHINE_ARN = aws_sfn_state_machine.pipeline.arn
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "claim" {
  name              = "/aws/lambda/${var.name_prefix}-pipeline-claim"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "sweep" {
  name              = "/aws/lambda/${var.name_prefix}-pipeline-sweep"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = local.common_tags
}

# --- The state machine ---

resource "aws_iam_role" "state_machine" {
  name = "${var.name_prefix}-pipeline"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "state_machine" {
  name = "${var.name_prefix}-pipeline"
  role = aws_iam_role.state_machine.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeClaim"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.claim.arn
      },
      {
        # SubmitJob cannot be usefully scoped to a queue and a definition
        # together without also naming every revision of the definition, which
        # changes on every image update.
        Sid      = "RunWorkers"
        Effect   = "Allow"
        Action   = ["batch:SubmitJob", "batch:DescribeJobs", "batch:TerminateJob"]
        Resource = "*"
      },
      {
        # NOT optional, and not obvious.
        #
        # batch:submitJob.sync is not a plain SubmitJob: Step Functions
        # implements the .sync wait by creating a MANAGED EventBridge rule
        # (StepFunctionsGetEventsForBatchJobsRule) to receive the job's state
        # changes. Without these three actions every execution fails at the
        # first Batch state with an error naming EventBridge, which is not where
        # anyone looks. The rule name is fixed by the service, so it can be
        # scoped tightly.
        Sid      = "ManageTheSyncPatternRule"
        Effect   = "Allow"
        Action   = ["events:PutRule", "events:PutTargets", "events:DescribeRule"]
        Resource = "arn:aws:events:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:rule/StepFunctionsGetEventsForBatchJobsRule"
      },
      {
        # Status is the machine's to write. The worker owns timeline_id and
        # event_count and nothing else, so a retried job and this machine's
        # catch handler can never disagree about what happened.
        Sid      = "RecordOutcome"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = var.artifacts_table_arn
      },
      {
        Sid      = "Notify"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.pipeline.arn
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

locals {
  # ResultPath = null on every Batch and DynamoDB state, so the claim payload
  # flows through untouched. Without it the Batch job description would replace
  # $ and the next state would have no case_id to work with.
  pipeline_definition = jsonencode({
    Comment = "Route an artifact to plaso or direct import, then into Timesketch (spec 4.1)"
    StartAt = "Claim"

    States = {
      Claim = {
        Type       = "Task"
        Resource   = aws_lambda_function.claim.arn
        ResultPath = "$"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "RecordFailure"
        }]
        Next = "Claimed"
      }

      Claimed = {
        Type = "Choice"
        Choices = [
          {
            # Deduplication: the other trigger got there first, or the artifact
            # is not in a state that may be timelined. Not an error.
            Variable      = "$.claimed"
            BooleanEquals = false
            Next          = "AlreadyHandled"
          },
          {
            Variable     = "$.route"
            StringEquals = "plaso"
            Next         = "Timeline"
          },
        ]
        Default = "ImportEvidence"
      }

      AlreadyHandled = { Type = "Succeed" }

      Timeline = {
        Type     = "Task"
        Resource = "arn:aws:states:::batch:submitJob.sync"
        Parameters = {
          "JobName.$"   = "States.Format('timeline-{}', $.sha256)"
          JobQueue      = aws_batch_job_queue.worker.arn
          JobDefinition = aws_batch_job_definition.worker.arn
          ContainerOverrides = {
            "Command.$" = "States.Array('timeline', '--case-id', $.case_id, '--sha256', $.sha256, '--evidence-key', $.evidence_key)"
          }
        }
        ResultPath = null
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "RecordFailure"
        }]
        Next = "ImportPlaso"
      }

      ImportPlaso = {
        Type     = "Task"
        Resource = "arn:aws:states:::batch:submitJob.sync"
        Parameters = {
          "JobName.$"   = "States.Format('import-{}', $.sha256)"
          JobQueue      = aws_batch_job_queue.worker.arn
          JobDefinition = aws_batch_job_definition.worker.arn
          ContainerOverrides = {
            "Command.$" = "States.Array('import', '--case-id', $.case_id, '--sha256', $.sha256, '--key', $.plaso_key, '--bucket-kind', 'plaso')"
          }
        }
        ResultPath = null
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "RecordFailure"
        }]
        Next = "ReadEventCount"
      }

      # Spec 4.3's second route. plaso has no generic CSV or JSON parser, so
      # arbitrary tabular data goes straight to Timesketch, whose import maps
      # columns onto message / datetime / timestamp_desc.
      ImportEvidence = {
        Type     = "Task"
        Resource = "arn:aws:states:::batch:submitJob.sync"
        Parameters = {
          "JobName.$"   = "States.Format('import-{}', $.sha256)"
          JobQueue      = aws_batch_job_queue.worker.arn
          JobDefinition = aws_batch_job_definition.worker.arn
          ContainerOverrides = {
            "Command.$" = "States.Array('import', '--case-id', $.case_id, '--sha256', $.sha256, '--key', $.evidence_key, '--bucket-kind', 'evidence')"
          }
        }
        ResultPath = null
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "RecordFailure"
        }]
        Next = "ReadEventCount"
      }

      # The worker wrote event_count; read it back rather than threading it
      # through the Batch job description, which carries no application output.
      ReadEventCount = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:dynamodb:getItem"
        Parameters = {
          TableName = var.artifacts_table
          Key = {
            case_id = { "S.$" = "$.case_id" }
            sha256  = { "S.$" = "$.sha256" }
          }
          ConsistentRead = true
        }
        ResultPath = "$.manifest"
        Next       = "AnyEvents"
      }

      AnyEvents = {
        Type = "Choice"
        Choices = [{
          Variable     = "$.manifest.Item.event_count.N"
          StringEquals = "0"
          Next         = "FlagForTriage"
        }]
        Default = "Finalize"
      }

      # Spec 4.3: plaso returning zero events falls back and flags for a
      # responder. Recording it as finished would leave an artifact nobody looks
      # at again, which is worse than a failure -- a failure is at least loud.
      FlagForTriage = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.artifacts_table
          Key = {
            case_id = { "S.$" = "$.case_id" }
            sha256  = { "S.$" = "$.sha256" }
          }
          UpdateExpression         = "SET #s = :status, custody = list_append(custody, :event)"
          ExpressionAttributeNames = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":status" = { S = "needs_triage" }
            ":event"  = { L = [{ "S.$" = "States.Format('{} imported with zero events; needs a responder', $$.State.EnteredTime)" }] }
          }
        }
        ResultPath = null
        Next       = "NotifyTriage"
      }

      NotifyTriage = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.pipeline.arn
          "Subject.$" = "States.Format('IR pipeline: {} produced no events', $.case_id)"
          "Message.$" = "States.JsonToString($)"
        }
        End = true
      }

      Finalize = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.artifacts_table
          Key = {
            case_id = { "S.$" = "$.case_id" }
            sha256  = { "S.$" = "$.sha256" }
          }
          UpdateExpression         = "SET #s = :status, custody = list_append(custody, :event)"
          ExpressionAttributeNames = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":status" = { S = "timelined" }
            ":event"  = { L = [{ "S.$" = "States.Format('{} timelined by the ingest pipeline', $$.State.EnteredTime)" }] }
          }
        }
        ResultPath = null
        Next       = "NotifyDone"
      }

      NotifyDone = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.pipeline.arn
          "Subject.$" = "States.Format('IR pipeline: {} timelined', $.case_id)"
          "Message.$" = "States.JsonToString($)"
        }
        End = true
      }

      # Spec 4.7: the artifact remains in the evidence bucket regardless of
      # pipeline outcome. A processing failure must never lose the thing a
      # responder was given.
      RecordFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.artifacts_table
          Key = {
            case_id = { "S.$" = "$.case_id" }
            sha256  = { "S.$" = "$.sha256" }
          }
          UpdateExpression         = "SET #s = :status, custody = list_append(custody, :event)"
          ExpressionAttributeNames = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":status" = { S = "failed" }
            ":event"  = { L = [{ "S.$" = "States.Format('{} pipeline failed', $$.State.EnteredTime)" }] }
          }
        }
        ResultPath = null
        Next       = "NotifyFailure"
      }

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.pipeline.arn
          "Subject.$" = "States.Format('IR pipeline FAILED: {}', $.case_id)"
          "Message.$" = "States.JsonToString($)"
        }
        Next = "Failed"
      }

      Failed = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "See the artifact's manifest row and the Batch job logs. The artifact is still in evidence, recorded and under legal hold."
      }
    }
  })
}

resource "aws_sfn_state_machine" "pipeline" {
  name       = "${var.name_prefix}-pipeline"
  role_arn   = aws_iam_role.state_machine.arn
  definition = local.pipeline_definition

  tags = local.common_tags
}

# --- Trigger 1: latency ---

resource "aws_cloudwatch_event_rule" "evidence_created" {
  name        = "${var.name_prefix}-evidence-created"
  description = "Start the ingest pipeline when the recorder files an artifact"

  # Spec 3.2's posture-gated pipeline trigger. Intake recording is NOT gated;
  # that is amendment A4's whole point, and it lives in modules/platform.
  state = var.posture == "active" ? "ENABLED" : "DISABLED"

  # No filter on detail.reason, deliberately. The recorder's server-side copy is
  # a CopyObject below 5 GB and a CompleteMultipartUpload above it, so a reason
  # filter would silently skip exactly the large artifacts.
  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [var.evidence_bucket] }
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "evidence_created" {
  rule     = aws_cloudwatch_event_rule.evidence_created.name
  arn      = aws_sfn_state_machine.pipeline.arn
  role_arn = aws_iam_role.events.arn

  # Named evidence_key_ENCODED because S3 delivers keys URL-encoded here just as
  # it does through a bucket notification. The sweep path reads raw keys out of
  # DynamoDB, so the claim function must be able to tell the two apart rather
  # than guess -- decoding a raw key would corrupt any containing '+' or '%'.
  input_transformer {
    input_paths = {
      key = "$.detail.object.key"
    }
    input_template = "{\"evidence_key_encoded\": <key>}"
  }
}

# --- Trigger 2: correctness ---

resource "aws_cloudwatch_event_rule" "sweep" {
  name                = "${var.name_prefix}-pipeline-sweep"
  description         = "Timeline any recorded artifact the low-latency trigger never saw"
  schedule_expression = "rate(${var.sweep_interval_minutes} minutes)"
  state               = var.posture == "active" ? "ENABLED" : "DISABLED"

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "sweep" {
  rule = aws_cloudwatch_event_rule.sweep.name
  arn  = aws_lambda_function.sweep.arn
}

resource "aws_lambda_permission" "sweep" {
  statement_id  = "AllowScheduledSweep"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sweep.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sweep.arn
}

resource "aws_iam_role" "events" {
  name = "${var.name_prefix}-pipeline-events"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "events.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "events" {
  name = "${var.name_prefix}-pipeline-events"
  role = aws_iam_role.events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "StartPipeline"
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = aws_sfn_state_machine.pipeline.arn
    }]
  })
}
