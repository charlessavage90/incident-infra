"""plaso worker -- spec 4.1, 4.5, 4.6.

Runs on AWS Batch, EC2 on-demand (D14, re-argued as amendment A9): plaso is
disk-bound and D8 targets 100 GB to 1 TB per incident, so the scratch area is
instance-store NVMe rather than a per-task network volume.

This image is `FROM` the Timesketch image by digest, which is what makes the
spec 4.5 parity invariant structural: the log2timeline.py that writes a .plaso
here is the same binary the appliance reads it back with. Timesketch rejects
.plaso files produced by a newer plaso than it runs, and upstream installs
plaso-tools UNPINNED from ppa:gift, so two builds of one release tag can differ.

This process is told what to do. Routing -- the spec 4.3 rule -- lives in the
claim Lambda so there is exactly one copy of it.

It reads evidence and writes .plaso. It holds no delete permission and no legal
hold anywhere; see the job role in modules/analysis/batch.tf. The recorder's
read/write asymmetry (amendment A7) is a property of the RECORDER, not of the
bucket, and nothing enforces anything for a second reader but that policy --
which is why amendment A12 states this boundary rather than assuming it.
"""

import argparse
import logging
import os
import subprocess
import sys
import tempfile

import boto3

from timesketch_client import TimesketchClient, TimesketchError

log = logging.getLogger("worker")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

# Resolved on first use, never at import.
#
# Creating a boto3 client at module scope needs a resolvable region, so the
# module would import fine on a developer machine and fail on every CI runner
# with NoRegionError raised during collection. See
# test_import_reaches_for_no_aws_configuration.
_CLIENTS = {}

# Read in 8 MB chunks. The artifact can be hundreds of gigabytes and the
# container's memory is sized for plaso, not for holding a disk image.
_CHUNK_BYTES = 8 * 1024 * 1024


class WorkerError(Exception):
    """The job failed. The artifact stays in the evidence bucket regardless."""


def _client(service):
    if service not in _CLIENTS:
        _CLIENTS[service] = boto3.client(service)
    return _CLIENTS[service]


def _config(name):
    try:
        return os.environ[name]
    except KeyError:
        raise WorkerError(
            f"{name} is not set. The worker is configured by modules/analysis; "
            "an unset value means the job definition was built elsewhere."
        ) from None


def plaso_key(case_id, sha256):
    """Case close operates across a prefix, so the prefix must be the case."""
    return f"{case_id}/{sha256}.plaso"


def timeline_name(evidence_key):
    """A responder reads this in the Timesketch UI, so it is the file's name."""
    return os.path.splitext(os.path.basename(evidence_key))[0]


def download(bucket, key, dest):
    body = _client("s3").get_object(Bucket=bucket, Key=key)["Body"]
    with open(dest, "wb") as handle:
        for chunk in iter(lambda: body.read(_CHUNK_BYTES), b""):
            handle.write(chunk)
    return dest


def upload(path, bucket, key):
    _client("s3").upload_file(path, bucket, key)
    return key


def run_log2timeline(source, destination):
    """log2timeline auto-detects across roughly 200 formats and runs every
    applicable parser itself. The pipeline does not second-guess it (spec 4.3).
    """
    argv = [
        "log2timeline.py",
        "--status_view", "none",
        "--partitions", "all",
        "--volumes", "all",
        "--unattended",
        "--storage_file", destination,
        source,
    ]
    log.info("running %s", " ".join(argv))
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        raise WorkerError(f"log2timeline exit {result.returncode}: {result.stderr[-2000:]}")
    return destination


def record_timeline(case_id, sha256, timeline_id, event_count):
    """Write the two fields this job owns.

    Status belongs to the state machine. If the worker wrote it too, a retried
    job and the machine's catch handler would race and the manifest would end up
    disagreeing with what actually happened.
    """
    _client("dynamodb").update_item(
        TableName=_config("ARTIFACTS_TABLE"),
        Key={"case_id": {"S": case_id}, "sha256": {"S": sha256}},
        UpdateExpression="SET timeline_id = :t, event_count = :c",
        ExpressionAttributeValues={
            ":t": {"N": str(timeline_id)},
            ":c": {"N": str(event_count)},
        },
    )


def _timesketch():
    secret = _client("secretsmanager").get_secret_value(
        SecretId=_config("TIMESKETCH_SECRET_ID")
    )["SecretString"]
    client = TimesketchClient(_config("TIMESKETCH_URL"), _config("TIMESKETCH_USER"), secret)
    client.login()
    return client


def cmd_timeline(args):
    scratch = _config("SCRATCH_DIR")
    with tempfile.TemporaryDirectory(dir=scratch) as workdir:
        source = download(
            _config("EVIDENCE_BUCKET"),
            args.evidence_key,
            os.path.join(workdir, os.path.basename(args.evidence_key)),
        )
        output = os.path.join(workdir, f"{args.sha256}.plaso")
        run_log2timeline(source, output)
        key = upload(output, _config("PLASO_BUCKET"), plaso_key(args.case_id, args.sha256))
    log.info("wrote %s", key)
    return 0


def cmd_import(args):
    bucket = _config("PLASO_BUCKET") if args.bucket_kind == "plaso" else _config("EVIDENCE_BUCKET")
    scratch = _config("SCRATCH_DIR")

    with tempfile.TemporaryDirectory(dir=scratch) as workdir:
        local = download(bucket, args.key, os.path.join(workdir, os.path.basename(args.key)))
        client = _timesketch()
        sketch_id = client.resolve_sketch(args.case_id)
        timeline_id = client.upload(local, sketch_id, timeline_name(args.key))
        count = client.event_count(sketch_id, timeline_id)

    record_timeline(args.case_id, args.sha256, timeline_id, count)
    log.info("sketch %s timeline %s: %s events", sketch_id, timeline_id, count)
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="worker")
    sub = parser.add_subparsers(dest="command", required=True)

    timeline = sub.add_parser("timeline", help="run log2timeline over an evidence object")
    timeline.add_argument("--case-id", required=True)
    timeline.add_argument("--sha256", required=True)
    timeline.add_argument("--evidence-key", required=True)
    timeline.set_defaults(func=lambda args: cmd_timeline(args))

    importer = sub.add_parser("import", help="import a file into Timesketch")
    importer.add_argument("--case-id", required=True)
    importer.add_argument("--sha256", required=True)
    importer.add_argument("--key", required=True)
    importer.add_argument("--bucket-kind", required=True, choices=["evidence", "plaso"])
    importer.set_defaults(func=lambda args: cmd_import(args))

    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (WorkerError, TimesketchError) as exc:
        # Batch reads the exit code, and the state machine surfaces whatever the
        # job said. A traceback would name Python rather than the thing that
        # failed.
        log.error("%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
