# NEXT.md

Hand-off for the next session. Durable project facts live in `CLAUDE.md`; this file is what is
*outstanding*, and it should shrink as items close.

**Last updated:** 2026-09-28, after the check 10 re-run on `charlessavage90/feat-phase-4-lifecycle` (PR #8).

---

## State right now

Phases 1, 2 and 3 are built and have had their acceptance runs against a real AWS account.
**Phase 3 passed 14 of 15 checks.** Check 10 fails on its premise (finding 13, below), deferred
with a success condition. The run found **twelve defects**, all fixed on the Phase 3 branch with
regression tests where the property is checkable offline; `docs/acceptance/phase-3.md` has the
results table and the defect table. Phase 4 is specified but not started.

**Phase 3 is merged to `main`** (PR #7), including all twelve acceptance fixes and this hand-off.
The follow-up branch `charlessavage90/feat-phase-4-lifecycle` carries the A15 worker fix and
`irctl artifact redrive`. PR #6's stale branch `docs/next-after-merge` has been deleted.

**Local-only state on the owner's machine:** `.claude/settings.local.json` (gitignored) allows
`tofu -chdir=envs/example/{platform,images,analysis} apply` and denies `tofu destroy`, added so an
acceptance run could apply reviewed plans. Keep or remove it deliberately.

**The development environment is DORMANT** and now holds Phases 1–3: everything Phase 2 had, plus
the worker ECR repository, the DynamoDB gateway endpoint, the Batch fleet (compute environment
`DISABLED`, queue `ENABLED`), the Step Functions pipeline, both triggers (`DISABLED`), and an
appliance replaced several times during the run on the same data volume.

**Test data left in place, on purpose until the owner decides:**

- Cases `CASE-TEST-003` to `CASE-TEST-006` in the cases table, and eight manifest rows across
  them (`CASE-TEST-006` is the 2026-09-28 check 10 re-run: a random blob and `sample.evtx`).
- Their evidence objects, **all under legal hold in GOVERNANCE mode**, including a 5.5 GiB
  zero-filled `CASE-TEST-005/large.bin` from check 9 — the one worth removing, as the only material
  storage cost. The matching `.plaso` files are in the plaso bucket (no hold).
- Timesketch sketches `CASE-TEST-003` to `CASE-TEST-006` and `acceptance-probe`
  (a scratch sketch from diagnosing defect 9), alongside Phase 1's `acceptance-check`.
- Teardown follows `docs/acceptance/phase-3.md`: release each legal hold, then delete **by version**.

Deployment identifiers are not recorded here on purpose (this repo is intended for open-sourcing
under D1). Discover them with `tofu output` in `envs/example/platform` or
`aws sts get-caller-identity`.

---

## Open items, in dependency order

1. ~~Finding 13~~ — **closed.** A15 deployed; check 10 re-run passed on 2026-09-28 after it found
   defects 13 (Timesketch fails a zero-event `.plaso` import) and 14 (`.pytest_cache` shipped in
   every Lambda zip). Both fixed, deployed, and verified live. Environment returned to dormant.
2. ~~Re-drive path for `failed` rows~~ — **closed**: `irctl artifact redrive`, used for real in
   the re-run (it re-drove the blob, and refused an already-timelined row).
3. **Pipeline notifications: subscribed, awaiting API confirmation.** `pipeline_notification_emails`
   is set on the apply command line (there is no tfvars). The first subscription was confirmed and
   then unsubscribed within seconds by something following the email's unauthenticated
   unsubscribe link; it has been recreated. *Success condition:* confirmed via `aws sns
   confirm-subscription ... --authenticate-on-unsubscribe true` using the token from the email
   (procedure in `CLAUDE.md`), and `list-subscriptions-by-topic` shows an ARN, not `Pending`.
4. **Tear down the test data** above, or decide to keep it. At minimum the 5.5 GiB object.
5. **`irctl` has no `posture` subcommand**, which spec §7 promises. Decide whether §7's CLI
   surface is still the intent before Phase 4 builds `case close`.
6. **Whether the tooling-bucket Snyk lows merit a scoped `.snyk` ignore.** Unchanged judgement
   call. Scans at the end of this run: platform 13 lows, analysis and images 0 at medium or above,
   Snyk Code 0 — but re-run rather than trust these.
7. **CloudTrail → CloudWatch Logs** (`SNYK-CC-TF-256`). Fold into Phase 4's alerting.
8. **Phase 4** — case close, legal hold, archival, exercise mode, auto-dormancy nudge, per-case cost
   attribution.

**One verification gap from the run, still open.** The 2026-09-28 cycle did not replace the
appliance, so it could not test this. Defect 4's fix (retrying cloud-init's endpoint calls) was
re-verified only on its provisioning half. The race it fixes needs interface endpoints and a
replacement appliance created in the same apply, which no later apply reproduced. The next
dormant→active cycle that also replaces the appliance is the test; read
`/var/log/cloud-init-output.log` for `attempt N of 10` lines.

---

## Deferred in Phase 3, deliberately, so nobody goes looking

- **No legal hold on derived `.plaso` files.** A `.plaso` is reproducible from the evidence object,
  which *is* held, so holding derived artifacts adds a teardown step for no integrity gain and
  pre-empts Phase 4, where retention and holds are set coherently at case close (§5.4). The plaso
  bucket keeps Object Lock enabled so Phase 4 can. *Success condition:* Phase 4's `case close` sets
  retention on the `.plaso` prefix at the same time as the evidence prefix, or a written argument
  records why it should not.
- **The reconciler scans the manifest** rather than using a GSI on `status`. Correct at one row per
  artifact per case; revisit past roughly 100k rows.
- **No SQS dead-letter queue**, despite §4.7's wording. The artifact stays in the evidence bucket
  regardless of outcome and the manifest row is the durable record; a queue holding a copy of the
  same information would be a component to maintain with no consumer.
- **Single-AZ interface endpoints, revisited and kept.** The Batch fleet is pinned to the
  appliance's subnet, so compute is still single-AZ and the original argument holds unchanged.
  Spanning the fleet across AZs without spanning the endpoints would strand workers in an AZ with
  no ENI to reach ECR through.

---

## Known limitations, not defects

**The reactivation floor** (roughly six minutes, set by interface endpoint ENI readiness) is
described in spec §3.2 and recorded as amendment A6.

The open *decision* it leaves behind: keeping only the three SSM endpoints alive through dormancy
would remove the race entirely, at roughly $22/month of dormant cost. **That trade has not been
taken and nobody has argued for it.** Six minutes is inside D3's promise, so this is a
cost-versus-convenience call rather than a defect.

Phase 3 adds three more interface endpoints while active (`ecs`, `ecs-agent`, `ecs-telemetry`),
taking eight to eleven — roughly $22/month more, and only while active.

---

## What Phase 3's design settled

Four things the spec left open are now argued in
`docs/superpowers/plans/2026-09-16-phase-3-ingest-pipeline.md` and recorded as amendments A9–A12.
Two are worth knowing before reading anything that predates them:

- **A10 withdraws a promise §5.5 made.** Phase 3 was supposed to move the intake copy into Batch.
  It does not, because Batch is posture-gated and that would have made *recording* posture-gated —
  the exact silent gap §5.5 exists to prevent. A remembered reading of §5.5 is wrong on this point.
- **A9 replaces D14's reasoning without changing its conclusion.** Batch on EC2 still, but because
  plaso is disk-bound and wants instance-store NVMe, not because of Fargate's old ephemeral cap.

---

## Production readiness, when it stops being a sandbox

- **The dedicated IR account must not use the current credential shape.** Development runs on a
  long-lived IAM access key with `AdministratorAccess` belonging to an unrelated project. D2 and
  the break-glass property in §3.5 assume IR access survives compromise of everything else; a
  static admin key on a workstation is exactly the dependency the design exists to remove.
- **The public-ALB ingress seam is designed but unbuilt.** Spec §3.5 keeps ingress as a variable
  with one implemented value so adding it is additive. The open question is whether Cognito can
  drive `GOOGLE_OIDC_*` directly or whether an nginx shim mapping `x-amzn-oidc-identity` to
  `REMOTE_USER` is needed — never settled, deserves a spike.
- **Exercise mode should exist before the first real incident**, not after.
- **Compliance mode has still never been exercised**, by design — §5.2.1's guard variable is
  implemented and tested, and the development account deliberately runs GOVERNANCE. The first
  production deployment will be the first time that path runs, and it is irreversible. Worth a
  deliberate dry run in a throwaway account before it is used in anger.
- **EBS snapshot ingest** (spec §10) stays deferred with the prior art identified:
  **libcloudforensics** for cross-account volume copy including encrypted volumes, and
  dfTimewolf's `aws_snapshot_s3_copy` to reconstruct a snapshot into S3, which collapses that path
  into the S3 pipeline rather than adding a second one. dfTimewolf is the wrong *outer*
  orchestrator (synchronous CLI, no retry or fan-out), which is why Step Functions holds that role
  (D15).
- **Normalizers stay deferred** (D5) until a source proves it recurs. Two clean routes exist then:
  a Timesketch header mapping (no code) or a plaso `DSVParser` subclass (upstreamable).
- **Open questions from spec §11 still open**: region strategy for data residency, and OpenSearch
  heap tuning at `r6i.large` measured against a real timeline rather than assumed.
