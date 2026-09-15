# NEXT.md

Hand-off for the next session. Durable project facts live in `CLAUDE.md`; this file is what is
*outstanding*, and it should shrink as items close.

**Last updated:** 2026-09-14, Phase 2 built and awaiting its acceptance run.

---

## State right now

Phase 1 is built and acceptance-passed against a real AWS account. **Phase 2 is built and
CI-green, but has never been applied** — every test is offline. Phases 3–4 are specified in the
design but not started.

PRs #1 (design + plan), #2 (Phase 1 implementation) and #3 (six acceptance defects) are merged.
Phase 2 is PR #4 on `feat/phase-2-evidence-store`.

**The live development environment is DORMANT.** It costs roughly $15/month in that state and
nothing needs doing to it. What persists:

- VPC, subnets, route tables, security groups, private hosted zone (`ir.internal`)
- The 100 GB EBS data volume, still attached to the stopped instance, holding a sketch named
  `acceptance-check` and a Timesketch user `alice`
- Five ECR repositories with digest-pinned images, and the tooling bucket holding Docker Compose
- KMS key, IAM role and instance profile, budget alarm (`ir-dev-monthly`, $200)

What is destroyed while dormant: the eight VPC interface endpoints. The appliance is *stopped*,
not terminated.

To wake it: `cd envs/example/analysis && tofu apply -var='posture=active' -var='responders=["alice"]'`.
Expect **roughly six minutes** before SSM is reachable — see the known limitation below.

Deployment identifiers are not recorded here on purpose (this repo is intended for open-sourcing
under D1). Discover them with `tofu output` in `envs/example/platform` or
`aws sts get-caller-identity`.

---

## Immediate items

**1. Run the Phase 2 acceptance gate.** `docs/acceptance/phase-2.md`, 16 checks. This is the
item that matters: the module has 46 platform tests and 19 Python tests, and **not one of them
has spoken to AWS.** Phase 1's equivalent run surfaced six defects against a codebase that also
looked finished.

Costs a few cents and does not need the appliance — leave the environment dormant. Requires
`tofu init` first, because the `archive` provider is new in this phase.

The checks most likely to fail, and worth reading the reasoning for before running:

- **6 and 7 together.** The object must be under a legal hold *and* have no retain-until date.
  Either alone passes a weaker reading of §5.2 while getting the retention model wrong.
- **12.** S3 must reject a mismatched `x-amz-checksum-sha256` at PUT. The whole of A1 rests on
  this actually happening rather than being assumed.
- **15 and 16.** These exercise primitives Phase 2 does not build, so that Phase 4's case close
  does not meet them cold. 16 also proves teardown is possible at all.

**2. DEFECT — our compose file dropped upstream's healthcheck gating.** Found while settling the
compose pin; not fixed, because it is in `analysis/` and Phase 2 was scoped to touch nothing there.

At the pinned `20260630` tag, upstream gives `opensearch`, `postgres` and `redis` healthchecks and
has `timesketch-web` and `timesketch-worker` wait on `depends_on: condition: service_healthy`.
`modules/analysis/templates/docker-compose.yml.tftpl` uses plain list-form `depends_on`, so
Timesketch starts when those containers *start*, not when they are *ready*. OpenSearch takes tens
of seconds to become ready; `restart: always` retries until it works, which is why Phase 1
acceptance passed and why this is noisy rather than fatal.

It is plausibly a contributor to the reactivation floor below, though the endpoint ENI race is the
measured cause and this has not been separated from it.

*Success condition:* the three backing services carry upstream's healthchecks, web and worker gate
on `service_healthy`, and one activation shows no restart-loop entries for either container in
`docker compose logs`. Needs a real activation to verify, which costs money and wakes the
environment — hence the owner's call on when, not whether.

---

## Known limitation, not a defect

**Reactivation takes about six minutes, not seconds.** Dormancy destroys the interface endpoints,
and a recreated endpoint reports `available` via the API well before its ENI actually forwards
packets. The SSM agent starts inside that window, fails, and would hibernate for up to an hour;
`ssm-endpoint-wait.service` catches that and restarts it once the endpoint responds.

Two ways to do better, if it ever matters:

- Keep only the three SSM endpoints alive during dormancy and destroy the other five. Removes the
  race entirely, at roughly $22/month of dormant cost.
- Accept it. Six minutes is well inside the design's promise.

This was verified across three full dormancy cycles; the sketch and user survived every one, and
the `mkfs` guard never fired.

---

## Phase 2 — evidence store (built, not yet accepted)

Spec §9. Four buckets, two manifest tables, the intake recorder, `irctl`, the compliance-mode
guard and CloudTrail data events are all implemented on PR #4. What remains is the acceptance
run above.

**Settled during Phase 2 design** (all now in the spec, see §12):

- Everything lands in `modules/platform/`. Nothing in Phase 2 touches `analysis/`, so the posture
  toggle is unaffected.
- `irctl` is **Python + boto3**, tested offline with `botocore.Stubber` — the same no-credentials,
  no-cost discipline as `mock_provider`. Adds a second CI job.
- The **intake bucket stays** as a quarantine boundary. S3's PUT-time checksum makes it redundant
  for transfer corruption, but not for an artifact filed against the wrong case, which per-case
  compliance mode would make permanent.
- **Manual means the upload is manual.** Verify, manifest, copy and hold are automatic from the
  moment the object lands; Phase 3 wraps that recorder in Step Functions rather than replacing it.

**Found while building it, worth not rediscovering:**

- **`scripts/sync-test-mocks.py` regenerates the `mock_provider` preamble** in every platform
  test file from one canonical block. Adding the Lambda broke seven runs in files I had not
  touched, because only the new test file mocked `aws_iam_role` and the provider validates role
  ARNs. The error names the ARN, never the missing mock. Edit the script, not one file.
- **`mock_resource` defaults apply to every instance of a type**, so all four buckets share one
  ARN under test. Any assertion of the form "this policy does not mention the evidence bucket"
  passes vacuously. Assert on actions, which are literal config.
- **`expect_failures` must list every resource that trips a shared precondition.** Both evidence
  buckets carry the compliance guard; listing one passed while leaving the other reachable.

**Still true and carried forward:**

- **The S3 endpoint policy lesson applies to Phase 3, not Phase 2.** Nothing built in Phase 2 reaches
  the evidence buckets through the VPC endpoint — `irctl` runs on a responder's machine and the
  recorder runs outside the VPC. The Batch workers of Phase 3 are the first thing that will, and any
  access path that is anonymous or presigned by AWS does **not** carry `aws:PrincipalAccount`. The
  existing condition denies it with a 403 that names nothing useful. This already broke `dnf` and
  would have broken `docker pull`.
- **The development role needs `s3:BypassGovernanceRetention`** or `tofu destroy` will fail against
  any bucket holding locked objects. `AdministratorAccess` covers it, but a scoped role would not.
  The teardown procedure is written out at the end of `docs/acceptance/phase-2.md`, including the
  part that is not obvious: a **legal hold is not cleared by the retention bypass** and must be
  turned off separately.
- **Retention is a legal hold at PUT, then `PutObjectRetention` at case close — in that order.**
  The clock starts at closure, not at upload. Object Lock has no "event hold" primitive; earlier
  drafts said it did (A3). Default three years (D10). Phase 4 builds `irctl case close`; acceptance
  checks 15 and 16 prove the primitives first.
- **`SNYK-CC-TF-45` and `SNYK-CC-TF-127` now report on four buckets rather than one.** CloudTrail
  data events are the real compensating control and are built; the rule looks for
  `aws_s3_bucket_logging`, so it reports regardless, and MFA delete cannot be set from Terraform at
  all. Full reasoning is in the headers of `evidence.tf` and `audit.tf`. Whether a scoped ignore is
  now defensible is still open — it is a judgement call, not a defect.

---

## Phase 3 — ingest pipeline

Batch worker, Step Functions, routing. The most useful thing already established:

- **Build the plaso worker image `FROM` the Timesketch image, pinned by digest.** The Timesketch
  release image already installs `plaso-tools`, so it contains `log2timeline.py` at exactly the
  version Timesketch will read back. Same image, two roles — the worker is that image with a
  different entrypoint. This makes the §4.5 version-parity invariant structural rather than a matter
  of discipline, and it is the phase where the **CI parity assertion** finally has two things to
  compare.
- The tooling-mirror path built in Phase 1 (CodeBuild → S3 → checksum-verified install) is the
  pattern for anything else the worker needs that AL2023 does not package.
- **Routing is a rule, not a classifier**: `.csv`/`.jsonl`/`.json` go to direct Timesketch import,
  everything else to `log2timeline`, and zero events falls back to flagging for a responder.
- **Revisit D14** (Batch on EC2 on-demand). It was chosen partly on the belief that Fargate's
  200 GiB ephemeral cap ruled it out; Fargate can now attach EBS volumes at task launch and reaches
  32 vCPU / 244 GB. The on-demand-versus-Spot reasoning still stands on its own.
- **Revisit the single-AZ endpoint placement** if the Batch fleet spans availability zones. It is
  currently pinned to the appliance's subnet, which is correct only while compute is single-AZ.

---

## Phase 4 and deferred work

- **Phase 4**: case close, legal hold, archival, exercise mode, auto-dormancy nudge, per-case cost
  attribution. Exercise mode matters more than it looks — infrastructure only touched during
  incidents is infrastructure that is broken during incidents.
- **EBS snapshot ingest** (spec §10) is deferred with the prior art identified. Most disk images
  arrive as EBS snapshots rather than uploaded files. **libcloudforensics** handles cross-account
  volume copy including encrypted volumes via temporary CMKs — genuinely fiddly code nobody should
  rewrite. dfTimewolf wraps it in an `aws_forensics` recipe and its `aws_snapshot_s3_copy` module
  reconstructs a snapshot into S3, which **collapses that path into the S3 pipeline** rather than
  adding a second one. dfTimewolf is the wrong *outer* orchestrator (synchronous CLI, no retry or
  fan-out), which is why Step Functions holds that role (D15).
- **Normalizers stay deferred** (D5) until a source proves it recurs. Two clean routes exist then:
  a Timesketch header mapping (no code) or a plaso `DSVParser` subclass (upstreamable).
- **Open questions from spec §11 still open**: region strategy for data residency, and OpenSearch
  heap tuning at `r6i.large` measured against a real timeline rather than assumed.

---

## Production readiness, when it stops being a sandbox

- **The dedicated IR account must not use the current credential shape.** Development runs on a
  long-lived IAM access key with `AdministratorAccess` belonging to an unrelated project. D2 and the
  break-glass property in §3.5 assume IR access survives compromise of everything else; a static
  admin key on a workstation is exactly the dependency the design exists to remove.
- **The public-ALB ingress seam is designed but unbuilt.** Spec §3.5 keeps ingress as a variable
  with one implemented value so adding it is additive. If it is ever built, the open question is
  whether Cognito can drive `GOOGLE_OIDC_*` directly or whether an nginx shim mapping
  `x-amzn-oidc-identity` to `REMOTE_USER` is needed — that was never settled and deserves a spike.
- **Exercise mode should exist before the first real incident**, not after.
