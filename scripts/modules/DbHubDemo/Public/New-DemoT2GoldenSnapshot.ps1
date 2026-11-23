function New-DemoT2GoldenSnapshot {
    <#
    .SYNOPSIS
    Captures the T2 host's OS disk as a golden snapshot in rg-<prefix>-golden (ADR 0018, guardrails 2, 4,
    and 5). capture-t2-golden.ps1 calls it.

    .DESCRIPTION
    1. The subscription guard. The nested T2 mode with PaygWizard (the snapshot keeps the setup-wizard state) or
       JumpstartImage (a speed-up only: a redeploy skips the image's download and first boot), and a host without data
       disks (the guest lives on the OS disk); anything else is Not supported.
    2. Policy: the read-only inventory must not deny snapshots or disks (unless -SkipPolicyInventory).
       Then no on-demand run may be active (GOLDEN.CAPTURE.CONTROL, Get-DemoGoldenCaptureControlResult): no
       DbHub-Control or DbHub-Stop job queued or running, and no pending auto-stop, because a run starts and
       deallocates archost01; otherwise nothing changes (review, 2026-11-04). Nor may the Incident RCA's evidence that a
       history save didn't take be listed for T2, which Prepare would delete: this PC's pending list (out/history-pending,
       Read-DemoRcaPending), or the session control's status (its variable DbHubSessionStatus, read through Azure Resource
       Manager: Get-DemoGoldenControlRcaPending). GOLDEN.CAPTURE.RCA names the list and the way to save them: the
       scripts' history save for the first, a Run all session for each session the second lists, at least, since each start
       fetches one session's on any VM, and the capture again after each (ADR 0031); both save them with the demo
       workspace's NB_DatabaseHub_LiveActivity, so when its copy is from before the Incident RCA (Get-DemoGoldenRcaNotebookState,
       read only then), the fix updates it first (./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook
       NB_DatabaseHub_LiveActivity, which leaves the workspace's other notebook as it is). A status that Resource Manager
       can't give, because a tenant's policy encrypted the variable (Resource Manager then returns no value) or the read
       failed, is read by the session control's own read-only job (2026-11-23: DbHub-Control's pending action, started as
       a job, Invoke-DemoGoldenControlPendingJob), which reads it with Get-AutomationVariable and prints its lists. When
       that can't either, nothing is captured: a DbHub-Control from before that action gets ./scripts/deploy.ps1 as the fix,
       and another failure the capture again, then, for an encrypted variable, the fix for a governed tenant: Run all
       sessions until one has no RCA.EARLIER line at its start about evidence still left, no RCA.EXPORT line about another
       session's documents, and no RCA.PENDING line at its end; then, the same day, the variable deleted, deploy.ps1, which
       creates it again unencrypted and empty (since 2026-11-23 it keeps an existing one as it is, so an update no longer
       loses what it lists), and the capture, before it's encrypted again. Nor does a variable missing from the control's
       account, which exists (the review of 40124992: since 2026-11-23 deploy.ps1 creates it only when it's missing, so a
       deletion, or a deployment that couldn't create it, can leave it missing while sessions run), with
       ./scripts/deploy.ps1, which creates it, as the fix.
    3. Starts archost01 when it's deallocated, and releases an air gap that an interrupted capture left (the
       host's Azure VM ID matches the capture record, so only the guest's network and start action return).
    4. Inspects the host and guest (vm/bootstrap/Invoke-DemoGoldenGuest.ps1 -Action Inspect, read-only) and
       checks: the host's health is Ready, no SQL Server product key file, SQL Server Standard running, the
       guest's Arc agent connected to this environment's arcsql01, and, for a guest whose Windows is an evaluation,
       its evaluation more than 7 days from its end (a Warning within 30 days).
    5. Turns T2's activity profile off and rotates the host administrator's password to a value nobody keeps.
       Then the sign-in data gate (ADR 0009): vm/bootstrap/Invoke-DemoSignInResidue.ps1 removes the sign-in data
       left on the host and in the guest and scans again; anything left (GOLDEN.CAPTURE.SIGNIN Fail, or Manual
       action required for the Security log, which only an operator clears) means nothing is captured.
       With -WipeFreeSpace (ADR 0009, Phase 26d), vm/bootstrap/Invoke-DemoDiskWipe.ps1 -WipeAction GuestFill then
       checks that the host's C: has at least -MinHostFreeGB free, runs the TRIM pass in the guest, overwrites the
       guest's free space with zeros, deletes that file, and trims again (GOLDEN.CAPTURE.WIPE).
    6. Prepare: writes the capture marker first (T2's control relay leaves the guest alone while it's there; the
       capture's own Release removes it, at step 3 and in step 9), removes the sign-in data that setup leaves on the
       VM again and checks that none remains, turns IE
       ESC on, deletes the Incident RCA's capture in the guest after stopping its workload runner (ADR 0031; anything
       left means nothing is captured), writes the capture record, applies the air gap (the guest's automatic start action Nothing, its
       network adapter disconnected), and shuts the guest down cleanly. With -WipeFreeSpace, HostCompact then
       compacts the guest's VHDX (Optimize-VHD -Mode Full, mounted read-only), overwrites the host's free space
       with zeros, deletes that file, and trims the host's volume, so the snapshot keeps none of the zeroed
       blocks (GOLDEN.CAPTURE.COMPACT). Either failing means nothing is captured.
    7. Deallocates the host, creates rg-<prefix>-golden when missing (standard tags, no deploymentId), then an
       incremental snapshot of archost01-osdisk with network access DenyAll and public network access off,
       tagged with its lifetime and provenance.
    8. Creates a disk from it in the golden group (DenyAll), deletes it, and tags the snapshot disk-verified.
       Older snapshots stay until the new one is boot-verified (test-t2-golden.ps1).

    9. Returns the source to service once Prepare has run, whatever happened after it (GOLDEN.CAPTURE.SOURCE,
       Restore-DemoGoldenCaptureSource): starts archost01 when it's deallocated, releases its guest (reconnects its
       adapter, automatic start Start, starts it; Invoke-DemoGoldenSourceRelease, which also tags the snapshot
       dbhubSourceReleasedUtc), waits up to 30 minutes until arcsql01 reads Connected after the air gap, then
       returns the host to the power state the capture found it in (a clean guest shutdown first, never by force).
       A Fabric start therefore never finds T2 cut off (live, 2026-11-03).

    Nothing is deleted. -WhatIf runs steps 1 and 2 only. An interrupted capture (Ctrl+C) may leave the air gap and its
    marker: the next capture releases it at once (its first step ends the marker), start-demo.ps1 and deploy.ps1 once
    its snapshot exists (they end the marker then), and a Fabric start of T2 once the marker no longer counts (6 hours);
    status.ps1 reports it (T2.GUEST.STATE).

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
    # The guest's own mode (2026-11-09): a kept PaygWizard guest under the default JumpstartImage mode is captured as what it is.
    $guestState = $null
    try {
        $guestState = Get-DemoDeploymentState -Config $Config
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The deployment state couldn''t be read, so the snapshot is tagged with t2SqlInstallMode: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    $guestMode = Get-DemoT2GuestInstallMode -Config $Config -State $guestState
    if ($guestMode -notin 'PaygWizard', 'JumpstartImage') {
        & $add 'GOLDEN.CAPTURE.MODE' 'Not supported' ('Golden snapshots keep the PaygWizard setup-wizard state or speed up a JumpstartImage redeploy; T2''s guest is in {0} mode, which installs unattended on every build.' -f $guestMode)
        return $results.ToArray()
    }
    $vm = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $resourceGroupName, '--name', 'archost01') -AsJson -AllowFailure
    if ($null -eq $vm) {
        & $add 'GOLDEN.CAPTURE.HOST' 'Fail' ('archost01 wasn''t found in {0}.' -f $resourceGroupName) @{} 'Deploy T2 first (deploy.ps1), then capture.'
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

    # 2b. No on-demand run: it would start or deallocate archost01 during the capture (review, 2026-11-04).
    $control = Get-DemoGoldenCaptureControlResult -Config $Config
    $results.Add($control)
    if ($control.status -eq 'Fail') {
        return $results.ToArray()
    }

    # 2c. T2's Incident RCA evidence that a history save didn't take (ADR 0031): Prepare deletes what T2's guest keeps,
    # where the runner keeps such documents to be fetched again, so a capture now would lose them (the review of 3f6cd14).
    # Two lists name them, each with its VM, and each has its own way to fetch them: this PC's (out/history-pending),
    # which the scripts' next history save fetches, and the session control's status, whose next start fetches the
    # documents its runbooks exported but couldn't fetch (Get-DemoGoldenControlRcaPending). A status that can't be read
    # captures nothing, as GOLDEN.CAPTURE.CONTROL does.
    $pending = Read-DemoRcaPending -Config $Config
    $t2Pending = @(@($pending.Documents) | Where-Object { $null -ne $_ -and [string]$_['vm'] -eq 'archost01' })
    $controlPending = Get-DemoGoldenControlRcaPending -Config $Config -NowUtc $NowUtc
    if ($controlPending.Error) {
        $readFix = 'Run ./scripts/capture-t2-golden.ps1 again; ./scripts/status.ps1 shows the control (STATUS.CONTROL).'
        $readEvidence = [ordered]@{ status = $controlPending.Variable }
        $jobId = [string](Get-DemoMemberValue -InputObject $controlPending -Name 'JobId')
        if ($jobId) {
            $readEvidence['job'] = $jobId
        }
        if ([bool](Get-DemoMemberValue -InputObject $controlPending -Name 'Missing')) {
            # Missing from an account that exists (the review of 40124992): deploy.ps1 creates it only when it's missing, so a
            # deletion, or a deployment that couldn't create it, can leave it so while sessions run, and their stops' lists
            # are then only in the control vault, which the runbooks can't read back.
            $readEvidence['missing'] = $true
            $readFix = 'Run ./scripts/deploy.ps1, which creates it (CONTROL.RESOURCES says so), then ./scripts/capture-t2-golden.ps1 again. Until it exists, the runbooks keep each session''s status only in the control vault, which they can''t read back, so a session''s start doesn''t fetch what the last stop left on the VMs.'
        }
        elseif ([bool](Get-DemoMemberValue -InputObject $controlPending -Name 'RunbookOld')) {
            # The session control's job reads the status whatever Resource Manager returns (2026-11-23), once deploy.ps1 has
            # published the runbook that knows how.
            $readEvidence['runbookOld'] = $true
            $readFix = 'Run ./scripts/deploy.ps1, which publishes the session control''s runbooks again (CONTROL.RUNBOOKS), then ./scripts/capture-t2-golden.ps1 again: since 2026-11-23, DbHub-Control reads the status for the capture, encrypted or not.'
        }
        elseif ([bool](Get-DemoMemberValue -InputObject $controlPending -Name 'Encrypted')) {
            # A tenant's policy can re-create the variable encrypted (2026-11-23): then only the runbooks read it, and the
            # session control's own job reads it for the capture. When that failed, the capture again usually reads it. If it
            # keeps failing: since 2026-11-23 deploy.ps1 keeps an existing variable as it is, so it reads through Resource
            # Manager again only once deleted and created again, empty, which loses what it lists. Run all prints what's left
            # from the vault's copy of the status: RCA.EARLIER at a start, RCA.EXPORT's note of another session's documents,
            # which the status then carries for that session, and RCA.PENDING at the end; a stop that can't end the capture
            # names that VM in RCA.PENDING too (O1).
            $readEvidence['encrypted'] = $true
            $controlName = Get-DemoActivityControlName -Config $Config
            $readFix = 'Run ./scripts/capture-t2-golden.ps1 again: the session control''s DbHub-Control job reads an encrypted status, and what kept it from it may not last. If it keeps failing, save what the status may list first: run sessions with Run all in {0} until one has no RCA.EARLIER line at its start about evidence still on the VMs or in the control vault, no RCA.EXPORT line that says "document(s) of another session go with that session''s evidence", and no RCA.PENDING line at its end. Then, the same day, before the tenant''s policy encrypts the variable again, delete it (az rest --method delete --url "https://management.azure.com{1}/variables/DbHubSessionStatus?api-version=2024-10-23", or {2}''s Variables in the Azure portal), run ./scripts/deploy.ps1, which creates it again, unencrypted and empty, and then ./scripts/capture-t2-golden.ps1.' -f $controlPending.Notebook, $controlName.AutomationAccountId, $controlName.AutomationAccount
        }
        & $add 'GOLDEN.CAPTURE.RCA' 'Fail' ('The session control''s status ({0}) couldn''t be read ({1}), so whether it lists Incident RCA evidence from T2 that the capture would delete isn''t known. Nothing was captured.' -f $controlPending.Variable, $controlPending.Error) $readEvidence $readFix
        return $results.ToArray()
    }
    $t2Control = @(@($controlPending.Documents) | Where-Object { $null -ne $_ -and [string]$_['vm'] -eq 'archost01' })
    # Each start fetches one session's documents, on whichever VM they are: unsaved bundles first, then the earliest to
    # expire (Get-DbHubRcaEarlier). So every session the status lists counts, and sessions with only unsaved bundles,
    # which the list doesn't show, can come first: the count is a minimum (the reviews of 0a9fb8d and e716ff8).
    $statusSessions = @(@($controlPending.Documents) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_['sessionId'] } | Select-Object -Unique)
    if ($t2Pending.Count -gt 0 -or $t2Control.Count -gt 0) {
        $shown = [string]$pending.Path
        $root = $script:RepoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($shown.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $shown = './' + $shown.Substring($root.Length).Replace('\', '/')
        }
        $evidence = [ordered]@{ path = $shown; documents = @($t2Pending | ForEach-Object { [string]$_['documentId'] }); status = $controlPending.Variable; statusDocuments = @($t2Control | ForEach-Object { [string]$_['documentId'] }); statusSessions = $statusSessions.Count }
        $save = ''
        if ($t2Pending.Count -gt 0) {
            $hostPower = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName 'archost01'
            $evidence['hostPower'] = [string]$hostPower
            $save = if ($hostPower -eq 'PowerState/running') { './scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity' } else { './scripts/start-demo.ps1, then ./scripts/stop-demo.ps1 -SaveHistory' }
        }
        # Both ways save them with the demo workspace's NB_DatabaseHub_LiveActivity, which Run all runs too. A copy from
        # before the Incident RCA, which deploy.ps1 keeps while fabric.importNotebooks is false, saves none of them, so the
        # scripts' save would fetch them again and again and this refusal would stay (the review of c059878): the fix
        # updates it first. Read as FABRIC.RCA.EVIDENCE reads it; one that can't be read gets the fix's condition instead.
        $notebook = Get-DemoGoldenRcaNotebookState -Config $Config
        $evidence['activityNotebook'] = if (-not $notebook.Known) { 'unknown' } elseif ($notebook.Current) { 'current' } else { 'fromBeforeRca' }
        $lose = 'and the capture would delete them with the rest of what T2''s guest keeps, so nothing was captured.'
        $runAll = 'run a session with Run all in {0} for each session the status lists, at least {1}: each start fetches one session''s documents, and its end saves them with its history.' -f $controlPending.Notebook, [System.Math]::Max(1, $statusSessions.Count)
        $again = 'Then run ./scripts/capture-t2-golden.ps1 again.'
        $runAllAgain = 'Run ./scripts/capture-t2-golden.ps1 again after each.'
        $update = ''
        $saveLead = 'Save the history first'
        $runLead = 'First, '
        $ifOld = ''
        if ($notebook.Known -and -not $notebook.Current) {
            $kept = if ([bool](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'importNotebooks')) { '' } else { ' (fabric.importNotebooks is false, so ./scripts/deploy.ps1 keeps the workspace''s copy)' }
            $update = 'First update the demo workspace''s NB_DatabaseHub_LiveActivity, which is from before the Incident RCA (2026-11-20) and so saves none of them{0}: ./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity. ' -f $kept
            $saveLead = 'Then save the history'
            $runLead = 'Then '
        }
        elseif (-not $notebook.Known) {
            $ifOld = ' If a save says the demo workspace''s NB_DatabaseHub_LiveActivity is from before the Incident RCA, run ./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity, which updates it, and save again.'
        }
        if ($t2Control.Count -eq 0) {
            $message = '{0} Incident RCA evidence document(s) from T2 aren''t in the history yet ({1} lists them), {2}' -f $t2Pending.Count, $shown, $lose
            $fix = '{0}{1}: {2}, which fetches them from T2.{3} {4}' -f $update, $saveLead, $save, $ifOld, $again
        }
        elseif ($t2Pending.Count -eq 0) {
            $message = '{0} Incident RCA evidence document(s) from T2 aren''t in the history yet (the session control''s status lists them, in {1}), {2}' -f $t2Control.Count, $controlPending.Variable, $lose
            $fix = '{0}{1}{2}{3} {4}' -f $update, $runLead, $runAll, $ifOld, $runAllAgain
        }
        else {
            $message = '{0} Incident RCA evidence document(s) from T2 aren''t in the history yet ({1} lists {2}, and the session control''s status, in {3}, lists {4}), {5}' -f ($t2Pending.Count + $t2Control.Count), $shown, $t2Pending.Count, $controlPending.Variable, $t2Control.Count, $lose
            $fix = '{0}{1}: {2}, which fetches the ones {3} lists. Then {4}{5} {6}' -f $update, $saveLead, $save, $shown, $runAll, $ifOld, $runAllAgain
        }
        & $add 'GOLDEN.CAPTURE.RCA' 'Fail' $message $evidence $fix
        return $results.ToArray()
    }

    # 3. The host running, with a guest an interrupted capture left air-gapped released. The power state it was
    # found in is what GOLDEN.CAPTURE.SOURCE returns it to.
    $foundPower = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName 'archost01'
    $power = Invoke-DemoVmPowerAction -Config $Config -VmName 'archost01' -Action Start
    $results.Add($power)
    if ($power.status -ne 'Pass') {
        return $results.ToArray()
    }
    # EndCapture: this capture's own Release, so it also removes the marker an interrupted capture left.
    $release = Invoke-DemoGoldenGuestAction -Config $Config -Action 'Release' -Parameter @{ EndCapture = 'true' } -TimeoutSeconds 1800
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
    # Only an evaluation (the TIMEBASED_EVAL channel) expires; the Jumpstart image's Windows Server 2022 Standard doesn't.
    $licenseDescription = [string](Get-DemoMemberValue -InputObject $guest -Name 'licenseDescription')
    $isEvaluation = -not $licenseDescription -or $licenseDescription -match 'TIMEBASED_EVAL'
    $expiresUtc = [datetime]::MinValue
    $daysLeft = $null
    if ($isEvaluation -and [datetime]::TryParse($expires, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiresUtc)) {
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
        evaluationExpiresUtc   = $(if ($isEvaluation) { $expires } else { 'none' })
        evaluationDaysLeft     = $daysLeft
        licenseDescription     = $licenseDescription
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
    if ($isEvaluation -and $null -eq $daysLeft) { $problems.Add('the guest''s Windows evaluation expiry couldn''t be read') }
    elseif ($isEvaluation -and $daysLeft -le 7) { $problems.Add(('the guest''s Windows evaluation ends in {0} days' -f $daysLeft)) }
    if ($problems.Count -gt 0) {
        & $add 'GOLDEN.CAPTURE.INSPECT' 'Fail' ('Not captured: {0}.' -f ($problems -join '; ')) $facts 'Fix each item (deploy.ps1 -Resume converges the host), then run capture-t2-golden.ps1 again.'
        return $results.ToArray()
    }
    $inspectStatus = if ($isEvaluation -and $daysLeft -le 30) { 'Warning' } else { 'Pass' }
    $inspectMessage = if ($isEvaluation) { 'The host is Ready, SQL Server Standard runs, the guest is connected to arcsql01, and its Windows evaluation ends on {0} ({1} days).' -f $expiresUtc.ToString('yyyy-MM-dd'), $daysLeft } else { 'The host is Ready, SQL Server Standard runs, the guest is connected to arcsql01, and its Windows isn''t an evaluation ({0}).' -f $licenseDescription }
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

    # 6 to 8 in one block: once Prepare has run, GOLDEN.CAPTURE.SOURCE returns the source to service whatever happens
    # next (ADR 0018, section 4, item 9), so no start ever finds T2 cut off (live, 2026-11-03).
    $capture = @{ Prepared = $false; AirGapUtc = $null }
    $captureSteps = {
        # 6. Clean, air-gap, and shut the guest down.
        $capture['Prepared'] = $true
        $prepare = Invoke-DemoGoldenGuestAction -Config $Config -Action 'Prepare' -Parameter @{ SnapshotName = $snapshotName } -TimeoutSeconds 2400
        $capture['AirGapUtc'] = [DateTime]::UtcNow
        if (-not $prepare.Succeeded) {
            & $add 'GOLDEN.CAPTURE.PREPARE' 'Fail' ('The guest wasn''t prepared: {0}' -f $prepare.Error) @{} 'Fix the cause and run capture-t2-golden.ps1 again; GOLDEN.CAPTURE.SOURCE says whether the source is back in service.'
            return
        }
        $prepared = $prepare.Data
        $prepareEvidence = [ordered]@{}
        foreach ($name in 'cachesRemoved', 'logFilesRedacted', 'signInCachesLeft', 'setupLogFilesWithToken', 'ieEsc', 'airGap', 'guestState', 'guestShutdownSeconds', 'rcaSpansRemoved', 'rcaSpansNotExported') {
            $prepareEvidence[$name] = Get-DemoMemberValue -InputObject $prepared -Name $name
        }
        $record = Get-DemoMemberValue -InputObject $prepared -Name 'record'
        $prepareMessage = 'The guest passed its own sign-in check again (caches removed: {0}, log files redacted: {1}), and is air-gapped and shut down in {2} seconds.' -f $prepareEvidence['cachesRemoved'], $prepareEvidence['logFilesRedacted'], $prepareEvidence['guestShutdownSeconds']
        # The Incident RCA's capture in the guest, deleted so the snapshot carries none (ADR 0031; the docs review of 0189a4b).
        $rcaSpans = [int]$prepareEvidence['rcaSpansRemoved']
        $rcaNotExported = [int]$prepareEvidence['rcaSpansNotExported']
        if ($rcaSpans -gt 0) {
            # "Exported" isn't "in the history": a save can fail after an export. Step 2c refused while this PC's pending list
            # held T2's documents (the review of 3f6cd14).
            $rcaNote = if ($rcaNotExported -gt 0) { ' The Incident RCA''s capture in the guest was deleted, so the snapshot carries none: {0} observation span(s), {1} of them never fully exported, so that part of T2''s evidence isn''t in the history.' -f $rcaSpans, $rcaNotExported } else { ' The Incident RCA''s capture in the guest was deleted, so the snapshot carries none: {0} observation span(s), each taken by an export, and none of T2''s documents was waiting in this PC''s pending list for a history save.' -f $rcaSpans }
            $prepareMessage += $rcaNote
        }
        & $add 'GOLDEN.CAPTURE.PREPARE' 'Pass' $prepareMessage $prepareEvidence
        if ($WipeFreeSpace) {
            # 6b. With the guest off: its VHDX compacted, then the host's free space zeroed and trimmed.
            $compact = Invoke-DemoDiskWipeAction -Config $Config -Action 'HostCompact'
            $hostPart = Get-DemoMemberValue -InputObject $compact.Data -Name 'host'
            $compactEvidence = [ordered]@{ seconds = $compact.Seconds; disks = Get-DemoMemberValue -InputObject $hostPart -Name 'disks'; hostBytes = Get-DemoMemberValue -InputObject $hostPart -Name 'bytes'; hostFreeAfter = Get-DemoMemberValue -InputObject $hostPart -Name 'freeAfter'; trim = Get-DemoMemberValue -InputObject $hostPart -Name 'trim' }
            if (-not $compact.Succeeded) {
                $results.Add((New-DemoResult -CheckId 'GOLDEN.CAPTURE.COMPACT' -Area 't2' -Target 'T2' -Status 'Fail' -Message ('The guest''s disk wasn''t compacted or the host''s free space wasn''t overwritten, so nothing was captured: {0}' -f $compact.Error) -Evidence $compactEvidence -Remediation 'Free space on the host''s C: when it''s short, then run capture-t2-golden.ps1 -WipeFreeSpace again; GOLDEN.CAPTURE.SOURCE says whether the source is back in service.' -DocUrl $wipeDoc))
                return
            }
            $results.Add((New-DemoResult -CheckId 'GOLDEN.CAPTURE.COMPACT' -Area 't2' -Target 'T2' -Status 'Pass' -Message ('The guest''s disk was compacted, and the host''s free space was overwritten with zeros ({0:N1} GB) and trimmed, in {1:N0} minutes.' -f ([double]$compactEvidence['hostBytes'] / 1GB), ($compact.Seconds / 60)) -Evidence $compactEvidence -DocUrl $wipeDoc))
        }

        # 7. Deallocate, then the snapshot.
        $stop = Invoke-DemoVmPowerAction -Config $Config -VmName 'archost01' -Action Deallocate
        $results.Add($stop)
        if ($stop.status -ne 'Pass') {
            return
        }
        $standardTags = Get-DemoGoldenStandardTag -Config $Config
        $groupExists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $goldenGroup) -AllowFailure
        if (([string]$groupExists.StdOut).Trim() -ne 'true') {
            $create = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList (@('group', 'create', '--name', $goldenGroup, '--location', $location, '--tags') + (ConvertTo-DemoTagArgument -Tag $standardTags)) -AllowFailure
            if ($create.ExitCode -ne 0) {
                & $add 'GOLDEN.CAPTURE.GROUP' 'Fail' ('{0} couldn''t be created: {1}' -f $goldenGroup, (Get-DemoDeploymentErrorText -Text $create.StdErr -MaxLength 400))
                return
            }
        }
        $names = Get-DemoGoldenTagName
        $snapshotTags = [ordered]@{}
        foreach ($key in $standardTags.Keys) {
            $snapshotTags[$key] = $standardTags[$key]
        }
        $snapshotTags[$names['Role']] = 't2-golden'
        $snapshotTags[$names['CapturedUtc']] = $NowUtc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $snapshotTags[$names['EvalExpiresUtc']] = if ($isEvaluation) { $expiresUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } else { 'none' }
        $snapshotTags[$names['BundleSha256']] = $facts.bundleSha256
        $snapshotTags[$names['RunnerSha256']] = $facts.runnerSha256
        $snapshotTags[$names['SqlEdition']] = 'Standard'
        $snapshotTags[$names['SqlVersion']] = $facts.sqlVersion
        $snapshotTags[$names['SqlUpdateLevel']] = if ($facts.sqlUpdateLevel) { '{0}-{1}' -f $facts.sqlUpdateLevel, $facts.sqlUpdateReference } else { 'RTM' }
        $snapshotTags[$names['InstallMode']] = $guestMode
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
            & $add 'GOLDEN.CAPTURE.SNAPSHOT' 'Fail' ('The snapshot {0} wasn''t created: {1}' -f $snapshotName, (Get-DemoDeploymentErrorText -Text $created.StdErr -MaxLength 600)) @{} 'A policy deny names the policy. The source is returned to service either way (GOLDEN.CAPTURE.SOURCE).'
            return
        }
        $parsed = ConvertFrom-DemoGoldenSnapshot -Snapshot $snapshot -NowUtc $NowUtc
        $snapshotEvidence = [ordered]@{ name = $parsed.Name; sku = $parsed.Sku; sizeGiB = $parsed.SizeGiB; usedGiB = $facts.usedGiB; incremental = $parsed.Incremental; networkAccessPolicy = $parsed.NetworkAccessPolicy; seconds = [int]$watch.Elapsed.TotalSeconds; evalExpiresUtc = $snapshotTags[$names['EvalExpiresUtc']] }
        if (-not $parsed.Incremental -or $parsed.NetworkAccessPolicy -ne 'DenyAll') {
            & $add 'GOLDEN.CAPTURE.SNAPSHOT' 'Fail' ('The snapshot {0} exists, but it isn''t incremental with network access DenyAll.' -f $snapshotName) $snapshotEvidence
            return
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
            return
        }
        $verifiedUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $tagged = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('tag', 'update', '--resource-id', $parsed.Id, '--operation', 'Merge', '--tags', ('{0}={1}' -f $names['DiskVerifiedUtc'], $verifiedUtc)) -AllowFailure
        $diskStatus = if ($tagged.ExitCode -eq 0 -and $deleted.ExitCode -eq 0) { 'Pass' } else { 'Warning' }
        & $add 'GOLDEN.CAPTURE.DISKVERIFY' $diskStatus ('A disk created from {0} succeeded in {1} seconds{2}.' -f $snapshotName, $diskSeconds, $(if ($deleted.ExitCode -ne 0) { '; its test disk wasn''t deleted, so delete it by hand' } elseif ($tagged.ExitCode -ne 0) { '; the disk-verified tag wasn''t written' } else { ' and was deleted' })) @{ seconds = $diskSeconds; testDisk = $diskName }

        $older = @(Get-DemoT2GoldenSnapshot -Config $Config -NowUtc $NowUtc | Where-Object { $_.Name -ne $snapshotName })
        $olderStatus = if ($older.Count -gt 0) { 'Pass' } else { 'Not selected' }
        & $add 'GOLDEN.CAPTURE.PREVIOUS' $olderStatus $(if ($older.Count -gt 0) { '{0} older golden snapshot(s) stay until {1} is boot-verified: {2}.' -f $older.Count, $snapshotName, (($older | ForEach-Object { $_.Name }) -join ', ') } else { 'No older golden snapshot.' })
        & $add 'GOLDEN.CAPTURE' 'Pass' ('{0} is captured and disk-verified. Prove it boots before relying on it: ./scripts/test-t2-golden.ps1 -SnapshotName {0} -Onboard.' -f $snapshotName) ([ordered]@{ snapshot = $snapshotName; group = $goldenGroup })
    }
    try {
        $null = & $captureSteps
    }
    finally {
        if ($capture['Prepared']) {
            $airGap = if ($null -ne $capture['AirGapUtc']) { $capture['AirGapUtc'] } else { [DateTime]::UtcNow }
            $source = Restore-DemoGoldenCaptureSource -Config $Config -FoundPowerState $foundPower -AirGapUtc $airGap
            $results.Add($source)
            Write-DemoLog -Level $(if ($source.status -eq 'Pass') { 'Info' } else { 'Warning' }) -Message ('GOLDEN.CAPTURE.SOURCE {0}: {1}' -f $source.status, $source.message)
        }
    }
    return $results.ToArray()
}
