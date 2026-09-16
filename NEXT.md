# NEXT.md

Hand-off for the next session. Durable project facts live in `CLAUDE.md`; this file is what is
*outstanding*, and it should shrink as items close.

**Last updated:** 2026-09-15, after the Phase 2 acceptance run.

---

## State right now

Phases 1 and 2 are built and acceptance-passed against a real AWS account. Phases 3–4 are
specified in the design but not started.

PRs #1–#5 are all merged and their branches deleted. **`main` matches what is deployed**: PR #5
carried the three defects the Phase 2 acceptance run found, each with a regression test, and those
fixes were already applied to the development account because the run could not continue without
them. There is no open branch and nothing is waiting on the previous session.

**The live development environment is DORMANT and Phase 2 now exists in it.** The appliance was
never woken for this run — none of the 16 checks needed it. What persists:

- VPC, subnets, route tables, security groups, private hosted zone (`ir.internal`)
- The 100 GB EBS data volume, still attached to the stopped instance, holding a sketch named
  `acceptance-check` and a Timesketch user `alice`
- Five ECR repositories with digest-pinned images, and the tooling bucket holding Docker Compose
- KMS key, IAM role and instance profile, budget alarm (`ir-dev-monthly`, $200)
- **New:** four evidence-store buckets, two manifest tables, the intake recorder and its log group,
  and the CloudTrail data-event trail

What is destroyed while dormant: the eight VPC interface endpoints. The appliance is *stopped*,
not terminated. **Nothing in Phase 2 is posture-gated**, so the toggle does not touch any of it.

**The evidence store is empty and the manifest holds no rows.** The acceptance artifacts were
removed at the end of the run, including the `CASE-TEST-001` case row, so nothing in the account
is a leftover pretending to be real. The audit bucket keeps its CloudTrail logs, which is the
point of it.

Cost is effectively unchanged. Phase 2 adds four near-empty buckets, two `PAY_PER_REQUEST` tables
and a data-event trail — all usage-billed and negligible at rest. The dormant figure is still
roughly $15/month, dominated by the data volume.

To wake it: `cd envs/example/analysis && tofu apply -var='posture=active' -var='responders=["alice"]'`.
Expect **roughly six minutes** before SSM is reachable — see the known limitation below.

Deployment identifiers are not recorded here on purpose (this repo is intended for open-sourcing
under D1). Discover them with `tofu output` in `envs/example/platform` or
`aws sts get-caller-identity`.

---

## Immediate items

**DEFECT — our compose file dropped upstream's healthcheck gating.** Unchanged from the last
hand-off, and now the only open defect. It is in `modules/analysis`, which both Phase 2 and its
acceptance run were scoped to leave alone.

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

**Read the compose-pin trap in `CLAUDE.md` before touching that file.** Re-syncing toward upstream
is safe; bumping the Compose pin is safe; doing both is not, and neither looks dangerous alone.

---

## Known limitations, not defects

**The reactivation floor** (roughly six minutes, set by interface endpoint ENI readiness) is
described in full in spec §3.2 and recorded as amendment A6. Not restated here — it is a measured
fact, not an open item.

The open *decision* it leaves behind: keeping only the three SSM endpoints alive through dormancy
would remove the race entirely, at roughly $22/month of dormant cost. **That trade has not been
taken and nobody has argued for it.** Six minutes is inside D3's promise, so this is a
cost-versus-convenience call rather than a defect.

Verified across three full dormancy cycles during Phase 1 acceptance; the sketch and user survived
every one, and the `mkfs` guard never fired.

---

## What the Phase 2 acceptance run established

The defect table and the reasoning live in `docs/acceptance/phase-2.md`; the durable facts are in
`CLAUDE.md` and in spec §12 as amendments A7 and A8. What belongs *here* is the part that should
change how the next phase is approached:

**All three defects were authorisation failures, and `mock_provider` could not have caught any of
them.** Two were IAM grants whose behaviour depends on how AWS maps an API call to an action —
`HeadObject` is authorised by `s3:GetObject`, which is why the recorder 403'd on its first real
invocation. The third was an S3 semantic no plan can model: Object Lock protects a version, not a
name, so a delete marker can be written over a legal hold.

**Two tests asserted invariants AWS does not implement, and passed.** They are now rewritten to
assert what is actually true and actually load-bearing. Expect the same class of error in Phase 3,
where the Batch workers' access paths are new and the S3 endpoint policy condition is waiting.

**What the previous hand-off expected to break did not.** The recorder's cross-bucket `s3.copy`
worked first time, the CloudTrail trail created cleanly, and the `case-id`/`case_id` metadata
mismatch it flagged as unverified did not exist. The failures were all one layer below where they
were predicted.

---

## Phase 2 — still open

- **Whether the tooling-bucket Snyk lows now merit a scoped `.snyk` ignore.** The original
  objection was that a blanket ignore would exempt Phase 2's evidence buckets; those buckets now
  exist and carry a real compensating control (CloudTrail data events, verified delivering during
  acceptance). Genuinely a judgement call, not a defect. Currently all 13 lows are left visible
  with reasoning in the file headers. The count did not move when the two new bucket policies
  landed — **re-run the scan rather than trusting that number.**
- **`irctl` has no `posture` subcommand**, which spec §7 promises alongside `upload` and
  `case open/close`. `scripts/check.sh dormant|active` covers it today. Decide whether §7's CLI
  surface is still the intent before Phase 4 builds `case close` and the question resurfaces.
- **CloudTrail is not wired to CloudWatch Logs** (`SNYK-CC-TF-256`). Alarms on evidence access are
  worth having, but alerting is Phase 4 work (spec §6). Fold it into Phase 4's auto-dormancy nudge
  rather than doing it standalone.

### Deliberately not built, so nobody goes looking

- **No `irctl case close`.** Phase 4 per §9. Acceptance checks 15 and 16 exercised its S3
  primitives by hand and both behaved as §5.2 assumes, so that phase does not meet them cold.
- **The recorder's copy has a 900-second ceiling**, being Lambda-driven. It fails loudly and the
  object stays in intake. Phase 3 moves the copy into Batch, which removes it.
- **A sub-second window exists between the copy and the legal hold.** Deliberate — the reasoning is
  in `_copy_and_hold`. Closing it would mean betting the hold on `CopyObject`'s allowed-argument
  list, which the managed copy needed above 5 GB does not obviously honour.

### Carried into Phase 3

- **The S3 endpoint policy lesson applies to Phase 3, not Phase 2.** Nothing built in Phase 2
  reaches the evidence buckets through the VPC endpoint — `irctl` runs on a responder's machine and
  the recorder runs outside the VPC. The Batch workers are the first thing that will, and any
  access path that is anonymous or presigned by AWS does **not** carry `aws:PrincipalAccount`. The
  existing condition denies it with a 403 that names nothing useful. This already broke `dnf` and
  would have broken `docker pull`.
- **The development role needs `s3:BypassGovernanceRetention`** or `tofu destroy` fails against any
  bucket holding locked objects. `AdministratorAccess` covers it; a scoped role would not. Teardown
  is written out at the end of `docs/acceptance/phase-2.md`, including the part that is not obvious
  and is now confirmed rather than assumed: **a legal hold is not cleared by the retention bypass**
  and must be turned off separately.
- **Break-glass deletion must target a version.** The new bucket policy denies keyed
  `s3:DeleteObject` outright, so any teardown or cleanup script that omits `--version-id` will now
  fail with an explicit deny rather than quietly writing a delete marker. The teardown script in
  the acceptance doc already does this correctly.

---

## Phase 3 — ingest pipeline

Batch worker, Step Functions, routing. The most useful things already established:

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
- **The worker will need `s3:GetObject` on the evidence bucket**, which is the first component in
  the design that legitimately does. It is worth stating the boundary explicitly when that lands:
  the recorder's asymmetry (§5.5, amendment A7) is a property of the *recorder*, not a property of
  the bucket, and nothing enforces it for a second reader.

**Do the Phase 3 acceptance run before Phase 4.** Two for two now: every acceptance run against
this design has found defects in code that was reviewed, CI-green and looked finished.

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
- **Compliance mode has still never been exercised**, by design — §5.2.1's guard variable is
  implemented and tested, and the development account deliberately runs GOVERNANCE. The first
  production deployment will be the first time that path runs, and it is irreversible. Worth a
  deliberate dry run in a throwaway account before it is used in anger.
