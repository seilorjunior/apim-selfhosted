#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Common.ps1')
Get-Command bicep -ErrorAction Stop | Out-Null
$work = New-PrivateWorkDirectory
try {
    foreach ($template in @('main', 'gateway')) {
        & bicep build (Join-Path $root "infra\$template.bicep") --outfile (Join-Path $work "$template.json")
        if ($LASTEXITCODE -ne 0) { throw "Bicep build failed: $template" }
    }
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "PowerShell parse errors in $($file.FullName): $parseErrors" }
    }
    foreach ($suite in @('shared', 'bash')) {
        & python -B -m unittest discover -s (Join-Path $root "tests\$suite") -p 'test_*.py' -v
        if ($LASTEXITCODE -ne 0) { throw "Python regression tests failed: $suite" }
    }
    $container = New-PesterContainer -Path (Join-Path $root 'tests\psw\*.Tests.ps1') -Data @{ BuildDirectory = $work }
    $result = Invoke-Pester -Container $container -PassThru -Output Detailed
    if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0) { throw 'Local regression checks failed.' }
} finally {
    foreach ($name in @('main.json', 'gateway.json')) {
        $path = Join-Path $work $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $work
}
