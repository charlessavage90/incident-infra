"""Unit tests for the intake recorder.

No AWS, no credentials, no cost -- these are pure functions, which is the same
discipline mock_provider gives the HCL.
"""

import os

import pytest

os.environ.setdefault("EVIDENCE_BUCKET", "ir-test-evidence")
os.environ.setdefault("CASES_TABLE", "ir-test-cases")
os.environ.setdefault("ARTIFACTS_TABLE", "ir-test-artifacts")

import handler  # noqa: E402


def test_missing_digest_metadata_is_refused():
    """An object with no recorded digest cannot enter the custody chain."""
    head = {"Metadata": {"case-id": "CASE-1"}, "ContentLength": 10}
    with pytest.raises(handler.IntakeError, match="sha256"):
        handler.validate_metadata("some/key", head)


def test_missing_case_metadata_is_refused():
    head = {"Metadata": {"sha256": "ab" * 32}, "ContentLength": 10}
    with pytest.raises(handler.IntakeError, match="case-id"):
        handler.validate_metadata("some/key", head)


def test_metadata_is_returned_when_complete():
    head = {
        "Metadata": {"sha256": "ab" * 32, "case-id": "CASE-1", "source": "laptop-7"},
        "ContentLength": 4096,
    }
    meta = handler.validate_metadata("some/key", head)
    assert meta.sha256 == "ab" * 32
    assert meta.case_id == "CASE-1"
    assert meta.source == "laptop-7"
    assert meta.size_bytes == 4096


def test_source_defaults_when_absent():
    """Source is useful but not load-bearing; its absence must not reject evidence."""
    head = {"Metadata": {"sha256": "ab" * 32, "case-id": "CASE-1"}, "ContentLength": 1}
    assert handler.validate_metadata("k", head).source == "unspecified"


def test_evidence_key_is_prefixed_by_case():
    """Case close operates across a prefix, so the prefix has to be the case."""
    assert handler.evidence_key("CASE-1", "CASE-1/triage.zip") == "CASE-1/triage.zip"
    assert handler.evidence_key("CASE-1", "triage.zip") == "CASE-1/triage.zip"
