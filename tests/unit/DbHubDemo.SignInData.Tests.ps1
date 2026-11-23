BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        return $config
    }

    function New-TestPart {
        # One machine's part of the sweep's compact output (ConvertTo-DemoSignInSummary).
        param([bool] $Pass = $true, [int] $User = 0, [int] $App = 0, [int] $LogUser = 0, [int] $Caches = 0, [int] $LeftUser = 0, [int] $Security = 0, [string[]] $Cleared = @())
        $counts = { param([int] $U, [int] $A, [int] $L, [int] $C, [int] $S) [ordered]@{ scanned = 10; user = $U; other = 0; app = $A; files = [int]($U -gt 0); archives = 0; caches = $C; unverified = 0; logUser = $L; logApp = 0; security = $S } }
        [ordered]@{
            computer  = 'VM'
            reachable = $true
            pass      = $Pass
            found     = & $counts $User $App $LogUser $Caches $Security
            remaining = & $counts $LeftUser 0 0 0 $Security
            actions   = [ordered]@{ redacted = 0; deleted = 0; failed = 0; caches = 0; broker = 0; logsCleared = $Cleared; logsNotCleared = @() }
            eventLogs = @()
            found_at  = @('SetupLogs|File|u1 a0 o0|...\Log\x\Example.xml')
            left_at   = @()
            seconds   = 12
        }
    }

    function New-TestOutcome {
        param([object] $Local, [object] $Guest = $null, [string] $Action = 'Scan')
        $data = [ordered]@{ action = $Action; scope = 'Both'; succeeded = $true; pass = $true; local = $Local; guest = $Guest }
        [pscustomobject]@{ Succeeded = $true; Data = ($data | ConvertTo-Json -Depth 8 | ConvertFrom-Json); Error = ''; Seconds = 40 }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoSignInDataResult' {
    It 'passes when nothing is left on the host and in its guest' {
        $result = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local (New-TestPart) -Guest (New-TestPart)) } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'SECURITY.SIGNIN.ARCHOST01' -Area 'security' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $O
        }
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'archost01 and arcsql01 \(guest\)'
    }

    It 'fails closed when sign-in data from a person is left, naming what and where, never a value' {
        $guest = New-TestPart -Pass $false -User 2 -LeftUser 2
        $result = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local (New-TestPart) -Guest $guest -Action 'Clean') } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'SECURITY.SIGNIN.ARCHOST01' -Area 'security' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $O
        }
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'After the cleanup, sign-in data is left \(fail closed\): arcsql01 \(guest\): 2 sign-in token\(s\) in 1 file\(s\)'
        $result.evidence['arcsql01 (guest)'].foundAt | Should -Contain 'SetupLogs|File|u1 a0 o0|...\Log\x\Example.xml'
    }

    It 'fails closed when the guest couldn''t be reached, or the sweep couldn''t run' {
        $unreachable = [ordered]@{ reachable = $false; pass = $false; state = 'Off' }
        $result = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local (New-TestPart) -Guest $unreachable) } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'TEST.SIGNIN' -Area 'security' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $O
        }
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'couldn''t be reached \(Off\)'
        $failed = InModuleScope DbHubDemo {
            Get-DemoSignInDataResult -CheckId 'TEST.SIGNIN' -Area 'security' -Target 'T1' -VmName 'sqlvm01' -Outcome ([pscustomobject]@{ Succeeded = $false; Data = $null; Error = 'Conflict'; Seconds = 3 })
        }
        $failed.status | Should -Be 'Fail'
        $failed.message | Should -Match 'treated as left \(fail closed\)'
    }

    It 'asks for manual action, with the exact command, when the Security log holds a token-shaped value' {
        $result = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local (New-TestPart -Security 1) -Guest (New-TestPart)) } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'SECURITY.SIGNIN.ARCHOST01' -Area 'security' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $O
        }
        $result.status | Should -Be 'Manual action required'
        $result.remediation | Should -Match ([regex]::Escape('./scripts/check-sign-in-data.ps1 -VmName archost01 -Clean -ClearSecurityLog'))
        $result.remediation | Should -Match 'wevtutil clear-log Security'
    }

    It 'warns that endpoint protection may report it when the cleanup cleared an event log' {
        $result = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local (New-TestPart -LogUser 1 -Cleared @('Windows PowerShell')) -Guest (New-TestPart) -Action 'Clean') } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'SECURITY.SIGNIN.ARCHOST01' -Area 'security' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $O
        }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'cleared Windows PowerShell on archost01, which endpoint protection may report'
    }

    It 'warns, without failing, when only an application''s or a managed identity''s token was found' {
        $result = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local (New-TestPart -App 3)) } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'SECURITY.SIGNIN.SQLVM01' -Area 'security' -Target 'T1' -VmName 'sqlvm01' -Outcome $O
        }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match '3 token\(s\) of an application or a managed identity'
    }

    It 'passes with a note, not "left armed", when the cleanup deleted only the LSA secret Azure''s provisioning leaves (live finding, 2026-11-06)' {
        $hostPart = New-TestPart
        $hostPart.found['loneSecret'] = 1
        $hostPart.actions['loneSecret'] = 1
        $result = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local $hostPart -Guest (New-TestPart) -Action 'Clean') } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $O
        }
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'The cleanup deleted the LSA secret DefaultPassword that Azure''s provisioning leaves on archost01; automatic sign-in was off\.$'
        $result.message | Should -Not -Match 'armed'
        $result.evidence['note'] | Should -Match 'on archost01;'

        # T1 is reported the same way.
        $t1 = New-TestPart
        $t1.found['loneSecret'] = 1
        $t1.actions['loneSecret'] = 1
        $sqlvm = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local $t1 -Action 'Clean') } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'SECURITY.SIGNIN.SQLVM01' -Area 'security' -Target 'T1' -VmName 'sqlvm01' -Outcome $O
        }
        $sqlvm.status | Should -Be 'Pass'
        $sqlvm.message | Should -Match 'that Azure''s provisioning leaves on sqlvm01; automatic sign-in was off'

        # Azure doesn't provision the nested guest, so the note there doesn't say where the secret came from.
        $guestPart = New-TestPart
        $guestPart.found['loneSecret'] = 1
        $guestPart.actions['loneSecret'] = 1
        $guest = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local (New-TestPart) -Guest $guestPart -Action 'Clean') } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'SECURITY.SIGNIN.ARCHOST01' -Area 'security' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $O
        }
        $guest.status | Should -Be 'Pass'
        $guest.message | Should -Match 'deleted a leftover LSA secret DefaultPassword on arcsql01 \(guest\)'
    }

    It 'keeps the Warning when automatic sign-in really was armed, and still notes a lone secret elsewhere' {
        $guestPart = New-TestPart
        $guestPart.found['autologon'] = 2
        $guestPart.actions['autologon'] = 1
        $hostPart = New-TestPart
        $hostPart.found['loneSecret'] = 1
        $hostPart.actions['loneSecret'] = 1
        $result = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local $hostPart -Guest $guestPart -Action 'Clean') } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $O
        }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match '^Windows automatic sign-in was left armed on arcsql01 \(guest\), and the cleanup turned it off'
        $result.message | Should -Match 'The cleanup deleted the LSA secret DefaultPassword that Azure''s provisioning leaves on archost01'
        $result.remediation | Should -Match 'guided stop'
    }

    It 'fails a read-only scan that finds the lone LSA secret, and names it accurately' {
        $part = New-TestPart -Pass $false
        $part.found['loneSecret'] = 1
        $part.remaining['loneSecret'] = 1
        $result = InModuleScope DbHubDemo -Parameters @{ O = (New-TestOutcome -Local $part) } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'SECURITY.SIGNIN.SQLVM01' -Area 'security' -Target 'T1' -VmName 'sqlvm01' -Outcome $O
        }
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'sqlvm01: the LSA secret DefaultPassword, a stored password nothing needs \(automatic sign-in is off'
        $result.message | Should -Not -Match 'left armed'
        $result.remediation | Should -Match '-Clean'
    }

    It 'says why the guest couldn''t be reached, with PowerShell Direct''s own error and what its recovery did (2026-11-19, dbhubfn)' {
        # Live, the status page said only "couldn't be reached (Running)".
        $guest = [ordered]@{ reachable = $false; pass = $false; state = 'Running'; error = 'The Hyper-V socket target process has ended. (PSSessionStateBroken)' }
        $outcome = New-TestOutcome -Local (New-TestPart) -Guest $guest -Action 'Clean'
        $outcome.Data | Add-Member -NotePropertyName 'guestRecovery' -NotePropertyValue ([pscustomobject]@{ action = 'Busy'; restarted = $false; recovered = $false; ranAgain = $false; message = 'Another restart of arcsql01 held the host''s recovery lock for 20 minutes, so it wasn''t restarted again.' })
        $result = InModuleScope DbHubDemo -Parameters @{ O = $outcome } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $O
        }
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'arcsql01 \(guest\) couldn''t be reached \(Running: The Hyper-V socket target process has ended\. \(PSSessionStateBroken\)\)'
        $result.message | Should -Match 'It didn''t run once more: Another restart of arcsql01 held the host''s recovery lock'
        $result.evidence['arcsql01 (guest)'].error | Should -Match 'PSSessionStateBroken'
        $result.evidence['arcsql01 (guest)'].state | Should -Be 'Running'
        $result.evidence.guestRecovery.action | Should -Be 'Busy'
    }

    It 'fails closed, sweeping nothing, when the host''s own bootstrap pass held its lock past the bound (2026-11-19)' {
        $busy = [ordered]@{ reachable = $false; pass = $false; state = 'Busy'; error = 'The host bootstrap held its lock (bootstrap.lock) for 1800 seconds, so nothing was swept beside its own sign-in cleanup.' }
        $outcome = New-TestOutcome -Local $busy -Guest $busy -Action 'Clean'
        $outcome.Data | Add-Member -NotePropertyName 'lock' -NotePropertyValue ([pscustomobject]@{ minutes = 30; seconds = 1800; timedOut = $true })
        $result = InModuleScope DbHubDemo -Parameters @{ O = $outcome } {
            param($O)
            Get-DemoSignInDataResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -VmName 'archost01' -GuestName 'arcsql01' -Outcome $O -Remediation 'Run ./scripts/deploy.ps1 again.'
        }
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'wasn''t checked, so it''s treated as left \(fail closed\): archost01''s own bootstrap pass held its lock for 30 minutes'
        $result.evidence.lockTimedOut | Should -BeTrue
        $result.evidence.lockSeconds | Should -Be 1800
        $result.remediation | Should -Be 'Run ./scripts/deploy.ps1 again.'
    }
}

Describe 'Invoke-DemoSignInDataAction' {
    BeforeEach {
        $script:sent = $null
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            $script:sent = [pscustomobject]@{ Parameter = $PesterBoundParameters['Parameter']; TimeoutSeconds = $PesterBoundParameters['TimeoutSeconds'] }
            [pscustomobject]@{ Succeeded = $true; Output = '{"action":"Scan","succeeded":true,"pass":true}'; Error = ''; ExecutionState = 'Succeeded'; ExitCode = 0 }
        }
    }

    It 'has a guest sweep wait for the host''s own bootstrap pass and recover the guest for the run, with the time that takes; a local one neither (2026-11-19)' {
        InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } {
            param($C)
            Set-DemoRunRecoveryKey -Key 'deploy-cccccccccccc'
            try {
                $null = Invoke-DemoSignInDataAction -Config $C -VmName 'archost01' -Action 'Clean' -Scope 'Both'
            }
            finally {
                Set-DemoRunRecoveryKey -Key ''
            }
        }
        $script:sent.Parameter['ResidueLockMinutes'] | Should -Be '20'
        $script:sent.Parameter['RecoveryKey'] | Should -Be 'deploy-cccccccccccc'
        $script:sent.TimeoutSeconds | Should -Be 4800 -Because 'the wait comes before the sweep, its tries, and a restart of the guest'

        InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { param($C) $null = Invoke-DemoSignInDataAction -Config $C -VmName 'archost01' -Action 'Clean' -Scope 'Both' -LockMinutes 30 -RecoveryKey '' }
        $script:sent.Parameter['ResidueLockMinutes'] | Should -Be '30'
        $script:sent.Parameter.Contains('RecoveryKey') | Should -BeFalse
        $script:sent.TimeoutSeconds | Should -Be 5400

        InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { param($C) $null = Invoke-DemoSignInDataAction -Config $C -VmName 'sqlvm01' -Action 'Scan' -Scope 'Local' }
        $script:sent.Parameter.Contains('ResidueLockMinutes') | Should -BeFalse
        $script:sent.Parameter.Contains('RecoveryKey') | Should -BeFalse
        $script:sent.TimeoutSeconds | Should -Be 2400
    }
}

Describe 'check-sign-in-data.ps1 where no one can answer its question (the final tests'' F9, 2026-11-19)' {
    It 'stops at once with the same command and -Force, checking and changing nothing, instead of waiting on the question' {
        # Live, a launcher's -Clean waited 7.5 minutes on its confirmation, with nothing on the screen.
        $script = Join-Path -Path $repoRoot -ChildPath 'scripts/check-sign-in-data.ps1'
        $configPath = Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json'
        $outputPath = Join-Path -Path $TestDrive -ChildPath 'check-sign-in-data.jsonl'
        $previous = $env:CI
        # CI is one of the signs that no one can answer (Test-DemoInteractiveSession); so is redirected input.
        $env:CI = 'true'
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $printed = & pwsh -NoProfile -File $script -ConfigPath $configPath -VmName archost01 -Clean -OutputPath $outputPath *>&1
            $exitCode = $LASTEXITCODE
            $watch.Stop()
        }
        finally {
            $env:CI = $previous
        }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 60 -Because 'it never waits on the question'
        $exitCode | Should -Be 0 -Because 'Manual action required, as init.ps1 where it can''t ask'
        $records = @(Get-Content -LiteralPath $outputPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $records.Count | Should -Be 1 -Because 'nothing was checked: no guard, no Run Command'
        $records[0].checkId | Should -Be 'SECURITY.SIGNIN.CONFIRM'
        $records[0].status | Should -Be 'Manual action required'
        $records[0].remediation | Should -Match ([regex]::Escape(('Run ./scripts/check-sign-in-data.ps1 -ConfigPath "{0}" -VmName archost01 -Clean -Force to clean without asking' -f $configPath)))
        ($printed -join "`n") | Should -Match 'SECURITY\.SIGNIN\.CONFIRM'
    }
}

Describe 'Find-DemoSignInData' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:runs = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { if ($VmName -eq 'sqlvm01') { 'PowerState/deallocated' } else { 'PowerState/running' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            # Strict mode (static validation sets it): a parameter the caller didn't pass isn't a variable here.
            $bound = $PesterBoundParameters
            $VmName = $bound['VmName']
            $Parameter = $bound['Parameter']
            $script:runs.Add([pscustomobject]@{ VmName = $VmName; Name = $bound['RunCommandName']; Parameter = $Parameter; Protected = $(if ($bound.ContainsKey('ProtectedParameter')) { $bound['ProtectedParameter'] } else { $null }); Script = $bound['Script'] })
            $part = [ordered]@{ computer = $VmName; reachable = $true; pass = $true; found = [ordered]@{ user = 0; other = 0; app = 0; files = 0; archives = 0; caches = 0; unverified = 0; logUser = 0; logApp = 0 }; remaining = [ordered]@{ user = 0; other = 0; app = 0; files = 0; archives = 0; caches = 0; unverified = 0; logUser = 0; logApp = 0 }; eventLogs = @(); found_at = @(); left_at = @(); seconds = 5 }
            $line = [ordered]@{ action = $Parameter['ResidueAction']; scope = $Parameter['ResidueScope']; succeeded = $true; pass = $true; local = $part; guest = $part } | ConvertTo-Json -Compress -Depth 6
            [pscustomobject]@{ Succeeded = $true; Output = "scan`n$line"; Error = ''; ExecutionState = 'Succeeded'; ExitCode = 0 }
        }
    }

    It 'checks the running T2 host with its guest, skips a deallocated VM with a Warning, and sends no secret' {
        $results = @(Find-DemoSignInData -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'SECURITY.SIGNIN.SQLVM01').status | Should -Be 'Warning'
        ($results | Where-Object checkId -EQ 'SECURITY.SIGNIN.ARCHOST01').status | Should -Be 'Pass'
        $script:runs.Count | Should -Be 1
        $script:runs[0].VmName | Should -Be 'archost01'
        $script:runs[0].Name | Should -Be 'DbHubDemo-SignInData'
        $script:runs[0].Parameter['ResidueAction'] | Should -Be 'Scan'
        $script:runs[0].Parameter['ResidueScope'] | Should -Be 'Both'
        $script:runs[0].Parameter['ClearSecurityLog'] | Should -Be 'false'
        $script:runs[0].Protected | Should -BeNullOrEmpty -Because 'the sweep takes no secret'
        $script:runs[0].Script | Should -Match 'function Invoke-DemoSignInSweep'
    }

    It 'cleans only when asked, and clears the Security log only with -ClearSecurityLog' {
        Find-DemoSignInData -Config $config -VmName archost01 -Clean -ClearSecurityLog -Confirm:$false | Out-Null
        $script:runs[0].Parameter['ResidueAction'] | Should -Be 'Clean'
        $script:runs[0].Parameter['ClearSecurityLog'] | Should -Be 'true'
        $script:runs[0].Parameter['ClearEventLogs'] | Should -Be 'true'
    }

    It 'changes nothing under -WhatIf' {
        $results = @(Find-DemoSignInData -Config $config -VmName archost01 -Clean -WhatIf)
        ($results | Where-Object checkId -EQ 'SECURITY.SIGNIN.ARCHOST01').status | Should -Be 'Not selected'
        $script:runs.Count | Should -Be 0
    }

    It 'stops with nothing checked when the subscription guard fails' {
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { throw 'The Azure CLI is signed in to another tenant.' }
        $results = @(Find-DemoSignInData -Config $config -Confirm:$false)
        $results.Count | Should -Be 1
        $results[0].status | Should -Be 'Fail'
        $script:runs.Count | Should -Be 0
    }
}
