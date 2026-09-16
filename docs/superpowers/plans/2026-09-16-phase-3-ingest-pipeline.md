# Phase 3 — Ingest Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** An artifact uploaded with `irctl upload` becomes a Timesketch timeline with no manual
step, whether it arrived while the environment was active or while it was dormant.

**Architecture:** A Batch fleet on EC2 runs `log2timeline` inside an image built `FROM` the
Timesketch image by digest, so the plaso that writes a `.plaso` is the plaso that reads it back.
Step Functions orchestrates; it is started either by an EventBridge rule on the *evidence* bucket
(low latency) or by a scheduled reconciler that sweeps the manifest (correctness, including the
backlog that accumulates during dormancy). Both paths converge on one conditional DynamoDB write,
so they cannot double-process.

**Tech Stack:** OpenTofu 1.12, AWS Batch on EC2, Step Functions, EventBridge, Lambda (Python
3.12), CodeBuild, Docker, `botocore.Stubber`, `tofu test` with `mock_provider`.

**Spec:** `docs/superpowers/specs/2026-09-14-ir-infrastructure-design.md` — §4 in full, plus §3.2
(dormancy), §5.5 (recording is not posture-gated), §7 (layout), §8 (testing), §9 (phasing). Read
§12 Amendments before trusting a remembered reading; this plan adds A9–A12.

---

## Global Constraints

Copied verbatim from the spec and `CLAUDE.md`. Every task's requirements implicitly include these.

- **Image digest pinning (§4.5).** Every image reference on the path to the appliance or the
  worker is `repo@sha256:...`, never a tag. ECR repositories are `IMMUTABLE`.
- **The plaso that produces a timeline and the plaso that ingests it are the same binary (§4.5).**
  The worker image's `FROM` digest must be the digest resolved for `timesketch` in the same
  CodeBuild run.
- **No internet egress (§3.3).** No IGW, no NAT. Everything reaches AWS through VPC endpoints.
  Anything the worker needs that AL2023 or the base image does not carry must be mirrored into the
  account first.
- **The S3 endpoint policy has two statements and the second is load-bearing.** Anonymous AL2023
  repo fetches and AWS-presigned ECR layer URLs do not carry `aws:PrincipalAccount`. Do not delete
  it.
- **Dormancy is a variable, never a destroy (§3.2).** `posture = "dormant"` must never destroy the
  VPC, subnets, route tables, security groups, DNS, the data volume, or anything in the evidence
  store.
- **Recording is never posture-gated (§5.5, A4).** Nothing this plan adds may place the intake
  recorder, its copy, or its legal hold behind a resource that dormancy disables.
- **No bucket-level default retention on the Object Lock buckets.** Never add a
  `rule { default_retention { ... } }` to `aws_s3_bucket_object_lock_configuration`.
- **`s3:GetObject` on the evidence bucket appears in exactly two roles after this plan:** the
  recorder's (scoped to *intake*, never evidence) and the new worker's (scoped to evidence). No
  role gains `s3:DeleteObject`, `s3:DeleteObjectVersion`, or `s3:PutObjectLegalHold` on evidence
  except the break-glass role that already holds them.
- **Use `jsonencode`, never `aws_iam_policy_document`.** The data source's rendered `.json` is
  computed, and `mock_provider` replaces it with an invented string.
- **`mock_resource` defaults apply to every instance of a type.** All S3 buckets share one mocked
  ARN, so never assert that a policy does or does not *mention* a bucket. Assert on **actions**.
- **Several provider block types are sets, not lists.** Use `one(...)` and compare against
  `toset([...])`, never `tolist([...])`.
- **`lifecycle` is a meta-argument and cannot be read in an assertion.** Assert the property it
  protects.
- **Run `python scripts/sync-test-mocks.py` rather than editing one platform test file's mock
  preamble.** Task 1 fixes that script's hardcoded path first.
- **A test can assert an impossibility and pass.** When an assertion encodes a *behaviour* of an
  AWS service rather than a *shape* of the config, say so in a comment at the assertion.
- **Python:** `botocore.Stubber`, never live calls. No dummy AWS credentials (Snyk Code
  `HardcodedNonCryptoSecret`; Stubber intercepts before signing, so they are pointless anyway).
  Never pass `ANY` as a whole `expected_params` dict. No boto3 client creation at import time.
- **Compose pin stays at `v5.5.1`.** This plan re-syncs the compose *file* toward upstream. It must
  not also bump the compose pin: v5.0.0 made a dependency on a profile-disabled service a hard
  error, and our file's lack of profiles is the only reason a v5 compose runs it.
- **`set -x` is on throughout cloud-init.** Anything handling a secret is wrapped in
  `set +x` / `set -x`.
- **Commit style:** conventional commits, scoped pathspec (`git commit -- <paths>`), never
  `add -A`. End every commit message with the two attribution lines used elsewhere on this branch.
- **Verification:** `bash scripts/check.sh check` must pass before each commit. Confirm the `tofu
  test` counts actually moved — a `-filter` that matches nothing reports `Success! 0 passed`.

---

## File Structure

**Created**

| Path | Responsibility |
|---|---|
| `containers/plaso-worker/worker.py` | Worker entrypoint. Two subcommands: `timeline`, `import`. Downloads evidence, runs `log2timeline.py`, uploads `.plaso`, imports to Timesketch. |
| `containers/plaso-worker/timesketch_client.py` | Minimal REST client: session login, CSRF token, sketch resolve-or-create, file upload, event count. The API client package is not in the image. |
| `containers/plaso-worker/Dockerfile` | `FROM <timesketch>@<digest>`, `COPY` the two modules, entrypoint. |
| `containers/plaso-worker/test_worker.py` | Routing, argument handling, S3 calls under `Stubber`. |
| `containers/plaso-worker/test_timesketch_client.py` | Login/CSRF/upload against a stubbed transport. |
| `containers/plaso-worker/requirements-dev.txt` | `pytest`, `boto3`, `requests` for the test job. |
| `modules/analysis/batch.tf` | Worker security group, launch template, compute environment, job queue, job definition, job role. |
| `modules/analysis/pipeline.tf` | Step Functions state machine and role; EventBridge rule; reconciler and claim Lambdas; SNS topic. |
| `modules/analysis/lambda/pipeline/handler.py` | Two handlers in one module: `claim_handler` (first state of the machine) and `sweep_handler` (scheduled reconciler). |
| `modules/analysis/lambda/pipeline/test_handler.py` | Routing and claim logic under `Stubber`. |
| `modules/analysis/templates/scratch.sh.tftpl` | Launch-template user data: find instance-store NVMe, RAID0, format, mount `/scratch`. |
| `modules/analysis/tests/pipeline.tftest.hcl` | Posture gating, job role asymmetry, digest pinning. |
| `docs/acceptance/phase-3.md` | The Phase 3 acceptance gate. Written before the run, filled in after. |

**Modified**

| Path | Change |
|---|---|
| `scripts/sync-test-mocks.py:77` | Hardcoded `C:/dev/incident-infra/...` → path relative to the script. |
| `modules/platform/ecr.tf` | Add a `plaso-worker` repository, built not mirrored, with its own lifecycle policy. |
| `modules/platform/network.tf` | Add the free DynamoDB gateway endpoint. |
| `modules/platform/evidence.tf` | Add `aws_s3_bucket_notification` on the evidence bucket with `eventbridge = true`. |
| `modules/platform/iam.tf` | Appliance role: allow ECR pull from the new repository. |
| `modules/platform/outputs.tf` | Export the plaso-worker repository URL and the evidence/plaso bucket ARNs the analysis layer needs. |
| `modules/images/variables.tf` | `ecr_repository_urls` validation gains `plaso-worker`. |
| `modules/images/codebuild.tf` | New env vars; upload `worker.py` to the tooling bucket. |
| `modules/images/buildspec.yml` | New stage: build and push the worker image, publish its digest to SSM. |
| `modules/analysis/variables.tf` | Bucket names/ARNs, table names/ARNs, worker sizing, `pipeline_notification_emails`. |
| `modules/analysis/endpoints.tf` | Add `ecs`, `ecs-agent`, `ecs-telemetry`. |
| `modules/analysis/appliance.tf` | Read the `plaso-worker` digest; pass the pipeline user and bind address into the templates. |
| `modules/analysis/secrets.tf` | A `pipeline` Timesketch account secret. |
| `modules/analysis/templates/docker-compose.yml.tftpl` | Healthchecks + `service_healthy` gating; bind the web port on the private IP as well as loopback. |
| `modules/analysis/templates/cloud-init.sh.tftpl` | Create the `pipeline` Timesketch user. |
| `modules/analysis/outputs.tf` | State machine ARN, job queue ARN, SNS topic ARN. |
| `envs/example/platform/main.tf`, `envs/example/analysis/main.tf` | Wire the new inputs and outputs. |
| `docs/superpowers/specs/2026-09-14-ir-infrastructure-design.md` | Amendments A9–A12; §4.1 diagram corrected. |
| `CLAUDE.md`, `NEXT.md` | Durable facts and the hand-off. |

---

### Task 1: Platform prerequisites

Everything Phase 3 needs from the permanent layer, in one reviewable unit: a repository for the
built worker image, a free DynamoDB gateway endpoint so the worker can write the manifest without
an interface endpoint, the EventBridge notification that gives the pipeline its low-latency
trigger, and the outputs the analysis layer consumes.

**Files:**
- Modify: `scripts/sync-test-mocks.py:77`
- Modify: `modules/platform/ecr.tf`
- Modify: `modules/platform/network.tf`
- Modify: `modules/platform/evidence.tf`
- Modify: `modules/platform/iam.tf`
- Modify: `modules/platform/outputs.tf`
- Test: `modules/platform/tests/storage.tftest.hcl`, `modules/platform/tests/evidence.tftest.hcl`,
  `modules/platform/tests/network.tftest.hcl`

**Interfaces:**
- Consumes: nothing.
- Produces: `aws_ecr_repository.worker` (name `<prefix>/plaso-worker`); platform outputs
  `plaso_worker_repository_url`, `evidence_bucket_arn`, `plaso_bucket_arn`, `cases_table_arn`,
  `artifacts_table_arn` — all strings. Tasks 4, 5, 6 and 8 rely on these exact names.

- [ ] **Step 1: Fix the hardcoded path in the mock sync script**

`scripts/sync-test-mocks.py` line 77 pins an absolute Windows path, so it fails on any other
checkout and on every CI runner. Replace:

```python
tests = pathlib.Path("C:/dev/incident-infra/modules/platform/tests")
```

with:

```python
tests = pathlib.Path(__file__).resolve().parent.parent / "modules" / "platform" / "tests"
```

- [ ] **Step 2: Verify the script still rewrites every platform test file**

Run: `python scripts/sync-test-mocks.py && git diff --stat modules/platform/tests`

Expected: the script prints one line per test file and `git diff --stat` reports no changes — the
preamble is already canonical, so a correct path is a no-op. A non-empty diff means the preamble
had drifted and the script just repaired it; read the diff before continuing.

- [ ] **Step 3: Write the failing test for the worker repository**

Append to `modules/platform/tests/storage.tftest.hcl`:

```hcl
# The worker image is BUILT from the mirrored Timesketch image, not mirrored, so
# it needs its own repository rather than a sixth entry in local.mirrored_images:
# a built image wants "keep the last N", where a mirror wants "expire untagged".
run "worker_repository_is_immutable" {
  command = plan

  assert {
    condition     = aws_ecr_repository.worker.image_tag_mutability == "IMMUTABLE"
    error_message = "A mutable worker tag would let a re-push change what an existing job definition resolves to, which is what spec 4.5 forbids."
  }

  assert {
    condition     = aws_ecr_repository.worker.name == "${var.name_prefix}/plaso-worker"
    error_message = "The images module and the analysis job definition both address this repository by name."
  }
}
```

- [ ] **Step 4: Run it and watch it fail**

Run: `cd modules/platform && tofu test -filter='tests\storage.tftest.hcl'`

Expected: FAIL — `A managed resource "aws_ecr_repository" "worker" has not been declared`.

- [ ] **Step 5: Add the repository**

In `modules/platform/ecr.tf`, after the mirror resources:

```hcl
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
```

- [ ] **Step 6: Run the test and watch it pass**

Run: `cd modules/platform && tofu test -filter='tests\storage.tftest.hcl'`

Expected: PASS. Check the run count moved — a filter matching nothing also prints `Success!`.

- [ ] **Step 7: Write the failing test for the DynamoDB gateway endpoint**

Append to `modules/platform/tests/network.tftest.hcl`:

```hcl
# Gateway endpoints are route-table entries: free, and unaffected by dormancy.
# The Batch worker writes timeline_id and event_count to the manifest from
# inside the VPC, and an interface endpoint for DynamoDB would both bill per ENI
# and -- living in the analysis layer -- disappear when dormant.
run "dynamodb_reachable_without_an_interface_endpoint" {
  command = plan

  assert {
    condition     = aws_vpc_endpoint.dynamodb.vpc_endpoint_type == "Gateway"
    error_message = "A DynamoDB interface endpoint would bill per ENI and would be destroyed by dormancy; a gateway endpoint is free and permanent."
  }
}
```

- [ ] **Step 8: Run it and watch it fail**

Run: `cd modules/platform && tofu test -filter='tests\network.tftest.hcl'`

Expected: FAIL — `aws_vpc_endpoint.dynamodb has not been declared`.

- [ ] **Step 9: Add the gateway endpoint**

First confirm the private route table's resource name:
`grep -n 'aws_route_table' modules/platform/network.tf`. Use whatever it is rather than assuming
`private`. In `modules/platform/network.tf`, immediately after the S3 gateway endpoint:

```hcl
# --- DynamoDB gateway endpoint ---
#
# Free, like the S3 one, and in the permanent layer for the same reason: the
# Batch worker updates the artifact manifest from inside the VPC, and a control
# path that dormancy can destroy has no business in the chain of custody.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-dynamodb" })
}
```

- [ ] **Step 10: Run the test and watch it pass**

Run: `cd modules/platform && tofu test -filter='tests\network.tftest.hcl'`

Expected: PASS.

- [ ] **Step 11: Write the failing test for the evidence-bucket EventBridge notification**

Append to `modules/platform/tests/evidence.tftest.hcl`:

```hcl
# The pipeline trigger hangs off EVIDENCE, not intake (amendment A11).
#
# The recorder deletes the intake object once it has copied and held it, so an
# intake-triggered pipeline would race that delete and would read from a bucket
# with a seven-day expiry. Evidence is the first place the artifact is both
# immutable and permanent.
#
# This asserts the notification is CONFIGURED, not that EventBridge delivers.
# mock_provider evaluates config, not service behaviour; only an acceptance run
# can confirm an event actually arrives.
run "evidence_bucket_publishes_to_eventbridge" {
  command = plan

  assert {
    condition     = aws_s3_bucket_notification.evidence.eventbridge == true
    error_message = "Without this the pipeline has no low-latency trigger and every artifact waits for the reconciler sweep."
  }
}
```

- [ ] **Step 12: Run it and watch it fail**

Run: `cd modules/platform && tofu test -filter='tests\evidence.tftest.hcl'`

Expected: FAIL — `aws_s3_bucket_notification.evidence has not been declared`.

- [ ] **Step 13: Add the notification**

In `modules/platform/evidence.tf`, after `aws_s3_bucket_policy.evidence`:

```hcl
# Amendment A11: the pipeline trigger fans out from evidence, not from intake.
#
# Spec 4.1's diagram had intake feeding both the recorder and EventBridge. That
# predates the recorder clearing the intake object once recorded -- a pipeline
# started from intake would race a DeleteObject and read a bucket whose contents
# expire in intake_expiry_days.
#
# Deliberately no lambda_function block. aws_s3_bucket_notification is a
# whole-bucket resource: a second one pointed at the same bucket silently
# replaces the first, which is how the intake recorder's notification would
# vanish if this were ever mis-targeted.
resource "aws_s3_bucket_notification" "evidence" {
  bucket      = aws_s3_bucket.evidence.id
  eventbridge = true
}
```

- [ ] **Step 14: Run the test and watch it pass**

Run: `cd modules/platform && tofu test -filter='tests\evidence.tftest.hcl'`

Expected: PASS.

- [ ] **Step 15: Let the appliance pull the worker image, and export what analysis needs**

The appliance role's `EcrPull` statement is scoped to `[for r in aws_ecr_repository.mirror : r.arn]`,
which excludes the new repository. The appliance does not run the worker in normal operation, but
it is the box an operator uses to reproduce a timeline by hand, and the omission surfaces as a 403
naming a layer digest. In `modules/platform/iam.tf`, change the `EcrPull` resource list to:

```hcl
        Resource = concat(
          [for r in aws_ecr_repository.mirror : r.arn],
          [aws_ecr_repository.worker.arn],
        )
```

Then append to `modules/platform/outputs.tf`:

```hcl
output "plaso_worker_repository_url" {
  value       = aws_ecr_repository.worker.repository_url
  description = "ECR repository for the built plaso worker image."
}

output "evidence_bucket_arn" {
  value       = aws_s3_bucket.evidence.arn
  description = "Evidence bucket ARN. The Batch worker is the first component that legitimately reads it."
}

output "plaso_bucket_arn" {
  value       = aws_s3_bucket.plaso.arn
  description = "Destination for .plaso files produced by the worker."
}

output "cases_table_arn" {
  value       = aws_dynamodb_table.cases.arn
  description = "Case store ARN, for the pipeline's claim step."
}

output "artifacts_table_arn" {
  value       = aws_dynamodb_table.artifacts.arn
  description = "Artifact manifest ARN, for the claim step and the worker's finalisation."
}
```

- [ ] **Step 16: Run the whole platform suite and the repo check**

Run: `cd modules/platform && tofu test` then `bash scripts/check.sh check`

Expected: every run block passes and the platform count rises from 48 to 51. If `tflint` is absent
the check prints a one-line skip on stderr and still exits 0 — install it (recipe in `CLAUDE.md`)
rather than letting a `terraform_unused_declarations` failure reach CI looking like a clean local
run.

- [ ] **Step 17: Commit**

```bash
git commit -- scripts/sync-test-mocks.py modules/platform/ecr.tf modules/platform/network.tf \
  modules/platform/evidence.tf modules/platform/iam.tf modules/platform/outputs.tf \
  modules/platform/tests -F docs/superpowers/plans/.commit-msg-task1
```

Write the message to that scratch file first (then delete it), or pass `-m` twice. The message:

```
feat(platform): prerequisites for the Phase 3 pipeline

Worker image repository (built, not mirrored, so its own lifecycle policy), a
free DynamoDB gateway endpoint so the worker writes the manifest without an
interface endpoint dormancy would destroy, and the evidence bucket's EventBridge
notification -- the pipeline trigger hangs off evidence rather than intake
because the recorder clears the intake object once it has copied and held it.

Also fixes the hardcoded absolute path in scripts/sync-test-mocks.py, which
would have failed on any checkout but one.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS
```

- [ ] **Step 18: Push and open the draft PR**

Unpushed work is unbacked, and the PR gives the branch an address that survives this session.

```bash
git push -u origin feat/phase-3-ingest-pipeline
gh pr create --draft --base main --title "Phase 3: ingest pipeline" --body "Batch worker, Step Functions, routing, and the reconciler that timelines the backlog dormancy leaves behind.

Plan: docs/superpowers/plans/2026-09-16-phase-3-ingest-pipeline.md

Draft until the Phase 3 acceptance run.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS"
```

---

### Task 2: Timesketch REST client

The API client package (`timesketch_api_client`) is **not installed in the Timesketch release
image**, so scripted interaction means the REST API with a session cookie and a CSRF token. This
task builds that client alone, with no AWS in it, so it can be tested against an injected fake
session rather than a network.

**Files:**
- Create: `containers/plaso-worker/timesketch_client.py`
- Create: `containers/plaso-worker/test_timesketch_client.py`
- Create: `containers/plaso-worker/requirements-dev.txt`

**Interfaces:**
- Consumes: nothing.
- Produces: `TimesketchClient(base_url: str, username: str, password: str, session=None)` with
  methods `login() -> None`, `resolve_sketch(name: str) -> int`,
  `upload(path: str, sketch_id: int, timeline_name: str) -> int` (returns timeline id), and
  `event_count(sketch_id: int, timeline_id: int) -> int`. Raises `TimesketchError`. Task 3 calls
  exactly these.

- [ ] **Step 1: Create the dev requirements file**

`containers/plaso-worker/requirements-dev.txt` — the image itself already carries `requests` and
`boto3` is only needed by `worker.py`, but CI runs these tests outside the image:

```
boto3
pytest
requests
```

- [ ] **Step 2: Write the failing tests**

`containers/plaso-worker/test_timesketch_client.py`:

```python
"""No network, no live Timesketch. The session is injected.

This mirrors the discipline botocore.Stubber gives the AWS paths: assert the
exact calls made, not merely that nothing raised.
"""

import pytest

from timesketch_client import TimesketchClient, TimesketchError


class FakeResponse:
    def __init__(self, status_code=200, json_data=None, cookies=None):
        self.status_code = status_code
        self._json = json_data if json_data is not None else {}
        self.cookies = cookies or {}
        self.text = ""

    def json(self):
        return self._json


class FakeSession:
    """Records every call and returns queued responses in order."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []
        self.cookies = {}
        self.headers = {}

    def _next(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        if not self._responses:
            raise AssertionError(f"unexpected {method} {url}: no response queued")
        return self._responses.pop(0)

    def get(self, url, **kwargs):
        return self._next("GET", url, **kwargs)

    def post(self, url, **kwargs):
        return self._next("POST", url, **kwargs)


def test_login_sends_the_csrf_token_it_was_given():
    session = FakeSession([
        FakeResponse(cookies={"csrf_token": "tok-123"}),
        FakeResponse(200),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    client.login()

    method, url, kwargs = session.calls[1]
    assert method == "POST"
    assert url == "http://ts:5000/login/"
    assert kwargs["data"]["username"] == "pipeline"
    assert kwargs["headers"]["X-CSRFToken"] == "tok-123"


def test_login_without_a_csrf_cookie_fails_loudly():
    session = FakeSession([FakeResponse(cookies={})])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    with pytest.raises(TimesketchError, match="CSRF"):
        client.login()


def test_resolve_sketch_reuses_an_existing_sketch():
    session = FakeSession([
        FakeResponse(json_data={"objects": [[{"id": 7, "name": "CASE-1"}]]}),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    assert client.resolve_sketch("CASE-1") == 7
    assert len(session.calls) == 1, "a sketch that exists must not be created again"


def test_resolve_sketch_creates_one_when_absent():
    session = FakeSession([
        FakeResponse(json_data={"objects": [[]]}),
        FakeResponse(json_data={"objects": [{"id": 9}]}),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    assert client.resolve_sketch("CASE-2") == 9
    assert session.calls[1][0] == "POST"


def test_upload_returns_the_timeline_id():
    session = FakeSession([
        FakeResponse(json_data={"objects": [{"id": 42}]}),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    timeline_id = client.upload(__file__, sketch_id=7, timeline_name="triage")

    assert timeline_id == 42


def test_upload_rejects_a_non_2xx_without_inventing_a_timeline():
    session = FakeSession([FakeResponse(status_code=500)])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    with pytest.raises(TimesketchError, match="500"):
        client.upload(__file__, sketch_id=7, timeline_name="triage")


def test_event_count_reads_the_timeline_record():
    session = FakeSession([
        FakeResponse(json_data={"objects": [{"id": 42, "datasources": [{"total_file_events": 1337}]}]}),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    assert client.event_count(sketch_id=7, timeline_id=42) == 1337


def test_event_count_of_a_timeline_with_no_datasources_is_zero():
    """Zero is a real answer, not an error: spec 4.3 falls back and flags for a
    responder when plaso produced nothing. Raising here would turn a routing
    outcome into a pipeline failure."""
    session = FakeSession([
        FakeResponse(json_data={"objects": [{"id": 42, "datasources": []}]}),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    assert client.event_count(sketch_id=7, timeline_id=42) == 0
```

- [ ] **Step 3: Run them and watch them fail**

Run: `cd containers/plaso-worker && python -m pytest test_timesketch_client.py -v`

Expected: FAIL at collection — `ModuleNotFoundError: No module named 'timesketch_client'`.

- [ ] **Step 4: Write the client**

`containers/plaso-worker/timesketch_client.py`:

```python
"""Minimal Timesketch REST client (spec 4.1 finalisation).

timesketch_api_client is NOT installed in the release image, so scripted
interaction is the REST API with a session cookie and a CSRF token. Timesketch
auth is local accounts, SSO_ENABLED, or GOOGLE_OIDC_* -- there is no AWS IAM
integration, so SSM authenticates the tunnel a responder uses and never the
application. This client logs in as the dedicated `pipeline` account.

The session is injectable so the tests never open a socket.
"""

import os

import requests


class TimesketchError(Exception):
    """Timesketch did not do what was asked. The artifact stays in evidence."""


class TimesketchClient:
    def __init__(self, base_url, username, password, session=None, timeout=300):
        self.base_url = base_url.rstrip("/")
        self._username = username
        self._password = password
        self._session = session if session is not None else requests.Session()
        self._timeout = timeout
        self._csrf = None

    def _url(self, path):
        return f"{self.base_url}{path}"

    def _check(self, response, what):
        if not 200 <= response.status_code < 300:
            raise TimesketchError(f"{what}: HTTP {response.status_code}")
        return response

    def login(self):
        """Fetch the login form for its CSRF cookie, then post credentials."""
        form = self._session.get(self._url("/login/"), timeout=self._timeout)
        token = form.cookies.get("csrf_token")
        if not token:
            raise TimesketchError(
                "no CSRF token on the login form. Timesketch sets csrf_token as a "
                "cookie on GET /login/; its absence usually means the web container "
                "is up but not yet ready."
            )
        self._csrf = token

        self._check(
            self._session.post(
                self._url("/login/"),
                data={"username": self._username, "password": self._password},
                headers={"X-CSRFToken": token},
                timeout=self._timeout,
            ),
            "login",
        )

    def _headers(self):
        return {"X-CSRFToken": self._csrf} if self._csrf else {}

    def resolve_sketch(self, name):
        """A case is a data concept (D11): one sketch per case, reused."""
        listing = self._check(
            self._session.get(self._url("/api/v1/sketches/"), timeout=self._timeout),
            "list sketches",
        ).json()

        for sketch in _flatten(listing.get("objects", [])):
            if sketch.get("name") == name:
                return sketch["id"]

        created = self._check(
            self._session.post(
                self._url("/api/v1/sketches/"),
                json={"name": name, "description": name},
                headers=self._headers(),
                timeout=self._timeout,
            ),
            "create sketch",
        ).json()
        return _first(created)["id"]

    def upload(self, path, sketch_id, timeline_name):
        with open(path, "rb") as handle:
            response = self._session.post(
                self._url("/api/v1/upload/"),
                data={"name": timeline_name, "sketch_id": str(sketch_id)},
                files={"file": (os.path.basename(path), handle)},
                headers=self._headers(),
                timeout=self._timeout,
            )
        return _first(self._check(response, "upload").json())["id"]

    def event_count(self, sketch_id, timeline_id):
        record = _first(
            self._check(
                self._session.get(
                    self._url(f"/api/v1/sketches/{sketch_id}/timelines/{timeline_id}/"),
                    timeout=self._timeout,
                ),
                "read timeline",
            ).json()
        )
        # Zero is a legitimate answer -- spec 4.3 flags it for a responder rather
        # than failing the pipeline.
        return sum(ds.get("total_file_events", 0) for ds in record.get("datasources", []))


def _flatten(objects):
    """Timesketch wraps collections one level deeper than single records."""
    for entry in objects:
        if isinstance(entry, list):
            yield from entry
        else:
            yield entry


def _first(payload):
    objects = list(_flatten(payload.get("objects", [])))
    if not objects:
        raise TimesketchError(f"expected an object in the response, got {payload!r}")
    return objects[0]
```

- [ ] **Step 5: Run the tests and watch them pass**

Run: `cd containers/plaso-worker && python -m pytest test_timesketch_client.py -v`

Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git commit -- containers/plaso-worker -m "feat(worker): minimal Timesketch REST client

timesketch_api_client is not in the release image, so the pipeline talks to the
REST API with a session cookie and a CSRF token. The session is injectable so
the tests never open a socket.

Zero events is a return value, not an exception: spec 4.3 falls back and flags
for a responder, and raising here would turn a routing outcome into a failure.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS"
```

---

### Task 3: Worker entrypoint and image

The worker is told what to do; it does not decide. Routing lives in the claim Lambda (Task 6), so
there is one copy of that rule and it is the one with tests around it.

**Files:**
- Create: `containers/plaso-worker/worker.py`
- Create: `containers/plaso-worker/test_worker.py`
- Create: `containers/plaso-worker/Dockerfile`

**Interfaces:**
- Consumes: `TimesketchClient` from Task 2.
- Produces: a container whose entrypoint is `python3 /usr/local/bin/worker.py`, accepting
  `timeline --case-id ID --sha256 HEX --evidence-key KEY` and
  `import --case-id ID --sha256 HEX --key KEY --bucket-kind {evidence,plaso}`. Task 5's job
  definition and Task 6's state machine build exactly these argument vectors.
  Module-level helpers `plaso_key(case_id, sha256) -> str` and
  `timeline_name(evidence_key) -> str` are relied on by Task 6's tests.

- [ ] **Step 1: Write the failing tests**

`containers/plaso-worker/test_worker.py`:

```python
"""botocore.Stubber, never live calls -- the same discipline mock_provider gives
the HCL. No dummy credentials: Stubber intercepts at before-call, which runs
ahead of signing, so nothing ever authenticates and hardcoded keys would only
trip Snyk Code's HardcodedNonCryptoSecret rule.
"""

import boto3
import pytest
from botocore.stub import Stubber

import worker


def test_import_reaches_for_no_aws_configuration():
    """A module that builds a boto3 client at import needs a resolvable region,
    so it imports fine on a developer machine and fails on every CI runner with
    NoRegionError raised during collection."""
    assert worker._CLIENTS == {}


def test_plaso_key_is_namespaced_by_case():
    """Case close operates across a prefix, so the prefix must be the case."""
    assert worker.plaso_key("CASE-2026-014", "abc123") == "CASE-2026-014/abc123.plaso"


def test_timeline_name_drops_the_case_prefix_and_the_extension():
    assert worker.timeline_name("CASE-2026-014/triage.zip") == "triage"
    assert worker.timeline_name("CASE-2026-014/nested/dir/evtx.evtx") == "evtx"


def test_missing_configuration_names_the_module_that_sets_it(monkeypatch):
    monkeypatch.delenv("EVIDENCE_BUCKET", raising=False)
    with pytest.raises(worker.WorkerError, match="modules/analysis"):
        worker._config("EVIDENCE_BUCKET")


def test_download_asks_for_the_object_it_was_told_to(tmp_path, monkeypatch):
    s3 = boto3.client("s3", region_name="us-east-1")
    stub = Stubber(s3)
    stub.add_response(
        "get_object",
        {"Body": _body(b"bytes")},
        {"Bucket": "ir-evidence", "Key": "CASE-1/triage.zip"},
    )
    stub.activate()
    monkeypatch.setitem(worker._CLIENTS, "s3", s3)

    dest = tmp_path / "triage.zip"
    worker.download("ir-evidence", "CASE-1/triage.zip", str(dest))

    stub.assert_no_pending_responses()
    assert dest.read_bytes() == b"bytes"


def test_record_timeline_writes_only_the_two_fields_it_owns(monkeypatch):
    """Status is owned by the state machine. If the worker also wrote status the
    two would race on a retry and the manifest would disagree with reality."""
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_response(
        "update_item",
        {},
        {
            "TableName": "ir-artifacts",
            "Key": {"case_id": {"S": "CASE-1"}, "sha256": {"S": "abc"}},
            "UpdateExpression": "SET timeline_id = :t, event_count = :c",
            "ExpressionAttributeValues": {":t": {"N": "42"}, ":c": {"N": "1337"}},
        },
    )
    stub.activate()
    monkeypatch.setitem(worker._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    worker.record_timeline("CASE-1", "abc", timeline_id=42, event_count=1337)

    stub.assert_no_pending_responses()


def test_run_log2timeline_raises_with_the_exit_code(monkeypatch, tmp_path):
    def fake_run(argv, **kwargs):
        class Result:
            returncode = 1
            stderr = "parser exploded"
        return Result()

    monkeypatch.setattr(worker.subprocess, "run", fake_run)

    with pytest.raises(worker.WorkerError, match="exit 1"):
        worker.run_log2timeline(str(tmp_path / "in"), str(tmp_path / "out.plaso"))


def _body(data):
    import io
    from botocore.response import StreamingBody
    return StreamingBody(io.BytesIO(data), len(data))
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd containers/plaso-worker && python -m pytest test_worker.py -v`

Expected: FAIL at collection — `ModuleNotFoundError: No module named 'worker'`.

- [ ] **Step 3: Write the worker**

`containers/plaso-worker/worker.py`:

```python
"""plaso worker -- spec 4.1, 4.5, 4.6.

Runs on AWS Batch, EC2 on-demand (D14, re-argued as amendment A9): plaso is
disk-bound and D8 targets 100 GB to 1 TB per incident, so the scratch area is
instance-store NVMe rather than network storage.

This image is `FROM` the Timesketch image by digest, which is what makes the
spec 4.5 parity invariant structural: the log2timeline.py that writes a .plaso
here is the same binary the appliance reads it back with. Timesketch rejects
.plaso files produced by a newer plaso than it runs, and upstream installs
plaso-tools UNPINNED from ppa:gift, so two builds of one release tag can differ.

This process is told what to do. Routing -- the spec 4.3 rule -- lives in the
claim Lambda so there is exactly one copy of it.

It reads evidence and writes .plaso. It holds no delete and no legal-hold
permission anywhere; see the job role in modules/analysis/batch.tf. The
recorder's read/write asymmetry is a property of the RECORDER, not of the
bucket, and nothing enforces it for a second reader but that policy.
"""

import argparse
import logging
import os
import subprocess
import sys
import tempfile

import boto3

from timesketch_client import TimesketchClient, TimesketchError

log = logging.getLogger("worker")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

# Resolved on first use, never at import. See test_import_reaches_for_no_aws_configuration.
_CLIENTS = {}


class WorkerError(Exception):
    """The job failed. The artifact stays in the evidence bucket regardless."""


def _client(service):
    if service not in _CLIENTS:
        _CLIENTS[service] = boto3.client(service)
    return _CLIENTS[service]


def _config(name):
    try:
        return os.environ[name]
    except KeyError:
        raise WorkerError(
            f"{name} is not set. The worker is configured by modules/analysis; "
            "an unset value means the job definition was built elsewhere."
        ) from None


def plaso_key(case_id, sha256):
    """Case close operates across a prefix, so the prefix must be the case."""
    return f"{case_id}/{sha256}.plaso"


def timeline_name(evidence_key):
    """A responder reads this in the Timesketch UI, so it is the file's name."""
    return os.path.splitext(os.path.basename(evidence_key))[0]


def download(bucket, key, dest):
    body = _client("s3").get_object(Bucket=bucket, Key=key)["Body"]
    with open(dest, "wb") as handle:
        for chunk in iter(lambda: body.read(8 * 1024 * 1024), b""):
            handle.write(chunk)
    return dest


def upload(path, bucket, key):
    _client("s3").upload_file(path, bucket, key)
    return key


def run_log2timeline(source, destination):
    """log2timeline auto-detects across roughly 200 formats and runs every
    applicable parser itself. The pipeline does not second-guess it (spec 4.3)."""
    argv = [
        "log2timeline.py",
        "--status_view", "none",
        "--partitions", "all",
        "--volumes", "all",
        "--unattended",
        "--storage_file", destination,
        source,
    ]
    log.info("running %s", " ".join(argv))
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        raise WorkerError(
            f"log2timeline exit {result.returncode}: {result.stderr[-2000:]}"
        )
    return destination


def record_timeline(case_id, sha256, timeline_id, event_count):
    """Write the two fields this job owns.

    Status belongs to the state machine. If the worker wrote it too, a retried
    job and the machine's catch handler would race and the manifest would end up
    disagreeing with what actually happened.
    """
    _client("dynamodb").update_item(
        TableName=_config("ARTIFACTS_TABLE"),
        Key={"case_id": {"S": case_id}, "sha256": {"S": sha256}},
        UpdateExpression="SET timeline_id = :t, event_count = :c",
        ExpressionAttributeValues={
            ":t": {"N": str(timeline_id)},
            ":c": {"N": str(event_count)},
        },
    )


def _timesketch():
    secret = _client("secretsmanager").get_secret_value(
        SecretId=_config("TIMESKETCH_SECRET_ID")
    )["SecretString"]
    client = TimesketchClient(_config("TIMESKETCH_URL"), _config("TIMESKETCH_USER"), secret)
    client.login()
    return client


def cmd_timeline(args):
    scratch = _config("SCRATCH_DIR")
    with tempfile.TemporaryDirectory(dir=scratch) as workdir:
        source = download(
            _config("EVIDENCE_BUCKET"),
            args.evidence_key,
            os.path.join(workdir, os.path.basename(args.evidence_key)),
        )
        output = os.path.join(workdir, f"{args.sha256}.plaso")
        run_log2timeline(source, output)
        key = upload(output, _config("PLASO_BUCKET"), plaso_key(args.case_id, args.sha256))
    log.info("wrote %s", key)
    return 0


def cmd_import(args):
    bucket = _config("PLASO_BUCKET") if args.bucket_kind == "plaso" else _config("EVIDENCE_BUCKET")
    scratch = _config("SCRATCH_DIR")

    with tempfile.TemporaryDirectory(dir=scratch) as workdir:
        local = download(bucket, args.key, os.path.join(workdir, os.path.basename(args.key)))
        client = _timesketch()
        sketch_id = client.resolve_sketch(args.case_id)
        timeline_id = client.upload(local, sketch_id, timeline_name(args.key))
        count = client.event_count(sketch_id, timeline_id)

    record_timeline(args.case_id, args.sha256, timeline_id, count)
    log.info("sketch %s timeline %s: %s events", sketch_id, timeline_id, count)
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="worker")
    sub = parser.add_subparsers(dest="command", required=True)

    timeline = sub.add_parser("timeline", help="run log2timeline over an evidence object")
    timeline.add_argument("--case-id", required=True)
    timeline.add_argument("--sha256", required=True)
    timeline.add_argument("--evidence-key", required=True)
    timeline.set_defaults(func=cmd_timeline)

    importer = sub.add_parser("import", help="import a file into Timesketch")
    importer.add_argument("--case-id", required=True)
    importer.add_argument("--sha256", required=True)
    importer.add_argument("--key", required=True)
    importer.add_argument("--bucket-kind", required=True, choices=["evidence", "plaso"])
    importer.set_defaults(func=cmd_import)

    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (WorkerError, TimesketchError) as exc:
        log.error("%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd containers/plaso-worker && python -m pytest -v`

Expected: PASS, 15 tests (7 from Task 2, 8 here).

- [ ] **Step 5: Write the Dockerfile**

`containers/plaso-worker/Dockerfile`. The `FROM` is filled in by the build, never by hand:

```dockerfile
# syntax=docker/dockerfile:1
#
# The base is supplied as a build argument by modules/images/buildspec.yml, and
# it is always a DIGEST resolved seconds earlier in the same build. That is what
# makes the spec 4.5 parity invariant structural rather than a matter of
# discipline: the log2timeline.py in this image is the one the appliance's
# Timesketch reads .plaso files back with.
#
# Never replace this with a tag. Timesketch installs plaso-tools unpinned from
# ppa:gift, so two builds of one release tag can carry different plaso versions,
# and Timesketch rejects a .plaso produced by a newer plaso than it runs.
ARG TIMESKETCH_BASE
FROM ${TIMESKETCH_BASE}

COPY worker.py /usr/local/bin/worker.py
COPY timesketch_client.py /usr/local/bin/timesketch_client.py

ENV PYTHONPATH=/usr/local/bin
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python3", "/usr/local/bin/worker.py"]
```

- [ ] **Step 6: Commit**

```bash
git commit -- containers/plaso-worker -m "feat(worker): plaso worker entrypoint and image

Two subcommands, told what to do rather than deciding: timeline runs
log2timeline over an evidence object and writes .plaso; import pushes a file
into Timesketch and records timeline_id and event_count.

Routing stays in the claim Lambda so spec 4.3's rule has exactly one copy.
Status stays with the state machine so a retried job and the catch handler
cannot race.

The Dockerfile takes its base as a build argument that is always a digest
resolved in the same CodeBuild run, which makes spec 4.5's parity invariant
structural.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS"
```

---

### Task 4: Build and publish the worker image

CodeBuild's source is `NO_SOURCE` with an inline buildspec, so the Dockerfile and its two Python
modules cannot simply sit in a build context. Rendering them through `templatefile()` is worse
than it looks — `${...}` inside the Python would be eaten by OpenTofu's interpolation — so
OpenTofu uploads them to the tooling bucket and the build pulls them into a context. That is the
Phase 1 CodeBuild → S3 pattern, reused as `CLAUDE.md` nominates.

**Files:**
- Modify: `modules/images/variables.tf`
- Modify: `modules/images/codebuild.tf`
- Modify: `modules/images/iam.tf`
- Modify: `modules/images/buildspec.yml`
- Test: `modules/images/tests/mirror.tftest.hcl`

**Interfaces:**
- Consumes: `plaso_worker_repository_url` from Task 1, via `var.ecr_repository_urls["plaso-worker"]`.
- Produces: SSM parameter `/<name_prefix>/images/plaso-worker` holding `repo@sha256:...`. Task 5's
  job definition reads exactly this path.

- [ ] **Step 1: Check what the mirror role can already do**

Run: `grep -n 'ecr\|s3\|ssm' modules/images/iam.tf`

The role needs, in addition to what it has: `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`,
`ecr:CompleteLayerUpload`, `ecr:PutImage`, `ecr:BatchCheckLayerAvailability`,
`ecr:DescribeImages`, `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer` on the worker
repository (it pulls its own base from ECR), plus `s3:GetObject` on the tooling bucket. Add only
what is missing; the mirror already pushes to five repositories and writes to tooling.

- [ ] **Step 2: Write the failing tests**

Append to `modules/images/tests/mirror.tftest.hcl`:

```hcl
# The worker's base is a DIGEST resolved in the same build, not a tag.
#
# This asserts the SHAPE of the build, which is what is checkable offline: the
# buildspec passes a build argument rather than hardcoding a FROM. That the
# resulting image actually carries the same plaso as the appliance can only be
# confirmed by an acceptance run -- see docs/acceptance/phase-3.md check 3.
run "worker_image_takes_its_base_as_a_build_argument" {
  command = plan

  assert {
    condition     = strcontains(aws_codebuild_project.mirror.source[0].buildspec, "--build-arg TIMESKETCH_BASE=")
    error_message = "A hardcoded FROM would let the worker's plaso drift from the appliance's, which spec 4.5 exists to prevent."
  }

  assert {
    condition     = strcontains(aws_codebuild_project.mirror.source[0].buildspec, "/images/plaso-worker")
    error_message = "The analysis job definition reads the worker digest from this SSM path; the build must publish it."
  }
}

# Uploaded rather than heredoc'd into the buildspec: templatefile() would eat
# every ${...} in the Python.
run "worker_sources_are_staged_in_the_tooling_bucket" {
  command = plan

  assert {
    condition     = length(aws_s3_object.worker_source) == 3
    error_message = "The build context needs worker.py, timesketch_client.py and the Dockerfile."
  }
}
```

- [ ] **Step 3: Run them and watch them fail**

Run: `cd modules/images && tofu test`

Expected: FAIL — `aws_s3_object.worker_source has not been declared`, and the two `strcontains`
assertions false.

- [ ] **Step 4: Accept the new repository in the variable validation**

In `modules/images/variables.tf`, extend the `ecr_repository_urls` validation list and message:

```hcl
  validation {
    condition = alltrue([
      for k in ["timesketch", "opensearch", "postgres", "redis", "nginx", "plaso-worker"] :
      contains(keys(var.ecr_repository_urls), k)
    ])
    error_message = "ecr_repository_urls must contain timesketch, opensearch, postgres, redis, nginx, and plaso-worker."
  }
```

- [ ] **Step 5: Stage the build context and pass the new environment**

In `modules/images/codebuild.tf`, above `local.build_env`:

```hcl
# The worker's build context, staged in S3.
#
# CodeBuild here is NO_SOURCE with an inline buildspec, so there is no checkout
# to build from. Rendering these through templatefile() would be worse than it
# looks: every ${...} in the Python would be interpolated by OpenTofu. Uploading
# them keeps worker.py a real file with real pytest tests, and reuses the
# Phase 1 CodeBuild -> S3 path.
#
# The path reaches outside the module deliberately: spec 7 puts the container
# source at the repository root, and duplicating it under modules/ would give
# the parity invariant two places to drift.
locals {
  worker_source_prefix = "plaso-worker/src"

  worker_source_files = {
    "worker.py"             = "${path.module}/../../containers/plaso-worker/worker.py"
    "timesketch_client.py"  = "${path.module}/../../containers/plaso-worker/timesketch_client.py"
    "Dockerfile"            = "${path.module}/../../containers/plaso-worker/Dockerfile"
  }
}

resource "aws_s3_object" "worker_source" {
  for_each = local.worker_source_files

  bucket = var.tooling_bucket
  key    = "${local.worker_source_prefix}/${each.key}"
  source = each.value

  # Without this the object is uploaded once and never refreshed, so an edited
  # worker.py would build into an image that still carries the old one.
  etag = filemd5(each.value)

  kms_key_id = var.kms_key_arn
}
```

Then add three entries to `local.build_env`:

```hcl
    ECR_PLASO_WORKER     = var.ecr_repository_urls["plaso-worker"]
    WORKER_SOURCE_PREFIX = local.worker_source_prefix
```

- [ ] **Step 6: Add the build stage to the buildspec**

Append a third command block to `modules/images/buildspec.yml`, after the Docker Compose block:

```yaml
      - |
        set -euo pipefail

        # --- The plaso worker image (spec 4.5) ---
        #
        # Built, not mirrored. Its base is the digest resolved for timesketch a
        # few lines above, in THIS build, which is what makes the parity
        # invariant structural: the log2timeline.py in the worker is the binary
        # the appliance's Timesketch reads .plaso files back with.
        #
        # Tagged by the BASE digest rather than by TIMESKETCH_VERSION. The
        # mirror's idempotency rule is "tag exists, skip", and a version-tagged
        # worker would let that rule hide a stale base -- the same mechanism
        # that left postgres:13.0-alpine in the development account after the
        # pin moved. A new base is always a new tag, so the skip is honest.

        ts_ref=$(aws ssm get-parameter --name "/$NAME_PREFIX/images/timesketch" \
          --query 'Parameter.Value' --output text)
        base_digest="${ts_ref##*@}"
        short="${base_digest#sha256:}"
        worker_tag="ts-${short:0:12}"
        worker_repo_name="${ECR_PLASO_WORKER#*/}"

        echo "== worker base is $ts_ref -> tag $worker_tag"

        existing=$(aws ecr describe-images \
          --repository-name "$worker_repo_name" \
          --image-ids imageTag="$worker_tag" \
          --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || true)

        if [ -n "$existing" ] && [ "$existing" != "None" ]; then
          echo "== worker already built against this base, skipping"
          worker_digest="$existing"
        else
          rm -rf /tmp/worker-context
          mkdir -p /tmp/worker-context
          aws s3 cp --recursive "s3://$TOOLING_BUCKET/$WORKER_SOURCE_PREFIX/" /tmp/worker-context/

          docker build \
            --build-arg TIMESKETCH_BASE="$ts_ref" \
            -t "$ECR_PLASO_WORKER:$worker_tag" \
            /tmp/worker-context

          docker push "$ECR_PLASO_WORKER:$worker_tag"

          worker_digest=$(aws ecr describe-images \
            --repository-name "$worker_repo_name" \
            --image-ids imageTag="$worker_tag" \
            --query 'imageDetails[0].imageDigest' --output text)
        fi

        if [ -z "$worker_digest" ] || [ "$worker_digest" = "None" ]; then
          echo "FATAL: could not resolve a digest for $worker_repo_name:$worker_tag" >&2
          exit 1
        fi

        aws ssm put-parameter \
          --name "/$NAME_PREFIX/images/plaso-worker" \
          --type String --overwrite \
          --value "$ECR_PLASO_WORKER@$worker_digest"

        echo "   plaso-worker -> $ECR_PLASO_WORKER@$worker_digest"
```

- [ ] **Step 7: Run the tests and watch them pass**

Run: `cd modules/images && tofu test`

Expected: PASS. The images count rises from 7 to 10.

- [ ] **Step 8: Run the repo check and commit**

Run: `bash scripts/check.sh check`

```bash
git commit -- modules/images containers/plaso-worker -m "feat(images): build and publish the plaso worker image

FROM the timesketch digest resolved in the same build, tagged by that base
digest rather than by release version -- so the mirror's 'tag exists, skip'
rule can never hide a stale base the way it did for postgres:13.0-alpine.

The build context is staged in the tooling bucket because CodeBuild here is
NO_SOURCE, and because templatefile() would interpolate every \${...} in the
Python.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS"
```

---

### Task 5: The Batch fleet

D14 stands — Batch on EC2 on-demand — but on re-argued grounds (amendment A9). plaso is disk-bound
and D8 targets 100 GB to 1 TB per incident, so scratch is instance-store NVMe, which is why the
instance families are `i4i`/`c6id` rather than anything Fargate can offer. The isolation Fargate
would give structurally is bought here with a job sized to the whole instance and an IMDS hop limit
of 1.

**Files:**
- Create: `modules/analysis/batch.tf`
- Create: `modules/analysis/templates/scratch.sh.tftpl`
- Create: `modules/analysis/tests/pipeline.tftest.hcl`
- Modify: `modules/analysis/variables.tf`, `modules/analysis/endpoints.tf`,
  `modules/analysis/appliance.tf`, `modules/analysis/tests/posture.tftest.hcl`

**Interfaces:**
- Consumes: platform outputs from Task 1; SSM parameter `/<prefix>/images/plaso-worker` from Task 4.
- Produces: `aws_batch_job_queue.worker` (arn), `aws_batch_job_definition.worker` (arn),
  `aws_security_group.worker` (id), `aws_iam_role.worker`. Task 6's state machine submits to
  exactly these.

**Deferred here, deliberately, with a success condition:** the worker does **not** apply a legal
hold to the `.plaso` files it writes, and holds no `s3:PutObjectLegalHold` anywhere. A `.plaso` is
reproducible from the evidence object, which *is* under hold; holding derived artifacts adds a
teardown step for no integrity gain and pre-empts Phase 4, where retention and holds are set
coherently at case close (§5.4). The plaso bucket keeps Object Lock enabled so Phase 4 can. *Success
condition:* Phase 4's `case close` sets retention on the `.plaso` prefix at the same time as the
evidence prefix, or a written argument records why it should not.

- [ ] **Step 1: Add the variables**

Append to `modules/analysis/variables.tf`:

```hcl
# --- Phase 3: the ingest pipeline ---

variable "evidence_bucket" {
  type        = string
  description = "Evidence bucket name, from the platform layer."
}

variable "evidence_bucket_arn" {
  type        = string
  description = "Evidence bucket ARN, from the platform layer."
}

variable "plaso_bucket" {
  type        = string
  description = "Destination bucket for .plaso files, from the platform layer."
}

variable "plaso_bucket_arn" {
  type        = string
  description = "Plaso bucket ARN, from the platform layer."
}

variable "artifacts_table" {
  type        = string
  description = "Artifact manifest table name, from the platform layer."
}

variable "artifacts_table_arn" {
  type        = string
  description = "Artifact manifest table ARN, from the platform layer."
}

# Instance families carrying NVMe instance storage.
#
# This is the whole of amendment A9's argument made concrete: plaso is
# disk-bound and D8 targets 100 GB to 1 TB per incident, so scratch is local
# NVMe rather than a network volume attached per task. An instance type without
# instance storage still works -- templates/scratch.sh.tftpl falls back to the
# root volume -- but slowly, and the fallback is a safety net, not a plan.
variable "worker_instance_types" {
  type        = list(string)
  description = "Batch compute environment instance types. Must carry NVMe instance storage."
  default     = ["i4i.2xlarge", "c6id.4xlarge"]
}

# Sized to consume a whole instance, which is how Batch on EC2 approximates the
# per-task isolation Fargate gives structurally. A fleet processing live malware
# should not co-schedule two cases on one kernel.
variable "worker_job_vcpus" {
  type        = number
  description = "vCPUs per job. Set to a whole instance's count to keep one job per host."
  default     = 8
}

variable "worker_job_memory_mib" {
  type        = number
  description = "Memory per job, MiB. Leave headroom below the instance total for the ECS agent."
  default     = 58000
}

variable "worker_max_vcpus" {
  type        = number
  description = "Ceiling on the compute environment. Bounds spend during a large incident."
  default     = 64
}

variable "worker_root_volume_gb" {
  type        = number
  description = "Root volume for worker instances. Scratch is instance store; this is just the OS and image layers."
  default     = 100
}
```

- [ ] **Step 2: Write the scratch user-data template**

`modules/analysis/templates/scratch.sh.tftpl`:

```bash
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==IRBOUNDARY=="

--==IRBOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
# Managed by OpenTofu.
#
# MIME multipart is not optional. AWS Batch APPENDS its own user data -- the
# ECS_CLUSTER configuration that joins the instance to the compute environment --
# to whatever a launch template supplies. A plain shell script here silently
# replaces it instead of being merged, and the instances come up, never join the
# cluster, and jobs sit in RUNNABLE forever with no error anywhere.
set -euxo pipefail

# plaso is disk-bound (amendment A9). Instance-store NVMe is the point of
# choosing these instance families; a worker that quietly used the root EBS
# volume would be correct and slow, which is the worst failure mode to debug
# mid-incident. Mount it loudly.
SCRATCH=/scratch
mkdir -p "$SCRATCH"

# Instance-store devices report a distinct model string. EBS volumes on the same
# instance are also NVMe, so filtering on /dev/nvme* alone would pick up the root
# volume and destroy it.
mapfile -t EPHEMERAL < <(lsblk -d -n -o NAME,MODEL \
  | awk '$0 ~ /Instance Storage/ { print "/dev/" $1 }')

if [ "$${#EPHEMERAL[@]}" -eq 0 ]; then
  echo "WARNING: no instance store on this instance type; scratch falls back to the root volume" >&2
elif [ "$${#EPHEMERAL[@]}" -eq 1 ]; then
  mkfs.xfs -f "$${EPHEMERAL[0]}"
  mount "$${EPHEMERAL[0]}" "$SCRATCH"
else
  mdadm --create /dev/md0 --level=0 --raid-devices="$${#EPHEMERAL[@]}" "$${EPHEMERAL[@]}"
  mkfs.xfs -f /dev/md0
  mount /dev/md0 "$SCRATCH"
fi

chmod 1777 "$SCRATCH"
df -h "$SCRATCH"

--==IRBOUNDARY==--
```

Note the doubled `$$` on every shell variable expansion: `templatefile()` would otherwise treat
`${#EPHEMERAL[@]}` as an OpenTofu interpolation and fail at plan time with an error that names the
template, not the line.

- [ ] **Step 3: Write the failing tests**

`modules/analysis/tests/pipeline.tftest.hcl`. Copy the mock preamble and the `variables` block
verbatim from `modules/analysis/tests/posture.tftest.hcl` — `mock_provider` has no `source`
argument in OpenTofu 1.12, so the block genuinely has to be duplicated. Add the new variables to
it, then:

```hcl
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
# instance of a type, so all four buckets share one invented ARN and any
# assertion of the form "this policy does not mention the evidence bucket"
# passes vacuously.
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

# Spec 4.5. The parameter is a repo@sha256 reference; a tag here would let the
# worker's plaso drift from the appliance's.
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
# arrives over the ECS task credential endpoint instead.
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
```

- [ ] **Step 4: Run them and watch them fail**

Run: `cd modules/analysis && tofu test -filter='tests\pipeline.tftest.hcl'`

Expected: FAIL — the Batch resources are not declared. Confirm the run count is 6, not 0.

- [ ] **Step 5: Add the three interface endpoints**

In `modules/analysis/endpoints.tf`, extend `interface_endpoint_services`:

```hcl
  interface_endpoint_services = var.posture == "active" ? toset([
    "ssm",
    "ssmmessages",
    "ec2messages",
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
    "kms",
    # Batch on EC2 is ECS underneath. Without these the instances launch, the
    # agent cannot register, and every job sits in RUNNABLE indefinitely with
    # nothing in any log that names the cause.
    "ecs",
    "ecs-agent",
    "ecs-telemetry",
  ]) : toset([])
```

Update the two counts in `modules/analysis/tests/posture.tftest.hcl` from `8` to `11`, and their
error messages with them.

- [ ] **Step 6: Read the worker digest**

In `modules/analysis/appliance.tf`, extend the SSM lookup:

```hcl
data "aws_ssm_parameter" "image" {
  for_each = toset(["timesketch", "opensearch", "postgres", "redis", "plaso-worker"])
  name     = "${var.image_digest_parameter_prefix}/${each.key}"
}
```

The mirror must have run before the analysis layer applies — that is already true for the other
four, and the failure mode is the same: a `ParameterNotFound` naming the path.

- [ ] **Step 7: Write `modules/analysis/batch.tf`**

```hcl
# The plaso fleet (D14, re-argued as amendment A9; spec 4.6).
#
# Batch on EC2 on-demand. The original D14 reasoning leaned partly on Fargate's
# 200 GiB ephemeral cap, which no longer holds -- Fargate can attach EBS at task
# launch. The live argument is I/O: plaso is disk-bound, D8 targets 100 GB to
# 1 TB per incident, and instance-store NVMe is both faster than a per-task
# network volume and included in the instance price.
#
# What EC2 costs us is Fargate's per-task microVM isolation, which matters for a
# fleet that processes live malware. It is bought back two ways: a job sized to
# a whole instance, so two cases never share a kernel, and an IMDS hop limit of
# 1, so a container cannot reach the instance role.
#
# At zero desired vCPUs this fleet costs nothing, which is why dormancy only has
# to DISABLE it rather than destroy it.

resource "aws_security_group" "worker" {
  name        = "${var.name_prefix}-worker"
  description = "plaso workers. Egress to VPC endpoints and the appliance only."
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-worker" })
}

# There is no internet route in this VPC (spec 3.3), so "all egress" reaches
# VPC endpoints, the appliance, and nothing else.
resource "aws_vpc_security_group_egress_rule" "worker_all" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "VPC endpoints and the appliance; this VPC has no internet route"
}

# --- Roles ---

resource "aws_iam_role" "batch_service" {
  name = "${var.name_prefix}-batch-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "batch.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  role       = aws_iam_role.batch_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

resource "aws_iam_role" "batch_instance" {
  name = "${var.name_prefix}-batch-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

# The HOST's role: join the cluster and pull images. Deliberately holds nothing
# about evidence -- that lives on the job role, which the container gets over
# the task credential endpoint.
resource "aws_iam_role_policy_attachment" "batch_instance" {
  role       = aws_iam_role.batch_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "batch_instance" {
  name = "${var.name_prefix}-batch-instance"
  role = aws_iam_role.batch_instance.name
  tags = local.common_tags
}

resource "aws_iam_role" "worker" {
  name = "${var.name_prefix}-plaso-worker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

# The second reader of the evidence store (amendment A12).
#
# The recorder's asymmetry -- read on intake, write-and-lock on evidence, never
# read on evidence -- is a property of the RECORDER, not of the bucket. Nothing
# enforces anything for a second reader but this policy, so it is written to be
# read: the worker reads evidence, writes .plaso, and updates two manifest
# fields. It holds no delete of any kind and no legal hold.
#
# s3:DeleteObject in particular would be worse than it looks: on a versioned
# bucket it writes a delete marker rather than failing, and S3 permits that over
# a legal hold (amendment A8). The bucket policy denies it, and this role does
# not ask for it -- two independent reasons, which is the right number for
# something that hides evidence without destroying it.
resource "aws_iam_role_policy" "worker" {
  name = "${var.name_prefix}-plaso-worker"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadEvidence"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.evidence_bucket_arn}/*"
      },
      {
        Sid      = "WriteAndReadPlaso"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = "${var.plaso_bucket_arn}/*"
      },
      {
        # Only timeline_id and event_count. Status belongs to the state machine.
        Sid      = "RecordTimeline"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = var.artifacts_table_arn
      },
      {
        Sid      = "ReadPipelineCredential"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.pipeline.arn
      },
      {
        Sid      = "KmsUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

# --- Fleet ---

resource "aws_launch_template" "worker" {
  name        = "${var.name_prefix}-worker"
  description = "plaso workers: instance-store scratch, IMDS closed to containers"

  user_data = base64encode(templatefile("${path.module}/templates/scratch.sh.tftpl", {}))

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.worker_root_volume_gb
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = var.kms_key_arn
    }
  }

  metadata_options {
    http_tokens = "required"

    # One hop reaches the host and stops there. A container is two hops away, so
    # it cannot read the instance role; the job role arrives over the ECS task
    # credential endpoint instead. This is the compensating control for choosing
    # EC2 over Fargate for a fleet that handles live malware (amendment A9).
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.name_prefix}-worker" })
  }
}

resource "aws_batch_compute_environment" "worker" {
  name = "${var.name_prefix}-plaso"
  type = "MANAGED"

  # Dormancy is a variable, never a destroy (spec 3.2). DISABLED holds the
  # fleet at zero without losing the queue, the job definition, or anything a
  # queued job refers to.
  state = var.posture == "active" ? "ENABLED" : "DISABLED"

  service_role = aws_iam_role.batch_service.arn

  compute_resources {
    type = "EC2"

    # On-demand, not Spot (D14). Incidents are infrequent, and a reclaim partway
    # through a multi-hour disk image costs more in incident time than the
    # discount saves.
    allocation_strategy = "BEST_FIT_PROGRESSIVE"

    min_vcpus     = 0
    desired_vcpus = 0
    max_vcpus     = var.worker_max_vcpus

    instance_type       = var.worker_instance_types
    instance_role       = aws_iam_instance_profile.batch_instance.arn
    security_group_ids  = [aws_security_group.worker.id]

    # Pinned to the appliance's subnet while the interface endpoints are
    # single-AZ. Spanning AZs here would strand workers in an AZ with no
    # endpoint ENI; see endpoints.tf.
    subnets = [var.private_subnet_ids[0]]

    launch_template {
      launch_template_id = aws_launch_template.worker.id
      version            = "$Latest"
    }

    tags = local.common_tags
  }

  depends_on = [aws_iam_role_policy_attachment.batch_service]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_job_queue" "worker" {
  name     = "${var.name_prefix}-plaso"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.worker.arn
  }

  # The QUEUE stays enabled while dormant on purpose. A job submitted against a
  # disabled compute environment waits; a job submitted against a disabled queue
  # is rejected outright. Waiting is the behaviour spec 5.5 wants -- the artifact
  # is already recorded, immutable and held, and only its timeline is deferred.
}

resource "aws_batch_job_definition" "worker" {
  name                  = "${var.name_prefix}-plaso-worker"
  type                  = "container"
  platform_capabilities = ["EC2"]

  # A failed job leaves the artifact in evidence regardless (spec 4.7). One
  # retry covers a lost Spot-like interruption or an ECS agent hiccup; beyond
  # that a failure is real and the state machine records it.
  retry_strategy {
    attempts = 2
  }

  timeout {
    # plaso over a 1 TB disk image is measured in hours, not minutes. This is a
    # ceiling against a runaway parser, not a target.
    attempt_duration_seconds = 43200
  }

  container_properties = jsonencode({
    image      = data.aws_ssm_parameter.image["plaso-worker"].value
    vcpus      = var.worker_job_vcpus
    memory     = var.worker_job_memory_mib
    jobRoleArn = aws_iam_role.worker.arn

    volumes = [{
      name = "scratch"
      host = { sourcePath = "/scratch" }
    }]

    mountPoints = [{
      sourceVolume  = "scratch"
      containerPath = "/scratch"
      readOnly      = false
    }]

    environment = [
      { name = "EVIDENCE_BUCKET", value = var.evidence_bucket },
      { name = "PLASO_BUCKET", value = var.plaso_bucket },
      { name = "ARTIFACTS_TABLE", value = var.artifacts_table },
      { name = "SCRATCH_DIR", value = "/scratch" },
      { name = "TIMESKETCH_URL", value = "http://timesketch.${var.private_zone_name}:5000" },
      { name = "TIMESKETCH_USER", value = local.pipeline_user },
      { name = "TIMESKETCH_SECRET_ID", value = aws_secretsmanager_secret.pipeline.name },
      { name = "AWS_DEFAULT_REGION", value = data.aws_region.current.region },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.worker.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "plaso"
      }
    }
  })
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/batch/${var.name_prefix}-plaso-worker"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = local.common_tags
}
```

**If `aws_cloudwatch_log_group.worker` fails at apply with `CreateLogGroup:
AccessDeniedException`,** the CMK policy is missing `AllowCloudWatchLogsEncrypt` for this region's
logs service principal — the same failure the intake recorder hit as Phase 2 defect 1. The error
names the log group ARN, never the key. Check `modules/platform/kms.tf`; the statement should
already be there from Phase 2 and should already cover this.

- [ ] **Step 8: Run the tests**

Run: `cd modules/analysis && tofu test`

Expected: the new file's six runs pass and the two posture counts now assert 11. `aws_batch_*`
resources are unusual under `mock_provider` — if a plan-time type error appears on
`compute_environment_order` or `container_properties`, re-read the "sets, not lists" note in
`CLAUDE.md` before changing the module.

`aws_secretsmanager_secret.pipeline` and `local.pipeline_user` do not exist yet; Task 7 adds them.
Until then this task's tests will fail on those two references — add the secret and the local as
part of this step, taking the code from Task 7 Step 2, and leave the cloud-init and compose changes
for Task 7.

- [ ] **Step 9: Run the repo check and commit**

Run: `bash scripts/check.sh check`

```bash
git commit -- modules/analysis -m "feat(analysis): plaso Batch fleet

D14 stands but on re-argued grounds: plaso is disk-bound and D8 targets 100 GB
to 1 TB per incident, so scratch is instance-store NVMe rather than a per-task
network volume. Fargate's per-task isolation is bought back with a job sized to
a whole instance and an IMDS hop limit of 1.

The job role is the second reader of the evidence store and the first that
legitimately reads it. It holds no delete of any kind and no legal hold: the
recorder's asymmetry is a property of the recorder, not of the bucket.

The compute environment is DISABLED when dormant; the queue is not, so a job
submitted while asleep waits rather than being rejected.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS"
```

---

### Task 6: Claim, routing, and the reconciler

Two handlers in one module, deployed as two functions from one zip. They share the routing rule
and the manifest vocabulary, and splitting them into two packages would give that shared knowledge
two places to drift.

**Files:**
- Create: `modules/analysis/lambda/pipeline/handler.py`
- Create: `modules/analysis/lambda/pipeline/test_handler.py`

**Interfaces:**
- Consumes: `artifacts_table`, `cases_table` names from variables.
- Produces: `route(evidence_key) -> "direct" | "plaso"`; `claim_handler(event, context)` returning
  `{"claimed": bool, "route": str, "case_id": str, "sha256": str, "evidence_key": str,
  "plaso_key": str}`; `sweep_handler(event, context)` returning `{"started": int}`. Task 8's state
  machine reads exactly these field names in its Choice state.

- [ ] **Step 1: Write the failing tests**

`modules/analysis/lambda/pipeline/test_handler.py`:

```python
"""botocore.Stubber, never live calls. No dummy credentials -- Stubber
intercepts at before-call, ahead of signing, so nothing authenticates and a
hardcoded key would only trip Snyk Code's HardcodedNonCryptoSecret rule."""

import boto3
import pytest
from botocore.exceptions import ClientError
from botocore.stub import Stubber

import handler


def test_import_reaches_for_no_aws_configuration():
    assert handler._CLIENTS == {}


@pytest.mark.parametrize(
    "key,expected",
    [
        ("CASE-1/export.csv", "direct"),
        ("CASE-1/events.jsonl", "direct"),
        ("CASE-1/cloudtrail.json", "direct"),
        ("CASE-1/EXPORT.CSV", "direct"),
        ("CASE-1/triage.zip", "plaso"),
        ("CASE-1/disk.E01", "plaso"),
        ("CASE-1/System.evtx", "plaso"),
        ("CASE-1/nested/dir/$MFT", "plaso"),
    ],
)
def test_routing_is_a_rule_not_a_classifier(key, expected):
    """Spec 4.3. plaso has no generic CSV or JSON parser -- dsv_parser.py is an
    abstract base class whose COLUMNS list each concrete parser must define, and
    a _MAGIC_TEST_STRING sniff test rejects non-conforming files. So arbitrary
    tabular data takes the direct-import route and everything else goes to
    log2timeline, which auto-detects across roughly 200 formats."""
    assert handler.route(key) == expected


def test_case_id_is_the_first_path_segment():
    assert handler.case_id_from_key("CASE-2026-014/triage.zip") == "CASE-2026-014"


def test_case_id_of_a_key_with_no_prefix_is_rejected():
    """Every evidence key is written by the recorder as <case_id>/<name>. A key
    without a prefix did not come from the recorder."""
    with pytest.raises(handler.PipelineError, match="prefix"):
        handler.case_id_from_key("loose-file.zip")


def test_claim_moves_a_recorded_row_to_timelining(monkeypatch):
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_response(
        "update_item",
        {},
        {
            "TableName": "ir-artifacts",
            "Key": {"case_id": {"S": "CASE-1"}, "sha256": {"S": "abc"}},
            "UpdateExpression": "SET #s = :timelining, claimed_at = :now",
            "ConditionExpression": "#s = :recorded OR (#s = :timelining AND claimed_at < :stale)",
            "ExpressionAttributeNames": {"#s": "status"},
            "ExpressionAttributeValues": {
                ":timelining": {"S": "timelining"},
                ":recorded": {"S": "recorded"},
                ":now": {"S": handler._now()},
                ":stale": {"S": handler._stale_before()},
            },
        },
    )
    stub.activate()
    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")
    monkeypatch.setattr(handler, "_now", lambda: "2026-09-16T00:00:00+00:00")
    monkeypatch.setattr(handler, "_stale_before", lambda: "2026-09-15T12:00:00+00:00")

    result = handler.claim_handler(
        {"case_id": "CASE-1", "sha256": "abc", "evidence_key": "CASE-1/triage.zip"}, None
    )

    stub.assert_no_pending_responses()
    assert result["claimed"] is True
    assert result["route"] == "plaso"
    assert result["plaso_key"] == "CASE-1/abc.plaso"


def test_a_lost_claim_is_not_an_error(monkeypatch):
    """Deduplication is the conditional write failing, not a check before it.

    Both trigger paths -- the EventBridge rule and the reconciler sweep -- can
    fire for the same artifact. A read-then-write check would let both through;
    only one can win a conditional write. The loser returns claimed=False and
    the state machine succeeds without doing anything.
    """
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_client_error("update_item", service_error_code="ConditionalCheckFailedException")
    stub.activate()
    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    result = handler.claim_handler(
        {"case_id": "CASE-1", "sha256": "abc", "evidence_key": "CASE-1/triage.zip"}, None
    )

    assert result["claimed"] is False


def test_a_claim_error_that_is_not_a_lost_race_propagates(monkeypatch):
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_client_error("update_item", service_error_code="ProvisionedThroughputExceededException")
    stub.activate()
    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    with pytest.raises(ClientError):
        handler.claim_handler(
            {"case_id": "CASE-1", "sha256": "abc", "evidence_key": "CASE-1/triage.zip"}, None
        )


def test_claim_resolves_a_missing_digest_from_the_manifest(monkeypatch):
    """The EventBridge path carries a bucket and a key, never a digest.

    Resolving it by querying the manifest keeps this function's AWS surface to
    DynamoDB alone. Reading the object's metadata instead would mean giving the
    claim step s3:GetObject on the evidence bucket, which is precisely the grant
    amendment A12 exists to keep rare.
    """
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_response(
        "query",
        {"Items": [{"case_id": {"S": "CASE-1"}, "sha256": {"S": "abc"}}]},
        {
            "TableName": "ir-artifacts",
            "KeyConditionExpression": "case_id = :c",
            "FilterExpression": "evidence_key = :k",
            "ExpressionAttributeValues": {
                ":c": {"S": "CASE-1"},
                ":k": {"S": "CASE-1/triage.zip"},
            },
            "ConsistentRead": True,
        },
    )
    stub.activate()
    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    assert handler.resolve_sha256("CASE-1", "CASE-1/triage.zip") == "abc"
    stub.assert_no_pending_responses()


def test_an_unrecorded_object_is_not_timelined(monkeypatch):
    """An object in the evidence bucket with no manifest row did not come
    through the recorder. Timelining it would put an artifact with no chain of
    custody into a sketch."""
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_response("query", {"Items": []}, {
        "TableName": "ir-artifacts",
        "KeyConditionExpression": "case_id = :c",
        "FilterExpression": "evidence_key = :k",
        "ExpressionAttributeValues": {":c": {"S": "CASE-1"}, ":k": {"S": "CASE-1/x.zip"}},
        "ConsistentRead": True,
    })
    stub.activate()
    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    with pytest.raises(handler.PipelineError, match="no manifest row"):
        handler.resolve_sha256("CASE-1", "CASE-1/x.zip")


def test_sweep_starts_one_execution_per_untimelined_row(monkeypatch):
    """This is the path that timelines the backlog dormancy leaves behind.

    Nothing else does: an artifact recorded while the environment was asleep
    generated its S3 event at a moment when the EventBridge rule was DISABLED,
    and that event is gone. The sweep is the correctness path and the rule is a
    latency optimisation on top of it.
    """
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb_stub = Stubber(ddb)
    ddb_stub.add_response(
        "scan",
        {
            "Items": [
                {
                    "case_id": {"S": "CASE-1"},
                    "sha256": {"S": "abc"},
                    "evidence_key": {"S": "CASE-1/triage.zip"},
                }
            ]
        },
        {
            "TableName": "ir-artifacts",
            "FilterExpression": "#s = :recorded AND attribute_not_exists(timeline_id)",
            "ExpressionAttributeNames": {"#s": "status"},
            "ExpressionAttributeValues": {":recorded": {"S": "recorded"}},
        },
    )
    ddb_stub.activate()

    sfn = boto3.client("stepfunctions", region_name="us-east-1")
    sfn_stub = Stubber(sfn)
    sfn_stub.add_response(
        "start_execution",
        {"executionArn": "arn:aws:states:us-east-1:111122223333:execution:p:1", "startDate": 0},
        {
            "stateMachineArn": "arn:aws:states:us-east-1:111122223333:stateMachine:p",
            "input": '{"case_id": "CASE-1", "sha256": "abc", "evidence_key": "CASE-1/triage.zip"}',
        },
    )
    sfn_stub.activate()

    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setitem(handler._CLIENTS, "stepfunctions", sfn)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")
    monkeypatch.setenv("STATE_MACHINE_ARN", "arn:aws:states:us-east-1:111122223333:stateMachine:p")

    assert handler.sweep_handler({}, None) == {"started": 1}
    ddb_stub.assert_no_pending_responses()
    sfn_stub.assert_no_pending_responses()
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd modules/analysis/lambda/pipeline && python -m pytest -v`

Expected: FAIL at collection — `ModuleNotFoundError: No module named 'handler'`.

- [ ] **Step 3: Write the handler**

`modules/analysis/lambda/pipeline/handler.py`:

```python
"""Pipeline claim and reconciliation (spec 4.1, 4.3).

Two entry points, one module, one zip. They share the routing rule and the
manifest vocabulary; separating them would give that shared knowledge two places
to drift.

claim_handler is the first state of the machine. Both triggers -- the
EventBridge rule on the evidence bucket and the scheduled sweep -- run it, and
it is where double-processing is prevented: by a conditional write failing, not
by a check before one. Two concurrent invocations would both pass a
read-then-write check; only one can win a conditional write. That is the same
argument the intake recorder's _claim makes, and deliberately the same shape.

sweep_handler is the correctness path. An artifact recorded while the
environment was dormant produced its S3 event while the EventBridge rule was
DISABLED, and that event is gone forever. Nothing but this sweep would ever
timeline it. The rule is a latency optimisation layered on top.

Neither function touches S3. The digest a claim needs is resolved from the
manifest rather than from object metadata, which keeps s3:GetObject on the
evidence bucket confined to the Batch worker (amendment A12).
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

# Resolved on first use, never at import: a client at module scope needs a
# resolvable region, so the module would import on a developer machine and fail
# on every CI runner with NoRegionError raised during collection.
_CLIENTS = {}

# Spec 4.3. plaso has no generic CSV or JSON parser -- dsv_parser.py is an
# abstract base class whose COLUMNS list each concrete parser defines, and a
# _MAGIC_TEST_STRING sniff test rejects non-conforming files. Arbitrary tabular
# data therefore takes the direct-import route.
DIRECT_IMPORT_SUFFIXES = (".csv", ".jsonl", ".json")

# Matches the job definition's attempt_duration_seconds. A row still marked
# timelining after this long belongs to an execution that cannot still be
# running, so the sweep may re-claim it.
STALE_CLAIM_HOURS = 12


class PipelineError(Exception):
    """The artifact is not timelined. It stays in evidence, recorded and held."""


def _client(service):
    if service not in _CLIENTS:
        _CLIENTS[service] = boto3.client(service)
    return _CLIENTS[service]


def _config(name):
    try:
        return os.environ[name]
    except KeyError:
        raise PipelineError(
            f"{name} is not set. This function is configured by modules/analysis; "
            "an unset value means it was deployed outside it."
        ) from None


def _now():
    return datetime.now(timezone.utc).isoformat()


def _stale_before():
    return (datetime.now(timezone.utc) - timedelta(hours=STALE_CLAIM_HOURS)).isoformat()


def route(evidence_key):
    """A rule, not a classifier (spec 4.3).

    log2timeline auto-detects across roughly 200 formats and runs every
    applicable parser itself; the pipeline does not second-guess it.
    """
    return "direct" if evidence_key.lower().endswith(DIRECT_IMPORT_SUFFIXES) else "plaso"


def case_id_from_key(evidence_key):
    """The recorder writes every evidence key as <case_id>/<name>, because case
    close operates across a prefix."""
    head, sep, _ = evidence_key.partition("/")
    if not sep or not head:
        raise PipelineError(
            f"{evidence_key} has no case prefix, so it was not written by the "
            "intake recorder. It is not timelined."
        )
    return head


def plaso_key(case_id, sha256):
    return f"{case_id}/{sha256}.plaso"


def resolve_sha256(case_id, evidence_key):
    """Find the digest from the manifest rather than from object metadata.

    HeadObject would need s3:GetObject on the evidence bucket -- IAM has no
    s3:HeadObject action -- and that grant is one amendment A12 exists to keep
    confined to the worker.
    """
    result = _client("dynamodb").query(
        TableName=_config("ARTIFACTS_TABLE"),
        KeyConditionExpression="case_id = :c",
        FilterExpression="evidence_key = :k",
        ExpressionAttributeValues={":c": {"S": case_id}, ":k": {"S": evidence_key}},
        ConsistentRead=True,
    )
    items = result.get("Items", [])
    if not items:
        raise PipelineError(
            f"{evidence_key} has no manifest row. An object in the evidence "
            "bucket that the recorder never recorded has no chain of custody, "
            "and is not put into a sketch."
        )
    return items[0]["sha256"]["S"]


def claim_handler(event, context):
    """Claim the artifact, or report that someone else already has."""
    evidence_key = event["evidence_key"]
    case_id = event.get("case_id") or case_id_from_key(evidence_key)
    sha256 = event.get("sha256") or resolve_sha256(case_id, evidence_key)

    payload = {
        "claimed": False,
        "case_id": case_id,
        "sha256": sha256,
        "evidence_key": evidence_key,
        "route": route(evidence_key),
        "plaso_key": plaso_key(case_id, sha256),
    }

    try:
        _client("dynamodb").update_item(
            TableName=_config("ARTIFACTS_TABLE"),
            Key={"case_id": {"S": case_id}, "sha256": {"S": sha256}},
            UpdateExpression="SET #s = :timelining, claimed_at = :now",
            ConditionExpression=(
                "#s = :recorded OR (#s = :timelining AND claimed_at < :stale)"
            ),
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":timelining": {"S": "timelining"},
                ":recorded": {"S": "recorded"},
                ":now": {"S": _now()},
                ":stale": {"S": _stale_before()},
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        log.info("%s is already claimed or not ready; nothing to do", evidence_key)
        return payload

    payload["claimed"] = True
    log.info("claimed %s for %s via the %s route", sha256, case_id, payload["route"])
    return payload


def sweep_handler(event, context):
    """Start an execution for every recorded artifact with no timeline.

    A Scan with a filter, not a GSI. The manifest holds one row per artifact per
    case -- tens to low thousands -- and a GSI on status would be an index
    nobody asked for, billed forever, to save a scan that runs four times an
    hour while the environment is awake. If a deployment's manifest passes
    roughly 100k rows, revisit that.
    """
    table = _config("ARTIFACTS_TABLE")
    machine = _config("STATE_MACHINE_ARN")
    started = 0

    paginator_kwargs = {
        "TableName": table,
        "FilterExpression": "#s = :recorded AND attribute_not_exists(timeline_id)",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":recorded": {"S": "recorded"}},
    }

    while True:
        page = _client("dynamodb").scan(**paginator_kwargs)

        for item in page.get("Items", []):
            _client("stepfunctions").start_execution(
                stateMachineArn=machine,
                input=json.dumps(
                    {
                        "case_id": item["case_id"]["S"],
                        "sha256": item["sha256"]["S"],
                        "evidence_key": item["evidence_key"]["S"],
                    }
                ),
            )
            started += 1

        last = page.get("LastEvaluatedKey")
        if not last:
            break
        paginator_kwargs["ExclusiveStartKey"] = last

    if started:
        log.info("swept %s artifact(s) into the pipeline", started)
    return {"started": started}
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd modules/analysis/lambda/pipeline && python -m pytest -v`

Expected: PASS, 16 tests (8 of them the routing parametrisation).

- [ ] **Step 5: Commit**

```bash
git commit -- modules/analysis/lambda -m "feat(analysis): pipeline claim and reconciliation

Deduplication is a conditional write failing, not a check before one -- the same
shape as the intake recorder's _claim, and for the same reason: two triggers can
fire for one artifact and a read-then-write check would let both through.

The sweep is the correctness path. An artifact recorded while dormant produced
its S3 event while the EventBridge rule was DISABLED and that event is gone;
nothing else would ever timeline it.

Neither handler touches S3. The digest is resolved from the manifest rather than
from object metadata, so s3:GetObject on the evidence bucket stays confined to
the Batch worker.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS"
```

---

### Task 7: The appliance side — pipeline account, healthchecks, reachability

Three changes to the appliance, all of which only an activation can verify, which is why they share
a task: one future wake confirms all of them. This closes the standing compose-healthcheck defect
from `NEXT.md` at the same time.

**Read the compose-pin trap in `CLAUDE.md` before editing the compose file.** Re-syncing toward
upstream is safe. Bumping the Compose pin is safe. Doing both is not: Compose v5.0.0 made a service
depending on a profile-disabled service a hard error, and our file's lack of profiles is the only
reason a v5 compose runs it at all. **This task re-syncs the file and does not touch the pin.**

**Files:**
- Modify: `modules/analysis/secrets.tf`
- Modify: `modules/analysis/appliance.tf`
- Modify: `modules/analysis/templates/docker-compose.yml.tftpl`
- Modify: `modules/analysis/templates/cloud-init.sh.tftpl`
- Modify: `modules/analysis/batch.tf` (the SG ingress rule)
- Test: `modules/analysis/tests/secrets.tftest.hcl`, `modules/analysis/tests/appliance.tftest.hcl`

**Interfaces:**
- Consumes: `aws_security_group.worker` from Task 5.
- Produces: `aws_secretsmanager_secret.pipeline` (arn, name) and `local.pipeline_user` (string
  `"pipeline"`), both referenced by Task 5's job definition; Timesketch reachable on port 5000
  from the worker security group.

- [ ] **Step 1: Fetch upstream's healthchecks rather than inventing them**

Our compose file is *derived* from upstream's, not a copy (spec A2), and the healthcheck omission
is the one part of that delta that was never deliberate. Get the real thing:

```bash
curl -fsSL "https://raw.githubusercontent.com/google/timesketch/20260630/docker/release/docker-compose.yml" \
  -o "$SCRATCH/upstream-compose.yml"
grep -n -A8 'healthcheck' "$SCRATCH/upstream-compose.yml"
```

Copy the `healthcheck` blocks for `opensearch`, `postgres` and `redis` **verbatim**. If the tag is
unreachable, the equivalents below are correct for these images, but prefer upstream's — the point
of the exercise is to stop diverging.

- [ ] **Step 2: Add the pipeline account secret**

In `modules/analysis/secrets.tf`:

```hcl
# The pipeline's own Timesketch account.
#
# Timesketch auth is local accounts, SSO_ENABLED, or GOOGLE_OIDC_* -- there is
# no AWS IAM integration, so the Batch worker cannot present a role and must
# present a password like any other client. A named account rather than a shared
# responder login, because Timesketch attributes every timeline to a user and
# "which human imported this" should not be answered with "a robot using Alice's
# credentials".
resource "random_password" "pipeline" {
  length  = 32
  special = true
}

resource "aws_secretsmanager_secret" "pipeline" {
  name                    = "${var.name_prefix}/pipeline"
  kms_key_id              = var.kms_key_arn
  description             = "Timesketch login used by the plaso worker to import timelines"
  recovery_window_in_days = 7

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "pipeline" {
  secret_id     = aws_secretsmanager_secret.pipeline.id
  secret_string = random_password.pipeline.result
}
```

In `modules/analysis/appliance.tf`, inside the existing `locals` block:

```hcl
  # Named once. The job definition, the cloud-init account creation, and
  # LOCAL_AUTH_ALLOWED_USERS must all agree, and three string literals would not.
  pipeline_user = "pipeline"
```

- [ ] **Step 3: Write the failing tests**

Append to `modules/analysis/tests/secrets.tftest.hcl`:

```hcl
run "pipeline_has_its_own_account" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition     = aws_secretsmanager_secret.pipeline.name == "${var.name_prefix}/pipeline"
    error_message = "The worker reads this secret by name from its job definition environment."
  }
}
```

Append to `modules/analysis/tests/appliance.tftest.hcl`:

```hcl
# The defect NEXT.md carried from Phase 1 acceptance.
#
# Upstream gives the three backing services healthchecks and has web and worker
# wait on condition: service_healthy. Our derived file dropped that for plain
# list-form depends_on, so Timesketch starts when OpenSearch STARTS rather than
# when it is READY -- and restart: always masks it, which is why acceptance
# passed. These assert the compose text; whether the restart loop is actually
# gone can only be seen in `docker compose logs` after a real activation.
run "backing_services_gate_on_readiness" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition     = strcontains(local.docker_compose, "condition: service_healthy")
    error_message = "Without healthcheck gating, timesketch-web crash-loops until OpenSearch is ready and restart: always hides it."
  }

  assert {
    condition     = length(regexall("healthcheck:", local.docker_compose)) == 3
    error_message = "opensearch, postgres and redis each need a healthcheck; a service_healthy dependency on a service with no healthcheck is a compose error."
  }
}

# The worker imports over the REST API, so the web container can no longer bind
# loopback alone. D6 forbids PUBLIC ingress; this stays private -- no public IP,
# no internet gateway, and a security group that names exactly two sources.
run "timesketch_is_reachable_from_the_worker" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition     = !strcontains(local.docker_compose, "127.0.0.1:5000:5000")
    error_message = "A loopback-only bind leaves the Batch worker with no way to import the .plaso it just produced."
  }
}
```

- [ ] **Step 4: Run them and watch them fail**

Run: `cd modules/analysis && tofu test -filter='tests\appliance.tftest.hcl'`

Expected: FAIL on all three assertions. Confirm the count moved.

- [ ] **Step 5: Fix the compose template**

In `modules/analysis/templates/docker-compose.yml.tftpl`, add a `healthcheck` to each of the three
backing services (upstream's, from Step 1; these are the equivalents):

```yaml
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:9200/_cluster/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 60s
```

for `opensearch`;

```yaml
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U timesketch -d timesketch"]
      interval: 10s
      timeout: 5s
      retries: 20
```

for `postgres`; and

```yaml
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 20
```

for `redis`. Then replace the `depends_on` list on **both** `timesketch-web` and
`timesketch-worker`:

```yaml
    # Upstream gates on readiness and our derived file did not (spec A2). Plain
    # list-form depends_on waits for the container to START; OpenSearch takes
    # tens of seconds more to become READY, and restart: always retried until it
    # worked -- which is why Phase 1 acceptance passed over this.
    depends_on:
      opensearch:
        condition: service_healthy
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
```

And change the web container's port binding:

```yaml
    # Bound on all interfaces, not loopback.
    #
    # D6 forbids PUBLIC ingress and this is not that: the instance has no public
    # IP, the VPC has no internet gateway, and the appliance security group
    # admits exactly two sources -- the operator's connector CIDRs and the plaso
    # worker's security group. The Batch worker imports over this port; a
    # loopback bind would leave it with the .plaso it just produced and no way
    # to deliver it. SSM port-forward is unaffected.
    ports:
      - "5000:5000"
```

- [ ] **Step 6: Create the pipeline account at boot**

In `modules/analysis/templates/cloud-init.sh.tftpl`, immediately after the responder loop:

```bash
# The pipeline's own Timesketch account. Idempotent, like the responder loop.
if ! docker compose exec -T timesketch-web tsctl list-users 2>/dev/null | grep -qx "${pipeline_user}"; then
  echo "creating Timesketch user ${pipeline_user}"
  # set -x is on for this script and would otherwise echo the generated password
  # into /var/log/cloud-init-output.log in plaintext.
  set +x
  PW=$(aws secretsmanager get-secret-value --region "$REGION" \
    --secret-id "${name_prefix}/pipeline" \
    --query SecretString --output text)
  docker compose exec -T timesketch-web tsctl create-user "${pipeline_user}" --password "$PW" >/dev/null 2>&1
  unset PW
  set -x
else
  echo "Timesketch user ${pipeline_user} already exists"
fi
```

Pass it into the template in `appliance.tf`'s `user_data` block:

```hcl
    pipeline_user = local.pipeline_user
```

And add it to `local_auth_allowed_users` in `local.timesketch_conf` so the account is not locked
out if federated ingress is ever enabled — `LOCAL_AUTH_ALLOWED_USERS` is the break-glass hook, and
the pipeline is exactly the kind of account that must survive an auth change:

```hcl
    local_auth_allowed_users = join(", ", [for u in concat(var.responders, [local.pipeline_user]) : "'${u}'"])
```

- [ ] **Step 7: Let the worker reach the appliance**

In `modules/analysis/batch.tf`:

```hcl
# The one ingress the pipeline needs. Source is the worker security group, not a
# CIDR: the worker fleet's addresses are ephemeral and a subnet CIDR would admit
# anything that ever lands in that subnet.
resource "aws_vpc_security_group_ingress_rule" "appliance_from_worker" {
  security_group_id            = var.appliance_security_group_id
  referenced_security_group_id = aws_security_group.worker.id
  from_port                    = 5000
  to_port                      = 5000
  ip_protocol                  = "tcp"
  description                  = "Timesketch REST API, for timeline import by the plaso worker"
}
```

This lives in the analysis layer although the security group belongs to platform: the rule
references the worker SG, which dormancy destroys along with the rest of the fleet. The platform
layer's group survives; only the rule goes.

- [ ] **Step 8: Run the tests and watch them pass**

Run: `cd modules/analysis && tofu test`

Expected: PASS. Confirm the analysis count rose from 26 to at least 36.

- [ ] **Step 9: Run the repo check and commit**

Run: `bash scripts/check.sh check`

```bash
git commit -- modules/analysis -m "fix(analysis): gate Timesketch on backing-service readiness; add the pipeline account

Closes the compose healthcheck defect carried since Phase 1 acceptance. Upstream
gives opensearch, postgres and redis healthchecks and has web and worker wait on
condition: service_healthy; our derived file had dropped that for plain
list-form depends_on, so Timesketch started when those containers started rather
than when they were ready. restart: always masked it.

Re-syncs the compose file toward upstream WITHOUT bumping the Compose pin --
each is safe alone and the pair is not.

The web container now binds all interfaces so the Batch worker can import over
the REST API. D6 forbids public ingress and this is not that: no public IP, no
internet gateway, and a security group naming exactly two sources.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS"
```

---

### Task 8: The state machine and its two triggers

**Files:**
- Create: `modules/analysis/pipeline.tf`
- Modify: `modules/analysis/lambda/pipeline/handler.py` (URL-decoding for the EventBridge path)
- Modify: `modules/analysis/lambda/pipeline/test_handler.py`
- Modify: `modules/analysis/variables.tf`, `modules/analysis/outputs.tf`,
  `modules/analysis/tests/pipeline.tftest.hcl`

**Interfaces:**
- Consumes: `aws_batch_job_queue.worker`, `aws_batch_job_definition.worker` (Task 5);
  `claim_handler` / `sweep_handler` and their payload fields (Task 6).
- Produces: outputs `state_machine_arn`, `job_queue_arn`, `pipeline_topic_arn`.

- [ ] **Step 1: Teach the claim handler to decode an EventBridge key**

S3 delivers object keys URL-encoded, through EventBridge exactly as through a bucket notification —
the intake recorder already calls `urllib.parse.unquote_plus` for this reason. The sweep path,
however, reads keys straight out of DynamoDB, where they are **not** encoded, and decoding those
would corrupt any key containing a literal `+` or `%`. So the two paths must be distinguishable
rather than guessed at. Add to `handler.py`:

```python
import urllib.parse
```

and at the top of `claim_handler`, replacing the first line:

```python
    # The EventBridge rule sends a URL-encoded key; the sweep sends a raw one
    # out of DynamoDB. Decoding unconditionally would corrupt any key with a
    # literal '+' or '%' in it, so the two are named differently rather than
    # sniffed apart.
    if "evidence_key_encoded" in event:
        evidence_key = urllib.parse.unquote_plus(event["evidence_key_encoded"])
    else:
        evidence_key = event["evidence_key"]
```

Add the test to `test_handler.py`:

```python
def test_an_eventbridge_key_is_url_decoded_and_a_swept_one_is_not(monkeypatch):
    """S3 delivers keys URL-encoded through EventBridge; DynamoDB does not.
    Decoding both would corrupt any key holding a literal '+' or '%'."""
    monkeypatch.setattr(handler, "resolve_sha256", lambda case_id, key: "abc")
    monkeypatch.setattr(handler, "_claim", lambda *a, **k: False)

    from_events = handler.claim_handler({"evidence_key_encoded": "CASE-1/a+b.zip"}, None)
    from_sweep = handler.claim_handler(
        {"case_id": "CASE-1", "sha256": "abc", "evidence_key": "CASE-1/a+b.zip"}, None
    )

    assert from_events["evidence_key"] == "CASE-1/a b.zip"
    assert from_sweep["evidence_key"] == "CASE-1/a+b.zip"
```

That test needs the conditional write extracted into a `_claim(case_id, sha256)` helper returning
`bool`. Do that refactor — `claim_handler` keeps its behaviour and the two existing claim tests
keep passing unchanged.

Run: `cd modules/analysis/lambda/pipeline && python -m pytest -v` — expect 17 passing.

- [ ] **Step 2: Add the variables**

```hcl
variable "pipeline_notification_emails" {
  type        = list(string)
  description = "Addresses notified when an artifact is timelined, flagged for triage, or fails."
  default     = []
}

variable "sweep_interval_minutes" {
  type        = number
  description = "How often the reconciler looks for recorded artifacts with no timeline."
  default     = 15
}
```

- [ ] **Step 3: Write the failing tests**

Append to `modules/analysis/tests/pipeline.tftest.hcl`:

```hcl
# Spec 3.2's "ingest pipeline trigger", and A4's insistence that it is one of
# TWO triggers. Recording is never gated; this is.
run "dormant_disables_both_pipeline_triggers" {
  command = plan

  variables {
    posture = "dormant"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.evidence_created.state == "DISABLED"
    error_message = "A dormant environment must not start executions it cannot run; the Batch fleet is DISABLED and the appliance is stopped."
  }

  assert {
    condition     = aws_cloudwatch_event_rule.sweep.state == "DISABLED"
    error_message = "The sweep would start an execution per recorded artifact every fifteen minutes against a fleet that cannot run them."
  }
}

# The whole point of the sweep.
run "active_enables_the_reconciler_that_drains_the_dormant_backlog" {
  command = plan

  variables {
    posture = "active"
  }

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

  variables {
    posture = "active"
  }

  assert {
    condition     = !strcontains(aws_cloudwatch_event_rule.evidence_created.event_pattern, "reason")
    error_message = "Filtering on detail.reason drops artifacts over 5 GB, which arrive as CompleteMultipartUpload rather than CopyObject."
  }
}

# batch:submitJob.sync is not a plain SubmitJob.
#
# Step Functions implements the .sync pattern by creating a managed EventBridge
# rule, so the state machine role needs events:PutRule / PutTargets /
# DescribeRule as well as the Batch actions. Without them the execution fails at
# the first Batch state with an error that names EventBridge, not Batch -- the
# same class of authorisation failure that produced all three Phase 2
# acceptance defects. Only a real execution proves it; this asserts the grant is
# present.
run "state_machine_can_run_the_sync_pattern" {
  command = plan

  variables {
    posture = "active"
  }

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

  variables {
    posture = "active"
  }

  assert {
    condition     = strcontains(aws_sfn_state_machine.pipeline.definition, "needs_triage")
    error_message = "An artifact plaso found nothing in must reach a human, not sit in the manifest looking finished."
  }
}
```

- [ ] **Step 4: Run them and watch them fail**

Run: `cd modules/analysis && tofu test -filter='tests\pipeline.tftest.hcl'`

Expected: FAIL. Confirm the count is 11, not 0.

- [ ] **Step 5: Write `modules/analysis/pipeline.tf`**

```hcl
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
# is most of them, because that is what an evidence store is for.

data "archive_file" "pipeline" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/pipeline"
  output_path = "${path.module}/build/pipeline.zip"
  excludes    = ["test_handler.py", "__pycache__"]
}

# --- Notifications (spec 4.7) ---

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

# DynamoDB only. The claim step resolves a missing digest by querying the
# manifest rather than reading object metadata, precisely so that s3:GetObject
# on the evidence bucket stays confined to the Batch worker (amendment A12).
# It also cannot start an execution -- only the sweep does that.
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

  # A full scan of a manifest plus one StartExecution per row. Generous, because
  # the first sweep after a long dormancy is the largest one this ever does.
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
        # scoped.
        Sid    = "ManageTheSyncPatternRule"
        Effect = "Allow"
        Action = ["events:PutRule", "events:PutTargets", "events:DescribeRule"]
        Resource = "arn:aws:events:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:rule/StepFunctionsGetEventsForBatchJobsRule"
      },
      {
        # Status is the machine's to write. The worker owns timeline_id and
        # event_count and nothing else, so a retried job and this catch handler
        # can never disagree about what happened.
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
      # arbitrary tabular data goes straight to Timesketch, whose import UI maps
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
          TopicArn   = aws_sns_topic.pipeline.arn
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
      # responder was given, so the manifest row is the durable record and there
      # is no queue holding a copy of anything.
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
  # than guess.
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
```

- [ ] **Step 6: Add the outputs**

```hcl
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
```

- [ ] **Step 7: Run the tests and the repo check**

Run: `cd modules/analysis && tofu test` then `bash scripts/check.sh check`

Expected: PASS throughout, analysis count at roughly 41.

- [ ] **Step 8: Commit**

```bash
git commit -- modules/analysis -m "feat(analysis): ingest pipeline state machine and its two triggers

The EventBridge rule on the evidence bucket is the latency path; the scheduled
sweep is the correctness path. An artifact recorded while dormant produced its
S3 event while the rule was DISABLED and that event is gone, so without the
sweep nothing would ever timeline the backlog an evidence store exists to
accumulate.

The state machine role holds events:PutRule -- batch:submitJob.sync is
implemented with a managed EventBridge rule, and without it every execution
fails at the first Batch state with an error naming EventBridge.

Zero events flags for a responder rather than recording success (spec 4.3), and
a failure leaves the artifact in evidence with the manifest row as the durable
record (spec 4.7).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS"
```

---

### Task 9: Raise the recorder's copy ceiling

§5.5 says Phase 3 moves the intake recorder's copy into Batch to remove its 900-second ceiling.
**That is withdrawn (amendment A10), because it contradicts §5.5's own argument.** Batch is
posture-gated: the compute environment is `DISABLED` when dormant. Moving the copy there would make
*recording* posture-gated, and an artifact arriving between incidents would sit in intake with a
seven-day expiry and no legal hold, its manifest row stuck at `recording`, until someone woke the
environment. That is exactly the silent gap §5.5 and amendment A4 exist to prevent.

So the ceiling is raised in place instead, and then measured rather than assumed.

**Files:**
- Modify: `modules/platform/lambda/intake/handler.py`
- Modify: `modules/platform/lambda/intake/test_handler.py`
- Modify: `modules/platform/intake.tf`

**Interfaces:**
- Consumes: nothing.
- Produces: no new names. `_copy_and_hold` keeps its signature.

- [ ] **Step 1: Write the failing test**

Append to `modules/platform/lambda/intake/test_handler.py`:

```python
def test_the_copy_is_tuned_rather_than_left_at_boto3_defaults(monkeypatch):
    """boto3's default multipart chunk is 8 MB with 10 threads, which is the
    difference between a ceiling around the low hundreds of GB and one well
    above it. Spec 5.5 originally planned to remove this ceiling by moving the
    copy to Batch; that was withdrawn in amendment A10 because Batch is
    posture-gated and recording must never be.

    The real ceiling is a measurement, not a config value -- see
    docs/acceptance/phase-3.md check 9. This asserts only that the knobs are set.
    """
    captured = {}

    class FakeS3:
        def copy(self, **kwargs):
            captured.update(kwargs)

        def put_object_legal_hold(self, **kwargs):
            pass

    monkeypatch.setitem(handler._CLIENTS, "s3", FakeS3())
    monkeypatch.setenv("EVIDENCE_BUCKET", "ir-evidence")

    meta = handler.ArtifactMetadata(sha256="abc", case_id="CASE-1", source="laptop", size_bytes=1)
    handler._copy_and_hold("ir-intake", "CASE-1/triage.zip", meta)

    config = captured["Config"]
    assert config.multipart_chunksize >= 64 * 1024 * 1024
    assert config.max_concurrency >= 20
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd modules/platform/lambda/intake && python -m pytest test_handler.py -v`

Expected: FAIL — `KeyError: 'Config'`.

- [ ] **Step 3: Tune the transfer**

In `modules/platform/lambda/intake/handler.py`, add the import and the config:

```python
from boto3.s3.transfer import TransferConfig
```

```python
# Amendment A10: spec 5.5's plan to move this copy into Batch is withdrawn.
#
# Batch is posture-gated -- the compute environment is DISABLED when dormant --
# so moving the copy there would make RECORDING posture-gated, and an artifact
# arriving between incidents would sit in intake with a seven-day expiry and no
# legal hold. That is the silent gap section 5.5 exists to prevent, so the fix
# would have broken the thing it was fixing.
#
# The ceiling is raised here instead. boto3's defaults are an 8 MB chunk and ten
# threads, which for a server-side copy is far below what the function's network
# allowance can drive. The memory bump in intake.tf is the other half: Lambda
# scales network bandwidth with memory, so a 256 MB function cannot use these
# settings however they are tuned.
#
# The resulting ceiling is a MEASUREMENT, not a number to write down here. See
# docs/acceptance/phase-3.md check 9.
_TRANSFER = TransferConfig(
    multipart_threshold=64 * 1024 * 1024,
    multipart_chunksize=64 * 1024 * 1024,
    max_concurrency=20,
    use_threads=True,
)
```

and pass it in `_copy_and_hold`:

```python
    _client("s3").copy(
        CopySource={"Bucket": bucket, "Key": key},
        Bucket=_config("EVIDENCE_BUCKET"),
        Key=target,
        Config=_TRANSFER,
    )
```

Update that function's docstring: the "Phase 3 moves the copy into Batch" line in the module
docstring is now wrong and must go, replaced by a pointer to A10.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd modules/platform/lambda/intake && python -m pytest test_handler.py -v`

Expected: PASS, 8 tests.

- [ ] **Step 5: Give the function the memory to use it**

In `modules/platform/intake.tf`, change `memory_size` and replace the stale comment:

```hcl
  # 900 seconds is the ceiling, and amendment A10 explains why it stays rather
  # than moving to Batch: Batch is posture-gated and recording must never be.
  #
  # Memory is 2 GB not because the function needs the heap -- it streams nothing
  # -- but because Lambda scales NETWORK bandwidth with memory, and the tuned
  # TransferConfig in handler.py cannot drive a 256 MB function's allowance. The
  # pair only works together.
  timeout     = 900
  memory_size = 2048
```

- [ ] **Step 6: Run the repo check and commit**

Run: `bash scripts/check.sh check`

```bash
git commit -- modules/platform/lambda modules/platform/intake.tf -m "fix(platform): raise the recorder's copy ceiling in place

Spec 5.5 planned to remove this ceiling by moving the copy into Batch. That is
withdrawn: Batch is posture-gated, so the move would have made recording
posture-gated, and an artifact arriving between incidents would sit in intake
with a seven-day expiry and no legal hold. The fix would have broken the
property it was fixing.

Tuned TransferConfig plus the memory to drive it -- Lambda scales network
bandwidth with memory, so the two only work together. The resulting ceiling is
a measurement for the acceptance run, not a number to assert here.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS"
```

---

### Task 10: Wire the example environment, amend the spec, write the acceptance gate

**Files:**
- Modify: `envs/example/platform/main.tf`, `envs/example/analysis/main.tf`,
  `envs/example/images/main.tf`, `envs/example/README.md`
- Modify: `docs/superpowers/specs/2026-09-14-ir-infrastructure-design.md`
- Modify: `CLAUDE.md`, `NEXT.md`
- Create: `docs/acceptance/phase-3.md`

**Interfaces:**
- Consumes: every output and variable added by Tasks 1, 4, 5, 7 and 8.
- Produces: an applyable reference deployment.

- [ ] **Step 1: Wire the example environment**

`envs/example/images/main.tf` — the `ecr_repository_urls` map now needs the sixth entry, which the
platform output already provides; check whether it is passed wholesale
(`module.platform.ecr_repository_urls`) or key by key, and add `plaso-worker` if the latter.

`envs/example/analysis/main.tf` — pass the new inputs:

```hcl
  evidence_bucket     = data.terraform_remote_state.platform.outputs.evidence_bucket
  evidence_bucket_arn = data.terraform_remote_state.platform.outputs.evidence_bucket_arn
  plaso_bucket        = data.terraform_remote_state.platform.outputs.plaso_bucket
  plaso_bucket_arn    = data.terraform_remote_state.platform.outputs.plaso_bucket_arn
  artifacts_table     = data.terraform_remote_state.platform.outputs.artifacts_table
  artifacts_table_arn = data.terraform_remote_state.platform.outputs.artifacts_table_arn
```

Match whatever mechanism the file already uses to read platform outputs rather than introducing a
second one — check with `grep -n 'platform' envs/example/analysis/main.tf` first.

Run `cd envs/example/analysis && tofu init -backend=false && tofu validate` and the same in
`envs/example/platform`. **Do not apply.**

- [ ] **Step 2: Add the four amendments**

Append to the §12 table in `docs/superpowers/specs/2026-09-14-ir-infrastructure-design.md`:

```markdown
| A9 | D14's reasoning is replaced, not its conclusion. Batch on EC2 stands, but the recorded ground — that Fargate's 200 GiB ephemeral cap ruled it out — is stale: Fargate attaches EBS at task launch. The live argument is I/O. plaso is disk-bound and D8 targets 100 GB to 1 TB per incident, so scratch is instance-store NVMe rather than a per-task network volume. What EC2 gives up is Fargate's per-task microVM isolation, which matters for a fleet handling live malware; it is bought back with a job sized to a whole instance and an IMDS hop limit of 1 (D14, §4.6) | Phase 3 design |
| A10 | §5.5's plan to move the intake copy into Batch in Phase 3 is **withdrawn**. Batch is posture-gated (§3.2), so the move would have made *recording* posture-gated — an artifact arriving between incidents would sit in intake with a short expiry and no legal hold, its manifest row stuck at `recording`. That is the silent gap §5.5 and A4 exist to prevent, so the fix contradicted the thing it was fixing. The 900-second ceiling stays, raised in place by a tuned transfer and the function memory to drive it, and measured at acceptance rather than assumed (§5.5) | Phase 3 design |
| A11 | The pipeline trigger fans out from the **evidence** bucket, not from intake. §4.1's diagram predates the recorder clearing the intake object once it has copied and held it: a pipeline started from intake would race that delete and read a bucket whose contents expire in `intake_expiry_days`. It is also not the only trigger — a scheduled reconciler sweeps the manifest, because an artifact recorded while dormant produced its S3 event while the rule was disabled, and nothing else would ever timeline it (§4.1, §3.2) | Phase 3 design |
| A12 | The Batch worker is the **second** reader of the evidence store and the first that legitimately reads it. A7's asymmetry is a property of the *recorder*, not of the bucket, and nothing enforces it for a second reader but that reader's own policy. The worker's policy therefore holds `s3:GetObject` on evidence, no delete of any kind, and no legal hold — stated here because the boundary is invisible from the bucket side (§4.6, §5.5) | Phase 3 design |
```

Then correct §4.1's diagram in place — the `RecordIntake` branch stays, and the EventBridge branch
moves under the evidence bucket with the reconciler beside it — and add a line to §4.6 pointing at
A9, and to §5.5 pointing at A10 where it currently promises the Batch move.

- [ ] **Step 3: Write the acceptance gate**

`docs/acceptance/phase-3.md`, following the shape of `phase-1.md` and `phase-2.md`: numbered
checks written **before** the run, a defect table filled in after. The checks:

1. `tofu apply` in `envs/example/platform` succeeds; the worker repository, the DynamoDB gateway
   endpoint and the evidence notification exist.
2. The mirror build succeeds and `/<prefix>/images/plaso-worker` holds a `repo@sha256:` value.
3. **Version parity.** `docker run --entrypoint log2timeline.py <worker digest> --version` and the
   appliance's `docker compose exec timesketch-web log2timeline.py --version` report the same
   plaso. This is the §8 assertion that finally has two things to compare.
4. `tofu apply -var='posture=active'` brings up eleven interface endpoints and an `ENABLED`
   compute environment.
5. **The compose fix.** `docker compose logs timesketch-web` over one activation shows no restart
   loop, and `docker compose ps` shows the three backing services healthy before web starts. This
   is the success condition `NEXT.md` has carried since Phase 1.
6. `irctl upload` an EVTX with a known event count; a timeline appears in Timesketch with that
   count and the manifest row reaches `timelined` with a matching `event_count`.
7. `irctl upload` a `.csv`; it takes the direct route, with no Batch `timeline` job submitted.
8. **The dormant backlog.** Toggle dormant, upload an artifact, confirm the manifest row reaches
   `recorded` with no execution started, toggle active, and confirm the sweep timelines it within
   `sweep_interval_minutes`. This is the check that justifies the reconciler existing.
9. **Measure the copy ceiling.** Upload an artifact large enough to exercise multipart (≥ 5 GB) and
   record the recorder's duration from its CloudWatch log. Extrapolate and write the figure into
   `CLAUDE.md`; A10 makes this a measurement rather than an assumption.
10. A deliberately corrupt artifact (an EVTX truncated to nonsense) reaches `needs_triage`, not
    `timelined`, and SNS notifies.
11. Both trigger paths are exercised on the same artifact — start an execution by hand while the
    S3-triggered one is running — and exactly one timeline results.
12. Teardown, including the parts `phase-2.md` established: clear legal holds separately from the
    retention bypass, and target versions rather than keys.

Expect defects. Two acceptance runs for two, and every one so far was an authorisation failure that
`mock_provider` could not see. The candidates here: `events:PutRule` for the `.sync` pattern, the
ECS agent endpoints, and the worker's read of the evidence bucket through the S3 gateway endpoint —
whose policy condition on `aws:PrincipalAccount` the worker should satisfy, being an in-account
role, but which has not been exercised from inside the VPC before.

- [ ] **Step 4: Update `CLAUDE.md`**

Add to the architecture table (`modules/analysis` now holds the Batch fleet and Step Functions),
the test-count table (platform 51, images 10, analysis ~41, cli 16, intake 8, pipeline 17, worker
15), the commands section (the two new Python suites and their working directories), and a Phase 3
subsection under "Invariants that are expensive to break" covering: the two triggers and why
dropping the sweep is silent; `events:PutRule` for `submitJob.sync`; MIME multipart in the Batch
launch template; the worker tag being the base digest; and A12's boundary.

Remove the claim that Phase 3 will move the copy into Batch wherever it appears.

- [ ] **Step 5: Rewrite `NEXT.md`**

It is the hand-off, and it should shrink. The compose defect is closed. What remains open: the
Phase 3 acceptance run (not yet done, and two for two on finding defects), the Snyk judgement call,
`irctl posture`, CloudTrail to CloudWatch Logs, and everything already listed for Phase 4. Add the
Phase 3 items this plan deliberately deferred: the `.plaso` legal-hold question with its success
condition, and the manifest-scan threshold at which the sweep wants a GSI.

- [ ] **Step 6: Run everything and the scans**

```bash
bash scripts/check.sh check
cd cli && python -m pytest tests -q
cd ../modules/platform/lambda/intake && python -m pytest -q
cd ../../../analysis/lambda/pipeline && python -m pytest -q
cd ../../../../containers/plaso-worker && python -m pytest -q
```

Then Snyk, per `CLAUDE.md`: `snyk_iac_scan` on `modules/platform` **and** `modules/analysis` (the
analysis module now carries IAM and a launch template and has not been scanned before), and
`snyk_code_scan` on `containers/plaso-worker`, `modules/analysis/lambda` and `cli`. Target: nothing
above low, 0 Snyk Code findings. **Re-run rather than trusting the count written in `CLAUDE.md`** —
it moves whenever a resource is added, and this plan adds many. New lows need reasoning in the file
header or a scoped `.snyk` entry, not silence.

- [ ] **Step 7: Commit and mark the PR ready**

```bash
git commit -- envs docs CLAUDE.md NEXT.md -m "docs: Phase 3 amendments, acceptance gate, and hand-off

A9 replaces D14's reasoning without changing its conclusion. A10 withdraws
5.5's plan to move the intake copy into Batch -- it would have posture-gated
recording. A11 moves the pipeline trigger to the evidence bucket and records
that there are two triggers, not one. A12 states the boundary the Batch worker
crosses as the evidence store's second reader.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Wtx98TgQcc3EhqBAWjLxiS"

git push
```

Leave the PR a **draft**. Phase 3 is not done when CI is green — §9's gate is "upload triggers
timeline creation with no manual step", and only the acceptance run shows that. Mark it ready after
`docs/acceptance/phase-3.md` has its defect table filled in.

---

## Self-Review

**Spec coverage.** §4.1 flow — Tasks 5, 6, 8 (with the A11 correction). §4.2 hashing — unchanged,
Phase 2. §4.3 routing, including the zero-events fallback — Task 6 (`route`) and Task 8
(`FlagForTriage`). §4.4 normalizers — deferred by D5, no task, correct. §4.5 parity — Tasks 1, 3, 4
and acceptance check 3. §4.6 compute — Task 5 and amendment A9. §4.7 failure handling — Task 8's
`RecordFailure`; no SQS DLQ, argued in the plan. §3.2 dormancy row "ingest pipeline trigger" —
Tasks 5 and 8. §5.5's Batch-copy promise — Task 9, withdrawn as A10. §7 layout — `containers/`
created as specified. §8 testing, parity assertion — Task 4's config-shape assertion plus acceptance
check 3, with the limitation stated. §9 phase-3 gate — `docs/acceptance/phase-3.md`.

**Known gaps, stated rather than hidden:**
- **`irctl` gains no `posture` subcommand.** §7 promises one; `NEXT.md` already carries it as an
  open question, and Phase 4's `case close` is when the CLI surface should be settled as a whole.
- **Per-case cost attribution tags** are §6 and Phase 4. The Batch resources take `local.common_tags`
  like everything else, so the retrofit is not made harder.
- **No `.plaso` legal hold.** Deferred in Task 5 with a success condition.

**Type consistency.** `claim_handler` returns `claimed`, `case_id`, `sha256`, `evidence_key`,
`route`, `plaso_key`; Task 8's Choice state reads `$.claimed` and `$.route`, and its Batch commands
read `$.case_id`, `$.sha256`, `$.evidence_key`, `$.plaso_key`. `worker.py` accepts
`--case-id/--sha256/--evidence-key` for `timeline` and `--case-id/--sha256/--key/--bucket-kind` for
`import`, which is what `States.Array` builds. `plaso_key` is defined identically in `handler.py`
and `worker.py` — the worker computes it for its upload and the claim step for the command, and the
acceptance run is what proves they agree.

**Cross-references:** Task 5 depends on `aws_secretsmanager_secret.pipeline` and
`local.pipeline_user`, which Task 7 owns; Task 5 Step 8 says to pull that code forward rather than
leaving a broken intermediate state. Every other task's `Consumes` block names only things an
earlier task produced.
