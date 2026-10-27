function Invoke-DemoVmNativeCommand {
    <#
    .SYNOPSIS
    Runs a native program and returns its exit code and its output (stdout and stderr) as text.

    .DESCRIPTION
    Windows PowerShell 5.1 turns every stderr line of a redirected native command into an error record, and
    with $ErrorActionPreference = 'Stop' the first one ends the script, even when the program succeeds. Tools
    such as bcdboot write diagnostics to stderr on success ("BFSVC Error: Failed to create a new system
    store" with exit code 0; live finding, 2026-10-20). This runs the program with 'Continue' and leaves the
    decision to the exit code.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [string[]] $ArgumentList = @()
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Protect-DemoVmFolder {
    <#
    .SYNOPSIS
    Restricts a folder or file to SYSTEM and Administrators (well-known SIDs, so any OS language works).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (Test-Path -LiteralPath $Path -PathType Container) {
        # Set the ACL on the folder only: '/grant' with '/T' strips the inherited entries from files and leaves
        # them with an empty ACL that nobody can read. Children then inherit, and '/reset' repairs any child
        # whose ACL isn't inherited (for example one damaged by an earlier '/T' run).
        $result = Invoke-DemoVmNativeCommand -FilePath 'icacls.exe' -ArgumentList @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '/C', '/Q')
        if ($result.ExitCode -eq 0 -and (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            $result = Invoke-DemoVmNativeCommand -FilePath 'icacls.exe' -ArgumentList @((Join-Path -Path $Path -ChildPath '*'), '/reset', '/T', '/C', '/Q')
        }
    }
    else {
        $result = Invoke-DemoVmNativeCommand -FilePath 'icacls.exe' -ArgumentList @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:F', '*S-1-5-32-544:F', '/C', '/Q')
    }
    if ($result.ExitCode -ne 0) {
        throw ('icacls failed with exit code {0} for {1}: {2}' -f $result.ExitCode, $Path, ($result.Output -join ' '))
    }
}

function Protect-DemoVmSecret {
    <#
    .SYNOPSIS
    Stores a value with DPAPI (LocalMachine scope) in a file only SYSTEM and Administrators can read (ADR 0009).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    Add-Type -AssemblyName 'System.Security'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [System.IO.File]::WriteAllBytes($Path, $protected)
    Protect-DemoVmFolder -Path $Path
}

function Unprotect-DemoVmSecret {
    <#
    .SYNOPSIS
    Reads a value stored by Protect-DemoVmSecret. The caller never logs it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    Add-Type -AssemblyName 'System.Security'
    $protected = [System.IO.File]::ReadAllBytes($Path)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    $value = [System.Text.Encoding]::UTF8.GetString($bytes)
    Register-DemoVmSecret -Value $value
    return $value
}

function Get-DemoVmRandomIndex {
    # Uniform random index from a cryptographic generator (rejection sampling avoids modulo bias).
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RandomNumberGenerator] $Generator,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65536)]
        [int] $Count
    )

    $buffer = New-Object -TypeName 'byte[]' -ArgumentList 4
    $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$Count)
    while ($true) {
        $Generator.GetBytes($buffer)
        $value = [System.BitConverter]::ToUInt32($buffer, 0)
        if ($value -lt $limit) {
            return [int]($value % [uint32]$Count)
        }
    }
}

function Build-DemoVmPassword {
    <#
    .SYNOPSIS
    Returns a cryptographically random password for the guest administrator (ADR 0009).

    .DESCRIPTION
    At least two characters from each of upper case, lower case, digits, and symbols; it starts with a
    letter and avoids characters that need escaping in XML, command lines, or JSON. The value is registered
    for redaction and never logged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateRange(16, 64)]
        [int] $Length = 24
    )

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $symbols = '!#%*+-=?^_~'
    $all = $upper + $lower + $digits + $symbols
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $chars = New-Object -TypeName 'System.Collections.Generic.List[char]'
        foreach ($set in @($upper, $lower, $digits, $symbols)) {
            for ($i = 0; $i -lt 2; $i++) {
                $chars.Add($set[(Get-DemoVmRandomIndex -Generator $generator -Count $set.Length)])
            }
        }
        while ($chars.Count -lt $Length) {
            $chars.Add($all[(Get-DemoVmRandomIndex -Generator $generator -Count $all.Length)])
        }
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = Get-DemoVmRandomIndex -Generator $generator -Count ($i + 1)
            $swap = $chars[$i]
            $chars[$i] = $chars[$j]
            $chars[$j] = $swap
        }
        $letters = $upper + $lower
        if ($letters.IndexOf($chars[0]) -lt 0) {
            for ($i = 1; $i -lt $chars.Count; $i++) {
                if ($letters.IndexOf($chars[$i]) -ge 0) {
                    $swap = $chars[0]
                    $chars[0] = $chars[$i]
                    $chars[$i] = $swap
                    break
                }
            }
        }
        $value = -join $chars.ToArray()
    }
    finally {
        $generator.Dispose()
    }
    Register-DemoVmSecret -Value $value
    return $value
}

function Get-DemoVmDataVolume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    return (Get-Volume | Where-Object { $_.FileSystemLabel -eq $Label -and $_.FileSystem -eq 'NTFS' -and $_.DriveLetter } | Select-Object -First 1)
}

function Initialize-DemoVmDataDisk {
    <#
    .SYNOPSIS
    Formats the raw data disk at the given LUN as one NTFS volume with a label, once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Label,

        [ValidatePattern('^[F-Z]$')]
        [string] $DriveLetter = 'F',

        [ValidateRange(0, 63)]
        [int] $Lun = 0,

        [ValidateSet(4096, 65536)]
        [int] $AllocationUnitSize = 65536
    )

    $existing = Get-DemoVmDataVolume -Label $Label
    if ($existing) {
        return $existing
    }
    $raw = @(Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' })
    $disk = $raw | Where-Object { [string]$_.Location -match ('LUN {0}(\D|$)' -f $Lun) } | Select-Object -First 1
    if (-not $disk -and $raw.Count -eq 1) {
        $disk = $raw[0]
    }
    if (-not $disk) {
        throw ('No uninitialized data disk was found at LUN {0}.' -f $Lun)
    }
    if ($disk.IsOffline) {
        Set-Disk -Number $disk.Number -IsOffline $false
    }
    if ($disk.IsReadOnly) {
        Set-Disk -Number $disk.Number -IsReadOnly $false
    }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $letterInUse = $null -ne (Get-Volume | Where-Object { [string]$_.DriveLetter -eq $DriveLetter } | Select-Object -First 1)
    if ($letterInUse) {
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    }
    else {
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $DriveLetter
    }
    $volume = Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $Label -AllocationUnitSize $AllocationUnitSize -Confirm:$false
    Write-DemoVmLog -Message ('Formatted the data disk at LUN {0} as {1}: ({2}).' -f $Lun, $volume.DriveLetter, $Label)
    return $volume
}
