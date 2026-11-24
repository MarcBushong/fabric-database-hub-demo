BeforeAll {
    # tests/Update-RcaFixtures.ps1 (ADR 0031, decision 6), run on copies of rca/fixtures under TestDrive.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $tool = Join-Path -Path $repoRoot -ChildPath 'tests/Update-RcaFixtures.ps1'

    function New-RcaFixtureCopy {
        # A repository root under TestDrive with a copy of rca/fixtures, for the script to change.
        param([Parameter(Mandatory = $true)][string] $Name)

        $root = Join-Path -Path $TestDrive -ChildPath $Name
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'rca') -Force
        Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'rca/fixtures') -Destination (Join-Path -Path $root -ChildPath 'rca') -Recurse
        return $root
    }

    function Get-TreeHash {
        # Every file under a root, as its relative path and SHA-256.
        param([Parameter(Mandatory = $true)][string] $Root)

        return @(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object -Property FullName | ForEach-Object {
                '{0}={1}' -f [System.IO.Path]::GetRelativePath($Root, $_.FullName), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            })
    }

    function Expand-RcaPartFile {
        # A parts file's lines in order, the SHA-256 they name, their gzip's own SHA-256, and the JSON they carry.
        param([Parameter(Mandatory = $true)][string] $LiteralPath)

        $lines = @(Get-Content -LiteralPath $LiteralPath | Where-Object { $_ } | Sort-Object -Property { [int]$_.Split(' ')[3].Split('/')[0] })
        $buffer = [System.IO.MemoryStream]::new()
        foreach ($line in $lines) {
            $bytes = [System.Convert]::FromBase64String($line.Split(' ')[5])
            $buffer.Write($bytes, 0, $bytes.Length)
        }
        $gzip = $buffer.ToArray()
        $reader = [System.IO.StreamReader]::new([System.IO.Compression.GZipStream]::new([System.IO.MemoryStream]::new($gzip), [System.IO.Compression.CompressionMode]::Decompress))
        try {
            $json = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        return [pscustomobject]@{
            Lines        = $lines
            Sha256       = $lines[0].Split(' ')[4]
            ActualSha256 = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($gzip)).ToLowerInvariant()
            Json         = $json
        }
    }
}

Describe 'Update-RcaFixtures.ps1: the retired workload module names (ADR 0031, decision 6)' {
    It 'renames a name that demo qualifies, however a file quotes or escapes it, and one that nothing qualifies, in any case' {
        $root = New-RcaFixtureCopy -Name 'forms'
        $fixturesBefore = Get-TreeHash -Root (Join-Path -Path $root -ChildPath 'rca')
        $scratch = Join-Path -Path $root -ChildPath 'scratch.ts'
        [System.IO.File]::WriteAllText($scratch, @'
const escapedTwice = "\\[demo\\]\\.\\[usp_scenario_chain_acquire\\] \\(session 63";
const escapedOnce = /^\[demo\]\.\[usp_scenario_chain_link\]/;
const brackets = "[demo].[usp_scenario_chain_escalate]";
const quoted = 'SELECT 1 FROM "demo"."usp_scenario_cpu_pressure"($1)';
const upper = "EXEC DEMO.USP_SCENARIO_LOCKING_CONTEND @run_id = 1";
const mixed = "[Demo].[Usp_Scenario_Healthy_Baseline]";
const longer = "SELECT 1 FROM demo.usp_scenario_io_pressure_grow($1), demo.usp_scenario_io_pressure($1)";
const threePart = 'procname="ContosoCare.demo.usp_scenario_deadlock_storm"';
const escapedDot = "demo\\.usp_visit_summary_lookup";
const bare = ["usp_scenario_replica_lag", "USP_SCENARIO_RU_STORM"];
'@)

        & $tool -RepositoryRoot $root -RenameWorkloadModules -Path 'scratch.ts' | Out-Null

        [System.IO.File]::ReadAllText($scratch) | Should -BeExactly @'
const escapedTwice = "\\[scheduling\\]\\.\\[usp_assign_work_item\\] \\(session 63";
const escapedOnce = /^\[scheduling\]\.\[usp_route_work_item\]/;
const brackets = "[scheduling].[usp_bulk_reschedule]";
const quoted = 'SELECT 1 FROM "scheduling"."usp_find_double_bookings"($1)';
const upper = "EXEC billing.usp_claim_work_item @run_id = 1";
const mixed = "[frontdesk].[usp_process_requests]";
const longer = "SELECT 1 FROM records.usp_load_archive_batch($1), records.usp_scan_archive($1)";
const threePart = 'procname="ContosoCare.supply.usp_reconcile_stock"';
const escapedDot = "frontdesk\\.usp_visit_summary";
const bare = ["usp_publish_feed_checkpoint", "usp_ingest_readings"];
'@
        Get-TreeHash -Root (Join-Path -Path $root -ChildPath 'rca') | Should -Be $fixturesBefore -Because 'the fixtures have their realistic names already'
    }

    It 'writes nothing, and names the file and its text, when <Case>' -ForEach @(
        @{ Case = 'a new name is still in demo, in brackets'; Line = 'const a = "[demo].[usp_assign_work_item]";'; Message = '*scratch.ts names usp_assign_work_item in demo*"const a = *nothing was written*' }
        @{ Case = 'a new name is still in demo, escaped twice'; Line = 'const a = "\\[demo\\]\\.\\[usp_assign_work_item\\]";'; Message = '*names usp_assign_work_item in demo*' }
        @{ Case = 'a new name is still in demo, in double quotes'; Line = 'const a = ''"demo"."usp_find_double_bookings"'';'; Message = '*names usp_find_double_bookings in demo*' }
        @{ Case = 'a new name in upper case is still in demo'; Line = 'const a = "DEMO.USP_CLAIM_WORK_ITEM";'; Message = '*names USP_CLAIM_WORK_ITEM in demo*' }
        @{ Case = 'another schema qualifies an old name'; Line = 'const a = "care.usp_scenario_cpu_pressure";'; Message = '*scratch.ts still names the retired module usp_scenario_cpu_pressure*nothing was written*' }
    ) {
        $root = New-RcaFixtureCopy -Name ('stops-' + [guid]::NewGuid().ToString('N'))
        # Names the script would rename, in a fixture and in another file, so that any write would show.
        $chain = Join-Path -Path $root -ChildPath 'rca/fixtures/t1-blocking-chain.evidence.json'
        $document = [System.IO.File]::ReadAllText($chain)
        [System.IO.File]::WriteAllText($chain, $document.Replace('[scheduling].[usp_route_work_item]', '[demo].[usp_scenario_chain_link]'))
        [System.IO.File]::WriteAllText((Join-Path -Path $root -ChildPath 'renamable.ts'), 'const b = "demo.usp_scenario_chain_link";')
        [System.IO.File]::WriteAllText((Join-Path -Path $root -ChildPath 'scratch.ts'), $Line)
        $before = Get-TreeHash -Root $root

        { & $tool -RepositoryRoot $root -RenameWorkloadModules -Path 'renamable.ts', 'scratch.ts' } | Should -Throw -ExpectedMessage $Message

        Get-TreeHash -Root $root | Should -Be $before
    }

    It 'renames a scenario.json''s prose and leaves its procedure line to the catalog' {
        $root = New-RcaFixtureCopy -Name 'catalog'
        $catalog = Join-Path -Path $root -ChildPath 'scenarios/cpu-pressure/scenario.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $catalog -Parent) -Force
        [System.IO.File]::WriteAllText($catalog, "{`n  `"procedure`": `"demo.usp_scenario_cpu_pressure`",`n  `"reset`": `"Nothing to undo after demo.usp_scenario_cpu_pressure.`"`n}`n")

        & $tool -RepositoryRoot $root -RenameWorkloadModules -Path 'scenarios/cpu-pressure/scenario.json' | Out-Null

        [System.IO.File]::ReadAllText($catalog) | Should -BeExactly "{`n  `"procedure`": `"demo.usp_scenario_cpu_pressure`",`n  `"reset`": `"Nothing to undo after scheduling.usp_find_double_bookings.`"`n}`n"
    }

    It 'takes -Path only with -RenameWorkloadModules' {
        $root = New-RcaFixtureCopy -Name 'path-alone'
        { & $tool -RepositoryRoot $root -Path 'scratch.ts' } | Should -Throw -ExpectedMessage '*needs -RenameWorkloadModules*'
    }
}

Describe 'Update-RcaFixtures.ps1: the part lines, written again' {
    It 'writes nothing while a document''s part count would change, then every part, index, and parameter once none would' {
        $root = New-RcaFixtureCopy -Name 'counts'
        $fixtures = Join-Path -Path $root -ChildPath 'rca/fixtures'
        $chain = Join-Path -Path $fixtures -ChildPath 't1-blocking-chain.evidence.json'
        $replica = Join-Path -Path $fixtures -ChildPath 't4-replica-lag.evidence.json'
        $chainBefore = Expand-RcaPartFile -LiteralPath (Join-Path -Path $fixtures -ChildPath 't1-blocking-chain.parts.txt')
        # T1's document changes and keeps its 2 parts; T4's, which the script reaches after it, would need more.
        $chainText = [System.IO.File]::ReadAllText($chain).Replace('"exportedUtc": "2026-11-20T17:22:04.512Z"', '"exportedUtc": "2026-11-20T17:22:04.513Z"')
        [System.IO.File]::WriteAllText($chain, $chainText)
        $replicaText = [System.IO.File]::ReadAllText($replica)
        $noise = [byte[]]::new(3000)
        [System.Random]::new(7).NextBytes($noise)
        [System.IO.File]::WriteAllText($replica, $replicaText.Replace('"strings": [', ('"strings": [' + "`n    `"" + [System.Convert]::ToBase64String($noise) + '",')))
        $before = Get-TreeHash -Root $root

        { & $tool -RepositoryRoot $root } | Should -Throw -ExpectedMessage '*t4-replica-lag.evidence.json would need * part(s), not 2*nothing was written*'
        Get-TreeHash -Root $root | Should -Be $before -Because 'T1''s parts, the indexes, and the parameters wait until every document passes its check'

        [System.IO.File]::WriteAllText($replica, $replicaText)
        & $tool -RepositoryRoot $root | Out-Null

        $chainAfter = Expand-RcaPartFile -LiteralPath (Join-Path -Path $fixtures -ChildPath 't1-blocking-chain.parts.txt')
        $chainAfter.Lines.Count | Should -Be 2
        $chainAfter.Sha256 | Should -Be $chainAfter.ActualSha256
        $chainAfter.Sha256 | Should -Not -Be $chainBefore.Sha256
        [System.Text.Json.Nodes.JsonNode]::DeepEquals([System.Text.Json.Nodes.JsonNode]::Parse($chainAfter.Json), [System.Text.Json.Nodes.JsonNode]::Parse($chainText)) | Should -BeTrue
        foreach ($index in 'export-index.json', 'metrics-rca-member.json') {
            $entry = @((Get-Content -LiteralPath (Join-Path -Path $fixtures -ChildPath $index) -Raw | ConvertFrom-Json).documents | Where-Object { $_.documentId -eq '20261120T165000Z-sqlvm01-0001' })
            $entry.Count | Should -Be 1 -Because $index
            $entry[0].sha256 | Should -Be $chainAfter.Sha256 -Because $index
        }
        foreach ($parameter in 'rca-evidence.parameter.json', 'metrics-bundle.json') {
            $parts = @((Get-Content -LiteralPath (Join-Path -Path $fixtures -ChildPath $parameter) -Raw | ConvertFrom-Json).parts)
            foreach ($line in $chainAfter.Lines) { $parts | Should -Contain $line -Because $parameter }
            foreach ($line in $chainBefore.Lines) { $parts | Should -Not -Contain $line -Because $parameter }
        }

        $after = Get-TreeHash -Root $root
        & $tool -RepositoryRoot $root | Out-Null
        Get-TreeHash -Root $root | Should -Be $after -Because 'a second run changes nothing'
    }
}
