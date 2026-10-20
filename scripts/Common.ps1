#Requires -Version 7.2
Set-StrictMode -Version Latest

function Invoke-Az {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI '$($Arguments[0])' failed with exit code $LASTEXITCODE. See CLI diagnostics above." }
    return $result
}

function New-PrivateWorkDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) "apim-shgw-$([guid]::NewGuid().ToString('N'))"
    if ($IsWindows) {
        New-Item -ItemType Directory -Path $path | Out-Null
        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $path -AclObject $acl
    } else {
        [IO.Directory]::CreateDirectory($path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute) | Out-Null
    }
    return $path
}

function Write-DeploymentParameters {
    param([string] $Path, [hashtable] $Parameters)
    @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = $Parameters
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Assert-ProjectParameters {
    param([hashtable] $Parameters, [string] $Environment, [string] $ResourceGroup, [switch] $Rotation)
    if (!$Parameters.ContainsKey('environmentName') -or $Parameters.environmentName.value -ne $Environment) {
        throw 'Parameter file environmentName must match Environment.'
    }
    $existing = $Parameters.ContainsKey('existingApimName') -and ![string]::IsNullOrWhiteSpace($Parameters.existingApimName.value)
    if (!$existing -and !$Rotation) {
        if (!$Parameters.ContainsKey('publisherEmail') -or $Parameters.publisherEmail.value -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            throw 'PublisherEmail is required and must be a valid email when creating APIM.'
        }
        if ($Parameters.ContainsKey('apimResourceGroup') -and $Parameters.apimResourceGroup.value -ne $ResourceGroup) {
            throw 'A new APIM must be created in the deployment resource group.'
        }
    }
    $sku = if ($Parameters.ContainsKey('apimSku')) { $Parameters.apimSku.value } else { 'Developer' }
    if ($sku -notin @('Developer', 'Premium')) { throw 'Only classic Developer and Premium support this project.' }
    if ($Environment -eq 'prod' -and !$existing -and $sku -ne 'Premium') { throw 'Production requires classic Premium APIM.' }
    $minimum = if ($Parameters.ContainsKey('gatewayMinReplicas')) { [int]$Parameters.gatewayMinReplicas.value } elseif ($Environment -eq 'prod') { 2 } else { 1 }
    $maximum = if ($Parameters.ContainsKey('gatewayMaxReplicas')) { [int]$Parameters.gatewayMaxReplicas.value } else { 3 }
    if ($minimum -lt 1 -or $maximum -lt $minimum) { throw 'Replica bounds must satisfy 1 <= minimum <= maximum.' }
    if ($Environment -eq 'prod' -and $minimum -lt 2) { throw 'Production requires at least two gateway replicas.' }
    $cpu = if ($Parameters.ContainsKey('gatewayCpu')) { [string]$Parameters.gatewayCpu.value } else { '1.0' }
    $memory = if ($Parameters.ContainsKey('gatewayMemory')) { [string]$Parameters.gatewayMemory.value } else { '2Gi' }
    if (@{ '0.5' = '1Gi'; '1.0' = '2Gi'; '1.75' = '3.5Gi' }[$cpu] -ne $memory) {
        throw 'Use a supported gateway CPU/memory pair: 0.5/1Gi, 1.0/2Gi, or 1.75/3.5Gi. Reserve 0.25 CPU/0.5Gi for readiness within the consumption-only 2 CPU/4Gi total.'
    }
    if ($Parameters.ContainsKey('zoneRedundant') -and $Parameters.zoneRedundant.value -and
        (!$Parameters.ContainsKey('infrastructureSubnetId') -or !$Parameters.infrastructureSubnetId.value)) {
        throw 'Zone redundancy requires an existing infrastructureSubnetId in a supported region.'
    }
}

function Wait-GatewayRevision {
    param([string] $AppId, [string] $RevisionName, [string] $SubscriptionId, [int] $TimeoutSeconds = 600)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $revision = Invoke-Az -Arguments @('rest', '--method', 'get', '--url', "https://management.azure.com$AppId/revisions/$RevisionName`?api-version=2024-03-01", '--subscription', $SubscriptionId, '--query', 'properties', '-o', 'json') | ConvertFrom-Json
        if ($revision.provisioningState -eq 'Failed') { throw "Gateway revision $RevisionName provisioning failed." }
        if ($revision.healthState -eq 'Healthy' -and $revision.provisioningState -eq 'Provisioned') { return $revision }
        Write-Host "Waiting for healthy gateway revision $RevisionName (health: $($revision.healthState))..."
        Start-Sleep -Seconds 5
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Gateway revision $RevisionName did not become ready within $TimeoutSeconds seconds. Inspect Container Apps system and console logs."
}

function Wait-GatewayConfiguration {
    param([uri] $GatewayUrl, [string] $ExpectedGatewayId, [int] $TimeoutSeconds = 600)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $response = Invoke-WebRequest -Uri ($GatewayUrl.AbsoluteUri.TrimEnd('/') + '/gateway-health/ready') -TimeoutSec 10 -SkipHttpErrorCheck -MaximumRedirection 0
            $body = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
            if ($response.StatusCode -eq 200 -and [string]$response.Headers['X-Gateway-Ready'] -ceq 'configured' -and
                [string]$response.Headers['X-Served-By'] -ceq $ExpectedGatewayId -and $body -ceq 'ready') {
                Write-Host "Configuration readiness passed for $ExpectedGatewayId"
                return
            }
            Write-Warning 'Configuration readiness marker is missing or invalid.'
        } catch [System.Net.Http.HttpRequestException] {
            Write-Warning "Configuration readiness request failed: $($_.Exception.Message)"
        } catch [System.Threading.Tasks.TaskCanceledException] {
            Write-Warning "Configuration readiness request timed out: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 5
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw 'Gateway configuration readiness failed.'
}

function Test-GatewayResponse {
    param($Response, [string] $ExpectedGatewayId)
    return ($Response.StatusCode -eq 200 -and
        [string]$Response.Headers['X-Served-By'] -ceq $ExpectedGatewayId)
}

function Wait-GatewayResponse {
    param([uri] $Uri, [string] $ExpectedGatewayId, [int] $TimeoutSeconds = 600, [int] $RetrySeconds = 5)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastFailure = 'No response received.'
    do {
        try {
            $response = Invoke-WebRequest -Uri $Uri -TimeoutSec 15 -SkipHttpErrorCheck -MaximumRedirection 0
            if (Test-GatewayResponse -Response $response -ExpectedGatewayId $ExpectedGatewayId) {
                Write-Host "Smoke test passed: HTTP 200, X-Served-By: $ExpectedGatewayId"
                return
            }
            $lastFailure = "HTTP $($response.StatusCode); X-Served-By: $($response.Headers['X-Served-By'])"
        } catch [System.Net.Http.HttpRequestException] {
            $lastFailure = $_.Exception.Message
        } catch [System.Threading.Tasks.TaskCanceledException] {
            $lastFailure = $_.Exception.Message
        }
        Write-Warning "Gateway not ready: $lastFailure"
        Start-Sleep -Seconds $RetrySeconds
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Gateway smoke test failed after $TimeoutSeconds seconds. $lastFailure"
}
