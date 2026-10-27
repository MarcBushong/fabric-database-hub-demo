BeforeDiscovery {
    $onWindows = $IsWindows -and $null -ne (Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $loaderPath = Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoBootstrapLoader.ps1'
    # Dot-sourcing defines the loader's functions without running it.
    . $loaderPath
    $script:LoaderConsole = $false
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

    function New-TestBundle {
        # A real zip with the role's state machine script, built on the fly.
        param([string] $Role = 'SqlVm')
        $source = Join-Path -Path $TestDrive -ChildPath ('src-' + [guid]::NewGuid().ToString('N'))
        $scriptName = if ($Role -eq 'ArcHost') { 'Invoke-HostBootstrap.ps1' } else { 'Invoke-SqlVmBootstrap.ps1' }
        New-Item -ItemType Directory -Path (Join-Path -Path $source -ChildPath 'vm/bootstrap') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $source -ChildPath "vm/bootstrap/$scriptName") -Value ('# state machine ' + [guid]::NewGuid())
        Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'bundle-manifest.json') -Value '{"schemaVersion":1}'
        $zip = Join-Path -Path $TestDrive -ChildPath ('bundle-' + [guid]::NewGuid().ToString('N') + '.zip')
        [System.IO.Compression.ZipFile]::CreateFromDirectory($source, $zip)
        [pscustomobject]@{ Zip = $zip; Sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() }
    }

    function Write-TestChunk {
        # What the chunk Run Commands leave on the VM: chunk-NNN.bin plus chunk-NNN.sha256.
        param([string] $Root, [string] $ZipPath, [string] $Sha256, [int] $Count)
        $bytes = [System.IO.File]::ReadAllBytes($ZipPath)
        $folder = Join-Path -Path $Root -ChildPath ('downloads/' + $Sha256.Substring(0, 12))
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $size = [int][System.Math]::Ceiling($bytes.Length / [double]$Count)
        for ($i = 0; $i -lt $Count; $i++) {
            $length = [System.Math]::Min($size, $bytes.Length - $i * $size)
            $chunk = [byte[]]::new($length)
            [System.Array]::Copy($bytes, $i * $size, $chunk, 0, $length)
            $name = 'chunk-{0:d3}' -f ($i + 1)
            [System.IO.File]::WriteAllBytes((Join-Path -Path $folder -ChildPath "$name.bin"), $chunk)
            [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath "$name.sha256"), [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($chunk)).ToLowerInvariant())
        }
        return $folder
    }

    function ConvertTo-TestBase64([string] $Value) {
        [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value))
    }
}

Describe 'Invoke-DemoBootstrapLoader' {
    BeforeEach {
        $script:root = Join-Path -Path $TestDrive -ChildPath ('root-' + [guid]::NewGuid().ToString('N'))
        Mock -CommandName Protect-DemoLoaderFolder -MockWith { }
        Mock -CommandName Register-DemoLoaderTask -MockWith { }
        Mock -CommandName Invoke-DemoLoaderTask -MockWith { }
    }

    It 'assembles the chunks, verifies them, extracts the bundle, writes settings.json, and registers the task' {
        $bundle = New-TestBundle -Role 'ArcHost'
        $chunkFolder = Write-TestChunk -Root $script:root -ZipPath $bundle.Zip -Sha256 $bundle.Sha256 -Count 3
        $settings = '{"t2SqlInstallMode":"PaygWizard","dataDiskTier":"None","guest":{"name":"arcsql01","vcpus":2}}'

        $result = Invoke-DemoBootstrapLoader -BundleSha256 $bundle.Sha256.ToUpperInvariant() -ChunkCount '3' -Role 'ArcHost' -SettingsJson (ConvertTo-TestBase64 $settings) -Root $script:root

        $result.ScriptPath | Should -Match 'Invoke-HostBootstrap\.ps1$'
        Test-Path -LiteralPath $result.ScriptPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $result.BundlePath -ChildPath '.complete') | Should -BeTrue
        $written = Get-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'settings.json') -Raw | ConvertFrom-Json
        $written.role | Should -Be 'ArcHost'
        $written.t2SqlInstallMode | Should -Be 'PaygWizard'
        $written.dataDiskTier | Should -Be 'None'
        $written.guest.vcpus | Should -Be 2
        $written.bundleSha256 | Should -Be $bundle.Sha256
        $written.generation | Should -Match ('^{0}-\d{{14}}$' -f $bundle.Sha256.Substring(0, 12))
        # The chunks, the joined file, and the zip are gone once the bundle is installed.
        Test-Path -LiteralPath $chunkFolder | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'downloads') -File).Count | Should -Be 0
        Should -Invoke -CommandName Register-DemoLoaderTask -Times 1 -Exactly -ParameterFilter { $ScriptPath -eq $result.ScriptPath -and $StateRoot -eq $script:root }
        Should -Invoke -CommandName Invoke-DemoLoaderTask -Times 1 -Exactly
    }

    It 'fails closed when the joined bundle does not match its SHA-256: the joined file and the chunks are deleted' {
        $bundle = New-TestBundle
        $other = ('0' * 12) + $bundle.Sha256.Substring(12)
        $chunkFolder = Write-TestChunk -Root $script:root -ZipPath $bundle.Zip -Sha256 $other -Count 2

        { Invoke-DemoBootstrapLoader -BundleSha256 $other -ChunkCount '2' -Role 'SqlVm' -SettingsJson '{}' -Root $script:root } | Should -Throw '*SHA-256 mismatch*nothing was installed*'

        Test-Path -LiteralPath $chunkFolder | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'downloads') -Recurse -File).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'bundle') -ErrorAction SilentlyContinue).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path -Path $script:root -ChildPath 'settings.json') | Should -BeFalse
        Should -Invoke -CommandName Register-DemoLoaderTask -Times 0
        Should -Invoke -CommandName Invoke-DemoLoaderTask -Times 0
    }

    It 'names a missing chunk and installs nothing' {
        $bundle = New-TestBundle
        $chunkFolder = Write-TestChunk -Root $script:root -ZipPath $bundle.Zip -Sha256 $bundle.Sha256 -Count 3
        Remove-Item -LiteralPath (Join-Path -Path $chunkFolder -ChildPath 'chunk-002.bin')

        { Invoke-DemoBootstrapLoader -BundleSha256 $bundle.Sha256 -ChunkCount '4' -Role 'SqlVm' -SettingsJson '' -Root $script:root } | Should -Throw '*missing chunk(s) 2, 4*Send-DemoBootstrapBundle*'

        Test-Path -LiteralPath (Join-Path -Path $chunkFolder -ChildPath 'chunk-001.bin') | Should -BeTrue
        Should -Invoke -CommandName Register-DemoLoaderTask -Times 0
    }

    It 'names a chunk that fails its own SHA-256 check' {
        $bundle = New-TestBundle
        $chunkFolder = Write-TestChunk -Root $script:root -ZipPath $bundle.Zip -Sha256 $bundle.Sha256 -Count 2
        [System.IO.File]::WriteAllBytes((Join-Path -Path $chunkFolder -ChildPath 'chunk-002.bin'), [byte[]](1, 2, 3))

        { Invoke-DemoBootstrapLoader -BundleSha256 $bundle.Sha256 -ChunkCount '2' -Role 'SqlVm' -SettingsJson '' -Root $script:root } | Should -Throw '*chunk(s) 2 failed their SHA-256 check*'
    }

    It 'rejects an unknown role, a malformed SHA-256, and a bad chunk count' {
        { Invoke-DemoBootstrapLoader -BundleSha256 ('a' * 64) -ChunkCount '1' -Role 'Other' -SettingsJson '{}' -Root $script:root } | Should -Throw '*Role*'
        { Invoke-DemoBootstrapLoader -BundleSha256 'abc' -ChunkCount '1' -Role 'SqlVm' -SettingsJson '{}' -Root $script:root } | Should -Throw '*64 hexadecimal*'
        foreach ($count in '', '0', '-1', 'two') {
            { Invoke-DemoBootstrapLoader -BundleSha256 ('a' * 64) -ChunkCount $count -Role 'SqlVm' -SettingsJson '{}' -Root $script:root } | Should -Throw '*ChunkCount*'
        }
    }

    It 'skips assembly when the same bundle is already installed, and still re-registers the task' {
        $bundle = New-TestBundle
        Write-TestChunk -Root $script:root -ZipPath $bundle.Zip -Sha256 $bundle.Sha256 -Count 2 | Out-Null
        Invoke-DemoBootstrapLoader -BundleSha256 $bundle.Sha256 -ChunkCount '2' -Role 'SqlVm' -SettingsJson '{}' -Root $script:root | Out-Null
        Mock -CommandName Join-DemoLoaderChunk -MockWith { throw 'must not join again' }

        # The chunks are gone after the first run; the second run doesn't need them.
        Invoke-DemoBootstrapLoader -BundleSha256 $bundle.Sha256 -ChunkCount '2' -Role 'SqlVm' -SettingsJson '{}' -Root $script:root | Out-Null

        Should -Invoke -CommandName Join-DemoLoaderChunk -Times 0
        Should -Invoke -CommandName Register-DemoLoaderTask -Times 2 -Exactly
    }
}

Describe 'Loader file' {
    It 'stays well under the 96 KB loadTextContent limit' {
        (Get-Item -LiteralPath $loaderPath).Length | Should -BeLessThan (96KB - 16KB)
    }

    It 'is what bootstrap.bicep embeds, with the chunk parameters' {
        $bicep = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/bootstrap.bicep') -Raw
        $bicep | Should -Match "loadTextContent\('\.\./\.\./vm/bootstrap/Invoke-DemoBootstrapLoader\.ps1'\)"
        foreach ($name in 'BundleSha256', 'ChunkCount', 'Role', 'SettingsJson') {
            $bicep | Should -Match ("name: '{0}'" -f $name)
        }
        $bicep | Should -Not -Match 'protectedParameters|BundleUrl'
    }

    It 'has no download, URL, or SAS code left, and never uses Expand-Archive' {
        $text = Get-Content -LiteralPath $loaderPath -Raw
        $text | Should -Not -Match 'WebClient|HttpWebRequest|Invoke-WebRequest|BundleUrl|sig='
        $text | Should -Not -Match '(?m)^\s*Expand-Archive'
        $text | Should -Match 'ZipFile\]::ExtractToDirectory'
    }

    It 'decodes Base64 settings and passes plain JSON through' {
        ConvertFrom-DemoLoaderValue -Value (ConvertTo-TestBase64 '{"a":1}') | Should -Be '{"a":1}'
        ConvertFrom-DemoLoaderValue -Value '{"a":1}' | Should -Be '{"a":1}'
        ConvertFrom-DemoLoaderValue -Value '' | Should -Be ''
        { ConvertFrom-DemoLoaderValue -Value 'not base64 !' } | Should -Throw '*neither JSON nor Base64*'
    }
}

Describe 'Loader under Windows PowerShell 5.1' -Skip:(-not $onWindows) {
    # Regression test for the critical review finding: the old loader passed bundle-<sha12>.zip.partial to
    # Expand-Archive, which Windows PowerShell 5.1 rejects for any extension other than .zip, so no VM
    # would have bootstrapped. These run the real functions in powershell.exe.
    BeforeAll {
        function Invoke-WindowsPowerShell([string] $Command) {
            $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $Command 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output) -join "`n") }
        }
    }

    It 'assembles, verifies, and extracts a real zip from its chunks' {
        $root = Join-Path -Path $TestDrive -ChildPath 'ps51-ok'
        $bundle = New-TestBundle -Role 'SqlVm'
        $chunkFolder = Write-TestChunk -Root $root -ZipPath $bundle.Zip -Sha256 $bundle.Sha256 -Count 3
        $command = ". '{0}'; `$script:LoaderConsole = `$false; `$path = Install-DemoLoaderBundle -Root '{1}' -BundleSha256 '{2}' -ChunkCount 3; 'PS ' + `$PSVersionTable.PSVersion.Major; 'BUNDLE ' + `$path" -f $loaderPath, $root, $bundle.Sha256

        $run = Invoke-WindowsPowerShell -Command $command

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'PS 5'
        $bundlePath = Join-Path -Path $root -ChildPath ('bundle/' + $bundle.Sha256.Substring(0, 12))
        Test-Path -LiteralPath (Join-Path -Path $bundlePath -ChildPath '.complete') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $bundlePath -ChildPath 'vm/bootstrap/Invoke-SqlVmBootstrap.ps1') | Should -BeTrue
        Test-Path -LiteralPath $chunkFolder | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'downloads') -File).Count | Should -Be 0
    }

    It 'fails closed on a SHA-256 mismatch and deletes the joined file and the chunks' {
        $root = Join-Path -Path $TestDrive -ChildPath 'ps51-bad'
        $bundle = New-TestBundle
        $other = ('f' * 12) + $bundle.Sha256.Substring(12)
        $chunkFolder = Write-TestChunk -Root $root -ZipPath $bundle.Zip -Sha256 $other -Count 2
        $command = ". '{0}'; `$script:LoaderConsole = `$false; try {{ Install-DemoLoaderBundle -Root '{1}' -BundleSha256 '{2}' -ChunkCount 2 | Out-Null; exit 0 }} catch {{ [Console]::Out.WriteLine(`$_.Exception.Message); exit 3 }}" -f $loaderPath, $root, $other

        $run = Invoke-WindowsPowerShell -Command $command

        $run.ExitCode | Should -Be 3
        $run.Output | Should -Match 'SHA-256 mismatch'
        Test-Path -LiteralPath $chunkFolder | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'downloads') -Recurse -File).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 'bundle') | Should -BeFalse
    }

    It 'installs the repository bundle end to end from the generated chunk scripts' {
        Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
        try {
            $root = Join-Path -Path $TestDrive -ChildPath 'ps51-e2e'
            # The root exists already, so the chunk scripts don't restrict its ACL to SYSTEM and Administrators.
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $bundle = New-DemoBootstrapBundle -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'e2e-bundle')
            $chunks = @(New-DemoBootstrapChunk -Path $bundle.Path -ChunkSizeKiB 24 -Root $root)
            $chunks.Count | Should -BeGreaterThan 1
            foreach ($chunk in $chunks) {
                $scriptPath = Join-Path -Path $TestDrive -ChildPath ('{0}.ps1' -f $chunk.Name)
                [System.IO.File]::WriteAllText($scriptPath, $chunk.Script, [System.Text.Encoding]::ASCII)
                $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptPath 2>&1
                $LASTEXITCODE | Should -Be 0 -Because (@($output) -join ' ')
            }
            $run = Invoke-WindowsPowerShell -Command (". '{0}'; `$script:LoaderConsole = `$false; Install-DemoLoaderBundle -Root '{1}' -BundleSha256 '{2}' -ChunkCount {3}" -f $loaderPath, $root, $bundle.Sha256, $chunks.Count)
            $run.ExitCode | Should -Be 0 -Because $run.Output
            $installed = Join-Path -Path $root -ChildPath ('bundle/' + $bundle.Sha256.Substring(0, 12))
            Test-Path -LiteralPath (Join-Path -Path $installed -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path -Path $installed -ChildPath 'bundle-manifest.json') | Should -BeTrue
        }
        finally {
            Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
        }
    }
}
