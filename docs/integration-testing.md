# Disposable live integration testing

**Status:** implemented, locally tested with doubles, not yet executed against Azure.
Run this suite only after reviewing its cost and cleanup behavior. Ordinary CI and
pull requests do not run it. Run all commands from the repository root.

## Scenarios

| Step | Required result |
|---|---|
| Provision | New Developer APIM, internal backend, gateway, readiness sidecar in a new resource group |
| Readiness and sample | Exact configuration markers; sample HTTP 200 with gateway identity and nonempty body |
| Authenticated fixture | Test-only `/integration-auth/` API forwards a valid subscription-key request to the backend |
| Rejected requests | Missing and invalid keys return 401; unknown route and unsupported sample POST return 404 |
| Token rotation | Existing rotation command promotes a different revision to 100% traffic |
| Post-rotation | All readiness, positive, authentication, and negative checks still pass |
| Manual rollback | Existing rollback command restores the initial revision to 100% traffic |
| Post-rollback | All route checks still pass |
| Cleanup | Delete only this run's ownership-tagged group and verify it no longer exists |

The fixture uses APIM subscription-key enforcement, not Entra JWT validation. It
does not change authentication on the normal sample API. Rotation issues another
gateway token; it does not revoke the old token. Rollback verifies revision traffic,
not reversal of shared APIM policies or app-level secrets. This suite does not run
the bounded load gate or claim zero downtime, autoscaling, or outage resilience.

## Isolation and costs

- The runner generates `rg-shgw-it-<32-character-run-id>` and refuses an existing
  group, even if its tags match.
- It creates its own Developer APIM. It never accepts an existing APIM, resource
  group, gateway URL, or custom deployment profile.
- Explicit integration parameters prevent local dev-profile overrides from
  pointing the deployment at a shared APIM or subnet.
- Only public Azure is supported. Providers must already be registered.
- Developer APIM provisioning can take 30 to 60 minutes or longer. API Management,
  Container Apps, and logs incur charges until cleanup completes.
- Cleanup requires both `shgwIntegrationRun=<run-id>` and
  `purpose=disposable-integration` tags to match. A mismatch fails rather than
  deleting the group.
- Cleanup runs after deployment/scenario failures. GitHub has a second `always()`
  cleanup step. Process termination, expired credentials, job timeouts, or platform
  failures can prevent cleanup; check Azure after every interrupted run.

## GitHub setup

This repository already has an `integration` environment restricted to the `main`
branch. Azure OIDC federation and environment variables still need configuration.
For a fork, create that GitHub environment and its branch restriction yourself.

1. Merge the workflow into the default branch before expecting it in the manual
   Actions dispatch interface.
2. Create an `integration` GitHub environment. Restrict its allowed deployment
   branch to `main`; add human approval if another reviewer is available.
3. Configure an Entra application or user-assigned managed identity with OIDC:
   - Issuer: `https://token.actions.githubusercontent.com`
   - Audience: `api://AzureADTokenExchange`
   - Subject: `repo:seilorjunior/apim-selfhosted:environment:integration`
4. Use a disposable Azure subscription where possible. The identity needs resource
   group creation/deletion and permission to deploy/manage APIM, Container Apps,
   and Log Analytics. Subscription Contributor is a broad, practical test setup;
   prefer a reviewed custom role for narrower access. Do not reuse a production
   deployment identity.
5. Have an administrator register `Microsoft.ApiManagement`, `Microsoft.App`, and
   `Microsoft.OperationalInsights`. The suite does not register providers.
6. Set these environment variables:

   | Variable | Value |
   |---|---|
   | `AZURE_CLIENT_ID` | OIDC identity client ID |
   | `AZURE_TENANT_ID` | Entra tenant ID |
   | `AZURE_SUBSCRIPTION_ID` | Disposable target subscription |
   | `APIM_PUBLISHER_EMAIL` | Valid APIM publisher email |

7. Open **Actions**, select **Disposable Azure integration**, select `main`, enter
   `CREATE DISPOSABLE RESOURCES`, and choose a region. No client secret is needed.

The workflow serializes live integration runs and has a 240-minute job timeout.
The cleanup retry has a 30-minute timeout within that job, not an additional
guaranteed window after the job timeout. Reports are uploaded even after failure
when the runner remains available.

## Local execution

Use the normal [deployment prerequisites](deployment.md#1-check-prerequisites),
an authenticated Azure CLI session, and the permissions above. On Windows use
PowerShell 7; on POSIX use native Bash with `jq` and `curl`. Both entry points use
the same standard-library Python runner.

PowerShell:

```powershell
$runId = [guid]::NewGuid().ToString('N')
.\scripts\psw\Test-Integration.ps1 -SubscriptionId 'YOUR-SUBSCRIPTION-ID' `
    -PublisherEmail 'you@contoso.com' -RunId $runId -AllowProvisioning
```

Bash:

```bash
run_id="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
bash scripts/bash/test-integration.sh \
  --subscription-id YOUR-SUBSCRIPTION-ID \
  --publisher-email you@contoso.com --run-id "$run_id" --allow-provisioning
```

The explicit acknowledgement is mandatory. Without it the runner exits before
calling Azure. Normal completion includes cleanup; there is no keep-resources mode.

## Reports and cleanup recovery

The runner writes `TestResults/integration-<run-id>.json` with overall pass/fail,
step pass/fail, durations, and the disposable resource group name. Cleanup retries
write a separate `integration-<run-id>-cleanup.json` without overwriting the scenario
report. Keys and HTTP bodies are not included. Reports are ignored by Git.

A passed cleanup retry does not turn a failed scenario report into a success.
Inspect failed Azure deployment operations in the named group when provisioning
fails; CLI responses that could contain credentials are not copied into reports.
Subscription keys stay in memory and are masked in GitHub Actions.

If a run is interrupted or cleanup fails, authenticate again and reuse the exact
run ID shown in the logs, report, or generated resource group name:

```powershell
.\scripts\psw\Test-Integration.ps1 -SubscriptionId 'YOUR-SUBSCRIPTION-ID' `
    -RunId 'PASTE-EXACT-32-CHARACTER-RUN-ID' -AllowProvisioning -CleanupOnly
```

```bash
bash scripts/bash/test-integration.sh --subscription-id YOUR-SUBSCRIPTION-ID \
  --run-id PASTE-EXACT-32-CHARACTER-RUN-ID --allow-provisioning --cleanup-only
```

Recovery refuses groups with missing or different ownership tags. Do not bypass
that check or use a broad subscription cleanup command. Confirm the group is gone
in Azure after an interrupted run.

## Local regression coverage

The ordinary runners include the integration runner's regression tests:

```powershell
.\scripts\psw\Test-Local.ps1
```

```bash
bash scripts/bash/test-local.sh
```

These tests cover orchestration and failure handling with process/HTTP doubles.
They are not evidence of a successful live Azure integration run.
