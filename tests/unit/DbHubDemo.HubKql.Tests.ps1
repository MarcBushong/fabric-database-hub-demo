BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $kqlRoot = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/Kql'
    $ids = @($script:HubT1Id, $script:HubT2Id, $script:HubT3Id)
    # The 13 tables documented on the telemetry page, plus the union wildcard.
    $telemetryTables = @(
        'SqlServerCPUUtilization', 'SqlServerWaitStats', 'SqlServerMemoryUtilization', 'SqlServerPerformanceCountersCommon',
        'SqlServerPerformanceCountersDetailed', 'SqlServerStorageIO', 'SqlServerDatabaseStorageUtilization',
        'SqlServerDatabaseProperties', 'SqlServerActiveSessions', 'SqlServerClientConnections',
        'SqlServerAvailabilityGroupStates', 'SqlServerAvailabilityReplicaStates', 'SqlServerDatabaseReplicaStates'
    )
    $templateNames = @('ResourceSummary', 'TableSummary', 'WaitCategoryDeltas', 'CounterGauges', 'CounterRates')
    function Get-RenderedKql([string] $Name) {
        Get-DemoHubTelemetryKql -Name $Name -ResourceId $ids -LookbackMinutes 30 -SubscriptionId $script:HubSubscriptionId -ResourceGroup 'rg-dbhub-demo'
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Telemetry KQL builders (rules on the telemetry doc)' {
    It '<_> filters on SampleTimeUTC right after every table it reads (rule 1)' -ForEach @('ResourceSummary', 'TableSummary', 'WaitCategoryDeltas', 'CounterGauges', 'CounterRates') {
        $kql = Get-RenderedKql $_
        $tablePattern = '(?m)(?:^|=\s*|withsource=\w+\s+)((?:' + ($telemetryTables -join '|') + ')|SqlServer\*)\s*$'
        $sources = @([regex]::Matches($kql, $tablePattern))
        $sources.Count | Should -BeGreaterThan 0
        foreach ($source in $sources) {
            $after = $kql.Substring($source.Index + $source.Length)
            $after | Should -Match '^\s*\|\s*where\s+SampleTimeUTC\s*(>|between)'
        }
    }

    It '<_> compares ResourceID case-insensitively and limits its rows (rules 5 and 10)' -ForEach @('ResourceSummary', 'TableSummary', 'WaitCategoryDeltas', 'CounterGauges', 'CounterRates') {
        $kql = Get-RenderedKql $_
        $kql | Should -Match 'ResourceID in~ \(targetIds\)'
        # ResourceID == prev(ResourceID) compares a series with itself; only literals must use =~ or in~.
        $kql | Should -Not -Match 'ResourceID\s*==\s*[''"]'
        $kql | Should -Match '\|\s*take\s+\d+'
    }

    It 'takes deltas of the cumulative wait counters and never sums them (rule 2)' {
        $kql = Get-RenderedKql 'WaitCategoryDeltas'
        foreach ($column in 'WaitTimeMs', 'WaitingTasksCount', 'SignalWaitTimeMs') {
            $kql | Should -Not -Match ('(?i)\b(sum|max|min|avg|percentile|arg_max|arg_min)\(\s*{0}\b' -f $column)
        }
        $kql | Should -Match 'sort by ResourceID asc, SqlServerInstanceName asc, WaitType asc, SampleTimeUTC asc'
        $kql | Should -Match 'WaitTimeMs >= prev\(WaitTimeMs\)'
        $kql | Should -Match 'WaitingTasksCount >= prev\(WaitingTasksCount\)'
        $kql | Should -Match 'iff\(Keep, WaitTimeMs - prev\(WaitTimeMs\), long\(0\)\)'
        $kql | Should -Match 'sum\(DeltaWaitMs\)'
        $kql | Should -Match "WaitCategory !in \('Idle', 'Unknown'\)"
    }

    It 'turns cumulative counters into deltas per elapsed second and gauges into direct reads (rules 2 and 3)' {
        $rates = Get-RenderedKql 'CounterRates'
        $rates | Should -Match 'where CounterType == 272696576'
        $rates | Should -Match 'CounterValue >= prev\(CounterValue\)'
        $rates | Should -Match 'iff\(Keep, CounterValue - prev\(CounterValue\), 0\.0\)'
        $rates | Should -Match 'TotalEvents / ElapsedSec'
        $rates | Should -Not -Match '(?i)\b(sum|max|min|avg)\(\s*CounterValue\s*\)'

        $gauges = Get-RenderedKql 'CounterGauges'
        $gauges | Should -Match 'where CounterType in \(65792, 537003264\)'
        $gauges | Should -Not -Match '272696576'
        $gauges | Should -Not -Match 'prev\('
    }

    It 'renders the lookback, the targets, and a UTC since as KQL literals' {
        $local = [datetime]::SpecifyKind([datetime]'2026-10-20 05:00:00', [System.DateTimeKind]::Unspecified)
        $kql = Get-DemoHubTelemetryKql -Name ResourceSummary -ResourceId $script:HubT1Id -LookbackMinutes 10080 -Since $local
        $kql | Should -Match 'let lookback = 10080m;'
        $kql | Should -Match 'let since = datetime\(2026-10-20T05:00:00\.0000000Z\);'
        $kql | Should -Match ([regex]::Escape("let targetIds = dynamic(['$($script:HubT1Id)']);"))
        $kql | Should -Not -Match '\{\{'
        $kql | Should -Not -Match '(?m)^\s*//'
        (Get-DemoHubTelemetryKql -Name ResourceSummary -ResourceId $script:HubT1Id) | Should -Match 'let since = ago\(lookback\);'
    }

    It 'uses the default blocking and throughput counters, or the ones passed in' {
        Get-RenderedKql 'CounterGauges' | Should -Match "'Processes blocked'"
        Get-RenderedKql 'CounterRates' | Should -Match "'Number of Deadlocks/sec'"
        Get-DemoHubTelemetryKql -Name CounterGauges -ResourceId $script:HubT1Id -CounterName 'User Connections' | Should -Match "dynamic\(\['User Connections'\]\)"
    }

    It 'refuses a resource ID that could change the query' {
        { Get-DemoHubTelemetryKql -Name ResourceSummary -ResourceId ("{0}' or 1==1 //" -f $script:HubT1Id) } | Should -Throw
        { Get-DemoHubTelemetryKql -Name ResourceSummary -ResourceId 'sqlvm01' } | Should -Throw
        { Get-DemoHubTelemetryKql -Name ResourceSummary -ResourceId $script:HubT1Id -ResourceGroup "rg'x" } | Should -Throw
    }
}

Describe 'KQL literals and templates (internal)' {
    It 'escapes quotes and backslashes and refuses control characters' {
        InModuleScope -ModuleName DbHubDemo {
            ConvertTo-DemoKqlLiteral -Value "a'b\c" -Type String | Should -Be "'a\'b\\c'"
            ConvertTo-DemoKqlLiteral -Value @('x', "y'z") -Type StringArray | Should -Be "dynamic(['x', 'y\'z'])"
            ConvertTo-DemoKqlLiteral -Value @() -Type StringArray | Should -Be 'dynamic([])'
            ConvertTo-DemoKqlLiteral -Value ([timespan]::FromSeconds(90)) -Type Timespan | Should -Be '90s'
            ConvertTo-DemoKqlLiteral -Value ([timespan]::FromHours(2)) -Type Timespan | Should -Be '120m'
            { ConvertTo-DemoKqlLiteral -Value "a`nb" -Type String } | Should -Throw '*control character*'
            { ConvertTo-DemoKqlLiteral -Value ([timespan]::Zero) -Type Timespan } | Should -Throw
        }
    }

    It 'needs a value for every placeholder, refuses unknown values, and replaces in one pass' {
        InModuleScope -ModuleName DbHubDemo {
            { Format-DemoKqlTemplate -Name 'Telemetry.TableSummary' -Parameters @{ Lookback = '5m' } } | Should -Throw '*needs a value for: Targets*'
            { Format-DemoKqlTemplate -Name 'Telemetry.TableSummary' -Parameters @{ Lookback = '5m'; Targets = 'dynamic([])'; Extra = '1' } } | Should -Throw '*no placeholder for: Extra*'
            { Format-DemoKqlTemplate -Name 'Telemetry.Missing' -Parameters @{} } | Should -Throw '*doesn''t exist*'
            $kql = Format-DemoKqlTemplate -Name 'Telemetry.TableSummary' -Parameters @{ Lookback = '5m'; Targets = "dynamic(['{{Lookback}}'])" }
            $kql | Should -Match ([regex]::Escape("let targetIds = dynamic(['{{Lookback}}']);"))
        }
    }

    It 'renders the Resource Graph estate query for the demo resource group' {
        InModuleScope -ModuleName DbHubDemo -Parameters @{ Subscription = $script:HubSubscriptionId } {
            param($Subscription)
            $query = Format-DemoKqlTemplate -Name 'ResourceGraph.Estate' -Parameters @{
                SubscriptionId = ConvertTo-DemoKqlLiteral -Value $Subscription -Type String
                ResourceGroup  = ConvertTo-DemoKqlLiteral -Value 'rg-dbhub-demo' -Type String
            }
            $query | Should -Match "subscriptionId =~ '$Subscription'"
            $query | Should -Match "resourceGroup =~ 'rg-dbhub-demo'"
            foreach ($type in 'microsoft.sqlvirtualmachine/sqlvirtualmachines', 'microsoft.azurearcdata/sqlserverinstances', 'microsoft.sql/servers/databases') {
                $query | Should -Match ([regex]::Escape($type))
            }
        }
    }

    It 'every KQL template cites the Learn page it follows and is ASCII' {
        foreach ($file in Get-ChildItem -LiteralPath $kqlRoot -Filter '*.kql') {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $text | Should -Match 'https://learn\.microsoft\.com/'
            [System.Linq.Enumerable]::Any([byte[]][System.IO.File]::ReadAllBytes($file.FullName), [System.Func[byte, bool]] { param($b) $b -gt 127 }) | Should -BeFalse
        }
        @(Get-ChildItem -LiteralPath $kqlRoot -Filter 'Telemetry.*.kql').Count | Should -Be $templateNames.Count
    }
}

Describe 'Kusto v1 response parsing (internal)' {
    It 'maps rows by column name, converts datetimes to UTC, and ignores the later tables' {
        $json = ConvertTo-HubSummaryJson -Entry @(
            @{ Id = $script:HubT1Id; Type = 'virtualMachines'; Name = 'sqlvm01'; Rows = 120; First = $script:HubNow.AddMinutes(-20); Last = $script:HubNow.AddMinutes(-2) }
            @{ Id = $script:HubT3Id; Type = 'servers/databases'; Name = 'azuresql01-abc123/ContosoCare'; Rows = 40; RowsSince = 10; First = $script:HubNow.AddMinutes(-30); FirstSince = $script:HubNow.AddMinutes(-5); Last = $script:HubNow.AddMinutes(-1); Instances = 1 }
        )
        InModuleScope -ModuleName DbHubDemo -Parameters @{ Json = $json } {
            param($Json)
            $parsed = ConvertFrom-DemoKustoV1Response -Content ($Json | ConvertFrom-Json)
            $parsed.PartialFailure | Should -BeFalse
            $parsed.Columns[0] | Should -Be 'ResourceID'
            $parsed.Rows.Count | Should -Be 2
            $parsed.Rows[1].RowsSince | Should -Be 10
            $parsed.Rows[1].LastSampleUTC.Kind | Should -Be 'Utc'
            $parsed.Rows[1].LastSampleUTC | Should -Be ([datetime]::new(2026, 10, 20, 11, 59, 0, [System.DateTimeKind]::Utc))
            $fromString = ConvertFrom-DemoKustoV1Response -Content $Json
            $fromString.Rows.Count | Should -Be 2
        }
    }

    It 'returns no rows for an empty result and reads 0001-01-01 as not set' {
        $columns = '[{"ColumnName":"LastGoodCheckdbTime","DataType":"DateTime","ColumnType":"datetime"},{"ColumnName":"Name","DataType":"String","ColumnType":"string"}]'
        InModuleScope -ModuleName DbHubDemo -Parameters @{ Columns = $columns } {
            param($Columns)
            (ConvertFrom-DemoKustoV1Response -Content ('{"Tables":[{"TableName":"Table_0","Columns":' + $Columns + ',"Rows":[]}]}')).Rows.Count | Should -Be 0
            $parsed = ConvertFrom-DemoKustoV1Response -Content ('{"Tables":[{"TableName":"Table_0","Columns":' + $Columns + ',"Rows":[["0001-01-01T00:00:00Z","a"],[null,"b"]]}]}')
            $parsed.Rows[0].LastGoodCheckdbTime | Should -BeNullOrEmpty
            $parsed.Rows[1].LastGoodCheckdbTime | Should -BeNullOrEmpty
            $parsed.Rows[1].Name | Should -Be 'b'
        }
    }

    It 'reports a query that failed after it started as a partial failure' {
        InModuleScope -ModuleName DbHubDemo {
            $body = '{"Tables":[{"TableName":"Table_0","Columns":[{"ColumnName":"Rows","DataType":"Int64","ColumnType":"long"}],"Rows":[[5],{"Exceptions":["Query execution has exceeded the allowed limits"]}]}]}'
            $parsed = ConvertFrom-DemoKustoV1Response -Content $body
            $parsed.PartialFailure | Should -BeTrue
            $parsed.Rows.Count | Should -Be 1
            $parsed.Exceptions[0] | Should -Match 'exceeded the allowed limits'
        }
    }

    It 'throws on a body without the documented shape' {
        InModuleScope -ModuleName DbHubDemo {
            { ConvertFrom-DemoKustoV1Response -Content '' } | Should -Throw '*empty body*'
            { ConvertFrom-DemoKustoV1Response -Content 'not json' } | Should -Throw '*isn''t JSON*'
            { ConvertFrom-DemoKustoV1Response -Content '{"value":[]}' } | Should -Throw '*no Tables*'
            { ConvertFrom-DemoKustoV1Response -Content '{"Tables":[{"TableName":"Table_0","Rows":[]}]}' } | Should -Throw '*no Columns*'
            { ConvertFrom-DemoKustoV1Response -Content '{"Tables":[{"Columns":[{"ColumnName":"A","ColumnType":"long"}],"Rows":[[1,2]]}]}' } | Should -Throw '*2 values for 1 columns*'
        }
    }

    It 'applies the freshness rule: Pass when fresh, Warning when stale, Fail without rows' {
        InModuleScope -ModuleName DbHubDemo -Parameters @{ Now = $script:HubNow } {
            param($Now)
            $fresh = Get-DemoTelemetryState -Rows 10 -LastSampleUtc $Now.AddMinutes(-2.5) -NowUtc $Now -FreshMinutes 15
            $fresh.Status | Should -Be 'Pass'
            $fresh.LagMinutes | Should -Be 2.5
            (Get-DemoTelemetryState -Rows 10 -LastSampleUtc $Now.AddMinutes(-15) -NowUtc $Now -FreshMinutes 15).Status | Should -Be 'Pass'
            $stale = Get-DemoTelemetryState -Rows 10 -LastSampleUtc $Now.AddMinutes(-15.2) -NowUtc $Now -FreshMinutes 15
            $stale.Status | Should -Be 'Warning'
            $stale.LagMinutes | Should -Be 15.2
            (Get-DemoTelemetryState -Rows 0 -LastSampleUtc $null -NowUtc $Now -FreshMinutes 15).Status | Should -Be 'Fail'
            (Get-DemoTelemetryState -Rows 3 -LastSampleUtc $Now.AddMinutes(1) -NowUtc $Now -FreshMinutes 15).LagMinutes | Should -Be 0
        }
    }
}

Describe 'Documented interfaces only' {
    BeforeAll {
        $excluded = '[\\/](\.git|node_modules|bin|obj|out|TestResults)[\\/]'
        $gitFiles = @(git -C $repoRoot ls-files --cached --others --exclude-standard 2>$null)
        $visible = if ($LASTEXITCODE -eq 0 -and $gitFiles.Count -gt 0) {
            @($gitFiles | ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path -Path $repoRoot -ChildPath $_)) })
        }
        else {
            @(Get-ChildItem -Path $repoRoot -Recurse -File -Force | Where-Object { $_.FullName -notmatch $excluded } | ForEach-Object { $_.FullName })
        }
    }

    It 'no file outside the docs names a private Database Hub route (repo-wide, including KQL and manifests)' {
        $route = '/v1/databasehub/' + '__private'
        $hits = foreach ($path in $visible) {
            if ($path -match '\.md$' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                continue
            }
            if (Select-String -LiteralPath $path -Pattern $route -SimpleMatch -Quiet) {
                $path.Substring($repoRoot.Length)
            }
        }
        $hits | Should -BeNullOrEmpty
    }

    It 'the Hub validators call only documented hosts' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $hub = $versions.databaseHub
        ([uri]$hub.telemetry.queryUrl).AbsoluteUri | Should -Be 'https://adx.centralus.arcdataservices.com/kusto/v1/rest/query'
        $hub.telemetry.database | Should -Be 'ArcSqlTelemetry'
        $hub.telemetry.tokenAudience | Should -Be 'https://kusto.kusto.windows.net'
        $hub.telemetry.retentionDays | Should -BeLessOrEqual 7
        ([uri]$hub.resourceGraph.url).Host | Should -Be 'management.azure.com'
        ([uri]$hub.fabric.apiBaseUrl).Host | Should -Be 'api.fabric.microsoft.com'
        $hub.fabric.Keys | Should -Not -Contain 'tokenAudience'
        $hub.arcTelemetryRole.roleName | Should -Be 'Azure Hybrid Database Administrator - Read Only Service Role'
        $hub.arcTelemetryRole.Keys | Should -Not -Contain 'id'
        $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo'
        $hubUrls = Get-ChildItem -Path $moduleRoot -Recurse -File -Include '*.ps1', '*.kql' | Select-String -Pattern 'https?://[^\s''"<>)]+' -AllMatches |
            ForEach-Object { $_.Matches.Value } | Where-Object { $_ -match '(?i)databasehub|fdh' }
        $hubUrls | Should -BeNullOrEmpty
    }

    It 'P4 and P5 reach Fabric only through the Phase 12 helpers' {
        $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo'
        $files = @(
            Join-Path -Path $moduleRoot -ChildPath 'Private/HubFabricHelpers.ps1'
            Join-Path -Path $moduleRoot -ChildPath 'Public/Test-DemoFabricHubSetting.ps1'
            Join-Path -Path $moduleRoot -ChildPath 'Public/Test-DemoFabricWorkspace.ps1'
        )
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
            $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
            foreach ($forbidden in 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-DemoAz', 'Invoke-DemoHubRestCall', 'Invoke-DemoHubHttp', 'Get-DemoHubToken') {
                $commands | Should -Not -Contain $forbidden -Because ('{0} must use Get-DemoFabricToken and Invoke-DemoFabricRequest' -f (Split-Path -Path $file -Leaf))
            }
        }
        (Get-Content -LiteralPath $files[0] -Raw) | Should -Match 'Invoke-DemoFabricRequest -Method Get'
        (Get-Content -LiteralPath $files[0] -Raw) | Should -Match 'Get-DemoFabricToken -SubscriptionId'
    }
}
