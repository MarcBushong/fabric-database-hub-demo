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
        '.github/copilot-instructions.md', '.github/dependabot.yml',
        '.github/workflows/validate.yml', '.github/workflows/deploy.yml', '.github/workflows/demo-control.yml', '.github/workflows/destroy.yml'
    ) {
        Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $_) -PathType Leaf | Should -BeTrue
    }

    It 'has the script scripts/<_>.ps1 with #Requires and comment-based help' -ForEach @(
        'init', 'deploy', 'preflight', 'configure-fabric', 'configure-powerbi', 'configure-fabric-app', 'configure-arc', 'configure-monitoring', 'validate',
        'start-demo', 'stop-demo', 'reset-demo', 'status', 'estimate-cost', 'destroy', 'setup-github-oidc', 'setup-github-repo', 'setup-activity-control',
        'collect-diagnostics'
    ) {
        $path = Join-Path -Path $repoRoot -ChildPath "scripts/$_.ps1"
        Test-Path -LiteralPath $path | Should -BeTrue
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.4'
        $text | Should -Match '\.SYNOPSIS'
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
        foreach ($name in 'windowsServer2022Eval', 'sqlServer2022', 'sqlServer2022Developer') {
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
