#Requires -Version 7.4
<#
.SYNOPSIS
Runs the live validation catalog and reports each check with the demo status model (ADR 0012).

.DESCRIPTION
Runs the subscription guard first and stops if it doesn't pass; it never signs in or changes the Azure CLI
context. Then it runs the selected areas through the module's checks (Invoke-DemoValidation): Preflight,
Infrastructure, T1, T2, T3, Hub, Telemetry, Workload, Cost, Security, and Teardown. The catalog is in
docs/adr/0012-validation-model.md.

It changes nothing in the demo. On running VMs, some checks read through Run Commands: temporary managed
Run Commands, deleted when they finish, and an action Run Command for the workload status. T3.PROPERTY's
query resumes a paused T3, which auto-pauses again. To stay strictly read-only while someone else runs a
VM, leave its target out with -Target.

Stopped resources are expected: a check that needs a running VM reports a Warning with the command to
start it while the VM is deallocated (the nightly auto-shutdown), never a Fail.

Every result is written as one JSON line to -OutputPath and printed in a summary table; the remediation
of each Fail, Warning, and Manual action required is logged. Output is redacted (Write-DemoLog,
Export-DemoResult). In GitHub Actions the results are added to the job summary.

Exit code: 1 when a result is Fail, or Manual action required with -TreatManualAsError; otherwise 0.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER Area
Areas to run: Preflight, Infrastructure, T1, T2, T3, T4, Hub, Telemetry, Workload, Cost, Security, Teardown.
All of them by default.

.PARAMETER Target
Targets whose checks run: T1, T2, T3, T4 (default: all).

.PARAMETER WaitMinutes
How long the telemetry checks keep polling for fresh rows (data appears 3 to 15 minutes after a target
starts). 0 checks once.

.PARAMETER OutputPath
Where to write the results as JSON lines (default: out/validate.jsonl).

.PARAMETER TreatManualAsError
Exit with code 1 when a result is Manual action required.

.PARAMETER ScanPath
More files or folders for the Security area's secret scan, besides out/: for example GitHub Actions logs
saved with 'gh run view <run-id> --log', or an exported notebook.

.PARAMETER DeploymentId
The environment's deploymentId. Read from the resource group's tag when omitted; after destroy.ps1, pass it
to -Area Teardown so resources tagged with it are found.

.PARAMETER FabricAdmin
You're a Fabric administrator, so the Hub tenant setting (P4) is read through the Fabric admin API.

.PARAMETER SkipPolicyInventory
Skip the Preflight area's policy inventory, which can take a few minutes in tenants with large policy sets.

.PARAMETER PolicyCacheHours
Let the Preflight area reuse the last complete policy inventory when it's at most this many hours old and the
policy assignments that apply to the subscription are unchanged (default 168; 0 reads everything again).

.EXAMPLE
./scripts/validate.ps1

.EXAMPLE
./scripts/validate.ps1 -Area Infrastructure, T1, T3, Telemetry -Target T1, T3 -WaitMinutes 15

.EXAMPLE
./scripts/validate.ps1 -Area Teardown -DeploymentId abc123
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidateSet('Preflight', 'Infrastructure', 'T1', 'T2', 'T3', 'T4', 'Hub', 'Telemetry', 'Workload', 'Cost', 'Security', 'Teardown')]
    [string[]] $Area = @('Preflight', 'Infrastructure', 'T1', 'T2', 'T3', 'T4', 'Hub', 'Telemetry', 'Workload', 'Cost', 'Security', 'Teardown'),

    [ValidateSet('T1', 'T2', 'T3', 'T4')]
    [string[]] $Target = @('T1', 'T2', 'T3', 'T4'),

    [ValidateRange(0, 120)]
    [int] $WaitMinutes = 0,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/validate.jsonl'),

    [switch] $TreatManualAsError,

    [string[]] $ScanPath = @(),

    [ValidatePattern('^$|^[a-z0-9]{6}$')]
    [string] $DeploymentId = '',

    [switch] $FabricAdmin,

    [switch] $SkipPolicyInventory,

    [ValidateRange(0, 720)]
    [int] $PolicyCacheHours = 168
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1') -Force

$config = Get-DemoConfig -Path $ConfigPath
$parameters = @{
    Config              = $config
    Area                = $Area
    Target              = $Target
    WaitMinutes         = $WaitMinutes
    ScanPath            = $ScanPath
    DeploymentId        = $DeploymentId
    FabricAdmin         = $FabricAdmin
    SkipPolicyInventory = $SkipPolicyInventory
    PolicyCacheHours    = $PolicyCacheHours
}
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$results = @(Invoke-DemoValidation @parameters)
$clock.Stop()

$results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
foreach ($item in $results | Where-Object { $_.status -in 'Fail', 'Warning', 'Manual action required' -and $_.remediation }) {
    Write-DemoLog -Level Warning -Message ('{0} ({1}): {2}' -f $item.checkId, $item.status, $item.remediation)
}
$statuses = @('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')
$summary = foreach ($status in $statuses) {
    [pscustomobject]@{ Status = $status; Checks = @($results | Where-Object { $_.status -eq $status }).Count }
}
$summary | Format-Table -AutoSize | Out-String -Width 120 | Write-Output
Write-DemoLog -Message ('{0} checks in {1:N0} seconds; results in {2}.' -f $results.Count, $clock.Elapsed.TotalSeconds, $OutputPath)
Export-DemoResult -Result $results -Path $OutputPath

# The contract with validate.yml (Phases 13 and 14): 1 for any Fail, and for Manual action required with
# -TreatManualAsError; Get-DemoExitCode returns 2 for the latter.
$exitCode = Get-DemoExitCode -Result $results -TreatManualAsError:$TreatManualAsError
exit ([int]($exitCode -ne 0))
