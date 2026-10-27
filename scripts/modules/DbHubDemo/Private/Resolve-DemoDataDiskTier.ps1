function Resolve-DemoDataDiskTier {
    <#
    .SYNOPSIS
    Returns the data disk tier (None, E10, P10, or PremiumV2) for one VM, matching infra/modules/demo.bicep (ADR 0016).

    .DESCRIPTION
    Internal. The cost estimate and preflight both call this, so they agree with each other; demo.bicep
    applies the same rules, and a change here needs the same change there.
    - An explicit dataDiskSku (None, E10, P10, or PremiumV2) wins. Premium SSD P10 is only ever an explicit
      opt-in, and None removes the data disk from a profile that has one.
    - Otherwise ('Auto'), a configured zone selects the profile's zonal tier (Premium SSD v2), because
      Premium SSD v2 needs a zonal VM; with no zone the profile's regional tier applies. The lowest-cost
      profile's tier is None: no separate data disk (2026-10-20).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $VmSizing,

        [AllowEmptyString()]
        [string] $Zone = '',

        [ValidateSet('Auto', 'None', 'E10', 'P10', 'PremiumV2')]
        [string] $Override = 'Auto'
    )

    if ($Override -ne 'Auto') {
        return $Override
    }

    if ($Zone -and $VmSizing.Contains('zonalDataDisk')) {
        return [string]$VmSizing['zonalDataDisk']
    }

    return [string]$VmSizing['dataDisk']
}

function Get-DemoDataDiskOverride {
    <#
    .SYNOPSIS
    Returns the configured dataDiskSku, or 'Auto' when the configuration doesn't set one. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ($Config.Contains('dataDiskSku') -and $Config['dataDiskSku']) {
        return [string]$Config['dataDiskSku']
    }

    return 'Auto'
}
