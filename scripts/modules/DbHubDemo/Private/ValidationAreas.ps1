function Invoke-DemoValidationPreflight {
    <#
    .SYNOPSIS
    The Preflight area: Invoke-DemoPreflight without changes (no provider registration, no what-if), whose
    network-mode and free-offer results the T3 and cost checks reuse. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [switch] $SkipPolicyInventory,

        [ValidateRange(0, 720)]
        [int] $PolicyCacheHours = 0
    )

    # validate.ps1 has already run the subscription guard; preflight runs it again, and its record is dropped.
    $results = @(Invoke-DemoPreflight -Config $Context.Config -SkipProviderRegistration -SkipWhatIf -SkipPolicyInventory:$SkipPolicyInventory -PolicyCacheHours $PolicyCacheHours |
            Where-Object { $_.checkId -ne 'PREFLIGHT.GUARD.CONTEXT' })
    $sqlPublic = $results | Where-Object { $_.checkId -eq 'PREFLIGHT.POLICY.SQLPUBLIC' } | Select-Object -First 1
    if ($sqlPublic -and -not [bool](Get-DemoMemberValue -InputObject $sqlPublic.evidence -Name 'assumed')) {
        $mode = [string](Get-DemoMemberValue -InputObject $sqlPublic.evidence -Name 'effectiveNetworkMode')
        if ($mode -in 'public', 'private') {
            $Context.NetworkMode = $mode
            $Context.NetworkModeSource = 'the policy inventory'
        }
    }
    $freeOffer = $results | Where-Object { $_.checkId -eq 'PREFLIGHT.T3.FREEOFFER' } | Select-Object -First 1
    if ($freeOffer -and $freeOffer.status -ne 'Not selected') {
        $useFree = Get-DemoMemberValue -InputObject $freeOffer.evidence -Name 'useFreeLimit'
        if ($null -ne $useFree) {
            $Context.T3UseFreeLimit = [bool]$useFree
        }
    }
    return $results
}

function Invoke-DemoValidationInfrastructure {
    <#
    .SYNOPSIS
    The Infrastructure area: the resource group and its tags, the network, and for each selected target VM its
    power state, the bootstrap loader's exit code, health.json, and on the T2 host the nested guest. Checks
    that need a running VM report a Warning while it's deallocated. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $config = $Context.Config
    $group = $Context.ResourceGroup
    $results = [System.Collections.Generic.List[object]]::new()
    $groupDoc = 'https://learn.microsoft.com/azure/azure-resource-manager/management/manage-resource-groups-cli'
    if (-not $Context.GroupExists) {
        if ($Context.GroupNotFound) {
            $results.Add((New-DemoResult -CheckId 'INFRA.RESOURCEGROUP' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('The resource group {0} doesn''t exist: the demo isn''t deployed, or it was destroyed.' -f $group) -Remediation 'Deploy it with ./scripts/deploy.ps1. After destroy.ps1, run validate.ps1 -Area Teardown instead.' -DocUrl $groupDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'INFRA.RESOURCEGROUP' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('The resource group {0} couldn''t be read: {1}' -f $group, $Context.GroupError) -Remediation 'Check that you can read the subscription (Reader or higher), then run validate.ps1 again.' -DocUrl $groupDoc))
        }
        return $results.ToArray()
    }

    $required = @('solution', 'environment', 'owner', 'purpose', 'costCenter', 'autoShutdown', 'deploymentId')
    $missing = @($required | Where-Object { -not $Context.Tags.ContainsKey($_) -or -not $Context.Tags[$_] })
    $arcTag = [string]$Context.Tags['ArcSQLServerExtensionDeployment']
    $evidence = [ordered]@{ resourceGroup = $group; deploymentId = $Context.DeploymentId; tagNames = @($Context.Tags.Keys | Sort-Object); arcSqlExtensionDeployment = $arcTag }
    if ($missing.Count -gt 0 -or $arcTag -ne 'PAYG') {
        $problems = @(
            if ($missing.Count -gt 0) { 'missing tags: {0}' -f ($missing -join ', ') }
            if ($arcTag -ne 'PAYG') { 'ArcSQLServerExtensionDeployment is ''{0}'', not PAYG' -f $arcTag }
        )
        $results.Add((New-DemoResult -CheckId 'INFRA.RESOURCEGROUP' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('The resource group {0} exists, but {1}.' -f $group, ($problems -join '; ')) -Evidence $evidence -Remediation 'Deploy again (deploy.ps1 -Resume): the template merges the required tags into the existing ones (ADR 0002).' -DocUrl $groupDoc))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'INFRA.RESOURCEGROUP' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('The resource group {0} exists with the required tags, deploymentId {1}, and ArcSQLServerExtensionDeployment=PAYG.' -f $group, $Context.DeploymentId) -Evidence $evidence -DocUrl $groupDoc))
    }

    # The network: four subnets, each with its NSG (ADR 0007).
    $prefix = '{0}-{1}' -f $config['prefix'], $config['environment']
    $vnetName = 'vnet-{0}' -f $prefix
    $expected = [ordered]@{
        'snet-sqlvm'         = 'nsg-{0}-sqlvm' -f $prefix
        'snet-archost'       = 'nsg-{0}-archost' -f $prefix
        'snet-pe'            = 'nsg-{0}-pe' -f $prefix
        'AzureBastionSubnet' = 'nsg-{0}-bastion' -f $prefix
    }
    $networkDoc = 'https://learn.microsoft.com/cli/azure/network/vnet'
    $vnet = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('network', 'vnet', 'show', '--resource-group', $group, '--name', $vnetName)
    if (-not $vnet.Ok) {
        $status = if ($vnet.NotFound) { 'Fail' } else { 'Warning' }
        $results.Add((New-DemoResult -CheckId 'INFRA.NETWORK' -Area 'infra' -Target 'subscription' -Status $status -Message ('The virtual network {0} couldn''t be read: {1}' -f $vnetName, $vnet.Error) -Remediation 'Deploy again (deploy.ps1 -Resume), then run validate.ps1 again.' -DocUrl $networkDoc))
    }
    else {
        $subnets = Get-DemoMemberList -InputObject $vnet.Value -Name 'subnets'
        $problems = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $expected.Keys) {
            $subnet = $subnets | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -eq $name } | Select-Object -First 1
            if ($null -eq $subnet) {
                $problems.Add(('{0} is missing' -f $name))
                continue
            }
            $nsgId = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $subnet -Name 'networkSecurityGroup') -Name 'id')
            if ($nsgId -notmatch ('(?i)/networkSecurityGroups/{0}$' -f [regex]::Escape($expected[$name]))) {
                $problems.Add(('{0} isn''t associated with {1}' -f $name, $expected[$name]))
            }
        }
        $networkEvidence = [ordered]@{ virtualNetwork = $vnetName; subnets = @($subnets | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') }) }
        if ($problems.Count -gt 0) {
            $results.Add((New-DemoResult -CheckId 'INFRA.NETWORK' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('The network doesn''t match the template: {0}.' -f ($problems -join '; ')) -Evidence $networkEvidence -Remediation 'Deploy again (deploy.ps1 -Resume) to restore the subnets and their NSGs (ADR 0007).' -DocUrl $networkDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'INFRA.NETWORK' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('{0} has snet-sqlvm, snet-archost, snet-pe, and AzureBastionSubnet, each with its NSG.' -f $vnetName) -Evidence $networkEvidence -DocUrl $networkDoc))
        }
    }

    foreach ($entry in $Context.VmNames.GetEnumerator()) {
        $target = [string]$entry.Key
        $vmName = [string]$entry.Value
        $evaluationOnly = $target -eq 'T2' -and $Context.Arc.EvaluationOnly
        $suffix = ($vmName -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
        $state = Get-DemoValidationVmState -Context $Context -VmName $vmName
        $guestCheck = $target -eq 'T2' -and -not $Context.Arc.EvaluationOnly
        if (-not $state.Running) {
            $results.Add((New-DemoValidationStoppedResult -CheckId ('INFRA.VM.{0}' -f $suffix) -Area 'infra' -Target $target -VmState $state -Context $Context -Checks 'its bootstrap and health checks' -EvaluationOnly:$evaluationOnly))
            if ($state.PowerState -ne 'not found') {
                $results.Add((New-DemoValidationStoppedResult -CheckId ('INFRA.BOOTSTRAP.LOADER_{0}' -f $suffix) -Area 'infra' -Target $target -VmState $state -Context $Context -Checks 'the bootstrap loader check (its instance view is empty until the VM runs)' -EvaluationOnly:$evaluationOnly))
                $results.Add((New-DemoValidationStoppedResult -CheckId ('INFRA.HEALTH.{0}' -f $suffix) -Area 'infra' -Target $target -VmState $state -Context $Context -Checks 'the health.json read (Run Command)' -EvaluationOnly:$evaluationOnly))
                if ($guestCheck) {
                    $results.Add((New-DemoValidationStoppedResult -CheckId 'INFRA.GUEST.ARCSQL01' -Area 'infra' -Target 'T2' -VmState $state -Context $Context -Checks 'the nested guest check'))
                }
            }
            continue
        }

        $results.Add((New-DemoResult -CheckId ('INFRA.VM.{0}' -f $suffix) -Area 'infra' -Target $target -Status 'Pass' -Message ('{0} is running (provisioning state {1}).' -f $vmName, $state.ProvisioningState) -Evidence @{ vmName = $vmName; powerState = $state.PowerState } -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/states-billing' -EvaluationOnly:$evaluationOnly))
        $loader = Wait-DemoBootstrapLoader -Config $config -VmName $vmName -TimeoutSeconds 30
        if ($evaluationOnly -and $loader) {
            $loader = New-DemoResult -CheckId $loader.checkId -Area $loader.area -Target $loader.target -Status $loader.status -Message $loader.message -Evidence $loader.evidence -Remediation $loader.remediation -DocUrl $loader.docUrl -EvaluationOnly
        }

        $read = Get-DemoValidationHealth -Context $Context -VmName $vmName
        # deploy.ps1's parallel tracks run the loader in a Run Command and remove it afterward (ADR 0018), so there's no
        # DbHubDemo-Bootstrap Run Command to read; health.json's generation names the bundle the loader installed.
        if ($loader -and [string]$loader.status -eq 'Fail' -and [string]$loader.message -match 'has no bootstrap loader Run Command' -and $null -ne $read.Health) {
            $generation = [string](Get-DemoMemberValue -InputObject $read.Health -Name 'generation')
            $recorded = [string]$Context.Tags['DbHubBundleSha256']
            if ($recorded.Length -ge 12 -and $generation.StartsWith($recorded.Substring(0, 12), [System.StringComparison]::OrdinalIgnoreCase)) {
                $loader = New-DemoResult -CheckId $loader.checkId -Area $loader.area -Target $loader.target -Status 'Pass' -Message ('{0} runs the recorded bootstrap bundle {1} (generation {2}). deploy.ps1''s parallel tracks ran its loader in a Run Command and removed it afterward, so there''s no DbHubDemo-Bootstrap Run Command to read.' -f $vmName, $recorded.Substring(0, 12).ToLowerInvariant(), $generation) -Evidence ([ordered]@{ vmName = $vmName; bundle = $recorded.Substring(0, 12).ToLowerInvariant(); generation = $generation }) -DocUrl $loader.docUrl -EvaluationOnly:$evaluationOnly
            }
        }
        $results.Add($loader)
        $healthDoc = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
        if ($null -eq $read.Health) {
            $note = Get-DemoValidationRunCommandNote -ErrorText $read.Error
            $results.Add((New-DemoResult -CheckId ('INFRA.HEALTH.{0}' -f $suffix) -Area 'infra' -Target $target -Status 'Warning' -Message ('health.json on {0} couldn''t be read: {1} {2}' -f $vmName, $read.Error, $note) -Remediation 'Run validate.ps1 again in about 10 minutes.' -DocUrl $healthDoc -EvaluationOnly:$evaluationOnly))
            if ($guestCheck) {
                $results.Add((New-DemoResult -CheckId 'INFRA.GUEST.ARCSQL01' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('The nested guest wasn''t checked, because health.json on {0} couldn''t be read.' -f $vmName) -Remediation 'Run validate.ps1 again in about 10 minutes.' -DocUrl $healthDoc))
            }
            continue
        }
        $health = $read.Health
        $healthStatus = [string](Get-DemoMemberValue -InputObject $health -Name 'status')
        if ($healthStatus -notin $script:ValidStatuses) {
            $healthStatus = 'Warning'
        }
        $healthState = [string](Get-DemoMemberValue -InputObject $health -Name 'state')
        $step = [string](Get-DemoMemberValue -InputObject $health -Name 'currentStep')
        $healthMessage = [string](Get-DemoMemberValue -InputObject $health -Name 'message')
        $healthEvidence = [ordered]@{}
        foreach ($name in 'role', 'state', 'status', 'currentStep', 'generation', 'updatedUtc', 'installMode', 'arcOnboarded', 'guestState', 'sqlEdition', 'guidedArmed', 'guidedRequest', 'guidedLast') {
            $healthEvidence[$name] = Get-DemoMemberValue -InputObject $health -Name $name
        }
        $stepText = if ($step) { ' (step {0})' -f $step } else { '' }
        $text = if ($healthMessage) { '{0} reports {1}{2}: {3}' -f $vmName, $healthState, $stepText, $healthMessage } else { '{0} reports {1}{2}.' -f $vmName, $healthState, $stepText }
        $remediation = switch ($healthStatus) {
            'Manual action required' { 'Follow the instructions in health.json (Get-DemoVmHealth -Config $config -VmName {0} -View Full). The T2 setup-wizard step is in docs/deployment.md.' -f $vmName }
            'Fail' { 'Read health.json and C:\ProgramData\DbHubDemo\logs on {0} (through Bastion), fix the cause, then run deploy.ps1 -Resume.' -f $vmName }
            'Warning' { 'The bootstrap is still working or waiting; run validate.ps1 again later.' }
            default { '' }
        }
        $results.Add((New-DemoResult -CheckId ('INFRA.HEALTH.{0}' -f $suffix) -Area 'infra' -Target $target -Status $healthStatus -Message $text -Evidence $healthEvidence -Remediation $remediation -DocUrl $healthDoc -EvaluationOnly:$evaluationOnly))

        if ($guestCheck) {
            $guestState = [string](Get-DemoMemberValue -InputObject $health -Name 'guestState')
            $guestDoc = 'https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/nested-virtualization'
            if ($guestState -eq 'Running') {
                $results.Add((New-DemoResult -CheckId 'INFRA.GUEST.ARCSQL01' -Area 'infra' -Target 'T2' -Status 'Pass' -Message ('The nested guest arcsql01 is running on {0}, so nested virtualization works (ADR 0003).' -f $vmName) -Evidence @{ guestState = $guestState; hostState = $healthState } -DocUrl $guestDoc))
            }
            elseif ($guestState) {
                $results.Add((New-DemoResult -CheckId 'INFRA.GUEST.ARCSQL01' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('The nested guest arcsql01 is {0} on {1}.' -f $guestState, $vmName) -Evidence @{ guestState = $guestState; hostState = $healthState } -Remediation 'The guest starts with the host; if it stays off, check the host''s health.json and run validate.ps1 again.' -DocUrl $guestDoc))
            }
            else {
                $results.Add((New-DemoResult -CheckId 'INFRA.GUEST.ARCSQL01' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('{0} doesn''t report the nested guest yet (host state {1}); the guest is built in the host''s state machine.' -f $vmName, $healthState) -Evidence @{ hostState = $healthState } -Remediation 'Wait for the host''s guest steps, then run validate.ps1 again.' -DocUrl $guestDoc))
            }
        }
    }
    return $results.ToArray()
}

function Invoke-DemoValidationT1 {
    <#
    .SYNOPSIS
    The T1 area: T1.SQLVM.MONITORING (a Warning while sqlvm01 is deallocated) and
    T1.SQLVM.ASSOCIATEDSERVICES (unified inventory, readable while the VM is deallocated: Pass with the
    engine only, a Warning while Analysis Services or Integration Services are still listed), both
    read-only. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    @(
        Test-DemoSqlVmMonitoring -Config $Context.Config
        Test-DemoSqlVmAssociatedService -Config $Context.Config
    )
}

function Invoke-DemoValidationT2 {
    <#
    .SYNOPSIS
    The T2 area: the Arc checks (Get-DemoArcCheck) and, while the host runs, T2.GUEST.ISOLATION from the
    read-only onboarding probe: the guest can't reach IMDS or the wire server, and resolves names through the
    host (ADR 0004). Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-DemoArcCheck -Config $Context.Config)) {
        $results.Add($item)
    }

    $arc = $Context.Arc
    $docUrl = 'https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine'
    $state = Get-DemoValidationVmState -Context $Context -VmName $arc.HostVmName
    if (-not $state.Running) {
        $results.Add((New-DemoValidationStoppedResult -CheckId 'T2.GUEST.ISOLATION' -Area 't2' -Target 'T2' -VmState $state -Context $Context -Checks 'the guest isolation probe (ADR 0004)' -EvaluationOnly:$arc.EvaluationOnly))
        return $results.ToArray()
    }
    $probe = $null
    $probeError = ''
    try {
        $script = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/Invoke-DemoArcOnboard.ps1') -Raw
        $run = Invoke-DemoVmRunCommand -Config $Context.Config -VmName $arc.HostVmName -RunCommandName 'DbHubDemo-ValidateProbe' -Script $script -Parameter @{ Action = 'Probe'; MachineName = $arc.MachineName; Mode = $arc.T2Mode } -TimeoutSeconds 300 -PollIntervalSeconds 15 -Confirm:$false
        if ($run.Succeeded) {
            $probe = ConvertFrom-DemoRunCommandOutput -Text $run.Output
        }
        else {
            $probeError = if ($run.Error) { $run.Error } else { 'execution state {0}' -f $run.ExecutionState }
        }
    }
    catch {
        $probeError = Protect-DemoText -Text $_.Exception.Message
    }
    if ($null -eq $probe) {
        $results.Add((New-DemoResult -CheckId 'T2.GUEST.ISOLATION' -Area 't2' -Target 'T2' -Status 'Warning' -Message ('The guest couldn''t be probed on {0}: {1} {2}' -f $arc.HostVmName, $probeError, (Get-DemoValidationRunCommandNote -ErrorText $probeError)) -Remediation 'Run validate.ps1 -Area T2 again in about 10 minutes.' -DocUrl $docUrl -EvaluationOnly:$arc.EvaluationOnly))
        return $results.ToArray()
    }
    $evidence = [ordered]@{}
    foreach ($name in 'guestReachable', 'imdsReachable', 'wireServerReachable', 'dnsResolves') {
        $evidence[$name] = Get-DemoMemberValue -InputObject $probe -Name $name
    }
    # The onboarding decision table owns the isolation rule; with -Force it doesn't depend on the host's state.
    $decision = Get-DemoArcOnboardingDecision -Force -Probe $probe -Machine $null -MachineName $arc.MachineName -ResourceGroupName $arc.ResourceGroupName -SubscriptionId $arc.SubscriptionId -EvaluationOnly:$arc.EvaluationOnly
    $evidence['decision'] = $decision.Action
    if ($decision.Action -in 'GuestUnreachable', 'GuestNotIsolated') {
        $remediation = if ($decision.Action -eq 'GuestNotIsolated') { 'Rerun the host''s GuestHardening step (guest firewall rules and host port ACLs, ADR 0004) before anything else runs in the guest.' } else { 'Check that arcsql01 runs on the host, then run validate.ps1 -Area T2 again.' }
        $results.Add((New-DemoResult -CheckId 'T2.GUEST.ISOLATION' -Area 't2' -Target 'T2' -Status $decision.Status -Message $decision.Reason -Evidence $evidence -Remediation $remediation -DocUrl $docUrl -EvaluationOnly:$arc.EvaluationOnly))
    }
    elseif (-not [bool]$evidence['dnsResolves']) {
        $results.Add((New-DemoResult -CheckId 'T2.GUEST.ISOLATION' -Area 't2' -Target 'T2' -Status 'Warning' -Message 'The guest can''t reach IMDS or the wire server, but name resolution through the host failed.' -Evidence $evidence -Remediation 'Check the DNS Server role on the host (it forwards for the guest, ADR 0004), then run validate.ps1 -Area T2 again.' -DocUrl $docUrl -EvaluationOnly:$arc.EvaluationOnly))
    }
    else {
        $what = if ($arc.EvaluationOnly) { 'IMDS is blocked on arcsql01, as the evaluation procedure requires' } else { 'the guest can''t reach IMDS or the wire server, and it resolves names through the host' }
        $results.Add((New-DemoResult -CheckId 'T2.GUEST.ISOLATION' -Area 't2' -Target 'T2' -Status 'Pass' -Message ('Isolation holds: {0} (ADR 0004).' -f $what) -Evidence $evidence -DocUrl $docUrl -EvaluationOnly:$arc.EvaluationOnly))
    }
    return $results.ToArray()
}

function Invoke-DemoValidationT3 {
    <#
    .SYNOPSIS
    The T3 area: Test-DemoT3 with the effective network mode and the free-offer decision. T3.PROPERTY runs
    its T-SQL through T1, so it's a Warning while sqlvm01 is deallocated, and it resumes a paused T3. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $parameters = @{ Config = $Context.Config; NetworkMode = (Get-DemoValidationNetworkMode -Context $Context) }
    if ($Context.DeploymentId) {
        $parameters['DeploymentId'] = $Context.DeploymentId
    }
    if ($null -ne $Context.T3UseFreeLimit) {
        $parameters['T3UseFreeLimit'] = [bool]$Context.T3UseFreeLimit
    }
    Write-DemoLog -Message ('T3 checks use network mode {0}, from {1}.' -f $parameters['NetworkMode'], $Context.NetworkModeSource)
    @(Test-DemoT3 @parameters)
}

function Invoke-DemoValidationT4 {
    <#
    .SYNOPSIS
    The T4 area (Phase 24, ADR 0019): Test-DemoT4 -IncludeMetrics, read-only. A stopped T4 is a Warning (it
    sends no metrics), never a Fail. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $parameters = @{ Config = $Context.Config; IncludeMetrics = $true }
    if ($Context.DeploymentId) {
        $parameters['DeploymentId'] = $Context.DeploymentId
    }
    @(Test-DemoT4 @parameters)
}

function Invoke-DemoValidationHub {
    <#
    .SYNOPSIS
    The Hub area: P4 and P5 (Test-DemoFabricHubSetting, and Test-DemoFabricWorkspace on the workspace that
    Resolve-DemoFabricConfig finds by name, read-only), Estate visibility (Test-DemoHubEstate), and presenter access
    read-only (Set-DemoPresenterAccess, with -WhatIf when it would assign roles). Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [switch] $FabricAdmin
    )

    $config = $Context.Config
    $results = [System.Collections.Generic.List[object]]::new()
    # The Fabric workspace by name (Phase 26a, ADR 0021), read-only: validation never creates anything.
    $resolution = Resolve-DemoFabricConfig -Config $config
    foreach ($item in @(Test-DemoFabricHubSetting -Config $config -FabricAdmin:$FabricAdmin) + @($resolution.Results) + @(Test-DemoFabricWorkspace -Config $resolution.Config) + @(Test-DemoHubEstate -Config $config -Target $Context.Target -DeploymentId $Context.DeploymentId)) {
        if ($null -ne $item) {
            $results.Add($item)
        }
    }

    # Validation changes nothing: when assignRoles would assign presenter roles, it runs in what-if mode and the
    # pending assignments become a manual step.
    $presenters = @(@($config['presenterObjectIds']) | Where-Object { $_ })
    $whatIf = [bool]$config['assignRoles'] -and $presenters.Count -gt 0
    foreach ($item in @(Set-DemoPresenterAccess -Config $config -WhatIf:$whatIf -Confirm:$false)) {
        if ($whatIf -and $item.status -eq 'Not selected' -and $item.message -like 'WhatIf:*') {
            $item = New-DemoResult -CheckId $item.checkId -Area $item.area -Target $item.target -Status 'Manual action required' -Message ($item.message -replace '^WhatIf: ', 'Not assigned yet: ') -Evidence $item.evidence -Remediation 'Run ./scripts/configure-fabric.ps1 -SkipNotebookImport, which assigns them (assignRoles is true).' -DocUrl $item.docUrl
        }
        $results.Add($item)
    }
    return $results.ToArray()
}

function Invoke-DemoValidationTelemetry {
    <#
    .SYNOPSIS
    The Telemetry area: rows per target from the telemetry endpoint over the 7-day retention window
    (Test-DemoHubTelemetry), and the T3 readiness gate (Test-DemoT3Readiness). A target without rows is the
    manual step Estate reports (T2 before the setup wizard), or a Warning when it sends nothing by design (a
    deallocated VM, a paused or removed T3); otherwise it stays a Fail. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 0
    )

    $config = $Context.Config
    $results = [System.Collections.Generic.List[object]]::new()
    $estate = @($Context.Results | Where-Object { $_.checkId -like 'HUB.ESTATE.T*' })
    if ($estate.Count -eq 0) {
        $estate = @(Test-DemoHubEstate -Config $config -Target $Context.Target -DeploymentId $Context.DeploymentId)
    }
    $estateStatus = @{}
    foreach ($item in $estate) {
        $estateStatus[[string]$item.target] = [string]$item.status
    }

    # T4's telemetry is Azure Monitor metrics (METRICS.T4 in the T4 area), not the Hub's SQL telemetry endpoint.
    $sqlTargets = @($Context.Target | Where-Object { $_ -ne 'T4' })
    foreach ($item in @(if ($sqlTargets.Count -gt 0) { Test-DemoHubTelemetry -Config $config -Target $sqlTargets -LookbackMinutes 10080 -WaitMinutes $WaitMinutes -DeploymentId $Context.DeploymentId })) {
        $rows = Get-DemoMemberValue -InputObject $item.evidence -Name 'rows'
        $noRows = $item.status -eq 'Fail' -and $null -ne $rows -and [long]$rows -eq 0
        if ($noRows -and $estateStatus[[string]$item.target] -eq 'Manual action required') {
            # The same rule as Invoke-DemoHubReadiness: no telemetry before the SQL Server instance exists.
            $item = New-DemoResult -CheckId $item.checkId -Area $item.area -Target $item.target -Status 'Manual action required' -Message ('No performance telemetry from {0} yet, because its SQL Server instance isn''t set up: HUB.ESTATE.{0} reports a pending manual step.' -f $item.target) -Evidence $item.evidence -Remediation ('Finish the step that HUB.ESTATE.{0} describes, then run validate.ps1 -Area Telemetry -WaitMinutes 15.' -f $item.target) -DocUrl $item.docUrl -EvaluationOnly:$item.evaluationOnly
        }
        elseif ($noRows) {
            $quiet = Get-DemoValidationQuietReason -Context $Context -Target $item.target
            if ($quiet) {
                $item = New-DemoResult -CheckId $item.checkId -Area $item.area -Target $item.target -Status 'Warning' -Message ('No performance telemetry from {0} in the 7-day retention window, because {1}, so it sends none.' -f $item.target, $quiet) -Evidence $item.evidence -Remediation 'Start the demo (./scripts/start-demo.ps1 starts the VMs and warms T3 up), then run validate.ps1 -Area Telemetry -WaitMinutes 15.' -DocUrl $item.docUrl -EvaluationOnly:$item.evaluationOnly
            }
        }
        $results.Add($item)
    }

    if ('T3' -in $Context.Target) {
        $property = $Context.Results | Where-Object { $_.checkId -eq 'T3.PROPERTY' } | Select-Object -First 1
        if ($null -eq $property) {
            $run = Invoke-DemoT3SqlFromT1 -Config $config -Name Status -DeploymentId $Context.DeploymentId -CheckId 'T3.PROPERTY' -MaxLoginWaitSeconds 120 -Confirm:$false
            $value = if ($run.Status -eq 'Pass') { [string](Get-DemoMemberValue -InputObject (@($run.Rows) | Select-Object -First 1) -Name 'performance_monitoring') } else { '' }
            $property = [pscustomobject]@{ status = $(if ($run.Status -ne 'Pass') { 'Warning' } elseif ($value -eq 'true') { 'Pass' } else { 'Fail' }); message = [string]$run.Message }
        }
        # Test-DemoT3Readiness treats a thrown error as "not checked", so a property check that couldn't run
        # (T1 deallocated) never reads as "not set". It adds its own prefix, so T3.PROPERTY's is dropped.
        $answer = $property
        $why = ([string]$property.message) -replace '^The extended property couldn''t be checked:\s*', ''
        $check = if ($property.status -in 'Pass', 'Fail') {
            { param($Settings) $null = $Settings; $answer }.GetNewClosure()
        }
        else {
            { param($Settings) $null = $Settings; throw $why }.GetNewClosure()
        }
        $gate = Test-DemoT3Readiness -Config $config -PerformanceMonitoringCheck $check -DeploymentId $Context.DeploymentId -WaitMinutes $WaitMinutes
        foreach ($item in @($gate.Results)) {
            $results.Add($item)
        }
    }
    return $results.ToArray()
}

function Invoke-DemoValidationWorkload {
    <#
    .SYNOPSIS
    The Workload area: the runner's status on each selected target (Invoke-DemoWorkloadCommand status --json,
    read-only), the scenario bounds from it, and the profile host lane that serves the target (WORKLOAD.<target>.HOST,
    Phase 25b). With control.enabled, the on-demand activity control's CONTROL.* checks (Test-DemoActivityControl, ADR 0020). T1 and T3 run on sqlvm01, and T2 through the host into the guest, so each needs that VM running; T2
    also needs the host's last step, after the setup wizard. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command'
    foreach ($target in @('T1', 'T2', 'T3', 'T4' | Where-Object { $_ -in $Context.Target })) {
        $checkId = 'WORKLOAD.{0}.COMMAND' -f $target
        if ($target -eq 'T2' -and $Context.Arc.EvaluationOnly) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T2' -Status 'Not selected' -Message 'The evaluation-only T2 mode has no workload runner (risk R188).' -DocUrl $docUrl -EvaluationOnly))
            continue
        }
        $vmName = if ($target -eq 'T2') { $Context.Arc.HostVmName } else { 'sqlvm01' }
        $state = Get-DemoValidationVmState -Context $Context -VmName $vmName
        if (-not $state.Running) {
            $results.Add((New-DemoValidationStoppedResult -CheckId $checkId -Area 'workload' -Target $target -VmState $state -Context $Context -Checks ('the {0} workload checks' -f $target)))
            continue
        }
        if ($target -eq 'T3') {
            $t3 = Get-DemoValidationT3State -Context $Context
            if ($t3.Missing) {
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T3' -Status 'Warning' -Message 'T3 isn''t deployed now, so it runs no workload: stop-demo.ps1 -RemoveT3 removes it between demos, and start-demo.ps1 recreates it.' -Remediation 'Start the demo (./scripts/start-demo.ps1), then run validate.ps1 -Area Workload again.' -DocUrl $docUrl))
                continue
            }
        }
        if ($target -eq 'T4') {
            if (-not (Test-DemoT4Enabled -Config $Context.Config)) {
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T4' -Status 'Not selected' -Message 'T4 is off in this configuration (t4Enabled is false).'))
                continue
            }
            $quiet = Get-DemoValidationQuietReason -Context $Context -Target 'T4'
            if ($quiet) {
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T4' -Status 'Warning' -Message ('{0}, so it runs no workload.' -f $quiet) -Remediation 'Start the demo (./scripts/start-demo.ps1 starts T4), then run validate.ps1 -Area Workload again.' -DocUrl $docUrl))
                continue
            }
        }
        if ($target -eq 'T2') {
            $read = Get-DemoValidationHealth -Context $Context -VmName $vmName
            $hostState = [string](Get-DemoMemberValue -InputObject $read.Health -Name 'state')
            if ($null -eq $read.Health) {
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T2' -Status 'Warning' -Message ('The T2 runner wasn''t checked, because health.json on {0} couldn''t be read: {1}' -f $vmName, $read.Error) -Remediation 'Run validate.ps1 -Area Workload again in about 10 minutes.' -DocUrl $docUrl))
                continue
            }
            if ($hostState -eq 'ManualActionRequired') {
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T2' -Status 'Manual action required' -Message ('The T2 runner is installed in the host''s last step, after the manual step health.json reports: {0}' -f [string](Get-DemoMemberValue -InputObject $read.Health -Name 'message')) -Evidence @{ hostState = $hostState } -Remediation 'Finish the setup-wizard step in docs/deployment.md; the host then configures SQL Server, seeds ContosoCare, and installs the runner.' -DocUrl $docUrl))
                continue
            }
            if ($hostState -ne 'Ready') {
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T2' -Status 'Warning' -Message ('{0} is in state {1}; the T2 runner is installed in its last step (WorkloadRunner).' -f $vmName, $hostState) -Evidence @{ hostState = $hostState } -Remediation 'Wait for the host to report Ready, then run validate.ps1 -Area Workload again.' -DocUrl $docUrl))
                continue
            }
        }
        try {
            $run = Invoke-DemoWorkloadCommand -Config $Context.Config -Target $target -ArgumentList @('status', '--json', '--runs', '5') -TimeoutSeconds 180 -Confirm:$false
        }
        catch {
            $message = Protect-DemoText -Text $_.Exception.Message
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target $target -Status 'Warning' -Message ('The runner''s status on {0} couldn''t be read: {1} {2}' -f $target, $message, (Get-DemoValidationRunCommandNote -ErrorText $message)) -Remediation 'Run validate.ps1 -Area Workload again in about 10 minutes.' -DocUrl $docUrl))
            continue
        }
        $results.Add($run.Result)
        if ($run.Status -in 'Pass', 'Warning') {
            $results.Add((Test-DemoValidationWorkloadBound -Target $target -StdOut $run.StdOut))
            $results.Add((Test-DemoValidationWorkloadHost -Target $target -StdOut $run.StdOut -VmName $vmName))
        }
    }
    # The optional on-demand activity control (ADR 0020): CONTROL.*, read-only, or one Not selected when it's off.
    foreach ($item in @(Test-DemoActivityControl -Config $Context.Config)) {
        $results.Add($item)
    }
    return $results.ToArray()
}

function Invoke-DemoValidationCost {
    <#
    .SYNOPSIS
    The Cost area: the live-price estimate against the ceilings (reused from the Preflight area when it ran),
    the budget, the auto-shutdown schedules, and anything on demand that's still billing: Bastion, or its
    public IP left by an interrupted delete. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $config = $Context.Config
    $group = $Context.ResourceGroup
    $results = [System.Collections.Generic.List[object]]::new()

    if (@($Context.Results | Where-Object { $_.checkId -like 'PREFLIGHT.COST.*' }).Count -eq 0) {
        $parameters = @{ Config = $config; NetworkMode = (Get-DemoValidationNetworkMode -Context $Context) }
        try {
            $parameters['DefenderPlans'] = @(Get-DemoDefenderPlan -SubscriptionId $Context.SubscriptionId)
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The Defender for Cloud plans couldn''t be read, so the estimate excludes them: {0}' -f $_.Exception.Message)
        }
        try {
            $parameters['T3UseFreeLimit'] = [bool](Get-DemoT3FreeOfferStatus -Config $config).UseFreeLimit
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The T3 free offer couldn''t be checked, so T3 is priced as regular serverless: {0}' -f $_.Exception.Message)
        }
        try {
            $parameters['GoldenSnapshots'] = @(Get-DemoT2GoldenSnapshot -Config $config)
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The T2 golden snapshots couldn''t be listed, so the estimate leaves them out: {0}' -f $_.Exception.Message)
        }
        try {
            foreach ($item in @((Get-DemoCostEstimate @parameters).Results)) {
                $results.Add($item)
            }
        }
        catch {
            $results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.SESSION' -Area 'preflight' -Target 'subscription' -Status 'Warning' -Message ('The cost estimate couldn''t be computed: {0}' -f $_.Exception.Message) -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices'))
        }
    }
    if (-not $Context.GroupExists) {
        return $results.ToArray()
    }

    # The budget (ADR 0016): budget-<prefix>-<environment>, monthly, at the hard ceiling.
    $budgetDoc = 'https://learn.microsoft.com/cli/azure/consumption/budget'
    $budgetName = 'budget-{0}-{1}' -f $config['prefix'], $config['environment']
    $ceiling = [double]$config['monthlyCeilingUsd']
    $budgets = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('consumption', 'budget', 'list', '--resource-group', $group)
    if (-not $budgets.Ok) {
        $results.Add((New-DemoResult -CheckId 'COST.BUDGET' -Area 'cost' -Target 'subscription' -Status 'Warning' -Message ('The budgets on {0} couldn''t be read: {1}' -f $group, $budgets.Error) -Remediation 'Check that you can read the resource group''s budgets (Contributor or Cost Management Reader), then run validate.ps1 -Area Cost again.' -DocUrl $budgetDoc))
    }
    else {
        $budget = @($budgets.Value) | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -eq $budgetName } | Select-Object -First 1
        if ($null -eq $budget) {
            $results.Add((New-DemoResult -CheckId 'COST.BUDGET' -Area 'cost' -Target 'subscription' -Status 'Fail' -Message ('The budget {0} is missing, so nobody is alerted as spend approaches the {1} USD ceiling.' -f $budgetName, $ceiling) -Remediation 'Deploy again (deploy.ps1 -Resume); the template creates the budget with alerts at 50, 80, and 100 percent (ADR 0016).' -DocUrl $budgetDoc))
        }
        else {
            $amount = [double](Get-DemoMemberValue -InputObject $budget -Name 'amount')
            $grain = [string](Get-DemoMemberValue -InputObject $budget -Name 'timeGrain')
            $evidence = [ordered]@{ budget = $budgetName; amount = $amount; timeGrain = $grain; monthlyCeilingUsd = $ceiling }
            if ($amount -ne $ceiling -or $grain -ne 'Monthly') {
                $results.Add((New-DemoResult -CheckId 'COST.BUDGET' -Area 'cost' -Target 'subscription' -Status 'Warning' -Message ('The budget {0} is {1} ({2}), not the configured monthly ceiling of {3} USD.' -f $budgetName, $amount, $grain, $ceiling) -Evidence $evidence -Remediation 'Deploy again (deploy.ps1 -Resume) to set the budget to monthlyCeilingUsd.' -DocUrl $budgetDoc))
            }
            else {
                $results.Add((New-DemoResult -CheckId 'COST.BUDGET' -Area 'cost' -Target 'subscription' -Status 'Pass' -Message ('The budget {0} alerts at the {1} USD monthly ceiling.' -f $budgetName, $ceiling) -Evidence $evidence -DocUrl $budgetDoc))
            }
        }
    }

    # Auto-shutdown schedules for the selected VMs (DevTest Labs, ADR 0016).
    $scheduleDoc = 'https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm'
    $time = [string]$config['autoShutdownTime']
    $zone = [string]$config['autoShutdownTimeZone']
    $problems = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $checked = [System.Collections.Generic.List[string]]::new()
    foreach ($vmName in @($Context.VmNames.Values)) {
        # Named, not --ids: Invoke-DemoAz adds --subscription to every call (as Invoke-DemoArcMonitoringUpdate does).
        $schedule = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('resource', 'show', '--resource-group', $group, '--name', ('shutdown-computevm-{0}' -f $vmName), '--resource-type', 'Microsoft.DevTestLab/schedules')
        if (-not $schedule.Ok) {
            $missing.Add($vmName)
            continue
        }
        $properties = Get-DemoMemberValue -InputObject $schedule.Value -Name 'properties'
        $scheduleStatus = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
        $scheduleTime = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'dailyRecurrence') -Name 'time')
        $scheduleZone = [string](Get-DemoMemberValue -InputObject $properties -Name 'timeZoneId')
        $checked.Add(('{0} {1} {2} ({3})' -f $vmName, $scheduleTime, $scheduleZone, $scheduleStatus))
        if ($scheduleStatus -ne 'Enabled') {
            $problems.Add(('{0}''s schedule is {1}' -f $vmName, $scheduleStatus))
        }
        elseif ($scheduleTime -ne $time -or $scheduleZone -ne $zone) {
            $problems.Add(('{0} shuts down at {1} {2}, not {3} {4}' -f $vmName, $scheduleTime, $scheduleZone, $time, $zone))
        }
    }
    $evidence = [ordered]@{ schedules = $checked.ToArray(); configured = ('{0} {1}' -f $time, $zone) }
    if ($missing.Count -gt 0) {
        $results.Add((New-DemoResult -CheckId 'COST.AUTOSHUTDOWN' -Area 'cost' -Target 'subscription' -Status 'Fail' -Message ('No auto-shutdown schedule for {0}, so it runs until someone stops it.' -f ($missing -join ', ')) -Evidence $evidence -Remediation 'Deploy again (deploy.ps1 -Resume); the template creates the schedules (ADR 0016).' -DocUrl $scheduleDoc))
    }
    elseif ($problems.Count -gt 0) {
        $results.Add((New-DemoResult -CheckId 'COST.AUTOSHUTDOWN' -Area 'cost' -Target 'subscription' -Status 'Warning' -Message ('The auto-shutdown schedules differ from the configuration: {0}.' -f ($problems -join '; ')) -Evidence $evidence -Remediation 'Deploy again (deploy.ps1 -Resume) to restore autoShutdownTime and autoShutdownTimeZone.' -DocUrl $scheduleDoc))
    }
    elseif ($checked.Count -gt 0) {
        $results.Add((New-DemoResult -CheckId 'COST.AUTOSHUTDOWN' -Area 'cost' -Target 'subscription' -Status 'Pass' -Message ('Auto-shutdown is enabled at {0} {1} for {2}.' -f $time, $zone, (@($Context.VmNames.Values) -join ' and ')) -Evidence $evidence -DocUrl $scheduleDoc))
    }

    # On-demand Bastion and public IPs (C8). An interrupted Bastion delete can leave its public IP (live finding, 2026-10-20).
    $bastionDoc = 'https://learn.microsoft.com/azure/bastion/bastion-overview'
    $bastionName = 'bas-{0}-{1}' -f $config['prefix'], $config['environment']
    $bastionIp = 'pip-{0}-{1}-bastion' -f $config['prefix'], $config['environment']
    $natIp = 'pip-{0}-{1}-nat' -f $config['prefix'], $config['environment']
    $hosts = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('resource', 'list', '--resource-group', $group, '--resource-type', 'Microsoft.Network/bastionHosts')
    $addresses = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('network', 'public-ip', 'list', '--resource-group', $group)
    if (-not $hosts.Ok -or -not $addresses.Ok) {
        $readError = @($hosts.Error, $addresses.Error | Where-Object { $_ }) -join ' '
        $results.Add((New-DemoResult -CheckId 'COST.BASTION' -Area 'cost' -Target 'subscription' -Status 'Warning' -Message ('Bastion and public IPs in {0} couldn''t be read: {1}' -f $group, $readError) -Remediation 'Run validate.ps1 -Area Cost again.' -DocUrl $bastionDoc))
        return $results.ToArray()
    }
    $hostNames = @(@($hosts.Value) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
    $ipNames = @(@($addresses.Value) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
    $expectedNat = [string]$config['outboundMode'] -eq 'NatGateway'
    $unexpected = @($ipNames | Where-Object { $_ -ne $bastionIp -and -not ($expectedNat -and $_ -eq $natIp) })
    $evidence = [ordered]@{ bastionHosts = $hostNames; publicIps = $ipNames; expectedBastion = $bastionName; expectedBastionIp = $bastionIp }
    $deleteIp = 'az network public-ip delete --resource-group {0} --name {{0}} --subscription {1}' -f $group, $Context.SubscriptionId
    if ($hostNames.Count -gt 0) {
        $results.Add((New-DemoResult -CheckId 'COST.BASTION' -Area 'cost' -Target 'subscription' -Status 'Warning' -Message ('Bastion is still deployed ({0}); it and its public IP bill every hour until they''re removed.' -f ($hostNames -join ', ')) -Evidence $evidence -Remediation 'Remove it when the interactive session ends: ./scripts/stop-demo.ps1 removes Bastion and its public IP; the bastion-cleanup workflow removes it after bastionMaxHours.' -DocUrl $bastionDoc))
    }
    elseif ($ipNames -contains $bastionIp) {
        $results.Add((New-DemoResult -CheckId 'COST.BASTION' -Area 'cost' -Target 'subscription' -Status 'Warning' -Message ('Bastion is gone, but its public IP {0} is still there, as an interrupted delete leaves it; it bills every hour.' -f $bastionIp) -Evidence $evidence -Remediation ('Delete it: {0}' -f ($deleteIp -f $bastionIp)) -DocUrl 'https://learn.microsoft.com/cli/azure/network/public-ip'))
    }
    elseif ($unexpected.Count -gt 0) {
        $results.Add((New-DemoResult -CheckId 'COST.BASTION' -Area 'cost' -Target 'subscription' -Status 'Warning' -Message ('Public IPs that the demo doesn''t create are in {0}: {1}; each bills every hour.' -f $group, ($unexpected -join ', ')) -Evidence $evidence -Remediation ('Check who added them, then delete them: {0}' -f ($deleteIp -f '<name>')) -DocUrl 'https://learn.microsoft.com/cli/azure/network/public-ip'))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'COST.BASTION' -Area 'cost' -Target 'subscription' -Status 'Pass' -Message 'No Bastion and no leftover public IP: nothing on demand is billing.' -Evidence $evidence -DocUrl $bastionDoc))
    }
    return $results.ToArray()
}
