BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    Add-Type -AssemblyName 'System.IO.Compression'
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

    function New-FakeRunnerRepository {
        # The inputs Publish-DemoWorkloadRunner hashes, with no real source.
        $root = Join-Path -Path $TestDrive -ChildPath ('runner-repo-' + [guid]::NewGuid().ToString('N'))
        foreach ($folder in 'workload-generator/src/ContosoCare.Workload', 'scenarios/healthy-baseline', 'database/common', 'config') {
            New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath $folder) -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-generator/src/ContosoCare.Workload/ContosoCare.Workload.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk" />'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-generator/src/ContosoCare.Workload/Program.cs') -Value 'return 0;'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-generator/global.json') -Value '{ "sdk": { "version": "10.0.402" } }'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'scenarios/healthy-baseline/scenario.json') -Value '{ "id": "healthy-baseline" }'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'database/common/110-demo-control.sql') -Value 'SELECT 1;'
        Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Destination (Join-Path -Path $root -ChildPath 'config/versions.json')
        return $root
    }

    function Get-ZipEntry([string] $Path) {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            return @($archive.Entries | ForEach-Object { [pscustomobject]@{ Name = $_.FullName; Time = $_.LastWriteTime } })
        }
        finally {
            $archive.Dispose()
        }
    }

    function Read-ZipText([string] $Path, [string] $Entry) {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $reader = [System.IO.StreamReader]::new($archive.GetEntry($Entry).Open())
            try {
                return $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }
    }

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        return $config
    }

    function New-RunCommandResponse([string] $Line, [string] $StdErr = '') {
        # The shape 'az vm run-command invoke' returns: value[] entries for StdOut and StdErr.
        $value = @(
            @{ code = 'ComponentStatus/StdOut/succeeded'; level = 'Info'; message = $Line }
            @{ code = 'ComponentStatus/StdErr/succeeded'; level = 'Info'; message = $StdErr }
        )
        [pscustomobject]@{ ExitCode = 0; StdOut = (@{ value = $value } | ConvertTo-Json -Depth 5); StdErr = '' }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Publish-DemoWorkloadRunner' {
    BeforeEach {
        $script:publishCalls = [System.Collections.Generic.List[object]]::new()
        $script:fakeDll = 'runner dll v1'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -MockWith {
            $script:publishCalls.Add([pscustomobject]@{ Arguments = $ArgumentList; WorkingDirectory = $WorkingDirectory })
            $output = $ArgumentList[[array]::IndexOf($ArgumentList, '--output') + 1]
            New-Item -ItemType Directory -Path (Join-Path -Path $output -ChildPath 'runtimes') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $output -ChildPath 'ContosoCare.Workload.dll') -Value $script:fakeDll -NoNewline
            Set-Content -LiteralPath (Join-Path -Path $output -ChildPath 'ContosoCare.Workload.runtimeconfig.json') -Value '{}' -NoNewline
            Set-Content -LiteralPath (Join-Path -Path $output -ChildPath 'ContosoCare.Workload.deps.json') -Value '{}' -NoNewline
            Set-Content -LiteralPath (Join-Path -Path $output -ChildPath 'ContosoCare.Workload.pdb') -Value 'build paths' -NoNewline
            Set-Content -LiteralPath (Join-Path -Path $output -ChildPath 'Azure.Core.dll') -Value 'azure' -NoNewline
            Set-Content -LiteralPath (Join-Path -Path $output -ChildPath 'runtimes/native.dll') -Value 'native' -NoNewline
            [pscustomobject]@{ ExitCode = 0; StdOut = 'published'; StdErr = '' }
        }
    }

    It 'publishes framework-dependent for win-x64 with locked-mode restore, from workload-generator' {
        $fake = New-FakeRunnerRepository
        $runner = Publish-DemoWorkloadRunner -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'p1')

        $script:publishCalls.Count | Should -Be 1
        $arguments = $script:publishCalls[0].Arguments
        $arguments[0] | Should -Be 'publish'
        $arguments[1] | Should -Match 'ContosoCare\.Workload\.csproj$'
        ($arguments -join ' ') | Should -Match '--configuration Release'
        ($arguments -join ' ') | Should -Match '--runtime win-x64'
        ($arguments -join ' ') | Should -Match '--self-contained false'
        $arguments | Should -Contain '-p:RestoreLockedMode=true'
        # No program database: its Source Link data holds the checkout's path and the commit (live, 2026-10-22).
        $arguments | Should -Contain '-p:DebugType=none'
        $script:publishCalls[0].WorkingDirectory | Should -Be (Join-Path -Path $fake -ChildPath 'workload-generator')
        $runner.RuntimeIdentifier | Should -Be 'win-x64'
        $runner.Reused | Should -BeFalse
    }

    It 'zips the publish output deterministically, without program databases, with a manifest' {
        $fake = New-FakeRunnerRepository
        $runner = Publish-DemoWorkloadRunner -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'p2')

        $runner.FileName | Should -Match '^contosocare-workload-\d+\.\d+\.\d+-win-x64-[0-9a-f]{12}\.zip$'
        $runner.Sha256 | Should -Be (Get-FileHash -LiteralPath $runner.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        $runner.SizeBytes | Should -Be (Get-Item -LiteralPath $runner.Path).Length
        $entries = Get-ZipEntry -Path $runner.Path
        $entries.Name | Should -Be @('runner-manifest.json', 'Azure.Core.dll', 'ContosoCare.Workload.deps.json', 'ContosoCare.Workload.dll', 'ContosoCare.Workload.runtimeconfig.json', 'runtimes/native.dll')
        $entries.Name | Should -Not -Contain 'ContosoCare.Workload.pdb'
        foreach ($entry in $entries) {
            # Zip entries keep a DOS time without a zone, read back with the local offset: compare the clock time.
            $entry.Time.DateTime | Should -Be ([datetime]::new(2020, 1, 1, 0, 0, 0))
        }
        $manifest = Read-ZipText -Path $runner.Path -Entry 'runner-manifest.json' | ConvertFrom-Json -AsHashtable
        $manifest.name | Should -Be 'ContosoCare.Workload'
        $manifest.entryPoint | Should -Be 'ContosoCare.Workload.dll'
        $manifest.runtimeIdentifier | Should -Be 'win-x64'
        $manifest.sourceSha256 | Should -Be $runner.SourceSha256
        $manifest.files.Count | Should -Be 5
        $runner.FileCount | Should -Be 5
    }

    It 'builds the same zip, byte for byte, from the same output' {
        $fake = New-FakeRunnerRepository
        $first = Publish-DemoWorkloadRunner -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'p3a')
        $second = Publish-DemoWorkloadRunner -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'p3b') -Force
        $second.Sha256 | Should -Be $first.Sha256
    }

    It 'reuses a zip built from the same inputs, so deploy.ps1 -Resume keeps the same SHA-256' {
        $fake = New-FakeRunnerRepository
        $output = Join-Path -Path $TestDrive -ChildPath 'p4'
        $first = Publish-DemoWorkloadRunner -RepositoryRoot $fake -OutputDirectory $output
        $script:fakeDll = 'a different build of the same source'
        $second = Publish-DemoWorkloadRunner -RepositoryRoot $fake -OutputDirectory $output

        $second.Reused | Should -BeTrue
        $second.Sha256 | Should -Be $first.Sha256
        $second.FileCount | Should -Be $first.FileCount
        $script:publishCalls.Count | Should -Be 1
    }

    It 'builds again, under a new name, when an input changes' {
        $fake = New-FakeRunnerRepository
        $output = Join-Path -Path $TestDrive -ChildPath 'p5'
        $first = Publish-DemoWorkloadRunner -RepositoryRoot $fake -OutputDirectory $output
        Set-Content -LiteralPath (Join-Path -Path $fake -ChildPath 'database/common/110-demo-control.sql') -Value 'SELECT 2;'
        $second = Publish-DemoWorkloadRunner -RepositoryRoot $fake -OutputDirectory $output

        $second.SourceSha256 | Should -Not -Be $first.SourceSha256
        $second.FileName | Should -Not -Be $first.FileName
        $script:publishCalls.Count | Should -Be 2
    }

    It 'hashes line endings the same way, so a CRLF checkout keeps the same runner name' {
        $fake = New-FakeRunnerRepository
        $before = & (Get-Module -Name DbHubDemo) { param($r) Get-DemoWorkloadSourceHash -RepositoryRoot $r -RuntimeIdentifier 'win-x64' -SdkVersion '10.0.402' } $fake
        [System.IO.File]::WriteAllText((Join-Path -Path $fake -ChildPath 'workload-generator/src/ContosoCare.Workload/Program.cs'), "return 0;`r`n")
        $crlf = & (Get-Module -Name DbHubDemo) { param($r) Get-DemoWorkloadSourceHash -RepositoryRoot $r -RuntimeIdentifier 'win-x64' -SdkVersion '10.0.402' } $fake
        [System.IO.File]::WriteAllText((Join-Path -Path $fake -ChildPath 'workload-generator/src/ContosoCare.Workload/Program.cs'), "return 0;`n")
        $lf = & (Get-Module -Name DbHubDemo) { param($r) Get-DemoWorkloadSourceHash -RepositoryRoot $r -RuntimeIdentifier 'win-x64' -SdkVersion '10.0.402' } $fake
        $crlf | Should -Be $lf
        $before | Should -Match '^[0-9a-f]{64}$'
    }

    It 'hashes the publish properties too, so changing them builds a new runner' {
        $fake = New-FakeRunnerRepository
        $without = & (Get-Module -Name DbHubDemo) { param($r) Get-DemoWorkloadSourceHash -RepositoryRoot $r -RuntimeIdentifier 'win-x64' -SdkVersion '10.0.402' -BuildProperty '-p:RestoreLockedMode=true' } $fake
        $with = & (Get-Module -Name DbHubDemo) { param($r) Get-DemoWorkloadSourceHash -RepositoryRoot $r -RuntimeIdentifier 'win-x64' -SdkVersion '10.0.402' -BuildProperty '-p:RestoreLockedMode=true', '-p:DebugType=none' } $fake
        $again = & (Get-Module -Name DbHubDemo) { param($r) Get-DemoWorkloadSourceHash -RepositoryRoot $r -RuntimeIdentifier 'win-x64' -SdkVersion '10.0.402' -BuildProperty '-p:RestoreLockedMode=true', '-p:DebugType=none' } $fake
        $with | Should -Not -Be $without
        $again | Should -Be $with
    }

    It 'stops with the SDK''s error when dotnet publish fails' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDotNet -MockWith { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'NU1004: The packages lock file is inconsistent.' } }
        $fake = New-FakeRunnerRepository
        { Publish-DemoWorkloadRunner -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'p6') } | Should -Throw '*exit code 1*NU1004*'
        @(Get-ChildItem -Path (Join-Path -Path $TestDrive -ChildPath 'p6') -Filter '*.zip' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'builds nothing with -WhatIf' {
        $fake = New-FakeRunnerRepository
        Publish-DemoWorkloadRunner -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'p7') -WhatIf | Should -BeNullOrEmpty
        $script:publishCalls.Count | Should -Be 0
    }
}

Describe 'Send-DemoWorkloadRunner' {
    BeforeAll {
        $config = New-TestConfig
        $runnerFile = Join-Path -Path $TestDrive -ChildPath 'runner.zip'
        [System.IO.File]::WriteAllBytes($runnerFile, [byte[]](1..200))
        $runner = [pscustomobject]@{ Path = $runnerFile; Sha256 = (Get-FileHash -LiteralPath $runnerFile -Algorithm SHA256).Hash.ToLowerInvariant(); SizeBytes = 200 }
    }

    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Send-DemoBootstrapBundle -MockWith {
            [pscustomobject]@{ VmName = $VmName; BundleSha256 = $Bundle.Sha256; ChunkCount = 3; Seconds = 12.5 }
        }
    }

    It 'sends the runner through the bootstrap chunk path, labeled as the workload runner' {
        $sent = Send-DemoWorkloadRunner -Config $config -Runner $runner -VmName 'archost01' -ChunkSizeKiB 256

        $sent.VmName | Should -Be 'archost01'
        $sent.RunnerSha256 | Should -Be $runner.Sha256
        $sent.ChunkCount | Should -Be 3
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoBootstrapBundle -Times 1 -Exactly -ParameterFilter {
            $Bundle.Sha256 -eq $runner.Sha256 -and $VmName -eq 'archost01' -and $ChunkSizeKiB -eq 256 -and $Description -eq 'workload runner'
        }
    }

    It 'refuses an object that isn''t a published runner' {
        { Send-DemoWorkloadRunner -Config $config -Runner ([pscustomobject]@{ Path = $runnerFile }) -VmName 'sqlvm01' } | Should -Throw '*Publish-DemoWorkloadRunner*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoBootstrapBundle -Times 0
    }

    It 'sends nothing with -WhatIf' {
        Send-DemoWorkloadRunner -Config $config -Runner $runner -VmName 'sqlvm01' -WhatIf | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoBootstrapBundle -Times 0
    }
}

Describe 'The secret check on binary content' {
    BeforeAll {
        function New-TestZip([hashtable] $Entries) {
            $path = Join-Path -Path $TestDrive -ChildPath ('zip-' + [guid]::NewGuid().ToString('N') + '.zip')
            $stream = [System.IO.File]::Create($path)
            try {
                $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
                try {
                    foreach ($name in $Entries.Keys) {
                        $entryStream = $archive.CreateEntry($name).Open()
                        try {
                            $bytes = [byte[]]$Entries[$name]
                            $entryStream.Write($bytes, 0, $bytes.Length)
                        }
                        finally {
                            $entryStream.Dispose()
                        }
                    }
                }
                finally {
                    $archive.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }
            return $path
        }
        # The runner's own redactor holds this pattern; the check builds it at run time so scanners stay quiet.
        $pattern = 'Account' + 'Key=' + 'abcdef'
    }

    It 'accepts a compiled assembly that holds a redaction pattern' {
        $binary = [byte[]](@(0x4D, 0x5A, 0x00, 0x00) + [System.Text.Encoding]::UTF8.GetBytes($pattern))
        $zip = New-TestZip @{ 'ContosoCare.Workload.dll' = $binary }
        @(New-DemoBootstrapChunk -Path $zip).Count | Should -Be 1
    }

    It 'still refuses the same pattern in a text file' {
        $zip = New-TestZip @{ 'settings.json' = [System.Text.Encoding]::UTF8.GetBytes($pattern) }
        { New-DemoBootstrapChunk -Path $zip } | Should -Throw '*settings.json*account-key*'
    }

    It 'refuses a registered secret in a binary entry, in UTF-8 or UTF-16' {
        $secret = 'Zq' + [guid]::NewGuid().ToString('N')
        Register-DemoSecret -Value $secret
        $utf16 = [byte[]](@(0x4D, 0x5A, 0x00, 0x00) + [System.Text.Encoding]::Unicode.GetBytes($secret))
        $zip = New-TestZip @{ 'Assembly.dll' = $utf16 }
        { New-DemoBootstrapChunk -Path $zip } | Should -Throw '*Assembly.dll contains a registered secret*'
    }
}

Describe 'New-DemoBootstrapBundle with the .NET runtime pin' {
    It 'carries config/versions.json dotnetRuntime in the manifest, without the note' {
        $bundle = New-DemoBootstrapBundle -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'bundle')
        $manifest = Read-ZipText -Path $bundle.Path -Entry 'bundle-manifest.json' | ConvertFrom-Json -AsHashtable
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $manifest.dotnetRuntime.sha512 | Should -Be $versions.dotnetRuntime.sha512
        $manifest.dotnetRuntime.url | Should -Be $versions.dotnetRuntime.url
        $manifest.dotnetRuntime.fileName | Should -Be $versions.dotnetRuntime.fileName
        $manifest.dotnetRuntime.Keys | Should -Not -Contain 'note'
    }

    It 'bundles the workload scripts the VMs run' {
        $bundle = New-DemoBootstrapBundle -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'bundle2')
        $names = (Get-ZipEntry -Path $bundle.Path).Name
        foreach ($expected in 'vm/bootstrap/Start-DemoWorkload.ps1', 'vm/bootstrap/Invoke-DemoWorkloadControl.ps1', 'vm/bootstrap/lib/Workload.ps1', 'vm/hyperv-guest/GuestWorkload.ps1', 'database/common/110-demo-control.sql', 'database/common/120-scenario-procedures.sql') {
            $names | Should -Contain $expected
        }
    }
}

Describe 'Get-DemoDeploymentParameter with the workload runner' {
    BeforeAll {
        $config = New-TestConfig
        $sha = 'ab' * 32
    }

    It 'passes the runner''s SHA-256 and chunk count only when the runner was sent' {
        $without = Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true -BootstrapBundleSha256 ('cd' * 32) -BootstrapChunkCount 1
        $without.parameters.Contains('workloadRunnerSha256') | Should -BeFalse
        $with = Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true -BootstrapBundleSha256 ('cd' * 32) -BootstrapChunkCount 1 -WorkloadRunnerSha256 $sha.ToUpperInvariant() -WorkloadRunnerChunkCount 7
        $with.parameters.workloadRunnerSha256.value | Should -Be $sha
        $with.parameters.workloadRunnerChunkCount.value | Should -Be 7
    }

    It 'needs the chunk count with the SHA-256, and the bootstrap bundle with the runner' {
        { Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true -BootstrapBundleSha256 ('cd' * 32) -BootstrapChunkCount 1 -WorkloadRunnerSha256 $sha } | Should -Throw '*WorkloadRunnerChunkCount is required*'
        { Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true -WorkloadRunnerChunkCount 3 } | Should -Throw '*needs -WorkloadRunnerSha256*'
        { Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true -WorkloadRunnerSha256 $sha -WorkloadRunnerChunkCount 3 } | Should -Throw '*needs -BootstrapBundleSha256*'
    }

    It 'passes the activity profile from the configuration, baseline by default' {
        (Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true).parameters.activityProfile.value | Should -Be 'baseline'
        $custom = $config.Clone()
        $custom['activityProfile'] = 'incident:locking-blocking'
        (Get-DemoDeploymentParameter -Config $custom -NetworkMode private -T3UseFreeLimit $true).parameters.activityProfile.value | Should -Be 'incident:locking-blocking'
    }

    It 'sets the profile at boot only when activityProfileOnBoot is true (R183)' {
        (Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true).parameters.activityProfileOnBoot.value | Should -BeFalse
        $custom = $config.Clone()
        $custom['activityProfileOnBoot'] = $true
        (Get-DemoDeploymentParameter -Config $custom -NetworkMode private -T3UseFreeLimit $true).parameters.activityProfileOnBoot.value | Should -BeTrue
    }

    It 'matches a parameter the template declares' {
        $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($name in 'workloadRunnerSha256', 'workloadRunnerChunkCount', 'activityProfile', 'activityProfileOnBoot') {
            $template.parameters.Keys | Should -Contain $name
        }
    }
}

Describe 'Runner settings in the configuration schema and the template' {
    BeforeAll {
        $schema = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/environment.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $templateText = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw
        $template = $templateText | ConvertFrom-Json -AsHashtable
    }

    It 'accepts the runner''s activity profiles, baseline by default' {
        $property = $schema.properties.activityProfile
        $property.default | Should -Be 'baseline'
        foreach ($valid in 'off', 'baseline', 'business-day', 'incident:locking-blocking', 'incident:cpu-pressure') {
            $valid | Should -MatchExactly $property.pattern
        }
        foreach ($invalid in 'Baseline', 'fast', 'incident:', 'incident:Locking', 'baseline; drop') {
            $invalid | Should -Not -MatchExactly $property.pattern
        }
        (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json).activityProfile | Should -Be 'baseline'
    }

    It 'doesn''t set the profile at boot by default, so a VM that starts can''t keep T3 awake on its own' {
        $schema.properties.activityProfileOnBoot.type | Should -Be 'boolean'
        $schema.properties.activityProfileOnBoot.default | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json).activityProfileOnBoot | Should -BeFalse
        $template.parameters.activityProfileOnBoot.defaultValue | Should -BeFalse
        $templateText | Should -Match ([regex]::Escape('"profileOnBoot": "[parameters(''activityProfileOnBoot'')]"'))
    }

    It 'bounds the template parameters like the runner does' {
        $template.parameters.activityProfile.defaultValue | Should -Be 'baseline'
        $template.parameters.workloadRunnerSha256.defaultValue | Should -Be ''
        $template.parameters.workloadRunnerSha256.maxLength | Should -Be 64
        $template.parameters.workloadRunnerChunkCount.maxValue | Should -Be 999
    }

    It 'gives both bootstraps the runner settings and the shutdown schedule, and T1 the T3 names' {
        $templateText | Should -Match ([regex]::Escape('"runnerSha256": "[toLower(parameters(''workloadRunnerSha256''))]"'))
        $templateText | Should -Match ([regex]::Escape('"workload": "[variables(''workloadSettings'')]"'))
        foreach ($key in 'runnerChunkCount', 'activityProfile', 'autoShutdownTime', 'autoShutdownTimeZone') {
            $templateText | Should -Match ('"workloadSettings": \{[^}]*"' + $key + '"')
        }
        $templateText | Should -Match ([regex]::Escape("createObject('role', 'SqlVm', 'dataDiskTier', variables('t1DataDiskTier'), 't3', createObject('serverName', reference('azuresql01').outputs.serverName.value, 'serverFqdn', reference('azuresql01').outputs.serverFqdn.value"))
    }
}

Describe 'Workload control through action Run Command' {
    BeforeAll {
        $config = New-TestConfig
        $script:resultLine = ''
    }

    BeforeEach {
        $script:azCalls = [System.Collections.Generic.List[object]]::new()
        $script:serverExists = $true
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $call = [pscustomobject]@{ Arguments = $ArgumentList; Script = '' }
            $script:azCalls.Add($call)
            if ($ArgumentList[0] -eq 'sql' -and $ArgumentList[2] -eq 'show') {
                if (-not $script:serverExists) {
                    return [pscustomobject]@{ ExitCode = 3; StdOut = ''; StdErr = 'ERROR: (ResourceNotFound) The Resource was not found.' }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = '{ "name": "azuresql01-abc123", "fullyQualifiedDomainName": "azuresql01-abc123.database.windows.net" }'; StdErr = '' }
            }
            if ($ArgumentList[0] -eq 'vm' -and $ArgumentList[1] -eq 'run-command') {
                $scriptArgument = $ArgumentList[[array]::IndexOf($ArgumentList, '--scripts') + 1]
                $call.Script = Get-Content -LiteralPath $scriptArgument.Substring(1) -Raw
                return (New-RunCommandResponse -Line $script:resultLine)
            }
            throw "Unexpected az call: $($ArgumentList -join ' ')"
        }
    }

    It 'enables T3 on T1 with the server''s FQDN in a Base64 request, and reports the VM''s result' {
        $script:resultLine = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"EnableT3","status":"Pass","message":"setup --target T3: Pass (3 check(s) passed). DbHubDemo-Workload was restarted and now hosts T1 and T3.","evidence":{"setup":"Pass","notAfter":"2026-10-20T19:00:00-07:00"}}'
        $result = Enable-DemoT3Workload -Config $config -DeploymentId 'abc123' -Confirm:$false

        $result.checkId | Should -Be 'WORKLOAD.T3.ENABLE'
        $result.status | Should -Be 'Pass'
        $result.target | Should -Be 'T3'
        $result.evidence.setup | Should -Be 'Pass'
        $result.evidence.server | Should -Be 'azuresql01-abc123'
        $result.evidence.operatorSeconds | Should -BeGreaterOrEqual 0
        $run = $script:azCalls | Where-Object { $_.Arguments[0] -eq 'vm' }
        $run.Arguments | Should -Contain 'sqlvm01'
        $run.Arguments | Should -Contain 'RunPowerShellScript'
        $run.Arguments | Should -Contain '11111111-2222-3333-4444-555555555555'
        $run.Script | Should -Match "-Action 'EnableT3'"
        $encoded = [regex]::Match($run.Script, "-RequestBase64 '([A-Za-z0-9+/=]+)'").Groups[1].Value
        $request = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $request.serverFqdn | Should -Be 'azuresql01-abc123.database.windows.net'
        $run.Script | Should -Match 'Invoke-DemoWorkloadControl\.ps1'
        $run.Script | Should -Not -Match '[^\x00-\x7F]'
    }

    It 'fails without a Run Command when T3 doesn''t exist' {
        $script:serverExists = $false
        $result = Enable-DemoT3Workload -Config $config -DeploymentId 'abc123' -Confirm:$false
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match "wasn't found"
        @($script:azCalls | Where-Object { $_.Arguments[0] -eq 'vm' }).Count | Should -Be 0
    }

    It 'passes the VM''s Fail through, with remediation' {
        $script:resultLine = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"EnableT3","status":"Fail","message":"setup --target T3 failed with exit code 1: Login failed for user","evidence":{}}'
        $result = Enable-DemoT3Workload -Config $config -DeploymentId 'abc123' -Confirm:$false
        $result.status | Should -Be 'Fail'
        $result.remediation | Should -Match 'Add-DemoT1ToT3AdminGroup'
    }

    It 'reports Fail when the VM prints no result line' {
        $script:resultLine = 'something else'
        $result = Enable-DemoT3Workload -Config $config -DeploymentId 'abc123' -Confirm:$false
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'no workload result'
    }

    It 'runs T1 and T3 commands on sqlvm01 and T2 commands through archost01' {
        $script:resultLine = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"Runner","status":"Pass","message":"ok","evidence":{"exitCode":0,"stdout":"[{\"checkId\":\"WORKLOAD.T2.STATUS.PROFILE\",\"status\":\"Pass\"}]","stderr":""}}'
        $t2 = Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'status', '--json' -Confirm:$false
        $t2.Status | Should -Be 'Pass'
        $t2.ExitCode | Should -Be 0
        $t2.Records.Count | Should -Be 1
        $t2.Records[0].checkId | Should -Be 'WORKLOAD.T2.STATUS.PROFILE'
        $t2.Result.checkId | Should -Be 'WORKLOAD.T2.COMMAND'
        ($script:azCalls | Where-Object { $_.Arguments[0] -eq 'vm' } | Select-Object -Last 1).Arguments | Should -Contain 'archost01'

        Invoke-DemoWorkloadCommand -Config $config -Target T3 -ArgumentList 'profile', 'set', '--name', 'off' -Confirm:$false | Out-Null
        $last = $script:azCalls | Where-Object { $_.Arguments[0] -eq 'vm' } | Select-Object -Last 1
        $last.Arguments | Should -Contain 'sqlvm01'
        $encoded = [regex]::Match($last.Script, "-RequestBase64 '([A-Za-z0-9+/=]+)'").Groups[1].Value
        $request = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $request.target | Should -Be 'T3'
        $request.arguments | Should -Be @('profile', 'set', '--name', 'off')
    }

    It 'takes a single JSON object, such as profile get''s, as one record' {
        # 'profile get --json' (Cli/CommandLine.cs) writes one object; a bracket in a string once made the record cut fail.
        $document = [ordered]@{
            target      = 'T1'
            name        = 'incident:blocking-chain'
            setBy       = 'demo-control'
            expiresAt   = '2026-10-26T23:00:00Z'
            parameters  = [ordered]@{ durationSeconds = 900; parameters = [ordered]@{ chainDepth = '4' } }
            description = 'incident:blocking-chain (active until 2026-10-26T23:00:00Z)'
            host        = [ordered]@{ status = 'Pass'; message = 'ok'; lane = [ordered]@{ state = 'Serving'; lastError = 'Execution Timeout Expired [poll 412]'; runningRuns = 1 } }
        } | ConvertTo-Json -Depth 8 -Compress
        $line = [ordered]@{ marker = 'DBHUBDEMO-WORKLOAD'; action = 'Runner'; status = 'Pass'; message = 'ok'; evidence = [ordered]@{ exitCode = 0; stdout = $document; stderr = '' } } | ConvertTo-Json -Depth 8 -Compress
        $script:resultLine = 'DBHUBDEMO-WORKLOAD ' + $line
        $read = Invoke-DemoWorkloadCommand -Config $config -Target T1 -ArgumentList 'profile', 'get', '--json' -Confirm:$false
        $read.Status | Should -Be 'Pass'
        @($read.Records).Count | Should -Be 1
        $read.Records[0].name | Should -Be 'incident:blocking-chain'
        $read.Records[0].host.lane.state | Should -Be 'Serving'
    }

    It 'reads the runner''s records from an array, one object, or text around them, and nothing from a cut document' {
        InModuleScope -ModuleName DbHubDemo {
            $array = @(ConvertFrom-DemoRunnerRecord -StdOut '[{"checkId":"WORKLOAD.T1.RESET.STOP","status":"Pass"},{"checkId":"WORKLOAD.T1.RESET.SCRATCH","status":"Pass"}]')
            $array.Count | Should -Be 2
            $array[1].checkId | Should -Be 'WORKLOAD.T1.RESET.SCRATCH'
            $object = @(ConvertFrom-DemoRunnerRecord -StdOut ('{"target":"T2","runs":[{"runId":"r1"},{"runId":"r2"}],"host":{"status":"Pass"}}' + "`n"))
            $object.Count | Should -Be 1
            @($object[0].runs).Count | Should -Be 2
            $noisy = @(ConvertFrom-DemoRunnerRecord -StdOut "[info] reading the profile`n{`"name`":`"off`"}")
            $noisy.Count | Should -Be 1
            $noisy[0].name | Should -Be 'off'
            @(ConvertFrom-DemoRunnerRecord -StdOut '"stopRequests":[],"host":{"status":"Pass"}}').Count | Should -Be 0
            @(ConvertFrom-DemoRunnerRecord -StdOut '').Count | Should -Be 0
            @(ConvertFrom-DemoRunnerRecord -StdOut 'T1: off (no activity) [file]').Count | Should -Be 0
            @(ConvertFrom-DemoRunnerRecord -StdOut '[]').Count | Should -Be 0
        }
    }

    It 'refuses --target in the arguments and arguments with line breaks' {
        { Invoke-DemoWorkloadCommand -Config $config -Target T1 -ArgumentList 'status', '--target', 'T2' -Confirm:$false } | Should -Throw '*-Target*'
        { Invoke-DemoWorkloadCommand -Config $config -Target T1 -ArgumentList "status`nwhoami" -Confirm:$false } | Should -Throw '*line break*'
        @($script:azCalls).Count | Should -Be 0
    }

    It 'retries a busy Run Command' {
        $script:busy = 1
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            if ($script:busy -gt 0) {
                $script:busy--
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (Conflict) Run command extension execution is in progress.' }
            }
            New-RunCommandResponse -Line 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"Runner","status":"Warning","message":"warn","evidence":{"exitCode":0,"stdout":"","stderr":""}}'
        }
        (Invoke-DemoWorkloadCommand -Config $config -Target T1 -ArgumentList 'status' -Confirm:$false).Status | Should -Be 'Warning'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 2 -Exactly
    }
}

Describe 'Get-DemoWorkloadControlScript' {
    It 'embeds only a validated action and a Base64 request' {
        $script = & (Get-Module -Name DbHubDemo) { Get-DemoWorkloadControlScript -Action 'Runner' -Request @{ target = 'T1'; arguments = @('status', "it's"); timeoutSeconds = 60 } }
        $script | Should -Match "-Action 'Runner' -RequestBase64 '[A-Za-z0-9+/=]+'"
        $script | Should -Not -Match "it's"
        $script | Should -Not -Match '__ACTION__|__REQUEST__'
        { & (Get-Module -Name DbHubDemo) { Get-DemoWorkloadControlScript -Action 'Shell' -Request @{} } } | Should -Throw
    }

    It 'parses as PowerShell' {
        $script = & (Get-Module -Name DbHubDemo) { Get-DemoWorkloadControlScript -Action 'StopGuest' -Request @{ timeoutMinutes = 10 } }
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}
