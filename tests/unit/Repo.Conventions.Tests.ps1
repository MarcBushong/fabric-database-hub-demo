BeforeDiscovery {
    $repoRootForDiscovery = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $notebookFiles = @(Get-ChildItem -Path (Join-Path -Path $repoRootForDiscovery -ChildPath 'fabric/notebooks') -Filter '*.ipynb' -File -ErrorAction SilentlyContinue |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $excluded = '[\\/](\.git|node_modules|bin|obj|out|TestResults)[\\/]'

    # Check only what Git would commit: tracked files plus untracked files that .gitignore doesn't exclude.
    # Operator-local files such as config/demo.config.json are ignored by design and may hold real IDs.
    $gitVisibleFiles = $null
    $gitFiles = @(git -C $repoRoot ls-files --cached --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -eq 0 -and $gitFiles.Count -gt 0) {
        $gitVisibleFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $gitFiles) {
            [void]$gitVisibleFiles.Add([System.IO.Path]::GetFullPath((Join-Path -Path $repoRoot -ChildPath $file)))
        }
    }

    function Get-RepoFile {
        param([string[]] $Include)
        Get-ChildItem -Path $repoRoot -Recurse -File -Include $Include -Force |
            Where-Object { $_.FullName -notmatch $excluded -and ($null -eq $gitVisibleFiles -or $gitVisibleFiles.Contains($_.FullName)) }
    }

    function Test-FakeGuid {
        param([string] $Guid)
        # A GUID is an obvious placeholder when every group repeats a single character.
        foreach ($group in $Guid.Split('-')) {
            if (@($group.ToCharArray() | Select-Object -Unique).Count -ne 1) {
                return $false
            }
        }
        return $true
    }
}

Describe 'Repository layout' {
    It 'has the directory <_>' -ForEach @(
        'docs/adr', 'infra/modules', 'config', 'scripts/modules/DbHubDemo',
        'vm/bootstrap', 'vm/dsc', 'vm/health', 'vm/hyperv-guest',
        'database/common', 'database/sqlvm01', 'database/arcsql01', 'database/azuresql',
        'scenarios/healthy-baseline', 'scenarios/locking-blocking', 'scenarios/cpu-pressure',
        'scenarios/io-pressure', 'scenarios/inefficient-query', 'scenarios/missing-index',
        'workload-generator/src', 'workload-generator/tests',
        'fabric/notebooks', 'fabric/agent', 'fabric/connections',
        'tests/unit', 'tests/integration', 'tests/smoke', 'tests/teardown',
        '.github/workflows', '.github/ISSUE_TEMPLATE'
    ) {
        Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $_) -PathType Container | Should -BeTrue
    }

    It 'has the file <_>' -ForEach @(
        'README.md', 'LICENSE', 'SECURITY.md', 'CONTRIBUTING.md', 'CHANGELOG.md', 'CODE_OF_CONDUCT.md',
        'config/environment.schema.json', 'config/demo.config.example.json', 'config/versions.json',
        'workload-generator/Dockerfile', 'workload-generator/README.md', 'fabric/README.md',
        '.github/copilot-instructions.md', '.github/dependabot.yml', 'AGENTS.md',
        '.github/workflows/validate.yml', '.github/workflows/deploy.yml', '.github/workflows/demo-control.yml', '.github/workflows/destroy.yml'
    ) {
        Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $_) -PathType Leaf | Should -BeTrue
    }

    It 'tells an AI agent to set the demo up with init.ps1 and deploy.ps1, never by hand, and to report DONE or NOT DONE (2026-11-09)' {
        $agents = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'AGENTS.md') -Raw
        foreach ($phrase in './scripts/init.ps1', './scripts/deploy.ps1', "Don't assemble a partial setup by hand", "Don't leave a target out on your own", 'T4 (PostgreSQL)', '**NOT DONE**', 'az login', './scripts/estimate-cost.ps1', 'no setup wizard') {
            $agents | Should -BeLike ('*{0}*' -f $phrase) -Because $phrase
        }
        Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath '.github/copilot-instructions.md') -Raw | Should -Match '\[AGENTS\.md\]\(\.\./AGENTS\.md\)'
    }

    It 'has the script scripts/<_>.ps1 with #Requires and comment-based help' -ForEach @(
        'init', 'deploy', 'preflight', 'configure-fabric', 'configure-powerbi', 'configure-fabric-app', 'configure-arc', 'configure-monitoring', 'validate',
        'start-demo', 'stop-demo', 'reset-demo', 'status', 'estimate-cost', 'destroy', 'setup-github-oidc', 'setup-github-repo', 'setup-activity-control',
        'grant-safety-stop', 'collect-diagnostics'
    ) {
        $path = Join-Path -Path $repoRoot -ChildPath "scripts/$_.ps1"
        Test-Path -LiteralPath $path | Should -BeTrue
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.4'
        $text | Should -Match '\.SYNOPSIS'
    }
}

Describe 'Entry scripts load this checkout''s DbHubDemo on every run (live finding, 2026-11-06)' {
    # Live: deploy.ps1 -Resume, run again in the terminal of an earlier run after a pull, reused the DbHubDemo that the
    # earlier run had loaded (its import skipped a module already loaded), so the run's own code was the old one: it never
    # checked the changed bootstrap bundle. The track processes, which import the module themselves, ran the new code.
    BeforeAll {
        $script:entryScripts = @(Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'scripts') -Filter '*.ps1' -File |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw).Contains('modules/DbHubDemo/DbHubDemo.psd1') })
        $script:entryLines = @(
            '$entryRepoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath ''..'')).TrimEnd(''\'', ''/'') + [System.IO.Path]::DirectorySeparatorChar'
            '$entryNested = $false'
            'foreach ($entryFrame in @(Get-PSCallStack | Select-Object -Skip 1)) {'
            '    $entryNested = $entryNested -or [bool]($entryFrame.ScriptName -and $entryFrame.ScriptName.StartsWith($entryRepoRoot, [System.StringComparison]::OrdinalIgnoreCase))'
            '}'
            'Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath ''modules/DbHubDemo/DbHubDemo.psd1'') -Force:(-not $entryNested)'
        ) -join "`n"
        # The same lines for a script that runs code in the module's scope (& $module { ... }): it keeps the module object it
        # imported (live finding, 2026-11-10).
        $script:entryLinesModule = $script:entryLines.Replace("`nImport-Module -Name", "`n`$module = Import-Module -Name") + ' -PassThru'
        # Get-Module -Name 'DbHubDemo' (or Get-Command -Module DbHubDemo): every checkout's copy that the session loaded.
        $script:isNameLookup = {
            param($Node)
            $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -in 'Get-Module', 'gmo', 'Get-Command', 'gcm' -and
            @($Node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -eq 'DbHubDemo' }).Count -gt 0 -and
            ($Node.GetCommandName() -in 'Get-Module', 'gmo' -or @($Node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Module' }).Count -gt 0)
        }
        # & <target> { ... }: code that runs in a module's scope.
        $script:isModuleCall = {
            param($Node)
            $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
            $Node.CommandElements.Count -ge 2 -and $Node.CommandElements[1] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
        }
    }

    It 'finds the entry scripts that import DbHubDemo' {
        $script:entryScripts.Count | Should -BeGreaterOrEqual 20
        @($script:entryScripts | ForEach-Object { $_.Name }) | Should -Contain 'deploy.ps1'
    }

    It 'imports it with -Force unless the repository''s own code runs the script, and never reuses a module that''s loaded already' {
        $wrong = foreach ($file in $script:entryScripts) {
            $text = (Get-Content -LiteralPath $file.FullName -Raw) -replace "`r`n", "`n"
            $imports = @([regex]::Matches($text, '(?m)^.*Import-Module\b.*DbHubDemo\.psd1.*$') | ForEach-Object { $_.Value.Trim() })
            if (-not ($text.Contains($script:entryLines) -or $text.Contains($script:entryLinesModule))) {
                '{0}: lacks the shared lines that load the module again' -f $file.Name
            }
            if ($imports.Count -ne 1 -or $imports[0] -notmatch '-Force:\(-not \$entryNested\)( -PassThru)?$') {
                '{0}: imports DbHubDemo {1} time(s), not once with -Force:(-not $entryNested)' -f $file.Name, $imports.Count
            }
            if ($text -match "if \(-not \(Get-Module -Name 'DbHubDemo'\)\)") {
                '{0}: reuses a DbHubDemo that''s loaded already' -f $file.Name
            }
        }
        $wrong | Should -BeNullOrEmpty
    }

    It 'never looks DbHubDemo up by name in an entry script or a tool, since that finds every checkout''s copy that the session loaded (live finding, 2026-11-10)' {
        # Live: start-demo.ps1 -WarmUpMinutes 10, in a window that had imported DbHubDemo from three clones, crashed after
        # the environment had started: "The term 'DbHubDemo DbHubDemo DbHubDemo' is not recognized", since
        # Get-Module -Name 'DbHubDemo' returned all three and & $module { ... } got the array.
        $tools = @(Get-RepoFile -Include '*.ps1' | Where-Object { $_.FullName.StartsWith((Join-Path -Path $repoRoot -ChildPath 'tests'), [System.StringComparison]::OrdinalIgnoreCase) -and $_.FullName -notmatch '[\\/]tests[\\/]unit[\\/]' })
        $tools.Count | Should -BeGreaterThan 0
        $found = foreach ($file in @($script:entryScripts) + $tools) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($node in $ast.FindAll($script:isNameLookup, $true)) {
                '{0}:{1}: {2}' -f $file.FullName.Substring($repoRoot.Length), $node.Extent.StartLineNumber, $node.Extent.Text
            }
        }
        $found | Should -BeNullOrEmpty -Because 'the module object comes from Import-Module -PassThru, and commands resolve to the copy the script imported last'
    }

    It 'runs code in the module''s scope only through the module object it imported (live finding, 2026-11-10)' {
        $wrong = foreach ($file in $script:entryScripts) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $calls = @($ast.FindAll($script:isModuleCall, $true))
            if ($calls.Count -eq 0) {
                continue
            }
            foreach ($call in $calls) {
                $target = $call.CommandElements[0]
                if ($target -isnot [System.Management.Automation.Language.VariableExpressionAst] -or $target.VariablePath.UserPath -ne 'module') {
                    '{0}:{1}: runs module code through {2}, not $module' -f $file.Name, $call.Extent.StartLineNumber, $target.Extent.Text
                }
            }
            $assignments = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'module' }, $true))
            if ($assignments.Count -ne 1 -or $assignments[0].Right.Extent.Text -notmatch '^Import-Module -Name .*DbHubDemo\.psd1.* -PassThru$') {
                '{0}: $module is assigned {1} time(s), not once from its own Import-Module -PassThru' -f $file.Name, $assignments.Count
            }
        }
        $wrong | Should -BeNullOrEmpty
        @($script:entryScripts | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw).Contains('& $module {') } | ForEach-Object { $_.Name }) | Should -Contain 'start-demo.ps1'
    }

    It 'looks DbHubDemo up by name only in a job''s own process or runspace, after importing it there (live finding, 2026-11-10)' {
        # A Start-Job process or a Start-ThreadJob runspace has only the copy it imported by path, from the module's own
        # checkout ($script:RepoRoot), so Get-Module -Name 'DbHubDemo' finds exactly that one there.
        $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo'
        $checked = 0
        $wrong = foreach ($file in Get-ChildItem -LiteralPath $moduleRoot -Recurse -Include '*.ps1', '*.psm1' -File -Force) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($lookup in $ast.FindAll($script:isNameLookup, $true)) {
                $checked++
                $where = '{0}:{1}' -f $file.FullName.Substring($repoRoot.Length), $lookup.Extent.StartLineNumber
                $block = $lookup.Parent
                while ($null -ne $block -and $block -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $block = $block.Parent
                }
                $assignment = if ($null -ne $block -and $null -ne $block.Parent) { $block.Parent.Parent } else { $null }
                if ($assignment -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or $assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                    '{0}: not in a scriptblock assigned to a variable' -f $where
                    continue
                }
                $name = $assignment.Left.VariablePath.UserPath
                $function = $assignment.Parent
                while ($null -ne $function -and $function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $function = $function.Parent
                }
                $starts = @(if ($null -ne $function) {
                        $function.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Start-Job', 'Start-ThreadJob' }, $true) | Where-Object {
                            $elements = @($_.CommandElements)
                            $at = [array]::FindIndex($elements, [System.Predicate[object]] { param($e) $e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'ScriptBlock' })
                            $at -ge 0 -and $at + 1 -lt $elements.Count -and $elements[$at + 1] -is [System.Management.Automation.Language.VariableExpressionAst] -and $elements[$at + 1].VariablePath.UserPath -eq $name
                        }
                    })
                if ($starts.Count -eq 0) {
                    '{0}: ${1} isn''t started with Start-Job or Start-ThreadJob -ScriptBlock in the same function' -f $where, $name
                }
                $imported = @($block.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' }, $true) | Where-Object { $_.Extent.StartOffset -lt $lookup.Extent.StartOffset })
                if ($imported.Count -eq 0) {
                    '{0}: the job doesn''t import the module before it looks it up' -f $where
                }
            }
        }
        $wrong | Should -BeNullOrEmpty
        $checked | Should -BeGreaterThan 0 -Because 'the track, build, policy, monitoring, and status page jobs look it up'
    }

    It 'uses the copy it imported in a session that loaded DbHubDemo from another checkout too, top-level or nested (live finding, 2026-11-10)' {
        # Two copies of the module under the test drive, as two checkouts. The child process loads the "two" copy, then the
        # "one" copy, last, as a window that ran scripts from both. Then each entry script's own selection runs from "two"'s
        # scripts folder: the statement that imports DbHubDemo, the statements that assign the variables it runs module code
        # through, and those targets (& <target> { ... }), taken from the script's text; first as a run from a terminal,
        # then as the repository's own code runs it ($entryNested).
        $pwsh = (Get-Process -Id $PID).Path
        $source = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo'
        foreach ($checkout in 'one', 'two') {
            $modules = Join-Path -Path $TestDrive -ChildPath ('{0}/scripts/modules' -f $checkout)
            $null = New-Item -ItemType Directory -Path $modules -Force
            Copy-Item -LiteralPath $source -Destination $modules -Recurse -Force
        }
        $scriptsTwo = Join-Path -Path $TestDrive -ChildPath 'two/scripts'
        $probes = [ordered]@{}
        foreach ($file in $script:entryScripts) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $import = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' -and $n.Extent.Text.Contains('DbHubDemo.psd1') }, $true)
            $statement = $import.Parent
            if ($statement.Parent -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                $statement = $statement.Parent
            }
            $targets = @($ast.FindAll($script:isModuleCall, $true) | ForEach-Object { $_.CommandElements[0] } | Group-Object -Property { $_.Extent.Text } | ForEach-Object { $_.Group[0] })
            $variables = @($targets | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] } | ForEach-Object { $_.VariablePath.UserPath })
            $assignments = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -in $variables }, $true) |
                    Where-Object { $_.Extent.StartOffset -ne $statement.Extent.StartOffset } | ForEach-Object { $_.Extent.Text })
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add('$entryNested = $Nested')
            $lines.Add($statement.Extent.Text)
            $lines.AddRange([string[]]$assignments)
            foreach ($target in $targets) {
                $text = $target.Extent.Text
                $lines.Add(('$found = @({0})' -f $text))
                $lines.Add(('$root = try {{ [string](& ({0}) {{ $script:ModuleRoot }}) }} catch {{ ''ERROR: '' + $_.Exception.Message }}' -f $text))
                $lines.Add(('''RESULT '' + ([ordered]@{{ target = ''{0}''; modules = $found.Count; bases = @($found | ForEach-Object {{ [string]$_.ModuleBase }}); root = $root }} | ConvertTo-Json -Compress)' -f $text.Replace("'", "''")))
            }
            $lines.Add('''RESOLVED '' + [string](Get-Command -Name ''Get-DemoConfig'' -CommandType Function).Module.ModuleBase')
            $key = $lines -join "`n"
            if (-not $probes.Contains($key)) {
                $probes[$key] = [System.Collections.Generic.List[string]]::new()
            }
            $probes[$key].Add($file.Name)
        }
        $index = 0
        foreach ($key in $probes.Keys) {
            $index++
            [System.IO.File]::WriteAllText((Join-Path -Path $scriptsTwo -ChildPath ('probe-{0}.ps1' -f $index)), ("param([bool] `$Nested)`n'PROBE {0}'`n{1}`n" -f ($probes[$key] -join ', '), $key))
        }
        $runner = Join-Path -Path $TestDrive -ChildPath 'runner.ps1'
        [System.IO.File]::WriteAllText($runner, @'
param([string] $Root)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $Root -ChildPath 'two/scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
Import-Module -Name (Join-Path -Path $Root -ChildPath 'one/scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
'LOADED {0}' -f @(Get-Module -Name 'DbHubDemo').Count
foreach ($probe in Get-ChildItem -LiteralPath (Join-Path -Path $Root -ChildPath 'two/scripts') -Filter 'probe-*.ps1' -File | Sort-Object -Property Name) {
    foreach ($nested in $false, $true) {
        'NESTED {0}' -f $nested
        & $probe.FullName -Nested $nested
    }
}
'@)
        $output = @(& $pwsh -NoProfile -NonInteractive -File $runner -Root $TestDrive 2>&1 | ForEach-Object { [string]$_ })
        $because = $output -join ' | '
        $output | Should -Contain 'LOADED 2' -Because $because
        $own = '[\\/]two[\\/]scripts[\\/]modules[\\/]DbHubDemo$'
        @($output | Where-Object { $_ -like 'PROBE *' }).Count | Should -Be (2 * $probes.Count) -Because $because
        $resolved = @($output | Where-Object { $_ -like 'RESOLVED *' })
        $resolved.Count | Should -Be (2 * $probes.Count) -Because $because
        foreach ($line in $resolved) {
            $line.Substring(9) | Should -Match $own -Because ('commands resolve to the copy the script imported: {0}' -f $because)
        }
        $results = @($output | Where-Object { $_ -like 'RESULT *' } | ForEach-Object { $_.Substring(7) | ConvertFrom-Json })
        $results.Count | Should -BeGreaterOrEqual 2 -Because ('start-demo.ps1 and setup-github-repo.ps1 run module code: {0}' -f $because)
        foreach ($result in $results) {
            $result.root | Should -Match $own -Because ('& {0} {{ ... }} runs in the copy it imported, not "The term ''DbHubDemo DbHubDemo'' is not recognized"' -f $result.target)
            $result.modules | Should -Be 1 -Because ('{0} must be the one module the script imported, not every loaded copy' -f $result.target)
            @($result.bases)[0] | Should -Match $own -Because $result.target
        }
        @($probes.Values | ForEach-Object { $_ }) | Should -Contain 'start-demo.ps1'
    }

    It 'replaces a module that an earlier run loaded, and keeps it, with its state, when DbHubDemo''s own code runs the script' {
        $pwsh = (Get-Process -Id $PID).Path
        $missing = Join-Path -Path $TestDrive -ChildPath 'missing.json'
        $probe = Join-Path -Path $TestDrive -ChildPath 'probe.ps1'
        # Outside the repository, as a terminal or a workflow step runs a script.
        [System.IO.File]::WriteAllText($probe, @'
param([string] $Repo, [string] $Missing)
$ErrorActionPreference = 'Stop'
$status = Join-Path -Path $Repo -ChildPath 'scripts/status.ps1'
Import-Module -Name (Join-Path -Path $Repo -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1')
$mark = { & (Get-Module -Name 'DbHubDemo') { $script:StaleMarker = 'earlier run' } }
$read = { [string](& (Get-Module -Name 'DbHubDemo') { Get-Variable -Name 'StaleMarker' -Scope Script -ValueOnly -ErrorAction SilentlyContinue }) }
& $mark
try { & $status -ConfigPath $Missing *> $null } catch { $null = $_ }
'TOP [{0}]' -f (& $read)
& $mark
try { & (Get-Module -Name 'DbHubDemo') { param($Path, $Config) Invoke-DemoRepositoryScript -Path $Path -Argument @{ ConfigPath = $Config } } $status $Missing *> $null } catch { $null = $_ }
'NESTED [{0}]' -f (& $read)
'@)
        $output = @(& $pwsh -NoProfile -NonInteractive -File $probe -Repo $repoRoot -Missing $missing 2>&1 | ForEach-Object { [string]$_ })
        $output | Should -Contain 'TOP []' -Because ('a run from outside the repository loads the module again: {0}' -f ($output -join ' | '))
        $output | Should -Contain 'NESTED [earlier run]' -Because 'a script that the module runs keeps the module and its state'
    }
}

Describe 'PowerShell files' {
    It 'are ASCII-only, so Windows PowerShell 5.1 reads them correctly' {
        $nonAscii = foreach ($file in Get-RepoFile -Include '*.ps1', '*.psm1', '*.psd1') {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            if ([System.Linq.Enumerable]::Any([byte[]]$bytes, [System.Func[byte, bool]] { param($b) $b -gt 127 })) {
                $file.FullName.Substring($repoRoot.Length)
            }
        }
        $nonAscii | Should -BeNullOrEmpty
    }

    It 'never pass [type]$value as a command argument, where it is a string, not a cast (live finding, 2026-11-06)' {
        # In argument mode, [string]$x is the text "[string]" followed by the value: the first boot's cleanup got
        # "[string]System.Collections.Hashtable[jumpstartFolder]" as its folder and never deleted C:\Jumpstart. Write
        # ([string]$x). A bare type name with no variable, such as Should -BeOfType [string], is fine.
        $offenders = foreach ($file in Get-RepoFile -Include '*.ps1', '*.psm1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $found = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
                    $node.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::BareWord -and
                    $node.Extent.Text -match '^\[[A-Za-z_][\w.,\[\]]*\]\$'
                }, $true)
            foreach ($node in $found) {
                '{0}:{1}: {2}' -f $file.FullName.Substring($repoRoot.Length), $node.Extent.StartLineNumber, $node.Extent.Text
            }
        }
        $offenders | Should -BeNullOrEmpty
    }
}

Describe 'Safety rules' {
    It 'no code calls private Database Hub routes' {
        $route = '/v1/databasehub/' + '__private'
        $hits = Get-RepoFile -Include '*.ps1', '*.psm1', '*.cs', '*.py', '*.bicep', '*.ipynb', '*.yml', '*.yaml', '*.json', '*.sql' |
            Select-String -Pattern $route -SimpleMatch
        $hits | Should -BeNullOrEmpty
    }

    It 'no code hard-codes a real subscription ID' {
        $pattern = '(?i)(?:/subscriptions/|"subscriptionId"\s*:\s*")([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
        $real = foreach ($match in (Get-RepoFile -Include '*.ps1', '*.psm1', '*.cs', '*.bicep', '*.bicepparam', '*.json', '*.yml', '*.yaml', '*.ipynb' | Select-String -Pattern $pattern -AllMatches)) {
            foreach ($m in $match.Matches) {
                if (-not (Test-FakeGuid -Guid $m.Groups[1].Value)) {
                    '{0}:{1}' -f $match.Path.Substring($repoRoot.Length), $match.LineNumber
                }
            }
        }
        $real | Should -BeNullOrEmpty
    }

    It 'no file names the archive repository; the public repository is MarcBushong/fabric-database-hub-demo (Phase 26e)' {
        # Assembled here, so this file doesn't name it either. Paths are checked relative to the repository root,
        # because a clone's own folder may still carry the old name.
        $archiveName = 'fabric-database-hub-' + 'hybrid-sql-demo'
        $binary = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.zip', '.pbix', '.dll', '.exe')
        $hits = foreach ($file in Get-RepoFile -Include '*') {
            $relative = $file.FullName.Substring($repoRoot.Length)
            if ($relative.IndexOf($archiveName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $relative
            }
            elseif ($file.Extension -notin $binary -and [System.IO.File]::ReadAllText($file.FullName).IndexOf($archiveName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $relative
            }
        }
        $hits | Should -BeNullOrEmpty
    }

    It 'Git ignores the local configuration file' {
        Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath '.gitignore') | Should -Contain 'config/demo.config.json'
    }

    It 'no script runs icacls /grant with /T, which leaves files with an empty ACL (live finding, 2026-10-20)' {
        $hits = Get-RepoFile -Include '*.ps1', '*.psm1' | Select-String -Pattern 'icacls' |
            Where-Object { $_.Line -match '(?i)/grant' -and $_.Line -match '(?i)\s/T(\s|$)' } |
            ForEach-Object { '{0}:{1}' -f $_.Path.Substring($repoRoot.Length), $_.LineNumber }
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'GitHub workflows' {
    BeforeAll {
        $yamlFiles = @(Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath '.github') -Recurse -File -Include '*.yml', '*.yaml')
        $uses = foreach ($file in $yamlFiles) {
            foreach ($match in (Select-String -LiteralPath $file.FullName -Pattern '^\s*(?:-\s*)?uses:\s*([^\s#]+)')) {
                [pscustomobject]@{ File = $file.Name; Ref = $match.Matches[0].Groups[1].Value }
            }
        }
        $external = @($uses | Where-Object { -not $_.Ref.StartsWith('./') })
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    }

    It 'pin every external action to a full commit SHA' {
        $unpinned = $external | Where-Object { $_.Ref -notmatch '^[^@]+@[0-9a-f]{40}$' } | ForEach-Object { "$($_.File): $($_.Ref)" }
        $unpinned | Should -BeNullOrEmpty
    }

    It 'pin the same SHAs that config/versions.json records' {
        $mismatched = foreach ($item in $external) {
            $name, $sha = $item.Ref.Split('@')
            if (-not $versions.actions.ContainsKey($name) -or $versions.actions[$name].sha -ne $sha) {
                "$($item.File): $($item.Ref)"
            }
        }
        $mismatched | Should -BeNullOrEmpty
    }
}

Describe 'Notebooks' {
    It '<Name> has no outputs or execution counts' -ForEach $notebookFiles {
        $notebook = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        foreach ($cell in $notebook.cells | Where-Object { $_.cell_type -eq 'code' }) {
            @($cell.outputs).Count | Should -Be 0
            $cell.execution_count | Should -BeNullOrEmpty
        }
    }

    It '<Name> keeps the PySpark kernel and the LH_DatabaseHub name, but no Fabric IDs (ADR 0021)' -ForEach $notebookFiles {
        $notebook = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        $notebook.metadata.kernelspec.name | Should -Be 'synapse_pyspark'
        $notebook.metadata.dependencies.lakehouse.default_lakehouse_name | Should -Be 'LH_DatabaseHub'
        # The import binds the lakehouse that Resolve-DemoFabricConfig resolves by name; the repo stores no ID.
        @($notebook.metadata.dependencies.lakehouse.Keys) | Should -Be @('default_lakehouse_name')
    }
}

Describe 'No Fabric IDs in the repository (ADR 0021)' {
    BeforeAll {
        $guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

        # A documented fake: the all-zero placeholder, or an obviously made-up value: at most six distinct hex digits
        # (11111111-2222-3333-4444-555555555555, aaaaaaaa-0000-0000-0000-000000000001), or three or more of its five groups
        # each one repeated character (AbCdEf12-1111-2222-3333-444444444444). A random GUID uses about twelve distinct
        # digits and almost never repeats one character through a whole group.
        function Test-DocumentedFake {
            param([string] $Guid)
            $lower = $Guid.ToLowerInvariant()
            if (@($lower.Replace('-', '').ToCharArray() | Select-Object -Unique).Count -le 6) {
                return $true
            }
            return @($lower.Split('-') | Where-Object { $_ -match '^(.)\1*$' }).Count -ge 3
        }

        # Public, well-known IDs that the tests use. None of them identifies a tenant.
        $publicIds = @{
            '4633458b-17de-408a-b874-0445c86b69e6' = 'Azure built-in role: Key Vault Secrets User'
            'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7' = 'Azure built-in role: Azure Connected Machine Onboarding'
            'a509b1a7-37ef-4b3f-8cfc-4f3a74704073' = 'Windows: Internet Explorer Enhanced Security Configuration, administrators'
            'a509b1a8-37ef-4b3f-8cfc-4f3a74704073' = 'Windows: Internet Explorer Enhanced Security Configuration, users'
            'ab7fd829-77a8-56a7-ae68-8649f2587158' = 'The Real-Time Dashboard''s name-based UUID for page/incident (ConvertTo-DemoStableGuid)'
        }

        $textTypes = @('*.ps1', '*.psm1', '*.psd1', '*.json', '*.ipynb', '*.md', '*.yml', '*.yaml', '*.bicep', '*.bicepparam', '*.tmdl', '*.pbir',
            '*.platform', '*.ts', '*.tsx', '*.js', '*.mjs', '*.css', '*.html', '*.py', '*.sql', '*.kql', '*.cs', '*.csproj', '*.props', '*.txt', '*.example', '*.toml')
        $relative = { param([System.IO.FileInfo] $File) $File.FullName.Substring($repoRoot.Length + 1).Replace('\', '/') }
        $fabricFiles = @(Get-RepoFile -Include $textTypes | Where-Object { (& $relative $_) -like 'fabric/*' })
        $testFiles = @(Get-RepoFile -Include $textTypes | Where-Object { (& $relative $_) -like 'tests/*' })
    }

    It 'finds the files it checks' {
        $fabricFiles.Count | Should -BeGreaterThan 50
        $testFiles.Count | Should -BeGreaterThan 50
    }

    It 'rule 1: no notebook holds a GUID-shaped value' {
        $offenders = foreach ($file in $fabricFiles | Where-Object { $_.Extension -eq '.ipynb' }) {
            if ([regex]::IsMatch([System.IO.File]::ReadAllText($file.FullName), $guidPattern)) {
                & $relative $file
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'rule 2: under fabric/, a GUID is the all-zero placeholder, a documented fake, or a generator''s ID under its own key' {
        # The Real-Time Dashboard's IDs are version-5 UUIDs that Export-DemoRealTimeDashboard derives from element names
        # (ConvertTo-DemoStableGuid; Fabric.Dashboard.Tests checks that the committed file is exactly its output). The
        # report's logicalId and visual IDs are hashes of names from fabric/powerbi/generator (hexGuid). Neither comes
        # from a tenant, and both are recomputed from the names whenever the generators run.
        $offenders = foreach ($file in $fabricFiles) {
            $path = & $relative $file
            $text = [System.IO.File]::ReadAllText($file.FullName)
            foreach ($match in [regex]::Matches($text, $guidPattern)) {
                if (Test-DocumentedFake -Guid $match.Value) {
                    continue
                }
                $before = $text.Substring([System.Math]::Max(0, $match.Index - 40), [System.Math]::Min(40, $match.Index))
                $generated = ($path -eq 'fabric/realtime/RealTimeDashboard.json' -and $match.Value.Substring(14, 1) -eq '5' -and $before -match '"(id|pageId|queryId|dataSourceId)"\s*:\s*"$') -or
                    ($path -like 'fabric/powerbi/*/.platform' -and $before -match '"logicalId"\s*:\s*"$') -or
                    ($path -like 'fabric/powerbi/*/visual.json' -and $before -match '"id"\s*:\s*"field-$')
                if (-not $generated) {
                    '{0} at {1}' -f $path, $match.Index
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'rule 3: wherever it appears, a GUID in a Fabric ID context is the all-zero placeholder or a documented fake' {
        $context = '(?i)(?:(?:workspace|lakehouse|capacity)_?id[''"\]]{0,3}\s*[:=]\s*[''"]?|default_lakehouse(?:_workspace_id)?["'']?\s*:\s*["'']|/(?:workspaces|groups|lakehouses|capacities)/|onelake\.dfs\.fabric\.microsoft\.com/(?:' + $guidPattern + '/)?)(' + $guidPattern + ')'
        $offenders = foreach ($file in Get-RepoFile -Include $textTypes) {
            foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($file.FullName), $context)) {
                if (-not (Test-DocumentedFake -Guid $match.Groups[1].Value)) {
                    '{0} at {1}' -f (& $relative $file), $match.Index
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'rule 4: every GUID in the tests is the all-zero placeholder, a documented fake, or a listed public ID' {
        $offenders = foreach ($file in $testFiles) {
            foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($file.FullName), $guidPattern)) {
                if (-not (Test-DocumentedFake -Guid $match.Value) -and -not $publicIds.ContainsKey($match.Value.ToLowerInvariant())) {
                    '{0} at {1}' -f (& $relative $file), $match.Index
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }
}

Describe 'Configuration files' {
    It 'the example configuration matches the schema' {
        $schema = Join-Path -Path $repoRoot -ChildPath 'config/environment.schema.json'
        Test-Json -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -SchemaFile $schema | Should -BeTrue
    }

    It 'versions.json pins tools and actions' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $versions.tools.Keys | Should -Contain 'pester'
        $versions.tools.Keys | Should -Contain 'psscriptanalyzer'
        $versions.tools.Keys | Should -Contain 'bicep'
        foreach ($action in $versions.actions.Values) {
            $action.sha | Should -Match '^[0-9a-f]{40}$'
        }
    }

    It 'every Azure Verified Module reference matches config/versions.json' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $references = Get-RepoFile -Include '*.bicep' | Select-String -Pattern "'br/public:(avm/[^:]+):([0-9.]+)'" -AllMatches
        $mismatched = foreach ($match in $references) {
            foreach ($m in $match.Matches) {
                if ($versions.avm[$m.Groups[1].Value] -ne $m.Groups[2].Value) {
                    '{0}: {1}:{2}' -f $match.Filename, $m.Groups[1].Value, $m.Groups[2].Value
                }
            }
        }
        $mismatched | Should -BeNullOrEmpty
    }

    It 'every profile puts the T2 host in a nested-virtualization family' {
        $catalog = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/profiles.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($name in $catalog.profiles.Keys) {
            $catalog.nestedVirtualizationFamilies | Should -Contain $catalog.profiles[$name].t2Host.family
        }
    }

    It 'every profile disk tier exists, and only a zonal tier is Premium SSD v2' {
        $catalog = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/profiles.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($name in $catalog.profiles.Keys) {
            foreach ($role in 't1', 't2Host') {
                $vm = $catalog.profiles[$name][$role]
                $catalog.diskTiers[$vm.osDisk].zonalOnly | Should -BeFalse
                $catalog.diskTiers[$vm.dataDisk].zonalOnly | Should -BeFalse
                if ($vm.ContainsKey('zonalDataDisk')) {
                    $catalog.diskTiers.Keys | Should -Contain $vm.zonalDataDisk
                }
            }
        }
        $catalog.diskTiers['PremiumV2'].sku | Should -Be 'PremiumV2_LRS'
        $catalog.diskTiers['PremiumV2'].caching | Should -Be 'None'
    }

    It 'the lowest-cost profile has no separate data disks, and the other profiles keep theirs (2026-10-20)' {
        $catalog = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/profiles.json') -Raw | ConvertFrom-Json -AsHashtable
        $catalog.diskTiers['None'].sku | Should -Be 'None'
        foreach ($role in 't1', 't2Host') {
            $catalog.profiles['lowest-cost'][$role].dataDisk | Should -Be 'None'
            $catalog.profiles['lowest-cost'][$role].ContainsKey('zonalDataDisk') | Should -BeFalse
            $catalog.profiles['demo-day'][$role].dataDisk | Should -Be 'E10'
            $catalog.profiles['enhanced-performance'][$role].dataDisk | Should -Be 'P10'
        }
    }

    It 'the .NET runtime pin matches the SDK and comes from Microsoft with a SHA-512' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $runtime = $versions.dotnetRuntime
        $runtime.sdkVersion | Should -Be $versions.tools.dotnetSdk
        $runtime.version | Should -Match '^10\.0\.\d+$'
        $runtime.rid | Should -Be 'win-x64'
        $runtime.url | Should -Match ('^https://builds\.dotnet\.microsoft\.com/dotnet/Runtime/{0}/' -f [regex]::Escape($runtime.version))
        $runtime.fileName | Should -Be ([System.IO.Path]::GetFileName(([uri]$runtime.url).AbsolutePath))
        $runtime.fileName | Should -Be ('dotnet-runtime-{0}-win-x64.zip' -f $runtime.version)
        $runtime.sha512 | Should -Match '^[0-9a-f]{128}$'
        $runtime.sizeBytes | Should -BeGreaterThan 0
        $runtime.releaseMetadata | Should -Match '^https://builds\.dotnet\.microsoft\.com/dotnet/release-metadata/10\.0/releases\.json$'
    }

    It 'the workload generator''s global.json pins the SDK that config/versions.json records, so nobody needs a newer one than the documented pin (2026-11-09)' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $globalJson = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'workload-generator/global.json') -Raw | ConvertFrom-Json -AsHashtable
        # rollForward picks a later SDK, never an earlier one, so a global.json above the pin would fail the build with it.
        $globalJson['sdk']['version'] | Should -Be $versions['tools']['dotnetSdk']
        $globalJson['sdk']['rollForward'] | Should -Be 'latestFeature'
        $globalJson['sdk']['allowPrerelease'] | Should -BeFalse
    }

    It 'the .NET SDK that deploy.ps1 installs for the user is the pin, from Microsoft, with a SHA-512 for each Windows architecture (2026-11-09)' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $install = $versions['dotnetSdkInstall']
        $install['version'] | Should -Be $versions['tools']['dotnetSdk'] -Because 'deploy.ps1 installs the SDK that global.json pins'
        $install['releaseMetadata'] | Should -Match '^https://builds\.dotnet\.microsoft\.com/dotnet/release-metadata/10\.0/releases\.json$'
        @($install['files'].Keys | Sort-Object) | Should -Be @('win-arm64', 'win-x64')
        foreach ($rid in $install['files'].Keys) {
            $file = $install['files'][$rid]
            $file['url'] | Should -BeExactly ('https://builds.dotnet.microsoft.com/dotnet/Sdk/{0}/dotnet-sdk-{0}-{1}.zip' -f $install['version'], $rid)
            $file['fileName'] | Should -Be ([System.IO.Path]::GetFileName(([uri]$file['url']).AbsolutePath))
            $file['sha512'] | Should -Match '^[0-9a-f]{128}$' -Because $rid
            $file['sizeBytes'] | Should -BeGreaterThan 100MB -Because ('deploy.ps1 says the download''s size before it starts ({0})' -f $rid)
        }
    }

    It 'every resource API version in infra/ matches config/versions.json' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $declarations = Get-RepoFile -Include '*.bicep' | Select-String -Pattern "^\s*resource\s+\w+\s+'([^'@]+)@([^']+)'"
        $declarations | Should -Not -BeNullOrEmpty
        $mismatched = foreach ($match in $declarations) {
            $type = $match.Matches[0].Groups[1].Value
            $apiVersion = $match.Matches[0].Groups[2].Value
            if ($versions.apiVersions[$type] -ne $apiVersion) {
                '{0}: {1}@{2}' -f $match.Filename, $type, $apiVersion
            }
        }
        $mismatched | Should -BeNullOrEmpty
    }

    It 'media pins use HTTPS and a SHA-256 or null (trust on first use)' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($name in 'windowsServer2022Eval', 'sqlServer2022', 'sqlServer2022Developer', 'jumpstartArcBoxSqlStd') {
            $pin = $versions.media[$name]
            $pin.url | Should -Match '^https://'
            $pin.fileName | Should -Be ([System.IO.Path]::GetFileName(([uri]$pin.url).AbsolutePath))
            if ($null -ne $pin.sha256) {
                $pin.sha256 | Should -Match '^[0-9a-f]{64}$'
            }
        }
    }
}

Describe 'VM-side files' {
    It 'the embedded bootstrap loader stays under the 96 KB loadTextContent limit' {
        (Get-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoBootstrapLoader.ps1')).Length | Should -BeLessThan 96KB
    }

    It 'redirect native stderr only with Continue, because Windows PowerShell 5.1 stops on the first stderr line (live finding, 2026-10-20)' {
        # Use Invoke-DemoVmNativeCommand, or set $ErrorActionPreference = 'Continue' around the call in standalone scripts.
        $offenders = foreach ($file in Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'vm') -Recurse -File -Include '*.ps1', '*.psm1') {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ($text -match '(?m)&\s*[^\r\n|]*2>&1' -and $text -notmatch "\`$ErrorActionPreference = 'Continue'") {
                $file.FullName.Substring($repoRoot.Length)
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'the health schema is valid JSON Schema that requires the ADR 0012 status' {
        $schema = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/health/health.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $schema['$schema'] | Should -Be 'https://json-schema.org/draft/2020-12/schema'
        $schema.required | Should -Contain 'status'
        $schema.required | Should -Contain 'state'
        $schema.properties.status.enum | Should -Be @('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')
    }

    It 'VM-side PowerShell and the runbooks avoid syntax that Windows PowerShell 5.1 does not have' {
        $offenders = foreach ($file in Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'vm'), (Join-Path -Path $repoRoot -ChildPath 'automation') -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1') {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $found = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TernaryExpressionAst] -or
                    $node -is [System.Management.Automation.Language.PipelineChainAst] -or
                    ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -and $node.Operator -eq 'QuestionQuestion') -or
                    ($node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Operator -eq 'QuestionQuestionEquals') -or
                    ($node -is [System.Management.Automation.Language.CommandParameterAst] -and $node.ParameterName -in @('AsHashtable', 'Parallel'))
                }, $true)
            foreach ($node in $found) {
                '{0}:{1}' -f $file.FullName.Substring($repoRoot.Length), $node.Extent.StartLineNumber
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'VM-side PowerShell and the runbooks declare no mandatory [byte[]] parameter, which Windows PowerShell 5.1 walks on every call (live finding, 2026-11-06)' {
        # Windows PowerShell 5.1 checks a mandatory array argument for null elements one by one (PowerShell 6 and later skip
        # value types, PowerShell/PowerShell#5432): a hash function given the 4 MiB buffer per network read held the
        # Jumpstart image's download to 0.2 MB/s. Call .NET methods in such loops, or take the parameter as optional.
        $offenders = foreach ($file in Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'vm'), (Join-Path -Path $repoRoot -ChildPath 'automation') -Recurse -File -Include '*.ps1', '*.psm1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $found = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.ParameterAst] -and $node.StaticType -eq [byte[]] -and
                    @($node.Attributes | Where-Object {
                            $_ -is [System.Management.Automation.Language.AttributeAst] -and
                            $_.TypeName.GetReflectionAttributeType() -eq [System.Management.Automation.ParameterAttribute] -and
                            @($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' -and $_.Argument.Extent.Text -ne '$false' }).Count -gt 0
                        }).Count -gt 0
                }, $true)
            foreach ($node in $found) {
                '{0}:{1}' -f $file.FullName.Substring($repoRoot.Length), $node.Extent.StartLineNumber
            }
        }
        $offenders | Should -BeNullOrEmpty
    }
}

Describe 'Network security rules in the compiled template' {
    BeforeAll {
        # Azure checks these only at deployment time; what-if, the Bicep linter, and PSRule don't (Phase 5 live findings).
        $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable
        $rules = [System.Collections.Generic.List[object]]::new()
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push($template)
        while ($stack.Count -gt 0) {
            $node = $stack.Pop()
            if ($node -is [System.Collections.IDictionary]) {
                if ($node.Contains('properties') -and $node['properties'] -is [System.Collections.IDictionary] -and
                    $node['properties'].Contains('access') -and $node['properties'].Contains('direction')) {
                    $rules.Add($node)
                }
                foreach ($value in $node.Values) { $stack.Push($value) }
            }
            elseif ($node -is [System.Collections.IList]) {
                foreach ($value in $node) { $stack.Push($value) }
            }
        }
    }

    It 'finds security rules to check' {
        $rules.Count | Should -BeGreaterThan 0
    }

    It 'never allow traffic with a deny-only platform service tag' {
        # AzurePlatformDNS, AzurePlatformIMDS, and AzurePlatformLKM are valid only in Deny rules; Azure rejects
        # an Allow rule that uses them (SecurityRuleInvalidAccessType). The platform allows that traffic anyway.
        $invalid = foreach ($rule in $rules) {
            $p = $rule['properties']
            $prefixes = @($p['destinationAddressPrefix'], $p['sourceAddressPrefix']) + @($p['destinationAddressPrefixes']) + @($p['sourceAddressPrefixes'])
            if ($p['access'] -eq 'Allow' -and @($prefixes | Where-Object { $_ -is [string] -and $_ -match '^AzurePlatform(DNS|IMDS|LKM)$' }).Count -gt 0) {
                [string]$rule['name']
            }
        }
        $invalid | Should -BeNullOrEmpty
    }

    It 'keep every description within the 140-character limit' {
        # Longer descriptions fail with SecurityRuleDescriptionTooLong.
        $tooLong = foreach ($rule in $rules) {
            $description = [string]$rule['properties']['description']
            if ($description.Length -gt 140) {
                '{0} ({1} characters)' -f $rule['name'], $description.Length
            }
        }
        $tooLong | Should -BeNullOrEmpty
    }
}

Describe 'Resources in the compiled template' {
    BeforeAll {
        $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable
        $resourceTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $subnets = [System.Collections.Generic.List[object]]::new()
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push($template)
        while ($stack.Count -gt 0) {
            $node = $stack.Pop()
            if ($node -is [System.Collections.IDictionary]) {
                if ($node['type'] -is [string] -and $node.Contains('apiVersion')) {
                    [void]$resourceTypes.Add($node['type'])
                }
                # Subnet definitions passed to the AVM virtual-network module.
                if ($node['name'] -is [string] -and $node.Contains('addressPrefix') -and $node.Contains('networkSecurityGroupResourceId')) {
                    $subnets.Add($node)
                }
                foreach ($value in $node.Values) { $stack.Push($value) }
            }
            elseif ($node -is [System.Collections.IList]) {
                foreach ($value in $node) { $stack.Push($value) }
            }
        }
        Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
        $demoResourceTypes = & (Get-Module -Name DbHubDemo) { $script:DemoResourceTypes }
    }

    AfterAll {
        Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
    }

    It 'create no storage accounts (the artifact cache was dropped on 2026-10-20)' {
        # Tenant policies turn off shared-key and public access on storage accounts, and Defender for Storage
        # bills each account; the cost estimate and the policy checks rely on there being none.
        @($resourceTypes | Where-Object { $_ -like 'Microsoft.Storage/*' }) | Should -BeNullOrEmpty
    }

    It 'create the data disks only when the tier isn''t None, and attach them only then' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw
        $template = $text | ConvertFrom-Json -AsHashtable
        $disks = [System.Collections.Generic.List[object]]::new()
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push($template)
        while ($stack.Count -gt 0) {
            $node = $stack.Pop()
            if ($node -is [System.Collections.IDictionary]) {
                if ($node['type'] -eq 'Microsoft.Compute/disks') {
                    $disks.Add($node)
                }
                foreach ($value in $node.Values) { $stack.Push($value) }
            }
            elseif ($node -is [System.Collections.IList]) {
                foreach ($value in $node) { $stack.Push($value) }
            }
        }
        # The only other disk is the T2 host's OS disk copied from a golden snapshot (ADR 0018).
        $dataDisks = @($disks | Where-Object { [string]$_['condition'] -notmatch 'osDiskFromSnapshot' })
        $dataDisks.Count | Should -BeGreaterThan 0
        foreach ($disk in $dataDisks) {
            $disk['condition'] | Should -Match 'hasDataDisk'
        }
        $text | Should -Match ([regex]::Escape("not(equals(parameters('dataDisk').sku, 'None'))"))
    }

    It 'copy the T2 host''s OS disk from a golden snapshot only when one is given, with export and public access off' {
        $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable
        $golden = [System.Collections.Generic.List[object]]::new()
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push($template)
        while ($stack.Count -gt 0) {
            $node = $stack.Pop()
            if ($node -is [System.Collections.IDictionary]) {
                if ($node['type'] -eq 'Microsoft.Compute/disks' -and [string]$node['condition'] -match 'osDiskFromSnapshot') {
                    $golden.Add($node)
                }
                foreach ($value in $node.Values) { $stack.Push($value) }
            }
            elseif ($node -is [System.Collections.IList]) {
                foreach ($value in $node) { $stack.Push($value) }
            }
        }
        $golden.Count | Should -BeGreaterThan 0
        foreach ($disk in $golden) {
            $disk['properties']['creationData']['createOption'] | Should -Be 'Copy'
            $disk['properties']['networkAccessPolicy'] | Should -Be 'DenyAll'
            $disk['properties']['publicNetworkAccess'] | Should -Be 'Disabled'
        }
    }

    It 'pass the chunk count and no bundle URL to the bootstrap loader' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw
        $text | Should -Match '"bootstrapChunkCount"'
        $text | Should -Not -Match '(?i)bootstrapBundleUrl|protectedParameters'
    }

    It 'set privateEndpointNetworkPolicies on every subnet' {
        # Without it, what-if reports a change from the live value on every run (Phase 5 convergence what-if).
        # snet-sqlvm, snet-archost, snet-pe, the Bastion subnet, and T4's delegated snet-pg (Phase 24).
        $subnets.Count | Should -Be 5
        foreach ($subnet in $subnets) {
            $subnet.Contains('privateEndpointNetworkPolicies') | Should -BeTrue -Because $subnet['name']
        }
        ($subnets | Where-Object { $_['name'] -eq 'snet-pe' })['privateEndpointNetworkPolicies'] | Should -Be 'NetworkSecurityGroupEnabled'
    }

    It 'use only resource types that the policy inventory checks' {
        # AVM options the demo leaves off, and the nested deployments themselves.
        $notCreated = @('Microsoft.Resources/deployments', 'Microsoft.Authorization/roleAssignments', 'Microsoft.Insights/diagnosticSettings', 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings')
        $unchecked = @($resourceTypes | Where-Object { $_ -notin $notCreated -and $_ -notin $demoResourceTypes })
        $unchecked | Should -BeNullOrEmpty
    }
}

Describe 'Markdown' {
    It 'every relative link resolves' {
        $broken = foreach ($file in Get-RepoFile -Include '*.md') {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, '\]\(([^)\s]+)\)')) {
                $target = $match.Groups[1].Value
                if ($target -match '^(https?:|mailto:|#|<)') {
                    continue
                }
                $pathPart = $target.Split('#')[0]
                if ($pathPart -and -not (Test-Path -LiteralPath (Join-Path -Path $file.DirectoryName -ChildPath $pathPart))) {
                    '{0} -> {1}' -f $file.FullName.Substring($repoRoot.Length), $target
                }
            }
        }
        $broken | Should -BeNullOrEmpty
    }
}
