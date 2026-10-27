function Test-DemoT3Readiness {
    <#
    .SYNOPSIS
    The T3 readiness gate for warm-up: T3 is ready only when it's in Azure Resource Graph, its
    MS_EnablePerformanceMonitoringPreview extended property is set, and fresh telemetry rows arrive from the
    telemetry endpoint. Otherwise it reports a Warning with the measured lag.

    .DESCRIPTION
    T3 persists between demos, but 'stop-demo.ps1 -RemoveT3' deletes it and the next start or warm-up
    recreates it with the same names (coordinator decision, 2026-10-20). A recreated database shows up in
    the Hub late, so warm-up runs this gate:
    (a) Azure Resource Graph lists the database (the Hub's inventory source), through the documented
        Resources API (https://learn.microsoft.com/rest/api/azureresourcegraph/resourcegraph/resources/resources).
    (b) The extended property MS_EnablePerformanceMonitoringPreview is set on ContosoCare
        (https://learn.microsoft.com/fabric/database/hub/add-sql). Phase 8 owns that check; pass it as
        -PerformanceMonitoringCheck, a script block that receives the configuration and returns $true or
        $false, or a DbHubDemo result record (status Pass means set). Without it, (b) is Manual action
        required with the T-SQL to run.
    (c) The telemetry endpoint returns rows for T3's ResourceID since the database was created, and the
        newest is at most FreshMinutes old (Test-DemoHubTelemetry's rule).

    Results: T3.READINESS.RESOURCEGRAPH, T3.READINESS.PERFPROPERTY, T3.READINESS.TELEMETRY, and
    T3.READINESS.GATE. The gate is Pass when all three hold, and a Warning otherwise. The measured lag is
    the time from the database's creation to its first telemetry sample; while no sample has arrived, it's
    the time since creation so far. The telemetry query reads the whole retention window (7 days), so rows
    from before the current database was created are counted too (priorSessionRows): T3's ResourceID is
    stable, which keeps earlier sessions queryable within retention.

    With -WaitMinutes, the gate repeats every -PollSeconds until T3 is ready or the wait ends; the number of
    polls is bounded. Returns Ready, LagMinutes, and Results.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER PerformanceMonitoringCheck
    Phase 8's check of the extended property (see the description).

    .PARAMETER DeploymentId
    The deploymentId in T3's server name. Read from the resource group's deploymentId tag when omitted.

    .PARAMETER WaitMinutes
    How long to keep polling. 0 checks once.

    .PARAMETER PollSeconds
    Seconds between polls.

    .PARAMETER FreshMinutes
    The oldest the newest sample can be.

    .EXAMPLE
    (Test-DemoT3Readiness -Config $config -WaitMinutes 30 -PerformanceMonitoringCheck { param($c) Test-MyT3Property $c }).Results
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [scriptblock] $PerformanceMonitoringCheck,

        [AllowEmptyString()]
        [string] $DeploymentId = '',

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 0,

        [ValidateRange(10, 600)]
        [int] $PollSeconds = 60,

        [ValidateRange(1, 1440)]
        [int] $FreshMinutes = 15
    )

    $settings = Get-DemoHubSetting
    $telemetryDoc = [string]$settings['telemetry']['docUrl']
    $graphDoc = [string]$settings['resourceGraph']['docUrl']
    $propertyDoc = 'https://learn.microsoft.com/fabric/database/hub/add-sql'
    $retentionMinutes = [int]$settings['telemetry']['retentionDays'] * 1440
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $propertyCheck = "SELECT name, value FROM sys.extended_properties WHERE class = 0 AND name = N'MS_EnablePerformanceMonitoringPreview';"

    $resolved = Resolve-DemoHubTarget -Config $Config -DeploymentId $DeploymentId -NeedT3
    $t3 = $resolved.Targets['T3']
    $estateQuery = Format-DemoKqlTemplate -Name 'ResourceGraph.Estate' -Parameters @{
        SubscriptionId = ConvertTo-DemoKqlLiteral -Value $resolved.SubscriptionId -Type String
        ResourceGroup  = ConvertTo-DemoKqlLiteral -Value $resolved.ResourceGroup -Type String
    }

    function Invoke-PropertyCheck([scriptblock] $Check, [System.Collections.IDictionary] $Settings) {
        if ($null -eq $Check) {
            return [pscustomobject]@{ State = 'NoCheck'; Detail = '' }
        }
        try {
            $outcome = @(& $Check $Settings)
        }
        catch {
            return [pscustomobject]@{ State = 'Error'; Detail = (Protect-DemoText -Text $_.Exception.Message) }
        }
        $last = $outcome | Select-Object -Last 1
        if ($last -is [bool]) {
            return [pscustomobject]@{ State = $(if ($last) { 'Set' } else { 'NotSet' }); Detail = '' }
        }
        $status = [string](Get-DemoMemberValue -InputObject $last -Name 'status')
        if ($status) {
            return [pscustomobject]@{ State = $(if ($status -eq 'Pass') { 'Set' } else { 'NotSet' }); Detail = [string](Get-DemoMemberValue -InputObject $last -Name 'message') }
        }
        return [pscustomobject]@{ State = 'Unknown'; Detail = 'The check returned neither $true or $false nor a result record.' }
    }

    $maxPolls = 1 + [int][System.Math]::Ceiling(($WaitMinutes * 60.0) / $PollSeconds)
    $started = Get-DemoHubUtcNow
    $deadline = $started.AddMinutes($WaitMinutes)
    $now = $started
    $poll = 0
    $graph = $null
    $database = $null
    $databaseId = $t3.ResourceId
    $serverName = $t3.ServerName
    $created = $null
    $property = [pscustomobject]@{ State = 'NoCheck'; Detail = '' }
    $query = $null
    $entry = $null
    $ready = $false
    $pending = @()
    while ($true) {
        $poll++

        # (a) Azure Resource Graph.
        $graph = Invoke-DemoHubResourceGraph -SubscriptionId $resolved.SubscriptionId -Query $estateQuery
        if ($graph.Succeeded) {
            if (-not $serverName) {
                $servers = @($graph.Rows | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'type') -ieq 'microsoft.sql/servers' -and [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -like 'azuresql01-*' })
                if ($servers.Count -eq 1) {
                    $serverName = [string](Get-DemoMemberValue -InputObject $servers[0] -Name 'name')
                    $databaseId = '{0}/databases/ContosoCare' -f [string](Get-DemoMemberValue -InputObject $servers[0] -Name 'id')
                }
            }
            $database = $graph.Rows | Where-Object {
                [string](Get-DemoMemberValue -InputObject $_ -Name 'type') -ieq 'microsoft.sql/servers/databases' -and
                $databaseId -and [string](Get-DemoMemberValue -InputObject $_ -Name 'id') -ieq $databaseId
            } | Select-Object -First 1
            $created = if ($database) { ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $database -Name 'createdUtc') } else { $null }
        }

        # (b) The extended property, through Phase 8's check. Once it's set, it stays set.
        if ($property.State -ne 'Set') {
            $property = Invoke-PropertyCheck -Check $PerformanceMonitoringCheck -Settings $Config
        }

        # (c) Telemetry since the database was created, over the whole retention window.
        $query = $null
        $entry = $null
        if ($databaseId) {
            $windowStart = (Get-DemoHubUtcNow).AddMinutes(-$retentionMinutes)
            $since = if ($null -ne $created -and $created -gt $windowStart) { $created } else { $windowStart }
            $kql = Get-DemoHubTelemetryKql -Name 'ResourceSummary' -ResourceId $databaseId -LookbackMinutes $retentionMinutes -Since $since
            $query = Invoke-DemoHubTelemetryQuery -SubscriptionId $resolved.SubscriptionId -Query $kql
            $match = @($query.Rows | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'ResourceID') -ieq $databaseId })
            if ($match.Count -gt 0) {
                $entry = [pscustomobject]@{
                    Rows       = [long](($match | ForEach-Object { [long](Get-DemoMemberValue -InputObject $_ -Name 'Rows') } | Measure-Object -Sum).Sum)
                    RowsSince  = [long](($match | ForEach-Object { [long](Get-DemoMemberValue -InputObject $_ -Name 'RowsSince') } | Measure-Object -Sum).Sum)
                    FirstSince = @($match | ForEach-Object { ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $_ -Name 'FirstSampleSinceUTC') } | Where-Object { $_ } | Sort-Object) | Select-Object -First 1
                    Last       = @($match | ForEach-Object { ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $_ -Name 'LastSampleUTC') } | Where-Object { $_ } | Sort-Object) | Select-Object -Last 1
                }
            }
        }
        $now = Get-DemoHubUtcNow
        $fresh = $false
        if ($entry -and $entry.RowsSince -gt 0) {
            $fresh = (Get-DemoTelemetryState -Rows $entry.RowsSince -LastSampleUtc $entry.Last -NowUtc $now -FreshMinutes $FreshMinutes).Fresh
        }

        $pending = @(
            if (-not $database) { 'Resource Graph' }
            if ($property.State -ne 'Set') { 'extended property' }
            if (-not $fresh) { 'telemetry' }
        )
        $ready = $pending.Count -eq 0
        if ($ready -or $poll -ge $maxPolls -or $now -ge $deadline) {
            break
        }
        Write-DemoLog -Message ('T3 isn''t ready yet (waiting for: {0}); checking again in {1} seconds.' -f ($pending -join ', '), $PollSeconds)
        Start-Sleep -Seconds $PollSeconds
    }

    # Measured lag: creation to the first telemetry sample, or creation to now while none has arrived.
    $lagMinutes = $null
    $lagNote = ''
    $retentionStart = $now.AddMinutes(-$retentionMinutes)
    if ($null -eq $created) {
        $lagNote = 'T3''s creation time is unknown, so the lag can''t be measured.'
    }
    elseif ($created -lt $retentionStart) {
        $lagNote = 'T3 was created before the 7-day retention window, so the lag from creation can''t be measured.'
    }
    elseif ($entry -and $entry.FirstSince) {
        $lagMinutes = [System.Math]::Round(($entry.FirstSince - $created).TotalMinutes, 1)
        $lagNote = 'The first telemetry sample arrived {0} minutes after T3 was created.' -f $lagMinutes
    }
    else {
        $lagMinutes = [System.Math]::Round(($now - $created).TotalMinutes, 1)
        $lagNote = 'No telemetry sample yet, {0} minutes after T3 was created.' -f $lagMinutes
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $display = if ($serverName) { 'ContosoCare on {0}' -f $serverName } else { 'ContosoCare on azuresql01-<deploymentId>' }
    $createdText = if ($created) { $created.ToString('o', $invariant) } else { $null }

    # (a)
    if (-not $graph.Succeeded) {
        $results.Add((New-DemoResult -CheckId 'T3.READINESS.RESOURCEGRAPH' -Area 'hub' -Target 'T3' -Status 'Warning' -Message ('Azure Resource Graph could not be queried for T3: {0}' -f $graph.Error) -Remediation 'Check that you can read the subscription (Reader or higher) and run the gate again.' -DocUrl $graphDoc))
    }
    elseif ($database) {
        $results.Add((New-DemoResult -CheckId 'T3.READINESS.RESOURCEGRAPH' -Area 'hub' -Target 'T3' -Status 'Pass' -Message ('T3 ({0}) is in Azure Resource Graph, the Hub''s inventory source.' -f $display) -Evidence ([ordered]@{ resourceId = $databaseId; createdUtc = $createdText; status = [string](Get-DemoMemberValue -InputObject $database -Name 'status') }) -DocUrl $graphDoc))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'T3.READINESS.RESOURCEGRAPH' -Area 'hub' -Target 'T3' -Status 'Warning' -Message ('T3 ({0}) isn''t in Azure Resource Graph yet. {1}' -f $display, $t3.Error).Trim() -Evidence ([ordered]@{ expectedResourceId = $databaseId }) -Remediation 'A new database takes a few minutes to appear in Resource Graph; after stop-demo.ps1 -RemoveT3, start-demo.ps1 recreates T3. Run the gate again with -WaitMinutes.' -DocUrl $graphDoc))
    }

    # (b)
    $propertyRemediation = "Set it with scripts/configure-monitoring.ps1 (T3), the Hub's Enable Performance Monitoring button, or the T-SQL on the add-sql page; check it on ContosoCare with: $propertyCheck"
    switch ($property.State) {
        'Set' {
            $results.Add((New-DemoResult -CheckId 'T3.READINESS.PERFPROPERTY' -Area 'hub' -Target 'T3' -Status 'Pass' -Message 'The MS_EnablePerformanceMonitoringPreview extended property is set on ContosoCare.' -Evidence @{ detail = $property.Detail } -DocUrl $propertyDoc))
        }
        'NoCheck' {
            $results.Add((New-DemoResult -CheckId 'T3.READINESS.PERFPROPERTY' -Area 'hub' -Target 'T3' -Status 'Manual action required' -Message 'The MS_EnablePerformanceMonitoringPreview extended property wasn''t checked, because no check was supplied (-PerformanceMonitoringCheck, from Phase 8).' -Remediation ('Run on ContosoCare as a T3 administrator and confirm the value is true: {0}' -f $propertyCheck) -DocUrl $propertyDoc))
        }
        'Unknown' {
            $results.Add((New-DemoResult -CheckId 'T3.READINESS.PERFPROPERTY' -Area 'hub' -Target 'T3' -Status 'Manual action required' -Message ('The extended property check returned an unexpected value: {0}' -f $property.Detail) -Remediation ('Run on ContosoCare and confirm the value is true: {0}' -f $propertyCheck) -DocUrl $propertyDoc))
        }
        'Error' {
            $results.Add((New-DemoResult -CheckId 'T3.READINESS.PERFPROPERTY' -Area 'hub' -Target 'T3' -Status 'Warning' -Message ('The extended property check failed: {0}' -f $property.Detail) -Remediation $propertyRemediation -DocUrl $propertyDoc))
        }
        default {
            $results.Add((New-DemoResult -CheckId 'T3.READINESS.PERFPROPERTY' -Area 'hub' -Target 'T3' -Status 'Warning' -Message 'The MS_EnablePerformanceMonitoringPreview extended property isn''t set on ContosoCare yet, so T3 sends no performance telemetry.' -Evidence @{ detail = $property.Detail } -Remediation $propertyRemediation -DocUrl $propertyDoc))
        }
    }

    # (c)
    $telemetryEvidence = [ordered]@{
        resourceId                = $databaseId
        createdUtc                = $createdText
        rowsSinceCreation         = if ($entry) { $entry.RowsSince } else { 0 }
        firstSampleSinceUtc       = if ($entry -and $entry.FirstSince) { $entry.FirstSince.ToString('o', $invariant) } else { $null }
        lastSampleUtc             = if ($entry -and $entry.Last) { $entry.Last.ToString('o', $invariant) } else { $null }
        priorSessionRows          = if ($entry) { [System.Math]::Max(0, $entry.Rows - $entry.RowsSince) } else { 0 }
        priorSessionRowsQueryable = [bool]($entry -and ($entry.Rows - $entry.RowsSince) -gt 0)
        lagMinutes                = $lagMinutes
        retentionDays             = [int]$settings['telemetry']['retentionDays']
        freshMinutes              = $FreshMinutes
    }
    if ($null -eq $query) {
        $results.Add((New-DemoResult -CheckId 'T3.READINESS.TELEMETRY' -Area 'hub' -Target 'T3' -Status 'Warning' -Message ('T3''s telemetry wasn''t queried, because its ResourceID is unknown. {0}' -f $t3.Error).Trim() -Evidence $telemetryEvidence -Remediation 'Pass -DeploymentId, or run the gate again once T3 is in Resource Graph.' -DocUrl $telemetryDoc))
    }
    elseif (-not $query.Succeeded -and $query.ErrorKind -ne 'PartialFailure') {
        $telemetryEvidence['errorKind'] = $query.ErrorKind
        $status = if ($query.ErrorKind -in 'BadRequest', 'InvalidResponse') { 'Manual action required' } else { 'Fail' }
        $remediation = if ($status -eq 'Fail') { 'You need Reader (or higher) on the subscription and the Microsoft.Sql provider registered, and a token from ''az login'' (prerequisites P2 and P8).' } else { 'Compare the KQL templates in scripts/modules/DbHubDemo/Kql with the schema on the telemetry doc, then run again.' }
        $results.Add((New-DemoResult -CheckId 'T3.READINESS.TELEMETRY' -Area 'hub' -Target 'T3' -Status $status -Message ('The telemetry endpoint could not be queried for T3: {0}' -f $query.Error) -Evidence $telemetryEvidence -Remediation $remediation -DocUrl $telemetryDoc))
    }
    elseif ($fresh) {
        $results.Add((New-DemoResult -CheckId 'T3.READINESS.TELEMETRY' -Area 'hub' -Target 'T3' -Status 'Pass' -Message ('T3 sends performance telemetry: {0} CPU samples since it was created. {1}' -f $entry.RowsSince, $lagNote) -Evidence $telemetryEvidence -DocUrl $telemetryDoc))
    }
    elseif ($entry -and $entry.RowsSince -gt 0) {
        $results.Add((New-DemoResult -CheckId 'T3.READINESS.TELEMETRY' -Area 'hub' -Target 'T3' -Status 'Warning' -Message ('T3 has telemetry since it was created, but the newest sample is older than {0} minutes, so it''s probably paused.' -f $FreshMinutes) -Evidence $telemetryEvidence -Remediation 'Run the warm-up workload to resume T3, then run the gate again with -WaitMinutes 15.' -DocUrl $telemetryDoc))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'T3.READINESS.TELEMETRY' -Area 'hub' -Target 'T3' -Status 'Warning' -Message ('No telemetry from T3 since it was created. {0}' -f $lagNote) -Evidence $telemetryEvidence -Remediation 'Telemetry takes 3 to 15 minutes after the extended property is set and the database is active; run the gate again with -WaitMinutes 15.' -DocUrl $telemetryDoc))
    }

    # The gate.
    $gateEvidence = [ordered]@{
        ready         = $ready
        pending       = $pending
        lagMinutes    = $lagMinutes
        createdUtc    = $createdText
        polls         = $poll
        waitedSeconds = [long][System.Math]::Max(0, ($now - $started).TotalSeconds)
        resourceId    = $databaseId
    }
    if ($ready) {
        $results.Add((New-DemoResult -CheckId 'T3.READINESS.GATE' -Area 'hub' -Target 'T3' -Status 'Pass' -Message ('T3 is ready for the demo: it''s in Resource Graph, performance monitoring is on, and telemetry is arriving. {0}' -f $lagNote) -Evidence $gateEvidence -DocUrl $telemetryDoc))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'T3.READINESS.GATE' -Area 'hub' -Target 'T3' -Status 'Warning' -Message ('T3 isn''t ready yet (waiting for: {0}). {1}' -f ($pending -join ', '), $lagNote) -Evidence $gateEvidence -Remediation 'Keep the warm-up running and run the gate again; a newly created T3 can show Hub and Database Agent findings late, so use a persistent T3 for agent-focused demos.' -DocUrl $telemetryDoc))
    }

    [pscustomobject]@{
        PSTypeName = 'DbHubDemo.T3Readiness'
        Ready      = $ready
        LagMinutes = $lagMinutes
        Results    = $results.ToArray()
    }
}
