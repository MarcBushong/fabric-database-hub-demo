# The DbHub-Stop job statuses that mean a job ended (2026-11-04): Completed, or one that didn't finish its work. The safety
# stop's coverage (Get-DemoT4RestartCoverage) reads the last one.
# https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account
$script:T4StopJobEndedStatuses = @('Completed', 'Failed', 'Stopped', 'Suspended')

# T4's documented sizes (ADR 0019): the default, General Purpose Standard_D4ds_v5 (4 vCores, since 2026-11-04, for
# autonomous tuning; user-directed), the fallback's Standard_D4ads_v5 (4 vCores) and Standard_D2ds_v5 (2 vCores), and the
# Burstable sizes a configuration can set to stay cheap. The fallback's order is the first three.
# https://learn.microsoft.com/azure/postgresql/compute-storage/concepts-compute (checked 2026-11-04)
$script:T4Sizes = @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5', 'Standard_B1ms', 'Standard_B2s')
$script:T4FallbackSizes = @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
# The same sizes, cheapest first by tier and vCores (Burstable before General Purpose, fewer vCores first; never a price,
# ADR 0016), for the fallback of a size t4SkuName sets (2026-11-09). Standard_D4ds_v5 and Standard_D4ads_v5 share the
# vCore price, and the default comes first.
$script:T4CostOrder = @('Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5')
# The states of a server that's deployed, whatever it's doing (ServerState in Servers - Get, API 2025-08-01): not Dropping
# ("Server is being deleted") and not Provisioning ("being created"). After a failed attempt, a server in another state is
# checked against the T4 deployment's own operations before it counts as created: Azure keeps a server it refused as a
# shell for a few minutes (live, 2026-11-09).
# https://learn.microsoft.com/rest/api/postgresql/servers/get (checked 2026-11-09)
$script:T4DeployedStates = @('Ready', 'Stopped', 'Starting', 'Stopping', 'Updating', 'Restarting', 'Disabled', 'Inaccessible')

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
    T4's compute size: the t4SkuName setting, or the profile's size (General Purpose Standard_D4ds_v5 since 2026-11-04)
    when it isn't set. When Azure refuses that size with SkuNotAvailable at creation, deploy.ps1's fallback moves on
    (Get-DemoT4FallbackOrder, ADR 0019): the size once more in another zone the region lists, then, without t4SkuName,
    Standard_D4ads_v5 (4 vCores) and Standard_D2ds_v5 (2 vCores, autonomous tuning off), and, for a size t4SkuName sets
    (2026-11-09), the next size Azure accepts, cheapest first. It records what it used; Resolve-DemoEffectiveConfig puts
    the recorded size here while the configuration still asks for the size Azure refused. Internal.
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
    return (Get-DemoT4DefaultSkuName -Config $Config)
}

function Get-DemoT4DefaultSkuName {
    # The profile's T4 size, what a configuration without t4SkuName gets: General Purpose Standard_D4ds_v5 since
    # 2026-11-04 (user-directed, for autonomous tuning; ADR 0016 and ADR 0019). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $catalog = Get-DemoProfile
    $profileName = if ($Config['profile']) { [string]$Config['profile'] } else { 'lowest-cost' }
    return [string]$catalog.profiles[$profileName].t4.skuName
}

function Test-DemoT4SkuExplicit {
    # True when the configuration file sets t4SkuName, and nothing filled it in: a size that Resolve-DemoEffectiveConfig
    # or the deployment filled in carries t4SkuSource, which the schema doesn't allow in the file (additionalProperties
    # false), and the size t4SkuName set then stays in t4SkuPinned (Get-DemoT4PinnedSku). Pure. Internal.
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

function Get-DemoT4PinnedSku {
    # The size the person set in t4SkuName, or '' (2026-11-09): the file's t4SkuName, or, in a copy whose size the fallback,
    # a record, or the server filled in (Copy-DemoT4Config), the one t4SkuName had set (t4SkuPinned). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if (Test-DemoT4SkuExplicit -Config $Config) {
        return [string]$Config['t4SkuName']
    }
    if ($Config.Contains('t4SkuPinned') -and -not [string]::IsNullOrWhiteSpace([string]$Config['t4SkuPinned'])) {
        return [string]$Config['t4SkuPinned']
    }
    return ''
}

function Get-DemoT4AskedSku {
    # The size the configuration asks for (2026-11-09): the one t4SkuName sets (Get-DemoT4PinnedSku), or the default. The
    # fallback starts from it, and its notice compares the size it used with it. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $pinned = Get-DemoT4PinnedSku -Config $Config
    if ($pinned) {
        return $pinned
    }
    return (Get-DemoT4DefaultSkuName -Config $Config)
}

function Copy-DemoT4Config {
    <#
    A copy of the configuration with T4's size set (and T4 on), or with T4 off (-Off), marked with where that came from in
    t4SkuSource (Phase 28 follow-up): record (the resource group's DbHubT4Size tag), fallback (the fallback's next size,
    whose cost check may still be to come), server (an existing server's own size), deployed (what this run's
    template deployed), or retry (2026-11-09: the default size again after a Refused record, because this run deploys the
    template and Azure's regional capacity changes). So it's never taken for a size the file sets (Test-DemoT4SkuExplicit),
    and a size the file set stays in t4SkuPinned (2026-11-09), so the fallback and its notice still know what was asked
    for (Get-DemoT4AskedSku). -Zone sets the zone a new server is created in (the fallback's retry in another zone; '' is
    no preference). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('record', 'fallback', 'server', 'deployed', 'retry')]
        [string] $Source,

        [string] $SkuName = '',

        [switch] $Off,

        [ValidateSet('', '1', '2', '3')]
        [string] $Zone = ''
    )

    $copy = [ordered]@{}
    foreach ($key in $Config.Keys) {
        $copy[$key] = $Config[$key]
    }
    $pinned = Get-DemoT4PinnedSku -Config $Config
    if ($pinned) {
        $copy['t4SkuPinned'] = $pinned
    }
    if ($Off) {
        $copy['t4Enabled'] = $false
    }
    elseif ($SkuName) {
        $copy['t4Enabled'] = $true
        $copy['t4SkuName'] = $SkuName
    }
    if ($PSBoundParameters.ContainsKey('Zone')) {
        $copy['t4AvailabilityZone'] = [string]$Zone
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
    if ($name -cin $script:T4Sizes) {
        return $name
    }
    return ''
}

function Get-DemoT4SkuSpec {
    <#
    A documented T4 size's tier, vCores, and Retail Prices meter. The tier follows the size, as in
    infra/modules/demo.bicep: Standard_B sizes are Burstable (one meter per server-hour), and Standard_D<n>ds_v5 and
    Standard_D<n>ads_v5 are General Purpose (a vCore-hour meter of their series times their vCores). Internal.
    Source: https://learn.microsoft.com/azure/postgresql/compute-storage/concepts-compute (checked 2026-11-04)
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
    if ($SkuName -match '^Standard_D(\d+)ads_v5$') {
        return [pscustomobject]@{ SkuName = $SkuName; Tier = 'GeneralPurpose'; VCores = [int]$Matches[1]; Product = 'Azure Database for PostgreSQL Flexible Server General Purpose Dadsv5 Series Compute'; Meter = 'vCore'; PerVCore = $true }
    }
    throw ('{0} isn''t a documented T4 size ({1}).' -f $SkuName, ($script:T4Sizes -join ', '))
}

function Test-DemoT4SizeIncrease {
    <#
    Whether moving an existing T4 from -From to -To raises its hourly price, so the move is priced first (review of PR 20,
    2026-11-04): General Purpose costs more than Burstable, and within a tier more vCores cost more (the documented sizes:
    Standard_B1ms, Standard_B2s, Standard_D2ds_v5, and Standard_D4ds_v5 and Standard_D4ads_v5, which share the vCore price).
    A size it doesn't know counts as a raise, so it's priced. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $From,

        [Parameter(Mandatory)]
        [string] $To
    )

    try {
        return ((Get-DemoT4SizeRank -SkuName $To) -gt (Get-DemoT4SizeRank -SkuName $From))
    }
    catch {
        return $true
    }
}

function Get-DemoT4SizeRank {
    # A documented T4 size's cost class: General Purpose above Burstable, and more vCores above fewer, never a price (ADR
    # 0016). Standard_D4ds_v5 and Standard_D4ads_v5 share one (the same vCore price). Throws for a size it doesn't know.
    # Pure. Internal.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $SkuName
    )

    $spec = Get-DemoT4SkuSpec -SkuName $SkuName
    return ([int]$spec.VCores + $(if ($spec.Tier -eq 'GeneralPurpose') { 1000 } else { 0 }))
}

function Get-DemoT4FallbackOrder {
    <#
    The sizes T4's fallback tries, in order, after Azure refused the size the configuration asks for (Get-DemoT4AskedSku)
    with SkuNotAvailable, in another zone the region lists too (ADR 0019):
    - Without t4SkuName: Standard_D4ads_v5, then Standard_D2ds_v5, as since 2026-11-04.
    - For a size t4SkuName sets (2026-11-09, user-directed: "fall back automatically, cheapest first, with a Warning"): the
      other documented sizes that cost as much or more, cheapest first, then the cheaper ones, nearest first, so a 4-vCore
      size tries its peer before smaller ones. Standard_B1ms: Standard_B2s, Standard_D2ds_v5, Standard_D4ds_v5,
      Standard_D4ads_v5. Standard_D4ds_v5: Standard_D4ads_v5, Standard_D2ds_v5, Standard_B2s, Standard_B1ms.
    The order follows tier and vCores (Get-DemoT4SizeRank), never a price (ADR 0016). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $asked = Get-DemoT4AskedSku -Config $Config
    if (-not (Get-DemoT4PinnedSku -Config $Config)) {
        return [string[]]@($script:T4FallbackSizes | Where-Object { $_ -cne $asked })
    }
    $rank = Get-DemoT4SizeRank -SkuName $asked
    $up = @($script:T4CostOrder | Where-Object { $_ -cne $asked -and (Get-DemoT4SizeRank -SkuName $_) -ge $rank })
    $down = @($script:T4CostOrder | Where-Object { (Get-DemoT4SizeRank -SkuName $_) -lt $rank })
    [array]::Reverse($down)
    return [string[]]@($up + $down)
}

function Get-DemoT4NextSku {
    # The size T4's fallback tries after -Current, in the asked size's order (Get-DemoT4FallbackOrder), or '' when it tried
    # them all, or -Current isn't one of them. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $Current
    )

    $steps = [string[]]@(@(Get-DemoT4AskedSku -Config $Config) + @(Get-DemoT4FallbackOrder -Config $Config))
    $index = [array]::IndexOf($steps, $Current)
    if ($index -lt 0 -or $index + 1 -ge $steps.Count) {
        return ''
    }
    return $steps[$index + 1]
}

function ConvertTo-DemoT4RefusedRecord {
    # DbHubT4Refused's value (2026-11-09): the sizes Azure refused for T4 with SkuNotAvailable, the asked size first, each
    # with the zones it was tried in ('any' for no zone preference), and when, as in
    # "Standard_B1ms@1,2;Standard_B2s@1;2026-11-09T21:25:13Z"; within a tag's 256 characters. -Refusal items have Sku and
    # Zones. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Refusal = @(),

        [string] $TimeUtc = ''
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Refusal | Where-Object { $null -ne $_ })) {
        $zoneValue = Get-DemoMemberValue -InputObject $item -Name 'Zones'
        $zones = @(@($zoneValue) | Where-Object { [string]$_ -in '1', '2', '3', 'any' } | ForEach-Object { [string]$_ })
        $parts.Add($(if ($zones.Count -gt 0) { '{0}@{1}' -f [string]$item.Sku, ($zones -join ',') } else { [string]$item.Sku }))
    }
    if ($parts.Count -eq 0) {
        return ''
    }
    if ($TimeUtc) {
        $parts.Add($TimeUtc)
    }
    $value = $parts -join ';'
    return $(if ($value.Length -le 256) { $value } else { $value.Substring(0, 256) })
}

function ConvertFrom-DemoT4RefusedRecord {
    # Reads DbHubT4Refused (ConvertTo-DemoT4RefusedRecord): Asked (its first size, or ''), Refusals (Sku and Zones), and
    # TimeUtc. An empty or unreadable value gives an empty record. Pure. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Value = ''
    )

    $refusals = [System.Collections.Generic.List[object]]::new()
    $time = ''
    foreach ($part in @(([string]$Value) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($part -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?Z$') {
            $time = $part
            continue
        }
        if ($part -cmatch '^(?<sku>Standard_[A-Za-z0-9_]+)(@(?<zones>[a-z0-9,]+))?$' -and $Matches['sku'] -cin $script:T4Sizes) {
            $sku = [string]$Matches['sku']
            $zoneText = [string]$Matches['zones']
            $zones = [string[]]@($zoneText -split ',' | Where-Object { $_ -in '1', '2', '3', 'any' })
            $refusals.Add([pscustomobject]@{ Sku = $sku; Zones = $zones })
        }
    }
    return [pscustomobject]@{ Asked = $(if ($refusals.Count -gt 0) { [string]$refusals[0].Sku } else { '' }); Refusals = $refusals.ToArray(); TimeUtc = $time }
}

function Test-DemoT4RecordInEffect {
    <#
    Whether the size T4's fallback recorded (DbHubT4Size, -Recorded) still applies to this configuration (2026-11-09): it
    stands in for the size the configuration asks for (Get-DemoT4AskedSku) while that's the size Azure refused, the first
    one in DbHubT4Refused (-Refused). A record without DbHubT4Refused comes from the fallback without t4SkuName, or from a
    scale to the default that Azure refused, so it holds only while t4SkuName isn't set (review finding 5). So a server the
    fallback created keeps its size on later runs, with no resize and no refusal again, until t4SkuName names another
    size. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $Recorded = '',

        [AllowEmptyString()]
        [AllowNull()]
        [string] $Refused = ''
    )

    if (-not ($Recorded -cin $script:T4Sizes)) {
        return $false
    }
    $asked = (ConvertFrom-DemoT4RefusedRecord -Value $Refused).Asked
    if (-not $asked) {
        return (-not (Get-DemoT4PinnedSku -Config $Config))
    }
    return ($asked -ceq (Get-DemoT4AskedSku -Config $Config))
}

function Format-DemoT4ZoneText {
    # Where Azure refused a size, in the order tried (2026-11-09): "zone 1", "zones 1 and 2", or, with an attempt without a
    # zone preference ('any'), "no zone preference, then zone 2". '' for none. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Zone = @()
    )

    $tried = @(@($Zone) | Where-Object { [string]$_ -in '1', '2', '3', 'any' } | ForEach-Object { [string]$_ })
    if ($tried.Count -eq 0) {
        return ''
    }
    if ($tried -notcontains 'any') {
        if ($tried.Count -eq 1) {
            return ('zone {0}' -f $tried[0])
        }
        return ('zones {0} and {1}' -f (($tried | Select-Object -SkipLast 1) -join ', '), $tried[-1])
    }
    return (@($tried | ForEach-Object { if ($_ -eq 'any') { 'no zone preference' } else { 'zone {0}' -f $_ } }) -join ', then ')
}

function Get-DemoT4Tuning {
    <#
    .SYNOPSIS
    Whether T4 gets autonomous tuning (2026-11-04, user-directed; ADR 0019): Query Store and index tuning in REPORT mode,
    which the template sets only when Enabled. Returns Enabled, Status, Message, Remediation, SkuName, Tier, VCores, and
    Switch (t4AutonomousTuning as the file sets it, or $null). Pure. Internal.

    .DESCRIPTION
    Autonomous tuning works on "any currently supported compute SKU with at least 4 vCores", and the Query Store it needs
    shouldn't run on Burstable ("Don't enable query store on the Burstable pricing tier as it causes performance
    problems"), so the size must be General Purpose or Memory Optimized with at least 4 vCores
    (config/versions.json postgresql.autonomousTuning.minVCores). t4AutonomousTuning, unset meaning on:
    - unset or true, with a size that fits: Enabled, Pass.
    - unset, with a size that doesn't (a t4SkuName you set, or the fallback's Standard_D2ds_v5): off, Warning, with why.
    - true, with a t4SkuName you set that doesn't: off, Fail, with the exact fix (preflight stops the run).
    - true, with the fallback's size that doesn't: off, Warning (2026-11-09: tuning never leaves T4 out).
    - false: off, Not selected; the template leaves the parameters as they are.
    -SkuName is the size to judge (the fallback's step); by default, the configuration's.
    Sources (checked 2026-11-04): https://learn.microsoft.com/azure/postgresql/monitor/concepts-autonomous-tuning (updated
    2026-07-16), https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $SkuName = ''
    )

    $switchValue = if ($Config.Contains('t4AutonomousTuning') -and $null -ne $Config['t4AutonomousTuning']) { [bool]$Config['t4AutonomousTuning'] } else { $null }
    $size = if ($SkuName) { $SkuName } else { Get-DemoT4SkuName -Config $Config }
    $spec = Get-DemoT4SkuSpec -SkuName $size
    $minVCores = [int](Get-DemoPostgresSetting)['autonomousTuning']['minVCores']
    $fits = $spec.Tier -ne 'Burstable' -and $spec.VCores -ge $minVCores
    $tierText = if ($spec.Tier -eq 'GeneralPurpose') { 'General Purpose' } else { $spec.Tier }
    $sized = '{0} ({1}, {2} vCore{3})' -f $size, $tierText, $spec.VCores, $(if ($spec.VCores -eq 1) { '' } else { 's' })
    $result = [ordered]@{ Enabled = $false; Status = 'Not selected'; Message = ''; Remediation = ''; SkuName = $size; Tier = $spec.Tier; VCores = $spec.VCores; Switch = $switchValue }
    $needs = 'it needs a General Purpose or Memory Optimized size with at least {0} vCores, because it runs only on {0} vCores or more and Query Store shouldn''t run on Burstable' -f $minVCores
    if ($switchValue -eq $false) {
        $result.Message = 't4AutonomousTuning is false, so T4 gets no autonomous tuning; its Query Store and index-tuning parameters are left as they are.'
    }
    elseif ($fits) {
        $result.Enabled = $true
        $result.Status = 'Pass'
        $result.Message = 'T4 gets autonomous tuning at {0}: Query Store captures the top queries, and index tuning runs in REPORT mode every 60 minutes, so its index and table recommendations show in the Azure portal (the server''s Intelligent Performance > Autonomous tuning), not in Database Hub.' -f $sized
    }
    elseif ($switchValue -eq $true -and (Test-DemoT4SkuExplicit -Config $Config) -and $size -ceq [string]$Config['t4SkuName']) {
        $result.Status = 'Fail'
        $result.Message = 't4AutonomousTuning is true, but T4''s size {0} can''t run autonomous tuning: {1}.' -f $sized, $needs
        $result.Remediation = 'Set t4SkuName to Standard_D4ds_v5 (or remove it: that''s the default) or Standard_D4ads_v5; or set t4AutonomousTuning to false (or remove it, which turns tuning off on this size with a Warning).'
    }
    elseif ($switchValue -eq $true) {
        # 2026-11-09 (user-directed): T4 is part of every deployment, so a size its fallback chose never leaves it out for
        # autonomous tuning; T4 gets the size with tuning off, and says so.
        $result.Status = 'Warning'
        $result.Message = 't4AutonomousTuning is true, but T4 gets {0} from its fallback, because Azure refused the size it asks for here, and that size can''t run autonomous tuning: {1}. T4 is part of every deployment, so it''s created with autonomous tuning off.' -f $sized, $needs
        $result.Remediation = 'To have autonomous tuning, ask for access to Standard_D4ds_v5 or Standard_D4ads_v5 with a Region access request (Learn: Resolve capacity errors), then set t4SkuName to that size and run ./scripts/deploy.ps1.'
    }
    else {
        $result.Status = 'Warning'
        $result.Message = 'Autonomous tuning is off for T4 at {0}: {1}. Database Hub''s PostgreSQL visuals don''t need it.' -f $sized, $needs
        $result.Remediation = 'Nothing to do for the demo. To have it, remove t4SkuName (the default is Standard_D4ds_v5) or set it to Standard_D4ds_v5 or Standard_D4ads_v5; to say you don''t want it, set t4AutonomousTuning to false.'
    }
    return [pscustomobject]$result
}

function New-DemoT4TuningResult {
    # <Prefix>.T4.TUNING from Get-DemoT4Tuning (2026-11-04, ADR 0019), or Not selected when T4 is off. -Why adds why T4
    # has this size (the fallback's step). Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $SkuName = '',

        [string] $Why = '',

        [ValidateSet('PREFLIGHT', 'DEPLOY')]
        [string] $CheckPrefix = 'PREFLIGHT'
    )

    $checkId = '{0}.T4.TUNING' -f $CheckPrefix
    $area = if ($CheckPrefix -eq 'PREFLIGHT') { 'preflight' } else { 't4' }
    $docUrl = [string](Get-DemoPostgresSetting)['autonomousTuning']['docUrls']['autonomousTuning']
    if (-not (Test-DemoT4Enabled -Config $Config)) {
        return (New-DemoResult -CheckId $checkId -Area $area -Target 'T4' -Status 'Not selected' -Message 'T4 is off in this configuration, so autonomous tuning doesn''t apply.' -DocUrl $docUrl)
    }
    $tuning = Get-DemoT4Tuning -Config $Config -SkuName $SkuName
    $message = if ($Why) { '{0} {1}' -f $tuning.Message, $Why } else { $tuning.Message }
    $evidence = [ordered]@{ enabled = $tuning.Enabled; skuName = $tuning.SkuName; tier = $tuning.Tier; vCores = $tuning.VCores; switch = $tuning.Switch }
    $parameters = @{ CheckId = $checkId; Area = $area; Target = 'T4'; Status = $tuning.Status; Message = $message; Evidence = $evidence; DocUrl = $docUrl }
    if ($tuning.Remediation) {
        $parameters['Remediation'] = $tuning.Remediation
    }
    return (New-DemoResult @parameters)
}

function New-DemoT4SizeResult {
    <#
    <Prefix>.T4.SIZE (2026-11-04, ADR 0019): the notice that an existing T4 whose size the configuration doesn't set moves
    to the default, General Purpose Standard_D4ds_v5 with autonomous tuning, at this deploy, or why it keeps its size.
    It's said while the move is pending, so once it's done, it isn't said again. -Outcome:
    - Scale: it scales now. A Warning: the server restarts ("When you change the number of vCores or the compute tier, the
      server restarts", typically a minute or less), and it bills more while it runs.
    - Waiting: T4 isn't Ready (deploy.ps1 starts a stopped T4 before the template), so it keeps its size this time.
    - Refused: Azure refused the scale (-Failure, SkuNotAvailable), so it keeps its size, which the resource group records
      (DbHubT4Size), and later runs keep it.
    - Ceiling (review of PR 20): the move's cost check (-Cost, Get-DemoT4GeneralPurposeCost at the larger size, with the
      restart worst case a safety stop allows) put the month over monthlyCeilingUsd, a session over
      sessionCeilingUsd, or found no price, so this deployment keeps the server's size and names the ceiling to raise; the
      next run that deploys the template checks again. Nothing is recorded.
    -Explicit words it for a t4SkuName the configuration changed on an existing server; -Cost on Scale says the check
    passed.
    Internal.
    Source (checked 2026-11-04; updated 2026-07-16): https://learn.microsoft.com/azure/postgresql/scale/concepts-scaling-resources
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PREFLIGHT', 'DEPLOY')]
        [string] $CheckPrefix,

        [Parameter(Mandatory)]
        [string] $ServerSku,

        [Parameter(Mandatory)]
        [string] $SkuName,

        [Parameter(Mandatory)]
        [ValidateSet('Scale', 'Waiting', 'Refused', 'Ceiling')]
        [string] $Outcome,

        [string] $State = '',

        [AllowNull()]
        [pscustomobject] $Failure,

        [AllowNull()]
        [pscustomobject] $Cost,

        [switch] $Explicit
    )

    $checkId = '{0}.T4.SIZE' -f $CheckPrefix
    $area = if ($CheckPrefix -eq 'PREFLIGHT') { 'preflight' } else { 't4' }
    $docUrl = 'https://learn.microsoft.com/azure/postgresql/scale/concepts-scaling-resources'
    $from = '{0} ({1})' -f $ServerSku, $(if ((Get-DemoT4SkuSpec -SkuName $ServerSku).Tier -eq 'GeneralPurpose') { 'General Purpose' } else { 'Burstable' })
    $evidence = [ordered]@{ serverSku = $ServerSku; skuName = $SkuName; outcome = $Outcome; explicit = [bool]$Explicit }
    $keep = 'To keep T4 at {0}, set t4SkuName to {0} in your configuration (autonomous tuning then stays off on a size under 4 vCores); an existing server keeps a size you set.' -f $ServerSku
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -ne $Cost) {
        foreach ($name in 'SkipReason', 'MonthlyWorstCaseUsd', 'SessionUsd', 'MonthlyCeilingUsd', 'SessionCeilingUsd', 'RestartAssumption') {
            $evidence[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = Get-DemoMemberValue -InputObject $Cost -Name $name
        }
    }
    switch ($Outcome) {
        'Scale' {
            $who = if ($CheckPrefix -eq 'PREFLIGHT') { 'deploy.ps1 scales it' } else { 'this deployment scales it' }
            $message = if ($Explicit) {
                'T4 exists as {0}, and your configuration sets t4SkuName to {1}, so {2}, which restarts it, usually for a minute or less.' -f $from, $SkuName, $who
            }
            else {
                'T4 exists as {0}, and your configuration doesn''t set t4SkuName, so {1} to the default, General Purpose {2} with 4 vCores and autonomous tuning (since 2026-11-04), which restarts it, usually for a minute or less. The cost checks price it at {2}.' -f $from, $who, $SkuName
            }
            if ($null -ne $Cost -and $null -ne $Cost.HourlyUsd) {
                $message += ' Its cost check passed: {0}.' -f (Format-DemoT4FallbackCostText -Cost $Cost)
            }
            $remediation = if ($Explicit) { 'Nothing to do. To keep T4 at {0}, set t4SkuName back to {0}.' -f $ServerSku } else { 'Nothing to do. {0}' -f $keep }
            return (New-DemoResult -CheckId $checkId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
        }
        'Ceiling' {
            $where = if ($Explicit) { 'to {0}, the size your configuration sets in t4SkuName,' -f $SkuName } else { 'to the default, General Purpose {0} with autonomous tuning,' -f $SkuName }
            $reason = [string](Get-DemoMemberValue -InputObject $Cost -Name 'SkipReason')
            $why = switch ($reason) {
                'MonthlyCeiling' { [string]::Format($culture, 'put the demo''s month at {0:N2} USD, over monthlyCeilingUsd ({1:N2} USD)', [double]$Cost.MonthlyWorstCaseUsd, [double]$Cost.MonthlyCeilingUsd) }
                'SessionCeiling' { [string]::Format($culture, 'put a session at {0:N2} USD, over sessionCeilingUsd ({1:N2} USD)', [double]$Cost.SessionUsd, [double]$Cost.SessionCeilingUsd) }
                default { 'need a price the Azure Retail Prices API didn''t give just now{0}' -f $(if ($Cost.PriceError) { ' (' + $Cost.PriceError + ')' } else { '' }) }
            }
            $message = 'T4 exists as {0}. Moving it {1} would {2}, so this deployment keeps its size, and the next run that deploys the template checks again.' -f $from, $where, $why
            if ($reason -ne 'Price' -and $null -ne $Cost.HourlyUsd) {
                $message += ' The check: {0}.' -f (Format-DemoT4FallbackCostText -Cost $Cost)
            }
            $back = if ($Explicit) { 'Or set t4SkuName back to {0}.' -f $ServerSku } else { $keep }
            $remediation = switch ($reason) {
                'MonthlyCeiling' {
                    $safety = if ([string]$Cost.RestartAssumption -eq 'RestOfMonth') { ' Or put the nightly safety stop fully in place (./scripts/deploy.ps1 sets it up, and an Owner runs ./scripts/grant-safety-stop.ps1 once when deploy.ps1 couldn''t assign its role), so each of T4''s 7-day restarts counts as about a day.' } else { '' }
                    [string]::Format($culture, 'To move T4 to {0}, raise monthlyCeilingUsd to at least {1:N0} (the budget follows it), then run ./scripts/deploy.ps1 -FromStage Infrastructure again.{2} {3}', $SkuName, [System.Math]::Ceiling([double]$Cost.MonthlyWorstCaseUsd), $safety, $back)
                }
                'SessionCeiling' { [string]::Format($culture, 'To move T4 to {0}, raise sessionCeilingUsd to at least {1:N0}, then run ./scripts/deploy.ps1 -FromStage Infrastructure again. {2}', $SkuName, [System.Math]::Ceiling([double]$Cost.SessionUsd), $back) }
                default { 'Run ./scripts/deploy.ps1 -FromStage Infrastructure again once the Azure Retail Prices API answers: the move is priced first. {0}' -f $back }
            }
            return (New-DemoResult -CheckId $checkId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices')
        }
        'Waiting' {
            $evidence['state'] = $State
            $message = 'T4 exists as {0} and is {1}, not Ready, so this deployment keeps its size; the default, {2} with autonomous tuning, comes with the next ./scripts/deploy.ps1 while T4 runs.' -f $from, $(if ($State) { $State } else { 'in an unknown state' }), $SkuName
            return (New-DemoResult -CheckId $checkId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation ('Run ./scripts/deploy.ps1 again once T4 is Ready (./scripts/start-demo.ps1 starts it). {0}' -f $keep) -DocUrl $docUrl)
        }
        default {
            if ($null -ne $Failure) {
                $evidence['refusedUtc'] = $Failure.TimeUtc
            }
            $message = 'Azure refused to scale T4 to {0} (SkuNotAvailable{1}), so T4 keeps {2}, and later runs keep it too (the resource group''s DbHubT4Size records it); autonomous tuning stays off on a size under 4 vCores.' -f $SkuName, $(if ($null -ne $Failure) { ', at ' + $Failure.TimeUtc } else { '' }), $from
            return (New-DemoResult -CheckId $checkId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation ('Nothing to do: T4 works at its size. To have the default, first ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors), then set t4SkuName to {0} and run ./scripts/deploy.ps1, which moves T4 after checking its cost; the fallback only chooses a size for a new server, so a refusal of that move is a Fail.' -f $SkuName) -DocUrl 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors')
        }
    }
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
    The verdict on T4's 2-vCore fallback, General Purpose Standard_D2ds_v5 (ADR 0019; the last size the fallback tries
    since T4's 4-vCore default, 2026-11-04), from the demo's estimate with T4 at that size: Allowed only when its compute
    was priced, the worst-case month is within monthlyCeilingUsd, and a session is within sessionCeilingUsd. Pure.
    Internal.

    .DESCRIPTION
    The worst case counts Azure starting a stopped flexible server again on its own after seven days ("The server remains
    stopped for seven days unless you restart it sooner", https://learn.microsoft.com/azure/postgresql/overview;
    https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server): the estimate's light-use month plus
    its T4 restart worst case (Get-DemoCostEstimate: about a day per restart where a safety stop is fully in
    place, otherwise the rest of the month's compute at that size), with T4's storage, its private DNS zone, and, where
    the subscription's plans are on Standard (what a tenant policy enforces, PREFLIGHT.POLICY.DEFENDER), Defender CSPM
    and Defender for open-source relational databases. Unpriced names what the Retail Prices API had no price for, which
    the totals leave out, and Defender for Cloud when its plans weren't read. Returns Allowed, SkipReason
    (MonthlyCeiling, SessionCeiling, Price, or ''), SkuName, HourlyUsd, T4LightUseMonthlyUsd and T4MonthlyWorstCaseUsd (T4
    alone), LightUseMonthlyUsd and MonthlyWorstCaseUsd (the demo's month with it), SessionUsd, MonthlyCeilingUsd,
    SessionCeilingUsd, DefenderIncluded, Unpriced, Location, PriceError, and RestartAssumption (SafetyStop, RestOfMonth,
    or '').
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
    # T4 alone: its fixed costs and its compute for the light-use hours plus the restart worst case the estimate counted
    # (T4RestartHours: the rest of the month, or about a day per restart where a safety stop is in place;
    # 2026-11-04). An estimate without it counts every hour of the month.
    $restartHours = Get-DemoMemberValue -InputObject $Estimate -Name 'T4RestartHours'
    $t4Hours = if ($null -ne $restartHours) { [System.Math]::Min($hoursPerMonth, [double](Get-DemoMemberValue -InputObject $Estimate -Name 'LightUseHoursPerMonth') + [double]$restartHours) } else { $hoursPerMonth }
    $t4Worst = if ($null -ne $hourly) { [System.Math]::Round([double](Get-DemoMemberValue -InputObject $Estimate -Name 'T4FixedMonthly') + $hourly * $t4Hours, 2) } else { $null }
    # T4 alone at light use (2026-11-09): its fixed costs and its compute for the light-use hours, for the notice of an
    # automatic size change, which compares two sizes.
    $t4Light = if ($null -ne $hourly) { [System.Math]::Round([double](Get-DemoMemberValue -InputObject $Estimate -Name 'T4FixedMonthly') + $hourly * [double](Get-DemoMemberValue -InputObject $Estimate -Name 'LightUseHoursPerMonth'), 2) } else { $null }
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
        T4LightUseMonthlyUsd  = $t4Light
        T4MonthlyWorstCaseUsd = $t4Worst
        LightUseMonthlyUsd    = $(if ($null -ne $Estimate) { [System.Math]::Round([double](Get-DemoMemberValue -InputObject $Estimate -Name 'LightUseMonthly'), 2) } else { $null })
        MonthlyWorstCaseUsd   = $(if ($null -ne $Estimate) { $monthlyWorst } else { $null })
        SessionUsd            = $(if ($null -ne $Estimate) { $session } else { $null })
        MonthlyCeilingUsd     = $monthlyCeiling
        SessionCeilingUsd     = $sessionCeiling
        DefenderIncluded      = $defenderIncluded
        Unpriced              = $unpriced.ToArray()
        Location              = [string]$Config['location']
        PriceError            = $PriceError
        RestartAssumption     = [string](Get-DemoMemberValue -InputObject $Estimate -Name 'T4RestartAssumption')
    }
}

function Get-DemoT4GeneralPurposeCost {
    <#
    .SYNOPSIS
    The cost check right before T4's fallback creates Standard_D2ds_v5, its 2-vCore size (ADR 0019), and, with -SkuName,
    right before deploy.ps1 moves an existing T4 to a larger size: the default Standard_D4ds_v5, or a t4SkuName the
    configuration changed (review of PR 20, 2026-11-04). The demo's estimate with T4 at that size, priced from the Azure
    Retail Prices API now (Get-DemoCostEstimate, with the subscription's Defender for Cloud plans, the T2 golden snapshots,
    and the safety stops' coverage of T4's 7-day restart, all read-only), and its verdict
    (ConvertTo-DemoT4FallbackCost). Never throws: an estimate that can't be made is a verdict that doesn't allow it
    (Price). -Cache (2026-11-09) keeps what doesn't depend on the size (the Defender plans, the golden snapshots, the safety
    stops' coverage, and the retail prices read) for the next size the same run prices. Internal.
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
        [object] $T3UseFreeLimit,

        [string] $SkuName = 'Standard_D2ds_v5',

        [AllowNull()]
        [hashtable] $Cache = $null
    )

    $priced = Copy-DemoT4Config -Config $Config -Source fallback -SkuName $SkuName
    $parameters = @{ Config = $priced; NetworkMode = $NetworkMode }
    if ($null -ne $T3UseFreeLimit) {
        $parameters['T3UseFreeLimit'] = [bool]$T3UseFreeLimit
    }
    if ($null -ne $Cache -and $Cache.ContainsKey('Shared')) {
        foreach ($key in $Cache['Shared'].Keys) {
            $parameters[$key] = $Cache['Shared'][$key]
        }
    }
    else {
        $shared = @{ PriceCache = @{} }
        try {
            $shared['DefenderPlans'] = @(Get-DemoDefenderPlan -SubscriptionId ([string]$Config['subscriptionId']))
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The Defender for Cloud plans couldn''t be read, so T4''s estimate at {0} leaves them out: {1}' -f $SkuName, (Protect-DemoText -Text $_.Exception.Message))
        }
        try {
            $shared['GoldenSnapshots'] = @(Get-DemoT2GoldenSnapshot -Config $Config)
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The T2 golden snapshots couldn''t be listed, so T4''s estimate at {0} leaves them out: {1}' -f $SkuName, (Protect-DemoText -Text $_.Exception.Message))
        }
        # A safety stop caps the restart worst case when it's fully in place (2026-11-04, ADR 0024); never throws.
        $shared['T4RestartCoverage'] = Get-DemoT4RestartCoverage -Config $Config
        foreach ($key in $shared.Keys) {
            $parameters[$key] = $shared[$key]
        }
        if ($null -ne $Cache) {
            $Cache['Shared'] = $shared
        }
    }
    try {
        return (ConvertTo-DemoT4FallbackCost -Estimate (Get-DemoCostEstimate @parameters) -Config $priced -SkuName $SkuName)
    }
    catch {
        $problem = Protect-DemoText -Text $_.Exception.Message
        Write-DemoLog -Level Warning -Message ('T4 couldn''t be priced at {0}: {1}' -f $SkuName, $problem)
        return (ConvertTo-DemoT4FallbackCost -Estimate $null -Config $priced -SkuName $SkuName -PriceError $problem)
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
    $worst = if ([string](Get-DemoMemberValue -InputObject $Cost -Name 'RestartAssumption') -eq 'SafetyStop') { 'its worst case, Azure starting a stopped server again on its own after 7 days, counted as about a day per restart because a safety stop is in place,' } else { 'its worst case, every hour of a month because Azure starts a stopped server again on its own after 7 days,' }
    $text = [string]::Format($culture, 'about {0:N3} USD an hour while it runs (list price in {1}, Azure Retail Prices API, read now); {7} is {2:N2} USD a month for T4 with its storage and Defender plans, and {3:N2} USD for the demo''s month against monthlyCeilingUsd ({4:N2} USD); a session is {5:N2} USD against sessionCeilingUsd ({6:N2} USD)', [object[]]@([double]$Cost.HourlyUsd, $Cost.Location, [double]$Cost.T4MonthlyWorstCaseUsd, [double]$Cost.MonthlyWorstCaseUsd, [double]$Cost.MonthlyCeilingUsd, [double]$Cost.SessionUsd, [double]$Cost.SessionCeilingUsd, $worst))
    if (@($Cost.Unpriced).Count -gt 0) {
        $text += '. Not priced, so left out of these totals: {0}' -f (@($Cost.Unpriced) -join '; ')
    }
    return $text
}

function Select-DemoT4StartSku {
    # Where T4's fallback starts, from what preflight's checks found (their startSku evidence): the furthest step wins, in
    # -Order, the fallback's order with '' (the asked size) first (ADR 0019): by default the one without t4SkuName,
    # '', Standard_D4ads_v5, Standard_D2ds_v5; for a size t4SkuName sets, '' and Get-DemoT4FallbackOrder (2026-11-09). An
    # older run's None counts as Standard_D2ds_v5, and Refused, or anything else, as '': no step leaves T4 out since
    # 2026-11-09. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Sku = @(),

        [string[]] $Order = @('', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
    )

    $best = 0
    foreach ($item in @($Sku)) {
        $value = if ([string]$item -ceq 'None') { 'Standard_D2ds_v5' } else { [string]$item }
        $rank = [array]::IndexOf($Order, $value)
        if ($rank -gt $best) {
            $best = $rank
        }
    }
    return [string]$Order[$best]
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

function Get-DemoT4SkuZone {
    <#
    The availability zones the region's PostgreSQL flexible server capabilities list for -SkuName in its tier's edition
    (General Purpose, or Burstable for a size t4SkuName sets, 2026-11-09; supportedServerEditions[].supportedServerSkus[]
    .supportedZones, through 'az postgres flexible-server list-skus'), for the fallback's one retry in another zone
    (2026-11-04, ADR 0019). An empty list when it can't be read. Never throws. A read. Internal.
    https://learn.microsoft.com/cli/azure/postgres/flexible-server#az-postgres-flexible-server-list-skus
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $SkuName
    )

    try {
        $editionName = (Get-DemoT4SkuSpec -SkuName $SkuName).Tier
        $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('postgres', 'flexible-server', 'list-skus', '--location', [string]$Config['location'], '--output', 'json') -AllowFailure
        if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
            return @()
        }
        $items = @([string]$read.StdOut | ConvertFrom-Json -Depth 64)
        if ($items.Count -eq 1 -and $null -ne (Get-DemoMemberValue -InputObject $items[0] -Name 'value')) {
            # Get-DemoMemberList returns its list as one object: assign it before going through it.
            $listed = Get-DemoMemberList -InputObject $items[0] -Name 'value'
            $items = @($listed)
        }
        foreach ($item in $items) {
            $editions = Get-DemoMemberList -InputObject $item -Name 'supportedServerEditions'
            foreach ($edition in $editions) {
                if ([string](Get-DemoMemberValue -InputObject $edition -Name 'name') -ne $editionName) {
                    continue
                }
                $skus = Get-DemoMemberList -InputObject $edition -Name 'supportedServerSkus'
                foreach ($sku in $skus) {
                    if ([string](Get-DemoMemberValue -InputObject $sku -Name 'name') -ceq $SkuName) {
                        $zones = Get-DemoMemberList -InputObject $sku -Name 'supportedZones'
                        return [string[]]@($zones | ForEach-Object { [string]$_ } | Where-Object { $_ -in '1', '2', '3' } | Sort-Object -Unique)
                    }
                }
            }
        }
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The zones the region lists for {0} couldn''t be read: {1}' -f $SkuName, (Protect-DemoText -Text $_.Exception.Message))
    }
    return @()
}

function Get-DemoT4CreateFailure {
    <#
    .SYNOPSIS
    T4's last refused creation: the resource group's pgflex01 deployment (the template's T4 module) when it
    failed with SkuNotAvailable. Returns Sku, Zone, and TimeUtc, or $null. A read. Internal.

    .DESCRIPTION
    Azure answers SkuNotAvailable ("Specified SKU is not supported in this region") when a size isn't offered
    in the region or is temporarily unavailable there, even when the Location Based Capabilities API lists it
    (live, 2026-10-26). Learn's remedy is another size. deploy.ps1's fallback moves on by itself (ADR 0019): without
    t4SkuName, Standard_D4ds_v5 once more in another zone the region lists, then Standard_D4ads_v5, then Standard_D2ds_v5
    (autonomous tuning off) after its cost check; for a size t4SkuName sets (2026-11-09), the size once more in another
    zone, then the next size Azure accepts, cheapest first (Get-DemoT4FallbackOrder); only this code moves it on,
    and no other failure (a quota, a policy denial, a transient error) does. Deploy and preflight use this to report it
    and to move the fallback on.
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
    The result for a T4 size Azure refused with SkuNotAvailable on record (Get-DemoT4CreateFailure): a Warning when the
    configuration names another zone to try first, or a Fail when nothing moves the fallback on, which leaves the run
    NOT DONE. Since 2026-11-09 (user-directed) a size t4SkuName sets has the fallback too (Get-DemoT4FallbackOrder), so its
    remediation never asks for another size to be set: deploy.ps1 moves on by itself, and only a refusal of every size
    needs a Region access request. Internal.
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
    $evidence = [ordered]@{ refusedSku = $Failure.Sku; refusedZone = $Failure.Zone; refusedUtc = $Failure.TimeUtc }
    $docUrl = 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors'
    if ($Status -eq 'Warning') {
        $message = 'Azure refused T4''s size {0} with {1} at {2} (SkuNotAvailable: not supported in the region, or temporarily unavailable). This run tries {0} once more in zone {3}, as t4AvailabilityZone says; if Azure refuses it again, deploy.ps1''s fallback moves on to its next size by itself, and says which.' -f $Failure.Sku, $where, $Failure.TimeUtc, $NextZone
        return (New-DemoResult -CheckId $CheckId -Area 't4' -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation 'Nothing to do: T4 is part of every deployment, and deploy.ps1''s fallback chooses the size by itself.' -DocUrl $docUrl)
    }
    $message = 'Azure refused to create T4 at size {0} with {1} at {2}: SkuNotAvailable ("Specified SKU is not supported in this region"), although the region''s capability list includes it, so the size is unavailable there for now.' -f $Failure.Sku, $where, $Failure.TimeUtc
    return (New-DemoResult -CheckId $CheckId -Area 't4' -Target 'T4' -Status 'Fail' -Message $message -Evidence $evidence -Remediation 'Ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors), then run ./scripts/deploy.ps1, which tries the sizes again.' -DocUrl $docUrl)
}

function New-DemoT4FallbackResult {
    <#
    .SYNOPSIS
    DEPLOY.T4.SKU (or a preflight check) for T4's fallback (ADR 0019), without t4SkuName, or, with -Pinned, for a size it sets: a
    Warning that says what this run does about a size Azure refused with SkuNotAvailable. Internal.

    .DESCRIPTION
    The fallback since T4's 4-vCore default (2026-11-04, user-directed):
    - Zone: Azure refused Standard_D4ds_v5; this run tries it once more in -Zone, another zone the region's capabilities
      list for it.
    - Standard_D4ads_v5: Azure refused Standard_D4ds_v5 (in another zone too, when one was tried); this run tries
      Standard_D4ads_v5, General Purpose with 4 vCores on AMD processors, so autonomous tuning stays on.
    - Standard_D2ds_v5: Azure refused both 4-vCore sizes, and -Cost (ConvertTo-DemoT4FallbackCost) allows the 2-vCore
      fallback: this run creates T4 as Standard_D2ds_v5, with autonomous tuning off (it needs 4 vCores), and its hourly
      list price and worst case from the Azure Retail Prices API, read now.
    - None: Azure refused both 4-vCore sizes, and -Cost doesn't allow the 2-vCore fallback (its worst case would exceed
      monthlyCeilingUsd, a session would exceed sessionCeilingUsd, or its price couldn't be read), so this run finishes
      without T4; the next run that deploys the template checks the fallback again.
    - Refused: Azure refused Standard_D2ds_v5 too, or, with -TuningRequired (t4AutonomousTuning true), the 4-vCore sizes,
      which leave no size that runs autonomous tuning; this run finishes without T4, and the next run that deploys the
      template tries the sizes again (2026-11-09; Resolve-DemoEffectiveConfig, DEPLOY.T4.RETRY).
    For a size t4SkuName sets (-Pinned, 2026-11-09, user-directed), the steps are Zone, then any documented size
    (Get-DemoT4FallbackOrder: the next one Azure accepts, cheapest first), with -Cost's check, which only reports, and
    Refused when Azure refused them all (-Tried: Sku and Zones), a Fail that ends the run NOT DONE.
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
        [ValidateSet('Zone', 'Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5', 'Standard_B1ms', 'Standard_B2s', 'None', 'Refused')]
        [string] $Next,

        [AllowNull()]
        [pscustomobject] $Cost,

        [ValidateSet('', '1', '2', '3')]
        [string] $Zone = '',

        [switch] $TuningRequired,

        [ValidateSet('DEPLOY.T4.SKU', 'PREFLIGHT.T4.FALLBACK')]
        [string] $CheckId = 'DEPLOY.T4.SKU',

        [string] $Pinned = '',

        [AllowEmptyCollection()]
        [object[]] $Tried = @()
    )

    $docUrl = 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors'
    $area = if ($CheckId -like 'PREFLIGHT.*') { 'preflight' } else { 't4' }
    $where = ''
    # Where a later run starts: never None any more (2026-11-09: no step leaves T4 out).
    $startSku = switch ($Next) { 'Zone' { '' } 'None' { 'Standard_D2ds_v5' } 'Refused' { '' } default { $Next } }
    $evidence = [ordered]@{ next = $Next; startSku = $startSku }
    $refusal = 'SkuNotAvailable, on record or found by preflight'
    if ($null -ne $Refused) {
        $where = if ($Refused.Zone) { 'zone {0}' -f $Refused.Zone } else { 'no zone preference' }
        $refusal = '{0}, at {1}; SkuNotAvailable' -f $where, $Refused.TimeUtc
        $evidence['refusedSku'] = $Refused.Sku
        $evidence['refusedZone'] = $Refused.Zone
        $evidence['refusedUtc'] = $Refused.TimeUtc
    }
    $keep = 'Nothing to do. To choose T4''s size yourself, set t4SkuName in your configuration; if Azure refuses it, deploy.ps1 moves on to the next size Azure accepts, cheapest first.'
    if ($Pinned) {
        # 2026-11-09 (user-directed: "fall back automatically, cheapest first, with a Warning"): a size t4SkuName sets that
        # Azure refuses moves on too.
        $evidence['pinnedSku'] = $Pinned
        $pinnedKeep = 'Nothing to do: T4 is part of every deployment. A Warning names the size it gets and both monthly estimates once it''s created, and later runs keep that size while t4SkuName sets {0}.' -f $Pinned
        if ($Next -eq 'Zone') {
            $evidence['retryZone'] = $Zone
            $message = 'Azure refused {0}, the size t4SkuName sets ({1}). This run tries it once more in zone {2}, which the region''s capabilities list for it; if Azure refuses that too, it moves on to the next size Azure accepts, cheapest first.' -f $Pinned, $refusal, $Zone
            return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $pinnedKeep -DocUrl $docUrl)
        }
        if ($Next -eq 'Refused') {
            $triedText = @(foreach ($item in @($Tried | Where-Object { $null -ne $_ })) { $zoneValue = Get-DemoMemberValue -InputObject $item -Name 'Zones'; $zoneText = Format-DemoT4ZoneText -Zone ([string[]]@($zoneValue)); if ($zoneText) { '{0} ({1})' -f [string]$item.Sku, $zoneText } else { [string]$item.Sku } }) -join ', '
            $evidence['tried'] = @(foreach ($item in @($Tried | Where-Object { $null -ne $_ })) { [string]$item.Sku })
            $message = 'Azure refused every size T4''s fallback tries for {0}, the size t4SkuName sets: {1} ({2}). T4 is part of every deployment, so this run deploys the rest and ends NOT DONE. Azure''s regional capacity changes, and every run tries the sizes again.' -f $Pinned, $triedText, $refusal
            $remediation = 'Ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors), then run ./scripts/deploy.ps1, which tries the sizes again.'
            return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Fail' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
        }
        $spec = Get-DemoT4SkuSpec -SkuName $(if ($Next -eq 'None') { 'Standard_D2ds_v5' } else { $Next })
        $size = '{0} ({1}, {2} vCore{3})' -f $spec.SkuName, $(if ($spec.Tier -eq 'GeneralPurpose') { 'General Purpose' } else { 'Burstable' }), $spec.VCores, $(if ($spec.VCores -eq 1) { '' } else { 's' })
        $what = if ($null -ne $Refused) { 'Azure refused {0} ({1})' -f [string]$Refused.Sku, $refusal } else { 'Azure doesn''t offer {0}, the size t4SkuName sets, here now ({1})' -f $Pinned, $refusal }
        $message = '{0}, so this run creates T4 as {1}, the next size of the fallback for {2}, cheapest first' -f $what, $size, $Pinned
        $remediation = $pinnedKeep
        if ($null -ne $Cost) {
            foreach ($name in 'HourlyUsd', 'T4LightUseMonthlyUsd', 'T4MonthlyWorstCaseUsd', 'MonthlyWorstCaseUsd', 'SessionUsd', 'MonthlyCeilingUsd', 'SessionCeilingUsd', 'SkipReason') {
                $evidence[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = Get-DemoMemberValue -InputObject $Cost -Name $name
            }
            if ($Cost.Allowed) {
                $message += ': {0}.' -f (Format-DemoT4FallbackCostText -Cost $Cost)
            }
            else {
                # Its cost check only reports (2026-11-09: T4 is part of every deployment).
                $skip = Get-DemoT4SkipReason -Cost $Cost
                $message += ', although its cost check doesn''t pass: {0}. T4 is part of every deployment, so a ceiling never leaves it out.' -f $skip.Because
                $remediation = $skip.Remediation
            }
        }
        else {
            $message += '.'
        }
        if ($spec.Tier -ne 'GeneralPurpose' -or $spec.VCores -lt [int](Get-DemoPostgresSetting)['autonomousTuning']['minVCores']) {
            $message += ' Autonomous tuning is off at this size.'
        }
        return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
    }
    if ($Next -eq 'Zone') {
        $evidence['retryZone'] = $Zone
        $message = 'Azure refused T4''s size Standard_D4ds_v5 ({0}). This run tries it once more in zone {1}, which the region''s capabilities list for it; if Azure refuses that too, it moves on to Standard_D4ads_v5.' -f $refusal, $Zone
        return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $keep -DocUrl $docUrl)
    }
    if ($Next -eq 'Standard_D4ads_v5') {
        $message = 'Azure refused T4''s default size, Standard_D4ds_v5 ({0}). This run tries Standard_D4ads_v5, General Purpose with 4 vCores on AMD processors at the same price per vCore (estimate-cost.ps1 prices it at run time), so autonomous tuning stays on, and later runs keep it.' -f $refusal
        return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $keep -DocUrl $docUrl)
    }
    if ($Next -eq 'Refused') {
        # 2026-11-09 (user-directed): T4 is part of every deployment, so this is a Fail, and the run ends NOT DONE once the
        # rest is deployed; nothing is recorded, so every run tries the sizes again.
        if ($TuningRequired) {
            # A caller from before 2026-11-09; autonomous tuning no longer stops the fallback.
            $evidence['tuningRequired'] = $true
        }
        $message = 'Azure refused every size T4''s fallback tries, the last one Standard_D2ds_v5 ({0}), after both 4-vCore sizes, Standard_D4ds_v5 (in another zone too, when the region lists one) and Standard_D4ads_v5. T4 is part of every deployment, so this run deploys the rest and ends NOT DONE. Azure''s regional capacity changes, and every run tries the sizes again.' -f $refusal
        $remediation = 'Ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors), or set t4SkuName to a size Azure offers you in this region, then run ./scripts/deploy.ps1.'
        return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Fail' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
    }

    # Standard_D2ds_v5 or None: the 2-vCore fallback, as its cost check decided.
    $why = if ($null -ne $Refused) { 'Azure refused both of T4''s 4-vCore sizes, Standard_D4ds_v5 and then Standard_D4ads_v5 ({0})' -f $refusal } else { 'Azure refuses T4''s 4-vCore sizes, Standard_D4ds_v5 and Standard_D4ads_v5, here ({0})' -f $refusal }
    $evidence['fallbackSku'] = 'Standard_D2ds_v5'
    $evidence['fallbackTier'] = 'GeneralPurpose'
    if ($null -ne $Cost) {
        foreach ($name in 'HourlyUsd', 'T4MonthlyWorstCaseUsd', 'MonthlyWorstCaseUsd', 'SessionUsd', 'MonthlyCeilingUsd', 'SessionCeilingUsd', 'DefenderIncluded', 'SkipReason') {
            $evidence[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = $Cost.$name
        }
        $evidence['unpriced'] = @($Cost.Unpriced)
    }
    if ($Next -eq 'Standard_D2ds_v5') {
        $message = '{0}, so this run creates T4 as General Purpose Standard_D2ds_v5 (2 vCores, 8 GiB), with autonomous tuning off, because it needs at least 4 vCores: {1}. Later runs keep this size.' -f $why, (Format-DemoT4FallbackCostText -Cost $Cost)
        $remediation = 'Nothing to do: Database Hub''s PostgreSQL visuals don''t need autonomous tuning. ./scripts/stop-demo.ps1 stops T4 between sessions and says when Azure starts it again on its own. To choose T4''s size yourself, set t4SkuName; if Azure refuses it, deploy.ps1 moves on to the next size Azure accepts, cheapest first.'
        return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl 'https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server')
    }
    $skipReason = if ($null -ne $Cost) { [string]$Cost.SkipReason } else { 'Price' }
    $evidence['skipReason'] = $skipReason
    $skip = Get-DemoT4SkipReason -Cost $Cost
    # 2026-11-09 (user-directed): T4 is part of every deployment, so a cost check that doesn't pass is a Warning, and T4 is
    # created at Standard_D2ds_v5 anyway.
    $message = '{0}, so this run creates T4 as General Purpose Standard_D2ds_v5 (2 vCores, 8 GiB), with autonomous tuning off, although its cost check doesn''t pass: {1}. T4 is part of every deployment, so a ceiling never leaves it out. Later runs keep this size.' -f $why, $skip.Because
    if ($null -ne $Cost -and @($Cost.Unpriced).Count -gt 0) {
        $message += ' Not priced, so left out of these totals: {0}.' -f (@($Cost.Unpriced) -join '; ')
    }
    return (New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $skip.Remediation -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices')
}

function Get-DemoT4SkipReason {
    # Why the 2-vCore fallback's cost check (ConvertTo-DemoT4FallbackCost) doesn't pass, which T4 is created anyway for (2026-11-09), and the fix: Because
    # (a clause) and Remediation, invariant culture (ADR 0019). -Ahead words the remediation for preflight, before Azure
    # has refused anything. Pure. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [pscustomobject] $Cost,

        [switch] $Ahead
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $reason = if ($null -ne $Cost) { [string]$Cost.SkipReason } else { 'Price' }
    $then = if ($Ahead) { 'Nothing to do unless Azure refuses both 4-vCore sizes. To keep the month within your ceilings then, ' } else { 'To keep the month within your ceilings, ' }
    $again = if ($Ahead) { '' } else { ', and stop T4 between sessions with ./scripts/stop-demo.ps1' }
    $worst = if ($null -ne $Cost -and [string](Get-DemoMemberValue -InputObject $Cost -Name 'RestartAssumption') -eq 'SafetyStop') { 'its worst case (Azure starts a stopped server again on its own after 7 days, about a day each time while a safety stop is in place)' } else { 'its worst case, every hour of a month (Azure starts a stopped server again on its own after 7 days)' }
    switch ($reason) {
        'MonthlyCeiling' {
            $because = [string]::Format($culture, '{3} at about {0:N3} USD an hour, with its storage and Defender plans, brings the demo''s month to {1:N2} USD, over monthlyCeilingUsd ({2:N2} USD)', [double]$Cost.HourlyUsd, [double]$Cost.MonthlyWorstCaseUsd, [double]$Cost.MonthlyCeilingUsd, $worst)
            $remediation = [string]::Format($culture, '{0}raise monthlyCeilingUsd to at least {1:N0} in your configuration (the budget follows it){2}.', $then, [System.Math]::Ceiling([double]$Cost.MonthlyWorstCaseUsd), $again)
        }
        'SessionCeiling' {
            $because = [string]::Format($culture, 'with it, a session is estimated at {0:N2} USD, over sessionCeilingUsd ({1:N2} USD)', [double]$Cost.SessionUsd, [double]$Cost.SessionCeilingUsd)
            $remediation = [string]::Format($culture, '{0}raise sessionCeilingUsd to at least {1:N0} in your configuration{2}.', $then, [System.Math]::Ceiling([double]$Cost.SessionUsd), $again)
        }
        default {
            $problem = if ($null -ne $Cost -and $Cost.PriceError) { ' ({0})' -f $Cost.PriceError } else { '' }
            $because = 'its price couldn''t be read from the Azure Retail Prices API{0}' -f $problem
            $remediation = if ($Ahead) { 'Nothing to do: deploy.ps1 prices the fallback again right before it creates T4.' } else { 'Nothing to do: T4 is created; ./scripts/estimate-cost.ps1 prices it once the Azure Retail Prices API answers.' }
        }
    }
    return [pscustomobject]@{ Reason = $reason; Because = $because; Remediation = $remediation }
}

function Get-DemoT4FallbackPreflight {
    <#
    .SYNOPSIS
    PREFLIGHT.T4.FALLBACK (ADR 0019): the 2-vCore fallback's cost check in preflight, and where deploy.ps1's fallback
    starts (its evidence's startSku). Returns Result and CostResults (the cost checks to report instead of the
    estimate's own, or $null). Internal.

    .DESCRIPTION
    - -Start Standard_D2ds_v5 (the 4-vCore sizes are ruled out, or an earlier run's record): -Estimate already prices T4
      at that size, so its verdict (ConvertTo-DemoT4FallbackCost) decides. Within both ceilings, the start stays, with a
      Warning that gives the price and the worst case; otherwise the start is None, with a Warning that says why, and the
      ceilings are checked again without T4 (CostResults), which this run leaves out.
    - A T4 that doesn't exist yet and a size the configuration doesn't set, starting at a 4-vCore size: Azure can still
      refuse it at creation although the region lists it (live, West US 3, 2026-10-26, for Standard_B1ms), so the 2-vCore
      step is priced now too, with the same parameters and price cache (only its compute price is read again): a Pass
      within both ceilings, otherwise a Warning that T4 would be left out. deploy.ps1 prices it again right before it
      would create it.
    - A size t4SkuName sets (-Explicit, or one a record stands in for; 2026-11-09, user-directed) for a T4 that doesn't
      exist yet: a Pass that says what deploy.ps1 does if Azure refuses it (the size once more in another zone, then the
      next size Azure accepts, cheapest first, Get-DemoT4FallbackOrder), priced right before each attempt.
    - Otherwise Not selected: T4 exists (deploy.ps1 keeps it, or scales it to the default).
    Its own estimates never throw (review of 20e855c): the 4-vCore start's that fails is a Warning with skipReason Price,
    and when the estimate without T4 fails, CostResults stays $null, so the run's own cost checks, a monthly-ceiling Fail
    included, are what preflight reports.
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
    $notSelected = {
        param([string] $Message)
        [pscustomobject]@{ Result = (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'T4' -Status 'Not selected' -Message $Message -Evidence ([ordered]@{ startSku = $Start })); CostResults = $null }
    }
    if ($Exists) {
        return (& $notSelected ('T4 exists{0}, so the fallback doesn''t apply: deploy.ps1 keeps its size, or scales it to the default (PREFLIGHT.T4.SIZE says when).' -f $(if ($ServerSku) { ' as ' + $ServerSku } else { '' })))
    }
    $pinned = Get-DemoT4PinnedSku -Config $Config
    if ($Explicit -and -not $pinned) {
        $pinned = Get-DemoT4SkuName -Config $Config
    }
    if ($pinned) {
        $order = @(Get-DemoT4FallbackOrder -Config $Config)
        $from = if ($Start) { ' (deploy.ps1 starts at {0}: PREFLIGHT.T4.CAPABILITY or PREFLIGHT.T4.SKU says why)' -f $Start } else { '' }
        $message = 't4SkuName sets {0}{1}. If Azure refuses it when it creates T4 (SkuNotAvailable), deploy.ps1 tries it once more in another zone the region lists, then the next size Azure accepts, cheapest first: {2}. Each size''s cost check runs right before it''s tried and only reports, and a Warning then names the size T4 got and both monthly estimates; later runs keep that size.' -f $pinned, $from, ($order -join ', ')
        return [pscustomobject]@{ Result = (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'T4' -Status 'Pass' -Message $message -Evidence ([ordered]@{ startSku = $Start; pinnedSku = $pinned; order = $order }) -DocUrl 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors'); CostResults = $null }
    }
    if ($Start -eq 'Standard_D2ds_v5') {
        # 2026-11-09 (user-directed): T4 is part of every deployment, so this cost check only reports; the run's own cost
        # checks (PREFLIGHT.COST.*) price T4 at Standard_D2ds_v5, as they always did.
        $cost = ConvertTo-DemoT4FallbackCost -Estimate $Estimate -Config $CostParameters['Config']
        $next = if ($cost.Allowed) { 'Standard_D2ds_v5' } else { 'None' }
        return [pscustomobject]@{ Result = (New-DemoT4FallbackResult -Refused $null -Next $next -Cost $cost -CheckId $checkId); CostResults = $null }
    }

    # A 4-vCore start: the 2-vCore step, priced now for the record.
    $priced = @{} + $CostParameters
    $priced['Config'] = Copy-DemoT4Config -Config $Config -Source fallback -SkuName 'Standard_D2ds_v5'
    try {
        $cost = ConvertTo-DemoT4FallbackCost -Estimate (Get-DemoCostEstimate @priced) -Config $priced['Config']
    }
    catch {
        $problem = Protect-DemoText -Text $_.Exception.Message
        Write-DemoLog -Level Warning -Message ('T4''s 2-vCore fallback couldn''t be priced ahead: {0}' -f $problem)
        $cost = ConvertTo-DemoT4FallbackCost -Estimate $null -Config $priced['Config'] -PriceError $problem
    }
    $evidence = [ordered]@{ startSku = $Start; fallbackSku = 'Standard_D2ds_v5'; fallbackTier = 'GeneralPurpose' }
    foreach ($name in 'HourlyUsd', 'T4MonthlyWorstCaseUsd', 'MonthlyWorstCaseUsd', 'SessionUsd', 'MonthlyCeilingUsd', 'SessionCeilingUsd', 'DefenderIncluded', 'SkipReason') {
        $evidence[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = $cost.$name
    }
    $evidence['unpriced'] = @($cost.Unpriced)
    $premise = 'If Azure refuses T4''s 4-vCore sizes when it creates it (SkuNotAvailable; West US 3 refused Standard_B1ms on 2026-10-26 although it listed it)'
    if ($cost.Allowed) {
        $message = '{0}, deploy.ps1 creates T4 as General Purpose Standard_D2ds_v5, with autonomous tuning off (it needs 4 vCores): {1}. That''s within both ceilings; deploy.ps1 prices it again right before it would create it.' -f $premise, (Format-DemoT4FallbackCostText -Cost $cost)
        return [pscustomobject]@{ Result = (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'T4' -Status 'Pass' -Message $message -Evidence $evidence -DocUrl 'https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server'); CostResults = $null }
    }
    $skip = Get-DemoT4SkipReason -Cost $cost -Ahead
    $message = if ($skip.Reason -eq 'Price') {
        '{0}, deploy.ps1 prices its 2-vCore fallback, Standard_D2ds_v5, right before it would create it; right now, {1}.' -f $premise, $skip.Because
    }
    else {
        '{0}, deploy.ps1''s 2-vCore fallback, Standard_D2ds_v5, would still create T4, because T4 is part of every deployment, though its cost check doesn''t pass: {1}.' -f $premise, $skip.Because
    }
    if (@($cost.Unpriced).Count -gt 0) {
        $message += ' Not priced, so left out of these totals: {0}.' -f (@($cost.Unpriced) -join '; ')
    }
    return [pscustomobject]@{ Result = (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $skip.Remediation -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices'); CostResults = $null }
}

function Resolve-DemoEffectiveConfig {
    <#
    .SYNOPSIS
    The configuration with what earlier runs settled that the file doesn't say: T4's size from the fallback (ADR 0019),
    recorded in the resource group's DbHubT4Size tag, while it still stands in for the size the configuration asks for
    (Test-DemoT4RecordInEffect, with DbHubT4Refused; 2026-11-09). Returns the configuration itself when nothing applies or
    it's already resolved (it carries t4SkuSource), otherwise a copy (Copy-DemoT4Config, which keeps a size t4SkuName sets
    in t4SkuPinned). Pure. Internal.

    .DESCRIPTION
    The record (since T4's 4-vCore default, 2026-11-04; the Phase 28 tag, DbHubT4Sku, is no longer read, so a server its
    fallback created moves to the default at the next deploy):
    - A documented size: T4 uses it, and a redeploy keeps it, while the configuration asks for the size Azure refused,
      DbHubT4Refused's first: the default without t4SkuName, or, since 2026-11-09 (user-directed: a refused t4SkuName
      falls back too), the size t4SkuName sets. So a server the fallback created isn't resized back, and its size isn't
      refused again on every run. A record without DbHubT4Refused (the fallback without t4SkuName, or a scale to the
      default that Azure refused) holds only while t4SkuName isn't set (review finding 5). A t4SkuName that names another
      size wins.
    - None or Refused, which earlier runs wrote when the fallback left T4 out (the 2-vCore size's cost check, or every size
      refused): since 2026-11-09 (user-directed) T4 is part of every deployment, and no record leaves it out. With
      -TemplateRuns (this run deploys the template), T4 is planned at the default size again (t4SkuSource retry), so the
      fallback tries every size again, because Azure's regional capacity changes (DEPLOY.T4.RETRY says so); without it,
      the configuration stays as it is, T4 on (a resume whose T4 doesn't exist starts from preflight: DEPLOY.T4.MISSING).
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
    if (-not $recorded -or -not (Test-DemoT4Enabled -Config $Config)) {
        return $Config
    }
    if ($recorded -cin $script:T4Sizes) {
        if (Test-DemoT4RecordInEffect -Config $Config -Recorded $recorded -Refused ([string](Get-DemoMemberValue -InputObject $State -Name 'T4Refused'))) {
            return (Copy-DemoT4Config -Config $Config -Source record -SkuName $recorded)
        }
        return $Config
    }
    if ($recorded -cin 'None', 'Refused' -and $TemplateRuns -and -not (Test-DemoT4SkuExplicit -Config $Config)) {
        return (Copy-DemoT4Config -Config $Config -Source retry -SkuName (Get-DemoT4DefaultSkuName -Config $Config))
    }
    return $Config
}

function Get-DemoT4MissingResult {
    <#
    .SYNOPSIS
    DEPLOY.T4.MISSING (2026-11-09): a resumed run starts from preflight instead when Azure says T4's server doesn't exist,
    as in a demo deployed before T4 (Phase 24), one whose server was deleted, or one an earlier run's fallback left out
    (DbHubT4Size None or Refused, which no longer leave T4 out). A resume skips preflight, which checks T4's cost against
    the ceilings, the template, which creates T4, and T1's T4 step, which sets it up. Returns that Pass, or $null when the
    resume can go on: no deploymentId to name the server by, a server that exists, or one that couldn't be read (fail
    safe). A read. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State
    )

    if (-not (Test-DemoT4Enabled -Config $Config)) {
        return $null
    }
    $tags = Get-DemoMemberValue -InputObject $State -Name 'Tags'
    $deploymentId = ''
    if ($tags -is [System.Collections.IDictionary] -and $tags.Contains('deploymentId')) {
        $deploymentId = [string]$tags['deploymentId']
    }
    if (-not $deploymentId) {
        return $null
    }
    $current = Get-DemoT4State -Config $Config -DeploymentId $deploymentId
    # A server Azure is deleting (Dropping, 2026-11-09: a server it refused, or one deleted by hand) isn't T4 either.
    $removing = [bool](Get-DemoMemberValue -InputObject $current -Name 'Removing')
    if ([string]$current.State -ne 'NotFound' -and -not $removing) {
        return $null
    }
    $serverName = [string](Get-DemoMemberValue -InputObject $current.Names -Name 'ServerName')
    $why = if ($removing) { 'is being deleted (Dropping: Azure removes a server it refused within minutes, and one deleted by hand too)' } else { 'doesn''t exist (a demo deployed before T4, or a server that was deleted)' }
    $message = 'T4 (Azure Database for PostgreSQL) isn''t deployed yet: its server {0} {1}. Resuming would skip it, so this run starts from preflight instead: preflight checks T4''s cost against your ceilings, the template creates it, and T1 sets it up. What earlier runs finished is checked again and kept.' -f $serverName, $why
    return (New-DemoResult -CheckId 'DEPLOY.T4.MISSING' -Area 't4' -Target 'T4' -Status 'Pass' -Message $message -Evidence ([ordered]@{ serverName = $serverName; recordedStage = [string](Get-DemoMemberValue -InputObject $State -Name 'Stage'); state = [string]$current.State }) -DocUrl 'https://learn.microsoft.com/azure/postgresql/overview')
}

function Test-DemoT4FallbackSize {
    # True when T4 runs, or is to run, at a size its fallback chose instead of the one the configuration asks for: the
    # resource group's DbHubT4Size records another size, and the record holds (Test-DemoT4RecordInEffect; 2026-11-09, a size
    # t4SkuName sets included). A record without DbHubT4Refused counts only for Standard_D4ads_v5 or Standard_D2ds_v5 (only
    # the fallback without t4SkuName writes those, review of 20e855c). It says nothing about whether the server exists
    # (Get-DemoT4ServerEvidence). Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [System.Collections.IDictionary] $Config = @{},

        [AllowNull()]
        [object] $State
    )

    if (-not (Test-DemoT4Enabled -Config $Config)) {
        return $false
    }
    $recorded = [string](Get-DemoMemberValue -InputObject $State -Name 'T4Sku')
    $refused = [string](Get-DemoMemberValue -InputObject $State -Name 'T4Refused')
    if (-not $recorded -or $recorded -ceq (Get-DemoT4AskedSku -Config $Config) -or -not (Test-DemoT4RecordInEffect -Config $Config -Recorded $recorded -Refused $refused)) {
        return $false
    }
    return ([bool](ConvertFrom-DemoT4RefusedRecord -Value $refused).Asked -or $recorded -cin 'Standard_D4ads_v5', 'Standard_D2ds_v5')
}

function Get-DemoT4ServerEvidence {
    <#
    Whether this run's results, or the T4 track's record, show T4's server (review of 20e855c): $true for a T4.SERVER Pass
    or Warning (it exists), a HUB.ESTATE.T4 or METRICS.T4 Pass, a DEPLOY.TEMPLATE Pass with T4 in the template, or a T4
    track that finished a step (DbHubTrackT4: its Server step fails without a server); otherwise $null, and a Servers - Get
    decides. Never $false (review of 64c28b2): a T4.SERVER Fail means a missing server or a read that failed
    (Test-DemoT4), and this run's fallback creating T4 (DEPLOY.T4.SKU next Standard_D2ds_v5) with a DEPLOY.TEMPLATE Fail
    can still have created it, because T4's server depends only on the network (infra/modules/demo.bicep), so another
    resource's failure doesn't stop it. Either one also outweighs the T4 track's record, which can be older. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [object] $State
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $seen = @($all | Where-Object {
            $id = [string]$_.checkId
            $status = [string]$_.status
            ($id -eq 'T4.SERVER' -and $status -in 'Pass', 'Warning') -or ($id -in 'HUB.ESTATE.T4', 'METRICS.T4' -and $status -eq 'Pass') -or
            ($id -eq 'DEPLOY.TEMPLATE' -and $status -eq 'Pass' -and [bool](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'evidence') -Name 't4Enabled'))
        })
    if ($seen.Count -gt 0) {
        return $true
    }
    $creating = @($all | Where-Object { [string]$_.checkId -eq 'DEPLOY.T4.SKU' -and [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'evidence') -Name 'next') -cin 'Standard_D4ads_v5', 'Standard_D2ds_v5', 'Zone' }).Count -gt 0
    $templateFailed = @($all | Where-Object { [string]$_.checkId -eq 'DEPLOY.TEMPLATE' -and [string]$_.status -eq 'Fail' }).Count -gt 0
    if (($creating -and $templateFailed) -or @($all | Where-Object { [string]$_.checkId -eq 'T4.SERVER' -and [string]$_.status -eq 'Fail' }).Count -gt 0) {
        return $null
    }
    if ([string](Get-DemoMemberValue -InputObject $State -Name 'TrackT4')) {
        return $true
    }
    return $null
}

function Format-DemoT4FallbackCreatedText {
    # "T4 created as General Purpose <size> because Azure refused <what> here, with autonomous tuning on (or off); about
    # <price> USD an hour while running": the console line, the status page, and DONE say it the same way (ADR 0019).
    # -HourlyUsd comes from the Azure Retail Prices API; without it, the line says the price couldn't be read. -Tuning is
    # whether this size gets autonomous tuning (Get-DemoT4Tuning). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $HourlyUsd,

        [string] $Location = '',

        [ValidateSet('Standard_D4ads_v5', 'Standard_D2ds_v5')]
        [string] $SkuName = 'Standard_D2ds_v5',

        [bool] $Tuning = $false
    )

    $hourly = Format-DemoT4HourlyText -HourlyUsd $HourlyUsd -Location $Location
    if ($SkuName -eq 'Standard_D4ads_v5') {
        $tuningText = if ($Tuning) { 'with autonomous tuning on' } else { 'with autonomous tuning off (t4AutonomousTuning is false)' }
        return ('T4 created as General Purpose Standard_D4ads_v5 (4 vCores) because Azure refused Standard_D4ds_v5 here, {0}; {1}.' -f $tuningText, $hourly)
    }
    return ('T4 created as General Purpose Standard_D2ds_v5 (2 vCores) because Azure refused the 4-vCore sizes here, so autonomous tuning is off (it needs 4 vCores); {0}.' -f $hourly)
}

function Format-DemoT4HourlyText {
    # "about <price> USD an hour while running (list price in <region>, Azure Retail Prices API)", or that the price couldn't
    # be read (Phase 28 follow-up). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $HourlyUsd,

        [string] $Location = ''
    )

    if ($null -ne $HourlyUsd) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, 'about {0:N3} USD an hour while running (list price in {1}, Azure Retail Prices API)', [double]$HourlyUsd, $Location)
    }
    return 'its hourly list price couldn''t be read just now (./scripts/estimate-cost.ps1 prices it)'
}

function Get-DemoT4FallbackNote {
    <#
    The line deploy.ps1's ending (DONE and NOT DONE, on the console and the status page) adds while T4 runs at a size its
    fallback chose instead of the one the configuration asks for (ADR 0019; Test-DemoT4FallbackSize). It says "created"
    only with evidence that the server exists (review of 20e855c): -Created $true gives -Notice, the size change's notice
    with what was tried and refused and both monthly estimates (Format-DemoT4SizeChangeText, 2026-11-09), or without one,
    the size and the hourly list price the caller read from the Azure Retail Prices API, never a number written here (ADR
    0016), with the 7-day restart; $false (a Servers - Get found no server) says the size was chosen but the server isn't
    created yet, and why (-Why); $null says it couldn't be confirmed. '' when it doesn't apply. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [System.Collections.IDictionary] $Config = @{},

        [AllowNull()]
        [object] $State,

        [AllowNull()]
        [object] $HourlyUsd,

        [AllowNull()]
        [object] $Created,

        [string] $Why = '',

        [string] $Notice = ''
    )

    if (-not (Test-DemoT4FallbackSize -Config $Config -State $State)) {
        return ''
    }
    $location = [string]$Config['location']
    $sku = [string](Get-DemoMemberValue -InputObject $State -Name 'T4Sku')
    $asked = Get-DemoT4AskedSku -Config $Config
    $pinned = [bool](Get-DemoT4PinnedSku -Config $Config)
    $legacy = -not $pinned -and $sku -cin 'Standard_D4ads_v5', 'Standard_D2ds_v5'
    $tierText = if ((Get-DemoT4SkuSpec -SkuName $sku).Tier -eq 'GeneralPurpose') { 'General Purpose' } else { 'Burstable' }
    $tuning = (Get-DemoT4Tuning -Config $Config -SkuName $sku).Enabled
    if ($Created -is [bool] -and $Created) {
        # Whether the nightly safety stop is in place isn't read here, so it's said as a condition (status.ps1 reads it).
        $restart = 'Azure starts a stopped T4 again on its own after 7 days; the nightly safety stop stops it again within a day when it''s in place, at its T3 check or at the next auto-shutdown time, and ./scripts/stop-demo.ps1 and ./scripts/status.ps1 show the date and whether it is.'
        if ($Notice) {
            return ('{0} {1}' -f $Notice, $restart)
        }
        if ($legacy) {
            return ('{0} {1}' -f (Format-DemoT4FallbackCreatedText -HourlyUsd $HourlyUsd -Location $location -SkuName $sku -Tuning $tuning), $restart)
        }
        return ('T4 runs as {0} {1} because Azure refused {2}, the size t4SkuName sets, here; {3}. {4}' -f $tierText, $sku, $asked, (Format-DemoT4HourlyText -HourlyUsd $HourlyUsd -Location $location), $restart)
    }
    $hourly = Format-DemoT4HourlyText -HourlyUsd $HourlyUsd -Location $location
    $origin = if (-not $legacy) { 'because Azure refused {0}, the size t4SkuName sets, here' -f $asked } elseif ($sku -ceq 'Standard_D4ads_v5') { 'because Azure refused Standard_D4ds_v5 here' } else { 'because Azure refused the 4-vCore sizes here, so autonomous tuning is off' }
    if ($Created -is [bool]) {
        $because = if ($Why) { $Why } else { 'no server exists yet: no deployment has created it' }
        return ('T4 isn''t created yet: the fallback chose {0} {1} {2}, {3}, but {4}. The next ./scripts/deploy.ps1 that deploys the template creates it, after checking its price against the ceilings again.' -f $tierText, $sku, $origin, $hourly, $because)
    }
    return ('The fallback chose {0} {1} for T4 {2}, {3}; whether the server exists couldn''t be confirmed just now, and ./scripts/status.ps1 shows it.' -f $tierText, $sku, $origin, $hourly)
}

function Get-DemoT4SizeChangeCost {
    <#
    T4's monthly estimate at the size the configuration asks for and at the size deployed (2026-11-09), for the notice of
    an automatic size change: Get-DemoT4GeneralPurposeCost at each, the same pricing as the fallback's cost check, sharing
    -Cache, so the second one reads only its compute price. Returns Asked and Deployed (ConvertTo-DemoT4FallbackCost's
    verdicts, whose HourlyUsd is $null when a price couldn't be read). Never throws. Internal.
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
        [object] $T3UseFreeLimit,

        [Parameter(Mandatory)]
        [string] $Asked,

        [Parameter(Mandatory)]
        [string] $Deployed,

        [AllowNull()]
        [hashtable] $Cache = $null
    )

    if ($null -eq $Cache) {
        $Cache = @{}
    }
    $askedCost = Get-DemoT4GeneralPurposeCost -Config $Config -NetworkMode $NetworkMode -T3UseFreeLimit $T3UseFreeLimit -SkuName $Asked -Cache $Cache
    $deployedCost = Get-DemoT4GeneralPurposeCost -Config $Config -NetworkMode $NetworkMode -T3UseFreeLimit $T3UseFreeLimit -SkuName $Deployed -Cache $Cache
    return [pscustomobject]@{ Asked = $askedCost; Deployed = $deployedCost }
}

function Format-DemoT4SizeChangeText {
    <#
    The notice for an automatic change of T4's size (2026-11-09, user-directed: "make sure to add a notification of it
    though to say what you tried to deploy and what was deployed included cost difference"), said the same way on the
    console, on the status page's Infrastructure and T4 rows, at DONE and NOT DONE, and by status.ps1: the size the
    configuration asks for and every size Azure refused, with the zones tried (-Refusal: Sku and Zones); the size
    deployed; and T4's monthly estimate at each (-AskedCost and -DeployedCost, ConvertTo-DemoT4FallbackCost), light use
    and worst case, with the difference in USD, labeled as estimates from the Azure Retail Prices API (ADR 0016). -Later
    words it for status.ps1 and a later run, with -Since, when Azure refused it. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $Deployed,

        [AllowEmptyCollection()]
        [object[]] $Refusal = @(),

        [AllowNull()]
        [object] $AskedCost,

        [AllowNull()]
        [object] $DeployedCost,

        [string] $Since = '',

        [switch] $Later
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $asked = Get-DemoT4AskedSku -Config $Config
    $whose = if (Get-DemoT4PinnedSku -Config $Config) { 'the size t4SkuName sets' } else { 'T4''s default size' }
    $spec = Get-DemoT4SkuSpec -SkuName $Deployed
    $sized = '{0} ({1}, {2} vCore{3})' -f $Deployed, $(if ($spec.Tier -eq 'GeneralPurpose') { 'General Purpose' } else { 'Burstable' }), $spec.VCores, $(if ($spec.VCores -eq 1) { '' } else { 's' })
    # A refusal with zones was tried and refused; one without wasn't tried in that run, because preflight or an earlier
    # run found the size unavailable.
    $tried = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Refusal | Where-Object { $null -ne $_ })) {
        $zoneValue = Get-DemoMemberValue -InputObject $item -Name 'Zones'
        $zoneText = Format-DemoT4ZoneText -Zone ([string[]]@($zoneValue))
        if ($zoneText) {
            $tried.Add(('{0} ({1})' -f [string]$item.Sku, $zoneText))
        }
        else {
            $skipped.Add([string]$item.Sku)
        }
    }
    if ($skipped.Count -eq 0 -and $tried.Count -eq 0) {
        $skipped.Add($asked)
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($skipped.Count -gt 0) {
        $parts.Add(('{0} {1} unavailable here (found by preflight or an earlier run)' -f ($skipped -join ' and '), $(if ($skipped.Count -eq 1) { 'was' } else { 'were' })))
    }
    if ($tried.Count -gt 0) {
        $parts.Add(('Azure refused {0} with SkuNotAvailable{1}' -f ($tried -join ', then '), $(if ($Since) { ', at {0}' -f $Since } else { '' })))
    }
    $why = $parts -join ', and '
    $text = if ($Later) {
        'T4 runs as {0} instead of {1}, {2}: deploy.ps1''s fallback created it at that size because {3}.' -f $sized, $asked, $whose, $why
    }
    else {
        'T4 was created as {0} instead of {1}, {2}, because {3}.' -f $sized, $asked, $whose, $why
    }
    $value = { param([object] $Cost, [string] $Name) Get-DemoMemberValue -InputObject $Cost -Name $Name }
    $priced = @($AskedCost, $DeployedCost | Where-Object { $null -ne $_ -and $null -ne (& $value $_ 'T4LightUseMonthlyUsd') -and $null -ne (& $value $_ 'T4MonthlyWorstCaseUsd') }).Count -eq 2
    if ($priced) {
        $askedLight = [double](& $value $AskedCost 'T4LightUseMonthlyUsd')
        $askedWorst = [double](& $value $AskedCost 'T4MonthlyWorstCaseUsd')
        $deployedLight = [double](& $value $DeployedCost 'T4LightUseMonthlyUsd')
        $deployedWorst = [double](& $value $DeployedCost 'T4MonthlyWorstCaseUsd')
        $difference = {
            param([double] $Amount)
            if ([System.Math]::Round($Amount, 2) -ge 0) { [string]::Format($culture, '{0:N2} USD more', $Amount) } else { [string]::Format($culture, '{0:N2} USD less', -$Amount) }
        }
        $location = [string](& $value $DeployedCost 'Location')
        $text += [string]::Format($culture, ' Estimated monthly cost of T4 alone (list prices in {0}, Azure Retail Prices API, read now; estimates): {1} {2:N2} USD at light use and {3:N2} USD in the worst case; {4} {5:N2} USD and {6:N2} USD, so {7} a month at light use and {8} in the worst case, which counts Azure starting a stopped T4 again on its own after 7 days.', [object[]]@($location, $asked, $askedLight, $askedWorst, $Deployed, $deployedLight, $deployedWorst, (& $difference ($deployedLight - $askedLight)), (& $difference ($deployedWorst - $askedWorst))))
    }
    else {
        $text += ' Its estimated monthly cost couldn''t be read just now from the Azure Retail Prices API; ./scripts/estimate-cost.ps1 prices T4 at its size.'
    }
    $tuningAsked = (Get-DemoT4Tuning -Config $Config -SkuName $asked).Enabled
    $tuningDeployed = (Get-DemoT4Tuning -Config $Config -SkuName $Deployed).Enabled
    if ($tuningAsked -and -not $tuningDeployed) {
        $text += ' Autonomous tuning is off at this size: it needs a General Purpose size with at least 4 vCores.'
    }
    elseif ($tuningDeployed -and -not $tuningAsked) {
        $text += ' T4 gets autonomous tuning at this size.'
    }
    return $text
}

function New-DemoT4SizeChangeResult {
    <#
    DEPLOY.T4.FALLBACK, the T4 row's T4.SIZE, or status.ps1's STATUS.T4.SIZE (2026-11-09): the Warning for T4 at a size its
    fallback chose instead of the one the configuration asks for (Format-DemoT4SizeChangeText), with what was tried and
    refused, what was deployed, and both estimates and their differences in its evidence. A Warning, never a block: DONE
    stays reachable. Its remediation says how to change the size. Pure. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $Deployed,

        [AllowEmptyCollection()]
        [object[]] $Refusal = @(),

        [AllowNull()]
        [object] $AskedCost,

        [AllowNull()]
        [object] $DeployedCost,

        [string] $Since = '',

        [switch] $Later,

        [ValidateSet('DEPLOY.T4.FALLBACK', 'T4.SIZE', 'STATUS.T4.SIZE')]
        [string] $CheckId = 'DEPLOY.T4.FALLBACK'
    )

    $asked = Get-DemoT4AskedSku -Config $Config
    $pinned = [bool](Get-DemoT4PinnedSku -Config $Config)
    $summary = {
        param([object] $Cost)
        if ($null -eq $Cost) {
            return $null
        }
        $item = [ordered]@{}
        foreach ($name in 'SkuName', 'HourlyUsd', 'T4LightUseMonthlyUsd', 'T4MonthlyWorstCaseUsd', 'LightUseMonthlyUsd', 'MonthlyWorstCaseUsd') {
            $item[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = Get-DemoMemberValue -InputObject $Cost -Name $name
        }
        return $item
    }
    $askedSummary = & $summary $AskedCost
    $deployedSummary = & $summary $DeployedCost
    $evidence = [ordered]@{
        askedSku    = $asked
        pinned      = $pinned
        deployedSku = $Deployed
        refused     = @(foreach ($item in @($Refusal | Where-Object { $null -ne $_ })) { $zoneValue = Get-DemoMemberValue -InputObject $item -Name 'Zones'; [ordered]@{ sku = [string]$item.Sku; zones = @(@($zoneValue) | ForEach-Object { [string]$_ }) } })
        since       = $Since
        asked       = $askedSummary
        deployed    = $deployedSummary
        estimates   = 'Azure Retail Prices API list prices, read at run time (ADR 0016)'
    }
    foreach ($pair in @(@('lightUseDifferenceUsd', 't4LightUseMonthlyUsd'), @('worstCaseDifferenceUsd', 't4MonthlyWorstCaseUsd'))) {
        $evidence[$pair[0]] = if ($null -ne $askedSummary -and $null -ne $deployedSummary -and $null -ne $askedSummary[$pair[1]] -and $null -ne $deployedSummary[$pair[1]]) { [System.Math]::Round([double]$deployedSummary[$pair[1]] - [double]$askedSummary[$pair[1]], 2) } else { $null }
    }
    $change = 'To choose another size, set t4SkuName to it: deploy.ps1 then moves T4 to it after checking its cost, which restarts T4.'
    $remediation = if ($pinned) {
        'Nothing to do: later runs keep T4 at {0}, so nothing resizes or restarts it. {1} To have {2} itself, ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors); docs/troubleshooting.md says how to move T4 to it then.' -f $Deployed, $change, $asked
    }
    else {
        'Nothing to do: later runs keep T4 at {0}. {1}' -f $Deployed, $change
    }
    return (New-DemoResult -CheckId $CheckId -Area 't4' -Target 'T4' -Status 'Warning' -Message (Format-DemoT4SizeChangeText -Config $Config -Deployed $Deployed -Refusal $Refusal -AskedCost $AskedCost -DeployedCost $DeployedCost -Since $Since -Later:$Later) -Evidence $evidence -Remediation $remediation -DocUrl 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors')
}

function Get-DemoT4RecordedSizeChange {
    <#
    The size change's notice for T4 at a size an earlier run's fallback chose (2026-11-09), for status.ps1 (STATUS.T4.SIZE)
    and the ending of a later deploy.ps1: New-DemoT4SizeChangeResult from the record (DbHubT4Size, and DbHubT4Refused
    with the zones tried and when) and T4's monthly estimate at both sizes now (Get-DemoT4SizeChangeCost). $null when T4
    runs at the size the configuration asks for (Test-DemoT4FallbackSize). Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State,

        [ValidateSet('STATUS.T4.SIZE', 'T4.SIZE', 'DEPLOY.T4.FALLBACK')]
        [string] $CheckId = 'STATUS.T4.SIZE'
    )

    if (-not (Test-DemoT4FallbackSize -Config $Config -State $State)) {
        return $null
    }
    try {
        $resolved = Resolve-DemoEffectiveConfig -Config $Config -State $State
        $recorded = [string](Get-DemoMemberValue -InputObject $State -Name 'T4Sku')
        $refused = ConvertFrom-DemoT4RefusedRecord -Value ([string](Get-DemoMemberValue -InputObject $State -Name 'T4Refused'))
        $asked = Get-DemoT4AskedSku -Config $resolved
        $mode = [string](Get-DemoMemberValue -InputObject $State -Name 'NetworkMode')
        if ($mode -notin 'public', 'private') {
            $mode = if ([string]$Config['networkMode'] -in 'public', 'private') { [string]$Config['networkMode'] } else { 'private' }
        }
        $costs = Get-DemoT4SizeChangeCost -Config $resolved -NetworkMode $mode -T3UseFreeLimit (Get-DemoMemberValue -InputObject $State -Name 'T3UseFreeLimit') -Asked $asked -Deployed $recorded
        $refusals = if (@($refused.Refusals).Count -gt 0) { @($refused.Refusals) } else { @([pscustomobject]@{ Sku = $asked; Zones = [string[]]@() }) }
        return (New-DemoT4SizeChangeResult -Config $resolved -Deployed $recorded -Refusal $refusals -AskedCost $costs.Asked -DeployedCost $costs.Deployed -Since ([string]$refused.TimeUtc) -Later -CheckId $CheckId)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('T4''s size change couldn''t be described: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        return $null
    }
}

function New-DemoT4RecordedOffResult {
    <#
    The Warning that status.ps1 (STATUS.T4) and validate.ps1 (T4.SERVER) give for a T4 server that exists although the
    resource group's record says T4 is off, DbHubT4Size None or Refused (review of 64c28b2): a run before that review could
    record None for a server that a template attempt which failed for another resource had created, and a server bills
    whatever the record says. The next deploy.ps1 keeps it, at its own size, and clears a None record
    (Invoke-DemoTemplateDeployment keeps an existing server's size), while Refused leaves it out of the demo until
    t4SkuName sets its size; stop-demo.ps1 stops it whatever the record says. -Server is Get-DemoT4State's answer for the
    server that exists. The record itself isn't changed (status.ps1 and validate.ps1 are read-only). Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('STATUS.T4', 'T4.SERVER')]
        [string] $CheckId,

        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [ValidateSet('None', 'Refused')]
        [string] $Recorded
    )

    $serverName = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Server -Name 'Names') -Name 'ServerName')
    $state = [string](Get-DemoMemberValue -InputObject $Server -Name 'State')
    $sku = Get-DemoT4ServerSku -Server (Get-DemoMemberValue -InputObject $Server -Name 'Server')
    $size = ''
    if ($sku) {
        $size = ', {0} {1}' -f $(if ((Get-DemoT4SkuSpec -SkuName $sku).Tier -eq 'GeneralPurpose') { 'General Purpose' } else { 'Burstable' }), $sku
    }
    $message = 'T4 ({0}) exists and bills, although the resource group''s record says T4 is off (DbHubT4Size {1}): it''s {2}{3}.' -f $serverName, $Recorded, $(if ($state) { $state } else { 'Unknown' }), $size
    $keep = if ($Recorded -ceq 'None') {
        'The next ./scripts/deploy.ps1 keeps it at its own size and clears the record.'
    }
    else {
        'The next ./scripts/deploy.ps1 keeps it as it is, but leaves it out of the demo while the record says Refused; set t4SkuName to its size{0} to bring it back.' -f $(if ($sku) { ', ' + $sku + ',' } else { '' })
    }
    $remediation = '{0} Meanwhile ./scripts/stop-demo.ps1 stops it with the rest of the demo, and ./scripts/destroy.ps1 removes everything.' -f $keep
    return (New-DemoResult -CheckId $CheckId -Area 't4' -Target 'T4' -Status 'Warning' -Message $message -Evidence ([ordered]@{ server = $serverName; state = $state; skuName = $sku; recorded = $Recorded }) -Remediation $remediation -DocUrl ([string](Get-DemoPostgresSetting)['docUrls']['stopServer']))
}

function Format-DemoT4RestartText {
    <#
    When a stopped T4 starts again on its own, and what that bills, for status.ps1 and stop-demo.ps1 (Phase 28 follow-up):
    Azure starts a stopped flexible server again after 7 days ("The server remains stopped for seven days unless you
    restart it sooner", https://learn.microsoft.com/azure/postgresql/overview; "Server will be automatically started after
    7 days", https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server), so it's the stop time
    plus -Days. -SafetyStop is what stops it again, as Get-DemoT4RestartStopState read it: Nightly (the nightly safety stop,
    ADR 0024) and Scheduled (the on-demand control's daily safety stop, ADR 0020) stop it within a day; NoRole (the
    nightly safety stop is scheduled, but its role isn't assigned), NotScheduled, and Off mean nothing here stops it again;
    Unknown (a read failed) is said as a condition (review of 20e855c). With Nightly and -Config, it names the run that
    stops it (Get-DemoSafetyStopRunAfter): the stop at the auto-shutdown time, or, with -CheckStopsT4, the T3 check, which
    also stops a running T4 since 2026-11-09, when the restart comes between the two. -HourlyUsd is the caller's, from
    the Retail Prices API. Pure, but for a debug log line when the configured times can't be worked out. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $RestartUtc,

        [string] $SkuName = '',

        [AllowNull()]
        [object] $HourlyUsd,

        [ValidateRange(1, 30)]
        [int] $Days = 7,

        [ValidateSet('Off', 'Nightly', 'Scheduled', 'NoRole', 'NotScheduled', 'Unknown')]
        [string] $SafetyStop = 'Off',

        [AllowNull()]
        [System.Collections.IDictionary] $Config,

        [switch] $CheckStopsT4
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $when = if ($null -ne $RestartUtc) { [string]::Format($culture, 'at {0:yyyy-MM-dd HH:mm} UTC, {1} days after the stop', ([datetime]$RestartUtc).ToUniversalTime(), $Days) } else { '{0} days after it was stopped' -f $Days }
    $bills = if ($null -ne $HourlyUsd) { [string]::Format($culture, ', and it then bills compute at about {0:N3} USD an hour ({1}, list price)', [double]$HourlyUsd, $SkuName) } elseif ($SkuName) { ', and it then bills compute at its size ({0})' -f $SkuName } else { ', and it then bills compute' }
    $nightly = ' until the nightly safety stop stops it again, at the next auto-shutdown time.'
    if ($SafetyStop -eq 'Nightly' -and $null -ne $Config) {
        try {
            if ($null -ne $RestartUtc) {
                # The first of the safety stop's runs at or after the restart (2026-11-09: the T3 check stops T4 too).
                $restart = ([datetime]$RestartUtc).ToUniversalTime()
                $run = Get-DemoSafetyStopRunAfter -Config $Config -AfterUtc $restart -WithCheck:$CheckStopsT4
                $gap = $run.Utc - $restart
                $span = if ($gap.TotalMinutes -lt 2) { 'within minutes' } elseif ($gap.TotalMinutes -lt 90) { 'about {0} minutes' -f [int][System.Math]::Round($gap.TotalMinutes) } else { 'about {0} hours' -f [int][System.Math]::Round($gap.TotalHours) }
                $by = if ($run.Run -eq 'Check') { 'the nightly safety stop''s T3 check' } else { 'the nightly safety stop' }
                $nightly = [string]::Format($culture, ' until {0} stops it again at {1:yyyy-MM-dd HH:mm} UTC ({2} {3}), {4} after it starts.', $by, $run.Utc, $run.LocalTime, $run.TimeZone, $span)
            }
            else {
                $times = Get-DemoSafetyStopTime -Config $Config
                $nightly = if ($CheckStopsT4) {
                    ' until the nightly safety stop stops it again, within a day: its T3 check at {0} when it starts between {1} and then, otherwise its stop at the next {1} ({2}).' -f $times.CheckLocalTime, $times.StopLocalTime, $times.TimeZone
                }
                else {
                    ' until the nightly safety stop stops it again, at the next auto-shutdown time ({0} {1}).' -f $times.StopLocalTime, $times.TimeZone
                }
            }
        }
        catch {
            # A configuration whose time zone can't be read keeps the general text; preflight reports the zone itself.
            Write-DemoLog -Level Debug -Message ('The nightly safety stop''s times couldn''t be worked out for T4''s restart: {0}' -f $_.Exception.Message)
        }
    }
    $after = switch ($SafetyStop) {
        'Nightly' { $nightly }
        'Scheduled' { ' until the on-demand control''s daily safety stop stops it again, within a day.' }
        'NoRole' { (' until it''s stopped again: the nightly safety stop is scheduled, but it can''t stop T4 until an Owner assigns its role once ({0}), so run ./scripts/stop-demo.ps1 again once it has started, or ./scripts/destroy.ps1 if the demo stays idle.' -f (Get-DemoSafetyStopCommand)) }
        'Unknown' { ' until it''s stopped again: the nightly safety stop does that within a day if it''s in place, which couldn''t be read just now (./scripts/status.ps1 shows it as STATUS.SAFETYSTOP); otherwise run ./scripts/stop-demo.ps1 again once it has started.' }
        default { ' until it''s stopped again: the nightly safety stop isn''t in place (./scripts/deploy.ps1 sets it up), so nothing here stops it on its own; run ./scripts/stop-demo.ps1 again once it has started, or ./scripts/destroy.ps1 if the demo stays idle.' }
    }
    return ('Azure starts it again on its own {0}{1}{2}' -f $when, $bills, $after)
}

function Get-DemoT4LastStopJob {
    <#
    .SYNOPSIS
    The control's last DbHub-Stop job that ended (the per-run auto-stop or the daily T4 safety stop), from Job - List By
    Automation Account (https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account), the newest by its
    creation time. Returns Ok, Error, Found, Id, Status, and CreatedUtc; a control Automation account that doesn't exist has
    none (Found false). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Name
    )

    $jobs = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url ('https://management.azure.com{0}/jobs' -f $Name.AutomationAccountId) -Query ([ordered]@{ '$filter' = ("properties/runbook/name eq '{0}'" -f $Name.StopRunbook); 'api-version' = '2024-10-23' })
    if (-not $jobs.Ok) {
        if ($jobs.Missing) {
            return [pscustomobject]@{ Ok = $true; Error = ''; Found = $false; Id = ''; Status = ''; CreatedUtc = $null }
        }
        return [pscustomobject]@{ Ok = $false; Error = $jobs.Error; Found = $false; Id = ''; Status = ''; CreatedUtc = $null }
    }
    $last = $null
    foreach ($job in @(Get-DemoActivityControlList -InputObject $jobs.Value -Name 'value')) {
        $properties = Get-DemoMemberValue -InputObject $job -Name 'properties'
        $status = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
        $runbook = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'runbook') -Name 'name')
        if ($runbook -ne $Name.StopRunbook -or $status -notin $script:T4StopJobEndedStatuses) {
            continue
        }
        $created = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $properties -Name 'creationTime')
        if ($null -eq $last -or ($null -ne $created -and ($null -eq $last.CreatedUtc -or $created -gt $last.CreatedUtc))) {
            $last = [pscustomobject]@{ Ok = $true; Error = ''; Found = $true; Id = [string](Get-DemoMemberValue -InputObject $properties -Name 'jobId'); Status = $status; CreatedUtc = $created }
        }
    }
    if ($null -eq $last) {
        return [pscustomobject]@{ Ok = $true; Error = ''; Found = $false; Id = ''; Status = ''; CreatedUtc = $null }
    }
    return $last
}

function Get-DemoT4RestartCoverage {
    <#
    .SYNOPSIS
    Whether a safety stop caps T4's 7-day automatic restart in the cost estimate's worst case (the owner's decision,
    2026-11-04, ADR 0016): the nightly safety stop, part of every deployment since 2026-11-05 (ADR 0024), or else the
    on-demand control's daily T4 safety stop (ADR 0020). Returns Counts, Missing (SafetyStop, Role, or StopJob for the
    nightly safety stop; '' when it counts), Reason, Fix, and Evidence. Never throws. Internal.

    .DESCRIPTION
    Azure starts a stopped flexible server again on its own after 7 days, and it then runs until something stops it. Each
    restart counts as about a day, until the next safety stop, only when one of them is fully in place:
    - the nightly safety stop (Get-DemoSafetyStopState): dbhub-safety-stop is enabled and linked to DbHub-Stop -Scope
      Nightly, its identity holds "DbHub Demo Safety Stop" at the demo resource group (destroy deletes that assignment with
      the group; deploy.ps1 makes it again when the person who runs it may), and its last stop run didn't fail; or
    - the control's own (Get-DemoT4ControlRestartCoverage): its schedule, A1, and a last DbHub-Stop job that didn't fail.
    Anything else, a read that fails included (fail safe), means the worst case counts the rest of the month, and Missing,
    Reason, and Fix say what's missing from the nightly safety stop and the exact command that fixes it.
    - Schedules: https://learn.microsoft.com/rest/api/automation/schedule/get
    - Role assignments: https://learn.microsoft.com/rest/api/authorization/role-assignments/list-for-scope
    - Jobs: https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = ''
    )

    $grant = Get-DemoSafetyStopCommand -ConfigPath $ConfigPath
    $missing = {
        param([string] $Piece, [string] $Reason, [string] $Fix, [System.Collections.IDictionary] $Evidence)
        $Evidence['counts'] = $false
        $Evidence['missing'] = $Piece
        [pscustomobject]@{ Counts = $false; Missing = $Piece; Reason = $Reason; Fix = $Fix; Evidence = $Evidence }
    }
    $evidence = [ordered]@{}
    try {
        $nightly = Get-DemoSafetyStopState -Config $Config
        $evidence['nightly'] = $nightly.State
        $gap = $null
        if ($nightly.State -eq 'InPlace') {
            $runs = Get-DemoSafetyStopLastRun -Name (Get-DemoSafetyStopName -Config $Config)
            if (-not $runs.Ok) {
                $evidence['nightlyLastRun'] = 'unread'
                $gap = @('StopJob', ('the nightly safety stop''s last run couldn''t be read ({0}), so it''s taken as failed' -f $runs.Error), 'Run ./scripts/status.ps1 to see it (STATUS.SAFETYSTOP), then run this again.')
            }
            else {
                $stopStatus = if ($null -ne $runs.Stop) { [string](Get-DemoMemberValue -InputObject $runs.Stop.Result -Name 'status') } else { '' }
                $evidence['nightlyLastRun'] = if ($null -eq $runs.Stop) { 'none' } else { '{0} ({1})' -f $runs.Stop.Status, $(if ($stopStatus) { $stopStatus } else { 'no result line' }) }
                if ($null -ne $runs.Stop -and ($runs.Stop.Status -ne 'Completed' -or $stopStatus -ne 'Stopped')) {
                    $when = if ($null -ne $runs.Stop.CreatedUtc) { ' (created {0:yyyy-MM-dd HH:mm} UTC)' -f ([datetime]$runs.Stop.CreatedUtc) } else { '' }
                    $gap = @('StopJob', ('the nightly safety stop''s last run{0} didn''t finish its work (job {1}), so it may not stop T4' -f $when, $runs.Stop.Status), 'Run ./scripts/status.ps1 to see what it said (STATUS.SAFETYSTOP), fix that, then run this again.')
                }
                else {
                    $evidence['counts'] = $true
                    $evidence['missing'] = ''
                    $ran = if ($null -eq $runs.Stop) { 'it hasn''t run yet' } else { 'its last run didn''t fail' }
                    return [pscustomobject]@{ Counts = $true; Missing = ''; Reason = ('the nightly safety stop is scheduled, its role is assigned, and {0}' -f $ran); Fix = ''; Evidence = $evidence }
                }
            }
        }
        elseif ($nightly.State -eq 'NoRole') {
            $gap = @('Role', ('the nightly safety stop can''t stop T4: its role isn''t assigned ({0})' -f $nightly.Missing), ('An Owner of the subscription runs {0} once; deploy.ps1 assigns it when the person who runs it may.' -f $grant))
        }
        elseif ($nightly.State -eq 'Unknown') {
            $gap = @('SafetyStop', ('whether the nightly safety stop is in place couldn''t be read ({0}), so it''s taken as missing' -f $nightly.Error), 'Run ./scripts/status.ps1 to see it (STATUS.SAFETYSTOP), then run this again.')
        }
        else {
            $gap = @('SafetyStop', ('the nightly safety stop isn''t in place yet ({0})' -f $nightly.Missing), ('./scripts/deploy.ps1 sets it up after its template, so the checks after that run count about a day per restart (a first deployment''s own preflight can''t: it runs before the template); when deploy.ps1 can''t assign its role, an Owner runs {0} once.' -f $grant))
        }
        # The on-demand control's own daily T4 safety stop still covers T4 when it's fully in place (ADR 0020).
        if ((Get-DemoActivityControlSetting -Config $Config).Enabled) {
            $control = Get-DemoT4ControlRestartCoverage -Config $Config -ConfigPath $ConfigPath
            $evidence['control'] = $control.Evidence
            if ($control.Counts) {
                $evidence['counts'] = $true
                $evidence['missing'] = ''
                return [pscustomobject]@{ Counts = $true; Missing = ''; Reason = $control.Reason; Fix = ''; Evidence = $evidence }
            }
        }
        return (& $missing $gap[0] $gap[1] $gap[2] $evidence)
    }
    catch {
        $problem = Protect-DemoText -Text $_.Exception.Message
        Write-DemoLog -Level Warning -Message ('Whether a safety stop is in place couldn''t be read, so the cost estimate counts T4''s restart for the rest of the month: {0}' -f $problem)
        $evidence['error'] = $problem
        return (& $missing 'SafetyStop' ('the nightly safety stop couldn''t be checked ({0}), so it''s taken as missing' -f $problem) 'Run ./scripts/status.ps1 to see it (STATUS.SAFETYSTOP), then run this again.' $evidence)
    }
}

function Get-DemoT4ControlRestartCoverage {
    <#
    .SYNOPSIS
    Whether the on-demand control's daily T4 safety stop (ADR 0020) caps T4's 7-day automatic restart: the second check of
    Get-DemoT4RestartCoverage, after the nightly safety stop. Returns Counts, Missing (Control, Schedule, A1, StopJob, or
    ''), Reason, Fix, and Evidence. Never throws. Internal.

    .DESCRIPTION
    It counts only when all three hold:
    - the schedule dbhub-t4-safety-stop exists, is enabled, and is linked to DbHub-Stop (Get-DemoT4SafetyStopState);
    - A1, the control identity's custom role on the demo's resource group, is assigned: DbHub-Stop can't stop T4 without
      it, and destroy deletes it with the group, so only assignRoles or -GrantRole grants it again;
    - the last DbHub-Stop job that ended didn't fail (Failed, Stopped, or Suspended).
    Anything else, a read that fails included (fail safe), doesn't count, and Missing, Reason, and Fix say what's missing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = ''
    )

    $grant = Get-DemoActivityControlCommand -ConfigPath $ConfigPath
    $setup = $grant -replace ' -GrantRole$', ''
    $missing = {
        param([string] $Piece, [string] $Reason, [string] $Fix, [System.Collections.IDictionary] $Evidence)
        $Evidence['counts'] = $false
        $Evidence['missing'] = $Piece
        [pscustomobject]@{ Counts = $false; Missing = $Piece; Reason = $Reason; Fix = $Fix; Evidence = $Evidence }
    }
    $evidence = [ordered]@{}
    try {
        if (-not (Get-DemoActivityControlSetting -Config $Config).Enabled) {
            $evidence['control'] = 'off'
            return (& $missing 'Control' 'the on-demand activity control isn''t set up (control.enabled is false), so nothing here stops T4 after Azure starts it again' ('Set control.enabled to true and run {0}; an Owner then runs {1} once (ADR 0020).' -f $setup, $grant) $evidence)
        }
        $state = [string](Get-DemoT4SafetyStopState -Config $Config).State
        $evidence['schedule'] = $state
        if ($state -ne 'Scheduled') {
            $what = if ($state -eq 'Unknown') { 'couldn''t be read, so it''s taken as missing' } else { 'isn''t in place (the schedule dbhub-t4-safety-stop is missing, disabled, or not linked to DbHub-Stop)' }
            return (& $missing 'Schedule' ('the daily T4 safety stop {0}' -f $what) ('Run {0}, which schedules it again.' -f $setup) $evidence)
        }
        $name = Get-DemoActivityControlName -Config $Config
        $roleId = Get-DemoActivityControlRoleId -SubscriptionId $name.SubscriptionId
        $principalId = if ($roleId) { Get-DemoActivityControlPrincipalId -Name $name } else { '' }
        $a1 = if ($roleId -and $principalId) { Test-DemoActivityControlAssignment -SubscriptionId $name.SubscriptionId -Scope $name.DemoResourceGroupId -PrincipalId $principalId -RoleId $roleId } else { $null }
        $evidence['a1'] = if ($null -ne $a1 -and $a1.Exists) { 'assigned' } elseif ($null -ne $a1 -and $a1.Error -and -not $a1.Missing) { 'unread' } else { 'missing' }
        if ($evidence['a1'] -ne 'assigned') {
            $what = if ($evidence['a1'] -eq 'unread') { 'couldn''t be read, so it''s taken as missing' } else { 'isn''t assigned' }
            $reason = 'A1, {0}''s "{1}" role on {2}, {3}: without it DbHub-Stop can''t stop T4, and destroy deletes it with the group' -f $name.Identity, $name.RoleName, $name.DemoResourceGroup, $what
            return (& $missing 'A1' $reason ('An Owner runs {0}, or set assignRoles to true and run ./scripts/deploy.ps1, which grants A1 again after the template.' -f $grant) $evidence)
        }
        $job = Get-DemoT4LastStopJob -Name $name
        if (-not $job.Ok) {
            $evidence['lastStopJob'] = 'unread'
            return (& $missing 'StopJob' ('the last DbHub-Stop job couldn''t be read ({0}), so it''s taken as failed' -f $job.Error) ('Open {0} > Jobs in the Azure portal to check DbHub-Stop''s last run, then run {1}.' -f $name.AutomationAccount, $setup) $evidence)
        }
        $evidence['lastStopJob'] = if ($job.Found) { $job.Status } else { 'none' }
        if ($job.Found -and $job.Status -ne 'Completed') {
            $when = if ($null -ne $job.CreatedUtc) { ' (created {0:yyyy-MM-dd HH:mm} UTC)' -f ([datetime]$job.CreatedUtc) } else { '' }
            $reason = 'the last DbHub-Stop job{0} ended {1}, so the safety stop may not stop T4' -f $when, $job.Status
            return (& $missing 'StopJob' $reason ('Open the job in {0} (Process Automation > Jobs) to see why; when A1 is the cause, an Owner runs {1}. Then run {2}.' -f $name.AutomationAccount, $grant, $setup) $evidence)
        }
        $evidence['counts'] = $true
        $evidence['missing'] = ''
        return [pscustomobject]@{ Counts = $true; Missing = ''; Reason = 'the on-demand control''s daily T4 safety stop is scheduled, A1 is assigned, and the last DbHub-Stop job didn''t fail'; Fix = ''; Evidence = $evidence }
    }
    catch {
        $problem = Protect-DemoText -Text $_.Exception.Message
        Write-DemoLog -Level Warning -Message ('Whether the daily T4 safety stop is in place couldn''t be read, so the cost estimate counts T4''s restart for the rest of the month: {0}' -f $problem)
        $evidence['error'] = $problem
        return (& $missing 'Schedule' ('the daily T4 safety stop couldn''t be checked ({0}), so it''s taken as missing' -f $problem) ('Run {0}, then run this again.' -f $setup) $evidence)
    }
}

function Get-DemoT4RestartWorstCase {
    <#
    The hours of T4 compute the estimate's worst case adds for its 7-day automatic restart (2026-11-04, ADR 0016). Without
    a safety stop (-Capped false), the rest of the month after the light-use hours. With one, each restart runs until the
    next nightly safety stop, at most about 24 hours, and a restart comes at most every 8 days (7 stopped, then up to 1 running): at
    most floor(HoursPerMonth / 192) + 1 restarts a month, 4 for a 730-hour month, so 96 hours, never more than the rest
    of the month. Returns Hours and Restarts (0 without the cap). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [double] $HoursPerMonth,

        [Parameter(Mandatory)]
        [double] $LightUseHoursPerMonth,

        [Parameter(Mandatory)]
        [bool] $Capped,

        [ValidateRange(1, 30)]
        [int] $StoppedDays = 7
    )

    $rest = [System.Math]::Max(0.0, $HoursPerMonth - $LightUseHoursPerMonth)
    if (-not $Capped) {
        return [pscustomobject]@{ Hours = $rest; Restarts = 0 }
    }
    $restarts = [int][System.Math]::Floor($HoursPerMonth / (($StoppedDays + 1) * 24.0)) + 1
    return [pscustomobject]@{ Hours = [System.Math]::Min($rest, $restarts * 24.0); Restarts = $restarts }
}

function New-DemoT4RestartCoverageResult {
    <#
    <Prefix>.COST.T4RESTART (2026-11-04, ADR 0016): which worst case the monthly ceiling counts for T4's 7-day automatic
    restart, and why. Pass when a safety stop caps it (about a day per restart); a Warning that names what's
    missing, and the exact fix, when it counts the rest of the month; Not selected when T4 is off. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Coverage,

        [ValidateSet('PREFLIGHT', 'START')]
        [string] $CheckPrefix = 'PREFLIGHT'
    )

    $checkId = '{0}.COST.T4RESTART' -f $CheckPrefix
    $doc = [string](Get-DemoPostgresSetting)['docUrls']['stopServer']
    if (-not (Test-DemoT4Enabled -Config $Config)) {
        return (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'T4' -Status 'Not selected' -Message 'T4 is off in this configuration (t4Enabled is false), so its automatic restart costs nothing.' -DocUrl $doc)
    }
    if ($null -ne $Coverage -and $Coverage.Counts) {
        return (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'T4' -Status 'Pass' -Message ('Azure starts a stopped T4 again on its own after 7 days, and {0}, so the monthly ceiling counts each restart as about a day, until the next safety stop.' -f $Coverage.Reason) -Evidence $Coverage.Evidence -DocUrl $doc)
    }
    $reason = if ($null -ne $Coverage) { $Coverage.Reason } else { 'whether the nightly safety stop is in place wasn''t checked' }
    $fix = if ($null -ne $Coverage -and $Coverage.Fix) { $Coverage.Fix } else { 'Run ./scripts/deploy.ps1, which sets up the nightly safety stop (ADR 0024).' }
    $evidence = if ($null -ne $Coverage) { $Coverage.Evidence } else { [ordered]@{ counts = $false; missing = 'NotChecked' } }
    return (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'T4' -Status 'Warning' -Message ('Azure starts a stopped T4 again on its own after 7 days, and {0}, so the monthly ceiling counts it running for the rest of the month.' -f $reason) -Evidence $evidence -Remediation ('{0} With it in place, each restart counts as about a day.' -f $fix) -DocUrl $doc)
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

    .DESCRIPTION
    Exists means T4 is deployed: the server is there and Azure isn't deleting it. A server in Dropping ("Server is being
    deleted", ServerState in Servers - Get) isn't T4 any more, whatever deleted it: Removing is $true, Exists $false, and
    Present $true (the resource is still there, so a new server with its name has to wait). Azure keeps a server it
    refused with SkuNotAvailable as such a shell for a few minutes (live, 2026-11-09: Dropping for about 3 minutes after
    the refusal), which a run must neither count as T4 nor try to create again before it's gone.
    Source: https://learn.microsoft.com/rest/api/postgresql/servers/get (ServerState)
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
        return [pscustomobject]@{ Names = $names; Exists = $false; Present = $false; Removing = $false; State = 'NotFound'; Server = $null; Error = 'The resource group has no deploymentId tag.' }
    }
    $read = Get-DemoT4Resource -Config $Config -ServerId $names.ServerId
    if ($read.Found) {
        $state = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $read.Value -Name 'properties') -Name 'state')
        $removing = $state -eq 'Dropping'
        return [pscustomobject]@{ Names = $names; Exists = (-not $removing); Present = $true; Removing = $removing; State = $(if ($state) { $state } else { 'Unknown' }); Server = $read.Value; Error = '' }
    }
    return [pscustomobject]@{ Names = $names; Exists = $false; Present = $false; Removing = $false; State = $(if ($read.NotFound) { 'NotFound' } else { 'Unknown' }); Server = $null; Error = $read.Error }
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
    API), and whether the nightly safety stop (ADR 0024), or else the on-demand control's daily one, stops it again
    (Format-DemoT4RestartText). A missing
    server, one Azure is deleting (Dropping, 2026-11-09), or T4 turned off (t4Enabled false), is Not selected.
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
        # A server Azure is deleting (Dropping, 2026-11-09) isn't deployed, like one that doesn't exist.
        $gone = $current.State -eq 'NotFound' -or [bool](Get-DemoMemberValue -InputObject $current -Name 'Removing')
        $status = if ($gone) { 'Not selected' } else { 'Warning' }
        $message = if ($current.State -eq 'NotFound') { 'T4 isn''t deployed, so there''s nothing to {0}.' -f $Action.ToLowerInvariant() } elseif ($gone) { 'T4''s server is being deleted (Dropping), so it isn''t deployed and there''s nothing to {0}.' -f $Action.ToLowerInvariant() } else { 'T4''s state couldn''t be read: {0}' -f $current.Error }
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
        # Whether anything stops it again: the nightly safety stop (ADR 0024), or else the on-demand control's daily one, by
        # their schedules and roles, not only by the configuration (review of 20e855c).
        $safety = Get-DemoT4RestartStopState -Config $Config
        $evidence['dailySafetyStop'] = $safety.State -in 'Nightly', 'Scheduled'
        $evidence['safetyStop'] = $safety.State
        $autoStart = ' ' + (Format-DemoT4RestartText -RestartUtc $restartUtc -SkuName $serverSku -HourlyUsd $hourly -Days $days -SafetyStop $safety.State -Config $Config -CheckStopsT4:([bool](Get-DemoMemberValue -InputObject $safety -Name 'CheckStopsT4')))
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

function Get-DemoT4ParameterState {
    <#
    .SYNOPSIS
    One of T4's server parameters (Configurations - Get): Found, Value, PendingRestart, Source, and Error. Internal.

    .DESCRIPTION
    PendingRestart is isConfigPendingRestart: a static parameter's new value waits for a server restart before it takes
    effect. A read: it works while the server is stopped.
    Source (checked 2026-11-03): https://learn.microsoft.com/rest/api/postgresql/configurations/get
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ServerId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._]+$')]
        [string] $Name
    )

    $read = Get-DemoT4Resource -Config $Config -ServerId $ServerId -Child ('configurations/{0}' -f $Name)
    $properties = Get-DemoMemberValue -InputObject $read.Value -Name 'properties'
    return [pscustomobject]@{
        Found          = [bool]$read.Found
        Value          = [string](Get-DemoMemberValue -InputObject $properties -Name 'value')
        PendingRestart = ([string](Get-DemoMemberValue -InputObject $properties -Name 'isConfigPendingRestart') -eq 'True')
        Source         = [string](Get-DemoMemberValue -InputObject $properties -Name 'source')
        Error          = [string]$read.Error
    }
}

function Invoke-DemoT4PendingRestart {
    <#
    .SYNOPSIS
    Restarts T4 when max_connections, which the template sets, waits for a restart, so the new limit is in effect before T1
    sets T4 up and the runner connects (ADR 0019, 2026-11-03). Returns DEPLOY.T4.RESTART, or nothing when nothing waits.
    Internal.

    .DESCRIPTION
    max_connections is a static parameter: after the template changes it, isConfigPendingRestart is true until the server
    restarts. Then, when T4 is Ready, this sends Servers - Restart, which restarts the PostgreSQL engine, not the compute,
    and waits up to -WaitMinutes until T4 is Ready with nothing pending. The restart ends T4's open sessions; the runner's
    connections retry, and Enable-DemoT4Workload, which follows, restarts the activity host anyway. A deployment that
    changed nothing never restarts T4. A T4 that isn't Ready isn't restarted (Warning): the value takes effect at its next
    restart.
    Sources (checked 2026-11-03):
    - https://learn.microsoft.com/rest/api/postgresql/configurations/get
    - https://learn.microsoft.com/rest/api/postgresql/servers/restart
    - https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-restart-server
    - https://learn.microsoft.com/azure/postgresql/server-parameters/param-connections-authentication-connection-settings
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'deploy.ps1 confirms once for the whole deployment.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $DeploymentId = '',

        [ValidateRange(1, 30)]
        [int] $WaitMinutes = 10,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15
    )

    $checkId = 'DEPLOY.T4.RESTART'
    $postgres = Get-DemoPostgresSetting
    $docUrl = [string]$postgres['docUrls']['restartServer']
    $names = Get-DemoT4Name -Config $Config -DeploymentId $DeploymentId
    if (-not $names.Enabled -or -not $names.ServerId) {
        return
    }
    $current = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
    if (-not $current.Exists) {
        return
    }
    $setting = Get-DemoT4ParameterState -Config $Config -ServerId $names.ServerId -Name 'max_connections'
    if (-not $setting.Found -or -not $setting.PendingRestart) {
        # Nothing waits, or the read failed: T4.MAXCONNECTIONS (Test-DemoT4) reports the value either way.
        return
    }
    $evidence = [ordered]@{ server = $names.ServerName; parameter = 'max_connections'; value = $setting.Value; stateBefore = $current.State }
    if ($current.State -ne 'Ready') {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('max_connections {0} waits for a restart, but T4 ({1}) is {2}, so it wasn''t restarted; the value takes effect at its next restart.' -f $setting.Value, $names.ServerName, $current.State) -Evidence $evidence -Remediation 'Once T4 is Ready, run ./scripts/deploy.ps1 -FromStage T4, or restart it yourself (az postgres flexible-server restart).' -DocUrl $docUrl)
    }

    Write-DemoLog -Message ('T4 ({0}) restarts so max_connections {1}, a static parameter the template set, takes effect.' -f $names.ServerName, $setting.Value)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $url = 'https://management.azure.com{0}/restart?api-version={1}' -f $names.ServerId, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers')
    $post = Invoke-DemoAzWithConflictRetry -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'post', '--url', $url) -Label ('T4 {0}: restart' -f $names.ServerName) -MaxConflictRetries 4
    if ($post.ExitCode -ne 0) {
        $evidence['error'] = Protect-DemoText -Text ([string]$post.StdErr).Trim()
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4 ({0}) couldn''t be restarted, so max_connections {1} waits for its next restart: {2}' -f $names.ServerName, $setting.Value, $evidence['error']) -Evidence $evidence -Remediation 'Run ./scripts/deploy.ps1 -FromStage T4 again in a few minutes, or restart T4 yourself (az postgres flexible-server restart).' -DocUrl $docUrl)
    }
    # Servers - Restart answers 202 before the state changes, so the wait is for the value in effect, not just Ready.
    $deadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    do {
        Start-Sleep -Seconds $PollSeconds
        $current = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
        $done = $false
        if ($current.State -eq 'Ready') {
            $setting = Get-DemoT4ParameterState -Config $Config -ServerId $names.ServerId -Name 'max_connections'
            $done = $setting.Found -and -not $setting.PendingRestart
        }
    } until ($done -or [DateTime]::UtcNow -ge $deadline)
    $evidence['stateAfter'] = $current.State
    $evidence['seconds'] = [int]$clock.Elapsed.TotalSeconds
    if ($done) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4 ({0}) restarted in {1} s, so max_connections {2} is in effect (only the PostgreSQL engine restarted, not its compute).' -f $names.ServerName, $evidence['seconds'], $setting.Value) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4 ({0}) was asked to restart, but after {1} minute(s) it''s {2} and max_connections still waits for the restart.' -f $names.ServerName, $WaitMinutes, $current.State) -Evidence $evidence -Remediation 'Check it in a few minutes with ./scripts/validate.ps1 -Area T4 (T4.MAXCONNECTIONS); if it still waits, run ./scripts/deploy.ps1 -FromStage T4.' -DocUrl $docUrl)
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
    if ($State -eq 'Dropping') {
        # A server Azure is deleting isn't T4 any more (2026-11-09), so start-demo.ps1 can't bring its metrics back.
        return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Warning' -Message 'T4''s server is being deleted (Dropping), so it isn''t deployed and sends no metrics.' -Evidence ([ordered]@{ state = $State }) -Remediation 'Run ./scripts/deploy.ps1 once Azure has removed it: it creates T4 again.' -DocUrl $docUrl)
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
