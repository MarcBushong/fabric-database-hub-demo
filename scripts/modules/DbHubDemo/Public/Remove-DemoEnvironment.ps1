function Remove-DemoEnvironment {
    <#
    .SYNOPSIS
    Destroys the demo: Arc resources first, then the resource group, then the subscription-scope deployment
    record, and checks that nothing is left (plan section 9.6, ADR 0002). destroy.ps1 and the destroy and
    expiry workflows call it.

    .DESCRIPTION
    1. Records, read-only, what the residual check needs once the group is gone (Get-DemoTeardownManifest: the
       deploymentId, the identities, the names), and writes it to -ManifestPath when given.
    2. Arc resources for the T2 guest are created by onboarding, not by the template, so they're deleted
       explicitly, children first: every Microsoft.AzureArcData/sqlServerInstances resource in the group (T1's
       unified-inventory instance too), then every Microsoft.HybridCompute/machines resource (its extensions go
       with it).
    3. 'az group delete' removes everything else, including T3 and the on-demand Bastion, and the function
       waits until the group is gone. T1's managed identity, and with it its membership in the P6 group, goes
       with the VM. With the Key Vault opt-in, the vault goes into soft delete with the group (DESTROY.KEYVAULT
       says for how long); a later deploy.ps1 recovers it.
    4. Deletes the subscription-scope deployment record dbhub-<environment>-main, which outlives the group and
       holds the template's parameters and outputs (DESTROY.DEPLOYMENT), and the budget at the group's scope,
       which outlives the group too (live, 2026-10-22; DESTROY.BUDGET).
    5. Test-DemoTeardownResidue checks that nothing is left: the group, anything carrying the environment's
       tags, Arc resources, role assignments, the identities and their P6 membership, deployments, and the
       budget (TEARDOWN.RESIDUAL.*). DESTROY.RESIDUAL sums it up: Pass only when every check is clean (ADR
       0002, step 5).
    The GitHub identity's resource group (rg-<prefix>-control) isn't touched. With fabric.manageCapacity true (Phase
    26b, ADR 0023), a Fabric capacity that start-demo.ps1 resumed, as the group's DbHubFabricCapacityResumed tag
    records, is paused before the group goes (DESTROY.FABRIC.CAPACITY; a Warning when it can't be); with false, the
    default, the capacity isn't called. When the group is already gone,
    steps 1, 4, and 5 still run, so a destroy that was interrupted can be run again: it keeps the manifest an
    earlier run recorded while the group existed (Resolve-DemoTeardownManifest), and a group still being
    deleted (ResourceGroupBeingDeleted) is waited for. If the residual check itself can't run, DESTROY.RESIDUAL
    is a Warning that says how to run it again. It never passes --ids or a {subscriptionId} placeholder to the
    Azure CLI.

    The golden group rg-<prefix>-golden (ADR 0018) belongs to the prefix, not to the environment: it stays
    unless -IncludeGolden (DESTROY.GOLDEN). Before anything is deleted, an environment whose nested T2 host
    holds a PaygWizard install (the setup-wizard step, which no script can redo) needs a boot-verified golden
    snapshot whose guest's evaluation isn't over; without one, nothing is deleted (DESTROY.GOLDEN.GUARD Fail)
    unless -WithoutGolden or -IncludeGolden accepts losing that state. With -IfExpired, the expiry wins and
    it's a Warning.

    ConfirmImpact is High: destroy.ps1 asks unless -Force. Returns DESTROY.EXPIRY (with -IfExpired),
    DESTROY.GOLDEN.GUARD, DESTROY.ARC.SQLINSTANCES, DESTROY.ARC.MACHINES, DESTROY.RESOURCEGROUP,
    DESTROY.KEYVAULT (with the Key Vault opt-in), DESTROY.DEPLOYMENT, DESTROY.BUDGET, DESTROY.GOLDEN, the
    TEARDOWN.RESIDUAL.* checks, and DESTROY.RESIDUAL.

    Sources (checked 2026-10-21): https://learn.microsoft.com/cli/azure/group#az-group-delete,
    https://learn.microsoft.com/rest/api/hybridcompute/machines/delete,
    https://learn.microsoft.com/rest/api/azurearcdata/sql-server-instances/delete,
    https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-delete,
    https://learn.microsoft.com/rest/api/consumption/budgets/delete,
    https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/common-deployment-errors
    (ResourceGroupBeingDeleted: wait for deletion to complete)

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER IfExpired
    Delete only when the resource group's expiresOn tag (yyyy-MM-dd, from expiresOn in the configuration) is
    in the past, in UTC; otherwise return DESTROY.EXPIRY Not selected and delete nothing (the expiry
    workflow, plan section 9.4).

    .PARAMETER WaitMinutes
    How long to wait for the resource group to be deleted.

    .PARAMETER ManifestPath
    Where to write the manifest (JSON, names and IDs only) for a later residual check.

    .PARAMETER SkipResidueCheck
    Don't run the residual check (DESTROY.RESIDUAL is Not selected).

    .PARAMETER ResidueWaitMinutes
    How long the residual check waits for Azure Resource Graph and Microsoft Entra to catch up.

    .PARAMETER IncludeGolden
    Also delete rg-<prefix>-golden and its golden snapshots (ADR 0018). The next deploy then builds T2 and, in
    PaygWizard mode, needs the setup-wizard step again.

    .PARAMETER WithoutGolden
    Accept losing a PaygWizard install when no boot-verified golden snapshot keeps it.

    .PARAMETER NowUtc
    For tests: the current time.

    .EXAMPLE
    Remove-DemoEnvironment -Config $config -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $IfExpired,

        [ValidateRange(1, 180)]
        [int] $WaitMinutes = 60,

        [string] $ManifestPath = '',

        [switch] $SkipResidueCheck,

        [ValidateRange(0, 120)]
        [int] $ResidueWaitMinutes = 10,

        [switch] $IncludeGolden,

        [switch] $WithoutGolden,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing was deleted. Sign in yourself and run destroy.ps1 again.'))
        return $results.ToArray()
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $docUrl = 'https://learn.microsoft.com/cli/azure/group#az-group-delete'
    $groupExists = Test-DemoResourceGroupExist -Config $Config
    if ($IfExpired) {
        if (-not $groupExists) {
            $results.Add((New-DemoResult -CheckId 'DESTROY.RESOURCEGROUP' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('{0} doesn''t exist; nothing to delete.' -f $resourceGroupName)))
            return $results.ToArray()
        }
        $expiresOn = [string](Get-DemoResourceGroupTag -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName)['expiresOn']
        $expiry = [datetime]::MinValue
        if (-not $expiresOn) {
            $results.Add((New-DemoResult -CheckId 'DESTROY.EXPIRY' -Area 'teardown' -Target 'subscription' -Status 'Not selected' -Message ('{0} has no expiresOn tag, so it doesn''t expire; nothing was deleted.' -f $resourceGroupName)))
            return $results.ToArray()
        }
        if (-not [datetime]::TryParseExact($expiresOn, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$expiry)) {
            $results.Add((New-DemoResult -CheckId 'DESTROY.EXPIRY' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('{0}''s expiresOn tag ({1}) isn''t a yyyy-MM-dd date, so nothing was deleted.' -f $resourceGroupName, $expiresOn) -Remediation 'Fix expiresOn in the configuration and run deploy.ps1 -FromStage Infrastructure, or run destroy.ps1 yourself.'))
            return $results.ToArray()
        }
        if ($NowUtc.Date -le $expiry.Date) {
            $results.Add((New-DemoResult -CheckId 'DESTROY.EXPIRY' -Area 'teardown' -Target 'subscription' -Status 'Not selected' -Message ('{0} expires on {1}; nothing was deleted.' -f $resourceGroupName, $expiresOn)))
            return $results.ToArray()
        }
        $results.Add((New-DemoResult -CheckId 'DESTROY.EXPIRY' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('{0} expired on {1}, so it''s deleted now.' -f $resourceGroupName, $expiresOn)))
    }
    if (-not $PSCmdlet.ShouldProcess($resourceGroupName, 'Delete the Arc resources, the resource group and everything in it, the subscription deployment record, and the budget')) {
        $results.Add((New-DemoResult -CheckId 'DESTROY.RESOURCEGROUP' -Area 'teardown' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} wasn''t deleted.' -f $resourceGroupName)))
        return $results.ToArray()
    }

    # A PaygWizard install holds the setup-wizard step, which no script can redo: keep it in a golden snapshot first.
    $goldenGroup = Get-DemoGoldenResourceGroupName -Config $Config
    $goldenDoc = 'https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots'
    $installMode = if ($Config.Contains('t2SqlInstallMode') -and $Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'PaygWizard' }
    if ($groupExists -and $installMode -eq 'PaygWizard' -and (Get-DemoHostVmName -Config $Config) -eq 'archost01') {
        $hostRead = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $resourceGroupName, '--name', 'archost01', '--query', 'name', '--output', 'tsv') -AllowFailure
        if ($hostRead.ExitCode -eq 0 -and ([string]$hostRead.StdOut).Trim()) {
            $kept = @(Get-DemoT2GoldenSnapshot -Config $Config -NowUtc $NowUtc | Where-Object { $null -ne $_.BootVerifiedUtc -and $null -ne $_.EvalDaysLeft -and $_.EvalDaysLeft -ge 1 })
            if ($kept.Count -gt 0 -and -not $IncludeGolden) {
                $results.Add((New-DemoResult -CheckId 'DESTROY.GOLDEN.GUARD' -Area 'teardown' -Target 'T2' -Status 'Pass' -Message ('archost01 holds a PaygWizard install, and the boot-verified golden snapshot {0} in {1} keeps it; the next deploy restores from it.' -f $kept[0].Name, $goldenGroup) -Evidence ([ordered]@{ snapshot = $kept[0].Name; bootVerifiedUtc = $kept[0].BootVerifiedUtc; evalDaysLeft = $kept[0].EvalDaysLeft }) -DocUrl $goldenDoc))
            }
            elseif ($WithoutGolden -or $IncludeGolden -or $IfExpired) {
                $why = if ($IncludeGolden) { '-IncludeGolden deletes the golden snapshots too' } elseif ($WithoutGolden) { 'no boot-verified golden snapshot keeps it (-WithoutGolden accepts that)' } else { 'no boot-verified golden snapshot keeps it, and the environment expired (-IfExpired)' }
                $results.Add((New-DemoResult -CheckId 'DESTROY.GOLDEN.GUARD' -Area 'teardown' -Target 'T2' -Status 'Warning' -Message ('archost01''s PaygWizard install (the setup-wizard step) is lost: {0}. The next deploy builds T2 and waits for the wizard again.' -f $why) -DocUrl $goldenDoc))
            }
            else {
                $results.Add((New-DemoResult -CheckId 'DESTROY.GOLDEN.GUARD' -Area 'teardown' -Target 'T2' -Status 'Fail' -Message ('Nothing was deleted: archost01 holds a PaygWizard install (the setup-wizard step, which no script can redo), and no boot-verified golden snapshot in {0} keeps it.' -f $goldenGroup) -Remediation 'Capture and prove one first (./scripts/capture-t2-golden.ps1, then ./scripts/test-t2-golden.ps1 -Onboard), or accept losing the wizard state: destroy.ps1 -WithoutGolden.' -DocUrl $goldenDoc))
                return $results.ToArray()
            }
        }
    }

    # fabric.manageCapacity (Phase 26b, ADR 0023): a Fabric capacity that start-demo.ps1 resumed is paused before its record
    # goes with the group (a Warning when it can't be). With the default (false), the capacity isn't called.
    if ($groupExists -and (Get-DemoFabricCapacitySetting -Config $Config).ManageCapacity) {
        $results.Add((Suspend-DemoFabricCapacity -Config $Config -CheckPrefix DESTROY -Confirm:$false))
    }

    # Read before anything goes: the deploymentId and the identities can't be found once the group is gone.
    $manifest = $null
    try {
        $manifest = Resolve-DemoTeardownManifest -Manifest (Get-DemoTeardownManifest -Config $Config) -Path $ManifestPath
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The manifest for the residual check couldn''t be recorded; the check runs without it: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }

    if ($groupExists) {
        $base = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers' -f $subscriptionId, $resourceGroupName
        $arcSetting = Get-DemoArcSetting
        $arc = @(
            @{ CheckId = 'DESTROY.ARC.SQLINSTANCES'; Type = 'Microsoft.AzureArcData/sqlServerInstances'; ApiVersion = $arcSetting.SqlInstanceApiVersion }
            @{ CheckId = 'DESTROY.ARC.MACHINES'; Type = 'Microsoft.HybridCompute/machines'; ApiVersion = $arcSetting.MachineApiVersion }
        )
        foreach ($kind in $arc) {
            # Get-DemoArmCollection returns its array as one object (return ,): assign it first, so @() doesn't nest it.
            $collection = Get-DemoArmCollection -SubscriptionId $subscriptionId -Url ('{0}/{1}?api-version={2}' -f $base, $kind.Type, $kind.ApiVersion)
            $items = @($collection | Where-Object { $null -ne $_ })
            $deleted = [System.Collections.Generic.List[string]]::new()
            $failed = [System.Collections.Generic.List[string]]::new()
            foreach ($item in $items) {
                $id = [string](Get-DemoMemberValue -InputObject $item -Name 'id')
                $name = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
                if (-not $id) {
                    continue
                }
                $gone = Remove-DemoArmResource -SubscriptionId $subscriptionId -Url ('https://management.azure.com{0}?api-version={1}' -f $id, $kind.ApiVersion) -Confirm:$false
                if ($gone) {
                    $deleted.Add($name)
                }
                else {
                    $failed.Add($name)
                }
            }
            $status = if ($failed.Count -gt 0) { 'Fail' } else { 'Pass' }
            $message = if ($items.Count -eq 0) { 'No {0} resources.' -f $kind.Type } else { 'Deleted {0} of {1} {2} resource(s){3}.' -f $deleted.Count, $items.Count, $kind.Type, $(if ($failed.Count) { '; still there: ' + ($failed -join ', ') } else { '' }) }
            $results.Add((New-DemoResult -CheckId $kind.CheckId -Area 'teardown' -Target 'T2' -Status $status -Message $message -Evidence ([ordered]@{ deleted = $deleted.ToArray(); failed = $failed.ToArray() }) -Remediation $(if ($status -eq 'Fail') { 'Delete them in the portal (Azure Arc, then Machines or SQL Server instances), then run destroy.ps1 again.' } else { '' })))
            if ($status -eq 'Fail') {
                return $results.ToArray()
            }
        }

        # The opt-in vault goes with the group into soft delete; it's reported, because its name stays taken.
        $vaultNote = $null
        if ((Get-DemoKeyVaultSetting -Config $Config).Enabled) {
            $vault = Get-DemoKeyVaultTarget -Config $Config
            $vaultJson = if ($vault.Name) { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('keyvault', 'show', '--name', $vault.Name, '--resource-group', $resourceGroupName) -AsJson -AllowFailure } else { $null }
            if ($null -ne $vaultJson) {
                $vaultProperties = Get-DemoMemberValue -InputObject $vaultJson -Name 'properties'
                $vaultNote = [ordered]@{
                    vaultName               = $vault.Name
                    softDeleteRetentionDays = [int](Get-DemoMemberValue -InputObject $vaultProperties -Name 'softDeleteRetentionInDays')
                    purgeProtection         = [bool](Get-DemoMemberValue -InputObject $vaultProperties -Name 'enablePurgeProtection')
                }
            }
        }

        $delete = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList @('group', 'delete', '--name', $resourceGroupName, '--yes', '--no-wait') -Label ('Deleting {0}' -f $resourceGroupName)
        # A run after an interruption can find the group still being deleted (ResourceGroupBeingDeleted): wait.
        $deleting = [string]$delete.StdErr -match '(?i)ResourceGroupBeingDeleted|deprovisioning state'
        if ($delete.ExitCode -ne 0 -and -not $deleting -and -not (Test-DemoAzNotFound -Text ([string]$delete.StdErr))) {
            $results.Add((New-DemoResult -CheckId 'DESTROY.RESOURCEGROUP' -Area 'teardown' -Target 'subscription' -Status 'Fail' -Message ('Deleting {0} failed: {1}' -f $resourceGroupName, (Get-DemoDeploymentErrorText -Text $delete.StdErr -MaxLength 600)) -Remediation 'A resource lock or a policy may block it; remove the lock (enableLock) and run destroy.ps1 again.' -DocUrl $docUrl))
            return $results.ToArray()
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $gone = $false
        while ($watch.Elapsed.TotalMinutes -lt $WaitMinutes) {
            if (-not (Test-DemoResourceGroupExist -Config $Config)) {
                $gone = $true
                break
            }
            Start-Sleep -Seconds 30
        }
        if (-not $gone) {
            $results.Add((New-DemoResult -CheckId 'DESTROY.RESOURCEGROUP' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('{0} is still being deleted after {1} minutes.' -f $resourceGroupName, $WaitMinutes) -Remediation 'Check it in the portal later; run destroy.ps1 again: it finishes the cleanup and checks for residue.' -DocUrl $docUrl))
            return $results.ToArray()
        }
        $results.Add((New-DemoResult -CheckId 'DESTROY.RESOURCEGROUP' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('{0} is deleted ({1:N0} minutes).' -f $resourceGroupName, $watch.Elapsed.TotalMinutes) -Evidence ([ordered]@{ minutes = [math]::Round($watch.Elapsed.TotalMinutes, 1) }) -DocUrl $docUrl))
        if ($null -ne $vaultNote) {
            $results.Add((New-DemoResult -CheckId 'DESTROY.KEYVAULT' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('The Key Vault {0} is soft-deleted with the group and stays recoverable for {1} days{2}; it holds only disabled or rotated one-time passwords. A deploy.ps1 within that time recovers it under the same name; otherwise Azure purges it.' -f $vaultNote['vaultName'], $vaultNote['softDeleteRetentionDays'], $(if ($vaultNote['purgeProtection']) { ' (purge protection: it can''t be purged sooner)' } else { '' })) -Evidence $vaultNote -DocUrl 'https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview'))
        }
    }
    else {
        $results.Add((New-DemoResult -CheckId 'DESTROY.RESOURCEGROUP' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('{0} doesn''t exist; nothing to delete.' -f $resourceGroupName)))
    }

    # The subscription-scope deployment record outlives the group (history only, but it holds the parameters).
    $deploymentName = 'dbhub-{0}-main' -f $Config['environment']
    $deploymentDoc = 'https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-delete'
    $record = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('deployment', 'sub', 'show', '--name', $deploymentName, '--query', 'name', '--output', 'tsv') -AllowFailure
    if ($record.ExitCode -ne 0 -and (Test-DemoAzNotFound -Text ([string]$record.StdErr))) {
        $results.Add((New-DemoResult -CheckId 'DESTROY.DEPLOYMENT' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('There''s no subscription deployment record {0}.' -f $deploymentName) -DocUrl $deploymentDoc))
    }
    elseif ($record.ExitCode -ne 0) {
        $results.Add((New-DemoResult -CheckId 'DESTROY.DEPLOYMENT' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('The subscription deployment record {0} couldn''t be read: {1}' -f $deploymentName, (Get-DemoDeploymentErrorText -Text $record.StdErr -MaxLength 400)) -Remediation ('az deployment sub delete --name {0}' -f $deploymentName) -DocUrl $deploymentDoc))
    }
    else {
        $removed = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList @('deployment', 'sub', 'delete', '--name', $deploymentName) -Label ('Deleting the deployment record {0}' -f $deploymentName)
        if ($removed.ExitCode -eq 0 -or (Test-DemoAzNotFound -Text ([string]$removed.StdErr))) {
            $results.Add((New-DemoResult -CheckId 'DESTROY.DEPLOYMENT' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('Deleted the subscription deployment record {0}; it held the template''s parameters and outputs, not resources.' -f $deploymentName) -DocUrl $deploymentDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'DESTROY.DEPLOYMENT' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('The subscription deployment record {0} couldn''t be deleted: {1}' -f $deploymentName, (Get-DemoDeploymentErrorText -Text $removed.StdErr -MaxLength 400)) -Remediation ('az deployment sub delete --name {0}' -f $deploymentName) -DocUrl $deploymentDoc))
        }
    }

    # The budget at the group's scope outlives the group (live, 2026-10-22: it still answered after the group was
    # gone), so it's read and deleted by its URL, which works with or without the group.
    $budgetName = 'budget-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $budgetDoc = 'https://learn.microsoft.com/rest/api/consumption/budgets/delete'
    $budgetUrl = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Consumption/budgets/{2}?api-version={3}' -f $subscriptionId, $resourceGroupName, $budgetName, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Consumption/budgets')
    $budgetRemediation = 'Delete the budget {0} in Cost Management under Budgets (scope: {1}); it stays listed after the group is gone.' -f $budgetName, $resourceGroupName
    $budget = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $budgetUrl) -AllowFailure
    if ($budget.ExitCode -ne 0 -and (Test-DemoAzNotFound -Text ([string]$budget.StdErr))) {
        $results.Add((New-DemoResult -CheckId 'DESTROY.BUDGET' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('There''s no budget {0} at the scope of {1}.' -f $budgetName, $resourceGroupName) -DocUrl $budgetDoc))
    }
    elseif ($budget.ExitCode -ne 0) {
        $results.Add((New-DemoResult -CheckId 'DESTROY.BUDGET' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('The budget {0} couldn''t be read: {1}' -f $budgetName, (Get-DemoDeploymentErrorText -Text $budget.StdErr -MaxLength 400)) -Remediation $budgetRemediation -DocUrl $budgetDoc))
    }
    else {
        $removed = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', $budgetUrl) -AllowFailure
        if ($removed.ExitCode -eq 0 -or (Test-DemoAzNotFound -Text ([string]$removed.StdErr))) {
            $results.Add((New-DemoResult -CheckId 'DESTROY.BUDGET' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('Deleted the budget {0}; a budget at a resource group''s scope outlives the group.' -f $budgetName) -DocUrl $budgetDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'DESTROY.BUDGET' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('The budget {0} couldn''t be deleted: {1}' -f $budgetName, (Get-DemoDeploymentErrorText -Text $removed.StdErr -MaxLength 400)) -Remediation $budgetRemediation -DocUrl $budgetDoc))
        }
    }

    # The golden group belongs to the prefix, not to this environment (ADR 0018): it stays unless -IncludeGolden.
    $goldenSnapshots = @()
    try {
        $goldenSnapshots = @(Get-DemoT2GoldenSnapshot -Config $Config -NowUtc $NowUtc)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The golden snapshots couldn''t be listed: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    if (-not $IncludeGolden) {
        $results.Add((New-DemoResult -CheckId 'DESTROY.GOLDEN' -Area 'teardown' -Target 'subscription' -Status 'Not selected' -Message ('{0} stays with {1} golden snapshot(s); destroy.ps1 -IncludeGolden deletes it.' -f $goldenGroup, $goldenSnapshots.Count) -Evidence ([ordered]@{ snapshots = @($goldenSnapshots | ForEach-Object { $_.Name }) }) -DocUrl $goldenDoc))
    }
    else {
        $goldenExists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $goldenGroup) -AllowFailure
        if ($goldenExists.ExitCode -eq 0 -and ([string]$goldenExists.StdOut).Trim() -ne 'true') {
            $results.Add((New-DemoResult -CheckId 'DESTROY.GOLDEN' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('{0} doesn''t exist; no golden snapshot to delete.' -f $goldenGroup) -DocUrl $docUrl))
        }
        else {
            $goldenDelete = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList @('group', 'delete', '--name', $goldenGroup, '--yes', '--no-wait') -Label ('Deleting {0}' -f $goldenGroup)
            $goldenGone = $false
            if ($goldenDelete.ExitCode -eq 0 -or [string]$goldenDelete.StdErr -match '(?i)ResourceGroupBeingDeleted|deprovisioning state') {
                $goldenWatch = [System.Diagnostics.Stopwatch]::StartNew()
                while ($goldenWatch.Elapsed.TotalMinutes -lt $WaitMinutes) {
                    $probe = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $goldenGroup) -AllowFailure
                    if ($probe.ExitCode -eq 0 -and ([string]$probe.StdOut).Trim() -ne 'true') {
                        $goldenGone = $true
                        break
                    }
                    Start-Sleep -Seconds 15
                }
            }
            if ($goldenGone) {
                $results.Add((New-DemoResult -CheckId 'DESTROY.GOLDEN' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('Deleted {0} and its {1} golden snapshot(s) (-IncludeGolden). The next deploy builds T2 and, in PaygWizard mode, waits for the setup-wizard step again.' -f $goldenGroup, $goldenSnapshots.Count) -Evidence ([ordered]@{ snapshots = @($goldenSnapshots | ForEach-Object { $_.Name }) }) -DocUrl $docUrl))
            }
            else {
                $results.Add((New-DemoResult -CheckId 'DESTROY.GOLDEN' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('{0} wasn''t deleted within {1} minutes: {2}' -f $goldenGroup, $WaitMinutes, (Get-DemoDeploymentErrorText -Text ([string]$goldenDelete.StdErr) -MaxLength 400)).Trim() -Remediation 'Run destroy.ps1 -IncludeGolden again, or delete the group in the portal.' -DocUrl $docUrl))
            }
        }
    }

    if ($SkipResidueCheck) {
        $results.Add((New-DemoResult -CheckId 'DESTROY.RESIDUAL' -Area 'teardown' -Target 'subscription' -Status 'Not selected' -Message 'The residual check was skipped (-SkipResidueCheck).'))
        return $results.ToArray()
    }
    try {
        $residue = @(Test-DemoTeardownResidue -Config $Config -Manifest $manifest -WaitMinutes $ResidueWaitMinutes)
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'DESTROY.RESIDUAL' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('The deletes finished, but the residual check couldn''t run: {0}' -f (Protect-DemoText -Text $_.Exception.Message).Trim()) -Remediation ('Run the check again later, read-only: ./tests/teardown/Invoke-TeardownTest.ps1 -ConfigPath <configuration>. It reads the manifest {0}.' -f $(if ($ManifestPath) { $ManifestPath } else { 'that destroy.ps1 wrote' })) -DocUrl 'https://learn.microsoft.com/azure/governance/resource-graph/overview'))
        return $results.ToArray()
    }
    foreach ($item in $residue) {
        $results.Add($item)
    }
    $failed = @($residue | Where-Object { $_.status -eq 'Fail' } | ForEach-Object { $_.checkId })
    $warned = @($residue | Where-Object { $_.status -eq 'Warning' } | ForEach-Object { $_.checkId })
    $summary = if ($failed.Count) { 'Fail' } elseif ($warned.Count) { 'Warning' } else { 'Pass' }
    $message = switch ($summary) {
        'Pass' { 'Nothing of {0} is left: no resource, Arc resource, role assignment, identity, deployment record, or budget.' -f $resourceGroupName }
        'Warning' { 'No check found anything of {0} left, but read the warnings: {1}.' -f $resourceGroupName, ($warned -join ', ') }
        default { 'Something of {0} is left: {1}.' -f $resourceGroupName, ($failed -join ', ') }
    }
    $results.Add((New-DemoResult -CheckId 'DESTROY.RESIDUAL' -Area 'teardown' -Target 'subscription' -Status $summary -Message $message -Evidence ([ordered]@{ failed = $failed; warnings = $warned; deploymentId = [string](Get-DemoMemberValue -InputObject $manifest -Name 'DeploymentId') }) -Remediation $(if ($summary -eq 'Fail') { 'Read the TEARDOWN.RESIDUAL results above; run destroy.ps1 again, or delete what''s named there.' } else { '' }) -DocUrl 'https://learn.microsoft.com/azure/governance/resource-graph/overview'))
    return $results.ToArray()
}
