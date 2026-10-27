# Step helpers for the T2 host state machine (ADR 0003). Windows PowerShell 5.1.
# Every function takes the host context built by Get-DemoHostContext in Invoke-HostBootstrap.ps1.

function Get-DemoHostDataPath {
    # Folders for the media and the guest VHDX: on the data disk, or on the OS disk without one.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Media', 'Vms')]
        [string] $Kind
    )

    $relative = $Context.Host.DataDisk.MediaFolder
    if ($Kind -eq 'Vms') {
        $relative = $Context.Host.DataDisk.VmFolder
    }
    if (-not (Test-DemoHostHasDataDisk -Context $Context)) {
        return ('{0}\{1}' -f (Get-DemoHostSystemDrive), $relative)
    }
    $volume = Get-DemoVmDataVolume -Label $Context.Host.DataDisk.Label
    if (-not $volume) {
        throw 'The data disk is not initialized yet.'
    }
    return ('{0}:\{1}' -f $volume.DriveLetter, $relative)
}

function Test-DemoHostHasDataDisk {
    # False when the template created no data disk (dataDiskTier None, the lowest-cost default).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    return ($Context.DataDiskTier -ne 'None')
}

function Get-DemoHostSystemDrive {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:SystemDrive) {
        return $env:SystemDrive
    }
    return 'C:'
}

function Get-DemoHostDriveFreeSpace {
    # Free space on a drive such as C:. Tests mock it.
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Drive
    )

    return [long](New-Object -TypeName 'System.IO.DriveInfo' -ArgumentList $Drive).AvailableFreeSpace
}

function Get-DemoHostOsDiskRequirement {
    <#
    .SYNOPSIS
    Bytes the guest needs on the OS disk without a data disk: the VHDX's maximum size, the Windows Server
    and SQL Server media for the install mode (sizes from the bundle manifest), and a margin.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $mediaBytes = [long]0
    foreach ($name in @($Context.Host.Media.WindowsServer, (Get-DemoHostSqlMediaName -Context $Context))) {
        $pin = Get-DemoVmMediaPin -Name $name -BundleRoot $Context.BundleRoot
        if ($pin.Contains('sizeBytes') -and [long]$pin['sizeBytes'] -gt 0) {
            $mediaBytes += [long]$pin['sizeBytes']
        }
        else {
            # A pin without a size counts as 6 GB, more than either ISO.
            $mediaBytes += 6GB
        }
    }
    $vhdxBytes = [long]$Context.VhdxGB * 1GB
    $marginBytes = [long]$Context.Host.DataDisk.OsDiskMarginGB * 1GB
    return [pscustomobject]@{
        VhdxBytes   = $vhdxBytes
        MediaBytes  = $mediaBytes
        MarginBytes = $marginBytes
        TotalBytes  = $vhdxBytes + $mediaBytes + $marginBytes
    }
}

function Test-DemoHostStorage {
    # The DataDisk step's check: the data disk is formatted, or, without one, the OS disk folders exist.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    if (Test-DemoHostHasDataDisk -Context $Context) {
        return [bool](Get-DemoVmDataVolume -Label $Context.Host.DataDisk.Label)
    }
    return ((Test-Path -LiteralPath (Get-DemoHostDataPath -Context $Context -Kind 'Media')) -and (Test-Path -LiteralPath (Get-DemoHostDataPath -Context $Context -Kind 'Vms')))
}

function Initialize-DemoHostStorage {
    <#
    .SYNOPSIS
    Formats the data disk at LUN 0. Without one, checks the OS disk's free space first and fails clearly
    when the guest wouldn't fit, then creates the folders there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $disk = $Context.Host.DataDisk
    if (Test-DemoHostHasDataDisk -Context $Context) {
        Initialize-DemoVmDataDisk -Label $disk.Label -DriveLetter $disk.DriveLetter -Lun $disk.Lun -AllocationUnitSize $disk.AllocationUnitSize | Out-Null
        return
    }
    $drive = Get-DemoHostSystemDrive
    $need = Get-DemoHostOsDiskRequirement -Context $Context
    $free = Get-DemoHostDriveFreeSpace -Drive $drive
    if ($free -lt $need.TotalBytes) {
        return (New-DemoVmStepResult -Outcome 'Failed' -Message ('Not enough free space on {0} for the guest without a data disk: {1:N1} GB free, {2:N1} GB needed (VHDX up to {3:N0} GB, media {4:N1} GB, and a {5:N0} GB margin). Set dataDiskSku to E10 in the configuration to add a data disk, or free space on {0} (ADR 0016).' -f $drive, ($free / 1GB), ($need.TotalBytes / 1GB), ($need.VhdxBytes / 1GB), ($need.MediaBytes / 1GB), ($need.MarginBytes / 1GB)))
    }
    foreach ($kind in @('Media', 'Vms')) {
        $path = Get-DemoHostDataPath -Context $Context -Kind $kind
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
    Write-DemoVmLog -Message ('No data disk: the media and the guest VHDX go on {0} ({1:N1} GB free, {2:N1} GB needed).' -f $drive, ($free / 1GB), ($need.TotalBytes / 1GB))
}

function Get-DemoHostMediaFile {
    # Host path and pin for a media entry (bundle manifest, from config/versions.json).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [Parameter(Mandatory = $true)]
        [string] $MediaName
    )

    $pin = Get-DemoVmMediaPin -Name $MediaName -BundleRoot $Context.BundleRoot
    $fileName = [string]$pin['fileName']
    if (-not $fileName) {
        $fileName = $MediaName + '.iso'
    }
    return [pscustomobject]@{
        Name   = $MediaName
        Url    = [string]$pin['url']
        Sha256 = [string]$pin['sha256']
        Path   = Join-Path -Path (Get-DemoHostDataPath -Context $Context -Kind 'Media') -ChildPath $fileName
    }
}

function Get-DemoHostSqlMediaName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    if ($Context.Mode -eq 'Developer') {
        return $Context.Host.Media.SqlDeveloper
    }
    return $Context.Host.Media.SqlServer
}

function Test-DemoHostMedia {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [Parameter(Mandatory = $true)]
        [string] $MediaName
    )

    $media = Get-DemoHostMediaFile -Context $Context -MediaName $MediaName
    return (Test-DemoVmFileHash -Path $media.Path -ExpectedSha256 $media.Sha256 -Name $media.Name)
}

function Save-DemoHostMedia {
    # Downloads pinned media to the host's media folder; a SHA-256 mismatch fails closed. Returns a step result
    # carrying the trust-on-first-use warning when no hash is pinned.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [Parameter(Mandatory = $true)]
        [string] $MediaName
    )

    $media = Get-DemoHostMediaFile -Context $Context -MediaName $MediaName
    $download = Save-DemoVmDownload -Uri $media.Url -Path $media.Path -ExpectedSha256 $media.Sha256 -Name $media.Name
    if ($download.Warning) {
        return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage $download.Warning)
    }
}

function Build-DemoHostGuestDisk {
    # Generates the guest password (DPAPI on the host), fills the unattend file in memory, and builds the VHDX.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    Initialize-DemoGuestSecret -SecretPath $Context.SecretPath
    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    $template = [System.IO.Path]::Combine($Context.BundleRoot, 'vm', 'hyperv-guest', 'unattend.template.xml')
    $xml = Format-DemoUnattendXml -TemplatePath $template -ComputerName $Context.GuestName -TimeZone $Context.Guest.TimeZone -AdministratorPassword $credential.Password
    $media = Get-DemoHostMediaFile -Context $Context -MediaName $Context.Host.Media.WindowsServer
    Build-DemoGuestVhdx -IsoPath $media.Path -VhdxPath $Context.VhdxPath -SizeGB $Context.VhdxGB -ImageNamePattern $Context.Guest.ImageNamePattern -UnattendXml $xml
}

function Get-DemoHostGuestIsoPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $media = Get-DemoHostMediaFile -Context $Context -MediaName (Get-DemoHostSqlMediaName -Context $Context)
    return (Join-Path -Path $Context.Guest.MediaFolder -ChildPath (Split-Path -Path $media.Path -Leaf))
}

function Test-DemoHostGuestReachable {
    # Never throws: false while the guest is off, booting, or in first-boot setup.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    try {
        if (-not (Test-Path -LiteralPath $Context.SecretPath -PathType Leaf)) {
            return $false
        }
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        return (Test-DemoGuestOnline -Name $Context.GuestName -Credential $credential)
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The guest is not reachable yet: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Wait-DemoHostGuest {
    # Starts the guest if needed (after a host restart, for example) and waits up to 10 minutes.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    if (Test-DemoHostGuestReachable -Context $Context) {
        return $true
    }
    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    return (Wait-DemoGuestOnline -Name $Context.GuestName -Credential $credential -TimeoutMinutes 10)
}

function Test-DemoHostGuestSqlMedia {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    try {
        $mediaName = Get-DemoHostSqlMediaName -Context $Context
        if (-not (Test-DemoHostMedia -Context $Context -MediaName $mediaName)) {
            return $false
        }
        $media = Get-DemoHostMediaFile -Context $Context -MediaName $mediaName
        $expected = $media.Sha256
        if (-not $expected) {
            $expected = Get-DemoVmFileSha256 -Path $media.Path
        }
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        return (Test-DemoGuestFile -Name $Context.GuestName -Credential $credential -Path (Get-DemoHostGuestIsoPath -Context $Context) -ExpectedSha256 $expected)
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('SQL Server media check: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Copy-DemoHostGuestSqlMedia {
    # The SQL Server ISO goes to the host's media folder first (verified), then into the guest (verified again).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $mediaName = Get-DemoHostSqlMediaName -Context $Context
    $result = $null
    if (-not (Test-DemoHostMedia -Context $Context -MediaName $mediaName)) {
        $result = Save-DemoHostMedia -Context $Context -MediaName $mediaName
    }
    $media = Get-DemoHostMediaFile -Context $Context -MediaName $mediaName
    $expected = $media.Sha256
    if (-not $expected) {
        $expected = Get-DemoVmFileSha256 -Path $media.Path
    }
    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    Copy-DemoGuestFile -Name $Context.GuestName -Credential $credential -SourcePath $media.Path -DestinationPath (Get-DemoHostGuestIsoPath -Context $Context) -ExpectedSha256 $expected
    return $result
}

function Get-DemoHostFileSignature {
    # Get-AuthenticodeSignature, wrapped so tests can stand in for it on any platform.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return (Get-AuthenticodeSignature -FilePath $Path)
}

function Test-DemoHostSignedFile {
    # True when the file has a valid Authenticode signature whose signer matches the pattern.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $SignerPattern
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $signature = Get-DemoHostFileSignature -Path $Path
    return ([string]$signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and [string]$signature.SignerCertificate.Subject -match $SignerPattern)
}

function Save-DemoHostWebView2Installer {
    # Downloads the WebView2 standalone installer to the host's media folder over HTTPS, with retries, and keeps
    # it only when its Microsoft Authenticode signature is valid (fail closed). Returns its path.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [ValidateRange(1, 10)]
        [int] $MaxAttempts = 4
    )

    $setting = $Context.Host.WebView2
    $folder = Get-DemoHostDataPath -Context $Context -Kind 'Media'
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $path = '{0}\{1}' -f $folder.TrimEnd('\'), $setting.FileName
    if (Test-DemoHostSignedFile -Path $path -SignerPattern $setting.SignerPattern) {
        return $path
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    $partial = $path + '.partial'
    # Windows PowerShell 5.1 draws a progress bar per chunk, which makes large downloads very slow.
    $ProgressPreference = 'SilentlyContinue'
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            Write-DemoVmLog -Message ('Downloading the WebView2 runtime installer (attempt {0} of {1}).' -f $attempt, $MaxAttempts)
            Invoke-WebRequest -Uri $setting.Url -OutFile $partial -UseBasicParsing
            Move-Item -LiteralPath $partial -Destination $path -Force
            break
        }
        catch {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            if ($attempt -ge $MaxAttempts) {
                throw ('Downloading the WebView2 runtime installer failed after {0} attempts: {1}' -f $MaxAttempts, (Protect-DemoVmText -Text $_.Exception.Message))
            }
            Start-Sleep -Seconds (15 * $attempt)
        }
    }
    if (-not (Test-DemoHostSignedFile -Path $path -SignerPattern $setting.SignerPattern)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw 'The WebView2 runtime installer is not validly signed by Microsoft; it was deleted (fail closed).'
    }
    Write-DemoVmLog -Message 'Downloaded the WebView2 runtime installer and verified its Microsoft signature.'
    return $path
}

function Test-DemoHostGuestWebView2 {
    # Never throws: false when the guest can't be asked or has no WebView2 runtime.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    try {
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        return (Test-DemoGuestWebView2 -Name $Context.GuestName -Credential $credential)
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('WebView2 check: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Install-DemoHostGuestWebView2 {
    # PaygWizard: installs the WebView2 runtime in the guest before the setup wizard, so "Use Azure Login" on the
    # Azure Extension for SQL Server page can sign in (pay-as-you-go needs that page).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $installer = Save-DemoHostWebView2Installer -Context $Context
    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    # A guest path, built as a string: Join-Path would resolve its drive on the host.
    $guestPath = '{0}\{1}' -f ([string]$Context.Guest.MediaFolder).TrimEnd('\'), $Context.Host.WebView2.FileName
    Copy-DemoGuestFile -Name $Context.GuestName -Credential $credential -SourcePath $installer -DestinationPath $guestPath -ExpectedSha256 (Get-DemoVmFileSha256 -Path $installer)
    Install-DemoGuestWebView2 -Name $Context.GuestName -Credential $credential -InstallerPath $guestPath -TimeoutMinutes ([int]$Context.Host.WebView2.InstallTimeoutMinutes)
    Write-DemoVmLog -Message 'Installed the WebView2 runtime in the guest for the setup wizard''s Azure sign-in.'
}

function Test-DemoHostGuestSignInClean {
    # Never throws: false when the guest can't be asked, SQL Server setup still runs in it, sign-in data is left in
    # the guest or on this host (Invoke-DemoSignInSweep, read-only), or IE Enhanced Security Configuration is off.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    try {
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        $residue = Get-DemoGuestSignInResidue -Name $Context.GuestName -Credential $credential
        if (-not $residue.Pass -or $residue.SecurityLogTokens -gt 0 -or -not $residue.IeEscEnabled -or @($residue.SetupProcess).Count -gt 0) {
            return $false
        }
        $local = Invoke-DemoSignInSweep
        return ([bool]$local.pass -and [int]$local.found.securityLogTokens -eq 0)
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('Sign-in cleanup check: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Clear-DemoHostGuestSignIn {
    # After the setup wizard's interactive sign-in (PaygWizard) and after Arc onboarding (every mode): removes the
    # sign-in data left in the guest and on this host, verifies that none remains (fail closed), and turns IE
    # Enhanced Security Configuration back on in case it was turned off during the wizard. While SQL Server setup
    # still runs in the guest it waits, so nothing setup writes as it closes is missed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    $setup = @(Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ScriptBlock ${function:Get-DemoSetupProcess} | Where-Object { $_ })
    if ($setup.Count -gt 0) {
        return (New-DemoVmStepResult -Outcome 'InProgress' -Message ('SQL Server setup is still running in {0} ({1}). Close the setup wizard and the Installation Center: within about 5 minutes the host removes the sign-in data that setup leaves in the guest, checks that none remains, and continues.' -f $Context.GuestName, ($setup -join ', ')))
    }
    $guest = Clear-DemoGuestSignInResidue -Name $Context.GuestName -Credential $credential
    $local = Invoke-DemoSignInSweep -Clean $true
    $summary = '{0} {1}' -f (Format-DemoSignInSweep -Sweep $guest -Label $Context.GuestName), (Format-DemoSignInSweep -Sweep $local -Label 'This host')
    Write-DemoVmLog -Message ('Sign-in cleanup. {0} IE Enhanced Security Configuration is on.' -f $summary)
    if (-not [bool]$guest.pass -or -not [bool]$local.pass) {
        throw ('Sign-in data is left after the cleanup, so the build stops here (fail closed). {0}' -f $summary)
    }
    $result = Get-DemoSignInStepResult -Sweep @($guest, $local) -Label @($Context.GuestName, 'archost01')
    if ($null -ne $result) {
        return $result
    }
}
function Test-DemoHostSqlEdition {
    # Developer mode expects Developer; the other modes expect Standard (Enterprise also drives Hub Performance).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    try {
        $instance = Get-DemoGuestSqlInstance -Name $Context.GuestName -Credential $credential
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('SQL Server check in the guest: {0}' -f $_.Exception.Message)
        return $false
    }
    if (-not $instance.Running -or -not $instance.IsSysAdmin) {
        return $false
    }
    if ($Context.Mode -eq 'Developer') {
        return ([string]$instance.Edition -like 'Developer*')
    }
    if ($Context.Mode -eq 'PaygWizard') {
        return ([string]$instance.Edition -like 'Standard*')
    }
    return ([string]$instance.Edition -like 'Standard*' -or [string]$instance.Edition -like 'Enterprise*')
}

function Install-DemoHostGuestSql {
    # ProductKey and Developer modes. The product key comes only from protected input (Phase 7 hook).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $productKey = $null
    if ($Context.Mode -eq 'ProductKey') {
        $productKey = Get-DemoProtectedSqlProductKey -Path $Context.ProductKeyPath
        if ($null -eq $productKey) {
            return (New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForProductKey' -Message 'ProductKey mode needs the SQL Server product key (prerequisite P10). The orchestrator passes it in a protected Run Command that runs vm/bootstrap/Set-DemoSqlProductKey.ps1 (Phase 7); this step continues when the key arrives.')
        }
    }
    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    $exitCode = Install-DemoGuestSql -Name $Context.GuestName -Credential $credential -IsoPath (Get-DemoHostGuestIsoPath -Context $Context) -Sql $Context.Guest.Sql -ProductKey $productKey
    if ($Context.Mode -eq 'ProductKey' -and (Test-Path -LiteralPath $Context.ProductKeyPath)) {
        Remove-Item -LiteralPath $Context.ProductKeyPath -Force
        Write-DemoVmLog -Message 'Deleted the stored product key after setup.'
    }
    if ($exitCode -eq 3010) {
        Invoke-Command -VMName $Context.GuestName -Credential $credential -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 30
        if (-not (Wait-DemoGuestOnline -Name $Context.GuestName -Credential $credential -TimeoutMinutes 15)) {
            return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'The guest is restarting after SQL Server setup.')
        }
    }
}

function Get-DemoHostWizardResult {
    # PaygWizard: report Manual action required with the exact steps, and why the check still fails.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    $drive = Mount-DemoGuestIso -Name $Context.GuestName -Credential $credential -IsoPath (Get-DemoHostGuestIsoPath -Context $Context)
    $instance = Get-DemoGuestSqlInstance -Name $Context.GuestName -Credential $credential
    $message = 'Arc is connected. Install SQL Server Standard in arcsql01 with the setup wizard, choosing pay-as-you-go billing (ADR 0006). The host checks every 5 minutes and continues on its own.'
    if ($instance.ServiceExists -and -not $instance.Running) {
        $message = 'SQL Server is installed in arcsql01 but its service is not running. Start the MSSQLSERVER service, or finish the setup wizard.'
    }
    elseif ($instance.Running -and $instance.Error) {
        $message = 'SQL Server is running in arcsql01, but the guest Administrator cannot sign in to it. Add the Administrator account as a SQL Server administrator (setup wizard: Add Current User).'
    }
    elseif ($instance.Running -and -not $instance.IsSysAdmin) {
        $message = 'SQL Server is running in arcsql01, but the guest Administrator is not a sysadmin. Add it as a SQL Server administrator.'
    }
    elseif ($instance.Running -and [string]$instance.Edition -notlike 'Standard*') {
        $message = ('SQL Server in arcsql01 is {0}; this mode needs Standard with pay-as-you-go billing. Uninstall it and run the setup wizard again.' -f $instance.Edition)
    }
    return (New-DemoVmStepResult -Outcome 'ManualActionRequired' -Message $message -Instruction (Get-DemoPaygWizardInstruction -GuestName $Context.GuestName -MediaDrive $drive))
}

function Get-DemoHostDatabaseStatus {
    # Database, Query Store, growth caps, runner role, and seed state, read inside the guest.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    $exists = @(Invoke-DemoGuestSqlQuery -Name $Context.GuestName -Credential $credential -GuestToolsFolder $Context.Guest.ToolsFolder -Query "SELECT DB_ID(N'ContosoCare') AS database_id")
    if ($exists.Count -eq 0 -or $null -eq $exists[0].database_id) {
        return $null
    }
    return @(Invoke-DemoGuestSqlQuery -Name $Context.GuestName -Credential $credential -GuestToolsFolder $Context.Guest.ToolsFolder -Database 'ContosoCare' -Query $Context.StatusQuery)[0]
}

function Test-DemoHostDatabase {
    # ContosoCare exists with Query Store read-write, capped files, simple recovery, and the runner role.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [switch] $Seeded
    )

    try {
        $status = Get-DemoHostDatabaseStatus -Context $Context
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('Database check in the guest: {0}' -f $_.Exception.Message)
        return $false
    }
    if ($null -eq $status) {
        return $false
    }
    if ($Seeded) {
        return ([string]$status.seed_status -eq 'Completed' -and [int]$status.seed_scale -eq [int]$Context.SeedScale -and [int]$status.seed_version -eq [int]$Context.SeedVersion)
    }
    return ([string]$status.query_store_state -eq 'READ_WRITE' -and [int]$status.uncapped_files -eq 0 -and [string]$status.recovery_model -eq 'SIMPLE' -and [int]$status.seed_procedure -eq 1 -and [int]$status.runner_role -eq 1)
}

function Initialize-DemoHostDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    Copy-DemoGuestTool -Name $Context.GuestName -Credential $credential -BundleRoot $Context.BundleRoot -GuestToolsFolder $Context.Guest.ToolsFolder
    Invoke-DemoGuestSqlScript -Name $Context.GuestName -Credential $credential -GuestToolsFolder $Context.Guest.ToolsFolder -RelativePath @('arcsql01\000-create-database.sql') -Database 'master'
    Invoke-DemoGuestSqlScript -Name $Context.GuestName -Credential $credential -GuestToolsFolder $Context.Guest.ToolsFolder -RelativePath @('common\010-schema.sql', 'common\020-seed.sql', 'arcsql01\030-configure.sql') -Database 'ContosoCare'
}

function Invoke-DemoHostSeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    Invoke-DemoGuestSqlQuery -Name $Context.GuestName -Credential $credential -GuestToolsFolder $Context.Guest.ToolsFolder -Database 'ContosoCare' -Query ('EXEC demo.usp_seed_contosocare @scale = {0};' -f [int]$Context.SeedScale) | Out-Null
}
