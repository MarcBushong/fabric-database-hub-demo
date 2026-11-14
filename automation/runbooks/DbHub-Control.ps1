<#
.SYNOPSIS
The DbHub-Control runbook (ADR 0020, ADR 0026): started only by its webhook, it validates the request against the
allow-lists, then runs a control session, runs, stops, or resets the demo's activity, or saves T4's metrics, and exits.

.DESCRIPTION
Windows PowerShell 5.1 in Azure Automation. scripts/setup-activity-control.ps1 publishes this file with
automation/runbooks/DbHubControl.Common.ps1 and the settings in place of the two markers below, so the published
runbook is self-contained; nothing it holds is secret. It calls Azure Resource Manager with the user-assigned
identity id-<prefix>-automation, whose roles are DbHub Demo Activity Operator at the demo resource group (A1) and
at the control account (A2), and DbHub Demo Session Writer at the control vault's two session secrets only (A4).

- session (the control notebook's Run all, ADR 0026): the showcase on every target, as a run is, for at most the
  showcase's maximum and before the VMs' next auto-shutdown. It also marks the demo busy until the auto-stop (so the
  nightly stop waits), creates T4's read replica once T4 is Ready (at T4's size or the next documented size Azure
  accepts), plans the replica-lag beat's windows, adds a backup auto-stop 30 minutes after the auto-stop, and writes
  each step, in plain words with its fix, to the control vault's session status for the notebook.
- run: refuses while another run is active; caps each activity's minutes at its scenario's maximum and before the
  VMs' next auto-shutdown; creates the one-time auto-stop schedule (and, for a run that uses sqlvm01, the monitoring
  re-checks that start DbHub-Monitor) before anything starts; starts the VMs (and T4) when they're stopped; and sets
  each target's activity profile through an asynchronous managed Run Command on each VM as soon as it runs (T4's once
  it's Ready, without holding back T1 to T3). The VM-side control waits for each target to accept connections, and
  releases or starts T2's guest when it's off, before it sets the profile. Once sqlvm01 runs, the job looks after T1's
  monitoring plugin and restarts its agent when the plugin doesn't run. It doesn't wait for the Run Commands, and each
  profile ends on its own at the run's end.
- capture: saves T4's and its replica's Azure Monitor metrics for the session to the control vault's session metrics,
  which the notebook reads for the history.
- stop (Stop now; DbHub-Stop's auto-stop does the same): removes the auto-stop, saves a session's metrics first,
  deallocates both VMs, deletes T4's read replica (or stops it where the control can't delete it), and stops T4,
  through Azure Resource Manager only.
- reset: the runner's reset on the targets whose VM runs.

The job output holds the log and one result line, 'DBHUB-CONTROL <json>'. The webhook URL never reaches the runbook.
Webhooks: https://learn.microsoft.com/azure/automation/automation-webhooks

.PARAMETER WebhookData
Set by Azure Automation when the webhook starts the runbook: WebhookName, RequestBody, and RequestHeader. Only
RequestBody is read; the notebook sends no credential header.
#>
param(
    [Parameter(Mandatory = $false)]
    [object] $WebhookData
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
    $result = Invoke-DbHubControl -WebhookData $WebhookData -Context $context
}
catch {
    $result = [pscustomobject]@{ action = ''; status = 'Error'; message = (ConvertTo-DbHubSafeText -Text $_.Exception.Message) }
}
finally {
    if ($null -ne $context) {
        foreach ($line in $context.Log) {
            Write-Output $line
        }
        $context.Token = ''
    }
}
Write-Output ('DBHUB-CONTROL ' + ($result | ConvertTo-Json -Depth 6 -Compress))
if ([string]$result.status -eq 'Error') {
    throw ('DbHub-Control failed: {0}' -f $result.message)
}
