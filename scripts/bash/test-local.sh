#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
if [[ ${1:-} == --help ]]; then
    echo 'Usage: bash scripts/bash/test-local.sh (Bicep, Bash syntax, Python/runtime and mocked Bash tests; no PowerShell required)'
    exit 0
fi
(($# == 0)) || { fail 'This command takes no arguments.'; exit 1; }
require_tools bicep python3 jq curl
new_work_directory
trap 'cleanup_work_directory' EXIT
bicep build "$ROOT/infra/main.bicep" --outfile "$work_directory/main.json"
bicep build "$ROOT/infra/gateway.bicep" --outfile "$work_directory/gateway.json"
for script in "$SCRIPT_DIR/"*.sh; do bash -n "$script"; done
for suite in shared bash; do
    python3 -B -m unittest discover -s "$ROOT/tests/$suite" -p 'test_*.py' -v
done
log 'Native Bash local checks passed. Run scripts/psw/Test-Local.ps1 separately for Pester coverage.'
