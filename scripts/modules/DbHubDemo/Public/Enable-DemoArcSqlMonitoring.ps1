function Enable-DemoArcSqlMonitoring {
    <#
    .SYNOPSIS
    Turns on SQL Server enabled by Azure Arc monitoring for T2 and returns the T2.ARC.MONITORING result
    (ADR 0006; configure-monitoring.ps1).

    .DESCRIPTION
    Sets properties.monitoring.enabled = true on T2's Microsoft.AzureArcData/sqlServerInstances resource with
    the documented command (az resource update --set properties.monitoring.enabled=true --api-version
    2023-09-01-preview, https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring) when it's off,
    then checks it and the documented prerequisites: extension 1.1.2504.99 or later, Standard or Enterprise,
    and license type PAYG or Paid. The server also needs egress to *.<region>.arcdataservices.com, which the
    host NAT and the NSG's HTTPS rule allow (ADR 0007). In Developer mode it changes nothing and reports Not
    supported. Telemetry rows are validated in Phase 9.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .EXAMPLE
    Enable-DemoArcSqlMonitoring -Config $config
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $target = Get-DemoArcTarget -Config $Config
    $expectation = Get-DemoArcExpectation -InstallMode $target.InstallMode
    $docUrl = $target.Setting.DocUrls['monitoring']
    try {
        $state = Get-DemoArcState -Config $Config
    }
    catch {
        return (New-DemoArcResult -CheckId 'T2.ARC.MONITORING' -Target $target -Status 'Fail' -Message ('Azure couldn''t be read: {0}' -f $_.Exception.Message) -DocUrl $docUrl)
    }
    if (-not $expectation.MonitoringSupported) {
        return (Test-DemoArcMonitoring -State $state)
    }
    $info = Get-DemoArcInstanceInfo -Instance @($state.HostedInstances)
    if ($null -ne $info -and -not $info.MonitoringEnabled) {
        if (-not $PSCmdlet.ShouldProcess($info.Name, 'Turn on SQL Server enabled by Azure Arc monitoring')) {
            return (New-DemoArcResult -CheckId 'T2.ARC.MONITORING' -Target $target -Status 'Not selected' -Message ('What if: monitoring for {0} was left off.' -f $info.Name) -DocUrl $docUrl)
        }
        try {
            Invoke-DemoArcMonitoringUpdate -Target $target -InstanceName $info.Name -Confirm:$false
            $state = Get-DemoArcState -Config $Config
        }
        catch {
            return (New-DemoArcResult -CheckId 'T2.ARC.MONITORING' -Target $target -Status 'Fail' -Message $_.Exception.Message -Remediation 'Run configure-monitoring.ps1 again; a conflict clears within minutes.' -DocUrl $docUrl)
        }
    }
    return (Test-DemoArcMonitoring -State $state)
}
