# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An OpenTofu module that stands up an incident-response analysis environment in a dedicated AWS
account, holds it dormant between incidents at storage-only cost, and returns it to service in
minutes. Timesketch is the timeline database; plaso does artifact timelining.

**The design is the source of truth, and it records rejected alternatives.** Read it before
changing anything structural:

- `docs/superpowers/specs/2026-09-14-ir-infrastructure-design.md` — 16 numbered decisions (D1–D16),
  each with what was rejected and why
- `docs/superpowers/plans/2026-09-14-phase-1-platform-and-appliance.md` — Phase 1 implementation
- `docs/acceptance/phase-1.md` — the acceptance gate, plus a table of the six defects the first
  real run exposed

Phase 1 (platform, appliance, dormancy) is complete and acceptance-passed. Phases 2–4 (evidence
store, ingest pipeline, lifecycle) are specified but not built.

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

**Running one test file:**

```bash
cd modules/platform && tofu test -filter='tests\network.tftest.hcl'   # Windows
cd modules/platform && tofu test -filter=tests/network.tftest.hcl      # Linux/macOS
```

`-filter` needs the **OS-native path separator**. A filter that matches nothing reports
`Success! 0 passed, 0 failed` — it does not error. Always check the count, or you will believe
tests ran when none did.

**Tests never touch AWS.** Every test uses `mock_provider`, so `tofu test` needs no credentials,
no network, and costs nothing. 52 run blocks: platform 19, images 7, analysis 26.

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
| `modules/platform/` | **Permanent** | VPC, KMS, ECR, IAM, private DNS, budget alarm, tooling bucket, **and the EBS data volume** |
| `modules/analysis/` | **Toggleable** | Appliance, VPC interface endpoints, secrets — driven by `var.posture` |
| `modules/images/` | Independent | CodeBuild mirror; runs outside the VPC, unaffected by dormancy |

**The EBS data volume lives in `platform/`, not `analysis/`.** That is load-bearing: `tofu destroy`
against `analysis/` loses no warm data, because indices and evidence sit on the other side of the
boundary. Do not move it.

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

**The mirror must stay idempotent.** Tags are immutable, so re-pushing fails; the buildspec skips
images already present. Sources are ECR Public, not Docker Hub, which rate-limits anonymous pulls
per IP and broke the mirror in practice.

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

## Testing conventions

- **Use `jsonencode`, not `aws_iam_policy_document`.** The data source's rendered `.json` is a
  computed attribute that `mock_provider` replaces with an invented string — which both fails
  provider validation at plan time and makes any assertion about policy content a test of the mock
  rather than of the module.
- Mocks must supply anything the provider validates (ARNs especially) and anything returned as a
  list (`aws_availability_zones.names` comes back empty otherwise).
- OpenTofu 1.12 has **no** `source` argument on `mock_provider`, so the mock block is duplicated
  across each module's test files. Keep them in sync.
- Assertions should name the consequence, not the rule. The failure message is what a future
  reader gets at 2am.

## Working against a real account

Development does not need a dedicated IR account; nothing in phases 1–4 requires a second one
(spec §5.2.2). Four constraints:

- **Never enable Object Lock compliance mode outside production.** It is the only irreversible
  action in this design — locked objects cannot be deleted before expiry by anyone including root,
  and the bucket cannot be destroyed while they exist, so `tofu destroy` fails against one. Phase 1
  creates no Object Lock buckets, so the risk arrives with Phase 2. Spec §5.2.1 specifies an
  `acknowledge_compliance_mode_is_irreversible` guard variable; **it is not implemented yet** and
  must be built with those buckets.
- Governance mode is destroyable only by a principal holding `s3:BypassGovernanceRetention`, which
  the development role will need from Phase 2 onwards or teardown fails.
- Set `budget_alert_emails` before the first apply. The auto-dormancy nudge is Phase 4, so until
  then the budget alarm is the only signal that the environment was left running.
- Interface endpoints bill per ENI *per AZ* and are the largest active cost. They are deliberately
  placed in one AZ only, matching the appliance.

**Local state files contain generated secrets in plaintext.** `envs/example/*/terraform.tfstate`
holds the `random_password` results. They are gitignored; keep it that way, and do not paste their
contents anywhere.

## Snyk

Two low findings on the tooling bucket (`SNYK-CC-TF-127` MFA delete, `SNYK-CC-TF-45` access logging)
are **deliberately left visible** rather than suppressed — a scoped ignore could not be made to
match, and a blanket one would silently exempt Phase 2's evidence buckets where both genuinely
matter. The reasoning is in `modules/platform/storage.tf`. `.snyk` suppresses only
`SNYK-CC-AWS-426` (EC2 termination protection), which would break `user_data_replace_on_change` and
the per-incident resize.
