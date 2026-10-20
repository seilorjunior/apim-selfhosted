BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'scripts\Rollout.ps1')
}

Describe 'Stable revision selection' {
    It 'pins a single-mode gateway to its actual ready revision' {
        $state = [pscustomobject]@{ properties = [pscustomobject]@{
            latestReadyRevisionName = 'app--stable'
            configuration = [pscustomobject]@{ activeRevisionsMode = 'Single' }
        } }
        Get-StableGatewayRevision $state | Should -Be 'app--stable'
    }
    It 'does not mistake the newest ready candidate for the serving revision' {
        $state = [pscustomobject]@{ properties = [pscustomobject]@{
            latestReadyRevisionName = 'app--candidate'
            configuration = [pscustomobject]@{
                activeRevisionsMode = 'Multiple'
                ingress = [pscustomobject]@{traffic=@(
                    [pscustomobject]@{revisionName='app--stable';weight=100},
                    [pscustomobject]@{revisionName='app--candidate';weight=0}
                )}
            }
        } }
        Get-StableGatewayRevision $state | Should -Be 'app--stable'
        $state.properties.configuration.ingress.traffic[0].weight = 50
        $state.properties.configuration.ingress.traffic[1].weight = 50
        { Get-StableGatewayRevision $state } | Should -Throw '*exactly one stable revision*'
    }
    It 'handles first deployment explicitly' {
        Get-StableGatewayRevision $null | Should -Be ''
    }
}

Describe 'Configuration-aware promotion and restoration' {
    BeforeEach {
        $global:ShgwRolloutTest = @{
            events = [Collections.Generic.List[string]]::new()
            failCandidate = $false; failPublic = $false; failRestore = $false
        }
        Mock Invoke-Az {
            return '{"gatewayFqdn":{"value":"gateway.example"},"revisionName":{"value":"app--candidate"}}'
        }
        Mock Wait-GatewayRevision {
            $global:ShgwRolloutTest.events.Add('wait-candidate')
            return [pscustomobject]@{fqdn='candidate.example'}
        }
        Mock Wait-GatewayConfiguration {
            $global:ShgwRolloutTest.events.Add('check-configuration')
            if ($global:ShgwRolloutTest.failCandidate) { throw 'Missing configuration marker' }
        }
        Mock Wait-GatewayResponse {
            param($Uri)
            if ($Uri.Host -eq 'candidate.example') {
                $global:ShgwRolloutTest.events.Add('check-candidate')
            } else {
                $global:ShgwRolloutTest.events.Add('check-public')
                if ($global:ShgwRolloutTest.failPublic) { $global:ShgwRolloutTest.failPublic = $false; throw 'Public smoke failed' }
            }
        }
        Mock Set-GatewayTraffic {
            param($RevisionName)
            $global:ShgwRolloutTest.events.Add("traffic:$RevisionName")
            if ($RevisionName -eq 'app--stable' -and $global:ShgwRolloutTest.failRestore) { throw 'Traffic restoration rejected' }
        }
        Mock Get-GatewayState {
            return [pscustomobject]@{properties=[pscustomobject]@{
                configuration=[pscustomobject]@{ingress=[pscustomobject]@{fqdn='gateway.example'}}
            }}
        }
        Mock Get-GatewayRevisions {
            return @(
                [pscustomobject]@{name='app--stable';properties=[pscustomobject]@{active=$true}},
                [pscustomobject]@{name='app--candidate';properties=[pscustomobject]@{active=$true}},
                [pscustomobject]@{name='app--older';properties=[pscustomobject]@{active=$true}}
            )
        }
        Mock Stop-GatewayRevision {
            param($RevisionName)
            $global:ShgwRolloutTest.events.Add("deactivate:$RevisionName")
        }
        $arguments = @{
            AppId='/subscriptions/test/resourceGroups/test/providers/Microsoft.App/containerApps/app'
            SubscriptionId='test'; DeploymentArguments=@('--fake')
            PreviousRevision='app--stable'; CandidateRevision='app--candidate'
            ExpectedGatewayId='gateway'; TimeoutSeconds=1
        }
    }
    AfterEach { Remove-Variable ShgwRolloutTest -Scope Global -ErrorAction SilentlyContinue }
    It 'checks candidate configuration and backend before moving any public traffic' {
        $result = Invoke-GatewayRollout @arguments
        $result.revisionName.value | Should -Be 'app--candidate'
        @($global:ShgwRolloutTest.events) | Should -Be @(
            'wait-candidate','check-configuration','check-candidate',
            'traffic:app--candidate','check-public','deactivate:app--older'
        )
    }
    It 'rejects a false-positive listener and keeps stable traffic' {
        $global:ShgwRolloutTest.failCandidate = $true
        { Invoke-GatewayRollout @arguments } | Should -Throw '*Missing configuration marker*'
        $global:ShgwRolloutTest.events | Should -Not -Contain 'traffic:app--candidate'
        $global:ShgwRolloutTest.events | Should -Contain 'traffic:app--stable'
        $global:ShgwRolloutTest.events | Should -Contain 'deactivate:app--candidate'
        $global:ShgwRolloutTest.events | Should -Not -Contain 'deactivate:app--stable'
    }
    It 'restores and verifies the old public endpoint after post-promotion failure' {
        $global:ShgwRolloutTest.failPublic = $true
        { Invoke-GatewayRollout @arguments } | Should -Throw '*Public smoke failed*'
        $global:ShgwRolloutTest.events.IndexOf('traffic:app--stable') | Should -BeGreaterThan $global:ShgwRolloutTest.events.IndexOf('traffic:app--candidate')
        @($global:ShgwRolloutTest.events | Where-Object {$_ -eq 'check-public'}).Count | Should -Be 2
    }
    It 'surfaces both the original failure and restoration failure' {
        $global:ShgwRolloutTest.failCandidate = $true
        $global:ShgwRolloutTest.failRestore = $true
        { Invoke-GatewayRollout @arguments } | Should -Throw '*Missing configuration marker*Restoration/cleanup also failed*'
    }
    It 'does not claim rollback when no previous revision exists' {
        $arguments.PreviousRevision = ''
        $global:ShgwRolloutTest.failCandidate = $true
        { Invoke-GatewayRollout @arguments } | Should -Throw '*Missing configuration marker*'
        Should -Invoke Set-GatewayTraffic -Times 0 -Exactly
    }
    It 'does not promote when the optional bounded load gate fails' {
        Mock python { throw 'Load threshold failed' }
        { Invoke-GatewayRollout @arguments -RunLoadTest } | Should -Throw '*Load threshold failed*'
        $global:ShgwRolloutTest.events | Should -Not -Contain 'traffic:app--candidate'
        $global:ShgwRolloutTest.events | Should -Contain 'traffic:app--stable'
    }
    It 'keeps load report output separate from deployment outputs' {
        Mock python { $global:LASTEXITCODE = 0; return '{"passed":true}' }
        $result = Invoke-GatewayRollout @arguments -RunLoadTest
        @($result).Count | Should -Be 1
        $result.gatewayFqdn.value | Should -Be 'gateway.example'
        $result.revisionName.value | Should -Be 'app--candidate'
        Should -Invoke python -Times 1 -Exactly
    }
}

Describe 'Readiness marker guards' {
    It 'does not accept empty HTTP 200 as configured' {
        Mock Start-Sleep {}
        Mock Invoke-WebRequest { return @{StatusCode=200;Headers=@{};Content=''} }
        { Wait-GatewayConfiguration -GatewayUrl 'https://gateway.example' -ExpectedGatewayId gateway -TimeoutSeconds 0 } | Should -Throw '*configuration readiness failed*'
    }
    It 'accepts only the correct marker, body and gateway identity' {
        Mock Invoke-WebRequest { return @{
            StatusCode=200;Content='ready'
            Headers=@{'X-Gateway-Ready'='configured';'X-Served-By'='gateway'}
        } }
        { Wait-GatewayConfiguration -GatewayUrl 'https://gateway.example' -ExpectedGatewayId gateway -TimeoutSeconds 0 } | Should -Not -Throw
    }
    It 'retries transient transport errors rather than accepting or hiding them' {
        Mock Start-Sleep {}
        Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('Transport unavailable') }
        { Wait-GatewayConfiguration -GatewayUrl 'https://gateway.example' -ExpectedGatewayId gateway -TimeoutSeconds 0 } | Should -Throw '*configuration readiness failed*'
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }
}

Describe 'Manual rollback safeguards' {
    BeforeEach {
        $global:ShgwRollbackTest = @{
            targetActive = $false
            commands = [Collections.Generic.List[string]]::new()
            traffic = 'ca-apim-gateway--current'
        }
        Mock Invoke-Az {
            param($Arguments)
            $command = $Arguments -join ' '
            $global:ShgwRollbackTest.commands.Add($command)
            if ($command.StartsWith('resource show')) {
                return @{
                    tags=@{shgwPreviousRevision='ca-apim-gateway--previous'}
                    properties=@{
                        configuration=@{activeRevisionsMode='Multiple';ingress=@{
                            fqdn='public.example'
                            traffic=@(@{revisionName=$global:ShgwRollbackTest.traffic;weight=100})
                        }}
                    }
                } | ConvertTo-Json -Depth 10
            }
            if ($command -match '/revisions\?') {
                return @{value=@(@{
                    name='ca-apim-gateway--previous'
                    properties=@{active=$global:ShgwRollbackTest.targetActive}
                })} | ConvertTo-Json -Depth 5
            }
            if ($command -match 'traffic set') {
                $global:ShgwRollbackTest.traffic = 'ca-apim-gateway--previous'
                return
            }
            if ($command -match '/activate\?' -or $command.StartsWith('tag update')) { return }
            throw "Unexpected Azure command: $command"
        }
        Mock Wait-GatewayRevision { return [pscustomobject]@{fqdn='previous.example'} }
        Mock Wait-GatewayConfiguration {}
        Mock Wait-GatewayResponse {}
        $rollbackArguments = @{SubscriptionId='test'; ResourceGroup='test'}
    }
    AfterEach { Remove-Variable ShgwRollbackTest -Scope Global -ErrorAction SilentlyContinue }
    It 'previews rollback without changing traffic or activating revisions' {
        & (Join-Path $root 'scripts\Rollback-Gateway.ps1') @rollbackArguments -WhatIf
        @($global:ShgwRollbackTest.commands | Where-Object {$_ -match 'activate|traffic set|tag update'}).Count | Should -Be 0
        Should -Invoke Wait-GatewayRevision -Times 0 -Exactly
    }
    It 'rejects revisions owned by a different gateway' {
        { & (Join-Path $root 'scripts\Rollback-Gateway.ps1') @rollbackArguments -RevisionName 'other--previous' -Confirm:$false } | Should -Throw '*belong to this gateway*'
    }
    It 'rejects a revision which does not exist' {
        { & (Join-Path $root 'scripts\Rollback-Gateway.ps1') @rollbackArguments -RevisionName 'ca-apim-gateway--missing' -Confirm:$false } | Should -Throw '*does not exist*'
    }
    It 'activates, verifies and promotes the recorded prior release' {
        & (Join-Path $root 'scripts\Rollback-Gateway.ps1') @rollbackArguments -Confirm:$false
        $global:ShgwRollbackTest.traffic | Should -Be 'ca-apim-gateway--previous'
        @($global:ShgwRollbackTest.commands | Where-Object {$_ -match '/activate\?'}).Count | Should -Be 1
        Should -Invoke Wait-GatewayConfiguration -Times 1 -Exactly
        Should -Invoke Wait-GatewayResponse -Times 2 -Exactly
        $global:ShgwRollbackTest.commands[-1] | Should -Match 'shgwPreviousRevision=ca-apim-gateway--current'
    }
}
