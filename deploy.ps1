#Requires -Version 7.2
[CmdletBinding()]
param(
    [string] $PublisherEmail,
    [string] $PublisherName,
    [string] $SubscriptionId,
    [string] $ResourceGroup,
    [string] $Location = 'eastus2',
    [ValidateSet('dev', 'prod')] [string] $Environment = 'dev',
    [string] $ParametersFile,
    [ValidateSet('Developer', 'Premium')] [string] $ApimSku,
    [string] $ExistingApimName,
    [string] $ApimResourceGroup,
    [ValidateRange(1, 30)] [int] $TokenDays = 29,
    [ValidateRange(30, 3600)] [int] $TimeoutSeconds = 600,
    [switch] $ValidateOnly,
    [switch] $RotateTokenOnly,
    [switch] $RunLoadTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'scripts\Rollout.ps1')

if ($ValidateOnly -and $RotateTokenOnly) { throw 'Choose ValidateOnly or RotateTokenOnly, not both.' }
if (!$ResourceGroup) {
    $ResourceGroup = if ($Environment -eq 'prod') { 'rg-apim-selfhosted-prod' } else { 'rg-apim-selfhosted' }
}
if (!$ParametersFile) { $ParametersFile = Join-Path $PSScriptRoot "infra\parameters\$Environment.parameters.json" }
$parameters = (Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Json -AsHashtable).parameters
foreach ($entry in @{
    publisherEmail = $PublisherEmail; publisherName = $PublisherName; apimSku = $ApimSku
    existingApimName = $ExistingApimName; apimResourceGroup = $ApimResourceGroup
}.GetEnumerator()) {
    if ($entry.Value) { $parameters[$entry.Key] = @{ value = $entry.Value } }
}
$parameters.location = @{ value = $Location }
Assert-ProjectParameters -Parameters $parameters -Environment $Environment -ResourceGroup $ResourceGroup -Rotation:$RotateTokenOnly

Get-Command az -ErrorAction Stop | Out-Null
Get-Command bicep -ErrorAction Stop | Out-Null
$template = Join-Path $PSScriptRoot 'infra\main.bicep'
$gatewayTemplate = Join-Path $PSScriptRoot 'infra\gateway.bicep'
$accountArgs = @('account', 'show', '-o', 'json')
if ($SubscriptionId) { $accountArgs += @('--subscription', $SubscriptionId) }
$account = Invoke-Az -Arguments $accountArgs | ConvertFrom-Json
if ($account.environmentName -ne 'AzureCloud') { throw 'This project currently targets Azure public cloud only.' }
$SubscriptionId = $account.id
Write-Host "Subscription: $SubscriptionId; resource group: $ResourceGroup; region: $Location; profile: $Environment"

foreach ($provider in @('Microsoft.ApiManagement', 'Microsoft.App', 'Microsoft.OperationalInsights')) {
    $state = Invoke-Az -Arguments @('provider', 'show', '--namespace', $provider, '--subscription', $SubscriptionId, '--query', 'registrationState', '-o', 'tsv')
    if ($state -ne 'Registered') {
        throw "Provider $provider is not registered. Register it explicitly with: az provider register --namespace $provider --subscription $SubscriptionId --wait"
    }
}

if ($parameters.ContainsKey('existingApimName') -and $parameters.existingApimName.value) {
    $apimGroup = if ($parameters.ContainsKey('apimResourceGroup')) { $parameters.apimResourceGroup.value } else { $ResourceGroup }
    $serviceId = "/subscriptions/$SubscriptionId/resourceGroups/$apimGroup/providers/Microsoft.ApiManagement/service/$($parameters.existingApimName.value)"
    $service = Invoke-Az -Arguments @('resource', 'show', '--ids', $serviceId, '--api-version', '2024-05-01', '--subscription', $SubscriptionId, '-o', 'json') | ConvertFrom-Json
    if ($service.sku.name -notin @('Developer', 'Premium')) { throw 'Existing APIM must use classic Developer or Premium.' }
    if ($Environment -eq 'prod' -and $service.sku.name -ne 'Premium') { throw 'Production requires classic Premium APIM.' }
}

$workDirectory = New-PrivateWorkDirectory
try {
    foreach ($item in @(@{ Source = $template; Target = 'main.json' }, @{ Source = $gatewayTemplate; Target = 'gateway.json' })) {
        & bicep build $item.Source --outfile (Join-Path $workDirectory $item.Target)
        if ($LASTEXITCODE -ne 0) { throw "Bicep build failed: $($item.Source)" }
    }
    $parameterPath = Join-Path $workDirectory 'infra.parameters.json'
    Write-DeploymentParameters -Path $parameterPath -Parameters $parameters
    $groupExists = Invoke-Az -Arguments @('group', 'exists', '-n', $ResourceGroup, '--subscription', $SubscriptionId, '-o', 'tsv')
    if ($groupExists -eq 'false') {
        if ($ValidateOnly -or $RotateTokenOnly) { throw 'Resource group must already exist for validation or rotation.' }
        Invoke-Az -Arguments @('group', 'create', '-n', $ResourceGroup, '-l', $Location, '--subscription', $SubscriptionId, '-o', 'none')
    }
    $deploymentArgs = @('--resource-group', $ResourceGroup, '--subscription', $SubscriptionId)
    if (!$RotateTokenOnly) {
        $infraArgs = $deploymentArgs + @('--template-file', (Join-Path $workDirectory 'main.json'), '--parameters', "@$parameterPath")
        Write-Host 'Checking ARM/provider permissions and previewing infrastructure changes...'
        Invoke-Az -Arguments (@('deployment', 'group', 'validate') + $infraArgs + @('--validation-level', 'Provider', '-o', 'none'))
        Invoke-Az -Arguments (@('deployment', 'group', 'what-if') + $infraArgs + @('--validation-level', 'Provider', '--no-pretty-print'))
        if ($ValidateOnly) {
            Write-Host 'Validation complete. No resources deployed. Gateway ARM validation requires the environment to exist and runs during deployment.'
            return
        }
        Write-Host 'Deploying infrastructure and API (initial APIM provisioning can take 30-60 minutes)...'
        $outputs = Invoke-Az -Arguments (@('deployment', 'group', 'create') + $infraArgs + @('-n', 'shgw-infra', '--query', 'properties.outputs', '-o', 'json')) | ConvertFrom-Json
    } else {
        $outputs = Invoke-Az -Arguments (@('deployment', 'group', 'show') + $deploymentArgs + @('-n', 'shgw-infra', '--query', 'properties.outputs', '-o', 'json')) | ConvertFrom-Json
    }
    $settings = $outputs.gatewaySettings.value
    if ($settings.tags.environment -ne $Environment) { throw 'Stored deployment environment does not match the requested profile.' }
    $appId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$($settings.appName)"
    $existingAppId = Invoke-Az -Arguments @('resource', 'list', '--resource-group', $ResourceGroup,
        '--subscription', $SubscriptionId, '--resource-type', 'Microsoft.App/containerApps',
        '--query', "[?name=='$($settings.appName)'].id | [0]", '-o', 'tsv')
    $state = if ($existingAppId) { Get-GatewayState -AppId $appId -SubscriptionId $SubscriptionId } else { $null }
    $previousRevision = Get-StableGatewayRevision -State $state
    if ($previousRevision) {
        & (Join-Path $PSScriptRoot 'scripts\Test-Gateway.ps1') `
            -GatewayUrl "https://$($state.properties.configuration.ingress.fqdn)" `
            -ExpectedGatewayId $outputs.gatewayName.value -TimeoutSeconds $TimeoutSeconds
        Write-Host "Keeping $previousRevision at 100% public traffic while the candidate is verified."
    }
    $expiry = [DateTime]::UtcNow.AddDays($TokenDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $bodyPath = Join-Path $workDirectory 'token-request.json'
    @{ keyType = 'primary'; expiry = $expiry } | ConvertTo-Json | Set-Content -LiteralPath $bodyPath -Encoding utf8
    $tokenUrl = "https://management.azure.com$($outputs.gatewayId.value)/generateToken?api-version=2024-05-01"
    $token = Invoke-Az -Arguments @('rest', '--method', 'post', '--url', $tokenUrl, '--body', "@$bodyPath", '--subscription', $SubscriptionId, '--query', 'value', '-o', 'tsv')
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'APIM returned an empty gateway token.' }
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::add-mask::$token" }
    if (!$token.StartsWith('GatewayKey ', [StringComparison]::Ordinal)) {
        $token = "GatewayKey $token"
    }

    $gatewayParameters = @{
        environmentId = @{ value = $outputs.environmentId.value }
        configurationEndpoint = @{ value = "https://$($outputs.apimName.value).configuration.azure-api.net" }
        expectedGatewayId = @{ value = $outputs.gatewayName.value }
        previousRevision = @{ value = $previousRevision }
        gatewayToken = @{ value = $token }
        revisionSuffix = @{ value = "r$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 6))" }
    }
    foreach ($name in @('appName', 'location', 'imageTag', 'minReplicas', 'maxReplicas', 'concurrentRequests', 'cpu', 'memory', 'tags')) {
        $gatewayParameters[$name] = @{ value = $settings.$name }
    }
    $gatewayParameterPath = Join-Path $workDirectory 'gateway.parameters.json'
    Write-DeploymentParameters -Path $gatewayParameterPath -Parameters $gatewayParameters
    $gatewayArgs = $deploymentArgs + @('--template-file', (Join-Path $workDirectory 'gateway.json'), '--parameters', "@$gatewayParameterPath")
    Invoke-Az -Arguments (@('deployment', 'group', 'validate') + $gatewayArgs + @('--validation-level', 'Provider', '-o', 'none'))
    Write-Host 'Deploying and verifying a candidate gateway revision before promotion...'
    $gatewayOutputs = Invoke-GatewayRollout -AppId $appId -SubscriptionId $SubscriptionId `
        -DeploymentArguments $gatewayArgs -PreviousRevision $previousRevision `
        -ExpectedGatewayId $outputs.gatewayName.value -TimeoutSeconds $TimeoutSeconds `
        -CandidateRevision "$($settings.appName)--$($gatewayParameters.revisionSuffix.value)" -RunLoadTest:$RunLoadTest
    $gatewayUrl = "https://$($gatewayOutputs.gatewayFqdn.value)"
    Write-Host "Verified gateway: $gatewayUrl; token expires: $expiry"
    Write-Host 'Schedule rotation before expiry. Rotation does not regenerate the APIM signing key.'
} finally {
    # Never publish the parameter file: it contains the gateway token.
    foreach ($name in @('main.json', 'gateway.json', 'infra.parameters.json', 'gateway.parameters.json', 'token-request.json')) {
        $path = Join-Path $workDirectory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Remove-Item -LiteralPath $workDirectory -Force
}
