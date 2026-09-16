# The intake recorder (spec 5.5).
#
# Deliberately not posture-gated and deliberately outside the VPC. The pipeline
# that timelines an artifact needs a running appliance and is gated in
# modules/analysis; recording one needs S3, DynamoDB and KMS, none of which
# dormancy touches. "The environment was asleep" is not an answer to "why is this
# artifact not in the manifest".

data "archive_file" "intake" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/intake"
  output_path = "${path.module}/build/intake.zip"
  excludes    = ["test_handler.py", "__pycache__"]
}

resource "aws_iam_role" "intake" {
  name = "${var.name_prefix}-intake-recorder"

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

resource "aws_iam_role_policy_attachment" "intake_logs" {
  role       = aws_iam_role.intake.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# s3:GetObject appears exactly once, scoped to intake, and must stay that way.
#
# It is not optional and an earlier draft that omitted it did not work: IAM has
# no s3:HeadObject action -- HeadObject is authorised by s3:GetObject -- and
# CopyObject requires "s3:GetObject permission to read the source object that is
# being copied". The recorder 403'd on HeadObject on its first real invocation
# during Phase 2 acceptance.
#
# The property that survives, and the one that actually matters, is the
# asymmetry: read on intake, write-and-lock on evidence, no read on evidence
# ever. Object bytes still never pass through the function -- HeadObject returns
# metadata and the copy is executed server-side by S3 -- so a recorder outside
# the VPC still cannot exfiltrate the evidence store. Adding a read action to
# WriteEvidenceUnderHold is what would break that argument.
resource "aws_iam_role_policy" "intake" {
  name = "${var.name_prefix}-intake-recorder"
  role = aws_iam_role.intake.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadIntakeMetadata"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectAttributes", "s3:GetObjectVersionAttributes"]
        Resource = "${aws_s3_bucket.intake.arn}/*"
      },
      {
        Sid      = "ClearIntakeOnceRecorded"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = "${aws_s3_bucket.intake.arn}/*"
      },
      {
        Sid    = "WriteEvidenceUnderHold"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectLegalHold",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.evidence.arn}/*"
      },
      {
        Sid      = "RecordCustody"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.artifacts.arn
      },
      {
        Sid      = "ReadCaseState"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = aws_dynamodb_table.cases.arn
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = aws_kms_key.main.arn
      },
      {
        # X-Ray segment upload cannot be resource-scoped.
        Sid      = "XRayTracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "intake" {
  function_name = "${var.name_prefix}-intake-recorder"
  role          = aws_iam_role.intake.arn
  handler       = "handler.handler"
  runtime       = "python3.12"

  filename         = data.archive_file.intake.output_path
  source_code_hash = data.archive_file.intake.output_base64sha256

  # The server-side copy of a large artifact needs the whole window.
  #
  # 900 seconds stays, and amendment A10 explains why it is not moved to Batch:
  # Batch is posture-gated and recording must never be. Moving it would have
  # left an artifact arriving between incidents in intake with a seven-day
  # expiry and no legal hold.
  #
  # Memory is 2 GB not because the function needs the heap -- it streams nothing
  # and holds no object bytes -- but because Lambda scales NETWORK bandwidth
  # with memory, and the tuned TransferConfig in handler.py cannot drive a
  # 256 MB function's allowance. The pair only works together; changing one
  # without the other wastes the change.
  timeout     = 900
  memory_size = 2048

  # The server-side copy is the least observable thing here -- it is one boto3
  # call that fans out into UploadPartCopy above 5 GB, across two buckets with
  # different encryption contexts. When it fails, the CloudWatch log line alone
  # does not say which leg failed. Tracing costs pennies at this invocation rate.
  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      EVIDENCE_BUCKET = aws_s3_bucket.evidence.bucket
      CASES_TABLE     = aws_dynamodb_table.cases.name
      ARTIFACTS_TABLE = aws_dynamodb_table.artifacts.name
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_permission" "intake" {
  statement_id  = "AllowIntakeBucketInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.intake.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.intake.arn
}

resource "aws_s3_bucket_notification" "intake" {
  bucket = aws_s3_bucket.intake.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.intake.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.intake]
}

resource "aws_cloudwatch_log_group" "intake" {
  name              = "/aws/lambda/${var.name_prefix}-intake-recorder"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.main.arn
  tags              = local.common_tags
}
