#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $AppName = 'ca-apim-gateway',
    [Parameter(Mandatory)] [uri] $GatewayUrl,
    [string] $ExpectedGatewayId = 'aca-gateway',
    [ValidateRange(30, 3600)] [int] $TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
& (Join-Path $PSScriptRoot 'Test-Gateway.ps1') -GatewayUrl $GatewayUrl -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
$appId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$AppName"
$revision = Invoke-Az -Arguments @('resource', 'show', '--ids', $appId, '--api-version', '2024-03-01', '--subscription', $SubscriptionId, '--query', 'properties.latestReadyRevisionName', '-o', 'tsv')
if ([string]::IsNullOrWhiteSpace($revision)) { throw 'No ready revision to restart.' }
if ($PSCmdlet.ShouldProcess("$AppName/$revision", 'Restart all replicas of this revision (may interrupt traffic)')) {
    $url = "https://management.azure.com$appId/revisions/$revision/restart?api-version=2024-03-01"
    Invoke-Az -Arguments @('rest', '--method', 'post', '--url', $url, '--subscription', $SubscriptionId, '-o', 'none')
    # Require observable data-plane recovery, not just an unchanged latestReadyRevisionName.
    Start-Sleep -Seconds 15
    & (Join-Path $PSScriptRoot 'Test-Gateway.ps1') -GatewayUrl $GatewayUrl -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
}
