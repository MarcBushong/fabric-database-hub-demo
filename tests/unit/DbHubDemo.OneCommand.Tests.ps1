BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig([switch] $WithT4, [string] $InstallMode = 'PaygWizard') {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        $config['t4Enabled'] = [bool]$WithT4
        $config['t2SqlInstallMode'] = $InstallMode
        return $config
    }

    function New-TestResult([string] $CheckId, [string] $Status = 'Pass') {
        New-DemoResult -CheckId $CheckId -Area 'infra' -Target 'subscription' -Status $Status -Message ('{0} {1}' -f $CheckId, $Status) -Remediation $(if ($Status -in 'Fail', 'Manual action required') { 'Fix it, then run ./scripts/deploy.ps1.' } else { '' })
    }

    # Every DONE requirement passing (brief item 16), for the configuration's mode and T4.
    function New-DoneResult([switch] $WithT4, [string] $InstallMode = 'PaygWizard', [switch] $SkipFabric) {
        $ids = InModuleScope DbHubDemo -Parameters @{ T4 = [bool]$WithT4; Mode = $InstallMode; Skip = [bool]$SkipFabric } { Get-DemoDoneRequirement -InstallMode $Mode -T4Off:(-not $T4) -SkipFabric:$Skip }
        foreach ($id in $ids) {
            New-TestResult $id
        }
    }

    function New-FinishedState([switch] $WithT4, [string] $T4Sku = '') {
        [pscustomobject]@{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = $(if ($WithT4) { 'Telemetry' } else { '' }); TrackFabric = 'Fabric'; T4Sku = $T4Sku; GuidedStopUtc = ''; HostPasswordUtc = '' }
    }
}

Describe 'What a run can expect (brief goal 7, items 3 and 13)' {
    It 'gives the first-run and golden-redeploy times, and when a person is needed in PaygWizard mode' {
        $expect = InModuleScope DbHubDemo { Get-DemoDeploymentExpectation -InstallMode 'PaygWizard' -WaitForT2 -T2WaitMinutes 180 }
        $expect.GuidedStop | Should -BeTrue
        $text = $expect.Lines -join ' '
        $text | Should -Match 'about 2 to 3 hours'
        $text | Should -Match 'golden snapshot \(\./scripts/capture-t2-golden\.ps1\) takes about 30 to 45 minutes'
        $text | Should -Match 'about 60 to 90 minutes after the start'
        $text | Should -Match 'about 10 minutes'
        $text | Should -Match 'waits up to 180 minutes'
        $text | Should -Match 'stays awake'
        $text | Should -Match 'If this window closes or the PC restarts, run \./scripts/deploy\.ps1 again; it continues where it stopped\.'
        $expect.HumanText | Should -Match 'Bastion'
    }

    It 'says no step needs a person in ProductKey and Developer modes' {
        foreach ($mode in 'ProductKey', 'Developer') {
            $expect = InModuleScope DbHubDemo -Parameters @{ Mode = $mode } { Get-DemoDeploymentExpectation -InstallMode $Mode -WaitForT2 }
            $expect.GuidedStop | Should -BeFalse
            ($expect.Lines -join ' ') | Should -Match 'No step needs a person'
            $expect.HumanText | Should -BeNullOrEmpty
        }
    }

    It 'warns a session that can''t take keyboard input before anything is spent, with the alternatives and the plan for a person' {
        $environment = [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $false; Codespaces = $false; Windows = $true }
        $notice = InModuleScope DbHubDemo -Parameters @{ Environment = $environment } { Get-DemoDeploymentNotice -Environment $Environment -InstallMode 'PaygWizard' -WaitForT2 -PagePath 'out/deploy-status.html' }
        $text = $notice -join ' '
        $text | Should -Match 'doesn''t take keyboard input'
        $text | Should -Match '-NoWaitForT2'
        $text | Should -Match 'ProductKey'
        $text | Should -Match 'Developer'
        $text | Should -Match 'no T2 performance data or findings'
        @($notice | Where-Object { $_ -like 'PLAN FOR A PERSON: DEPLOY.T2.GUIDEDSTOP*' }).Count | Should -Be 1
        $text | Should -Match 'out/deploy-status\.html'
    }

    It 'warns about the GitHub Codespaces idle timeout and the setting that raises it' {
        $environment = [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $true; Codespaces = $true; Windows = $false }
        $notice = InModuleScope DbHubDemo -Parameters @{ Environment = $environment } { Get-DemoDeploymentNotice -Environment $Environment -InstallMode 'Developer' -WaitForT2 }
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
        $ids | Should -Be @('HUB.ESTATE.T1', 'HUB.ESTATE.T2', 'HUB.ESTATE.T3', 'HUB.ESTATE.T4', 'TELEMETRY.T1', 'TELEMETRY.T2', 'TELEMETRY.T3', 'METRICS.T4', 'T2.ARC.SQLINSTANCE', 'T2.ARC.MONITORING', 'T1.SQLVM.ASSOCIATEDSERVICES', 'FABRIC.ITEMS.REQUIRED')
        (InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'ProductKey' }) | Should -Contain 'T2.ARC.MONITORING'
        $ids | Should -Not -Contain 'DEPLOY.FABRIC.APP'
    }

    It 'leaves T4 out when it''s off, and T2''s performance, PAYG, and monitoring out in Developer mode' {
        $off = InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'PaygWizard' -T4Off }
        $off | Should -Not -Contain 'HUB.ESTATE.T4'
        $off | Should -Not -Contain 'METRICS.T4'
        $developer = InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'Developer' -T4Off -SkipFabric }
        $developer | Should -Contain 'HUB.ESTATE.T2'
        $developer | Should -Not -Contain 'TELEMETRY.T2'
        $developer | Should -Not -Contain 'T2.ARC.SQLINSTANCE'
        $developer | Should -Not -Contain 'FABRIC.ITEMS.REQUIRED'
    }

    It 'checks only what this run''s results don''t show passing, read-only, so a resumed run judges every target' {
        $config = New-TestConfig -WithT4
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubEstate -MockWith { $script:calls.Add('estate ' + ($Target -join ',')); foreach ($t in $Target) { New-TestResult ('HUB.ESTATE.{0}' -f $t) } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith { $script:calls.Add('telemetry ' + ($Target -join ',')); foreach ($t in $Target) { New-TestResult ('TELEMETRY.{0}' -f $t) } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ State = 'Ready'; Names = [pscustomobject]@{ ServerId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT4MetricFlow -MockWith { $script:calls.Add('metrics'); New-TestResult 'METRICS.T4' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcCheck -MockWith { $script:calls.Add('arc ' + ($Check -join ',')); foreach ($c in $Check) { New-TestResult ('T2.ARC.{0}' -f $c.ToUpperInvariant()) } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmAssociatedService -MockWith { $script:calls.Add('inventory'); New-TestResult 'T1.SQLVM.ASSOCIATEDSERVICES' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricRequiredItem -MockWith { $script:calls.Add('fabric'); New-TestResult 'FABRIC.ITEMS.REQUIRED' }
        $seen = @((New-TestResult 'HUB.ESTATE.T1'), (New-TestResult 'HUB.ESTATE.T3'), (New-TestResult 'TELEMETRY.T1'), (New-TestResult 'TELEMETRY.T3'), (New-TestResult 'T2.ARC.SQLINSTANCE'), (New-TestResult 'TELEMETRY.T2' 'Warning'))
        $requirement = InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'PaygWizard' }
        $new = InModuleScope DbHubDemo -Parameters @{ Config = $config; Seen = $seen; Requirement = $requirement } { Invoke-DemoDoneGate -Config $Config -Result $Seen -Requirement $Requirement -TelemetryWaitMinutes 5 }
        $script:calls | Should -Be @('estate T2,T4', 'telemetry T2', 'metrics', 'arc Monitoring', 'inventory', 'fabric')
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
        ($lines -join ' ') | Should -Match 'capture-t2-golden\.ps1 to make future redeploys skip the build and the guided stop'
    }

    It 'is DONE with the optional Insights app listed and how to add it later, when its prerequisites aren''t met' {
        $config = New-TestConfig -WithT4
        $result = @(New-DoneResult -WithT4) + @(
            (New-DemoResult -CheckId 'FABRIC.APP.TENANTSETTING' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'The Fabric tenant setting "Fabric Apps (preview)" is disabled.' -Remediation 'Ask a Fabric administrator.')
            (New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.DATA' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'Execute Queries is off.' -Remediation 'Turn it on.')
        )
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState -WithT4); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        @($outcome.Optional).Count | Should -Be 2
        $lines = (InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) -join ' '
        $lines | Should -Match 'Optional, not needed for the demo: the Insights app'
        $lines | Should -Match 'Fabric Apps \(preview\) and Dataset Execute Queries REST API'
        $lines | Should -Match 'configure-fabric-app\.ps1 -SignIn'
        $lines | Should -Match 'an assistant can''t do that sign-in for you'
    }

    It 'is DONE when the optional app''s own workspace lookup failed, and says that, not a tenant setting, is why (Phase 28 live finding)' {
        # Live: the app's step failed FABRIC.RESOLVE.WORKSPACE, a check ID that isn't the app's own, so it would have
        # counted as a Fail of the demo, and the page blamed tenant settings that were on.
        $config = New-TestConfig -WithT4
        $appRecords = InModuleScope DbHubDemo {
            foreach ($record in @(
                    (New-DemoResult -CheckId 'FABRIC.RESOLVE.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'Your Fabric workspaces couldn''t be listed: HTTP 429.' -Remediation 'Check your Fabric access, then run the script again.')
                    (New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'The Fabric workspace isn''t resolved, so nothing was deployed.')
                )) {
                ConvertTo-DemoOptionalAppRecord -Record $record
            }
        }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult -WithT4) + @($appRecords)); State = (New-FinishedState -WithT4); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        $outcome.ExitCode | Should -Be 0
        @($outcome.Optional).Count | Should -Be 1
        $outcome.Optional[0]['message'] | Should -Match ([regex]::Escape('FABRIC.RESOLVE.WORKSPACE: Your Fabric workspaces couldn''t be listed'))
        $outcome.Optional[0]['howTo'] | Should -Not -Match 'tenant settings'
        $lines = (InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) -join ' '
        $lines | Should -Match ([regex]::Escape('Optional, not needed for the demo: the Insights app (Fabric Apps preview). It wasn''t added: FABRIC.RESOLVE.WORKSPACE'))
    }

    It 'says T4 isn''t deployed and why: off in the configuration, or after the Burstable fallback' {
        $config = New-TestConfig
        $off = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = (New-FinishedState); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $off.Kind | Should -Be 'Done'
        ($off.Notes -join ' ') | Should -Match 't4Enabled is false in your configuration'
        $fallback = New-TestConfig -WithT4
        $after = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = (New-FinishedState -T4Sku 'None'); Config = $fallback } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $after.Kind | Should -Be 'Done'
        ($after.Notes -join ' ') | Should -Match 'Azure refused both Burstable sizes'
        ($after.Notes -join ' ') | Should -Match 'Standard_D2ds_v5'
        $after.Reason | Should -Match 'T1, T2, and T3 in Estate'
    }

    It 'lets a t4SkuName the configuration sets win over a recorded "no T4", so DONE still needs T4 (review finding 5)' {
        $sized = New-TestConfig -WithT4
        $sized['t4SkuName'] = 'Standard_D2ds_v5'
        (InModuleScope DbHubDemo -Parameters @{ Config = $sized } { Get-DemoT4OffReason -Config $Config -State ([pscustomobject]@{ T4Sku = 'None' }) }) | Should -BeNullOrEmpty
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = (New-FinishedState -WithT4 -T4Sku 'None'); Config = $sized } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'NotDone' -Because 'a T4 that''s on must show in Database Hub'
        $outcome.Missing | Should -Contain 'HUB.ESTATE.T4'
        $outcome.Missing | Should -Contain 'METRICS.T4'
        ($outcome.Notes -join ' ') | Should -Not -Match 'Azure refused both Burstable sizes'

        # t4Enabled false in the file is the reason, whatever an earlier fallback recorded.
        (InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4OffReason -Config $Config -State ([pscustomobject]@{ T4Sku = 'None' }) }) | Should -Match 't4Enabled is false in your configuration'
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
        $unfinished = InModuleScope DbHubDemo -Parameters @{ Result = @(New-DoneResult); State = ([pscustomobject]@{ Stage = 'Monitoring'; TrackT1 = 'Telemetry'; TrackT2 = 'T2'; TrackT4 = ''; TrackFabric = 'Fabric'; T4Sku = '' }); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
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

    It 'counts a guided stop that timed out as NOT DONE with the command that continues it' {
        $config = New-TestConfig
        $result = @(New-DoneResult) + @(New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDSTOP' -Area 'infra' -Target 'T2' -Status 'Manual action required' -Message 'Nobody finished SQL Server setup by 14:05.' -Remediation 'Run ./scripts/deploy.ps1 again when you have about 15 minutes.')
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.Reason | Should -Match 'DEPLOY\.T2\.GUIDEDSTOP'
        $outcome.Next | Should -Match 'deploy\.ps1 again when you have about 15 minutes'
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
        $model['guidedStop']['state'] | Should -Be 'Pending'
        $model['expect']['humanText'] | Should -Match '60 to 90 minutes'
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

    It 'ends a stopped run at Stopped, not done, with the command to continue, without an Azure call, and moves its running steps back to Pending (Phase 28 live finding)' {
        $config = New-TestConfig
        $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
        InModuleScope DbHubDemo { $script:DemoRunCancelWatch } | Should -BeTrue -Because 'the run records Ctrl+C from its start'
        InModuleScope DbHubDemo -Parameters @{ Path = $run.ProgressPath } {
            Set-DemoProgressStep -Path $Path -Id 'Preflight' -State 'Done' -Status 'Pass' -Message 'Passed.'
            Set-DemoProgressStep -Path $Path -Id 'T1.Bootstraps' -State 'Running' -Message 'The loader runs.'
            Set-DemoProgressStep -Path $Path -Id 'T2.GuidedStop' -State 'Action needed' -Message 'Waiting for you.'
            Set-DemoProgressValue -Path $Path -Section 'guidedStop' -Value @{ state = 'Ready' }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { throw 'a stopped run makes no Azure call' }
        $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result @() -Stopped
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -Times 0 -Exactly
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.ExitCode | Should -Be 2
        $outcome.Reason | Should -Match 'Ctrl\+C'
        $outcome.NextCommand | Should -Be './scripts/deploy.ps1'
        $outcome.Next | Should -Match ([regex]::Escape('./scripts/stop-demo.ps1')) -Because 'it stopped at the guided stop, which leaves Bastion up and the password unrotated'
        $outcome.Next | Should -Match 'until the next run cleans them up when it gets to T2, whether or not setup finished meanwhile' -Because 'the next run cleans up even when setup finished after the stop (Phase 28 review)'
        $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $model['run']['state'] | Should -Be 'NotDone'
        $model['run']['nextCommand'] | Should -Be './scripts/deploy.ps1'
        $steps = @{}
        foreach ($track in @($model['tracks'])) { foreach ($item in @($track['steps'])) { $steps[[string]$item['id']] = $item } }
        $steps['Preflight']['state'] | Should -Be 'Done'
        $steps['T1.Bootstraps']['state'] | Should -Be 'Pending'
        $steps['T1.Bootstraps']['message'] | Should -Match 'Stopped here \(Ctrl\+C\)'
        $steps['T2.GuidedStop']['state'] | Should -Be 'Pending'
        $page = Get-Content -LiteralPath $run.PagePath -Raw
        $page | Should -Match 'Stopped, not done'
        $page | Should -Match ([regex]::Escape('Run: ./scripts/deploy.ps1'))
        InModuleScope DbHubDemo { $script:DemoRunCancelWatch } | Should -BeFalse -Because 'a later command in the same session never reads this run''s Ctrl+C as its own'
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

Describe 'The guided stop''s prompt (brief items 4 and 13)' {
    BeforeEach {
        $script:printed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-Host -MockWith { $script:printed.Add([string]$Object) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAttention -MockWith { $script:printed.Add('ATTENTION') }
        Mock -ModuleName DbHubDemo -CommandName Start-Process -MockWith { $script:printed.Add('BROWSER ' + $FilePath + ' ' + (@($PesterBoundParameters['ArgumentList']) -join ' ')) }
        $script:url = 'https://portal.azure.com/#@contoso.example/resource/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/archost01'
    }

    It 'shows a large banner, the time limit, the steps, the link, opens the browser, draws attention, and prints the handoff line' {
        $saved = $env:CODESPACES
        try {
            $env:CODESPACES = $null
            InModuleScope DbHubDemo -Parameters @{ Url = $script:url } { Show-DemoGuidedStopPrompt -Url $Url -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(45)) -HostUser 'demoadmin' -SignInWay 'portalReset' -PagePath 'out/deploy-status.html' }
        }
        finally {
            $env:CODESPACES = $saved
        }
        $text = $script:printed -join "`n"
        $text | Should -Match 'WAITING FOR YOU: one step, about 10 minutes'
        $text | Should -Match 'Time limit: 4[45] minutes'
        $text | Should -Match 'Use pay-as-you-go billing through Microsoft Azure'
        $text | Should -Match 'Help, then Reset password'
        # In GitHub Actions the module's log masking writes the subscription's GUID as *** (Phase 26c).
        $text | Should -Match 'Portal: https://portal\.azure\.com/#@contoso\.example/resource/subscriptions/[^/]+/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Compute/virtualMachines/archost01'
        $script:printed | Should -Contain 'ATTENTION'
        # A Linux machine without xdg-open (some CI images) has no way to open a browser, and says so instead.
        $canOpen = $IsWindows -or $IsMacOS -or $null -ne (Get-Command -Name 'xdg-open' -ErrorAction SilentlyContinue)
        @($script:printed | Where-Object { $_ -match '^BROWSER ' }).Count -gt 0 | Should -Be $canOpen
        @($script:printed | Where-Object { $_ -like 'HUMAN ACTION REQUIRED: DEPLOY.T2.GUIDEDSTOP - *out/deploy-status.html*' }).Count | Should -Be 1
    }

    It 'doesn''t open a browser in GitHub Codespaces' {
        $saved = $env:CODESPACES
        try {
            $env:CODESPACES = 'true'
            InModuleScope DbHubDemo -Parameters @{ Url = $script:url } { Show-DemoGuidedStopPrompt -Url $Url -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(45)) -SignInWay 'portalReset' }
        }
        finally {
            $env:CODESPACES = $saved
        }
        @($script:printed | Where-Object { $_ -match '^BROWSER ' }).Count | Should -Be 0
        ($script:printed -join ' ') | Should -Match 'Open the portal link above'
    }

    It 'reminds with the handoff line' {
        InModuleScope DbHubDemo { Show-DemoGuidedStopReminder -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(30)) -PagePath 'out/deploy-status.html' -Status 'Setup is open in arcsql01.' }
        ($script:printed -join ' ') | Should -Match 'Reminder: the guided stop still waits for you'
        @($script:printed | Where-Object { $_ -like 'HUMAN ACTION REQUIRED: DEPLOY.T2.GUIDEDSTOP*' }).Count | Should -Be 1
    }

    It 'points the handoff line at the console, not a page that doesn''t exist, without a status page (review finding 2)' {
        $line = InModuleScope DbHubDemo { Get-DemoHumanActionLine -PagePath '' -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(30)) }
        $line | Should -BeLike 'HUMAN ACTION REQUIRED: DEPLOY.T2.GUIDEDSTOP - *'
        $line | Should -Not -Match 'deploy-status\.html'
        $line | Should -Match 'printed above in deploy\.ps1''s console'
        (InModuleScope DbHubDemo { Get-DemoHumanActionLine -PagePath 'out/deploy-status.html' }) | Should -Match 'Steps and link: out/deploy-status\.html \(or \./scripts/status\.ps1 -Watch\)\.$'
    }
}

Describe 'The host credential at the guided stop (ADR 0009)' {
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

    It 'puts a one-time password on a working clipboard, never in a result' {
        Mock -ModuleName DbHubDemo -CommandName Test-DemoClipboard -MockWith { $true }
        $credential = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoGuidedStopCredential -Config $Config }
        $credential.Mode | Should -Be 'clipboard'
        $credential.UserName | Should -Be 'demoadmin'
        $script:order | Should -Be @('set', 'clipboard')
    }

    It 'without a clipboard or the Key Vault opt-in: sets and shows no password, records the handover for the rotation, and points to the portal' {
        Mock -ModuleName DbHubDemo -CommandName Test-DemoClipboard -MockWith { $false }
        $credential = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoGuidedStopCredential -Config $Config }
        $credential.Mode | Should -Be 'portalReset'
        $credential.UserName | Should -Be 'demoadmin'
        $script:order | Should -Be @('state HostPasswordSet')
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-Clipboard -Times 0 -Exactly
        $result = @($credential.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.HOSTPASSWORD' })[0]
        $result.status | Should -Be 'Pass'
        $result.docUrl | Should -Be 'https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp'
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

    It 'sends a session whose Set-Clipboard only pretends (an SSH session here) to the portal''s Reset password, with no password set' {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoKeyVaultSetting -MockWith { [pscustomobject]@{ Enabled = $false } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -MockWith { throw 'no password may be set' }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = "demoadmin`n"; StdErr = '' } }
        $env:SSH_TTY = '/dev/pts/0'
        $credential = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoGuidedStopCredential -Config $Config }
        $credential.Mode | Should -Be 'portalReset'
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -Times 0 -Exactly
    }
}

Describe 'Invoke-DemoT2GuidedStop: the stop, then the run continues on its own' {
    BeforeEach {
        $config = New-TestConfig
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:health = [System.Collections.Generic.Queue[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoGuidedStopRequest -MockWith { $script:calls.Add('request ' + $Action); New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDREQUEST' -Area 'infra' -Target 'T2' -Status 'Pass' -Message $Action }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentStateLocked -MockWith { $script:calls.Add('state ' + (@($Value.Keys) -join ',')) }
        Mock -ModuleName DbHubDemo -CommandName New-DemoBastion -MockWith { $script:calls.Add('bastion nowait=' + [bool]$NoWait); New-DemoResult -CheckId 'START.BASTION' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'being deployed' }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoBastionDeployment -MockWith { [pscustomobject]@{ Succeeded = $true; State = 'Succeeded' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcConfiguration -MockWith { $script:calls.Add('onboard skipConfiguration=' + [bool]$SkipConfiguration); New-DemoResult -CheckId 'T2.ARC.CONNECTED' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'connected' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { if ($script:health.Count -gt 1) { $script:health.Dequeue() } else { $script:health.Peek() } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGuidedStopCredential -MockWith { $script:calls.Add('credential'); [pscustomobject]@{ Mode = 'portalReset'; UserName = 'demoadmin'; Text = ''; Results = @() } }
        Mock -ModuleName DbHubDemo -CommandName Show-DemoGuidedStopPrompt -MockWith { $script:calls.Add('prompt') }
        Mock -ModuleName DbHubDemo -CommandName Show-DemoGuidedStopReminder -MockWith { $script:calls.Add('reminder') }
        Mock -ModuleName DbHubDemo -CommandName Complete-DemoGuidedStop -MockWith { $script:calls.Add('cleanup'); @() }
        # The deployment state that Clear-DemoGuidedStopLeftover reads: nothing open unless a test queues more.
        $script:states = [System.Collections.Generic.Queue[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { if ($script:states.Count -gt 0) { $script:states.Dequeue() } else { [pscustomobject]@{ HostPasswordUtc = ''; GuidedStopUtc = '' } } }
        $script:waitingArc = [pscustomobject]@{ state = 'WaitingForArcOnboarding'; currentStep = 'ArcOnboardingBeforeWizard'; message = 'waiting for Arc' }
        $script:wizard = [pscustomobject]@{ state = 'ManualActionRequired'; currentStep = 'SqlSetupWizard'; message = 'SQL Server setup is open in arcsql01.' }
        $script:after = [pscustomobject]@{ state = 'InProgress'; currentStep = 'GuestSignInCleanup'; message = 'Cleaning up.' }
    }

    It 'requests the stop, starts Bastion without waiting, onboards Arc first, prompts once, and continues when the host''s check passes' {
        foreach ($item in @($script:wizard, $script:wizard, $script:after)) {
            $script:health.Enqueue($item)
        }
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $script:waitingArc } { Invoke-DemoT2GuidedStop -Config $Config -Context @{} -Health $Health -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(120)) -PollSeconds 10 }
        $stop.Status | Should -Be 'Done'
        $script:calls | Should -Be @('request Set', 'state GuidedStopUtc', 'bastion nowait=True', 'onboard skipConfiguration=True', 'credential', 'prompt', 'cleanup')
        ($stop.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDSTOP' }).status | Should -Be 'Pass'
    }

    It 'lets deploy.ps1''s own process prompt when the tracks run in their own processes' {
        foreach ($item in @($script:wizard, $script:after)) {
            $script:health.Enqueue($item)
        }
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $script:wizard } { Invoke-DemoT2GuidedStop -Config $Config -Context @{ PromptInParent = $true } -Health $Health -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(120)) -PollSeconds 10 }
        $stop.Status | Should -Be 'Done'
        $script:calls | Should -Not -Contain 'prompt'
        $script:calls | Should -Not -Contain 'credential'
    }

    It 'times out as Manual action required, reminds the person meanwhile, and still cleans up' {
        $script:health.Enqueue($script:wizard)
        # Each read of the clock is 10 minutes later: the person's window (at least 45 minutes) passes without setup.
        $script:clock = [DateTime]::UtcNow
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $script:clock = $script:clock.AddMinutes(10); $script:clock }
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $script:wizard } { Invoke-DemoT2GuidedStop -Config $Config -Context @{} -Health $Health -DeadlineUtc ([DateTime]::UtcNow) -PollSeconds 10 }
        $stop.Status | Should -Be 'TimedOut'
        $timedOut = $stop.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDSTOP' }
        $timedOut.status | Should -Be 'Manual action required'
        $timedOut.remediation | Should -Match 'Run \./scripts/deploy\.ps1 again'
        $script:calls | Should -Contain 'reminder'
        $script:calls[-1] | Should -Be 'cleanup'
    }

    It 'fails, and cleans up, when the host fails during the stop' {
        foreach ($item in @($script:wizard, ([pscustomobject]@{ state = 'Failed'; currentStep = 'SqlSetupWizard'; message = 'Setup failed.' }))) {
            $script:health.Enqueue($item)
        }
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $script:wizard } { Invoke-DemoT2GuidedStop -Config $Config -Context @{} -Health $Health -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(120)) -PollSeconds 10 }
        $stop.Status | Should -Be 'Failed'
        ($stop.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDSTOP' }).status | Should -Be 'Fail'
        $script:calls[-1] | Should -Be 'cleanup'
    }

    It 'isn''t needed when SQL Server is already set up' {
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $script:after } { Invoke-DemoT2GuidedStop -Config $Config -Context @{} -Health $Health -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(120)) }
        $stop.Status | Should -Be 'NotNeeded'
        $script:calls.Count | Should -Be 0
    }

    It 'removes what an earlier guided stop left open when setup finished after a Ctrl+C, so the run isn''t DONE with it (Phase 28 review)' {
        # The review: Ctrl+C at the guided stop skipped its cleanup, setup finished in the guest anyway, and the next run's
        # guided stop returned NotNeeded and ended DONE with Bastion up and the handed-over password valid.
        $ready = [pscustomobject]@{ state = 'Ready'; currentStep = 'WorkloadRunner'; message = 'Every step is in the desired state.' }
        $script:states.Enqueue([pscustomobject]@{ HostPasswordUtc = '2026-10-29T15:00:00Z'; GuidedStopUtc = '2026-10-29T16:00:00Z' })
        $script:states.Enqueue([pscustomobject]@{ HostPasswordUtc = ''; GuidedStopUtc = '' })
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $ready } { Invoke-DemoT2GuidedStop -Config $Config -Context @{} -Health $Health -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(120)) }
        $stop.Status | Should -Be 'NotNeeded'
        $script:calls | Should -Be @('cleanup')
        $cleaned = $stop.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' }
        $cleaned.status | Should -Be 'Pass'
        $cleaned.message | Should -Match 'host''s password, handed over at 2026-10-29T15:00:00Z'

        # A password that's still valid afterward (the rotation failed): Manual action required, naming stop-demo.ps1.
        $script:calls.Clear()
        $script:states.Enqueue([pscustomobject]@{ HostPasswordUtc = '2026-10-29T15:00:00Z'; GuidedStopUtc = '' })
        $script:states.Enqueue([pscustomobject]@{ HostPasswordUtc = '2026-10-29T15:00:00Z'; GuidedStopUtc = '' })
        $left = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $script:after } { Invoke-DemoT2GuidedStop -Config $Config -Context @{} -Health $Health -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(120)) }
        $script:calls | Should -Be @('cleanup')
        $open = $left.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' }
        $open.status | Should -Be 'Manual action required'
        $open.remediation | Should -Match ([regex]::Escape('./scripts/stop-demo.ps1 -RemoveBastionOnly'))

        # While deploy.ps1 is being stopped, nothing: the next run does it.
        $script:calls.Clear()
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
        $script:states.Enqueue([pscustomobject]@{ HostPasswordUtc = '2026-10-29T15:00:00Z'; GuidedStopUtc = '2026-10-29T16:00:00Z' })
        $stopped = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $ready } { Invoke-DemoT2GuidedStop -Config $Config -Context @{} -Health $Health -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(120)) }
        $script:calls.Count | Should -Be 0
        $stopped.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' } | Should -BeNullOrEmpty
    }

    It 'leaves its Azure cleanup to the next run, and the status page to deploy.ps1, when deploy.ps1 was stopped (Phase 28 live finding)' {
        # Live, Ctrl+C here seemed to do nothing: stopping this track ran its cleanup first, minutes of Azure calls.
        $script:health.Enqueue($script:wizard)
        $script:clock = [DateTime]::UtcNow
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $script:clock = $script:clock.AddMinutes(10); $script:clock }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressValue -MockWith { $script:calls.Add(('page {0} {1}' -f $Section, [string]$Value['state'])) }
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = $config; Health = $script:wizard } { Invoke-DemoT2GuidedStop -Config $Config -Context @{ ProgressPath = 'progress.json' } -Health $Health -DeadlineUtc ([DateTime]::UtcNow) -PollSeconds 10 }
        $stop.Status | Should -Be 'Stopped'
        $script:calls | Should -Not -Contain 'cleanup'
        $script:calls | Should -Not -Contain 'page guidedStop TimedOut'
        $stopped = $stop.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDSTOP' }
        $stopped.status | Should -Be 'Manual action required'
        $stopped.message | Should -Match 'Bastion stays up'
        $stopped.remediation | Should -Match ([regex]::Escape('./scripts/stop-demo.ps1'))
    }

    It 'knows the host''s phases, and the host''s step list matches the VM side''s plan' {
        (InModuleScope DbHubDemo { Get-DemoT2HostPhase -Health ([pscustomobject]@{ state = 'InProgress'; currentStep = 'GuestVhdx' }) }).Phase | Should -Be 'Build'
        (InModuleScope DbHubDemo { Get-DemoT2HostPhase -Health ([pscustomobject]@{ state = 'ManualActionRequired'; currentStep = 'SqlSetupWizard' }) }).Phase | Should -Be 'GuidedStop'
        (InModuleScope DbHubDemo { Get-DemoT2HostPhase -Health ([pscustomobject]@{ state = 'InProgress'; currentStep = 'ConfigureSql' }) }).Phase | Should -Be 'AfterSetup'
        (InModuleScope DbHubDemo { Get-DemoT2HostPhase -Health ([pscustomobject]@{ state = 'Failed'; currentStep = 'GuestOnline' }) }).Phase | Should -Be 'Failed'
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1') -Raw
        $vmOrder = @([regex]::Matches($text, "@\{ Name = '([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value })
        $vmOrder | Should -Be @(InModuleScope DbHubDemo { Get-DemoHostStepOrder })
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
    It 'is Pass while it waits for a guided stop, a Warning when it''s armed with none waiting or its cleanup didn''t finish, and nothing otherwise' {
        (InModuleScope DbHubDemo { Get-DemoGuidedSignInStatus -Health ([pscustomobject]@{ guidedArmed = $true; guidedRequest = 'valid'; guidedLeft = @() }) }).status | Should -Be 'Pass'
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
        $proof['prefix'] = 'dbhubp28'
        InModuleScope DbHubDemo -Parameters @{ Default = $default; Proof = $proof } {
            Get-DemoMainDeploymentName -Config $Default | Should -Be 'dbhub-demo-main' -Because 'the default prefix keeps the record it had before Phase 28'
            Get-DemoMainDeploymentName -Config $Proof | Should -Be 'dbhubp28-demo-main'
            Get-DemoResourceGroupName -Config $Proof | Should -Be 'rg-dbhubp28-demo'
        }
        # The deploy, its outputs' read, the destroy's manifest and delete, and the residual check all use it.
        $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo'
        $literal = @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -Filter '*.ps1' | Select-String -Pattern "'dbhub-\{0\}-")
        $literal | Should -BeNullOrEmpty -Because 'a name without the prefix would let a throwaway environment touch another environment''s record'
        @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -Filter '*.ps1' | Select-String -Pattern 'Get-DemoMainDeploymentName -Config').Count | Should -BeGreaterOrEqual 5
    }
}