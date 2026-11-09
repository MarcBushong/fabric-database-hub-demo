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
