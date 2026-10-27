<#
.SYNOPSIS
T1 state machine for sqlvm01 (ADR 0003): data disk, SQL Server access, ContosoCare schema, configuration,
seed, and the workload runner (ADR 0010).

.DESCRIPTION
Runs as SYSTEM from the scheduled task DbHubDemo-Bootstrap, at startup and every 5 minutes, with a lock
against overlapping runs. Each step checks before it acts. Progress is in C:\ProgramData\DbHubDemo\state.json
and health.json. Windows PowerShell 5.1. SQL Server is reached locally with Windows authentication only.
Without a data disk (settings dataDiskTier None, the lowest-cost default), the DataDisk step is Not selected
and ContosoCare uses SQL Server's default data and log folders on the OS disk. The WorkloadRunner step
installs the .NET runtime and the runner that deploy.ps1 delivers in Run Command chunks, applies the demo
objects to T1 (and to T3 once Enable-DemoT3Workload has run), and registers the DbHubDemo-Workload task
that hosts the activity profiles for T1 and T3.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.
#>
[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SqlVmBundleRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Vm.psd1') -Force

function Get-DemoSqlVmContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $BundleRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Settings
    )

    $config = Import-PowerShellDataFile -Path ([System.IO.Path]::Combine($BundleRoot, 'vm', 'dsc', 'sqlvm.psd1'))
    $seedScale = [int]$Settings['seedScale']
    if ($seedScale -le 0) {
        throw 'settings.json is missing a positive seedScale.'
    }
    return @{
        BundleRoot   = $BundleRoot
        Root         = (Get-DemoVmContext).Root
        Config       = $config
        DataDiskTier = [string]$Settings['dataDiskTier']
        SeedScale    = $seedScale
        SeedVersion  = 1
        StatusQuery  = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($BundleRoot, 'database', 'common', '900-status.sql'))
        Workload     = Get-DemoVmWorkloadSetting -Settings $Settings
    }
}

function Test-DemoSqlVmHasDataDisk {
    # False when the template created no data disk (dataDiskTier None).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    return ($Context.DataDiskTier -ne 'None')
}

function Get-DemoSqlVmFolder {
    # Data and log folders: on the data disk, or SQL Server's default folders when there's no data disk.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    if (-not (Test-DemoSqlVmHasDataDisk -Context $Context)) {
        $row = @(Invoke-DemoVmSql -Query "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(512)) AS data_path, CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(512)) AS log_path")[0]
        if ([string]::IsNullOrWhiteSpace([string]$row.data_path) -or [string]::IsNullOrWhiteSpace([string]$row.log_path)) {
            throw 'SQL Server did not report its default data and log folders.'
        }
        return [pscustomobject]@{
            Data = ([string]$row.data_path).TrimEnd('\')
            Log  = ([string]$row.log_path).TrimEnd('\')
        }
    }
    $disk = $Context.Config.DataDisk
    $volume = Get-DemoVmDataVolume -Label $disk.Label
    if (-not $volume) {
        return $null
    }
    return [pscustomobject]@{
        Data = '{0}:\{1}' -f $volume.DriveLetter, $disk.DataFolder
        Log  = '{0}:\{1}' -f $volume.DriveLetter, $disk.LogFolder
    }
}

function Initialize-DemoSqlVmDataDisk {
    # Formats LUN 0 and grants the SQL Server service SID full control of the data and log folders.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $disk = $Context.Config.DataDisk
    Initialize-DemoVmDataDisk -Label $disk.Label -DriveLetter $disk.DriveLetter -Lun $disk.Lun -AllocationUnitSize $disk.AllocationUnitSize | Out-Null
    $folders = Get-DemoSqlVmFolder -Context $Context
    foreach ($folder in @($folders.Data, $folders.Log)) {
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
        $result = Invoke-DemoVmNativeCommand -FilePath 'icacls.exe' -ArgumentList @($folder, '/grant', ('{0}:(OI)(CI)F' -f $Context.Config.Sql.ServiceAccount), '/C', '/Q')
        if ($result.ExitCode -ne 0) {
            throw ('icacls failed with exit code {0} for {1}: {2}' -f $result.ExitCode, $folder, ($result.Output -join ' '))
        }
    }
}

function Test-DemoSqlVmDataDisk {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $folders = Get-DemoSqlVmFolder -Context $Context
    return ($null -ne $folders -and (Test-Path -LiteralPath $folders.Data) -and (Test-Path -LiteralPath $folders.Log))
}

function Test-DemoSqlVmSysadmin {
    # True when this run (SYSTEM) is a sysadmin. Never throws.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $row = @(Invoke-DemoVmSql -Query "SELECT IS_SRVROLEMEMBER('sysadmin') AS is_sysadmin")[0]
        return ([int]$row.is_sysadmin -eq 1)
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('SQL Server access check: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Grant-DemoSqlVmSysadmin {
    <#
    .SYNOPSIS
    Makes BUILTIN\Administrators a sysadmin with the documented "Connect to SQL Server when system
    administrators are locked out" procedure, because the image's SQL IaaS Agent least-privilege mode
    doesn't give SYSTEM sysadmin. SYSTEM and the break-glass local administrator are both members.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $sql = $Context.Config.Sql
    $login = $sql.AdminLogin.Replace(']', ']]')
    Stop-Service -Name $sql.AgentService -Force -ErrorAction SilentlyContinue
    Stop-Service -Name $sql.ServiceName -Force
    try {
        $result = Invoke-DemoVmNativeCommand -FilePath 'net.exe' -ArgumentList @('start', $sql.ServiceName, '/f', '/mSQLCMD')
        if ($result.ExitCode -ne 0) {
            throw ('Starting SQL Server in single-user mode failed: {0}' -f ($result.Output -join ' '))
        }
        $query = "IF SUSER_ID(N'{0}') IS NULL CREATE LOGIN [{0}] FROM WINDOWS; ALTER SERVER ROLE sysadmin ADD MEMBER [{0}];" -f $login
        Invoke-DemoVmSql -Query $query -ApplicationName 'SQLCMD' -TimeoutSeconds 120 | Out-Null
    }
    finally {
        Stop-Service -Name $sql.ServiceName -Force -ErrorAction SilentlyContinue
        Start-Service -Name $sql.ServiceName
        Start-Service -Name $sql.AgentService -ErrorAction SilentlyContinue
    }
    return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage ('SYSTEM was not a sysadmin, so {0} was made one with the documented lockout-recovery procedure.' -f $sql.AdminLogin))
}

function Get-DemoSqlVmDatabaseStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    try {
        $exists = @(Invoke-DemoVmSql -Query "SELECT DB_ID(N'ContosoCare') AS database_id")
        if ($exists.Count -eq 0 -or $null -eq $exists[0].database_id) {
            return $null
        }
        return @(Invoke-DemoVmSql -Database 'ContosoCare' -Query $Context.StatusQuery)[0]
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('Database check: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Test-DemoSqlVmDatabase {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [switch] $Seeded
    )

    $status = Get-DemoSqlVmDatabaseStatus -Context $Context
    if ($null -eq $status) {
        return $false
    }
    if ($Seeded) {
        return ([string]$status.seed_status -eq 'Completed' -and [int]$status.seed_scale -eq $Context.SeedScale -and [int]$status.seed_version -eq $Context.SeedVersion)
    }
    return ([string]$status.query_store_state -eq 'READ_WRITE' -and [int]$status.uncapped_files -eq 0 -and [string]$status.recovery_model -eq 'SIMPLE' -and [int]$status.seed_procedure -eq 1 -and [int]$status.runner_role -eq 1)
}

function Initialize-DemoSqlVmDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $folders = Get-DemoSqlVmFolder -Context $Context
    $database = Join-Path -Path $Context.BundleRoot -ChildPath 'database'
    Invoke-DemoVmSqlScript -Path ([System.IO.Path]::Combine($database, 'sqlvm01', '000-create-database.sql')) -Database 'master' -Token @{ DATA_DIRECTORY = $folders.Data; LOG_DIRECTORY = $folders.Log }
    foreach ($relative in @('common\010-schema.sql', 'common\020-seed.sql', 'sqlvm01\030-configure.sql')) {
        Invoke-DemoVmSqlScript -Path (Join-Path -Path $database -ChildPath $relative) -Database 'ContosoCare'
    }
}

function Get-DemoSqlVmWorkloadRecord {
    # The workload-install.json this bundle wants on T1 (New-DemoVmWorkloadRecord).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $pin = Get-DemoVmDotNetPin -BundleRoot $Context.BundleRoot
    return (New-DemoVmWorkloadRecord -Root $Context.Root -Workload $Context.Workload -PrimaryTarget 'T1' -DotNetPin $pin)
}

function Test-DemoSqlVmWorkload {
    <#
    .SYNOPSIS
    The WorkloadRunner step's check: the pinned runtime, this runner, its wrapper, a setup that passed on T1,
    the current profile and schedule, and the DbHubDemo-Workload task are all in place.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $workload = $Context.Workload
    $root = $Context.Root
    $paths = Get-DemoVmWorkloadPath -Root $root -RunnerSha256 $workload.RunnerSha256
    $pin = Get-DemoVmDotNetPin -BundleRoot $Context.BundleRoot
    if (-not (Test-DemoVmDotNetRuntime -Root $root -Pin $pin) -or -not (Test-DemoVmRunnerPackage -Root $root -Sha256 $workload.RunnerSha256)) {
        return $false
    }
    $bundleWrapper = [System.IO.Path]::Combine($Context.BundleRoot, 'vm', 'bootstrap', 'Start-DemoWorkload.ps1')
    if (-not (Test-Path -LiteralPath $paths.Wrapper -PathType Leaf) -or (Get-DemoVmFileSha256 -Path $paths.Wrapper) -ne (Get-DemoVmFileSha256 -Path $bundleWrapper)) {
        return $false
    }
    $record = Read-DemoVmJsonFile -Path $paths.InstallRecord
    if (-not (Test-DemoVmWorkloadRecord -Record $record -Expected (Get-DemoSqlVmWorkloadRecord -Context $Context))) {
        return $false
    }
    return (Test-DemoVmWorkloadTask -Root $root)
}

function Install-DemoSqlVmWorkload {
    <#
    .SYNOPSIS
    Installs the workload runner on T1 and starts its host (ADR 0010, Phase 13).

    .DESCRIPTION
    1. Assembles and verifies the runner from the Run Command chunks that Send-DemoWorkloadRunner delivered
       (Waiting, not Failed, while they haven't all arrived), and extracts it to runner\<sha12>.
    2. Downloads the pinned .NET runtime (SHA-512) and extracts it to dotnet.
    3. Runs the runner's setup on T1 (local, Windows authentication; SYSTEM is a sysadmin through
       BUILTIN\Administrators, see SqlAdminAccess). On T3 it runs setup only when Enable-DemoT3Workload has
       recorded that T1's identity reaches T3 (t3-workload.json): nothing on T1 asks for an Azure SQL token
       before T1 is in the P6 group, because managed identity tokens are cached for up to about 24 hours.
       T4 (PostgreSQL) gets its demo objects and grants the same way once Enable-DemoT4Workload has recorded
       t4-workload.json, signed in as the P6 group's role.
    4. Writes workload-install.json, copies Start-DemoWorkload.ps1 next to the runner, registers the SYSTEM
       task DbHubDemo-Workload, and starts it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $workload = $Context.Workload
    $root = $Context.Root
    $paths = Get-DemoVmWorkloadPath -Root $root -RunnerSha256 $workload.RunnerSha256
    if (-not (Test-DemoVmRunnerPackage -Root $root -Sha256 $workload.RunnerSha256)) {
        if (-not (Test-Path -LiteralPath $paths.RunnerZip -PathType Leaf) -and -not (Test-DemoVmRunnerChunk -Root $root -Sha256 $workload.RunnerSha256 -ChunkCount $workload.RunnerChunkCount)) {
            return (New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForInput' -Message ('Waiting for the workload runner {0}: its {1} Run Command chunk(s) have not all arrived. deploy.ps1 sends them with Send-DemoWorkloadRunner; this step continues on the next run after they arrive.' -f $workload.RunnerSha256.Substring(0, 12), $workload.RunnerChunkCount))
        }
        Stop-DemoVmWorkload -Root $root -Confirm:$false
        $zip = Get-DemoVmRunnerZip -Root $root -Sha256 $workload.RunnerSha256 -ChunkCount $workload.RunnerChunkCount
        Expand-DemoVmVerifiedZip -ZipPath $zip -Destination $paths.Runner -ExpectedSha256 $workload.RunnerSha256
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
    $pin = Get-DemoVmDotNetPin -BundleRoot $Context.BundleRoot
    Install-DemoVmDotNetRuntime -Root $root -Pin $pin | Out-Null
    Stop-DemoVmWorkload -Root $root -Confirm:$false

    $record = Get-DemoSqlVmWorkloadRecord -Context $Context
    $warnings = @()
    $t1 = Invoke-DemoVmRunnerSetup -DotNetExe $paths.DotNetExe -RunnerDll $paths.RunnerDll -Target 'T1'
    if ($t1.Status -in @('Fail', 'Manual action required')) {
        throw ('The runner''s setup on T1 did not pass. {0}' -f $t1.Message)
    }
    $record.setup['T1'] = [ordered]@{ status = $t1.Status; utc = (Get-DemoVmUtcNow); message = $t1.Message }
    if ($t1.Status -eq 'Warning') {
        $warnings += $t1.Message
    }

    if ($null -ne $workload.T3 -and (Test-DemoVmT3Enabled -Root $root -ServerFqdn $workload.T3.ServerFqdn)) {
        if (Test-DemoVmNameResolve -HostName $workload.T3.ServerFqdn) {
            $t3 = Invoke-DemoVmRunnerSetup -DotNetExe $paths.DotNetExe -RunnerDll $paths.RunnerDll -Target 'T3' -Server $workload.T3.ServerFqdn
            $record.setup['T3'] = [ordered]@{ status = $t3.Status; utc = (Get-DemoVmUtcNow); message = $t3.Message }
            if ($t3.Status -ne 'Pass') {
                $warnings += ('T3: {0}' -f $t3.Message)
            }
        }
        else {
            $record.setup['T3'] = [ordered]@{ status = 'Warning'; utc = (Get-DemoVmUtcNow); message = ('{0} does not resolve.' -f $workload.T3.ServerFqdn) }
            $warnings += ('T3 ({0}) does not resolve, so its demo objects were not updated; it may have been removed with stop-demo.ps1 -RemoveT3. start-demo.ps1 recreates it and runs Enable-DemoT3Workload.' -f $workload.T3.ServerFqdn)
        }
    }

    # T4 (Phase 24, ADR 0019): the new runner's demo objects and grants, as the P6 group's role that
    # Enable-DemoT4Workload recorded. A stopped T4 is a Warning; Enable-DemoT4Workload runs the same setup.
    if ($workload.Contains('T4') -and $null -ne $workload.T4 -and (Test-DemoVmT4Enabled -Root $root -ServerFqdn $workload.T4.ServerFqdn)) {
        $t4Marker = Read-DemoVmJsonFile -Path $paths.T4Marker
        $adminRole = [string]$t4Marker['adminRole']
        if ($adminRole -and (Test-DemoVmNameResolve -HostName $workload.T4.ServerFqdn)) {
            $t4 = Invoke-DemoVmRunnerSetup -DotNetExe $paths.DotNetExe -RunnerDll $paths.RunnerDll -Target 'T4' -Server $workload.T4.ServerFqdn -User $adminRole -RunnerRole $workload.T4.RunnerRole -TimeoutSeconds 900
            $record.setup['T4'] = [ordered]@{ status = $t4.Status; utc = (Get-DemoVmUtcNow); message = $t4.Message }
            if ($t4.Status -ne 'Pass') {
                $warnings += ('T4: {0}' -f $t4.Message)
            }
        }
        else {
            $record.setup['T4'] = [ordered]@{ status = 'Warning'; utc = (Get-DemoVmUtcNow); message = ('{0} does not resolve, or t4-workload.json names no administrator role.' -f $workload.T4.ServerFqdn) }
            $warnings += ('T4 ({0}) was not updated: it does not resolve or t4-workload.json names no administrator role. Enable-DemoT4Workload sets it up again.' -f $workload.T4.ServerFqdn)
        }
    }

    if (-not (Test-Path -LiteralPath $paths.RunnerRoot)) {
        New-Item -ItemType Directory -Path $paths.RunnerRoot -Force | Out-Null
    }
    Copy-Item -LiteralPath ([System.IO.Path]::Combine($Context.BundleRoot, 'vm', 'bootstrap', 'Start-DemoWorkload.ps1')) -Destination $paths.Wrapper -Force
    Write-DemoVmWorkloadInstall -Root $root -Record $record
    Register-DemoVmWorkloadTask -Root $root
    Start-DemoVmWorkload -Confirm:$false
    Remove-DemoVmOldRunner -Root $root -KeepSha256 $workload.RunnerSha256 -Confirm:$false
    return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage $warnings)
}

function Get-DemoSqlVmAssociatedService {
    # The configured associated services that exist on this VM (none once their features are uninstalled).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $found = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($name in @($Context.Config.AssociatedServices.ServiceNames)) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service) {
            $found.Add($service)
        }
    }
    return $found.ToArray()
}

function Test-DemoSqlVmAssociatedServiceState {
    # True when each configured associated service is gone or stopped and disabled. The uninstall is best effort
    # and isn't part of the check, so a failed uninstall never blocks the bootstrap.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    foreach ($service in @(Get-DemoSqlVmAssociatedService -Context $Context)) {
        if ([string]$service.Status -ne 'Stopped' -or [string]$service.StartType -ne 'Disabled') {
            return $false
        }
    }
    return $true
}

function Disable-DemoSqlVmService {
    # Sets one service to Disabled and stops it, doing only what's needed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Service
    )

    if ([string]$Service.StartType -ne 'Disabled') {
        Set-Service -Name $Service.Name -StartupType Disabled
    }
    if ([string]$Service.Status -ne 'Stopped') {
        Stop-Service -Name $Service.Name -Force
    }
}

function Invoke-DemoSqlVmFeatureUninstall {
    # Runs SQL Server setup quietly to uninstall the associated features and waits for it. Returns the exit code, or
    # $null when setup was still running after TimeoutMinutes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Settings
    )

    $arguments = @('/QUIET', '/ACTION=Uninstall', ('/FEATURES={0}' -f $Settings.Features), ('/INSTANCENAME={0}' -f $Settings.InstanceName))
    $process = Start-Process -FilePath $Settings.SetupPath -ArgumentList $arguments -PassThru -WindowStyle Hidden
    # Reading the handle now keeps ExitCode available after the process ends.
    $null = $process.Handle
    if (-not $process.WaitForExit([int]$Settings.TimeoutMinutes * 60000)) {
        return $null
    }
    return [int]$process.ExitCode
}

function Get-DemoSqlVmSetupFinalResult {
    # The "Final result" line of SQL Server setup's Summary.txt, or '' when it can't be read.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }
    $line = @(Get-Content -LiteralPath $Path | Where-Object { $_ -match '^\s*Final result:\s*(.+?)\s*$' } | Select-Object -First 1)
    if ($line.Count -eq 0 -or [string]$line[0] -notmatch '^\s*Final result:\s*(.+?)\s*$') {
        return ''
    }
    return $Matches[1]
}

function Test-DemoSqlVmInventoryRefreshed {
    # True unless the associated features are gone and the SQL IaaS Agent hasn't been restarted since, which unified
    # inventory needs before it drops their instance resources. Features that are still installed (no uninstall, or
    # a failed one, which is only a warning) don't need it.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $settings = $Context.Config.AssociatedServices
    if (-not $settings.Uninstall -or @(Get-DemoSqlVmAssociatedService -Context $Context).Count -gt 0) {
        return $true
    }
    return (Test-Path -LiteralPath (Join-Path -Path $Context.Root -ChildPath $settings.InventoryMarker))
}

function Restart-DemoSqlVmIaasAgent {
    # Restarts the SQL IaaS Agent service (the main service of the SQL IaaS Agent extension,
    # https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-agent-extension-troubleshoot-known-issues)
    # so it discovers the instances again, then records the attempt for Test-DemoSqlVmInventoryRefreshed. A service
    # that isn't running is left alone: it discovers the instances when the extension starts it. Returns a warning
    # when the restart fails; it never fails the step.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $settings = $Context.Config.AssociatedServices
    $name = [string]$settings.AgentServiceName
    if (-not $PSCmdlet.ShouldProcess($name, 'Restart the SQL IaaS Agent service so unified inventory drops the uninstalled features')) {
        return $null
    }
    $warning = $null
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        $action = 'Absent'
    }
    elseif ([string]$service.Status -ne 'Running') {
        $action = 'NotRunning'
    }
    else {
        try {
            Restart-Service -Name $name -Force
            $action = 'Restarted'
        }
        catch {
            $action = 'Failed'
            $warning = 'The SQL IaaS Agent service {0} couldn''t be restarted ({1}), so unified inventory may keep listing Analysis Services and Integration Services until it restarts.' -f $name, $_.Exception.Message
        }
    }
    $record = [ordered]@{ agentService = $name; action = $action; utc = [DateTime]::UtcNow.ToString('o') }
    [System.IO.File]::WriteAllText((Join-Path -Path $Context.Root -ChildPath $settings.InventoryMarker), ($record | ConvertTo-Json -Compress))
    Write-DemoVmLog -Message ('The associated features are gone; SQL IaaS Agent service {0}: {1}.' -f $name, $action)
    return $warning
}

function Disable-DemoSqlVmAssociatedService {
    # Stops and disables the associated services, then, with Uninstall, removes their features with the image's
    # setup media. Live on 2026-10-21 the uninstall took about 2 minutes, passed, removed all four services, and
    # left the engine and ContosoCare untouched. Once the features are gone, it restarts the SQL IaaS Agent so
    # unified inventory drops them (Restart-DemoSqlVmIaasAgent). Anything short of that is a warning, never a
    # failed step; deploy.ps1's validation fails when inventory still lists them (T1.SQLVM.ASSOCIATEDSERVICES).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $settings = $Context.Config.AssociatedServices
    $services = @(Get-DemoSqlVmAssociatedService -Context $Context)
    foreach ($service in $services) {
        Disable-DemoSqlVmService -Service $service
    }
    if ($services.Count -gt 0) {
        Write-DemoVmLog -Message ('Stopped and disabled {0} associated service(s): {1}.' -f $services.Count, (@($services | ForEach-Object { $_.Name }) -join ', '))
    }
    if (-not $settings.Uninstall) {
        return
    }
    if ($services.Count -eq 0) {
        # Uninstalled by an earlier run that didn't restart the agent (or never installed): inventory must still see it.
        if (-not (Test-DemoSqlVmInventoryRefreshed -Context $Context)) {
            $agentWarning = Restart-DemoSqlVmIaasAgent -Context $Context
            if ($agentWarning) {
                return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage $agentWarning)
            }
        }
        return
    }
    $keep = 'The services stay stopped and disabled, and unified inventory keeps listing Analysis Services and Integration Services as SQL Server instances.'
    if (-not (Test-Path -LiteralPath $settings.SetupPath)) {
        return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage ('The image has no SQL Server setup media at {0}, so the features weren''t uninstalled. {1}' -f $settings.SetupPath, $keep))
    }
    $exitCode = Invoke-DemoSqlVmFeatureUninstall -Settings $settings
    $final = Get-DemoSqlVmSetupFinalResult -Path $settings.SummaryPath
    $left = @(Get-DemoSqlVmAssociatedService -Context $Context)
    $warnings = @()
    if ($left.Count -eq 0) {
        $agentWarning = Restart-DemoSqlVmIaasAgent -Context $Context
        if ($agentWarning) {
            $warnings += $agentWarning
        }
    }
    if ($null -eq $exitCode) {
        return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage (@('SQL Server setup was still uninstalling {0} after {1} minutes. {2}' -f $settings.Features, $settings.TimeoutMinutes, $keep) + $warnings))
    }
    if ($exitCode -notin 0, 3010 -or $final -notlike 'Passed*' -or $left.Count -gt 0) {
        return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage (@('Uninstalling {0} didn''t pass (exit code {1}, final result "{2}", {3} service(s) left; see {4}). {5}' -f $settings.Features, $exitCode, $final, $left.Count, $settings.SummaryPath, $keep) + $warnings))
    }
    Write-DemoVmLog -Message ('Uninstalled {0} with SQL Server setup (exit code {1}, final result {2}).' -f $settings.Features, $exitCode, $final)
    if ($exitCode -eq 3010) {
        $warnings = @('SQL Server setup asked for a restart to finish removing Analysis Services and Integration Services; the nightly shutdown or the next start completes it.') + $warnings
    }
    if ($warnings.Count -gt 0) {
        return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage $warnings)
    }
}

function Get-DemoSqlVmStepPlan {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $plan = @(
        @{ Name = 'DataDisk'
            When = { param($Step) Test-DemoSqlVmHasDataDisk -Context $Step.Context }
            NotSelectedMessage = 'No separate data disk (dataDiskSku None, the lowest-cost default): ContosoCare uses SQL Server''s default data and log folders on the OS disk.'
            Test = { param($Step) Test-DemoSqlVmDataDisk -Context $Step.Context }
            Set = { param($Step) Initialize-DemoSqlVmDataDisk -Context $Step.Context } }
        @{ Name = 'SqlService'
            Test = { param($Step) [string](Get-Service -Name $Step.Context.Config.Sql.ServiceName).Status -eq 'Running' }
            Set = { param($Step)
                Set-Service -Name $Step.Context.Config.Sql.ServiceName -StartupType Automatic
                Start-Service -Name $Step.Context.Config.Sql.ServiceName } }
        @{ Name = 'AssociatedServices'
            Test = { param($Step) (Test-DemoSqlVmAssociatedServiceState -Context $Step.Context) -and (Test-DemoSqlVmInventoryRefreshed -Context $Step.Context) }
            Set = { param($Step) Disable-DemoSqlVmAssociatedService -Context $Step.Context } }
        @{ Name = 'SqlAdminAccess'; MaxAttempts = 2
            Test = { Test-DemoSqlVmSysadmin }
            Set = { param($Step) Grant-DemoSqlVmSysadmin -Context $Step.Context } }
        @{ Name = 'ConfigureSql'
            Test = { param($Step) Test-DemoSqlVmDatabase -Context $Step.Context }
            Set = { param($Step) Initialize-DemoSqlVmDatabase -Context $Step.Context } }
        @{ Name = 'SeedDatabase'
            Test = { param($Step) Test-DemoSqlVmDatabase -Context $Step.Context -Seeded }
            Set = { param($Step) Invoke-DemoVmSql -Database 'ContosoCare' -TimeoutSeconds 3600 -Query ('EXEC demo.usp_seed_contosocare @scale = {0};' -f $Step.Context.SeedScale) | Out-Null } }
        @{ Name = 'WorkloadRunner'; MaxAttempts = 3
            When = { param($Step) $Step.Context.Workload.Selected }
            NotSelectedMessage = 'No workload runner came with this deployment: deploy.ps1 publishes it, sends it with Send-DemoWorkloadRunner, and passes its SHA-256 to the template (ADR 0010).'
            Test = { param($Step) Test-DemoSqlVmWorkload -Context $Step.Context }
            Set = { param($Step) Install-DemoSqlVmWorkload -Context $Step.Context } }
    )
    foreach ($step in $plan) {
        $step['Context'] = $Context
    }
    return $plan
}

function Get-DemoSqlVmHealthDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $detail = [ordered]@{ dataDiskTier = $Context.DataDiskTier; sql = [ordered]@{ running = $false } }
    $service = Get-Service -Name $Context.Config.Sql.ServiceName -ErrorAction SilentlyContinue
    $running = $service -and [string]$service.Status -eq 'Running'
    if ($running) {
        $row = @(Invoke-DemoVmSql -Query "SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition, CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) AS version, DB_ID(N'ContosoCare') AS database_id")[0]
        $detail.sql = [ordered]@{ running = $true; edition = [string]$row.edition; version = [string]$row.version; contosoCare = ($null -ne $row.database_id) }
    }
    if ($running -or (Test-DemoSqlVmHasDataDisk -Context $Context)) {
        $folders = Get-DemoSqlVmFolder -Context $Context
        if ($folders) {
            $detail.dataFolder = $folders.Data
        }
    }
    if ($Context.Workload.Selected) {
        $detail.workload = Get-DemoVmWorkloadHealth -Root $Context.Root
    }
    return $detail
}

function Invoke-DemoSqlVmBootstrap {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [string] $BundleRoot
    )

    Initialize-DemoVmContext -Root $StateRoot -Role 'SqlVm' -BundleRoot $BundleRoot | Out-Null
    $lock = Enter-DemoVmLock
    if ($null -eq $lock) {
        return 'Locked'
    }
    try {
        $settings = Get-DemoVmSetting
        $context = Get-DemoSqlVmContext -BundleRoot $BundleRoot -Settings $settings
        $plan = Get-DemoSqlVmStepPlan -Context $context
        return (Invoke-DemoVmStateMachine -Step $plan -Generation ([string]$settings['generation']) -HealthDetail { Get-DemoSqlVmHealthDetail -Context $context })
    }
    finally {
        Exit-DemoVmLock -Lock $lock
    }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $outcome = Invoke-DemoSqlVmBootstrap -StateRoot $Root -BundleRoot $script:SqlVmBundleRoot
        Write-DemoVmLog -Message ('Run finished: {0}.' -f $outcome)
        exit 0
    }
    catch {
        Write-DemoVmLog -Level 'Error' -Message ('Run failed: {0}' -f $_.Exception.Message)
        exit 1
    }
}
