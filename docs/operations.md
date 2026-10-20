# Operations

[Project overview](../README.md). Run commands from the repository root.

## Token rotation

Rotate before expiry; the default token lifetime is 29 days.

```powershell
.\scripts\psw\deploy.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroup $resourceGroup -Environment dev -RotateTokenOnly
```

For prod, supply `-Environment prod` and the production resource group.
Publisher information is not needed for rotation.

- Rotation reads the saved settings from the successful `shgw-infra` deployment.
  Keep that deployment history; rerun a full deployment to recreate it if removed.
- The token API returns a raw token. The script adds `GatewayKey ` exactly once
  before supplying `config.service.auth`.
- A new revision suffix forces the container to consume the updated secret.
  Updating a Container Apps secret alone does not restart existing containers.
- Rotation uses the same controlled multiple-revision rollout described below,
  keeping the serving revision pinned until candidate checks pass.
- Rotation does not regenerate signing keys or immediately revoke old tokens.
- Token files live in an owner-restricted temporary directory and are removed in
  `finally`; Bicep parameters are secure and GitHub Actions masks generated tokens.

Never commit tokens, put them in environment profiles, upload generated parameter
files, or enable CLI debug/HTTP tracing around credentials. Shorter `TokenDays`
values require a correspondingly more frequent rotation schedule.
## Safe rollout and rollback

For an existing healthy gateway, deployment and rotation:

1. Identify the single revision currently receiving 100% traffic and baseline-test
   its public API. Existing manual traffic splits are rejected rather than overwritten.
2. Keep that revision pinned at 100%; create the candidate with 0% public traffic.
3. Wait for the **exact candidate revision** to become healthy, including its
   configuration-aware readiness probe.
4. Check configuration markers and the sample backend through the candidate's
   revision-specific HTTPS FQDN. These candidate endpoints are public under the
   existing ingress configuration.
5. If requested, run the bounded load gate against that candidate.
6. Move 100% of public traffic to the candidate, then smoke-test the public URL.
7. On failure, restore previous traffic, verify the public API, and deactivate the
   failed candidate. Restoration/cleanup errors explicitly fail the command and
   require inspection. On success, retain the current and previous active releases;
   deactivate older releases to avoid accumulating active-revision costs.

**First deployment exception:** no prior release exists. The initial revision
gets 100% traffic and has no rollback target; checks still must pass.

To include the candidate load gate in deployment:

```powershell
.\scripts\psw\deploy.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup `
    -PublisherEmail $publisherEmail -Environment dev -RunLoadTest
```

To preview or perform a later manual rollback:

```powershell
.\scripts\psw\Rollback-Gateway.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroup $resourceGroup -WhatIf

.\scripts\psw\Rollback-Gateway.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroup $resourceGroup
```

Rollback prompts for confirmation and defaults to the app's
`shgwPreviousRevision` tag. Use `-RevisionName` for an explicit revision belonging
to the app. It activates an inactive target if needed, verifies health,
configuration and backend before moving traffic, then verifies the public URL.
On failure it restores and verifies the formerly serving release. A successful
rollback records that release as the next rollback target. For prod, supply
`-AppName ca-apim-gateway-prod -ExpectedGatewayId aca-gateway-prod`.

**Rollback scope:** this restores gateway revision traffic, not APIM API/policy
changes, backend infrastructure, or app-scoped secrets. Those are shared across
revisions. Full deployment updates APIM configuration before candidate creation;
use backward-compatible API/policy changes and separate versioning when needed.
Traffic restoration is not a transaction across Azure resources or a guarantee
of zero downtime.
## Operations and troubleshooting

### Inspect deployments and logs

```powershell
az deployment group show --name shgw-infra `
    --resource-group $resourceGroup --subscription $subscriptionId `
    --query properties.provisioningState --output tsv

az deployment group show --name shgw-gateway `
    --resource-group $resourceGroup --subscription $subscriptionId `
    --query properties.provisioningState --output tsv

az containerapp logs show --name ca-apim-gateway `
    --resource-group $resourceGroup --subscription $subscriptionId `
    --type console --tail 40
```

For production logs, use app name `ca-apim-gateway-prod`. Use `--type system`
for platform events such as startup or revision failures.

| Symptom | What to check |
|---|---|
| Provider not registered | Register the named provider explicitly; the deployment script does not register it silently |
| `bicep` not found | Ensure the standalone executable is on `PATH`, not just callable through `az bicep` |
| Unsupported APIM SKU | Use classic Developer/Premium; prod requires Premium |
| HTTP 200 with empty body and no gateway header | Inspect gateway logs for tenant/configuration startup failure; HTTP 200 alone is not proof of routing |
| `No valid authentication was configured` | Verify the secret includes `GatewayKey ` and rerun rotation with the corrected script |
| Configuration cannot load | Check token expiry, outbound HTTPS/DNS, and `<apim-name>.configuration.azure-api.net` reachability |
| Gateway secret changed but behavior did not | Use token rotation to force a new revision, rather than changing only the secret |
| New revision never becomes ready | Inspect console/system logs; check image, resources, network, and token configuration |
| Rotation cannot find settings | Check subscription/resource group and the `shgw-infra` deployment history |
| Optional CLI extension fails before any command | Repair that extension or use an empty session-specific `AZURE_EXTENSION_DIR`; do not broadly change filesystem permissions |

Startup/liveness probes verify the HTTP listener; readiness uses the sidecar's
configuration assertion. The API smoke test separately verifies backend routing.
If readiness fails, select the `readiness` container when inspecting console logs
and check the `/gateway-health/ready` response markers. The missing authorization-prefix
case was observed and corrected during the initial deployment, and is covered by
regression tests. Older retained revisions can still have their original probes;
they are checked explicitly before manual rollback.

### Restart rehearsal

Run only when a temporary interruption is acceptable:

```powershell
.\scripts\psw\Test-Restart.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroup $resourceGroup -GatewayUrl $gatewayUrl
```

The script prompts before restarting the ready revision and smoke-tests before
and after restart. It restarts all replicas of that revision and proves recovery,
not zero downtime. `-WhatIf` performs the baseline smoke check and previews the
restart without executing it. For prod, also set `-AppName ca-apim-gateway-prod`
and `-ExpectedGatewayId aca-gateway-prod`.

### Configuration-service outage rehearsal

This test is **not automated or executed by the normal test suite**. Use an isolated,
disposable environment with controlled egress; the default deployment does not
create the VNet/firewall needed for fault injection.

1. Pass the live smoke test and record a rollback procedure for the firewall rule.
2. Block only outbound HTTPS to the APIM configuration endpoint. Preserve backend
   connectivity, DNS, and Container Apps platform dependencies.
3. Check whether existing replicas continue serving their in-memory configuration.
   Record results, and verify an APIM policy update does not propagate while blocked.
4. Separately test restart while blocked. There is no persistent configuration
   backup in this project; a replacement replica cannot be assumed to bootstrap
   offline. Record actual startup/API availability rather than trusting status probes.
5. Restore connectivity even if checks fail, rerun smoke checks, and confirm the
   policy update propagates.

Do not run this rehearsal against shared or production environments.
## Costs, limitations, and cleanup

- Budget for APIM, applicable self-hosted gateway billing/licensing, minimum
  Container Apps replicas, Log Analytics ingestion/retention, and optional networking.
- The readiness sidecar adds **0.25 CPU / 0.5 GiB per replica**, in addition to the
  gateway's profile resources (default combined allocation: 1.25 CPU / 2.5 GiB).
  The consumption-only environment limits the combined replica to 2 CPU / 4 GiB;
  the largest gateway-only pair is now 1.75 CPU / 3.5 GiB, not the former 2 / 4.
  Both current and retained previous revisions remain active with their own
  minimum replica counts. Expect additional cost; deactivate an old revision
  manually only when accepting loss of immediate ready rollback.
- Classic Developer is nonproduction. Do not substitute another tier, including
  Premium v2, without verifying current self-hosted gateway support.
- API authentication, private ingress, WAF, custom domains, API access dashboards,
  persistent offline configuration backup, and multi-region failover are not included.
- Container Apps logs are configured; alerting and end-to-end API tracing require
  additional observability design.
- Public ingress, a second replica, and a prod parameter file do not establish a
  complete production security or availability posture.

**Cleanup is destructive.** For a dedicated demo resource group only, inspect its
contents, then use the interactive deletion command if you want to remove it:

```powershell
az resource list --resource-group $resourceGroup --subscription $subscriptionId `
    --query "[].{Name:name,Type:type}" --output table

# Deletes every resource in this group after confirmation:
az group delete --name $resourceGroup --subscription $subscriptionId
```

Do not delete a shared resource group. If APIM was reused in a different group,
deleting the Container Apps group does not remove the API/policy or gateway from
that APIM service; clean up only those project-owned entities separately if needed.
