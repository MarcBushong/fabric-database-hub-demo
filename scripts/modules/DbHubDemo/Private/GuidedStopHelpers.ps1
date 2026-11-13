# The T2 track's wait for the host's build, with progress, and what's left of the PaygWizard guided stop on deploy.ps1's
# side (Phase 28, ADR 0006, ADR 0009, ADR 0018). The guided stop itself is retired (2026-11-09, user-directed: no
# configuration value leads to the setup wizard), and its code is gone; what an earlier guided stop or session left open
# is still cleaned up: the host's request is cleared, Bastion is removed, and the host password is rotated
# (Clear-DemoGuidedStopLeftover). Nothing here displays, logs, or stores a password.
# Sources (checked 2026-10-29):
# - Bastion RDP to a Windows VM: https://learn.microsoft.com/azure/bastion/bastion-connect-vm-rdp-windows
# - Reset a VM's password in the portal (Help, Reset password): https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp
# - az deployment group create --no-wait: https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-create
# - FlashWindowEx: https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-flashwindowex
# - GetConsoleWindow: https://learn.microsoft.com/windows/console/getconsolewindow
# - Console.Beep: https://learn.microsoft.com/dotnet/api/system.console.beep
# - Set-Clipboard (xclip on Linux, pbcopy on macOS; SSH_CLIENT and SSH_TTY mark an SSH session):
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.management/set-clipboard
# - GitHub Codespaces' CODESPACES variable: https://docs.github.com/codespaces/developing-in-a-codespace/default-environment-variables-for-your-codespace

function Get-DemoHostStepOrder {
    # The T2 host's state-machine steps in order (Get-DemoHostStepPlan in vm/bootstrap/Invoke-HostBootstrap.ps1; a test
    # keeps the two the same). Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        'NestedVirtualization', 'HyperVRole', 'DnsServerRole', 'NatNetwork', 'DnsForwarder', 'GuestSource', 'DataDisk', 'GuestOsMedia',
        'GuestVhdx', 'GuestImage', 'GuestVm', 'GuestFirstBoot', 'GuestOnline', 'GuestHardening', 'SqlMedia', 'GuestWebView2', 'SqlUnattendedInstall',
        'JumpstartImageCheck', 'ArcOnboarding', 'ArcOnboardingBeforeWizard', 'GuidedSetup', 'SqlSetupWizard', 'GuestSignInCleanup', 'ConfigureSql',
        'SeedDatabase', 'WorkloadRunner')
}

function Get-DemoT2HostPhase {
    <#
    .SYNOPSIS
    Where the T2 host is, from its health summary: Phase (Build, GuidedStop, AfterSetup, Ready, Failed), Step, Index and
    Count among the build's steps (until it waits for Arc onboarding), and a rough estimate of the build's remaining
    minutes from the documented 60 to 90 minutes a guest build takes, or, in JumpstartImage mode, an estimated 30 to 60
    for the host, the image's download, and its first boot (one live run measured about 27 on 2026-11-06, so the
    estimate errs long). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Health,

        [ValidateSet('JumpstartImage', 'PaygWizard', 'ProductKey', 'Developer')]
        [string] $InstallMode = 'JumpstartImage'
    )

    $order = @(Get-DemoHostStepOrder)
    $step = [string](Get-DemoMemberValue -InputObject $Health -Name 'currentStep')
    $state = [string](Get-DemoMemberValue -InputObject $Health -Name 'state')
    $buildEnd = [array]::IndexOf($order, $(if ($InstallMode -eq 'PaygWizard') { 'ArcOnboardingBeforeWizard' } else { 'ArcOnboarding' }))
    $index = [array]::IndexOf($order, $step)
    $setupIndex = [array]::IndexOf($order, 'SqlSetupWizard')
    $phase = if ($state -eq 'Failed') {
        'Failed'
    }
    elseif ($state -eq 'Ready') {
        'Ready'
    }
    elseif ($index -gt $setupIndex) {
        'AfterSetup'
    }
    elseif ($InstallMode -eq 'PaygWizard' -and $step -in 'GuidedSetup', 'SqlSetupWizard') {
        'GuidedStop'
    }
    elseif ($index -ge $buildEnd -and $state -eq 'WaitingForArcOnboarding') {
        'GuidedStop'
    }
    else {
        'Build'
    }
    $position = [System.Math]::Max(0, [System.Math]::Min($index, $buildEnd))
    $left = 1.0 - ($position / [double][System.Math]::Max(1, $buildEnd))
    $low = 60
    $high = 90
    if ($InstallMode -eq 'JumpstartImage') {
        $low = 30
        $high = 60
    }
    return [pscustomobject]@{
        Phase         = $phase
        Step          = $step
        State         = $state
        Index         = $position + 1
        Count         = $buildEnd + 1
        RemainingLow  = [int][System.Math]::Round($low * $left)
        RemainingHigh = [int][System.Math]::Round($high * $left)
    }
}

function Set-DemoGuidedStopRequest {
    <#
    .SYNOPSIS
    Clears an earlier guided stop's request on the T2 host with vm/bootstrap/Set-DemoGuidedSetupRequest.ps1 in a managed Run
    Command, which also starts the host's bootstrap task: the host then turns the guest's one-time sign-in off. Returns a
    DEPLOY.T2.GUIDEDREQUEST result. Only Clear: nothing writes a request since the guided stop's retirement (2026-11-09).
    Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('Clear')]
        [string] $Action = 'Clear'
    )

    $checkId = 'DEPLOY.T2.GUIDEDREQUEST'
    if (-not $PSCmdlet.ShouldProcess('archost01', 'Clear the guided stop''s request')) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T2' -Status 'Not selected' -Message 'What if: the guided stop''s request wasn''t changed.')
    }
    $script = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/Set-DemoGuidedSetupRequest.ps1') -Raw
    try {
        $run = Invoke-DemoVmRunCommand -Config $Config -VmName 'archost01' -RunCommandName 'DbHubDemo-GuidedSetup' -Script $script -Parameter @{ Action = $Action } -TimeoutSeconds 300 -Confirm:$false
    }
    catch {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('The guided stop''s request couldn''t be cleared on archost01: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed')
    }
    if ($null -ne $run -and $run.Succeeded) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'The guided stop''s request is cleared on archost01: the host turns the guest''s one-time sign-in off within a minute.')
    }
    $detail = if ($null -ne $run) { if ($run.Error) { $run.Error } else { $run.Output } } else { 'no result' }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('The guided stop''s request couldn''t be cleared on archost01: {0}' -f $detail) -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed')
}

function Wait-DemoT2HostBuild {
    <#
    .SYNOPSIS
    Waits, bounded by -DeadlineUtc, for the T2 host to stop building: until it waits for the product key or for Arc
    onboarding, needs a person, is Ready, or Failed. Every poll updates the status page's T2.HostBuild step and prints a
    progress line with the elapsed time, the host's step (n of N), and a rough estimate of when Arc onboarding starts.
    Since 2026-11-09, a host that rebuilds an unfinished PaygWizard guest from Arc Jumpstart's image is followed up once
    (Complete-DemoT2GuestRebuild: the old guest's Arc resources go, and the console and the status page say so, with the
    measured time), the estimate follows the mode the host runs, and a report from the bundle before this run's
    (-BundlePrefix) doesn't end the wait for up to 20 minutes. Since 2026-11-13, reads that find no room for a fresh Run
    Command name (Azure keeps the host's Run Commands in Deleting) end the wait after 15 minutes, with TimedOut and Full.
    Returns Health, TimedOut, Failed, Rebuilt, Results, and Full. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [datetime] $DeadlineUtc,

        [string] $ProgressPath = '',

        [ValidateRange(10, 1800)]
        [int] $PollSeconds = 300,

        [System.Nullable[datetime]] $StartedUtc = $null,

        # The first 12 characters of the bootstrap bundle this run sent to archost01 (2026-11-09): a health whose generation
        # belongs to another bundle is the last run's, from before the loader started this one, so its state doesn't end the
        # wait for up to 20 minutes, and neither its mode nor its guest is taken from it.
        [AllowEmptyString()]
        [string] $BundlePrefix = ''
    )

    $installMode = (Get-DemoArcTarget -Config $Config).InstallMode
    $stopStates = @('WaitingForProductKey', 'WaitingForArcOnboarding', 'ManualActionRequired', 'Ready', 'Failed')
    $started = if ($null -ne $StartedUtc) { [datetime]$StartedUtc } else { [System.DateTime]::UtcNow }
    $waitStarted = [System.DateTime]::UtcNow
    $health = $null
    # 2026-11-09: the host's rebuild of an unfinished guest, followed up once (Complete-DemoT2GuestRebuild).
    $followUp = [System.Collections.Generic.List[object]]::new()
    $rebuilding = $false
    # 2026-11-13 live finding: reads that find no room for a fresh Run Command name (Azure keeps the host's Run Commands in
    # Deleting) end the wait after 15 minutes, as Full, instead of at the deadline.
    $fullSince = $null
    while ($true) {
        try {
            $read = Get-DemoVmHealth -Config $Config -VmName 'archost01' -View Summary
            if ($null -ne $read) {
                $health = $read
            }
            $fullSince = $null
        }
        catch {
            Write-DemoLog -Level Warning -Message ('Reading archost01''s health failed (it may be restarting); reading it again later: {0}' -f $_.Exception.Message)
            if (Test-DemoRunCommandFullError -Text $_.Exception.Message) {
                if ($null -eq $fullSince) {
                    $fullSince = [System.DateTime]::UtcNow
                }
            }
            else {
                $fullSince = $null
            }
        }
        if ($null -ne $fullSince -and ([System.DateTime]::UtcNow - $fullSince).TotalMinutes -ge 15) {
            return [pscustomobject]@{ Health = $health; TimedOut = $true; Failed = $false; Rebuilt = $rebuilding; Results = $followUp.ToArray(); Full = $true }
        }
        if (-not $rebuilding) {
            $rebuild = @(Complete-DemoT2GuestRebuild -Config $Config -Health $health -ProgressPath $ProgressPath -Confirm:$false)
            if ($rebuild.Count -gt 0) {
                $rebuilding = $true
                $installMode = 'JumpstartImage'
                $followUp.AddRange([object[]]$rebuild)
            }
        }
        # The mode the host runs, which can be the existing guest's own (2026-11-09), shapes the estimate.
        $generation = [string](Get-DemoMemberValue -InputObject $health -Name 'generation')
        $stale = [bool]$BundlePrefix -and $null -ne $health -and -not $generation.StartsWith($BundlePrefix, [System.StringComparison]::OrdinalIgnoreCase) -and ([System.DateTime]::UtcNow - $waitStarted).TotalMinutes -lt 20
        $hostMode = [string](Get-DemoMemberValue -InputObject $health -Name 'installMode')
        if (-not $rebuilding -and -not $stale -and $hostMode -in 'JumpstartImage', 'PaygWizard', 'ProductKey', 'Developer') {
            $installMode = $hostMode
        }
        $state = [string](Get-DemoMemberValue -InputObject $health -Name 'state')
        $phase = Get-DemoT2HostPhase -Health $health -InstallMode $installMode
        $elapsed = [int]([System.DateTime]::UtcNow - $started).TotalMinutes
        $estimate = if ($phase.Phase -eq 'Build') {
            $low = [System.DateTime]::UtcNow.AddMinutes($phase.RemainingLow).ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            $high = [System.DateTime]::UtcNow.AddMinutes($phase.RemainingHigh).ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            ' Rough estimate: {0} to {1} more minutes, then Arc onboarding starts (around {2} to {3}).' -f $phase.RemainingLow, $phase.RemainingHigh, $low, $high
        }
        else {
            ''
        }
        $what = if ($rebuilding) { 'makes T2 again from Arc Jumpstart''s image (about 27 minutes in all, measured on 2026-11-06, with the 34 GiB download at about 51 MiB/s)' } elseif ($stale) { 'starts this run''s bootstrap (its last report is from the bundle before)' } else { 'builds its guest' }
        $message = 'archost01 {5}: step {0} ({1} of {2}), {3} minutes so far.{4}' -f $(if ($phase.Step) { $phase.Step } else { 'starting' }), $phase.Index, $phase.Count, $elapsed, $estimate, $what
        # 2026-11-13 live finding: while Azure keeps DbHubDemo-HealthRead in Deleting, the reads run under a fresh name.
        if (@(Get-DemoRunCommandStuckResult -VmName 'archost01').Count -gt 0) {
            $message += ' Azure keeps a Run Command name on archost01 in Deleting, so its health reads run under a fresh name (DEPLOY.RUNCOMMAND.STUCK_ARCHOST01; nothing to do).'
        }
        Set-DemoProgressStep -Path $ProgressPath -Id 'T2.HostBuild' -State 'Running' -Message $message
        Write-DemoLog -Message ('T2: {0}' -f $message)
        if ($state -in $stopStates -and -not $stale) {
            return [pscustomobject]@{ Health = $health; TimedOut = $false; Failed = ($state -eq 'Failed'); Rebuilt = $rebuilding; Results = $followUp.ToArray(); Full = $false }
        }
        $left = ($DeadlineUtc - [System.DateTime]::UtcNow).TotalSeconds
        if ($left -le 0) {
            return [pscustomobject]@{ Health = $health; TimedOut = $true; Failed = $false; Rebuilt = $rebuilding; Results = $followUp.ToArray(); Full = $false }
        }
        $poll = if ($stale) { [System.Math]::Min($PollSeconds, 60) } else { $PollSeconds }
        Start-Sleep -Seconds ([int][System.Math]::Max(5, [System.Math]::Min($poll, $left)))
    }
}

function Test-DemoClipboard {
    # True when this session has a clipboard the person at the keyboard can paste from (review finding 3). PowerShell
    # 7's Set-Clipboard doesn't fail where there's none: on Linux it needs xclip and on macOS pbcopy (Set-Clipboard's
    # documentation, https://learn.microsoft.com/powershell/module/microsoft.powershell.management/set-clipboard), and
    # without the tool, or when xclip has no X display, it keeps the text inside its own process. So: never in GitHub
    # Codespaces (CODESPACES), an SSH session (SSH_CLIENT or SSH_TTY, as that page detects one: the clipboard there
    # isn't the person's), or Azure Cloud Shell; on macOS only with pbcopy; on Linux only with an X display (DISPLAY,
    # which XWayland sets too) and xclip; on Windows when Set-Clipboard takes text. -Platform is for tests. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [ValidateSet('', 'Windows', 'MacOS', 'Linux')]
        [string] $Platform = ''
    )

    if (-not $Platform) {
        $Platform = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'MacOS' } else { 'Linux' }
    }
    $variable = { param([string] $Name) [string][System.Environment]::GetEnvironmentVariable($Name) }
    # Azure Cloud Shell sets AZUREPS_HOST_ENVIRONMENT to cloud-shell/<version>, which Learn doesn't document, so it's
    # only a second line: Cloud Shell is Linux without a display, which the Linux rule below refuses anyway.
    if ((& $variable 'CODESPACES') -eq 'true' -or (& $variable 'SSH_CLIENT') -or (& $variable 'SSH_TTY') -or (& $variable 'AZUREPS_HOST_ENVIRONMENT') -like 'cloud-shell*') {
        return $false
    }
    if ($Platform -eq 'Linux' -and -not (& $variable 'DISPLAY')) {
        return $false
    }
    $tool = switch ($Platform) {
        'MacOS' { 'pbcopy' }
        'Linux' { 'xclip' }
        default { '' }
    }
    if ($tool -and -not (Get-Command -Name $tool -CommandType Application -ErrorAction SilentlyContinue)) {
        return $false
    }
    if (-not (Get-Command -Name 'Set-Clipboard' -ErrorAction SilentlyContinue)) {
        return $false
    }
    try {
        Set-Clipboard -Value ' ' -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Write-DemoConsoleBlock {
    # Writes lines to the console, each redacted (Protect-DemoLogText), in one color. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Operator console output. Every line is redacted before it is written.')]
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]] $Line = @(),

        [ValidateSet('Cyan', 'Yellow', 'Green', 'Red', 'White', 'Gray')]
        [string] $Color = 'White'
    )

    foreach ($text in @($Line)) {
        Write-Host (Protect-DemoLogText -Text ([string]$text)) -ForegroundColor $Color
    }
}

function Get-DemoBannerLine {
    # A large banner's lines: a frame of # around the title. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Title,

        [ValidateRange(40, 120)]
        [int] $Width = 80
    )

    $frame = '#' * $Width
    $inner = $Width - 6
    $text = if ($Title.Length -gt $inner) { $Title.Substring(0, $inner) } else { $Title }
    return @($frame, ('##  {0}##' -f $text.PadRight($inner)), $frame)
}

function Invoke-DemoAttention {
    # Draws attention to the console: a bell, a beep on Windows, and the console window's taskbar button flashing until
    # it's in front (FlashWindowEx with FLASHW_ALL and FLASHW_TIMERNOFG on GetConsoleWindow). Best effort; never throws.
    # Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Writes only the console bell character (BEL) to the operator''s console, never text.')]
    [CmdletBinding()]
    param()

    try {
        if (-not [System.Console]::IsOutputRedirected) {
            [System.Console]::Write([char]7)
        }
    }
    catch {
        Write-Debug -Message 'The console bell isn''t available.'
    }
    if (-not $IsWindows) {
        return
    }
    try {
        [System.Console]::Beep(880, 300)
        if (-not ('DbHubDemoAttention' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DbHubDemoAttention
{
    [StructLayout(LayoutKind.Sequential)]
    private struct FlashInfo { public uint Size; public IntPtr Window; public uint Flags; public uint Count; public uint Timeout; }

    [DllImport("user32.dll")] private static extern bool FlashWindowEx(ref FlashInfo info);
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();

    public static bool Flash()
    {
        IntPtr window = GetConsoleWindow();
        if (window == IntPtr.Zero) { return false; }
        FlashInfo info = new FlashInfo();
        info.Size = (uint)Marshal.SizeOf(typeof(FlashInfo));
        info.Window = window;
        info.Flags = 3 | 12;
        info.Count = 0;
        info.Timeout = 0;
        return FlashWindowEx(ref info);
    }
}
'@
        }
        $null = [DbHubDemoAttention]::Flash()
    }
    catch {
        Write-Debug -Message ('The console window couldn''t flash: {0}' -f $_.Exception.Message)
    }
}

function Complete-DemoGuidedStop {
    <#
    .SYNOPSIS
    The guided stop's cleanup on deploy.ps1's side, run whatever happened: clears the host's request (the host then
    turns the guest's one-time sign-in off), removes Bastion, rotates the host password when one was handed over (a
    Warning when it can't be: stop-demo.ps1 rotates it later), disables the Key Vault copy with the opt-in, and clears
    the state's request time once Bastion is gone: while Bastion couldn't be removed, the record stays, so the next run
    tries again and isn't DONE before (Get-DemoGuidedStopLeftover; Phase 28 review). Returns the results. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if (-not $PSCmdlet.ShouldProcess('archost01', 'Clean up after the guided stop')) {
        return $results.ToArray()
    }
    $clear = Set-DemoGuidedStopRequest -Config $Config -Action Clear -Confirm:$false
    if ($clear.status -ne 'Pass') {
        $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDCLEANUP' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('{0} The request expires on its own, and the host then turns the guest''s one-time sign-in off and cleans up.' -f $clear.message) -Remediation 'Nothing to do; ./scripts/check-sign-in-data.ps1 confirms the guest is clean.'))
    }
    $bastion = Remove-DemoBastion -Config $Config -Confirm:$false
    $bastionGone = [string]$bastion.status -in 'Pass', 'Not selected'
    if (-not $bastionGone) {
        $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.BASTION' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('Bastion couldn''t be removed after the guided stop: {0}' -f $bastion.message) -Remediation 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly; the bastion-cleanup workflow also removes it after its expiry.'))
    }
    $state = $null
    try {
        $state = Get-DemoDeploymentState -Config $Config
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The deployment state couldn''t be read after the guided stop: {0}' -f $_.Exception.Message)
    }
    if ($null -eq $state -or [string](Get-DemoMemberValue -InputObject $state -Name 'HostPasswordUtc')) {
        $rotation = Set-DemoVmLocalPassword -Config $Config -VmName 'archost01' -Rotate -Confirm:$false
        if ([string]$rotation.status -in 'Pass', 'Warning') {
            $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'The host password from the guided stop was rotated to a value nobody keeps.' -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('The host password from the guided stop couldn''t be rotated yet: {0}' -f $rotation.message) -Remediation 'Run ./scripts/stop-demo.ps1, which rotates it; or in the Azure portal open archost01, then Help, then Reset password, and set a random value you don''t keep.' -DocUrl 'https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp'))
        }
    }
    if ((Get-DemoKeyVaultSetting -Config $Config).Enabled) {
        $results.Add((Disable-DemoHostPasswordSecret -Config $Config -VmName 'archost01' -CheckId 'DEPLOY.T2.KEYVAULT' -Confirm:$false))
    }
    if ($bastionGone) {
        try {
            Set-DemoDeploymentStateLocked -Config $Config -Value @{ GuidedStopUtc = '' } -Confirm:$false
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The guided stop''s end wasn''t recorded: {0}' -f $_.Exception.Message)
        }
    }
    return $results.ToArray()
}

function Get-DemoGuidedStopLeftover {
    <#
    .SYNOPSIS
    What a guided stop or a session left open, from the deployment state (Phase 28 review): a guided stop whose cleanup
    didn't finish (GuidedStopUtc, as after a Ctrl+C at the guided stop: its on-demand Bastion may still be up), and a
    handed-over host password that isn't rotated yet (HostPasswordUtc, which the guided stop and start-demo.ps1
    -Interactive record). Returns what to name, or '' when nothing is open or there's no state. DONE waits for both
    (Get-DemoDeploymentOutcome). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $State
    )

    if ($null -eq $State) {
        return ''
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ([string](Get-DemoMemberValue -InputObject $State -Name 'GuidedStopUtc')) {
        $parts.Add('the guided stop''s on-demand Bastion (its cleanup didn''t finish)')
    }
    $handedOver = [string](Get-DemoMemberValue -InputObject $State -Name 'HostPasswordUtc')
    if ($handedOver) {
        $parts.Add(('the T2 host''s password, handed over at {0} and not rotated yet' -f $handedOver))
    }
    return ($parts -join ', and ')
}

function Clear-DemoGuidedStopLeftover {
    <#
    .SYNOPSIS
    Cleans up what an earlier guided stop or session left open, before T2 counts as done (Phase 28 review). When the
    deployment state records it (Get-DemoGuidedStopLeftover), runs Complete-DemoGuidedStop, which clears the host's
    request, removes Bastion, rotates the host password, and disables the Key Vault copy; then reads the state again.
    Returns its results with DEPLOY.T2.GUIDEDLEFTOVER: Pass when nothing is left; Manual action required naming
    stop-demo.ps1 when something is, so the run isn't DONE with it. Returns nothing when nothing is recorded, when
    deploy.ps1 is being stopped (Test-DemoRunCancelled: the next run does it), and in the evaluation-only mode, which
    has no guided stop (DONE still waits, and stop-demo.ps1 does it). With -Provisional, what's still open is a Warning
    instead: a later check gives the final word (the T2 step's own, at its end, and DONE, which reads the state), so a
    cleanup that succeeds there isn't outvoted by this one (review of 27396a4: the T2 track's cleanup before the loader).
    Internal.

    .DESCRIPTION
    After a Ctrl+C at the guided stop, the guided stop skipped its cleanup (Phase 28 live finding), and setup may have
    finished in the guest anyway; before this, nothing removed Bastion or rotated the password, and the run could end
    DONE. Since the guided stop's retirement (2026-11-09), only this cleans up what an earlier one, or start-demo.ps1
    -Interactive, left open: the T2 track before its loader (-Provisional) and at its T2 step's end, whatever it reached
    (-NoWaitForT2, a golden redeploy), and deploy.ps1 -Sequential's T2 stage.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $Provisional
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if ((Test-DemoRunCancelled) -or (Get-DemoHostVmName -Config $Config) -ne 'archost01') {
        return $results.ToArray()
    }
    $readState = {
        try {
            Get-DemoDeploymentState -Config $Config
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The deployment state couldn''t be read to check what a guided stop left open: {0}' -f $_.Exception.Message)
            $null
        }
    }
    $open = Get-DemoGuidedStopLeftover -State (& $readState)
    if (-not $open) {
        return $results.ToArray()
    }
    if (-not $PSCmdlet.ShouldProcess('archost01', ('Clean up {0}' -f $open))) {
        return $results.ToArray()
    }
    Write-DemoLog -Message ('T2: {0} is still open from an earlier guided stop or session; cleaning it up now.' -f $open)
    $results.AddRange([object[]]@(Complete-DemoGuidedStop -Config $Config -Confirm:$false))
    $after = & $readState
    $left = Get-DemoGuidedStopLeftover -State $after
    $remediation = 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly: it removes Bastion and rotates the host password, and leaves the VMs running.'
    if ($null -eq $after) {
        $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDLEFTOVER' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('The cleanup of {0} ran, but the deployment state couldn''t be read to confirm it.' -f $open) -Remediation ('./scripts/status.ps1 shows whether Bastion is still up. {0}' -f $remediation)))
    }
    elseif ($left -and $Provisional) {
        $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDLEFTOVER' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('{0} is still open after this cleanup; the T2 step tries again at its end, and DONE waits until nothing is open.' -f $left) -Remediation $remediation))
    }
    elseif ($left) {
        $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDLEFTOVER' -Area 'infra' -Target 'T2' -Status 'Manual action required' -Message ('{0} is still open after the cleanup, so the run isn''t DONE: DONE never leaves access to the T2 host behind.' -f $left) -Remediation $remediation))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDLEFTOVER' -Area 'infra' -Target 'T2' -Status 'Pass' -Message ('Cleaned up what an earlier guided stop or session left open ({0}); none of it is left.' -f $open)))
    }
    return $results.ToArray()
}

function Get-DemoGuidedSignInStatus {
    <#
    .SYNOPSIS
    STATUS.T2.AUTOSIGNIN (Phase 28, brief item 12): what archost01's health says about the guest's one-time automatic
    sign-in, from its summary (guidedArmed, guidedRequest, guidedLeft) or its full health (details.guidedSetup). The
    guided stop is retired (2026-11-09), so it's only an earlier one's leftover: a Warning when it's still armed, with
    deploy.ps1 as the fix while that guided stop's request hasn't expired, or when the last cleanup didn't finish:
    archost01's next pass (every 5 minutes while it runs) removes the leftovers, and check-sign-in-data.ps1 -Clean does
    too. $null when nothing is armed or left. Read-only. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Health
    )

    if ($null -eq $Health) {
        return $null
    }
    $detail = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Health -Name 'details') -Name 'guidedSetup'
    $armed = if ($null -ne $detail) { Get-DemoMemberValue -InputObject $detail -Name 'armed' } else { Get-DemoMemberValue -InputObject $Health -Name 'guidedArmed' }
    $request = [string]$(if ($null -ne $detail) { Get-DemoMemberValue -InputObject $detail -Name 'request' } else { Get-DemoMemberValue -InputObject $Health -Name 'guidedRequest' })
    $problemList = if ($null -ne $detail) { Get-DemoMemberValue -InputObject $detail -Name 'lastProblems' } else { Get-DemoMemberValue -InputObject $Health -Name 'guidedLeft' }
    $problems = @(@($problemList) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $docUrl = 'https://learn.microsoft.com/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon'
    $evidence = [ordered]@{ armed = [bool]$armed; request = $request; problems = $problems }
    if ([bool]$armed -and $request -eq 'valid') {
        # The guided stop is retired (2026-11-09), so a request that hasn't expired is an earlier one's leftover:
        # deploy.ps1 clears it before T2's loader (DEPLOY.T2.GUIDEDLEFTOVER), and the host then turns the sign-in off.
        return (New-DemoResult -CheckId 'STATUS.T2.AUTOSIGNIN' -Area 't2' -Target 'T2' -Status 'Warning' -Message 'Automatic sign-in is still armed in arcsql01 for an earlier guided stop, whose request hasn''t expired; the guided stop is retired (2026-11-09), so nothing uses it.' -Evidence $evidence -Remediation 'Run ./scripts/deploy.ps1: it clears the request before T2''s loader, and archost01''s next pass then turns automatic sign-in off, deletes the LSA secret and the Winlogon values, rotates the guest password, and signs the console out. ./scripts/check-sign-in-data.ps1 -Clean removes them too.' -DocUrl $docUrl)
    }
    if ([bool]$armed) {
        return (New-DemoResult -CheckId 'STATUS.T2.AUTOSIGNIN' -Area 't2' -Target 'T2' -Status 'Warning' -Message 'Automatic sign-in is still armed in arcsql01, but no guided stop is waiting.' -Evidence $evidence -Remediation 'Nothing to do while archost01 runs: its next pass (within about 5 minutes) turns it off, deletes the LSA secret and the Winlogon values, rotates the guest password, and signs the console out. ./scripts/check-sign-in-data.ps1 -Clean removes them too.' -DocUrl $docUrl)
    }
    if ($problems.Count -gt 0) {
        return (New-DemoResult -CheckId 'STATUS.T2.AUTOSIGNIN' -Area 't2' -Target 'T2' -Status 'Warning' -Message ('The guided stop''s last cleanup in arcsql01 didn''t finish: {0}.' -f ($problems -join '; ')) -Evidence $evidence -Remediation 'archost01 runs it again on its next pass; ./scripts/check-sign-in-data.ps1 -Clean checks and removes what''s left.' -DocUrl $docUrl)
    }
    return $null
}

function Get-DemoUtcNow {
    # The current UTC time. The chunk sender's stall check and other waits read it here, so tests can move time on.
    # Internal.
    [CmdletBinding()]
    [OutputType([datetime])]
    param()

    return [System.DateTime]::UtcNow
}
