function Enable-DemoSqlVmMonitoring {
    <#
    .SYNOPSIS
    Turns on Database Hub performance monitoring for T1 (SQL Server on an Azure VM, preview) with the
    documented feature-flag merge, and returns the T1.SQLVM.MONITORING result.

    .DESCRIPTION
    Follows "Enable performance monitoring for SQL Server on Azure VMs"
    (https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm):
    1. Reads the SqlIaasExtension with its instance view (az vm extension show --instance-view), the VM's
       identity, and the Microsoft.Sql and Microsoft.AzureArcData registrations, through Invoke-DemoAz.
       Nothing is written while a prerequisite fails: extension 2.0.229.0 or later and Succeeded, a
       system-assigned identity, Microsoft.AzureArcData registered. An extension that's Updating or Creating
       (a template deployment keeps it Updating for about 10 minutes, Phase 13 live finding) is waited for
       within -WaitMinutes, then reported as a Warning, not a Fail.
    2. Unless DatabaseWatcheronAzureVM is already set with Enable true, merges it into the current public
       settings: the settings aren't cumulative, so every existing key and every other feature flag is kept
       (Merge-DemoSqlIaasFeatureFlag).
    3. Writes them back with the documented command, az vm extension set --publisher
       Microsoft.SqlServer.Management --name SqlIaaSAgent --extension-instance-name SqlIaasExtension
       --settings @<file>, with the file in a private temporary directory that's deleted afterward. A 409
       Conflict is retried.
    4. Waits up to -WaitMinutes for DatabaseMonitorArcPlugin to report State Running and MetricsUploadStatus
       OK, which takes about 3 to 15 minutes; with 0 it reports what it sees now. -WaitMinutes bounds the whole call in
       elapsed time, reads and the merge included (a read takes 15 to 20 seconds). While it waits, the console gets a
       line every few minutes and -ProgressPath's -ProgressStepId the wait's state (Phase 28 live finding, 2026-10-30).
       With -NotRunningGraceMinutes, the wait ends once the plugin has reported a state other than Running (NotRunning)
       for that long, at least 5 minutes when this call merged the flag (Get-DemoSqlVmPluginGrace), because a NotRunning
       plugin rarely starts by itself and the agent's restart does (the caller's Restore-DemoSqlVmMonitoringPlugin;
       live, 2026-10-30: the Monitoring step waited 20 minutes first, 25 with the reads).
    T1 also needs outbound HTTPS to telemetry.<region>.arcdataservices.com, which the NSG's HTTPS rule allows
    (ADR 0007). Under -WhatIf nothing is written.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER WaitMinutes
    How long to wait for the plugin to report Running and OK.

    .PARAMETER PollIntervalSeconds
    Seconds between reads while waiting.

    .PARAMETER NotRunningGraceMinutes
    0 (the default) waits the whole -WaitMinutes. Above 0, how long a plugin that reports a state other than Running
    is waited for before the wait ends, so the caller can restart the agent: deploy.ps1 passes 3 when the flag was
    set before the run, and 5 when the run merged it.

    .PARAMETER ProgressPath
    The status page's progress model, whose -ProgressStepId shows the wait; empty for none.

    .PARAMETER ProgressStepId
    The status page's step (T1.Monitoring).

    .EXAMPLE
    Enable-DemoSqlVmMonitoring -Config $config -WaitMinutes 15
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(0, 60)]
        [int] $WaitMinutes = 0,

        [ValidateRange(1, 600)]
        [int] $PollIntervalSeconds = 60,

        [ValidateRange(0, 60)]
        [int] $NotRunningGraceMinutes = 0,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [string] $ProgressStepId = 'T1.Monitoring'
    )

    # The whole wait counts elapsed time, reads and the merge included, and no sleep runs past its end: live (2026-10-30),
    # a 20-minute wait counted in reads took 25, because each read takes 15 to 20 seconds. Get-DemoUtcNow lets tests count
    # the reads' time.
    $startUtc = Get-DemoUtcNow
    $slept = 0
    $budget = $WaitMinutes * 60
    $state = Get-DemoSqlVmMonitoringState -Config $Config
    $setting = $state.Setting
    $flagName = [string]$setting['featureFlag']
    $actions = [System.Collections.Generic.List[string]]::new()
    $blocked = ConvertTo-DemoSqlVmMonitoringResult -State $state -PrerequisitesOnly
    # An extension that a template deployment is still updating is a wait (Phase 13 live finding).
    while ($null -ne $blocked -and [bool]$blocked.evidence['pending']) {
        $spent = [System.Math]::Max(((Get-DemoUtcNow) - $startUtc).TotalSeconds, $slept)
        if ($spent -ge $budget) {
            break
        }
        $pause = [int][System.Math]::Max(1, [System.Math]::Min($PollIntervalSeconds, [System.Math]::Ceiling($budget - $spent)))
        Start-Sleep -Seconds $pause
        $slept += $pause
        $state = Get-DemoSqlVmMonitoringState -Config $Config
        $blocked = ConvertTo-DemoSqlVmMonitoringResult -State $state -PrerequisitesOnly
    }
    if ($null -ne $blocked) {
        return $blocked
    }
    $extensionSettings = Get-DemoMemberValue -InputObject $state.Extension -Name 'settings'
    $flagSet = Test-DemoSqlIaasFeatureFlag -Settings $extensionSettings -Name $flagName

    if (-not $flagSet) {
        if (-not $PSCmdlet.ShouldProcess($state.VmName, ('Merge the {0} feature flag into the SqlIaasExtension settings' -f $flagName))) {
            return (New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status 'Not selected' -Message ('What if: the {0} feature flag was not written.' -f $flagName) -DocUrl 'https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm')
        }
        $merged = Merge-DemoSqlIaasFeatureFlag -Settings $extensionSettings -Name $flagName -Enable $true
        $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-sqlvm'
        try {
            $path = Write-DemoPrivateFile -Directory $directory -Name 'sqliaas-settings.json' -Content ($merged | ConvertTo-Json -Depth 50)
            $arguments = @(
                'vm', 'extension', 'set'
                '--resource-group', $state.ResourceGroupName
                '--vm-name', $state.VmName
                '--publisher', [string]$setting['publisher']
                '--name', [string]$setting['extensionName']
                '--extension-instance-name', [string]$setting['extensionInstanceName']
                '--settings', "@$path"
            )
            $set = Invoke-DemoAzWithConflictRetry -SubscriptionId $state.SubscriptionId -ArgumentList $arguments -Label ('{0}: merging {1}' -f $state.VmName, $flagName)
        }
        finally {
            Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
        }
        if ($set.ExitCode -ne 0) {
            return (New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status 'Fail' -Message ('Writing the {0} feature flag on {1} failed: {2}' -f $flagName, $state.VmName, (Protect-DemoText -Text ([string]$set.StdErr).Trim())) -Remediation 'Run configure-monitoring.ps1 again; a conflict with an extension that a policy installs clears within minutes.' -DocUrl 'https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm')
        }
        $otherSettings = @($merged.Keys | Where-Object { $_ -ne 'FeatureFlags' }).Count
        $otherFlags = @($merged['FeatureFlags']).Count - 1
        $actions.Add(('Merged {0} into the SqlIaasExtension public settings, keeping {1} other setting(s) and {2} other feature flag(s).' -f $flagName, $otherSettings, $otherFlags))
        Write-DemoLog -Message $actions[$actions.Count - 1]
        $state = Get-DemoSqlVmMonitoringState -Config $Config
    }

    $result = ConvertTo-DemoSqlVmMonitoringResult -State $state -Action $actions.ToArray()
    $graceMinutes = $NotRunningGraceMinutes
    if ($graceMinutes -gt 0 -and $actions.Count -gt 0) {
        # The setting takes a few minutes to apply after the merge.
        $graceMinutes = [System.Math]::Max($graceMinutes, [int](Get-DemoSqlVmPluginGrace).JustMerged)
    }
    $graceSeconds = $graceMinutes * 60
    $notRunningSince = -1.0
    $stoppedForRestart = $false
    $marker = $null
    while ([bool]$result.evidence['pending']) {
        $spent = [System.Math]::Max(((Get-DemoUtcNow) - $startUtc).TotalSeconds, $slept)
        if ($spent -ge $budget) {
            break
        }
        $pluginState = [string]$result.evidence['pluginState']
        $notRunning = $graceSeconds -gt 0 -and $pluginState -and $pluginState -ne 'Running'
        if (-not $notRunning) {
            $notRunningSince = -1.0
        }
        elseif ($notRunningSince -lt 0) {
            $notRunningSince = $spent
        }
        if ($notRunning -and $spent - $notRunningSince -ge $graceSeconds) {
            $stoppedForRestart = $true
            break
        }
        $end = if ($notRunning) { [System.Math]::Min($budget, $notRunningSince + $graceSeconds) } else { $budget }
        $restartIn = if ($notRunning) { [int][System.Math]::Ceiling(($end - $spent) / 60) } else { -1 }
        $marker = Show-DemoSqlVmPluginWait -State $pluginState -Minutes ([int][System.Math]::Floor($spent / 60)) -RestartInMinutes $restartIn -WaitLeftMinutes ([int][System.Math]::Ceiling(($budget - $spent) / 60)) -Marker $marker -ProgressPath $ProgressPath -ProgressStepId $ProgressStepId
        $pause = [int][System.Math]::Max(1, [System.Math]::Min($PollIntervalSeconds, [System.Math]::Ceiling($end - $spent)))
        Start-Sleep -Seconds $pause
        $slept += $pause
        $state = Get-DemoSqlVmMonitoringState -Config $Config
        $result = ConvertTo-DemoSqlVmMonitoringResult -State $state -Action $actions.ToArray()
    }
    if ($budget -gt 0) {
        $result.evidence['waitedSeconds'] = [int][System.Math]::Max(((Get-DemoUtcNow) - $startUtc).TotalSeconds, $slept)
    }
    if ($graceSeconds -gt 0) {
        $result.evidence['notRunningGraceMinutes'] = $graceMinutes
        $result.evidence['stoppedForRestart'] = $stoppedForRestart
    }
    return $result
}
