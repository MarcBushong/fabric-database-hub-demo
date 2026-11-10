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

    function New-ServerJson([string] $State = 'Ready', [string] $LocalSignIn = 'Disabled', [string] $Public = 'Disabled', [string] $Sku = 'Standard_B1ms') {
        @{
            id         = $script:serverId
            name       = 'pgflex01-abc123'
            sku        = @{ name = $Sku; tier = $(if ($Sku -like 'Standard_B*') { 'Burstable' } else { 'GeneralPurpose' }) }
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
        # No test reaches the Retail Prices API; a test that needs a price mocks Get-DemoRetailPrice.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -MockWith { throw 'The unit tests make no Retail Prices API call.' }
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
                # Get-DemoResourceGroupTag reads the Azure CLI's text (Phase 28 follow-up); -AsJson callers get it parsed.
                if ($AsJson) {
                    return [pscustomobject]@{ tags = [pscustomobject]@{ deploymentId = 'abc123' } }
                }
                return (New-AzResult -Json @{ tags = @{ deploymentId = 'abc123' } })
            }
            if ($text -match '--method post --url \S+/(start|stop|restart)\?') {
                if ($Matches[1] -eq 'restart') {
                    $script:t4.Restarts++
                    $script:t4.MaxPending = $false
                    $script:events.Add('restart')
                    return (New-AzResult -Json '')
                }
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
            if ($text -match '--method get --url \S+/flexibleServers/pgflex01-abc123/configurations/max_connections\?') {
                if (-not $script:t4.MaxConnections) {
                    return (New-AzResult -ExitCode 1 -StdErr 'A fake read error.')
                }
                return (New-AzResult -Json @{ name = 'max_connections'; properties = @{ value = $script:t4.MaxConnections; isConfigPendingRestart = $script:t4.MaxPending; isDynamicConfig = $false; source = 'user-override'; allowedValues = '25-5000' } })
            }
            if ($text -match '--method get --url \S+/flexibleServers/pgflex01-abc123\?') {
                if (-not $script:t4.Exists) {
                    return (New-AzResult -ExitCode 1 -StdErr '(ResourceNotFound) The Resource was not found.')
                }
                return (New-AzResult -Json (New-ServerJson -State $script:t4.State -LocalSignIn $script:t4.PasswordAuth -Sku $script:t4.Sku))
            }
            throw "unexpected Azure CLI call: $text"
        }
    }

    function Reset-T4State {
        $script:t4 = @{ Exists = $true; State = 'Ready'; PasswordAuth = 'Disabled'; Enhanced = 'on'; Metrics = $true; Sku = 'Standard_D4ds_v5'; MaxConnections = '50'; MaxPending = $false; Restarts = 0 }
        $script:events = [System.Collections.Generic.List[string]]::new()
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
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('T4.SERVER', 'T4.CONFIG', 'T4.ENTRAONLY', 'T4.NETWORK', 'T4.ADMIN', 'T4.DATABASE', 'T4.ENHANCEDMETRICS', 'T4.MAXCONNECTIONS', 'METRICS.T4')
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
        $check.status | Should -Be 'Warning' -Because 'the server runs Standard_D4ds_v5, the default'
        $check.message | Should -Match 'on Standard_B2s'
        $check.evidence.wantedSku | Should -Be 'Standard_B2s'
    }

    It 'checks max_connections against config/versions.json: <Name> (2026-11-03)' -ForEach @(
        @{ Name = 'in effect'; Value = '50'; Pending = $false; Status = 'Pass'; Pattern = '^max_connections is 50 and in effect' }
        @{ Name = 'waiting for a restart'; Value = '50'; Pending = $true; Status = 'Warning'; Pattern = 'waits for a restart' }
        @{ Name = 'a size''s own default'; Value = '859'; Pending = $false; Status = 'Warning'; Pattern = '^max_connections is 859, not 50' }
        @{ Name = 'a read that failed'; Value = ''; Pending = $false; Status = 'Warning'; Pattern = 'couldn''t be read: A fake read error' }
    ) {
        $script:t4.MaxConnections = $Value
        $script:t4.MaxPending = $Pending
        $check = Test-DemoT4 -Config (New-TestConfig) | Where-Object checkId -EQ 'T4.MAXCONNECTIONS'
        $check.status | Should -Be $Status
        $check.message | Should -Match $Pattern
        $check.evidence.wanted | Should -Be '50'
        @($script:azCalls | Where-Object { $_ -match '--method (post|put|patch|delete)' }).Count | Should -Be 0 -Because 'the check only reads; deploy.ps1 restarts'
    }
}

Describe 'max_connections on every T4 size (ADR 0019, 2026-11-03)' {
    BeforeEach {
        Reset-T4State
        Initialize-T4AzMock
    }

    It 'sets it in the template from config/versions.json, within the documented range, after the other parameters' {
        $postgres = (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable)['postgresql']
        $postgres['maxConnections'] | Should -Be 50 -Because 'Standard_B1ms''s own default, below connection-surge''s cap of 60'
        $postgres['docUrls']['serverParameters'] | Should -Match '/azure/postgresql/server-parameters/param-connections-authentication-connection-settings$'
        $server = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/pgflex01.bicep') -Raw
        $server | Should -Match "@minValue\(25\)\s+@maxValue\(5000\)\s+param maxConnections int = 50"
        $server | Should -Match "(?s)resource maxConnectionsSetting 'Microsoft\.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = \{\s+parent: server\s+name: 'max_connections'\s+properties: \{\s+value: string\(maxConnections\)\s+source: 'user-override'\s+\}\s+dependsOn: \[\s+idleInTransactionTimeout\s+\]"
        (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/demo.bicep') -Raw) | Should -Match 'maxConnections: postgres\.maxConnections'
        $scenario = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scenarios/connection-surge/scenario.json') -Raw | ConvertFrom-Json -AsHashtable
        $scenario['parameters']['maxConnections']['default'] | Should -BeGreaterThan ($postgres['maxConnections'] - 15) -Because 'a wave fills every slot the runner can have before the cap stops it'
    }

    It 'leaves a T4 alone when nothing waits for a restart, and when the value can''t be read' {
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PendingRestart -Config $Config } | Should -BeNullOrEmpty
        $script:t4.MaxConnections = ''
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PendingRestart -Config $Config } | Should -BeNullOrEmpty
        $script:t4.Restarts | Should -Be 0
        $config = New-TestConfig
        $config['t4Enabled'] = $false
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoT4PendingRestart -Config $Config } | Should -BeNullOrEmpty
    }

    It 'restarts a Ready T4 whose max_connections waits, with the documented operation, and waits until the value is in effect' {
        $script:t4.MaxPending = $true
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PendingRestart -Config $Config }
        $result.checkId | Should -Be 'DEPLOY.T4.RESTART'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match '^T4 \(pgflex01-abc123\) restarted in \d+ s, so max_connections 50 is in effect'
        $script:t4.Restarts | Should -Be 1
        @($script:azCalls | Where-Object { $_ -match '--method post --url https://management\.azure\.com/subscriptions/\S+/flexibleServers/pgflex01-abc123/restart\?api-version=\d{4}-\d\d-\d\d$' }).Count | Should -Be 1
    }

    It 'doesn''t restart a T4 that isn''t Ready, and says when a restart doesn''t apply the value' {
        $script:t4.MaxPending = $true
        $script:t4.State = 'Stopped'
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PendingRestart -Config $Config }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'is Stopped, so it wasn''t restarted'
        $script:t4.Restarts | Should -Be 0
        # A restart that Azure accepts but that leaves the value waiting until the wait ends.
        $script:t4.State = 'Ready'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4ParameterState -MockWith { [pscustomobject]@{ Found = $true; Value = '50'; PendingRestart = $true; Source = 'user-override'; Error = '' } }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PendingRestart -Config $Config -WaitMinutes 1 -PollSeconds 1 }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'still waits for the restart'
        $result.remediation | Should -Match 'validate\.ps1 -Area T4'
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
        $d4 = InModuleScope DbHubDemo { Get-DemoT4SkuSpec -SkuName 'Standard_D4ds_v5' }
        $d4.VCores | Should -Be 4
        $d4.Product | Should -Match 'General Purpose Ddsv5 Series Compute'
        $amd = InModuleScope DbHubDemo { Get-DemoT4SkuSpec -SkuName 'Standard_D4ads_v5' }
        $amd.Tier | Should -Be 'GeneralPurpose'
        $amd.VCores | Should -Be 4
        $amd.Product | Should -Match 'General Purpose Dadsv5 Series Compute'
        $amd.PerVCore | Should -BeTrue
        { InModuleScope DbHubDemo { Get-DemoT4SkuSpec -SkuName 'Standard_E2ds_v5' } } | Should -Throw '*documented T4 size*'
    }

    It 'offers the documented sizes: the schema and the template allow them, Standard_D4ds_v5 is the default (2026-11-04), and the template derives the tier from the size' {
        $schema = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/environment.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $schema.properties['t4SkuName'].enum | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5', 'Standard_B1ms', 'Standard_B2s')
        # Phase 28: the schema has no default, so an unset size is told apart from one you set (only an unset one falls
        # back on its own); the profile's size, Standard_D4ds_v5 since 2026-11-04, is what an unset one deploys. The same
        # goes for t4AutonomousTuning: unset means on, with a Warning instead of a Fail on a size that can't run it.
        $schema.properties['t4SkuName'].Contains('default') | Should -BeFalse
        (New-TestConfig).Contains('t4SkuName') | Should -BeFalse
        $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable
        $schema.properties['t4AutonomousTuning'].Contains('default') | Should -BeFalse
        $template.parameters['t4SkuName'].allowedValues | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5', 'Standard_B1ms', 'Standard_B2s')
        $template.parameters['t4SkuName'].defaultValue | Should -Be 'Standard_D4ds_v5'
        $template.parameters['t4AutonomousTuning'].defaultValue | Should -BeFalse -Because 'deploy.ps1 decides, from the switch and the size'
        (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/demo.bicep') -Raw) | Should -Match "tier: startsWith\(t4SkuName, 'Standard_B'\) \? 'Burstable' : 'GeneralPurpose'"
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4SkuName -Config $Config } | Should -Be 'Standard_D4ds_v5'
        foreach ($profileName in 'lowest-cost', 'demo-day', 'enhanced-performance') {
            $config = New-TestConfig
            $config['profile'] = $profileName
            InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4DefaultSkuName -Config $Config } | Should -Be 'Standard_D4ds_v5'
        }
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
        # An obviously fake price: the stop says what a restarted T4 bills at its own size (Phase 28 follow-up), here a
        # Burstable server a configuration chose to keep the month cheap.
        $script:t4.Sku = 'Standard_B1ms'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -MockWith { @([pscustomobject]@{ productName = 'Azure Database for PostgreSQL Flexible Server Burstable BS Series Compute'; skuName = 'B1MS'; meterName = 'B1MS'; retailPrice = 0.25; unitOfMeasure = '1 Hour' }) }
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PowerAction -Config $Config -Action Stop -WaitMinutes 5 -CheckPrefix STOP }
        $stop.status | Should -Be 'Pass'
        $stop.message | Should -Match 'Azure starts it again on its own at \d{4}-\d\d-\d\d \d\d:\d\d UTC, 7 days after the stop'
        $stop.message | Should -Match 'about 0\.250 USD an hour \(Standard_B1ms, list price\)'
        $stop.evidence.autoStartsAfterDays | Should -Be 7
        (([datetime]$stop.evidence.autoStartUtc).ToUniversalTime() - ([datetime]$stop.evidence.stoppedUtc).ToUniversalTime()) | Should -Be ([System.TimeSpan]::FromDays(7))
    }

    It 'prices a restarted T4 at its own size, says when the nightly safety stop stops it, and dates an earlier stop from the activity log (Phase 28 follow-up)' {
        # A General Purpose server, the fallback's size, with an obviously fake vCore price.
        $script:t4.Sku = 'Standard_D2ds_v5'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -MockWith { @([pscustomobject]@{ productName = 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'; skuName = 'vCore'; meterName = 'vCore'; retailPrice = 0.25; unitOfMeasure = '1 Hour' }) }
        # What stops it again is read from the schedules and roles (Get-DemoT4RestartStopState, ADR 0024); here the nightly
        # safety stop is in place.
        $script:safetyState = 'Nightly'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4RestartStopState -MockWith { [pscustomobject]@{ State = $script:safetyState; NextRunUtc = $null } }
        $before = [System.DateTime]::UtcNow.AddSeconds(-1)
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PowerAction -Config $Config -Action Stop -WaitMinutes 5 -CheckPrefix STOP }
        $stop.status | Should -Be 'Pass'
        $stop.evidence.skuName | Should -Be 'Standard_D2ds_v5'
        $stop.evidence.hourlyUsd | Should -Be 0.5
        $stop.evidence.dailySafetyStop | Should -BeTrue
        $stop.evidence.safetyStop | Should -Be 'Nightly'
        $stop.message | Should -Match 'about 0\.500 USD an hour \(Standard_D2ds_v5, list price\) until the nightly safety stop stops it again at \d{4}-\d\d-\d\d \d\d:\d\d UTC \(19:00 Pacific Standard Time\), (within minutes|about \d+ (minutes|hours)) after it starts\.$'
        ([datetime]$stop.evidence.stoppedUtc).ToUniversalTime() | Should -BeGreaterOrEqual $before -Because 'this call''s stop is now'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -ParameterFilter { $Filter -match 'General Purpose Ddsv5 Series Compute' }

        # Already stopped: the stop comes from the activity log. Without the nightly safety stop, the on-demand control's
        # daily one still stops it within a day; without either, nothing stops it again.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4StoppedUtc -MockWith { [datetime]::new(2026, 10, 30, 18, 0, 0, [System.DateTimeKind]::Utc) }
        $script:safetyState = 'Scheduled'
        $controlled = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PowerAction -Config $Config -Action Stop -CheckPrefix STOP }
        $controlled.evidence.dailySafetyStop | Should -BeTrue
        $controlled.message | Should -Match 'until the on-demand control''s daily safety stop stops it again, within a day\.$'
        $script:safetyState = 'NotScheduled'
        $again = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PowerAction -Config $Config -Action Stop -CheckPrefix STOP }
        $again.message | Should -Match '^T4 \(pgflex01-abc123\) was already stopped\. Azure starts it again on its own at 2026-11-06 18:00 UTC, 7 days after the stop'
        $again.message | Should -Match 'the nightly safety stop isn''t in place \(\./scripts/deploy\.ps1 sets it up\), so nothing here stops it on its own; run \./scripts/stop-demo\.ps1 again once it has started'
        ([datetime]$again.evidence.autoStartUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm', [System.Globalization.CultureInfo]::InvariantCulture) | Should -Be '2026-11-06T18:00'
        $again.evidence.dailySafetyStop | Should -BeFalse
        @($script:azCalls | Where-Object { $_ -match '--method post --url \S+/stop\?' }).Count | Should -Be 1 -Because 'an already stopped server isn''t stopped again'
    }

    It 'says nothing stops a restarted T4 when the nightly safety stop <Case> (review of 20e855c, ADR 0024)' -ForEach @(
        @{ Case = 'isn''t in place'; SafetyStop = 'NotScheduled'; Text = 'until it''s stopped again: the nightly safety stop isn''t in place \(\./scripts/deploy\.ps1 sets it up\), so nothing here stops it on its own; run \./scripts/stop-demo\.ps1 again once it has started' }
        @{ Case = 'can''t act without its role'; SafetyStop = 'NoRole'; Text = 'until it''s stopped again: the nightly safety stop is scheduled, but it can''t stop T4 until an Owner assigns its role once \(\./scripts/grant-safety-stop\.ps1 -ConfigPath \./config/demo\.config\.json\), so run \./scripts/stop-demo\.ps1 again once it has started' }
        @{ Case = 'couldn''t be read'; SafetyStop = 'Unknown'; Text = 'until it''s stopped again: the nightly safety stop does that within a day if it''s in place, which couldn''t be read just now \(\./scripts/status\.ps1 shows it as STATUS\.SAFETYSTOP\)' }
    ) {
        $script:t4.Sku = 'Standard_D2ds_v5'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -MockWith { @([pscustomobject]@{ productName = 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'; skuName = 'vCore'; meterName = 'vCore'; retailPrice = 0.25; unitOfMeasure = '1 Hour' }) }
        $script:safetyState = $SafetyStop
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4RestartStopState -MockWith { [pscustomobject]@{ State = $script:safetyState; NextRunUtc = $null } }
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4PowerAction -Config $Config -Action Stop -WaitMinutes 5 -CheckPrefix STOP }
        $stop.status | Should -Be 'Pass'
        $stop.evidence.dailySafetyStop | Should -BeFalse
        $stop.evidence.safetyStop | Should -Be $SafetyStop
        $stop.message | Should -Match 'Azure starts it again on its own at \d{4}-\d\d-\d\d \d\d:\d\d UTC, 7 days after the stop'
        $stop.message | Should -Match $Text
        $stop.message | Should -Not -Match 'stops it again, within a day\.'
    }

    It 'names the nightly safety stop''s run that stops a restarted T4: <Case> (2026-11-09, ADR 0024)' -ForEach @(
        # Live: the stop of 2026-11-07 00:01Z ended at 00:03Z, so the restart comes 3 minutes after the stop of 2026-11-13
        # 19:00 Eastern, which finds T4 still stopped; the T3 check at 19:30 stops it that evening.
        @{ Case = 'just after the stop, the T3 check'; Restart = '2026-11-14T00:03:00Z'; CheckStopsT4 = $true; Text = 'until the nightly safety stop''s T3 check stops it again at 2026-11-14 00:30 UTC (19:30 Eastern Standard Time), about 27 minutes after it starts.' }
        # The T3 check's own stop ends just after its time, so the next week's restart waits for the next evening's stop.
        @{ Case = 'just after the T3 check, the next evening''s stop'; Restart = '2026-11-14T00:33:00Z'; CheckStopsT4 = $true; Text = 'until the nightly safety stop stops it again at 2026-11-15 00:00 UTC (19:00 Eastern Standard Time), about 23 hours after it starts.' }
        @{ Case = 'without the T3 check, the next evening''s stop'; Restart = '2026-11-14T00:03:00Z'; CheckStopsT4 = $false; Text = 'until the nightly safety stop stops it again at 2026-11-15 00:00 UTC (19:00 Eastern Standard Time), about 24 hours after it starts.' }
        @{ Case = 'during the day, that evening''s stop'; Restart = '2026-11-13T15:00:00Z'; CheckStopsT4 = $true; Text = 'until the nightly safety stop stops it again at 2026-11-14 00:00 UTC (19:00 Eastern Standard Time), about 9 hours after it starts.' }
        @{ Case = 'an unknown restart, with the T3 check'; Restart = ''; CheckStopsT4 = $true; Text = 'until the nightly safety stop stops it again, within a day: its T3 check at 19:30 when it starts between 19:00 and then, otherwise its stop at the next 19:00 (Eastern Standard Time).' }
        @{ Case = 'an unknown restart, without the T3 check'; Restart = ''; CheckStopsT4 = $false; Text = 'until the nightly safety stop stops it again, at the next auto-shutdown time (19:00 Eastern Standard Time).' }
    ) {
        $config = New-TestConfig
        $config['autoShutdownTime'] = '1900'
        $config['autoShutdownTimeZone'] = 'Eastern Standard Time'
        $config['t3AutoPauseMinutes'] = 15
        $restartUtc = if ($Restart) { [datetime]::Parse($Restart, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } else { $null }
        $said = InModuleScope DbHubDemo -Parameters @{ Config = $config; RestartUtc = $restartUtc; CheckStopsT4 = $CheckStopsT4 } { Format-DemoT4RestartText -RestartUtc $RestartUtc -SkuName 'Standard_D4ds_v5' -HourlyUsd 0.25 -SafetyStop Nightly -Config $Config -CheckStopsT4:$CheckStopsT4 }
        $said | Should -BeLike ('Azure starts it again on its own * and it then bills compute at about 0.250 USD an hour (Standard_D4ds_v5, list price) {0}' -f $Text)
        # Without the configuration's times, the general text.
        $plain = InModuleScope DbHubDemo -Parameters @{ RestartUtc = $restartUtc } { Format-DemoT4RestartText -RestartUtc $RestartUtc -SkuName 'Standard_D4ds_v5' -HourlyUsd 0.25 -SafetyStop Nightly -CheckStopsT4 }
        $plain | Should -BeLike '* until the nightly safety stop stops it again, at the next auto-shutdown time.'
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

    It 'restarts a T4 whose max_connections waits right before T1 sets it up, and only in T1''s T4 step (2026-11-03)' {
        $script:t4.MaxPending = $true
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ RunnerSha256 = ('b' * 64); RunnerSentTo = @('sqlvm01') } }
        Mock -ModuleName DbHubDemo -CommandName Add-DemoT1ToT3AdminGroup -MockWith { New-DemoResult -CheckId 'T3.GROUP' -Area 't3' -Target 'T3' -Status 'Pass' -Message 'member' -Evidence @{ principalId = '88888888-8888-8888-8888-888888888888' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT1PrincipalId -MockWith { '88888888-8888-8888-8888-888888888888' }
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoT4Workload -MockWith { $script:events.Add('enable'); New-DemoResult -CheckId 'WORKLOAD.T4.ENABLE' -Area 'workload' -Target 'T4' -Status 'Pass' -Message 'set up' }
        # The T4 track's Server step only reports it, so it can run beside T1's T4 step without restarting T4 under it.
        $server = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T4' -Context @{ NoState = $true; TelemetryWaitMinutes = 0 } -Step @('Server') }
        ($server.Results | Where-Object checkId -EQ 'T4.MAXCONNECTIONS').status | Should -Be 'Warning'
        $script:t4.Restarts | Should -Be 0
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context @{ NoState = $true } -Step @('T4') }
        $outcome.Status | Should -Be 'Pass'
        @($script:events) | Should -Be @('restart', 'enable')
        ($outcome.Results | Where-Object checkId -EQ 'DEPLOY.T4.RESTART').status | Should -Be 'Pass'
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

Describe 'Get-DemoT4RestartCoverage (2026-11-04; the nightly safety stop since 2026-11-05)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        # The control's names, as Get-DemoActivityControlName returns them for the example configuration; no request is real.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlName -MockWith {
            [pscustomobject]@{ SubscriptionId = '11111111-2222-3333-4444-555555555555'; Identity = 'id-dbhub-automation'; RoleName = 'DbHub Demo Activity Operator'; DemoResourceGroup = 'rg-dbhub-demo'; DemoResourceGroupId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo'; AutomationAccount = 'aa-dbhub-control'; AutomationAccountId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-control/providers/Microsoft.Automation/automationAccounts/aa-dbhub-control'; StopRunbook = 'DbHub-Stop'; SafetyStopSchedule = 'dbhub-t4-safety-stop' }
        }
        $script:control = $true
        $script:schedule = 'Scheduled'
        $script:roleId = 'dddddddd-0000-0000-0000-000000000009'
        $script:a1 = [pscustomobject]@{ Exists = $true; Missing = $false; Error = '' }
        $script:jobs = [pscustomobject]@{ Ok = $true; Missing = $false; Error = ''; Value = @{ value = @() } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlSetting -MockWith { [pscustomobject]@{ Enabled = $script:control } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4SafetyStopState -MockWith { [pscustomobject]@{ State = $script:schedule; NextRunUtc = $null } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlRoleId -MockWith { $script:roleId }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlPrincipalId -MockWith { 'dddddddd-0000-0000-0000-000000000004' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoActivityControlAssignment -MockWith { $script:a1 }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoActivityControlArm -MockWith { $script:jobs }
        # The nightly safety stop (ADR 0024): not in place unless a test says so.
        $script:nightly = [pscustomobject]@{ State = 'NotScheduled'; NextRunUtc = $null; CheckNextRunUtc = $null; CheckScheduled = $false; RoleAssigned = $null; Missing = 'the schedule dbhub-safety-stop doesn''t exist'; Error = '' }
        $script:nightlyRuns = [pscustomobject]@{ Ok = $true; Error = ''; Stop = $null; Check = $null }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSafetyStopState -MockWith { $script:nightly }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSafetyStopLastRun -MockWith { $script:nightlyRuns }
        function New-StopJob([string] $Status, [string] $Created) {
            @{ properties = @{ jobId = ('job-' + $Status); status = $Status; creationTime = $Created; runbook = @{ name = 'DbHub-Stop' } } }
        }
        function New-NightlyState([string] $State, [string] $Missing = '', [string] $ReadError = '') {
            [pscustomobject]@{ State = $State; NextRunUtc = [datetime]::new(2026, 11, 6, 3, 0, 0, [System.DateTimeKind]::Utc); CheckNextRunUtc = $null; CheckScheduled = $true; RoleAssigned = ($State -eq 'InPlace'); Missing = $Missing; Error = $ReadError }
        }
        function New-NightlyRun([string] $JobStatus, [string] $ResultStatus) {
            [pscustomobject]@{ Ok = $true; Error = ''; Check = $null; Stop = [pscustomobject]@{ JobId = 'aaaaaaaa-0000-0000-0000-00000000000a'; Status = $JobStatus; CreatedUtc = [datetime]::new(2026, 11, 5, 3, 0, 0, [System.DateTimeKind]::Utc); Result = @{ action = 'stop-nightly'; status = $ResultStatus } } }
        }
        $script:coverage = { InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4RestartCoverage -Config $Config -ConfigPath './config/demo.config.json' } }
        $script:controlCoverage = { InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4ControlRestartCoverage -Config $Config -ConfigPath './config/demo.config.json' } }
    }

    It 'counts the nightly safety stop when it''s scheduled, its role is assigned, and <Case>' -ForEach @(
        @{ Case = 'it hasn''t run yet'; Run = $null; Reason = 'it hasn''t run yet$'; LastRun = 'none' }
        @{ Case = 'its last run stopped what ran'; Run = @('Completed', 'Stopped'); Reason = 'its last run didn''t fail$'; LastRun = 'Completed \(Stopped\)' }
    ) {
        $script:control = $false
        $script:nightly = New-NightlyState -State 'InPlace'
        if ($null -ne $Run) {
            $script:nightlyRuns = New-NightlyRun -JobStatus $Run[0] -ResultStatus $Run[1]
        }
        $coverage = & $script:coverage
        $coverage.Counts | Should -BeTrue
        $coverage.Missing | Should -Be ''
        $coverage.Reason | Should -Match ('^the nightly safety stop is scheduled, its role is assigned, and ' + $Reason)
        $coverage.Evidence.nightly | Should -Be 'InPlace'
        $coverage.Evidence.nightlyLastRun | Should -Match $LastRun
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4SafetyStopState -Times 0 -Because 'the control''s own safety stop isn''t read when the nightly one counts'
    }

    It 'doesn''t count without the nightly safety stop, and names its missing piece and the exact fix: <Case>' -ForEach @(
        @{ Case = 'it isn''t set up yet'; Setup = { }; Missing = 'SafetyStop'; Reason = '^the nightly safety stop isn''t in place yet \(the schedule dbhub-safety-stop doesn''t exist\)$'; Fix = '^\./scripts/deploy\.ps1 sets it up after its template, so the checks after that run count about a day per restart \(a first deployment''s own preflight can''t: it runs before the template\); when deploy\.ps1 can''t assign its role, an Owner runs \./scripts/grant-safety-stop\.ps1 -ConfigPath \./config/demo\.config\.json once\.$' }
        @{ Case = 'its role isn''t assigned'; Setup = { $script:nightly = New-NightlyState -State 'NoRole' -Missing 'id-dbhub-demo-safetystop doesn''t hold "DbHub Demo Safety Stop" at rg-dbhub-demo' }; Missing = 'Role'; Reason = '^the nightly safety stop can''t stop T4: its role isn''t assigned \(id-dbhub-demo-safetystop doesn''t hold "DbHub Demo Safety Stop" at rg-dbhub-demo\)$'; Fix = '^An Owner of the subscription runs \./scripts/grant-safety-stop\.ps1 -ConfigPath \./config/demo\.config\.json once; deploy\.ps1 assigns it when the person who runs it may\.$' }
        @{ Case = 'it couldn''t be read'; Setup = { $script:nightly = New-NightlyState -State 'Unknown' -ReadError 'HTTP 503' }; Missing = 'SafetyStop'; Reason = 'couldn''t be read \(HTTP 503\), so it''s taken as missing'; Fix = 'status\.ps1' }
        @{ Case = 'its last run didn''t finish'; Setup = { $script:nightly = New-NightlyState -State 'InPlace'; $script:nightlyRuns = New-NightlyRun -JobStatus 'Failed' -ResultStatus 'Partial' }; Missing = 'StopJob'; Reason = 'last run \(created 2026-11-05 03:00 UTC\) didn''t finish its work \(job Failed\), so it may not stop T4'; Fix = 'STATUS\.SAFETYSTOP' }
        @{ Case = 'its last run said NotGranted'; Setup = { $script:nightly = New-NightlyState -State 'InPlace'; $script:nightlyRuns = New-NightlyRun -JobStatus 'Completed' -ResultStatus 'NotGranted' }; Missing = 'StopJob'; Reason = 'didn''t finish its work'; Fix = 'STATUS\.SAFETYSTOP' }
        @{ Case = 'its runs couldn''t be read'; Setup = { $script:nightly = New-NightlyState -State 'InPlace'; $script:nightlyRuns = [pscustomobject]@{ Ok = $false; Error = 'HTTP 429'; Stop = $null; Check = $null } }; Missing = 'StopJob'; Reason = 'couldn''t be read \(HTTP 429\), so it''s taken as failed'; Fix = 'status\.ps1' }
        @{ Case = 'a read throws'; Setup = { Mock -ModuleName DbHubDemo -CommandName Get-DemoSafetyStopState -MockWith { throw 'The connection was reset.' } }; Missing = 'SafetyStop'; Reason = 'couldn''t be checked \(The connection was reset\.\), so it''s taken as missing'; Fix = 'then run this again' }
    ) {
        $script:control = $false
        & $Setup
        $coverage = & $script:coverage
        $coverage.Counts | Should -BeFalse
        $coverage.Missing | Should -Be $Missing
        $coverage.Reason | Should -Match $Reason
        $coverage.Fix | Should -Match $Fix
        $coverage.Evidence.counts | Should -BeFalse
        $coverage.Evidence.missing | Should -Be $Missing
    }

    It 'counts the on-demand control''s daily T4 safety stop when the nightly one isn''t in place, and names the nightly one''s gap when neither counts' {
        $coverage = & $script:coverage
        $coverage.Counts | Should -BeTrue
        $coverage.Reason | Should -Be 'the on-demand control''s daily T4 safety stop is scheduled, A1 is assigned, and the last DbHub-Stop job didn''t fail'
        $coverage.Evidence.nightly | Should -Be 'NotScheduled'
        $coverage.Evidence.control.counts | Should -BeTrue
        $script:schedule = 'NotScheduled'
        $neither = & $script:coverage
        $neither.Counts | Should -BeFalse
        $neither.Missing | Should -Be 'SafetyStop'
        $neither.Evidence.control.missing | Should -Be 'Schedule'
    }

    It 'the control''s own counts when its schedule is in place, A1 is assigned, and its last DbHub-Stop job didn''t fail' {
        $script:jobs.Value = @{ value = @((New-StopJob -Status 'Failed' -Created '2026-11-01T19:15:00Z'), (New-StopJob -Status 'Completed' -Created '2026-11-03T19:15:00Z'), (New-StopJob -Status 'Running' -Created '2026-11-04T19:15:00Z')) }
        $coverage = & $script:controlCoverage
        $coverage.Counts | Should -BeTrue -Because 'the newest job that ended completed; a running one hasn''t ended'
        $coverage.Missing | Should -Be ''
        $coverage.Reason | Should -Be 'the on-demand control''s daily T4 safety stop is scheduled, A1 is assigned, and the last DbHub-Stop job didn''t fail'
        $coverage.Evidence.lastStopJob | Should -Be 'Completed'
        $script:jobs.Value = @{ value = @() }
        (& $script:controlCoverage).Counts | Should -BeTrue -Because 'a control whose stop never ran has no failed job'
    }

    It 'the control''s own doesn''t count, and names the missing piece and its exact fix: <Case>' -ForEach @(
        @{ Case = 'the control isn''t set up'; Setup = { $script:control = $false }; Missing = 'Control'; Reason = 'control\.enabled is false'; Fix = 'Set control\.enabled to true and run \./scripts/setup-activity-control\.ps1 -ConfigPath \./config/demo\.config\.json; an Owner then runs \./scripts/setup-activity-control\.ps1 -ConfigPath \./config/demo\.config\.json -GrantRole once' }
        @{ Case = 'the schedule isn''t in place'; Setup = { $script:schedule = 'NotScheduled' }; Missing = 'Schedule'; Reason = 'missing, disabled, or not linked to DbHub-Stop'; Fix = '^Run \./scripts/setup-activity-control\.ps1 -ConfigPath \./config/demo\.config\.json, which schedules it again\.$' }
        @{ Case = 'the schedule couldn''t be read'; Setup = { $script:schedule = 'Unknown' }; Missing = 'Schedule'; Reason = 'couldn''t be read, so it''s taken as missing'; Fix = 'schedules it again' }
        @{ Case = 'the custom role doesn''t exist'; Setup = { $script:roleId = '' }; Missing = 'A1'; Reason = 'isn''t assigned: without it DbHub-Stop can''t stop T4'; Fix = '-GrantRole, or set assignRoles to true and run \./scripts/deploy\.ps1, which grants A1 again after the template\.$' }
        @{ Case = 'A1 isn''t assigned'; Setup = { $script:a1 = [pscustomobject]@{ Exists = $false; Missing = $false; Error = '' } }; Missing = 'A1'; Reason = 'id-dbhub-automation''s "DbHub Demo Activity Operator" role on rg-dbhub-demo, isn''t assigned'; Fix = '^An Owner runs \./scripts/setup-activity-control\.ps1 -ConfigPath \./config/demo\.config\.json -GrantRole, or set assignRoles to true' }
        @{ Case = 'A1 couldn''t be read'; Setup = { $script:a1 = [pscustomobject]@{ Exists = $false; Missing = $false; Error = 'HTTP 503' } }; Missing = 'A1'; Reason = 'couldn''t be read, so it''s taken as missing'; Fix = '-GrantRole' }
        @{ Case = 'the last DbHub-Stop job failed'; Setup = { $script:jobs.Value = @{ value = @((New-StopJob -Status 'Completed' -Created '2026-11-01T19:15:00Z'), (New-StopJob -Status 'Failed' -Created '2026-11-03T19:15:00Z')) } }; Missing = 'StopJob'; Reason = 'the last DbHub-Stop job \(created 2026-11-03 19:15 UTC\) ended Failed'; Fix = '^Open the job in aa-dbhub-control \(Process Automation > Jobs\) to see why; when A1 is the cause, an Owner runs' }
        @{ Case = 'the last DbHub-Stop job was stopped'; Setup = { $script:jobs.Value = @{ value = @(New-StopJob -Status 'Stopped' -Created '2026-11-03T19:15:00Z') } }; Missing = 'StopJob'; Reason = 'ended Stopped'; Fix = 'Process Automation > Jobs' }
        @{ Case = 'the jobs couldn''t be read'; Setup = { $script:jobs = [pscustomobject]@{ Ok = $false; Missing = $false; Error = 'HTTP 429'; Value = $null } }; Missing = 'StopJob'; Reason = 'couldn''t be read \(HTTP 429\), so it''s taken as failed'; Fix = '^Open aa-dbhub-control > Jobs in the Azure portal' }
        @{ Case = 'a read throws'; Setup = { Mock -ModuleName DbHubDemo -CommandName Get-DemoT4SafetyStopState -MockWith { throw 'The connection was reset.' } }; Missing = 'Schedule'; Reason = 'couldn''t be checked \(The connection was reset\.\), so it''s taken as missing'; Fix = 'then run this again' }
    ) {
        & $Setup
        $coverage = & $script:controlCoverage
        $coverage.Counts | Should -BeFalse
        $coverage.Missing | Should -Be $Missing
        $coverage.Reason | Should -Match $Reason
        $coverage.Fix | Should -Match $Fix
        $coverage.Evidence.counts | Should -BeFalse
        $coverage.Evidence.missing | Should -Be $Missing
    }

    It 'reports which worst case the monthly ceiling counts: a Pass with a safety stop, a Warning with the fix without one, Not selected without T4' {
        $config = New-TestConfig
        $script:control = $false
        $script:nightly = New-NightlyState -State 'InPlace'
        $counted = & $script:coverage
        $pass = InModuleScope DbHubDemo -Parameters @{ Config = $config; Coverage = $counted } { New-DemoT4RestartCoverageResult -Config $Config -Coverage $Coverage -CheckPrefix 'START' }
        $pass.checkId | Should -Be 'START.COST.T4RESTART'
        $pass.status | Should -Be 'Pass'
        $pass.message | Should -Match 'and the nightly safety stop is scheduled, its role is assigned, and it hasn''t run yet, so the monthly ceiling counts each restart as about a day, until the next safety stop\.$'
        $script:nightly = New-NightlyState -State 'NoRole' -Missing 'the custom role "DbHub Demo Safety Stop" doesn''t exist'
        $missing = & $script:coverage
        $warning = InModuleScope DbHubDemo -Parameters @{ Config = $config; Coverage = $missing } { New-DemoT4RestartCoverageResult -Config $Config -Coverage $Coverage }
        $warning.checkId | Should -Be 'PREFLIGHT.COST.T4RESTART'
        $warning.status | Should -Be 'Warning'
        $warning.message | Should -Match 'so the monthly ceiling counts it running for the rest of the month\.$'
        $warning.remediation | Should -Match '^An Owner of the subscription runs \./scripts/grant-safety-stop\.ps1 .* With it in place, each restart counts as about a day\.$'
        $unchecked = InModuleScope DbHubDemo -Parameters @{ Config = $config } { New-DemoT4RestartCoverageResult -Config $Config -Coverage $null }
        $unchecked.status | Should -Be 'Warning'
        $unchecked.message | Should -Match 'whether the nightly safety stop is in place wasn''t checked'
        $unchecked.remediation | Should -Match '^Run \./scripts/deploy\.ps1, which sets up the nightly safety stop \(ADR 0024\)\.'
        $config['t4Enabled'] = $false
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { New-DemoT4RestartCoverageResult -Config $Config -Coverage $null }).status | Should -Be 'Not selected'
    }
}

Describe 'Get-DemoT4RestartWorstCase (2026-11-04)' {
    It 'counts the rest of the month without the safety stop, and about a day per restart with it: <Case>' -ForEach @(
        @{ Case = 'no safety stop'; Month = 730; Light = 10; Capped = $false; Hours = 720; Restarts = 0 }
        @{ Case = 'the safety stop, a 730-hour month'; Month = 730; Light = 10; Capped = $true; Hours = 96; Restarts = 4 }
        @{ Case = 'the safety stop, a 720-hour month'; Month = 720; Light = 10; Capped = $true; Hours = 96; Restarts = 4 }
        @{ Case = 'the safety stop, never more than the rest of the month'; Month = 730; Light = 700; Capped = $true; Hours = 30; Restarts = 4 }
        @{ Case = 'no safety stop, light use past the month'; Month = 730; Light = 744; Capped = $false; Hours = 0; Restarts = 0 }
    ) {
        $result = InModuleScope DbHubDemo -Parameters @{ Month = $Month; Light = $Light; Capped = $Capped } { Get-DemoT4RestartWorstCase -HoursPerMonth $Month -LightUseHoursPerMonth $Light -Capped $Capped }
        $result.Hours | Should -Be $Hours
        $result.Restarts | Should -Be $Restarts
    }
}

Describe 'T4 autonomous tuning (2026-11-04)' {
    It 'is <Status> with t4AutonomousTuning <Switch> at <Sku>' -ForEach @(
        @{ Switch = 'unset'; Sku = ''; Status = 'Pass'; Enabled = $true; Pattern = 'gets autonomous tuning at Standard_D4ds_v5 \(General Purpose, 4 vCores\)' }
        @{ Switch = 'unset'; Sku = 'Standard_D4ads_v5'; Status = 'Pass'; Enabled = $true; Pattern = 'Standard_D4ads_v5' }
        @{ Switch = 'true'; Sku = 'Standard_D4ds_v5'; Status = 'Pass'; Enabled = $true; Pattern = 'Intelligent Performance > Autonomous tuning' }
        @{ Switch = 'unset'; Sku = 'Standard_B1ms'; Status = 'Warning'; Enabled = $false; Pattern = 'off for T4 at Standard_B1ms \(Burstable, 1 vCore\): it needs a General Purpose or Memory Optimized size with at least 4 vCores' }
        @{ Switch = 'unset'; Sku = 'Standard_D2ds_v5'; Status = 'Warning'; Enabled = $false; Pattern = 'Standard_D2ds_v5 \(General Purpose, 2 vCores\)' }
        @{ Switch = 'true'; Sku = 'Standard_B1ms'; Status = 'Fail'; Enabled = $false; Pattern = '^t4AutonomousTuning is true, but T4''s size Standard_B1ms' }
        @{ Switch = 'true'; Sku = 'Standard_D2ds_v5'; Status = 'Fail'; Enabled = $false; Pattern = 'Standard_D2ds_v5 \(General Purpose, 2 vCores\) can''t run autonomous tuning' }
        @{ Switch = 'false'; Sku = ''; Status = 'Not selected'; Enabled = $false; Pattern = 'left as they are' }
        @{ Switch = 'false'; Sku = 'Standard_B1ms'; Status = 'Not selected'; Enabled = $false; Pattern = 't4AutonomousTuning is false' }
    ) {
        $config = New-TestConfig
        if ($Switch -ne 'unset') {
            $config['t4AutonomousTuning'] = $Switch -eq 'true'
        }
        if ($Sku) {
            $config['t4SkuName'] = $Sku
        }
        $tuning = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4Tuning -Config $Config }
        $tuning.Status | Should -Be $Status
        $tuning.Enabled | Should -Be $Enabled
        $tuning.Message | Should -Match $Pattern
        if ($Status -eq 'Fail') {
            $tuning.Remediation | Should -Match 'Set t4SkuName to Standard_D4ds_v5 \(or remove it: that''s the default\) or Standard_D4ads_v5; or set t4AutonomousTuning to false'
        }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { New-DemoT4TuningResult -Config $Config -CheckPrefix PREFLIGHT }
        $result.checkId | Should -Be 'PREFLIGHT.T4.TUNING'
        $result.status | Should -Be $Status
        $result.evidence.enabled | Should -Be $Enabled
        # The template gets it only where it runs.
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDeploymentParameter -Config $Config -NetworkMode private -T3UseFreeLimit $false }).parameters['t4AutonomousTuning'].value | Should -Be $Enabled
    }

    It 'judges the size it''s given, the fallback''s step, and is Not selected while T4 is off' {
        $config = New-TestConfig
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4Tuning -Config $Config -SkuName 'Standard_D2ds_v5' }).Status | Should -Be 'Warning'
        $config['t4Enabled'] = $false
        $off = InModuleScope DbHubDemo -Parameters @{ Config = $config } { New-DemoT4TuningResult -Config $Config -CheckPrefix DEPLOY }
        $off.checkId | Should -Be 'DEPLOY.T4.TUNING'
        $off.status | Should -Be 'Not selected'
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDeploymentParameter -Config $Config -NetworkMode private -T3UseFreeLimit $false }).parameters['t4AutonomousTuning'].value | Should -BeFalse
    }

    It 'sets Query Store and index tuning in the template, the interval before the mode, only when it''s on, and Query Store off on Burstable' {
        $postgres = InModuleScope DbHubDemo { Get-DemoPostgresSetting }
        $postgres['autonomousTuning']['minVCores'] | Should -Be 4
        $postgres['autonomousTuning']['queryCaptureMode'] | Should -Be 'top'
        $postgres['autonomousTuning']['parametersCaptureMode'] | Should -Be 'capture_first_sample'
        $postgres['autonomousTuning']['analysisIntervalMinutes'] | Should -Be 60
        $postgres['autonomousTuning']['mode'] | Should -Be 'report'
        $bicep = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/pgflex01.bicep') -Raw
        $order = @('max_connections', 'pg_qs.query_capture_mode', 'pg_qs.parameters_capture_mode', 'index_tuning.analysis_interval', 'index_tuning.mode') | ForEach-Object { $bicep.IndexOf("name: '$_'") }
        $order | Should -Not -Contain -1
        @($order | Sort-Object) | Should -Be $order -Because 'each depends on the one before, so the interval is in effect when the mode turns tuning on'
        $bicep | Should -Match "resource queryCaptureMode '[^']+' = if \(autonomousTuning \|\| sizing\.tier == 'Burstable'\)"
        $bicep | Should -Match "value: autonomousTuning \? string\(tuning\.queryCaptureMode\) : 'none'"
        foreach ($name in 'parametersCaptureMode', 'tuningInterval', 'tuningMode') {
            $bicep | Should -Match ("resource {0} '[^']+' = if \(autonomousTuning\)" -f $name)
        }
        (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/demo.bicep') -Raw) | Should -Match 'tuning: postgres\.autonomousTuning'
    }

    It 'reads the zones the region lists for a General Purpose size, and nothing when it can''t' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            New-AzResult -Json @(@{ name = 'westus3'; supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_D4ds_v5'; supportedZones = @('9') }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @(@{ name = 'Standard_D2ds_v5'; supportedZones = @('1') }, @{ name = 'Standard_D4ds_v5'; supportedZones = @('3', '1', '2') }) }) })
        } -ParameterFilter { ($ArgumentList -join ' ') -match '^postgres flexible-server list-skus --location westus3' }
        @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4SkuZone -Config $Config -SkuName 'Standard_D4ds_v5' }) | Should -Be @('1', '2', '3')
        @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4SkuZone -Config $Config -SkuName 'Standard_D4ads_v5' }).Count | Should -Be 0
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { New-AzResult -ExitCode 1 -StdErr 'boom' } -ParameterFilter { ($ArgumentList -join ' ') -match '^postgres flexible-server list-skus' }
        @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4SkuZone -Config $Config -SkuName 'Standard_D4ds_v5' }).Count | Should -Be 0
    }

    It 'says an existing T4 moves to the default once, and why it keeps its size otherwise: <Outcome>' -ForEach @(
        @{ Outcome = 'Scale'; Pattern = 'T4 exists as Standard_B1ms \(Burstable\), and your configuration doesn''t set t4SkuName, so deploy\.ps1 scales it to the default, General Purpose Standard_D4ds_v5 with 4 vCores and autonomous tuning \(since 2026-11-04\), which restarts it' }
        @{ Outcome = 'Waiting'; Pattern = 'T4 exists as Standard_B1ms \(Burstable\) and is Stopped, not Ready, so this deployment keeps its size' }
        @{ Outcome = 'Refused'; Pattern = 'Azure refused to scale T4 to Standard_D4ds_v5 \(SkuNotAvailable, at 2026-11-04T10:00:00Z\), so T4 keeps Standard_B1ms \(Burstable\)' }
    ) {
        $result = InModuleScope DbHubDemo -Parameters @{ Outcome = $Outcome } { New-DemoT4SizeResult -CheckPrefix PREFLIGHT -ServerSku 'Standard_B1ms' -SkuName 'Standard_D4ds_v5' -Outcome $Outcome -State 'Stopped' -Failure ([pscustomobject]@{ Sku = 'Standard_D4ds_v5'; Zone = ''; TimeUtc = '2026-11-04T10:00:00Z' }) }
        $result.checkId | Should -Be 'PREFLIGHT.T4.SIZE'
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match $Pattern
        $result.remediation | Should -Match 't4SkuName'
        # 2026-11-09: a size you set falls back too when T4 is created, so no fix says it never changes or has no fallback;
        # after a refused scale, the access request comes before the move, so that move isn't simply refused again.
        $result.remediation | Should -Not -Match 'a size you set (is never changed|has no fallback)'
        if ($Outcome -eq 'Refused') {
            $result.remediation | Should -Match '^Nothing to do: T4 works at its size\. To have the default, first ask for access with a Region access request for Azure Database for PostgreSQL flexible server \(Learn: Resolve capacity errors\), then set t4SkuName to Standard_D4ds_v5 and run \./scripts/deploy\.ps1'
        }
    }
}