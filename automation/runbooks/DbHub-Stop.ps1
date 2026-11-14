<#
.SYNOPSIS
The DbHub-Stop runbook: the on-demand control's per-run auto-stop and daily T4 safety stop (ADR 0020), and the nightly
safety stop and its T3 check (ADR 0024). It never starts anything, never uses Run Command, and never connects to a
database.

.DESCRIPTION
Windows PowerShell 5.1 in Azure Automation, with automation/runbooks/DbHubControl.Common.ps1 and the settings in place
of the two markers below. scripts/setup-activity-control.ps1 publishes it to the control's account, and deploy.ps1
publishes it to the nightly safety stop's own account in the demo resource group.

- Scope All: started by the one-time schedule dbhub-autostop, which DbHub-Control creates at each run's end plus
  10 minutes. It does exactly what Stop now does: removes that schedule and the run's monitoring re-checks,
  deallocates both VMs, and stops T4, through Azure Resource Manager only.
- Scope T4: started by the control's daily schedule dbhub-t4-safety-stop. It stops T4 only when it's running, because
  a stopped flexible server starts itself after 7 days
  (https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server). A cost guardrail, not an
  activity schedule.
- Scope Nightly: started by the daily schedule dbhub-safety-stop at the VMs' auto-shutdown time, in every deployment.
  It deallocates each VM that isn't deallocated (their DevTest Labs auto-shutdown may hold them already) and stops
  T4 when it runs, waiting up to 10 minutes for one that's starting.
- Scope T3Check: started by the daily schedule dbhub-safety-t3check after the stop. It reads T3's status through Azure
  Resource Manager only, which never resumes a paused serverless database
  (https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-monitor), and says whether it paused. Then it
  stops T4 when it runs, as Scope Nightly does: a T4 that Azure started again 7 days after a stop, just after the
  stop's time, doesn't run until the next evening (2026-11-09).

When the demo resource group doesn't exist (destroyed) or can't be read, it logs that and exits cleanly. The job
output holds the log and one result line, 'DBHUB-STOP <json>'. A Nightly or T3Check job that couldn't do its work
(status Partial or NotGranted) fails after that line, so the account's job history shows it.

Scope Nightly, T3Check, and T4 change nothing while the demo resource group's busy marker (DbHubBusyUntilUtc) is ahead,
by at most 3 hours: a deploy.ps1 run or a demo session that's still running sets it. Their status is then Deferred, and
the job completes. deploy.ps1 schedules a later pass, dbhub-safety-deferred, that stops everything once the marker has
expired, the same night (2026-11-14).

.PARAMETER Scope
All (the default), T4, Nightly, or T3Check.
#>
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('All', 'T4', 'Nightly', 'T3Check')]
    [string] $Scope = 'All'
)

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
    $result = Invoke-DbHubStop -Scope $Scope -Context $context
}
catch {
    $action = 'stop-' + $Scope.ToLowerInvariant()
    if ($Scope -eq 'T3Check') {
        $action = 'check-t3'
    }
    $result = [pscustomobject]@{ action = $action; status = 'Error'; message = (ConvertTo-DbHubSafeText -Text $_.Exception.Message) }
}
finally {
    if ($null -ne $context) {
        foreach ($line in $context.Log) {
            Write-Output $line
        }
        $context.Token = ''
    }
}
Write-Output ('DBHUB-STOP ' + ($result | ConvertTo-Json -Depth 6 -Compress))
if ([string]$result.status -eq 'Error' -or ($Scope -in 'Nightly', 'T3Check' -and [string]$result.status -in 'Partial', 'NotGranted')) {
    throw ('DbHub-Stop failed: {0}' -f $result.message)
}
