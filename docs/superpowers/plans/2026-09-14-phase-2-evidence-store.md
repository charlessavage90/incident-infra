# Phase 2: Evidence Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An artifact can be uploaded by hand with `irctl`, is hash-verified by S3 at PUT, is recorded in a DynamoDB manifest, and lands in an Object Lock bucket under a legal hold — with nothing in the path able to re-read the evidence it handles.

**Architecture:** Everything lands in `modules/platform/`, because evidence and its manifest are permanent by definition and must not observe the posture toggle. Four S3 buckets (`intake`, `evidence`, `plaso`, `audit`), two DynamoDB tables (`cases`, `artifacts`), one Lambda that records arrivals, and a Python CLI. The Lambda runs **outside the VPC** and never calls `GetObject`; `HeadObject` reads metadata and `CopyObject` is executed server-side by S3.

**Tech Stack:** OpenTofu 1.12.6, AWS provider 6.64.0, `hashicorp/archive` ~> 2.4 (new in this phase), Python 3.12 + boto3 for both the Lambda and `irctl`, pytest + `botocore.Stubber` for CLI tests.

**Spec:** `docs/superpowers/specs/2026-09-14-ir-infrastructure-design.md` — read §4.2, §5 in full, and **§12 Amendments** before starting. A1, A3 and A4 changed load-bearing behaviour that earlier readings of that document got wrong.

## Global Constraints

Every task's requirements implicitly include this section.

- **IaC tool:** OpenTofu `1.12.6` (D16). CLI is `tofu`, never `terraform`.
- **AWS provider:** `hashicorp/aws` pinned to `6.64.0`. `.terraform.lock.hcl` is committed.
- **Policies use `jsonencode`, never `aws_iam_policy_document`.** The data source's rendered `.json` is computed, so `mock_provider` replaces it with an invented string — which fails provider validation at plan time and makes any assertion a test of the mock. This is a hard rule in this repo.
- **Every bucket and table name carries `var.name_prefix`.** Bucket names are globally unique (spec §5.2.2). Buckets additionally carry the account ID, matching the existing `aws_s3_bucket.tooling` pattern.
- **Encryption at rest uses `aws_kms_key.main`** (the platform CMK), never AWS-managed keys.
- **Object Lock buckets carry NO bucket-level default retention.** A default stamps a retain-until date at PUT; spec §5.2 requires the clock to start at case close. This is the single easiest thing in this phase to get wrong.
- **Compliance mode is never enabled in a development account** (spec §5.2.2). `var.object_lock_mode` stays `GOVERNANCE` everywhere except a real production deployment.
- **Tests use `mock_provider`** so `tofu test` runs offline with no AWS credentials and no cost.
- **`tofu test -filter` needs the OS-native path separator** — `-filter='tests\evidence.tftest.hcl'` on Windows, `-filter=tests/evidence.tftest.hcl` elsewhere. A filter matching nothing reports `Success! 0 passed, 0 failed` rather than erroring. Always check the count.
- **Assertions name the consequence, not the rule.** The failure message is what a future reader gets at 2am.
- **`set +x` around anything handling a secret** in shell. Not expected in this phase, but the rule stands.

---

## File Structure

| File | Responsibility |
|---|---|
| `modules/platform/versions.tf` | **Modify** — add the `archive` provider |
| `modules/platform/variables.tf` | **Modify** — Phase 2 inputs and the compliance-mode guard variables |
| `modules/platform/evidence.tf` | **Create** — `intake`, `evidence`, `plaso` buckets, Object Lock, lifecycle, TLS-only policy |
| `modules/platform/manifest.tf` | **Create** — `cases` and `artifacts` DynamoDB tables |
| `modules/platform/audit.tf` | **Create** — `audit` bucket, its CloudTrail bucket policy, and the data-event trail |
| `modules/platform/kms.tf` | **Modify** — explicit key policy so CloudTrail can encrypt with the CMK |
| `modules/platform/intake.tf` | **Create** — intake recorder Lambda, its role, packaging, S3 notification |
| `modules/platform/lambda/intake/handler.py` | **Create** — the recorder itself |
| `modules/platform/iam.tf` | **Modify** — responder policy and break-glass role |
| `modules/platform/outputs.tf` | **Modify** — bucket names, table names, role ARNs |
| `modules/platform/tests/evidence.tftest.hcl` | **Create** — bucket, Object Lock, and compliance-guard tests |
| `modules/platform/tests/manifest.tftest.hcl` | **Create** — DynamoDB table tests |
| `modules/platform/tests/audit.tftest.hcl` | **Create** — CloudTrail data-event tests |
| `modules/platform/tests/intake.tftest.hcl` | **Create** — Lambda placement and IAM scoping tests |
| `envs/example/platform/main.tf` | **Modify** — wire the new variables |
| `cli/pyproject.toml` | **Create** — `irctl` package metadata |
| `cli/irctl/__init__.py` | **Create** — version marker |
| `cli/irctl/digest.py` | **Create** — one-pass whole-file and per-part SHA-256 |
| `cli/irctl/cases.py` | **Create** — `case open` against the `cases` table |
| `cli/irctl/upload.py` | **Create** — checksummed single and multipart PUT |
| `cli/irctl/cli.py` | **Create** — argparse entry point |
| `cli/tests/test_digest.py` | **Create** — hashing tests, no AWS |
| `cli/tests/test_upload.py` | **Create** — `botocore.Stubber` tests |
| `cli/tests/test_cases.py` | **Create** — `botocore.Stubber` tests |
| `.github/workflows/ci.yml` | **Modify** — add the Python job |
| `docs/acceptance/phase-2.md` | **Create** — the acceptance gate |

### Decisions locked in here, with the reasoning

- **No `prevent_destroy` on the evidence buckets.** Object Lock is the protection; `prevent_destroy` would additionally block the `tofu destroy` that spec §5.2.2 explicitly expects to work in a development account via `s3:BypassGovernanceRetention`.
- **`deletion_protection_enabled` on the DynamoDB tables is behind `var.manifest_deletion_protection` (default `true`).** The manifest is the one thing here that cannot be reconstructed, so the default protects it; §5.2.2's development case needs the knob to tear down.
- **The legal hold is applied by a second API call after the copy**, not as a `CopyObject` argument. `boto3`'s managed `copy()` is needed to handle objects over 5 GB (it falls back to `UploadPartCopy`, still server-side), and its allowed-arguments list is not a place to bet the hold on. The cost is a sub-second window where the object is in `evidence` without a hold. Documented, not hidden.
- **The manifest row is written *before* the copy**, with a `status` field. That ordering gives atomic deduplication and makes a partial failure recoverable; see Task 6 for the state machine.

---

### Task 1: Phase 2 variables, evidence buckets, and the compliance-mode guard

Spec §5.1, §5.2, §5.2.1. Delivers the `evidence` and `plaso` buckets with Object Lock enabled and no default retention, plus the guard that has been specified since §5.2.1 and never built.

**Files:**
- Modify: `modules/platform/variables.tf` (append)
- Create: `modules/platform/evidence.tf`
- Test: `modules/platform/tests/evidence.tftest.hcl`

**Interfaces:**
- Consumes: `aws_kms_key.main`, `local.common_tags`, `data.aws_caller_identity.current`, `var.name_prefix` — all already exist
- Produces: `aws_s3_bucket.evidence`, `aws_s3_bucket.plaso`, `var.object_lock_mode`, `var.retention_years`, `var.acknowledge_compliance_mode_is_irreversible`

- [x] **Step 1: Write the failing test**

Create `modules/platform/tests/evidence.tftest.hcl`:

```hcl
mock_provider "aws" {
  # mock_provider invents values for computed attributes, but the AWS provider
  # validates some of them (ARNs especially) and rejects the invented ones.
  # OpenTofu 1.12 has no shared-mock `source` argument, so this block is repeated
  # in each test file in this module. Keep them in sync.
  #
  # NOTE: mock_resource defaults apply to EVERY instance of a type, so all four
  # buckets share one mocked ARN. Never assert on bucket ARN equality here --
  # assert on `.bucket`, which is configured and therefore known at plan time.
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      key_id = "11111111-2222-3333-4444-555555555555"
    }
  }

  mock_resource "aws_ecr_repository" {
    defaults = {
      arn = "arn:aws:ecr:us-east-1:111122223333:repository/ir-test/placeholder"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::ir-test-mock"
    }
  }
}
mock_provider "random" {}

variables {
  name_prefix         = "ir-test"
  budget_alert_emails = ["responder@example.com"]
}

run "evidence_bucket_has_object_lock_enabled" {
  command = plan

  assert {
    condition     = aws_s3_bucket.evidence.object_lock_enabled == true
    error_message = "Without Object Lock an artifact can be deleted before its case closes, which is the guarantee this bucket exists to make."
  }

  assert {
    condition     = aws_s3_bucket_versioning.evidence.versioning_configuration[0].status == "Enabled"
    error_message = "Object Lock requires versioning, and versioning can never be suspended afterwards."
  }
}

# Spec 5.2: the retain-until date is computed at case close, not at upload.
# A bucket-level default retention would stamp one at PUT and silently defeat
# the entire retention model.
run "evidence_bucket_has_no_default_retention" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_object_lock_configuration.evidence.rule) == 0
    error_message = "A default retention would start every artifact's clock at upload instead of at case close."
  }

  assert {
    condition     = length(aws_s3_bucket_object_lock_configuration.plaso.rule) == 0
    error_message = "Derived evidence follows the same retention model as raw evidence."
  }
}

run "evidence_buckets_are_encrypted_with_the_platform_key" {
  command = plan

  assert {
    condition     = aws_s3_bucket_server_side_encryption_configuration.evidence.rule[0].apply_server_side_encryption_by_default[0].kms_master_key_id == aws_kms_key.main.arn
    error_message = "Evidence must be encrypted with the platform CMK, not an AWS-managed key."
  }

  assert {
    condition     = aws_s3_bucket_server_side_encryption_configuration.plaso.rule[0].apply_server_side_encryption_by_default[0].kms_master_key_id == aws_kms_key.main.arn
    error_message = "Generated timelines are derived evidence and get the same key."
  }
}

run "evidence_buckets_block_public_access" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.evidence.block_public_acls,
      aws_s3_bucket_public_access_block.evidence.block_public_policy,
      aws_s3_bucket_public_access_block.evidence.ignore_public_acls,
      aws_s3_bucket_public_access_block.evidence.restrict_public_buckets,
    ])
    error_message = "There is no public ingress anywhere in this design (D6), least of all to evidence."
  }
}

# Spec 5.2.1. Compliance mode is the only irreversible action in this module:
# a locked object cannot be deleted before expiry by anyone including account
# root, and the bucket cannot be destroyed while one exists.
run "compliance_mode_requires_explicit_acknowledgement" {
  command = plan

  variables {
    object_lock_mode = "COMPLIANCE"
    # acknowledge_compliance_mode_is_irreversible deliberately left at false
  }

  expect_failures = [aws_s3_bucket.evidence]
}

run "compliance_mode_is_allowed_once_acknowledged" {
  command = plan

  variables {
    object_lock_mode                            = "COMPLIANCE"
    acknowledge_compliance_mode_is_irreversible = true
  }

  assert {
    condition     = aws_s3_bucket.evidence.object_lock_enabled == true
    error_message = "An acknowledged compliance-mode deployment must still plan cleanly."
  }
}

run "object_lock_mode_rejects_an_unknown_value" {
  command = plan

  variables {
    object_lock_mode = "guvnor"
  }

  expect_failures = [var.object_lock_mode]
}
```

- [x] **Step 2: Run the test to verify it fails**

```bash
cd modules/platform && tofu test -filter='tests\evidence.tftest.hcl'
```

Expected: FAIL — `A managed resource "aws_s3_bucket" "evidence" has not been declared`. Confirm the run count is non-zero; `0 passed, 0 failed` means the filter matched nothing and you have proved nothing.

- [x] **Step 3: Add the Phase 2 variables**

Append to `modules/platform/variables.tf`:

```hcl
# --- Phase 2: evidence store (spec 5) ---

variable "retention_years" {
  type        = number
  description = <<-EOT
    Years an artifact is retained after its case closes (D10). The clock starts at case
    close, not at upload -- see spec 5.2. Phase 2 records this on the case; phase 4's case
    close is what applies it.
  EOT
  default     = 3

  validation {
    condition     = var.retention_years >= 1 && var.retention_years <= 100
    error_message = "retention_years must be between 1 and 100."
  }
}

variable "object_lock_mode" {
  type        = string
  description = "GOVERNANCE (reversible by a break-glass role) or COMPLIANCE (irreversible)."
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be \"GOVERNANCE\" or \"COMPLIANCE\"."
  }
}

variable "acknowledge_compliance_mode_is_irreversible" {
  type        = bool
  description = <<-EOT
    Required to be true when object_lock_mode is COMPLIANCE. Compliance-locked objects cannot
    be deleted before expiry by anyone, including the account root -- AWS documents the sole
    escape as deleting the AWS account -- and the bucket cannot be destroyed while they exist,
    so `tofu destroy` fails against one. Never set this in a development or sandbox account.
  EOT
  default     = false
}

variable "intake_expiry_days" {
  type        = number
  description = <<-EOT
    Days before an object left in the intake bucket expires. Intake is a quarantine boundary,
    not storage: the recorder deletes objects it has filed, so anything still here after this
    window failed to record and should be investigated rather than kept.
  EOT
  default     = 7

  validation {
    condition     = var.intake_expiry_days >= 1
    error_message = "intake_expiry_days must be at least 1."
  }
}

variable "manifest_deletion_protection" {
  type        = bool
  description = <<-EOT
    Blocks deletion of the case and artifact tables. The manifest is the only thing in this
    design that cannot be reconstructed -- evidence can be re-hashed, a chain of custody
    cannot be re-derived. Set false only to tear down a development deployment (spec 5.2.2).
  EOT
  default     = true
}

variable "break_glass_principal_arns" {
  type        = list(string)
  description = <<-EOT
    Principals permitted to assume the break-glass role, which holds
    s3:BypassGovernanceRetention for genuine operator error -- ingesting the wrong client's
    data, for example (spec 5.2). Empty means no role is created.
  EOT
  default     = []
}
```

- [x] **Step 4: Write the evidence buckets**

Create `modules/platform/evidence.tf`:

```hcl
# The evidence store (spec 5.1).
#
# These buckets live in the permanent platform layer, like the data volume and
# for the same reason: `tofu destroy` against modules/analysis must lose nothing.
#
# Object Lock is enabled at bucket level and NO default retention is configured.
# That omission is load-bearing. A default retention stamps a retain-until date
# at PUT; spec 5.2 requires the clock to start when the case closes, which is
# what the legal-hold-then-retention sequence achieves. If you add a
# `rule { default_retention { ... } }` block below, you have silently converted
# the retention model into "N years from upload" and nothing will tell you.

locals {
  # Bucket names are globally unique, so they carry the account ID as well as
  # the prefix -- matching aws_s3_bucket.tooling.
  evidence_buckets = {
    evidence = "Raw artifacts exactly as received"
    plaso    = "Generated .plaso timelines -- derived evidence is still evidence"
  }
}

resource "aws_s3_bucket" "evidence" {
  bucket              = "${var.name_prefix}-evidence-${data.aws_caller_identity.current.account_id}"
  object_lock_enabled = true

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-evidence"
    Content = "raw-artifacts"
  })

  # Spec 5.2.1. Compliance mode is the only genuinely irreversible action in
  # this module, so it cannot be reached by editing one variable.
  lifecycle {
    precondition {
      condition     = var.object_lock_mode != "COMPLIANCE" || var.acknowledge_compliance_mode_is_irreversible
      error_message = "object_lock_mode is COMPLIANCE but acknowledge_compliance_mode_is_irreversible is false. Compliance-locked objects cannot be deleted before expiry by anyone, including the account root, and this bucket cannot be destroyed while they exist. Set the acknowledgement only in a production IR account."
    }
  }
}

resource "aws_s3_bucket" "plaso" {
  bucket              = "${var.name_prefix}-plaso-${data.aws_caller_identity.current.account_id}"
  object_lock_enabled = true

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-plaso"
    Content = "derived-timelines"
  })

  lifecycle {
    precondition {
      condition     = var.object_lock_mode != "COMPLIANCE" || var.acknowledge_compliance_mode_is_irreversible
      error_message = "object_lock_mode is COMPLIANCE but acknowledge_compliance_mode_is_irreversible is false. See the evidence bucket for the full consequence."
    }
  }
}

# Object Lock requires versioning, and versioning can never be suspended on a
# bucket that has it.
resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "plaso" {
  bucket = aws_s3_bucket.plaso.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Declared with no `rule` block on purpose. See the header comment.
resource "aws_s3_bucket_object_lock_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
}

resource "aws_s3_bucket_object_lock_configuration" "plaso" {
  bucket = aws_s3_bucket.plaso.id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "plaso" {
  bucket = aws_s3_bucket.plaso.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "plaso" {
  bucket = aws_s3_bucket.plaso.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

- [x] **Step 5: Run the test to verify it passes**

```bash
cd modules/platform && tofu test -filter='tests\evidence.tftest.hcl'
```

Expected: PASS, 6 run blocks.

- [x] **Step 6: Commit**

```bash
git add modules/platform/evidence.tf modules/platform/variables.tf modules/platform/tests/evidence.tftest.hcl
git commit -m "feat(platform): evidence and plaso buckets with the compliance-mode guard"
```

---

### Task 2: Intake bucket

Spec §5.1. The quarantine boundary. S3 verifies transfer integrity at PUT (A1), so what this bucket still buys is somewhere for a correctly-transferred artifact to be *wrong* — filed against the wrong case — before it becomes immutable.

**Files:**
- Modify: `modules/platform/evidence.tf` (append)
- Test: `modules/platform/tests/evidence.tftest.hcl` (append)

**Interfaces:**
- Consumes: `var.intake_expiry_days`, `aws_kms_key.main`
- Produces: `aws_s3_bucket.intake`

- [x] **Step 1: Write the failing test**

Append to `modules/platform/tests/evidence.tftest.hcl`:

```hcl
# Intake is a quarantine boundary, not storage. The recorder deletes what it
# files, so anything still here after the window failed and wants investigating.
run "intake_bucket_expires_its_contents" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.intake.rule).expiration[0].days == 7
    error_message = "Intake must expire, or a failed recording sits in a mutable bucket indefinitely."
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.intake.rule).abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "An abandoned multipart upload is billed storage that no listing shows. Abort it."
  }
}

# Intake is NOT Object Lock: an artifact must be deletable until it has been
# verified and filed against a real case.
run "intake_bucket_is_not_locked" {
  command = plan

  assert {
    condition     = aws_s3_bucket.intake.object_lock_enabled == false
    error_message = "Locking intake would make a mis-filed artifact permanent, which is the exact failure the quarantine exists to prevent."
  }
}

run "intake_bucket_refuses_plaintext_transport" {
  command = plan

  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.intake.policy).Statement : s if s.Sid == "DenyInsecureTransport"]) == 1
    error_message = "Evidence must not cross the wire in plaintext."
  }
}
```

- [x] **Step 2: Run the test to verify it fails**

```bash
cd modules/platform && tofu test -filter='tests\evidence.tftest.hcl'
```

Expected: FAIL — `aws_s3_bucket.intake` not declared.

- [x] **Step 3: Write the intake bucket**

Append to `modules/platform/evidence.tf`:

```hcl
# Intake: the quarantine boundary (spec 5.1).
#
# S3 verifies the client's SHA-256 at PUT (spec 4.2), so this bucket is no
# longer where transfer corruption is caught -- that never reaches storage. What
# it still catches is an artifact that transferred perfectly and is filed against
# the wrong case. Under GOVERNANCE the break-glass role can undo that; under the
# per-case COMPLIANCE mode of spec 5.2 nobody can. One server-side copy is a
# cheap price for somewhere to be wrong.
#
# Deliberately NOT Object Lock and NOT versioned: the recorder deletes what it
# has filed, and a locked intake bucket would defeat the purpose.
resource "aws_s3_bucket" "intake" {
  bucket = "${var.name_prefix}-intake-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-intake"
    Content = "unverified-landing-zone"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "intake" {
  bucket = aws_s3_bucket.intake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "intake" {
  bucket = aws_s3_bucket.intake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "intake" {
  bucket = aws_s3_bucket.intake.id

  rule {
    id     = "expire-unrecorded-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = var.intake_expiry_days
    }

    # An abandoned multipart upload is billed storage that no object listing
    # shows. Uploads here are large and interruptible, so this matters.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "intake" {
  bucket = aws_s3_bucket.intake.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.intake.arn,
          "${aws_s3_bucket.intake.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}
```

- [x] **Step 4: Run the test to verify it passes**

```bash
cd modules/platform && tofu test -filter='tests\evidence.tftest.hcl'
```

Expected: PASS, 9 run blocks.

- [x] **Step 5: Commit**

```bash
git add modules/platform/evidence.tf modules/platform/tests/evidence.tftest.hcl
git commit -m "feat(platform): intake bucket as the quarantine boundary"
```

---

### Task 3: The manifest tables

Spec §5.3. Two DynamoDB tables. The `artifacts` composite key is what makes deduplication a property of the write rather than a check before it.

**Files:**
- Create: `modules/platform/manifest.tf`
- Test: `modules/platform/tests/manifest.tftest.hcl`

**Interfaces:**
- Consumes: `aws_kms_key.main`, `var.manifest_deletion_protection`
- Produces: `aws_dynamodb_table.cases` (hash key `case_id`), `aws_dynamodb_table.artifacts` (hash key `case_id`, range key `sha256`)

- [x] **Step 1: Write the failing test**

Create `modules/platform/tests/manifest.tftest.hcl` — start with the identical `mock_provider` block from Task 1 Step 1 (copy it verbatim, including the comment; OpenTofu 1.12 has no shared-mock mechanism), then:

```hcl
variables {
  name_prefix         = "ir-test"
  budget_alert_emails = ["responder@example.com"]
}

# Spec 4.2: deduplication. A composite key of (case_id, sha256) lets the
# recorder write conditionally on attribute_not_exists(sha256), which makes
# "have I seen this before" atomic. A read-then-write check is not: two
# concurrent recorder invocations on the same artifact would both pass the read.
run "artifacts_are_keyed_by_case_and_digest" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.artifacts.hash_key == "case_id"
    error_message = "Deduplication is scoped within a case: the same file on two engagements is two custody chains."
  }

  assert {
    condition     = aws_dynamodb_table.artifacts.range_key == "sha256"
    error_message = "The digest must be the sort key, so a conditional write gives atomic deduplication."
  }
}

run "cases_are_keyed_by_case_id" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.cases.hash_key == "case_id"
    error_message = "Case state is looked up by case ID on every intake."
  }
}

# The manifest is the only thing here that cannot be reconstructed. Evidence can
# be re-hashed; a chain of custody cannot be re-derived.
run "manifest_survives_accidents" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.cases.point_in_time_recovery[0].enabled
    error_message = "A custody chain cannot be re-derived, so it needs point-in-time recovery."
  }

  assert {
    condition     = aws_dynamodb_table.artifacts.point_in_time_recovery[0].enabled
    error_message = "A custody chain cannot be re-derived, so it needs point-in-time recovery."
  }

  assert {
    condition     = aws_dynamodb_table.cases.deletion_protection_enabled
    error_message = "Deletion protection defaults on; spec 5.2.2's development teardown turns it off deliberately."
  }
}

run "manifest_is_encrypted_with_the_platform_key" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.artifacts.server_side_encryption[0].kms_key_arn == aws_kms_key.main.arn
    error_message = "The manifest names artifacts and cases; it takes the platform CMK, not an AWS-managed key."
  }
}

# Incidents are infrequent and the tables hold hundreds of rows. Provisioned
# capacity would bill continuously for a workload that is idle by design.
run "manifest_bills_per_request" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.cases.billing_mode == "PAY_PER_REQUEST"
    error_message = "This environment is dormant most of the time; provisioned capacity would bill through the gaps."
  }

  assert {
    condition     = aws_dynamodb_table.artifacts.billing_mode == "PAY_PER_REQUEST"
    error_message = "This environment is dormant most of the time; provisioned capacity would bill through the gaps."
  }
}

run "deletion_protection_can_be_released_for_teardown" {
  command = plan

  variables {
    manifest_deletion_protection = false
  }

  assert {
    condition     = aws_dynamodb_table.artifacts.deletion_protection_enabled == false
    error_message = "Spec 5.2.2 develops against a non-dedicated account, which must be able to tear down."
  }
}
```

- [x] **Step 2: Run the test to verify it fails**

```bash
cd modules/platform && tofu test -filter='tests\manifest.tftest.hcl'
```

Expected: FAIL — `aws_dynamodb_table.artifacts` not declared.

- [x] **Step 3: Write the tables**

Create `modules/platform/manifest.tf`:

```hcl
# The case store (spec 5.3).
#
# This exists because evidence objects are immutable. Everything worth knowing
# about an artifact changes after it lands -- custody events accumulate, the case
# opens and closes, the legal hold flag toggles, retention is set, and phase 3
# attaches a timeline ID and an event count. None of that can be written onto an
# object that is under a legal hold from the moment it arrives.
#
# Only the key schema is declared. DynamoDB is schemaless beyond its keys, and
# declaring non-key attributes here would create indexes nobody asked for.
#
# Attributes written by the recorder and by irctl:
#   cases      case_id, status, opened_at, closed_at, sketch_id, retention_years,
#              object_lock_mode, legal_hold, cost_tag
#   artifacts  case_id, sha256, status, source, size_bytes, received_at,
#              evidence_key, custody (list), timeline_id, event_count

resource "aws_dynamodb_table" "cases" {
  name         = "${var.name_prefix}-cases"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "case_id"

  attribute {
    name = "case_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  deletion_protection_enabled = var.manifest_deletion_protection

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-cases"
  })
}

resource "aws_dynamodb_table" "artifacts" {
  name         = "${var.name_prefix}-artifacts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "case_id"
  range_key    = "sha256"

  attribute {
    name = "case_id"
    type = "S"
  }

  attribute {
    name = "sha256"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  deletion_protection_enabled = var.manifest_deletion_protection

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-artifacts"
  })
}
```

- [x] **Step 4: Run the test to verify it passes**

```bash
cd modules/platform && tofu test -filter='tests\manifest.tftest.hcl'
```

Expected: PASS, 6 run blocks.

- [x] **Step 5: Commit**

```bash
git add modules/platform/manifest.tf modules/platform/tests/manifest.tftest.hcl
git commit -m "feat(platform): case and artifact manifest tables"
```

---

### Task 4: Audit bucket, CMK key policy, and CloudTrail data events

Spec §5.1. Object Lock buckets cannot receive S3 server access logs, so bucket-level access auditing is CloudTrail data events. The CMK needs an explicit key policy for this, and **getting that policy wrong locks you out of your own key** — the root statement below is not optional.

**Files:**
- Create: `modules/platform/audit.tf`
- Modify: `modules/platform/kms.tf`
- Test: `modules/platform/tests/audit.tftest.hcl`

**Interfaces:**
- Consumes: `aws_s3_bucket.intake/evidence/plaso`, `aws_s3_bucket.tooling`, `data.aws_region.current.region`
- Produces: `aws_s3_bucket.audit`, `aws_cloudtrail.data_events`

- [x] **Step 1: Write the failing test**

Create `modules/platform/tests/audit.tftest.hcl` — identical `mock_provider` block from Task 1 Step 1, then:

```hcl
variables {
  name_prefix         = "ir-test"
  budget_alert_emails = ["responder@example.com"]
}

# Spec 5.1: Object Lock buckets cannot receive S3 server access logs, so
# object-level read/write auditing is CloudTrail data events instead.
run "data_events_cover_every_evidence_bucket" {
  command = plan

  assert {
    condition     = length(aws_cloudtrail.data_events.advanced_event_selector) == 1
    error_message = "One selector covers all four buckets; splitting them multiplies cost for no benefit."
  }

  assert {
    condition = length([
      for f in one(aws_cloudtrail.data_events.advanced_event_selector).field_selector :
      f if f.field == "resources.ARN"
    ]) == 1
    error_message = "The selector must scope to bucket ARNs, or it bills for every S3 object event in the account."
  }
}

run "trail_validates_its_own_log_files" {
  command = plan

  assert {
    condition     = aws_cloudtrail.data_events.enable_log_file_validation
    error_message = "An audit log that cannot be shown to be unmodified is not evidence of anything."
  }
}

run "audit_bucket_is_versioned_and_encrypted" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.audit.versioning_configuration[0].status == "Enabled"
    error_message = "Overwriting an audit log must leave a trace."
  }

  assert {
    condition     = aws_s3_bucket_server_side_encryption_configuration.audit.rule[0].apply_server_side_encryption_by_default[0].kms_master_key_id == aws_kms_key.main.arn
    error_message = "Audit logs name artifacts and principals; they take the platform CMK."
  }
}

# The default key policy grants the account root, which does not cover an AWS
# service principal. Without an explicit grant CloudTrail cannot encrypt, and
# the trail fails at apply time with a message that does not name the key.
run "key_policy_lets_cloudtrail_encrypt_and_keeps_root" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.main.policy).Statement : s if s.Sid == "EnableRootAccountAccess"
    ]) == 1
    error_message = "An explicit key policy without a root statement is an unrecoverable lockout."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.main.policy).Statement : s if s.Sid == "AllowCloudTrailEncrypt"
    ]) == 1
    error_message = "CloudTrail is a service principal, not an account principal, so the default key policy does not reach it."
  }
}
```

- [x] **Step 2: Run the test to verify it fails**

```bash
cd modules/platform && tofu test -filter='tests\audit.tftest.hcl'
```

Expected: FAIL — `aws_cloudtrail.data_events` not declared.

- [x] **Step 3: Give the CMK an explicit key policy**

Replace the `aws_kms_key` resource in `modules/platform/kms.tf` with:

```hcl
# An explicit key policy replaces the default.
#
# The default policy grants the account root, and IAM policies then delegate from
# there. That covers every principal in this account -- but NOT an AWS service
# principal such as CloudTrail, which is not an account principal. Without the
# second statement the trail fails at apply with an error that does not name the
# key.
#
# The root statement is not optional. A key policy that omits it cannot be
# edited by anyone, and the key becomes unusable and undeletable except by
# scheduling deletion. Do not "tidy" it away.
resource "aws_kms_key" "main" {
  description             = "${var.name_prefix} IR platform key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudTrailEncrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringLike = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"
          }
        }
      },
    ]
  })
}
```

- [x] **Step 4: Write the audit bucket and trail**

Create `modules/platform/audit.tf`:

```hcl
# Bucket-level access auditing (spec 5.1).
#
# S3 server access logging cannot target an Object Lock bucket, and two of the
# three evidence buckets are Object Lock buckets, so object-level auditing is
# CloudTrail data events. The selector also covers the tooling bucket, which
# gives SNYK-CC-TF-45 a real compensating control -- though that rule looks for
# aws_s3_bucket_logging specifically and will keep reporting.

resource "aws_s3_bucket" "audit" {
  bucket = "${var.name_prefix}-audit-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-audit"
    Content = "cloudtrail-data-events"
  })
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  trail_arn = "arn:aws:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/${var.name_prefix}-data-events"
}

# The aws:SourceArn conditions are the confused-deputy guard: without them any
# account's CloudTrail could be pointed at this bucket.
resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.audit.arn
        Condition = {
          StringEquals = { "aws:SourceArn" = local.trail_arn }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.audit.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.trail_arn
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.audit.arn,
          "${aws_s3_bucket.audit.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

resource "aws_cloudtrail" "data_events" {
  name           = "${var.name_prefix}-data-events"
  s3_bucket_name = aws_s3_bucket.audit.id
  kms_key_id     = aws_kms_key.main.arn

  # Management events are not the point here and would multiply cost; this trail
  # exists to record who touched which object.
  include_global_service_events = false
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  advanced_event_selector {
    name = "S3 object access in the evidence store"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    # Scoped to these buckets. Unscoped, this bills for every S3 object event in
    # the account.
    field_selector {
      field = "resources.ARN"
      starts_with = [
        "${aws_s3_bucket.intake.arn}/",
        "${aws_s3_bucket.evidence.arn}/",
        "${aws_s3_bucket.plaso.arn}/",
        "${aws_s3_bucket.tooling.arn}/",
      ]
    }
  }

  # CloudTrail validates it can write to the bucket at creation time.
  depends_on = [aws_s3_bucket_policy.audit]
}
```

- [x] **Step 5: Run the test to verify it passes**

```bash
cd modules/platform && tofu test -filter='tests\audit.tftest.hcl'
```

Expected: PASS, 4 run blocks.

- [x] **Step 6: Run the full module test suite**

The key policy change touches a resource every other test file references.

```bash
cd modules/platform && tofu test
```

Expected: PASS. If `tests/foundations.tftest.hcl` or `tests/iam.tftest.hcl` now fail, the key policy is the cause — fix the policy, not the test.

- [x] **Step 7: Commit**

```bash
git add modules/platform/audit.tf modules/platform/kms.tf modules/platform/tests/audit.tftest.hcl
git commit -m "feat(platform): CloudTrail data events over the evidence store"
```

---

### Task 5: Break-glass role and responder policy

Spec §5.2, §5.2.2. The break-glass role is what makes GOVERNANCE mode meaningfully reversible; without a holder of `s3:BypassGovernanceRetention`, governance and compliance behave identically.

**Files:**
- Modify: `modules/platform/iam.tf` (append)
- Test: `modules/platform/tests/intake.tftest.hcl` (created here, extended in Task 7)

**Interfaces:**
- Consumes: `var.break_glass_principal_arns`, `aws_s3_bucket.evidence/plaso/intake`, `aws_dynamodb_table.cases/artifacts`
- Produces: `aws_iam_role.break_glass` (count-gated), `aws_iam_policy.responder`

- [x] **Step 1: Write the failing test**

Create `modules/platform/tests/intake.tftest.hcl` — identical `mock_provider` block from Task 1 Step 1, plus this extra mock inside the `mock_provider "aws"` block:

```hcl
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/ir-test-mock"
    }
  }
```

then:

```hcl
variables {
  name_prefix         = "ir-test"
  budget_alert_emails = ["responder@example.com"]
}

# Spec 5.2: GOVERNANCE is only meaningfully different from COMPLIANCE if some
# principal can actually bypass it. Ingesting the wrong client's data is the
# case this exists for.
run "break_glass_role_is_absent_until_a_principal_is_named" {
  command = plan

  assert {
    condition     = length(aws_iam_role.break_glass) == 0
    error_message = "A bypass role nobody asked for is a standing privilege; it appears only when a principal is named."
  }
}

run "break_glass_role_can_bypass_governance_retention" {
  command = plan

  variables {
    break_glass_principal_arns = ["arn:aws:iam::111122223333:role/incident-lead"]
  }

  assert {
    condition     = length(aws_iam_role.break_glass) == 1
    error_message = "Naming a principal must create the role."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(one(aws_iam_role_policy.break_glass).policy).Statement :
      contains(s.Action, "s3:BypassGovernanceRetention")
    ])
    error_message = "Without this permission a governance-locked object cannot be removed and tofu destroy fails (spec 5.2.2)."
  }
}

# A responder uploads. A responder does not read the evidence bucket, delete
# from it, or write the manifest -- the recorder does that.
run "responder_policy_can_upload_but_not_reach_evidence" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_policy.responder.policy).Statement :
      s.Sid == "IntakeUpload"
    ])
    error_message = "A responder must be able to put an artifact into intake."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_policy.responder.policy).Statement :
      !strcontains(jsonencode(s.Resource), "-evidence-")
    ])
    error_message = "A responder has no reason to reach the evidence bucket directly; the recorder owns that path."
  }
}
```

- [x] **Step 2: Run the test to verify it fails**

```bash
cd modules/platform && tofu test -filter='tests\intake.tftest.hcl'
```

Expected: FAIL — `aws_iam_role.break_glass` not declared.

- [x] **Step 3: Write the roles**

Append to `modules/platform/iam.tf`:

```hcl
# --- Phase 2: evidence store principals ---

# Break glass (spec 5.2).
#
# GOVERNANCE mode differs from COMPLIANCE mode only because some principal can
# bypass it. That principal is this role, and it is created only when someone is
# named to assume it -- a standing bypass role nobody asked for is a standing
# privilege.
#
# Spec 5.2.2: without this, `tofu destroy` fails against any bucket holding
# locked objects, which a development deployment needs.
resource "aws_iam_role" "break_glass" {
  count = length(var.break_glass_principal_arns) > 0 ? 1 : 0

  name = "${var.name_prefix}-break-glass"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = var.break_glass_principal_arns }
    }]
  })

  tags = merge(local.common_tags, {
    Purpose = "operator-error-recovery"
  })
}

resource "aws_iam_role_policy" "break_glass" {
  count = length(var.break_glass_principal_arns) > 0 ? 1 : 0

  name = "${var.name_prefix}-break-glass"
  role = aws_iam_role.break_glass[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BypassGovernanceRetention"
        Effect = "Allow"
        Action = [
          "s3:BypassGovernanceRetention",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:PutObjectLegalHold",
          "s3:PutObjectRetention",
          "s3:GetObjectLegalHold",
          "s3:GetObjectRetention",
        ]
        Resource = [
          "${aws_s3_bucket.evidence.arn}/*",
          "${aws_s3_bucket.plaso.arn}/*",
        ]
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.main.arn
      },
    ]
  })
}

# The responder surface (D12).
#
# Attached by the deployer to whichever principal responders actually use. It is
# deliberately narrow: upload to intake, read and open cases. Everything past
# intake belongs to the recorder, so a compromised responder credential cannot
# read the evidence store or rewrite the manifest.
resource "aws_iam_policy" "responder" {
  name        = "${var.name_prefix}-responder"
  description = "Upload artifacts to intake and open cases. Attach to responder principals."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IntakeUpload"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.intake.arn}/*"
      },
      {
        Sid      = "IntakeListForMultipart"
        Effect   = "Allow"
        Action   = ["s3:ListBucketMultipartUploads"]
        Resource = aws_s3_bucket.intake.arn
      },
      {
        Sid    = "CaseReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
        ]
        Resource = aws_dynamodb_table.cases.arn
      },
      {
        # Read-only: a responder can see what has been recorded but cannot write
        # a custody entry by hand.
        Sid      = "ArtifactRead"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.artifacts.arn
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.main.arn
      },
    ]
  })
}
```

- [x] **Step 4: Run the test to verify it passes**

```bash
cd modules/platform && tofu test -filter='tests\intake.tftest.hcl'
```

Expected: PASS, 3 run blocks.

- [x] **Step 5: Commit**

```bash
git add modules/platform/iam.tf modules/platform/tests/intake.tftest.hcl
git commit -m "feat(platform): break-glass role and responder policy"
```

---

### Task 6: The intake recorder

Spec §5.5. Pure Python, unit-tested with `botocore.Stubber`. Written before its infrastructure so the state machine is settled before anything wires it up.

**Files:**
- Create: `modules/platform/lambda/intake/handler.py`
- Create: `modules/platform/lambda/intake/test_handler.py`

**Interfaces:**
- Consumes: environment variables `EVIDENCE_BUCKET`, `CASES_TABLE`, `ARTIFACTS_TABLE`
- Produces: `handler(event, context)`; `record_one(bucket, key) -> str` returning `"recorded"`, `"duplicate"`, or raising `IntakeError`

**The state machine, because the ordering is not obvious:**

The manifest row is written *before* the copy. Writing it after would mean a failed copy left no trace; writing it before and failing means a row with `status="recording"` and the object still in intake — loud and recoverable. The conditional write is therefore not a plain `attribute_not_exists`, because a retry after a partial failure must be able to continue:

| Existing row | Meaning | Action |
|---|---|---|
| none | First arrival | Write `status="recording"`, copy, hold, mark `recorded`, delete from intake |
| `status="recording"` | A previous attempt died mid-flight | Continue from the copy. `CopyObject` and `PutObjectLegalHold` are both idempotent |
| `status="recorded"` | Genuine duplicate (spec §4.2) | Delete from intake, do nothing else |

- [x] **Step 1: Write the failing test**

Create `modules/platform/lambda/intake/test_handler.py`:

```python
"""Unit tests for the intake recorder.

No AWS, no credentials, no cost -- botocore.Stubber asserts the exact API calls,
which is the same discipline mock_provider gives the HCL.
"""
import os

import pytest

os.environ.setdefault("EVIDENCE_BUCKET", "ir-test-evidence")
os.environ.setdefault("CASES_TABLE", "ir-test-cases")
os.environ.setdefault("ARTIFACTS_TABLE", "ir-test-artifacts")

import handler  # noqa: E402


def test_missing_digest_metadata_is_refused():
    """An object with no recorded digest cannot enter the custody chain."""
    head = {"Metadata": {"case-id": "CASE-1"}, "ContentLength": 10}
    with pytest.raises(handler.IntakeError, match="sha256"):
        handler.validate_metadata("some/key", head)


def test_missing_case_metadata_is_refused():
    head = {"Metadata": {"sha256": "ab" * 32}, "ContentLength": 10}
    with pytest.raises(handler.IntakeError, match="case-id"):
        handler.validate_metadata("some/key", head)


def test_metadata_is_returned_when_complete():
    head = {
        "Metadata": {"sha256": "ab" * 32, "case-id": "CASE-1", "source": "laptop-7"},
        "ContentLength": 4096,
    }
    meta = handler.validate_metadata("some/key", head)
    assert meta.sha256 == "ab" * 32
    assert meta.case_id == "CASE-1"
    assert meta.source == "laptop-7"
    assert meta.size_bytes == 4096


def test_source_defaults_when_absent():
    """Source is useful but not load-bearing; its absence must not reject evidence."""
    head = {"Metadata": {"sha256": "ab" * 32, "case-id": "CASE-1"}, "ContentLength": 1}
    assert handler.validate_metadata("k", head).source == "unspecified"


def test_evidence_key_is_prefixed_by_case():
    """Case close operates across a prefix, so the prefix has to be the case."""
    assert handler.evidence_key("CASE-1", "CASE-1/triage.zip") == "CASE-1/triage.zip"
    assert handler.evidence_key("CASE-1", "triage.zip") == "CASE-1/triage.zip"
```

- [x] **Step 2: Run the test to verify it fails**

```bash
cd modules/platform/lambda/intake && python -m pytest test_handler.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'handler'`.

- [x] **Step 3: Write the handler**

Create `modules/platform/lambda/intake/handler.py`:

```python
"""Intake recorder -- spec 5.5.

Runs OUTSIDE the VPC, deliberately. In-VPC placement would put this behind the
interface endpoints that dormancy destroys, which would couple the chain of
custody to the posture toggle: an artifact arriving between incidents would sit
unrecorded in a bucket with a short expiry lifecycle, and the gap would be
silent.

It never calls GetObject. HeadObject reads the metadata and CopyObject is
executed server-side by S3, so no object bytes pass through this function. That
is what makes running it outside the VPC a defensible choice rather than a
concession -- a component that cannot read evidence cannot leak it.

Known ceiling: the copy is driven from here, under a 15-minute function timeout.
boto3's managed copy uses UploadPartCopy above 5 GB, still server-side, but a
large enough artifact will exhaust the timeout. It fails loudly and the object
stays in intake. Phase 3 moves the copy into Batch, which removes the ceiling.
"""

import logging
import os
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

EVIDENCE_BUCKET = os.environ["EVIDENCE_BUCKET"]
CASES_TABLE = os.environ["CASES_TABLE"]
ARTIFACTS_TABLE = os.environ["ARTIFACTS_TABLE"]

s3 = boto3.client("s3")
ddb = boto3.client("dynamodb")


class IntakeError(Exception):
    """The object could not be recorded. It stays in intake for investigation."""


@dataclass(frozen=True)
class ArtifactMetadata:
    sha256: str
    case_id: str
    source: str
    size_bytes: int


def validate_metadata(key, head):
    """Pull the custody fields off a HeadObject response.

    irctl writes these at PUT. Their absence means the object did not come
    through irctl, and an artifact whose digest was never recorded at the point
    of collection cannot enter the chain of custody (spec 4.2).
    """
    metadata = head.get("Metadata", {})

    sha256 = metadata.get("sha256")
    if not sha256:
        raise IntakeError(
            f"{key}: no sha256 metadata. The digest is computed at collection; "
            "an object without one did not come through irctl."
        )

    case_id = metadata.get("case-id")
    if not case_id:
        raise IntakeError(f"{key}: no case-id metadata. Evidence is filed against a case.")

    return ArtifactMetadata(
        sha256=sha256,
        case_id=case_id,
        source=metadata.get("source", "unspecified"),
        size_bytes=head.get("ContentLength", 0),
    )


def evidence_key(case_id, intake_key):
    """Case close operates across a prefix, so the prefix must be the case."""
    prefix = f"{case_id}/"
    return intake_key if intake_key.startswith(prefix) else prefix + intake_key


def _now():
    return datetime.now(timezone.utc).isoformat()


def _require_open_case(case_id):
    """Refuse an artifact filed against a case that does not exist.

    This is the quarantine boundary doing its job: past this point the object is
    under a legal hold and, in a compliance-mode deployment, permanent.
    """
    result = ddb.get_item(
        TableName=CASES_TABLE,
        Key={"case_id": {"S": case_id}},
        ConsistentRead=True,
    )
    item = result.get("Item")
    if not item:
        raise IntakeError(
            f"case {case_id} does not exist. Run `irctl case open {case_id}` first; "
            "the artifact stays in intake."
        )
    status = item.get("status", {}).get("S")
    if status != "open":
        raise IntakeError(f"case {case_id} is {status!r}, not open. Artifact stays in intake.")


def _claim(meta, key):
    """Write the manifest row conditionally. Returns True if this is a new claim.

    Deduplication is this write failing, not a check before it -- which makes it
    atomic. Two concurrent invocations on the same artifact would both pass a
    read-then-write check; only one can win a conditional write.
    """
    try:
        ddb.put_item(
            TableName=ARTIFACTS_TABLE,
            Item={
                "case_id": {"S": meta.case_id},
                "sha256": {"S": meta.sha256},
                "status": {"S": "recording"},
                "source": {"S": meta.source},
                "size_bytes": {"N": str(meta.size_bytes)},
                "received_at": {"S": _now()},
                "intake_key": {"S": key},
                "evidence_key": {"S": evidence_key(meta.case_id, key)},
                "custody": {"L": [{"S": f"{_now()} received from {meta.source}"}]},
            },
            ConditionExpression="attribute_not_exists(sha256)",
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        return False


def _existing_status(meta):
    result = ddb.get_item(
        TableName=ARTIFACTS_TABLE,
        Key={"case_id": {"S": meta.case_id}, "sha256": {"S": meta.sha256}},
        ConsistentRead=True,
    )
    return result.get("Item", {}).get("status", {}).get("S")


def _copy_and_hold(bucket, key, meta):
    """Server-side copy, then the legal hold.

    The hold is a separate call rather than a CopyObject argument: the managed
    copy is needed to handle objects over 5 GB (it falls back to UploadPartCopy,
    still server-side) and its allowed-argument list is not somewhere to bet the
    hold on. The cost is a sub-second window in which the object is in evidence
    without a hold. Both calls are idempotent, so a retry is safe.
    """
    target = evidence_key(meta.case_id, key)

    s3.copy(
        CopySource={"Bucket": bucket, "Key": key},
        Bucket=EVIDENCE_BUCKET,
        Key=target,
    )

    # Spec 5.2: legal hold ON, no retain-until date. The retention clock starts
    # at case close (phase 4), not here. Setting a retention period at this point
    # would silently convert the model into "N years from upload".
    s3.put_object_legal_hold(
        Bucket=EVIDENCE_BUCKET,
        Key=target,
        LegalHold={"Status": "ON"},
    )
    return target


def record_one(bucket, key):
    head = s3.head_object(Bucket=bucket, Key=key, ChecksumMode="ENABLED")
    meta = validate_metadata(key, head)
    _require_open_case(meta.case_id)

    if not _claim(meta, key):
        status = _existing_status(meta)
        if status == "recorded":
            # Spec 4.2: a triage package uploaded twice is recognised and not
            # reprocessed.
            log.info("duplicate %s for case %s; discarding intake copy", meta.sha256, meta.case_id)
            s3.delete_object(Bucket=bucket, Key=key)
            return "duplicate"
        log.warning(
            "artifact %s was left mid-recording; continuing from the copy", meta.sha256
        )

    target = _copy_and_hold(bucket, key, meta)

    ddb.update_item(
        TableName=ARTIFACTS_TABLE,
        Key={"case_id": {"S": meta.case_id}, "sha256": {"S": meta.sha256}},
        UpdateExpression=(
            "SET #s = :recorded, evidence_key = :ek, custody = list_append(custody, :event)"
        ),
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":recorded": {"S": "recorded"},
            ":ek": {"S": target},
            ":event": {"L": [{"S": f"{_now()} copied to evidence under legal hold"}]},
        },
    )

    s3.delete_object(Bucket=bucket, Key=key)
    log.info("recorded %s for case %s as %s", meta.sha256, meta.case_id, target)
    return "recorded"


def handler(event, context):
    """S3 ObjectCreated entry point.

    One failure does not abandon the rest of the batch: each object is
    independent, and an artifact that cannot be recorded must not prevent one
    that can.
    """
    outcomes = []
    failures = []

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        try:
            outcomes.append({"key": key, "outcome": record_one(bucket, key)})
        except Exception as exc:  # noqa: BLE001 -- reported, not swallowed
            log.exception("failed to record %s", key)
            failures.append({"key": key, "error": str(exc)})

    if failures:
        raise IntakeError(f"{len(failures)} artifact(s) not recorded: {failures}")

    return {"recorded": outcomes}
```

- [x] **Step 4: Run the test to verify it passes**

```bash
cd modules/platform/lambda/intake && python -m pytest test_handler.py -v
```

Expected: PASS, 5 tests.

- [x] **Step 5: Commit**

```bash
git add modules/platform/lambda/intake/
git commit -m "feat(platform): intake recorder, outside the VPC and blind to object content"
```

---

### Task 7: Wire the recorder into the platform

**Files:**
- Modify: `modules/platform/versions.tf`
- Create: `modules/platform/intake.tf`
- Test: `modules/platform/tests/intake.tftest.hcl` (append)

**Interfaces:**
- Consumes: `aws_s3_bucket.intake/evidence`, `aws_dynamodb_table.cases/artifacts`, `modules/platform/lambda/intake/handler.py`
- Produces: `aws_lambda_function.intake`

- [x] **Step 1: Write the failing test**

Append to `modules/platform/tests/intake.tftest.hcl`:

```hcl
# Spec 5.5. In-VPC placement would put the recorder behind the interface
# endpoints that dormancy destroys, which would couple the chain of custody to
# the posture toggle -- artifacts arriving between incidents would go unrecorded.
run "recorder_is_not_attached_to_the_vpc" {
  command = plan

  assert {
    condition     = length(aws_lambda_function.intake.vpc_config) == 0
    error_message = "A VPC-attached recorder stops working while the environment is dormant, and the gap is silent."
  }
}

# It reads metadata and drives a server-side copy. It never reads object bytes,
# which is what makes running it outside the VPC defensible.
run "recorder_cannot_read_object_content" {
  command = plan

  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.intake.policy).Statement :
      contains(s.Action, "s3:GetObject")
    ])
    error_message = "A component that cannot read evidence cannot leak it. HeadObject and a server-side CopyObject are enough."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.intake.policy).Statement :
      contains(s.Action, "s3:PutObjectLegalHold")
    ])
    error_message = "The recorder applies the hold that makes an artifact immutable (spec 5.2)."
  }
}

run "recorder_is_triggered_by_intake_arrivals" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_notification.intake.lambda_function).events == tolist(["s3:ObjectCreated:*"])
    error_message = "Recording must begin the moment an object lands, whatever the posture."
  }
}

run "recorder_has_the_full_timeout" {
  command = plan

  assert {
    condition     = aws_lambda_function.intake.timeout == 900
    error_message = "The server-side copy of a large artifact needs the whole window; the ceiling is documented, not hidden."
  }
}
```

- [x] **Step 2: Run the test to verify it fails**

```bash
cd modules/platform && tofu test -filter='tests\intake.tftest.hcl'
```

Expected: FAIL — `aws_lambda_function.intake` not declared.

- [x] **Step 3: Add the archive provider**

Modify `modules/platform/versions.tf`, adding to `required_providers`:

```hcl
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
```

- [x] **Step 4: Write the infrastructure**

Create `modules/platform/intake.tf`:

```hcl
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

# Note the absence of s3:GetObject. HeadObject returns the metadata and
# CopyObject is executed server-side by S3, so this role can move evidence
# without ever being able to read it.
resource "aws_iam_role_policy" "intake" {
  name = "${var.name_prefix}-intake-recorder"
  role = aws_iam_role.intake.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadIntakeMetadata"
        Effect   = "Allow"
        Action   = ["s3:GetObjectAttributes", "s3:GetObjectVersionAttributes"]
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

  # The server-side copy of a large artifact needs the whole window. This is the
  # documented Phase 2 ceiling; phase 3 moves the copy into Batch.
  timeout     = 900
  memory_size = 256

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
```

- [x] **Step 5: Run the test to verify it passes**

```bash
cd modules/platform && tofu init -backend=false && tofu test -filter='tests\intake.tftest.hcl'
```

The `init` is needed once: `archive` is a new provider. Expected: PASS, 7 run blocks.

- [x] **Step 6: Commit the lock file too**

```bash
git add modules/platform/intake.tf modules/platform/versions.tf modules/platform/.terraform.lock.hcl modules/platform/tests/intake.tftest.hcl
git commit -m "feat(platform): wire the intake recorder to bucket arrivals"
```

---

### Task 8: Outputs and example wiring

**Files:**
- Modify: `modules/platform/outputs.tf` (append)
- Modify: `envs/example/platform/main.tf`

**Interfaces:**
- Produces: `evidence_bucket`, `intake_bucket`, `plaso_bucket`, `audit_bucket`, `cases_table`, `artifacts_table`, `responder_policy_arn`, `break_glass_role_arn` — `irctl` and the acceptance gate read these

- [x] **Step 1: Append the outputs**

Append to `modules/platform/outputs.tf`:

```hcl
# --- Phase 2: evidence store (spec 5) ---
#
# irctl is configured from these; so is the acceptance gate.

output "intake_bucket" {
  value       = aws_s3_bucket.intake.bucket
  description = "Upload target. Objects are recorded and removed from here automatically."
}

output "evidence_bucket" {
  value       = aws_s3_bucket.evidence.bucket
  description = "Raw artifacts under Object Lock and legal hold. Not written to directly."
}

output "plaso_bucket" {
  value       = aws_s3_bucket.plaso.bucket
  description = "Generated timelines. Written by the phase 3 pipeline."
}

output "audit_bucket" {
  value       = aws_s3_bucket.audit.bucket
  description = "CloudTrail data events over the evidence store."
}

output "cases_table" {
  value       = aws_dynamodb_table.cases.name
  description = "Case state: status, retention policy, legal hold flag."
}

output "artifacts_table" {
  value       = aws_dynamodb_table.artifacts.name
  description = "Custody chain, keyed by (case_id, sha256)."
}

output "responder_policy_arn" {
  value       = aws_iam_policy.responder.arn
  description = "Attach to responder principals. Upload and case access only."
}

output "break_glass_role_arn" {
  value       = one(aws_iam_role.break_glass[*].arn)
  description = "Holds s3:BypassGovernanceRetention. Null unless break_glass_principal_arns is set."
}
```

- [x] **Step 2: Wire the example environment**

In `envs/example/platform/main.tf`, add inside the `module "platform"` block, after `data_volume_gb`:

```hcl
  # Phase 2. GOVERNANCE is the only safe value outside a production IR account:
  # compliance-locked objects cannot be deleted before expiry by anyone, and this
  # deployment gets torn down (spec 5.2.2).
  object_lock_mode = "GOVERNANCE"
  retention_years  = 3

  # Development deployments get torn down; the manifest here is disposable.
  # Never set this false in production.
  manifest_deletion_protection = false
```

- [x] **Step 3: Verify the whole suite still passes**

```bash
bash scripts/check.sh check
```

Expected: fmt clean, all three modules valid, tflint clean, and **52 + 20 = 72 run blocks** passing (platform now 39). Check the count.

- [x] **Step 4: Commit**

```bash
git add modules/platform/outputs.tf envs/example/platform/main.tf
git commit -m "feat(platform): expose the evidence store and wire the example env"
```

---

### Task 9: `irctl` package and the digest module

Spec §4.2. One pass over the file producing the whole-file digest, the per-part digests, and the size. Reading the file twice for a 20 GB artifact is a minute of avoidable I/O.

**Files:**
- Create: `cli/pyproject.toml`, `cli/irctl/__init__.py`, `cli/irctl/digest.py`
- Test: `cli/tests/test_digest.py`

**Interfaces:**
- Produces: `PART_SIZE`, `FileDigest(sha256_hex, sha256_b64, part_digests_b64, size_bytes)`, `hash_file(path, part_size=PART_SIZE) -> FileDigest`

- [x] **Step 1: Write the failing test**

Create `cli/tests/test_digest.py`:

```python
import base64
import hashlib

from irctl.digest import PART_SIZE, hash_file


def test_digest_matches_hashlib(tmp_path):
    payload = b"artifact contents"
    target = tmp_path / "triage.bin"
    target.write_bytes(payload)

    result = hash_file(target)

    expected = hashlib.sha256(payload)
    assert result.sha256_hex == expected.hexdigest()
    assert result.sha256_b64 == base64.b64encode(expected.digest()).decode()
    assert result.size_bytes == len(payload)


def test_small_file_is_a_single_part(tmp_path):
    """Below the threshold the stored checksum IS the whole-file digest (spec 4.2)."""
    target = tmp_path / "small.bin"
    target.write_bytes(b"x" * 100)

    result = hash_file(target)

    assert len(result.part_digests_b64) == 1
    assert result.part_digests_b64[0] == result.sha256_b64


def test_large_file_is_split_into_parts(tmp_path):
    """Above the threshold S3 stores a composite digest, so parts are hashed too."""
    target = tmp_path / "large.bin"
    target.write_bytes(b"y" * 2500)

    result = hash_file(target, part_size=1000)

    assert len(result.part_digests_b64) == 3
    assert result.size_bytes == 2500
    # The whole-file digest is still the digest of the whole file, not a
    # composite -- that is the value custody and deduplication key on.
    assert result.sha256_hex == hashlib.sha256(b"y" * 2500).hexdigest()


def test_part_digests_are_digests_of_their_own_part(tmp_path):
    target = tmp_path / "parts.bin"
    target.write_bytes(b"ab" * 1000)

    result = hash_file(target, part_size=1000)

    first = base64.b64encode(hashlib.sha256(b"ab" * 500).digest()).decode()
    assert result.part_digests_b64[0] == first


def test_empty_file_still_yields_one_part(tmp_path):
    """S3 rejects a multipart upload with no parts; an empty artifact is a single PUT."""
    target = tmp_path / "empty.bin"
    target.write_bytes(b"")

    result = hash_file(target)

    assert result.size_bytes == 0
    assert len(result.part_digests_b64) == 1


def test_default_part_size_matches_s3_multipart_minimum():
    assert PART_SIZE >= 5 * 1024 * 1024
```

- [x] **Step 2: Create the package scaffolding**

Create `cli/pyproject.toml`:

```toml
[project]
name = "irctl"
version = "0.2.0"
description = "Incident response evidence intake CLI"
requires-python = ">=3.11"
dependencies = ["boto3>=1.34"]

[project.scripts]
irctl = "irctl.cli:main"

[project.optional-dependencies]
dev = ["pytest>=8.0"]

[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
include = ["irctl*"]

[tool.pytest.ini_options]
testpaths = ["tests"]
```

Create `cli/irctl/__init__.py`:

```python
"""irctl -- responder-facing evidence intake (spec 4.1, D12)."""

__version__ = "0.2.0"
```

- [x] **Step 3: Run the test to verify it fails**

```bash
cd cli && python -m pip install -e ".[dev]" && python -m pytest tests/test_digest.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'irctl.digest'`.

- [x] **Step 4: Write the digest module**

Create `cli/irctl/digest.py`:

```python
"""Hashing at the point of collection (spec 4.2).

The digest is computed before upload and S3 verifies it server-side at PUT,
rejecting a mismatch. Hashing after arrival would prove only that S3 did not
corrupt the object; hashing at collection is what is actually defensible.

Both digests are produced in one pass. A 20 GB triage package read twice is a
minute of avoidable I/O, and the per-part digests are only needed because S3
stores a composite `<hash>-N` for multipart uploads rather than the whole-file
digest.
"""

import base64
import hashlib
from dataclasses import dataclass

# 8 MiB. Above S3's 5 MiB minimum part size, and small enough that a failed part
# is cheap to retry over a field connection.
PART_SIZE = 8 * 1024 * 1024


@dataclass(frozen=True)
class FileDigest:
    """Everything the upload and the manifest need from one read of the file.

    sha256_hex       -- what goes in the manifest and object metadata. The value
                        custody and deduplication key on.
    sha256_b64        -- what goes in x-amz-checksum-sha256 for a single PUT.
    part_digests_b64  -- per-part checksums for a multipart upload.
    size_bytes        -- decides single versus multipart, and is recorded.
    """

    sha256_hex: str
    sha256_b64: str
    part_digests_b64: list
    size_bytes: int


def hash_file(path, part_size=PART_SIZE):
    whole = hashlib.sha256()
    parts = []
    size = 0

    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(part_size)
            if not chunk:
                break
            size += len(chunk)
            whole.update(chunk)
            parts.append(base64.b64encode(hashlib.sha256(chunk).digest()).decode())

    if not parts:
        # S3 rejects a multipart upload with zero parts, and an empty artifact is
        # still an artifact. One empty part keeps the single-PUT path valid.
        parts.append(base64.b64encode(hashlib.sha256(b"").digest()).decode())

    return FileDigest(
        sha256_hex=whole.hexdigest(),
        sha256_b64=base64.b64encode(whole.digest()).decode(),
        part_digests_b64=parts,
        size_bytes=size,
    )
```

- [x] **Step 5: Run the test to verify it passes**

```bash
cd cli && python -m pytest tests/test_digest.py -v
```

Expected: PASS, 6 tests.

- [x] **Step 6: Commit**

```bash
git add cli/pyproject.toml cli/irctl/__init__.py cli/irctl/digest.py cli/tests/test_digest.py
git commit -m "feat(irctl): one-pass whole-file and per-part SHA-256"
```

---

### Task 10: `irctl case open`

**Files:**
- Create: `cli/irctl/cases.py`
- Test: `cli/tests/test_cases.py`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `open_case(ddb, table, case_id, retention_years=3, object_lock_mode="GOVERNANCE", cost_tag=None) -> dict`, `CaseExistsError`

- [x] **Step 1: Write the failing test**

Create `cli/tests/test_cases.py`:

```python
import boto3
import pytest
from botocore.stub import ANY, Stubber

from irctl.cases import CaseExistsError, open_case


@pytest.fixture
def ddb():
    return boto3.client("dynamodb", region_name="us-east-1")


def test_open_case_writes_an_open_record(ddb):
    stub = Stubber(ddb)
    stub.add_response("put_item", {}, {
        "TableName": "ir-test-cases",
        "Item": ANY,
        "ConditionExpression": "attribute_not_exists(case_id)",
    })

    with stub:
        record = open_case(ddb, "ir-test-cases", "CASE-2026-014")

    assert record["case_id"] == "CASE-2026-014"
    assert record["status"] == "open"
    assert record["retention_years"] == 3
    assert record["legal_hold"] is False
    stub.assert_no_pending_responses()


def test_open_case_is_refused_when_the_case_exists(ddb):
    """Reopening would silently reset retention policy on a live case."""
    stub = Stubber(ddb)
    stub.add_client_error(
        "put_item",
        service_error_code="ConditionalCheckFailedException",
        http_status_code=400,
    )

    with stub, pytest.raises(CaseExistsError, match="CASE-2026-014"):
        open_case(ddb, "ir-test-cases", "CASE-2026-014")


def test_compliance_mode_is_recorded_on_the_case(ddb):
    """Spec 5.2: the mode is per-case, and case close reads it to set retention."""
    stub = Stubber(ddb)
    stub.add_response("put_item", {}, {
        "TableName": "ir-test-cases",
        "Item": ANY,
        "ConditionExpression": "attribute_not_exists(case_id)",
    })

    with stub:
        record = open_case(
            ddb, "ir-test-cases", "CASE-2026-015", object_lock_mode="COMPLIANCE"
        )

    assert record["object_lock_mode"] == "COMPLIANCE"


def test_unknown_lock_mode_is_rejected_before_any_call(ddb):
    stub = Stubber(ddb)
    with stub, pytest.raises(ValueError, match="GOVERNANCE"):
        open_case(ddb, "ir-test-cases", "CASE-1", object_lock_mode="whatever")
    stub.assert_no_pending_responses()
```

- [x] **Step 2: Run the test to verify it fails**

```bash
cd cli && python -m pytest tests/test_cases.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'irctl.cases'`.

- [x] **Step 3: Write the module**

Create `cli/irctl/cases.py`:

```python
"""Case records (spec 5.3).

A case is a data concept, not an infrastructure one (D11): a row here, a prefix
in the evidence bucket, and eventually a Timesketch sketch. Opening a case
creates nothing in AWS beyond this row.
"""

from datetime import datetime, timezone

from botocore.exceptions import ClientError

LOCK_MODES = ("GOVERNANCE", "COMPLIANCE")


class CaseExistsError(Exception):
    """The case is already open. Reopening would reset its retention policy."""


def open_case(
    ddb,
    table,
    case_id,
    retention_years=3,
    object_lock_mode="GOVERNANCE",
    cost_tag=None,
):
    """Create an open case record.

    The retention policy is recorded now and applied at case close (spec 5.2) --
    the clock starts when the case closes, not when an artifact arrives.
    """
    if object_lock_mode not in LOCK_MODES:
        raise ValueError(
            f"object_lock_mode must be one of {LOCK_MODES}, got {object_lock_mode!r}"
        )

    opened_at = datetime.now(timezone.utc).isoformat()

    record = {
        "case_id": case_id,
        "status": "open",
        "opened_at": opened_at,
        "retention_years": retention_years,
        "object_lock_mode": object_lock_mode,
        # Independent of retention, and persists until explicitly removed. At
        # case close the hold is released only if this is still false (spec 5.2).
        "legal_hold": False,
        "cost_tag": cost_tag or case_id,
    }

    item = {
        "case_id": {"S": case_id},
        "status": {"S": "open"},
        "opened_at": {"S": opened_at},
        "retention_years": {"N": str(retention_years)},
        "object_lock_mode": {"S": object_lock_mode},
        "legal_hold": {"BOOL": False},
        "cost_tag": {"S": record["cost_tag"]},
    }

    try:
        ddb.put_item(
            TableName=table,
            Item=item,
            ConditionExpression="attribute_not_exists(case_id)",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise CaseExistsError(
                f"case {case_id} already exists. Reopening it would reset the "
                "retention policy on evidence already filed against it."
            ) from exc
        raise

    return record
```

- [x] **Step 4: Run the test to verify it passes**

```bash
cd cli && python -m pytest tests/test_cases.py -v
```

Expected: PASS, 4 tests.

- [x] **Step 5: Commit**

```bash
git add cli/irctl/cases.py cli/tests/test_cases.py
git commit -m "feat(irctl): case open"
```

---

### Task 11: `irctl upload` and the CLI entry point

Spec §4.2. The checksum goes on the PUT so S3 rejects a corrupt transfer rather than storing it.

**Files:**
- Create: `cli/irctl/upload.py`, `cli/irctl/cli.py`
- Test: `cli/tests/test_upload.py`

**Interfaces:**
- Consumes: `irctl.digest.hash_file`, `irctl.digest.FileDigest`, `irctl.cases.open_case`
- Produces: `upload_artifact(s3, bucket, case_id, path, source=None, part_size=PART_SIZE) -> dict`

- [x] **Step 1: Write the failing test**

Create `cli/tests/test_upload.py`:

```python
import boto3
import pytest
from botocore.stub import ANY, Stubber

from irctl.upload import upload_artifact


@pytest.fixture
def s3():
    return boto3.client("s3", region_name="us-east-1")


def test_single_part_upload_sends_the_checksum(s3, tmp_path):
    """Spec 4.2 / A1: S3 verifies this server-side and rejects a mismatch."""
    artifact = tmp_path / "triage.zip"
    artifact.write_bytes(b"z" * 64)

    stub = Stubber(s3)
    stub.add_response("put_object", {}, {
        "Bucket": "ir-test-intake",
        "Key": "CASE-1/triage.zip",
        "Body": ANY,
        "ChecksumAlgorithm": "SHA256",
        "ChecksumSHA256": ANY,
        "Metadata": ANY,
    })

    with stub:
        result = upload_artifact(s3, "ir-test-intake", "CASE-1", artifact)

    assert result["key"] == "CASE-1/triage.zip"
    assert result["multipart"] is False
    stub.assert_no_pending_responses()


def test_metadata_carries_the_custody_fields(s3, tmp_path):
    """The recorder refuses an object without these; they are the custody chain."""
    artifact = tmp_path / "evidence.bin"
    artifact.write_bytes(b"q" * 10)

    captured = {}

    stub = Stubber(s3)
    stub.add_response("put_object", {}, {
        "Bucket": ANY, "Key": ANY, "Body": ANY,
        "ChecksumAlgorithm": "SHA256", "ChecksumSHA256": ANY, "Metadata": ANY,
    })

    with stub:
        result = upload_artifact(
            s3, "ir-test-intake", "CASE-9", artifact, source="laptop-7"
        )

    captured = result["metadata"]
    assert captured["case-id"] == "CASE-9"
    assert captured["source"] == "laptop-7"
    assert len(captured["sha256"]) == 64


def test_large_artifact_uses_multipart_with_part_checksums(s3, tmp_path):
    """Multipart stores a composite <hash>-N, so every part carries its own digest."""
    artifact = tmp_path / "image.dd"
    artifact.write_bytes(b"w" * 2500)

    stub = Stubber(s3)
    stub.add_response("create_multipart_upload", {"UploadId": "mpu-1"}, {
        "Bucket": "ir-test-intake",
        "Key": "CASE-2/image.dd",
        "ChecksumAlgorithm": "SHA256",
        "Metadata": ANY,
    })
    for part in (1, 2, 3):
        stub.add_response("upload_part", {"ETag": f"etag-{part}"}, {
            "Bucket": "ir-test-intake",
            "Key": "CASE-2/image.dd",
            "UploadId": "mpu-1",
            "PartNumber": part,
            "Body": ANY,
            "ChecksumAlgorithm": "SHA256",
            "ChecksumSHA256": ANY,
        })
    stub.add_response("complete_multipart_upload", {}, {
        "Bucket": "ir-test-intake",
        "Key": "CASE-2/image.dd",
        "UploadId": "mpu-1",
        "MultipartUpload": ANY,
    })

    with stub:
        result = upload_artifact(
            s3, "ir-test-intake", "CASE-2", artifact, part_size=1000
        )

    assert result["multipart"] is True
    assert result["parts"] == 3
    stub.assert_no_pending_responses()


def test_failed_multipart_is_aborted(s3, tmp_path):
    """An abandoned multipart upload is billed storage no object listing shows."""
    artifact = tmp_path / "image.dd"
    artifact.write_bytes(b"w" * 2500)

    stub = Stubber(s3)
    stub.add_response("create_multipart_upload", {"UploadId": "mpu-2"}, ANY)
    stub.add_client_error("upload_part", service_error_code="InternalError")
    stub.add_response("abort_multipart_upload", {}, {
        "Bucket": "ir-test-intake",
        "Key": "CASE-3/image.dd",
        "UploadId": "mpu-2",
    })

    with stub, pytest.raises(Exception):
        upload_artifact(s3, "ir-test-intake", "CASE-3", artifact, part_size=1000)

    stub.assert_no_pending_responses()
```

- [x] **Step 2: Run the test to verify it fails**

```bash
cd cli && python -m pytest tests/test_upload.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'irctl.upload'`.

- [x] **Step 3: Write the upload module**

Create `cli/irctl/upload.py`:

```python
"""Upload with the digest attached (spec 4.2, amendment A1).

The client's SHA-256 travels on the PUT as x-amz-checksum-sha256. S3 verifies it
server-side and rejects a mismatch, so a corrupt transfer never becomes an
object. Nothing downstream re-hashes the artifact -- which is what lets the
recorder run inside a function timeout regardless of artifact size.

Multipart is hand-rolled rather than delegated to boto3's managed transfer,
because the part checksums are the whole point and the managed path does not
make it obvious whether they were attached.
"""

import os

from .digest import PART_SIZE, hash_file


def upload_artifact(s3, bucket, case_id, path, source=None, part_size=PART_SIZE):
    """Hash then upload. Returns a record describing what was sent."""
    digest = hash_file(path, part_size=part_size)
    key = f"{case_id}/{os.path.basename(path)}"

    # The recorder reads these off HeadObject. Without sha256 and case-id it
    # refuses the object, because an artifact whose digest was not recorded at
    # collection cannot enter the chain of custody.
    metadata = {
        "sha256": digest.sha256_hex,
        "case-id": case_id,
        "source": source or "unspecified",
    }

    if digest.size_bytes <= part_size:
        # Below the threshold the stored checksum IS the whole-file digest.
        with open(path, "rb") as handle:
            s3.put_object(
                Bucket=bucket,
                Key=key,
                Body=handle,
                ChecksumAlgorithm="SHA256",
                ChecksumSHA256=digest.sha256_b64,
                Metadata=metadata,
            )
        return {
            "key": key,
            "sha256": digest.sha256_hex,
            "size_bytes": digest.size_bytes,
            "multipart": False,
            "parts": 1,
            "metadata": metadata,
        }

    upload_id = s3.create_multipart_upload(
        Bucket=bucket,
        Key=key,
        ChecksumAlgorithm="SHA256",
        Metadata=metadata,
    )["UploadId"]

    completed = []
    try:
        with open(path, "rb") as handle:
            for number, part_checksum in enumerate(digest.part_digests_b64, start=1):
                chunk = handle.read(part_size)
                response = s3.upload_part(
                    Bucket=bucket,
                    Key=key,
                    UploadId=upload_id,
                    PartNumber=number,
                    Body=chunk,
                    ChecksumAlgorithm="SHA256",
                    ChecksumSHA256=part_checksum,
                )
                completed.append({
                    "ETag": response["ETag"],
                    "PartNumber": number,
                    "ChecksumSHA256": part_checksum,
                })

        s3.complete_multipart_upload(
            Bucket=bucket,
            Key=key,
            UploadId=upload_id,
            MultipartUpload={"Parts": completed},
        )
    except Exception:
        # An abandoned multipart upload is billed storage that no object listing
        # shows. The bucket lifecycle catches it eventually; this catches it now.
        s3.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)
        raise

    return {
        "key": key,
        "sha256": digest.sha256_hex,
        "size_bytes": digest.size_bytes,
        "multipart": True,
        "parts": len(completed),
        "metadata": metadata,
    }
```

- [x] **Step 4: Run the test to verify it passes**

```bash
cd cli && python -m pytest tests/test_upload.py -v
```

Expected: PASS, 4 tests.

- [x] **Step 5: Write the CLI entry point**

Create `cli/irctl/cli.py`:

```python
"""irctl command line.

Configuration comes from the environment so the CLI has no state of its own:

    IR_INTAKE_BUCKET   from `tofu output -raw intake_bucket`
    IR_CASES_TABLE     from `tofu output -raw cases_table`
    AWS_REGION         standard
"""

import argparse
import json
import os
import sys

import boto3

from .cases import CaseExistsError, open_case
from .upload import upload_artifact


def _require_env(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(
            f"{name} is not set. Get it with `tofu output -raw "
            f"{name.replace('IR_', '').lower()}` in envs/example/platform."
        )
    return value


def _cmd_case_open(args):
    ddb = boto3.client("dynamodb")
    try:
        record = open_case(
            ddb,
            _require_env("IR_CASES_TABLE"),
            args.case_id,
            retention_years=args.retention_years,
            object_lock_mode=args.object_lock_mode,
        )
    except CaseExistsError as exc:
        raise SystemExit(str(exc)) from exc
    print(json.dumps(record, indent=2))
    return 0


def _cmd_upload(args):
    s3 = boto3.client("s3")
    record = upload_artifact(
        s3,
        _require_env("IR_INTAKE_BUCKET"),
        args.case,
        args.path,
        source=args.source,
    )
    print(json.dumps(record, indent=2))
    print(
        "\nUploaded to intake. The recorder verifies, files and locks it within "
        "a few seconds; poll the artifacts table to confirm.",
        file=sys.stderr,
    )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="irctl", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    case = sub.add_parser("case", help="case lifecycle")
    case_sub = case.add_subparsers(dest="case_command", required=True)

    case_open = case_sub.add_parser("open", help="open a new case")
    case_open.add_argument("case_id")
    case_open.add_argument("--retention-years", type=int, default=3)
    case_open.add_argument(
        "--object-lock-mode",
        default="GOVERNANCE",
        choices=["GOVERNANCE", "COMPLIANCE"],
        help="COMPLIANCE is irreversible. Never use it outside a production IR account.",
    )
    case_open.set_defaults(func=_cmd_case_open)

    upload = sub.add_parser("upload", help="upload an artifact to intake")
    upload.add_argument("path")
    upload.add_argument("--case", required=True)
    upload.add_argument("--source", help="where the artifact came from, for custody")
    upload.set_defaults(func=_cmd_upload)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
```

- [x] **Step 6: Verify the CLI wires up**

```bash
cd cli && python -m irctl.cli --help && python -m irctl.cli upload --help
```

Expected: both print usage without traceback.

- [x] **Step 7: Commit**

```bash
git add cli/irctl/upload.py cli/irctl/cli.py cli/tests/test_upload.py
git commit -m "feat(irctl): checksummed upload and the command line"
```

---

### Task 12: CI runs the Python tests

**Files:**
- Modify: `.github/workflows/ci.yml`

- [x] **Step 1: Add the job**

Append to `.github/workflows/ci.yml`, at the same indentation as the existing `check:` job:

```yaml
  python:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      # Both suites are offline: irctl uses botocore.Stubber and the recorder's
      # tests are pure functions. No AWS credentials, no network, no cost --
      # the same discipline mock_provider gives the HCL.
      - name: irctl tests
        working-directory: cli
        run: |
          python -m pip install --upgrade pip
          python -m pip install -e ".[dev]"
          python -m pytest tests -v

      - name: intake recorder tests
        working-directory: modules/platform/lambda/intake
        run: |
          python -m pip install boto3 pytest
          python -m pytest test_handler.py -v
```

- [x] **Step 2: Verify both suites pass locally exactly as CI runs them**

```bash
cd cli && python -m pytest tests -v
cd ../modules/platform/lambda/intake && python -m pytest test_handler.py -v
```

Expected: 14 tests and 5 tests, all passing.

- [x] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run the irctl and recorder test suites"
```

---

### Task 13: The acceptance gate

Spec §9: Phase 2 is done when an artifact can be ingested by hand and is hashed, immutable, and recorded. This document is what proves it, and it follows the shape of `docs/acceptance/phase-1.md`.

**Files:**
- Create: `docs/acceptance/phase-2.md`

- [x] **Step 1: Write the acceptance document**

Create `docs/acceptance/phase-2.md`:

````markdown
# Phase 2 acceptance

Spec §9: *"An artifact can be ingested by hand, is hashed, immutable, and recorded."*

Run against a real AWS account. Everything here is cheap — S3 storage for a few test
objects, a handful of DynamoDB writes, and one Lambda invocation. **The appliance is not
needed; leave the environment dormant.**

## Setup

```bash
cd envs/example/platform
tofu apply

export AWS_REGION=$(tofu output -raw region 2>/dev/null || echo us-east-1)
export IR_INTAKE_BUCKET=$(tofu output -raw intake_bucket)
export IR_CASES_TABLE=$(tofu output -raw cases_table)
EVIDENCE=$(tofu output -raw evidence_bucket)
ARTIFACTS=$(tofu output -raw artifacts_table)

cd ../../../cli && python -m pip install -e .
```

## Checks

| # | Check | How | Pass |
|---|---|---|---|
| 1 | A case can be opened | `irctl case open CASE-TEST-001` | JSON record with `status: open`, `retention_years: 3` |
| 2 | Reopening is refused | `irctl case open CASE-TEST-001` again | Exits non-zero, names the case |
| 3 | An artifact uploads | `irctl upload --case CASE-TEST-001 sample.evtx --source acceptance` | JSON with a 64-character `sha256` |
| 4 | It reaches evidence | `aws s3 ls s3://$EVIDENCE/CASE-TEST-001/` | `sample.evtx` present within ~30s |
| 5 | Intake was cleared | `aws s3 ls s3://$IR_INTAKE_BUCKET/CASE-TEST-001/` | Empty |
| 6 | **It is immutable** | `aws s3api get-object-legal-hold --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx` | `"Status": "ON"` |
| 7 | **No retention clock has started** | `aws s3api get-object-retention --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx` | Error `NoSuchObjectLockConfiguration` — §5.2 starts the clock at case close, not upload |
| 8 | **Deletion is refused** | `aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx` | `AccessDenied` |
| 9 | It is recorded | `aws dynamodb get-item --table-name $ARTIFACTS --key '{"case_id":{"S":"CASE-TEST-001"},"sha256":{"S":"<hash from check 3>"}}'` | `status: recorded`, two custody entries |
| 10 | The digest matches the file | `sha256sum sample.evtx` | Identical to check 3's `sha256` |
| 11 | **A re-upload deduplicates** | `irctl upload --case CASE-TEST-001 sample.evtx` again | Intake empties; artifact row unchanged (`received_at` identical) |
| 12 | **A corrupt transfer is refused at PUT** | See below | `BadDigest`, and nothing lands in intake |
| 13 | An unknown case is refused | `irctl upload --case CASE-NOPE sample.evtx` | Object stays in intake; recorder logs name the case |
| 14 | Data events are recorded | `aws s3 ls s3://$(tofu output -raw audit_bucket)/AWSLogs/` | Prefix exists within ~10 min |

### Check 12 — corrupt transfer

The point of A1 is that S3, not a later pipeline step, catches this. Send a digest
that does not match the bytes:

```bash
python - <<'PY'
import base64, hashlib, os, boto3
s3 = boto3.client("s3")
wrong = base64.b64encode(hashlib.sha256(b"not the payload").digest()).decode()
try:
    s3.put_object(
        Bucket=os.environ["IR_INTAKE_BUCKET"], Key="CASE-TEST-001/corrupt.bin",
        Body=b"the actual payload", ChecksumAlgorithm="SHA256", ChecksumSHA256=wrong,
        Metadata={"sha256": "0" * 64, "case-id": "CASE-TEST-001"},
    )
    print("FAIL: S3 accepted a mismatched checksum")
except Exception as exc:
    print("PASS:", type(exc).__name__, exc)
PY
```

Pass: an error naming `BadDigest` or `InvalidRequest`, and `aws s3 ls` shows nothing.

### Checks 15 and 16 — de-risking Phase 4 for free

Phase 2 builds no case-close, so the retention path is never exercised. These two
probes cost nothing and prove the primitives behave as §5.2 assumes. Run them by hand.

**15 — retention then hold release, in that order:**

```bash
RETAIN=$(python -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

aws s3api put-object-retention --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --retention "{\"Mode\":\"GOVERNANCE\",\"RetainUntilDate\":\"$RETAIN\"}"

aws s3api put-object-legal-hold --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --legal-hold Status=OFF

aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx
```

Pass: the delete still fails. The hold is gone but retention now holds it — which is
exactly what case close must achieve, and why the order in §5.2 is not arbitrary.

**16 — break-glass actually breaks glass:**

```bash
aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --bypass-governance-retention
```

Pass: succeeds. This is what makes GOVERNANCE meaningfully different from COMPLIANCE,
and it is what §5.2.2 depends on for `tofu destroy` to work in development.

## Teardown

Governance-mode objects block `tofu destroy` until removed with the bypass, and the
manifest tables have deletion protection on by default:

```bash
aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --bypass-governance-retention
cd envs/example/platform
tofu apply -var='manifest_deletion_protection=false'
tofu destroy
```

## Defects found

| # | Defect | Fix |
|---|---|---|
| | *(fill in during the run — this table is the point of the exercise)* | |
````

- [x] **Step 2: Commit**

```bash
git add docs/acceptance/phase-2.md
git commit -m "docs: Phase 2 acceptance gate"
```

---

## Self-Review

**Spec coverage.** §5.1 buckets → Tasks 1, 2, 4. §5.2 retention model → Tasks 1, 6 (legal hold at PUT, no retention), 13 (checks 6, 7, 15). §5.2.1 compliance guard → Task 1. §5.2.2 development account → Tasks 3 (`manifest_deletion_protection`), 5 (break-glass), 13 (teardown). §5.3 case store → Tasks 3, 10. §5.4 case close → **deliberately not built**; §9 places it in Phase 4. Task 13 checks 15 and 16 probe its primitives by hand so Phase 4 does not discover them cold. §5.5 posture independence → Tasks 6, 7. §4.2 hashing → Tasks 9, 11. §9 "manual ingest" → Tasks 11, 13.

**Known gaps, stated rather than hidden:**

- **No `irctl case close`.** Phase 4 per §9. The primitives are probed by hand in Task 13.
- **The copy has a documented size ceiling** — the recorder drives it under a 900-second timeout. Phase 3 moves it into Batch. It fails loudly and the object stays in intake.
- **A sub-second window exists between the copy and the legal hold.** Deliberate; the reasoning is in `_copy_and_hold`.
- **`SNYK-CC-TF-45` will still report on the tooling bucket.** CloudTrail data events now cover it, which is a real compensating control, but the rule looks for `aws_s3_bucket_logging`. Whether that makes a scoped ignore defensible is a judgement call for the reviewer, not this plan.
- **Snyk IaC should be re-run after Task 4.** New buckets and a new key policy are exactly what it is good at, and the global instruction to scan new first-party code applies.

**Type consistency check.** `hash_file` returns `FileDigest` with `sha256_hex`/`sha256_b64`/`part_digests_b64`/`size_bytes`, used under those names in Task 11. `validate_metadata` returns `ArtifactMetadata` with `sha256`/`case_id`/`source`/`size_bytes`, used under those names in `_claim`, `_require_open_case` and `_copy_and_hold`. `open_case` returns a plain dict, printed directly by `_cmd_case_open`. Object metadata keys are `sha256`, `case-id`, `source` in both `upload.py` (written) and `handler.py` (read) — boto3 lowercases and strips the `x-amz-meta-` prefix, which is why the reader uses `case-id` and not `case_id`.
