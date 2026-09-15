"""Upload with the digest attached (spec 4.2, amendment A1).

The client's SHA-256 travels on the PUT as x-amz-checksum-sha256. S3 verifies it
server-side and rejects a mismatch, so a corrupt transfer never becomes an
object. Nothing downstream re-hashes the artifact -- which is what lets the
recorder run inside a function timeout regardless of artifact size.

Multipart is hand-rolled rather than delegated to boto3's managed transfer,
because the part checksums are the whole point and the managed path does not
make it obvious whether they were attached.
"""

import os

from .digest import PART_SIZE, hash_file


def upload_artifact(s3, bucket, case_id, path, source=None, part_size=PART_SIZE):
    """Hash then upload. Returns a record describing what was sent."""
    digest = hash_file(path, part_size=part_size)
    key = f"{case_id}/{os.path.basename(path)}"

    # The recorder reads these off HeadObject. Without sha256 and case-id it
    # refuses the object, because an artifact whose digest was not recorded at
    # collection cannot enter the chain of custody.
    metadata = {
        "sha256": digest.sha256_hex,
        "case-id": case_id,
        "source": source or "unspecified",
    }

    if digest.size_bytes <= part_size:
        # Below the threshold the stored checksum IS the whole-file digest.
        with open(path, "rb") as handle:
            s3.put_object(
                Bucket=bucket,
                Key=key,
                Body=handle,
                ChecksumAlgorithm="SHA256",
                ChecksumSHA256=digest.sha256_b64,
                Metadata=metadata,
            )
        return {
            "key": key,
            "sha256": digest.sha256_hex,
            "size_bytes": digest.size_bytes,
            "multipart": False,
            "parts": 1,
            "metadata": metadata,
        }

    upload_id = s3.create_multipart_upload(
        Bucket=bucket,
        Key=key,
        ChecksumAlgorithm="SHA256",
        Metadata=metadata,
    )["UploadId"]

    completed = []
    try:
        with open(path, "rb") as handle:
            for number, part_checksum in enumerate(digest.part_digests_b64, start=1):
                chunk = handle.read(part_size)
                response = s3.upload_part(
                    Bucket=bucket,
                    Key=key,
                    UploadId=upload_id,
                    PartNumber=number,
                    Body=chunk,
                    ChecksumAlgorithm="SHA256",
                    ChecksumSHA256=part_checksum,
                )
                completed.append(
                    {
                        "ETag": response["ETag"],
                        "PartNumber": number,
                        "ChecksumSHA256": part_checksum,
                    }
                )

        s3.complete_multipart_upload(
            Bucket=bucket,
            Key=key,
            UploadId=upload_id,
            MultipartUpload={"Parts": completed},
        )
    except Exception:
        # An abandoned multipart upload is billed storage that no object listing
        # shows. The bucket lifecycle catches it eventually; this catches it now.
        s3.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)
        raise

    return {
        "key": key,
        "sha256": digest.sha256_hex,
        "size_bytes": digest.size_bytes,
        "multipart": True,
        "parts": len(completed),
        "metadata": metadata,
    }
