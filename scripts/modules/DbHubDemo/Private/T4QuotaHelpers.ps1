# Azure Database for PostgreSQL flexible server's vCore quota, for T4 and its read replica (F37, 2026-11-22).
# - A refusal at creation: Learn documents Azure's message, "Operation could not be completed as it results in exceeding
#   approved {0} Cores quota. Additional details - Current Limit: {1}, Current Usage: {2}, Additional Required: {3},
#   (Minimum) New Limit Required: {4}." T4's size fallback and its read replica's move on from that refusal as from
#   SkuNotAvailable (ADR 0019 and ADR 0025, amended 2026-11-22), without the retry in another zone: a quota is the
#   subscription's in the region, not a zone's.
# - The readings: Quota Usages - List gives the region's vCores (cores) and each series' (standardDDSv5Family, ...), stopped
#   servers included. Azure didn't enforce them as reported: on 2026-11-21 it created two T4 servers and two read replicas
#   in West US 3, all Standard_D4ds_v5, which brought the region's PostgreSQL vCores to 32 at most, while a day later cores
#   read a limit of 24 and standardDDSv5Family one of 4. So preflight logs them for diagnosis only, and never judges them.
# Sources (checked 2026-11-22):
# - Exceeded quota: https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors#exceeded-quota
# - Request a quota increase: https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-request-quota-increase
# - Quota Usages - List: https://learn.microsoft.com/rest/api/postgresql/quota-usages/list (also in API version 2025-08-01,
#   the provider's pinned one)

# Learn's message, as Azure's error text carries it: the quota's name is what Azure puts before "Cores quota".
$script:T4QuotaRefusalPattern = '(?is)exceeding\s+approved\s+(?<quota>[^"\\\r\n]{0,80}?)\s*Cores\s+quota'

# The series entry of each documented T4 size in Quota Usages - List: Learn's examples name standardBSFamily and
# standardDDSv4Family (the REST reference) and standardDDSv5Family (Get-AzPostgreSqlFlexibleServerQuotaUsage); West US 3
# listed standardDADSv5Family on 2026-11-22.
$script:T4QuotaFamily = @{
    Standard_D4ds_v5  = 'standardDDSv5Family'
    Standard_D2ds_v5  = 'standardDDSv5Family'
    Standard_D4ads_v5 = 'standardDADSv5Family'
    Standard_B1ms     = 'standardBSFamily'
    Standard_B2s      = 'standardBSFamily'
}

function Get-DemoT4QuotaRefusal {
    <#
    .SYNOPSIS
    Azure's refusal of a T4 or read replica size for the subscription's vCore quota, read from an error's text (F37,
    2026-11-22): $null when the text doesn't carry Learn's message, else Quota (the quota's name Azure gives, such as
    "Total Regional", or ''), and Limit, Usage, and Required (integers, or $null where the text doesn't give them). Pure.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text = ''
    )

    $value = [string]$Text
    $match = [regex]::Match($value, $script:T4QuotaRefusalPattern)
    if (-not $match.Success) {
        return $null
    }
    $tail = $value.Substring($match.Index, [System.Math]::Min(400, $value.Length - $match.Index))
    $number = {
        param([string] $Label)
        $found = [regex]::Match($tail, ('(?i){0}\s*:\s*(\d+)' -f [regex]::Escape($Label)))
        if ($found.Success) { [int]$found.Groups[1].Value } else { $null }
    }
    return [pscustomobject]@{
        Quota    = ($match.Groups['quota'].Value -replace '\s+', ' ').Trim()
        Limit    = & $number 'Current Limit'
        Usage    = & $number 'Current Usage'
        Required = & $number 'Additional Required'
    }
}

function Format-DemoT4RefusalReason {
    <#
    .SYNOPSIS
    How Azure's refusal of a T4 or read replica size reads in a message (F37, 2026-11-22): SkuNotAvailable, as since ADR
    0019, or, for a refusal over the subscription's vCore quota (-Failure's Quota, from Get-DemoT4QuotaRefusal; -Quota for
    one a record names without its figures), "over the subscription's vCore quota for Azure Database for PostgreSQL here",
    with Azure's figures when it gave them. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Failure,

        [switch] $Quota
    )

    $refusal = Get-DemoMemberValue -InputObject $Failure -Name 'Quota'
    if ($null -eq $refusal -and -not $Quota) {
        return 'SkuNotAvailable'
    }
    $text = 'over the subscription''s vCore quota for Azure Database for PostgreSQL here'
    if ($null -eq $refusal) {
        return $text
    }
    $name = [string](Get-DemoMemberValue -InputObject $refusal -Name 'Quota')
    $limit = Get-DemoMemberValue -InputObject $refusal -Name 'Limit'
    $usage = Get-DemoMemberValue -InputObject $refusal -Name 'Usage'
    $required = Get-DemoMemberValue -InputObject $refusal -Name 'Required'
    # No parentheses: messages put the reason in theirs.
    $figures = if ($null -ne $limit -and $null -ne $usage -and $null -ne $required) { '{0} of {1} in use, {2} more needed' -f $usage, $limit, $required } else { '' }
    if ($name -and $figures) {
        return ('{0}, its {1} Cores quota: {2}' -f $text, $name, $figures)
    }
    if ($name) {
        return ('{0}, its {1} Cores quota' -f $text, $name)
    }
    if ($figures) {
        return ('{0}: {1}' -f $text, $figures)
    }
    return $text
}

function Get-DemoT4QuotaRemediation {
    <#
    .SYNOPSIS
    The ways out when Azure refused every size T4 or its read replica can have, over the subscription's vCore quota for
    Azure Database for PostgreSQL in -Location (F37, 2026-11-22): free vCores there or request more quota, then -Command
    again; or move the demo to another region. -AlsoUnavailable adds the Region access request, for sizes Azure refused
    as unavailable (SkuNotAvailable) in the same run. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Location = '',

        [string] $Command = './scripts/deploy.ps1',

        [switch] $AlsoUnavailable
    )

    $where = if ($Location) { $Location } else { 'this region' }
    $access = if ($AlsoUnavailable) { ' For the sizes Azure refused as unavailable (SkuNotAvailable), ask for access with a Region access request (Learn: Resolve capacity errors).' } else { '' }
    return ('Free vCores in {0}: ./scripts/destroy.ps1 -ConfigPath <its configuration> deletes a demo environment you no longer use, with its T4 and read replica (a stopped server still counts against the quota). Or request more quota for Azure Database for PostgreSQL flexible server in {0} (Learn: Request a quota increase).{2} Then run {1} again. Or move the demo to another region: ./scripts/destroy.ps1, ./scripts/init.ps1 -Force -Location <region>, then ./scripts/deploy.ps1.' -f $where, $Command, $access)
}

function Read-DemoPostgresQuotaUsage {
    <#
    .SYNOPSIS
    The subscription's quota usages for Azure Database for PostgreSQL flexible server in the configured region (Quota
    Usages - List, with the provider's pinned API version; F37, 2026-11-22): Ok, Entries (by name, each with Current and
    Limit, in Azure's order), and Error. For diagnosis only: Azure didn't enforce these readings as reported (the comment
    above). Never throws. A read. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $entries = [ordered]@{}
    try {
        $url = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.DBforPostgreSQL/locations/{1}/resourceType/flexibleServers/usages?api-version={2}' -f [string]$Config['subscriptionId'], [string]$Config['location'], (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers')
        $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'get', '--url', $url, '--output', 'json') -AllowFailure
        if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
            return [pscustomobject]@{ Ok = $false; Entries = $entries; Error = (Protect-DemoText -Text ([string]$read.StdErr).Trim()) }
        }
        $answer = [string]$read.StdOut | ConvertFrom-Json -Depth 16
        $items = Get-DemoMemberList -InputObject $answer -Name 'value'
        foreach ($item in $items) {
            $name = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'name') -Name 'value')
            if (-not $name -or $entries.Contains($name)) {
                continue
            }
            $entries[$name] = [pscustomobject]@{ Name = $name; Current = [int64](Get-DemoMemberValue -InputObject $item -Name 'currentValue'); Limit = [int64](Get-DemoMemberValue -InputObject $item -Name 'limit') }
        }
        return [pscustomobject]@{ Ok = $true; Entries = $entries; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Entries = $entries; Error = (Protect-DemoText -Text $_.Exception.Message) }
    }
}

function Format-DemoPostgresQuotaUsageText {
    <#
    .SYNOPSIS
    Preflight's line about Azure Database for PostgreSQL's vCore quota usage in the region, for diagnosis only (F37,
    2026-11-22): the region's vCores (cores) and -SkuName's series, against T4's vCores at that size and, for a General
    Purpose size, its read replica's. Returns Text and Evidence (the readings as "name current/limit"). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Usage,

        [Parameter(Mandatory)]
        [string] $SkuName,

        [AllowEmptyString()]
        [string] $Location = ''
    )

    $spec = Get-DemoT4SkuSpec -SkuName $SkuName
    $family = if ($script:T4QuotaFamily.ContainsKey($SkuName)) { [string]$script:T4QuotaFamily[$SkuName] } else { '' }
    $replica = $spec.Tier -eq 'GeneralPurpose'
    $vcores = '{0} vCore{1}' -f $spec.VCores, $(if ($spec.VCores -eq 1) { '' } else { 's' })
    $needs = if ($replica) { 'T4 at {0} takes {1}, and its read replica {1} more while it exists' -f $SkuName, $vcores } else { 'T4 at {0} takes {1} (a Burstable size has no read replica)' -f $SkuName, $vcores }
    $evidence = [ordered]@{ skuName = $SkuName; vCores = $spec.VCores; replica = $replica; family = $family; readings = @() }
    if (-not $Usage.Ok) {
        # az's error can run to several lines: its first, at most 200 characters, is enough for diagnosis.
        $why = @(([string]$Usage.Error) -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -First 1) -join ''
        $why = $why.Trim().TrimEnd('.')
        if ($why.Length -gt 200) {
            $why = $why.Substring(0, 200) + '...'
        }
        if (-not $why) {
            $why = 'no answer'
        }
        $evidence['error'] = $why
        return [pscustomobject]@{ Text = ('For diagnosis only: Azure Database for PostgreSQL flexible server''s vCore usage in {0} couldn''t be read ({1}); {2}.' -f $Location, $why, $needs); Evidence = $evidence }
    }
    $readings = @(foreach ($name in @('cores', $family) | Where-Object { $_ }) {
            if ($Usage.Entries.Contains($name)) {
                '{0} {1} of {2}' -f $name, $Usage.Entries[$name].Current, $Usage.Entries[$name].Limit
            }
            else {
                '{0} not listed' -f $name
            }
        })
    $evidence['readings'] = $readings
    return [pscustomobject]@{ Text = ('For diagnosis only: Azure Database for PostgreSQL flexible server''s vCore usage in {0} reads {1}; {2}. Azure has created servers past such readings, so preflight doesn''t judge them: a refusal at creation moves the size fallback on, and says so.' -f $Location, ($readings -join ', '), $needs); Evidence = $evidence }
}
