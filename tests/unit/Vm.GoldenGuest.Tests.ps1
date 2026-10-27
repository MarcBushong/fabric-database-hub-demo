BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the golden guest script's functions without running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoGoldenGuest.ps1')
    $secure = [System.Security.SecureString]::new()
    foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
    $script:credential = [System.Management.Automation.PSCredential]::new('Administrator', $secure)
}

Describe 'Read-GoldenAgentState' {
    BeforeEach {
        Mock -CommandName Start-Sleep -MockWith { }
        $script:answers = [System.Collections.Generic.Queue[object]]::new()
        Mock -CommandName Invoke-Command -MockWith { $script:answers.Dequeue() }
    }

    It 'waits while the agent prints no JSON after a cold boot, then returns the identity it reports' {
        # Live, 2026-10-22: right after a restored copy's guest booted, azcmagent show -j printed no JSON, and the
        # Release took that for "no identity" and skipped the reset.
        $script:answers.Enqueue([pscustomobject]@{ installed = $true; json = 'AZCM0064: Unable to establish communication with himds server' })
        $script:answers.Enqueue([pscustomobject]@{ installed = $true; json = '' })
        $script:answers.Enqueue([pscustomobject]@{ installed = $true; json = '{"status":"Disconnected","resourceName":"arcsql01","resourceGroup":"rg-dbhub-demo"}' })
        $state = Read-GoldenAgentState -Credential $script:credential -TimeoutSeconds 60 -PollSeconds 10
        $state.readable | Should -BeTrue
        $state.agent.resourceName | Should -Be 'arcsql01'
        $state.agent.resourceGroup | Should -Be 'rg-dbhub-demo'
        Should -Invoke -CommandName Invoke-Command -Times 3 -Exactly
        Should -Invoke -CommandName Start-Sleep -Times 2 -Exactly
    }

    It 'reports the state as unreadable, never as no identity, when the agent never answers' {
        1..6 | ForEach-Object { $script:answers.Enqueue([pscustomobject]@{ installed = $true; json = '' }) }
        $state = Read-GoldenAgentState -Credential $script:credential -TimeoutSeconds 60 -PollSeconds 10
        $state.readable | Should -BeFalse
        $state.installed | Should -BeTrue
        Should -Invoke -CommandName Invoke-Command -Times 6 -Exactly
    }

    It 'reports no identity only when the agent answers without a resource, or isn''t installed' {
        $script:answers.Enqueue([pscustomobject]@{ installed = $true; json = '{"status":"Disconnected","resourceName":""}' })
        $answered = Read-GoldenAgentState -Credential $script:credential
        $answered.readable | Should -BeTrue
        $answered.agent.status | Should -Be 'Disconnected'
        $answered.agent.resourceName | Should -BeNullOrEmpty
        $script:answers.Enqueue([pscustomobject]@{ installed = $false; json = '' })
        $missing = Read-GoldenAgentState -Credential $script:credential
        $missing.installed | Should -BeFalse
        $missing.readable | Should -BeTrue
    }
}

Describe 'Get-GoldenResetDecision' {
    BeforeAll {
        $script:capture = [pscustomobject]@{ arcResourceName = 'arcsql01'; arcResourceGroup = 'rg-dbhub-demo' }
    }

    It 'resets a copy whose agent names the captured identity' {
        (Get-GoldenResetDecision -Agent ([pscustomobject]@{ status = 'Disconnected'; resourceName = 'ARCSQL01'; resourceGroup = 'rg-dbhub-demo' }) -Capture $script:capture).Reason | Should -Be 'CapturedIdentity'
    }

    It 'resets a copy whose air-gapped agent names nothing, because that doesn''t prove there''s no identity (live, 2026-10-23)' {
        # The Release read {status: failed} with no resource, skipped the reset, and reconnected the guest; the onboarding's
        # probe then found the agent still configured for arcsql01.
        $decision = Get-GoldenResetDecision -Agent ([pscustomobject]@{ status = 'failed'; resourceName = ''; resourceGroup = '' }) -Capture $script:capture
        $decision.Action | Should -Be 'Reset'
        $decision.Reason | Should -Be 'IdentityUnknown'
    }

    It 'leaves an agent that names another identity alone' {
        $decision = Get-GoldenResetDecision -Agent ([pscustomobject]@{ status = 'Connected'; resourceName = 'arcsql01'; resourceGroup = 'rg-dbhub-gtest' }) -Capture $script:capture
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Be 'OtherIdentity'
    }

    It 'skips only when the snapshot was captured without an identity and the agent names none' {
        $decision = Get-GoldenResetDecision -Agent ([pscustomobject]@{ status = 'Disconnected'; resourceName = '' }) -Capture ([pscustomobject]@{ arcResourceName = ''; arcResourceGroup = '' })
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Be 'NoCapturedIdentity'
    }
}