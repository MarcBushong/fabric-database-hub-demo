@{
    # Settings for VM-side scripts under vm/ (ADR 0003). They run on Windows PowerShell 5.1 on the VMs, so the
    # three compatibility rules target 5.1: PSUseCompatibleSyntax (no ternary or null-coalescing operators, no
    # pipeline chain operators), and PSUseCompatibleCommands and PSUseCompatibleTypes against the profile that
    # PSScriptAnalyzer ships for Windows PowerShell 5.1 on Windows Server 2019 Datacenter. No Windows Server
    # 2022 profile ships; the VMs run Windows Server 2022, with the same Windows PowerShell 5.1 (Phase 14).
    # Profiles: https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/rules/usecompatibletypes
    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true
    Rules               = @{
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
            # DPAPI lives in System.Security.dll, which Windows PowerShell 5.1 doesn't load by default. Every
            # script that uses these types runs Add-Type -AssemblyName 'System.Security' first, which the rule
            # can't see; tests/unit/Vm.Compatibility.Tests.ps1 enforces that.
            IgnoreTypes    = @(
                'System.Security.Cryptography.ProtectedData'
                'System.Security.Cryptography.DataProtectionScope'
            )
        }
    }
}
