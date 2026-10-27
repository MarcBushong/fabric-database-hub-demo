function Test-DemoSkuZone {
    <#
    .SYNOPSIS
    True when a resource SKU from 'az vm list-skus' is offered in the zone and has no Zone restriction for it.

    .DESCRIPTION
    Internal. 'az vm list-skus --all' returns locationInfo[].zones for the zones a SKU is offered in, and
    restrictions of type Zone (restrictionInfo.zones) where the subscription can't use it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object] $Sku,

        [Parameter(Mandatory)]
        [ValidatePattern('^[1-3]$')]
        [string] $Zone
    )

    $zones = [System.Collections.Generic.List[string]]::new()
    if ($Sku.PSObject.Properties['locationInfo']) {
        foreach ($info in @($Sku.locationInfo)) {
            if ($info -and $info.PSObject.Properties['zones']) {
                foreach ($offered in @($info.zones)) {
                    $zones.Add([string]$offered)
                }
            }
        }
    }
    if (-not $zones.Contains($Zone)) {
        return $false
    }
    if ($Sku.PSObject.Properties['restrictions']) {
        foreach ($restriction in @($Sku.restrictions)) {
            if ($restriction -and $restriction.type -eq 'Zone' -and $restriction.PSObject.Properties['restrictionInfo'] -and
                $restriction.restrictionInfo.PSObject.Properties['zones'] -and @($restriction.restrictionInfo.zones) -contains $Zone) {
                return $false
            }
        }
    }
    return $true
}
