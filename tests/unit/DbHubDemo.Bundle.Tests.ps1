BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    Add-Type -AssemblyName 'System.IO.Compression'
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

    function New-FakeRepository {
        $root = Join-Path -Path $TestDrive -ChildPath ('repo-' + [guid]::NewGuid().ToString('N'))
        foreach ($folder in 'vm/bootstrap/lib', 'database/common', 'config') {
            New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath $folder) -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'vm/bootstrap/Invoke-DemoBootstrapLoader.ps1') -Value '# loader'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'vm/bootstrap/lib/Core.ps1') -Value '# core'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'vm/README.md') -Value '# not bundled'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'database/common/010-schema.sql') -Value 'SELECT 1;'
        Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Destination (Join-Path -Path $root -ChildPath 'config/versions.json')
        return $root
    }

    function Get-ZipEntryName([string] $Path) {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            return @($archive.Entries | ForEach-Object { $_.FullName })
        }
        finally {
            $archive.Dispose()
        }
    }

    function Read-ZipManifest([string] $Path) {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $reader = [System.IO.StreamReader]::new($archive.GetEntry('bundle-manifest.json').Open())
            try {
                return ($reader.ReadToEnd() | ConvertFrom-Json -AsHashtable)
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'New-DemoBootstrapBundle' {
    It 'builds the same zip, byte for byte, from the same content' {
        $fake = New-FakeRepository
        $first = New-DemoBootstrapBundle -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'a')
        (Get-Item -LiteralPath (Join-Path -Path $fake -ChildPath 'database/common/010-schema.sql')).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-5)
        $second = New-DemoBootstrapBundle -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'b')
        $second.Sha256 | Should -Be $first.Sha256
        $second.ContentSha256 | Should -Be $first.ContentSha256
        $first.Sha256 | Should -Match '^[0-9a-f]{64}$'
        $first.Sha256 | Should -Be (Get-FileHash -LiteralPath $first.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    It 'changes the hash and the file name when a file changes' {
        $fake = New-FakeRepository
        $before = New-DemoBootstrapBundle -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'c')
        Set-Content -LiteralPath (Join-Path -Path $fake -ChildPath 'database/common/010-schema.sql') -Value 'SELECT 2;'
        $after = New-DemoBootstrapBundle -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'd')
        $after.Sha256 | Should -Not -Be $before.Sha256
        $after.FileName | Should -Not -Be $before.FileName
    }

    It 'holds vm/ and database/ without Markdown, plus a manifest with file hashes and media pins' {
        $fake = New-FakeRepository
        $bundle = New-DemoBootstrapBundle -RepositoryRoot $fake -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'e')
        $bundle.FileName | Should -Match '^dbhub-bootstrap-\d+\.\d+\.\d+-[0-9a-f]{12}\.zip$'
        $bundle.FileCount | Should -Be 3
        $names = Get-ZipEntryName -Path $bundle.Path
        $names | Should -Be @('bundle-manifest.json', 'database/common/010-schema.sql', 'vm/bootstrap/Invoke-DemoBootstrapLoader.ps1', 'vm/bootstrap/lib/Core.ps1')
        $manifest = Read-ZipManifest -Path $bundle.Path
        $manifest.version | Should -Be $bundle.Version
        $manifest.contentSha256 | Should -Be $bundle.ContentSha256
        $manifest.files.Count | Should -Be 3
        ($manifest.files | Where-Object { $_.path -eq 'database/common/010-schema.sql' }).sha256 | Should -Be (Get-FileHash -LiteralPath (Join-Path -Path $fake -ChildPath 'database/common/010-schema.sql') -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest.media.Keys | Should -Contain 'windowsServer2022Eval'
        $manifest.media.Keys | Should -Contain 'sqlServer2022'
        $manifest.media.Keys | Should -Not -Contain 'note'
    }

    It 'bundles everything both state machines need from this repository' {
        $bundle = New-DemoBootstrapBundle -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'f')
        $names = Get-ZipEntryName -Path $bundle.Path
        foreach ($expected in @(
                'vm/bootstrap/Invoke-DemoBootstrapLoader.ps1', 'vm/bootstrap/Invoke-HostBootstrap.ps1', 'vm/bootstrap/Invoke-SqlVmBootstrap.ps1',
                'vm/bootstrap/DbHubDemo.Vm.psd1', 'vm/bootstrap/DbHubDemo.Vm.psm1', 'vm/hyperv-guest/unattend.template.xml',
                'vm/dsc/host.psd1', 'vm/dsc/guest.psd1', 'vm/dsc/sqlvm.psd1', 'database/common/010-schema.sql', 'database/common/020-seed.sql')) {
            $names | Should -Contain $expected
        }
        ($names | Where-Object { $_ -match '\\|\.md$' }) | Should -BeNullOrEmpty
    }

    It 'writes nothing with -WhatIf' {
        $fake = New-FakeRepository
        $output = Join-Path -Path $TestDrive -ChildPath 'g'
        New-DemoBootstrapBundle -RepositoryRoot $fake -OutputDirectory $output -WhatIf | Should -BeNullOrEmpty
        Test-Path -LiteralPath $output | Should -BeFalse
    }
}

Describe 'New-DemoBootstrapChunk' {
    BeforeAll {
        function Get-ChunkData([string] $Script) {
            $match = [regex]::Match($Script, '(?s)\$data = @"\n(.*?)\n"@')
            $match.Success | Should -BeTrue
            [System.Convert]::FromBase64String($match.Groups[1].Value)
        }
        $chunkRepository = New-FakeRepository
        # Enough content for several 1 KiB chunks.
        Set-Content -LiteralPath (Join-Path -Path $chunkRepository -ChildPath 'database/common/020-seed.sql') -Value ((1..400 | ForEach-Object { "INSERT INTO care.patients VALUES ($_, N'Patient $_');" }) -join "`n")
        $chunkBundle = New-DemoBootstrapBundle -RepositoryRoot $chunkRepository -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'chunk-bundle')
    }

    It 'splits the bundle into scripts whose data joins back into the same bytes' {
        $chunks = @(New-DemoBootstrapChunk -Path $chunkBundle.Path -ChunkSizeKiB 1)
        $expectedCount = [int][System.Math]::Ceiling($chunkBundle.SizeBytes / 1024.0)
        $chunks.Count | Should -Be $expectedCount
        $chunks.Count | Should -BeGreaterThan 2
        $joined = [System.Collections.Generic.List[byte]]::new()
        foreach ($chunk in $chunks) {
            $data = Get-ChunkData -Script $chunk.Script
            [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant() | Should -Be $chunk.Sha256
            $data.Length | Should -Be $chunk.SizeBytes
            $chunk.Script | Should -Match ("\`$expected = '{0}'" -f $chunk.Sha256)
            $joined.AddRange([byte[]]$data)
        }
        [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($joined.ToArray())).ToLowerInvariant() | Should -Be $chunkBundle.Sha256
        $joined.Count | Should -Be $chunkBundle.SizeBytes
    }

    It 'uses deterministic names, indexes, and folders for the bundle' {
        $chunks = @(New-DemoBootstrapChunk -Path $chunkBundle.Path -ChunkSizeKiB 1)
        $short = $chunkBundle.Sha256.Substring(0, 12)
        for ($i = 0; $i -lt $chunks.Count; $i++) {
            $chunks[$i].Index | Should -Be ($i + 1)
            $chunks[$i].Count | Should -Be $chunks.Count
            $chunks[$i].BundleSha256 | Should -Be $chunkBundle.Sha256
            $chunks[$i].Name | Should -Be ('DbHubDemo-Chunk-{0}-{1:d3}' -f $short, ($i + 1))
            $chunks[$i].Script | Should -Match ([regex]::Escape(('downloads\{0}' -f $short)))
            $chunks[$i].Script | Should -Match ("\`$name = 'chunk-{0:d3}'" -f ($i + 1))
        }
        $again = @(New-DemoBootstrapChunk -Path $chunkBundle.Path -ChunkSizeKiB 1)
        ($again | ForEach-Object { $_.Script }) | Should -Be ($chunks | ForEach-Object { $_.Script })
    }

    It 'writes ASCII-only Windows PowerShell 5.1 scripts with no Run Command parameters' {
        foreach ($chunk in New-DemoBootstrapChunk -Path $chunkBundle.Path -ChunkSizeKiB 2) {
            $chunk.Script | Should -Not -Match '[^\x00-\x7F]'
            $chunk.Script | Should -Match ([regex]::Escape("`$root = 'C:\ProgramData\DbHubDemo'"))
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($chunk.Script, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty
            # The data and hashes are inlined: the script itself takes no parameters.
            $ast.ParamBlock | Should -BeNullOrEmpty
            $newer = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.TernaryExpressionAst] -or $node -is [System.Management.Automation.Language.PipelineChainAst] }, $true)
            $newer | Should -BeNullOrEmpty
        }
    }

    It 'defaults to 512 KiB and accepts 1 to 512 KiB' {
        @(New-DemoBootstrapChunk -Path $chunkBundle.Path).Count | Should -Be ([int][System.Math]::Ceiling($chunkBundle.SizeBytes / 524288.0))
        @(New-DemoBootstrapChunk -Path $chunkBundle.Path -ChunkSizeKiB 48).Count | Should -Be ([int][System.Math]::Ceiling($chunkBundle.SizeBytes / 49152.0))
        { New-DemoBootstrapChunk -Path $chunkBundle.Path -ChunkSizeKiB 0 } | Should -Throw
        { New-DemoBootstrapChunk -Path $chunkBundle.Path -ChunkSizeKiB 513 } | Should -Throw
        @(New-DemoBootstrapChunk -Path $chunkBundle.Path -ChunkSizeKiB 512).Count | Should -Be 1
    }

    It 'refuses a root path that would break the inlined string' {
        { New-DemoBootstrapChunk -Path $chunkBundle.Path -Root "C:\it's" } | Should -Throw
    }

    It 'refuses content that matches a secret pattern, without showing the value' {
        $repository = New-FakeRepository
        # Built at run time so secret scanners don't flag the fixture.
        $token = 'ey' + 'J' + ('a' * 12) + '.' + 'ey' + 'J' + ('b' * 12) + '.' + ('c' * 12)
        Set-Content -LiteralPath (Join-Path -Path $repository -ChildPath 'vm/bootstrap/lib/Core.ps1') -Value "`$header = '$token'"
        $bundle = New-DemoBootstrapBundle -RepositoryRoot $repository -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'secret-bundle')
        $failure = $null
        try {
            New-DemoBootstrapChunk -Path $bundle.Path | Out-Null
        }
        catch {
            $failure = $_.Exception.Message
        }
        $failure | Should -Match "vm/bootstrap/lib/Core\.ps1 matches the secret pattern 'jwt'"
        $failure | Should -Not -Match 'aaaaaaaaaaaa'
    }

    It 'refuses content that holds a registered secret' {
        $repository = New-FakeRepository
        $secret = 'Fake-' + [guid]::NewGuid().ToString('N')
        Register-DemoSecret -Value $secret
        try {
            Set-Content -LiteralPath (Join-Path -Path $repository -ChildPath 'database/common/010-schema.sql') -Value "-- $secret"
            $bundle = New-DemoBootstrapBundle -RepositoryRoot $repository -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'registered-bundle')
            { New-DemoBootstrapChunk -Path $bundle.Path } | Should -Throw '*010-schema.sql contains a registered secret*'
        }
        finally {
            Clear-DemoSecret
        }
    }

    It 'accepts the bundle built from this repository: nothing in it looks like a secret' {
        $bundle = New-DemoBootstrapBundle -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'repository-bundle')
        $chunks = @(New-DemoBootstrapChunk -Path $bundle.Path)
        $chunks.Count | Should -BeGreaterThan 0
        # Below the 1 MB limit for a resource definition (ADR 0001); 512 KiB of data makes about 700 KB of script.
        $chunks[0].Script.Length | Should -BeLessThan 1MB
    }
}

Describe 'Send-DemoBootstrapBundle' {
    BeforeAll {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $sendRepository = New-FakeRepository
        Set-Content -LiteralPath (Join-Path -Path $sendRepository -ChildPath 'database/common/020-seed.sql') -Value ((1..200 | ForEach-Object { "SELECT $_;" }) -join "`n")
        $sendBundle = New-DemoBootstrapBundle -RepositoryRoot $sendRepository -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'send')
        $expectedChunks = @(New-DemoBootstrapChunk -Path $sendBundle.Path -ChunkSizeKiB 1)
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $apiVersion = $versions.apiVersions['Microsoft.Compute/virtualMachines/runCommands']
    }

    BeforeEach {
        # A fake ARM endpoint for the VM's runCommands collection.
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:runCommands = [ordered]@{}
        $script:conflictsLeft = 0
        $script:putError = ''
        $script:failName = ''
        # Phase 28: reads that find a chunk still running, and deletes Azure holds (a busy extension).
        $script:runningReads = 0
        $script:stuckDeletes = $false
        # 2026-11-16: lists that fail before one succeeds, with az's error.
        $script:listFailures = 0
        $script:listError = ''
        # 2026-11-16: names Azure keeps marked for deletion: listed as Deleting, a delete leaves them, and a PUT is refused
        # with the live answer (its status line empty, as az printed it; or Conflict).
        $script:held = [System.Collections.Generic.HashSet[string]]::new()
        $script:heldStatus = ''
        # 2026-11-16: deletes Azure finishes only after this many more lists (a crowded VM's leftovers).
        $script:deleteLag = 0
        $script:pendingDeletes = @{}
        InModuleScope DbHubDemo { $script:DemoRunCommandStuck.Clear(); $script:DemoRunCommandStuckName.Clear() }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $method = $ArgumentList[[array]::IndexOf($ArgumentList, '--method') + 1]
            $url = $ArgumentList[[array]::IndexOf($ArgumentList, '--url') + 1]
            $name = if ($url -match '/runCommands/([^?]+)\?') { $Matches[1] } else { '' }
            $call = [pscustomobject]@{ Method = $method; Url = $url; Name = $name; Body = $null }
            $script:calls.Add($call)
            $notFound = [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: Not Found({"error":{"code":"NotFound","message":"The entity was not found."}})' }
            switch ($method) {
                'put' {
                    $bodyArgument = $ArgumentList[[array]::IndexOf($ArgumentList, '--body') + 1]
                    $call.Body = Get-Content -LiteralPath $bodyArgument.Substring(1) -Raw | ConvertFrom-Json -AsHashtable
                    if ($script:conflictsLeft -gt 0) {
                        $script:conflictsLeft--
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: Conflict({"error":{"code":"Conflict","message":"The request failed due to conflict with a concurrent request."}})' }
                    }
                    if ($script:putError) {
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = $script:putError }
                    }
                    if ($script:held.Contains($name)) {
                        $answer = '{{"error":{{"code":"OperationNotAllowed","message":"Operation ''PUT Extension'' is not allowed on VM extension ''{0}'' since it is marked for deletion. You can only retry the Delete operation (or wait for an ongoing one to complete)."}}}}' -f $name
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('ERROR: {0}({1})' -f $script:heldStatus, $answer) }
                    }
                    $script:runCommands[$name] = $call.Body
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
                }
                'delete' {
                    if (-not $script:stuckDeletes -and -not $script:held.Contains($name)) {
                        if ($script:deleteLag -gt 0) {
                            $script:pendingDeletes[$name] = $script:deleteLag
                        }
                        else {
                            $script:runCommands.Remove($name)
                        }
                    }
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                default {
                    if (-not $name) {
                        if ($script:listFailures -gt 0) {
                            $script:listFailures--
                            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = $script:listError }
                        }
                        foreach ($pendingName in @($script:pendingDeletes.Keys)) {
                            $script:pendingDeletes[$pendingName]--
                            if ($script:pendingDeletes[$pendingName] -le 0) {
                                $script:pendingDeletes.Remove($pendingName)
                                $script:runCommands.Remove($pendingName)
                            }
                        }
                        $value = @($script:runCommands.Keys | ForEach-Object { @{ name = $_; properties = @{ provisioningState = $(if ($script:held.Contains($_)) { 'Deleting' } else { 'Succeeded' }) } } })
                        return [pscustomobject]@{ ExitCode = 0; StdOut = (@{ value = $value } | ConvertTo-Json -Depth 5); StdErr = '' }
                    }
                    if (-not $script:runCommands.Contains($name)) {
                        return $notFound
                    }
                    # A lagged delete finishes after as many reads of the Run Command itself as of the list (R871's wait reads it).
                    if ($script:pendingDeletes.ContainsKey($name)) {
                        $script:pendingDeletes[$name]--
                        if ($script:pendingDeletes[$name] -le 0) {
                            $script:pendingDeletes.Remove($name)
                            $script:runCommands.Remove($name)
                            return $notFound
                        }
                    }
                    $failed = $name -eq $script:failName
                    $running = $script:runningReads -gt 0
                    if ($running) {
                        $script:runningReads--
                    }
                    $view = @{
                        executionState = if ($failed) { 'Failed' } elseif ($running) { 'Running' } else { 'Succeeded' }
                        exitCode       = if ($failed) { 1 } else { 0 }
                        output         = ''
                        error          = if ($failed) { 'Chunk 2: SHA-256 mismatch (expected a, got b). Nothing was written.' } else { '' }
                    }
                    return [pscustomobject]@{ ExitCode = 0; StdOut = (@{ name = $name; properties = @{ provisioningState = 'Succeeded'; instanceView = $view } } | ConvertTo-Json -Depth 5); StdErr = '' }
                }
            }
        }
    }

    It 'sends each chunk with PUT, waits for exit code 0, and deletes it before the next one without waiting for the delete (Phase 28)' {
        $result = Send-DemoBootstrapBundle -Config $config -Bundle $sendBundle -VmName 'sqlvm01' -ChunkSizeKiB 1

        $result.VmName | Should -Be 'sqlvm01'
        $result.BundleSha256 | Should -Be $sendBundle.Sha256
        $result.ChunkCount | Should -Be $expectedChunks.Count
        $result.Seconds | Should -BeGreaterOrEqual 0
        $expectedChunks.Count | Should -BeGreaterThan 1
        # List (cleanup), then PUT, GET, DELETE per chunk, never waiting for the delete (Phase 28), then list (the one
        # bounded cleanup at the end, which finds nothing left).
        $sequence = @('get') + @(foreach ($chunk in $expectedChunks) { 'put', 'get', 'delete' }) + @('get')
        $script:calls.Method | Should -Be $sequence
        $puts = @($script:calls | Where-Object Method -eq 'put')
        $puts.Name | Should -Be $expectedChunks.Name
        for ($i = 0; $i -lt $puts.Count; $i++) {
            $puts[$i].Url | Should -Be ('https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/sqlvm01/runCommands/{0}?api-version={1}' -f $expectedChunks[$i].Name, $apiVersion)
            $puts[$i].Body.location | Should -Be $config['location']
            $puts[$i].Body.properties.source.script | Should -Be $expectedChunks[$i].Script
            $puts[$i].Body.properties.asyncExecution | Should -BeFalse
            $puts[$i].Body.properties.treatFailureAsDeploymentFailure | Should -BeFalse
            $puts[$i].Body.properties.timeoutInSeconds | Should -Be 600
            $puts[$i].Body.properties.Contains('parameters') | Should -BeFalse
            $puts[$i].Body.properties.Contains('protectedParameters') | Should -BeFalse
        }
        ($script:calls | Where-Object { $_.Method -eq 'get' -and $_.Name }).Url | ForEach-Object { $_ | Should -Match '&\$expand=instanceView$' }
        $script:runCommands.Count | Should -Be 0
    }

    It 'sends the T2 host''s chunks one at a time, each chunk''s Run Command gone before the next is written, whatever the parallelism asked (R871)' {
        # Live, 2026-11-16, eight at once on archost01: Azure ended every chunk's delete with InternalExecutionError, the
        # chunks stayed, and the host's next start never got its goal state.
        $sent = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Bundle = $sendBundle } { Send-DemoChunkSet -Config $Config -File @([pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = 'bootstrap bundle' }) -VmName 'archost01' -ChunkSizeKiB 1 -Parallelism 8 -CleanupWaitSeconds 0 })
        $sent[0].ChunkCount | Should -Be $expectedChunks.Count
        # List, then for each chunk: PUT, its result, DELETE, and a read that finds it gone; then the cleanup's list.
        $sequence = @('get') + @(foreach ($chunk in $expectedChunks) { 'put', 'get', 'delete', 'get' }) + @('get')
        $script:calls.Method | Should -Be $sequence
        $script:runCommands.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -like '*chunk*delivered*' } -Times $expectedChunks.Count -Exactly
    }

    It 'deletes a T2 host chunk''s Run Command once more when Azure didn''t, then stops the transfer before the next chunk (R871)' {
        $script:stuckDeletes = $true
        { InModuleScope DbHubDemo -Parameters @{ Config = $config; Bundle = $sendBundle } { Send-DemoChunkSet -Config $Config -File @([pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = 'bootstrap bundle' }) -VmName 'archost01' -ChunkSizeKiB 1 -CleanupWaitSeconds 0 -DeleteWaitSeconds 30 } } | Should -Throw ('archost01: Azure didn''t delete the Run Command of chunk 1 of {0}, twice in 30s, so the transfer stops before more chunks stay on archost01*R871*' -f $expectedChunks.Count)
        @($script:calls | Where-Object Method -EQ 'put').Count | Should -Be 1 -Because 'no second chunk goes while the first stays'
        @($script:calls | Where-Object { $_.Method -eq 'delete' -and $_.Name -eq $expectedChunks[0].Name }).Count | Should -BeGreaterOrEqual 2
        @($script:calls | Where-Object { $_.Method -eq 'get' -and $_.Name -eq $expectedChunks[0].Name }).Count | Should -Be 5 -Because 'its result, then 2 reads 15 seconds apart in each of the two rounds'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like ('archost01: Azure didn''t delete the Run Command of chunk 1 of {0} within 30s, so it''s deleted once more.' -f $expectedChunks.Count) } -Times 1 -Exactly
    }

    It 'uses the runCommands API version that bootstrap.bicep declares' {
        $bicep = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/bootstrap.bicep') -Raw
        $bicep | Should -Match ([regex]::Escape("'Microsoft.Compute/virtualMachines/runCommands@$apiVersion'"))
    }

    It 'retries a PUT that hits 409 Conflict, with backoff' {
        $script:conflictsLeft = 2
        Send-DemoBootstrapBundle -Config $config -Bundle $sendBundle -VmName 'archost01' -ChunkSizeKiB 1 | Out-Null
        @($script:calls | Where-Object { $_.Method -eq 'put' -and $_.Name -eq $expectedChunks[0].Name }).Count | Should -Be 3
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 10 } -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 20 } -Times 1 -Exactly
        $script:runCommands.Count | Should -Be 0
    }

    It 'stops at a chunk whose script exits non-zero, reports its error, and deletes the leftover Run Command' {
        $script:failName = $expectedChunks[1].Name
        { Send-DemoBootstrapBundle -Config $config -Bundle $sendBundle -VmName 'sqlvm01' -ChunkSizeKiB 1 } | Should -Throw ('*chunk 2 of {0} failed on the VM*exit code 1*SHA-256 mismatch*' -f $expectedChunks.Count)
        @($script:calls | Where-Object Method -eq 'put').Name | Should -Be @($expectedChunks[0].Name, $expectedChunks[1].Name)
        # The finally block listed the VM's Run Commands and deleted the failed chunk.
        @($script:calls | Where-Object { $_.Method -eq 'delete' -and $_.Name -eq $expectedChunks[1].Name }).Count | Should -Be 1
        $script:runCommands.Count | Should -Be 0
    }

    It 'fails without retrying on another PUT error' {
        $script:putError = 'ERROR: Bad Request({"error":{"code":"InvalidParameter","message":"Bad request."}})'
        { Send-DemoBootstrapBundle -Config $config -Bundle $sendBundle -VmName 'sqlvm01' -ChunkSizeKiB 1 } | Should -Throw '*sending chunk 1 of*failed*InvalidParameter*'
        @($script:calls | Where-Object Method -eq 'put').Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0
    }

    It 'deletes leftover chunk Run Commands from an earlier run before it starts' {
        $script:runCommands['DbHubDemo-Chunk-aaaaaaaaaaaa-007'] = @{}
        $script:runCommands['DbHubDemo-Bootstrap'] = @{}
        Send-DemoBootstrapBundle -Config $config -Bundle $sendBundle -VmName 'sqlvm01' -ChunkSizeKiB 1 | Out-Null
        $script:calls[1].Method | Should -Be 'delete'
        $script:calls[1].Name | Should -Be 'DbHubDemo-Chunk-aaaaaaaaaaaa-007'
        $script:runCommands.Keys | Should -Be @('DbHubDemo-Bootstrap')
    }

    It 'lists the Run Commands again when a list fails, so leftovers are still deleted first, logs the cause, and warns of nothing (2026-11-16)' {
        $script:listFailures = 1
        $script:listError = 'ERROR: (TooManyRequests) The request is being throttled.'
        $script:runCommands['DbHubDemo-Chunk-aaaaaaaaaaaa-007'] = @{}
        Send-DemoBootstrapBundle -Config $config -Bundle $sendBundle -VmName 'sqlvm01' -ChunkSizeKiB 1 | Out-Null
        $script:calls[0].Method | Should -Be 'get'
        $script:calls[1].Method | Should -Be 'get'
        $script:calls[1].Name | Should -BeNullOrEmpty
        $script:calls[2].Method | Should -Be 'delete'
        $script:calls[2].Name | Should -Be 'DbHubDemo-Chunk-aaaaaaaaaaaa-007'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 5 } -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -like 'Listed the Run Commands on sqlvm01 on try 2 of 3; the try before failed (az: ERROR: (TooManyRequests) The request is being throttled.).' } -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' } -Times 0
    }

    It 'warns of nothing when the VM has no chunk Run Commands, the usual case, and lists once at each end (2026-11-16)' {
        # An empty list reached the callers as $null, which they read as "couldn't be listed": a Warning in nearly every
        # deploy, before the send and after it, while every list had succeeded (az exit code 0).
        Send-DemoBootstrapBundle -Config $config -Bundle $sendBundle -VmName 'sqlvm01' -ChunkSizeKiB 1 | Out-Null
        @($script:calls | Where-Object { $_.Method -eq 'get' -and -not $_.Name }).Count | Should -Be 2
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' } -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 5 } -Times 0
    }

    It 'reports no leftover when the deletes it asked for are done by its first look, not every name it asked to delete (2026-11-16)' {
        $script:runCommands['DbHubDemo-Chunk-bbbbbbbbbbbb-001'] = @{}
        $script:runCommands['DbHubDemo-Bootstrap'] = @{}
        $baseUrl = 'https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/sqlvm01/runCommands'
        $left = @(InModuleScope DbHubDemo -Parameters @{ BaseUrl = $baseUrl; ApiVersion = $apiVersion } { Wait-DemoChunkRunCommandGone -SubscriptionId '11111111-2222-3333-4444-555555555555' -BaseUrl $BaseUrl -ApiVersion $ApiVersion -TimeoutSeconds 60 })
        $left.Count | Should -Be 0
        $script:runCommands.Keys | Should -Be @('DbHubDemo-Bootstrap')
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' } -Times 0
    }

    It 'warns with az''s error, redacted, after three failed lists, and still sends the bundle (2026-11-16)' {
        $fakeToken = 'Bearer ' + ('q' * 40)
        $script:listFailures = 3
        $script:listError = ('ERROR: (AuthorizationFailed) The client failed with header {0}.' -f $fakeToken)
        $result = Send-DemoBootstrapBundle -Config $config -Bundle $sendBundle -VmName 'archost01' -ChunkSizeKiB 1
        $result.ChunkCount | Should -Be $expectedChunks.Count
        @($script:calls | Select-Object -First 3).Method | Should -Be @('get', 'get', 'get')
        $script:calls[3].Method | Should -Be 'put'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 5 } -Times 2 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'The Run Commands on archost01 could not be listed in 3 tries (az: ERROR: (AuthorizationFailed) The client failed with header *), so leftover chunk Run Commands weren''t deleted this time. Nothing to do:*./scripts/status.ps1*' -and $Message -notlike ('*{0}*' -f ('q' * 40)) } -Times 1 -Exactly
        $script:runCommands.Count | Should -Be 0
    }

    It 'never waits on a delete Azure holds: one bounded cleanup at the end reports what''s left (Phase 28, R49)' {
        $script:stuckDeletes = $true
        $sent = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Bundle = $sendBundle } { Send-DemoChunkSet -Config $Config -File @([pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = 'bootstrap bundle' }) -VmName 'sqlvm01' -ChunkSizeKiB 1 -CleanupWaitSeconds 0 })
        $sent[0].ChunkCount | Should -Be $expectedChunks.Count
        @($sent[0].LeftoverRunCommands) | Should -Be @($expectedChunks.Name)
        # Each chunk's Run Command is read only for its result, never polled after its delete.
        @($script:calls | Where-Object { $_.Method -eq 'get' -and $_.Name }).Count | Should -Be $expectedChunks.Count
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'Azure is still deleting' }
    }

    It 'leaves its end-of-run cleanup to the next run when deploy.ps1 was stopped (Phase 28 live finding)' {
        # A stop (Ctrl+C) runs this finally block; the cleanup's wait would hold the stop for up to CleanupWaitSeconds.
        $script:stuckDeletes = $true
        $script:cleanupWaited = $false
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoChunkRunCommandGone -MockWith { $script:cleanupWaited = $true; @() }
        $sent = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Bundle = $sendBundle } { Send-DemoChunkSet -Config $Config -File @([pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = 'bootstrap bundle' }) -VmName 'sqlvm01' -ChunkSizeKiB 1 -CleanupWaitSeconds 300 })
        $script:cleanupWaited | Should -BeFalse
        @($sent[0].LeftoverRunCommands).Count | Should -Be 0
    }

    It 'sends a chunk whose name Azure keeps marked for deletion under a fresh name at once, with the same script, and its cleanup still finds it (2026-11-16 live finding)' {
        # Live on archost01, the refused PUT failed the transfer, and the watchdog restarted the VM, which Azure then hung.
        $held = $expectedChunks[0].Name
        $script:runCommands[$held] = @{}
        $null = $script:held.Add($held)
        $sent = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Bundle = $sendBundle } { Send-DemoChunkSet -Config $Config -File @([pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = 'bootstrap bundle' }) -VmName 'archost01' -ChunkSizeKiB 1 -CleanupWaitSeconds 0 })

        $sent[0].ChunkCount | Should -Be $expectedChunks.Count
        $puts = @($script:calls | Where-Object Method -eq 'put')
        $puts.Count | Should -Be ($expectedChunks.Count + 1)
        $puts[0].Name | Should -Be $held
        $puts[1].Name | Should -Match ('^{0}-\d{{14}}$' -f [regex]::Escape($held))
        $puts[1].Body.properties.source.script | Should -Be $expectedChunks[0].Script -Because 'the VM writes the same chunk-001 file, whatever the Run Command is called'
        @($puts | Select-Object -Skip 2).Name | Should -Be @($expectedChunks | Select-Object -Skip 1).Name
        @($script:calls | Where-Object { $_.Method -eq 'delete' -and $_.Name -eq $puts[1].Name }).Count | Should -Be 1 -Because 'it''s deleted once it finished, like any chunk'
        $script:runCommands.Keys | Should -Be @($held)
        @($sent[0].LeftoverRunCommands) | Should -Be @($held) -Because 'the cleanup at the end still reports the one Azure holds'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 10 } -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like ('archost01: Azure keeps {0} marked for deletion (*), so it runs as {0}-*. Nothing to do: Azure deletes the stuck one on its own (DEPLOY.RUNCOMMAND.STUCK_ARCHOST01).' -f $held) } -Times 1 -Exactly
        $stuck = @(InModuleScope DbHubDemo { Get-DemoRunCommandStuckResult -Clear })
        $stuck.Count | Should -Be 1
        $stuck[0].checkId | Should -Be 'DEPLOY.RUNCOMMAND.STUCK_ARCHOST01'
        $stuck[0].status | Should -Be 'Warning'
        $stuck[0].message | Should -BeLike ('Azure kept {0} on archost01 marked for deletion, so 1 Run Command run(s) used a fresh name instead of waiting (the last: {1}).*' -f $held, $puts[1].Name)
    }

    It 'leaves the other chunks of its set alone while one gets a fresh name, so each is still read back (2026-11-16)' {
        $expectedChunks.Count | Should -BeGreaterOrEqual 3
        $held = $expectedChunks[2].Name
        $script:runCommands[$held] = @{}
        $null = $script:held.Add($held)
        $sent = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Bundle = $sendBundle } { Send-DemoChunkSet -Config $Config -File @([pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = 'bootstrap bundle' }) -VmName 'archost01' -ChunkSizeKiB 1 -Parallelism 4 -CleanupWaitSeconds 0 })

        $sent[0].ChunkCount | Should -Be $expectedChunks.Count
        # Chunks 1 and 2 had finished, unread, when chunk 3's fresh name was resolved: only their own finish deletes them.
        foreach ($name in $expectedChunks[0].Name, $expectedChunks[1].Name) {
            @($script:calls | Where-Object { $_.Method -eq 'delete' -and $_.Name -eq $name }).Count | Should -Be 1
        }
        $script:runCommands.Keys | Should -Be @($held)
    }

    It 'gives a held name a fresh name at once when Azure''s answer reads Conflict too, with no backoff (2026-11-16)' {
        $script:heldStatus = 'Conflict'
        $held = $expectedChunks[0].Name
        $script:runCommands[$held] = @{}
        $null = $script:held.Add($held)
        $sent = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Bundle = $sendBundle } { Send-DemoChunkSet -Config $Config -File @([pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = 'bootstrap bundle' }) -VmName 'archost01' -ChunkSizeKiB 1 -CleanupWaitSeconds 0 })

        $sent[0].ChunkCount | Should -Be $expectedChunks.Count
        @($script:calls | Where-Object { $_.Method -eq 'put' -and $_.Name -eq $held }).Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 10 } -Times 0
    }

    It 'stops with Azure''s limit of 25, not the refused PUT, when the VM has no room for a fresh name (2026-11-16)' {
        $held = $expectedChunks[0].Name
        $script:runCommands[$held] = @{}
        $null = $script:held.Add($held)
        foreach ($i in 1..23) {
            $script:runCommands[('DbHubDemo-Other-{0:d2}' -f $i)] = @{}
        }
        { InModuleScope DbHubDemo -Parameters @{ Config = $config; Bundle = $sendBundle } { Send-DemoChunkSet -Config $Config -File @([pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = 'bootstrap bundle' }) -VmName 'archost01' -ChunkSizeKiB 1 -CleanupWaitSeconds 0 -RoomWaitSeconds 0 } } | Should -Throw ('archost01: Azure keeps {0} marked for deletion, and the VM already has 24 Run Commands (1 being deleted), close to Azure''s limit of 25*' -f $held)
        @($script:calls | Where-Object Method -eq 'put').Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like ('archost01: Azure still lists 24 Run Commands after 0s, so the {0} chunk(s) go now;*' -f $expectedChunks.Count) } -Times 1 -Exactly
    }

    It 'waits for its leftovers'' deletes before the first chunk when the VM has no room for the set, so a held chunk still gets a fresh name (2026-11-16 live finding)' {
        # Live on archost01: 23 of Azure's 25, among them 9 finished chunks of an earlier send and 8 held ones.
        $script:deleteLag = 2
        foreach ($i in 1..9) {
            $script:runCommands[('DbHubDemo-Chunk-4e8f3641cbfc-{0:d3}' -f $i)] = @{}
        }
        $held = $expectedChunks[0].Name
        foreach ($name in @($held) + @(2..8 | ForEach-Object { 'DbHubDemo-Chunk-a8a10d93133c-{0:d3}' -f $_ })) {
            $script:runCommands[$name] = @{}
            $null = $script:held.Add($name)
        }
        foreach ($i in 1..7) {
            $script:runCommands[('DbHubDemo-Named-{0}' -f $i)] = @{}
        }
        # 24 listed: without the wait, the held chunk would find no room for a fresh name.
        $sent = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Bundle = $sendBundle } { Send-DemoChunkSet -Config $Config -File @([pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = 'bootstrap bundle' }) -VmName 'archost01' -ChunkSizeKiB 1 -CleanupWaitSeconds 0 })

        $sent[0].ChunkCount | Should -Be $expectedChunks.Count
        $puts = @($script:calls | Where-Object Method -eq 'put')
        $firstPut = $script:calls.IndexOf($puts[0])
        @($script:calls | Select-Object -First $firstPut | Where-Object { $_.Method -eq 'get' -and -not $_.Name }).Count | Should -Be 3 -Because 'the cleanup''s list, then two more until the leftovers were gone'
        $puts[1].Name | Should -Match ('^{0}-\d{{14}}$' -f [regex]::Escape($held))
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -like ('archost01: it lists 24 Run Commands, 17 of them chunks it just asked Azure to delete, and {0} chunk(s) need room under Azure''s limit of 25, so it waits up to 5m 00s for those deletes first.' -f $expectedChunks.Count) } -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -like ('archost01: Azure finished enough of those deletes in *: 15 Run Commands listed, room for the {0} chunk(s).' -f $expectedChunks.Count) } -Times 1 -Exactly
    }

    It 'goes on one chunk at a time after a stall, when no chunk finishes for StallSeconds while several run (Phase 28)' {
        $script:runningReads = 20
        $script:clock = [DateTime]::UtcNow
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $script:clock = $script:clock.AddSeconds(20); $script:clock }
        $sent = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Bundle = $sendBundle } { Send-DemoChunkSet -Config $Config -File @([pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = 'bootstrap bundle' }) -VmName 'sqlvm01' -ChunkSizeKiB 1 -Parallelism 4 -StallSeconds 30 })
        $sent[0].Stalled | Should -BeTrue
        $sent[0].ChunkCount | Should -Be $expectedChunks.Count
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'so the rest go one at a time' }
        $script:runCommands.Count | Should -Be 0
    }

    It 'makes no Azure calls with -WhatIf' {
        Send-DemoBootstrapBundle -Config $config -Bundle $sendBundle -VmName 'sqlvm01' -WhatIf | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'refuses a bundle that changed after it was built, before any Azure call' {
        $copy = Join-Path -Path $TestDrive -ChildPath 'changed.zip'
        Copy-Item -LiteralPath $sendBundle.Path -Destination $copy
        Add-Content -LiteralPath $copy -Value 'tampered'
        $tampered = $sendBundle.PSObject.Copy()
        $tampered.Path = $copy
        { Send-DemoBootstrapBundle -Config $config -Bundle $tampered -VmName 'sqlvm01' } | Should -Throw '*changed after it was built*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'sends several files through one queue: every chunk Run Command is created before the first is deleted (ADR 0018)' {
        $secondRepository = New-FakeRepository
        Set-Content -LiteralPath (Join-Path -Path $secondRepository -ChildPath 'database/common/020-seed.sql') -Value ((1..150 | ForEach-Object { "SELECT $_ + 1;" }) -join "`n")
        $second = New-DemoBootstrapBundle -RepositoryRoot $secondRepository -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'send-second')
        $files = @(
            [pscustomobject]@{ Path = $sendBundle.Path; Sha256 = $sendBundle.Sha256; SizeBytes = $sendBundle.SizeBytes; Description = 'bootstrap bundle' }
            [pscustomobject]@{ Path = $second.Path; Sha256 = $second.Sha256; SizeBytes = $second.SizeBytes; Description = 'workload runner' }
        )
        $sent = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Files = $files } { Send-DemoChunkSet -Config $Config -File $Files -VmName 'sqlvm01' -ChunkSizeKiB 1 -Parallelism 16 })

        $sent.Count | Should -Be 2
        $sent[0].Sha256 | Should -Be $sendBundle.Sha256
        $sent[0].ChunkCount | Should -Be $expectedChunks.Count
        $sent[1].Sha256 | Should -Be $second.Sha256
        $sent[1].Description | Should -Be 'workload runner'
        $methods = @($script:calls.Method)
        @($script:calls | Where-Object Method -eq 'put').Count | Should -Be ($sent[0].ChunkCount + $sent[1].ChunkCount)
        [array]::LastIndexOf($methods, 'put') | Should -BeLessThan ([array]::IndexOf($methods, 'delete'))
        $script:runCommands.Count | Should -Be 0
    }

    It 'refuses a file that changed after it was built, before any Azure call, whatever else travels with it' {
        $copy = Join-Path -Path $TestDrive -ChildPath 'changed-set.zip'
        Copy-Item -LiteralPath $sendBundle.Path -Destination $copy
        Add-Content -LiteralPath $copy -Value 'tampered'
        $files = @(
            [pscustomobject]@{ Path = $sendBundle.Path; Sha256 = $sendBundle.Sha256; SizeBytes = $sendBundle.SizeBytes; Description = 'bootstrap bundle' }
            [pscustomobject]@{ Path = $copy; Sha256 = $sendBundle.Sha256; SizeBytes = $sendBundle.SizeBytes; Description = 'workload runner' }
        )
        { InModuleScope DbHubDemo -Parameters @{ Config = $config; Files = $files } { Send-DemoChunkSet -Config $Config -File $Files -VmName 'sqlvm01' -Parallelism 8 } } | Should -Throw '*workload runner changed after it was built*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }
}

Describe 'Wait-DemoBootstrapLoader' {
    BeforeAll {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
    }

    BeforeEach {
        $script:loaderView = $null
        $script:loaderUrls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $script:loaderUrls.Add($ArgumentList[[array]::IndexOf($ArgumentList, '--url') + 1])
            if ($null -eq $script:loaderView) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: Not Found({"error":{"code":"NotFound"}})' }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = (@{ name = 'DbHubDemo-Bootstrap'; properties = @{ provisioningState = 'Succeeded'; instanceView = $script:loaderView } } | ConvertTo-Json -Depth 5); StdErr = '' }
        }
    }

    It 'passes when the loader exits 0, and reads the instance view of DbHubDemo-Bootstrap' {
        $script:loaderView = @{ executionState = 'Succeeded'; exitCode = 0; output = 'DbHubDemo loader finished'; error = '' }
        $result = Wait-DemoBootstrapLoader -Config $config -VmName 'sqlvm01'
        $result.status | Should -Be 'Pass'
        $result.checkId | Should -Be 'INFRA.BOOTSTRAP.LOADER_SQLVM01'
        $result.target | Should -Be 'T1'
        $result.evidence.exitCode | Should -Be 0
        $script:loaderUrls[0] | Should -Match '/virtualMachines/sqlvm01/runCommands/DbHubDemo-Bootstrap\?api-version=[0-9-]+&\$expand=instanceView$'
    }

    It 'fails with the loader''s error when it exits non-zero, so a failed bootstrap is never hidden' {
        $script:loaderView = @{ executionState = 'Failed'; exitCode = 1; output = ''; error = 'DbHubDemo loader failed: The bundle is incomplete: missing chunk(s) 3.' }
        $result = Wait-DemoBootstrapLoader -Config $config -VmName 'archost01'
        $result.status | Should -Be 'Fail'
        $result.target | Should -Be 'T2'
        $result.message | Should -Match 'missing chunk\(s\) 3'
        $result.remediation | Should -Match 'loader\.log'
    }

    It 'fails when the VM has no loader Run Command' {
        $result = Wait-DemoBootstrapLoader -Config $config -VmName 'sqlvm01'
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'no bootstrap loader Run Command'
    }

    It 'warns when the loader is still running at the end of the wait' {
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoRunCommand -MockWith {
            [pscustomobject]@{ Found = $true; NotFound = $false; ProvisioningState = 'Succeeded'; ExecutionState = 'Running'; ExitCode = $null; Output = ''; Error = ''; WaitTimedOut = $true }
        }
        $result = Wait-DemoBootstrapLoader -Config $config -VmName 'sqlvm01' -TimeoutSeconds 30
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'still Running'
    }
}

Describe 'New-DemoAdminPassword' {
    It 'returns a registered SecureString that meets Azure VM complexity rules' {
        $secure = New-DemoAdminPassword
        $secure | Should -BeOfType ([System.Security.SecureString])
        $plain = [System.Net.NetworkCredential]::new('', $secure).Password
        $plain.Length | Should -BeGreaterOrEqual 20
        $plain | Should -Match '^[A-Za-z]'
        $plain | Should -MatchExactly '[a-z]'
        $plain | Should -MatchExactly '[A-Z]'
        $plain | Should -Match '[0-9]'
        $plain | Should -Match '[^A-Za-z0-9]'
        Protect-DemoText -Text $plain | Should -Not -Be $plain
        Clear-DemoSecret
    }

    It 'never uses a character that cmd.exe or Invoke-DemoAz treats specially, across 1,000 passwords' {
        # '%' is refused by Invoke-DemoAz on Windows; '!' and '^' are cmd.exe metacharacters, like '&|<>()'.
        $forbidden = [char[]]'"%!^&|<>()'
        $problems = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt 1000; $i++) {
            $plain = [System.Net.NetworkCredential]::new('', (New-DemoAdminPassword)).Password
            $complex = $plain -cmatch '[a-z]' -and $plain -cmatch '[A-Z]' -and $plain -match '[0-9]' -and $plain -match '[^A-Za-z0-9]'
            if ($plain.IndexOfAny($forbidden) -ge 0 -or -not $complex -or $plain.Length -lt 12 -or $plain.Length -gt 123 -or $plain -notmatch '^[A-Za-z]') {
                $problems.Add(('password {0}' -f $i))
            }
            if ($i % 100 -eq 0) {
                Clear-DemoSecret
            }
        }
        Clear-DemoSecret
        $problems | Should -BeNullOrEmpty
    }

    It 'passes through the az.cmd quoting unchanged' {
        $plain = [System.Net.NetworkCredential]::new('', (New-DemoAdminPassword)).Password
        try {
            $quoted = InModuleScope -ModuleName DbHubDemo -Parameters @{ Value = "adminPassword=$plain" } { param($Value) ConvertTo-DemoBatchArgument -Argument $Value }
            $quoted | Should -Be ('"adminPassword={0}"' -f $plain)
        }
        finally {
            Clear-DemoSecret
        }
    }
}
