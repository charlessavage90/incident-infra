"""botocore.Stubber, never live calls.

No dummy AWS credentials: Stubber intercepts at before-call, which runs ahead of
signing, so nothing ever authenticates and a hardcoded key would only trip Snyk
Code's HardcodedNonCryptoSecret rule.
"""

import boto3
import pytest
from botocore.exceptions import ClientError
from botocore.stub import Stubber

import handler


def test_import_reaches_for_no_aws_configuration():
    """A module that builds a boto3 client at import needs a resolvable region,
    so it imports fine on a developer machine and fails on every CI runner with
    NoRegionError raised during collection."""
    assert handler._CLIENTS == {}


@pytest.mark.parametrize(
    "key,expected",
    [
        ("CASE-1/export.csv", "direct"),
        ("CASE-1/events.jsonl", "direct"),
        ("CASE-1/cloudtrail.json", "direct"),
        ("CASE-1/EXPORT.CSV", "direct"),
        ("CASE-1/triage.zip", "plaso"),
        ("CASE-1/disk.E01", "plaso"),
        ("CASE-1/System.evtx", "plaso"),
        ("CASE-1/nested/dir/$MFT", "plaso"),
    ],
)
def test_routing_is_a_rule_not_a_classifier(key, expected):
    """Spec 4.3.

    plaso has no generic CSV or JSON parser -- dsv_parser.py is an abstract base
    class whose COLUMNS list each concrete parser must define, and a
    _MAGIC_TEST_STRING sniff test rejects non-conforming files. So arbitrary
    tabular data takes the direct-import route and everything else goes to
    log2timeline, which auto-detects across roughly 200 formats.
    """
    assert handler.route(key) == expected


def test_case_id_is_the_first_path_segment():
    assert handler.case_id_from_key("CASE-2026-014/triage.zip") == "CASE-2026-014"


def test_case_id_of_a_key_with_no_prefix_is_rejected():
    """Every evidence key is written by the recorder as <case_id>/<name>,
    because case close operates across a prefix. A key without one did not come
    from the recorder."""
    with pytest.raises(handler.PipelineError, match="prefix"):
        handler.case_id_from_key("loose-file.zip")


def test_claim_moves_a_recorded_row_to_timelining(monkeypatch):
    monkeypatch.setattr(handler, "_now", lambda: "2026-09-16T00:00:00+00:00")
    monkeypatch.setattr(handler, "_stale_before", lambda: "2026-09-15T12:00:00+00:00")

    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_response(
        "update_item",
        {},
        {
            "TableName": "ir-artifacts",
            "Key": {"case_id": {"S": "CASE-1"}, "sha256": {"S": "abc"}},
            "UpdateExpression": "SET #s = :timelining, claimed_at = :now",
            "ConditionExpression": "#s = :recorded OR (#s = :timelining AND claimed_at < :stale)",
            "ExpressionAttributeNames": {"#s": "status"},
            "ExpressionAttributeValues": {
                ":timelining": {"S": "timelining"},
                ":recorded": {"S": "recorded"},
                ":now": {"S": "2026-09-16T00:00:00+00:00"},
                ":stale": {"S": "2026-09-15T12:00:00+00:00"},
            },
        },
    )
    stub.activate()
    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    result = handler.claim_handler(
        {"case_id": "CASE-1", "sha256": "abc", "evidence_key": "CASE-1/triage.zip"}, None
    )

    stub.assert_no_pending_responses()
    assert result["claimed"] is True
    assert result["route"] == "plaso"
    assert result["plaso_key"] == "CASE-1/abc.plaso"


def test_a_lost_claim_is_not_an_error(monkeypatch):
    """Deduplication is the conditional write failing, not a check before it.

    Both trigger paths -- the EventBridge rule and the reconciler sweep -- can
    fire for the same artifact. A read-then-write check would let both through;
    only one can win a conditional write. The loser returns claimed=False and
    the state machine succeeds without doing anything.
    """
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_client_error("update_item", service_error_code="ConditionalCheckFailedException")
    stub.activate()
    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    result = handler.claim_handler(
        {"case_id": "CASE-1", "sha256": "abc", "evidence_key": "CASE-1/triage.zip"}, None
    )

    assert result["claimed"] is False


def test_a_claim_error_that_is_not_a_lost_race_propagates(monkeypatch):
    """Throttling is not a duplicate. Swallowing it would report the artifact as
    handled by someone else and it would never be timelined."""
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_client_error(
        "update_item", service_error_code="ProvisionedThroughputExceededException"
    )
    stub.activate()
    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    with pytest.raises(ClientError):
        handler.claim_handler(
            {"case_id": "CASE-1", "sha256": "abc", "evidence_key": "CASE-1/triage.zip"}, None
        )


def test_claim_resolves_a_missing_digest_from_the_manifest(monkeypatch):
    """The EventBridge path carries a bucket and a key, never a digest.

    Resolving it by querying the manifest keeps this function's AWS surface to
    DynamoDB alone. Reading the object's metadata instead would mean giving the
    claim step s3:GetObject on the evidence bucket -- IAM has no s3:HeadObject
    action -- which is precisely the grant amendment A12 exists to keep rare.
    """
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_response(
        "query",
        {"Items": [{"case_id": {"S": "CASE-1"}, "sha256": {"S": "abc"}}]},
        {
            "TableName": "ir-artifacts",
            "KeyConditionExpression": "case_id = :c",
            "FilterExpression": "evidence_key = :k",
            "ExpressionAttributeValues": {
                ":c": {"S": "CASE-1"},
                ":k": {"S": "CASE-1/triage.zip"},
            },
            "ConsistentRead": True,
        },
    )
    stub.activate()
    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    assert handler.resolve_sha256("CASE-1", "CASE-1/triage.zip") == "abc"
    stub.assert_no_pending_responses()


def test_an_unrecorded_object_is_not_timelined(monkeypatch):
    """An object in the evidence bucket with no manifest row did not come
    through the recorder. Timelining it would put an artifact with no chain of
    custody into a sketch."""
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_response(
        "query",
        {"Items": []},
        {
            "TableName": "ir-artifacts",
            "KeyConditionExpression": "case_id = :c",
            "FilterExpression": "evidence_key = :k",
            "ExpressionAttributeValues": {":c": {"S": "CASE-1"}, ":k": {"S": "CASE-1/x.zip"}},
            "ConsistentRead": True,
        },
    )
    stub.activate()
    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    with pytest.raises(handler.PipelineError, match="no manifest row"):
        handler.resolve_sha256("CASE-1", "CASE-1/x.zip")


def test_an_eventbridge_key_is_url_decoded_and_a_swept_one_is_not(monkeypatch):
    """S3 delivers keys URL-encoded through EventBridge, exactly as through a
    bucket notification. The sweep reads raw keys out of DynamoDB. Decoding both
    would corrupt any key holding a literal '+' or '%', so the two arrive under
    different names rather than being sniffed apart."""
    monkeypatch.setattr(handler, "resolve_sha256", lambda case_id, key: "abc")
    monkeypatch.setattr(handler, "_claim", lambda case_id, sha256: False)

    from_events = handler.claim_handler({"evidence_key_encoded": "CASE-1/a+b.zip"}, None)
    from_sweep = handler.claim_handler(
        {"case_id": "CASE-1", "sha256": "abc", "evidence_key": "CASE-1/a+b.zip"}, None
    )

    assert from_events["evidence_key"] == "CASE-1/a b.zip"
    assert from_sweep["evidence_key"] == "CASE-1/a+b.zip"


def test_sweep_starts_one_execution_per_untimelined_row(monkeypatch):
    """This is the path that timelines the backlog dormancy leaves behind.

    Nothing else does: an artifact recorded while the environment was asleep
    generated its S3 event at a moment when the EventBridge rule was DISABLED,
    and that event is gone. The sweep is the correctness path and the rule is a
    latency optimisation on top of it.
    """
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb_stub = Stubber(ddb)
    ddb_stub.add_response(
        "scan",
        {
            "Items": [
                {
                    "case_id": {"S": "CASE-1"},
                    "sha256": {"S": "abc"},
                    "evidence_key": {"S": "CASE-1/triage.zip"},
                }
            ]
        },
        {
            "TableName": "ir-artifacts",
            "FilterExpression": "#s = :recorded AND attribute_not_exists(timeline_id)",
            "ExpressionAttributeNames": {"#s": "status"},
            "ExpressionAttributeValues": {":recorded": {"S": "recorded"}},
        },
    )
    ddb_stub.activate()

    sfn = boto3.client("stepfunctions", region_name="us-east-1")
    sfn_stub = Stubber(sfn)
    sfn_stub.add_response(
        "start_execution",
        {"executionArn": "arn:aws:states:us-east-1:111122223333:execution:p:1", "startDate": 0},
        {
            "stateMachineArn": "arn:aws:states:us-east-1:111122223333:stateMachine:p",
            "input": '{"case_id": "CASE-1", "sha256": "abc", "evidence_key": "CASE-1/triage.zip"}',
        },
    )
    sfn_stub.activate()

    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setitem(handler._CLIENTS, "stepfunctions", sfn)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")
    monkeypatch.setenv(
        "STATE_MACHINE_ARN", "arn:aws:states:us-east-1:111122223333:stateMachine:p"
    )

    assert handler.sweep_handler({}, None) == {"started": 1}
    ddb_stub.assert_no_pending_responses()
    sfn_stub.assert_no_pending_responses()


def test_sweep_of_an_empty_manifest_starts_nothing(monkeypatch):
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb_stub = Stubber(ddb)
    ddb_stub.add_response(
        "scan",
        {"Items": []},
        {
            "TableName": "ir-artifacts",
            "FilterExpression": "#s = :recorded AND attribute_not_exists(timeline_id)",
            "ExpressionAttributeNames": {"#s": "status"},
            "ExpressionAttributeValues": {":recorded": {"S": "recorded"}},
        },
    )
    ddb_stub.activate()

    monkeypatch.setitem(handler._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")
    monkeypatch.setenv(
        "STATE_MACHINE_ARN", "arn:aws:states:us-east-1:111122223333:stateMachine:p"
    )

    assert handler.sweep_handler({}, None) == {"started": 0}
    ddb_stub.assert_no_pending_responses()


def test_missing_configuration_names_the_module_that_sets_it(monkeypatch):
    monkeypatch.delenv("ARTIFACTS_TABLE", raising=False)
    with pytest.raises(handler.PipelineError, match="modules/analysis"):
        handler._config("ARTIFACTS_TABLE")
