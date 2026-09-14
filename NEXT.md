# NEXT.md

Hand-off for the next session. Durable project facts live in `CLAUDE.md`; this file is what is
*outstanding*, and it should shrink as items close.

**Last updated:** 2026-09-14, at the end of Phase 1 acceptance.

---

## State right now

Phase 1 is built and acceptance-passed against a real AWS account. Phases 2–4 are specified in the
design but not started.

**Open PR: #3** — "Fix six defects found by Phase 1 acceptance against real AWS". CI green.
Contains the six acceptance fixes plus `CLAUDE.md`/`NEXT.md`. PRs #1 (design + plan) and #2
(Phase 1 implementation) are merged.

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

**1. Merge PR #3.** Owner's call; CI is green.

**2. Reconcile the spec with what acceptance proved.** Three statements in
`docs/superpowers/specs/2026-09-14-ir-infrastructure-design.md` are now known to be wrong or
imprecise, and a future reader will trust them:

- **§11 cost model** says "roughly $45/month plus S3" dormant, assuming 500 GB of warm EBS. Measured
  at the development volume size (100 GB) it is closer to **$15/month**. Active cost is dominated by
  interface endpoints (~$58/month after the single-AZ change), not the `r6i.large` appliance (~$92).
  A full acceptance run cost about a dollar.
- **D13 says "upstream `docker-compose` unmodified"**, which is still true of the compose *file* but
  now carries a dependency the decision did not anticipate: the compose *binary* must be mirrored,
  because AL2023 packages none and the VPC has no internet. Worth recording as an amendment rather
  than silently diverging.
- **§3.3 / D3 promise "spin-up in minutes"** without qualification. There is a measured floor of
  about six minutes on reactivation, set by how long a recreated interface endpoint takes to pass
  traffic. That is still "minutes", but it should be stated rather than discovered.

**3. `docker-compose` is pinned to `v5.5.1` on no evidence.** It was simply the latest release on
the day, and it demonstrably works. Nobody has checked it against what Timesketch's compose file
actually requires. Cheap to verify, and the kind of thing that silently breaks on a later bump.

**4. PostgreSQL runs `13-alpine`, not the `13.0-alpine` in Timesketch's `config.env`.** Deliberate:
the exact 2020 patch release is not on a non-rate-limited registry, and the §4.5 parity invariant
concerns the *Timesketch* image, not this one. Note that the **already-mirrored image in ECR is
still the original `13.0-alpine`**, because the mirror is idempotent and skipped it. A fresh
deployment will get `13-alpine`; this one has not been re-pulled. Harmless, but do not be confused
by the mismatch.

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

## Phase 2 — evidence store

Next phase per spec §9. Delivers S3 buckets, Object Lock, hashing, the case manifest, and manual
ingest. Done when an artifact can be ingested by hand and is hashed, immutable, and recorded.

Carry these forward:

- **The S3 endpoint policy lesson applies directly.** Evidence buckets will be reached by more than
  the instance role. Any access path that is anonymous or presigned by AWS does **not** carry
  `aws:PrincipalAccount`, and the existing condition will deny it with a 403 that names nothing
  useful. This already broke `dnf` and would have broken `docker pull`.
- **Implement `acknowledge_compliance_mode_is_irreversible`** (spec §5.2.1). It is specified and
  not built. Compliance mode is the only irreversible action in the system, and Phase 2 is where it
  first becomes reachable.
- **The development role needs `s3:BypassGovernanceRetention`** or `tofu destroy` will fail against
  any bucket holding locked objects. `AdministratorAccess` covers it, but a scoped role would not.
- **Retention uses variable retention with an event hold** so the clock starts at case closure, not
  at upload. Default three years (D10).
- **Object Lock buckets cannot receive S3 server access logs** — use CloudTrail data events. This
  also resolves the `SNYK-CC-TF-45` finding currently left visible on the tooling bucket; revisit
  both Snyk lows once a proper log-target bucket exists.
- Hashing happens **client-side before upload** and is verified on arrival, which also gives free
  deduplication (spec §4.2).

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
