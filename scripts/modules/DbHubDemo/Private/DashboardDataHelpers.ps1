# Helpers for the Real-Time Dashboard's data check (Phase 18). Internal; Test-DemoRealTimeDashboardData calls them.
# They read the rendered definition and the layout spec, build read-only KQL, and read the targets' state; the
# queries themselves go through Invoke-DemoHubTelemetryQuery.

function Get-DemoDashboardSpecName {
    <#
    .SYNOPSIS
    Maps the dashboard's tile and query element IDs to their keys in fabric/realtime/dashboard.spec.psd1, the
    names the data check uses in its check IDs and evidence. Internal.

    .DESCRIPTION
    Element IDs are the name-based UUIDs of the spec's keys (ConvertTo-DemoStableGuid), so the map is rebuilt
    from the spec, not stored. Returns Tiles (ID to Page and Key) and Queries (ID to Key); both are empty when
    the spec isn't there.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $SpecPath = (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/realtime/dashboard.spec.psd1')
    )

    $tiles = @{}
    $queries = @{}
    if (Test-Path -LiteralPath $SpecPath -PathType Leaf) {
        $spec = Import-PowerShellDataFile -LiteralPath $SpecPath
        foreach ($tile in @($spec['Tiles'])) {
            $id = ([string](ConvertTo-DemoStableGuid -Key ('tile/{0}/{1}' -f $tile['Page'], $tile['Key']))).ToLowerInvariant()
            $tiles[$id] = [pscustomobject]@{ Page = [string]$tile['Page']; Key = [string]$tile['Key'] }
        }
        foreach ($query in @($spec['Queries'])) {
            $id = ([string](ConvertTo-DemoStableGuid -Key ('query/' + $query['Key']))).ToLowerInvariant()
            $queries[$id] = [string]$query['Key']
        }
    }
    [pscustomobject]@{ Tiles = $tiles; Queries = $queries }
}

function Get-DemoDashboardTileColumn {
    <#
    .SYNOPSIS
    The result columns a tile shows: its x, y, series, label, and value columns, and the columns its conditional
    formatting reads. A query that returns rows without one of them leaves the tile broken. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Tile
    )

    $columns = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([object] $Value)
        foreach ($item in @($Value)) {
            if ($item -is [string] -and $item -and -not $columns.Contains($item)) {
                $columns.Add($item)
            }
        }
    }
    $options = $Tile['visualOptions']
    if ($options -is [System.Collections.IDictionary]) {
        foreach ($name in 'xColumn', 'yColumns', 'seriesColumns', 'labelColumn', 'multiStat__valueColumn', 'multiStat__labelColumn') {
            if ($options.Contains($name)) {
                & $add $options[$name]
            }
        }
        if ($options.Contains('colorRules')) {
            foreach ($rule in @($options['colorRules'])) {
                if ($rule -isnot [System.Collections.IDictionary]) {
                    continue
                }
                foreach ($condition in @($rule['conditions'])) {
                    if ($condition -is [System.Collections.IDictionary]) {
                        & $add $condition['column']
                    }
                }
                & $add $rule['applyToColumn']
            }
        }
    }
    return $columns.ToArray()
}

function Get-DemoDashboardBinding {
    <#
    .SYNOPSIS
    The let statements that bind the dashboard's parameters for a direct query, the way the dashboard binds them:
    _startTime and _endTime to the window, and _selectedTargets to null, the dashboard's "Select all" (the Target
    parameter has allIsNull). Only the variables in -Variable are bound. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [datetime] $StartUtc,

        [Parameter(Mandatory)]
        [datetime] $EndUtc,

        [string[]] $Variable = @('_startTime', '_endTime', '_selectedTargets')
    )

    $format = 'yyyy-MM-ddTHH:mm:ss.fffZ'
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $values = [ordered]@{
        _startTime       = 'datetime({0})' -f $StartUtc.ToUniversalTime().ToString($format, $culture)
        _endTime         = 'datetime({0})' -f $EndUtc.ToUniversalTime().ToString($format, $culture)
        _selectedTargets = 'dynamic(null)'
    }
    foreach ($name in $Variable) {
        if (-not $values.Contains($name)) {
            throw ('The dashboard query uses the variable {0}, which the data check can''t bind.' -f $name)
        }
    }
    return (@(foreach ($name in $values.Keys) {
                if ($Variable -contains $name) {
                    'let {0} = {1};' -f $name, $values[$name]
                }
            }) -join "`n")
}

function Get-DemoDashboardSourceProbe {
    <#
    .SYNOPSIS
    A read-only query that counts a tile query's own source rows per target: the shared prelude, the source table
    and every row filter that follows it (so the tile's own time window and filters), then the target mapping.
    Empty when the query doesn't have that shape. Internal.

    .DESCRIPTION
    Every dashboard query is Live.Prelude.kql, which ends with the line '};' that closes _target(), followed by a
    body that starts with its telemetry table (or the union of them) and its row filters, before any extend. When
    a tile is empty, the probe tells whether there was anything to show.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $QueryText
    )

    $lines = $QueryText.Replace("`r`n", "`n").Split("`n")
    $close = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -eq '};') {
            $close = $index
            break
        }
    }
    if ($close -lt 0) {
        return ''
    }
    $index = $close + 1
    while ($index -lt $lines.Count -and ($lines[$index].Trim() -eq '' -or $lines[$index].TrimStart().StartsWith('//', [System.StringComparison]::Ordinal))) {
        $index++
    }
    if ($index -ge $lines.Count) {
        return ''
    }
    $source = $lines[$index].Trim()
    if ($source -cnotmatch '^(SqlServer[A-Za-z]+|union withsource=[A-Za-z]+ SqlServer\*)$') {
        return ''
    }
    $probe = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines[0..$close]) {
        $probe.Add($line)
    }
    $probe.Add($source)
    for ($index++; $index -lt $lines.Count -and $lines[$index] -match '^\|\s*where\s'; $index++) {
        $probe.Add($lines[$index])
    }
    $probe.Add('| extend Target = _target(ResourceType, ResourceName)')
    $probe.Add('| where isnotempty(Target)')
    $probe.Add('| where isempty(_selectedTargets) or Target in (_selectedTargets)')
    $probe.Add('| summarize Rows = count() by Target')
    return ($probe -join "`n")
}

function Get-DemoDashboardTargetState {
    <#
    .SYNOPSIS
    Why tiles can be empty right now: the power state of T1's VM and T2's VM, and the status of T3's database,
    read with Azure CLI reads through Invoke-DemoAz. A value that can't be read is empty. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $group = Get-DemoResourceGroupName -Config $Config
    $hostVm = Get-DemoHostVmName -Config $Config
    $t1 = ''
    $t2 = ''
    $t3 = ''
    try {
        $t1 = [string](Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $group -VmName 'sqlvm01')
    }
    catch {
        $t1 = ''
    }
    try {
        $t2 = [string](Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $group -VmName $hostVm)
    }
    catch {
        $t2 = ''
    }
    try {
        $t3 = [string](Get-DemoT3State -Config $Config).Status
    }
    catch {
        $t3 = ''
    }
    $stopped = @(foreach ($entry in @(@{ Name = 'sqlvm01'; Target = 'T1'; State = $t1 }, @{ Name = $hostVm; Target = 'T2'; State = $t2 })) {
            if ($entry.State -and $entry.State -ne 'PowerState/running') {
                '{0}''s VM {1} ({2})' -f $entry.Target, $entry.Name, ($entry.State -replace '^PowerState/', '')
            }
        })
    [pscustomobject]@{
        T1Vm         = 'sqlvm01'
        T1PowerState = $t1
        T2Vm         = $hostVm
        T2PowerState = $t2
        T3Status     = $t3
        VmsStopped   = $stopped
    }
}
