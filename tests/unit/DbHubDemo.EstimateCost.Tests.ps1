# scripts/estimate-cost.ps1 signed in (2026-11-13): it read whether a safety stop covers T4's 7-day restart through two of
# the module's internal functions, called from the script, where they aren't visible, so every signed-in estimate counted
# the restart for the rest of the month and warned that "The Defender for Cloud plans, the T3 free offer, or the golden
# snapshots weren't read", which they had been (since 654145e, 2026-11-04). Each read now stands on its own and says what
# it left out, and the internal functions run in the module's scope. Azure is mocked; IDs are obviously fake.
BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    $script:entry = Join-Path -Path $repoRoot -ChildPath 'scripts/estimate-cost.ps1'

    function New-TestConfigFile {
        $config = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        # Obviously fake IDs: every group repeats one character.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $path = Join-Path -Path $TestDrive -ChildPath 'demo.config.json'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }

    function Invoke-TestEstimate {
        $null = & $script:entry -ConfigPath (New-TestConfigFile) -NetworkMode private -OutputPath (Join-Path -Path $TestDrive -ChildPath 'estimate.jsonl')
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'estimate-cost.ps1 signed in: what it reads, and what it says it left out (2026-11-13)' {
    # The mocks keep no state: a mock's body runs in the script's own scope, which has its own $script: variables. What
    # was logged and what the estimate got are read back from the mocks' calls (Should -Invoke).
    BeforeEach {
        Mock Write-DemoLog { }
        Mock Assert-DemoAzContext { }
        Mock Get-DemoDefenderPlan { @([pscustomobject]@{ name = 'CloudPosture'; pricingTier = 'Standard'; subPlan = $null }) }
        Mock Get-DemoT3FreeOfferStatus { [pscustomobject]@{ UseFreeLimit = $false; Result = [pscustomobject]@{ status = 'Warning'; message = 'Not available in this region.' } } }
        Mock Get-DemoT2GoldenSnapshot { @() }
        Mock Export-DemoResult { }
        # The module's own read of the safety stop, which the script reaches only through the module's scope.
        Mock -ModuleName DbHubDemo Get-DemoT4RestartCoverage { [pscustomobject]@{ Counts = $true; Reason = 'the nightly safety stop is in place'; Missing = ''; Fix = '' } }
        # T5's free tier (2026-11-18, ADR 0027), read the same way.
        Mock -ModuleName DbHubDemo Get-DemoT5FreeTierStatus { $true }
        # T5's container lifecycle (2026-11-19, ADR 0027): the resource group's DbHubT5Container tag, and with Session, what
        # deletes the container after a session (review of ab91ee5): here the session control's role.
        Mock Get-DemoDeploymentState { [pscustomobject]@{ Exists = $true; T5Container = 'Session' } }
        Mock -ModuleName DbHubDemo Get-DemoT5ControlRoleState { [pscustomobject]@{ Mode = 'Control'; Why = ''; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = @(); IdentityExists = $true; HoldsRole = $true; HoldsOther = $false } }
        Mock -ModuleName DbHubDemo Test-DemoT5SafetyStopDeletes { $false }
        # Your permissions (2026-11-19, the final tests), which the script reads, as deploy.ps1's preflight does, only for an
        # environment that doesn't exist yet: here an Owner's.
        Mock -ModuleName DbHubDemo Get-DemoDeployerRolePermission { [pscustomobject]@{ CanDefine = $true; CanAssign = $true; Error = '' } }
        Mock Get-DemoCostEstimate {
            [pscustomobject]@{
                Results = @(); Components = @(); HourlyRunning = 1.0; BastionHourly = 0.2; SessionCost = 5.0; IdleMonthly = 30.0; LightUseMonthly = 40.0
                DefenderIncluded = $PesterBoundParameters.ContainsKey('DefenderPlans'); DefenderSession = 0.1; DefenderMonthly = 1.0
                T3FreeOffer = $false; T3FreeOfferUnchecked = $false; T4ReplicaIncluded = $false; T4ReplicaSession = $null
                QueriedOn = '2026-11-13'; NetworkMode = 'private'; NetworkModeAssumed = $false
                # The monthly check (2026-11-19): the worst case, its ceiling and margin, and what it assumed.
                T4RestartHours = 96.0; T4AutoRestartWorstCaseMonthly = 34.18; T5Enabled = $true; T5ContainerLifecycle = 'Session'
                BastionHours = 0.0; MonthlyWorstCase = 74.18; MonthlyCeiling = 415.0; MonthlyMargin = 340.82
            }
        }
    }

    It 'prints the monthly check: the worst case against monthlyCeilingUsd, its margin, and what it assumed (2026-11-19, the docs audit)' {
        $output = & $script:entry -ConfigPath (New-TestConfigFile) -NetworkMode private -BastionHours 4 -OutputPath (Join-Path -Path $TestDrive -ChildPath 'estimate.jsonl') | Out-String -Width 250
        $output | Should -Match 'The monthly check: the worst case against monthlyCeilingUsd \(a negative margin is over it\)'
        $output | Should -Match 'Profile\s+Light-use month\s+T4 restart hours\s+T4 restart\s+T5 container\s+Bastion hours\s+Worst-case month\s+Ceiling\s+Margin'
        $output | Should -Match 'lowest-cost\s+40(\.0+)?\s+96(\.0+)?\s+34\.18\s+Session\s+0(\.0+)?\s+74\.18\s+415(\.0+)?\s+340\.82'
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $BastionHours -eq 4 }
    }

    It 'reads whether a safety stop covers T4''s 7-day restart, so the estimate counts about a day per restart' {
        Invoke-TestEstimate
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4RestartCoverage -Times 1 -Exactly
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $null -ne $T4RestartCoverage -and $T4RestartCoverage.Counts -and $PesterBoundParameters.ContainsKey('DefenderPlans') }
        Should -Invoke Write-DemoLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' } -Because 'everything was read'
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -like 'T4''s automatic restart: about a day each, the nightly safety stop is in place*' }
        # T5's free tier prices its throughput at zero (ADR 0027).
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $T5FreeTier -eq $true }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeployerRolePermission -Times 0 -Exactly -Because 'an existing environment is priced by what''s in place'
    }

    Context 'an environment that doesn''t exist yet, priced as deploy.ps1''s preflight will price its first run for you (2026-11-19, the final tests)' {
        BeforeEach {
            # No environment, so no safety stop in place and no session-control identity yet; the custom roles don't exist.
            Mock Get-DemoDeploymentState { [pscustomobject]@{ Exists = $false; T5Container = '' } }
            Mock -ModuleName DbHubDemo Get-DemoT4RestartCoverage { [pscustomobject]@{ Counts = $false; Missing = 'SafetyStop'; Reason = 'the nightly safety stop isn''t in place yet (the schedule dbhub-safety-stop doesn''t exist)'; Fix = './scripts/deploy.ps1 sets it up after its template.'; Evidence = [ordered]@{ counts = $false; missing = 'SafetyStop'; nightly = 'NotScheduled' } } }
            Mock -ModuleName DbHubDemo Get-DemoSafetyStopRoleState { [pscustomobject]@{ Id = ''; Actions = @(); Error = '' } }
            Mock -ModuleName DbHubDemo Get-DemoT5ControlRoleState { [pscustomobject]@{ Mode = 'NoRole'; Why = 'id-dbhub-demo-control doesn''t exist yet'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $false; Lacking = @('Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/read', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/delete'); IdentityExists = $false; HoldsRole = $false; HoldsOther = $false } }
        }

        It 'counts, for an Owner, the nightly safety stop that deploy.ps1''s first run sets up, and T5''s container for the running hours, and says so' {
            Invoke-TestEstimate
            Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeployerRolePermission -Times 1 -Exactly -Because 'your permissions are read once, for T4 and T5'
            Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $T4RestartCoverage.Counts -and $T4RestartCoverage.Planned -and $T5ContainerLifecycle -ceq 'Session' -and -not $T5ManualDeleteOnly }
            Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -like 'No environment yet, so the estimate prices what deploy.ps1''s first run sets up with your rights, as its preflight does*' }
            Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -like 'T4''s automatic restart: about a day each, counting the nightly safety stop that deploy.ps1 sets up in its first run, since you can assign its role*' }
            Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -like 'T5''s container: for the running hours only: no environment yet, and deploy.ps1 gives the session control its role with your rights*' }
            Should -Invoke Write-DemoLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' }
        }

        It 'counts, for a Contributor, T4''s restart for the rest of the month and T5''s container all month, and names the grant' {
            Mock -ModuleName DbHubDemo Get-DemoDeployerRolePermission { [pscustomobject]@{ CanDefine = $false; CanAssign = $false; Error = '' } }
            Invoke-TestEstimate
            # Priced all month only because nothing automatic will delete it, so the hard ceiling warns, as preflight's does
            # (the re-review of 0590bbe).
            Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { -not $T4RestartCoverage.Counts -and $T5ContainerLifecycle -ceq 'AlwaysOn' -and $T5ManualDeleteOnly }
            Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -like 'T4''s automatic restart: the rest of the month: no environment yet, and you can''t assign the nightly safety stop''s role*Once it''s deployed, an Owner of the subscription runs, once: ./scripts/grant-safety-stop.ps1 -ConfigPath *' }
            Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -like 'T5''s container: all month: no environment yet, and you can''t assign roles, so the session control gets none and only ./scripts/stop-demo.ps1 deletes the container after a session*grant-safety-stop.ps1*' }
            Should -Invoke Write-DemoLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' }
        }
    }

    It 'keeps pricing an existing environment by what''s in place, without reading your permissions (2026-11-19)' {
        Mock -ModuleName DbHubDemo Get-DemoT4RestartCoverage { [pscustomobject]@{ Counts = $false; Missing = 'SafetyStop'; Reason = 'the nightly safety stop isn''t in place yet (the schedule dbhub-safety-stop doesn''t exist)'; Fix = './scripts/deploy.ps1 sets it up after its template.'; Evidence = [ordered]@{ counts = $false; missing = 'SafetyStop'; nightly = 'NotScheduled' } } }
        Invoke-TestEstimate
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeployerRolePermission -Times 0 -Exactly
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { -not $T4RestartCoverage.Counts -and $T5ContainerLifecycle -ceq 'Session' }
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -like 'T4''s automatic restart: the rest of the month, because the nightly safety stop isn''t in place yet*' }
    }

    It 'says exactly what it couldn''t read, and still reads the rest' {
        Mock Get-DemoDefenderPlan { throw 'AuthorizationFailed' }
        Invoke-TestEstimate
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' }
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -eq 'The Defender for Cloud plans couldn''t be read, so the estimate excludes Defender. AuthorizationFailed' }
        Should -Invoke Get-DemoT3FreeOfferStatus -Times 1 -Exactly
        Should -Invoke Get-DemoT2GoldenSnapshot -Times 1 -Exactly
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('DefenderPlans') -and $null -ne $T4RestartCoverage -and $T4RestartCoverage.Counts }
    }

    It 'names the restart when only the safety stop''s coverage can''t be read' {
        Mock -ModuleName DbHubDemo Get-DemoT4RestartCoverage { throw 'The Automation account couldn''t be read.' }
        Invoke-TestEstimate
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' }
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'Whether a safety stop covers T4''s 7-day restart couldn''t be read, so the estimate counts it for the rest of the month.*' }
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('T4RestartCoverage') -and $PesterBoundParameters.ContainsKey('DefenderPlans') }
    }

    It 'says in one line when the Azure CLI isn''t signed in, and reads nothing' {
        Mock Assert-DemoAzContext { throw 'Sign in with az login.' }
        Invoke-TestEstimate
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' }
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'The Azure CLI isn''t signed in to the configured subscription, so the estimate excludes Defender for Cloud and the T2 golden snapshots, prices T3 as regular serverless, and counts T4''s 7-day restart for the rest of the month.*' }
        Should -Invoke Get-DemoDefenderPlan -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4RestartCoverage -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT5FreeTierStatus -Times 0 -Exactly
        Should -Invoke Get-DemoDeploymentState -Times 0 -Exactly
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('T5ContainerLifecycle') } -Because 'the estimate''s default, Session, applies'
    }

    It 'prices T5''s container as the environment has it: <Case> is <Expected> (2026-11-19, ADR 0027)' -ForEach @(
        @{ Case = 'DbHubT5Container Session'; Exists = $true; Tag = 'Session'; Expected = 'Session' }
        @{ Case = 'DbHubT5Container AlwaysOn'; Exists = $true; Tag = 'AlwaysOn'; Expected = 'AlwaysOn' }
        @{ Case = 'an existing group without the tag, deployed before then'; Exists = $true; Tag = ''; Expected = 'AlwaysOn' }
        @{ Case = 'no group yet'; Exists = $false; Tag = ''; Expected = 'Session' }
    ) {
        $state = [pscustomobject]@{ Exists = $Exists; T5Container = $Tag }
        Mock Get-DemoDeploymentState { $state }
        Invoke-TestEstimate
        Should -Invoke Get-DemoDeploymentState -Times 1 -Exactly
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $T5ContainerLifecycle -ceq $Expected }
        Should -Invoke Write-DemoLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' }
    }

    It 'prices a recorded Session all month when nothing automatic deletes the container: no session-control role and no nightly safety stop that can (review of ab91ee5)' {
        Mock -ModuleName DbHubDemo Get-DemoT5ControlRoleState { [pscustomobject]@{ Mode = 'NoRole'; Why = 'id-dbhub-demo-control holds no role at rg-dbhub-demo yet'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = @('a'); IdentityExists = $true; HoldsRole = $false; HoldsOther = $false } }
        Invoke-TestEstimate
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $T5ContainerLifecycle -ceq 'AlwaysOn' -and $T5ManualDeleteOnly }
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -like 'T5''s container: it stays between sessions in this environment, or only stop-demo.ps1 deletes it, so its throughput is priced all month*' }
        Mock -ModuleName DbHubDemo Test-DemoT5SafetyStopDeletes { $true }
        Invoke-TestEstimate
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $T5ContainerLifecycle -ceq 'Session' -and -not $T5ManualDeleteOnly }
        # A session-control role without the container's actions: all month for real, with nothing to excuse.
        Mock -ModuleName DbHubDemo Get-DemoT5ControlRoleState { [pscustomobject]@{ Mode = 'Lacking'; Why = 'its role doesn''t have the container''s actions'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = @('a'); IdentityExists = $true; HoldsRole = $true; HoldsOther = $false } }
        Invoke-TestEstimate
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $T5ContainerLifecycle -ceq 'AlwaysOn' -and -not $T5ManualDeleteOnly }
    }

    It 'prices -T5ContainerLifecycle as given, without reading the environment''s, and assumes Session when the tag can''t be read (2026-11-19)' {
        $null = & $script:entry -ConfigPath (New-TestConfigFile) -NetworkMode private -T5ContainerLifecycle AlwaysOn -OutputPath (Join-Path -Path $TestDrive -ChildPath 'estimate.jsonl')
        Should -Invoke Get-DemoDeploymentState -Times 0 -Exactly
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $T5ContainerLifecycle -ceq 'AlwaysOn' }

        Mock Get-DemoDeploymentState { throw 'AuthorizationFailed' }
        Invoke-TestEstimate
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -eq 'T5''s container lifecycle couldn''t be read, so the estimate assumes the container exists only during a session. AuthorizationFailed' }
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('T5ContainerLifecycle') }
    }
}