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
    every part), Evidence (tables, measures, parts), and Definition (parts, InlineBase64). It reads files only.

    - SemanticModel definition (TMDL is the default format): https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/semantic-model-definition
    - Direct Lake on OneLake: https://learn.microsoft.com/fabric/fundamentals/direct-lake-overview

    .PARAMETER Path
    The .SemanticModel folder.

    .PARAMETER WorkspaceId
    The workspace that holds the lakehouse (fabric.workspaceId).

    .PARAMETER LakehouseId
    The lakehouse (fabric.lakehouseId).

    .EXAMPLE
    Get-DemoFabricSemanticModelDefinition -WorkspaceId $config.fabric.workspaceId -LakehouseId $config.fabric.lakehouseId
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
        [string] $DisplayName = 'SM_DatabaseHub_History'
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
    $files = [ordered]@{}
    $files['definition.pbism'] = [System.IO.File]::ReadAllBytes($pbism)
    $tmdl = Get-ChildItem -LiteralPath $definitionDir -Recurse -File | Sort-Object -Property FullName
    $placeholders = 0
    foreach ($file in $tmdl) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        $text = $utf8.GetString([System.IO.File]::ReadAllBytes($file.FullName))
        if ($relative -eq 'definition/expressions.tmdl') {
            $placeholders = ([regex]::Matches($text, [regex]::Escape($placeholder))).Count
            $text = $text.Replace($placeholder, $source)
        }
        if ($text.Contains($zero)) {
            throw "$relative still has an all-zero ID after the lakehouse was filled in."
        }
        $files[$relative] = $utf8.GetBytes($text)
    }
    if ($placeholders -ne 1) {
        throw "definition/expressions.tmdl must have the all-zero OneLake placeholder exactly once; it has it $placeholders time(s)."
    }

    $tables = @($tmdl | Where-Object { $_.DirectoryName -eq (Join-Path -Path $definitionDir -ChildPath 'tables') }).Count
    $measures = @(Get-DemoTmdlMeasure -DefinitionPath $definitionDir).Count
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
            format   = 'TMDL'
            parts    = $files.Count
            tables   = $tables
            measures = $measures
        }
        Definition  = [ordered]@{ parts = $built.Parts }
    }
}
