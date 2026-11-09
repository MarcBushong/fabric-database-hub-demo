BeforeAll {
    # The .NET SDK check (2026-11-09 live finding: a runtime-only dotnet first on PATH failed the Artifacts step 15
    # minutes into a run). Every dotnet call is mocked, except one real child process that stands in for dotnet; the
    # repository is a stand-in in TestDrive with its own global.json, so the pinned version can change without these tests.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    $script:exe = if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' }
    # The dotnet host's own words for a runtime-only install, as it printed them live (exit code 0x8000809B).
    $script:hostError = "The command could not be loaded, possibly because:`n  * You intended to execute a .NET application:`n      The application '--version' does not exist or is not a managed .dll or .exe.`n  * You intended to execute a .NET SDK command:`n      A compatible .NET SDK was not found.`n`nRequested SDK version: 10.0.403`n`nInstalled SDKs:`nNo .NET SDKs were found."

    function New-TestRepository([string] $GlobalJson = '{"sdk":{"version":"10.0.403","rollForward":"latestFeature","allowPrerelease":false}}') {
        $root = Join-Path -Path $TestDrive -ChildPath ('repo-' + [guid]::NewGuid().ToString('N'))
        $generator = Join-Path -Path $root -ChildPath 'workload-generator'
        $null = New-Item -ItemType Directory -Path $generator -Force
        if ($GlobalJson) {
            Set-Content -LiteralPath (Join-Path -Path $generator -ChildPath 'global.json') -Value $GlobalJson -Encoding utf8NoBOM
        }
        return $root
    }

    # A folder with a dotnet executable in it (an empty file: only its presence is checked; every run is mocked).
    function New-TestDotNetFolder([string] $Name) {
        $folder = Join-Path -Path $TestDrive -ChildPath ('{0}-{1}' -f $Name, [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $folder -Force
        $null = New-Item -ItemType File -Path (Join-Path -Path $folder -ChildPath $script:exe) -Force
        return $folder
    }

    function Get-TestStatus([string] $Root) {
        InModuleScope DbHubDemo -Parameters @{ Root = $Root } { Get-DemoDotNetSdkStatus -RepositoryRoot $Root }
    }

    function Get-TestResult([string] $Root) {
        InModuleScope DbHubDemo -Parameters @{ Root = $Root } { Test-DemoDotNetSdk -RepositoryRoot $Root }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Test-DemoDotNetSdk: the .NET SDK that builds the workload runner, checked before anything is created (PREFLIGHT.TOOLS.DOTNETSDK, 2026-11-09)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:root = New-TestRepository
        $script:primary = Join-Path -Path (New-TestDotNetFolder -Name 'system') -ChildPath $script:exe
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetPath -MockWith { $script:primary }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetCandidateFolder -MockWith { @() }
        # Where deploy.ps1 installs no SDK itself: the manual fix (its own install has its tests below).
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetSdkPin -MockWith { $null }
        # What each dotnet answers: Version (its --version in workload-generator; '' when no SDK there passes) and Sdks
        # (its --list-sdks).
        $script:answers = @{}
        $script:answers[$script:primary] = @{ Version = ''; Sdks = @() }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -MockWith {
            $answer = $script:answers[$DotNetPath]
            if ($ArgumentList[0] -eq '--list-sdks') {
                $lines = @($answer.Sdks | ForEach-Object { '{0} [{1}]' -f $_, (Join-Path -Path (Split-Path -Path $DotNetPath -Parent) -ChildPath 'sdk') })
                return [pscustomobject]@{ ExitCode = 0; StdOut = ($lines -join "`n"); StdErr = '' }
            }
            if ($answer.Version) {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $answer.Version; StdErr = '' }
            }
            [pscustomobject]@{ ExitCode = -2147450725; StdOut = ''; StdErr = $script:hostError }
        }
    }

    It 'is Pass with the SDK version, from the dotnet first on PATH, read in workload-generator, where global.json applies' {
        # The first run of an SDK can print a banner before its version.
        $script:answers[$script:primary] = @{ Version = "Welcome to .NET 10.0!`n---------------------`n10.0.403"; Sdks = @('10.0.403') }
        $result = Get-TestResult -Root $script:root
        $result.checkId | Should -Be 'PREFLIGHT.TOOLS.DOTNETSDK'
        $result.area | Should -Be 'preflight'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match ([regex]::Escape('The .NET SDK 10.0.403 builds the workload runner: {0}' -f $script:primary))
        $result.message | Should -Match ([regex]::Escape('10.0.403 or any later 10.0 SDK (rollForward latestFeature)'))
        $result.evidence['sdkVersion'] | Should -Be '10.0.403'
        $result.evidence['dotnetPath'] | Should -Be $script:primary
        $result.evidence['requiredVersion'] | Should -Be '10.0.403'
        $result.evidence['rollForward'] | Should -Be 'latestFeature'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -Times 1 -Exactly -ParameterFilter {
            $DotNetPath -eq $script:primary -and ($ArgumentList -join ' ') -eq '--version' -and $WorkingDirectory -eq (Join-Path -Path $script:root -ChildPath 'workload-generator')
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -Times 1 -Exactly -Because 'a Pass needs one call, no list, and no other folder'
    }

    It 'is a Fail that names the dotnet that ran, its SDKs, what global.json needs, and the exact fix: <Case>' -ForEach @(
        @{ Case = 'a runtime-only install, as Windows apps and Visual Studio leave (the live finding)'; Sdks = @(); Has = 'has no .NET SDK, only runtimes' }
        @{ Case = 'the 10.0.402 SDK the docs pinned until 2026-11-09, which latestFeature can''t roll back to'; Sdks = @('10.0.402'); Has = 'has only the .NET SDK 10.0.402' }
        @{ Case = 'two SDKs, neither accepted'; Sdks = @('8.0.415', '10.0.402'); Has = 'has only the .NET SDKs 8.0.415, 10.0.402' }
    ) {
        $script:answers[$script:primary] = @{ Version = ''; Sdks = $Sdks }
        $result = Get-TestResult -Root $script:root
        $result.status | Should -Be 'Fail'
        $result.message | Should -BeExactly ('The dotnet first on PATH, {0}, {1}, and workload-generator/global.json needs 10.0.403 or any later 10.0 SDK (rollForward latestFeature), so the workload runner can''t be built.' -f $script:primary, $Has)
        if ($IsWindows) {
            $result.remediation | Should -Match '^Install the \.NET SDK 10\.0\.403 or later: winget install Microsoft\.DotNet\.SDK\.10 '
            $result.remediation | Should -Match ([regex]::Escape('https://dotnet.microsoft.com/download/dotnet/10.0'))
            $result.docUrl | Should -Be 'https://learn.microsoft.com/dotnet/core/install/windows'
        }
        else {
            $result.remediation | Should -Match '^Install the \.NET SDK 10\.0\.403 or later from https://dotnet\.microsoft\.com/download/dotnet/10\.0 '
            $result.remediation | Should -Match 'dev container'
        }
        $result.remediation | Should -Match ([regex]::Escape('then open a new terminal and run ./scripts/deploy.ps1 again'))
        $result.remediation | Should -Match ([regex]::Escape('./scripts/deploy.ps1 -SkipRunner'))
        @($result.evidence['installedSdks']) | Should -Be @($Sdks)
        $result.evidence['exitCode'] | Should -Be -2147450725
        @($result.evidence['alternatives']).Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq '--list-sdks' }
    }

    It 'is a Fail without any dotnet on PATH, and runs nothing' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetPath -MockWith { '' }
        $result = Get-TestResult -Root $script:root
        $result.status | Should -Be 'Fail'
        $result.message | Should -BeExactly 'No dotnet is on PATH, and workload-generator/global.json needs the .NET SDK 10.0.403 or any later 10.0 SDK (rollForward latestFeature), so the workload runner can''t be built.'
        $result.remediation | Should -Match '^Install the \.NET SDK 10\.0\.403 or later'
        $result.evidence['dotnetPath'] | Should -BeExactly ''
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -Times 0 -Exactly
    }

    It 'says when another well-known folder has an SDK global.json accepts, but isn''t first on PATH, and how to put it first' {
        $user = New-TestDotNetFolder -Name 'user'
        $empty = New-TestDotNetFolder -Name 'old'
        $missing = Join-Path -Path $TestDrive -ChildPath 'no-dotnet-here'
        $userExe = Join-Path -Path $user -ChildPath $script:exe
        $script:answers[$userExe] = @{ Version = '10.0.403'; Sdks = @('10.0.403') }
        $script:answers[(Join-Path -Path $empty -ChildPath $script:exe)] = @{ Version = ''; Sdks = @('10.0.402') }
        $script:candidates = @(
            [pscustomobject]@{ Name = 'DOTNET_ROOT'; Folder = (Split-Path -Path $script:primary -Parent) }
            [pscustomobject]@{ Name = '%ProgramFiles%\dotnet'; Folder = $empty }
            [pscustomobject]@{ Name = '~/.dotnet'; Folder = $missing }
            [pscustomobject]@{ Name = '%LOCALAPPDATA%\Microsoft\dotnet'; Folder = $user }
        )
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetCandidateFolder -MockWith { $script:candidates }
        $result = Get-TestResult -Root $script:root
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match ([regex]::Escape(' {0} has the .NET SDK 10.0.403, which it accepts, but isn''t first on PATH.' -f $user))
        $expected = 'Put {0} first on PATH: in this terminal, $env:PATH = ''{0}{1}'' + $env:PATH, then run ./scripts/deploy.ps1 again; to keep it, move {0} before {2} in your PATH settings. Or ' -f $user, [System.IO.Path]::PathSeparator, (Split-Path -Path $script:primary -Parent)
        $result.remediation | Should -Match ('^' + [regex]::Escape($expected))
        @($result.evidence['alternatives']).Count | Should -Be 1
        $result.evidence['alternatives'][0]['folder'] | Should -Be $user
        $result.evidence['alternatives'][0]['sdkVersion'] | Should -Be '10.0.403'
        # The dotnet that ran first isn't asked again, and a folder without one isn't run at all.
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -Times 1 -Exactly -ParameterFilter { $DotNetPath -eq $script:primary -and $ArgumentList[0] -eq '--version' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -Times 1 -Exactly -ParameterFilter { $DotNetPath -eq (Join-Path -Path $empty -ChildPath $script:exe) }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -Times 0 -Exactly -ParameterFilter { $DotNetPath -like ('{0}*' -f $missing) }
    }

    It 'says to put the installers'' folder first on Windows when the dotnet first on PATH is elsewhere' -Skip:(-not $IsWindows) {
        $result = Get-TestResult -Root $script:root
        $expected = ' The installer and winget put it in {0}, so make that folder come before {1} on PATH.' -f (Join-Path -Path $env:ProgramFiles -ChildPath 'dotnet'), (Split-Path -Path $script:primary -Parent)
        $result.remediation | Should -Match ([regex]::Escape($expected))
    }

    It 'is a Fail that says how to restore global.json when it can''t be read, and runs nothing' {
        $result = Get-TestResult -Root (New-TestRepository -GlobalJson '')
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match '^workload-generator/global\.json couldn''t be read'
        $result.remediation | Should -Match ([regex]::Escape('git checkout -- workload-generator/global.json'))
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -Times 0 -Exactly
    }

    It 'never throws when dotnet can''t start: a Fail that says so' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -MockWith { throw 'Access to the path is denied.' }
        $result = Get-TestResult -Root $script:root
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match ([regex]::Escape('has no .NET SDK it can use here (dotnet --version: exit code none: it didn''t start)'))
    }
}

Describe 'deploy.ps1 installs the pinned .NET SDK for the user when none is found (Initialize-DemoDotNetSdk, 2026-11-09)' {
    BeforeAll {
        # A stand-in for Microsoft's SDK zip: a dotnet.exe, whose signature and --version are mocked, and an SDK file.
        $script:zipSource = Join-Path -Path $TestDrive -ChildPath 'fake-sdk-content'
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:zipSource -ChildPath 'sdk/10.0.403') -Force
        Set-Content -LiteralPath (Join-Path -Path $script:zipSource -ChildPath 'dotnet.exe') -Value 'not really dotnet' -NoNewline
        Set-Content -LiteralPath (Join-Path -Path $script:zipSource -ChildPath 'sdk/10.0.403/dotnet.dll') -Value 'not really the SDK' -NoNewline
        $script:fakeZip = Join-Path -Path $TestDrive -ChildPath 'fake-dotnet-sdk.zip'
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($script:zipSource, $script:fakeZip)
        $script:fakeSha512 = (Get-FileHash -LiteralPath $script:fakeZip -Algorithm SHA512).Hash.ToLowerInvariant()

        function Invoke-TestInitialize([switch] $WhatIfRun) {
            InModuleScope DbHubDemo -Parameters @{ Root = $script:root; WhatIfRun = [bool]$WhatIfRun } { Initialize-DemoDotNetSdk -ProgressPath 'progress.json' -RepositoryRoot $Root -Confirm:$false -WhatIf:$WhatIfRun }
        }

        # Linux and macOS hide a file or folder whose name starts with a dot, as the install's '.partial-' download and
        # extract do, and cmdlets skip a hidden item without -Force (CI on Ubuntu, 2026-11-09: Get-Item said "Could not find
        # item"). This marks such an item hidden on Windows too, so every OS runs the install the way Linux sees it.
        function Set-TestDotItemHidden([string] $Path) {
            if ($IsWindows -and (Split-Path -Path $Path -Leaf).StartsWith('.')) {
                [System.IO.File]::SetAttributes($Path, [System.IO.File]::GetAttributes($Path) -bor [System.IO.FileAttributes]::Hidden)
            }
        }

        # What another deploy.ps1 that installed it leaves: the SDK, then its record.
        function New-TestInstall([string] $Sha512 = $script:fakeSha512) {
            $null = New-Item -ItemType Directory -Path $script:pin.Folder -Force
            Copy-Item -Path (Join-Path -Path $script:zipSource -ChildPath '*') -Destination $script:pin.Folder -Recurse -Force
            Set-Content -LiteralPath (Join-Path -Path $script:pin.Folder -ChildPath 'dbhub-sdk.json') -Value (@{ version = '10.0.403'; sha512 = $Sha512 } | ConvertTo-Json)
        }
    }

    BeforeEach {
        $script:root = New-TestRepository
        $script:primary = Join-Path -Path (New-TestDotNetFolder -Name 'runtime-only') -ChildPath $script:exe
        $installRoot = Join-Path -Path $TestDrive -ChildPath ('DbHubDemo-dotnet-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:pin = [pscustomobject]@{
            Version   = '10.0.403'
            Rid       = 'win-x64'
            Url       = 'https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.403/dotnet-sdk-10.0.403-win-x64.zip'
            FileName  = 'dotnet-sdk-10.0.403-win-x64.zip'
            SizeBytes = [long]300745255
            Sha512    = $script:fakeSha512
            Root      = $installRoot
            Folder    = (Join-Path -Path $installRoot -ChildPath '10.0.403')
        }
        $script:held = $null
        $script:log = [System.Collections.Generic.List[string]]::new()
        $script:rows = [System.Collections.Generic.List[object]]::new()
        $script:signatureOk = $true
        $script:installedVersion = '10.0.403'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:log.Add([string]$Message) }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith {
            $script:rows.Add([pscustomobject]@{ Id = (@($Id) -join ','); State = [string]$PesterBoundParameters['State']; Status = [string]$PesterBoundParameters['Status']; Message = [string]$PesterBoundParameters['Message'] })
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetPath -MockWith { $script:primary }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetCandidateFolder -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetSdkPin -MockWith { $script:pin }
        # Microsoft's zip is 287 MB: the stand-in's progress is told in its terms.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -MockWith {
            Copy-Item -LiteralPath $script:fakeZip -Destination $Path
            Set-TestDotItemHidden -Path $Path
            & $OnProgress ([long]150372628) ([long]300745255)
            & $OnProgress ([long]300745255) ([long]300745255)
            [long](Get-Item -LiteralPath $Path -Force).Length
        }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoDotNetSignature -MockWith {
            if ($script:signatureOk) {
                return [pscustomobject]@{ Ok = $true; Status = 'Valid'; Subject = 'CN=.NET, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
            }
            [pscustomobject]@{ Ok = $false; Status = 'NotSigned'; Subject = '' }
        }
        # The dotnet first on PATH is runtime-only, as in the live finding; any other answers $script:installedVersion.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -MockWith {
            if ($DotNetPath -eq $script:primary) {
                if ($ArgumentList[0] -eq '--list-sdks') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                return [pscustomobject]@{ ExitCode = -2147450725; StdOut = ''; StdErr = $script:hostError }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = $script:installedVersion; StdErr = '' }
        }
    }

    AfterEach {
        if ($null -ne $script:held) {
            $script:held.Dispose()
            $script:held = $null
        }
    }

    It 'downloads Microsoft''s zip, checks its SHA-512, then dotnet.exe''s signature and global.json, installs it, and records it last' {
        $result = Invoke-TestInitialize
        $result.checkId | Should -Be 'DEPLOY.DOTNETSDK'
        $result.area | Should -Be 'preflight'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match ('^' + [regex]::Escape(('Installed the .NET SDK 10.0.403 for you in {0} in ' -f $script:pin.Folder)))
        $result.message | Should -Match 'nothing on PATH changed\.$'
        $result.evidence['dotnetPath'] | Should -Be (Join-Path -Path $script:pin.Folder -ChildPath 'dotnet.exe')
        $result.evidence['installed'] | Should -BeTrue
        $result.evidence['firstOnPath'] | Should -Be $script:primary
        Test-Path -LiteralPath (Join-Path -Path $script:pin.Folder -ChildPath 'sdk/10.0.403/dotnet.dll') -PathType Leaf | Should -BeTrue
        $record = Get-Content -LiteralPath (Join-Path -Path $script:pin.Folder -ChildPath 'dbhub-sdk.json') -Raw | ConvertFrom-Json -AsHashtable
        $record['version'] | Should -Be '10.0.403'
        $record['sha512'] | Should -Be $script:fakeSha512
        $record['url'] | Should -Be $script:pin.Url
        # Nothing else stays: no download, no extract folder, and no lock.
        @(Get-ChildItem -LiteralPath $script:pin.Root -Force | ForEach-Object { $_.Name }) | Should -Be @('10.0.403')
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -Times 1 -Exactly -ParameterFilter { $Url -eq $script:pin.Url }
        # The extracted copy is checked before it's moved into place, with 'dotnet --version' where global.json applies.
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoDotNetSignature -Times 1 -Exactly -ParameterFilter { $Path -like '*.partial-*dotnet.exe' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -Times 1 -Exactly -ParameterFilter {
            $DotNetPath -like '*.partial-*dotnet.exe' -and ($ArgumentList -join ' ') -eq '--version' -and $WorkingDirectory -eq (Join-Path -Path $script:root -ChildPath 'workload-generator')
        }
        # Its size and progress, on the console and the status page's .NET SDK row.
        $start = 'Installing the .NET SDK 10.0.403 for the workload runner, for you only, into {0}: downloading dotnet-sdk-10.0.403-win-x64.zip (287 MB) from Microsoft. No administrator rights, and nothing on PATH changes.' -f $script:pin.Folder
        $running = @($script:rows | Where-Object { $_.Id -eq 'DotNetSdk' -and $_.State -eq 'Running' } | ForEach-Object { $_.Message })
        $running | Should -Contain $start
        $running | Should -Contain 'Downloading the .NET SDK 10.0.403: 143 MB of 287 MB (50%).'
        @($running | Where-Object { $_ -match '^Downloaded \d+ MB and checked its SHA-512; extracting it\.$' }).Count | Should -Be 1
        $script:log | Should -Contain $start
        $script:log | Should -Contain 'Downloading the .NET SDK 10.0.403: 143 MB of 287 MB (50%).'
        $script:rows[-1].Id | Should -Be 'DotNetSdk'
        $script:rows[-1].State | Should -Be 'Done'
        $script:rows[-1].Status | Should -Be 'Pass'
    }

    It 'builds with it by its full path afterwards, the SDK check passes with it, and a later run reuses it without downloading' {
        $null = Invoke-TestInitialize
        $installed = Join-Path -Path $script:pin.Folder -ChildPath 'dotnet.exe'
        (InModuleScope DbHubDemo -Parameters @{ Root = $script:root } { Resolve-DemoBuildDotNet -RepositoryRoot $Root }) | Should -Be $installed
        $check = Get-TestResult -Root $script:root
        $check.status | Should -Be 'Pass'
        $check.evidence['source'] | Should -Be 'Installed'
        $check.evidence['dotnetPath'] | Should -Be $installed
        $check.message | Should -Match '^The \.NET SDK 10\.0\.403 that deploy\.ps1 installed for you builds the workload runner'
        $again = Invoke-TestInitialize
        $again.status | Should -Be 'Pass'
        $again.message | Should -Match ('^' + [regex]::Escape(('Reusing the .NET SDK 10.0.403 that deploy.ps1 installed for you in {0}: checked again' -f $script:pin.Folder)))
        $again.evidence['installed'] | Should -BeFalse
        $again.evidence['source'] | Should -Be 'Installed'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -Times 1 -Exactly
        # Each later use checks it again: the install's own check, the build, the SDK check, and the second run.
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoDotNetSignature -Times 4 -Exactly
    }

    It 'fails, saying nothing was created, and leaves nothing behind when <Case>' -ForEach @(
        @{ Case = 'the download''s SHA-512 isn''t the pinned one'; Setup = { $script:pin.Sha512 = 'ab' * 64 }; Why = 'dotnet-sdk-10.0.403-win-x64.zip''s SHA-512 isn''t the one config/versions.json pins from Microsoft''s release metadata (got '; Checked = 0 }
        @{ Case = 'dotnet.exe''s Authenticode signature isn''t Microsoft''s'; Setup = { $script:signatureOk = $false }; Why = 'The extracted .NET SDK 10.0.403 failed its check, so it was deleted: dotnet.exe''s Authenticode signature isn''t a valid one from Microsoft Corporation (status NotSigned)'; Checked = 1 }
        @{ Case = 'its dotnet --version in workload-generator isn''t the pinned version'; Setup = { $script:installedVersion = '10.0.402' }; Why = 'The extracted .NET SDK 10.0.403 failed its check, so it was deleted: ''dotnet --version'' in workload-generator answered 10.0.402 (exit code 0), not 10.0.403'; Checked = 1 }
        @{ Case = 'the download breaks off'; Setup = { Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -MockWith { Set-Content -LiteralPath $Path -Value 'half'; throw 'The download ended after 1,048,576 of 300,745,255 bytes.' } }; Why = 'The download ended after 1,048,576 of 300,745,255 bytes.'; Checked = 0 }
    ) {
        . $Setup
        $result = Invoke-TestInitialize
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match ('^' + [regex]::Escape('The .NET SDK 10.0.403 that the workload runner needs couldn''t be installed for you, so nothing was created: ' + $Why))
        $result.remediation | Should -Match '^Run \./scripts/deploy\.ps1 again: it removes what this install left and starts over'
        $result.remediation | Should -Match ([regex]::Escape('./scripts/deploy.ps1 -SkipRunner'))
        $result.evidence['installFolder'] | Should -Be $script:pin.Folder
        @(Get-ChildItem -LiteralPath $script:pin.Root -Force) | Should -BeNullOrEmpty -Because 'the download, the extracted copy, and the lock are all removed'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoDotNetSignature -Times $Checked -Exactly
        $script:rows[-1].State | Should -Be 'Failed'
        $script:rows[-1].Status | Should -Be 'Fail'
    }

    It 'removes what an interrupted install left, then installs it again: <Case>' -ForEach @(
        @{ Case = 'a partial download and extract, a version folder without its record, and a lock file nobody holds'; Record = '' }
        @{ Case = 'a version folder whose record is for another archive'; Record = ('cd' * 64) }
    ) {
        $null = New-Item -ItemType Directory -Path $script:pin.Root -Force
        Set-Content -LiteralPath (Join-Path -Path $script:pin.Root -ChildPath '.partial-0badc0de-dotnet-sdk-10.0.403-win-x64.zip') -Value 'half a download'
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:pin.Root -ChildPath '.partial-0badc0de-10.0.403/sdk') -Force
        foreach ($name in '.partial-0badc0de-dotnet-sdk-10.0.403-win-x64.zip', '.partial-0badc0de-10.0.403') {
            Set-TestDotItemHidden -Path (Join-Path -Path $script:pin.Root -ChildPath $name)
        }
        Set-Content -LiteralPath (Join-Path -Path $script:pin.Root -ChildPath 'install.lock') -Value ''
        if ($Record) {
            New-TestInstall -Sha512 $Record
        }
        else {
            $null = New-Item -ItemType Directory -Path $script:pin.Folder -Force
            Set-Content -LiteralPath (Join-Path -Path $script:pin.Folder -ChildPath 'dotnet.exe') -Value 'left by a stopped install'
        }
        $result = Invoke-TestInitialize
        $result.status | Should -Be 'Pass'
        $result.evidence['installed'] | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:pin.Root -Force | ForEach-Object { $_.Name }) | Should -Be @('10.0.403')
        Get-Content -LiteralPath (Join-Path -Path $script:pin.Folder -ChildPath 'dotnet.exe') -Raw | Should -Be 'not really dotnet'
        (Get-Content -LiteralPath (Join-Path -Path $script:pin.Folder -ChildPath 'dbhub-sdk.json') -Raw | ConvertFrom-Json -AsHashtable)['sha512'] | Should -Be $script:fakeSha512
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -Times 1 -Exactly
        @($script:log | Where-Object { $_ -like ('Removing {0} and installing it again: *' -f $script:pin.Folder) }).Count | Should -Be 1
    }

    It 'removes an earlier version it installed, and keeps a folder it didn''t install' {
        $older = Join-Path -Path $script:pin.Root -ChildPath '10.0.402'
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $older -ChildPath 'sdk') -Force
        Set-Content -LiteralPath (Join-Path -Path $older -ChildPath 'dbhub-sdk.json') -Value '{"version":"10.0.402"}'
        $notMine = Join-Path -Path $script:pin.Root -ChildPath '10.0.300'
        $null = New-Item -ItemType Directory -Path $notMine -Force
        $result = Invoke-TestInitialize
        $result.status | Should -Be 'Pass'
        Test-Path -LiteralPath $older | Should -BeFalse
        Test-Path -LiteralPath $notMine | Should -BeTrue -Because 'only a folder with deploy.ps1''s record is removed'
        @(Get-ChildItem -LiteralPath $script:pin.Root -Force -Filter '.partial-*') | Should -BeNullOrEmpty
    }

    # The lock matters where deploy.ps1 installs the SDK, on Windows, which enforces FileShare.None between handles.
    It 'waits for another deploy.ps1 that''s installing it, says so, then uses what it installed without downloading' -Skip:(-not $IsWindows) {
        $null = New-Item -ItemType Directory -Path $script:pin.Root -Force
        $script:held = [System.IO.File]::Open((Join-Path -Path $script:pin.Root -ChildPath 'install.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        # The other install finishes while this one waits: its SDK and record, then its lock goes.
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {
            if ($null -ne $script:held) {
                New-TestInstall
                $script:held.Dispose()
                $script:held = $null
            }
        }
        $result = Invoke-TestInitialize
        $result.status | Should -Be 'Pass'
        $result.message | Should -BeExactly ('Reusing the .NET SDK 10.0.403 that another deploy.ps1 installed for you in {0} meanwhile.' -f $script:pin.Folder)
        $result.evidence['installed'] | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -Times 0 -Exactly
        @($script:rows | Where-Object { $_.Message -like 'Another deploy.ps1 is installing the .NET SDK 10.0.403 into *; waiting for it.' }).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path -Path $script:pin.Root -ChildPath 'install.lock') | Should -BeFalse
    }

    It 'gives up with a clear error when another install holds the lock past the wait, and downloads nothing' -Skip:(-not $IsWindows) {
        $null = New-Item -ItemType Directory -Path $script:pin.Root -Force
        $script:held = [System.IO.File]::Open((Join-Path -Path $script:pin.Root -ChildPath 'install.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        { InModuleScope DbHubDemo -Parameters @{ Pin = $script:pin; Root = $script:root } { Install-DemoDotNetSdk -Pin $Pin -RepositoryRoot $Root -LockWaitMinutes 0 -Confirm:$false } } | Should -Throw '*stayed locked by another install for 0 minutes*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -Times 0 -Exactly
    }

    It 'installs nothing with -WhatIf: Not selected' {
        $result = Invoke-TestInitialize -WhatIfRun
        $result.status | Should -Be 'Not selected'
        $result.message | Should -Be ('What if: the .NET SDK 10.0.403 would be installed for you in {0}.' -f $script:pin.Folder)
        Test-Path -LiteralPath $script:pin.Root | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -Times 0 -Exactly
        $script:rows[-1].State | Should -Be 'Skipped'
    }

    It 'installs nothing, and builds with the dotnet first on PATH, when its SDK is one global.json accepts' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = '10.0.404'; StdErr = '' } }
        $result = Invoke-TestInitialize
        $result.status | Should -Be 'Pass'
        $result.message | Should -BeExactly ('The dotnet first on PATH, {0}, has the .NET SDK 10.0.404, which global.json accepts: nothing to install.' -f $script:primary)
        $result.evidence['installed'] | Should -BeFalse
        $result.evidence['source'] | Should -Be 'PATH'
        (InModuleScope DbHubDemo -Parameters @{ Root = $script:root } { Resolve-DemoBuildDotNet -RepositoryRoot $Root }) | Should -Be $script:primary
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDotNetSdkPin -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -Times 0 -Exactly
        Test-Path -LiteralPath $script:pin.Root | Should -BeFalse
    }

    It 'is a Fail with the manual fix where deploy.ps1 installs no SDK (no pinned archive for this platform)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetSdkPin -MockWith { $null }
        $result = Invoke-TestInitialize
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'so the workload runner can''t be built\. deploy\.ps1 installs the \.NET SDK by itself only on Windows\.$'
        $result.remediation | Should -Match '^Install the \.NET SDK 10\.0\.403 or later'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -Times 0 -Exactly
        $script:rows[-1].State | Should -Be 'Failed'
    }

    It 'is a Fail that says how to restore global.json when it can''t be read, and installs nothing' {
        $script:root = New-TestRepository -GlobalJson ''
        $result = Invoke-TestInitialize
        $result.status | Should -Be 'Fail'
        $result.remediation | Should -Match ([regex]::Escape('git checkout -- workload-generator/global.json'))
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -Times 0 -Exactly
    }

    It 'makes the SDK check a Warning, not a Fail, where deploy.ps1 installs it, saying it will before it creates anything; the check itself installs nothing' {
        $result = Get-TestResult -Root $script:root
        $result.status | Should -Be 'Warning'
        $result.message | Should -BeExactly ('The dotnet first on PATH, {0}, has no .NET SDK, only runtimes, and workload-generator/global.json needs 10.0.403 or any later 10.0 SDK (rollForward latestFeature), so the workload runner can''t be built.' -f $script:primary)
        $result.remediation | Should -Match ('^' + [regex]::Escape(('Run ./scripts/deploy.ps1: before it creates anything, it installs the .NET SDK 10.0.403 for you in {0} (a 287 MB download, with no administrator rights and no change to PATH) and builds with it. Or install the .NET SDK 10.0.403 or later' -f $script:pin.Folder)))
        $result.remediation | Should -Match ([regex]::Escape('./scripts/deploy.ps1 -SkipRunner'))
        $result.evidence['installFolder'] | Should -Be $script:pin.Folder
        $result.evidence['installVersion'] | Should -Be '10.0.403'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDotNetSdkDownload -Times 0 -Exactly
        { InModuleScope DbHubDemo -Parameters @{ Root = $script:root } { Resolve-DemoBuildDotNet -RepositoryRoot $Root } } | Should -Throw '*so the workload runner can''t be built. Run ./scripts/deploy.ps1: before it creates anything*'
    }
}

Describe 'Where deploy.ps1 installs the .NET SDK, and which archive (Get-DemoDotNetSdkInstallRoot, Get-DemoDotNetSdkPin)' {
    BeforeAll {
        $script:savedInstallRoot = [System.Environment]::GetEnvironmentVariable('DBHUB_DOTNET_INSTALL_ROOT')
    }

    AfterAll {
        [System.Environment]::SetEnvironmentVariable('DBHUB_DOTNET_INSTALL_ROOT', $script:savedInstallRoot)
    }

    It 'installs into the user''s local application data, DbHubDemo/dotnet, or the folder DBHUB_DOTNET_INSTALL_ROOT names' {
        [System.Environment]::SetEnvironmentVariable('DBHUB_DOTNET_INSTALL_ROOT', $null)
        $expected = [System.IO.Path]::GetFullPath((Join-Path -Path ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)) -ChildPath 'DbHubDemo/dotnet'))
        (InModuleScope DbHubDemo { Get-DemoDotNetSdkInstallRoot }) | Should -Be $expected
        $custom = Join-Path -Path $TestDrive -ChildPath 'sdk-root'
        [System.Environment]::SetEnvironmentVariable('DBHUB_DOTNET_INSTALL_ROOT', $custom)
        (InModuleScope DbHubDemo { Get-DemoDotNetSdkInstallRoot }) | Should -Be ([System.IO.Path]::GetFullPath($custom))
    }

    It 'reads this machine''s archive from config/versions.json on Windows, and none elsewhere' {
        $custom = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'sdk-root'))
        [System.Environment]::SetEnvironmentVariable('DBHUB_DOTNET_INSTALL_ROOT', $custom)
        $pin = InModuleScope DbHubDemo -Parameters @{ Root = $repoRoot } { Get-DemoDotNetSdkPin -RepositoryRoot $Root }
        $rid = switch ([string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) { 'X64' { 'win-x64' } 'Arm64' { 'win-arm64' } default { '' } }
        if (-not $IsWindows -or -not $rid) {
            $pin | Should -BeNullOrEmpty
            return
        }
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $pin.Version | Should -Be $versions['tools']['dotnetSdk']
        $pin.Rid | Should -Be $rid
        $pin.Url | Should -Be $versions['dotnetSdkInstall']['files'][$rid]['url']
        $pin.FileName | Should -Be $versions['dotnetSdkInstall']['files'][$rid]['fileName']
        $pin.Sha512 | Should -Match '^[0-9a-f]{128}$'
        $pin.Root | Should -Be $custom
        $pin.Folder | Should -Be (Join-Path -Path $custom -ChildPath $pin.Version)
    }

    It 'downloads only over HTTPS' {
        $target = Join-Path -Path $TestDrive -ChildPath 'never-written.zip'
        { InModuleScope DbHubDemo -Parameters @{ Path = $target } { Invoke-DemoDotNetSdkDownload -Url 'http://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.403/dotnet-sdk-10.0.403-win-x64.zip' -Path $Path } } | Should -Throw '*Only an HTTPS download is allowed*'
        Test-Path -LiteralPath $target | Should -BeFalse
    }
}

Describe 'Test-DemoDotNetSignature: a valid Authenticode signature from Microsoft Corporation' -Skip:(-not $IsWindows) {
    It 'is <Ok> for status <Status> and signer <Subject>' -ForEach @(
        @{ Status = 'Valid'; Subject = 'CN=.NET, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Ok = $true }
        @{ Status = 'Valid'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Ok = $true }
        @{ Status = 'HashMismatch'; Subject = 'CN=.NET, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Ok = $false }
        @{ Status = 'NotSigned'; Subject = ''; Ok = $false }
        @{ Status = 'Valid'; Subject = 'CN=Contoso, O=Contoso Ltd, C=US'; Ok = $false }
        @{ Status = 'Valid'; Subject = 'CN=x, O=Microsoft Corporation Fans, C=US'; Ok = $false }
    ) {
        $script:signatureStatus = $Status
        $script:signatureSubject = $Subject
        Mock -ModuleName DbHubDemo -CommandName Get-AuthenticodeSignature -MockWith {
            [pscustomobject]@{ Status = $script:signatureStatus; SignerCertificate = $(if ($script:signatureSubject) { [pscustomobject]@{ Subject = $script:signatureSubject } } else { $null }) }
        }
        $check = InModuleScope DbHubDemo { Test-DemoDotNetSignature -Path 'C:\sdk\dotnet.exe' }
        $check.Ok | Should -Be $Ok
        $check.Status | Should -Be $Status
    }

    It 'rejects an unsigned file, and accepts this PowerShell, which Microsoft signs' {
        $unsigned = Join-Path -Path $TestDrive -ChildPath 'dotnet.exe'
        Set-Content -LiteralPath $unsigned -Value 'not signed'
        (InModuleScope DbHubDemo -Parameters @{ Path = $unsigned } { Test-DemoDotNetSignature -Path $Path }).Ok | Should -BeFalse
        $shell = (Get-Process -Id $PID).Path
        if ((Get-AuthenticodeSignature -FilePath $shell).Status -ne 'Valid') {
            Set-ItResult -Skipped -Because 'this PowerShell''s executable carries no valid signature of its own'
            return
        }
        (InModuleScope DbHubDemo -Parameters @{ Path = $shell } { Test-DemoDotNetSignature -Path $Path }).Ok | Should -BeTrue
    }
}

Describe 'Get-DemoDotNetSdkRequirement: what global.json asks for, in words' {
    It 'reads <Json> as <Text>' -ForEach @(
        @{ Json = '{"sdk":{"version":"10.0.403","rollForward":"latestFeature"}}'; Text = '10.0.403 or any later 10.0 SDK (rollForward latestFeature)' }
        @{ Json = '{"sdk":{"version":"10.0.403","rollForward":"latestPatch"}}'; Text = '10.0.403 or a later 10.0.4xx patch (rollForward latestPatch)' }
        @{ Json = '{"sdk":{"version":"10.0.403"}}'; Text = '10.0.403 or a later 10.0.4xx patch (rollForward latestPatch)' }
        @{ Json = '{"sdk":{"version":"10.0.403","rollForward":"disable"}}'; Text = 'exactly 10.0.403 (rollForward disable)' }
        @{ Json = '{"sdk":{"version":"10.0.403","rollForward":"latestMinor"}}'; Text = '10.0.403 or any later 10.x SDK (rollForward latestMinor)' }
        @{ Json = '{"sdk":{"version":"10.0.403","rollForward":"latestMajor"}}'; Text = '10.0.403 or any later SDK (rollForward latestMajor)' }
    ) {
        $root = New-TestRepository -GlobalJson $Json
        $requirement = InModuleScope DbHubDemo -Parameters @{ Generator = (Join-Path -Path $root -ChildPath 'workload-generator') } { Get-DemoDotNetSdkRequirement -GeneratorPath $Generator }
        $requirement.Text | Should -BeExactly $Text
        $requirement.Version | Should -Be '10.0.403'
        $requirement.Major | Should -Be '10'
        $requirement.MajorMinor | Should -Be '10.0'
    }

    It 'reads the repository''s own global.json, which pins tools.dotnetSdk' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $requirement = InModuleScope DbHubDemo -Parameters @{ Generator = (Join-Path -Path $repoRoot -ChildPath 'workload-generator') } { Get-DemoDotNetSdkRequirement -GeneratorPath $Generator }
        $requirement.Version | Should -Be $versions['tools']['dotnetSdk']
    }
}

Describe 'Get-DemoDotNetCandidateFolder: the well-known SDK folders, once each' {
    BeforeAll {
        $script:savedRoot = [System.Environment]::GetEnvironmentVariable('DOTNET_ROOT')
    }

    AfterAll {
        [System.Environment]::SetEnvironmentVariable('DOTNET_ROOT', $script:savedRoot)
    }

    It 'lists DOTNET_ROOT first, then the installers'', dotnet-install.ps1''s, and dotnet-install.sh''s defaults, without a duplicate' {
        $custom = Join-Path -Path $TestDrive -ChildPath 'custom-dotnet'
        [System.Environment]::SetEnvironmentVariable('DOTNET_ROOT', $custom)
        $folders = @(InModuleScope DbHubDemo { Get-DemoDotNetCandidateFolder })
        $folders[0].Name | Should -Be 'DOTNET_ROOT'
        $folders[0].Folder | Should -Be ([System.IO.Path]::GetFullPath($custom))
        $folders.Name | Should -Contain '~/.dotnet'
        if ($IsWindows) {
            $folders.Name | Should -Contain '%ProgramFiles%\dotnet'
            $folders.Name | Should -Contain '%LOCALAPPDATA%\Microsoft\dotnet'
        }
        # DOTNET_ROOT set to a folder that's also on the list counts once.
        [System.Environment]::SetEnvironmentVariable('DOTNET_ROOT', (Join-Path -Path $HOME -ChildPath '.dotnet'))
        $again = @(InModuleScope DbHubDemo { Get-DemoDotNetCandidateFolder })
        @($again | Where-Object { $_.Folder -eq ([System.IO.Path]::GetFullPath((Join-Path -Path $HOME -ChildPath '.dotnet'))) }).Count | Should -Be 1
    }
}

Describe 'Invoke-DemoDotNet -DotNetPath' {
    It 'runs that executable in the working directory, and the first dotnet on PATH without it' {
        # This PowerShell stands in for dotnet: it writes a file where it runs, prints a line, and exits 3.
        $workingDirectory = Join-Path -Path $TestDrive -ChildPath 'work'
        $null = New-Item -ItemType Directory -Path $workingDirectory -Force
        $run = InModuleScope DbHubDemo -Parameters @{ Shell = (Get-Process -Id $PID).Path; Dir = $workingDirectory } {
            Invoke-DemoDotNet -DotNetPath $Shell -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Set-Content -LiteralPath dotnet-ran-here.txt -Value x; Write-Output ran; exit 3') -WorkingDirectory $Dir
        }
        $run.ExitCode | Should -Be 3
        $run.StdOut.Trim() | Should -Be 'ran'
        Test-Path -LiteralPath (Join-Path -Path $workingDirectory -ChildPath 'dotnet-ran-here.txt') | Should -BeTrue -Because 'global.json applies only from the working directory'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetPath -MockWith { '' }
        { InModuleScope DbHubDemo { Invoke-DemoDotNet -ArgumentList @('--version') -WorkingDirectory $TestDrive } } | Should -Throw '*was not found on PATH*'
    }
}

Describe 'DEPLOY.ARTIFACTS.BUILD''s remediation: the SDK check''s own diagnosis and fix when the build failed on the SDK (2026-11-09 live finding)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:status = [pscustomobject]@{ Ok = $false; Message = 'The dotnet first on PATH, C:\Program Files\dotnet\dotnet.exe, has no .NET SDK, only runtimes, and workload-generator/global.json needs 10.0.403 or any later 10.0 SDK (rollForward latestFeature), so the workload runner can''t be built.'; Fix = 'Install the .NET SDK 10.0.403 or later: winget install Microsoft.DotNet.SDK.10.' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetSdkStatus -MockWith { $script:status }
        # The live run's message, as DEPLOY.ARTIFACTS.BUILD reported it.
        $script:live = 'dotnet publish failed with exit code -2147450725: The command could not be loaded, possibly because: * You intended to execute a .NET application: The application ''publish'' does not exist or is not a managed .dll or .exe. * You intended to execute a .NET SDK command: A compatible .NET SDK was ...'
    }

    It 'recognizes the SDK in the host''s words and Invoke-DemoDotNet''s: <Case>' -ForEach @(
        @{ Case = 'the live run''s message'; Text = 'dotnet publish failed with exit code -2147450725: The command could not be loaded'; Sdk = $true }
        @{ Case = 'no SDK at all'; Text = 'Installed SDKs: No .NET SDKs were found.'; Sdk = $true }
        @{ Case = 'none that global.json accepts'; Text = 'A compatible .NET SDK was not found. Requested SDK version: 10.0.403'; Sdk = $true }
        @{ Case = 'no dotnet on PATH'; Text = 'The .NET SDK (dotnet) was not found on PATH. Install the SDK pinned in config/versions.json'; Sdk = $true }
        @{ Case = 'the host''s status code'; Text = 'exited with 0x8000809B'; Sdk = $true }
        @{ Case = 'Resolve-DemoBuildDotNet''s words (2026-11-09)'; Text = 'The dotnet first on PATH, C:\Program Files\dotnet\dotnet.exe, has no .NET SDK, only runtimes, and workload-generator/global.json needs 10.0.403 or any later 10.0 SDK (rollForward latestFeature), so the workload runner can''t be built. Run ./scripts/deploy.ps1'; Sdk = $true }
        @{ Case = 'a compile error'; Text = 'dotnet publish failed with exit code 1: error CS1002: ; expected'; Sdk = $false }
        @{ Case = 'a locked restore'; Text = 'NU1004: The packages lock file is inconsistent.'; Sdk = $false }
        @{ Case = 'the bundle'; Text = 'New-DemoBootstrapBundle: a file is missing'; Sdk = $false }
    ) {
        (InModuleScope DbHubDemo -Parameters @{ Text = $Text } { Test-DemoDotNetSdkFailure -Text $Text }) | Should -Be $Sdk
    }

    It 'is the check''s message and fix for an SDK failure, read again now' {
        $remediation = InModuleScope DbHubDemo -Parameters @{ Message = $script:live } { Get-DemoArtifactBuildRemediation -Message $Message }
        $remediation | Should -BeExactly ('{0} {1}' -f $script:status.Message, $script:status.Fix)
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDotNetSdkStatus -Times 1 -Exactly
    }

    It 'keeps the generic step for any other failure, without checking the SDK' {
        $remediation = InModuleScope DbHubDemo { Get-DemoArtifactBuildRemediation -Message 'dotnet publish failed with exit code 1: error CS1002' }
        $remediation | Should -BeExactly 'Run New-DemoBootstrapBundle and Publish-DemoWorkloadRunner yourself to see the error (the runner needs the .NET SDK, or use -SkipRunner).'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDotNetSdkStatus -Times 0 -Exactly
    }

    It 'still names the SDK and -SkipRunner when the check passes now or can''t run: <Case>' -ForEach @(
        @{ Case = 'it passes now'; Throws = $false }
        @{ Case = 'it throws'; Throws = $true }
    ) {
        if ($Throws) {
            Mock -ModuleName DbHubDemo -CommandName Get-DemoDotNetSdkStatus -MockWith { throw 'broken' }
        }
        else {
            $script:status = [pscustomobject]@{ Ok = $true; Message = ''; Fix = '' }
        }
        $remediation = InModuleScope DbHubDemo -Parameters @{ Message = $script:live } { Get-DemoArtifactBuildRemediation -Message $Message }
        $remediation | Should -Match 'PREFLIGHT\.TOOLS\.DOTNETSDK'
        $remediation | Should -Match ([regex]::Escape('./scripts/deploy.ps1 -SkipRunner'))
    }
}
