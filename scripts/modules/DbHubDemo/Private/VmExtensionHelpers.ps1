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
    provisioning state is Creating, Updating, or Deleting, or whose instance-view status is transitioning, and a running VM
    whose agent isn't Ready (its start, R871). The Run Command handler isn't counted. Also lists the Run Commands Azure is
    still deleting, which don't make it busy, and every chunk Run Command (Chunks). Returns Readable, Busy, Items (each
    extension with its state), Labels (for the status page), RunCommandsDeleting, Chunks, NoPower (it shows no power state
    and its agent isn't Ready, #63), and View (the instance view, for diagnostics). Internal.
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
    $noPowerDown = $false
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
        # A running VM whose agent isn't Ready gets no Run Command yet (R871, live 2026-11-17): chunks sent to the T2 host then
        # stayed in Creating, and a later deallocate canceled their deletes instead of completing them, so the host never
        # started again. A healthy start has the agent Ready within about 2 minutes; a host whose start never got its goal
        # state gets the watchdog, which deletes its chunks and deallocates and starts it. So does a VM that shows no power
        # state at all, while Azure's operation on it runs (#63, live 2026-11-18: the T2 host stayed "updating", with no power
        # state and its agent Not Ready, for hours, and the run sent it chunks that stayed in Creating).
        $vmStatuses = Get-DemoMemberList -InputObject $instanceView -Name 'statuses'
        $vmCodes = @(foreach ($status in $vmStatuses) { [string](Get-DemoMemberValue -InputObject $status -Name 'code') })
        $noPower = @($vmCodes | Where-Object { $_ -like 'ProvisioningState/*' }).Count -gt 0 -and @($vmCodes | Where-Object { $_ -like 'PowerState/*' }).Count -eq 0
        if ('PowerState/running' -in $vmCodes -or $noPower) {
            $agentStatuses = Get-DemoMemberList -InputObject (Get-DemoMemberValue -InputObject $instanceView -Name 'vmAgent') -Name 'statuses'
            $agent = [string](Get-DemoMemberValue -InputObject (@($agentStatuses) | Select-Object -First 1) -Name 'displayStatus')
            if ($agent -ne 'Ready') {
                $items.Add(('VM agent ({0})' -f $(if ($agent) { $agent } else { 'no status' })))
                $labels.Add($(if ($noPower) { 'the VM''s start or update (no power state, and its agent isn''t Ready)' } else { 'the VM''s start (its agent isn''t Ready yet)' }))
                $noPowerDown = $noPower
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
    # Every chunk Run Command the VM lists, whatever its state (R871: on the T2 host, one whose delete Azure ended with an
    # error stays listed as Succeeded, marked for deletion, and the VM's next start never gets its goal state).
    $chunks = @(foreach ($item in $runCommands) {
            $name = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
            if ($name -like 'DbHubDemo-Chunk-*') {
                $name
            }
        })
    return [pscustomobject]@{
        Readable            = ($null -ne $view)
        Busy                = ($items.Count -gt 0)
        Items               = $items.ToArray()
        Labels              = $labels.ToArray()
        RunCommandsDeleting = $deleting
        Chunks              = $chunks
        NoPower             = $noPowerDown
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
    # #63: since when every read has shown no power state with the agent not Ready, for the watchdog's agent-down rule.
    $noPowerSince = $null
    while ($true) {
        $activity = Get-DemoVmExtensionActivity -Config $Config -VmName $VmName
        $minutes = [int][System.Math]::Floor($watch.Elapsed.TotalMinutes)
        if ([bool](Get-DemoMemberValue -InputObject $activity -Name 'NoPower')) {
            if ($null -eq $noPowerSince) {
                $noPowerSince = $watch.Elapsed
            }
        }
        elseif ([bool](Get-DemoMemberValue -InputObject $activity -Name 'Readable')) {
            $noPowerSince = $null
        }
        if (-not $activity.Busy) {
            if ($waited) {
                Write-DemoLog -Message ('{0}: Azure finished its extension work after {1} minute(s).' -f $VmName, $minutes)
                Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State 'Running' -Message ('Azure finished its extension work on {0}; continuing.' -f $VmName)
            }
            return [pscustomobject]@{ Settled = $true; Minutes = $minutes; Activity = $activity; NoPowerMinutes = 0 }
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
            $noPowerMinutes = if ($null -ne $noPowerSince) { [int][System.Math]::Floor(($watch.Elapsed - $noPowerSince).TotalMinutes) } else { 0 }
            return [pscustomobject]@{ Settled = $false; Minutes = $minutes; Activity = $activity; NoPowerMinutes = $noPowerMinutes }
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

# #63: deploy.ps1's longest wait for T2's guest build (-T2WaitMinutes, 180). A bootstrap generation the state records for
# longer has finished unseen or died, so it no longer keeps the watchdog from the T2 host (Get-DemoHostRestartBlocker).
$script:T2BuildRecordMaxMinutes = 180

function Get-DemoHostRestartBlocker {
    <#
    .SYNOPSIS
    Why the watchdog mustn't restart the T2 host now, or '' when it may (review finding 6 and its follow-up): the guided
    stop's time limit is open (its guest may be in the middle of setup); a golden guest action, the Release, runs on it in
    this process (Invoke-DemoGoldenGuestAction); or its guest build may be running. Judged from the deployment state
    alone, never through the host's VM agent, which is what's stuck when the watchdog asks (R336). Internal.

    .DESCRIPTION
    A guest build may be running while T2BuildUtc is set (the host's loader started a bootstrap generation that nobody has
    seen finish; the Release of a new golden copy and the end of the T2 step clear it), while the T2 track's last step is
    Bootstraps (a state written before T2BuildUtc existed), or, for a sequential run's state (no track recorded), while
    the recorded stage is between Bootstraps and T2. So a new host before its loader, a golden copy after its Release
    (until its loader starts a new generation), and a host whose T2 step finished may be restarted; a state that can't be
    read may not. A generation older than T2's longest build ($script:T2BuildRecordMaxMinutes) finished unseen or died,
    so it doesn't block (#63, live 2026-11-18: an older run cut short left it, the host's agent died, and no later run
    could see the build finish, so none recovered the host).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName = 'archost01'
    )

    try {
        $state = Get-DemoDeploymentState -Config $Config
    }
    catch {
        return ('the deployment state couldn''t be read ({0}), so its guest build may be running' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    $until = ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $state -Name 'GuidedStopUtc')
    if ($null -ne $until -and $until -gt [System.DateTime]::UtcNow) {
        return 'its guest may be in the middle of SQL Server setup (the guided stop)'
    }
    $key = '{0}/{1}' -f (Get-DemoResourceGroupName -Config $Config), $VmName
    if ($script:DemoHostAction.ContainsKey($key)) {
        return ('the golden {0} is running on it' -f $script:DemoHostAction[$key])
    }
    $building = [string](Get-DemoMemberValue -InputObject $state -Name 'T2BuildUtc')
    if ($building) {
        $since = ConvertTo-DemoRunCommandUtc -Value $building
        if ($null -eq $since -or ([System.DateTime]::UtcNow - $since).TotalMinutes -lt $script:T2BuildRecordMaxMinutes) {
            return ('its loader started a bootstrap generation at {0} that hasn''t been seen to finish, so its guest build may be running' -f $building)
        }
        # #63: older than T2's longest build, so it isn't running any more. Its record is newer than a Bootstraps track
        # the same run left, so that doesn't block either.
        return ''
    }
    $track = [string](Get-DemoMemberValue -InputObject $state -Name 'TrackT2')
    if ($track -eq 'Bootstraps') {
        return 'its loader started a bootstrap generation (the T2 track''s last step is Bootstraps), so its guest build may be running'
    }
    $tracks = @(foreach ($name in 'TrackT1', 'TrackT2', 'TrackT4', 'TrackFabric') { [string](Get-DemoMemberValue -InputObject $state -Name $name) }) -join ''
    $stage = [string](Get-DemoMemberValue -InputObject $state -Name 'Stage')
    if (-not $tracks -and $stage -and (Test-DemoDeploymentStageReached -Recorded $stage -Stage 'Bootstraps') -and -not (Test-DemoDeploymentStageReached -Recorded $stage -Stage 'T2')) {
        return ('the recorded stage is {0}, after the loaders and before T2 finished, so its guest build may be running' -f $stage)
    }
    return ''
}

function Restart-DemoVmOnce {
    <#
    .SYNOPSIS
    The watchdog's restart: 'az vm restart --no-wait' for one VM, at most once per deploy.ps1 process, then a bounded wait
    until Azure has finished it (Wait-DemoVmRestarted, -RestartMinutes) and the VM agent is Ready; a restart Azure doesn't
    finish in that time gets one deallocate and start (Invoke-DemoVmRestartRecovery, -RecoverMinutes), so no restart holds
    a run without end (2026-11-16). Never the T2 host while Get-DemoHostRestartBlocker names a reason: the guided stop's
    request is valid (its guest may be in the middle of setup), the golden Release runs on it, or its guest build may be
    running, judged from the deployment state (review finding 6 and its follow-up). Returns Restarted, Reason, AtUtc,
    Recovered (the deallocate and start brought it back), Failed (it isn't back: the watchdog's result is a Fail), Detail,
    and Results (the guest's shutdown, when the recovery ran it). Internal.

    The T2 host whose VM agent isn't Ready, or that lists chunk Run Commands (-ChunkRunCommand), gets no restart (R871,
    2026-11-17): the deletes of those chunks go first, then one deallocate and start (Invoke-DemoVmRestartRecovery). Live,
    a chunk whose delete Azure had ended with an error stayed on the VM, marked for deletion, and no start or restart got
    the VM's goal state with it (13 of 13); a delete still pending when the VM deallocated completed with it, and the next
    start had the agent Ready in 2 minutes. Then Action says 'deallocated and started' and AgentDown says why.

    #63 (live, 2026-11-18): so does a T2 host that shows no power state, with its agent not Ready, once it has stayed down
    for -AgentDownMinutes in all (Wait-DemoVmAgentDown), never on one read. One that comes Ready, or that Azure or someone
    stops, meanwhile gets nothing, unless it lists chunks.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [string] $Because = 'Azure''s work on its extensions was stuck',

        [AllowEmptyCollection()]
        [string[]] $ChunkRunCommand = @(),

        [ValidateRange(1, 60)]
        [int] $RestartMinutes = 15,

        [ValidateRange(1, 60)]
        [int] $RecoverMinutes = 20,

        # #63: how long a T2 host that shows no power state, with its agent not Ready, must stay down to count as down: the
        # 20 minutes a running VM's agent gets before the watchdog (Invoke-DemoVmSettle -FirstMinutes). -NoPowerMinutes is
        # how long the caller already saw it so, read by read (the settle's wait); the rest is read here, at least once.
        [ValidateRange(0, 60)]
        [int] $AgentDownMinutes = 20,

        [ValidateRange(0, 1440)]
        [int] $NoPowerMinutes = 0,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15
    )

    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $key = '{0}/{1}' -f $resourceGroupName, $VmName
    if ($script:DemoVmRestarted.ContainsKey($key)) {
        return [pscustomobject]@{ Restarted = $false; Reason = 'it was restarted once already in this run'; AtUtc = $script:DemoVmRestarted[$key]; Recovered = $false; Failed = $false; Detail = ''; Results = @() }
    }
    if ($VmName -eq 'archost01') {
        $blocker = Get-DemoHostRestartBlocker -Config $Config -VmName $VmName
        if ($blocker) {
            return [pscustomobject]@{ Restarted = $false; Reason = $blocker; AtUtc = $null; Recovered = $false; Failed = $false; Detail = ''; Results = @() }
        }
    }
    if (-not $PSCmdlet.ShouldProcess($VmName, 'Restart the VM once, because its Azure-side work is stuck')) {
        return [pscustomobject]@{ Restarted = $false; Reason = 'what if'; AtUtc = $null; Recovered = $false; Failed = $false; Detail = ''; Results = @() }
    }
    $at = [System.DateTime]::UtcNow
    $script:DemoVmRestarted[$key] = $at
    $subscriptionId = [string]$Config['subscriptionId']
    $chunks = @($ChunkRunCommand | Where-Object { $_ -like 'DbHubDemo-Chunk-*' })
    if ($VmName -eq (Get-DemoHostVmName -Config $Config)) {
        $state = Get-DemoVmRestartState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName
        $agentDown = $state.Read -and $state.Power -eq 'PowerState/running' -and $state.Agent -ne 'Ready'
        $held = $null
        if (-not $agentDown -and $state.Read -and $state.Provisioning -and -not $state.Power -and $state.Agent -ne 'Ready') {
            # #63 (live, 2026-11-18): a host that Azure keeps in an operation, with no power state and its agent not Ready, is
            # down too, but only once it stays down as long as a running VM's agent gets: Azure's start or update that takes a
            # few minutes reads the same at first, and mustn't be deallocated.
            $more = [System.Math]::Max(0, $AgentDownMinutes - $NoPowerMinutes)
            $held = Wait-DemoVmAgentDown -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName -Minutes $more -PollSeconds $PollSeconds
            if ($held.Down) {
                $agentDown = $true
                $state = $held.State
            }
            elseif ($chunks.Count -eq 0) {
                # Not down: nothing to restart now, and a later stall in this run may still use the watchdog.
                $script:DemoVmRestarted.Remove($key)
                $reason = if ($null -ne $held.State) { 'Azure was still working on it: it showed no power state, with its VM agent not Ready, then {0}' -f $held.State.Text } else { 'it showed no power state, with its VM agent not Ready, and its instance view couldn''t be read again, so it isn''t judged down on one read' }
                return [pscustomobject]@{ Restarted = $false; Reason = $reason; AtUtc = $null; Recovered = $false; Failed = $false; Detail = ''; Results = @() }
            }
        }
        if ($agentDown -or $chunks.Count -gt 0) {
            # R871: no restart. The chunks' deletes go first, so they're pending when the VM deallocates, which completes them.
            $baseUrl = Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName
            $apiVersion = Get-DemoRunCommandApiVersion
            $asked = 0
            foreach ($name in $chunks) {
                if (Remove-DemoRunCommand -SubscriptionId $subscriptionId -Url ('{0}/{1}?api-version={2}' -f $baseUrl, $name, $apiVersion) -NoWait -Confirm:$false) {
                    $asked++
                }
            }
            $why = if ($null -ne $held -and $held.Down) { 'it showed no power state, with its VM agent not Ready, for {0} minutes ({1})' -f $AgentDownMinutes, $state.Text } elseif ($agentDown) { 'its VM agent isn''t Ready ({0})' -f $state.Text } else { 'it lists {0} chunk Run Command(s) that a restart would keep' -f $chunks.Count }
            $sent = if ($asked -gt 0) { 'the deletes of its {0} chunk Run Command(s) went first, to complete with the deallocate; ' -f $asked } else { '' }
            Write-DemoLog -Level Warning -Message ('{0}: {1}, and {2}, so it isn''t restarted: {3}it''s deallocated and started once now (R871); no action needed.' -f $VmName, $Because, $why, $sent)
            if ($asked -gt 0) {
                # Live, the deallocate went out a minute after the deletes.
                Start-Sleep -Seconds 60
            }
            $recover = Invoke-DemoVmRestartRecovery -Config $Config -VmName $VmName -TimeoutMinutes $RecoverMinutes -PollSeconds $PollSeconds
            $detail = '{0}{1}, so it wasn''t restarted: {2}{3}' -f $why.Substring(0, 1).ToUpperInvariant(), $why.Substring(1), $sent, $recover.Detail
            # The host's rebuild (2026-11-17) is the cue's last resort: its agent stayed down after the deallocate and start,
            # or it was down to begin with and the deallocate and start didn't bring it back at all. Live on rg-dbhubmn-demo
            # (2026-11-17, 01:11 UTC), a deallocate during the host's hung start didn't finish in 20 minutes.
            $dead = [bool](Get-DemoMemberValue -InputObject $recover -Name 'AgentDead') -or ($agentDown -and -not [bool]$recover.Recovered)
            return [pscustomobject]@{ Restarted = $true; Reason = ''; AtUtc = $at; Recovered = [bool]$recover.Recovered; Failed = -not [bool]$recover.Recovered; Detail = $detail; Results = @($recover.Results); Left = [string](Get-DemoMemberValue -InputObject $recover -Name 'Left'); Action = 'deallocated and started'; AgentDown = $agentDown; ChunksDeleted = $asked; AgentDead = $dead }
        }
    }
    Write-DemoLog -Level Warning -Message ('{0}: {1} for about 15 minutes, so the VM restarts once now (az vm restart); the run goes on afterward.' -f $VmName, $Because)
    # --no-wait, then a bounded wait (2026-11-16): without them, a restart Azure never finished held the track, and deploy.ps1,
    # with no end and no NOT DONE (live: archost01 'updating', its agent Not Ready, 40 minutes after the restart).
    $restart = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'restart', '--resource-group', $resourceGroupName, '--name', $VmName, '--no-wait') -AllowFailure -TimeoutSeconds 300
    if ($restart.ExitCode -ne 0) {
        return [pscustomobject]@{ Restarted = $false; Reason = ('the restart failed: {0}' -f (Get-DemoDeploymentErrorText -Text $restart.StdErr -MaxLength 300)); AtUtc = $at; Recovered = $false; Failed = $false; Detail = ''; Results = @() }
    }
    $wait = Wait-DemoVmRestarted -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName -SinceUtc $at -TimeoutMinutes $RestartMinutes -PollSeconds $PollSeconds
    if ($wait.Done) {
        return [pscustomobject]@{ Restarted = $true; Reason = ''; AtUtc = $at; Recovered = $false; Failed = $false; Detail = ''; Results = @() }
    }
    Write-DemoLog -Level Warning -Message ('{0}: Azure didn''t finish its restart in {1} minutes ({2}), so it''s deallocated and started once now; no action needed.' -f $VmName, $RestartMinutes, $wait.State)
    $recover = Invoke-DemoVmRestartRecovery -Config $Config -VmName $VmName -TimeoutMinutes $RecoverMinutes -PollSeconds $PollSeconds
    $detail = 'Azure didn''t finish its restart in {0} minutes ({1}), so {2}' -f $RestartMinutes, $wait.State, $recover.Detail
    return [pscustomobject]@{ Restarted = $true; Reason = ''; AtUtc = $at; Recovered = [bool]$recover.Recovered; Failed = -not [bool]$recover.Recovered; Detail = $detail; Results = @($recover.Results); Left = [string](Get-DemoMemberValue -InputObject $recover -Name 'Left'); AgentDead = [bool](Get-DemoMemberValue -InputObject $recover -Name 'AgentDead') }
}

function Get-DemoVmRestartState {
    # One read of a VM's instance view for the watchdog's bounded restart: Read, Provisioning (the ProvisioningState code),
    # ProvisionedUtc (its time, when Azure gives one), Power (the PowerState code), Agent (the VM agent's displayStatus), and
    # Text for the messages. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    $view = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('vm', 'get-instance-view', '--resource-group', $ResourceGroupName, '--name', $VmName, '--query', 'instanceView', '--output', 'json') -AsJson -AllowFailure -TimeoutSeconds 120
    if ($null -eq $view) {
        return [pscustomobject]@{ Read = $false; Provisioning = ''; ProvisionedUtc = $null; Power = ''; Agent = ''; Text = 'its instance view couldn''t be read' }
    }
    # Assigned first: Get-DemoMemberValue returns an array as one object.
    $statusValue = Get-DemoMemberValue -InputObject $view -Name 'statuses'
    $statuses = @($statusValue)
    $provisioning = @($statuses | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'code') -like 'ProvisioningState/*' }) | Select-Object -First 1
    $power = @($statuses | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'code') -like 'PowerState/*' }) | Select-Object -First 1
    $agentValue = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $view -Name 'vmAgent') -Name 'statuses'
    $agent = [string](Get-DemoMemberValue -InputObject (@($agentValue) | Select-Object -First 1) -Name 'displayStatus')
    $time = [string](Get-DemoMemberValue -InputObject $provisioning -Name 'time')
    $provisionedUtc = $null
    if ($time) {
        $parsed = [System.DateTimeOffset]::MinValue
        if ([System.DateTimeOffset]::TryParse($time, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
            $provisionedUtc = $parsed.UtcDateTime
        }
    }
    $state = [pscustomobject]@{
        Read           = $true
        Provisioning   = [string](Get-DemoMemberValue -InputObject $provisioning -Name 'code')
        ProvisionedUtc = $provisionedUtc
        Power          = [string](Get-DemoMemberValue -InputObject $power -Name 'code')
        Agent          = $agent
        Text           = ''
    }
    $state.Text = 'provisioning {0}, power {1}, agent {2}' -f $(if ($state.Provisioning) { $state.Provisioning.Split('/')[-1] } else { 'unknown' }), $(if ($state.Power) { $state.Power.Split('/')[-1] } else { 'unknown' }), $(if ($agent) { $agent } else { 'unknown' })
    return $state
}

function Wait-DemoVmAgentDown {
    <#
    .SYNOPSIS
    Whether a VM that read with no power state and its agent not Ready stays down for -Minutes more (#63): its instance
    view is read again every -PollSeconds, -Minutes * 60 / -PollSeconds times, and at least once, so it's never judged on
    the caller's one read. It stays down while its agent isn't Ready and it shows no power state, or starting, or running
    (a start whose agent never comes Ready is down too, as in R871). A read with its agent Ready ends it, and so does a
    power state that isn't one of those (Azure or someone is stopping it): Down is false, as for Azure's start or update
    that takes a few minutes. A read that fails says nothing either way. Returns Down, Reads (the readable reads), and
    State (the last readable one, as Get-DemoVmRestartState gives it, or $null). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $VmName,

        [ValidateRange(0, 60)]
        [int] $Minutes = 20,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15
    )

    $tries = [System.Math]::Max(1, [int][System.Math]::Ceiling($Minutes * 60 / $PollSeconds))
    $reads = 0
    $last = $null
    for ($try = 0; $try -lt $tries; $try++) {
        Start-Sleep -Seconds $PollSeconds
        $read = Get-DemoVmRestartState -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -VmName $VmName
        if (-not $read.Read) {
            continue
        }
        $reads++
        $last = $read
        if ($read.Agent -eq 'Ready' -or $read.Power -notin @('', 'PowerState/starting', 'PowerState/running')) {
            return [pscustomobject]@{ Down = $false; Reads = $reads; State = $read }
        }
    }
    return [pscustomobject]@{ Down = ($reads -gt 0); Reads = $reads; State = $last }
}

function Wait-DemoVmRestarted {
    <#
    .SYNOPSIS
    After 'az vm restart --no-wait' (2026-11-16): waits at most -TimeoutMinutes until Azure has finished the restart, that
    is, the VM's provisioning state is Succeeded again (with a time at or after -SinceUtc, or after Updating was seen), it's
    running, and its VM agent reports Ready. Returns Done, Seconds, and State (the last read, in words). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [datetime] $SinceUtc,

        [ValidateRange(1, 60)]
        [int] $TimeoutMinutes = 15,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $sawWork = $false
    $last = 'not read yet'
    while ($true) {
        $state = Get-DemoVmRestartState -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -VmName $VmName
        if ($state.Read) {
            $last = $state.Text
            if ($state.Provisioning -ne 'ProvisioningState/succeeded' -or $state.Power -ne 'PowerState/running' -or $state.Agent -ne 'Ready') {
                $sawWork = $true
            }
            $finished = $sawWork -or ($null -ne $state.ProvisionedUtc -and $state.ProvisionedUtc -ge $SinceUtc.ToUniversalTime().AddSeconds(-5))
            if ($finished -and $state.Provisioning -eq 'ProvisioningState/succeeded' -and $state.Power -eq 'PowerState/running' -and $state.Agent -eq 'Ready') {
                return [pscustomobject]@{ Done = $true; Seconds = [int]$watch.Elapsed.TotalSeconds; State = $last }
            }
        }
        if ($watch.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
            return [pscustomobject]@{ Done = $false; Seconds = [int]$watch.Elapsed.TotalSeconds; State = $last }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Invoke-DemoVmRestartRecovery {
    <#
    .SYNOPSIS
    The watchdog's last resort when Azure doesn't finish a VM's restart (2026-11-16; the T2 host on rg-dbhubup-demo on
    2026-11-13 and 14, and on rg-dbhubmn-demo on 2026-11-16, where a deallocate and start by hand cleared the same state):
    the T2 guest shut down cleanly first when the host can still run commands (its agent Ready; Stop-DemoGuestVm, at most 3
    minutes), then one deallocate and one start, each with --no-wait and a bounded wait (Invoke-DemoVmPowerAction), then
    its agent Ready. Azure refusing the deallocate (an operation still in progress, after the conflict retries), or a VM
    that still isn't running with its agent Ready, is reported, not waited for. Returns Recovered, Detail (what happened,
    in words), and Results (the guest's shutdown, when it ran). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [ValidateRange(1, 60)]
        [int] $TimeoutMinutes = 20,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $results = [System.Collections.Generic.List[object]]::new()
    $guestText = ''
    if ($VmName -eq (Get-DemoHostVmName -Config $Config)) {
        $state = Get-DemoVmRestartState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName
        if ($state.Agent -eq 'Ready') {
            try {
                $guest = Stop-DemoGuestVm -Config $Config -TimeoutSeconds 180 -Confirm:$false
                $results.Add($guest)
                $guestText = 'its guest was shut down first ({0}), ' -f [string]$guest.status
            }
            catch {
                $guestText = 'its guest''s clean shutdown failed ({0}), ' -f (Protect-DemoText -Text $_.Exception.Message)
            }
        }
        else {
            $guestText = 'its guest wasn''t shut down first (the host''s agent can''t run commands: {0}), ' -f $state.Text
        }
    }
    # Invoke-DemoAz here, not Invoke-DemoAzWithConflictRetry: Azure names the refused operation, 'deallocate', which that
    # function's not-running check would read as a VM that's already deallocated. A conflict with an operation in progress
    # is asked again, 4 times at most, 30 seconds apart; any other refusal is reported at once.
    $deallocate = $null
    for ($try = 1; $try -le 4; $try++) {
        $deallocate = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'deallocate', '--resource-group', $resourceGroupName, '--name', $VmName, '--no-wait') -AllowFailure -TimeoutSeconds 300
        if ($deallocate.ExitCode -eq 0 -or [string]$deallocate.StdErr -notmatch '(?i)conflict|in progress|another operation|preempt') {
            break
        }
        if ($try -lt 4) {
            Start-Sleep -Seconds 30
        }
    }
    if ($deallocate.ExitCode -ne 0) {
        return [pscustomobject]@{ Recovered = $false; Detail = ('{0}Azure refused its deallocate: {1}' -f $guestText, (Get-DemoDeploymentErrorText -Text $deallocate.StdErr -MaxLength 300)); Results = $results.ToArray(); Left = ''; AgentDead = $false }
    }
    $seconds = [int][System.Math]::Max(60, ($TimeoutMinutes * 60) - $watch.Elapsed.TotalSeconds)
    $stopped = Invoke-DemoVmPowerAction -Config $Config -VmName $VmName -Action Deallocate -TimeoutSeconds ([System.Math]::Min(3600, $seconds)) -PollSeconds $PollSeconds -DeallocateRequested
    if ([string]$stopped.status -ne 'Pass') {
        return [pscustomobject]@{ Recovered = $false; Detail = ('{0}it was asked to deallocate, but {1}' -f $guestText, [string]$stopped.message); Results = $results.ToArray(); Left = 'deallocating'; AgentDead = $false }
    }
    $seconds = [int][System.Math]::Max(60, ($TimeoutMinutes * 60) - $watch.Elapsed.TotalSeconds)
    $started = Invoke-DemoVmPowerAction -Config $Config -VmName $VmName -Action Start -TimeoutSeconds ([System.Math]::Min(3600, $seconds)) -PollSeconds $PollSeconds
    if ([string]$started.status -ne 'Pass') {
        return [pscustomobject]@{ Recovered = $false; Detail = ('{0}it was deallocated, but its start didn''t finish: {1}' -f $guestText, [string]$started.message); Results = $results.ToArray(); Left = $(if ([string]$started.status -eq 'Fail') { 'deallocated' } else { 'starting' }); AgentDead = $false }
    }
    $minutes = [int][System.Math]::Max(1, [System.Math]::Ceiling((($TimeoutMinutes * 60) - $watch.Elapsed.TotalSeconds) / 60))
    $agent = Wait-DemoVmAgentReady -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName -TimeoutMinutes ([System.Math]::Min(60, $minutes)) -PollSeconds $PollSeconds
    if ($agent -lt 0) {
        # The VM runs, but its agent stayed down through a deallocate and start: what the T2 host's rebuild is for (2026-11-17).
        return [pscustomobject]@{ Recovered = $false; Detail = ('{0}it was deallocated and started, but its VM agent wasn''t Ready within {1} minutes' -f $guestText, $TimeoutMinutes); Results = $results.ToArray(); Left = 'running'; AgentDead = $true }
    }
    return [pscustomobject]@{ Recovered = $true; Detail = ('{0}it was deallocated and started once, and it''s running with its agent Ready after {1} minutes' -f $guestText, [int][System.Math]::Ceiling($watch.Elapsed.TotalMinutes)); Results = $results.ToArray(); Left = 'running'; AgentDead = $false }
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

        # #63: how long the caller already saw the VM with no power state and its agent not Ready (Restart-DemoVmOnce).
        [ValidateRange(0, 1440)]
        [int] $NoPowerMinutes = 0,

        [string] $ProgressPath = '',

        [string[]] $ProgressId = @()
    )

    $activity = Get-DemoVmExtensionActivity -Config $Config -VmName $VmName
    $saved = Save-DemoVmInstanceView -View $activity.View -VmName $VmName
    # Assigned first: Get-DemoMemberValue returns an array as one object.
    $chunkNames = Get-DemoMemberValue -InputObject $activity -Name 'Chunks'
    $restart = Restart-DemoVmOnce -Config $Config -VmName $VmName -Because $Cause -ChunkRunCommand @($chunkNames | Where-Object { $_ }) -NoPowerMinutes $NoPowerMinutes -Confirm:$false
    $at = if ($null -ne $restart.AtUtc) { ([datetime]$restart.AtUtc).ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
    $what = if ($activity.Labels.Count -gt 0) { ' Azure was busy with {0}.' -f ($activity.Labels -join ', ') } else { '' }
    $recovered = [bool](Get-DemoMemberValue -InputObject $restart -Name 'Recovered')
    $failed = [bool](Get-DemoMemberValue -InputObject $restart -Name 'Failed')
    $detail = [string](Get-DemoMemberValue -InputObject $restart -Name 'Detail')
    $action = [string](Get-DemoMemberValue -InputObject $restart -Name 'Action')
    $verb = if ($action) { $action } else { 'restarted' }
    $done = if ($restart.Restarted) { '{0} was {1} automatically at {2} (local time), because {3}.{4}' -f $VmName, $verb, $at, $Cause, $what } else { '{0} wasn''t restarted ({1}), although {2}.{3}' -f $VmName, $restart.Reason, $Cause, $what }
    if ($detail) {
        $done = '{0} {1}.' -f $done, $detail
    }
    $savedText = if ($saved) { ' Its instance view is saved in {0} for ./scripts/collect-diagnostics.ps1.' -f $saved } else { '' }
    # Where the recovery left the VM (deallocating, deallocated, starting, running; '' when it didn't run), so the run's ending
    # doesn't call a VM it left deallocating running and billing (Get-DemoWatchdogLeftVm).
    $evidence = [ordered]@{ vmName = $VmName; restarted = [bool]$restart.Restarted; restartedAtUtc = $(if ($null -ne $restart.AtUtc) { ([datetime]$restart.AtUtc).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }); recovered = $recovered; left = [string](Get-DemoMemberValue -InputObject $restart -Name 'Left'); busy = @($activity.Items); runCommandsDeleting = @($activity.RunCommandsDeleting).Count; instanceView = $saved; action = $verb; agentDown = [bool](Get-DemoMemberValue -InputObject $restart -Name 'AgentDown'); chunksDeleted = [int](Get-DemoMemberValue -InputObject $restart -Name 'ChunksDeleted'); agentDead = [bool](Get-DemoMemberValue -InputObject $restart -Name 'AgentDead') }
    $checkId = 'DEPLOY.WATCHDOG_{0}' -f $VmName.ToUpperInvariant()
    if ($failed) {
        Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State 'Running' -AzureSide -Message ('{0} Azure-side; the run stops this step.' -f $done)
        # R871: a host that a deallocate and start didn't bring back isn't helped by waiting. The T2 host whose agent stayed down
        # is rebuilt by its track, once per run (Invoke-DemoT2HostRebuild, 2026-11-17), which then turns this into a Warning.
        $remediation = if ($evidence['agentDead'] -and $VmName -eq 'archost01' -and (Get-DemoHostVmName -Config $Config) -eq $VmName) { 'Run ./scripts/deploy.ps1 again: when archost01''s VM agent stays down and a deallocate and start doesn''t bring it back, deploy.ps1 deletes the host and its disks and creates it again from the template, once per run (DEPLOY.T2.HOSTREBUILD), and builds T2 on it. See docs/troubleshooting.md ("A host''s VM agent that isn''t Ready").' } elseif ($action) { 'Run ./scripts/deploy.ps1 again: it sends the deletes of the host''s chunk Run Commands again, then deallocates and starts it once more. If its VM agent still isn''t Ready, see docs/troubleshooting.md ("A host''s VM agent that isn''t Ready").' } else { 'Wait 30 minutes, then run ./scripts/deploy.ps1 again; it continues where it stopped, and restarts the VM again, or deallocates and starts it, if it still needs to.' }
        $result = New-DemoResult -CheckId $checkId -Area 'infra' -Target (Get-DemoVmTarget -VmName $VmName) -Status 'Fail' -Message ('{0}{1}' -f $done, $savedText) -Evidence $evidence -Remediation $remediation -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/states-billing'
    }
    else {
        Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State 'Running' -AzureSide -Message ('{0} No action needed.' -f $done)
        # R871: the T2 host's chunk Run Commands, not a policy's extension, kept its agent from Ready.
        $remediation = if ($action) { 'Nothing to do: the run went on. docs/troubleshooting.md ("A host''s VM agent that isn''t Ready") says why it happens and what keeps it from happening again.' } else { 'Nothing to do. If it happens on every run, an extension that a policy installs may be failing on the VM: see docs/troubleshooting.md.' }
        $docUrl = if ($action) { 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed' } else { 'https://learn.microsoft.com/cli/azure/vm#az-vm-restart' }
        $result = New-DemoResult -CheckId $checkId -Area 'infra' -Target (Get-DemoVmTarget -VmName $VmName) -Status 'Warning' -Message ('{0}{1}' -f $done, $savedText) -Evidence $evidence -Remediation $remediation -DocUrl $docUrl
    }
    return [pscustomobject]@{ Restarted = [bool]$restart.Restarted; Recovered = $recovered; Failed = $failed; AgentDead = [bool]$evidence['agentDead']; Saved = $saved; Items = @($activity.Labels); Result = $result; Results = @(@((Get-DemoMemberValue -InputObject $restart -Name 'Results')) | Where-Object { $null -ne $_ }) }
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
    $message = '{0} is still stuck on {1} after about {2} minutes{3}: Azure is busy with {4}. This is Azure-side; the run can''t continue {1}''s setup until it finishes.' -f $What, $VmName, $Minutes, $(if ($Restarted) { ' and one automatic restart' } else { '' }), $stuck
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
    $watchdog = Invoke-DemoVmWatchdog -Config $Config -VmName $VmName -Cause ('Azure''s extension work didn''t finish in {0} minutes' -f $first.Minutes) -NoPowerMinutes ([int](Get-DemoMemberValue -InputObject $first -Name 'NoPowerMinutes')) -ProgressPath $ProgressPath -ProgressId $ProgressId
    if ([bool](Get-DemoMemberValue -InputObject $watchdog -Name 'Failed')) {
        # The VM isn't back (its restart and the deallocate and start didn't finish): the watchdog's Fail says why and when to
        # run deploy.ps1 again, and waiting on its extensions here would only add time.
        return [pscustomobject]@{ Settled = $false; Results = @(@((Get-DemoMemberValue -InputObject $watchdog -Name 'Results') | Where-Object { $null -ne $_ }) + @($watchdog.Result)) }
    }
    $second = Wait-DemoVmExtensionSettled -Config $Config -VmName $VmName -TimeoutMinutes $AfterRestartMinutes -PollSeconds $PollSeconds -ProgressPath $ProgressPath -ProgressId $ProgressId
    if ($second.Settled) {
        return [pscustomobject]@{ Settled = $true; Results = @(@((Get-DemoMemberValue -InputObject $watchdog -Name 'Results') | Where-Object { $null -ne $_ }) + @($watchdog.Result)) }
    }
    $stuck = New-DemoVmStuckResult -VmName $VmName -What 'Extension work' -Item $second.Activity.Labels -Minutes ($first.Minutes + $second.Minutes) -Restarted $watchdog.Restarted
    return [pscustomobject]@{ Settled = $false; Results = @(@((Get-DemoMemberValue -InputObject $watchdog -Name 'Results') | Where-Object { $null -ne $_ }) + @($watchdog.Result, $stuck)) }
}
