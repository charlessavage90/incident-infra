# Phase 2 acceptance

Spec §9: *"An artifact can be ingested by hand, is hashed, immutable, and recorded."*

Run against a real AWS account. Everything here is cheap — S3 storage for a few test
objects, a handful of DynamoDB writes, and one Lambda invocation. **The appliance is not
needed; leave the environment dormant.**

## Setup

```bash
cd envs/example/platform
tofu init   # the archive provider is new in Phase 2
tofu apply

export AWS_REGION=us-east-1
export IR_INTAKE_BUCKET=$(tofu output -raw intake_bucket)
export IR_CASES_TABLE=$(tofu output -raw cases_table)
export IR_RETENTION_YEARS=$(tofu output -raw retention_years)
EVIDENCE=$(tofu output -raw evidence_bucket)
ARTIFACTS=$(tofu output -raw artifacts_table)

cd ../../../cli && python -m pip install -e .
```

Take any file as the test artifact — an EVTX if you have one, otherwise anything:

```bash
head -c 1000000 /dev/urandom > sample.evtx
```

## Checks

| # | Check | How | Pass |
|---|---|---|---|
| 1 | A case can be opened | `irctl case open CASE-TEST-001` | JSON record with `status: open`, `retention_years: 3` |
| 2 | Reopening is refused | `irctl case open CASE-TEST-001` again | Exits non-zero, names the case |
| 3 | An artifact uploads | `irctl upload --case CASE-TEST-001 sample.evtx --source acceptance` | JSON with a 64-character `sha256` |
| 4 | It reaches evidence | `aws s3 ls s3://$EVIDENCE/CASE-TEST-001/` | `sample.evtx` present within ~30s |
| 5 | Intake was cleared | `aws s3 ls s3://$IR_INTAKE_BUCKET/CASE-TEST-001/` | Empty |
| 6 | **It is immutable** | `aws s3api get-object-legal-hold --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx` | `"Status": "ON"` |
| 7 | **No retention clock has started** | `aws s3api get-object-retention --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx` | Error `NoSuchObjectLockConfiguration` — §5.2 starts the clock at case close, not upload |
| 8 | **Deletion is refused** | `aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx` | `AccessDenied` |
| 9 | It is recorded | `aws dynamodb get-item --table-name $ARTIFACTS --key '{"case_id":{"S":"CASE-TEST-001"},"sha256":{"S":"<hash from check 3>"}}'` | `status: recorded`, two custody entries |
| 10 | The digest matches the file | `sha256sum sample.evtx` | Identical to check 3's `sha256` |
| 11 | **A re-upload deduplicates** | `irctl upload --case CASE-TEST-001 sample.evtx` again | Intake empties; artifact row unchanged (`received_at` identical) |
| 12 | **A corrupt transfer is refused at PUT** | See below | `BadDigest`, and nothing lands in intake |
| 13 | An unknown case is refused | `irctl upload --case CASE-NOPE sample.evtx` | Object stays in intake; recorder logs name the case |
| 14 | Data events are recorded | `aws s3 ls s3://$(tofu output -raw audit_bucket)/AWSLogs/` | Prefix exists within ~10 min |

**On Windows / Git Bash**, prefix AWS CLI calls whose arguments look like POSIX paths with
`MSYS_NO_PATHCONV=1`, and set `PYTHONIOENCODING=utf-8 PYTHONUTF8=1` — see `CLAUDE.md`.

### Check 12 — corrupt transfer

The point of A1 is that S3, not a later pipeline step, catches this. Send a digest
that does not match the bytes:

```bash
python - <<'PY'
import base64, hashlib, os, boto3
s3 = boto3.client("s3")
wrong = base64.b64encode(hashlib.sha256(b"not the payload").digest()).decode()
try:
    s3.put_object(
        Bucket=os.environ["IR_INTAKE_BUCKET"], Key="CASE-TEST-001/corrupt.bin",
        Body=b"the actual payload", ChecksumAlgorithm="SHA256", ChecksumSHA256=wrong,
        Metadata={"sha256": "0" * 64, "case-id": "CASE-TEST-001"},
    )
    print("FAIL: S3 accepted a mismatched checksum")
except Exception as exc:
    print("PASS:", type(exc).__name__, exc)
PY
```

Pass: an error naming `BadDigest` or `InvalidRequest`, and `aws s3 ls` shows nothing.

### Checks 15 and 16 — de-risking Phase 4 for free

Phase 2 builds no case-close, so the retention path is never exercised. These two
probes cost nothing and prove the primitives behave as §5.2 assumes. Run them by hand.

**15 — retention then hold release, in that order:**

```bash
RETAIN=$(python -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

aws s3api put-object-retention --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --retention "{\"Mode\":\"GOVERNANCE\",\"RetainUntilDate\":\"$RETAIN\"}"

aws s3api put-object-legal-hold --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --legal-hold Status=OFF

aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx
```

Pass: the delete still fails. The hold is gone but retention now holds it — which is
exactly what case close must achieve, and why the order in §5.2 is not arbitrary.

**16 — break-glass actually breaks glass:**

```bash
aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --bypass-governance-retention
```

Pass: succeeds. This is what makes GOVERNANCE meaningfully different from COMPLIANCE,
and it is what §5.2.2 depends on for `tofu destroy` to work in development.

## Teardown

Governance-mode objects block `tofu destroy` until removed with the bypass. The example
environment already sets `manifest_deletion_protection = false`; a deployment that does
not must clear it before destroying.

```bash
# Remove every object version left in the locked buckets.
for B in $EVIDENCE $(cd envs/example/platform && tofu output -raw plaso_bucket); do
  aws s3api list-object-versions --bucket "$B" \
    --query '[Versions,DeleteMarkers][].{Key:Key,VersionId:VersionId}' --output json \
  | python -c "
import json,subprocess,sys,os
for o in json.load(sys.stdin) or []:
    subprocess.run(['aws','s3api','delete-object','--bucket',os.environ['B'],
                    '--key',o['Key'],'--version-id',o['VersionId'],
                    '--bypass-governance-retention'])
"
done

cd envs/example/platform && tofu destroy
```

If `tofu destroy` still fails on a bucket, an object retains a **legal hold** — retention
bypass does not clear one. Set `--legal-hold Status=OFF` on it first.

## Defects found

| # | Defect | Fix |
|---|---|---|
| | *(fill in during the run — this table is the point of the exercise)* | |

## Known gaps at this phase

- **No `irctl case close`.** Phase 4 per §9. Checks 15 and 16 probe its primitives by hand
  so that phase does not meet them cold.
- **The copy has a documented size ceiling** — the recorder drives it under a 900-second
  timeout. It fails loudly and the object stays in intake. Phase 3 moves the copy into Batch.
- **A sub-second window exists between the copy and the legal hold.** Deliberate; the
  reasoning is in `_copy_and_hold`.
- **`SNYK-CC-TF-45` still reports** on all four buckets. CloudTrail data events are the
  compensating control and are real, but the rule looks for `aws_s3_bucket_logging`.
