# Builds the T2 guest's boot disk on the Hyper-V host (ADR 0003). Windows PowerShell 5.1.
# Dot-sourced by vm/bootstrap/Invoke-HostBootstrap.ps1.

function ConvertFrom-DemoSecureString {
    # In memory only; callers never log the result.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [securestring] $SecureValue
    )

    $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Format-DemoUnattendXml {
    <#
    .SYNOPSIS
    Fills unattend.template.xml in memory. The result holds the guest password, so it's only ever written
    into the mounted VHDX (ADR 0009).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $TemplatePath,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
        [string] $ComputerName,

        [Parameter(Mandatory = $true)]
        [string] $TimeZone,

        [Parameter(Mandatory = $true)]
        [securestring] $AdministratorPassword
    )

    $template = [System.IO.File]::ReadAllText($TemplatePath)
    $secret = ConvertFrom-DemoSecureString -SecureValue $AdministratorPassword
    $xml = $template.Replace('{{COMPUTER_NAME}}', [System.Security.SecurityElement]::Escape($ComputerName))
    $xml = $xml.Replace('{{TIME_ZONE}}', [System.Security.SecurityElement]::Escape($TimeZone))
    $xml = $xml.Replace('{{ADMINISTRATOR_SECRET}}', [System.Security.SecurityElement]::Escape($secret))
    if ($xml -match '\{\{[A-Z_]+\}\}') {
        throw 'The unattend template has an unreplaced token.'
    }
    [void][xml]$xml
    return $xml
}

function Get-DemoWindowsImageIndex {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ImagePath,

        [Parameter(Mandatory = $true)]
        [string] $NamePattern
    )

    $images = @(Get-WindowsImage -ImagePath $ImagePath)
    $match = $images | Where-Object { $_.ImageName -like $NamePattern } | Select-Object -First 1
    if (-not $match) {
        throw ('No image matches "{0}". The ISO has: {1}' -f $NamePattern, (($images | ForEach-Object { $_.ImageName }) -join '; '))
    }
    return [int]$match.ImageIndex
}

function Test-DemoGuestVhdx {
    # The build writes <vhdx>.built only after bcdboot succeeds, so a half-built disk never passes.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $VhdxPath
    )

    return ((Test-Path -LiteralPath $VhdxPath -PathType Leaf) -and (Test-Path -LiteralPath ($VhdxPath + '.built') -PathType Leaf))
}

function Get-DemoBcdbootArgument {
    <#
    .SYNOPSIS
    bcdboot arguments that write UEFI boot files for an offline Windows image to a system partition.

    .DESCRIPTION
    The guest image is offline, so /offline is passed whenever the host's bcdboot lists it in bcdboot /?.
    A patched host's bcdboot otherwise chooses the boot files from the running system's Secure Boot
    servicing state (CVE-2023-24932 "bootex" binaries in Windows\Boot\EFI_EX). The Windows Server 2022
    evaluation image has no EFI_EX folder, and bcdboot then fails with "BFSVC Error: Failed to create a
    new system store. Status = [c000003a]" and exit code 3 (live finding, 2026-10-20: host bcdboot
    10.0.20348.2849, image 10.0.20348.1; /offline succeeded). /offline without /bootex forces the image's
    standard boot files. Older bcdboot builds have neither the switch nor the bootex selection.
    https://learn.microsoft.com/windows-hardware/manufacture/desktop/bcdboot-command-line-options-techref-di
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $BcdbootPath,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z]$')]
        [string] $WindowsLetter,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z]$')]
        [string] $SystemLetter
    )

    $arguments = @(('{0}:\Windows' -f $WindowsLetter), '/s', ('{0}:' -f $SystemLetter), '/f', 'UEFI')
    $help = Invoke-DemoVmNativeCommand -FilePath $BcdbootPath -ArgumentList @('/?')
    if (@($help.Output | Where-Object { [string]$_ -match '^\s*/offline\b' }).Count -gt 0) {
        $arguments += '/offline'
    }
    return $arguments
}

function Build-DemoGuestVhdx {
    <#
    .SYNOPSIS
    Builds a bootable Generation 2 VHDX from the Windows Server ISO with DISM, then adds the unattend file.

    .DESCRIPTION
    GPT layout: EFI system partition (FAT32), MSR, Windows (NTFS). The ESP is created as a basic data
    partition so it can be formatted and mounted for bcdboot, then retyped once bcdboot has written the
    UEFI boot files. Any failure deletes the partial disk so the next run starts clean.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $IsoPath,

        [Parameter(Mandatory = $true)]
        [string] $VhdxPath,

        [Parameter(Mandatory = $true)]
        [ValidateRange(40, 1024)]
        [int] $SizeGB,

        [Parameter(Mandatory = $true)]
        [string] $ImageNamePattern,

        [Parameter(Mandatory = $true)]
        [string] $UnattendXml
    )

    $basicData = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $marker = $VhdxPath + '.built'
    foreach ($path in @($marker, $VhdxPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    $directory = Split-Path -Path $VhdxPath -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $isoMounted = $false
    $vhdMounted = $false
    try {
        $isoVolume = Mount-DiskImage -ImagePath $IsoPath -PassThru | Get-Volume
        $isoMounted = $true
        $wim = '{0}:\sources\install.wim' -f $isoVolume.DriveLetter
        if (-not (Test-Path -LiteralPath $wim)) {
            throw 'sources\install.wim was not found on the Windows Server ISO.'
        }
        $index = Get-DemoWindowsImageIndex -ImagePath $wim -NamePattern $ImageNamePattern
        Write-DemoVmLog -Message ('Applying image index {0} to a {1} GB dynamic VHDX.' -f $index, $SizeGB)

        New-VHD -Path $VhdxPath -SizeBytes ([int64]$SizeGB * 1GB) -Dynamic | Out-Null
        $disk = Mount-VHD -Path $VhdxPath -Passthru | Get-Disk
        $vhdMounted = $true
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null

        $system = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType $basicData
        Format-Volume -Partition $system -FileSystem FAT32 -NewFileSystemLabel 'System' -Force -Confirm:$false | Out-Null
        New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
        $windows = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType $basicData
        Format-Volume -Partition $windows -FileSystem NTFS -NewFileSystemLabel 'Windows' -Force -Confirm:$false | Out-Null
        # Letters are assigned while the system partition is still a basic data partition: Windows doesn't
        # mount an EFI system partition, so a letter assigned after retyping is unusable and bcdboot fails
        # with "Failure when initializing library system volume" and exit code 87 (tested live,
        # 2026-10-20). The partition is retyped to the EFI system partition GUID after bcdboot.
        $system | Add-PartitionAccessPath -AssignDriveLetter
        $windows | Add-PartitionAccessPath -AssignDriveLetter
        $systemLetter = [string](Get-Partition -DiskNumber $disk.Number -PartitionNumber $system.PartitionNumber).DriveLetter
        $windowsLetter = [string](Get-Partition -DiskNumber $disk.Number -PartitionNumber $windows.PartitionNumber).DriveLetter
        foreach ($letter in @($systemLetter, $windowsLetter)) {
            if ($letter -notmatch '^[A-Za-z]$') {
                throw 'A partition of the new VHDX got no drive letter, so the image and the boot files have nowhere to go.'
            }
        }

        Expand-WindowsImage -ImagePath $wim -Index $index -ApplyPath ('{0}:\' -f $windowsLetter) | Out-Null

        $panther = '{0}:\Windows\Panther' -f $windowsLetter
        New-Item -ItemType Directory -Path $panther -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $panther -ChildPath 'unattend.xml'), $UnattendXml, (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))

        $bcdboot = Join-Path -Path $env:SystemRoot -ChildPath 'System32\bcdboot.exe'
        # bcdboot writes diagnostics to stderr even when it succeeds, so the exit code decides (Invoke-DemoVmNativeCommand).
        $result = Invoke-DemoVmNativeCommand -FilePath $bcdboot -ArgumentList (Get-DemoBcdbootArgument -BcdbootPath $bcdboot -WindowsLetter $windowsLetter -SystemLetter $systemLetter)
        if ($result.ExitCode -ne 0) {
            throw ('bcdboot failed with exit code {0}: {1}' -f $result.ExitCode, ($result.Output -join ' '))
        }
        $system | Remove-PartitionAccessPath -AccessPath ('{0}:\' -f $systemLetter)
        $windows | Remove-PartitionAccessPath -AccessPath ('{0}:\' -f $windowsLetter)
        $system | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    }
    catch {
        $failure = $_
        if ($vhdMounted) {
            Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
            $vhdMounted = $false
        }
        Remove-Item -LiteralPath $VhdxPath -Force -ErrorAction SilentlyContinue
        throw $failure
    }
    finally {
        if ($vhdMounted) {
            Dismount-VHD -Path $VhdxPath
        }
        if ($isoMounted) {
            Dismount-DiskImage -ImagePath $IsoPath | Out-Null
        }
    }
    [System.IO.File]::WriteAllText($marker, (Get-Date).ToUniversalTime().ToString('o'))
    Write-DemoVmLog -Message 'The guest VHDX is built.'
}
