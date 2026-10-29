# Run Commands must never stall a deployment (Phase 28, brief item 14; R49, R336).
# - Before deploy.ps1 sends a VM its artifacts, and before its loader, it waits (at most 20 minutes) until the VM's
#   instance view shows no extension in a transitioning state: on a new VM, Azure Policy installs or updates extensions
#   (MDE.Windows, Guest Configuration, Defender for SQL, AMA), and until they finish the VM agent doesn't process Run
#   Command changes. The log and the status page name each one: "Azure is finishing <extension> on <VM> (installed by
#   a policy in your tenant); no action needed". The Run Command handler itself, and Run Commands Azure is still
#   deleting, don't block: chunk deletes are never waited for, and 25 managed Run Commands per VM are allowed.
# - A watchdog: when that wait, a chunk Run Command, or the loader stays non-terminal past about 15 to 20 minutes, it saves
#   the VM's instance view (agent and extension statuses, redacted) for the diagnostics bundle, restarts that VM once
#   (the T2 host never during the guided stop, the golden Release, or its guest build: Get-DemoHostRestartBlocker), and
#   the run goes on. While the Release runs, archost01's artifacts go without the wait or the watchdog.
#   Still stuck: the run ends NOT DONE, naming the extension and the next step.
# Sources (checked 2026-10-29):
# - az vm get-instance-view: https://learn.microsoft.com/cli/azure/vm#az-vm-get-instance-view
# - az vm restart: https://learn.microsoft.com/cli/azure/vm#az-vm-restart
# - Managed Run Commands and their limits: https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed
# - Extension states and troubleshooting: https://learn.microsoft.com/azure/virtual-machines/extensions/overview

function Get-DemoExtensionLabel {
    # How the status page names one extension: the demo's own (the SQL IaaS Agent extension), or one a policy in the
    # tenant installed. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($Name -match '(?i)SqlIaas') {
        return '{0} (the SQL IaaS Agent extension, which the demo''s SQL VM resource installs)' -f $Name
    }
    return '{0} (installed by a policy in your tenant)' -f $Name
}

function Get-DemoVmExtensionActivity {
    <#
    .SYNOPSIS
    The Azure-side work in progress on one VM, from its instance view (az vm get-instance-view): extensions whose
    provisioning state is Creating, Updating, or Deleting, or whose instance-view status is transitioning. The Run Command
    handler isn't counted. Also lists the Run Commands Azure is still deleting, which don't make it busy. Returns
    Readable, Busy, Items (each extension with its state), Labels (for the status page), RunCommandsDeleting, and View
    (the instance view, for diagnostics). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $busyStates = @('Creating', 'Updating', 'Deleting')
    $items = [System.Collections.Generic.List[string]]::new()
    $labels = [System.Collections.Generic.List[string]]::new()
    $named = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $add = {
        param([string] $Name, [string] $State)
        if ($Name -and $Name -notmatch '(?i)RunCommandHandler' -and $named.Add($Name)) {
            $items.Add(('{0} ({1})' -f $Name, $State))
            $labels.Add((Get-DemoExtensionLabel -Name $Name))
        }
    }
    $view = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'get-instance-view', '--resource-group', $resourceGroupName, '--name', $VmName, '--output', 'json') -AsJson -AllowFailure
    if ($null -ne $view) {
        # Get-DemoMemberList returns its list as one object: it's assigned before it's enumerated.
        $resources = Get-DemoMemberList -InputObject $view -Name 'resources'
        foreach ($resource in $resources) {
            $state = [string](Get-DemoMemberValue -InputObject $resource -Name 'provisioningState')
            if ($state -in $busyStates) {
                & $add ([string](Get-DemoMemberValue -InputObject $resource -Name 'name')) $state
            }
        }
        $instanceView = Get-DemoMemberValue -InputObject $view -Name 'instanceView'
        $extensions = Get-DemoMemberList -InputObject $instanceView -Name 'extensions'
        foreach ($extension in $extensions) {
            $statuses = Get-DemoMemberList -InputObject $extension -Name 'statuses'
            $codes = @(foreach ($status in $statuses) { [string](Get-DemoMemberValue -InputObject $status -Name 'code') })
            $moving = @($codes | Where-Object { $_ -match '(?i)^ProvisioningState/(transitioning|creating|updating|deleting)$' })
            if ($moving.Count -gt 0) {
                & $add ([string](Get-DemoMemberValue -InputObject $extension -Name 'name')) ($moving[0] -replace '(?i)^ProvisioningState/', '')
            }
        }
    }
    $baseUrl = Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName
    $list = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('{0}?api-version={1}' -f $baseUrl, (Get-DemoRunCommandApiVersion))) -AsJson -AllowFailure
    $runCommands = Get-DemoMemberList -InputObject $list -Name 'value'
    $deleting = @(foreach ($item in $runCommands) {
            if ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'properties') -Name 'provisioningState') -eq 'Deleting') {
                [string](Get-DemoMemberValue -InputObject $item -Name 'name')
            }
        })
    return [pscustomobject]@{
        Readable            = ($null -ne $view)
        Busy                = ($items.Count -gt 0)
        Items               = $items.ToArray()
        Labels              = $labels.ToArray()
        RunCommandsDeleting = $deleting
        View                = $view
    }
}

function Wait-DemoVmExtensionSettled {
    <#
    .SYNOPSIS
    Waits at most -TimeoutMinutes until no extension on the VM is transitioning (Get-DemoVmExtensionActivity), and names
    each one in the log and on the status page's -ProgressId step: "Azure is finishing <extension> on <VM> (installed
    by a policy in your tenant); no action needed". Returns Settled, Minutes, and Activity (the last read). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $VmName,

        [ValidateRange(0, 120)]
        [int] $TimeoutMinutes = 20,

        [ValidateRange(1, 600)]
        [int] $PollSeconds = 30,

        [string] $ProgressPath = '',

        [string[]] $ProgressId = @()
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextLog = [System.DateTime]::MinValue
    $waited = $false
    while ($true) {
        $activity = Get-DemoVmExtensionActivity -Config $Config -VmName $VmName
        $minutes = [int][System.Math]::Floor($watch.Elapsed.TotalMinutes)
        if (-not $activity.Busy) {
            if ($waited) {
                Write-DemoLog -Message ('{0}: Azure finished its extension work after {1} minute(s).' -f $VmName, $minutes)
                Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State 'Running' -Message ('Azure finished its extension work on {0}; continuing.' -f $VmName)
            }
            return [pscustomobject]@{ Settled = $true; Minutes = $minutes; Activity = $activity }
        }
        $waited = $true
        $text = 'Azure is finishing {0} on {1}; no action needed ({2} min so far).' -f ($activity.Labels -join ', '), $VmName, $minutes
        if ($ProgressPath -and @($ProgressId).Count -gt 0) {
            Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State 'Running' -AzureSide -Message $text
        }
        if ([System.DateTime]::UtcNow -ge $nextLog) {
            Write-DemoLog -Message $text
            $nextLog = [System.DateTime]::UtcNow.AddMinutes(2)
        }
        if ($watch.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
            return [pscustomobject]@{ Settled = $false; Minutes = $minutes; Activity = $activity }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Save-DemoVmInstanceView {
    # Saves a VM's instance view (agent and extension statuses), redacted, to out/diagnostics for
    # collect-diagnostics.ps1. Returns the path, or '' when there's nothing to save or it can't be written. Never throws.
    # Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes a Git-ignored local diagnostics file only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $View,

        [Parameter(Mandatory)]
        [string] $VmName,

        [string] $Directory = ''
    )

    if ($null -eq $View) {
        return ''
    }
    try {
        if (-not $Directory) {
            $Directory = Join-Path -Path $script:RepoRoot -ChildPath 'out/diagnostics'
        }
        if (-not (Test-Path -LiteralPath $Directory)) {
            $null = New-Item -ItemType Directory -Path $Directory -Force
        }
        $stamp = [System.DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $path = Join-Path -Path $Directory -ChildPath ('{0}-instance-view-{1}.json' -f $VmName, $stamp)
        $text = Protect-DemoText -Text (ConvertTo-Json -InputObject $View -Depth 32)
        [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
        return $path
    }
    catch {
        Write-DemoLog -Level Warning -Message ('{0}''s instance view couldn''t be saved for diagnostics: {1}' -f $VmName, $_.Exception.Message)
        return ''
    }
}

function Get-DemoHostRestartBlocker {
    <#
    .SYNOPSIS
    Why the watchdog mustn't restart the T2 host now, or '' when it may (review finding 6): the guided stop's time limit
    is open (its guest may be in the middle of setup); a golden guest action, the Release, runs on it in this process
    (Invoke-DemoGoldenGuestAction); or its guest build runs (health state InProgress or RebootPending). A host whose
    bootstrap never ran (no T2 step past Artifacts, no stage past Artifacts, not a golden copy) has nothing to
    interrupt, so its health isn't read; for any other host, health that can't be read counts as a build that may be
    running. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName = 'archost01'
    )

    $state = Get-DemoDeploymentState -Config $Config
    $until = ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $state -Name 'GuidedStopUtc')
    if ($null -ne $until -and $until -gt [System.DateTime]::UtcNow) {
        return 'its guest may be in the middle of SQL Server setup (the guided stop)'
    }
    $key = '{0}/{1}' -f (Get-DemoResourceGroupName -Config $Config), $VmName
    if ($script:DemoHostAction.ContainsKey($key)) {
        return ('the golden {0} is running on it' -f $script:DemoHostAction[$key])
    }
    $track = [string](Get-DemoMemberValue -InputObject $state -Name 'TrackT2')
    $stage = [string](Get-DemoMemberValue -InputObject $state -Name 'Stage')
    $bootstrapped = $track -in 'Bootstraps', 'T2', 'Telemetry' -or [string](Get-DemoMemberValue -InputObject $state -Name 'T2Source') -eq 'golden' -or ($stage -and (Test-DemoDeploymentStageReached -Recorded $stage -Stage 'Bootstraps'))
    if (-not $bootstrapped) {
        return ''
    }
    try {
        $health = Get-DemoVmHealth -Config $Config -VmName $VmName -View Summary -TimeoutSeconds 120
    }
    catch {
        return ('its health couldn''t be read ({0}), and its guest build may be running' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    $hostState = [string](Get-DemoMemberValue -InputObject $health -Name 'state')
    if ($hostState -in 'InProgress', 'RebootPending') {
        return ('its guest build is running (step {0})' -f [string](Get-DemoMemberValue -InputObject $health -Name 'currentStep'))
    }
    return ''
}

function Restart-DemoVmOnce {
    <#
    .SYNOPSIS
    The watchdog's restart: 'az vm restart' for one VM, at most once per deploy.ps1 process, then the wait for its VM
    agent. Never the T2 host while Get-DemoHostRestartBlocker names a reason: the guided stop's request is valid (its
    guest may be in the middle of setup), the golden Release runs on it, or its guest build runs (review finding 6).
    Returns Restarted, Reason, and AtUtc. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [string] $Because = 'Azure''s work on its extensions was stuck'
    )

    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $key = '{0}/{1}' -f $resourceGroupName, $VmName
    if ($script:DemoVmRestarted.ContainsKey($key)) {
        return [pscustomobject]@{ Restarted = $false; Reason = 'it was restarted once already in this run'; AtUtc = $script:DemoVmRestarted[$key] }
    }
    if ($VmName -eq 'archost01') {
        $blocker = Get-DemoHostRestartBlocker -Config $Config -VmName $VmName
        if ($blocker) {
            return [pscustomobject]@{ Restarted = $false; Reason = $blocker; AtUtc = $null }
        }
    }
    if (-not $PSCmdlet.ShouldProcess($VmName, 'Restart the VM once, because its Azure-side work is stuck')) {
        return [pscustomobject]@{ Restarted = $false; Reason = 'what if'; AtUtc = $null }
    }
    $at = [System.DateTime]::UtcNow
    $script:DemoVmRestarted[$key] = $at
    Write-DemoLog -Level Warning -Message ('{0}: {1} for about 15 minutes, so the VM restarts once now (az vm restart); the run goes on afterward.' -f $VmName, $Because)
    $restart = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('vm', 'restart', '--resource-group', $resourceGroupName, '--name', $VmName) -AllowFailure
    if ($restart.ExitCode -ne 0) {
        return [pscustomobject]@{ Restarted = $false; Reason = ('the restart failed: {0}' -f (Get-DemoDeploymentErrorText -Text $restart.StdErr -MaxLength 300)); AtUtc = $at }
    }
    $null = Wait-DemoVmAgentReady -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName $resourceGroupName -VmName $VmName -TimeoutMinutes 15
    return [pscustomobject]@{ Restarted = $true; Reason = ''; AtUtc = $at }
}

function Invoke-DemoVmWatchdog {
    <#
    .SYNOPSIS
    The watchdog (brief item 14): saves the VM's instance view for diagnostics, restarts it once (Restart-DemoVmOnce),
    and says so on the status page as an Azure-side wait, with the cause and the restart's time. Returns Restarted,
    Saved (the file), Items (what was stuck), and Result (a Warning describing it). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $Cause,

        [string] $ProgressPath = '',

        [string[]] $ProgressId = @()
    )

    $activity = Get-DemoVmExtensionActivity -Config $Config -VmName $VmName
    $saved = Save-DemoVmInstanceView -View $activity.View -VmName $VmName
    $restart = Restart-DemoVmOnce -Config $Config -VmName $VmName -Because $Cause -Confirm:$false
    $at = if ($null -ne $restart.AtUtc) { ([datetime]$restart.AtUtc).ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
    $what = if ($activity.Labels.Count -gt 0) { ' Azure was busy with {0}.' -f ($activity.Labels -join ', ') } else { '' }
    $done = if ($restart.Restarted) { '{0} was restarted automatically at {1} (local time), because {2}.{3}' -f $VmName, $at, $Cause, $what } else { '{0} wasn''t restarted ({1}), although {2}.{3}' -f $VmName, $restart.Reason, $Cause, $what }
    Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State 'Running' -AzureSide -Message ('{0} No action needed.' -f $done)
    $savedText = if ($saved) { ' Its instance view is saved in {0} for ./scripts/collect-diagnostics.ps1.' -f $saved } else { '' }
    $result = New-DemoResult -CheckId ('DEPLOY.WATCHDOG_{0}' -f $VmName.ToUpperInvariant()) -Area 'infra' -Target (Get-DemoVmTarget -VmName $VmName) -Status 'Warning' -Message ('{0}{1}' -f $done, $savedText) -Evidence ([ordered]@{ vmName = $VmName; restarted = [bool]$restart.Restarted; restartedAtUtc = $(if ($null -ne $restart.AtUtc) { ([datetime]$restart.AtUtc).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }); busy = @($activity.Items); runCommandsDeleting = @($activity.RunCommandsDeleting).Count; instanceView = $saved }) -Remediation 'Nothing to do. If it happens on every run, an extension that a policy installs may be failing on the VM: see docs/troubleshooting.md.' -DocUrl 'https://learn.microsoft.com/cli/azure/vm#az-vm-restart'
    return [pscustomobject]@{ Restarted = [bool]$restart.Restarted; Saved = $saved; Items = @($activity.Labels); Result = $result }
}

function New-DemoVmStuckResult {
    # The Fail that ends the run NOT DONE when a VM's Azure-side work is still stuck after the watchdog: it names what's
    # stuck and the exact next step. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $What,

        [AllowEmptyCollection()]
        [string[]] $Item = @(),

        [int] $Minutes = 0,

        [bool] $Restarted = $false
    )

    $stuck = if (@($Item).Count -gt 0) { @($Item) -join ', ' } else { 'the VM agent''s Run Command handling' }
    $message = '{0} is still stuck on {1} after about {2} minutes{3}: Azure is busy with {4}. This is Azure-side; the run can''t continue {0}''s setup until it finishes.' -f $What, $VmName, $Minutes, $(if ($Restarted) { ' and one automatic restart' } else { '' }), $stuck
    $first = if (@($Item).Count -gt 0) { @($Item)[0] } else { 'the extension' }
    $remediation = 'Wait 15 to 30 minutes, then run ./scripts/deploy.ps1 again; it continues where it stopped. If {0} stays stuck, ask your Azure administrator about it (often a policy installs it), and see docs/troubleshooting.md (Run Commands stuck in Deleting).' -f $first
    return (New-DemoResult -CheckId ('DEPLOY.EXTENSIONS_{0}' -f $VmName.ToUpperInvariant()) -Area 'infra' -Target (Get-DemoVmTarget -VmName $VmName) -Status 'Fail' -Message $message -Evidence ([ordered]@{ vmName = $VmName; stuck = @($Item); minutes = $Minutes; restarted = $Restarted }) -Remediation $remediation -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed')
}

function Invoke-DemoVmSettle {
    <#
    .SYNOPSIS
    Before a VM's artifacts or its loader (brief item 14): waits up to -FirstMinutes for its extensions to settle; past
    that, the watchdog (Invoke-DemoVmWatchdog) saves the instance view and restarts the VM once, then it waits up to
    -AfterRestartMinutes more. Returns Settled and Results: none when nothing got in the way, the watchdog's Warning
    when it cleared it, and a Fail naming the stuck extension and the next step when it didn't. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [string] $ProgressPath = '',

        [string[]] $ProgressId = @(),

        [ValidateRange(0, 120)]
        [int] $FirstMinutes = 20,

        [ValidateRange(0, 120)]
        [int] $AfterRestartMinutes = 10,

        [ValidateRange(1, 600)]
        [int] $PollSeconds = 30
    )

    $first = Wait-DemoVmExtensionSettled -Config $Config -VmName $VmName -TimeoutMinutes $FirstMinutes -PollSeconds $PollSeconds -ProgressPath $ProgressPath -ProgressId $ProgressId
    if ($first.Settled) {
        return [pscustomobject]@{ Settled = $true; Results = @() }
    }
    $watchdog = Invoke-DemoVmWatchdog -Config $Config -VmName $VmName -Cause ('Azure''s extension work didn''t finish in {0} minutes' -f $first.Minutes) -ProgressPath $ProgressPath -ProgressId $ProgressId
    $second = Wait-DemoVmExtensionSettled -Config $Config -VmName $VmName -TimeoutMinutes $AfterRestartMinutes -PollSeconds $PollSeconds -ProgressPath $ProgressPath -ProgressId $ProgressId
    if ($second.Settled) {
        return [pscustomobject]@{ Settled = $true; Results = @($watchdog.Result) }
    }
    $stuck = New-DemoVmStuckResult -VmName $VmName -What 'Extension work' -Item $second.Activity.Labels -Minutes ($first.Minutes + $second.Minutes) -Restarted $watchdog.Restarted
    return [pscustomobject]@{ Settled = $false; Results = @($watchdog.Result, $stuck) }
}
