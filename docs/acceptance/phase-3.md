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
| 2 | The worker image is built and published | `aws ssm get-parameter --name /<prefix>/images/plaso-worker` | A `repo@sha256:` value, tag `ts-<12 hex>-src-<12 hex>` (base digest, then worker source) |
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

## Results

Run 2026-09-24/25 against the development account. **14 of 15 checks pass; check 10 fails on its
premise** (finding 13 below). Twelve defects, each fixed on the Phase 3 branch (PR #7), with a
regression test wherever the property is checkable offline.

| # | Result | Evidence |
|---|---|---|
| 1 | Pass | 4 added / 2 changed / 0 destroyed: worker repository, DynamoDB gateway endpoint, evidence notification |
| 2 | Pass (after defects 1, 7) | `ir-dev/plaso-worker@sha256:...`, tag `ts-5d2db4bd966d-src-<hash>` |
| 3 | Pass | Appliance and worker both `plaso - log2timeline version 20260512` |
| 4 | Pass (after defects 2, 3) | 11 interface endpoints `available`; compute environment `ENABLED`/`VALID` |
| 5 | Pass | Backing services `healthy` ~21 s before web and worker start; `restarts=0` on all five; no connection errors. Held again on a stop/start reactivation. **Closes the item NEXT.md carried since Phase 1** |
| 6 | Pass (after defects 4-6, 8-12) | Upload to `timelined` in **34 s** with no manual step (the section 9 gate). `sample.evtx` is plaso's own `test_data/evtx/System.evtx`, 5,009 records per plaso's parser test, and indexed as **10,021 events**: 2 per record (`Creation Time`, `Content Modification Time`) + 3 `fs:stat` (finding 13) |
| 7 | Pass | CSV went `import-*` only, no `timeline-*`; `timelined`, 2 events |
| 8 | Pass | Uploaded while dormant: `recorded`, legal hold `ON`, no execution. On reactivation the sweep had it `timelining` before the apply returned; `timelined` 4 min after active |
| 9 | Pass, **measured** | 5.5 GiB (multipart copy path, 704 parts) filed in **10.17 s** at 2,048 MB configured / 116 MB used, about 554 MiB/s. Linear extrapolation to the 900 s timeout: **~480 GiB**. One measurement; treat it as an order of magnitude |
| 10 | **Fail, on premise** | 1 MB of random bytes reached `timelined` with **3 events**, not `needs_triage`. The three are `fs:stat` records of the worker's own scratch copy. See finding 13 |
| 11 | Pass | A hand-started duplicate execution with identical input ended `Claimed` then `AlreadyHandled`; one timeline, one datasource |
| 12 | Pass, by natural failure | Terminating a job was not needed: four real failures took the same `States.TaskFailed` catch. Row `failed`, SNS publish succeeded, evidence object intact with matching SHA-256 and legal hold `ON` |
| 13 | Pass | IAM policy simulator as the worker role against the live bucket policy: `DeleteObject` **explicitDeny** (bucket policy); `DeleteObjectVersion`, `PutObjectLegalHold`, `PutObjectRetention`, `BypassGovernanceRetention`, `PutObject` **implicitDeny** (role); `GetObject` allowed |
| 14 | Pass | Compute environment `DISABLED`, both rules `DISABLED`, queue `ENABLED`, 0 instances, 0 interface endpoints, appliance `stopped` |
| 15 | Pass | All sketches and timelines present after the dormant/active cycle, each with exactly one datasource |

## Defects found

| # | Defect | Fix |
|---|---|---|
| 1 | Mirror build failed: `AccessDenied` on `s3:ListBucket` for the tooling bucket. `aws s3 cp --recursive` lists before it copies, and `ListObjectsV2` is authorised on the **bucket** ARN; the role only named `bucket/*` | `ListWorkerBuildContext` statement, scoped by `s3:prefix` to `plaso-worker/src/*` |
| 2 | Compute environment went `INVALID`: the Batch service role was not authorised for `ecs:DescribeClusters`. The policy was correct and attached a second earlier; this was an **IAM propagation race**. `depends_on` was already in place and cannot close it, and Batch never re-validates | `service_role` omitted, so Batch uses its account-wide service-linked role, which it creates on first use. Two resources removed |
| 3 | Replacing that environment could never succeed: `create_before_destroy` with a **fixed name**, and Batch names are unique | `name_prefix` |
| 4 | cloud-init died on its first `aws ssm get-parameter` (`Connect timeout on endpoint URL`), leaving an appliance with no Timesketch. Endpoints and a replacement instance were created in one apply, and the endpoint reported `available` before its ENI forwarded packets: GOTCHA 4's race, hitting the script instead of the agent | Every endpoint call in cloud-init goes through `retry`. **Only the provisioning half is re-verified**: the race needs endpoints and a replacement in the same apply, which later applies did not reproduce |
| 5 | Every Batch instance was terminated before `InService` with `Client.InvalidKMSKey.InvalidState`, and jobs sat in `RUNNABLE`. Fleet volumes use the CMK and are launched by `AWSServiceRoleForAutoScaling`, whose AWS-managed permissions the root statement never reaches. The error names neither the key nor the role: the third instance of this pattern after CloudTrail and CloudWatch Logs | AWS's documented pair of key-policy statements, pinned by `aws:PrincipalArn` rather than naming the role, because KMS rejects a policy naming a principal that does not exist yet and this role exists only after an account's first Auto Scaling use |
| 6 | Every job died on `import boto3`. The Dockerfile assumed the Timesketch base carried it; `/opt/venv` has plaso and `requests` only. Its argument against `RUN` was also wrong: the build runs in CodeBuild, outside the VPC | `pip install boto3==1.43.94` at build time, pinned to the version the tests use |
| 7 | The fix for 6 could not ship: the worker was tagged by **base digest alone** and the mirror skips existing tags, so any change to the worker's own source was silently skipped | The tag carries a hash of the staged worker sources: `ts-<base>-src-<hash>` |
| 8 | Every login failed with `no CSRF token`. The client read a `csrf_token` **cookie**; this release renders the token in the login HTML (a hidden field and a meta tag) and sets only `session`. The error blamed readiness, pointing diagnosis the wrong way | Token read from the form field, as `timesketch_api_client` does, with the meta tag as fallback. The test fixture is the page captured from the appliance |
| 9 | Every upload returned `HTTP 400`. The server reads `total_file_size` from the form, defaults it to 0 and rejects 0 as *"File is empty"*. The log said only `upload: HTTP 400`; diagnosed by replaying the request inside the web container | Field sent; errors now carry the response body |
| 10 | Found in the same replay: upload returns while the datasource is `queueing` with 0 events, and the worker counted immediately, so every artifact would have been flagged `needs_triage` | Poll until the datasource reads `ready`; raise on `fail` with Timesketch's reason; bounded at 6 h, half the job timeout |
| 11 | Every `.plaso` import failed in psort: `No such OpenSearch mappings file: /etc/timesketch/plaso.mappings`. cloud-init wrote `timesketch.conf` but none of the data files it names, and CSV imports never read them | Data files copied at boot from the **same digest-pinned image** (`cp -n` keeps our conf). That pushed user data past EC2's 16 KB limit, which the provider caught at plan, so user data is now `base64gzip`'d, with a test at 75% of the limit |
| 12 | Re-importing to a same-named timeline **appends** a datasource. Every retry duplicated the events (one timeline held 10,021 events four times over), `event_count` summed them, and a stale `fail` sank later clean attempts | Import is idempotent, reusing a finished import of the same file, and waiting and counting read only the datasource this upload created |

**The pattern held a third time, and widened.** Phase 2's three defects were authorisation failures
`mock_provider` cannot see. Phase 3 has four of those (1, 2, 5, and the timing in 4), but eight are
**contract failures against a real upstream**: what the Timesketch image contains (6), how its login
page issues a token (8), which form fields its upload handler requires (9), that it indexes
asynchronously (10), what files its config expects (11), and how it treats a repeated upload (12).
Every Python test was green throughout, because the fakes encoded the same wrong beliefs as the code.
Where a test now pins one of these, its fixture was **captured from the appliance**, not written
from memory.

## Known gaps at this phase

- **No `irctl case close`.** Phase 4 per §9.
- **No `.plaso` legal hold.** Deferred deliberately: a `.plaso` is reproducible from the evidence
  object, which *is* held, so holding derived artifacts adds a teardown step for no integrity gain
  and pre-empts Phase 4, where retention and holds are set coherently at case close (§5.4).
  *Success condition:* Phase 4's `case close` sets retention on the `.plaso` prefix at the same
  time as the evidence prefix, or a written argument records why it should not.
- **The reconciler scans the manifest.** Fine at one row per artifact per case; revisit with a GSI
  on `status` past roughly 100k rows.
- **Finding 13: every plaso timeline carries three `fs:stat` events of the worker's scratch copy**,
  stamped with processing time at a path like `/scratch/tmpnfebi8n3/sample.bin`. An analyst can
  mistake them for incident activity, and they make §4.3's zero-events signal unreachable on the
  plaso route, which is check 10's failure. **Deliberately not fixed during the run:**
  `--parsers '!filestat'` would also strip the file-system timestamps *inside* disk images, which
  are among the most valuable events plaso produces. *Success condition:* parser selection per
  route (single files without `filestat`, images with it) argued as an amendment to D4, and
  check 10 re-run.
- **No supported re-drive of a `failed` row.** `failed` is terminal by design (the claim accepts
  only `recorded` or a stale `timelining`), so an artifact whose failure has been fixed stays
  un-timelined. This run re-drove by a conditional `failed` to `recorded` update with a custody
  note. *Success condition:* an `irctl` re-drive command, or that procedure written into an
  operator runbook.
- **Failure notifications reach nobody in the example environment.** `pipeline_notification_emails`
  defaults to `[]`, the topic has no subscribers, and every failure this run published to an empty
  topic. Set it before real use.
- **Per-case cost attribution** is §6 and Phase 4. Batch resources carry `local.common_tags` like
  everything else, so the retrofit is not made harder.
