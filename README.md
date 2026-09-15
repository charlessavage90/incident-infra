# incident-infra

An OpenTofu module that stands up an incident-response analysis environment in a dedicated AWS
account, holds it dormant between incidents at storage-only cost, and returns it to service in
minutes. [Timesketch](https://github.com/google/timesketch) is the timeline database;
[plaso](https://github.com/log2timeline/plaso) does artifact timelining.

There is no public ingress anywhere. Access is SSM port-forward, and the VPC has no route to the
internet — plaso workers handle live malware.

## Status

| Phase | Delivers | State |
|---|---|---|
| 1 | Platform, appliance, dormancy toggle | **Built, acceptance-passed** against a real account |
| 2 | Evidence store: buckets, Object Lock, hashing, manifest, manual ingest | **Built, acceptance-passed** against a real account |
| 3 | Ingest pipeline: Batch worker, Step Functions, routing | Specified, not started |
| 4 | Lifecycle: case close, legal hold, archival, exercise mode | Specified, not started |

## Where to start

| You are | Read |
|---|---|
| An AI agent working here | **`CLAUDE.md`** — conventions, invariants, and the traps that have already cost someone a day |
| Picking up outstanding work | **`NEXT.md`** — open items and handoff notes, and nothing else |
| Asking *why* something is built this way | **`docs/superpowers/specs/2026-09-14-ir-infrastructure-design.md`** — the source of truth. 16 numbered decisions, each recording what was rejected; amendments in §12 |
| Deploying it | **`envs/example/README.md`** |

## Quick start

```bash
bash scripts/check.sh check    # fmt, validate, tflint, tofu test — what CI runs
```

`tofu` 1.12.6 must be on PATH. **No test in this repository touches AWS** — the HCL uses
`mock_provider`, the CLI uses `botocore.Stubber` — so the suite needs no credentials, no network,
and costs nothing. `CLAUDE.md` has the Python suites and the full command set.

## Licence

Not yet chosen. The module is built for internal use with boundaries clean enough to open-source
later (D1); that decision has not been made.
