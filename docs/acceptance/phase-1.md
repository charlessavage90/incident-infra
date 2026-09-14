# Phase 1 Acceptance

Phase 1 is done when this runs green end to end. Spec §9: *"Timesketch reachable over SSM;
dormant/active cycle preserves data."*

> **This creates real AWS resources and costs real money.** Run step 8 when finished. If you are
> stepping away for more than a day, destroy the analysis layer — the platform layer is cheap
> (an EBS volume and an idle VPC) and holds the data.

> **Never set `object_lock_mode = "COMPLIANCE"` in a development account.** It is the only
> irreversible action in this system. Phase 1 creates no Object Lock buckets, so the risk
> arrives with Phase 2 — but the habit starts here. See spec §5.2.1.

## Result of the first run (2026-09-14)

**PASSED**, after six defects that only real hardware exposed. All are fixed and each has a
regression test. Recorded here because the failure modes are the useful part.

| # | Defect | Fix |
|---|---|---|
| 1 | S3 gateway endpoint policy returned **403** for Amazon Linux repos and would have done the same for ECR image layers. Repos are fetched anonymously and ECR layers via AWS-presigned URLs, so neither carries this account's principal and the `aws:PrincipalAccount` condition denied both. | Second policy statement allowing AWS-owned service buckets, read-only |
| 2 | Instance booted before the VPC endpoints existed; cloud-init failed and never re-runs | `depends_on` on the instance, plus retries around package install |
| 3 | **AL2023 ships no Docker Compose package** and this VPC has no internet, so `docker compose up` could never work | Mirror the binary through CodeBuild into S3, checksum-verified both ends |
| 4 | Docker Hub anonymous **pull rate limit** broke the mirror on re-run; ECR immutable tags meant a re-run was not idempotent either | Source from ECR Public; skip images already mirrored |
| 5 | `timesketch-web` crash-looped: gunicorn opens `/var/log/timesketch/wsgi_error.log` at startup and exits if the directory is missing | Mount the logs directory upstream expects |
| 6 | The SSM agent lost a race against endpoint readiness on **every reactivation** and logged *"entering hibernation"*, backing off for up to an hour. Terraform ordering does not fix it: the endpoint reports `available` before its ENI forwards packets | A systemd unit that waits for reachability and restarts the agent, since cloud-init does not re-run on stop/start |

Also fixed: generated responder passwords were being echoed into
`/var/log/cloud-init-output.log` in plaintext by `set -x`.

Measured on the third cycle: **SSM reachable ~6 minutes after reactivation**, sketch and user
data intact.

## Note for Windows operators

Git Bash rewrites `/ir-dev/images` into a Windows path, so SSM parameter commands below fail with
a validation error. Prefix them with `MSYS_NO_PATHCONV=1`, or run them from PowerShell.

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
