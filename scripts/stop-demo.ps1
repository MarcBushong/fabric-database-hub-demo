#Requires -Version 7.4
<#
.SYNOPSIS
Stops the demo's compute after a session (plan section 9.4, ADR 0016).

.DESCRIPTION
- Default: removes on-demand Bastion and then its public IP (also a public IP that an interrupted delete left
  behind), rotates the T2 host's one-time password, sets every activity profile to off so a later boot
  doesn't keep T3 awake, shuts the T2 guest down cleanly, and deallocates the T2 VM and sqlvm01. T3
  persists; serverless auto-pause stops its compute. T4, the PostgreSQL flexible server, is stopped; it
  starts on its own after seven days, and its storage and the Defender plans a tenant policy enables are
  billed while it's stopped (Phase 24, ADR 0019).
- -ParkT2: only the T2 side (its profile, the guest, and the host), for demos on T1 and T3.
- -RemoveBastionOnly: only Bastion and the password rotation; with -IfExpired, a Bastion host goes only after
  its expiry (the bastion-cleanup workflow), and a leftover public IP at once.
- A rotation needs the host running: on a deallocated host it reports Manual action required with the steps.
- -RemoveT3: also deletes T3 and its private endpoint, which stops its fixed monthly costs; the next
  start-demo.ps1 recreates it under the same names (about 10 more minutes).
- -SaveHistory (or fabric.saveHistoryOnStop): after the VMs stop, runs NB_DatabaseHub_LiveActivity on demand to save
  the session's history to the lakehouse, at most 15 minutes (STOP.FABRIC.SAVEHISTORY). Then, only with
  fabric.manageCapacity true, the Fabric capacity that start-demo.ps1 resumed is paused, never while that run is
  still going (STOP.FABRIC.CAPACITY). With the defaults, the capacity isn't called (Phase 26b, ADR 0023).

It never signs in: sign in first with 'az login --tenant <tenantId>'. You don't need to change the Azure CLI's default subscription.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER ParkT2
Stop only the T2 side.

.PARAMETER RemoveBastionOnly
Remove Bastion and rotate the host password, nothing else.

.PARAMETER IfExpired
With -RemoveBastionOnly: only after the Bastion's expiry tag.

.PARAMETER RemoveT3
Also delete T3.

.PARAMETER SaveHistory
Save the session's history with NB_DatabaseHub_LiveActivity first (at most 15 minutes), before the Fabric capacity is
paused. Not with -ParkT2 or -RemoveBastionOnly.

.PARAMETER SaveHistoryWindowMinutes
How far back the saved history goes (default 720).

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/stop-demo.ps1

.EXAMPLE
./scripts/stop-demo.ps1 -RemoveT3

.EXAMPLE
./scripts/stop-demo.ps1 -SaveHistory
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [switch] $ParkT2,

    [switch] $RemoveBastionOnly,

    [switch] $IfExpired,

    [switch] $RemoveT3,

    [switch] $SaveHistory,

    [ValidateRange(15, 10080)]
    [int] $SaveHistoryWindowMinutes = 720,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/stop-demo.jsonl')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

$config = Get-DemoConfig -Path $ConfigPath
$results = @(Stop-DemoEnvironment -Config $config -ParkT2:$ParkT2 -RemoveBastionOnly:$RemoveBastionOnly -IfExpired:$IfExpired -RemoveT3:$RemoveT3 -SaveHistory:$SaveHistory -SaveHistoryWindowMinutes $SaveHistoryWindowMinutes -WhatIf:([bool]$WhatIfPreference) -Confirm:$false)
if (@($results | Where-Object { $_.checkId -eq 'STOP.HOSTPASSWORD' -and $_.status -in 'Pass', 'Warning' }).Count -gt 0 -and (Get-Command -Name 'Set-Clipboard' -ErrorAction SilentlyContinue)) {
    # The one-time password may still be on this machine's clipboard; it's rotated now, but clear it anyway.
    try {
        Set-Clipboard -Value ' '
    }
    catch {
        Write-DemoLog -Level Warning -Message 'The clipboard could not be cleared.'
    }
}

Write-DemoResultReport -Result $results -Title 'stop-demo.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
