import base64
import hashlib

from irctl.digest import PART_SIZE, hash_file


def test_digest_matches_hashlib(tmp_path):
    payload = b"artifact contents"
    target = tmp_path / "triage.bin"
    target.write_bytes(payload)

    result = hash_file(target)

    expected = hashlib.sha256(payload)
    assert result.sha256_hex == expected.hexdigest()
    assert result.sha256_b64 == base64.b64encode(expected.digest()).decode()
    assert result.size_bytes == len(payload)


def test_small_file_is_a_single_part(tmp_path):
    """Below the threshold the stored checksum IS the whole-file digest (spec 4.2)."""
    target = tmp_path / "small.bin"
    target.write_bytes(b"x" * 100)

    result = hash_file(target)

    assert len(result.part_digests_b64) == 1
    assert result.part_digests_b64[0] == result.sha256_b64


def test_large_file_is_split_into_parts(tmp_path):
    """Above the threshold S3 stores a composite digest, so parts are hashed too."""
    target = tmp_path / "large.bin"
    target.write_bytes(b"y" * 2500)

    result = hash_file(target, part_size=1000)

    assert len(result.part_digests_b64) == 3
    assert result.size_bytes == 2500
    # The whole-file digest is still the digest of the whole file, not a
    # composite -- that is the value custody and deduplication key on.
    assert result.sha256_hex == hashlib.sha256(b"y" * 2500).hexdigest()


def test_part_digests_are_digests_of_their_own_part(tmp_path):
    target = tmp_path / "parts.bin"
    target.write_bytes(b"ab" * 1000)

    result = hash_file(target, part_size=1000)

    first = base64.b64encode(hashlib.sha256(b"ab" * 500).digest()).decode()
    assert result.part_digests_b64[0] == first


def test_empty_file_still_yields_one_part(tmp_path):
    """S3 rejects a multipart upload with no parts; an empty artifact is a single PUT."""
    target = tmp_path / "empty.bin"
    target.write_bytes(b"")

    result = hash_file(target)

    assert result.size_bytes == 0
    assert len(result.part_digests_b64) == 1


def test_default_part_size_matches_s3_multipart_minimum():
    assert PART_SIZE >= 5 * 1024 * 1024
