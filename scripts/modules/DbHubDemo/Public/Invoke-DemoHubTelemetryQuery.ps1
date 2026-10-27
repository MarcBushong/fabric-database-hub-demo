function Invoke-DemoHubTelemetryQuery {
    <#
    .SYNOPSIS
    Runs one read-only KQL query against the Database Hub performance telemetry REST endpoint.

    .DESCRIPTION
    The documented contract
    (https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry,
    "Instructions for AI agents", checked 2026-10-20):
    - POST https://adx.centralus.arcdataservices.com/kusto/v1/rest/query with the JSON body
      {"db": "ArcSqlTelemetry", "csl": "<KQL>"} (values from config/versions.json, databaseHub.telemetry).
    - A Microsoft Entra bearer token for the audience https://kusto.kusto.windows.net in the Authorization
      header. It comes from 'az account get-access-token' through Invoke-DemoAz, is registered as a secret
      at once, and is never printed, logged, stored, or returned.
    - Kusto v1 JSON back: Tables[0].Columns and Tables[0].Rows, mapped here by column name.
    - Access needs Reader (or higher) on the subscription and the Microsoft.Sql resource provider
      registered; the endpoint returns only resources the caller can read. Retention is up to 7 days.

    The call has a timeout and bounded retries (network errors, 408, 429 with Retry-After, 502, 503, 504,
    520), and one fresh token on 401. Management (dot) commands are refused: they belong to /v1/rest/mgmt,
    and this repo only reads.

    Returns Succeeded, StatusCode, ErrorKind, Error, Columns, Rows, PartialFailure, Attempts, and
    DurationSeconds. ErrorKind is empty on success, or one of Token, Network, BadRequest (KQL syntax error
    or a table or column that doesn't exist, which during the preview can mean the schema changed),
    Unauthorized (expired token or wrong audience), Forbidden (no Reader on the subscription, or
    Microsoft.Sql not registered), NotFound, Throttled, ServerError (HTTP 500: the request body isn't
    valid), Unavailable, HttpError, InvalidResponse, or PartialFailure.

    .PARAMETER SubscriptionId
    The configured subscription. The token request carries it, so the token is for that subscription's tenant.

    .PARAMETER Query
    Read-only KQL, for example from Get-DemoHubTelemetryKql.

    .PARAMETER TimeoutSeconds
    Timeout for one HTTP request.

    .PARAMETER MaxAttempts
    Attempts for retryable failures.

    .EXAMPLE
    $kql = Get-DemoHubTelemetryKql -Name ResourceSummary -ResourceId $ids
    (Invoke-DemoHubTelemetryQuery -SubscriptionId $config.subscriptionId -Query $kql).Rows
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Query,

        [ValidateRange(10, 600)]
        [int] $TimeoutSeconds = 120,

        [ValidateRange(1, 6)]
        [int] $MaxAttempts = 3
    )

    $statement = (@($Query -split "`r?`n" | Where-Object { $_ -notmatch '^\s*//' -and $_.Trim() }) -join "`n").TrimStart()
    if ($statement.StartsWith('.', [System.StringComparison]::Ordinal)) {
        throw 'Invoke-DemoHubTelemetryQuery runs read-only KQL only. Management (dot) commands belong to /v1/rest/mgmt, which this repo never calls.'
    }

    $telemetry = (Get-DemoHubSetting)['telemetry']
    # The [string] cast keeps csl a plain string; anything else gets HTTP 500 (telemetry doc, "REST errors").
    $body = [ordered]@{ db = [string]$telemetry['database']; csl = [string]$Query } | ConvertTo-Json -Compress
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $call = Invoke-DemoHubRestCall -SubscriptionId $SubscriptionId -Resource ([string]$telemetry['tokenAudience']) -Method Post -Uri ([string]$telemetry['queryUrl']) -Body $body -TimeoutSec $TimeoutSeconds -MaxAttempts $MaxAttempts
    $stopwatch.Stop()

    $result = [ordered]@{
        PSTypeName      = 'DbHubDemo.TelemetryQueryResult'
        Succeeded       = $false
        StatusCode      = $call.StatusCode
        ErrorKind       = $call.ErrorKind
        Error           = $call.Error
        Columns         = @()
        Rows            = @()
        PartialFailure  = $false
        Attempts        = $call.Attempts
        DurationSeconds = [System.Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    }
    if (-not $call.Succeeded) {
        return [pscustomobject]$result
    }

    try {
        $parsed = ConvertFrom-DemoKustoV1Response -Content $call.Content
    }
    catch {
        $result['ErrorKind'] = 'InvalidResponse'
        $result['Error'] = Protect-DemoText -Text $_.Exception.Message
        return [pscustomobject]$result
    }

    $result['Columns'] = $parsed.Columns
    $result['Rows'] = $parsed.Rows
    $result['PartialFailure'] = $parsed.PartialFailure
    if ($parsed.PartialFailure) {
        $result['ErrorKind'] = 'PartialFailure'
        $result['Error'] = 'The query failed after it started, so the rows may be incomplete: ' + ($parsed.Exceptions -join ' | ')
        return [pscustomobject]$result
    }
    $result['Succeeded'] = $true
    return [pscustomobject]$result
}
