"""Pipeline claim and reconciliation (spec 4.1, 4.3).

Two entry points, one module, one zip. They share the routing rule and the
manifest vocabulary; separating them would give that shared knowledge two places
to drift.

claim_handler is the first state of the machine. Both triggers -- the
EventBridge rule on the evidence bucket and the scheduled sweep -- run it, and
it is where double-processing is prevented: by a conditional write failing, not
by a check before one. Two concurrent invocations would both pass a
read-then-write check; only one can win a conditional write. That is the same
argument the intake recorder's _claim makes, and deliberately the same shape.

sweep_handler is the correctness path. An artifact recorded while the
environment was dormant produced its S3 event while the EventBridge rule was
DISABLED, and that event is gone forever. Nothing but this sweep would ever
timeline it. The rule is a latency optimisation layered on top.

Neither function touches S3. The digest a claim needs is resolved from the
manifest rather than from object metadata, which keeps s3:GetObject on the
evidence bucket confined to the Batch worker (amendment A12).
"""

import json
import logging
import os
import urllib.parse
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

# Resolved on first use, never at import.
#
# A client at module scope needs a resolvable region, so the module would import
# fine on a developer machine and fail on every CI runner with NoRegionError
# raised during collection.
_CLIENTS = {}

# Spec 4.3. plaso has no generic CSV or JSON parser -- dsv_parser.py is an
# abstract base class whose COLUMNS list each concrete parser defines, and a
# _MAGIC_TEST_STRING sniff test rejects non-conforming files. Arbitrary tabular
# data therefore takes the direct-import route, where Timesketch's own import
# maps columns onto message / datetime / timestamp_desc.
DIRECT_IMPORT_SUFFIXES = (".csv", ".jsonl", ".json")

# Matches attempt_duration_seconds on the Batch job definition (batch.tf). A row
# still marked `timelining` after this long belongs to an execution that cannot
# still be running, so the sweep may re-claim it. The two must stay in step: a
# value below the job timeout would re-drive work that is still in flight and
# produce a duplicate timeline.
STALE_CLAIM_HOURS = 12


class PipelineError(Exception):
    """The artifact is not timelined. It stays in evidence, recorded and held."""


def _client(service):
    if service not in _CLIENTS:
        _CLIENTS[service] = boto3.client(service)
    return _CLIENTS[service]


def _config(name):
    try:
        return os.environ[name]
    except KeyError:
        raise PipelineError(
            f"{name} is not set. This function is configured by modules/analysis; "
            "an unset value means it was deployed outside it."
        ) from None


def _now():
    return datetime.now(timezone.utc).isoformat()


def _stale_before():
    return (datetime.now(timezone.utc) - timedelta(hours=STALE_CLAIM_HOURS)).isoformat()


def route(evidence_key):
    """A rule, not a classifier (spec 4.3).

    log2timeline auto-detects across roughly 200 formats and runs every
    applicable parser itself; the pipeline does not second-guess it.
    """
    return "direct" if evidence_key.lower().endswith(DIRECT_IMPORT_SUFFIXES) else "plaso"


def case_id_from_key(evidence_key):
    """The recorder writes every evidence key as <case_id>/<name>, because case
    close operates across a prefix."""
    head, sep, _ = evidence_key.partition("/")
    if not sep or not head:
        raise PipelineError(
            f"{evidence_key} has no case prefix, so it was not written by the "
            "intake recorder. It is not timelined."
        )
    return head


def plaso_key(case_id, sha256):
    """Must agree with worker.plaso_key. The worker computes it for its upload
    and this computes it for the import command; only an acceptance run proves
    the two agree."""
    return f"{case_id}/{sha256}.plaso"


def resolve_sha256(case_id, evidence_key):
    """Find the digest from the manifest rather than from object metadata.

    HeadObject would need s3:GetObject on the evidence bucket -- IAM has no
    s3:HeadObject action -- and that grant is one amendment A12 exists to keep
    confined to the worker.
    """
    result = _client("dynamodb").query(
        TableName=_config("ARTIFACTS_TABLE"),
        KeyConditionExpression="case_id = :c",
        FilterExpression="evidence_key = :k",
        ExpressionAttributeValues={":c": {"S": case_id}, ":k": {"S": evidence_key}},
        ConsistentRead=True,
    )
    items = result.get("Items", [])
    if not items:
        raise PipelineError(
            f"{evidence_key} has no manifest row. An object in the evidence "
            "bucket that the recorder never recorded has no chain of custody, "
            "and is not put into a sketch."
        )
    return items[0]["sha256"]["S"]


def _claim(case_id, sha256):
    """Conditionally move the row to `timelining`. True if this call won it."""
    try:
        _client("dynamodb").update_item(
            TableName=_config("ARTIFACTS_TABLE"),
            Key={"case_id": {"S": case_id}, "sha256": {"S": sha256}},
            UpdateExpression="SET #s = :timelining, claimed_at = :now",
            ConditionExpression="#s = :recorded OR (#s = :timelining AND claimed_at < :stale)",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":timelining": {"S": "timelining"},
                ":recorded": {"S": "recorded"},
                ":now": {"S": _now()},
                ":stale": {"S": _stale_before()},
            },
        )
        return True
    except ClientError as exc:
        # Only a lost race is benign. Throttling is not a duplicate, and
        # swallowing it would report the artifact as handled by someone else,
        # after which nothing would ever timeline it.
        if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        return False


def claim_handler(event, context):
    """Claim the artifact, or report that someone else already has."""
    # The EventBridge rule sends a URL-encoded key, exactly as an S3 bucket
    # notification does; the sweep sends a raw one out of DynamoDB. Decoding
    # unconditionally would corrupt any key with a literal '+' or '%' in it, so
    # the two arrive under different names rather than being sniffed apart.
    if "evidence_key_encoded" in event:
        evidence_key = urllib.parse.unquote_plus(event["evidence_key_encoded"])
    else:
        evidence_key = event["evidence_key"]

    case_id = event.get("case_id") or case_id_from_key(evidence_key)
    sha256 = event.get("sha256") or resolve_sha256(case_id, evidence_key)

    payload = {
        "claimed": False,
        "case_id": case_id,
        "sha256": sha256,
        "evidence_key": evidence_key,
        "route": route(evidence_key),
        "plaso_key": plaso_key(case_id, sha256),
    }

    if not _claim(case_id, sha256):
        log.info("%s is already claimed or not ready; nothing to do", evidence_key)
        return payload

    payload["claimed"] = True
    log.info("claimed %s for %s via the %s route", sha256, case_id, payload["route"])
    return payload


def sweep_handler(event, context):
    """Start an execution for every recorded artifact with no timeline.

    A Scan with a filter, not a GSI. The manifest holds one row per artifact per
    case -- tens to low thousands -- and a GSI on status would be an index
    nobody asked for, billed forever, to save a scan that runs four times an
    hour while the environment is awake. If a deployment's manifest passes
    roughly 100k rows, revisit that.
    """
    table = _config("ARTIFACTS_TABLE")
    machine = _config("STATE_MACHINE_ARN")
    started = 0

    scan_kwargs = {
        "TableName": table,
        "FilterExpression": "#s = :recorded AND attribute_not_exists(timeline_id)",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":recorded": {"S": "recorded"}},
    }

    while True:
        page = _client("dynamodb").scan(**scan_kwargs)

        for item in page.get("Items", []):
            _client("stepfunctions").start_execution(
                stateMachineArn=machine,
                input=json.dumps(
                    {
                        "case_id": item["case_id"]["S"],
                        "sha256": item["sha256"]["S"],
                        "evidence_key": item["evidence_key"]["S"],
                    }
                ),
            )
            started += 1

        last = page.get("LastEvaluatedKey")
        if not last:
            break
        scan_kwargs["ExclusiveStartKey"] = last

    if started:
        log.info("swept %s artifact(s) into the pipeline", started)
    return {"started": started}
