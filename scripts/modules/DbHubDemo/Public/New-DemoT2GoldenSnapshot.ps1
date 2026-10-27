function New-DemoT2GoldenSnapshot {
    <#
    .SYNOPSIS
    Captures the T2 host's OS disk as a golden snapshot in rg-<prefix>-golden (ADR 0018, guardrails 2, 4,
    and 5). capture-t2-golden.ps1 calls it.

    .DESCRIPTION
    1. The subscription guard. The nested T2 mode with PaygWizard, and a host without data disks (the guest
       lives on the OS disk); anything else is Not supported.
    2. Policy: the read-only inventory must not deny snapshots or disks (unless -SkipPolicyInventory).
    3. Starts archost01 when it's deallocated, and releases an air gap that an interrupted capture left (the
       host's Azure VM ID matches the capture record, so only the guest's network and start action return).
    4. Inspects the host and guest (vm/bootstrap/Invoke-DemoGoldenGuest.ps1 -Action Inspect, read-only) and
       checks: the host's health is Ready, no SQL Server product key file, SQL Server Standard running, the
       guest's Arc agent connected to this environment's arcsql01, and the guest's Windows evaluation more
       than 7 days from its end (a Warning within 30 days).
    5. Turns T2's activity profile off and rotates the host administrator's password to a value nobody keeps.
       Then the sign-in data gate (ADR 0009): vm/bootstrap/Invoke-DemoSignInResidue.ps1 removes the sign-in data
       left on the host and in the guest and scans again; anything left (GOLDEN.CAPTURE.SIGNIN Fail, or Manual
       action required for the Security log, which only an operator clears) means nothing is captured.
       With -WipeFreeSpace (ADR 0009, Phase 26d), vm/bootstrap/Invoke-DemoDiskWipe.ps1 -WipeAction GuestFill then
       checks that the host's C: has at least -MinHostFreeGB free, runs the TRIM pass in the guest, overwrites the
       guest's free space with zeros, deletes that file, and trims again (GOLDEN.CAPTURE.WIPE).
    6. Prepare: removes the sign-in data that setup leaves on the VM again and checks that none remains, turns IE
       ESC on, writes the capture record, applies the air gap (the guest's automatic start action Nothing, its
       network adapter disconnected), and shuts the guest down cleanly. With -WipeFreeSpace, HostCompact then
       compacts the guest's VHDX (Optimize-VHD -Mode Full, mounted read-only), overwrites the host's free space
       with zeros, deletes that file, and trims the host's volume, so the snapshot keeps none of the zeroed
       blocks (GOLDEN.CAPTURE.COMPACT). Either failing means nothing is captured.
    7. Deallocates the host, creates rg-<prefix>-golden when missing (standard tags, no deploymentId), then an
       incremental snapshot of archost01-osdisk with network access DenyAll and public network access off,
       tagged with its lifetime and provenance.
    8. Creates a disk from it in the golden group (DenyAll), deletes it, and tags the snapshot disk-verified.
       Older snapshots stay until the new one is boot-verified (test-t2-golden.ps1).

    The air gap stays on the source host until the next start-demo.ps1 or deploy.ps1 releases it. Nothing is
    deleted. -WhatIf runs steps 1 and 2 only.

    Sources (checked 2026-10-21):
    - az snapshot create: https://learn.microsoft.com/cli/azure/snapshot#az-snapshot-create
    - Incremental snapshots: https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots
    - Restrict export (NetworkAccessPolicy): https://learn.microsoft.com/azure/virtual-machines/disks-restrict-import-export-overview
    - az disk create: https://learn.microsoft.com/cli/azure/disk#az-disk-create

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER SkipPolicyInventory
    Skip the policy inventory (the snapshot's creation still fails on a deny).

    .PARAMETER HostReadyMinutes
    How long to wait for the started host and its guest to report Ready.

    .PARAMETER WipeFreeSpace
    Overwrite the guest's and the host's free space with zeros and compact the guest's disk before the
    snapshot (about an hour more on the lowest-cost host).

    .PARAMETER MinHostFreeGB
    With -WipeFreeSpace, the free space the host's C: needs first, because filling the guest's free space grows
    its dynamic VHDX toward its maximum size.

    .PARAMETER NowUtc
    The capture time, for the snapshot's name and tags.

    .EXAMPLE
    New-DemoT2GoldenSnapshot -Config $config -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $SkipPolicyInventory,

        [ValidateRange(0, 60)]
        [int] $HostReadyMinutes = 20,

        [switch] $WipeFreeSpace,

        [ValidateRange(10, 1000)]
        [int] $MinHostFreeGB = 45,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots'
    # One confirmation for the whole capture, asked first. Nested commands then run without prompting, and the
    # read-only steps run under -WhatIf too (the guard must record its context).
    $proceed = $PSCmdlet.ShouldProcess((Get-DemoGoldenResourceGroupName -Config $Config), 'Start archost01, clean and air-gap its guest, rotate the host password, deallocate it, and snapshot archost01-osdisk')
    $WhatIfPreference = $false
    $ConfirmPreference = 'None'
    $add = {
        param([string] $CheckId, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '')
        $results.Add((New-DemoResult -CheckId $CheckId -Area 't2' -Target 'T2' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl))
    }
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing was captured. Sign in yourself and run capture-t2-golden.ps1 again.'))
        return $results.ToArray()
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $goldenGroup = Get-DemoGoldenResourceGroupName -Config $Config
    $location = [string]$Config['location']

    # 1. What can be captured.
    if ((Get-DemoHostVmName -Config $Config) -ne 'archost01') {
        & $add 'GOLDEN.CAPTURE.MODE' 'Not supported' 'The evaluation-only T2 is an Azure VM, not a nested guest; golden snapshots keep a nested guest''s setup-wizard state.'
        return $results.ToArray()
    }
    if ([string]$Config['t2SqlInstallMode'] -ne 'PaygWizard') {
        & $add 'GOLDEN.CAPTURE.MODE' 'Not supported' ('Golden snapshots keep the PaygWizard setup-wizard state; t2SqlInstallMode is {0}, which installs unattended on every build.' -f $Config['t2SqlInstallMode'])
        return $results.ToArray()
    }
    $vm = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $resourceGroupName, '--name', 'archost01') -AsJson -AllowFailure
    if ($null -eq $vm) {
        & $add 'GOLDEN.CAPTURE.HOST' 'Fail' ('archost01 wasn''t found in {0}.' -f $resourceGroupName) @{} 'Deploy T2 first (deploy.ps1), finish the setup-wizard step, then capture.'
        return $results.ToArray()
    }
    $storage = Get-DemoMemberValue -InputObject $vm -Name 'storageProfile'
    $osDisk = Get-DemoMemberValue -InputObject $storage -Name 'osDisk'
    $osDiskId = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $osDisk -Name 'managedDisk') -Name 'id')
    # Get-DemoMemberValue keeps an array intact, so it's unrolled from a variable.
    $dataDiskValue = Get-DemoMemberValue -InputObject $storage -Name 'dataDisks'
    $dataDisks = @($dataDiskValue | Where-Object { $null -ne $_ })
    $securityType = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $vm -Name 'securityProfile') -Name 'securityType')
    if (-not $securityType) {
        $securityType = 'Standard'
    }
    $hostSize = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $vm -Name 'hardwareProfile') -Name 'vmSize')
    $hostEvidence = [ordered]@{ osDisk = [string](Get-DemoMemberValue -InputObject $osDisk -Name 'name'); dataDisks = $dataDisks.Count; securityType = $securityType; size = $hostSize }
    if ($dataDisks.Count -gt 0 -or $securityType -ne 'Standard' -or -not $osDiskId) {
        & $add 'GOLDEN.CAPTURE.HOST' 'Not supported' 'Golden snapshots copy one OS disk of a Standard security type host without data disks (the lowest-cost layout, where the guest lives on the OS disk).' $hostEvidence
        return $results.ToArray()
    }
    & $add 'GOLDEN.CAPTURE.HOST' 'Pass' ('archost01 ({0}, {1}) has one OS disk and no data disks.' -f $hostSize, $securityType) $hostEvidence

    # 2. Policy.
    if ($SkipPolicyInventory) {
        & $add 'GOLDEN.CAPTURE.POLICY' 'Not selected' 'The policy inventory was skipped (-SkipPolicyInventory); the snapshot''s creation still fails on a deny.'
    }
    else {
        try {
            $policy = Get-DemoPolicyConstraint -Config $Config
            $types = @($policy.Results | Where-Object { [string]$_.checkId -eq 'PREFLIGHT.POLICY.RESOURCETYPES' } | Select-Object -First 1)
            $deniedValue = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject ($types | Select-Object -First 1) -Name 'evidence') -Name 'denied'
            $denied = @($deniedValue | Where-Object { [string]$_ -match 'Microsoft\.Compute/(snapshots|disks)' })
            if ($denied.Count -gt 0) {
                & $add 'GOLDEN.CAPTURE.POLICY' 'Fail' ('Azure Policy denies what the capture creates: {0}.' -f ($denied -join '; ')) @{ denied = $denied } 'Ask for a policy exemption for rg-<prefix>-golden, or keep building T2 (t2Source build).'
                return $results.ToArray()
            }
            & $add 'GOLDEN.CAPTURE.POLICY' 'Pass' 'No enforced policy denies snapshots or disks.'
        }
        catch {
            & $add 'GOLDEN.CAPTURE.POLICY' 'Warning' ('The policy inventory failed ({0}); the snapshot''s creation still fails on a deny.' -f $_.Exception.Message.TrimEnd('.'))
        }
    }

    $snapshotName = Get-DemoGoldenSnapshotName -Config $Config -NowUtc $NowUtc
    if (-not $proceed) {
        & $add 'GOLDEN.CAPTURE' 'Not selected' ('What if: nothing changed. The capture would create {0} in {1}.' -f $snapshotName, $goldenGroup)
        return $results.ToArray()
    }

    # 3. The host running, with a guest an interrupted capture left air-gapped released.
    $power = Invoke-DemoVmPowerAction -Config $Config -VmName 'archost01' -Action Start
    $results.Add($power)
    if ($power.status -ne 'Pass') {
        return $results.ToArray()
    }
    $release = Invoke-DemoGoldenGuestAction -Config $Config -Action 'Release' -TimeoutSeconds 1800
    if (-not $release.Succeeded) {
        & $add 'GOLDEN.CAPTURE.RELEASE' 'Fail' ('The guest couldn''t be made ready: {0}' -f $release.Error) @{} 'Read the Run Command error, fix the cause, and run capture-t2-golden.ps1 again.'
        return $results.ToArray()
    }

    # 4. Inspect until the host is Ready, then check the preconditions.
    $deadline = [DateTime]::UtcNow.AddMinutes($HostReadyMinutes)
    $inspect = $null
    while ($true) {
        $inspect = Invoke-DemoGoldenGuestAction -Config $Config -Action 'Inspect' -TimeoutSeconds 900
        $hostState = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $inspect.Data -Name 'host') -Name 'hostState')
        $sqlService = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $inspect.Data -Name 'guest') -Name 'sqlService')
        if (($inspect.Succeeded -and $hostState -eq 'Ready' -and $sqlService -eq 'Running') -or [DateTime]::UtcNow -ge $deadline) {
            break
        }
        Start-Sleep -Seconds 60
    }
    if (-not $inspect.Succeeded) {
        & $add 'GOLDEN.CAPTURE.INSPECT' 'Fail' ('The host and guest couldn''t be inspected: {0}' -f $inspect.Error)
        return $results.ToArray()
    }
    $hostFacts = Get-DemoMemberValue -InputObject $inspect.Data -Name 'host'
    $guest = Get-DemoMemberValue -InputObject $inspect.Data -Name 'guest'
    $agent = Get-DemoMemberValue -InputObject $guest -Name 'agent'
    $expires = [string](Get-DemoMemberValue -InputObject $guest -Name 'evaluationExpiresUtc')
    $expiresUtc = [datetime]::MinValue
    $daysLeft = $null
    if ([datetime]::TryParse($expires, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiresUtc)) {
        $daysLeft = [int][System.Math]::Floor(($expiresUtc - $NowUtc.ToUniversalTime()).TotalDays)
    }
    $agentKeys = Get-DemoMemberValue -InputObject $agent -Name 'keys'
    $facts = [ordered]@{
        hostState              = [string](Get-DemoMemberValue -InputObject $hostFacts -Name 'hostState')
        productKeyFile         = [bool](Get-DemoMemberValue -InputObject $hostFacts -Name 'productKeyFile')
        bundleSha256           = [string](Get-DemoMemberValue -InputObject $hostFacts -Name 'bundleSha256')
        runnerSha256           = [string](Get-DemoMemberValue -InputObject $hostFacts -Name 'runnerSha256')
        usedGiB                = Get-DemoMemberValue -InputObject $hostFacts -Name 'usedGiB'
        sqlService             = [string](Get-DemoMemberValue -InputObject $guest -Name 'sqlService')
        sqlEdition             = [string](Get-DemoMemberValue -InputObject $guest -Name 'sqlEdition')
        sqlVersion             = [string](Get-DemoMemberValue -InputObject $guest -Name 'sqlVersion')
        sqlUpdateLevel         = [string](Get-DemoMemberValue -InputObject $guest -Name 'sqlUpdateLevel')
        sqlUpdateReference     = [string](Get-DemoMemberValue -InputObject $guest -Name 'sqlUpdateReference')
        evaluationExpiresUtc   = $expires
        evaluationDaysLeft     = $daysLeft
        agentStatus            = [string](Get-DemoMemberValue -InputObject $agent -Name 'status')
        agentResourceName      = [string](Get-DemoMemberValue -InputObject $agent -Name 'resourceName')
        agentResourceGroup     = [string](Get-DemoMemberValue -InputObject $agent -Name 'resourceGroup')
        agentKeys              = @($agentKeys)
        setupLogFilesWithToken = Get-DemoMemberValue -InputObject $guest -Name 'setupLogFilesWithToken'
        signInCacheCount       = Get-DemoMemberValue -InputObject $guest -Name 'signInCacheCount'
        ieEsc                  = Get-DemoMemberValue -InputObject $guest -Name 'ieEsc'
        workloadTask           = [string](Get-DemoMemberValue -InputObject $guest -Name 'workloadTask')
    }
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($facts.hostState -ne 'Ready') { $problems.Add(('the host reports {0}, not Ready' -f $facts.hostState)) }
    if ($facts.productKeyFile) { $problems.Add('a SQL Server product key file is on the host') }
    if ($facts.sqlService -ne 'Running' -or $facts.sqlEdition -notmatch 'Standard') { $problems.Add(('SQL Server is {0} with edition ''{1}''' -f $facts.sqlService, $facts.sqlEdition)) }
    if ($facts.agentStatus -ne 'Connected' -or $facts.agentResourceName -ne 'arcsql01' -or ($facts.agentResourceGroup -and $facts.agentResourceGroup -ne $resourceGroupName)) {
        $problems.Add(('the guest''s Arc agent reports {0} for {1} in {2}, not Connected for arcsql01 in {3}' -f $facts.agentStatus, $facts.agentResourceName, $facts.agentResourceGroup, $resourceGroupName))
    }
    if ($null -eq $daysLeft) { $problems.Add('the guest''s Windows evaluation expiry couldn''t be read') }
    elseif ($daysLeft -le 7) { $problems.Add(('the guest''s Windows evaluation ends in {0} days' -f $daysLeft)) }
    if ($problems.Count -gt 0) {
        & $add 'GOLDEN.CAPTURE.INSPECT' 'Fail' ('Not captured: {0}.' -f ($problems -join '; ')) $facts 'Fix each item (deploy.ps1 -Resume converges the host), then run capture-t2-golden.ps1 again.'
        return $results.ToArray()
    }
    $inspectStatus = if ($daysLeft -le 30) { 'Warning' } else { 'Pass' }
    $inspectMessage = 'The host is Ready, SQL Server Standard runs, the guest is connected to arcsql01, and its Windows evaluation ends on {0} ({1} days).' -f $expiresUtc.ToString('yyyy-MM-dd'), $daysLeft
    if ($inspectStatus -eq 'Warning') {
        $inspectMessage += ' Re-capture after a fresh build within 30 days.'
    }
    & $add 'GOLDEN.CAPTURE.INSPECT' $inspectStatus $inspectMessage $facts

    # 5. Activity off, then the host password.
    $results.Add((Set-DemoTargetProfile -Config $Config -Target 'T2' -ProfileName 'off' -CheckPrefix 'STOP' -SkipReason '' -RequestedBy 'capture-t2-golden'))
    $password = Set-DemoVmLocalPassword -Config $Config -VmName 'archost01' -Rotate -Confirm:$false
    $results.Add($password)
    # A Warning: the password is rotated, and the Windows PowerShell log that recorded it was cleared (Phase 26f).
    if ($password.status -notin 'Pass', 'Warning') {
        & $add 'GOLDEN.CAPTURE.HOSTPASSWORD' 'Fail' 'The host administrator''s password wasn''t rotated, so nothing was captured (guardrail 5).' @{} $password.remediation
        return $results.ToArray()
    }

    # 5b. Sign-in data (ADR 0009): nothing is captured unless, after the cleanup, a fresh sweep of the host and
    # the guest finds none left.
    $sweep = Invoke-DemoSignInDataAction -Config $Config -VmName 'archost01' -Action 'Clean' -Scope 'Both'
    $signIn = Get-DemoSignInDataResult -CheckId 'GOLDEN.CAPTURE.SIGNIN' -Area 't2' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $sweep -Remediation 'Nothing was captured. Run ./scripts/check-sign-in-data.ps1 -VmName archost01 -Clean until it passes, then capture again.'
    if ($signIn.status -eq 'Manual action required') {
        $signIn.message = '{0} Nothing was captured.' -f $signIn.message
    }
    $results.Add($signIn)
    if ($signIn.status -in 'Fail', 'Manual action required') {
        return $results.ToArray()
    }
    $wipeDoc = 'https://learn.microsoft.com/powershell/module/hyper-v/optimize-vhd'
    if ($WipeFreeSpace) {
        # 5c. The guest's free space, overwritten with zeros (ADR 0009): what the sweep deleted is gone from it too.
        $fill = Invoke-DemoDiskWipeAction -Config $Config -Action 'GuestFill' -MinHostFreeGB $MinHostFreeGB
        $guestFill = Get-DemoMemberValue -InputObject $fill.Data -Name 'guest'
        $fillEvidence = [ordered]@{ seconds = $fill.Seconds; hostFreeBefore = Get-DemoMemberValue -InputObject $fill.Data -Name 'hostFreeBefore'; hostFreeAfter = Get-DemoMemberValue -InputObject $fill.Data -Name 'hostFreeAfter'; guestBytes = Get-DemoMemberValue -InputObject $guestFill -Name 'bytes'; guestTrim = Get-DemoMemberValue -InputObject $guestFill -Name 'trimAfter' }
        if (-not $fill.Succeeded) {
            $results.Add((New-DemoResult -CheckId 'GOLDEN.CAPTURE.WIPE' -Area 't2' -Target 'T2' -Status 'Fail' -Message ('The guest''s free space wasn''t overwritten, so nothing was captured: {0}' -f $fill.Error) -Evidence $fillEvidence -Remediation 'Free space on the host''s C: when it''s short, then run capture-t2-golden.ps1 -WipeFreeSpace again.' -DocUrl $wipeDoc))
            return $results.ToArray()
        }
        $results.Add((New-DemoResult -CheckId 'GOLDEN.CAPTURE.WIPE' -Area 't2' -Target 'T2' -Status 'Pass' -Message ('The guest''s free space was overwritten with zeros ({0:N1} GB in {1:N0} minutes) and trimmed.' -f ([double]$fillEvidence['guestBytes'] / 1GB), ($fill.Seconds / 60)) -Evidence $fillEvidence -DocUrl $wipeDoc))
    }

    # 6. Clean, air-gap, and shut the guest down.
    $prepare = Invoke-DemoGoldenGuestAction -Config $Config -Action 'Prepare' -Parameter @{ SnapshotName = $snapshotName } -TimeoutSeconds 2400
    if (-not $prepare.Succeeded) {
        & $add 'GOLDEN.CAPTURE.PREPARE' 'Fail' ('The guest wasn''t prepared: {0}' -f $prepare.Error) @{} 'Run capture-t2-golden.ps1 again: it releases a half-prepared guest first.'
        return $results.ToArray()
    }
    $prepared = $prepare.Data
    $prepareEvidence = [ordered]@{}
    foreach ($name in 'cachesRemoved', 'logFilesRedacted', 'signInCachesLeft', 'setupLogFilesWithToken', 'ieEsc', 'airGap', 'guestState', 'guestShutdownSeconds') {
        $prepareEvidence[$name] = Get-DemoMemberValue -InputObject $prepared -Name $name
    }
    $record = Get-DemoMemberValue -InputObject $prepared -Name 'record'
    & $add 'GOLDEN.CAPTURE.PREPARE' 'Pass' ('The guest passed its own sign-in check again (caches removed: {0}, log files redacted: {1}), and is air-gapped and shut down in {2} seconds.' -f $prepareEvidence['cachesRemoved'], $prepareEvidence['logFilesRedacted'], $prepareEvidence['guestShutdownSeconds']) $prepareEvidence
    if ($WipeFreeSpace) {
        # 6b. With the guest off: its VHDX compacted, then the host's free space zeroed and trimmed.
        $compact = Invoke-DemoDiskWipeAction -Config $Config -Action 'HostCompact'
        $hostPart = Get-DemoMemberValue -InputObject $compact.Data -Name 'host'
        $compactEvidence = [ordered]@{ seconds = $compact.Seconds; disks = Get-DemoMemberValue -InputObject $hostPart -Name 'disks'; hostBytes = Get-DemoMemberValue -InputObject $hostPart -Name 'bytes'; hostFreeAfter = Get-DemoMemberValue -InputObject $hostPart -Name 'freeAfter'; trim = Get-DemoMemberValue -InputObject $hostPart -Name 'trim' }
        if (-not $compact.Succeeded) {
            $results.Add((New-DemoResult -CheckId 'GOLDEN.CAPTURE.COMPACT' -Area 't2' -Target 'T2' -Status 'Fail' -Message ('The guest''s disk wasn''t compacted or the host''s free space wasn''t overwritten, so nothing was captured: {0}' -f $compact.Error) -Evidence $compactEvidence -Remediation 'Run capture-t2-golden.ps1 -WipeFreeSpace again: it releases the air-gapped guest first.' -DocUrl $wipeDoc))
            return $results.ToArray()
        }
        $results.Add((New-DemoResult -CheckId 'GOLDEN.CAPTURE.COMPACT' -Area 't2' -Target 'T2' -Status 'Pass' -Message ('The guest''s disk was compacted, and the host''s free space was overwritten with zeros ({0:N1} GB) and trimmed, in {1:N0} minutes.' -f ([double]$compactEvidence['hostBytes'] / 1GB), ($compact.Seconds / 60)) -Evidence $compactEvidence -DocUrl $wipeDoc))
    }

    # 7. Deallocate, then the snapshot.
    $stop = Invoke-DemoVmPowerAction -Config $Config -VmName 'archost01' -Action Deallocate
    $results.Add($stop)
    if ($stop.status -ne 'Pass') {
        return $results.ToArray()
    }
    $standardTags = Get-DemoGoldenStandardTag -Config $Config
    $groupExists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $goldenGroup) -AllowFailure
    if (([string]$groupExists.StdOut).Trim() -ne 'true') {
        $create = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList (@('group', 'create', '--name', $goldenGroup, '--location', $location, '--tags') + (ConvertTo-DemoTagArgument -Tag $standardTags)) -AllowFailure
        if ($create.ExitCode -ne 0) {
            & $add 'GOLDEN.CAPTURE.GROUP' 'Fail' ('{0} couldn''t be created: {1}' -f $goldenGroup, (Get-DemoDeploymentErrorText -Text $create.StdErr -MaxLength 400))
            return $results.ToArray()
        }
    }
    $names = Get-DemoGoldenTagName
    $snapshotTags = [ordered]@{}
    foreach ($key in $standardTags.Keys) {
        $snapshotTags[$key] = $standardTags[$key]
    }
    $snapshotTags[$names['Role']] = 't2-golden'
    $snapshotTags[$names['CapturedUtc']] = $NowUtc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $snapshotTags[$names['EvalExpiresUtc']] = $expiresUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $snapshotTags[$names['BundleSha256']] = $facts.bundleSha256
    $snapshotTags[$names['RunnerSha256']] = $facts.runnerSha256
    $snapshotTags[$names['SqlEdition']] = 'Standard'
    $snapshotTags[$names['SqlVersion']] = $facts.sqlVersion
    $snapshotTags[$names['SqlUpdateLevel']] = if ($facts.sqlUpdateLevel) { '{0}-{1}' -f $facts.sqlUpdateLevel, $facts.sqlUpdateReference } else { 'RTM' }
    $snapshotTags[$names['InstallMode']] = 'PaygWizard'
    $snapshotTags[$names['HostSize']] = $hostSize
    $snapshotTags[$names['SecurityType']] = $securityType
    $snapshotTags[$names['UsedGiB']] = [string]$facts.usedGiB
    $snapshotTags[$names['SourceGroup']] = $resourceGroupName
    $snapshotTags[$names['SourceAzureVmId']] = [string](Get-DemoMemberValue -InputObject $record -Name 'sourceAzureVmId')
    $snapshotTags[$names['ArcIdentity']] = '{0}/{1}' -f $resourceGroupName, 'arcsql01'
    $clean = [ordered]@{}
    foreach ($key in $snapshotTags.Keys) {
        # Tag values pass through az.cmd, which can't carry quotes or percent signs; spaces aren't needed.
        $value = ([string]$snapshotTags[$key]) -replace '[^A-Za-z0-9._:/@+=,_-]', '-'
        if ($value) {
            $clean[$key] = $value
        }
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $created = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList (@('snapshot', 'create', '--resource-group', $goldenGroup, '--name', $snapshotName, '--location', $location, '--source', $osDiskId, '--incremental', 'true', '--network-access-policy', 'DenyAll', '--public-network-access', 'Disabled', '--output', 'json', '--tags') + (ConvertTo-DemoTagArgument -Tag $clean)) -AllowFailure
    $snapshot = if ($created.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$created.StdOut)) { [string]$created.StdOut | ConvertFrom-Json -Depth 32 } else { $null }
    if ($null -eq $snapshot -or [string](Get-DemoMemberValue -InputObject $snapshot -Name 'provisioningState') -ne 'Succeeded') {
        & $add 'GOLDEN.CAPTURE.SNAPSHOT' 'Fail' ('The snapshot {0} wasn''t created: {1}' -f $snapshotName, (Get-DemoDeploymentErrorText -Text $created.StdErr -MaxLength 600)) @{} 'A policy deny names the policy. The source host stays deallocated and air-gapped until start-demo.ps1 releases it.'
        return $results.ToArray()
    }
    $parsed = ConvertFrom-DemoGoldenSnapshot -Snapshot $snapshot -NowUtc $NowUtc
    $snapshotEvidence = [ordered]@{ name = $parsed.Name; sku = $parsed.Sku; sizeGiB = $parsed.SizeGiB; usedGiB = $facts.usedGiB; incremental = $parsed.Incremental; networkAccessPolicy = $parsed.NetworkAccessPolicy; seconds = [int]$watch.Elapsed.TotalSeconds; evalExpiresUtc = $snapshotTags[$names['EvalExpiresUtc']] }
    if (-not $parsed.Incremental -or $parsed.NetworkAccessPolicy -ne 'DenyAll') {
        & $add 'GOLDEN.CAPTURE.SNAPSHOT' 'Fail' ('The snapshot {0} exists, but it isn''t incremental with network access DenyAll.' -f $snapshotName) $snapshotEvidence
        return $results.ToArray()
    }
    & $add 'GOLDEN.CAPTURE.SNAPSHOT' 'Pass' ('Snapshot {0}: incremental, {1}, DenyAll, {2} GiB provisioned and about {3} GiB used, in {4:N0} seconds.' -f $parsed.Name, $parsed.Sku, $parsed.SizeGiB, $facts.usedGiB, $watch.Elapsed.TotalSeconds) $snapshotEvidence

    # 8. A disk from it must succeed.
    $diskName = '{0}-verify' -f $snapshotName
    $watch.Restart()
    $diskCreate = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList (@('disk', 'create', '--resource-group', $goldenGroup, '--name', $diskName, '--location', $location, '--source', $parsed.Id, '--sku', 'Standard_LRS', '--network-access-policy', 'DenyAll', '--public-network-access', 'Disabled', '--output', 'json', '--tags') + (ConvertTo-DemoTagArgument -Tag $standardTags)) -AllowFailure
    $disk = if ($diskCreate.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$diskCreate.StdOut)) { [string]$diskCreate.StdOut | ConvertFrom-Json -Depth 32 } else { $null }
    $diskState = [string](Get-DemoMemberValue -InputObject $disk -Name 'provisioningState')
    $diskSeconds = [int]$watch.Elapsed.TotalSeconds
    $deleted = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('disk', 'delete', '--resource-group', $goldenGroup, '--name', $diskName, '--yes') -AllowFailure
    if ($diskState -ne 'Succeeded') {
        & $add 'GOLDEN.CAPTURE.DISKVERIFY' 'Fail' ('A disk couldn''t be created from {0} (state ''{1}''): {2}' -f $snapshotName, $diskState, (Get-DemoDeploymentErrorText -Text $diskCreate.StdErr -MaxLength 400)) @{ seconds = $diskSeconds } 'Don''t rely on this snapshot; capture again.'
        return $results.ToArray()
    }
    $verifiedUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $tagged = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('tag', 'update', '--resource-id', $parsed.Id, '--operation', 'Merge', '--tags', ('{0}={1}' -f $names['DiskVerifiedUtc'], $verifiedUtc)) -AllowFailure
    $diskStatus = if ($tagged.ExitCode -eq 0 -and $deleted.ExitCode -eq 0) { 'Pass' } else { 'Warning' }
    & $add 'GOLDEN.CAPTURE.DISKVERIFY' $diskStatus ('A disk created from {0} succeeded in {1} seconds{2}.' -f $snapshotName, $diskSeconds, $(if ($deleted.ExitCode -ne 0) { '; its test disk wasn''t deleted, so delete it by hand' } elseif ($tagged.ExitCode -ne 0) { '; the disk-verified tag wasn''t written' } else { ' and was deleted' })) @{ seconds = $diskSeconds; testDisk = $diskName }

    $older = @(Get-DemoT2GoldenSnapshot -Config $Config -NowUtc $NowUtc | Where-Object { $_.Name -ne $snapshotName })
    $olderStatus = if ($older.Count -gt 0) { 'Pass' } else { 'Not selected' }
    & $add 'GOLDEN.CAPTURE.PREVIOUS' $olderStatus $(if ($older.Count -gt 0) { '{0} older golden snapshot(s) stay until {1} is boot-verified: {2}.' -f $older.Count, $snapshotName, (($older | ForEach-Object { $_.Name }) -join ', ') } else { 'No older golden snapshot.' })
    & $add 'GOLDEN.CAPTURE' 'Pass' ('{0} is captured and disk-verified. Prove it boots before relying on it: ./scripts/test-t2-golden.ps1 -SnapshotName {0} -Onboard.' -f $snapshotName) ([ordered]@{ snapshot = $snapshotName; group = $goldenGroup })
    return $results.ToArray()
}
