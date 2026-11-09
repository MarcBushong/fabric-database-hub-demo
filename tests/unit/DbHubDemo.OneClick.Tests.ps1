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

Describe 'Following up a rebuilt T2 guest in Azure (review of 849d4c2, 2026-11-09)' {
    BeforeEach {
        $script:config = [ordered]@{ subscriptionId = '11111111-2222-3333-4444-555555555555'; location = 'westus3'; t2Mode = 'Nested' }
        $script:machine = $null
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcTarget -MockWith { [pscustomobject]@{ SubscriptionId = '11111111-2222-3333-4444-555555555555'; MachineUrl = 'https://management.azure.com/machines/arcsql01'; MachineName = 'arcsql01' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcArmResource -MockWith { $script:machine }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoArcStaleResource -MockWith { @('sqlServerInstances/arcsql01', 'machines/arcsql01') }
        Mock -ModuleName DbHubDemo -CommandName Clear-DemoGuidedStopLeftover -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:follow = {
            param([hashtable] $Health)
            @(InModuleScope DbHubDemo -Parameters @{ Config = $script:config; Health = [pscustomobject]$Health } { Complete-DemoT2GuestRebuild -Config $Config -Health $Health -Confirm:$false })
        }
        $script:removed = @{ guestRebuild = 'Removed'; rebuildUtc = '2026-11-09T10:00:00Z'; rebuildMode = 'PaygWizard'; rebuildArcId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.HybridCompute/machines/arcsql01' }
    }

    It 'decides what happens to arcsql01''s Arc machine on evidence only: <Case>' -ForEach @(
        @{ Case = 'no machine'; Json = ''; Action = 'None' }
        @{ Case = 'Disconnected'; Json = '{"name":"arcsql01","properties":{"status":"Disconnected"},"systemData":{"createdAt":"2026-11-09T10:40:00Z"}}'; Action = 'Delete' }
        @{ Case = 'Expired'; Json = '{"name":"arcsql01","properties":{"status":"Expired"}}'; Action = 'Delete' }
        @{ Case = 'without a status'; Json = '{"name":"arcsql01","properties":{}}'; Action = 'Delete' }
        @{ Case = 'Connected, created before the rebuild started'; Json = '{"name":"arcsql01","properties":{"status":"Connected"},"systemData":{"createdAt":"2026-10-30T09:00:00.1234567Z"}}'; Action = 'Delete' }
        @{ Case = 'Connected, created after the rebuild started'; Json = '{"name":"arcsql01","properties":{"status":"Connected"},"systemData":{"createdAt":"2026-11-09T10:40:00Z"}}'; Action = 'Keep' }
        @{ Case = 'Connected, without systemData'; Json = '{"name":"arcsql01","properties":{"status":"Connected"}}'; Action = 'Keep' }
    ) {
        $machine = if ($Json) { $Json | ConvertFrom-Json } else { $null }
        # PowerShell 7's ConvertFrom-Json reads the health summary's time as a DateTime; the text form must decide the same.
        foreach ($rebuildUtc in @('2026-11-09T10:00:00Z', [datetime]::new(2026, 11, 9, 10, 0, 0, [System.DateTimeKind]::Utc))) {
            $decision = InModuleScope DbHubDemo -Parameters @{ Machine = $machine; RebuildUtc = $rebuildUtc } { Get-DemoT2RebuildArcDecision -Machine $Machine -RebuildUtc $RebuildUtc }
            $decision.Action | Should -Be $Action
            $decision.Reason | Should -Not -BeNullOrEmpty
        }
    }

    It 'keeps a Connected machine when the rebuild''s start isn''t known' {
        $machine = '{"name":"arcsql01","properties":{"status":"Connected"},"systemData":{"createdAt":"2026-10-30T09:00:00Z"}}' | ConvertFrom-Json
        (InModuleScope DbHubDemo -Parameters @{ Machine = $machine } { Get-DemoT2RebuildArcDecision -Machine $Machine -RebuildUtc '' }).Action | Should -Be 'Keep'
    }

    It 'has nothing to follow up when <Case>' -ForEach @(
        @{ Case = 'there''s no rebuild'; Health = @{} }
        @{ Case = 'the rebuild is Done'; Health = @{ guestRebuild = 'Done'; rebuildArcNew = $true } }
        @{ Case = 'the rebuild is Done, whatever the marker says'; Health = @{ guestRebuild = 'Done' } }
        @{ Case = 'the new guest is onboarded'; Health = @{ guestRebuild = 'Removed'; rebuildArcNew = $true } }
    ) {
        & $script:follow $Health | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArcArmResource -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoArcStaleResource -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Clear-DemoGuidedStopLeftover -Times 0 -Exactly
    }

    It 'deletes nothing in Azure when the host can''t tell whether the new guest is onboarded (<Case>)' -ForEach @(
        @{ Case = 'null'; Present = $true }
        @{ Case = 'not reported'; Present = $false }
    ) {
        $health = $script:removed.Clone()
        if ($Present) {
            $health['rebuildArcNew'] = $null
        }
        $script:machine = '{"name":"arcsql01","properties":{"status":"Disconnected"}}' | ConvertFrom-Json
        $results = & $script:follow $health
        $rebuild = $results | Where-Object { $_.checkId -eq 'DEPLOY.T2.REBUILD' }
        $rebuild.status | Should -Be 'Warning'
        $rebuild.message | Should -Match 'In Azure, nothing was deleted: archost01 couldn''t tell whether its new guest is onboarded'
        $rebuild.evidence.arcNew | Should -BeNullOrEmpty
        $rebuild.evidence.arcAction | Should -Be 'Keep'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArcArmResource -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoArcStaleResource -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Clear-DemoGuidedStopLeftover -Times 1 -Exactly
    }

    It 'with the new guest not onboarded yet, acts on the machine Azure shows: <Case>' -ForEach @(
        @{ Case = 'a Disconnected one is deleted'; Json = '{"name":"arcsql01","properties":{"status":"Disconnected"}}'; Action = 'Delete'; Removes = 1; Says = 'were deleted, because it''s Disconnected' }
        @{ Case = 'a Connected one from before the rebuild is deleted'; Json = '{"name":"arcsql01","properties":{"status":"Connected"},"systemData":{"createdAt":"2026-10-30T09:00:00Z"}}'; Action = 'Delete'; Removes = 1; Says = 'before the rebuild started' }
        @{ Case = 'a Connected one from after the rebuild is kept'; Json = '{"name":"arcsql01","properties":{"status":"Connected"},"systemData":{"createdAt":"2026-11-09T10:40:00Z"}}'; Action = 'Keep'; Removes = 0; Says = 'was kept, because it''s Connected' }
        @{ Case = 'none is left'; Json = ''; Action = 'None'; Removes = 0; Says = 'had no Arc machine left' }
    ) {
        $script:machine = if ($Json) { $Json | ConvertFrom-Json } else { $null }
        $health = $script:removed.Clone()
        $health['rebuildArcNew'] = $false
        $rebuild = & $script:follow $health | Where-Object { $_.checkId -eq 'DEPLOY.T2.REBUILD' }
        $rebuild.status | Should -Be 'Warning'
        $rebuild.message | Should -Match $Says
        $rebuild.evidence.arcAction | Should -Be $Action
        $rebuild.evidence.arcNew | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoArcStaleResource -Times $Removes -Exactly
    }

    It 'keeps going when Azure can''t be read, and deletes nothing' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcArmResource -MockWith { throw 'Azure answered 503.' }
        $health = $script:removed.Clone()
        $health['rebuildArcNew'] = $false
        $rebuild = & $script:follow $health | Where-Object { $_.checkId -eq 'DEPLOY.T2.REBUILD' }
        $rebuild.message | Should -Match 'couldn''t be deleted now \(Azure answered 503\.\)'
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoArcStaleResource -Times 0 -Exactly
    }
}

Describe 'No fix offers a retired value (review of 849d4c2, 2026-11-09)' {
    It 'never names PaygWizard or t4Enabled as a fix, and the setup-wizard step only where PaygWizard is the mode' {
        # NOT DONE's next step comes from these texts, so an agent that follows AGENTS.md would loop on a value deploy.ps1
        # ignores. Text inside an if whose condition names PaygWizard stays: only that mode has the setup-wizard step.
        $root = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
        $retired = '(?i)\bset\s+t4Enabled\b|\bt4Enabled\s+to\s+false\b|\bor\s+PaygWizard\b|PaygWizard,\s+which\s+needs|t2SqlInstallMode\s+to\s+PaygWizard|-T2SqlInstallMode\s+PaygWizard'
        $wizardStep = '(?i)\b(finish|do)\s+the\s+setup-wizard\s+step\b|setup-wizard step is in docs|When the setup-wizard step|build and the wizard'
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($file in Get-ChildItem -Path (Join-Path -Path $root -ChildPath 'scripts'), (Join-Path -Path $root -ChildPath 'vm') -Recurse -Include '*.ps1', '*.psm1') {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $strings = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
            foreach ($node in $strings) {
                if ($node.Value -match $retired) {
                    $found.Add(('{0}:{1}: {2}' -f $file.Name, $node.Extent.StartLineNumber, $Matches[0]))
                    continue
                }
                if ($node.Value -notmatch $wizardStep) {
                    continue
                }
                $guarded = $false
                for ($parent = $node.Parent; $null -ne $parent -and -not $guarded; $parent = $parent.Parent) {
                    if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
                        foreach ($clause in $parent.Clauses) {
                            if ($clause.Item1.Extent.Text -match 'PaygWizard' -and $node.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and $node.Extent.EndOffset -le $clause.Item2.Extent.EndOffset) {
                                $guarded = $true
                            }
                        }
                    }
                }
                if (-not $guarded) {
                    $found.Add(('{0}:{1}: {2}' -f $file.Name, $node.Extent.StartLineNumber, $Matches[0]))
                }
            }
        }
        $found | Should -BeNullOrEmpty
    }
}

Describe 'The evaluation-only T2 with an older configuration (review of 849d4c2, 2026-11-09)' {
    It 'says PaygWizard is retired there, and names only the unattended modes' {
        $config = Get-DemoConfig -Path (New-TestConfigFile -Values @{ t2Mode = 'EvaluationOnlyAzureVm'; t2SqlInstallMode = 'PaygWizard' })
        $config['t2SqlInstallMode'] | Should -Be 'JumpstartImage'
        $text = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT2LegacyModeText -Config $Config }
        $text | Should -Match 'is retired: the one-click deployment has no SQL Server setup wizard, and t2Mode EvaluationOnlyAzureVm can''t use Arc Jumpstart''s image'
        $text | Should -Match 'Set t2SqlInstallMode to ProductKey or Developer\.$'
        $text | Should -Not -Match 'set t2SqlInstallMode to JumpstartImage'
    }
}