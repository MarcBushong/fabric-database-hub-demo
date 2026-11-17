# The T2 host's automatic rebuild (2026-11-17; the owner's decision: "Automatically: deploy.ps1 deletes and recreates only
# the T2 host, once, when its agent stays dead"). The last resort after R871's in-place recovery: when archost01's VM agent
# still isn't Ready after its chunk Run Commands' deletes and one deallocate and start (Invoke-DemoVmRestartRecovery,
# AgentDead), the T2 track deletes archost01 with its disks and creates it again from its own template, the nested deployment
# archost01 of azuredeploy.json, with the values its last deployment recorded; then T2 is built on it again in the same run.
# Live (2026-11-17), a host whose chunk Run Commands an earlier version had sent while its agent was down kept them in
# Creating and Deleting through two deallocates, and only a new host could run T2 again. T2's old Arc machine is replaced
# when the new guest onboards (Get-DemoArcOnboardingDecision, CleanupStaleThenOnboard). ASCII-only, like every PowerShell
# file.

function Find-DemoNestedTemplate {
    # The template of the nested deployment (Microsoft.Resources/deployments) named -Name in a compiled ARM template, searched
    # depth first; resources are an array, or an object keyed by symbolic name (languageVersion 2.0). $null when there's none.
    # Pure. Internal.
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [string] $Name,

        [ValidateRange(0, 16)]
        [int] $Depth = 0
    )

    if ($null -eq $Template -or $Depth -gt 8) {
        return $null
    }
    $resources = $Template['resources']
    $items = if ($resources -is [System.Collections.IDictionary]) { @($resources.Values) } else { @($resources) }
    foreach ($item in $items) {
        if ($item -isnot [System.Collections.IDictionary] -or [string]$item['type'] -ne 'Microsoft.Resources/deployments') {
            continue
        }
        $properties = $item['properties']
        $inner = if ($properties -is [System.Collections.IDictionary]) { $properties['template'] } else { $null }
        if ($inner -isnot [System.Collections.IDictionary]) {
            continue
        }
        if ([string]$item['name'] -eq $Name) {
            return $inner
        }
        $found = Find-DemoNestedTemplate -Template $inner -Name $Name -Depth ($Depth + 1)
        if ($null -ne $found) {
            return $found
        }
    }
    return $null
}

function Get-DemoT2HostTemplate {
    <#
    .SYNOPSIS
    The T2 host's own template: the nested deployment archost01 (infra/modules/archost01.bicep, compiled) of the template
    every deployment uses, azuredeploy.json. Throws when it isn't there. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [string] $TemplatePath = (Join-Path -Path $script:RepoRoot -ChildPath 'azuredeploy.json')
    )

    $document = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 200
    $found = Find-DemoNestedTemplate -Template $document -Name 'archost01'
    if ($null -eq $found) {
        throw ('{0} has no nested deployment archost01.' -f (Split-Path -Path $TemplatePath -Leaf))
    }
    return $found
}

function Get-DemoT2HostDeploymentParameter {
    <#
    .SYNOPSIS
    The parameters that create archost01 again with its own template (Get-DemoT2HostTemplate): the values the host's last
    deployment recorded in the resource group (the nested deployment archost01, Deployments - Get), with the OS profile
    included (the VM is new), no golden disk (the new host builds its guest), and no disk type overrides (its disks are new).
    adminPassword isn't recorded and is left out: New-DemoT2HostVm adds a new one. A parameter the template declares
    without a default and the record doesn't have makes it fail. Returns Ok, Parameters (name, then @{ value }), and Error.
    A read. Internal.
    Source: https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-show (checked 2026-11-17).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template
    )

    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'group', 'show', '--resource-group', $resourceGroupName, '--name', 'archost01', '--query', 'properties.parameters', '--output', 'json') -AllowFailure -TimeoutSeconds 120
    if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
        return [pscustomobject]@{ Ok = $false; Parameters = $null; Error = ('archost01''s last deployment record in {0} couldn''t be read: {1}' -f $resourceGroupName, (Get-DemoDeploymentErrorText -Text ([string]$read.StdErr) -MaxLength 300)) }
    }
    try {
        $recorded = [string]$read.StdOut | ConvertFrom-Json -AsHashtable -Depth 64
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Parameters = $null; Error = ('archost01''s last deployment record wasn''t JSON: {0}' -f $_.Exception.Message) }
    }
    if ($recorded -isnot [System.Collections.IDictionary]) {
        return [pscustomobject]@{ Ok = $false; Parameters = $null; Error = 'archost01''s last deployment record has no parameters.' }
    }
    $declared = $Template['parameters']
    if ($declared -isnot [System.Collections.IDictionary]) {
        return [pscustomobject]@{ Ok = $false; Parameters = $null; Error = 'archost01''s template declares no parameters.' }
    }
    # A new VM: its OS profile (with the new password), the marketplace image, and its own disks' types.
    $overrides = @{ includeOsProfile = $true; osDiskSourceResourceId = ''; attachExistingOsDisk = $false; diskSkuOverrides = @{} }
    $parameters = [ordered]@{}
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($declared.Keys)) {
        if ($name -eq 'adminPassword') {
            continue
        }
        if ($overrides.Contains($name)) {
            $parameters[$name] = @{ value = $overrides[$name] }
            continue
        }
        $entry = $recorded[$name]
        if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('value')) {
            $parameters[$name] = @{ value = $entry['value'] }
            continue
        }
        $definition = $declared[$name]
        if (-not ($definition -is [System.Collections.IDictionary] -and $definition.Contains('defaultValue'))) {
            $missing.Add([string]$name)
        }
    }
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Parameters = $null; Error = ('archost01''s last deployment record has no value for {0}, which its template needs' -f ($missing -join ', ')) }
    }
    return [pscustomobject]@{ Ok = $true; Parameters = $parameters; Error = '' }
}

function Reset-DemoT2HostRecord {
    <#
    .SYNOPSIS
    Clears what the resource group's state records for the T2 host, for a host that's new or gone (2026-11-17): archost01
    leaves BundleSentTo and RunnerSentTo, so its artifacts are sent again; the T2 track's record, the guest build's record,
    and the guest's install mode go; the T2 source is build. Under the tracks' lock (Set-DemoDeploymentStateLocked). Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if (-not $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), 'Clear what the deployment state records for archost01')) {
        return
    }
    Set-DemoDeploymentStateLocked -Config $Config -Value @{ TrackT2 = ''; T2BuildUtc = ''; T2Source = 'build'; T2InstallMode = '' } -RemoveBundleVm 'archost01' -RemoveRunnerVm 'archost01' -Confirm:$false
}

function Remove-DemoT2HostVm {
    <#
    .SYNOPSIS
    Deletes archost01 for its rebuild (2026-11-17): az vm delete (its OS disk and network interface go with it: deleteOption
    Delete in infra/modules/windows-vm.bicep), then waits until Azure no longer has it, at most -TimeoutMinutes, then deletes
    what can outlive it: its data disk (deleteOption Detach), and an OS disk or a network interface that's still there. Returns
    Deleted, Detail, Seconds, and Removed (what it deleted besides the VM). Never throws. Internal.
    Sources: https://learn.microsoft.com/cli/azure/vm#az-vm-delete, https://learn.microsoft.com/cli/azure/disk#az-disk-delete,
    https://learn.microsoft.com/azure/virtual-machines/delete (checked 2026-11-17).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(1, 120)]
        [int] $TimeoutMinutes = 30,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 20,

        [AllowEmptyString()]
        [string] $ProgressPath = ''
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $removed = [System.Collections.Generic.List[string]]::new()
    $answer = { param([bool] $Deleted, [string] $Detail) [pscustomobject]@{ Deleted = $Deleted; Detail = $Detail; Seconds = [int]$watch.Elapsed.TotalSeconds; Removed = $removed.ToArray() } }
    if (-not $PSCmdlet.ShouldProcess('archost01', 'Delete the VM and its disks')) {
        return (& $answer $false 'what if: nothing was deleted')
    }
    $delete = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList @('vm', 'delete', '--resource-group', $resourceGroupName, '--name', 'archost01', '--yes', '--no-wait') -Label 'archost01: delete' -MaxConflictRetries 6 -TimeoutSeconds 300
    if ($delete.ExitCode -ne 0 -and -not (Test-DemoAzNotFound -Text ([string]$delete.StdErr))) {
        return (& $answer $false ('Azure refused its delete: {0}' -f (Get-DemoDeploymentErrorText -Text ([string]$delete.StdErr) -MaxLength 300)))
    }
    # The wait counts its own polls, -PollSeconds apart, up to -TimeoutMinutes.
    $maxPolls = [int][System.Math]::Ceiling(($TimeoutMinutes * 60) / $PollSeconds)
    $gone = $false
    for ($poll = 0; $true; $poll++) {
        $show = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $resourceGroupName, '--name', 'archost01', '--query', 'provisioningState', '--output', 'tsv') -AllowFailure -TimeoutSeconds 120
        if ($show.ExitCode -ne 0 -and (Test-DemoAzNotFound -Text ([string]$show.StdErr))) {
            $gone = $true
            break
        }
        if ($poll -ge $maxPolls) {
            break
        }
        Set-DemoProgressStep -Path $ProgressPath -Id 'T2.HostRebuild' -State 'Running' -AzureSide -Message ('Deleting archost01 and its disks: {0} so far (Azure-side; no action needed).' -f (Format-DemoProgressDuration -Seconds ([long]$watch.Elapsed.TotalSeconds)))
        Start-Sleep -Seconds $PollSeconds
    }
    if (-not $gone) {
        return (& $answer $false ('Azure hadn''t deleted it after {0} minutes' -f $TimeoutMinutes))
    }
    foreach ($item in @(
            [pscustomobject]@{ Group = @('disk'); Name = 'archost01-data01'; Extra = @('--yes') }
            [pscustomobject]@{ Group = @('disk'); Name = 'archost01-osdisk'; Extra = @('--yes') }
            [pscustomobject]@{ Group = @('network', 'nic'); Name = 'nic-archost01'; Extra = @() }
        )) {
        $exists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList (@($item.Group) + @('show', '--resource-group', $resourceGroupName, '--name', $item.Name, '--query', 'id', '--output', 'tsv')) -AllowFailure -TimeoutSeconds 120
        if ($exists.ExitCode -ne 0) {
            if (Test-DemoAzNotFound -Text ([string]$exists.StdErr)) {
                continue
            }
            return (& $answer $false ('{0} couldn''t be read: {1}' -f $item.Name, (Get-DemoDeploymentErrorText -Text ([string]$exists.StdErr) -MaxLength 300)))
        }
        $gone = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList (@($item.Group) + @('delete', '--resource-group', $resourceGroupName, '--name', $item.Name) + @($item.Extra)) -Label ('{0}: delete' -f $item.Name) -MaxConflictRetries 6 -TimeoutSeconds 900
        if ($gone.ExitCode -ne 0 -and -not (Test-DemoAzNotFound -Text ([string]$gone.StdErr))) {
            return (& $answer $false ('{0} couldn''t be deleted: {1}' -f $item.Name, (Get-DemoDeploymentErrorText -Text ([string]$gone.StdErr) -MaxLength 300)))
        }
        $removed.Add($item.Name)
    }
    return (& $answer $true '')
}

function New-DemoT2HostVm {
    <#
    .SYNOPSIS
    Creates archost01 again from its own template (Get-DemoT2HostTemplate) with -Parameters (Get-DemoT2HostDeploymentParameter)
    and a new administrator password: generated, registered for redaction, written only to a private parameters file, and
    discarded afterward, as the main template's deployment does for a new VM (ADR 0009). The resource group's deployment
    archost01-rebuild, bounded by -TimeoutMinutes. Returns Created, Detail, and Seconds. Internal.
    Source: https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-create (checked 2026-11-17).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Parameters,

        [ValidateRange(1, 120)]
        [int] $TimeoutMinutes = 40
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $PSCmdlet.ShouldProcess('archost01', 'Create the VM again from its template (deployment archost01-rebuild)')) {
        return [pscustomobject]@{ Created = $false; Detail = 'what if: nothing was created'; Seconds = 0 }
    }
    $run = $null
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-rebuild'
    try {
        $values = [ordered]@{}
        foreach ($key in $Parameters.Keys) {
            $values[$key] = $Parameters[$key]
        }
        $secure = New-DemoAdminPassword
        $values['adminPassword'] = @{ value = [System.Net.NetworkCredential]::new('', $secure).Password }
        $secure.Dispose()
        $document = [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $values }
        $parametersPath = Write-DemoPrivateFile -Directory $directory -Name 'parameters.json' -Content ($document | ConvertTo-Json -Depth 64)
        $values = $null
        $document = $null
        $templatePath = Write-DemoPrivateFile -Directory $directory -Name 'archost01.json' -Content ($Template | ConvertTo-Json -Depth 100)
        $run = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'group', 'create', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', 'archost01-rebuild', '--template-file', $templatePath, '--parameters', "@$parametersPath", '--output', 'json') -AllowFailure -TimeoutSeconds ($TimeoutMinutes * 60)
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    if ($run.ExitCode -ne 0) {
        return [pscustomobject]@{ Created = $false; Detail = ('the deployment archost01-rebuild failed: {0}' -f (Get-DemoDeploymentErrorText -Text ([string]$run.StdErr) -MaxLength 400)); Seconds = [int]$watch.Elapsed.TotalSeconds }
    }
    $state = ''
    try {
        $state = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject ([string]$run.StdOut | ConvertFrom-Json -Depth 64) -Name 'properties') -Name 'provisioningState')
    }
    catch {
        $state = ''
    }
    if ($state -ne 'Succeeded') {
        return [pscustomobject]@{ Created = $false; Detail = ('the deployment archost01-rebuild ended {0}' -f $(if ($state) { $state } else { 'without a state' })); Seconds = [int]$watch.Elapsed.TotalSeconds }
    }
    return [pscustomobject]@{ Created = $true; Detail = ''; Seconds = [int]$watch.Elapsed.TotalSeconds }
}

function Test-DemoT2HostDeadResult {
    # Whether -Result holds the watchdog's Fail for the T2 host whose agent stayed down through its deallocate and start
    # (DEPLOY.WATCHDOG_ARCHOST01, evidence agentDead): the T2 track's cue for the host's rebuild. Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    foreach ($item in @($Result | Where-Object { $null -ne $_ })) {
        if ([string]$item.checkId -ne 'DEPLOY.WATCHDOG_ARCHOST01' -or [string]$item.status -ne 'Fail') {
            continue
        }
        if ([bool](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'evidence') -Name 'agentDead')) {
            return $true
        }
    }
    return $false
}

function Set-DemoT2HostRebuildSuperseded {
    # After the T2 host's rebuild, what the failed attempt on the old host reported as a Fail becomes a Warning that says the
    # rebuild took over, so it never blocks DONE; DEPLOY.T2.HOSTREBUILD stays as it is. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes in-memory results only.')]
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    foreach ($item in @($Result | Where-Object { $null -ne $_ -and [string]$_.status -eq 'Fail' -and [string]$_.checkId -ne 'DEPLOY.T2.HOSTREBUILD' })) {
        $item.status = 'Warning'
        $item.message = '{0} deploy.ps1 then rebuilt archost01 (DEPLOY.T2.HOSTREBUILD).' -f ([string]$item.message).TrimEnd()
        $item.remediation = 'Nothing to do: deploy.ps1 rebuilt archost01 and builds T2 on it again in this run (DEPLOY.T2.HOSTREBUILD).'
    }
}

function Invoke-DemoT2HostRebuild {
    <#
    .SYNOPSIS
    Rebuilds the T2 host once (2026-11-17): archost01's template and its last deployment's values are read first, so nothing
    is deleted when they can't be; then the state's records for the host are cleared (Reset-DemoT2HostRecord), archost01 is
    deleted with its disks (Remove-DemoT2HostVm), created again from its template (New-DemoT2HostVm), and waited for until its
    VM agent is Ready. Returns Rebuilt, Result (DEPLOY.T2.HOSTREBUILD: a Warning that says what happened when it worked, a
    Fail with the next step when it didn't), and Results. The status page's T2.HostRebuild row and the console say each
    step. Internal.

    .DESCRIPTION
    The caller, the T2 track, then builds T2 on the new host: its artifacts, its loader (the guest from Arc Jumpstart's image,
    about 27 minutes), Arc onboarding, and telemetry. The new VM's watchdog may act once more (a new machine). The template
    sets the host's auto-shutdown back to autoShutdownTime, so a run that's marked busy moves it out of the run's way again
    at once (Sync-DemoAutoShutdownForBusy), as the busy marker's next refresh would. An interrupted rebuild is finished by
    the next deploy.ps1: a host it deleted is created by the template (Get-DemoT2HostMissingResult), and one it didn't
    delete is recovered, or rebuilt, again.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $Cause = '',

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [ValidateRange(1, 60)]
        [int] $AgentWaitMinutes = 20,

        [ValidateRange(1, 120)]
        [int] $DeleteTimeoutMinutes = 30,

        [ValidateRange(1, 120)]
        [int] $CreateTimeoutMinutes = 40,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 20
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $row = 'T2.HostRebuild'
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/delete'
    $why = if ($Cause) { ' ({0})' -f $Cause.TrimEnd('.') } else { '' }
    $evidence = [ordered]@{ cause = $Cause; deployment = 'archost01-rebuild'; deleteSeconds = 0; createSeconds = 0; agentSeconds = -1; removed = @(); minutes = 0 }
    $finish = {
        param([string] $Status, [string] $Message, [string] $Remediation)
        $evidence['minutes'] = [int][System.Math]::Ceiling($watch.Elapsed.TotalMinutes)
        $result = New-DemoResult -CheckId 'DEPLOY.T2.HOSTREBUILD' -Area 'infra' -Target 'T2' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $docUrl
        Set-DemoProgressStep -Path $ProgressPath -Id $row -State $(if ($Status -eq 'Fail') { 'Failed' } else { 'Done' }) -Status $Status -Message $Message -MaxLength 1200
        Write-DemoLog -Level Warning -Message $Message
        return [pscustomobject]@{ Rebuilt = ($Status -ne 'Fail'); Result = $result; Results = @($result) }
    }
    if ((Get-DemoHostVmName -Config $Config) -ne 'archost01') {
        return (& $finish 'Fail' 'Only the nested T2 host, archost01, is rebuilt automatically; this configuration''s T2 is an Azure VM (t2Mode EvaluationOnlyAzureVm).' 'Rebuild T2 by hand: ./scripts/destroy.ps1, then ./scripts/deploy.ps1.')
    }
    if (-not $PSCmdlet.ShouldProcess('archost01', 'Delete the T2 host and its disks, and create it again from its template')) {
        return [pscustomobject]@{ Rebuilt = $false; Result = $null; Results = @() }
    }
    $mode = [string]$Config['t2SqlInstallMode']
    $total = if ($mode -in 'ProductKey', 'Developer') { 'longer than an hour: Windows and SQL Server are installed from evaluation media' } else { 'about 70 minutes in all; 72 when measured on 2026-11-17' }
    $start = 'archost01''s VM agent stayed down, and a deallocate and start didn''t bring it back{0}, so deploy.ps1 rebuilds T2''s host once now: it deletes archost01 and its disks, creates it again from the template, and builds T2 on it again in this run ({1}); no action needed.' -f $why, $total
    Write-DemoLog -Level Warning -Message $start
    Set-DemoProgressStep -Path $ProgressPath -Id $row -State 'Running' -AzureSide -Message $start -MaxLength 1200
    $template = $null
    try {
        $template = Get-DemoT2HostTemplate
    }
    catch {
        return (& $finish 'Fail' ('archost01''s VM agent stayed down, and a deallocate and start didn''t bring it back{0}, and the host wasn''t rebuilt: its template couldn''t be read ({1}). Nothing was deleted.' -f $why, (Protect-DemoText -Text $_.Exception.Message)) 'Run ./scripts/deploy.ps1 again from a complete checkout of the repository; or rebuild T2 by hand: ./scripts/destroy.ps1, then ./scripts/deploy.ps1.')
    }
    $parameters = Get-DemoT2HostDeploymentParameter -Config $Config -Template $template
    if (-not $parameters.Ok) {
        return (& $finish 'Fail' ('archost01''s VM agent stayed down, and a deallocate and start didn''t bring it back{0}, and the host wasn''t rebuilt: {1}. Nothing was deleted.' -f $why, $parameters.Error) 'Run ./scripts/deploy.ps1 -FromStage Infrastructure: the template records archost01''s deployment again, and the run rebuilds the host if its agent still stays down. Or rebuild T2 by hand: ./scripts/destroy.ps1, then ./scripts/deploy.ps1.')
    }
    Reset-DemoT2HostRecord -Config $Config -Confirm:$false
    Set-DemoProgressStep -Path $ProgressPath -Id $row -State 'Running' -AzureSide -Message 'Deleting archost01 and its disks (Azure-side; no action needed).'
    $removal = Remove-DemoT2HostVm -Config $Config -TimeoutMinutes $DeleteTimeoutMinutes -PollSeconds $PollSeconds -ProgressPath $ProgressPath -Confirm:$false
    $evidence['deleteSeconds'] = $removal.Seconds
    $evidence['removed'] = @($removal.Removed)
    if (-not $removal.Deleted) {
        return (& $finish 'Fail' ('archost01''s VM agent stayed down, and a deallocate and start didn''t bring it back{0}, and its rebuild stopped: archost01 couldn''t be deleted ({1}).' -f $why, $removal.Detail) 'Run ./scripts/deploy.ps1 again in about 30 minutes: it finishes the rebuild, and a host that''s gone by then is created again by the template (DEPLOY.T2.HOSTMISSING).')
    }
    Write-DemoLog -Message ('archost01 is deleted, with {0}, after {1}; it''s created again from the template now.' -f $(if (@($removal.Removed).Count -gt 0) { @($removal.Removed) -join ' and ' } else { 'its OS disk and network interface' }), (Format-DemoProgressDuration -Seconds ([long]$removal.Seconds)))
    Set-DemoProgressStep -Path $ProgressPath -Id $row -State 'Running' -AzureSide -Message 'Creating archost01 again from the template (Azure-side; no action needed).'
    $created = New-DemoT2HostVm -Config $Config -Template $template -Parameters $parameters.Parameters -TimeoutMinutes $CreateTimeoutMinutes -Confirm:$false
    $evidence['createSeconds'] = $created.Seconds
    if (-not $created.Created) {
        return (& $finish 'Fail' ('archost01 was deleted for its rebuild{0}, but creating it again failed: {1}.' -f $why, $created.Detail) 'Run ./scripts/deploy.ps1 again: archost01 doesn''t exist, so it deploys the template, which creates it (DEPLOY.T2.HOSTMISSING), and builds T2 on it.')
    }
    # A new machine: the watchdog may act on it once more in this run.
    $null = $script:DemoVmRestarted.Remove(('{0}/archost01' -f (Get-DemoResourceGroupName -Config $Config)))
    # The template set the host's auto-shutdown back to autoShutdownTime: a run that's marked busy moves it on at once.
    $state = Get-DemoDeploymentState -Config $Config
    $busyUntil = ConvertTo-DemoRunCommandUtc -Value ([string](Get-DemoMemberValue -InputObject $state -Name 'BusyUntilUtc'))
    if ([string](Get-DemoMemberValue -InputObject $state -Name 'BusyBy') -and $null -ne $busyUntil -and $busyUntil -gt [DateTime]::UtcNow) {
        foreach ($change in @(Sync-DemoAutoShutdownForBusy -Config $Config -UntilUtc $busyUntil -Confirm:$false | Where-Object { $_.VmName -eq 'archost01' -and -not $_.Ok })) {
            Write-DemoLog -Level Warning -Message ('archost01''s auto-shutdown couldn''t be moved out of this run''s way after its rebuild: {0}. The busy marker tries again in a few minutes.' -f $change.Error)
        }
    }
    Set-DemoProgressStep -Path $ProgressPath -Id $row -State 'Running' -AzureSide -Message 'archost01 exists again; waiting for its VM agent (Azure-side; no action needed).'
    $agent = Wait-DemoVmAgentReady -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName (Get-DemoResourceGroupName -Config $Config) -VmName 'archost01' -TimeoutMinutes $AgentWaitMinutes -PollSeconds $PollSeconds
    $evidence['agentSeconds'] = $agent
    if ($agent -lt 0) {
        return (& $finish 'Fail' ('archost01 was rebuilt{0}, but the new host''s VM agent wasn''t Ready within {1} minutes either, so the cause is on Azure''s side.' -f $why, $AgentWaitMinutes) 'Run ./scripts/deploy.ps1 again later: it recovers the host, and rebuilds it once more if its agent stays down. If the agent stays down, open a support request with Azure: the VM never gets its goal state from Azure (docs/troubleshooting.md, "A host''s VM agent that isn''t Ready").')
    }
    $minutes = [int][System.Math]::Ceiling($watch.Elapsed.TotalMinutes)
    $build = if ($mode -in 'ProductKey', 'Developer') { 'builds T2''s guest on it in {0} mode and onboards it to Azure Arc (longer than an hour: Windows and SQL Server are installed from evaluation media)' -f $mode } else { 'builds T2 on it from Arc Jumpstart''s image and onboards it to Azure Arc (about an hour)' }
    return (& $finish 'Warning' ('archost01''s VM agent stayed down, and a deallocate and start didn''t bring it back{0}, so deploy.ps1 rebuilt T2''s host in {1} minutes: it deleted archost01 and its disks and created it again from the template, and the new host''s agent is Ready. This run now {2}; T2''s old Arc machine is replaced at onboarding.' -f $why, $minutes, $build) 'Nothing to do: the run goes on with T2. docs/troubleshooting.md ("A host''s VM agent that isn''t Ready") says why it happens.')
}

function Get-DemoT2HostMissingResult {
    <#
    .SYNOPSIS
    DEPLOY.T2.HOSTMISSING (2026-11-17): the T2 host the state records doesn't exist, because a rebuild stopped after deleting
    it (Invoke-DemoT2HostRebuild) or because it was deleted by hand. Clears what the state records for it
    (Reset-DemoT2HostRecord), so its artifacts are sent again, and returns a Pass that says this run creates it with the template
    and builds T2 on it; deploy.ps1 then doesn't resume past the template. $null when there's nothing to do: another T2 mode,
    no record of the host, a host that exists, or one that couldn't be read (fail safe). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State
    )

    if ((Get-DemoHostVmName -Config $Config) -ne 'archost01' -or $null -eq $State -or -not [bool](Get-DemoMemberValue -InputObject $State -Name 'Exists')) {
        return $null
    }
    # Assigned first: Get-DemoMemberValue returns an array as one object.
    $bundleSentTo = Get-DemoMemberValue -InputObject $State -Name 'BundleSentTo'
    $runnerSentTo = Get-DemoMemberValue -InputObject $State -Name 'RunnerSentTo'
    $recorded = 'archost01' -in @($bundleSentTo) -or 'archost01' -in @($runnerSentTo) -or [string](Get-DemoMemberValue -InputObject $State -Name 'TrackT2')
    if (-not $recorded) {
        return $null
    }
    $read = $null
    try {
        $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('vm', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', 'archost01', '--query', 'id', '--output', 'tsv') -AllowFailure -TimeoutSeconds 120
    }
    catch {
        Write-DemoLog -Level Warning -Message ('Whether archost01 exists couldn''t be read ({0}), so this run goes on as the state records.' -f $_.Exception.Message)
        return $null
    }
    if ([int](Get-DemoMemberValue -InputObject $read -Name 'ExitCode') -eq 0 -or -not (Test-DemoAzNotFound -Text ([string](Get-DemoMemberValue -InputObject $read -Name 'StdErr')))) {
        return $null
    }
    Reset-DemoT2HostRecord -Config $Config -Confirm:$false
    $message = 'archost01, T2''s host, doesn''t exist (a rebuild an earlier run started, or a host deleted by hand), so this run deploys the template, which creates it again, and builds T2 on it (about an hour); what the state recorded for the old host is cleared. What earlier runs finished elsewhere is checked again and kept.'
    return (New-DemoResult -CheckId 'DEPLOY.T2.HOSTMISSING' -Area 'infra' -Target 'T2' -Status 'Pass' -Message $message -Evidence ([ordered]@{ recordedStage = [string](Get-DemoMemberValue -InputObject $State -Name 'Stage'); trackT2 = [string](Get-DemoMemberValue -InputObject $State -Name 'TrackT2') }) -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/delete')
}

function Get-DemoT2HostRebuildNote {
    # What DONE or NOT DONE says about the T2 host's rebuild in this run (DEPLOY.T2.HOSTREBUILD, a Warning when it worked) or
    # its re-creation at the start (DEPLOY.T2.HOSTMISSING); '' when neither happened. A rebuild that failed is NOT DONE's own
    # reason. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $rebuild = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'DEPLOY.T2.HOSTREBUILD' -and [string]$_.status -eq 'Warning' })
    if ($rebuild.Count -gt 0) {
        return 'archost01, T2''s host, was rebuilt in this run: its VM agent stayed down, and a deallocate and start didn''t bring it back, so deploy.ps1 deleted it and its disks, created it again from the template, and built T2 on it again (DEPLOY.T2.HOSTREBUILD).'
    }
    $missing = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'DEPLOY.T2.HOSTMISSING' })
    if ($missing.Count -gt 0) {
        return 'archost01, T2''s host, didn''t exist at the start of this run, so the template created it again and T2 was built on it (DEPLOY.T2.HOSTMISSING).'
    }
    return ''
}
