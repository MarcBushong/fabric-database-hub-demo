#Requires -Version 7.4
# The harness's marks (ADR 0031, the sidecar's leave-out; rca/README.md, What the capture leaves out): each control
# script marks exactly the modules it creates, no other script marks anything, and PostgreSQL's harness-only tables are
# the ones the leave-out expects.

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $databaseRoot = Join-Path -Path $repoRoot -ChildPath 'database'
    $sqlServerControl = Join-Path -Path $databaseRoot -ChildPath 'common/110-demo-control.sql'
    $postgresControl = Join-Path -Path $databaseRoot -ChildPath 'postgresql/110-demo-control.sql'
    $postgresScenarios = Join-Path -Path $databaseRoot -ChildPath 'postgresql/120-scenario-functions.sql'
    $sqlServerScenarios = Join-Path -Path $databaseRoot -ChildPath 'common/120-scenario-procedures.sql'
    $marker = '-- The harness''s marks'

    function Remove-SqlComment {
        param([string] $Text)
        return (($Text -replace '(?s)/\*.*?\*/', ' ') -replace '--[^\r\n]*', ' ')
    }

    function Get-MarkBlock {
        param([string] $Text)
        $at = $Text.IndexOf($marker, [System.StringComparison]::Ordinal)
        if ($at -lt 0) { return '' }
        return $Text.Substring($at)
    }

    function Get-SqlServerMarked {
        param([string] $Text)
        $list = [regex]::Match((Get-MarkBlock -Text $Text), '(?s)INSERT\s+INTO\s+@harness\s*\(module_name\)\s*VALUES(.*?);').Groups[1].Value
        return @([regex]::Matches($list, "N'(\w+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }

    function Get-PostgresMarked {
        param([string] $Text)
        $array = [regex]::Match((Get-MarkBlock -Text $Text), '(?s)ARRAY\[(.*?)\]').Groups[1].Value
        return @([regex]::Matches($array, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }

    function Get-SqlServerModule {
        param([string] $Text)
        return @([regex]::Matches((Remove-SqlComment -Text $Text), '(?i)\bCREATE\s+(?:OR\s+ALTER\s+)?(?:PROCEDURE|PROC|FUNCTION)\s+(?:\[?demo\]?\.)\[?(\w+)\]?') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }

    function Get-PostgresRoutine {
        param([string] $Text)
        return @([regex]::Matches((Remove-SqlComment -Text $Text), '(?i)\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\s+demo\.(\w+)') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }

    # Any schema, as schema.name: the scenario modules live in the application schemas (ADR 0031, decision 6).
    function Get-SqlServerQualifiedModule {
        param([string] $Text)
        return @([regex]::Matches((Remove-SqlComment -Text $Text), '(?i)\bCREATE\s+(?:OR\s+ALTER\s+)?(?:PROCEDURE|PROC|FUNCTION)\s+\[?(\w+)\]?\.\[?(\w+)\]?') |
                ForEach-Object { '{0}.{1}' -f $_.Groups[1].Value.ToLowerInvariant(), $_.Groups[2].Value } | Sort-Object -Unique)
    }

    function Get-PostgresQualifiedRoutine {
        param([string] $Text)
        return @([regex]::Matches((Remove-SqlComment -Text $Text), '(?i)\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\s+(\w+)\.(\w+)') |
                ForEach-Object { '{0}.{1}' -f $_.Groups[1].Value.ToLowerInvariant(), $_.Groups[2].Value } | Sort-Object -Unique)
    }

    function Get-WrittenTable {
        param([string] $Text)
        return @([regex]::Matches((Remove-SqlComment -Text $Text), '(?i)\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|TRUNCATE(?:\s+TABLE)?|MERGE\s+INTO)\s+([a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*)') |
                ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
    }

    $sqlServerText = [System.IO.File]::ReadAllText($sqlServerControl)
    $postgresText = [System.IO.File]::ReadAllText($postgresControl)
}

Describe 'The harness''s marks (ADR 0031, the sidecar''s leave-out)' {
    It 'marks every module the SQL Server control script creates, and nothing else' {
        $before = $sqlServerText.Substring(0, [Math]::Max(0, $sqlServerText.IndexOf($marker, [System.StringComparison]::Ordinal)))
        $created = Get-SqlServerModule -Text $before
        $marked = Get-SqlServerMarked -Text $sqlServerText
        $created.Count | Should -BeGreaterThan 10
        $marked | Should -Be $created
    }

    It 'marks every routine the PostgreSQL control script creates, and nothing else' {
        $before = $postgresText.Substring(0, [Math]::Max(0, $postgresText.IndexOf($marker, [System.StringComparison]::Ordinal)))
        $created = Get-PostgresRoutine -Text $before
        $array = [regex]::Match((Get-MarkBlock -Text $postgresText), '(?s)ARRAY\[(.*?)\]').Groups[1].Value
        $marked = @([regex]::Matches($array, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $created.Count | Should -BeGreaterThan 5
        $marked | Should -Be $created
    }

    It 'leaves the marks to the two control scripts: no other database script sets one' {
        $others = Get-ChildItem -LiteralPath $databaseRoot -Recurse -File -Filter '*.sql' |
            Where-Object { $_.FullName -ne $sqlServerControl -and $_.FullName -ne $postgresControl }
        foreach ($file in $others) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $text.Contains('dbhubdemo.role') | Should -BeFalse -Because $file.Name
            $text.Contains('dbhubdemo:harness') | Should -BeFalse -Because $file.Name
        }
    }

    It 'marks no scenario module on either engine' {
        # Every module the scenario scripts create, in any schema: none may be one the marks reach (demo.<a listed name>),
        # nor share a listed name, since RCA-PG-16 lists a marked routine by its name alone.
        $sqlServerMarked = Get-SqlServerMarked -Text $sqlServerText
        $sqlServerModules = Get-SqlServerQualifiedModule -Text ([System.IO.File]::ReadAllText($sqlServerScenarios))
        $sqlServerModules.Count | Should -Be 26
        foreach ($module in $sqlServerModules) { $module.Split('.')[1] | Should -Not -BeIn $sqlServerMarked -Because $module }
        $postgresMarked = Get-PostgresMarked -Text $postgresText
        $postgresRoutines = Get-PostgresQualifiedRoutine -Text ([System.IO.File]::ReadAllText($postgresScenarios))
        $postgresRoutines.Count | Should -Be 16
        foreach ($routine in $postgresRoutines) { $routine.Split('.')[1] | Should -Not -BeIn $postgresMarked -Because $routine }
    }

    It 'leaves PostgreSQL exactly the harness-only tables the leave-out expects' {
        # RCA-PG-16 counts a table as the harness's when only marked routines write it, and RCA-PG-14 then leaves out a
        # statement that touches only such tables. A new one changes what the evidence keeps, so it's reviewed here.
        $harnessWrites = Get-WrittenTable -Text $postgresText
        $scenarioWrites = Get-WrittenTable -Text ([System.IO.File]::ReadAllText($postgresScenarios))
        @($harnessWrites | Where-Object { $_ -notin $scenarioWrites }) | Should -Be @('demo.scenario_control', 'demo.scenario_run_events', 'demo.scenario_runs')
    }
}
