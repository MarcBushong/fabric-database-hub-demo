BeforeAll {
    # The Real-Time Dashboard as code (Phase 18): fabric/realtime/RealTimeDashboard.json, built by
    # Export-DemoRealTimeDashboard from fabric/realtime/dashboard.spec.psd1 and the shared KQL in
    # scripts/modules/DbHubDemo/Kql. These tests check the definition's structure, the KQL rules of the telemetry
    # article, that the KQL can't drift from the live-activity notebook, and that the file holds no secret or real ID.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    $script:kqlRoot = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/Kql'
    $script:dashboardPath = Join-Path -Path $repoRoot -ChildPath 'fabric/realtime/RealTimeDashboard.json'
    $script:specPath = Join-Path -Path $repoRoot -ChildPath 'fabric/realtime/dashboard.spec.psd1'
    $script:notebookPath = Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks/NB_DatabaseHub_LiveActivity.ipynb'
    $script:versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:pin = $script:versions['databaseHub']['realTimeDashboard']
    $script:committedText = ([System.IO.File]::ReadAllText($script:dashboardPath)).Replace("`r`n", "`n")
    $script:dashboard = $script:committedText | ConvertFrom-Json -AsHashtable -Depth 64
    $script:spec = Import-PowerShellDataFile -LiteralPath $script:specPath

    # The 13 tables documented on the telemetry page.
    $script:telemetryTables = @(
        'SqlServerCPUUtilization', 'SqlServerWaitStats', 'SqlServerMemoryUtilization', 'SqlServerPerformanceCountersCommon',
        'SqlServerPerformanceCountersDetailed', 'SqlServerStorageIO', 'SqlServerDatabaseStorageUtilization',
        'SqlServerDatabaseProperties', 'SqlServerActiveSessions', 'SqlServerClientConnections',
        'SqlServerAvailabilityGroupStates', 'SqlServerAvailabilityReplicaStates', 'SqlServerDatabaseReplicaStates'
    )
    # Notebook query variable -> shared KQL file (Kql/Live.<name>.kql).
    $script:liveMap = [ordered]@{
        PULSE_KQL        = 'EstatePulse'
        GAUGES_KQL       = 'CounterGauges'
        RATES_KQL        = 'CounterDeltas'
        WAITS_KQL        = 'WaitDeltas'
        SESSIONS_KQL     = 'ActiveSessions'
        CPU_SUMMARY_KQL  = 'CpuSummary'
        CPU_TIMELINE_KQL = 'CpuTimeline'
        STORAGE_IO_KQL   = 'StorageIoDeltas'
        MEMORY_KQL       = 'MemoryClerks'
        GROWTH_KQL       = 'DatabaseGrowth'
    }

    function Get-TestKqlBody {
        # A KQL file without its comment lines and blank lines, the way Format-DemoKqlTemplate reads it.
        param([string] $Name)
        $lines = Get-Content -LiteralPath (Join-Path -Path $script:kqlRoot -ChildPath "$Name.kql")
        @($lines | Where-Object { $_ -notmatch '^\s*//' -and -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    }

    function Get-TestNotebookCode {
        $notebook = Get-Content -LiteralPath $script:notebookPath -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        (@($notebook['cells'] | Where-Object { $_['cell_type'] -eq 'code' } | ForEach-Object { @($_['source']) -join '' }) -join "`n").Replace("`r`n", "`n")
    }

    function Get-TestNotebookKql {
        # NAME_KQL = prelude + """...""" (or kql_prelude(WINDOW_START, WINDOW_END, BIN) + """...""") in the notebook.
        $blocks = [ordered]@{}
        foreach ($match in [regex]::Matches((Get-TestNotebookCode), '(?ms)^([A-Z_]+_KQL) = (?:prelude|kql_prelude\(WINDOW_START, WINDOW_END, BIN\)) \+ """\n(.*?)"""')) {
            $blocks[$match.Groups[1].Value] = $match.Groups[2].Value
        }
        $blocks
    }

    function Get-TestStableGuid([string] $Key) {
        InModuleScope -ModuleName DbHubDemo -Parameters @{ Key = $Key } { ConvertTo-DemoStableGuid -Key $Key }
    }

    function Test-TestDocument([System.Collections.IDictionary] $Document, [switch] $Rendered) {
        InModuleScope -ModuleName DbHubDemo -Parameters @{ Document = $Document; Rendered = [bool]$Rendered } { @(Test-DemoDashboardDocument -Document $Document -Rendered:$Rendered) }
    }

    function Copy-TestDashboard {
        $script:committedText | ConvertFrom-Json -AsHashtable -Depth 64
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'The Real-Time Dashboard definition (fabric/realtime/RealTimeDashboard.json)' {
    It 'is up to date with dashboard.spec.psd1 and the KQL: run Export-DemoRealTimeDashboard after you change either' {
        $built = Export-DemoRealTimeDashboard -WhatIf -PassThru -SpecPath $script:specPath -Path (Join-Path -Path $TestDrive -ChildPath 'unused.json')
        $built | Should -BeExactly $script:committedText
        Test-Path -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'unused.json') | Should -BeFalse
    }

    It 'passes every rule of the pinned schema version that the validator checks' {
        @(Test-TestDocument -Document $script:dashboard) | Should -BeNullOrEmpty
    }

    It 'is the documented KQL dashboard definition at the pinned schema version, without the properties Fabric owns' {
        $script:pin['definitionPart'] | Should -Be 'RealTimeDashboard.json'
        $script:pin['itemType'] | Should -Be 'KQLDashboard'
        $script:dashboard['schema_version'] | Should -BeExactly $script:pin['schemaVersion']
        $script:dashboard['schema_version'] | Should -BeOfType ([string])
        $script:dashboard['$schema'] | Should -BeExactly ('https://dataexplorer.azure.com/static/d/schema/{0}/dashboard.json' -f $script:pin['schemaVersion'])
        foreach ($key in 'schema_version', 'title', 'tiles', 'baseQueries', 'parameters', 'dataSources', 'pages', 'queries') {
            $script:dashboard.Contains($key) | Should -BeTrue -Because "the schema requires $key"
        }
        $script:dashboard.Contains('id') | Should -BeFalse
        $script:dashboard.Contains('eTag') | Should -BeFalse
    }

    It 'has one data source: the documented SQL ADX proxy and ArcSqlTelemetry, with no stored connection or credential' {
        $sources = @($script:dashboard['dataSources'])
        $sources.Count | Should -Be 1
        @($sources[0].Keys) | Should -Be @('id', 'name', 'scopeId', 'kind', 'clusterUri', 'database')
        $sources[0]['kind'] | Should -BeExactly 'manual-kusto'
        $sources[0]['scopeId'] | Should -BeExactly 'kusto'
        # The connection URI on Learn's monitor-sql page, the same in every region.
        $sources[0]['clusterUri'] | Should -BeExactly 'https://adx.centralus.arcdataservices.com/kusto/'
        $sources[0]['clusterUri'] | Should -BeExactly $script:versions['databaseHub']['telemetry']['connectionUri']
        $sources[0]['database'] | Should -BeExactly 'ArcSqlTelemetry'
        foreach ($query in $script:dashboard['queries']) {
            $query['dataSource']['kind'] | Should -BeExactly 'inline'
            $query['dataSource']['dataSourceId'] | Should -BeExactly $sources[0]['id']
        }
    }

    It 'has the presenter''s parameters: a time range (default: the last hour) and Target (T1, T2, T3, or all)' {
        $parameters = @($script:dashboard['parameters'])
        $parameters.Count | Should -Be 2
        $range = $parameters | Where-Object { $_['kind'] -eq 'duration' }
        $range['beginVariableName'] | Should -BeExactly '_startTime'
        $range['endVariableName'] | Should -BeExactly '_endTime'
        $range['defaultValue']['kind'] | Should -Be 'dynamic'
        $range['defaultValue']['count'] | Should -Be 1
        $range['defaultValue']['unit'] | Should -Be 'hours'
        $targets = $parameters | Where-Object { $_['kind'] -eq 'string' }
        $targets['variableName'] | Should -BeExactly '_selectedTargets'
        $targets['selectionType'] | Should -Be 'array'
        $targets['includeAllOption'] | Should -BeTrue
        $targets['defaultValue']['kind'] | Should -Be 'all'
        $targets['dataSource']['kind'] | Should -Be 'static'
        @($targets['dataSource']['values'] | ForEach-Object { $_['value'] }) | Should -Be @('T1', 'T2', 'T3')
        foreach ($parameter in $parameters) {
            $parameter['showOnPages']['kind'] | Should -Be 'all'
        }
    }

    It 'refreshes on its own, every minute at most' {
        $script:dashboard['autoRefresh']['enabled'] | Should -BeTrue
        $script:dashboard['autoRefresh']['defaultInterval'] | Should -Be '1m'
        $script:dashboard['autoRefresh']['minInterval'] | Should -Be '1m'
    }

    It 'has the Estate pulse, Incident, and Resources pages with the tiles the brief names' {
        @($script:dashboard['pages'] | ForEach-Object { $_['name'] }) | Should -Be @('Estate pulse', 'Incident', 'Resources')
        $byPage = @{}
        foreach ($page in $script:dashboard['pages']) {
            $byPage[$page['name']] = (@($script:dashboard['tiles'] | Where-Object { $_['pageId'] -eq $page['id'] } | ForEach-Object { $_['title'] }) -join ' | ')
        }
        foreach ($expected in 'Freshness', 'tables, rows, and the newest sample', 'heartbeat') {
            $byPage['Estate pulse'] | Should -Match ([regex]::Escape($expected))
        }
        foreach ($expected in 'Processes blocked', 'Waits by category', 'Active sessions', 'Batch requests', 'CPU') {
            $byPage['Incident'] | Should -Match ([regex]::Escape($expected))
        }
        foreach ($expected in 'CPU', 'memory', 'IO') {
            $byPage['Resources'] | Should -Match ([regex]::Escape($expected))
        }
    }

    It 'uses color only for status: conditional formatting in red, yellow, or green on stat and table tiles, never on charts' {
        $colored = 0
        foreach ($tile in $script:dashboard['tiles']) {
            $options = $tile['visualOptions']
            $rules = @(if ($options.Contains('colorRules')) { $options['colorRules'] })
            if ($tile['visualType'] -notin 'multistat', 'table') {
                $rules | Should -BeNullOrEmpty -Because "$($tile['title']) is a chart"
            }
            foreach ($rule in $rules) {
                $rule['ruleType'] | Should -Be 'colorByCondition'
                $rule['color'] | Should -BeIn @('red', 'yellow', 'green')
                $colored++
            }
            # No fixed series colors or color palettes anywhere.
            ($options | ConvertTo-Json -Depth 10 -Compress) | Should -Not -Match '(?i)palette|seriesColor'
        }
        $colored | Should -BeGreaterThan 0
    }

    It 'shows its numbers large: every multi stat tile uses the large text size' {
        foreach ($tile in @($script:dashboard['tiles'] | Where-Object { $_['visualType'] -eq 'multistat' })) {
            $tile['visualOptions']['multiStat__textSize'] | Should -Be 'large'
        }
    }

    It 'lays out every tile inside the 24-column grid without overlaps, and every tile but the note uses a query' {
        foreach ($page in $script:dashboard['pages']) {
            $cells = @{}
            foreach ($tile in @($script:dashboard['tiles'] | Where-Object { $_['pageId'] -eq $page['id'] })) {
                $layout = $tile['layout']
                ($layout['x'] + $layout['width']) | Should -BeLessOrEqual 24
                for ($x = $layout['x']; $x -lt $layout['x'] + $layout['width']; $x++) {
                    for ($y = $layout['y']; $y -lt $layout['y'] + $layout['height']; $y++) {
                        $cells.ContainsKey("$x,$y") | Should -BeFalse -Because "$($tile['title']) overlaps $($cells["$x,$y"])"
                        $cells["$x,$y"] = $tile['title']
                    }
                }
            }
        }
        $queryIds = @($script:dashboard['queries'] | ForEach-Object { $_['id'] })
        foreach ($tile in $script:dashboard['tiles']) {
            if ($tile['visualType'] -eq 'markdownCard') {
                $tile['markdownText'] | Should -Match 'preview'
                continue
            }
            $tile['queryRef']['kind'] | Should -Be 'query'
            $tile['queryRef']['queryId'] | Should -BeIn $queryIds
        }
        # Every query is used by at least one tile.
        foreach ($id in $queryIds) {
            @($script:dashboard['tiles'] | Where-Object { $_.Contains('queryRef') -and $_['queryRef']['queryId'] -eq $id }).Count | Should -BeGreaterThan 0
        }
    }

    It 'lists in usedVariables exactly the parameter variables each query uses' {
        foreach ($query in $script:dashboard['queries']) {
            $expected = @('_startTime', '_endTime', '_selectedTargets' | Where-Object { $query['text'] -match ('(?<![A-Za-z0-9_])' + $_ + '(?![A-Za-z0-9_])') })
            @($query['usedVariables']) | Should -Be $expected
            @($query['usedVariables']) | Should -Contain '_selectedTargets' -Because 'every query honors the Target parameter'
        }
    }
}

Describe 'The dashboard''s KQL (rules in the telemetry article)' {
    BeforeAll {
        $script:queries = @($script:dashboard['queries'] | ForEach-Object { [string]$_['text'] })
        $script:prelude = $script:queries[0].Substring(0, $script:queries[0].IndexOf("`n};", [System.StringComparison]::Ordinal) + 3)
    }

    It 'starts every query with the shared prelude: the time range, a bin from it, the demo''s names, and _target()' {
        foreach ($text in $script:queries) {
            $text.StartsWith($script:prelude, [System.StringComparison]::Ordinal) | Should -BeTrue
        }
        $script:prelude | Should -Match '(?m)^let _start = _startTime;$'
        $script:prelude | Should -Match '(?m)^let _end = _endTime;$'
        $script:prelude | Should -Match '(?m)^let _bin = case\(_endTime - _startTime <= 2h, 1m, _endTime - _startTime <= 12h, 5m, 15m\);$'
        $script:prelude | Should -Match '(?m)^let _rg = \{\{ResourceGroup\}\};$'
        $script:prelude | Should -Match "(?m)^let _t1 = 'sqlvm01';$"
        $script:prelude | Should -Match "(?m)^let _t2 = 'arcsql01';$"
        $script:prelude | Should -Match "(?m)^let _t3prefix = 'azuresql01-';$"
        $script:prelude | Should -Match "(?m)^let _t3suffix = '/ContosoCare';$"
    }

    It 'filters on SampleTimeUTC right after every telemetry table it reads, then on the demo resource group (rule 1)' {
        $tablePattern = '(?m)(?:^|withsource=\w+\s+)((?:' + ($script:telemetryTables -join '|') + ')|SqlServer\*)\s*$'
        $reads = 0
        foreach ($text in $script:queries) {
            foreach ($source in [regex]::Matches($text, $tablePattern)) {
                $reads++
                $after = $text.Substring($source.Index + $source.Length)
                $after | Should -Match '^\s*\|\s*where\s+SampleTimeUTC\s+(>|between)\s'
                $after | Should -Match '^\s*\|[^\n]*\n\|\s*where\s+ResourceGroup\s*=~\s*_rg\s*\n'
            }
        }
        $reads | Should -Be $script:queries.Count -Because 'each query reads one telemetry table or the SqlServer* union'
    }

    It 'takes per-series deltas of cumulative counters, skips resets, and never sums the raw values (rules 2 and 4)' {
        $cumulative = 0
        foreach ($text in $script:queries) {
            if ($text -match 'SqlServerWaitStats|SqlServerStorageIO|CounterType == 272696576') {
                $cumulative++
                $text | Should -Match 'Keep = ResourceID == prev\(ResourceID\) and SqlServerInstanceName == prev\(SqlServerInstanceName\)'
                $text | Should -Match 'iff\(Keep, '
                $text | Should -Not -Match '\b(sum|avg|max|min)\((WaitTimeMs|WaitingTasksCount|SignalWaitTimeMs|NumOfBytesRead|NumOfBytesWritten|IOStallReadMs|IOStallWriteMs|NumOfReads|NumOfWrites|CounterValue|V|W|C|R)\)'
                $text | Should -Not -Match 'max\([^)]*\)\s*-\s*min\('
            }
        }
        $cumulative | Should -BeGreaterOrEqual 4
    }

    It 'branches on CounterType for performance counters (rule 3)' {
        foreach ($text in @($script:queries | Where-Object { $_ -match 'SqlServerPerformanceCounters' })) {
            $text | Should -Match '\|\s*where CounterType (==|in) '
        }
    }

    It 'compares ResourceID only case-insensitively or with itself (rule 5), and excludes Idle and Unknown waits (rule 6)' {
        foreach ($text in $script:queries) {
            $text | Should -Not -Match 'ResourceID\s*==\s*[''"]'
            $text | Should -Not -Match 'ResourceID\s+in\s*\('
            if ($text -match 'SqlServerWaitStats') {
                $text | Should -Match "WaitCategory !in \('Idle', 'Unknown'\)"
            }
        }
    }

    It 'limits its rows with take, top, or an aggregation (rule 10)' {
        foreach ($text in $script:queries) {
            $text | Should -Match '\|\s*(take \d+|top \d+|summarize )'
        }
    }

    It 'applies the Target parameter to every query, and leaves T3''s storage latency empty, as the article requires' {
        foreach ($text in $script:queries) {
            $text | Should -Match ([regex]::Escape('| where isempty(_selectedTargets) or Target in (_selectedTargets)'))
        }
        ($script:queries | Where-Object { $_ -match 'ReadLatencyMs' }) | Should -Match "iff\(Target == 'T3'"
    }
}

Describe 'The shared KQL and the live-activity notebook' {
    It 'mirrors every prelude-based notebook query in Kql/Live.*.kql, byte for byte, and nothing else' {
        $notebook = Get-TestNotebookKql
        @($notebook.Keys) | Should -Be @($script:liveMap.Keys)
        foreach ($variable in $script:liveMap.Keys) {
            $body = Get-TestKqlBody -Name ('Live.' + $script:liveMap[$variable])
            $body | Should -BeExactly $notebook[$variable] -Because "Kql/Live.$($script:liveMap[$variable]).kql must equal $variable in NB_DatabaseHub_LiveActivity"
        }
        $files = @(Get-ChildItem -LiteralPath $script:kqlRoot -Filter 'Live.*.kql' | ForEach-Object { $_.BaseName.Substring(5) } | Where-Object { $_ -ne 'Prelude' } | Sort-Object)
        $files | Should -Be @($script:liveMap.Values | Sort-Object)
    }

    It 'mirrors the notebook''s kql_prelude() in Kql/Live.Prelude.kql, line for line' {
        $code = Get-TestNotebookCode
        $function = [regex]::Match($code, '(?s)def kql_prelude\(start, end, bin_minutes=1\):.*?return "\\n"\.join\(\[(.*?)\]\)')
        $function.Success | Should -BeTrue
        $python = @([regex]::Matches($function.Groups[1].Value, '"((?:[^"\\]|\\.)*)"(?:\s*%[^\n]*)?,') | ForEach-Object { $_.Groups[1].Value -replace '%dm|%s|%d', '<value>' })
        $template = @((Get-TestKqlBody -Name 'Live.Prelude') -split "`n" | ForEach-Object { $_ -replace '\{\{[A-Za-z]+\}\}', '<value>' })
        $template | Should -Be $python
    }

    It 'renders the dashboard''s prelude from the same file' {
        $rendered = InModuleScope -ModuleName DbHubDemo {
            Format-DemoKqlTemplate -Name 'Live.Prelude' -Parameters ([ordered]@{
                    Start = '_startTime'; End = '_endTime'; Bin = 'case(_endTime - _startTime <= 2h, 1m, _endTime - _startTime <= 12h, 5m, 15m)'
                    ResourceGroup = '{{ResourceGroup}}'; Database = "'ContosoCare'"; VmName = "'sqlvm01'"; ArcMachineName = "'arcsql01'"
                    ServerPrefix = "'azuresql01-'"; DatabaseSuffix = "'/ContosoCare'"
                })
        }
        $script:dashboard['queries'][0]['text'].StartsWith($rendered + "`n", [System.StringComparison]::Ordinal) | Should -BeTrue
    }

    It 'builds every dashboard query from the shared files the spec names' {
        foreach ($query in $script:spec['Queries']) {
            $id = Get-TestStableGuid -Key ('query/' + $query['Key'])
            $text = ($script:dashboard['queries'] | Where-Object { $_['id'] -eq $id })['text']
            foreach ($fragment in $query['Kql']) {
                $text | Should -Match ([regex]::Escape((Get-TestKqlBody -Name $fragment)))
            }
        }
    }
}

Describe 'The dashboard holds no secrets and no real IDs' {
    It 'has only element IDs: the name-based UUIDs of the spec''s keys' {
        $expected = [System.Collections.Generic.HashSet[string]]::new()
        [void]$expected.Add((Get-TestStableGuid -Key ('datasource/' + $script:spec['DataSource']['Key'])))
        [void]$expected.Add((Get-TestStableGuid -Key 'parameter/time-range'))
        [void]$expected.Add((Get-TestStableGuid -Key 'parameter/targets'))
        foreach ($page in $script:spec['Pages']) { [void]$expected.Add((Get-TestStableGuid -Key ('page/' + $page['Key']))) }
        foreach ($query in $script:spec['Queries']) { [void]$expected.Add((Get-TestStableGuid -Key ('query/' + $query['Key']))) }
        foreach ($tile in $script:spec['Tiles']) {
            $key = '{0}/{1}' -f $tile['Page'], $tile['Key']
            [void]$expected.Add((Get-TestStableGuid -Key ('tile/' + $key)))
            for ($index = 0; $index -lt @(if ($tile.Contains('ColorRules')) { $tile['ColorRules'] }).Count; $index++) {
                [void]$expected.Add((Get-TestStableGuid -Key ('colorrule/{0}/{1}' -f $key, $index)))
            }
        }
        $found = @([regex]::Matches($script:committedText, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value } | Select-Object -Unique)
        foreach ($guid in $found) {
            $expected.Contains($guid) | Should -BeTrue -Because "$guid must be an element ID derived from the spec, never a real ID"
        }
        @($found).Count | Should -Be $expected.Count
    }

    It 'derives element IDs as RFC 4122 version 5 UUIDs in the URL namespace' {
        # Python: uuid.uuid5(uuid.NAMESPACE_URL, 'https://github.com/MarcBushong/fabric-database-hub-demo/fabric/realtime#page/incident')
        Get-TestStableGuid -Key 'page/incident' | Should -BeExactly 'ab7fd829-77a8-56a7-ae68-8649f2587158'
        Get-TestStableGuid -Key 'page/incident' | Should -BeExactly (Get-TestStableGuid -Key 'page/incident')
        Get-TestStableGuid -Key 'page/resources' | Should -Not -Be (Get-TestStableGuid -Key 'page/incident')
    }

    It 'holds no resource path, token, secret, email address, or credential setting, and is ASCII' {
        $script:committedText | Should -Not -Match '(?i)/subscriptions/'
        $script:committedText | Should -Not -Match 'eyJ[A-Za-z0-9_-]{5,}\.'
        $script:committedText | Should -Not -Match '(?i)bearer\s|password|secret|accessToken|clientSecret|connectionString'
        $script:committedText | Should -Not -Match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
        $script:committedText | Should -Not -Match '(?i)"(cloudConnection|connectionId|credential|identity)"'
        [System.Linq.Enumerable]::Any([byte[]][System.IO.File]::ReadAllBytes($script:dashboardPath), [System.Func[byte, bool]] { param($b) $b -gt 127 }) | Should -BeFalse
    }

    It 'leaves the resource group as the only placeholder, for the import to fill in' {
        @([regex]::Matches($script:committedText, '\{\{([A-Za-z]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) | Should -Be @('ResourceGroup')
        $script:committedText | Should -Not -Match "rg-[a-z0-9]+-[a-z0-9]+'"
    }
}

Describe 'Test-DemoDashboardDocument (the validator)' {
    It 'reports <Name>' -ForEach @(
        @{ Name = 'a tile without a query'; Change = { param($d) $d['tiles'][1].Remove('queryRef') }; Expect = 'must reference one of the dashboard' }
        @{ Name = 'overlapping tiles'; Change = { param($d) $d['tiles'][2]['layout']['x'] = 0 }; Expect = 'overlap' }
        @{ Name = 'a tile wider than the grid'; Change = { param($d) $d['tiles'][0]['layout']['width'] = 25 }; Expect = 'wider than the 24-column grid' }
        @{ Name = 'a variable no parameter declares'; Change = { param($d) $d['queries'][0]['text'] += "`n| where Target == _unknown"; $d['queries'][0]['usedVariables'] += '_unknown' }; Expect = 'no parameter declares' }
        @{ Name = 'usedVariables that disagree with the text'; Change = { param($d) $d['queries'][0]['usedVariables'] = @('_startTime') }; Expect = 'disagree' }
        @{ Name = 'a foreign ID'; Change = { param($d) $d['title'] = 'Workspace 99999999-8888-7777-6666-555555555555' }; Expect = 'an ID it doesn''t define' }
        @{ Name = 'an Azure resource path'; Change = { param($d) $d['tiles'][0]['markdownText'] = 'See /subscriptions/x/resourceGroups/y' }; Expect = 'resource path' }
        @{ Name = 'another data source'; Change = { param($d) $d['dataSources'][0]['clusterUri'] = 'https://help.kusto.windows.net' }; Expect = 'SQL ADX proxy' }
        @{ Name = 'the wrong schema version'; Change = { param($d) $d['schema_version'] = '89' }; Expect = 'schema_version' }
        @{ Name = 'a property Fabric owns'; Change = { param($d) $d['eTag'] = 'x' }; Expect = 'Fabric owns' }
        @{ Name = 'an unknown color'; Change = { param($d) $d['tiles'][1]['visualOptions']['colorRules'][0]['color'] = 'purple' }; Expect = 'invalid color' }
        @{ Name = 'an unknown top-level property'; Change = { param($d) $d['theme'] = 'dark' }; Expect = 'Unknown top-level property: theme' }
        @{ Name = 'a malformed layout'; Change = { param($d) $d['tiles'][0].Remove('layout') }; Expect = 'expected shape|invalid layout' }
    ) {
        $document = Copy-TestDashboard
        & $Change $document
        $problems = @(Test-TestDocument -Document $document)
        ($problems -join ' ') | Should -Match $Expect
    }

    It 'refuses the placeholder in a rendered definition, and any other placeholder in a template' {
        (@(Test-TestDocument -Document (Copy-TestDashboard) -Rendered) -join ' ') | Should -Match 'still has placeholders: ResourceGroup'
        $document = Copy-TestDashboard
        $document['queries'][0]['text'] = $document['queries'][0]['text'].Replace('{{ResourceGroup}}', '{{Subscription}}')
        (@(Test-TestDocument -Document $document) -join ' ') | Should -Match 'placeholders other than ResourceGroup'
    }
}
