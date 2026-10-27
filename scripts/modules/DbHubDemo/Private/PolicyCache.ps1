function Get-DemoCanonicalText {
    <#
    .SYNOPSIS
    Returns a stable text form of a value for hashing: dictionary keys and object properties in ordinal order.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return 'null'
    }
    if ($Value -is [string]) {
        return (ConvertTo-Json -InputObject $Value -Compress)
    }
    if ($Value -is [bool]) {
        return $(if ($Value) { 'true' } else { 'false' })
    }
    if ($Value -is [datetime]) {
        return ('"{0}"' -f $Value.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [System.ValueType]) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
        [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $parts = foreach ($key in $keys) {
            '{0}:{1}' -f (ConvertTo-Json -InputObject $key -Compress), (Get-DemoCanonicalText -Value $Value[$key])
        }
        return ('{' + (@($parts) -join ',') + '}')
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) {
            Get-DemoCanonicalText -Value $item
        }
        return ('[' + (@($parts) -join ',') + ']')
    }
    $table = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $table[$property.Name] = $property.Value
    }
    return (Get-DemoCanonicalText -Value $table)
}

function Get-DemoSha256Text {
    <#
    .SYNOPSIS
    Returns the lowercase hexadecimal SHA-256 of a string (UTF-8).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Get-DemoPolicyInventoryCachePath {
    <#
    .SYNOPSIS
    Returns the policy inventory cache file for a subscription: out/cache under the repository, named by a hash.

    .DESCRIPTION
    The file name holds a hash of the subscription ID, never the ID itself. out/ is Git-ignored.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [string] $Directory = ''
    )

    $folder = if ($Directory) { $Directory } else { Join-Path -Path $script:RepoRoot -ChildPath 'out/cache' }
    $key = (Get-DemoSha256Text -Text $SubscriptionId.ToLowerInvariant()).Substring(0, 16)
    return (Join-Path -Path $folder -ChildPath ('policy-inventory-{0}.clixml' -f $key))
}

function Get-DemoPolicyInventoryFingerprint {
    <#
    .SYNOPSIS
    Hashes everything a policy inventory depends on, except the policy definitions themselves.

    .DESCRIPTION
    The assignments that apply to the subscription (every property, so any change to an assignment, its
    parameters, overrides, selectors, or enforcement mode changes the hash), the configuration values the
    inventory reads (networkMode, profile, t1Priority, hostPriority), the profile catalog, the demo's
    resource types, and the inventory's own code. A definition changed in place, without a change to any
    assignment, isn't detected; the cache's age limit bounds that.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Assignment,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $CodeText
    )

    $assignmentTexts = [string[]]@($Assignment | ForEach-Object { Get-DemoCanonicalText -Value $_ })
    [System.Array]::Sort($assignmentTexts, [System.StringComparer]::Ordinal)
    $inputs = [ordered]@{
        schema        = 1
        code          = Get-DemoSha256Text -Text $CodeText
        networkMode   = [string]$Config['networkMode']
        profile       = [string]$Config['profile']
        t1Priority    = [string]$Config['t1Priority']
        hostPriority  = [string]$Config['hostPriority']
        catalog       = Get-DemoCanonicalText -Value (Get-DemoProfile)
        resourceTypes = @($script:DemoResourceTypes)
        assignments   = $assignmentTexts
    }
    return (Get-DemoSha256Text -Text (Get-DemoCanonicalText -Value $inputs))
}

function Write-DemoPolicyInventoryCache {
    <#
    .SYNOPSIS
    Saves a complete policy inventory with its fingerprint (atomically). A failure is logged, never thrown.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Fingerprint,

        [Parameter(Mandatory)]
        [object] $Inventory
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Save the policy inventory cache')) {
        return
    }
    $temporary = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    try {
        $folder = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
        $entry = [pscustomobject]@{
            Schema      = 1
            Fingerprint = $Fingerprint
            CreatedUtc  = [System.DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            Inventory   = $Inventory
        }
        Export-Clixml -InputObject $entry -LiteralPath $temporary -Depth 12
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Write-DemoLog -Level Warning -Message ('The policy inventory cache wasn''t saved: {0}' -f $_.Exception.Message)
    }
}

function Read-DemoPolicyInventoryCache {
    <#
    .SYNOPSIS
    Returns the cached inventory when its fingerprint matches and it's no older than the limit; otherwise $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Fingerprint,

        [Parameter(Mandatory)]
        [int] $MaximumAgeHours
    )

    if ($MaximumAgeHours -le 0 -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        $entry = Import-Clixml -LiteralPath $Path
        $created = [System.DateTime]::Parse([string]$entry.CreatedUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The policy inventory cache couldn''t be read, so the inventory runs again: {0}' -f $_.Exception.Message)
        return $null
    }
    $ageHours = ([System.DateTime]::UtcNow - $created).TotalHours
    if ([string]$entry.Fingerprint -ne $Fingerprint -or $ageHours -lt 0 -or $ageHours -gt $MaximumAgeHours -or [int]$entry.Schema -ne 1) {
        return $null
    }
    return [pscustomobject]@{ Inventory = $entry.Inventory; CreatedUtc = $created; AgeHours = $ageHours }
}

function Restore-DemoPolicyInventory {
    <#
    .SYNOPSIS
    Rebuilds a cached policy inventory: fresh results that say where they came from, with the same statuses.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Cached,

        [Parameter(Mandatory)]
        [int] $CacheHours
    )

    $inventory = $Cached.Inventory
    $createdText = $Cached.CreatedUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $results = foreach ($item in @($inventory.Results)) {
        $evidence = @{}
        if ($item.evidence -is [System.Collections.IDictionary]) {
            foreach ($key in @($item.evidence.Keys)) {
                $evidence[[string]$key] = $item.evidence[$key]
            }
        }
        $evidence['reusedFromUtc'] = $createdText
        $message = [string]$item.message
        if ([string]$item.checkId -eq 'PREFLIGHT.POLICY.INVENTORY') {
            $message += (' Reused from the inventory of {0} UTC ({1:n1} hours old; -PolicyCacheHours {2}): the policy assignments that apply to the subscription are unchanged.' -f $Cached.CreatedUtc.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture), $Cached.AgeHours, $CacheHours)
        }
        New-DemoResult -CheckId ([string]$item.checkId) -Area ([string]$item.area) -Target ([string]$item.target) -Status ([string]$item.status) -Message $message -Evidence $evidence -Remediation ([string]$item.remediation) -DocUrl ([string]$item.docUrl) -EvaluationOnly:([bool]$item.evaluationOnly)
    }
    $network = [pscustomobject]@{}
    foreach ($property in @($inventory.NetworkMode.PSObject.Properties)) {
        $network | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
    }
    [pscustomobject]@{
        PSTypeName            = 'DbHubDemo.PolicyConstraint'
        Complete              = [bool]$inventory.Complete
        AssignmentCount       = [int]$inventory.AssignmentCount
        DoNotEnforce          = @($inventory.DoNotEnforce)
        Unreadable            = @($inventory.Unreadable)
        Rules                 = @($inventory.Rules)
        SqlPublicAccessPolicy = @($inventory.SqlPublicAccessPolicy)
        NetworkMode           = $network
        Results               = @($results)
        ReusedFromUtc         = $createdText
    }
}
