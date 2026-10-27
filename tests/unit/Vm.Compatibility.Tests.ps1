BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $settingsPath = Join-Path -Path $repoRoot -ChildPath 'tests/PSScriptAnalyzerSettings.Vm.psd1'
}

Describe 'Windows PowerShell 5.1 compatibility analysis for vm/ (Phase 14)' {
    It 'checks syntax, commands, and types against Windows PowerShell 5.1' {
        $settings = Import-PowerShellDataFile -LiteralPath $settingsPath
        $settings.Rules.PSUseCompatibleSyntax.Enable | Should -BeTrue
        $settings.Rules.PSUseCompatibleSyntax.TargetVersions | Should -Be @('5.1')
        foreach ($rule in 'PSUseCompatibleCommands', 'PSUseCompatibleTypes') {
            $settings.Rules[$rule].Enable | Should -BeTrue
            $settings.Rules[$rule].TargetProfiles | Should -Be @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }

    It 'uses a profile that ships with the pinned PSScriptAnalyzer' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json
        $module = Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object { $_.Version -eq [version]$versions.tools.psscriptanalyzer } | Select-Object -First 1
        if (-not $module) {
            Set-ItResult -Skipped -Because ('PSScriptAnalyzer {0} isn''t installed here; tests/Install-TestTools.ps1 installs it' -f $versions.tools.psscriptanalyzer)
            return
        }
        $settings = Import-PowerShellDataFile -LiteralPath $settingsPath
        foreach ($name in @($settings.Rules.PSUseCompatibleTypes.TargetProfiles)) {
            Test-Path -LiteralPath (Join-Path -Path $module.ModuleBase -ChildPath ('compatibility_profiles/{0}.json' -f $name)) | Should -BeTrue
        }
    }

    It 'every VM-side file that uses the ignored DPAPI types loads System.Security first' {
        $settings = Import-PowerShellDataFile -LiteralPath $settingsPath
        $ignored = @($settings.Rules.PSUseCompatibleTypes.IgnoreTypes)
        $ignored | Should -Not -BeNullOrEmpty
        $offenders = foreach ($file in Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm') -Recurse -File -Include '*.ps1', '*.psm1') {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($type in $ignored) {
                $use = $text.IndexOf(('[{0}]' -f $type), [System.StringComparison]::OrdinalIgnoreCase)
                if ($use -lt 0) {
                    continue
                }
                $load = $text.IndexOf("Add-Type -AssemblyName 'System.Security'", [System.StringComparison]::Ordinal)
                if ($load -lt 0 -or $load -gt $use) {
                    '{0} uses {1} before loading System.Security' -f $file.FullName.Substring($repoRoot.Length), $type
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'is the settings file the static validation uses for vm/' {
        $runner = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'tests/Invoke-StaticValidation.ps1') -Raw
        $runner | Should -Match ([regex]::Escape("'PSScriptAnalyzerSettings.Vm.psd1'"))
        $runner | Should -Match 'vmSettings'
    }
}
