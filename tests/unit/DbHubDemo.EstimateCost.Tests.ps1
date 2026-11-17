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
        Mock Get-DemoCostEstimate {
            [pscustomobject]@{
                Results = @(); Components = @(); HourlyRunning = 1.0; BastionHourly = 0.2; SessionCost = 5.0; IdleMonthly = 30.0; LightUseMonthly = 40.0
                DefenderIncluded = $PesterBoundParameters.ContainsKey('DefenderPlans'); DefenderSession = 0.1; DefenderMonthly = 1.0
                T3FreeOffer = $false; T3FreeOfferUnchecked = $false; T4ReplicaIncluded = $false; T4ReplicaSession = $null
                QueriedOn = '2026-11-13'; NetworkMode = 'private'; NetworkModeAssumed = $false
            }
        }
    }

    It 'reads whether a safety stop covers T4''s 7-day restart, so the estimate counts about a day per restart' {
        Invoke-TestEstimate
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4RestartCoverage -Times 1 -Exactly
        Should -Invoke Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $null -ne $T4RestartCoverage -and $T4RestartCoverage.Counts -and $PesterBoundParameters.ContainsKey('DefenderPlans') }
        Should -Invoke Write-DemoLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' } -Because 'everything was read'
        Should -Invoke Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -like 'T4''s automatic restart: about a day each, the nightly safety stop is in place*' }
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
    }
}