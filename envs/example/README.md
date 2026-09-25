# Example deployment

A reference wiring of the three modules against a development account. Copy this directory
rather than editing it in place.

## Layers

Applied in order; each is independent state.

| Layer | Contains | Applied |
|---|---|---|
| `platform/` | VPC, KMS, **EBS data volume**, ECR, IAM, private DNS, budget alarm, the evidence store | Once. Rarely again. |
| `images/` | CodeBuild mirror publishing digest-pinned images to SSM, and building the plaso worker image | Once, then whenever upstream versions or the worker change |
| `analysis/` | Appliance, VPC endpoints, secrets, the plaso Batch fleet and the ingest pipeline. Driven by `posture` | Every dormant/active transition |

The split is deliberate. The data volume lives in `platform/`, so `tofu destroy` against
`analysis/` loses no warm data — indices sit on the other side of that boundary.

**Applying `images/` is not enough — run the mirror before `analysis/`.** `tofu apply` in `images/`
creates the CodeBuild project; the images, and the plaso worker, only exist once a build has run:

```bash
cd images && tofu apply
aws codebuild start-build --project-name "$(tofu output -raw mirror_project_name)"
```

`analysis/` reads every image digest from SSM at plan time and fails naming the missing parameter
if the build has not finished. The same holds after changing the worker: rebuild, **then
re-apply `analysis/`** — the Batch job definition picks up a new digest only when applied.

**Set `pipeline_notification_emails` in `analysis/`.** Pipeline failures publish to an SNS topic;
with the default empty list nobody is subscribed, and a failed artifact goes unnoticed.

## Everyday use

```bash
# Wake the environment for an incident
cd analysis && tofu apply -var='posture=active' -var='responders=["alice","bob"]'

# Reach Timesketch (no public ingress; SSM is the access path)
eval "$(tofu output -raw ssm_port_forward_command)"
# then open http://localhost:5000

# Get a responder's password
aws secretsmanager get-secret-value --secret-id ir-dev/responders/alice \
  --query SecretString --output text

# Stand down
tofu apply -var='posture=dormant'
```

From the repository root, `make active` and `make dormant` do the same thing.

## Sizing

`instance_type` is a **per-incident dial, not a commitment**. The appliance is stopped between
incidents and its data lives on a separate volume, so a large case can run on a bigger instance
and drop back afterwards:

| Instance | vCPU / RAM | OpenSearch heap | Suits |
|---|---|---|---|
| `r6i.large` (default) | 2 / 16 GiB | 8 GiB | 1–3 responders, modest timelines |
| `r6i.xlarge` | 4 / 32 GiB | 16 GiB | 3–6 responders, sustained ingest |
| `r6i.2xlarge` | 8 / 64 GiB | 32 GiB | Large case, multi-TB timelines |

Heap and wsgi worker count are derived automatically from the instance type using Timesketch's
own rules, so changing the type is the only change needed.

## Connecting your own network

This module does not own connectivity. Deploy your connector (ZPA App Connector, Tailscale
subnet router, TGW attachment) into the VPC yourself and authorise it:

```hcl
module "platform" {
  # ...
  allowed_ingress_security_group_ids = [aws_security_group.your_connector.id]
  enable_internet_egress             = true # if your connector dials outbound
}
```

Point your application segment at `timesketch.ir.internal`, not an IP — the name survives
instance replacement.

The network layer is stable across dormancy, so you attach once and it keeps working through
every cycle.

## Cost

Dormant cost is storage-dominated: the EBS data volume plus a few dollars of incidentals. The
appliance is stopped and the interface endpoints are destroyed.

**Set `budget_alert_emails` before your first apply.** The auto-dormancy nudge does not arrive
until Phase 4, so until then the budget alarm is the only thing that tells you the environment
was left running.

## Before touching a real incident

Run **all three** acceptance gates end to end against your own deployment. Infrastructure only
touched during incidents is infrastructure that is broken during incidents — and each gate's first
run against the development account found defects in code that was CI-green (six, three, twelve).

- `docs/acceptance/phase-1.md` — platform, appliance, dormancy cycle.
- `docs/acceptance/phase-2.md` — the evidence store. Cheap, and it does not need the appliance
  running.
- `docs/acceptance/phase-3.md` — the ingest pipeline, upload to timeline. Not cheap: it needs the
  appliance, eleven interface endpoints and real Batch instances. Budget an afternoon.

`../../NEXT.md` is the current state.
