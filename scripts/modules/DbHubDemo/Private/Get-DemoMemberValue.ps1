function Get-DemoMemberValue {
    <#
    .SYNOPSIS
    Returns a property or key of an object, or $null when it doesn't exist.

    .DESCRIPTION
    Internal. Works for dictionaries and for objects from ConvertFrom-Json, ignores case, and never throws
    under Set-StrictMode, which the module uses.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    # The leading comma keeps an array value intact instead of unrolling it into the pipeline.
    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return , $InputObject[$key]
            }
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return , $property.Value
    }
    return $null
}
