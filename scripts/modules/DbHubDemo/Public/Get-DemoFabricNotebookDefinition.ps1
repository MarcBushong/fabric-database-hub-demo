function Get-DemoFabricNotebookDefinition {
    <#
    .SYNOPSIS
    Builds the Fabric REST API definition for a local .ipynb notebook. Local only: no network calls.

    .DESCRIPTION
    Validates the notebook (JSON, nbformat 4, and no outputs or execution counts, so nothing a cell printed can
    be uploaded), then returns the documented definition: format 'ipynb' with one part, 'notebook-content.ipynb',
    whose payload is the file's UTF-8 bytes in InlineBase64.

    When -LakehouseId and -LakehouseWorkspaceId are given, the uploaded payload (never the file) is bound to that
    lakehouse: metadata.dependencies.lakehouse gets default_lakehouse, default_lakehouse_workspace_id,
    known_lakehouses, and default_lakehouse_name, and the parameters cell gets WORKSPACE_ID, LAKEHOUSE_ID, and
    LAKEHOUSE_NAME. The repo's notebooks hold no Fabric IDs (ADR 0021): Resolve-DemoFabricConfig resolves them by
    name, and this binding puts them in at import. Without the IDs, the payload is the file as it is.

    -GitHubRepository and -GitHubEnvironment set GITHUB_REPOSITORY and GITHUB_ENVIRONMENT in the uploaded copy's
    parameters cell, where the notebook has them, so a copy of the repository links to and triggers its own workflows.

    Notebook definition: https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/notebook-definition
    ipynb example (part path notebook-content.ipynb): https://learn.microsoft.com/rest/api/fabric/notebook/items/create-notebook
    Default lakehouse in a notebook's metadata: https://learn.microsoft.com/fabric/data-engineering/notebook-source-control-deployment

    .EXAMPLE
    $definition = Get-DemoFabricNotebookDefinition -Path ./fabric/notebooks/NB_DatabaseHub_Deployment.ipynb
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [ValidatePattern('^[A-Za-z0-9 _.-]{1,256}$')]
        [string] $DisplayName,

        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $LakehouseId = '',

        [ValidatePattern('^$|^[A-Za-z0-9 _.-]{1,256}$')]
        [string] $LakehouseName = '',

        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $LakehouseWorkspaceId = '',

        [ValidatePattern('^$|^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$')]
        [string] $GitHubRepository = '',

        [ValidatePattern('^$|^[A-Za-z0-9._-]+$')]
        [string] $GitHubEnvironment = ''
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Notebook not found: $Path"
    }
    $file = Get-Item -LiteralPath $Path
    if (-not $DisplayName) {
        $DisplayName = $file.BaseName
    }
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    try {
        $notebook = $text | ConvertFrom-Json -AsHashtable -Depth 64
    }
    catch {
        throw "$($file.Name) isn't valid JSON: $($_.Exception.Message)"
    }
    if ((Get-DemoMemberValue -InputObject $notebook -Name 'nbformat') -ne 4 -or $null -eq (Get-DemoMemberValue -InputObject $notebook -Name 'cells')) {
        throw "$($file.Name) isn't an nbformat 4 notebook."
    }
    foreach ($cell in @($notebook['cells'])) {
        if ((Get-DemoMemberValue -InputObject $cell -Name 'cell_type') -ne 'code') {
            continue
        }
        $outputs = Get-DemoMemberValue -InputObject $cell -Name 'outputs'
        if (($null -ne $outputs -and @($outputs).Count -gt 0) -or $null -ne (Get-DemoMemberValue -InputObject $cell -Name 'execution_count')) {
            throw "$($file.Name) has cell outputs or execution counts. Strip them (pre-commit's nbstripout hook) before importing, so no output can leave the machine."
        }
    }

    $rebound = $false
    $lakehouse = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $notebook -Name 'metadata') -Name 'dependencies') -Name 'lakehouse'
    $bindLakehouse = [bool]($LakehouseId -and $LakehouseWorkspaceId -and $lakehouse -is [System.Collections.IDictionary])
    $sameBinding = $true
    $name = ''
    $values = [ordered]@{}
    if ($bindLakehouse) {
        $name = if ($LakehouseName) { $LakehouseName } else { [string]$lakehouse['default_lakehouse_name'] }
        $sameBinding = [string]::Equals([string]$lakehouse['default_lakehouse'], $LakehouseId, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$lakehouse['default_lakehouse_workspace_id'], $LakehouseWorkspaceId, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]$lakehouse['default_lakehouse_name'] -ceq $name
        # The repo's parameters cell holds empty IDs (ADR 0021); the uploaded copy gets the resolved ones.
        $values['WORKSPACE_ID'] = $LakehouseWorkspaceId
        $values['LAKEHOUSE_ID'] = $LakehouseId
        $values['LAKEHOUSE_NAME'] = $name
    }
    if ($GitHubRepository) {
        $values['GITHUB_REPOSITORY'] = $GitHubRepository
    }
    if ($GitHubEnvironment) {
        $values['GITHUB_ENVIRONMENT'] = $GitHubEnvironment
    }
    $changed = [System.Collections.Generic.HashSet[string]]::new()
    if ($values.Count -gt 0) {
        foreach ($cell in @($notebook['cells'])) {
            # Get-DemoMemberValue returns an array as one object: enumerate it directly, not through @().
            $isParameters = $false
            foreach ($tag in (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $cell -Name 'metadata') -Name 'tags')) {
                if ([string]$tag -eq 'parameters') {
                    $isParameters = $true
                }
            }
            if ((Get-DemoMemberValue -InputObject $cell -Name 'cell_type') -ne 'code' -or -not $isParameters) {
                continue
            }
            $lines = @($cell['source'])
            for ($index = 0; $index -lt $lines.Count; $index++) {
                foreach ($key in $values.Keys) {
                    $match = [regex]::Match([string]$lines[$index], ('^{0} = "[^"]*"(\r?\n)?$' -f $key))
                    if ($match.Success) {
                        $replacement = '{0} = "{1}"{2}' -f $key, $values[$key], $match.Groups[1].Value
                        if ($replacement -cne [string]$lines[$index]) {
                            $lines[$index] = $replacement
                            $null = $changed.Add([string]$key)
                        }
                    }
                }
            }
            $cell['source'] = $lines
        }
    }
    $lakehouseParametersChanged = $changed.Contains('WORKSPACE_ID') -or $changed.Contains('LAKEHOUSE_ID') -or $changed.Contains('LAKEHOUSE_NAME')
    if ($bindLakehouse -and (-not $sameBinding -or $lakehouseParametersChanged)) {
        # Fabric's own ipynb export orders these keys alphabetically.
        $binding = [ordered]@{
            default_lakehouse              = $LakehouseId
            default_lakehouse_name         = $name
            default_lakehouse_workspace_id = $LakehouseWorkspaceId
            known_lakehouses               = @([ordered]@{ id = $LakehouseId })
        }
        foreach ($key in @($lakehouse.Keys)) {
            if (-not $binding.Contains([string]$key)) {
                $binding[[string]$key] = $lakehouse[$key]
            }
        }
        $notebook['metadata']['dependencies']['lakehouse'] = $binding
        $rebound = $true
    }
    if ($rebound -or $changed.Count -gt 0) {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($notebook | ConvertTo-Json -Depth 64))
    }

    $sha256 = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    [pscustomobject]@{
        PSTypeName       = 'DbHubDemo.FabricNotebookDefinition'
        DisplayName      = $DisplayName
        Path             = $file.FullName
        SizeBytes        = $bytes.Length
        Sha256           = $sha256
        LakehouseRebound = $rebound
        Definition       = [ordered]@{
            format = 'ipynb'
            parts  = @(
                [ordered]@{
                    path        = 'notebook-content.ipynb'
                    payload     = [System.Convert]::ToBase64String($bytes)
                    payloadType = 'InlineBase64'
                }
            )
        }
    }
}
