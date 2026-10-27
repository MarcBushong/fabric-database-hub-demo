function Test-DemoSqlVmMonitoring {
    <#
    .SYNOPSIS
    The read-only T1.SQLVM.MONITORING check for validate.ps1 (ADR 0012).

    .DESCRIPTION
    Reads the SqlIaasExtension with its instance view, the VM's identity, the Microsoft.Sql and
    Microsoft.AzureArcData registrations, and unified inventory, and reports Pass only when
    DatabaseMonitorArcPlugin shows State Running and MetricsUploadStatus OK
    (https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm).
    Changes nothing; Enable-DemoSqlVmMonitoring sets the feature flag.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .EXAMPLE
    Test-DemoSqlVmMonitoring -Config $config
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    try {
        $state = Get-DemoSqlVmMonitoringState -Config $Config
    }
    catch {
        return (New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status 'Fail' -Message ('Azure couldn''t be read: {0}' -f $_.Exception.Message) -DocUrl 'https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm')
    }
    return (ConvertTo-DemoSqlVmMonitoringResult -State $state)
}
