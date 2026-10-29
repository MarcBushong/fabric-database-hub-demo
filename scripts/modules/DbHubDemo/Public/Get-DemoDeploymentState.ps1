function Get-DemoDeploymentState {
    <#
    .SYNOPSIS
    Reads deploy.ps1's state from the demo resource group's tags (plan section 9.2).

    .DESCRIPTION
    The state lives in resource group tags, not in a local file, so 'deploy.ps1 -Resume' works from any
    machine and from GitHub Actions, and it goes away with the resource group. Returns Exists (whether the
    group exists), Stage (the last stage that finished, or empty), StageUtc, BundleSha256, BundleChunkCount,
    RunnerSha256, RunnerChunkCount, BundleSentTo and RunnerSentTo (the VMs that have the chunks of exactly
    those hashes), NetworkMode, T3UseFreeLimit ($null when unknown), T3AdminGroupName, BastionExpiresUtc,
    HostPasswordUtc, TrackT1, TrackT2, TrackT4, and TrackFabric (the last step each parallel track finished, ADR 0018),
    T2Source (golden or build), FabricCapacityResumed and FabricCapacityResumedUtc (the capacity start-demo.ps1 resumed
    with fabric.manageCapacity, as "<resource group>/<name>", Phase 26b), GuidedStopUtc (until when the PaygWizard guided
    stop's request is valid) and T4Sku (the size T4's Burstable fallback settled on: Standard_B2s, or None; Phase 28),
    T2BuildUtc (when the T2 host's loader started a bootstrap generation that nobody has seen finish; empty when none
    runs; Phase 28 review follow-up), and Tags (every tag on the group). Read-only.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .EXAMPLE
    (Get-DemoDeploymentState -Config $config).Stage
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $exists = Test-DemoResourceGroupExist -Config $Config
    $tags = @{}
    if ($exists) {
        $tags = Get-DemoResourceGroupTag -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName (Get-DemoResourceGroupName -Config $Config)
    }
    $names = Get-DemoDeploymentStateTagName
    $read = { param([string] $Key) if ($tags.ContainsKey($names[$Key])) { [string]$tags[$names[$Key]] } else { '' } }
    $count = { param([string] $Key) $value = & $read $Key; if ($value -match '^\d{1,3}$') { [int]$value } else { 0 } }
    $list = { param([string] $Key) @((& $read $Key) -split ',' | Where-Object { $_ }) }
    $freeOffer = & $read 'T3UseFreeLimit'
    return [pscustomobject]@{
        Exists            = $exists
        Stage             = & $read 'Stage'
        StageUtc          = & $read 'StageUtc'
        BundleSha256      = (& $read 'BundleSha256').ToLowerInvariant()
        BundleChunkCount  = & $count 'BundleChunkCount'
        RunnerSha256      = (& $read 'RunnerSha256').ToLowerInvariant()
        RunnerChunkCount  = & $count 'RunnerChunkCount'
        BundleSentTo      = & $list 'BundleSentTo'
        RunnerSentTo      = & $list 'RunnerSentTo'
        NetworkMode       = & $read 'NetworkMode'
        T3UseFreeLimit    = if ($freeOffer -eq 'true') { $true } elseif ($freeOffer -eq 'false') { $false } else { $null }
        T3AdminGroupName  = & $read 'T3AdminGroupName'
        BastionExpiresUtc = & $read 'BastionExpiresUtc'
        HostPasswordUtc   = & $read 'HostPasswordSet'
        TrackT1           = & $read 'TrackT1'
        TrackT2           = & $read 'TrackT2'
        TrackT4           = & $read 'TrackT4'
        TrackFabric       = & $read 'TrackFabric'
        T2Source          = & $read 'T2Source'
        FabricCapacityResumed    = & $read 'FabricCapacityResumed'
        FabricCapacityResumedUtc = & $read 'FabricCapacityResumedUtc'
        GuidedStopUtc     = & $read 'GuidedStopUtc'
        T4Sku             = & $read 'T4Sku'
        T2BuildUtc        = & $read 'T2BuildUtc'
        Tags              = $tags
    }
}
