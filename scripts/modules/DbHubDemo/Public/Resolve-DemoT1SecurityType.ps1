function Resolve-DemoT1SecurityType {
    <#
    .SYNOPSIS
    Resolves securityType.t1 (ADR 0003): Auto becomes TrustedLaunch only when the T1 image advertises it.

    .DESCRIPTION
    Reads the T1 image (config/versions.json vmImages.t1) with 'az vm image show' through Invoke-DemoAz.
    Per the Trusted Launch FAQ, a Generation 2 image supports Trusted Launch when hyperVGeneration is V2
    and its SecurityType feature contains TrustedLaunch; a size that reports the TrustedLaunchDisabled
    capability doesn't. Auto resolves to TrustedLaunch with Pass, or to Standard with Warning. An explicit
    TrustedLaunch that the image or size doesn't support is a Fail. Returns SecurityType, Status, Message,
    and Evidence.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER SizeSku
    The T1 size's entry from 'az vm list-skus', when the caller already has it.

    .EXAMPLE
    (Resolve-DemoT1SecurityType -Config $config).SecurityType
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [object] $SizeSku = $null
    )

    $requested = [string]$Config['securityType']['t1']
    if ($requested -eq 'Standard') {
        return [pscustomobject]@{ SecurityType = 'Standard'; Status = 'Pass'; Message = 'T1 uses the Standard security type, as configured.'; Evidence = @{ requested = $requested } }
    }

    $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $image = $versions.vmImages.t1
    $urn = '{0}:{1}:{2}:{3}' -f $image.publisher, $image.offer, $image.sku, $image.version
    $details = Invoke-DemoAz -SubscriptionId $Config['subscriptionId'] -ArgumentList @('vm', 'image', 'show', '--urn', $urn, '--location', $Config['location']) -AsJson -AllowFailure

    $generation = ''
    $securityFeature = ''
    if ($details) {
        if ($details.PSObject.Properties['hyperVGeneration']) {
            $generation = [string]$details.hyperVGeneration
        }
        if ($details.PSObject.Properties['features']) {
            $feature = @($details.features) | Where-Object { $_ -and $_.name -eq 'SecurityType' } | Select-Object -First 1
            if ($feature) {
                $securityFeature = [string]$feature.value
            }
        }
    }
    $sizeDisabled = $false
    if ($SizeSku -and $SizeSku.PSObject.Properties['capabilities']) {
        $sizeDisabled = @($SizeSku.capabilities | Where-Object { $_.name -eq 'TrustedLaunchDisabled' -and [string]$_.value -eq 'True' }).Count -gt 0
    }
    $supported = $generation -eq 'V2' -and $securityFeature -match 'TrustedLaunch' -and -not $sizeDisabled
    $evidence = @{ requested = $requested; image = $urn; hyperVGeneration = $generation; securityTypeFeature = $securityFeature; sizeTrustedLaunchDisabled = $sizeDisabled }

    if ($supported) {
        return [pscustomobject]@{ SecurityType = 'TrustedLaunch'; Status = 'Pass'; Message = 'T1 uses Trusted Launch: the image advertises it and the size supports it.'; Evidence = $evidence }
    }
    $reason = if (-not $details) { 'the image details could not be read' } elseif ($sizeDisabled) { 'the size reports TrustedLaunchDisabled' } else { "the image's SecurityType feature is '$securityFeature' on generation '$generation'" }
    if ($requested -eq 'TrustedLaunch') {
        return [pscustomobject]@{ SecurityType = 'TrustedLaunch'; Status = 'Fail'; Message = "securityType.t1 is TrustedLaunch, but $reason."; Evidence = $evidence }
    }
    return [pscustomobject]@{ SecurityType = 'Standard'; Status = 'Warning'; Message = "T1 falls back to the Standard security type: $reason."; Evidence = $evidence }
}
