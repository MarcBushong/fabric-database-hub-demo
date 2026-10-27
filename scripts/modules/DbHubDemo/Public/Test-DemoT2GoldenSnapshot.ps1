function Test-DemoT2GoldenSnapshot {
    <#
    .SYNOPSIS
    Proves a T2 golden snapshot in quarantine (ADR 0018 section 6, guardrail 8): a disk from it, a copy that
    boots isolated, its Arc identity reset, SQL Server Standard running, and with -Onboard a fresh onboarding
    with pay-as-you-go and monitoring. test-t2-golden.ps1 calls it.

    .DESCRIPTION
    Everything happens in a disposable resource group, rg-<prefix>-<TestEnvironment> (rg-<prefix>-gtest by
    default), never in the demo's group:
    1. The subscription guard; the test environment differs from the demo's, golden, and control; the snapshot
       (the newest, or -SnapshotName) is tagged t2-golden for this prefix, in the configured region, with
       network access DenyAll and its guest's Windows evaluation not over; the test group doesn't exist yet;
       vCPU quota covers one more host.
    2. Reads the source's Arc machine (the snapshot's dbhubArcIdentity tag) before anything starts.
    3. Creates the test group (the standard tags, a new deploymentId, expiresOn tomorrow, and
       ArcSQLServerExtensionDeployment PAYG like the demo's group), then a disk from the snapshot in it, which
       must succeed, and deletes that disk.
    4. Deploys infra/golden-test.bicep: a network whose host subnet's network security group denies all
       outbound traffic (Deny-Quarantine-Outbound) before the copy's first boot, and archost01 with its OS disk
       copied from the snapshot. The copy's guest doesn't start on its own and has no network (the air gap).
    5. Rotates the copy's host administrator password (the built-in account; an attached disk has no
       osProfile), and checks the snapshot's air gap as the copy booted (the guest off, no automatic start,
       its adapter disconnected; read-only). Then it runs the golden Release with ProveIsolation: the guest
       starts, its adapter is connected behind the deny rule, and 'azcmagent check' and direct TCP tests must
       find no endpoint reachable; then the Arc extensions are removed locally, 'azcmagent disconnect
       --force-local-only' runs, SQL Server must run Standard edition, and the guest's password is rotated.
       Then vm/bootstrap/Invoke-DemoSignInResidue.ps1 checks the copy's host and guest for sign-in data without
       changing anything (GOLDEN.TEST.SIGNIN, ADR 0009): any found fails the test, so the snapshot isn't tagged
       and isn't onboarded. The snapshot is tagged boot-verified.
    6. -Onboard: deletes the deny rule and runs configure-arc's sequence for the test environment
       (Invoke-DemoArcConfiguration -Force): onboarding, the Azure extension for SQL Server, license type PAYG,
       and monitoring; T2.ARC.SQLEXTENSION, T2.ARC.SQLINSTANCE, and T2.ARC.MONITORING must pass. With
       assignRoles = true, step 4 also creates the test group's own onboarding identity, id-<prefix>-<env>-arc-onboard
       with Azure Connected Machine Onboarding on the test group, attached to the copy, so the onboarding uses it
       and not the caller's token (ADR 0009); otherwise the caller's short-lived token is used. Onboarding passes,
       or warns only about sign-in data the sweep after it removed. The snapshot is tagged onboard-verified.
    7. Reads the source's Arc machine again, and its Activity Log for the test's window: the same machine ID,
       not Connected (a status change during the window may only be its decay to Disconnected, because its
       host is deallocated), and no operation on it, or GOLDEN.TEST.SOURCE fails.
    8. Deletes the test group with the destroy path (Remove-DemoEnvironment: Arc resources first, then the
       group, then the residual check), unless -KeepTestGroup. When the tested snapshot is the newest and
       passed (boot-verified, and onboard-verified with -Onboard), older golden snapshots of the prefix are
       deleted (ADR 0018 section 4, replacement).
    -CleanupOnly runs only step 8's deletion, for a test group an interruption left behind; it deletes only a
    group tagged purpose t2-golden-boot-test. -WhatIf runs step 1 only.

    Sources (checked 2026-10-22):
    - azcmagent disconnect --force-local-only: https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-disconnect
    - azcmagent check: https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-check
    - Network security groups (Azure DNS and the wire server aren't filtered): https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview
    - az disk create: https://learn.microsoft.com/cli/azure/disk#az-disk-create
    - az deployment group create: https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-create
    - az monitor activity-log list: https://learn.microsoft.com/cli/azure/monitor/activity-log#az-monitor-activity-log-list

    .PARAMETER Config
    Configuration from Get-DemoConfig (the demo's; the test environment is derived from it).

    .PARAMETER SnapshotName
    The golden snapshot to prove; the newest one by default.

    .PARAMETER Onboard
    After the boot test, open outbound access and onboard the copy fresh in the test group.

    .PARAMETER TestEnvironment
    The test environment's name (2 to 8 lowercase letters or digits); the group is rg-<prefix>-<name>.

    .PARAMETER KeepOlderSnapshots
    Keep older golden snapshots even when this one passes, for example until someone approves deleting them.

    .PARAMETER KeepTestGroup
    Leave the test group for inspection (delete it later with -CleanupOnly).

    .PARAMETER CleanupOnly
    Only delete a test group an earlier, interrupted run left behind.

    .PARAMETER ArcWaitMinutes
    How long configure-arc's sequence waits for the extension and the SQL Server instance resource.

    .PARAMETER NowUtc
    The time the evaluation days left and expiresOn are counted from.

    .EXAMPLE
    Test-DemoT2GoldenSnapshot -Config $config -Onboard -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')]
        [string] $SnapshotName = '',

        [switch] $Onboard,

        [ValidatePattern('^[a-z0-9]{2,8}$')]
        [string] $TestEnvironment = 'gtest',

        [switch] $KeepTestGroup,

        [switch] $KeepOlderSnapshots,

        [switch] $CleanupOnly,

        [ValidateRange(5, 120)]
        [int] $ArcWaitMinutes = 45,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $docUrl = 'https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-disconnect'
    $testConfig = [ordered]@{}
    foreach ($key in $Config.Keys) {
        $testConfig[$key] = $Config[$key]
    }
    $testConfig['environment'] = $TestEnvironment
    $testGroup = Get-DemoResourceGroupName -Config $testConfig
    $action = if ($CleanupOnly) { 'Delete the golden boot test''s resource group and check for residue' } else { 'Restore a copy of the golden snapshot in quarantine, prove it''s isolated, reset its Arc identity, check SQL Server, {0}then delete the test group' -f $(if ($Onboard) { 'onboard it fresh, ' } else { '' }) }
    # One confirmation, asked first; nested commands then run without prompting (as in New-DemoT2GoldenSnapshot).
    $proceed = $PSCmdlet.ShouldProcess($testGroup, $action)
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
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing was created. Sign in yourself and run test-t2-golden.ps1 again.'))
        return $results.ToArray()
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $location = [string]$Config['location']
    $prefix = [string]$Config['prefix']
    $reserved = @((Get-DemoResourceGroupName -Config $Config), (Get-DemoGoldenResourceGroupName -Config $Config), ('rg-{0}-control' -f $prefix))
    if ($TestEnvironment -in @([string]$Config['environment'], 'golden', 'control') -or $testGroup -in $reserved) {
        & $add 'GOLDEN.TEST.ENVIRONMENT' 'Fail' ('The test environment ''{0}'' would use {1}, which belongs to the demo, the golden snapshots, or the control identity.' -f $TestEnvironment, $testGroup) @{} 'Pick another -TestEnvironment (the default is gtest).'
        return $results.ToArray()
    }
    $purpose = 't2-golden-boot-test'

    # Deletes the test group through the destroy path, only when it's the boot test's own group.
    $teardown = {
        $exists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $testGroup) -AllowFailure
        if (([string]$exists.StdOut).Trim() -ne 'true') {
            & $add 'GOLDEN.TEST.TEARDOWN' 'Pass' ('{0} doesn''t exist; nothing to delete.' -f $testGroup)
            return
        }
        $groupTags = Get-DemoResourceGroupTag -SubscriptionId $subscriptionId -ResourceGroupName $testGroup
        if ([string]$groupTags['purpose'] -ne $purpose) {
            & $add 'GOLDEN.TEST.TEARDOWN' 'Fail' ('{0} exists but isn''t tagged purpose {1}, so it wasn''t deleted.' -f $testGroup, $purpose) @{} 'Check what the group holds; delete it yourself if it''s a leftover, or pick another -TestEnvironment.'
            return
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        # The copy holds nothing of its own (it came from the snapshot), so the wizard-state guard doesn't apply.
        $removed = @(Remove-DemoEnvironment -Config $testConfig -WaitMinutes 45 -ResidueWaitMinutes 10 -WithoutGolden -Confirm:$false)
        foreach ($item in $removed) {
            if ([string]$item.checkId -notin 'PREFLIGHT.GUARD.CONTEXT', 'DESTROY.GOLDEN.GUARD') {
                $results.Add($item)
            }
        }
        $residual = $removed | Where-Object { [string]$_.checkId -eq 'DESTROY.RESIDUAL' } | Select-Object -Last 1
        $group = $removed | Where-Object { [string]$_.checkId -eq 'DESTROY.RESOURCEGROUP' } | Select-Object -Last 1
        $status = if ($null -ne $residual) { [string]$residual.status } elseif ($null -ne $group) { [string]$group.status } else { 'Fail' }
        $state['Timing']['teardownSeconds'] = [int]$watch.Elapsed.TotalSeconds
        & $add 'GOLDEN.TEST.TEARDOWN' $status ('{0} was deleted through the destroy path in {1:N0} seconds; residual check: {2}.' -f $testGroup, $watch.Elapsed.TotalSeconds, $(if ($null -ne $residual) { $residual.status } else { 'not run' })) ([ordered]@{ seconds = [int]$watch.Elapsed.TotalSeconds }) $(if ($status -eq 'Pass') { '' } else { 'Run ./scripts/test-t2-golden.ps1 -CleanupOnly again, or read the DESTROY results.' })
    }
    $state = @{ Timing = [ordered]@{} }

    if ($CleanupOnly) {
        if (-not $proceed) {
            & $add 'GOLDEN.TEST.TEARDOWN' 'Not selected' ('What if: {0} wasn''t deleted.' -f $testGroup)
            return $results.ToArray()
        }
        & $teardown
        return $results.ToArray()
    }

    # 1. The snapshot, the group, and quota.
    $snapshots = @(Get-DemoT2GoldenSnapshot -Config $Config -NowUtc $NowUtc)
    $snapshot = if ($SnapshotName) { $snapshots | Where-Object { $_.Name -eq $SnapshotName } | Select-Object -First 1 } else { $snapshots | Select-Object -First 1 }
    if ($null -eq $snapshot) {
        & $add 'GOLDEN.TEST.SNAPSHOT' 'Fail' $(if ($SnapshotName) { 'No golden snapshot named {0} in {1}.' -f $SnapshotName, (Get-DemoGoldenResourceGroupName -Config $Config) } else { 'No golden snapshot in {0}.' -f (Get-DemoGoldenResourceGroupName -Config $Config) }) @{} 'Capture one first: ./scripts/capture-t2-golden.ps1.'
        return $results.ToArray()
    }
    $snapshotEvidence = [ordered]@{ name = $snapshot.Name; capturedUtc = $snapshot.CapturedUtc; evalDaysLeft = $snapshot.EvalDaysLeft; sku = $snapshot.Sku; sizeGiB = $snapshot.SizeGiB; diskVerifiedUtc = $snapshot.DiskVerifiedUtc; hostSize = $snapshot.HostSize; sqlVersion = $snapshot.SqlVersion }
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($snapshot.Location -ne $location) { $problems.Add(('it''s in {0}, not {1}' -f $snapshot.Location, $location)) }
    if ($snapshot.NetworkAccessPolicy -ne 'DenyAll') { $problems.Add(('its network access is {0}, not DenyAll' -f $snapshot.NetworkAccessPolicy)) }
    if ($snapshot.ProvisioningState -and $snapshot.ProvisioningState -ne 'Succeeded') { $problems.Add(('it''s {0}' -f $snapshot.ProvisioningState)) }
    if ($null -eq $snapshot.EvalDaysLeft -or $snapshot.EvalDaysLeft -lt 1) { $problems.Add('its guest''s Windows evaluation is over or unknown') }
    if ($problems.Count -gt 0) {
        & $add 'GOLDEN.TEST.SNAPSHOT' 'Fail' ('{0} can''t be tested: {1}.' -f $snapshot.Name, ($problems -join '; ')) $snapshotEvidence 'Capture a new snapshot (./scripts/capture-t2-golden.ps1).'
        return $results.ToArray()
    }
    & $add 'GOLDEN.TEST.SNAPSHOT' 'Pass' ('{0}: captured {1:yyyy-MM-dd HH:mm} UTC, {2}, the guest''s evaluation ends in {3} days.' -f $snapshot.Name, $snapshot.CapturedUtc, $snapshot.Sku, $snapshot.EvalDaysLeft) $snapshotEvidence

    $groupExists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $testGroup) -AllowFailure
    if (([string]$groupExists.StdOut).Trim() -eq 'true') {
        & $add 'GOLDEN.TEST.GROUP' 'Fail' ('{0} already exists, so a copy could already be running there.' -f $testGroup) @{} 'Delete it first: ./scripts/test-t2-golden.ps1 -CleanupOnly.'
        return $results.ToArray()
    }

    $hostSizing = (Get-DemoProfile).profiles[[string]$Config['profile']].t2Host
    $hostSize = if ($snapshot.HostSize) { $snapshot.HostSize } else { [string]$hostSizing.size }
    $needed = [ordered]@{ cores = [int]$hostSizing.vcpus }
    if ($hostSize -eq [string]$hostSizing.size -and $hostSizing.family) {
        $needed[[string]$hostSizing.family] = [int]$hostSizing.vcpus
    }
    $usage = @(Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'list-usage', '--location', $location, '--output', 'json') -AsJson -AllowFailure)
    $short = @(foreach ($name in $needed.Keys) {
            $row = $usage | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'name') -Name 'value') -eq $name } | Select-Object -First 1
            $free = if ($null -ne $row) { [int](Get-DemoMemberValue -InputObject $row -Name 'limit') - [int](Get-DemoMemberValue -InputObject $row -Name 'currentValue') } else { 0 }
            if ($free -lt $needed[$name]) {
                '{0} (need {1}, free {2})' -f $name, $needed[$name], $free
            }
        })
    if ($short.Count -gt 0) {
        & $add 'GOLDEN.TEST.QUOTA' 'Fail' ('Not enough vCPU quota in {0} for the test host: {1}.' -f $location, ($short -join '; ')) @{} 'Deallocate a VM or request more quota, then run the test again.'
        return $results.ToArray()
    }
    & $add 'GOLDEN.TEST.QUOTA' 'Pass' ('vCPU quota in {0} covers one more {1}.' -f $location, $hostSize)

    if (-not $proceed) {
        & $add 'GOLDEN.TEST' 'Not selected' ('What if: nothing was created. The test would restore {0} into {1}.' -f $snapshot.Name, $testGroup)
        return $results.ToArray()
    }

    # 2. The source's Arc machine, before.
    $sourceGroup = Get-DemoResourceGroupName -Config $Config
    $sourceName = 'arcsql01'
    if ($snapshot.ArcIdentity -match '^(?<group>[A-Za-z0-9._()-]{1,90})/(?<name>[A-Za-z0-9-]{1,63})$') {
        $sourceGroup = $Matches['group']
        $sourceName = $Matches['name']
    }
    $sourceId = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.HybridCompute/machines/{2}' -f $subscriptionId, $sourceGroup, $sourceName
    $sourceUrl = 'https://management.azure.com{0}?api-version={1}' -f $sourceId, (Get-DemoArcSetting).MachineApiVersion
    $toUtc = {
        param($Value)
        if ($Value -is [datetime]) {
            return $Value.ToUniversalTime()
        }
        $parsed = [datetime]::MinValue
        if ($Value -and [datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
            return $parsed
        }
        return $null
    }
    $readSource = {
        $machine = Get-DemoArcArmResource -SubscriptionId $subscriptionId -Url $sourceUrl
        if ($null -eq $machine) {
            return [ordered]@{ exists = $false }
        }
        $properties = Get-DemoMemberValue -InputObject $machine -Name 'properties'
        $changed = & $toUtc (Get-DemoMemberValue -InputObject $properties -Name 'lastStatusChange')
        return [ordered]@{
            exists              = $true
            status              = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
            lastStatusChangeUtc = $(if ($null -ne $changed) { $changed.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' })
            vmId                = [string](Get-DemoMemberValue -InputObject $properties -Name 'vmId')
            agentVersion        = [string](Get-DemoMemberValue -InputObject $properties -Name 'agentVersion')
            provisioningState   = [string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState')
        }
    }
    $sourceBefore = $null
    try {
        $sourceBefore = & $readSource
    }
    catch {
        & $add 'GOLDEN.TEST.SOURCE' 'Fail' ('The source''s Arc machine couldn''t be read before the test: {0}' -f $_.Exception.Message) @{} 'Nothing was created. Run the test again.'
        return $results.ToArray()
    }
    $windowStart = [DateTime]::UtcNow
    $total = [System.Diagnostics.Stopwatch]::StartNew()

    $steps = {
        $timing = $state['Timing']
        $tagValue = {
            param([string] $Value)
            ([string]$Value) -replace '[^A-Za-z0-9._:/@+=,_-]', '-'
        }
        # 3. The group, then a disk from the snapshot (G2).
        $groupTags = [ordered]@{
            solution                        = 'fabric-database-hub-demo'
            environment                     = $TestEnvironment
            owner                           = & $tagValue ([string]$Config['owner'])
            purpose                         = $purpose
            costCenter                      = & $tagValue $(if ($Config['costCenter']) { [string]$Config['costCenter'] } else { 'demo' })
            deploymentId                    = ([guid]::NewGuid().ToString('N')).Substring(0, 6)
            expiresOn                       = $NowUtc.ToUniversalTime().AddDays(1).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            ArcSQLServerExtensionDeployment = 'PAYG'
            dbhubPrefix                     = $prefix
            dbhubGoldenSnapshot             = $snapshot.Name
        }
        $created = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList (@('group', 'create', '--name', $testGroup, '--location', $location, '--tags') + (ConvertTo-DemoTagArgument -Tag $groupTags)) -AllowFailure
        if ($created.ExitCode -ne 0) {
            & $add 'GOLDEN.TEST.GROUP' 'Fail' ('{0} couldn''t be created: {1}' -f $testGroup, (Get-DemoDeploymentErrorText -Text $created.StdErr -MaxLength 400))
            return
        }
        & $add 'GOLDEN.TEST.GROUP' 'Pass' ('Created {0} (deploymentId {1}, expires {2}).' -f $testGroup, $groupTags['deploymentId'], $groupTags['expiresOn']) ([ordered]@{ group = $testGroup; deploymentId = $groupTags['deploymentId'] })

        $diskName = '{0}-g2' -f $snapshot.Name
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $disk = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList (@('disk', 'create', '--resource-group', $testGroup, '--name', $diskName, '--location', $location, '--source', $snapshot.Id, '--sku', 'Standard_LRS', '--network-access-policy', 'DenyAll', '--public-network-access', 'Disabled', '--output', 'json', '--tags') + (ConvertTo-DemoTagArgument -Tag $groupTags)) -AllowFailure
        $diskObject = if ($disk.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$disk.StdOut)) { [string]$disk.StdOut | ConvertFrom-Json -Depth 32 } else { $null }
        $diskState = [string](Get-DemoMemberValue -InputObject $diskObject -Name 'provisioningState')
        $timing['diskSeconds'] = [int]$watch.Elapsed.TotalSeconds
        $diskDeleted = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('disk', 'delete', '--resource-group', $testGroup, '--name', $diskName, '--yes') -AllowFailure
        if ($diskState -ne 'Succeeded') {
            & $add 'GOLDEN.TEST.DISK' 'Fail' ('A disk couldn''t be created from {0} in {1} (state ''{2}''): {3}' -f $snapshot.Name, $testGroup, $diskState, (Get-DemoDeploymentErrorText -Text $disk.StdErr -MaxLength 400)) ([ordered]@{ seconds = $timing['diskSeconds'] }) 'Don''t rely on this snapshot; capture again.'
            return
        }
        & $add 'GOLDEN.TEST.DISK' 'Pass' ('A disk created from {0} in {1} succeeded in {2} seconds{3}.' -f $snapshot.Name, $testGroup, $timing['diskSeconds'], $(if ($diskDeleted.ExitCode -eq 0) { ' and was deleted' } else { '; the group''s deletion removes it' })) ([ordered]@{ seconds = $timing['diskSeconds']; sku = 'Standard_LRS'; networkAccessPolicy = 'DenyAll' })

        # 4. The quarantined network and the copy.
        $parameters = [ordered]@{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = [ordered]@{
                location                = @{ value = $location }
                prefix                  = @{ value = $prefix }
                environment             = @{ value = $TestEnvironment }
                tags                    = @{ value = $groupTags }
                osDiskSourceResourceId  = @{ value = $snapshot.Id }
                profile                 = @{ value = [string]$Config['profile'] }
                hostVmSize              = @{ value = $hostSize }
                quarantineHostOutbound  = @{ value = $true }
                # The copy onboards with its own host identity when the caller may create role assignments (-Onboard only).
                assignArcOnboardingRole = @{ value = ([bool]$Config['assignRoles'] -and [bool]$Onboard) }
                autoShutdownTime        = @{ value = [string]$Config['autoShutdownTime'] }
                autoShutdownTimeZone    = @{ value = [string]$Config['autoShutdownTimeZone'] }
            }
        }
        $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-goldentest'
        $watch.Restart()
        try {
            $path = Write-DemoPrivateFile -Directory $directory -Name 'golden-test.parameters.json' -Content ($parameters | ConvertTo-Json -Depth 10)
            Write-DemoLog -Message ('Deploying the quarantined copy of {0} into {1}.' -f $snapshot.Name, $testGroup)
            $deploy = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('deployment', 'group', 'create', '--resource-group', $testGroup, '--name', ('golden-test-{0}' -f $NowUtc.ToUniversalTime().ToString('yyyyMMddHHmm', [System.Globalization.CultureInfo]::InvariantCulture)), '--template-file', (Join-Path -Path $script:RepoRoot -ChildPath 'infra/golden-test.bicep'), '--parameters', "@$path", '--output', 'none') -AllowFailure
        }
        finally {
            Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
        }
        $timing['deploySeconds'] = [int]$watch.Elapsed.TotalSeconds
        if ($deploy.ExitCode -ne 0) {
            & $add 'GOLDEN.TEST.DEPLOY' 'Fail' ('The quarantined copy wasn''t deployed: {0}' -f (Get-DemoDeploymentErrorText -Text $deploy.StdErr -MaxLength 600)) ([ordered]@{ seconds = $timing['deploySeconds'] })
            return
        }
        $rule = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('network', 'nsg', 'rule', 'show', '--resource-group', $testGroup, '--nsg-name', ('nsg-{0}-{1}-archost' -f $prefix, $TestEnvironment), '--name', 'Deny-Quarantine-Outbound', '--output', 'json') -AsJson -AllowFailure
        $ruleOk = $null -ne $rule -and [string](Get-DemoMemberValue -InputObject $rule -Name 'access') -eq 'Deny' -and [string](Get-DemoMemberValue -InputObject $rule -Name 'direction') -eq 'Outbound' -and [string](Get-DemoMemberValue -InputObject $rule -Name 'destinationAddressPrefix') -eq '*'
        if (-not $ruleOk) {
            & $add 'GOLDEN.TEST.DEPLOY' 'Fail' 'The copy is deployed, but its subnet''s deny-all outbound rule couldn''t be confirmed, so it isn''t started further.' ([ordered]@{ seconds = $timing['deploySeconds'] })
            return
        }
        & $add 'GOLDEN.TEST.DEPLOY' 'Pass' ('The copy and its quarantined network are deployed in {0} seconds; Deny-Quarantine-Outbound (priority {1}) denies all outbound traffic from the host''s subnet.' -f $timing['deploySeconds'], (Get-DemoMemberValue -InputObject $rule -Name 'priority')) ([ordered]@{ seconds = $timing['deploySeconds']; rulePriority = Get-DemoMemberValue -InputObject $rule -Name 'priority' })

        # 5. The host's password, then the guest's isolation, reset, SQL Server, and password.
        $watch.Restart()
        $ready = Wait-DemoVmAgentReady -SubscriptionId $subscriptionId -ResourceGroupName $testGroup -VmName 'archost01' -TimeoutMinutes 20
        $timing['agentReadySeconds'] = $ready
        $password = Set-DemoVmLocalPassword -Config $testConfig -VmName 'archost01' -Rotate -Confirm:$false
        $timing['hostPasswordSeconds'] = [int]$watch.Elapsed.TotalSeconds - [System.Math]::Max(0, $ready)
        $results.Add($password)
        # A Warning: the password is rotated, and the Windows PowerShell log that recorded it was cleared (Phase 26f).
        if ($password.status -notin 'Pass', 'Warning') {
            & $add 'GOLDEN.TEST.HOSTPASSWORD' 'Fail' 'The copy''s host administrator password wasn''t rotated, so its guest wasn''t started (guardrail 5).' @{} $password.remediation
            return
        }
        # The snapshot's air gap, as the copy booted (read-only): the guest off, no automatic start, adapter disconnected.
        $airGap = Invoke-DemoGoldenGuestAction -Config $testConfig -Action 'Inspect' -TimeoutSeconds 900
        $hostFacts = Get-DemoMemberValue -InputObject $airGap.Data -Name 'host'
        $airGapEvidence = [ordered]@{
            guestState             = [string](Get-DemoMemberValue -InputObject $hostFacts -Name 'guestState')
            guestStartAction       = [string](Get-DemoMemberValue -InputObject $hostFacts -Name 'guestStartAction')
            adapterConnected       = [int](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $hostFacts -Name 'guestAdapter') -Name 'connected')
            captureRecord          = [bool](Get-DemoMemberValue -InputObject $hostFacts -Name 'captureRecord')
            hostPasswordLastSetUtc = [string](Get-DemoMemberValue -InputObject $hostFacts -Name 'administratorPasswordLastSetUtc')
        }
        if (-not $airGap.Succeeded) {
            & $add 'GOLDEN.TEST.AIRGAP' 'Fail' ('The copy''s host couldn''t be inspected: {0}' -f $airGap.Error) $airGapEvidence
            return
        }
        if ($airGapEvidence['adapterConnected'] -gt 0 -or -not $airGapEvidence['captureRecord']) {
            & $add 'GOLDEN.TEST.AIRGAP' 'Fail' ('The copy booted without the air gap (adapter connected: {0}, capture record: {1}), so a restore outside quarantine could reach Azure as the captured machine. Don''t restore this snapshot.' -f $airGapEvidence['adapterConnected'], $airGapEvidence['captureRecord']) $airGapEvidence 'Capture a new snapshot (./scripts/capture-t2-golden.ps1), then test it again.'
            return
        }
        if ($airGapEvidence['guestStartAction'] -ne 'Nothing' -or $airGapEvidence['guestState'] -ne 'Off') {
            & $add 'GOLDEN.TEST.AIRGAP' 'Warning' ('The copy''s guest adapter is disconnected, but its guest is {0} with automatic start {1}: one layer of the air gap is missing.' -f $airGapEvidence['guestState'], $airGapEvidence['guestStartAction']) $airGapEvidence 'Re-capture when convenient; the disconnected adapter still isolates a copy.'
        }
        else {
            & $add 'GOLDEN.TEST.AIRGAP' 'Pass' 'The copy booted with its guest off, no automatic start, and the guest''s adapter disconnected (the air gap the capture wrote).' $airGapEvidence
        }
        $watch.Restart()
        $release = Invoke-DemoGoldenGuestAction -Config $testConfig -Action 'Release' -Parameter @{ ProveIsolation = 'true'; Region = $location } -TimeoutSeconds 3600
        $timing['releaseSeconds'] = [int]$watch.Elapsed.TotalSeconds
        $data = $release.Data
        $isolation = Get-DemoMemberValue -InputObject $data -Name 'isolation'
        $role = [string](Get-DemoMemberValue -InputObject $data -Name 'role')
        $timing['guestBootSeconds'] = Get-DemoMemberValue -InputObject $data -Name 'guestBootSeconds'
        if ($null -ne $isolation) {
            $reachableValue = Get-DemoMemberValue -InputObject $isolation -Name 'reachable'
            $checkValue = Get-DemoMemberValue -InputObject $isolation -Name 'checkReachable'
            $reachable = @(@($reachableValue) + @($checkValue) | Where-Object { $_ })
            $isolationEvidence = [ordered]@{ tested = Get-DemoMemberValue -InputObject $isolation -Name 'tested'; reachable = $reachable; checkExitCode = Get-DemoMemberValue -InputObject $isolation -Name 'checkExitCode'; checkSample = Get-DemoMemberValue -InputObject $isolation -Name 'checkSample' }
            if ($reachable.Count -gt 0) {
                & $add 'GOLDEN.TEST.ISOLATION' 'Fail' ('From the quarantined guest, {0} answered; nothing was reset, and the guest''s adapter was disconnected again.' -f ($reachable -join ', ')) $isolationEvidence 'Check the test network''s deny rule; never onboard a copy that can reach Azure before its reset.'
                return
            }
            & $add 'GOLDEN.TEST.ISOLATION' 'Pass' ('From the quarantined guest, none of {0} endpoints answered on TCP 443, and azcmagent check found none reachable.' -f $isolationEvidence['tested']) $isolationEvidence
        }
        if (-not $release.Succeeded) {
            & $add 'GOLDEN.TEST.RESET' 'Fail' ('The copy''s release failed: {0}' -f $release.Error) ([ordered]@{ seconds = $timing['releaseSeconds']; role = $role }) 'Read the error; the test group is deleted, so nothing stays connected.'
            return
        }
        if ($role -ne 'Copy') {
            & $add 'GOLDEN.TEST.RESET' 'Fail' ('The restored host reports role ''{0}'', not Copy: its Azure VM ID matched the source''s capture record.' -f $role) ([ordered]@{ role = $role })
            return
        }
        $reset = Get-DemoMemberValue -InputObject $data -Name 'reset'
        $agentAfter = Get-DemoMemberValue -InputObject $reset -Name 'agentAfter'
        $agentBefore = Get-DemoMemberValue -InputObject $data -Name 'agentBefore'
        $resetEvidence = [ordered]@{
            agentBefore        = $agentBefore
            steps              = Get-DemoMemberValue -InputObject $reset -Name 'steps'
            removeExitCode     = Get-DemoMemberValue -InputObject $reset -Name 'removeExitCode'
            disconnectExitCode = Get-DemoMemberValue -InputObject $reset -Name 'disconnectExitCode'
            agentAfter         = $agentAfter
            markerRenamed      = Get-DemoMemberValue -InputObject $data -Name 'markerRenamed'
            seconds            = $timing['releaseSeconds']
        }
        if ($reset -is [string] -or $null -eq $agentAfter) {
            & $add 'GOLDEN.TEST.RESET' 'Fail' ('The copy''s agent wasn''t reset ({0}); a copy of the captured guest must hold the captured identity until its reset.' -f $reset) $resetEvidence
            return
        }
        if ([string](Get-DemoMemberValue -InputObject $agentAfter -Name 'resourceName')) {
            & $add 'GOLDEN.TEST.RESET' 'Fail' 'The copy''s agent still names a resource after azcmagent disconnect --force-local-only.' $resetEvidence
            return
        }
        & $add 'GOLDEN.TEST.RESET' 'Pass' ('The copy held {0} and was reset locally: extensions removed (exit {1}), azcmagent disconnect --force-local-only (exit {2}), and the agent now names no resource.' -f [string](Get-DemoMemberValue -InputObject $agentBefore -Name 'resourceName'), $resetEvidence['removeExitCode'], $resetEvidence['disconnectExitCode']) $resetEvidence
        $sqlEvidence = [ordered]@{ sqlService = Get-DemoMemberValue -InputObject $data -Name 'sqlService'; sqlEdition = Get-DemoMemberValue -InputObject $data -Name 'sqlEdition'; sqlWait = Get-DemoMemberValue -InputObject $data -Name 'sqlWait'; guestBootSeconds = $timing['guestBootSeconds'] }
        & $add 'GOLDEN.TEST.SQL' 'Pass' ('SQL Server runs {0} in the copy''s guest.' -f $sqlEvidence['sqlEdition']) $sqlEvidence
        $guestPassword = [string](Get-DemoMemberValue -InputObject $data -Name 'guestPassword')
        & $add 'GOLDEN.TEST.GUESTPASSWORD' $(if ($guestPassword -eq 'Rotated') { 'Pass' } else { 'Fail' }) $(if ($guestPassword -eq 'Rotated') { 'The guest administrator''s password was rotated before the guest reached the network (guardrail 5).' } else { 'The guest administrator''s password wasn''t rotated.' })
        # The copy must hold no sign-in data (ADR 0009): a sweep of its host and guest that changes nothing.
        $watch.Restart()
        $sweep = Invoke-DemoSignInDataAction -Config $testConfig -VmName 'archost01' -Action 'Scan' -Scope 'Both'
        $signIn = Get-DemoSignInDataResult -CheckId 'GOLDEN.TEST.SIGNIN' -Area 't2' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $sweep -Remediation 'Don''t rely on this snapshot: capture a new one (./scripts/capture-t2-golden.ps1 captures only after the sign-in data check passes).'
        $results.Add($signIn)
        $timing['signInSeconds'] = [int]$watch.Elapsed.TotalSeconds
        $names = Get-DemoGoldenTagName
        $bootUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $state['BootVerified'] = $guestPassword -eq 'Rotated' -and $signIn.status -ne 'Fail'
        if (-not $state['BootVerified']) {
            & $add 'GOLDEN.TEST.BOOT' 'Fail' ('{0} wasn''t tagged boot-verified: {1}.' -f $snapshot.Name, $(if ($signIn.status -eq 'Fail') { 'its copy holds sign-in data' } else { 'the guest password wasn''t rotated' }))
            return
        }
        $tagged = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('tag', 'update', '--resource-id', $snapshot.Id, '--operation', 'Merge', '--tags', ('{0}={1}' -f $names['BootVerifiedUtc'], $bootUtc)) -AllowFailure
        & $add 'GOLDEN.TEST.BOOT' $(if ($tagged.ExitCode -eq 0) { 'Pass' } else { 'Warning' }) ('{0} boots in quarantine with SQL Server Standard running and no sign-in data{1}.' -f $snapshot.Name, $(if ($tagged.ExitCode -eq 0) { '; tagged boot-verified' } else { '; the boot-verified tag wasn''t written' })) ([ordered]@{ bootVerifiedUtc = $bootUtc })
        if (-not $Onboard) {
            return
        }

        # 6. Outbound open, then a fresh onboarding in the test group.
        $opened = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('network', 'nsg', 'rule', 'delete', '--resource-group', $testGroup, '--nsg-name', ('nsg-{0}-{1}-archost' -f $prefix, $TestEnvironment), '--name', 'Deny-Quarantine-Outbound') -AllowFailure
        if ($opened.ExitCode -ne 0) {
            & $add 'GOLDEN.TEST.OPEN' 'Fail' ('The deny rule couldn''t be deleted: {0}' -f (Get-DemoDeploymentErrorText -Text $opened.StdErr -MaxLength 300))
            return
        }
        & $add 'GOLDEN.TEST.OPEN' 'Pass' 'Deleted Deny-Quarantine-Outbound: the reset copy may reach Azure now.'
        $watch.Restart()
        $configured = @(Invoke-DemoArcConfiguration -Config $testConfig -Force -WaitMinutes $ArcWaitMinutes -Confirm:$false)
        foreach ($item in $configured) {
            if ([string]$item.checkId -ne 'PREFLIGHT.GUARD.CONTEXT') {
                $results.Add($item)
            }
        }
        $checks = @(Get-DemoArcCheck -Config $testConfig -Check 'SqlExtension', 'SqlInstance', 'Monitoring')
        foreach ($item in $checks) {
            $results.Add($item)
        }
        $timing['onboardSeconds'] = [int]$watch.Elapsed.TotalSeconds
        $onboarding = $configured | Where-Object { [string]$_.checkId -eq 'T2.ARC.ONBOARDING' } | Select-Object -Last 1
        $failed = @($checks | Where-Object { $_.status -ne 'Pass' } | ForEach-Object { '{0} {1}' -f $_.checkId, $_.status })
        $onboardEvidence = if ($null -ne $onboarding) { $onboarding.evidence } else { $null }
        $tokenSource = [string](Get-DemoMemberValue -InputObject $onboardEvidence -Name 'tokenSource')
        # A Warning counts only when the machine is Connected: the sweep after onboarding cleared a log, or the agent
        # got the token on its command line once; both are reported in T2.ARC.ONBOARDING.
        $onboarded = $null -ne $onboarding -and ([string]$onboarding.status -eq 'Pass' -or ([string]$onboarding.status -eq 'Warning' -and [string](Get-DemoMemberValue -InputObject $onboardEvidence -Name 'azureStatus') -eq 'Connected'))
        if (-not $onboarded -or $failed.Count -gt 0) {
            & $add 'GOLDEN.TEST.ONBOARD' 'Fail' ('The reset copy wasn''t onboarded with Standard, PAYG, and monitoring: onboarding {0}{1}.' -f $(if ($null -ne $onboarding) { $onboarding.status } else { 'not run' }), $(if ($failed.Count) { '; ' + ($failed -join ', ') } else { '' })) ([ordered]@{ seconds = $timing['onboardSeconds'] })
            return
        }
        $onboardUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $tagged = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('tag', 'update', '--resource-id', $snapshot.Id, '--operation', 'Merge', '--tags', ('{0}={1}' -f $names['OnboardVerified'], $onboardUtc)) -AllowFailure
        $state['OnboardVerified'] = $true
        $with = switch ($tokenSource) { 'HostIdentity' { ' with the host identity' } 'Caller' { ' with your token' } default { '' } }
        & $add 'GOLDEN.TEST.ONBOARD' 'Pass' ('The reset copy was onboarded fresh in {0}{1} in {2:N0} minutes: Standard edition, license type PAYG, and monitoring on{3}.' -f $testGroup, $with, ($timing['onboardSeconds'] / 60), $(if ($tagged.ExitCode -eq 0) { '; tagged onboard-verified' } else { '; the onboard-verified tag wasn''t written' })) ([ordered]@{ seconds = $timing['onboardSeconds']; onboardVerifiedUtc = $onboardUtc; tokenSource = $tokenSource; onboardingStatus = [string]$onboarding.status })
    }

    try {
        & $steps
    }
    catch {
        & $add 'GOLDEN.TEST.ERROR' 'Fail' ('The test stopped: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    finally {
        # 7. The source, after.
        try {
            $sourceAfter = & $readSource
            $operations = @()
            $log = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('monitor', 'activity-log', 'list', '--resource-id', $sourceId, '--start-time', $windowStart.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture), '--query', '[].{operation: operationName.value, status: status.value, time: eventTimestamp}', '--output', 'json') -AsJson -AllowFailure
            if ($null -ne $log) {
                $operations = @($log | Where-Object { $null -ne $_ })
            }
            $sourceEvidence = [ordered]@{ before = $sourceBefore; after = $sourceAfter; operations = @($operations | Select-Object -First 10); windowStartUtc = $windowStart.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
            # Azure marks a machine Disconnected about 15 minutes after its last heartbeat, so a source captured just
            # before the test can still read Connected; a Connected source well past that has something heartbeating
            # as it. The capture shut the source's guest down before the disk check.
            $quietMinutes = if ($null -ne $snapshot.DiskVerifiedUtc) { [int]([DateTime]::UtcNow - $snapshot.DiskVerifiedUtc).TotalMinutes } else { 9999 }
            $sourceEvidence['minutesSinceCapture'] = $quietMinutes
            $sourceProblems = [System.Collections.Generic.List[string]]::new()
            $sourceNotes = [System.Collections.Generic.List[string]]::new()
            if ([bool]$sourceBefore['exists'] -ne [bool]$sourceAfter['exists']) { $sourceProblems.Add('it appeared or disappeared') }
            if ([bool]$sourceAfter['exists']) {
                $changedUtc = & $toUtc $sourceAfter['lastStatusChangeUtc']
                if ($sourceBefore['vmId'] -ne $sourceAfter['vmId']) { $sourceProblems.Add('its machine ID changed') }
                if ($sourceAfter['status'] -eq 'Connected' -and $null -ne $changedUtc -and $changedUtc -ge $windowStart) {
                    $sourceProblems.Add('it turned Connected during the test')
                }
                elseif ($sourceAfter['status'] -eq 'Connected' -and $quietMinutes -gt 20) {
                    $sourceProblems.Add(('it still reports Connected {0} minutes after its guest was shut down for the capture' -f $quietMinutes))
                }
                elseif ($sourceAfter['status'] -eq 'Connected') {
                    $sourceNotes.Add(('it still reads Connected only {0} minutes after the capture, before Azure marks it Disconnected (about 15 minutes without heartbeats)' -f $quietMinutes))
                }
            }
            if ($operations.Count -gt 0) { $sourceProblems.Add(('the Activity Log shows {0} operation(s) on it' -f $operations.Count)) }
            if ($sourceProblems.Count -gt 0) {
                & $add 'GOLDEN.TEST.SOURCE' 'Fail' ('The source''s Arc machine {0}/{1} may have been touched during the test: {2}.' -f $sourceGroup, $sourceName, ($sourceProblems -join '; ')) $sourceEvidence 'Compare the machine''s properties and Activity Log by hand before you rely on the source.'
            }
            elseif ($sourceNotes.Count -gt 0) {
                & $add 'GOLDEN.TEST.SOURCE' 'Warning' ('The source''s Arc machine {0}/{1} kept the same machine ID and has no operation in the Activity Log, but {2}.' -f $sourceGroup, $sourceName, ($sourceNotes -join '; ')) $sourceEvidence 'Read its status again in a few minutes: it must be Disconnected.'
            }
            else {
                & $add 'GOLDEN.TEST.SOURCE' 'Pass' ('The source''s Arc machine {0}/{1} is untouched: the same machine ID, {2}, and no operation in the Activity Log since {3:HH:mm} UTC.' -f $sourceGroup, $sourceName, $(if ($sourceAfter['exists']) { $sourceAfter['status'] } else { 'absent before and after' }), $windowStart) $sourceEvidence
            }
        }
        catch {
            & $add 'GOLDEN.TEST.SOURCE' 'Warning' ('The source''s Arc machine couldn''t be read after the test: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) @{} 'Read it and its Activity Log by hand.'
        }
        # 8. The test group.
        if ($KeepTestGroup) {
            & $add 'GOLDEN.TEST.TEARDOWN' 'Not selected' ('{0} was kept (-KeepTestGroup); delete it with ./scripts/test-t2-golden.ps1 -CleanupOnly.' -f $testGroup)
        }
        else {
            try {
                & $teardown
            }
            catch {
                & $add 'GOLDEN.TEST.TEARDOWN' 'Fail' ('Deleting {0} failed: {1}' -f $testGroup, (Protect-DemoText -Text $_.Exception.Message)) @{} 'Run ./scripts/test-t2-golden.ps1 -CleanupOnly.'
            }
        }
    }

    $failedChecks = @($results | Where-Object { $_.status -eq 'Fail' } | ForEach-Object { $_.checkId })
    $verified = [bool]$state['BootVerified'] -and (-not $Onboard -or [bool]$state['OnboardVerified'])
    if ($verified -and $failedChecks.Count -eq 0) {
        $newest = $snapshots | Select-Object -First 1
        $older = @($snapshots | Where-Object { $_.Name -ne $snapshot.Name -and ($null -eq $_.CapturedUtc -or $_.CapturedUtc -lt $snapshot.CapturedUtc) })
        if ($KeepOlderSnapshots -and $older.Count -gt 0) {
            & $add 'GOLDEN.TEST.PREVIOUS' 'Not selected' ('{0} older golden snapshot(s) were kept (-KeepOlderSnapshots): {1}.' -f $older.Count, (($older | ForEach-Object { $_.Name }) -join ', '))
        }
        elseif ($newest.Name -eq $snapshot.Name -and $older.Count -gt 0) {
            $removed = @(foreach ($item in $older) {
                    $gone = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('snapshot', 'delete', '--resource-group', (Get-DemoGoldenResourceGroupName -Config $Config), '--name', $item.Name) -AllowFailure
                    if ($gone.ExitCode -eq 0) { $item.Name }
                })
            & $add 'GOLDEN.TEST.PREVIOUS' $(if ($removed.Count -eq $older.Count) { 'Pass' } else { 'Warning' }) ('Deleted {0} of {1} older golden snapshot(s) now that {2} is verified: {3}.' -f $removed.Count, $older.Count, $snapshot.Name, ($removed -join ', '))
        }
        else {
            & $add 'GOLDEN.TEST.PREVIOUS' 'Not selected' 'No older golden snapshot to replace.'
        }
    }
    $state['Timing']['totalSeconds'] = [int]$total.Elapsed.TotalSeconds
    $failedChecks = @($results | Where-Object { $_.status -eq 'Fail' } | ForEach-Object { $_.checkId })
    $summaryStatus = if ($failedChecks.Count -gt 0) { 'Fail' } elseif ($verified) { 'Pass' } else { 'Warning' }
    $summaryMessage = switch ($summaryStatus) {
        'Pass' { '{0} is proven: it boots isolated, its copy resets its Arc identity, SQL Server Standard runs{1}, and the test group is gone.' -f $snapshot.Name, $(if ($Onboard) { ', and a fresh onboarding gives PAYG with monitoring' } else { '' }) }
        'Warning' { '{0} wasn''t fully verified; read the results above.' -f $snapshot.Name }
        default { '{0} failed its test: {1}.' -f $snapshot.Name, ($failedChecks -join ', ') }
    }
    & $add 'GOLDEN.TEST' $summaryStatus $summaryMessage ([ordered]@{ snapshot = $snapshot.Name; testGroup = $testGroup; onboard = [bool]$Onboard; arcWaitMinutes = $ArcWaitMinutes; timing = $state['Timing'] })
    return $results.ToArray()
}
