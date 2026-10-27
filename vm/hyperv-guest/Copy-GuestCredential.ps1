<#
.SYNOPSIS
Copies the arcsql01 Administrator password to the clipboard without displaying it (ADR 0009).

.DESCRIPTION
Run it on archost01 inside the Bastion session, as an administrator, for the PaygWizard setup-wizard step.
The password was generated on the host and is kept there with DPAPI (LocalMachine scope); it never leaves
the host and this script never prints it. At the guest's sign-in screen in Virtual Machine Connection, use
Clipboard > Type clipboard text. Run it again with -Clear when you're done.
The bootstrap copies this script to C:\ProgramData\DbHubDemo\Copy-GuestCredential.ps1.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.

.PARAMETER Clear
Clears the clipboard instead.

.EXAMPLE
C:\ProgramData\DbHubDemo\Copy-GuestCredential.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\DbHubDemo',

    [switch] $Clear
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Clear) {
    Set-Clipboard -Value ' '
    Write-Output 'The clipboard is cleared.'
    return
}

$secretPath = [System.IO.Path]::Combine($Root, 'protected', 'guest-administrator.bin')
if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
    throw 'The guest password does not exist yet. Wait until health.json shows the guest build has finished.'
}

Add-Type -AssemblyName 'System.Security'
$bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([System.IO.File]::ReadAllBytes($secretPath), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
Set-Clipboard -Value ([System.Text.Encoding]::UTF8.GetString($bytes))
[System.Array]::Clear($bytes, 0, $bytes.Length)
Write-Output 'The arcsql01 Administrator password is on the clipboard. In Virtual Machine Connection, use Clipboard > Type clipboard text at the sign-in screen. Run this script with -Clear afterward.'
