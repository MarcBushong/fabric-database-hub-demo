<#
.SYNOPSIS
Writes or clears the PaygWizard guided stop's request on the T2 host, then starts the bootstrap task (Phase 28, ADR 0006).

.DESCRIPTION
deploy.ps1 runs this script in a managed Run Command on archost01 when it starts waiting for a person at the guided
stop, and again (Clear) when it stops waiting: after setup, at its time limit, or when it's cancelled. While a request
is there and hasn't expired, the host's SqlSetupWizard step opens the pre-filled SQL Server setup in the guest, through
one automatic sign-in when nobody is signed in there; once the request expires or goes, the host's guard turns the
automatic sign-in off and cleans up within one run (vm/hyperv-guest/GuestSetup.ps1). The request holds a request ID, the
expiry, and the Azure extension's subscription, resource group, region, and tenant for setup's configuration file:
identifiers, never a secret. Windows PowerShell 5.1.

.PARAMETER Action
Set or Clear.

.PARAMETER RequestId
Letters, digits, and hyphens.

.PARAMETER ExpiresUtc
When the request expires, in UTC (ISO 8601).

.PARAMETER SubscriptionId
The Azure extension's subscription.

.PARAMETER ResourceGroup
The Azure extension's resource group.

.PARAMETER Region
The Azure extension's region.

.PARAMETER TenantId
The Azure extension's tenant.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.
#>
[CmdletBinding()]
param(
    [string] $Action = 'Set',

    [string] $RequestId = '',

    [string] $ExpiresUtc = '',

    [string] $SubscriptionId = '',

    [string] $ResourceGroup = '',

    [string] $Region = '',

    [string] $TenantId = '',

    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$exitCode = 1
$path = Join-Path -Path $Root -ChildPath 'guided-setup-request.json'

try {
    if ($Action -notin 'Set', 'Clear') {
        throw ('Unknown action {0}.' -f $Action)
    }
    if ($Action -eq 'Clear') {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Output 'DBHUBDEMO-GUIDEDSETUP cleared'
    }
    else {
        $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        if ($RequestId -notmatch '^[A-Za-z0-9-]{8,64}$') {
            throw 'RequestId is not valid.'
        }
        $expires = [datetime]::MinValue
        if (-not [datetime]::TryParse($ExpiresUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expires)) {
            throw 'ExpiresUtc is not a date.'
        }
        if ($SubscriptionId -and $SubscriptionId -notmatch $guid) {
            throw 'SubscriptionId is not valid.'
        }
        if ($TenantId -and $TenantId -notmatch $guid) {
            throw 'TenantId is not valid.'
        }
        if ($ResourceGroup -and $ResourceGroup -notmatch '^[A-Za-z0-9._()-]{1,90}$') {
            throw 'ResourceGroup is not valid.'
        }
        if ($Region -and $Region -notmatch '^[a-z0-9]{2,40}$') {
            throw 'Region is not valid.'
        }
        if (-not (Test-Path -LiteralPath $Root)) {
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
        }
        $request = [ordered]@{
            schemaVersion  = 1
            requestId      = $RequestId
            requestedUtc   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            expiresUtc     = $expires.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            subscriptionId = $SubscriptionId
            resourceGroup  = $ResourceGroup
            region         = $Region
            tenantId       = $TenantId
        }
        $temporary = $path + '.tmp'
        [System.IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $request -Compress), (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
        Move-Item -LiteralPath $temporary -Destination $path -Force
        Write-Output ('DBHUBDEMO-GUIDEDSETUP set until {0}' -f $request.expiresUtc)
    }
    # The host reacts now instead of at its next 5-minute run.
    Start-ScheduledTask -TaskName 'DbHubDemo-Bootstrap' -ErrorAction SilentlyContinue
    $exitCode = 0
}
catch {
    [Console]::Error.WriteLine(('The guided setup request failed: {0}' -f $_.Exception.Message))
}
exit $exitCode
