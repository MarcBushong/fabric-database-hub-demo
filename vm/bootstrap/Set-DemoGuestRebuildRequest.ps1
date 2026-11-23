<#
.SYNOPSIS
Writes the request to make the T2 guest again from Arc Jumpstart's image on the T2 host (reset-demo.ps1 -RebuildGuest,
2026-11-21).

.DESCRIPTION
reset-demo.ps1 -RebuildGuest runs this script in a managed Run Command on archost01, then deploy.ps1 -FromStage Artifacts.
The request (guest-rebuild-request.json) holds an ID, when it was asked for, and by what: identifiers, never a secret. The
deploy's bootstrap generation acts on it in the host's GuestSource step: it deletes the guest with its disk and records
(Remove-DemoHostGuest, which records the request's ID in guest-rebuild.json), and the image's steps make a new arcsql01,
unless a golden capture holds the guest or T2 runs a build mode, which the step refuses and notes. A request whose ID a
rebuild record carries is done. Writing the request changes nothing else. Windows PowerShell 5.1.

.PARAMETER RequestId
Letters, digits, and hyphens.

.PARAMETER RequestedBy
What asked for it, for the host's log.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.
#>
[CmdletBinding()]
param(
    [string] $RequestId = '',

    [string] $RequestedBy = 'reset-demo.ps1 -RebuildGuest',

    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$exitCode = 1
$path = Join-Path -Path $Root -ChildPath 'guest-rebuild-request.json'

try {
    if ($RequestId -notmatch '^[A-Za-z0-9-]{8,64}$') {
        throw 'RequestId is not valid.'
    }
    if ($RequestedBy -notmatch '^[A-Za-z0-9 ._/-]{1,80}$') {
        throw 'RequestedBy is not valid.'
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $request = [ordered]@{
        schemaVersion = 1
        id            = $RequestId
        requestedUtc  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        requestedBy   = $RequestedBy
    }
    $temporary = $path + '.tmp'
    [System.IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $request -Compress), (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
    Move-Item -LiteralPath $temporary -Destination $path -Force
    Write-Output ('DBHUBDEMO-GUESTREBUILD requested {0} at {1}' -f $request.id, $request.requestedUtc)
    $exitCode = 0
}
catch {
    [Console]::Error.WriteLine(('The guest rebuild request failed: {0}' -f $_.Exception.Message))
}
exit $exitCode
