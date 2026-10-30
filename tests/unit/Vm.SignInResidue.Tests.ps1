BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the sweep's functions without running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoSignInResidue.ps1')

    # Every token is built at run time from harmless parts, so secret scanners never see one in the repository.
    function New-TestToken {
        param([hashtable] $Claim)
        $encode = { param([byte[]] $Bytes) [System.Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        $utf8 = [System.Text.Encoding]::UTF8
        $header = '{"typ":"JWT","alg":"RS256","kid":"' + [guid]::NewGuid().ToString('N') + '"}'
        $payload = (@($Claim.Keys | ForEach-Object { '"{0}":"{1}"' -f $_, $Claim[$_] }) -join ',')
        $signature = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(64)
        '{0}.{1}.{2}' -f (& $encode $utf8.GetBytes($header)), (& $encode $utf8.GetBytes('{' + $payload + '}')), (& $encode $signature)
    }

    function New-TestMachine {
        # A small machine tree: the folders the sweep reads, under TestDrive.
        $root = Join-Path -Path $TestDrive -ChildPath ('machine-' + [guid]::NewGuid().ToString('N'))
        $folder = @{
            ProgramFiles = Join-Path -Path $root -ChildPath 'Program Files'
            ProgramData  = Join-Path -Path $root -ChildPath 'ProgramData'
            Windows      = Join-Path -Path $root -ChildPath 'Windows'
            SystemRoot   = $root
            Users        = Join-Path -Path $root -ChildPath 'Users'
            ExpandRoot   = Join-Path -Path $root -ChildPath 'expand'
        }
        foreach ($path in $folder.Values) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        return $folder
    }

    function Write-TestFile {
        param([string] $Path, [string] $Text, [System.Text.Encoding] $Encoding = [System.Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($Path, $Text, $Encoding)
        return $Path
    }

    function New-TestEventRecord {
        param([string] $Text, [datetime] $TimeCreated = [datetime]::UtcNow)
        [pscustomobject]@{ Properties = @([pscustomobject]@{ Value = $Text }); TimeCreated = $TimeCreated }
    }

    $script:noEvents = { param($Name, $XPath) $null = $Name, $XPath }

    # Windows automatic sign-in (Phase 28) isn't readable here (no LSA on this test machine, or no administrator), and
    # the sweep fails closed on what it can't read: every test reads a machine without it unless it passes its own
    # -AutoLogonProvider. The sweep's own autologon tests are at the end of its Describe block.
    $script:noAutoLogon = { param($Mode) $null = $Mode; @{ Enabled = 0; Secret = 0; PlainValue = 0; UserName = 0 } }
    $script:sweep = ${function:Invoke-DemoSignInSweep}
    function Invoke-DemoSignInSweep {
        $arguments = @{}
        for ($i = 0; $i -lt $args.Count; $i += 2) {
            $arguments[([string]$args[$i]).TrimStart('-').TrimEnd(':')] = $args[$i + 1]
        }
        if (-not $arguments.ContainsKey('AutoLogonProvider')) {
            $arguments['AutoLogonProvider'] = $script:noAutoLogon
        }
        & $script:sweep @arguments
    }
}

Describe 'Invoke-DemoSignInSweep' {
    BeforeEach {
        $script:userToken = New-TestToken -Claim @{ aud = 'https://management.azure.com/'; scp = 'user_impersonation'; upn = 'someone@example.com' }
        $script:appToken = New-TestToken -Claim @{ aud = 'https://management.azure.com/'; xms_mirid = '/subscriptions/x/identity'; appid = [guid]::NewGuid().ToString() }
        $script:machine = New-TestMachine
        $log = [System.IO.Path]::Combine($script:machine.ProgramFiles, 'Microsoft SQL Server', '160', 'Setup Bootstrap', 'Log', '20261021_144021')
        $xml = '<?xml version="1.0" encoding="utf-16"?>' + "`r`n" + '<Settings>' + "`r`n" + ('  <Setting Id="ExampleValue" Value="{0}" />' -f $script:userToken) + "`r`n" + ('  <Value>{0}</Value>' -f $script:userToken) + "`r`n" + '</Settings>'
        $script:settingsFile = Write-TestFile -Path (Join-Path -Path $log -ChildPath 'Example.xml') -Text $xml -Encoding ([System.Text.UnicodeEncoding]::new($false, $true))
        $script:detailFile = Write-TestFile -Path (Join-Path -Path $log -ChildPath 'Detail.txt') -Text 'No sign-in data here.'
        $script:archive = Join-Path -Path $log -ChildPath 'Log.cab'
        [System.IO.File]::WriteAllBytes($script:archive, [byte[]](0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0))
        $profileRoot = Join-Path -Path $script:machine.Users -ChildPath 'Administrator'
        $script:tempFile = Write-TestFile -Path ([System.IO.Path]::Combine($profileRoot, 'AppData', 'Local', 'Temp', 'setup.log')) -Text ("line one`nsign-in {0} end`n" -f $script:userToken)
        $script:historyFile = Write-TestFile -Path ([System.IO.Path]::Combine($profileRoot, 'AppData', 'Roaming', 'Microsoft', 'Windows', 'PowerShell', 'PSReadLine', 'ConsoleHost_history.txt')) -Text "Get-Date`n"
        $script:transcript = Write-TestFile -Path ([System.IO.Path]::Combine($profileRoot, 'Documents', 'PowerShell_transcript.HOST.abc.20261021.txt')) -Text ("Host Application: powershell.exe -File x.ps1 -Value {0}`n" -f $script:userToken)
        $script:webView = [System.IO.Path]::Combine($profileRoot, 'AppData', 'Local', 'Temp', 'setup.exe.WebView2', 'EBWebView')
        Write-TestFile -Path ([System.IO.Path]::Combine($script:webView, 'Default', 'Cookies')) -Text 'cookie' | Out-Null
        $script:msalCache = Write-TestFile -Path ([System.IO.Path]::Combine($profileRoot, 'AppData', 'Local', '.IdentityService', 'msal.cache')) -Text 'encrypted'
        $script:brokerEntry = Write-TestFile -Path ([System.IO.Path]::Combine($profileRoot, 'AppData', 'Local', 'Microsoft', 'TokenBroker', 'Cache', 'entry.tbres')) -Text '{}'
        $script:handlerStatus = Write-TestFile -Path ([System.IO.Path]::Combine($script:machine.SystemRoot, 'Packages', 'Plugins', 'Microsoft.CPlat.Core.RunCommandHandlerWindows', '2.0.14', 'Status', '0.status')) -Text ('{{"message":"-Action Onboard -Value {0}"}}' -f $script:userToken)
        $script:agentLog = Write-TestFile -Path ([System.IO.Path]::Combine($script:machine.ProgramData, 'AzureConnectedMachineAgent', 'Log', 'himds.log')) -Text ('issued {0}' -f $script:appToken)
        $script:demoLog = Write-TestFile -Path ([System.IO.Path]::Combine($script:machine.ProgramData, 'DbHubDemo', 'logs', 'bootstrap-20261021.log')) -Text 'Redacted: [REDACTED:jwt]'
        $script:cleared = [System.Collections.Generic.List[string]]::new()
        $script:clearer = { param($Name) $script:cleared.Add($Name) }
        $script:events = @{
            'Windows PowerShell' = @(
                (New-TestEventRecord -Text ('HostApplication=powershell.exe -File script.ps1 -Value {0}' -f $script:userToken) -TimeCreated ([datetime]'2026-10-21T14:41:00Z'))
                (New-TestEventRecord -Text 'HostApplication=powershell.exe -File script.ps1 -Action Probe')
            )
        }
        $script:reader = {
            param($Name, $XPath)
            $null = $XPath
            if ($script:events.ContainsKey($Name)) {
                $script:events[$Name]
            }
        }
    }

    It 'finds every kind of sign-in data with counts and locations, and never returns a value' {
        $result = Invoke-DemoSignInSweep -IncludeBrowserCache $true -Folder $script:machine -EventLogReader $script:reader -EventLogClearer $script:clearer

        $result.pass | Should -BeFalse
        $result.cleaned | Should -BeFalse
        $result.found.userTokens | Should -Be 5 -Because 'two in the UTF-16 setup file, one each in temp, the transcript, and the handler status'
        $result.found.appTokens | Should -Be 1
        $result.found.archives | Should -Be 1
        $result.found.browserCaches | Should -Be 2
        $result.found.brokerEntries | Should -Be 1
        $result.found.eventLogUserTokens | Should -Be 1
        $locations = @($result.locations | ForEach-Object { '{0}|{1}' -f $_.location, [System.IO.Path]::GetFileName($_.path) })
        $locations | Should -Contain 'SetupLogs|Example.xml'
        $locations | Should -Contain 'SetupLogs|Log.cab'
        $locations | Should -Contain 'Temp|setup.log'
        $locations | Should -Contain 'Transcripts|PowerShell_transcript.HOST.abc.20261021.txt'
        $locations | Should -Contain 'RunCommand|0.status'
        $locations | Should -Contain 'ArcAgent|himds.log'
        $locations | Should -Contain 'BrowserCache|EBWebView'
        ($result.eventLogs | Where-Object { $_.log -eq 'Windows PowerShell' }).firstUtc | Should -Be '2026-10-21T14:41:00Z'
        $json = $result | ConvertTo-Json -Depth 8
        foreach ($value in $script:userToken, $script:appToken) {
            $json | Should -Not -Match ([regex]::Escape($value))
            $json | Should -Not -Match ([regex]::Escape($value.Split('.')[2].Substring(0, 30)))
        }
        $script:cleared.Count | Should -Be 0 -Because 'a scan changes nothing'
        Test-Path -LiteralPath $script:webView | Should -BeTrue
        [System.IO.File]::ReadAllText($script:tempFile) | Should -Match ([regex]::Escape($script:userToken))
    }

    It 'cleans: redacts in place keeping the encoding, deletes the archive and the caches, clears the event log, and passes' {
        $result = Invoke-DemoSignInSweep -Clean $true -IncludeBrowserCache $true -Folder $script:machine -EventLogReader $script:reader -EventLogClearer { param($Name) $script:cleared.Add($Name); $script:events.Remove($Name) }

        $result.pass | Should -BeTrue
        $result.actions.filesRedacted | Should -Be 5
        $result.actions.filesDeleted | Should -Be 1
        $result.actions.cachesRemoved | Should -Be 2
        $result.actions.brokerEntriesRemoved | Should -Be 1
        @($result.actions.eventLogsCleared) | Should -Be @('Windows PowerShell')
        $result.remaining.userTokens + $result.remaining.otherTokens + $result.remaining.appTokens | Should -Be 0
        $bytes = [System.IO.File]::ReadAllBytes($script:settingsFile)
        @($bytes[0], $bytes[1]) | Should -Be @(0xFF, 0xFE) -Because 'the UTF-16 byte order mark is kept'
        $text = [System.IO.File]::ReadAllText($script:settingsFile, [System.Text.Encoding]::Unicode)
        $text | Should -Match 'Id="ExampleValue" Value="\[REDACTED\]"'
        $text | Should -Match '<Value>\[REDACTED\]</Value>'
        $text | Should -Not -Match 'eyJ'
        [System.IO.File]::ReadAllText($script:detailFile) | Should -Be 'No sign-in data here.'
        [System.IO.File]::ReadAllText($script:agentLog) | Should -Be 'issued [REDACTED]'
        Test-Path -LiteralPath $script:archive | Should -BeFalse
        Test-Path -LiteralPath $script:webView | Should -BeFalse
        Test-Path -LiteralPath $script:msalCache | Should -BeFalse
        Test-Path -LiteralPath $script:brokerEntry | Should -BeFalse
        Test-Path -LiteralPath $script:historyFile | Should -BeTrue -Because 'files without sign-in data are left alone'
    }

    It 'reports an application''s or a managed identity''s token without failing, and Clean redacts it' {
        $machine = New-TestMachine
        $log = Write-TestFile -Path ([System.IO.Path]::Combine($machine.ProgramData, 'GuestConfig', 'ext.log')) -Text ('token {0}' -f $script:appToken)
        $scan = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents
        $scan.pass | Should -BeTrue
        $scan.found.appTokens | Should -Be 1
        $scan.found.filesWithAppTokens | Should -Be 1
        $clean = Invoke-DemoSignInSweep -Clean $true -Folder $machine -EventLogReader $script:noEvents
        $clean.pass | Should -BeTrue
        $clean.actions.filesRedacted | Should -Be 1
        [System.IO.File]::ReadAllText($log) | Should -Be 'token [REDACTED]'
    }

    It 'classifies a token it can''t decode, and a token-named JSON property, as sign-in data' {
        $machine = New-TestMachine
        $garbled = ('ey' + 'J') + ('A' * 12) + '.' + ('!' * 3) + ('B' * 12) + '.' + ('C' * 12)
        $odd = ('ey' + 'J') + ('A' * 12) + '.' + ('B' * 13) + '.' + ('C' * 12)
        $refresh = 'r1' + ([guid]::NewGuid().ToString('N')) + ([guid]::NewGuid().ToString('N'))
        Write-TestFile -Path ([System.IO.Path]::Combine($machine.Windows, 'Temp', 'cache.json')) -Text ('{{"refresh_token": "{0}", "other": "{1}", "id": "{2}"}}' -f $refresh, $odd, $garbled) | Out-Null
        $scan = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents
        $scan.pass | Should -BeFalse
        $scan.found.otherTokens | Should -Be 2 -Because 'the undecodable token and the refresh token property'
        ($scan | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($refresh))
        $clean = Invoke-DemoSignInSweep -Clean $true -Folder $machine -EventLogReader $script:noEvents
        $clean.pass | Should -BeTrue
        [System.IO.File]::ReadAllText([System.IO.Path]::Combine($machine.Windows, 'Temp', 'cache.json')) | Should -Match '"refresh_token": "\[REDACTED\]"'
    }

    It 'counts the Security log apart and never clears it without an explicit request, and fails closed when another log isn''t cleared' {
        $machine = New-TestMachine
        $events = @{ 'Security' = @(New-TestEventRecord -Text ('Process Command Line: tool.exe --value {0}' -f $script:userToken)) }
        $reader = { param($Name, $XPath) $null = $XPath; if ($events.ContainsKey($Name)) { $events[$Name] } }.GetNewClosure()
        $cleared = [System.Collections.Generic.List[string]]::new()
        $clearer = { param($Name) $cleared.Add($Name) }.GetNewClosure()
        $result = Invoke-DemoSignInSweep -Clean $true -Folder $machine -EventLogReader $reader -EventLogClearer $clearer
        $result.pass | Should -BeTrue -Because 'the Security log is reported apart, for an operator to clear'
        $result.remaining.securityLogTokens | Should -Be 1
        $result.remaining.eventLogUserTokens | Should -Be 0
        @($result.actions.eventLogsNotCleared) | Should -Be @('Security')
        $cleared.Count | Should -Be 0
        $withOptIn = Invoke-DemoSignInSweep -Clean $true -ClearSecurityLog $true -Folder $machine -EventLogReader $reader -EventLogClearer { param($Name) $cleared.Add($Name); $events.Remove($Name) }.GetNewClosure()
        $withOptIn.remaining.securityLogTokens | Should -Be 0
        @($cleared) | Should -Be @('Security')

        $events['Windows PowerShell'] = @(New-TestEventRecord -Text ('-Value {0}' -f $script:userToken))
        $noClear = Invoke-DemoSignInSweep -Clean $true -ClearEventLogs $false -Folder $machine -EventLogReader $reader -EventLogClearer $clearer
        $noClear.pass | Should -BeFalse
        @($noClear.actions.eventLogsNotCleared) | Should -Contain 'Windows PowerShell'
    }

    It 'clears a PowerShell or Application log that holds any token-shaped value, and leaves one without alone' {
        $machine = New-TestMachine
        $events = @{
            'Application'        = @(New-TestEventRecord -Text ('agent issued {0}' -f $script:appToken))
            'Windows PowerShell' = @(New-TestEventRecord -Text 'HostApplication=powershell.exe -File script.ps1 -Action Probe')
        }
        $reader = { param($Name, $XPath) $null = $XPath; if ($events.ContainsKey($Name)) { $events[$Name] } }.GetNewClosure()
        $cleared = [System.Collections.Generic.List[string]]::new()
        $result = Invoke-DemoSignInSweep -Clean $true -Folder $machine -EventLogReader $reader -EventLogClearer { param($Name) $cleared.Add($Name); $events.Remove($Name) }.GetNewClosure()
        $result.pass | Should -BeTrue
        $result.found.eventLogAppTokens | Should -Be 1
        @($cleared) | Should -Be @('Application') -Because 'only a log that holds a token-shaped value is cleared'
        $result.remaining.eventLogAppTokens | Should -Be 0
    }
    It 'checks the files inside an archive: a clean one passes and stays, and Clean deletes one that holds a token' {
        $machine = New-TestMachine
        $log = [System.IO.Path]::Combine($machine.ProgramFiles, 'Microsoft SQL Server', '160', 'Setup Bootstrap', 'Log', '20261023_175721')
        New-Item -ItemType Directory -Path $log -Force | Out-Null
        $cleanArchive = Join-Path -Path $log -ChildPath 'LogSet_clean.cab'
        $tokenArchive = Join-Path -Path $log -ChildPath 'LogSet_token.cab'
        foreach ($path in $cleanArchive, $tokenArchive) { [System.IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3)) }
        $contents = @{ 'LogSet_clean.cab' = 'Detail: nothing to find'; 'LogSet_token.cab' = ('Detail: value {0}' -f $script:userToken) }
        # Stands in for expand.exe: writes the archive's one file.
        $expander = { param($Source, $Destination) [System.IO.File]::WriteAllText((Join-Path -Path $Destination -ChildPath 'Detail.txt'), $contents[[System.IO.Path]::GetFileName($Source)]); $true }.GetNewClosure()

        $scan = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents -ArchiveExpander $expander
        $scan.found.archivesChecked | Should -Be 2
        $scan.found.archives | Should -Be 0 -Because 'both could be checked'
        $scan.found.userTokens | Should -Be 1
        $scan.pass | Should -BeFalse
        $inside = @($scan.locations | Where-Object { $_.kind -eq 'Archive' })
        [System.IO.Path]::GetFileName($inside[0].path) | Should -Be 'LogSet_token.cab'
        $inside[0].user | Should -Be 1
        ($scan | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($script:userToken))

        $result = Invoke-DemoSignInSweep -Clean $true -Folder $machine -EventLogReader $script:noEvents -ArchiveExpander $expander
        $result.pass | Should -BeTrue
        $result.actions.filesDeleted | Should -Be 1
        Test-Path -LiteralPath $cleanArchive | Should -BeTrue -Because 'a clean archive is left alone'
        Test-Path -LiteralPath $tokenArchive | Should -BeFalse
        @(Get-ChildItem -LiteralPath $machine.ExpandRoot -Force).Count | Should -Be 0 -Because 'each expansion folder is deleted right after'
    }

    It 'fails closed on an archive it can''t expand, until Clean deletes it' {
        $machine = New-TestMachine
        $archive = Join-Path -Path ([System.IO.Path]::Combine($machine.ProgramFiles, 'Microsoft SQL Server', '160', 'Setup Bootstrap', 'Log')) -ChildPath 'Old.7z'
        New-Item -ItemType Directory -Path (Split-Path -Path $archive -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($archive, [byte[]](55, 122, 188, 175))
        $scan = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents -ArchiveExpander { param($Source, $Destination) $null = $Source, $Destination; $false }
        $scan.found.archives | Should -Be 1
        $scan.pass | Should -BeFalse
        ($scan.locations | Where-Object { $_.location -eq 'SetupLogs' }).kind | Should -Be 'ArchiveUnverified'
        $result = Invoke-DemoSignInSweep -Clean $true -Folder $machine -EventLogReader $script:noEvents -ArchiveExpander { param($Source, $Destination) $null = $Source, $Destination; $false }
        $result.pass | Should -BeTrue
        Test-Path -LiteralPath $archive | Should -BeFalse
    }

    It 'expands a .zip and a .gz with .NET and checks their files' {
        $machine = New-TestMachine
        $log = [System.IO.Path]::Combine($machine.ProgramFiles, 'Microsoft SQL Server', '160', 'Setup Bootstrap', 'Log')
        New-Item -ItemType Directory -Path $log -Force | Out-Null
        $source = Join-Path -Path $TestDrive -ChildPath ('zip-' + [guid]::NewGuid().ToString('N'))
        Write-TestFile -Path (Join-Path -Path $source -ChildPath 'Summary.txt') -Text ('value {0}' -f $script:userToken) | Out-Null
        [System.IO.Compression.ZipFile]::CreateFromDirectory($source, (Join-Path -Path $log -ChildPath 'LogSet.zip'))
        $gzPath = Join-Path -Path $log -ChildPath 'Detail.txt.gz'
        $gzFile = [System.IO.File]::Create($gzPath)
        try {
            $gzip = [System.IO.Compression.GZipStream]::new($gzFile, [System.IO.Compression.CompressionMode]::Compress)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes('nothing to find')
            $gzip.Write($bytes, 0, $bytes.Length)
            $gzip.Dispose()
        }
        finally {
            $gzFile.Dispose()
        }
        $scan = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents
        $scan.found.archivesChecked | Should -Be 2
        $scan.found.archives | Should -Be 0
        $scan.found.userTokens | Should -Be 1
        [System.IO.Path]::GetFileName(@($scan.locations | Where-Object { $_.kind -eq 'Archive' })[0].path) | Should -Be 'LogSet.zip'
    }

    It 'expands a real .cab with Windows'' expand.exe' -Skip:(-not $IsWindows -or -not (Test-Path -LiteralPath (Join-Path -Path ([string]$env:windir) -ChildPath 'System32\makecab.exe'))) {
        $machine = New-TestMachine
        $log = [System.IO.Path]::Combine($machine.ProgramFiles, 'Microsoft SQL Server', '160', 'Setup Bootstrap', 'Log', '20261021_142008')
        New-Item -ItemType Directory -Path $log -Force | Out-Null
        $source = Write-TestFile -Path (Join-Path -Path $TestDrive -ChildPath ('cab-' + [guid]::NewGuid().ToString('N') + '\Detail.txt')) -Text ('value {0}' -f $script:userToken)
        $cab = Join-Path -Path $log -ChildPath 'LogSet_arcsql01.cab'
        $null = & (Join-Path -Path $env:windir -ChildPath 'System32\makecab.exe') $source $cab 2>&1
        Test-Path -LiteralPath $cab | Should -BeTrue
        $scan = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents
        $scan.found.archivesChecked | Should -Be 1
        $scan.found.userTokens | Should -Be 1
        $result = Invoke-DemoSignInSweep -Clean $true -Folder $machine -EventLogReader $script:noEvents
        $result.pass | Should -BeTrue
        Test-Path -LiteralPath $cab | Should -BeFalse
    }

    It 'clears a PowerShell log once more when a process wrote another token right after the first clearing' {
        $machine = New-TestMachine
        $state = @{ rounds = 0 }
        $events = @{ 'Windows PowerShell' = @(New-TestEventRecord -Text ('HostApplication=powershell.exe -Value {0}' -f $script:userToken)) }
        # The onboarding Run Command's PowerShell logs its engine stop with the same command line after the first clearing.
        $late = @(New-TestEventRecord -Text ('Engine stopped. HostApplication=powershell.exe -Value {0}' -f $script:userToken))
        $reader = { param($Name, $XPath) $null = $XPath; if ($events.ContainsKey($Name)) { $events[$Name] } }.GetNewClosure()
        $clearer = { param($Name) $state.rounds++; $events.Remove($Name); if ($state.rounds -eq 1) { $events[$Name] = $late } }.GetNewClosure()
        $result = Invoke-DemoSignInSweep -Clean $true -Folder $machine -EventLogReader $reader -EventLogClearer $clearer
        $result.pass | Should -BeTrue -Because 'the second round clears what the stopping process wrote'
        $state.rounds | Should -Be 2
        @($result.actions.eventLogsCleared) | Should -Be @('Windows PowerShell')
        $result.remaining.eventLogUserTokens | Should -Be 0
    }

    It 'finds a product key in a file and in the Windows PowerShell log, ignores placeholders and masked keys, and Clean removes both' {
        $machine = New-TestMachine
        # Built at run time, so no scanner sees a key-shaped value in the repository.
        $key = (@('Q7W2E', 'R9T4Y', 'U6I8O', 'P3A5S', 'D1F0G') -join '-')
        $placeholder = (@('XXXXX') * 5) -join '-'
        $freeEdition = (@('22222') + @('00000') * 4) -join '-'
        $masked = (@('XXXXX') * 4 + @('D1F0G')) -join '-'
        $file = Write-TestFile -Path ([System.IO.Path]::Combine($machine.ProgramData, 'DbHubDemo', 'logs', 'install.log')) -Text ("key {0}`nexample {1}`nedition {2}`nlicense {3}`n" -f $key, $placeholder, $freeEdition, $masked)
        $events = @{ 'Windows PowerShell' = @(New-TestEventRecord -Text ('HostApplication=powershell.exe -File script.ps1 -ProductKey {0}' -f $key)) }
        $reader = { param($Name, $XPath) $null = $XPath; if ($events.ContainsKey($Name)) { $events[$Name] } }.GetNewClosure()
        $scan = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $reader
        $scan.found.productKeys | Should -Be 1 -Because 'a placeholder, a free edition''s identifier, and a masked key aren''t keys'
        $scan.found.eventLogKeys | Should -Be 1
        $scan.pass | Should -BeFalse
        ($scan | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($key))
        (ConvertTo-DemoSignInSummary -Sweep $scan).eventLogs[0] | Should -Match '^Windows PowerShell\|u0 a0 o0 k1\|'

        $result = Invoke-DemoSignInSweep -Clean $true -Folder $machine -EventLogReader $reader -EventLogClearer { param($Name) $events.Remove($Name) }.GetNewClosure()
        $result.pass | Should -BeTrue
        @($result.actions.eventLogsCleared) | Should -Be @('Windows PowerShell')
        [System.IO.File]::ReadAllText($file) | Should -Not -Match ([regex]::Escape($key))
    }

    It 'counts a file it can''t read in setup''s log folders as unverified, which fails the result' {
        $machine = New-TestMachine
        $log = [System.IO.Path]::Combine($machine.ProgramFiles, 'Microsoft SQL Server', '160', 'Setup Bootstrap', 'Log')
        Write-TestFile -Path (Join-Path -Path $log -ChildPath 'Detail.txt') -Text ('x' * 2048) | Out-Null
        $result = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents -MaxFileBytes 1024
        $result.pass | Should -BeFalse
        $result.found.filesUnverified | Should -Be 1
        ($result.locations | Where-Object { $_.kind -eq 'TooLarge' }).location | Should -Be 'SetupLogs'
    }

    It 'passes on a machine with nothing to find, and reads no browser cache unless asked' {
        $machine = New-TestMachine
        Write-TestFile -Path ([System.IO.Path]::Combine($machine.Users, 'dbhubadmin', 'AppData', 'Local', 'EBWebView', 'x.txt')) -Text 'x' | Out-Null
        $result = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents
        $result.pass | Should -BeTrue
        $result.found.browserCaches | Should -Be 0
        (Invoke-DemoSignInSweep -IncludeBrowserCache $true -Folder $machine -EventLogReader $script:noEvents).pass | Should -BeFalse
    }

    It 'fails closed on automatic sign-in left armed: AutoAdminLogon, the LSA secret, or the Winlogon values (Phase 28)' {
        $machine = New-TestMachine
        foreach ($leftover in @(@{ Enabled = 1; Secret = 0; PlainValue = 0; UserName = 0 }, @{ Enabled = 0; Secret = 1; PlainValue = 0; UserName = 0 }, @{ Enabled = 0; Secret = 0; PlainValue = 1; UserName = 0 })) {
            $script:autoState = $leftover
            $result = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents -AutoLogonProvider { param($Mode) $null = $Mode; $script:autoState }
            $result.pass | Should -BeFalse -Because ('the leftover {0} blocks a golden capture' -f (($leftover.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key }) -join ','))
        }
        # DefaultUserName counts only where the setup wizard signs in (IncludeBrowserCache): elsewhere Windows writes it as
        # the last console user.
        $userOnly = { param($Mode) $null = $Mode; @{ Enabled = 0; Secret = 0; PlainValue = 0; UserName = 1 } }
        (Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents -AutoLogonProvider $userOnly).pass | Should -BeTrue
        (Invoke-DemoSignInSweep -IncludeBrowserCache $true -Folder $machine -EventLogReader $script:noEvents -AutoLogonProvider $userOnly).pass | Should -BeFalse
    }

    It 'fails closed when automatic sign-in can''t be read, and Clean turns it off and removes the secret and the values' {
        $machine = New-TestMachine
        (Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents -AutoLogonProvider { param($Mode) $null = $Mode; throw 'access denied' }).pass | Should -BeFalse
        $script:modes = [System.Collections.Generic.List[string]]::new()
        $script:armed = $true
        $provider = {
            param($Mode)
            $script:modes.Add($Mode)
            if ($Mode -eq 'Clear') {
                $script:armed = $false
            }
            $on = [int]$script:armed
            @{ Enabled = $on; Secret = $on; PlainValue = 0; UserName = $on }
        }
        $result = Invoke-DemoSignInSweep -Clean $true -IncludeBrowserCache $true -Folder $machine -EventLogReader $script:noEvents -EventLogClearer { param($Name) $null = $Name } -AutoLogonProvider $provider
        $result.pass | Should -BeTrue
        $script:modes | Should -Contain 'Clear'
        $summary = ConvertTo-DemoSignInSummary -Sweep $result
        $summary.actions.autologon | Should -Be 1
        $summary.actions.logonName | Should -Be 1
        $summary.found.autologon | Should -BeGreaterThan 0
        $summary.remaining.autologon | Should -Be 0
    }
}

Describe 'Invoke-DemoSignInResidue.ps1 as a Run Command script' {
    It 'refuses an unknown action before reading anything, and prints one JSON line without a value' {
        $script = Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoSignInResidue.ps1'
        $output = & pwsh -NoProfile -NonInteractive -File $script -ResidueAction 'Erase' 2>$null
        $LASTEXITCODE | Should -Be 1
        $json = @($output)[-1] | ConvertFrom-Json
        $json.succeeded | Should -BeFalse
        $json.error | Should -Match 'Unknown action Erase'
    }

    It 'summarizes a sweep in counts and shortened locations, never a value' {
        $token = New-TestToken -Claim @{ scp = 'x'; upn = 'someone@example.com' }
        $machine = New-TestMachine
        foreach ($index in 1..30) {
            Write-TestFile -Path ([System.IO.Path]::Combine($machine.Windows, 'Temp', ('a-very-long-folder-name-for-the-test-{0:D2}' -f $index), 'setup.log')) -Text ('x {0}' -f $token) | Out-Null
        }
        $sweep = Invoke-DemoSignInSweep -Folder $machine -EventLogReader $script:noEvents
        $summary = ConvertTo-DemoSignInSummary -Sweep $sweep -MaxLocations 6
        $summary.pass | Should -BeFalse
        $summary.found.user | Should -Be 30
        @($summary.found_at).Count | Should -Be 6
        @($summary.found_at)[0] | Should -Match '^Temp\|File\|u1 a0 o0 k0\|'
        $line = ConvertTo-Json -InputObject ([ordered]@{ local = $summary; guest = $summary }) -Compress -Depth 6
        $line.Length | Should -BeLessThan 3800 -Because 'the instance view keeps only the last 4 KB of output'
        $line | Should -Not -Match ([regex]::Escape($token.Split('.')[2].Substring(0, 30)))
        (ConvertTo-DemoSignInSummary -Sweep ([pscustomobject]@{ reachable = $false; state = 'Off'; pass = $false })).state | Should -Be 'Off'
    }
}
