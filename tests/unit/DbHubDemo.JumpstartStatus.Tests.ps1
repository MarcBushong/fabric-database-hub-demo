BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force

    function New-TestConfig {
        param([string] $T2Mode = 'Nested')
        $config = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['t2Mode'] = $T2Mode
        return $config
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'STATUS.T2.DISKSPACE: the free space for the guest''s dynamic disk (2026-11-05)' {
    It 'passes with the free space, and warns below the host''s threshold with the fixes' {
        $config = New-TestConfig
        $health = [pscustomobject]@{ storageDrive = 'C:'; storageFreeGiB = 58.4; storageWarnGiB = 20; storageLow = $false }
        $pass = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $health } { Get-DemoT2DiskSpaceResult -Config $Config -Health $Health }
        $pass.checkId | Should -Be 'STATUS.T2.DISKSPACE'
        $pass.status | Should -Be 'Pass'
        $pass.message | Should -Match '58\.4 GiB free on C:'

        $health = [pscustomobject]@{ storageDrive = 'C:'; storageFreeGiB = 12.1; storageWarnGiB = 20; storageLow = $true }
        $warn = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $health } { Get-DemoT2DiskSpaceResult -Config $Config -Health $Health }
        $warn.status | Should -Be 'Warning'
        $warn.message | Should -Match 'below 20 GiB'
        $warn.message | Should -Match 'pauses the guest'
        $warn.remediation | Should -Match 'dataDiskSku E10'
        $warn.evidence.freeGiB | Should -Be 12.1
    }

    It 'says nothing without the health''s storage figures, or for the evaluation-only T2' {
        $config = New-TestConfig
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT2DiskSpaceResult -Config $Config -Health ([pscustomobject]@{ state = 'Ready' }) }) | Should -BeNullOrEmpty
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT2DiskSpaceResult -Config $Config -Health $null }) | Should -BeNullOrEmpty
        $evaluation = New-TestConfig -T2Mode 'EvaluationOnlyAzureVm'
        $health = [pscustomobject]@{ storageDrive = 'C:'; storageFreeGiB = 5; storageWarnGiB = 20; storageLow = $true }
        (InModuleScope DbHubDemo -Parameters @{ Config = $evaluation; Health = $health } { Get-DemoT2DiskSpaceResult -Config $Config -Health $Health }) | Should -BeNullOrEmpty
    }
}

Describe 'STATUS.T2.IMAGE: which Arc Jumpstart image the guest came from (2026-11-05)' {
    It 'passes for the pinned image, and warns, with nothing to do, for a newer one' {
        $health = [pscustomobject]@{ installMode = 'JumpstartImage'; imageEtag = '0x8DDD21BE1292CD1'; imageModified = '2025-08-02T23:25:34Z'; imagePinned = $true }
        $pass = InModuleScope DbHubDemo -Parameters @{ Health = $health } { Get-DemoT2ImageResult -Health $Health }
        $pass.checkId | Should -Be 'STATUS.T2.IMAGE'
        $pass.status | Should -Be 'Pass'
        $pass.message | Should -Match 'tested with'

        $health = [pscustomobject]@{ installMode = 'JumpstartImage'; imageEtag = '0x8DE0000000000000'; imageModified = '2026-12-01T00:00:00Z'; imagePinned = $false }
        $warn = InModuleScope DbHubDemo -Parameters @{ Health = $health } { Get-DemoT2ImageResult -Health $Health }
        $warn.status | Should -Be 'Warning'
        $warn.message | Should -Match 'newer Arc Jumpstart image \(etag 0x8DE0000000000000'
        $warn.message | Should -Match 'passed the image checks'
        $warn.remediation | Should -Match '^Nothing is needed while T2 works'
        $warn.evidence.pinned | Should -BeFalse
    }

    It 'says nothing in another install mode, or before the image is in place' {
        (InModuleScope DbHubDemo { Get-DemoT2ImageResult -Health ([pscustomobject]@{ installMode = 'PaygWizard'; imageEtag = '0x1'; imagePinned = $true }) }) | Should -BeNullOrEmpty
        (InModuleScope DbHubDemo { Get-DemoT2ImageResult -Health ([pscustomobject]@{ installMode = 'JumpstartImage'; imageEtag = '' }) }) | Should -BeNullOrEmpty
        (InModuleScope DbHubDemo { Get-DemoT2ImageResult -Health $null }) | Should -BeNullOrEmpty
    }
}

Describe 'Golden snapshots of a guest that isn''t a Windows evaluation (2026-11-05)' {
    It 'never expires a snapshot tagged EvalExpiresUtc none, and treats one without the property as an evaluation' {
        InModuleScope DbHubDemo {
            Test-DemoGoldenIsEvaluation -Snapshot ([pscustomobject]@{ Evaluation = $false }) | Should -BeFalse
            Test-DemoGoldenIsEvaluation -Snapshot ([pscustomobject]@{ Evaluation = $true }) | Should -BeTrue
            Test-DemoGoldenIsEvaluation -Snapshot ([pscustomobject]@{ Name = 'older shape' }) | Should -BeTrue
            Test-DemoGoldenEvaluationOk -Snapshot ([pscustomobject]@{ Evaluation = $false; EvalDaysLeft = $null }) | Should -BeTrue
            Test-DemoGoldenEvaluationOk -Snapshot ([pscustomobject]@{ Evaluation = $true; EvalDaysLeft = 0 }) | Should -BeFalse
            Test-DemoGoldenEvaluationOk -Snapshot ([pscustomobject]@{ EvalDaysLeft = 0 }) | Should -BeFalse
            Test-DemoGoldenEvaluationOk -Snapshot ([pscustomobject]@{ EvalDaysLeft = 12 }) | Should -BeTrue
        }
    }

    It 'reports a JumpstartImage snapshot as usable with no evaluation to end' {
        $config = New-TestConfig
        $snapshot = [pscustomobject]@{
            Name = 'snap-dbhub-t2golden-202611060000'; CapturedUtc = [datetime]'2026-11-06'; BootVerifiedUtc = [datetime]'2026-11-06'; OnboardVerifiedUtc = $null
            Evaluation = $false; EvalExpiresUtc = $null; EvalDaysLeft = $null; SizeGiB = 128; UsedGiB = 55
        }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config; Snapshot = $snapshot } { Get-DemoT2GoldenStatus -Config $Config -Snapshot @($Snapshot) }
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'isn''t a Windows evaluation'
    }
}
