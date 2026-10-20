#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $AppName = 'ca-apim-gateway',
    [string] $RevisionName,
    [string] $ExpectedGatewayId = 'aca-gateway',
    [ValidateRange(30, 3600)] [int] $TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Rollout.ps1')
$appId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$AppName"
$state = Get-GatewayState -AppId $appId -SubscriptionId $SubscriptionId
$current = Get-StableGatewayRevision -State $state
if (!$RevisionName) {
    if ($state.PSObject.Properties.Name -notcontains 'tags' -or !$state.tags -or
        $state.tags.PSObject.Properties.Name -notcontains 'shgwPreviousRevision') {
        throw 'No previous revision tag found. Supply RevisionName explicitly.'
    }
    $RevisionName = $state.tags.shgwPreviousRevision
}
if ($RevisionName -eq $current) { throw 'Requested revision is already receiving traffic.' }
if (!$RevisionName.StartsWith("$AppName--", [StringComparison]::Ordinal)) { throw 'RevisionName must belong to this gateway app.' }
$target = @(Get-GatewayRevisions -AppId $appId -SubscriptionId $SubscriptionId | Where-Object name -EQ $RevisionName)
if ($target.Count -ne 1) { throw "Revision $RevisionName does not exist." }
if ($PSCmdlet.ShouldProcess("$AppName/$RevisionName", 'Verify target and move 100% of gateway traffic to it')) {
    try {
        if (!$target[0].properties.active) {
            Invoke-Az -Arguments @('rest', '--method', 'post', '--url',
                "https://management.azure.com$appId/revisions/$RevisionName/activate?api-version=2024-03-01",
                '--subscription', $SubscriptionId, '-o', 'none')
        }
        $revision = Wait-GatewayRevision -AppId $appId -RevisionName $RevisionName -SubscriptionId $SubscriptionId -TimeoutSeconds $TimeoutSeconds
        Wait-GatewayConfiguration -GatewayUrl "https://$($revision.fqdn)" -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
        & (Join-Path $PSScriptRoot 'Test-Gateway.ps1') -GatewayUrl "https://$($revision.fqdn)" -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
        Set-GatewayTraffic -AppId $appId -RevisionName $RevisionName -SubscriptionId $SubscriptionId
        & (Join-Path $PSScriptRoot 'Test-Gateway.ps1') -GatewayUrl "https://$($state.properties.configuration.ingress.fqdn)" -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
    } catch {
        $failure = $_
        try {
            Set-GatewayTraffic -AppId $appId -RevisionName $current -SubscriptionId $SubscriptionId
            & (Join-Path $PSScriptRoot 'Test-Gateway.ps1') -GatewayUrl "https://$($state.properties.configuration.ingress.fqdn)" -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
        } catch {
            throw "Rollback failed: $($failure.Exception.Message) Restoration also failed: $($_.Exception.Message). Inspect traffic immediately."
        }
        throw "Rollback did not complete; traffic restored to $current. $($failure.Exception.Message)"
    }
    Invoke-Az -Arguments @('tag', 'update', '--resource-id', $appId, '--operation', 'Merge',
        '--tags', "shgwPreviousRevision=$current", '--subscription', $SubscriptionId, '-o', 'none')
    Write-Host "Rollback verified: $RevisionName now receives 100% of traffic."
}
