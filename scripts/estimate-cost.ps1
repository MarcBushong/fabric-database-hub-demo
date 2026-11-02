#Requires -Version 7.4
<#
.SYNOPSIS
Estimates demo cost per profile from live Azure retail prices (ADR 0016).

.DESCRIPTION
Queries the public Azure Retail Prices API. For each profile it reports running cost per hour, one
demo-day session, idle cost per month, and a light-use month, and compares them with the ceilings in the
configuration. The monthly ceiling (monthlyCeilingUsd, 250 USD by default) is hard: a light-use month
above it is Fail and the script exits with code 1. A session above sessionCeilingUsd is a Warning.
Prices are list prices in USD on the day you run it: estimates, not quotes.

Microsoft Defender for Cloud: when the Azure CLI is already signed in to the configured subscription, the
script reads the subscription's Defender plans (az security pricing list, read-only) and includes the
plans that bill the demo's resources. Otherwise it continues without them and reports that the estimate
excludes Defender. It never signs in.

T3 free offer: when signed in, the script also checks whether the Azure SQL Database free offer is
available (Get-DemoT3FreeOfferStatus, read-only) and applies its monthly allowance. Otherwise T3 is priced
as regular serverless.

Network mode: pass -NetworkMode with the mode preflight resolved (the effectiveNetworkMode evidence of
PREFLIGHT.POLICY.SQLPUBLIC). Without it, a public or private value in the configuration is used, and auto
is assumed to resolve to private, the more expensive mode.

.PARAMETER ConfigPath
Demo configuration. If it doesn't exist, config/demo.config.example.json is used.

.PARAMETER ProfileName
Profile to estimate. Defaults to the profile in the configuration.

.PARAMETER AllProfiles
Estimate all three profiles.

.PARAMETER DemoHours
Hours in one demo-day session. Defaults to config/profiles.json.

.PARAMETER LightUseHoursPerMonth
Running hours in a light-use month. Defaults to config/profiles.json.

.PARAMETER NetworkMode
The effective network mode, public or private.

.PARAMETER Detailed
Show every priced component and its meter.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/estimate-cost.ps1 -AllProfiles -Detailed

.EXAMPLE
./scripts/estimate-cost.ps1 -NetworkMode private
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidateSet('lowest-cost', 'demo-day', 'enhanced-performance')]
    [string] $ProfileName,

    [switch] $AllProfiles,

    [ValidateRange(-1, 24)]
    [double] $DemoHours = -1,

    [ValidateRange(-1, 744)]
    [double] $LightUseHoursPerMonth = -1,

    [ValidateSet('public', 'private')]
    [string] $NetworkMode,

    [switch] $Detailed,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/estimate-cost.jsonl')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1') -Force
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-DemoLog -Level Warning -Message "No configuration at $ConfigPath; using config/demo.config.example.json."
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.example.json'
}
$config = Get-DemoConfig -Path $ConfigPath

# Defender plans, the T3 free offer, and the T2 golden snapshots are read only when the CLI is already signed
# in to the configured subscription.
$defenderPlans = $null
$t3UseFreeLimit = $null
$goldenSnapshots = @()
if ($config['subscriptionId'] -eq '00000000-0000-0000-0000-000000000000') {
    Write-DemoLog -Level Warning -Message 'The configuration has no subscription yet, so the estimate excludes Defender for Cloud and prices T3 as regular serverless.'
}
else {
    try {
        $null = Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])
        $defenderPlans = @(Get-DemoDefenderPlan -SubscriptionId $config['subscriptionId'])
        Write-DemoLog -Message ('Read {0} Defender for Cloud plans from the subscription (read-only).' -f $defenderPlans.Count)
        $freeOffer = Get-DemoT3FreeOfferStatus -Config $config
        $t3UseFreeLimit = [bool]$freeOffer.UseFreeLimit
        Write-DemoLog -Message ('T3 free offer: {0} ({1})' -f $freeOffer.Result.status, $freeOffer.Result.message)
        $goldenSnapshots = @(Get-DemoT2GoldenSnapshot -Config $config)
        Write-DemoLog -Message ('T2 golden snapshots in the golden resource group: {0} (ADR 0018).' -f $goldenSnapshots.Count)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The Defender for Cloud plans, the T3 free offer, or the golden snapshots weren''t read, so the estimate may exclude Defender and the snapshots and prices T3 as regular serverless. {0}' -f $_.Exception.Message)
    }
}

$profileNames = if ($AllProfiles) { @('lowest-cost', 'demo-day', 'enhanced-performance') } elseif ($ProfileName) { @($ProfileName) } else { @($config['profile']) }
$results = [System.Collections.Generic.List[object]]::new()
$summary = foreach ($name in $profileNames) {
    $parameters = @{ Config = $config; ProfileName = $name; DemoHours = $DemoHours; LightUseHoursPerMonth = $LightUseHoursPerMonth }
    if ($NetworkMode) {
        $parameters['NetworkMode'] = $NetworkMode
    }
    if ($null -ne $defenderPlans) {
        $parameters['DefenderPlans'] = $defenderPlans
    }
    if ($null -ne $t3UseFreeLimit) {
        $parameters['T3UseFreeLimit'] = $t3UseFreeLimit
    }
    $parameters['GoldenSnapshots'] = $goldenSnapshots
    $estimate = Get-DemoCostEstimate @parameters
    foreach ($result in $estimate.Results) {
        $results.Add($result)
    }
    if ($Detailed) {
        Write-Output "Profile $name"
        $estimate.Components | Format-Table -Property Name, Basis, Meter, UnitPrice, Quantity, Unit, Cost -AutoSize | Out-String -Width 240 | Write-Output
    }
    [pscustomobject]@{
        Profile            = $name
        'Running per hour' = $estimate.HourlyRunning
        'Bastion per hour' = $estimate.BastionHourly
        'Session'          = $estimate.SessionCost
        'Idle per month'   = $estimate.IdleMonthly
        'Light-use month'  = $estimate.LightUseMonthly
        'Defender session' = if ($estimate.DefenderIncluded) { $estimate.DefenderSession } else { 'excluded' }
        'Defender month'   = if ($estimate.DefenderIncluded) { $estimate.DefenderMonthly } else { 'excluded' }
        'T3 free offer'    = if ($estimate.T3FreeOffer) { 'yes' } elseif ($estimate.T3FreeOfferUnchecked) { 'unchecked' } else { 'no' }
    }
    $queriedOn = $estimate.QueriedOn
    $effectiveNetworkMode = $estimate.NetworkMode
    $networkModeAssumed = $estimate.NetworkModeAssumed
}

$summary | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
Write-DemoLog -Message "List prices in USD from the Azure Retail Prices API on $queriedOn for $($config['location']). Estimates, not quotes."
if ($networkModeAssumed) {
    Write-DemoLog -Level Warning -Message 'networkMode auto is not resolved, so the estimate assumes private mode. Pass -NetworkMode with the mode preflight resolved.'
}
else {
    Write-DemoLog -Message "Network mode: $effectiveNetworkMode."
}
$results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 200 | Write-Output
Export-DemoResult -Result $results.ToArray() -Path $OutputPath
exit (Get-DemoExitCode -Result $results.ToArray())
