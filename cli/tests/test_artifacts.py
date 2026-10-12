import boto3
import pytest
from botocore.stub import ANY, Stubber

from irctl.artifacts import NotFailedError, redrive


@pytest.fixture
def ddb():
    # No credentials: Stubber intercepts ahead of signing. See test_cases.py.
    return boto3.client("dynamodb", region_name="us-east-1")


def _expected(reason_matcher=ANY):
    return {
        "TableName": "ir-test-artifacts",
        "Key": {"case_id": {"S": "CASE-1"}, "sha256": {"S": "abc"}},
        "UpdateExpression": "SET #s = :recorded, custody = list_append(custody, :event)",
        "ConditionExpression": "#s = :failed",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {
            ":recorded": {"S": "recorded"},
            ":failed": {"S": "failed"},
            ":event": reason_matcher,
        },
    }


def test_redrive_returns_a_failed_row_to_recorded_for_the_sweep(ddb):
    """The sweep claims `recorded` rows, so this is all a re-drive needs to be.
    It never starts an execution itself: the claim's conditional write stays
    the one place double-processing is prevented."""
    stub = Stubber(ddb)
    stub.add_response("update_item", {}, _expected())

    with stub:
        event = redrive(ddb, "ir-test-artifacts", "CASE-1", "abc", "worker fixed", "arn:x")

    assert "re-driven by arn:x: worker fixed" in event
    stub.assert_no_pending_responses()


def test_the_custody_note_names_the_operator_and_the_reason(ddb):
    """An operator changing an artifact's state is a custody event. Without the
    note the chain would show `failed` then `timelined` with nothing between."""
    captured = {}

    def capture(params, **kwargs):
        captured.update(params)

    stub = Stubber(ddb)
    stub.add_response("update_item", {}, _expected())
    ddb.meta.events.register("provide-client-params.dynamodb.UpdateItem", capture)

    with stub:
        redrive(ddb, "ir-test-artifacts", "CASE-1", "abc", "worker fixed", "arn:aws:iam::1:user/alice")

    [note] = captured["ExpressionAttributeValues"][":event"]["L"]
    assert note["S"].endswith("re-driven by arn:aws:iam::1:user/alice: worker fixed")


def test_a_row_that_is_not_failed_is_refused(ddb):
    """`recorded`, `timelining` and `timelined` rows are either already queued,
    in flight, or done; re-driving any of them would produce a duplicate
    timeline. The condition refuses them rather than a read beforehand, for the
    same reason the claim does: a read-then-write check races."""
    stub = Stubber(ddb)
    stub.add_client_error(
        "update_item",
        service_error_code="ConditionalCheckFailedException",
        http_status_code=400,
        expected_params=_expected(),
    )

    with stub, pytest.raises(NotFailedError, match="CASE-1/abc"):
        redrive(ddb, "ir-test-artifacts", "CASE-1", "abc", "worker fixed", "arn:x")


@pytest.mark.parametrize("reason", ["", "   "])
def test_a_reason_is_required_before_any_call(ddb, reason):
    stub = Stubber(ddb)
    with stub, pytest.raises(ValueError, match="reason"):
        redrive(ddb, "ir-test-artifacts", "CASE-1", "abc", reason, "arn:x")
    stub.assert_no_pending_responses()
