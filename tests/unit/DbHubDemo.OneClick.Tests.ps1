BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force

    # A configuration file as an older init.ps1 wrote it, with what the one-click deployment now ignores.
    function New-TestConfigFile {
        param([hashtable] $Values = @{})
        $base = [ordered]@{
            subscriptionId       = '00000000-0000-0000-0000-000000000000'
            tenantId             = '00000000-0000-0000-0000-000000000000'
            t3AdminGroupObjectId = '00000000-0000-0000-0000-000000000000'
            ownerEmail           = 'owner@example.com'
        }
        foreach ($key in $Values.Keys) {
            $base[$key] = $Values[$key]
        }
        $path = Join-Path -Path $TestDrive -ChildPath ('config-{0}.json' -f [guid]::NewGuid())
        $base | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        return $path
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'One click: a configuration can''t lead to the setup wizard or leave T4 out (2026-11-09, user-directed)' {
    It 'loads the user''s live-check configuration, PaygWizard and t4Enabled false, as JumpstartImage with T4, and says so' {
        $config = Get-DemoConfig -Path (New-TestConfigFile -Values @{ t2SqlInstallMode = 'PaygWizard'; t4Enabled = $false })
        $config['t2SqlInstallMode'] | Should -Be 'JumpstartImage'
        $config['t2SqlInstallModeSource'] | Should -Be 'legacy'
        $config['t4Enabled'] | Should -BeTrue
        $config['t4EnabledIgnored'] | Should -BeTrue
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoT2PaygWizardOptIn -Config $Config } | Should -BeFalse
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoT4Enabled -Config $Config } | Should -BeTrue
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT2LegacyModeText -Config $Config } | Should -Match 'PaygWizard in your configuration .* is ignored: T2 comes from Arc Jumpstart''s image \(JumpstartImage\), with no setup wizard'
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4IgnoredText -Config $Config } | Should -Match '^t4Enabled false in your configuration is ignored: T4 \(Azure Database for PostgreSQL\) is part of every deployment'
    }

    It 'says nothing when there''s nothing to ignore' {
        $config = Get-DemoConfig -Path (New-TestConfigFile)
        $config['t2SqlInstallMode'] | Should -Be 'JumpstartImage'
        $config['t2SqlInstallModeSource'] | Should -Be 'default'
        $config['t4Enabled'] | Should -BeTrue
        $config.Contains('t4EnabledIgnored') | Should -BeFalse
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { (Get-DemoT2LegacyModeText -Config $Config) + (Get-DemoT4IgnoredText -Config $Config) } | Should -BeNullOrEmpty
        (Get-DemoConfig -Path (New-TestConfigFile -Values @{ t4Enabled = $true })).Contains('t4EnabledIgnored') | Should -BeFalse
        (Get-DemoConfig -Path (New-TestConfigFile -Values @{ t2SqlInstallMode = 'Developer' }))['t2SqlInstallMode'] | Should -Be 'Developer' -Because 'Developer and ProductKey keep their meaning'
    }

    It 'has no configuration key that opts into the setup wizard' {
        { Get-DemoConfig -Path (New-TestConfigFile -Values @{ t2SqlInstallMode = 'PaygWizard'; t2PaygWizardOptIn = $true }) } | Should -Throw -ExpectedMessage '*environment.schema.json*'
    }

    It 'writes a run''s configuration back without its marks, and it loads the same' {
        $config = Get-DemoConfig -Path (New-TestConfigFile -Values @{ t2SqlInstallMode = 'PaygWizard'; t4Enabled = $false })
        $config['t2PaygWizardOptIn'] = $true
        $text = InModuleScope DbHubDemo -Parameters @{ Config = $config } { ConvertTo-DemoConfigFileText -Config $Config }
        $written = $text | ConvertFrom-Json -AsHashtable
        foreach ($mark in 't2SqlInstallModeSource', 't4EnabledIgnored', 't2PaygWizardOptIn', 't4SkuSource') {
            $written.Contains($mark) | Should -BeFalse -Because $mark
        }
        $path = Join-Path -Path $TestDrive -ChildPath 'written.json'
        [System.IO.File]::WriteAllText($path, $text)
        $again = Get-DemoConfig -Path $path
        $again['t2SqlInstallMode'] | Should -Be 'JumpstartImage'
        $again['t4Enabled'] | Should -BeTrue
    }

    It 'puts what it ignores at the top of the start banner and on the status page' {
        $notes = @('t2SqlInstallMode PaygWizard ... is ignored.', 't4Enabled false ... is ignored.', '')
        $expect = InModuleScope DbHubDemo -Parameters @{ Notes = $notes } { Get-DemoDeploymentExpectation -InstallMode 'JumpstartImage' -WaitForT2 -Note $Notes }
        $expect.Lines[1] | Should -Be '- t2SqlInstallMode PaygWizard ... is ignored.'
        $expect.Lines[2] | Should -Be '- t4Enabled false ... is ignored.'
        $expect.Lines | Should -Not -Contain '- '
        $expect.Text | Should -Match 't2SqlInstallMode PaygWizard \.\.\. is ignored\. t4Enabled false \.\.\. is ignored\.$'
        $expect.GuidedStop | Should -BeFalse
        $expect.HumanText | Should -BeNullOrEmpty
    }
}

Describe 'DONE needs T4, like T1, T2, and T3 (2026-11-09)' {
    It 'requires T4''s estate and metrics in <Mode> mode' -ForEach @(
        @{ Mode = 'JumpstartImage' }
        @{ Mode = 'ProductKey' }
        @{ Mode = 'Developer' }
    ) {
        $ids = InModuleScope DbHubDemo -Parameters @{ Mode = $Mode } { Get-DemoDoneRequirement -InstallMode $Mode }
        $ids | Should -Contain 'HUB.ESTATE.T4'
        $ids | Should -Contain 'METRICS.T4'
        (InModuleScope DbHubDemo { Get-Command -Name Get-DemoDoneRequirement }).Parameters.Keys | Should -Not -Contain 'T4Off'
    }

    It 'turns Azure''s refusal of every size into a Fail with the fix, never a silent omission' {
        $refusal = InModuleScope DbHubDemo { New-DemoT4FallbackResult -Refused $null -Next 'Refused' }
        $refusal.status | Should -Be 'Fail'
        $refusal.message | Should -Match 'ends NOT DONE'
        $refusal.remediation | Should -Match 'Region access request'
        $refusal.remediation | Should -Match 't4SkuName'
        $refusal.remediation | Should -Not -Match 't4Enabled'
        $off = InModuleScope DbHubDemo -Parameters @{ Refusal = $refusal } { New-DemoT4OffResult -Config @{ location = 'westus3' } -State $null -Result @($Refusal) }
        $off.checkId | Should -Be 'DEPLOY.T4.OFF'
        $off.status | Should -Be 'Fail'
        $off.message | Should -Match 'DONE needs it'
        InModuleScope DbHubDemo { New-DemoT4OffResult -Config @{ location = 'westus3' } -State $null -Result @() } | Should -BeNullOrEmpty
    }

    It 'creates T4 at the 2-vCore size when its cost check doesn''t pass, with a Warning' {
        $cost = [pscustomobject]@{ Allowed = $false; SkipReason = 'MonthlyCeiling'; HourlyUsd = 0.178; T4MonthlyWorstCaseUsd = 130.0; MonthlyWorstCaseUsd = 412.5; SessionUsd = 9.1; MonthlyCeilingUsd = 375.0; SessionCeilingUsd = 15.0; DefenderIncluded = $false; Unpriced = @(); PriceError = ''; RestartAssumption = 'RestOfMonth' }
        $result = InModuleScope DbHubDemo -Parameters @{ Cost = $cost } { New-DemoT4FallbackResult -Refused $null -Next 'None' -Cost $Cost }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'this run creates T4 as General Purpose Standard_D2ds_v5'
        $result.message | Should -Match 'a ceiling never leaves it out'
        $result.remediation | Should -Match 'raise monthlyCeilingUsd to at least 413'
        $result.remediation | Should -Not -Match 't4Enabled'
    }

    It 'keeps autonomous tuning from leaving T4 out: a Warning at the fallback''s size, a Fail only for a size the file sets' {
        $fallback = @{ t4AutonomousTuning = $true; t4SkuName = 'Standard_D2ds_v5'; t4SkuSource = 'fallback'; profile = 'lowest-cost' }
        (InModuleScope DbHubDemo -Parameters @{ Config = $fallback } { Get-DemoT4Tuning -Config $Config }).Status | Should -Be 'Warning'
        $explicit = @{ t4AutonomousTuning = $true; t4SkuName = 'Standard_D2ds_v5'; profile = 'lowest-cost' }
        (InModuleScope DbHubDemo -Parameters @{ Config = $explicit } { Get-DemoT4Tuning -Config $Config }).Status | Should -Be 'Fail'
        $preflight = @{ t4AutonomousTuning = $true; profile = 'lowest-cost' }
        (InModuleScope DbHubDemo -Parameters @{ Config = $preflight } { Get-DemoT4Tuning -Config $Config -SkuName 'Standard_D2ds_v5' }).Status | Should -Be 'Warning' -Because 'preflight judges the size the fallback starts at'
    }
}

Describe 'No record leaves T4 out: every run tries the sizes again (2026-11-09)' {
    It 'plans T4 at the default size again after a <Record> record when the template runs, and keeps T4 on otherwise' -ForEach @(
        @{ Record = 'None' }
        @{ Record = 'Refused' }
    ) {
        $config = [ordered]@{ location = 'westus3'; profile = 'lowest-cost'; t4Enabled = $true }
        $state = [pscustomobject]@{ T4Sku = $Record }
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = $config; State = $state } { Resolve-DemoEffectiveConfig -Config $Config -State $State -TemplateRuns }
        $resolved['t4Enabled'] | Should -BeTrue
        $resolved['t4SkuSource'] | Should -Be 'retry'
        $resolved['t4SkuName'] | Should -Be 'Standard_D4ds_v5'
        $resumed = InModuleScope DbHubDemo -Parameters @{ Config = $config; State = $state } { Resolve-DemoEffectiveConfig -Config $Config -State $State }
        $resumed['t4Enabled'] | Should -BeTrue
        InModuleScope DbHubDemo -Parameters @{ Config = $config; State = $state } { Get-DemoT4OffReason -Config $Config -State $State } | Should -BeNullOrEmpty
    }

    It 'starts a resumed run from preflight when T4''s server doesn''t exist, whatever an earlier run recorded' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ State = 'NotFound'; Exists = $false; Names = [pscustomobject]@{ ServerName = 'pgflex01-abc123' } } }
        $config = [ordered]@{ location = 'westus3'; t4Enabled = $true }
        foreach ($record in '', 'None', 'Refused', 'Standard_D2ds_v5') {
            $state = [pscustomobject]@{ T4Sku = $record; Stage = 'T2'; Tags = @{ deploymentId = 'abc123' } }
            $missing = InModuleScope DbHubDemo -Parameters @{ Config = $config; State = $state } { Get-DemoT4MissingResult -Config $Config -State $State }
            $missing.checkId | Should -Be 'DEPLOY.T4.MISSING' -Because ('the record was "{0}"' -f $record)
        }
    }
}
