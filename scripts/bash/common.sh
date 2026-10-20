#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
log() { printf '%s\n' "$*" >&2; }
require_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || { fail "Required tool not found: $tool"; return 1; }
    done
}
az_run() {
    command az "$@" || { fail "Azure CLI '$1' failed; see diagnostics above."; return 1; }
}
integer_range() {
    [[ $2 =~ ^[0-9]+$ ]] && (( 10#$2 >= $3 && 10#$2 <= $4 )) ||
        { fail "$1 must be an integer between $3 and $4."; return 1; }
}

parse_options() {
    local allowed=$1 option value
    shift
    subscription_id='' resource_group='' location='eastus2' environment='dev'
    publisher_email='' publisher_name='' parameters_file='' apim_sku=''
    existing_apim_name='' apim_resource_group='' token_days=29 timeout_seconds=600
    gateway_url='' expected_gateway_id='aca-gateway' app_name='ca-apim-gateway'
    revision_name='' requests_per_second=10 duration_seconds=60 max_concurrency=10
    max_p95_milliseconds=2000 max_error_rate=0.01 output_path=''
    validate_only=false rotate_token_only=false run_load_test=false what_if=false yes=false
    while (($#)); do
        option=$1
        case " $allowed " in
            *" $option "*) ;;
            *) fail "Unknown option: $option (use --help)."; return 1 ;;
        esac
        shift
        case "$option" in
            --validate-only) validate_only=true; continue ;;
            --rotate-token-only) rotate_token_only=true; continue ;;
            --run-load-test) run_load_test=true; continue ;;
            --what-if) what_if=true; continue ;;
            --yes) yes=true; continue ;;
        esac
        if (($# == 0)) || [[ $1 == --* ]]; then
            fail "Missing value for $option."; return 1
        fi
        value=$1
        shift
        case "$option" in
            --subscription-id) subscription_id=$value ;;
            --resource-group) resource_group=$value ;;
            --location) location=$value ;;
            --environment) environment=$value ;;
            --publisher-email) publisher_email=$value ;;
            --publisher-name) publisher_name=$value ;;
            --parameters-file) parameters_file=$value ;;
            --apim-sku) apim_sku=$value ;;
            --existing-apim-name) existing_apim_name=$value ;;
            --apim-resource-group) apim_resource_group=$value ;;
            --token-days) token_days=$value ;;
            --timeout-seconds) timeout_seconds=$value ;;
            --gateway-url) gateway_url=$value ;;
            --expected-gateway-id) expected_gateway_id=$value ;;
            --app-name) app_name=$value ;;
            --revision-name) revision_name=$value ;;
            --requests-per-second) requests_per_second=$value ;;
            --duration-seconds) duration_seconds=$value ;;
            --max-concurrency) max_concurrency=$value ;;
            --max-p95-milliseconds) max_p95_milliseconds=$value ;;
            --max-error-rate) max_error_rate=$value ;;
            --output-path) output_path=$value ;;
        esac
    done
}

validate_origin() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit
try:
    url = urlsplit(sys.argv[1])
    valid = (url.scheme == "https" and url.hostname and not url.username
             and not url.password and url.path in ("", "/") and not url.query
             and not url.fragment and url.port != 0)
except ValueError:
    valid = False
if not valid:
    sys.exit("Gateway URL must be an HTTPS origin without a path, credentials, query, or fragment.")
PY
}

new_work_directory() {
    umask 077
    work_directory=$(mktemp -d "${TMPDIR:-/tmp}/apim-shgw.XXXXXXXX") || return 1
}
cleanup_work_directory() {
    local name
    for name in main.json gateway.json infra.parameters.json gateway.parameters.json \
        token-request.json token.txt outputs.json settings.json gateway-outputs.json \
        response.headers response.body; do
        rm -f -- "$work_directory/$name" || return 1
    done
    rmdir -- "$work_directory"
}

wait_http() {
    local origin=$1 identity=$2 timeout=$((10#$3)) kind=$4 started=$SECONDS status path
    validate_origin "$origin" || return 1
    path='/sample/'
    [[ $kind != configuration ]] || path='/gateway-health/ready'
    while :; do
        if status=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
            --proto '=https' --dump-header "$work_directory/response.headers" \
            --output "$work_directory/response.body" --write-out '%{http_code}' \
            "${origin%/}$path"); then
            if python3 - "$work_directory" "$status" "$identity" "$kind" <<'PY'
from email.parser import BytesParser
from pathlib import Path
import sys
directory, status, identity, kind = sys.argv[1:]
raw = (Path(directory) / "response.headers").read_bytes()
block = [part for part in raw.split(b"\r\n\r\n") if part.startswith(b"HTTP/")][-1]
headers = BytesParser().parsebytes(block.split(b"\r\n", 1)[1])
body = (Path(directory) / "response.body").read_bytes()
valid = status == "200" and headers.get("X-Served-By") == identity
if kind == "configuration":
    valid = valid and headers.get("X-Gateway-Ready") == "configured" and body == b"ready"
else:
    valid = valid and bool(body)
sys.exit(0 if valid else 1)
PY
            then
                log "$kind check passed for $identity."
                return 0
            fi
            log "$kind check not ready: HTTP $status or invalid markers/body."
        else
            log "$kind request failed; retrying within timeout."
        fi
        (( SECONDS - started < timeout )) || break
        sleep 5
    done
    fail "$kind check failed after $timeout seconds."
}

gateway_state() {
    az_run resource show --ids "$app_id" --api-version 2024-03-01 \
        --subscription "$subscription_id" -o json
}
stable_revision() {
    jq -er '
      if . == null then ""
      elif .properties.configuration.activeRevisionsMode == "Single" then
        .properties.latestReadyRevisionName | select(type == "string" and length > 0)
      else
        . as $state | [.properties.configuration.ingress.traffic[] | select(.weight > 0)] |
        if length == 1 and .[0].weight == 100 then
          (.[0].revisionName // $state.properties.latestReadyRevisionName) |
          select(type == "string" and length > 0)
        else error("Controlled rollout requires exactly one stable revision with 100% traffic.") end
      end'
}
set_traffic() {
    local revision=$1 state serving
    az_run containerapp ingress traffic set --name "$app_name" --resource-group "$resource_group" \
        --subscription "$subscription_id" --revision-weight "$revision=100" -o none || return 1
    state=$(gateway_state) || return 1
    serving=$(printf '%s' "$state" | stable_revision) || return 1
    [[ $serving == "$revision" ]] || { fail "Traffic did not pin 100% to $revision."; return 1; }
}
gateway_revisions() {
    az_run rest --method get --url \
        "https://management.azure.com$app_id/revisions?api-version=2024-03-01" \
        --subscription "$subscription_id" -o json
}
revision_action() {
    az_run rest --method post --url \
        "https://management.azure.com$app_id/revisions/$1/$2?api-version=2024-03-01" \
        --subscription "$subscription_id" -o none
}
wait_revision() {
    local name=$1 started=$SECONDS revision
    while :; do
        revision=$(az_run rest --method get --url \
            "https://management.azure.com$app_id/revisions/$name?api-version=2024-03-01" \
            --subscription "$subscription_id" --query properties -o json) || return 1
        if [[ $(jq -r '.provisioningState' <<<"$revision") == Failed ]]; then
            fail "Gateway revision $name provisioning failed."; return 1
        fi
        if jq -e '.healthState == "Healthy" and .provisioningState == "Provisioned"' \
            <<<"$revision" >/dev/null; then
            jq -er '.fqdn | select(type == "string" and length > 0)' <<<"$revision"
            return
        fi
        log "Waiting for healthy revision $name..."
        (( SECONDS - started < 10#$timeout_seconds )) || break
        sleep 5
    done
    fail "Gateway revision $name did not become healthy within $timeout_seconds seconds."
}
confirm_action() {
    local answer
    log "$1"
    [[ $yes != true ]] || return 0
    if [[ ! -t 0 ]]; then fail 'Interactive confirmation required; use --yes for automation.'; return 1; fi
    read -r -p 'Type yes to continue: ' answer
    [[ $answer == yes ]] || { fail 'Operation cancelled.'; return 1; }
}
