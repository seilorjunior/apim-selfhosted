#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

restore_rollout() {
    local state public_url revisions
    if [[ -z $previous_revision ]]; then
        fail 'First deployment failed: no previous revision exists for rollback.'
        return 1
    fi
    set_traffic "$previous_revision" || return 1
    state=$(gateway_state) || return 1
    public_url="https://$(jq -er '.properties.configuration.ingress.fqdn' <<<"$state")"
    wait_http "$public_url" "$expected_gateway_id" "$timeout_seconds" smoke || return 1
    log "Traffic restored to $previous_revision and public API verified."
    revisions=$(gateway_revisions) || return 1
    if jq -e --arg candidate "$candidate_revision" \
        '.value[] | select(.name == $candidate and .properties.active)' <<<"$revisions" >/dev/null; then
        revision_action "$candidate_revision" deactivate || return 1
    fi
}

invoke_rollout() {
    local fqdn public_url revisions name
    rollback_armed=true
    az_run deployment group create "${gateway_args[@]}" -n shgw-gateway \
        --query properties.outputs -o json > "$work_directory/gateway-outputs.json"
    candidate_revision=$(jq -er '.revisionName.value' "$work_directory/gateway-outputs.json")
    fqdn=$(wait_revision "$candidate_revision")
    wait_http "https://$fqdn" "$expected_gateway_id" "$timeout_seconds" configuration
    wait_http "https://$fqdn" "$expected_gateway_id" "$timeout_seconds" smoke
    if [[ $run_load_test == true ]]; then
        bash "$SCRIPT_DIR/test-load.sh" --gateway-url "https://$fqdn" \
            --expected-gateway-id "$expected_gateway_id"
    fi
    log "Candidate $candidate_revision passed checks. Promoting..."
    set_traffic "$candidate_revision"
    public_url="https://$(jq -er '.gatewayFqdn.value' "$work_directory/gateway-outputs.json")"
    wait_http "$public_url" "$expected_gateway_id" "$timeout_seconds" smoke
    rollback_armed=false
    revisions=$(gateway_revisions)
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        revision_action "$name" deactivate
    done < <(jq -r --arg current "$candidate_revision" --arg previous "$previous_revision" \
        '.value[] | select(.properties.active and .name != $current and .name != $previous) | .name' <<<"$revisions")
    log "Verified gateway: $public_url"
}
