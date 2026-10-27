BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/DbHubDemo.Vm.psd1') -Force
    $healthSchema = Join-Path -Path $repoRoot -ChildPath 'vm/health/health.schema.json'

    function New-TestRoot {
        $path = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Initialize-DemoVmContext -Root $path -Role 'ArcHost' | Out-Null
        return $path
    }

    function Read-TestJson([string] $Path) {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'VM state store' {
    It 'starts with a NotStarted state and round-trips it through state.json' {
        $root = New-TestRoot
        $state = Get-DemoVmState
        $state['state'] | Should -Be 'NotStarted'
        $record = Get-DemoVmStepRecord -State $state -Name 'One'
        $record['attempts'] = 2
        $record['lastError'] = 'boom'
        Save-DemoVmState -State $state

        $again = Get-DemoVmState
        $again['steps']['One']['attempts'] | Should -Be 2
        $again['steps']['One']['lastError'] | Should -Be 'boom'
        (Read-TestJson (Join-Path -Path $root -ChildPath 'state.json')).role | Should -Be 'ArcHost'
    }

    It 'redacts secrets and SAS query strings from state.json' {
        $root = New-TestRoot
        Register-DemoVmSecret -Value 'Pa55-For-Test-Only'
        $state = Get-DemoVmState
        $state['message'] = 'failed with Pa55-For-Test-Only at https://st1.blob.core.windows.net/artifacts/b.zip?sv=1&sig=' + ('Q' * 20)
        Save-DemoVmState -State $state
        $text = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'state.json') -Raw
        $text | Should -Not -Match 'Pa55-For-Test-Only'
        $text | Should -Not -Match 'QQQQQQQQ'
        $text | Should -Match 'b.zip\?\[REDACTED\]'
    }
}

Describe 'VM lock' {
    It 'lets one run hold the lock and turns a second run away' {
        New-TestRoot | Out-Null
        $first = Enter-DemoVmLock
        try {
            $first | Should -Not -BeNullOrEmpty
            Enter-DemoVmLock | Should -BeNullOrEmpty
        }
        finally {
            Exit-DemoVmLock -Lock $first
        }
        $second = Enter-DemoVmLock
        $second | Should -Not -BeNullOrEmpty
        Exit-DemoVmLock -Lock $second
    }
}

Describe 'VM step runner' {
    BeforeEach {
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRestart -MockWith { }
    }

    It 'runs steps in order, skips steps already in the desired state, and reaches Ready' {
        $root = New-TestRoot
        $marker = Join-Path -Path $root -ChildPath 'b.txt'
        $steps = @(
            @{ Name = 'A'; Test = { $true }; Set = { throw 'A must not run' } }
            @{ Name = 'B'; Context = @{ Marker = $marker }; Test = { param($Step) Test-Path -LiteralPath $Step.Context.Marker }; Set = { param($Step) Set-Content -LiteralPath $Step.Context.Marker -Value 'x' } }
        )
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'Ready'
        $state = Get-DemoVmState
        $state['steps']['A']['status'] | Should -Be 'Succeeded'
        $state['steps']['B']['status'] | Should -Be 'Succeeded'
        $state['completedUtc'] | Should -Not -BeNullOrEmpty
    }

    It 'restarts for a reboot step and resumes after the restart without repeating finished steps' {
        $root = New-TestRoot
        $script:installs = 0
        $script:installed = $false
        $steps = @(
            @{ Name = 'Before'; Test = { $true }; Set = { } }
            @{ Name = 'Role'; Test = { $script:installed }; Set = { $script:installs++; New-DemoVmStepResult -Outcome 'RebootRequired' } }
            @{ Name = 'After'; Test = { $true }; Set = { } }
        )
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'RebootPending'
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRestart -Times 1 -Exactly
        $state = Get-DemoVmState
        $state['pendingReboot'] | Should -BeTrue
        $state['steps']['Role']['status'] | Should -Be 'RebootPending'
        (Read-TestJson (Join-Path -Path $root -ChildPath 'health.json')).state | Should -Be 'RebootPending'

        # The restart finished the install.
        $script:installed = $true
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'Ready'
        $script:installs | Should -Be 1
        $state = Get-DemoVmState
        $state['pendingReboot'] | Should -BeFalse
        $state['rebootCount'] | Should -Be 1
    }

    It 'fails a step that keeps asking for restarts' {
        New-TestRoot | Out-Null
        $steps = @(@{ Name = 'Loop'; Test = { $false }; Set = { New-DemoVmStepResult -Outcome 'RebootRequired' } })
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' -MaxRebootsPerStep 1 | Should -Be 'RebootPending'
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' -MaxRebootsPerStep 1 | Should -Be 'InProgress'
        (Get-DemoVmState)['steps']['Loop']['lastError'] | Should -Match 'more than 1 restarts'
    }

    It 'retries a failing step on the next run and marks it Failed after MaxAttempts' {
        $root = New-TestRoot
        $steps = @(@{ Name = 'Flaky'; MaxAttempts = 2; Test = { $false }; Set = { throw 'transient failure' } })
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'InProgress'
        (Get-DemoVmState)['steps']['Flaky']['status'] | Should -Be 'Retrying'
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'Failed'
        $health = Read-TestJson (Join-Path -Path $root -ChildPath 'health.json')
        $health.status | Should -Be 'Fail'
        $health.message | Should -Match 'transient failure'
        # Failed stays failed until the next generation, which re-checks every step.
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'Failed'
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g2' | Should -Be 'InProgress'
    }

    It 'replaces the previous run''s health.json while a step converges' {
        $root = New-TestRoot
        $healthPath = Join-Path -Path $root -ChildPath 'health.json'
        $failing = @(@{ Name = 'Long'; MaxAttempts = 1; Test = { $false }; Set = { throw 'old failure' } })
        Invoke-DemoVmStateMachine -Step $failing -Generation 'g1' | Should -Be 'Failed'
        (Read-TestJson $healthPath).status | Should -Be 'Fail'

        $script:during = $null
        $steps = @(@{ Name = 'Long'; Context = @{ Path = $healthPath }; Test = { $script:during }; Set = { param($Step) $script:during = Get-Content -LiteralPath $Step.Context.Path -Raw | ConvertFrom-Json -AsHashtable } })
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g2' | Should -Be 'Ready'
        $script:during.state | Should -Be 'InProgress'
        $script:during.status | Should -Be 'Warning'
        $script:during.generation | Should -Be 'g2'
        $script:during.currentStep | Should -Be 'Long'
        $script:during.message | Should -Be 'Step Long is converging (attempt 1 of 3).'
        $script:during.message | Should -Not -Match 'old failure'
    }

    It 'stops at a wait step without counting attempts, and continues once the condition is met' {
        $root = New-TestRoot
        $script:arcConnected = $false
        $steps = @(
            @{ Name = 'Arc'; Test = { $script:arcConnected }; Set = { New-DemoVmStepResult -Outcome 'Waiting' -WaitState 'WaitingForArcOnboarding' -Message 'Waiting for Arc.' } }
            @{ Name = 'Next'; Test = { $true }; Set = { } }
        )
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'WaitingForArcOnboarding'
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'WaitingForArcOnboarding'
        (Get-DemoVmState)['steps']['Arc']['attempts'] | Should -Be 0
        (Read-TestJson (Join-Path -Path $root -ChildPath 'health.json')).status | Should -Be 'Warning'
        $script:arcConnected = $true
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'Ready'
    }

    It 'reports Manual action required with instructions' {
        $root = New-TestRoot
        $steps = @(@{ Name = 'Wizard'; Test = { $false }; Set = { New-DemoVmStepResult -Outcome 'ManualActionRequired' -Message 'Run the wizard.' -Instruction @('Step one', 'Step two') } })
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'ManualActionRequired'
        $health = Read-TestJson (Join-Path -Path $root -ChildPath 'health.json')
        $health.status | Should -Be 'Manual action required'
        $health.instructions | Should -Be @('Step one', 'Step two')
    }

    It 'marks steps whose When is false as NotSelected and never runs them' {
        New-TestRoot | Out-Null
        $steps = @(
            @{ Name = 'Runner'; When = { $false }; NotSelectedMessage = 'Phase 11.'; Test = { throw 'no' }; Set = { throw 'no' } }
            @{ Name = 'Mode'; Mode = 'Developer'; Context = @{ Mode = 'PaygWizard' }; When = { param($Step) $Step.Context.Mode -eq $Step.Mode }; Test = { throw 'no' }; Set = { throw 'no' } }
        )
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'Ready'
        (Get-DemoVmState)['steps']['Runner']['status'] | Should -Be 'NotSelected'
        (Get-DemoVmState)['steps']['Mode']['status'] | Should -Be 'NotSelected'
    }

    It 'fails a step whose Set ran but whose check still fails' {
        New-TestRoot | Out-Null
        $steps = @(@{ Name = 'Stubborn'; MaxAttempts = 1; Test = { $false }; Set = { } })
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'Failed'
        (Get-DemoVmState)['steps']['Stubborn']['lastError'] | Should -Match 'check still fails'
    }

    It 'keeps step warnings, such as trust on first use, and reports Warning when Ready' {
        $root = New-TestRoot
        $steps = @(@{ Name = 'Media'; Test = { $false }; Set = { New-DemoVmStepResult -Outcome 'NotSelected' -Message 'x' -WarningMessage 'Trusted on first use.' } })
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' | Should -Be 'Ready'
        $health = Read-TestJson (Join-Path -Path $root -ChildPath 'health.json')
        $health.status | Should -Be 'Warning'
        $health.warnings | Should -Contain 'Trusted on first use.'
    }

    It 'writes health.json that matches vm/health/health.schema.json' {
        $root = New-TestRoot
        $steps = @(@{ Name = 'A'; Test = { $true }; Set = { } })
        Invoke-DemoVmStateMachine -Step $steps -Generation 'g1' -HealthDetail { [ordered]@{ guest = [ordered]@{ state = 'Running' } } } | Out-Null
        $json = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'health.json') -Raw
        Test-Json -Json $json -SchemaFile $healthSchema | Should -BeTrue
        ($json | ConvertFrom-Json).details.guest.state | Should -Be 'Running'
    }
}

Describe 'Verified downloads' {
    It 'keeps a download whose SHA-256 matches the pin' {
        $root = New-TestRoot
        $content = [System.Text.Encoding]::UTF8.GetBytes('pinned media')
        $expected = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($content)).ToLowerInvariant()
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmWebDownload -MockWith { [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::UTF8.GetBytes('pinned media')) }
        $target = Join-Path -Path $root -ChildPath 'media/file.iso'
        $result = Save-DemoVmDownload -Uri 'https://download.example.invalid/file.iso' -Path $target -ExpectedSha256 $expected -Name 'file'
        $result.Sha256 | Should -Be $expected
        $result.TrustOnFirstUse | Should -BeFalse
        Test-DemoVmFileHash -Path $target -ExpectedSha256 $expected | Should -BeTrue
    }

    It 'fails closed on a SHA-256 mismatch and deletes the download' {
        $root = New-TestRoot
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmWebDownload -MockWith { [System.IO.File]::WriteAllBytes($Path, [byte[]](1, 2, 3)) }
        $target = Join-Path -Path $root -ChildPath 'media/file.iso'
        { Save-DemoVmDownload -Uri 'https://download.example.invalid/file.iso' -Path $target -ExpectedSha256 ('0' * 64) -Name 'file' } | Should -Throw '*mismatch*fail closed*'
        Test-Path -LiteralPath $target | Should -BeFalse
        Test-Path -LiteralPath ($target + '.partial') | Should -BeFalse
    }

    It 'trusts the first download without a pin, warns, and fails closed if the hash later changes' {
        $root = New-TestRoot
        $script:payload = [byte[]](7, 7, 7)
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmWebDownload -MockWith { [System.IO.File]::WriteAllBytes($Path, $script:payload) }
        $target = Join-Path -Path $root -ChildPath 'media/eval.iso'
        $first = Save-DemoVmDownload -Uri 'https://download.example.invalid/eval.iso' -Path $target -ExpectedSha256 '' -Name 'eval'
        $first.TrustOnFirstUse | Should -BeTrue
        $first.Warning | Should -Match 'trusted and recorded'
        Test-DemoVmFileHash -Path $target -Name 'eval' | Should -BeTrue

        $script:payload = [byte[]](8, 8, 8)
        { Save-DemoVmDownload -Uri 'https://download.example.invalid/eval.iso' -Path $target -ExpectedSha256 '' -Name 'eval' } | Should -Throw '*changed since first use*'
    }

    It 'reports a changed file as not matching its pin' {
        $root = New-TestRoot
        $target = Join-Path -Path $root -ChildPath 'plain.bin'
        [System.IO.File]::WriteAllBytes($target, [byte[]](1, 2))
        Test-DemoVmFileHash -Path $target -ExpectedSha256 ('a' * 64) | Should -BeFalse
        Test-DemoVmFileHash -Path (Join-Path -Path $root -ChildPath 'missing.bin') -ExpectedSha256 ('a' * 64) | Should -BeFalse
    }
}

Describe 'Download retries and resume' {
    BeforeAll {
        $script:media = [byte[]](1..250)
        $script:mediaSha = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($script:media)).ToLowerInvariant()
        $mediaUri = 'https://download.example.invalid/media.iso'

        function Add-TestMediaSlice([string] $Path, [int] $Offset, [int] $Count) {
            # What a resumed (206) response does: append to the partial file.
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append)
            try {
                $stream.Write($script:media, $Offset, $Count)
            }
            finally {
                $stream.Dispose()
            }
        }
    }

    BeforeEach {
        $script:offsets = [System.Collections.Generic.List[long]]::new()
        Mock -ModuleName DbHubDemo.Vm -CommandName Start-Sleep -MockWith { }
    }

    It 'retries a dropped download with backoff and resumes from the bytes already downloaded' {
        $root = New-TestRoot
        $target = Join-Path -Path $root -ChildPath 'media/media.iso'
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmWebDownload -MockWith {
            $script:offsets.Add($Offset)
            if ($script:offsets.Count -eq 1) {
                Add-TestMediaSlice -Path $Path -Offset 0 -Count 100
                throw 'The underlying connection was closed: An unexpected error occurred on a receive.'
            }
            Add-TestMediaSlice -Path $Path -Offset ([int]$Offset) -Count (250 - [int]$Offset)
            [pscustomobject]@{ StatusCode = 206; Resumed = $true }
        }

        $result = Save-DemoVmDownload -Uri $mediaUri -Path $target -ExpectedSha256 $script:mediaSha -Name 'media'

        $script:offsets | Should -Be @(0, 100)
        $result.Sha256 | Should -Be $script:mediaSha
        Test-DemoVmFileHash -Path $target -ExpectedSha256 $script:mediaSha | Should -BeTrue
        Test-Path -LiteralPath ($target + '.partial') | Should -BeFalse
        Test-Path -LiteralPath ($target + '.partial.source') | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 15 }
    }

    It 'keeps the partial file after the last attempt fails, and the next run resumes it' {
        $root = New-TestRoot
        $target = Join-Path -Path $root -ChildPath 'media/media.iso'
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmWebDownload -MockWith {
            $script:offsets.Add($Offset)
            Add-TestMediaSlice -Path $Path -Offset ([int]$Offset) -Count 10
            throw 'The operation has timed out.'
        }

        { Save-DemoVmDownload -Uri $mediaUri -Path $target -ExpectedSha256 $script:mediaSha -Name 'media' -MaxAttempts 3 } | Should -Throw '*failed after 3 attempts*partial file is kept*'

        $script:offsets | Should -Be @(0, 10, 20)
        (Get-Item -LiteralPath ($target + '.partial')).Length | Should -Be 30
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 15 }
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }

        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmWebDownload -MockWith {
            $script:offsets.Add($Offset)
            Add-TestMediaSlice -Path $Path -Offset ([int]$Offset) -Count (250 - [int]$Offset)
            [pscustomobject]@{ StatusCode = 206; Resumed = $true }
        }
        Save-DemoVmDownload -Uri $mediaUri -Path $target -ExpectedSha256 $script:mediaSha -Name 'media' | Out-Null
        $script:offsets[-1] | Should -Be 30
        Test-DemoVmFileHash -Path $target -ExpectedSha256 $script:mediaSha | Should -BeTrue
    }

    It 'discards a partial file that another URL left behind' {
        $root = New-TestRoot
        $target = Join-Path -Path $root -ChildPath 'media/media.iso'
        New-Item -ItemType Directory -Path (Split-Path -Path $target -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($target + '.partial', [byte[]](9, 9, 9, 9))
        [System.IO.File]::WriteAllText($target + '.partial.source', 'https://download.example.invalid/older.iso')
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmWebDownload -MockWith {
            $script:offsets.Add($Offset)
            Add-TestMediaSlice -Path $Path -Offset 0 -Count 250
            [pscustomobject]@{ StatusCode = 200; Resumed = $false }
        }

        Save-DemoVmDownload -Uri $mediaUri -Path $target -ExpectedSha256 $script:mediaSha -Name 'media' | Out-Null

        $script:offsets | Should -Be @(0)
        Test-DemoVmFileHash -Path $target -ExpectedSha256 $script:mediaSha | Should -BeTrue
    }

    It 'fails closed when the resumed file does not match the pin, and deletes it so the next run starts over' {
        $root = New-TestRoot
        $target = Join-Path -Path $root -ChildPath 'media/media.iso'
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmWebDownload -MockWith {
            [System.IO.File]::WriteAllBytes($Path, [byte[]](1, 2, 3))
            [pscustomobject]@{ StatusCode = 200; Resumed = $false }
        }

        { Save-DemoVmDownload -Uri $mediaUri -Path $target -ExpectedSha256 $script:mediaSha -Name 'media' } | Should -Throw '*mismatch*fail closed*'

        Test-Path -LiteralPath $target | Should -BeFalse
        Test-Path -LiteralPath ($target + '.partial') | Should -BeFalse
        Test-Path -LiteralPath ($target + '.partial.source') | Should -BeFalse
    }
}

Describe 'VM helpers' {
    It 'splits T-SQL on GO lines like sqlcmd' {
        $script = "SELECT 1;`r`nGO`r`n`r`nSELECT 2;`nGO -- comment`nSELECT 'GO' AS word;`n go`n"
        $batches = Split-DemoVmSqlBatch -Script $script
        $batches.Count | Should -Be 3
        $batches[2] | Should -Be "SELECT 'GO' AS word;"
    }

    It 'generates strong passwords that start with a letter and are redacted' {
        New-TestRoot | Out-Null
        $passwords = 1..20 | ForEach-Object { Build-DemoVmPassword }
        foreach ($password in $passwords) {
            $password.Length | Should -Be 24
            $password | Should -Match '^[A-Za-z]'
            $password | Should -MatchExactly '[A-Z]'
            $password | Should -MatchExactly '[a-z]'
            $password | Should -Match '[0-9]'
            $password | Should -Match '[!#%*+\-=?^_~]'
            $password | Should -Not -Match '[&<>"''`$\\ @;|]'
            Protect-DemoVmText -Text "x $password y" | Should -Be 'x [REDACTED] y'
        }
        @($passwords | Select-Object -Unique).Count | Should -Be 20
    }

    It 'redacts product keys, tokens, and /PID switches' {
        $key = (@('ABCDE', 'FGHIJ', 'KLMNO', 'PQRST', 'UVWXY') -join '-')
        Protect-DemoVmText -Text "setup.exe /Q /PID=`"$key`" /ACTION=Install" | Should -Not -Match 'ABCDE'
        $jwt = 'ey' + 'J' + ('a' * 20) + '.' + 'ey' + 'J' + ('b' * 20) + '.' + ('c' * 20)
        Protect-DemoVmText -Text "azcmagent connect --access-token $jwt" | Should -Not -Match 'aaaaaaaaaa'
    }

    It 'formats the data disk once, using stub storage cmdlets' {
        New-TestRoot | Out-Null
        # Storage cmdlets exist only on Windows, so stubs are defined before they're mocked. Their parameters
        # exist only so that Mock can copy them for the parameter filters.
        function global:Get-Volume { }
        function global:Get-Disk { }
        function global:Set-Disk {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub for Mock.')]
            param($Number, $IsOffline, $IsReadOnly)
        }
        function global:Initialize-Disk {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub for Mock.')]
            param($Number, $PartitionStyle)
        }
        function global:New-Partition {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub for Mock.')]
            param($DiskNumber, [switch] $UseMaximumSize, $DriveLetter, [switch] $AssignDriveLetter)
        }
        function global:Format-Volume {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub for Mock.')]
            [CmdletBinding(SupportsShouldProcess)]
            param($Partition, $FileSystem, $NewFileSystemLabel, $AllocationUnitSize)
            if ($PSCmdlet.ShouldProcess('stub')) { }
        }
        try {
            Mock -ModuleName DbHubDemo.Vm -CommandName Get-Volume -MockWith { @() }
            Mock -ModuleName DbHubDemo.Vm -CommandName Get-Disk -MockWith {
                @([pscustomobject]@{ Number = 2; PartitionStyle = 'RAW'; Location = 'Integrated : Adapter 3 : Port 0 : Target 0 : LUN 0'; IsOffline = $false; IsReadOnly = $false })
            }
            Mock -ModuleName DbHubDemo.Vm -CommandName Initialize-Disk -MockWith { }
            Mock -ModuleName DbHubDemo.Vm -CommandName New-Partition -MockWith { [pscustomobject]@{ PartitionNumber = 2 } }
            Mock -ModuleName DbHubDemo.Vm -CommandName Format-Volume -MockWith { [pscustomobject]@{ DriveLetter = 'F'; FileSystemLabel = 'DbHubData' } }

            $volume = Initialize-DemoVmDataDisk -Label 'DbHubData' -DriveLetter 'F' -Lun 0
            $volume.DriveLetter | Should -Be 'F'
            Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Initialize-Disk -Times 1 -Exactly -ParameterFilter { $Number -eq 2 -and $PartitionStyle -eq 'GPT' }
            Should -Invoke -ModuleName DbHubDemo.Vm -CommandName New-Partition -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'F' }
        }
        finally {
            foreach ($name in 'Get-Volume', 'Get-Disk', 'Set-Disk', 'Initialize-Disk', 'New-Partition', 'Format-Volume') {
                Remove-Item -Path "Function:\global:$name" -ErrorAction SilentlyContinue
            }
        }
    }
}
