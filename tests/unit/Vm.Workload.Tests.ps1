BeforeDiscovery {
    $onWindows = $IsWindows -and $null -ne (Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/DbHubDemo.Vm.psd1') -Force -WarningAction SilentlyContinue
    Add-Type -AssemblyName 'System.IO.Compression'
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

    function New-TestRoot {
        $root = Join-Path -Path $TestDrive -ChildPath ('vm-' + [guid]::NewGuid().ToString('N'))
        Initialize-DemoVmContext -Root $root -Role 'SqlVm' -BundleRoot $repoRoot | Out-Null
        return $root
    }

    function New-TestZipContent([hashtable] $Entries) {
        $memory = [System.IO.MemoryStream]::new()
        $archive = [System.IO.Compression.ZipArchive]::new($memory, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($name in ($Entries.Keys | Sort-Object)) {
                $stream = $archive.CreateEntry($name).Open()
                try {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Entries[$name])
                    $stream.Write($bytes, 0, $bytes.Length)
                }
                finally {
                    $stream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
        return $memory.ToArray()
    }

    function Get-HexHash([byte[]] $Bytes, [string] $Algorithm = 'SHA256') {
        $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
        try {
            return ([System.BitConverter]::ToString($hasher.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
        }
        finally {
            $hasher.Dispose()
        }
    }

    function Write-TestChunk([string] $Root, [byte[]] $Bytes, [int] $Size) {
        # What the chunk Run Commands from Send-DemoWorkloadRunner leave on the VM.
        $sha = Get-HexHash -Bytes $Bytes
        $folder = Join-Path -Path (Join-Path -Path $Root -ChildPath 'downloads') -ChildPath $sha.Substring(0, 12)
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $count = [int][System.Math]::Ceiling($Bytes.Length / [double]$Size)
        for ($i = 0; $i -lt $count; $i++) {
            $length = [System.Math]::Min($Size, $Bytes.Length - ($i * $Size))
            $chunk = [byte[]]::new($length)
            [System.Array]::Copy($Bytes, $i * $Size, $chunk, 0, $length)
            $name = 'chunk-{0:d3}' -f ($i + 1)
            [System.IO.File]::WriteAllBytes((Join-Path -Path $folder -ChildPath ($name + '.bin')), $chunk)
            [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath ($name + '.sha256')), (Get-HexHash -Bytes $chunk))
        }
        return [pscustomobject]@{ Sha256 = $sha; Count = $count; Folder = $folder }
    }

    # Stubs with the parameters the module uses, so Pester can mock these Windows cmdlets on Linux too.
    $stubs = @{
        'Get-ScheduledTask'   = 'param([string] $TaskName)'
        'Start-ScheduledTask' = 'param([string] $TaskName)'
        'Stop-ScheduledTask'  = 'param([string] $TaskName)'
        'Get-CimInstance'     = 'param([string] $ClassName, [string] $Filter)'
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            New-Item -Path ('function:global:' + $name) -Value ([scriptblock]::Create('[CmdletBinding()] ' + $stubs[$name])) | Out-Null
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'Workload settings' {
    It 'is Not selected without a runner, with baseline and 19:00 UTC by default' {
        $workload = Get-DemoVmWorkloadSetting -Settings ([ordered]@{ role = 'SqlVm' })
        $workload.Selected | Should -BeFalse
        $workload.ActivityProfile | Should -Be 'baseline'
        $workload.AutoShutdownTime | Should -Be '1900'
        $workload.AutoShutdownTimeZone | Should -Be 'UTC'
        $workload.T3 | Should -BeNullOrEmpty
        $workload.ProfileOnBoot | Should -BeFalse -Because 'a VM that starts must not keep T3 awake on its own (R183)'
    }

    It 'sets the profile at boot only when the template says so' {
        (Get-DemoVmWorkloadSetting -Settings @{ workload = @{ profileOnBoot = $true } }).ProfileOnBoot | Should -BeTrue
        (Get-DemoVmWorkloadSetting -Settings @{ workload = @{ profileOnBoot = $false } }).ProfileOnBoot | Should -BeFalse
        (Get-DemoVmWorkloadSetting -Settings @{ workload = @{ profileOnBoot = 'false' } }).ProfileOnBoot | Should -BeFalse
    }

    It 'reads the runner, the profile, the schedule, and T3''s names from settings.json' {
        $settings = [ordered]@{
            workload = [ordered]@{ runnerSha256 = ('AB' * 32); runnerChunkCount = 7; activityProfile = 'business-day'; autoShutdownTime = '1830'; autoShutdownTimeZone = 'Pacific Standard Time' }
            t3       = [ordered]@{ serverName = 'azuresql01-abc123'; serverFqdn = 'AzureSql01-abc123.database.windows.net'; databaseName = 'ContosoCare' }
        }
        $workload = Get-DemoVmWorkloadSetting -Settings $settings
        $workload.Selected | Should -BeTrue
        $workload.RunnerSha256 | Should -Be ('ab' * 32)
        $workload.RunnerChunkCount | Should -Be 7
        $workload.ActivityProfile | Should -Be 'business-day'
        $workload.AutoShutdownTime | Should -Be '1830'
        $workload.T3.ServerFqdn | Should -Be 'azuresql01-abc123.database.windows.net'
        $workload.T3.DatabaseName | Should -Be 'ContosoCare'
    }

    It 'is Not selected with a SHA-256 but no chunks' {
        (Get-DemoVmWorkloadSetting -Settings @{ workload = @{ runnerSha256 = ('ab' * 32) } }).Selected | Should -BeFalse
    }

    It 'reads T4''s names, with the runner''s role, and ignores a role that isn''t a plain PostgreSQL name' {
        $workload = Get-DemoVmWorkloadSetting -Settings ([ordered]@{ t4 = [ordered]@{ serverName = 'pgflex01-abc123'; serverFqdn = 'PGFLEX01-abc123.postgres.database.azure.com'; databaseName = 'contosocare'; runnerRole = 'contosocare_runner' } })
        $workload.T4.ServerFqdn | Should -Be 'pgflex01-abc123.postgres.database.azure.com'
        $workload.T4.DatabaseName | Should -Be 'contosocare'
        $workload.T4.RunnerRole | Should -Be 'contosocare_runner'
        (Get-DemoVmWorkloadSetting -Settings ([ordered]@{ t4 = [ordered]@{ serverFqdn = 'pgflex01-abc123.postgres.database.azure.com'; runnerRole = 'x; DROP' } })).T4.RunnerRole | Should -Be 'contosocare_runner'
        (Get-DemoVmWorkloadSetting -Settings ([ordered]@{ role = 'SqlVm' })).T4 | Should -BeNullOrEmpty
    }

    It 'refuses an invalid activity profile or shutdown time' {
        { Get-DemoVmWorkloadSetting -Settings @{ workload = @{ activityProfile = 'everything' } } } | Should -Throw '*invalid activity profile*'
        { Get-DemoVmWorkloadSetting -Settings @{ workload = @{ autoShutdownTime = '25:00' } } } | Should -Throw '*auto-shutdown time*'
    }
}

Describe 'Next auto-shutdown' {
    It 'is later today when the time hasn''t passed, in the schedule''s time zone' {
        $next = Get-DemoVmNextShutdown -Time '1900' -TimeZoneId 'Pacific Standard Time' -NowUtc ([datetime]::new(2026, 10, 20, 12, 0, 0, [System.DateTimeKind]::Utc))
        $next.Iso | Should -Be '2026-10-20T19:00:00-07:00'
        $next.MinutesLeft | Should -Be 840
    }

    It 'is tomorrow once the time has passed' {
        $next = Get-DemoVmNextShutdown -Time '1900' -TimeZoneId 'Pacific Standard Time' -NowUtc ([datetime]::new(2026, 10, 21, 3, 0, 0, [System.DateTimeKind]::Utc))
        $next.Iso | Should -Be '2026-10-21T19:00:00-07:00'
    }

    It 'moves a time that doesn''t exist on the spring-forward day one hour later' {
        $next = Get-DemoVmNextShutdown -Time '0230' -TimeZoneId 'Pacific Standard Time' -NowUtc ([datetime]::new(2027, 3, 14, 8, 0, 0, [System.DateTimeKind]::Utc))
        $next.Iso | Should -Be '2027-03-14T03:30:00-07:00'
    }

    It 'reads an unknown time zone as UTC' {
        $next = Get-DemoVmNextShutdown -Time '1900' -TimeZoneId 'Nowhere Standard Time' -NowUtc ([datetime]::new(2026, 10, 20, 12, 0, 0, [System.DateTimeKind]::Utc))
        $next.Iso | Should -Be '2026-10-20T19:00:00+00:00'
    }
}

Describe 'Process arguments' {
    It 'quotes arguments with spaces, quotes, and trailing backslashes the way Windows parses them' {
        ConvertTo-DemoVmProcessArgument -Argument 'plain' | Should -Be 'plain'
        ConvertTo-DemoVmProcessArgument -Argument '' | Should -Be '""'
        ConvertTo-DemoVmProcessArgument -Argument 'C:\Program Files\x\' | Should -Be '"C:\Program Files\x\\"'
        ConvertTo-DemoVmProcessArgument -Argument 'a"b' | Should -Be '"a\"b"'
        ConvertTo-DemoVmProcessArgument -Argument 'NT AUTHORITY\SYSTEM' | Should -Be '"NT AUTHORITY\SYSTEM"'
    }
}

Describe 'The runner package from its chunks' {
    BeforeEach {
        $root = New-TestRoot
        # Random content doesn't compress, so the zip spans several 1 KiB chunks.
        $zipBytes = New-TestZipContent @{ 'ContosoCare.Workload.dll' = 'runner'; 'runner-manifest.json' = '{}'; 'Azure.Core.dll' = [System.Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(4000)) }
    }

    It 'assembles and verifies the chunks, keeps the zip, and removes the chunk folder' {
        $chunks = Write-TestChunk -Root $root -Bytes $zipBytes -Size 1024
        $chunks.Count | Should -BeGreaterThan 1
        Test-DemoVmRunnerChunk -Root $root -Sha256 $chunks.Sha256 -ChunkCount $chunks.Count | Should -BeTrue

        $zip = Get-DemoVmRunnerZip -Root $root -Sha256 $chunks.Sha256 -ChunkCount $chunks.Count
        $zip | Should -Be (Get-DemoVmWorkloadPath -Root $root -RunnerSha256 $chunks.Sha256).RunnerZip
        Get-HexHash -Bytes ([System.IO.File]::ReadAllBytes($zip)) | Should -Be $chunks.Sha256
        Test-Path -LiteralPath $chunks.Folder | Should -BeFalse
        # A second run reuses the verified zip.
        Get-DemoVmRunnerZip -Root $root -Sha256 $chunks.Sha256 -ChunkCount $chunks.Count | Should -Be $zip
    }

    It 'names missing and bad chunks and installs nothing' {
        $chunks = Write-TestChunk -Root $root -Bytes $zipBytes -Size 1024
        Remove-Item -LiteralPath (Join-Path -Path $chunks.Folder -ChildPath 'chunk-002.bin')
        [System.IO.File]::WriteAllText((Join-Path -Path $chunks.Folder -ChildPath 'chunk-001.sha256'), ('0' * 64))
        Test-DemoVmRunnerChunk -Root $root -Sha256 $chunks.Sha256 -ChunkCount $chunks.Count | Should -BeFalse
        { Get-DemoVmRunnerZip -Root $root -Sha256 $chunks.Sha256 -ChunkCount $chunks.Count } | Should -Throw '*missing chunk(s) 2*chunk(s) 1 failed their SHA-256 check*'
        Test-Path -LiteralPath (Get-DemoVmWorkloadPath -Root $root -RunnerSha256 $chunks.Sha256).RunnerZip | Should -BeFalse
    }

    It 'fails closed when the joined file doesn''t match: the joined file and the chunks are deleted' {
        $chunks = Write-TestChunk -Root $root -Bytes $zipBytes -Size 1024
        $other = ('cd' * 32)
        $otherFolder = Join-Path -Path (Join-Path -Path $root -ChildPath 'downloads') -ChildPath $other.Substring(0, 12)
        Rename-Item -LiteralPath $chunks.Folder -NewName $other.Substring(0, 12)
        { Get-DemoVmRunnerZip -Root $root -Sha256 $other -ChunkCount $chunks.Count } | Should -Throw '*SHA-256 mismatch*nothing was installed*'
        Test-Path -LiteralPath $otherFolder | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'downloads') -Filter '*.partial').Count | Should -Be 0
    }

    It 'extracts the verified zip with a marker that Test-DemoVmRunnerPackage reads' {
        $chunks = Write-TestChunk -Root $root -Bytes $zipBytes -Size 4096
        $zip = Get-DemoVmRunnerZip -Root $root -Sha256 $chunks.Sha256 -ChunkCount $chunks.Count
        $paths = Get-DemoVmWorkloadPath -Root $root -RunnerSha256 $chunks.Sha256
        Expand-DemoVmVerifiedZip -ZipPath $zip -Destination $paths.Runner -ExpectedSha256 $chunks.Sha256
        Test-Path -LiteralPath $paths.RunnerDll | Should -BeTrue
        Test-DemoVmRunnerPackage -Root $root -Sha256 $chunks.Sha256 | Should -BeTrue
        $marker = Read-DemoVmJsonFile -Path $paths.RunnerMarker
        $marker['algorithm'] | Should -Be 'SHA256'
        $marker['hash'] | Should -Be $chunks.Sha256
        Test-Path -LiteralPath ($paths.Runner + '.staging') | Should -BeFalse
    }

    It 'deletes a zip that fails its pinned SHA-256 or SHA-512 and installs nothing' {
        $zip = Join-Path -Path $root -ChildPath 'tampered.zip'
        [System.IO.File]::WriteAllBytes($zip, $zipBytes)
        $destination = Join-Path -Path $root -ChildPath 'never'
        { Expand-DemoVmVerifiedZip -ZipPath $zip -Destination $destination -ExpectedSha256 ('0' * 64) } | Should -Throw '*SHA-256 mismatch*fail closed*'
        Test-Path -LiteralPath $zip | Should -BeFalse
        [System.IO.File]::WriteAllBytes($zip, $zipBytes)
        { Expand-DemoVmVerifiedZip -ZipPath $zip -Destination $destination -ExpectedSha512 ('0' * 128) } | Should -Throw '*SHA-512 mismatch*'
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It 'extracts in place, never renames a folder, and replaces a partial install and a leftover staging folder' {
        # Live finding: Defender held the freshly extracted runtime, so renaming the staging folder failed.
        Mock -CommandName Move-Item -ModuleName 'DbHubDemo.Vm' -MockWith { throw 'Move-Item must not be used.' }
        $nested = New-TestZipContent @{ 'dotnet.exe' = 'host'; 'shared/Microsoft.NETCore.App/10.0.13/System.Runtime.dll' = 'runtime' }
        $zip = Join-Path -Path $root -ChildPath 'runtime.zip'
        [System.IO.File]::WriteAllBytes($zip, $nested)
        $destination = Join-Path -Path $root -ChildPath 'dotnet'
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $destination -ChildPath 'stale.dll') -Value 'old'
        New-Item -ItemType Directory -Path ($destination + '.staging') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path ($destination + '.staging') -ChildPath 'dotnet.exe') -Value 'left over'

        Expand-DemoVmVerifiedZip -ZipPath $zip -Destination $destination -ExpectedSha512 (Get-HexHash -Bytes $nested -Algorithm 'SHA512') -MarkerName '.runtime.json' -MarkerData @{ version = '10.0.13' }
        Get-Content -LiteralPath (Join-Path -Path $destination -ChildPath 'dotnet.exe') -Raw | Should -Be 'host'
        Test-Path -LiteralPath ([System.IO.Path]::Combine($destination, 'shared', 'Microsoft.NETCore.App', '10.0.13', 'System.Runtime.dll')) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $destination -ChildPath 'stale.dll') | Should -BeFalse
        Test-Path -LiteralPath ($destination + '.staging') | Should -BeFalse
        (Read-DemoVmJsonFile -Path (Join-Path -Path $destination -ChildPath '.runtime.json'))['version'] | Should -Be '10.0.13'
        Should -Invoke -CommandName Move-Item -ModuleName 'DbHubDemo.Vm' -Times 0 -Exactly
    }

    It 'removes the marker first, so an extraction that fails part-way doesn''t count as installed' {
        $destination = Join-Path -Path $root -ChildPath 'runner-x'
        $good = New-TestZipContent @{ 'a.dll' = 'a' }
        $zip = Join-Path -Path $root -ChildPath 'good.zip'
        [System.IO.File]::WriteAllBytes($zip, $good)
        Expand-DemoVmVerifiedZip -ZipPath $zip -Destination $destination -ExpectedSha256 (Get-HexHash -Bytes $good)
        Test-Path -LiteralPath (Join-Path -Path $destination -ChildPath '.complete') | Should -BeTrue

        $evil = New-TestZipContent @{ '../outside.txt' = 'escape'; 'b.dll' = 'b' }
        [System.IO.File]::WriteAllBytes($zip, $evil)
        { Expand-DemoVmVerifiedZip -ZipPath $zip -Destination $destination -ExpectedSha256 (Get-HexHash -Bytes $evil) } | Should -Throw '*would be extracted outside*'
        Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 'outside.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $destination -ChildPath '.complete') | Should -BeFalse
    }

    It 'keeps the current runner and the newest previous one' {
        $runnerRoot = Join-Path -Path $root -ChildPath 'runner'
        foreach ($name in 'aaaaaaaaaaaa', 'bbbbbbbbbbbb', 'cccccccccccc') {
            New-Item -ItemType Directory -Path (Join-Path -Path $runnerRoot -ChildPath $name) -Force | Out-Null
            Start-Sleep -Milliseconds 20
        }
        Remove-DemoVmOldRunner -Root $root -KeepSha256 ('cc' * 32) -Confirm:$false
        (Get-ChildItem -LiteralPath $runnerRoot -Directory).Name | Sort-Object | Should -Be @('bbbbbbbbbbbb', 'cccccccccccc')
    }
}

Describe 'File operations that another process holds' {
    BeforeAll {
        $null = New-TestRoot
    }

    It 'retries an IOException or an access-denied error until it succeeds' {
        $script:calls = 0
        $result = Invoke-DemoVmFileRetry -DelaySeconds 0 -MaxAttempts 5 -ScriptBlock {
            param($Value)
            $script:calls++
            if ($script:calls -eq 1) { throw [System.IO.IOException]::new('The process cannot access the file.') }
            if ($script:calls -eq 2) { throw [System.UnauthorizedAccessException]::new('Access to the path is denied.') }
            'done ' + $Value
        } -ArgumentList 'x'
        $result | Should -Be 'done x'
        $script:calls | Should -Be 3
    }

    It 'retries an IOException that a .NET method call wraps' {
        $script:calls = 0
        Invoke-DemoVmFileRetry -DelaySeconds 0 -ScriptBlock {
            $script:calls++
            if ($script:calls -lt 3) { [System.IO.File]::OpenRead((Join-Path -Path $TestDrive -ChildPath 'no-such-folder/missing.bin')) }
        }
        $script:calls | Should -Be 3
    }

    It 'throws other errors at once, and the last failure after the limit' {
        $script:calls = 0
        { Invoke-DemoVmFileRetry -DelaySeconds 0 -ScriptBlock { $script:calls++; throw 'not a file problem' } } | Should -Throw '*not a file problem*'
        $script:calls | Should -Be 1
        $script:calls = 0
        { Invoke-DemoVmFileRetry -DelaySeconds 0 -MaxAttempts 3 -ScriptBlock { $script:calls++; throw [System.IO.IOException]::new('still held') } } | Should -Throw '*still held*'
        $script:calls | Should -Be 3
    }
}

Describe 'The .NET runtime' {
    BeforeEach {
        $root = New-TestRoot
        $runtimeBytes = New-TestZipContent @{ 'dotnet.exe' = 'host'; 'shared/Microsoft.NETCore.App/10.0.13/System.Private.CoreLib.dll' = 'corelib' }
        $pin = @{ version = '10.0.13'; fileName = 'dotnet-runtime-10.0.13-win-x64.zip'; url = 'https://builds.dotnet.microsoft.com/dotnet/Runtime/10.0.13/dotnet-runtime-10.0.13-win-x64.zip'; sha512 = (Get-HexHash -Bytes $runtimeBytes -Algorithm 'SHA512') }
        $script:downloads = 0
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmWebDownload -MockWith {
            $script:downloads++
            [System.IO.File]::WriteAllBytes($Path, $script:servedBytes)
            [pscustomobject]@{ StatusCode = 200; Resumed = $false }
        }
        Mock -ModuleName DbHubDemo.Vm -CommandName Stop-DemoVmWorkload -MockWith { }
    }

    It 'downloads the pinned zip, checks its SHA-512, and extracts it with a marker' {
        $script:servedBytes = $runtimeBytes
        $zip = Install-DemoVmDotNetRuntime -Root $root -Pin $pin
        $paths = Get-DemoVmWorkloadPath -Root $root
        Test-Path -LiteralPath $zip | Should -BeTrue
        Test-Path -LiteralPath $paths.DotNetExe | Should -BeTrue
        Test-DemoVmDotNetRuntime -Root $root -Pin $pin | Should -BeTrue
        (Read-DemoVmJsonFile -Path $paths.DotNetMarker)['version'] | Should -Be '10.0.13'
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Stop-DemoVmWorkload -Times 1 -Exactly

        # Installed and cached: nothing is downloaded or stopped again.
        Install-DemoVmDotNetRuntime -Root $root -Pin $pin | Out-Null
        $script:downloads | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Stop-DemoVmWorkload -Times 1 -Exactly
    }

    It 'fails closed when the download doesn''t match the SHA-512, and installs nothing' {
        $script:servedBytes = [System.Text.Encoding]::UTF8.GetBytes('not the runtime')
        Mock -ModuleName DbHubDemo.Vm -CommandName Start-Sleep -MockWith { }
        { Install-DemoVmDotNetRuntime -Root $root -Pin $pin } | Should -Throw '*SHA-512 mismatch*fail closed*'
        Test-Path -LiteralPath (Get-DemoVmWorkloadPath -Root $root).DotNetExe | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path (Join-Path -Path $root -ChildPath 'downloads') -ChildPath $pin.fileName) | Should -BeFalse
    }

    It 'reads the pin from the bundle manifest, and refuses a manifest without one' {
        $bundle = Join-Path -Path $TestDrive -ChildPath ('bundle-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bundle | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $bundle -ChildPath 'bundle-manifest.json') -Value (@{ schemaVersion = 1; media = @{} } | ConvertTo-Json)
        { Get-DemoVmDotNetPin -BundleRoot $bundle } | Should -Throw '*no dotnetRuntime pin*'
        Set-Content -LiteralPath (Join-Path -Path $bundle -ChildPath 'bundle-manifest.json') -Value (@{ schemaVersion = 1; dotnetRuntime = $pin } | ConvertTo-Json)
        (Get-DemoVmDotNetPin -BundleRoot $bundle)['sha512'] | Should -Be $pin.sha512
    }
}

Describe 'Runner results' {
    It 'maps exit codes and records to the ADR 0012 statuses' {
        $pass = [pscustomobject]@{ ExitCode = 0; StdOut = '[{"checkId":"WORKLOAD.T1.SETUP.A","status":"Pass","message":"ok"}]'; StdErr = '' }
        (Get-DemoVmRunnerOutcome -Run $pass -Label 'setup').Status | Should -Be 'Pass'
        $warn = [pscustomobject]@{ ExitCode = 0; StdOut = 'log line [{"checkId":"X","status":"Warning","message":"slow"}]'; StdErr = '' }
        $outcome = Get-DemoVmRunnerOutcome -Run $warn -Label 'setup'
        $outcome.Status | Should -Be 'Warning'
        $outcome.Message | Should -Match 'slow'
        (Get-DemoVmRunnerOutcome -Run ([pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = '' }) -Label 'reset').Status | Should -Be 'Manual action required'
        $fail = Get-DemoVmRunnerOutcome -Run ([pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'SQL error 18456: Login failed' }) -Label 'setup'
        $fail.Status | Should -Be 'Fail'
        $fail.Message | Should -Match '18456'
    }

    It 'runs setup with --server for T3 and --grant-windows-login when asked' {
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRunnerProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' } }
        Invoke-DemoVmRunnerSetup -DotNetExe 'dotnet.exe' -RunnerDll 'runner.dll' -Target 'T3' -Server 'azuresql01-abc123.database.windows.net' | Out-Null
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'setup --target T3 --json --server azuresql01-abc123.database.windows.net'
        }
        Invoke-DemoVmRunnerSetup -DotNetExe 'dotnet.exe' -RunnerDll 'runner.dll' -Target 'T2' -GrantWindowsLogin 'NT AUTHORITY\SYSTEM' | Out-Null
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join '|') -eq 'setup|--target|T2|--json|--grant-windows-login|NT AUTHORITY\SYSTEM'
        }
    }

    It 'sets a profile until the next auto-shutdown, but gives off no end time' {
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRunnerProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' } }
        Set-DemoVmActivityProfile -DotNetExe 'dotnet.exe' -RunnerDll 'runner.dll' -Target 'T1' -Name 'baseline' -NotAfter '2026-10-20T19:00:00-07:00' -Confirm:$false | Out-Null
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains '--not-after' -and $ArgumentList -contains '2026-10-20T19:00:00-07:00' -and $ArgumentList -contains 'baseline'
        }
        Set-DemoVmActivityProfile -DotNetExe 'dotnet.exe' -RunnerDll 'runner.dll' -Target 'T3' -Server 's.database.windows.net' -Name 'off' -NotAfter 'x' -Confirm:$false | Out-Null
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -notcontains '--not-after' -and $ArgumentList -contains 'off' -and $ArgumentList -contains '--server'
        }
        { Set-DemoVmActivityProfile -DotNetExe 'd' -RunnerDll 'r' -Target 'T1' -Name 'party' -NotAfter 'x' -Confirm:$false } | Should -Throw
    }
}

Describe 'Workload records and the task' {
    BeforeAll {
        $pin = @{ version = '10.0.13'; sha512 = ('ef' * 64) }
        $workload = Get-DemoVmWorkloadSetting -Settings @{
            workload = @{ runnerSha256 = ('ab' * 32); runnerChunkCount = 7; activityProfile = 'baseline'; autoShutdownTime = '1900'; autoShutdownTimeZone = 'UTC' }
            t3       = @{ serverName = 'azuresql01-abc123'; serverFqdn = 'azuresql01-abc123.database.windows.net' }
        }
    }

    It 'matches only the same runner, runtime, profile, schedule, T3 server, and a passing setup' {
        $root = New-TestRoot
        $expected = New-DemoVmWorkloadRecord -Root $root -Workload $workload -PrimaryTarget 'T1' -DotNetPin $pin
        $expected.t3.serverFqdn | Should -Be 'azuresql01-abc123.database.windows.net'
        $record = New-DemoVmWorkloadRecord -Root $root -Workload $workload -PrimaryTarget 'T1' -DotNetPin $pin
        Test-DemoVmWorkloadRecord -Record $record -Expected $expected | Should -BeFalse -Because 'setup has not run'
        $record.setup['T1'] = @{ status = 'Pass' }
        Test-DemoVmWorkloadRecord -Record $record -Expected $expected | Should -BeTrue
        $record.activityProfile = 'off'
        Test-DemoVmWorkloadRecord -Record $record -Expected $expected | Should -BeFalse
        $record.activityProfile = 'baseline'
        $record.profileOnBoot = $true
        Test-DemoVmWorkloadRecord -Record $record -Expected $expected | Should -BeFalse -Because 'the boot behavior changed'
        $record.Remove('profileOnBoot')
        Test-DemoVmWorkloadRecord -Record $record -Expected $expected | Should -BeTrue -Because 'a record from before the setting means false'
        $record.setup['T1'] = @{ status = 'Fail' }
        Test-DemoVmWorkloadRecord -Record $record -Expected $expected | Should -BeFalse
        Test-DemoVmWorkloadRecord -Record $null -Expected $expected | Should -BeFalse
    }

    It 'leaves T3 out of a T2 record' {
        $record = New-DemoVmWorkloadRecord -Root (New-TestRoot) -Workload $workload -PrimaryTarget 'T2' -DotNetPin $pin
        $record.t3 | Should -BeNullOrEmpty
        $record.primaryTarget | Should -Be 'T2'
    }

    It 'defines DbHubDemo-Workload as SYSTEM, two minutes after startup, running the stable wrapper, bounded to 13 hours' {
        $root = New-TestRoot
        $definition = Get-DemoVmWorkloadTaskDefinition -Root $root
        $definition.TaskName | Should -Be 'DbHubDemo-Workload'
        $definition.Execute | Should -Be 'powershell.exe'
        $definition.Argument | Should -Be ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Root "{1}"' -f (Get-DemoVmWorkloadPath -Root $root).Wrapper, $root)
        $definition.StartupDelay | Should -Be 'PT2M'
        $definition.UserId | Should -Be 'SYSTEM'
        $definition.ExecutionTimeLimit | Should -Be (New-TimeSpan -Hours 13)
        $definition.RestartCount | Should -Be 3
        # The wrapper lives next to the runner, not in a bundle folder that a later deployment deletes.
        $definition.Argument | Should -Not -Match 'bundle'
    }

    It 'stops only runner processes that use this state folder''s runtime' {
        $root = New-TestRoot
        $dotnet = (Get-DemoVmWorkloadPath -Root $root).DotNet
        Mock -ModuleName DbHubDemo.Vm -CommandName Get-ScheduledTask -MockWith { [pscustomobject]@{ TaskName = 'DbHubDemo-Workload' } }
        Mock -ModuleName DbHubDemo.Vm -CommandName Stop-ScheduledTask -MockWith { }
        Mock -ModuleName DbHubDemo.Vm -CommandName Get-CimInstance -MockWith {
            @([pscustomobject]@{ ProcessId = 11; ExecutablePath = (Join-Path -Path $dotnet -ChildPath 'dotnet.exe') }, [pscustomobject]@{ ProcessId = 22; ExecutablePath = 'C:\Program Files\dotnet\dotnet.exe' })
        }
        Mock -ModuleName DbHubDemo.Vm -CommandName Stop-Process -MockWith { }
        Stop-DemoVmWorkload -Root $root -Confirm:$false
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Stop-ScheduledTask -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 11 }
    }

    It 'builds another machine''s paths as strings, without resolving their drive (Linux CI, the host for the guest)' {
        # A drive letter that doesn't exist here stands in for the guest's C: on the host, or any C: on Linux.
        $letter = [char[]](90..68) | Where-Object { -not (Test-Path -LiteralPath ([string]$_ + ':\')) } | Select-Object -First 1
        $guestRoot = '{0}:\ProgramData\DbHubDemo' -f $letter
        $paths = Get-DemoVmWorkloadPath -Root $guestRoot -RunnerSha256 ('ab' * 32)
        $paths.RunnerZip | Should -Be ('{0}\downloads\runner-abababababab.zip' -f $guestRoot)
        $paths.DotNetExe | Should -Be ('{0}\dotnet\dotnet.exe' -f $guestRoot)
        $paths.Wrapper | Should -Be ('{0}\runner\Start-DemoWorkload.ps1' -f $guestRoot)
        $record = New-DemoVmWorkloadRecord -Root $guestRoot -Workload (Get-DemoVmWorkloadSetting -Settings @{ workload = @{ runnerSha256 = ('ab' * 32); runnerChunkCount = 7 } }) -PrimaryTarget 'T2' -DotNetPin @{ version = '10.0.13'; sha512 = ('ef' * 64) }
        $record.runnerDll | Should -Be ('{0}\runner\abababababab\ContosoCare.Workload.dll' -f $guestRoot)
        Join-DemoVmPath -Path 'C:\ProgramData\DbHubDemo\' -ChildPath 'logs' | Should -Be 'C:\ProgramData\DbHubDemo\logs'
        Join-DemoVmPath -Path $TestDrive -ChildPath 'logs' | Should -Be ([System.IO.Path]::Combine($TestDrive, 'logs')) -Because 'a local path keeps the local separator'
    }
}

Describe 'Verified downloads with SHA-512' {
    BeforeEach {
        $root = New-TestRoot
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmWebDownload -MockWith {
            [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::UTF8.GetBytes('runtime bytes'))
            [pscustomobject]@{ StatusCode = 200; Resumed = $false }
        }
        $sha512 = Get-HexHash -Bytes ([System.Text.Encoding]::UTF8.GetBytes('runtime bytes')) -Algorithm 'SHA512'
    }

    It 'keeps a download that matches its SHA-512 and caches the check' {
        $path = Join-Path -Path $root -ChildPath 'downloads/runtime.zip'
        $result = Save-DemoVmDownload -Uri 'https://example.invalid/runtime.zip' -Path $path -Name 'dotnetRuntime' -ExpectedSha512 $sha512.ToUpperInvariant()
        $result.Sha512 | Should -Be $sha512
        $result.TrustOnFirstUse | Should -BeFalse
        Test-DemoVmFileHash -Path $path -ExpectedSha512 $sha512 | Should -BeTrue
        Mock -ModuleName DbHubDemo.Vm -CommandName Get-DemoVmFileSha512 -MockWith { throw 'The cache should have answered.' }
        Test-DemoVmFileHash -Path $path -ExpectedSha512 $sha512 | Should -BeTrue
    }

    It 'never trusts a SHA-512 download on first use: a mismatch deletes it' {
        Mock -ModuleName DbHubDemo.Vm -CommandName Start-Sleep -MockWith { }
        $path = Join-Path -Path $root -ChildPath 'downloads/runtime.zip'
        { Save-DemoVmDownload -Uri 'https://example.invalid/runtime.zip' -Path $path -Name 'dotnetRuntime' -ExpectedSha512 ('0' * 128) } | Should -Throw '*SHA-512 mismatch*'
        Test-Path -LiteralPath $path | Should -BeFalse
        Test-Path -LiteralPath ($path + '.partial') | Should -BeFalse
    }
}

Describe 'Workload functions under Windows PowerShell 5.1' -Skip:(-not $onWindows) {
    BeforeAll {
        function Invoke-WindowsPowerShell([string] $Command) {
            $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $Command 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output) -join "`n") }
        }
        $modulePath = Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/DbHubDemo.Vm.psd1'
    }

    It 'assembles the runner from its chunks and extracts it, with SHA-256 and SHA-512 checks' {
        $root = Join-Path -Path $TestDrive -ChildPath 'ps51'
        $zipBytes = New-TestZipContent @{ 'ContosoCare.Workload.dll' = 'runner'; 'big.bin' = ('y' * 5000) }
        $chunks = Write-TestChunk -Root $root -Bytes $zipBytes -Size 2048
        $sha512 = Get-HexHash -Bytes $zipBytes -Algorithm 'SHA512'
        $command = "`$ErrorActionPreference = 'Stop'; Import-Module '{0}' -Force -WarningAction SilentlyContinue; Initialize-DemoVmContext -Root '{1}' -Role SqlVm | Out-Null; `$zip = Get-DemoVmRunnerZip -Root '{1}' -Sha256 '{2}' -ChunkCount {3}; `$p = Get-DemoVmWorkloadPath -Root '{1}' -RunnerSha256 '{2}'; Copy-Item `$zip ('{1}\copy.zip'); Expand-DemoVmVerifiedZip -ZipPath `$zip -Destination `$p.Runner -ExpectedSha256 '{2}'; Expand-DemoVmVerifiedZip -ZipPath ('{1}\copy.zip') -Destination ('{1}\other') -ExpectedSha512 '{4}'; 'OK ' + (Test-DemoVmRunnerPackage -Root '{1}' -Sha256 '{2}') + ' ' + (Test-Path ('{1}\other\big.bin')); 'PS ' + `$PSVersionTable.PSVersion.Major" -f $modulePath, $root, $chunks.Sha256, $chunks.Count, $sha512
        $run = Invoke-WindowsPowerShell -Command $command
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'PS 5'
        $run.Output | Should -Match 'OK True True'
    }

    It 'runs a program that writes to stderr under Stop and returns its exit code and both streams' {
        $command = "`$ErrorActionPreference = 'Stop'; Import-Module '{0}' -Force -WarningAction SilentlyContinue; `$r = Invoke-DemoVmRunnerProcess -DotNetExe 'cmd.exe' -RunnerDll '/d' -ArgumentList @('/c', 'echo out & echo diagnostic 1>&2 & exit /b 3') -TimeoutSeconds 60; 'EXIT ' + `$r.ExitCode; 'OUT ' + `$r.StdOut.Trim(); 'ERR ' + `$r.StdErr.Trim()" -f $modulePath
        $run = Invoke-WindowsPowerShell -Command $command
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'EXIT 3'
        $run.Output | Should -Match 'OUT out'
        $run.Output | Should -Match 'ERR diagnostic'
    }

    It 'computes the next auto-shutdown the same way in the module and in Start-DemoWorkload.ps1' {
        $wrapper = Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Start-DemoWorkload.ps1'
        $command = "`$ErrorActionPreference = 'Stop'; Import-Module '{0}' -Force -WarningAction SilentlyContinue; . '{1}' -Root '{2}'; `$now = [datetime]::new(2026, 10, 20, 12, 0, 0, [DateTimeKind]::Utc); 'MODULE ' + (Get-DemoVmNextShutdown -Time '1900' -TimeZoneId 'Pacific Standard Time' -NowUtc `$now).Iso; 'WRAPPER ' + (Get-DemoWorkloadNextShutdown -Time '1900' -TimeZoneId 'Pacific Standard Time' -Now `$now).ToString(""yyyy-MM-dd'T'HH:mm:sszzz"")" -f $modulePath, $wrapper, (Join-Path -Path $TestDrive -ChildPath 'wrapper51')
        $run = Invoke-WindowsPowerShell -Command $command
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'MODULE 2026-10-20T19:00:00-07:00'
        $run.Output | Should -Match 'WRAPPER 2026-10-20T19:00:00-07:00'
    }
}
