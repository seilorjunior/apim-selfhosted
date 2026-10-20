#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/rollout.sh"
if [[ ${1:-} == --help ]]; then
    echo 'Usage: bash scripts/bash/rollback-gateway.sh --subscription-id ID --resource-group GROUP [--app-name NAME] [--revision-name NAME] [--expected-gateway-id ID] [--timeout-seconds 600] [--what-if] [--yes]'
    exit 0
fi
parse_options '--subscription-id --resource-group --app-name --revision-name --expected-gateway-id --timeout-seconds --what-if --yes' "$@"
require_tools az jq python3 curl
integer_range timeout-seconds "$timeout_seconds" 30 3600
[[ -n $subscription_id && -n $resource_group ]] || { fail 'Subscription and resource group are required.'; exit 1; }
app_id="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.App/containerApps/$app_name"
state=$(gateway_state)
current=$(printf '%s' "$state" | stable_revision)
if [[ -z $revision_name ]]; then
    revision_name=$(jq -er '.tags.shgwPreviousRevision | select(type == "string" and length > 0)' <<<"$state") ||
        { fail 'No previous revision tag found. Supply --revision-name.'; exit 1; }
fi
[[ $revision_name != "$current" ]] || { fail 'Requested revision already receives traffic.'; exit 1; }
[[ $revision_name == "$app_name--"* ]] || { fail 'Revision must belong to this gateway app.'; exit 1; }
revisions=$(gateway_revisions)
target=$(jq -ce --arg name "$revision_name" '[.value[] | select(.name == $name)] | select(length == 1) | .[0]' <<<"$revisions") ||
    { fail "Revision $revision_name does not exist."; exit 1; }
if [[ $what_if == true ]]; then
    log "What if: verify $revision_name and move 100% of gateway traffic to it."
    exit 0
fi
confirm_action "Move 100% of $app_name traffic from $current to $revision_name?"
new_work_directory
rollback_armed=true
rollback_cleanup() {
    local status=$?
    trap - EXIT
    if ((status != 0)) && [[ $rollback_armed == true ]]; then
        if set_traffic "$current" &&
            wait_http "$public_url" "$expected_gateway_id" "$timeout_seconds" smoke; then
            log "Rollback failed; traffic restored to $current and public API verified."
        else
            log 'ERROR: Rollback and traffic restoration failed. Inspect traffic immediately.'
        fi
    fi
    if ! cleanup_work_directory; then log "ERROR: Temporary directory cleanup failed: $work_directory"; status=1; fi
    exit "$status"
}
public_url="https://$(jq -er '.properties.configuration.ingress.fqdn' <<<"$state")"
trap rollback_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ $(jq -r '.properties.active' <<<"$target") != true ]]; then
    revision_action "$revision_name" activate
fi
fqdn=$(wait_revision "$revision_name")
wait_http "https://$fqdn" "$expected_gateway_id" "$timeout_seconds" configuration
wait_http "https://$fqdn" "$expected_gateway_id" "$timeout_seconds" smoke
set_traffic "$revision_name"
wait_http "$public_url" "$expected_gateway_id" "$timeout_seconds" smoke
rollback_armed=false
az_run tag update --resource-id "$app_id" --operation Merge --tags "shgwPreviousRevision=$current" \
    --subscription "$subscription_id" -o none
log "Rollback verified: $revision_name receives 100% of traffic."
