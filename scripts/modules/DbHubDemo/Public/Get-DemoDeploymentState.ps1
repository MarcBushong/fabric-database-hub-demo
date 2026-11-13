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
    stop's request is valid; while it's still set after that, the guided stop's cleanup didn't finish and its Bastion
    may be up, so DONE waits: Get-DemoGuidedStopLeftover, Phase 28 review) and T4Sku (the size T4's fallback settled
    on, in the DbHubT4Size tag: Standard_D4ads_v5, Standard_D2ds_v5, a size an existing server kept, or, since 2026-11-09,
    any documented size the fallback chose for a size t4SkuName sets; an older run's None or Refused no longer leaves T4
    out, and start-demo.ps1 or the next deploy.ps1 clears it; ADR 0019, Resolve-DemoEffectiveConfig), T4Refused (2026-11-09: the sizes Azure refused, the one the
    configuration asks for first, with the zones tried and when, in the DbHubT4Refused tag; ConvertFrom-DemoT4RefusedRecord),
    T2BuildUtc (when the T2 host's loader started a bootstrap generation that nobody has seen finish; empty when none
    runs; Phase 28 review follow-up), T2InstallMode (the T2 guest's own install mode as its host reported it, in the
    DbHubT2InstallMode tag; 2026-11-09, Get-DemoT2GuestInstallMode), T4Replica (Session once deploy.ps1 has set up T4's
    read replica for this environment, in the DbHubT4Replica tag; 2026-11-13, ADR 0025), T4ReplicaSize (the size and zone the
    last replica was created with, in the DbHubT4ReplicaSize tag), and Tags (every tag on the group). Read-only.

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
        T4Refused         = & $read 'T4Refused'
        T2BuildUtc        = & $read 'T2BuildUtc'
        T2InstallMode     = & $read 'T2InstallMode'
        T4Replica         = & $read 'T4Replica'
        T4ReplicaSize     = & $read 'T4ReplicaSize'
        Tags              = $tags
    }
}
