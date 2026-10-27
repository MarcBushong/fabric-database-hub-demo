<#
.SYNOPSIS
EVALUATION ONLY. State machine for the opt-in fallback t2Mode = EvaluationOnlyAzureVm (ADR 0006): SQL Server
on the Azure VM arcsql01, onboarded to Azure Arc with Microsoft's evaluation procedure.

.DESCRIPTION
Used only when the nested-virtualization preflight fails and the operator opts in. Arc on an Azure VM is for
evaluation and testing only ("Evaluate Azure Arc-enabled servers on an Azure virtual machine",
https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine); every result for
this mode is labeled EVALUATION ONLY. Runs as SYSTEM from the scheduled task DbHubDemo-Bootstrap, at startup
and every 5 minutes, with a lock against overlapping runs. Windows PowerShell 5.1. Steps:
1. ArcEvaluationPrep: MSFT_ARC_TEST = true at machine level, and the Windows Firewall rule BlockAzureIMDS for
   169.254.169.254 and 169.254.169.253, as the procedure documents.
2. SqlMedia, then SqlUnattendedInstall (ProductKey and Developer) with the same setup switches as the nested
   guest (Get-DemoSqlSetupArgument), or, in PaygWizard mode, ArcOnboardingBeforeWizard and the documented
   setup-wizard step on this VM.
3. ArcOnboarding: waits in WaitingForArcOnboarding until configure-arc.ps1 has run
   Invoke-DemoArcOnboard.ps1 -Mode EvaluationOnlyAzureVm here and written arc-onboarded.json.
4. SqlAdminAccess, ConfigureSql, SeedDatabase: T1's local helpers with the arcsql01 database scripts.
5. DisableAzureGuestAgent, last: the procedure disables the Azure guest agent, but Run Command needs it, so it
   runs only after the marker is at least 15 minutes old, when the onboarding Run Command has reported back.
   Afterward Run Command (and health reads through it) no longer work on this VM; the Arc resources are
   checked through Azure Resource Manager.
Deviation, recorded in ADR 0006: the procedure also removes the VM's extensions first, which this demo can't
do, because Run Command is itself an extension and tenant policy may add others; the Azure guest agent is
disabled last instead, which stops them all.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.
#>
[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EvalStateRoot = $Root
$script:EvalBundleRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
# T1's local SQL Server helpers (dot-sourcing only defines them; it imports DbHubDemo.Vm), the Arc marker and
# product-key readers, and the shared setup switches.
. (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-SqlVmBootstrap.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'HostPlatform.ps1')
# The sign-in data sweep (ADR 0009); dot-sourcing only defines its functions.
. (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-DemoSignInResidue.ps1')
foreach ($guestScript in @('GuestVhdx.ps1', 'GuestSql.ps1')) {
    . ([System.IO.Path]::Combine($script:EvalBundleRoot, 'vm', 'hyperv-guest', $guestScript))
}

function Get-DemoEvalArcContext {
    <#
    .SYNOPSIS
    Everything the steps need: settings.json, vm/dsc/sqlvm.psd1 (SQL Server service names, for T1's helpers),
    guest.psd1 (setup switches), host.psd1 (media names, the marker file), and derived paths.
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

    $dsc = [System.IO.Path]::Combine($BundleRoot, 'vm', 'dsc')
    $hostConfig = Import-PowerShellDataFile -Path (Join-Path -Path $dsc -ChildPath 'host.psd1')
    $guestConfig = Import-PowerShellDataFile -Path (Join-Path -Path $dsc -ChildPath 'guest.psd1')
    $mode = [string]$Settings['t2SqlInstallMode']
    if (-not $mode) {
        $mode = 'PaygWizard'
    }
    $seedScale = [int]$Settings['seedScale']
    if ($seedScale -le 0) {
        throw 'settings.json is missing a positive seedScale.'
    }
    return @{
        Root                   = $StateRoot
        BundleRoot             = $BundleRoot
        Settings               = $Settings
        Mode                   = $mode
        MachineName            = [string]$guestConfig.Name
        Config                 = Import-PowerShellDataFile -Path (Join-Path -Path $dsc -ChildPath 'sqlvm.psd1')
        Guest                  = $guestConfig
        Host                   = $hostConfig
        DataDiskTier           = 'None'
        SeedScale              = $seedScale
        SeedVersion            = 1
        StatusQuery            = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($BundleRoot, 'database', 'common', '900-status.sql'))
        MediaFolder            = [string]$guestConfig.MediaFolder
        ProductKeyPath         = [System.IO.Path]::Combine($StateRoot, 'protected', 'sql-product-key.bin')
        ArcMarkerPath          = Join-Path -Path $StateRoot -ChildPath $hostConfig.ArcMarkerFile
        ImdsAddresses          = @('169.254.169.254', '169.254.169.253')
        ImdsRuleName           = 'BlockAzureIMDS'
        GuestAgentService      = 'WindowsAzureGuestAgent'
        GuestAgentDelayMinutes = 15
    }
}

function Test-DemoEvalArcPrep {
    # MSFT_ARC_TEST is set at machine level and BlockAzureIMDS blocks both IMDS addresses. Never throws.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    if ([string][Environment]::GetEnvironmentVariable('MSFT_ARC_TEST', 'Machine') -ne 'true') {
        return $false
    }
    try {
        $rule = Get-NetFirewallRule -Name $Context.ImdsRuleName -ErrorAction SilentlyContinue
        if (-not $rule -or [string]$rule.Enabled -ne 'True' -or [string]$rule.Action -ne 'Block' -or [string]$rule.Direction -ne 'Outbound') {
            return $false
        }
        $remote = @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)
        foreach ($address in $Context.ImdsAddresses) {
            if ($remote -notcontains $address) {
                return $false
            }
        }
        return $true
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The IMDS firewall rule could not be read: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Initialize-DemoEvalArcPrep {
    # The documented evaluation settings: MSFT_ARC_TEST, and an outbound block of 169.254.169.254 and .253.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    [Environment]::SetEnvironmentVariable('MSFT_ARC_TEST', 'true', [EnvironmentVariableTarget]::Machine)
    Get-NetFirewallRule -Name $Context.ImdsRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $Context.ImdsRuleName -DisplayName 'Block access to Azure IMDS' -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress $Context.ImdsAddresses | Out-Null
    return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage 'EVALUATION ONLY: this Azure VM is prepared for Azure Arc with Microsoft''s evaluation procedure, which isn''t supported for production (ADR 0006).')
}

function Get-DemoEvalSqlMediaFile {
    # The pinned SQL Server ISO for the install mode, under the media folder.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $name = $Context.Host.Media.SqlServer
    if ($Context.Mode -eq 'Developer') {
        $name = $Context.Host.Media.SqlDeveloper
    }
    $pin = Get-DemoVmMediaPin -Name $name -BundleRoot $Context.BundleRoot
    $fileName = [string]$pin['fileName']
    if (-not $fileName) {
        $fileName = $name + '.iso'
    }
    return [pscustomobject]@{
        Name   = $name
        Url    = [string]$pin['url']
        Sha256 = [string]$pin['sha256']
        Path   = Join-Path -Path $Context.MediaFolder -ChildPath $fileName
    }
}

function Save-DemoEvalSqlMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $media = Get-DemoEvalSqlMediaFile -Context $Context
    $download = Save-DemoVmDownload -Uri $media.Url -Path $media.Path -ExpectedSha256 $media.Sha256 -Name $media.Name
    if ($download.Warning) {
        return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage $download.Warning)
    }
}

function Mount-DemoEvalSqlMedia {
    # Mounts the SQL Server ISO (if needed) and returns its drive letter.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $media = Get-DemoEvalSqlMediaFile -Context $Context
    $image = Get-DiskImage -ImagePath $media.Path
    if (-not $image.Attached) {
        $image = Mount-DiskImage -ImagePath $media.Path -PassThru
    }
    return [string]($image | Get-Volume).DriveLetter
}

function Get-DemoEvalSqlEdition {
    # The default instance's edition from the setup registry key, readable without a SQL Server login. Never throws.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $instanceKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
        if (-not $instanceKey -or -not $instanceKey.PSObject.Properties['MSSQLSERVER']) {
            return ''
        }
        $setup = Get-ItemProperty -Path ('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\{0}\Setup' -f $instanceKey.MSSQLSERVER) -ErrorAction SilentlyContinue
        if ($setup -and $setup.PSObject.Properties['Edition']) {
            return [string]$setup.Edition
        }
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The SQL Server edition could not be read: {0}' -f $_.Exception.Message)
    }
    return ''
}

function Test-DemoEvalSqlEdition {
    # The default instance runs with the edition the mode expects (Developer; Standard; Standard or Enterprise).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $service = Get-Service -Name $Context.Config.Sql.ServiceName -ErrorAction SilentlyContinue
    if (-not $service -or [string]$service.Status -ne 'Running') {
        return $false
    }
    $edition = Get-DemoEvalSqlEdition
    if ($Context.Mode -eq 'Developer') {
        return ($edition -like 'Developer*')
    }
    if ($Context.Mode -eq 'PaygWizard') {
        return ($edition -like 'Standard*')
    }
    return ($edition -like 'Standard*' -or $edition -like 'Enterprise*')
}

function Install-DemoEvalSql {
    # ProductKey and Developer modes: local unattended setup with the nested guest's switches.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $productKey = $null
    if ($Context.Mode -eq 'ProductKey') {
        $productKey = Get-DemoProtectedSqlProductKey -Path $Context.ProductKeyPath
        if ($null -eq $productKey) {
            return (New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForProductKey' -Message 'ProductKey mode needs the SQL Server product key (prerequisite P10). configure-arc.ps1 -ProductKey sends it in a protected Run Command; this step continues when it arrives.')
        }
    }
    $arguments = Get-DemoSqlSetupArgument -Sql $Context.Guest.Sql -ProductKey $productKey
    $drive = Mount-DemoEvalSqlMedia -Context $Context
    Write-DemoVmLog -Message ('Running SQL Server setup from {0}: (this takes 10 to 30 minutes).' -f $drive)
    $process = Start-Process -FilePath ('{0}:\setup.exe' -f $drive) -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    $arguments = $null
    if ($Context.Mode -eq 'ProductKey' -and (Test-Path -LiteralPath $Context.ProductKeyPath)) {
        Remove-Item -LiteralPath $Context.ProductKeyPath -Force
        Write-DemoVmLog -Message 'Deleted the stored product key after setup.'
    }
    if ($process.ExitCode -eq 3010) {
        return (New-DemoVmStepResult -Outcome 'RebootRequired' -Message 'SQL Server setup asked for a restart.')
    }
    if ($process.ExitCode -ne 0) {
        $summary = Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
        $tail = ''
        if ($summary) {
            $tail = (Get-Content -LiteralPath $summary.FullName -Tail 15) -join ' | '
        }
        throw ('SQL Server setup failed with exit code {0}. Summary: {1}' -f $process.ExitCode, (Protect-DemoVmText -Text $tail))
    }
    Write-DemoVmLog -Message 'SQL Server setup finished.'
}

function Get-DemoEvalWizardInstruction {
    # The setup-wizard steps for PaygWizard mode on the evaluation VM.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MachineName,

        [string] $MediaDrive = ''
    )

    $setupPath = 'setup.exe on the SQL Server media drive'
    if ($MediaDrive) {
        $setupPath = '{0}:\setup.exe (the SQL Server media is mounted)' -f $MediaDrive
    }
    return @(
        ('EVALUATION ONLY: {0} is an Azure VM onboarded to Azure Arc with Microsoft''s evaluation procedure (ADR 0006).' -f $MachineName)
        'Run ./scripts/start-demo.ps1 -Interactive -ResetAdminPassword to create Bastion and get a one-time password.'
        ('In the Azure portal, connect to {0} with Bastion and sign in as the local administrator.' -f $MachineName)
        ('Run {0}. Select Installation > New SQL Server standalone installation.' -f $setupPath)
        'On the Edition page, select Use pay-as-you-go billing through Microsoft Azure, then Standard.'
        'On the Azure Extension for SQL Server page, if it appears, select Use Azure Login and sign in with your own Azure account; pay-as-you-go needs it, and the subscription, resource group, and region are locked to the existing Arc connection. Never enter a service principal secret. A blank sign-in window means the WebView2 runtime is missing (install the Evergreen Standalone Installer, which needs only HTTPS).'
        'Select Database Engine Services (leave Azure Extension for SQL Server selected), and keep the default instance (MSSQLSERVER).'
        'Choose Windows authentication mode, add BUILTIN\Administrators as a SQL Server administrator, and install.'
        'Close setup and the SQL Server Installation Center. Within about 5 minutes the bootstrap detects the instance, removes the sign-in data that setup leaves on this VM, checks that none remains, and continues on its own.'
    )
}

function Get-DemoEvalWizardResult {
    # PaygWizard: Manual action required with the steps, and why the check still fails.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $drive = Mount-DemoEvalSqlMedia -Context $Context
    $message = ('EVALUATION ONLY: Arc is connected. Install SQL Server Standard on {0} with the setup wizard, choosing pay-as-you-go billing (ADR 0006). The bootstrap checks every 5 minutes and continues on its own.' -f $Context.MachineName)
    $service = Get-Service -Name $Context.Config.Sql.ServiceName -ErrorAction SilentlyContinue
    $edition = Get-DemoEvalSqlEdition
    if ($service -and [string]$service.Status -ne 'Running') {
        $message = 'EVALUATION ONLY: SQL Server is installed but its service is not running. Start the MSSQLSERVER service, or finish the setup wizard.'
    }
    elseif ($service -and $edition -and $edition -notlike 'Standard*') {
        $message = ('EVALUATION ONLY: SQL Server is {0}; this mode needs Standard with pay-as-you-go billing. Uninstall it and run the setup wizard again.' -f $edition)
    }
    return (New-DemoVmStepResult -Outcome 'ManualActionRequired' -Message $message -Instruction (Get-DemoEvalWizardInstruction -MachineName $Context.MachineName -MediaDrive $drive))
}

function Initialize-DemoEvalArcDatabase {
    # ContosoCare with the arcsql01 scripts, run locally (Windows authentication only).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $database = Join-Path -Path $Context.BundleRoot -ChildPath 'database'
    Invoke-DemoVmSqlScript -Path ([System.IO.Path]::Combine($database, 'arcsql01', '000-create-database.sql')) -Database 'master'
    foreach ($relative in @('common\010-schema.sql', 'common\020-seed.sql', 'arcsql01\030-configure.sql')) {
        Invoke-DemoVmSqlScript -Path (Join-Path -Path $database -ChildPath $relative) -Database 'ContosoCare'
    }
}

function Get-DemoEvalMarkerAge {
    # Minutes since the Arc marker's connectedUtc, or -1 without a valid marker. Never throws.
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [datetime] $Now = [DateTime]::UtcNow
    )

    try {
        $marker = Read-DemoVmJsonFile -Path $Context.ArcMarkerPath
        if ($null -eq $marker -or -not $marker.Contains('connectedUtc')) {
            return -1
        }
        $connected = [DateTime]::Parse([string]$marker['connectedUtc'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        return ($Now - $connected).TotalMinutes
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The Arc marker could not be read: {0}' -f $_.Exception.Message)
        return -1
    }
}

function Test-DemoEvalGuestAgentDisabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $service = Get-Service -Name $Context.GuestAgentService -ErrorAction SilentlyContinue
    if (-not $service) {
        return $true
    }
    return ([string]$service.StartType -eq 'Disabled' -and [string]$service.Status -eq 'Stopped')
}

function Disable-DemoEvalWindowsService {
    # The documented commands: Set-Service -StartupType Disabled, then Stop-Service -Force. Tests stand in for it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    Set-Service -Name $Name -StartupType Disabled
    Stop-Service -Name $Name -Force
}

function Disable-DemoEvalGuestAgent {
    <#
    .SYNOPSIS
    Disables the Azure guest agent with the documented commands, at least GuestAgentDelayMinutes after the
    marker was written, so the onboarding Run Command has reported back. Stopping the agent ends Run Command
    on this VM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [datetime] $Now = [DateTime]::UtcNow
    )

    $age = Get-DemoEvalMarkerAge -Context $Context -Now $Now
    if ($age -lt 0) {
        return (New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForArcOnboarding' -Message 'The Azure guest agent is disabled only after Arc onboarding; no Arc marker was found.')
    }
    if ($age -lt $Context.GuestAgentDelayMinutes) {
        return (New-DemoVmStepResult -Outcome 'InProgress' -Message ('EVALUATION ONLY: the Azure guest agent is disabled {0} minutes after onboarding, so the onboarding Run Command can report back first ({1:N0} minutes so far).' -f $Context.GuestAgentDelayMinutes, $age))
    }
    Disable-DemoEvalWindowsService -Name $Context.GuestAgentService
    return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage 'EVALUATION ONLY: the Azure guest agent is disabled as the evaluation procedure requires, so Run Command and VM extensions no longer work on this VM. Check T2 through its Azure Arc resources.')
}

function Get-DemoEvalArcStepPlan {
    <#
    .SYNOPSIS
    The evaluation-only steps. Mode-specific steps use When, so the plan is the same list in every mode.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $unattendedModes = @('ProductKey', 'Developer')
    $plan = @(
        @{ Name = 'ArcEvaluationPrep'
            Test = { param($Step) Test-DemoEvalArcPrep -Context $Step.Context }
            Set = { param($Step) Initialize-DemoEvalArcPrep -Context $Step.Context } }
        @{ Name = 'SqlMedia'; MaxAttempts = 5
            Test = { param($Step)
                $media = Get-DemoEvalSqlMediaFile -Context $Step.Context
                Test-DemoVmFileHash -Path $media.Path -ExpectedSha256 $media.Sha256 -Name $media.Name }
            Set = { param($Step) Save-DemoEvalSqlMedia -Context $Step.Context } }
        @{ Name = 'SqlUnattendedInstall'; MaxAttempts = 2; Mode = $unattendedModes
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'PaygWizard mode installs SQL Server with the setup wizard after Arc onboarding.'
            Test = { param($Step) Test-DemoEvalSqlEdition -Context $Step.Context }
            Set = { param($Step) Install-DemoEvalSql -Context $Step.Context } }
        @{ Name = 'ArcOnboarding'; Mode = $unattendedModes
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'PaygWizard mode waits for Arc before the setup wizard.'
            Test = { param($Step) Test-DemoArcOnboarded -MarkerPath $Step.Context.ArcMarkerPath -MachineName $Step.Context.MachineName }
            Set = { New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForArcOnboarding' -Message 'EVALUATION ONLY: SQL Server is installed. Waiting for configure-arc.ps1 to onboard this VM to Azure Arc with the caller''s token (ADR 0005); it writes arc-onboarded.json when the machine is Connected.' } }
        @{ Name = 'ArcOnboardingBeforeWizard'; Mode = @('PaygWizard')
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'ProductKey and Developer modes onboard Arc after the unattended install.'
            Test = { param($Step) Test-DemoArcOnboarded -MarkerPath $Step.Context.ArcMarkerPath -MachineName $Step.Context.MachineName }
            Set = { New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForArcOnboarding' -Message 'EVALUATION ONLY: waiting for configure-arc.ps1 to onboard this VM to Azure Arc before the setup-wizard step, so the wizard finds the existing connection (ADR 0005, ADR 0006).' } }
        @{ Name = 'SqlSetupWizard'; Mode = @('PaygWizard')
            When = { param($Step) $Step.Context.Mode -in $Step.Mode }
            NotSelectedMessage = 'ProductKey and Developer modes install SQL Server unattended.'
            Test = { param($Step) Test-DemoEvalSqlEdition -Context $Step.Context }
            Set = { param($Step) Get-DemoEvalWizardResult -Context $Step.Context } }
        @{ Name = 'SignInCleanup'
            Test = {
                $sweep = Invoke-DemoSignInSweep -IncludeBrowserCache $true
                [bool]$sweep.pass -and [int]$sweep.found.securityLogTokens -eq 0 -and (Test-DemoIeEscEnabled) -and (@(Get-DemoSetupProcess).Count -eq 0) }
            Set = {
                $setup = @(Get-DemoSetupProcess)
                if ($setup.Count -gt 0) {
                    return (New-DemoVmStepResult -Outcome 'InProgress' -Message ('EVALUATION ONLY: SQL Server setup is still running ({0}). Close the setup wizard and the Installation Center: within about 5 minutes the bootstrap removes the sign-in data that setup leaves on this VM, checks that none remains, and continues.' -f ($setup -join ', ')))
                }
                $sweep = Invoke-DemoSignInSweep -Clean $true -IncludeBrowserCache $true
                Enable-DemoIeEsc
                $summary = Format-DemoSignInSweep -Sweep $sweep -Label 'This VM'
                Write-DemoVmLog -Message ('EVALUATION ONLY: sign-in cleanup. {0} IE Enhanced Security Configuration is on.' -f $summary)
                if (-not [bool]$sweep.pass) {
                    throw ('Sign-in data is left after the cleanup, so the build stops here (fail closed). {0}' -f $summary)
                }
                Get-DemoSignInStepResult -Sweep @($sweep) -Label @('arcsql01') -VmName 'arcsql01' } }
        @{ Name = 'SqlAdminAccess'; MaxAttempts = 2
            Test = { Test-DemoSqlVmSysadmin }
            Set = { param($Step) Grant-DemoSqlVmSysadmin -Context $Step.Context } }
        @{ Name = 'ConfigureSql'
            Test = { param($Step) Test-DemoSqlVmDatabase -Context $Step.Context }
            Set = { param($Step) Initialize-DemoEvalArcDatabase -Context $Step.Context } }
        @{ Name = 'SeedDatabase'
            Test = { param($Step) Test-DemoSqlVmDatabase -Context $Step.Context -Seeded }
            Set = { param($Step) Invoke-DemoVmSql -Database 'ContosoCare' -TimeoutSeconds 3600 -Query ('EXEC demo.usp_seed_contosocare @scale = {0};' -f $Step.Context.SeedScale) | Out-Null } }
        @{ Name = 'WorkloadRunner'
            When = { $false }
            NotSelectedMessage = 'Evaluation-only mode does not install the workload runner yet: the runner reaches T1 and the nested T2 guest (ADR 0010); a local T2 runner on this VM is a Phase 13 follow-up.'
            Test = { $true }
            Set = { } }
        @{ Name = 'DisableAzureGuestAgent'
            Test = { param($Step) Test-DemoEvalGuestAgentDisabled -Context $Step.Context }
            Set = { param($Step) Disable-DemoEvalGuestAgent -Context $Step.Context } }
    )
    foreach ($step in $plan) {
        $step['Context'] = $Context
    }
    return $plan
}

function Get-DemoEvalArcHealthDetail {
    # health.json details: the evaluation-only label, the procedure's settings, Arc onboarding, and SQL Server.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $service = Get-Service -Name $Context.Config.Sql.ServiceName -ErrorAction SilentlyContinue
    $agent = Get-Service -Name $Context.GuestAgentService -ErrorAction SilentlyContinue
    $agentState = 'NotInstalled'
    if ($agent) {
        $agentState = '{0}/{1}' -f $agent.Status, $agent.StartType
    }
    return [ordered]@{
        evaluationOnly = $true
        installMode    = $Context.Mode
        arcOnboarded   = Test-DemoArcOnboarded -MarkerPath $Context.ArcMarkerPath -MachineName $Context.MachineName
        msftArcTest    = [string][Environment]::GetEnvironmentVariable('MSFT_ARC_TEST', 'Machine')
        imdsBlocked    = Test-DemoEvalArcPrep -Context $Context
        guestAgent     = $agentState
        guest          = [ordered]@{
            name  = $Context.MachineName
            state = 'AzureVm'
            sql   = [ordered]@{ running = [bool]($service -and [string]$service.Status -eq 'Running'); edition = Get-DemoEvalSqlEdition }
        }
    }
}

function Invoke-DemoEvalArcVmBootstrap {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [string] $BundleRoot
    )

    Initialize-DemoVmContext -Root $StateRoot -Role 'EvalArcVm' -BundleRoot $BundleRoot | Out-Null
    $lock = Enter-DemoVmLock
    if ($null -eq $lock) {
        return 'Locked'
    }
    try {
        $settings = Get-DemoVmSetting
        $context = Get-DemoEvalArcContext -StateRoot $StateRoot -BundleRoot $BundleRoot -Settings $settings
        $plan = Get-DemoEvalArcStepPlan -Context $context
        return (Invoke-DemoVmStateMachine -Step $plan -Generation ([string]$settings['generation']) -HealthDetail { Get-DemoEvalArcHealthDetail -Context $context })
    }
    finally {
        Exit-DemoVmLock -Lock $lock
    }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $outcome = Invoke-DemoEvalArcVmBootstrap -StateRoot $script:EvalStateRoot -BundleRoot $script:EvalBundleRoot
        Write-DemoVmLog -Message ('Run finished: {0}.' -f $outcome)
        exit 0
    }
    catch {
        Write-DemoVmLog -Level 'Error' -Message ('Run failed: {0}' -f $_.Exception.Message)
        exit 1
    }
}
