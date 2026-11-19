function Get-DemoSchemaDefault {
    <#
    .SYNOPSIS
    Builds a hashtable of default values from a JSON schema node.

    .DESCRIPTION
    Internal. Walks 'properties' recursively. A property with a 'default' gets that value; an object
    property gets the defaults of its own properties merged over its 'default'. The schema is the single
    source of truth for configuration defaults.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Node
    )

    $result = @{}
    if (-not $Node.Contains('properties')) {
        return $result
    }

    foreach ($name in $Node['properties'].Keys) {
        $property = $Node['properties'][$name]
        if ($property -isnot [System.Collections.IDictionary]) {
            continue
        }

        $isObject = $property.Contains('properties')
        if ($isObject) {
            $nested = Get-DemoSchemaDefault -Node $property
            if ($property.Contains('default') -and $property['default'] -is [System.Collections.IDictionary]) {
                $nested = Merge-DemoHashtable -Base $property['default'] -Override $nested
            }
            $result[$name] = $nested
        }
        elseif ($property.Contains('default')) {
            $result[$name] = $property['default']
        }
    }

    return $result
}

function Merge-DemoHashtable {
    <#
    .SYNOPSIS
    Deep-merges two hashtables. Values in Override win; nested dictionaries merge recursively.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary] $Base,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary] $Override
    )

    $merged = @{}
    foreach ($key in $Base.Keys) {
        $merged[$key] = $Base[$key]
    }

    foreach ($key in $Override.Keys) {
        $value = $Override[$key]
        if ($merged.Contains($key) -and $merged[$key] -is [System.Collections.IDictionary] -and $value -is [System.Collections.IDictionary]) {
            $merged[$key] = Merge-DemoHashtable -Base $merged[$key] -Override $value
        }
        else {
            $merged[$key] = $value
        }
    }

    return $merged
}

function ConvertTo-DemoConfigFileText {
    <#
    .SYNOPSIS
    The configuration as the JSON a script's -ConfigPath reads back with Get-DemoConfig: without the marks that only a
    run's own configuration carries and the schema doesn't allow in the file (additionalProperties false):
    t2SqlInstallModeSource and t4EnabledIgnored (Get-DemoConfig; 2026-11-09), t4SkuSource (ADR 0019), and
    sessionCeilingUsdSource (Get-DemoConfig; 2026-11-18). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $copy = [ordered]@{}
    foreach ($key in $Config.Keys) {
        if ([string]$key -notin 't2SqlInstallModeSource', 't4EnabledIgnored', 't4SkuSource', 'sessionCeilingUsdSource') {
            $copy[$key] = $Config[$key]
        }
    }
    return ($copy | ConvertTo-Json -Depth 20)
}

function Get-DemoSessionCeilingLegacyText {
    # The one line a run prints, and its status page shows, when the configuration's sessionCeilingUsd is exactly 15, the
    # default before 2026-11-18, which counts as 20, today's default (sessionCeilingUsdSource legacy, Get-DemoConfig;
    # ADR 0016). '' otherwise. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if (-not ($Config.Contains('sessionCeilingUsdSource') -and [string]$Config['sessionCeilingUsdSource'] -eq 'legacy')) {
        return ''
    }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, 'sessionCeilingUsd 15 in your configuration (the default before 2026-11-18) counts as {0}, the default since then: lowest-cost''s T3 went from 1 to 2 vCores, because Database Agents doesn''t support one-vCore serverless databases, which raises a session''s estimate; a session over the ceiling is still only a Warning. To drop this note, set sessionCeilingUsd to {0}, or to any value but 15, which is kept as it is.', $Config['sessionCeilingUsd'])
}
