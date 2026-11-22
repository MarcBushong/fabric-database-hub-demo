BeforeDiscovery {
    $script:nodeAvailable = [bool](Get-Command -Name 'node' -ErrorAction SilentlyContinue)
}

BeforeAll {
    # Phase 19: the committed Power BI artifacts. No network; the generator checks run only where Node.js is installed.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $powerbi = Join-Path -Path $repoRoot -ChildPath 'fabric/powerbi'
    $modelRoot = Join-Path -Path $powerbi -ChildPath 'SM_DatabaseHub_History.SemanticModel'
    $reportRoot = Join-Path -Path $powerbi -ChildPath 'RPT_DatabaseHub_History.Report'
    $guid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $zero = '00000000-0000-0000-0000-000000000000'
    $tableFiles = @(Get-ChildItem -LiteralPath (Join-Path -Path $modelRoot -ChildPath 'definition/tables') -Filter '*.tmdl' -File)

    # Every measure: table, name, the /// description above it, and its properties.
    $script:measures = foreach ($file in $tableFiles) {
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^ {4}measure\s+('(?:[^']|'')+'|\S+)\s*=") {
                $name = $Matches[1].Trim("'").Replace("''", "'")
                $properties = [System.Collections.Generic.List[string]]::new()
                for ($j = $i + 1; $j -lt $lines.Count -and ($lines[$j] -match '^ {5,}' -or $lines[$j] -eq ''); $j++) {
                    if ($lines[$j] -match '^ {8}(\w+)') {
                        $properties.Add($Matches[1])
                    }
                }
                [pscustomobject]@{
                    Table       = $file.BaseName
                    Name        = $name
                    Description = ($i -gt 0 -and $lines[$i - 1] -match '^ {4}///\s*\S')
                    Formatted   = ($properties -contains 'formatString' -or $properties -contains 'formatStringDefinition')
                    Hidden      = $properties -contains 'isHidden'
                }
            }
        }
    }

    # The spec's measure summary: "Name `format`", "Name (dynamic)", or "Name (text)" per visible measure.
    $spec = Get-Content -LiteralPath (Join-Path -Path $powerbi -ChildPath '_brief/report-spec.md') -Raw
    $summary = [regex]::Match($spec, '(?s)\| Table, folder \| Visible measures and formats \|(.+?)\n\n').Groups[1].Value
    $script:specFormats = @{}
    $measureNames = @($script:measures | ForEach-Object { $_.Name })
    $splitNames = {
        param([string] $Names)
        if ($measureNames -contains $Names.Trim()) { return @($Names.Trim()) }
        return @($Names -split ',\s*(?:and\s+)?|\s+and\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    foreach ($row in ($summary -split "`n" | Where-Object { $_ -match '^\| [A-Z]' })) {
        $cells = $row.Trim('|').Split('|')
        foreach ($entry in ($cells[1] -split ';')) {
            $entry = $entry.Trim()
            if ($entry -match '^(?<names>.+?) `(?<format>[^`]+)`$') {
                $format = $Matches['format']
                foreach ($name in (& $splitNames $Matches['names'])) { $script:specFormats[$name] = $format }
            }
            elseif ($entry -match '^(?<names>.+?) \((?<kind>dynamic|text)\)$') {
                $kind = '(' + $Matches['kind'] + ')'
                foreach ($name in (& $splitNames $Matches['names'])) { $script:specFormats[$name] = $kind }
            }
        }
    }
}

Describe 'Semantic model SM_DatabaseHub_History (Phase 19)' {
    It 'is a TMDL folder: definition.pbism, compatibility level 1702, en-US, implicit measures off, 10 tables' {
        Test-Path -LiteralPath (Join-Path -Path $modelRoot -ChildPath 'definition.pbism') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path -Path $modelRoot -ChildPath 'definition/database.tmdl') -Raw | Should -Match 'compatibilityLevel: 1702'
        $model = Get-Content -LiteralPath (Join-Path -Path $modelRoot -ChildPath 'definition/model.tmdl') -Raw
        $model | Should -Match 'culture: en-US'
        $model | Should -Match 'discourageImplicitMeasures'
        $tableFiles.Count | Should -Be 10
        @($script:measures).Count | Should -Be 114
        ([regex]::Matches((Get-Content -LiteralPath (Join-Path -Path $modelRoot -ChildPath 'definition/relationships.tmdl') -Raw), '(?m)^relationship ')).Count | Should -Be 16
    }

    It 'commits no real ID: the only GUIDs are the all-zero OneLake placeholder, twice' {
        $found = foreach ($file in Get-ChildItem -LiteralPath $modelRoot -Recurse -File) {
            foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($file.FullName), $guid)) { $match.Value }
        }
        @($found).Count | Should -Be 2
        @($found | Where-Object { $_ -ne $zero }) | Should -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path -Path $modelRoot -ChildPath 'definition/expressions.tmdl') -Raw | Should -Match ([regex]::Escape("https://onelake.dfs.fabric.microsoft.com/$zero/$zero"))
    }

    It 'reads only the five notebook tables, from schema dbo, through the Direct Lake expression' {
        $text = ($tableFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $entities = @([regex]::Matches($text, '(?m)^\s+entityName:\s*(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        $entities | Should -Be @('analysis_findings', 'incident_windows', 'scenario_runs', 'telemetry_snapshots', 'validation_results')
        @([regex]::Matches($text, '(?m)^\s+schemaName:\s*(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) | Should -Be @('dbo')
        @([regex]::Matches($text, "(?m)^\s+expressionSource:\s*(.+?)\s*$") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) | Should -Be @("'DirectLake - LH_DatabaseHub'")
    }

    It 'gives every measure a /// description' {
        @($script:measures | Where-Object { -not $_.Description } | ForEach-Object { '{0}[{1}]' -f $_.Table, $_.Name }) | Should -BeNullOrEmpty
    }

    It 'names T5 in the Target and Analysis dimensions, and reads its Cosmos DB measures from the rows NB_DatabaseHub_LiveActivity writes (ADR 0027)' {
        $tables = Join-Path -Path $modelRoot -ChildPath 'definition/tables'
        $target = [System.IO.File]::ReadAllText((Join-Path -Path $tables -ChildPath 'Target.tmdl'))
        $target | Should -Match '\{ "T5", "T5 . Azure Cosmos DB", "T5", "Cosmos DB target", "Azure Cosmos DB for NoSQL account", 6 \},'
        $target | Should -Match '\{ "repo", "Repository", "Repo", "Platform scope", "Static checks", 12 \}'
        [System.IO.File]::ReadAllText((Join-Path -Path $tables -ChildPath 'Analysis.tmdl')) | Should -Match '\{ "cosmosdb", "Azure Cosmos DB \(Azure Monitor\)", "Cosmos DB", "Per bin", 19 \}'
        # The notebook's own names for T5's rows: analysis, target, and the metrics it writes.
        $notebook = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks/NB_DatabaseHub_LiveActivity.ipynb') -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $code = (@($notebook['cells'] | Where-Object { $_['cell_type'] -eq 'code' } | ForEach-Object { @($_['source']) -join '' })) -join "`n"
        $code | Should -Match '(?m)^COSMOS_ANALYSIS = "cosmosdb"$'
        $code | Should -Match '(?m)^COSMOS_TARGET = "T5"$'
        $written = @([regex]::Matches([regex]::Match($code, '(?s)COSMOS_METRIC_UNITS = \{(.*?)\n\}').Groups[1].Value, '"(\w+)":') | ForEach-Object { $_.Groups[1].Value })
        $written | Should -Be @('NormalizedRUConsumption', 'TotalRequestUnits', 'TotalRequests', 'ThrottledRequests', 'ServerSideLatencyGateway', 'ProvisionedThroughput', 'ServiceAvailability')
        $snapshots = [System.IO.File]::ReadAllText((Join-Path -Path $tables -ChildPath 'Telemetry Snapshots.tmdl'))
        $expected = [ordered]@{
            'Peak Norm RU (%)'               = 'NormalizedRUConsumption'
            'Cosmos DB Requests'             = 'TotalRequests'
            'Throttled Requests (429s)'      = 'ThrottledRequests'
            'RU Consumed'                    = 'TotalRequestUnits'
            'Provisioned RU/s'               = 'ProvisionedThroughput'
            'Cosmos DB Availability (%)'     = 'ServiceAvailability'
            'Cosmos DB Gateway Latency (ms)' = 'ServerSideLatencyGateway'
        }
        foreach ($name in $expected.Keys) {
            $block = [regex]::Match($snapshots, ("(?ms)^ {{4}}measure '{0}' =.*?(?=^ {{4}}\S|\z)" -f [regex]::Escape($name))).Value
            $block | Should -Match ([regex]::Escape('''Telemetry Snapshots''[Analysis Key] = "cosmosdb"')) -Because $name
            $block | Should -Match ([regex]::Escape(('''Telemetry Snapshots''[Metric] = "{0}"' -f $expected[$name]))) -Because $name
            $block | Should -Match '(?m)^ {8}displayFolder: Cosmos DB$' -Because $name
            $written | Should -Contain $expected[$name] -Because $name
        }
        foreach ($name in '429 Rate (%)', 'Has Cosmos DB Bins', 'Cosmos DB Headline') {
            [regex]::Match($snapshots, ("(?ms)^ {{4}}measure '{0}' =.*?(?=^ {{4}}\S|\z)" -f [regex]::Escape($name))).Value | Should -Match '(?m)^ {8}displayFolder: Cosmos DB$' -Because $name
        }
        $episodes = [regex]::Match([System.IO.File]::ReadAllText((Join-Path -Path $tables -ChildPath 'Analysis Findings.tmdl')), "(?ms)^ {4}measure 'Throttling Episodes' =.*?(?=^ {4}\S|\z)").Value
        $episodes | Should -Match ([regex]::Escape('''Analysis Findings''[Analysis Key] = "cosmosdb"'))
        $episodes | Should -Match ([regex]::Escape('CONTAINSSTRING ( ''Analysis Findings''[Finding ID], ".throttle." )'))
        $code | Should -Match ([regex]::Escape('"key": "throttle.%s" % episode["start"].strftime("%Y%m%dT%H%M")'))
    }

    It 'names no DAX variable after a table or a reserved word' {
        # https://learn.microsoft.com/dax/var-dax: reserved keywords and table names aren't allowed. SCOPE is one: the
        # first live deploy (2026-10-22) reported "The syntax for 'Scope' is incorrect" for VAR Scope.
        $reserved = @('AND', 'ASC', 'AT', 'BY', 'CALCULATIONGROUP', 'COLUMN', 'DEFINE', 'DESC', 'EVALUATE', 'FALSE', 'FUNCTION', 'IN', 'MEASURE', 'NOT', 'OR', 'ORDER', 'RETURN', 'SCOPE', 'START', 'TABLE', 'TRUE', 'VAR')
        $tables = @($tableFiles | ForEach-Object { $_.BaseName.ToUpperInvariant() })
        $text = ($tableFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $names = @([regex]::Matches($text, '\bVAR\s+([A-Za-z_][A-Za-z0-9_]*)\s*=') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $names.Count | Should -BeGreaterThan 20
        @($names | Where-Object { $_.ToUpperInvariant() -in $reserved -or $_.ToUpperInvariant() -in $tables }) | Should -BeNullOrEmpty
    }

    It 'formats every measure exactly as the spec''s measure summary says' {
        $script:specFormats.Count | Should -BeGreaterThan 60
        $problems = foreach ($name in $script:specFormats.Keys) {
            $measure = @($script:measures | Where-Object { $_.Name -eq $name })
            if ($measure.Count -ne 1) { "{0}: {1} measure(s) in the TMDL" -f $name, $measure.Count; continue }
            $expected = $script:specFormats[$name]
            $file = Join-Path -Path $modelRoot -ChildPath ('definition/tables/{0}.tmdl' -f $measure[0].Table)
            $block = [regex]::Match([System.IO.File]::ReadAllText($file), ("(?ms)^ {{4}}measure\s+'?{0}'?\s*=.*?(?=^ {{4}}\S|\z)" -f [regex]::Escape($name))).Value
            switch ($expected) {
                '(text)' { if ($block -match '(?m)^ {8}formatString') { "{0}: a text measure has a format string" -f $name } }
                '(dynamic)' { if ($block -notmatch '(?m)^ {8}formatStringDefinition') { "{0}: no dynamic format string" -f $name } }
                default { if ($block -notmatch ('(?m)^ {{8}}formatString:\s*{0}\s*$' -f [regex]::Escape($expected))) { "{0}: expected format string {1}" -f $name, $expected } }
            }
        }
        @($problems) | Should -BeNullOrEmpty
    }

    It 'leaves a measure unformatted only when the spec calls it text, or it''s a hidden helper' {
        $unformatted = @($script:measures | Where-Object { -not $_.Formatted -and -not $_.Hidden -and $script:specFormats[$_.Name] -ne '(text)' } | ForEach-Object { $_.Name })
        $unformatted | Should -BeNullOrEmpty
    }

    It 'uses spaces, LF line endings, and UTF-8 without a byte order mark' {
        foreach ($file in Get-ChildItem -LiteralPath $modelRoot -Recurse -File) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $bytes -contains 13 | Should -BeFalse -Because $file.Name
            $bytes -contains 9 | Should -BeFalse -Because $file.Name
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse -Because $file.Name
        }
    }
}

Describe 'Snapshot Value: each interval from its finest save (F35)' {
    BeforeAll {
        $snapshotsText = [System.IO.File]::ReadAllText((Join-Path -Path $modelRoot -ChildPath 'definition/tables/Telemetry Snapshots.tmdl'))
        $script:measure = [regex]::Match($snapshotsText, "(?ms)^ {4}measure 'Snapshot Value' =\n(.*?)(?=^ {8}\S)").Groups[1].Value
        $script:checks = Join-Path -Path $powerbi -ChildPath 'checks/f35'
        $script:squash = { param([string] $Text) ($Text -replace '\s+', ' ').Trim() }
        $script:items = { param([string] $List) @([regex]::Matches($List, '"([^"]+)"|(\d+)') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { [int] $_.Groups[2].Value } }) }
        $script:tsList = {
            param([string] $Text, [string] $Name)
            $match = [regex]::Match($Text, ('{0}(?::[^=]+)? = (?:new Set\()?\[([^\]]*)\]' -f [regex]::Escape($Name)))
            $match.Success | Should -BeTrue -Because $Name
            & $script:items $match.Groups[1].Value
        }
        $script:daxList = {
            param([string] $Pattern)
            $match = [regex]::Match($script:measure, $Pattern)
            $match.Success | Should -BeTrue -Because $Pattern
            & $script:items $match.Groups['list'].Value
        }
    }

    It 'tells totals from peaks, Azure Monitor from SQL, hourly metrics, and analyses off the bin grid by the shared rule''s lists' {
        # finest-per-interval.test.ts ties these lists to the notebooks and the history helpers that write the rows.
        $shared = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath 'fabric/app/src/data/finest-per-interval.ts'))
        $reference = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath 'fabric/app/src/data/snapshot-value.ts'))
        $adds = [regex]::Match($script:measure, 'VAR Adds = AnalysisName IN \{ (?<a>[^}]*) \} \|\| MetricName IN \{ (?<m>[^}]*) \}')
        $adds.Success | Should -BeTrue
        & $script:items $adds.Groups['a'].Value | Should -Be (& $script:tsList $shared 'ADDITIVE_ANALYSES')
        & $script:items $adds.Groups['m'].Value | Should -Be (& $script:tsList $shared 'ADDITIVE_METRICS')
        & $script:daxList 'VAR OffGrid = ISBLANK \( Bin \) \|\| AnalysisName IN \{ (?<list>[^}]*) \}' | Should -Be (& $script:tsList $shared 'OFF_GRID_ANALYSES')
        & $script:daxList 'VAR IsHourly = MetricName IN \{ (?<list>[^}]*) \}' | Should -Be (& $script:tsList $shared 'HOURLY_METRICS')
        & $script:daxList "NOT \( 'Telemetry Snapshots'\[Metric\] IN \{ (?<list>[^}]*) \} \)" | Should -Be (& $script:tsList $shared 'HOURLY_METRICS')
        & $script:daxList 'VAR IsMonitor = AnalysisName IN \{ (?<list>[^}]*) \}' | Should -Be (& $script:tsList $reference 'MONITOR_ANALYSES')
        # Azure Monitor's step: the intervals the history helpers step up through. SQL's: the notebook's own bin rule.
        $ladder = & $script:daxList 'SELECTCOLUMNS \( \{ (?<list>[^}]*) \}, "@Step"'
        $ladder | Should -Be (& $script:tsList $reference 'LADDER')
        foreach ($helper in 'PostgresHistoryHelpers.ps1', 'CosmosHistoryHelpers.ps1') {
            $text = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath "scripts/modules/DbHubDemo/Private/$helper"))
            & $script:items ([regex]::Match($text, '(?m)^\$script:\w+HistoryIntervals = @\(([^)]*)\)').Groups[1].Value) | Should -Be $ladder -Because $helper
        }
        $script:measure | Should -Match ([regex]::Escape('IF ( SpanMinutes <= 120.000001, 1, IF ( SpanMinutes <= 720.000001, 5, 15 ) )'))
        $reference | Should -Match ([regex]::Escape('span <= 120 + 1e-6 ? 1 : span <= 720 + 1e-6 ? 5 : 15'))
        $notebook = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks/NB_DatabaseHub_LiveActivity.ipynb') -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $code = (@($notebook['cells'] | Where-Object { $_['cell_type'] -eq 'code' } | ForEach-Object { @($_['source']) -join '' })) -join "`n"
        $code | Should -Match ([regex]::Escape('bin_minutes = int(BIN_MINUTES) or (1 if span_minutes <= 120 else 5 if span_minutes <= 720 else 15)'))
    }

    It 'reads each save whole, whatever the period selected: its saves, its step, its rows'' extent, and the rows of a partly covered interval' {
        # report_date_utc is each row's bin date, so a period through 'Date' would cut a day-long save at midnight and
        # change the step its bins give.
        $removes = @([regex]::Matches($script:measure, "REMOVEFILTERS \( 'Telemetry Snapshots'\[Bucket UTC\][^)]*\)") | ForEach-Object { $_.Value })
        $removes.Count | Should -Be 6
        $removes | ForEach-Object { $_ | Should -Match ([regex]::Escape("'Telemetry Snapshots'[Report Date UTC]")) }
        ([regex]::Matches($script:measure, [regex]::Escape("REMOVEFILTERS ( 'Date' )"))).Count | Should -Be $removes.Count
    }

    It 'checks a live model with the measures'' own expressions, in read-only query files' {
        $tmdlText = [System.IO.File]::ReadAllText((Join-Path -Path $modelRoot -ChildPath 'definition/tables/Telemetry Snapshots.tmdl'))
        $tmdlMeasure = {
            param([string] $Name)
            $quoted = "'" + $Name.Replace("'", "''") + "'"
            $match = [regex]::Match($tmdlText, ("(?ms)^ {{4}}measure (?:{0}|{1}) =\n(.*?)(?=^ {{0,8}}\S)" -f [regex]::Escape($quoted), [regex]::Escape($Name)))
            $match.Success | Should -BeTrue -Because $Name
            & $script:squash $match.Groups[1].Value
        }
        (& $tmdlMeasure 'Snapshot Value').Length | Should -BeGreaterThan 10000
        $defined = @{}
        foreach ($file in Get-ChildItem -LiteralPath $script:checks -Filter '*.dax' -File) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $blocks = @([regex]::Matches($text, "(?ms)^    MEASURE 'Telemetry Snapshots'\[([^\]]+)\] =\n(.*?)(?=^    MEASURE |^EVALUATE)"))
            $names = @($blocks | ForEach-Object { $_.Groups[1].Value })
            $defined[$file.Name] = $names
            foreach ($block in $blocks | Where-Object { $_.Groups[1].Value -ne 'Replica Lag Peak (s)' }) {
                $name = $block.Groups[1].Value
                & $script:squash $block.Groups[2].Value | Should -BeExactly (& $tmdlMeasure ($name -replace ' F35$', '')) -Because ('{0} [{1}]' -f $file.Name, $name)
            }
            if ($file.Name -like '*-f35.dax') {
                # A model measure reads the deployed Snapshot Value whatever a query defines (live, 602e18a1's first run): each
                # measure a check evaluates, or that one of its measures reads, is defined in it.
                $code = $text -replace '//[^\n]*', ''
                $referenced = @([regex]::Matches($code, "(?<!['\w\]])\[([^\]@][^\]]*)\]") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'Value' } | Sort-Object -Unique)
                $referenced.Count | Should -BeGreaterThan 3 -Because $file.Name
                @($referenced | Where-Object { $names -notcontains $_ }) | Should -BeNullOrEmpty -Because $file.Name
                $names[0] | Should -Be 'Snapshot Value' -Because $file.Name
            }
        }
        $defined['snapshot-value-bins.dax'] | Should -Be @('Snapshot Value F35')
        @($defined['window-f35.dax']).Count | Should -Be 15
        # The read replica's lag has no model measure: both window checks define the same one.
        $replica = foreach ($name in 'window-today.dax', 'window-f35.dax') {
            $text = [System.IO.File]::ReadAllText((Join-Path -Path $script:checks -ChildPath $name))
            & $script:squash ([regex]::Match($text, "(?ms)^    MEASURE 'Telemetry Snapshots'\[Replica Lag Peak \(s\)\] =\n(.*?)(?=^    MEASURE |^EVALUATE)").Groups[1].Value)
        }
        $replica[0] | Should -Match ([regex]::Escape('''Telemetry Snapshots''[Metric] = "physical_replication_delay_in_seconds"'))
        $replica[1] | Should -BeExactly $replica[0]
        $files = @(Get-ChildItem -LiteralPath $script:checks -File | Sort-Object -Property Name | ForEach-Object { $_.Name })
        $files | Should -Be @('estate-f35.dax', 'estate-today.dax', 'README.md', 'rows-monitor.dax', 'rows-saves.dax', 'rows-sql.dax', 'snapshot-value-bins.dax', 't5-f35.dax', 't5-today.dax', 'window-f35.dax', 'window-today.dax')
        foreach ($file in Get-ChildItem -LiteralPath $script:checks -File) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $bytes -contains 13 | Should -BeFalse -Because $file.Name
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse -Because $file.Name
            if ($file.Extension -eq '.dax') {
                @($bytes | Where-Object { $_ -eq 9 -or $_ -gt 127 }) | Should -BeNullOrEmpty -Because $file.Name
            }
        }
    }
}

Describe 'DAX variable names' {
    BeforeAll {
        # Learn's VAR page: a name has only a-z, A-Z, and 0-9, never a digit first, with __ allowed as a prefix, and isn't a
        # reserved keyword or an existing table's name (https://learn.microsoft.com/dax/var-dax). Live, the engine refused
        # 'Under' (2026-11-22) in a measure whose texts every other check passed, so each DAX source is checked here.
        $script:reservedWords = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($line in [System.IO.File]::ReadAllLines((Join-Path -Path $PSScriptRoot -ChildPath 'data/dax-reserved-words.txt'))) {
            if ($line -and -not $line.StartsWith('#')) {
                [void]$script:reservedWords.Add($line.Trim())
            }
        }
        $script:tableNames = @($tableFiles | ForEach-Object {
                [regex]::Match([System.IO.File]::ReadAllText($_.FullName), "(?m)^table\s+('(?:[^']|'')+'|\S+)").Groups[1].Value.Trim("'").Replace("''", "'")
            })
        # The model's measures, every DAX file in fabric/powerbi (the F35 checks among them), and the Insights app's queries.
        $script:daxSources = @($tableFiles) + @(Get-ChildItem -LiteralPath $powerbi -Filter '*.dax' -File -Recurse) +
            @(Get-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'fabric/app/src/data/queries.ts'))
    }

    It 'has the reserved words and the model''s tables to check against' {
        $script:reservedWords.Count | Should -BeGreaterThan 500
        foreach ($word in 'UNDER', 'FUNCTION', 'EVALUATE', 'RETURN', 'CALCULATE', 'FIRST', 'ROWS', 'CURRENTMEMBER') {
            $script:reservedWords.Contains($word) | Should -BeTrue -Because $word
        }
        $script:tableNames | Should -Contain 'Telemetry Snapshots'
        $script:tableNames | Should -Contain 'Date'
    }

    It 'names every VAR as Learn allows: letters and digits, never a DAX keyword, a function''s name, or a table''s' {
        $declared = 0
        $problems = foreach ($file in $script:daxSources) {
            $text = [System.IO.File]::ReadAllText($file.FullName) -replace '//[^\n]*', ''
            # In TypeScript, only the DAX keyword's upper case, never the language's own var.
            $options = if ($file.Extension -eq '.ts') { [System.Text.RegularExpressions.RegexOptions]::None } else { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
            foreach ($match in [regex]::Matches($text, '\bVAR\s+([^\s=]+)\s*=', $options)) {
                $declared++
                $name = $match.Groups[1].Value
                if ($name -cnotmatch '^(__)?[A-Za-z][A-Za-z0-9]*$') {
                    '{0}: VAR {1} has a character a variable''s name can''t' -f $file.Name, $name
                }
                elseif ($script:reservedWords.Contains($name)) {
                    '{0}: VAR {1} is a DAX keyword or function name' -f $file.Name, $name
                }
                elseif ($script:tableNames -contains $name) {
                    '{0}: VAR {1} is a table''s name' -f $file.Name, $name
                }
            }
        }
        $declared | Should -BeGreaterThan 400
        @($problems | Sort-Object -Unique) | Should -BeNullOrEmpty
    }
}

Describe 'Report RPT_DatabaseHub_History (Phase 19)' {
    It 'has the PBIR folder shape: byPath binding, report.json, version.json, four pages with 10, 8, 11, and 10 visuals' {
        $pbir = Get-Content -LiteralPath (Join-Path -Path $reportRoot -ChildPath 'definition.pbir') -Raw | ConvertFrom-Json -AsHashtable
        $pbir['datasetReference'].Keys | Should -Be @('byPath')
        $pbir['datasetReference']['byPath']['path'] | Should -Be '../SM_DatabaseHub_History.SemanticModel'
        foreach ($file in 'definition/report.json', 'definition/version.json', 'definition/pages/pages.json', 'definition/bookmarks/bookmarks.json', '.platform') {
            Test-Path -LiteralPath (Join-Path -Path $reportRoot -ChildPath $file) | Should -BeTrue -Because $file
        }
        $pages = Get-Content -LiteralPath (Join-Path -Path $reportRoot -ChildPath 'definition/pages/pages.json') -Raw | ConvertFrom-Json
        $counts = foreach ($page in $pages.pageOrder) { @(Get-ChildItem -LiteralPath (Join-Path -Path $reportRoot -ChildPath "definition/pages/$page/visuals") -Recurse -Filter 'visual.json').Count }
        $counts | Should -Be @(10, 8, 11, 10)
        Test-Path -LiteralPath (Join-Path -Path $powerbi -ChildPath 'DbHubHistory.pbip') | Should -BeTrue
    }

    It 'registers the DbHub Cockpit Dark theme under its file name, with the base theme vendored' {
        $report = Get-Content -LiteralPath (Join-Path -Path $reportRoot -ChildPath 'definition/report.json') -Raw | ConvertFrom-Json
        $custom = $report.themeCollection.customTheme
        $custom.type | Should -Be 'RegisteredResources'
        $custom.name | Should -Match '^DbHubCockpitDark-[0-9a-f]{8}\.json$'
        $theme = Get-Content -LiteralPath (Join-Path -Path $reportRoot -ChildPath "StaticResources/RegisteredResources/$($custom.name)") -Raw | ConvertFrom-Json
        $theme.background | Should -Be '#0E0E10'
        Test-Path -LiteralPath (Join-Path -Path $reportRoot -ChildPath "StaticResources/SharedResources/BaseThemes/$($report.themeCollection.baseTheme.name).json") | Should -BeTrue
    }

    It 'binds only fields that exist in the semantic model' {
        $tmdl = ($tableFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $missing = foreach ($file in Get-ChildItem -LiteralPath (Join-Path -Path $reportRoot -ChildPath 'definition') -Recurse -Filter '*.json') {
            foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($file.FullName), '"Entity":\s*"(?<table>[^"]+)"\s*}\s*},\s*"Property":\s*"(?<name>[^"]+)"')) {
                $name = $match.Groups['name'].Value
                $quoted = if ($name -match '[^A-Za-z0-9_]') { "'{0}'" -f $name.Replace("'", "''") } else { $name }
                if ($tmdl -notmatch ("(?m)^ {{4}}(measure|column)\s+{0}(\s|$)" -f [regex]::Escape($quoted))) { '{0}[{1}]' -f $match.Groups['table'].Value, $name }
            }
        }
        @($missing | Sort-Object -Unique) | Should -BeNullOrEmpty
    }

    It 'matches a fresh run of the generator' -Skip:(-not $script:nodeAvailable) {
        Push-Location -LiteralPath (Join-Path -Path $powerbi -ChildPath 'generator')
        try {
            if (-not (Test-Path -LiteralPath 'node_modules/yaml')) {
                Set-ItResult -Skipped -Because 'the generator''s npm dependencies aren''t installed (npm ci)'
                return
            }
            $output = & node src/generate.js --check 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        }
        finally {
            Pop-Location
        }
    }
}

Describe 'configure-powerbi.ps1 (Phase 19)' {
    It 'is a documented, unattended deploy step: help, SupportsShouldProcess, and no prompt or sign-in' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/configure-powerbi.ps1') -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.4'
        $text | Should -Match '\.SYNOPSIS'
        $text | Should -Match 'SupportsShouldProcess'
        $text | Should -Match 'Assert-DemoAzContext'
        $text | Should -Not -Match 'Read-Host|Get-Credential|ConfirmImpact = .High'
        $text | Should -Not -Match "'login'|'logout'|'set'"
    }

    It 'creates no app: the Fabric app (Rayfin) is a separate item, and the org app was dropped' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/configure-powerbi.ps1') -Raw
        $text | Should -Not -Match 'OrgApp|SkipOrgApp|APP_DatabaseHub_Demo'
        Test-Path -LiteralPath (Join-Path -Path $powerbi -ChildPath 'orgapp') | Should -BeFalse
    }

    It 'calls only functions that DbHubDemo exports' {
        # A script can't reach the module's private functions: -CheckModelData once called one and failed live.
        $exports = (Import-PowerShellDataFile -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1')).FunctionsToExport
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path -Path $repoRoot -ChildPath 'scripts/configure-powerbi.ps1'), [ref]$null, [ref]$null)
        $called = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '^[A-Z][a-z]+-Demo' } | Sort-Object -Unique)
        $called.Count | Should -BeGreaterThan 10
        @($called | Where-Object { $_ -notin $exports }) | Should -BeNullOrEmpty
    }
}
