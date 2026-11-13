BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    # T4 is part of every deployment since 2026-11-09 (user-directed), so a configuration always has it; -WithT4 stays for
    # the tests that say so. -WithoutT4 is a run whose template deployed without T4 (Azure refused every size).
    function New-TestConfig([switch] $WithT4, [string] $InstallMode = 'PaygWizard', [switch] $WithoutT4) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        $config['t4Enabled'] = -not $WithoutT4
        $config['t2SqlInstallMode'] = $InstallMode
        return $config
    }

    function New-TestResult([string] $CheckId, [string] $Status = 'Pass') {
        New-DemoResult -CheckId $CheckId -Area 'infra' -Target 'subscription' -Status $Status -Message ('{0} {1}' -f $CheckId, $Status) -Remediation $(if ($Status -in 'Fail', 'Manual action required') { 'Fix it, then run ./scripts/deploy.ps1.' } else { '' })
    }

    # Every DONE requirement passing (brief item 16), for the configuration's mode; T4's always (2026-11-09).
    function New-DoneResult([switch] $WithT4, [string] $InstallMode = 'PaygWizard', [switch] $SkipFabric) {
        $ids = InModuleScope DbHubDemo -Parameters @{ Mode = $InstallMode; Skip = [bool]$SkipFabric } { Get-DemoDoneRequirement -InstallMode $Mode -SkipFabric:$Skip }
        foreach ($id in $ids) {
            New-TestResult $id
        }
    }

    function New-FinishedState([switch] $WithT4, [string] $T4Sku = '') {
        [pscustomobject]@{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = 'Telemetry'; TrackFabric = 'Fabric'; T4Sku = $T4Sku; GuidedStopUtc = ''; HostPasswordUtc = '' }
    }

    # The Hub checks' Fabric REST mocks (Initialize-HubFabricMock), for the tenant setting's real results.
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')

    # The Hub tenant setting as Test-DemoFabricHubSetting reads it through the mocked admin API (Phase 28 live finding):
    # Forbidden (the caller isn't a Fabric administrator), Enabled, or Disabled.
    function New-HubSettingResult([string] $Answer, [string] $CheckId = 'FABRIC.P4.HUBSETTING') {
        $script:hubAnswer = $Answer
        Initialize-HubFabricMock -Handler {
            if ($script:hubAnswer -eq 'Forbidden') {
                ConvertTo-HubFabricResponse -StatusCode 403 -Body @{ errorCode = 'Forbidden'; message = 'The caller is not a Fabric administrator' }
            }
            else {
                ConvertTo-HubFabricResponse -Body @{ value = @(@{ settingName = 'HubSetting'; title = 'Users can access the Database hub (preview)'; enabled = ($script:hubAnswer -eq 'Enabled') }) }
            }
        }
        Test-DemoFabricHubSetting -Config (New-TestConfig) -CheckId $CheckId
    }
}

Describe 'What a run can expect (brief goal 7, items 3 and 13)' {
    It 'gives the first-run and golden-redeploy times, and says no T2 step needs a person in any mode (the guided stop is retired, 2026-11-09)' {
        foreach ($mode in 'PaygWizard', 'ProductKey', 'Developer') {
            $expect = InModuleScope DbHubDemo -Parameters @{ Mode = $mode } { Get-DemoDeploymentExpectation -InstallMode $Mode }
            $text = $expect.Lines -join ' '
            $text | Should -Match 'No T2 step needs a person' -Because $mode
            $text | Should -Match 'golden snapshot \(\./scripts/capture-t2-golden\.ps1\) takes about 30 to 45 minutes'
            $text | Should -Match 'stays awake'
            $text | Should -Match 'If this window closes or the PC restarts, run \./scripts/deploy\.ps1 again; it continues where it stopped\.'
            $text | Should -Not -Match '(?i)guided stop|Bastion|a person is needed' -Because $mode
            @($expect.PSObject.Properties.Name) | Should -Be @('Lines', 'Text')
        }
    }

    It 'says no T2 step needs a person in JumpstartImage mode, the default, and gives the first deployment''s measured time (2026-11-06)' {
        $expect = InModuleScope DbHubDemo { Get-DemoDeploymentExpectation }
        $text = $expect.Lines -join ' '
        $text | Should -Match 'No T2 step needs a person'
        $text | Should -Match 'about 1\.5 hours in all: 91 minutes when measured on 2026-11-06'
        $text | Should -Match 'host build, with the Jumpstart image''s download and first boot, took about 27'
        $text | Should -Not -Match 'not measured yet'
        $expect.Lines[0] | Should -Match 'measured on 2026-11-06; the rest are estimates'
        $expect.Text | Should -Match '91 minutes, measured on 2026-11-06'
        $text | Should -Match 'The Insights app deploys with your Azure CLI sign-in \(az login\), so no browser opens for it\. Only after Fabric refused that token in an earlier run' -Because 'the app''s Rayfin CLI needs no sign-in of its own by default (2026-11-09)'
        $environment = [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $false; Codespaces = $false; Windows = $true }
        $notice = InModuleScope DbHubDemo -Parameters @{ Environment = $environment } { Get-DemoDeploymentNotice -Environment $Environment }
        @($notice | Where-Object { $_ -notlike 'The Insights app deploys with your Azure CLI sign-in*' }) | Should -BeNullOrEmpty -Because 'a session without keyboard input needs no T2 warning when no T2 step needs a person'
        @($notice | Where-Object { $_ -like 'The Insights app deploys with your Azure CLI sign-in*' }).Count | Should -Be 1 -Because 'its fallback, the Rayfin CLI''s browser sign-in, still doesn''t start in such a session (2026-11-05; 2026-11-09)'
        ($notice -join ' ') | Should -Match 'Only if Fabric refuses that token does it need the Rayfin CLI''s browser sign-in, which isn''t started in a session like this one'
        $quiet = InModuleScope DbHubDemo -Parameters @{ Environment = $environment } { Get-DemoDeploymentNotice -Environment $Environment -SkipFabric }
        @($quiet) | Should -BeNullOrEmpty -Because 'without Fabric, nothing in JumpstartImage mode needs a person'
    }

    It 'warns about the GitHub Codespaces idle timeout and the setting that raises it' {
        $environment = [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $true; Codespaces = $true; Windows = $false }
        $notice = InModuleScope DbHubDemo -Parameters @{ Environment = $environment } { Get-DemoDeploymentNotice -Environment $Environment }
        ($notice -join ' ') | Should -Match '30 minutes without activity'
        ($notice -join ' ') | Should -Match 'Default idle timeout'
        ($notice -join ' ') | Should -Match 'gh codespace create --idle-timeout 240m'
        ($notice -join ' ') | Should -Not -Match 'PLAN FOR A PERSON'
    }
}

Describe 'Get-DemoRunEnvironment' {
    It 'tells CI, GitHub Actions, and Codespaces from their variables' {
        $saved = @{ CI = $env:CI; GITHUB_ACTIONS = $env:GITHUB_ACTIONS; TF_BUILD = $env:TF_BUILD; CODESPACES = $env:CODESPACES }
        try {
            $env:CI = $null; $env:GITHUB_ACTIONS = $null; $env:TF_BUILD = $null; $env:CODESPACES = 'true'
            $local = Get-DemoRunEnvironment
            $local.Ci | Should -BeFalse
            $local.Codespaces | Should -BeTrue
            $env:GITHUB_ACTIONS = 'true'
            $actions = Get-DemoRunEnvironment
            $actions.GitHubActions | Should -BeTrue
            $actions.Ci | Should -BeTrue
            $actions.Interactive | Should -BeFalse
        }
        finally {
            foreach ($name in $saved.Keys) {
                [System.Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
    }
}

Describe 'The first-run setup from deploy.ps1 (brief goal 1)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:path = Join-Path -Path $TestDrive -ChildPath ('first-' + [guid]::NewGuid().ToString('N') + '.local.json')
        $script:interactive = [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $true; Codespaces = $false; Windows = $true }
    }

    It 'does nothing when the configuration exists' {
        Set-Content -LiteralPath $script:path -Value '{}'
        Mock -ModuleName DbHubDemo -CommandName Initialize-DemoConfig -MockWith { throw 'should not run' }
        $first = Initialize-DemoFirstRun -ConfigPath $script:path -Environment $script:interactive
        $first.Ran | Should -BeFalse
        $first.Ready | Should -BeTrue
    }

    It 'writes it as init.ps1 does, creating the admin group, with the prompts where a person can answer' {
        Mock -ModuleName DbHubDemo -CommandName Initialize-DemoConfig -MockWith {
            [pscustomobject]@{ Results = @(New-DemoResult -CheckId 'INIT.CONFIG' -Area 'preflight' -Target 'repo' -Status 'Pass' -Message 'written'); Config = @{}; Path = $Path; Written = $true; BackupPath = ''; NextSteps = @('./scripts/deploy.ps1') }
        }
        $first = Initialize-DemoFirstRun -ConfigPath $script:path -Environment $script:interactive
        $first.Ran | Should -BeTrue
        $first.Ready | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Initialize-DemoConfig -Times 1 -Exactly -ParameterFilter { $CreateAdminGroup -and -not $NonInteractive -and -not $WhatIf }
    }

    It 'asks nothing where nobody can answer, and ends NOT DONE with the first open item''s fix and the command' {
        $script:noInput = [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $false; Codespaces = $false; Windows = $true }
        Mock -ModuleName DbHubDemo -CommandName Initialize-DemoConfig -MockWith {
            [pscustomobject]@{ Results = @(New-DemoResult -CheckId 'INIT.SUBSCRIPTION' -Area 'preflight' -Target 'subscription' -Status 'Manual action required' -Message 'The Azure CLI has 2 subscriptions.' -Remediation 'Run init.ps1 -SubscriptionId <id>.'); Config = $null; Path = $Path; Written = $false; BackupPath = ''; NextSteps = @() }
        }
        $first = Initialize-DemoFirstRun -ConfigPath $script:path -Environment $script:noInput
        $first.Ready | Should -BeFalse
        $first.Outcome.Kind | Should -Be 'NotDone'
        $first.Outcome.ExitCode | Should -Be 2
        $first.Outcome.Reason | Should -Match 'INIT\.SUBSCRIPTION'
        $first.Outcome.Next | Should -Match 'init\.ps1 -SubscriptionId'
        $first.Outcome.NextCommand | Should -Match '^\./scripts/deploy\.ps1 -ConfigPath'
        Should -Invoke -ModuleName DbHubDemo -CommandName Initialize-DemoConfig -Times 1 -Exactly -ParameterFilter { $NonInteractive -and $CreateAdminGroup }
    }
}

Describe 'What DONE requires (brief item 16)' {
    It 'is Database Hub''s own views of every target, T2 at Standard with PAYG and monitoring, T1''s inventory, and the required Fabric items' {
        $ids = InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'PaygWizard' }
        $ids | Should -Be @('HUB.ESTATE.T1', 'HUB.ESTATE.T2', 'HUB.ESTATE.T3', 'HUB.ESTATE.T4', 'TELEMETRY.T1', 'TELEMETRY.T2', 'TELEMETRY.T3', 'METRICS.T4', 'HUB.ESTATE.T4.REPLICA', 'METRICS.T4.REPLICA', 'T2.ARC.SQLINSTANCE', 'T2.ARC.MONITORING', 'T1.SQLVM.ASSOCIATEDSERVICES', 'FABRIC.ITEMS.REQUIRED')
        (InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'ProductKey' }) | Should -Contain 'T2.ARC.MONITORING'
        $ids | Should -Not -Contain 'DEPLOY.FABRIC.APP'
    }

    It 'always needs T4 (2026-11-09), and leaves T2''s performance, PAYG, and monitoring out in Developer mode' {
        $developer = InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'Developer' -SkipFabric }
        $developer | Should -Contain 'HUB.ESTATE.T4'
        $developer | Should -Contain 'METRICS.T4'
        $developer | Should -Contain 'HUB.ESTATE.T2'
        $developer | Should -Not -Contain 'TELEMETRY.T2'
        $developer | Should -Not -Contain 'T2.ARC.SQLINSTANCE'
        $developer | Should -Not -Contain 'FABRIC.ITEMS.REQUIRED'
    }

    It 'checks only what this run''s results don''t show passing, so a resumed run judges every target' {
        $config = New-TestConfig -WithT4
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubEstate -MockWith { $script:calls.Add('estate ' + ($Target -join ',')); foreach ($t in $Target) { New-TestResult ('HUB.ESTATE.{0}' -f $t) } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith { $script:calls.Add('telemetry ' + ($Target -join ',')); foreach ($t in $Target) { New-TestResult ('TELEMETRY.{0}' -f $t) } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ State = 'Ready'; Names = [pscustomobject]@{ ServerId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT4MetricFlow -MockWith { $script:calls.Add('metrics'); New-TestResult 'METRICS.T4' }
        # T4's read replica (ADR 0025): created when a run didn't create it, then read (its own tests are in DbHubDemo.T4Replica.Tests.ps1).
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4ReplicaDoneCheck -MockWith { $script:calls.Add('replica ' + (@($Missing | Where-Object { $_ -like '*.T4.REPLICA' }) -join ',')); New-TestResult 'HUB.ESTATE.T4.REPLICA'; New-TestResult 'METRICS.T4.REPLICA' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcCheck -MockWith { $script:calls.Add('arc ' + ($Check -join ',')); foreach ($c in $Check) { New-TestResult ('T2.ARC.{0}' -f $c.ToUpperInvariant()) } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmAssociatedService -MockWith { $script:calls.Add('inventory'); New-TestResult 'T1.SQLVM.ASSOCIATEDSERVICES' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricRequiredItem -MockWith { $script:calls.Add('fabric'); New-TestResult 'FABRIC.ITEMS.REQUIRED' }
        $seen = @((New-TestResult 'HUB.ESTATE.T1'), (New-TestResult 'HUB.ESTATE.T3'), (New-TestResult 'TELEMETRY.T1'), (New-TestResult 'TELEMETRY.T3'), (New-TestResult 'T2.ARC.SQLINSTANCE'), (New-TestResult 'TELEMETRY.T2' 'Warning'))
        $requirement = InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'PaygWizard' }
        $new = InModuleScope DbHubDemo -Parameters @{ Config = $config; Seen = $seen; Requirement = $requirement } { Invoke-DemoDoneGate -Config $Config -Result $Seen -Requirement $Requirement -TelemetryWaitMinutes 5 }
        $script:calls | Should -Be @('estate T2,T4', 'metrics', 'replica HUB.ESTATE.T4.REPLICA,METRICS.T4.REPLICA', 'arc Monitoring', 'inventory', 'fabric', 'telemetry T2') -Because 'the telemetry comes last, so its recovery runs only when the rest passed (Phase 28 live finding)'
        (InModuleScope DbHubDemo -Parameters @{ All = @($seen + $new); Requirement = $requirement } { Test-DemoDoneEvidence -Result $All -Requirement $Requirement }).Complete | Should -BeTrue
    }

    It 'checks the required Fabric items by name, and the Insights app isn''t one of them' {
        $config = New-TestConfig
        $script:asked = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { $token = [System.Security.SecureString]::new(); foreach ($character in 'not-a-real-token'.ToCharArray()) { $token.AppendChar($character) }; $token }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith { [pscustomobject]@{ WorkspaceId = '22222222-2222-2222-2222-222222222222'; LakehouseId = '33333333-3333-3333-3333-333333333333' } }
        Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith { $script:asked.Add(('{0}:{1}' -f $Type, $DisplayName)); [pscustomobject]@{ StatusCode = 200; Items = @(if ($DisplayName -ne $script:missing) { [pscustomobject]@{ id = '44444444-4444-4444-4444-444444444444' } }) } }
        $script:missing = ''
        $pass = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoFabricRequiredItem -Config $Config }
        $pass.status | Should -Be 'Pass'
        $script:asked | Should -Contain 'Notebook:NB_DatabaseHub_Deployment'
        $script:asked | Should -Contain 'KQLDashboard:RTD_DatabaseHub_LiveView'
        $script:asked | Should -Contain 'SemanticModel:SM_DatabaseHub_History'
        $script:asked | Should -Contain 'Report:RPT_DatabaseHub_History'
        @($script:asked | Where-Object { $_ -match 'APP_' }).Count | Should -Be 0
        $script:missing = 'RTD_DatabaseHub_LiveView'
        $fail = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoFabricRequiredItem -Config $Config }
        $fail.status | Should -Be 'Fail'
        $fail.message | Should -Match 'RTD_DatabaseHub_LiveView'
    }

    Context 'a list that didn''t answer isn''t a missing item (live finding, 2026-11-10)' {
        BeforeEach {
            $script:itemConfig = New-TestConfig
            $script:itemConfig['fabric']['workspaceName'] = 'Database Hub Demo Final Test'
            $script:itemWorkspaceId = '22222222-2222-2222-2222-222222222222'
            # What List Lakehouses answered live while the capacity's owner had paused it.
            $script:capacityNotActive = 'HTTP 404: CapacityNotActive: Internal error CapacityNotActive.Capacity is not active.'
            $script:resumeFix = 'Resume the capacity, or ask its administrator to (Azure portal: Microsoft Fabric, the capacity, Resume; that resumes its billing too).'
            $script:lakehouseRecord = $null
            $script:itemAnswer = @{}
            Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { $token = [System.Security.SecureString]::new(); foreach ($character in 'not-a-real-token'.ToCharArray()) { $token.AppendChar($character) }; $token }
            Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith {
                $copy = @{ subscriptionId = '11111111-2222-3333-4444-555555555555'; fabric = @{ workspaceName = 'Database Hub Demo Final Test'; workspaceId = $script:itemWorkspaceId } }
                $lakehouse = if ($null -ne $script:lakehouseRecord) { $script:lakehouseRecord } else { New-DemoResult -CheckId 'FABRIC.RESOLVE.LAKEHOUSE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Found the lakehouse.' }
                $records = @((New-DemoResult -CheckId 'FABRIC.RESOLVE.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Found the workspace.'), $lakehouse)
                [pscustomobject]@{ Resolved = ($null -eq $script:lakehouseRecord); Config = $copy; WorkspaceId = $script:itemWorkspaceId; WorkspaceName = 'Database Hub Demo Final Test'; LakehouseId = $(if ($null -eq $script:lakehouseRecord) { '33333333-3333-3333-3333-333333333333' } else { '' }); Results = $records }
            }
            # The workspace's item list still answers on a paused capacity, as it did live.
            Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith {
                if ($script:itemAnswer.ContainsKey($DisplayName)) {
                    return $script:itemAnswer[$DisplayName]
                }
                [pscustomobject]@{ StatusCode = 200; Items = @([pscustomobject]@{ id = '44444444-4444-4444-4444-444444444444'; displayName = $DisplayName }); Error = '' }
            }
            Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -MockWith {
                New-DemoResult -CheckId 'FABRIC.P5.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'You have Contributor or higher.'
                New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The capacity "fabricmbprod" (F4) of the Fabric workspace "Database Hub Demo Final Test" is Inactive, so notebooks can''t run.' -Evidence ([ordered]@{ capacityName = 'fabricmbprod'; sku = 'F4'; state = 'Inactive' }) -Remediation $script:resumeFix
            }
            # The capacity is its owner's: nothing here may resume, pause, or scale it.
            Mock -ModuleName DbHubDemo -CommandName Resume-DemoFabricCapacity -MockWith { throw 'resumed a capacity' }
            Mock -ModuleName DbHubDemo -CommandName Suspend-DemoFabricCapacity -MockWith { throw 'paused a capacity' }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricCapacityTransition -MockWith { throw 'changed a capacity' }
        }

        It 'calls a lakehouse that Fabric doesn''t list for a paused capacity unchecked, never missing, and names the capacity first in NOT DONE, with its resume as the next step' {
            $script:lakehouseRecord = New-DemoResult -CheckId 'FABRIC.RESOLVE.LAKEHOUSE' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message ('The lakehouses in the workspace "Database Hub Demo Final Test" couldn''t be listed, because its capacity is paused or inactive: {0}' -f $script:capacityNotActive) -Evidence ([ordered]@{ lakehouseName = 'LH_DatabaseHub'; statusCode = 404; listed = $false; error = $script:capacityNotActive; capacityInactive = $true }) -Remediation ('{0} Then run the script again.' -f $script:resumeFix)
            $records = @(InModuleScope DbHubDemo -Parameters @{ Config = $script:itemConfig } { Test-DemoFabricRequiredItem -Config $Config })
            $records.checkId | Should -Be @('FABRIC.P5.CAPACITY', 'FABRIC.ITEMS.REQUIRED') -Because 'the capacity''s own record comes first, so the run names it'
            $items = $records[1]
            $items.status | Should -Be 'Manual action required'
            $items.message | Should -Be ('The required Fabric items couldn''t all be checked: the capacity "fabricmbprod" (F4) of the workspace "Database Hub Demo Final Test" is Inactive, so Fabric didn''t list the lakehouse LH_DatabaseHub ({0}). That doesn''t mean it''s missing: Fabric lists it again once the capacity is resumed.' -f $script:capacityNotActive.TrimEnd('.'))
            $items.message | Should -Not -Match 'is missing'
            $items.evidence['capacityInactive'] | Should -Be $true
            @($items.evidence['missing']).Count | Should -Be 0
            $items.evidence['unchecked'][0]['statusCode'] | Should -Be 404
            $items.remediation | Should -Be ('{0} Then run ./scripts/deploy.ps1 again.' -f $script:resumeFix)
            $items.remediation | Should -Not -Match 'start-demo|stop-demo|manageCapacity|imports what'
            $items.docUrl | Should -Be 'https://learn.microsoft.com/fabric/enterprise/pause-resume'

            # The live run's order: the Insights app's capacity check passed (00:32), then the validation's lakehouse list
            # and capacity check (00:47), then DONE's checks.
            $earlier = New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'The Fabric workspace "Database Hub Demo Final Test" is on the Active Fabric capacity "fabricmbprod" (F4, West US 3).' -Evidence ([ordered]@{ capacityName = 'fabricmbprod'; sku = 'F4'; state = 'Active' })
            $result = @(New-DoneResult | Where-Object { $_.checkId -ne 'FABRIC.ITEMS.REQUIRED' }) + @($earlier, $script:lakehouseRecord, $records[0]) + @($records)
            $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = $script:itemConfig } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
            $outcome.Kind | Should -Be 'NotDone'
            $outcome.Reason | Should -Be 'FABRIC.P5.CAPACITY: The capacity "fabricmbprod" (F4) of the Fabric workspace "Database Hub Demo Final Test" is Inactive, so notebooks can''t run.'
            $outcome.Next | Should -Be ('{0} Then run ./scripts/deploy.ps1.' -f $script:resumeFix)
            $outcome.NextCommand | Should -Be './scripts/deploy.ps1'
            ('{0} {1}' -f $outcome.Reason, $outcome.Next) | Should -Not -Match 'missing'
            $lines = InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }
            ($lines -join "`n") | Should -Match 'Why: FABRIC\.P5\.CAPACITY: The capacity "fabricmbprod" \(F4\)'
            ($lines -join "`n") | Should -Match ([regex]::Escape(('Next: {0} Then run ./scripts/deploy.ps1.' -f $script:resumeFix)))
        }

        It 'calls an item that Fabric throttled or didn''t answer unchecked, with the HTTP status, and the fix is to run again in a few minutes: HTTP <Code>' -ForEach @(
            @{ Code = 429; Fix = 'Fabric is throttling requests (HTTP 429), even after retries: run ./scripts/deploy.ps1 again in a few minutes.' }
            @{ Code = 503; Fix = 'Fabric didn''t answer the list (HTTP 503), even after retries: run ./scripts/deploy.ps1 again in a few minutes.' }
        ) {
            $script:itemAnswer = @{ 'RTD_DatabaseHub_LiveView' = [pscustomobject]@{ StatusCode = $Code; Items = @(); Error = ('HTTP {0} RequestBlocked Try again later.' -f $Code) } }
            $records = @(InModuleScope DbHubDemo -Parameters @{ Config = $script:itemConfig } { Test-DemoFabricRequiredItem -Config $Config })
            $records.Count | Should -Be 1
            $records[0].status | Should -Be 'Warning'
            $records[0].message | Should -Be ('The required Fabric items couldn''t all be checked: Fabric didn''t list RTD_DatabaseHub_LiveView (HTTP {0} RequestBlocked Try again later). That doesn''t mean it''s missing.' -f $Code)
            $records[0].remediation | Should -Be $Fix
            $records[0].evidence['unchecked'][0]['statusCode'] | Should -Be $Code
            @($records[0].evidence['missing']).Count | Should -Be 0
            Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -Times 0 -Exactly -Because 'only a paused capacity is read again'

            $result = @(New-DoneResult | Where-Object { $_.checkId -ne 'FABRIC.ITEMS.REQUIRED' }) + @($records)
            $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = $script:itemConfig } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
            $outcome.Kind | Should -Be 'NotDone'
            $outcome.Reason | Should -Match ('^FABRIC\.ITEMS\.REQUIRED hasn''t passed yet \(Warning\): The required Fabric items couldn''t all be checked: Fabric didn''t list RTD_DatabaseHub_LiveView \(HTTP {0} ' -f $Code)
            $outcome.Next | Should -Be $Fix
            $outcome.NextCommand | Should -Be './scripts/deploy.ps1'
        }

        It 'still calls an item missing when its list answered without it, with the rerun that imports it, and names what couldn''t be checked besides' {
            $script:lakehouseRecord = New-DemoResult -CheckId 'FABRIC.RESOLVE.LAKEHOUSE' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'The lakehouse "LH_DatabaseHub" isn''t in the workspace "Database Hub Demo Final Test".' -Evidence ([ordered]@{ lakehouseName = 'LH_DatabaseHub'; createIfMissing = $true })
            $records = @(InModuleScope DbHubDemo -Parameters @{ Config = $script:itemConfig } { Test-DemoFabricRequiredItem -Config $Config })
            $records.Count | Should -Be 1
            $records[0].status | Should -Be 'Fail'
            $records[0].message | Should -Be 'The workspace "Database Hub Demo Final Test" is missing: the lakehouse LH_DatabaseHub.'
            $records[0].remediation | Should -Be 'Run ./scripts/deploy.ps1 again: its Fabric track imports what''s missing (configure-fabric.ps1 and configure-powerbi.ps1).'
            @($records[0].evidence['missing']) | Should -Be @('the lakehouse LH_DatabaseHub')
            Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -Times 0 -Exactly

            $script:itemAnswer = @{ 'RTD_DatabaseHub_LiveView' = [pscustomobject]@{ StatusCode = 503; Items = @(); Error = 'HTTP 503 ServiceUnavailable' } }
            $both = @(InModuleScope DbHubDemo -Parameters @{ Config = $script:itemConfig } { Test-DemoFabricRequiredItem -Config $Config })
            $both[0].status | Should -Be 'Fail'
            $both[0].message | Should -Be 'The workspace "Database Hub Demo Final Test" is missing: the lakehouse LH_DatabaseHub. Fabric didn''t list RTD_DatabaseHub_LiveView (HTTP 503 ServiceUnavailable), so that one couldn''t be checked.'
        }

        It 'names a paused capacity first only while it''s the latest word on it, ahead of a Fail elsewhere' {
            $inactive = New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The capacity "fabricmbprod" (F4) of the Fabric workspace "Database Hub Demo Final Test" is Inactive, so notebooks can''t run.' -Evidence ([ordered]@{ sku = 'F4'; state = 'Inactive' }) -Remediation $script:resumeFix
            $active = New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Active.' -Evidence ([ordered]@{ sku = 'F4'; state = 'Active' })
            $sign = New-DemoResult -CheckId 'FABRIC.ITEMS.REQUIRED' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The required Fabric items couldn''t all be checked: the capacity of the workspace "Database Hub Demo Final Test" is paused or inactive.' -Evidence ([ordered]@{ capacityInactive = $true }) -Remediation ('{0} Then run ./scripts/deploy.ps1 again.' -f $script:resumeFix)
            $telemetry = New-TestResult 'TELEMETRY.T1' 'Fail'
            $block = { param([object[]] $Items) InModuleScope DbHubDemo -Parameters @{ Items = $Items } { Get-DemoFabricCapacityBlock -Result $Items } }
            (& $block @($telemetry, $sign, $inactive)).checkId | Should -Be 'FABRIC.P5.CAPACITY'
            & $block @($sign, $inactive, $active) | Should -BeNullOrEmpty -Because 'the capacity was Active when it was last read'
            (& $block @($active, $sign)).checkId | Should -Be 'FABRIC.ITEMS.REQUIRED' -Because 'it paused after the last read'
            & $block @($telemetry) | Should -BeNullOrEmpty

            $result = @(New-DoneResult | Where-Object { $_.checkId -notin 'TELEMETRY.T1', 'FABRIC.ITEMS.REQUIRED' }) + @($telemetry, $inactive, $sign)
            $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = $script:itemConfig } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
            $outcome.Reason | Should -Match '^FABRIC\.P5\.CAPACITY: '
            $outcome.ExitCode | Should -Be 1 -Because 'a Fail is still a Fail'
            $resumed = @(New-DoneResult | Where-Object { $_.checkId -ne 'TELEMETRY.T1' }) + @($inactive, $active, $telemetry)
            $later = InModuleScope DbHubDemo -Parameters @{ Result = $resumed; State = (New-FinishedState); Config = $script:itemConfig } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
            $later.Reason | Should -Match '^TELEMETRY\.T1: ' -Because 'a capacity Active when it was last read isn''t the reason'
        }
    }
}

Describe 'The one ending: DONE or NOT DONE (brief items 1, 15, 16)' {
    It 'is DONE, exit code 0, when every track finished and every requirement passed, with where to look' {
        $config = New-TestConfig -WithT4
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult -WithT4); State = (New-FinishedState -WithT4); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        $outcome.ExitCode | Should -Be 0
        $outcome.Reason | Should -Match 'T1, T2, T3, and T4 in Estate'
        $lines = InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome -Minutes 130 -WorkspaceName 'Database Hub Demo' }
        ($lines -join ' ') | Should -Match '##  DONE'
        ($lines -join ' ') | Should -Match 'The demo is complete\.'
        ($lines -join ' ') | Should -Match 'Where to look: open Database Hub'
        ($lines -join ' ') | Should -Match 'capture-t2-golden\.ps1 to make future redeploys skip T2''s build'
    }

    It 'is DONE, naming the Insights app as a failure that doesn''t block DONE with its reason and fix, when its prerequisites aren''t met (2026-11-05)' {
        $config = New-TestConfig -WithT4
        $result = @(New-DoneResult -WithT4) + @(
            (New-DemoResult -CheckId 'FABRIC.APP.TENANTSETTING' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'The Fabric tenant setting "Fabric Apps (preview)" is disabled.' -Remediation 'Ask a Fabric administrator.')
            (New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.DATA' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'Execute Queries is off.' -Remediation 'Turn it on.')
        )
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState -WithT4); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        $outcome.ExitCode | Should -Be 0
        @($outcome.NonBlocking).Count | Should -Be 2
        $outcome.NonBlocking[0]['state'] | Should -Be 'Failed'
        $outcome.NonBlocking[1]['state'] | Should -Be 'Action needed'
        $outcome.Reason | Should -Match 'the Real-Time Dashboard, and the history report\.' -Because 'the app wasn''t created, so DONE doesn''t claim it'
        $lines = @(InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome })
        $text = $lines -join ' '
        $text | Should -Match ([regex]::Escape('Failed (doesn''t block DONE): the Insights app. It wasn''t created: FABRIC.APP.TENANTSETTING: The Fabric tenant setting "Fabric Apps (preview)" is disabled.'))
        $text | Should -Match ([regex]::Escape('Action needed (doesn''t block DONE): the history report''s data check.'))
        $text | Should -Match 'Fabric Apps \(preview\) and Dataset Execute Queries REST API'
        $text | Should -Match 'configure-fabric-app\.ps1 -SignIn'
        $text | Should -Match 'an assistant can''t do that sign-in for you'
        $text | Should -Not -Match '(?i)optional'
        # Right after the reason, before "Where to look", so it isn't missed.
        [array]::IndexOf($lines, @($lines | Where-Object { $_ -like 'Failed (doesn''t block DONE)*' })[0]) | Should -BeLessThan ([array]::IndexOf($lines, @($lines | Where-Object { $_ -like 'Where to look*' })[0]))
    }

    It 'is DONE when the app''s own workspace lookup failed, and says that, not a tenant setting, is why (Phase 28 live finding)' {
        # Live: the app's step failed FABRIC.RESOLVE.WORKSPACE, a check ID that isn't the app's own, so it would have
        # counted as a Fail of the demo, and the page blamed tenant settings that were on.
        $config = New-TestConfig -WithT4
        $appRecords = InModuleScope DbHubDemo {
            foreach ($record in @(
                    (New-DemoResult -CheckId 'FABRIC.RESOLVE.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'Your Fabric workspaces couldn''t be listed: HTTP 429.' -Remediation 'Check your Fabric access, then run the script again.')
                    (New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'The Fabric workspace isn''t resolved, so nothing was deployed.')
                )) {
                ConvertTo-DemoInsightsAppRecord -Record $record
            }
        }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult -WithT4) + @($appRecords)); State = (New-FinishedState -WithT4); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        $outcome.ExitCode | Should -Be 0
        @($outcome.NonBlocking).Count | Should -Be 1
        $outcome.NonBlocking[0]['message'] | Should -Match ([regex]::Escape('FABRIC.RESOLVE.WORKSPACE: Your Fabric workspaces couldn''t be listed'))
        $outcome.NonBlocking[0]['howTo'] | Should -Not -Match 'tenant settings'
        $lines = (InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) -join ' '
        $lines | Should -Match ([regex]::Escape('Failed (doesn''t block DONE): the Insights app. It wasn''t created: FABRIC.RESOLVE.WORKSPACE'))
    }

    It 'says DONE includes the Insights app when this run deployed it (2026-11-05)' {
        $config = New-TestConfig -WithT4
        $appRecords = InModuleScope DbHubDemo {
            foreach ($record in @(
                    (New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Deployed.')
                    (New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Every query returned rows.')
                )) {
                ConvertTo-DemoInsightsAppRecord -Record $record
            }
        }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult -WithT4) + @($appRecords)); State = (New-FinishedState -WithT4); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        $outcome.Reason | Should -Match 'the Real-Time Dashboard, the history report, and the Insights app\.'
        @($outcome.NonBlocking).Count | Should -Be 0
    }

    It 'stays DONE and says so when Run Commands ran under a fresh name because Azure kept their own in Deleting (2026-11-13 live finding)' {
        $config = New-TestConfig -WithT4
        $stuck = @(InModuleScope DbHubDemo {
                $script:DemoRunCommandStuck.Clear()
                $script:DemoRunCommandStuck.Add([pscustomobject]@{ VmName = 'archost01'; Name = 'DbHubDemo-HealthRead'; FreshName = 'DbHubDemo-HealthRead-20261113213000'; AtUtc = [datetime]::UtcNow; WaitedSeconds = 300; Listed = 12; Deleting = 1 })
                Get-DemoRunCommandStuckResult -Clear
            })
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult -WithT4) + $stuck); State = (New-FinishedState -WithT4); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done' -Because 'a stuck name held nothing up'
        ($outcome.Notes -join ' ') | Should -Match 'Azure kept Run Command names on archost01 in Deleting, so 1 Run Command run\(s\) used a fresh name instead of waiting \(DEPLOY\.RUNCOMMAND\.STUCK\): nothing to do'
    }

    It 'is NOT DONE when Azure refused every T4 size, with why and the fix, never DONE without T4 (2026-11-09)' {
        $config = New-TestConfig -WithoutT4
        $refusal = InModuleScope DbHubDemo { New-DemoT4FallbackResult -Refused $null -Next 'Refused' }
        $result = @(New-DoneResult | Where-Object { $_.checkId -notin 'HUB.ESTATE.T4', 'METRICS.T4' }) + @($refusal)
        $state = New-FinishedState
        $state.TrackT4 = ''
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = $state; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.Done | Should -BeFalse
        $outcome.Reason | Should -Match 'refused every size'
        ($outcome.Notes -join ' ') | Should -Match 'DONE needs it'
        ($outcome.Notes -join ' ') | Should -Match 'Region access request'
        $outcome.Unfinished | Should -Contain 'T4'
    }

    It 'lets a t4SkuName the configuration sets win over a recorded "no T4", so DONE still needs T4 (review finding 5)' {
        $sized = New-TestConfig -WithT4
        $sized['t4SkuName'] = 'Standard_D2ds_v5'
        (InModuleScope DbHubDemo -Parameters @{ Config = $sized } { Get-DemoT4OffReason -Config $Config -State ([pscustomobject]@{ T4Sku = 'None' }) }) | Should -BeNullOrEmpty
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult | Where-Object { $_.checkId -notin 'HUB.ESTATE.T4', 'METRICS.T4' }); State = (New-FinishedState -WithT4 -T4Sku 'None'); Config = $sized } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'NotDone' -Because 'a T4 that''s on must show in Database Hub'
        $outcome.Missing | Should -Contain 'HUB.ESTATE.T4'
        $outcome.Missing | Should -Contain 'METRICS.T4'
        ($outcome.Notes -join ' ') | Should -Not -Match 'Azure refused'

        # 2026-11-09: no record turns T4 off any more, whatever an earlier fallback recorded.
        (InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4OffReason -Config $Config -State ([pscustomobject]@{ T4Sku = 'None' }) }) | Should -BeNullOrEmpty
    }

    It 'states plainly in Developer mode that T2 has no performance data or agent findings' {
        $config = New-TestConfig -InstallMode 'Developer'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult -InstallMode 'Developer'); State = (New-FinishedState); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        ($outcome.Notes -join ' ') | Should -Match 'T2 has no performance data or Database Agent findings'
        $lines = (InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) -join ' '
        $lines | Should -Match 'no performance data or Database Agent findings'
    }

    It 'is NOT DONE, exit code 1, with a Fail: why, the fix, the exact command, how to resume, and the diagnostics bundle' {
        $config = New-TestConfig
        $result = @(New-DoneResult) + @(New-TestResult 'DEPLOY.EXTENSIONS_SQLVM01' 'Fail')
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.ExitCode | Should -Be 1
        $lines = (InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) -join "`n"
        $lines | Should -Match '##  NOT DONE'
        $lines | Should -Match 'Why: DEPLOY\.EXTENSIONS_SQLVM01'
        $lines | Should -Match 'Run: \./scripts/deploy\.ps1'
        $lines | Should -Match 'If this window closes or the PC restarts, run \./scripts/deploy\.ps1 again; it continues where it stopped\.'
        $lines | Should -Match 'collect-diagnostics\.ps1'
    }

    It 'is NOT DONE, exit code 2, while a track is unfinished or a requirement hasn''t passed, never DONE by deployment success alone' {
        $config = New-TestConfig
        $unfinished = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = ([pscustomobject]@{ Stage = 'Monitoring'; TrackT1 = 'Telemetry'; TrackT2 = 'T2'; TrackT4 = 'Telemetry'; TrackFabric = 'Fabric'; T4Sku = '' }); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $unfinished.Kind | Should -Be 'NotDone'
        $unfinished.ExitCode | Should -Be 2
        $unfinished.Unfinished | Should -Be @('T2')
        $missing = @(New-DoneResult | Where-Object { $_.checkId -ne 'TELEMETRY.T2' }) + @(New-TestResult 'TELEMETRY.T2' 'Warning')
        $notYet = InModuleScope DbHubDemo -Parameters @{ Result = $missing; State = (New-FinishedState); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $notYet.Kind | Should -Be 'NotDone'
        $notYet.Missing | Should -Be @('TELEMETRY.T2')
        $notYet.Reason | Should -Match 'TELEMETRY\.T2 hasn''t passed yet'
        $notYet.Next | Should -Match 'Wait about 10 minutes'
    }

    It 'is never DONE while a guided stop''s Bastion or a handed-over host password is still open, and names stop-demo.ps1 (Phase 28 review)' {
        # The review: after a Ctrl+C at the guided stop, setup finished anyway, and the next run ended DONE with Bastion up
        # and the handed-over password valid.
        $config = New-TestConfig
        $password = New-FinishedState
        $password.HostPasswordUtc = '2026-10-29T15:00:00Z'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = $password; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.ExitCode | Should -Be 2
        $outcome.Reason | Should -Match 'host''s password, handed over at 2026-10-29T15:00:00Z and not rotated yet'
        $outcome.NextCommand | Should -Be './scripts/stop-demo.ps1 -RemoveBastionOnly'
        $outcome.Next | Should -Match 'removes Bastion and rotates the host password'
        $lines = (InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) -join "`n"
        $lines | Should -Match ([regex]::Escape('Run: ./scripts/stop-demo.ps1 -RemoveBastionOnly'))

        # The guided stop's own record (its cleanup didn't finish), with a configuration of its own: the command keeps it.
        $bastion = New-FinishedState
        $bastion.GuidedStopUtc = '2026-10-29T16:00:00Z'
        $own = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = $bastion; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Command './scripts/deploy.ps1 -ConfigPath "./config/proof.local.json"' }
        $own.Kind | Should -Be 'NotDone'
        $own.Reason | Should -Match 'the guided stop''s on-demand Bastion'
        $own.NextCommand | Should -Be './scripts/stop-demo.ps1 -RemoveBastionOnly -ConfigPath "./config/proof.local.json"'

        # deploy.ps1 -Sequential is judged the same way.
        $sequential = [pscustomobject]@{ Stage = 'Validation'; TrackT1 = ''; TrackT2 = ''; TrackT4 = ''; TrackFabric = ''; T4Sku = ''; GuidedStopUtc = ''; HostPasswordUtc = '2026-10-29T15:00:00Z' }
        (InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = $sequential; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Sequential }).Kind | Should -Be 'NotDone'

        # The T2 step's own record of a cleanup that couldn't finish names the same command.
        $leftover = @(New-DoneResult) + @(New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDLEFTOVER' -Area 'infra' -Target 'T2' -Status 'Manual action required' -Message 'Still open.' -Remediation 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly.')
        $step = InModuleScope DbHubDemo -Parameters @{ Result = $leftover; State = $password; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $step.Reason | Should -Match 'DEPLOY\.T2\.GUIDEDLEFTOVER'
        $step.NextCommand | Should -Be './scripts/stop-demo.ps1 -RemoveBastionOnly'

        # The T2 track's cleanup before the loader is provisional (review of 27396a4): what's still open there is a Warning,
        # and the T2 step's own cleanup, and the state DONE reads, give the final word.
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { $script:leftState }
        Mock -ModuleName DbHubDemo -CommandName Complete-DemoGuidedStop -MockWith { @() }
        $script:leftState = New-FinishedState
        $script:leftState.HostPasswordUtc = '2026-10-29T15:00:00Z'
        $early = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Clear-DemoGuidedStopLeftover -Config $Config -Provisional -Confirm:$false }) | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' }
        $early.status | Should -Be 'Warning'
        (@(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Clear-DemoGuidedStopLeftover -Config $Config -Confirm:$false }) | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' }).status | Should -Be 'Manual action required' -Because 'the T2 step''s own cleanup has the final word'
        $later = New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDLEFTOVER' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'Cleaned up what an earlier guided stop or session left open; none of it is left.'
        $cleaned = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult) + @($early, $later); State = (New-FinishedState); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $cleaned.Kind | Should -Be 'Done'
        $cleaned.ExitCode | Should -Be 0
        # The state still records it: NOT DONE, naming stop-demo.ps1, whatever the run's results say.
        $stillOpen = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult) + @($early); State = $script:leftState; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $stillOpen.Kind | Should -Be 'NotDone'
        $stillOpen.NextCommand | Should -Be './scripts/stop-demo.ps1 -RemoveBastionOnly'

        # Another reason first: the leftover is still said.
        $unfinished = [pscustomobject]@{ Stage = 'Monitoring'; TrackT1 = 'Telemetry'; TrackT2 = 'T2'; TrackT4 = ''; TrackFabric = 'Fabric'; T4Sku = ''; GuidedStopUtc = ''; HostPasswordUtc = '2026-10-29T15:00:00Z' }
        $both = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = $unfinished; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $both.Reason | Should -Match 'Not every target finished: T2'
        ($both.Notes -join ' ') | Should -Match 'Also still open from an earlier guided stop or session'
    }

    It 'is WHAT IF, exit code 0, for a -WhatIf without a Fail' {
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = @(New-TestResult 'PREFLIGHT.P1.SUBSCRIPTION'); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -Config $Config -WhatIfRun }
        $outcome.Kind | Should -Be 'WhatIf'
        $outcome.ExitCode | Should -Be 0
    }

    It 'judges a -Sequential run by its recorded stage, which records no tracks, so it can be DONE (review finding 4)' {
        $config = New-TestConfig
        $sequentialState = [pscustomobject]@{ Stage = 'Validation'; TrackT1 = ''; TrackT2 = ''; TrackT4 = ''; TrackFabric = ''; T4Sku = '' }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = $sequentialState; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Sequential }
        $outcome.Kind | Should -Be 'Done'
        $outcome.ExitCode | Should -Be 0

        $open = [pscustomobject]@{ Stage = 'Monitoring'; TrackT1 = ''; TrackT2 = ''; TrackT4 = ''; TrackFabric = ''; T4Sku = '' }
        $notDone = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = $open; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Sequential }
        $notDone.Kind | Should -Be 'NotDone'
        $notDone.ExitCode | Should -Be 2
        $notDone.Reason | Should -Match 'Not every stage finished: the last one recorded is Monitoring'
        # A plain deploy.ps1 continues after the recorded stage, with the guided stop that -Sequential doesn't have.
        $notDone.NextCommand | Should -Be './scripts/deploy.ps1'

        # Without a state, the run's DEPLOY.STAGE.VALIDATION stands in.
        $stand = @(New-DoneResult) + @(New-TestResult 'DEPLOY.STAGE.VALIDATION')
        (InModuleScope DbHubDemo -Parameters @{ Result = $stand; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $null -Config $Config -Sequential }).Kind | Should -Be 'Done'
    }
}

Describe 'NOT DONE names the exact command its fix needs, with the run''s -ConfigPath (live finding, 2026-11-06)' {
    BeforeAll {
        # The T2 track's remediation for a host step that failed, as TrackHelpers.ps1 writes it.
        $script:hostFix = 'Read archost01''s health (Get-DemoVmHealth -VmName archost01 -View Full) and C:\ProgramData\DbHubDemo\logs on it, fix the cause, then run ./scripts/deploy.ps1 -FromStage Artifacts: a failed step is tried again only in a new bootstrap generation, which that starts (a plain rerun resumes and finds the same step failed, unless your fix changed the bootstrap bundle, which a plain rerun then sends again, starting one too).'
        $script:own = './scripts/deploy.ps1 -ConfigPath "./config/livetest.local.json"'
    }

    It 'gives the same command in Next and on the Run line, built from the run''s own command' {
        # Live (15:05Z): Next said -FromStage Artifacts, the Run line gave the plain command, and neither kept -ConfigPath.
        $config = New-TestConfig
        $result = @(New-DoneResult) + @(New-DemoResult -CheckId 'DEPLOY.T2.HOST' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'archost01 failed at step JumpstartImageCheck: SQL Server is Developer Edition.' -Remediation $script:hostFix)
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = $config; Command = $script:own } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Command $Command }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.ExitCode | Should -Be 1
        $outcome.NextCommand | Should -Be './scripts/deploy.ps1 -ConfigPath "./config/livetest.local.json" -FromStage Artifacts'
        $outcome.Next | Should -Match ([regex]::Escape('then run ./scripts/deploy.ps1 -ConfigPath "./config/livetest.local.json" -FromStage Artifacts: a failed step is tried again only in a new bootstrap generation'))
        $outcome.Next | Should -Match 'unless your fix changed the bootstrap bundle' -Because 'the common case, a transient failure or a fix outside the bundle, needs the new generation that -FromStage Artifacts starts'
        $lines = @(InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome })
        $lines | Should -Contain 'Run: ./scripts/deploy.ps1 -ConfigPath "./config/livetest.local.json" -FromStage Artifacts'

        # The default configuration: the same command without -ConfigPath.
        $plain = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $plain.NextCommand | Should -Be './scripts/deploy.ps1 -FromStage Artifacts'
    }

    It 'takes a requirement''s own fix the same way, and keeps the plain command when the fix names none' {
        $config = New-TestConfig
        $missing = @(New-DoneResult | Where-Object { $_.checkId -ne 'T2.ARC.MONITORING' }) + @(New-DemoResult -CheckId 'T2.ARC.MONITORING' -Area 't2' -Target 'T2' -Status 'Warning' -Message 'Monitoring is off.' -Remediation 'Fix T2''s monitoring, then run deploy.ps1 -FromStage T2.')
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $missing; State = (New-FinishedState); Config = $config; Command = $script:own } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Command $Command }
        $outcome.Missing | Should -Be @('T2.ARC.MONITORING')
        $outcome.NextCommand | Should -Be ('{0} -FromStage T2' -f $script:own)
        $outcome.Next | Should -Be ('Fix T2''s monitoring, then run {0} -FromStage T2.' -f $script:own)

        $other = @(New-DoneResult) + @(New-DemoResult -CheckId 'FABRIC.P4.HUBSETTING' -Area 'fabric' -Target 'tenant' -Status 'Fail' -Message 'Off.' -Remediation 'A Fabric administrator turns it on.')
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $other; State = (New-FinishedState); Config = $config; Command = $script:own } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Command $Command }
        $outcome.NextCommand | Should -Be $script:own
        $outcome.Next | Should -Be ('A Fabric administrator turns it on. Then run {0}.' -f $script:own)
    }

    It 'names the plain command for a fix that says deploy.ps1 -Resume, which starts over when the stage reached Validation (review finding)' {
        # A rerun after DONE starts over; when its template then fails, the recorded stage stays Validation, where -Resume
        # would skip preflight and the template and run every track against the failed deployment's outputs.
        $config = New-TestConfig
        $templateFix = 'Fix the cause in the message, then run deploy.ps1 -Resume. A 409 Conflict while a policy installs an extension clears within minutes.'
        $failed = @(New-DoneResult) + @(New-DemoResult -CheckId 'DEPLOY.TEMPLATE' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message 'The deployment failed: Conflict.' -Remediation $templateFix)
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $failed; State = (New-FinishedState); Config = $config; Command = $script:own } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Command $Command }
        $outcome.NextCommand | Should -Be $script:own
        $outcome.Next | Should -Be ('Fix the cause in the message, then run {0}. A 409 Conflict while a policy installs an extension clears within minutes.' -f $script:own)
        # deploy.ps1 resumes by itself only while the recorded stage isn't Validation (-AutoResume); there, -Resume would skip
        # the template, and the plain command's plan runs it.
        $state = [pscustomobject]@{ Stage = 'Validation' }
        (InModuleScope DbHubDemo -Parameters @{ State = $state } { Resolve-DemoTrackPlan -Resume -State $State }).Infrastructure | Should -BeFalse
        $plain = InModuleScope DbHubDemo -Parameters @{ State = $state } { Resolve-DemoTrackPlan -State $State }
        $plain.Preflight | Should -BeTrue
        $plain.Infrastructure | Should -BeTrue
    }

    It 'gives a script that the fix names the run''s -ConfigPath too, when the fix names no deploy.ps1' {
        $config = New-TestConfig
        $vmStart = @(New-DoneResult) + @(New-DemoResult -CheckId 'DEPLOY.VMSTART' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'archost01 didn''t start.' -Remediation 'Start it in the portal, or run ./scripts/start-demo.ps1.')
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $vmStart; State = (New-FinishedState); Config = $config; Command = $script:own } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Command $Command }
        $outcome.NextCommand | Should -Be $script:own
        $outcome.Next | Should -Be ('Start it in the portal, or run ./scripts/start-demo.ps1 -ConfigPath "./config/livetest.local.json". Then run {0}.' -f $script:own)

        $missing = @(New-DoneResult | Where-Object { $_.checkId -ne 'T2.ARC.MONITORING' }) + @(New-DemoResult -CheckId 'T2.ARC.MONITORING' -Area 't2' -Target 'T2' -Status 'Warning' -Message 'Monitoring is off.' -Remediation 'Run ./scripts/configure-monitoring.ps1 -Target T2.')
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $missing; State = (New-FinishedState); Config = $config; Command = $script:own } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Command $Command }
        $outcome.NextCommand | Should -Be $script:own
        $outcome.Next | Should -Be ('Run ./scripts/configure-monitoring.ps1 -ConfigPath "./config/livetest.local.json" -Target T2. Then run {0}.' -f $script:own)
    }

    It 'writes each deploy.ps1 to run as the run''s command, gives the other scripts its -ConfigPath, and leaves mentions in passing alone' {
        $named = InModuleScope DbHubDemo -Parameters @{ Command = $script:own } { Resolve-DemoDeployCommandText -Text 'Set t2SqlInstallMode back, then run ./scripts/deploy.ps1 -FromStage Infrastructure; or rebuild T2: ./scripts/destroy.ps1, then ./scripts/deploy.ps1.' -Command $Command }
        $named.Command | Should -Be ('{0} -FromStage Infrastructure' -f $script:own)
        $named.Text | Should -Be ('Set t2SqlInstallMode back, then run {0} -FromStage Infrastructure; or rebuild T2: ./scripts/destroy.ps1 -ConfigPath "./config/livetest.local.json", then {0}.' -f $script:own)

        $passing = InModuleScope DbHubDemo -Parameters @{ Command = $script:own } { Resolve-DemoDeployCommandText -Text 'deploy.ps1''s watchdog restarts the VM once; the next deploy.ps1 does the rest.' -Command $Command }
        $passing.Command | Should -BeNullOrEmpty
        $passing.Text | Should -Be 'deploy.ps1''s watchdog restarts the VM once; the next deploy.ps1 does the rest.'

        $resume = InModuleScope DbHubDemo -Parameters @{ Command = $script:own } { Resolve-DemoDeployCommandText -Text 'Run deploy.ps1 -Resume later; it keeps converging. Then run deploy.ps1 again.' -Command $Command }
        $resume.Command | Should -Be $script:own -Because 'a plain run resumes by itself, and after a run whose stage reached Validation it starts over, where -Resume would run only the validation'
        $resume.Text | Should -Be ('Run {0} later; it keeps converging. Then run {0} again.' -f $script:own)

        $switch = InModuleScope DbHubDemo -Parameters @{ Command = $script:own } { Resolve-DemoDeployCommandText -Text 'Run deploy.ps1 -SkipRunner now; the VMs keep their runner.' -Command $Command }
        $switch.Command | Should -Be ('{0} -SkipRunner' -f $script:own) -Because 'a switch takes no value: "now" stays text'
        $switch.Text | Should -Be ('Run {0} -SkipRunner now; the VMs keep their runner.' -f $script:own)

        # A command that already names its configuration keeps it; the default configuration adds nothing to other scripts.
        $already = InModuleScope DbHubDemo -Parameters @{ Command = $script:own } { Resolve-DemoDeployCommandText -Text 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly -ConfigPath "./config/a.json". Then go on.' -Command $Command }
        $already.Text | Should -Be 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly -ConfigPath "./config/a.json". Then go on.'
        $default = InModuleScope DbHubDemo { Resolve-DemoDeployCommandText -Text 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly, then deploy.ps1 -FromStage T2.' -Command './scripts/deploy.ps1' }
        $default.Text | Should -Be 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly, then ./scripts/deploy.ps1 -FromStage T2.'
        $default.Command | Should -Be './scripts/deploy.ps1 -FromStage T2'
    }

    It 'logs every remediation with the run''s command in deploy.ps1''s report; the results stay as they are' {
        $script:logged = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add($Message) }
        $results = @(
            (New-DemoResult -CheckId 'DEPLOY.T2.HOST' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'failed' -Remediation 'Fix it, then run ./scripts/deploy.ps1 -FromStage Artifacts.')
            (New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDSTOP' -Area 'infra' -Target 'T2' -Status 'Manual action required' -Message 'waits' -Remediation 'Run ./scripts/deploy.ps1 again when you have about 15 minutes.')
        )
        Write-DemoResultReport -Result $results -Title 'deploy.ps1' -DeployCommand $script:own 6>$null
        $script:logged | Should -Contain ('DEPLOY.T2.HOST: Fix it, then run {0} -FromStage Artifacts.' -f $script:own)
        $script:logged | Should -Contain ('  DEPLOY.T2.GUIDEDSTOP: Run {0} again when you have about 15 minutes.' -f $script:own)
        $results[0].remediation | Should -Be 'Fix it, then run ./scripts/deploy.ps1 -FromStage Artifacts.'
    }

    It 'says after Ctrl+C that the rerun sends a bootstrap bundle or workload runner that changed meanwhile' {
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result @() -State $null -Config $Config -Stopped }
        $outcome.NextCommand | Should -Be './scripts/deploy.ps1'
        $outcome.Next | Should -Be 'Run ./scripts/deploy.ps1 again when you''re ready: it continues where it stopped, and when the bootstrap bundle or the workload runner changed meanwhile (a fix you pulled, for example), it sends them to the VMs again first.'
    }
}

Describe 'What only a person can confirm never keeps the run from DONE (Phase 28 live finding, 2026-10-30)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        # A deployed Insights app that only waits for its browser check, as the Fabric track reports it.
        $script:appRecords = @(InModuleScope DbHubDemo {
                foreach ($record in @(
                        (New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'The app is deployed.')
                        (New-DemoResult -CheckId 'FABRIC.APP.BROWSER' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'A person must confirm the app in the browser: sign-in and the connector in the app can''t be checked from a script.' -Remediation 'In the Fabric portal, open the app''s item in the workspace; it shows "Connector check passed".')
                    )) {
                    ConvertTo-DemoInsightsAppRecord -Record $record
                }
            })
    }

    It 'is DONE, exit code 0, when every requirement passed and the Hub setting couldn''t be read, listing it once under "Please confirm" as couldn''t check' {
        # Live: every DONE requirement passed, yet the run ended NOT DONE, exit 2, on FABRIC.P4.HUBSETTING's unread reminder,
        # which read as "the setting isn't enabled" (it was), followed by System.String[].
        $result = @(New-DoneResult) + @((New-HubSettingResult 'Forbidden' 'PREFLIGHT.P4.HUBSETTING'), (New-HubSettingResult 'Forbidden')) + @($script:appRecords)
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState -WithT4); Config = (New-TestConfig -InstallMode 'Developer') } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        $outcome.ExitCode | Should -Be 0
        @($outcome.Confirm).Count | Should -Be 2
        @($outcome.NonBlocking).Count | Should -Be 0 -Because 'the deployed app''s browser check is to confirm, not something that didn''t work'
        $lines = @(InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome })
        $text = $lines -join "`n"
        @($lines | Where-Object { $_ -like 'Please confirm*' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match 'Fabric tenant setting' }).Count | Should -Be 1 -Because 'the setting is one line, whichever check reported it'
        $lines | Should -Contain '- Couldn''t check the Fabric tenant setting "Users can access the Database hub (preview)" (needs a Fabric administrator; HTTP 403): please confirm it''s enabled.'
        $text | Should -Match '- The Insights app is deployed; confirm it once in the browser\.'
        $text | Should -Not -Match '(?i)optional'
        $text | Should -Not -Match 'is disabled|not enabled|System\.String\[\]'
        @($lines | Where-Object { $_ -match '^T2 runs SQL Server Developer edition' }).Count | Should -Be 1 -Because 'a note is its own line'
    }

    It 'is NOT DONE, with the true wording, only when the Hub setting was read and is disabled, and never asks to confirm a setting it read' {
        $disabled = @(New-DoneResult) + @((New-HubSettingResult 'Forbidden' 'PREFLIGHT.P4.HUBSETTING'), (New-HubSettingResult 'Disabled'))
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $disabled; State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.ExitCode | Should -Be 2
        $outcome.Reason | Should -Be 'FABRIC.P4.HUBSETTING: The Fabric tenant setting "Users can access the Database hub (preview)" is disabled (read through the Fabric admin API), so nobody in the tenant can open Database Hub.'
        $outcome.Next | Should -Match 'A Fabric administrator opens the Fabric admin portal'
        $outcome.Next | Should -Match ([regex]::Escape('Then run ./scripts/deploy.ps1 again.'))
        @($outcome.Confirm | Where-Object { $_['key'] -eq 'P4' }).Count | Should -Be 0 -Because 'a setting read as disabled is the reason, not a reminder'

        # Read and enabled: DONE with nothing to confirm, even beside the other check's unread reminder.
        $enabled = @(New-DoneResult) + @((New-HubSettingResult 'Forbidden' 'PREFLIGHT.P4.HUBSETTING'), (New-HubSettingResult 'Enabled'))
        $done = InModuleScope DbHubDemo -Parameters @{ Result = $enabled; State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $done.Kind | Should -Be 'Done'
        @($done.Confirm).Count | Should -Be 0
    }

    It 'judges the Hub setting by its latest read, so the Fabric track''s read supersedes preflight''s (Phase 28 review)' {
        # The reviewer's case: an administrator turned the setting on during the run. Preflight read it as disabled, and
        # the Fabric track, later in the same run, as enabled.
        $result = @(New-DoneResult) + @((New-HubSettingResult 'Disabled' 'PREFLIGHT.P4.HUBSETTING'), (New-HubSettingResult 'Enabled'))
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        $outcome.ExitCode | Should -Be 0
        @($outcome.Confirm).Count | Should -Be 0
        $summary = InModuleScope DbHubDemo -Parameters @{ Result = $result } { Get-DemoDeploySummary -Result $Result }
        @($summary.Evidence['manual']).Count | Should -Be 0
        $summary.Message | Should -Not -Match 'disabled'

        # The other way round, the later read decides too; and a later read that couldn't happen keeps an earlier "off".
        $turnedOff = @(New-DoneResult) + @((New-HubSettingResult 'Enabled' 'PREFLIGHT.P4.HUBSETTING'), (New-HubSettingResult 'Disabled'))
        $off = InModuleScope DbHubDemo -Parameters @{ Result = $turnedOff; State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $off.Kind | Should -Be 'NotDone'
        $off.Reason | Should -Match '^FABRIC\.P4\.HUBSETTING: .* is disabled'
        $unreadAfter = @(New-DoneResult) + @((New-HubSettingResult 'Disabled' 'PREFLIGHT.P4.HUBSETTING'), (New-HubSettingResult 'Forbidden'))
        $stillOff = InModuleScope DbHubDemo -Parameters @{ Result = $unreadAfter; State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $stillOff.Kind | Should -Be 'NotDone'
        $stillOff.Reason | Should -Match '^PREFLIGHT\.P4\.HUBSETTING: .* is disabled'
        @($stillOff.Confirm | Where-Object { $_['key'] -eq 'P4' }).Count | Should -Be 0
    }

    It 'reads the Hub setting once more before the run is judged, only when its latest read said disabled (Phase 28 review)' {
        $preflightOff = New-HubSettingResult 'Disabled' 'PREFLIGHT.P4.HUBSETTING'
        $fabricOn = New-HubSettingResult 'Enabled'
        $fabricOff = New-HubSettingResult 'Disabled'
        $requirement = @(InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'PaygWizard' })
        $script:reread = $fabricOn
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricHubSetting -MockWith { $script:reread }
        $result = @(New-DoneResult) + @($preflightOff)
        $gate = @(InModuleScope DbHubDemo -Parameters @{ Result = $result; Config = (New-TestConfig); Requirement = $requirement } { Invoke-DemoDoneGate -Config $Config -Result $Result -Requirement $Requirement })
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricHubSetting -Times 1 -Exactly -ParameterFilter { $CheckId -eq 'FABRIC.P4.HUBSETTING' }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = (@($result) + @($gate)); State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done' -Because 'the setting was turned on during the run'

        # Still off: NOT DONE with the true wording, after one more read.
        $script:reread = $fabricOff
        $gate = @(InModuleScope DbHubDemo -Parameters @{ Result = $result; Config = (New-TestConfig); Requirement = $requirement } { Invoke-DemoDoneGate -Config $Config -Result $Result -Requirement $Requirement })
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricHubSetting -Times 2 -Exactly
        $notDone = InModuleScope DbHubDemo -Parameters @{ Result = (@($result) + @($gate)); State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $notDone.Kind | Should -Be 'NotDone'
        $notDone.Reason | Should -Match '^FABRIC\.P4\.HUBSETTING: .* is disabled \(read through the Fabric admin API\)'

        # Read as on, or never read: no extra read.
        foreach ($latest in $fabricOn, (New-TestResult 'TEST.NOTHING')) {
            $null = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult) + @($latest)); Config = (New-TestConfig); Requirement = $requirement } { Invoke-DemoDoneGate -Config $Config -Result $Result -Requirement $Requirement }
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricHubSetting -Times 2 -Exactly
    }

    It 'is NOT DONE, exit code 1, for a failed requirement, and names only that, not what''s left to confirm' {
        $result = @(New-DoneResult | Where-Object { $_.checkId -ne 'TELEMETRY.T1' }) + @((New-TestResult 'TELEMETRY.T1' 'Fail'), (New-HubSettingResult 'Forbidden'))
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.ExitCode | Should -Be 1
        $outcome.Reason | Should -Match '^TELEMETRY\.T1: '
        $outcome.Reason | Should -Not -Match 'tenant setting'
    }

    It 'treats a capacity SKU to confirm and the presenters'' roles as confirm-only, and a paused capacity as a blocker' {
        $capacity = New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The Fabric workspace "Database Hub Demo" is on the capacity "trial01" with SKU FT1, which this check can''t confirm runs notebooks.' -Evidence ([ordered]@{ sku = 'FT1'; state = 'Active' }) -Remediation 'Confirm that "trial01" is a Fabric Trial or F capacity.'
        $presenter = New-DemoResult -CheckId 'HUB.PRESENTER.READER' -Area 'hub' -Target 'subscription' -Status 'Manual action required' -Message 'assignRoles is false, so Reader on the subscription must be granted by an administrator to 1 presenter(s).' -Remediation 'An administrator runs: az role assignment create (the command is in this result).'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult) + @($capacity, $presenter)); State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        $texts = @($outcome.Confirm | ForEach-Object { [string]$_['text'] })
        $texts | Should -Contain 'Confirm that "trial01" is a Fabric Trial or F capacity.'
        ($texts -join ' ') | Should -Match 'must be granted by an administrator to 1 presenter\(s\)\. The commands are in its result \(HUB\.PRESENTER\.READER\)\.'

        $paused = New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The capacity "f2cap" (F2) of the Fabric workspace "Database Hub Demo" is Paused, so notebooks can''t run.' -Evidence ([ordered]@{ sku = 'F2'; state = 'Paused' }) -Remediation 'A capacity administrator resumes the capacity in the Azure portal or the Fabric admin portal.'
        $blocked = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult) + @($paused)); State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $blocked.Kind | Should -Be 'NotDone'
        $blocked.Reason | Should -Match '^FABRIC\.P5\.CAPACITY: '
        $blocked.Next | Should -Match 'A capacity administrator resumes the capacity'
    }

    It 'names a requirement''s own fix when a rerun alone can''t change it, and the wait when telemetry only lags' {
        $resourceId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.HybridCompute/machines/arcsql01'
        $lookalike = New-DemoResult -CheckId 'TELEMETRY.T2' -Area 'hub' -Target 'T2' -Status 'Warning' -Message 'Telemetry for T2 (arcsql01) arrives under another ResourceID, not the expected one.' -Evidence ([ordered]@{ resourceId = $resourceId; telemetryResourceId = '/subscriptions/x' }) -Remediation 'Record the ResourceID format in docs/implementation-report.md and update Resolve-DemoHubTarget to match it.'
        $result = @(New-DoneResult | Where-Object { $_.checkId -ne 'TELEMETRY.T2' }) + @($lookalike)
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.Next | Should -Match '^Record the ResourceID format'
        $outcome.Next | Should -Match ([regex]::Escape('Then run ./scripts/deploy.ps1.'))

        $stale = New-DemoResult -CheckId 'TELEMETRY.T2' -Area 'hub' -Target 'T2' -Status 'Warning' -Message 'T2 (arcsql01) has telemetry, but the newest sample is 40 minutes old.' -Evidence ([ordered]@{ resourceId = $resourceId; rows = 12; lagMinutes = 40 }) -Remediation 'Start the target (start-demo.ps1) and run again with -WaitMinutes 15.'
        $lagging = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult | Where-Object { $_.checkId -ne 'TELEMETRY.T2' }) + @($stale)); State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $lagging.Next | Should -Match 'Wait about 10 minutes'
    }

    It 'summarizes the run without System.String[], with what needs you apart from what to confirm, each once (DEPLOY.SUMMARY)' {
        $array = [pscustomobject]@{ checkId = 'DEPLOY.T2.GUIDEDSTOP'; status = 'Manual action required'; message = [string[]]@('Nobody finished', 'SQL Server setup.'); remediation = [string[]]@('Run ./scripts/deploy.ps1 again', 'when you have about 15 minutes.') }
        $confirmItems = @((New-HubSettingResult 'Forbidden' 'PREFLIGHT.P4.HUBSETTING'), (New-HubSettingResult 'Forbidden')) + @($script:appRecords)
        $summary = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult) + @($array) + $confirmItems) } { Get-DemoDeploySummary -Result $Result -FinishedText 'Every track and the validation finished.' }
        $summary.Status | Should -Be 'Manual action required'
        $summary.Message | Should -Match '^1 item\(s\) need you: DEPLOY\.T2\.GUIDEDSTOP: Run \./scripts/deploy\.ps1 again when you have about 15 minutes\.'
        $summary.Message | Should -Not -Match 'System\.String\[\]'
        ([regex]::Matches($summary.Message, 'Fabric tenant setting')).Count | Should -Be 1
        @($summary.Evidence['confirm']).Count | Should -Be 2

        $confirmOnly = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult) + $confirmItems) } { Get-DemoDeploySummary -Result $Result -FinishedText 'Every track and the validation finished.' }
        $confirmOnly.Message | Should -Match '^Every track and the validation finished\. Nothing else needs you for DONE\. Please confirm \(none of these keeps the run from DONE\): Couldn''t check the Fabric tenant setting'
        @($confirmOnly.Evidence['manual']).Count | Should -Be 0
    }
}

Describe 'The Insights app is part of every deployment, and nothing about it keeps the run from DONE (2026-11-05)' {
    BeforeAll {
        # The app's records as the Fabric track reports them (ConvertTo-DemoInsightsAppRecord), for each way it can fail.
        function New-AppRecord([string] $CheckId, [string] $Status, [string] $Message, [string] $Remediation = '', [System.Collections.IDictionary] $Evidence = @{}) {
            InModuleScope DbHubDemo -Parameters @{ CheckId = $CheckId; Status = $Status; Message = $Message; Remediation = $Remediation; Evidence = $Evidence } {
                ConvertTo-DemoInsightsAppRecord -Record (New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Remediation $Remediation -Evidence $Evidence)
            }
        }
        $script:appFailures = [ordered]@{
            exception = @(InModuleScope DbHubDemo { ConvertTo-DemoInsightsAppErrorRecord -Exception ([System.InvalidOperationException]::new('The stage folder is locked by another process.')) })
            timeout   = @(New-AppRecord 'FABRIC.APP.DEPLOY' 'Fail' 'rayfin up didn''t deploy APP_DatabaseHub_Insights (exit code -1, 1200 s): node did not finish within 1200 seconds and was stopped.' 'Fix the reported problem and run the script again; nothing is deleted, and a re-run reuses the item.')
            network   = @(New-AppRecord 'DEPLOY.FABRIC.APP' 'Fail' 'configure-fabric-app.ps1 stopped: A network error reached api.fabric.microsoft.com on each of 4 attempts: The SSL connection could not be established.' 'Run ./scripts/deploy.ps1 again: it resumes where it stopped. A network error stopped it (requests that are safe to repeat were retried).' ([ordered]@{ networkError = $true }))
            signIn    = @(
                (New-AppRecord 'FABRIC.APP.SIGNIN' 'Manual action required' 'The Rayfin CLI isn''t signed in, so the app can''t be deployed unattended.' 'Sign in once as the demo''s Fabric user, from any folder.')
                (New-AppRecord 'FABRIC.APP.DEPLOY' 'Not selected' 'Not deployed: FABRIC.APP.SIGNIN needs attention first.')
            )
        }
        $script:appReasons = @{
            exception = 'The stage folder is locked by another process'
            timeout   = 'did not finish within 1200 seconds'
            network   = 'A network error reached api\.fabric\.microsoft\.com'
            signIn    = 'FABRIC\.APP\.SIGNIN: The Rayfin CLI isn''t signed in'
        }
        # What the run's own sign-in left: skipped in a session that can't answer it, or a sign-in that didn't finish.
        $script:signInRecords = @(
            (New-DemoResult -CheckId 'DEPLOY.FABRIC.APPSIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Not supported' -Message 'This session can''t answer a browser sign-in.')
            (New-DemoResult -CheckId 'DEPLOY.FABRIC.APPSIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Warning' -Message 'Nobody finished the Rayfin CLI''s sign-in within 15 minutes, so it was stopped.')
        )
    }

    It 'is DONE, exit code 0, after <_> in the app''s step, with the app named as failed with its real error' -ForEach @('exception', 'timeout', 'network', 'signIn') {
        $kind = $_
        $records = @(New-DoneResult -WithT4) + @($script:signInRecords) + @($script:appFailures[$kind])
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $records; State = (New-FinishedState -WithT4); Config = (New-TestConfig -WithT4) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done' -Because $kind
        $outcome.ExitCode | Should -Be 0
        $outcome.NextCommand | Should -BeNullOrEmpty -Because 'DONE asks for no rerun, whatever the app''s records say'
        @($outcome.NonBlocking).Count | Should -Be 1
        $outcome.NonBlocking[0]['name'] | Should -Be 'the Insights app'
        $outcome.NonBlocking[0]['state'] | Should -Be 'Failed'
        $outcome.NonBlocking[0]['message'] | Should -Match $script:appReasons[$kind]
        $outcome.NonBlocking[0]['howTo'] | Should -Not -Match 'deploy\.ps1' -Because 'the fix is the app''s own command, never a rerun of the whole deployment'
        $outcome.NonBlocking[0]['howTo'] | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
        $text = (InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) -join "`n"
        $text | Should -Match '##  DONE'
        $text | Should -Match ('Failed \(doesn''t block DONE\): the Insights app\. It wasn''t created: .*' + $script:appReasons[$kind])
        # DEPLOY.SUMMARY and the exit code in GitHub Actions never see a Fail from the app.
        @($records | Where-Object { $_.status -eq 'Fail' }).Count | Should -Be 0
        (Get-DemoExitCode -Result $records) | Should -Be 0
        $summary = InModuleScope DbHubDemo -Parameters @{ Result = $records } { Get-DemoDeploySummary -Result $Result -FinishedText 'Every track and the validation finished.' }
        $summary.Status | Should -Not -Be 'Fail'
        $summary.Message | Should -Match 'Nothing else needs you for DONE\.'
        $summary.Message | Should -Match ([regex]::Escape('Doesn''t block DONE: the Insights app (failed).'))
        @($summary.Evidence['manual']).Count | Should -Be 0
    }

    It 'names only what blocks DONE when something else failed too, never the app''s network error or its rerun' {
        $records = @(New-DoneResult) + @(New-TestResult 'DEPLOY.EXTENSIONS_SQLVM01' 'Fail') + @($script:appFailures['network'])
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $records; State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.ExitCode | Should -Be 1
        $outcome.Reason | Should -Match '^DEPLOY\.EXTENSIONS_SQLVM01'
        $outcome.Next | Should -Not -Match 'network error'
        $text = (InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) -join "`n"
        $text | Should -Match 'Failed \(doesn''t block DONE\): the Insights app\.'

        # The app's network error alone: DONE, and no rerun.
        $alone = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult) + @($script:appFailures['network'])); State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $alone.Kind | Should -Be 'Done'
    }
}

Describe 'A target''s missing telemetry gets its monitoring checked once more before the run is judged (Phase 28 live finding, 2026-10-30)' {
    BeforeAll {
        $script:t1Id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/sqlvm01'
        # TELEMETRY.<target> shaped as Test-DemoHubTelemetry returns it.
        function New-TelemetryResult([string] $Target, [string] $Status, [System.Collections.IDictionary] $Evidence = [ordered]@{ resourceId = $script:t1Id; rows = 0 }) {
            New-DemoResult -CheckId ('TELEMETRY.{0}' -f $Target) -Area 'hub' -Target $Target -Status $Status -Message ('TELEMETRY.{0} {1}' -f $Target, $Status) -Evidence $Evidence
        }
    }

    BeforeEach {
        $script:asked = [System.Collections.Generic.List[string]]::new()
        $script:polls = 0
        # The first poll finds no rows for the targets in $script:missing; every later poll finds them.
        $script:missing = @('T1')
        $script:recheckMisses = $false
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith {
            $script:polls++
            $script:asked.Add(('telemetry {0} wait={1}' -f ($Target -join ','), $WaitMinutes))
            foreach ($name in 'T1', 'T2', 'T3') {
                if ($name -notin $Target) {
                    New-DemoResult -CheckId ('TELEMETRY.{0}' -f $name) -Area 'hub' -Target $name -Status 'Not selected' -Message 'Not selected.'
                }
                elseif ($name -in $script:missing -and ($script:polls -eq 1 -or $script:recheckMisses)) {
                    New-DemoResult -CheckId ('TELEMETRY.{0}' -f $name) -Area 'hub' -Target $name -Status 'Fail' -Message ('No performance telemetry from {0} in the last 60 minutes.' -f $name) -Evidence ([ordered]@{ resourceId = ('/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/x/{0}' -f $name); rows = 0 })
                }
                else {
                    New-DemoResult -CheckId ('TELEMETRY.{0}' -f $name) -Area 'hub' -Target $name -Status 'Pass' -Message ('{0} sends performance telemetry.' -f $name)
                }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith {
            $script:asked.Add(('restore {0} {1}' -f $CheckId, $Occasion))
            New-DemoResult -CheckId 'DEPLOY.T1.MONITORING' -Area 't1' -Target 'T1' -Status 'Pass' -Message 'sqlvm01''s monitoring plugin wasn''t running after the deployment; the SQL IaaS Agent service was restarted, and it''s Running with uploads OK after 161 seconds.' -Evidence ([ordered]@{ restarted = $true })
        }
    }

    It 'tells which targets lack their data, and leaves access errors, unknown resource IDs, and telemetry under another ID alone' {
        $results = @(
            (New-TelemetryResult 'T1' 'Fail')
            (New-TelemetryResult 'T2' 'Fail' ([ordered]@{ resourceId = '/x'; rows = 0; errorKind = 'Forbidden'; statusCode = 403 }))
            (New-TelemetryResult 'T3' 'Warning' ([ordered]@{ resourceId = '/y'; telemetryResourceId = '/z' }))
        )
        @(InModuleScope DbHubDemo -Parameters @{ Result = $results } { Get-DemoTelemetryRetryTarget -Result $Result }) | Should -Be @('T1')
        $more = @(
            (New-TelemetryResult 'T1' 'Fail' ([ordered]@{}))
            (New-TelemetryResult 'T2' 'Warning' ([ordered]@{ resourceId = '/x'; rows = 4; lagMinutes = 40 }))
            (New-TelemetryResult 'T3' 'Pass' ([ordered]@{ resourceId = '/y'; rows = 9 }))
        )
        @(InModuleScope DbHubDemo -Parameters @{ Result = $more } { Get-DemoTelemetryRetryTarget -Result $Result }) | Should -Be @('T2') -Because 'stale data is what a stopped agent leaves too; an unknown resource ID isn''t'
    }

    It 'restarts T1''s stopped plugin once, says so on the status page, waits, and replaces the miss with the new check' {
        # Live: T1's plugin was NotRunning hours after start-demo.ps1 found it running; the restart brought it back in 161 s.
        $progress = Join-Path -Path $TestDrive -ChildPath ('progress-' + [guid]::NewGuid().ToString('N') + '.json')
        InModuleScope DbHubDemo -Parameters @{ Path = $progress } { Initialize-DemoProgress -Path $Path -Model (New-DemoProgressModel -Catalog (Get-DemoProgressCatalog)) -Confirm:$false }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Path = $progress } { Invoke-DemoTelemetryCheck -Config $Config -Target 'T1', 'T3' -WaitMinutes 15 -ProgressPath $Path -ProgressStepId 'Validation' })
        $script:asked | Should -Be @('telemetry T1,T3 wait=15', 'restore DEPLOY.T1.MONITORING the deployment', 'telemetry T1 wait=15')
        @($results | Where-Object { $_.checkId -eq 'TELEMETRY.T1' }).status | Should -Be @('Pass') -Because 'the new check replaces the miss'
        @($results | Where-Object { $_.checkId -eq 'TELEMETRY.T3' }).status | Should -Be @('Pass')
        @($results | Where-Object { $_.checkId -eq 'DEPLOY.T1.MONITORING' }).status | Should -Be @('Pass')
        @($results | Where-Object { $_.status -eq 'Fail' }) | Should -BeNullOrEmpty
        $model = Get-Content -LiteralPath $progress -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $steps = @{}
        foreach ($track in @($model['tracks'])) { foreach ($item in @($track['steps'])) { $steps[[string]$item['id']] = $item } }
        $steps['T1.Monitoring']['state'] | Should -Be 'Done'
        $steps['T1.Monitoring']['message'] | Should -Match 'the SQL IaaS Agent service was restarted'
        $steps['Validation']['message'] | Should -Be 'Waiting up to 15 minutes for telemetry from T1 in Database Hub, after checking its monitoring: no action needed.'
        $steps['Validation']['azureSide'] | Should -BeTrue
    }

    It 'tries once: a second miss is the result, with no further restart' {
        $script:recheckMisses = $true
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoTelemetryCheck -Config $Config -Target 'T1' -WaitMinutes 5 })
        @($script:asked | Where-Object { $_ -like 'restore*' }).Count | Should -Be 1
        @($script:asked | Where-Object { $_ -like 'telemetry*' }).Count | Should -Be 2
        @($results | Where-Object { $_.checkId -eq 'TELEMETRY.T1' }).status | Should -Be @('Fail')
    }

    It 'doesn''t wait for a target whose monitoring is off, and waits for T2 and T3 once theirs is on' {
        $script:missing = @('T1', 'T2', 'T3')
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith { $script:asked.Add('restore'); New-DemoResult -CheckId 'DEPLOY.T1.MONITORING' -Area 't1' -Target 'T1' -Status 'Not selected' -Message 'Performance monitoring isn''t turned on for sqlvm01.' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcCheck -MockWith { $script:asked.Add('arc ' + ($Check -join ',')); New-DemoResult -CheckId 'T2.ARC.CONNECTED' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'Connected.'; New-DemoResult -CheckId 'T2.ARC.MONITORING' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'Monitoring is on.' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3WarmUp -MockWith { $script:asked.Add('warm T3'); New-DemoResult -CheckId 'T3.WARMUP' -Area 't3' -Target 'T3' -Status 'Pass' -Message 'T3 is online.'; New-DemoResult -CheckId 'T3.PROPERTY' -Area 't3' -Target 'T3' -Status 'Pass' -Message 'The property is true.' }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoTelemetryCheck -Config $Config -Target 'T1', 'T2', 'T3' -WaitMinutes 15 })
        $script:asked | Should -Be @('telemetry T1,T2,T3 wait=15', 'restore', 'arc Connected,Monitoring', 'warm T3', 'telemetry T2,T3 wait=15')
        @($results | Where-Object { $_.checkId -eq 'TELEMETRY.T1' }).status | Should -Be @('Fail') -Because 'T1''s monitoring is off, so its miss stands'
        @($results | Where-Object { $_.checkId -eq 'TELEMETRY.T2' }).status | Should -Be @('Pass')
        @($results | Where-Object { $_.checkId -eq 'TELEMETRY.T3' }).status | Should -Be @('Pass')

        # Arc monitoring off: T2 isn't waited for, and the reason is in its own result.
        $script:asked.Clear()
        $script:polls = 0
        $script:missing = @('T2')
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcCheck -MockWith { $script:asked.Add('arc'); New-DemoResult -CheckId 'T2.ARC.MONITORING' -Area 't2' -Target 'T2' -Status 'Fail' -Message 'Monitoring is off.' }
        $off = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoTelemetryCheck -Config $Config -Target 'T2' -WaitMinutes 15 })
        $script:asked | Should -Be @('telemetry T2 wait=15', 'arc')
        @($off | Where-Object { $_.checkId -eq 'T2.ARC.MONITORING' }).status | Should -Be @('Fail')
    }

    It 'checks once, without the recovery, for an access error or with -NoRecovery' {
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith {
            $script:asked.Add('telemetry')
            New-DemoResult -CheckId 'TELEMETRY.T1' -Area 'hub' -Target 'T1' -Status 'Fail' -Message 'The telemetry endpoint denied access.' -Evidence ([ordered]@{ resourceId = '/x'; rows = 0; errorKind = 'Forbidden'; statusCode = 403 })
        }
        $null = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoTelemetryCheck -Config $Config -Target 'T1' -WaitMinutes 15 }
        $script:asked | Should -Be @('telemetry')
        $script:asked.Clear()
        $script:missing = @('T1')
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith { $script:asked.Add('telemetry'); New-DemoResult -CheckId 'TELEMETRY.T1' -Area 'hub' -Target 'T1' -Status 'Fail' -Message 'No rows.' -Evidence ([ordered]@{ resourceId = '/x'; rows = 0 }) }
        $null = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoTelemetryCheck -Config $Config -Target 'T1' -WaitMinutes 15 -NoRecovery }
        $script:asked | Should -Be @('telemetry')
    }

    It 'runs in DONE''s checks last, and only when everything else DONE needs passed' {
        $config = New-TestConfig
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubEstate -MockWith { $script:asked.Add('estate ' + ($Target -join ',')); foreach ($t in $Target) { New-TestResult ('HUB.ESTATE.{0}' -f $t) $script:estateStatus } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmAssociatedService -MockWith { New-TestResult 'T1.SQLVM.ASSOCIATEDSERVICES' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricRequiredItem -MockWith { New-TestResult 'FABRIC.ITEMS.REQUIRED' }
        $requirement = InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'PaygWizard' }
        $seen = @(New-DoneResult | Where-Object { $_.checkId -notin 'TELEMETRY.T1', 'HUB.ESTATE.T1' })
        $script:estateStatus = 'Pass'
        $new = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Seen = $seen; Requirement = $requirement } { Invoke-DemoDoneGate -Config $Config -Result $Seen -Requirement $Requirement -TelemetryWaitMinutes 15 })
        $script:asked | Should -Be @('estate T1', 'telemetry T1 wait=15', 'restore DEPLOY.T1.MONITORING the deployment', 'telemetry T1 wait=15')
        @($new | Where-Object { $_.checkId -eq 'TELEMETRY.T1' }).status | Should -Be @('Pass')
        (InModuleScope DbHubDemo -Parameters @{ All = @($seen + $new); Requirement = $requirement } { Test-DemoDoneEvidence -Result $All -Requirement $Requirement }).Complete | Should -BeTrue

        # T1's estate entry is missing too: the run isn't DONE whatever T1's telemetry shows, so nothing waits again.
        $script:asked.Clear()
        $script:polls = 0
        $script:estateStatus = 'Warning'
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config; Seen = $seen; Requirement = $requirement } { Invoke-DemoDoneGate -Config $Config -Result $Seen -Requirement $Requirement -TelemetryWaitMinutes 15 }
        $script:asked | Should -Be @('estate T1', 'telemetry T1 wait=15')
    }
}

Describe 'The history model''s blank measures right after a first deployment (Phase 28 live finding, 2026-10-30)' {
    It 'collapses the blank-measure Warnings into one while no history is written, and keeps every other record' {
        # Live: a new workspace gave about 40 FABRIC.SEMANTICMODEL.MEASURE.* Warnings before the notebook saved anything.
        $records = [System.Collections.Generic.List[object]]::new()
        $records.Add((New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.ROWS' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message '5 Direct Lake tables answer: telemetry_snapshots 0.'))
        foreach ($index in 1..40) {
            $records.Add((New-DemoResult -CheckId ('FABRIC.SEMANTICMODEL.MEASURE.TELEMETRY_SNAPSHOTS.M{0}' -f $index) -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'Blank.'))
        }
        $records.Add((New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.MEASURE.VALIDATION_RESULTS.COUNT' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Returned 3.'))
        $records.Add((New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.MEASURE.SIGNAL.BROKEN' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'A DAX error.'))
        $records.Add((New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.DATA' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'Summary.'))
        $merged = @(InModuleScope DbHubDemo -Parameters @{ Records = $records.ToArray() } { Merge-DemoBlankMeasureResult -Result $Records })
        @($merged | Where-Object { [string]$_.checkId -like 'FABRIC.SEMANTICMODEL.MEASURE.*' -and $_.status -eq 'Warning' }) | Should -BeNullOrEmpty
        $one = @($merged | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.MEASURES' })
        $one.Count | Should -Be 1
        $one[0].status | Should -Be 'Warning'
        $one[0].message | Should -Be 'The history report is empty until NB_DatabaseHub_LiveActivity saves its first snapshots; that''s expected right after a first deployment (40 measures are blank for now).'
        @($one[0].evidence.blankMeasures).Count | Should -Be 40
        $merged.checkId | Should -Contain 'FABRIC.SEMANTICMODEL.MEASURE.VALIDATION_RESULTS.COUNT'
        $merged.checkId | Should -Contain 'FABRIC.SEMANTICMODEL.MEASURE.SIGNAL.BROKEN'
        $merged.Count | Should -Be 5

        # With history written, every record stays as it is.
        $records[0] = New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.ROWS' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Rows.'
        @(InModuleScope DbHubDemo -Parameters @{ Records = $records.ToArray() } { Merge-DemoBlankMeasureResult -Result $Records }).Count | Should -Be 44
    }

    It 'applies to the deployment''s Power BI step' {
        $script:records = @(
            (New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.ROWS' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'No history yet.')
            (New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.MEASURE.A.B' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'Blank.')
            (New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.MEASURE.A.C' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'Blank.')
        )
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricScriptStep -MockWith { $script:records }
        $result = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoPowerBIStage -Config $Config })
        $result.checkId | Should -Be @('FABRIC.SEMANTICMODEL.ROWS', 'FABRIC.SEMANTICMODEL.MEASURES')
    }
}

Describe 'The Preflight step''s message in plain words (Phase 28 live run, 2026-10-30)' {
    It 'says whether T3 uses the free offer, and where T2 comes from, in words rather than raw values, on both deployment paths' {
        # Live: "Preflight passed (network mode private, T3 free offer False, T2 source existing-build)."
        InModuleScope DbHubDemo {
            Get-DemoPreflightPassText -NetworkMode 'private' -T3UseFreeLimit $false -T2Source 'existing-build' | Should -Be 'Preflight passed (network mode: private; T3 free offer: not used; T2 source: the existing host, built from the image).'
            Get-DemoPreflightPassText -NetworkMode 'public' -T3UseFreeLimit $true -T2Source 'golden' | Should -Be 'Preflight passed (network mode: public; T3 free offer: used; T2 source: a copy of the golden snapshot).'
            Get-DemoPreflightPassText -NetworkMode 'private' -T3UseFreeLimit $false -T2Source 'build' | Should -Be 'Preflight passed (network mode: private; T3 free offer: not used; T2 source: a new build from the image).'
            Get-DemoPreflightPassText -NetworkMode 'private' -T3UseFreeLimit $true | Should -Be 'Preflight passed (network mode: private; T3 free offer: used).'
        }
        foreach ($file in 'Private/ParallelDeployment.ps1', 'Public/Invoke-DemoDeployment.ps1') {
            $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath ('scripts/modules/DbHubDemo/{0}' -f $file)) -Raw
            $text | Should -Match ([regex]::Escape("& `$stageResult 'Preflight' 'Pass' (Get-DemoPreflightPassText -NetworkMode ([string]`$context.NetworkMode) -T3UseFreeLimit ([bool]`$context.T3UseFreeLimit)")) -Because $file
            $text | Should -Not -Match 'T3 free offer \{1\}' -Because $file
        }
    }
}

Describe 'Start-DemoDeploymentRun and Complete-DemoDeploymentRun (brief goals 4 and 7, item 11)' {
    BeforeEach {
        $script:out = Join-Path -Path $TestDrive -ChildPath ('out-' + [guid]::NewGuid().ToString('N'))
        Mock -ModuleName DbHubDemo -CommandName Write-Host -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Enter-DemoKeepAwake -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoProgressPageWriter -MockWith { $null }
        Mock -ModuleName DbHubDemo -CommandName Open-DemoProgressPage -MockWith { 'The status page is open in your browser.' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRunEnvironment -MockWith { [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $true; Codespaces = $false; Windows = $true } }
    }

    It 'keeps the PC awake, writes the model and the page, opens the page, and prints the expectations' {
        $run = Start-DemoDeploymentRun -Config (New-TestConfig) -WaitForT2 -OutputDirectory $script:out -Confirm:$false
        Should -Invoke -ModuleName DbHubDemo -CommandName Enter-DemoKeepAwake -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoProgressPageWriter -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Open-DemoProgressPage -Times 1 -Exactly -ParameterFilter { -not $NoBrowser }
        $run.KeepAwake | Should -BeTrue
        Test-Path -LiteralPath $run.ProgressPath | Should -BeTrue
        Get-Content -LiteralPath $run.PagePath -Raw | Should -Match 'Deploying, no action needed'
        $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $model.Contains('guidedStop') | Should -BeFalse -Because 'the guided stop is retired (2026-11-09)'
        $model['expect'].Contains('humanText') | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-Host -ParameterFilter { [string]$Object -match 'stays awake' }
    }

    It 'writes no page in GitHub Actions, and records DONE or NOT DONE in the model at the end' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRunEnvironment -MockWith { [pscustomobject]@{ GitHubActions = $true; Ci = $true; Interactive = $false; Codespaces = $false; Windows = $false } }
        $ci = Start-DemoDeploymentRun -Config (New-TestConfig) -OutputDirectory $script:out -Confirm:$false
        $ci.ProgressPath | Should -BeNullOrEmpty

        Mock -ModuleName DbHubDemo -CommandName Get-DemoRunEnvironment -MockWith { [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $true; Codespaces = $false; Windows = $true } }
        $config = New-TestConfig
        $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
        $result = @(New-TestResult 'DEPLOY.TEMPLATE')
        $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result $result -State ([pscustomobject]@{ Stage = 'Infrastructure'; TrackT1 = 'Bootstraps'; TrackT2 = ''; TrackT4 = ''; TrackFabric = ''; T4Sku = '' })
        $outcome.Kind | Should -Be 'NotDone'
        $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $model['run']['state'] | Should -Be 'NotDone'
        $model['run']['nextCommand'] | Should -Be './scripts/deploy.ps1'
        Get-Content -LiteralPath $run.PagePath -Raw | Should -Match 'Stopped, not done'
    }

    It 'ends DONE on the status page with what to confirm, saying it couldn''t check the setting, never "not enabled" (Phase 28 live finding)' {
        # Live: the page said the run stopped because the Hub setting wasn't enabled; it was on, and the check never read it.
        $config = New-TestConfig -WithT4
        $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
        $result = @(New-DoneResult) + @((New-HubSettingResult 'Forbidden' 'PREFLIGHT.P4.HUBSETTING'), (New-HubSettingResult 'Forbidden'))
        $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result $result -State (New-FinishedState -WithT4)
        $outcome.Kind | Should -Be 'Done'
        $outcome.ExitCode | Should -Be 0
        $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $model['run']['state'] | Should -Be 'Done'
        $model['run']['reason'] | Should -Match 'T1, T2, T3, and T4 in Estate'
        $model['run']['reason'] | Should -Not -Match 'System\.String\[\]|tenant setting'
        @($model['confirm']).Count | Should -Be 1
        $model['confirm'][0] | Should -Be 'Couldn''t check the Fabric tenant setting "Users can access the Database hub (preview)" (needs a Fabric administrator; HTTP 403): please confirm it''s enabled.'
        $page = Get-Content -LiteralPath $run.PagePath -Raw
        $page | Should -Match '<h1>Done</h1>'
        $page | Should -Match 'Please confirm \(a rerun can&#39;t check these, and none of them keeps the demo from being done\):'
        $page | Should -Match 'Couldn&#39;t check the Fabric tenant setting &quot;Users can access the Database hub \(preview\)&quot; \(needs a Fabric administrator; HTTP 403\): please confirm it&#39;s enabled\.'
        $page | Should -Not -Match 'not enabled|is disabled|System\.String\[\]'
        $console = (InModuleScope DbHubDemo -Parameters @{ Path = $run.ProgressPath } { Format-DemoProgressConsole -Model (Read-DemoProgress -Path $Path) -Width 400 }) -join "`n"
        $console | Should -Match 'Please confirm'
        $console | Should -Match 'Couldn''t check the Fabric tenant setting'
    }

    It 'never writes System.String[] into a NOT DONE reason that has notes, and prints each note on its own line (Phase 28 live finding)' {
        # Live: "TELEMETRY.T1: No performance telemetry from T1 (sqlvm01) in the last 60 minutes. System.String[]".
        $config = New-TestConfig -WithT4
        $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
        $telemetry = New-DemoResult -CheckId 'TELEMETRY.T1' -Area 'hub' -Target 'T1' -Status 'Fail' -Message 'No performance telemetry from T1 (sqlvm01) in the last 60 minutes.'
        $result = @(New-DoneResult | Where-Object { $_.checkId -ne 'TELEMETRY.T1' }) + @($telemetry)
        $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result $result -State (New-FinishedState -WithT4 -T4Sku 'None')
        $outcome.Kind | Should -Be 'NotDone'
        $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $model['run']['reason'] | Should -Match '^TELEMETRY\.T1: No performance telemetry from T1 \(sqlvm01\) in the last 60 minutes\.'
        $model['run']['reason'] | Should -Not -Match 'System\.String\[\]'
        Get-Content -LiteralPath $run.PagePath -Raw | Should -Not -Match 'System\.String\[\]'

        # Two notes, two lines: T4 not deployed in this run (DONE needs it), and Developer mode.
        $developer = New-TestConfig -InstallMode 'Developer' -WithoutT4
        $two = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult -InstallMode 'Developer'); State = (New-FinishedState); Config = $developer } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        @($two.Notes).Count | Should -Be 2
        $lines = @(InModuleScope DbHubDemo -Parameters @{ Outcome = $two } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome })
        $lines | Should -Contain ([string]$two.Notes[0])
        $lines | Should -Contain ([string]$two.Notes[1])
    }

    It 'ends a stopped run at Stopped, not done, with the command to continue, without an Azure call, and moves its running steps back to Pending (Phase 28 live finding)' {
        $config = New-TestConfig
        $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
        InModuleScope DbHubDemo { $script:DemoRunCancelWatch } | Should -BeTrue -Because 'the run records Ctrl+C from its start'
        InModuleScope DbHubDemo -Parameters @{ Path = $run.ProgressPath } {
            Set-DemoProgressStep -Path $Path -Id 'Preflight' -State 'Done' -Status 'Pass' -Message 'Passed.'
            Set-DemoProgressStep -Path $Path -Id 'T1.Bootstraps' -State 'Running' -Message 'The loader runs.'
            Set-DemoProgressStep -Path $Path -Id 'T2.HostBuild' -State 'Action needed' -Message 'The build didn''t finish within the wait.'
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { throw 'a stopped run makes no Azure call' }
        $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result @() -Stopped
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -Times 0 -Exactly
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.ExitCode | Should -Be 2
        $outcome.Reason | Should -Match 'Ctrl\+C'
        $outcome.NextCommand | Should -Be './scripts/deploy.ps1'
        $outcome.Next | Should -Not -Match '(?i)guided stop' -Because 'no run stops at a guided stop any more (2026-11-09)'
        $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $model['run']['state'] | Should -Be 'NotDone'
        $model['run']['nextCommand'] | Should -Be './scripts/deploy.ps1'
        $steps = @{}
        foreach ($track in @($model['tracks'])) { foreach ($item in @($track['steps'])) { $steps[[string]$item['id']] = $item } }
        $steps['Preflight']['state'] | Should -Be 'Done'
        $steps['T1.Bootstraps']['state'] | Should -Be 'Pending'
        $steps['T1.Bootstraps']['message'] | Should -Match 'Stopped here \(Ctrl\+C\)'
        $steps['T2.HostBuild']['state'] | Should -Be 'Pending'
        $page = Get-Content -LiteralPath $run.PagePath -Raw
        $page | Should -Match 'Stopped, not done'
        $page | Should -Match ([regex]::Escape('Run: ./scripts/deploy.ps1'))
        InModuleScope DbHubDemo { $script:DemoRunCancelWatch } | Should -BeFalse -Because 'a later command in the same session never reads this run''s Ctrl+C as its own'
    }

    It 'names, in one line, what this run started or created and how it stops, when the run isn''t DONE, even after Ctrl+C (Phase 28)' {
        $config = New-TestConfig
        $config['autoShutdownTime'] = '1900'
        $config['autoShutdownTimeZone'] = 'Pacific Standard Time'
        $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
        # A first deployment created the VMs and T4, and a later step started one of them again: each is named once.
        InModuleScope DbHubDemo -Parameters @{ Path = $run.ProgressPath } {
            Add-DemoProgressStartedVm -Path $Path -Name 'sqlvm01', 'archost01', 'T4'
            Add-DemoProgressStartedVm -Path $Path -Name 'sqlvm01'
        }
        (Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20)['run']['startedVms'] | Should -Be @('sqlvm01', 'archost01', 'T4')
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { throw 'a stopped run makes no Azure call' }
        $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result @() -Stopped
        $note = 'Running and billing, because this run started or created them: sqlvm01, archost01, and T4. ./scripts/stop-demo.ps1 stops them now; otherwise the nightly auto-shutdown stops sqlvm01 and archost01 at 19:00 (Pacific Standard Time).'
        @($outcome.Notes) | Should -Contain $note
        $lines = @(InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome })
        @($lines | Where-Object { $_ -eq $note }).Count | Should -Be 1
        $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $model['run']['reason'] | Should -Match ([regex]::Escape('Running and billing, because this run started or created them'))
    }

    It 'takes what started from this run''s DEPLOY.VMSTART without a model, leaves out a VM that didn''t start, and adds nothing to DONE (Phase 28)' {
        $config = New-TestConfig
        $config['autoShutdownTime'] = '1900'
        $config['autoShutdownTimeZone'] = 'Pacific Standard Time'
        $started = New-DemoResult -CheckId 'DEPLOY.VMSTART' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'Started sqlvm01 and archost01, which had been stopped, in about 1 minute(s).' -Evidence ([ordered]@{ vms = @('sqlvm01', 'archost01'); started = @('sqlvm01', 'archost01'); notRunning = @(); t4 = ''; minutes = 1 })
        $names = @(InModuleScope DbHubDemo -Parameters @{ Result = @($started) } { Get-DemoStartedVm -Result $Result })
        $names | Should -Be @('sqlvm01', 'archost01')
        # Only what this run issued a start for counts: not a VM that something else was already starting (Phase 28 review).
        $waitedFor = New-DemoResult -CheckId 'DEPLOY.VMSTART' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'Started sqlvm01 and archost01, which had been stopped, in about 1 minute(s).' -Evidence ([ordered]@{ vms = @('sqlvm01', 'archost01'); started = @('archost01'); notRunning = @(); t4 = ''; minutes = 1 })
        @(InModuleScope DbHubDemo -Parameters @{ Result = @($waitedFor) } { Get-DemoStartedVm -Result $Result }) | Should -Be @('archost01')
        $failed = New-DemoResult -CheckId 'DEPLOY.VMSTART' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message 'archost01 isn''t running.' -Evidence ([ordered]@{ vms = @('sqlvm01', 'archost01'); started = @('sqlvm01', 'archost01'); notRunning = @('archost01'); t4 = 'Pass'; minutes = 5 })
        $model = @{ run = @{ startedVms = @('sqlvm01', 'archost01') } }
        @(InModuleScope DbHubDemo -Parameters @{ Result = @($failed); Model = $model } { Get-DemoStartedVm -Result $Result -Model $Model }) | Should -Be @('sqlvm01', 'T4')

        $done = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult) + @($started)); State = (New-FinishedState); Config = $config; Names = $names } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -StartedVm $Names }
        $done.Kind | Should -Be 'Done'
        @($done.Notes | Where-Object { $_ -match 'billing' }).Count | Should -Be 0
        $result = @(New-DoneResult | Where-Object { $_.checkId -ne 'TELEMETRY.T1' }) + @((New-TestResult 'TELEMETRY.T1' 'Fail'), $started)
        $notDone = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = $config; Names = $names } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -StartedVm $Names -Command './scripts/deploy.ps1 -ConfigPath ./config/proof.json' }
        $notDone.Kind | Should -Be 'NotDone'
        @($notDone.Notes) | Should -Contain 'Running and billing, because this run started or created them: sqlvm01 and archost01. ./scripts/stop-demo.ps1 -ConfigPath ./config/proof.json stops them now; otherwise the nightly auto-shutdown stops them at 19:00 (Pacific Standard Time).'
        $config['autoShutdownTime'] = ''
        $plain = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoBillingNote -Config $Config -Name 'sqlvm01' }
        $plain | Should -Be 'Running and billing, because this run started or created it: sqlvm01. ./scripts/stop-demo.ps1 stops it now.'
    }

    It 'ends the page and keep-awake itself when it''s stopped while it starts, before deploy.ps1 holds the run (Phase 28 live finding)' {
        Mock -ModuleName DbHubDemo -CommandName Exit-DemoKeepAwake -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentNotice -MockWith { throw 'stopped while the banner was printed' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { throw 'a stopped start makes no Azure call' }
        # The cancel marker stands in for the Ctrl+C that Enable-DemoRunCancelWatch records in a console.
        $marker = Join-Path -Path $TestDrive -ChildPath ('cancel-' + [guid]::NewGuid().ToString('N') + '.xml')
        Set-Content -LiteralPath $marker -Value 'stop'
        $saved = $env:DBHUB_CANCEL_FILE
        try {
            $env:DBHUB_CANCEL_FILE = $marker
            { Start-DemoDeploymentRun -Config (New-TestConfig) -WaitForT2 -OutputDirectory $script:out -Confirm:$false } | Should -Throw -ExpectedMessage 'stopped while the banner was printed'
        }
        finally {
            $env:DBHUB_CANCEL_FILE = $saved
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Exit-DemoKeepAwake -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -Times 0 -Exactly
        $model = Get-Content -LiteralPath (Join-Path -Path $script:out -ChildPath 'deploy-progress.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $model['run']['state'] | Should -Be 'NotDone'
        $model['run']['reason'] | Should -Match 'Ctrl\+C'
        $model['run']['nextCommand'] | Should -Be './scripts/deploy.ps1'
        Get-Content -LiteralPath (Join-Path -Path $script:out -ChildPath 'deploy-status.html') -Raw | Should -Match 'Stopped, not done'
        InModuleScope DbHubDemo { $script:DemoRunCancelWatch } | Should -BeFalse
    }
}

Describe 'The host credential an earlier guided stop handed over, rotated and cleaned up (ADR 0009)' {
    BeforeEach {
        $config = New-TestConfig
        $script:order = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoKeyVaultSetting -MockWith { [pscustomobject]@{ Enabled = $false } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -MockWith { $script:order.Add('set'); New-DemoResult -CheckId 'START.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'set' -Evidence @{ userName = 'demoadmin' } }
        Mock -ModuleName DbHubDemo -CommandName Set-Clipboard -MockWith { $script:order.Add('clipboard') }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:order.Add('state ' + (@($Value.Keys) -join ',')) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = "demoadmin`n"; StdErr = '' } }
    }

    It 'rotates the handed-over password at the end, and a rotation that fails is a Warning with the portal''s way' {
        Mock -ModuleName DbHubDemo -CommandName Set-DemoGuidedStopRequest -MockWith { New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDREQUEST' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'cleared' }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoBastion -MockWith { New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'deleted' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ HostPasswordUtc = '2026-10-29T15:00:00Z'; GuidedStopUtc = '' } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentStateLocked -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -MockWith { New-DemoResult -CheckId 'STOP.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'Run Command failed.' }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Complete-DemoGuidedStop -Config $Config -Confirm:$false })
        $rotation = $results | Where-Object { $_.checkId -eq 'DEPLOY.T2.HOSTPASSWORD' }
        $rotation.status | Should -Be 'Warning'
        $rotation.remediation | Should -Match 'stop-demo\.ps1'
        $rotation.remediation | Should -Match 'Help, then Reset password'
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -Times 1 -Exactly -ParameterFilter { $Rotate }
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoBastion -Times 1 -Exactly
    }

    It 'stop-demo.ps1 rotates it too, and a failed rotation is a Warning that keeps the handover on record' {
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoBastion -MockWith { New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'deleted' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ HostPasswordUtc = '2026-10-29T15:00:00Z'; Tags = @{ deploymentId = 'abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -MockWith { New-DemoResult -CheckId 'STOP.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'The password wasn''t changed.' }
        $results = @(Stop-DemoEnvironment -Config $config -RemoveBastionOnly -Confirm:$false)
        $rotation = $results | Where-Object { $_.checkId -eq 'STOP.HOSTPASSWORD' }
        $rotation.status | Should -Be 'Warning'
        $rotation.remediation | Should -Match 'Reset password'
    }

    It 'keeps the guided stop''s record while its Bastion couldn''t be removed, so the next run tries again and DONE waits (Phase 28 review)' {
        Mock -ModuleName DbHubDemo -CommandName Set-DemoGuidedStopRequest -MockWith { New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDREQUEST' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'cleared' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ HostPasswordUtc = ''; GuidedStopUtc = '2026-10-29T16:00:00Z' } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentStateLocked -MockWith { $script:order.Add('state ' + (@($Value.Keys) -join ',')) }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoBastion -MockWith { New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'Deleting bas-dbhub failed.' }
        $failed = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Complete-DemoGuidedStop -Config $Config -Confirm:$false })
        ($failed | Where-Object { $_.checkId -eq 'DEPLOY.T2.BASTION' }).status | Should -Be 'Warning'
        $script:order | Should -Not -Contain 'state GuidedStopUtc'

        Mock -ModuleName DbHubDemo -CommandName Remove-DemoBastion -MockWith { New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'deleted' }
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Complete-DemoGuidedStop -Config $Config -Confirm:$false }
        $script:order | Should -Contain 'state GuidedStopUtc'
    }

    It 'stop-demo.ps1 clears the guided stop''s record once Bastion is gone, so DONE no longer waits for it (Phase 28 review)' {
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ HostPasswordUtc = ''; GuidedStopUtc = '2026-10-29T16:00:00Z'; Tags = @{ deploymentId = 'abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoBastion -MockWith { New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Not selected' -Message 'There''s no Bastion host or Bastion public IP to remove.' }
        $null = @(Stop-DemoEnvironment -Config $config -RemoveBastionOnly -Confirm:$false)
        $script:order | Should -Contain 'state GuidedStopUtc'

        # A Bastion that couldn't be removed keeps it.
        $script:order.Clear()
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoBastion -MockWith { New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'Deleting bas-dbhub failed.' }
        $null = @(Stop-DemoEnvironment -Config $config -RemoveBastionOnly -Confirm:$false)
        $script:order | Should -Not -Contain 'state GuidedStopUtc'
    }
}

Describe 'Test-DemoClipboard: only a clipboard the person can paste from (review finding 3)' {
    BeforeAll {
        $script:clipboardVariables = 'CODESPACES', 'SSH_CLIENT', 'SSH_TTY', 'AZUREPS_HOST_ENVIRONMENT', 'DISPLAY', 'WAYLAND_DISPLAY'
    }

    BeforeEach {
        $script:savedVariables = @{}
        foreach ($name in $script:clipboardVariables) {
            $script:savedVariables[$name] = [System.Environment]::GetEnvironmentVariable($name)
            [System.Environment]::SetEnvironmentVariable($name, $null)
        }
        # PowerShell 7's Set-Clipboard doesn't fail on Linux without xclip or a display: it keeps the text in its own process.
        Mock -ModuleName DbHubDemo -CommandName Set-Clipboard -MockWith { }
        $script:tools = @()
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -in 'xclip', 'pbcopy' } -MockWith { if ($Name -in $script:tools) { [pscustomobject]@{ Name = $Name; Source = ('/usr/bin/{0}' -f $Name) } } }
    }

    AfterEach {
        foreach ($name in $script:clipboardVariables) {
            [System.Environment]::SetEnvironmentVariable($name, $script:savedVariables[$name])
        }
    }

    It 'never counts one in GitHub Codespaces, an SSH session, or Azure Cloud Shell, even when Set-Clipboard doesn''t fail' {
        foreach ($case in @(@{ CODESPACES = 'true' }, @{ SSH_CLIENT = 'test-client 50000 22' }, @{ SSH_TTY = '/dev/pts/0' }, @{ AZUREPS_HOST_ENVIRONMENT = 'cloud-shell/1.0' })) {
            $name = @($case.Keys)[0]
            [System.Environment]::SetEnvironmentVariable($name, $case[$name])
            (InModuleScope DbHubDemo { Test-DemoClipboard }) | Should -BeFalse -Because $name
            [System.Environment]::SetEnvironmentVariable($name, $null)
        }
    }

    It 'on Linux, counts one only with an X display and xclip' {
        (InModuleScope DbHubDemo { Test-DemoClipboard -Platform 'Linux' }) | Should -BeFalse -Because 'no display and no xclip'
        $script:tools = @('xclip')
        (InModuleScope DbHubDemo { Test-DemoClipboard -Platform 'Linux' }) | Should -BeFalse -Because 'xclip but no display'
        $env:WAYLAND_DISPLAY = 'wayland-0'
        (InModuleScope DbHubDemo { Test-DemoClipboard -Platform 'Linux' }) | Should -BeFalse -Because 'xclip is an X client, and Wayland alone gives it no display'
        $env:DISPLAY = ':0'
        (InModuleScope DbHubDemo { Test-DemoClipboard -Platform 'Linux' }) | Should -BeTrue
        $script:tools = @()
        (InModuleScope DbHubDemo { Test-DemoClipboard -Platform 'Linux' }) | Should -BeFalse -Because 'a display but no xclip'
    }

    It 'on macOS, counts one only with pbcopy; on Windows, when Set-Clipboard takes text' {
        (InModuleScope DbHubDemo { Test-DemoClipboard -Platform 'MacOS' }) | Should -BeFalse
        $script:tools = @('pbcopy')
        (InModuleScope DbHubDemo { Test-DemoClipboard -Platform 'MacOS' }) | Should -BeTrue
        (InModuleScope DbHubDemo { Test-DemoClipboard -Platform 'Windows' }) | Should -BeTrue
        Mock -ModuleName DbHubDemo -CommandName Set-Clipboard -MockWith { throw 'The clipboard is in use.' }
        (InModuleScope DbHubDemo { Test-DemoClipboard -Platform 'Windows' }) | Should -BeFalse
    }
}

Describe 'Run Commands never stall a run (brief item 14)' {
    BeforeEach {
        $config = New-TestConfig
        $script:views = [System.Collections.Generic.Queue[object]]::new()
        $script:restarts = 0
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmAgentReady -MockWith { 10 }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ GuidedStopUtc = $script:guidedUntil } }
        $script:guidedUntil = ''
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $joined = $ArgumentList -join ' '
            if ($joined -match '^vm get-instance-view') {
                return $(if ($script:views.Count -gt 1) { $script:views.Dequeue() } else { $script:views.Peek() })
            }
            if ($joined -match '^vm restart') {
                $script:restarts++
                return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            if ($joined -match '^rest --method get') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ name = 'DbHubDemo-Chunk-1'; properties = [pscustomobject]@{ provisioningState = 'Deleting' } }) }
            }
            throw ('unexpected Azure CLI call: ' + $joined)
        }
        InModuleScope DbHubDemo { $script:DemoVmRestarted = @{} }
        $script:busy = [pscustomobject]@{
            resources    = @([pscustomobject]@{ name = 'MDE.Windows'; provisioningState = 'Creating' }, [pscustomobject]@{ name = 'RunCommandHandlerWindows'; provisioningState = 'Updating' })
            instanceView = [pscustomobject]@{ extensions = @([pscustomobject]@{ name = 'AzurePolicyforWindows'; statuses = @([pscustomobject]@{ code = 'ProvisioningState/transitioning' }) }) }
        }
        $script:idle = [pscustomobject]@{ resources = @([pscustomobject]@{ name = 'MDE.Windows'; provisioningState = 'Succeeded' }); instanceView = [pscustomobject]@{ extensions = @() } }
    }

    It 'names the extensions Azure is still working on, never the Run Command handler, and lists Run Commands being deleted without waiting for them' {
        $script:views.Enqueue($script:busy)
        $activity = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoVmExtensionActivity -Config $Config -VmName 'sqlvm01' }
        $activity.Busy | Should -BeTrue
        $activity.Items | Should -Be @('MDE.Windows (Creating)', 'AzurePolicyforWindows (transitioning)')
        ($activity.Labels -join ' ') | Should -Match 'MDE\.Windows \(installed by a policy in your tenant\)'
        ($activity.Labels -join ' ') | Should -Not -Match 'RunCommandHandler'
        $activity.RunCommandsDeleting | Should -Be @('DbHubDemo-Chunk-1')
    }

    It 'waits for the extensions to settle, and says so on the status page as an Azure-side wait' {
        $path = Join-Path -Path $TestDrive -ChildPath ('settle-' + [guid]::NewGuid().ToString('N') + '.json')
        InModuleScope DbHubDemo -Parameters @{ Path = $path } { Initialize-DemoProgress -Path $Path -Model (New-DemoProgressModel -Catalog (Get-DemoProgressCatalog)) -Confirm:$false }
        foreach ($view in @($script:busy, $script:busy, $script:idle)) {
            $script:views.Enqueue($view)
        }
        $script:seen = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { $script:seen.Add(('{0}|{1}|{2}' -f (@($PesterBoundParameters['Id']) -join ','), [bool]$PesterBoundParameters['AzureSide'], $PesterBoundParameters['Message'])) }
        $wait = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $path } { Wait-DemoVmExtensionSettled -Config $Config -VmName 'sqlvm01' -TimeoutMinutes 20 -PollSeconds 30 -ProgressPath $Path -ProgressId 'T1.Artifacts' }
        $wait.Settled | Should -BeTrue
        $script:seen[0] | Should -Match '^T1\.Artifacts\|True\|Azure is finishing MDE\.Windows \(installed by a policy in your tenant\).* on sqlvm01; no action needed'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'Azure is finishing MDE\.Windows' }
    }

    It 'restarts a stuck VM once, saving its instance view first, and then ends NOT DONE naming the extension and the next step' {
        $script:views.Enqueue($script:busy)
        $diagnostics = Join-Path -Path $TestDrive -ChildPath 'diagnostics'
        Mock -ModuleName DbHubDemo -CommandName Save-DemoVmInstanceView -MockWith { $script:saved = $true; Join-Path -Path $diagnostics -ChildPath 'sqlvm01-instance-view.json' }
        $settle = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoVmSettle -Config $Config -VmName 'sqlvm01' -FirstMinutes 0 -AfterRestartMinutes 0 -PollSeconds 1 }
        $settle.Settled | Should -BeFalse
        $script:restarts | Should -Be 1
        $script:saved | Should -BeTrue
        $watchdog = $settle.Results | Where-Object { $_.checkId -eq 'DEPLOY.WATCHDOG_SQLVM01' }
        $watchdog.status | Should -Be 'Warning'
        $watchdog.message | Should -Match 'restarted automatically at'
        $stuck = $settle.Results | Where-Object { $_.checkId -eq 'DEPLOY.EXTENSIONS_SQLVM01' }
        $stuck.status | Should -Be 'Fail'
        $stuck.message | Should -Match 'MDE\.Windows'
        $stuck.remediation | Should -Match 'run \./scripts/deploy\.ps1 again'

        # Once per run: a second stall doesn't restart it again.
        $again = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoVmSettle -Config $Config -VmName 'sqlvm01' -FirstMinutes 0 -AfterRestartMinutes 0 -PollSeconds 1 }
        $script:restarts | Should -Be 1
        ($again.Results | Where-Object { $_.checkId -eq 'DEPLOY.WATCHDOG_SQLVM01' }).message | Should -Match 'restarted once already'
    }

    It 'never restarts the T2 host while its guest may be in the middle of setup' {
        $script:views.Enqueue($script:busy)
        $script:guidedUntil = [DateTime]::UtcNow.AddMinutes(30).ToString('o')
        $restart = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Restart-DemoVmOnce -Config $Config -VmName 'archost01' -Confirm:$false }
        $restart.Restarted | Should -BeFalse
        $restart.Reason | Should -Match 'guided stop'
        $script:restarts | Should -Be 0
    }

    It 'never restarts the T2 host mid-build, or while a golden Release runs on it (review finding 6)' {
        # Judged from the deployment state, not the host's health (review follow-up): the agent that would read it is what's stuck.
        $script:stateValues = @{ GuidedStopUtc = ''; Stage = 'Infrastructure'; TrackT1 = 'Monitoring'; TrackT2 = 'Bootstraps'; TrackT4 = ''; TrackFabric = ''; T2Source = 'build'; T2BuildUtc = '2026-10-29T15:00:00Z' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]$script:stateValues }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { throw 'The watchdog must not read health through a Run Command.' }
        $restart = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Restart-DemoVmOnce -Config $Config -VmName 'archost01' -Confirm:$false }
        $restart.Restarted | Should -BeFalse
        $restart.Reason | Should -Match 'guest build may be running'
        # A state that can't be read may hide a build: no restart.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { throw 'The resource group''s tags couldn''t be read.' }
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Restart-DemoVmOnce -Config $Config -VmName 'archost01' -Confirm:$false }).Reason | Should -Match 'deployment state couldn''t be read'
        # While a golden Release runs on it in this process (deploy.ps1 sends its artifacts meanwhile).
        $script:stateValues = @{ GuidedStopUtc = ''; Stage = 'Infrastructure'; TrackT1 = 'Monitoring'; TrackT2 = 'Restore'; TrackT4 = ''; TrackFabric = ''; T2Source = 'golden'; T2BuildUtc = '' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]$script:stateValues }
        $during = InModuleScope DbHubDemo -Parameters @{ Config = $config } {
            $key = '{0}/archost01' -f (Get-DemoResourceGroupName -Config $Config)
            $script:DemoHostAction[$key] = 'Release'
            try {
                Restart-DemoVmOnce -Config $Config -VmName 'archost01' -Confirm:$false
            }
            finally {
                $script:DemoHostAction.Remove($key)
            }
        }
        $during.Restarted | Should -BeFalse
        $during.Reason | Should -Match 'the golden Release is running on it'
        $script:restarts | Should -Be 0
        # A new host whose loader never ran has nothing to interrupt.
        $script:stateValues = @{ GuidedStopUtc = ''; Stage = 'Infrastructure'; TrackT1 = 'Bootstraps'; TrackT2 = 'Artifacts'; TrackT4 = ''; TrackFabric = ''; T2Source = 'build'; T2BuildUtc = '' }
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Restart-DemoVmOnce -Config $Config -VmName 'archost01' -Confirm:$false }).Restarted | Should -BeTrue
        $script:restarts | Should -Be 1
    }

    It 'marks the T2 host busy while a golden guest action runs on it, and clears the mark afterward, even when it fails (review finding 6)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            $script:flagDuring = InModuleScope DbHubDemo { @($script:DemoHostAction.Values) -join ',' }
            if ($script:actionThrows) {
                throw 'the Run Command failed'
            }
            [pscustomobject]@{ Succeeded = $true; Output = '{"succeeded":true}'; ExecutionState = 'Succeeded'; ExitCode = 0; Error = ''; WhileRunningError = '' }
        }
        foreach ($throws in $false, $true) {
            $script:actionThrows = $throws
            $script:flagDuring = ''
            $null = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoGoldenGuestAction -Config $Config -Action 'Release' }
            $script:flagDuring | Should -Be 'Release'
            (InModuleScope DbHubDemo { $script:DemoHostAction.Count }) | Should -Be 0
        }
    }

    It 'restarts a golden copy stuck after its Release without reading its health through a Run Command (review follow-up)' {
        # A golden redeploy's host is a new VM: policy-installed extensions can hold its Run Commands (R336), so a health
        # read through a Run Command times out exactly then.
        $script:healthReads = 0
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { $script:healthReads++; throw 'Run Command timed out.' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ GuidedStopUtc = ''; Stage = 'Infrastructure'; TrackT1 = 'Monitoring'; TrackT2 = 'Restore'; TrackT4 = ''; TrackFabric = ''; T2Source = 'golden'; T2BuildUtc = '' } }
        $restart = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Restart-DemoVmOnce -Config $Config -VmName 'archost01' -Confirm:$false }
        $restart.Restarted | Should -BeTrue
        $script:restarts | Should -Be 1
        $script:healthReads | Should -Be 0
    }

    It 'judges whether the T2 host may be building from the deployment state alone, never its health (review follow-up)' {
        $script:healthReads = 0
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { $script:healthReads++; [pscustomobject]@{ state = 'Ready' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith {
            $values = [ordered]@{ GuidedStopUtc = ''; Stage = ''; TrackT1 = ''; TrackT2 = ''; TrackT4 = ''; TrackFabric = ''; T2Source = ''; T2BuildUtc = '' }
            foreach ($key in $script:stateValues.Keys) {
                $values[$key] = $script:stateValues[$key]
            }
            [pscustomobject]$values
        }
        $blocker = { InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoHostRestartBlocker -Config $Config } }
        # A generation the loader started that nobody saw finish, even after a rerun from Artifacts recorded an earlier step.
        $script:stateValues = @{ T2BuildUtc = '2026-10-29T15:00:00Z'; TrackT1 = 'Monitoring'; TrackT2 = 'Restore'; T2Source = 'build' }
        & $blocker | Should -Match 'bootstrap generation'
        # The track's last step is the loader (a state written before the build was recorded on its own).
        $script:stateValues = @{ TrackT1 = 'Monitoring'; TrackT2 = 'Bootstraps'; T2Source = 'build' }
        & $blocker | Should -Match 'bootstrap generation'
        # A sequential run's stages between the loaders and T2.
        $script:stateValues = @{ Stage = 'Monitoring' }
        & $blocker | Should -Match 'guest build may be running'
        # Nothing running: a new host before its loader, a golden copy after its Release, a host whose T2 step finished,
        # and a sequential run that finished.
        foreach ($values in @(
                @{ TrackT1 = 'Bootstraps'; TrackT2 = 'Artifacts'; T2Source = 'build' }
                @{ TrackT1 = 'Monitoring'; TrackT2 = 'Artifacts'; T2Source = 'golden' }
                @{ TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; T2Source = 'build' }
                @{ Stage = 'Validation' }
            )) {
            $script:stateValues = $values
            & $blocker | Should -BeNullOrEmpty -Because (($values.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ' ')
        }
        $script:healthReads | Should -Be 0
    }

    It 'goes on after the watchdog when the extensions settle after the restart' {
        foreach ($view in @($script:busy, $script:busy, $script:idle)) {
            $script:views.Enqueue($view)
        }
        Mock -ModuleName DbHubDemo -CommandName Save-DemoVmInstanceView -MockWith { '' }
        $settle = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoVmSettle -Config $Config -VmName 'sqlvm01' -FirstMinutes 0 -AfterRestartMinutes 10 -PollSeconds 1 }
        $settle.Settled | Should -BeTrue
        @($settle.Results).Count | Should -Be 1
        $settle.Results[0].status | Should -Be 'Warning'
    }
}

Describe 'Stopping a run with Ctrl+C (Phase 28 live finding)' {
    BeforeAll {
        $modulePath = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1'
        $pwshPath = (Get-Process -Id $PID).Path
        # Starts a hidden PowerShell process that runs -Command, and returns it.
        function Start-TestPwsh([string] $Command) {
            $info = [System.Diagnostics.ProcessStartInfo]::new($pwshPath)
            foreach ($argument in '-NoProfile', '-NonInteractive', '-EncodedCommand', [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))) {
                $info.ArgumentList.Add($argument)
            }
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            return [System.Diagnostics.Process]::Start($info)
        }
        function Wait-TestFile([string] $Path, [int] $Seconds = 60) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $Path) -and $watch.Elapsed.TotalSeconds -lt $Seconds) {
                Start-Sleep -Milliseconds 200
            }
            return (Test-Path -LiteralPath $Path)
        }
    }

    It 'records a real Ctrl+C without changing what it does, and only while deploy.ps1''s run lasts' -Skip:(-not $IsWindows) {
        # A console of its own, where the child sends Ctrl+C to itself (GenerateConsoleCtrlEvent): PowerShell still stops
        # the script at once, and the stop is recorded for the finally blocks.
        $log = Join-Path -Path $TestDrive -ChildPath ('ctrlc-' + [guid]::NewGuid().ToString('N') + '.log')
        $script = Join-Path -Path $TestDrive -ChildPath ('ctrlc-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = @'
param([string] $ModulePath, [string] $Log)
Import-Module -Name $ModulePath
$module = Get-Module -Name 'DbHubDemo'
$null = & $module { Enable-DemoRunCancelWatch }
Add-Type -Namespace 'DbHubDemoTest' -Name 'ConsoleBreak' -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint group); [DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr handler, bool add);'
$null = [DbHubDemoTest.ConsoleBreak]::SetConsoleCtrlHandler([System.IntPtr]::Zero, $false)
$watch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $null = [DbHubDemoTest.ConsoleBreak]::GenerateConsoleCtrlEvent(0, 0)
    Start-Sleep -Seconds 30
    Add-Content -LiteralPath $Log -Value 'not stopped'
}
finally {
    Add-Content -LiteralPath $Log -Value ('stopped after {0} ms' -f [int]$watch.Elapsed.TotalMilliseconds)
    Add-Content -LiteralPath $Log -Value ('cancelled={0}' -f (& $module { Test-DemoRunCancelled }))
    & $module { Disable-DemoRunCancelWatch }
    Add-Content -LiteralPath $Log -Value ('after the run={0}' -f (& $module { Test-DemoRunCancelled }))
}
'@
        [System.IO.File]::WriteAllText($script, $body)
        $child = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-File', ('"{0}"' -f $script), '-ModulePath', ('"{0}"' -f $modulePath), '-Log', ('"{0}"' -f $log) -WindowStyle Hidden -PassThru
        $child.WaitForExit(90000) | Should -BeTrue
        $lines = @(Get-Content -LiteralPath $log)
        $lines | Should -Not -Contain 'not stopped'
        $stoppedAfter = [int](($lines | Where-Object { $_ -like 'stopped after *' } | Select-Object -First 1) -replace '\D', '')
        $stoppedAfter | Should -BeLessThan 5000
        $lines | Should -Contain 'cancelled=True'
        $lines | Should -Contain 'after the run=False' -Because 'a later command in the same session never reads the run''s Ctrl+C as its own'
    }

    It 'ends the run''s jobs within seconds: one that honors the stop ends by itself, and one that doesn''t is ended with its processes' {
        # Before the live finding, deploy.ps1's finally block called Stop-Job and waited for each track's own cleanup.
        $marker = Join-Path -Path $TestDrive -ChildPath ('cancel-' + [guid]::NewGuid().ToString('N') + '.xml')
        $politeTrack = {
            param([string] $Marker)
            'DBHUB-PID {0}' -f $PID
            $env:DBHUB_CANCEL_FILE = $Marker
            try {
                'started'
                Start-Sleep -Seconds 120
            }
            finally {
                if (-not (Test-Path -LiteralPath $env:DBHUB_CANCEL_FILE)) {
                    Start-Sleep -Seconds 60
                }
            }
        }
        $polite = Start-Job -ArgumentList $marker -ScriptBlock $politeTrack
        $stubborn = Start-ThreadJob -ScriptBlock {
            try {
                Start-Sleep -Seconds 120
            }
            finally {
                [System.Threading.Thread]::Sleep(6000)
            }
        }
        $script:stubbornId = $stubborn.InstanceId
        $script:killed = 0
        Mock -ModuleName DbHubDemo -CommandName Get-DemoJobProcessId -ParameterFilter { $Job.InstanceId -eq $script:stubbornId } -MockWith { 4242 }
        Mock -ModuleName DbHubDemo -CommandName Stop-DemoProcessTree -MockWith { $script:killed = $ProcessId; $true }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (@($polite.ChildJobs[0].Output | Where-Object { $_ -eq 'started' }).Count -eq 0 -and $watch.Elapsed.TotalSeconds -lt 60) {
            Start-Sleep -Milliseconds 200
        }
        [System.IO.File]::WriteAllText($marker, 'stopped')
        try {
            $watch.Restart()
            $ended = @(InModuleScope DbHubDemo -Parameters @{ Jobs = @($polite, $stubborn) } { Stop-DemoRunJob -Job $Jobs -GraceSeconds 3 })
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 10
            $ended | Should -Be @($stubborn.Name)
            $script:killed | Should -Be 4242
            $polite.State | Should -Be 'Stopped' -Because 'it skipped its slow cleanup, so it ended by itself'
            Get-Job -Id $polite.Id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'a job that ended is removed'
        }
        finally {
            $null = Wait-Job -Job $stubborn -Timeout 30
            Remove-Job -Job $stubborn -Force -ErrorAction SilentlyContinue
            Remove-Job -Job $polite -Force -ErrorAction SilentlyContinue
        }
    }

    It 'ends a process with every process it started, and never a process that isn''t PowerShell' {
        $directory = Join-Path -Path $TestDrive -ChildPath ('tree-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory
        $childFile = Join-Path -Path $directory -ChildPath 'child.pid'
        $grandchildFile = Join-Path -Path $directory -ChildPath 'grandchild.pid'
        $grandchild = "Set-Content -LiteralPath '{0}' -Value `$PID; Start-Sleep -Seconds 120" -f $grandchildFile
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($grandchild))
        $child = Start-TestPwsh ("Set-Content -LiteralPath '{0}' -Value `$PID; & '{1}' -NoProfile -NonInteractive -EncodedCommand {2}" -f $childFile, $pwshPath, $encoded)
        $other = $null
        try {
            Wait-TestFile -Path $grandchildFile | Should -BeTrue
            $grandchildId = [int](Get-Content -LiteralPath $grandchildFile -Raw)
            InModuleScope DbHubDemo -Parameters @{ Id = $child.Id } { Stop-DemoProcessTree -ProcessId $Id } | Should -BeTrue
            $child.HasExited | Should -BeTrue
            Start-Sleep -Milliseconds 500
            Get-Process -Id $grandchildId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the processes it started end with it'

            # A process ID that now belongs to something else is left alone.
            $info = if ($IsWindows) { [System.Diagnostics.ProcessStartInfo]::new('ping.exe', '-n 60 127.0.0.1') } else { [System.Diagnostics.ProcessStartInfo]::new('sleep', '60') }
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $other = [System.Diagnostics.Process]::Start($info)
            InModuleScope DbHubDemo -Parameters @{ Id = $other.Id } { Stop-DemoProcessTree -ProcessId $Id } | Should -BeFalse
            $other.HasExited | Should -BeFalse
        }
        finally {
            foreach ($process in @($child, $other) | Where-Object { $null -ne $_ }) {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                }
                $process.Dispose()
            }
        }
    }

    It 'keeps the process ID a job reports first, with its start time' {
        $job = Start-ThreadJob -ScriptBlock { 'DBHUB-PID 4242 638000000000000000' }
        $old = Start-ThreadJob -ScriptBlock { 'DBHUB-PID 4243' }
        try {
            $null = Wait-Job -Job $job, $old -Timeout 30
            $read = InModuleScope DbHubDemo -Parameters @{ Job = $job; Old = $old } {
                $null = Receive-DemoDeploymentTrackOutput -Job $Job
                $null = Receive-DemoDeploymentTrackOutput -Job $Old
                @((Get-DemoJobProcessId -Job $Job), (Get-DemoJobProcessStart -Job $Job), (Get-DemoJobProcessId -Job $Old), (Get-DemoJobProcessStart -Job $Old))
            }
            $read | Should -Be @(4242, 638000000000000000, 4243, 0)
        }
        finally {
            Remove-Job -Job $job, $old -Force
        }
    }

    It 'never ends a PowerShell process that got the job''s process ID later: its start time differs (Phase 28 review)' {
        $process = Start-TestPwsh 'Start-Sleep -Seconds 120'
        try {
            $started = $process.StartTime.ToUniversalTime().Ticks
            # A job whose process started a minute earlier: the process with that ID now is another one.
            InModuleScope DbHubDemo -Parameters @{ Id = $process.Id; Ticks = ($started - [System.TimeSpan]::TicksPerMinute) } { Stop-DemoProcessTree -ProcessId $Id -StartTicks $Ticks } | Should -BeTrue -Because 'the job''s own process is gone'
            $process.HasExited | Should -BeFalse
            InModuleScope DbHubDemo -Parameters @{ Id = $process.Id; Ticks = $started } { Stop-DemoProcessTree -ProcessId $Id -StartTicks $Ticks } | Should -BeTrue
            $process.HasExited | Should -BeTrue
        }
        finally {
            if (-not $process.HasExited) {
                $process.Kill($true)
            }
            $process.Dispose()
        }
    }

    It 'has every job of deploy.ps1 report its process ID and start time first, and the track jobs know the cancel marker and their private directory' {
        foreach ($name in 'Start-DemoDeploymentTrackJob', 'Start-DemoArtifactBuildJob', 'Start-DemoPolicyInventoryJob') {
            $text = InModuleScope DbHubDemo -Parameters @{ Name = $name } { (Get-Command -Name $Name).ScriptBlock.ToString() }
            $reported = $text.IndexOf("'DBHUB-PID {0} {1}' -f `$PID, `$(try { [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks } catch { 0 })", [System.StringComparison]::Ordinal)
            $reported | Should -BeGreaterThan 0 -Because $name
            $reported | Should -BeLessThan $text.IndexOf('Import-Module -Name $', [System.StringComparison]::Ordinal) -Because ('{0} reports it before anything slow' -f $name)
        }
        $track = InModuleScope DbHubDemo { (Get-Command -Name 'Start-DemoDeploymentTrackJob').ScriptBlock.ToString() }
        $track | Should -Match ([regex]::Escape('$env:DBHUB_CANCEL_FILE = Join-Path -Path $handoffPath -ChildPath ''cancel.xml'''))
        $track | Should -Match ([regex]::Escape('$env:DBHUB_PRIVATE_ROOT = Join-Path -Path $handoffPath -ChildPath ''private'''))
    }

    It 'puts a track process''s private files under the run''s handoff directory, which deploy.ps1 deletes even after ending the process' {
        $root = Join-Path -Path $TestDrive -ChildPath ('handoff-' + [guid]::NewGuid().ToString('N'))
        $private = Join-Path -Path $root -ChildPath 'private'
        $null = New-Item -ItemType Directory -Path $private -Force
        $saved = $env:DBHUB_PRIVATE_ROOT
        $made = @()
        try {
            $env:DBHUB_PRIVATE_ROOT = $private
            $made += InModuleScope DbHubDemo { Initialize-DemoPrivateDirectory -Prefix 'dbhub-rc' }
            [System.IO.Path]::GetFullPath((Split-Path -Path $made[0] -Parent)) | Should -Be ([System.IO.Path]::GetFullPath($private))
            # Without the run's directory (outside a track process), the user's temporary folder, as before.
            $env:DBHUB_PRIVATE_ROOT = Join-Path -Path $root -ChildPath 'missing'
            $made += InModuleScope DbHubDemo { Initialize-DemoPrivateDirectory -Prefix 'dbhub-rc' }
            [System.IO.Path]::GetFullPath((Split-Path -Path $made[1] -Parent)).TrimEnd([System.IO.Path]::DirectorySeparatorChar) | Should -Be ([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar))
        }
        finally {
            $env:DBHUB_PRIVATE_ROOT = $saved
            foreach ($path in $made) {
                InModuleScope DbHubDemo -Parameters @{ Path = $path } { Remove-DemoPrivateDirectory -Path $Path -Confirm:$false } | Out-Null
            }
        }
    }

    It 'stops waiting for the Azure CLI within a second when the run is stopped, and ends the CLI with it' {
        # Before the live finding, a time-limited CLI call waited in one WaitForExit, which a stop can't interrupt.
        $pidFile = Join-Path -Path $TestDrive -ChildPath ('cli-' + [guid]::NewGuid().ToString('N') + '.pid')
        $command = "Set-Content -LiteralPath '{0}' -Value `$PID; Start-Sleep -Seconds 30" -f $pidFile
        $runner = [powershell]::Create()
        $null = $runner.AddScript({
                param([string] $ModulePath, [string] $FilePath, [string] $Text)
                Import-Module -Name $ModulePath
                & (Get-Module -Name 'DbHubDemo') { param($Path, $Value) Invoke-DemoAzProcess -FilePath $Path -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $Value) -TimeoutSeconds 300 } $FilePath $Text
            }).AddArgument($modulePath).AddArgument($pwshPath).AddArgument($command)
        $null = $runner.BeginInvoke()
        try {
            Wait-TestFile -Path $pidFile | Should -BeTrue
            $cliId = [int](Get-Content -LiteralPath $pidFile -Raw)
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $runner.Stop()
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
            Start-Sleep -Milliseconds 500
            Get-Process -Id $cliId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the CLI ends with the stop instead of running on'
        }
        finally {
            $runner.Dispose()
        }
    }
}

Describe 'STATUS.T2.AUTOSIGNIN: the guest''s one-time sign-in in status.ps1 (brief item 12)' {
    It 'is a Warning while it''s armed, an earlier guided stop''s leftover since the guided stop is retired (2026-11-09), or when its cleanup didn''t finish, and nothing otherwise' {
        $leftover = InModuleScope DbHubDemo { Get-DemoGuidedSignInStatus -Health ([pscustomobject]@{ guidedArmed = $true; guidedRequest = 'valid'; guidedLeft = @() }) }
        $leftover.status | Should -Be 'Warning'
        $leftover.message | Should -Match 'for an earlier guided stop, whose request hasn''t expired; the guided stop is retired'
        $leftover.message | Should -Not -Match 'waiting for you'
        $leftover.remediation | Should -Match '^Run \./scripts/deploy\.ps1: it clears the request before T2''s loader'
        $armed = InModuleScope DbHubDemo { Get-DemoGuidedSignInStatus -Health ([pscustomobject]@{ guidedArmed = $true; guidedRequest = 'expired'; guidedLeft = @() }) }
        $armed.status | Should -Be 'Warning'
        $armed.remediation | Should -Match 'check-sign-in-data\.ps1 -Clean'
        (InModuleScope DbHubDemo { Get-DemoGuidedSignInStatus -Health ([pscustomobject]@{ details = [pscustomobject]@{ guidedSetup = [pscustomobject]@{ armed = $false; request = 'none'; lastProblems = @('rotating the guest password (access denied)') } } }) }).status | Should -Be 'Warning'
        InModuleScope DbHubDemo { Get-DemoGuidedSignInStatus -Health ([pscustomobject]@{ guidedArmed = $false; guidedRequest = 'none'; guidedLeft = @() }) } | Should -BeNullOrEmpty
    }
}

Describe 'The diagnostics bundle (brief item 9)' {
    BeforeEach {
        $script:out = Join-Path -Path $TestDrive -ChildPath ('out-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path -Path $script:out -ChildPath 'logs') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path -Path $script:out -ChildPath 'config-backup') -Force | Out-Null
    }

    It 'redacts IDs, the servers'' suffix, email addresses, the home folder, and masked names again, and leaves the configuration out' {
        $homeInJson = $HOME -replace '\\', '\\'
        $line = '{"checkId":"STATUS.T3","message":"azuresql01-abc123 in 11111111-2222-3333-4444-555555555555 for someone@contoso.example by dbhub-owner-alias at ' + $homeInJson + '"}'
        Set-Content -LiteralPath (Join-Path -Path $script:out -ChildPath 'deploy.jsonl') -Value $line
        Set-Content -LiteralPath (Join-Path -Path $script:out -ChildPath 'logs/deploy-20261029-150000.log') -Value ('Started in {0}' -f $HOME)
        Set-Content -LiteralPath (Join-Path -Path $script:out -ChildPath 'config-backup/demo.config.json') -Value '{"subscriptionId":"11111111-2222-3333-4444-555555555555"}'
        $zip = Join-Path -Path $script:out -ChildPath 'bundle.zip'
        $result = Export-DemoDiagnosticBundle -Directory $script:out -Path $zip -Mask @('dbhub-owner-alias') -Confirm:$false
        $result.status | Should -Be 'Pass'
        $result.evidence['files'] | Should -Contain 'deploy.jsonl'
        $result.evidence['files'] | Should -Contain 'logs/deploy-20261029-150000.log'
        @($result.evidence['files'] | Where-Object { $_ -match 'config' }).Count | Should -Be 0
        $extract = Join-Path -Path $script:out -ChildPath 'extract'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract
        $text = Get-Content -LiteralPath (Join-Path -Path $extract -ChildPath 'deploy.jsonl') -Raw
        $text | Should -Not -Match '11111111-2222-3333-4444-555555555555'
        $text | Should -Match 'azuresql01-\*\*\*'
        $text | Should -Match '\[email\]'
        $text | Should -Match '\[masked\]'
        $text | Should -Not -Match ([regex]::Escape($homeInJson))
        (Get-Content -LiteralPath (Join-Path -Path $extract -ChildPath 'logs/deploy-20261029-150000.log') -Raw) | Should -Match 'Started in ~'
        @(Get-ChildItem -LiteralPath $script:out -Filter 'diagnostics-staging-*').Count | Should -Be 0
    }

    It 'writes no zip when the redacted copy still looks secret (fail closed)' {
        $fakeKey = 'AccountKey=' + ('Q' * 86) + '=='
        Set-Content -LiteralPath (Join-Path -Path $script:out -ChildPath 'deploy.jsonl') -Value ('{"message":"x"}')
        $zip = Join-Path -Path $script:out -ChildPath 'bundle.zip'
        Mock -ModuleName DbHubDemo -CommandName Find-DemoSecretLeak -MockWith { [pscustomobject]@{ Findings = @([pscustomobject]@{ Source = (Join-Path -Path $Path[0] -ChildPath 'deploy.jsonl'); Line = 1; Rule = 'storage-key'; Excerpt = '[REDACTED:storage-key]' }); Scanned = @(); Skipped = @() } }
        $result = Export-DemoDiagnosticBundle -Directory $script:out -Path $zip -Confirm:$false
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'deploy\.jsonl line 1 \(storage-key\)'
        $result.message | Should -Not -Match ([regex]::Escape($fakeKey))
        Test-Path -LiteralPath $zip | Should -BeFalse
    }

    It 'is Not selected with nothing to collect' {
        (Export-DemoDiagnosticBundle -Directory (Join-Path -Path $TestDrive -ChildPath 'empty') -Confirm:$false).status | Should -Be 'Not selected'
    }
}

Describe 'An environment with its own prefix (the live proof, Phase 28)' {
    It 'names the template''s subscription deployment record after the prefix, so another environment''s record is never replaced, read, or deleted' {
        $default = New-TestConfig
        $proof = New-TestConfig
        $proof['prefix'] = 'dbhubalt'
        InModuleScope DbHubDemo -Parameters @{ Default = $default; Proof = $proof } {
            Get-DemoMainDeploymentName -Config $Default | Should -Be 'dbhub-demo-main' -Because 'the default prefix keeps the record it had before Phase 28'
            Get-DemoMainDeploymentName -Config $Proof | Should -Be 'dbhubalt-demo-main'
            Get-DemoResourceGroupName -Config $Proof | Should -Be 'rg-dbhubalt-demo'
        }
        # The deploy, its outputs' read, the destroy's manifest and delete, and the residual check all use it.
        $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo'
        $literal = @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -Filter '*.ps1' | Select-String -Pattern "'dbhub-\{0\}-")
        $literal | Should -BeNullOrEmpty -Because 'a name without the prefix would let a throwaway environment touch another environment''s record'
        @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -Filter '*.ps1' | Select-String -Pattern 'Get-DemoMainDeploymentName -Config').Count | Should -BeGreaterOrEqual 5
    }
}
