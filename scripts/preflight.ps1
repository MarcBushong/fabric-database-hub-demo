#Requires -Version 7.4
<#
.SYNOPSIS
Checks every prerequisite before anything is deployed.

.DESCRIPTION
Runs the subscription guard, then checks the .NET SDK that builds the workload runner (the dotnet first on PATH,
in workload-generator, where global.json applies; unless -SkipRunner), P1-P6 (ADR 0008), the region, VM sizes and
nested-virtualization families, vCPU and public IP quota, a read-only inventory of the Azure Policy rules that apply
to the subscription, Azure Policy through a subscription what-if, and the cost estimate against the ceilings,
including the subscription's Defender for Cloud plans. The policy inventory resolves networkMode auto to
public or private; the result is in the evidence of PREFLIGHT.POLICY.SQLPUBLIC. Missing resource providers
are registered unless -SkipProviderRegistration is set; that is the only change preflight makes. It never
signs in: sign in yourself first with 'az login --tenant <tenantId>'. You don't need to change the Azure CLI's default subscription.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER SkipProviderRegistration
Report unregistered providers instead of registering them.

.PARAMETER SkipWhatIf
Skip the what-if policy check.

.PARAMETER SkipPolicyInventory
Skip the policy inventory. It reads every policy definition that applies to the subscription, one at a
time, which can take a few minutes in tenants with large policy sets. networkMode auto then resolves to
private, which works under any policy.

.PARAMETER PolicyCacheHours
Reuse the last complete policy inventory when it's at most this many hours old and the policy assignments
that apply to the subscription are unchanged (default 168, one week; the assignments are listed every time,
and the reused results say so). 0 reads every policy definition again.

.PARAMETER SkipRunner
Don't check the .NET SDK (PREFLIGHT.TOOLS.DOTNETSDK is Not selected), for a deployment with deploy.ps1 -SkipRunner,
which builds no workload runner.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/preflight.ps1 -ConfigPath ./config/demo.config.json
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [switch] $SkipProviderRegistration,

    [switch] $SkipWhatIf,

    [switch] $SkipPolicyInventory,

    [ValidateRange(0, 720)]
    [int] $PolicyCacheHours = 168,

    [switch] $SkipRunner,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/preflight.jsonl')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# This checkout's DbHubDemo, loaded again on every run, so a session that ran an earlier checkout's script doesn't keep
# that code (live finding, 2026-11-06). Not when the repository's own code runs this script (a DbHubDemo function,
# another script, or a test): it loaded the module already, and the module's state stays, such as the subscription
# guard's validated context, the redaction's registered values, or a test's mocks.
$entryRepoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..')).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$entryNested = $false
foreach ($entryFrame in @(Get-PSCallStack | Select-Object -Skip 1)) {
    $entryNested = $entryNested -or [bool]($entryFrame.ScriptName -and $entryFrame.ScriptName.StartsWith($entryRepoRoot, [System.StringComparison]::OrdinalIgnoreCase))
}
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1') -Force:(-not $entryNested)
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

$config = Get-DemoConfig -Path $ConfigPath
$results = @(Invoke-DemoPreflight -Config $config -SkipProviderRegistration:$SkipProviderRegistration -SkipWhatIf:$SkipWhatIf -SkipPolicyInventory:$SkipPolicyInventory -PolicyCacheHours $PolicyCacheHours -SkipRunner:$SkipRunner)

$results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
foreach ($item in $results | Where-Object { $_.status -in 'Fail', 'Manual action required' -and $_.remediation }) {
    Write-DemoLog -Level Warning -Message ('{0}: {1}' -f $item.checkId, $item.remediation)
}
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
