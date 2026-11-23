#Requires -Version 7.4
<#
.SYNOPSIS
Writes the Incident RCA fixtures' part lines again after their documents change, and can first rename the workload's
retired module names to their realistic ones.

.DESCRIPTION
Each evidence document and sidecar in rca/fixtures is there twice: as JSON (<name>.evidence.json, <name>.sidecar.json)
and as the part lines the runner prints (<name>.parts.txt, <name>.sidecar-parts.txt), which are its compact UTF-8 JSON,
gzipped and cut into parts of 2,400 bytes, each line naming the gzip's SHA-256 (rca/README.md, Part lines). The other
fixture files repeat those lines and that SHA-256: the evidence and sidecar parameters, the bundle, and the indexes.

For each document whose parts no longer decode to it, this script writes its part lines again, as PartCodec does, and
puts the new lines and SHA-256 in place of the old ones in every other fixture file. A document whose parts still
decode to it is left alone, so a second run changes nothing. A part count that changes stops the script, because the
fixtures' messages count parts: edit those by hand, then run it again.

With -RenameWorkloadModules, it first renames each retired workload module, demo.usp_scenario_* and the helpers beside
it, to its realistic name since 2026-11-23 (ADR 0031, decision 6) in every fixture document and in each -Path file. It
renames [demo].[old], demo.old, their regular-expression-escaped forms in tests, and the bare old name, each only as a
whole identifier. A scenario.json's procedure line is never changed.

.PARAMETER RenameWorkloadModules
Rename the retired workload module names first.

.PARAMETER Path
With -RenameWorkloadModules, more files to rename in, relative to the repository root: for example the app's RCA tests
and test data, or the runner's RCA tests.

.EXAMPLE
./tests/Update-RcaFixtures.ps1

Writes the part lines again for each fixture document that changed.

.EXAMPLE
./tests/Update-RcaFixtures.ps1 -RenameWorkloadModules -Path fabric/app/src/rca/testdata/eval-set.ts, fabric/app/src/rca/rules.test.ts

Renames the retired module names in the fixtures and in the two files, then writes the changed fixtures' part lines.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $RenameWorkloadModules,
    [string[]] $Path = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$fixtureRoot = Join-Path -Path $repoRoot -ChildPath 'rca/fixtures'
$partBytes = 2400
$maximumLineLength = 3400

# Each retired name and its realistic name, from the design of ADR 0031's decision 6: the T-SQL modules of
# database/common/120-scenario-procedures.sql, the PostgreSQL functions of database/postgresql/120-scenario-functions.sql
# (one name on both engines where a scenario runs on both), and T5's label. The answer key maps each new name to its
# scenarios (rca/blind-detection.json, answerKey.workloadNames).
$retiredModules = [ordered]@{
    'usp_scenario_healthy_baseline'    = 'frontdesk.usp_process_requests'
    'fn_locking_hot_rows'              = 'billing.fn_priority_work_items'
    'usp_scenario_locking_acquire'     = 'billing.usp_reprioritize_queue'
    'usp_scenario_locking_hold'        = 'billing.usp_reprioritize_queue_batch'
    'usp_scenario_locking_contend'     = 'billing.usp_claim_work_item'
    'usp_scenario_locking_deadlock'    = 'supply.usp_transfer_stock'
    'usp_scenario_cpu_pressure'        = 'scheduling.usp_find_double_bookings'
    'usp_io_scratch_grow'              = 'records.usp_load_archive_batch'
    'usp_scenario_io_pressure_grow'    = 'records.usp_load_archive_batch'
    'usp_scenario_io_pressure'         = 'records.usp_scan_archive'
    'usp_scenario_missing_index'       = 'billing.usp_claims_aging_report'
    'usp_scenario_inefficient_query'   = 'frontdesk.usp_find_patient_visits'
    'usp_scenario_resource_governance' = 'reporting.usp_utilization_rollup'
    'usp_scenario_log_rate_pressure'   = 'billing.usp_import_remittances'
    'fn_chain_rows'                    = 'scheduling.fn_open_work_items'
    'usp_scenario_chain_acquire'       = 'scheduling.usp_assign_work_item'
    'usp_scenario_chain_link'          = 'scheduling.usp_route_work_item'
    'usp_scenario_chain_escalate'      = 'scheduling.usp_bulk_reschedule'
    'usp_scenario_deadlock_storm'      = 'supply.usp_reconcile_stock'
    'usp_scenario_tempdb_contention'   = 'frontdesk.usp_refresh_dashboard'
    'usp_scenario_memory_grants'       = 'reporting.usp_rank_visits'
    'usp_scenario_parallel_scans'      = 'reporting.usp_encounter_summary'
    'usp_scenario_commit_flood'        = 'frontdesk.usp_log_checkin'
    'usp_scenario_slow_consumer'       = 'records.usp_export_visit_history'
    'usp_scenario_capacity_max'        = 'reporting.usp_nightly_batch'
    'usp_visit_summary_lookup'         = 'frontdesk.usp_visit_summary'
    'usp_scenario_plan_regression'     = 'frontdesk.usp_refresh_visit_summaries'
    'usp_scenario_connection_surge'    = 'frontdesk.usp_kiosk_heartbeat'
    'fn_idle_rows'                     = 'billing.fn_claims_review_batch'
    'usp_scenario_idle_in_transaction' = 'billing.usp_open_claims_review'
    'usp_scenario_idle_writer'         = 'billing.usp_update_claim_status'
    'usp_scenario_replica_lag'         = 'reporting.usp_publish_feed_checkpoint'
    'usp_scenario_ru_storm'            = 'events.usp_ingest_readings'
}

function ConvertTo-RealisticModuleText {
    # The text with every retired module name renamed, and how many it renamed. Longest names first, so a name that
    # starts another (usp_scenario_io_pressure, usp_scenario_io_pressure_grow) is never renamed inside it.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)

    $count = 0
    $start = '(?<![A-Za-z0-9_])'
    $end = '(?![A-Za-z0-9_])'
    foreach ($old in @($retiredModules.Keys | Sort-Object -Property Length -Descending)) {
        $schema, $name = $retiredModules[$old].Split('.')
        $escaped = [regex]::Escape($old)
        $forms = @(
            @(('\[demo\]\.\[' + $escaped + '\]'), ('[{0}].[{1}]' -f $schema, $name)),
            @(('\\\[demo\\\]\\\.\\\[' + $escaped + '\\\]'), ('\[{0}\]\.\[{1}\]' -f $schema, $name)),
            @(($start + 'demo\\\.' + $escaped + $end), ('{0}\.{1}' -f $schema, $name)),
            @(($start + 'demo\.' + $escaped + $end), ('{0}.{1}' -f $schema, $name)),
            @(($start + $escaped + $end), $name)
        )
        foreach ($form in $forms) {
            $count += [regex]::Matches($Text, $form[0]).Count
            $Text = [regex]::Replace($Text, $form[0], $form[1].Replace('$', '$$'))
        }
    }
    return [pscustomobject]@{ Text = $Text; Count = $count }
}

function Get-RealisticModuleFileText {
    # A file's text with its retired module names renamed. In a scenario.json, the procedure line stays as it is: the
    # catalog's entry module changes with the scripts that define it.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string] $LiteralPath)

    $text = [System.IO.File]::ReadAllText($LiteralPath)
    if ([System.IO.Path]::GetFileName($LiteralPath) -ne 'scenario.json') {
        return ConvertTo-RealisticModuleText -Text $text
    }
    $count = 0
    $lines = foreach ($line in $text.Split("`n")) {
        if ($line -match '^\s*"procedure":') {
            $line
            continue
        }
        $renamed = ConvertTo-RealisticModuleText -Text $line
        $count += $renamed.Count
        $renamed.Text
    }
    return [pscustomobject]@{ Text = ($lines -join "`n"); Count = $count }
}

function ConvertFrom-RcaPartLine {
    # A document's part lines as the JSON they carry, with the fields every line repeats.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string[]] $Line)

    $parts = @($Line | ForEach-Object {
            $fields = $_.Split(' ')
            if ($fields.Count -ne 6) { throw "Not a part line: $($_.Substring(0, [Math]::Min(60, $_.Length)))" }
            [pscustomobject]@{ Marker = $fields[0]; Format = $fields[1]; DocumentId = $fields[2]; Index = [int]$fields[3].Split('/')[0]; Sha256 = $fields[4]; Data = $fields[5] }
        } | Sort-Object -Property Index)
    $buffer = [System.IO.MemoryStream]::new()
    foreach ($part in $parts) {
        $bytes = [System.Convert]::FromBase64String($part.Data)
        $buffer.Write($bytes, 0, $bytes.Length)
    }
    $stream = [System.IO.Compression.GZipStream]::new([System.IO.MemoryStream]::new($buffer.ToArray()), [System.IO.Compression.CompressionMode]::Decompress)
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
    try {
        $json = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
    return [pscustomobject]@{ Marker = $parts[0].Marker; Format = $parts[0].Format; DocumentId = $parts[0].DocumentId; Sha256 = $parts[0].Sha256; Json = $json }
}

function ConvertTo-RcaPartLine {
    # A document's part lines, as PartCodec.Lines makes them: its compact JSON, gzipped at SmallestSize, in parts of
    # 2,400 bytes, each line with the gzip's SHA-256 and at most 3,400 characters.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $Marker,
        [Parameter(Mandatory = $true)][string] $Format,
        [Parameter(Mandatory = $true)][string] $DocumentId,
        [Parameter(Mandatory = $true)][string] $Json
    )

    $output = [System.IO.MemoryStream]::new()
    $gzip = [System.IO.Compression.GZipStream]::new($output, [System.IO.Compression.CompressionLevel]::SmallestSize, $true)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $gzip.Write($bytes, 0, $bytes.Length)
    $gzip.Dispose()
    $data = $output.ToArray()
    $sha256 = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant()
    $count = [Math]::Max(1, [int][Math]::Ceiling($data.Length / $partBytes))
    $lines = for ($index = 1; $index -le $count; $index++) {
        $offset = ($index - 1) * $partBytes
        $line = '{0} {1} {2} {3}/{4} {5} {6}' -f $Marker, $Format, $DocumentId, $index, $count, $sha256, [System.Convert]::ToBase64String($data, $offset, [Math]::Min($partBytes, $data.Length - $offset))
        if ($line.Length -gt $maximumLineLength) { throw "Part $index of $DocumentId would be $($line.Length) characters." }
        $line
    }
    return [pscustomobject]@{ Sha256 = $sha256; Lines = @($lines) }
}

Add-Type -AssemblyName 'System.Text.Encodings.Web'
$compact = [System.Text.Json.JsonSerializerOptions]::new()
$compact.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping

$documents = @(Get-ChildItem -LiteralPath $fixtureRoot -File -Filter '*.json' | ForEach-Object {
        $match = [regex]::Match($_.Name, '^(?<name>.+)\.(?<kind>evidence|sidecar)\.json$')
        if ($match.Success) {
            $parts = if ($match.Groups['kind'].Value -eq 'evidence') { '{0}.parts.txt' } else { '{0}.sidecar-parts.txt' }
            $partsPath = Join-Path -Path $fixtureRoot -ChildPath ($parts -f $match.Groups['name'].Value)
            if (Test-Path -LiteralPath $partsPath -PathType Leaf) {
                [pscustomobject]@{ Path = $_.FullName; Parts = $partsPath; Name = $_.Name }
            }
        }
    })

if ($RenameWorkloadModules) {
    $targets = @($documents | ForEach-Object { $_.Path }) + @($Path | ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path -Path $repoRoot -ChildPath $_)) })
    foreach ($target in ($targets | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "No such file: $target" }
        $renamed = Get-RealisticModuleFileText -LiteralPath $target
        if ($renamed.Count -gt 0 -and $PSCmdlet.ShouldProcess($target, "Rename $($renamed.Count) retired module name(s)")) {
            [System.IO.File]::WriteAllText($target, $renamed.Text)
        }
        Write-Output ('{0,4} retired module name(s) in {1}' -f $renamed.Count, $target.Substring($repoRoot.Length + 1).Replace('\', '/'))
    }
}

$replacements = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($document in $documents) {
    $old = ConvertFrom-RcaPartLine -Line @(Get-Content -LiteralPath $document.Parts | Where-Object { $_ })
    $node = [System.Text.Json.Nodes.JsonNode]::Parse([System.IO.File]::ReadAllText($document.Path))
    if ([System.Text.Json.Nodes.JsonNode]::DeepEquals($node, [System.Text.Json.Nodes.JsonNode]::Parse($old.Json))) {
        Write-Output ('{0}: its parts decode to it; unchanged' -f $document.Name)
        continue
    }
    $oldLines = @(Get-Content -LiteralPath $document.Parts | Where-Object { $_ })
    $new = ConvertTo-RcaPartLine -Marker $old.Marker -Format $old.Format -DocumentId $old.DocumentId -Json $node.ToJsonString($compact)
    if ($new.Lines.Count -ne $oldLines.Count) {
        throw "$($document.Name) now has $($new.Lines.Count) part(s), not $($oldLines.Count): the fixtures' indexes and messages count parts, so edit them by hand first."
    }
    if ($PSCmdlet.ShouldProcess($document.Parts, 'Write the part lines again')) {
        [System.IO.File]::WriteAllText($document.Parts, (($new.Lines -join "`n") + "`n"))
    }
    $replacements.Add([pscustomobject]@{ OldLines = $oldLines; NewLines = $new.Lines; OldSha256 = $old.Sha256; NewSha256 = $new.Sha256 })
    Write-Output ('{0}: {1} part(s), SHA-256 {2} is now {3}' -f $document.Name, $new.Lines.Count, $old.Sha256, $new.Sha256)
}

if ($replacements.Count -gt 0) {
    $documentPaths = @($documents | ForEach-Object { $_.Path })
    foreach ($file in Get-ChildItem -LiteralPath $fixtureRoot -File -Filter '*.json' | Where-Object { $_.FullName -notin $documentPaths }) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $updated = $text
        foreach ($replacement in $replacements) {
            for ($index = 0; $index -lt $replacement.OldLines.Count; $index++) {
                $updated = $updated.Replace($replacement.OldLines[$index], $replacement.NewLines[$index])
            }
            $updated = $updated.Replace($replacement.OldSha256, $replacement.NewSha256)
        }
        if ($updated -cne $text -and $PSCmdlet.ShouldProcess($file.FullName, 'Put the new part lines and SHA-256 in place')) {
            [System.IO.File]::WriteAllText($file.FullName, $updated)
            Write-Output ('{0}: the new part lines and SHA-256 are in place' -f $file.Name)
        }
    }
}
