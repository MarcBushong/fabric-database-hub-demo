@{
    # Error and Warning findings fail CI. Information findings are advisory.
    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true
    Rules               = @{
        # Operator-side scripts target PowerShell 7.4. VM-side scripts under vm/ use
        # PSScriptAnalyzerSettings.Vm.psd1, which targets Windows PowerShell 5.1.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.4')
        }
    }
}
