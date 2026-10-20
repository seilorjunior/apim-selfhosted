# Deployment

[Project overview](../README.md). Run commands from the repository root.

## Quick start

```powershell
git clone https://github.com/seilorjunior/apim-selfhosted.git
cd apim-selfhosted
```

### 1. Check prerequisites

The quick-start examples below use **PowerShell 7.2 or later** from the project
root. Linux/macOS users can follow the [native Bash commands](#powershell-and-native-bash-commands).

| Tool or permission | Requirement |
|---|---|
| Azure CLI | Version 2.76+ for provider-level ARM validation |
| Bicep CLI | `bicep` executable available on `PATH` |
| Pester | Version 5+ for local regression tests |
| Python | Version 3.12+ on `PATH` as `python`; standard library only |
| Azure access | Permission to deploy resources and generate APIM gateway tokens |
| Azure cloud | Public Azure; sovereign clouds are not configured |

```powershell
$PSVersionTable.PSVersion
az version
bicep --version
Get-Module -ListAvailable Pester
python --version
```

If Bicep is missing, install it with `az bicep install` and add its installation
directory to `PATH`. For the default Windows Azure CLI installation:

```powershell
az bicep install
$env:Path = "$(Join-Path $HOME '.azure\bin');$env:Path"
bicep --version
```

If Pester 5+ is missing:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
```

A practical deployment identity needs Contributor on the target resource group,
plus permission to read provider registrations at subscription scope. When reusing
APIM in another resource group, it also needs appropriate access there.
The token operation requires
`Microsoft.ApiManagement/service/gateways/generateToken/action`; Contributor
includes it. Use narrower custom roles where required. Creating a resource group
or registering providers requires additional subscription-level permission.

### 2. Sign in and choose your target

Replace the example values before running:

```powershell
az login
az account list --query "[].{Name:name,Subscription:id}" --output table

$subscriptionId = 'YOUR-SUBSCRIPTION-ID'
$publisherEmail = 'you@contoso.com'
$resourceGroup = 'rg-apim-selfhosted'
$location = 'eastus2'
```

### 3. Register providers and create the resource group

Skip registration if the providers are already registered. An administrator can
perform this step if your deployment identity is resource-group scoped.

```powershell
foreach ($provider in @(
    'Microsoft.ApiManagement',
    'Microsoft.App',
    'Microsoft.OperationalInsights'
)) {
    az provider register --namespace $provider `
        --subscription $subscriptionId --wait
    if ($LASTEXITCODE -ne 0) { throw "Provider registration failed: $provider" }
}

az group create --name $resourceGroup --location $location `
    --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) { throw 'Resource-group creation failed.' }
```

### 4. Validate and review the preview

```powershell
$deployment = @{
    SubscriptionId = $subscriptionId
    PublisherEmail = $publisherEmail
    ResourceGroup  = $resourceGroup
    Location       = $location
    Environment    = 'dev'
}

.\scripts\psw\Test-Local.ps1
.\scripts\psw\deploy.ps1 @deployment -ValidateOnly
```

Validation builds both Bicep entry points, checks provider registrations, runs
ARM validation with `--validation-level Provider`, and previews infrastructure
changes with what-if. It does not generate a token or deploy resources.
The resource group must already exist.

Gateway provider validation runs during deployment, after the Container Apps
environment exists. What-if does not guarantee capacity, quota, or successful
runtime startup.

### 5. Deploy

**This step creates billable resources.** Initial APIM provisioning can take
30-60 minutes or longer.

```powershell
.\scripts\psw\deploy.ps1 @deployment
```

The script validates and previews changes again, then proceeds without an
interactive approval prompt:

1. Deploy infrastructure, the backend, and APIM API configuration as `shgw-infra`.
2. Generate a gateway token, valid for 29 days by default.
3. Add the required `GatewayKey ` authorization prefix.
4. Validate and deploy the gateway as `shgw-gateway`, using a fresh revision suffix.
5. Wait for that exact revision to become ready.
6. Verify `/sample/` returns HTTP 200 and the expected `X-Served-By` header.

Success ends with `Verified gateway: https://...; token expires: ...`.
A successful ARM deployment alone is **not** considered a successful smoke test.

### 6. Call the API

Retrieve the gateway address without exposing credentials:

```powershell
$gatewayFqdn = az deployment group show --name shgw-gateway `
    --resource-group $resourceGroup --subscription $subscriptionId `
    --query properties.outputs.gatewayFqdn.value --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Gateway lookup failed.' }
$gatewayUrl = "https://$gatewayFqdn"

curl.exe -i "$gatewayUrl/sample/"
```

Expect HTML from the backend, HTTP 200, and `X-Served-By: aca-gateway`.
The header is a diagnostic routing check, not an authentication mechanism.
## PowerShell and native Bash commands

Scripts are organized by shell:

| Operation | PowerShell 7.2+ | Native Bash |
|---|---|---|
| Deploy, validate, rotate | [scripts/psw/deploy.ps1](../scripts/psw/deploy.ps1) | [scripts/bash/deploy.sh](../scripts/bash/deploy.sh) |
| Local tests | [scripts/psw/Test-Local.ps1](../scripts/psw/Test-Local.ps1) | [scripts/bash/test-local.sh](../scripts/bash/test-local.sh) |
| Live checks | [scripts/psw/Test-Gateway.ps1](../scripts/psw/Test-Gateway.ps1) | [scripts/bash/test-gateway.sh](../scripts/bash/test-gateway.sh) |
| Bounded load | [scripts/psw/Test-Load.ps1](../scripts/psw/Test-Load.ps1) | [scripts/bash/test-load.sh](../scripts/bash/test-load.sh) |
| Manual rollback | [scripts/psw/Rollback-Gateway.ps1](../scripts/psw/Rollback-Gateway.ps1) | [scripts/bash/rollback-gateway.sh](../scripts/bash/rollback-gateway.sh) |
| Restart rehearsal | [scripts/psw/Test-Restart.ps1](../scripts/psw/Test-Restart.ps1) | [scripts/bash/test-restart.sh](../scripts/bash/test-restart.sh) |

### Folder organization and updated paths

PowerShell scripts live only in `scripts/psw/`, Bash scripts in `scripts/bash/`,
and the shared Python load engine in `scripts/shared/`. There are no entry-point
wrappers at the repository root or directly under `scripts/`. Both shells use the
same Bicep, parameter profiles and Python load engine. Bash has native
orchestration and does not call `pwsh`.
Tests follow the same organization: `tests/psw/` contains Pester suites,
`tests/bash/` contains the Python-based native Bash behavior harness, and
`tests/shared/` contains shared Python runtime and folder-layout tests.
Helper files (`Common.ps1`/`common.sh` and `Rollout.ps1`/`rollout.sh`) are sourced
by their entry points rather than executed independently.

Update local commands, editor tasks and external automation that used the old
paths. Those paths have been removed; they no longer forward to the new scripts.

| Former path | Current path |
|---|---|
| `deploy.ps1` | [scripts/psw/deploy.ps1](../scripts/psw/deploy.ps1) |
| `scripts/*.ps1` | [scripts/psw/](../scripts/psw/) |
| `scripts/load_test.py` | [scripts/shared/load_test.py](../scripts/shared/load_test.py) |
| `tests/*.Tests.ps1` | [tests/psw/](../tests/psw/) |
| `tests/test_bash.py` | [tests/bash/test_bash.py](../tests/bash/test_bash.py) |
| `tests/test_runtime.py` | [tests/shared/test_runtime.py](../tests/shared/test_runtime.py) |

Test runners discover suites in these subfolders. Running Python discovery only
against the top-level `tests` directory is not the supported entry point; use
the runners below or select a suite explicitly. The folder-layout regression
tests prevent loose scripts and test files from returning to the parent folders.
Generated load reports remain under ignored `TestResults/`.

### Bash prerequisites and deployment

Use Bash 3.2+ on Linux/macOS (or a Linux distribution in WSL), Azure CLI 2.76+,
standalone `bicep`, Python 3.12+ as `python3`, `curl`, and `jq`. Install them with
your platform's package manager or official installers. Pester and PowerShell are
not required for the native Bash commands. The hosted runtime image remains
unchanged.

```bash
az version
bicep --version
python3 --version
jq --version
curl --version
az login

subscription_id='YOUR-SUBSCRIPTION-ID'
resource_group='rg-apim-selfhosted'
location='eastus2'
publisher_email='you@contoso.com'

# Run local checks before any Azure deployment.
bash scripts/bash/test-local.sh

# Read-only validation requires an existing resource group.
# Create a dedicated demo group first if needed:
az group create --name "$resource_group" --location "$location" \
  --subscription "$subscription_id"

bash scripts/bash/deploy.sh \
  --subscription-id "$subscription_id" --resource-group "$resource_group" \
  --location "$location" --publisher-email "$publisher_email" --validate-only

# After reviewing validation/what-if, deploy with the candidate load gate.
bash scripts/bash/deploy.sh \
  --subscription-id "$subscription_id" --resource-group "$resource_group" \
  --location "$location" --publisher-email "$publisher_email" --run-load-test
```

Provider registration and Azure permissions are the same as for PowerShell;
Bash refuses unregistered providers rather than registering them silently.
Use `--environment prod` with a production resource group for the prod profile.
Use `--existing-apim-name` and optionally `--apim-resource-group` to reuse APIM,
or `--parameters-file` for a custom JSON profile. Run an entry point with
`--help` for all its options. Unknown options, missing values and invalid bounds
fail explicitly.

```bash
# Rotate using settings from the successful shgw-infra deployment.
bash scripts/bash/deploy.sh \
  --subscription-id "$subscription_id" --resource-group "$resource_group" \
  --rotate-token-only
```

Deployment uses owner-restricted temporary files, prefixes `GatewayKey ` exactly
once, and removes generated credentials on exit. Do not run deployment with shell
tracing or Azure CLI debug logging. The candidate stays at 0% traffic until its
configuration, backend and optional load checks pass. Failure restores and
verifies previous traffic, with the same first-deployment and shared-configuration
limitations described in [safe rollout](operations.md#safe-rollout-and-rollback).

### Bash testing

```bash
fqdn=$(az containerapp show --name ca-apim-gateway \
  --resource-group "$resource_group" --subscription "$subscription_id" \
  --query properties.configuration.ingress.fqdn --output tsv) || exit 1
test -n "$fqdn" || exit 1
gateway_url="https://$fqdn"

# Checks both exact configuration readiness and a nonempty sample API response.
bash scripts/bash/test-gateway.sh --gateway-url "$gateway_url" \
  --expected-gateway-id aca-gateway --timeout-seconds 60

# Inspect the HTTP status: both negative-route responses should be 404.
curl -i "$gateway_url/not-found"
curl -i -X POST "$gateway_url/sample/"

# Short run, followed by the full bounded test if appropriate.
bash scripts/bash/test-load.sh --gateway-url "$gateway_url" --duration-seconds 10
bash scripts/bash/test-load.sh --gateway-url "$gateway_url" \
  --requests-per-second 10 --duration-seconds 60 --max-concurrency 10

# Use the exact report path printed by the command.
jq '{passed, startedRequests, failedRequests, droppedRequests, droppedByReason,
     errorRate, p95Ms, p99Ms}' TestResults/load-REPLACE-WITH-PRINTED-FILENAME.json
```

For prod, add `--expected-gateway-id aca-gateway-prod` and use
`ca-apim-gateway-prod` for address discovery and operational commands. Bash uses
the same load limits, default thresholds, report format and nonzero failure
status as PowerShell. See [load report troubleshooting](testing.md#read-a-load-report-and-investigate-failures).

The Bash local runner builds both templates, checks shell syntax, runs the shared
Python runtime tests and native Bash behavior tests with mocked Azure, Bicep and
HTTP commands. It does not execute the Pester suite or make Azure changes.
Windows PowerShell tests explicitly skip POSIX Bash tests; CI runs those on
Ubuntu. Native Bash orchestration is tested on Linux; macOS uses the same portable
commands but has not been exercised here.

### Bash rollback and restart safety

```bash
# Read-only previews do not activate, restart or change traffic.
bash scripts/bash/rollback-gateway.sh \
  --subscription-id "$subscription_id" --resource-group "$resource_group" --what-if

bash scripts/bash/test-restart.sh \
  --subscription-id "$subscription_id" --resource-group "$resource_group" \
  --gateway-url "$gateway_url" --what-if
```

Remove `--what-if` to execute with interactive confirmation. Both commands require
typing `yes`; automation must explicitly pass `--yes`. Restart can interrupt all
replicas of the serving revision. Rollback resolves the recorded previous release
unless `--revision-name` is provided, checks it before switching traffic, and
restores the formerly serving release if rollback fails.
## Deployment options

### Dev and production profiles

| Setting | Dev | Prod |
|---|---|---|
| APIM tier | Classic Developer | Classic Premium |
| Default resource group | `rg-apim-selfhosted` | `rg-apim-selfhosted-prod` |
| Gateway app | `ca-apim-gateway` | `ca-apim-gateway-prod` |
| Gateway ID | `aca-gateway` | `aca-gateway-prod` |
| Backend app | `ca-backend` | `ca-backend-prod` |
| Gateway replicas | 1-3 | 2-6 |
| Gateway CPU / memory | 1 CPU / 2 GiB | 1 CPU / 2 GiB |
| HTTP scaling concurrency | 50 | 50 |
| Zone redundancy | Disabled | Disabled |

```powershell
.\scripts\psw\deploy.ps1 -SubscriptionId $subscriptionId `
    -PublisherEmail $publisherEmail -Environment prod -Location $location
```

A full deployment can create a missing resource group if the caller has permission.
For a production validation-only preview, create the production resource group
first and pass `-Environment prod -ValidateOnly` with the same target values.

Developer has no production SLA. Two gateway replicas are not equivalent to
availability-zone redundancy or a tested high-availability design.

### Reuse an existing APIM service

```powershell
.\scripts\psw\deploy.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroup $resourceGroup -Location $location `
    -ExistingApimName 'my-existing-apim' `
    -ApimResourceGroup 'rg-existing-apim'
```

No publisher email is required. The service must be in the same subscription and
use classic Developer or Premium; prod requires Premium. The script reads the
actual existing SKU before proceeding.

The APIM service itself is not redeclared, but the API module **does manage**
`sample-api`, its policy, and the configured gateway. Check these names first:
deploying over matching resources can replace their configuration.

### Rerun safely

Infrastructure and gateway use separate **incremental** deployments. Deploying
infrastructure alone does not clear the existing gateway token or remove the
gateway app. Full deployment manages the sample API, policy, backend, and gateway.
Do not use complete deployment mode for these entry points.
## Configuration

Start with the [dev profile](../infra/parameters/dev.parameters.json) or
[prod profile](../infra/parameters/prod.parameters.json). To keep local overrides
outside version control:

```powershell
Copy-Item .\infra\parameters\dev.parameters.json `
    .\infra\parameters\dev.local.parameters.json

# Edit the copied ARM parameter file, then:
.\scripts\psw\deploy.ps1 @deployment `
    -ParametersFile .\infra\parameters\dev.local.parameters.json
```

The file's `environmentName` must match `-Environment`. Command-line values for
publisher email/name, APIM SKU, existing APIM name, and APIM resource group
override file values when supplied. `-Location` always sets location.

| Parameter | Purpose |
|---|---|
| `baseName`, `gatewayName`, `gatewayAppName`, `backendAppName` | Resource naming |
| `tags` | Custom resource tags; project/environment tags are set by the template |
| `gatewayImageTag`, `backendImage` | Explicit gateway version and pinned backend image |
| `gatewayMinReplicas`, `gatewayMaxReplicas` | Scaling bounds; prod requires at least two minimum replicas |
| `gatewayConcurrentRequests` | HTTP concurrency scaling threshold |
| `gatewayCpu`, `gatewayMemory` | Gateway-only pairs: `0.5`/`1Gi`, `1.0`/`2Gi`, `1.75`/`3.5Gi`; readiness adds `0.25`/`0.5Gi` |
| `zoneRedundant`, `infrastructureSubnetId` | Opt-in zonal environment using an existing suitable subnet |
| Script `TokenDays` | Token validity, 1-30 days; default 29 |
| Script `TimeoutSeconds` | Revision-readiness and smoke-test polling budgets; default 600 seconds each |

Concurrency 50 is a starting configuration, not a measured capacity limit.
Load-test representative APIs before selecting production scaling settings.
`TimeoutSeconds` does not limit the total duration of APIM provisioning.

Zone redundancy requires a supported region and a suitable dedicated infrastructure
subnet. This template uses a consumption-only environment, requiring at least /23
for VNet integration. Validate current regional/network requirements first.
Zone redundancy cannot be enabled in place on an existing environment. Neither
profile creates a VNet or enables private gateway ingress.

### Replace the sample API

The [OpenAPI 3.0 contract](../api/sample.openapi.json) is version `1.0.0`.
The [API module](../infra/modules/api.bicep) imports it, sets the internal backend URL,
applies the [policy](../api/policies/sample.xml), and assigns the API to the gateway.

When adopting a real API, update the contract, backend mapping, API name/path,
policies, and smoke-test expectations together. An OpenAPI document version does
not automatically create an APIM API version set. The diagnostic header uses
`context.Deployment.Gateway.Id`, not the APIM service name.
