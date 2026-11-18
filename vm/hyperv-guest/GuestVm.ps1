# Guest VM creation, credentials, and PowerShell Direct reachability (ADR 0003, ADR 0009).
# Windows PowerShell 5.1 on the Hyper-V host. Dot-sourced by vm/bootstrap/Invoke-HostBootstrap.ps1.

function Initialize-DemoGuestSecret {
    <#
    .SYNOPSIS
    Generates the guest administrator password once and keeps it on the host with DPAPI (LocalMachine).
    It never leaves the host and is never logged (ADR 0009).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SecretPath
    )

    if (Test-Path -LiteralPath $SecretPath -PathType Leaf) {
        return
    }
    $value = Build-DemoVmPassword -Length 24
    Protect-DemoVmSecret -Value $value -Path $SecretPath
    Write-DemoVmLog -Message 'Generated the guest administrator password and stored it on the host with DPAPI.'
}

function Get-DemoGuestCredential {
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SecretPath,

        [string] $UserName = 'Administrator'
    )

    $plain = Unprotect-DemoVmSecret -Path $SecretPath
    $secure = New-Object -TypeName 'System.Security.SecureString'
    foreach ($character in $plain.ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    return (New-Object -TypeName 'System.Management.Automation.PSCredential' -ArgumentList $UserName, $secure)
}

function Update-DemoGuestSecret {
    <#
    .SYNOPSIS
    Rotates the guest administrator's password the way the golden rotation does (vm/bootstrap/Invoke-DemoGoldenGuest.ps1,
    RotateGuestPassword): the new random value is stored with DPAPI as pending first, then set in the guest over
    PowerShell Direct with the current credential, proven with a new session, and only then promoted; if it can't sign
    in, the old one is set back. It's never logged or returned (ADR 0009).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SecretPath,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [string] $UserName = 'Administrator'
    )

    if (-not $PSCmdlet.ShouldProcess($Name, 'Rotate the guest administrator password')) {
        return
    }
    $pendingPath = $SecretPath + '.pending'
    $old = Get-DemoGuestCredential -SecretPath $SecretPath -UserName $UserName
    $session = New-PSSession -VMName $Name -Credential $old -ErrorAction Stop
    try {
        $value = Build-DemoVmPassword -Length 24
        Protect-DemoVmSecret -Value $value -Path $pendingPath
        $value = $null
        $new = Get-DemoGuestCredential -SecretPath $pendingPath -UserName $UserName
        $setSecret = {
            param($Account, $Secret)
            Set-LocalUser -Name $Account -Password $Secret
        }
        Invoke-Command -Session $session -ScriptBlock $setSecret -ArgumentList $UserName, $new.Password -ErrorAction Stop
        if (Test-DemoGuestOnline -Name $Name -Credential $new) {
            Move-Item -LiteralPath $pendingPath -Destination $SecretPath -Force
            Write-DemoVmLog -Message 'Rotated the guest administrator password; the new one is stored on the host with DPAPI.'
            return
        }
        Invoke-Command -Session $session -ScriptBlock $setSecret -ArgumentList $UserName, $old.Password -ErrorAction Stop
        Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
        throw 'The new guest password could not sign in, so the old one was set back.'
    }
    finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

function Test-DemoGuestVm {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [int] $VCpu,

        [Parameter(Mandatory = $true)]
        [int] $MemoryGiB
    )

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        return $false
    }
    return ([int]$vm.Generation -eq 2 -and [int]$vm.ProcessorCount -eq $VCpu -and -not $vm.DynamicMemoryEnabled -and
        [int64]$vm.MemoryStartup -eq ([int64]$MemoryGiB * 1GB) -and [string]$vm.AutomaticStartAction -eq 'Start' -and
        [string]$vm.AutomaticStopAction -eq 'ShutDown' -and [string]$vm.State -eq 'Running')
}

function Initialize-DemoGuestVm {
    <#
    .SYNOPSIS
    Creates or reconfigures the Generation 2 guest: static memory, automatic start, ShutDown stop action
    (so host auto-shutdown and deallocation shut the guest down cleanly), Secure Boot, no checkpoints.

    .DESCRIPTION
    With -Disconnected (the JumpstartImage mode), a new guest's network adapter isn't connected to the switch: the image's
    published password is replaced over PowerShell Direct before the guest has any network, and the first-boot step
    connects it afterward (vm/hyperv-guest/GuestJumpstart.ps1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $VhdxPath,

        [Parameter(Mandatory = $true)]
        [string] $VmFolder,

        [Parameter(Mandatory = $true)]
        [string] $SwitchName,

        [Parameter(Mandatory = $true)]
        [int] $VCpu,

        [Parameter(Mandatory = $true)]
        [int] $MemoryGiB,

        [switch] $Disconnected
    )

    $memory = [int64]$MemoryGiB * 1GB
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        if ($Disconnected) {
            # New-VM adds one network adapter, connected only when a switch is named.
            New-VM -Name $Name -Generation 2 -MemoryStartupBytes $memory -VHDPath $VhdxPath -Path $VmFolder | Out-Null
        }
        else {
            New-VM -Name $Name -Generation 2 -MemoryStartupBytes $memory -VHDPath $VhdxPath -SwitchName $SwitchName -Path $VmFolder | Out-Null
        }
        Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
        Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface'
        Write-DemoVmLog -Message ('Created the guest VM {0}{1}.' -f $Name, $(if ($Disconnected) { ' with its network adapter not connected yet' } else { '' }))
    }
    elseif ([int]$vm.ProcessorCount -ne $VCpu -or [int64]$vm.MemoryStartup -ne $memory -or $vm.DynamicMemoryEnabled) {
        if ([string]$vm.State -ne 'Off') {
            Stop-VM -Name $Name -Force
        }
    }
    if ([string](Get-VM -Name $Name).State -eq 'Off') {
        Set-VM -Name $Name -ProcessorCount $VCpu -StaticMemory -MemoryStartupBytes $memory -CheckpointType Disabled
    }
    Set-VM -Name $Name -AutomaticStartAction Start -AutomaticStartDelay 0 -AutomaticStopAction ShutDown
    if ([string](Get-VM -Name $Name).State -ne 'Running') {
        Start-VM -Name $Name
    }
}

function Test-DemoGuestOnline {
    # One PowerShell Direct probe; PowerShell Direct uses VMBus, not the network.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential
    )

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm -or [string]$vm.State -ne 'Running') {
        return $false
    }
    try {
        $value = Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
        return (-not [string]::IsNullOrEmpty([string]$value))
    }
    catch {
        return $false
    }
}

function Wait-DemoGuestOnline {
    # Bounded wait inside one task run; the next run continues if the guest is still in OOBE.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [ValidateRange(1, 120)]
        [int] $TimeoutMinutes = 20
    )

    if ([string](Get-VM -Name $Name).State -ne 'Running') {
        Start-VM -Name $Name
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-DemoGuestOnline -Name $Name -Credential $Credential) {
            return $true
        }
        Start-Sleep -Seconds 20
    }
    return $false
}

# ---- A broken PowerShell Direct channel, and the one guest restart that clears it (issue #65, 2026-11-18) ----
# A PowerShell Direct session connects twice: to the guest's broker (vmicvmsession), which signs in and starts a
# PowerShell server with a one-time token, then to that server. Every server listens on the same Hyper-V socket service
# and accepts one connection. A server whose client never connected keeps listening, so each later session reaches the
# server left before it, fails its token check ("The Hyper-V socket target process has ended"), and leaves its own
# server listening in turn, until the guest restarts. Sources: https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct,
# https://learn.microsoft.com/windows-server/virtualization/hyper-v/make-integration-service,
# https://learn.microsoft.com/powershell/module/hyper-v/stop-vm, https://learn.microsoft.com/powershell/module/hyper-v/start-vm.

$script:DemoGuestChannelBrokenPattern = '(?i)Hyper-V socket target process has ended|PSSessionStateBroken'
$script:DemoGuestRecoveryFile = 'guest-recovery.json'

function Get-DemoGuestChannelErrorText {
    # One line from a PowerShell Direct failure: its message and its fully qualified error ID, which tell a broken channel
    # from the other failures. Pure.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $ErrorRecord
    )

    if ($null -eq $ErrorRecord) {
        return ''
    }
    $message = ''
    $exception = $ErrorRecord.PSObject.Properties['Exception']
    if ($null -ne $exception -and $null -ne $exception.Value) {
        $message = [string]$exception.Value.Message
    }
    else {
        $message = [string]$ErrorRecord
    }
    $id = $ErrorRecord.PSObject.Properties['FullyQualifiedErrorId']
    if ($null -ne $id -and [string]$id.Value -and $message -notmatch [regex]::Escape([string]$id.Value)) {
        $message = '{0} ({1})' -f $message.Trim(), [string]$id.Value
    }
    return $message.Trim()
}

function Test-DemoGuestChannelBroken {
    # True when a PowerShell Direct error says the channel broke after it connected (issue #65); a guest that's off,
    # starting, or refusing the credential says something else. Pure.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    return ([string]$Text -match $script:DemoGuestChannelBrokenPattern)
}

function Get-DemoGuestUptime {
    # A Get-VM object's uptime in minutes, rounded to 0.1; 0 when it has none. Pure.
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [AllowNull()]
        [object] $Vm
    )

    if ($null -eq $Vm) {
        return 0.0
    }
    $uptime = $Vm.PSObject.Properties['Uptime']
    if ($null -eq $uptime -or $null -eq $uptime.Value) {
        return 0.0
    }
    return [System.Math]::Round([double]([timespan]$uptime.Value).TotalMinutes, 1)
}

function Get-DemoGuestComputerName {
    # One PowerShell Direct session into the guest that returns its computer name; throws what PowerShell Direct throws.
    # A function of its own so tests can stand in for it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential
    )

    return [string](Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop)
}

function Test-DemoGuestChannel {
    <#
    .SYNOPSIS
    Probes PowerShell Direct into the guest and says how it failed: Ok, State, Heartbeat, UptimeMinutes, Error, and
    Broken, true only when every attempt failed with a broken channel while the guest ran with a healthy heartbeat
    (issue #65). Another failure ends the attempts at once. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [ValidateRange(1, 10)]
        [int] $Attempts = 1,

        [ValidateRange(0, 120)]
        [int] $DelaySeconds = 10
    )

    $result = [ordered]@{ Ok = $false; State = 'Missing'; Heartbeat = ''; UptimeMinutes = 0.0; Error = ''; Broken = $false }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if (-not $vm) {
            $result.State = 'Missing'
            $result.Error = ('There is no guest {0} on this host.' -f $Name)
            $result.Broken = $false
            break
        }
        $result.State = [string]$vm.State
        $result.Heartbeat = [string]$vm.Heartbeat
        $result.UptimeMinutes = Get-DemoGuestUptime -Vm $vm
        if ($result.State -ne 'Running') {
            $result.Error = ('{0} is {1}.' -f $Name, $result.State)
            $result.Broken = $false
            break
        }
        try {
            $value = Get-DemoGuestComputerName -Name $Name -Credential $Credential
            if (-not [string]::IsNullOrEmpty([string]$value)) {
                $result.Ok = $true
                $result.Error = ''
                $result.Broken = $false
                break
            }
            $result.Error = 'PowerShell Direct answered without the computer name.'
            $result.Broken = $false
        }
        catch {
            $result.Error = Get-DemoGuestChannelErrorText -ErrorRecord $_
            $result.Broken = (Test-DemoGuestChannelBroken -Text $result.Error) -and $result.Heartbeat -like 'Ok*'
        }
        if (-not $result.Broken) {
            break
        }
        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    return [pscustomobject]$result
}

function Get-DemoGuestRecoveryDecision {
    <#
    .SYNOPSIS
    What a broken PowerShell Direct channel calls for (issue #65). Returns Action and Reason, and Previous, this run's
    earlier restart. Pure.

    .DESCRIPTION
    - None: the channel isn't broken, the guest doesn't run with a healthy heartbeat, or a golden capture holds it.
    - Wait: it started less than MinUptimeMinutes ago (its own start, or a restart another run made), so it may still be
      starting: wait for it, don't restart it.
    - Exhausted: this run (Key) already restarted it once.
    - Restart: restart it once, for this run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $State = '',

        [AllowEmptyString()]
        [string] $Heartbeat = '',

        [double] $UptimeMinutes = 0,

        [bool] $Broken,

        [AllowNull()]
        [System.Collections.IDictionary] $Record,

        [Parameter(Mandatory = $true)]
        [string] $Key,

        [bool] $CaptureInProgress = $false,

        [ValidateRange(0, 60)]
        [int] $MinUptimeMinutes = 5
    )

    $previous = $null
    if ($null -ne $Record -and $Record.Contains('restarts')) {
        foreach ($entry in @($Record['restarts'])) {
            if ($entry -is [System.Collections.IDictionary] -and [string]$entry['key'] -eq $Key) {
                $previous = $entry
            }
        }
    }
    $decide = {
        param([string] $Action, [string] $Reason)
        [pscustomobject]@{ Action = $Action; Reason = $Reason; Previous = $previous }
    }
    if ($CaptureInProgress) {
        return (& $decide 'None' 'a golden capture is in progress on this host, and only it changes the guest')
    }
    if ($State -ne 'Running') {
        return (& $decide 'None' ('the guest is {0}, so this isn''t a broken channel' -f $(if ($State) { $State } else { 'missing' })))
    }
    if ($Heartbeat -notlike 'Ok*') {
        return (& $decide 'None' ('the guest''s heartbeat is {0}, so it''s starting or not responding; that isn''t a broken channel' -f $(if ($Heartbeat) { $Heartbeat } else { 'unknown' })))
    }
    if (-not $Broken) {
        return (& $decide 'None' 'PowerShell Direct failed in another way than a broken channel')
    }
    if ($UptimeMinutes -lt $MinUptimeMinutes) {
        return (& $decide 'Wait' ('the guest started {0:N1} minutes ago and may still be starting' -f $UptimeMinutes))
    }
    if ($null -ne $previous) {
        $at = $previous['startedUtc']
        if ($at -is [datetime]) {
            # PowerShell 7's ConvertFrom-Json reads an ISO time as a DateTime; Windows PowerShell 5.1 keeps the text.
            $at = $at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        return (& $decide 'Exhausted' ('this run already restarted the guest once, at {0}' -f [string]$at))
    }
    return (& $decide 'Restart' 'PowerShell Direct is broken while the guest runs with a healthy heartbeat')
}

function Read-DemoGuestRecoveryRecord {
    # guest-recovery.json: the guest restarts that cleared a broken channel, the newest last. $null when there's none or
    # it can't be read. Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    try {
        return (Read-DemoVmJsonFile -Path (Join-Path -Path $StateRoot -ChildPath $script:DemoGuestRecoveryFile))
    }
    catch {
        return $null
    }
}

function Save-DemoGuestRecoveryEntry {
    # Adds or replaces (by id) one restart in guest-recovery.json and keeps the last 20. Nothing in it is secret.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Entry
    )

    $record = Read-DemoGuestRecoveryRecord -StateRoot $StateRoot
    $restarts = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $record -and $record.Contains('restarts')) {
        foreach ($item in @($record['restarts'])) {
            if ($item -is [System.Collections.IDictionary] -and [string]$item['id'] -ne [string]$Entry['id']) {
                $restarts.Add($item)
            }
        }
    }
    $restarts.Add($Entry)
    while ($restarts.Count -gt 20) {
        $restarts.RemoveAt(0)
    }
    Write-DemoVmJsonFile -Path (Join-Path -Path $StateRoot -ChildPath $script:DemoGuestRecoveryFile) -InputObject ([ordered]@{ schemaVersion = 1; restarts = $restarts.ToArray() }) -Redact
}

function Enter-DemoGuestRecoveryLock {
    # The host-wide lock around a recovery, so the bootstrap and a Run Command never restart the guest together. Returns
    # the mutex, or $null when another recovery held it for Minutes.
    [CmdletBinding()]
    param(
        [ValidateRange(1, 60)]
        [int] $Minutes = 20
    )

    $mutex = New-Object -TypeName 'System.Threading.Mutex' -ArgumentList $false, 'Global\DbHubDemo-GuestRecovery'
    try {
        if ($mutex.WaitOne([TimeSpan]::FromMinutes($Minutes))) {
            return $mutex
        }
    }
    catch [System.Threading.AbandonedMutexException] {
        # A recovery whose process ended (a restart of the host, a stopped Run Command) left it; it's ours now.
        return $mutex
    }
    $mutex.Dispose()
    return $null
}

function Exit-DemoGuestRecoveryLock {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Lock
    )

    if ($null -ne $Lock) {
        try {
            $Lock.ReleaseMutex()
        }
        finally {
            $Lock.Dispose()
        }
    }
}

function Restart-DemoGuestVm {
    # Shuts the guest down through its operating system (Stop-VM -Force: Hyper-V gives it five minutes, then forces it),
    # turns it off when it's still running after StopMinutes, and starts it. Returns how it stopped: Shutdown or TurnOff.
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [ValidateRange(1, 30)]
        [int] $StopMinutes = 6
    )

    if (-not $PSCmdlet.ShouldProcess($Name, 'Restart the guest')) {
        return ''
    }
    $how = 'Shutdown'
    Stop-VM -Name $Name -Force -AsJob | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes($StopMinutes)
    while ([string](Get-VM -Name $Name).State -ne 'Off' -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 5
    }
    if ([string](Get-VM -Name $Name).State -ne 'Off') {
        $how = 'TurnOff'
        Stop-VM -Name $Name -TurnOff -Force
    }
    Start-VM -Name $Name
    return $how
}

function Get-DemoGuestRecoveryUnfinished {
    # guest-recovery.json's latest entry when its restart never finished (no endedUtc): its process ended between
    # Stop-VM and Start-VM, or before it recorded the end. $null otherwise. Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    $record = Read-DemoGuestRecoveryRecord -StateRoot $StateRoot
    if ($null -eq $record -or -not $record.Contains('restarts')) {
        return $null
    }
    $last = @($record['restarts']) | Select-Object -Last 1
    if ($last -is [System.Collections.IDictionary] -and -not [string]$last['endedUtc']) {
        return $last
    }
    return $null
}

function Test-DemoGuestHeldOff {
    # True while something keeps the guest off on purpose, so nothing may start it: a golden capture in progress, or a
    # capture record that isn't released (a restored copy waiting for its reset and release, or a source the capture
    # hasn't returned yet). A record that can't be read counts as held. Never throws.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    if (Test-Path -LiteralPath ([System.IO.Path]::Combine($StateRoot, 'golden', 'capture-in-progress.json'))) {
        return $true
    }
    $capturePath = [System.IO.Path]::Combine($StateRoot, 'golden', 'capture.json')
    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
        return $false
    }
    try {
        $capture = Read-DemoVmJsonFile -Path $capturePath
        return ($null -eq $capture -or -not [bool]$capture['released'])
    }
    catch {
        return $true
    }
}

function Complete-DemoGuestRecoveryInterrupted {
    <#
    .SYNOPSIS
    Finishes a restart of the guest that its own process didn't (review of #65): a deploy.ps1 stopped with Ctrl+C, a Run
    Command deleted or timed out during the restart, or the host's bootstrap stopped. Returns $null when there's nothing
    to finish, else Action (Interrupted), Restarted, Recovered, Seconds, Reason, By, Key, AtUtc, RestartUtc, StoppedBy,
    and Message, as Invoke-DemoGuestRecovery does. Never throws.

    .DESCRIPTION
    Only when guest-recovery.json's latest entry has no endedUtc, under the host's recovery lock (so not while a restart
    runs), and for the same guest (its VM ID). A guest that's Off is started and waited for, unless something keeps it
    off on purpose (Test-DemoGuestHeldOff: a golden capture, or a restored copy that isn't released yet); one that runs
    only gets its entry completed. The entry ends with stoppedBy Interrupted. A guest that's Off for any other reason,
    without such an entry, is never started here.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [string] $StateRoot = 'C:\ProgramData\DbHubDemo',

        [ValidateRange(1, 60)]
        [int] $LockMinutes = 1,

        [ValidateRange(1, 60)]
        [int] $OnlineMinutes = 10,

        # The caller holds the recovery lock already (Invoke-DemoGuestRecovery).
        [switch] $LockHeld
    )

    $lock = $null
    try {
        if ($null -eq (Get-DemoGuestRecoveryUnfinished -StateRoot $StateRoot)) {
            return $null
        }
        if (-not $LockHeld) {
            $lock = Enter-DemoGuestRecoveryLock -Minutes $LockMinutes
            if ($null -eq $lock) {
                return $null
            }
        }
        # Read again under the lock: a restart that held it has finished its own entry since.
        $entry = Get-DemoGuestRecoveryUnfinished -StateRoot $StateRoot
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $entry -or -not $vm) {
            return $null
        }
        if ([string]$entry['vmId'] -and -not [string]::Equals([string]$entry['vmId'], [string]$vm.VMId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        $state = [string]$vm.State
        if ($state -eq 'Off' -and (Test-DemoGuestHeldOff -StateRoot $StateRoot)) {
            return $null
        }
        if (-not $PSCmdlet.ShouldProcess($Name, 'Finish a restart that was interrupted')) {
            return $null
        }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $result = [ordered]@{ Action = 'Interrupted'; Restarted = $true; Recovered = $false; Seconds = 0; Reason = [string]$entry['reason']; By = [string]$entry['by']; Key = [string]$entry['key']; AtUtc = (Get-DemoVmUtcNow); RestartUtc = [string]$entry['startedUtc']; StoppedBy = 'Interrupted'; Message = '' }
        if ($state -eq 'Off') {
            Write-DemoVmLog -Level 'Warning' -Message ('{0} is off because its restart by {1} at {2} didn''t finish; it''s started again.' -f $Name, $result.By, $result.RestartUtc)
            Start-VM -Name $Name
            Start-Sleep -Seconds 20
        }
        $result.Recovered = Wait-DemoGuestOnline -Name $Name -Credential $Credential -TimeoutMinutes $OnlineMinutes
        $result.Seconds = [int]$clock.Elapsed.TotalSeconds
        $entry['endedUtc'] = Get-DemoVmUtcNow
        $entry['stoppedBy'] = 'Interrupted'
        $entry['recovered'] = [bool]$result.Recovered
        Save-DemoGuestRecoveryEntry -StateRoot $StateRoot -Entry $entry
        # deploy.ps1 reports it once, at the time it was finished, from this result or from the host's health.
        $result.AtUtc = [string]$entry['endedUtc']
        $result.Message = if ($result.Recovered) {
            '{0}''s restart by {1} at {2} was interrupted; {3}, and it answers over PowerShell Direct again.' -f $Name, $result.By, $result.RestartUtc, $(if ($state -eq 'Off') { 'it was started again' } else { 'it was running' })
        }
        else {
            '{0}''s restart by {1} at {2} was interrupted, and it didn''t answer over PowerShell Direct within {3} minutes.' -f $Name, $result.By, $result.RestartUtc, $OnlineMinutes
        }
        Write-DemoVmLog -Level $(if ($result.Recovered) { 'Warning' } else { 'Error' }) -Message $result.Message
        return [pscustomobject]$result
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('An interrupted restart of {0} couldn''t be finished: {1}' -f $Name, (Protect-DemoVmText -Text $_.Exception.Message))
        return $null
    }
    finally {
        Exit-DemoGuestRecoveryLock -Lock $lock
    }
}

function Close-DemoGuestRecoveryUnfinished {
    # Ends an unfinished restart's entry without starting the guest, for the host's own stop (StopGuest), so nothing starts
    # the guest that the stop turns off. Never throws.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string] $StateRoot = 'C:\ProgramData\DbHubDemo',

        [ValidateSet('HostStop')]
        [string] $How = 'HostStop'
    )

    $lock = $null
    try {
        if ($null -eq (Get-DemoGuestRecoveryUnfinished -StateRoot $StateRoot)) {
            return
        }
        $lock = Enter-DemoGuestRecoveryLock -Minutes 1
        $entry = Get-DemoGuestRecoveryUnfinished -StateRoot $StateRoot
        if ($null -eq $lock -or $null -eq $entry -or -not $PSCmdlet.ShouldProcess('guest-recovery.json', 'End an unfinished restart''s entry')) {
            return
        }
        $entry['endedUtc'] = Get-DemoVmUtcNow
        $entry['stoppedBy'] = $How
        $entry['recovered'] = $false
        Save-DemoGuestRecoveryEntry -StateRoot $StateRoot -Entry $entry
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('An unfinished restart''s entry couldn''t be ended: {0}' -f (Protect-DemoVmText -Text $_.Exception.Message))
    }
    finally {
        Exit-DemoGuestRecoveryLock -Lock $lock
    }
}

function Invoke-DemoGuestRecovery {
    <#
    .SYNOPSIS
    Restarts the T2 guest once when PowerShell Direct into it is broken while it runs with a healthy heartbeat, waits for
    it to answer again, and records it in guest-recovery.json (issue #65). Returns Action (None, Healed, Wait, Exhausted,
    Restart, or Busy), Restarted, Recovered, Seconds, Reason, By, Key, AtUtc (when it was asked), RestartUtc, StoppedBy,
    and Message. Never throws.

    .DESCRIPTION
    Under a host-wide lock, it first finishes a restart that its own process didn't (Complete-DemoGuestRecoveryInterrupted:
    it starts a guest that restart left off, and returns that as this recovery). It then probes the guest three times,
    10 seconds apart, so a one-off failure restarts nothing, and another caller's restart counts (Healed).
    Get-DemoGuestRecoveryDecision then decides; a restart happens at most once per Key, the caller's run (deploy.ps1's run,
    a session, or the host bootstrap's generation). The guest shuts down through its operating system
    (Restart-DemoGuestVm), so SQL Server stops cleanly, and starts again; its own startup tasks run, its workload runner's
    profile host included. The restart's entry, with the guest's VM ID, is in guest-recovery.json before the shutdown.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [string] $Key,

        [Parameter(Mandatory = $true)]
        [string] $By,

        [AllowEmptyString()]
        [string] $Reason = '',

        [string] $StateRoot = 'C:\ProgramData\DbHubDemo',

        [ValidateRange(1, 60)]
        [int] $OnlineMinutes = 10,

        [ValidateRange(1, 30)]
        [int] $StopMinutes = 6
    )

    $result = [ordered]@{ Action = 'None'; Restarted = $false; Recovered = $false; Seconds = 0; Reason = $Reason; By = $By; Key = $Key; AtUtc = (Get-DemoVmUtcNow); RestartUtc = ''; StoppedBy = ''; Message = '' }
    $lock = $null
    try {
        $lock = Enter-DemoGuestRecoveryLock
        if ($null -eq $lock) {
            $result.Action = 'Busy'
            $result.Message = ('Another restart of {0} held the host''s recovery lock for 20 minutes, so it wasn''t restarted again.' -f $Name)
            return [pscustomobject]$result
        }
        # A restart whose process ended before it finished (review of #65) is finished first; that counts as this one.
        $interrupted = Complete-DemoGuestRecoveryInterrupted -Name $Name -Credential $Credential -StateRoot $StateRoot -OnlineMinutes $OnlineMinutes -LockHeld -Confirm:$false
        if ($null -ne $interrupted) {
            return $interrupted
        }
        $probe = Test-DemoGuestChannel -Name $Name -Credential $Credential -Attempts 3 -DelaySeconds 10
        if ($probe.Ok) {
            $result.Action = 'Healed'
            $result.Recovered = $true
            $result.Message = ('{0} answers over PowerShell Direct again.' -f $Name)
            return [pscustomobject]$result
        }
        if (-not $result.Reason) {
            $result.Reason = [string]$probe.Error
        }
        $capture = Test-Path -LiteralPath ([System.IO.Path]::Combine($StateRoot, 'golden', 'capture-in-progress.json'))
        $decision = Get-DemoGuestRecoveryDecision -State $probe.State -Heartbeat $probe.Heartbeat -UptimeMinutes $probe.UptimeMinutes -Broken ([bool]$probe.Broken) -Record (Read-DemoGuestRecoveryRecord -StateRoot $StateRoot) -Key $Key -CaptureInProgress $capture
        $result.Action = $decision.Action
        if ($decision.Action -in 'None', 'Exhausted') {
            $result.Message = ('{0} wasn''t restarted: {1}.' -f $Name, $decision.Reason)
            return [pscustomobject]$result
        }
        if ($decision.Action -eq 'Wait') {
            $result.Recovered = Wait-DemoGuestOnline -Name $Name -Credential $Credential -TimeoutMinutes $OnlineMinutes
            $result.Message = ('{0} wasn''t restarted: {1}; it {2} over PowerShell Direct.' -f $Name, $decision.Reason, $(if ($result.Recovered) { 'answers' } else { ('didn''t answer within {0} minutes' -f $OnlineMinutes) }))
            return [pscustomobject]$result
        }
        if (-not $PSCmdlet.ShouldProcess($Name, 'Restart the guest to clear a broken PowerShell Direct channel')) {
            $result.Action = 'None'
            return [pscustomobject]$result
        }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $vmNow = Get-VM -Name $Name -ErrorAction SilentlyContinue
        $entry = [ordered]@{ id = [guid]::NewGuid().ToString('N'); key = $Key; by = $By; reason = (Protect-DemoVmText -Text ([string]$result.Reason)); vmId = $(if ($vmNow) { [string]$vmNow.VMId } else { '' }); startedUtc = (Get-DemoVmUtcNow); endedUtc = ''; seconds = 0; stoppedBy = ''; recovered = $false }
        if (([string]$entry['reason']).Length -gt 400) {
            $entry['reason'] = ([string]$entry['reason']).Substring(0, 400)
        }
        # Recorded before the restart, so this run's one restart counts even when this process ends during it.
        Save-DemoGuestRecoveryEntry -StateRoot $StateRoot -Entry $entry
        $result.RestartUtc = [string]$entry['startedUtc']
        Write-DemoVmLog -Level 'Warning' -Message ('PowerShell Direct into {0} is broken while it runs with a healthy heartbeat ({1}); {2} restarts it once for this run ({3}).' -f $Name, $result.Reason, $By, $Key)
        $result.StoppedBy = Restart-DemoGuestVm -Name $Name -StopMinutes $StopMinutes -Confirm:$false
        $result.Restarted = $true
        Start-Sleep -Seconds 20
        $result.Recovered = Wait-DemoGuestOnline -Name $Name -Credential $Credential -TimeoutMinutes $OnlineMinutes
        $result.Seconds = [int]$clock.Elapsed.TotalSeconds
        $entry['endedUtc'] = Get-DemoVmUtcNow
        $entry['seconds'] = $result.Seconds
        $entry['stoppedBy'] = $result.StoppedBy
        $entry['recovered'] = [bool]$result.Recovered
        Save-DemoGuestRecoveryEntry -StateRoot $StateRoot -Entry $entry
        $result.Message = if ($result.Recovered) {
            '{0} was restarted once ({1}, {2} s) and answers over PowerShell Direct again.' -f $Name, $(if ($result.StoppedBy -eq 'TurnOff') { 'turned off after its shutdown didn''t finish' } else { 'a clean shutdown' }), $result.Seconds
        }
        else {
            '{0} was restarted once, but it didn''t answer over PowerShell Direct within {1} minutes.' -f $Name, $OnlineMinutes
        }
        Write-DemoVmLog -Level $(if ($result.Recovered) { 'Warning' } else { 'Error' }) -Message $result.Message
    }
    catch {
        $result.Message = ('The restart of {0} failed: {1}' -f $Name, (Protect-DemoVmText -Text $_.Exception.Message))
        Write-DemoVmLog -Level 'Error' -Message $result.Message
    }
    finally {
        Exit-DemoGuestRecoveryLock -Lock $lock
    }
    return [pscustomobject]$result
}

function Get-DemoGuestRecoveryKey {
    # The recovery's run key: the caller's own (deploy.ps1's run, a session), else one per hour for a caller that has none,
    # so a restart happens at most once an hour for it. Pure.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Key = '',

        [Parameter(Mandatory = $true)]
        [string] $Prefix,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    if ($Key -match '^[A-Za-z0-9._:-]{1,80}$') {
        return $Key
    }
    return ('{0}-{1}' -f $Prefix, $NowUtc.ToUniversalTime().ToString('yyyyMMddHH', [System.Globalization.CultureInfo]::InvariantCulture))
}
