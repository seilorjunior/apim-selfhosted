param([string] $BuildDirectory)

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'scripts\Common.ps1')
    $main = Get-Content -LiteralPath (Join-Path $BuildDirectory 'main.json') -Raw | ConvertFrom-Json -AsHashtable
    $gateway = Get-Content -LiteralPath (Join-Path $BuildDirectory 'gateway.json') -Raw | ConvertFrom-Json -AsHashtable
}

Describe 'Reusable infrastructure contract' {
    It 'keeps the API versioned and fixes the gateway identity policy' {
        $api = Get-Content -LiteralPath (Join-Path $root 'api\sample.openapi.json') -Raw | ConvertFrom-Json -AsHashtable
        $api.openapi | Should -Be '3.0.3'
        $api.paths['/'].get.operationId | Should -Be 'get-root'
        $api.paths['/'].get.responses.ContainsKey('200') | Should -BeTrue
        [xml]$policy = Get-Content -LiteralPath (Join-Path $root 'api\policies\sample.xml') -Raw
        $policy.policies.outbound.'set-header'.value | Should -Be '@(context.Deployment.Gateway.Id)'
        $policy.policies.outbound.'set-header'.name | Should -Be 'X-Served-By'
    }
    It 'pins the backend image by digest and keeps its ingress internal' {
        $main.parameters.backendImage.defaultValue | Should -Match '@sha256:[a-f0-9]{64}$'
        $backend = $main.resources | Where-Object type -EQ 'Microsoft.App/containerApps'
        $backend.properties.configuration.ingress.external | Should -BeFalse
    }
    It 'uses a valid consistent readiness API URL prefix across runtime and verification' {
        $apiModule = $main.resources | Where-Object type -EQ 'Microsoft.Resources/deployments'
        $readiness = $apiModule.properties.template.resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/apis' -and $_.properties.displayName -eq 'Gateway configuration readiness' }
        $readiness.properties.path | Should -Be 'gateway-health'
        $readiness.properties.path | Should -Match '^[a-zA-Z0-9][a-zA-Z0-9-]*$'
        Get-Content -LiteralPath (Join-Path $root 'gateway\readiness.py') -Raw | Should -Match '/gateway-health/ready'
        Get-Content -LiteralPath (Join-Path $root 'scripts\Common.ps1') -Raw | Should -Match '/gateway-health/ready'
    }
    It 'supports existing APIM without redeclaring its service' {
        $apim = $main.resources | Where-Object type -EQ 'Microsoft.ApiManagement/service'
        $apim.condition | Should -Match 'existingApimName'
        $module = $main.resources | Where-Object type -EQ 'Microsoft.Resources/deployments'
        $module.resourceGroup | Should -Match 'apimResourceGroup'
    }
    It 'keeps the token secure and pins traffic in multiple-revision mode' {
        $gateway.parameters.gatewayToken.type | Should -Be 'secureString'
        $app = $gateway.resources | Where-Object type -EQ 'Microsoft.App/containerApps'
        $app.properties.configuration.activeRevisionsMode | Should -Be 'Multiple'
        $app.properties.configuration.ingress.traffic | Should -Match 'previousRevision'
        $app.properties.template.revisionSuffix | Should -Be "[parameters('revisionSuffix')]"
        $gateway.outputs.Keys | Should -Not -Contain 'gatewayToken'
    }
    It 'configures startup, readiness, liveness and explicit HTTP scaling' {
        $app = $gateway.resources | Where-Object type -EQ 'Microsoft.App/containerApps'
        $probes = $app.properties.template.containers[0].probes
        @($probes.type | Sort-Object) | Should -Be @('Liveness', 'Readiness', 'Startup')
        ($probes | Where-Object type -EQ Readiness).httpGet.port | Should -Be 18081
        ($probes | Where-Object type -EQ Readiness).httpGet.path | Should -Be '/ready'
        ($probes | Where-Object type -EQ Liveness).httpGet.port | Should -Be 8080
        $app.properties.template.containers[1].name | Should -Be 'readiness'
        $app.properties.template.containers[1].image | Should -Match '@sha256:'
        $app.properties.template.containers[1].probes[0].tcpSocket.port | Should -Be 18081
        ($gateway.variables.Values -join "`n") | Should -Match '"0.0.0.0", 18081'
        $app.properties.template.scale.rules[0].http.metadata.concurrentRequests | Should -Match 'concurrentRequests'
        $app.properties.configuration.ingress.allowInsecure | Should -BeFalse
    }
    It 'provides valid dev and prod defaults' -ForEach @(@{ Profile = 'dev' }, @{ Profile = 'prod' }) {
        $parameters = (Get-Content -LiteralPath (Join-Path $root "infra\parameters\$Profile.parameters.json") -Raw | ConvertFrom-Json -AsHashtable).parameters
        $parameters.publisherEmail = @{ value = 'test@example.com' }
        { Assert-ProjectParameters -Parameters $parameters -Environment $Profile -ResourceGroup 'test' } | Should -Not -Throw
        if ($Profile -eq 'prod') {
            $parameters.apimSku.value | Should -Be 'Premium'
            $parameters.gatewayMinReplicas.value | Should -BeGreaterOrEqual 2
        }
    }
}

Describe 'Input and credential handling' {
    BeforeEach {
        $parameters = @{
            environmentName = @{ value = 'dev' }
            publisherEmail = @{ value = 'test@example.com' }
        }
    }
    It 'rejects missing publisher information for new APIM' {
        $parameters.Remove('publisherEmail')
        { Assert-ProjectParameters $parameters 'dev' 'test' } | Should -Throw '*PublisherEmail*'
    }
    It 'allows an existing APIM in another resource group without a publisher email' {
        $parameters.Remove('publisherEmail')
        $parameters.existingApimName = @{ value = 'existing' }
        $parameters.apimResourceGroup = @{ value = 'other-group' }
        { Assert-ProjectParameters $parameters 'dev' 'test' } | Should -Not -Throw
    }
    It 'does not require publisher information for token-only rotation' {
        $parameters.Remove('publisherEmail')
        { Assert-ProjectParameters $parameters 'dev' 'test' -Rotation } | Should -Not -Throw
    }
    It 'rejects invalid replica ranges' {
        $parameters.gatewayMinReplicas = @{ value = 3 }
        $parameters.gatewayMaxReplicas = @{ value = 2 }
        { Assert-ProjectParameters $parameters 'dev' 'test' } | Should -Throw '*Replica bounds*'
    }
    It 'reserves sidecar resources within the consumption-only environment limit' {
        $parameters.gatewayCpu = @{value='1.75'}
        $parameters.gatewayMemory = @{value='3.5Gi'}
        { Assert-ProjectParameters $parameters 'dev' 'test' } | Should -Not -Throw
        $gateway.parameters.cpu.allowedValues | Should -Contain '1.75'
        $gateway.parameters.cpu.allowedValues | Should -Not -Contain '2.0'
        $main.parameters.gatewayCpu.allowedValues | Should -Not -Contain '2.0'
        $parameters.gatewayCpu.value = '2.0'
        $parameters.gatewayMemory.value = '4Gi'
        { Assert-ProjectParameters $parameters 'dev' 'test' } | Should -Throw '*Reserve 0.25 CPU*'
    }

    Describe 'Mocked deployment orchestration' {
        BeforeEach {
            # Native command mocks invoked from another script need scope-independent state.
            $global:ShgwTestState = @{
                commands = [Collections.Generic.List[string]]::new()
                parameterPaths = [Collections.Generic.List[string]]::new()
                revisionSuffixes = [Collections.Generic.List[string]]::new()
                revision = ''
                traffic = 'ca-apim-gateway--old'
                emptyToken = $false
                prefixedToken = $false
                providerState = 'Registered'
                existingSku = 'Developer'
            }
            $global:ShgwTestState.outputs = @{
                apimName = @{ value = 'test-apim' }
                gatewayName = @{ value = 'aca-gateway' }
                gatewayId = @{ value = '/subscriptions/test/resourceGroups/test/providers/Microsoft.ApiManagement/service/test-apim/gateways/aca-gateway' }
                environmentId = @{ value = '/subscriptions/test/resourceGroups/test/providers/Microsoft.App/managedEnvironments/test' }
                gatewaySettings = @{ value = @{
                    appName = 'ca-apim-gateway'; location = 'eastus2'; imageTag = '2.9.2'
                    minReplicas = 1; maxReplicas = 3; concurrentRequests = 50
                    cpu = '1.0'; memory = '2Gi'; tags = @{ environment = 'dev' }
                } }
            } | ConvertTo-Json -Depth 10
            Mock Start-Sleep {}
            Mock Invoke-WebRequest { return @{ StatusCode = 200; Content = 'ready'; Headers = @{ 'X-Served-By' = 'aca-gateway'; 'X-Gateway-Ready' = 'configured' } } }
            Mock az {
                $global:LASTEXITCODE = 0
                $arguments = @($args)
                $command = $arguments -join ' '
                $global:ShgwTestState.commands.Add($command)
                if ($command.StartsWith('account show')) {
                    return '{"id":"test","environmentName":"AzureCloud"}'
                }
                if ($command.StartsWith('provider show')) { return $global:ShgwTestState.providerState }
                if ($command.StartsWith('group exists')) { return 'true' }
                if ($command.StartsWith('resource list')) { return '/existing-app' }
                if ($command.StartsWith('containerapp ingress traffic set')) {
                    $global:ShgwTestState.traffic = $arguments[[Array]::IndexOf($arguments, '--revision-weight') + 1].Split('=')[0]
                    return
                }
                if ($command.StartsWith('deployment group validate') -or $command.StartsWith('deployment group what-if')) { return }
                if ($command.StartsWith('deployment group create')) {
                    $path = $arguments[[Array]::IndexOf($arguments, '--parameters') + 1].TrimStart('@')
                    $global:ShgwTestState.parameterPaths.Add($path)
                    $parameters = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable).parameters
                    if ($command -match 'shgw-infra') { return $global:ShgwTestState.outputs }
                    $parameters.gatewayToken.value | Should -Be 'GatewayKey test-token'
                    $global:ShgwTestState.revisionSuffixes.Add($parameters.revisionSuffix.value)
                    $global:ShgwTestState.revision = "ca-apim-gateway--$($parameters.revisionSuffix.value)"
                    return (@{ gatewayFqdn = @{ value = 'gateway.example' }; revisionName = @{ value = $global:ShgwTestState.revision } } | ConvertTo-Json)
                }
                if ($command.StartsWith('deployment group show')) { return $global:ShgwTestState.outputs }
                if ($command.StartsWith('rest') -and $command -match 'generateToken') {
                    $bodyPath = $arguments[[Array]::IndexOf($arguments, '--body') + 1].TrimStart('@')
                    $global:ShgwTestState.parameterPaths.Add($bodyPath)
                    if ($global:ShgwTestState.emptyToken) { return '' }
                    if ($global:ShgwTestState.prefixedToken) { return 'GatewayKey test-token' }
                    return 'test-token'
                }
                if ($command.StartsWith('rest') -and $command -match '/restart\?') { return }
                if ($command.StartsWith('rest') -and $command -match '/deactivate\?') { return }
                if ($command.StartsWith('rest') -and $command -match '/revisions\?') {
                    return (@{ value = @(
                        @{ name = $global:ShgwTestState.revision; properties = @{ active = $true } }
                        @{ name = 'ca-apim-gateway--old'; properties = @{ active = $true } }
                    ) } | ConvertTo-Json -Depth 6)
                }
                if ($command.StartsWith('rest') -and $command -match '/revisions/') {
                    return '{"healthState":"Healthy","provisioningState":"Provisioned","fqdn":"candidate.example"}'
                }
                if ($command.StartsWith('resource show')) {
                    if ($command -match 'latestReadyRevisionName') { return $global:ShgwTestState.revision }
                    if ($command -match 'Microsoft.ApiManagement') {
                        return (@{ sku = @{ name = $global:ShgwTestState.existingSku } } | ConvertTo-Json)
                    }
                    return (@{ properties = @{
                        latestReadyRevisionName = $global:ShgwTestState.traffic
                        configuration = @{
                            activeRevisionsMode = 'Multiple'
                            ingress = @{ fqdn = 'gateway.example'; traffic = @(@{revisionName=$global:ShgwTestState.traffic;weight=100}) }
                        }
                    } } | ConvertTo-Json -Depth 10)
                }
                throw "Unexpected mocked Azure command: $command"
            }
        }
        AfterEach { Remove-Variable -Name ShgwTestState -Scope Global }
        It 'validates, deploys, waits for the new revision, smoke-tests, and cleans sensitive files' {
            & (Join-Path $root 'deploy.ps1') -PublisherEmail 'test@example.com' -SubscriptionId test -ResourceGroup test
            @($global:ShgwTestState.commands | Where-Object { $_ -like 'deployment group validate*' }).Count | Should -Be 2
            @($global:ShgwTestState.commands | Where-Object { $_ -like 'deployment group what-if*' }).Count | Should -Be 1
            @($global:ShgwTestState.commands | Where-Object { $_ -like 'deployment group create*' }).Count | Should -Be 2
            $global:ShgwTestState.parameterPaths | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeFalse }
            Should -Invoke Invoke-WebRequest -Times 4 -Exactly
        }
        It 'performs read-only validation without tokens or deployments' {
            & (Join-Path $root 'deploy.ps1') -PublisherEmail 'test@example.com' -SubscriptionId test -ResourceGroup test -ValidateOnly
            @($global:ShgwTestState.commands | Where-Object { $_ -match 'generateToken|deployment group create|group create' }).Count | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }
        It 'rotates twice without redeploying infrastructure and always uses a distinct revision' {
            1..2 | ForEach-Object {
                & (Join-Path $root 'deploy.ps1') -SubscriptionId test -ResourceGroup test -RotateTokenOnly
            }
            @($global:ShgwTestState.commands | Where-Object { $_ -like 'deployment group create*' -and $_ -match 'shgw-infra' }).Count | Should -Be 0
            @($global:ShgwTestState.revisionSuffixes | Select-Object -Unique).Count | Should -Be 2
            $global:ShgwTestState.parameterPaths | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeFalse }
        }
        It 'rejects an empty token before attempting a gateway rollout' {
            $global:ShgwTestState.emptyToken = $true
            { & (Join-Path $root 'deploy.ps1') -SubscriptionId test -ResourceGroup test -RotateTokenOnly } | Should -Throw '*empty gateway token*'
            @($global:ShgwTestState.commands | Where-Object { $_ -like 'deployment group create*' }).Count | Should -Be 0
            $global:ShgwTestState.parameterPaths | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeFalse }
        }
        It 'does not duplicate the authorization scheme if a token is already prefixed' {
            $global:ShgwTestState.prefixedToken = $true
            & (Join-Path $root 'deploy.ps1') -SubscriptionId test -ResourceGroup test -RotateTokenOnly
            $global:ShgwTestState.revisionSuffixes.Count | Should -Be 1
        }
        It 'rejects an unregistered provider rather than registering it silently' {
            $global:ShgwTestState.providerState = 'NotRegistered'
            { & (Join-Path $root 'deploy.ps1') -SubscriptionId test -ResourceGroup test -RotateTokenOnly } | Should -Throw '*not registered*'
            @($global:ShgwTestState.commands | Where-Object { $_ -match 'provider register|deployment group create' }).Count | Should -Be 0
        }
        It 'checks the actual existing APIM SKU' {
            $global:ShgwTestState.existingSku = 'StandardV2'
            { & (Join-Path $root 'deploy.ps1') -SubscriptionId test -ResourceGroup test -ExistingApimName existing } | Should -Throw '*classic Developer or Premium*'
        }
        It 'rejects a validity period beyond the gateway token maximum' {
            { & (Join-Path $root 'deploy.ps1') -SubscriptionId test -ResourceGroup test -RotateTokenOnly -TokenDays 31 } | Should -Throw
            $global:ShgwTestState.commands.Count | Should -Be 0
        }
        It 'rehearses a restart and verifies the data plane before and after' {
            $global:ShgwTestState.revision = 'ca-apim-gateway--test'
            & (Join-Path $root 'scripts\Test-Restart.ps1') -SubscriptionId test -ResourceGroup test -GatewayUrl 'https://gateway.example' -Confirm:$false
            @($global:ShgwTestState.commands | Where-Object { $_ -match '/restart\?' }).Count | Should -Be 1
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        }
        It 'does not restart the revision in WhatIf mode' {
            $global:ShgwTestState.revision = 'ca-apim-gateway--test'
            & (Join-Path $root 'scripts\Test-Restart.ps1') -SubscriptionId test -ResourceGroup test -GatewayUrl 'https://gateway.example' -WhatIf
            @($global:ShgwTestState.commands | Where-Object { $_ -match '/restart\?' }).Count | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }
    }
    It 'rejects Developer for a new production instance' {
        $parameters.environmentName.value = 'prod'
        { Assert-ProjectParameters $parameters 'prod' 'test' } | Should -Throw '*Premium*'
    }
    It 'rejects mismatched profiles' {
        { Assert-ProjectParameters $parameters 'prod' 'test' } | Should -Throw '*environmentName*'
    }
    It 'rejects unsupported CPU/memory pairs' {
        $parameters.gatewayCpu = @{ value = '0.5' }
        { Assert-ProjectParameters $parameters 'dev' 'test' } | Should -Throw '*CPU/memory*'
    }
    It 'requires subnet configuration for zone redundancy' {
        $parameters.zoneRedundant = @{ value = $true }
        { Assert-ProjectParameters $parameters 'dev' 'test' } | Should -Throw '*infrastructureSubnetId*'
    }
    It 'serializes parameters in an owner-restricted temporary directory' {
        $path = New-PrivateWorkDirectory
        try {
            $file = Join-Path $path 'test.json'
            Write-DeploymentParameters -Path $file -Parameters @{ gatewayToken = @{ value = 'test-only-token' } }
            $value = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            $value.parameters.gatewayToken.value | Should -Be 'test-only-token'
            if ($IsWindows) {
                (Get-Acl -LiteralPath $path).AreAccessRulesProtected | Should -BeTrue
            }
        } finally {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
            Remove-Item -LiteralPath $path
        }
    }
    It 'surfaces Azure CLI failures' {
        Mock az { $global:LASTEXITCODE = 1 }
        { Invoke-Az -Arguments @('account', 'show') } | Should -Throw '*exit code 1*'
    }
}

Describe 'Data-plane smoke test' {
    It 'requires both HTTP 200 and the exact gateway ID' {
        Test-GatewayResponse @{ StatusCode = 200; Headers = @{ 'X-Served-By' = 'aca-gateway' } } 'aca-gateway' | Should -BeTrue
        Test-GatewayResponse @{ StatusCode = 200; Headers = @{ 'X-Served-By' = 'wrong-service' } } 'aca-gateway' | Should -BeFalse
        Test-GatewayResponse @{ StatusCode = 500; Headers = @{ 'X-Served-By' = 'aca-gateway' } } 'aca-gateway' | Should -BeFalse
        Test-GatewayResponse @{ StatusCode = 200; Headers = @{} } 'aca-gateway' | Should -BeFalse
    }
    It 'retries an unconfigured gateway until the API becomes available' {
        $script:attempt = 0
        Mock Start-Sleep {}
        Mock Invoke-WebRequest {
            $script:attempt++
            if ($script:attempt -eq 1) { return @{ StatusCode = 503; Headers = @{} } }
            return @{ StatusCode = 200; Headers = @{ 'X-Served-By' = 'aca-gateway' } }
        }
        { Wait-GatewayResponse -Uri 'https://gateway.example/sample/' -ExpectedGatewayId 'aca-gateway' -TimeoutSeconds 1 -RetrySeconds 0 } | Should -Not -Throw
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
    }
    It 'fails explicitly when the serving gateway never matches' {
        Mock Start-Sleep {}
        Mock Invoke-WebRequest { return @{ StatusCode = 200; Headers = @{ 'X-Served-By' = 'wrong' } } }
        { Wait-GatewayResponse -Uri 'https://gateway.example/sample/' -ExpectedGatewayId 'aca-gateway' -TimeoutSeconds 0 -RetrySeconds 0 } | Should -Throw '*smoke test failed*'
    }
    It 'reports transient connection failures rather than treating them as success' {
        Mock Start-Sleep {}
        Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('Connection refused') }
        { Wait-GatewayResponse -Uri 'https://gateway.example/sample/' -ExpectedGatewayId 'aca-gateway' -TimeoutSeconds 0 -RetrySeconds 0 } | Should -Throw '*Connection refused*'
    }
    It 'does not confuse the previous ready revision with a successful rollout' {
        $script:attempt = 0
        Mock Start-Sleep {}
        Mock Invoke-Az {
            $script:attempt++
            if ($script:attempt -eq 1) { return '{"healthState":"None","provisioningState":"Provisioning"}' }
            return '{"healthState":"Healthy","provisioningState":"Provisioned","fqdn":"candidate.example"}'
        }
        { Wait-GatewayRevision -AppId '/app' -RevisionName 'app--new' -SubscriptionId 'test' -TimeoutSeconds 1 } | Should -Not -Throw
        Should -Invoke Invoke-Az -Times 2 -Exactly
    }
    It 'fails if the new revision never becomes ready' {
        Mock Start-Sleep {}
        Mock Invoke-Az { return '{"healthState":"Unhealthy","provisioningState":"Provisioned"}' }
        { Wait-GatewayRevision -AppId '/app' -RevisionName 'app--new' -SubscriptionId 'test' -TimeoutSeconds 0 } | Should -Throw '*did not become ready*'
    }
}
