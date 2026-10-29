function Invoke-DemoTemplateDeployment {
    <#
    .SYNOPSIS
    Deploys azuredeploy.json at subscription scope (or runs its what-if) with the parameters the earlier
    stages resolved, and falls back to regular serverless when Azure rejects the T3 free offer.

    .DESCRIPTION
    The one place the template is deployed (deploy.ps1, start-demo.ps1 when it recreates T3):
    1. Reads the resource group's tags (kept on every redeployment, ADR 0002), the VMs that already exist,
       T1's security type (Resolve-DemoT1SecurityType), and the existing budget's start date, which a
       redeployment must keep.
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
       server that doesn't exist yet; and a T4 size Azure refuses with SkuNotAvailable adds the DEPLOY.T4.SKU
       Fail, whose remediation names the documented fallback (Get-DemoT4CreateFailure).
    6. Phase 28, T4's Burstable fallback (ADR 0019), only when the configuration doesn't set t4SkuName: a refused
       Standard_B1ms deploys again with Standard_B2s, and a refused Standard_B2s deploys again without T4, each with
       the DEPLOY.T4.SKU Warning (the second names t4SkuName: Standard_D2ds_v5 and its price); -T4StartSku starts one
       size on when preflight already ruled the default out. What was used is recorded in the resource group's T4Sku
       tag for later runs (Resolve-DemoEffectiveConfig). A General Purpose size is never chosen on its own. The VMs
       that exist are read again before each attempt, so a VM a failed attempt created never gets an osProfile again.

    Deployment success alone is never Pass (ADR 0012): the result is DEPLOY.TEMPLATE Pass only with the
    provisioning state Succeeded, and later stages check what was deployed.

    Returns Succeeded, Results (DEPLOY.TEMPLATE plus any fallback Warning), Outputs (the template outputs as
    name -> value), Changes (what-if only), T3UseFreeLimit (what was deployed), and T4Enabled and T4SkuName (what
    T4 got).

    Sources (checked 2026-10-20):
    - az deployment sub create: https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-create
    - What-if: https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-what-if

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
    Standard_B2s or None: where T4's Burstable fallback starts when preflight already ruled out the default (Phase 28).
    Ignored when the configuration sets t4SkuName or T4 exists.

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

        [ValidateSet('', 'Standard_B2s', 'None')]
        [string] $T4StartSku = '',

        [string] $TemplatePath = (Join-Path -Path $script:RepoRoot -ChildPath 'azuredeploy.json')
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $deploymentName = Get-DemoMainDeploymentName -Config $Config
    $docUrl = 'https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-create'
    $results = [System.Collections.Generic.List[object]]::new()

    $tags = @{}
    $existing = @()
    $budgetStart = ''
    if (Test-DemoResourceGroupExist -Config $Config) {
        $tags = Get-DemoResourceGroupTag -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName
        $budgetStart = Get-DemoBudgetStartDate -Config $Config
    }
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
    # T4 keeps the zone it was created in, so the configured zone goes only to a new server (Phase 24).
    $t4On = Test-DemoT4Enabled -Config $Config
    $t4Exists = $false
    if ($t4On -and $tags.Count -gt 0) {
        $t4Exists = [bool](Get-DemoT4State -Config $Config -DeploymentId ([string]$tags['deploymentId'])).Exists
    }

    $useFreeLimit = $T3UseFreeLimit
    # Phase 28: T4's Burstable fallback works on a copy of the configuration, and only for a size it doesn't set.
    $effective = $Config
    $t4Explicit = $Config.Contains('t4SkuName') -and -not [string]::IsNullOrWhiteSpace([string]$Config['t4SkuName'])
    $freeOfferTried = $false
    $t4Refused = [System.Collections.Generic.List[string]]::new()
    if ($T4StartSku -and -not $t4Explicit -and $t4On -and -not $t4Exists -and $Action -eq 'Create') {
        # Preflight's capability list (or a refusal on record) already rules out the default: start one size on.
        $copy = [ordered]@{}
        foreach ($key in $Config.Keys) {
            $copy[$key] = $Config[$key]
        }
        if ($T4StartSku -eq 'None') {
            $copy['t4Enabled'] = $false
            $t4Refused.AddRange([string[]]@('Standard_B1ms', 'Standard_B2s'))
        }
        else {
            $copy['t4SkuName'] = $T4StartSku
            $t4Refused.Add('Standard_B1ms')
        }
        $effective = $copy
        # The template keeps the group's tags from its parameters, so the choice goes into them too.
        $tags[(Get-DemoDeploymentStateTagName)['T4Sku']] = $T4StartSku
        $message = if ($T4StartSku -eq 'None') { 'Preflight found that the region offers neither of T4''s Burstable sizes, so this deployment creates no T4; t4Enabled stays as you configured it, and nothing larger is chosen for you.' } else { 'Preflight found that the region doesn''t offer T4''s default Standard_B1ms, so this deployment uses Standard_B2s, the same Burstable class, and later runs keep it.' }
        $results.Add((New-DemoResult -CheckId 'DEPLOY.T4.SKU' -Area 't4' -Target 'T4' -Status 'Warning' -Message $message -Evidence ([ordered]@{ startSku = $T4StartSku }) -Remediation $(if ($T4StartSku -eq 'None') { 'To add T4, set "t4SkuName": "Standard_D2ds_v5" (General Purpose; estimate-cost.ps1 prices it), then run ./scripts/deploy.ps1.' } else { 'Nothing to do. To choose T4''s size yourself, set t4SkuName.' }) -DocUrl 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors'))
    }
    for ($attempt = 1; $attempt -le 4; $attempt++) {
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
            $results.Add((New-DemoResult -CheckId 'DEPLOY.TEMPLATE' -Area 'infra' -Target 'subscription' -Status $status -Message ('Deployment {0}: {1} in {2}.' -f $deploymentName, $state, $duration) -Evidence ([ordered]@{ provisioningState = $state; duration = $duration; newVms = $missing; t3UseFreeLimit = $useFreeLimit; bundle = $BootstrapBundleSha256; runner = $WorkloadRunnerSha256; t2Disk = $(if ($hostSnapshotId) { 'golden: ' + ($hostSnapshotId -replace '^.*/', '') } elseif ($attachHostDisk) { 'attached' } else { 'image' }); t4Enabled = (Test-DemoT4Enabled -Config $effective); t4SkuName = (Get-DemoT4SkuName -Config $effective) }) -DocUrl $docUrl))
            return [pscustomobject]@{ Succeeded = ($state -eq 'Succeeded'); Results = $results.ToArray(); Outputs = (ConvertTo-DemoDeploymentOutput -Deployment $parsed); Changes = @(); T3UseFreeLimit = $useFreeLimit; T4Enabled = (Test-DemoT4Enabled -Config $effective); T4SkuName = (Get-DemoT4SkuName -Config $effective) }
        }

        $verdict = Resolve-DemoT3FreeOfferError -ErrorText ([string]$run.StdErr)
        if (-not $freeOfferTried -and $useFreeLimit -and $verdict.IsFreeOfferError) {
            Write-DemoLog -Level Warning -Message 'Azure rejected the T3 free offer; deploying again with regular General Purpose serverless.'
            $results.Add($verdict.Result)
            $useFreeLimit = $false
            $freeOfferTried = $true
            continue
        }
        $t4Failure = $null
        if ((Test-DemoT4Enabled -Config $effective) -and -not $t4Exists -and $Action -eq 'Create') {
            $t4Failure = Get-DemoT4CreateFailure -Config $effective
        }
        # Phase 28 (brief item 6, ADR 0019): a Burstable size Azure refused, which the configuration doesn't set, falls back
        # once to Standard_B2s, then to no T4 at all; what was used is recorded for later runs. Never a General Purpose size.
        $current = Get-DemoT4SkuName -Config $effective
        if ($null -ne $t4Failure -and -not $t4Explicit -and [string]$t4Failure.Sku -eq $current -and $current -in 'Standard_B1ms', 'Standard_B2s' -and $current -notin $t4Refused) {
            $t4Refused.Add($current)
            $copy = [ordered]@{}
            foreach ($key in $effective.Keys) {
                $copy[$key] = $effective[$key]
            }
            $recorded = if ($current -eq 'Standard_B1ms') { 'Standard_B2s' } else { 'None' }
            if ($recorded -eq 'Standard_B2s') {
                $copy['t4SkuName'] = 'Standard_B2s'
            }
            else {
                $copy['t4Enabled'] = $false
            }
            $effective = $copy
            $tagName = (Get-DemoDeploymentStateTagName)['T4Sku']
            $tags[$tagName] = $recorded
            try {
                Set-DemoDeploymentState -Config $Config -Value @{ T4Sku = $recorded } -Confirm:$false
            }
            catch {
                Write-DemoLog -Level Warning -Message ('T4''s fallback size wasn''t recorded on the resource group, so the next run tries the default again: {0}' -f $_.Exception.Message)
            }
            $results.Add((New-DemoT4FallbackResult -Config $Config -Refused $t4Failure -Next $recorded))
            Write-DemoLog -Level Warning -Message $(if ($recorded -eq 'None') { 'Azure refused T4''s Burstable sizes; deploying again without T4.' } else { 'Azure refused T4''s Standard_B1ms; deploying again with Standard_B2s, the same Burstable class.' })
            continue
        }
        $results.Add((New-DemoResult -CheckId 'DEPLOY.TEMPLATE' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('The template {0} failed: {1}' -f $verb, (Get-DemoDeploymentErrorText -Text $run.StdErr)) -Remediation 'Fix the cause in the message, then run deploy.ps1 -Resume. A 409 Conflict while a policy installs an extension clears within minutes.' -DocUrl $docUrl))
        if ($null -ne $t4Failure) {
            # A size Azure refused for T4 that the configuration sets gets its own Fail, with the documented fallback (Phase 24, ADR 0019).
            $results.Add((New-DemoT4SkuFailureResult -CheckId 'DEPLOY.T4.SKU' -Failure $t4Failure))
        }
        return [pscustomobject]@{ Succeeded = $false; Results = $results.ToArray(); Outputs = @{}; Changes = @(); T3UseFreeLimit = $useFreeLimit; T4Enabled = (Test-DemoT4Enabled -Config $effective); T4SkuName = (Get-DemoT4SkuName -Config $effective) }
    }
}
