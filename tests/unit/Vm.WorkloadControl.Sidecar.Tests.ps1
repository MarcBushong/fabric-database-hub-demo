# The Query Store sidecar's actions in the VM's control script (2026-11-23; rca/README.md, The sidecar, Transport, and
# Versioning): RcaSidecarExport, RcaAck, and a sidecar's parts through the Rca action, held to the contract's command
# lines and lines. The evidence document's own actions are tested in Vm.WorkloadSteps.Tests.ps1.

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoWorkloadControl.ps1')
    # GuestVm.ps1's functions exist here too, so Pester can mock the guest's credential (the T2 relay loads that file only
    # when they're missing).
    . (Join-Path -Path $repoRoot -ChildPath 'vm/hyperv-guest/GuestVm.ps1')

    $rcaRoot = Join-Path -Path $repoRoot -ChildPath 'rca'
    $fixtures = Join-Path -Path $rcaRoot -ChildPath 'fixtures'
    $script:transport = Get-Content -LiteralPath (Join-Path -Path $rcaRoot -ChildPath 'transport.schema.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:sidecarSchema = Get-Content -LiteralPath (Join-Path -Path $rcaRoot -ChildPath 'sidecar.schema.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:session = '5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21'
    $script:sidecarIndexLine = 'DBHUBDEMO-RCAS-INDEX ' + (Get-Content -LiteralPath (Join-Path -Path $fixtures -ChildPath 'sidecar-index.json') -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 5 -Compress)
    $script:evidenceIndexLine = 'DBHUBDEMO-RCA-INDEX ' + (Get-Content -LiteralPath (Join-Path -Path $fixtures -ChildPath 'export-index.json') -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 5 -Compress)
    $readParts = { param([string] $Like, [bool] $Sidecar) @(Get-ChildItem -LiteralPath $fixtures -File | Where-Object { $_.Name -like $Like -and ($_.Name -like '*.sidecar-parts.txt') -eq $Sidecar } | ForEach-Object { Get-Content -LiteralPath $_.FullName } | Where-Object { $_ }) }
    $script:sidecarParts = & $readParts '*.sidecar-parts.txt' $true
    $script:evidenceParts = & $readParts '*.parts.txt' $false
    # The same window's two kinds: an evidence document and its sidecar, whose IDs differ only by -sidecar.
    $firstPart = { param([string[]] $Lines, [string] $DocumentId) $Lines | Where-Object { $_.Split(' ')[2] -ceq $DocumentId -and $_.Split(' ')[3].StartsWith('1/', [System.StringComparison]::Ordinal) } | Select-Object -First 1 }
    $script:evidencePart = & $firstPart $script:evidenceParts '20261120T165000Z-sqlvm01-0001'
    $script:sidecarPart = & $firstPart $script:sidecarParts '20261120T165000Z-sqlvm01-0001-sidecar'

    function New-ControlRoot([string] $Role = 'SqlVm', [switch] $NoInstall) {
        $root = Join-Path -Path $TestDrive -ChildPath ('control-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $settings = [ordered]@{ role = $Role; workload = [ordered]@{ runnerSha256 = ('ab' * 32); runnerChunkCount = 7; activityProfile = 'baseline'; autoShutdownTime = '1900'; autoShutdownTimeZone = 'UTC' } }
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'settings.json') -Value ($settings | ConvertTo-Json -Depth 5)
        if (-not $NoInstall) {
            $dotnet = Join-Path -Path $root -ChildPath 'dotnet.exe'
            $runner = Join-Path -Path $root -ChildPath 'ContosoCare.Workload.dll'
            Set-Content -LiteralPath $dotnet -Value 'host'
            Set-Content -LiteralPath $runner -Value 'runner'
            $install = [ordered]@{ primaryTarget = 'T1'; runnerDll = $runner; dotnetExe = $dotnet }
            Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-install.json') -Value ($install | ConvertTo-Json -Depth 5)
        }
        return $root
    }

    function ConvertTo-Request([hashtable] $Request) {
        [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Depth 5 -Compress)))
    }

    function Get-Result {
        $script:lines[0] | Should -Match '^DBHUBDEMO-WORKLOAD \{'
        $script:lines[0].Substring('DBHUBDEMO-WORKLOAD '.Length) | ConvertFrom-Json
    }

    function New-LongSidecarId([int] $Sequence, [int] $HostLength = 58) {
        # 58 characters of host make the longest ID a sidecar may have: 88 (sidecar.schema.json, documentId).
        '20261120T165000Z-{0}-{1:0000}-sidecar' -f ('h' * $HostLength), $Sequence
    }

    function New-FullIndexLine([int] $Length = 3400) {
        # One page of 8 sidecars with the longest IDs, brought to Length with the whitespace JSON allows before its last brace.
        $documents = foreach ($sequence in 1..8) {
            [ordered]@{ documentId = (New-LongSidecarId -Sequence $sequence); sessionId = $script:session; parts = 28; sha256 = (('{0:x2}' -f $sequence) * 32); state = 'pending' }
        }
        $index = [ordered]@{ kind = 'ContosoCare.RcaSidecarIndex'; version = 1; page = 1; pages = 3; documents = @($documents); status = 'Pass'; message = '8 of 20 sidecars, all from an earlier session that no save had acknowledged.' }
        $line = 'DBHUBDEMO-RCAS-INDEX ' + (ConvertTo-Json -InputObject $index -Depth 5 -Compress)
        return $line.Substring(0, $line.Length - 1) + (' ' * ($Length - $line.Length)) + '}'
    }

    function New-FullPartLine([int] $Length = 3400) {
        # Part 1 of 28 of the longest ID; its Base64 fills the rest (3,224 characters at 3,400, which is whole Base64).
        $prefix = 'DBHUBDEMO-RCAS 1 {0} 1/28 {1} ' -f (New-LongSidecarId -Sequence 1), ('01' * 32)
        return $prefix + ('A' * ($Length - $prefix.Length))
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'Invoke-DemoWorkloadControl.ps1: the Query Store sidecar''s actions (rca/README.md, The sidecar)' {
    BeforeEach {
        $script:lines = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-DemoControlLine -MockWith { $script:lines.Add($Line) }
    }

    Context 'the lines it takes' {
        It 'takes a sidecar''s part line and ID as rca/transport.schema.json defines them, at most 88 characters' {
            $script:ControlRcaSidecarPartPattern | Should -BeExactly $script:transport['$defs']['sidecarPartLine']['pattern']
            $script:ControlRcaSidecarIdPattern | Should -BeExactly $script:transport['$defs']['sidecarId']['pattern']
            $script:sidecarSchema['$defs']['documentId']['maxLength'] | Should -Be 88
            (New-LongSidecarId -Sequence 1).Length | Should -Be 88
            Test-DemoControlRcaSidecarId -Value (New-LongSidecarId -Sequence 1) | Should -BeTrue
            Test-DemoControlRcaSidecarId -Value (New-LongSidecarId -Sequence 1 -HostLength 59) | Should -BeFalse -Because 'an 89-character ID matches the pattern, but not the document''s length'
            Test-DemoControlRcaSidecarId -Value '20261120T165000Z-sqlvm01-0001' | Should -BeFalse
        }

        It 'never takes a sidecar''s line for an evidence document''s, or an evidence document''s for a sidecar''s' {
            $script:sidecarParts.Count | Should -BeGreaterOrEqual 4
            $script:evidenceParts.Count | Should -BeGreaterOrEqual 4
            foreach ($line in $script:sidecarParts) {
                $line | Should -MatchExactly $script:ControlRcaSidecarPartPattern
                $line | Should -Not -MatchExactly $script:ControlRcaPartPattern
            }
            foreach ($line in $script:evidenceParts) {
                $line | Should -MatchExactly $script:ControlRcaPartPattern
                $line | Should -Not -MatchExactly $script:ControlRcaSidecarPartPattern
            }
            # Each marker with the other kind's ID matches neither pattern.
            foreach ($line in @(($script:sidecarPart -creplace '^DBHUBDEMO-RCAS ', 'DBHUBDEMO-RCA '), ($script:evidencePart -creplace '^DBHUBDEMO-RCA ', 'DBHUBDEMO-RCAS '))) {
                $line | Should -Not -MatchExactly $script:ControlRcaPartPattern
                $line | Should -Not -MatchExactly $script:ControlRcaSidecarPartPattern
            }
            # And each index line goes only to its own action.
            $both = $script:evidenceIndexLine + "`r`n" + $script:sidecarIndexLine + "`r`n"
            Get-DemoControlRcaLine -Text $both -Command 'export' | Should -BeExactly $script:evidenceIndexLine
            Get-DemoControlRcaSidecarLine -Text $both -Command 'sidecar-export' | Should -BeExactly $script:sidecarIndexLine
            Get-DemoControlRcaSidecarLine -Text $script:evidenceIndexLine -Command 'sidecar-export' | Should -BeExactly ''
        }

        It 'relays the sidecar''s part asked for through the Rca action, and each kind''s request takes only its own line' {
            $root = New-ControlRoot
            $script:runnerOut = $script:evidencePart + "`r`n" + $script:sidecarPart + "`r`n"
            Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:runnerOut; StdErr = '' } }
            Invoke-DemoWorkloadControl -ActionName 'Rca' -Request (ConvertTo-Request @{ command = 'part'; documentId = '20261120T165000Z-sqlvm01-0001-sidecar'; part = 1 }) -StateRoot $root
            (Get-Result).status | Should -Be 'Pass'
            $script:lines.Count | Should -Be 2
            $script:lines[1] | Should -BeExactly $script:sidecarPart
            Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'rca part --document 20261120T165000Z-sqlvm01-0001-sidecar --part 1' -and $TimeoutSeconds -eq 120 }
            $script:lines.Clear()
            Invoke-DemoWorkloadControl -ActionName 'Rca' -Request (ConvertTo-Request @{ command = 'part'; documentId = '20261120T165000Z-sqlvm01-0001'; part = 1 }) -StateRoot $root
            (Get-Result).status | Should -Be 'Pass'
            $script:lines[1] | Should -BeExactly $script:evidencePart
            # The other kind's line alone is no answer.
            foreach ($case in @(@{ Id = '20261120T165000Z-sqlvm01-0001-sidecar'; Out = $script:evidencePart }, @{ Id = '20261120T165000Z-sqlvm01-0001'; Out = $script:sidecarPart })) {
                $script:lines.Clear()
                $script:runnerOut = $case.Out
                Invoke-DemoWorkloadControl -ActionName 'Rca' -Request (ConvertTo-Request @{ command = 'part'; documentId = $case.Id; part = 1 }) -StateRoot $root
                $script:lines.Count | Should -Be 1
                (Get-Result).status | Should -Be 'Fail'
            }
        }

        It 'answers an action it doesn''t know with its list, which names both sidecar actions' {
            Invoke-DemoWorkloadControl -ActionName 'RcaSidecarImport' -Request '' -StateRoot (New-ControlRoot)
            $result = Get-Result
            $result.status | Should -Be 'Fail'
            $result.message | Should -BeExactly 'Unknown action; use EnableT3, EnableT4, Runner, StopGuest, Rca, RcaSidecarExport, or RcaAck.'
        }
    }

    Context 'RcaSidecarExport' {
        It 'fetches the index with the session''s ID, --final and --page, and prints the runner''s index line last, whole' {
            $root = New-ControlRoot
            Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = ("sealed 1 span`r`n" + $script:sidecarIndexLine + "`r`n"); StdErr = '' } }
            Invoke-DemoWorkloadControl -ActionName 'RcaSidecarExport' -Request (ConvertTo-Request @{ sessionId = $script:session; final = $true; page = 2 }) -StateRoot $root
            $script:lines.Count | Should -Be 2
            $result = Get-Result
            $result.action | Should -Be 'RcaSidecarExport'
            $result.status | Should -Be 'Pass'
            $result.evidence.command | Should -Be 'sidecar-export'
            $script:lines[1] | Should -BeExactly $script:sidecarIndexLine
            Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq ('rca sidecar-export --session {0} --final --page 2' -f $script:session) -and $TimeoutSeconds -eq 600 }
            # Outside a control session: no session, and --final only for true itself.
            $script:lines.Clear()
            Invoke-DemoWorkloadControl -ActionName 'RcaSidecarExport' -Request (ConvertTo-Request @{ final = 'true' }) -StateRoot $root
            Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'rca sidecar-export --session none' }
        }

        It 'passes on the runner''s exit code, 0 or 2, and is Not selected, with its line, when there''s nothing to fetch' {
            $root = New-ControlRoot
            $script:exportRun = [pscustomobject]@{ ExitCode = 0; StdOut = $script:sidecarIndexLine; StdErr = '' }
            Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { $script:exportRun }
            Invoke-DemoWorkloadControl -ActionName 'RcaSidecarExport' -Request (ConvertTo-Request @{}) -StateRoot $root
            (Get-Result).status | Should -Be 'Pass'
            (Get-Result).evidence.exitCode | Should -Be 0
            $empty = 'DBHUBDEMO-RCAS-INDEX {"kind":"ContosoCare.RcaSidecarIndex","version":1,"page":1,"pages":0,"documents":[],"status":"Pass","message":"No sidecar to fetch."}'
            foreach ($output in @($empty, '')) {
                $script:lines.Clear()
                $script:exportRun = [pscustomobject]@{ ExitCode = 2; StdOut = $output; StdErr = '' }
                Invoke-DemoWorkloadControl -ActionName 'RcaSidecarExport' -Request (ConvertTo-Request @{}) -StateRoot $root
                $result = Get-Result
                $result.status | Should -Be 'Not selected'
                $result.evidence.exitCode | Should -Be 2
                if ($output) {
                    $script:lines.Count | Should -Be 2
                    $script:lines[1] | Should -BeExactly $output
                }
                else {
                    $script:lines.Count | Should -Be 1
                }
            }
            # Any other exit code, or an answer without the index line, fails.
            foreach ($run in @(
                    [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'The sidecar store is locked by another export.' }
                    [pscustomobject]@{ ExitCode = 0; StdOut = 'sealed 1 span'; StdErr = '' }
                    [pscustomobject]@{ ExitCode = 0; StdOut = ($script:sidecarIndexLine + ' tail'); StdErr = '' }
                )) {
                $script:lines.Clear()
                $script:exportRun = $run
                Invoke-DemoWorkloadControl -ActionName 'RcaSidecarExport' -Request (ConvertTo-Request @{}) -StateRoot $root
                $script:lines.Count | Should -Be 1
                $result = Get-Result
                $result.status | Should -Be 'Fail'
                $result.evidence.exitCode | Should -Be $run.ExitCode
            }
            # A VM whose runner isn't installed yet holds no sidecar.
            $script:lines.Clear()
            Invoke-DemoWorkloadControl -ActionName 'RcaSidecarExport' -Request (ConvertTo-Request @{}) -StateRoot (New-ControlRoot -NoInstall)
            (Get-Result).status | Should -Be 'Not selected'
        }
    }

    Context 'RcaAck' {
        It 'acknowledges up to 64 sidecars in one --document list, each once, and relays the runner''s last line' {
            $root = New-ControlRoot
            $script:ackLine = 'Acknowledged 64 sidecars; the runner no longer offers them.'
            Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = ("opened the sidecar store`r`n" + $script:ackLine + "`r`n"); StdErr = '' } }
            $ids = @(1..64 | ForEach-Object { New-LongSidecarId -Sequence $_ })
            Invoke-DemoWorkloadControl -ActionName 'RcaAck' -Request (ConvertTo-Request @{ documentIds = $ids }) -StateRoot $root
            $result = Get-Result
            $result.action | Should -Be 'RcaAck'
            $result.status | Should -Be 'Pass'
            $result.evidence.documents | Should -Be 64
            $script:lines.Count | Should -Be 2
            $script:lines[1] | Should -BeExactly $script:ackLine
            Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq ('rca ack --document ' + ($ids -join ',')) -and $TimeoutSeconds -eq 120 }
            # One ID may arrive as a string, and an ID listed twice is sent once.
            foreach ($given in @('20261120T165000Z-sqlvm01-0001-sidecar', @('20261120T165000Z-sqlvm01-0001-sidecar', '20261120T165000Z-sqlvm01-0001-sidecar'))) {
                $script:lines.Clear()
                Invoke-DemoWorkloadControl -ActionName 'RcaAck' -Request (ConvertTo-Request @{ documentIds = $given }) -StateRoot $root
                (Get-Result).evidence.documents | Should -Be 1
            }
            Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 2 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'rca ack --document 20261120T165000Z-sqlvm01-0001-sidecar' }
        }

        It 'relays no last line that would pass for its own result line, or that''s over 3,400 characters, and still passes on exit code 0' {
            $root = New-ControlRoot
            Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:ackOut; StdErr = '' } }
            foreach ($last in @('DBHUBDEMO-WORKLOAD {"status":"Pass"}', ('x' * 3401))) {
                $script:lines.Clear()
                $script:ackOut = "Acknowledged 1 sidecar.`r`n" + $last
                Invoke-DemoWorkloadControl -ActionName 'RcaAck' -Request (ConvertTo-Request @{ documentIds = @('20261120T165000Z-sqlvm01-0001-sidecar') }) -StateRoot $root
                $script:lines.Count | Should -Be 1
                (Get-Result).status | Should -Be 'Pass'
            }
        }

        It 'acknowledges T2''s sidecars in its guest on archost01, without making the guest ready or restarting it' {
            $root = New-ControlRoot -Role 'ArcHost' -NoInstall
            Mock -CommandName Invoke-DemoControlT2Attempt -MockWith { [pscustomobject]@{ Run = [pscustomobject]@{ ExitCode = 0; StdOut = 'Acknowledged 1 sidecar.'; StdErr = '' }; ReadyNote = [ordered]@{}; Failure = $null } }
            Mock -CommandName Invoke-DemoControlT2Recovery -MockWith { throw 'must not restart the guest' }
            Invoke-DemoWorkloadControl -ActionName 'RcaAck' -Request (ConvertTo-Request @{ documentIds = @('20261120T165000Z-arcsql01-0001-sidecar') }) -StateRoot $root
            $result = Get-Result
            $result.status | Should -Be 'Pass'
            $result.evidence.guest | Should -Be 'arcsql01'
            Should -Invoke -CommandName Invoke-DemoControlT2Attempt -Times 1 -Exactly -ParameterFilter { -not $Activity -and ($Arguments -join ' ') -eq 'rca ack --document 20261120T165000Z-arcsql01-0001-sidecar' -and $GuestName -eq 'arcsql01' -and $LockSeconds -eq 30 -and $TimeoutSeconds -eq 120 }
        }
    }

    Context 'requests outside the contract' {
        It 'refuses IDs outside sidecarId''s pattern, more than 64 of them, or none, and runs nothing' {
            $root = New-ControlRoot
            Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { throw 'must not run' }
            $requests = @(
                @{ documentIds = @('20261120T165000Z-sqlvm01-0001') }
                @{ documentIds = @('20261120T165000Z-SQLVM01-0001-sidecar') }
                @{ documentIds = @((New-LongSidecarId -Sequence 1 -HostLength 59)) }
                @{ documentIds = @('../20261120T165000Z-sqlvm01-0001-sidecar') }
                @{ documentIds = @('20261120T165000Z-sqlvm01-0001-sidecar,--session none') }
                @{ documentIds = @('20261120T165000Z-sqlvm01-0001-sidecar --final') }
                @{ documentIds = @('20261120T165000Z-sqlvm01-0001-sidecar', 7) }
                @{ documentIds = @{ documentId = '20261120T165000Z-sqlvm01-0001-sidecar' } }
                @{ documentIds = @() }
                @{ documentIds = $null }
                @{}
                @{ documentIds = @(1..65 | ForEach-Object { New-LongSidecarId -Sequence $_ }) }
            )
            foreach ($request in $requests) {
                $script:lines.Clear()
                Invoke-DemoWorkloadControl -ActionName 'RcaAck' -Request (ConvertTo-Request $request) -StateRoot $root
                $script:lines.Count | Should -Be 1
                $result = Get-Result
                $result.status | Should -Be 'Fail' -Because ($request | ConvertTo-Json -Compress)
                $result.message | Should -Match '^The request''s documentIds must '
            }
            Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 0
        }

        It 'refuses an export''s session or page, or a part''s sidecar ID, outside the contract, and runs nothing' {
            $root = New-ControlRoot
            Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { throw 'must not run' }
            $cases = @(
                @{ Action = 'RcaSidecarExport'; Request = @{ sessionId = $script:session.ToUpperInvariant() }; Why = 'sessionId' }
                @{ Action = 'RcaSidecarExport'; Request = @{ sessionId = 'none; whoami' }; Why = 'sessionId' }
                @{ Action = 'RcaSidecarExport'; Request = @{ page = 0 }; Why = 'page' }
                @{ Action = 'RcaSidecarExport'; Request = @{ page = 1000 }; Why = 'page' }
                @{ Action = 'RcaSidecarExport'; Request = @{ page = -1 }; Why = 'page' }
                @{ Action = 'RcaSidecarExport'; Request = @{ page = 2.5 }; Why = 'page' }
                @{ Action = 'RcaSidecarExport'; Request = @{ page = '2 --final' }; Why = 'page' }
                @{ Action = 'RcaSidecarExport'; Request = @{ page = $true }; Why = 'page' }
                @{ Action = 'Rca'; Request = @{ command = 'part'; documentId = (New-LongSidecarId -Sequence 1 -HostLength 59); part = 1 }; Why = 'documentId' }
                @{ Action = 'Rca'; Request = @{ command = 'part'; documentId = '20261120T165000Z-SQLVM01-0001-sidecar'; part = 1 }; Why = 'documentId' }
                @{ Action = 'Rca'; Request = @{ command = 'part'; documentId = '20261120T165000Z-sqlvm01-0001-sidecar --final'; part = 1 }; Why = 'documentId' }
            )
            foreach ($case in $cases) {
                $script:lines.Clear()
                Invoke-DemoWorkloadControl -ActionName $case.Action -Request (ConvertTo-Request $case.Request) -StateRoot $root
                $script:lines.Count | Should -Be 1
                $result = Get-Result
                $result.status | Should -Be 'Fail' -Because ($case.Request | ConvertTo-Json -Compress)
                $result.message | Should -Match ('^The request''s {0} ' -f $case.Why)
            }
            Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 0
        }
    }

    Context 'T2, relayed by archost01 from its guest over PowerShell Direct (L5)' {
        BeforeEach {
            $secure = [System.Security.SecureString]::new()
            foreach ($character in 'not-a-real-secret'.ToCharArray()) {
                $secure.AppendChar($character)
            }
            $script:guestCredential = [System.Management.Automation.PSCredential]::new('Administrator', $secure)
            Mock -CommandName Get-DemoGuestCredential -MockWith { $script:guestCredential }
            Mock -CommandName Enter-DemoControlBootstrapLock -MockWith { [pscustomobject]@{ Stream = [System.IO.MemoryStream]::new(); Seconds = 0; TimedOut = $false } }
            Mock -CommandName Invoke-DemoControlGuestReady -MockWith { throw 'must not make the guest ready' }
            Mock -CommandName Invoke-DemoControlT2Recovery -MockWith { throw 'must not restart the guest' }
            $script:guestRuns = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Invoke-DemoControlGuestCommand -MockWith {
                $script:guestRuns.Add((@($ArgumentList[1]) -join ' '))
                # The runner's own log lines around its one line, so the line is in neither the first nor the last 1,800
                # characters; then serialized and rebuilt, as PowerShell Direct hands the guest's object back.
                $before = @(1..30 | ForEach-Object { 'observer: sealed span {0:00} of T2 into sidecars' -f $_ }) -join "`r`n"
                $after = @(1..30 | ForEach-Object { 'store: span {0:00} kept until its sidecar is acknowledged' -f $_ }) -join "`r`n"
                $run = [pscustomobject]@{ ExitCode = 0; StdOut = ($before + "`r`n" + $script:guestLine + "`r`n" + $after + "`r`n"); StdErr = '' }
                [System.Management.Automation.PSSerializer]::Deserialize([System.Management.Automation.PSSerializer]::Serialize($run))
            }
        }

        It 'relays an index line of 8 sidecars with the longest IDs, and a sidecar''s part line, each 3,400 characters, whole and within 4 KB' {
            $root = New-ControlRoot -Role 'ArcHost' -NoInstall
            $index = New-FullIndexLine
            $part = New-FullPartLine
            $index.Length | Should -Be 3400
            $part.Length | Should -Be 3400
            @(($index.Substring('DBHUBDEMO-RCAS-INDEX '.Length) | ConvertFrom-Json).documents | Where-Object { $_.documentId.Length -eq 88 }).Count | Should -Be 8
            $part | Should -MatchExactly $script:ControlRcaSidecarPartPattern
            $cases = @(
                @{ Action = 'RcaSidecarExport'; Request = @{ sessionId = $script:session; final = $true }; Line = $index; Arguments = ('rca sidecar-export --session {0} --final' -f $script:session) }
                @{ Action = 'Rca'; Request = @{ command = 'part'; documentId = (New-LongSidecarId -Sequence 1); part = 1 }; Line = $part; Arguments = ('rca part --document {0} --part 1' -f (New-LongSidecarId -Sequence 1)) }
            )
            foreach ($case in $cases) {
                $script:lines.Clear()
                $script:guestRuns.Clear()
                $script:guestLine = $case.Line
                Invoke-DemoWorkloadControl -ActionName $case.Action -Request (ConvertTo-Request $case.Request) -StateRoot $root
                $script:lines.Count | Should -Be 2
                $result = Get-Result
                $result.status | Should -Be 'Pass' -Because $result.message
                $result.evidence.guest | Should -Be 'arcsql01'
                $script:lines[1] | Should -BeExactly $case.Line
                $script:guestRuns.Count | Should -Be 1
                $script:guestRuns[0] | Should -BeExactly $case.Arguments
                # A managed Run Command keeps the last 4,096 bytes of output: both lines, as the VM writes them.
                [System.Text.Encoding]::UTF8.GetByteCount((($script:lines | ForEach-Object { $_ + "`r`n" }) -join '')) | Should -BeLessOrEqual 4096
            }
        }

        It 'relays no line of 3,401 characters, which the 4 KB could cut' {
            $root = New-ControlRoot -Role 'ArcHost' -NoInstall
            $cases = @(
                @{ Action = 'RcaSidecarExport'; Request = @{}; Line = (New-FullIndexLine -Length 3401) }
                @{ Action = 'Rca'; Request = @{ command = 'part'; documentId = (New-LongSidecarId -Sequence 1); part = 1 }; Line = (New-FullPartLine -Length 3401) }
            )
            foreach ($case in $cases) {
                $script:lines.Clear()
                $script:guestLine = $case.Line
                Invoke-DemoWorkloadControl -ActionName $case.Action -Request (ConvertTo-Request $case.Request) -StateRoot $root
                $script:lines.Count | Should -Be 1
                $result = Get-Result
                $result.status | Should -Be 'Fail'
                $result.message | Should -Match 'no line the contract allows'
            }
        }
    }
}
