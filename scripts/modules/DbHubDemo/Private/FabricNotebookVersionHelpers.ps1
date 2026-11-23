# The demo's notebooks in its workspace: whether a copy is a version the demo published, which nobody edited, so
# deploy.ps1 brings it up to date while fabric.importNotebooks is false and keeps an edited one (follow-ups decision 2a,
# 2026-11-23). Internal.
# - Items - Get Item Definition (format=ipynb): https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition
# - Notebook definition (ipynb and FabricGitSource): https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/notebook-definition

# The parameters the import sets in a notebook's parameters cell (Get-DemoFabricNotebookDefinition): the workspace, the
# lakehouse, and the GitHub path. Their values are this run's binding, not an edit.
$script:FabricNotebookBindingKeys = @('WORKSPACE_ID', 'LAKEHOUSE_ID', 'LAKEHOUSE_NAME', 'GITHUB_REPOSITORY', 'GITHUB_ENVIRONMENT')

# Every version of each of the demo's notebooks in this repository's history (Get-DemoNotebookPublishedVersion).
$script:FabricNotebookVersionsPath = Join-Path -Path $script:RepoRoot -ChildPath 'fabric/notebooks/published-versions.json'

function Get-DemoNotebookFingerprint {
    <#
    .SYNOPSIS
    A notebook's code as one SHA-256, from its ipynb text: each cell's type and source, in order. What Fabric keeps around
    them doesn't count: outputs, execution counts, metadata, line endings, spaces at a line's end, blank lines at a cell's
    ends, and empty cells. Nor do the values the import sets ($script:FabricNotebookBindingKeys, each on a line of its own,
    KEY = "value"), which are read into Bindings. Returns Sha256 and Bindings, or $null when the text isn't an nbformat
    notebook. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    try {
        $notebook = $Text | ConvertFrom-Json -AsHashtable
    }
    catch {
        return $null
    }
    if ($notebook -isnot [System.Collections.IDictionary] -or -not $notebook.Contains('cells')) {
        return $null
    }
    $bindingLine = '^({0}) = "([^"]*)"$' -f ($script:FabricNotebookBindingKeys -join '|')
    $bindings = [ordered]@{}
    $code = [System.Text.StringBuilder]::new()
    foreach ($cell in @($notebook['cells'])) {
        if ($cell -isnot [System.Collections.IDictionary]) {
            continue
        }
        $type = [string]$cell['cell_type']
        $source = $cell['source']
        # nbformat: a cell's source is one string, or a list of strings joined as they are.
        $text = if ($source -is [string]) { $source } elseif ($null -ne $source) { -join @(foreach ($piece in @($source)) { [string]$piece }) } else { '' }
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($text -replace "`r`n", "`n" -replace "`r", "`n").Split([char]10)) {
            $line = $line.TrimEnd()
            if ($type -eq 'code') {
                $match = [regex]::Match($line, $bindingLine)
                if ($match.Success) {
                    if (-not $bindings.Contains($match.Groups[1].Value)) {
                        $bindings[$match.Groups[1].Value] = $match.Groups[2].Value
                    }
                    $line = '{0} = ""' -f $match.Groups[1].Value
                }
            }
            $lines.Add($line)
        }
        $body = ($lines -join "`n").Trim([char]10)
        if (-not $body) {
            continue
        }
        $null = $code.Append($type).Append("`t").Append($body.Length).Append("`n").Append($body).Append("`n")
    }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($code.ToString())
    return [pscustomobject]@{
        Sha256   = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        Bindings = $bindings
    }
}

function Get-DemoNotebookPublishedVersion {
    <#
    .SYNOPSIS
    The fingerprints of every version of one of the demo's notebooks in this repository's history, oldest first, each
    with the day it first appeared (fabric/notebooks/published-versions.json, which a unit test keeps current). Returns
    Sha256 and Since for each; nothing for a notebook the file doesn't list, or when the file can't be read, so a copy
    then counts as edited and is kept. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [string] $Path = $script:FabricNotebookVersionsPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    try {
        $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        return @()
    }
    $notebooks = if ($data -is [System.Collections.IDictionary]) { $data['notebooks'] } else { $null }
    if ($notebooks -isnot [System.Collections.IDictionary] -or -not $notebooks.Contains($Name)) {
        return @()
    }
    return @(foreach ($entry in @($notebooks[$Name])) {
            if ($entry -is [System.Collections.IDictionary] -and [string]$entry['sha256'] -match '^[0-9a-f]{64}$') {
                $since = $entry['since']
                [pscustomobject]@{
                    Sha256 = [string]$entry['sha256']
                    Since  = $(if ($since -is [datetime]) { $since.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$since })
                }
            }
        })
}

function Read-DemoFabricItemDefinition {
    <#
    .SYNOPSIS
    An item's definition with Items - Get Item Definition, in -Format when given (ipynb for a notebook). It can answer 202:
    the operation is then waited for, at most -TimeoutSeconds, and the definition read from its result. Returns Ok, Parts
    (each part's path and bytes), Error, and CapacityInactive (the workspace's capacity is paused or inactive). Never
    throws. Internal.
    https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $ItemId,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidatePattern('^[A-Za-z]*$')]
        [string] $Format = '',

        [ValidateRange(10, 3600)]
        [int] $TimeoutSeconds = 300
    )

    $answer = {
        param([bool] $Ok, [System.Collections.IDictionary] $Parts, [string] $Why = '')
        [pscustomobject]@{ Ok = $Ok; Parts = $Parts; Error = $Why; CapacityInactive = (Test-DemoFabricCapacityInactiveText -Text $Why) }
    }
    try {
        $uri = '{0}/workspaces/{1}/items/{2}/getDefinition{3}' -f $script:FabricApiBaseUri, $WorkspaceId, $ItemId, $(if ($Format) { '?format=' + $Format } else { '' })
        $response = Invoke-DemoFabricRequest -Method Post -Uri $uri -Token $Token
        $body = $null
        if ([int]$response.StatusCode -eq 200) {
            $body = $response.Body
        }
        elseif ([int]$response.StatusCode -eq 202) {
            $operationId = Get-DemoFabricHeaderValue -Headers $response.Headers -Name 'x-ms-operation-id'
            $state = Wait-DemoFabricOperation -OperationId $operationId -Token $Token -TimeoutSeconds $TimeoutSeconds -RetryAfterSeconds (Get-DemoFabricRetryDelay -Headers $response.Headers -Default 5 -Maximum 30)
            if ([string]$state.Status -ne 'Succeeded') {
                return (& $answer $false @{} ('reading its definition ended {0} {1}' -f $state.Status, $state.Error).Trim())
            }
            $result = Invoke-DemoFabricRequest -Method Get -Uri ('{0}/operations/{1}/result' -f $script:FabricApiBaseUri, $operationId) -Token $Token
            if ([int]$result.StatusCode -ne 200) {
                return (& $answer $false @{} (Get-DemoFabricErrorText -Response $result))
            }
            $body = $result.Body
        }
        else {
            return (& $answer $false @{} (Get-DemoFabricErrorText -Response $response))
        }
        $parts = [ordered]@{}
        # Get-DemoMemberValue returns an array as one object: enumerate it directly, not through @().
        foreach ($part in (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $body -Name 'definition') -Name 'parts')) {
            $path = [string](Get-DemoMemberValue -InputObject $part -Name 'path')
            $payload = [string](Get-DemoMemberValue -InputObject $part -Name 'payload')
            if ($path -and $payload) {
                $parts[$path] = [System.Convert]::FromBase64String($payload)
            }
        }
        return (& $answer $true $parts)
    }
    catch {
        return (& $answer $false @{} (Protect-DemoText -Text (Get-DemoExceptionText -Exception $_.Exception)))
    }
}

function Get-DemoLiveNotebookUpdateFix {
    <#
    .SYNOPSIS
    How a fix text brings the workspace's NB_DatabaseHub_LiveActivity up to date (2026-11-23), without a final period:
    ./scripts/deploy.ps1 updates it, unless someone edited it while fabric.importNotebooks is false (follow-ups decision
    2a); then ./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity updates that notebook
    alone, as the Incident RCA's fixes name it, and leaves NB_DatabaseHub_Deployment as it is. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ([bool](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'importNotebooks')) {
        return 'Run ./scripts/deploy.ps1, which updates the notebook'
    }
    return 'Run ./scripts/deploy.ps1, which updates the notebook unless someone edited it; ./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity updates that notebook alone, edited or not'
}

function Get-DemoFabricNotebookState {
    <#
    .SYNOPSIS
    Whether the workspace's copy of one of the demo's notebooks is a version the demo published, which nobody edited
    (follow-ups decision 2a, 2026-11-23). Reads it as ipynb (Read-DemoFabricItemDefinition), and compares its fingerprint
    (Get-DemoNotebookFingerprint) with the one -Notebook uploads, and with every version in this repository's history
    (Get-DemoNotebookPublishedVersion). Returns State, ItemId, Since, and Error. Never throws. Internal.

    .DESCRIPTION
    - Missing: the workspace has no notebook by the name. Duplicate: it has more than one. ListFailed: its notebooks
      couldn't be listed (Error).
    - Current: this version, with the values -Notebook sets for the workspace, the lakehouse, and the GitHub path.
    - Rebind: this version, with other values: it's bound to another lakehouse, for example.
    - Older: an earlier version of the demo's (Since: the day that version first appeared), so nobody edited it.
    - Edited: none of them: someone edited it, or another copy of the scripts published it (a newer one, or a fork).
    - Unread: its definition couldn't be read (Error; CapacityInactive when the workspace's capacity is paused), or isn't
      a notebook the check reads.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [PSTypeName('DbHubDemo.FabricNotebookDefinition')]
        [pscustomobject] $Notebook,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidateRange(10, 3600)]
        [int] $TimeoutSeconds = 300
    )

    $answer = {
        param([string] $State, [string] $ItemId = '', [string] $Why = '', [string] $Since = '', [bool] $CapacityInactive = $false)
        [pscustomobject]@{ State = $State; ItemId = $ItemId; Error = $Why; Since = $Since; CapacityInactive = $CapacityInactive }
    }
    try {
        $found = Find-DemoFabricItem -WorkspaceId $WorkspaceId -DisplayName $Notebook.DisplayName -Type 'Notebook' -Token $Token
    }
    catch {
        return (& $answer 'ListFailed' '' (Protect-DemoText -Text (Get-DemoExceptionText -Exception $_.Exception)))
    }
    if ([int]$found.StatusCode -ne 200) {
        return (& $answer 'ListFailed' '' ([string]$found.Error))
    }
    $items = @($found.Items)
    if ($items.Count -eq 0) {
        return (& $answer 'Missing')
    }
    if ($items.Count -gt 1) {
        return (& $answer 'Duplicate')
    }
    $itemId = [string](Get-DemoMemberValue -InputObject $items[0] -Name 'id')
    if ($itemId -notmatch $script:GuidPattern) {
        return (& $answer 'Unread' '' 'the workspace listed it without an item ID')
    }
    $read = Read-DemoFabricItemDefinition -WorkspaceId $WorkspaceId -ItemId $itemId -Token $Token -Format 'ipynb' -TimeoutSeconds $TimeoutSeconds
    if (-not $read.Ok) {
        return (& $answer 'Unread' $itemId ([string]$read.Error) '' ([bool]$read.CapacityInactive))
    }
    $path = @($read.Parts.Keys | Where-Object { [string]$_ -like '*.ipynb' }) | Select-Object -First 1
    if (-not $path) {
        return (& $answer 'Unread' $itemId ('its definition came back without an ipynb part ({0})' -f $(if ($read.Parts.Count) { @($read.Parts.Keys) -join ', ' } else { 'no parts' })))
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $there = Get-DemoNotebookFingerprint -Text $utf8.GetString([byte[]]$read.Parts[$path])
    if ($null -eq $there) {
        return (& $answer 'Unread' $itemId 'its definition isn''t an nbformat notebook')
    }
    $code = Get-DemoNotebookFingerprint -Text $utf8.GetString([System.Convert]::FromBase64String([string]@($Notebook.Definition['parts'])[0]['payload']))
    if ($null -ne $code -and $there.Sha256 -eq $code.Sha256) {
        $same = $true
        foreach ($key in @($code.Bindings.Keys) + @($there.Bindings.Keys)) {
            if (-not [string]::Equals([string]$code.Bindings[$key], [string]$there.Bindings[$key], [System.StringComparison]::OrdinalIgnoreCase)) {
                $same = $false
            }
        }
        return (& $answer $(if ($same) { 'Current' } else { 'Rebind' }) $itemId)
    }
    $name = if ([string]$Notebook.Path) { [System.IO.Path]::GetFileNameWithoutExtension([string]$Notebook.Path) } else { [string]$Notebook.DisplayName }
    $known = @(Get-DemoNotebookPublishedVersion -Name $name | Where-Object { $_.Sha256 -eq $there.Sha256 }) | Select-Object -First 1
    if ($null -ne $known) {
        return (& $answer 'Older' $itemId '' ([string]$known.Since))
    }
    return (& $answer 'Edited' $itemId)
}
