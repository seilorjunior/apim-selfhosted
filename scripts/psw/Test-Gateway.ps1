#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [uri] $GatewayUrl,
    [string] $ExpectedGatewayId = 'aca-gateway',
    [ValidateRange(1, 3600)] [int] $TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if ($GatewayUrl.Scheme -ne 'https') { throw 'GatewayUrl must use HTTPS.' }
$uri = [uri]::new($GatewayUrl.AbsoluteUri.TrimEnd('/') + '/sample/')
Wait-GatewayResponse -Uri $uri -ExpectedGatewayId $ExpectedGatewayId -TimeoutSeconds $TimeoutSeconds
