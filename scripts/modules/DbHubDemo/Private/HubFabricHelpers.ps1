# Adapters from the Phase 9 Hub checks (P4, P5, and the workspace capacity) to the Fabric REST helpers that
# Phase 12 owns: Get-DemoFabricToken (Public) and Invoke-DemoFabricRequest (Private/FabricRest.ps1). The Hub
# checks never get Fabric tokens or call the Fabric API any other way. Until a build includes those helpers,
# Test-DemoHubFabricRest is false and the checks report Manual action required instead of failing.

function Test-DemoHubFabricRest {
    <#
    .SYNOPSIS
    True when the Phase 12 Fabric REST helpers (Get-DemoFabricToken, Invoke-DemoFabricRequest) are loaded. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $token = Get-Command -Name 'Get-DemoFabricToken' -CommandType Function -ErrorAction SilentlyContinue
    $request = Get-Command -Name 'Invoke-DemoFabricRequest' -CommandType Function -ErrorAction SilentlyContinue
    return ($null -ne $token -and $null -ne $request)
}

function Get-DemoHubFabricAccess {
    <#
    .SYNOPSIS
    Returns the Fabric token for the Hub checks: the one the caller passed, or one from Get-DemoFabricToken
    (Phase 12). Internal.

    .DESCRIPTION
    Returns Available (the Phase 12 helpers are loaded), Token (a SecureString, or $null), and Error.
    Get-DemoFabricToken runs 'az account get-access-token --resource https://api.fabric.microsoft.com' through
    Invoke-DemoAz after the subscription guard, registers the token for redaction, and returns it only as a
    SecureString; a failure here becomes Error, never an exception.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId,

        [securestring] $Token
    )

    if (-not (Test-DemoHubFabricRest)) {
        return [pscustomobject]@{ Available = $false; Token = $null; Error = 'The Fabric REST helpers from Phase 12 (Get-DemoFabricToken and Invoke-DemoFabricRequest) aren''t in this build of the DbHubDemo module.' }
    }
    if ($null -ne $Token) {
        return [pscustomobject]@{ Available = $true; Token = $Token; Error = '' }
    }
    try {
        $fabricToken = Get-DemoFabricToken -SubscriptionId $SubscriptionId
        return [pscustomobject]@{ Available = $true; Token = $fabricToken; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Available = $true; Token = $null; Error = ('No Fabric token is available without interaction: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) }
    }
}

function Invoke-DemoHubFabricGet {
    <#
    .SYNOPSIS
    One GET through Invoke-DemoFabricRequest (Phase 12), with exceptions turned into status 0. Internal.

    .DESCRIPTION
    Invoke-DemoFabricRequest sends the SecureString token with '-Authentication Bearer' only to
    https://api.fabric.microsoft.com/v1, retries a transient failure (Invoke-DemoTransientRetry: a network error, and HTTP
    408, 429, 502, 503, and 504), and returns StatusCode, Headers, and the parsed Body without throwing on HTTP errors. A
    network error that lasts, or a refused URI, throws; this adapter returns that as StatusCode 0 with the redacted
    message and its innermost cause. Returns StatusCode, Body, and Error (empty on 2xx).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https://')]
        [string] $Uri,

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    try {
        $response = Invoke-DemoFabricRequest -Method Get -Uri $Uri -Token $Token
    }
    catch {
        return [pscustomobject]@{ StatusCode = 0; Body = $null; Error = ('No response: {0}' -f (Get-DemoExceptionText -Exception $_.Exception)) }
    }
    $code = [int]$response.StatusCode
    $errorText = ''
    if ($code -lt 200 -or $code -ge 300) {
        $detail = Get-DemoHubErrorText -Content $response.Body
        $errorText = if ($detail) { 'HTTP {0}: {1}' -f $code, $detail } else { 'HTTP {0}' -f $code }
    }
    [pscustomobject]@{ StatusCode = $code; Body = $response.Body; Error = $errorText }
}

function Read-DemoHubFabricList {
    <#
    .SYNOPSIS
    Reads every page of a Fabric REST list operation through Invoke-DemoHubFabricGet. Internal.

    .DESCRIPTION
    Fabric list responses carry 'value' and, while more pages exist, 'continuationUri' and
    'continuationToken' (https://learn.microsoft.com/rest/api/fabric/articles/pagination). The next page comes
    from continuationUri, followed only when it's HTTPS on the Fabric API host (Invoke-DemoFabricRequest
    refuses any other host too); otherwise from continuationToken. At most MaxPages pages are read. Returns
    Succeeded, StatusCode, Error, Items, Pages, and Complete.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https://')]
        [string] $Uri,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidateRange(1, 50)]
        [int] $MaxPages = 10
    )

    $apiHost = ([uri][string](Get-DemoHubSetting)['fabric']['apiBaseUrl']).Host
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $pages = 0
    $refused = $false
    while ($next -and $pages -lt $MaxPages) {
        $pages++
        $response = Invoke-DemoHubFabricGet -Uri $next -Token $Token
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            return [pscustomobject]@{ Succeeded = $false; StatusCode = $response.StatusCode; Error = $response.Error; Items = $items.ToArray(); Pages = $pages; Complete = $false }
        }
        # Assign before enumerating: Get-DemoMemberValue returns an array as one object.
        $value = Get-DemoMemberValue -InputObject $response.Body -Name 'value'
        foreach ($item in @($value)) {
            if ($null -ne $item) {
                $items.Add($item)
            }
        }
        $continuationUri = [string](Get-DemoMemberValue -InputObject $response.Body -Name 'continuationUri')
        $continuation = [string](Get-DemoMemberValue -InputObject $response.Body -Name 'continuationToken')
        $next = ''
        if ($continuationUri) {
            $candidate = $null
            if ([uri]::TryCreate($continuationUri, [System.UriKind]::Absolute, [ref]$candidate) -and $candidate.Scheme -eq 'https' -and $candidate.Host -ieq $apiHost) {
                $next = $candidate.OriginalString
            }
            else {
                $refused = $true
                Write-DemoLog -Level Warning -Message 'A Fabric list response pointed to another host; the remaining pages were not read.'
            }
        }
        elseif ($continuation) {
            $escaped = if ($continuation -match '^[A-Za-z0-9%._~-]+$') { $continuation } else { [uri]::EscapeDataString($continuation) }
            $separator = if ($Uri.Contains('?')) { '&' } else { '?' }
            $next = '{0}{1}continuationToken={2}' -f $Uri, $separator, $escaped
        }
    }

    [pscustomobject]@{ Succeeded = $true; StatusCode = 200; Error = ''; Items = $items.ToArray(); Pages = $pages; Complete = -not $next -and -not $refused }
}
