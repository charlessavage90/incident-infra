"""botocore.Stubber, never live calls -- the same discipline mock_provider gives
the HCL.

No dummy AWS credentials anywhere: Stubber intercepts at before-call, which runs
ahead of signing, so nothing ever authenticates and a hardcoded key would only
trip Snyk Code's HardcodedNonCryptoSecret rule.
"""

import io

import boto3
import pytest
from botocore.response import StreamingBody
from botocore.stub import Stubber

import worker


def _body(data):
    return StreamingBody(io.BytesIO(data), len(data))


def test_import_reaches_for_no_aws_configuration():
    """A module that builds a boto3 client at import needs a resolvable region,
    so it imports fine on a developer machine and fails on every CI runner with
    NoRegionError raised during collection."""
    assert worker._CLIENTS == {}


def test_plaso_key_is_namespaced_by_case():
    """Case close operates across a prefix, so the prefix must be the case."""
    assert worker.plaso_key("CASE-2026-014", "abc123") == "CASE-2026-014/abc123.plaso"


def test_timeline_name_drops_the_case_prefix_and_the_extension():
    assert worker.timeline_name("CASE-2026-014/triage.zip") == "triage"
    assert worker.timeline_name("CASE-2026-014/nested/dir/evtx.evtx") == "evtx"


def test_missing_configuration_names_the_module_that_sets_it(monkeypatch):
    monkeypatch.delenv("EVIDENCE_BUCKET", raising=False)
    with pytest.raises(worker.WorkerError, match="modules/analysis"):
        worker._config("EVIDENCE_BUCKET")


def test_download_asks_for_the_object_it_was_told_to(tmp_path, monkeypatch):
    s3 = boto3.client("s3", region_name="us-east-1")
    stub = Stubber(s3)
    stub.add_response(
        "get_object",
        {"Body": _body(b"bytes")},
        {"Bucket": "ir-evidence", "Key": "CASE-1/triage.zip"},
    )
    stub.activate()
    monkeypatch.setitem(worker._CLIENTS, "s3", s3)

    dest = tmp_path / "triage.zip"
    worker.download("ir-evidence", "CASE-1/triage.zip", str(dest))

    stub.assert_no_pending_responses()
    assert dest.read_bytes() == b"bytes"


def test_record_timeline_writes_only_the_two_fields_it_owns(monkeypatch):
    """Status is owned by the state machine.

    If the worker also wrote status, a retried job and the machine's catch
    handler would race and the manifest would end up disagreeing with what
    actually happened.
    """
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    stub = Stubber(ddb)
    stub.add_response(
        "update_item",
        {},
        {
            "TableName": "ir-artifacts",
            "Key": {"case_id": {"S": "CASE-1"}, "sha256": {"S": "abc"}},
            "UpdateExpression": "SET timeline_id = :t, event_count = :c",
            "ExpressionAttributeValues": {":t": {"N": "42"}, ":c": {"N": "1337"}},
        },
    )
    stub.activate()
    monkeypatch.setitem(worker._CLIENTS, "dynamodb", ddb)
    monkeypatch.setenv("ARTIFACTS_TABLE", "ir-artifacts")

    worker.record_timeline("CASE-1", "abc", timeline_id=42, event_count=1337)

    stub.assert_no_pending_responses()


def test_run_log2timeline_raises_with_the_exit_code(monkeypatch, tmp_path):
    class Result:
        returncode = 1
        stderr = "parser exploded"

    monkeypatch.setattr(worker.subprocess, "run", lambda argv, **kwargs: Result())

    with pytest.raises(worker.WorkerError, match="exit 1"):
        worker.run_log2timeline(str(tmp_path / "in"), str(tmp_path / "out.plaso"))


def test_run_log2timeline_passes_the_storage_file_and_the_source(monkeypatch, tmp_path):
    """log2timeline auto-detects across roughly 200 formats and runs every
    applicable parser itself; the pipeline does not second-guess it (spec 4.3).
    So the only thing worth asserting is that it is handed the right two paths."""
    captured = {}

    class Result:
        returncode = 0
        stderr = ""

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return Result()

    monkeypatch.setattr(worker.subprocess, "run", fake_run)

    source = str(tmp_path / "triage.zip")
    destination = str(tmp_path / "abc.plaso")
    worker.run_log2timeline(source, destination)

    assert captured["argv"][0] == "log2timeline.py"
    assert captured["argv"][-1] == source
    assert destination in captured["argv"]


def test_main_returns_nonzero_rather_than_raising(monkeypatch):
    """Batch reads the exit code. An uncaught traceback would still exit
    non-zero, but the state machine's error would name Python rather than the
    thing that failed."""
    monkeypatch.setattr(
        worker, "cmd_timeline", lambda args: (_ for _ in ()).throw(worker.WorkerError("boom"))
    )

    code = worker.main(
        ["timeline", "--case-id", "CASE-1", "--sha256", "abc", "--evidence-key", "CASE-1/a.zip"]
    )

    assert code == 1
