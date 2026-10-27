BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the evaluation-only bootstrap's functions (and T1's helpers it reuses) without running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-EvalArcVmBootstrap.ps1')

    function New-TestEvalContext {
        param([string] $Mode = 'PaygWizard')
        $root = Join-Path -Path $TestDrive -ChildPath ('eval-' + [guid]::NewGuid().ToString('N'))
        Initialize-DemoVmContext -Root $root -Role 'EvalArcVm' -BundleRoot $repoRoot | Out-Null
        Get-DemoEvalArcContext -StateRoot $root -BundleRoot $repoRoot -Settings ([ordered]@{ role = 'EvalArcVm'; t2SqlInstallMode = $Mode; seedScale = 1 })
    }

    function Write-TestMarker {
        param([System.Collections.IDictionary] $Context, [datetime] $ConnectedUtc)
        $marker = [ordered]@{ schemaVersion = 1; machineName = 'arcsql01'; status = 'Connected'; resourceId = 'x'; connectedUtc = $ConnectedUtc.ToString('o'); guestVmId = ''; evaluationOnly = $true }
        Set-Content -LiteralPath $Context.ArcMarkerPath -Value ($marker | ConvertTo-Json)
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'Evaluation-only T2 bootstrap (EvalArcVm)' {
    It 'follows the evaluation procedure, with the Azure guest agent disabled last' {
        $plan = Get-DemoEvalArcStepPlan -Context (New-TestEvalContext)
        $plan.Name | Should -Be @(
            'ArcEvaluationPrep', 'SqlMedia', 'SqlUnattendedInstall', 'ArcOnboarding', 'ArcOnboardingBeforeWizard', 'SqlSetupWizard',
            'SignInCleanup', 'SqlAdminAccess', 'ConfigureSql', 'SeedDatabase', 'WorkloadRunner', 'DisableAzureGuestAgent')
    }

    It 'selects the steps for the install mode, and cleans up sign-in data in every mode' -TestCases @(
        @{ Mode = 'PaygWizard'; Selected = @('ArcOnboardingBeforeWizard', 'SqlSetupWizard'); Skipped = @('SqlUnattendedInstall', 'ArcOnboarding') }
        @{ Mode = 'ProductKey'; Selected = @('SqlUnattendedInstall', 'ArcOnboarding'); Skipped = @('ArcOnboardingBeforeWizard', 'SqlSetupWizard') }
        @{ Mode = 'Developer'; Selected = @('SqlUnattendedInstall', 'ArcOnboarding'); Skipped = @('ArcOnboardingBeforeWizard', 'SqlSetupWizard') }
    ) {
        $plan = Get-DemoEvalArcStepPlan -Context (New-TestEvalContext -Mode $Mode)
        foreach ($name in $Selected) {
            $step = $plan | Where-Object { $_.Name -eq $name }
            [bool](& $step.When $step) | Should -BeTrue -Because $name
        }
        foreach ($name in $Skipped) {
            $step = $plan | Where-Object { $_.Name -eq $name }
            [bool](& $step.When $step) | Should -BeFalse -Because $name
        }
        ($plan | Where-Object { $_.Name -eq 'SignInCleanup' }).Contains('When') | Should -BeFalse -Because 'Arc onboarding uses a token in every mode'
    }

    It 'waits while setup runs, then removes the sign-in data on this VM and fails closed when any is left' {
        $step = Get-DemoEvalArcStepPlan -Context (New-TestEvalContext) | Where-Object { $_.Name -eq 'SignInCleanup' }
        Mock -CommandName Get-DemoSetupProcess -MockWith { @('ScenarioEngine') }
        Mock -CommandName Invoke-DemoSignInSweep -MockWith { throw 'should not run while setup is open' }
        (& $step.Set $step).Outcome | Should -Be 'InProgress'

        Mock -CommandName Get-DemoSetupProcess -MockWith { @() }
        Mock -CommandName Enable-DemoIeEsc -MockWith { }
        Mock -CommandName Invoke-DemoSignInSweep -MockWith { [pscustomobject]@{ pass = $true; cleaned = [bool]$Clean; found = [pscustomobject]@{ userTokens = 1; otherTokens = 0; filesWithUserData = 1; eventLogUserTokens = 0; browserCaches = 1; archives = 0; filesUnverified = 0; appTokens = 0; eventLogAppTokens = 0; securityLogTokens = 0 }; remaining = [pscustomobject]@{ userTokens = 0; otherTokens = 0; filesWithUserData = 0; eventLogUserTokens = 0; browserCaches = 0; archives = 0; filesUnverified = 0; appTokens = 0; eventLogAppTokens = 0; securityLogTokens = 0 }; actions = [pscustomobject]@{ filesRedacted = 1; filesDeleted = 0; cachesRemoved = 1; brokerEntriesRemoved = 0; eventLogsCleared = @() }; foundLocations = @(); foundEventLogs = @() } }
        & $step.Set $step
        Should -Invoke -CommandName Invoke-DemoSignInSweep -Times 1 -Exactly -ParameterFilter { $Clean -and $IncludeBrowserCache }
        Should -Invoke -CommandName Enable-DemoIeEsc -Times 1 -Exactly

        Mock -CommandName Invoke-DemoSignInSweep -MockWith { [pscustomobject]@{ pass = $false; cleaned = $true; found = $null } }
        { & $step.Set $step } | Should -Throw '*fail closed*'
    }

    It 'blocks both documented IMDS addresses and uses T1''s SQL Server settings without a data disk' {
        $context = New-TestEvalContext
        $context.ImdsAddresses | Should -Be @('169.254.169.254', '169.254.169.253')
        $context.ImdsRuleName | Should -Be 'BlockAzureIMDS'
        $context.MachineName | Should -Be 'arcsql01'
        $context.DataDiskTier | Should -Be 'None'
        $context.Config.Sql.ServiceName | Should -Be 'MSSQLSERVER'
        $context.Guest.Sql.SysAdminAccounts | Should -Be 'BUILTIN\Administrators'
    }

    It 'disables the Azure guest agent only 15 minutes after onboarding' {
        $context = New-TestEvalContext
        $now = [datetime]::new(2026, 10, 20, 12, 0, 0, [System.DateTimeKind]::Utc)
        Mock -CommandName Disable-DemoEvalWindowsService -MockWith { }

        (Disable-DemoEvalGuestAgent -Context $context -Now $now).Outcome | Should -Be 'Waiting'

        Write-TestMarker -Context $context -ConnectedUtc $now.AddMinutes(-10)
        $early = Disable-DemoEvalGuestAgent -Context $context -Now $now
        $early.Outcome | Should -Be 'InProgress'
        $early.Message | Should -Match '^EVALUATION ONLY'
        Should -Invoke -CommandName Disable-DemoEvalWindowsService -Times 0 -Exactly

        Write-TestMarker -Context $context -ConnectedUtc $now.AddMinutes(-20)
        $done = Disable-DemoEvalGuestAgent -Context $context -Now $now
        $done.Outcome | Should -Be 'Done'
        $done.WarningMessage[0] | Should -Match '^EVALUATION ONLY'
        Should -Invoke -CommandName Disable-DemoEvalWindowsService -Times 1 -Exactly -ParameterFilter { $Name -eq 'WindowsAzureGuestAgent' }
    }

    It 'waits for the product key in ProductKey mode' {
        Mock -CommandName Get-DemoProtectedSqlProductKey -MockWith { $null }
        Mock -CommandName Mount-DemoEvalSqlMedia -MockWith { throw 'should not run' }
        $result = Install-DemoEvalSql -Context (New-TestEvalContext -Mode 'ProductKey')
        $result.Outcome | Should -Be 'Waiting'
        $result.WaitState | Should -Be 'WaitingForProductKey'
    }

    It 'shares the nested guest''s setup switches' {
        $arguments = Get-DemoSqlSetupArgument -Sql (New-TestEvalContext).Guest.Sql
        $arguments | Should -Contain '/Q'
        $arguments | Should -Contain '/FEATURES=SQLENGINE'
        $arguments | Should -Contain '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"'
        $arguments | Should -Contain '/IACCEPTSQLSERVERLICENSETERMS'
        ($arguments -join ' ') | Should -Not -Match '/PID'
    }

    It 'creates ContosoCare with the arcsql01 scripts' {
        $script:sqlScripts = [System.Collections.Generic.List[object]]::new()
        Mock -CommandName Invoke-DemoVmSqlScript -MockWith { $script:sqlScripts.Add([pscustomobject]@{ Path = $Path; Database = $Database }) }
        Initialize-DemoEvalArcDatabase -Context (New-TestEvalContext)
        $script:sqlScripts.Count | Should -Be 4
        $script:sqlScripts[0].Path | Should -Match 'arcsql01.000-create-database\.sql$'
        $script:sqlScripts[0].Database | Should -Be 'master'
        $script:sqlScripts[3].Path | Should -Match 'arcsql01.030-configure\.sql$'
        $script:sqlScripts[1..3].Database | Should -Be @('ContosoCare', 'ContosoCare', 'ContosoCare')
    }

    It 'labels the setup-wizard instructions EVALUATION ONLY' {
        $steps = Get-DemoEvalWizardInstruction -MachineName 'arcsql01' -MediaDrive 'E'
        $steps[0] | Should -Match '^EVALUATION ONLY'
        ($steps -join ' ') | Should -Match 'pay-as-you-go'
        ($steps -join ' ') | Should -Match ([regex]::Escape('BUILTIN\Administrators'))
        ($steps -join ' ') | Should -Match ([regex]::Escape('E:\setup.exe'))
    }

    It 'is the script the loader runs for Role EvalArcVm' {
        $loader = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoBootstrapLoader.ps1') -Raw
        $loader | Should -Match ([regex]::Escape("`$Role -eq 'EvalArcVm'"))
        $loader | Should -Match ([regex]::Escape("'Invoke-EvalArcVmBootstrap.ps1'"))
        (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/health/health.schema.json') -Raw | ConvertFrom-Json).properties.role.enum | Should -Contain 'EvalArcVm'
    }
}
