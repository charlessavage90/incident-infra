import boto3
import pytest
from botocore.exceptions import ClientError
from botocore.stub import ANY, Stubber

from irctl.upload import upload_artifact


@pytest.fixture
def s3():
    # No credentials: Stubber intercepts at before-call, which runs ahead of
    # signing, so nothing here ever needs to authenticate. Passing dummy keys
    # would work too, but they read as hardcoded secrets to a scanner and are
    # genuinely unnecessary.
    return boto3.client("s3", region_name="us-east-1")


def test_single_part_upload_sends_the_checksum(s3, tmp_path):
    """Spec 4.2 / A1: S3 verifies this server-side and rejects a mismatch."""
    artifact = tmp_path / "triage.zip"
    artifact.write_bytes(b"z" * 64)

    stub = Stubber(s3)
    stub.add_response(
        "put_object",
        {},
        {
            "Bucket": "ir-test-intake",
            "Key": "CASE-1/triage.zip",
            "Body": ANY,
            "ChecksumAlgorithm": "SHA256",
            "ChecksumSHA256": ANY,
            "Metadata": ANY,
        },
    )

    with stub:
        result = upload_artifact(s3, "ir-test-intake", "CASE-1", artifact)

    assert result["key"] == "CASE-1/triage.zip"
    assert result["multipart"] is False
    stub.assert_no_pending_responses()


def test_metadata_carries_the_custody_fields(s3, tmp_path):
    """The recorder refuses an object without these; they are the custody chain."""
    artifact = tmp_path / "evidence.bin"
    artifact.write_bytes(b"q" * 10)

    stub = Stubber(s3)
    stub.add_response(
        "put_object",
        {},
        {
            "Bucket": ANY,
            "Key": ANY,
            "Body": ANY,
            "ChecksumAlgorithm": "SHA256",
            "ChecksumSHA256": ANY,
            "Metadata": ANY,
        },
    )

    with stub:
        result = upload_artifact(
            s3, "ir-test-intake", "CASE-9", artifact, source="laptop-7"
        )

    captured = result["metadata"]
    assert captured["case-id"] == "CASE-9"
    assert captured["source"] == "laptop-7"
    assert len(captured["sha256"]) == 64


def test_large_artifact_uses_multipart_with_part_checksums(s3, tmp_path):
    """Multipart stores a composite <hash>-N, so every part carries its own digest."""
    artifact = tmp_path / "image.dd"
    artifact.write_bytes(b"w" * 2500)

    stub = Stubber(s3)
    stub.add_response(
        "create_multipart_upload",
        {"UploadId": "mpu-1"},
        {
            "Bucket": "ir-test-intake",
            "Key": "CASE-2/image.dd",
            "ChecksumAlgorithm": "SHA256",
            "Metadata": ANY,
        },
    )
    for part in (1, 2, 3):
        stub.add_response(
            "upload_part",
            {"ETag": f"etag-{part}"},
            {
                "Bucket": "ir-test-intake",
                "Key": "CASE-2/image.dd",
                "UploadId": "mpu-1",
                "PartNumber": part,
                "Body": ANY,
                "ChecksumAlgorithm": "SHA256",
                "ChecksumSHA256": ANY,
            },
        )
    stub.add_response(
        "complete_multipart_upload",
        {},
        {
            "Bucket": "ir-test-intake",
            "Key": "CASE-2/image.dd",
            "UploadId": "mpu-1",
            "MultipartUpload": ANY,
        },
    )

    with stub:
        result = upload_artifact(
            s3, "ir-test-intake", "CASE-2", artifact, part_size=1000
        )

    assert result["multipart"] is True
    assert result["parts"] == 3
    stub.assert_no_pending_responses()


def test_failed_multipart_is_aborted(s3, tmp_path):
    """An abandoned multipart upload is billed storage no object listing shows."""
    artifact = tmp_path / "image.dd"
    artifact.write_bytes(b"w" * 2500)

    stub = Stubber(s3)
    # Expected params spelled out rather than ANY: passing ANY for the whole
    # dict makes a mismatch raise, which a broad pytest.raises(Exception) then
    # swallows -- the test goes green having exercised nothing.
    stub.add_response(
        "create_multipart_upload",
        {"UploadId": "mpu-2"},
        {
            "Bucket": "ir-test-intake",
            "Key": "CASE-3/image.dd",
            "ChecksumAlgorithm": "SHA256",
            "Metadata": ANY,
        },
    )
    stub.add_client_error("upload_part", service_error_code="InternalError")
    stub.add_response(
        "abort_multipart_upload",
        {},
        {
            "Bucket": "ir-test-intake",
            "Key": "CASE-3/image.dd",
            "UploadId": "mpu-2",
        },
    )

    with stub, pytest.raises(ClientError, match="InternalError"):
        upload_artifact(s3, "ir-test-intake", "CASE-3", artifact, part_size=1000)

    # The abort must actually have been sent, not merely queued.
    stub.assert_no_pending_responses()
