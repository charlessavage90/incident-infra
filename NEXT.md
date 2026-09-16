# NEXT.md

Hand-off for the next session. Durable project facts live in `CLAUDE.md`; this file is what is
*outstanding*, and it should shrink as items close.

**Last updated:** 2026-09-16, after Phase 3 was built.

---

## State right now

Phases 1 and 2 are built and acceptance-passed against a real AWS account. **Phase 3 is built and
has not been run against one.** Phase 4 is specified but not started.

**Two open PRs, both waiting on the owner.** `gh pr list` is the authority; at the time of writing:

- **#6** — a docs-only NEXT.md update from the last session. Note the seam it contains: it says
  "there is no open branch", which was true when written and false the moment it became a PR. This
  file supersedes it, so merging or closing it are both reasonable.
- **#7** — Phase 3, a draft. It branches off `origin/main`, so it does not conflict with #6.
  **Leave it a draft until the acceptance run.** §9's gate is "upload triggers timeline creation
  with no manual step", and only a real apply shows that.

**The live development environment is still DORMANT and still holds Phase 1 and 2 only.** Nothing
in this session was applied. What persists is unchanged from the last hand-off:

- VPC, subnets, route tables, security groups, private hosted zone (`ir.internal`)
- The 100 GB EBS data volume, holding a sketch named `acceptance-check` and a Timesketch user
  `alice`
- Five ECR repositories with digest-pinned images, and the tooling bucket holding Docker Compose
- KMS key, IAM role and instance profile, budget alarm (`ir-dev-monthly`, $200)
- The four evidence-store buckets, both manifest tables, the intake recorder, CloudTrail

**The evidence store is empty and the manifest holds no rows.** Cost is still roughly $15/month
dormant, dominated by the data volume.

Deployment identifiers are not recorded here on purpose (this repo is intended for open-sourcing
under D1). Discover them with `tofu output` in `envs/example/platform` or
`aws sts get-caller-identity`.

---

## The one thing that matters next

**Run the Phase 3 acceptance gate: `docs/acceptance/phase-3.md`.** It is written, with fifteen
checks and a defect table waiting to be filled in.

Unlike Phase 2's, this run is **not cheap and not short**. It needs the appliance awake, eleven
interface endpoints, and a Batch fleet launching real `i4i`/`c6id` instances. Budget an afternoon
and expect to pay for it. Set `posture=dormant` again at the end even if it is abandoned midway.

The order matters and is easy to get wrong: **the image mirror must run before the analysis layer
applies**, because the Batch job definition reads `/<prefix>/images/plaso-worker` and a missing
parameter fails the apply naming the path.

**Expect defects. Two runs for two.** Phase 1 found six, Phase 2 found three, and all three of
Phase 2's were authorisation failures `mock_provider` cannot see. The four most likely here are
listed at the top of the acceptance doc; the common thread is that three of them **fail silently**
rather than loudly — missing ECS endpoints and a non-multipart launch template both leave jobs in
`RUNNABLE` with nothing anywhere saying why.

Two checks in that document are worth calling out because they close items rather than just
verifying them:

- **Check 5** is the success condition this file has carried since Phase 1 acceptance: the compose
  healthcheck defect. The fix is in (upstream's healthchecks verbatim, `service_healthy` gating on
  both web and worker, Compose pin untouched); only an activation can confirm the restart loop is
  gone.
- **Check 9** measures the recorder's copy ceiling instead of assuming it. Write the figure into
  `CLAUDE.md` afterwards — amendment A10 turned that from a number into a measurement.

---

## Open items, in dependency order

1. **Phase 3 acceptance** — above. Everything else waits on it.
2. **Whether the tooling-bucket Snyk lows merit a scoped `.snyk` ignore.** Unchanged judgement
   call. Phase 3 adds a good deal of new infrastructure, so **re-run the scan rather than trusting
   any count written down** — including the "13 lows" this file used to quote. `snyk_iac_scan` now
   needs running on `modules/analysis` too, which has never been scanned and now carries IAM, a
   launch template and a state machine. `snyk_code_scan` covers `cli`,
   `modules/platform/lambda`, `modules/analysis/lambda` and `containers/plaso-worker`.
3. **`irctl` has no `posture` subcommand**, which spec §7 promises alongside `upload` and
   `case open/close`. `scripts/check.sh dormant|active` covers it today. Decide whether §7's CLI
   surface is still the intent before Phase 4 builds `case close` and the question resurfaces.
4. **CloudTrail is not wired to CloudWatch Logs** (`SNYK-CC-TF-256`). Fold into Phase 4's alerting
   rather than doing it standalone.
5. **Phase 4** — case close, legal hold, archival, exercise mode, auto-dormancy nudge, per-case
   cost attribution.

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
