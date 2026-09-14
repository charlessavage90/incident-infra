# Phase 1 Acceptance

Phase 1 is done when this runs green end to end. Spec §9: *"Timesketch reachable over SSM;
dormant/active cycle preserves data."*

> **This creates real AWS resources and costs real money.** Run step 8 when finished. If you are
> stepping away for more than a day, destroy the analysis layer — the platform layer is cheap
> (an EBS volume and an idle VPC) and holds the data.

> **Never set `object_lock_mode = "COMPLIANCE"` in a development account.** It is the only
> irreversible action in this system. Phase 1 creates no Object Lock buckets, so the risk
> arrives with Phase 2 — but the habit starts here. See spec §5.2.1.

## Prerequisites

- OpenTofu 1.12.6 (`tofu version`)
- AWS credentials for a **development or sandbox** account, not corporate production
- The dev role needs `s3:BypassGovernanceRetention` from Phase 2 onwards, or teardown will fail
- An email address for budget alerts

## 1. Apply the platform layer

```bash
cd envs/example/platform
tofu init
tofu apply -var='budget_alert_emails=["you@example.com"]'
```

**Confirm the budget alarm exists before continuing.** Idle cost is the failure mode it guards,
and the auto-dormancy nudge does not arrive until Phase 4.

```bash
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'Budgets[?BudgetName==`ir-dev-monthly`].[BudgetName,BudgetLimit.Amount]' --output table
```

## 2. Mirror the images

```bash
cd ../images
tofu init && tofu apply
aws codebuild start-build --project-name "$(tofu output -raw mirror_project_name)"
```

Wait for `SUCCEEDED`, then verify every digest landed:

```bash
aws ssm get-parameters-by-path --path /ir-dev/images \
  --query 'Parameters[].[Name,Value]' --output table
```

Expected: five parameters, each value ending in `@sha256:...`.

**A tag reference here is a defect.** Spec §4.5 requires digests: Timesketch installs
`plaso-tools` unpinned from `ppa:gift`, so the same release tag can carry different plaso
versions between builds, and Timesketch rejects `.plaso` files produced by a newer plaso than
it runs.

## 3. Activate

```bash
cd ../analysis
tofu init
tofu apply -var='posture=active' -var='responders=["alice"]'
```

## 4. Reach Timesketch

```bash
eval "$(tofu output -raw ssm_port_forward_command)"
```

In another shell, get the login:

```bash
aws secretsmanager get-secret-value --secret-id ir-dev/responders/alice \
  --query SecretString --output text
```

Open <http://localhost:5000> and log in as `alice`.

**Checkpoint:** the Timesketch UI loads and accepts the login.

If it does not, check cloud-init first:

```bash
aws ssm start-session --target "$(tofu output -raw appliance_instance_id)"
sudo tail -100 /var/log/cloud-init-output.log
sudo docker compose -f /opt/timesketch/docker-compose.yml ps
```

The usual first-run failure is OpenSearch exiting on `max_map_count`. That is guarded in
cloud-init; if you see it, the guard has regressed.

## 5. Create state worth preserving

In the Timesketch UI, create a sketch named `acceptance-check`.

## 6. Go dormant

```bash
tofu apply -var='posture=dormant'
```

Verify all three properties:

```bash
# Instance stopped, NOT terminated
aws ec2 describe-instances --filters "Name=tag:Name,Values=ir-dev-appliance" \
  --query 'Reservations[].Instances[].State.Name' --output text
# Expected: stopped

# Interface endpoints gone (this is the dormant cost saving)
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$(cd ../platform && tofu output -json platform | jq -r .vpc_id)" \
  --query 'VpcEndpoints[?VpcEndpointType==`Interface`].ServiceName' --output text
# Expected: empty

# Data volume still attached to the stopped instance, NOT deleted
aws ec2 describe-volumes \
  --volume-ids "$(cd ../platform && tofu output -json platform | jq -r .data_volume_id)" \
  --query 'Volumes[].State' --output text
# Expected: in-use
```

## 7. Reactivate and confirm the data survived

```bash
tofu apply -var='posture=active' -var='responders=["alice"]'
```

Re-run the port-forward from step 4, log in, and confirm the `acceptance-check` sketch is still
there.

**This is the test that matters.** If the sketch survived, the dormancy design works.

If the sketch is gone and Timesketch looks freshly installed, the `blkid` guard in
`modules/analysis/templates/cloud-init.sh.tftpl` has failed and the volume was reformatted.
That is the single highest-risk defect in Phase 1: cloud-init runs on every boot, so an
unguarded `mkfs` destroys all evidence on the second activation.

## 8. Clean up

```bash
tofu apply -var='posture=dormant'
```

Leaving the platform layer applied is fine and cheap. To tear down completely, note that the
data volume has `prevent_destroy = true` and must be released deliberately — that guard is
there on purpose.

---

## Result

| Step | Pass | Notes |
|---|---|---|
| 1 Platform applies, budget alarm exists | | |
| 2 Five digests in SSM, all `@sha256:` | | |
| 3 Analysis applies | | |
| 4 Timesketch reachable over SSM, login works | | |
| 6 Stopped, endpoints gone, volume `in-use` | | |
| 7 Sketch survived the cycle | | |
