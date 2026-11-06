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
        $script:order = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Protect-DemoLoaderFolder -MockWith { }
        Mock -CommandName Register-DemoLoaderTask -MockWith { $script:order.Add('register') }
        Mock -CommandName Invoke-DemoLoaderTask -MockWith { $script:order.Add('start') }
        # Its own tests are below; here no earlier bundle's run is going.
        Mock -CommandName Stop-DemoLoaderEarlierRun -MockWith { $script:order.Add('takeover'); [pscustomobject]@{ Stopped = @(); Children = @(); Same = @(); Ready = $true; Text = '' } }
        Mock -CommandName Remove-DemoLoaderOldBundle -MockWith { $script:order.Add('prune') }
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
        # The task points at this bundle before an earlier bundle's run is stopped, and starts once it has (2026-11-06).
        $script:order | Should -Be @('register', 'takeover', 'prune', 'start')
        Should -Invoke -CommandName Stop-DemoLoaderEarlierRun -Times 1 -Exactly -ParameterFilter { $Root -eq $script:root -and $BundleSha256 -eq $bundle.Sha256 }
        $result.TookOver | Should -BeNullOrEmpty
    }

    It 'returns what it stopped, for the Run Command''s output (live finding, 2026-11-06)' {
        $bundle = New-TestBundle
        Write-TestChunk -Root $script:root -ZipPath $bundle.Zip -Sha256 $bundle.Sha256 -Count 1 | Out-Null
        Mock -CommandName Stop-DemoLoaderEarlierRun -MockWith { [pscustomobject]@{ Stopped = @(1); Children = @(); Same = @(); Ready = $true; Text = 'stopped bundle aaaaaaaaaaaa''s bootstrap run, which was still going (process 4242); bundle bbbbbbbbbbbb''s run starts now.' } }
        $result = Invoke-DemoBootstrapLoader -BundleSha256 $bundle.Sha256 -ChunkCount '1' -Role 'SqlVm' -SettingsJson '{}' -Root $script:root
        $result.TookOver | Should -Match '^stopped bundle aaaaaaaaaaaa''s bootstrap run'
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

Describe 'The loader takes over from an earlier bundle''s bootstrap run (live finding, 2026-11-06)' {
    # Live: a fix reached archost01 while its bootstrap run of the old bundle was in a 34 GiB download. The task ignores a
    # new instance while one runs (MultipleInstances IgnoreNew) and ends one only after 6 hours, and registering it again
    # doesn't stop the one that runs, so the new bundle waited until its powershell.exe was stopped by hand.
    BeforeAll {
        # A stub with the parameters the loader uses, so Pester can mock this Windows cmdlet on Linux too.
        if (-not (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue)) {
            New-Item -Path 'function:global:Get-CimInstance' -Value ([scriptblock]::Create('[CmdletBinding()] param([string] $ClassName, [string] $Filter)')) | Out-Null
        }
        $script:oldSha = 'a' * 12
        $script:newSha = 'c' * 64

        function New-TestProcess {
            param([int] $Id, [int] $Parent = 4, [string] $Name = 'powershell.exe', [string] $CommandLine = '', [datetime] $Created = [datetime]'2026-11-06T14:00:00Z')
            [pscustomobject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name; CommandLine = $CommandLine; CreationDate = $Created }
        }

        function Get-TestBootstrapLine {
            param([string] $Root, [string] $Sha12, [string] $Script = 'Invoke-HostBootstrap.ps1')
            '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Root "{1}"' -f (Join-Path -Path $Root -ChildPath ('bundle/{0}/vm/bootstrap/{1}' -f $Sha12, $Script)), $Root
        }
    }

    BeforeEach {
        $script:root = Join-Path -Path $TestDrive -ChildPath ('state-' + [guid]::NewGuid().ToString('N'))
        $script:stopped = [System.Collections.Generic.List[int]]::new()
        $script:logged = [System.Collections.Generic.List[string]]::new()
        $script:alive = $false
        # A mock doesn't get the function's parameter defaults, so a call without -Level is an Info line.
        Mock -CommandName Write-DemoLoaderLog -MockWith { $script:logged.Add(('{0} {1}' -f $(if ($Level) { $Level } else { 'Info' }), $Message)) }
        Mock -CommandName Stop-DemoLoaderProcess -MockWith { $script:stopped.Add($ProcessId); $true }
        Mock -CommandName Test-DemoLoaderProcessMatch -MockWith { $script:alive }
        Mock -CommandName Test-DemoLoaderLockFree -MockWith { $true }
        Mock -CommandName Test-DemoLoaderTaskIdle -MockWith { $true }
    }

    It 'finds the bootstrap runs under this state folder by their command line, with their bundle' {
        $processes = @(
            (New-TestProcess -Id 100 -CommandLine ('powershell.exe ' + (Get-TestBootstrapLine -Root $script:root -Sha12 $script:oldSha)))
            (New-TestProcess -Id 101 -CommandLine ('powershell.exe ' + (Get-TestBootstrapLine -Root $script:root -Sha12 ('b' * 12) -Script 'Invoke-SqlVmBootstrap.ps1')))
            (New-TestProcess -Id 102 -CommandLine ('powershell.exe ' + (Get-TestBootstrapLine -Root (Join-Path -Path $TestDrive -ChildPath 'other') -Sha12 $script:oldSha)))
            (New-TestProcess -Id 103 -Name 'notepad.exe' -CommandLine ('notepad.exe ' + (Join-Path -Path $script:root -ChildPath ('bundle/{0}/vm/bootstrap/Invoke-HostBootstrap.ps1' -f $script:oldSha))))
            (New-TestProcess -Id 104 -CommandLine ('powershell.exe -File "{0}"' -f (Join-Path -Path $script:root -ChildPath ('bundle/{0}/vm/bootstrap/Invoke-DemoWorkloadControl.ps1' -f $script:oldSha))))
            (New-TestProcess -Id 105 -CommandLine $null)
        )
        $runs = @(Get-DemoLoaderBootstrapRun -Process $processes -Root $script:root)
        @($runs | ForEach-Object { $_.ProcessId }) | Should -Be @(100, 101)
        $runs[0].Bundle | Should -Be $script:oldSha
        $runs[0].Script | Should -Be 'Invoke-HostBootstrap.ps1'
        $runs[1].Script | Should -Be 'Invoke-SqlVmBootstrap.ps1'
    }

    It 'finds what a run started, and what that started, but never a process older than its parent' {
        $start = [datetime]'2026-11-06T14:00:00Z'
        $processes = @(
            (New-TestProcess -Id 100 -Created $start)
            (New-TestProcess -Id 200 -Parent 100 -Name 'conhost.exe' -Created $start.AddSeconds(1))
            (New-TestProcess -Id 201 -Parent 100 -Name 'setup.exe' -Created $start.AddMinutes(3))
            (New-TestProcess -Id 300 -Parent 201 -Name 'ScenarioEngine.exe' -Created $start.AddMinutes(4))
            # It has the run's ID as its parent, but it's older: its parent was another process that had that ID before.
            (New-TestProcess -Id 400 -Parent 100 -Name 'svchost.exe' -Created $start.AddDays(-1))
            (New-TestProcess -Id 500 -Parent 4 -Name 'other.exe' -Created $start.AddMinutes(5))
        )
        $tree = @(Get-DemoLoaderProcessTree -Process $processes -Parent @($processes[0]))
        @($tree | ForEach-Object { $_.ProcessId } | Sort-Object) | Should -Be @(200, 201, 300)
        @(Get-DemoLoaderProcessTree -Process $processes -Parent @()).Count | Should -Be 0
    }

    It 'stops an earlier bundle''s run first, then what it started, waits for the lock, and says so' {
        $script:processes = @(
            (New-TestProcess -Id 100 -CommandLine ('powershell.exe ' + (Get-TestBootstrapLine -Root $script:root -Sha12 $script:oldSha)))
            (New-TestProcess -Id 200 -Parent 100 -Name 'conhost.exe' -Created ([datetime]'2026-11-06T14:00:01Z'))
            (New-TestProcess -Id 999 -Name 'svchost.exe')
        )
        Mock -CommandName Get-CimInstance -MockWith { $script:processes }
        $result = Stop-DemoLoaderEarlierRun -Root $script:root -BundleSha256 $script:newSha -TimeoutSeconds 5
        @($script:stopped) | Should -Be @(100, 200)
        $result.Ready | Should -BeTrue
        @($result.Stopped).Count | Should -Be 1
        @($result.Children).Count | Should -Be 1
        $result.Text | Should -Be ('stopped bundle {0}''s bootstrap run, which was still going (process 100), and the 1 process(es) it started (conhost.exe); bundle {1}''s run starts now.' -f $script:oldSha, $script:newSha.Substring(0, 12))
        ($script:logged -join "`n") | Should -Match ('Info Bundle {0}''s bootstrap run is still going \(process 100\): it''s stopped, and the 1 process\(es\) it started \(conhost\.exe\), so bundle {1}''s run starts now instead of after it' -f $script:oldSha, $script:newSha.Substring(0, 12))
        ($script:logged -join "`n") | Should -Match 'Its steps are resumable: the new run checks each one again \(ADR 0003\)'
        Should -Invoke -CommandName Test-DemoLoaderLockFree -ParameterFilter { $Path -eq (Join-Path -Path $script:root -ChildPath 'bootstrap.lock') }
    }

    It 'leaves a run of the same bundle alone, and does nothing when no run is going' {
        $script:processes = @(New-TestProcess -Id 100 -CommandLine ('powershell.exe ' + (Get-TestBootstrapLine -Root $script:root -Sha12 $script:newSha.Substring(0, 12))))
        Mock -CommandName Get-CimInstance -MockWith { $script:processes }
        $result = Stop-DemoLoaderEarlierRun -Root $script:root -BundleSha256 $script:newSha -TimeoutSeconds 5
        $script:stopped.Count | Should -Be 0
        @($result.Same).Count | Should -Be 1
        $result.Text | Should -BeNullOrEmpty
        ($script:logged -join "`n") | Should -Match 'A bootstrap run of bundle c{12} is in progress \(process 100\); it goes on, and its next pass takes the new generation\.'

        $script:processes = @(New-TestProcess -Id 999 -Name 'svchost.exe')
        $script:logged.Clear()
        $result = Stop-DemoLoaderEarlierRun -Root $script:root -BundleSha256 $script:newSha -TimeoutSeconds 5
        $script:stopped.Count | Should -Be 0
        $result.Ready | Should -BeTrue
        $script:logged.Count | Should -Be 0
    }

    It 'warns, stops nothing, and lets the task''s next pass start the run, when the processes can''t be read' {
        Mock -CommandName Get-CimInstance -MockWith { throw 'Invalid class' }
        $result = Stop-DemoLoaderEarlierRun -Root $script:root -BundleSha256 $script:newSha -TimeoutSeconds 5
        $script:stopped.Count | Should -Be 0
        $result.Text | Should -BeNullOrEmpty
        ($script:logged -join "`n") | Should -Match '^Warning The running processes couldn''t be read \(Invalid class\)'
    }

    It 'says the new run starts at the task''s next pass when the earlier one hasn''t ended in time' {
        $script:processes = @(New-TestProcess -Id 100 -CommandLine ('powershell.exe ' + (Get-TestBootstrapLine -Root $script:root -Sha12 $script:oldSha)))
        Mock -CommandName Get-CimInstance -MockWith { $script:processes }
        $script:alive = $true
        $result = Stop-DemoLoaderEarlierRun -Root $script:root -BundleSha256 $script:newSha -TimeoutSeconds 1
        $result.Ready | Should -BeFalse
        $result.Text | Should -Match 'but after 1 seconds the run hasn''t ended, the bootstrap lock is still held, or the task still reports a run; bundle c{12}''s run starts at the task''s next pass once it has\.$'
        ($script:logged -join "`n") | Should -Match 'Warning Bundle a{12}''s run was stopped, but after 1 seconds'
    }

    It 'counts the new bundle''s run that the task''s own trigger started as ready' {
        $script:processes = @(New-TestProcess -Id 100 -CommandLine ('powershell.exe ' + (Get-TestBootstrapLine -Root $script:root -Sha12 $script:oldSha)))
        Mock -CommandName Get-CimInstance -MockWith { $script:processes }
        # Once the earlier run is gone, the 5-minute trigger starts the new bundle's run, which holds the lock.
        Mock -CommandName Stop-DemoLoaderProcess -MockWith {
            $script:stopped.Add($ProcessId)
            $script:processes = @(New-TestProcess -Id 101 -CommandLine ('powershell.exe ' + (Get-TestBootstrapLine -Root $script:root -Sha12 $script:newSha.Substring(0, 12))))
            $true
        }
        Mock -CommandName Test-DemoLoaderLockFree -MockWith { $false }
        $result = Stop-DemoLoaderEarlierRun -Root $script:root -BundleSha256 $script:newSha -TimeoutSeconds 5
        $result.Ready | Should -BeTrue
        ($script:logged -join "`n") | Should -Match 'the task''s own trigger has already started bundle c{12}''s run'
    }
}

Describe 'The loader''s bootstrap lock check' {
    It 'sees the lock as free when no run holds it, and as held while one does' {
        $lock = Join-Path -Path $TestDrive -ChildPath ('lock-' + [guid]::NewGuid().ToString('N'))
        Test-DemoLoaderLockFree -Path $lock | Should -BeTrue
        [System.IO.File]::WriteAllText($lock, 'pid=1')
        Test-DemoLoaderLockFree -Path $lock | Should -BeTrue
        $held = [System.IO.FileStream]::new($lock, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            Test-DemoLoaderLockFree -Path $lock | Should -BeFalse
        }
        finally {
            $held.Dispose()
        }
        Test-DemoLoaderLockFree -Path $lock | Should -BeTrue
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

    It 'stops a real earlier bundle''s run and the process it started, frees its lock, and leaves a run of the same bundle alone (2026-11-06)' {
        $root = Join-Path -Path $TestDrive -ChildPath ('ps51-takeover-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        # A stand-in for a role's state machine at the path the task runs it from: with -TakeLock it holds bootstrap.lock as
        # Enter-DemoVmLock does; it starts one process and waits, as a run in a long download or SQL Server setup does.
        $standIn = @'
param([string] $Root, [string] $Marker, [switch] $TakeLock)
if ($TakeLock) {
    $lock = New-Object -TypeName 'System.IO.FileStream' -ArgumentList @((Join-Path -Path $Root -ChildPath 'bootstrap.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}
$child = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', ('Start-Sleep -Seconds 240 # {0}' -f $Marker)) -WindowStyle Hidden -PassThru
[System.IO.File]::WriteAllText((Join-Path -Path $Root -ChildPath ($Marker + '.child')), [string]$child.Id)
Start-Sleep -Seconds 240
'@
        $started = [System.Collections.Generic.List[int]]::new()
        $startStandIn = {
            param([string] $Sha12, [string] $Marker, [switch] $TakeLock)
            $folder = Join-Path -Path $root -ChildPath ('bundle\{0}\vm\bootstrap' -f $Sha12)
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $scriptPath = Join-Path -Path $folder -ChildPath 'Invoke-HostBootstrap.ps1'
            [System.IO.File]::WriteAllText($scriptPath, $standIn, [System.Text.Encoding]::ASCII)
            $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $scriptPath), '-Root', ('"{0}"' -f $root), '-Marker', $Marker) + @(if ($TakeLock) { '-TakeLock' })
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
            $started.Add($process.Id)
            $markerPath = Join-Path -Path $root -ChildPath ($Marker + '.child')
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not (Test-Path -LiteralPath $markerPath) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 250
            }
            $child = [int](Get-Content -LiteralPath $markerPath -Raw)
            $started.Add($child)
            [pscustomobject]@{ Process = $process; ChildId = $child }
        }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            $old = & $startStandIn -Sha12 ('a' * 12) -Marker 'old' -TakeLock
            $command = ". '{0}'; `$script:LoaderConsole = `$false; `$r = Stop-DemoLoaderEarlierRun -Root '{1}' -BundleSha256 '{2}' -TimeoutSeconds 30; 'READY ' + `$r.Ready; 'STOPPED ' + ((@(`$r.Stopped) | ForEach-Object {{ `$_.ProcessId }}) -join ','); 'CHILDREN ' + @(`$r.Children).Count; 'TEXT ' + `$r.Text" -f $loaderPath, $root, ('c' * 64)

            $run = Invoke-WindowsPowerShell -Command $command

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $run.Output | Should -Match 'READY True'
            $run.Output | Should -Match ('STOPPED {0}' -f $old.Process.Id)
            $run.Output | Should -Match 'TEXT stopped bundle a{12}''s bootstrap run, which was still going'
            $old.Process.WaitForExit(10000) | Should -BeTrue
            { Get-Process -Id $old.ChildId -ErrorAction Stop } | Should -Throw -Because 'the process the run started goes with it'
            $lock = [System.IO.FileStream]::new((Join-Path -Path $root -ChildPath 'bootstrap.lock'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $lock.Dispose()

            $same = & $startStandIn -Sha12 ('c' * 12) -Marker 'same'
            $run = Invoke-WindowsPowerShell -Command $command
            $run.ExitCode | Should -Be 0 -Because $run.Output
            $run.Output | Should -Match '(?m)^STOPPED\s*$'
            $same.Process.HasExited | Should -BeFalse -Because 'a run of the same bundle goes on'
        }
        finally {
            foreach ($id in $started) {
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
