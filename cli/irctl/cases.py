"""Case records (spec 5.3).

A case is a data concept, not an infrastructure one (D11): a row here, a prefix
in the evidence bucket, and eventually a Timesketch sketch. Opening a case
creates nothing in AWS beyond this row.
"""

from datetime import datetime, timezone

from botocore.exceptions import ClientError

LOCK_MODES = ("GOVERNANCE", "COMPLIANCE")


class CaseExistsError(Exception):
    """The case is already open. Reopening would reset its retention policy."""


def open_case(
    ddb,
    table,
    case_id,
    retention_years=3,
    object_lock_mode="GOVERNANCE",
    cost_tag=None,
):
    """Create an open case record.

    The retention policy is recorded now and applied at case close (spec 5.2) --
    the clock starts when the case closes, not when an artifact arrives.
    """
    if object_lock_mode not in LOCK_MODES:
        raise ValueError(
            f"object_lock_mode must be one of {LOCK_MODES}, got {object_lock_mode!r}"
        )

    opened_at = datetime.now(timezone.utc).isoformat()

    record = {
        "case_id": case_id,
        "status": "open",
        "opened_at": opened_at,
        "retention_years": retention_years,
        "object_lock_mode": object_lock_mode,
        # Independent of retention, and persists until explicitly removed. At
        # case close the hold is released only if this is still false (spec 5.2).
        "legal_hold": False,
        "cost_tag": cost_tag or case_id,
    }

    item = {
        "case_id": {"S": case_id},
        "status": {"S": "open"},
        "opened_at": {"S": opened_at},
        "retention_years": {"N": str(retention_years)},
        "object_lock_mode": {"S": object_lock_mode},
        "legal_hold": {"BOOL": False},
        "cost_tag": {"S": record["cost_tag"]},
    }

    try:
        ddb.put_item(
            TableName=table,
            Item=item,
            ConditionExpression="attribute_not_exists(case_id)",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise CaseExistsError(
                f"case {case_id} already exists. Reopening it would reset the "
                "retention policy on evidence already filed against it."
            ) from exc
        raise

    return record
