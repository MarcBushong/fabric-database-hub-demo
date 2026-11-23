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
decode to it is left alone, so a second run changes nothing.

It plans every change in memory and writes nothing until all of them pass their checks, so a run that stops leaves
every file as it found it. A document whose part count would change stops it: the indexes count its parts, and the
parameters, the bundle, and their messages hold and count its part lines, which this script doesn't change.

With -RenameWorkloadModules, it first renames each retired workload module, demo.usp_scenario_* and the helpers beside
it, to its realistic name since 2026-11-23 (ADR 0031, decision 6) in every fixture document and in each -Path file:
 - a name qualified by demo, however the file quotes or escapes it ([demo].[old], "demo"."old", demo.old, and a
   regular expression's \[demo\]\.\[old\] or \\[demo\\]\\.\\[old\\]), takes its new schema and name;
 - a name that nothing qualifies takes its new name;
 - names match in any case, each only as a whole identifier, and a scenario.json's procedure line is never changed.
It then stops, before writing anything, when an old name is left (qualified some other way) or a new name is still
qualified by demo (half renamed by hand), and names the file and the text, to rename by hand.

.PARAMETER RenameWorkloadModules
Rename the retired workload module names first.

.PARAMETER Path
With -RenameWorkloadModules, more files to rename in, relative to the repository root: for example the app's RCA tests
and test data, or the runner's RCA tests.

.PARAMETER RepositoryRoot
The repository whose rca/fixtures to update: by default the one this script is in. Its tests run it on a copy.

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
    [string[]] $Path = @(),
    [string] $RepositoryRoot = (Join-Path -Path $PSScriptRoot -ChildPath '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
$fixtureRoot = Join-Path -Path $repoRoot -ChildPath 'rca/fixtures'
$partBytes = 2400
$maximumLineLength = 3400
if (-not (Test-Path -LiteralPath $fixtureRoot -PathType Container)) {
    throw "$repoRoot has no rca/fixtures folder."
}
if ($Path.Count -gt 0 -and -not $RenameWorkloadModules) {
    throw '-Path names files to rename the retired module names in, so it needs -RenameWorkloadModules.'
}

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

# How a file can qualify a name: besides its one dot, brackets ([demo].[x]), double or single quotes ("demo"."x"),
# backticks, backslashes (a regular expression's \[demo\]\.\[x\], or that inside a string literal, \\[demo\\]\\.\\[x\\]),
# spaces, and tabs.
$quoting = '[\\\[\]"''`\t ]*'
$qualifier = $quoting + '\.' + $quoting
$identifierStart = '(?<![A-Za-z0-9_])'
$identifierEnd = '(?![A-Za-z0-9_])'
$ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
# Longest first, so a name that starts another (usp_scenario_io_pressure, usp_scenario_io_pressure_grow) never takes
# the other's place.
$oldNames = @($retiredModules.Keys | Sort-Object -Property Length -Descending)
$newNames = @($retiredModules.Values | ForEach-Object { $_.Split('.')[1] } | Sort-Object -Unique | Sort-Object -Property Length -Descending)
$anyOldName = $identifierStart + '(?<name>' + (($oldNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')' + $identifierEnd
$anyNewNameInDemo = $identifierStart + 'demo' + $qualifier + '(?<name>' + (($newNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')' + $identifierEnd

function Get-TextExcerpt {
    # The text around a match, on one line, for a message.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][System.Text.RegularExpressions.Match] $Match
    )

    $start = [Math]::Max(0, $Match.Index - 30)
    $length = [Math]::Min($Text.Length - $start, $Match.Length + 60)
    return ($Text.Substring($start, $length) -replace '\s+', ' ').Trim()
}

function ConvertTo-RealisticModuleText {
    # The text with every retired module name renamed, and how many it renamed: one qualified by demo, however the text
    # quotes or escapes it, takes its new schema and name; one that nothing qualifies, its new name; in any case. It
    # stops when an old name is left, qualified some other way, or a new name is qualified by demo, half renamed by hand.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory = $true)][string] $Source
    )

    $count = 0
    foreach ($old in $oldNames) {
        $schema, $name = $retiredModules[$old].Split('.')
        $escaped = [regex]::Escape($old)
        $qualified = $identifierStart + 'demo(?<separator>' + $qualifier + ')' + $escaped + $identifierEnd
        $count += [regex]::Matches($Text, $qualified, $ignoreCase).Count
        $Text = [regex]::Replace($Text, $qualified, ($schema + '${separator}' + $name), $ignoreCase)
        $bare = $identifierStart + '(?<!\.' + $quoting + ')' + $escaped + $identifierEnd
        $count += [regex]::Matches($Text, $bare, $ignoreCase).Count
        $Text = [regex]::Replace($Text, $bare, $name, $ignoreCase)
    }

    $left = [regex]::Match($Text, $anyOldName, $ignoreCase)
    if ($left.Success) {
        throw ('{0} still names the retired module {1}, qualified in a way this script doesn''t rename: "{2}". Rename it by hand; nothing was written.' -f $Source, $left.Groups['name'].Value, (Get-TextExcerpt -Text $Text -Match $left))
    }
    $half = [regex]::Match($Text, $anyNewNameInDemo, $ignoreCase)
    if ($half.Success) {
        throw ('{0} names {1} in demo, which never has it, as a rename that kept the old schema would: "{2}". Give it its schema by hand; nothing was written.' -f $Source, $half.Groups['name'].Value, (Get-TextExcerpt -Text $Text -Match $half))
    }
    return [pscustomobject]@{ Text = $Text; Count = $count }
}

function Get-RealisticModuleFileText {
    # A file's text with its retired module names renamed. In a scenario.json, the procedure line stays as it is: the
    # catalog's entry module changes with the scripts that define it.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory = $true)][string] $Source,
        [switch] $ScenarioCatalog
    )

    if (-not $ScenarioCatalog) {
        return ConvertTo-RealisticModuleText -Text $Text -Source $Source
    }
    $count = 0
    $lines = foreach ($line in $Text.Split("`n")) {
        if ($line -match '^\s*"procedure":') {
            $line
            continue
        }
        $renamed = ConvertTo-RealisticModuleText -Text $line -Source $Source
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

# Every file this run writes, with its new text: nothing is written until every rename, document, and part count has
# been checked, so a run that stops leaves every file as it found it.
$planned = [ordered]@{}
$messages = [System.Collections.Generic.List[string]]::new()

function Get-PlannedText {
    # A file's text as this run would leave it: its planned text, or what's on disk.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $LiteralPath)

    if ($planned.Contains($LiteralPath)) {
        return $planned[$LiteralPath]
    }
    return [System.IO.File]::ReadAllText($LiteralPath)
}

function Get-RepositoryRelativePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $LiteralPath)

    return [System.IO.Path]::GetRelativePath($repoRoot, $LiteralPath).Replace('\', '/')
}

$documents = @(Get-ChildItem -LiteralPath $fixtureRoot -File -Filter '*.json' | Sort-Object -Property Name | ForEach-Object {
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
    $targets = @($documents | ForEach-Object { $_.Path }) + @($Path | ForEach-Object { [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($repoRoot, $_)) })
    foreach ($target in ($targets | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "No such file: $target. Nothing was written."
        }
        $source = Get-RepositoryRelativePath -LiteralPath $target
        $renamed = Get-RealisticModuleFileText -Text (Get-PlannedText -LiteralPath $target) -Source $source -ScenarioCatalog:([System.IO.Path]::GetFileName($target) -eq 'scenario.json')
        if ($renamed.Count -gt 0) {
            $planned[$target] = $renamed.Text
        }
        $messages.Add(('{0,4} retired module name(s) in {1}' -f $renamed.Count, $source))
    }
}

$replacements = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($document in $documents) {
    $oldLines = @(Get-Content -LiteralPath $document.Parts | Where-Object { $_ })
    $old = ConvertFrom-RcaPartLine -Line $oldLines
    $node = [System.Text.Json.Nodes.JsonNode]::Parse((Get-PlannedText -LiteralPath $document.Path))
    if ([System.Text.Json.Nodes.JsonNode]::DeepEquals($node, [System.Text.Json.Nodes.JsonNode]::Parse($old.Json))) {
        $messages.Add(('{0}: its parts decode to it; unchanged' -f $document.Name))
        continue
    }
    $new = ConvertTo-RcaPartLine -Marker $old.Marker -Format $old.Format -DocumentId $old.DocumentId -Json $node.ToJsonString($compact)
    if ($new.Lines.Count -ne $oldLines.Count) {
        throw ('{0} would need {1} part(s), not {2}. The indexes count its parts, and the parameters, the bundle, and their messages hold and count its part lines, which this script doesn''t change; nothing was written.' -f $document.Name, $new.Lines.Count, $oldLines.Count)
    }
    if (-not [System.Text.Json.Nodes.JsonNode]::DeepEquals($node, [System.Text.Json.Nodes.JsonNode]::Parse((ConvertFrom-RcaPartLine -Line $new.Lines).Json))) {
        throw "$($document.Name)'s new part lines don't decode to it; nothing was written."
    }
    $planned[$document.Parts] = ($new.Lines -join "`n") + "`n"
    $replacements.Add([pscustomobject]@{ OldLines = $oldLines; NewLines = $new.Lines; OldSha256 = $old.Sha256; NewSha256 = $new.Sha256 })
    $messages.Add(('{0}: {1} part(s), SHA-256 {2} is now {3}' -f $document.Name, $new.Lines.Count, $old.Sha256, $new.Sha256))
}

if ($replacements.Count -gt 0) {
    $documentPaths = @($documents | ForEach-Object { $_.Path })
    foreach ($file in Get-ChildItem -LiteralPath $fixtureRoot -File -Filter '*.json' | Sort-Object -Property Name | Where-Object { $_.FullName -notin $documentPaths }) {
        $text = Get-PlannedText -LiteralPath $file.FullName
        $updated = $text
        foreach ($replacement in $replacements) {
            for ($index = 0; $index -lt $replacement.OldLines.Count; $index++) {
                $updated = $updated.Replace($replacement.OldLines[$index], $replacement.NewLines[$index])
            }
            $updated = $updated.Replace($replacement.OldSha256, $replacement.NewSha256)
        }
        if ($updated -cne $text) {
            $planned[$file.FullName] = $updated
            $messages.Add(('{0}: the new part lines and SHA-256 are in place' -f $file.Name))
        }
    }
}

foreach ($target in @($planned.Keys)) {
    if ($PSCmdlet.ShouldProcess($target, 'Write its new text')) {
        [System.IO.File]::WriteAllText($target, $planned[$target])
    }
}
$messages
