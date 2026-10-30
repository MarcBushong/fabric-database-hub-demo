#Requires -Version 7.4
<#
.SYNOPSIS
Onboards the T2 guest arcsql01 to Azure Arc and configures SQL Server enabled by Azure Arc (ADR 0005, ADR 0006).

.DESCRIPTION
Runs the subscription guard first and stops if it doesn't pass; it never signs in or changes the Azure CLI
context. Then, through managed Run Commands on the T2 host (Invoke-DemoArcConfiguration):
1. ProductKey mode: when the host waits in WaitingForProductKey, sends the SQL Server product key as a
   protected Run Command parameter only (prerequisite P10). The key comes from -ProductKey (a hidden prompt)
   or, in GitHub Actions, from the DBHUB_SQL_PRODUCT_KEY secret, which is removed from the environment as
   soon as it's read. It's redacted everywhere and never written on the operator side.
2. When the host waits in WaitingForArcOnboarding, onboards arcsql01. Whenever the least-privilege host
   identity id-<prefix>-<env>-arc-onboard is attached to archost01 (deploy.ps1 creates it when assignRoles is
   true), the host gets its own token from IMDS and yours isn't used. Otherwise your short-lived Azure
   Resource Manager token (about an hour) is passed only as a protected parameter; Run Command hands it to the
   host's PowerShell as an argument, where process auditing and endpoint protection can record it, and the
   sweep right after onboarding removes what it left (ADR 0009). An Arc machine left over from an earlier
   guest build is deleted first, its SQL Server instances before it, so a rebuild never leaves duplicates.
3. Converges the Azure extension for SQL Server, the PAYG license type, the sqlServerInstances resource, and
   monitoring. In PaygWizard mode the host then asks for the documented setup-wizard step (health.json has
   the instructions); run this script again after the wizard to finish the configuration.
4. Reports T2.ARC.CONNECTED, T2.ARC.NODUPLICATES, and T2.ARC.DISCONNECTEDDAYS.
Every step is re-runnable. Results go to the console and, as JSON lines, to -OutputPath.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER ProductKey
Prompt for the SQL Server product key (input hidden). ProductKey mode only.

.PARAMETER Force
Onboard even when the host doesn't wait for onboarding, for example to repair a connection after the host
finished. A stale Arc machine is still deleted before onboarding. In PaygWizard mode it also configures the
license type and monitoring without waiting for the host's setup check, so use it only when SQL Server Standard
already runs in arcsql01.

.PARAMETER UseHostIdentity
Require the host identity id-<prefix>-<env>-arc-onboard: fail when it isn't attached to archost01 instead of
using your token. It's used whenever it's attached anyway.

.PARAMETER UseCallerToken
Use your token even when the host identity is attached, for example while its role assignment is repaired.

.PARAMETER WaitForHostMinutes
Wait up to this long for the host to reach a state this script acts on (the guest build takes 60 to 90
minutes). 0 reads the host's state once.

.PARAMETER WaitMinutes
How long to wait for the Azure extension for SQL Server and the SQL Server instance resource.

.PARAMETER SkipConfiguration
Onboard only.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.PARAMETER TreatManualAsError
Exit with code 2 when a result is Manual action required.

.EXAMPLE
./scripts/configure-arc.ps1 -WaitForHostMinutes 120

.EXAMPLE
./scripts/configure-arc.ps1 -ProductKey -WaitForHostMinutes 180
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [switch] $ProductKey,

    [switch] $Force,

    [switch] $UseHostIdentity,

    [switch] $UseCallerToken,

    [ValidateRange(0, 360)]
    [int] $WaitForHostMinutes = 0,

    [ValidateRange(0, 120)]
    [int] $WaitMinutes = 15,

    [switch] $SkipConfiguration,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/configure-arc.jsonl'),

    [switch] $TreatManualAsError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1') -Force
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

$config = Get-DemoConfig -Path $ConfigPath

$secureKey = $null
if ($ProductKey) {
    $secureKey = Read-Host -AsSecureString -Prompt 'SQL Server product key (input is hidden)'
}
elseif (-not [string]::IsNullOrEmpty($env:DBHUB_SQL_PRODUCT_KEY)) {
    $plain = $env:DBHUB_SQL_PRODUCT_KEY
    Remove-Item -LiteralPath 'Env:DBHUB_SQL_PRODUCT_KEY' -ErrorAction SilentlyContinue
    Register-DemoSecret -Value $plain.Trim()
    $secureKey = [System.Security.SecureString]::new()
    foreach ($character in $plain.Trim().ToCharArray()) {
        $secureKey.AppendChar($character)
    }
    $secureKey.MakeReadOnly()
    $plain = $null
}

$parameters = @{
    Config             = $config
    Force              = $Force
    UseHostIdentity    = $UseHostIdentity
    UseCallerToken     = $UseCallerToken
    WaitForHostMinutes = $WaitForHostMinutes
    WaitMinutes        = $WaitMinutes
    SkipConfiguration  = $SkipConfiguration
    # Preference variables don't reach module functions, so -WhatIf is passed on explicitly.
    WhatIf             = [bool]$WhatIfPreference
}
if ($null -ne $secureKey) {
    $parameters['ProductKey'] = $secureKey
}
try {
    $results = @(Invoke-DemoArcConfiguration @parameters)
}
finally {
    if ($null -ne $secureKey) {
        $secureKey.Dispose()
    }
}

$results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
foreach ($item in $results | Where-Object { $_.status -in 'Fail', 'Manual action required' -and $_.remediation }) {
    Write-DemoLog -Level Warning -Message ('{0}: {1}' -f $item.checkId, $item.remediation)
}
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results -TreatManualAsError:$TreatManualAsError)
