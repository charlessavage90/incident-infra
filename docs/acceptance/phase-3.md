# Phase 3 acceptance

Spec §9: *"Upload triggers timeline creation with no manual step."*

Written **before** the run. The defect table at the bottom is filled in after it, the way
`phase-1.md` and `phase-2.md` were.

**This run is not cheap and it is not short.** Unlike Phase 2 it needs the appliance awake, eleven
interface endpoints, and a Batch fleet that launches real instances. Budget an afternoon and
expect to pay for it. Set `posture=dormant` again at the end even if the run is abandoned midway.

**Two acceptance runs for two: every one so far has found defects in code that was reviewed,
CI-green and looked finished.** Phase 1 found six, Phase 2 found three, and all three of Phase 2's
were authorisation failures `mock_provider` cannot see. The candidates here, in the order they are
most likely to bite:

- **`events:PutRule` for `batch:submitJob.sync`.** Step Functions implements the `.sync` wait with
  a managed EventBridge rule. If the grant is wrong the execution fails at the first Batch state
  with an error naming EventBridge, not Batch.
- **The ECS agent endpoints.** Without `ecs`, `ecs-agent` and `ecs-telemetry` the instances launch,
  look healthy, never join the cluster, and jobs sit in `RUNNABLE` with nothing anywhere saying so.
  The symptom is silence, not an error.
- **MIME multipart in the launch template.** Same symptom, different cause: Batch appends its
  `ECS_CLUSTER` config and can only do so to an archive.
- **The S3 gateway endpoint policy.** The worker is the first component to reach the evidence
  bucket *through* it. Its `aws:PrincipalAccount` condition should be satisfied by an in-account
  job role, but that has never been exercised from inside this VPC, and the failure is a 403 that
  names nothing useful.

## Setup

```bash
cd envs/example/platform
tofu init    # the DynamoDB gateway endpoint and the worker repository are new
tofu apply

export AWS_REGION=us-east-1
export IR_INTAKE_BUCKET=$(tofu output -raw intake_bucket)
export IR_CASES_TABLE=$(tofu output -raw cases_table)
export IR_RETENTION_YEARS=$(tofu output -raw retention_years)
EVIDENCE=$(tofu output -raw evidence_bucket)
PLASO=$(tofu output -raw plaso_bucket)
ARTIFACTS=$(tofu output -raw artifacts_table)
```

The mirror must run **before** the analysis layer applies — the Batch job definition reads
`/<prefix>/images/plaso-worker`, and a missing parameter fails the apply naming the path:

```bash
cd ../images
tofu apply
aws codebuild start-build --project-name "$(tofu output -raw mirror_project_name)"
# wait for it, then confirm the worker digest exists
MSYS_NO_PATHCONV=1 aws ssm get-parameter --name "/ir-dev/images/plaso-worker" \
  --query 'Parameter.Value' --output text
```

Then wake the environment. **Expect roughly six minutes before SSM is reachable** (spec §3.2, A6):

```bash
cd ../analysis
tofu apply -var='posture=active' -var='responders=["alice"]'
```

Test artifacts — a real EVTX with a known event count is worth finding, because check 6 compares
against it:

```bash
head -c 1000000 /dev/urandom > sample.bin          # routes to plaso, finds nothing
printf 'message,datetime,timestamp_desc\nhello,2026-01-01T00:00:00,Test\n' > sample.csv
```

## Checks

| # | Check | How | Pass |
|---|---|---|---|
| 1 | Platform applies | `tofu apply` in `envs/example/platform` | Worker repository, DynamoDB gateway endpoint and evidence notification all created |
| 2 | The worker image is built and published | `aws ssm get-parameter --name /<prefix>/images/plaso-worker` | A `repo@sha256:` value, tag `ts-<12 hex>` |
| 3 | **Version parity** | `docker run --rm --entrypoint log2timeline.py <worker digest> --version` and, on the appliance, `docker compose exec -T timesketch-web log2timeline.py --version` | Identical plaso versions. This is the §8 assertion that finally has two things to compare |
| 4 | Activation brings up the fleet | `tofu apply -var='posture=active'` | Eleven interface endpoints; compute environment `ENABLED` and `VALID` |
| 5 | **The compose fix** | On the appliance: `docker compose ps` then `docker compose logs timesketch-web \| head -50` | The three backing services report `healthy` before web starts; no restart-loop entries for web or worker. **This is the success condition `NEXT.md` has carried since Phase 1** |
| 6 | An EVTX becomes a timeline | `irctl upload --case CASE-TEST-003 sample.evtx --source acceptance` | A timeline appears in the `CASE-TEST-003` sketch; manifest row reaches `timelined` with a matching `event_count` |
| 7 | A CSV takes the direct route | `irctl upload --case CASE-TEST-003 sample.csv --source acceptance` | Manifest reaches `timelined`; **no `timeline-*` Batch job was submitted**, only `import-*` |
| 8 | **The dormant backlog drains** | `tofu apply -var='posture=dormant'`; upload an artifact; confirm the row reaches `recorded` with no execution started; `tofu apply -var='posture=active'` | Within `sweep_interval_minutes` the sweep timelines it. **This is the check that justifies the reconciler existing** |
| 9 | **Measure the copy ceiling** | Upload an artifact ≥ 5 GB; read the recorder's duration from its CloudWatch log | Record the figure and the implied ceiling in `CLAUDE.md`. A10 makes this a measurement, not an assumption |
| 10 | Zero events is flagged, not recorded | `irctl upload --case CASE-TEST-003 sample.bin` | Manifest reaches `needs_triage`, not `timelined`; SNS notifies (spec §4.3) |
| 11 | The two triggers cannot double-process | While an S3-triggered execution runs, start a second by hand with the same input | Exactly one timeline in the sketch; the second execution ends at `AlreadyHandled` |
| 12 | A failure leaves the artifact intact | Terminate a running Batch job | Manifest reaches `failed`; the object is still in evidence under legal hold; SNS notifies (spec §4.7) |
| 13 | The worker cannot destroy evidence | From the worker's role, attempt `delete-object` on an evidence key | `AccessDenied` — from the bucket policy *and* from the absence of the action in the job role |
| 14 | Dormancy stops the fleet | `tofu apply -var='posture=dormant'` | Compute environment `DISABLED`, both rules `DISABLED`, queue still `ENABLED`, no running instances |
| 15 | Warm data survives | Reactivate and open the sketch | The timelines from checks 6 and 7 are still there |

## Teardown

Unchanged from `docs/acceptance/phase-2.md`, and both non-obvious parts still apply:

- **A legal hold is not cleared by `--bypass-governance-retention`.** Turn the hold off separately
  first.
- **Break-glass deletion must target a version.** The bucket policy denies keyed `s3:DeleteObject`
  outright, so any script omitting `--version-id` fails with an explicit deny rather than quietly
  writing a delete marker.

Additionally, the `plaso` bucket now holds objects. It is an Object Lock bucket but this phase
applies **no** legal hold to derived `.plaso` files (see the deferral in the Phase 3 plan), so they
delete as ordinary versioned objects.

Finish with `tofu apply -var='posture=dormant'` in `envs/example/analysis`.

## Defects found

*Filled in after the run.*

| # | Defect | Root cause | Fix |
|---|---|---|---|

## Known gaps at this phase

- **No `irctl case close`.** Phase 4 per §9.
- **No `.plaso` legal hold.** Deferred deliberately: a `.plaso` is reproducible from the evidence
  object, which *is* held, so holding derived artifacts adds a teardown step for no integrity gain
  and pre-empts Phase 4, where retention and holds are set coherently at case close (§5.4).
  *Success condition:* Phase 4's `case close` sets retention on the `.plaso` prefix at the same
  time as the evidence prefix, or a written argument records why it should not.
- **The reconciler scans the manifest.** Fine at one row per artifact per case; revisit with a GSI
  on `status` past roughly 100k rows.
- **Per-case cost attribution** is §6 and Phase 4. Batch resources carry `local.common_tags` like
  everything else, so the retrofit is not made harder.
