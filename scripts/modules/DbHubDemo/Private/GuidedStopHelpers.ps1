# The PaygWizard guided stop on deploy.ps1's side (Phase 28, ADR 0006, ADR 0009, ADR 0018): the T2 track waits for the
# host's guest build with progress, writes the host's request, starts on-demand Bastion, onboards Arc, and waits for the
# host to open the pre-filled setup in the guest; then the person is prompted (by deploy.ps1's own process, which owns
# the console, the clipboard, and the browser), and the track waits for the host's setup check. Whatever happens, the
# request is cleared, Bastion is removed, and the host password is rotated. Nothing here displays, logs, or stores a
# password.
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
        'NestedVirtualization', 'HyperVRole', 'DnsServerRole', 'NatNetwork', 'DnsForwarder', 'DataDisk', 'GuestOsMedia',
        'GuestVhdx', 'GuestVm', 'GuestOnline', 'GuestHardening', 'SqlMedia', 'GuestWebView2', 'SqlUnattendedInstall', 'ArcOnboarding',
        'ArcOnboardingBeforeWizard', 'GuidedSetup', 'SqlSetupWizard', 'GuestSignInCleanup', 'ConfigureSql', 'SeedDatabase', 'WorkloadRunner')
}

function Get-DemoT2HostPhase {
    <#
    .SYNOPSIS
    Where the T2 host is, from its health summary: Phase (Build, GuidedStop, AfterSetup, Ready, Failed), Step, Index and
    Count among the build's steps (until it waits for Arc onboarding), and a rough estimate of the build's remaining
    minutes from the documented 60 to 90 minutes a guest build takes. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Health,

        [ValidateSet('PaygWizard', 'ProductKey', 'Developer')]
        [string] $InstallMode = 'PaygWizard'
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
    return [pscustomobject]@{
        Phase         = $phase
        Step          = $step
        State         = $state
        Index         = $position + 1
        Count         = $buildEnd + 1
        RemainingLow  = [int][System.Math]::Round(60 * $left)
        RemainingHigh = [int][System.Math]::Round(90 * $left)
    }
}

function Get-DemoPortalVmUrl {
    # The Azure portal's page for a demo VM, in the configured tenant (its Connect menu has Bastion). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $VmName = 'archost01'
    )

    return ('https://portal.azure.com/#@{0}/resource/subscriptions/{1}/resourceGroups/{2}/providers/Microsoft.Compute/virtualMachines/{3}' -f [string]$Config['tenantId'], [string]$Config['subscriptionId'], (Get-DemoResourceGroupName -Config $Config), $VmName)
}

function Set-DemoGuidedStopRequest {
    <#
    .SYNOPSIS
    Writes (Set) or clears (Clear) the guided stop's request on the T2 host with vm/bootstrap/Set-DemoGuidedSetupRequest.ps1
    in a managed Run Command, which also starts the host's bootstrap task. Returns a DEPLOY.T2.GUIDEDREQUEST result. The
    request holds identifiers and an expiry, never a secret. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('Set', 'Clear')]
        [string] $Action,

        [string] $RequestId = '',

        [System.Nullable[datetime]] $ExpiresUtc = $null
    )

    $checkId = 'DEPLOY.T2.GUIDEDREQUEST'
    if (-not $PSCmdlet.ShouldProcess('archost01', ('{0} the guided stop''s request' -f $Action))) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T2' -Status 'Not selected' -Message 'What if: the guided stop''s request wasn''t changed.')
    }
    $parameters = @{ Action = $Action }
    if ($Action -eq 'Set') {
        $parameters['RequestId'] = $RequestId
        $parameters['ExpiresUtc'] = ([datetime]$ExpiresUtc).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $parameters['SubscriptionId'] = [string]$Config['subscriptionId']
        $parameters['ResourceGroup'] = Get-DemoResourceGroupName -Config $Config
        $parameters['Region'] = [string]$Config['location']
        $parameters['TenantId'] = [string]$Config['tenantId']
    }
    $script = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/Set-DemoGuidedSetupRequest.ps1') -Raw
    try {
        $run = Invoke-DemoVmRunCommand -Config $Config -VmName 'archost01' -RunCommandName 'DbHubDemo-GuidedSetup' -Script $script -Parameter $parameters -TimeoutSeconds 300 -Confirm:$false
    }
    catch {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('The guided stop''s request couldn''t be {0} on archost01: {1}' -f $(if ($Action -eq 'Set') { 'written' } else { 'cleared' }), (Protect-DemoText -Text $_.Exception.Message)) -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed')
    }
    if ($null -ne $run -and $run.Succeeded) {
        $text = if ($Action -eq 'Set') { 'The guided stop''s request is on archost01 until {0}: the host prepares the pre-filled setup and the guest''s one-time sign-in.' -f $parameters['ExpiresUtc'] } else { 'The guided stop''s request is cleared on archost01: the host turns the guest''s one-time sign-in off within a minute.' }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T2' -Status 'Pass' -Message $text)
    }
    $detail = if ($null -ne $run) { if ($run.Error) { $run.Error } else { $run.Output } } else { 'no result' }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('The guided stop''s request couldn''t be {0} on archost01: {1}' -f $(if ($Action -eq 'Set') { 'written' } else { 'cleared' }), $detail) -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed')
}

function Wait-DemoBastionDeployment {
    # Waits at most -TimeoutMinutes for New-DemoBastion -NoWait's deployment (bastion-on-demand) to finish. Returns
    # Succeeded and State. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(1, 60)]
        [int] $TimeoutMinutes = 20,

        [ValidateRange(5, 300)]
        [int] $PollSeconds = 30
    )

    $deadline = [System.DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $state = ''
    while ($true) {
        $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'group', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', 'bastion-on-demand', '--query', 'properties.provisioningState', '--output', 'tsv') -AllowFailure
        $state = if ($read.ExitCode -eq 0) { ([string]$read.StdOut).Trim() } else { '' }
        if ($state -eq 'Succeeded') {
            return [pscustomobject]@{ Succeeded = $true; State = $state }
        }
        if ($state -in 'Failed', 'Canceled') {
            return [pscustomobject]@{ Succeeded = $false; State = $state }
        }
        if ([System.DateTime]::UtcNow -ge $deadline) {
            return [pscustomobject]@{ Succeeded = $false; State = $(if ($state) { $state } else { 'TimedOut' }) }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Wait-DemoT2HostBuild {
    <#
    .SYNOPSIS
    Waits, bounded by -DeadlineUtc, for the T2 host to stop building: until it waits for the product key or for Arc
    onboarding, needs a person, is Ready, or Failed. Every poll updates the status page's T2.HostBuild step and prints a
    progress line with the elapsed time, the host's step (n of N), and a rough estimate of when the guided stop comes.
    Returns Health, TimedOut, and Failed. Internal.
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

        [System.Nullable[datetime]] $StartedUtc = $null
    )

    $installMode = (Get-DemoArcTarget -Config $Config).InstallMode
    $stopStates = @('WaitingForProductKey', 'WaitingForArcOnboarding', 'ManualActionRequired', 'Ready', 'Failed')
    $started = if ($null -ne $StartedUtc) { [datetime]$StartedUtc } else { [System.DateTime]::UtcNow }
    $health = $null
    while ($true) {
        try {
            $read = Get-DemoVmHealth -Config $Config -VmName 'archost01' -View Summary
            if ($null -ne $read) {
                $health = $read
            }
        }
        catch {
            Write-DemoLog -Level Warning -Message ('Reading archost01''s health failed (it may be restarting); reading it again later: {0}' -f $_.Exception.Message)
        }
        $state = [string](Get-DemoMemberValue -InputObject $health -Name 'state')
        $phase = Get-DemoT2HostPhase -Health $health -InstallMode $installMode
        $elapsed = [int]([System.DateTime]::UtcNow - $started).TotalMinutes
        $estimate = if ($phase.Phase -eq 'Build') {
            $low = [System.DateTime]::UtcNow.AddMinutes($phase.RemainingLow).ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            $high = [System.DateTime]::UtcNow.AddMinutes($phase.RemainingHigh).ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            $after = if ($installMode -eq 'PaygWizard') { 'the guided stop needs you' } else { 'Arc onboarding starts' }
            ' Rough estimate: {0} to {1} more minutes, then {2} (around {3} to {4}).' -f $phase.RemainingLow, $phase.RemainingHigh, $after, $low, $high
        }
        else {
            ''
        }
        $message = 'archost01 builds its guest: step {0} ({1} of {2}), {3} minutes so far.{4}' -f $(if ($phase.Step) { $phase.Step } else { 'starting' }), $phase.Index, $phase.Count, $elapsed, $estimate
        Set-DemoProgressStep -Path $ProgressPath -Id 'T2.HostBuild' -State 'Running' -Message $message
        Write-DemoLog -Message ('T2: {0}' -f $message)
        if ($state -in $stopStates) {
            return [pscustomobject]@{ Health = $health; TimedOut = $false; Failed = ($state -eq 'Failed') }
        }
        $left = ($DeadlineUtc - [System.DateTime]::UtcNow).TotalSeconds
        if ($left -le 0) {
            return [pscustomobject]@{ Health = $health; TimedOut = $true; Failed = $false }
        }
        Start-Sleep -Seconds ([int][System.Math]::Max(5, [System.Math]::Min($PollSeconds, $left)))
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

function Invoke-DemoGuidedStopCredential {
    <#
    .SYNOPSIS
    The host credential for the guided stop's Bastion sign-in, the documented way for this session (ADR 0009): with the
    Key Vault opt-in, a one-time password stored in the vault first, then set on the host; else, with a working
    clipboard, a one-time password set on the host and copied to the clipboard, never shown; else no password at all:
    the person resets it in the portal (Help, Reset password) to one of their own, and the host password is rotated
    afterward, so the state records that a password was handed over. Returns Mode (keyVault, clipboard, or
    portalReset), UserName, Text, and Results. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $VmName = 'archost01',

        [System.Nullable[datetime]] $ExpiresUtc = $null
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $expiry = if ($null -ne $ExpiresUtc) { ([datetime]$ExpiresUtc).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
    if ((Get-DemoKeyVaultSetting -Config $Config).Enabled) {
        $vault = @(Initialize-DemoKeyVault -Config $Config -EnsureOnly -Confirm:$false)
        $results.AddRange([object[]]$vault)
        if (@($vault | Where-Object { $_.status -eq 'Fail' }).Count -eq 0) {
            $oneTime = New-DemoAdminPassword
            try {
                $stored = Set-DemoHostPasswordSecret -Config $Config -VmName $VmName -Password $oneTime -ExpiresUtc $expiry -Confirm:$false
                $results.Add($stored)
                if ($stored.status -eq 'Pass') {
                    $applied = Set-DemoVmLocalPassword -Config $Config -VmName $VmName -Password $oneTime -Confirm:$false
                    $results.Add($applied)
                    if ($applied.status -in 'Pass', 'Warning') {
                        $user = [string](Get-DemoMemberValue -InputObject $stored.evidence -Name 'userName')
                        $steps = ([string]$stored.message -split 'stop-demo\.ps1 rotates it and disables the secret\. ', 2)[-1]
                        return [pscustomobject]@{ Mode = 'keyVault'; UserName = $user; Text = $steps; Results = $results.ToArray() }
                    }
                    $results.Add((Disable-DemoHostPasswordSecret -Config $Config -VmName $VmName -CheckId 'DEPLOY.T2.KEYVAULT.CLEANUP' -Confirm:$false))
                }
            }
            finally {
                $oneTime.Dispose()
            }
        }
    }
    if (Test-DemoClipboard) {
        $password = New-DemoAdminPassword
        try {
            $set = Set-DemoVmLocalPassword -Config $Config -VmName $VmName -Password $password -Confirm:$false
            $results.Add($set)
            if ($set.status -in 'Pass', 'Warning') {
                $user = [string](Get-DemoMemberValue -InputObject $set.evidence -Name 'userName')
                try {
                    Set-Clipboard -Value ([System.Net.NetworkCredential]::new('', $password).Password) -ErrorAction Stop
                    return [pscustomobject]@{ Mode = 'clipboard'; UserName = $user; Text = ''; Results = $results.ToArray() }
                }
                catch {
                    Write-DemoLog -Level Warning -Message 'The one-time password was set but couldn''t be copied to the clipboard, and it''s never displayed: use the portal''s Reset password instead.'
                }
            }
        }
        finally {
            $password.Dispose()
        }
    }
    # No clipboard and no vault (Codespaces, Cloud Shell, an SSH session): nothing is set or shown. The person sets a
    # password of their own in the portal, and the state records it, so this run and stop-demo.ps1 rotate it.
    $userRead = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('vm', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', $VmName, '--query', 'osProfile.adminUsername', '--output', 'tsv') -AllowFailure
    $userName = if ($userRead.ExitCode -eq 0) { ([string]$userRead.StdOut).Trim() } else { '' }
    try {
        Set-DemoDeploymentState -Config $Config -Value @{ HostPasswordSet = [System.DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } -Confirm:$false
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The resource group couldn''t record that the host password is handed over, so stop-demo.ps1 may not rotate it: {0}' -f $_.Exception.Message)
    }
    $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'This session has no working clipboard and no Key Vault opt-in, so no password was set or shown: you set one of your own in the Azure portal (Help, Reset password), and it''s rotated after the guided stop.' -DocUrl 'https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp'))
    return [pscustomobject]@{ Mode = 'portalReset'; UserName = $userName; Text = ''; Results = $results.ToArray() }
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

function Get-DemoHumanActionLine {
    # The one plain handoff line an assistant can relay (brief item 13). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $PagePath = '',

        [System.Nullable[datetime]] $DeadlineUtc = $null,

        [string] $HostVm = 'archost01'
    )

    $until = if ($null -ne $DeadlineUtc) { ', by {0} (local time)' -f ([datetime]$DeadlineUtc).ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
    # Without a status page (-NoStatusPage, or one that couldn't be set up) the steps are only in the console.
    $where = if ($PagePath) { '{0} (or ./scripts/status.ps1 -Watch)' -f $PagePath } else { 'printed above in deploy.ps1''s console (there''s no status page in this run; ./scripts/status.ps1 shows where the host is)' }
    return ('HUMAN ACTION REQUIRED: DEPLOY.T2.GUIDEDSTOP - a person signs in to {0} through Bastion and finishes SQL Server setup in arcsql01 (pay-as-you-go, Standard, Use Azure Login; about 10 minutes){1}. No assistant can do these sign-ins. Steps and link: {2}.' -f $HostVm, $until, $where)
}

function Show-DemoGuidedStopPrompt {
    <#
    .SYNOPSIS
    The guided stop's unmissable prompt (brief item 4): a large banner, the steps with the credential's way in, how long
    the run waits and what to run after that, the portal link (opened in the browser where possible), a bell and the
    console window flashing, and the HUMAN ACTION REQUIRED line. Internal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Url,

        [Parameter(Mandatory)]
        [datetime] $DeadlineUtc,

        [string] $HostVm = 'archost01',

        [AllowEmptyString()]
        [string] $HostUser = '',

        [ValidateSet('', 'clipboard', 'keyVault', 'portalReset', 'unknown')]
        [string] $SignInWay = '',

        [AllowEmptyString()]
        [string] $SignInText = '',

        [AllowEmptyString()]
        [string] $PagePath = '',

        [switch] $NoBrowser
    )

    $left = [int][System.Math]::Max(0, ($DeadlineUtc - [System.DateTime]::UtcNow).TotalMinutes)
    $until = $DeadlineUtc.ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    Write-DemoConsoleBlock -Color 'Yellow' -Line @('') 
    Write-DemoConsoleBlock -Color 'Yellow' -Line (Get-DemoBannerLine -Title 'WAITING FOR YOU: one step, about 10 minutes')
    Write-DemoConsoleBlock -Color 'Yellow' -Line @(
        ('Time limit: {0} minutes, until {1} (local time). After that, deploy.ps1 stops; run ./scripts/deploy.ps1 again and it waits for this step again.' -f $left, $until)
        ('Portal: {0}' -f $Url)
    )
    Write-DemoConsoleBlock -Color 'White' -Line (Get-DemoGuidedStopInstruction -HostVm $HostVm -HostUser $HostUser -SignInWay $SignInWay -SignInText $SignInText)
    $opened = $false
    if (-not $NoBrowser -and [string]$env:CODESPACES -ne 'true' -and $Url -match '^https://portal\.azure\.com/') {
        try {
            if ($IsWindows) {
                Start-Process -FilePath $Url
                $opened = $true
            }
            elseif ($IsMacOS) {
                Start-Process -FilePath 'open' -ArgumentList $Url
                $opened = $true
            }
            elseif (Get-Command -Name 'xdg-open' -ErrorAction SilentlyContinue) {
                Start-Process -FilePath 'xdg-open' -ArgumentList $Url
                $opened = $true
            }
        }
        catch {
            $opened = $false
        }
    }
    Write-DemoConsoleBlock -Color 'Gray' -Line @($(if ($opened) { 'The browser opened archost01''s page in the Azure portal.' } else { 'Open the portal link above in your browser.' }))
    Invoke-DemoAttention
    Write-DemoConsoleBlock -Color 'Yellow' -Line @((Get-DemoHumanActionLine -PagePath $PagePath -DeadlineUtc $DeadlineUtc -HostVm $HostVm))
}

function Show-DemoGuidedStopReminder {
    # A short reminder while the guided stop waits (every few minutes; brief item 4), with the handoff line again.
    # Internal.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime] $DeadlineUtc,

        [AllowEmptyString()]
        [string] $PagePath = '',

        [AllowEmptyString()]
        [string] $Status = '',

        [string] $HostVm = 'archost01'
    )

    $left = [int][System.Math]::Max(0, ($DeadlineUtc - [System.DateTime]::UtcNow).TotalMinutes)
    $now = if ($Status) { ' Now: {0}' -f $Status } else { '' }
    Write-DemoConsoleBlock -Color 'Yellow' -Line @(('Reminder: the guided stop still waits for you ({0} minutes left, until {1}).{2}' -f $left, $DeadlineUtc.ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture), $now))
    Invoke-DemoAttention
    Write-DemoConsoleBlock -Color 'Yellow' -Line @((Get-DemoHumanActionLine -PagePath $PagePath -DeadlineUtc $DeadlineUtc -HostVm $HostVm))
}

function Complete-DemoGuidedStop {
    <#
    .SYNOPSIS
    The guided stop's cleanup on deploy.ps1's side, run whatever happened: clears the host's request (the host then
    turns the guest's one-time sign-in off), removes Bastion, rotates the host password when one was handed over (a
    Warning when it can't be: stop-demo.ps1 rotates it later), disables the Key Vault copy with the opt-in, and clears
    the state's request time. Returns the results. Internal.
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
    if ([string]$bastion.status -notin 'Pass', 'Not selected') {
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
    try {
        Set-DemoDeploymentStateLocked -Config $Config -Value @{ GuidedStopUtc = '' } -Confirm:$false
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The guided stop''s end wasn''t recorded: {0}' -f $_.Exception.Message)
    }
    return $results.ToArray()
}

function Get-DemoGuidedSignInStatus {
    <#
    .SYNOPSIS
    STATUS.T2.AUTOSIGNIN (Phase 28, brief item 12): what archost01's health says about the guest's one-time automatic
    sign-in, from its summary (guidedArmed, guidedRequest, guidedLeft) or its full health (details.guidedSetup). Pass
    while it's armed for a guided stop that's waiting; a Warning when it's armed with no guided stop waiting, or when the
    last cleanup didn't finish: archost01's next pass (every 5 minutes while it runs) removes the leftovers, and
    check-sign-in-data.ps1 -Clean does too. $null when nothing is armed or left. Read-only. Pure. Internal.
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
        return (New-DemoResult -CheckId 'STATUS.T2.AUTOSIGNIN' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'arcsql01 signs itself in once for the guided stop, which is waiting for you; automatic sign-in goes off again after setup, and its LSA secret is deleted.' -Evidence $evidence -DocUrl $docUrl)
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
    # The current UTC time. The guided stop's deadlines and the chunk sender's stall check read it here, so tests can move
    # time on. Internal.
    [CmdletBinding()]
    [OutputType([datetime])]
    param()

    return [System.DateTime]::UtcNow
}
function Invoke-DemoT2GuidedStop {
    <#
    .SYNOPSIS
    The PaygWizard guided stop in deploy.ps1's T2 track (Phase 28). Returns Status (Done, NotNeeded, TimedOut, or
    Failed) and Results. Internal.

    .DESCRIPTION
    1. Nothing to do when the host is past setup already (NotNeeded).
    2. The host's request (Set-DemoGuidedStopRequest), valid until the deadline: at least -PersonMinutes after the prompt.
    3. On-demand Bastion, deployed in the background (New-DemoBastion -NoWait).
    4. Arc onboarding when the host waits for it, without the SQL Server configuration, which waits for the setup check.
    5. Waits for the host to open the pre-filled setup in the guest (SqlSetupWizard), and for Bastion.
    6. The prompt: the status page's guidedStop turns Ready; deploy.ps1's own process prompts the person (Context
       PromptInParent, set only when the progress model exists), or this process does (in-process runs, and track
       processes without a model, such as -NoStatusPage: its console lines reach deploy.ps1's console).
    7. Waits for the host's setup check, relaying its message (a wrong install's documented fix), until it passes, the
       deadline passes (TimedOut), or the host fails.
    8. Always: Complete-DemoGuidedStop.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [System.Collections.IDictionary] $Context = @{},

        [AllowNull()]
        [object] $Health,

        [Parameter(Mandatory)]
        [datetime] $DeadlineUtc,

        [ValidateRange(10, 240)]
        [int] $PersonMinutes = 45,

        [ValidateRange(10, 600)]
        [int] $PollSeconds = 120
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $progress = if ($Context.Contains('ProgressPath')) { [string]$Context['ProgressPath'] } else { '' }
    $inParent = $Context.Contains('PromptInParent') -and [bool]$Context['PromptInParent']
    $docUrl = 'https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-using-a-configuration-file'
    $phase = Get-DemoT2HostPhase -Health $Health
    if ($phase.Phase -in 'AfterSetup', 'Ready') {
        Set-DemoProgressStep -Path $progress -Id 'T2.GuidedStop', 'T2.SetupCheck' -State 'Done' -Message 'Not needed: SQL Server is already set up in arcsql01.'
        Set-DemoProgressValue -Path $progress -Section 'guidedStop' -Value @{ state = 'NotSelected'; message = 'SQL Server is already set up in arcsql01.' }
        $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDSTOP' -Area 'infra' -Target 'T2' -Status 'Not selected' -Message 'SQL Server is already set up in arcsql01, so no step needs you.' -DocUrl $docUrl))
        return [pscustomobject]@{ Status = 'NotNeeded'; Results = $results.ToArray() }
    }
    if ($phase.Phase -eq 'Failed') {
        $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDSTOP' -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('archost01 reports Failed at step {0}, so the guided stop didn''t start.' -f $phase.Step) -Remediation 'Read archost01''s health (Get-DemoVmHealth -VmName archost01 -View Full), fix the cause, then run ./scripts/deploy.ps1 again.'))
        return [pscustomobject]@{ Status = 'Failed'; Results = $results.ToArray() }
    }
    $now = (Get-DemoUtcNow)
    $deadline = if ($DeadlineUtc -gt $now.AddMinutes($PersonMinutes + 20)) { $DeadlineUtc } else { $now.AddMinutes($PersonMinutes + 20) }
    $status = 'TimedOut'
    $started = [System.Diagnostics.Stopwatch]::StartNew()
    Set-DemoProgressStep -Path $progress -Id 'T2.GuidedStop' -State 'Running' -Message 'Preparing: Bastion, Arc onboarding, the pre-filled setup, and the guest''s one-time sign-in (about 10 to 15 minutes).'
    Set-DemoProgressValue -Path $progress -Section 'guidedStop' -Value @{ state = 'Preparing'; message = 'Preparing Bastion and the pre-filled setup (about 10 to 15 minutes); nothing to do yet.'; deadlineAt = (Get-DemoUnixTime -Value $deadline); hostVm = 'archost01' }
    try {
        :guided do {
            $request = Set-DemoGuidedStopRequest -Config $Config -Action Set -RequestId ([guid]::NewGuid().ToString()) -ExpiresUtc $deadline.AddMinutes(5) -Confirm:$false
            $results.Add($request)
            if ($request.status -ne 'Pass') {
                $status = 'Failed'
                break guided
            }
            try {
                Set-DemoDeploymentStateLocked -Config $Config -Value @{ GuidedStopUtc = $deadline.AddMinutes(5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } -Confirm:$false
            }
            catch {
                Write-DemoLog -Level Warning -Message ('The guided stop''s time limit wasn''t recorded: {0}' -f $_.Exception.Message)
            }
            $bastion = New-DemoBastion -Config $Config -NoWait -Confirm:$false
            $results.Add($bastion)
            if ($bastion.status -eq 'Fail') {
                $status = 'Failed'
                break guided
            }
            $state = [string](Get-DemoMemberValue -InputObject $Health -Name 'state')
            if ($state -eq 'WaitingForArcOnboarding') {
                Set-DemoProgressStep -Path $progress -Id 'T2.ArcOnboarding' -State 'Running' -Message 'Onboarding arcsql01 to Azure Arc before setup.'
                $arc = @(Invoke-DemoArcConfiguration -Config $Config -SkipConfiguration -Confirm:$false)
                $results.AddRange([object[]]$arc)
                if (@($arc | Where-Object { [string]$_.status -eq 'Fail' }).Count -gt 0) {
                    Set-DemoProgressStep -Path $progress -Id 'T2.ArcOnboarding' -State 'Failed' -Message 'Arc onboarding failed; see the results.'
                    $status = 'Failed'
                    break guided
                }
                Set-DemoProgressStep -Path $progress -Id 'T2.ArcOnboarding' -State 'Done' -Message 'arcsql01 is connected to Azure Arc.'
            }
            # The host opens the pre-filled setup once Arc is connected and the request is there.
            $ready = $false
            $health = $Health
            while (-not $ready) {
                try {
                    $read = Get-DemoVmHealth -Config $Config -VmName 'archost01' -View Summary
                    if ($null -ne $read) {
                        $health = $read
                    }
                }
                catch {
                    Write-DemoLog -Level Warning -Message ('Reading archost01''s health failed; reading it again: {0}' -f $_.Exception.Message)
                }
                $phase = Get-DemoT2HostPhase -Health $health
                if ($phase.Phase -in 'AfterSetup', 'Ready') {
                    $status = 'Done'
                    break guided
                }
                if ($phase.Phase -eq 'Failed') {
                    $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDSTOP' -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('archost01 failed while it prepared the guided stop (step {0}): {1}' -f $phase.Step, [string](Get-DemoMemberValue -InputObject $health -Name 'message')) -Remediation 'Read archost01''s health (Get-DemoVmHealth -VmName archost01 -View Full), fix the cause, then run ./scripts/deploy.ps1 again.'))
                    $status = 'Failed'
                    break guided
                }
                $ready = $phase.Step -eq 'SqlSetupWizard' -and $phase.State -eq 'ManualActionRequired'
                if (-not $ready) {
                    if ((Get-DemoUtcNow) -ge $deadline) {
                        break guided
                    }
                    Set-DemoProgressValue -Path $progress -Section 'guidedStop' -Value @{ message = ('archost01 prepares the pre-filled setup (step {0}); nothing to do yet.' -f $phase.Step) }
                    Start-Sleep -Seconds 60
                }
            }
            $bastionReady = Wait-DemoBastionDeployment -Config $Config -TimeoutMinutes 20
            if (-not $bastionReady.Succeeded) {
                $results.Add((New-DemoResult -CheckId 'START.BASTION' -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('On-demand Bastion didn''t deploy ({0}), so nobody can sign in to archost01.' -f $bastionReady.State) -Remediation 'Check the AzureBastionSubnet and the public IP quota (PREFLIGHT.P3.PUBLICIP), then run ./scripts/deploy.ps1 again.' -DocUrl 'https://learn.microsoft.com/azure/bastion/configuration-settings'))
                $status = 'Failed'
                break guided
            }
            # The person's window starts now: at least PersonMinutes.
            if ($deadline -lt (Get-DemoUtcNow).AddMinutes($PersonMinutes)) {
                $deadline = (Get-DemoUtcNow).AddMinutes($PersonMinutes)
                $null = Set-DemoGuidedStopRequest -Config $Config -Action Set -RequestId ([guid]::NewGuid().ToString()) -ExpiresUtc $deadline.AddMinutes(5) -Confirm:$false
            }
            $url = Get-DemoPortalVmUrl -Config $Config -VmName 'archost01'
            $hostMessage = [string](Get-DemoMemberValue -InputObject $health -Name 'message')
            Set-DemoProgressValue -Path $progress -Section 'guidedStop' -Value @{ state = 'Ready'; url = $url; deadlineAt = (Get-DemoUnixTime -Value $deadline); promptedAt = (Get-DemoUnixTime); message = $hostMessage }
            Set-DemoProgressStep -Path $progress -Id 'T2.GuidedStop' -State 'Action needed' -Message 'Waiting for you: sign in through Bastion and finish SQL Server setup (see the banner).'
            Write-DemoLog -Message 'T2: the guided stop is ready: Bastion is up, and arcsql01 has opened the pre-filled SQL Server setup.'
            $nextReminder = (Get-DemoUtcNow).AddMinutes(5)
            if (-not $inParent) {
                $credential = Invoke-DemoGuidedStopCredential -Config $Config -ExpiresUtc $deadline
                $results.AddRange([object[]]@($credential.Results))
                Set-DemoProgressValue -Path $progress -Section 'guidedStop' -Value @{ credential = $credential.Mode; credentialText = $credential.Text; hostUser = $credential.UserName }
                Show-DemoGuidedStopPrompt -Url $url -DeadlineUtc $deadline -HostUser $credential.UserName -SignInWay $credential.Mode -SignInText $credential.Text -PagePath ([string]$Context['PagePath'])
            }
            while ($true) {
                Start-Sleep -Seconds $PollSeconds
                try {
                    $read = Get-DemoVmHealth -Config $Config -VmName 'archost01' -View Summary
                    if ($null -ne $read) {
                        $health = $read
                    }
                }
                catch {
                    Write-DemoLog -Level Warning -Message ('Reading archost01''s health failed; reading it again: {0}' -f $_.Exception.Message)
                }
                $phase = Get-DemoT2HostPhase -Health $health
                if ($phase.Phase -in 'AfterSetup', 'Ready') {
                    $status = 'Done'
                    break guided
                }
                if ($phase.Phase -eq 'Failed') {
                    $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDSTOP' -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('archost01 failed during the guided stop (step {0}): {1}' -f $phase.Step, [string](Get-DemoMemberValue -InputObject $health -Name 'message')) -Remediation 'Read archost01''s health (Get-DemoVmHealth -VmName archost01 -View Full), fix the cause, then run ./scripts/deploy.ps1 again.'))
                    $status = 'Failed'
                    break guided
                }
                $hostMessage = [string](Get-DemoMemberValue -InputObject $health -Name 'message')
                Set-DemoProgressValue -Path $progress -Section 'guidedStop' -Value @{ message = $hostMessage }
                if ($hostMessage -match 'Fix:') {
                    Set-DemoProgressStep -Path $progress -Id 'T2.SetupCheck' -State 'Action needed' -Message $hostMessage
                    Write-DemoLog -Level Warning -Message ('T2: the setup check found a problem: {0}' -f $hostMessage)
                }
                if ((Get-DemoUtcNow) -ge $deadline) {
                    break guided
                }
                if (-not $inParent -and (Get-DemoUtcNow) -ge $nextReminder) {
                    Show-DemoGuidedStopReminder -DeadlineUtc $deadline -PagePath ([string]$Context['PagePath']) -Status $hostMessage
                    $nextReminder = (Get-DemoUtcNow).AddMinutes(5)
                }
            }
        } while ($false)
    }
    finally {
        $minutes = [int]$started.Elapsed.TotalMinutes
        $results.AddRange([object[]]@(Complete-DemoGuidedStop -Config $Config -Confirm:$false))
        switch ($status) {
            'Done' {
                Set-DemoProgressStep -Path $progress -Id 'T2.GuidedStop' -State 'Done' -Status 'Pass' -Message ('Done in {0} minutes.' -f $minutes)
                Set-DemoProgressStep -Path $progress -Id 'T2.SetupCheck' -State 'Done' -Status 'Pass' -Message 'Standard, the default instance MSSQLSERVER, and the Azure extension.'
                Set-DemoProgressValue -Path $progress -Section 'guidedStop' -Value @{ state = 'Done'; message = 'SQL Server setup is done; deploy.ps1 finishes T2 on its own.' }
                $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDSTOP' -Area 'infra' -Target 'T2' -Status 'Pass' -Message ('SQL Server Standard is set up in arcsql01 as the default instance with the Azure extension (the host''s check passed), {0} minutes after the guided stop began; Bastion is removed and the host password rotated.' -f $minutes) -DocUrl $docUrl))
            }
            'Failed' {
                Set-DemoProgressStep -Path $progress -Id 'T2.GuidedStop' -State 'Failed' -Status 'Fail' -Message 'The guided stop couldn''t go on; see the results.'
                Set-DemoProgressValue -Path $progress -Section 'guidedStop' -Value @{ state = 'Failed'; message = 'The guided stop stopped; see the console.' }
            }
            default {
                $until = $deadline.ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
                Set-DemoProgressStep -Path $progress -Id 'T2.GuidedStop' -State 'Action needed' -Status 'Manual action required' -Message ('Nobody finished SQL Server setup by {0}.' -f $until)
                Set-DemoProgressValue -Path $progress -Section 'guidedStop' -Value @{ state = 'TimedOut'; message = ('The time limit ({0}) passed.' -f $until) }
                $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDSTOP' -Area 'infra' -Target 'T2' -Status 'Manual action required' -Message ('Nobody finished SQL Server setup in arcsql01 by the time limit ({0}). The guest''s one-time sign-in was turned off, Bastion was removed, and the host password rotated.' -f $until) -Remediation 'Run ./scripts/deploy.ps1 again when you have about 15 minutes: it opens Bastion, guides you through the pre-filled setup again, and continues.' -DocUrl $docUrl))
            }
        }
    }
    return [pscustomobject]@{ Status = $status; Results = $results.ToArray() }
}
