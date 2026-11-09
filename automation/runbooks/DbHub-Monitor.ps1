<#
.SYNOPSIS
The DbHub-Monitor runbook (ADR 0020): T1's monitoring plugin, checked again while an on-demand run lasts. It never
starts or stops anything.

.DESCRIPTION
Windows PowerShell 5.1 in Azure Automation, published by scripts/setup-activity-control.ps1 with
automation/runbooks/DbHubControl.Common.ps1 and the settings in place of the two markers below.

DbHub-Control creates the one-time schedules dbhub-monitor-1, 2, ... every 30 minutes of a run that uses sqlvm01, each
linked to this runbook; they go with the run's auto-stop (Stop now, the auto-stop, the next run, stop-demo.ps1, and
start-demo.ps1 remove them). While the run's auto-stop is pending and sqlvm01 runs, it reads the SQL IaaS Agent
extension's instance view and, when the Database Hub monitoring plugin reports a state other than Running, or no
status for 5 minutes, restarts the SQL IaaS Agent service through an asynchronous managed Run Command, then reads it
again for up to 5 minutes, as start-demo.ps1 does. Live, the plugin stopped within 90 minutes after a start, and a run
lasts up to 120.

When the demo resource group doesn't exist, no run is active, or sqlvm01 doesn't run, it logs that and exits cleanly.
The job output holds the log and one result line, 'DBHUB-MONITOR <json>'.
#>
param()

$ErrorActionPreference = 'Stop'

$settingsJson = @'
__DBHUB_SETTINGS__
'@

# __DBHUB_COMMON__

$jobId = ''
$metadata = Get-Variable -Name 'PSPrivateMetadata' -ValueOnly -ErrorAction SilentlyContinue
if ($null -ne $metadata -and $null -ne $metadata.JobId) {
    $jobId = [string]$metadata.JobId.Guid
}
$context = $null
$result = $null
try {
    $context = Initialize-DbHubContext -Settings (ConvertFrom-DbHubSetting -Json $settingsJson) -JobId $jobId
    $result = Invoke-DbHubMonitor -Context $context
}
catch {
    $result = [pscustomobject]@{ action = 'monitor'; status = 'Error'; message = (ConvertTo-DbHubSafeText -Text $_.Exception.Message) }
}
finally {
    if ($null -ne $context) {
        foreach ($line in $context.Log) {
            Write-Output $line
        }
        $context.Token = ''
    }
}
Write-Output ('DBHUB-MONITOR ' + ($result | ConvertTo-Json -Depth 6 -Compress))
if ([string]$result.status -eq 'Error') {
    throw ('DbHub-Monitor failed: {0}' -f $result.message)
}
