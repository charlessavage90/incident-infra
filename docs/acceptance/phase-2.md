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
| 8 | **Deletion is refused** | `aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx` | `AccessDenied`, from the bucket policy. Read the section below before trusting Object Lock alone for this |
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

### Check 8 — why there is a bucket policy, and not just Object Lock

The first run of this gate failed here, and the reason is worth keeping rather
than paraphrasing.

**Object Lock protects a version, not a name.** A `DeleteObject` with no version
ID on a versioned bucket does not delete anything: it writes a delete marker and
returns 204, and S3 permits that on an object under a legal hold. The version
underneath was never at risk — deleting it was refused even with
`--bypass-governance-retention`. But the artifact was gone from `aws s3 ls`, gone
from every read-by-key path, and Phase 3's workers read evidence by key. Evidence
that reads as absent is an integrity failure whether or not the bytes survive.

`evidence.tf` therefore denies `s3:DeleteObject` on both locked buckets, and that
is what check 8 now exercises. The deny is deliberately narrow: a versioned
delete is authorised by `s3:DeleteObjectVersion`, which is left alone so the
teardown below still works. Both halves are worth seeing:

```bash
# Refused by the bucket policy -- this is the call that writes a delete marker.
aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx

# Reaches Object Lock, which refuses it on its own terms (checks 15 and 16).
aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --version-id <id>
```

### Checks 15 and 16 — de-risking Phase 4 for free

Phase 2 builds no case-close, so the retention path is never exercised. These two
probes cost nothing and prove the primitives behave as §5.2 assumes. Run them by hand.

**15 — retention then hold release, in that order:**

```bash
RETAIN=$(python -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
VID=$(aws s3api list-object-versions --bucket $EVIDENCE \
  --prefix CASE-TEST-001/sample.evtx --query 'Versions[0].VersionId' --output text)

aws s3api put-object-retention --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --version-id $VID \
  --retention "{\"Mode\":\"GOVERNANCE\",\"RetainUntilDate\":\"$RETAIN\"}"

aws s3api put-object-legal-hold --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --version-id $VID --legal-hold Status=OFF

aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx --version-id $VID
```

Pass: the delete fails with `Access Denied because object protected by object
lock`. The hold is gone but retention now holds it — which is exactly what case
close must achieve, and why the order in §5.2 is not arbitrary.

**Target the version, not the key.** A keyed delete is now refused by check 8's
bucket policy, which would pass this check for entirely the wrong reason. What is
being tested here is that *Object Lock* refuses it.

**16 — break-glass actually breaks glass:**

```bash
aws s3api delete-object --bucket $EVIDENCE --key CASE-TEST-001/sample.evtx \
  --version-id $VID --bypass-governance-retention
```

Pass: succeeds, and `list-object-versions` then reports the key gone entirely —
no version, no delete marker.

Note what the bypass does **not** do: run it before check 15 has released the
legal hold and it is still refused. A hold outranks the retention bypass, which
is why the teardown below has to clear holds separately. This is what makes GOVERNANCE meaningfully different from COMPLIANCE,
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

Run 2026-09-15 against the development account. All 16 checks pass. Three defects,
each fixed with a regression test in the same branch (PR #5).

| # | Defect | Fix |
|---|---|---|
| 1 | `tofu apply` failed creating the recorder's log group: `CreateLogGroup: AccessDeniedException: The specified KMS key does not exist or is not allowed to be used with Arn '...log-group:/aws/lambda/ir-dev-intake-recorder'`. The group is CMK-encrypted and CloudWatch Logs encrypts it as a **service** principal, which the key policy's root statement does not reach — the same gap the `AllowCloudTrailEncrypt` statement exists to close. Like CloudTrail's, the error names everything except the key | `AllowCloudWatchLogsEncrypt` added to the key policy in `kms.tf`, conditioned on this account's log group ARNs |
| 2 | The recorder 403'd on `HeadObject` on its first real invocation, so nothing was ever recorded. The role deliberately withheld `s3:GetObject` — but IAM has no `s3:HeadObject` action, and `CopyObject` requires `s3:GetObject` on the source object, so the copy would have failed next. `GetObjectAttributes` is not a substitute: it does not return user metadata, which is where `sha256`, `case-id` and `source` live | `s3:GetObject` granted on the `ReadIntakeMetadata` statement, scoped to **intake only**. The evidence bucket still carries write-and-lock and no read. Spec §5.5 corrected; amendment A7 |
| 3 | **Check 8 failed.** Deleting an artifact under a legal hold succeeded, returning 204 and a delete marker. Object Lock protects a version, not a name. The version was safe — refused even with `--bypass-governance-retention`, which also establishes that a hold outranks the bypass — but the artifact vanished from every read-by-key path, and Phase 3 reads evidence by key | `s3:DeleteObject` denied on both locked buckets in `evidence.tf`; `s3:DeleteObjectVersion` deliberately left alone so teardown still works. Both buckets also picked up the `DenyInsecureTransport` statement that only intake had. Amendment A8 |

**What passed first time, and is worth stating.** The two things the Phase 2
hand-off predicted would break did not: the recorder's cross-bucket `s3.copy`
worked on its first attempt with the KMS grants as written, and the CloudTrail
trail created cleanly with its `aws:SourceArn` conditions and the new key policy
correct simultaneously. The `case-id` versus `case_id` metadata mismatch the
hand-off flagged as untested did not exist either — `irctl` and the recorder agree.

All three defects were in **authorisation**, and every one of them was invisible
to `mock_provider`: two were IAM grants the mocks cannot evaluate, and the third
was an S3 semantic no plan can model.

## Known gaps at this phase

Listed in `NEXT.md` under "Deliberately not built, so nobody goes looking" rather than repeated
here. The short version, so a reader running these checks is not surprised by them: there is no
`irctl case close` yet, the recorder's copy has a 900-second ceiling, and there is a sub-second
window between the copy and the legal hold. None of them should make a check below fail.
