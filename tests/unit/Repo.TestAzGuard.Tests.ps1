BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $repoRoot -ChildPath 'tests/TestAzGuard.ps1')
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'The unit tests'' guard against the Azure CLI (2026-11-16)' {
    It 'stops a test that reaches the Azure CLI at once, lists the call, and never uses a sign-in' {
        $pathBefore = $env:PATH
        $configBefore = $env:AZURE_CONFIG_DIR
        $guard = Enable-DemoTestAzGuard
        try {
            $env:AZURE_CONFIG_DIR | Should -Not -Be $configBefore
            @(Get-ChildItem -LiteralPath $env:AZURE_CONFIG_DIR -Force).Count | Should -Be 0 -Because 'an empty folder holds no sign-in'
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $result = InModuleScope DbHubDemo { Invoke-DemoAzCli -ArgumentList @('account', 'show', '--output', 'json') }
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 30
            $result.ExitCode | Should -Be 97
            $result.StdErr | Should -Match 'DBHUB TEST GUARD: a unit test reached the Azure CLI'
            $through = InModuleScope DbHubDemo { Invoke-DemoAz -SubscriptionId '11111111-2222-3333-4444-555555555555' -ArgumentList @('group', 'exists', '--name', 'rg-dbhub-demo') -AllowFailure }
            $through.ExitCode | Should -Be 97
            $leaks = @(Get-DemoTestAzLeak -State $guard)
            $leaks.Count | Should -Be 2
            $leaks[0] | Should -Match '^az account show --output json$'
            $leaks[1] | Should -Match '^az group exists --name rg-dbhub-demo --subscription 11111111-2222-3333-4444-555555555555'
        }
        finally {
            Disable-DemoTestAzGuard -State $guard
        }
        $env:PATH | Should -Be $pathBefore
        $env:AZURE_CONFIG_DIR | Should -Be $configBefore
        Test-Path -LiteralPath $guard.Root | Should -BeFalse
    }

    It 'is on around every Pester run of the static validation, which fails on any call it lists' {
        $validation = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'tests/Invoke-StaticValidation.ps1') -Raw
        $validation | Should -Match '(?s)\$azGuard = Enable-DemoTestAzGuard\s+try \{\s+\$run = Invoke-Pester -Configuration \$configuration'
        $validation | Should -Match "Add-StaticResult -CheckId 'STATIC\.PESTER\.AZURECLI' -Status 'Fail'"
    }
}
