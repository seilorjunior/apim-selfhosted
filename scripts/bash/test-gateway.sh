#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
if [[ ${1:-} == --help ]]; then
    echo 'Usage: bash scripts/bash/test-gateway.sh --gateway-url HTTPS_ORIGIN [--expected-gateway-id ID] [--timeout-seconds 60]'
    exit 0
fi
parse_options '--gateway-url --expected-gateway-id --timeout-seconds' "$@"
require_tools python3 curl
integer_range timeout-seconds "$timeout_seconds" 1 3600
[[ -n $gateway_url ]] || { fail '--gateway-url is required.'; exit 1; }
new_work_directory
trap 'cleanup_work_directory' EXIT
wait_http "$gateway_url" "$expected_gateway_id" "$timeout_seconds" configuration
wait_http "$gateway_url" "$expected_gateway_id" "$timeout_seconds" smoke
