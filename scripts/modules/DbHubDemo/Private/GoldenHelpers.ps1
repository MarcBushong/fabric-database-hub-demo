function Get-DemoGoldenResourceGroupName {
    # rg-<prefix>-golden: the T2 golden snapshots, shared by every environment of the prefix (ADR 0018). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    return ('rg-{0}-golden' -f $Config['prefix'])
}

function Get-DemoGoldenTagName {
    # The tags a golden snapshot carries (ADR 0018, guardrail 2). Values are strings; times are UTC. Internal.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    return [ordered]@{
        Role             = 'dbhubRole'
        Prefix           = 'dbhubPrefix'
        CapturedUtc      = 'dbhubCapturedUtc'
        EvalExpiresUtc   = 'dbhubEvalExpiresUtc'
        BundleSha256     = 'dbhubBundleSha256'
        RunnerSha256     = 'dbhubRunnerSha256'
        SqlEdition       = 'dbhubSqlEdition'
        SqlVersion       = 'dbhubSqlVersion'
        SqlUpdateLevel   = 'dbhubSqlUpdateLevel'
        InstallMode      = 'dbhubInstallMode'
        HostSize         = 'dbhubHostSize'
        SecurityType     = 'dbhubSecurityType'
        UsedGiB          = 'dbhubUsedGiB'
        SourceGroup      = 'dbhubSourceGroup'
        SourceAzureVmId  = 'dbhubSourceVmId'
        ArcIdentity      = 'dbhubArcIdentity'
        DiskVerifiedUtc  = 'dbhubDiskVerifiedUtc'
        BootVerifiedUtc  = 'dbhubBootVerifiedUtc'
        OnboardVerified  = 'dbhubOnboardVerifiedUtc'
        SourceReleased   = 'dbhubSourceReleasedUtc'
    }
}

function Get-DemoGoldenStandardTag {
    # The golden group's and snapshot's standard tags. No deploymentId and no autoShutdown: the group serves every
    # environment of the prefix and must not count as an environment's residue (Phase 16's TEARDOWN.RESIDUAL.TAGGED
    # matches a deploymentId, or solution with the environment's name). Internal.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    return [ordered]@{
        solution    = 'fabric-database-hub-demo'
        environment = 'golden'
        owner       = [string]$Config['owner']
        purpose     = 't2-golden-snapshot'
        costCenter  = $(if ($Config['costCenter']) { [string]$Config['costCenter'] } else { 'demo' })
        dbhubPrefix = [string]$Config['prefix']
    }
}

function Get-DemoGoldenSnapshotName {
    # snap-<prefix>-t2golden-<yyyyMMddHHmm> (UTC). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    return ('snap-{0}-t2golden-{1}' -f $Config['prefix'], $NowUtc.ToUniversalTime().ToString('yyyyMMddHHmm', [System.Globalization.CultureInfo]::InvariantCulture))
}

function ConvertTo-DemoTagArgument {
    # 'key=value' arguments for --tags. Values are kept as they are; Invoke-DemoAz passes each as one argument. Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Tag
    )

    return @(foreach ($key in $Tag.Keys) {
            '{0}={1}' -f $key, [string]$Tag[$key]
        })
}

function ConvertFrom-DemoGoldenSnapshot {
    <#
    .SYNOPSIS
    A golden snapshot from 'az snapshot show' or 'list' as a flat object with its tags parsed. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Snapshot,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $names = Get-DemoGoldenTagName
    $tags = Get-DemoMemberValue -InputObject $Snapshot -Name 'tags'
    $tag = {
        param([string] $Key)
        [string](Get-DemoMemberValue -InputObject $tags -Name $names[$Key])
    }
    $parseUtc = {
        param([string] $Text)
        $value = [datetime]::MinValue
        if ($Text -and [datetime]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$value)) {
            return $value
        }
        return $null
    }
    $expires = & $parseUtc (& $tag 'EvalExpiresUtc')
    $properties = Get-DemoMemberValue -InputObject $Snapshot -Name 'properties'
    $sku = Get-DemoMemberValue -InputObject $Snapshot -Name 'sku'
    $sizeGb = Get-DemoMemberValue -InputObject $Snapshot -Name 'diskSizeGB'
    if ($null -eq $sizeGb) {
        $sizeGb = Get-DemoMemberValue -InputObject $properties -Name 'diskSizeGB'
    }
    $incremental = Get-DemoMemberValue -InputObject $Snapshot -Name 'incremental'
    if ($null -eq $incremental) {
        $incremental = Get-DemoMemberValue -InputObject $properties -Name 'incremental'
    }
    $access = [string](Get-DemoMemberValue -InputObject $Snapshot -Name 'networkAccessPolicy')
    if (-not $access) {
        $access = [string](Get-DemoMemberValue -InputObject $properties -Name 'networkAccessPolicy')
    }
    $provisioning = [string](Get-DemoMemberValue -InputObject $Snapshot -Name 'provisioningState')
    if (-not $provisioning) {
        $provisioning = [string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState')
    }
    $used = 0.0
    $null = [double]::TryParse((& $tag 'UsedGiB'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$used)
    return [pscustomobject]@{
        Name                = [string](Get-DemoMemberValue -InputObject $Snapshot -Name 'name')
        Id                  = [string](Get-DemoMemberValue -InputObject $Snapshot -Name 'id')
        Location            = [string](Get-DemoMemberValue -InputObject $Snapshot -Name 'location')
        Sku                 = [string](Get-DemoMemberValue -InputObject $sku -Name 'name')
        SizeGiB             = [int]$sizeGb
        UsedGiB             = $used
        Incremental         = [bool]$incremental
        NetworkAccessPolicy = $access
        ProvisioningState   = $provisioning
        Role                = & $tag 'Role'
        Prefix              = & $tag 'Prefix'
        CapturedUtc         = & $parseUtc (& $tag 'CapturedUtc')
        EvalExpiresUtc      = $expires
        EvalDaysLeft        = $(if ($null -ne $expires) { [int][System.Math]::Floor(($expires - $NowUtc.ToUniversalTime()).TotalDays) } else { $null })
        BundleSha256        = & $tag 'BundleSha256'
        RunnerSha256        = & $tag 'RunnerSha256'
        SqlEdition          = & $tag 'SqlEdition'
        SqlVersion          = & $tag 'SqlVersion'
        SqlUpdateLevel      = & $tag 'SqlUpdateLevel'
        InstallMode         = & $tag 'InstallMode'
        HostSize            = & $tag 'HostSize'
        SecurityType        = & $tag 'SecurityType'
        SourceGroup         = & $tag 'SourceGroup'
        SourceAzureVmId     = & $tag 'SourceAzureVmId'
        ArcIdentity         = & $tag 'ArcIdentity'
        DiskVerifiedUtc     = & $parseUtc (& $tag 'DiskVerifiedUtc')
        BootVerifiedUtc     = & $parseUtc (& $tag 'BootVerifiedUtc')
        OnboardVerifiedUtc  = & $parseUtc (& $tag 'OnboardVerified')
        SourceReleasedUtc   = & $parseUtc (& $tag 'SourceReleased')
    }
}

function Wait-DemoVmAgentReady {
    <#
    .SYNOPSIS
    Polls a VM's instance view until its Azure VM agent reports Ready, so the first Run Command on a VM that has
    just booted doesn't spend its own timeout waiting for the agent. Returns the seconds waited, or -1 on
    timeout. Internal.

    Source: the agent's status in the instance view
    (https://learn.microsoft.com/azure/virtual-machines/extensions/agent-windows#detect-the-vm-agent, checked 2026-10-22).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $VmName,

        [ValidateRange(1, 60)]
        [int] $TimeoutMinutes = 15,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalMinutes -lt $TimeoutMinutes) {
        $status = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('vm', 'get-instance-view', '--resource-group', $ResourceGroupName, '--name', $VmName, '--query', 'instanceView.vmAgent.statuses[0].displayStatus', '--output', 'tsv') -AllowFailure
        if ($status.ExitCode -eq 0 -and ([string]$status.StdOut).Trim() -eq 'Ready') {
            return [int]$watch.Elapsed.TotalSeconds
        }
        Start-Sleep -Seconds $PollSeconds
    }
    return -1
}

function Resolve-DemoT2Source {
    <#
    .SYNOPSIS
    Decides where the T2 host comes from (ADR 0018, section 3) and reports it as PREFLIGHT.T2.SOURCE.
    Internal.

    .DESCRIPTION
    t2Source in the configuration (optional, default auto): auto restores a new host from the newest usable
    golden snapshot and builds it otherwise; golden requires one (Fail without it); build always builds.
    Only a new host chooses: an existing archost01 keeps its disk, and one attached from a golden disk has no
    osProfile. A usable snapshot is tagged t2-golden for this prefix and boot-verified, lies in the configured
    region with network access DenyAll, matches the install mode and the host's security type, fits a host
    without a data disk (the guest lives on the OS disk), and its guest's Windows evaluation isn't over.
    Warnings at 30 and 7 days before the evaluation ends, and when it ends before the configuration's
    expiresOn. Returns Source (golden, build, existing-golden, or existing-build), SnapshotId, SnapshotName,
    AttachExisting, and Result.

    Source: incremental snapshots, https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots
    (checked 2026-10-22).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots'
    $configured = if ($Config.Contains('t2Source') -and $Config['t2Source']) { ([string]$Config['t2Source']).ToLowerInvariant() } else { 'auto' }
    $decide = {
        param([string] $Source, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '', [object] $Snapshot = $null, [bool] $Attach = $false)
        $Evidence['t2Source'] = $configured
        $Evidence['decision'] = $Source
        [pscustomobject]@{
            Source         = $Source
            SnapshotId     = $(if ($null -ne $Snapshot) { [string]$Snapshot.Id } else { '' })
            SnapshotName   = $(if ($null -ne $Snapshot) { [string]$Snapshot.Name } else { '' })
            AttachExisting = $Attach
            Result         = (New-DemoResult -CheckId 'PREFLIGHT.T2.SOURCE' -Area 'preflight' -Target 'T2' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl)
        }
    }
    if ($configured -notin 'auto', 'golden', 'build') {
        return (& $decide 'build' 'Fail' ("t2Source is '{0}'; use auto, golden, or build." -f $configured) @{} 'Fix t2Source in the configuration.')
    }
    if ((Get-DemoHostVmName -Config $Config) -ne 'archost01') {
        return (& $decide 'build' 'Not selected' 'Golden snapshots keep a nested guest; the evaluation-only T2 is always built.')
    }

    $subscriptionId = [string]$Config['subscriptionId']
    $vm = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', 'archost01', '--output', 'json') -AsJson -AllowFailure
    if ($null -ne $vm) {
        if ($null -eq (Get-DemoMemberValue -InputObject $vm -Name 'osProfile')) {
            return (& $decide 'existing-golden' 'Pass' 'archost01 exists and runs from a disk restored from a golden snapshot; it keeps that disk.' @{} '' $null $true)
        }
        return (& $decide 'existing-build' 'Pass' 'archost01 exists and was built from the image; it keeps its disk.')
    }
    if ($configured -eq 'build') {
        return (& $decide 'build' 'Pass' 't2Source is build: a new archost01 builds its guest from the image, then waits for the setup-wizard step in PaygWizard mode.')
    }

    $hostSizing = (Get-DemoProfile).profiles[[string]$Config['profile']].t2Host
    $zone = if ($Config.Contains('zone') -and $Config['zone']) { [string]$Config['zone'] } else { '' }
    $hostDataDisk = Resolve-DemoDataDiskTier -VmSizing $hostSizing -Zone $zone -Override (Get-DemoDataDiskOverride -Config $Config)
    $installMode = [string]$Config['t2SqlInstallMode']
    $securityType = [string]$Config['securityType']['t2Host']
    $snapshots = @(Get-DemoT2GoldenSnapshot -Config $Config -NowUtc $NowUtc)
    $rejected = [ordered]@{}
    $usable = [System.Collections.Generic.List[object]]::new()
    foreach ($snapshot in $snapshots) {
        $why = [System.Collections.Generic.List[string]]::new()
        if ($null -eq $snapshot.BootVerifiedUtc) { $why.Add('not boot-verified (test-t2-golden.ps1)') }
        if ($snapshot.Location -ne [string]$Config['location']) { $why.Add(('in {0}' -f $snapshot.Location)) }
        if ($snapshot.NetworkAccessPolicy -ne 'DenyAll') { $why.Add(('network access {0}' -f $snapshot.NetworkAccessPolicy)) }
        if ($snapshot.ProvisioningState -and $snapshot.ProvisioningState -ne 'Succeeded') { $why.Add(('state {0}' -f $snapshot.ProvisioningState)) }
        if ($snapshot.InstallMode -ne $installMode) { $why.Add(('install mode {0}' -f $snapshot.InstallMode)) }
        if ($snapshot.SecurityType -and $snapshot.SecurityType -ne $securityType) { $why.Add(('security type {0}' -f $snapshot.SecurityType)) }
        if ($hostDataDisk -ne 'None') { $why.Add(('the profile gives the host a {0} data disk' -f $hostDataDisk)) }
        if ($null -eq $snapshot.EvalDaysLeft -or $snapshot.EvalDaysLeft -lt 1) { $why.Add('its guest''s Windows evaluation is over') }
        if ($why.Count -gt 0) {
            $rejected[$snapshot.Name] = $why -join ', '
        }
        else {
            $usable.Add($snapshot)
        }
    }
    $evidence = [ordered]@{ snapshots = $snapshots.Count; rejected = $rejected }
    if ($usable.Count -eq 0) {
        $reasons = if ($rejected.Count -gt 0) { ' ({0})' -f (($rejected.Keys | ForEach-Object { '{0}: {1}' -f $_, $rejected[$_] }) -join '; ') } else { '' }
        if ($configured -eq 'golden') {
            return (& $decide 'build' 'Fail' ('t2Source is golden, but no usable golden snapshot exists{0}.' -f $reasons) $evidence 'Capture one (./scripts/capture-t2-golden.ps1) and prove it (./scripts/test-t2-golden.ps1 -Onboard), or set t2Source to auto or build.')
        }
        $expired = @($snapshots | Where-Object { $null -ne $_.EvalDaysLeft -and $_.EvalDaysLeft -lt 1 })
        $status = if ($expired.Count -gt 0) { 'Warning' } else { 'Pass' }
        return (& $decide 'build' $status ('No usable golden snapshot{0}: a new archost01 builds its guest from the image, then waits for the setup-wizard step in PaygWizard mode.' -f $reasons) $evidence $(if ($expired.Count -gt 0) { 'After this build and the wizard, capture again: ./scripts/capture-t2-golden.ps1.' } else { '' }))
    }

    $chosen = $usable[0]
    $evidence['snapshot'] = $chosen.Name
    $evidence['capturedUtc'] = $chosen.CapturedUtc
    $evidence['bootVerifiedUtc'] = $chosen.BootVerifiedUtc
    $evidence['onboardVerifiedUtc'] = $chosen.OnboardVerifiedUtc
    $evidence['evalExpiresUtc'] = $chosen.EvalExpiresUtc
    $evidence['evalDaysLeft'] = $chosen.EvalDaysLeft
    $notes = [System.Collections.Generic.List[string]]::new()
    $status = 'Pass'
    if ($chosen.EvalDaysLeft -le 7) {
        $status = 'Warning'
        $notes.Add(('its guest''s Windows evaluation ends in {0} days: re-capture now' -f $chosen.EvalDaysLeft))
    }
    elseif ($chosen.EvalDaysLeft -le 30) {
        $status = 'Warning'
        $notes.Add(('its guest''s Windows evaluation ends in {0} days: re-capture after a fresh build' -f $chosen.EvalDaysLeft))
    }
    $expiresOn = [datetime]::MinValue
    if ($Config['expiresOn'] -and [datetime]::TryParseExact([string]$Config['expiresOn'], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$expiresOn) -and $null -ne $chosen.EvalExpiresUtc -and $expiresOn -gt $chosen.EvalExpiresUtc) {
        $status = 'Warning'
        $notes.Add(('the evaluation ends before the environment''s expiresOn ({0})' -f $Config['expiresOn']))
    }
    $message = 'A new archost01 restores from {0} (captured {1:yyyy-MM-dd}, boot-verified {2:yyyy-MM-dd}; its guest''s evaluation ends {3:yyyy-MM-dd}, in {4} days){5}.' -f $chosen.Name, $chosen.CapturedUtc, $chosen.BootVerifiedUtc, $chosen.EvalExpiresUtc, $chosen.EvalDaysLeft, $(if ($notes.Count) { ': ' + ($notes -join '; ') } else { '' })
    return (& $decide 'golden' $status $message $evidence $(if ($status -eq 'Warning') { 'Plan a fresh build (t2Source build), the setup-wizard step, and a new capture (capture-t2-golden.ps1, then test-t2-golden.ps1 -Onboard).' } else { '' }) $chosen)
}

function Get-DemoT2GoldenStatus {
    <#
    .SYNOPSIS
    STATUS.T2.GOLDEN for status.ps1 (ADR 0018, guardrail 2): the newest usable golden snapshot and how long its
    guest's Windows evaluation has left. Internal.

    .DESCRIPTION
    Not selected without a snapshot (a redeploy builds T2). Warning when none is usable (not boot-verified,
    or its evaluation is over), at 30 days or less, at 7 days or less ("re-capture now"), and when the
    evaluation ends before the configuration's expiresOn. Otherwise Pass.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Snapshot = @()
    )

    $group = Get-DemoGoldenResourceGroupName -Config $Config
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots'
    $new = { param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '') New-DemoResult -CheckId 'STATUS.T2.GOLDEN' -Area 't2' -Target 'T2' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl }
    if ((Get-DemoHostVmName -Config $Config) -ne 'archost01') {
        return (& $new 'Not selected' 'The evaluation-only T2 has no golden snapshot.')
    }
    $all = @($Snapshot | Where-Object { $null -ne $_ })
    if ($all.Count -eq 0) {
        return (& $new 'Not selected' ('No T2 golden snapshot in {0}: a redeploy builds T2 and, in PaygWizard mode, waits for the setup-wizard step.' -f $group) @{} 'To keep the current T2 for fast redeploys: ./scripts/capture-t2-golden.ps1, then ./scripts/test-t2-golden.ps1 -Onboard.')
    }
    $usable = @($all | Where-Object { $null -ne $_.BootVerifiedUtc -and $null -ne $_.EvalDaysLeft -and $_.EvalDaysLeft -ge 1 })
    if ($usable.Count -eq 0) {
        $why = ($all | ForEach-Object { '{0}: {1}' -f $_.Name, $(if ($null -eq $_.BootVerifiedUtc) { 'not boot-verified' } else { 'its guest''s evaluation is over' }) }) -join '; '
        return (& $new 'Warning' ('{0} golden snapshot(s) in {1}, none usable ({2}); a redeploy builds T2.' -f $all.Count, $group, $why) ([ordered]@{ snapshots = $all.Count }) 'Prove a new capture with ./scripts/test-t2-golden.ps1 -Onboard, or, after the evaluation ends, build T2 fresh, do the setup-wizard step, and capture again.')
    }
    $chosen = $usable[0]
    $evidence = [ordered]@{
        snapshot           = $chosen.Name
        capturedUtc        = $chosen.CapturedUtc
        bootVerifiedUtc    = $chosen.BootVerifiedUtc
        onboardVerifiedUtc = $chosen.OnboardVerifiedUtc
        evalExpiresUtc     = $chosen.EvalExpiresUtc
        evalDaysLeft       = $chosen.EvalDaysLeft
        sizeGiB            = $chosen.SizeGiB
        usedGiB            = $chosen.UsedGiB
        snapshots          = $all.Count
    }
    $notes = [System.Collections.Generic.List[string]]::new()
    $status = 'Pass'
    if ($chosen.EvalDaysLeft -le 7) {
        $status = 'Warning'
        $notes.Add('re-capture now')
    }
    elseif ($chosen.EvalDaysLeft -le 30) {
        $status = 'Warning'
        $notes.Add('plan a fresh build and a new capture')
    }
    $expiresOn = [datetime]::MinValue
    if ($Config['expiresOn'] -and [datetime]::TryParseExact([string]$Config['expiresOn'], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$expiresOn) -and $null -ne $chosen.EvalExpiresUtc -and $expiresOn -gt $chosen.EvalExpiresUtc) {
        $status = 'Warning'
        $notes.Add(('the evaluation ends before the environment''s expiresOn ({0})' -f $Config['expiresOn']))
    }
    $message = '{0}: captured {1:yyyy-MM-dd}, boot-verified {2:yyyy-MM-dd}; its guest''s evaluation ends {3:yyyy-MM-dd}, in {4} days; about {5:N0} of {6} GiB used{7}.' -f $chosen.Name, $chosen.CapturedUtc, $chosen.BootVerifiedUtc, $chosen.EvalExpiresUtc, $chosen.EvalDaysLeft, $chosen.UsedGiB, $chosen.SizeGiB, $(if ($notes.Count) { ': ' + ($notes -join '; ') } else { '' })
    return (& $new $status $message $evidence $(if ($status -eq 'Warning') { 'Build T2 fresh (t2Source build), do the setup-wizard step, then ./scripts/capture-t2-golden.ps1 and ./scripts/test-t2-golden.ps1 -Onboard.' } else { '' }))
}

function Invoke-DemoGoldenSourceRelease {
    <#
    .SYNOPSIS
    Releases the air gap on the host a golden snapshot was captured from (ADR 0018, section 5, item 9). Returns
    T2.GOLDEN.SOURCE, or nothing when archost01 isn't a capture source that still needs it. Internal.

    .DESCRIPTION
    The capture leaves the source's guest disconnected (no network adapter, no automatic start), so the copy
    and the source never run connected at once. When archost01's Azure VM ID matches a golden snapshot's
    dbhubSourceVmId (in this resource group) and that snapshot doesn't carry dbhubSourceReleasedUtc yet, the
    guest is reconnected (vm/bootstrap/Invoke-DemoGoldenGuest.ps1 -Action Release: on the source, it only
    reconnects; the Arc identity is still its own), and the snapshot is tagged dbhubSourceReleasedUtc, so
    later starts skip it. start-demo.ps1 and deploy.ps1 (existing host) call it.

    Sources (checked 2026-10-22): https://learn.microsoft.com/cli/azure/vm#az-vm-show,
    https://learn.microsoft.com/cli/azure/tag#az-tag-update
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(60, 7200)]
        [int] $TimeoutSeconds = 1800
    )

    if ((Get-DemoHostVmName -Config $Config) -ne 'archost01') {
        return
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $vmRead = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $resourceGroupName, '--name', 'archost01', '--query', 'vmId', '--output', 'tsv') -AllowFailure
    $vmId = ([string]$vmRead.StdOut).Trim()
    if ($vmRead.ExitCode -ne 0 -or -not $vmId) {
        return
    }
    $sources = @(Get-DemoT2GoldenSnapshot -Config $Config | Where-Object { $_.SourceGroup -eq $resourceGroupName -and $_.SourceAzureVmId -eq $vmId -and $null -eq $_.SourceReleasedUtc })
    if ($sources.Count -eq 0) {
        return
    }
    $docUrl = 'https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct'
    Write-DemoLog -Message ('archost01 is the source of {0}; reconnecting its air-gapped guest.' -f (($sources | ForEach-Object { $_.Name }) -join ', '))
    $release = Invoke-DemoGoldenGuestAction -Config $Config -Action 'Release' -TimeoutSeconds $TimeoutSeconds
    $evidence = [ordered]@{
        snapshots = @($sources | ForEach-Object { $_.Name })
        seconds   = $release.Seconds
        role      = [string](Get-DemoMemberValue -InputObject $release.Data -Name 'role')
        captured  = Get-DemoMemberValue -InputObject $release.Data -Name 'captured'
    }
    if (-not $release.Succeeded) {
        return (New-DemoResult -CheckId 'T2.GOLDEN.SOURCE' -Area 't2' -Target 'T2' -Status 'Fail' -Message ('archost01 is a golden snapshot''s source, and its guest couldn''t be reconnected: {0}' -f $release.Error) -Evidence $evidence -Remediation 'Fix the cause and run start-demo.ps1 (or deploy.ps1) again; the release is safe to repeat.' -DocUrl $docUrl)
    }
    $names = Get-DemoGoldenTagName
    $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $untagged = [System.Collections.Generic.List[string]]::new()
    foreach ($snapshot in $sources) {
        $tagged = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('tag', 'update', '--resource-id', $snapshot.Id, '--operation', 'Merge', '--tags', ('{0}={1}' -f $names['SourceReleased'], $stamp)) -AllowFailure
        if ($tagged.ExitCode -ne 0) {
            $untagged.Add($snapshot.Name)
        }
    }
    $status = if ($untagged.Count -eq 0) { 'Pass' } else { 'Warning' }
    $message = 'archost01 is the source of {0}: its guest is reconnected and starts with the host again ({1:N0} seconds){2}.' -f ($evidence['snapshots'] -join ', '), $release.Seconds, $(if ($untagged.Count) { '; the release wasn''t recorded on {0}, so the next start checks again' -f ($untagged -join ', ') } else { '' })
    return (New-DemoResult -CheckId 'T2.GOLDEN.SOURCE' -Area 't2' -Target 'T2' -Status $status -Message $message -Evidence $evidence -DocUrl $docUrl)
}

function Invoke-DemoGoldenGuestAction {
    <#
    .SYNOPSIS
    Runs vm/bootstrap/Invoke-DemoGoldenGuest.ps1 on the T2 host in a managed Run Command and parses its last
    JSON line. Returns Succeeded, Data, Error, Seconds, and WhileRunningError (Invoke-DemoVmRunCommand
    -WhileRunning: deploy.ps1 sends archost01's artifacts while the Release runs). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('Inspect', 'Prepare', 'Release', 'RotateGuestPassword')]
        [string] $Action,

        [System.Collections.IDictionary] $Parameter = @{},

        [string] $ResourceGroupName = '',

        [ValidateRange(60, 7200)]
        [int] $TimeoutSeconds = 1800,

        [scriptblock] $WhileRunning = $null
    )

    $script = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/Invoke-DemoGoldenGuest.ps1') -Raw
    $values = @{ Action = $Action }
    foreach ($key in $Parameter.Keys) {
        $values[$key] = $Parameter[$key]
    }
    $arguments = @{
        Config              = $Config
        VmName              = 'archost01'
        RunCommandName      = 'DbHubDemo-Golden'
        Script              = $script
        Parameter           = $values
        TimeoutSeconds      = $TimeoutSeconds
        PollIntervalSeconds = 15
        Confirm             = $false
    }
    if ($ResourceGroupName) {
        $arguments['ResourceGroupName'] = $ResourceGroupName
    }
    if ($null -ne $WhileRunning) {
        $arguments['WhileRunning'] = $WhileRunning
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    # The watchdog never restarts the host while this runs on it (Restart-DemoVmOnce; review finding 6).
    $busyKey = '{0}/archost01' -f $(if ($ResourceGroupName) { $ResourceGroupName } else { Get-DemoResourceGroupName -Config $Config })
    $script:DemoHostAction[$busyKey] = $Action
    try {
        $run = Invoke-DemoVmRunCommand @arguments
    }
    catch {
        return [pscustomobject]@{ Succeeded = $false; Data = $null; Error = $_.Exception.Message; Seconds = [int]$watch.Elapsed.TotalSeconds; WhileRunningError = '' }
    }
    finally {
        $script:DemoHostAction.Remove($busyKey)
    }
    $data = $null
    if ($null -ne $run) {
        $data = ConvertFrom-DemoRunCommandOutput -Text ([string]$run.Output)
    }
    $succeeded = ($null -ne $run -and $run.Succeeded -and $null -ne $data -and [bool](Get-DemoMemberValue -InputObject $data -Name 'succeeded'))
    $errorText = ''
    if (-not $succeeded) {
        $errorText = [string](Get-DemoMemberValue -InputObject $data -Name 'error')
        if (-not $errorText -and $null -ne $run) {
            $errorText = if ($run.Error) { [string]$run.Error } else { 'execution state {0}, exit code {1}' -f $run.ExecutionState, $run.ExitCode }
        }
    }
    return [pscustomobject]@{ Succeeded = $succeeded; Data = $data; Error = (Protect-DemoText -Text $errorText); Seconds = [int]$watch.Elapsed.TotalSeconds; WhileRunningError = [string](Get-DemoMemberValue -InputObject $run -Name 'WhileRunningError') }
}
