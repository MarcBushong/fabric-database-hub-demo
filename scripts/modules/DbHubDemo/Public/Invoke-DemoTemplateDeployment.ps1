function Invoke-DemoTemplateDeployment {
    <#
    .SYNOPSIS
    Deploys azuredeploy.json at subscription scope (or runs its what-if) with the parameters the earlier
    stages resolved, and falls back to regular serverless when Azure rejects the T3 free offer.

    .DESCRIPTION
    The one place the template is deployed (deploy.ps1, start-demo.ps1 when it recreates T3):
    1. Reads the resource group's tags (kept on every redeployment, ADR 0002), the VMs that already exist,
       T1's security type (Resolve-DemoT1SecurityType), and the existing budget's start date, which a
       redeployment must keep (Get-DemoBudgetStartDate: read as text, so a redeploy in a later month than the
       budget's own sends the budget's date, not the template's default; Phase 28 live finding, 2026-11-02).
    2. Builds the parameters with Get-DemoDeploymentParameter, including the bootstrap bundle and the
       workload runner when they were sent, and writes them to a file in a private temporary directory that's
       deleted afterward. When a VM doesn't exist yet, a generated administrator password goes into that file,
       never onto a command line; it's registered for redaction and not stored (ADR 0009).
    3. Runs 'az deployment sub create' (or 'what-if --no-pretty-print') through Invoke-DemoAz, deployment name
       <prefix>-<environment>-main (dbhub-demo-main with the defaults).
    4. If the deployment fails because Azure rejected the free offer (Resolve-DemoT3FreeOfferError), it
       deploys again with t3UseFreeLimit false and returns the T3.FREEOFFER Warning (ADR 0016, C7).
    5. Phase 24: an existing VM's disks whose type drifted from the profile (Get-DemoVmDiskDrift; the
       subscription's automation can switch a deallocated VM's disks to Standard HDD) keep their current type
       through diskSkuOverrides, with the DEPLOY.DISKS.DRIFT Warning; T4's availability zone goes only to a
       server that doesn't exist yet; and a T4 size the configuration sets that Azure refuses with SkuNotAvailable
       adds the DEPLOY.T4.SKU Fail, whose remediation names the next size (Get-DemoT4CreateFailure).
    6. T4's fallback (ADR 0019; since T4's 4-vCore default, 2026-11-04), only when the configuration doesn't set t4SkuName
       and T4 doesn't exist yet, and only for Azure's SkuNotAvailable (a quota, a policy denial, or a transient error
       fails the template as before): a refused Standard_D4ds_v5 deploys again in another zone the region's capabilities
       list for it (Get-DemoT4SkuZone), once; then with Standard_D4ads_v5, General Purpose with 4 vCores too, so
       autonomous tuning stays on; a refused Standard_D4ads_v5 moves to Standard_D2ds_v5 (2 vCores, autonomous tuning
       off), but only after its cost check (Get-DemoT4GeneralPurposeCost: its price from the Azure Retail Prices API now,
       and the demo's worst-case month, with T4's 7-day automatic restart, its storage, and its Defender plans, against
       monthlyCeilingUsd, and a session against sessionCeilingUsd), which runs right before every creation at that size
       on the fallback's behalf, and again after Azure refuses the T3 free offer, because it counted the offer's
       allowance (review of 20e855c), unless that attempt had already created the server (below); over either ceiling,
       or without a price, T4 is left out (DbHubT4Size None, checked again on the next run that deploys the template);
       and a refused Standard_D2ds_v5 deploys again without T4 (Refused). With t4AutonomousTuning true, the 2-vCore step
       is skipped: a refused Standard_D4ads_v5 ends Refused. Each step is a DEPLOY.T4.SKU Warning, and a T4 the fallback
       created at another size also gets a console line and T4Note ("T4 created as General Purpose <size> because Azure
       refused ... here, with autonomous tuning on (or off); about <price> USD an hour while running"). -T4StartSku
       starts further down when preflight already ruled sizes out. What was chosen goes into the resource group's
       DbHubT4Size tag at once, and into the tags the template carries, for later runs (Resolve-DemoEffectiveConfig,
       which this function applies to a configuration that isn't resolved yet); Phase 28's DbHubT4Sku tag is dropped. An
       existing server whose size the configuration doesn't set keeps its size when a record says so; otherwise, with
       -ScaleT4 (deploy.ps1) and T4 Ready, it scales to the default, Standard_D4ds_v5, which restarts it (DEPLOY.T4.SIZE
       Warning; a refused scale keeps its size and records it), and without -ScaleT4 (start-demo.ps1) or while T4 isn't
       Ready, it keeps its size (DEPLOY.T4.SKU Pass when that differs from the configured size). A record that doesn't
       match the server that exists is cleared, never set to its size, unless it's the size a refused scale kept. A
       record no longer holds once the configuration sets t4SkuName (review finding 5). The VMs that exist are read again
       before each attempt, so a VM a failed attempt created never gets an osProfile again. While the fallback is
       choosing, T4 is read again after each failed attempt that sent it (review of 64c28b2): its server depends only on
       the network, so an attempt that failed for another resource (the T3 free offer, a budget) can still have created
       it, and a server that exists is treated as existing from then on: it keeps its own size and record, isn't priced
       again, even after the T3 free offer's rejection (it exists and bills), is never recorded None or Refused, and is
       never moved to another size, which would resize it.
    7. Phase 28 live finding (2026-11-02): a deployment that failed while it ran (DeploymentFailed) and isn't retried
       above gets DEPLOY.TEMPLATE's Fail with the innermost errors of its failed operations, nested deployments
       included (Get-DemoDeploymentFailure, New-DemoTemplateFailureResult), for example "Microsoft.Consumption/budgets
       budget-dbhub-demo: 400: Start date of budgets cannot be updated. ..."; when they can't be read, the Azure
       CLI's error, as before. A refused budget start date gets a remediation that says how to recreate the budget.

    Deployment success alone is never Pass (ADR 0012): the result is DEPLOY.TEMPLATE Pass only with the
    provisioning state Succeeded, and later stages check what was deployed.

    Returns Succeeded, Results (DEPLOY.TEMPLATE plus any fallback Warning), Outputs (the template outputs as
    name -> value), Changes (what-if only), T3UseFreeLimit (what was deployed), T4Enabled and T4SkuName (what
    T4 got), and T4Note (the fallback's line for the console and the status page, or '').

    Sources (checked 2026-10-20; the last three 2026-11-02):
    - az deployment sub create: https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-create
    - What-if: https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-what-if
    - Find error codes: https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/find-error-code
    - az deployment operation sub list: https://learn.microsoft.com/cli/azure/deployment/operation/sub#az-deployment-operation-sub-list
    - az deployment operation group list: https://learn.microsoft.com/cli/azure/deployment/operation/group#az-deployment-operation-group-list
    - T4's compute tiers and capacity errors (2026-11-02): https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-compute,
      https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors
    - A stopped server starts again after 7 days (2026-11-02): https://learn.microsoft.com/azure/postgresql/overview
    - T4's server, read again after a failed attempt (Get-DemoT4State, through 'az rest'; as the review of 20e855c cites
      it): https://learn.microsoft.com/rest/api/postgresql/servers/get

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Action
    Create (default) or WhatIf.

    .PARAMETER NetworkMode
    public or private, as preflight resolved networkMode.

    .PARAMETER T3UseFreeLimit
    The free-offer decision (preflight's PREFLIGHT.T3.FREEOFFER).

    .PARAMETER T3AdminGroupDisplayName
    The P6 group's display name (preflight's PREFLIGHT.P6.GROUP).

    .PARAMETER BootstrapBundleSha256
    The bundle sent to both VMs; empty deploys the infrastructure only.

    .PARAMETER BootstrapChunkCount
    The bundle's chunk count.

    .PARAMETER WorkloadRunnerSha256
    The workload runner sent to the VMs; empty leaves the runner steps Not selected.

    .PARAMETER WorkloadRunnerChunkCount
    The runner's chunk count.

    .PARAMETER T2OsDiskSourceId
    A golden snapshot for a new archost01 (Resolve-DemoT2Source); ignored when archost01 exists. An existing
    archost01 without an osProfile (restored from a golden disk) always gets its OS disk attached, so no path
    asks Azure to rebuild it from the image (ADR 0018).

    .PARAMETER T4StartSku
    Where T4's fallback starts when preflight already ruled sizes out (ADR 0019): Standard_D4ads_v5, Standard_D2ds_v5 (its
    cost check still runs right before the attempt), None (left out: the 2-vCore fallback can't be created now), or
    Refused (Azure refused the fallback's last size too). Ignored when the configuration sets t4SkuName or T4 exists.

    .PARAMETER ScaleT4
    deploy.ps1's: an existing T4 whose size the configuration doesn't set, and no record keeps, scales to the default,
    Standard_D4ds_v5, when it's Ready (2026-11-04). Without it (start-demo.ps1's T3 recreation), T4 keeps its size.

    .PARAMETER TemplatePath
    The compiled template; defaults to the repository's azuredeploy.json.

    .EXAMPLE
    Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('Create', 'WhatIf')]
        [string] $Action = 'Create',

        [Parameter(Mandatory)]
        [ValidateSet('public', 'private')]
        [string] $NetworkMode,

        [Parameter(Mandatory)]
        [bool] $T3UseFreeLimit,

        [string] $T3AdminGroupDisplayName = '',

        [ValidatePattern('^([0-9a-fA-F]{64})?$')]
        [string] $BootstrapBundleSha256 = '',

        [ValidateRange(0, 999)]
        [int] $BootstrapChunkCount = 0,

        [ValidatePattern('^([0-9a-fA-F]{64})?$')]
        [string] $WorkloadRunnerSha256 = '',

        [ValidateRange(0, 999)]
        [int] $WorkloadRunnerChunkCount = 0,

        [string] $T2OsDiskSourceId = '',

        [ValidateSet('', 'Standard_D4ads_v5', 'Standard_D2ds_v5', 'None', 'Refused')]
        [string] $T4StartSku = '',

        [switch] $ScaleT4,

        [string] $TemplatePath = (Join-Path -Path $script:RepoRoot -ChildPath 'azuredeploy.json')
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $deploymentName = Get-DemoMainDeploymentName -Config $Config
    $docUrl = 'https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-create'
    $results = [System.Collections.Generic.List[object]]::new()

    $tags = @{}
    $existing = @()
    if (Test-DemoResourceGroupExist -Config $Config) {
        $tags = Get-DemoResourceGroupTag -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName
    }
    # Phase 28's record of T4's Burstable fallback is no longer read (T4's 4-vCore default, 2026-11-04), so the template
    # drops it from the group's tags.
    if ($Action -eq 'Create' -and $tags.Contains('DbHubT4Sku')) {
        $tags.Remove('DbHubT4Sku')
    }
    # Azure never changes a budget's start date, so a redeployment sends the budget's own (Phase 28 live finding,
    # 2026-11-02). Read even without the group: a budget at its scope outlives it.
    $budgetStart = Get-DemoBudgetStartDate -Config $Config
    $securityType = Resolve-DemoT1SecurityType -Config $Config
    $hostVm = Get-DemoHostVmName -Config $Config
    $hostDiskSource = $T2OsDiskSourceId
    # The VMs that exist, and how archost01's OS disk is given, are read again before every attempt: an attempt that
    # failed (a T4 size Azure refused, the T3 free offer) can still have created the VMs, and a VM that exists must
    # never get an osProfile or a new OS disk source again (ADR 0001, ADR 0018).
    $readVms = {
        $vmState = [ordered]@{ Existing = @(); Missing = @(); AttachHostDisk = $false; HostSnapshotId = '' }
        if ($tags.Count -gt 0 -or (Test-DemoResourceGroupExist -Config $Config)) {
            $vmState.Existing = @(Get-DemoExistingVmName -Config $Config)
        }
        $vmState.Missing = @(@('sqlvm01', $hostVm) | Where-Object { $_ -notin $vmState.Existing })
        # An existing host restored from a golden disk has no osProfile and keeps its attached disk (ADR 0018).
        if ($hostVm -eq 'archost01' -and 'archost01' -in $vmState.Existing) {
            $computerName = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $resourceGroupName, '--name', 'archost01', '--query', 'osProfile.computerName', '--output', 'tsv') -AllowFailure
            $vmState.AttachHostDisk = $computerName.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace([string]$computerName.StdOut)
        }
        $vmState.HostSnapshotId = if ($hostVm -eq 'archost01' -and 'archost01' -in $vmState.Missing) { $hostDiskSource } else { '' }
        [pscustomobject]$vmState
    }
    $vms = & $readVms
    $existing = @($vms.Existing)
    $missing = @($vms.Missing)
    $attachHostDisk = $vms.AttachHostDisk
    $hostSnapshotId = $vms.HostSnapshotId

    # Existing disks whose type drifted from the profile keep their current type (Phase 24): the subscription's
    # automation can switch a deallocated VM's disks to Standard HDD, and Azure refuses to change an OS disk's
    # type through its VM (OperationNotAllowed), which failed the whole template on 2026-10-26.
    $diskOverrides = @{}
    if ($existing.Count -gt 0) {
        $drift = @(Get-DemoVmDiskDrift -Config $Config -VmName $existing)
        foreach ($item in $drift) {
            $diskOverrides[[string]$item.DiskName] = [string]$item.Current
        }
        if ($drift.Count -gt 0) {
            $results.Add((New-DemoDiskDriftResult -CheckId 'DEPLOY.DISKS.DRIFT' -Drift $drift -VmName $existing))
        }
    }
    # T4's size (ADR 0019). A configuration that isn't resolved yet (start-demo.ps1's T3 recreation, a caller that reads no
    # record) gets what the fallback recorded in the group's tags; a size the file sets always wins. T4 keeps the zone it
    # was created in, so the configured zone goes only to a new server (Phase 24).
    $t4TagName = (Get-DemoDeploymentStateTagName)['T4Sku']
    $t4Explicit = Test-DemoT4SkuExplicit -Config $Config
    $effective = Resolve-DemoEffectiveConfig -Config $Config -State ([pscustomobject]@{ T4Sku = [string]$tags[$t4TagName] })
    $t4On = Test-DemoT4Enabled -Config $effective
    $t4Exists = $false
    $t4ServerSku = ''
    $t4ServerState = ''
    if ($t4On -and $tags.Count -gt 0) {
        $t4Current = Get-DemoT4State -Config $effective -DeploymentId ([string]$tags['deploymentId'])
        $t4Exists = [bool]$t4Current.Exists
        $t4ServerSku = Get-DemoT4ServerSku -Server (Get-DemoMemberValue -InputObject $t4Current -Name 'Server')
        $t4ServerState = [string](Get-DemoMemberValue -InputObject $t4Current -Name 'State')
    }
    # An existing server keeps its own size unless the configuration sets one, or it moves to the default (below): the
    # fallback never resizes a server, so a redeploy never sends another size to a server the fallback created, whatever
    # the record says (Phase 28 follow-up). A record that doesn't match the server that exists no longer holds, and is
    # cleared rather than set to the server's size: only the fallback writes a size, so a record always means the
    # fallback chose it (review of 20e855c). The same goes for a server that a failed attempt of this run created (below).
    $keepServer = {
        param([System.Collections.IDictionary] $Wanted, [string] $ServerSku)
        if ($ServerSku -cne (Get-DemoT4SkuName -Config $Wanted)) {
            $results.Add((New-DemoResult -CheckId 'DEPLOY.T4.SKU' -Area 't4' -Target 'T4' -Status 'Pass' -Message ('T4 exists as {0} ({1}), so this deployment keeps that size.' -f $ServerSku, (Get-DemoT4SkuSpec -SkuName $ServerSku).Tier) -Evidence ([ordered]@{ serverSku = $ServerSku; configuredSku = (Get-DemoT4SkuName -Config $Wanted) }) -DocUrl 'https://learn.microsoft.com/azure/postgresql/compute-storage/concepts-compute'))
            $Wanted = Copy-DemoT4Config -Config $Wanted -Source server -SkuName $ServerSku
        }
        if ($Action -eq 'Create' -and [string]$tags[$t4TagName] -and [string]$tags[$t4TagName] -cne $ServerSku) {
            $tags[$t4TagName] = ''
        }
        return $Wanted
    }
    # T4's 4-vCore default (2026-11-04, user-directed): an existing server whose size the configuration doesn't set and no
    # record keeps (a server from before, whose Phase 28 record isn't read) moves to the default at deploy.ps1's run
    # (-ScaleT4) while it's Ready, which restarts it (DEPLOY.T4.SIZE); otherwise it keeps its size this time.
    $t4Default = Get-DemoT4DefaultSkuName -Config $Config
    $t4Scaling = $false
    if ($t4Exists -and -not $t4Explicit -and $t4ServerSku) {
        $toDefault = $t4ServerSku -cne $t4Default -and (Get-DemoT4SkuName -Config $effective) -ceq $t4Default
        if ($toDefault -and $ScaleT4 -and $Action -eq 'Create' -and $t4ServerState -eq 'Ready') {
            $t4Scaling = $true
            $results.Add((New-DemoT4SizeResult -CheckPrefix DEPLOY -ServerSku $t4ServerSku -SkuName $t4Default -Outcome Scale))
            Write-DemoLog -Level Warning -Message ('T4 exists as {0}; this deployment scales it to the default, {1}, which restarts it.' -f $t4ServerSku, $t4Default)
        }
        else {
            if ($toDefault -and $ScaleT4 -and $Action -eq 'Create') {
                $results.Add((New-DemoT4SizeResult -CheckPrefix DEPLOY -ServerSku $t4ServerSku -SkuName $t4Default -Outcome Waiting -State $t4ServerState))
            }
            $effective = & $keepServer $effective $t4ServerSku
        }
    }

    $useFreeLimit = $T3UseFreeLimit
    $freeOfferTried = $false
    # The fallback works on $effective, only for a server that doesn't exist yet and a size the file doesn't set.
    $ladder = $t4On -and -not $t4Explicit -and -not $t4Exists -and $Action -eq 'Create'
    # t4AutonomousTuning true rules out the 2-vCore step: the fallback stops after the 4-vCore sizes (2026-11-04).
    $tuningRequired = (Get-DemoT4Tuning -Config $Config).Switch -eq $true
    $t4Refused = [System.Collections.Generic.List[string]]::new()
    $zoneTried = $false
    $gpChecked = $false
    $gpRefusal = $null
    $gpHourly = $null
    $gpResult = $null
    $t4Note = ''
    # The fallback's choice goes into the tags the template carries, which would otherwise put the old value back, and,
    # once the group exists, into the group's tags at once, so a later run (even after a stop) starts from it (Phase 28).
    # A value the group already has isn't written again.
    $groupSeen = $tags.Count -gt 0
    $record = {
        param([string] $Value)
        if ([string]$tags[$t4TagName] -ceq $Value) {
            return
        }
        $tags[$t4TagName] = $Value
        if (-not $groupSeen) {
            return
        }
        try {
            Set-DemoDeploymentState -Config $Config -Value @{ T4Sku = $Value } -Confirm:$false
        }
        catch {
            Write-DemoLog -Level Warning -Message ('T4''s fallback size wasn''t recorded on the resource group, so the next run may try it again: {0}' -f $_.Exception.Message)
        }
    }
    if ($ladder -and $T4StartSku) {
        # Preflight already ruled sizes out (the region's capability list, a refusal on record, or the cost check); the
        # template carries the choice into the group's tags, as before (Phase 28).
        $refusalDoc = 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors'
        switch ($T4StartSku) {
            'Standard_D4ads_v5' {
                $effective = Copy-DemoT4Config -Config $effective -Source fallback -SkuName 'Standard_D4ads_v5'
                $t4Refused.Add('Standard_D4ds_v5')
                $tags[$t4TagName] = 'Standard_D4ads_v5'
                $results.Add((New-DemoResult -CheckId 'DEPLOY.T4.SKU' -Area 't4' -Target 'T4' -Status 'Warning' -Message 'Preflight found that the region doesn''t offer, or refused, T4''s default Standard_D4ds_v5, so this deployment uses Standard_D4ads_v5, General Purpose with 4 vCores too (autonomous tuning stays on), and later runs keep it.' -Evidence ([ordered]@{ startSku = $T4StartSku }) -Remediation 'Nothing to do. To choose T4''s size yourself, set t4SkuName.' -DocUrl $refusalDoc))
            }
            'Standard_D2ds_v5' {
                $t4Refused.AddRange([string[]]@('Standard_D4ds_v5', 'Standard_D4ads_v5'))
                if ($tuningRequired) {
                    # Preflight's PREFLIGHT.T4.TUNING fails this case first; a caller that skips preflight still never gets
                    # a size that can't run autonomous tuning.
                    $effective = Copy-DemoT4Config -Config $effective -Source fallback -Off
                    $tags[$t4TagName] = 'Refused'
                    $results.Add((New-DemoT4FallbackResult -Refused $null -Next 'Refused' -TuningRequired))
                }
                else {
                    # The 2-vCore fallback: its cost check runs right before the attempt, below.
                    $effective = Copy-DemoT4Config -Config $effective -Source fallback -SkuName 'Standard_D2ds_v5'
                }
            }
            'None' {
                $effective = Copy-DemoT4Config -Config $effective -Source fallback -Off
                $t4Refused.AddRange([string[]]@('Standard_D4ds_v5', 'Standard_D4ads_v5'))
                $tags[$t4TagName] = 'None'
                $results.Add((New-DemoResult -CheckId 'DEPLOY.T4.SKU' -Area 't4' -Target 'T4' -Status 'Warning' -Message 'Preflight left T4 out of this deployment (PREFLIGHT.T4.FALLBACK or PREFLIGHT.T4.CAPABILITY says why): Azure refuses its 4-vCore sizes here, and the 2-vCore fallback, Standard_D2ds_v5, can''t be created now. t4Enabled stays as you configured it, and the next run that deploys the template checks the fallback again.' -Evidence ([ordered]@{ startSku = $T4StartSku }) -Remediation 'PREFLIGHT.T4.FALLBACK says what would add T4.' -DocUrl $refusalDoc))
            }
            'Refused' {
                $effective = Copy-DemoT4Config -Config $effective -Source fallback -Off
                $t4Refused.AddRange([string[]]@('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5'))
                $tags[$t4TagName] = 'Refused'
                $results.Add((New-DemoT4FallbackResult -Refused $null -Next 'Refused' -TuningRequired:$tuningRequired))
            }
        }
    }
    # Review finding 5: any record no longer holds once the configuration sets t4SkuName and this deployment has T4 in it;
    # the template carries the group's tags, so it's cleared in them.
    if ([string]$tags[$t4TagName] -and $Action -eq 'Create' -and $t4Explicit -and (Test-DemoT4Enabled -Config $effective)) {
        $tags[$t4TagName] = ''
    }
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        # Right before the fallback creates T4 at its 2-vCore size, its cost check runs (ADR 0019): the price from the Azure
        # Retail Prices API now, and the worst case with T4's 7-day automatic restart, against both ceilings. Over either,
        # or without a price, T4 is left out instead. Never for a size the configuration sets.
        if ($ladder -and -not $gpChecked -and (Test-DemoT4Enabled -Config $effective) -and (Get-DemoT4SkuName -Config $effective) -ceq 'Standard_D2ds_v5') {
            $gpChecked = $true
            $cost = Get-DemoT4GeneralPurposeCost -Config $effective -NetworkMode $NetworkMode -T3UseFreeLimit $useFreeLimit
            if ($cost.Allowed) {
                & $record 'Standard_D2ds_v5'
                $gpHourly = $cost.HourlyUsd
                $gpResult = New-DemoT4FallbackResult -Refused $gpRefusal -Next 'Standard_D2ds_v5' -Cost $cost
                $results.Add($gpResult)
                Write-DemoLog -Level Warning -Message ('Azure refused T4''s 4-vCore sizes here, so this run creates T4 as General Purpose Standard_D2ds_v5, with autonomous tuning off: {0}.' -f (Format-DemoT4FallbackCostText -Cost $cost))
            }
            else {
                $effective = Copy-DemoT4Config -Config $effective -Source fallback -Off
                & $record 'None'
                $skip = New-DemoT4FallbackResult -Refused $gpRefusal -Next 'None' -Cost $cost
                $results.Add($skip)
                Write-DemoLog -Level Warning -Message ('T4 isn''t created: {0}' -f $skip.message)
            }
        }
        if ($attempt -gt 1) {
            $vms = & $readVms
            $existing = @($vms.Existing)
            $missing = @($vms.Missing)
            $attachHostDisk = $vms.AttachHostDisk
            $hostSnapshotId = $vms.HostSnapshotId
        }
        $parameterArguments = @{
            Config                    = $effective
            ExistingResourceGroupTags = $tags
            NetworkMode               = $NetworkMode
            ExistingVmName            = $existing
            T1SecurityType            = $securityType.SecurityType
            T3UseFreeLimit            = $useFreeLimit
        }
        if ($budgetStart) {
            $parameterArguments['BudgetStartDate'] = $budgetStart
        }
        if ($T3AdminGroupDisplayName) {
            $parameterArguments['T3AdminGroupDisplayName'] = $T3AdminGroupDisplayName
        }
        if ($hostSnapshotId) {
            $parameterArguments['T2OsDiskSourceId'] = $hostSnapshotId
        }
        elseif ($attachHostDisk) {
            $parameterArguments['T2AttachExistingOsDisk'] = $true
        }
        if ($BootstrapBundleSha256) {
            $parameterArguments['BootstrapBundleSha256'] = $BootstrapBundleSha256
            $parameterArguments['BootstrapChunkCount'] = $BootstrapChunkCount
            if ($WorkloadRunnerSha256) {
                $parameterArguments['WorkloadRunnerSha256'] = $WorkloadRunnerSha256
                $parameterArguments['WorkloadRunnerChunkCount'] = $WorkloadRunnerChunkCount
            }
        }
        if ($diskOverrides.Count -gt 0) {
            $parameterArguments['DiskSkuOverride'] = $diskOverrides
        }
        if ($t4Exists) {
            $parameterArguments['T4Exists'] = $true
        }
        $document = Get-DemoDeploymentParameter @parameterArguments

        $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-deploy'
        try {
            if ($missing.Count -gt 0) {
                # New VMs need an administrator password: generated, registered for redaction, written only to
                # the private parameters file, and discarded afterward (ADR 0009).
                $secure = New-DemoAdminPassword
                $document['parameters']['adminPassword'] = @{ value = [System.Net.NetworkCredential]::new('', $secure).Password }
                $secure.Dispose()
            }
            $path = Write-DemoPrivateFile -Directory $directory -Name 'parameters.json' -Content ($document | ConvertTo-Json -Depth 30)
            $document = $null
            $verb = if ($Action -eq 'WhatIf') { 'what-if' } else { 'create' }
            $arguments = [System.Collections.Generic.List[string]]::new([string[]]@('deployment', 'sub', $verb, '--location', [string]$Config['location'], '--name', $deploymentName, '--template-file', $TemplatePath, '--parameters', "@$path"))
            if ($Action -eq 'WhatIf') {
                $arguments.Add('--no-pretty-print')
            }
            Write-DemoLog -Message ('Template {0}: {1} (VMs that exist: {2}; bundle {3}; runner {4}).' -f $verb, $deploymentName, $(if ($existing) { $existing -join ', ' } else { 'none' }), $(if ($BootstrapBundleSha256) { $BootstrapBundleSha256.Substring(0, 12) } else { 'none' }), $(if ($WorkloadRunnerSha256) { $WorkloadRunnerSha256.Substring(0, 12) } else { 'none' }))
            $started = [System.Diagnostics.Stopwatch]::StartNew()
            $run = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $arguments.ToArray() -AllowFailure
            $started.Stop()
        }
        finally {
            Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
        }

        if ($run.ExitCode -eq 0) {
            $parsed = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$run.StdOut)) {
                $parsed = [string]$run.StdOut | ConvertFrom-Json -Depth 64
            }
            if ($Action -eq 'WhatIf') {
                # Get-DemoMemberValue keeps an array intact, so it's unrolled from a variable.
                $changeValue = Get-DemoMemberValue -InputObject $parsed -Name 'changes'
                $changes = @($changeValue | Where-Object { $null -ne $_ })
                $counts = [ordered]@{}
                foreach ($change in $changes) {
                    $type = [string](Get-DemoMemberValue -InputObject $change -Name 'changeType')
                    $counts[$type] = 1 + [int]$counts[$type]
                }
                $summary = ($counts.Keys | ForEach-Object { '{0} {1}' -f $counts[$_], $_ }) -join ', '
                $results.Add((New-DemoResult -CheckId 'DEPLOY.TEMPLATE.WHATIF' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('What-if ran in {0:N0} seconds: {1}.' -f $started.Elapsed.TotalSeconds, $summary) -Evidence ([ordered]@{ changes = $counts; deploymentName = $deploymentName }) -DocUrl 'https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-what-if'))
                return [pscustomobject]@{ Succeeded = $true; Results = $results.ToArray(); Outputs = @{}; Changes = $changes; T3UseFreeLimit = $useFreeLimit }
            }
            $state = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $parsed -Name 'properties') -Name 'provisioningState')
            $duration = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $parsed -Name 'properties') -Name 'duration')
            $status = if ($state -eq 'Succeeded') { 'Pass' } else { 'Fail' }
            $t4Deployed = Test-DemoT4Enabled -Config $effective
            $t4SkuName = if ($t4Deployed) { Get-DemoT4SkuName -Config $effective } else { '' }
            # Said loudly (ADR 0019): T4 created by the fallback at another size, with whether autonomous tuning is on and its
            # price from the API; an existing T4 scaled to the default; or T4 left out by the fallback. The status page's
            # Infrastructure step and DONE say it too.
            $location = [string]$Config['location']
            if ($state -eq 'Succeeded' -and $t4Deployed -and $gpChecked -and $t4SkuName -ceq 'Standard_D2ds_v5') {
                $t4Note = Format-DemoT4FallbackCreatedText -HourlyUsd $gpHourly -Location $location -SkuName 'Standard_D2ds_v5'
                Write-DemoLog -Level Warning -Message $t4Note
            }
            elseif ($state -eq 'Succeeded' -and $t4Deployed -and $t4SkuName -ceq 'Standard_D4ads_v5' -and $t4Refused -contains 'Standard_D4ds_v5') {
                $t4Note = Format-DemoT4FallbackCreatedText -HourlyUsd (Get-DemoT4HourlyPrice -Config $effective) -Location $location -SkuName 'Standard_D4ads_v5' -Tuning (Get-DemoT4Tuning -Config $effective).Enabled
                Write-DemoLog -Level Warning -Message $t4Note
            }
            elseif ($state -eq 'Succeeded' -and $t4Deployed -and $t4Scaling) {
                $t4Note = 'T4 scaled from {0} to the default, General Purpose {1}, {2}; {3}.' -f $t4ServerSku, $t4SkuName, $(if ((Get-DemoT4Tuning -Config $effective).Enabled) { 'with autonomous tuning on' } else { 'with autonomous tuning off (t4AutonomousTuning is false)' }), (Format-DemoT4HourlyText -HourlyUsd (Get-DemoT4HourlyPrice -Config $effective) -Location $location)
                Write-DemoLog -Level Warning -Message $t4Note
            }
            elseif ($state -eq 'Succeeded' -and $t4On -and -not $t4Deployed -and $t4Refused.Count -gt 0) {
                $t4Note = 'T4 isn''t deployed: Azure refused its 4-vCore sizes here, and the 2-vCore fallback wasn''t created (DEPLOY.T4.SKU says why).'
            }
            $results.Add((New-DemoResult -CheckId 'DEPLOY.TEMPLATE' -Area 'infra' -Target 'subscription' -Status $status -Message ('Deployment {0}: {1} in {2}.' -f $deploymentName, $state, $duration) -Evidence ([ordered]@{ provisioningState = $state; duration = $duration; newVms = $missing; t3UseFreeLimit = $useFreeLimit; bundle = $BootstrapBundleSha256; runner = $WorkloadRunnerSha256; t2Disk = $(if ($hostSnapshotId) { 'golden: ' + ($hostSnapshotId -replace '^.*/', '') } elseif ($attachHostDisk) { 'attached' } else { 'image' }); t4Enabled = $t4Deployed; t4SkuName = (Get-DemoT4SkuName -Config $effective); t4Fallback = $(if ($t4Deployed -and $t4Refused.Count -gt 0) { $t4SkuName } elseif ($t4Refused.Count -gt 0) { [string]$tags[$t4TagName] } else { '' }); t4Scaled = $(if ($t4Deployed -and $t4Scaling) { $t4ServerSku } else { '' }); t4AutonomousTuning = $($t4Deployed -and (Get-DemoT4Tuning -Config $effective).Enabled) }) -DocUrl $docUrl))
            return [pscustomobject]@{ Succeeded = ($state -eq 'Succeeded'); Results = $results.ToArray(); Outputs = (ConvertTo-DemoDeploymentOutput -Deployment $parsed); Changes = @(); T3UseFreeLimit = $useFreeLimit; T4Enabled = $t4Deployed; T4SkuName = (Get-DemoT4SkuName -Config $effective); T4Note = $t4Note }
        }

        if ($Action -eq 'Create') {
            # The template creates the resource group before anything else, so a later record goes into its tags too.
            $groupSeen = $true
        }
        # T4's server depends only on the network (infra/modules/demo.bicep), so an attempt that failed for another resource
        # (the T3 free offer, a budget) can still have created it, as it can the VMs. While the fallback is choosing, T4 is
        # read again after every failed attempt that sent it, and a server that exists is treated as existing from then on:
        # it keeps its own size and the record that goes with it, isn't priced again (it exists and bills), is never recorded
        # as left out (None) or refused (Refused), and is never moved to another size, which would resize it (review of
        # 64c28b2). A server that can't be read is taken as missing, as before.
        if ($ladder -and (Test-DemoT4Enabled -Config $effective)) {
            $t4Now = $null
            try {
                $t4Now = Get-DemoT4State -Config $effective -DeploymentId ([string]$tags['deploymentId'])
            }
            catch {
                Write-DemoLog -Level Warning -Message ('T4''s server couldn''t be read after the failed attempt, so the fallback goes on as if it doesn''t exist: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
            }
            if ([bool](Get-DemoMemberValue -InputObject $t4Now -Name 'Exists')) {
                $t4Exists = $true
                $ladder = $false
                $t4ServerSku = Get-DemoT4ServerSku -Server (Get-DemoMemberValue -InputObject $t4Now -Name 'Server')
                if ($t4ServerSku) {
                    $effective = & $keepServer $effective $t4ServerSku
                }
                Write-DemoLog -Level Warning -Message ('T4''s server exists after this failed attempt (it depends only on the network, so another resource''s failure doesn''t stop it): it''s kept at {0}, and the fallback stops here, so it isn''t priced again, left out, or moved to another size.' -f $(if ($t4ServerSku) { $t4ServerSku } else { 'its own size' }))
            }
            elseif ($null -ne $t4Now -and [string](Get-DemoMemberValue -InputObject $t4Now -Name 'State') -ne 'NotFound') {
                Write-DemoLog -Level Warning -Message ('T4''s server couldn''t be read after the failed attempt, so the fallback goes on as if it doesn''t exist: {0}' -f (Protect-DemoText -Text ([string](Get-DemoMemberValue -InputObject $t4Now -Name 'Error'))))
            }
        }
        $verdict = Resolve-DemoT3FreeOfferError -ErrorText ([string]$run.StdErr)
        if (-not $freeOfferTried -and $useFreeLimit -and $verdict.IsFreeOfferError) {
            Write-DemoLog -Level Warning -Message 'Azure rejected the T3 free offer; deploying again with regular General Purpose serverless.'
            $results.Add($verdict.Result)
            $useFreeLimit = $false
            $freeOfferTried = $true
            # The 2-vCore fallback's cost check counted the free offer's allowance, so it runs again without it before
            # the next attempt, and its new result replaces the old one (review of 20e855c); unless the rejected attempt had
            # already created the server, which then exists and bills, so it isn't priced again (review of 64c28b2).
            if ($ladder -and $gpChecked -and (Test-DemoT4Enabled -Config $effective) -and (Get-DemoT4SkuName -Config $effective) -ceq 'Standard_D2ds_v5') {
                $gpChecked = $false
                if ($null -ne $gpResult) {
                    [void]$results.Remove($gpResult)
                    $gpResult = $null
                }
            }
            elseif ($t4Exists -and $null -ne $gpResult) {
                $gpResult.message += ' Azure then rejected the T3 free offer, whose allowance this check counted, but that attempt had already created T4''s server, so it isn''t priced again: it exists and bills.'
                $gpResult.evidence['freeOfferCounted'] = $true
            }
            continue
        }
        $t4Failure = $null
        if ((Test-DemoT4Enabled -Config $effective) -and ($Action -eq 'Create') -and (-not $t4Exists -or $t4Scaling)) {
            $t4Failure = Get-DemoT4CreateFailure -Config $effective
        }
        $current = Get-DemoT4SkuName -Config $effective
        # A scale to the default that Azure refused with SkuNotAvailable (2026-11-04): T4 keeps its size, which the group
        # records, so later runs keep it too, and this run deploys again without the scale.
        if ($t4Scaling -and $null -ne $t4Failure -and [string]$t4Failure.Sku -ceq $current) {
            $t4Scaling = $false
            $effective = Copy-DemoT4Config -Config $effective -Source server -SkuName $t4ServerSku
            & $record $t4ServerSku
            $results.Add((New-DemoT4SizeResult -CheckPrefix DEPLOY -ServerSku $t4ServerSku -SkuName $current -Outcome Refused -Failure $t4Failure))
            Write-DemoLog -Level Warning -Message ('Azure refused to scale T4 to {0}; deploying again with T4 at {1}.' -f $current, $t4ServerSku)
            continue
        }
        # The fallback (ADR 0019, since T4's 4-vCore default, 2026-11-04): only Azure's SkuNotAvailable for the size this
        # attempt sent, which the configuration doesn't set, moves it on, and only while T4's server doesn't exist (read
        # above): Standard_D4ds_v5 once more in another zone the region lists for it, then Standard_D4ads_v5, then
        # Standard_D2ds_v5 (after its cost check, at the top of the next attempt; not with t4AutonomousTuning true), and
        # Standard_D2ds_v5 to no T4. A quota, a policy denial, or a transient error fails the template as before. What it
        # chose is recorded for later runs.
        if ($ladder -and $null -ne $t4Failure -and [string]$t4Failure.Sku -ceq $current -and $current -notin $t4Refused) {
            switch ($current) {
                'Standard_D4ds_v5' {
                    $retryZone = ''
                    if (-not $zoneTried) {
                        $zoneTried = $true
                        $retryZone = [string](@(Get-DemoT4SkuZone -Config $effective -SkuName $current) | Where-Object { $_ -ne [string]$t4Failure.Zone } | Select-Object -First 1)
                    }
                    if ($retryZone) {
                        $effective = Copy-DemoT4Config -Config $effective -Source fallback -SkuName 'Standard_D4ds_v5' -Zone $retryZone
                        $results.Add((New-DemoT4FallbackResult -Refused $t4Failure -Next 'Zone' -Zone $retryZone))
                        Write-DemoLog -Level Warning -Message ('Azure refused T4''s Standard_D4ds_v5; deploying again in zone {0}, which the region lists for it.' -f $retryZone)
                    }
                    else {
                        $t4Refused.Add($current)
                        $effective = Copy-DemoT4Config -Config $effective -Source fallback -SkuName 'Standard_D4ads_v5' -Zone (Get-DemoT4AvailabilityZone -Config $Config)
                        & $record 'Standard_D4ads_v5'
                        $results.Add((New-DemoT4FallbackResult -Refused $t4Failure -Next 'Standard_D4ads_v5'))
                        Write-DemoLog -Level Warning -Message 'Azure refused T4''s Standard_D4ds_v5; deploying again with Standard_D4ads_v5, General Purpose with 4 vCores too.'
                    }
                }
                'Standard_D4ads_v5' {
                    $t4Refused.Add($current)
                    if ($tuningRequired) {
                        $effective = Copy-DemoT4Config -Config $effective -Source fallback -Off
                        & $record 'Refused'
                        $results.Add((New-DemoT4FallbackResult -Refused $t4Failure -Next 'Refused' -TuningRequired))
                        Write-DemoLog -Level Warning -Message 'Azure refused T4''s Standard_D4ads_v5 too, and t4AutonomousTuning is true, which rules out the 2-vCore fallback; deploying again without T4.'
                    }
                    else {
                        $effective = Copy-DemoT4Config -Config $effective -Source fallback -SkuName 'Standard_D2ds_v5'
                        $gpRefusal = $t4Failure
                        Write-DemoLog -Level Warning -Message 'Azure refused T4''s Standard_D4ads_v5 too; pricing the 2-vCore fallback, Standard_D2ds_v5, before deploying again.'
                    }
                }
                default {
                    # Standard_D2ds_v5, the last size the fallback tries.
                    $t4Refused.Add($current)
                    $effective = Copy-DemoT4Config -Config $effective -Source fallback -Off
                    & $record 'Refused'
                    $results.Add((New-DemoT4FallbackResult -Refused $t4Failure -Next 'Refused'))
                    Write-DemoLog -Level Warning -Message 'Azure refused T4''s 2-vCore fallback, Standard_D2ds_v5, too; deploying again without T4.'
                }
            }
            continue
        }
        # Phase 28 live finding (2026-11-02): a deployment that failed while it ran names its cause in its operations, read
        # only now, after the free offer's and T4's own handling above, which reads the error as before.
        $cause = if ($Action -eq 'Create') { Get-DemoDeploymentFailure -Config $Config -DeploymentName $deploymentName -ErrorText ([string]$run.StdErr) } else { $null }
        $results.Add((New-DemoTemplateFailureResult -Config $Config -Verb $verb -DeploymentName $deploymentName -ErrorText ([string]$run.StdErr) -Cause $cause -DocUrl $docUrl))
        if ($null -ne $t4Failure -and [string]$t4Failure.Sku -ceq $current) {
            # A size Azure refused for T4 that the configuration sets gets its own Fail, with the documented fallback (Phase 24, ADR 0019).
            $results.Add((New-DemoT4SkuFailureResult -CheckId 'DEPLOY.T4.SKU' -Failure $t4Failure))
        }
        return [pscustomobject]@{ Succeeded = $false; Results = $results.ToArray(); Outputs = @{}; Changes = @(); T3UseFreeLimit = $useFreeLimit; T4Enabled = (Test-DemoT4Enabled -Config $effective); T4SkuName = (Get-DemoT4SkuName -Config $effective); T4Note = $t4Note }
    }
    # Every attempt above returns or moves on to a next one; this is reached only if they all moved on.
    $results.Add((New-DemoResult -CheckId 'DEPLOY.TEMPLATE' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message 'The template deployment didn''t succeed within its attempts (the T3 free offer''s and T4''s fallbacks included).' -Remediation 'Run deploy.ps1 -Resume; the results above say what each attempt changed.' -DocUrl $docUrl))
    return [pscustomobject]@{ Succeeded = $false; Results = $results.ToArray(); Outputs = @{}; Changes = @(); T3UseFreeLimit = $useFreeLimit; T4Enabled = (Test-DemoT4Enabled -Config $effective); T4SkuName = (Get-DemoT4SkuName -Config $effective); T4Note = $t4Note }
}
