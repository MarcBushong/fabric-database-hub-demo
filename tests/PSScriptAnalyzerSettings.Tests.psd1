@{
    # Settings for Pester test files (*.Tests.ps1). Same as PSScriptAnalyzerSettings.psd1, minus two
    # rules that misfire on Pester's structure:
    # - PSUseDeclaredVarsMoreThanAssignments can't see variables set in BeforeAll or BeforeDiscovery
    #   being used inside It blocks.
    # - PSUseShouldProcessForStateChangingFunctions flags small test helpers (New-TestConfig) that
    #   only build fixtures in TestDrive.
    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Rules               = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.4')
        }
    }
}
