#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $SubscriptionId,
    [string] $PublisherEmail,
    [string] $Location = 'eastus2',
    [ValidatePattern('^[0-9a-f]{32}$')] [string] $RunId = [guid]::NewGuid().ToString('N'),
    [switch] $AllowProvisioning,
    [switch] $CleanupOnly
)
$ErrorActionPreference = 'Stop'
if (!$AllowProvisioning) { throw 'AllowProvisioning is required; live tests incur Azure charges.' }
if ($CleanupOnly -and !$PSBoundParameters.ContainsKey('RunId')) { throw 'CleanupOnly requires an explicit RunId.' }
$arguments = @(
    '-B', (Join-Path $PSScriptRoot '..\shared\integration_test.py'),
    '--subscription-id', $SubscriptionId.ToString(), '--location', $Location,
    '--run-id', $RunId, '--allow-provisioning'
)
if ($PublisherEmail) { $arguments += @('--publisher-email', $PublisherEmail) }
if ($CleanupOnly) { $arguments += '--cleanup-only' }
& python @arguments
if ($LASTEXITCODE -ne 0) { throw 'Live integration suite failed. See diagnostics and the integration report.' }
