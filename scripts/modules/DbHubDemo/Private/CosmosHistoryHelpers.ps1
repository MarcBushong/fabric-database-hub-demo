# T5's Azure Cosmos DB metrics for the history (2026-11-18, ADR 0027). NB_DatabaseHub_LiveActivity can't read T5: a Fabric
# notebook gets no Azure Resource Manager token, and Database Hub's Cosmos DB views chart Azure Monitor platform metrics,
# which aren't in the SQL telemetry endpoint the notebook queries. So the operator's side reads them here, with the Azure
# CLI, as PostgresHistoryHelpers.ps1 reads T4's, and passes them to the notebook's analyze-only run as its COSMOS_METRICS
# parameter: compact JSON that the notebook writes to telemetry_snapshots and analysis_findings (analysis 'cosmosdb',
# target 'T5'). T5's account isn't deleted between sessions, so its metrics can be read any time within Azure Monitor's
# retention.
# Sources (checked 2026-11-18):
# - Metrics - List: https://learn.microsoft.com/rest/api/monitor/metrics/list
# - az rest: https://learn.microsoft.com/cli/azure/reference-index#az-rest
# - Supported metrics for Microsoft.DocumentDB/databaseAccounts:
#   https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-documentdb-databaseaccounts-metrics
# - Monitor a Cosmos DB account in the Database Hub: https://learn.microsoft.com/fabric/database/hub/monitor-cosmos-db
# - Normalized RU consumption: https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units
# - Run a notebook on demand with parameters: https://learn.microsoft.com/fabric/data-engineering/notebook-public-api

# The document's version; NB_DatabaseHub_LiveActivity reads version 1.
$script:CosmosHistoryVersion = 1

# What T5's history keeps, one Metrics - List read each: the signals Database Hub's Cosmos DB views chart (Normalized RU
# Consumption, Total Request Units, Throttled Requests, Provisioned throughput, and Availability), the requests the 429 rate
# divides by, and the gateway's server-side latency, because the runner uses gateway mode, so ServerSideLatencyDirect, the
# Hub's Avg Latency, stays empty. ThrottledRequests is TotalRequests filtered to StatusCode 429 (config/versions.json
# cosmosdb.metrics). ProvisionedThroughput has no grain under 5 minutes and ServiceAvailability none under an hour, so both
# are read hourly.
$script:CosmosHistoryReads = @(
    @{ Metric = 'NormalizedRUConsumption'; Name = 'NormalizedRUConsumption'; Aggregation = 'Maximum'; Throttled = $false; Hourly = $false }
    @{ Metric = 'TotalRequestUnits'; Name = 'TotalRequestUnits'; Aggregation = 'Total'; Throttled = $false; Hourly = $false }
    @{ Metric = 'TotalRequests'; Name = 'TotalRequests'; Aggregation = 'Count'; Throttled = $false; Hourly = $false }
    @{ Metric = 'ThrottledRequests'; Name = 'TotalRequests'; Aggregation = 'Count'; Throttled = $true; Hourly = $false }
    @{ Metric = 'ServerSideLatencyGateway'; Name = 'ServerSideLatencyGateway'; Aggregation = 'Average'; Throttled = $false; Hourly = $false }
    @{ Metric = 'ProvisionedThroughput'; Name = 'ProvisionedThroughput'; Aggregation = 'Maximum'; Throttled = $false; Hourly = $true }
    @{ Metric = 'ServiceAvailability'; Name = 'ServiceAvailability'; Aggregation = 'Average'; Throttled = $false; Hourly = $true }
)

# The intervals a document steps up through, in minutes, until it fits the size bound, as T4's do.
$script:CosmosHistoryIntervals = @(1, 5, 15, 30, 60, 180, 360, 720, 1440)

# One read holds at most this many intervals (a day of minutes): a longer window is read at a coarser interval.
$script:CosmosHistoryMaxReadPoints = 1440

function Read-DemoCosmosHistoryMetric {
    <#
    .SYNOPSIS
    One read of Azure Monitor's Metrics - List for T5's account: -Name with one -Aggregation, every -IntervalMinutes over
    -Timespan, with -Filter for a dimension (StatusCode eq '429'). Returns Read ($true when Azure answered), NotFound (the
    account isn't there), Unit, Points (UTC instant to value, only the points that have a value; points of several time
    series at one instant are combined as the aggregation combines them), and Error (redacted). Never throws. Internal.

    .DESCRIPTION
    The query parameters go in a private file (--url-parameters @<path>), as Read-DemoPostgresHistoryMetric sends them,
    because an encoded query string has '%', which cmd.exe can't pass to az.cmd (live, 2026-10-26).
    Source: https://learn.microsoft.com/rest/api/monitor/metrics/list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $AccountId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]{1,64}$')]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('Maximum', 'Total', 'Count', 'Average', 'Minimum')]
        [string] $Aggregation,

        [AllowEmptyString()]
        [string] $Filter = '',

        [Parameter(Mandatory)]
        [ValidatePattern('^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')]
        [string] $Timespan,

        [Parameter(Mandatory)]
        [ValidateSet('1', '5', '15', '30', '60')]
        [int] $IntervalMinutes,

        [Parameter(Mandatory)]
        [string] $Directory,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9-]{1,40}$')]
        [string] $FileStem
    )

    $points = [System.Collections.Generic.SortedDictionary[datetime, double]]::new()
    $counts = [System.Collections.Generic.Dictionary[datetime, int]]::new()
    $field = $Aggregation.ToLowerInvariant()
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $answer = { param([bool] $Read, [bool] $NotFound, [string] $Unit, [string] $Why) [pscustomobject]@{ Read = $Read; NotFound = $NotFound; Unit = $Unit; Points = $points; Error = $Why } }
    try {
        $parameters = [ordered]@{
            timespan      = $Timespan
            interval      = $(if ($IntervalMinutes -eq 60) { 'PT1H' } else { 'PT{0}M' -f $IntervalMinutes })
            metricnames   = $Name
            aggregation   = $Aggregation
            'api-version' = (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Insights/metrics')
        }
        if ($Filter) {
            $parameters['$filter'] = $Filter
        }
        $path = Write-DemoPrivateFile -Directory $Directory -Name ('{0}.json' -f $FileStem) -Content ($parameters | ConvertTo-Json -Compress)
        $url = 'https://management.azure.com{0}/providers/Microsoft.Insights/metrics' -f $AccountId
        $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'get', '--url', $url, '--url-parameters', "@$path", '--output', 'json') -AllowFailure
        if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
            $text = (Protect-DemoText -Text ([string]$result.StdErr)).Trim()
            $missing = $text -match '(?i)ResourceNotFound|ResourceGroupNotFound|\(404\)|\bNot ?Found\b'
            return (& $answer $false $missing '' $(if ($text) { $text } else { 'the Azure CLI returned no metrics' }))
        }
        $body = [string]$result.StdOut | ConvertFrom-Json -Depth 32
        $unit = ''
        foreach ($metric in (Get-DemoMemberList -InputObject $body -Name 'value')) {
            if ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $metric -Name 'name') -Name 'value') -ne $Name) {
                continue
            }
            $unit = [string](Get-DemoMemberValue -InputObject $metric -Name 'unit')
            foreach ($timeseries in (Get-DemoMemberList -InputObject $metric -Name 'timeseries')) {
                foreach ($point in (Get-DemoMemberList -InputObject $timeseries -Name 'data')) {
                    $value = Get-DemoMemberValue -InputObject $point -Name $field
                    $stamp = ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $point -Name 'timeStamp')
                    $number = 0.0
                    if ($null -eq $value -or $null -eq $stamp -or $value -is [bool] -or
                        -not [double]::TryParse([string]$value, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$number) -or
                        [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
                        continue
                    }
                    $at = [datetime]$stamp
                    if (-not $points.ContainsKey($at)) {
                        $points[$at] = $number
                        $counts[$at] = 1
                        continue
                    }
                    # Several time series at one instant (one per dimension value): combined as the aggregation does.
                    switch ($Aggregation) {
                        'Maximum' { $points[$at] = [System.Math]::Max($points[$at], $number) }
                        'Minimum' { $points[$at] = [System.Math]::Min($points[$at], $number) }
                        'Average' { $points[$at] = ($points[$at] * $counts[$at] + $number) / ($counts[$at] + 1) }
                        default { $points[$at] = $points[$at] + $number }
                    }
                    $counts[$at] = $counts[$at] + 1
                }
            }
        }
        if (-not $unit -and $Aggregation -in 'Count', 'Total') {
            $unit = 'Count'
        }
        return (& $answer $true $false $unit '')
    }
    catch {
        return (& $answer $false $false '' (Protect-DemoText -Text $_.Exception.Message).Trim())
    }
}

function Get-DemoCosmosHistoryParameter {
    <#
    .SYNOPSIS
    T5's Azure Monitor metrics over the last -WindowMinutes, as NB_DatabaseHub_LiveActivity's COSMOS_METRICS parameter:
    compact JSON (version 1), or an empty string when there's nothing to add. Never throws for an Azure error. Internal.

    .DESCRIPTION
    NB_DatabaseHub_LiveActivity can't read T5 (no Azure Resource Manager token in a notebook), so stop-demo.ps1
    -SaveHistory, deploy.ps1's history snapshot, and configure-fabric.ps1 -RunLiveActivity read its metrics here and send
    them with the notebook's analyze-only run (2026-11-18, ADR 0027). Read-only:
    1. T5's account, cosmos01-<deploymentId> (Get-DemoT5State, which reads the resource group's deploymentId tag unless
       -DeploymentId gives it). With T5 turned off (t5Enabled false), no deploymentId, or an account that doesn't exist,
       nothing is read: Not selected.
    2. Its metrics, one Metrics - List read each (Read-DemoCosmosHistoryMetric), every -IntervalMinutes over the window,
       which starts on an interval boundary (a coarser interval when the window holds more than 1,440 of them):
       NormalizedRUConsumption (Maximum), TotalRequestUnits (Total), TotalRequests (Count), ThrottledRequests
       (TotalRequests filtered to StatusCode 429, Count), and ServerSideLatencyGateway (Average); and hourly,
       ProvisionedThroughput (Maximum) and ServiceAvailability (Average). Only the points with a value are kept; a series
       without one is left out, but ThrottledRequests stays when its read worked: none throttled. An account with no data
       in the window is left out, with a note.
    3. The document, at most -MaxBytes of UTF-8 (about 24 KB by default): when it's larger, every series is combined into
       coarser intervals (5, then 15, 30, 60, and up to 1440 minutes; ConvertTo-DemoPostgresHistoryPoint, where Count
       combines as a sum), an hourly series never finer than an hour, and a note says so.
    The document holds the account's name, metric names, times, and numbers; no resource ID, subscription, or credential:
    {"version":1,"capturedUtc":"...","startUtc":"...","endUtc":"...","windowMinutes":60,"intervalMinutes":1,
     "accounts":[{"target":"T5","resourceName":"cosmos01-abc123"}],
     "series":[{"resourceName":"cosmos01-abc123","metric":"NormalizedRUConsumption","aggregation":"Maximum",
                "unit":"Percent","intervalMinutes":1,"points":[["2026-11-18T17:00:00Z",100],...]},
               {"resourceName":"cosmos01-abc123","metric":"ThrottledRequests","aggregation":"Count","unit":"Count",
                "statusCode":"429","intervalMinutes":1,"points":[...]},...]}
    Returns Json, Status, Message, AccountName, SeriesCount, PointCount, IntervalMinutes, WindowMinutes, Bytes,
    PeakNormalizedRu, Requests, ThrottledRequests, and Notes. Status is for the caller's result line: Pass when metrics
    were captured; Warning when a read failed (Json may still hold what was read) or the account had no data; Not
    selected when there's nothing to read (T5 off, or not deployed).
    Sources: https://learn.microsoft.com/rest/api/monitor/metrics/list,
    https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-documentdb-databaseaccounts-metrics,
    https://learn.microsoft.com/fabric/database/hub/monitor-cosmos-db

    .PARAMETER WindowMinutes
    How far back to read, ending now; the notebook run's WINDOW_MINUTES.

    .PARAMETER IntervalMinutes
    The interval Azure Monitor aggregates each point over before any coarsening (1 by default: T5's ru-storm waves and
    their recovery last minutes).

    .PARAMETER DeploymentId
    The deployment's six-character suffix in the account's name; read from the resource group's deploymentId tag when it
    isn't given.

    .PARAMETER MaxBytes
    The document's size bound in UTF-8 bytes.

    .PARAMETER NowUtc
    The window's end; the current time by default.

    .EXAMPLE
    $cosmos = Get-DemoCosmosHistoryParameter -Config $config -WindowMinutes 720
    $parameters['COSMOS_METRICS'] = $cosmos.Json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(15, 10080)]
        [int] $WindowMinutes = 1440,

        [ValidateSet('1', '5', '15', '30', '60')]
        [int] $IntervalMinutes = 1,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [ValidateRange(4096, 262144)]
        [int] $MaxBytes = 24576,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $notes = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $accountName = ''
    $totals = @{ Peak = $null; Requests = $null; Throttled = $null }
    $answer = {
        param([string] $Status, [string] $Message, [string] $Json = '', [int] $Series = 0, [int] $Points = 0, [int] $Interval = $IntervalMinutes)
        [pscustomobject]@{
            Json              = $Json
            Status            = $Status
            Message           = $Message
            AccountName       = $accountName
            SeriesCount       = $Series
            PointCount        = $Points
            IntervalMinutes   = $Interval
            WindowMinutes     = $WindowMinutes
            Bytes             = [System.Text.Encoding]::UTF8.GetByteCount($Json)
            PeakNormalizedRu  = $totals.Peak
            Requests          = $totals.Requests
            ThrottledRequests = $totals.Throttled
            Notes             = $notes.ToArray()
        }
    }

    # The read's interval: the one asked, or a coarser one when the window would hold more than a day of minutes.
    $readInterval = $IntervalMinutes
    foreach ($candidate in @(1, 5, 15, 30, 60)) {
        if ($candidate -ge $IntervalMinutes -and ($WindowMinutes / $candidate) -le $script:CosmosHistoryMaxReadPoints) {
            $readInterval = $candidate
            break
        }
    }
    # The window ends at the current minute and starts on an interval boundary, so every interval is a whole one; the hourly
    # reads start on the hour.
    $now = ConvertTo-DemoRunCommandUtc -Value $NowUtc
    $end = [datetime]::new($now.Ticks - ($now.Ticks % [TimeSpan]::TicksPerMinute), [System.DateTimeKind]::Utc)
    $from = $end.AddMinutes(-$WindowMinutes)
    $intervalTicks = [TimeSpan]::FromMinutes($readInterval).Ticks
    $start = [datetime]::new($from.Ticks - ($from.Ticks % $intervalTicks), [System.DateTimeKind]::Utc)
    $hourStart = [datetime]::new($from.Ticks - ($from.Ticks % [TimeSpan]::TicksPerHour), [System.DateTimeKind]::Utc)
    $timespan = '{0}/{1}' -f (ConvertTo-DemoPostgresHistoryStamp -Value $start), (ConvertTo-DemoPostgresHistoryStamp -Value $end)
    $hourTimespan = '{0}/{1}' -f (ConvertTo-DemoPostgresHistoryStamp -Value $hourStart), (ConvertTo-DemoPostgresHistoryStamp -Value $end)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $span = '{0} to {1} UTC' -f $start.ToString('yyyy-MM-dd HH:mm', $invariant), $end.ToString('yyyy-MM-dd HH:mm', $invariant)

    if (-not (Test-DemoT5Enabled -Config $Config)) {
        return (& $answer 'Not selected' 'T5 is turned off (t5Enabled is false), so no Azure Cosmos DB metrics go to the history.')
    }
    try {
        $state = Get-DemoT5State -Config $Config -DeploymentId $DeploymentId
    }
    catch {
        $errors.Add((Protect-DemoText -Text $_.Exception.Message).Trim())
        $notes.Add($errors[0])
        return (& $answer 'Warning' ('T5''s metrics weren''t read for the history: its account couldn''t be resolved ({0}).' -f $errors[0]))
    }
    $accountName = [string]$state.Names.AccountName
    if (-not $accountName) {
        return (& $answer 'Not selected' 'T5''s account isn''t known (the resource group has no deploymentId tag, so the demo isn''t deployed), so no Azure Cosmos DB metrics go to the history.')
    }
    if ([string]$state.State -eq 'NotFound') {
        $notes.Add(('T5 ({0}) doesn''t exist (T5 isn''t deployed yet: ./scripts/deploy.ps1 creates it), so it''s left out.' -f $accountName))
        return (& $answer 'Not selected' ('No Azure Cosmos DB metrics go to the history: {0}' -f ($notes -join ' ')))
    }
    if (-not $state.Exists -and $state.Error) {
        # The metrics are still read: the account's read can fail on its own.
        $errors.Add(('T5 ({0}) couldn''t be read: {1}' -f $accountName, $state.Error))
    }

    $series = [System.Collections.Generic.List[object]]::new()
    $cosmos = Get-DemoCosmosSetting
    $filter = "{0} eq '{1}'" -f $cosmos['metrics']['throttledDimension'], $cosmos['metrics']['throttledStatusCode']
    $directory = ''
    try {
        $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-cosmoshistory'
        $index = 0
        foreach ($read in $script:CosmosHistoryReads) {
            $index++
            $metric = Read-DemoCosmosHistoryMetric -Config $Config -AccountId $state.Names.AccountId -Name $read.Name -Aggregation $read.Aggregation -Filter $(if ($read.Throttled) { $filter } else { '' }) -Timespan $(if ($read.Hourly) { $hourTimespan } else { $timespan }) -IntervalMinutes $(if ($read.Hourly) { 60 } else { $readInterval }) -Directory $directory -FileStem ('metrics-{0}' -f $index)
            if ($metric.NotFound) {
                $series.Clear()
                $errors.Clear()
                $notes.Add(('T5 ({0}) isn''t there for Azure Monitor ({1}), so it''s left out.' -f $accountName, $metric.Error))
                break
            }
            if (-not $metric.Read) {
                $errors.Add(('T5''s {0} ({1}) couldn''t be read: {2}' -f $read.Metric, $read.Aggregation, $metric.Error))
                continue
            }
            $series.Add([pscustomobject]@{ Metric = $read.Metric; Aggregation = $read.Aggregation; Unit = $metric.Unit; StatusCode = $(if ($read.Throttled) { [string]$cosmos['metrics']['throttledStatusCode'] } else { '' }); Interval = $(if ($read.Hourly) { 60 } else { $readInterval }); Points = $metric.Points })
        }
    }
    catch {
        $errors.Add((Protect-DemoText -Text $_.Exception.Message).Trim())
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    foreach ($problem in $errors) {
        $notes.Add($problem)
    }

    if (@($series | Where-Object { $_.Points.Count -gt 0 }).Count -eq 0) {
        if ($errors.Count -gt 0) {
            return (& $answer 'Warning' ('T5''s Azure Monitor metrics couldn''t be read, so none go to the history: {0}' -f ($notes -join ' ')))
        }
        if ($notes.Count -gt 0) {
            # Azure Monitor didn't know the account: not deployed, as far as the history goes.
            return (& $answer 'Not selected' ('No Azure Cosmos DB metrics go to the history: {0}' -f ($notes -join ' ')))
        }
        $notes.Add(('T5 ({0}) had no Azure Monitor data from {1} (no requests yet, or its metrics haven''t arrived), so it''s left out.' -f $accountName, $span))
        return (& $answer 'Warning' ('No Azure Cosmos DB metrics go to the history: {0}' -f ($notes -join ' ')))
    }
    # A series without a point is left out, but the throttled requests stay when their read worked: none throttled.
    $kept = @($series | Where-Object { $_.Points.Count -gt 0 -or $_.Metric -eq 'ThrottledRequests' })
    $sumOf = {
        param([string] $Metric)
        $item = @($kept | Where-Object { $_.Metric -eq $Metric }) | Select-Object -First 1
        if ($null -eq $item) { return $null }
        $sum = 0.0
        foreach ($value in $item.Points.Values) { $sum += $value }
        return $sum
    }
    $normalized = @($kept | Where-Object { $_.Metric -eq 'NormalizedRUConsumption' }) | Select-Object -First 1
    if ($null -ne $normalized -and $normalized.Points.Count -gt 0) {
        $totals.Peak = [double](@($normalized.Points.Values) | Measure-Object -Maximum).Maximum
    }
    $totals.Requests = & $sumOf 'TotalRequests'
    $totals.Throttled = & $sumOf 'ThrottledRequests'

    # The smallest interval whose document fits the bound.
    $ladder = @($script:CosmosHistoryIntervals | Where-Object { $_ -ge $readInterval })
    $json = ''
    $bytes = 0
    $interval = $readInterval
    $pointCount = 0
    foreach ($step in $ladder) {
        $interval = $step
        $pointCount = 0
        $seriesOut = @(foreach ($item in $kept) {
                $seriesInterval = [System.Math]::Max($step, [int]$item.Interval)
                # Count combines as a sum; availability keeps two decimals, so 99.95 % isn't written as 100.
                $points = ConvertTo-DemoPostgresHistoryPoint -Point $item.Points -Aggregation $(if ($item.Aggregation -eq 'Count') { 'Total' } else { $item.Aggregation }) -Unit $(if ($item.Metric -eq 'ServiceAvailability') { '' } else { $item.Unit }) -IntervalMinutes $seriesInterval
                $pointCount += @($points).Count
                $entry = [ordered]@{ resourceName = $accountName; metric = $item.Metric; aggregation = $item.Aggregation; unit = $item.Unit }
                if ($item.StatusCode) {
                    $entry['statusCode'] = $item.StatusCode
                }
                $entry['intervalMinutes'] = $seriesInterval
                $entry['points'] = $points
                $entry
            })
        $document = [ordered]@{
            version         = $script:CosmosHistoryVersion
            capturedUtc     = (ConvertTo-DemoPostgresHistoryStamp -Value $end)
            startUtc        = (ConvertTo-DemoPostgresHistoryStamp -Value $start)
            endUtc          = (ConvertTo-DemoPostgresHistoryStamp -Value $end)
            windowMinutes   = $WindowMinutes
            intervalMinutes = $step
            accounts        = @([ordered]@{ target = 'T5'; resourceName = $accountName })
            series          = $seriesOut
        }
        $json = ConvertTo-Json -InputObject $document -Depth 8 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
        if ($bytes -le $MaxBytes) {
            break
        }
    }
    if ($bytes -gt $MaxBytes) {
        $notes.Add(('Even at {0}-minute intervals the document is {1:N0} bytes, over the {2:N0}-byte bound.' -f $interval, $bytes, $MaxBytes))
        return (& $answer 'Warning' ('T5''s Azure Monitor metrics are too large for the notebook''s parameter, so none go to the history: {0:N0} bytes at {1}-minute intervals, over {2:N0}.' -f $bytes, $interval, $MaxBytes) '' 0 0 $interval)
    }
    if ($interval -ne $readInterval) {
        $notes.Add(('Combined the {1}-minute intervals into {0}-minute ones to keep the document within {2:N0} bytes.' -f $interval, $readInterval, $MaxBytes))
    }
    $facts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $totals.Peak) {
        $facts.Add([string]::Format($invariant, 'normalized RU consumption peaked at {0:N0}%', $totals.Peak))
    }
    if ($null -ne $totals.Throttled) {
        $facts.Add([string]::Format($invariant, '{0:N0} throttled request(s) (429){1}', $totals.Throttled, $(if ($null -ne $totals.Requests) { [string]::Format($invariant, ' of {0:N0}', $totals.Requests) } else { '' })))
    }
    $message = [string]::Format($invariant, 'Azure Monitor metrics for the history: T5 ({0}), {1} series and {2:N0} points from {3}, every {4} minute(s) ({5:N1} KB){6}.', $accountName, $kept.Count, $pointCount, $span, $interval, ($bytes / 1024.0), $(if ($facts.Count -gt 0) { ': ' + ($facts -join ', ') } else { '' }))
    if ($notes.Count -gt 0) {
        $message = '{0} {1}' -f $message, ($notes -join ' ')
    }
    $status = if ($errors.Count -gt 0) { 'Warning' } else { 'Pass' }
    return (& $answer $status $message $json $kept.Count $pointCount $interval)
}

function Get-DemoCosmosHistoryCapture {
    <#
    .SYNOPSIS
    T5's Azure Monitor metrics for the history (2026-11-18, ADR 0027), captured on the operator's side for
    NB_DatabaseHub_LiveActivity's COSMOS_METRICS parameter, because Fabric notebooks get no Azure Resource Manager token.
    Returns Json ('' when there's nothing) and Result (-CheckId: Pass, Warning, or Not selected when T5 is off or not
    deployed). Never throws. Internal.

    .DESCRIPTION
    stop-demo.ps1 -SaveHistory, deploy.ps1's history snapshot, and configure-fabric.ps1 -RunLiveActivity call it. T5's
    account stays between sessions, so its metrics can be read any time before the run. The reading and the JSON's shape
    are Get-DemoCosmosHistoryParameter's.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(15, 10080)]
        [int] $WindowMinutes = 720,

        [ValidatePattern('^[A-Z0-9]+(\.[A-Z0-9_]+)+$')]
        [string] $CheckId = 'STOP.T5.HISTORY',

        # The deployment's suffix when the caller has it (the resource group's deploymentId tag); read when it isn't given.
        [AllowEmptyString()]
        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = ''
    )

    $docUrl = 'https://learn.microsoft.com/fabric/database/hub/monitor-cosmos-db'
    try {
        $docUrl = [string](Get-DemoCosmosSetting)['docUrls']['hubMonitor']
        $capture = Get-DemoCosmosHistoryParameter -Config $Config -WindowMinutes $WindowMinutes -DeploymentId $DeploymentId
        $json = [string]$capture.Json
        $evidence = [ordered]@{ account = [string]$capture.AccountName; series = [int]$capture.SeriesCount; points = [int]$capture.PointCount; bytes = [int]$capture.Bytes; intervalMinutes = [int]$capture.IntervalMinutes; windowMinutes = $WindowMinutes; peakNormalizedRuPercent = $capture.PeakNormalizedRu; requests = $capture.Requests; throttledRequests = $capture.ThrottledRequests; notes = @($capture.Notes) }
        $remediation = ''
        if ([string]$capture.Status -eq 'Warning') {
            $remediation = 'Database Hub''s Cosmos DB views show T5''s metrics for Azure Monitor''s retention; the next ./scripts/stop-demo.ps1 -SaveHistory or ./scripts/configure-fabric.ps1 -RunLiveActivity reads them again.'
        }
        return [pscustomobject]@{ Json = $json; Result = (New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'T5' -Status ([string]$capture.Status) -Message ([string]$capture.Message) -Evidence $evidence -Remediation $remediation -DocUrl $docUrl) }
    }
    catch {
        return [pscustomobject]@{ Json = ''; Result = (New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'T5' -Status 'Warning' -Message ('T5''s metrics weren''t captured for the history: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Nothing to do for the demo; the history keeps the other targets.' -DocUrl $docUrl) }
    }
}
