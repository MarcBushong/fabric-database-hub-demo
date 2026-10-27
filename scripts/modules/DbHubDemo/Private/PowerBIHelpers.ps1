# Power BI history report helpers (Phase 19). Internal; tests mock Invoke-WebRequest and Start-Sleep.
# Power BI REST calls go only to https://api.powerbi.com/v1.0/myorg, with the caller's token as a SecureString, so
# the token never appears in a header string, a log line, or an error message.
$script:PowerBIApiBaseUri = 'https://api.powerbi.com/v1.0/myorg'
$script:PowerBITokenResource = 'https://analysis.windows.net/powerbi/api'

function Invoke-DemoPowerBIRequest {
    <#
    .SYNOPSIS
    Sends one Power BI REST API request with the caller's token and returns status, headers, and the parsed body.

    .DESCRIPTION
    Refuses any URI outside https://api.powerbi.com/v1.0/myorg, so the token can't be sent anywhere else. HTTP errors
    don't throw: the caller reads StatusCode. HTTP 429 is retried after Retry-After (at most 60 seconds, 4 attempts).
    https://learn.microsoft.com/rest/api/power-bi/
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post')]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [System.Collections.IDictionary] $Body
    )

    if (-not $Uri.StartsWith($script:PowerBIApiBaseUri + '/', [System.StringComparison]::Ordinal)) {
        throw "Refusing to send the Power BI token outside $($script:PowerBIApiBaseUri)."
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

    $attempt = 0
    while ($true) {
        $attempt++
        $response = Invoke-WebRequest @request
        $statusCode = [int]$response.StatusCode
        if ($statusCode -eq 429 -and $attempt -lt 4) {
            Start-Sleep -Seconds (Get-DemoFabricRetryDelay -Headers $response.Headers -Default 10)
            continue
        }
        break
    }

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

function Get-DemoPowerBIErrorText {
    <#
    .SYNOPSIS
    Summarizes a Power BI REST error response (status, code, message, and detail values), redacted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Response
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add(('HTTP {0}' -f $Response.StatusCode))
    $errorBody = Get-DemoMemberValue -InputObject $Response.Body -Name 'error'
    foreach ($name in 'code', 'message') {
        $value = Get-DemoMemberValue -InputObject $errorBody -Name $name
        if ($value) {
            $parts.Add([string]$value)
        }
    }
    $pbiError = Get-DemoMemberValue -InputObject $errorBody -Name 'pbi.error'
    # Get-DemoMemberValue returns an array as one object: assign it, then enumerate the variable.
    $details = Get-DemoMemberValue -InputObject $pbiError -Name 'details'
    foreach ($detail in @($details)) {
        $value = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $detail -Name 'detail') -Name 'value'
        if ($value) {
            $parts.Add([string]$value)
        }
    }
    return (Protect-DemoText -Text ($parts -join ' '))
}

function ConvertTo-DemoCheckIdPart {
    <#
    .SYNOPSIS
    Turns a display name into a check ID segment: upper case, letters and digits, single underscores.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $part = ($Name.ToUpperInvariant() -replace '%', ' PCT ' -replace '[^A-Z0-9]+', '_').Trim('_')
    if (-not $part) {
        throw "No check ID segment can be made from '$Name'."
    }
    return $part
}

function Get-DemoTmdlMeasure {
    <#
    .SYNOPSIS
    Lists the measures in a TMDL definition folder: table, name, and whether it's hidden.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $DefinitionPath
    )

    $unquote = {
        param([string] $Text)
        $Text = $Text.Trim()
        if ($Text.StartsWith("'") -and $Text.EndsWith("'")) {
            return $Text.Substring(1, $Text.Length - 2).Replace("''", "'")
        }
        return $Text
    }
    $name = "('(?:[^']|'')+'|[^\s='][^\s=]*)"
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path -Path $DefinitionPath -ChildPath 'tables') -Filter '*.tmdl' -File | Sort-Object -Property Name) {
        $table = $null
        $current = $null
        foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
            if ($line -match "^table\s+$name\s*$") {
                $table = & $unquote $Matches[1]
                continue
            }
            if ($line -match "^ {4}measure\s+$name\s*=") {
                $current = [pscustomobject]@{ Table = $table; Name = (& $unquote $Matches[1]); IsHidden = $false }
                $current
                continue
            }
            if ($line -match '^ {4}\S') {
                $current = $null
            }
            elseif ($null -ne $current -and $line -match '^ {8}isHidden\s*$') {
                $current.IsHidden = $true
            }
        }
    }
}

function ConvertTo-DemoDaxName {
    <#
    .SYNOPSIS
    Quotes a table and a column or measure for DAX: 'Table'[Name].
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Table,

        [Parameter(Mandatory)]
        [string] $Name
    )

    return ("'{0}'[{1}]" -f $Table.Replace("'", "''"), $Name.Replace(']', ']]'))
}

function Invoke-DemoDaxQuery {
    <#
    .SYNOPSIS
    Runs one DAX query through Execute Queries In Group and returns StatusCode, Rows, and Error.

    .DESCRIPTION
    POST /v1.0/myorg/groups/{groupId}/datasets/{datasetId}/executeQueries with one query and includeNulls, so a blank
    value comes back as null. A query error (HTTP 400, or an error inside the result) returns no rows and the error
    text. https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [string] $SemanticModelId,

        [Parameter(Mandatory)]
        [string] $Query,

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    $uri = '{0}/groups/{1}/datasets/{2}/executeQueries' -f $script:PowerBIApiBaseUri, $WorkspaceId, $SemanticModelId
    $body = [ordered]@{
        queries            = @([ordered]@{ query = $Query })
        serializerSettings = [ordered]@{ includeNulls = $true }
    }
    $response = Invoke-DemoPowerBIRequest -Method Post -Uri $uri -Body $body -Token $Token
    if ($response.StatusCode -ne 200) {
        return [pscustomobject]@{ StatusCode = $response.StatusCode; Rows = @(); Error = (Get-DemoPowerBIErrorText -Response $response) }
    }
    $results = Get-DemoMemberValue -InputObject $response.Body -Name 'results'
    $result = @($results) | Select-Object -First 1
    $resultError = Get-DemoMemberValue -InputObject $result -Name 'error'
    if ($resultError) {
        $text = '{0} {1}' -f (Get-DemoMemberValue -InputObject $resultError -Name 'code'), (Get-DemoMemberValue -InputObject $resultError -Name 'message')
        return [pscustomobject]@{ StatusCode = 400; Rows = @(); Error = (Protect-DemoText -Text $text.Trim()) }
    }
    $tables = Get-DemoMemberValue -InputObject $result -Name 'tables'
    $table = @($tables) | Select-Object -First 1
    $rows = Get-DemoMemberValue -InputObject $table -Name 'rows'
    [pscustomobject]@{ StatusCode = 200; Rows = @($rows | Where-Object { $null -ne $_ }); Error = '' }
}

function ConvertTo-DemoDefinitionPart {
    <#
    .SYNOPSIS
    Builds the definition object Import-DemoFabricItem sends: parts (path, InlineBase64 payload) from a list of
    relative paths and their bytes, with the SHA-256 and size of the whole set.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary] $Files
    )

    $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $size = 0
    $parts = foreach ($path in $Files.Keys) {
        [byte[]]$bytes = $Files[$path]
        $hash.AppendData([System.Text.Encoding]::UTF8.GetBytes([string]$path + [char]0))
        $hash.AppendData($bytes)
        $size += $bytes.Length
        [ordered]@{ path = [string]$path; payload = [System.Convert]::ToBase64String($bytes); payloadType = 'InlineBase64' }
    }
    [pscustomobject]@{
        Parts     = @($parts)
        Sha256    = [System.Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
        SizeBytes = $size
    }
}
