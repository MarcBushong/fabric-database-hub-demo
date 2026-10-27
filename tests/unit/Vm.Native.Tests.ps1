BeforeDiscovery {
    $onWindows = $IsWindows -and $null -ne (Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    $platformPath = Join-Path -Path $PSScriptRoot -ChildPath '../../vm/bootstrap/lib/Platform.ps1'
}

Describe 'Invoke-DemoVmNativeCommand under Windows PowerShell 5.1' -Skip:(-not $onWindows) {
    # Regression test for a live finding (2026-10-20): bcdboot wrote "BFSVC Error: Failed to create a new system
    # store" to stderr while succeeding, and with $ErrorActionPreference = 'Stop' Windows PowerShell 5.1 ended the
    # T2 guest build on that line. These run the real function in powershell.exe with 'Stop' set.
    BeforeAll {
        function Invoke-WindowsPowerShell([string] $Command) {
            $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $Command 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output) -join "`n") }
        }

        function New-NativeCommand([int] $ExitCode) {
            "`$ErrorActionPreference = 'Stop'; . '{0}'; `$r = Invoke-DemoVmNativeCommand -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', 'echo diagnostic 1>&2 & exit /b {1}'); 'EXIT ' + `$r.ExitCode; 'OUT ' + (`$r.Output -join '|'); 'EAP ' + `$ErrorActionPreference; 'PS ' + `$PSVersionTable.PSVersion.Major" -f $platformPath, $ExitCode
        }
    }

    It 'returns exit code 0 and the stderr text when a program succeeds but writes to stderr' {
        $run = Invoke-WindowsPowerShell -Command (New-NativeCommand -ExitCode 0)

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'PS 5'
        $run.Output | Should -Match 'EXIT 0'
        $run.Output | Should -Match 'OUT diagnostic'
    }

    It 'returns a failing exit code without throwing, so the caller decides' {
        $run = Invoke-WindowsPowerShell -Command (New-NativeCommand -ExitCode 3)

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'EXIT 3'
    }

    It 'restores the caller''s error action preference' {
        $run = Invoke-WindowsPowerShell -Command (New-NativeCommand -ExitCode 0)

        $run.Output | Should -Match 'EAP Stop'
    }
}
