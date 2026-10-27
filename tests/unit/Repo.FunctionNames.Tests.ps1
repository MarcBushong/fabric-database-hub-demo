BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))

    function Get-TestTopLevelFunction {
        # Top-level function definitions in each file. Functions nested in other functions are local to them.
        param([string[]] $Path)

        foreach ($file in $Path) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
            foreach ($statement in @($ast.EndBlock.Statements)) {
                if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    [pscustomobject]@{ Name = $statement.Name; File = [System.IO.Path]::GetFileName($file) }
                }
            }
        }
    }

    function Get-TestDuplicateFunction {
        param([object[]] $Function)

        @($Function | Group-Object -Property Name | Where-Object -Property Count -GT -Value 1 | ForEach-Object {
                '{0} ({1})' -f $_.Name, (($_.Group | ForEach-Object { $_.File }) -join ', ')
            })
    }
}

Describe 'Function names' {
    # Dot-sourced files share one scope, so a second definition silently replaces the first. Live finding
    # (2026-10-20): Phase 5's Get-DemoArmResource (PolicyHelpers.ps1) replaced Phase 7's (ArcHelpers.ps1),
    # and the Arc and SQL VM inventory reads got the policy reader's wrapper object instead of the resource.

    It 'defines each DbHubDemo module function once' {
        $files = @(foreach ($folder in 'Private', 'Public') {
                Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath ('scripts/modules/DbHubDemo/' + $folder)) -Filter '*.ps1' -File |
                    ForEach-Object { $_.FullName }
            })
        $functions = @(Get-TestTopLevelFunction -Path $files)
        $functions.Count | Should -BeGreaterThan 0
        Get-TestDuplicateFunction -Function $functions | Should -BeNullOrEmpty
    }

    It 'defines each function the T2 host bootstrap loads once' {
        # DbHubDemo.Vm's library, the host's own scripts, and the guest scripts it dot-sources.
        $files = @(
            Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/lib') -Filter '*.ps1' -File | ForEach-Object { $_.FullName }
            foreach ($name in 'HostPlatform.ps1', 'HostSteps.ps1', 'Invoke-HostBootstrap.ps1', 'Invoke-DemoSignInResidue.ps1') {
                Join-Path -Path $repoRoot -ChildPath ('vm/bootstrap/' + $name)
            }
            Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/hyperv-guest') -Filter '*.ps1' -File | ForEach-Object { $_.FullName }
        )
        $functions = @(Get-TestTopLevelFunction -Path $files)
        $functions.Count | Should -BeGreaterThan 0
        Get-TestDuplicateFunction -Function $functions | Should -BeNullOrEmpty
    }
}
