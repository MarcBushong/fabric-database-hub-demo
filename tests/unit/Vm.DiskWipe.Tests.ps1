BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoDiskWipe.ps1')

    # Hyper-V and Storage cmdlets don't exist on every test machine, so the tests mock these stand-ins.
    function Get-VM { param($Name) $null = $Name }
    function Get-VMHardDiskDrive { param($VMName) $null = $VMName }
    function Mount-VHD { param($Path, [switch] $ReadOnly, [switch] $NoDriveLetter) $null = $Path, $ReadOnly, $NoDriveLetter }
    function Optimize-VHD { param($Path, $Mode) $null = $Path, $Mode }
    function Dismount-VHD { param($Path) $null = $Path }
    function Optimize-Volume { param($DriveLetter, [switch] $ReTrim) $null = $DriveLetter, $ReTrim }
}

Describe 'Write-DemoZeroFill' {
    It 'writes zeros until the limit, then deletes its file' {
        $folder = Join-Path -Path $TestDrive -ChildPath ('fill-' + [guid]::NewGuid().ToString('N'))
        $result = Write-DemoZeroFill -Folder $folder -MarginBytes 0 -MaxBytes (10MB) -FreeSpaceReader { param($Path) $null = $Path; 1TB }
        $result.bytes | Should -Be (10MB)
        $result.stopped | Should -Be 'max'
        $result.left | Should -BeFalse
        @(Get-ChildItem -LiteralPath $folder -Force).Count | Should -Be 0
    }

    It 'writes nothing when the volume is already at its margin, and stops when the time is up' {
        $folder = Join-Path -Path $TestDrive -ChildPath ('fill-' + [guid]::NewGuid().ToString('N'))
        $atMargin = Write-DemoZeroFill -Folder $folder -MarginBytes (2GB) -FreeSpaceReader { param($Path) $null = $Path; 1GB }
        $atMargin.bytes | Should -Be 0
        $atMargin.stopped | Should -Be 'margin'
        $timed = Write-DemoZeroFill -Folder $folder -MarginBytes 0 -MaxSeconds 0 -FreeSpaceReader { param($Path) $null = $Path; 1TB }
        $timed.stopped | Should -Be 'time'
        $timed.left | Should -BeFalse
    }

    It 'leaves the margin free: it never writes past it' {
        $folder = Join-Path -Path $TestDrive -ChildPath ('fill-' + [guid]::NewGuid().ToString('N'))
        # The volume has 8 MB free, then 4 MB after the first 4 MB write, then nothing.
        $script:reads = 0
        $result = Write-DemoZeroFill -Folder $folder -MarginBytes (3MB) -MaxBytes (64MB) -FreeSpaceReader { param($Path) $null = $Path; $script:reads++; [long][System.Math]::Max(0, 8MB - (4MB * ($script:reads - 1))) }
        $result.bytes | Should -Be (5MB) -Because 'each write is capped at the free space above the margin'
        $result.stopped | Should -Be 'margin'
    }
}

Describe 'Invoke-DemoGuestFill' {
    It 'sends the zero fill and both TRIM passes to the guest, with a stored credential tried in order' {
        $script:sent = $null
        Mock -CommandName Invoke-Command -MockWith {
            $script:sent = [pscustomobject]@{ Name = $VMName; Block = $ScriptBlock.ToString(); Arguments = @($ArgumentList) }
            [pscustomobject]@{ bytes = 5GB; stopped = 'margin'; left = $false }
        }
        $secure = [System.Security.SecureString]::new()
        foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
        $credential = [System.Management.Automation.PSCredential]::new('Administrator', $secure)
        $outcome = Invoke-DemoGuestFill -Name 'arcsql01' -Credential @($credential) -MarginBytes (1GB) -MaxSeconds 600
        $outcome.stopped | Should -Be 'margin'
        $script:sent.Name | Should -Be 'arcsql01'
        $script:sent.Block | Should -Match ([regex]::Escape('Optimize-Volume -DriveLetter C -ReTrim'))
        $script:sent.Arguments[0] | Should -Match 'FileStream' -Because 'the zero fill travels as text, so the guest needs nothing installed'
        $script:sent.Arguments[1] | Should -Be (1GB)
    }
}

Describe 'Invoke-DemoHostCompact' {
    BeforeEach {
        $script:steps = [System.Collections.Generic.List[string]]::new()
        $script:guestState = 'Off'
        Mock -CommandName Get-VM -MockWith { [pscustomobject]@{ State = $script:guestState } }
        Mock -CommandName Get-VMHardDiskDrive -MockWith { [pscustomobject]@{ Path = 'C:\DbHubDemo\vhd\arcsql01.vhdx' } }
        Mock -CommandName Get-Item -MockWith { [pscustomobject]@{ Length = 30GB } }
        Mock -CommandName Mount-VHD -MockWith { $script:steps.Add(('mount {0}' -f [bool]$ReadOnly)) }
        Mock -CommandName Optimize-VHD -MockWith { $script:steps.Add(('optimize {0}' -f $Mode)) }
        Mock -CommandName Dismount-VHD -MockWith { $script:steps.Add('dismount') }
        Mock -CommandName Write-DemoZeroFill -MockWith { $script:steps.Add('host fill'); [pscustomobject]@{ bytes = 50GB; seconds = 900; stopped = 'margin'; left = $false } }
        Mock -CommandName Remove-Item -MockWith { }
        Mock -CommandName Optimize-Volume -MockWith { $script:steps.Add('host trim') }
        Mock -CommandName Get-DemoWipeFreeSpace -MockWith { 60GB }
    }

    It 'compacts the guest''s disk mounted read-only, then zeroes and trims the host''s free space' {
        $outcome = Invoke-DemoHostCompact -Name 'arcsql01' -MarginBytes (4GB) -MaxSeconds 3600
        @($script:steps) | Should -Be @('mount True', 'optimize Full', 'dismount', 'host fill', 'host trim')
        $outcome.trim | Should -Be 'done'
        $outcome.disks[0].file | Should -Be 'arcsql01.vhdx'
        $outcome.guestState | Should -Be 'Off'
    }

    It 'refuses to compact while the guest runs' {
        $script:guestState = 'Running'
        { Invoke-DemoHostCompact -Name 'arcsql01' -MarginBytes (4GB) -MaxSeconds 3600 } | Should -Throw '*must be off*'
        $script:steps.Count | Should -Be 0
    }

    It 'dismounts the disk even when the compaction fails' {
        Mock -CommandName Optimize-VHD -MockWith { throw 'compaction failed' }
        { Invoke-DemoHostCompact -Name 'arcsql01' -MarginBytes (4GB) -MaxSeconds 3600 } | Should -Throw '*compaction failed*'
        $script:steps | Should -Contain 'dismount'
        $script:steps | Should -Not -Contain 'host fill'
    }
}
