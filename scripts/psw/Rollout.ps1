#Requires -Version 7.2
. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-GatewayState {
    param([string] $AppId, [string] $SubscriptionId)
    Invoke-Az -Arguments @('resource', 'show', '--ids', $AppId, '--api-version', '2024-03-01', '--subscription', $SubscriptionId, '-o', 'json') | ConvertFrom-Json
}

function Get-StableGatewayRevision {
    param($State)
    if ($null -eq $State) { return '' }
    if ($State.properties.configuration.activeRevisionsMode -eq 'Single') {
        $name = $State.properties.latestReadyRevisionName
    } else {
        $serving = @($State.properties.configuration.ingress.traffic | Where-Object { $_.weight -gt 0 })
        if ($serving.Count -ne 1 -or $serving[0].weight -ne 100) {
            throw 'Controlled rollout requires exactly one stable revision with 100% traffic; resolve existing traffic splits first.'
        }
        $name = if ($serving[0].PSObject.Properties.Name -contains 'revisionName' -and $serving[0].revisionName) {
            $serving[0].revisionName
        } else { $State.properties.latestReadyRevisionName }
    }
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Existing gateway has no ready stable revision. Resolve its health before deploying.' }
    return $name
}

function Set-GatewayTraffic {
    param([string] $AppId, [string] $RevisionName, [string] $SubscriptionId)
    $parts = $AppId.Split('/')
    Invoke-Az -Arguments @('containerapp', 'ingress', 'traffic', 'set', '--name', $parts[-1],
        '--resource-group', $parts[4], '--subscription', $SubscriptionId,
        '--revision-weight', "$RevisionName=100", '-o', 'none')
    $state = Get-GatewayState -AppId $AppId -SubscriptionId $SubscriptionId
    if ((Get-StableGatewayRevision -State $state) -ne $RevisionName) {
        throw "Traffic update did not pin 100% to $RevisionName."
    }
}

function Get-GatewayRevisions {
    param([string] $AppId, [string] $SubscriptionId)
    $response = Invoke-Az -Arguments @('rest', '--method', 'get', '--url',
        "https://management.azure.com$AppId/revisions?api-version=2024-03-01",
        '--subscription', $SubscriptionId, '-o', 'json') | ConvertFrom-Json
    return @($response.value)
}

function Stop-GatewayRevision {
    param([string] $AppId, [string] $RevisionName, [string] $SubscriptionId)
    Invoke-Az -Arguments @('rest', '--method', 'post', '--url',
        "https://management.azure.com$AppId/revisions/$RevisionName/deactivate?api-version=2024-03-01",
        '--subscription', $SubscriptionId, '-o', 'none')
}

function Invoke-GatewayRollout {
    param(
        [string] $AppId, [string] $SubscriptionId, [string[]] $DeploymentArguments,
        [string] $PreviousRevision, [string] $ExpectedGatewayId, [int] $TimeoutSeconds = 600,
        [string] $CandidateRevision, [switch] $RunLoadTest
    )
    $candidate = $CandidateRevision
    try {
        $outputs = Invoke-Az -Arguments (@('deployment', 'group', 'create') + $DeploymentArguments +
            @('-n', 'shgw-gateway', '--query', 'properties.outputs', '-o', 'json')) | ConvertFrom-Json
        $candidate = $outputs.revisionName.value
        $revision = Wait-GatewayRevision -AppId $AppId -RevisionName $candidate -SubscriptionId $SubscriptionId -TimeoutSeconds $TimeoutSeconds
        $candidateUrl = "https://$($revision.fqdn)"
        Wait-GatewayConfiguration -GatewayUrl $candidateUrl -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
        & (Join-Path $PSScriptRoot 'Test-Gateway.ps1') -GatewayUrl $candidateUrl -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
        if ($RunLoadTest) {
            & (Join-Path $PSScriptRoot 'Test-Load.ps1') -GatewayUrl $candidateUrl -ExpectedGatewayId $ExpectedGatewayId | Out-Host
        }
        Write-Host "Candidate $candidate passed configuration and backend checks. Promoting..."
        Set-GatewayTraffic -AppId $AppId -RevisionName $candidate -SubscriptionId $SubscriptionId
        $publicUrl = "https://$($outputs.gatewayFqdn.value)"
        & (Join-Path $PSScriptRoot 'Test-Gateway.ps1') -GatewayUrl $publicUrl -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
    } catch {
        $rolloutFailure = $_
        if ($PreviousRevision) {
            try {
                Set-GatewayTraffic -AppId $AppId -RevisionName $PreviousRevision -SubscriptionId $SubscriptionId
                $state = Get-GatewayState -AppId $AppId -SubscriptionId $SubscriptionId
                & (Join-Path $PSScriptRoot 'Test-Gateway.ps1') -GatewayUrl "https://$($state.properties.configuration.ingress.fqdn)" -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
                Write-Warning "Rollout failed. Traffic was restored to $PreviousRevision and its API was verified."
                if ($candidate) {
                    $failed = @(Get-GatewayRevisions -AppId $AppId -SubscriptionId $SubscriptionId |
                        Where-Object { $_.name -eq $candidate -and $_.properties.active })
                    if ($failed.Count) { Stop-GatewayRevision -AppId $AppId -RevisionName $candidate -SubscriptionId $SubscriptionId }
                }
            } catch {
                throw "Rollout failed: $($rolloutFailure.Exception.Message) Restoration/cleanup also failed: $($_.Exception.Message). Inspect traffic immediately."
            }
        } else {
            Write-Warning 'First deployment failed: no previous revision exists for rollback.'
        }
        throw $rolloutFailure
    }
    # Retain the current and previous revisions; do not keep scaling every historical release.
    foreach ($revision in Get-GatewayRevisions -AppId $AppId -SubscriptionId $SubscriptionId) {
        if ($revision.properties.active -and $revision.name -notin @($candidate, $PreviousRevision)) {
            Stop-GatewayRevision -AppId $AppId -RevisionName $revision.name -SubscriptionId $SubscriptionId
        }
    }
    return $outputs
}
