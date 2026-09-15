import boto3
import pytest
from botocore.stub import ANY, Stubber

from irctl.cases import CaseExistsError, open_case


@pytest.fixture
def ddb():
    # No credentials: Stubber intercepts at before-call, which runs ahead of
    # signing, so nothing here ever needs to authenticate. Passing dummy keys
    # would work too, but they read as hardcoded secrets to a scanner and are
    # genuinely unnecessary.
    return boto3.client("dynamodb", region_name="us-east-1")


def test_open_case_writes_an_open_record(ddb):
    stub = Stubber(ddb)
    stub.add_response(
        "put_item",
        {},
        {
            "TableName": "ir-test-cases",
            "Item": ANY,
            "ConditionExpression": "attribute_not_exists(case_id)",
        },
    )

    with stub:
        record = open_case(ddb, "ir-test-cases", "CASE-2026-014")

    assert record["case_id"] == "CASE-2026-014"
    assert record["status"] == "open"
    assert record["retention_years"] == 3
    assert record["legal_hold"] is False
    stub.assert_no_pending_responses()


def test_open_case_is_refused_when_the_case_exists(ddb):
    """Reopening would silently reset retention policy on a live case."""
    stub = Stubber(ddb)
    stub.add_client_error(
        "put_item",
        service_error_code="ConditionalCheckFailedException",
        http_status_code=400,
    )

    with stub, pytest.raises(CaseExistsError, match="CASE-2026-014"):
        open_case(ddb, "ir-test-cases", "CASE-2026-014")


def test_compliance_mode_is_recorded_on_the_case(ddb):
    """Spec 5.2: the mode is per-case, and case close reads it to set retention."""
    stub = Stubber(ddb)
    stub.add_response(
        "put_item",
        {},
        {
            "TableName": "ir-test-cases",
            "Item": ANY,
            "ConditionExpression": "attribute_not_exists(case_id)",
        },
    )

    with stub:
        record = open_case(
            ddb, "ir-test-cases", "CASE-2026-015", object_lock_mode="COMPLIANCE"
        )

    assert record["object_lock_mode"] == "COMPLIANCE"


def test_unknown_lock_mode_is_rejected_before_any_call(ddb):
    stub = Stubber(ddb)
    with stub, pytest.raises(ValueError, match="GOVERNANCE"):
        open_case(ddb, "ir-test-cases", "CASE-1", object_lock_mode="whatever")
    stub.assert_no_pending_responses()
