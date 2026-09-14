#!/usr/bin/env bash
# Portable task runner. The Makefile delegates here so the same logic runs in CI,
# on Linux/macOS, and in Git Bash on Windows (where `make` is generally absent).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODULES=(modules/platform modules/images modules/analysis)

if ! command -v tofu >/dev/null 2>&1; then
  cat >&2 <<'MSG'
error: `tofu` is not on PATH.

  Install:  https://opentofu.org/docs/intro/install/  (pin 1.12.6)
  Windows:  winget install --id=OpenTofu.Tofu -e --version 1.12.6

On Windows, winget updates the User PATH; open a new shell afterwards, or add
the install directory to PATH for this shell.
MSG
  exit 1
fi

fmt() {
  tofu fmt -recursive
}

fmt_check() {
  tofu fmt -recursive -check
}

validate() {
  for m in "${MODULES[@]}"; do
    echo "== validate $m =="
    (cd "$m" && tofu init -backend=false -input=false >/dev/null && tofu validate)
  done
}

lint() {
  if ! command -v tflint >/dev/null 2>&1; then
    echo "tflint not installed; skipping (CI enforces it)" >&2
    return 0
  fi
  tflint --init >/dev/null
  tflint --recursive
}

test_modules() {
  for m in "${MODULES[@]}"; do
    echo "== test $m =="
    (cd "$m" && tofu test)
  done
}

ANALYSIS_ENV="envs/example/analysis"

posture() {
  local want="$1"
  echo "== setting posture=$want in $ANALYSIS_ENV"
  (cd "$ANALYSIS_ENV" && tofu apply -var="posture=$want")
}

usage() {
  echo "usage: $0 {fmt|fmt-check|validate|lint|test|check|dormant|active}" >&2
  exit 2
}

case "${1:-check}" in
  fmt)       fmt ;;
  fmt-check) fmt_check ;;
  validate)  validate ;;
  lint)      lint ;;
  test)      test_modules ;;
  check)     fmt_check; validate; lint; test_modules ;;
  dormant)   posture dormant ;;
  active)    posture active ;;
  *)         usage ;;
esac
