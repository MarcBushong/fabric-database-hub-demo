<#
.SYNOPSIS
T2 host state machine for archost01 (ADR 0003): Hyper-V, NAT, DNS forwarder, guest build, SQL Server, and
the Arc and setup-wizard wait states.

.DESCRIPTION
Runs as SYSTEM from the scheduled task DbHubDemo-Bootstrap, at startup and every 5 minutes; a lock file
prevents overlapping runs. Each step checks before it acts, so runs resume after restarts and re-runs
converge. Progress is in C:\ProgramData\DbHubDemo\state.json and health.json. Windows PowerShell 5.1.

Install modes (t2SqlInstallMode, ADR 0006):
- JumpstartImage (the default since 2026-11-05): GuestImage downloads Arc Jumpstart's prebuilt SQL Server 2022 Standard
  guest disk and verifies it (its length and the blob's Content-MD5, fail closed; another image than the tested one is a
  warning), GuestVm creates the guest with its network adapter not connected, and GuestFirstBoot makes it arcsql01 over
  PowerShell Direct (the published password replaced, the computer and SQL Server renamed, the sysadmin group, SQL logins
  disabled, the sample database, extra services, and C:\Jumpstart removed), then connects it. JumpstartImageCheck then
  stops T2 with the cause when the guest isn't SQL Server 2022 Standard on the default instance; nothing falls back by
  itself. Then WaitingForArcOnboarding, as in the unattended modes.
- ProductKey and Developer: unattended setup, then WaitingForArcOnboarding until the orchestrator writes
  arc-onboarded.json (Phase 7).
- PaygWizard: WaitingForArcOnboarding first; once Arc is connected, GuidedSetup prepares the guided stop (Phase 28):
  SQL Server setup pre-filled from a configuration file with a logon task in the guest, and Virtual Machine Connection
  at an administrator's sign-in to this host. SqlSetupWizard then reports Manual action required; while deploy.ps1 waits
  for a person (its request in guided-setup-request.json), the guest signs itself in once and opens the setup. The host
  checks what was installed (Standard, the default instance, the Azure extension), shows the documented fix when it's
  wrong, and once it's right cleans up: automatic sign-in off, its LSA secret and Winlogon values gone, the guest
  password rotated, the console signed out. Invoke-DemoHostGuidedSetupGuard runs that cleanup before every pass when no
  person is expected any more.
In every mode, GuestSignInCleanup then removes the sign-in data that Arc onboarding and, in PaygWizard mode, the
setup wizard's interactive sign-in leave in the guest and on the host, and verifies that none remains; the build
stops there if any remains (ADR 0009). It runs again whenever a new bundle generation arrives.
Then the database is configured and seeded, and the WorkloadRunner step installs the runner and the .NET
runtime in the guest and starts its activity host for T2 (ADR 0010), once the guest's SQL Server is ready.
In every mode, the GuestSource step first refuses a mode whose source (the Jumpstart image or the build) differs from an
existing guest's, and after a pass that finds the host Ready, Invoke-DemoHostEvaluationGuard extends an evaluation
guest's Windows evaluation when it runs low (slmgr.vbs /rearm, at most once a day, never while an activity profile runs).

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.
#>
[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HostBundleRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Vm.psd1') -Force
. (Join-Path -Path $PSScriptRoot -ChildPath 'HostPlatform.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'HostSteps.ps1')
# The sign-in data sweep (ADR 0009); dot-sourcing only defines its functions.
. (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-DemoSignInResidue.ps1')
foreach ($guestScript in @('GuestVhdx.ps1', 'GuestVm.ps1', 'GuestHardening.ps1', 'GuestSql.ps1', 'GuestWorkload.ps1', 'GuestSetup.ps1', 'GuestJumpstart.ps1')) {
    . ([System.IO.Path]::Combine($script:HostBundleRoot, 'vm', 'hyperv-guest', $guestScript))
}

function Get-DemoHostContext {
    <#
    .SYNOPSIS
    Everything the steps need: settings.json, vm/dsc/host.psd1 and guest.psd1, and derived paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [string] $BundleRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Settings
    )

    $hostConfig = Import-PowerShellDataFile -Path ([System.IO.Path]::Combine($BundleRoot, 'vm', 'dsc', 'host.psd1'))
    $guestConfig = Import-PowerShellDataFile -Path ([System.IO.Path]::Combine($BundleRoot, 'vm', 'dsc', 'guest.psd1'))
    $guestSettings = $Settings['guest']
    if ($null -eq $guestSettings) {
        $guestSettings = @{}
    }
    $guestName = [string]$guestConfig.Name
    if ($guestSettings.Contains('name') -and $guestSettings['name']) {
        $guestName = [string]$guestSettings['name']
    }
    $mode = [string]$Settings['t2SqlInstallMode']
    if (-not $mode) {
        $mode = 'JumpstartImage'
    }
    $context = @{
        Root           = $StateRoot
        BundleRoot     = $BundleRoot
        Settings       = $Settings
        Host           = $hostConfig
        Guest          = $guestConfig
        GuestName      = $guestName
        Mode           = $mode
        DataDiskTier   = [string]$Settings['dataDiskTier']
        VCpu           = [int]$guestSettings['vcpus']
        MemoryGiB      = [int]$guestSettings['memoryGiB']
        VhdxGB         = [int]$guestSettings['vhdxGB']
        SeedScale      = [int]$Settings['seedScale']
        SeedVersion    = 1
        SecretPath     = [System.IO.Path]::Combine($StateRoot, 'protected', 'guest-administrator.bin')
        ProductKeyPath = [System.IO.Path]::Combine($StateRoot, 'protected', 'sql-product-key.bin')
        ArcMarkerPath  = Join-Path -Path $StateRoot -ChildPath $hostConfig.ArcMarkerFile
        StatusQuery    = ''
        VhdxPath       = ''
        Workload       = Get-DemoVmWorkloadSetting -Settings $Settings
    }
    foreach ($key in @('VCpu', 'MemoryGiB', 'VhdxGB', 'SeedScale')) {
        if ($context[$key] -le 0) {
            throw ('settings.json is missing a positive value for {0}.' -f $key)
        }
    }
    $statusQueryPath = [System.IO.Path]::Combine($BundleRoot, 'database', 'common', '900-status.sql')
    if (Test-Path -LiteralPath $statusQueryPath) {
        $context.StatusQuery = [System.IO.File]::ReadAllText($statusQueryPath)
    }
    return $context
}

function Get-DemoHostVhdxPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $vmFolder = Get-DemoHostDataPath -Context $Context -Kind 'Vms'
    return [System.IO.Path]::Combine($vmFolder, $Context.GuestName, ($Context.GuestName + '.vhdx'))
}

function Get-DemoHostStepPlan {
    <#
    .SYNOPSIS
    The ordered steps from ADR 0003. Mode-specific steps use When, so the plan is the same list in every mode.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $unattendedModes = @('ProductKey', 'Developer')
    $buildModes = @('PaygWizard', 'ProductKey', 'Developer')
    $plan = @(
        @{ Name = 'NestedVirtualization'
            Test = { Test-DemoNestedVirtualization }
            Set = { Confirm-DemoNestedVirtualization } }
        @{ Name = 'HyperVRole'
            Test = { Test-DemoHostFeature -Name 'Hyper-V' }
            Set = { Install-DemoHostFeature -Name 'Hyper-V' } }
        @{ Name = 'DnsServerRole'
            Test = { Test-DemoHostFeature -Name 'DNS' }
            Set = { Install-DemoHostFeature -Name 'DNS' } }
        @{ Name = 'NatNetwork'
            Test = { param($Step) Test-DemoHostNatNetwork -HostConfig $Step.Context.Host }
            Set = { param($Step) Initialize-DemoHostNatNetwork -HostConfig $Step.Context.Host } }
        @{ Name = 'DnsForwarder'
            Test = { param($Step) Test-DemoHostDnsForwarder -HostConfig $Step.Context.Host }
            Set = { param($Step) Initialize-DemoHostDnsForwarder -HostConfig $Step.Context.Host } }
        @{ Name = 'GuestSource'
            Test = { param($Step) (Get-DemoHostGuestSourceState -Context $Step.Context).Ok }
            Set = { param($Step) Get-DemoHostGuestSourceFailure -Context $Step.Context } }
        @{ Name = 'DataDisk'
            Test = { param($Step) Test-DemoHostStorage -Context $Step.Context }
            Set = { param($Step) Initialize-DemoHostStorage -Context $Step.Context } }
        @{ Name = 'GuestOsMedia'; MaxAttempts = 5; Mode = $buildModes
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'JumpstartImage mode downloads Arc Jumpstart''s prebuilt guest instead of the Windows Server media.'
            Test = { param($Step) Test-DemoHostMedia -Context $Step.Context -MediaName $Step.Context.Host.Media.WindowsServer }
            Set = { param($Step) Save-DemoHostMedia -Context $Step.Context -MediaName $Step.Context.Host.Media.WindowsServer } }
        @{ Name = 'GuestVhdx'; Mode = $buildModes
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'JumpstartImage mode uses Arc Jumpstart''s prebuilt guest disk.'
            Test = { param($Step) Test-DemoGuestVhdx -VhdxPath (Get-DemoHostVhdxPath -Context $Step.Context) }
            Set = { param($Step)
                $Step.Context.VhdxPath = Get-DemoHostVhdxPath -Context $Step.Context
                Build-DemoHostGuestDisk -Context $Step.Context
                Set-DemoHostGuestSource -Context $Step.Context -Source 'Build' -Confirm:$false } }
        @{ Name = 'GuestImage'; MaxAttempts = 5; Mode = @('JumpstartImage')
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'Only JumpstartImage mode uses Arc Jumpstart''s prebuilt guest disk; the other modes build the guest.'
            Test = { param($Step) Test-DemoJumpstartImage -Context $Step.Context -VhdxPath (Get-DemoHostVhdxPath -Context $Step.Context) }
            Set = { param($Step) Save-DemoJumpstartImage -Context $Step.Context -VhdxPath (Get-DemoHostVhdxPath -Context $Step.Context) } }
        @{ Name = 'GuestVm'
            Test = { param($Step) Test-DemoGuestVm -Name $Step.Context.GuestName -VCpu $Step.Context.VCpu -MemoryGiB $Step.Context.MemoryGiB }
            Set = { param($Step)
                $c = $Step.Context
                $vhdx = Get-DemoHostVhdxPath -Context $c
                Initialize-DemoGuestVm -Name $c.GuestName -VhdxPath $vhdx -VmFolder (Get-DemoHostDataPath -Context $c -Kind 'Vms') -SwitchName $c.Host.SwitchName -VCpu $c.VCpu -MemoryGiB $c.MemoryGiB -Disconnected:($c.Mode -eq 'JumpstartImage') } }
        @{ Name = 'GuestFirstBoot'; MaxAttempts = 3; Mode = @('JumpstartImage')
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'Only JumpstartImage mode makes Arc Jumpstart''s guest arcsql01 at its first boot; the build names the guest in its unattend file.'
            Test = { param($Step) Test-DemoJumpstartFirstBoot -Context $Step.Context }
            Set = { param($Step) Invoke-DemoJumpstartFirstBoot -Context $Step.Context } }
        @{ Name = 'GuestOnline'
            Test = { param($Step) Test-DemoHostGuestReachable -Context $Step.Context }
            Set = { param($Step)
                $credential = Get-DemoGuestCredential -SecretPath $Step.Context.SecretPath -UserName $Step.Context.Guest.AdministratorName
                if (-not (Wait-DemoGuestOnline -Name $Step.Context.GuestName -Credential $credential -TimeoutMinutes $Step.Context.Host.GuestBootTimeoutMinutes)) {
                    throw 'The guest did not answer over PowerShell Direct in time; first-boot setup may still be running.'
                } } }
        @{ Name = 'GuestHardening'
            Test = { param($Step)
                if (-not (Test-DemoHostGuestReachable -Context $Step.Context)) {
                    return $false
                }
                $credential = Get-DemoGuestCredential -SecretPath $Step.Context.SecretPath -UserName $Step.Context.Guest.AdministratorName
                Test-DemoGuestHardening -Name $Step.Context.GuestName -Credential $credential -Guest $Step.Context.Guest }
            Set = { param($Step)
                if (-not (Wait-DemoHostGuest -Context $Step.Context)) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'Waiting for the guest to start.')
                }
                $credential = Get-DemoGuestCredential -SecretPath $Step.Context.SecretPath -UserName $Step.Context.Guest.AdministratorName
                Invoke-DemoGuestHardening -Name $Step.Context.GuestName -Credential $credential -Guest $Step.Context.Guest } }
        @{ Name = 'SqlMedia'; MaxAttempts = 5; Mode = $buildModes
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'The Jumpstart guest comes with SQL Server 2022 Standard installed.'
            Test = { param($Step) (Test-DemoHostGuestReachable -Context $Step.Context) -and (Test-DemoHostGuestSqlMedia -Context $Step.Context) }
            Set = { param($Step)
                if (-not (Wait-DemoHostGuest -Context $Step.Context)) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'Waiting for the guest to start.')
                }
                Copy-DemoHostGuestSqlMedia -Context $Step.Context } }
        @{ Name = 'GuestWebView2'; Mode = @('PaygWizard')
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'Only the PaygWizard guided stop asks for setup''s Azure sign-in, and installs the WebView2 runtime before it.'
            Test = { param($Step) (Test-DemoHostGuestReachable -Context $Step.Context) -and (Test-DemoHostGuestWebView2 -Context $Step.Context) }
            Set = { param($Step)
                if (-not (Wait-DemoHostGuest -Context $Step.Context)) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'Waiting for the guest to start.')
                }
                Install-DemoHostGuestWebView2 -Context $Step.Context } }
        @{ Name = 'SqlUnattendedInstall'; MaxAttempts = 2; Mode = $unattendedModes
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'PaygWizard mode installs SQL Server with the setup wizard after Arc onboarding; the Jumpstart guest comes with it installed.'
            Test = { param($Step) (Test-DemoHostGuestReachable -Context $Step.Context) -and (Test-DemoHostSqlEdition -Context $Step.Context) }
            Set = { param($Step)
                if (-not (Wait-DemoHostGuest -Context $Step.Context)) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'Waiting for the guest to start.')
                }
                Install-DemoHostGuestSql -Context $Step.Context } }
        @{ Name = 'JumpstartImageCheck'; MaxAttempts = 3; Mode = @('JumpstartImage')
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'Only JumpstartImage mode checks a prebuilt guest before Arc onboarding.'
            Test = { param($Step) (Test-DemoHostGuestReachable -Context $Step.Context) -and (Test-DemoJumpstartGuest -Context $Step.Context) }
            Set = { param($Step)
                if (-not (Wait-DemoHostGuest -Context $Step.Context)) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'Waiting for the guest to start.')
                }
                Invoke-DemoJumpstartImageCheck -Context $Step.Context } }
        @{ Name = 'ArcOnboarding'; Mode = @('ProductKey', 'Developer', 'JumpstartImage')
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'PaygWizard mode waits for Arc before the setup wizard.'
            Test = { param($Step) Test-DemoArcOnboarded -MarkerPath $Step.Context.ArcMarkerPath -MachineName $Step.Context.GuestName -GuestVmId (Get-DemoHostGuestVmId -Name $Step.Context.GuestName) }
            Set = { New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForArcOnboarding' -Message 'SQL Server is installed in arcsql01. Waiting for the orchestrator to onboard it to Azure Arc with the caller''s token (deploy.ps1 stage 5, ADR 0005); it writes arc-onboarded.json when the machine is Connected.' } }
        @{ Name = 'ArcOnboardingBeforeWizard'; Mode = @('PaygWizard')
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'ProductKey, Developer, and JumpstartImage modes onboard Arc once SQL Server is in place.'
            Test = { param($Step) Test-DemoArcOnboarded -MarkerPath $Step.Context.ArcMarkerPath -MachineName $Step.Context.GuestName -GuestVmId (Get-DemoHostGuestVmId -Name $Step.Context.GuestName) }
            Set = { New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForArcOnboarding' -Message 'Waiting for the orchestrator to onboard arcsql01 to Azure Arc before the setup-wizard step, so the wizard finds the existing connection (deploy.ps1 stage 5, ADR 0005, ADR 0006).' } }
        @{ Name = 'GuidedSetup'; Mode = @('PaygWizard')
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'ProductKey and Developer modes install SQL Server unattended; the Jumpstart guest comes with it installed.'
            Test = { param($Step) (Test-DemoHostGuestReachable -Context $Step.Context) -and (Test-DemoHostGuidedSetup -Context $Step.Context) }
            Set = { param($Step)
                if (-not (Wait-DemoHostGuest -Context $Step.Context)) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'Waiting for the guest to start.')
                }
                Initialize-DemoHostGuidedSetup -Context $Step.Context } }
        @{ Name = 'SqlSetupWizard'; Mode = @('PaygWizard')
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'ProductKey and Developer modes install SQL Server unattended; the Jumpstart guest comes with it installed.'
            Test = { param($Step) (Test-DemoHostGuestReachable -Context $Step.Context) -and (Test-DemoHostGuidedSetupDone -Context $Step.Context) }
            Set = { param($Step)
                if (-not (Wait-DemoHostGuest -Context $Step.Context)) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'Waiting for the guest to start.')
                }
                Invoke-DemoHostGuidedSetupStep -Context $Step.Context } }
        @{ Name = 'GuestSignInCleanup'
            Test = { param($Step) (Test-DemoHostGuestReachable -Context $Step.Context) -and (Test-DemoHostGuestSignInClean -Context $Step.Context) }
            Set = { param($Step)
                if (-not (Wait-DemoHostGuest -Context $Step.Context)) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'Waiting for the guest to start.')
                }
                Clear-DemoHostGuestSignIn -Context $Step.Context } }
        @{ Name = 'ConfigureSql'
            Test = { param($Step) (Test-DemoHostGuestReachable -Context $Step.Context) -and (Test-DemoHostDatabase -Context $Step.Context) }
            Set = { param($Step)
                if (-not (Wait-DemoHostGuest -Context $Step.Context)) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'Waiting for the guest to start.')
                }
                Initialize-DemoHostDatabase -Context $Step.Context } }
        @{ Name = 'SeedDatabase'
            Test = { param($Step) (Test-DemoHostGuestReachable -Context $Step.Context) -and (Test-DemoHostDatabase -Context $Step.Context -Seeded) }
            Set = { param($Step)
                if (-not (Wait-DemoHostGuest -Context $Step.Context)) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'Waiting for the guest to start.')
                }
                Invoke-DemoHostSeed -Context $Step.Context } }
        @{ Name = 'WorkloadRunner'; MaxAttempts = 3
            When = { param($Step) $Step.Context.Workload.Selected }
            NotSelectedMessage = 'No workload runner came with this deployment: deploy.ps1 publishes it, sends it with Send-DemoWorkloadRunner, and passes its SHA-256 to the template (ADR 0010).'
            Test = { param($Step) Test-DemoHostGuestWorkload -Context $Step.Context }
            Set = { param($Step) Install-DemoHostGuestWorkload -Context $Step.Context } }
    )
    foreach ($step in $plan) {
        $step['Context'] = $Context
    }
    return $plan
}

function Get-DemoHostHealthDetail {
    <#
    .SYNOPSIS
    Host and guest facts for health.json: size, free space on the guest's drive, the guest's source (and, in
    JumpstartImage mode, the image it came from), its state read over PowerShell Direct, its Windows license (evaluation
    days left only for an evaluation), the SQL Server edition, Arc onboarding, and the evaluation guard's last check.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $detail = [ordered]@{
        installMode  = $Context.Mode
        dataDiskTier = $Context.DataDiskTier
        host         = Get-DemoHostInstanceInfo
        storage      = Get-DemoHostStorageDetail -Context $Context
        arcOnboarded = Test-DemoArcOnboarded -MarkerPath $Context.ArcMarkerPath -MachineName $Context.GuestName -GuestVmId (Get-DemoHostGuestVmId -Name $Context.GuestName)
        guest        = [ordered]@{ name = $Context.GuestName; state = 'NotCreated' }
    }
    $source = Read-DemoVmJsonFile -Path (Get-DemoHostGuestSourcePath -Context $Context)
    if ($null -ne $source) {
        $detail.guestSource = [ordered]@{ source = $source['source']; installMode = $source['installMode'] }
    }
    if ($Context.Mode -eq 'JumpstartImage') {
        $detail.jumpstart = Get-DemoJumpstartHealthDetail -Context $Context
    }
    $evaluation = Read-DemoVmJsonFile -Path (Join-Path -Path $Context.Root -ChildPath 'guest-evaluation.json')
    if ($null -ne $evaluation) {
        $detail.evaluation = [ordered]@{ checkedUtc = $evaluation['checkedUtc']; action = $evaluation['action']; reason = $evaluation['reason']; lastRearmUtc = $evaluation['lastRearmUtc'] }
    }
    if ($Context.Mode -eq 'PaygWizard') {
        $detail.guidedSetup = Get-DemoHostGuidedSetupDetail -Context $Context
    }
    $vm = Get-VM -Name $Context.GuestName -ErrorAction SilentlyContinue
    if ($vm) {
        $detail.guest.state = [string]$vm.State
        $detail.guest.vcpus = [int]$vm.ProcessorCount
        $detail.guest.memoryGiB = [int]([int64]$vm.MemoryStartup / 1GB)
        $detail.guest.uptimeMinutes = [int]$vm.Uptime.TotalMinutes
        if ([string]$vm.State -eq 'Running' -and (Test-DemoHostGuestReachable -Context $Context)) {
            $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
            $inGuest = Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ScriptBlock {
                $license = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" | Select-Object -First 1
                $graceDays = $null
                $description = ''
                if ($license) {
                    $description = [string]$license.Description
                    # Only an evaluation (the TIMEBASED_EVAL channel) has days left; another channel's grace isn't an expiry.
                    if ($description -match 'TIMEBASED_EVAL') {
                        $graceDays = [int]([double]$license.GracePeriodRemaining / 1440)
                    }
                }
                $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
                $freeGiB = $null
                if ($drive) {
                    $freeGiB = [Math]::Round([double]$drive.FreeSpace / 1GB, 1)
                }
                [pscustomobject]@{ ComputerName = $env:COMPUTERNAME; EvaluationDaysLeft = $graceDays; License = $description; FreeGiB = $freeGiB }
            }
            $detail.guest.computerName = [string]$inGuest.ComputerName
            $detail.guest.evaluationDaysLeft = $inGuest.EvaluationDaysLeft
            $detail.guest.license = [string]$inGuest.License
            $detail.guest.freeGiB = $inGuest.FreeGiB
            $instance = Get-DemoGuestSqlInstance -Name $Context.GuestName -Credential $credential
            $detail.guest.sql = [ordered]@{ running = [bool]$instance.Running; edition = [string]$instance.Edition; version = [string]$instance.ProductVersion }
            if ($Context.Workload.Selected) {
                $guestWorkload = Get-DemoHostGuestWorkloadStatus -Context $Context
                if ($null -ne $guestWorkload) {
                    $detail.guest.workload = $guestWorkload.Health
                }
            }
        }
    }
    return $detail
}

function Invoke-DemoHostBootstrap {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [string] $BundleRoot
    )

    Initialize-DemoVmContext -Root $StateRoot -Role 'ArcHost' -BundleRoot $BundleRoot | Out-Null
    $lock = Enter-DemoVmLock
    if ($null -eq $lock) {
        return 'Locked'
    }
    try {
        $settings = Get-DemoVmSetting
        $context = Get-DemoHostContext -StateRoot $StateRoot -BundleRoot $BundleRoot -Settings $settings
        # The operator's clipboard helper for the PaygWizard step lives next to the state files.
        Copy-Item -LiteralPath ([System.IO.Path]::Combine($BundleRoot, 'vm', 'hyperv-guest', 'Copy-GuestCredential.ps1')) -Destination (Join-Path -Path $StateRoot -ChildPath 'Copy-GuestCredential.ps1') -Force
        $plan = Get-DemoHostStepPlan -Context $context
        if ($context.Mode -eq 'PaygWizard') {
            # The guided stop's cleanup always runs: armed automatic sign-in goes once no person is expected (Phase 28).
            Invoke-DemoHostGuidedSetupGuard -Context $context
        }
        $outcome = Invoke-DemoVmStateMachine -Step $plan -Generation ([string]$settings['generation']) -HealthDetail { Get-DemoHostHealthDetail -Context $context }
        if ($outcome -eq 'Ready') {
            # An evaluation guest's Windows evaluation, checked at most once a day; health.json shows it after the next pass.
            Invoke-DemoHostEvaluationGuard -Context $context
        }
        return $outcome
    }
    finally {
        Exit-DemoVmLock -Lock $lock
    }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $outcome = Invoke-DemoHostBootstrap -StateRoot $Root -BundleRoot $script:HostBundleRoot
        Write-DemoVmLog -Message ('Run finished: {0}.' -f $outcome)
        exit 0
    }
    catch {
        Write-DemoVmLog -Level 'Error' -Message ('Run failed: {0}' -f $_.Exception.Message)
        exit 1
    }
}
