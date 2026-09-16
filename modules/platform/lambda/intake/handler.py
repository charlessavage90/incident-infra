"""Intake recorder -- spec 5.5.

Runs OUTSIDE the VPC, deliberately. In-VPC placement would put this behind the
interface endpoints that dormancy destroys, which would couple the chain of
custody to the posture toggle: an artifact arriving between incidents would sit
unrecorded in a bucket with a short expiry lifecycle, and the gap would be
silent.

It never calls GetObject. HeadObject reads the metadata and CopyObject is
executed server-side by S3, so no object bytes pass through this function. That
is what makes running it outside the VPC a defensible choice rather than a
concession -- a component that cannot read evidence cannot leak it.

Known ceiling: the copy is driven from here, under a 15-minute function timeout.
boto3's managed copy uses UploadPartCopy above 5 GB, still server-side, but a
large enough artifact will exhaust the timeout. It fails loudly and the object
stays in intake.

Spec 5.5 planned to remove that ceiling in Phase 3 by moving the copy into
Batch. Amendment A10 withdraws it: Batch is posture-gated, so the move would
have made RECORDING posture-gated, and an artifact arriving between incidents
would sit here with a seven-day expiry and no legal hold while its manifest row
stayed at `recording`. That is exactly the silent gap this module exists to
prevent, so the fix would have broken the property it was fixing. The ceiling is
raised in place instead -- see _TRANSFER below and memory_size in intake.tf --
and measured at acceptance rather than assumed.
"""

import logging
import os
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

# Clients and configuration are resolved on first use, not at import.
#
# Creating a boto3 client at module scope needs a resolvable region, so importing
# this module would fail anywhere one is not configured -- which is every CI
# runner. It passed locally only because the developer machine happened to have
# one set, which is the worst kind of green.
#
# Lambda always sets AWS_REGION, so this was never a runtime problem. It was a
# testability problem, and an import that reaches for ambient configuration is
# one either way.
_CLIENTS = {}

# Amendment A10. boto3's defaults are an 8 MB chunk and ten threads, which for a
# server-side copy is far below what this function's network allowance can
# drive. The memory bump in intake.tf is the other half of the same change:
# Lambda scales network bandwidth with memory, so a 256 MB function cannot use
# these settings however they are tuned. Neither works without the other.
#
# The resulting ceiling is a MEASUREMENT, not a number to write down here. See
# docs/acceptance/phase-3.md check 9.
_TRANSFER = TransferConfig(
    multipart_threshold=64 * 1024 * 1024,
    multipart_chunksize=64 * 1024 * 1024,
    max_concurrency=20,
    use_threads=True,
)


def _client(service):
    if service not in _CLIENTS:
        _CLIENTS[service] = boto3.client(service)
    return _CLIENTS[service]


def _config(name):
    try:
        return os.environ[name]
    except KeyError:
        raise IntakeError(
            f"{name} is not set. The recorder is configured by modules/platform; "
            "an unset value means the function was deployed outside it."
        ) from None


class IntakeError(Exception):
    """The object could not be recorded. It stays in intake for investigation."""


@dataclass(frozen=True)
class ArtifactMetadata:
    sha256: str
    case_id: str
    source: str
    size_bytes: int


def validate_metadata(key, head):
    """Pull the custody fields off a HeadObject response.

    irctl writes these at PUT. Their absence means the object did not come
    through irctl, and an artifact whose digest was never recorded at the point
    of collection cannot enter the chain of custody (spec 4.2).
    """
    metadata = head.get("Metadata", {})

    sha256 = metadata.get("sha256")
    if not sha256:
        raise IntakeError(
            f"{key}: no sha256 metadata. The digest is computed at collection; "
            "an object without one did not come through irctl."
        )

    case_id = metadata.get("case-id")
    if not case_id:
        raise IntakeError(f"{key}: no case-id metadata. Evidence is filed against a case.")

    return ArtifactMetadata(
        sha256=sha256,
        case_id=case_id,
        source=metadata.get("source", "unspecified"),
        size_bytes=head.get("ContentLength", 0),
    )


def evidence_key(case_id, intake_key):
    """Case close operates across a prefix, so the prefix must be the case."""
    prefix = f"{case_id}/"
    return intake_key if intake_key.startswith(prefix) else prefix + intake_key


def _now():
    return datetime.now(timezone.utc).isoformat()


def _require_open_case(case_id):
    """Refuse an artifact filed against a case that does not exist.

    This is the quarantine boundary doing its job: past this point the object is
    under a legal hold and, in a compliance-mode deployment, permanent.
    """
    result = _client("dynamodb").get_item(
        TableName=_config("CASES_TABLE"),
        Key={"case_id": {"S": case_id}},
        ConsistentRead=True,
    )
    item = result.get("Item")
    if not item:
        raise IntakeError(
            f"case {case_id} does not exist. Run `irctl case open {case_id}` first; "
            "the artifact stays in intake."
        )
    status = item.get("status", {}).get("S")
    if status != "open":
        raise IntakeError(f"case {case_id} is {status!r}, not open. Artifact stays in intake.")


def _claim(meta, key):
    """Write the manifest row conditionally. Returns True if this is a new claim.

    Deduplication is this write failing, not a check before it -- which makes it
    atomic. Two concurrent invocations on the same artifact would both pass a
    read-then-write check; only one can win a conditional write.
    """
    try:
        _client("dynamodb").put_item(
            TableName=_config("ARTIFACTS_TABLE"),
            Item={
                "case_id": {"S": meta.case_id},
                "sha256": {"S": meta.sha256},
                "status": {"S": "recording"},
                "source": {"S": meta.source},
                "size_bytes": {"N": str(meta.size_bytes)},
                "received_at": {"S": _now()},
                "intake_key": {"S": key},
                "evidence_key": {"S": evidence_key(meta.case_id, key)},
                "custody": {"L": [{"S": f"{_now()} received from {meta.source}"}]},
            },
            ConditionExpression="attribute_not_exists(sha256)",
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        return False


def _existing_status(meta):
    result = _client("dynamodb").get_item(
        TableName=_config("ARTIFACTS_TABLE"),
        Key={"case_id": {"S": meta.case_id}, "sha256": {"S": meta.sha256}},
        ConsistentRead=True,
    )
    return result.get("Item", {}).get("status", {}).get("S")


def _copy_and_hold(bucket, key, meta):
    """Server-side copy, then the legal hold.

    The hold is a separate call rather than a CopyObject argument: the managed
    copy is needed to handle objects over 5 GB (it falls back to UploadPartCopy,
    still server-side) and its allowed-argument list is not somewhere to bet the
    hold on. The cost is a sub-second window in which the object is in evidence
    without a hold. Both calls are idempotent, so a retry is safe.
    """
    target = evidence_key(meta.case_id, key)

    _client("s3").copy(
        CopySource={"Bucket": bucket, "Key": key},
        Bucket=_config("EVIDENCE_BUCKET"),
        Key=target,
        Config=_TRANSFER,
    )

    # Spec 5.2: legal hold ON, no retain-until date. The retention clock starts
    # at case close (phase 4), not here. Setting a retention period at this point
    # would silently convert the model into "N years from upload".
    _client("s3").put_object_legal_hold(
        Bucket=_config("EVIDENCE_BUCKET"),
        Key=target,
        LegalHold={"Status": "ON"},
    )
    return target


def record_one(bucket, key):
    head = _client("s3").head_object(Bucket=bucket, Key=key, ChecksumMode="ENABLED")
    meta = validate_metadata(key, head)
    _require_open_case(meta.case_id)

    if not _claim(meta, key):
        status = _existing_status(meta)
        if status == "recorded":
            # Spec 4.2: a triage package uploaded twice is recognised and not
            # reprocessed.
            log.info("duplicate %s for case %s; discarding intake copy", meta.sha256, meta.case_id)
            _client("s3").delete_object(Bucket=bucket, Key=key)
            return "duplicate"
        log.warning(
            "artifact %s was left mid-recording; continuing from the copy", meta.sha256
        )

    target = _copy_and_hold(bucket, key, meta)

    _client("dynamodb").update_item(
        TableName=_config("ARTIFACTS_TABLE"),
        Key={"case_id": {"S": meta.case_id}, "sha256": {"S": meta.sha256}},
        UpdateExpression=(
            "SET #s = :recorded, evidence_key = :ek, custody = list_append(custody, :event)"
        ),
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":recorded": {"S": "recorded"},
            ":ek": {"S": target},
            ":event": {"L": [{"S": f"{_now()} copied to evidence under legal hold"}]},
        },
    )

    _client("s3").delete_object(Bucket=bucket, Key=key)
    log.info("recorded %s for case %s as %s", meta.sha256, meta.case_id, target)
    return "recorded"


def handler(event, context):
    """S3 ObjectCreated entry point.

    One failure does not abandon the rest of the batch: each object is
    independent, and an artifact that cannot be recorded must not prevent one
    that can.
    """
    outcomes = []
    failures = []

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        try:
            outcomes.append({"key": key, "outcome": record_one(bucket, key)})
        except Exception as exc:  # noqa: BLE001 -- reported, not swallowed
            log.exception("failed to record %s", key)
            failures.append({"key": key, "error": str(exc)})

    if failures:
        raise IntakeError(f"{len(failures)} artifact(s) not recorded: {failures}")

    return {"recorded": outcomes}
