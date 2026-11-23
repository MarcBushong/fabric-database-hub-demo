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

    # Strips comments in one pass from the start, so a // or /* inside a string, a name, or another comment, or a double
    # quote inside a name, is text there and can't hide the code after it.
    # - DAX: "..." strings, with "" inside, also across lines; 'table' and [column] names, which can't hold an apostrophe,
    #   a slash, a bracket, or a control character such as a newline, but can hold a double quote
    #   (https://learn.microsoft.com/dax/dax-syntax-reference); and // and /* */ comments. The DAX query view's page
    #   lists those two, not -- (https://learn.microsoft.com/power-bi/transform-model/dax-query-view), so a -- line is
    #   kept whole: a name in it is still checked, and a double quote in it opens no string.
    # - TypeScript: '...', "...", and `...` strings, where a backslash escapes, and // and /* */ comments. A template's
    #   text is kept whole, a DAX comment in it included, so a name there is checked too: at worst, a false alarm.
    # A /* */ comment becomes a space, so the words on either side stay apart. Its limits, which none of the files it
    # reads has: a string or a /* that's never closed, or a template inside another's ${...}, can shift what it reads
    # as a string or a comment from there on.
    $script:stripComments = {
        param([string] $Text, [bool] $TypeScript)
        $kept = if ($TypeScript) { '''(?:[^''\\\n]|\\[\s\S])*''|"(?:[^"\\\n]|\\[\s\S])*"|`(?:[^`\\]|\\[\s\S])*`' } else { '"(?:[^"]|"")*"|''[^''\n]*''|\[[^\]\n]*\]|--[^\n]*' }
        [regex]::Replace($Text, '(?<kept>' + $kept + ')|(?<block>/\*[\s\S]*?\*/)|//[^\n]*', [System.Text.RegularExpressions.MatchEvaluator] { param($Match) if ($Match.Groups['kept'].Success) { $Match.Value } elseif ($Match.Groups['block'].Success) { ' ' } else { '' } })
    }

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
        foreach ($file in @(Get-ChildItem -LiteralPath $modelRoot -Recurse -File) + @(Get-ChildItem -LiteralPath (Join-Path -Path $powerbi -ChildPath 'kept-value') -File)) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $bytes -contains 13 | Should -BeFalse -Because $file.Name
            $bytes -contains 9 | Should -BeFalse -Because $file.Name
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse -Because $file.Name
        }
    }
}

Describe 'Snapshot Value''s kept form (F35, design (i))' {
    BeforeAll {
        $script:kept = [System.IO.File]::ReadAllText((Join-Path -Path $powerbi -ChildPath 'kept-value/Snapshot Value.tmdl'))
        $script:keptMeasure = [regex]::Match($script:kept, "(?ms)^    measure 'Snapshot Value' =\n.*?^        displayFolder: Base\n").Value
        $script:releaseMeasure = [regex]::Match([System.IO.File]::ReadAllText((Join-Path -Path $modelRoot -ChildPath 'definition/tables/Telemetry Snapshots.tmdl')), "(?ms)^    measure 'Snapshot Value' =\n.*?^        displayFolder: Base\n").Value
        $script:sharedLists = (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'fabric/history/kept-value-cases.json') -Raw | ConvertFrom-Json -AsHashtable)['lists']
        $script:inList = {
            param([string] $Column)
            $list = [regex]::Match($script:keptMeasure, ("'Telemetry Snapshots'\[{0}\] IN \{{ ([^}}]*) \}}" -f [regex]::Escape($Column)))
            return @([regex]::Matches($list.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        }
    }

    It 'takes the shared rule''s lists: totals by analysis and by metric, and the analyses off the bin grid' {
        $script:keptMeasure | Should -Not -BeNullOrEmpty
        # The shared cases list them sorted as JavaScript sorts, by code unit.
        $ordinal = {
            param([string[]] $Items)
            $sorted = [string[]]@($Items)
            [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
            $sorted
        }
        # Two IN lists on Analysis Key: the grid's exceptions, then the totals.
        $analysisLists = @([regex]::Matches($script:keptMeasure, "'Telemetry Snapshots'\[Analysis Key\] IN \{ ([^}]*) \}") | ForEach-Object { , @([regex]::Matches($_.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) })
        $analysisLists.Count | Should -Be 2
        @(& $ordinal $analysisLists[0]) | Should -Be @($script:sharedLists['offGridAnalyses'])
        @(& $ordinal $analysisLists[1]) | Should -Be @($script:sharedLists['additiveAnalyses'])
        @(& $ordinal (& $script:inList 'Metric')) | Should -Be @($script:sharedLists['additiveMetrics'])
    }

    It 'reads the kept values only where every row of a bin on the grid is worked out, and the release''s rule everywhere else' {
        $script:keptMeasure | Should -Match ([regex]::Escape("NOT ISBLANK ( 'Telemetry Snapshots'[Bucket UTC] )"))
        $script:keptMeasure | Should -Match ([regex]::Escape("ISEMPTY ( CALCULATETABLE ( 'Telemetry Snapshots', ISBLANK ( 'Telemetry Snapshots'[Resolved At UTC] ) ) )"))
        # A total sums its kept values; a maximum or an average takes the highest capture's sum, as bin_values reads them.
        $script:keptMeasure | Should -Match ([regex]::Escape("CALCULATE ( SUM ( 'Telemetry Snapshots'[Kept Value] ) ),"))
        $script:keptMeasure | Should -Match ([regex]::Escape("CALCULATE ( MAXX ( VALUES ( 'Telemetry Snapshots'[Captured At UTC] ), CALCULATE ( SUM ( 'Telemetry Snapshots'[Kept Value] ) ) ) )"))
        # The fallback is the release's measure, word for word: the most recent capture's sum.
        $release = [regex]::Match($script:releaseMeasure, '(?s)VAR LatestCapture = (.*?)\n\s+RETURN\n\s+(CALCULATE \( SUM [^\n]+)')
        $release.Success | Should -BeTrue
        $script:keptMeasure | Should -Match ([regex]::Escape('VAR LatestCapture = ' + $release.Groups[1].Value))
        $script:keptMeasure | Should -Match ([regex]::Escape($release.Groups[2].Value))
        # Same grouping as the release's, and the same format, visibility, and folder.
        $script:keptMeasure | Should -Match ([regex]::Escape("SUMMARIZE (`n                    'Telemetry Snapshots',`n                    'Telemetry Snapshots'[Target Key],`n                    'Telemetry Snapshots'[Analysis Key],`n                    'Telemetry Snapshots'[Metric],`n                    'Telemetry Snapshots'[Bucket UTC]`n                )"))
        $script:releaseMeasure | Should -Match ([regex]::Escape("SUMMARIZE (`n                    'Telemetry Snapshots',`n                    'Telemetry Snapshots'[Target Key],`n                    'Telemetry Snapshots'[Analysis Key],`n                    'Telemetry Snapshots'[Metric],`n                    'Telemetry Snapshots'[Bucket UTC]`n                )"))
        ($script:keptMeasure -split "`n")[-4..-2] | Should -Be @('        formatString: #,0.##', '        isHidden', '        displayFolder: Base')
    }

    It 'reads every bin by the release''s rule while a query filters a column that tells a bin''s saves apart, as Ask''s latest T5 run does (the review of f2298b18)' {
        # A kept value is a row's share against every save, so a filter that leaves some of a bin's saves out would leave out
        # what the others hold: Ask's T5 rule reads TREATAS ( LatestRun, 'Telemetry Snapshots'[Run ID] ).
        $filtered = @([regex]::Matches($script:keptMeasure, "NOT ISFILTERED \( 'Telemetry Snapshots'\[([^\]]+)\] \)") | ForEach-Object { $_.Groups[1].Value })
        $filtered | Should -Be @('Run ID', 'Source Notebook', 'Captured At UTC', 'Window Start UTC', 'Window End UTC', 'Value', 'Kept Value', 'Resolved At UTC')
        $script:keptMeasure | Should -Match ([regex]::Escape("VAR WorkedOut =`n                    OnGrid`n                        && EverySave`n                        && ISEMPTY ( CALCULATETABLE ("))
        # Every column of the table is in that list, or holds the same value in every save's rows of a bin: the bin's keys,
        # the row's resource, and its report date, which is the bin's. A new column has to be put on one side.
        $release = [System.IO.File]::ReadAllText((Join-Path -Path $modelRoot -ChildPath 'definition/tables/Telemetry Snapshots.tmdl'))
        $columns = @([regex]::Matches($release + "`n" + $script:kept, "(?m)^    column ('(?:[^']|'')+'|\S+)$") | ForEach-Object { $_.Groups[1].Value.Trim("'").Replace("''", "'") })
        $columns.Count | Should -Be 18
        $sameInEverySave = @('Target Key', 'Analysis Key', 'Metric', 'Bucket UTC', 'Resource Type', 'Resource Name', 'Instance Name', 'Database Name', 'Unit', 'Report Date UTC')
        @($columns | Where-Object { $_ -notin $filtered -and $_ -notin $sameInEverySave }) | Should -BeNullOrEmpty
        @($filtered + $sameInEverySave | Where-Object { $_ -notin $columns }) | Should -BeNullOrEmpty
    }

    It 'reads its two columns from the columns the notebooks write, hidden' {
        $notebook = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks/NB_DatabaseHub_LiveActivity.ipynb') -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $code = (@($notebook['cells'] | Where-Object { $_['cell_type'] -eq 'code' } | ForEach-Object { @($_['source']) -join '' })) -join "`n"
        $code | Should -Match '\("kept_value", "double"\), \("resolved_at_utc", "timestamp"\)'
        $columns = @([regex]::Matches($script:kept, "(?ms)^    column '([^']+)'\n(.*?)(?=\n\n|\z)") | ForEach-Object { [pscustomobject]@{ Name = $_.Groups[1].Value; Body = $_.Groups[2].Value } })
        @($columns.Name) | Should -Be @('Kept Value', 'Resolved At UTC')
        $columns[0].Body | Should -Match '(?m)^        dataType: double$'
        $columns[0].Body | Should -Match '(?m)^        sourceColumn: kept_value$'
        $columns[1].Body | Should -Match '(?m)^        dataType: dateTime$'
        $columns[1].Body | Should -Match '(?m)^        sourceColumn: resolved_at_utc$'
        foreach ($column in $columns) {
            $column.Body | Should -Match '(?m)^        isHidden$' -Because $column.Name
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
        # The model's measures, Snapshot Value's kept form (F35), every DAX file in fabric/powerbi, and the Insights app's queries.
        $script:daxSources = @($tableFiles) + @(Get-ChildItem -LiteralPath (Join-Path -Path $powerbi -ChildPath 'kept-value') -Filter '*.tmdl' -File) +
            @(Get-ChildItem -LiteralPath $powerbi -Filter '*.dax' -File -Recurse) +
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
            $text = & $script:stripComments ([System.IO.File]::ReadAllText($file.FullName)) ($file.Extension -eq '.ts')
            # DAX keywords are case-insensitive. In TypeScript, the language's own var is a lint error there (no-var), so a
            # var in any case is DAX's.
            foreach ($match in [regex]::Matches($text, '\bVAR\s+([^\s=]+)\s*=', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
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
        # 81 on 2026-11-22: a floor, so a stripper or a path that reads nothing can't pass.
        $declared | Should -BeGreaterThan 60
        @($problems | Sort-Object -Unique) | Should -BeNullOrEmpty
    }

    It 'reads a // inside a string as text, and finds a lowercase var, so neither hides a name' {
        $dax = "VAR Url = ""https://learn.microsoft.com"" VAR Under = 1 // VAR Hidden = 2`nRETURN Url"
        $stripped = & $script:stripComments $dax $false
        $stripped | Should -BeLikeExactly '*VAR Under = 1 *'
        $stripped | Should -Not -BeLike '*Hidden*'
        $ts = "const q = ``var Under = 1`` // var Hidden = 2`nconst u = 'https://x' + ""a//b"""
        $tsStripped = & $script:stripComments $ts $true
        @([regex]::Matches($tsStripped, '\bVAR\s+([^\s=]+)\s*=', 'IgnoreCase') | ForEach-Object { $_.Groups[1].Value }) -join ',' | Should -BeExactly 'Under'
        $tsStripped | Should -BeLikeExactly "*'https://x' + ""a//b""*"
    }

    It 'finds every name after a /* */ comment, a string across lines, a URL in a template, and a name or -- line with a double quote in it' {
        $dax = @(
            '/* https://x */ VAR A1 = 1'
            'VAR A2 = "a string'
            'across two lines, https://x" VAR A3 = 3'
            '/* one'
            'two // three */ VAR A4 = 4 VAR/* a comment is a space */A5 = 5'
            'VAR A6 = ''Odd "Table''[Col] VAR A7 = "https://x" VAR A8 = 8'
            'VAR A9 = [Say "x] VAR A10 = "https://x" VAR A11 = 11'
            '-- a "quote, and VAR A12 = 12 is still read'
            'VAR A13 = "https://x" VAR A14 = 14 /* VAR Hidden = 0 */ // VAR Hidden = 0'
        ) -join "`n"
        $names = { param([string] $Code) @([regex]::Matches($Code, '\bVAR\s+([^\s=]+)\s*=', 'IgnoreCase') | ForEach-Object { $_.Groups[1].Value }) -join ',' }
        & $names (& $script:stripComments $dax $false) | Should -BeExactly 'A1,A2,A3,A4,A5,A6,A7,A8,A9,A10,A11,A12,A13,A14'
        $ts = @(
            '/* https://x */ var T1 = 1'
            '/** an odd ` in a doc comment */'
            'const q = `var T2 = 2 // the query''s own text'
            'VAR T3 = "https://x" VAR T4 = 4`'
            'const s = ''it\''s // text'' + "a\"b // text" // var Hidden = 0'
            'const u = ''a line \'
            'continued // text''; var T5 = 5'
            'const v = `https://x/${id}`; var T6 = 6'
        ) -join "`n"
        $tsStripped = & $script:stripComments $ts $true
        & $names $tsStripped | Should -BeExactly 'T1,T2,T3,T4,T5,T6'
        $tsStripped.Contains('''it\''s // text'' + "a\"b // text"') | Should -BeTrue
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
