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
  10 minutes, and start-demo.ps1 creates for its session, 4 hours after its start by default (2026-11-19), and by
  ./scripts/stop-demo.ps1 during a Run all session (2026-11-22, -RequestedBy stop-demo.ps1). It does exactly what Stop now does: removes that schedule and the run's monitoring re-checks,
  deallocates both VMs, stops T4, and deletes T5's container, through Azure Resource Manager only. T5, the Azure Cosmos
  DB account (ADR 0027), has no stop, so its container, whose provisioned throughput bills every hour it exists, lives
  only during a session (2026-11-19): it's deleted when its lifecycle is Session (the demo resource group's
  DbHubT5Container tag), and otherwise kept, and the result says why. start-demo.ps1's auto-stop (its description begins
  with [start-demo.ps1]) waits for a deploy.ps1 run that's still going: it moves to 5 minutes after the run's busy marker,
  and its status is Deferred.
- Scope T4: started by the control's daily schedule dbhub-t4-safety-stop. It stops T4 only when it's running, because
  a stopped flexible server starts itself after 7 days
  (https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server). A cost guardrail, not an
  activity schedule. While sqlvm01 doesn't run, it also deletes T5's container, as a fallback for a night the safety
  stop couldn't (2026-11-19).
- Scope Nightly: started by the daily schedule dbhub-safety-stop at the VMs' auto-shutdown time, in every deployment.
  It deallocates each VM that isn't deallocated (their DevTest Labs auto-shutdown may hold them already), stops
  T4 when it runs, waiting up to 10 minutes for one that's starting, and deletes T5's container when a session's stop
  didn't (2026-11-19).
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

.PARAMETER RequestedBy
Who asked for a whole stop (Scope All; 2026-11-22): Auto-stop (the default: the one-time schedule dbhub-autostop or its
backup), or stop-demo.ps1, which hands a Run all session's stop to the session control through Job - Create
(https://learn.microsoft.com/rest/api/automation/job/create), so a re-check that's exporting the session's evidence stops
before this stop's export, as with Stop now. The session's status says who stopped it (stoppedBy), and stop-demo.ps1's
stop never waits for a deploy.ps1 run, which a person asked for now. Its result line has the stop's RCA lines (rcaLines),
which stop-demo.ps1 prints.
#>
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('All', 'T4', 'Nightly', 'T3Check')]
    [string] $Scope = 'All',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto-stop', 'stop-demo.ps1')]
    [string] $RequestedBy = 'Auto-stop'
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
    $result = Invoke-DbHubStop -Scope $Scope -Context $context -RequestedBy $RequestedBy
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
