BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/ProtectedValueLog.ps1')
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force

    function New-TestEventRecord {
        param([string] $Text)
        [pscustomobject]@{ Properties = @([pscustomobject]@{ Value = 'Started' }, [pscustomobject]@{ Value = $Text }) }
    }

    # Built at run time, so no scanner sees a key-shaped value in the repository.
    $script:value = (@('Q7W2E', 'R9T4Y', 'U6I8O', 'P3A5S', 'D1F0G') -join '-')
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Clear-DemoProtectedValueLog' {
    It 'clears the Windows PowerShell log when an event holds the exact value, and returns no value' {
        $events = @{ 'Windows PowerShell' = @((New-TestEventRecord -Text ('HostApplication=powershell.exe -File script.ps1 -ProductKey {0}' -f $script:value)), (New-TestEventRecord -Text 'HostApplication=powershell.exe -File other.ps1')) }
        $cleared = [System.Collections.Generic.List[string]]::new()
        $result = Clear-DemoProtectedValueLog -Value $script:value -Reader { param($Name) $events[$Name] }.GetNewClosure() -Clearer { param($Name) $cleared.Add($Name) }.GetNewClosure()
        $result.found | Should -Be 1
        $result.cleared | Should -BeTrue
        @($cleared) | Should -Be @('Windows PowerShell')
        ($result | ConvertTo-Json) | Should -Not -Match ([regex]::Escape($script:value))
    }

    It 'leaves the log alone when no event holds the value, or there''s no value' {
        $cleared = [System.Collections.Generic.List[string]]::new()
        $reader = { param($Name) $null = $Name; @(New-TestEventRecord -Text 'HostApplication=powershell.exe -File script.ps1 -ProductKey [hidden]') }
        $none = Clear-DemoProtectedValueLog -Value $script:value -Reader $reader -Clearer { param($Name) $cleared.Add($Name) }.GetNewClosure()
        $none.found | Should -Be 0
        $none.cleared | Should -BeFalse
        (Clear-DemoProtectedValueLog -Value '' -Reader $reader -Clearer { param($Name) $cleared.Add($Name) }.GetNewClosure()).cleared | Should -BeFalse
        $cleared.Count | Should -Be 0
    }

    It 'never reads or clears the Security log' {
        $read = [System.Collections.Generic.List[string]]::new()
        $records = @(New-TestEventRecord -Text $script:value)
        $result = Clear-DemoProtectedValueLog -Value $script:value -LogName 'Security' -Reader { param($Name) $read.Add($Name); $records }.GetNewClosure() -Clearer { param($Name) throw ('must not clear ' + $Name) }
        $result.cleared | Should -BeFalse
        $read.Count | Should -Be 0
    }

    It 'reports a failed clearing by its error type, without the value' {
        $records = @(New-TestEventRecord -Text ('-ProductKey {0}' -f $script:value))
        $result = Clear-DemoProtectedValueLog -Value $script:value -Reader { param($Name) $null = $Name; $records }.GetNewClosure() -Clearer { param($Name) throw [System.UnauthorizedAccessException]::new(('denied for ' + $Name)) }
        $result.found | Should -Be 1
        $result.cleared | Should -BeFalse
        $result.error | Should -Be 'UnauthorizedAccessException'
    }
}

Describe 'Disable-DemoSessionEventLog' {
    It 'turns off the session''s engine and provider events, which would repeat the command line' {
        $names = 'LogEngineLifecycleEvent', 'LogProviderLifecycleEvent', 'LogEngineHealthEvent', 'LogProviderHealthEvent'
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = Get-Variable -Name $name -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
        try {
            Disable-DemoSessionEventLog
            foreach ($name in $names) {
                Get-Variable -Name $name -Scope Global -ValueOnly | Should -BeFalse -Because $name
            }
        }
        finally {
            foreach ($name in $names) {
                if ($null -eq $saved[$name]) { Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue } else { Set-Variable -Name $name -Value $saved[$name] -Scope Global }
            }
        }
    }
}

Describe 'Add-DemoProtectedValueLogHelper' {
    It 'inserts the helpers right after the param block, so the script still parses and calls them after use' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Set-DemoSqlProductKey.ps1') -Raw
        $sent = InModuleScope DbHubDemo -Parameters @{ Text = $text } { param($Text) Add-DemoProtectedValueLogHelper -ScriptText $Text }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($sent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $ast.ParamBlock | Should -Not -BeNullOrEmpty -Because 'the param block stays first'
        $functions = @($ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name })
        $functions | Should -Contain 'Clear-DemoProtectedValueLog'
        $functions | Should -Contain 'Disable-DemoSessionEventLog'
        $sent.IndexOf('function Clear-DemoProtectedValueLog') | Should -BeGreaterThan $ast.ParamBlock.Extent.EndOffset
        $sent.IndexOf('Disable-DemoSessionEventLog' + "`n" + '$exitCode') | Should -BeGreaterThan $sent.IndexOf('function Disable-DemoSessionEventLog') -Because 'the session''s events are off before the key is used'
        $sent | Should -Match ([regex]::Escape('Clear-DemoProtectedValueLog -Value $ProductKey'))
        $sent | Should -Match ([regex]::Escape("'DBHUBDEMO-LOG found={0} cleared={1} error={2}'"))
    }

    It 'puts the helpers first in a script without a param block' {
        $sent = InModuleScope DbHubDemo { Add-DemoProtectedValueLogHelper -ScriptText "'hello'" }
        $sent.TrimStart().StartsWith('function Disable-DemoSessionEventLog') | Should -BeTrue
        $sent.TrimEnd().EndsWith("'hello'") | Should -BeTrue
    }

    It 'reads the script''s report line: found, cleared, and the error''s type' {
        $read = InModuleScope DbHubDemo { Get-DemoProtectedValueLogResult -Output ("stored`nDBHUBDEMO-LOG found=2 cleared=True error=`n") }
        $read.Reported | Should -BeTrue
        $read.Found | Should -Be 2
        $read.Cleared | Should -BeTrue
        $missing = InModuleScope DbHubDemo { Get-DemoProtectedValueLogResult -Output 'stored' }
        $missing.Reported | Should -BeFalse
        $missing.Found | Should -Be 0
    }
}