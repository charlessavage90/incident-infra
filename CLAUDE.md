# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

For what the *next* session should pick up — open items, phase-specific context, and the state of
the live development environment — see `NEXT.md`.

## What this is

An OpenTofu module that stands up an incident-response analysis environment in a dedicated AWS
account, holds it dormant between incidents at storage-only cost, and returns it to service in
minutes. Timesketch is the timeline database; plaso does artifact timelining.

**The design is the source of truth, and it records rejected alternatives.** Read it before
changing anything structural:

- `docs/superpowers/specs/2026-09-14-ir-infrastructure-design.md` — 16 numbered decisions (D1–D16),
  each with what was rejected and why
- `docs/superpowers/plans/2026-09-14-phase-1-platform-and-appliance.md` — Phase 1 implementation
- `docs/superpowers/plans/2026-09-14-phase-2-evidence-store.md` — Phase 2 implementation, and the
  place three decisions the spec left open are argued: write-before-copy, the separate legal-hold
  call, and no `prevent_destroy` on the evidence buckets
- `docs/superpowers/plans/2026-09-16-phase-3-ingest-pipeline.md` — Phase 3 implementation, and
  where the four decisions the spec left open are argued: D14's re-examination, §5.5's
  self-contradiction, which bucket the pipeline triggers from, and how the worker reaches
  Timesketch
- `docs/acceptance/phase-1.md` — the acceptance gate, plus a table of the six defects the first
  real run exposed
- `docs/acceptance/phase-2.md` — the Phase 2 gate, plus a table of the three defects its first
  real run exposed
- `docs/acceptance/phase-3.md` — the Phase 3 gate. **Written, not yet run.**

Phases 1 and 2 are complete and acceptance-passed against a real AWS account. **Phase 3 is built
but has not had its acceptance run** — CI-green is not the same claim. Phase 4 (lifecycle) is
specified but not built.

**Every test in this repository is offline, so "CI-green" and "works" remain different claims.**
Phase 1's acceptance run found six defects in code that looked finished; Phase 2's found three,
all of them authorisation failures that `mock_provider` cannot see. Assume the next phase behaves
the same way.

The design document carries an **§12 Amendments** table. Twelve corrections have been made in
place rather than in a parallel errata file; read §12 before trusting a remembered reading of that
document. A1, A3, A4, A7, A8, A10, A11 and A12 changed load-bearing behaviour. A2's open half —
the dropped compose healthchecks — is now fixed. A9 replaces D14's *reasoning* without changing its
conclusion, and A10 **withdraws** something §5.5 previously promised, so a remembered reading of
either is likely to be wrong.

## Commands

`tofu` must be on PATH. On Windows it is installed to
`~/AppData/Local/Microsoft/WinGet/Packages/OpenTofu.Tofu_*/` and only appears in **login** shells,
so non-login subshells need it prepended explicitly.

```bash
bash scripts/check.sh check     # fmt-check + validate + tflint + tofu test  (what CI runs)
bash scripts/check.sh fmt       # rewrite formatting
bash scripts/check.sh test      # tofu test across all three modules
```

The `Makefile` delegates to `scripts/check.sh`. It exists for CI and Unix; `make` is absent from
Git Bash on Windows, so prefer invoking the script directly.

**`check.sh check` is not the same locally as in CI unless `tflint` is installed.** The script
skips linting with a one-line notice on stderr when the binary is absent, and exits 0 -- so a
`terraform_unused_declarations` failure reaches CI looking like a clean local run. It is easy to
lose that notice when filtering output. Install it to make local and CI agree:

```bash
curl -sSL https://github.com/terraform-linters/tflint/releases/download/v0.52.0/tflint_windows_amd64.zip -o /tmp/tflint.zip
cd /tmp && unzip -oq tflint.zip && export PATH="/tmp:$PATH"
```

**Running one test file:**

```bash
cd modules/platform && tofu test -filter='tests\network.tftest.hcl'   # Windows
cd modules/platform && tofu test -filter=tests/network.tftest.hcl      # Linux/macOS
```

`-filter` needs the **OS-native path separator**. A filter that matches nothing reports
`Success! 0 passed, 0 failed` — it does not error. Always check the count, or you will believe
tests ran when none did.

**Python.** The repo has four Python trees since Phase 3 — `cli/` (`irctl`),
`modules/platform/lambda/intake/` (the recorder), `modules/analysis/lambda/pipeline/` (claim and
reconcile) and `containers/plaso-worker/` (the worker). They are separate suites with separate CI
jobs and separate working directories; there is no single command that runs them all.

```bash
python -m venv .venv                                  # .venv/ is gitignored
./.venv/Scripts/python.exe -m pip install -e "cli[dev]"
./.venv/Scripts/python.exe -m pip install boto3 pytest

cd cli && python -m pytest tests -v                                     # irctl, 16
cd modules/platform/lambda/intake && python -m pytest -v                # recorder, 8
cd modules/analysis/lambda/pipeline && python -m pytest -v              # claim/sweep, 20
cd containers/plaso-worker && python -m pytest -v                       # worker, 23
```

The worker suite needs `requests` as well as `boto3` and `pytest`; see
`containers/plaso-worker/requirements-dev.txt`.

**No test anywhere touches AWS.** The HCL uses `mock_provider`; every Python suite uses
`botocore.Stubber` or an injected fake. No credentials, no network, no cost. Current counts — **check them, a filter that matches nothing still reports success**:

| Suite | Count |
|---|---|
| `modules/platform` | 51 run blocks |
| `modules/images` | 9 |
| `modules/analysis` | 42 |
| `cli` | 16 tests |
| `modules/platform/lambda/intake` | 8 tests |
| `modules/analysis/lambda/pipeline` | 20 tests |
| `containers/plaso-worker` | 23 tests |

**Posture toggle** (applies real infrastructure, costs money):

```bash
cd envs/example/analysis
tofu apply -var='posture=active' -var='responders=["alice"]'
tofu apply -var='posture=dormant'
```

## Architecture

Three modules with independent state. The split is the design, not organisation.

| Module | Lifetime | Holds |
|---|---|---|
| `modules/platform/` | **Permanent** | VPC, KMS, ECR, IAM, private DNS, budget alarm, tooling bucket, **the EBS data volume**, and the whole **evidence store** — four buckets, both manifest tables, the intake recorder, CloudTrail |
| `modules/analysis/` | **Toggleable** | Appliance, VPC interface endpoints, secrets, **the plaso Batch fleet, the Step Functions pipeline and both its triggers** — driven by `var.posture` |
| `modules/images/` | Independent | CodeBuild mirror; runs outside the VPC, unaffected by dormancy |

**The EBS data volume lives in `platform/`, not `analysis/`.** That is load-bearing: `tofu destroy`
against `analysis/` loses no warm data, because indices and evidence sit on the other side of the
boundary. Do not move it. The same argument puts the entire evidence store there, and for the
same reason — nothing in Phase 2 is in `analysis/`, so the posture toggle cannot affect it.

**Dormancy is a variable, never a destroy.** `posture = "dormant"` stops the instance
(`aws_ec2_instance_state`), disables the Batch environment, and destroys the interface endpoints.
It never touches the VPC, subnets, route tables, security groups, DNS, or the data volume — because
organisations attach their own connectors (ZPA, Tailscale, TGW) to that network layer and must not
have to re-onboard on every cycle.

**The module does not own connectivity (D7).** It exposes an attachment surface — subnet/SG/route-table
IDs and a stable `timesketch.ir.internal` name as outputs, `allowed_ingress_cidrs` /
`allowed_ingress_security_group_ids` as inputs. Access is SSM port-forward; there is no public
ingress anywhere (D6).

**No internet egress by default.** No IGW, no NAT. Everything reaches AWS through VPC endpoints.
This is a posture choice — plaso workers handle live malware — not frugality. Two consequences that
have already caused outages:

- Anything the OS needs must come through the S3 gateway endpoint or be mirrored into the account
  first. `dnf install` of a package not in the AL2023 repos will fail, and there is no fallback.
- The S3 endpoint policy has **two** statements. The `aws:PrincipalAccount` condition stops a
  compromised instance copying evidence to another account; the second statement allows AWS-owned
  buckets, because **Amazon Linux repos are fetched anonymously and ECR image layers arrive via
  AWS-presigned URLs** — neither carries this account's principal. Deleting the second statement
  returns 403 on both, and `dnf` dies before Docker is installed.

### The evidence store (Phase 2)

An artifact's whole journey, because the ordering is not guessable from the files:

```
irctl upload  --▶  intake bucket  --s3:ObjectCreated--▶  recorder Lambda  --▶  evidence bucket
   hashes first      quarantine                              manifest, copy,        Object Lock
   S3 verifies                                               legal hold             + legal hold
   at PUT
```

**The recorder runs outside the VPC, and can read intake but never evidence.** Both are deliberate
and both are load-bearing:

- *Outside the VPC*, because in-VPC placement would put it behind the interface endpoints that
  dormancy destroys. An artifact arriving between incidents would then sit unrecorded in a bucket
  with a 7-day expiry, and the gap would be silent. Recording is not posture-gated; the Phase 3
  pipeline that timelines an artifact will be, because that needs a running appliance (spec §5.5).
- *Read on intake, never on evidence.* No object bytes pass through the function: `HeadObject`
  returns the metadata and `CopyObject` is executed server-side by S3. That is what makes running
  it outside the VPC defensible rather than a concession — a component that cannot read the
  evidence store cannot leak it.

  **`s3:GetObject` appears exactly once in that role, scoped to intake, and it is not optional.**
  IAM has no `s3:HeadObject` action — `HeadObject` is authorised by `s3:GetObject` — and
  `CopyObject` requires `s3:GetObject` on the source object it copies. An earlier draft withheld
  it on the belief that `GetObjectAttributes` would do; the recorder 403'd on `HeadObject` on its
  first real invocation (amendment A7). `GetObjectAttributes` cannot substitute: it does not
  return user metadata, which is where `sha256`, `case-id` and `source` live.

  **What must never change is the asymmetry.** Adding any read action to the evidence-scoped
  statement is what would break this argument. The test asserts that `s3:GetObject` appears on the
  `ReadIntakeMetadata` statement and nowhere else.

**The manifest row is written before the copy, with a `status` field.** A failed copy then leaves a
recoverable trace rather than none. The conditional write is deliberately not a plain
`attribute_not_exists` check:

| Existing row | Meaning | Action |
|---|---|---|
| none | first arrival | claim `recording`, copy, hold, mark `recorded`, clear intake |
| `recording` | a previous attempt died mid-flight | continue from the copy; both it and the hold are idempotent |
| `recorded` | genuine duplicate (spec §4.2) | clear intake, do nothing else |

**Deduplication is that conditional write failing, not a check before it.** Two concurrent
invocations on the same artifact would both pass a read-then-write check; only one wins a
conditional write. It is scoped within a case — the same file on two engagements is two custody
chains, which is why `artifacts` is keyed `(case_id, sha256)`.

**The intake bucket still earns its place even though S3 verifies the hash at PUT.** What it
catches is no longer transfer corruption — that never reaches storage. It is an artifact that
transferred perfectly and was filed against the wrong case, which under per-case COMPLIANCE mode
nobody can undo.

**Known ceiling:** the copy is driven by a Lambda under a 900-second timeout. It fails loudly and
the object stays in intake.

**Phase 3 was supposed to move that copy into Batch and does not (amendment A10), because doing so
would break the property §5.5 exists to provide.** Batch is posture-gated — the compute environment
is `DISABLED` when dormant — so an artifact arriving between incidents would sit in intake with a
7-day expiry and no legal hold, its manifest row stuck at `recording`, until someone woke the
environment. The ceiling is raised in place instead: a tuned `TransferConfig` in `handler.py` **and**
2 GB of function memory, because Lambda scales network bandwidth with memory and neither change
does anything without the other. The real ceiling is a measurement, not a number to write down —
`docs/acceptance/phase-3.md` check 9 takes it.

**`irctl` is configured entirely from environment variables** so it holds no state:
`IR_INTAKE_BUCKET`, `IR_CASES_TABLE`, `IR_RETENTION_YEARS` — each a `tofu output` from
`envs/example/platform`. `IR_RETENTION_YEARS` exists because the retention policy would otherwise
live only as a default in the CLI, and a deployment configured for seven years would record three
on every case it opened.

## Invariants that are expensive to break

**Image digest pinning (spec §4.5).** Timesketch's own Dockerfile installs `plaso-tools` *unpinned*
from `ppa:gift`, so two builds of the same Timesketch release tag can carry different plaso
versions — and Timesketch rejects `.plaso` files produced by a newer plaso than it runs. Everything
is therefore referenced by `@sha256:` digest, resolved once by the mirror and published to
`/<name_prefix>/images/*` in SSM. ECR repos are `IMMUTABLE`. Never introduce a tag reference on the
path to the appliance.

**Docker Compose is mirrored, not installed.** AL2023 packages no compose plugin and the VPC has no
internet, so `modules/images` fetches the binary in CodeBuild, checksums it against upstream's
published `.sha256`, and stores it in the tooling bucket. The appliance re-verifies the checksum
before making it executable. Phase 3 should reuse this path for plaso tooling.

The pinned `v5.5.1` is far above what the stack needs. **Our compose file's floor is Compose
v2.0** — it uses no `version:` key, list-form `depends_on`, `ulimits`, and short-syntax ports and
volumes, and nothing newer. Bumping the pin is low-risk *on its own*.

**But the pin and our divergence from upstream protect each other, which is the trap.** Compose
v5.0.0 made a service depending on a profile-disabled service a hard error (`service X is
required by Y, but is disabled`). Upstream Timesketch's compose file uses profiles heavily
(`legacy-ui`, `v3-ui`, `telemetry`); ours has none, which is the only reason a v5 compose runs it
at all. Re-syncing our compose file toward upstream is safe. Bumping compose is safe. **Doing
both is not**, and neither change looks dangerous in isolation.

**Our compose file is derived from upstream's, not a copy of it** — D13 says "unmodified" and is
wrong (spec A2). Against the pinned `20260630` tag we drop `nginx` (the web container binds to
loopback and is reached over SSM), drop the profiled services, substitute digests for tags, and
repoint volumes at the data volume. Those are all deliberate. One is not: upstream gives
`opensearch`, `postgres` and `redis` healthchecks and has the web and worker services wait on
`condition: service_healthy`. Ours uses plain list-form `depends_on`, so Timesketch starts when
those containers *start* rather than when they are *ready*. `restart: always` masks it, which is
why acceptance passed.

**The mirror must stay idempotent.** Tags are immutable, so re-pushing fails; the buildspec skips
images already present. Sources are ECR Public, not Docker Hub, which rate-limits anonymous pulls
per IP and broke the mirror in practice.

The cost of that idempotency is that **changing a pinned version does not change what is already
mirrored.** A deployed ECR can hold an image the current configuration would no longer choose,
and a fresh deployment will disagree with it. This has already happened once: `postgres` moved
from `13.0-alpine` to `13-alpine` (the exact 2020 patch release is on no non-rate-limited
registry), and the development account's ECR still holds `13.0-alpine` because the mirror saw the
repository populated and skipped it. Harmless there — §4.5's parity invariant is about the
*Timesketch* image, not this one — but the same mechanism applied to the Timesketch image would
not be harmless. Re-mirroring means deleting the ECR tag first, deliberately.

**No bucket-level default retention on the Object Lock buckets.** `evidence.tf` declares
`aws_s3_bucket_object_lock_configuration` with **no `rule` block**, and that omission is the single
most dangerous thing in this repo to "fix". A default retention stamps a retain-until date at PUT.
Spec §5.2 requires the clock to start when the case *closes*. Adding a
`rule { default_retention { ... } }` silently converts the model into "N years from upload" and
nothing will tell you — there is no error, no warning, and the mistake only surfaces years later.
A test asserts the absence.

**Object Lock protects a version, not a name, so the locked buckets deny `s3:DeleteObject`.**
A `DeleteObject` with no version ID on a versioned bucket deletes nothing — it writes a delete
marker and returns 204 — and S3 permits that on an object under a legal hold. The bytes are never
at risk, but the artifact disappears from `aws s3 ls` and from every read-by-key path, and Phase 3
reads evidence by key. Phase 2 acceptance check 8 found this (amendment A8).

The deny in `evidence.tf` is deliberately narrow, and the narrowness is the part to preserve:
`s3:DeleteObject` authorises the marker, `s3:DeleteObjectVersion` authorises a versioned delete.
Denying both would make §5.2.2 break-glass teardown — and `tofu destroy` against a development
deployment — impossible.

Two related facts, both established against a live bucket rather than assumed:

- **A legal hold outranks `--bypass-governance-retention`.** The bypass does not touch a hold; the
  hold must be cleared separately, which is why teardown has that extra step.
- **Break-glass deletion must target a version**, or the new bucket policy refuses it first.

**Legal hold at PUT, retention at case close, in that order.** S3 Object Lock has two primitives,
not three: a retention period and one boolean legal hold. There is no "event hold" — earlier drafts
of the spec named one and there is nothing to build against (amendment A3). The order is not
arbitrary: releasing the hold before setting retention leaves a window in which the object is
deletable by anything holding `s3:DeleteObject`. The one boolean serves two meanings — event hold
for an open case, and D9's litigation flag — distinguished in the manifest, because S3 cannot
distinguish them.

**The CMK has an explicit key policy, and its root statement is not optional.** The default key
policy grants the account root and lets IAM delegate from there — which never reaches a *service*
principal. Two of them need naming explicitly, and each was discovered by an apply failing:

- `AllowCloudTrailEncrypt`, without which the trail fails at apply.
- `AllowCloudWatchLogsEncrypt`, without which the intake recorder's CMK-encrypted log group fails
  with `CreateLogGroup: AccessDeniedException` (amendment A7's sibling; Phase 2 acceptance defect 1).

**Neither error names the key** — CloudTrail's names the trail, CloudWatch Logs' names the log
group ARN. Any future CMK-encrypted resource owned by a service rather than by an account
principal will need the same treatment, and will fail the same uninformative way.

**The root statement is the one that cannot be dropped.** An explicit key policy that omits
`EnableRootAccountAccess` **cannot be edited by anyone**, and the key becomes unusable and
undeletable except by scheduling deletion. Do not tidy it away. A test asserts all three
statements.

### The ingest pipeline (Phase 3)

**There are two triggers and the second one is not redundant.** An EventBridge rule on the
*evidence* bucket starts the state machine within seconds; a scheduled reconciler (`sweep`) scans
the manifest every `sweep_interval_minutes` while active. Deleting the rule would cost latency.
Deleting the sweep would silently strand **every artifact that arrived while the environment was
dormant** — their S3 events fired when the rule was `DISABLED` and those events are gone. That is
most artifacts, because accumulating them between incidents is what an evidence store is for.

**The trigger hangs off evidence, not intake (A11).** §4.1's original diagram fanned out from
intake, which cannot work now the recorder clears the intake object on success: the pipeline would
race a `DeleteObject` and read a bucket whose contents expire in `intake_expiry_days`.

**The event pattern deliberately does not filter on `detail.reason`.** The recorder's server-side
copy is a `CopyObject` below 5 GB and a `CompleteMultipartUpload` above it, so a reason filter
would silently skip exactly the large artifacts.

**Both triggers converge on one conditional DynamoDB write**, `recorded → timelining`, in the claim
Lambda. Deduplication is that write failing, not a check before it — the same argument, and
deliberately the same shape, as the recorder's `_claim`. A stale `timelining` row becomes
re-claimable after `STALE_CLAIM_HOURS`, which **must stay at or above the Batch job definition's
`attempt_duration_seconds`**; below it, the sweep would re-drive work still in flight and produce a
duplicate timeline.

**`batch:submitJob.sync` needs `events:PutRule`.** Step Functions implements the `.sync` wait by
creating a managed EventBridge rule (`StepFunctionsGetEventsForBatchJobsRule`). Without
`events:PutRule`, `PutTargets` and `DescribeRule` every execution fails at the first Batch state
with an error naming **EventBridge**, which is not where anyone looks.

**The Batch launch template's user data must be MIME multipart.** Batch *appends* its `ECS_CLUSTER`
configuration to whatever the template supplies, and can only do that to an archive. A plain shell
script is replaced rather than merged, and the symptom is silence: instances launch, look healthy,
never join the cluster, and every job sits in `RUNNABLE` with no error in Batch, in ECS, or on the
instance. Missing `ecs` / `ecs-agent` / `ecs-telemetry` endpoints produce the identical symptom, so
check both.

**The worker image is tagged by its base digest, not by `timesketch_version`.** The mirror's
idempotency rule is "tag exists, skip", and a version-tagged worker would let that rule hide a
stale base — the exact mechanism that left `postgres:13.0-alpine` in the development account after
the pin moved. A new base is always a new tag, so the skip stays honest.

**The worker is the evidence store's second reader, and A7's asymmetry does not protect it
(A12).** That asymmetry is a property of the *recorder*, not of the bucket. The worker's job role
holds `s3:GetObject` on evidence, no delete of any kind, and no legal hold — and a test asserts
the absence of both by **action**, because `mock_resource` gives all four buckets one ARN and any
assertion about which bucket a policy names passes vacuously.

**Neither pipeline Lambda touches S3 at all.** The claim step resolves a missing digest by querying
the manifest rather than by `HeadObject`, specifically so `s3:GetObject` on evidence stays confined
to the worker. Adding it to the claim role would be the easy, wrong fix for a lookup failure.

**Keys arrive URL-encoded from EventBridge and raw from the sweep.** They are passed under
different field names (`evidence_key_encoded` versus `evidence_key`) rather than sniffed apart:
decoding a raw key would corrupt any containing a literal `+` or `%`.

**The Batch job queue stays `ENABLED` while dormant; only the compute environment is `DISABLED`.**
A job submitted against a disabled environment waits. A job submitted against a disabled queue is
rejected outright, and a rejected job is an artifact that never gets timelined.

**Timesketch's web container binds all interfaces, not loopback.** That is not a D6 violation: D6
forbids *public* ingress, and there is no public IP, no internet gateway, and a security group
admitting exactly two sources. The bind is not the control; the security group is. The worker
authenticates as a dedicated `pipeline` local account — Timesketch has no AWS IAM integration, so
it must present a password like any other client.

### `modules/analysis/templates/cloud-init.sh.tftpl`

Four guards, each of which caused a real failure. It runs on every boot of a *replaced* instance,
and **not** on stop/start (cloud-init `scripts-user` is per-instance), which is why the fourth one
is a systemd unit.

1. `vm.max_map_count=262144` written to `/etc/sysctl.d/` — OpenSearch will not start without it, and
   `sysctl -w` alone would be lost on the next activation.
2. The data volume is resolved **by volume ID** via `nvme id-ctrl`. On Nitro instances `/dev/sdf`
   appears as an NVMe device whose number is not predictable.
3. `mkfs` is guarded by `blkid`. **This is the single most important line in the repository** — an
   unguarded format destroys every timeline on the second activation.
4. `ssm-endpoint-wait.service` restarts the SSM agent once its endpoint actually accepts
   connections. Dormancy destroys the endpoints; on reactivation the agent races ENI readiness,
   loses, logs `entering hibernation due to error`, and backs off **for up to an hour**. Terraform
   `depends_on` does not fix this: the endpoint reports `available` before its ENI forwards packets.

`set -x` is on throughout, so anything handling a secret must be wrapped in `set +x` / `set -x`.
Responder passwords leaked into `/var/log/cloud-init-output.log` until that was added.

## Upstream facts worth not rediscovering

All verified against upstream sources during design; each shaped a decision.

### plaso

- Roughly **200 supported formats**: Windows registry/EVTX/`$MFT`/`$UsnJrnl`/prefetch/LNK, browser
  history, macOS plists and keychains, Linux syslog/utmp, and a lot of *server and application*
  logs (Apache, IIS, PostgreSQL, vsftpd, Snort/Suricata, Windows Firewall, McAfee, Symantec, Sophos).
  The reflex "just run plaso at it" is usually right.
- **No generic CSV or JSON parser exists.** `plaso/parsers/dsv_parser.py` is an *abstract base
  class* whose `COLUMNS` list "needs to be defined by each DSV parser"; concrete parsers such as
  `SymantecParser` subclass it, and a `_MAGIC_TEST_STRING` sniff test rejects non-conforming files.
- Its JSON-L support is nine schema-specific parsers, including `aws_cloudtrail_log`,
  `azure_activity_log`, `gcp_log`, and `microsoft_audit_log`. So plaso covers more cloud than
  expected — but **no Okta, no Entra sign-in logs, no Google Workspace**.
- `log2timeline` auto-detects, so the pipeline routes by extension rather than classifying (D4).

### Timesketch

- Auth is **local accounts, `SSO_ENABLED` (trusting a `REMOTE_USER` env var set by a fronting web
  server), or `GOOGLE_OIDC_*`** (generic despite the name — discovery URL, client id/secret and
  algorithm are all configurable). There is **no AWS IAM integration, no SAML, no LDAP**. SSM
  authenticates the tunnel, never the application.
- `LOCAL_AUTH_ALLOWED_USERS` keeps named local accounts working even when OIDC is enabled. That is
  the break-glass hook if federated ingress is ever added.
- Direct import needs three fields: `message`, `datetime` (ISO 8601), `timestamp_desc`. The web UI
  can map arbitrary columns onto them, combine columns, and supply defaults — which is why v1 ships
  no pre-built normalizers (D5).
- The release image installs `plaso-tools`, so **it already contains `log2timeline.py`**. The
  `timesketch-worker` service uses the *same image* as `timesketch-web`, with a different command.
- Upstream pins live in `docker/release/config.env`; `OPENSEARCH_MEM_USE_GB` is RAM/2 capped at
  32 GB and `NUM_WSGI_WORKERS` is `(cores * 2) + 1`. Both are derived from `instance_type` in
  `appliance.tf`, so resizing needs no other change.
- The API client (`timesketch_api_client`) is **not** installed in the web container. Scripted
  interaction means the REST API with a session cookie and CSRF token.

### AWS behaviours that drove decisions

- **S3 Object Lock can be enabled on an existing bucket**, not only at creation — but it can never
  be disabled afterwards, and versioning can never be suspended.
- Object Lock supports **variable retention with an event hold**: the retain-until date is computed
  when the hold is *released*, which is what lets retention start at case closure rather than at
  upload (D9/D10).
- **Object Lock buckets cannot receive S3 server access logs.** Bucket auditing must use CloudTrail
  data events.
- Interface endpoints bill **per ENI — per endpoint, per AZ**. They are deliberately placed in one
  AZ, matching the appliance, which halves the largest active-cost line.
- ECR Public carries `docker/library/*` mirrors of Docker Hub official images and
  `opensearchproject/opensearch`. It does **not** carry `postgres:13.0-alpine` (a 2020 patch
  release); `13-alpine` is the nearest equivalent.
- AL2023 packages `docker` (25.0.x) and `nvme-cli`, and **no compose plugin of any kind** —
  `dnf search compose` returns only unrelated packages.
- Fargate tops out at 32 vCPU / 244 GB and can attach EBS volumes at task launch, so its old
  200 GiB ephemeral cap is not the constraint it once was (relevant to D14's revisit).

## Testing conventions

- **Use `jsonencode`, not `aws_iam_policy_document`.** The data source's rendered `.json` is a
  computed attribute that `mock_provider` replaces with an invented string — which both fails
  provider validation at plan time and makes any assertion about policy content a test of the mock
  rather than of the module.
- OpenTofu 1.12 has **no** `source` argument on `mock_provider`, so the mock block is duplicated
  across each module's test files. **Run `python scripts/sync-test-mocks.py` rather than editing
  one file.** Keeping them in sync by hand is what failed, twice: adding the intake Lambda broke
  seven runs in `modules/platform` files nobody had touched, and the Phase 3 Batch fleet did the
  same in `modules/analysis`. Both times only the new test file mocked `aws_iam_role`, and the
  provider validates role ARNs. The error names the ARN, never the missing mock. The script
  regenerates **both modules'** preambles, each from its own canonical block — their needs differ,
  but within a module they must not.
- Mocks must supply anything the provider *validates* and anything returned as a *list*. Known
  necessities: `aws_availability_zones.names` (empty otherwise), and ARNs for `aws_kms_key`,
  `aws_ecr_repository`, `aws_iam_role`; plus `aws_subnet.availability_zone`, `aws_ami.id`,
  `aws_ssm_parameter.value`, `aws_caller_identity.account_id`, `aws_region.region`.
- `lifecycle` is a meta-argument and **cannot be read in an assertion**. Assert the property it
  protects instead.
- `expect_failures` accepts a variable (`[var.posture]`) for validation blocks and a resource
  (`[aws_instance.appliance]`) for preconditions. It must list **every** resource that trips a
  shared precondition: both evidence buckets carry the compliance-mode guard, and listing only
  one passed while leaving the other reachable.
- Assertions should name the consequence, not the rule. The failure message is what a future reader
  gets at 2am.
- **`mock_resource` defaults apply to every instance of a type.** All four S3 buckets share one
  mocked ARN, so any assertion of the form *"this policy does not mention the evidence bucket"*
  passes vacuously and proves nothing. Assert on **actions**, which are literal config and are
  genuinely checked.
- **Several provider block types are sets, not lists**, and `x[0]` on one is a plan-time error
  rather than a failing assertion. Known so far: `aws_s3_bucket_server_side_encryption_configuration.rule`,
  `aws_s3_bucket_lifecycle_configuration.rule`, `aws_dynamodb_table.point_in_time_recovery` and
  `.server_side_encryption`, and `aws_s3_bucket_notification.lambda_function[*].events`. Use
  `one(...)`, and compare a set against `toset([...])` — `tolist([...])` fails on type even when
  the contents match.
- **A test can assert an impossibility and pass.** `mock_provider` evaluates config, not AWS
  semantics, so it cannot know that `HeadObject` is authorised by `s3:GetObject` or that S3 lets a
  delete marker be written over a legal hold. Two Phase 2 tests passed for years' worth of CI
  against invariants AWS does not implement. When an assertion encodes a *behaviour* of a service
  rather than a *shape* of the config, only an acceptance run can confirm it — say so at the
  assertion.
- **Project attribute-by-attribute rather than reading a whole block object.** `one(rule)` on a
  lifecycle rule pulls in its deprecated `prefix` and emits a warning against a perfectly good
  config; `one([for r in ...rule : one(r.expiration).days])` does not.

### Python testing

- **`botocore.Stubber`, never live calls.** It asserts the exact API calls made, which is the same
  discipline `mock_provider` gives the HCL.
- **Do not pass dummy AWS credentials to a stubbed client.** Stubber intercepts at `before-call`,
  which runs ahead of signing, so nothing ever authenticates — and hardcoded keys trip Snyk Code's
  `HardcodedNonCryptoSecret` rule. `boto3.client("s3", region_name="us-east-1")` is enough.
- **Never pass `ANY` as a whole `expected_params` dict.** A mismatch then raises, and a broad
  `pytest.raises(Exception)` swallows it — the test goes green having exercised nothing, with every
  response still queued. Spell the params out and assert the specific exception type.
- **A Lambda handler must not create boto3 clients at import.** Doing so needs a resolvable region,
  so the module imports fine on a developer machine with one configured and fails on every CI
  runner with `NoRegionError` raised during *collection*. `handler.py` resolves clients and config
  on first use, and `test_import_reaches_for_no_aws_configuration` asserts no client exists after
  import.

## Working against a real account

Development does not need a dedicated IR account; nothing in phases 1–4 requires a second one
(spec §5.2.2). Four constraints:

- **Never enable Object Lock compliance mode outside production.** It is the only irreversible
  action in this design — locked objects cannot be deleted before expiry by anyone including root,
  and the bucket cannot be destroyed while they exist, so `tofu destroy` fails against one. Phase 1
  creates no Object Lock buckets, so the risk arrives with Phase 2. Spec §5.2.1 specifies an
  `acknowledge_compliance_mode_is_irreversible` guard variable. **It is implemented** — declared
  in `variables.tf` and enforced by a `lifecycle { precondition }` on *both* Object Lock buckets
  in `evidence.tf`, with `expect_failures` coverage in `tests/evidence.tftest.hcl`.
- Governance mode is destroyable only by a principal holding `s3:BypassGovernanceRetention`, which
  the development role will need from Phase 2 onwards or teardown fails.
- Set `budget_alert_emails` before the first apply. The auto-dormancy nudge is Phase 4, so until
  then the budget alarm is the only signal that the environment was left running.
- Interface endpoints are the largest active cost — larger than the appliance itself before they
  were narrowed to one AZ.

**Local state files contain generated secrets in plaintext.** `envs/example/*/terraform.tfstate`
holds the `random_password` results. They are gitignored; keep it that way, and do not paste their
contents anywhere.

**Development credentials are a long-lived IAM access key with `AdministratorAccess`, not SSO.**
Run `aws sts get-caller-identity` to see what you are. That shape is acceptable for a sandbox and
is explicitly *not* acceptable for the production IR account: D2 and the break-glass property in
§3.5 assume IR access survives compromise of everything else, and a static admin key on a
workstation is the opposite of that.

## Operating from Windows / Git Bash

Every one of these cost real time.

- **`tofu` is only on PATH in login shells.** Prepend the winget package directory in any
  non-login subshell.
- **`MSYS_NO_PATHCONV=1`** is required for any AWS CLI argument that looks like a POSIX path. Git
  Bash rewrites `/ir-dev/images` into a Windows path and SSM returns a parameter-name validation
  error that does not mention path conversion.
- **`PYTHONIOENCODING=utf-8 PYTHONUTF8=1`** avoids `'charmap' codec can't encode` failures when AWS
  CLI output contains non-ASCII.
- Git Bash `/tmp` and Windows Python's `/tmp` are different places. Use the session scratchpad
  directory for intermediate files.
- `grep -P` is available; `grep '\t'` is not interpreted as a tab (use `grep -P '^\t'`).
- **`aws ssm send-command` parameter JSON is painful to escape.** The reliable pattern is to write
  the script locally, base64-encode it, and send one command:
  `echo <b64> | base64 -d > /root/x.sh && bash /root/x.sh`.
- Results come from `aws ssm get-command-invocation` and need roughly 20–25 seconds after sending.

## Repository workflow

- `.gitattributes` forces LF. Shell scripts committed with CRLF fail on Linux runners with
  `bad interpreter`, which would break CI on the first push.
- `.terraform.lock.hcl` is committed deliberately; `.terraform/`, state, and `*.tfvars` are not.
- **Merging a PR with `--delete-branch` closes any stacked PR based on that branch**, and GitHub
  does not auto-retarget it. Retarget the child (`gh pr edit N --base main`) *before* merging the
  parent. Recovering afterwards means pushing the deleted branch back, reopening, retargeting, then
  merging.

## Snyk

Run `snyk_iac_scan` on `modules/platform` **and `modules/analysis`**, and `snyk_code_scan` on
`cli`, `modules/platform/lambda`, `modules/analysis/lambda` and `containers/plaso-worker`, after
touching any of them.

**Nothing above low severity, and 0 Snyk Code findings.** The low count moves whenever a resource
is added — it was 13, then 14 when the Lambda arrived, then 13 again once X-Ray tracing was
enabled — so **re-run the scan rather than trusting a number written here or in a commit
message.**

**Scanning a module directory does not pick up the repository-root `.snyk`**, so
`SNYK-CC-AWS-426` shows as an unignored low against `modules/analysis`. That is the suppression
working, not a regression.

Phase 3 raised two findings and both were real:

- **A medium on the new DynamoDB gateway endpoint** (`SNYK-CC-AWS-428`, no endpoint policy). The
  first draft omitted it, arguing nothing writes evidence to DynamoDB so there was nothing to
  exfiltrate. That misses the direction of the threat — without the account condition a compromised
  worker could reach a table in an *attacker's* account. Fixed, not suppressed.
- **A path traversal in the worker** (`CWE-23`). `os.path.basename("CASE-1/..")` is `".."`, which
  lands a download one level above the scratch directory. `safe_local_path` resolves and bounds it.

X-Ray is enabled on the two pipeline Lambdas for the same reason as the recorder's: a failure that
spans Lambda, Batch and DynamoDB is not diagnosable from one service's log lines. The lows are accepted and **left visible rather than suppressed**, with reasoning
grouped by rule in the headers of `evidence.tf`, `audit.tf` and `storage.tf`. Three are not
weaknesses the scanner can see through:

- **`SNYK-CC-TF-45` (no server access logging) on `evidence` and `plaso`** — S3 *cannot* deliver
  server access logs to an Object Lock bucket at all. That impossibility is why spec §5.1 specifies
  CloudTrail data events, which are built. The selector in `audit.tf` is the authority on what it
  covers — deliberately not the `audit` bucket itself, since a trail whose data events include its
  own destination writes events about writing events. The rule looks for `aws_s3_bucket_logging`,
  so it reports whether or not the control exists.
- **`SNYK-CC-TF-127` (no MFA delete)** — cannot be set by Terraform under any provider version; it
  needs root credentials presenting an MFA token via the CLI. On the locked buckets it is also the
  weaker control: a legal hold cannot be cleared by presenting a TOTP code.
- **`SNYK-CC-TF-124` (versioning disabled) on `intake`** — deliberate. Versioning intake would
  retain a delete marker and a noncurrent version of every artifact the recorder files: billed
  storage, and a second copy of evidence sitting outside the locked bucket.

The two CloudTrail lows (`SNYK-CC-TF-135` not multi-region, `SNYK-CC-TF-256` no CloudWatch
integration) are scope rather than posture — see `audit.tf`.

`.snyk` suppresses only `SNYK-CC-AWS-426` (EC2 termination protection), which would break
`user_data_replace_on_change` and the per-incident resize. Whether the tooling-bucket lows now merit
a scoped ignore is **still an open judgement call**, not a defect — the original objection was that
a blanket ignore would exempt Phase 2's evidence buckets, and those buckets now exist.

**Snyk Code findings are worth fixing rather than ignoring.** The four it raised were dummy AWS
credentials in test fixtures; removing them was a real fix, not a suppression, because `Stubber`
never authenticates.
