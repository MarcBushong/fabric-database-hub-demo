<#
.SYNOPSIS
Phase 26d: overwrites the free space of the T2 guest's and host's volumes with zeros, and compacts the guest's
dynamic VHDX, before a golden capture (ADR 0009, ADR 0018).

.DESCRIPTION
A file scan can't prove that deleted data, such as sign-in data the cleanup removed, is gone from a volume's
free space. This script overwrites it with zeros using only built-in PowerShell, and then hands the zeroed
space back, so the incremental golden snapshot doesn't keep it:
- GuestFill (the guest running): checks that the host's C: has at least MinHostFreeGB free, because filling
  the guest's free space grows its dynamic VHDX toward its maximum size. Then, in the guest over PowerShell
  Direct: Optimize-Volume -ReTrim (the TRIM pass), a file of zeros written until GuestMarginGB is left, the
  file deleted, and Optimize-Volume -ReTrim again.
- HostCompact (the guest off): mounts each of the guest's VHDX files read-only and runs Optimize-VHD -Mode
  Full, which reclaims the zeroed blocks; then the host's C: gets the same zero fill (HostMarginGB left), the
  file is deleted, and Optimize-Volume -ReTrim tells the managed disk which blocks are free, so the snapshot
  doesn't hold them. Deleted Run Command handler files on the host are overwritten the same way.
Windows PowerShell 5.1, self-contained. The last line of output is one compact JSON object with sizes and
seconds only; exit code 0 means the action succeeded.

Sources (checked 2026-10-27):
- Optimize-VHD (Full needs the VHDX unattached or attached read-only): https://learn.microsoft.com/powershell/module/hyper-v/optimize-vhd
- Mount-VHD -ReadOnly: https://learn.microsoft.com/powershell/module/hyper-v/mount-vhd
- Optimize-Volume -ReTrim: https://learn.microsoft.com/powershell/module/storage/optimize-volume
- TRIM and unmap on Azure managed disks: https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots

.PARAMETER WipeAction
GuestFill or HostCompact.

.PARAMETER MinHostFreeGB
The free space the host's C: needs before GuestFill starts.
#>
[CmdletBinding()]
param(
    [string] $WipeAction = 'GuestFill',
    [string] $WipeGuestName = 'arcsql01',
    [string] $MinHostFreeGB = '45',
    [string] $GuestMarginGB = '1',
    [string] $HostMarginGB = '4',
    [string] $MaxMinutes = '120',
    [string] $WipeStateRoot = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest

function Write-DemoZeroFill {
    <#
    .SYNOPSIS
    Writes zeros into one file in Folder until the volume has MarginBytes free, MaxBytes are written, or the time
    is up, then deletes the file. Returns bytes written and seconds. Defined as a script block below too, for the guest.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Folder,

        [long] $MarginBytes = 1GB,

        [long] $MaxBytes = [long]::MaxValue,

        [int] $MaxSeconds = 7200,

        [scriptblock] $FreeSpaceReader
    )

    $reader = $FreeSpaceReader
    if ($null -eq $reader) {
        $reader = { param($Path) (New-Object -TypeName 'System.IO.DriveInfo' -ArgumentList ([System.IO.Path]::GetPathRoot($Path))).AvailableFreeSpace }
    }
    if (-not (Test-Path -LiteralPath $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }
    $path = Join-Path -Path $Folder -ChildPath ('zero-fill-{0}.bin' -f [guid]::NewGuid().ToString('N'))
    $buffer = New-Object -TypeName 'byte[]' -ArgumentList (4MB)
    $written = [long]0
    $stopped = 'margin'
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    try {
        $stream = New-Object -TypeName 'System.IO.FileStream' -ArgumentList $path, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None), 4MB
        while ($true) {
            $free = [long](& $reader $Folder)
            if ($free -le $MarginBytes) {
                $stopped = 'margin'
                break
            }
            if ($written -ge $MaxBytes) {
                $stopped = 'max'
                break
            }
            if ($clock.Elapsed.TotalSeconds -ge $MaxSeconds) {
                $stopped = 'time'
                break
            }
            $count = [long][System.Math]::Min([long]$buffer.Length, [System.Math]::Min($free - $MarginBytes, $MaxBytes - $written))
            try {
                $stream.Write($buffer, 0, [int]$count)
            }
            catch [System.IO.IOException] {
                $stopped = 'full'
                break
            }
            $written += $count
        }
        try {
            $stream.Flush($true)
        }
        catch [System.IO.IOException] {
            $stopped = 'full'
        }
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ bytes = $written; seconds = [int]$clock.Elapsed.TotalSeconds; stopped = $stopped; left = [bool](Test-Path -LiteralPath $path) }
}

function Get-DemoWipeFreeSpace {
    # The free bytes of the volume that holds Path.
    param([string] $Path)
    return [long](New-Object -TypeName 'System.IO.DriveInfo' -ArgumentList ([System.IO.Path]::GetPathRoot($Path))).AvailableFreeSpace
}

function Get-DemoWipeGuestCredential {
    # The guest administrator's credentials from the host's DPAPI store (the current one, then a pending one).
    param([string] $Root)
    Add-Type -AssemblyName 'System.Security'
    $credentials = @()
    $path = [System.IO.Path]::Combine($Root, 'protected', 'guest-administrator.bin')
    foreach ($candidate in @($path, ($path + '.pending'))) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([System.IO.File]::ReadAllBytes($candidate), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $secure = New-Object -TypeName 'System.Security.SecureString'
        foreach ($character in [System.Text.Encoding]::UTF8.GetString($bytes).ToCharArray()) {
            $secure.AppendChar($character)
        }
        [System.Array]::Clear($bytes, 0, $bytes.Length)
        $secure.MakeReadOnly()
        $credentials += New-Object -TypeName 'System.Management.Automation.PSCredential' -ArgumentList 'Administrator', $secure
    }
    return $credentials
}

function Invoke-DemoGuestFill {
    # The TRIM pass, the zero fill, and TRIM again, in the guest over PowerShell Direct.
    param([string] $Name, [System.Management.Automation.PSCredential[]] $Credential, [long] $MarginBytes, [int] $MaxSeconds)
    $fill = ${function:Write-DemoZeroFill}.ToString()
    $block = {
        param($FillText, $Margin, $Seconds)
        $ErrorActionPreference = 'Stop'
        $writer = [scriptblock]::Create($FillText)
        $drive = New-Object -TypeName 'System.IO.DriveInfo' -ArgumentList 'C:\'
        $before = [long]$drive.AvailableFreeSpace
        $trim = { try { Optimize-Volume -DriveLetter C -ReTrim -ErrorAction Stop; 'done' } catch { 'failed: ' + $_.Exception.Message } }
        $first = & $trim
        $zero = & $writer -Folder 'C:\DbHubDemo\wipe' -MarginBytes $Margin -MaxSeconds $Seconds
        Remove-Item -LiteralPath 'C:\DbHubDemo\wipe' -Recurse -Force -ErrorAction SilentlyContinue
        $second = & $trim
        [pscustomobject]@{ freeBefore = $before; freeAfter = [long](New-Object -TypeName 'System.IO.DriveInfo' -ArgumentList 'C:\').AvailableFreeSpace; bytes = $zero.bytes; seconds = $zero.seconds; stopped = $zero.stopped; left = $zero.left; trimBefore = [string]$first; trimAfter = [string]$second }
    }
    $lastError = ''
    foreach ($candidate in $Credential) {
        try {
            return (Invoke-Command -VMName $Name -Credential $candidate -ScriptBlock $block -ArgumentList $fill, $MarginBytes, $MaxSeconds -ErrorAction Stop)
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }
    throw ('The guest {0} couldn''t be reached over PowerShell Direct: {1}' -f $Name, $lastError)
}

function Invoke-DemoHostCompact {
    # With the guest off: Optimize-VHD -Mode Full on each of its VHDX files (mounted read-only), then the host's
    # zero fill and TRIM.
    param([string] $Name, [long] $MarginBytes, [int] $MaxSeconds)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ([string]$vm.State -ne 'Off') {
        throw ('The guest {0} is {1}; it must be off to compact its disk.' -f $Name, $vm.State)
    }
    $disks = @()
    foreach ($drive in @(Get-VMHardDiskDrive -VMName $Name)) {
        $path = [string]$drive.Path
        $sizeBefore = [long](Get-Item -LiteralPath $path).Length
        Mount-VHD -Path $path -ReadOnly -NoDriveLetter -ErrorAction Stop | Out-Null
        try {
            Optimize-VHD -Path $path -Mode Full -ErrorAction Stop
        }
        finally {
            Dismount-VHD -Path $path -ErrorAction Stop
        }
        $disks += [pscustomobject]@{ file = ($path -split '[\\/]')[-1]; bytesBefore = $sizeBefore; bytesAfter = [long](Get-Item -LiteralPath $path).Length }
    }
    $before = Get-DemoWipeFreeSpace -Path 'C:\'
    $zero = Write-DemoZeroFill -Folder 'C:\DbHubDemo\wipe' -MarginBytes $MarginBytes -MaxSeconds $MaxSeconds
    Remove-Item -LiteralPath 'C:\DbHubDemo\wipe' -Recurse -Force -ErrorAction SilentlyContinue
    $trim = 'done'
    try {
        Optimize-Volume -DriveLetter C -ReTrim -ErrorAction Stop
    }
    catch {
        $trim = 'failed: ' + $_.Exception.Message
    }
    return [pscustomobject]@{ disks = $disks; freeBefore = $before; freeAfter = (Get-DemoWipeFreeSpace -Path 'C:\'); bytes = $zero.bytes; seconds = $zero.seconds; stopped = $zero.stopped; left = $zero.left; trim = $trim; guestState = [string](Get-VM -Name $Name).State }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $exitCode = 1
    try {
        if ($WipeAction -notin 'GuestFill', 'HostCompact') {
            throw ('Unknown action {0}.' -f $WipeAction)
        }
        if ($WipeGuestName -notmatch '^[A-Za-z0-9-]{1,15}$') {
            throw 'WipeGuestName is not valid.'
        }
        $maxSeconds = [int]$MaxMinutes * 60
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $outcome = [ordered]@{ action = $WipeAction; succeeded = $false }
        if ($WipeAction -eq 'GuestFill') {
            $hostFree = Get-DemoWipeFreeSpace -Path 'C:\'
            $outcome['hostFreeBefore'] = $hostFree
            if ($hostFree -lt ([long]$MinHostFreeGB * 1GB)) {
                throw ('The host''s C: has {0:N1} GB free, under the {1} GB the guest''s disk may grow to; nothing was written.' -f ($hostFree / 1GB), $MinHostFreeGB)
            }
            $credentials = @(Get-DemoWipeGuestCredential -Root $WipeStateRoot)
            if ($credentials.Count -eq 0) {
                throw 'The guest administrator''s credential isn''t stored on the host.'
            }
            $guest = Invoke-DemoGuestFill -Name $WipeGuestName -Credential $credentials -MarginBytes ([long]$GuestMarginGB * 1GB) -MaxSeconds $maxSeconds
            $outcome['guest'] = $guest
            $outcome['hostFreeAfter'] = Get-DemoWipeFreeSpace -Path 'C:\'
            $outcome['succeeded'] = -not [bool]$guest.left -and $guest.stopped -in 'margin', 'full'
            if (-not $outcome['succeeded']) {
                $outcome['error'] = 'The guest''s zero fill stopped early ({0}) or its file was left.' -f $guest.stopped
            }
        }
        else {
            $compact = Invoke-DemoHostCompact -Name $WipeGuestName -MarginBytes ([long]$HostMarginGB * 1GB) -MaxSeconds $maxSeconds
            $outcome['host'] = $compact
            $outcome['succeeded'] = -not [bool]$compact.left -and $compact.stopped -in 'margin', 'full' -and $compact.guestState -eq 'Off'
            if (-not $outcome['succeeded']) {
                $outcome['error'] = 'The host''s zero fill stopped early ({0}), its file was left, or the guest isn''t off.' -f $compact.stopped
            }
        }
        $outcome['seconds'] = [int]$clock.Elapsed.TotalSeconds
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $outcome -Compress -Depth 5))
        if ($outcome['succeeded']) {
            $exitCode = 0
        }
    }
    catch {
        $message = [string]$_.Exception.Message
        [Console]::Error.WriteLine('DbHubDemo disk wipe ' + $WipeAction + ' failed: ' + $message)
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([ordered]@{ action = $WipeAction; succeeded = $false; error = $message }) -Compress))
    }
    exit $exitCode
}
