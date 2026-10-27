<#
.SYNOPSIS
Hosts the ContosoCare activity profiles on a demo VM, or in the T2 guest, until the next auto-shutdown
(ADR 0010). The SYSTEM scheduled task DbHubDemo-Workload runs it two minutes after every start.

.DESCRIPTION
Reads workload-install.json, which the WorkloadRunner step writes, then:
1. Computes the next auto-shutdown from the same schedule as the DevTest Labs auto-shutdown
   (autoShutdownTime and autoShutdownTimeZone), and exits when it's less than 10 minutes away.
2. Picks the targets: the VM's own (T1 on sqlvm01, T2 in the guest), plus T3 on T1 once
   Enable-DemoT3Workload has recorded that T1's identity reaches T3 (t3-workload.json) and T3's name
   resolves. It doesn't after stop-demo.ps1 -RemoveT3, until start-demo.ps1 recreates T3. T4, the
   PostgreSQL flexible server, joins the same way once Enable-DemoT4Workload has recorded t4-workload.json
   (Phase 24, ADR 0019); its sessions sign in as the runner's role with T1's managed identity.
3. Sets every target's activity profile to the configured one (activityProfile, baseline by default), ending
   before the next auto-shutdown: once after each install (a deployment), and once per boot only when
   activityProfileOnBoot is true. It's false by default: a VM that starts (a manual start, a scheduled
   start, a restart) then serves only the profile that deploy.ps1, start-demo.ps1, demo-control.yml, or the
   live-activity notebook set, and stop-demo.ps1 sets it to off, so T3's serverless database can auto-pause
   (ADR 0016, R183). A profile set later in the same boot survives a restart of this task.
4. Runs 'ContosoCare.Workload profile run' until two minutes before the next auto-shutdown, or until the
   task is stopped. It polls the stored profiles, so a profile set while it runs takes effect within a
   poll. While the T3 profile is active, the runner keeps the serverless database awake (ADR 0016).

It's self-contained, without the DbHubDemo.Vm module, because the task runs this stable copy next to the
runner while the bundle folders change with each deployment. Nothing here is secret: T1 and T2 use Windows
authentication and T3 the VM's managed identity. Windows PowerShell 5.1.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.

.PARAMETER NowUtc
For tests only: the current time.
#>
[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\DbHubDemo',

    [datetime] $NowUtc = [DateTime]::UtcNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WorkloadStateRoot = $Root

function Write-DemoWorkloadLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string] $Level = 'Info'
    )

    $line = '{0} [{1}] {2}' -f [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture), $Level.ToUpperInvariant(), $Message
    Write-Verbose -Message $line
    try {
        $folder = Join-Path -Path $script:WorkloadStateRoot -ChildPath 'logs'
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
        [System.IO.File]::AppendAllText((Join-Path -Path $folder -ChildPath 'workload-wrapper.log'), $line + "`r`n", (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
    }
    catch {
        Write-Verbose -Message 'Could not write the workload log.'
    }
}

function Read-DemoWorkloadJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return ($text | ConvertFrom-Json)
}

function Get-DemoWorkloadValue {
    # A property of a ConvertFrom-Json object, or $null when it doesn't exist (Set-StrictMode safe).
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function ConvertTo-DemoWorkloadStamp {
    # A time stamp as ISO 8601 text. PowerShell 7's ConvertFrom-Json turns ISO strings into DateTime values,
    # while Windows PowerShell 5.1 keeps them as text; both compare the same way after this.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function ConvertTo-DemoWorkloadArgument {
    # Quotes one argument for a Windows command line (the CommandLineToArgvW rules).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Argument
    )

    if ($Argument -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = New-Object -TypeName 'System.Text.StringBuilder'
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($character -eq [char]'"') {
            [void]$builder.Append([char]'\', (2 * $backslashes) + 1)
            [void]$builder.Append([char]'"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([char]'\', $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]'\', 2 * $backslashes)
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-DemoWorkloadRunner {
    <#
    .SYNOPSIS
    Runs 'dotnet.exe <runner> <arguments>' and returns its exit code. With TimeoutSeconds 0 it waits as long as
    the runner runs (profile run); standard output and error go to the logs folder.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DotNetExe,

        [Parameter(Mandatory = $true)]
        [string] $RunnerDll,

        [Parameter(Mandatory = $true)]
        [string[]] $ArgumentList,

        [ValidateRange(0, 86400)]
        [int] $TimeoutSeconds = 300,

        [Parameter(Mandatory = $true)]
        [string] $LogName
    )

    $all = @($RunnerDll) + @($ArgumentList)
    $info = New-Object -TypeName 'System.Diagnostics.ProcessStartInfo'
    $info.FileName = $DotNetExe
    $info.Arguments = (@($all | ForEach-Object { ConvertTo-DemoWorkloadArgument -Argument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = Split-Path -Path $RunnerDll -Parent
    $info.EnvironmentVariables['DOTNET_ROOT'] = Split-Path -Path $DotNetExe -Parent
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $waitMilliseconds = -1
        if ($TimeoutSeconds -gt 0) {
            $waitMilliseconds = $TimeoutSeconds * 1000
        }
        if (-not $process.WaitForExit($waitMilliseconds)) {
            $process.Kill()
            Write-DemoWorkloadLog -Level 'Warning' -Message ('{0} did not finish within {1} seconds and was stopped.' -f $LogName, $TimeoutSeconds)
            return 1
        }
        $process.WaitForExit()
        $folder = Join-Path -Path $script:WorkloadStateRoot -ChildPath 'logs'
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
        $text = 'exit code {0}{1}--- stdout ---{1}{2}{1}--- stderr ---{1}{3}{1}' -f $process.ExitCode, "`r`n", $stdout.Result, $stderr.Result
        [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath ('workload-{0}.log' -f $LogName)), $text, (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
        return [int]$process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Get-DemoWorkloadNextShutdown {
    # The next daily auto-shutdown after NowUtc in the Windows time zone, as a DateTimeOffset.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Time,

        [string] $TimeZoneId = 'UTC',

        [Parameter(Mandatory = $true)]
        [datetime] $Now
    )

    if ($Time -notmatch '^([01][0-9]|2[0-3])[0-5][0-9]$') {
        throw ('The auto-shutdown time {0} is not HHmm.' -f $Time)
    }
    try {
        $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    }
    catch {
        Write-DemoWorkloadLog -Level 'Warning' -Message ('Time zone {0} was not found; the auto-shutdown time is read as UTC.' -f $TimeZoneId)
        $zone = [System.TimeZoneInfo]::Utc
    }
    $utc = [DateTime]::SpecifyKind($Now, [System.DateTimeKind]::Utc)
    $localNow = [DateTime]::SpecifyKind([System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $zone), [System.DateTimeKind]::Unspecified)
    $candidate = $localNow.Date.AddHours([int]$Time.Substring(0, 2)).AddMinutes([int]$Time.Substring(2, 2))
    if ($candidate -le $localNow) {
        $candidate = $candidate.AddDays(1)
    }
    if ($zone.IsInvalidTime($candidate)) {
        $candidate = $candidate.AddHours(1)
    }
    return (New-Object -TypeName 'System.DateTimeOffset' -ArgumentList $candidate, $zone.GetUtcOffset($candidate))
}

function Test-DemoWorkloadNameResolve {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $HostName
    )

    try {
        return (@([System.Net.Dns]::GetHostAddresses($HostName)).Count -gt 0)
    }
    catch {
        return $false
    }
}

function Get-DemoWorkloadBootTime {
    # The last boot time in UTC, as ISO 8601 text.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $os = Get-CimInstance -ClassName 'Win32_OperatingSystem'
    return $os.LastBootUpTime.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-DemoWorkloadHost {
    <#
    .SYNOPSIS
    The wrapper's logic; returns the exit code for the scheduled task.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [datetime] $Now
    )

    $script:WorkloadStateRoot = $StateRoot
    $install = Read-DemoWorkloadJson -Path (Join-Path -Path $StateRoot -ChildPath 'workload-install.json')
    if ($null -eq $install) {
        Write-DemoWorkloadLog -Level 'Error' -Message 'workload-install.json is missing; the WorkloadRunner step writes it.'
        return 1
    }
    $dotnet = [string](Get-DemoWorkloadValue -InputObject $install -Name 'dotnetExe')
    $runner = [string](Get-DemoWorkloadValue -InputObject $install -Name 'runnerDll')
    $primary = [string](Get-DemoWorkloadValue -InputObject $install -Name 'primaryTarget')
    $activityProfile = [string](Get-DemoWorkloadValue -InputObject $install -Name 'activityProfile')
    $profileOnBoot = ([string](Get-DemoWorkloadValue -InputObject $install -Name 'profileOnBoot')) -eq 'True'
    foreach ($path in @($dotnet, $runner)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-DemoWorkloadLog -Level 'Error' -Message ('The runner is not installed: {0} is missing.' -f $path)
            return 1
        }
    }
    if ($primary -notin @('T1', 'T2')) {
        Write-DemoWorkloadLog -Level 'Error' -Message ('workload-install.json names an unknown target: {0}.' -f $primary)
        return 1
    }

    $shutdown = Get-DemoWorkloadNextShutdown -Time ([string](Get-DemoWorkloadValue -InputObject $install -Name 'autoShutdownTime')) -TimeZoneId ([string](Get-DemoWorkloadValue -InputObject $install -Name 'autoShutdownTimeZone')) -Now $Now
    $minutesLeft = ($shutdown.UtcDateTime - [DateTime]::SpecifyKind($Now, [System.DateTimeKind]::Utc)).TotalMinutes
    $notAfter = $shutdown.ToString("yyyy-MM-dd'T'HH:mm:sszzz", [System.Globalization.CultureInfo]::InvariantCulture)
    if ($minutesLeft -lt 10) {
        Write-DemoWorkloadLog -Message ('The next auto-shutdown is {0}, {1:N0} minutes away, so no activity starts.' -f $notAfter, $minutesLeft)
        return 0
    }

    $t3Fqdn = ''
    $t3 = Get-DemoWorkloadValue -InputObject $install -Name 't3'
    if ($primary -eq 'T1' -and $null -ne $t3) {
        $fqdn = [string](Get-DemoWorkloadValue -InputObject $t3 -Name 'serverFqdn')
        $marker = Read-DemoWorkloadJson -Path (Join-Path -Path $StateRoot -ChildPath 't3-workload.json')
        if ($fqdn -and $null -ne $marker -and [string](Get-DemoWorkloadValue -InputObject $marker -Name 'serverFqdn') -eq $fqdn) {
            if (Test-DemoWorkloadNameResolve -HostName $fqdn) {
                $t3Fqdn = $fqdn
            }
            else {
                Write-DemoWorkloadLog -Level 'Warning' -Message ('T3 ({0}) does not resolve, so only {1} runs; start-demo.ps1 recreates T3 and restarts this task.' -f $fqdn, $primary)
            }
        }
    }

    $t4Fqdn = ''
    $t4Role = ''
    $t4 = Get-DemoWorkloadValue -InputObject $install -Name 't4'
    if ($primary -eq 'T1' -and $null -ne $t4) {
        $fqdn = [string](Get-DemoWorkloadValue -InputObject $t4 -Name 'serverFqdn')
        $marker = Read-DemoWorkloadJson -Path (Join-Path -Path $StateRoot -ChildPath 't4-workload.json')
        if ($fqdn -and $null -ne $marker -and [string](Get-DemoWorkloadValue -InputObject $marker -Name 'serverFqdn') -eq $fqdn) {
            if (Test-DemoWorkloadNameResolve -HostName $fqdn) {
                $t4Fqdn = $fqdn
                $t4Role = [string](Get-DemoWorkloadValue -InputObject $marker -Name 'runnerRole')
                if ($t4Role -notmatch '^[a-z_][a-z0-9_]{0,62}$') {
                    $t4Role = 'contosocare_runner'
                }
            }
            else {
                Write-DemoWorkloadLog -Level 'Warning' -Message ('T4 ({0}) does not resolve, so the host runs without it.' -f $fqdn)
            }
        }
    }

    $installedUtc = ConvertTo-DemoWorkloadStamp -Value (Get-DemoWorkloadValue -InputObject $install -Name 'installedUtc')
    $bootUtc = Get-DemoWorkloadBootTime
    $bootPath = Join-Path -Path $StateRoot -ChildPath 'workload-boot.json'
    $applied = Read-DemoWorkloadJson -Path $bootPath
    $newBoot = $null -eq $applied -or (ConvertTo-DemoWorkloadStamp -Value (Get-DemoWorkloadValue -InputObject $applied -Name 'bootUtc')) -ne $bootUtc
    $newInstall = $null -eq $applied -or (ConvertTo-DemoWorkloadStamp -Value (Get-DemoWorkloadValue -InputObject $applied -Name 'installedUtc')) -ne $installedUtc
    # After an install (a deployment) the configured profile always applies; at a boot only when
    # activityProfileOnBoot is true, so a VM that starts doesn't keep T3 awake on its own (R183).
    $apply = $newInstall -or ($newBoot -and $profileOnBoot)
    if (-not $apply -and $newBoot) {
        Write-DemoWorkloadLog -Message ('The activity profile is not set at boot (activityProfileOnBoot is false): the stored profiles stay as deploy.ps1, start-demo.ps1, stop-demo.ps1, or demo-control.yml left them; {0} is the configured one.' -f $activityProfile)
        $record = [ordered]@{
            bootUtc      = $bootUtc
            installedUtc = $installedUtc
            profile      = $activityProfile
            applied      = $false
            reason       = 'activityProfileOnBoot is false'
            appliedUtc   = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        [System.IO.File]::WriteAllText($bootPath, ($record | ConvertTo-Json -Depth 5), (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
    }
    if ($apply) {
        $targets = @($primary)
        if ($t3Fqdn) {
            $targets += 'T3'
        }
        if ($t4Fqdn) {
            $targets += 'T4'
        }
        $results = [ordered]@{}
        foreach ($target in $targets) {
            $arguments = @('profile', 'set', '--target', $target, '--name', $activityProfile, '--requested-by', 'DbHubDemo-Workload')
            if ($activityProfile -ne 'off') {
                $arguments += @('--not-after', $notAfter)
            }
            if ($target -eq 'T3') {
                $arguments += @('--server', $t3Fqdn)
            }
            if ($target -eq 'T4') {
                $arguments += @('--server', $t4Fqdn)
            }
            $exitCode = 1
            # SQL Server may still be starting after a boot: retry for about five minutes.
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                $exitCode = Invoke-DemoWorkloadRunner -DotNetExe $dotnet -RunnerDll $runner -ArgumentList $arguments -TimeoutSeconds 300 -LogName ('profile-set-' + $target.ToLowerInvariant())
                if ($exitCode -eq 0) {
                    break
                }
                Start-Sleep -Seconds 30
            }
            $results[$target] = $exitCode
            Write-DemoWorkloadLog -Message ('{0}: activity profile {1} until {2}: exit code {3}.' -f $target, $activityProfile, $notAfter, $exitCode)
        }
        $record = [ordered]@{
            bootUtc      = $bootUtc
            installedUtc = $installedUtc
            profile      = $activityProfile
            notAfter     = $notAfter
            exitCodes    = $results
            appliedUtc   = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        [System.IO.File]::WriteAllText($bootPath, ($record | ConvertTo-Json -Depth 5), (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
    }

    $hostArguments = @('profile', 'run', '--target', $primary, '--not-after', $notAfter, '--log-file', (Join-Path -Path (Join-Path -Path $StateRoot -ChildPath 'logs') -ChildPath ('workload-{0}.log' -f [DateTime]::UtcNow.ToString('yyyyMMdd'))))
    if ($t3Fqdn) {
        $hostArguments += @('--t3-server', $t3Fqdn)
    }
    if ($t4Fqdn) {
        $hostArguments += @('--t4-server', $t4Fqdn, '--t4-user', $t4Role)
    }
    $targetText = $primary
    if ($t3Fqdn) {
        $targetText = $primary + ' and T3'
    }
    if ($t4Fqdn) {
        $targetText = $targetText.Replace(' and ', ', ') + ' and T4'
    }
    Write-DemoWorkloadLog -Message ('Hosting the activity profiles for {0} until {1}.' -f $targetText, $notAfter)
    $code = Invoke-DemoWorkloadRunner -DotNetExe $dotnet -RunnerDll $runner -ArgumentList $hostArguments -TimeoutSeconds 0 -LogName 'host'
    Write-DemoWorkloadLog -Message ('The activity host ended with exit code {0}.' -f $code)
    return $code
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        exit (Invoke-DemoWorkloadHost -StateRoot $Root -Now $NowUtc)
    }
    catch {
        Write-DemoWorkloadLog -Level 'Error' -Message ('The workload host failed: {0}' -f $_.Exception.Message)
        exit 1
    }
}
