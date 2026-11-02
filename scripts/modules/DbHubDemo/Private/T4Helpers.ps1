function Test-DemoT4Enabled {
    # True unless the configuration turns T4 off (t4Enabled false; Phase 24, ADR 0019). Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    return -not ($Config.Contains('t4Enabled') -and $null -ne $Config['t4Enabled'] -and -not [bool]$Config['t4Enabled'])
}

function Get-DemoPostgresSetting {
    # config/versions.json's postgresql block: T4's pinned major version, names, runner role, and metric lists. Internal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    return $versions['postgresql']
}

function Get-DemoT4SkuName {
    <#
    T4's compute size: the t4SkuName setting, or the profile's size (Standard_B1ms) when it isn't set. When the
    configuration doesn't set it, deploy.ps1's fallback moves on when Azure refuses a size with SkuNotAvailable: from B1ms
    to Standard_B2s (Phase 28), then to General Purpose Standard_D2ds_v5 once its cost check passes (Phase 28 follow-up,
    ADR 0019), and records it; Resolve-DemoEffectiveConfig puts the recorded size here. A size the configuration sets
    never changes. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ($Config.Contains('t4SkuName') -and $Config['t4SkuName']) {
        return [string]$Config['t4SkuName']
    }
    $catalog = Get-DemoProfile
    $profileName = if ($Config['profile']) { [string]$Config['profile'] } else { 'lowest-cost' }
    return [string]$catalog.profiles[$profileName].t4.skuName
}

function Test-DemoT4SkuExplicit {
    # True when the configuration file sets t4SkuName: a size you set always wins, with no fallback and no size change. A
    # size that Resolve-DemoEffectiveConfig or the deployment filled in carries t4SkuSource, which the schema doesn't
    # allow in the file (additionalProperties false). Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if (-not $Config.Contains('t4SkuName') -or [string]::IsNullOrWhiteSpace([string]$Config['t4SkuName'])) {
        return $false
    }
    return -not ($Config.Contains('t4SkuSource') -and -not [string]::IsNullOrWhiteSpace([string]$Config['t4SkuSource']))
}

function Copy-DemoT4Config {
    <#
    A copy of the configuration with T4's size set (and T4 on), or with T4 off (-Off), marked with where that came from in
    t4SkuSource (Phase 28 follow-up): record (the resource group's DbHubT4Sku tag), fallback (the General Purpose
    fallback, whose cost check is still to come), server (an existing server's own size), or deployed (what this run's
    template deployed). So it's never taken for a size the file sets (Test-DemoT4SkuExplicit). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('record', 'fallback', 'server', 'deployed')]
        [string] $Source,

        [string] $SkuName = '',

        [switch] $Off
    )

    $copy = [ordered]@{}
    foreach ($key in $Config.Keys) {
        $copy[$key] = $Config[$key]
    }
    if ($Off) {
        $copy['t4Enabled'] = $false
    }
    elseif ($SkuName) {
        $copy['t4Enabled'] = $true
        $copy['t4SkuName'] = $SkuName
    }
    $copy['t4SkuSource'] = $Source
    return $copy
}

function Get-DemoT4ServerSku {
    # An existing T4 server's own size (sku.name in its Servers - Get answer, Get-DemoT4State's Server) when it's one of
    # the documented sizes the template takes, otherwise ''. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Server
    )

    $name = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Server -Name 'sku') -Name 'name')
    if ($name -cin 'Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5') {
        return $name
    }
    return ''
}

function Get-DemoT4SkuSpec {
    <#
    A documented T4 size's tier, vCores, and Retail Prices meter. The tier follows the size, as in
    infra/modules/demo.bicep: Standard_B sizes are Burstable (one meter per server-hour), and Standard_D<n>ds_v5 is
    General Purpose (a vCore-hour meter times its vCores). Internal.
    Source: https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-compute
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SkuName
    )

    if ($SkuName -match '^Standard_B') {
        return [pscustomobject]@{ SkuName = $SkuName; Tier = 'Burstable'; VCores = $(if ($SkuName -eq 'Standard_B1ms') { 1 } else { 2 }); Product = 'Azure Database for PostgreSQL Flexible Server Burstable BS Series Compute'; Meter = ($SkuName -replace '^Standard_', '').ToUpperInvariant(); PerVCore = $false }
    }
    if ($SkuName -match '^Standard_D(\d+)ds_v5$') {
        return [pscustomobject]@{ SkuName = $SkuName; Tier = 'GeneralPurpose'; VCores = [int]$Matches[1]; Product = 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'; Meter = 'vCore'; PerVCore = $true }
    }
    throw ('{0} isn''t a documented T4 size (Standard_B1ms, Standard_B2s, or Standard_D2ds_v5).' -f $SkuName)
}

function Select-DemoT4ComputePrice {
    # T4's compute meter among Retail Prices items: the size's own meter for Burstable, the vCore meter for General Purpose. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Item = @(),

        [Parameter(Mandatory)]
        [pscustomobject] $Spec
    )

    $hourly = @($Item | Where-Object { $_.unitOfMeasure -eq '1 Hour' })
    if ($Spec.PerVCore) {
        return ($hourly | Where-Object { [string]$_.meterName -eq 'vCore' } | Sort-Object -Property retailPrice | Select-Object -First 1)
    }
    return ($hourly | Where-Object { ([string]$_.skuName).ToUpperInvariant() -eq $Spec.Meter } | Select-Object -First 1)
}

function Get-DemoT4HourlyPrice {
    <#
    T4's compute list price per hour at its configured size, or at -SkuName (an existing server's own size), in USD, from
    the Azure Retail Prices API at run time (ADR 0016: no hard-coded prices), or $null when it can't be read. Never
    throws. Internal.
    https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[double]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $SkuName = ''
    )

    try {
        $spec = Get-DemoT4SkuSpec -SkuName $(if ($SkuName) { $SkuName } else { Get-DemoT4SkuName -Config $Config })
        $items = @(Get-DemoRetailPrice -Filter ("serviceName eq 'Azure Database for PostgreSQL' and armRegionName eq '{0}' and productName eq '{1}' and priceType eq 'Consumption'" -f [string]$Config['location'], $spec.Product) -CurrencyCode 'USD')
        $item = Select-DemoT4ComputePrice -Item $items -Spec $spec
        if ($null -eq $item) {
            return $null
        }
        return [double]$item.retailPrice * $(if ($spec.PerVCore) { $spec.VCores } else { 1 })
    }
    catch {
        Write-DemoLog -Level Warning -Message ('T4''s hourly price couldn''t be read from the Retail Prices API: {0}' -f $_.Exception.Message)
        return $null
    }
}

function ConvertTo-DemoT4FallbackCost {
    <#
    .SYNOPSIS
    The verdict on T4's General Purpose fallback from the demo's estimate with T4 at Standard_D2ds_v5 (Phase 28
    follow-up, ADR 0019): Allowed only when its compute was priced, the worst-case month is within monthlyCeilingUsd, and
    a session is within sessionCeilingUsd. Pure. Internal.

    .DESCRIPTION
    The worst case is every hour of a month running, because Azure starts a stopped flexible server again on its own after
    seven days ("The server remains stopped for seven days unless you restart it sooner",
    https://learn.microsoft.com/azure/postgresql/overview; https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server).
    So it's the estimate's light-use month plus its T4 restart worst case (Get-DemoCostEstimate: the rest of the month's
    compute at that size), with T4's storage, its private DNS zone, and, where the subscription's plans are on Standard
    (what a tenant policy enforces, PREFLIGHT.POLICY.DEFENDER), Defender CSPM and Defender for open-source relational
    databases. Unpriced names what the Retail Prices API had no price for, which the totals leave out, and Defender for
    Cloud when its plans weren't read. Returns Allowed, SkipReason (MonthlyCeiling, SessionCeiling, Price, or ''),
    SkuName, HourlyUsd, T4MonthlyWorstCaseUsd (T4 alone, the whole month), MonthlyWorstCaseUsd (the demo's month with it),
    SessionUsd, MonthlyCeilingUsd, SessionCeilingUsd, DefenderIncluded, Unpriced, Location, and PriceError.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Estimate,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $SkuName = 'Standard_D2ds_v5',

        [string] $PriceError = ''
    )

    $components = Get-DemoMemberValue -InputObject $Estimate -Name 'Components'
    $compute = @($components) | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'Name') -eq ('T4 compute ({0})' -f $SkuName) } | Select-Object -First 1
    $hourly = $null
    if ($null -ne $compute) {
        $hourly = [System.Math]::Round([double]$compute.UnitPrice * [double]$compute.Quantity, 4)
    }
    $hoursPerMonth = [double](Get-DemoProfile).assumptions.hoursPerMonth
    $monthlyCeiling = [double]$Config['monthlyCeilingUsd']
    $sessionCeiling = [double]$Config['sessionCeilingUsd']
    $monthlyWorst = [System.Math]::Round([double](Get-DemoMemberValue -InputObject $Estimate -Name 'LightUseMonthly') + [double](Get-DemoMemberValue -InputObject $Estimate -Name 'T4AutoRestartWorstCaseMonthly'), 2)
    $session = [System.Math]::Round([double](Get-DemoMemberValue -InputObject $Estimate -Name 'SessionCost'), 2)
    $t4Worst = if ($null -ne $hourly) { [System.Math]::Round([double](Get-DemoMemberValue -InputObject $Estimate -Name 'T4FixedMonthly') + $hourly * $hoursPerMonth, 2) } else { $null }
    $defenderIncluded = [bool](Get-DemoMemberValue -InputObject $Estimate -Name 'DefenderIncluded')
    $missing = Get-DemoMemberValue -InputObject $Estimate -Name 'MissingPrices'
    $unpriced = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($missing)) {
        if ($name -and [string]$name -ne ('T4 compute ({0})' -f $SkuName)) {
            $unpriced.Add([string]$name)
        }
    }
    if ($null -ne $Estimate -and -not $defenderIncluded) {
        $unpriced.Add('Microsoft Defender for Cloud (the subscription''s plans weren''t read)')
    }
    $reason = if ($null -eq $Estimate -or $null -eq $hourly) { 'Price' } elseif ($monthlyWorst -gt $monthlyCeiling) { 'MonthlyCeiling' } elseif ($session -gt $sessionCeiling) { 'SessionCeiling' } else { '' }
    return [pscustomobject]@{
        Allowed               = (-not $reason)
        SkipReason            = $reason
        SkuName               = $SkuName
        HourlyUsd             = $hourly
        T4MonthlyWorstCaseUsd = $t4Worst
        MonthlyWorstCaseUsd   = $(if ($null -ne $Estimate) { $monthlyWorst } else { $null })
        SessionUsd            = $(if ($null -ne $Estimate) { $session } else { $null })
        MonthlyCeilingUsd     = $monthlyCeiling
        SessionCeilingUsd     = $sessionCeiling
        DefenderIncluded      = $defenderIncluded
        Unpriced              = $unpriced.ToArray()
        Location              = [string]$Config['location']
        PriceError            = $PriceError
    }
}

function Get-DemoT4GeneralPurposeCost {
    <#
    .SYNOPSIS
    The cost check right before T4's General Purpose fallback creates Standard_D2ds_v5 (Phase 28 follow-up, ADR 0019): the
    demo's estimate with T4 at that size, priced from the Azure Retail Prices API now (Get-DemoCostEstimate, with the
    subscription's Defender for Cloud plans and the T2 golden snapshots, both read-only), and its verdict
    (ConvertTo-DemoT4FallbackCost). Never throws: an estimate that can't be made is a verdict that doesn't allow it
    (Price). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('public', 'private')]
        [string] $NetworkMode,

        [AllowNull()]
        [object] $T3UseFreeLimit
    )

    $priced = Copy-DemoT4Config -Config $Config -Source fallback -SkuName 'Standard_D2ds_v5'
    $parameters = @{ Config = $priced; NetworkMode = $NetworkMode }
    if ($null -ne $T3UseFreeLimit) {
        $parameters['T3UseFreeLimit'] = [bool]$T3UseFreeLimit
    }
    try {
        $parameters['DefenderPlans'] = @(Get-DemoDefenderPlan -SubscriptionId ([string]$Config['subscriptionId']))
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The Defender for Cloud plans couldn''t be read, so the General Purpose fallback''s estimate leaves them out: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    try {
        $parameters['GoldenSnapshots'] = @(Get-DemoT2GoldenSnapshot -Config $Config)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The T2 golden snapshots couldn''t be listed, so the General Purpose fallback''s estimate leaves them out: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    try {
        return (ConvertTo-DemoT4FallbackCost -Estimate (Get-DemoCostEstimate @parameters) -Config $priced)
    }
    catch {
        $problem = Protect-DemoText -Text $_.Exception.Message
        Write-DemoLog -Level Warning -Message ('T4''s General Purpose fallback couldn''t be priced: {0}' -f $problem)
        return (ConvertTo-DemoT4FallbackCost -Estimate $null -Config $priced -PriceError $problem)
    }
}

function Format-DemoT4FallbackCostText {
    # The cost check's numbers in one sentence, invariant culture, for the fallback's results (Phase 28 follow-up). Pure.
    # Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Cost
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $text = [string]::Format($culture, 'about {0:N3} USD an hour while it runs (list price in {1}, Azure Retail Prices API, read now); its worst case, every hour of a month because Azure starts a stopped server again on its own after 7 days, is {2:N2} USD a month for T4 with its storage and Defender plans, and {3:N2} USD for the demo''s month against monthlyCeilingUsd ({4:N2} USD); a session is {5:N2} USD against sessionCeilingUsd ({6:N2} USD)', [object[]]@([double]$Cost.HourlyUsd, $Cost.Location, [double]$Cost.T4MonthlyWorstCaseUsd, [double]$Cost.MonthlyWorstCaseUsd, [double]$Cost.MonthlyCeilingUsd, [double]$Cost.SessionUsd, [double]$Cost.SessionCeilingUsd))
    if (@($Cost.Unpriced).Count -gt 0) {
        $text += '. Not priced, so left out of these totals: {0}' -f (@($Cost.Unpriced) -join '; ')
    }
    return $text
}

function Select-DemoT4StartSku {
    # Where T4's fallback starts, from what preflight's checks found (their startSku evidence): the furthest step wins, in
    # the fallback's order: '' (the default size), Standard_B2s, Standard_D2ds_v5, None, Refused (Phase 28 follow-up). Pure.
    # Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Sku = @()
    )

    $order = @('', 'Standard_B2s', 'Standard_D2ds_v5', 'None', 'Refused')
    $best = 0
    foreach ($item in @($Sku)) {
        $rank = [array]::IndexOf($order, [string]$item)
        if ($rank -gt $best) {
            $best = $rank
        }
    }
    return $order[$best]
}

function Get-DemoT4AvailabilityZone {
    # The zone T4 is created in (t4AvailabilityZone): empty for no preference, or 1, 2, or 3. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ($Config.Contains('t4AvailabilityZone') -and $null -ne $Config['t4AvailabilityZone']) {
        return [string]$Config['t4AvailabilityZone']
    }
    return ''
}

function Get-DemoT4CreateFailure {
    <#
    .SYNOPSIS
    T4's last refused creation: the resource group's pgflex01 deployment (the template's T4 module) when it
    failed with SkuNotAvailable. Returns Sku, Zone, and TimeUtc, or $null. A read. Internal.

    .DESCRIPTION
    Azure answers SkuNotAvailable ("Specified SKU is not supported in this region") when a size isn't offered
    in the region or is temporarily unavailable there, even when the Location Based Capabilities API lists it
    (live, 2026-10-26). Learn's remedy is another size. When the configuration doesn't set t4SkuName, deploy.ps1's
    fallback moves on by itself (Phase 28 and its follow-up): Standard_B2s, then General Purpose Standard_D2ds_v5 after
    its cost check; only this code moves it on, and no other failure (a quota, a policy denial, a transient error) does.
    Deploy and preflight use this to report it and to move the fallback on.
    Sources: https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors,
    https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-show,
    https://learn.microsoft.com/cli/azure/deployment/operation/group#az-deployment-operation-group-list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'group', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', 'pgflex01', '--output', 'json') -AllowFailure
    if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
        return $null
    }
    $deployment = [string]$read.StdOut | ConvertFrom-Json -Depth 64
    $properties = Get-DemoMemberValue -InputObject $deployment -Name 'properties'
    if ([string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState') -ne 'Failed') {
        return $null
    }
    # The deployment's own error stops at ResourceDeploymentFailure; the refusal's code is in the server's
    # operation (live, 2026-10-26), so the operations are read too (Deployment Operations - List).
    $errorText = ConvertTo-Json -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'error') -Depth 64 -Compress
    $operations = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'operation', 'group', 'list', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', 'pgflex01', '--output', 'json') -AllowFailure
    if ($operations.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$operations.StdOut)) {
        foreach ($operation in @([string]$operations.StdOut | ConvertFrom-Json -Depth 64)) {
            $operationProperties = Get-DemoMemberValue -InputObject $operation -Name 'properties'
            if ([string](Get-DemoMemberValue -InputObject $operationProperties -Name 'provisioningState') -eq 'Failed') {
                $errorText += ConvertTo-Json -InputObject (Get-DemoMemberValue -InputObject $operationProperties -Name 'statusMessage') -Depth 64 -Compress
            }
        }
    }
    if ($errorText -notmatch 'SkuNotAvailable') {
        return $null
    }
    $parameters = Get-DemoMemberValue -InputObject $properties -Name 'parameters'
    $sizing = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $parameters -Name 'sizing') -Name 'value'
    # ConvertFrom-Json turns the ISO timestamp into a DateTime; it's reported in UTC, culture-independent.
    $stamp = Get-DemoMemberValue -InputObject $properties -Name 'timestamp'
    $timeUtc = if ($stamp -is [datetime]) { $stamp.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$stamp }
    [pscustomobject]@{
        Sku     = [string](Get-DemoMemberValue -InputObject $sizing -Name 'skuName')
        Zone    = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $parameters -Name 'availabilityZone') -Name 'value')
        TimeUtc = $timeUtc
    }
}

function New-DemoT4SkuFailureResult {
    <#
    The Fail (or, for a first try in another zone, Warning) for a T4 size Azure refused with SkuNotAvailable: a size the
    configuration sets, which never changes on its own. Its remediation names the next size, and that leaving t4SkuName
    unset lets deploy.ps1's fallback choose (Phase 28 follow-up). Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $CheckId,

        [Parameter(Mandatory)]
        [pscustomobject] $Failure,

        [ValidateSet('Fail', 'Warning')]
        [string] $Status = 'Fail',

        [string] $NextZone = ''
    )

    $where = if ($Failure.Zone) { 'zone {0}' -f $Failure.Zone } else { 'no zone preference' }
    $evidence = [ordered]@{ refusedSku = $Failure.Sku; refusedZone = $Failure.Zone; refusedUtc = $Failure.TimeUtc; fallbackSku = 'Standard_B2s' }
    $remediation = 'Set t4SkuName to Standard_B2s, the documented fallback (2 vCores, 4 GiB; about four times the hourly list price of B1ms, which estimate-cost.ps1 prices at run time), and run deploy.ps1 again; or keep the size and try once more with t4AvailabilityZone set to another zone the region lists; or remove t4SkuName, and deploy.ps1''s fallback tries Standard_B2s, then General Purpose Standard_D2ds_v5 after its cost check, by itself. A size you set is never changed on its own.'
    if ($Failure.Sku -eq 'Standard_B2s') {
        # Live, 2026-10-26: West US 3 refused the fallback too; the owner then chose the General Purpose option.
        $evidence['fallbackSku'] = 'Standard_D2ds_v5'
        $remediation = 'Standard_B2s is already the documented Burstable fallback. Ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors), try once more with t4AvailabilityZone set to a zone the region lists, set t4SkuName to Standard_D2ds_v5, the documented General Purpose option (2 vCores, 8 GiB; a much higher hourly price and 7-day restart worst case, which estimate-cost.ps1 prices at run time), remove t4SkuName so deploy.ps1''s fallback moves to it by itself after its cost check, or set t4Enabled to false until Azure accepts the size. A size you set is never changed on its own.'
    }
    elseif ($Failure.Sku -match '^Standard_D') {
        $evidence['fallbackSku'] = ''
        $remediation = 'The demo documents no further size. Ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors), and set t4Enabled to false until Azure accepts a size. A size you set is never changed on its own.'
    }
    $docUrl = 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors'
    if ($Status -eq 'Warning') {
        $message = 'Azure refused T4''s size {0} with {1} at {2} (SkuNotAvailable: not supported in the region, or temporarily unavailable). This run tries {0} once more in zone {3}; if Azure refuses it again, the deployment reports a Fail.' -f $Failure.Sku, $where, $Failure.TimeUtc, $NextZone
        return (New-DemoResult -CheckId $CheckId -Area 't4' -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
    }
    $message = 'Azure refused to create T4 at size {0} with {1} at {2}: SkuNotAvailable ("Specified SKU is not supported in this region"), although the region''s capability list includes it, so the size is unavailable there for now.' -f $Failure.Sku, $where, $Failure.TimeUtc
    return (New-DemoResult -CheckId $CheckId -Area 't4' -Target 'T4' -Status 'Fail' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
}

function New-DemoT4FallbackResult {
    <#
    .SYNOPSIS
    DEPLOY.T4.SKU (or a preflight check) for T4's fallback when the configuration doesn't set t4SkuName (Phase 28 and its
    follow-up, ADR 0019): a Warning that says what this run does about a size Azure refused with SkuNotAvailable.
    Internal.

    .DESCRIPTION
    -Next:
    - Standard_B2s: Azure refused Standard_B1ms; this run tries Standard_B2s, the same Burstable class.
    - Standard_D2ds_v5: Azure refused both Burstable sizes, and -Cost (ConvertTo-DemoT4FallbackCost) allows the General
      Purpose fallback: this run creates T4 as Standard_D2ds_v5, with its hourly list price and its worst case from the
      Azure Retail Prices API, read now.
    - None: Azure refused both Burstable sizes, and -Cost doesn't allow the General Purpose fallback (its worst case would
      exceed monthlyCeilingUsd, a session would exceed sessionCeilingUsd, or its price couldn't be read), so this run
      finishes without T4; the next run that deploys the template checks the fallback again.
    - Refused: Azure refused Standard_D2ds_v5 too, so this run finishes without T4, and nothing is tried again on its own.
    -Refused is the refusal that moved the fallback on (Get-DemoT4CreateFailure), or $null when preflight or an earlier
    run's record started it there. No price is written here (ADR 0016).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [pscustomobject] $Refused,

        [Parameter(Mandatory)]
        [ValidateSet('Standard_B2s', 'Standard_D2ds_v5', 'None', 'Refused')]
        [string] $Next,

        [AllowNull()]
        [pscustomobject] $Cost,

        [ValidateSet('DEPLOY.T4.SKU', 'PREFLIGHT.T4.FALLBACK')]
        [string] $CheckId = 'DEPLOY.T4.SKU'
    )

    $docUrl = 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors'
    $area = if ($CheckId -like 'PREFLIGHT.*') { 'preflight' } else { 't4' }
    $where = ''
    $evidence = [ordered]@{ next = $Next; startSku = $Next }
    if ($null -ne $Refused) {
        $where = if ($Refused.Zone) { 'zone {0}' -f $Refused.Zone } else { 'no zone preference' }
        $evidence['refusedSku'] = $Refused.Sku
        $evidence['refusedZone'] = $Refused.Zone
        $evidence['refusedUtc'] = $Refused.TimeUtc
    }
    if ($Next -eq 'Standard_B2s') {
        $message = 'Azure refused T4''s size {0} with {1} at {2} (SkuNotAvailable). This run tries Standard_B2s, the same Burstable class (2 vCores, 4 GiB; about four times the hourly list price of B1ms, which estimate-cost.ps1 prices at run time), and later runs keep it.' -f $Refused.Sku, $where, $Refused.TimeUtc
        return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation 'Nothing to do. To choose T4''s size yourself, set t4SkuName in your configuration: a size you set is never changed.' -DocUrl $docUrl)
    }
    if ($Next -eq 'Refused') {
        $what = if ($null -ne $Refused) { ' ({0}, at {1}; SkuNotAvailable)' -f $where, $Refused.TimeUtc } else { ' (SkuNotAvailable, on record)' }
        $message = 'Azure refused T4''s General Purpose fallback, Standard_D2ds_v5{0}, after both Burstable sizes, so this run finishes without T4, and later runs don''t try again on their own: t4Enabled stays as you configured it, but the server isn''t created.' -f $what
        $remediation = 'Ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors), then set t4SkuName to the size you get access to and run ./scripts/deploy.ps1. Or set t4Enabled to false to leave T4 out on purpose.'
        return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
    }

    # Standard_D2ds_v5 or None: the General Purpose fallback, as its cost check decided.
    $why = if ($null -ne $Refused) { 'Azure refused both of T4''s Burstable sizes, Standard_B1ms and then Standard_B2s ({0}, at {1}; SkuNotAvailable)' -f $where, $Refused.TimeUtc } else { 'Azure refuses T4''s Burstable sizes, Standard_B1ms and Standard_B2s, here (SkuNotAvailable, on record or found by preflight)' }
    $evidence['fallbackSku'] = 'Standard_D2ds_v5'
    $evidence['fallbackTier'] = 'GeneralPurpose'
    if ($null -ne $Cost) {
        foreach ($name in 'HourlyUsd', 'T4MonthlyWorstCaseUsd', 'MonthlyWorstCaseUsd', 'SessionUsd', 'MonthlyCeilingUsd', 'SessionCeilingUsd', 'DefenderIncluded', 'SkipReason') {
            $evidence[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = $Cost.$name
        }
        $evidence['unpriced'] = @($Cost.Unpriced)
    }
    if ($Next -eq 'Standard_D2ds_v5') {
        $message = '{0}, so this run creates T4 as General Purpose Standard_D2ds_v5 (2 vCores, 8 GiB): {1}. Later runs keep this size, and an existing server is never resized.' -f $why, (Format-DemoT4FallbackCostText -Cost $Cost)
        $remediation = 'Nothing to do. ./scripts/stop-demo.ps1 stops T4 between sessions and says when Azure starts it again on its own. To choose T4''s size yourself, set t4SkuName (a size you set is never changed), or set t4Enabled to false to leave T4 out.'
        return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl 'https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server')
    }
    $skipReason = if ($null -ne $Cost) { [string]$Cost.SkipReason } else { 'Price' }
    $evidence['skipReason'] = $skipReason
    $skip = Get-DemoT4SkipReason -Cost $Cost
    $message = '{0}, and the General Purpose fallback, Standard_D2ds_v5, isn''t created: {1}. This run finishes without T4: t4Enabled stays as you configured it, and the next run that deploys the template checks the fallback again, price and ceilings first.' -f $why, $skip.Because
    if ($null -ne $Cost -and @($Cost.Unpriced).Count -gt 0) {
        $message += ' Not priced, so left out of these totals: {0}.' -f (@($Cost.Unpriced) -join '; ')
    }
    return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $skip.Remediation -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices')
}

function Get-DemoT4SkipReason {
    # Why the General Purpose fallback's cost check (ConvertTo-DemoT4FallbackCost) leaves T4 out, and what would add it:
    # Because (a clause) and Remediation, invariant culture (Phase 28 follow-up). -Ahead words the remediation for
    # preflight, before Azure has refused anything. Pure. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [pscustomobject] $Cost,

        [switch] $Ahead
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $reason = if ($null -ne $Cost) { [string]$Cost.SkipReason } else { 'Price' }
    $then = if ($Ahead) { 'Nothing to do unless Azure refuses both Burstable sizes. To have the fallback create T4 then, ' } else { 'To add T4, ' }
    $again = if ($Ahead) { '' } else { ', then run ./scripts/deploy.ps1, which checks the fallback again' }
    switch ($reason) {
        'MonthlyCeiling' {
            $because = [string]::Format($culture, 'its worst case, every hour of a month (Azure starts a stopped server again on its own after 7 days) at about {0:N3} USD an hour, with its storage and Defender plans, brings the demo''s month to {1:N2} USD, over monthlyCeilingUsd ({2:N2} USD)', [double]$Cost.HourlyUsd, [double]$Cost.MonthlyWorstCaseUsd, [double]$Cost.MonthlyCeilingUsd)
            $remediation = [string]::Format($culture, '{0}raise monthlyCeilingUsd to at least {1:N0} in your configuration (the budget follows it){2}; or set t4Enabled to false to leave T4 out on purpose.', $then, [System.Math]::Ceiling([double]$Cost.MonthlyWorstCaseUsd), $again)
        }
        'SessionCeiling' {
            $because = [string]::Format($culture, 'with it, a session is estimated at {0:N2} USD, over sessionCeilingUsd ({1:N2} USD)', [double]$Cost.SessionUsd, [double]$Cost.SessionCeilingUsd)
            $remediation = [string]::Format($culture, '{0}raise sessionCeilingUsd to at least {1:N0} in your configuration{2}; or set t4Enabled to false to leave T4 out on purpose.', $then, [System.Math]::Ceiling([double]$Cost.SessionUsd), $again)
        }
        default {
            $problem = if ($null -ne $Cost -and $Cost.PriceError) { ' ({0})' -f $Cost.PriceError } else { '' }
            $because = 'its price couldn''t be read from the Azure Retail Prices API{0}, and nothing is created without one' -f $problem
            $remediation = if ($Ahead) { 'Nothing to do: deploy.ps1 prices the fallback again right before it would create anything.' } else { 'Run ./scripts/deploy.ps1 again later: it prices the fallback again before it creates anything. Or set t4Enabled to false to leave T4 out on purpose.' }
        }
    }
    return [pscustomobject]@{ Reason = $reason; Because = $because; Remediation = $remediation }
}

function Get-DemoT4FallbackPreflight {
    <#
    .SYNOPSIS
    PREFLIGHT.T4.FALLBACK (Phase 28 follow-up, ADR 0019): the General Purpose fallback's cost check in preflight, and where
    deploy.ps1's fallback starts (its evidence's startSku). Returns Result and CostResults (the cost checks to report
    instead of the estimate's own, or $null). Internal.

    .DESCRIPTION
    - -Start Standard_D2ds_v5 (the Burstable sizes are ruled out, or an earlier run's record): -Estimate already prices T4
      at that size, so its verdict (ConvertTo-DemoT4FallbackCost) decides. Within both ceilings, the start stays, with a
      Warning that gives the price and the worst case; otherwise the start is None, with a Warning that says why, and the
      ceilings are checked again without T4 (CostResults), which this run leaves out.
    - A T4 that doesn't exist yet and a size the configuration doesn't set, starting at a Burstable size: Azure can still
      refuse it at creation although the region lists it (live, West US 3), so the General Purpose step is priced now too,
      with the same parameters and price cache (only its compute price is read again): a Pass within both ceilings,
      otherwise a Warning that T4 would be left out. deploy.ps1 prices it again right before it would create it.
    - Otherwise Not selected: T4 exists (its size is kept), the configuration sets t4SkuName (no fallback), or the start is
      None or Refused (PREFLIGHT.T4.CAPABILITY or PREFLIGHT.T4.SKU says why).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [hashtable] $CostParameters,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Estimate,

        [AllowEmptyString()]
        [string] $Start = '',

        [switch] $Explicit,

        [switch] $Exists,

        [string] $ServerSku = ''
    )

    $checkId = 'PREFLIGHT.T4.FALLBACK'
    if ($Start -eq 'Standard_D2ds_v5') {
        $cost = ConvertTo-DemoT4FallbackCost -Estimate $Estimate -Config $CostParameters['Config']
        if ($cost.Allowed) {
            return [pscustomobject]@{ Result = (New-DemoT4FallbackResult -Refused $null -Next 'Standard_D2ds_v5' -Cost $cost -CheckId $checkId); CostResults = $null }
        }
        $without = @{} + $CostParameters
        $without['Config'] = Copy-DemoT4Config -Config $Config -Source fallback -Off
        return [pscustomobject]@{ Result = (New-DemoT4FallbackResult -Refused $null -Next 'None' -Cost $cost -CheckId $checkId); CostResults = @((Get-DemoCostEstimate @without).Results) }
    }
    $notSelected = {
        param([string] $Message)
        [pscustomobject]@{ Result = (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'T4' -Status 'Not selected' -Message $Message -Evidence ([ordered]@{ startSku = $Start })); CostResults = $null }
    }
    if ($Explicit) {
        return (& $notSelected ('t4SkuName is set to {0}, so there''s no fallback: a size you set is never changed.' -f (Get-DemoT4SkuName -Config $Config)))
    }
    if ($Exists) {
        return (& $notSelected ('T4 exists{0}, so the fallback doesn''t apply: deploy.ps1 keeps its size.' -f $(if ($ServerSku) { ' as ' + $ServerSku } else { '' })))
    }
    if ($Start -in 'None', 'Refused') {
        return (& $notSelected 'This run leaves T4 out (PREFLIGHT.T4.CAPABILITY or PREFLIGHT.T4.SKU says why), so the General Purpose fallback isn''t priced.')
    }
    # A Burstable start: the General Purpose step, priced now for the record.
    $priced = @{} + $CostParameters
    $priced['Config'] = Copy-DemoT4Config -Config $Config -Source fallback -SkuName 'Standard_D2ds_v5'
    $cost = ConvertTo-DemoT4FallbackCost -Estimate (Get-DemoCostEstimate @priced) -Config $priced['Config']
    $evidence = [ordered]@{ startSku = $Start; fallbackSku = 'Standard_D2ds_v5'; fallbackTier = 'GeneralPurpose' }
    foreach ($name in 'HourlyUsd', 'T4MonthlyWorstCaseUsd', 'MonthlyWorstCaseUsd', 'SessionUsd', 'MonthlyCeilingUsd', 'SessionCeilingUsd', 'DefenderIncluded', 'SkipReason') {
        $evidence[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = $cost.$name
    }
    $evidence['unpriced'] = @($cost.Unpriced)
    $premise = 'If Azure refuses T4''s Burstable sizes when it creates it (SkuNotAvailable; West US 3 did, although it lists them)'
    if ($cost.Allowed) {
        $message = '{0}, deploy.ps1 creates T4 as General Purpose Standard_D2ds_v5: {1}. That''s within both ceilings; deploy.ps1 prices it again right before it would create it.' -f $premise, (Format-DemoT4FallbackCostText -Cost $cost)
        return [pscustomobject]@{ Result = (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'T4' -Status 'Pass' -Message $message -Evidence $evidence -DocUrl 'https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server'); CostResults = $null }
    }
    $skip = Get-DemoT4SkipReason -Cost $cost -Ahead
    $message = '{0}, deploy.ps1''s General Purpose fallback, Standard_D2ds_v5, would leave T4 out instead: {1}.' -f $premise, $skip.Because
    if (@($cost.Unpriced).Count -gt 0) {
        $message += ' Not priced, so left out of these totals: {0}.' -f (@($cost.Unpriced) -join '; ')
    }
    return [pscustomobject]@{ Result = (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $skip.Remediation -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices'); CostResults = $null }
}

function Resolve-DemoEffectiveConfig {
    <#
    .SYNOPSIS
    The configuration with what earlier runs settled that the file doesn't say: T4's size from the fallback (Phase 28 and
    its follow-up, ADR 0019), recorded in the resource group's DbHubT4Sku tag. A t4SkuName the file sets, or t4Enabled
    false, always wins. Returns the configuration itself when nothing applies or it's already resolved (it carries
    t4SkuSource), otherwise a copy (Copy-DemoT4Config). Pure. Internal.

    .DESCRIPTION
    The record:
    - Standard_B2s: Azure refused Standard_B1ms, and T4 uses Standard_B2s.
    - Standard_D2ds_v5: Azure refused both Burstable sizes, the cost check passed, and T4 uses General Purpose
      Standard_D2ds_v5. A redeploy keeps it, and never tries Standard_B1ms again.
    - None: Azure refused both Burstable sizes, and T4 isn't deployed: the General Purpose fallback's cost check left it
      out (over a ceiling, or no price), or the record is from before the fallback went on to General Purpose. With
      -TemplateRuns (this run deploys the template), T4 is planned at Standard_D2ds_v5 again, and its cost check runs
      before anything is created; the Burstable sizes aren't tried again. Without it, T4 is off.
    - Refused: Azure refused Standard_D2ds_v5 too, so T4 is off, and nothing is tried again on its own.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State,

        [switch] $TemplateRuns
    )

    if ($Config.Contains('t4SkuSource') -and -not [string]::IsNullOrWhiteSpace([string]$Config['t4SkuSource'])) {
        return $Config
    }
    $recorded = [string](Get-DemoMemberValue -InputObject $State -Name 'T4Sku')
    if (-not $recorded -or (Test-DemoT4SkuExplicit -Config $Config) -or -not (Test-DemoT4Enabled -Config $Config)) {
        return $Config
    }
    switch -CaseSensitive ($recorded) {
        'Standard_B2s' {
            return (Copy-DemoT4Config -Config $Config -Source record -SkuName 'Standard_B2s')
        }
        'Standard_D2ds_v5' {
            return (Copy-DemoT4Config -Config $Config -Source record -SkuName 'Standard_D2ds_v5')
        }
        'None' {
            if ($TemplateRuns) {
                return (Copy-DemoT4Config -Config $Config -Source fallback -SkuName 'Standard_D2ds_v5')
            }
            return (Copy-DemoT4Config -Config $Config -Source record -Off)
        }
        'Refused' {
            return (Copy-DemoT4Config -Config $Config -Source record -Off)
        }
    }
    return $Config
}

function Test-DemoT4FallbackSize {
    # True when T4 runs on the General Purpose size the fallback chose (DbHubT4Sku Standard_D2ds_v5) and the configuration
    # neither sets t4SkuName nor turns T4 off (Phase 28 follow-up). Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [System.Collections.IDictionary] $Config = @{},

        [AllowNull()]
        [object] $State
    )

    if (-not (Test-DemoT4Enabled -Config $Config) -or (Test-DemoT4SkuExplicit -Config $Config)) {
        return $false
    }
    return ([string](Get-DemoMemberValue -InputObject $State -Name 'T4Sku') -ceq 'Standard_D2ds_v5')
}

function Format-DemoT4FallbackCreatedText {
    # "T4 created as General Purpose Standard_D2ds_v5 because Burstable sizes were refused here; about <price> USD an hour
    # while running": the console line, the status page, and DONE say it the same way (Phase 28 follow-up). -HourlyUsd
    # comes from the Azure Retail Prices API; without it, the line says the price couldn't be read. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $HourlyUsd,

        [string] $Location = ''
    )

    $price = if ($null -ne $HourlyUsd) { [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, 'about {0:N3} USD an hour while running (list price in {1}, Azure Retail Prices API)', [double]$HourlyUsd, $Location) } else { 'its hourly list price couldn''t be read just now (./scripts/estimate-cost.ps1 prices it)' }
    return ('T4 created as General Purpose Standard_D2ds_v5 because Burstable sizes were refused here; {0}.' -f $price)
}

function Get-DemoT4FallbackNote {
    <#
    The line deploy.ps1's ending (DONE and NOT DONE, on the console and the status page) adds while T4 runs on the General
    Purpose fallback (Phase 28 follow-up): Format-DemoT4FallbackCreatedText, with the hourly list price the caller read
    from the Azure Retail Prices API, never a number written here (ADR 0016), and the 7-day restart. '' when it doesn't
    apply (Test-DemoT4FallbackSize). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [System.Collections.IDictionary] $Config = @{},

        [AllowNull()]
        [object] $State,

        [AllowNull()]
        [object] $HourlyUsd
    )

    if (-not (Test-DemoT4FallbackSize -Config $Config -State $State)) {
        return ''
    }
    $restart = if ((Get-DemoActivityControlSetting -Config $Config).Enabled) {
        'Azure starts a stopped T4 again on its own after 7 days, and the on-demand control''s daily safety stop stops it again.'
    }
    else {
        'Azure starts a stopped T4 again on its own after 7 days, and nothing here stops it again (no daily safety stop is set up), so ./scripts/stop-demo.ps1 and ./scripts/status.ps1 show that date.'
    }
    return ('{0} {1}' -f (Format-DemoT4FallbackCreatedText -HourlyUsd $HourlyUsd -Location ([string]$Config['location'])), $restart)
}

function Format-DemoT4RestartText {
    <#
    When a stopped T4 starts again on its own, and what that bills, for status.ps1 and stop-demo.ps1 (Phase 28 follow-up):
    Azure starts a stopped flexible server again after 7 days ("The server remains stopped for seven days unless you
    restart it sooner", https://learn.microsoft.com/azure/postgresql/overview; "Server will be automatically started after
    7 days", https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server), so it's the stop time
    plus -Days. With the on-demand control's daily safety stop (control.enabled, ADR 0020) it's stopped again within a
    day; without it nothing here stops it again. -HourlyUsd is the caller's, from the Retail Prices API. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $RestartUtc,

        [string] $SkuName = '',

        [AllowNull()]
        [object] $HourlyUsd,

        [ValidateRange(1, 30)]
        [int] $Days = 7
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $when = if ($null -ne $RestartUtc) { [string]::Format($culture, 'at {0:yyyy-MM-dd HH:mm} UTC, {1} days after the stop', ([datetime]$RestartUtc).ToUniversalTime(), $Days) } else { '{0} days after it was stopped' -f $Days }
    $bills = if ($null -ne $HourlyUsd) { [string]::Format($culture, ', and it then bills compute at about {0:N3} USD an hour ({1}, list price)', [double]$HourlyUsd, $SkuName) } elseif ($SkuName) { ', and it then bills compute at its size ({0})' -f $SkuName } else { ', and it then bills compute' }
    $after = if ((Get-DemoActivityControlSetting -Config $Config).Enabled) {
        ' until the on-demand control''s daily safety stop stops it again, within a day.'
    }
    else {
        ' until it''s stopped again: nothing here stops it on its own (the on-demand control''s daily safety stop isn''t set up), so run ./scripts/stop-demo.ps1 again once it has started, or ./scripts/destroy.ps1 if the demo stays idle.'
    }
    return ('Azure starts it again on its own {0}{1}{2}' -f $when, $bills, $after)
}

function Get-DemoT4Name {
    <#
    .SYNOPSIS
    Returns T4's names: resource group, the flexible server pgflex01-<deploymentId>, its resource ID and FQDN,
    the database, the runner's role, and T1. Internal.

    .DESCRIPTION
    The server's name is stable across stops and redeployments (infra/modules/demo.bicep). The deploymentId
    comes from -DeploymentId or the resource group's deploymentId tag (Get-DemoT3Name); with -NoLookup nothing
    is read, and ServerName is empty when -DeploymentId wasn't given. Enabled is false when the configuration
    sets t4Enabled to false.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [switch] $NoLookup
    )

    $t3 = Get-DemoT3Name -Config $Config -DeploymentId $DeploymentId -NoLookup:$NoLookup
    $postgres = Get-DemoPostgresSetting
    $serverName = if ($t3.DeploymentId) { '{0}-{1}' -f $postgres['serverNamePrefix'], $t3.DeploymentId } else { '' }
    [pscustomobject]@{
        Enabled       = (Test-DemoT4Enabled -Config $Config)
        ResourceGroup = $t3.ResourceGroup
        DeploymentId  = $t3.DeploymentId
        ServerName    = $serverName
        ServerId      = if ($serverName) { '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{2}' -f $Config['subscriptionId'], $t3.ResourceGroup, $serverName } else { '' }
        Fqdn          = if ($serverName) { '{0}.postgres.database.azure.com' -f $serverName } else { '' }
        DatabaseName  = [string]$postgres['databaseName']
        RunnerRole    = [string]$postgres['runnerRole']
        MajorVersion  = [string]$postgres['majorVersion']
        T1VmName      = $t3.T1VmName
    }
}

function Get-DemoT4Resource {
    <#
    .SYNOPSIS
    Reads T4's server, or one of its child resources, through 'az rest --method get' with the pinned API
    version. Returns Found, NotFound, Value, and Error. Internal.

    .DESCRIPTION
    -Child is the path under the server, for example 'databases/contosocare', 'administrators', or
    'configurations/metrics.collector_database_activity'. A read: it works while the server is stopped.
    Source: https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/get
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ServerId,

        [ValidatePattern('^$|^[A-Za-z]+(/[A-Za-z0-9._-]+)?$')]
        [string] $Child = ''
    )

    $type = 'Microsoft.DBforPostgreSQL/flexibleServers'
    if ($Child) {
        $type = '{0}/{1}' -f $type, $Child.Split('/')[0]
    }
    $url = 'https://management.azure.com{0}{1}?api-version={2}' -f $ServerId, $(if ($Child) { '/' + $Child } else { '' }), (Get-DemoPinnedApiVersion -ResourceType $type)
    $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'get', '--url', $url, '--output', 'json') -AllowFailure
    if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
        return [pscustomobject]@{ Found = $true; NotFound = $false; Value = ([string]$result.StdOut | ConvertFrom-Json -Depth 32); Error = '' }
    }
    $errorText = Protect-DemoText -Text ([string]$result.StdErr).Trim()
    $missing = $errorText -match '(?i)ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound|\bNot ?Found\b|\(404\)'
    return [pscustomobject]@{ Found = $false; NotFound = $missing; Value = $null; Error = $errorText }
}

function Get-DemoT4State {
    <#
    .SYNOPSIS
    T4's server state (Ready, Stopped, Starting, Stopping, Updating, ...), or NotFound or Unknown, with the
    server's properties when it exists. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $DeploymentId = ''
    )

    $names = Get-DemoT4Name -Config $Config -DeploymentId $DeploymentId
    if (-not $names.ServerName) {
        return [pscustomobject]@{ Names = $names; Exists = $false; State = 'NotFound'; Server = $null; Error = 'The resource group has no deploymentId tag.' }
    }
    $read = Get-DemoT4Resource -Config $Config -ServerId $names.ServerId
    if ($read.Found) {
        $state = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $read.Value -Name 'properties') -Name 'state')
        return [pscustomobject]@{ Names = $names; Exists = $true; State = $(if ($state) { $state } else { 'Unknown' }); Server = $read.Value; Error = '' }
    }
    return [pscustomobject]@{ Names = $names; Exists = $false; State = $(if ($read.NotFound) { 'NotFound' } else { 'Unknown' }); Server = $null; Error = $read.Error }
}

function Wait-DemoT4State {
    # Polls T4's state until it's one of -State or -TimeoutMinutes pass; returns the last state read. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string[]] $State,

        [ValidateRange(0, 60)]
        [int] $TimeoutMinutes = 15,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15,

        [string] $DeploymentId = ''
    )

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ($true) {
        $current = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
        if ($current.State -in $State -or [DateTime]::UtcNow -ge $deadline) {
            return $current
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Invoke-DemoT4PowerAction {
    <#
    .SYNOPSIS
    Starts or stops T4 with the documented REST operations (Servers - Start, Servers - Stop), unless it's
    already in that state, and with -WaitMinutes waits for Ready or Stopped. Returns <CheckPrefix>.T4.<ACTION>.
    Internal.

    .DESCRIPTION
    start-demo.ps1 starts T4 and stop-demo.ps1 stops it; deploy.ps1 starts a stopped T4 before the template,
    because a stopped flexible server rejects every other management operation. A stopped server starts on
    its own after seven days (Learn: Stop an Azure Database for PostgreSQL flexible server, and the overview's "Stop and
    start server to lower TCO"), so the stop result says when (Phase 28 follow-up): the stop time plus seven days (for a
    server that was already stopped, its stop in the activity log), what it then bills at its own size (the Retail Prices
    API), and whether the on-demand control's daily safety stop stops it again (Format-DemoT4RestartText). A missing
    server, or T4 turned off (t4Enabled false), is Not selected.
    -Requested says that the caller already sent this operation in an earlier call (-WaitMinutes 0), so a server
    that's in the wanted state by now "is now" running or stopped, not "was already" (Phase 25d).
    Sources: https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server,
    https://learn.microsoft.com/azure/postgresql/overview,
    https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/start,
    https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/stop
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Callers confirm once for the whole start, stop, or deployment.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('Start', 'Stop')]
        [string] $Action,

        [ValidateRange(0, 60)]
        [int] $WaitMinutes = 0,

        [ValidateSet('DEPLOY', 'START', 'STOP')]
        [string] $CheckPrefix = 'START',

        [string] $DeploymentId = '',

        [switch] $Requested
    )

    $checkId = '{0}.T4.{1}' -f $CheckPrefix, $Action.ToUpperInvariant()
    $postgres = Get-DemoPostgresSetting
    $docUrl = [string]$postgres['docUrls']['stopServer']
    $names = Get-DemoT4Name -Config $Config -DeploymentId $DeploymentId
    if (-not $names.Enabled) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Not selected' -Message 'T4 is off in this configuration (t4Enabled is false).')
    }
    $current = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
    if (-not $current.Exists) {
        $status = if ($current.State -eq 'NotFound') { 'Not selected' } else { 'Warning' }
        $message = if ($current.State -eq 'NotFound') { 'T4 isn''t deployed, so there''s nothing to {0}.' -f $Action.ToLowerInvariant() } else { 'T4''s state couldn''t be read: {0}' -f $current.Error }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $status -Message $message -Evidence @{ server = $names.ServerName } -DocUrl $docUrl)
    }

    $wanted = if ($Action -eq 'Start') { 'Ready' } else { 'Stopped' }
    $before = $current.State
    $evidence = [ordered]@{ server = $names.ServerName; stateBefore = $before }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $requestUtc = [DateTime]::UtcNow
    if ($before -ne $wanted) {
        # A server that's moving the other way finishes first; the operation is then sent once.
        $settling = if ($Action -eq 'Start') { 'Stopping' } else { 'Starting' }
        if ($before -eq $settling) {
            $current = Wait-DemoT4State -Config $Config -State @('Ready', 'Stopped') -TimeoutMinutes 15 -DeploymentId $DeploymentId
        }
        if ($current.State -ne $wanted -and $current.State -ne $(if ($Action -eq 'Start') { 'Starting' } else { 'Stopping' })) {
            $url = 'https://management.azure.com{0}/{1}?api-version={2}' -f $names.ServerId, $Action.ToLowerInvariant(), (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers')
            $post = Invoke-DemoAzWithConflictRetry -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'post', '--url', $url) -Label ('T4 {0}: {1}' -f $names.ServerName, $Action.ToLowerInvariant()) -MaxConflictRetries 4
            if ($post.ExitCode -ne 0) {
                $evidence['error'] = Protect-DemoText -Text ([string]$post.StdErr).Trim()
                return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Fail' -Message ('T4 ({0}) couldn''t be {1}: {2}' -f $names.ServerName, $(if ($Action -eq 'Start') { 'started' } else { 'stopped' }), $evidence['error']) -Evidence $evidence -Remediation ('Run the script again in a few minutes; a server that''s updating rejects {0} until it finishes.' -f $Action.ToLowerInvariant()) -DocUrl $docUrl)
            }
        }
        if ($WaitMinutes -gt 0) {
            $current = Wait-DemoT4State -Config $Config -State @($wanted) -TimeoutMinutes $WaitMinutes -DeploymentId $DeploymentId
        }
        else {
            $current = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
        }
    }
    $evidence['stateAfter'] = $current.State
    $evidence['seconds'] = [int]$clock.Elapsed.TotalSeconds
    $autoStart = ''
    if ($Action -eq 'Stop') {
        # When Azure starts it again on its own: the stop time plus 7 days (Phase 28 follow-up). This call's stop is now; a
        # server that was already stopped has its stop in the activity log. What it then bills is priced at its own size.
        $days = [int]$postgres['autoStartAfterStoppedDays']
        $evidence['autoStartsAfterDays'] = $days
        $stoppedUtc = $null
        if ($before -eq 'Stopped') {
            $stoppedUtc = Get-DemoT4StoppedUtc -Config $Config -ServerId $names.ServerId
        }
        elseif ($current.State -in 'Stopped', 'Stopping' -or ($WaitMinutes -eq 0 -and $current.State -eq $before)) {
            $stoppedUtc = $requestUtc
        }
        $restartUtc = if ($null -ne $stoppedUtc) { ([datetime]$stoppedUtc).ToUniversalTime().AddDays($days) } else { $null }
        $serverSku = Get-DemoT4ServerSku -Server $current.Server
        $hourly = if ($serverSku) { Get-DemoT4HourlyPrice -Config $Config -SkuName $serverSku } else { $null }
        $evidence['stoppedUtc'] = if ($null -ne $stoppedUtc) { ([datetime]$stoppedUtc).ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
        $evidence['autoStartUtc'] = if ($null -ne $restartUtc) { $restartUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
        $evidence['skuName'] = $serverSku
        $evidence['hourlyUsd'] = $hourly
        $evidence['dailySafetyStop'] = [bool](Get-DemoActivityControlSetting -Config $Config).Enabled
        $autoStart = ' ' + (Format-DemoT4RestartText -Config $Config -RestartUtc $restartUtc -SkuName $serverSku -HourlyUsd $hourly -Days $days)
    }
    if ($current.State -eq $wanted) {
        $verb = if ($Action -eq 'Start') { 'running (Ready)' } else { 'stopped' }
        $how = if ($before -eq $wanted -and -not $Requested) { 'was already' } else { 'is now' }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4 ({0}) {1} {2}.{3}' -f $names.ServerName, $how, $verb, $autoStart) -Evidence $evidence -DocUrl $docUrl)
    }
    $pending = if ($Action -eq 'Start') { 'Starting' } else { 'Stopping' }
    if ($WaitMinutes -eq 0 -and $current.State -in @($pending, $before)) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4 ({0}) is {1}; the operation runs in the background.{2}' -f $names.ServerName, $pending.ToLowerInvariant(), $autoStart) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4 ({0}) is {1}, not {2}, after {3} minute(s).{4}' -f $names.ServerName, $current.State, $wanted, $WaitMinutes, $autoStart) -Evidence $evidence -Remediation 'Check it again with status.ps1 in a few minutes; a Burstable server that has used up its CPU credits can take longer to stop or start.' -DocUrl $docUrl)
}

function Get-DemoT4MetricSnapshot {
    <#
    .SYNOPSIS
    T4's latest Azure Monitor metrics at a one-minute grain over the last -Minutes: the metrics Database Hub's
    PostgreSQL dashboard charts, the Burstable CPU credits, and the enhanced metrics (sessions by state and by
    wait event type, the oldest transaction and query, deadlocks). Internal.

    .DESCRIPTION
    Four reads of the documented Metrics - List REST API (az rest --method get): the maximum-aggregated
    metrics, the summed ones, and the two split by a dimension. The query parameters go in a file
    (--url-parameters @<path>, which the Azure CLI encodes), because an encoded query string has '%', which
    cmd.exe can't pass to az.cmd (live, 2026-10-26). Returns Succeeded, Error, Latest (metric -> newest value),
    LatestUtc, ByState, and ByWaitEventType. Native metric queries are free up to a monthly allowance;
    status.ps1 and validate.ps1 make four per call.
    Sources: https://learn.microsoft.com/rest/api/monitor/metrics/list,
    https://learn.microsoft.com/cli/azure/reference-index#az-rest,
    https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-dbforpostgresql-flexibleservers-metrics
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ServerId,

        [ValidateRange(5, 1440)]
        [int] $Minutes = 15,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $end = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)
    $timespan = '{0}/{1}' -f $end.AddMinutes(-$Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant), $end.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    $apiVersion = Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Insights/metrics'
    $maximum = @('cpu_percent', 'memory_percent', 'storage_percent', 'iops', 'active_connections', 'cpu_credits_remaining', 'cpu_credits_consumed', 'disk_iops_consumed_percentage', 'longest_transaction_time_sec', 'longest_query_time_sec', 'oldest_backend_xmin_age')
    $total = @('connections_failed', 'deadlocks')
    $reads = @(
        @{ Names = $maximum; Aggregation = 'Maximum'; Filter = ''; Split = '' }
        @{ Names = $total; Aggregation = 'Total'; Filter = ''; Split = '' }
        @{ Names = @('sessions_by_state'); Aggregation = 'Maximum'; Filter = "State eq '*'"; Split = 'state' }
        @{ Names = @('sessions_by_wait_event_type'); Aggregation = 'Maximum'; Filter = "WaitEventType eq '*'"; Split = 'waiteventtype' }
    )
    $latest = [ordered]@{}
    $byState = [ordered]@{}
    $byWait = [ordered]@{}
    $newest = $null
    $errors = [System.Collections.Generic.List[string]]::new()
    $url = 'https://management.azure.com{0}/providers/Microsoft.Insights/metrics' -f $ServerId
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-t4metrics'
    try {
        $index = 0
        foreach ($read in $reads) {
            $index++
            $parameters = [ordered]@{ timespan = $timespan; interval = 'PT1M'; metricnames = ($read.Names -join ','); aggregation = $read.Aggregation; 'api-version' = $apiVersion }
            if ($read.Filter) {
                $parameters['$filter'] = $read.Filter
            }
            $path = Write-DemoPrivateFile -Directory $directory -Name ('metrics-{0}.json' -f $index) -Content ($parameters | ConvertTo-Json -Compress)
            $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'get', '--url', $url, '--url-parameters', "@$path", '--output', 'json') -AllowFailure
            if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
                $errors.Add((Protect-DemoText -Text ([string]$result.StdErr).Trim()))
                continue
            }
            $body = [string]$result.StdOut | ConvertFrom-Json -Depth 32
            foreach ($metric in (Get-DemoMemberList -InputObject $body -Name 'value')) {
                $name = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $metric -Name 'name') -Name 'value')
                foreach ($series in (Get-DemoMemberList -InputObject $metric -Name 'timeseries')) {
                    $field = $read.Aggregation.ToLowerInvariant()
                    $data = Get-DemoMemberList -InputObject $series -Name 'data'
                    $point = $data | Where-Object { $null -ne (Get-DemoMemberValue -InputObject $_ -Name $field) } | Select-Object -Last 1
                    if ($null -eq $point) {
                        continue
                    }
                    $value = [double](Get-DemoMemberValue -InputObject $point -Name $field)
                    $stamp = ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $point -Name 'timeStamp')
                    if ($null -ne $stamp -and ($null -eq $newest -or $stamp -gt $newest)) {
                        $newest = $stamp
                    }
                    if ($read.Split) {
                        $dimensions = Get-DemoMemberList -InputObject $series -Name 'metadatavalues'
                        $dimension = $dimensions | Where-Object { ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'name') -Name 'value')).ToLowerInvariant() -eq $read.Split } | Select-Object -First 1
                        $key = [string](Get-DemoMemberValue -InputObject $dimension -Name 'value')
                        if (-not $key) {
                            $key = 'unknown'
                        }
                        if ($read.Split -eq 'state') {
                            $byState[$key] = $value
                        }
                        else {
                            $byWait[$key] = $value
                        }
                    }
                    else {
                        $latest[$name] = $value
                    }
                }
            }
        }
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    [pscustomobject]@{
        Succeeded       = ($errors.Count -lt $reads.Count)
        Error           = ($errors | Select-Object -First 1)
        Latest          = $latest
        LatestUtc       = $(if ($null -ne $newest) { $newest.ToString('o', $invariant) } else { '' })
        ByState         = $byState
        ByWaitEventType = $byWait
        Minutes         = $Minutes
    }
}

function Test-DemoT4MetricFlow {
    <#
    .SYNOPSIS
    METRICS.T4: whether Azure Monitor has T4's CPU and connection metrics from the last -Minutes, with the
    latest values (and the enhanced metrics) as evidence. With -WaitMinutes, reads again every minute until
    they arrive. Internal.

    .DESCRIPTION
    Database Hub's PostgreSQL monitoring charts these Azure Monitor metrics; it has no query-level
    diagnostics for PostgreSQL (https://learn.microsoft.com/fabric/database/hub/monitor-postgresql, checked
    2026-10-23). A server that isn't Ready sends no fresh metrics: Warning.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ServerId,

        [Parameter(Mandatory)]
        [string] $State,

        [ValidateRange(5, 1440)]
        [int] $Minutes = 15,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 0
    )

    $docUrl = [string](Get-DemoPostgresSetting)['docUrls']['hubMonitor']
    if (-not $ServerId) {
        return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Warning' -Message 'T4''s server isn''t known (the resource group has no deploymentId tag), so its metrics weren''t read.' -Remediation 'Deploy it with scripts/deploy.ps1.' -DocUrl $docUrl)
    }
    if ($State -ne 'Ready') {
        return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Warning' -Message ('T4 is {0}, so it sends no fresh metrics.' -f $State) -Evidence ([ordered]@{ state = $State }) -Remediation 'start-demo.ps1 starts it; metrics arrive within a few minutes.' -DocUrl $docUrl)
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    while ($true) {
        $snapshot = Get-DemoT4MetricSnapshot -Config $Config -ServerId $ServerId -Minutes $Minutes
        $evidence = [ordered]@{ latestUtc = $snapshot.LatestUtc; minutes = $Minutes; latest = $snapshot.Latest; sessionsByState = $snapshot.ByState; sessionsByWaitEventType = $snapshot.ByWaitEventType }
        $flowing = $snapshot.Succeeded -and $snapshot.Latest.Contains('cpu_percent') -and $snapshot.Latest.Contains('active_connections')
        if ($flowing -or [DateTime]::UtcNow -ge $deadline) {
            break
        }
        Start-Sleep -Seconds 60
    }
    if (-not $snapshot.Succeeded) {
        return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Fail' -Message ('Azure Monitor''s metrics for T4 couldn''t be read: {0}' -f $snapshot.Error) -Evidence $evidence -Remediation 'Check that you can read the resource group (Reader or higher) and run again.' -DocUrl 'https://learn.microsoft.com/rest/api/monitor/metrics/list')
    }
    if ($flowing) {
        $enhanced = if ($snapshot.ByState.Count -gt 0) { ', with the enhanced metrics' } else { '; the enhanced metrics have no data yet' }
        return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Pass' -Message ('Azure Monitor has T4''s metrics from the last {0} minutes (CPU {1:N0}%, {2:N0} active connection(s){3}), which Database Hub''s PostgreSQL dashboard charts.' -f $Minutes, $snapshot.Latest['cpu_percent'], $snapshot.Latest['active_connections'], $enhanced) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Warning' -Message ('Azure Monitor has no CPU or connection metrics for T4 from the last {0} minutes yet.' -f $Minutes) -Evidence $evidence -Remediation 'A server that just started or was just created sends metrics within a few minutes; run validate.ps1 -Area T4 again.' -DocUrl $docUrl)
}

function Get-DemoT4StoppedUtc {
    <#
    .SYNOPSIS
    When T4 was last stopped, from the Azure activity log's last succeeded stop operation within the last
    eight days, or $null. A stopped flexible server starts on its own seven days later. Internal.

    .DESCRIPTION
    The query passes --end-time as well: with --start-time alone, the Azure CLI ends the range at the start
    plus --offset (6 hours by default), so an eight-day look-back found nothing (live, 2026-10-26).
    Sources: https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server,
    https://learn.microsoft.com/cli/azure/monitor/activity-log#az-monitor-activity-log-list
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[datetime]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ServerId,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $now = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)
    $start = $now.AddDays(-8).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    $end = $now.AddMinutes(5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    $events = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('monitor', 'activity-log', 'list', '--resource-id', $ServerId, '--start-time', $start, '--end-time', $end, '--max-events', '1000', '--query', '[].{operation: operationName.value, status: status.value, time: eventTimestamp}', '--output', 'json') -AsJson -AllowFailure
    $stops = foreach ($entry in @($events)) {
        if ([string](Get-DemoMemberValue -InputObject $entry -Name 'operation') -ieq 'Microsoft.DBforPostgreSQL/flexibleServers/stop/action' -and [string](Get-DemoMemberValue -InputObject $entry -Name 'status') -ieq 'Succeeded') {
            ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $entry -Name 'time')
        }
    }
    $latest = @($stops | Where-Object { $null -ne $_ } | Sort-Object -Descending) | Select-Object -First 1
    return $latest
}

function Format-DemoT4MetricText {
    # One line for status.ps1 from a metric snapshot: CPU, memory, connections, sessions by state and wait, the
    # oldest transaction, and deadlocks. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Snapshot
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $latest = $Snapshot.Latest
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in @(@('cpu_percent', 'CPU {0:N0}%'), @('memory_percent', 'memory {0:N0}%'), @('active_connections', '{0:N0} active connection(s)'), @('cpu_credits_remaining', '{0:N0} CPU credit(s) left'), @('storage_percent', 'storage {0:N0}%'))) {
        if ($latest.Contains($pair[0])) {
            $parts.Add([string]::Format($culture, $pair[1], $latest[$pair[0]]))
        }
    }
    if ($Snapshot.ByState.Count -gt 0) {
        $parts.Add('sessions ' + (@($Snapshot.ByState.Keys | ForEach-Object { [string]::Format($culture, '{0} {1:N0}', $_, $Snapshot.ByState[$_]) }) -join ', '))
    }
    $waits = @($Snapshot.ByWaitEventType.Keys | Where-Object { $Snapshot.ByWaitEventType[$_] -gt 0 })
    if ($waits.Count -gt 0) {
        $parts.Add('waiting on ' + (@($waits | ForEach-Object { [string]::Format($culture, '{0} {1:N0}', $_, $Snapshot.ByWaitEventType[$_]) }) -join ', '))
    }
    if ($latest.Contains('longest_transaction_time_sec')) {
        $parts.Add([string]::Format($culture, 'oldest transaction {0:N0} s', $latest['longest_transaction_time_sec']))
    }
    if ($latest.Contains('deadlocks')) {
        $parts.Add([string]::Format($culture, '{0:N0} deadlock(s) in the last minute with data', $latest['deadlocks']))
    }
    if ($parts.Count -eq 0) {
        return 'no Azure Monitor metrics in the last {0} minutes yet' -f $Snapshot.Minutes
    }
    return ($parts -join '; ')
}

function ConvertFrom-DemoT4ServerJson {
    # The "server" object from the runner's 'status --json' output for T4, even when Run Command cut the front of
    # the output: it's near the document's end, before the profile host's node (Phase 25b). $null when it isn't
    # there. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    $index = $Text.LastIndexOf('"server"', [System.StringComparison]::Ordinal)
    if ($index -lt 0) {
        return $null
    }
    $start = $Text.IndexOf('{', $index)
    if ($start -lt 0) {
        return $null
    }
    $depth = 0
    for ($i = $start; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '{') {
            $depth++
        }
        elseif ($Text[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) {
                try {
                    return ($Text.Substring($start, $i - $start + 1) | ConvertFrom-Json -Depth 8)
                }
                catch {
                    return $null
                }
            }
        }
    }
    return $null
}
