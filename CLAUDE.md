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
  across each module's test files. Keep them in sync.
- Mocks must supply anything the provider *validates* and anything returned as a *list*. Known
  necessities: `aws_availability_zones.names` (empty otherwise), and ARNs for `aws_kms_key`,
  `aws_ecr_repository`, `aws_iam_role`; plus `aws_subnet.availability_zone`, `aws_ami.id`,
  `aws_ssm_parameter.value`, `aws_caller_identity.account_id`, `aws_region.region`.
- `lifecycle` is a meta-argument and **cannot be read in an assertion**. Assert the property it
  protects instead.
- `expect_failures` accepts a variable (`[var.posture]`) for validation blocks and a resource
  (`[aws_instance.appliance]`) for preconditions.
- Assertions should name the consequence, not the rule. The failure message is what a future reader
  gets at 2am.

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

Two low findings on the tooling bucket (`SNYK-CC-TF-127` MFA delete, `SNYK-CC-TF-45` access logging)
are **deliberately left visible** rather than suppressed — a scoped ignore could not be made to
match, and a blanket one would silently exempt Phase 2's evidence buckets where both genuinely
matter. The reasoning is in `modules/platform/storage.tf`. `.snyk` suppresses only
`SNYK-CC-AWS-426` (EC2 termination protection), which would break `user_data_replace_on_change` and
the per-incident resize.
