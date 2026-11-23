BeforeDiscovery {
    $repoRootForDiscovery = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $fixtureRoot = Join-Path -Path $repoRootForDiscovery -ChildPath 'rca/fixtures'
    # The evidence documents' fixtures (<name>.evidence.json, parts in <name>.parts.txt) and the sidecars' (<name>.sidecar.json,
    # parts in <name>.sidecar-parts.txt, which the RCA_EVIDENCE fixture never holds).
    $documentFixtures = @(
        @(Get-ChildItem -Path $fixtureRoot -Filter '*.evidence.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property Name |
                ForEach-Object { @{ Name = $_.Name; Path = $_.FullName; Parts = $_.FullName -replace '\.evidence\.json$', '.parts.txt'; Kind = 'evidence' } })
        @(Get-ChildItem -Path $fixtureRoot -Filter '*.sidecar.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property Name |
                ForEach-Object { @{ Name = $_.Name; Path = $_.FullName; Parts = $_.FullName -replace '\.sidecar\.json$', '.sidecar-parts.txt'; Kind = 'sidecar' } })
    )
    $transportFixtures = @('rca-evidence.parameter.json', 'metrics-bundle.json', 'metrics-rca-member.json', 'export-index.json', 'rca-sidecar.parameter.json', 'sidecar-index.json', 'rca-ack.json', 'sidecar-bundle.json', 'sidecar-bundle-index.json', 'metrics-rca-sidecars-member.json', 'rca-ack-request.json', 'rca-ack-result.json') |
        ForEach-Object { @{ Name = $_; Path = (Join-Path -Path $repoRootForDiscovery -ChildPath "rca/fixtures/$_") } }
}

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $rcaRoot = Join-Path -Path $repoRoot -ChildPath 'rca'
    $evidenceSchemaPath = Join-Path -Path $rcaRoot -ChildPath 'evidence.schema.json'
    $sidecarSchemaPath = Join-Path -Path $rcaRoot -ChildPath 'sidecar.schema.json'
    $transportSchemaPath = Join-Path -Path $rcaRoot -ChildPath 'transport.schema.json'
    $evidenceSchema = Get-Content -LiteralPath $evidenceSchemaPath -Raw | ConvertFrom-Json -AsHashtable
    $sidecarSchema = Get-Content -LiteralPath $sidecarSchemaPath -Raw | ConvertFrom-Json -AsHashtable
    # Each document kind with its schema, the tables it carries, its coverage table, and its part line.
    $documentKinds = @{
        evidence = @{ Kind = 'ContosoCare.RcaEvidence'; Path = $evidenceSchemaPath; Schema = $evidenceSchema; Coverage = 'rca_coverage'; PartLine = 'partLine' }
        sidecar  = @{ Kind = 'ContosoCare.RcaSidecar'; Path = $sidecarSchemaPath; Schema = $sidecarSchema; Coverage = 'rca_query_coverage'; PartLine = 'sidecarPartLine' }
    }
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
    It 'writes the schemas as JSON Schema 2020-12 with the repository''s $id: the evidence document''s, the sidecar''s, and the transport''s' {
        foreach ($schema in $evidenceSchema, $sidecarSchema, $transportSchema) { $schema['$schema'] | Should -Be 'https://json-schema.org/draft/2020-12/schema' }
        $evidenceSchema['$id'] | Should -Be 'https://github.com/MarcBushong/fabric-database-hub-demo/rca/evidence.schema.json'
        $sidecarSchema['$id'] | Should -Be 'https://github.com/MarcBushong/fabric-database-hub-demo/rca/sidecar.schema.json'
        $transportSchema['$id'] | Should -Be 'https://github.com/MarcBushong/fabric-database-hub-demo/rca/transport.schema.json'
        $evidenceSchema.properties.kind.const | Should -Be 'ContosoCare.RcaEvidence'
        $evidenceSchema.properties.version.const | Should -Be 1
        $sidecarSchema.properties.kind.const | Should -Be 'ContosoCare.RcaSidecar'
        $sidecarSchema.properties.version.const | Should -Be 1
        # The file's own version: a consumer checks a document's kind and version, never this.
        $tables.version | Should -Be 2
    }

    It 'names the document that carries each table: the evidence document''s seven detection tables and answer key, as before, and the sidecar''s six' {
        foreach ($table in $tables.tables) { $table.document | Should -BeIn @('evidence', 'sidecar') -Because $table.name }
        $carried = { param($Document, $Role) @($tables.tables | Where-Object { $_.document -eq $Document -and $_.role -eq $Role } | ForEach-Object { $_.name } | Sort-Object) }
        & $carried 'evidence' 'detection' | Should -Be @('rca_coverage', 'rca_events', 'rca_queries', 'rca_replica', 'rca_resource', 'rca_sessions', 'rca_waits')
        & $carried 'evidence' 'answerKey' | Should -Be @('rca_answer_key')
        & $carried 'sidecar' 'detection' | Should -Be @('rca_connections', 'rca_query_coverage', 'rca_query_events', 'rca_query_plans', 'rca_query_stats', 'rca_query_waits')
        @(& $carried 'sidecar' 'answerKey') | Should -BeNullOrEmpty
    }

    It 'gives every table its own lakehouse and model name' {
        $detectionTables.Count | Should -Be 13
        $answerKeyTables.Count | Should -Be 1
        @($tables.tables.name | Sort-Object -Unique).Count | Should -Be 14
        @($tables.tables.model | Sort-Object -Unique).Count | Should -Be 14
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

    It 'relates every table only to Target and Date, and purges every table, the staged evidence, and the acknowledgements' {
        @($tables.relationships.toTable | Sort-Object) | Should -Be @('Date', 'Target')
        @($tables.purge | Sort-Object) | Should -Be @($tables.tables.name | Sort-Object)
        @($tables.purgeFiles) | Should -Be @('Files/rca/inbox', 'Files/rca/acks')
    }

    It 'gives every measure a known table, a format, and a description' {
        foreach ($measure in $tables.measures) {
            $measure.table | Should -BeIn @($tables.tables.model)
            $measure.formatString | Should -Not -BeNullOrEmpty
            $measure.description | Should -Not -BeNullOrEmpty
        }
    }

    It 'generates each document''s schema from history-tables.json: exactly its tables, with their columns, types, and required columns' {
        foreach ($document in 'evidence', 'sidecar') {
            $schema = $documentKinds[$document].Schema
            $carried = @($tables.tables | Where-Object { $_.document -eq $document })
            @($schema.properties.tables.properties.Keys | Sort-Object) | Should -Be @($carried | Where-Object { $_.role -eq 'detection' } | ForEach-Object { $_.name } | Sort-Object) -Because $document
            if ($document -eq 'evidence') {
                @($schema.properties.answerKey.properties.tables.properties.Keys | Sort-Object) | Should -Be @($carried | Where-Object { $_.role -eq 'answerKey' } | ForEach-Object { $_.name } | Sort-Object)
            }
            else {
                # The sidecar never carries the answer key.
                $schema.properties.Contains('answerKey') | Should -BeFalse
                $schema.required | Should -Not -Contain 'answerKey'
            }
            foreach ($table in $carried) {
                $section = if ($table.role -eq 'detection') { $schema.properties.tables.properties } else { $schema.properties.answerKey.properties.tables.properties }
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
    It 'accepts a minimal sidecar, and refuses one with an evidence document''s ID, an evidence table, the answer key, no coverage, or a header time without milliseconds' {
        $evidence = Get-Content -LiteralPath (Join-Path -Path $rcaRoot -ChildPath 'fixtures/t1-blocking-chain.evidence.json') -Raw
        $headerTimes = 'exportedUtc', 'windowStartUtc', 'windowEndUtc', 'epochUtc'
        # A fresh copy of the evidence fixture's header each time, as a sidecar with one coverage row. ConvertFrom-Json
        # reads the header's times as dates, so they're written back as the runner writes them, with milliseconds.
        $sidecar = {
            $document = $evidence | ConvertFrom-Json -AsHashtable
            $document.Remove('answerKey')
            foreach ($field in $headerTimes) {
                $document[$field] = ([datetime]$document[$field]).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            }
            $document['kind'] = 'ContosoCare.RcaSidecar'
            $document['documentId'] = $document['documentId'] + '-sidecar'
            $document['targets'] = @('T1')
            $document['strings'] = @('T1')
            $document['tables'] = [ordered]@{ rca_query_coverage = [ordered]@{ rows = 1; columns = [ordered]@{ target = @(0); window_start_utc = @(0); window_end_utc = @(900000); backfill = @($false) } } }
            return $document
        }
        $valid = { param($Document) Test-Json -Json ($Document | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $sidecarSchemaPath -ErrorAction SilentlyContinue }
        & $valid (& $sidecar) | Should -BeTrue
        $evidenceId = & $sidecar
        $evidenceId['documentId'] = $evidenceId['documentId'] -replace '-sidecar$', ''
        & $valid $evidenceId | Should -BeFalse
        $evidenceTable = & $sidecar
        $evidenceTable['tables']['rca_coverage'] = $evidenceTable['tables']['rca_query_coverage']
        & $valid $evidenceTable | Should -BeFalse
        $withKey = & $sidecar
        $withKey['answerKey'] = [ordered]@{ strings = @(); tables = [ordered]@{} }
        & $valid $withKey | Should -BeFalse
        $noCoverage = & $sidecar
        $noCoverage['tables'] = [ordered]@{}
        & $valid $noCoverage | Should -BeFalse
        foreach ($field in $headerTimes) {
            $seconds = & $sidecar
            $seconds[$field] = $seconds[$field] -replace '\.[0-9]{3}Z$', 'Z'
            & $valid $seconds | Should -BeFalse -Because "$field without milliseconds: $($seconds[$field])"
            $ticks = & $sidecar
            $ticks[$field] = $ticks[$field] -replace 'Z$', '0000Z'
            & $valid $ticks | Should -BeFalse -Because "$field with seven digits: $($ticks[$field])"
        }
    }
}
Describe 'The Incident RCA contract: document fixtures (ADR 0031)' {
    It '<Name> validates against its kind''s schema' -ForEach $documentFixtures {
        $schemaErrors = $null
        $valid = Test-Json -Path $Path -SchemaFile $documentKinds[$Kind].Path -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
        $valid | Should -BeTrue -Because ($schemaErrors | Out-String)
    }

    It '<Name> holds only its own kind''s tables' -ForEach $documentFixtures {
        $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        $document.kind | Should -Be $documentKinds[$Kind].Kind
        $carried = @($tables.tables | Where-Object { $_.document -eq $Kind } | ForEach-Object { $_.name })
        foreach ($name in $document.tables.Keys) { $name | Should -BeIn $carried }
    }

    It '<Name> has every column as long as its table, and every string an index into its own dictionary' -ForEach $documentFixtures {
        $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        $sections = @(@{ Strings = $document.strings; Tables = $document.tables })
        if ($document.Contains('answerKey')) { $sections += @{ Strings = $document.answerKey.strings; Tables = $document.answerKey.tables } }
        foreach ($section in $sections) {
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

    It '<Name> covers each of its targets in its coverage table' -ForEach $documentFixtures {
        $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        $covered = @($document.tables[$documentKinds[$Kind].Coverage].columns.target | ForEach-Object { $document.strings[$_] } | Sort-Object)
        $covered | Should -Be @($document.targets | Sort-Object)
    }

    It '<Name> has a plan row for every plan its statistics name, and writes a plan again only when it changed' -ForEach @($documentFixtures | Where-Object { $_.Kind -eq 'sidecar' }) {
        # rca/README.md, Query Store, Plans: RCA-SQL-14's @plans, and a plan's row again only when its forcing, compiles,
        # or compile time change. T4 stores no plans: its statistics name plan 0.
        $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        $stats = $document.tables['rca_query_stats']
        $plans = $document.tables['rca_query_plans']
        $value = { param($Table, $Column, $Row) $values = $Table.columns[$Column]; if ($null -eq $values) { $null } else { $values[$Row] } }
        $keys = [System.Collections.Generic.HashSet[string]]::new()
        $rows = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $plans) {
            for ($i = 0; $i -lt $plans.columns.plan_id.Count; $i++) {
                $key = '{0}/{1}' -f $document.strings[$plans.columns.target[$i]], $plans.columns.plan_id[$i]
                $null = $keys.Add($key)
                $forcing = & $value $plans 'forcing_type' $i
                $change = '{0}|{1}|{2}|{3}|{4}' -f (& $value $plans 'is_forced_plan' $i), $(if ($null -ne $forcing) { $document.strings[$forcing] }), (& $value $plans 'compiles' $i), (& $value $plans 'last_compiled_utc' $i), (& $value $plans 'force_failures' $i)
                $rows.Add([pscustomobject]@{ Key = $key; At = [long]$plans.columns.captured_at_utc[$i]; Change = $change })
            }
        }
        if ($null -ne $stats) {
            for ($i = 0; $i -lt $stats.columns.plan_id.Count; $i++) {
                if ([long]$stats.columns.plan_id[$i] -eq 0) { continue }
                $key = '{0}/{1}' -f $document.strings[$stats.columns.target[$i]], $stats.columns.plan_id[$i]
                $keys.Contains($key) | Should -BeTrue -Because ('the statistics name plan {0}, which has no plan row' -f $key)
            }
        }
        foreach ($group in ($rows | Group-Object -Property Key)) {
            $ordered = @($group.Group | Sort-Object -Property At)
            for ($j = 1; $j -lt $ordered.Count; $j++) {
                $ordered[$j].Change | Should -Not -Be $ordered[$j - 1].Change -Because ('plan {0} is written again unchanged' -f $group.Name)
            }
        }
    }

    It '<Name> keeps the detection tables blind: no scenario ID, run ID, or answer-key string, and program names without their segments' -ForEach $documentFixtures {
        $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        $violations = foreach ($text in $document.strings) { Get-DetectionStringViolation -Text $text }
        @($violations) | Should -BeNullOrEmpty
        # A sidecar's run IDs are its session's evidence document's: the fixtures' answer keys.
        $keys = @(Get-ChildItem -Path (Join-Path -Path $rcaRoot -ChildPath 'fixtures') -Filter '*.evidence.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable })
        $keyRunIds = @($keys | ForEach-Object { $key = $_; $key.answerKey.tables.rca_answer_key.columns.scenario_run_id | ForEach-Object { $key.answerKey.strings[$_] } })
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

    It '<Name> decodes from its parts: complete, in order, with the SHA-256 every part names' -ForEach $documentFixtures {
        $lines = @(Get-Content -LiteralPath $Parts | Where-Object { $_ })
        $pattern = $transportSchema['$defs'][$documentKinds[$Kind].PartLine].pattern
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

    It 'carries Run all''s sidecars whole: the bundle, its index, the metrics'' pointer, and the next start''s acknowledgements agree' {
        $read = { param($Name) Get-Content -LiteralPath (Join-Path -Path $rcaRoot -ChildPath "fixtures/$Name") -Raw | ConvertFrom-Json }
        $bytes = { param($Name) [System.Text.Encoding]::UTF8.GetByteCount((& $read $Name | ConvertTo-Json -Depth 10 -Compress)) }
        $bundle = & $read 'sidecar-bundle.json'
        $index = & $read 'sidecar-bundle-index.json'
        $pointer = & $read 'metrics-rca-sidecars-member.json'
        $request = & $read 'rca-ack-request.json'
        $result = & $read 'rca-ack-result.json'
        (& $bytes 'sidecar-bundle.json') | Should -BeLessOrEqual 24000
        (& $bytes 'sidecar-bundle-index.json') | Should -BeLessOrEqual 24000
        (& $bytes 'metrics-rca-sidecars-member.json') | Should -BeLessOrEqual 300 -Because 'the pointer comes out of T5''s share of the metrics document'
        # Whole sidecars: every part of every listed document is in the bundles, with the index's SHA-256, and nothing else.
        $lines = @($bundle.parts)
        @($index.documents | Measure-Object -Property parts -Sum).Sum | Should -BeLessOrEqual 64 -Because 'RCA_SIDECAR_FILE takes at most 64 parts'
        foreach ($document in $index.documents) {
            $mine = @($lines | Where-Object { ($_ -split ' ')[2] -eq $document.documentId })
            $mine.Count | Should -Be $document.parts -Because $document.documentId
            @($mine | ForEach-Object { ($_ -split ' ')[4] } | Select-Object -Unique) | Should -Be @($document.sha256)
            @($mine | ForEach-Object { [int](($_ -split ' ')[3] -split '/')[0] } | Sort-Object) | Should -Be @(1..$document.parts)
        }
        @($lines | ForEach-Object { ($_ -split ' ')[2] } | Select-Object -Unique | Sort-Object) | Should -Be @($index.documents.documentId | Sort-Object)
        # An evidence reader takes only lines that start with DBHUBDEMO-RCA and a space: none of these.
        @($lines | Where-Object { $_.StartsWith('DBHUBDEMO-RCA ', [System.StringComparison]::Ordinal) }) | Should -BeNullOrEmpty
        $pointer.documents | Should -Be @($index.documents).Count
        $pointer.index | Should -Match '^[0-9a-f]{32}$'
        @($index.bundles) | Should -Not -Contain $pointer.index -Because 'the index is a version of its own'
        # The next start acknowledges only what the history holds, and accounts for every ID it was given.
        @($request.documents | Where-Object { $_ -notin @($index.documents.documentId) }) | Should -BeNullOrEmpty
        @(@($result.sent) + @($result.left) | Sort-Object) | Should -Be @($request.documents | Sort-Object)
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

    It 'keeps the sidecar''s transport apart from the evidence document''s: its part lines, IDs, and index never match the evidence''s' {
        $defs = $transportSchema['$defs']
        $slice = 'H4sIAAAAAAAA'
        $sha = 'a' * 64
        $evidenceLine = 'DBHUBDEMO-RCA 1 20261120T165000Z-sqlvm01-0001 1/1 {0} {1}' -f $sha, $slice
        $sidecarLine = 'DBHUBDEMO-RCAS 1 20261120T165000Z-sqlvm01-0001-sidecar 1/1 {0} {1}' -f $sha, $slice
        $evidenceLine | Should -MatchExactly $defs.partLine.pattern
        $sidecarLine | Should -MatchExactly $defs.sidecarPartLine.pattern
        $sidecarLine | Should -Not -Match $defs.partLine.pattern
        $evidenceLine | Should -Not -Match $defs.sidecarPartLine.pattern
        # Today's scripts and runbook take a runner's line only when it starts with the evidence document's markers and a space.
        foreach ($marker in 'DBHUBDEMO-RCA ', 'DBHUBDEMO-RCA-INDEX ') {
            foreach ($line in $sidecarLine, 'DBHUBDEMO-RCAS-INDEX {}') { $line.StartsWith($marker, [System.StringComparison]::Ordinal) | Should -BeFalse }
        }
        '20261120T165000Z-sqlvm01-0001-sidecar' | Should -Not -Match $defs.documentRef.properties.documentId.pattern
        '20261120T165000Z-sqlvm01-0001' | Should -Not -Match $defs.sidecarId.pattern
        # A sidecar's file stays in the same inbox, with its own name, kind, and parameter: sidecar-<UTC>, which the day-old
        # sweep of evidence files never matches (the notebook's staging rule, acde5510).
        foreach ($path in 'Files/rca/inbox/sidecar-20261121T102531Z.json', 'Files/rca/inbox/sidecar-20261121T102531Z-stop.json') {
            $path | Should -MatchExactly $defs.sidecarFile.pattern
            $path | Should -MatchExactly $defs.evidenceFile.pattern
        }
        foreach ($path in 'Files/rca/inbox/rca-20261121T102531Z.json', 'Files/rca/inbox/sidecar-latest.json', 'Files/rca/inbox/sidecar-20261121T102531Z.json.tmp', 'Files/rca/acks/sidecar-20261121T102531Z.json') {
            $path | Should -Not -MatchExactly $defs.sidecarFile.pattern
        }
        $defs.sidecarParameter.properties.kind.const | Should -Be 'ContosoCare.RcaSidecarParts'
    }

    It 'passes RCA_SIDECAR_FILE every part of the sidecars the index lists, and the acknowledgement names each by ID' {
        $fixtureRoot = Join-Path -Path $rcaRoot -ChildPath 'fixtures'
        $parameter = Get-Content -LiteralPath (Join-Path -Path $fixtureRoot -ChildPath 'rca-sidecar.parameter.json') -Raw | ConvertFrom-Json
        $allParts = @(Get-ChildItem -Path $fixtureRoot -Filter '*.sidecar-parts.txt' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName } | Where-Object { $_ })
        @($parameter.parts | Sort-Object) | Should -Be @($allParts | Sort-Object)
        # The evidence document's RCA_EVIDENCE never holds a sidecar's part.
        @((Get-Content -LiteralPath (Join-Path -Path $fixtureRoot -ChildPath 'rca-evidence.parameter.json') -Raw | ConvertFrom-Json).parts | Where-Object { $_.StartsWith('DBHUBDEMO-RCAS ', [System.StringComparison]::Ordinal) }) | Should -BeNullOrEmpty
        $sidecars = @(Get-ChildItem -Path $fixtureRoot -Filter '*.sidecar.json' -File | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).documentId } | Sort-Object)
        $index = Get-Content -LiteralPath (Join-Path -Path $fixtureRoot -ChildPath 'sidecar-index.json') -Raw | ConvertFrom-Json
        @($index.documents.documentId | Sort-Object) | Should -Be $sidecars
        ($index.documents | Measure-Object -Property parts -Sum).Sum | Should -Be $allParts.Count
        $index.page | Should -BeLessOrEqual $index.pages
        # Every line of the index fits what a Run Command keeps.
        ('DBHUBDEMO-RCAS-INDEX ' + ($index | ConvertTo-Json -Depth 10 -Compress)).Length | Should -BeLessOrEqual 3400
        $ack = Get-Content -LiteralPath (Join-Path -Path $fixtureRoot -ChildPath 'rca-ack.json') -Raw | ConvertFrom-Json
        @($ack.documents.documentId | Sort-Object) | Should -Be $sidecars
        foreach ($document in $ack.documents) {
            if ($document.status -eq 'skipped') { $document.reason | Should -Not -BeNullOrEmpty -Because $document.documentId }
        }
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
        # The observer's code and the sidecar's readers and store (blind-detection.json, detectionCode.runner); a folder a
        # builder hasn't created yet has nothing to scan.
        foreach ($pattern in @($blind.detectionCode.runner.include)) {
            $observerRoot = Join-Path -Path $repoRoot -ChildPath ($pattern -split '/\*\*/')[0]
            if (Test-Path -LiteralPath $observerRoot) {
                Get-ChildItem -LiteralPath $observerRoot -Recurse -File -Filter '*.cs' | ForEach-Object { $files.Add($_) }
            }
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

    It 'lets the list of the runner''s own statements name exactly the forbidden names those statements use (What the capture leaves out, 3)' {
        $list = 'workload-generator/src/ContosoCare.Workload/Rca/QueryStore/HarnessStatements.cs'
        $harnessCode = 'Sql/DemoDatabase.cs', 'Sql/SqlScripts.cs', 'Cli/CommandLine.cs'
        # The SQL the runner's harness code sends as text: Text("...") and CommandText = "...", raw string literals included.
        $literal = '(?:Text\(|CommandText\s*=)\s*(?:"""(?<raw>[\s\S]*?)"""|"(?<plain>(?:[^"\\]|\\.)*)")'
        $statements = foreach ($file in $harnessCode) {
            $source = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath ('workload-generator/src/ContosoCare.Workload/' + $file)))
            foreach ($match in [regex]::Matches($source, $literal)) { $match.Groups['raw'].Value + $match.Groups['plain'].Value }
        }
        @($statements).Count | Should -BeGreaterThan 8
        $named = @($blind.forbiddenInDetectionCode.identifiers | Where-Object { $identifier = $_; @($statements | Where-Object { $_.Contains($identifier) }).Count -gt 0 })
        $excepted = @($blind.detectionCode.exceptions | Where-Object { $list -in $_.files } | ForEach-Object { $_.identifier })
        @($excepted | Sort-Object) | Should -Be @($named | Sort-Object) -Because 'the list holds every such statement, and nothing else may name what blind-detection.json forbids'
    }

    It 'scans every folder of the runner''s RCA code for answer-key names, or says why one is exempt' {
        # A new folder (the sidecar's store, 2026-11-23) must join blind-detection.json's runner include, or this list.
        $exempt = @{
            AnswerKey = 'it records the answer key, which only the evaluation reads'
            Export    = 'it packs the answer key apart from the evidence; its Reducer.cs is scanned by name (RcaBlindTests)'
            Store     = 'it keeps the answer key''s file beside the evidence, unread by detection'
        }
        $rcaCode = Join-Path -Path $repoRoot -ChildPath 'workload-generator/src/ContosoCare.Workload/Rca'
        $scanned = @($blind.detectionCode.runner.include | ForEach-Object { ($_ -split '/\*\*/')[0] })
        foreach ($folder in Get-ChildItem -LiteralPath $rcaCode -Directory) {
            $relative = 'workload-generator/src/ContosoCare.Workload/Rca/' + $folder.Name
            ($relative -in $scanned -or $exempt.ContainsKey($folder.Name)) | Should -BeTrue -Because ('{0} holds RCA code that the blind-detection guard neither scans nor exempts' -f $relative)
        }
        foreach ($pattern in $scanned) {
            $pattern | Should -Match '^workload-generator/src/ContosoCare\.Workload/Rca/[A-Za-z]+$'
        }
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
}

Describe 'The Incident RCA contract: the capture catalog (ADR 0031)' {
    BeforeAll {
        $blocks = foreach ($file in Get-ChildItem -Path (Join-Path -Path $rcaRoot -ChildPath 'capture') -Filter '*.sql' -File) {
            foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($file.FullName), '(?m)^-- name: (RCA-[A-Z]+-[0-9]{2})\r?$')) { $match.Groups[1].Value }
        }
        $captureReadme = [System.IO.File]::ReadAllText((Join-Path -Path $rcaRoot -ChildPath 'capture/README.md'))
    }

    It 'names 44 blocks, each once: RCA-SQL-01 to 16, RCA-AZ-01 to 05, RCA-XE-00 to 05, RCA-PG-01 to 17' {
        $expected = @(1..16 | ForEach-Object { 'RCA-SQL-{0:d2}' -f $_ }) + @(1..5 | ForEach-Object { 'RCA-AZ-{0:d2}' -f $_ }) + @(0..5 | ForEach-Object { 'RCA-XE-{0:d2}' -f $_ }) + @(1..17 | ForEach-Object { 'RCA-PG-{0:d2}' -f $_ })
        @($blocks | Sort-Object) | Should -Be @($expected | Sort-Object)
    }

    It 'lists every block in capture/README.md, each row with its documentation' {
        $blocks.Count | Should -Be 44
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

    It 'leaves out only the capture''s own statements and the harness''s, by fixed rules that never read the answer key' {
        $catalog = @{}
        foreach ($file in Get-ChildItem -Path (Join-Path -Path $rcaRoot -ChildPath 'capture') -Filter '*.sql' -File) {
            $text = [System.IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n"
            foreach ($match in [regex]::Matches($text, '(?ms)^-- name: (RCA-[A-Z]+-[0-9]{2})\n(.*?)(?=^-- name: |\z)')) { $catalog[$match.Groups[1].Value] = $match.Groups[2].Value }
        }
        foreach ($id in $catalog.Keys) {
            $catalog[$id] | Should -Not -Match '@leave_out|blind-detection' -Because "$id takes nothing from the answer key"
        }
        # SQL Server: the observer's marker, and the modules the demo marks as its harness.
        foreach ($id in 'RCA-SQL-10', 'RCA-SQL-14') {
            $catalog[$id] | Should -Match ([regex]::Escape("qt.query_sql_text NOT LIKE N'%dbhubdemo:rca-observer%'")) -Because $id
            $catalog[$id] | Should -Match ([regex]::Escape("ep.name = N'dbhubdemo.role'")) -Because $id
            $catalog[$id] | Should -Match ([regex]::Escape("= N'harness'")) -Because $id
        }
        # PostgreSQL: the observer's search_path and marker, and the harness's functions and tables from RCA-PG-16.
        $catalog['RCA-PG-14'] | Should -Match ([regex]::Escape("COALESCE(q.search_path, '') NOT LIKE '%dbhubdemo_rca_observer%'"))
        $catalog['RCA-PG-14'] | Should -Match ([regex]::Escape("q.query_sql_text NOT LIKE '%dbhubdemo:rca-observer%'"))
        $catalog['RCA-PG-14'] | Should -Match '(?s)\$3::text\[\].*\$4::text\[\].*\$5::text\[\]'
        $catalog['RCA-PG-16'] | Should -Match ([regex]::Escape("obj_description(p.oid, 'pg_proc') = 'dbhubdemo:harness'"))
        # Nothing else: no schema, no statement on a system view, no service account is left out.
        foreach ($id in 'RCA-SQL-10', 'RCA-SQL-14', 'RCA-PG-14', 'RCA-PG-15') {
            $catalog[$id] | Should -Not -Match "schema_id|nspname = |is_system_query|sys\.dm\[_\]|pg_stat_\|" -Because $id
        }
        foreach ($object in $blind.answerKey.databaseObjects) {
            foreach ($id in $catalog.Keys) { $catalog[$id].Contains($object.Split('.')[-1]) | Should -BeFalse -Because "$id names $object" }
        }
    }

    It 'marks every statement the observer runs, so Query Store''s readers leave the capture''s own out' {
        $unmarked = foreach ($file in Get-ChildItem -Path (Join-Path -Path $rcaRoot -ChildPath 'capture') -Filter '*.sql' -File) {
            $id = ''
            $atStart = $true
            foreach ($line in ([System.IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n") -split "`n") {
                if ($line -match '^-- name: (RCA-[A-Z]+-[0-9]{2})') {
                    $id = $Matches[1]
                    $atStart = $true
                    continue
                }
                if (-not $id -or $line.Trim() -eq '' -or $line.TrimStart().StartsWith('--')) { continue }
                # A statement that reads starts at the line's start with SELECT or WITH, or reads in an IF's condition.
                if ($atStart -and $line -match '^(SELECT|WITH|IF)\b' -and -not $line.Contains('/* dbhubdemo:rca-observer */')) { '{0}: {1}' -f $id, $line }
                $atStart = $line.TrimEnd().EndsWith(';')
            }
        }
        @($unmarked) | Should -BeNullOrEmpty
    }
}
