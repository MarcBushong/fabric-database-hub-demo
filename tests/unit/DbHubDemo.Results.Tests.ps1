BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    $schemaPath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/schemas/validation-result.schema.json'
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'New-DemoResult' {
    BeforeEach {
        Clear-DemoSecret
    }

    It 'creates a record that matches the validation-result schema' {
        $result = New-DemoResult -CheckId 'T2.ARC.CONNECTED' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'Arc machine is Connected.' -Evidence @{ version = '1.1.2504.99' }
        Test-Json -Json ($result | ConvertTo-Json -Depth 8) -SchemaFile $schemaPath | Should -BeTrue
    }

    It 'rejects a status outside the six defined statuses' {
        { New-DemoResult -CheckId 'T1.X.Y' -Area 't1' -Target 'T1' -Status 'OK' -Message 'm' } | Should -Throw
    }

    It 'rejects a malformed check ID' {
        { New-DemoResult -CheckId 'lowercase' -Area 't1' -Target 'T1' -Status 'Pass' -Message 'm' } | Should -Throw
    }

    It 'labels evaluation-only results' {
        $result = New-DemoResult -CheckId 'T2.ARC.CONNECTED' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'Arc machine is Connected.' -EvaluationOnly
        $result.message | Should -BeLike 'EVALUATION ONLY: *'
        $result.evaluationOnly | Should -BeTrue
    }

    It 'redacts the message, evidence, and remediation' {
        Register-DemoSecret -Value 'SecretEvidence42'
        $result = New-DemoResult -CheckId 'T1.X.Y' -Area 't1' -Target 'T1' -Status 'Warning' -Message 'saw SecretEvidence42' -Evidence @{ note = 'has SecretEvidence42' } -Remediation 'rotate SecretEvidence42'
        $result.message | Should -Be 'saw [REDACTED]'
        $result.evidence.note | Should -Be 'has [REDACTED]'
        $result.remediation | Should -Be 'rotate [REDACTED]'
    }

    It 'uses the same statuses, areas, and targets as the schema' {
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
        $command = Get-Command -Name New-DemoResult
        foreach ($name in 'status', 'area', 'target') {
            $parameter = $command.Parameters[(Get-Culture).TextInfo.ToTitleCase($name)]
            $validValues = ($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues
            ($validValues | Sort-Object) | Should -Be ($schema.properties[$name].enum | Sort-Object)
        }
    }
}

Describe 'Get-DemoExitCode' {
    BeforeAll {
        function New-TestResult([string] $Status) {
            New-DemoResult -CheckId 'STATIC.TEST' -Area 'static' -Target 'repo' -Status $Status -Message 'test'
        }
    }

    It 'returns 0 for an empty set' {
        Get-DemoExitCode -Result @() | Should -Be 0
    }

    It 'returns 0 when nothing failed' {
        Get-DemoExitCode -Result @((New-TestResult 'Pass'), (New-TestResult 'Warning'), (New-TestResult 'Not selected')) | Should -Be 0
    }

    It 'returns 1 when any check failed' {
        Get-DemoExitCode -Result @((New-TestResult 'Pass'), (New-TestResult 'Fail'), (New-TestResult 'Manual action required')) | Should -Be 1
    }

    It 'returns 2 for manual items only with -TreatManualAsError' {
        $results = @((New-TestResult 'Pass'), (New-TestResult 'Manual action required'))
        Get-DemoExitCode -Result $results | Should -Be 0
        Get-DemoExitCode -Result $results -TreatManualAsError | Should -Be 2
    }
}

Describe 'Export-DemoResult' {
    It 'writes one schema-valid JSON line per result' {
        $path = Join-Path -Path $TestDrive -ChildPath 'out/results.jsonl'
        $results = @(
            New-DemoResult -CheckId 'STATIC.ONE' -Area 'static' -Target 'repo' -Status 'Pass' -Message 'one'
            New-DemoResult -CheckId 'STATIC.TWO' -Area 'static' -Target 'repo' -Status 'Fail' -Message 'two'
        )
        Export-DemoResult -Result $results -Path $path
        $lines = Get-Content -LiteralPath $path
        $lines.Count | Should -Be 2
        foreach ($line in $lines) {
            Test-Json -Json $line -SchemaFile $schemaPath | Should -BeTrue
        }
    }
}
