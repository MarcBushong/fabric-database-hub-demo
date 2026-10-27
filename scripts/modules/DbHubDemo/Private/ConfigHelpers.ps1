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
