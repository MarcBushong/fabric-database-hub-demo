function Get-DemoFabricSemanticModelDefinition {
    <#
    .SYNOPSIS
    Builds the definition of the SM_DatabaseHub_History semantic model from its TMDL folder, bound to the configured
    lakehouse, in the shape Import-DemoFabricItem sends.

    .DESCRIPTION
    Reads fabric/powerbi/SM_DatabaseHub_History.SemanticModel: definition.pbism and every file under definition/
    (TMDL), as definition parts with forward-slash paths. The .platform file isn't sent. Git holds an all-zero OneLake
    URL in definition/expressions.tmdl, so no real ID is committed; this function puts the lakehouse's workspace and
    lakehouse IDs in its place and refuses a folder where the placeholder isn't there exactly once, or where any
    all-zero ID is left after the substitution.

    Returns a DbHubDemo.FabricItemDefinition: DisplayName, Type (SemanticModel), Label, Path, SizeBytes, Sha256 (of
    every part), Evidence (tables, measures, parts, excludedTables, snapshotValueForm), and Definition (parts,
    InlineBase64). It reads files only.

    'Snapshot Value' has two forms (F35, design (i)). The TMDL in the folder is the release's: each bin from its most
    recent capture. -SnapshotValueForm Kept sends the kept form instead, from fabric/powerbi/kept-value: the measure reads
    the kept values that the notebook and the operator's history steps write in telemetry_snapshots, with the release's
    rule for a bin not worked out yet, and the table gains their two columns. A Direct Lake model can't frame a column the
    lakehouse lacks, so the kept form is only for a lakehouse that has kept_value and resolved_at_utc.

    - SemanticModel definition (TMDL is the default format): https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/semantic-model-definition
    - Direct Lake on OneLake: https://learn.microsoft.com/fabric/fundamentals/direct-lake-overview
    - How Direct Lake frames tables: https://learn.microsoft.com/fabric/fundamentals/direct-lake-how-it-works

    .PARAMETER Path
    The .SemanticModel folder.

    .PARAMETER WorkspaceId
    The workspace that holds the lakehouse (fabric.workspaceId).

    .PARAMETER LakehouseId
    The lakehouse (fabric.lakehouseId).

    .PARAMETER ExcludeTable
    Tables of the model to leave out, by their model names, with their refs in model.tmdl and their relationships: the
    Incident RCA's tables while the lakehouse doesn't have them yet (Get-DemoRcaModelTablePlan; ADR 0031), because
    Direct Lake can't frame a missing table. Each must be one of the folder's tables.

    .PARAMETER SnapshotValueForm
    Release (the default): the folder's TMDL as it is. Kept: 'Snapshot Value' reads the kept values, and the table has
    their columns.

    .PARAMETER KeptValuePath
    The kept form's TMDL: the table's description, the measure, and the two columns.

    .EXAMPLE
    Get-DemoFabricSemanticModelDefinition -WorkspaceId $config.fabric.workspaceId -LakehouseId $config.fabric.lakehouseId

    .EXAMPLE
    Get-DemoFabricSemanticModelDefinition -WorkspaceId $config.fabric.workspaceId -LakehouseId $config.fabric.lakehouseId -SnapshotValueForm Kept
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/powerbi/SM_DatabaseHub_History.SemanticModel'),

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $LakehouseId,

        [ValidatePattern('^[A-Za-z0-9_]+$')]
        [string] $DisplayName = 'SM_DatabaseHub_History',

        [AllowEmptyCollection()]
        [string[]] $ExcludeTable = @(),

        [ValidateSet('Release', 'Kept')]
        [string] $SnapshotValueForm = 'Release',

        [string] $KeptValuePath = (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/powerbi/kept-value/Snapshot Value.tmdl')
    )

    $root = Resolve-DemoUserPath -Path $Path
    $pbism = Join-Path -Path $root -ChildPath 'definition.pbism'
    $definitionDir = Join-Path -Path $root -ChildPath 'definition'
    if (-not (Test-Path -LiteralPath $pbism -PathType Leaf) -or -not (Test-Path -LiteralPath $definitionDir -PathType Container)) {
        throw "Not a TMDL semantic model folder (definition.pbism and definition/ are required): $root"
    }
    $zero = '00000000-0000-0000-0000-000000000000'
    $placeholder = 'https://onelake.dfs.fabric.microsoft.com/{0}/{0}' -f $zero
    $source = 'https://onelake.dfs.fabric.microsoft.com/{0}/{1}' -f $WorkspaceId.ToLowerInvariant(), $LakehouseId.ToLowerInvariant()

    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    # The kept form: the fragment's table description, its 'Snapshot Value' in place of the release's, and its columns
    # before the partition. Each piece must be found exactly once, so a changed file stops the build instead of sending a
    # model that mixes the two.
    $fragmentPath = if ($SnapshotValueForm -eq 'Kept') { Resolve-DemoUserPath -Path $KeptValuePath } else { '' }
    $keptForm = {
        param([string] $Text)
        if (-not (Test-Path -LiteralPath $fragmentPath -PathType Leaf)) {
            throw "The kept form of Snapshot Value isn't there: $fragmentPath"
        }
        $fragment = $utf8.GetString([System.IO.File]::ReadAllBytes($fragmentPath)).Replace("`r`n", "`n")
        $measure = "(?ms)^    /// Base measure\.[^\n]*\n    measure 'Snapshot Value' =\n.*?^        displayFolder: Base\n"
        $description = "\A(?:///[^\n]*\n)+(?=table 'Telemetry Snapshots'\n)"
        $partition = "(?m)^    partition 'Telemetry Snapshots' = entity$"
        foreach ($check in @(@($Text, $measure, 'the table''s Snapshot Value'), @($Text, $description, 'the table''s description'), @($Text, $partition, 'the table''s partition'),
                @($fragment, $measure, 'the kept form''s Snapshot Value'), @($fragment, $description, 'the kept form''s description'))) {
            $count = [regex]::Matches($check[0], $check[1]).Count
            if ($count -ne 1) {
                throw ('The kept form of Snapshot Value can''t be applied: {0} is there {1} time(s), not once.' -f $check[2], $count)
            }
        }
        $keptMeasure = [regex]::Match($fragment, $measure)
        $columns = $fragment.Substring($keptMeasure.Index + $keptMeasure.Length).Trim("`n")
        if ($columns -notmatch "(?m)^    column 'Kept Value'$" -or $columns -notmatch "(?m)^    column 'Resolved At UTC'$" -or $Text -match "(?m)^    column '(Kept Value|Resolved At UTC)'$") {
            throw 'The kept form of Snapshot Value can''t be applied: its columns Kept Value and Resolved At UTC must follow its measure, once, and the table mustn''t have them.'
        }
        $splice = {
            param([string] $Into, [string] $Pattern, [string] $With)
            $found = [regex]::Match($Into, $Pattern)
            $Into.Substring(0, $found.Index) + $With + $Into.Substring($found.Index + $found.Length)
        }
        $result = & $splice $Text $measure $keptMeasure.Value
        $result = & $splice $result $description ([regex]::Match($fragment, $description).Value)
        return (& $splice $result $partition ($columns + "`n`n    partition 'Telemetry Snapshots' = entity"))
    }
    $files = [ordered]@{}
    $files['definition.pbism'] = [System.IO.File]::ReadAllBytes($pbism)
    $tmdl = Get-ChildItem -LiteralPath $definitionDir -Recurse -File | Sort-Object -Property FullName
    $tableDir = Join-Path -Path $definitionDir -ChildPath 'tables'
    $excluded = @($ExcludeTable | Where-Object { $_ } | Select-Object -Unique)
    foreach ($name in $excluded) {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $tableDir -ChildPath ($name + '.tmdl')) -PathType Leaf)) {
            throw "The model has no table '$name' to leave out."
        }
    }
    # A table's name as TMDL writes it: quoted, with '' for ', when it isn't a plain identifier.
    $tmdlName = { param([string] $Name) if ($Name -match '^[A-Za-z_][A-Za-z0-9_]*$') { $Name } else { "'{0}'" -f $Name.Replace("'", "''") } }
    $placeholders = 0
    foreach ($file in $tmdl) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($file.DirectoryName -eq $tableDir -and $file.BaseName -in $excluded) {
            continue
        }
        $text = $utf8.GetString([System.IO.File]::ReadAllBytes($file.FullName))
        if ($relative -eq 'definition/expressions.tmdl') {
            $placeholders = ([regex]::Matches($text, [regex]::Escape($placeholder))).Count
            $text = $text.Replace($placeholder, $source)
        }
        foreach ($name in $excluded) {
            $quoted = [regex]::Escape((& $tmdlName $name))
            if ($relative -eq 'definition/model.tmdl') {
                $text = [regex]::Replace($text, ('(?m)^ref table {0}\n' -f $quoted), '')
            }
            elseif ($relative -eq 'definition/relationships.tmdl') {
                $kept = @($text.TrimEnd("`n") -split "`n`n" | Where-Object { $_ -notmatch ('(?m)^\s+(from|to)Column: {0}\.' -f $quoted) })
                $text = ($kept -join "`n`n") + "`n"
            }
        }
        if ($relative -eq 'definition/tables/Telemetry Snapshots.tmdl' -and $SnapshotValueForm -eq 'Kept') {
            $text = & $keptForm $text
        }
        if ($text.Contains($zero)) {
            throw "$relative still has an all-zero ID after the lakehouse was filled in."
        }
        $files[$relative] = $utf8.GetBytes($text)
    }
    if ($placeholders -ne 1) {
        throw "definition/expressions.tmdl must have the all-zero OneLake placeholder exactly once; it has it $placeholders time(s)."
    }

    $tables = @($tmdl | Where-Object { $_.DirectoryName -eq $tableDir -and $_.BaseName -notin $excluded }).Count
    $measures = @(Get-DemoTmdlMeasure -DefinitionPath $definitionDir | Where-Object { $_.Table -notin $excluded }).Count
    $built = ConvertTo-DemoDefinitionPart -Files $files
    [pscustomobject]@{
        PSTypeName  = 'DbHubDemo.FabricItemDefinition'
        DisplayName = $DisplayName
        Type        = 'SemanticModel'
        Label       = 'semantic model'
        Path        = $root
        SizeBytes   = $built.SizeBytes
        Sha256      = $built.Sha256
        Evidence    = [ordered]@{
            format            = 'TMDL'
            parts             = $files.Count
            tables            = $tables
            measures          = $measures
            excludedTables    = $excluded
            snapshotValueForm = $SnapshotValueForm
        }
        Definition  = [ordered]@{ parts = $built.Parts }
    }
}
