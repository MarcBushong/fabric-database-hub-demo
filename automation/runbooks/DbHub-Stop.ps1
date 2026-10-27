<#
.SYNOPSIS
The DbHub-Stop runbook (ADR 0020): the per-run auto-stop and the daily T4 safety stop. It never starts anything and
never uses Run Command.

.DESCRIPTION
Windows PowerShell 5.1 in Azure Automation, published by scripts/setup-activity-control.ps1 with
automation/runbooks/DbHubControl.Common.ps1 and the settings in place of the two markers below.

- Scope All: started by the one-time schedule dbhub-autostop, which DbHub-Control creates at each run's end plus
  10 minutes. It does exactly what Stop now does: removes that schedule, deallocates both VMs, and stops T4,
  through Azure Resource Manager only.
- Scope T4: started by the daily schedule dbhub-t4-safety-stop. It stops T4 only when it's running, because a stopped
  flexible server starts itself after 7 days (https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server).
  A cost guardrail, not an activity schedule.

When the demo resource group doesn't exist (destroyed) or can't be read, it logs that and exits cleanly. The job
output holds the log and one result line, 'DBHUB-STOP <json>'.

.PARAMETER Scope
All (the default) or T4.
#>
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('All', 'T4')]
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
    $result = [pscustomobject]@{ action = ('stop-' + $Scope.ToLowerInvariant()); status = 'Error'; message = (ConvertTo-DbHubSafeText -Text $_.Exception.Message) }
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
if ([string]$result.status -eq 'Error') {
    throw ('DbHub-Stop failed: {0}' -f $result.message)
}
