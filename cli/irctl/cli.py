"""irctl command line.

Configuration comes from the environment so the CLI has no state of its own:

    IR_INTAKE_BUCKET   from `tofu output -raw intake_bucket`
    IR_CASES_TABLE     from `tofu output -raw cases_table`
    IR_RETENTION_YEARS from `tofu output -raw retention_years`  (optional, default 3)
    AWS_REGION         standard
"""

import argparse
import json
import os
import sys

import boto3

from .cases import CaseExistsError, open_case
from .upload import upload_artifact

# Maps an environment variable to the platform output that supplies it, so the
# error tells you the command to run rather than just the name of what is missing.
_ENV_SOURCE = {
    "IR_INTAKE_BUCKET": "intake_bucket",
    "IR_CASES_TABLE": "cases_table",
}


def _default_retention_years():
    """The deployment's policy, not the CLI's opinion.

    Falls back to D10's three years only when the deployment has not said
    otherwise. A deployment configured for seven would otherwise record three on
    every case, and the disagreement would surface years later at case close.
    """
    raw = os.environ.get("IR_RETENTION_YEARS")
    if not raw:
        return 3
    try:
        return int(raw)
    except ValueError:
        raise SystemExit(
            f"IR_RETENTION_YEARS must be a whole number of years, got {raw!r}."
        ) from None


def _require_env(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(
            f"{name} is not set. Get it with "
            f"`tofu output -raw {_ENV_SOURCE[name]}` in envs/example/platform."
        )
    return value


def _cmd_case_open(args):
    ddb = boto3.client("dynamodb")
    try:
        record = open_case(
            ddb,
            _require_env("IR_CASES_TABLE"),
            args.case_id,
            retention_years=args.retention_years,
            object_lock_mode=args.object_lock_mode,
        )
    except CaseExistsError as exc:
        raise SystemExit(str(exc)) from exc
    print(json.dumps(record, indent=2))
    return 0


def _cmd_upload(args):
    s3 = boto3.client("s3")
    record = upload_artifact(
        s3,
        _require_env("IR_INTAKE_BUCKET"),
        args.case,
        args.path,
        source=args.source,
    )
    print(json.dumps(record, indent=2))
    print(
        "\nUploaded to intake. The recorder verifies, files and locks it within "
        "a few seconds; poll the artifacts table to confirm.",
        file=sys.stderr,
    )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="irctl", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    case = sub.add_parser("case", help="case lifecycle")
    case_sub = case.add_subparsers(dest="case_command", required=True)

    case_open = case_sub.add_parser("open", help="open a new case")
    case_open.add_argument("case_id")
    case_open.add_argument(
        "--retention-years",
        type=int,
        default=_default_retention_years(),
        help="Defaults to IR_RETENTION_YEARS, else 3 (D10).",
    )
    case_open.add_argument(
        "--object-lock-mode",
        default="GOVERNANCE",
        choices=["GOVERNANCE", "COMPLIANCE"],
        help="COMPLIANCE is irreversible. Never use it outside a production IR account.",
    )
    case_open.set_defaults(func=_cmd_case_open)

    upload = sub.add_parser("upload", help="upload an artifact to intake")
    upload.add_argument("path")
    upload.add_argument("--case", required=True)
    upload.add_argument("--source", help="where the artifact came from, for custody")
    upload.set_defaults(func=_cmd_upload)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
