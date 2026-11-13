# T4's PostgreSQL metrics for the history (2026-11-13, user-directed; ADR 0025). NB_DatabaseHub_LiveActivity can't read T4
# or its read replica: a Fabric notebook gets no Azure Resource Manager token (notebookutils' audiences are storage, pbi,
# keyvault, and kusto), and Database Hub's PostgreSQL dashboard charts Azure Monitor metrics, which aren't in the SQL
# telemetry endpoint the notebook queries. So the operator's side reads them here, with the Azure CLI, and passes them to
# the notebook's analyze-only run as its POSTGRES_METRICS parameter: compact JSON that the notebook writes to
# telemetry_snapshots and analysis_findings (analysis 'postgresql', targets 'T4' and 'T4-replica'). The replica's metrics go
# with it when stop-demo.ps1 deletes it, so they're read before that.
# Sources (checked 2026-11-13):
# - Metrics - List: https://learn.microsoft.com/rest/api/monitor/metrics/list
# - az rest: https://learn.microsoft.com/cli/azure/reference-index#az-rest
# - Supported metrics for Microsoft.DBforPostgreSQL/flexibleServers:
#   https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-dbforpostgresql-flexibleservers-metrics
# - Read replicas (Read Replica Lag on replicas, Max Physical Replication Lag on the primary):
#   https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas
# - Monitor PostgreSQL in Database Hub: https://learn.microsoft.com/fabric/database/hub/monitor-postgresql
# - Run a notebook on demand with parameters: https://learn.microsoft.com/fabric/data-engineering/notebook-public-api

# The document's version; NB_DatabaseHub_LiveActivity reads version 1.
$script:PostgresHistoryVersion = 1

# What each server's history keeps, in one Metrics - List read per aggregation: the highest value in each interval, and the
# number of failed connections in it (Total). Read Replica Lag (physical_replication_delay_in_seconds) exists on a replica
# only, and Max Physical Replication Lag (physical_replication_delay_in_bytes) on the primary only (config/versions.json
# postgresql.replica.metrics).
$script:PostgresHistoryReads = @{
    primary = @(
        @{ Aggregation = 'Maximum'; Names = @('cpu_percent', 'memory_percent', 'active_connections', 'physical_replication_delay_in_bytes') }
        @{ Aggregation = 'Total'; Names = @('connections_failed') }
    )
    replica = @(
        @{ Aggregation = 'Maximum'; Names = @('physical_replication_delay_in_seconds', 'cpu_percent', 'active_connections') }
    )
}

# The intervals a document steps up through, in minutes, until it fits the size bound. Each one divides a day, so every
# interval starts on its own UTC boundary, and each is a multiple of the ones before it, so a coarser interval combines
# whole finer ones.
$script:PostgresHistoryIntervals = @(1, 5, 15, 30, 60, 180, 360, 720, 1440)

# Decimals kept per Azure Monitor unit; any other unit keeps two.
$script:PostgresHistoryDecimals = @{ Percent = 1; Seconds = 1; Count = 0; Bytes = 0 }

function ConvertTo-DemoPostgresHistoryStamp {
    # A UTC instant as yyyy-MM-ddTHH:mm:ssZ, the document's time format. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [datetime] $Value
    )

    return $Value.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Read-DemoPostgresHistoryMetric {
    <#
    .SYNOPSIS
    One read of Azure Monitor's Metrics - List for one server: -Name with one -Aggregation, every -IntervalMinutes over
    -Timespan. Returns Series (Metric, Unit, Aggregation, and Points: UTC instant to value, only the points that have a
    value) and Error (redacted; empty when the read worked). Never throws. Internal.

    .DESCRIPTION
    The query parameters go in a private file (--url-parameters @<path>), as Get-DemoT4MetricSnapshot sends them, because an
    encoded query string has '%', which cmd.exe can't pass to az.cmd (live, 2026-10-26).
    Source: https://learn.microsoft.com/rest/api/monitor/metrics/list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ServerId,

        [Parameter(Mandatory)]
        [string[]] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('Maximum', 'Total', 'Average', 'Minimum')]
        [string] $Aggregation,

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

    $series = [System.Collections.Generic.List[object]]::new()
    $field = $Aggregation.ToLowerInvariant()
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    try {
        $parameters = [ordered]@{
            timespan      = $Timespan
            interval      = $(if ($IntervalMinutes -eq 60) { 'PT1H' } else { 'PT{0}M' -f $IntervalMinutes })
            metricnames   = ($Name -join ',')
            aggregation   = $Aggregation
            'api-version' = (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Insights/metrics')
        }
        $path = Write-DemoPrivateFile -Directory $Directory -Name ('{0}.json' -f $FileStem) -Content ($parameters | ConvertTo-Json -Compress)
        $url = 'https://management.azure.com{0}/providers/Microsoft.Insights/metrics' -f $ServerId
        $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'get', '--url', $url, '--url-parameters', "@$path", '--output', 'json') -AllowFailure
        if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
            $text = (Protect-DemoText -Text ([string]$result.StdErr)).Trim()
            return [pscustomobject]@{ Series = $series.ToArray(); Error = $(if ($text) { $text } else { 'the Azure CLI returned no metrics' }) }
        }
        $body = [string]$result.StdOut | ConvertFrom-Json -Depth 32
        foreach ($metric in (Get-DemoMemberList -InputObject $body -Name 'value')) {
            $metricName = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $metric -Name 'name') -Name 'value')
            if ($metricName -notin $Name) {
                continue
            }
            $points = [System.Collections.Generic.SortedDictionary[datetime, double]]::new()
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
                    $points[[datetime]$stamp] = $number
                }
            }
            $series.Add([pscustomobject]@{ Metric = $metricName; Unit = [string](Get-DemoMemberValue -InputObject $metric -Name 'unit'); Aggregation = $Aggregation; Points = $points })
        }
    }
    catch {
        return [pscustomobject]@{ Series = $series.ToArray(); Error = (Protect-DemoText -Text $_.Exception.Message).Trim() }
    }
    return [pscustomobject]@{ Series = $series.ToArray(); Error = '' }
}

function ConvertTo-DemoPostgresHistoryPoint {
    <#
    .SYNOPSIS
    One series' points at -IntervalMinutes, as the document holds them: two-item arrays of the interval's start
    (yyyy-MM-ddTHH:mm:ssZ) and its value. Pure. Internal.

    .DESCRIPTION
    Each point goes to the interval it starts in (UTC, counted from midnight), and the points of one interval are
    combined the way the series' aggregation combines them: Maximum keeps the highest, Total adds them up, Minimum keeps
    the lowest, and Average takes the mean. Values are rounded for their unit (percent and seconds to one decimal, counts
    and bytes to whole numbers, anything else to two decimals), and a whole number is written without decimals.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.IDictionary[datetime, double]] $Point,

        [Parameter(Mandatory)]
        [ValidateSet('Maximum', 'Total', 'Average', 'Minimum')]
        [string] $Aggregation,

        [AllowEmptyString()]
        [string] $Unit = '',

        [Parameter(Mandatory)]
        [ValidateRange(1, 1440)]
        [int] $IntervalMinutes
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $decimals = if ($script:PostgresHistoryDecimals.ContainsKey($Unit)) { [int]$script:PostgresHistoryDecimals[$Unit] } else { 2 }
    $buckets = [System.Collections.Generic.SortedDictionary[long, System.Collections.Generic.List[double]]]::new()
    foreach ($pair in $Point.GetEnumerator()) {
        $minutes = [long][System.Math]::Floor(($pair.Key.ToUniversalTime() - [datetime]::UnixEpoch).TotalMinutes)
        $bucket = $minutes - ($minutes % $IntervalMinutes)
        if (-not $buckets.ContainsKey($bucket)) {
            $buckets[$bucket] = [System.Collections.Generic.List[double]]::new()
        }
        $buckets[$bucket].Add($pair.Value)
    }
    $output = [System.Collections.Generic.List[object]]::new()
    foreach ($bucket in $buckets.GetEnumerator()) {
        $values = $bucket.Value
        $combined = $values[0]
        switch ($Aggregation) {
            'Total' {
                $combined = 0.0
                foreach ($value in $values) { $combined += $value }
            }
            'Average' {
                $combined = 0.0
                foreach ($value in $values) { $combined += $value }
                $combined = $combined / $values.Count
            }
            'Minimum' {
                foreach ($value in $values) { if ($value -lt $combined) { $combined = $value } }
            }
            default {
                foreach ($value in $values) { if ($value -gt $combined) { $combined = $value } }
            }
        }
        $rounded = [System.Math]::Round([double]$combined, $decimals, [System.MidpointRounding]::AwayFromZero)
        $number = if ($rounded -eq [System.Math]::Floor($rounded) -and [System.Math]::Abs($rounded) -lt 1e15) { [long]$rounded } else { $rounded }
        $stamp = [datetime]::UnixEpoch.AddMinutes($bucket.Key).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
        $output.Add([object[]]@($stamp, $number))
    }
    return , $output.ToArray()
}

function Get-DemoPostgresHistoryParameter {
    <#
    .SYNOPSIS
    T4's and its read replica's Azure Monitor metrics over the last -WindowMinutes, as NB_DatabaseHub_LiveActivity's
    POSTGRES_METRICS parameter: compact JSON (version 1), or an empty string when there's nothing to add. Never throws for
    an Azure error. Internal.

    .DESCRIPTION
    NB_DatabaseHub_LiveActivity can't read T4 (no Azure Resource Manager token in a notebook), so stop-demo.ps1
    -SaveHistory and deploy.ps1's history snapshot read T4's metrics here and send them with the notebook's analyze-only
    run (2026-11-13, ADR 0025). Read-only:
    1. The names: T4 (pgflex01-<deploymentId>, Get-DemoT4Name, which reads the resource group's deploymentId tag unless
       -DeploymentId gives it) and its read replica (pgreplica01-<deploymentId>, Get-DemoT4ReplicaName). With T4 turned
       off (t4Enabled false), or no deploymentId, nothing is read: Not selected.
    2. Each server (Servers - Get, for its size): one that doesn't exist is left out, with a note; without T4, its replica
       isn't read. The replica exists only during a session, so between sessions that's expected.
    3. Its metrics, one Metrics - List read per aggregation (Read-DemoPostgresHistoryMetric), every -IntervalMinutes over
       the window, which starts on an interval boundary:
       - T4 (role primary): cpu_percent, memory_percent, active_connections, and physical_replication_delay_in_bytes (Max
         Physical Replication Lag), each its Maximum per interval, and connections_failed, its Total per interval.
       - The replica (role replica): physical_replication_delay_in_seconds (Read Replica Lag, Database Hub's Read replica
         lag chart), cpu_percent, and active_connections, each its Maximum per interval.
       Only the points with a value are kept. A server with no data in the window is left out, with a note.
    4. The document, at most -MaxBytes of UTF-8 (about 24 KB by default): when it's larger, every series is combined into
       coarser intervals (5, then 15, 30, 60, and up to 1440 minutes; ConvertTo-DemoPostgresHistoryPoint), and a note says
       so.
    The document holds server names, sizes, metric names, times, and numbers; no resource ID, subscription, or credential:
    {"version":1,"capturedUtc":"...","startUtc":"...","endUtc":"...","windowMinutes":1440,"intervalMinutes":5,
     "servers":[{"role":"primary","target":"T4","resourceName":"pgflex01-abc123","sku":"Standard_D4ds_v5"},
                {"role":"replica","target":"T4-replica","resourceName":"pgreplica01-abc123","sku":"Standard_D4ds_v5"}],
     "series":[{"resourceName":"pgreplica01-abc123","role":"replica","metric":"physical_replication_delay_in_seconds",
                "aggregation":"Maximum","unit":"Seconds","points":[["2026-11-13T17:00:00Z",6],...]},...]}
    Returns Json, Status, Message, ServerCount, SeriesCount, PointCount, IntervalMinutes, WindowMinutes, Bytes, Servers
    (Role, Target, ResourceName, Sku), and Notes. Status is for the caller's result line: Pass when metrics were captured;
    Warning when a read failed (Json may still hold what was read) or a server that exists had no data; Not selected when
    there's nothing to read (T4 off, not deployed, or no deploymentId).
    Sources: https://learn.microsoft.com/rest/api/monitor/metrics/list,
    https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-dbforpostgresql-flexibleservers-metrics,
    https://learn.microsoft.com/fabric/data-engineering/notebook-public-api

    .PARAMETER WindowMinutes
    How far back to read, ending now; the notebook run's WINDOW_MINUTES.

    .PARAMETER IntervalMinutes
    The interval Azure Monitor aggregates each point over before any coarsening.

    .PARAMETER DeploymentId
    The deployment's six-character suffix in the servers' names; read from the resource group's deploymentId tag when
    it isn't given.

    .PARAMETER SkipReplica
    Read T4 only.

    .PARAMETER ReplicaOnly
    Read the read replica only.

    .PARAMETER MaxBytes
    The document's size bound in UTF-8 bytes.

    .PARAMETER NowUtc
    The window's end; the current time by default.

    .EXAMPLE
    $postgres = Get-DemoPostgresHistoryParameter -Config $config -WindowMinutes 720
    $parameters['POSTGRES_METRICS'] = $postgres.Json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(15, 10080)]
        [int] $WindowMinutes = 1440,

        [ValidateSet('1', '5', '15', '30', '60')]
        [int] $IntervalMinutes = 5,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [switch] $SkipReplica,

        [switch] $ReplicaOnly,

        [ValidateRange(4096, 262144)]
        [int] $MaxBytes = 24576,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    if ($SkipReplica -and $ReplicaOnly) {
        throw [System.ArgumentException]::new('-SkipReplica and -ReplicaOnly together leave nothing to read; use one of them.')
    }
    $notes = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $servers = [System.Collections.Generic.List[object]]::new()
    $answer = {
        param([string] $Status, [string] $Message, [string] $Json = '', [int] $Series = 0, [int] $Points = 0, [int] $Interval = $IntervalMinutes)
        [pscustomobject]@{
            Json            = $Json
            Status          = $Status
            Message         = $Message
            ServerCount     = $servers.Count
            SeriesCount     = $Series
            PointCount      = $Points
            IntervalMinutes = $Interval
            WindowMinutes   = $WindowMinutes
            Bytes           = [System.Text.Encoding]::UTF8.GetByteCount($Json)
            Servers         = @($servers | ForEach-Object { [pscustomobject]@{ Role = $_['role']; Target = $_['target']; ResourceName = $_['resourceName']; Sku = $_['sku'] } })
            Notes           = $notes.ToArray()
        }
    }

    # The window ends at the current minute and starts on an interval boundary, so every interval is a whole one.
    $now = ConvertTo-DemoRunCommandUtc -Value $NowUtc
    $end = [datetime]::new($now.Ticks - ($now.Ticks % [TimeSpan]::TicksPerMinute), [System.DateTimeKind]::Utc)
    $from = $end.AddMinutes(-$WindowMinutes)
    $intervalTicks = [TimeSpan]::FromMinutes($IntervalMinutes).Ticks
    $start = [datetime]::new($from.Ticks - ($from.Ticks % $intervalTicks), [System.DateTimeKind]::Utc)
    $timespan = '{0}/{1}' -f (ConvertTo-DemoPostgresHistoryStamp -Value $start), (ConvertTo-DemoPostgresHistoryStamp -Value $end)
    $span = '{0} to {1} UTC' -f $start.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture), $end.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)

    if (-not (Test-DemoT4Enabled -Config $Config)) {
        return (& $answer 'Not selected' 'T4 is turned off (t4Enabled is false), so no PostgreSQL metrics go to the history.')
    }
    $wanted = [System.Collections.Generic.List[object]]::new()
    try {
        $t4 = Get-DemoT4Name -Config $Config -DeploymentId $DeploymentId
        if ($t4.ServerName) {
            if (-not $ReplicaOnly) {
                $wanted.Add([pscustomobject]@{ Role = 'primary'; Target = 'T4'; Name = $t4.ServerName; Id = $t4.ServerId; Label = 'T4' })
            }
            if (-not $SkipReplica) {
                $replica = Get-DemoT4ReplicaName -Config $Config -DeploymentId $t4.DeploymentId -NoLookup
                $wanted.Add([pscustomobject]@{ Role = 'replica'; Target = 'T4-replica'; Name = $replica.ServerName; Id = $replica.ServerId; Label = 'T4''s read replica' })
            }
        }
    }
    catch {
        $errors.Add((Protect-DemoText -Text $_.Exception.Message).Trim())
        $notes.Add($errors[0])
        return (& $answer 'Warning' ('T4''s metrics weren''t read for the history: its servers'' names couldn''t be resolved ({0}).' -f $errors[0]))
    }
    if (-not $t4.ServerName) {
        return (& $answer 'Not selected' 'T4''s server isn''t known (the resource group has no deploymentId tag, so the demo isn''t deployed), so no PostgreSQL metrics go to the history.')
    }

    $series = [System.Collections.Generic.List[object]]::new()
    $existing = 0
    $directory = ''
    try {
        $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-pghistory'
        $index = 0
        foreach ($server in $wanted) {
            $sku = ''
            $errorsBefore = $errors.Count
            try {
                $read = Get-DemoT4Resource -Config $Config -ServerId $server.Id
            }
            catch {
                $read = [pscustomobject]@{ Found = $false; NotFound = $false; Value = $null; Error = (Protect-DemoText -Text $_.Exception.Message).Trim() }
            }
            if ($read.NotFound) {
                $why = if ($server.Role -eq 'replica') { 'it exists only during a session: start-demo.ps1 creates it, and stop-demo.ps1 deletes it' } else { 'T4 isn''t deployed' }
                $notes.Add(('{0} ({1}) doesn''t exist ({2}), so it''s left out.' -f $server.Label, $server.Name, $why))
                if ($server.Role -eq 'primary') {
                    # A read replica can't exist without its source.
                    break
                }
                continue
            }
            $existing++
            if ($read.Found) {
                $sku = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $read.Value -Name 'sku') -Name 'name')
            }
            else {
                # The metrics are still read: the server's read can fail on its own.
                $errors.Add(('{0} ({1}) couldn''t be read: {2}' -f $server.Label, $server.Name, $(if ($read.Error) { $read.Error } else { 'no answer' })))
            }
            $found = 0
            foreach ($group in $script:PostgresHistoryReads[$server.Role]) {
                $index++
                $metrics = Read-DemoPostgresHistoryMetric -Config $Config -ServerId $server.Id -Name $group.Names -Aggregation $group.Aggregation -Timespan $timespan -IntervalMinutes $IntervalMinutes -Directory $directory -FileStem ('metrics-{0}' -f $index)
                if ($metrics.Error) {
                    $errors.Add(('{0}''s {1} ({2}) couldn''t be read: {3}' -f $server.Label, ($group.Names -join ', '), $group.Aggregation, $metrics.Error))
                }
                foreach ($item in @($metrics.Series)) {
                    if ($item.Points.Count -gt 0) {
                        $series.Add([pscustomobject]@{ ResourceName = $server.Name; Role = $server.Role; Metric = $item.Metric; Aggregation = $item.Aggregation; Unit = $item.Unit; Points = $item.Points })
                        $found++
                    }
                }
            }
            if ($found -gt 0) {
                $servers.Add([ordered]@{ role = $server.Role; target = $server.Target; resourceName = $server.Name; sku = $sku })
            }
            elseif ($errors.Count -eq $errorsBefore) {
                $notes.Add(('{0} ({1}) had no Azure Monitor data from {2} (stopped, or its metrics haven''t arrived yet), so it''s left out.' -f $server.Label, $server.Name, $span))
            }
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

    if ($series.Count -eq 0) {
        if ($errors.Count -gt 0) {
            return (& $answer 'Warning' ('T4''s Azure Monitor metrics couldn''t be read, so none go to the history: {0}' -f ($notes -join ' ')))
        }
        # Nothing exists to read (Not selected), or what exists had no data (Warning).
        return (& $answer $(if ($existing -eq 0) { 'Not selected' } else { 'Warning' }) ('No PostgreSQL metrics go to the history: {0}' -f ($notes -join ' ')))
    }

    # The smallest interval whose document fits the bound.
    $ladder = @($script:PostgresHistoryIntervals | Where-Object { $_ -ge $IntervalMinutes })
    $json = ''
    $bytes = 0
    $interval = $IntervalMinutes
    $seriesOut = @()
    foreach ($step in $ladder) {
        $interval = $step
        $seriesOut = @(foreach ($item in $series) {
                [ordered]@{
                    resourceName = $item.ResourceName
                    role         = $item.Role
                    metric       = $item.Metric
                    aggregation  = $item.Aggregation
                    unit         = $item.Unit
                    points       = (ConvertTo-DemoPostgresHistoryPoint -Point $item.Points -Aggregation $item.Aggregation -Unit $item.Unit -IntervalMinutes $step)
                }
            })
        $document = [ordered]@{
            version         = $script:PostgresHistoryVersion
            capturedUtc     = (ConvertTo-DemoPostgresHistoryStamp -Value $end)
            startUtc        = (ConvertTo-DemoPostgresHistoryStamp -Value $start)
            endUtc          = (ConvertTo-DemoPostgresHistoryStamp -Value $end)
            windowMinutes   = $WindowMinutes
            intervalMinutes = $step
            servers         = $servers.ToArray()
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
        return (& $answer 'Warning' ('T4''s Azure Monitor metrics are too large for the notebook''s parameter, so none go to the history: {0:N0} bytes at {1}-minute intervals, over {2:N0}.' -f $bytes, $interval, $MaxBytes) '' 0 0 $interval)
    }
    if ($interval -ne $IntervalMinutes) {
        $notes.Add(('Combined the {1}-minute intervals into {0}-minute ones to keep the document within {2:N0} bytes.' -f $interval, $IntervalMinutes, $MaxBytes))
    }
    $pointCount = 0
    foreach ($item in $seriesOut) {
        $pointCount += @($item['points']).Count
    }
    $names = @($servers | ForEach-Object { if ($_['role'] -eq 'replica') { 'T4''s read replica ({0})' -f $_['resourceName'] } else { 'T4 ({0})' -f $_['resourceName'] } })
    $message = 'Azure Monitor metrics for the history: {0}, {1} series and {2:N0} points from {3}, every {4} minutes ({5:N1} KB).' -f ($names -join ' and '), $seriesOut.Count, $pointCount, $span, $interval, ($bytes / 1024.0)
    if ($notes.Count -gt 0) {
        $message = '{0} {1}' -f $message, ($notes -join ' ')
    }
    $status = if ($errors.Count -gt 0) { 'Warning' } else { 'Pass' }
    return (& $answer $status $message $json $seriesOut.Count $pointCount $interval)
}
