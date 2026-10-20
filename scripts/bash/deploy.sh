#!/usr/bin/env bash
set +x
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/rollout.sh"
if [[ ${1:-} == --help ]]; then
    cat <<'HELP'
Usage: bash scripts/bash/deploy.sh [options]
  --subscription-id ID       Azure subscription (otherwise current CLI account)
  --resource-group NAME      Default: rg-apim-selfhosted or rg-apim-selfhosted-prod
  --location REGION          Default: eastus2
  --environment dev|prod     Default: dev
  --publisher-email EMAIL    Required for a new APIM on full deploy/validation
  --publisher-name NAME
  --parameters-file FILE     Default: infra/parameters/<environment>.parameters.json
  --apim-sku Developer|Premium
  --existing-apim-name NAME
  --apim-resource-group NAME
  --token-days 1..30          Default: 29
  --timeout-seconds 30..3600  Default: 600
  --validate-only            Provider validation and what-if; no token or deployment
  --rotate-token-only        Reuse shgw-infra outputs; create a gateway revision
  --run-load-test            Gate candidate promotion on bounded 10 RPS / 60s test
HELP
    exit 0
fi
parse_options '--subscription-id --resource-group --location --environment --publisher-email --publisher-name --parameters-file --apim-sku --existing-apim-name --apim-resource-group --token-days --timeout-seconds --validate-only --rotate-token-only --run-load-test' "$@"
require_tools az bicep python3 jq curl
integer_range token-days "$token_days" 1 30
integer_range timeout-seconds "$timeout_seconds" 30 3600
[[ $environment == dev || $environment == prod ]] || { fail 'Environment must be dev or prod.'; exit 1; }
[[ $validate_only != true || $rotate_token_only != true ]] ||
    { fail 'Choose --validate-only or --rotate-token-only, not both.'; exit 1; }
if [[ -z $resource_group ]]; then
    resource_group='rg-apim-selfhosted'
    [[ $environment != prod ]] || resource_group='rg-apim-selfhosted-prod'
fi
parameters_file=${parameters_file:-"$ROOT/infra/parameters/$environment.parameters.json"}
new_work_directory
rollback_armed=false previous_revision='' candidate_revision=''
deployment_cleanup() {
    local status=$?
    trap - EXIT
    if ((status != 0)) && [[ $rollback_armed == true ]]; then
        log "Rollout failed (exit $status). Restoring previous traffic..."
        if ! restore_rollout; then
            log 'ERROR: Restoration/cleanup also failed or no rollback target exists. Inspect traffic immediately.'
        fi
    fi
    if ! cleanup_work_directory; then
        log "ERROR: Could not remove private temporary directory: $work_directory"
        status=1
    fi
    exit "$status"
}
trap deployment_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

jq --arg location "$location" --arg email "$publisher_email" --arg publisher "$publisher_name" \
    --arg sku "$apim_sku" --arg existing "$existing_apim_name" --arg group "$apim_resource_group" '
    .parameters.location = {value:$location} |
    if $email != "" then .parameters.publisherEmail = {value:$email} else . end |
    if $publisher != "" then .parameters.publisherName = {value:$publisher} else . end |
    if $sku != "" then .parameters.apimSku = {value:$sku} else . end |
    if $existing != "" then .parameters.existingApimName = {value:$existing} else . end |
    if $group != "" then .parameters.apimResourceGroup = {value:$group} else . end
' "$parameters_file" > "$work_directory/infra.parameters.json"
jq -e --arg env "$environment" --arg group "$resource_group" --argjson rotation "$rotate_token_only" '
    .parameters as $p |
    ($p.existingApimName.value // "") as $existing |
    ($p.apimSku.value // "Developer") as $sku |
    ($p.gatewayMinReplicas.value // (if $env == "prod" then 2 else 1 end)) as $min |
    ($p.gatewayMaxReplicas.value // 3) as $max |
    ($p.gatewayCpu.value // "1.0") as $cpu |
    ($p.gatewayMemory.value // "2Gi") as $memory |
    if $p.environmentName.value != $env then error("Parameter file environmentName must match environment.")
    elif $existing == "" and ($rotation | not) and
      (($p.publisherEmail.value // "" | test("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")) | not)
      then error("Publisher email is required and must be valid for a new APIM.")
    elif $existing == "" and ($rotation | not) and ($p.apimResourceGroup.value // $group) != $group
      then error("A new APIM must be in the deployment resource group.")
    elif (["Developer","Premium"] | index($sku)) == null then error("Only classic Developer and Premium are supported.")
    elif $env == "prod" and $existing == "" and $sku != "Premium" then error("Production requires classic Premium APIM.")
    elif ($min | type) != "number" or ($max | type) != "number" then error("Replica bounds must be integers.")
    elif $min != ($min|floor) or $max != ($max|floor) or $min < 1 or $max < $min or ($env == "prod" and $min < 2)
      then error("Invalid replica bounds.")
    elif ({"0.5":"1Gi","1.0":"2Gi","1.75":"3.5Gi"}[$cpu]) != $memory
      then error("Unsupported gateway CPU/memory pair; reserve 0.25 CPU/0.5Gi for readiness.")
    elif ($p.zoneRedundant.value // false) and ($p.infrastructureSubnetId.value // "") == ""
      then error("Zone redundancy requires an existing infrastructure subnet.")
    else true end
' "$work_directory/infra.parameters.json" >/dev/null

account_args=(account show -o json)
[[ -z $subscription_id ]] || account_args+=(--subscription "$subscription_id")
account=$(az_run "${account_args[@]}")
[[ $(jq -r '.environmentName' <<<"$account") == AzureCloud ]] ||
    { fail 'This project targets Azure public cloud only.'; exit 1; }
subscription_id=$(jq -er '.id' <<<"$account")
log "Subscription: $subscription_id; resource group: $resource_group; region: $location; profile: $environment"
for provider in Microsoft.ApiManagement Microsoft.App Microsoft.OperationalInsights; do
    state=$(az_run provider show --namespace "$provider" --subscription "$subscription_id" --query registrationState -o tsv)
    [[ $state == Registered ]] || { fail "Provider $provider is not registered. Register it explicitly before deploying."; exit 1; }
done
existing_apim_name=$(jq -r '.parameters.existingApimName.value // ""' "$work_directory/infra.parameters.json")
if [[ -n $existing_apim_name ]]; then
    apim_group=$(jq -r --arg group "$resource_group" '.parameters.apimResourceGroup.value // $group' "$work_directory/infra.parameters.json")
    service=$(az_run resource show --ids "/subscriptions/$subscription_id/resourceGroups/$apim_group/providers/Microsoft.ApiManagement/service/$existing_apim_name" \
        --api-version 2024-05-01 --subscription "$subscription_id" -o json)
    sku=$(jq -r '.sku.name' <<<"$service")
    [[ $sku == Developer || $sku == Premium ]] || { fail 'Existing APIM must use classic Developer or Premium.'; exit 1; }
    [[ $environment != prod || $sku == Premium ]] || { fail 'Production requires classic Premium APIM.'; exit 1; }
fi
bicep build "$ROOT/infra/main.bicep" --outfile "$work_directory/main.json"
bicep build "$ROOT/infra/gateway.bicep" --outfile "$work_directory/gateway.json"
exists=$(az_run group exists -n "$resource_group" --subscription "$subscription_id" -o tsv)
case "$exists" in
    false)
        [[ $validate_only != true && $rotate_token_only != true ]] ||
            { fail 'Resource group must exist for validation or rotation.'; exit 1; }
        az_run group create -n "$resource_group" -l "$location" --subscription "$subscription_id" -o none ;;
    true) ;;
    *) fail 'Azure returned an invalid resource group existence response.'; exit 1 ;;
esac
deployment_args=(--resource-group "$resource_group" --subscription "$subscription_id")
if [[ $rotate_token_only != true ]]; then
    infra_args=("${deployment_args[@]}" --template-file "$work_directory/main.json" --parameters "@$work_directory/infra.parameters.json")
    az_run deployment group validate "${infra_args[@]}" --validation-level Provider -o none
    az_run deployment group what-if "${infra_args[@]}" --validation-level Provider --no-pretty-print
    if [[ $validate_only == true ]]; then
        log 'Validation complete. No resources deployed. Gateway provider validation runs during deployment.'
        exit 0
    fi
    az_run deployment group create "${infra_args[@]}" -n shgw-infra --query properties.outputs -o json > "$work_directory/outputs.json"
else
    az_run deployment group show "${deployment_args[@]}" -n shgw-infra --query properties.outputs -o json > "$work_directory/outputs.json"
fi
jq -e --arg env "$environment" '.gatewaySettings.value.tags.environment == $env' "$work_directory/outputs.json" >/dev/null ||
    { fail 'Stored deployment environment does not match requested profile.'; exit 1; }
jq '.gatewaySettings.value' "$work_directory/outputs.json" > "$work_directory/settings.json"
app_name=$(jq -er '.appName' "$work_directory/settings.json")
expected_gateway_id=$(jq -er '.gatewayName.value' "$work_directory/outputs.json")
app_id="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.App/containerApps/$app_name"
existing_id=$(az_run resource list --resource-group "$resource_group" --subscription "$subscription_id" \
    --resource-type Microsoft.App/containerApps --query "[?name=='$app_name'].id | [0]" -o tsv)
if [[ -n $existing_id ]]; then
    state=$(gateway_state)
    previous_revision=$(printf '%s' "$state" | stable_revision)
    wait_http "https://$(jq -er '.properties.configuration.ingress.fqdn' <<<"$state")" \
        "$expected_gateway_id" "$timeout_seconds" smoke
    log "Keeping $previous_revision at 100% public traffic while candidate is verified."
fi
expiry=$(python3 - "$token_days" <<'PY'
from datetime import datetime, timedelta, timezone
import sys
print((datetime.now(timezone.utc) + timedelta(days=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)
jq -n --arg expiry "$expiry" '{keyType:"primary",expiry:$expiry}' > "$work_directory/token-request.json"
gateway_id=$(jq -er '.gatewayId.value' "$work_directory/outputs.json")
az_run rest --method post --url "https://management.azure.com$gateway_id/generateToken?api-version=2024-05-01" \
    --body "@$work_directory/token-request.json" --subscription "$subscription_id" \
    --query value -o tsv > "$work_directory/token.txt"
python3 - "$work_directory/token.txt" <<'PY'
from pathlib import Path
import os
import sys
path = Path(sys.argv[1])
token = path.read_text(encoding="utf-8").strip()
if not token:
    sys.exit("APIM returned an empty gateway token.")
if os.environ.get("GITHUB_ACTIONS") == "true":
    masked = token.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::add-mask::{masked}")
path.write_text(token if token.startswith("GatewayKey ") else "GatewayKey " + token, encoding="utf-8")
PY
suffix=$(python3 -c 'from datetime import datetime, timezone; import secrets; print("r" + datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S") + "-" + secrets.token_hex(3))')
candidate_revision="$app_name--$suffix"
jq -n --slurpfile outputs "$work_directory/outputs.json" --slurpfile settings "$work_directory/settings.json" \
    --rawfile token "$work_directory/token.txt" --arg suffix "$suffix" --arg previous "$previous_revision" '
    $outputs[0] as $o | $settings[0] as $s |
    {"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
     contentVersion:"1.0.0.0", parameters:(
      {environmentId:{value:$o.environmentId.value},
       configurationEndpoint:{value:("https://" + $o.apimName.value + ".configuration.azure-api.net")},
       expectedGatewayId:{value:$o.gatewayName.value}, previousRevision:{value:$previous},
       gatewayToken:{value:$token}, revisionSuffix:{value:$suffix}} +
      ($s | with_entries(select(.key as $key | ["appName","location","imageTag","minReplicas",
         "maxReplicas","concurrentRequests","cpu","memory","tags"] | index($key))) |
         with_entries(.value = {value:.value}))
     )}
' > "$work_directory/gateway.parameters.json"
gateway_args=("${deployment_args[@]}" --template-file "$work_directory/gateway.json" --parameters "@$work_directory/gateway.parameters.json")
az_run deployment group validate "${gateway_args[@]}" --validation-level Provider -o none
invoke_rollout
log "Token expires: $expiry. Schedule rotation before expiry; signing keys were not regenerated."
