# The workload runner inside the T2 guest (ADR 0010, Phase 13). Windows PowerShell 5.1 on the Hyper-V host;
# every in-guest action runs over PowerShell Direct with the guest administrator's DPAPI-protected password.
# Dot-sourced by vm/bootstrap/Invoke-HostBootstrap.ps1.

function Get-DemoHostGuestWorkloadRecord {
    # The workload-install.json this bundle wants inside the guest (primary target T2, no T3).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $pin = Get-DemoVmDotNetPin -BundleRoot $Context.BundleRoot
    return (New-DemoVmWorkloadRecord -Root $Context.Guest.ToolsFolder -Workload $Context.Workload -PrimaryTarget 'T2' -DotNetPin $pin)
}

function Get-DemoHostGuestWorkloadStatus {
    <#
    .SYNOPSIS
    What's installed in the guest: workload-install.json, the runner, the runtime, the wrapper's SHA-256,
    and the DbHubDemo-Workload task. Returns $null when the guest can't be read. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    try {
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        $pin = Get-DemoVmDotNetPin -BundleRoot $Context.BundleRoot
        $runtime = @{ version = [string]$pin['version']; sha512 = ([string]$pin['sha512']).ToLowerInvariant() }
        $status = Invoke-Command -VMName $Context.GuestName -Credential $credential -ArgumentList $Context.Guest.ToolsFolder, $Context.Workload.RunnerSha256, $runtime -ErrorAction Stop -ScriptBlock {
            param($Folder, $RunnerSha256, $Runtime)
            $module = Join-Path -Path $Folder -ChildPath 'module\DbHubDemo.Vm.psd1'
            if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {
                return $null
            }
            Import-Module -Name $module -Force
            $paths = Get-DemoVmWorkloadPath -Root $Folder -RunnerSha256 $RunnerSha256
            $record = $null
            if (Test-Path -LiteralPath $paths.InstallRecord -PathType Leaf) {
                $record = [System.IO.File]::ReadAllText($paths.InstallRecord)
            }
            $wrapperSha256 = ''
            if (Test-Path -LiteralPath $paths.Wrapper -PathType Leaf) {
                $wrapperSha256 = Get-DemoVmFileSha256 -Path $paths.Wrapper
            }
            [pscustomobject]@{
                Record        = $record
                RunnerOk      = (Test-DemoVmRunnerPackage -Root $Folder -Sha256 $RunnerSha256)
                RuntimeOk     = (Test-DemoVmDotNetRuntime -Root $Folder -Pin $Runtime)
                TaskOk        = (Test-DemoVmWorkloadTask -Root $Folder)
                WrapperSha256 = $wrapperSha256
                Health        = (Get-DemoVmWorkloadHealth -Root $Folder)
            }
        }
        return $status
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The workload in the guest could not be read: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Test-DemoHostGuestWorkload {
    <#
    .SYNOPSIS
    The host's WorkloadRunner check: the guest runs this runner and runtime, with the current wrapper, a T2
    setup that passed, the current profile and schedule, and the DbHubDemo-Workload task. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    if (-not (Test-DemoHostGuestReachable -Context $Context)) {
        return $false
    }
    $status = Get-DemoHostGuestWorkloadStatus -Context $Context
    if ($null -eq $status -or -not $status.RunnerOk -or -not $status.RuntimeOk -or -not $status.TaskOk -or -not $status.Record) {
        return $false
    }
    $wrapper = [System.IO.Path]::Combine($Context.BundleRoot, 'vm', 'bootstrap', 'Start-DemoWorkload.ps1')
    if ([string]$status.WrapperSha256 -ne (Get-DemoVmFileSha256 -Path $wrapper)) {
        return $false
    }
    $record = ConvertTo-DemoVmHashtable -InputObject ([string]$status.Record | ConvertFrom-Json)
    return (Test-DemoVmWorkloadRecord -Record $record -Expected (Get-DemoHostGuestWorkloadRecord -Context $Context))
}

function Install-DemoHostGuestWorkload {
    <#
    .SYNOPSIS
    Installs the workload runner inside the T2 guest and starts its host for target T2 (ADR 0010, Phase 13).

    .DESCRIPTION
    1. Waits (WaitingForGuestSql, not Failed) until the guest answers over PowerShell Direct and its SQL
       Server runs with the guest administrator as a sysadmin. The Arc and setup-wizard waits come earlier
       in the plan, so in PaygWizard mode this step runs only after the wizard.
    2. On the host: assembles and verifies the runner zip from its Run Command chunks (waiting while they
       haven't all arrived), and downloads the pinned .NET runtime zip (SHA-512). Neither is extracted on
       the host.
    3. Copies the module, both zips, and Start-DemoWorkload.ps1 into the guest, each checked by SHA-256
       there, restricts the guest's C:\ProgramData\DbHubDemo to SYSTEM and Administrators, and extracts the
       runner and the runtime after checking their pinned hashes again.
    4. Runs the runner's setup for T2 as the guest administrator. In PaygWizard mode the wizard made only that
       account a sysadmin, so SYSTEM, which runs the task, gets a ContosoCare user in contosocare_runner
       (--grant-windows-login, no server-level permissions); in the other modes SYSTEM is a sysadmin through
       BUILTIN\Administrators.
    5. Writes workload-install.json in the guest, registers DbHubDemo-Workload there, and starts it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $workload = $Context.Workload
    if (-not (Test-DemoHostGuestReachable -Context $Context)) {
        return (New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForGuestSql' -Message ('Waiting for {0} to answer over PowerShell Direct before the workload runner is installed in it.' -f $Context.GuestName))
    }
    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    $instance = $null
    try {
        $instance = Get-DemoGuestSqlInstance -Name $Context.GuestName -Credential $credential
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('SQL Server check in the guest: {0}' -f $_.Exception.Message)
    }
    if ($null -eq $instance -or -not $instance.Running -or -not $instance.IsSysAdmin) {
        return (New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForGuestSql' -Message ('Waiting for SQL Server in {0} to run, with the guest administrator as a sysadmin, before the workload runner is installed in it.' -f $Context.GuestName))
    }

    $root = $Context.Root
    $paths = Get-DemoVmWorkloadPath -Root $root -RunnerSha256 $workload.RunnerSha256
    if (-not (Test-Path -LiteralPath $paths.RunnerZip -PathType Leaf) -and -not (Test-DemoVmRunnerChunk -Root $root -Sha256 $workload.RunnerSha256 -ChunkCount $workload.RunnerChunkCount)) {
        return (New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForInput' -Message ('Waiting for the workload runner {0}: its {1} Run Command chunk(s) have not all arrived on the host. deploy.ps1 sends them with Send-DemoWorkloadRunner.' -f $workload.RunnerSha256.Substring(0, 12), $workload.RunnerChunkCount))
    }
    $runnerZip = Get-DemoVmRunnerZip -Root $root -Sha256 $workload.RunnerSha256 -ChunkCount $workload.RunnerChunkCount
    $pin = Get-DemoVmDotNetPin -BundleRoot $Context.BundleRoot
    $runtimeSha512 = ([string]$pin['sha512']).ToLowerInvariant()
    $runtimeZip = Join-Path -Path $paths.Downloads -ChildPath ([string]$pin['fileName'])
    if (-not (Test-DemoVmFileHash -Path $runtimeZip -ExpectedSha512 $runtimeSha512)) {
        Save-DemoVmDownload -Uri ([string]$pin['url']) -Path $runtimeZip -ExpectedSha512 $runtimeSha512 -Name 'dotnetRuntime' | Out-Null
    }

    $folder = $Context.Guest.ToolsFolder
    # Guest paths are joined as strings: the guest's drive doesn't exist on the host (Join-DemoVmPath).
    $guestPaths = Get-DemoVmWorkloadPath -Root $folder -RunnerSha256 $workload.RunnerSha256
    $guestRunnerZip = Join-DemoVmPath -Path $guestPaths.Downloads -ChildPath ([System.IO.Path]::GetFileName($runnerZip))
    $guestRuntimeZip = Join-DemoVmPath -Path $guestPaths.Downloads -ChildPath ([string]$pin['fileName'])
    $wrapper = [System.IO.Path]::Combine($Context.BundleRoot, 'vm', 'bootstrap', 'Start-DemoWorkload.ps1')
    Copy-DemoGuestTool -Name $Context.GuestName -Credential $credential -BundleRoot $Context.BundleRoot -GuestToolsFolder $folder
    Copy-DemoGuestFile -Name $Context.GuestName -Credential $credential -SourcePath $runnerZip -DestinationPath $guestRunnerZip -ExpectedSha256 $workload.RunnerSha256
    Copy-DemoGuestFile -Name $Context.GuestName -Credential $credential -SourcePath $runtimeZip -DestinationPath $guestRuntimeZip -ExpectedSha256 (Get-DemoVmFileSha256 -Path $runtimeZip)
    Copy-DemoGuestFile -Name $Context.GuestName -Credential $credential -SourcePath $wrapper -DestinationPath $guestPaths.Wrapper -ExpectedSha256 (Get-DemoVmFileSha256 -Path $wrapper)

    $record = Get-DemoHostGuestWorkloadRecord -Context $Context
    $grantLogin = ''
    if ($Context.Mode -eq 'PaygWizard') {
        $grantLogin = 'NT AUTHORITY\SYSTEM'
    }
    $outcome = Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop `
        -ArgumentList $folder, $workload.RunnerSha256, $guestRunnerZip, $guestRuntimeZip, $runtimeSha512, ([string]$pin['version']), $record, $grantLogin -ScriptBlock {
        param($Folder, $RunnerSha256, $RunnerZip, $RuntimeZip, $RuntimeSha512, $RuntimeVersion, $Record, $GrantLogin)
        $ErrorActionPreference = 'Stop'
        Import-Module -Name (Join-Path -Path $Folder -ChildPath 'module\DbHubDemo.Vm.psd1') -Force
        Protect-DemoVmFolder -Path $Folder
        $paths = Get-DemoVmWorkloadPath -Root $Folder -RunnerSha256 $RunnerSha256
        Stop-DemoVmWorkload -Root $Folder -Confirm:$false
        if (-not (Test-DemoVmRunnerPackage -Root $Folder -Sha256 $RunnerSha256)) {
            Expand-DemoVmVerifiedZip -ZipPath $RunnerZip -Destination $paths.Runner -ExpectedSha256 $RunnerSha256
        }
        $runtime = @{ version = $RuntimeVersion; sha512 = $RuntimeSha512 }
        if (-not (Test-DemoVmDotNetRuntime -Root $Folder -Pin $runtime)) {
            Expand-DemoVmVerifiedZip -ZipPath $RuntimeZip -Destination $paths.DotNet -ExpectedSha512 $RuntimeSha512 -MarkerName '.runtime.json' -MarkerData @{ version = $RuntimeVersion }
        }
        $setup = Invoke-DemoVmRunnerSetup -DotNetExe $paths.DotNetExe -RunnerDll $paths.RunnerDll -Target 'T2' -GrantWindowsLogin $GrantLogin
        if ($setup.Status -in @('Pass', 'Warning')) {
            $Record['setup'] = @{ T2 = @{ status = $setup.Status; utc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture); message = $setup.Message } }
            Write-DemoVmWorkloadInstall -Root $Folder -Record $Record
            Register-DemoVmWorkloadTask -Root $Folder
            Start-DemoVmWorkload -Confirm:$false
            Remove-DemoVmOldRunner -Root $Folder -KeepSha256 $RunnerSha256 -Confirm:$false
            Remove-Item -LiteralPath $RunnerZip, $RuntimeZip -Force -ErrorAction SilentlyContinue
        }
        [pscustomobject]@{ Status = $setup.Status; Message = $setup.Message }
    }
    if ([string]$outcome.Status -notin @('Pass', 'Warning')) {
        throw ('The runner''s setup on T2 did not pass. {0}' -f $outcome.Message)
    }
    $hostRecord = [ordered]@{
        schemaVersion = 1
        runnerSha256  = $workload.RunnerSha256
        dotnetVersion = [string]$pin['version']
        setupT2       = [string]$outcome.Status
        message       = [string]$outcome.Message
        installedUtc  = Get-DemoVmUtcNow
    }
    Write-DemoVmJsonFile -Path (Join-Path -Path $root -ChildPath 'guest-workload.json') -InputObject $hostRecord -Redact
    Write-DemoVmLog -Message ('The workload runner {0} is installed in {1} and its host runs for T2.' -f $workload.RunnerSha256.Substring(0, 12), $Context.GuestName)
    if ($outcome.Status -eq 'Warning') {
        return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage ('T2: {0}' -f $outcome.Message))
    }
}
