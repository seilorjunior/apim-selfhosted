#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
if [[ ${1:-} == --help ]]; then
    echo 'Usage: bash scripts/bash/test-load.sh --gateway-url HTTPS_ORIGIN [--expected-gateway-id ID] [--requests-per-second 10] [--duration-seconds 60] [--max-concurrency 10] [--max-p95-milliseconds 2000] [--max-error-rate 0.01] [--output-path FILE]'
    exit 0
fi
parse_options '--gateway-url --expected-gateway-id --requests-per-second --duration-seconds --max-concurrency --max-p95-milliseconds --max-error-rate --output-path' "$@"
require_tools python3
validate_origin "$gateway_url"
integer_range requests-per-second "$requests_per_second" 1 10
integer_range duration-seconds "$duration_seconds" 1 60
integer_range max-concurrency "$max_concurrency" 1 10
integer_range max-p95-milliseconds "$max_p95_milliseconds" 1 60000
if [[ -z $output_path ]]; then
    output_path="$ROOT/TestResults/load-$(date -u +%Y%m%d%H%M%S)-$(python3 -c 'import secrets; print(secrets.token_hex(3))').json"
fi
if python3 "$ROOT/scripts/shared/load_test.py" --url "$gateway_url" \
    --gateway-id "$expected_gateway_id" --rate "$requests_per_second" \
    --duration "$duration_seconds" --concurrency "$max_concurrency" \
    --max-p95-ms "$max_p95_milliseconds" --max-error-rate "$max_error_rate" --output "$output_path"; then
    log "Load-test report: $output_path"
else
    fail "Load test failed. Inspect diagnostics and the report if created: $output_path"
    exit 1
fi
