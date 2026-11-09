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
        # A guest that isn't a Windows evaluation (the Jumpstart image's Windows Server 2022 Standard) is tagged 'none'.
        Evaluation          = ((& $tag 'EvalExpiresUtc') -ne 'none')
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
    without a data disk (the guest lives on the OS disk), and its guest's Windows evaluation isn't over (a
    JumpstartImage snapshot's guest isn't an evaluation, so that part doesn't apply to it).
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
        $makes = if ([string]$Config['t2SqlInstallMode'] -eq 'JumpstartImage') { 'makes its guest from Arc Jumpstart''s image' } else { 'builds its guest from the image, then waits for the setup-wizard step in PaygWizard mode' }
        return (& $decide 'build' 'Pass' ('t2Source is build: a new archost01 {0}.' -f $makes))
    }

    $hostSizing = (Get-DemoProfile).profiles[[string]$Config['profile']].t2Host
    $zone = if ($Config.Contains('zone') -and $Config['zone']) { [string]$Config['zone'] } else { '' }
    $hostDataDisk = Resolve-DemoDataDiskTier -VmSizing $hostSizing -Zone $zone -Override (Get-DemoDataDiskOverride -Config $Config)
    $installMode = [string]$Config['t2SqlInstallMode']
    # 2026-11-09: in JumpstartImage mode, a snapshot of a finished PaygWizard guest is kept as it is too, as an existing
    # finished guest is, with no setup wizard; one of the image is preferred. PaygWizard on purpose takes only its own.
    $modes = if ($installMode -eq 'JumpstartImage') { @('JumpstartImage', 'PaygWizard') } else { @($installMode) }
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
        if ($snapshot.InstallMode -notin $modes) { $why.Add(('install mode {0}' -f $snapshot.InstallMode)) }
        if ($snapshot.SecurityType -and $snapshot.SecurityType -ne $securityType) { $why.Add(('security type {0}' -f $snapshot.SecurityType)) }
        if ($hostDataDisk -ne 'None') { $why.Add(('the profile gives the host a {0} data disk' -f $hostDataDisk)) }
        if (-not (Test-DemoGoldenEvaluationOk -Snapshot $snapshot)) { $why.Add('its guest''s Windows evaluation is over') }
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
        $expired = @($snapshots | Where-Object { (Test-DemoGoldenIsEvaluation -Snapshot $_) -and $null -ne $_.EvalDaysLeft -and $_.EvalDaysLeft -lt 1 })
        $status = if ($expired.Count -gt 0) { 'Warning' } else { 'Pass' }
        $makes = if ($installMode -eq 'JumpstartImage') { 'makes its guest from Arc Jumpstart''s image' } else { 'builds its guest from the image, then waits for the setup-wizard step in PaygWizard mode' }
        return (& $decide 'build' $status ('No usable golden snapshot{0}: a new archost01 {1}.' -f $reasons, $makes) $evidence $(if ($expired.Count -gt 0) { 'After this build and the wizard, capture again: ./scripts/capture-t2-golden.ps1.' } else { '' }))
    }

    $chosen = @($usable | Where-Object { $_.InstallMode -eq $installMode }) + @($usable | Where-Object { $_.InstallMode -ne $installMode }) | Select-Object -First 1
    $evidence['snapshot'] = $chosen.Name
    $evidence['capturedUtc'] = $chosen.CapturedUtc
    $evidence['bootVerifiedUtc'] = $chosen.BootVerifiedUtc
    $evidence['onboardVerifiedUtc'] = $chosen.OnboardVerifiedUtc
    $evidence['evalExpiresUtc'] = $chosen.EvalExpiresUtc
    $evidence['evalDaysLeft'] = $chosen.EvalDaysLeft
    $notes = [System.Collections.Generic.List[string]]::new()
    $status = 'Pass'
    $isEvaluation = Test-DemoGoldenIsEvaluation -Snapshot $chosen
    if ($isEvaluation -and $chosen.EvalDaysLeft -le 7) {
        $status = 'Warning'
        $notes.Add(('its guest''s Windows evaluation ends in {0} days: re-capture now' -f $chosen.EvalDaysLeft))
    }
    elseif ($isEvaluation -and $chosen.EvalDaysLeft -le 30) {
        $status = 'Warning'
        $notes.Add(('its guest''s Windows evaluation ends in {0} days: re-capture after a fresh build' -f $chosen.EvalDaysLeft))
    }
    $expiresOn = [datetime]::MinValue
    if ($Config['expiresOn'] -and [datetime]::TryParseExact([string]$Config['expiresOn'], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$expiresOn) -and $null -ne $chosen.EvalExpiresUtc -and $expiresOn -gt $chosen.EvalExpiresUtc) {
        $status = 'Warning'
        $notes.Add(('the evaluation ends before the environment''s expiresOn ({0})' -f $Config['expiresOn']))
    }
    $lifetime = if ($isEvaluation) { 'its guest''s evaluation ends {0:yyyy-MM-dd}, in {1} days' -f $chosen.EvalExpiresUtc, $chosen.EvalDaysLeft } else { 'its guest isn''t a Windows evaluation' }
    $message = 'A new archost01 restores from {0} (captured {1:yyyy-MM-dd}, boot-verified {2:yyyy-MM-dd}; {3}){4}.' -f $chosen.Name, $chosen.CapturedUtc, $chosen.BootVerifiedUtc, $lifetime, $(if ($notes.Count) { ': ' + ($notes -join '; ') } else { '' })
    return (& $decide 'golden' $status $message $evidence $(if ($status -eq 'Warning') { 'Plan a fresh build (t2Source build), the setup-wizard step, and a new capture (capture-t2-golden.ps1, then test-t2-golden.ps1 -Onboard).' } else { '' }) $chosen)
}

function Test-DemoGoldenIsEvaluation {
    # True when a snapshot's guest is a Windows evaluation: its EvalExpiresUtc tag isn't 'none' (Evaluation true), or a
    # snapshot object from before 2026-11-05 without the Evaluation property, whose guests were all evaluations. Pure.
    # Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object] $Snapshot
    )

    $value = Get-DemoMemberValue -InputObject $Snapshot -Name 'Evaluation'
    return ($null -eq $value -or [bool]$value)
}

function Test-DemoGoldenEvaluationOk {
    # True when a snapshot's guest has time left: a Windows evaluation with at least a day left, or a guest that isn't an
    # evaluation (the Jumpstart image's Windows Server 2022 Standard, tagged 'none'). Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object] $Snapshot
    )

    if (-not (Test-DemoGoldenIsEvaluation -Snapshot $Snapshot)) {
        return $true
    }
    $days = Get-DemoMemberValue -InputObject $Snapshot -Name 'EvalDaysLeft'
    return ($null -ne $days -and [int]$days -ge 1)
}

function Get-DemoT2GoldenStatus {
    <#
    .SYNOPSIS
    STATUS.T2.GOLDEN for status.ps1 (ADR 0018, guardrail 2): the newest usable golden snapshot and how long its
    guest's Windows evaluation has left (an evaluation guest only). Internal.

    .DESCRIPTION
    Not selected without a snapshot (a redeploy builds T2). Warning when none is usable (not boot-verified,
    or its evaluation is over), at 30 days or less, at 7 days or less ("re-capture now"), and when the
    evaluation ends before the configuration's expiresOn. Otherwise Pass. A JumpstartImage snapshot's guest isn't an
    evaluation, so only boot verification counts for it.
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
    $usable = @($all | Where-Object { $null -ne $_.BootVerifiedUtc -and (Test-DemoGoldenEvaluationOk -Snapshot $_) })
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
    $isEvaluation = Test-DemoGoldenIsEvaluation -Snapshot $chosen
    if ($isEvaluation -and $chosen.EvalDaysLeft -le 7) {
        $status = 'Warning'
        $notes.Add('re-capture now')
    }
    elseif ($isEvaluation -and $chosen.EvalDaysLeft -le 30) {
        $status = 'Warning'
        $notes.Add('plan a fresh build and a new capture')
    }
    $expiresOn = [datetime]::MinValue
    if ($Config['expiresOn'] -and [datetime]::TryParseExact([string]$Config['expiresOn'], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$expiresOn) -and $null -ne $chosen.EvalExpiresUtc -and $expiresOn -gt $chosen.EvalExpiresUtc) {
        $status = 'Warning'
        $notes.Add(('the evaluation ends before the environment''s expiresOn ({0})' -f $Config['expiresOn']))
    }
    $lifetime = if ($isEvaluation) { 'its guest''s evaluation ends {0:yyyy-MM-dd}, in {1} days' -f $chosen.EvalExpiresUtc, $chosen.EvalDaysLeft } else { 'its guest isn''t a Windows evaluation' }
    $message = '{0}: captured {1:yyyy-MM-dd}, boot-verified {2:yyyy-MM-dd}; {3}; about {4:N0} of {5} GiB used{6}.' -f $chosen.Name, $chosen.CapturedUtc, $chosen.BootVerifiedUtc, $lifetime, $chosen.UsedGiB, $chosen.SizeGiB, $(if ($notes.Count) { ': ' + ($notes -join '; ') } else { '' })
    return (& $new $status $message $evidence $(if ($status -eq 'Warning') { 'Build T2 fresh (t2Source build), do the setup-wizard step, then ./scripts/capture-t2-golden.ps1 and ./scripts/test-t2-golden.ps1 -Onboard.' } else { '' }))
}

function Invoke-DemoGoldenSourceRelease {
    <#
    .SYNOPSIS
    Releases the air gap on the host a golden snapshot was captured from (ADR 0018, section 5, item 9). Returns
    T2.GOLDEN.SOURCE, or nothing when archost01 isn't a capture source that still needs it. Internal.

    .DESCRIPTION
    The capture leaves the source's guest disconnected (no network adapter, no automatic start) while it takes the
    snapshot, so the snapshot's copies boot air-gapped; since 2026-11-03 the capture itself releases its source right
    afterwards (Restore-DemoGoldenCaptureSource), and this is the safety net for a capture that was interrupted once
    its snapshot existed (before that, no snapshot names the host: the next capture releases it, or a Fabric start of T2
    once its marker no longer counts).
    When archost01's Azure VM ID matches a golden snapshot's
    dbhubSourceVmId (in this resource group) and that snapshot doesn't carry dbhubSourceReleasedUtc yet, the
    guest is reconnected (vm/bootstrap/Invoke-DemoGoldenGuest.ps1 -Action Release: on the source, it only
    reconnects; the Arc identity is still its own), and the snapshot is tagged dbhubSourceReleasedUtc, so
    later starts skip it. start-demo.ps1, deploy.ps1 (existing host), and the capture call it; a Fabric start of T2
    releases the source on the host itself (Invoke-DemoWorkloadControl.ps1), where it can't tag the snapshot, so a
    later call here releases again, which is harmless, and records it. -EndCapture is for the capture's own return
    of its source only: its Release removes the capture marker that Prepare wrote (2026-11-04). Any other call passes
    the snapshots it found (CapturedSnapshots): the Release ends a marker that names one of them, because that
    capture's snapshot exists, and refuses while any other marker counts on this host, which is a Warning here: the
    source stays air-gapped until its capture ends (review, 2026-11-04).

    Sources (checked 2026-10-22): https://learn.microsoft.com/cli/azure/vm#az-vm-show,
    https://learn.microsoft.com/cli/azure/tag#az-tag-update
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(60, 7200)]
        [int] $TimeoutSeconds = 1800,

        [switch] $EndCapture
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
    # The snapshots found go along: a capture marker that names one of them is over, because that snapshot exists, so
    # the Release ends it; any other marker that counts makes the Release refuse (review, 2026-11-04).
    $parameter = @{ CapturedSnapshots = (@($sources | ForEach-Object { $_.Name }) -join '+') }
    if ($EndCapture) {
        $parameter['EndCapture'] = 'true'
    }
    $release = Invoke-DemoGoldenGuestAction -Config $Config -Action 'Release' -Parameter $parameter -TimeoutSeconds $TimeoutSeconds
    $evidence = [ordered]@{
        snapshots    = @($sources | ForEach-Object { $_.Name })
        seconds      = $release.Seconds
        role         = [string](Get-DemoMemberValue -InputObject $release.Data -Name 'role')
        captured     = Get-DemoMemberValue -InputObject $release.Data -Name 'captured'
        captureEnded = [string](Get-DemoMemberValue -InputObject $release.Data -Name 'captureEnded')
    }
    if (-not $release.Succeeded -and [string]$release.Error -match '(?i)golden capture is in progress on this host|golden capture marker on this host') {
        $evidence['captureInProgress'] = $true
        return (New-DemoResult -CheckId 'T2.GOLDEN.SOURCE' -Area 't2' -Target 'T2' -Status 'Warning' -Message ('archost01 is the source of {0}, and its guest stays air-gapped: {1}' -f ($evidence['snapshots'] -join ', '), $release.Error) -Evidence $evidence -Remediation 'Let ./scripts/capture-t2-golden.ps1 finish: its return of the source releases it. If no capture runs (one was interrupted), run ./scripts/capture-t2-golden.ps1 again, which ends its marker and releases the source first; this release ends the marker too once that capture''s snapshot exists.' -DocUrl $docUrl)
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

function Restore-DemoGoldenCaptureSource {
    <#
    .SYNOPSIS
    Returns a capture's source to service once its guest has been air-gapped (ADR 0018, section 4, item 9, as
    amended 2026-11-03), so no Fabric start ever finds T2 cut off. New-DemoT2GoldenSnapshot calls it after Prepare,
    whatever happens next. Returns GOLDEN.CAPTURE.SOURCE. Internal.

    .DESCRIPTION
    1. archost01 started when it isn't running (the capture deallocates it for the snapshot).
    2. The release: Invoke-DemoGoldenSourceRelease when a golden snapshot names this host as its unreleased source (it
       also tags dbhubSourceReleasedUtc, so later starts skip it); otherwise, when the capture stopped before its
       snapshot, vm/bootstrap/Invoke-DemoGoldenGuest.ps1 -Action Release. Either way the host's own Azure VM ID
       decides its role, so only a source is released this way: its guest's adapter is reconnected, its automatic
       start set to Start, and the guest started. Both pass EndCapture, so the Release first removes the capture
       marker that Prepare wrote: the capture is over, and T2's control relay may act on the guest again.
    3. arcsql01 Connected, through Azure Resource Manager, at most -ArcWaitMinutes. A machine that misses its
       heartbeats turns Disconnected within 15 to 30 minutes, so Connected right after the air gap may be left over
       from before it. Connected counts once its lastStatusChange is later than the air gap (it reconnected), or 30
       minutes after the air gap (only a heartbeat since then keeps it Connected), or at once when the release found
       the guest's adapter connected (there was no air gap).
    4. The host returned to the power state the capture found: deallocated again, after a clean guest shutdown
       (STOP.GUEST, never by force) when it was deallocated or stopped; left running otherwise.
    Pass when all of that holds; Warning when the release wasn't recorded on the snapshot, Connected can't be told
    from a left-over status yet, or the host couldn't be returned; Fail when the guest stays air-gapped or arcsql01
    doesn't reconnect.
    Source: https://learn.microsoft.com/azure/azure-arc/servers/overview#agent-status (checked 2026-11-03).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $FoundPowerState = '',

        [Parameter(Mandatory)]
        [datetime] $AirGapUtc,

        [ValidateRange(0, 60)]
        [int] $ArcWaitMinutes = 30,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 30
    )

    $docUrl = 'https://learn.microsoft.com/azure/azure-arc/servers/overview#agent-status'
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $evidence = [ordered]@{ foundPowerState = $FoundPowerState; airGapUtc = $AirGapUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture); hostStarted = $false; release = ''; releaseStatus = ''; arcStatus = ''; arcLastStatusChange = ''; arcProof = ''; arcSeconds = 0; hostAfter = '' }
    $retry = 'Run ./scripts/capture-t2-golden.ps1 again: its first step ends this capture''s marker and releases the source. ./scripts/start-demo.ps1 releases it too once this capture''s snapshot exists (T2.GOLDEN.SOURCE ends the marker then), and so does a start of T2 from the Fabric control once no capture marker holds it back (6 hours at most). Each is safe to repeat.'
    $new = { param([string] $Status, [string] $Message, [string] $Remediation = '') New-DemoResult -CheckId 'GOLDEN.CAPTURE.SOURCE' -Area 't2' -Target 'T2' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $docUrl }

    # 1. The host.
    if ((Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName 'archost01') -ne 'PowerState/running') {
        $start = Invoke-DemoVmPowerAction -Config $Config -VmName 'archost01' -Action Start
        $evidence['hostStarted'] = $start.status -eq 'Pass'
        if ($start.status -ne 'Pass') {
            return (& $new 'Fail' ('archost01 didn''t start, so the source''s guest stays air-gapped: {0}' -f $start.message) $retry)
        }
    }

    # 2 and 3: the release, as a source only, then arcsql01 Connected as the release made it, not as it was before
    # the air gap. Their outcome waits for the host's power state (4).
    $waitMinutes = $ArcWaitMinutes
    $pollEvery = $PollSeconds
    $releaseAndVerify = {
        $airGapped = $true
        $released = Invoke-DemoGoldenSourceRelease -Config $Config -EndCapture
        if ($null -ne $released) {
            $evidence['release'] = 'T2.GOLDEN.SOURCE'
            $evidence['releaseStatus'] = [string]$released.status
            if ($released.status -eq 'Fail') {
                return [pscustomobject]@{ Status = 'Fail'; Message = ('The source''s guest stays air-gapped: {0}' -f $released.message); Remediation = $retry }
            }
        }
        else {
            $guest = Invoke-DemoGoldenGuestAction -Config $Config -Action 'Release' -Parameter @{ EndCapture = 'true' } -TimeoutSeconds 1800
            $evidence['release'] = 'Release'
            $evidence['releaseStatus'] = if ($guest.Succeeded) { 'Pass' } else { 'Fail' }
            $evidence['role'] = [string](Get-DemoMemberValue -InputObject $guest.Data -Name 'role')
            if (-not $guest.Succeeded) {
                return [pscustomobject]@{ Status = 'Fail'; Message = ('The source''s guest stays air-gapped: {0}' -f $guest.Error); Remediation = $retry }
            }
            $before = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $guest.Data -Name 'before') -Name 'adapter'
            if ($null -ne $before -and [int](Get-DemoMemberValue -InputObject $before -Name 'count') -gt 0 -and [int](Get-DemoMemberValue -InputObject $before -Name 'connected') -ge [int](Get-DemoMemberValue -InputObject $before -Name 'count')) {
                $airGapped = $false
            }
        }
        $evidence['airGapped'] = $airGapped
        $releaseNote = if ($evidence['releaseStatus'] -eq 'Warning') { ' The release wasn''t recorded on the snapshot, so the next start-demo.ps1 releases it again, which is harmless.' } else { '' }

        $target = Get-DemoArcTarget -Config $Config
        $decayUtc = $AirGapUtc.AddMinutes(30)
        $started = Get-DemoUtcNow
        $deadline = $started.AddMinutes($waitMinutes)
        $readError = ''
        $machine = $null
        $status = ''
        while ($true) {
            $now = Get-DemoUtcNow
            $machine = $null
            try {
                $machine = Get-DemoArcArmResource -SubscriptionId $target.SubscriptionId -Url $target.MachineUrl
                $readError = ''
            }
            catch {
                $readError = Protect-DemoText -Text $_.Exception.Message
            }
            $properties = Get-DemoMemberValue -InputObject $machine -Name 'properties'
            $status = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
            $changed = ConvertTo-DemoUtcDate -Value (Get-DemoMemberValue -InputObject $properties -Name 'lastStatusChange')
            $evidence['arcStatus'] = $status
            $evidence['arcLastStatusChange'] = if ($null -ne $changed) { $changed.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
            $evidence['arcSeconds'] = [int]($now - $started).TotalSeconds
            if ($status -eq 'Connected') {
                if (-not $airGapped) {
                    $evidence['arcProof'] = 'never disconnected'
                }
                elseif ($null -ne $changed -and $changed -gt $AirGapUtc) {
                    $evidence['arcProof'] = 'reconnected'
                }
                elseif ($now -ge $decayUtc) {
                    $evidence['arcProof'] = 'heartbeat'
                }
                if ($evidence['arcProof']) {
                    break
                }
            }
            if ($now -ge $deadline) {
                break
            }
            Start-Sleep -Seconds $pollEvery
        }
        if ($evidence['arcProof']) {
            $how = @{ 'reconnected' = 'it reconnected after the air gap'; 'heartbeat' = 'still Connected 30 minutes after the air gap, so it heartbeats again'; 'never disconnected' = 'its guest was never disconnected' }[$evidence['arcProof']]
            return [pscustomobject]@{ Status = $(if ($releaseNote) { 'Warning' } else { 'Pass' }); Message = ('The capture''s source is back in service: its guest is reconnected and starts with the host, and arcsql01 is Connected ({0}, after {1:N0} seconds).{2}' -f $how, $evidence['arcSeconds'], $releaseNote); Remediation = '' }
        }
        if ($status -eq 'Connected') {
            return [pscustomobject]@{ Status = 'Warning'; Message = ('The capture''s source is released, but arcsql01''s Connected status may still be the one from before the air gap (Azure marks a machine Disconnected within 15 to 30 minutes without heartbeats).{0}' -f $releaseNote); Remediation = ('With the demo running, read T2.ARC.CONNECTED again after {0:yyyy-MM-dd HH:mm} UTC: ./scripts/status.ps1.' -f $decayUtc) }
        }
        $seen = if ($readError) { 'couldn''t be read ({0})' -f $readError } elseif ($null -eq $machine) { 'doesn''t exist' } else { 'is {0}' -f $(if ($status) { $status } else { 'without a status' }) }
        return [pscustomobject]@{ Status = 'Fail'; Message = ('The capture''s source is released (its guest reconnected and started), but arcsql01 {0} after {1} minutes.' -f $seen, $waitMinutes); Remediation = 'Run ./scripts/start-demo.ps1, then ./scripts/validate.ps1 -Area T2: T2.ARC.CONNECTED says what to do (azcmagent check in the guest, then configure-arc.ps1 -Force).' }
    }
    $outcome = & $releaseAndVerify

    # 4. The host as the capture found it, whatever the outcome: deallocated again after a clean guest shutdown.
    $evidence['hostAfter'] = 'running'
    $hostText = ' archost01 keeps running, as the capture found it.'
    if ($FoundPowerState -in 'PowerState/deallocated', 'PowerState/deallocating', 'PowerState/stopped', 'PowerState/stopping') {
        $guestStop = Stop-DemoGuestVm -Config $Config -Confirm:$false
        $evidence['guestStop'] = [string]$guestStop.status
        $deallocate = Invoke-DemoVmPowerAction -Config $Config -VmName 'archost01' -Action Deallocate
        if ($deallocate.status -eq 'Pass') {
            $evidence['hostAfter'] = 'deallocated'
            $hostText = ' archost01 is deallocated again, as the capture found it.'
        }
        else {
            $hostText = ' archost01 couldn''t be deallocated again: {0}' -f $deallocate.message
            if ($outcome.Status -eq 'Pass') {
                $outcome.Status = 'Warning'
                $outcome.Remediation = 'Run ./scripts/stop-demo.ps1 to deallocate it.'
            }
        }
    }
    return (& $new $outcome.Status ($outcome.Message + $hostText) $outcome.Remediation)
}

function Get-DemoT2GuestStateResult {
    <#
    .SYNOPSIS
    T2.GUEST.STATE for status.ps1 and validate.ps1 while archost01 runs (2026-11-03): whether the nested guest can be in
    Database Hub, from the host's live read (the t2Guest part of Get-DemoVmHealth). $null when there's nothing to
    read (no Hyper-V host, as in the evaluation-only mode). Internal and pure.

    .DESCRIPTION
    Live, 2026-11-03: a golden capture had left the source's guest air-gapped (off, automatic start Nothing, adapter
    disconnected) for six days, and nothing said so. Statuses (ADR 0012):
    - Fail when T2 can't be in Database Hub while its host runs: a golden capture record that isn't released (the
      source: a Fabric start of T2 releases it, and so do start-demo.ps1 once a snapshot names the host and the next
      capture; a copy: deploy.ps1 resets it, and it's never connected by hand while it may hold the captured
      identity), a copy whose record says released without a reset (2026-11-04: it may hold the captured identity),
      the guest off, or its adapter not connected to the NAT switch.
    - Warning while a golden capture is in progress on this host (the marker Prepare writes, for 6 hours at most), or
      while a marker can't be read (it fails closed): the guest is off and air-gapped on purpose, and a Fabric start of
      T2 is refused until the capture ends (review, 2026-11-04). Also when it works now but won't after the next start (an automatic start action other than
      Start), or its heartbeat isn't OK yet (it may still be booting), or the host couldn't be read or tell its role.
    - Not selected while the host's build hasn't created the guest yet; Pass otherwise.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Health
    )

    $guest = Get-DemoMemberValue -InputObject $Health -Name 't2Guest'
    if ($null -eq $guest -or (Get-DemoHostVmName -Config $Config) -ne 'archost01') {
        return $null
    }
    $guestName = [string](Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/dsc/guest.psd1')).Name
    $switchName = [string](Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/dsc/host.psd1')).SwitchName
    $docUrl = 'https://learn.microsoft.com/powershell/module/hyper-v/connect-vmnetworkadapter'
    $golden = Get-DemoMemberValue -InputObject $guest -Name 'golden'
    $evidence = [ordered]@{
        guest       = $guestName
        present     = [bool](Get-DemoMemberValue -InputObject $guest -Name 'present')
        state       = [string](Get-DemoMemberValue -InputObject $guest -Name 'state')
        heartbeat   = [string](Get-DemoMemberValue -InputObject $guest -Name 'heartbeat')
        startAction = [string](Get-DemoMemberValue -InputObject $guest -Name 'startAction')
        adapters    = [int](Get-DemoMemberValue -InputObject $guest -Name 'adapters')
        connected   = [int](Get-DemoMemberValue -InputObject $guest -Name 'connected')
        golden      = $(if ($null -ne $golden) { [ordered]@{ released = [bool](Get-DemoMemberValue -InputObject $golden -Name 'released'); reset = [bool](Get-DemoMemberValue -InputObject $golden -Name 'reset'); role = [string](Get-DemoMemberValue -InputObject $golden -Name 'role') } } else { $null })
    }
    $new = { param([string] $Status, [string] $Message, [string] $Remediation = '') New-DemoResult -CheckId 'T2.GUEST.STATE' -Area 't2' -Target 'T2' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $docUrl }
    $readError = [string](Get-DemoMemberValue -InputObject $guest -Name 'error')
    if ($readError) {
        return (& $new 'Warning' ('archost01 couldn''t read its guest {0}: {1}' -f $guestName, (Protect-DemoText -Text $readError)) 'Run status.ps1 again in a few minutes.')
    }
    $capture = Get-DemoMemberValue -InputObject $guest -Name 'capture'
    $captureState = [string](Get-DemoMemberValue -InputObject $capture -Name 'state')
    if ($captureState -eq 'Unreadable') {
        $evidence['capture'] = [ordered]@{ state = $captureState; snapshotName = [string](Get-DemoMemberValue -InputObject $capture -Name 'snapshotName') }
        return (& $new 'Warning' ('A golden capture marker on archost01 can''t be read, and only a capture writes it, so {0} is left as it is: the Fabric control and every release but the capture''s own leave it alone (2026-11-04).' -f $guestName) 'Run ./scripts/capture-t2-golden.ps1 again: its first step ends the marker and releases the source. ./scripts/start-demo.ps1 ends it too once that capture''s snapshot exists.')
    }
    if ($captureState -in 'Active', 'Unknown') {
        # The health read's JSON may turn its ISO times into dates: one format for both.
        $time = {
            param([object] $Value)
            $moment = ConvertTo-DemoUtcDateTime -Value $Value
            if ($null -eq $moment) { return [string]$Value }
            return $moment.ToString("yyyy-MM-dd HH:mm 'UTC'", [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $evidence['capture'] = [ordered]@{ state = $captureState; snapshotName = [string](Get-DemoMemberValue -InputObject $capture -Name 'snapshotName'); sinceUtc = (& $time (Get-DemoMemberValue -InputObject $capture -Name 'sinceUtc')); untilUtc = (& $time (Get-DemoMemberValue -InputObject $capture -Name 'untilUtc')) }
        $where = if ($captureState -eq 'Active') { 'on archost01' } else { 'on archost01 (its marker is recent, and archost01''s Azure VM ID couldn''t be read to confirm it''s the host the marker names)' }
        return (& $new 'Warning' ('A golden capture is in progress {0}: snapshot {1}, since {2}. {3} stays off and air-gapped until the capture returns its source to service (GOLDEN.CAPTURE.SOURCE), and a start of T2 from the Fabric control is refused meanwhile.' -f $where, $evidence['capture']['snapshotName'], $evidence['capture']['sinceUtc'], $guestName) ('Let ./scripts/capture-t2-golden.ps1 finish. If no capture runs (one was interrupted), run ./scripts/capture-t2-golden.ps1 again: it ends the marker and releases the source before anything else; ./scripts/start-demo.ps1 does too once that capture''s snapshot exists. From {0} the marker no longer holds a Fabric start back, and that start releases the source too.' -f $evidence['capture']['untilUtc']))
    }
    $seen = '{0}, automatic start {1}, {2} of {3} adapter(s) connected' -f $(if ($evidence['state']) { $evidence['state'] } else { 'in no state' }), $(if ($evidence['startAction']) { $evidence['startAction'] } else { 'unknown' }), $evidence['connected'], $evidence['adapters']
    if (-not $evidence['present']) {
        $hostState = [string](Get-DemoMemberValue -InputObject $Health -Name 'state')
        if ($hostState -eq 'Ready') {
            return (& $new 'Fail' ('archost01 is Ready, but its guest {0} doesn''t exist, so T2 can''t be in Database Hub.' -f $guestName) 'Run ./scripts/deploy.ps1 -Resume: archost01''s bootstrap creates the guest again.')
        }
        return (& $new 'Not selected' ('The guest {0} doesn''t exist yet: archost01''s bootstrap is {1}{2}.' -f $guestName, $(if ($hostState) { $hostState } else { 'starting' }), $(if ([string](Get-DemoMemberValue -InputObject $Health -Name 'currentStep')) { ' at {0}' -f (Get-DemoMemberValue -InputObject $Health -Name 'currentStep') } else { '' })))
    }
    $fabricStart = 'a start of T2 from the Fabric control (NB_DatabaseHub_Control)'
    if ($null -ne $golden -and -not $evidence['golden']['released']) {
        switch ($evidence['golden']['role']) {
            'Source' {
                return (& $new 'Fail' ('{0} is still air-gapped by a golden capture ({1}): T2 is missing from Database Hub until its source is released.' -f $guestName, $seen) 'Start T2 from the Fabric control (NB_DatabaseHub_Control): archost01 releases its source itself. ./scripts/start-demo.ps1 releases it too (T2.GOLDEN.SOURCE) once a golden snapshot names archost01 as its source; a capture stopped before its snapshot is released by the next ./scripts/capture-t2-golden.ps1. The release only reconnects the guest and restores its automatic start, because its Arc identity is its own.')
            }
            'Copy' {
                if ($evidence['golden']['reset']) {
                    return (& $new 'Fail' ('{0} is a copy restored from a golden snapshot whose Arc identity was reset, but it isn''t released yet ({1}).' -f $guestName, $seen) ('Run ./scripts/deploy.ps1 (its T2 track releases it and onboards it), or {0}.' -f $fabricStart))
                }
                return (& $new 'Fail' ('{0} is a copy restored from a golden snapshot that hasn''t been reset yet ({1}); it may still hold the captured Arc identity, so it must stay air-gapped.' -f $guestName, $seen) 'Run ./scripts/deploy.ps1: its T2 track resets the copy while it''s air-gapped, then connects and onboards it. Don''t connect it by hand.')
            }
            default {
                return (& $new 'Fail' ('{0} carries a golden capture record that isn''t released, and archost01''s Azure VM ID couldn''t be read, so it can''t tell a source from a copy ({1}).' -f $guestName, $seen) 'Run ./scripts/deploy.ps1: its T2 track decides and releases or resets it. Don''t connect the guest by hand.')
            }
        }
    }
    if ($null -ne $golden -and $evidence['golden']['released'] -and -not $evidence['golden']['reset']) {
        # Only the capture's source may carry a released record without a reset (review, 2026-11-04).
        switch ($evidence['golden']['role']) {
            'Copy' {
                return (& $new 'Fail' ('{0} runs on a copy restored from a golden snapshot whose record says released, but its Arc identity was never reset, so it may hold the captured identity ({1}); the Fabric control won''t use it.' -f $guestName, $seen) 'Run ./scripts/deploy.ps1: its T2 track resets the restored copy. Don''t start or connect the guest by hand.')
            }
            'Unknown' {
                return (& $new 'Warning' ('archost01''s Azure VM ID couldn''t be read, so its released golden record can''t be told from a copy''s that was never reset ({0}); the Fabric control leaves {1} alone until it can.' -f $seen, $guestName) 'Run status.ps1 again in a few minutes; if it persists, run ./scripts/deploy.ps1.')
            }
        }
    }
    $connect = 'az vm run-command invoke --subscription {0} --resource-group {1} --name archost01 --command-id RunPowerShellScript --scripts ''Connect-VMNetworkAdapter -VMName {2} -SwitchName {3}; Set-VM -Name {2} -AutomaticStartAction Start -AutomaticStartDelay 0; Start-VM -Name {2}''' -f [string]$Config['subscriptionId'], (Get-DemoResourceGroupName -Config $Config), $guestName, $switchName
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($evidence['adapters'] -eq 0 -or $evidence['connected'] -lt $evidence['adapters']) {
        $problems.Add(('its network adapter isn''t connected to {0}, so it can''t reach Azure' -f $switchName))
    }
    if ($evidence['state'] -ne 'Running') {
        $problems.Add(('it''s {0}' -f $(if ($evidence['state']) { $evidence['state'] } else { 'in no state' })))
    }
    if ($problems.Count -gt 0) {
        $fix = if ($evidence['connected'] -lt $evidence['adapters'] -or $evidence['adapters'] -eq 0) { 'Connect, set, and start it on archost01: {0}' -f $connect } else { 'Use {0}, which starts an off guest and sets its automatic start, or run on archost01: {1}' -f $fabricStart, $connect }
        return (& $new 'Fail' ('{0} can''t be in Database Hub while archost01 runs: {1} ({2}).' -f $guestName, ($problems -join '; '), $seen) $fix)
    }
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($evidence['startAction'] -ne 'Start') {
        $notes.Add(('it doesn''t start with the host (automatic start action {0}), so the next start finds it off' -f $(if ($evidence['startAction']) { $evidence['startAction'] } else { 'unknown' })))
    }
    if ($evidence['heartbeat'] -notlike 'Ok*') {
        $notes.Add(('its heartbeat is {0}; it may still be booting' -f $(if ($evidence['heartbeat']) { $evidence['heartbeat'] } else { 'not reported' })))
    }
    if ($notes.Count -gt 0) {
        $fix = if ($evidence['startAction'] -ne 'Start') { 'Set it on archost01 (deploy.ps1 -Resume does too): {0}' -f $connect } else { 'Run status.ps1 again in a few minutes.' }
        return (& $new 'Warning' ('{0} runs, but {1}.' -f $guestName, ($notes -join '; ')) $fix)
    }
    return (& $new 'Pass' ('{0} runs with its heartbeat OK, starts with the host, and its adapter is connected to {1}.' -f $guestName, $switchName))
}

function Get-DemoGoldenCaptureControlResult {
    <#
    .SYNOPSIS
    GOLDEN.CAPTURE.CONTROL: capture-t2-golden.ps1 runs only while no on-demand run is active (review, 2026-11-04). A run
    from the Fabric control starts archost01 and dispatches T2, and its auto-stop deallocates archost01, which would cut
    into the capture or its return of the source. Internal.
    https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account
    https://learn.microsoft.com/rest/api/automation/schedule/get

    .DESCRIPTION
    - Not selected when the control is off (control.enabled false).
    - Fail, and nothing is captured, while a DbHub-Control or DbHub-Stop job is queued or running, while the auto-stop
      dbhub-autostop is pending (its time hasn't come), or when either can't be read.
    - Pass otherwise, also when the control's Automation account doesn't exist.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $docUrl = 'https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account'
    $new = { param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '') New-DemoResult -CheckId 'GOLDEN.CAPTURE.CONTROL' -Area 't2' -Target 'T2' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl }
    if (-not (Get-DemoActivityControlSetting -Config $Config).Enabled) {
        return (& $new 'Not selected' 'The on-demand activity control is off (control.enabled is false), so no run from Fabric can start or stop archost01 during the capture.')
    }
    $name = Get-DemoActivityControlName -Config $Config
    $wait = 'Nothing was captured. Wait until the run has ended, or end it now (Stop now in {0}, or ./scripts/stop-demo.ps1), then run capture-t2-golden.ps1 again.' -f $name.Notebook
    $evidence = [ordered]@{ jobs = @(); autoStopUtc = '' }
    foreach ($runbook in $name.ControlRunbook, $name.StopRunbook) {
        $jobs = Get-DemoActivityControlActiveJob -Name $name -Runbook $runbook
        if (-not $jobs.Ok) {
            return (& $new 'Fail' ('The on-demand control''s {0} jobs couldn''t be read ({1}), so a run may be active. Nothing was captured.' -f $runbook, $jobs.Error) $evidence 'Run capture-t2-golden.ps1 again; ./scripts/status.ps1 shows the control (STATUS.CONTROL).')
        }
        foreach ($job in @($jobs.Jobs)) {
            $evidence['jobs'] += ('{0} {1} {2}' -f $runbook, $job.Id, $job.Status)
        }
    }
    if (@($evidence['jobs']).Count -gt 0) {
        return (& $new 'Fail' ('An on-demand run is starting or stopping now ({0}): it starts or deallocates archost01, which would cut into the capture.' -f (@($evidence['jobs']) -join '; ')) $evidence $wait)
    }
    $version = '2024-10-23'
    $schedule = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/schedules/{1}' -f $name.AutomationAccountId, $name.AutoStopSchedule) -ApiVersion $version)
    if (-not $schedule.Ok -and -not $schedule.Missing) {
        return (& $new 'Fail' ('The on-demand auto-stop {0} couldn''t be read ({1}), so a run may be active. Nothing was captured.' -f $name.AutoStopSchedule, $schedule.Error) $evidence 'Run capture-t2-golden.ps1 again; ./scripts/status.ps1 shows the control (STATUS.CONTROL).')
    }
    if ($schedule.Ok) {
        $stopUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $schedule.Value -Name 'properties') -Name 'startTime')
        if ($null -ne $stopUtc -and $stopUtc -gt $NowUtc.ToUniversalTime()) {
            $evidence['autoStopUtc'] = $stopUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            return (& $new 'Fail' ('An on-demand run is active until {0:yyyy-MM-dd HH:mm} UTC: its auto-stop ({1}) deallocates archost01 then, which would cut into the capture, and its start of T2 waits for the capture.' -f $stopUtc, $name.AutoStopSchedule) $evidence $wait)
        }
    }
    return (& $new 'Pass' ('No on-demand run is active: no {0} or {1} job is queued or running, and no auto-stop is pending.' -f $name.ControlRunbook, $name.StopRunbook) $evidence)
}
