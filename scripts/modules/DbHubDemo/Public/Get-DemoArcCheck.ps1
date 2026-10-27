function Get-DemoArcCheck {
    <#
    .SYNOPSIS
    The read-only T2 Arc checks for validate.ps1 and configure-arc.ps1 (ADR 0012).

    .DESCRIPTION
    Reads one snapshot of T2's Arc resources (az rest GET through Invoke-DemoAz: the machine, every Arc machine
    and SQL Server instance in the resource group, and the Azure extension for SQL Server) and returns one
    New-DemoResult record per check:
    - Connected (T2.ARC.CONNECTED): the machine arcsql01 exists and is Connected; Disconnected is a Warning
      while the host is stopped or just started.
    - NoDuplicates (T2.ARC.NODUPLICATES): exactly one Arc machine, arcsql01; every Arc-hosted SQL Server
      instance belongs to it; no instance name twice.
    - SqlExtension (T2.ARC.SQLEXTENSION): WindowsAgent.SqlServer is Succeeded, at version 1.1.2504.99 or
      later, with the license type the install mode expects (PAYG; PAYG or Paid in ProductKey mode).
    - SqlInstance (T2.ARC.SQLINSTANCE): the instance resource exists with the expected edition (Standard;
      Standard or Enterprise in ProductKey mode; Developer in Developer mode) and license type, with vCore,
      cores, and the billable-core estimate as evidence.
    - Monitoring (T2.ARC.MONITORING): properties.monitoring.enabled is true and the documented
      prerequisites hold; Not supported in Developer mode.
    - DisconnectedDays (T2.ARC.DISCONNECTEDDAYS): Warning at 21 days disconnected, a stronger Warning at 28,
      and Fail after 30, when pay-as-you-go lapses (ADR 0006).

    Before the PaygWizard setup-wizard step, the SQL checks report Manual action required. In the
    evaluation-only mode every result is labeled EVALUATION ONLY. If Azure can't be read, every requested
    check is a Fail with the reason.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Check
    The checks to run; all of them by default.

    .PARAMETER Now
    The current UTC time, for the disconnection thresholds.

    .EXAMPLE
    Get-DemoArcCheck -Config $config | Format-Table checkId, status, message
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('Connected', 'NoDuplicates', 'SqlExtension', 'SqlInstance', 'Monitoring', 'DisconnectedDays')]
        [string[]] $Check = @('Connected', 'NoDuplicates', 'SqlExtension', 'SqlInstance', 'Monitoring', 'DisconnectedDays'),

        [datetime] $Now = [datetime]::UtcNow
    )

    $ids = @{
        Connected        = 'T2.ARC.CONNECTED'
        NoDuplicates     = 'T2.ARC.NODUPLICATES'
        SqlExtension     = 'T2.ARC.SQLEXTENSION'
        SqlInstance      = 'T2.ARC.SQLINSTANCE'
        Monitoring       = 'T2.ARC.MONITORING'
        DisconnectedDays = 'T2.ARC.DISCONNECTEDDAYS'
    }
    try {
        $state = Get-DemoArcState -Config $Config -IncludeHostPowerState:('Connected' -in $Check)
    }
    catch {
        $target = Get-DemoArcTarget -Config $Config
        $message = 'Azure couldn''t be read: {0}' -f $_.Exception.Message
        foreach ($name in $Check) {
            New-DemoArcResult -CheckId $ids[$name] -Target $target -Status 'Fail' -Message $message -Remediation 'Check the subscription guard and that Microsoft.HybridCompute and Microsoft.AzureArcData are registered (preflight), then run the checks again.'
        }
        return
    }
    foreach ($name in $Check) {
        switch ($name) {
            'Connected' { Test-DemoArcConnected -State $state -Now $Now }
            'NoDuplicates' { Test-DemoArcNoDuplicate -State $state }
            'SqlExtension' { Test-DemoArcSqlExtension -State $state }
            'SqlInstance' { Test-DemoArcSqlInstance -State $state }
            'Monitoring' { Test-DemoArcMonitoring -State $state }
            'DisconnectedDays' { Test-DemoArcDisconnection -State $state -Now $Now }
        }
    }
}
