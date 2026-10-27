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
        @($script:measures).Count | Should -Be 103
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
