# Example deployment

A reference wiring of the three modules against a development account. Copy this directory
rather than editing it in place.

## Layers

Applied in order; each is independent state.

| Layer | Contains | Applied |
|---|---|---|
| `platform/` | VPC, KMS, **EBS data volume**, ECR, IAM, private DNS, budget alarm | Once. Rarely again. |
| `images/` | CodeBuild mirror publishing digest-pinned images to SSM | Once, then whenever upstream versions change |
| `analysis/` | Appliance, VPC endpoints, secrets. Driven by `posture` | Every dormant/active transition |

The split is deliberate. The data volume lives in `platform/`, so `tofu destroy` against
`analysis/` loses no warm data — indices sit on the other side of that boundary.

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

Run `docs/acceptance/phase-1.md` end to end. Infrastructure only touched during incidents is
infrastructure that is broken during incidents.
