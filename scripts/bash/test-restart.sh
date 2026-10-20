#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
if [[ ${1:-} == --help ]]; then
    echo 'Usage: bash scripts/bash/test-restart.sh --subscription-id ID --resource-group GROUP --gateway-url HTTPS_ORIGIN [--app-name NAME] [--expected-gateway-id ID] [--timeout-seconds 600] [--what-if] [--yes]'
    exit 0
fi
parse_options '--subscription-id --resource-group --gateway-url --app-name --expected-gateway-id --timeout-seconds --what-if --yes' "$@"
require_tools az jq python3 curl
integer_range timeout-seconds "$timeout_seconds" 30 3600
[[ -n $subscription_id && -n $resource_group && -n $gateway_url ]] ||
    { fail 'Subscription, resource group and gateway origin are required.'; exit 1; }
new_work_directory
trap 'cleanup_work_directory' EXIT
wait_http "$gateway_url" "$expected_gateway_id" "$timeout_seconds" smoke
app_id="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.App/containerApps/$app_name"
state=$(gateway_state)
revision=$(printf '%s' "$state" | stable_revision)
if [[ $what_if == true ]]; then
    log "What if: restart all replicas of $revision (may interrupt traffic)."
    exit 0
fi
confirm_action "Restart all replicas of $revision? This may interrupt traffic."
revision_action "$revision" restart
sleep 15
wait_http "$gateway_url" "$expected_gateway_id" "$timeout_seconds" smoke
