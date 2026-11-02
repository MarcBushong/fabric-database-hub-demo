BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # Obviously fake IDs: every group repeats one character.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        $config
    }

    function New-AzResult([object] $Json = $null, [int] $ExitCode = 0, [string] $StdErr = '') {
        $text = if ($null -eq $Json) { '' } elseif ($Json -is [string]) { $Json } else { ConvertTo-Json -InputObject $Json -Depth 20 -Compress }
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $text; StdErr = $StdErr }
    }

    $script:serverId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123'

    function New-ServerJson([string] $State = 'Ready', [string] $LocalSignIn = 'Disabled', [string] $Public = 'Disabled') {
        @{
            id         = $script:serverId
            name       = 'pgflex01-abc123'
            sku        = @{ name = 'Standard_B1ms'; tier = 'Burstable' }
            properties = @{
                state                    = $State
                version                  = '18'
                fullyQualifiedDomainName = 'pgflex01-abc123.postgres.database.azure.com'
                storage                  = @{ storageSizeGB = 32 }
                authConfig               = @{ activeDirectoryAuth = 'Enabled'; passwordAuth = $LocalSignIn }
                network                  = @{ publicNetworkAccess = $Public; delegatedSubnetResourceId = '/subscriptions/x/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/virtualNetworks/vnet-dbhub-demo/subnets/snet-pg'; privateDnsZoneArmResourceId = '/subscriptions/x/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/privateDnsZones/dbhub-demo.private.postgres.database.azure.com' }
            }
        }
    }

    # A mock of Invoke-DemoAz for T4's reads and writes: the resource group's tag, the server and its children,
    # the start and stop operations, and the metrics. $script:t4 holds the server's state between calls.
    function Initialize-T4AzMock {
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:urlParameters = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            # Every argument must reach az.cmd unchanged, as the real Invoke-DemoAz requires (live, 2026-10-26: an
            # encoded metrics query string with '%' failed the T4 track).
            foreach ($argument in @($ArgumentList)) {
                $null = & (Get-Module -Name DbHubDemo) { param($Value) ConvertTo-DemoBatchArgument -Argument $Value } ([string]$argument)
            }
            $text = @($ArgumentList) -join ' '
            $parametersIndex = [array]::IndexOf([string[]]@($ArgumentList), '--url-parameters')
            if ($parametersIndex -ge 0) {
                $parametersText = Get-Content -LiteralPath ([string]$ArgumentList[$parametersIndex + 1]).Substring(1) -Raw
                $script:urlParameters.Add(($parametersText | ConvertFrom-Json -AsHashtable))
                $text = '{0} {1}' -f $text, $parametersText
            }
            $script:azCalls.Add($text)
            if ($text -like 'group show*') {
                return [pscustomobject]@{ tags = [pscustomobject]@{ deploymentId = 'abc123' } }
            }
            if ($text -match '--method post --url \S+/(start|stop)\?') {
                $script:t4.State = if ($Matches[1] -eq 'start') { 'Ready' } else { 'Stopped' }
                return (New-AzResult -Json '')
            }
            if ($text -match 'providers/Microsoft\.Insights/metrics') {
                if ($text -match 'sessions_by_state') {
                    return (New-AzResult -Json @{ value = @(@{ name = @{ value = 'sessions_by_state' }; timeseries = @(
                                        @{ metadatavalues = @(@{ name = @{ value = 'state' }; value = 'active' }); data = @(@{ timeStamp = '2026-10-23T20:00:00Z'; maximum = 3 }) }
                                        @{ metadatavalues = @(@{ name = @{ value = 'state' }; value = 'idle in transaction' }); data = @(@{ timeStamp = '2026-10-23T20:00:00Z'; maximum = 2 }) }
                                    )
                                })
                        })
                }
                if ($text -match 'sessions_by_wait_event_type') {
                    return (New-AzResult -Json @{ value = @(@{ name = @{ value = 'sessions_by_wait_event_type' }; timeseries = @(@{ metadatavalues = @(@{ name = @{ value = 'waiteventtype' }; value = 'Lock' }); data = @(@{ timeStamp = '2026-10-23T20:00:00Z'; maximum = 4 }) }) }) })
                }
                if ($text -match 'deadlocks') {
                    return (New-AzResult -Json @{ value = @(@{ name = @{ value = 'deadlocks' }; timeseries = @(@{ data = @(@{ timeStamp = '2026-10-23T20:00:00Z'; total = 1 }) }) }) })
                }
                if ($script:t4.Metrics) {
                    return (New-AzResult -Json @{ value = @(
                                @{ name = @{ value = 'cpu_percent' }; timeseries = @(@{ data = @(@{ timeStamp = '2026-10-23T19:59:00Z'; maximum = 40 }, @{ timeStamp = '2026-10-23T20:00:00Z'; maximum = 97.5 }, @{ timeStamp = '2026-10-23T20:01:00Z' }) }) }
                                @{ name = @{ value = 'active_connections' }; timeseries = @(@{ data = @(@{ timeStamp = '2026-10-23T20:00:00Z'; maximum = 12 }) }) }
                            )
                        })
                }
                return (New-AzResult -Json @{ value = @() })
            }
            if ($text -match '--method get --url \S+/flexibleServers/pgflex01-abc123/administrators\?') {
                return (New-AzResult -Json @{ value = @(@{ properties = @{ objectId = '77777777-7777-7777-7777-777777777777'; principalName = 'DbHub T3 admins'; principalType = 'Group' } }) })
            }
            if ($text -match '--method get --url \S+/flexibleServers/pgflex01-abc123/databases/contosocare\?') {
                return (New-AzResult -Json @{ name = 'contosocare'; properties = @{ charset = 'UTF8' } })
            }
            if ($text -match '--method get --url \S+/flexibleServers/pgflex01-abc123/configurations/metrics\.collector_database_activity\?') {
                return (New-AzResult -Json @{ properties = @{ value = $script:t4.Enhanced } })
            }
            if ($text -match '--method get --url \S+/flexibleServers/pgflex01-abc123\?') {
                if (-not $script:t4.Exists) {
                    return (New-AzResult -ExitCode 1 -StdErr '(ResourceNotFound) The Resource was not found.')
                }
                return (New-AzResult -Json (New-ServerJson -State $script:t4.State -LocalSignIn $script:t4.PasswordAuth))
            }
            throw "unexpected Azure CLI call: $text"
        }
    }

    function Reset-T4State {
        $script:t4 = @{ Exists = $true; State = 'Ready'; PasswordAuth = 'Disabled'; Enhanced = 'on'; Metrics = $true }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'T4 names and configuration' {
    It 'names the server pgflex01 plus the deploymentId, with the pinned database and runner role' {
        $names = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4Name -Config $Config -DeploymentId 'abc123' -NoLookup }
        $names.ServerName | Should -Be 'pgflex01-abc123'
        $names.ServerId | Should -Be $script:serverId
        $names.Fqdn | Should -Be 'pgflex01-abc123.postgres.database.azure.com'
        $names.DatabaseName | Should -Be 'contosocare'
        $names.RunnerRole | Should -Be 'contosocare_runner'
        $names.MajorVersion | Should -Be '18'
        $names.Enabled | Should -BeTrue
    }

    It 'is on unless the configuration turns it off, and the template gets the switch' {
        $config = New-TestConfig
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoT4Enabled -Config $Config } | Should -BeTrue
        $config['t4Enabled'] = $false
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoT4Enabled -Config $Config } | Should -BeFalse
        $schema = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/environment.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $schema.properties['t4Enabled'].default | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/main.bicep') -Raw) | Should -Match 'param t4Enabled bool = true'
    }
}

Describe 'Test-DemoT4' {
    BeforeEach {
        Reset-T4State
        Initialize-T4AzMock
    }

    It 'passes a Ready, Entra-only, privately integrated server with its database, administrator, and enhanced metrics' {
        $results = @(Test-DemoT4 -Config (New-TestConfig) -IncludeMetrics)
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('T4.SERVER', 'T4.CONFIG', 'T4.ENTRAONLY', 'T4.NETWORK', 'T4.ADMIN', 'T4.DATABASE', 'T4.ENHANCEDMETRICS', 'METRICS.T4')
        $results | ForEach-Object { $_.status | Should -Be 'Pass' -Because $_.checkId }
        ($results | Where-Object checkId -EQ 'T4.ADMIN').evidence.principalName | Should -Be 'DbHub T3 admins'
        $metrics = $results | Where-Object checkId -EQ 'METRICS.T4'
        $metrics.evidence.latest['cpu_percent'] | Should -Be 97.5 -Because 'the newest point with a value wins'
        $metrics.evidence.sessionsByState['idle in transaction'] | Should -Be 2
        $metrics.evidence.sessionsByWaitEventType['Lock'] | Should -Be 4
        $metrics.evidence.latest['deadlocks'] | Should -Be 1
        # Reads only: no write reached the Azure CLI.
        @($script:azCalls | Where-Object { $_ -match '--method (post|put|patch|delete)' }).Count | Should -Be 0
    }

    It 'reads the metrics with the query parameters in a file, because an encoded query string can''t pass through az.cmd' {
        $results = @(Test-DemoT4 -Config (New-TestConfig) -IncludeMetrics)
        ($results | Where-Object checkId -EQ 'METRICS.T4').status | Should -Be 'Pass'
        $metricCalls = @($script:azCalls | Where-Object { $_ -match 'providers/Microsoft\.Insights/metrics' })
        $metricCalls.Count | Should -Be 4
        $metricCalls | ForEach-Object { $_ | Should -Match '--url \S+/providers/Microsoft\.Insights/metrics --url-parameters @\S+metrics-\d\.json ' }
        $script:urlParameters.Count | Should -Be 4
        $script:urlParameters | ForEach-Object {
            $_['interval'] | Should -Be 'PT1M'
            $_['api-version'] | Should -Not -BeNullOrEmpty
            $_['timespan'] | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        }
        @($script:urlParameters | ForEach-Object { $_['$filter'] } | Where-Object { $_ }) | Should -Be @("State eq '*'", "WaitEventType eq '*'")
        @($script:urlParameters | ForEach-Object { $_['metricnames'] })[1] | Should -Be 'connections_failed,deadlocks'
        InModuleScope DbHubDemo { Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Directory -Filter 'dbhub-t4metrics*' -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty -Because 'the parameter files are removed after the reads'
    }

    It 'fails password authentication and public access, and warns about a stopped server and missing enhanced metrics' {
        $script:t4.PasswordAuth = 'Enabled'
        $script:t4.Enhanced = 'off'
        $script:t4.State = 'Stopped'
        $results = @(Test-DemoT4 -Config (New-TestConfig) -IncludeMetrics)
        ($results | Where-Object checkId -EQ 'T4.ENTRAONLY').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'T4.ENHANCEDMETRICS').status | Should -Be 'Warning'
        ($results | Where-Object checkId -EQ 'T4.SERVER').message | Should -Match 'starts on its own after 7 days'
        ($results | Where-Object checkId -EQ 'METRICS.T4').status | Should -Be 'Warning'
    }

    It 'fails a missing server and skips the rest, and is Not selected when T4 is off' {
        $script:t4.Exists = $false
        $results = @(Test-DemoT4 -Config (New-TestConfig))
        $results[0].checkId | Should -Be 'T4.SERVER'
        $results[0].status | Should -Be 'Fail'
        @($results | Select-Object -Skip 1 | Where-Object { $_.status -ne 'Not selected' }).Count | Should -Be 0
        $config = New-TestConfig
        $config['t4Enabled'] = $false
        @(Test-DemoT4 -Config $config).status | Should -Be @('Not selected')
    }

    It 'compares the server''s size with the t4SkuName setting, the documented B2s fallback included (Phase 24)' {
        $config = New-TestConfig
        $config['t4SkuName'] = 'Standard_B2s'
        $check = Test-DemoT4 -Config $config | Where-Object checkId -EQ 'T4.CONFIG'
        $check.status | Should -Be 'Warning' -Because 'the server runs Standard_B1ms'
        $check.message | Should -Match 'on Standard_B2s'
        $check.evidence.wantedSku | Should -Be 'Standard_B2s'
    }
}

Describe 'T4 sizes (Phase 24)' {
    It 'maps each documented size to its tier, vCores, and Retail Prices meter; the tier follows the size' {
        $b1 = InModuleScope DbHubDemo { Get-DemoT4SkuSpec -SkuName 'Standard_B1ms' }
        $b1.Tier | Should -Be 'Burstable'
        $b1.Meter | Should -Be 'B1MS'
        $b1.PerVCore | Should -BeFalse
        (InModuleScope DbHubDemo { Get-DemoT4SkuSpec -SkuName 'Standard_B2s' }).Meter | Should -Be 'B2S'
        $gp = InModuleScope DbHubDemo { Get-DemoT4SkuSpec -SkuName 'Standard_D2ds_v5' }
        $gp.Tier | Should -Be 'GeneralPurpose'
        $gp.VCores | Should -Be 2
        $gp.Product | Should -Match 'General Purpose Ddsv5 Series Compute'
        $gp.PerVCore | Should -BeTrue
        { InModuleScope DbHubDemo { Get-DemoT4SkuSpec -SkuName 'Standard_E2ds_v5' } } | Should -Throw '*documented T4 size*'
    }

    It 'offers D2ds_v5 only as a setting: the schema and the template allow it, B1ms stays the default, and the template derives the tier from the size' {
        $schema = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/environment.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $schema.properties['t4SkuName'].enum | Should -Be @('Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5')
        # Phase 28: the schema has no default, so an unset size is told apart from one you set (only an unset one falls
        # back on its own); the profile's size, Standard_B1ms, is what an unset one deploys.
        $schema.properties['t4SkuName'].Contains('default') | Should -BeFalse
        (New-TestConfig).Contains('t4SkuName') | Should -BeFalse
        $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable
        $template.parameters['t4SkuName'].allowedValues | Should -Contain 'Standard_D2ds_v5'
        $template.parameters['t4SkuName'].defaultValue | Should -Be 'Standard_B1ms'
        (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/demo.bicep') -Raw) | Should -Match "tier: startsWith\(t4SkuName, 'Standard_B'\) \? 'Burstable' : 'GeneralPurpose'"
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4SkuName -Config $Config } | Should -Be 'Standard_B1ms'
    }

    It 'prices T4''s hour at the configured size from the Retail Prices API, or returns nothing when it can''t' {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -MockWith {
            @(
                [pscustomobject]@{ productName = 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'; skuName = 'vCore'; meterName = 'vCore'; retailPrice = 0.089; unitOfMeasure = '1 Hour' }
                [pscustomobject]@{ productName = 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'; skuName = 'vCore'; meterName = 'vCore'; retailPrice = 520.0; unitOfMeasure = '1 Year' }
            )
        }
        $config = New-TestConfig
        $config['t4SkuName'] = 'Standard_D2ds_v5'
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4HourlyPrice -Config $Config } | Should -Be 0.178 -Because '2 vCores at the hourly vCore meter'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -Times 1 -Exactly -ParameterFilter { $Filter -match "productName eq 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'" -and $Filter -match "armRegionName eq 'westus3'" }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -MockWith { throw 'offline' }
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4HourlyPrice -Config $Config } | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DemoT4PowerAction' {
    BeforeEach {
        Reset-T4State
        Initialize-T4AzMock
    }

    It 'starts a stopped server with the documented start operation and waits until it''s Ready' {
        $script:t4.State = 'Stopped'
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PowerAction -Config $Config -Action Start -WaitMinutes 5 -CheckPrefix START }
        $result.checkId | Should -Be 'START.T4.START'
        $result.status | Should -Be 'Pass'
        $result.evidence.stateBefore | Should -Be 'Stopped'
        $result.evidence.stateAfter | Should -Be 'Ready'
        @($script:azCalls | Where-Object { $_ -match '--method post --url https://management\.azure\.com/subscriptions/1{8}-2{4}-3{4}-4{4}-5{12}/resourceGroups/rg-dbhub-demo/providers/Microsoft\.DBforPostgreSQL/flexibleServers/pgflex01-abc123/start\?api-version=2025-08-01' }).Count | Should -Be 1
    }

    It 'leaves a server that''s already in the wanted state alone, and says when a stopped one starts again' {
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PowerAction -Config $Config -Action Start }
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'was already running'
        @($script:azCalls | Where-Object { $_ -match '--method post' }).Count | Should -Be 0
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PowerAction -Config $Config -Action Stop -WaitMinutes 5 -CheckPrefix STOP }
        $stop.status | Should -Be 'Pass'
        $stop.message | Should -Match 'starts on its own after 7 days'
        $stop.evidence.autoStartsAfterDays | Should -Be 7
    }

    It 'says a server is now running when this caller already requested its start (-Requested, Phase 25d)' {
        # start-demo.ps1 requests T4's start with -WaitMinutes 0, then confirms it; by then T4 can be Ready.
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PowerAction -Config $Config -Action Start -WaitMinutes 5 -CheckPrefix START -Requested }
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'is now running \(Ready\)'
        $result.message | Should -Not -Match 'was already'
        @($script:azCalls | Where-Object { $_ -match '--method post' }).Count | Should -Be 0
    }

    It 'is Not selected when T4 isn''t deployed or is off' {
        $script:t4.Exists = $false
        (InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PowerAction -Config $Config -Action Stop -CheckPrefix STOP }).status | Should -Be 'Not selected'
        $config = New-TestConfig
        $config['t4Enabled'] = $false
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoT4PowerAction -Config $Config -Action Start }).status | Should -Be 'Not selected'
    }
}

Describe 'Enable-DemoT4Workload' {
    BeforeEach {
        Reset-T4State
        Initialize-T4AzMock
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadAction -MockWith {
            $script:requests.Add(@{ VmName = $VmName; Action = $Action; Request = $Request })
            @{ status = 'Pass'; message = 'setup --target T4: Pass. DbHubDemo-Workload was restarted and now also hosts T4.'; evidence = @{ setup = 'Pass' } }
        }
    }

    It 'asks T1 to set T4 up as the P6 group''s role for T1''s own identity, with no secret in the request' {
        $result = Enable-DemoT4Workload -Config (New-TestConfig) -PrincipalId '88888888-8888-8888-8888-888888888888' -Confirm:$false
        $result.checkId | Should -Be 'WORKLOAD.T4.ENABLE'
        $result.status | Should -Be 'Pass'
        $script:requests.Count | Should -Be 1
        $script:requests[0].VmName | Should -Be 'sqlvm01'
        $script:requests[0].Action | Should -Be 'EnableT4'
        $request = $script:requests[0].Request
        $request.serverFqdn | Should -Be 'pgflex01-abc123.postgres.database.azure.com'
        $request.adminRole | Should -Be 'DbHub T3 admins'
        $request.runnerRole | Should -Be 'contosocare_runner'
        $request.runnerObjectId | Should -Be '88888888-8888-8888-8888-888888888888'
        $request.seedScale | Should -Be 1
        ($request.Keys -join ',') | Should -Not -Match '(?i)token|password|secret|key'
    }

    It 'needs a running server' {
        $script:t4.State = 'Stopped'
        $result = Enable-DemoT4Workload -Config (New-TestConfig) -PrincipalId '88888888-8888-8888-8888-888888888888' -Confirm:$false
        $result.status | Should -Be 'Manual action required'
        $script:requests.Count | Should -Be 0
    }
}

Describe 'T4 in the deployment tracks' {
    BeforeEach {
        Reset-T4State
        Initialize-T4AzMock
    }

    It 'checks the server in the T4 track''s Server step and its metrics in Telemetry' {
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T4' -Context @{ NoState = $true; TelemetryWaitMinutes = 0 } -Step @('Server', 'Telemetry') }
        $outcome.Status | Should -Be 'Pass'
        $outcome.Steps | Should -Be @('Server', 'Telemetry')
        ($outcome.Results | Where-Object checkId -EQ 'METRICS.T4').status | Should -Be 'Pass'
        $outcome.ReadyUtc.Contains('T4') | Should -BeTrue
    }

    It 'stops the T4 track on a failed server check' {
        $script:t4.PasswordAuth = 'Enabled'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T4' -Context @{ NoState = $true; TelemetryWaitMinutes = 0 } -Step @('Server', 'Telemetry') }
        $outcome.Status | Should -Be 'Fail'
        @($outcome.Steps).Count | Should -Be 0
    }

    It 'reports a T4 setup failure in T1''s T4 step without stopping T1''s track' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ RunnerSha256 = ('b' * 64); RunnerSentTo = @('sqlvm01') } }
        Mock -ModuleName DbHubDemo -CommandName Add-DemoT1ToT3AdminGroup -MockWith { New-DemoResult -CheckId 'T3.GROUP' -Area 't3' -Target 'T3' -Status 'Pass' -Message 'member' -Evidence @{ principalId = '88888888-8888-8888-8888-888888888888' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT1PrincipalId -MockWith { '88888888-8888-8888-8888-888888888888' }
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoT4Workload -MockWith { New-DemoResult -CheckId 'WORKLOAD.T4.ENABLE' -Area 'workload' -Target 'T4' -Status 'Fail' -Message 'password authentication failed for user "DbHub T3 admins"' }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context @{ NoState = $true } -Step @('T4') }
        $outcome.Status | Should -Be 'Pass'
        $outcome.Steps | Should -Be @('T4')
        $enable = $outcome.Results | Where-Object checkId -EQ 'WORKLOAD.T4.ENABLE'
        $enable.status | Should -Be 'Fail'
        $enable.remediation | Should -Match 'FromStage T4'
    }
}

Describe 'Get-DemoT4StoppedUtc' {
    It 'asks the activity log for the whole eight days, with an end time, and returns the last succeeded stop' {
        # Live, 2026-10-26: with --start-time alone the Azure CLI ends the range 6 hours later (--offset), so
        # STATUS.T4 found no stop and couldn't say when T4 starts on its own.
        $script:activityCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $script:activityCalls.Add((@($ArgumentList) -join ' '))
            @(
                [pscustomobject]@{ operation = 'Microsoft.DBforPostgreSQL/flexibleServers/stop/action'; status = 'Started'; time = '2026-10-26T19:04:35Z' }
                [pscustomobject]@{ operation = 'Microsoft.DBforPostgreSQL/flexibleServers/stop/action'; status = 'Succeeded'; time = '2026-10-26T19:06:38Z' }
                [pscustomobject]@{ operation = 'Microsoft.DBforPostgreSQL/flexibleServers/start/action'; status = 'Succeeded'; time = '2026-10-26T18:54:31Z' }
                [pscustomobject]@{ operation = 'Microsoft.DBforPostgreSQL/flexibleServers/stop/action'; status = 'Succeeded'; time = '2026-10-26T18:52:32Z' }
            )
        }
        $stopped = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } {
            Get-DemoT4StoppedUtc -Config $Config -ServerId '/subscriptions/x/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' -NowUtc ([datetime]::new(2026, 10, 26, 19, 10, 0, [System.DateTimeKind]::Utc))
        }
        $stopped.ToUniversalTime() | Should -Be ([datetime]::new(2026, 10, 26, 19, 6, 38, [System.DateTimeKind]::Utc))
        $script:activityCalls.Count | Should -Be 1
        $script:activityCalls[0] | Should -Match '--start-time 2026-10-18T19:10:00Z --end-time 2026-10-26T19:15:00Z --max-events 1000 '
    }
}
