#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [uri] $GatewayUrl,
    [string] $ExpectedGatewayId = 'aca-gateway',
    [ValidateRange(1, 10)] [int] $RequestsPerSecond = 10,
    [ValidateRange(1, 60)] [int] $DurationSeconds = 60,
    [ValidateRange(1, 10)] [int] $MaxConcurrency = 10,
    [ValidateRange(1, 60000)] [int] $MaxP95Milliseconds = 2000,
    [ValidateRange(0, 1)] [double] $MaxErrorRate = 0.01,
    [string] $OutputPath
)
$ErrorActionPreference = 'Stop'
if ($GatewayUrl.Scheme -ne 'https' -or $GatewayUrl.UserInfo -or $GatewayUrl.Query -or $GatewayUrl.Fragment -or $GatewayUrl.AbsolutePath -ne '/') {
    throw 'GatewayUrl must be an HTTPS origin without a path, credentials, query, or fragment.'
}
if (!$OutputPath) {
    $OutputPath = Join-Path (Split-Path $PSScriptRoot -Parent) "TestResults\load-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0,6)).json"
}
Get-Command python -ErrorAction Stop | Out-Null
& python (Join-Path $PSScriptRoot 'load_test.py') --url $GatewayUrl.AbsoluteUri `
    --gateway-id $ExpectedGatewayId --rate $RequestsPerSecond --duration $DurationSeconds `
    --concurrency $MaxConcurrency --max-p95-ms $MaxP95Milliseconds `
    --max-error-rate $MaxErrorRate --output $OutputPath
if ($LASTEXITCODE -ne 0) { throw "Load test failed. Inspect diagnostics and the report if created: $OutputPath" }
Write-Host "Load-test report: $OutputPath"
