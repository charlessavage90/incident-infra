"""Operator actions on manifest rows (spec 4.7).

`failed` is terminal by design: the pipeline's claim accepts only `recorded` or
a stale `timelining`, so an artifact whose failure has since been fixed would
otherwise never be timelined. A re-drive is a conditional `failed -> recorded`
update; the sweep claims it from there on its next run, exactly as it would an
artifact that arrived while the environment was dormant.
"""

from datetime import datetime, timezone

from botocore.exceptions import ClientError


class NotFailedError(Exception):
    """The row is not `failed`, so re-driving it would duplicate or race work."""


def redrive(ddb, table, case_id, sha256, reason, operator):
    """Return a `failed` artifact to `recorded`, and record who did it and why.

    Returns the custody note appended.
    """
    if not reason.strip():
        raise ValueError("a reason is required; it is written to the chain of custody")

    event = f"{datetime.now(timezone.utc).isoformat()} re-driven by {operator}: {reason.strip()}"
    try:
        ddb.update_item(
            TableName=table,
            Key={"case_id": {"S": case_id}, "sha256": {"S": sha256}},
            UpdateExpression="SET #s = :recorded, custody = list_append(custody, :event)",
            ConditionExpression="#s = :failed",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":recorded": {"S": "recorded"},
                ":failed": {"S": "failed"},
                ":event": {"L": [{"S": event}]},
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise NotFailedError(
                f"{case_id}/{sha256} is not `failed` (or does not exist). Only a failed "
                "artifact can be re-driven; any other state is queued, in flight, or done."
            ) from exc
        raise
    return event
