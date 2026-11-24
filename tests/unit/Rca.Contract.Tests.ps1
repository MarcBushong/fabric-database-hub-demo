BeforeDiscovery {
    $repoRootForDiscovery = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $evidenceFixtures = @(Get-ChildItem -Path (Join-Path -Path $repoRootForDiscovery -ChildPath 'rca/fixtures') -Filter '*.evidence.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName; Parts = $_.FullName -replace '\.evidence\.json$', '.parts.txt' } })
    $transportFixtures = @('rca-evidence.parameter.json', 'metrics-bundle.json', 'metrics-rca-member.json', 'export-index.json') |
        ForEach-Object { @{ Name = $_; Path = (Join-Path -Path $repoRootForDiscovery -ChildPath "rca/fixtures/$_") } }
}

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $rcaRoot = Join-Path -Path $repoRoot -ChildPath 'rca'
    $evidenceSchemaPath = Join-Path -Path $rcaRoot -ChildPath 'evidence.schema.json'
    $transportSchemaPath = Join-Path -Path $rcaRoot -ChildPath 'transport.schema.json'
    $evidenceSchema = Get-Content -LiteralPath $evidenceSchemaPath -Raw | ConvertFrom-Json -AsHashtable
    $transportSchema = Get-Content -LiteralPath $transportSchemaPath -Raw | ConvertFrom-Json -AsHashtable
    $tables = Get-Content -LiteralPath (Join-Path -Path $rcaRoot -ChildPath 'history-tables.json') -Raw | ConvertFrom-Json -AsHashtable
    $blind = Get-Content -LiteralPath (Join-Path -Path $rcaRoot -ChildPath 'blind-detection.json') -Raw | ConvertFrom-Json -AsHashtable
    $detectionTables = @($tables.tables | Where-Object { $_.role -eq 'detection' })
    $answerKeyTables = @($tables.tables | Where-Object { $_.role -eq 'answerKey' })
    $scenarioIds = @(Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'scenarios') -Directory | ForEach-Object {
            (Get-Content -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'scenario.json') -Raw | ConvertFrom-Json).id
        })
    $documentTypes = @('string', 'timestamp', 'long', 'integer', 'double', 'boolean')

    function Get-WholeTokenPattern {
        param([Parameter(Mandatory = $true)][string] $Token)
        # A scenario ID counts only as a whole token: not inside a longer word, a path, or a URL.
        return '(?<![A-Za-z0-9_./-]){0}(?![A-Za-z0-9_./-])' -f [regex]::Escape($Token)
    }

    function Get-DetectionStringViolation {
        param([Parameter(Mandatory = $true)][string] $Text)
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $scenarioIds) {
            if ($Text -cmatch (Get-WholeTokenPattern -Token $id)) { $found.Add("scenario ID $id") }
        }
        return $found
    }

    function ConvertFrom-RcaPartLine {
        param([Parameter(Mandatory = $true)][string[]] $Line)
        $parsed = foreach ($text in $Line) {
            $fields = $text.Split(' ')
            [pscustomobject]@{ DocumentId = $fields[2]; Index = [int]$fields[3].Split('/')[0]; Count = [int]$fields[3].Split('/')[1]; Sha256 = $fields[4]; Data = $fields[5] }
        }
        return @($parsed)
    }

    function Expand-RcaDocument {
        param([Parameter(Mandatory = $true)][object[]] $Part)
        $ordered = @($Part | Sort-Object -Property Index)
        $buffer = [System.IO.MemoryStream]::new()
        foreach ($piece in $ordered) {
            $bytes = [System.Convert]::FromBase64String($piece.Data)
            $buffer.Write($bytes, 0, $bytes.Length)
        }
        $gzip = $buffer.ToArray()
        $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($gzip)).ToLowerInvariant()
        $compressed = [System.IO.MemoryStream]::new($gzip)
        $stream = [System.IO.Compression.GZipStream]::new($compressed, [System.IO.Compression.CompressionMode]::Decompress)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        try {
            $json = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        return [pscustomobject]@{ Sha256 = $hash; Json = $json }
    }
}

Describe 'The Incident RCA contract: schemas and tables (ADR 0031)' {
    It 'writes both schemas as JSON Schema 2020-12 with the repository''s $id' {
        $evidenceSchema['$schema'] | Should -Be 'https://json-schema.org/draft/2020-12/schema'
        $transportSchema['$schema'] | Should -Be 'https://json-schema.org/draft/2020-12/schema'
        $evidenceSchema['$id'] | Should -Be 'https://github.com/MarcBushong/fabric-database-hub-demo/rca/evidence.schema.json'
        $transportSchema['$id'] | Should -Be 'https://github.com/MarcBushong/fabric-database-hub-demo/rca/transport.schema.json'
    }

    It 'has seven detection tables and one answer-key table, each with its own lakehouse and model name' {
        $detectionTables.Count | Should -Be 7
        $answerKeyTables.Count | Should -Be 1
        @($tables.tables.name | Sort-Object -Unique).Count | Should -Be 8
        @($tables.tables.model | Sort-Object -Unique).Count | Should -Be 8
        foreach ($table in $tables.tables) {
            $table.name | Should -Match '^rca_[a-z_]+$'
            $table.model | Should -Match '^RCA [A-Z][A-Za-z ]+$'
            $table.primaryTime | Should -BeIn @($table.columns.name)
        }
    }

    It 'gives every column a notebook type, a snake_case name, a model column unique in its table, and a description' {
        foreach ($table in $tables.tables) {
            @($table.columns.model.column + $tables.notebookColumns.model.column | Sort-Object -Unique).Count | Should -Be (@($table.columns).Count + @($tables.notebookColumns).Count) -Because $table.name
            foreach ($column in $table.columns) {
                $column.name | Should -Match '^[a-z][a-z0-9_]*$'
                $column.type | Should -BeIn $documentTypes -Because "$($table.name).$($column.name)"
                $column.description | Should -Not -BeNullOrEmpty
                $column.model.column | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'keeps the answer key out of every detection table' {
        foreach ($table in $detectionTables) {
            @($table.columns.name) | Should -Not -Contain 'scenario'
            @($table.columns.name) | Should -Not -Contain 'scenario_run_id'
            @($table.columns.name) | Should -Not -Contain 'incident_key'
            @($table.columns.name) | Should -Not -Contain 'request_id'
            if ($table.Contains('kinds')) { @($table.kinds) | Should -Not -Contain 'run-event' }
        }
    }

    It 'relates every table only to Target and Date, and purges all eight and the evidence inbox' {
        @($tables.relationships.toTable | Sort-Object) | Should -Be @('Date', 'Target')
        @($tables.purge | Sort-Object) | Should -Be @($tables.tables.name | Sort-Object)
        @($tables.purgeFiles) | Should -Be @('Files/rca/inbox')
    }

    It 'gives every measure a known table, a format, and a description' {
        foreach ($measure in $tables.measures) {
            $measure.table | Should -BeIn @($tables.tables.model)
            $measure.formatString | Should -Not -BeNullOrEmpty
            $measure.description | Should -Not -BeNullOrEmpty
        }
    }

    It 'generates evidence.schema.json from history-tables.json: the same tables, columns, types, and required columns' {
        foreach ($table in $tables.tables) {
            $section = if ($table.role -eq 'detection') { $evidenceSchema.properties.tables.properties } else { $evidenceSchema.properties.answerKey.properties.tables.properties }
            $section.Contains($table.name) | Should -BeTrue -Because $table.name
            $columns = $section[$table.name].properties.columns
            @($columns.properties.Keys | Sort-Object) | Should -Be @($table.columns.name | Sort-Object) -Because $table.name
            # Under the static validation's Set-StrictMode -Version Latest, a column without 'required' has no such key or property.
            $isRequired = { param($c) if ($c -is [System.Collections.IDictionary]) { [bool]($c.Contains('required') -and $c['required']) } else { [bool]($c.PSObject.Properties['required'] -and $c.PSObject.Properties['required'].Value) } }
            @($columns.required | Sort-Object) | Should -Be @($table.columns | Where-Object { & $isRequired $_ } | ForEach-Object { $_.name } | Sort-Object) -Because $table.name
            foreach ($column in $table.columns) {
                $expected = '#/$defs/{0}{1}Column' -f $column.type, $(if (& $isRequired $column) { 'Required' } else { '' })
                $columns.properties[$column.name]['$ref'] | Should -Be $expected -Because "$($table.name).$($column.name)"
            }
        }
    }
}

Describe 'The Incident RCA contract: evidence fixtures (ADR 0031)' {
    It '<Name> validates against evidence.schema.json' -ForEach $evidenceFixtures {
        $schemaErrors = $null
        $valid = Test-Json -Path $Path -SchemaFile $evidenceSchemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
        $valid | Should -BeTrue -Because ($schemaErrors | Out-String)
    }

    It '<Name> has every column as long as its table, and every string an index into its own dictionary' -ForEach $evidenceFixtures {
        $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        foreach ($section in @(@{ Strings = $document.strings; Tables = $document.tables }, @{ Strings = $document.answerKey.strings; Tables = $document.answerKey.tables })) {
            foreach ($name in $section.Tables.Keys) {
                $table = $section.Tables[$name]
                $definition = $tables.tables | Where-Object { $_.name -eq $name }
                foreach ($columnName in $table.columns.Keys) {
                    $values = @($table.columns[$columnName])
                    $values.Count | Should -Be $table.rows -Because "$name.$columnName"
                    $type = ($definition.columns | Where-Object { $_.name -eq $columnName }).type
                    if ($type -eq 'string') {
                        foreach ($value in $values) {
                            if ($null -ne $value) { $value | Should -BeLessThan @($section.Strings).Count -Because "$name.$columnName" }
                        }
                    }
                }
            }
        }
    }

    It '<Name> covers each of its targets in rca_coverage' -ForEach $evidenceFixtures {
        $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        $covered = @($document.tables.rca_coverage.columns.target | ForEach-Object { $document.strings[$_] } | Sort-Object)
        $covered | Should -Be @($document.targets | Sort-Object)
    }

    It '<Name> keeps the detection tables blind: no scenario ID, run ID, or answer-key string, and program names without their segments' -ForEach $evidenceFixtures {
        $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        $violations = foreach ($text in $document.strings) { Get-DetectionStringViolation -Text $text }
        @($violations) | Should -BeNullOrEmpty
        $keyRunIds = @($document.answerKey.tables.rca_answer_key.columns.scenario_run_id | ForEach-Object { $document.answerKey.strings[$_] })
        foreach ($runId in $keyRunIds) {
            @($document.strings | Where-Object { $_.Contains($runId) }) | Should -BeNullOrEmpty -Because "run ID $runId is the answer key's"
        }
        foreach ($name in $document.tables.Keys) {
            $columns = $document.tables[$name].columns
            foreach ($columnName in @('program_name', 'conflict_holder_program')) {
                if ($columns.Contains($columnName)) {
                    @($columns[$columnName] | Where-Object { $null -ne $_ } | ForEach-Object { $document.strings[$_] } | Sort-Object -Unique) | Should -Be @('ContosoCare.Demo')
                }
            }
        }
    }

    It '<Name> decodes from its parts: complete, in order, with the SHA-256 every part names' -ForEach $evidenceFixtures {
        $lines = @(Get-Content -LiteralPath $Parts | Where-Object { $_ })
        $pattern = $transportSchema['$defs'].partLine.pattern
        foreach ($line in $lines) {
            $line.Length | Should -BeLessOrEqual 3400
            $line | Should -MatchExactly $pattern
        }
        $parsed = ConvertFrom-RcaPartLine -Line $lines
        @($parsed.Index | Sort-Object) | Should -Be @(1..$parsed[0].Count)
        @($parsed.Sha256 | Sort-Object -Unique).Count | Should -Be 1
        $decoded = Expand-RcaDocument -Part $parsed
        $decoded.Sha256 | Should -Be $parsed[0].Sha256
        $expected = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 30 -Compress
        ($decoded.Json | ConvertFrom-Json | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $expected
        ($decoded.Json | ConvertFrom-Json).documentId | Should -Be $parsed[0].DocumentId
    }
}

Describe 'The Incident RCA contract: transport fixtures (ADR 0031)' {
    It '<Name> validates against transport.schema.json' -ForEach $transportFixtures {
        $schemaErrors = $null
        $valid = Test-Json -Path $Path -SchemaFile $transportSchemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
        $valid | Should -BeTrue -Because ($schemaErrors | Out-String)
    }

    It 'keeps a bundle within 24,000 bytes and the bundle index within 4,000' {
        [System.Text.Encoding]::UTF8.GetByteCount((Get-Content -LiteralPath (Join-Path -Path $rcaRoot -ChildPath 'fixtures/metrics-bundle.json') -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress)) | Should -BeLessOrEqual 24000
        [System.Text.Encoding]::UTF8.GetByteCount((Get-Content -LiteralPath (Join-Path -Path $rcaRoot -ChildPath 'fixtures/metrics-rca-member.json') -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress)) | Should -BeLessOrEqual 4000
    }

    It 'passes RCA_EVIDENCE every part of both documents, as the index lists them' {
        $parameter = Get-Content -LiteralPath (Join-Path -Path $rcaRoot -ChildPath 'fixtures/rca-evidence.parameter.json') -Raw | ConvertFrom-Json
        $allParts = @(Get-ChildItem -Path (Join-Path -Path $rcaRoot -ChildPath 'fixtures') -Filter '*.parts.txt' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName } | Where-Object { $_ })
        @($parameter.parts | Sort-Object) | Should -Be @($allParts | Sort-Object)
        $index = Get-Content -LiteralPath (Join-Path -Path $rcaRoot -ChildPath 'fixtures/export-index.json') -Raw | ConvertFrom-Json
        ($index.documents | Measure-Object -Property parts -Sum).Sum | Should -Be $allParts.Count
    }

    It 'names RCA_EVIDENCE_FILE only inside the lakehouse inbox, and fits a full session in what the notebook reads' {
        $pattern = $transportSchema['$defs'].evidenceFile.pattern
        foreach ($good in @('Files/rca/inbox/00000000-0000-0000-0000-000000000000-run20261120T172000Z.json', 'Files/rca/inbox/s1.json')) { $good | Should -Match $pattern }
        foreach ($bad in @('Files/rca/inbox/../secrets.json', '/Files/rca/inbox/s1.json', 'Tables/rca_sessions/s1.json', 'Files/rca/inbox/s1.txt', 'Files/rca/inbox/sub/s1.json', 'Files/rca/inbox/.json')) { $bad | Should -Not -Match $pattern }
        # 64 part lines of 3,400 characters with their JSON quoting: under the 262,144 bytes the notebook passes to notebookutils.fs.head.
        $full = [ordered]@{ kind = 'ContosoCare.RcaEvidenceParts'; version = 1; sessionId = 's1'; parts = @(1..64 | ForEach-Object { 'x' * 3400 }); status = 'Pass'; message = 'm' * 500 }
        [System.Text.Encoding]::UTF8.GetByteCount(($full | ConvertTo-Json -Compress)) | Should -BeLessThan 262144
        $transportSchema['$defs'].evidenceFile.description | Should -Match 'max_bytes 262144'
    }
}

Describe 'The Incident RCA contract: blind detection (ADR 0031)' {
    It 'lets detection read every detection table and none of the answer key' {
        foreach ($table in $detectionTables) { $table.model | Should -BeIn $blind.detectionMayRead.modelTables }
        foreach ($table in $answerKeyTables) {
            $table.model | Should -BeIn $blind.answerKey.modelTables
            $table.model | Should -Not -BeIn $blind.detectionMayRead.modelTables
        }
        foreach ($name in $blind.answerKey.modelTables) { $name | Should -Not -BeIn $blind.detectionMayRead.modelTables }
        foreach ($analysis in $blind.answerKey.telemetryAnalyses) { $analysis | Should -Not -BeIn $blind.detectionMayRead.telemetryAnalyses }
    }

    It 'finds no answer-key name or scenario ID in detection code, wherever it exists yet' {
        $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        $appRoot = Join-Path -Path $repoRoot -ChildPath 'fabric/app/src/rca'
        if (Test-Path -LiteralPath $appRoot) {
            Get-ChildItem -LiteralPath $appRoot -Recurse -File -Include '*.ts', '*.tsx' |
                Where-Object { $_.Name -notmatch '\.test\.tsx?$' -and $_.FullName -notmatch '[\\/]testdata[\\/]' } |
                ForEach-Object { $files.Add($_) }
        }
        $observerRoot = Join-Path -Path $repoRoot -ChildPath 'workload-generator/src/ContosoCare.Workload/Rca/Observer'
        if (Test-Path -LiteralPath $observerRoot) {
            Get-ChildItem -LiteralPath $observerRoot -Recurse -File -Filter '*.cs' | ForEach-Object { $files.Add($_) }
        }
        $violations = foreach ($file in $files) {
            $relative = $file.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
            $text = [System.IO.File]::ReadAllText($file.FullName)
            foreach ($identifier in $blind.forbiddenInDetectionCode.identifiers) {
                $allowed = @($blind.detectionCode.exceptions | Where-Object { $_.identifier -eq $identifier -and $relative -in $_.files })
                if ($text.Contains($identifier) -and $allowed.Count -eq 0) { '{0}: {1}' -f $relative, $identifier }
            }
            foreach ($hit in (Get-DetectionStringViolation -Text $text)) { '{0}: {1}' -f $relative, $hit }
        }
        @($violations) | Should -BeNullOrEmpty
    }

    It 'keeps the capture catalog off the answer key: no scenario ID, and nothing the workload reports about itself' {
        foreach ($file in Get-ChildItem -Path (Join-Path -Path $rcaRoot -ChildPath 'capture') -Filter '*.sql' -File) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            @(Get-DetectionStringViolation -Text $text) | Should -BeNullOrEmpty -Because $file.Name
            foreach ($identifier in @('scenario_runs', 'scenario_run_events', 'fn_scenario_catalog', 'usp_run_event', 'usp_scenario_', 'SESSION_PLAN')) {
                $text.Contains($identifier) | Should -BeFalse -Because "$($file.Name) names $identifier"
            }
        }
    }

    It 'names no retired workload module in the fixtures, the app''s source, or the runner''s RCA tests (ADR 0031, decision 6)' {
        # The workload's modules have realistic names since 2026-11-23. A branch from before that adds a fixture or a test
        # with an earlier name: ./tests/Update-RcaFixtures.ps1 -RenameWorkloadModules -Path <its files> renames them and
        # writes the fixtures' part lines again. Names match in any case, as SQL Server's do.
        $retired = @('usp_scenario_', 'fn_locking_hot_rows', 'fn_chain_rows', 'fn_idle_rows', 'usp_io_scratch_grow', 'usp_visit_summary_lookup')
        $files = @(
            Get-ChildItem -LiteralPath (Join-Path -Path $rcaRoot -ChildPath 'fixtures') -File -Filter '*.json'
            $appSource = Join-Path -Path $repoRoot -ChildPath 'fabric/app/src'
            if (Test-Path -LiteralPath $appSource) { Get-ChildItem -LiteralPath $appSource -Recurse -File }
            $runnerTests = Join-Path -Path $repoRoot -ChildPath 'workload-generator/tests/ContosoCare.Workload.Tests'
            if (Test-Path -LiteralPath $runnerTests) { Get-ChildItem -LiteralPath $runnerTests -File -Filter 'Rca*.cs' }
        )
        $files.Count | Should -BeGreaterThan 0
        $found = foreach ($file in $files) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            foreach ($name in $retired) {
                if ($text.IndexOf($name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { '{0}: {1}' -f $file.FullName.Substring($repoRoot.Length + 1).Replace('\', '/'), $name }
            }
        }
        $found | Should -BeNullOrEmpty -Because 'the workload has realistic module names since 2026-11-23: run ./tests/Update-RcaFixtures.ps1 -RenameWorkloadModules -Path with the files it names'
    }
}

Describe 'The Incident RCA contract: the capture catalog (ADR 0031)' {
    BeforeAll {
        $blocks = foreach ($file in Get-ChildItem -Path (Join-Path -Path $rcaRoot -ChildPath 'capture') -Filter '*.sql' -File) {
            foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($file.FullName), '(?m)^-- name: (RCA-[A-Z]+-[0-9]{2})\r?$')) { $match.Groups[1].Value }
        }
        $captureReadme = [System.IO.File]::ReadAllText((Join-Path -Path $rcaRoot -ChildPath 'capture/README.md'))
    }

    It 'names 36 blocks, each once: RCA-SQL-01 to 13, RCA-AZ-01 to 05, RCA-XE-00 to 05, RCA-PG-01 to 12' {
        $expected = @(1..13 | ForEach-Object { 'RCA-SQL-{0:d2}' -f $_ }) + @(1..5 | ForEach-Object { 'RCA-AZ-{0:d2}' -f $_ }) + @(0..5 | ForEach-Object { 'RCA-XE-{0:d2}' -f $_ }) + @(1..12 | ForEach-Object { 'RCA-PG-{0:d2}' -f $_ })
        @($blocks | Sort-Object) | Should -Be @($expected | Sort-Object)
    }

    It 'lists every block in capture/README.md, each row with its documentation' {
        $blocks.Count | Should -Be 36
        $rows = @($captureReadme -split "`n" | Where-Object { $_ -match '^\| RCA-' })
        foreach ($block in $blocks) {
            $family, $number = $block -replace '^RCA-', '' -split '-'
            $row = $rows | Where-Object { $_ -match ('^\| RCA-{0}-([0-9, ]+)\|' -f $family) -and ($Matches[1] -split ',\s*' | ForEach-Object { '{0:d2}' -f [int]$_ }) -contains $number }
            $row | Should -Not -BeNullOrEmpty -Because "$block has a row"
            $row | Should -Match 'https://(learn\.microsoft\.com|www\.postgresql\.org/docs/18)/' -Because "$block cites its documentation"
        }
    }

    It 'names only capture IDs that exist in history-tables.json' {
        foreach ($table in $tables.tables) {
            foreach ($id in $table.captureIds) { $id | Should -BeIn $blocks -Because $table.name }
        }
    }

    It 'reads the events'' fields from sys.dm_xe_object_columns alone (RCA-XE-00), without the join to sys.dm_xe_objects that took about 8 s of CPU at each observer start' {
        $catalog = [System.IO.File]::ReadAllText((Join-Path -Path $rcaRoot -ChildPath 'capture/sqlserver.sql'))
        $block = [regex]::Match($catalog, '(?ms)^-- name: RCA-XE-00\r?$(?<body>.*?)(?=^-- name: |\z)').Groups['body'].Value
        $sql = @($block -split "`n" | Where-Object { $_ -notmatch '^\s*--' }) -join "`n"
        $sql | Should -Match 'FROM sys\.dm_xe_object_columns AS c'
        $sql | Should -Not -Match '\bJOIN\b'
        $sql | Should -Not -Match 'sys\.dm_xe_objects\b'
        foreach ($name in 'error_reported', 'attention', 'lock_escalation', 'xml_deadlock_report', 'database_xml_deadlock_report') { $sql | Should -Match ("N'{0}'" -f $name) }
        $sql | Should -Match "c\.column_type = N'data'"
    }
}
