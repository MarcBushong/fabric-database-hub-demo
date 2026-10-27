<#
.SYNOPSIS
Workload control on a demo VM, run through action Run Command by the DbHubDemo module (ADR 0010, ADR 0011).

.DESCRIPTION
The module's inline Run Command script finds this file through settings.json (bundlePath) and calls it with
an action and a Base64-encoded JSON request. It prints exactly one result line, 'DBHUBDEMO-WORKLOAD <json>',
with the action, an ADR 0012 status, a message, and evidence. The action Run Command returns only the last
4,096 bytes of output, so the line is kept under about 3,500 characters. Nothing here is secret: T1 and T2
use Windows authentication, T3 the VM's managed identity, and the guest password stays DPAPI-protected on
the host. Windows PowerShell 5.1.

Actions:
- EnableT3 (sqlvm01) { serverFqdn }: runs the runner's setup on T3 with T1's managed identity (after
  Add-DemoT1ToT3AdminGroup and Invoke-DemoT3SqlFromT1 -Name Setup), records t3-workload.json, sets T3's
  activity profile until the next auto-shutdown, and restarts DbHubDemo-Workload so its host adds T3.
- EnableT4 (sqlvm01) { serverFqdn, adminRole, runnerRole, runnerObjectId, seedScale }: T4 (Phase 24, ADR
  0019). T1's managed identity signs in to the PostgreSQL flexible server as adminRole, the P6 group's
  display name (it's a member, Add-DemoT1ToT3AdminGroup), creates runnerRole for runnerObjectId (its own
  object ID), applies and seeds the schema, records t4-workload.json, sets T4's activity profile, and
  restarts DbHubDemo-Workload so its host adds T4.
- Runner (sqlvm01 for T1, T3, and T4; archost01 relays T2 into the guest over PowerShell Direct)
  { target, arguments[], timeoutSeconds }: runs one runner command. The token {{NEXT_SHUTDOWN}} in an
  argument becomes the next auto-shutdown time, T3 commands get the server's FQDN, and T4 commands the
  flexible server's FQDN and the runner's role.
- StopGuest (archost01) { timeoutMinutes }: shuts the guest down cleanly (Stop-VM) and waits until it's
  off, so the host can be deallocated.

.PARAMETER Action
EnableT3, EnableT4, Runner, or StopGuest.

.PARAMETER RequestBase64
The request as Base64-encoded UTF-8 JSON.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.
#>
[CmdletBinding()]
param(
    [string] $Action = '',
    [string] $RequestBase64 = '',
    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ControlBundleRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$script:ControlMarker = 'DBHUBDEMO-WORKLOAD'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Vm.psd1') -Force

function Write-DemoControlLine {
    # The one line the module parses; a separate function so tests can capture it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    [Console]::Out.WriteLine($Line)
}

function Write-DemoControlResult {
    # Prints the one result line. Long text is cut from the front, so the end of an error survives.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ActionName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')]
        [string] $Status,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Message,

        [System.Collections.IDictionary] $Evidence = @{}
    )

    $safeMessage = Protect-DemoVmText -Text $Message
    if ($safeMessage.Length -gt 800) {
        $safeMessage = '...' + $safeMessage.Substring($safeMessage.Length - 800)
    }
    $result = [ordered]@{
        marker   = $script:ControlMarker
        action   = $ActionName
        status   = $Status
        message  = $safeMessage
        evidence = $Evidence
    }
    $json = Protect-DemoVmText -Text (ConvertTo-Json -InputObject $result -Depth 6 -Compress)
    Write-DemoControlLine -Line ($script:ControlMarker + ' ' + $json)
}

function Get-DemoControlRequest {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{}
    }
    $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value.Trim()))
    $request = ConvertTo-DemoVmHashtable -InputObject ($text | ConvertFrom-Json)
    if ($null -eq $request) {
        return @{}
    }
    return $request
}

function Get-DemoControlTail {
    # The last Length characters of a text, for output that must fit in the Run Command's 4 KB.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [int] $Length = 1500
    )

    $value = ([string]$Text).Trim()
    if ($value.Length -gt $Length) {
        return ('...' + $value.Substring($value.Length - $Length))
    }
    return $value
}

function Get-DemoControlArgument {
    <#
    .SYNOPSIS
    Validates the runner arguments from a request and replaces {{NEXT_SHUTDOWN}} with the next auto-shutdown.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [string] $NextShutdown
    )

    $arguments = @()
    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            continue
        }
        $text = [string]$item
        if ($text.Length -gt 512 -or $text -match '[\r\n\x00]') {
            throw 'A runner argument is too long or holds a line break.'
        }
        $arguments += $text.Replace('{{NEXT_SHUTDOWN}}', $NextShutdown)
    }
    if ($arguments.Count -eq 0) {
        throw 'The request has no runner arguments.'
    }
    if ($arguments -contains '--target' -or $arguments -contains '-t') {
        throw 'The request must not set --target; the target is a separate field.'
    }
    return , $arguments
}

function Invoke-DemoControlEnableT3 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Request
    )

    $fqdn = ([string]$Request['serverFqdn']).ToLowerInvariant()
    if ($fqdn -notmatch '^[a-z0-9][a-z0-9.-]{1,252}$') {
        Write-DemoControlResult -ActionName 'EnableT3' -Status 'Fail' -Message 'The request has no valid serverFqdn.'
        return
    }
    $paths = Get-DemoVmWorkloadPath -Root $StateRoot
    $install = Read-DemoVmJsonFile -Path $paths.InstallRecord
    if ($null -eq $install -or -not (Test-Path -LiteralPath ([string]$install['dotnetExe']) -PathType Leaf) -or -not (Test-Path -LiteralPath ([string]$install['runnerDll']) -PathType Leaf)) {
        Write-DemoControlResult -ActionName 'EnableT3' -Status 'Fail' -Message 'The workload runner is not installed on T1 yet. Wait for the WorkloadRunner step in health.json (Wait-DemoBootstrapLoader, then the bootstrap task), then run this again.'
        return
    }
    $dotnet = [string]$install['dotnetExe']
    $runner = [string]$install['runnerDll']
    $setup = Invoke-DemoVmRunnerSetup -DotNetExe $dotnet -RunnerDll $runner -Target 'T3' -Server $fqdn
    $evidence = [ordered]@{ serverFqdn = $fqdn; setup = $setup.Status; setupExitCode = $setup.ExitCode }
    if ($setup.Status -notin @('Pass', 'Warning')) {
        Write-DemoControlResult -ActionName 'EnableT3' -Status $setup.Status -Message $setup.Message -Evidence $evidence
        return
    }

    $now = Get-DemoVmUtcNow
    Write-DemoVmJsonFile -Path $paths.T3Marker -InputObject ([ordered]@{ schemaVersion = 1; serverFqdn = $fqdn; enabledUtc = $now; setup = $setup.Status }) -Redact
    $setupRecord = $install['setup']
    if ($null -eq $setupRecord) {
        $setupRecord = [ordered]@{}
    }
    $setupRecord['T3'] = [ordered]@{ status = $setup.Status; utc = $now; message = $setup.Message }
    $install['setup'] = $setupRecord
    Write-DemoVmWorkloadInstall -Root $StateRoot -Record $install

    $status = $setup.Status
    $messages = @($setup.Message)
    $shutdown = Get-DemoVmNextShutdown -Time ([string]$install['autoShutdownTime']) -TimeZoneId ([string]$install['autoShutdownTimeZone'])
    $evidence['notAfter'] = $shutdown.Iso
    if ($shutdown.MinutesLeft -ge 10) {
        $activityProfile = [string]$install['activityProfile']
        $set = Set-DemoVmActivityProfile -DotNetExe $dotnet -RunnerDll $runner -Target 'T3' -Server $fqdn -Name $activityProfile -NotAfter $shutdown.Iso -RequestedBy 'Enable-DemoT3Workload' -Confirm:$false
        $evidence['profile'] = $activityProfile
        $evidence['profileSet'] = $set.Status
        $messages += $set.Message
        if ($set.Status -ne 'Pass' -and $status -eq 'Pass') {
            $status = 'Warning'
        }
    }
    else {
        $evidence['profileSet'] = 'Not selected'
        $messages += ('The next auto-shutdown is {0:N0} minutes away, so no T3 activity was started.' -f $shutdown.MinutesLeft)
    }
    Stop-DemoVmWorkload -Root $StateRoot -Confirm:$false
    Start-DemoVmWorkload -Confirm:$false
    $messages += 'DbHubDemo-Workload was restarted and now hosts T1 and T3.'
    Write-DemoControlResult -ActionName 'EnableT3' -Status $status -Message ($messages -join ' ') -Evidence $evidence
}

function Invoke-DemoControlEnableT4 {
    # T4 (Phase 24, ADR 0019): T1's identity signs in as the P6 group's role (adminRole), creates the runner's
    # role for its own object ID, applies and seeds the schema, records t4-workload.json, sets T4's profile,
    # and restarts DbHubDemo-Workload so its host adds T4. No token or password is in the request.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Request
    )

    $fqdn = ([string]$Request['serverFqdn']).ToLowerInvariant()
    $adminRole = [string]$Request['adminRole']
    $runnerRole = [string]$Request['runnerRole']
    $objectId = [string]$Request['runnerObjectId']
    $seedScale = 1
    if ($Request.Contains('seedScale') -and [int]$Request['seedScale'] -ge 1) {
        $seedScale = [System.Math]::Min(50, [int]$Request['seedScale'])
    }
    $problem = ''
    if ($fqdn -notmatch '^[a-z0-9][a-z0-9.-]{1,252}$') {
        $problem = 'The request has no valid serverFqdn.'
    }
    elseif ($adminRole -notmatch '^[A-Za-z0-9_().-][A-Za-z0-9 _().-]{0,61}[A-Za-z0-9_().-]$') {
        $problem = 'The request has no valid adminRole (the P6 group''s display name).'
    }
    elseif ($runnerRole -notmatch '^[a-z_][a-z0-9_]{0,62}$') {
        $problem = 'The request has no valid runnerRole.'
    }
    elseif ($objectId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $problem = 'The request has no valid runnerObjectId (T1''s managed identity object ID).'
    }
    if ($problem) {
        Write-DemoControlResult -ActionName 'EnableT4' -Status 'Fail' -Message $problem
        return
    }
    $paths = Get-DemoVmWorkloadPath -Root $StateRoot
    $install = Read-DemoVmJsonFile -Path $paths.InstallRecord
    if ($null -eq $install -or -not (Test-Path -LiteralPath ([string]$install['dotnetExe']) -PathType Leaf) -or -not (Test-Path -LiteralPath ([string]$install['runnerDll']) -PathType Leaf)) {
        Write-DemoControlResult -ActionName 'EnableT4' -Status 'Fail' -Message 'The workload runner is not installed on T1 yet. Wait for the WorkloadRunner step in health.json (Wait-DemoBootstrapLoader, then the bootstrap task), then run this again.'
        return
    }
    if (-not (Test-DemoVmNameResolve -HostName $fqdn)) {
        Write-DemoControlResult -ActionName 'EnableT4' -Status 'Fail' -Message ('{0} does not resolve on T1: the private DNS zone that T4''s virtual network integration links to the network has no record for it yet.' -f $fqdn) -Evidence @{ serverFqdn = $fqdn }
        return
    }
    $dotnet = [string]$install['dotnetExe']
    $runner = [string]$install['runnerDll']
    $setup = Invoke-DemoVmRunnerSetup -DotNetExe $dotnet -RunnerDll $runner -Target 'T4' -Server $fqdn -User $adminRole -IncludeBaseSchema -SeedScale $seedScale -GrantEntraObjectId $objectId -RunnerRole $runnerRole
    $evidence = [ordered]@{ serverFqdn = $fqdn; runnerRole = $runnerRole; seedScale = $seedScale; setup = $setup.Status; setupExitCode = $setup.ExitCode }
    if ($setup.Status -notin @('Pass', 'Warning')) {
        Write-DemoControlResult -ActionName 'EnableT4' -Status $setup.Status -Message $setup.Message -Evidence $evidence
        return
    }

    $now = Get-DemoVmUtcNow
    Write-DemoVmJsonFile -Path $paths.T4Marker -InputObject ([ordered]@{ schemaVersion = 1; serverFqdn = $fqdn; adminRole = $adminRole; runnerRole = $runnerRole; enabledUtc = $now; setup = $setup.Status }) -Redact
    $setupRecord = $install['setup']
    if ($null -eq $setupRecord) {
        $setupRecord = [ordered]@{}
    }
    $setupRecord['T4'] = [ordered]@{ status = $setup.Status; utc = $now; message = $setup.Message }
    $install['setup'] = $setupRecord
    Write-DemoVmWorkloadInstall -Root $StateRoot -Record $install

    $status = $setup.Status
    $messages = @($setup.Message)
    $shutdown = Get-DemoVmNextShutdown -Time ([string]$install['autoShutdownTime']) -TimeZoneId ([string]$install['autoShutdownTimeZone'])
    $evidence['notAfter'] = $shutdown.Iso
    if ($shutdown.MinutesLeft -ge 10) {
        $activityProfile = [string]$install['activityProfile']
        $set = Set-DemoVmActivityProfile -DotNetExe $dotnet -RunnerDll $runner -Target 'T4' -Server $fqdn -Name $activityProfile -NotAfter $shutdown.Iso -RequestedBy 'Enable-DemoT4Workload' -Confirm:$false
        $evidence['profile'] = $activityProfile
        $evidence['profileSet'] = $set.Status
        $messages += $set.Message
        if ($set.Status -ne 'Pass' -and $status -eq 'Pass') {
            $status = 'Warning'
        }
    }
    else {
        $evidence['profileSet'] = 'Not selected'
        $messages += ('The next auto-shutdown is {0:N0} minutes away, so no T4 activity was started.' -f $shutdown.MinutesLeft)
    }
    Stop-DemoVmWorkload -Root $StateRoot -Confirm:$false
    Start-DemoVmWorkload -Confirm:$false
    $messages += 'DbHubDemo-Workload was restarted and now also hosts T4.'
    Write-DemoControlResult -ActionName 'EnableT4' -Status $status -Message ($messages -join ' ') -Evidence $evidence
}

function Invoke-DemoControlRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Request,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Settings
    )

    $target = [string]$Request['target']
    $timeout = 1800
    if ($Request.Contains('timeoutSeconds') -and [int]$Request['timeoutSeconds'] -ge 30) {
        $timeout = [System.Math]::Min(5400, [int]$Request['timeoutSeconds'])
    }
    $workload = Get-DemoVmWorkloadSetting -Settings $Settings
    $shutdown = Get-DemoVmNextShutdown -Time $workload.AutoShutdownTime -TimeZoneId $workload.AutoShutdownTimeZone
    $arguments = Get-DemoControlArgument -Value $Request['arguments'] -NextShutdown $shutdown.Iso
    $role = [string]$Settings['role']
    $label = 'runner ' + (@($arguments | Select-Object -First 2) -join ' ') + ' --target ' + $target

    if ($role -eq 'SqlVm' -and $target -in @('T1', 'T3', 'T4')) {
        $install = Read-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $StateRoot).InstallRecord
        if ($null -eq $install) {
            Write-DemoControlResult -ActionName 'Runner' -Status 'Fail' -Message 'The workload runner is not installed on T1 yet.'
            return
        }
        $full = @($arguments) + @('--target', $target)
        if ($target -eq 'T3' -and $full -notcontains '--server') {
            $t3 = $install['t3']
            if ($null -eq $t3 -or -not $t3['serverFqdn']) {
                Write-DemoControlResult -ActionName 'Runner' -Status 'Fail' -Message 'T1 has no T3 server in its workload settings.'
                return
            }
            $full += @('--server', [string]$t3['serverFqdn'])
        }
        if ($target -eq 'T4') {
            $t4 = $null
            if ($install.Contains('t4')) {
                $t4 = $install['t4']
            }
            if ($null -eq $t4 -or -not $t4['serverFqdn']) {
                Write-DemoControlResult -ActionName 'Runner' -Status 'Fail' -Message 'T1 has no T4 server in its workload settings: T4 is off (t4Enabled), or T1 was bootstrapped before T4 existed (deploy.ps1 -Resume updates it).'
                return
            }
            if ($full -notcontains '--server') {
                $full += @('--server', [string]$t4['serverFqdn'])
            }
            if ($full -notcontains '--user' -and $t4['runnerRole']) {
                $full += @('--user', [string]$t4['runnerRole'])
            }
        }
        $run = Invoke-DemoVmRunnerProcess -DotNetExe ([string]$install['dotnetExe']) -RunnerDll ([string]$install['runnerDll']) -ArgumentList $full -TimeoutSeconds $timeout
    }
    elseif ($role -eq 'ArcHost' -and $target -eq 'T2') {
        $guest = Import-PowerShellDataFile -Path ([System.IO.Path]::Combine($script:ControlBundleRoot, 'vm', 'dsc', 'guest.psd1'))
        $guestName = [string]$guest.Name
        if ($Settings.Contains('guest') -and $null -ne $Settings['guest'] -and $Settings['guest']['name']) {
            $guestName = [string]$Settings['guest']['name']
        }
        . ([System.IO.Path]::Combine($script:ControlBundleRoot, 'vm', 'hyperv-guest', 'GuestVm.ps1'))
        $credential = Get-DemoGuestCredential -SecretPath ([System.IO.Path]::Combine($StateRoot, 'protected', 'guest-administrator.bin')) -UserName $guest.AdministratorName
        $full = @($arguments) + @('--target', 'T2')
        $run = Invoke-Command -VMName $guestName -Credential $credential -ArgumentList $guest.ToolsFolder, $full, $timeout -ErrorAction Stop -ScriptBlock {
            param($Folder, $Arguments, $TimeoutSeconds)
            Import-Module -Name (Join-Path -Path $Folder -ChildPath 'module\DbHubDemo.Vm.psd1') -Force
            $install = Read-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $Folder).InstallRecord
            if ($null -eq $install) {
                throw 'The workload runner is not installed in the guest yet.'
            }
            Invoke-DemoVmRunnerProcess -DotNetExe ([string]$install['dotnetExe']) -RunnerDll ([string]$install['runnerDll']) -ArgumentList $Arguments -TimeoutSeconds $TimeoutSeconds
        }
    }
    else {
        Write-DemoControlResult -ActionName 'Runner' -Status 'Fail' -Message ('Target {0} is not driven from this VM (role {1}): T1, T3, and T4 run on sqlvm01, T2 through archost01.' -f $target, $role)
        return
    }

    $outcome = Get-DemoVmRunnerOutcome -Run $run -Label $label
    $evidence = [ordered]@{
        target   = $target
        exitCode = [int]$run.ExitCode
        stdout   = Get-DemoControlTail -Text $run.StdOut -Length 1800
        stderr   = Get-DemoControlTail -Text $run.StdErr -Length 500
    }
    Write-DemoControlResult -ActionName 'Runner' -Status $outcome.Status -Message $outcome.Message -Evidence $evidence
}

function Invoke-DemoControlStopGuest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Request,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Settings
    )

    $guest = Import-PowerShellDataFile -Path ([System.IO.Path]::Combine($script:ControlBundleRoot, 'vm', 'dsc', 'guest.psd1'))
    $guestName = [string]$guest.Name
    if ($Settings.Contains('guest') -and $null -ne $Settings['guest'] -and $Settings['guest']['name']) {
        $guestName = [string]$Settings['guest']['name']
    }
    $minutes = 10
    if ($Request.Contains('timeoutMinutes') -and [int]$Request['timeoutMinutes'] -ge 1) {
        $minutes = [System.Math]::Min(30, [int]$Request['timeoutMinutes'])
    }
    $vm = Get-VM -Name $guestName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-DemoControlResult -ActionName 'StopGuest' -Status 'Pass' -Message ('There is no guest {0} on this host.' -f $guestName) -Evidence @{ guest = $guestName; state = 'NotCreated' }
        return
    }
    if ([string]$vm.State -eq 'Off') {
        Write-DemoControlResult -ActionName 'StopGuest' -Status 'Pass' -Message ('{0} is already off.' -f $guestName) -Evidence @{ guest = $guestName; state = 'Off' }
        return
    }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    # A guest operating system shutdown through the Hyper-V shutdown integration service; -Force only skips
    # the prompt that a signed-in session would otherwise raise.
    Stop-VM -Name $guestName -Force -AsJob | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes($minutes)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ([string](Get-VM -Name $guestName).State -eq 'Off') {
            Write-DemoControlResult -ActionName 'StopGuest' -Status 'Pass' -Message ('{0} shut down cleanly in {1:N0} seconds.' -f $guestName, $clock.Elapsed.TotalSeconds) -Evidence @{ guest = $guestName; state = 'Off'; seconds = [int]$clock.Elapsed.TotalSeconds }
            return
        }
        Start-Sleep -Seconds 5
    }
    $state = [string](Get-VM -Name $guestName).State
    Write-DemoControlResult -ActionName 'StopGuest' -Status 'Warning' -Message ('{0} was still {1} after {2} minutes. Deallocating the host shuts it down through its automatic stop action (ShutDown).' -f $guestName, $state, $minutes) -Evidence @{ guest = $guestName; state = $state; seconds = [int]$clock.Elapsed.TotalSeconds }
}

function Invoke-DemoWorkloadControl {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $ActionName,

        [AllowEmptyString()]
        [string] $Request,

        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    $settings = Read-DemoVmJsonFile -Path (Join-Path -Path $StateRoot -ChildPath 'settings.json')
    if ($null -eq $settings) {
        Write-DemoControlResult -ActionName $ActionName -Status 'Fail' -Message 'settings.json is missing; the bootstrap loader has not run on this VM.'
        return
    }
    $role = [string]$settings['role']
    Initialize-DemoVmContext -Root $StateRoot -Role $role -BundleRoot $script:ControlBundleRoot | Out-Null
    $body = Get-DemoControlRequest -Value $Request
    switch ($ActionName) {
        'EnableT3' {
            if ($role -ne 'SqlVm') {
                Write-DemoControlResult -ActionName $ActionName -Status 'Fail' -Message 'EnableT3 runs on T1 (sqlvm01).'
                return
            }
            Invoke-DemoControlEnableT3 -StateRoot $StateRoot -Request $body
        }
        'EnableT4' {
            if ($role -ne 'SqlVm') {
                Write-DemoControlResult -ActionName $ActionName -Status 'Fail' -Message 'EnableT4 runs on T1 (sqlvm01).'
                return
            }
            Invoke-DemoControlEnableT4 -StateRoot $StateRoot -Request $body
        }
        'Runner' {
            Invoke-DemoControlRunner -StateRoot $StateRoot -Request $body -Settings $settings
        }
        'StopGuest' {
            if ($role -ne 'ArcHost') {
                Write-DemoControlResult -ActionName $ActionName -Status 'Fail' -Message 'StopGuest runs on the T2 host (archost01).'
                return
            }
            Invoke-DemoControlStopGuest -Request $body -Settings $settings
        }
        default {
            Write-DemoControlResult -ActionName ([string]$ActionName) -Status 'Fail' -Message 'Unknown action; use EnableT3, EnableT4, Runner, or StopGuest.'
        }
    }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-DemoWorkloadControl -ActionName $Action -Request $RequestBase64 -StateRoot $Root
    }
    catch {
        Write-DemoControlResult -ActionName ([string]$Action) -Status 'Fail' -Message ('The control action failed: {0}' -f $_.Exception.Message)
    }
    exit 0
}
