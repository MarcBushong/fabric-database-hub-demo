<#
.SYNOPSIS
Prints health.json in compact form for the validator (ADR 0012). Run it through Run Command on T1 or the
T2 host.

.DESCRIPTION
Run Command keeps only the last 4 KB of output, so steps are reduced to a name-to-status map. The file is
already redacted by the bootstrap. Windows PowerShell 5.1.

With -View Summary (Phase 7), only the fields the orchestrator gates on are printed: role, state, status,
the first 500 characters of message, currentStep, generation, updatedUtc, and from details the install mode,
Arc onboarding, the guest's state, and its SQL Server edition. Since Phase 28 it also prints the PaygWizard
guided stop's state (details.guidedSetup): whether automatic sign-in is armed in the guest, deploy.ps1's
request (none, valid, expired, or invalid), setup's sign-in preparation (none, preparing, ready, or restoring:
the WebView2 runtime, IE Enhanced Security Configuration off for administrators, and the Trusted sites entries;
deploy.ps1 asks for a person only at ready), the last cleanup's reason, and up to five problems it left. That
always fits in 4 KB, even when instructions are long.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.

.PARAMETER View
Full (default) or Summary.
#>
[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\DbHubDemo',

    [ValidateSet('Full', 'Summary')]
    [string] $View = 'Full'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$path = Join-Path -Path $Root -ChildPath 'health.json'
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Write-Output '{"schemaVersion":1,"state":"NotStarted","status":"Warning","message":"The bootstrap has not written health.json yet."}'
    return
}
$health = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
if ($View -eq 'Summary') {
    $read = {
        param($Object, [string[]] $Names)
        $value = $Object
        foreach ($name in $Names) {
            if ($null -eq $value) {
                return $null
            }
            $property = $value.PSObject.Properties[$name]
            if (-not $property) {
                return $null
            }
            $value = $property.Value
        }
        return $value
    }
    $message = [string](& $read $health @('message'))
    if ($message.Length -gt 500) {
        $message = $message.Substring(0, 500)
    }
    $summary = [ordered]@{
        schemaVersion = 1
        role          = & $read $health @('role')
        state         = & $read $health @('state')
        status        = & $read $health @('status')
        message       = $message
        currentStep   = & $read $health @('currentStep')
        generation    = & $read $health @('generation')
        updatedUtc    = & $read $health @('updatedUtc')
        installMode   = & $read $health @('details', 'installMode')
        arcOnboarded  = & $read $health @('details', 'arcOnboarded')
        guestState    = & $read $health @('details', 'guest', 'state')
        sqlEdition    = & $read $health @('details', 'guest', 'sql', 'edition')
        guidedArmed   = & $read $health @('details', 'guidedSetup', 'armed')
        guidedRequest = & $read $health @('details', 'guidedSetup', 'request')
        guidedSignIn  = & $read $health @('details', 'guidedSetup', 'signIn')
        guidedLast    = & $read $health @('details', 'guidedSetup', 'lastReason')
        guidedLeft    = @(& $read $health @('details', 'guidedSetup', 'lastProblems') | Where-Object { $_ } | Select-Object -First 5)
    }
    Write-Output (ConvertTo-Json -InputObject $summary -Compress -Depth 4)
    return
}
$steps = [ordered]@{}
foreach ($step in @($health.steps)) {
    $steps[[string]$step.name] = [string]$step.status
}
$health.steps = $steps
Write-Output ($health | ConvertTo-Json -Depth 10 -Compress)
