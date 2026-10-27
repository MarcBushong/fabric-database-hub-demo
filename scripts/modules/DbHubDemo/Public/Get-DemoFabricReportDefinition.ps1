function Get-DemoFabricReportDefinition {
    <#
    .SYNOPSIS
    Builds the definition of the RPT_DatabaseHub_History report from its PBIR folder, bound to a deployed semantic
    model, in the shape Import-DemoFabricItem sends.

    .DESCRIPTION
    Reads fabric/powerbi/RPT_DatabaseHub_History.Report (written by fabric/powerbi/generator): every file under
    definition/ and StaticResources/ as definition parts with forward-slash paths. The .platform file isn't sent. Git
    binds the report to the local model by path; the Fabric API needs the minimal byConnection form, so
    definition.pbir is replaced with 'semanticmodelid=<SemanticModelId>'. The folder must have report.json,
    version.json, pages.json, and every page it lists.

    Returns a DbHubDemo.FabricItemDefinition: DisplayName, Type (Report), Label, Path, SizeBytes, Sha256, Evidence
    (pages, visuals, parts, and the page display names in order), and Definition. It reads files only.

    - Report definition: https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/report-definition
    - Power BI Project report folder: https://learn.microsoft.com/power-bi/developer/projects/projects-report

    .PARAMETER Path
    The .Report folder.

    .PARAMETER SemanticModelId
    The deployed semantic model's item ID.

    .EXAMPLE
    Get-DemoFabricReportDefinition -SemanticModelId $modelId
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/powerbi/RPT_DatabaseHub_History.Report'),

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SemanticModelId,

        [ValidatePattern('^[A-Za-z0-9_]+$')]
        [string] $DisplayName = 'RPT_DatabaseHub_History'
    )

    $root = [System.IO.Path]::GetFullPath($Path)
    foreach ($required in 'definition.pbir', 'definition/report.json', 'definition/version.json', 'definition/pages/pages.json') {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $root -ChildPath $required) -PathType Leaf)) {
            throw "Not a PBIR report folder ($required is missing): $root"
        }
    }
    $pagesJson = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'definition/pages/pages.json') -Raw | ConvertFrom-Json -AsHashtable
    $pageNames = [System.Collections.Generic.List[string]]::new()
    $visuals = 0
    foreach ($page in @($pagesJson['pageOrder'])) {
        $pageFile = Join-Path -Path $root -ChildPath ('definition/pages/{0}/page.json' -f $page)
        if (-not (Test-Path -LiteralPath $pageFile -PathType Leaf)) {
            throw "pages.json lists page $page, but its page.json is missing."
        }
        $pageNames.Add([string]((Get-Content -LiteralPath $pageFile -Raw | ConvertFrom-Json -AsHashtable)['displayName']))
        $visualDir = Join-Path -Path $root -ChildPath ('definition/pages/{0}/visuals' -f $page)
        if (Test-Path -LiteralPath $visualDir) {
            $visuals += @(Get-ChildItem -LiteralPath $visualDir -Recurse -File -Filter 'visual.json').Count
        }
    }

    $pbir = [ordered]@{
        '$schema'        = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json'
        version          = '4.0'
        datasetReference = [ordered]@{ byConnection = [ordered]@{ connectionString = ('semanticmodelid={0}' -f $SemanticModelId.ToLowerInvariant()) } }
    }
    $files = [ordered]@{}
    $files['definition.pbir'] = [System.Text.UTF8Encoding]::new($false).GetBytes(($pbir | ConvertTo-Json -Depth 8) + "`n")
    $content = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
        $relative = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        $relative -like 'definition/*' -or $relative -like 'StaticResources/*'
    } | Sort-Object -Property FullName
    foreach ($file in $content) {
        $files[$file.FullName.Substring($root.Length + 1).Replace('\', '/')] = [System.IO.File]::ReadAllBytes($file.FullName)
    }

    $built = ConvertTo-DemoDefinitionPart -Files $files
    [pscustomobject]@{
        PSTypeName  = 'DbHubDemo.FabricItemDefinition'
        DisplayName = $DisplayName
        Type        = 'Report'
        Label       = 'report'
        Path        = $root
        SizeBytes   = $built.SizeBytes
        Sha256      = $built.Sha256
        Evidence    = [ordered]@{
            format          = 'PBIR'
            parts           = $files.Count
            pages           = $pageNames.Count
            visuals         = $visuals
            semanticModelId = $SemanticModelId.ToLowerInvariant()
        }
        PageNames   = $pageNames.ToArray()
        Definition  = [ordered]@{ parts = $built.Parts }
    }
}
