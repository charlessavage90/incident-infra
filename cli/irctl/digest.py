"""Hashing at the point of collection (spec 4.2).

The digest is computed before upload and S3 verifies it server-side at PUT,
rejecting a mismatch. Hashing after arrival would prove only that S3 did not
corrupt the object; hashing at collection is what is actually defensible.

Both digests are produced in one pass. A 20 GB triage package read twice is a
minute of avoidable I/O, and the per-part digests are only needed because S3
stores a composite `<hash>-N` for multipart uploads rather than the whole-file
digest.
"""

import base64
import hashlib
from dataclasses import dataclass

# 8 MiB. Above S3's 5 MiB minimum part size, and small enough that a failed part
# is cheap to retry over a field connection.
PART_SIZE = 8 * 1024 * 1024


@dataclass(frozen=True)
class FileDigest:
    """Everything the upload and the manifest need from one read of the file.

    sha256_hex        -- what goes in the manifest and object metadata. The value
                         custody and deduplication key on.
    sha256_b64        -- what goes in x-amz-checksum-sha256 for a single PUT.
    part_digests_b64  -- per-part checksums for a multipart upload.
    size_bytes        -- decides single versus multipart, and is recorded.
    """

    sha256_hex: str
    sha256_b64: str
    part_digests_b64: list
    size_bytes: int


def hash_file(path, part_size=PART_SIZE):
    whole = hashlib.sha256()
    parts = []
    size = 0

    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(part_size)
            if not chunk:
                break
            size += len(chunk)
            whole.update(chunk)
            parts.append(base64.b64encode(hashlib.sha256(chunk).digest()).decode())

    if not parts:
        # S3 rejects a multipart upload with zero parts, and an empty artifact is
        # still an artifact. One empty part keeps the single-PUT path valid.
        parts.append(base64.b64encode(hashlib.sha256(b"").digest()).decode())

    return FileDigest(
        sha256_hex=whole.hexdigest(),
        sha256_b64=base64.b64encode(whole.digest()).decode(),
        part_digests_b64=parts,
        size_bytes=size,
    )
