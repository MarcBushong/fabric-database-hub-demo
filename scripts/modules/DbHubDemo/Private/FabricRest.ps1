# Fabric REST API helpers for notebook import (Phase 12). Internal; tests mock Invoke-WebRequest and Start-Sleep.
# Every call goes to https://api.fabric.microsoft.com/v1 with the caller's token as a SecureString, so the token never
# appears in a header string, a log line, or an error message.
$script:FabricApiBaseUri = 'https://api.fabric.microsoft.com/v1'
$script:FabricTokenResource = 'https://api.fabric.microsoft.com'
$script:GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

function Get-DemoFabricHeaderValue {
    <#
    .SYNOPSIS
    Returns one response header value (case-insensitive), or an empty string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Headers,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $Headers) {
        return ''
    }
    foreach ($key in $Headers.Keys) {
        if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string](@($Headers[$key]) | Select-Object -First 1)
        }
    }
    return ''
}

function Get-DemoFabricRetryDelay {
    <#
    .SYNOPSIS
    Reads Retry-After in seconds, bounded to Minimum..Maximum, with a default when it's missing.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Headers,

        [int] $Default = 5,

        [int] $Minimum = 1,

        [int] $Maximum = 60
    )

    $value = 0
    if (-not [int]::TryParse((Get-DemoFabricHeaderValue -Headers $Headers -Name 'Retry-After'), [ref]$value)) {
        $value = $Default
    }
    return [System.Math]::Min([System.Math]::Max($value, $Minimum), $Maximum)
}

function Get-DemoFabricErrorText {
    <#
    .SYNOPSIS
    Summarizes a Fabric error response (status, errorCode, message, requestId), redacted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Response
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add(('HTTP {0}' -f $Response.StatusCode))
    foreach ($name in 'errorCode', 'message') {
        $value = Get-DemoMemberValue -InputObject $Response.Body -Name $name
        if ($value) {
            $parts.Add([string]$value)
        }
    }
    $requestId = Get-DemoMemberValue -InputObject $Response.Body -Name 'requestId'
    if ($requestId) {
        $parts.Add(('(request {0})' -f $requestId))
    }
    return (Protect-DemoText -Text ($parts -join ' '))
}

function Invoke-DemoFabricRequest {
    <#
    .SYNOPSIS
    Sends one Fabric REST API request with the caller's token and returns status, headers, and the parsed body.

    .DESCRIPTION
    Refuses any URI outside https://api.fabric.microsoft.com/v1, so the token can't be sent anywhere else.
    The token is passed as a SecureString with -Authentication Bearer. HTTP errors don't throw: the caller
    reads StatusCode. A transient failure is retried (Invoke-DemoTransientRetry: a network error, and HTTP 408, 429,
    502, 503, and 504, up to 4 attempts, after Retry-After when there is one, as the Fabric throttling guidance
    describes: https://learn.microsoft.com/rest/api/fabric/articles/throttling); with -NotIdempotent (a request that
    starts something, such as a notebook run), only a request that never reached the server, and HTTP 429. A network
    error that lasts throws, with its innermost cause (Phase 28 live finding, 2026-10-30).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post', 'Delete')]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [System.Collections.IDictionary] $Body,

        [switch] $NotIdempotent
    )

    if (-not $Uri.StartsWith($script:FabricApiBaseUri + '/', [System.StringComparison]::Ordinal)) {
        throw "Refusing to send the Fabric token outside $($script:FabricApiBaseUri)."
    }

    $request = @{
        Uri                = $Uri
        Method             = $Method
        Authentication     = 'Bearer'
        Token              = $Token
        SkipHttpErrorCheck = $true
        TimeoutSec         = 120
        ErrorAction        = 'Stop'
    }
    if ($null -ne $Body) {
        $request['Body'] = ($Body | ConvertTo-Json -Depth 32 -Compress)
        $request['ContentType'] = 'application/json; charset=utf-8'
    }

    $response = Invoke-DemoTransientRetry -Send { param([hashtable] $Call) Invoke-WebRequest @Call } -State $request -Target ([uri]$Uri).Host -NotIdempotent:$NotIdempotent
    $statusCode = [int]$response.StatusCode

    $content = [string]$response.Content
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($content)) {
        try {
            $parsed = $content | ConvertFrom-Json -Depth 64
        }
        catch {
            $parsed = $null
        }
    }
    [pscustomobject]@{
        StatusCode = $statusCode
        Headers    = $response.Headers
        Body       = $parsed
    }
}

function Find-DemoFabricItem {
    <#
    .SYNOPSIS
    Lists the items of one type in a workspace (following continuation pages) and returns those with a display name.

    .DESCRIPTION
    Items - List Items: https://learn.microsoft.com/rest/api/fabric/core/items/list-items
    Pagination: https://learn.microsoft.com/rest/api/fabric/articles/pagination
    Returns StatusCode (200 when the whole list was read), Items (the matches), and Error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [string] $DisplayName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]+$')]
        [string] $Type,

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    $baseUri = '{0}/workspaces/{1}/items?type={2}' -f $script:FabricApiBaseUri, $WorkspaceId, $Type
    $uri = $baseUri
    $matched = [System.Collections.Generic.List[object]]::new()
    for ($page = 0; $page -lt 50 -and $uri; $page++) {
        $response = Invoke-DemoFabricRequest -Method Get -Uri $uri -Token $Token
        if ($response.StatusCode -ne 200) {
            return [pscustomobject]@{ StatusCode = $response.StatusCode; Items = @(); Error = (Get-DemoFabricErrorText -Response $response) }
        }
        # Get-DemoMemberValue returns an array as one object: enumerate it directly, not through @().
        foreach ($item in (Get-DemoMemberValue -InputObject $response.Body -Name 'value')) {
            # A continuation URI can drop the type filter, so check the type too.
            $name = Get-DemoMemberValue -InputObject $item -Name 'displayName'
            $itemType = Get-DemoMemberValue -InputObject $item -Name 'type'
            if ($name -and [string]::Equals([string]$name, $DisplayName, [System.StringComparison]::OrdinalIgnoreCase) -and
                (-not $itemType -or [string]::Equals([string]$itemType, $Type, [System.StringComparison]::OrdinalIgnoreCase))) {
                $matched.Add($item)
            }
        }
        # Don't name a variable $token here: PowerShell variable names ignore case, so it would replace $Token.
        $nextUri = Get-DemoMemberValue -InputObject $response.Body -Name 'continuationUri'
        $continuation = Get-DemoMemberValue -InputObject $response.Body -Name 'continuationToken'
        $uri = if ($nextUri) {
            [string]$nextUri
        }
        elseif ($continuation) {
            '{0}&continuationToken={1}' -f $baseUri, [System.Uri]::EscapeDataString([string]$continuation)
        }
        else {
            $null
        }
    }
    if ($uri) {
        return [pscustomobject]@{ StatusCode = 0; Items = @(); Error = 'Stopped after 50 pages of results.' }
    }
    [pscustomobject]@{ StatusCode = 200; Items = $matched.ToArray(); Error = '' }
}

function Wait-DemoFabricOperation {
    <#
    .SYNOPSIS
    Polls a Fabric long-running operation until it succeeds, fails, or times out.

    .DESCRIPTION
    Follows the documented pattern: wait Retry-After seconds, then call Get Operation State
    (GET /v1/operations/{operationId}) until the status is Succeeded or Failed.
    https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation
    The operation ID comes from the x-ms-operation-id header and must be a GUID, so the polling URI is always
    built on the Fabric API host. TimeoutSeconds bounds the total time spent waiting between polls.
    Returns Status (Succeeded, Failed, or TimedOut) and Error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $OperationId,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 600,

        [int] $RetryAfterSeconds = 5
    )

    if ($OperationId -notmatch $script:GuidPattern) {
        throw 'The Fabric API returned an unexpected operation ID.'
    }
    $waited = 0
    $delay = [System.Math]::Min([System.Math]::Max($RetryAfterSeconds, 1), 30)
    while ($true) {
        Start-Sleep -Seconds $delay
        $waited += $delay
        $state = Invoke-DemoFabricRequest -Method Get -Uri ('{0}/operations/{1}' -f $script:FabricApiBaseUri, $OperationId) -Token $Token
        if ($state.StatusCode -ne 200) {
            return [pscustomobject]@{ Status = 'Failed'; Error = (Get-DemoFabricErrorText -Response $state) }
        }
        $status = [string](Get-DemoMemberValue -InputObject $state.Body -Name 'status')
        if ($status -eq 'Succeeded') {
            return [pscustomobject]@{ Status = 'Succeeded'; Error = '' }
        }
        if ($status -eq 'Failed') {
            $detail = Get-DemoMemberValue -InputObject $state.Body -Name 'error'
            $text = '{0} {1}' -f (Get-DemoMemberValue -InputObject $detail -Name 'errorCode'), (Get-DemoMemberValue -InputObject $detail -Name 'message')
            if ([string]::IsNullOrWhiteSpace($text)) {
                $text = 'no error details'
            }
            return [pscustomobject]@{ Status = 'Failed'; Error = (Protect-DemoText -Text $text.Trim()) }
        }
        if ($waited -ge $TimeoutSeconds) {
            return [pscustomobject]@{ Status = 'TimedOut'; Error = ('Last status: {0}' -f $status) }
        }
        $delay = Get-DemoFabricRetryDelay -Headers $state.Headers -Default 5 -Maximum 30
    }
}
