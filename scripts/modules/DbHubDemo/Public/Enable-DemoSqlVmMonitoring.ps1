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
       OK, which takes about 3 to 15 minutes; with 0 it reports what it sees now.
    T1 also needs outbound HTTPS to telemetry.<region>.arcdataservices.com, which the NSG's HTTPS rule allows
    (ADR 0007). Under -WhatIf nothing is written.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER WaitMinutes
    How long to wait for the plugin to report Running and OK.

    .PARAMETER PollIntervalSeconds
    Seconds between reads while waiting.

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
        [int] $PollIntervalSeconds = 60
    )

    $state = Get-DemoSqlVmMonitoringState -Config $Config
    $setting = $state.Setting
    $flagName = [string]$setting['featureFlag']
    $actions = [System.Collections.Generic.List[string]]::new()
    $attempts = [int][System.Math]::Ceiling($WaitMinutes * 60 / $PollIntervalSeconds)
    $blocked = ConvertTo-DemoSqlVmMonitoringResult -State $state -PrerequisitesOnly
    # An extension that a template deployment is still updating is a wait (Phase 13 live finding).
    while ($null -ne $blocked -and [bool]$blocked.evidence['pending'] -and $attempts -gt 0) {
        $attempts--
        Start-Sleep -Seconds $PollIntervalSeconds
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
    for ($i = 0; $i -lt $attempts -and [bool]$result.evidence['pending']; $i++) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $state = Get-DemoSqlVmMonitoringState -Config $Config
        $result = ConvertTo-DemoSqlVmMonitoringResult -State $state -Action $actions.ToArray()
    }
    return $result
}
