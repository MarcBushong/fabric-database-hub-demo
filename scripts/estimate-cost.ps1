#Requires -Version 7.4
<#
.SYNOPSIS
Estimates demo cost per profile from live Azure retail prices (ADR 0016).

.DESCRIPTION
Queries the public Azure Retail Prices API. For each profile it reports running cost per hour, one
demo-day session, idle cost per month, and a light-use month, and compares them with the ceilings in the
configuration. The monthly ceiling (monthlyCeilingUsd, 390 USD by default for a new configuration since 2026-11-19) is hard: a light-use month
above it is Fail and the script exits with code 1. A session above sessionCeilingUsd is a Warning.

T4's 7-day automatic restart: when signed in, the script also reads whether a safety stop is fully in place
(Get-DemoT4RestartCoverage, read-only): the nightly safety stop that every deployment sets up (its schedule, its role, and
its last run; ADR 0024), or the on-demand control's daily T4 safety stop. Then each restart counts as about a day;
otherwise, and when not signed in, the worst case counts the rest of the month.
T4's read replica (2026-11-13, ADR 0025) exists only during a session: start-demo.ps1 creates it and stop-demo.ps1 deletes
it, so its compute (at T4's size), storage, and Defender plans are in the running hours (the Replica session column), and
no automatic restart applies to it. A Burstable T4 has no replica.
T5, the Azure Cosmos DB account (2026-11-18, ADR 0027), has no stop, so its private endpoint and private DNS zone are in the
idle month. Its container exists only during a session since 2026-11-19, once the session control's role can create it: its
400 RU/s of throughput, its storage, and Defender for Azure Cosmos DB when its plan is on Standard are then in the running
hours. -T5ContainerLifecycle AlwaysOn prices the container all month, as while that role can't create it; when signed in and
without it, the script reads the environment's own lifecycle. When signed in, the script also reads whether T5 has, or would
get, the subscription's free tier (the first 1000 RU/s and 25 GB of one account per subscription), which prices its
throughput and storage at zero; otherwise they're at list price, an upper bound.
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

.PARAMETER T5ContainerLifecycle
When T5's container exists (2026-11-19, ADR 0027): Session, only during a session (start-demo.ps1 and Run all create it,
the stops delete it), or AlwaysOn, between sessions too, as while the session control's role can't create it. Without it,
the script reads the environment's own when signed in (the resource group's DbHubT5Container tag; AlwaysOn when it says so,
or when an existing environment doesn't have it yet), and assumes Session otherwise.

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

    [ValidateSet('Session', 'AlwaysOn')]
    [string] $T5ContainerLifecycle,

    [switch] $Detailed,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/estimate-cost.jsonl')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# This checkout's DbHubDemo, loaded again on every run, so a session that ran an earlier checkout's script doesn't keep
# that code (live finding, 2026-11-06). Not when the repository's own code runs this script (a DbHubDemo function,
# another script, or a test): it loaded the module already, and the module's state stays, such as the subscription
# guard's validated context, the redaction's registered values, or a test's mocks. $module is the module object this
# script imported, for the module's internal functions, which run in its scope (& $module { ... }; 2026-11-13: T4's
# restart coverage called them from the script, where they aren't visible, so a signed-in estimate never read it).
$entryRepoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..')).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$entryNested = $false
foreach ($entryFrame in @(Get-PSCallStack | Select-Object -Skip 1)) {
    $entryNested = $entryNested -or [bool]($entryFrame.ScriptName -and $entryFrame.ScriptName.StartsWith($entryRepoRoot, [System.StringComparison]::OrdinalIgnoreCase))
}
$module = Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1') -Force:(-not $entryNested) -PassThru
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-DemoLog -Level Warning -Message "No configuration at $ConfigPath; using config/demo.config.example.json."
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.example.json'
}
$config = Get-DemoConfig -Path $ConfigPath

# Defender plans, the T3 free offer, the T2 golden snapshots, and whether a safety stop covers T4's 7-day restart are read
# only when the CLI is already signed in to the configured subscription. Each read stands on its own (2026-11-13): one
# that fails says what it left out, and the others are still read.
$defenderPlans = $null
$t3UseFreeLimit = $null
$goldenSnapshots = @()
$t4RestartCoverage = $null
$t5FreeTier = $null
$t5Lifecycle = if ($T5ContainerLifecycle) { $T5ContainerLifecycle } else { '' }
if ($config['subscriptionId'] -eq '00000000-0000-0000-0000-000000000000') {
    Write-DemoLog -Level Warning -Message 'The configuration has no subscription yet, so the estimate excludes Defender for Cloud and prices T3 as regular serverless.'
}
else {
    $signedIn = $false
    try {
        $null = Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])
        $signedIn = $true
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The Azure CLI isn''t signed in to the configured subscription, so the estimate excludes Defender for Cloud and the T2 golden snapshots, prices T3 as regular serverless, and counts T4''s 7-day restart for the rest of the month. {0}' -f $_.Exception.Message)
    }
    if ($signedIn) {
        try {
            $defenderPlans = @(Get-DemoDefenderPlan -SubscriptionId $config['subscriptionId'])
            Write-DemoLog -Message ('Read {0} Defender for Cloud plans from the subscription (read-only).' -f $defenderPlans.Count)
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The Defender for Cloud plans couldn''t be read, so the estimate excludes Defender. {0}' -f $_.Exception.Message)
        }
        try {
            $freeOffer = Get-DemoT3FreeOfferStatus -Config $config
            $t3UseFreeLimit = [bool]$freeOffer.UseFreeLimit
            Write-DemoLog -Message ('T3 free offer: {0} ({1})' -f $freeOffer.Result.status, $freeOffer.Result.message)
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The T3 free offer couldn''t be checked, so T3 is priced as regular serverless. {0}' -f $_.Exception.Message)
        }
        try {
            $goldenSnapshots = @(Get-DemoT2GoldenSnapshot -Config $config)
            Write-DemoLog -Message ('T2 golden snapshots in the golden resource group: {0} (ADR 0018).' -f $goldenSnapshots.Count)
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The T2 golden snapshots couldn''t be listed, so the estimate leaves them out. {0}' -f $_.Exception.Message)
        }
        try {
            $t4RestartCoverage = & $module { param($Settings, $Path) if (Test-DemoT4Enabled -Config $Settings) { Get-DemoT4RestartCoverage -Config $Settings -ConfigPath $Path } } $config $ConfigPath
            if ($null -ne $t4RestartCoverage) {
                Write-DemoLog -Message ('T4''s automatic restart: {0} (2026-11-04, ADR 0016).' -f $(if ($t4RestartCoverage.Counts) { 'about a day each, ' + $t4RestartCoverage.Reason } else { 'the rest of the month, because ' + $t4RestartCoverage.Reason }))
            }
        }
        catch {
            $t4RestartCoverage = $null
            Write-DemoLog -Level Warning -Message ('Whether a safety stop covers T4''s 7-day restart couldn''t be read, so the estimate counts it for the rest of the month. {0}' -f $_.Exception.Message)
        }
        # T5's free tier (2026-11-18, ADR 0027): the account's own when it exists, otherwise whether the subscription's one
        # free-tier Azure Cosmos DB account is free (Azure Resource Graph, read-only).
        $t5FreeTier = & $module { param($Settings) Get-DemoT5FreeTierStatus -Config $Settings } $config
        if ($null -ne $t5FreeTier) {
            Write-DemoLog -Message ('T5''s free tier: {0} (ADR 0027).' -f $(if ($t5FreeTier) { 'yes, so its throughput costs nothing' } else { 'no, so its throughput is at list price' }))
        }
        # T5's container lifecycle (2026-11-19, ADR 0027), unless -T5ContainerLifecycle gives it: the resource group's
        # DbHubT5Container tag (read-only). AlwaysOn when it says so, while the session control's role can't create the
        # container, and when an existing environment doesn't have the tag yet (deployed before then: nothing deletes it).
        if (-not $t5Lifecycle -and (& $module { param($Settings) Test-DemoT5Enabled -Config $Settings } $config)) {
            try {
                $state = Get-DemoDeploymentState -Config $config
                # The shared rule (review of ab91ee5): Session only where something automatic deletes the container after a session.
                $t5Lifecycle = & $module { param($Settings, $State) Get-DemoT5CostLifecycle -Config $Settings -State $State } $config $state
                Write-DemoLog -Message ('T5''s container: {0} (ADR 0027).' -f $(if ($t5Lifecycle -ceq 'AlwaysOn') { 'it stays between sessions in this environment, or only stop-demo.ps1 deletes it, so its throughput is priced all month' } elseif ($state.Exists) { 'it exists only during a session, so its throughput bills only while the demo runs' } else { 'no environment yet, so the estimate assumes it exists only during a session' }))
            }
            catch {
                $t5Lifecycle = ''
                Write-DemoLog -Level Warning -Message ('T5''s container lifecycle couldn''t be read, so the estimate assumes the container exists only during a session. {0}' -f $_.Exception.Message)
            }
        }
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
    if ($null -ne $t4RestartCoverage) {
        $parameters['T4RestartCoverage'] = $t4RestartCoverage
    }
    if ($null -ne $t5FreeTier) {
        $parameters['T5FreeTier'] = $t5FreeTier
    }
    if ($t5Lifecycle) {
        $parameters['T5ContainerLifecycle'] = $t5Lifecycle
    }
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
        'Replica session'  = if ($estimate.T4ReplicaIncluded) { $estimate.T4ReplicaSession } else { 'none' }
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
