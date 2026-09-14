# Incident Response Infrastructure — Design

**Status:** Approved design, pending implementation plan
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
| D3 | Warm dormancy — compute stopped, data hot, spin-up in minutes | Cold (destroy + re-ingest); frozen (snapshot everything) |
| D4 | Two ingest routes: plaso, or direct Timesketch CSV/JSONL import | Single plaso lane; four-lane classifier |
| D5 | No pre-built normalizers in v1; Timesketch's header-mapping UI is the escape hatch | Shipping Okta/Entra/Workspace mappings; a plugin framework |
| D6 | No public ingress. SSM port-forward is the always-on access floor | Public ALB + Cognito; ALB federated to corporate SSO |
| D7 | The module does not own connectivity. It exposes an attachment surface for org-managed access (ZPA, Tailscale, TGW, Client VPN) | Building Client VPN or Site-to-Site VPN into the module |
| D8 | Default sizing targets 100 GB–1 TB per incident, 3–6 responders | Single-box-fits-all; large-scale-from-day-one |
| D9 | Evidence uses Object Lock in governance mode under an event hold; compliance mode available per case | Compliance mode everywhere; no Object Lock |
| D10 | Retention is 3 years, starting when a case closes | 7 years; 1 year; no default |
| D11 | A case is a data concept (sketch + prefix + record), not an infrastructure concept | An OpenTofu stack per case; hybrid per-case analysis stacks |
| D12 | Intake is a responder CLI push to S3 | Presigned URLs for third parties; cross-account pull; web upload |
| D13 | EC2 appliance running upstream `docker-compose`, plus an elastic plaso fleet | Everything on one box; fully managed services |
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
| Intake EventBridge rule | enabled | disabled |
| EBS data volumes, S3, VPC, DNS, DynamoDB | unchanged | unchanged |

`posture` is a variable of the `analysis/` layer. `platform/` has no equivalent and is applied
independently.

Destroying the VPC interface endpoints when dormant does not strand the environment. Starting
the appliance is an EC2 control-plane call, not an SSM call; activation recreates the endpoints
before any responder connects. Only the interactive path depends on them.

**Invariant — the network layer is stable across dormancy.** Dormant mode never destroys the
VPC, subnets, route tables, security groups, or private DNS. Third-party connectors attach once
and survive every cycle. Without this, every incident would begin by re-onboarding a ZPA
application segment.

### 3.3 Network

Private subnets across two availability zones. **No internet gateway and no NAT gateway by
default.** Egress is via VPC endpoints: S3 as a free gateway endpoint, plus interface endpoints
for SSM, SSM Messages, EC2 Messages, ECR (api and dkr), CloudWatch Logs, Secrets Manager, KMS,
and Step Functions.

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
   S3 intake ──EventBridge──▶ Step Functions
                                   │
                                   ▼
                              VerifyHash          recompute SHA-256,
                                   │              compare to source hash
                                   ▼
                             RecordIntake         DynamoDB manifest entry,
                                   │              copy to evidence bucket,
                                   ▼              Object Lock event hold ON
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

The three steps before `Route` are sequential, not parallel: an artifact whose hash fails
verification is never recorded or copied to evidence.

### 4.2 Hashing at source

The CLI computes SHA-256 **before upload**, and the pipeline verifies it on arrival. Hashing
after arrival proves only that S3 did not corrupt the object; hashing at the point of collection
is what is actually defensible. It also provides free deduplication — a triage package uploaded
twice is recognized and not reprocessed.

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
| `intake` | Landing zone | Short lifecycle; objects move out after processing |
| `evidence` | Raw artifacts as received | Object Lock, versioned, CMK-encrypted |
| `plaso` | Generated `.plaso` timelines | Object Lock — derived evidence is still evidence |
| `audit` | CloudTrail data events | Versioned, CMK-encrypted |

Object Lock buckets cannot receive S3 server access logs, so bucket-level access auditing uses
CloudTrail data events.

### 5.2 Retention model

Artifacts are written under **governance mode with an event hold**. The retain-until date is not
fixed at upload; it is computed when the hold is **released**.

This matches how evidence retention actually works. At ingest you cannot know how long an
artifact must be kept, but you do know the policy: *N years after the case closes.* Closing a
case releases the event hold and starts a **3-year** clock (D10, `retention_years` variable).

A named break-glass role holds `s3:BypassGovernanceRetention` for genuine operator error — for
example, ingesting the wrong client's data. Per-case **compliance mode** is available for matters
flagged as litigation or regulatory, applied per object at PUT, since bucket defaults are
overridden by explicit per-object retention.

**Legal hold** is a per-case flag driving `PutObjectLegalHold` across the case prefix. It is
independent of retention and persists until explicitly removed.

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

- **`cases`** — case ID, status (open/closed), sketch ID, retention policy, legal hold flag,
  compliance-mode flag, cost-allocation tag
- **`artifacts`** — SHA-256, source, size, timestamps, custody events, timeline ID, event count

### 5.4 Case close

A first-class operation, not a label:

1. Release the Object Lock event hold, starting the retention clock
2. Optionally drop the OpenSearch index
3. Transition `.plaso` files to Glacier
4. Freeze the manifest

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
3. **Cost model.** Dormant cost is estimated at roughly $45/month plus S3, assuming ~500 GB of
   warm EBS and interface endpoints toggled off. This needs building properly rather than left
   as an estimate.
