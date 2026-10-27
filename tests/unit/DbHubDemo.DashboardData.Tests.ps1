BeforeAll {
    # Phase 18: Test-DemoRealTimeDashboardData, the tile data check, and configure-fabric.ps1's step 4. Every query and
    # Azure CLI read is mocked; no test touches the network, and every ID is an obvious placeholder.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    $script:configureFabric = Join-Path -Path $repoRoot -ChildPath 'scripts/configure-fabric.ps1'
    $script:now = [datetime]::new(2026, 10, 21, 12, 0, 0, [System.DateTimeKind]::Utc)
    $script:definition = Get-DemoFabricDashboardDefinition -ResourceGroup 'rg-dbhub-demo'
    $script:document = $script:definition.Content | ConvertFrom-Json -AsHashtable -Depth 64
    # Every column any tile shows, so a fake result with them all passes every tile.
    $script:allColumns = @(InModuleScope DbHubDemo -Parameters @{ Document = $script:document } {
            foreach ($tile in $Document['tiles']) {
                Get-DemoDashboardTileColumn -Tile $tile
            }
        } | Select-Object -Unique)
    $script:queryTiles = @($script:document['tiles'] | Where-Object { $_.Contains('queryRef') }).Count
    $script:queryCount = @($script:document['queries']).Count

    function New-QueryResult {
        param(
            [int] $Rows = 1,
            [string[]] $Column = $script:allColumns,
            [string] $ErrorKind = '',
            [object[]] $Row
        )
        $made = if ($PSBoundParameters.ContainsKey('Row')) {
            @($Row)
        }
        else {
            @(for ($index = 0; $index -lt $Rows; $index++) {
                    $values = [ordered]@{}
                    foreach ($name in $Column) {
                        $values[$name] = if ($name -eq 'Target') { 'T{0}' -f (($index % 3) + 1) } elseif ($name -eq 'State') { 'Fresh' } else { 1 }
                    }
                    [pscustomobject]$values
                })
        }
        [pscustomobject]@{
            Succeeded       = -not $ErrorKind
            StatusCode      = if ($ErrorKind) { 400 } else { 200 }
            ErrorKind       = $ErrorKind
            Error           = if ($ErrorKind) { 'HTTP 400: Semantic error' } else { '' }
            Columns         = if ($ErrorKind) { @() } else { $Column }
            Rows            = if ($ErrorKind) { @() } else { $made }
            PartialFailure  = $false
            Attempts        = 1
            DurationSeconds = 0.1
        }
    }

    # Answers Invoke-DemoHubTelemetryQuery: $Handler gets the query text and returns New-QueryResult output, or
    # $null for the default (rows with every column). Records every query text.
    function Set-QueryMock {
        param([scriptblock] $Handler = { $null })
        $script:QueryHandler = $Handler
        $script:Queries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHubTelemetryQuery -MockWith {
            $script:Queries.Add($Query)
            $answer = & $script:QueryHandler $Query
            if ($null -ne $answer) {
                return $answer
            }
            New-QueryResult
        }
    }

    function Set-StateMock {
        param(
            [string] $T1 = 'PowerState/deallocated',
            [string] $T2 = 'PowerState/deallocated',
            [string] $T3 = 'Paused'
        )
        $script:PowerStates = @{ sqlvm01 = $T1; archost01 = $T2 }
        $script:T3Status = $T3
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { $script:PowerStates[$VmName] }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT3State -MockWith { [pscustomobject]@{ Exists = $true; Status = $script:T3Status; ServerName = 'azuresql01-abc123'; DeploymentId = 'abc123' } }
    }

    $script:sessionsMarker = 'SqlServerActiveSessions'
    $script:probeMarker = '| summarize Rows = count() by Target'
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Test-DemoRealTimeDashboardData' {
    BeforeEach {
        Initialize-GuardTestContext -SubscriptionId $script:HubSubscriptionId -TenantId $script:HubTenantId
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
        Set-StateMock
    }

    It 'runs each query once, read-only, with the dashboard''s parameters bound for the window, and passes every tile that gets rows' {
        Set-QueryMock
        $results = @(Test-DemoRealTimeDashboardData -Config (Get-HubTestConfig) -Definition $definition -NowUtc $now)
        $results.Count | Should -Be ($queryTiles + 1)
        @($results | Where-Object { $_.status -ne 'Pass' }).Count | Should -Be 0
        $results[-1].checkId | Should -Be 'FABRIC.DASHBOARD.DATA'
        $results[-1].evidence.tiles | Should -Be $queryTiles
        $results[-1].evidence.queries | Should -Be $queryCount
        ([datetime]$results[-1].evidence.windowStartUtc).ToUniversalTime() | Should -Be $now.AddHours(-24)
        $results.checkId | Should -Contain 'FABRIC.DASHBOARD.TILE.INCIDENT.BLOCKED_NOW'
        $results.checkId | Should -Contain 'FABRIC.DASHBOARD.TILE.ESTATE_PULSE.FRESHNESS'
        $results.checkId | Should -Contain 'FABRIC.DASHBOARD.TILE.RESOURCES.CPU'
        $results.checkId | Should -Contain 'FABRIC.DASHBOARD.TILE.INCIDENT.CPU'
        @($results.checkId | Select-Object -Unique).Count | Should -Be $results.Count
        $Queries.Count | Should -Be $queryCount
        foreach ($text in $Queries) {
            $text | Should -Match '^let _startTime = datetime\(2026-10-20T12:00:00\.000Z\);\nlet _endTime = datetime\(2026-10-21T12:00:00\.000Z\);\nlet _selectedTargets = dynamic\(null\);\n'
            $text | Should -Match "let _rg = 'rg-dbhub-demo';"
            $text | Should -Not -Match '\{\{'
            $text | Should -Not -Match '(?m)^\s*\.'
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -Times 0 -Exactly
    }

    It 'names the targets'' states on the status tiles' {
        Set-QueryMock -Handler {
            param($Text)
            if ($Text -match 'Freshness = iff') {
                New-QueryResult -Column @($script:allColumns) -Row @(
                    [pscustomobject]@{ Target = 'T1'; State = 'Stale'; Freshness = '40 min ago' }
                    [pscustomobject]@{ Target = 'T2'; State = 'Stale'; Freshness = '40 min ago' }
                    [pscustomobject]@{ Target = 'T3'; State = 'No data'; Freshness = 'no data in range' }
                )
            }
        }
        $freshness = @(Test-DemoRealTimeDashboardData -Config (Get-HubTestConfig) -Definition $definition -NowUtc $now) | Where-Object { $_.checkId -eq 'FABRIC.DASHBOARD.TILE.ESTATE_PULSE.FRESHNESS' }
        $freshness.status | Should -Be 'Pass'
        $freshness.evidence.states | Should -Be 'T1 Stale, T2 Stale, T3 No data'
        $freshness.message | Should -Match 'T3 No data'
    }

    It 'fails a tile that gets rows without a column it shows' {
        Set-QueryMock -Handler {
            param($Text)
            if ($Text -match 'BlockedProcesses' -and $Text -match 'arg_max') {
                New-QueryResult -Column @('Target', 'Something')
            }
        }
        $results = @(Test-DemoRealTimeDashboardData -Config (Get-HubTestConfig) -Definition $definition -NowUtc $now)
        $blocked = $results | Where-Object { $_.checkId -eq 'FABRIC.DASHBOARD.TILE.INCIDENT.BLOCKED_NOW' }
        $blocked.status | Should -Be 'Fail'
        @($blocked.evidence.missingColumns) | Should -Contain 'BlockedProcesses'
        $results[-1].status | Should -Be 'Fail'
    }

    It 'warns when a tile is empty only because the VMs aren''t running, and says so' {
        Set-QueryMock -Handler {
            param($Text)
            if ($Text.Contains($script:probeMarker)) {
                return (New-QueryResult -Rows 0 -Column @('Target', 'Rows'))
            }
            if ($Text.Contains($script:sessionsMarker)) {
                return (New-QueryResult -Rows 0)
            }
        }
        $results = @(Test-DemoRealTimeDashboardData -Config (Get-HubTestConfig) -Definition $definition -NowUtc $now)
        $sessions = $results | Where-Object { $_.checkId -eq 'FABRIC.DASHBOARD.TILE.INCIDENT.SESSIONS' }
        $sessions.status | Should -Be 'Warning'
        $sessions.evidence.reason | Should -Be 'VmsNotRunning'
        $sessions.message | Should -Match 'sqlvm01 \(deallocated\) and T2''s VM archost01 \(deallocated\) aren''t running right now; T3''s database is Paused'
        $sessions.message | Should -Match 'Phase 20'
        $results[-1].status | Should -Be 'Warning'
        $results[-1].evidence.targetState.T1 | Should -Be 'PowerState/deallocated'
        $probes = @($Queries | Where-Object { $_.Contains($script:probeMarker) })
        $probes.Count | Should -Be 1
        $probes[0] | Should -Match "(?m)^SqlServerActiveSessions\n\| where SampleTimeUTC between \(_start \.\. _end\)\n\| where ResourceGroup =~ _rg\n\| where DatabaseName =~ _db\n\| extend Target"
        $probes[0] | Should -Match '^let _startTime = '
    }

    It 'warns without blaming the VMs when they run but nothing has arrived yet' {
        Set-StateMock -T1 'PowerState/running' -T2 'PowerState/running' -T3 'Online'
        Set-QueryMock -Handler {
            param($Text)
            if ($Text.Contains($script:probeMarker) -or $Text.Contains($script:sessionsMarker)) {
                return (New-QueryResult -Rows 0 -Column @('Target', 'Rows'))
            }
        }
        $sessions = @(Test-DemoRealTimeDashboardData -Config (Get-HubTestConfig) -Definition $definition -NowUtc $now) | Where-Object { $_.checkId -eq 'FABRIC.DASHBOARD.TILE.INCIDENT.SESSIONS' }
        $sessions.status | Should -Be 'Warning'
        $sessions.evidence.reason | Should -Be 'NoSourceRows'
        $sessions.message | Should -Match 'although the VMs run'
    }

    It 'fails a tile that is empty although its source has rows in the window' {
        Set-QueryMock -Handler {
            param($Text)
            if ($Text.Contains($script:probeMarker)) {
                return (New-QueryResult -Column @('Target', 'Rows') -Row @([pscustomobject]@{ Target = 'T1'; Rows = 42 }))
            }
            if ($Text.Contains($script:sessionsMarker)) {
                return (New-QueryResult -Rows 0)
            }
        }
        $results = @(Test-DemoRealTimeDashboardData -Config (Get-HubTestConfig) -Definition $definition -NowUtc $now)
        $sessions = $results | Where-Object { $_.checkId -eq 'FABRIC.DASHBOARD.TILE.INCIDENT.SESSIONS' }
        $sessions.status | Should -Be 'Fail'
        $sessions.message | Should -Match 'T1 \(42\)'
        $results[-1].status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -Times 0 -Exactly
    }

    It 'reports a rejected query as Fail and a throttled endpoint as Warning' {
        Set-QueryMock -Handler {
            param($Text)
            if ($Text.Contains($script:sessionsMarker)) {
                return (New-QueryResult -ErrorKind 'BadRequest')
            }
            if ($Text -match 'MemoryClerkType') {
                $throttled = New-QueryResult -ErrorKind 'Throttled'
                $throttled.StatusCode = 429
                return $throttled
            }
        }
        $results = @(Test-DemoRealTimeDashboardData -Config (Get-HubTestConfig) -Definition $definition -NowUtc $now)
        ($results | Where-Object { $_.checkId -eq 'FABRIC.DASHBOARD.TILE.INCIDENT.SESSIONS' }).status | Should -Be 'Fail'
        ($results | Where-Object { $_.checkId -eq 'FABRIC.DASHBOARD.TILE.INCIDENT.SESSIONS' }).remediation | Should -Match 'Export-DemoRealTimeDashboard'
        ($results | Where-Object { $_.checkId -eq 'FABRIC.DASHBOARD.TILE.RESOURCES.MEMORY' }).status | Should -Be 'Warning'
        $results[-1].status | Should -Be 'Fail'
    }

    It 'checks nothing, and sends nothing, without a validated Azure CLI context' {
        Initialize-GuardTestContext -Clear
        Set-QueryMock
        $results = @(Test-DemoRealTimeDashboardData -Config (Get-HubTestConfig) -Definition $definition -NowUtc $now)
        $results.Count | Should -Be 1
        $results[0].checkId | Should -Be 'FABRIC.DASHBOARD.DATA'
        $results[0].status | Should -Be 'Fail'
        $results[0].remediation | Should -Match 'Assert-DemoAzContext'
        $Queries.Count | Should -Be 0
    }

    It 'derives a source probe from every query: the prelude, the source, and its row filters' {
        $probes = InModuleScope DbHubDemo -Parameters @{ Document = $document } {
            foreach ($query in $Document['queries']) {
                Get-DemoDashboardSourceProbe -QueryText ([string]$query['text'])
            }
        }
        @($probes | Where-Object { -not $_ }).Count | Should -Be 0
        foreach ($probe in $probes) {
            $probe | Should -Match '(?m)^let _target = '
            $probe | Should -Match '(?m)^(SqlServer[A-Za-z]+|union withsource=TableName SqlServer\*)\n\| where SampleTimeUTC between '
            $probe | Should -Match '\| summarize Rows = count\(\) by Target$'
            $probe | Should -Not -Match '(?m)^\| (summarize|extend) (?!Target = _target|Rows = count)'
        }
        InModuleScope DbHubDemo { Get-DemoDashboardSourceProbe -QueryText 'print 1' } | Should -BeNullOrEmpty
    }
}

Describe 'configure-fabric.ps1, step 4: the dashboard''s data' {
    BeforeAll {
        $config = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $config.Remove('$schema')
        $config['subscriptionId'] = $script:HubSubscriptionId
        $config['tenantId'] = $script:HubTenantId
        $config['fabric'].Remove('workspaceId')
        $script:configPath = Join-Path -Path $TestDrive -ChildPath 'demo.config.json'
        Set-Content -LiteralPath $script:configPath -Value ($config | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        $script:outputPath = Join-Path -Path $TestDrive -ChildPath 'configure-fabric.jsonl'
    }

    BeforeEach {
        Clear-DemoSecret
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
        Mock -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'guard' }
        Mock -CommandName Test-DemoRealTimeDashboardData -MockWith { New-DemoResult -CheckId 'FABRIC.DASHBOARD.DATA' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'tiles' }
    }

    It 'runs the tile check alone with -CheckDashboardData, after the guard, without a workspace' {
        $null = & $configureFabric -ConfigPath $configPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -CheckDashboardData *>&1
        $LASTEXITCODE | Should -Be 0
        $results = @(Get-Content -LiteralPath $outputPath | ConvertFrom-Json)
        $results.checkId | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'FABRIC.DASHBOARD.DATA')
        Should -Invoke -CommandName Assert-DemoAzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:HubSubscriptionId }
        Should -Invoke -CommandName Test-DemoRealTimeDashboardData -Times 1 -Exactly
    }

    It 'checks nothing after a failed guard' {
        Mock -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message 'wrong tenant' }
        $null = & $configureFabric -ConfigPath $configPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -CheckDashboardData *>&1
        $LASTEXITCODE | Should -Be 1
        $results = @(Get-Content -LiteralPath $outputPath | ConvertFrom-Json)
        $results.checkId | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'FABRIC.DASHBOARD.DATA')
        $results[1].status | Should -Be 'Not selected'
        Should -Invoke -CommandName Test-DemoRealTimeDashboardData -Times 0 -Exactly
    }

    It 'sends nothing under -WhatIf' {
        $null = & $configureFabric -ConfigPath $configPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -CheckDashboardData -WhatIf *>&1
        $LASTEXITCODE | Should -Be 0
        $results = @(Get-Content -LiteralPath $outputPath | ConvertFrom-Json)
        $results.checkId | Should -Be @('FABRIC.DASHBOARD.DATA')
        $results[0].status | Should -Be 'Not selected'
        $results[0].message | Should -Match 'Dry run'
        Should -Invoke -CommandName Assert-DemoAzContext -Times 0 -Exactly
        Should -Invoke -CommandName Test-DemoRealTimeDashboardData -Times 0 -Exactly
    }
}
