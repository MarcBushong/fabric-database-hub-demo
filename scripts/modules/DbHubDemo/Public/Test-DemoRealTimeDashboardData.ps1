function Test-DemoRealTimeDashboardData {
    <#
    .SYNOPSIS
    Proves that the Real-Time Dashboard's tiles populate: runs each tile's KQL, read-only, against the telemetry
    endpoint for a recent window, and returns one ADR 0012 record per tile plus a summary, FABRIC.DASHBOARD.DATA.

    .DESCRIPTION
    The tile check after the import and read-back (configure-fabric.ps1 -ImportDashboard runs it), and a deploy step
    that runs unattended: call it after Assert-DemoAzContext, as deploy.ps1 does. It only reads.

    - The queries come from the rendered definition (Get-DemoFabricDashboardDefinition -Config), which the read-back
      proved identical to what Fabric stores. Each query runs once, through Invoke-DemoHubTelemetryQuery: the
      documented SQL ADX proxy and database ArcSqlTelemetry, with a Kusto token from Get-DemoAccessToken (audience
      https://kusto.kusto.windows.net, the account of the configured subscription).
    - The dashboard's parameters are bound the way the dashboard binds them: _startTime and _endTime to the window,
      the last -LookbackHours (24 by default), and _selectedTargets to null, the dashboard's "Select all".
    - Pass: the tile's query returns rows, with every column the tile shows (its x, y, series, label, and value
      columns, and the columns its conditional formatting reads).
    - Warning: the query returns no rows, and neither does a probe of the tile's own source (its telemetry table,
      filtered the way the tile filters it, for the demo's targets, in the same window), so there was nothing to
      show. The message says when that's because the VMs aren't running right now (T1's VM and T2's VM, with T3's
      status), and Phase 20's end-to-end run checks these tiles again after a start. Also a Warning: the endpoint was
      throttled or unavailable after retries, or the query failed partway.
    - Fail: the query returns no rows although its source has rows in the window; it returns rows without a column
      the tile shows; or the endpoint rejected the query (HTTP 400), the token, or the caller's access. Without a
      validated Azure CLI context, the summary alone is a Fail and nothing is sent.
    The text tile has no query and gets no record. The summary takes the worst tile status.

    Check IDs: FABRIC.DASHBOARD.TILE.<PAGE>.<TILE>, from the keys in fabric/realtime/dashboard.spec.psd1 (for example
    FABRIC.DASHBOARD.TILE.INCIDENT.BLOCKED_NOW), and FABRIC.DASHBOARD.DATA.

    - Telemetry endpoint and its rules: https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
    - Dashboard parameters ("Select all" with an empty value): https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-parameters
    - Kusto query statements (let): https://learn.microsoft.com/kusto/query/let-statement

    .PARAMETER Config
    Configuration from Get-DemoConfig: the subscription, the resource group (prefix and environment), and T2's mode.

    .PARAMETER LookbackHours
    The window, in hours before now. The telemetry keeps 7 days or less.

    .PARAMETER Definition
    The rendered definition from Get-DemoFabricDashboardDefinition. Defaults to the one for -Config.

    .PARAMETER NowUtc
    The end of the window. Defaults to now.

    .PARAMETER TimeoutSeconds
    Timeout for each query.

    .EXAMPLE
    Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account $config['azureAccount']
    Test-DemoRealTimeDashboardData -Config $config | Format-Table -Property checkId, status, message
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(1, 168)]
        [int] $LookbackHours = 24,

        [PSTypeName('DbHubDemo.FabricItemDefinition')]
        [pscustomobject] $Definition,

        [datetime] $NowUtc = [datetime]::UtcNow,

        [ValidateRange(10, 600)]
        [int] $TimeoutSeconds = 60
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $telemetry = (Get-DemoHubSetting)['telemetry']
    $docUrl = [string]$telemetry['docUrl']
    $subscriptionId = [string]$Config['subscriptionId']
    $endUtc = if ($NowUtc.Kind -eq [System.DateTimeKind]::Local) { $NowUtc.ToUniversalTime() } else { [datetime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc) }
    $startUtc = $endUtc.AddHours(-$LookbackHours)
    $span = if ($LookbackHours -eq 1) { 'the last hour' } else { 'the last {0} hours' -f $LookbackHours }
    $window = '{0} ({1:yyyy-MM-dd HH:mm} to {2:yyyy-MM-dd HH:mm} UTC)' -f $span, $startUtc, $endUtc
    $summary = [ordered]@{
        windowStartUtc = $startUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        windowEndUtc   = $endUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        lookbackHours  = $LookbackHours
        endpoint       = [string]$telemetry['connectionUri']
        database       = [string]$telemetry['database']
    }
    $record = {
        param([string] $CheckId, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation = '')
        New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl
    }

    if ($null -eq (Get-DemoValidatedAzContext -SubscriptionId $subscriptionId)) {
        return (& $record 'FABRIC.DASHBOARD.DATA' 'Fail' 'No validated Azure CLI context for the configured subscription, so no Kusto token was requested and no tile was checked.' $summary 'Run the subscription guard first: Assert-DemoAzContext -SubscriptionId <subscriptionId> -TenantId <tenantId> -Account <azureAccount> (configure-fabric.ps1 and deploy.ps1 do), then run the check again.')
    }
    if (-not $Definition) {
        $Definition = Get-DemoFabricDashboardDefinition -Config $Config
    }
    $document = $Definition.Content | ConvertFrom-Json -AsHashtable -Depth 64
    $names = Get-DemoDashboardSpecName
    $queries = @{}
    foreach ($query in @($document['queries'])) {
        $queries[([string]$query['id']).ToLowerInvariant()] = $query
    }
    $pages = @{}
    foreach ($page in @($document['pages'])) {
        $pages[([string]$page['id']).ToLowerInvariant()] = [string]$page['name']
    }

    $results = @{}
    $probes = @{}
    $state = $null
    $tileResults = [System.Collections.Generic.List[object]]::new()
    $textTiles = 0
    $position = 0
    foreach ($tile in @($document['tiles'])) {
        $position++
        $queryRef = $tile['queryRef']
        if ($queryRef -isnot [System.Collections.IDictionary]) {
            $textTiles++
            continue
        }
        $tileId = ([string]$tile['id']).ToLowerInvariant()
        $queryId = ([string]$queryRef['queryId']).ToLowerInvariant()
        $title = [string]$tile['title']
        $name = $names.Tiles[$tileId]
        $suffix = if ($name) { '{0}.{1}' -f $name.Page, $name.Key } else { 'TILE{0}' -f $position }
        $checkId = 'FABRIC.DASHBOARD.TILE.' + ($suffix.ToUpperInvariant() -replace '[^A-Z0-9.]', '_')
        $evidence = [ordered]@{
            tile  = $title
            page  = [string]$pages[([string]$tile['pageId']).ToLowerInvariant()]
            query = if ($names.Queries.ContainsKey($queryId)) { $names.Queries[$queryId] } else { $queryId }
        }
        $query = $queries[$queryId]
        if ($null -eq $query) {
            $tileResults.Add((& $record $checkId 'Fail' ("Tile '{0}' refers to a query that isn't in the definition." -f $title) $evidence 'Rebuild the definition with Export-DemoRealTimeDashboard and import it again.'))
            continue
        }

        if (-not $results.ContainsKey($queryId)) {
            $binding = Get-DemoDashboardBinding -StartUtc $startUtc -EndUtc $endUtc -Variable @($query['usedVariables'])
            $text = (@($binding, [string]$query['text']) | Where-Object { $_ }) -join "`n"
            $results[$queryId] = Invoke-DemoHubTelemetryQuery -SubscriptionId $subscriptionId -Query $text -TimeoutSeconds $TimeoutSeconds -MaxAttempts 2
        }
        $result = $results[$queryId]
        $rows = @($result.Rows).Count
        $columns = @(Get-DemoDashboardTileColumn -Tile $tile)
        $evidence['rows'] = $rows
        $evidence['durationSeconds'] = $result.DurationSeconds
        $evidence['requiredColumns'] = $columns

        if (-not $result.Succeeded) {
            $evidence['errorKind'] = $result.ErrorKind
            $evidence['statusCode'] = $result.StatusCode
            $transient = $result.ErrorKind -in 'PartialFailure', 'Throttled', 'Unavailable', 'Network'
            $fix = switch ($result.ErrorKind) {
                'BadRequest' { 'Run the tile''s query in the Azure Data Explorer web UI against {0} (database {1}) to see the error; fix the spec or the KQL in scripts/modules/DbHubDemo/Kql, run Export-DemoRealTimeDashboard, and import again. During the preview, a table or column can change.' -f $summary.endpoint, $summary.database }
                'Forbidden' { 'Get Reader (or higher) on the subscription (prerequisite P8; Contributors have it), and register the Microsoft.Sql resource provider.' }
                { $_ -in 'Unauthorized', 'Token' } { 'Sign in once with ''az login --tenant <tenantId>'' as the account that runs the demo (you don''t need to change the default subscription), run the subscription guard, and run the check again.' }
                default { 'Run the check again in a few minutes. If it keeps failing, check outbound HTTPS to the telemetry endpoint and the Learn page for endpoint changes.' }
            }
            $status = if ($transient) { 'Warning' } else { 'Fail' }
            $tileResults.Add((& $record $checkId $status ("The query of tile '{0}' didn't complete ({1}): {2}" -f $title, $result.ErrorKind, $result.Error) $evidence $fix))
            continue
        }

        if ($rows -gt 0) {
            $missing = @($columns | Where-Object { @($result.Columns) -cnotcontains $_ })
            $evidence['columns'] = @($result.Columns)
            $states = ''
            if (@($result.Columns) -ccontains 'Target' -and @($result.Columns) -ccontains 'State') {
                # The status tiles show every target, with No data when one sent nothing: say which.
                $states = (@($result.Rows | ForEach-Object { '{0} {1}' -f $_.Target, $_.State }) -join ', ')
                $evidence['states'] = $states
            }
            if ($missing.Count -gt 0) {
                $evidence['missingColumns'] = $missing
                $tileResults.Add((& $record $checkId 'Fail' ("Tile '{0}' gets {1} row(s) for {2}, but not the column(s) it shows: {3}." -f $title, $rows, $window, ($missing -join ', ')) $evidence 'Align the tile''s visual options in fabric/realtime/dashboard.spec.psd1 with its query''s columns, run Export-DemoRealTimeDashboard, and import again.'))
            }
            else {
                $detail = if ($states) { ' Targets: {0}.' -f $states } else { '' }
                $tileResults.Add((& $record $checkId 'Pass' ("Tile '{0}' gets {1} row(s) for {2}, with the column(s) it shows.{3}" -f $title, $rows, $window, $detail) $evidence))
            }
            continue
        }

        # No rows: was there anything to show? Probe the tile's own source once per query.
        if (-not $probes.ContainsKey($queryId)) {
            $probeText = Get-DemoDashboardSourceProbe -QueryText ([string]$query['text'])
            $probes[$queryId] = if ($probeText) {
                Invoke-DemoHubTelemetryQuery -SubscriptionId $subscriptionId -Query ((Get-DemoDashboardBinding -StartUtc $startUtc -EndUtc $endUtc) + "`n" + $probeText) -TimeoutSeconds $TimeoutSeconds -MaxAttempts 2
            }
            else {
                $null
            }
        }
        $probe = $probes[$queryId]
        if ($null -eq $probe -or -not $probe.Succeeded) {
            $evidence['sourceRows'] = $null
            $why = if ($null -eq $probe) { 'its source couldn''t be derived from the query' } else { 'the probe of its source didn''t complete ({0})' -f $probe.ErrorKind }
            $tileResults.Add((& $record $checkId 'Warning' ("Tile '{0}' gets no rows for {1}, and {2}, so the reason isn't known." -f $title, $window, $why) $evidence 'Run the check again; if the tile stays empty while its targets run, open the dashboard and compare the tile with Database Hub''s Performance page.'))
            continue
        }
        $sourceRows = [ordered]@{}
        foreach ($row in @($probe.Rows)) {
            $sourceRows[[string]$row.Target] = [long]$row.Rows
        }
        $evidence['sourceRows'] = $sourceRows
        if ($sourceRows.Count -gt 0) {
            $listed = @(foreach ($key in $sourceRows.Keys) { '{0} ({1})' -f $key, $sourceRows[$key] }) -join ', '
            $tileResults.Add((& $record $checkId 'Fail' ("Tile '{0}' gets no rows for {1}, although its source has rows for {2} in the same window: the tile doesn't show data that exists." -f $title, $window, $listed) $evidence 'Run the tile''s query in the Azure Data Explorer web UI against the telemetry endpoint, find the step that drops the rows, fix the KQL, run Export-DemoRealTimeDashboard, and import again.'))
            continue
        }

        if ($null -eq $state) {
            $state = Get-DemoDashboardTargetState -Config $Config
            $summary['targetState'] = [ordered]@{ T1 = $state.T1PowerState; T2 = $state.T2PowerState; T3 = $state.T3Status }
        }
        $evidence['targetState'] = $summary['targetState']
        $t3 = if ($state.T3Status) { '; T3''s database is {0}' -f $state.T3Status } else { '' }
        if (@($state.VmsStopped).Count -gt 0) {
            $evidence['reason'] = 'VmsNotRunning'
            $message = "Tile '{0}' gets no rows for {1}, because there's nothing to show: its source has no rows for the demo's targets in that window, and {2} {3} right now{4}. Phase 20's end-to-end run checks it again after a start." -f $title, $window, (@($state.VmsStopped) -join ' and '), $(if (@($state.VmsStopped).Count -gt 1) { 'aren''t running' } else { 'isn''t running' }), $t3
            $tileResults.Add((& $record $checkId 'Warning' $message $evidence 'Start the demo (./scripts/start-demo.ps1), let the activity run for a few minutes, and run the check again.'))
        }
        else {
            $evidence['reason'] = 'NoSourceRows'
            $message = "Tile '{0}' gets no rows for {1}, because there's nothing to show yet: its source has no rows for the demo's targets in that window, although the VMs run{2}. Telemetry arrives a few minutes after the activity." -f $title, $window, $t3
            $tileResults.Add((& $record $checkId 'Warning' $message $evidence 'Check TELEMETRY.T1-T3 (Test-DemoHubTelemetry), let the activity run, and run the check again.'))
        }
    }

    $stopwatch.Stop()
    $statuses = @($tileResults | ForEach-Object { $_.status })
    $counts = [ordered]@{
        Pass    = @($statuses | Where-Object { $_ -eq 'Pass' }).Count
        Warning = @($statuses | Where-Object { $_ -eq 'Warning' }).Count
        Fail    = @($statuses | Where-Object { $_ -eq 'Fail' }).Count
    }
    $summary['tiles'] = $tileResults.Count
    $summary['textTiles'] = $textTiles
    $summary['queries'] = $results.Count
    $summary['probes'] = @($probes.Values | Where-Object { $null -ne $_ }).Count
    $summary['pass'] = $counts.Pass
    $summary['warning'] = $counts.Warning
    $summary['fail'] = $counts.Fail
    $summary['durationSeconds'] = [System.Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)

    foreach ($item in $tileResults) {
        $item
    }
    if ($tileResults.Count -eq 0) {
        & $record 'FABRIC.DASHBOARD.DATA' 'Fail' 'The dashboard definition has no tile with a query, so nothing was checked.' $summary 'Rebuild the definition with Export-DemoRealTimeDashboard.'
        return
    }
    $overall = if ($counts.Fail -gt 0) { 'Fail' } elseif ($counts.Warning -gt 0) { 'Warning' } else { 'Pass' }
    $message = "Ran the KQL of {0} tile(s) of '{1}' ({2} queries) against the telemetry for {3}: {4} Pass, {5} Warning, {6} Fail." -f $tileResults.Count, $Definition.DisplayName, $results.Count, $window, $counts.Pass, $counts.Warning, $counts.Fail
    $fix = switch ($overall) {
        'Fail' { 'See the failed FABRIC.DASHBOARD.TILE records.' }
        'Warning' { 'See the FABRIC.DASHBOARD.TILE Warnings; Phase 20''s end-to-end run checks them again after a start.' }
        default { '' }
    }
    & $record 'FABRIC.DASHBOARD.DATA' $overall $message $summary $fix
}
