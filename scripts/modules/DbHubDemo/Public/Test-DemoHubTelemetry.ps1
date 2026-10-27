function Test-DemoHubTelemetry {
    <#
    .SYNOPSIS
    Checks that each selected target sends Database Hub performance telemetry (TELEMETRY.T1, TELEMETRY.T2,
    TELEMETRY.T3), with row counts, the newest sample, and the lag.

    .DESCRIPTION
    Runs the ResourceSummary query (Get-DemoHubTelemetryKql) through Invoke-DemoHubTelemetryQuery: the
    documented telemetry REST endpoint, never a Hub route
    (https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry,
    checked 2026-10-20). Telemetry is keyed by ResourceID: the VM sqlvm01 for T1, the Arc machine arcsql01
    for T2, and the database ContosoCare on azuresql01-<deploymentId> for T3.

    Per target:
    - Pass: rows in the lookback, and the newest sample at most FreshMinutes old.
    - Warning: rows, but the newest sample is older (the target is stopped or paused, or the pipeline is
      late); or rows from the target arrive under a different ResourceID than expected.
    - Fail: no rows in the lookback, or the endpoint refused the call (HTTP 401 or 403: Reader on the
      subscription and the Microsoft.Sql resource provider are required).
    - Manual action required: the endpoint rejected the query (HTTP 400) or answered in an unexpected
      shape, which during the preview can mean the schema changed; verify against the doc.
    - Not supported: T2 in Developer mode, because Arc monitoring needs Standard or Enterprise edition.
    - Not selected: the target isn't in -Target.

    Telemetry takes 3 to 15 minutes to appear after monitoring is enabled. With -WaitMinutes, the query
    repeats every -PollSeconds until every selected target reports fresh rows or the wait ends; the number
    of polls is bounded. With -Detail, the evidence also lists the tables with rows, wait seconds per
    category (deltas of the cumulative wait counters), and the blocking and throughput counters.
    Retention is up to 7 days. Results in the evaluation-only T2 mode are labeled EVALUATION ONLY.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Target
    Targets to check. The others are reported as Not selected.

    .PARAMETER LookbackMinutes
    How far back to look for rows (at most 7 days).

    .PARAMETER FreshMinutes
    The oldest the newest sample can be for Pass.

    .PARAMETER WaitMinutes
    How long to keep polling for targets without fresh rows. 0 checks once.

    .PARAMETER PollSeconds
    Seconds between polls.

    .PARAMETER DeploymentId
    The deploymentId in T3's server name. Read from the resource group's deploymentId tag when omitted.

    .PARAMETER Detail
    Add table, wait-category, and counter evidence (four more queries).

    .EXAMPLE
    Test-DemoHubTelemetry -Config $config -WaitMinutes 15
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('T1', 'T2', 'T3')]
        [string[]] $Target = @('T1', 'T2', 'T3'),

        [ValidateRange(1, 10080)]
        [int] $LookbackMinutes = 60,

        [ValidateRange(1, 1440)]
        [int] $FreshMinutes = 15,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 0,

        [ValidateRange(10, 600)]
        [int] $PollSeconds = 60,

        [AllowEmptyString()]
        [string] $DeploymentId = '',

        [switch] $Detail
    )

    $telemetry = (Get-DemoHubSetting)['telemetry']
    $docUrl = [string]$telemetry['docUrl']
    $endpoint = [string]$telemetry['queryUrl']
    $evaluationOnly = [string]$Config['t2Mode'] -eq 'EvaluationOnlyAzureVm'
    $installMode = if ($Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'PaygWizard' }
    $region = ([string]$Config['location']).Replace(' ', '').ToLowerInvariant()
    $access = 'Querying needs Reader (or higher) on the subscription and the Microsoft.Sql resource provider registered (prerequisites P2 and P8), and an empty result never means a target is healthy.'
    $noRows = @{
        T1 = 'Enable performance monitoring on sqlvm01 with scripts/configure-monitoring.ps1 (the DatabaseWatcheronAzureVM flag of the SQL IaaS Agent extension 2.0.229.0 or later, which uses the VM''s system-assigned identity), make sure the VM is running and reaches telemetry.{0}.arcdataservices.com on port 443, then run again with -WaitMinutes 15.' -f $region
        T2 = 'Check the Arc SQL prerequisites with scripts/configure-arc.ps1 (Standard or Enterprise edition, pay-as-you-go or Software Assurance license type, Azure extension for SQL Server 1.1.2504.99 or later, monitoring enabled), make sure archost01 and its guest are running and the guest reaches *.{0}.arcdataservices.com on port 443, then run again with -WaitMinutes 15.' -f $region
        T3 = 'Set the MS_EnablePerformanceMonitoringPreview extended property on ContosoCare (scripts/configure-monitoring.ps1, or Enable Performance Monitoring on the Hub Estate page), make sure the database isn''t paused (run the warm-up), then run again with -WaitMinutes 15.'
    }

    $byTarget = [ordered]@{ T1 = $null; T2 = $null; T3 = $null }
    function Add-TargetResult([string] $Name, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation = '') {
        $byTarget[$Name] = New-DemoResult -CheckId ('TELEMETRY.{0}' -f $Name) -Area 'hub' -Target $Name -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl -EvaluationOnly:($Name -eq 'T2' -and $evaluationOnly)
    }

    $resolved = Resolve-DemoHubTarget -Config $Config -DeploymentId $DeploymentId -NeedT3:('T3' -in $Target)
    $active = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @($byTarget.Keys)) {
        $descriptor = $resolved.Targets[$name]
        if ($name -notin $Target) {
            Add-TargetResult $name 'Not selected' ('{0} ({1}) was not selected for this telemetry check.' -f $name, $descriptor.Name) @{}
        }
        elseif ($name -eq 'T2' -and $installMode -eq 'Developer') {
            Add-TargetResult 'T2' 'Not supported' 'T2 runs SQL Server Developer edition (t2SqlInstallMode Developer), and SQL Server enabled by Azure Arc sends performance telemetry only for Standard or Enterprise edition, so T2 appears in Estate but not in Performance.' @{ t2SqlInstallMode = $installMode } 'Use t2SqlInstallMode PaygWizard or ProductKey for Hub Performance on T2 (ADR 0006).'
        }
        elseif (-not $descriptor.ResourceId) {
            Add-TargetResult $name 'Fail' ('{0}''s resource ID is unknown, so its telemetry can''t be queried. {1}' -f $name, $descriptor.Error) @{} 'Run this check with -DeploymentId, or make sure the resource group carries its deploymentId tag (deploy.ps1 sets it).'
        }
        else {
            $active.Add($descriptor)
        }
    }

    if ($active.Count -gt 0) {
        $ids = @($active | ForEach-Object { $_.ResourceId })
        $kql = Get-DemoHubTelemetryKql -Name 'ResourceSummary' -ResourceId $ids -LookbackMinutes $LookbackMinutes -SubscriptionId $resolved.SubscriptionId -ResourceGroup $resolved.ResourceGroup
        $maxPolls = 1 + [int][System.Math]::Ceiling(($WaitMinutes * 60.0) / $PollSeconds)
        $started = Get-DemoHubUtcNow
        $deadline = $started.AddMinutes($WaitMinutes)
        $poll = 0
        $query = $null
        $summary = @{}
        $unmatched = @()
        $now = $started
        Write-DemoLog -Message ('Querying Database Hub performance telemetry for {0} (last {1} minutes).' -f (($active | ForEach-Object { $_.Target }) -join ', '), $LookbackMinutes)
        while ($true) {
            $poll++
            $query = Invoke-DemoHubTelemetryQuery -SubscriptionId $resolved.SubscriptionId -Query $kql
            $now = Get-DemoHubUtcNow
            $summary = @{}
            $unmatched = [System.Collections.Generic.List[object]]::new()
            foreach ($row in @($query.Rows)) {
                $rowId = [string](Get-DemoMemberValue -InputObject $row -Name 'ResourceID')
                $owner = $active | Where-Object { $_.ResourceId -ieq $rowId } | Select-Object -First 1
                if ($null -eq $owner) {
                    $unmatched.Add($row)
                    continue
                }
                $rowCount = [long](Get-DemoMemberValue -InputObject $row -Name 'Rows')
                $first = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $row -Name 'FirstSampleUTC')
                $last = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $row -Name 'LastSampleUTC')
                $instances = [long](Get-DemoMemberValue -InputObject $row -Name 'Instances')
                $entry = $summary[$owner.Target]
                if ($null -eq $entry) {
                    $summary[$owner.Target] = [pscustomobject]@{ Rows = $rowCount; First = $first; Last = $last; Instances = $instances }
                }
                else {
                    $entry.Rows += $rowCount
                    if ($null -ne $first -and ($null -eq $entry.First -or $first -lt $entry.First)) { $entry.First = $first }
                    if ($null -ne $last -and ($null -eq $entry.Last -or $last -gt $entry.Last)) { $entry.Last = $last }
                    $entry.Instances = [System.Math]::Max($entry.Instances, $instances)
                }
            }
            if (-not $query.Succeeded) {
                break
            }
            $pending = @($active | Where-Object {
                    $entry = $summary[$_.Target]
                    $null -eq $entry -or -not (Get-DemoTelemetryState -Rows $entry.Rows -LastSampleUtc $entry.Last -NowUtc $now -FreshMinutes $FreshMinutes).Fresh
                })
            if ($pending.Count -eq 0 -or $poll -ge $maxPolls -or $now -ge $deadline) {
                break
            }
            Write-DemoLog -Message ('No fresh telemetry yet from {0}; checking again in {1} seconds (until {2} UTC).' -f (($pending | ForEach-Object { $_.Target }) -join ', '), $PollSeconds, $deadline.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture))
            Start-Sleep -Seconds $PollSeconds
        }
        $waitedSeconds = [long][System.Math]::Max(0, ($now - $started).TotalSeconds)

        $details = @{}
        if ($Detail -and $query.Succeeded) {
            $details = Get-DemoHubTelemetryDetail -SubscriptionId $resolved.SubscriptionId -Target $active -LookbackMinutes $LookbackMinutes
        }

        foreach ($descriptor in $active) {
            $name = $descriptor.Target
            $entry = $summary[$name]
            $evidence = [ordered]@{
                resourceId      = $descriptor.ResourceId
                resourceType    = $descriptor.ResourceType
                rows            = if ($entry) { $entry.Rows } else { 0 }
                firstSampleUtc  = if ($entry -and $entry.First) { $entry.First.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { $null }
                lastSampleUtc   = if ($entry -and $entry.Last) { $entry.Last.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { $null }
                lagMinutes      = $null
                instances       = if ($entry) { $entry.Instances } else { 0 }
                lookbackMinutes = $LookbackMinutes
                freshMinutes    = $FreshMinutes
                measuredAtUtc   = $now.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
                polls           = $poll
                waitedSeconds   = $waitedSeconds
                endpoint        = $endpoint
                durationSeconds = $query.DurationSeconds
            }
            if ($details.Contains($name)) {
                foreach ($key in $details[$name].Keys) {
                    $evidence[$key] = $details[$name][$key]
                }
            }

            if (-not $query.Succeeded -and $query.ErrorKind -ne 'PartialFailure') {
                $evidence['errorKind'] = $query.ErrorKind
                $evidence['statusCode'] = $query.StatusCode
                switch ($query.ErrorKind) {
                    { $_ -in 'BadRequest', 'InvalidResponse' } {
                        Add-TargetResult $name 'Manual action required' ('The telemetry endpoint rejected or garbled the query for {0} ({1}): {2} During the preview this can mean a table or column name changed.' -f $name, $descriptor.Name, $query.Error) $evidence ('Compare the templates in scripts/modules/DbHubDemo/Kql with the schema on {0} (run "<table> | getschema" in the Azure Data Explorer web UI against https://adx.centralus.arcdataservices.com/kusto/), update them, and run again.' -f $docUrl)
                    }
                    'Forbidden' {
                        Add-TargetResult $name 'Fail' ('The telemetry endpoint denied access for {0} ({1}): {2}' -f $name, $descriptor.Name, $query.Error) $evidence ('Get Reader (or higher) on subscription {0} (prerequisite P8; Contributors have it) and register the provider: az provider register --namespace Microsoft.Sql --subscription {0}' -f $resolved.SubscriptionId)
                    }
                    { $_ -in 'Unauthorized', 'Token' } {
                        Add-TargetResult $name 'Fail' ('No valid token for the telemetry endpoint, so {0} ({1}) could not be checked: {2}' -f $name, $descriptor.Name, $query.Error) $evidence ('Sign in with ''az login --tenant {0}'' and run again; the token audience is {1}.' -f $Config['tenantId'], $telemetry['tokenAudience'])
                    }
                    default {
                        Add-TargetResult $name 'Fail' ('The telemetry endpoint could not be queried for {0} ({1}): {2}' -f $name, $descriptor.Name, $query.Error) $evidence ('Check outbound HTTPS to {0} and run again. If it keeps failing, check {1} for endpoint changes.' -f ([uri]$endpoint).Host, $docUrl)
                    }
                }
                continue
            }

            $state = if ($entry) { Get-DemoTelemetryState -Rows $entry.Rows -LastSampleUtc $entry.Last -NowUtc $now -FreshMinutes $FreshMinutes } else { [pscustomobject]@{ Status = 'Fail'; LagMinutes = $null; Fresh = $false } }
            $evidence['lagMinutes'] = $state.LagMinutes
            $partial = ''
            if ($query.ErrorKind -eq 'PartialFailure') {
                $evidence['errorKind'] = 'PartialFailure'
                $partial = ' The query failed partway, so the counts may be incomplete.'
            }

            if ($state.Status -eq 'Pass') {
                $status = if ($partial) { 'Warning' } else { 'Pass' }
                Add-TargetResult $name $status ('{0} ({1}) sends performance telemetry: {2} CPU samples in the last {3} minutes, the newest {4} minutes ago.{5}' -f $name, $descriptor.Name, $entry.Rows, $LookbackMinutes, $state.LagMinutes, $partial) $evidence
            }
            elseif ($state.Status -eq 'Warning') {
                Add-TargetResult $name 'Warning' ('{0} ({1}) has telemetry, but the newest sample is {2} minutes old (the limit is {3}), so the target is stopped or paused, or the pipeline is late.{4}' -f $name, $descriptor.Name, $state.LagMinutes, $FreshMinutes, $partial) $evidence 'Start the target (start-demo.ps1) and run again with -WaitMinutes 15; new telemetry takes 3 to 15 minutes to appear.'
            }
            else {
                $lookalike = @($unmatched | Where-Object {
                        [string](Get-DemoMemberValue -InputObject $_ -Name 'ResourceType') -ieq $descriptor.ResourceType -and
                        [string](Get-DemoMemberValue -InputObject $_ -Name 'ResourceName') -ieq $descriptor.Name
                    } | Select-Object -First 1)
                if ($lookalike.Count -gt 0) {
                    $actualId = [string](Get-DemoMemberValue -InputObject $lookalike[0] -Name 'ResourceID')
                    $evidence['telemetryResourceId'] = $actualId
                    $evidence['rows'] = [long](Get-DemoMemberValue -InputObject $lookalike[0] -Name 'Rows')
                    Add-TargetResult $name 'Warning' ('Telemetry for {0} ({1}) arrives under the ResourceID {2}, not the expected one, so this check can''t confirm it.' -f $name, $descriptor.Name, $actualId) $evidence 'Record the ResourceID format in docs/implementation-report.md and update Resolve-DemoHubTarget to match it.'
                }
                else {
                    Add-TargetResult $name 'Fail' ('No performance telemetry from {0} ({1}) in the last {2} minutes.{3}' -f $name, $descriptor.Name, $LookbackMinutes, $partial) $evidence ('{0} {1}' -f $noRows[$name], $access)
                }
            }
        }
    }

    return @($byTarget.Values)
}
