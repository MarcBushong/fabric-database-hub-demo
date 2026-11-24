# Fabric item definition read-back (Phase 18). Internal; Import-DemoFabricItem -ReadBack calls it.
# Items - Get Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition

function Get-DemoFabricItemReadBack {
    <#
    .SYNOPSIS
    Reads an item's definition back with Items - Get Item Definition and compares it with the definition that was
    sent. Returns one ADR 0012 record (FABRIC.READBACK.<NAME>). Internal.

    .DESCRIPTION
    POST /v1/workspaces/{workspaceId}/items/{itemId}/getDefinition, which can answer 202: then it waits Retry-After,
    polls Get Operation State, and reads the definition from Get Operation Result. Every part that was sent must come
    back under the same path. A KQL dashboard part is compared with Compare-DemoDashboardDocument: Pass when every
    page, data source, parameter, query text, and tile survived (fields that Fabric normalized are listed), Fail
    otherwise. Other parts are compared byte for byte: Pass when identical, Warning when Fabric changed them. A
    read-back that can't complete is a Warning, because the import before it succeeded.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [string] $ItemId,

        [Parameter(Mandatory)]
        [pscustomobject] $Item,

        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [string] $CheckId,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidateRange(30, 3600)]
        [int] $TimeoutSeconds = 600
    )

    $docUrl = 'https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition'
    $target = "{0} '{1}'" -f $Label, $Item.DisplayName
    $evidence = [ordered]@{ workspaceId = $WorkspaceId; itemId = $ItemId; sentSha256 = $Item.Sha256 }
    $common = @{ CheckId = $CheckId; Area = 'fabric'; Target = 'fabric'; DocUrl = $docUrl }
    $result = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult @common -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation
    }
    $retry = ('Open the {0} in the workspace to check it, or run the import again; it updates the same item.' -f $Label)

    if ($ItemId -notmatch $script:GuidPattern) {
        return (& $result 'Warning' ("The import worked, but it returned no item ID, so the definition of {0} wasn't read back." -f $target) $retry)
    }
    try {
        $uri = '{0}/workspaces/{1}/items/{2}/getDefinition' -f $script:FabricApiBaseUri, $WorkspaceId, $ItemId
        $response = Invoke-DemoFabricRequest -Method Post -Uri $uri -Token $Token
        $body = $null
        if ($response.StatusCode -eq 200) {
            $body = $response.Body
        }
        elseif ($response.StatusCode -eq 202) {
            $operationId = Get-DemoFabricHeaderValue -Headers $response.Headers -Name 'x-ms-operation-id'
            $evidence['operationId'] = $operationId
            $state = Wait-DemoFabricOperation -OperationId $operationId -Token $Token -TimeoutSeconds $TimeoutSeconds `
                -RetryAfterSeconds (Get-DemoFabricRetryDelay -Headers $response.Headers -Default 5 -Maximum 30)
            if ($state.Status -ne 'Succeeded') {
                return (& $result 'Warning' ("The import worked, but reading back the definition of {0} didn't succeed: {1} {2}" -f $target, $state.Status, $state.Error).Trim() $retry)
            }
            $operationResult = Invoke-DemoFabricRequest -Method Get -Uri ('{0}/operations/{1}/result' -f $script:FabricApiBaseUri, $operationId) -Token $Token
            if ($operationResult.StatusCode -ne 200) {
                $evidence['httpStatus'] = $operationResult.StatusCode
                return (& $result 'Warning' ("The import worked, but the definition of {0} couldn't be read from the operation result: {1}" -f $target, (Get-DemoFabricErrorText -Response $operationResult)) $retry)
            }
            $body = $operationResult.Body
        }
        else {
            $evidence['httpStatus'] = $response.StatusCode
            return (& $result 'Warning' ("The import worked, but the definition of {0} couldn't be read back: {1}" -f $target, (Get-DemoFabricErrorText -Response $response)) $retry)
        }
    }
    catch {
        return (& $result 'Warning' ("The import worked, but reading back the definition of {0} stopped: {1}" -f $target, (Get-DemoExceptionText -Exception $_.Exception)) $retry)
    }

    $definition = Get-DemoMemberValue -InputObject $body -Name 'definition'
    $parts = Get-DemoMemberValue -InputObject $definition -Name 'parts'
    $readParts = @{}
    foreach ($part in @($parts)) {
        $path = [string](Get-DemoMemberValue -InputObject $part -Name 'path')
        if ($path) {
            $readParts[$path] = [string](Get-DemoMemberValue -InputObject $part -Name 'payload')
        }
    }
    $evidence['partsReadBack'] = @($readParts.Keys | Sort-Object)

    $statuses = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($sent in @($Item.Definition['parts'])) {
        $path = [string]$sent['path']
        if (-not $readParts.ContainsKey($path)) {
            $statuses.Add('Fail')
            $notes.Add(('the part {0} is missing' -f $path))
            continue
        }
        $sentBytes = [System.Convert]::FromBase64String([string]$sent['payload'])
        try {
            $readBytes = [System.Convert]::FromBase64String($readParts[$path])
        }
        catch {
            $statuses.Add('Fail')
            $notes.Add(('the part {0} came back without a Base64 payload' -f $path))
            continue
        }
        $evidence['readSha256'] = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($readBytes)).ToLowerInvariant()
        $sameBytes = [System.Linq.Enumerable]::SequenceEqual([byte[]]$sentBytes, [byte[]]$readBytes)
        $evidence['byteIdentical'] = $sameBytes
        if ($Item.Type -eq 'KQLDashboard' -and $path -like '*.json') {
            $utf8 = [System.Text.UTF8Encoding]::new($false)
            $comparison = Compare-DemoDashboardDocument -Expected ($utf8.GetString($sentBytes) | ConvertFrom-Json -AsHashtable -Depth 64) -Actual ($utf8.GetString($readBytes) | ConvertFrom-Json -AsHashtable -Depth 64)
            $evidence['identical'] = $sameBytes -or $comparison.Identical
            $evidence['normalizedFields'] = @($comparison.NormalizedFields)
            $evidence['differences'] = @($comparison.Differences | Select-Object -First 20)
            if ($comparison.EssentialMatch) {
                $statuses.Add('Pass')
                if ($sameBytes) {
                    $notes.Add(('{0} is identical to what was sent, byte for byte' -f $path))
                }
                elseif ($comparison.Identical) {
                    # Live, 2026-10-21: Fabric returned the JSON with CRLF line endings and no final newline.
                    $notes.Add(('{0} is identical to what was sent in content; Fabric stored it with other whitespace or line endings' -f $path))
                }
                else {
                    $notes.Add(('every page, data source, parameter, query, and tile in {0} came back; Fabric normalized {1}' -f $path, ($comparison.NormalizedFields -join ', ')))
                }
            }
            else {
                $statuses.Add('Fail')
                $notes.Add(('{0} came back with {1} essential difference(s): {2}' -f $path, $comparison.Differences.Count, (($comparison.Differences | Select-Object -First 5) -join '; ')))
            }
        }
        elseif ($sameBytes) {
            $statuses.Add('Pass')
            $notes.Add(('{0} is identical to what was sent' -f $path))
        }
        else {
            $statuses.Add('Warning')
            $notes.Add(('{0} came back different from what was sent; Fabric may normalize this item type' -f $path))
        }
    }

    $status = if ($statuses -contains 'Fail') { 'Fail' } elseif ($statuses -contains 'Warning') { 'Warning' } elseif ($statuses.Count -gt 0) { 'Pass' } else { 'Fail' }
    $message = 'Read back the definition of {0} with Get Item Definition: {1}.' -f $target, ($(if ($notes.Count -gt 0) { $notes -join '; ' } else { 'no parts were sent' }))
    $remediation = switch ($status) {
        'Fail' { 'Run the import again. If the definition still comes back different, compare it with fabric/realtime/RealTimeDashboard.json and check the schema version pinned in config/versions.json.' }
        'Warning' { $retry }
        default { '' }
    }
    & $result $status $message $remediation
}

function Test-DemoFabricNotebookParameter {
    <#
    .SYNOPSIS
    Whether the workspace's copy of a notebook knows a parameter (2026-11-16): a copy imported before the parameter
    existed ignores it when a run passes it, as NB_DatabaseHub_LiveActivity from before 2026-11-13 ignores
    POSTGRES_METRICS. Reads the notebook's definition (Items - Get Item Definition, which can answer 202) and looks for
    the parameter's name. Returns Known ($true when the definition was read), Has, and Error. Never throws. Internal.
    https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z][A-Z0-9_]*$')]
        [string] $Parameter,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidateRange(10, 600)]
        [int] $TimeoutSeconds = 120
    )

    $answer = {
        param([bool] $Known, [bool] $Has, [string] $Why = '')
        [pscustomobject]@{ Known = $Known; Has = $Has; Error = $Why }
    }
    try {
        $found = Find-DemoFabricItem -WorkspaceId $WorkspaceId -DisplayName $Name -Type 'Notebook' -Token $Token
        $itemId = if ([int]$found.StatusCode -eq 200 -and @($found.Items).Count -gt 0) { [string](Get-DemoMemberValue -InputObject @($found.Items)[0] -Name 'id') } else { '' }
        if (-not $itemId) {
            return (& $answer $false $false $(if ([string]$found.Error) { [string]$found.Error } else { '{0} isn''t in the workspace' -f $Name }))
        }
        $uri = '{0}/workspaces/{1}/items/{2}/getDefinition' -f $script:FabricApiBaseUri, $WorkspaceId, $itemId
        $response = Invoke-DemoFabricRequest -Method Post -Uri $uri -Token $Token
        $body = $null
        if ([int]$response.StatusCode -eq 200) {
            $body = $response.Body
        }
        elseif ([int]$response.StatusCode -eq 202) {
            $operationId = Get-DemoFabricHeaderValue -Headers $response.Headers -Name 'x-ms-operation-id'
            $state = Wait-DemoFabricOperation -OperationId $operationId -Token $Token -TimeoutSeconds $TimeoutSeconds -RetryAfterSeconds (Get-DemoFabricRetryDelay -Headers $response.Headers -Default 5 -Maximum 30)
            if ([string]$state.Status -ne 'Succeeded') {
                return (& $answer $false $false ('reading its definition ended {0} {1}' -f $state.Status, $state.Error).Trim())
            }
            $operationResult = Invoke-DemoFabricRequest -Method Get -Uri ('{0}/operations/{1}/result' -f $script:FabricApiBaseUri, $operationId) -Token $Token
            if ([int]$operationResult.StatusCode -ne 200) {
                return (& $answer $false $false (Get-DemoFabricErrorText -Response $operationResult))
            }
            $body = $operationResult.Body
        }
        else {
            return (& $answer $false $false (Get-DemoFabricErrorText -Response $response))
        }
        $parts = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $body -Name 'definition') -Name 'parts'
        foreach ($part in @($parts)) {
            $payload = [string](Get-DemoMemberValue -InputObject $part -Name 'payload')
            if ($payload -and [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)).Contains($Parameter)) {
                return (& $answer $true $true)
            }
        }
        return (& $answer $true $false)
    }
    catch {
        return (& $answer $false $false (Protect-DemoText -Text $_.Exception.Message))
    }
}

function Get-DemoFabricContentSha256 {
    <#
    .SYNOPSIS
    One SHA-256 over the Fabric content that deploy.ps1's Fabric step publishes from this copy of the scripts: the
    notebooks (fabric/notebooks/*.ipynb), the dashboard (fabric/realtime/*.json), the history model and report
    (fabric/powerbi/*.SemanticModel and *.Report), and the Insights app's source (fabric/app, without dependencies, build
    output, Markdown, or the deploy-time files its .gitignore names). Each file counts with its path, and with LF line
    endings, so a checkout's line endings don't change it. Lowercase hex. Internal.

    .DESCRIPTION
    2026-11-16 (the merge's upgrade test): a resumed deploy.ps1 skipped the Fabric step that an earlier run had
    finished, so an upgraded environment kept the older notebooks, model, and app, and its sessions' history lost T4's
    metrics. The step records this value when it has published all of them (DbHubFabricSha256), and a resume compares it
    (Get-DemoFabricContentReopen). The control's notebook isn't in it: every run publishes that one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Root = $script:RepoRoot
    )

    $fabric = Join-Path -Path $Root -ChildPath 'fabric'
    $files = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string] $Path, [string] $Filter, [switch] $Recurse)
        if (Test-Path -LiteralPath $Path) {
            foreach ($item in @(Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Recurse:$Recurse)) {
                $files.Add($item.FullName)
            }
        }
    }
    & $add (Join-Path -Path $fabric -ChildPath 'notebooks') '*.ipynb'
    & $add (Join-Path -Path $fabric -ChildPath 'realtime') '*.json'
    foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path -Path $fabric -ChildPath 'powerbi') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.SemanticModel' -or $_.Name -like '*.Report' })) {
        & $add $folder.FullName '*' -Recurse
    }
    $app = Join-Path -Path $fabric -ChildPath 'app'
    $skipName = '^(\.gitignore|\.deployments\.json|rayfin\.config\.json|dbhub-app\.json)$|^\.env|\.(md|log)$'
    if (Test-Path -LiteralPath $app) {
        # Never into dependencies or build output, which a local npm install or build leaves there (tens of thousands of files).
        $folders = [System.Collections.Generic.Stack[string]]::new()
        $folders.Push($app)
        while ($folders.Count -gt 0) {
            $folder = $folders.Pop()
            foreach ($child in [System.IO.Directory]::EnumerateDirectories($folder)) {
                if ([System.IO.Path]::GetFileName($child) -notin 'node_modules', 'dist', '.temp') {
                    $folders.Push($child)
                }
            }
            foreach ($file in [System.IO.Directory]::EnumerateFiles($folder)) {
                if ([System.IO.Path]::GetFileName($file) -notmatch $skipName) {
                    $files.Add($file)
                }
            }
        }
    }
    $entries = foreach ($path in $files) {
        $relative = [System.IO.Path]::GetRelativePath($Root, $path) -replace '\\', '/'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n"
        $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
        [pscustomobject]@{ Path = $relative; Hash = $hash }
    }
    $lines = @($entries | Sort-Object -Property Path -Culture ([System.Globalization.CultureInfo]::InvariantCulture) -CaseSensitive | ForEach-Object { '{0} {1}' -f $_.Hash, $_.Path })
    $all = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($all)).ToLowerInvariant()
}

function Get-DemoFabricContentReopen {
    <#
    .SYNOPSIS
    Why a resumed deploy.ps1 runs the Fabric step again although an earlier run recorded it as finished: the Fabric content
    it last published in full (the state's FabricSha256) isn't what this copy of the scripts publishes (-Current,
    Get-DemoFabricContentSha256), or nothing was recorded (a run from before 2026-11-16, one whose Insights app wasn't
    deployed, or one that deployed the history model in the release's form while this copy has the kept values' one: F35,
    Test-DemoKeptFormPending). Returns that reason as a sentence, or '' when the content is the same. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $State,

        [Parameter(Mandatory)]
        [string] $Current
    )

    $recorded = ([string](Get-DemoMemberValue -InputObject $State -Name 'FabricSha256')).Trim().ToLowerInvariant()
    if ($recorded -eq $Current.ToLowerInvariant()) {
        return ''
    }
    if (-not $recorded) {
        return 'no record says it published this version''s notebooks, history model and report, dashboard, and Insights app (an earlier version, a run whose Insights app wasn''t deployed, or one that deployed the history model in the release''s form while this version has the kept values'' one).'
    }
    return ('this copy of the scripts has other notebooks, history model, report, dashboard, or Insights app than the ones it published ({0}, not {1}).' -f $Current.Substring(0, 12), $recorded.Substring(0, [System.Math]::Min(12, $recorded.Length)))
}