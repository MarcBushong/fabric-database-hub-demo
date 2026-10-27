#Requires -Version 7.4
<#
.SYNOPSIS
Checks every prerequisite before anything is deployed.

.DESCRIPTION
Runs the subscription guard, then checks P1-P6 (ADR 0008), the region, VM sizes and nested-virtualization
families, vCPU and public IP quota, a read-only inventory of the Azure Policy rules that apply to the
subscription, Azure Policy through a subscription what-if, and the cost estimate against the ceilings,
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

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/preflight.jsonl')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1') -Force

$config = Get-DemoConfig -Path $ConfigPath
$results = @(Invoke-DemoPreflight -Config $config -SkipProviderRegistration:$SkipProviderRegistration -SkipWhatIf:$SkipWhatIf -SkipPolicyInventory:$SkipPolicyInventory -PolicyCacheHours $PolicyCacheHours)

$results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
foreach ($item in $results | Where-Object { $_.status -in 'Fail', 'Manual action required' -and $_.remediation }) {
    Write-DemoLog -Level Warning -Message ('{0}: {1}' -f $item.checkId, $item.remediation)
}
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
