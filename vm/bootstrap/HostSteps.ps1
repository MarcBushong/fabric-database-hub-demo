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
    and SQL Server media for the install mode (sizes from the bundle manifest), and a margin. In JumpstartImage mode:
    the image's download size plus a growth allowance and the margin, not its 100 GiB maximum (user decision,
    2026-11-05); status.ps1 warns early when the drive runs low.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $marginBytes = [long]$Context.Host.DataDisk.OsDiskMarginGB * 1GB
    if ($Context.Mode -eq 'JumpstartImage') {
        $pin = Get-DemoVmMediaPin -Name $Context.Host.Media.JumpstartImage -BundleRoot $Context.BundleRoot
        $imageBytes = [long]40GB
        if ($pin.Contains('sizeBytes') -and [long]$pin['sizeBytes'] -gt 0) {
            $imageBytes = [long]$pin['sizeBytes']
        }
        $growthBytes = [long]$Context.Host.JumpstartImage.GrowthAllowanceGB * 1GB
        return [pscustomobject]@{
            VhdxBytes   = $imageBytes + $growthBytes
            ImageBytes  = $imageBytes
            GrowthBytes = $growthBytes
            MediaBytes  = [long]0
            MarginBytes = $marginBytes
            TotalBytes  = $imageBytes + $growthBytes + $marginBytes
        }
    }
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
    return [pscustomobject]@{
        VhdxBytes   = $vhdxBytes
        ImageBytes  = [long]0
        GrowthBytes = [long]0
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
        $parts = '(VHDX up to {0:N0} GB, media {1:N1} GB, and a {2:N0} GB margin)' -f ($need.VhdxBytes / 1GB), ($need.MediaBytes / 1GB), ($need.MarginBytes / 1GB)
        if ($Context.Mode -eq 'JumpstartImage') {
            $parts = '(the Jumpstart image {0:N1} GB, {1:N0} GB for it to grow, and a {2:N0} GB margin)' -f ($need.ImageBytes / 1GB), ($need.GrowthBytes / 1GB), ($need.MarginBytes / 1GB)
        }
        return (New-DemoVmStepResult -Outcome 'Failed' -Message ('Not enough free space on {0} for the guest without a data disk: {1:N1} GB free, {2:N1} GB needed {3}. Set dataDiskSku to E10 in the configuration to add a data disk, or free space on {0} (ADR 0016).' -f $drive, ($free / 1GB), ($need.TotalBytes / 1GB), $parts))
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
    # PaygWizard: installs the WebView2 runtime in the guest before the setup wizard. The guided stop checks it again,
    # and installs it when it's missing, before it asks for anyone (Initialize-DemoHostGuidedSignIn); setup's own sign-in
    # opened in an IE-based control in the 2026-10-30 live proof, so that also turns IE ESC off for administrators.
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
    # Developer mode expects Developer; PaygWizard and JumpstartImage expect Standard; ProductKey Standard or Enterprise.
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
    if ($Context.Mode -in 'PaygWizard', 'JumpstartImage') {
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

# ---- The guest's source (ADR 0006, amendment of 2026-11-05) ----

function Get-DemoHostGuestSourcePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    return (Join-Path -Path $Context.Root -ChildPath 'guest-source.json')
}

function Get-DemoHostGuestSourceDecision {
    <#
    .SYNOPSIS
    Pure: whether the configured install mode may use the guest that's there. A guest is made once, either from the
    Jumpstart image (JumpstartImage) or by the build (every other mode); a guest that exists without a record was built,
    as every guest was before the record existed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Mode,

        [AllowNull()]
        [System.Collections.IDictionary] $Record,

        [bool] $GuestExists
    )

    $expected = 'Build'
    if ($Mode -eq 'JumpstartImage') {
        $expected = 'JumpstartImage'
    }
    $recorded = ''
    $recordedMode = ''
    if ($null -ne $Record -and [string]$Record['source']) {
        $recorded = [string]$Record['source']
        $recordedMode = [string]$Record['installMode']
    }
    elseif ($GuestExists) {
        $recorded = 'Build'
    }
    return [pscustomobject]@{
        Ok           = (-not $recorded -or $recorded -eq $expected)
        Expected     = $expected
        Recorded     = $recorded
        RecordedMode = $recordedMode
    }
}

function Get-DemoHostGuestSourceState {
    # The decision for this host: its record, and whether the guest VM or its disk exists. Never throws.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $exists = $false
    try {
        $exists = [bool](Get-VM -Name $Context.GuestName -ErrorAction SilentlyContinue)
        if (-not $exists -and (Test-DemoHostStorage -Context $Context)) {
            $folder = Get-DemoHostDataPath -Context $Context -Kind 'Vms'
            $exists = Test-Path -LiteralPath ([System.IO.Path]::Combine($folder, $Context.GuestName, ($Context.GuestName + '.vhdx'))) -PathType Leaf
        }
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('Guest source check: {0}' -f $_.Exception.Message)
    }
    return (Get-DemoHostGuestSourceDecision -Mode $Context.Mode -Record (Read-DemoVmJsonFile -Path (Get-DemoHostGuestSourcePath -Context $Context)) -GuestExists $exists)
}

function Set-DemoHostGuestSource {
    # Records where the guest came from, when it's made: JumpstartImage or Build.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('JumpstartImage', 'Build')]
        [string] $Source
    )

    if ($PSCmdlet.ShouldProcess($Context.GuestName, ('Record the guest''s source as {0}' -f $Source))) {
        Write-DemoVmJsonFile -Path (Get-DemoHostGuestSourcePath -Context $Context) -InputObject ([ordered]@{ source = $Source; installMode = $Context.Mode; recordedUtc = (Get-DemoVmUtcNow) })
    }
}

function Get-DemoHostGuestSourceFailure {
    # The GuestSource step's result when the configured mode can't use the guest that's there. Nothing is changed. -Reason
    # says why the guest wasn't rebuilt or kept in its own mode (2026-11-09).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [string] $Reason = ''
    )

    $decision = Get-DemoHostGuestSourceState -Context $Context
    if ($decision.Ok) {
        return
    }
    $was = 'built from the evaluation media'
    if ($decision.Recorded -eq 'JumpstartImage') {
        $was = 'made from Arc Jumpstart''s image (t2SqlInstallMode JumpstartImage)'
    }
    elseif ($decision.RecordedMode) {
        $was = 'built from the evaluation media (t2SqlInstallMode {0})' -f $decision.RecordedMode
    }
    $why = ''
    if ($Reason) {
        $why = ' {0}' -f $Reason
    }
    return (New-DemoVmStepResult -Outcome 'Failed' -Message ('The guest {0} was {1}, but t2SqlInstallMode is now {2}, and an existing guest never changes its source.{3} Set t2SqlInstallMode back in config/demo.config.json, then run ./scripts/deploy.ps1 -FromStage Infrastructure, which brings the setting to the host; or rebuild T2 for the new mode: ./scripts/destroy.ps1, then ./scripts/deploy.ps1 (ADR 0006).' -f $Context.GuestName, $was, $Context.Mode, $why))
}

# ---- An unfinished PaygWizard guest rebuilt, and a finished guest's mode kept (ADR 0006, amendment of 2026-11-09) ----

function Get-DemoHostEffectiveMode {
    <#
    .SYNOPSIS
    Pure: the install mode the host runs. In JumpstartImage mode, an existing guest built in PaygWizard mode that a pass
    has seen with SQL Server set up (guest-source.json sqlSetUp) keeps that mode, whatever the configuration says
    (2026-11-09, user-directed: a finished guest is never rebuilt and never needs the setup wizard), so a finished
    PaygWizard demo upgrades without a configuration change. Only PaygWizard: it was the old default, and Azure expects
    the same of it as of JumpstartImage (Standard, PAYG), while ProductKey and Developer were deliberate choices whose
    license and checks differ, so their configuration keeps naming them. Any other mode runs as configured, whatever the
    mode's source (configuration, default, or legacy), which health.json reports.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $ConfiguredMode = '',

        [AllowNull()]
        [System.Collections.IDictionary] $Record
    )

    $mode = $ConfiguredMode
    if (-not $mode) {
        $mode = 'JumpstartImage'
    }
    $adopted = $false
    if ($mode -eq 'JumpstartImage' -and $null -ne $Record -and [string]$Record['source'] -eq 'Build' -and
        [string]$Record['installMode'] -eq 'PaygWizard' -and [bool]$Record['sqlSetUp']) {
        $mode = [string]$Record['installMode']
        $adopted = $true
    }
    return [pscustomobject]@{ Mode = $mode; Adopted = $adopted }
}

function Get-DemoHostGuestBuildMode {
    <#
    .SYNOPSIS
    Pure: the mode a build guest was made in. Its record names it (guests built since 2026-11-05). Before the record, the
    host's step records tell (state.json, kept across generations): only PaygWizard runs ArcOnboardingBeforeWizard,
    GuidedSetup, and SqlSetupWizard, and only ProductKey and Developer run SqlUnattendedInstall, whose edition tells them
    apart. '' when nothing tells.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Record,

        [AllowNull()]
        [System.Collections.IDictionary] $Steps,

        [AllowEmptyString()]
        [string] $Edition = ''
    )

    if ($null -ne $Record -and [string]$Record['installMode'] -in 'PaygWizard', 'ProductKey', 'Developer') {
        return [string]$Record['installMode']
    }
    $started = @()
    if ($null -ne $Steps) {
        foreach ($name in 'ArcOnboardingBeforeWizard', 'GuidedSetup', 'SqlSetupWizard', 'SqlUnattendedInstall') {
            if ($Steps.Contains($name) -and $Steps[$name] -is [System.Collections.IDictionary] -and [string]$Steps[$name]['firstStartedUtc']) {
                $started += $name
            }
        }
    }
    $wizard = @($started | Where-Object { $_ -ne 'SqlUnattendedInstall' }).Count -gt 0
    $unattended = $started -contains 'SqlUnattendedInstall'
    if ($wizard -and -not $unattended) {
        return 'PaygWizard'
    }
    if ($unattended -and -not $wizard) {
        if ($Edition -like 'Developer*') {
            return 'Developer'
        }
        if ($Edition -like 'Standard*' -or $Edition -like 'Enterprise*') {
            return 'ProductKey'
        }
    }
    return ''
}

function Get-DemoHostGuestFinding {
    <#
    .SYNOPSIS
    What the host knows about an existing build guest, read-only: its record and build mode, whether SQL Server setup ever
    completed (state.json), whether a guided stop waits for a person (guided-setup-request.json), and, over PowerShell
    Direct, its SQL Server instances, setup processes, and edition. It starts a guest that's off and waits up to 10 minutes
    for it (Wait-DemoHostGuest). Reachable is false when the guest couldn't be read. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $finding = [ordered]@{
        GuestExists     = $false
        GuestVmId       = ''
        Record          = $null
        BuildMode       = ''
        WizardCompleted = $false
        GuidedWaiting   = $false
        Reachable       = $false
        DefaultInstance = $false
        NamedInstances  = @()
        SetupRunning    = @()
        Edition         = ''
        ArcResourceId   = ''
        Error           = ''
    }
    $steps = $null
    try {
        $finding.Record = Read-DemoVmJsonFile -Path (Get-DemoHostGuestSourcePath -Context $Context)
        $steps = (Get-DemoVmState)['steps']
        foreach ($name in 'SqlSetupWizard', 'SqlUnattendedInstall') {
            if ($null -ne $steps -and $steps.Contains($name) -and [string]$steps[$name]['completedUtc']) {
                $finding.WizardCompleted = $true
            }
        }
        $finding.GuidedWaiting = (Get-DemoGuidedSetupRequest -Path (Get-DemoGuidedSetupPath -Root $Context.Root)).Valid
        $marker = Read-DemoVmJsonFile -Path $Context.ArcMarkerPath
        if ($null -ne $marker) {
            $finding.ArcResourceId = [string]$marker['resourceId']
        }
        $finding.GuestVmId = Get-DemoHostGuestVmId -Name $Context.GuestName
        $finding.GuestExists = [bool]$finding.GuestVmId
        if ($finding.GuestExists -and (Test-Path -LiteralPath $Context.SecretPath -PathType Leaf) -and (Wait-DemoHostGuest -Context $Context)) {
            $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
            $facts = Get-DemoGuestSetupFact -Name $Context.GuestName -Credential $credential
            $finding.DefaultInstance = [bool]$facts.DefaultInstance
            $finding.NamedInstances = @($facts.NamedInstances | Where-Object { $_ })
            $finding.SetupRunning = @($facts.SetupProcess | Where-Object { $_ })
            if ($finding.DefaultInstance) {
                $finding.Edition = [string](Get-DemoGuestSqlInstance -Name $Context.GuestName -Credential $credential).Edition
            }
            $finding.Reachable = $true
        }
    }
    catch {
        $finding.Error = Protect-DemoVmText -Text $_.Exception.Message
        $finding.Reachable = $false
        Write-DemoVmLog -Level 'Warning' -Message ('The existing guest couldn''t be read: {0}' -f $finding.Error)
    }
    $finding.BuildMode = Get-DemoHostGuestBuildMode -Record $finding.Record -Steps $steps -Edition $finding.Edition
    return [pscustomobject]$finding
}

function Get-DemoHostGuestSourcePlan {
    <#
    .SYNOPSIS
    Pure: what the GuestSource step does with a build guest when the host runs JumpstartImage mode (2026-11-09). Returns
    Action (Rebuild, Adopt, Wait, or Refuse), GuestMode, and Reason. Fail safe: only positive evidence that nothing is there
    to keep rebuilds, and anything unclear keeps the guest.
    - Adopt: SQL Server is set up (an instance, or setup completed by the host's records) in a guest built in PaygWizard
      mode: the guest is kept as it is, in that mode, whatever the configuration says (user-directed: a finished guest is
      never rebuilt and never needs the setup wizard). A finished ProductKey or Developer guest is kept too, but refused:
      those were deliberate choices whose license and checks differ from JumpstartImage's, so the configuration names them.
    - Rebuild: built in PaygWizard mode, read over PowerShell Direct just now, with no SQL Server instance (default or named),
      no setup running, SQL Server setup never completed by the host's records, and no guided stop waiting for a person.
    - Wait: the guest couldn't be read, setup runs in it, or a guided stop waits; the step tries again (MaxAttempts).
    - Refuse: anything else, with the reason in the step's failure.
    The mode's source (configuration, default, or legacy) doesn't change the plan.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Finding
    )

    $plan = { param([string] $Action, [string] $Reason) [pscustomobject]@{ Action = $Action; GuestMode = [string]$Finding.BuildMode; Reason = $Reason } }
    $instances = [bool]$Finding.DefaultInstance -or @($Finding.NamedInstances).Count -gt 0
    $setUp = $instances -or [bool]$Finding.WizardCompleted
    $mode = [string]$Finding.BuildMode
    $modeText = if ($mode) { $mode } else { 'an unknown build mode' }
    if ($setUp) {
        if ($mode -eq 'PaygWizard') {
            return (& $plan 'Adopt' 'SQL Server is set up in the guest, built in PaygWizard mode, so T2 keeps it as it is, in that mode, with no setup wizard.')
        }
        if ($mode) {
            return (& $plan 'Refuse' ('SQL Server is set up in the guest, built in {0} mode, a deliberate choice whose license and checks differ from JumpstartImage''s, so it''s kept as it is and used only in its own mode.' -f $mode))
        }
        return (& $plan 'Refuse' 'SQL Server is set up in the guest, so it''s kept, but the mode it was built in couldn''t be told, so it isn''t used on its own: name that mode with t2SqlInstallMode.')
    }
    if (-not [bool]$Finding.Reachable) {
        $detail = ''
        if ($Finding.Error) {
            $detail = ' ({0})' -f $Finding.Error
        }
        return (& $plan 'Wait' ('The guest couldn''t be read over PowerShell Direct{0}, so whether its SQL Server setup finished isn''t known yet; nothing is deleted.' -f $detail))
    }
    if (@($Finding.SetupRunning).Count -gt 0) {
        return (& $plan 'Wait' ('SQL Server setup is running in the guest ({0}), so nothing is deleted while it runs.' -f (@($Finding.SetupRunning) -join ', ')))
    }
    if ([bool]$Finding.GuidedWaiting) {
        return (& $plan 'Wait' 'A guided stop is waiting for a person to run SQL Server setup in the guest, so nothing is deleted until it ends.')
    }
    if ($mode -eq 'PaygWizard') {
        return (& $plan 'Rebuild' 'The guest was built in PaygWizard mode, and its SQL Server setup wizard was never finished: it has no SQL Server instance, and the host never saw setup complete. Nothing in it is kept, so the host deletes it and makes T2 from Arc Jumpstart''s image.')
    }
    return (& $plan 'Refuse' ('SQL Server isn''t installed in the guest, but it wasn''t built in PaygWizard mode ({0}), so it isn''t deleted on its own.' -f $modeText))
}

function Get-DemoHostGuestRebuildPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    return (Join-Path -Path $Context.Root -ChildPath 'guest-rebuild.json')
}

function Get-DemoHostGuestRebuildDetail {
    # For health.json (details.guestRebuild): the last rebuild of an unfinished guest, without its file list. $null when
    # there's none. Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    try {
        $record = Read-DemoVmJsonFile -Path (Get-DemoHostGuestRebuildPath -Context $Context)
    }
    catch {
        return [ordered]@{ state = 'Unreadable' }
    }
    if ($null -eq $record) {
        return $null
    }
    return [ordered]@{
        state         = [string]$record['state']
        startedUtc    = [string]$record['startedUtc']
        removedUtc    = [string]$record['removedUtc']
        oldMode       = [string]$record['oldMode']
        arcResourceId = [string]$record['arcResourceId']
    }
}

function Get-DemoHostGuestRebuildSpace {
    <#
    .SYNOPSIS
    Whether the Jumpstart image fits once the unfinished guest and the build media are deleted, without a data disk: the
    free space now plus what the deletion frees, against the JumpstartImage requirement (the image, its growth allowance,
    and the margin; Get-DemoHostOsDiskRequirement). With a data disk, Ok. Returns Ok, FreeBytes, FreedBytes, and
    NeededBytes. Never deletes anything.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [string[]] $Path = @()
    )

    if (Test-DemoHostHasDataDisk -Context $Context) {
        return [pscustomobject]@{ Ok = $true; FreeBytes = [long]0; FreedBytes = [long]0; NeededBytes = [long]0 }
    }
    $freed = [long]0
    foreach ($item in $Path) {
        if (Test-Path -LiteralPath $item -PathType Leaf) {
            $freed += [long](Get-Item -LiteralPath $item).Length
        }
        elseif (Test-Path -LiteralPath $item -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $item -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                $freed += [long]$file.Length
            }
        }
    }
    $free = Get-DemoHostDriveFreeSpace -Drive (Get-DemoHostSystemDrive)
    $need = (Get-DemoHostOsDiskRequirement -Context $Context).TotalBytes
    return [pscustomobject]@{ Ok = (($free + $freed) -ge $need); FreeBytes = $free; FreedBytes = $freed; NeededBytes = $need }
}

function Remove-DemoHostGuest {
    <#
    .SYNOPSIS
    Deletes an unfinished guest so JumpstartImage mode makes a new one (2026-11-09): the guest VM (turned off, then removed),
    its folder with its disk, the build modes' media, and the guest's records on the host (its source, the Arc marker, the
    evaluation guard's record, any Jumpstart records, the guided stop's request, records, scripts, and host logon task), and
    its DPAPI-protected password. guest-rebuild.json records it (state Removing, then Removed; no secret), so a run stopped
    midway finishes it, and deploy.ps1 deletes the old guest's Arc resources in Azure (DEPLOY.T2.REBUILD). Without a data
    disk, the space check comes first, and when the image wouldn't fit, nothing is deleted. Returns a step result only for
    that failure.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [AllowNull()]
        [pscustomobject] $Finding,

        [string] $Reason = '',

        [switch] $Resume
    )

    $name = $Context.GuestName
    $recordPath = Get-DemoHostGuestRebuildPath -Context $Context
    $guestFolder = ''
    try {
        $guestFolder = [System.IO.Path]::Combine((Get-DemoHostDataPath -Context $Context -Kind 'Vms'), $name)
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The guest''s folder couldn''t be found: {0}' -f $_.Exception.Message)
    }
    $media = @()
    foreach ($mediaName in @($Context.Host.Media.WindowsServer, $Context.Host.Media.SqlServer, $Context.Host.Media.SqlDeveloper) | Where-Object { $_ } | Select-Object -Unique) {
        try {
            $file = (Get-DemoHostMediaFile -Context $Context -MediaName $mediaName).Path
            $media += @($file, ($file + '.partial'))
        }
        catch {
            Write-DemoVmLog -Level 'Warning' -Message ('The build media {0} couldn''t be found: {1}' -f $mediaName, $_.Exception.Message)
        }
    }
    $record = Read-DemoVmJsonFile -Path $recordPath
    if (-not $Resume -or $null -eq $record) {
        $space = Get-DemoHostGuestRebuildSpace -Context $Context -Path (@($guestFolder) + $media | Where-Object { $_ })
        if (-not $space.Ok) {
            return (New-DemoVmStepResult -Outcome 'Failed' -Message ('{0} was built in PaygWizard mode and its SQL Server setup was never finished, but the Jumpstart image wouldn''t fit on {1} after deleting it: {2:N1} GB free, {3:N1} GB freed, {4:N1} GB needed. Nothing was deleted. Set dataDiskSku to E10 in the configuration to add a data disk, or free space on {1}, then run ./scripts/deploy.ps1 again (ADR 0016).' -f $name, (Get-DemoHostSystemDrive), ($space.FreeBytes / 1GB), ($space.FreedBytes / 1GB), ($space.NeededBytes / 1GB)))
        }
        $oldMode = 'PaygWizard'
        $vmId = ''
        $arcResourceId = ''
        if ($null -ne $Finding) {
            if ($Finding.BuildMode) {
                $oldMode = [string]$Finding.BuildMode
            }
            $vmId = [string]$Finding.GuestVmId
            $arcResourceId = [string]$Finding.ArcResourceId
        }
        $record = [ordered]@{
            schemaVersion = 1
            state         = 'Removing'
            reason        = $Reason
            startedUtc    = Get-DemoVmUtcNow
            removedUtc    = ''
            oldMode       = $oldMode
            oldGuestVmId  = $vmId
            arcResourceId = $arcResourceId
            removed       = @()
        }
    }
    if (-not $PSCmdlet.ShouldProcess($name, 'Delete the unfinished guest, its disk, the build media, and its records')) {
        return
    }
    Write-DemoVmJsonFile -Path $recordPath -InputObject $record
    Write-DemoVmLog -Level 'Warning' -Message ('Rebuilding T2''s guest from Arc Jumpstart''s image: {0}' -f $(if ($Reason) { $Reason } else { [string]$record['reason'] }))
    $removed = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if ($vm) {
        if ([string]$vm.State -ne 'Off') {
            Stop-VM -Name $name -TurnOff -Force -ErrorAction Stop
        }
        Remove-VM -Name $name -Force -ErrorAction Stop
        $removed.Add(('the guest VM {0}' -f $name))
    }
    if ($guestFolder -and (Test-Path -LiteralPath $guestFolder)) {
        Remove-Item -LiteralPath $guestFolder -Recurse -Force -ErrorAction Stop
        $removed.Add(('its folder and disk {0}' -f $guestFolder))
    }
    foreach ($file in $media) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Remove-Item -LiteralPath $file -Force -ErrorAction Stop
            $removed.Add(('the build media {0}' -f (Split-Path -Path $file -Leaf)))
        }
    }
    $guided = Get-DemoGuidedSetupPath -Root $Context.Root
    $records = @(
        (Get-DemoHostGuestSourcePath -Context $Context), $Context.ArcMarkerPath, (Join-Path -Path $Context.Root -ChildPath 'guest-evaluation.json'),
        (Join-Path -Path $Context.Root -ChildPath 'jumpstart-image.json'), (Join-Path -Path $Context.Root -ChildPath 'jumpstart-firstboot.json'),
        $guided.HostRequest, $guided.HostArmed, $guided.HostSignIn, $guided.HostLast, $guided.HostConsoleScript, $guided.HostSteps)
    foreach ($file in $records) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Remove-Item -LiteralPath $file -Force -ErrorAction Stop
            $removed.Add((Split-Path -Path $file -Leaf))
        }
    }
    if (Get-ScheduledTask -TaskName 'DbHubDemo-GuestConsole' -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName 'DbHubDemo-GuestConsole' -Confirm:$false
        $removed.Add('the host logon task DbHubDemo-GuestConsole')
    }
    foreach ($file in @($Context.SecretPath, ($Context.SecretPath + '.pending'))) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Remove-Item -LiteralPath $file -Force -ErrorAction Stop
            $removed.Add('the guest''s protected password')
        }
    }
    $record['state'] = 'Removed'
    $record['removedUtc'] = Get-DemoVmUtcNow
    $record['removed'] = @(@($record['removed']) + $removed.ToArray() | Where-Object { $_ } | Select-Object -Unique)
    Write-DemoVmJsonFile -Path $recordPath -InputObject $record
    Write-DemoVmLog -Message ('Deleted the unfinished guest: {0}. The next steps download Arc Jumpstart''s image and make a new {1}; deploy.ps1 deletes the old guest''s Arc resources in Azure.' -f $(if ($removed.Count -gt 0) { $removed -join ', ' } else { 'nothing was left' }), $name)
}

function Set-DemoHostGuestSqlSetUp {
    # Records that SQL Server is set up in a build guest, with the mode it was built in, so JumpstartImage mode keeps that
    # mode on every later pass (Get-DemoHostEffectiveMode). Keeps the record's first time.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('PaygWizard', 'ProductKey', 'Developer')]
        [string] $Mode
    )

    if (-not $PSCmdlet.ShouldProcess($Context.GuestName, ('Record its SQL Server as set up, in {0} mode' -f $Mode))) {
        return
    }
    $path = Get-DemoHostGuestSourcePath -Context $Context
    $old = Read-DemoVmJsonFile -Path $path
    $recorded = Get-DemoVmUtcNow
    if ($null -ne $old -and [string]$old['recordedUtc']) {
        $recorded = [string]$old['recordedUtc']
    }
    Write-DemoVmJsonFile -Path $path -InputObject ([ordered]@{ source = 'Build'; installMode = $Mode; recordedUtc = $recorded; sqlSetUp = $true; sqlSetUpUtc = (Get-DemoVmUtcNow) })
}

function Invoke-DemoHostGuestSourceStep {
    <#
    .SYNOPSIS
    The GuestSource step's Set (2026-11-09). A rebuild that a stopped run left Removing finishes first. A guest whose source
    the mode can use needs nothing. In JumpstartImage mode, a build guest is planned (Get-DemoHostGuestSourcePlan): Rebuild
    deletes it (Remove-DemoHostGuest), and the image's steps that follow make a new one in this pass; Adopt records it and
    runs its own mode from now on; Wait throws, so the step tries again on the next pass, up to its attempts; Refuse fails
    with the reason and the fix (Get-DemoHostGuestSourceFailure). Any other mismatch fails as before.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $rebuild = Read-DemoVmJsonFile -Path (Get-DemoHostGuestRebuildPath -Context $Context)
    if ($null -ne $rebuild -and [string]$rebuild['state'] -eq 'Removing') {
        return (Remove-DemoHostGuest -Context $Context -Resume -Confirm:$false)
    }
    $decision = Get-DemoHostGuestSourceState -Context $Context
    if ($decision.Ok) {
        return
    }
    if ($decision.Recorded -ne 'Build' -or $Context.Mode -ne 'JumpstartImage') {
        return (Get-DemoHostGuestSourceFailure -Context $Context)
    }
    $finding = Get-DemoHostGuestFinding -Context $Context
    $plan = Get-DemoHostGuestSourcePlan -Finding $finding
    Write-DemoVmLog -Message ('The existing guest: built in {0}, SQL Server instance {1}, setup completed by the records {2}, read over PowerShell Direct {3}; plan {4}. {5}' -f $(if ($finding.BuildMode) { $finding.BuildMode + ' mode' } else { 'an unknown mode' }), $(if ($finding.DefaultInstance -or @($finding.NamedInstances).Count -gt 0) { 'present' } else { 'absent' }), $(if ($finding.WizardCompleted) { 'yes' } else { 'no' }), $(if ($finding.Reachable) { 'yes' } else { 'no' }), $plan.Action, $plan.Reason)
    switch ($plan.Action) {
        'Rebuild' {
            return (Remove-DemoHostGuest -Context $Context -Finding $finding -Reason $plan.Reason -Confirm:$false)
        }
        'Adopt' {
            Set-DemoHostGuestSqlSetUp -Context $Context -Mode $plan.GuestMode -Confirm:$false
            $Context.Mode = $plan.GuestMode
            $Context.ModeAdopted = $true
            Write-DemoVmLog -Message ('T2 keeps its guest as it is, in the mode it was built in, {0}: {1}' -f $plan.GuestMode, $plan.Reason)
            return
        }
        'Wait' {
            throw $plan.Reason
        }
        default {
            return (Get-DemoHostGuestSourceFailure -Context $Context -Reason $plan.Reason)
        }
    }
}

# ---- Free space and the guest's Windows evaluation ----

function Get-DemoHostStorageDetail {
    # Free space on the drive that holds the guest's disk, for health.json and status.ps1's early warning. Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $detail = [ordered]@{ drive = ''; freeGiB = $null; warnBelowGiB = [int]$Context.Host.Storage.LowSpaceWarningGB; low = $false }
    try {
        $drive = Get-DemoHostSystemDrive
        if (Test-DemoHostHasDataDisk -Context $Context) {
            $volume = Get-DemoVmDataVolume -Label $Context.Host.DataDisk.Label
            if ($volume) {
                $drive = '{0}:' -f $volume.DriveLetter
            }
        }
        $free = Get-DemoHostDriveFreeSpace -Drive $drive
        $detail.drive = $drive
        $detail.freeGiB = [Math]::Round($free / 1GB, 1)
        $detail.low = ($free -lt ([long]$detail.warnBelowGiB * 1GB))
    }
    catch {
        $detail.error = Protect-DemoVmText -Text $_.Exception.Message
    }
    return $detail
}

function Get-DemoGuestRearmDecision {
    <#
    .SYNOPSIS
    Pure: whether to extend the guest's Windows evaluation now. Only an evaluation (license channel TIMEBASED_EVAL) with
    RearmDays or fewer left; never while an activity profile runs (a rearm restarts the guest); a Warning when no rearm
    is left.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $License,

        [Parameter(Mandatory = $true)]
        [int] $RearmDays,

        [bool] $ProfileActive
    )

    if ($null -eq $License) {
        return [pscustomobject]@{ Action = 'None'; Reason = 'The guest''s license couldn''t be read.' }
    }
    if (-not [bool]$License.isEvaluation) {
        return [pscustomobject]@{ Action = 'None'; Reason = ('The guest''s Windows isn''t an evaluation ({0}).' -f $License.description) }
    }
    if ($null -eq $License.daysLeft -or [int]$License.daysLeft -gt $RearmDays) {
        return [pscustomobject]@{ Action = 'None'; Reason = ('{0} evaluation day(s) left; a rearm comes at {1} or fewer.' -f $License.daysLeft, $RearmDays) }
    }
    if ($null -eq $License.rearmCount -or [int]$License.rearmCount -le 0) {
        return [pscustomobject]@{ Action = 'Warn'; Reason = ('{0} evaluation day(s) left and no rearm left: rebuild T2 before the evaluation ends (./scripts/destroy.ps1, then ./scripts/deploy.ps1).' -f $License.daysLeft) }
    }
    if ($ProfileActive) {
        return [pscustomobject]@{ Action = 'None'; Reason = ('{0} evaluation day(s) left; the rearm waits until no activity profile runs, because it restarts the guest.' -f $License.daysLeft) }
    }
    return [pscustomobject]@{ Action = 'Rearm'; Reason = ('{0} evaluation day(s) left and {1} rearm(s) left.' -f $License.daysLeft, $License.rearmCount) }
}

# In the guest, read-only: the Windows license (an evaluation is the TIMEBASED_EVAL channel) and the rearms left.
$script:DemoGuestLicenseBlock = {
    $license = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" | Select-Object -First 1
    $service = Get-CimInstance -ClassName SoftwareLicensingService
    if (-not $license) {
        return $null
    }
    $isEvaluation = [string]$license.Description -match 'TIMEBASED_EVAL'
    $daysLeft = $null
    if ($isEvaluation) {
        $daysLeft = [int]([double]$license.GracePeriodRemaining / 1440)
    }
    [pscustomobject]@{
        description   = [string]$license.Description
        licenseStatus = [int]$license.LicenseStatus
        isEvaluation  = $isEvaluation
        daysLeft      = $daysLeft
        rearmCount    = [int]$service.RemainingWindowsReArmCount
    }
}

# In the guest, read-only: whether T2's activity profile runs now (demo.activity_profile in ContosoCare).
$script:DemoGuestProfileBlock = {
    try {
        $connection = New-Object -TypeName 'System.Data.SqlClient.SqlConnection' -ArgumentList 'Data Source=.;Initial Catalog=master;Integrated Security=True;Application Name=DbHubDemo.Bootstrap;Connect Timeout=15'
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = "IF DB_ID(N'ContosoCare') IS NULL SELECT 0 ELSE EXEC (N'SELECT COUNT(*) FROM ContosoCare.demo.activity_profile WHERE profile_name <> ''off'' AND (expires_at IS NULL OR expires_at > SYSUTCDATETIME())')"
        $active = [int]$command.ExecuteScalar() -gt 0
        $connection.Dispose()
        return $active
    }
    catch {
        # Unknown counts as running, so the guest is never restarted in doubt.
        return $true
    }
}

function Invoke-DemoHostEvaluationGuard {
    <#
    .SYNOPSIS
    Runs after a pass that finds the host Ready, at most every Evaluation.CheckIntervalHours: reads the guest's Windows
    license and, when Get-DemoGuestRearmDecision says so, extends its evaluation with slmgr.vbs /rearm (documented in
    "Slmgr.vbs options"), restarts the guest, and activates it online with /ato. Records the outcome in
    guest-evaluation.json for health.json. Skipped while a golden capture is in progress. Never throws.
    https://learn.microsoft.com/windows-server/get-started/activation-slmgr-vbs-options
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $path = Join-Path -Path $Context.Root -ChildPath 'guest-evaluation.json'
    try {
        $previous = Read-DemoVmJsonFile -Path $path
        $hours = [int]$Context.Host.Evaluation.CheckIntervalHours
        if ($null -ne $previous -and $previous['checkedUtc']) {
            $checked = [DateTime]::MinValue
            if ([DateTime]::TryParse([string]$previous['checkedUtc'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$checked) -and $checked.AddHours($hours) -gt [DateTime]::UtcNow) {
                return
            }
        }
        if (Test-Path -LiteralPath ([System.IO.Path]::Combine($Context.Root, 'golden', 'capture-in-progress.json')) -PathType Leaf) {
            return
        }
        if (-not (Test-DemoHostGuestReachable -Context $Context)) {
            return
        }
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        $license = Invoke-Command -VMName $Context.GuestName -Credential $credential -ScriptBlock $script:DemoGuestLicenseBlock -ErrorAction Stop
        $active = $false
        if ($null -ne $license -and [bool]$license.isEvaluation) {
            $active = [bool](Invoke-Command -VMName $Context.GuestName -Credential $credential -ScriptBlock $script:DemoGuestProfileBlock -ErrorAction Stop)
        }
        $decision = Get-DemoGuestRearmDecision -License $license -RearmDays ([int]$Context.Host.Evaluation.RearmDays) -ProfileActive $active
        $record = [ordered]@{ checkedUtc = (Get-DemoVmUtcNow); license = $license; action = $decision.Action; reason = $decision.Reason }
        if ($null -ne $previous -and $previous['lastRearmUtc']) {
            $record.lastRearmUtc = $previous['lastRearmUtc']
        }
        if ($decision.Action -eq 'Rearm') {
            Write-DemoVmLog -Message ('Extending the guest''s Windows evaluation: {0}' -f $decision.Reason)
            $rearm = Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ScriptBlock {
                $output = & cscript.exe //nologo (Join-Path -Path $env:windir -ChildPath 'System32\slmgr.vbs') /rearm
                [pscustomobject]@{ exitCode = $LASTEXITCODE; output = (@($output) -join ' ') }
            }
            Invoke-Command -VMName $Context.GuestName -Credential $credential -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 30
            if (Wait-DemoGuestOnline -Name $Context.GuestName -Credential $credential -TimeoutMinutes 15) {
                $activation = Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ScriptBlock {
                    $output = & cscript.exe //nologo (Join-Path -Path $env:windir -ChildPath 'System32\slmgr.vbs') /ato
                    [pscustomobject]@{ exitCode = $LASTEXITCODE; output = (@($output) -join ' ') }
                }
                $record.after = Invoke-Command -VMName $Context.GuestName -Credential $credential -ScriptBlock $script:DemoGuestLicenseBlock -ErrorAction Stop
                $record.activation = [ordered]@{ exitCode = $activation.exitCode; output = (Protect-DemoVmText -Text ([string]$activation.output)) }
            }
            $record.rearm = [ordered]@{ exitCode = $rearm.exitCode; output = (Protect-DemoVmText -Text ([string]$rearm.output)) }
            $record.lastRearmUtc = Get-DemoVmUtcNow
        }
        elseif ($decision.Action -eq 'Warn') {
            Write-DemoVmLog -Level 'Warning' -Message $decision.Reason
        }
        Write-DemoVmJsonFile -Path $path -InputObject $record -Redact
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The guest''s evaluation check didn''t finish; it runs again later: {0}' -f $_.Exception.Message)
    }
}
