BeforeDiscovery {
    $repoRootForDiscovery = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $promptFiles = @(Get-ChildItem -Path (Join-Path -Path $repoRootForDiscovery -ChildPath 'fabric/agent/prompts') -Filter '*.md' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'README.md' } |
            Sort-Object -Property Name |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    $agentFiles = @(Get-ChildItem -Path (Join-Path -Path $repoRootForDiscovery -ChildPath 'fabric/agent') -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName |
            ForEach-Object { @{ Name = $_.FullName.Substring($repoRootForDiscovery.Length + 1).Replace('\', '/'); Path = $_.FullName } })
}

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $agentRoot = Join-Path -Path $repoRoot -ChildPath 'fabric/agent'
    $promptRoot = Join-Path -Path $agentRoot -ChildPath 'prompts'
    $schemaPath = Join-Path -Path $promptRoot -ChildPath 'prompt.schema.json'
    $guidePath = Join-Path -Path $agentRoot -ChildPath 'README.md'
    $indexPath = Join-Path -Path $promptRoot -ChildPath 'README.md'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
    $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    # The prompt pack covers the SQL targets (ADR 0013). T4-only scenarios (connection-surge, idle-in-transaction)
    # have no prompts: Database Hub monitors PostgreSQL with metrics only, and the Database Agent's PostgreSQL
    # coverage isn't documented (Phase 24, ADR 0019).
    $scenarioFolders = @(Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'scenarios') -Directory | Where-Object {
            @((Get-Content -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'scenario.json') -Raw | ConvertFrom-Json).targets.applicable | Where-Object { $_ -ne 'T4' }).Count -gt 0
        } | ForEach-Object { $_.Name })
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force

    $allowedPlaceholders = @('target', 'resourceGroup', 'incidentWindow', 'baselineWindow')
    $statuses = @('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')
    $requiredSections = @('## Prompts', '## Signals to look for', '## How to judge the answer', '## Safety', '## Fallback demo')
    $readOnlyGuard = "Don't change anything"
    $proposeGuard = "Don't apply anything; propose only"
    # Official documentation hosts, the Database Hub and Azure Data Explorer web UIs that Learn links to, and the
    # JSON Schema dialect URI.
    $allowedHosts = @('learn.microsoft.com', 'docs.github.com', 'github.com', 'code.visualstudio.com', 'devblogs.microsoft.com', 'dataexplorer.azure.com', 'powerbi.com', 'json-schema.org')
    # Phrases that would mean a file hard-codes what an agent answers (ADR 0013).
    $answerPatterns = @(
        '(?i)\bexpected\s+(ai\s+)?(output|answer|response|reply)\b'
        '(?i)\b(sample|example)\s+(output|answer|response|reply)\b'
        '(?i)\bthe\s+(agent|copilot|model)\s+(will|should)\s+(say|answer|respond|reply|return)\b'
        '(?im)^\s*>?\s*\**\s*(agent|copilot|assistant)\s*\**\s*:'
    )
    $privateMarker = '__' + 'private'

    function ConvertFrom-PromptScalar {
        param(
            [string] $Raw,
            [string] $Context
        )
        if ($Raw -ceq 'true') {
            return $true
        }
        if ($Raw -ceq 'false') {
            return $false
        }
        if ($Raw.StartsWith('"')) {
            if ($Raw -notmatch '^"([^"\\]*)"$') {
                throw "$Context has a quoted value that isn't a simple double-quoted string."
            }
            return $Matches[1]
        }
        # Plain YAML scalars can't start with an indicator character or contain ': ' or ' #'.
        if ($Raw -match '^[-?:,\[\]{}#&*!|>''"%@`]' -or $Raw.Contains(': ') -or $Raw.Contains(' #') -or $Raw.EndsWith(':')) {
            throw "$Context has a value that isn't a safe plain YAML scalar; quote it or reword it: $Raw"
        }
        return $Raw
    }

    function Read-PromptFile {
        <#
        Parses the YAML front matter of a prompt file. Only the subset the pack uses is accepted, so every
        file stays valid YAML for GitHub's renderer: 'key: value', 'key: [a, b]', and a 'key:' line followed
        by '  - item' lines.
        #>
        param(
            [string] $Path
        )
        $name = [System.IO.Path]::GetFileName($Path)
        $lines = [System.IO.File]::ReadAllLines($Path)
        if ($lines.Count -lt 3 -or $lines[0] -cne '---') {
            throw "$name doesn't start with YAML front matter."
        }
        $end = -1
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -ceq '---') {
                $end = $i
                break
            }
        }
        if ($end -lt 0) {
            throw "$name has no closing front matter line."
        }

        $frontMatter = [ordered]@{}
        $listKey = $null
        for ($i = 1; $i -lt $end; $i++) {
            $line = $lines[$i]
            $context = '{0} line {1}' -f $name, ($i + 1)
            if ($line -match '^\s*$') {
                continue
            }
            if ($line -match '^  - (.+)$') {
                if ($null -eq $listKey) {
                    throw "$context has a list item without a list key."
                }
                $frontMatter[$listKey].Add((ConvertFrom-PromptScalar -Raw $Matches[1] -Context $context))
                continue
            }
            if ($line -cmatch '^([a-z][A-Za-z]*):(?: (.*))?$') {
                $key = $Matches[1]
                $raw = $Matches[2]
                if ($frontMatter.Contains($key)) {
                    throw "$context repeats the key '$key'."
                }
                $listKey = $null
                if ([string]::IsNullOrEmpty($raw)) {
                    $frontMatter[$key] = [System.Collections.Generic.List[object]]::new()
                    $listKey = $key
                }
                elseif ($raw -match '^\[(.*)\]$') {
                    $items = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    foreach ($item in $items) {
                        if ($item -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                            throw "$context has a list item that isn't a simple token: $item"
                        }
                    }
                    $frontMatter[$key] = $items
                }
                else {
                    $frontMatter[$key] = ConvertFrom-PromptScalar -Raw $raw -Context $context
                }
                continue
            }
            throw "$context isn't supported front matter. Use 'key: value', 'key: [a, b]', or a '  - item' list."
        }

        $bodyLines = if ($end + 1 -lt $lines.Count) { $lines[($end + 1)..($lines.Count - 1)] } else { @() }
        [pscustomobject]@{
            Name        = $name
            Id          = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            FrontMatter = $frontMatter
            Body        = $bodyLines -join "`n"
            Text        = ($lines -join "`n")
        }
    }

    function Get-PromptBlock {
        param(
            [string] $Body
        )
        foreach ($match in [regex]::Matches($Body, '(?ms)^```text\n(.*?)\n```$')) {
            $match.Groups[1].Value
        }
    }

    $prompts = @(Get-ChildItem -Path $promptRoot -Filter '*.md' -File | Where-Object { $_.Name -ne 'README.md' } | ForEach-Object { Read-PromptFile -Path $_.FullName })
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Agent prompt files' {
    It 'exist for the session setup, every scenario on both surfaces, and the wrap-up' {
        $prompts.Count | Should -BeGreaterOrEqual 17
    }

    It '<Name> has front matter that matches prompt.schema.json' -ForEach $promptFiles {
        $prompt = Read-PromptFile -Path $Path
        $json = $prompt.FrontMatter | ConvertTo-Json -Depth 5
        $schemaErrors = $null
        $valid = Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
        $valid | Should -BeTrue -Because ($schemaErrors | Out-String)
    }

    It '<Name> has an id equal to its file name and a surface that matches it' -ForEach $promptFiles {
        $prompt = Read-PromptFile -Path $Path
        $prompt.FrontMatter['id'] | Should -BeExactly $prompt.Id
        $expectedSurface = if ($prompt.Id.EndsWith('.in-hub')) { 'in-hub-agent' } else { 'skills' }
        $prompt.FrontMatter['surface'] | Should -Be $expectedSurface
    }

    It '<Name> targets T1, T2, and T3 when it is an incident prompt' -ForEach $promptFiles {
        $prompt = Read-PromptFile -Path $Path
        if ($prompt.FrontMatter['incident']) {
            foreach ($target in 'T1', 'T2', 'T3') {
                $prompt.FrontMatter['targets'] | Should -Contain $target
            }
        }
    }

    It '<Name> names a scenario that exists, with a default target for scenario incidents' -ForEach $promptFiles {
        $prompt = Read-PromptFile -Path $Path
        $scenario = $prompt.FrontMatter['scenario']
        switch ($scenario) {
            'setup' {
                $prompt.FrontMatter['incident'] | Should -BeFalse
            }
            'any' {
                $prompt.FrontMatter['incident'] | Should -BeTrue
            }
            'resource-governance' {
                foreach ($source in $prompt.FrontMatter['producedBy']) {
                    $scenarioFolders | Should -Contain $source
                }
                $prompt.FrontMatter['defaultTarget'] | Should -Be 'T3'
            }
            default {
                $scenarioFolders | Should -Contain $scenario
            }
        }
        if ($prompt.FrontMatter['incident'] -and $scenario -ne 'any') {
            $prompt.FrontMatter.Contains('defaultTarget') | Should -BeTrue
        }
    }

    It '<Name> has a title and the standard sections' -ForEach $promptFiles {
        $prompt = Read-PromptFile -Path $Path
        $prompt.Body | Should -Match '(?m)^# \S'
        $headings = @($prompt.Body -split "`n" | Where-Object { $_ -match '^## ' })
        foreach ($section in $requiredSections) {
            $headings | Should -Contain $section
        }
    }

    It '<Name> has prompts that carry the read-only rule and use only the known placeholders' -ForEach $promptFiles {
        $prompt = Read-PromptFile -Path $Path
        $blocks = @(Get-PromptBlock -Body $prompt.Body)
        $blocks.Count | Should -BeGreaterThan 0
        foreach ($block in $blocks) {
            if ($prompt.FrontMatter['actionPolicy'] -eq 'read-only') {
                $block | Should -BeLikeExactly "*$readOnlyGuard*"
            }
            else {
                ($block.Contains($readOnlyGuard) -or $block.Contains($proposeGuard)) | Should -BeTrue -Because $block
            }
            foreach ($match in [regex]::Matches($block, '\{([^{}]*)\}')) {
                $allowedPlaceholders | Should -Contain $match.Groups[1].Value
            }
            $block | Should -Not -Match '<[A-Za-z][^<>]*>'
        }
        if ($prompt.FrontMatter['actionPolicy'] -eq 'propose-only') {
            @($blocks | Where-Object { $_.Contains($proposeGuard) }).Count | Should -BeGreaterThan 0
        }
    }

    It '<Name> describes signals, never the answer' -ForEach $promptFiles {
        $prompt = Read-PromptFile -Path $Path
        foreach ($pattern in $answerPatterns) {
            $prompt.Text | Should -Not -Match $pattern
        }
    }

    It 'every scenario folder has an in-Hub and a skills prompt file with the same targets' {
        foreach ($scenario in $scenarioFolders) {
            $files = @($prompts | Where-Object { $_.FrontMatter['scenario'] -eq $scenario })
            @($files | Where-Object { $_.FrontMatter['surface'] -eq 'in-hub-agent' }).Count | Should -Be 1 -Because $scenario
            @($files | Where-Object { $_.FrontMatter['surface'] -eq 'skills' }).Count | Should -Be 1 -Because $scenario
            ($files[0].FrontMatter['targets'] -join ',') | Should -Be ($files[1].FrontMatter['targets'] -join ',')
            $files[0].FrontMatter['defaultTarget'] | Should -Be $files[1].FrontMatter['defaultTarget']
        }
    }

    It 'each surface covers all twelve ADR 0013 prompt kinds' {
        foreach ($surface in 'in-hub-agent', 'skills') {
            $covered = @($prompts | Where-Object { $_.FrontMatter['surface'] -eq $surface } | ForEach-Object { $_.FrontMatter['adrPrompts'] } | Sort-Object -Unique)
            foreach ($kind in $schema.properties.adrPrompts.items.enum) {
                $covered | Should -Contain $kind -Because $surface
            }
        }
    }
}

Describe 'Agent prompt index' {
    BeforeAll {
        $indexRows = @(Get-Content -LiteralPath $indexPath | Where-Object { $_ -match '^\| \[' })
        $indexed = @(foreach ($row in $indexRows) {
                foreach ($match in [regex]::Matches($row, '\]\(([A-Za-z0-9.-]+\.md)\)')) {
                    $match.Groups[1].Value
                }
            })
    }

    It 'lists every prompt file exactly once' {
        ($indexed | Sort-Object) | Should -Be (@($prompts | ForEach-Object { $_.Name }) | Sort-Object)
        @($indexed | Group-Object | Where-Object { $_.Count -gt 1 }) | Should -BeNullOrEmpty
    }

    It 'documents every placeholder the prompts may use' {
        $indexText = Get-Content -LiteralPath $indexPath -Raw
        foreach ($placeholder in $allowedPlaceholders) {
            $indexText.Contains('`{' + $placeholder + '}`') | Should -BeTrue -Because $placeholder
        }
    }
}

Describe 'Agent files' {
    It '<Name> has no secrets' -ForEach $agentFiles {
        Clear-DemoSecret
        $text = [System.IO.File]::ReadAllText($Path)
        Protect-DemoText -Text $text | Should -BeExactly $text
        $text | Should -Not -Match '(?i)\bauthorization\s*[:=]\s*\S'
    }

    It '<Name> links only to official HTTPS sources' -ForEach $agentFiles {
        $text = [System.IO.File]::ReadAllText($Path)
        $text | Should -Not -Match '(?i)\bhttp://'
        foreach ($match in [regex]::Matches($text, 'https://([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)')) {
            $allowedHosts | Should -Contain $match.Groups[1].Value.ToLowerInvariant() -Because $match.Value
        }
    }

    It '<Name> never mentions private Database Hub routes' -ForEach $agentFiles {
        [System.IO.File]::ReadAllText($Path) | Should -Not -BeLike "*$privateMarker*"
    }

    It '<Name> references the telemetry agent instructions block instead of copying it' -ForEach $agentFiles {
        $text = [System.IO.File]::ReadAllText($Path)
        # Section headers and the opening sentence of the block as published on Learn.
        $text | Should -Not -BeLikeExactly '*CORRECTNESS RULES*'
        $text | Should -Not -BeLikeExactly '*DATA MODEL*'
        $text | Should -Not -BeLikeExactly '*You can query SQL performance monitoring telemetry for Azure SQL Database*'
    }
}

Describe 'Agent prompt validation rules' {
    BeforeAll {
        $valid = [ordered]@{
            id                = 'locking-blocking.skills'
            name              = 'A valid incident prompt for the rule tests'
            scenario          = 'locking-blocking'
            incident          = $true
            targets           = @('T1', 'T2', 'T3')
            defaultTarget     = 'T1'
            surface           = 'skills'
            hosts             = @('copilot-cli')
            dataSources       = @('telemetry-endpoint')
            capability        = 'Finds blocking on any target from the telemetry endpoint for the rule tests.'
            permission        = 'Reader or higher on the subscription and Microsoft.Sql registered there.'
            responseShape     = 'A verdict, then a table of signals with the metric, window, and value.'
            previewLimitation = 'The telemetry endpoint and its schema are previews that can change.'
            fallback          = 'Run the Learn telemetry sample queries in the Azure Data Explorer web UI.'
            actionPolicy      = 'read-only'
            adrPrompts        = @('investigate-locking')
            sources           = @('https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry')
            reviewed          = '2026-10-20'
        }

        function Test-FrontMatter([System.Collections.IDictionary] $FrontMatter) {
            Test-Json -Json ($FrontMatter | ConvertTo-Json -Depth 5) -SchemaFile $schemaPath -ErrorAction SilentlyContinue
        }

        function Copy-FrontMatter {
            $copy = [ordered]@{}
            foreach ($key in $valid.Keys) {
                $copy[$key] = $valid[$key]
            }
            return $copy
        }
    }

    It 'the schema accepts a complete incident prompt' {
        Test-FrontMatter -FrontMatter $valid | Should -BeTrue
    }

    It 'the schema rejects an incident prompt that leaves out a target' {
        $copy = Copy-FrontMatter
        $copy['targets'] = @('T1', 'T2')
        Test-FrontMatter -FrontMatter $copy | Should -BeFalse
    }

    It 'the schema rejects a prompt without a fallback demo' {
        $copy = Copy-FrontMatter
        $copy.Remove('fallback')
        Test-FrontMatter -FrontMatter $copy | Should -BeFalse
    }

    It 'the schema rejects an in-Hub prompt that claims a skills host' {
        $copy = Copy-FrontMatter
        $copy['id'] = 'locking-blocking.in-hub'
        $copy['surface'] = 'in-hub-agent'
        Test-FrontMatter -FrontMatter $copy | Should -BeFalse
    }

    It 'the schema rejects a source that isn''t HTTPS documentation' {
        $copy = Copy-FrontMatter
        $copy['sources'] = @('http://learn.microsoft.com/fabric/database/hub/overview')
        Test-FrontMatter -FrontMatter $copy | Should -BeFalse
    }

    It 'the front matter reader rejects a value that GitHub would not parse as YAML' {
        $path = Join-Path -Path $TestDrive -ChildPath 'bad.skills.md'
        Set-Content -LiteralPath $path -Value @('---', 'id: bad.skills', 'fallback: Run this: then that', '---', '# Bad')
        { Read-PromptFile -Path $path } | Should -Throw '*safe plain YAML scalar*'
    }

    It 'the answer patterns catch hard-coded answers' {
        $samples = @(
            ('Expected ' + 'output: the head blocker is session 57.')
            ('**Copi' + 'lot:** The head blocker is session 57.')
            ('The agent ' + 'will say that CPU is the cause.')
        )
        foreach ($sample in $samples) {
            @($answerPatterns | Where-Object { $sample -match $_ }).Count | Should -BeGreaterThan 0 -Because $sample
        }
    }

    It 'the secret check catches a token-shaped value' {
        Clear-DemoSecret
        # Built at run time so secret scanners don't flag the test file.
        $fake = 'Authorization: Bearer ' + ('eyJ' + ('a' * 12)) + '.' + ('b' * 12) + '.' + ('c' * 12)
        Protect-DemoText -Text $fake | Should -Not -BeExactly $fake
    }
}

Describe 'Agent install guide' {
    BeforeAll {
        $guide = Get-Content -LiteralPath $guidePath -Raw
        $agentPlugins = $versions.agentPlugins
    }

    It 'pins the marketplace to the commit in config/versions.json for Copilot CLI and VS Code' {
        $pins = @([regex]::Matches($guide, 'microsoft/microsoft-sql#([0-9a-f]+)') | ForEach-Object { $_.Groups[1].Value })
        $pins.Count | Should -BeGreaterOrEqual 2
        foreach ($pin in $pins) {
            $pin | Should -BeExactly $agentPlugins.marketplace.commit
        }
        $guide | Should -BeLikeExactly ('*copilot plugin marketplace add ' + $agentPlugins.marketplace.repository + '#*')
        $guide | Should -BeLikeExactly '*"chat.plugins.marketplaces"*'
    }

    It 'installs both plugins from the pinned marketplace' {
        foreach ($plugin in 'microsoft-sql-fdh', 'microsoft-sql') {
            $guide | Should -BeLikeExactly ('*copilot plugin install {0}@{1}*' -f $plugin, $agentPlugins.marketplace.name)
            $guide | Should -BeLikeExactly ('*{0}*' -f $agentPlugins.plugins[$plugin].version)
        }
    }

    It 'adds the Learn MCP server endpoint from config/versions.json' {
        $guide | Should -BeLikeExactly ('*' + $agentPlugins.learnMcp.endpoint + '*')
    }

    It 'attributes the telemetry agent instructions block to its Learn page' {
        $guide | Should -BeLikeExactly '*https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry*'
        $guide | Should -BeLikeExactly '*Agent instructions block*'
    }

    It 'records live coverage for every scenario prompt with the six statuses only' {
        $section = ($guide -split '(?m)^## ') | Where-Object { $_.StartsWith('Live coverage record') }
        $section | Should -Not -BeNullOrEmpty
        $rows = @($section -split "`n" | Where-Object { $_ -cmatch '^\| [a-z]' })
        $expected = @($prompts | Where-Object { $_.FrontMatter['scenario'] -ne 'setup' } | ForEach-Object { $_.Id } | Sort-Object)
        (@($rows | ForEach-Object { ($_ -split '\|')[1].Trim() }) | Sort-Object) | Should -Be $expected
        foreach ($row in $rows) {
            $cells = $row -split '\|'
            foreach ($cell in $cells[2..4]) {
                $statuses | Should -Contain $cell.Trim() -Because $row
            }
        }
    }
}

Describe 'Agent plugin pins in config/versions.json' {
    It 'pin the marketplace to a full commit SHA and the plugins to semantic versions' {
        $agentPlugins = $versions.agentPlugins
        $agentPlugins.marketplace.commit | Should -Match '^[0-9a-f]{40}$'
        $agentPlugins.marketplace.url | Should -BeExactly ('https://github.com/' + $agentPlugins.marketplace.repository)
        $agentPlugins.verifiedOn | Should -Match '^\d{4}-\d{2}-\d{2}$'
        foreach ($name in 'microsoft-sql-fdh', 'microsoft-sql') {
            $agentPlugins.plugins.Keys | Should -Contain $name
        }
        foreach ($plugin in $agentPlugins.plugins.Values) {
            $plugin.version | Should -Match '^\d+\.\d+\.\d+$'
        }
        $agentPlugins.learnMcp.endpoint | Should -BeExactly 'https://learn.microsoft.com/api/mcp'
        $agentPlugins.learnMcp.pluginCommit | Should -Match '^[0-9a-f]{40}$'
    }

    It 'list every skill the prompts name' {
        $skillsUsed = @($versions.agentPlugins.plugins.Values | ForEach-Object { if ($_.ContainsKey('skillsUsed')) { $_.skillsUsed } })
        $named = @($prompts | ForEach-Object { [regex]::Matches($_.Body, '\b(diagnose-[a-z-]+|read-execution-plan|databasehub-cli)\b') } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        foreach ($skill in $named) {
            $skillsUsed | Should -Contain $skill
        }
    }
}
