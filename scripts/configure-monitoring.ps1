#Requires -Version 7.4
<#
.SYNOPSIS
Turns on Database Hub performance monitoring for T1 and T2 and reports its state.

.DESCRIPTION
Runs the subscription guard first and stops if it doesn't pass; it never signs in or changes the Azure CLI
context. Then, for each selected target:
- T1 (SQL Server on Azure VM, preview): merges the documented DatabaseWatcheronAzureVM feature flag into the
  SQL IaaS Agent extension's current public settings (they aren't cumulative, so every existing setting is
  kept), writes them back with az vm extension set, and reports T1.SQLVM.MONITORING from the extension's
  instance view: DatabaseMonitorArcPlugin must show State Running and MetricsUploadStatus OK. Prerequisites
  (extension 2.0.229.0 or later, the VM's system-assigned identity, Microsoft.AzureArcData registered) are
  checked before anything is written. It also reports T1.SQLVM.ASSOCIATEDSERVICES, read-only: the database
  engine and the associated services (SSAS, SSIS) that unified inventory lists for T1.
- T2 (SQL Server enabled by Azure Arc): sets properties.monitoring.enabled = true on the sqlServerInstances
  resource (api-version 2023-09-01-preview) and reports T2.ARC.MONITORING. Developer mode reports Not
  supported.
- T3 (Azure SQL Database): its monitoring setting is the database's extended property
  MS_EnablePerformanceMonitoringPreview, which the T3 setup from T1 applies (database/azuresql, deploy.ps1's T3
  stage) and validate.ps1 checks (T3.PROPERTY); this script reports Not selected for T3 and points there.
Results go to the console and, as JSON lines, to -OutputPath.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER Target
The targets to configure: T1, T2, T3 (default: all).

.PARAMETER WaitMinutes
How long to wait for T1's monitoring plugin to report Running and OK (data usually appears within 3 to 15
minutes). 0 reports what it sees now.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.PARAMETER TreatManualAsError
Exit with code 2 when a result is Manual action required.

.EXAMPLE
./scripts/configure-monitoring.ps1 -Target T1, T2 -WaitMinutes 15
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidateSet('T1', 'T2', 'T3')]
    [string[]] $Target = @('T1', 'T2', 'T3'),

    [ValidateRange(0, 60)]
    [int] $WaitMinutes = 0,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/configure-monitoring.jsonl'),

    [switch] $TreatManualAsError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1') -Force

$config = Get-DemoConfig -Path $ConfigPath
$results = [System.Collections.Generic.List[object]]::new()
try {
    $results.Add((Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])))
}
catch {
    $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing ran. Fix the Azure CLI context yourself, then run configure-monitoring.ps1 again.'))
}

# Preference variables don't reach module functions, so -WhatIf is passed on explicitly.
$whatIf = [bool]$WhatIfPreference
if (@($results | Where-Object { $_.status -eq 'Fail' }).Count -eq 0) {
    if ('T1' -in $Target) {
        $results.Add((Enable-DemoSqlVmMonitoring -Config $config -WaitMinutes $WaitMinutes -WhatIf:$whatIf))
        # Read-only: the database engine and any associated services unified inventory lists for T1.
        $results.Add((Test-DemoSqlVmAssociatedService -Config $config))
    }
    if ('T2' -in $Target) {
        $results.Add((Enable-DemoArcSqlMonitoring -Config $config -WhatIf:$whatIf))
    }
    if ('T3' -in $Target) {
        $results.Add((New-DemoResult -CheckId 'T3.MONITORING' -Area 't3' -Target 'T3' -Status 'Not selected' -Message 'T3''s performance monitoring is its extended property MS_EnablePerformanceMonitoringPreview, which deploy.ps1''s T3 stage sets from T1; run deploy.ps1 -FromStage T3 to set it again, and validate.ps1 -Area T3 to check it (T3.PROPERTY).'))
    }
}

$results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
foreach ($item in $results | Where-Object { $_.status -in 'Fail', 'Manual action required' -and $_.remediation }) {
    Write-DemoLog -Level Warning -Message ('{0}: {1}' -f $item.checkId, $item.remediation)
}
Export-DemoResult -Result $results.ToArray() -Path $OutputPath
exit (Get-DemoExitCode -Result $results.ToArray() -TreatManualAsError:$TreatManualAsError)
