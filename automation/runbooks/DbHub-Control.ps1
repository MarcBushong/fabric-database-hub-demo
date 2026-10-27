<#
.SYNOPSIS
The DbHub-Control runbook (ADR 0020): started only by its webhook, it validates the request against the
allow-lists, then runs, stops, or resets the demo's activity, and exits.

.DESCRIPTION
Windows PowerShell 5.1 in Azure Automation. scripts/setup-activity-control.ps1 publishes this file with
automation/runbooks/DbHubControl.Common.ps1 and the settings in place of the two markers below, so the published
runbook is self-contained; nothing it holds is secret. It calls Azure Resource Manager with the user-assigned
identity id-<prefix>-automation, whose only role is DbHub Demo Activity Operator at the demo resource group (A1) and
at the control account (A2).

- run: refuses while another run is active; caps each activity's minutes at its scenario's maximum and before the
  VMs' next auto-shutdown; creates the one-time auto-stop schedule before anything starts; starts the VMs (and T4)
  when they're stopped; and sets each target's activity profile through one asynchronous managed Run Command per VM.
  It doesn't wait for the Run Commands, and each profile ends on its own at the run's end.
- stop (Stop now): removes the auto-stop, deallocates both VMs, and stops T4, through Azure Resource Manager only.
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
