BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the host bootstrap's functions, GuestJumpstart.ps1's included, without running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1')

    # Hyper-V's cmdlets exist only on a Hyper-V host; elsewhere these stand-ins let Pester mock them.
    $stubs = @{
        'Get-VM'                   = 'param([string] $Name)'
        'Start-VM'                 = 'param([string] $Name)'
        'Get-VMNetworkAdapter'     = 'param([string] $VMName)'
        'Connect-VMNetworkAdapter' = 'param([object] $VMNetworkAdapter, [string] $SwitchName)'
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            New-Item -Path ('function:global:' + $name) -Value ([scriptblock]::Create('[CmdletBinding()] ' + $stubs[$name])) | Out-Null
        }
    }

    function New-TestJumpstartContext {
        param([string] $Mode = 'JumpstartImage', [string] $DataDiskTier = 'None')
        $root = Join-Path -Path $TestDrive -ChildPath ('host-' + [guid]::NewGuid().ToString('N'))
        Initialize-DemoVmContext -Root $root -Role 'ArcHost' -BundleRoot $repoRoot | Out-Null
        $settings = [ordered]@{
            role             = 'ArcHost'
            t2SqlInstallMode = $Mode
            dataDiskTier     = $DataDiskTier
            seedScale        = 1
            guest            = [ordered]@{ name = 'arcsql01'; vcpus = 2; memoryGiB = 8; vhdxGB = 64 }
        }
        Get-DemoHostContext -StateRoot $root -BundleRoot $repoRoot -Settings $settings
    }

    function Get-TestMd5([byte[]] $Bytes) {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        try { [System.Convert]::ToBase64String($md5.ComputeHash($Bytes)) } finally { $md5.Dispose() }
    }

    function Get-TestSha256([byte[]] $Bytes) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    }

    function New-TestPin([long] $Size, [string] $Etag = '0xPINNED', [string] $Sha256 = $null) {
        [ordered]@{
            url          = 'https://jumpstart.example.invalid/arcbox/prod/ArcBox-SQL-STD.vhdx'
            fileName     = 'ArcBox-SQL-STD.vhdx'
            sizeBytes    = $Size
            sha256       = $Sha256
            etag         = $Etag
            lastModified = '2025-08-02T23:25:34Z'
            expected     = [ordered]@{ sqlEdition = 'Standard'; sqlMajorVersion = 16; instanceName = 'MSSQLSERVER'; computerName = 'ARCBOX-SQL'; sampleDatabases = @('AdventureWorksLT2022'); jumpstartFolder = 'C:\Jumpstart' }
        }
    }

    # The test image: random bytes made at run time.
    $script:imageBytes = New-Object -TypeName 'byte[]' -ArgumentList (3MB + 12345)
    [System.Random]::new(4242).NextBytes($script:imageBytes)
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'JumpstartImage step plan' {
    It 'downloads the image, makes the guest at its first boot, checks it, and onboards Arc; the build steps are Not selected' {
        $context = New-TestJumpstartContext
        $plan = Get-DemoHostStepPlan -Context $context
        $plan.Name | Should -Be @(
            'NestedVirtualization', 'HyperVRole', 'DnsServerRole', 'NatNetwork', 'DnsForwarder', 'GuestSource', 'DataDisk', 'GuestOsMedia',
            'GuestVhdx', 'GuestImage', 'GuestVm', 'GuestFirstBoot', 'GuestOnline', 'GuestHardening', 'SqlMedia', 'GuestWebView2',
            'SqlUnattendedInstall', 'JumpstartImageCheck', 'ArcOnboarding', 'ArcOnboardingBeforeWizard', 'GuidedSetup', 'SqlSetupWizard',
            'GuestSignInCleanup', 'ConfigureSql', 'SeedDatabase', 'WorkloadRunner')
        $selected = @($plan | Where-Object { -not $_.Contains('When') -or [bool](@(& $_['When'] $_)[-1]) } | ForEach-Object { $_.Name })
        $selected | Should -Contain 'GuestImage'
        $selected | Should -Contain 'GuestFirstBoot'
        $selected | Should -Contain 'JumpstartImageCheck'
        $selected | Should -Contain 'ArcOnboarding'
        foreach ($name in 'GuestOsMedia', 'GuestVhdx', 'SqlMedia', 'GuestWebView2', 'SqlUnattendedInstall', 'ArcOnboardingBeforeWizard', 'GuidedSetup', 'SqlSetupWizard') {
            $selected | Should -Not -Contain $name
        }
    }

    It 'creates the guest with its network adapter not connected only in JumpstartImage mode' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1') -Raw
        $text | Should -Match "-Disconnected:\(\`$c\.Mode -eq 'JumpstartImage'\)"
        $text | Should -Match "'GuestJumpstart\.ps1'"
    }

    It 'runs to Ready with the image steps, onboarding after the checks' {
        $context = New-TestJumpstartContext -DataDiskTier 'E10'
        Mock -CommandName Test-DemoNestedVirtualization -MockWith { $true }
        Mock -CommandName Test-DemoHostFeature -MockWith { $true }
        Mock -CommandName Test-DemoHostNatNetwork -MockWith { $true }
        Mock -CommandName Test-DemoHostDnsForwarder -MockWith { $true }
        Mock -CommandName Get-DemoHostGuestSourceState -MockWith { [pscustomobject]@{ Ok = $true; Expected = 'JumpstartImage'; Recorded = ''; RecordedMode = '' } }
        Mock -CommandName Get-DemoVmDataVolume -MockWith { [pscustomobject]@{ DriveLetter = 'F'; FileSystemLabel = 'DbHubData' } }
        $script:imagePlaced = $false
        Mock -CommandName Test-DemoJumpstartImage -MockWith { $script:imagePlaced }
        Mock -CommandName Save-DemoJumpstartImage -MockWith { $script:imagePlaced = $true }
        Mock -CommandName Test-DemoGuestVm -MockWith { $true }
        $script:firstBoot = $false
        Mock -CommandName Test-DemoJumpstartFirstBoot -MockWith { $script:firstBoot }
        Mock -CommandName Invoke-DemoJumpstartFirstBoot -MockWith { $script:firstBoot = $true }
        Mock -CommandName Test-DemoHostGuestReachable -MockWith { $true }
        Mock -CommandName Wait-DemoHostGuest -MockWith { $true }
        Mock -CommandName Get-DemoGuestCredential -MockWith {
            $secure = [System.Security.SecureString]::new()
            foreach ($character in ('t' + [guid]::NewGuid().ToString('N')).ToCharArray()) { $secure.AppendChar($character) }
            [System.Management.Automation.PSCredential]::new('Administrator', $secure)
        }
        Mock -CommandName Test-DemoGuestHardening -MockWith { $true }
        $script:checked = $false
        Mock -CommandName Test-DemoJumpstartGuest -MockWith { $script:checked }
        Mock -CommandName Invoke-DemoJumpstartImageCheck -MockWith { $script:checked = $true }
        $script:arcConnected = $false
        Mock -CommandName Test-DemoArcOnboarded -MockWith { $script:arcConnected }
        Mock -CommandName Test-DemoHostGuestSignInClean -MockWith { $true }
        Mock -CommandName Test-DemoHostDatabase -MockWith { $true }
        Mock -CommandName Save-DemoHostMedia -MockWith { throw 'JumpstartImage mode downloads no ISO.' }
        Mock -CommandName Build-DemoHostGuestDisk -MockWith { throw 'JumpstartImage mode builds no VHDX.' }
        Mock -CommandName Install-DemoHostGuestSql -MockWith { throw 'JumpstartImage mode installs no SQL Server.' }
        $plan = Get-DemoHostStepPlan -Context $context

        Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'WaitingForArcOnboarding'
        Should -Invoke -CommandName Save-DemoJumpstartImage -Times 1 -Exactly
        Should -Invoke -CommandName Invoke-DemoJumpstartFirstBoot -Times 1 -Exactly
        Should -Invoke -CommandName Invoke-DemoJumpstartImageCheck -Times 1 -Exactly
        $state = Get-DemoVmState
        foreach ($name in 'GuestOsMedia', 'GuestVhdx', 'SqlMedia', 'SqlUnattendedInstall', 'GuestWebView2') {
            $state['steps'][$name]['status'] | Should -Be 'NotSelected'
        }
        $state['steps']['ArcOnboarding']['status'] | Should -Be 'Waiting'

        $script:arcConnected = $true
        Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'Ready'
        (Get-DemoVmState)['steps']['GuidedSetup']['status'] | Should -Be 'NotSelected'
    }
}

Describe 'The guest''s source' {
    It 'decides from the record, or from an existing guest without one' -ForEach @(
        @{ Mode = 'JumpstartImage'; Record = $null; Exists = $false; Ok = $true; Recorded = '' }
        @{ Mode = 'JumpstartImage'; Record = $null; Exists = $true; Ok = $false; Recorded = 'Build' }
        @{ Mode = 'PaygWizard'; Record = $null; Exists = $true; Ok = $true; Recorded = 'Build' }
        @{ Mode = 'JumpstartImage'; Record = @{ source = 'JumpstartImage'; installMode = 'JumpstartImage' }; Exists = $true; Ok = $true; Recorded = 'JumpstartImage' }
        @{ Mode = 'Developer'; Record = @{ source = 'JumpstartImage'; installMode = 'JumpstartImage' }; Exists = $true; Ok = $false; Recorded = 'JumpstartImage' }
        @{ Mode = 'ProductKey'; Record = @{ source = 'Build'; installMode = 'PaygWizard' }; Exists = $true; Ok = $true; Recorded = 'Build' }
    ) {
        $decision = Get-DemoHostGuestSourceDecision -Mode $Mode -Record $Record -GuestExists $Exists
        $decision.Ok | Should -Be $Ok
        $decision.Recorded | Should -Be $Recorded
    }

    It 'stops the GuestSource step with the fix, and changes nothing, when the mode doesn''t match the guest' {
        $context = New-TestJumpstartContext
        Mock -CommandName Get-DemoHostGuestSourceState -MockWith { [pscustomobject]@{ Ok = $false; Expected = 'JumpstartImage'; Recorded = 'Build'; RecordedMode = 'PaygWizard' } }
        $result = Get-DemoHostGuestSourceFailure -Context $context
        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'PaygWizard'
        $result.Message | Should -Match 'destroy\.ps1, then \./scripts/deploy\.ps1'
    }

    It 'records the source when the guest is made' {
        $context = New-TestJumpstartContext
        Set-DemoHostGuestSource -Context $context -Source 'JumpstartImage' -Confirm:$false
        $record = Read-DemoVmJsonFile -Path (Get-DemoHostGuestSourcePath -Context $context)
        $record['source'] | Should -Be 'JumpstartImage'
        $record['installMode'] | Should -Be 'JumpstartImage'
    }
}

Describe 'Disk space without a data disk' {
    BeforeEach {
        $script:osDrive = Join-Path -Path $TestDrive -ChildPath ('os-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:osDrive -Force | Out-Null
        Mock -CommandName Get-DemoHostSystemDrive -MockWith { $script:osDrive }
        Mock -CommandName Get-DemoVmMediaPin -MockWith { New-TestPin -Size 36645634048 }
    }

    It 'needs the image, a growth allowance, and the margin, not the image''s 100 GiB maximum (user decision, 2026-11-05)' {
        $need = Get-DemoHostOsDiskRequirement -Context (New-TestJumpstartContext)
        $need.ImageBytes | Should -Be 36645634048
        $need.GrowthBytes | Should -Be (20 * 1GB)
        $need.MediaBytes | Should -Be 0
        $need.TotalBytes | Should -Be (36645634048 + 20GB + 10GB)
    }

    It 'fits the lowest-cost host''s 128 GiB OS disk with about 100 GB free' {
        $context = New-TestJumpstartContext
        Mock -CommandName Get-DemoHostDriveFreeSpace -MockWith { 100GB }
        Initialize-DemoHostStorage -Context $context | Should -BeNullOrEmpty
        Test-DemoHostStorage -Context $context | Should -BeTrue
    }

    It 'names the image and its growth allowance when the space isn''t there' {
        $context = New-TestJumpstartContext
        Mock -CommandName Get-DemoHostDriveFreeSpace -MockWith { 50GB }
        $result = Initialize-DemoHostStorage -Context $context
        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'the Jumpstart image 34\.1 GB, 20 GB for it to grow, and a 10 GB margin'
    }

    It 'reports the free space and warns below the threshold' {
        $context = New-TestJumpstartContext
        Mock -CommandName Get-DemoHostDriveFreeSpace -MockWith { 12GB }
        $detail = Get-DemoHostStorageDetail -Context $context
        $detail.freeGiB | Should -Be 12
        $detail.warnBelowGiB | Should -Be 20
        $detail.low | Should -BeTrue
    }
}

Describe 'The image download' {
    BeforeAll {
        # A stand-in for an HTTPS response stream: each Read returns at most MaxRead bytes, however large the buffer.
        Add-Type -TypeDefinition @'
namespace DbHubDemoTest
{
    public sealed class TrickleStream : System.IO.Stream
    {
        private readonly System.IO.Stream inner;
        private readonly int maxRead;

        public TrickleStream(System.IO.Stream inner, int maxRead)
        {
            this.inner = inner;
            this.maxRead = maxRead;
        }

        public int Reads { get; private set; }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new System.NotSupportedException(); } }
        public override long Position { get { throw new System.NotSupportedException(); } set { throw new System.NotSupportedException(); } }
        public override void Flush() { }
        public override long Seek(long offset, System.IO.SeekOrigin origin) { throw new System.NotSupportedException(); }
        public override void SetLength(long value) { throw new System.NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new System.NotSupportedException(); }

        public override int Read(byte[] buffer, int offset, int count)
        {
            this.Reads++;
            return this.inner.Read(buffer, offset, System.Math.Min(count, this.maxRead));
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                this.inner.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
'@
    }

    BeforeEach {
        $script:context = New-TestJumpstartContext
        $script:vhdx = Join-Path -Path $TestDrive -ChildPath ('vms-' + [guid]::NewGuid().ToString('N') + '/arcsql01/arcsql01.vhdx')
        $script:remote = [pscustomobject]@{ ContentLength = [long]$script:imageBytes.Length; ETag = '0xPINNED'; ContentMd5 = (Get-TestMd5 $script:imageBytes); LastModified = 'Sat, 02 Aug 2025 23:25:34 GMT' }
        Mock -CommandName Get-VM -MockWith { }
        Mock -CommandName Get-DemoJumpstartPin -MockWith { New-TestPin -Size $script:imageBytes.Length -Sha256 (Get-TestSha256 $script:imageBytes) }
        Mock -CommandName Get-DemoJumpstartRemoteFact -MockWith { $script:remote }
        Mock -CommandName Open-DemoJumpstartDownload -MockWith {
            $rest = New-Object -TypeName 'byte[]' -ArgumentList ($script:imageBytes.Length - $Offset)
            [Array]::Copy($script:imageBytes, $Offset, $rest, 0, $rest.Length)
            [pscustomobject]@{ Stream = [System.IO.MemoryStream]::new($rest); StatusCode = $(if ($Offset -gt 0) { 206 } else { 200 }); ContentRange = $(if ($Offset -gt 0) { 'bytes {0}-{1}/{2}' -f $Offset, ($script:imageBytes.Length - 1), $script:imageBytes.Length } else { '' }); Response = $null }
        }
    }

    It 'verifies the tested image while it streams, puts it in place, and records it' {
        $result = Save-DemoJumpstartImage -Context $script:context -VhdxPath $script:vhdx
        $result | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllBytes($script:vhdx).Length | Should -Be $script:imageBytes.Length
        Test-Path -LiteralPath ($script:vhdx + '.partial') | Should -BeFalse
        $record = Read-DemoVmJsonFile -Path (Get-DemoJumpstartPath -Context $script:context).Image
        $record['pinned'] | Should -BeTrue
        $record['md5Verified'] | Should -BeTrue
        $record['sha256'] | Should -Be (Get-TestSha256 $script:imageBytes)
        (Read-DemoVmJsonFile -Path (Get-DemoHostGuestSourcePath -Context $script:context))['source'] | Should -Be 'JumpstartImage'
        Mock -CommandName Get-DemoJumpstartPin -MockWith { New-TestPin -Size $script:imageBytes.Length }
        Test-DemoJumpstartImage -Context $script:context -VhdxPath $script:vhdx | Should -BeTrue
    }

    It 'resumes a partial download of the same etag and hashes the whole file' {
        New-Item -ItemType Directory -Path (Split-Path -Path $script:vhdx -Parent) -Force | Out-Null
        $first = New-Object -TypeName 'byte[]' -ArgumentList 1MB
        [Array]::Copy($script:imageBytes, 0, $first, 0, $first.Length)
        [System.IO.File]::WriteAllBytes($script:vhdx + '.partial', $first)
        Write-DemoVmJsonFile -Path ($script:vhdx + '.partial.json') -InputObject ([ordered]@{ url = 'x'; etag = '0xPINNED' })
        Save-DemoJumpstartImage -Context $script:context -VhdxPath $script:vhdx | Should -BeNullOrEmpty
        Should -Invoke -CommandName Open-DemoJumpstartDownload -Times 1 -Exactly -ParameterFilter { $Offset -eq 1MB -and $Length -eq $script:imageBytes.Length }
        (Get-TestSha256 ([System.IO.File]::ReadAllBytes($script:vhdx))) | Should -Be (Get-TestSha256 $script:imageBytes)
    }

    It 'writes and hashes every chunk when the network returns a few KiB per read (<PartialBytes> bytes on disk)' -ForEach @(
        @{ PartialBytes = 0 }
        @{ PartialBytes = [int](2.5 * 1MB) }
    ) {
        # A 1 MiB buffer: the resume reads the bytes on disk in several blocks, and each network read fills a sliver of it.
        $script:context.Host.JumpstartImage.BufferMB = 1
        $script:network = $null
        Mock -CommandName Open-DemoJumpstartDownload -MockWith {
            $rest = New-Object -TypeName 'byte[]' -ArgumentList ($script:imageBytes.Length - $Offset)
            [Array]::Copy($script:imageBytes, $Offset, $rest, 0, $rest.Length)
            $script:network = [DbHubDemoTest.TrickleStream]::new([System.IO.MemoryStream]::new($rest), 16KB - 7)
            [pscustomobject]@{ Stream = $script:network; StatusCode = $(if ($Offset -gt 0) { 206 } else { 200 }); ContentRange = $(if ($Offset -gt 0) { 'bytes {0}-{1}/{2}' -f $Offset, ($script:imageBytes.Length - 1), $script:imageBytes.Length } else { '' }); Response = $null }
        }
        if ($PartialBytes -gt 0) {
            New-Item -ItemType Directory -Path (Split-Path -Path $script:vhdx -Parent) -Force | Out-Null
            $first = New-Object -TypeName 'byte[]' -ArgumentList $PartialBytes
            [Array]::Copy($script:imageBytes, 0, $first, 0, $first.Length)
            [System.IO.File]::WriteAllBytes($script:vhdx + '.partial', $first)
            Write-DemoVmJsonFile -Path ($script:vhdx + '.partial.json') -InputObject ([ordered]@{ url = 'x'; etag = '0xPINNED' })
        }

        Save-DemoJumpstartImage -Context $script:context -VhdxPath $script:vhdx | Should -BeNullOrEmpty
        Should -Invoke -CommandName Open-DemoJumpstartDownload -Times 1 -Exactly -ParameterFilter { $Offset -eq $PartialBytes -and $Length -eq $script:imageBytes.Length }
        $script:network.Reads | Should -BeGreaterThan ([math]::Floor(($script:imageBytes.Length - $PartialBytes) / 16KB))
        (Get-TestSha256 ([System.IO.File]::ReadAllBytes($script:vhdx))) | Should -Be (Get-TestSha256 $script:imageBytes)
        $record = Read-DemoVmJsonFile -Path (Get-DemoJumpstartPath -Context $script:context).Image
        $record['md5Verified'] | Should -BeTrue
        $record['sha256'] | Should -Be (Get-TestSha256 $script:imageBytes)
    }

    It 'calls only .NET methods in its copy loops, never a PowerShell command per chunk (live finding, 2026-11-06)' {
        # Windows PowerShell 5.1 checks a mandatory array parameter by walking every element, so a function called per
        # network read with the 4 MiB buffer held the 34 GiB download to 0.2 MB/s.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path -Path $repoRoot -ChildPath 'vm/hyperv-guest/GuestJumpstart.ps1'), [ref]$null, [ref]$null)
        $loops = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.LoopStatementAst] -and $node.Condition.Extent.Text -match '\.Read\(\$buffer\b' }, $true))
        $loops.Count | Should -Be 2
        foreach ($loop in $loops) {
            @($loop.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.Extent.Text }) | Should -BeNullOrEmpty
        }
        $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Add-DemoJumpstartHashBlock' }, $true) | Should -BeNullOrEmpty
    }

    It 'starts over with a warning when the server ignores the range and sends the whole image' {
        New-Item -ItemType Directory -Path (Split-Path -Path $script:vhdx -Parent) -Force | Out-Null
        $first = New-Object -TypeName 'byte[]' -ArgumentList 1MB
        [Array]::Copy($script:imageBytes, 0, $first, 0, $first.Length)
        [System.IO.File]::WriteAllBytes($script:vhdx + '.partial', $first)
        Write-DemoVmJsonFile -Path ($script:vhdx + '.partial.json') -InputObject ([ordered]@{ url = 'x'; etag = '0xPINNED' })
        Mock -CommandName Open-DemoJumpstartDownload -MockWith {
            [pscustomobject]@{ Stream = [System.IO.MemoryStream]::new($script:imageBytes, $false); StatusCode = 200; ContentRange = ''; Response = $null }
        }
        Mock -CommandName Write-DemoVmLog

        Save-DemoJumpstartImage -Context $script:context -VhdxPath $script:vhdx | Should -BeNullOrEmpty
        Should -Invoke -CommandName Write-DemoVmLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'ignored the range request' -and $Message -match 'HTTP 200' -and $Message -match 'starts over' }
        (Get-TestSha256 ([System.IO.File]::ReadAllBytes($script:vhdx))) | Should -Be (Get-TestSha256 $script:imageBytes)
        $record = Read-DemoVmJsonFile -Path (Get-DemoJumpstartPath -Context $script:context).Image
        $record['md5Verified'] | Should -BeTrue
        $record['sha256'] | Should -Be (Get-TestSha256 $script:imageBytes)
    }

    It 'accepts a newer image with a warning that names it (user decision, 2026-11-05)' {
        $script:remote.ETag = '0xNEWER'
        $result = Save-DemoJumpstartImage -Context $script:context -VhdxPath $script:vhdx
        $result.Outcome | Should -Be 'Done'
        ($result.WarningMessage -join ' ') | Should -Match '0xNEWER'
        ($result.WarningMessage -join ' ') | Should -Match 'image checks'
        (Read-DemoVmJsonFile -Path (Get-DemoJumpstartPath -Context $script:context).Image)['pinned'] | Should -BeFalse
    }

    It 'fails closed and deletes the download when it doesn''t match the image''s own Content-MD5' {
        $script:remote.ContentMd5 = Get-TestMd5 ([byte[]](1, 2, 3))
        { Save-DemoJumpstartImage -Context $script:context -VhdxPath $script:vhdx } | Should -Throw '*Content-MD5*fail closed*'
        Test-Path -LiteralPath ($script:vhdx + '.partial') | Should -BeFalse
        Test-Path -LiteralPath $script:vhdx | Should -BeFalse
    }

    It 'fails closed when the tested image doesn''t match its pinned SHA-256' {
        Mock -CommandName Get-DemoJumpstartPin -MockWith { New-TestPin -Size $script:imageBytes.Length -Sha256 ('0' * 64) }
        { Save-DemoJumpstartImage -Context $script:context -VhdxPath $script:vhdx } | Should -Throw '*pinned SHA-256*'
        Test-Path -LiteralPath $script:vhdx | Should -BeFalse
    }

    It 'never replaces the disk of a guest that exists' {
        Mock -CommandName Get-VM -MockWith { [pscustomobject]@{ Name = 'arcsql01'; State = 'Running' } }
        $result = Save-DemoJumpstartImage -Context $script:context -VhdxPath $script:vhdx
        $result.Outcome | Should -Be 'Failed'
        Should -Invoke -CommandName Open-DemoJumpstartDownload -Times 0
    }

    It 'decides a short download is incomplete, so the next run resumes it' {
        $decision = Get-DemoJumpstartImageDecision -Pin (New-TestPin -Size 100) -Remote ([pscustomobject]@{ ContentLength = 100; ETag = '0xPINNED'; ContentMd5 = ''; LastModified = '' }) -Length 60 -Hash ([pscustomobject]@{ Md5Base64 = ''; Sha256 = '' })
        $decision.Outcome | Should -Be 'Incomplete'
    }
}

Describe 'The image request (live finding, 2026-11-06)' {
    It 'asks for a closed range when it resumes, the form Blob storage takes without x-ms-version' {
        # An anonymous request without x-ms-version is served at Blob storage's earliest version, which answered the open-ended
        # bytes=N- with 200 and the whole image, so every resume started over.
        $uri = 'https://jumpstart.example.invalid/arcbox/prod/ArcBox-SQL-STD.vhdx'
        $request = New-DemoJumpstartDownloadRequest -Uri $uri -Offset 1000000 -Length 36645634048
        $request.Method | Should -Be 'GET'
        $request.Headers['Range'] | Should -Be 'bytes=1000000-36645634047'
        $request.Headers['x-ms-version'] | Should -BeNullOrEmpty
        (New-DemoJumpstartDownloadRequest -Uri $uri -Length 36645634048).Headers['Range'] | Should -BeNullOrEmpty
    }

    It 'sends the request for the rest of the image of the length it was given' {
        $script:fakeRequest = [pscustomobject]@{}
        $script:fakeRequest | Add-Member -MemberType ScriptMethod -Name 'GetResponse' -Value { throw 'not sent in a test' }
        Mock -CommandName New-DemoJumpstartDownloadRequest -MockWith { $script:fakeRequest }
        { Open-DemoJumpstartDownload -Uri 'https://jumpstart.example.invalid/x.vhdx' -Offset 5 -Length 10 } | Should -Throw '*not sent in a test*'
        Should -Invoke -CommandName New-DemoJumpstartDownloadRequest -Times 1 -Exactly -ParameterFilter { $Offset -eq 5 -and $Length -eq 10 }
    }
}

Describe 'The published credential' {
    BeforeAll {
        $script:versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $script:realSource = $script:versions.media.jumpstartArcBoxSqlStd.credentialSource
    }

    BeforeEach {
        # A stand-in for Jumpstart's script, made at run time so no password text is in the repository.
        $script:fakeValue = 'P' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '!'
        $script:script = "`$vmDir = 'x'`n`$nestedWindowsUsername = 'Administrator'`n`$nestedWindowsPassword = '$($script:fakeValue)'`n`$other = 1`n"
        $script:scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($script:script)
        $script:pin = [ordered]@{ credentialSource = [ordered]@{ url = 'https://raw.example.invalid/commit/ArcServersLogonScript.ps1'; sha256 = (Get-TestSha256 $script:scriptBytes); userNamePattern = $script:realSource.userNamePattern; passwordPattern = $script:realSource.passwordPattern } }
        Mock -CommandName Get-DemoJumpstartTextDownload -MockWith { , $script:scriptBytes }
    }

    It 'reads it from the pinned script with the configured patterns, and redacts it from then on' {
        $credential = Get-DemoJumpstartDefaultCredential -Pin $script:pin
        $credential.UserName | Should -Be 'Administrator'
        $credential.GetNetworkCredential().Password | Should -Be $script:fakeValue
        Protect-DemoVmText -Text ('value {0} here' -f $script:fakeValue) | Should -Not -Match ([regex]::Escape($script:fakeValue))
    }

    It 'fails closed when the script doesn''t match its pinned SHA-256' {
        $script:pin.credentialSource.sha256 = '0' * 64
        { Get-DemoJumpstartDefaultCredential -Pin $script:pin } | Should -Throw '*SHA-256*nothing was used*'
    }

    It 'takes exactly one match for each value' {
        Get-DemoJumpstartPatternValue -Text "`$nestedWindowsUsername = 'Administrator'" -Pattern $script:realSource.userNamePattern -Label 'user name' | Should -Be 'Administrator'
        { Get-DemoJumpstartPatternValue -Text 'nothing here' -Pattern $script:realSource.passwordPattern -Label 'password' } | Should -Throw '*0 match*'
        { Get-DemoJumpstartPatternValue -Text ("`$nestedWindowsUsername = 'a'`n`$nestedWindowsUsername = 'b'") -Pattern $script:realSource.userNamePattern -Label 'user name' } | Should -Throw '*2 match*'
    }

    It 'keeps no credential value in config/versions.json, only where to read it and its SHA-256' {
        $script:realSource.Keys | Sort-Object | Should -Be @('description', 'passwordPattern', 'sha256', 'url', 'userNamePattern')
        $script:realSource.url | Should -Match '^https://raw\.githubusercontent\.com/microsoft/azure_arc/[0-9a-f]{40}/'
        $script:realSource.sha256 | Should -Match '^[0-9a-f]{64}$'
    }
}

Describe 'The image checks' {
    BeforeAll {
        $script:expected = (New-TestPin -Size 1)['expected']
        function New-TestFact {
            param([hashtable] $Override = @{})
            $fact = [ordered]@{
                computerName = 'ARCSQL01'; osCaption = 'Microsoft Windows Server 2022 Standard'; osBuild = '20348'; licenseDescription = 'Windows(R) Operating System, VOLUME_KMSCLIENT channel'; licenseStatus = 5
                sqlServiceExists = $true; sqlRunning = $true; sqlEdition = 'Standard Edition (64-bit)'; sqlVersion = '16.0.1140.6'; sqlServerName = 'ARCSQL01'; sqlIsSysAdmin = $true
                sqlEnabledLogins = @(); sampleDatabases = @(); jumpstartFolder = $false; sqlError = ''
            }
            foreach ($key in $Override.Keys) { $fact[$key] = $Override[$key] }
            [pscustomobject]$fact
        }
    }

    It 'passes SQL Server 2022 Standard on the default instance, named after the guest' {
        @(Get-DemoJumpstartCheckProblem -Fact (New-TestFact) -GuestName 'arcsql01' -Expected $script:expected).Count | Should -Be 0
    }

    It 'stops T2 for what Database Hub can''t use: <Case>' -ForEach @(
        @{ Case = 'Developer edition'; Override = @{ sqlEdition = 'Developer Edition (64-bit)' }; Code = 'Edition' }
        @{ Case = 'another major version'; Override = @{ sqlVersion = '17.0.900.4' }; Code = 'Version' }
        @{ Case = 'no default instance'; Override = @{ sqlServiceExists = $false }; Code = 'NoDefaultInstance' }
        @{ Case = 'no sysadmin'; Override = @{ sqlIsSysAdmin = $false }; Code = 'SysAdmin' }
    ) {
        $problems = @(Get-DemoJumpstartCheckProblem -Fact (New-TestFact -Override $Override) -GuestName 'arcsql01' -Expected $script:expected)
        @($problems | Where-Object { $_.Code -eq $Code -and $_.Fatal }).Count | Should -Be 1
    }

    It 'leaves first-boot work to a re-run: <Case>' -ForEach @(
        @{ Case = 'the server name'; Override = @{ sqlServerName = 'ARCBOX-SQL-STD' }; Code = 'ServerName' }
        @{ Case = 'an enabled SQL login'; Override = @{ sqlEnabledLogins = @('sa') }; Code = 'SqlLogin' }
        @{ Case = 'the sample database'; Override = @{ sampleDatabases = @('AdventureWorksLT2022') }; Code = 'SampleDatabase' }
        @{ Case = 'the Jumpstart folder'; Override = @{ jumpstartFolder = $true }; Code = 'JumpstartFolder' }
        @{ Case = 'the computer name'; Override = @{ computerName = 'ARCBOX-SQL' }; Code = 'ComputerName' }
    ) {
        $problems = @(Get-DemoJumpstartCheckProblem -Fact (New-TestFact -Override $Override) -GuestName 'arcsql01' -Expected $script:expected)
        @($problems | Where-Object { $_.Code -eq $Code -and -not $_.Fatal }).Count | Should -Be 1
    }

    It 'stops with the cause and the commands, and switches nothing by itself (user decision, 2026-11-05)' {
        $context = New-TestJumpstartContext
        Mock -CommandName Get-DemoJumpstartPin -MockWith { New-TestPin -Size 1 }
        Mock -CommandName Get-DemoJumpstartGuestFact -MockWith { New-TestFact -Override @{ sqlEdition = 'Developer Edition (64-bit)' } }
        Mock -CommandName Invoke-DemoJumpstartFirstBoot -MockWith { throw 'A fatal problem doesn''t run the first boot again.' }
        $result = Invoke-DemoJumpstartImageCheck -Context $context
        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Nothing switches by itself'
        $result.Message | Should -Match 'PaygWizard, ProductKey, or Developer'
    }
}

Describe 'The evaluation guard' {
    It 'decides: <Case>' -ForEach @(
        @{ Case = 'not an evaluation (the Jumpstart guest)'; License = [pscustomobject]@{ isEvaluation = $false; description = 'VOLUME_KMSCLIENT channel'; daysLeft = $null; rearmCount = 1000 }; Active = $false; Action = 'None' }
        @{ Case = 'plenty of days left'; License = [pscustomobject]@{ isEvaluation = $true; description = 'TIMEBASED_EVAL channel'; daysLeft = 120; rearmCount = 5 }; Active = $false; Action = 'None' }
        @{ Case = 'due, idle, a rearm left'; License = [pscustomobject]@{ isEvaluation = $true; description = 'TIMEBASED_EVAL channel'; daysLeft = 20; rearmCount = 5 }; Active = $false; Action = 'Rearm' }
        @{ Case = 'due while a profile runs'; License = [pscustomobject]@{ isEvaluation = $true; description = 'TIMEBASED_EVAL channel'; daysLeft = 20; rearmCount = 5 }; Active = $true; Action = 'None' }
        @{ Case = 'due with no rearm left'; License = [pscustomobject]@{ isEvaluation = $true; description = 'TIMEBASED_EVAL channel'; daysLeft = 5; rearmCount = 0 }; Active = $false; Action = 'Warn' }
        @{ Case = 'unreadable'; License = $null; Active = $false; Action = 'None' }
    ) {
        (Get-DemoGuestRearmDecision -License $License -RearmDays 30 -ProfileActive $Active).Action | Should -Be $Action
    }

    It 'runs at most once per interval, from the host''s pass when it''s Ready' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1') -Raw
        $text | Should -Match "if \(\`$outcome -eq 'Ready'\) \{\s+#[^\n]*\n\s+Invoke-DemoHostEvaluationGuard -Context \`$context"
        $context = New-TestJumpstartContext
        Write-DemoVmJsonFile -Path (Join-Path -Path $context.Root -ChildPath 'guest-evaluation.json') -InputObject ([ordered]@{ checkedUtc = (Get-DemoVmUtcNow) })
        Mock -CommandName Test-DemoHostGuestReachable -MockWith { throw 'Checked too soon.' }
        Invoke-DemoHostEvaluationGuard -Context $context
        Should -Invoke -CommandName Test-DemoHostGuestReachable -Times 0
    }
}

Describe 'The image pin' {
    It 'is in config/versions.json media, with the image''s identity and the facts the checks expect' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $pin = $versions.media.jumpstartArcBoxSqlStd
        $pin.url | Should -Be 'https://jumpstartprodsg.blob.core.windows.net/arcbox/prod/ArcBox-SQL-STD.vhdx'
        $pin.sizeBytes | Should -BeGreaterThan 30GB
        $pin.etag | Should -Match '^0x[0-9A-F]+$'
        $pin.contentMd5 | Should -Match '^[A-Za-z0-9+/]{22}==$'
        $pin.expected.sqlEdition | Should -Be 'Standard'
        $pin.expected.sqlMajorVersion | Should -Be 16
        $pin.expected.instanceName | Should -Be 'MSSQLSERVER'
        (Import-PowerShellDataFile -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/dsc/host.psd1')).Media.JumpstartImage | Should -Be 'jumpstartArcBoxSqlStd'
    }
}
