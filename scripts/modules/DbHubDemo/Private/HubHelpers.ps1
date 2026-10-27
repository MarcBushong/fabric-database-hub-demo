function Get-DemoHubSetting {
    <#
    .SYNOPSIS
    Returns the databaseHub block of config/versions.json: the documented endpoints, API versions, token
    audiences, and names the Hub validators use (Phase 9). Internal.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $path = Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json'
    $versions = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    $settings = $versions['databaseHub']
    if ($null -eq $settings) {
        throw 'config/versions.json has no databaseHub block.'
    }
    return $settings
}

function Get-DemoHubUtcNow {
    # The current UTC time. Internal; a separate function so tests can pin the clock.
    [CmdletBinding()]
    [OutputType([datetime])]
    param()

    return [System.DateTime]::UtcNow
}

function ConvertTo-DemoUtcDateTime {
    <#
    .SYNOPSIS
    Converts a value to a UTC DateTime, or returns $null. Internal.

    .DESCRIPTION
    Accepts DateTime (any Kind), DateTimeOffset, and ISO 8601 strings. Values without a zone are UTC, as every
    telemetry and Resource Graph timestamp is. 0001-01-01T00:00:00Z means "not set" in the telemetry (rule 8
    of the telemetry doc) and returns $null, as do empty and unparseable values.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return $null
    }
    $moment = $null
    if ($Value -is [datetime]) {
        $moment = $Value
    }
    elseif ($Value -is [System.DateTimeOffset]) {
        $moment = $Value.UtcDateTime
    }
    else {
        $text = ([string]$Value).Trim()
        if (-not $text) {
            return $null
        }
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        if (-not [datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return $null
        }
        $moment = $parsed
    }

    $utc = switch ($moment.Kind) {
        'Local' { $moment.ToUniversalTime() }
        'Unspecified' { [datetime]::SpecifyKind($moment, [System.DateTimeKind]::Utc) }
        default { $moment }
    }
    if ($utc.Year -le 1) {
        return $null
    }
    return $utc
}

function ConvertTo-DemoKqlLiteral {
    <#
    .SYNOPSIS
    Renders a value as a KQL literal for a template parameter. Internal.

    .DESCRIPTION
    String: a single-quoted literal with backslash and quote escaped; control characters are refused.
    StringArray: dynamic([...]) of string literals. Timespan: whole minutes ('60m') or seconds ('90s').
    Datetime: datetime(<ISO 8601 UTC>). Only these literal forms reach a query, so a parameter value can't
    change the query's structure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [object] $Value,

        [Parameter(Mandatory)]
        [ValidateSet('String', 'StringArray', 'Timespan', 'Datetime')]
        [string] $Type
    )

    switch ($Type) {
        'String' {
            $text = [string]$Value
            if ($text -match '[\x00-\x1F\x7F]') {
                throw 'A KQL string parameter contains a control character.'
            }
            return "'" + $text.Replace('\', '\\').Replace("'", "\'") + "'"
        }
        'StringArray' {
            $items = @(@($Value) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-DemoKqlLiteral -Value ([string]$_) -Type String })
            return 'dynamic([' + ($items -join ', ') + '])'
        }
        'Timespan' {
            $span = [timespan]$Value
            if ($span -le [timespan]::Zero) {
                throw 'A KQL timespan parameter must be positive.'
            }
            $seconds = [long][System.Math]::Ceiling($span.TotalSeconds)
            if ($seconds % 60 -eq 0) {
                return ('{0}m' -f [long]($seconds / 60))
            }
            return ('{0}s' -f $seconds)
        }
        default {
            $utc = ConvertTo-DemoUtcDateTime -Value $Value
            if ($null -eq $utc) {
                throw 'A KQL datetime parameter is empty or not a date and time.'
            }
            return ('datetime({0})' -f $utc.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [System.Globalization.CultureInfo]::InvariantCulture))
        }
    }
}

function Format-DemoKqlTemplate {
    <#
    .SYNOPSIS
    Renders a KQL template from scripts/modules/DbHubDemo/Kql. Internal.

    .DESCRIPTION
    Removes the comment lines (they cite the Learn page each query follows) and blank lines, then replaces
    every {{Name}} placeholder in one pass with a value already rendered by ConvertTo-DemoKqlLiteral (or a
    fixed expression). Every placeholder needs a value and every value needs a placeholder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]+\.[A-Za-z]+$')]
        [string] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Parameters
    )

    $path = Join-Path -Path $script:ModuleRoot -ChildPath ('Kql/{0}.kql' -f $Name)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The KQL template $Name doesn't exist in scripts/modules/DbHubDemo/Kql."
    }
    $lines = Get-Content -LiteralPath $path
    $body = (@($lines | Where-Object { $_ -notmatch '^\s*//' -and -not [string]::IsNullOrWhiteSpace($_) }) -join "`n")

    $pattern = '\{\{([A-Za-z]+)\}\}'
    $placeholders = @([regex]::Matches($body, $pattern) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $missing = @($placeholders | Where-Object { -not $Parameters.Contains($_) })
    if ($missing.Count -gt 0) {
        throw ('The KQL template {0} needs a value for: {1}.' -f $Name, ($missing -join ', '))
    }
    $unknown = @($Parameters.Keys | Where-Object { $_ -notin $placeholders })
    if ($unknown.Count -gt 0) {
        throw ('The KQL template {0} has no placeholder for: {1}.' -f $Name, ($unknown -join ', '))
    }

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        [string]$Parameters[$match.Groups[1].Value]
    }
    return [regex]::Replace($body, $pattern, $evaluator)
}

function Get-DemoHubToken {
    <#
    .SYNOPSIS
    Gets a token for the telemetry endpoint's audience from the signed-in Azure CLI, registers it as a secret,
    and returns it as a SecureString. Internal.

    .DESCRIPTION
    Gets the token with Get-DemoAccessToken ('az account get-access-token --resource <audience>
    --subscription <id>' through Invoke-DemoAz), so the configured subscription's account and tenant are
    used whatever the default subscription is, the token's tid and oid claims are checked against the
    context the subscription guard validated, and nothing signs in. The token is registered with
    Register-DemoSecret before anything else happens, so every log line and result redacts it, and it's
    returned only as a SecureString that Invoke-DemoHubHttp sends with '-Authentication Bearer', the same
    pattern as Get-DemoFabricToken. Fabric tokens come from Get-DemoFabricToken (Phase 12), not from here.
    Returns Token and Error; on failure, Token is $null.
    https://learn.microsoft.com/cli/azure/account#az-account-get-access-token
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidatePattern('^https://[A-Za-z0-9.-]+/?$')]
        [string] $Resource
    )

    $issued = Get-DemoAccessToken -SubscriptionId $SubscriptionId -Resource $Resource
    [pscustomobject]@{ Token = $issued.Token; Error = [string]$issued.Error }
}

function Invoke-DemoHubHttp {
    <#
    .SYNOPSIS
    Sends one HTTPS request to the telemetry endpoint with a bearer token, which travels only in the
    Authorization header. Internal; tests mock it.

    .DESCRIPTION
    The token is a SecureString passed with '-Authentication Bearer' to Invoke-RestMethod, so it never
    appears in a header string, the URI, the body, a log line, or an error message. A response with an error
    status doesn't throw: it's returned with its status code and body. A network error or timeout returns
    status code 0 and the redacted error. Returns StatusCode, Content, RetryAfterSeconds (from a Retry-After
    header), and Error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post')]
        [string] $Method,

        [Parameter(Mandatory)]
        [ValidatePattern('^https://')]
        [string] $Uri,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [AllowEmptyString()]
        [string] $Body = '',

        [ValidateRange(5, 600)]
        [int] $TimeoutSec = 120
    )

    $statusCode = 0
    $responseHeaders = $null
    $content = $null
    $errorText = ''
    $request = @{
        Method                  = $Method
        Uri                     = $Uri
        Authentication          = 'Bearer'
        Token                   = $Token
        Headers                 = @{ Accept = 'application/json'; 'x-ms-app' = 'DbHubDemo'; 'x-ms-client-request-id' = 'DbHubDemo;' + [guid]::NewGuid().ToString() }
        TimeoutSec              = $TimeoutSec
        SkipHttpErrorCheck      = $true
        StatusCodeVariable      = 'statusCode'
        ResponseHeadersVariable = 'responseHeaders'
        ErrorAction             = 'Stop'
    }
    if ($Body) {
        $request['Body'] = $Body
        $request['ContentType'] = 'application/json; charset=utf-8'
    }
    try {
        $content = Invoke-RestMethod @request
    }
    catch {
        $statusCode = 0
        $errorText = Protect-DemoText -Text $_.Exception.Message
    }
    finally {
        $request.Clear()
    }

    $retryAfter = $null
    if ($responseHeaders -is [System.Collections.IDictionary]) {
        foreach ($key in $responseHeaders.Keys) {
            if ([string]$key -ieq 'Retry-After') {
                $raw = [string](@($responseHeaders[$key]) | Select-Object -First 1)
                $seconds = 0
                if ([int]::TryParse($raw, [ref]$seconds)) {
                    $retryAfter = [System.Math]::Max(0, $seconds)
                }
            }
        }
    }

    [pscustomobject]@{
        StatusCode        = [int]$statusCode
        Content           = $content
        RetryAfterSeconds = $retryAfter
        Error             = $errorText
    }
}

function Get-DemoHubErrorText {
    # The readable part of an error response body (Kusto, Fabric, or ARM shape), redacted and shortened. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Content
    )

    if ($null -eq $Content) {
        return ''
    }
    if ($Content -is [string]) {
        $text = $Content
    }
    else {
        $inner = Get-DemoMemberValue -InputObject $Content -Name 'error'
        $source = if ($null -ne $inner -and $inner -isnot [string]) { $inner } else { $Content }
        $parts = foreach ($name in 'errorCode', 'code', 'message', '@message') {
            $value = Get-DemoMemberValue -InputObject $source -Name $name
            if ($value -is [string] -or $value -is [System.ValueType]) {
                [string]$value
            }
        }
        $text = if (@($parts).Count -gt 0) { (@($parts) | Select-Object -Unique) -join ': ' } elseif ($inner -is [string]) { $inner } else { '' }
    }
    $text = (Protect-DemoText -Text ([string]$text)).Trim()
    if ($text.Length -gt 400) {
        $text = $text.Substring(0, 400) + '...'
    }
    return $text
}

function Invoke-DemoHubRestCall {
    <#
    .SYNOPSIS
    Calls the telemetry REST endpoint with a token for its audience, with a timeout and bounded retries.
    Internal.

    .DESCRIPTION
    Fabric calls don't come here: they use Get-DemoFabricToken and Invoke-DemoFabricRequest (Phase 12)
    through Private/HubFabricHelpers.ps1. This one gets the token with Get-DemoHubToken (registered as a
    secret, kept as a SecureString) and sends it only as a bearer token through Invoke-DemoHubHttp. Retries
    status 0 (network error or timeout), 408, 429, 502, 503, 504, and 520 up to MaxAttempts, honoring
    Retry-After up to MaxRetryDelaySeconds and otherwise backing off exponentially. A 401 gets one fresh token
    and one more try, because Azure CLI tokens last 5 to 60 minutes. Other errors aren't retried. Returns
    Succeeded, StatusCode, ErrorKind, Error, Content, and Attempts. ErrorKind is one of Token, Network,
    BadRequest, Unauthorized, Forbidden, NotFound, Throttled, ServerError, Unavailable, or HttpError.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Resource,

        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post')]
        [string] $Method,

        [Parameter(Mandatory)]
        [ValidatePattern('^https://')]
        [string] $Uri,

        [AllowEmptyString()]
        [string] $Body = '',

        [ValidateRange(5, 600)]
        [int] $TimeoutSec = 120,

        [ValidateRange(1, 6)]
        [int] $MaxAttempts = 3,

        [ValidateRange(1, 300)]
        [int] $MaxRetryDelaySeconds = 60
    )

    function ConvertTo-CallResult([bool] $Succeeded, [int] $StatusCode, [string] $ErrorKind, [string] $ErrorText, [object] $Content, [int] $Attempts) {
        [pscustomobject]@{
            Succeeded  = $Succeeded
            StatusCode = $StatusCode
            ErrorKind  = $ErrorKind
            Error      = $ErrorText
            Content    = $Content
            Attempts   = $Attempts
        }
    }

    $token = Get-DemoHubToken -SubscriptionId $SubscriptionId -Resource $Resource
    if (-not $token.Token) {
        return ConvertTo-CallResult $false 0 'Token' $token.Error $null 0
    }

    $retryable = @(0, 408, 429, 502, 503, 504, 520)
    $refreshed = $false
    $attempt = 0
    while ($true) {
        $attempt++
        $response = Invoke-DemoHubHttp -Method $Method -Uri $Uri -Token $token.Token -Body $Body -TimeoutSec $TimeoutSec
        $code = [int]$response.StatusCode
        if ($code -ge 200 -and $code -lt 300) {
            return ConvertTo-CallResult $true $code '' '' $response.Content $attempt
        }

        $detail = if ($code -eq 0) { $response.Error } else { Get-DemoHubErrorText -Content $response.Content }
        if ($code -eq 401 -and -not $refreshed) {
            $refreshed = $true
            $token = Get-DemoHubToken -SubscriptionId $SubscriptionId -Resource $Resource
            if (-not $token.Token) {
                return ConvertTo-CallResult $false 401 'Token' $token.Error $null $attempt
            }
            continue
        }
        if ($code -in $retryable -and $attempt -lt $MaxAttempts) {
            $delay = if ($null -ne $response.RetryAfterSeconds) { [int]$response.RetryAfterSeconds } else { [int][System.Math]::Pow(2, $attempt) * 2 }
            $delay = [System.Math]::Min([System.Math]::Max($delay, 1), $MaxRetryDelaySeconds)
            Write-DemoLog -Level Warning -Message ('{0} returned {1}; retry {2} of {3} in {4} seconds.' -f ([uri]$Uri).Host, $(if ($code -eq 0) { 'no response' } else { "HTTP $code" }), $attempt, ($MaxAttempts - 1), $delay)
            Start-Sleep -Seconds $delay
            continue
        }

        $kind = switch ($code) {
            0 { 'Network' }
            400 { 'BadRequest' }
            401 { 'Unauthorized' }
            403 { 'Forbidden' }
            404 { 'NotFound' }
            429 { 'Throttled' }
            500 { 'ServerError' }
            { $_ -in 502, 503, 504, 520 } { 'Unavailable' }
            default { 'HttpError' }
        }
        $message = if ($code -eq 0) { 'No response: {0}' -f $detail } elseif ($detail) { 'HTTP {0}: {1}' -f $code, $detail } else { 'HTTP {0} with an empty body.' -f $code }
        return ConvertTo-CallResult $false $code $kind (Protect-DemoText -Text $message) $response.Content $attempt
    }
}

function ConvertFrom-DemoKustoV1Response {
    <#
    .SYNOPSIS
    Turns a Kusto v1 query response into objects keyed by column name. Internal.

    .DESCRIPTION
    The telemetry endpoint answers with Kusto v1 JSON: Tables[0].Columns (ColumnName, DataType, ColumnType)
    and Tables[0].Rows (positional arrays); later tables hold query status and are ignored
    (https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry).
    Values are mapped by column name, never by position. datetime columns become UTC DateTime values, and
    0001-01-01T00:00:00Z ("not set") becomes $null. Kusto injects error indicators into the stream when a
    query fails after it started (https://learn.microsoft.com/kusto/api/rest/response); a row that isn't an
    array, or an Exceptions property, is reported in Exceptions with PartialFailure set. A body without
    Tables or Columns, or a row whose length doesn't match the columns, throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Content
    )

    $document = $Content
    if ($document -is [string]) {
        if ([string]::IsNullOrWhiteSpace($document)) {
            throw 'The telemetry endpoint returned an empty body.'
        }
        try {
            $document = $document | ConvertFrom-Json -Depth 64
        }
        catch {
            throw "The telemetry endpoint returned a body that isn't JSON."
        }
    }
    $tables = Get-DemoMemberValue -InputObject $document -Name 'Tables'
    if ($null -eq $tables -or @($tables).Count -eq 0) {
        throw 'The telemetry response has no Tables; expected Kusto v1 JSON with Tables[0].Columns and Tables[0].Rows.'
    }
    $table = @($tables)[0]
    # Assign before wrapping: Get-DemoMemberValue returns an array as one object, and @() around the call
    # would nest it.
    $columnValue = Get-DemoMemberValue -InputObject $table -Name 'Columns'
    $columns = @($columnValue | Where-Object { $null -ne $_ })
    $rawRows = Get-DemoMemberValue -InputObject $table -Name 'Rows'
    if ($columns.Count -eq 0) {
        throw 'The first table in the telemetry response has no Columns.'
    }

    $names = [System.Collections.Generic.List[string]]::new()
    $types = [System.Collections.Generic.List[string]]::new()
    foreach ($column in $columns) {
        $name = [string](Get-DemoMemberValue -InputObject $column -Name 'ColumnName')
        if (-not $name) {
            throw 'A column in the telemetry response has no ColumnName.'
        }
        $type = [string](Get-DemoMemberValue -InputObject $column -Name 'ColumnType')
        if (-not $type) {
            $type = [string](Get-DemoMemberValue -InputObject $column -Name 'DataType')
        }
        $names.Add($name)
        $types.Add($type.ToLowerInvariant())
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $exceptions = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in @($rawRows)) {
        if ($null -eq $raw) {
            continue
        }
        if ($raw -is [System.Collections.IList]) {
            if ($raw.Count -ne $names.Count) {
                throw ('A telemetry row has {0} values for {1} columns.' -f $raw.Count, $names.Count)
            }
            $record = [ordered]@{}
            for ($index = 0; $index -lt $names.Count; $index++) {
                $value = $raw[$index]
                if ($types[$index] -in 'datetime', 'date') {
                    $value = ConvertTo-DemoUtcDateTime -Value $value
                }
                $record[$names[$index]] = $value
            }
            $rows.Add([pscustomobject]$record)
            continue
        }
        $indicator = Get-DemoMemberValue -InputObject $raw -Name 'Exceptions'
        if ($null -ne $indicator) {
            foreach ($item in @($indicator)) {
                $exceptions.Add((Protect-DemoText -Text ([string]$item)))
            }
        }
        else {
            $exceptions.Add('The response stream contained a value that is not a row.')
        }
    }
    $tableExceptions = Get-DemoMemberValue -InputObject $table -Name 'Exceptions'
    foreach ($item in @($tableExceptions | Where-Object { $null -ne $_ })) {
        $exceptions.Add((Protect-DemoText -Text ([string]$item)))
    }

    [pscustomobject]@{
        Columns        = $names.ToArray()
        Rows           = $rows.ToArray()
        PartialFailure = $exceptions.Count -gt 0
        Exceptions     = $exceptions.ToArray()
    }
}

function Invoke-DemoHubResourceGraph {
    <#
    .SYNOPSIS
    Runs one Azure Resource Graph query for the configured subscription. Internal.

    .DESCRIPTION
    POST https://management.azure.com/providers/Microsoft.ResourceGraph/resources (API version in
    config/versions.json) through Invoke-DemoRestRequest, with an Azure Resource Manager token that
    Get-DemoAccessToken verified for the configured tenant and caller. Not 'az rest': the URL has no
    subscription, so the Azure CLI would take the token from its default account, and Resource Graph refused
    such a query with AccessDenied while that account was in another tenant (live finding, 2026-10-21).
    Returns Succeeded, Error, Rows (the data array, objectArray format), and Truncated.
    https://learn.microsoft.com/rest/api/azureresourcegraph/resourcegraph/resources/resources
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Query
    )

    $graph = (Get-DemoHubSetting)['resourceGraph']
    $url = '{0}?api-version={1}' -f $graph['url'], $graph['apiVersion']
    $body = [ordered]@{
        subscriptions = @($SubscriptionId)
        query         = $Query
        options       = [ordered]@{ resultFormat = 'objectArray'; '$top' = 1000 }
    }
    $result = Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'POST' -Uri $url -Body ($body | ConvertTo-Json -Depth 5 -Compress)

    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Succeeded = $false; Error = (Protect-DemoText -Text ([string]$result.StdErr).Trim()); Rows = @(); Truncated = $false }
    }
    try {
        $response = ([string]$result.StdOut) | ConvertFrom-Json -Depth 64
    }
    catch {
        return [pscustomobject]@{ Succeeded = $false; Error = "Resource Graph returned a body that isn't JSON."; Rows = @(); Truncated = $false }
    }
    $data = Get-DemoMemberValue -InputObject $response -Name 'data'
    [pscustomobject]@{
        Succeeded = $true
        Error     = ''
        Rows      = @(@($data) | Where-Object { $null -ne $_ })
        Truncated = [string](Get-DemoMemberValue -InputObject $response -Name 'resultTruncated') -ieq 'true'
    }
}

function Resolve-DemoHubTarget {
    <#
    .SYNOPSIS
    Builds the Azure Resource Manager IDs that key each target's telemetry. Internal.

    .DESCRIPTION
    The names are fixed by the architecture: T1 is the VM sqlvm01 (telemetry ResourceType virtualMachines),
    T2 is the Arc machine arcsql01 (machines), and T3 is the database ContosoCare on the logical server
    azuresql01-<deploymentId> (servers/databases), all in rg-<prefix>-<environment>. With -NeedT3 and no
    -DeploymentId, the deploymentId comes from the resource group's deploymentId tag ('az group show'
    through Invoke-DemoAz), which survives 'stop-demo.ps1 -RemoveT3'; T3 keeps the same ID when it's
    recreated, so earlier sessions stay queryable by ResourceID within the retention window.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $DeploymentId = '',

        [switch] $NeedT3
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroup = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $groupId = '/subscriptions/{0}/resourceGroups/{1}' -f $subscriptionId, $resourceGroup

    $t3Error = ''
    if ($NeedT3 -and -not $DeploymentId) {
        $tag = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'show', '--name', $resourceGroup, '--query', 'tags.deploymentId', '--output', 'tsv') -AllowFailure
        if ($tag.ExitCode -eq 0) {
            $DeploymentId = ([string]$tag.StdOut).Trim()
            if (-not $DeploymentId) {
                $t3Error = "The resource group $resourceGroup has no deploymentId tag, so T3's server name (azuresql01-<deploymentId>) is unknown. Pass -DeploymentId."
            }
        }
        else {
            $t3Error = "The resource group $resourceGroup couldn't be read, so T3's server name (azuresql01-<deploymentId>) is unknown: $(Protect-DemoText -Text ([string]$tag.StdErr).Trim())"
        }
    }
    elseif (-not $NeedT3 -and -not $DeploymentId) {
        $t3Error = 'T3 was not resolved.'
    }
    if ($DeploymentId -and $DeploymentId -notmatch '^[a-z0-9]{6}$') {
        $t3Error = "The deploymentId '$DeploymentId' isn't six lowercase letters and digits."
        $DeploymentId = ''
    }

    $serverName = if ($DeploymentId) { 'azuresql01-' + $DeploymentId } else { '' }
    $targets = [ordered]@{
        T1 = [pscustomobject]@{
            Target       = 'T1'
            Name         = 'sqlvm01'
            ResourceId   = '{0}/providers/Microsoft.Compute/virtualMachines/sqlvm01' -f $groupId
            ResourceType = 'virtualMachines'
            ServerName   = ''
            Error        = ''
        }
        T2 = [pscustomobject]@{
            Target       = 'T2'
            Name         = 'arcsql01'
            ResourceId   = '{0}/providers/Microsoft.HybridCompute/machines/arcsql01' -f $groupId
            ResourceType = 'machines'
            ServerName   = ''
            Error        = ''
        }
        T3 = [pscustomobject]@{
            Target       = 'T3'
            Name         = if ($serverName) { '{0}/ContosoCare' -f $serverName } else { 'azuresql01-<deploymentId>/ContosoCare' }
            ResourceId   = if ($serverName) { '{0}/providers/Microsoft.Sql/servers/{1}/databases/ContosoCare' -f $groupId, $serverName } else { '' }
            ResourceType = 'servers/databases'
            ServerName   = $serverName
            Error        = if ($serverName) { '' } else { $t3Error }
        }
    }

    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceGroup  = $resourceGroup
        DeploymentId   = $DeploymentId
        Targets        = $targets
    }
}

function Get-DemoTelemetryState {
    <#
    .SYNOPSIS
    Applies the freshness rule to one target's telemetry summary. Internal.

    .DESCRIPTION
    Lag is the time from the newest sample to now, in minutes (one decimal, never negative). Rows with a lag
    up to FreshMinutes: Pass. Older rows: Warning, because the target stopped reporting (stopped or paused)
    or the pipeline is late; telemetry takes 3 to 15 minutes to appear. No rows: Fail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [long] $Rows,

        [AllowNull()]
        [object] $LastSampleUtc,

        [Parameter(Mandatory)]
        [datetime] $NowUtc,

        [Parameter(Mandatory)]
        [ValidateRange(1, 10080)]
        [int] $FreshMinutes
    )

    $last = ConvertTo-DemoUtcDateTime -Value $LastSampleUtc
    if ($Rows -le 0 -or $null -eq $last) {
        return [pscustomobject]@{ Status = 'Fail'; LagMinutes = $null; Fresh = $false }
    }
    $lag = [System.Math]::Round(($NowUtc - $last).TotalMinutes, 1)
    if ($lag -lt 0) {
        $lag = 0.0
    }
    $fresh = $lag -le $FreshMinutes
    [pscustomobject]@{ Status = $(if ($fresh) { 'Pass' } else { 'Warning' }); LagMinutes = $lag; Fresh = $fresh }
}

function Get-DemoHubTelemetryDetail {
    <#
    .SYNOPSIS
    Collects the -Detail evidence for Test-DemoHubTelemetry: tables with rows, wait seconds per category, and
    gauge and rate counters per target. Internal; a failed query only adds a note to the evidence.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [object[]] $Target,

        [Parameter(Mandatory)]
        [int] $LookbackMinutes
    )

    $ids = @($Target | ForEach-Object { $_.ResourceId })
    $details = @{}
    foreach ($descriptor in $Target) {
        $details[$descriptor.Target] = [ordered]@{}
    }

    foreach ($name in 'TableSummary', 'WaitCategoryDeltas', 'CounterGauges', 'CounterRates') {
        $query = Invoke-DemoHubTelemetryQuery -SubscriptionId $SubscriptionId -Query (Get-DemoHubTelemetryKql -Name $name -ResourceId $ids -LookbackMinutes $LookbackMinutes)
        foreach ($descriptor in $Target) {
            $evidence = $details[$descriptor.Target]
            if (-not $query.Succeeded) {
                $evidence[('{0}{1}Error' -f $name.Substring(0, 1).ToLowerInvariant(), $name.Substring(1))] = $query.Error
                continue
            }
            $rows = @($query.Rows | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'ResourceID') -ieq $descriptor.ResourceId })
            switch ($name) {
                'TableSummary' {
                    $evidence['tables'] = @($rows | ForEach-Object { [ordered]@{ table = [string](Get-DemoMemberValue -InputObject $_ -Name 'TableName'); rows = [long](Get-DemoMemberValue -InputObject $_ -Name 'Rows') } })
                }
                'WaitCategoryDeltas' {
                    $evidence['waitCategories'] = @($rows | Select-Object -First 5 | ForEach-Object { [ordered]@{ category = [string](Get-DemoMemberValue -InputObject $_ -Name 'WaitCategory'); waitSeconds = Get-DemoMemberValue -InputObject $_ -Name 'WaitSeconds'; tasks = Get-DemoMemberValue -InputObject $_ -Name 'Tasks' } })
                }
                'CounterGauges' {
                    $evidence['gaugeCounters'] = @($rows | ForEach-Object { [ordered]@{ counter = [string](Get-DemoMemberValue -InputObject $_ -Name 'CounterName'); avg = Get-DemoMemberValue -InputObject $_ -Name 'AvgValue'; max = Get-DemoMemberValue -InputObject $_ -Name 'MaxValue' } })
                }
                default {
                    $evidence['rateCounters'] = @($rows | ForEach-Object { [ordered]@{ counter = [string](Get-DemoMemberValue -InputObject $_ -Name 'CounterName'); total = Get-DemoMemberValue -InputObject $_ -Name 'TotalEvents'; perSecond = Get-DemoMemberValue -InputObject $_ -Name 'PerSecond' } })
                }
            }
        }
    }
    return $details
}
