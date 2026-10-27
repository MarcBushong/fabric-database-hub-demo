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
