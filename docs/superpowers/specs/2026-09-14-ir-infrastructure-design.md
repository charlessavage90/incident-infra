# Incident Response Infrastructure — Design

**Status:** Approved. Phase 1 built and acceptance-passed; Phase 2 built, acceptance pending;
Phases 3–4 not started. `CLAUDE.md` tracks phase status — this line goes stale, that one does not.
**Amended six times since approval: read §12 before trusting a remembered reading.**
**Date:** 2026-09-14
**Repository:** https://github.com/charlessavage90/incident-infra

---

## 1. Problem

Significant security incidents routinely require log and artifact analysis outside the SIEM,
often a great deal of it. That analysis needs infrastructure — a timeline database, artifact
processing capacity, and durable evidence storage — which is expensive to keep running between
incidents and slow to build under pressure.

This project delivers an OpenTofu module that stands up a complete incident-response analysis
environment in AWS, holds it in a low-cost dormant state between incidents, and returns it to
service in minutes.

The core is [Timesketch](https://github.com/google/timesketch) for collaborative timeline
analysis, fed by [plaso](https://github.com/log2timeline/plaso) (`log2timeline`) for artifact
timelining.

### Success criteria

1. A responder declares an incident and has a queryable timeline the same working day.
2. Dormant cost is storage-dominated and predictable — no idle compute, no idle VPN, no idle
   managed services.
3. An artifact uploaded by a responder reaches Timesketch without manual processing steps.
4. Evidence is immutable, hashed at source, and defensible to a regulator or insurer.
5. Spinning up does not require the corporate identity provider or corporate network to be
   trustworthy or even functional.

---

## 2. Decisions

These were settled during design. Each records the alternative rejected, so a future reader can
tell a deliberate choice from an accident.

| # | Decision | Rejected alternative |
|---|---|---|
| D1 | Built for internal use, with module boundaries clean enough to open-source later | Open-sourcing from day one; org-specific hardcoding |
| D2 | Deployed in a dedicated IR AWS account, isolated from the environment under investigation | Security/logging account; per-incident vended account |
| D3 | Warm dormancy — compute stopped, data hot, spin-up in minutes (measured floor ~6 min, §3.2) | Cold (destroy + re-ingest); frozen (snapshot everything) |
| D4 | Two ingest routes: plaso, or direct Timesketch CSV/JSONL import | Single plaso lane; four-lane classifier |
| D5 | No pre-built normalizers in v1; Timesketch's header-mapping UI is the escape hatch | Shipping Okta/Entra/Workspace mappings; a plugin framework |
| D6 | No public ingress. SSM port-forward is the always-on access floor | Public ALB + Cognito; ALB federated to corporate SSO |
| D7 | The module does not own connectivity. It exposes an attachment surface for org-managed access (ZPA, Tailscale, TGW, Client VPN) | Building Client VPN or Site-to-Site VPN into the module |
| D8 | Default sizing targets 100 GB–1 TB per incident, 3–6 responders | Single-box-fits-all; large-scale-from-day-one |
| D9 | Evidence uses Object Lock in governance mode, held by an S3 **legal hold** until case close (A3); compliance mode available per case | Compliance mode everywhere; no Object Lock |
| D10 | Retention is 3 years, starting when a case closes | 7 years; 1 year; no default |
| D11 | A case is a data concept (sketch + prefix + record), not an infrastructure concept | An OpenTofu stack per case; hybrid per-case analysis stacks |
| D12 | Intake is a responder CLI push to S3 | Presigned URLs for third parties; cross-account pull; web upload |
| D13 | EC2 appliance running a compose stack derived from upstream Timesketch's, plus an elastic plaso fleet. "Unmodified" was never accurate — see A2 for the delta and why each part of it exists | Everything on one box; fully managed services |
| D14 | plaso runs on AWS Batch, EC2 on-demand | Batch on Spot; Fargate tasks with attached EBS |
| D15 | Step Functions orchestrates; dfTimewolf is reserved for the EBS snapshot phase | dfTimewolf as the outer orchestrator |
| D16 | OpenTofu (MPL-2.0) is the IaC tool; HCL is Terraform-compatible | Terraform (BUSL), given D1's intent to open-source |

---

## 3. Architecture

### 3.1 Layering

Two OpenTofu layers with independent state.

**`platform/` — permanent.** Never destroyed in normal operation.

- VPC, subnets, route tables, security groups
- Route 53 private hosted zone
- S3 buckets: `intake`, `evidence`, `plaso`, `audit`
- KMS customer-managed keys
- DynamoDB tables: `cases`, `artifacts`
- ECR repositories
- CloudTrail (management + S3 data events)
- IAM roles and policies
- Budget alarms
- **EBS data volumes** (OpenSearch and PostgreSQL storage)

**`analysis/` — toggleable.** Safe to destroy and rebuild.

- EC2 appliance and its volume attachments
- AWS Batch compute environment, job queue, job definitions
- Step Functions state machine
- Lambda functions
- EventBridge rules
- VPC interface endpoints

**`images/` — independent.** The CodeBuild mirror pipeline and its digest-pinning manifest. It
belongs to neither layer: it runs outside the VPC, is unaffected by dormancy, and is applied on
its own cadence when upstream images are refreshed.

Placing the **EBS data volumes in the permanent layer** is load-bearing. It means a full
`tofu destroy` of `analysis/` loses no warm data — indices and evidence sit on the other
side of the boundary. This yields a colder dormancy tier later at no additional design cost.

### 3.2 Dormancy

Dormancy is a variable, not a destroy:

```hcl
variable "posture" {
  type        = string
  description = "active | dormant"
  validation {
    condition     = contains(["active", "dormant"], var.posture)
    error_message = "posture must be \"active\" or \"dormant\"."
  }
}
```

| Resource | `active` | `dormant` |
|---|---|---|
| EC2 appliance | running | **stopped** via `aws_ec2_instance_state` — not destroyed |
| Batch compute environment | `ENABLED` | `DISABLED` |
| VPC interface endpoints | created | **destroyed** |
| Ingest pipeline trigger (§4.1) | enabled | disabled |
| Intake recording (§5.5) | enabled | **enabled** |
| EBS data volumes, S3, VPC, DNS, DynamoDB | unchanged | unchanged |

`posture` is a variable of the `analysis/` layer. `platform/` has no equivalent and is applied
independently.

**Two triggers, not one (A4).** The *pipeline* trigger — the one that starts Step Functions,
Batch, and a Timesketch import — is posture-gated, because every one of those depends on a
running appliance. The *intake record* — verify, manifest, copy to evidence, apply the hold — is
not, because it depends on nothing dormancy touches, and its failure mode is a silent gap in
the chain of custody. An artifact that arrives while the environment is asleep is still
recorded and still made immutable; it simply is not timelined until the environment wakes.
§5.5 gives the argument in full.

Destroying the VPC interface endpoints when dormant does not strand the environment. Starting
the appliance is an EC2 control-plane call, not an SSM call; activation recreates the endpoints
before any responder connects. Only the interactive path depends on them.

**Reactivation has a measured floor of roughly six minutes**, and the endpoints set it, not the
instance. A recreated interface endpoint reports `available` through the API before its ENI
actually forwards packets; the SSM agent starts inside that window, fails, and would back off
for up to an hour. `ssm-endpoint-wait.service` on the appliance restarts it once the endpoint
answers. Six minutes is inside D3's promise of "minutes", but it is a floor rather than a
target, and it should be stated rather than discovered. Keeping the three SSM endpoints alive
through dormancy would remove the race entirely at roughly $22/month of dormant cost; that
trade has not been taken.

**Invariant — the network layer is stable across dormancy.** Dormant mode never destroys the
VPC, subnets, route tables, security groups, or private DNS. Third-party connectors attach once
and survive every cycle. Without this, every incident would begin by re-onboarding a ZPA
application segment.

### 3.3 Network

Private subnets across two availability zones. **No internet gateway and no NAT gateway by
default.** Egress is via VPC endpoints: S3 as a free gateway endpoint, plus interface endpoints
for SSM, SSM Messages, EC2 Messages, ECR (api and dkr), CloudWatch Logs, Secrets Manager, KMS,
and Step Functions. **Eight of those nine are built**; the Step Functions endpoint arrives with
the Step Functions state machine in phase 3, so a Phase 1 or 2 deployment has eight.

This is a posture decision, not frugality. plaso workers handle live malware. An environment
with no route to the internet cannot be used to exfiltrate evidence or call home.

`enable_internet_egress` adds a NAT gateway for deployments that need it — notably any
org-managed connector that dials outbound to a vendor cloud.

Container images reach ECR without any VPC egress. A **CodeBuild project outside the VPC**
mirrors upstream images into ECR. CodeBuild's managed network has internet access; the IR VPC
never does.

**Attachment surface.** The module exposes, as outputs: VPC ID, private subnet IDs, route table
IDs, the appliance security group ID, and the private DNS name. It accepts, as inputs:
`allowed_ingress_security_group_ids` and `allowed_ingress_cidrs`. An organization authorizes its
own connector on 443 without editing the module.

A stable private DNS record (`timesketch.<private_zone>`) matters because connector application
segments should reference a name that survives instance replacement, not an IP that does not.

**Bridging risk.** Connecting a corporate network to the IR VPC partially undoes D2's isolation.
Where an org does so, the mitigations are structural rather than config discipline: routes and
security groups permitting corp→IR on 443 only, no return route IR→corp, no outbound DNS
resolution, and artifacts continuing to arrive via S3 rather than over the tunnel.

### 3.4 The appliance

A single EC2 instance running upstream Timesketch `docker-compose` unmodified: web, Celery
worker, PostgreSQL, Redis, OpenSearch, nginx.

**Default: `r6i.large`** (2 vCPU, 16 GiB). Because the appliance is stopped between incidents
and its data lives on a separate volume, **instance type is a per-incident dial, not a
commitment.** A large case starts on a larger instance and drops back afterwards; the stop/start
motion is the dormancy motion already in use.

Sizing ladder, to be documented:

| Instance | vCPU / RAM | Suits |
|---|---|---|
| `r6i.large` (default) | 2 / 16 GiB | 1–3 responders, modest timelines |
| `r6i.xlarge` | 4 / 32 GiB | 3–6 responders, sustained ingest |
| `r6i.2xlarge` | 8 / 64 GiB | Large case, multi-TB timelines |

At the default, OpenSearch receives roughly 6–8 GiB of heap. This is adequate for the target
scale and will be the first constraint to bind under heavy bulk indexing; 2 vCPU is thin for
that workload. The resize path is the release valve, and sizing guidance must say so plainly.

A separate encrypted gp3 data volume (default 500 GB) holds OpenSearch and PostgreSQL data.

`timesketch.conf` is templated by OpenTofu; secrets come from Secrets Manager. Responder
accounts are provisioned on activation from a `responders` variable via `tsctl create-user`,
with generated passwords written to Secrets Manager. Adding a responder mid-incident is one
apply.

Named accounts are required rather than shared, because Timesketch attributes every comment,
tag, star, and saved search to a user. A shared login destroys that attribution, which matters
if the investigation is later scrutinized.

`LOCAL_AUTH_ALLOWED_USERS` is retained as a break-glass escape hatch — Timesketch honours local
database accounts even when OIDC is enabled, so a future federated ingress mode cannot lock out
responders.

### 3.5 Access

Two independent layers. They do not integrate, and the design does not pretend otherwise.

| Layer | Mechanism | Provides |
|---|---|---|
| Network | `ssm:StartSession`, IAM-gated | The perimeter. No inbound rules, no public DNS, no certificates. Every session in CloudTrail. |
| Application | Timesketch local accounts | Per-responder attribution within the tool |

Timesketch supports local accounts, `SSO_ENABLED` (trusting a `REMOTE_USER` environment
variable set by a fronting web server), and `GOOGLE_OIDC_*` (generic despite the name). It
supports no AWS IAM integration, no SAML, and no LDAP.

The ingress seam is preserved as a variable with a single implemented value, so adding a
public-ALB mode later is additive rather than a refactor of the networking and web tiers.

---

## 4. The ingest pipeline

### 4.1 Flow

```
irctl upload --case CASE-2026-014 triage.zip
        │  (hashes client-side, at the point of collection)
        ▼
   S3 intake      the PUT carries x-amz-checksum-sha256; S3 verifies it
        │         server-side and rejects a mismatched upload (§4.2)
        │
        ├─s3:ObjectCreated─▶ RecordIntake     manifest entry, written
        │                                         conditionally so a re-upload
        │                                         is a no-op; copy to evidence
        │                                         bucket; legal hold ON (§5.2)
        │
        └───EventBridge───▶ Step Functions
                                   │
                                   ▼
                                 Route            .csv / .jsonl / .json ?
                                   │
                        ┌──────────┴──────────┐
                        ▼                     ▼
                 Batch: plaso          Batch: direct
               log2timeline.py       timesketch importer
                        │                     │
                        ▼                     │
                 .plaso → S3 ─────────────────┤
                                              ▼
                                          Finalize          manifest: event count,
                                              │             timeline + sketch ID
                                              ▼
                                         SNS notify
```

An artifact whose hash fails verification never reaches the bucket at all, so it is never
recorded and never copied to evidence. `RecordIntake` runs regardless of posture; the Step
Functions branch does not (§3.2).

### 4.2 Hashing at source

The CLI computes SHA-256 **before upload**, and the hash is verified on arrival. Hashing
after arrival proves only that S3 did not corrupt the object; hashing at the point of collection
is what is actually defensible. It also provides free deduplication — a triage package uploaded
twice is recognized and not reprocessed.

**Verification happens at PUT, not in a pipeline step (A1).** S3 accepts the client's digest as
`x-amz-checksum-sha256` on `PutObject` and `UploadPart`, verifies it server-side, and rejects
the request on mismatch. That is strictly stronger than re-reading the object afterwards, and
it is why no component in this design ever needs to re-hash evidence — which matters, because a
Lambda cannot stream a 20 GB triage package inside its 15-minute limit. A design that required
it would have been load-bearing on a step that silently does not scale.

Two consequences, because they are easy to get wrong:

- A multipart upload stores a **composite** digest of the form `<hash>-N` — a hash of the
  concatenated part hashes, not of the object. S3 still verifies every part it received, so
  byte integrity is end-to-end either way, but the whole-file SHA-256 must *also* be written to
  object metadata and to the manifest. That is the value custody and deduplication key on.
- Below the multipart threshold the stored checksum *is* the whole-file SHA-256, and S3 will
  return it on request. Only the large-artifact path needs the metadata fallback.

### 4.3 Routing

Routing is a rule, not a classifier:

- `.csv`, `.jsonl`, `.json` → direct Timesketch import
- everything else → plaso
- plaso returns zero events → fall back and flag for a responder

`log2timeline` auto-detects across roughly 200 formats and runs every applicable parser itself.
The pipeline does not second-guess it. Format coverage includes host artifacts (registry, EVTX,
`$MFT`, `$UsnJrnl`, prefetch, LNK, browser history, macOS plists and keychains, Linux syslog and
utmp), server and application logs (Apache, IIS, PostgreSQL, vsftpd, Snort/Suricata, Windows
Firewall, McAfee, Symantec, Sophos), and several cloud JSONL formats (`aws_cloudtrail_log`,
`azure_activity_log`, `gcp_log`, `microsoft_audit_log`).

**What plaso does not have is a generic CSV or JSON parser.** `plaso/parsers/dsv_parser.py` is
an abstract base class whose `COLUMNS` list *"needs to be defined by each DSV parser"*; concrete
parsers such as `SymantecParser` subclass it with their own schema, and a `_MAGIC_TEST_STRING`
sniff test rejects non-conforming files. Arbitrary tabular data therefore takes the direct-import
route.

### 4.4 Normalizer extension paths

Per D5, v1 ships no normalizers. When a source proves it recurs, there are two clean routes:

1. **A Timesketch header mapping** — no code. Timesketch's import UI maps arbitrary columns onto
   the three mandatory fields (`message`, `datetime` in ISO 8601, `timestamp_desc`), can combine
   columns, and can supply defaults.
2. **A plaso DSV parser** — subclass `DSVParser`, declare `COLUMNS`. Upstreamable, and the right
   choice for a stable published format.

Deferring is the correct default because a mapping written against a guessed schema rots
silently when a vendor changes its export.

### 4.5 plaso version parity — a design invariant

> **The plaso that produces a timeline and the plaso that ingests it are the same binary.**

Timesketch rejects `.plaso` files produced by a newer plaso than the one it runs. This has been
observed in a real engagement. The root cause is in the upstream image build:

```dockerfile
FROM ubuntu:26.04
ARG PPA_TRACK=stable
RUN add-apt-repository -y ppa:gift/$PPA_TRACK
RUN apt-get install -y --no-install-recommends plaso-tools
```

`plaso-tools` is installed **unpinned** from the GIFT PPA. Two builds of the same Timesketch
release tag can contain different plaso versions. No amount of version discipline downstream
prevents this.

The fix is structural:

- The Batch worker image is built **`FROM` the Timesketch image itself, pinned by digest, not
  tag.** Same image, two roles: the worker is the Timesketch image with `log2timeline.py` as its
  entrypoint instead of `timesketch-worker`. Skew becomes impossible by construction.
- The ECR mirror pipeline resolves tag→digest **once** and emits a version manifest consumed by
  both the Batch job definition and the appliance's compose file. One source of truth.
- CI asserts version parity, so a drifted build fails in CI rather than three hours into an
  incident.

### 4.6 Compute

plaso runs on **AWS Batch, EC2 on-demand** (D14). Given infrequent incidents, a Spot reclaim
partway through a multi-hour disk image costs more in incident time than the discount saves.
The compute environment sits at zero desired vCPUs when dormant, so this choice does not affect
dormant cost.

### 4.7 Failure handling

Failures land in a DLQ with an SNS notification. The artifact remains in the evidence bucket
regardless of pipeline outcome — a processing failure must never lose the thing a responder was
given.

---

## 5. Evidence and chain of custody

### 5.1 Buckets

| Bucket | Purpose | Protection |
|---|---|---|
| `intake` | Landing zone | CMK-encrypted, unversioned, short expiry lifecycle, TLS-only |
| `evidence` | Raw artifacts as received | Object Lock, versioned, CMK-encrypted |
| `plaso` | Generated `.plaso` timelines | Object Lock — derived evidence is still evidence |
| `audit` | CloudTrail data events | Versioned, CMK-encrypted |

**The Object Lock buckets carry no bucket-level default retention**, and that omission is
deliberate rather than an oversight. A default retention stamps a retain-until date at PUT,
which is exactly the behaviour §5.2 exists to avoid: the clock must start at case close, not at
upload. Retention is applied per object, once, by the case-close operation.

The intake bucket is kept as a quarantine boundary even though S3 now verifies the hash at PUT
(§4.2), because the remaining risk it addresses is a *correctly transferred* artifact filed
against the wrong case. Under governance mode that is recoverable by the break-glass role;
under the per-case compliance mode of §5.2 it is not recoverable by anyone. Somewhere for an
artifact to be wrong before it becomes permanent is worth one server-side copy.

Object Lock buckets cannot receive S3 server access logs, so bucket-level access auditing uses
CloudTrail data events. Those data events cover the tooling bucket of §3.3 as well, which gives
the read-auditing control that its outstanding Snyk `SNYK-CC-TF-45` finding asks for — by a
different mechanism than the one that rule looks for.

### 5.2 Retention model

The retain-until date is not fixed at upload; it is computed when the case closes. This matches
how evidence retention actually works. At ingest you cannot know how long an artifact must be
kept, but you do know the policy: *N years after the case closes* — **3 years** by default (D10,
`retention_years` variable).

**S3 Object Lock has two primitives, not three (A3).** A retention period, and a boolean legal
hold. There is no "event hold" — earlier drafts of this document named one, and no such thing
exists to build against. The event-driven behaviour above is therefore assembled from the two
primitives that do exist:

| When | Action |
|---|---|
| At PUT | Legal hold **ON**. No retain-until date is set. The object cannot be deleted and its clock has not started. |
| At case close | `PutObjectRetention` with `now + retention_years` in the case's mode, **then** release the legal hold. |

The order matters: releasing the hold before setting retention leaves a window in which the
object is deletable by anything holding `s3:DeleteObject`.

**Legal hold is one boolean serving two purposes**, which is the consequence of there being only
one of them. It is the event hold for an open case, and it is also the per-case litigation flag
of D9. Case close releases it *unless* the case record's `legal_hold` attribute is set, in which
case the object keeps the hold indefinitely and retention runs underneath it. The two meanings
are distinguished in the manifest, not in S3 — S3 cannot tell them apart, so the case store is
the only place that can.

A named break-glass role holds `s3:BypassGovernanceRetention` for genuine operator error — for
example, ingesting the wrong client's data. Per-case **compliance mode** is available for matters
flagged as litigation or regulatory, applied per object when retention is set, since bucket
defaults are overridden by explicit per-object retention.

### 5.2.1 Compliance-mode guard

Compliance mode is the only genuinely irreversible action in this module. A compliance-locked
object cannot be deleted before its retain-until date by any principal including the account
root; AWS documents the sole escape as **deleting the AWS account**. An Object Lock bucket also
cannot be emptied or destroyed while locked objects remain, so `tofu destroy` fails against one.

The module therefore refuses compliance mode unless the caller opts in explicitly:

```hcl
variable "object_lock_mode" {
  type        = string
  default     = "GOVERNANCE"
  description = "GOVERNANCE (reversible by a break-glass role) or COMPLIANCE (irreversible)."
}

variable "acknowledge_compliance_mode_is_irreversible" {
  type        = bool
  default     = false
  description = <<-EOT
    Required to be true when object_lock_mode is COMPLIANCE. Compliance-locked objects cannot be
    deleted before expiry by anyone, including the account root, and the bucket cannot be
    destroyed while they exist. Never set this in a development or sandbox account.
  EOT
}
```

A precondition fails the plan when `COMPLIANCE` is requested without the acknowledgement. The
per-case compliance escalation described above is subject to the same guard.

### 5.2.2 Developing against a non-dedicated account

D2 requires a dedicated IR account for *production*. Development does not: nothing in phases 1–4
needs a second account, and the isolation property is a deployment characteristic rather than
module behaviour. A standard or sandbox account is a fine development target, subject to four
constraints.

1. **Never enable compliance mode in a development account.** This is the one mistake with no
   remedy. A test that writes a large artifact under compliance mode with a three-year retention
   commits that storage cost for three years. §5.2.1 exists to make this hard to do by accident.
2. **Governance mode is safely destroyable, but only by a principal holding
   `s3:BypassGovernanceRetention`.** The development role must hold it, or teardown will fail on
   any bucket containing locked objects.
3. **Watch idle cost.** VPC interface endpoints bill hourly whether used or not and are the
   largest avoidable line item in a half-built environment. Set a budget alarm before the first
   apply rather than after the first surprise; the auto-dormancy nudge does not arrive until
   phase 4.
4. **Check Batch service quotas.** On-demand EC2 vCPU limits in an account that has never run
   large instances may be lower than the plaso fleet needs.

Bucket names are globally unique, so a `name_prefix` variable must be applied to every bucket to
avoid collisions between a development and a production deployment.

Cross-account EBS snapshot copy (§10) is the one capability that will eventually require a
second account. It is deferred, and does not gate any earlier phase.

### 5.3 Case store

DynamoDB, always on, negligible cost, unaffected by dormancy.

- **`cases`** — PK `case_id`. Status (open/closed), opened and closed timestamps, sketch ID,
  `retention_years`, `object_lock_mode`, legal hold flag, cost-allocation tag
- **`artifacts`** — PK `case_id`, SK `sha256`. Source, size, timestamps, custody events,
  timeline ID, event count

**The case store exists because evidence objects are immutable.** Everything worth knowing about
an artifact changes after it lands — custody events accumulate, the case opens and closes, the
legal hold flag toggles, retention is set, and phase 3 attaches a timeline ID and an event count.
None of that can be written onto an object that is under a legal hold from the moment it
arrives. The manifest is the mutable half of the evidence store, and it is the half that answers
questions.

Three properties follow from that, and each drives an implementation detail:

- **Deduplication is the manifest write, not a check before it.** The `artifacts` entry is
  written conditionally on `attribute_not_exists(sha256)`, so a re-uploaded triage package is
  recognised by the write failing. This is atomic, which a read-then-write check is not — two
  concurrent intake invocations racing on the same artifact would both pass a prior read.
  Deduplication is scoped **within a case**: the same file arriving on two engagements is two
  custody chains, not one.
- **It must be readable and writable while the environment is dormant**, which disqualifies
  anything hosted on the appliance. A manifest in the appliance's PostgreSQL would be unavailable
  for exactly the period between incidents, which is most of the time.
- **It is the one thing here that cannot be reconstructed.** Evidence can be re-hashed; a custody
  chain cannot be re-derived. Both tables therefore carry point-in-time recovery and deletion
  protection, which at this data volume costs nothing worth counting.

S3 has supported conditional writes since late 2024, so atomic deduplication alone would no
longer require DynamoDB. What S3 still cannot do is answer "every artifact in this case" without
a LIST and a HEAD per object, hold an append-only custody log against an immutable object, or
store case-level state that belongs to no single object. The case for a separate manifest is
narrower than it was; it is not gone.

### 5.4 Case close

A first-class operation, not a label:

1. Set per-object retention to `now + retention_years` across the case prefix
2. Release the legal hold — **in that order** (§5.2), and only if the case's `legal_hold`
   attribute is unset
3. Optionally drop the OpenSearch index
4. Transition `.plaso` files to Glacier
5. Freeze the manifest

### 5.5 Intake recording does not observe posture

The component that records an arriving artifact — read its digest, write the manifest entry,
copy it to the evidence bucket, apply the legal hold — runs whatever the posture. The pipeline
that timelines it does not (§3.2). The split is not symmetry for its own sake; the two have
different dependencies and different failure modes.

The pipeline needs a running appliance, an enabled Batch environment, and interface endpoints,
all of which dormancy removes. Triggering it while dormant would fail, or worse, half-succeed.

Intake recording needs none of those. It touches S3, DynamoDB, and KMS — none of which dormancy
touches. Gating it would buy nothing and cost the property the evidence store exists to provide:
an artifact that arrives between incidents would sit unrecorded and unlocked in a bucket with a
short expiry lifecycle, and the gap would be silent. "The environment was asleep" is not an
answer to "why is this artifact not in the manifest".

Two implementation consequences:

- **It runs outside the VPC.** In-VPC placement would put it behind the interface endpoints that
  dormancy destroys, which would couple chain-of-custody to posture through the back door.
- **No object bytes pass through it.** It needs `HeadObject` for metadata and `CopyObject`, which
  S3 executes server-side; it never needs `GetObject`. That is what makes running it outside the
  VPC a defensible choice rather than a concession — a component that cannot read evidence cannot
  leak it, wherever it runs.

The copy is the one part with a scale limit: it is driven by a function with a 15-minute ceiling,
so a sufficiently large artifact will exceed it. The limit is documented and the failure is loud
rather than silent. Phase 3 moves the copy into Batch, which removes it.

---

## 6. Additional capability

In scope:

- **Exercise mode.** Spin up against synthetic artifacts on a schedule and assert the pipeline
  works end to end. Infrastructure touched only during incidents is infrastructure that is broken
  during incidents.
- **Auto-dormancy nudge and budget alarm.** A scheduled check notifies after `idle_days` rather
  than mutating infrastructure behind OpenTofu's back — auto-apply would cause state drift. This
  guards against a deployment left running for a quarter.
- **Per-case cost attribution.** Cost allocation tags applied at resource creation, plus a
  per-case view. Cheap to build in, awkward to retrofit.
- **Timesketch analyzers and Sigma rules seeded at deploy.** Detection content ready on spin-up
  rather than configured mid-incident.

Explicitly out of scope for v1: presigned upload URLs for third parties, cross-account log pull,
a web upload page, pre-built source normalizers, public ALB ingress, module-owned VPN, and
routing the IR account's own CloudTrail into a sketch.

---

## 7. Repository layout

```
incident-infra/
  modules/platform/         VPC, buckets, KMS, ECR, DNS, DynamoDB, IAM, CloudTrail
  modules/analysis/         appliance, Batch, Step Functions, Lambdas, posture toggle
  modules/images/           CodeBuild mirror pipeline, digest pinning
  envs/example/             reference deployment
  containers/plaso-worker/  FROM timesketch@<digest>, log2timeline entrypoint
  cli/                      irctl: upload, case open/close, posture
  docs/
```

---

## 8. Testing

- `tofu validate`, `tflint`, `checkov`, and Snyk IaC in CI
- Native `tofu test` for module contracts
- **CI assertion of plaso version parity** between the worker image and the appliance image
- End-to-end acceptance test, which is the test that matters:

  > apply → upload a known EVTX with a known event count → assert the timeline appears in
  > Timesketch with that count → toggle dormant → toggle active → assert it is still there

---

## 9. Phasing

| Phase | Delivers | Done when |
|---|---|---|
| 1 | Platform layer, appliance, dormancy toggle | Timesketch reachable over SSM; dormant/active cycle preserves data |
| 2 | Evidence store: buckets, Object Lock, hashing, manifest, manual ingest | An artifact can be ingested by hand, is hashed, immutable, and recorded |
| 3 | Pipeline: Batch worker, Step Functions, routing | Upload triggers timeline creation with no manual step |
| 4 | Lifecycle: case close, legal hold, archival, exercise mode, auto-dormancy nudge, cost attribution | Case close releases holds and starts retention; scheduled exercise passes |

Evidence precedes the pipeline deliberately: integrity guarantees should exist before anything
automated begins writing into the store. The trade is a later first end-to-end demo, accepted
because the environment will not be used on a real incident until phase 3 completes.

**"Manual ingest" in phase 2 means the upload is manual, not the recording.** A responder runs
`irctl upload` by hand; verification, the manifest entry, the copy to evidence and the legal hold
are automatic from the moment the object lands (§5.5). What stays manual until phase 3 is
everything downstream of the evidence bucket — running `log2timeline`, importing the result. The
line is drawn there so that phase 3 wraps the intake recorder in Step Functions rather than
replacing it, and so that no artifact is ever knowingly left unrecorded.

---

## 10. Deferred — EBS snapshot ingest

Most disk images in practice arrive as **EBS volume snapshots**, not files a responder uploads.
A later phase should automate that path rather than route terabytes through a laptop.

Existing tooling covers this and should not be reimplemented:

- **libcloudforensics** (`cloud-forensics-utils`) performs cross-account EBS volume copy,
  including **encrypted volumes via temporary customer-managed keys** — the genuinely fiddly part.

  ```
  cloudforensics aws us-east-1 copydisk --volume_id=vol-x \
      --src_profile=compromised --dst_profile=ir
  ```

- **dfTimewolf** wraps it in an `aws_forensics` recipe: *"Copies a volume from an AWS account,
  creates an analysis VM in AWS ... and attaches the copied volume to it."* Its
  `aws_snapshot_s3_copy` module reconstructs a snapshot into S3 as an image file.

The `aws_snapshot_s3_copy` route is preferred, because it **collapses the EBS path into the S3
path already built** — a snapshot becomes an object and the existing pipeline takes it from
there. One pipeline, not two.

Forensic constraint for this phase: plaso reads the raw device through dfVFS, so the filesystem
is never mounted. No OS mount, no timestamp mutation.

dfTimewolf is the wrong **outer** orchestrator — it is a synchronous CLI runner without retry,
checkpoint, or fan-out semantics — which is why Step Functions holds that role (D15). Its value
is the AWS collection code, in this phase.

---

## 11. Open questions

1. **Region strategy.** Single region assumed, set by variable. Deployments with data-residency
   obligations may need artifacts pinned to a region, which affects bucket and KMS design.
2. **OpenSearch heap tuning** at `r6i.large`. The 6–8 GiB figure needs measuring against a real
   timeline rather than assuming.
3. **Cost model — partly answered (A5).** The phase 1 acceptance run measured the development
   deployment rather than the 500 GB assumption this document was drafted against:

   | | Estimated here originally | Measured at phase 1 acceptance |
   |---|---|---|
   | Dormant | ~$45/month (assuming 500 GB warm EBS) | **~$15/month** at the 100 GB development volume size |
   | Active | not broken out | **interface endpoints ~$58/month dominate**, ahead of the `r6i.large` appliance at ~$92/month running continuously |
   | A full acceptance cycle | not estimated | **about $1** |

   Dormant cost is close to linear in volume size, so the original figure was not wrong so much
   as quoted at a different volume. The correction that matters is the second row: **interface
   endpoints, not compute, are the active-cost line to watch**, which is why they are pinned to
   a single AZ and destroyed when dormant. What remains genuinely open is active cost under a
   real case, where the plaso fleet and a resized appliance dominate and nothing has been
   measured.

---

## 12. Amendments

This document is the source of truth, so corrections are made in place rather than in a parallel
errata file. Each is logged here with what changed and why, so that a reader who remembers an
earlier reading can tell what moved.

| # | Amendment | Origin |
|---|---|---|
| A1 | Hash verification moved from a pipeline step to the PUT itself, using S3's `x-amz-checksum-sha256`. No component re-hashes evidence — the original `VerifyHash` step could not have scaled past what a 15-minute function can stream (§4.1, §4.2) | Phase 2 design |
| A2 | D13's "upstream `docker-compose` unmodified" is wrong twice over. The **binary** is mirrored and checksum-verified, because AL2023 packages no compose plugin and the VPC has no internet. The **file** is derived, not upstream's: no `nginx` (§3.5 binds the web container to loopback and reaches it over SSM), no profiled services, image references substituted to digests (§4.5), volume paths pointed at the data volume, and — unintentionally — upstream's healthchecks and `depends_on: condition: service_healthy` dropped for plain list-form `depends_on` (D13, §3.3, §3.4) | Phase 1 acceptance; corrected while closing the compose-pin question |
| A3 | S3 Object Lock has no "event hold" primitive. Earlier drafts named one. The behaviour is assembled from a legal hold at PUT plus retention set at case close, in that order (D9, §5.2, §5.4) | Phase 2 design |
| A4 | Dormancy gates the *pipeline* trigger, not *intake recording*. The original single "Intake EventBridge rule" row conflated two triggers with different dependencies, and disabling both would have left artifacts arriving between incidents silently unrecorded (§3.2, §5.5) | Phase 2 design |
| A5 | Cost model replaced with measured figures. Dormant ~$15/month at 100 GB; interface endpoints, not the appliance, dominate active cost (§11) | Phase 1 acceptance |
| A6 | Reactivation has a measured floor of roughly six minutes, set by interface endpoint ENI readiness rather than by the instance. Still "minutes" as D3 promises, but stated rather than discovered (D3, §3.2) | Phase 1 acceptance |
