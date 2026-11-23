BeforeDiscovery {
    $notebookNames = @('NB_DatabaseHub_Deployment', 'NB_DatabaseHub_LiveActivity')
}

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    $notebookFolder = Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks'

    # The supplied notebook's metadata (PySpark kernel, the LH_DatabaseHub name, session and compute settings), which
    # both notebooks keep exactly (ADR 0014), plus language_info.name: the supplied file lacked it, Fabric's own ipynb
    # export carries it, and Run On Demand Item Job rejects a notebook without it ("Not supported language"). The
    # workspace and lakehouse IDs are gone (ADR 0021): the import binds the ones Resolve-DemoFabricConfig resolves.
    $expectedMetadata = @'
{
 "dependencies": {
  "lakehouse": {
   "default_lakehouse_name": "LH_DatabaseHub"
  }
 },
 "kernel_info": {
  "name": "synapse_pyspark"
 },
 "kernelspec": {
  "display_name": "PySpark",
  "language": "python",
  "name": "synapse_pyspark"
 },
 "language_info": {
  "name": "python"
 },
 "microsoft": {
  "language": "python",
  "language_group": "synapse_pyspark",
  "ms_spell_check": {
   "ms_spell_check_language": "en"
  }
 },
 "nteract": {
  "version": "nteract-front-end@1.0.0"
 },
 "session": {},
 "spark_compute": {
  "compute_id": "/trident/default",
  "session_options": {
   "conf": {
    "spark.synapse.nbs.session.timeout": "1200000"
   }
  }
 }
}
'@ | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Depth 20 -Compress

    function Get-Notebook {
        param([string] $Name)
        $path = Join-Path -Path $notebookFolder -ChildPath "$Name.ipynb"
        $raw = [System.IO.File]::ReadAllText($path)
        $notebook = $raw | ConvertFrom-Json -AsHashtable -Depth 64
        $cells = @($notebook['cells'] | ForEach-Object {
                [pscustomobject]@{
                    Type     = $_['cell_type']
                    Id       = $_['id']
                    Metadata = $_['metadata']
                    Cell     = $_
                    Source   = (@($_['source']) -join '')
                }
            })
        [pscustomobject]@{ Path = $path; Raw = $raw; Notebook = $notebook; Cells = $cells; Code = @($cells | Where-Object { $_.Type -eq 'code' }) }
    }

    # Triple-quoted KQL strings in the code cells that query telemetry tables.
    function Get-KqlBlock {
        param([object] $Notebook)
        foreach ($cell in $Notebook.Code) {
            foreach ($match in [regex]::Matches($cell.Source, '(?s)"""(.*?)"""')) {
                if ($match.Groups[1].Value -match '\bSqlServer[A-Za-z]*\b') {
                    $match.Groups[1].Value
                }
            }
        }
    }

    $python = $null
    foreach ($candidate in 'python3', 'python') {
        $command = Get-Command -Name $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            $PSNativeCommandUseErrorActionPreference = $false
            $null = & $command.Source --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                $python = $command.Source
                break
            }
        }
    }
    # Tests that run the notebook's helpers need pandas; DBHUB_TEST_PYTHON can name a Python 3 that has it (Phase 25b).
    $pandasPython = if ($env:DBHUB_TEST_PYTHON) { $env:DBHUB_TEST_PYTHON } else { $python }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Fabric notebooks in the repo' {
    It 'are exactly the deployment and live-activity notebooks, so the output-stripping test in Repo.Conventions covers both' {
        $names = @(Get-ChildItem -Path $notebookFolder -Filter '*.ipynb' -File | Sort-Object -Property Name | ForEach-Object BaseName)
        $names | Should -Be @('NB_DatabaseHub_Deployment', 'NB_DatabaseHub_LiveActivity')
    }
}

Describe 'The versions of the notebooks the demo published (fabric/notebooks/published-versions.json)' {
    BeforeAll {
        $script:versionsPath = Join-Path -Path $notebookFolder -ChildPath 'published-versions.json'
        $script:names = @(Get-ChildItem -Path $notebookFolder -Filter '*.ipynb' -File | Sort-Object -Property Name | ForEach-Object BaseName)
        $script:current = @{}
        foreach ($name in $names) {
            $text = [System.IO.File]::ReadAllText((Join-Path -Path $notebookFolder -ChildPath "$name.ipynb"))
            $current[$name] = (InModuleScope -ModuleName DbHubDemo -Parameters @{ Text = $text } { Get-DemoNotebookFingerprint -Text $Text }).Sha256
        }

        # DBHUB_WRITE_NOTEBOOK_VERSIONS=1 writes the file: what it lists, every version of each notebook in this checkout's
        # git history (when git answers, with the day each first appeared), and the current one (today, when it's new),
        # oldest first. CI never sets it; a change to a notebook needs it once, and the file committed with the change.
        if ($env:DBHUB_WRITE_NOTEBOOK_VERSIONS -eq '1') {
            $known = @{}
            foreach ($name in $names) {
                $known[$name] = @{}
            }
            if (Test-Path -LiteralPath $versionsPath) {
                $existing = Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json -AsHashtable
                foreach ($name in $names) {
                    foreach ($entry in @($existing['notebooks'][$name])) {
                        if ($entry) {
                            $known[$name][[string]$entry['sha256']] = [string]$entry['since']
                        }
                    }
                }
            }
            $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            # The notebooks hold non-ASCII text, and PowerShell decodes git's output with the console's encoding.
            $consoleEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            try {
                foreach ($name in $names) {
                    $relative = "fabric/notebooks/$name.ipynb"
                    $commits = if ($git) { @(& $git.Source -C $repoRoot log --full-history '--format=%H %as' HEAD -- $relative 2>$null) } else { @() }
                    foreach ($line in $commits) {
                        $commit, $day = ([string]$line).Split(' ', 2)
                        $text = (& $git.Source -C $repoRoot show "${commit}:$relative" 2>$null) -join "`n"
                        if ($LASTEXITCODE -ne 0 -or -not $text) {
                            continue
                        }
                        $sha = (InModuleScope -ModuleName DbHubDemo -Parameters @{ Text = $text } { Get-DemoNotebookFingerprint -Text $Text }).Sha256
                        if ($sha -and (-not $known[$name].ContainsKey($sha) -or [string]::CompareOrdinal($day, $known[$name][$sha]) -lt 0)) {
                            $known[$name][$sha] = $day
                        }
                    }
                    if (-not $known[$name].ContainsKey($current[$name])) {
                        $known[$name][$current[$name]] = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                }
            }
            finally {
                [Console]::OutputEncoding = $consoleEncoding
            }
            $document = [ordered]@{
                about     = 'Every version of the demo''s notebooks in this repository''s history, oldest first, by fingerprint: each cell''s type and code, without outputs, metadata, line endings, trailing spaces, or the workspace, lakehouse, and GitHub values the import sets (Get-DemoNotebookFingerprint). deploy.ps1 brings a workspace''s copy that matches one of them up to date, since nobody edited it, and keeps one that matches none, while fabric.importNotebooks is false. Written by tests/unit/Fabric.Notebooks.Tests.ps1 with DBHUB_WRITE_NOTEBOOK_VERSIONS=1; don''t edit.'
                notebooks = [ordered]@{}
            }
            foreach ($name in $names) {
                $document['notebooks'][$name] = @($known[$name].GetEnumerator() | Sort-Object -Property @{ Expression = { $_.Value } }, @{ Expression = { $_.Key } } | ForEach-Object { [ordered]@{ sha256 = $_.Key; since = $_.Value } })
            }
            $json = (ConvertTo-Json -InputObject $document -Depth 5) -replace "`r`n", "`n"
            [System.IO.File]::WriteAllText($versionsPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'lists each notebook''s current version, so deploy.ps1 can tell an earlier one that nobody edited from an edited one' {
        Test-Path -LiteralPath $versionsPath | Should -BeTrue -Because 'deploy.ps1 reads it while fabric.importNotebooks is false'
        $document = Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json -AsHashtable
        @($document['notebooks'].Keys | Sort-Object) | Should -Be $names
        foreach ($name in $names) {
            $entries = @($document['notebooks'][$name])
            $entries.Count | Should -BeGreaterThan 0
            foreach ($entry in $entries) {
                [string]$entry['sha256'] | Should -Match '^[0-9a-f]{64}$'
                [string]$entry['since'] | Should -Match '^\d{4}-\d{2}-\d{2}$'
            }
            @($entries | ForEach-Object { [string]$_['sha256'] } | Select-Object -Unique).Count | Should -Be $entries.Count -Because 'each version is listed once'
            $days = @($entries | ForEach-Object { [string]$_['since'] })
            ($days -join ' ') | Should -BeExactly ((@($days | Sort-Object -CaseSensitive) -join ' ')) -Because 'the versions go oldest first'
            @($entries | ForEach-Object { [string]$_['sha256'] }) | Should -Contain $current[$name] -Because ('{0}''s current version must be listed, or deploy.ps1 counts a copy of it as edited: run this test with DBHUB_WRITE_NOTEBOOK_VERSIONS=1, and commit the file' -f $name)
        }
    }

    It 'reads the same fingerprint from the file the import binds, and from a copy Fabric gives back as one string per cell with CRLF and outputs' {
        foreach ($name in $names) {
            $path = Join-Path -Path $notebookFolder -ChildPath "$name.ipynb"
            $bound = Get-DemoFabricNotebookDefinition -Path $path -LakehouseId '66666666-6666-6666-6666-666666666666' -LakehouseName 'LH_Other' -LakehouseWorkspaceId '11111111-1111-1111-1111-111111111111' -GitHubRepository 'contoso/fork'
            $boundText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string]$bound.Definition['parts'][0]['payload']))
            $notebook = $boundText | ConvertFrom-Json -AsHashtable
            foreach ($cell in @($notebook['cells'])) {
                $cell['source'] = ((@($cell['source']) -join '') -replace "`n", "`r`n") + "`r`n"
                $cell['metadata'] = @{ microsoft = @{ language = 'python' } }
                if ($cell['cell_type'] -eq 'code') {
                    $cell['execution_count'] = 7
                    $cell['outputs'] = @(@{ output_type = 'stream'; name = 'stdout'; text = @('ran') })
                }
            }
            $notebook['metadata'] = @{ kernel_info = @{ name = 'synapse_pyspark' } }
            $fabricText = ConvertTo-Json -InputObject $notebook -Depth 20
            $fingerprints = InModuleScope -ModuleName DbHubDemo -Parameters @{ Bound = $boundText; Fabric = $fabricText } {
                @((Get-DemoNotebookFingerprint -Text $Bound), (Get-DemoNotebookFingerprint -Text $Fabric))
            }
            $fingerprints[0].Sha256 | Should -Be $current[$name] -Because 'the values the import binds aren''t edits'
            $fingerprints[1].Sha256 | Should -Be $current[$name] -Because 'outputs, metadata, line endings, and a cell''s last newline aren''t edits'
            $fingerprints[1].Bindings['LAKEHOUSE_ID'] | Should -Be '66666666-6666-6666-6666-666666666666'
            $fingerprints[1].Bindings['LAKEHOUSE_NAME'] | Should -Be 'LH_Other'
        }
    }
}

Describe 'Notebook <_>' -ForEach $notebookNames {
    BeforeAll {
        $name = $_
        $nb = Get-Notebook -Name $name
        $parameters = @($nb.Code | Where-Object { @($_.Metadata['tags']) -contains 'parameters' })
        $allCode = ($nb.Code | ForEach-Object Source) -join "`n"
    }

    It 'is valid nbformat 4.5 JSON with unique cell IDs' {
        $nb.Notebook['nbformat'] | Should -Be 4
        $nb.Notebook['nbformat_minor'] | Should -Be 5
        $nb.Cells.Count | Should -BeGreaterThan 10
        foreach ($cell in $nb.Cells) {
            $cell.Type | Should -BeIn @('code', 'markdown')
            $cell.Id | Should -Match '^[A-Za-z0-9_-]{1,64}$'
            $cell.Metadata | Should -BeOfType ([System.Collections.IDictionary])
            foreach ($line in @($cell.Cell['source'])) {
                $line | Should -BeOfType ([string])
            }
            if ($cell.Type -eq 'code') {
                $cell.Cell.Contains('outputs') | Should -BeTrue
                $cell.Cell.Contains('execution_count') | Should -BeTrue
            }
            else {
                $cell.Cell.Contains('outputs') | Should -BeFalse
                $cell.Cell.Contains('execution_count') | Should -BeFalse
            }
        }
        @($nb.Cells.Id | Select-Object -Unique).Count | Should -Be $nb.Cells.Count
    }

    It 'has no outputs or execution counts' {
        foreach ($cell in $nb.Code) {
            @($cell.Cell['outputs']).Count | Should -Be 0
            $cell.Cell['execution_count'] | Should -BeNullOrEmpty
        }
    }

    It 'is already in the form the nbstripout pre-commit hook writes, so the hook changes nothing' {
        $nb.Cells.Id | Should -Be @(0..($nb.Cells.Count - 1) | ForEach-Object { [string]$_ })
        foreach ($cell in $nb.Cells) {
            foreach ($key in 'collapsed', 'scrolled', 'ExecuteTime', 'execution', 'heading_collapsed', 'hidden') {
                $cell.Metadata.Contains($key) | Should -BeFalse
            }
        }
        $nb.Notebook['metadata'].Contains('signature') | Should -BeFalse
        $nb.Notebook['metadata'].Contains('widgets') | Should -BeFalse
        $nb.Raw | Should -Not -Match "`r"
    }

    It 'keeps the supplied notebook kernel and lakehouse metadata exactly' {
        ($nb.Notebook['metadata'] | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $expectedMetadata
    }

    It 'names its language in metadata.language_info.name, which Run On Demand Item Job requires' {
        $nb.Notebook['metadata']['language_info']['name'] | Should -BeExactly 'python'
    }

    It 'runs every code cell on the PySpark kernel' {
        foreach ($cell in $nb.Code) {
            $cell.Metadata['microsoft']['language'] | Should -Be 'python'
            $cell.Metadata['microsoft']['language_group'] | Should -Be 'synapse_pyspark'
        }
    }

    It 'has one parameters cell, tagged for Fabric and papermill, as its first code cell' {
        $parameters.Count | Should -Be 1
        $nb.Code[0].Id | Should -Be $parameters[0].Id
        # No Fabric IDs (ADR 0021): empty defaults that the import fills in, or the session's own at run time.
        $parameters[0].Source | Should -Match '(?m)^WORKSPACE_ID = ""\s*$'
        $parameters[0].Source | Should -Match '(?m)^LAKEHOUSE_ID = ""\s*$'
        $parameters[0].Source | Should -Match '(?m)^LAKEHOUSE_NAME = "LH_DatabaseHub"\s*$'
    }

    It 'defaults GITHUB_REPOSITORY to the public repository, which the import replaces with github.repository (the deployment notebook only)' {
        if ($name -eq 'NB_DatabaseHub_LiveActivity') {
            # 2026-11-14 (ADR 0026): the live-activity notebook has no GitHub path, so no repository to name.
            $parameters[0].Source | Should -Not -Match 'GITHUB_'
            return
        }
        $parameters[0].Source | Should -Match '(?m)^GITHUB_REPOSITORY = "MarcBushong/fabric-database-hub-demo"\s*$'
    }

    It 'runs on Run all: nothing to switch first, and the switch that drops tables stays False (2026-11-03)' {
        # The owner, 2026-11-03: "We should not default to dry runs anywhere. users should be able to just click run all
        # and then it should run."
        if ($name -eq 'NB_DatabaseHub_LiveActivity') {
            # 2026-11-14 (ADR 0026): it changes no activity, so it has no CONFIRM and no stop switch; Run all analyzes and saves.
            $parameters[0].Source | Should -Not -Match '(?m)^(CONFIRM|STOP_ACTIVITY) = '
            $parameters[0].Source | Should -Match '(?m)^SAVE_RESULTS = True\s*$'
        }
        else {
            $parameters[0].Source | Should -Match '(?m)^CONFIRM = True\s*$'
            $switches = @([regex]::Matches($parameters[0].Source, '(?m)^(STOP_ACTIVITY|PURGE_DEMO_TABLES) = (\w+)'))
            $switches.Count | Should -Be 1
            $switches[0].Groups[2].Value | Should -Be 'False'
        }
        $nb.Raw | Should -Not -Match 'Run all\*\* is safe|That''s safe|\(the default\) it only prints a dry run|Leave them False'
    }

    It 'holds no secrets or token-like strings' {
        $patterns = @(
            'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
            '\bgh[pousr]_[A-Za-z0-9]{20,}'
            'github_pat_[A-Za-z0-9_]{20,}'
            '(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{20,}'
            '(?i)AccountKey='
            '(?i)\bsig=[A-Za-z0-9%]{20,}'
            '(?i)\b(?:password|pwd)\s*=\s*[^\s;"''{]+'
            '\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b'
        )
        foreach ($pattern in $patterns) {
            $nb.Raw | Should -Not -Match $pattern
        }
        foreach ($cell in $nb.Cells) {
            Protect-DemoText -Text $cell.Source | Should -BeExactly $cell.Source
        }
        foreach ($assignment in [regex]::Matches($allCode, '(?m)^\s*([A-Z_]*(?:TOKEN|SECRET|PASSWORD)[A-Z_]*)\s*=\s*["'']([^"'']+)["'']')) {
            # Only the name of a Key Vault secret may be set, never a value.
            $assignment.Groups[1].Value | Should -Match '_NAME$'
        }
    }

    It 'never calls private Database Hub routes' {
        $nb.Raw | Should -Not -Match ([regex]::Escape('/v1/databasehub/' + '__private'))
    }

    It 'requests tokens only for the documented notebookutils audience keys' {
        $allCode | Should -Match 'ALLOWED_TOKEN_AUDIENCES = \("storage", "pbi", "keyvault", "kusto"\)'
        foreach ($call in [regex]::Matches($allCode, 'credentials\.getToken\(([^)]*)\)')) {
            $call.Groups[1].Value | Should -Be 'audience'
        }
        $allCode | Should -Match 'if audience not in ALLOWED_TOKEN_AUDIENCES:'
        $uses = [regex]::Matches($allCode, '(?<!def )\bget_token\(([^)]*)\)')
        $uses.Count | Should -BeGreaterThan 0
        foreach ($use in $uses) {
            $use.Groups[1].Value | Should -BeIn @('"pbi"', '"kusto"', '"storage"', '"keyvault"')
        }
        $allCode | Should -Not -Match 'mssparkutils'
        $nb.Raw | Should -Not -Match '(?i)management\.(azure\.com|core\.windows\.net)'
    }

    It 'never prints a token or secret' {
        # Case-sensitive: the token variable is lower case; upper-case names such as GITHUB_TOKEN_SECRET_NAME hold names.
        $allCode | Should -Not -MatchExactly '(?m)\bprint\([^\n]*(get_token\(|getToken\(|getSecret\(|[+%,(]\s*token\b|\{token\})'
        $allCode | Should -Not -MatchExactly '(?m)\bdisplay(_frame)?\([^\n]*(get_token\(|getToken\(|getSecret\()'
    }

    It 'gates every resource-changing cell on CONFIRM, with a flag in the code and the narration' {
        $mutating = 'submit_simulation_request|dispatch_workflow|drop_demo_tables'
        foreach ($definition in [regex]::Matches($allCode, "(?ms)^def ($mutating)\(.*?(?=^\S)")) {
            $definition.Value | Should -Match 'if not \(?CONFIRM'
        }
        if ($name -eq 'NB_DatabaseHub_LiveActivity') {
            # 2026-11-14 (ADR 0026): no cell changes a resource; it writes only the lakehouse's tables.
            $nb.Raw | Should -Not -Match 'RESOURCE-CHANGING CELL|Resource-changing cell'
            $allCode | Should -Not -Match "\b($mutating)\("
            return
        }
        $flagged = 0
        for ($index = 0; $index -lt $nb.Cells.Count; $index++) {
            $cell = $nb.Cells[$index]
            if ($cell.Type -ne 'code') {
                continue
            }
            # Calls outside function bodies: a helper that calls another helper isn't a resource-changing cell by itself.
            $topLevel = [regex]::Replace($cell.Source, '(?ms)^def \w+\(.*?(?=^\S|\z)', '')
            if (-not [regex]::IsMatch($topLevel, "\b($mutating)\(") -and $cell.Source -cnotmatch 'RESOURCE-CHANGING CELL') {
                continue
            }
            $flagged++
            $cell.Source | Should -Match '^# RESOURCE-CHANGING CELL:'
            $cell.Source | Should -Match '(?m)^if not \(?CONFIRM'
            $nb.Cells[$index - 1].Type | Should -Be 'markdown'
            $nb.Cells[$index - 1].Source | Should -Match '\*\*Resource-changing cell\.\*\*'
        }
        $flagged | Should -BeGreaterThan 0
    }

    It 'sends requests only to documented hosts' {
        $allowed = '^(api\.fabric\.microsoft\.com|adx\.centralus\.arcdataservices\.com|api\.github\.com|github\.com|docs\.github\.com|powerbi\.com|dataexplorer\.azure\.com|learn\.microsoft\.com|kusto\.kusto\.windows\.net|.+\.vault\\?\.azure\\?\.net)$'
        foreach ($url in [regex]::Matches($allCode, 'https://([^/"''\s:]+)')) {
            $url.Groups[1].Value | Should -Match $allowed
        }
        $allCode | Should -Match 'TELEMETRY_QUERY_URL = "https://adx\.centralus\.arcdataservices\.com/kusto/v1/rest/query"'
        $allCode | Should -Match 'TELEMETRY_DATABASE = "ArcSqlTelemetry"'
        $allCode | Should -Match 'json=\{"db": TELEMETRY_DATABASE, "csl": str\(kql\)\}'
    }

    It 'falls back to printing the KQL and the documented Azure Data Explorer web UI steps' {
        $allCode | Should -Match 'def print_kql_fallback'
        $allCode | Should -Match 'ADX_WEB_UI = "https://dataexplorer\.azure\.com/"'
        $allCode | Should -Match 'TELEMETRY_CONNECTION_URI = "https://adx\.centralus\.arcdataservices\.com/kusto/"'
    }

    It 'filters every telemetry query on SampleTimeUTC first' {
        $blocks = @(Get-KqlBlock -Notebook $nb)
        $blocks.Count | Should -BeGreaterThan 0
        foreach ($block in $blocks) {
            $firstWhere = @($block -split "`n" | Where-Object { $_ -match '^\s*\|\s*where\b' }) | Select-Object -First 1
            $firstWhere | Should -Match 'SampleTimeUTC'
        }
    }

    It 'takes per-series deltas of cumulative counters and never sums them' {
        foreach ($block in @(Get-KqlBlock -Notebook $nb)) {
            if ($block -match 'SqlServerWaitStats|SqlServerStorageIO|CounterType == 272696576') {
                $block | Should -Match 'prev\('
                $block | Should -Match 'Keep = '
                foreach ($statement in @($block -split "`n(?=\|)")) {
                    if ($statement -match '(?s)^\| summarize .*\bby [^\n]*, SampleTimeUTC$') {
                        # F36: the files of a key added within one sample, by SampleTimeUTC itself, are a cumulative
                        # counter again; the telemetry article's rule 2 forbids a sum across samples, never this one.
                        $statement | Should -Not -Match '\b(avg|max|min)\('
                    }
                    else {
                        $statement | Should -Not -Match 'sum\((WaitTimeMs|WaitingTasksCount|NumOfBytesRead|NumOfBytesWritten|IOStallReadMs|IOStallWriteMs|NumOfReads|NumOfWrites|CounterValue)\)'
                    }
                }
            }
            if ($block -match 'SqlServerWaitStats') {
                $block | Should -Match "WaitCategory !in \('Idle', 'Unknown'\)"
            }
            if ($block -match 'SqlServerPerformanceCounters') {
                $block | Should -Match 'CounterType == '
            }
        }
    }

    It 'compiles as Python 3.10, the oldest Fabric Spark runtime language level' {
        if (-not $python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $script = Join-Path -Path $TestDrive -ChildPath 'compile_cells.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import ast, json, sys
notebook = json.load(open(sys.argv[1], encoding="utf-8"))
for index, cell in enumerate(notebook["cells"]):
    if cell["cell_type"] == "code":
        ast.parse("".join(cell["source"]), filename="cell-%d" % index, feature_version=(3, 10))
print("ok")
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $python $script $nb.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }

    It 'holds no GUID-shaped value: the repo stores no Fabric ID (ADR 0021)' {
        [regex]::Matches($nb.Raw, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Count | Should -Be 0
    }

    It 'takes empty IDs from the session''s workspace and default lakehouse, and keeps resolved ones (ADR 0021)' {
        if (-not $python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # Runs the notebook's own lines: the parameters cell, then _require, _GUID, the ID normalization,
        # _notebookutils, runtime_context, and the fallback, with a stand-in for Fabric's notebookutils.
        $script = Join-Path -Path $TestDrive -ChildPath 'fallback.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import json, re, sys, types
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
params = next(cell for cell in cells if cell.startswith("# Parameters cell"))
lines = next(cell for cell in cells if "def runtime_context():" in cell).split("\n")

def block(pattern):
    for index, line in enumerate(lines):
        if re.match(pattern, line):
            found = [line]
            for following in lines[index + 1:]:
                if following and not following[0].isspace():
                    break
                found.append(following)
            return "\n".join(found)
    raise AssertionError("missing: " + pattern)

start = next(index for index, line in enumerate(lines) if line.startswith("if not WORKSPACE_ID or not LAKEHOUSE_ID:"))
fallback = []
for line in lines[start:]:
    if not line.strip():
        break
    fallback.append(line)
code = "\n".join(["import re", block(r"def _require\("), "\n".join(line for line in lines if re.match(r"_GUID = ", line)),
                  "\n".join(line for line in lines if re.match(r"(WORKSPACE_ID|LAKEHOUSE_ID) = str\(", line)),
                  block(r"def _notebookutils\("), block(r"def runtime_context\("), "\n".join(fallback)])
workspace, lakehouse = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
session = types.SimpleNamespace(runtime=types.SimpleNamespace(context={"currentWorkspaceId": workspace, "defaultLakehouseId": lakehouse}))

ns = {"notebookutils": session}
exec(params, ns)
assert ns["WORKSPACE_ID"] == "" and ns["LAKEHOUSE_ID"] == "", "the repo's defaults must be empty"
exec(code, ns)
assert ns["WORKSPACE_ID"] == workspace and ns["LAKEHOUSE_ID"] == lakehouse, (ns["WORKSPACE_ID"], ns["LAKEHOUSE_ID"])

resolved = {"notebookutils": session}
exec(params, resolved)
resolved["WORKSPACE_ID"], resolved["LAKEHOUSE_ID"] = "33333333-3333-3333-3333-333333333333", "44444444-4444-4444-4444-444444444444"
exec(code, resolved)
assert resolved["WORKSPACE_ID"].startswith("3333") and resolved["LAKEHOUSE_ID"].startswith("4444"), "resolved IDs must win"

broken = {"notebookutils": session}
exec(params, broken)
broken["WORKSPACE_ID"] = "not-an-id"
try:
    exec(code, broken)
    raise AssertionError("a malformed WORKSPACE_ID must be refused")
except ValueError:
    pass
print("ok")
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $python $script $nb.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }
}

Describe 'NB_DatabaseHub_Deployment content' {
    BeforeAll {
        $nb = Get-Notebook -Name 'NB_DatabaseHub_Deployment'
        $markdown = ($nb.Cells | Where-Object Type -EQ 'markdown' | ForEach-Object Source) -join "`n"
        $allCode = ($nb.Code | ForEach-Object Source) -join "`n"
    }

    It 'narrates section <_>' -ForEach @(
        'Parameters', 'Overview and value', 'Architecture', 'Security and permissions', 'Prerequisites check', 'Cost reminders',
        'Deployment status', 'SQL Server, Azure Arc, and Azure SQL', 'Hub telemetry validation', 'Hub discovery and per-target validation',
        'Agent skills and the Database Agent', 'Optional mirroring', 'Data generation and scenarios',
        'Hub investigation, Database Agent prompts, and expected findings', 'Remediation, reset and rerun, start and stop',
        'Validation summary', 'Troubleshooting', 'Cleanup', 'Limitations and preview disclosures', 'Official references', 'Next steps'
    ) {
        $markdown | Should -Match ('(?m)^## \d+\. ' + [regex]::Escape($_) + '$')
    }

    It 'validates Fabric with the pbi token and Hub telemetry with the kusto token' {
        $allCode | Should -Match 'fabric_get\("/workspaces/%s" % WORKSPACE_ID\)'
        $allCode | Should -Match 'fabric_get\("/workspaces/%s/lakehouses/%s"'
        $allCode | Should -Match 'fabric_list_items\(WORKSPACE_ID, "Notebook"\)'
        $allCode | Should -Match 'HUB\.TELEMETRY\.TOKEN'
        foreach ($target in 'T1', 'T2', 'T3') {
            $allCode | Should -Match ('"HUB\.TELEMETRY\." \+ target|HUB\.TELEMETRY\.' + $target)
        }
    }

    It 'records results with the six statuses only' {
        $allCode | Should -Match 'STATUSES = \("Pass", "Fail", "Warning", "Manual action required", "Not supported", "Not selected"\)'
        foreach ($status in [regex]::Matches($allCode, 'add_result\([^)]*?"(Pass|Fail|Warning|Manual action required|Not supported|Not selected|[A-Z][a-z]+)",')) {
            $status.Groups[1].Value | Should -BeIn @('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')
        }
    }

    It 'writes validation_results and telemetry_snapshots to the default lakehouse' {
        $allCode | Should -Match 'write_delta\("validation_results"'
        $allCode | Should -Match 'write_delta\("telemetry_snapshots"'
    }

    It 'links to the live-activity notebook' {
        $markdown | Should -Match 'NB_DatabaseHub_LiveActivity'
    }

    It 'checks the session, the workspace, and the lakehouse against the resolved or the session''s IDs (ADR 0021)' {
        # With empty parameters, WORKSPACE_ID and LAKEHOUSE_ID are the session's own (the fallback test above), so in
        # another tenant these comparisons hold, and the checks are Pass.
        $allCode | Should -Match '(?m)^    if current_workspace == WORKSPACE_ID:$'
        $allCode | Should -Match '(?m)^    if default_lakehouse == LAKEHOUSE_ID:$'
        $allCode | Should -Match 'status, workspace, error = fabric_get\("/workspaces/%s" % WORKSPACE_ID\)'
        $allCode | Should -Match '(?m)^if LAKEHOUSE_ID:\n    status, lakehouse, error = fabric_get\("/workspaces/%s/lakehouses/%s" % \(WORKSPACE_ID, LAKEHOUSE_ID\)\)'
        $allCode | Should -Match 'notebooks, error = fabric_list_items\(WORKSPACE_ID, "Notebook"\)'
        $markdown | Should -Match 'the scripts'' import binds the notebook to it'
    }

    It 'never drops a table on Run all with its defaults, and drops all thirteen and the staged RCA evidence only with PURGE_DEMO_TABLES and CONFIRM (2026-11-03, ADR 0031)' {
        if (-not $python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # Runs the notebook's own parameters and cleanup cells, with stand-ins for Spark that record each DROP, and for
        # notebookutils.fs that records each removal.
        $script = Join-Path -Path $TestDrive -ChildPath 'cleanup.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import json, sys, types
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
params = next(cell for cell in cells if cell.startswith("# Parameters cell"))
cleanup = next(cell for cell in cells if cell.startswith("# RESOURCE-CHANGING CELL: drops"))

class Catalog:
    def tableExists(self, name):
        return True

class Session:
    def __init__(self):
        self.catalog = Catalog()
        self.dropped = []
    def sql(self, text):
        self.dropped.append(text)

class Files:
    def __init__(self):
        self.removed = []
    def exists(self, path):
        return True
    def ls(self, path):
        return []
    def rm(self, path, recurse=False):
        self.removed.append((path, recurse))
        return True

def run(**overrides):
    ns = {}
    exec(params, ns)
    ns.update(overrides)
    session, files = Session(), Files()
    ns.update(_spark=lambda: session, _notebookutils=lambda: types.SimpleNamespace(fs=files), redact=str)
    exec(cleanup, ns)
    return ns, session.dropped, files.removed

ns, dropped, removed = run()
assert ns["CONFIRM"] is True and ns["PURGE_DEMO_TABLES"] is False, (ns["CONFIRM"], ns["PURGE_DEMO_TABLES"])
assert dropped == [] and removed == [], (dropped, removed)
ns, dropped, removed = run(PURGE_DEMO_TABLES=True)
assert len(dropped) == 13 and all(text.startswith("DROP TABLE IF EXISTS ") for text in dropped), dropped
assert removed == [("Files/rca/inbox", True), ("Files/rca", False)], removed
workspace, lakehouse = "-".join(("1" * 8, "2" * 4, "3" * 4, "4" * 4, "5" * 12)), "-".join(("6" * 8, "7" * 4, "8" * 4, "9" * 4, "a" * 12))
ns, dropped, removed = run(PURGE_DEMO_TABLES=True, WORKSPACE_ID=workspace, LAKEHOUSE_ID=lakehouse)
assert removed == [("abfss://%s@onelake.dfs.fabric.microsoft.com/%s/Files/rca/inbox" % (workspace, lakehouse), True),
                   ("abfss://%s@onelake.dfs.fabric.microsoft.com/%s/Files/rca" % (workspace, lakehouse), False)], removed
ns, dropped, removed = run(PURGE_DEMO_TABLES=True, CONFIRM=False)
assert dropped == [] and removed == [], (dropped, removed)
print("ok")
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $python $script $nb.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }
}

Describe 'NB_DatabaseHub_LiveActivity content' {
    BeforeAll {
        $nb = Get-Notebook -Name 'NB_DatabaseHub_LiveActivity'
        $markdown = ($nb.Cells | Where-Object Type -EQ 'markdown' | ForEach-Object Source) -join "`n"
        $allCode = ($nb.Code | ForEach-Object Source) -join "`n"
    }

    It 'narrates section <_>' -ForEach @(
        'Parameters', 'Helpers', 'This session', 'Telemetry access', 'Estate pulse', 'Locks and blocking', 'Overall consumption',
        'Correlation: scenario windows and telemetry', 'See it in the Hub', 'Optional: Real-Time Dashboard', 'Persist', 'Next steps'
    ) {
        $markdown | Should -Match ('(?m)^## \d+\. ' + [regex]::Escape($_) + '$')
    }

    It 'uses no GitHub and changes no activity: no workflow dispatch, no token, no Key Vault, no P9 (2026-11-14, ADR 0026)' {
        foreach ($pattern in 'api\.github\.com', 'workflow_dispatch', 'getSecret\(', 'GITHUB_', 'KEY_VAULT_URL', '\bCONFIRM\b', 'STOP_ACTIVITY', 'demo-control\.yml', 'build_simulation_request', 'submit_simulation_request') {
            # Case-sensitive: scenario_runs keeps its github_run_id and github_run_url columns, empty, for the report's schema.
            $allCode | Should -Not -MatchExactly $pattern -Because $pattern
        }
        $markdown | Should -Not -Match 'P9|demo-control\.yml|workflow_dispatch'
        $markdown | Should -Match 'uses no GitHub Actions'
        $markdown | Should -Match 'NB_DatabaseHub_Control'
        $allCode | Should -Match 'profile\.startswith\("incident:"\)'
    }

    It 'lists the Real-Time Dashboards in the resolved or the session''s workspace (ADR 0021)' {
        $allCode | Should -Match 'dashboards, error = fabric_list_items\(WORKSPACE_ID, "KQLDashboard"\)'
        # The fallback sits in the helpers cell, which runs before the dashboard cell.
        $helpers = [array]::FindIndex([object[]]$nb.Code, [Predicate[object]] { param($cell) $cell.Source -match 'if not WORKSPACE_ID or not LAKEHOUSE_ID:' })
        $dashboard = [array]::FindIndex([object[]]$nb.Code, [Predicate[object]] { param($cell) $cell.Source -match 'fabric_list_items\(WORKSPACE_ID, "KQLDashboard"\)' })
        $helpers | Should -BeGreaterOrEqual 0
        $dashboard | Should -BeGreaterThan $helpers
    }

    It 'records a control session and its beats as scenario windows, and saves a session only once (ADR 0026)' {
        if (-not $python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # The session helpers from part 3 and the session cell, with stand-ins for what needs pandas or Spark.
        $script = Join-Path -Path $TestDrive -ChildPath 'session.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import datetime as dt, json, re, sys, types
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
part3 = next(cell for cell in cells if cell.startswith("# Helpers, part 3"))
session_cell = next(cell for cell in cells if cell.startswith("# This session"))
functions = "\n".join(re.findall(r"(?m)^_SCENARIO_ID = .*$", part3) + re.findall(r"(?ms)^def (?:parse_session_plan|session_requests|session_beats)\(.*?(?=^\S|\Z)", part3))

def run(session_id, plan, saved=False, rca=False, rca_only=False):
    exits, saves = [], []
    # The Incident RCA's evidence (ADR 0031): part 4's save, which reports RCA.EVIDENCE, as a stand-in.
    ns = {"json": json, "re": re, "dt": dt, "RUN_ID": "run-1", "NOTEBOOK_NAME": "NB_DatabaseHub_LiveActivity", "SELECTED_TARGETS": ["T1", "T2", "T3"],
          "SESSION_REQUESTS": [], "SAVE_RESULTS": True, "SESSION_ID": session_id, "SESSION_PLAN": plan,
          "RCA_ONLY": rca_only, "RCA_STATE": {"passed": rca}, "save_rca_evidence": lambda: saves.append(True),
          "rca_exit_value": lambda: "RCA.EVIDENCE Pass: Wrote 2 evidence document(s).",
          "_parse_utc": lambda text: dt.datetime.fromisoformat(text.replace("Z", "+00:00")),
          "utc_now": lambda: dt.datetime(2026, 11, 14, 16, 0, tzinfo=dt.timezone.utc),
          "session_saved": lambda session: saved,
          "_notebookutils": lambda: types.SimpleNamespace(notebook=types.SimpleNamespace(exit=lambda value: exits.append(value)))}
    exec(functions, ns)
    exec(session_cell, ns)
    ns["RCA_SAVES"] = len(saves)
    return ns, exits

sid = "0123456789abcdef0123456789abcdef"
plan = json.dumps({"version": 1, "sessionId": sid, "startUtc": "2026-11-14T14:00:00Z", "endUtc": "2026-11-14T15:30:00Z", "beats": [
    {"target": "T1", "scenario": "blocking-chain", "startUtc": "2026-11-14T14:04:00Z", "endUtc": "2026-11-14T14:14:00Z"},
    {"target": "T3", "scenario": "resource-governance", "startUtc": "2026-11-14T14:05:00Z", "endUtc": "2026-11-14T14:17:00Z"},
    {"target": "T4", "scenario": "replica-lag", "startUtc": "2026-11-14T14:59:00Z", "endUtc": "2026-11-14T15:08:00Z"},
    {"target": "T1", "scenario": "DROP TABLE", "startUtc": "2026-11-14T14:20:00Z", "endUtc": "2026-11-14T14:30:00Z"},
    {"target": "T2", "scenario": "cpu-pressure", "startUtc": "2026-11-14T14:30:00Z", "endUtc": "2026-11-14T14:20:00Z"}]})
report = {}
ns, exits = run("", "")
report["none"] = {"rows": len(ns["SESSION_REQUESTS"]), "exits": exits}
ns, exits = run(sid, plan)
report["session"] = {"rows": [[row["request_id"], row["target"], row["profile"], row["duration_minutes"], row["dispatch_mode"]] for row in ns["SESSION_REQUESTS"]],
                     "save": ns["SAVE_RESULTS"], "exits": exits}
ns, exits = run(sid, plan, saved=True)
report["saved"] = {"rows": len(ns["SESSION_REQUESTS"]), "save": ns["SAVE_RESULTS"], "exits": exits, "rca": ns["RCA_SAVES"]}
ns, exits = run(sid, plan, saved=True, rca=True)
report["savedWithRca"] = {"rows": len(ns["SESSION_REQUESTS"]), "save": ns["SAVE_RESULTS"], "exits": exits, "rca": ns["RCA_SAVES"]}
ns, exits = run(sid, "", rca=True, rca_only=True)
report["rcaOnly"] = {"rows": len(ns["SESSION_REQUESTS"]), "save": ns["SAVE_RESULTS"], "exits": exits, "rca": ns["RCA_SAVES"]}
ns, exits = run(sid, plan)
report["session"]["rca"] = ns["RCA_SAVES"]
ns, exits = run(sid, "not json")
report["bad"] = {"rows": [row["profile"] for row in ns["SESSION_REQUESTS"]], "exits": exits}
print(json.dumps(report))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $python $script $nb.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $report = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $report.none.rows | Should -Be 0
        @($report.none.exits) | Should -BeNullOrEmpty
        # The session row, then its beats on T1 to T3 as incident windows; T4's beat shows in its own metrics, and a beat
        # with a bad scenario or window is left out.
        $rows = @($report.session.rows)
        $rows.Count | Should -Be 3
        $rows[0] | Should -Be @('session:0123456789abcdef0123456789abcdef', 'all', 'session', 90, 'session')
        $rows[1] | Should -Be @('session:0123456789abcdef0123456789abcdef:00', 'T1', 'incident:blocking-chain', 10, 'session')
        $rows[2] | Should -Be @('session:0123456789abcdef0123456789abcdef:01', 'T3', 'incident:resource-governance', 12, 'session')
        $report.session.save | Should -BeTrue
        # A session already saved: nothing is recorded or saved, and the run ends there, with the exit value a control
        # notebook from before the Incident RCA reads. Its RCA evidence is written all the same (each document once), and the
        # exit value adds RCA.EVIDENCE only when evidence was passed (ADR 0031).
        $report.saved.rows | Should -Be 0
        $report.saved.save | Should -BeFalse
        @($report.saved.exits) | Should -Be @('Session 0123456789abcdef0123456789abcdef is already saved.')
        $report.saved.rca | Should -Be 1
        $report.savedWithRca.save | Should -BeFalse
        @($report.savedWithRca.exits) | Should -Be @('Session 0123456789abcdef0123456789abcdef is already saved. RCA.EVIDENCE Pass: Wrote 2 evidence document(s).')
        $report.savedWithRca.rca | Should -Be 1
        # RCA_ONLY: an earlier session's evidence alone, then the run ends with RCA.EVIDENCE; nothing else is recorded or saved.
        $report.rcaOnly.rows | Should -Be 0
        $report.rcaOnly.save | Should -BeFalse
        @($report.rcaOnly.exits) | Should -Be @('RCA.EVIDENCE Pass: Wrote 2 evidence document(s).')
        $report.rcaOnly.rca | Should -Be 1
        # A session not saved yet writes its evidence in the persist cell, not here.
        $report.session.rca | Should -Be 0
        # A plan it can't read keeps the session's own row out too (no window), and never stops the run.
        @($report.bad.rows) | Should -BeNullOrEmpty
        @($report.bad.exits) | Should -BeNullOrEmpty
    }

    It 'records the Database Agent beat''s times and its database_agent finding: CPU before and after the run''s response (2026-11-18)' {
        if (-not $python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $script = Join-Path -Path $TestDrive -ChildPath 'agent.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import datetime as dt, json, re, sys
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
part3 = next(cell for cell in cells if cell.startswith("# Helpers, part 3"))
functions = "\n".join(re.findall(r"(?m)^_SCENARIO_ID = .*$", part3) + re.findall(r"(?ms)^def (?:parse_session_plan|session_requests|session_beats|agent_beat_finding)\(.*?(?=^\S|\Z)", part3))
utc = dt.timezone.utc
ns = {"json": json, "re": re, "dt": dt, "RUN_ID": "run-1", "NOTEBOOK_NAME": "NB_DatabaseHub_LiveActivity", "SELECTED_TARGETS": ["T1", "T2", "T3"],
      "_parse_utc": lambda text: dt.datetime.fromisoformat(text.replace("Z", "+00:00")),
      "utc_now": lambda: dt.datetime(2026, 11, 18, 16, 0, tzinfo=utc)}
exec(functions, ns)
sid = "fedcba9876543210fedcba9876543210"
plan = json.dumps({"version": 1, "sessionId": sid, "startUtc": "2026-11-18T14:00:00Z", "endUtc": "2026-11-18T15:30:00Z", "beats": [
    {"target": "T3", "scenario": "plan-regression", "startUtc": "2026-11-18T14:30:00Z", "endUtc": "2026-11-18T15:00:00Z",
     "agent": True, "regressUtc": "2026-11-18T14:33:00Z", "respondUtc": "2026-11-18T14:55:30Z"},
    {"target": "T3", "scenario": "plan-regression", "startUtc": "2026-11-18T15:15:00Z", "endUtc": "2026-11-18T15:25:00Z",
     "agent": True, "regressUtc": "2026-11-18T15:20:00Z", "respondUtc": "2026-11-18T15:40:00Z"},
    {"target": "T1", "scenario": "blocking-chain", "startUtc": "2026-11-18T14:04:00Z", "endUtc": "2026-11-18T14:14:00Z"}]})
session = ns["parse_session_plan"](sid, plan)
beats = ns["session_beats"](session)
agent = next(beat for _, beat in beats if beat.get("agent"))
respond = dt.datetime(2026, 11, 18, 14, 55, 30, tzinfo=utc)

def points(before, after):
    bins = [respond.replace(second=0) + dt.timedelta(minutes=minute) for minute in range(-12, 10)]
    return [(moment, before if moment < respond else after) for moment in bins]

late = dt.datetime(2026, 11, 18, 15, 35, tzinfo=utc)
report = {"agent": [bool(beat.get("agent")) for _, beat in beats], "ids": [request_id for request_id, _ in beats],
          "messages": [row["message"] for row in ns["session_requests"](session)],
          "pass": ns["agent_beat_finding"](sid, agent, points(84.0, 22.0), late),
          "flat": ns["agent_beat_finding"](sid, agent, points(50.0, 46.0), late),
          "early": ns["agent_beat_finding"](sid, agent, points(84.0, 22.0), dt.datetime(2026, 11, 18, 14, 58, tzinfo=utc)),
          "none": ns["agent_beat_finding"](sid, agent, [], None),
          "nan": ns["agent_beat_finding"](sid, agent, points(float("nan"), float("nan")), None)}
print(json.dumps(report))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $python $script $nb.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $report = ($output | Select-Object -Last 1) | ConvertFrom-Json
        # Only a beat whose times fall in its window, in order, is the agent beat; each beat keeps its request ID.
        @($report.agent) | Should -Be @($false, $true, $false)
        @($report.ids) | Should -Be @(0, 1, 2 | ForEach-Object { 'session:fedcba9876543210fedcba9876543210:{0:d2}' -f $_ })
        $report.messages[2] | Should -BeExactly 'Session fedcba98''s Database Agent beat: the plan regresses at 14:33 UTC; the run''s response forces the last good plan at 14:55 UTC.'
        $report.messages[3] | Should -BeExactly 'Session fedcba98''s showcase beat.'
        # Pass: CPU fell by a quarter or 10 points, with the times and both averages as evidence.
        $report.pass[0] | Should -Be 'Pass'
        $report.pass[1] | Should -BeExactly 'Database Agent loop on T3: the plan regressed at 14:33 UTC and the run''s response forced the last good plan at 14:55 UTC; T3''s CPU fell from 84% to 22%.'
        $report.pass[2].cpuBeforePercent | Should -Be 84
        $report.pass[2].cpuAfterPercent | Should -Be 22
        $report.pass[2].sessionId | Should -Be 'fedcba9876543210fedcba9876543210'
        foreach ($name in 'regressUtc', 'respondUtc', 'beforeStartUtc', 'beforeEndUtc', 'afterStartUtc', 'afterEndUtc') {
            $report.pass[2].$name | Should -Not -BeNullOrEmpty -Because $name
        }
        # A Warning when CPU didn't fall, when the run read its telemetry too early, or when it has none (or only NaN).
        $report.flat[0] | Should -Be 'Warning'
        $report.flat[1] | Should -Match 'didn''t fall \(50% before, 46% after\)'
        foreach ($case in 'early', 'none', 'nan') {
            $report.$case[0] | Should -Be 'Warning' -Because $case
            $report.$case[1] | Should -Match 'isn''t in the telemetry this run read' -Because $case
        }
    }

    It 'calls the agent finding in section 8, and keys each correlation finding by its whole request ID (2026-11-18)' {
        $correlation = @($nb.Code | Where-Object { $_.Source -match '^# Correlation:' })[0].Source
        # Every beat of a session starts "session:<id>", so a shortened key made one finding of a session's beats per target.
        $correlation | Should -Match 'window\["request_id"\], evidence=evidence'
        $correlation | Should -Not -Match 'request_id"\]\[:12\]'
        $correlation | Should -Match 'add_finding\("database_agent", beat\["target"\]'
        $correlation | Should -Match 'agent_beat_finding\(SESSION\["id"\], beat, points, WINDOW_END\)'
    }

    It 'saves telemetry_snapshots, analysis_findings, and the report tables, then a session''s rows in scenario_runs, last' {
        $persist = @($nb.Code | Where-Object { $_.Source -match '^# Persist:' })[0].Source
        $persist | Should -Match 'write_delta\("telemetry_snapshots"'
        $persist | Should -Match 'write_delta\("analysis_findings"'
        $persist.IndexOf('prepare_report_tables()') | Should -BeLessThan $persist.IndexOf('write_delta("scenario_runs"')
        $persist | Should -Match 'write_delta\("scenario_runs", SESSION_ROWS\)'
    }

    It 'saves a demo session once: the next run completes a save that a cancel cut off, table by table, and a first save is unchanged (R907)' {
        # The app's Stop now cancels the control's run, which may be saving a session's history; Stop now then saves that
        # session again, without its plan. The setup, section 3, and persist cells run here against a lakehouse in memory.
        $python = $pandasPython
        if (-not $python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        $PSNativeCommandUseErrorActionPreference = $false
        $null = & $python -c 'import pandas' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because 'pandas is not installed for that Python (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        $script = Join-Path -Path $TestDrive -ChildPath 'save_once.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import contextlib, io, json, re, sys, types
import pandas as pd

sys.modules.setdefault("requests", types.SimpleNamespace(RequestException=Exception))
# Spark isn't here: the schema's types as stand-ins, and the default lakehouse's tables in memory (Lake).
spark_types = types.ModuleType("pyspark.sql.types")
for name in ("StringType", "BooleanType", "TimestampType", "DoubleType", "LongType", "IntegerType", "DateType"):
    setattr(spark_types, name, type(name, (), {}))
spark_types.StructField = lambda name, kind, nullable: name
spark_types.StructType = list
pyspark_sql = types.ModuleType("pyspark.sql")
pyspark_sql.types = spark_types
sys.modules.update({"pyspark": types.ModuleType("pyspark"), "pyspark.sql": pyspark_sql, "pyspark.sql.types": spark_types})

code = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
setup = [cell for cell in code if cell.startswith(("# Parameters cell", "# Helpers, part"))]
session_cell = next(cell for cell in code if cell.startswith("# This session"))
persist = next(cell for cell in code if cell.startswith("# Persist:"))


class Cancelled(BaseException):
    """A cancel ends the run where it is; no except Exception in the notebook catches it."""


class Rows:
    def __init__(self, lake, rows):
        self.lake, self.rows = lake, rows

    def filter(self, condition):
        column, value = re.fullmatch(r"(\w+) = '([^']*)'", condition).groups()
        self.lake.reads.append(column)
        return Rows(self.lake, [row for row in self.rows if row.get(column) == value])

    def limit(self, count):
        return Rows(self.lake, self.rows[:count])

    def count(self):
        return len(self.rows)


class Lake:
    def __init__(self):
        self.tables, self.log, self.reads, self.cancel_at, self.columns = {}, [], [], None, {}
        self.catalog = types.SimpleNamespace(tableExists=lambda name: name in self.tables)
        self.conf = types.SimpleNamespace(get=lambda key: "UTC", set=lambda key, value: None)

    def table(self, name):
        rows = Rows(self, self.tables[name])
        rows.schema = types.SimpleNamespace(fields=[types.SimpleNamespace(name=column) for column, _ in self.columns[name]])
        return rows

    def createDataFrame(self, data, schema):
        lake, rows = self, [dict(zip(schema, values)) for values in data]

        class Writer:
            def format(self, name):
                return self

            def mode(self, name):
                return self

            def option(self, key, value):
                return self

            def saveAsTable(self, table):
                if table == lake.cancel_at:
                    raise Cancelled(table)
                lake.log.append("append %s %d" % (table, len(rows)))
                lake.tables.setdefault(table, []).extend(rows)

        return types.SimpleNamespace(coalesce=lambda count: types.SimpleNamespace(write=Writer()))

    def sql(self, statement):
        result = []
        delete = re.fullmatch(r"DELETE FROM (\w+) WHERE run_id = '([^']*)'", statement)
        if delete:
            table = self.tables[delete.group(1)]
            kept = [row for row in table if row.get("run_id") != delete.group(2)]
            self.log.append("delete %s %d" % (delete.group(1), len(table) - len(kept)))
            table[:] = kept
        elif statement.startswith("CREATE TABLE IF NOT EXISTS "):
            self.tables.setdefault(statement.split()[5], [])
        elif statement.startswith("SELECT COUNT(*) AS n FROM "):
            result = [{"n": 0}]
        elif statement.startswith("DESCRIBE DETAIL "):
            result = [{"numFiles": 1}]
        else:
            raise AssertionError("unexpected statement: " + statement)
        return types.SimpleNamespace(collect=lambda: result)


SID = "0123456789abcdef0123456789abcdef"
PLAN = json.dumps({"version": 1, "sessionId": SID, "startUtc": "2026-11-19T14:00:00Z", "endUtc": "2026-11-19T15:30:00Z", "beats": [
    {"target": "T1", "scenario": "blocking-chain", "startUtc": "2026-11-19T14:04:00Z", "endUtc": "2026-11-19T14:14:00Z"},
    {"target": "T3", "scenario": "plan-regression", "startUtc": "2026-11-19T14:30:00Z", "endUtc": "2026-11-19T15:00:00Z",
     "agent": True, "regressUtc": "2026-11-19T14:33:00Z", "respondUtc": "2026-11-19T14:55:30Z"}]})
BASE = pd.Timestamp("2026-11-19T14:00:00Z")


def run(lake, session_id, plan, cancel_at=None, again=False):
    """One notebook run: its setup, section 3, what sections 5 to 8 add, and the persist cell, which a cancel cuts off at
    a table's write. Returns its run ID, whether it was cut off, its writes, and how many tables it kept."""
    ns = {}
    exec(setup[0], ns)
    ns.update(SESSION_ID=session_id, SESSION_PLAN=plan)
    for cell in setup[1:]:
        exec(cell, ns)
    lake.columns = ns["TABLE_COLUMNS"]
    ns.update(_spark=lambda: lake, runtime_context=lambda: {"defaultLakehouseId": "lakehouse"},
              _notebookutils=lambda: types.SimpleNamespace(notebook=types.SimpleNamespace(exit=lambda value: None)))
    beat = ("session:%s:00" % SID, BASE + pd.Timedelta(minutes=4), BASE + pd.Timedelta(minutes=14))

    def incident_rows():
        if plan:
            return [ns["_incident_row"]("request:" + beat[0], "Recorded request", "T1", "blocking", beat[1], beat[2], 3.0,
                                        scenario="blocking-chain", request_id=beat[0])], []
        # Without the plan, the beat's blocking has no recorded window to explain it.
        return [], [ns["_incident_row"]("detected:T1:blocking:" + beat[1].strftime("%Y%m%dT%H%M"), "Detected signal", "T1",
                                        "blocking", beat[1], beat[2], 3.0)]

    def merge(session, recorded, detected):
        table = lake.tables["incident_windows"]
        for row in recorded + detected:
            table[:] = [item for item in table if item["incident_key"] != row["incident_key"]] + [dict(row)]
        lake.log.append("merge incident_windows %d" % len(recorded + detected))
        return len(recorded + detected), 0

    ns.update(incident_window_rows=incident_rows, merge_incident_windows=merge)
    before, printed, cut = len(lake.log), io.StringIO(), False
    with contextlib.redirect_stdout(printed):
        exec(session_cell, ns)
        cpu = pd.DataFrame({"Target": "T1", "Bucket": [BASE + pd.Timedelta(minutes=minute) for minute in range(6)],
                            "AvgCPU": [20.0, 85.0, 90.0, 30.0, 25.0, 20.0]})
        ns["add_snapshot"]("cpu", cpu, ns["WINDOW_START"], ns["WINDOW_END"], metrics=["AvgCPU"], units={"AvgCPU": "percent"})
        ru = pd.DataFrame({"Target": "T5", "Bucket": [BASE + pd.Timedelta(minutes=minute) for minute in range(3)],
                           "NormalizedRUConsumption": [40.0, 100.0, 60.0]})
        ns["add_snapshot"]("cosmosdb", ru, ns["WINDOW_START"], ns["WINDOW_END"], metrics=["NormalizedRUConsumption"])
        ns["add_finding"]("consumption", "T1", "Warning", "T1's CPU peaked at 90%.", "cpu")
        ns["add_finding"]("cosmosdb", "T5", "Pass", "T5's metrics were added.", "capture")
        if plan:
            ns["add_finding"]("correlation", "T1", "Pass", "blocking-chain on T1: expected signal observed.", beat[0], request_id=beat[0])
            ns["add_finding"]("database_agent", "T3", "Pass", "Database Agent loop on T3: its CPU fell.", "session:%s:01" % SID,
                              request_id="session:%s:01" % SID)
        lake.cancel_at = cancel_at
        try:
            exec(persist, ns)
            if again:
                exec(persist, ns)
        except Cancelled:
            cut = True
    lake.cancel_at = None
    return {"runId": ns["RUN_ID"], "cut": cut, "writes": lake.log[before:], "kept": printed.getvalue().count("so this run keeps them")}


def state(lake):
    rows = [row for table in lake.tables.values() for row in table]
    return {"counts": {table: len(rows) for table, rows in lake.tables.items()},
            "runIds": sorted({row["run_id"] for row in rows}),
            "agentFindings": sum(1 for row in lake.tables.get("analysis_findings", []) if row["analysis"] == "database_agent"),
            "detected": sum(1 for row in lake.tables.get("incident_windows", []) if row["source"] == "Detected signal"),
            "deleted": sum(int(entry.split()[-1]) for entry in lake.log if entry.startswith("delete ")),
            "runIdReads": lake.reads.count("run_id")}


report = {}
lake = Lake()
first = run(lake, SID, PLAN)
report["first"] = dict(run=first, **state(lake))
lake = Lake()
cutoff = run(lake, SID, PLAN, cancel_at="scenario_runs")
report["stopNow"] = dict(cutoff=cutoff, again=run(lake, SID, ""), **state(lake))
lake = Lake()
cutoff = run(lake, SID, PLAN, cancel_at="analysis_findings")
second = run(lake, SID, PLAN)
report["resumed"] = dict(cutoff=cutoff, second=second, third=run(lake, SID, ""), **state(lake))
lake = Lake()
report["twice"] = dict(run=run(lake, SID, PLAN, again=True), **state(lake))
lake = Lake()
runs = [run(lake, "", ""), run(lake, "", "")]
report["noSession"] = dict(runs=runs, **state(lake))
print(json.dumps(report))
'@
        $output = & $python $script $nb.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $report = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $runId = 'session-0123456789abcdef0123456789abcdef'
        # One copy of the session's rows: 9 telemetry rows (T1's CPU and T5's RU), 4 findings, its beat's incident window,
        # and its scenario_runs rows when a run with its plan saved them.
        $oneCopy = {
            param($State, [int] $Sessions)
            foreach ($pair in @(@('telemetry_snapshots', 9), @('analysis_findings', 4), @('incident_windows', 1), @('scenario_runs', $Sessions))) {
                $State.counts.($pair[0]) | Should -Be $pair[1] -Because $pair[0]
            }
        }

        # A first save: the same writes in the same order, the session's rows last, nothing deleted or kept, under the
        # session's run ID.
        $report.first.run.runId | Should -Be $runId
        $report.first.run.cut | Should -BeFalse
        @($report.first.run.writes | Where-Object { $_ -notlike 'delete *' }) | Should -Be @('append telemetry_snapshots 9', 'append analysis_findings 4', 'merge incident_windows 1', 'append scenario_runs 3')
        $report.first.deleted | Should -Be 0
        $report.first.run.kept | Should -Be 0
        & $oneCopy $report.first 3
        @($report.first.runIds) | Should -Be @($runId)

        # Cut off before scenario_runs, then Stop now's run, without the plan: it keeps what the earlier run saved, one copy
        # of each row with its database_agent finding, and records no detected twin of the beat's recorded window.
        $report.stopNow.cutoff.cut | Should -BeTrue
        @($report.stopNow.again.writes) | Should -BeNullOrEmpty
        $report.stopNow.again.kept | Should -Be 3
        & $oneCopy $report.stopNow 0
        $report.stopNow.agentFindings | Should -Be 1
        $report.stopNow.detected | Should -Be 0
        @($report.stopNow.runIds) | Should -Be @($runId)

        # Cut off after telemetry_snapshots: the next run saves the rest once, the session's rows last, and a run after that
        # finds the session saved and saves nothing.
        $report.resumed.cutoff.cut | Should -BeTrue
        @($report.resumed.cutoff.writes) | Should -Be @('append telemetry_snapshots 9')
        $report.resumed.second.kept | Should -Be 1
        @($report.resumed.second.writes | Where-Object { $_ -notlike 'delete *' }) | Should -Be @('append analysis_findings 4', 'merge incident_windows 1', 'append scenario_runs 3')
        @($report.resumed.third.writes) | Should -BeNullOrEmpty
        & $oneCopy $report.resumed 3
        $report.resumed.deleted | Should -Be 0

        # The persist cell run twice in one run replaces that run's rows in every table.
        & $oneCopy $report.twice 3
        $report.twice.deleted | Should -Be 16
        $report.twice.run.kept | Should -Be 0

        # An analysis without a session: its own run ID each time, no read for an earlier run, and each run's rows, as before.
        @($report.noSession.runIds).Count | Should -Be 2
        foreach ($id in $report.noSession.runIds) {
            $id | Should -Match '^\d{8}T\d{6}Z-[0-9a-f]{8}$'
        }
        $report.noSession.counts.telemetry_snapshots | Should -Be 18
        $report.noSession.counts.analysis_findings | Should -Be 4
        $report.noSession.runIdReads | Should -Be 0
        $report.noSession.deleted | Should -Be 0
    }

    It 'analyzes blocking, consumption, and T3 log-rate governance with charts' {
        foreach ($signal in "'Processes blocked'", "'Active Transactions'", "'Number of Deadlocks/sec'", 'SqlServerActiveSessions', 'SqlServerCPUUtilization', 'SqlServerMemoryUtilization', 'SqlServerStorageIO', 'SqlServerDatabaseStorageUtilization', 'Log Rate Governor', 'PAGEIOLATCH') {
            $allCode | Should -Match ([regex]::Escape($signal))
        }
        $allCode | Should -Match 'import matplotlib\.pyplot as plt'
        $allCode | Should -Match 'axvspan'
    }

    It 'prints one line for each table and chart in a reference run, as Run all''s history save runs it: no display, no chart, no table value (2026-11-16 live finding)' {
        # Live: Fabric's reference run (notebookutils.notebook.run) failed on a cell's result, a JSON parse error on a bare
        # token, so the history fell back to a job that queued behind Run all's own Spark session.
        $PSNativeCommandUseErrorActionPreference = $false
        if (-not $python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $script = Join-Path -Path $TestDrive -ChildPath 'reference_run.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import ast, contextlib, io, json, sys, types

notebook = json.load(open(sys.argv[1], encoding="utf-8"))
code = ["".join(cell["source"]) for cell in notebook["cells"] if cell["cell_type"] == "code"]
wanted = {"_notebookutils", "runtime_context", "in_reference_run", "display_frame", "plot_panels"}
DISPLAYED = []
namespace = {"display": DISPLAYED.append,
             "notebookutils": types.SimpleNamespace(runtime=types.SimpleNamespace(context={"isReferenceRun": True}))}
for source in code:
    for node in ast.parse(source).body:
        if isinstance(node, ast.FunctionDef) and node.name in wanted:
            exec(compile(ast.Module(body=[node], type_ignores=[]), "notebook", "exec"), namespace)
            wanted.discard(node.name)
if wanted:
    raise SystemExit("missing notebook functions: %s" % sorted(wanted))
sys.modules["matplotlib"] = None  # a chart would fail to import


class Frame:
    columns = ["Target", "Value", "Note"]
    empty = False

    def __init__(self, rows):
        self.rows = rows

    def __len__(self):
        return len(self.rows)

    def to_string(self, index=False):
        return "\n".join(str(row) for row in self.rows)


secret_like = '{"sessionId":"' + "e" * 32 + '","series":[]}'
frame = Frame([["T1", float("nan"), secret_like], ["T2", float("inf"), "x"], ["T3", 1.5, "y"]])
out = io.StringIO()
with contextlib.redirect_stdout(out):
    reference = namespace["in_reference_run"]()
    namespace["REFERENCE_RUN"] = reference
    namespace["display_frame"](frame)
    namespace["plot_panels"]("Locks and blocking", [("Blocked processes", frame, "count")])
    namespace["REFERENCE_RUN"] = False
    namespace["display_frame"](frame)
print(json.dumps({"reference": reference, "displayed": len(DISPLAYED), "printed": out.getvalue()}))
'@
        $live = Get-Notebook -Name 'NB_DatabaseHub_LiveActivity'
        $output = & $python $script $live.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $report = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $report.reference | Should -BeTrue
        $report.displayed | Should -Be 1 -Because 'only a run that isn''t a reference run displays the table'
        $report.printed | Should -Match '\(3 row\(s\) of Target, Value, Note; the history report and the Insights app show them\.\)'
        $report.printed | Should -Match 'Locks and blocking: 1 panel\(s\), in the history report and the Insights app; a reference run draws no chart\.'
        $report.printed | Should -Not -Match '(?i)\bnan\b|\binf\b|eeeeeeee|matplotlib'
    }

    It 'describes signals for Database Agent prompts, never expected answers' {
        $markdown | Should -Match 'never a specific answer'
        $allCode | Should -Match 'Look for:'
    }

    It 'reads T1''s and T2''s CPU from SQLProcessCPUPercent and T3''s from AvgCPUPercent (Phase 25b)' {
        # Phase 25a (2026-10-23): AvgCPUPercent was 0 in every T1 and T2 sample, so no CPU window was ever found there.
        $extend = "| extend CpuPercent = iff(ResourceType =~ 'servers/databases', AvgCPUPercent, coalesce(todouble(SQLProcessCPUPercent), AvgCPUPercent))"
        foreach ($name in 'CPU_SUMMARY_KQL', 'CPU_TIMELINE_KQL') {
            $block = [regex]::Match($allCode, '(?s)' + $name + ' = prelude \+ """(.*?)"""').Groups[1].Value
            $block | Should -Match ([regex]::Escape($extend)) -Because $name
            $block | Should -Not -Match 'avg\(AvgCPUPercent\)|max\(AvgCPUPercent\)' -Because $name
        }
    }

    It 'finds the CPU windows of T1 and T2 in rows shaped like Phase 25a''s, which AvgCPUPercent never showed' {
        # The notebook's own to_series and signal_episodes run on 10-second SqlServerCPUUtilization rows like those of
        # 2026-10-23 20:00-21:28Z, binned as CPU_TIMELINE_KQL bins them, with CpuPercent computed as its extend line
        # says (pinned by the previous test). Needs Python 3 with pandas: set DBHUB_TEST_PYTHON to its python.
        $interpreter = $pandasPython
        $PSNativeCommandUseErrorActionPreference = $false
        if (-not $interpreter) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        $null = & $interpreter -c 'import pandas' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because 'pandas is not installed for that Python (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        $script = Join-Path -Path $TestDrive -ChildPath 'cpu_episodes.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import ast, json, re, sys
from datetime import datetime, timedelta

import pandas as pd

notebook = json.load(open(sys.argv[1], encoding="utf-8"))
code = ["".join(cell["source"]) for cell in notebook["cells"] if cell["cell_type"] == "code"]
namespace = {"pd": pd}
wanted = {"to_series", "signal_episodes"}
for source in code:
    for node in ast.parse(source).body:
        if isinstance(node, ast.FunctionDef) and node.name in wanted:
            exec(compile(ast.Module(body=[node], type_ignores=[]), "notebook", "exec"), namespace)
            wanted.discard(node.name)
if wanted:
    raise SystemExit("missing notebook functions: %s" % sorted(wanted))
parameters = code[0]
threshold = float(re.search(r"(?m)^EPISODE_CPU_PERCENT = (\d+)", parameters).group(1))
min_bins = int(re.search(r"(?m)^EPISODE_MIN_BINS = (\d+)", parameters).group(1))

def rows():
    # T1 (SQL Server on a VM) and T2 (Arc): AvgCPUPercent 0 throughout, as in every live sample; SQLProcessCPUPercent
    # at 99 (T1) and 97 (T2) while CPU pressure ran. T3 (Azure SQL Database): AvgCPUPercent at the tier limit.
    start = datetime(2026, 10, 23, 20, 0, 0)
    for target, resource_type, name, instance, step, busy, busy_sql, busy_avg in (
        ("T1", "virtualMachines", "sqlvm01", "MSSQLSERVER", 10, (20, 10, 20, 24), 99, 0.0),
        ("T2", "machines", "arcsql01", "MSSQLSERVER", 10, (20, 10, 20, 29), 97, 0.0),
        ("T3", "servers/databases", "azuresql01-test01/ContosoCare", "azuresql01-test01", 15, (20, 17, 20, 36), 0, 99.91),
    ):
        busy_from = start.replace(hour=busy[0], minute=busy[1])
        busy_to = start.replace(hour=busy[2], minute=busy[3])
        at = start
        while at < start + timedelta(minutes=88):
            hot = busy_from <= at < busy_to
            sql = busy_sql if hot else 6
            avg = busy_avg if hot else (3.0 if resource_type == "servers/databases" else 0.0)
            yield {"SampleTimeUTC": at, "Target": target, "ResourceType": resource_type, "ResourceName": name,
                   "SqlServerInstanceName": instance, "AvgCPUPercent": avg, "SQLProcessCPUPercent": sql,
                   "OtherProcessCPUPercent": 1.0, "IdleCPUPercent": max(0, 99 - sql)}
            at += timedelta(seconds=step)

def timeline(cpu_percent):
    frame = pd.DataFrame(list(rows()))
    frame["CpuPercent"] = frame.apply(cpu_percent, axis=1)
    frame["Bucket"] = frame["SampleTimeUTC"].dt.floor("1min")
    return frame.groupby(["Target", "ResourceName", "SqlServerInstanceName", "Bucket"], as_index=False).agg(
        AvgCPU=("CpuPercent", "mean"), MaxCPU=("CpuPercent", "max"))

def episodes(frame):
    found = namespace["signal_episodes"](namespace["to_series"](frame, "AvgCPU", "max"), threshold, 1, min_bins)
    return {target: [{"start": e["start"].isoformat(), "end": e["end"].isoformat(), "peak": round(e["peak"], 2), "bins": e["bins"]}
                     for e in found if e["target"] == target] for target in ("T1", "T2", "T3")}

before = lambda r: r["AvgCPUPercent"]
after = lambda r: r["AvgCPUPercent"] if r["ResourceType"].lower() == "servers/databases" else (
    r["AvgCPUPercent"] if pd.isna(r["SQLProcessCPUPercent"]) else float(r["SQLProcessCPUPercent"]))
print(json.dumps({"threshold": threshold, "minBins": min_bins, "before": episodes(timeline(before)), "after": episodes(timeline(after))}))
'@
        $output = & $interpreter $script $nb.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable
        $result['before']['T1'].Count | Should -Be 0 -Because 'AvgCPUPercent stays at 0 on SQL Server, the live finding'
        $result['before']['T2'].Count | Should -Be 0
        $result['before']['T3'].Count | Should -Be 1
        $t1 = @($result['after']['T1'])
        $t2 = @($result['after']['T2'])
        $t1.Count | Should -Be 1
        $t1[0]['peak'] | Should -Be 99
        $t1[0]['start'] | Should -Be ([datetime]::new(2026, 10, 23, 20, 10, 0))
        $t1[0]['end'] | Should -Be ([datetime]::new(2026, 10, 23, 20, 24, 0))
        $t2.Count | Should -Be 1
        $t2[0]['peak'] | Should -Be 97
        $t2[0]['end'] | Should -Be ([datetime]::new(2026, 10, 23, 20, 29, 0))
        ($result['after']['T3'] | ConvertTo-Json -Compress) | Should -Be ($result['before']['T3'] | ConvertTo-Json -Compress) -Because 'T3 stays on AvgCPUPercent'
    }

    It 'adds T4''s Azure Monitor metrics only from POSTGRES_METRICS, empty by default, before the persist cell, without a network call (ADR 0025)' {
        $parameters = @($nb.Code | Where-Object { @($_.Metadata['tags']) -contains 'parameters' })[0].Source
        $parameters | Should -Match '(?m)^POSTGRES_METRICS = ""$'
        $nb.Code[1].Source | Should -Match '(?m)^POSTGRES_METRICS = str\(POSTGRES_METRICS or ""\)\.strip\(\)$'
        $t4 = [array]::FindIndex([object[]]$nb.Code, [Predicate[object]] { param($cell) $cell.Source -match '^# T4 \(PostgreSQL\):' })
        $persist = [array]::FindIndex([object[]]$nb.Code, [Predicate[object]] { param($cell) $cell.Source -match '^# Persist:' })
        $t4 | Should -BeGreaterThan 0
        $t4 | Should -BeLessThan $persist -Because 'the persist cell saves the rows it adds, with everything else'
        $nb.Code[$t4].Source | Should -Match '(?m)^    POSTGRES_CAPTURE = record_postgres_metrics\(POSTGRES_METRICS\)$'
        $markdown | Should -Match '(?m)^### T4: PostgreSQL and its read replica \(Azure Monitor\)$'
        $allCode | Should -Match 'POSTGRES_TARGETS = \{"primary": "T4", "replica": "T4-replica"\}'
        $allCode | Should -Match '(?m)^POSTGRES_ANALYSIS = "postgresql"$'
        foreach ($name in 'parse_postgres_metrics', 'postgres_snapshot_rows', 'postgres_findings', 'record_postgres_metrics', 'postgres_series_frame') {
            $body = [regex]::Match($allCode, "(?ms)^def $name\(.*?(?=^\S)").Value
            $body | Should -Not -BeNullOrEmpty -Because $name
            $body | Should -Not -Match 'https://|requests\.|get_token|getSecret|write_delta|_spark\(' -Because $name
        }
    }

    It 'leaves the replica''s catch-up after a restart out of the lag finding''s peak, and says so, with the Nov 13 data (2026-11-16)' {
        # Live, 2026-11-13: the safety stop stopped the replica at 00:38:46Z, start-demo.ps1 started it first at 00:57Z, and
        # Azure Monitor's lag read 1,380 s at 01:00 (the time since its last replay until T4 wrote again); the replica-lag beat
        # then peaked at 219 s. The finding named 1,380 s. Needs Python 3 with pandas: set DBHUB_TEST_PYTHON to its python.
        $interpreter = $pandasPython
        $PSNativeCommandUseErrorActionPreference = $false
        if (-not $interpreter) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        $null = & $interpreter -c 'import pandas' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because 'pandas is not installed for that Python (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        $script = Join-Path -Path $TestDrive -ChildPath 'catch-up.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import contextlib, io, json, sys, types
sys.modules.setdefault("requests", types.SimpleNamespace(RequestException=Exception))
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
ns = {}
exec(next(cell for cell in cells if cell.startswith("# Parameters cell")), ns)
with contextlib.redirect_stdout(io.StringIO()):
    for index, cell in enumerate(cells):
        if cell.startswith("# Helpers, part"):
            exec(compile(cell, "cell-%d" % index, "exec"), ns)

def document(lag):
    return json.dumps({"version": 1, "capturedUtc": "2026-11-14T01:40:00Z", "startUtc": "2026-11-14T00:00:00Z", "endUtc": "2026-11-14T01:40:00Z",
                       "windowMinutes": 100, "intervalMinutes": 5,
                       "servers": [{"role": "primary", "resourceName": "pgflex01-rrpigs", "sku": "Standard_D4ds_v5"},
                                   {"role": "replica", "resourceName": "pgreplica01-rrpigs", "sku": "Standard_D4ds_v5"}],
                       "series": [{"role": "replica", "resourceName": "pgreplica01-rrpigs", "metric": "physical_replication_delay_in_seconds",
                                   "aggregation": "Maximum", "unit": "Seconds", "points": [["2026-11-14T%s:00Z" % at, value] for at, value in lag]}]})

def lag_finding(lag):
    capture, error = ns["parse_postgres_metrics"](document(lag))
    found = next(item for item in ns["postgres_findings"](capture) if item["key"] == "lag")
    return {"status": found["status"], "finding": found["finding"], "evidence": {key: value for key, value in found["evidence"].items() if key != "resourceName"}}

# Running before the stop, nothing while it was stopped, its catch-up at 01:00, then the replica-lag beat.
nov13 = [("00:20", 3), ("00:25", 2), ("00:30", 4), ("00:35", 5), ("01:00", 1380), ("01:05", 67), ("01:10", 218), ("01:15", 219), ("01:20", 3)]
# The window starts after the stop, so the series starts with the catch-up.
late = [("00:50", 1950), ("00:55", 9), ("01:00", 188)]
# Only the catch-up: no point since the window's start, so it reads at least that long.
only = [("01:00", 3900)]
# A replica created during the window: its first points are small, and a beat's peak right after a short gap stays.
fresh = [("00:30", 0.4), ("00:35", 1), ("00:40", 120), ("00:45", 2), ("01:05", 300), ("01:10", 2)]
print(json.dumps({"nov13": lag_finding(nov13), "late": lag_finding(late), "only": lag_finding(only), "fresh": lag_finding(fresh)}))
'@
        $output = & $interpreter $script $nb.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable

        $result['nov13']['status'] | Should -Be 'Warning'
        $result['nov13']['finding'] | Should -Be 'Read replica lag on pgreplica01-rrpigs peaked at 219.0 s at 2026-11-14 01:15 UTC (a Warning at 60 s or more). Left out: 1 point from 2026-11-14 01:00 UTC, up to 1380.0 s, the replica''s catch-up after its restart (the time since its last replay until T4 wrote again), not replication lag.'
        $result['nov13']['evidence']['peakSeconds'] | Should -Be 219
        $result['nov13']['evidence']['catchUpPoints'] | Should -Be 1
        $result['nov13']['evidence']['catchUpPeakSeconds'] | Should -Be 1380
        $result['nov13']['evidence']['points'] | Should -Be 9 -Because 'the rows keep every point; only the finding leaves it out'

        $result['late']['finding'] | Should -Match '^Read replica lag on pgreplica01-rrpigs peaked at 188\.0 s at 2026-11-14 01:00 UTC .* Left out: 1 point from 2026-11-14 00:50 UTC, up to 1950\.0 s'
        $result['only']['status'] | Should -Be 'Pass'
        $result['only']['finding'] | Should -Be 'Read replica lag on pgreplica01-rrpigs: only the replica''s catch-up after its restart, up to 3900.0 s from 2026-11-14 01:00 UTC (the time since its last replay until T4 wrote again), not replication lag.'
        $result['only']['evidence'].ContainsKey('peakSeconds') | Should -BeFalse
        $result['fresh']['finding'] | Should -Be 'Read replica lag on pgreplica01-rrpigs peaked at 300.0 s at 2026-11-14 01:05 UTC (a Warning at 60 s or more).' -Because 'a gap whose next point is under half its length is lag, not catch-up'
        $result['fresh']['evidence']['catchUpPoints'] | Should -Be 0
    }

    It 'turns the document Get-DemoPostgresHistoryParameter writes into postgresql rows and findings, and says so in one line without one (ADR 0025)' {
        # Get-DemoPostgresHistoryParameter's own JSON, from a fake Azure CLI, goes through the notebook's helpers and its T4
        # cell. Needs Python 3 with pandas: set DBHUB_TEST_PYTHON to its python.
        $interpreter = $pandasPython
        $PSNativeCommandUseErrorActionPreference = $false
        if (-not $interpreter) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        $null = & $interpreter -c 'import pandas' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because 'pandas is not installed for that Python (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        # Five-minute values from 17:00 UTC; the 18:00 interval has no value yet.
        $script:pgPoints = @{
            'pgflex01-abc123'    = @{ cpu_percent = @(43.27, 91.26, 50); memory_percent = @(30.15); active_connections = @(12, 37); physical_replication_delay_in_bytes = @(184); connections_failed = @(0, 3, 1) }
            'pgreplica01-abc123' = @{ physical_replication_delay_in_seconds = @(6, 241.37, 2); cpu_percent = @(10.26); active_connections = @(1) }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $text = @($ArgumentList) -join ' '
            if ($text -match 'flexibleServers/(pg\w+-abc123)/providers/Microsoft\.Insights/metrics') {
                $server = $Matches[1]
                $index = [array]::IndexOf([string[]]@($ArgumentList), '--url-parameters')
                $query = Get-Content -LiteralPath ([string]$ArgumentList[$index + 1]).Substring(1) -Raw | ConvertFrom-Json -AsHashtable
                $field = ([string]$query['aggregation']).ToLowerInvariant()
                $units = @{ cpu_percent = 'Percent'; memory_percent = 'Percent'; physical_replication_delay_in_seconds = 'Seconds'; physical_replication_delay_in_bytes = 'Bytes' }
                $metrics = foreach ($name in ([string]$query['metricnames']).Split(',')) {
                    $values = @($script:pgPoints[$server][$name])
                    $data = @(for ($i = 0; $i -lt $values.Count; $i++) { [ordered]@{ timeStamp = ('2026-11-13T17:{0:00}:00Z' -f ($i * 5)); $field = $values[$i] } }) + @([ordered]@{ timeStamp = '2026-11-13T18:00:00Z' })
                    @{ name = @{ value = $name }; unit = $(if ($units.ContainsKey($name)) { $units[$name] } else { 'Count' }); timeseries = @(@{ data = $data }) }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject @{ value = @($metrics) } -Depth 10 -Compress); StdErr = '' }
            }
            if ($text -match 'flexibleServers/(pg\w+-abc123)\?') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject @{ name = $Matches[1]; sku = @{ name = 'Standard_D4ds_v5' } } -Compress); StdErr = '' }
            }
            throw "unexpected Azure CLI call: $text"
        }
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # An obviously fake ID: every group repeats one character.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $capture = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoPostgresHistoryParameter -Config $Config -DeploymentId 'abc123' -WindowMinutes 60 -NowUtc ([datetime]::new(2026, 11, 13, 18, 2, 37, [System.DateTimeKind]::Utc)) }
        $capture.Status | Should -Be 'Pass'
        $capture.PointCount | Should -Be 15
        $documentPath = Join-Path -Path $TestDrive -ChildPath 'postgres-metrics.json'
        Set-Content -LiteralPath $documentPath -Value $capture.Json -Encoding utf8NoBOM -NoNewline
        $script = Join-Path -Path $TestDrive -ChildPath 'postgres.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import contextlib, io, json, sys, types
sys.modules.setdefault("requests", types.SimpleNamespace(RequestException=Exception))
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
document = open(sys.argv[2], encoding="utf-8").read()
parameters = next(cell for cell in cells if cell.startswith("# Parameters cell"))
t4_cell = next(cell for cell in cells if cell.startswith("# T4 (PostgreSQL):"))

def t4(ns):
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        exec(compile(t4_cell, "t4", "exec"), ns)
    return printed.getvalue()

def run(metrics):
    ns = {}
    exec(parameters, ns)
    ns["POSTGRES_METRICS"] = metrics
    with contextlib.redirect_stdout(io.StringIO()):
        for index, cell in enumerate(cells):
            if cell.startswith("# Helpers, part"):
                exec(compile(cell, "cell-%d" % index, "exec"), ns)
    return ns, t4(ns)

def summary(ns, printed):
    text = lambda value: value.strftime("%Y-%m-%d %H:%M")
    rows = [row for row in ns["SNAPSHOT_ROWS"] if row["analysis"] == "postgresql"]
    return {
        "printed": printed.strip().splitlines(),
        "rows": [{"target": row["target"], "resource": row["resource_name"], "type": row["resource_type"], "metric": row["metric"],
                  "bucket": text(row["bucket_utc"]), "value": row["value"], "unit": row["unit"], "windowStart": text(row["window_start_utc"]),
                  "windowEnd": text(row["window_end_utc"]), "reportDate": str(ns["report_date"]("telemetry_snapshots", row))} for row in rows],
        "findings": {item["finding_id"]: {"status": item["status"], "finding": item["finding"], "target": item["target"],
                                          "reportDate": str(ns["report_date"]("analysis_findings", item))}
                     for item in ns["FINDINGS"] if item["analysis"] == "postgresql"},
    }

full, printed = run(document)
again = t4(full)
partial = json.loads(document)
partial["servers"] = [server for server in partial["servers"] if server["role"] == "primary"]
partial["series"] = [series for series in partial["series"] if series["role"] == "primary"]
# As live (F34, 2026-11-21): connection-surge at the limit, and Azure Monitor's failed connections at 0 in every interval.
live = json.loads(document)
for series in live["series"]:
    if series["metric"] == "connections_failed":
        series["points"] = [[point[0], 0] for point in series["points"]]
# A capture whose connections stay under the slots clients can use.
under = json.loads(document)
for series in under["series"]:
    if series["metric"] == "active_connections" and series["role"] == "primary":
        series["points"] = [[point[0], min(point[1], 34)] for point in series["points"]]
print(json.dumps({
    "full": summary(full, printed),
    "again": summary(full, again),
    "primaryOnly": summary(*run(json.dumps(partial))),
    "live": summary(*run(json.dumps(live))),
    "under": summary(*run(json.dumps(under))),
    "invalid": summary(*run('{"version": 2, "servers": [], "series": []}')),
    "empty": summary(*run("")),
}))
'@
        $output = & $interpreter $script $nb.Path $documentPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable

        $full = $result['full']
        $full['rows'].Count | Should -Be 15 -Because 'one row per point the collector kept'
        @($full['rows'] | ForEach-Object { $_['target'] } | Sort-Object -Unique) | Should -Be @('T4', 'T4-replica')
        @($full['rows'] | ForEach-Object { $_['type'] } | Sort-Object -Unique) | Should -Be @('flexibleServers')
        $lag = @($full['rows'] | Where-Object { $_['metric'] -eq 'physical_replication_delay_in_seconds' })
        @($lag | ForEach-Object { '{0}={1}' -f $_['bucket'], [string]$_['value'] }) | Should -Be @('2026-11-13 17:00=6', '2026-11-13 17:05=241.4', '2026-11-13 17:10=2')
        $lag[0]['target'] | Should -Be 'T4-replica'
        $lag[0]['resource'] | Should -Be 'pgreplica01-abc123'
        $lag[0]['unit'] | Should -Be 'seconds'
        $lag[0]['windowStart'] | Should -Be '2026-11-13 17:00'
        $lag[0]['windowEnd'] | Should -Be '2026-11-13 18:02'
        $lag[0]['reportDate'] | Should -Be '2026-11-13'
        @($full['rows'] | Where-Object { $_['metric'] -eq 'connections_failed' } | ForEach-Object { '{0}:{1}:{2}' -f $_['target'], $_['unit'], [string]$_['value'] }) | Should -Be @('T4:connections:0', 'T4:connections:3', 'T4:connections:1')
        @($full['rows'] | Where-Object { $_['metric'] -eq 'cpu_percent' -and $_['target'] -eq 'T4' } | ForEach-Object { $_['value'] }) | Should -Be @(43.3, 91.3, 50)
        $full['findings'].Count | Should -Be 5
        foreach ($id in 'postgresql.T4.capture', 'postgresql.T4-replica.lag', 'postgresql.T4.cpu', 'postgresql.T4.connections', 'postgresql.T4.connections_failed') {
            $full['findings'].ContainsKey($id) | Should -BeTrue -Because $id
        }
        $full['findings']['postgresql.T4.capture']['status'] | Should -Be 'Pass'
        $full['findings']['postgresql.T4.capture']['finding'] | Should -Match '^Azure Monitor metrics of T4 pgflex01-abc123 \(Standard_D4ds_v5\) and its read replica pgreplica01-abc123 \(Standard_D4ds_v5\) from 2026-11-13 17:00 to 2026-11-13 18:02 UTC, every 5 minutes: 8 series, 15 points\.$'
        $full['findings']['postgresql.T4-replica.lag']['status'] | Should -Be 'Warning' -Because '241 seconds is over the 60-second threshold'
        $full['findings']['postgresql.T4-replica.lag']['finding'] | Should -Be 'Read replica lag on pgreplica01-abc123 peaked at 241.4 s at 2026-11-13 17:05 UTC (a Warning at 60 s or more).'
        $full['findings']['postgresql.T4.cpu']['status'] | Should -Be 'Warning'
        $full['findings']['postgresql.T4.cpu']['finding'] | Should -Be 'T4''s CPU on pgflex01-abc123 peaked at 91.3% at 2026-11-13 17:05 UTC (a Warning at 80% or more).'
        $full['findings']['postgresql.T4.connections_failed']['status'] | Should -Be 'Warning'
        $full['findings']['postgresql.T4.connections_failed']['finding'] | Should -Match '^Failed connections on T4 \(pgflex01-abc123\): 4 from 2026-11-13 17:00 to 2026-11-13 17:15 UTC, at most 3 in one 5-minute interval'
        # F34 (live, 2026-11-21): connection-surge's signal is T4's connections at the slots clients can use, never its failed
        # connections, which leave out a client refused at the connection limit; they say so whatever their count.
        $leaveOut = 'They leave out a client refused at the connection limit (too many connections), so T4''s active connections show a connection surge.'
        $full['findings']['postgresql.T4.connections_failed']['finding'] | Should -BeLike ('* ' + $leaveOut)
        $full['findings']['postgresql.T4.connections']['status'] | Should -Be 'Warning'
        $full['findings']['postgresql.T4.connections']['finding'] | Should -Be 'T4''s active connections on pgflex01-abc123 peaked at 37 at 2026-11-13 17:05 UTC, at or above the 35 slots clients can use (max_connections 50, less 15 reserved; a Warning at 35 or more). At the limit, PostgreSQL refuses a new client (too many connections), and Azure Monitor''s failed connections don''t count that refusal.'
        $result['live']['findings']['postgresql.T4.connections']['status'] | Should -Be 'Warning'
        $result['live']['findings']['postgresql.T4.connections_failed']['status'] | Should -Be 'Pass'
        $result['live']['findings']['postgresql.T4.connections_failed']['finding'] | Should -Be ('Azure Monitor counted no failed connections on T4 (pgflex01-abc123) from 2026-11-13 17:00 to 2026-11-13 17:15 UTC. ' + $leaveOut)
        $result['under']['findings']['postgresql.T4.connections']['status'] | Should -Be 'Pass'
        $result['under']['findings']['postgresql.T4.connections']['finding'] | Should -Be 'T4''s active connections on pgflex01-abc123 peaked at 34 at 2026-11-13 17:05 UTC, under the 35 slots clients can use (max_connections 50, less 15 reserved; a Warning at 35 or more).'
        $full['findings']['postgresql.T4.cpu']['reportDate'] | Should -Be '2026-11-13'
        $full['printed'] | Should -Contain 'T4''s metrics from 2026-11-13 17:00 to 2026-11-13 18:02 UTC, every 5 minutes:'

        # Running the cell again replaces its rows and findings instead of adding to them.
        $result['again']['rows'].Count | Should -Be 15
        $result['again']['findings'].Count | Should -Be 5

        $primaryOnly = $result['primaryOnly']
        @($primaryOnly['rows'] | Where-Object { $_['target'] -eq 'T4-replica' }).Count | Should -Be 0
        $primaryOnly['findings']['postgresql.T4-replica.lag']['status'] | Should -Be 'Not selected'
        $primaryOnly['findings']['postgresql.T4-replica.lag']['finding'] | Should -Match 'exists only during a session'
        $primaryOnly['findings']['postgresql.T4.capture']['status'] | Should -Be 'Pass'

        $result['invalid']['rows'].Count | Should -Be 0
        @($result['invalid']['findings'].Keys) | Should -Be @('postgresql.T4.capture')
        $result['invalid']['findings']['postgresql.T4.capture']['status'] | Should -Be 'Fail'
        $result['invalid']['findings']['postgresql.T4.capture']['finding'] | Should -Be 'T4''s metrics in POSTGRES_METRICS weren''t added: it isn''t a version 1 document.'

        $result['empty']['rows'].Count | Should -Be 0
        $result['empty']['findings'].Count | Should -Be 0
        @($result['empty']['printed']).Count | Should -Be 1
        @($result['empty']['printed'])[0] | Should -Match '^T4''s PostgreSQL metrics weren''t passed in \(POSTGRES_METRICS is empty\), so this run adds none: \./scripts/stop-demo\.ps1 -SaveHistory and \./scripts/deploy\.ps1 pass them'
    }

    It 'adds T5''s Azure Monitor metrics only from COSMOS_METRICS, empty by default, after T4''s and before the persist cell, without a network call (ADR 0027)' {
        $parameters = @($nb.Code | Where-Object { @($_.Metadata['tags']) -contains 'parameters' })[0].Source
        $parameters | Should -Match '(?m)^COSMOS_METRICS = ""$'
        $nb.Code[1].Source | Should -Match '(?m)^COSMOS_METRICS = str\(COSMOS_METRICS or ""\)\.strip\(\)$'
        $t4 = [array]::FindIndex([object[]]$nb.Code, [Predicate[object]] { param($cell) $cell.Source -match '^# T4 \(PostgreSQL\):' })
        $t5 = [array]::FindIndex([object[]]$nb.Code, [Predicate[object]] { param($cell) $cell.Source -match '^# T5 \(Azure Cosmos DB\):' })
        $persist = [array]::FindIndex([object[]]$nb.Code, [Predicate[object]] { param($cell) $cell.Source -match '^# Persist:' })
        $t5 | Should -BeGreaterThan $t4
        $t5 | Should -BeLessThan $persist -Because 'the persist cell saves the rows it adds, with everything else'
        $nb.Code[$t5].Source | Should -Match '(?m)^    COSMOS_CAPTURE = record_cosmos_metrics\(COSMOS_METRICS\)$'
        $markdown | Should -Match '(?m)^### T5: Azure Cosmos DB \(Azure Monitor\)$'
        $allCode | Should -Match '(?m)^COSMOS_ANALYSIS = "cosmosdb"$'
        $allCode | Should -Match '(?m)^COSMOS_TARGET = "T5"$'
        foreach ($name in 'parse_cosmos_metrics', 'cosmos_snapshot_rows', 'cosmos_throttle_episodes', 'cosmos_findings', 'record_cosmos_metrics', 'cosmos_series_frame') {
            $body = [regex]::Match($allCode, "(?ms)^def $name\(.*?(?=^\S)").Value
            $body | Should -Not -BeNullOrEmpty -Because $name
            $body | Should -Not -Match 'https://|requests\.|get_token|getSecret|write_delta|_spark\(' -Because $name
        }
        # A session's T5 beats are kept with the session, as T4's are; T5's own metrics show them.
        $allCode | Should -Match ([regex]::Escape('beat.get("target") not in ("T1", "T2", "T3", "T4", "T5")'))
    }

    It 'turns the document Get-DemoCosmosHistoryParameter writes into cosmosdb rows and findings, with each throttling episode and its recovery, and says so in one line without one (ADR 0027)' {
        # Get-DemoCosmosHistoryParameter's own JSON, from a fake Azure CLI, goes through the notebook's helpers and its T5
        # cell. Needs Python 3 with pandas: set DBHUB_TEST_PYTHON to its python.
        $interpreter = $pandasPython
        $PSNativeCommandUseErrorActionPreference = $false
        if (-not $interpreter) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        $null = & $interpreter -c 'import pandas' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because 'pandas is not installed for that Python (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        # One-minute values from 17:02 UTC: an ru-storm wave saturates T5 from 17:05 to 17:09 and is throttled at 17:05,
        # 17:06, and 17:08; Azure Monitor sends no point for the 429s' other minutes, and none for 18:01 yet.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $text = @($ArgumentList) -join ' '
            if ($text -match 'databaseAccounts/cosmos01-abc123/providers/Microsoft\.Insights/metrics') {
                $index = [array]::IndexOf([string[]]@($ArgumentList), '--url-parameters')
                $query = Get-Content -LiteralPath ([string]$ArgumentList[$index + 1]).Substring(1) -Raw | ConvertFrom-Json -AsHashtable
                $field = ([string]$query['aggregation']).ToLowerInvariant()
                $name = [string]$query['metricnames']
                $hourly = $query['interval'] -eq 'PT1H'
                $data = if ($hourly) {
                    @([ordered]@{ timeStamp = '2026-11-13T17:00:00Z'; $field = @{ ProvisionedThroughput = 400; ServiceAvailability = 100 }[$name] }, [ordered]@{ timeStamp = '2026-11-13T18:00:00Z' })
                }
                else {
                    @(for ($minute = 2; $minute -le 20; $minute++) {
                            $value = if ($query.Contains('$filter')) { @{ 5 = 50; 6 = 40; 8 = 30 }[$minute] } else { @{ NormalizedRUConsumption = $(if ($minute -ge 5 -and $minute -le 9) { 100 } else { 20 }); TotalRequestUnits = 6000; TotalRequests = 600; ServerSideLatencyGateway = 5.5 }[$name] }
                            $point = [ordered]@{ timeStamp = ('2026-11-13T17:{0:00}:00Z' -f $minute) }
                            if ($null -ne $value) { $point[$field] = $value }
                            $point
                        })
                }
                $unit = @{ NormalizedRUConsumption = 'Percent'; ServiceAvailability = 'Percent'; ServerSideLatencyGateway = 'MilliSeconds' }[$name]
                return [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject @{ value = @(@{ name = @{ value = $name }; unit = $(if ($unit) { $unit } else { 'Count' }); timeseries = @(@{ data = @($data) }) }) } -Depth 10 -Compress); StdErr = '' }
            }
            if ($text -match 'databaseAccounts/cosmos01-abc123\?') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject @{ name = 'cosmos01-abc123'; properties = @{ provisioningState = 'Succeeded' } } -Compress); StdErr = '' }
            }
            throw "unexpected Azure CLI call: $text"
        }
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # An obviously fake ID: every group repeats one character.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $capture = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoCosmosHistoryParameter -Config $Config -DeploymentId 'abc123' -WindowMinutes 60 -NowUtc ([datetime]::new(2026, 11, 13, 18, 2, 37, [System.DateTimeKind]::Utc)) }
        $capture.Status | Should -Be 'Pass'
        $capture.PointCount | Should -Be 81
        $documentPath = Join-Path -Path $TestDrive -ChildPath 'cosmos-metrics.json'
        Set-Content -LiteralPath $documentPath -Value $capture.Json -Encoding utf8NoBOM -NoNewline
        $script = Join-Path -Path $TestDrive -ChildPath 'cosmos.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import contextlib, io, json, sys, types
sys.modules.setdefault("requests", types.SimpleNamespace(RequestException=Exception))
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
document = open(sys.argv[2], encoding="utf-8").read()
parameters = next(cell for cell in cells if cell.startswith("# Parameters cell"))
t5_cell = next(cell for cell in cells if cell.startswith("# T5 (Azure Cosmos DB):"))

def t5(ns):
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        exec(compile(t5_cell, "t5", "exec"), ns)
    return printed.getvalue()

def run(metrics):
    ns = {}
    exec(parameters, ns)
    ns["COSMOS_METRICS"] = metrics
    with contextlib.redirect_stdout(io.StringIO()):
        for index, cell in enumerate(cells):
            if cell.startswith("# Helpers, part"):
                exec(compile(cell, "cell-%d" % index, "exec"), ns)
    return ns, t5(ns)

def summary(ns, printed):
    text = lambda value: value.strftime("%Y-%m-%d %H:%M") if value is not None else None
    rows = [row for row in ns["SNAPSHOT_ROWS"] if row["analysis"] == "cosmosdb"]
    return {
        "printed": printed.strip().splitlines(),
        "rows": [{"target": row["target"], "resource": row["resource_name"], "type": row["resource_type"], "metric": row["metric"],
                  "bucket": text(row["bucket_utc"]), "value": row["value"], "unit": row["unit"], "windowStart": text(row["window_start_utc"]),
                  "windowEnd": text(row["window_end_utc"]), "reportDate": str(ns["report_date"]("telemetry_snapshots", row))} for row in rows],
        "findings": {item["finding_id"]: {"status": item["status"], "finding": item["finding"], "target": item["target"],
                                          "start": text(item["window_start_utc"]), "end": text(item["window_end_utc"]),
                                          "reportDate": str(ns["report_date"]("analysis_findings", item))}
                     for item in ns["FINDINGS"] if item["analysis"] == "cosmosdb"},
    }

full, printed = run(document)
again = t5(full)
# Still throttled at the capture's end: the last minutes are a storm.
stormy = json.loads(document)
for series in stormy["series"]:
    if series["metric"] == "ThrottledRequests":
        series["points"].append(["2026-11-13T17:20:00Z", 10])
    if series["metric"] == "NormalizedRUConsumption":
        series["points"] = [[at, 100 if at >= "2026-11-13T17:18:00Z" else value] for at, value in series["points"]]
calm = json.loads(document)
for series in calm["series"]:
    if series["metric"] == "ThrottledRequests":
        series["points"] = []
print(json.dumps({
    "full": summary(full, printed),
    "again": summary(full, again),
    "stormy": summary(*run(json.dumps(stormy))),
    "calm": summary(*run(json.dumps(calm))),
    "invalid": summary(*run('{"version": 2, "accounts": [], "series": []}')),
    "empty": summary(*run("")),
}))
'@
        $output = & $interpreter $script $nb.Path $documentPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable

        $full = $result['full']
        # 19 points of each one-minute signal, the 429s filled with 0 in the 16 minutes with requests and none throttled,
        # and one hourly point of each hourly signal.
        $full['rows'].Count | Should -Be 97
        @($full['rows'] | ForEach-Object { $_['target'] } | Sort-Object -Unique) | Should -Be @('T5')
        @($full['rows'] | ForEach-Object { $_['type'] } | Sort-Object -Unique) | Should -Be @('databaseAccounts')
        @($full['rows'] | ForEach-Object { $_['resource'] } | Sort-Object -Unique) | Should -Be @('cosmos01-abc123')
        @($full['rows'] | ForEach-Object { '{0}={1}' -f $_['metric'], $_['unit'] } | Sort-Object -Unique) | Should -Be @(
            'NormalizedRUConsumption=percent', 'ProvisionedThroughput=RU/s', 'ServerSideLatencyGateway=ms', 'ServiceAvailability=percent',
            'ThrottledRequests=requests', 'TotalRequests=requests', 'TotalRequestUnits=RU')
        $throttled = @($full['rows'] | Where-Object { $_['metric'] -eq 'ThrottledRequests' })
        $throttled.Count | Should -Be 19
        @($throttled | Where-Object { $_['value'] -gt 0 } | ForEach-Object { '{0}={1}' -f $_['bucket'], [string]$_['value'] }) | Should -Be @('2026-11-13 17:05=50', '2026-11-13 17:06=40', '2026-11-13 17:08=30')
        $throttled[0]['windowStart'] | Should -Be '2026-11-13 17:02'
        $throttled[0]['windowEnd'] | Should -Be '2026-11-13 18:02'
        $throttled[0]['reportDate'] | Should -Be '2026-11-13'
        @($full['findings'].Keys | Sort-Object) | Should -Be @('cosmosdb.T5.capture', 'cosmosdb.T5.recovery', 'cosmosdb.T5.throttle.20261113T1705', 'cosmosdb.T5.throttling')
        $full['findings']['cosmosdb.T5.capture']['status'] | Should -Be 'Pass'
        $full['findings']['cosmosdb.T5.capture']['finding'] | Should -Be 'Azure Monitor metrics of T5 cosmos01-abc123 from 2026-11-13 17:02 to 2026-11-13 18:02 UTC, every 1 minutes: 7 series, 97 points.'
        $full['findings']['cosmosdb.T5.throttling']['status'] | Should -Be 'Warning'
        $full['findings']['cosmosdb.T5.throttling']['finding'] | Should -Be 'Normalized RU consumption on T5 cosmos01-abc123 reached 100% with 120 throttled requests (429s) of 11,400 requests (1.1%) in 1 episode between 2026-11-13 17:05 and 2026-11-13 17:09 UTC.'
        $episode = $full['findings']['cosmosdb.T5.throttle.20261113T1705']
        $episode['status'] | Should -Be 'Warning'
        $episode['finding'] | Should -Be 'Normalized RU consumption on T5 reached 100% with 120 throttled requests (429s) of 2,400 requests between 2026-11-13 17:05 and 17:09 UTC; the throttling stopped at 17:09 UTC, and normalized RU fell back to 20% from 17:10 UTC.'
        $episode['start'] | Should -Be '2026-11-13 17:05'
        $episode['end'] | Should -Be '2026-11-13 17:09'
        $full['findings']['cosmosdb.T5.recovery']['status'] | Should -Be 'Pass'
        $full['findings']['cosmosdb.T5.recovery']['finding'] | Should -Be 'T5 cosmos01-abc123 was back at its baseline before the capture''s end: its last throttling stopped at 17:09 UTC, and normalized RU consumption fell back to 20% from 17:10 UTC, with no 429s after it.'
        $full['printed'] | Should -Contain 'T5''s metrics (cosmos01-abc123) from 2026-11-13 17:02 to 2026-11-13 18:02 UTC, every 1 minutes:'

        # Running the cell again replaces its rows and findings instead of adding to them.
        $result['again']['rows'].Count | Should -Be 97
        $result['again']['findings'].Count | Should -Be 4

        # Still throttled at the capture's end: a second episode, and a Warning that T5 wasn't back at its baseline.
        $result['stormy']['findings'].Contains('cosmosdb.T5.throttle.20261113T1720') | Should -BeTrue
        $result['stormy']['findings']['cosmosdb.T5.throttle.20261113T1720']['finding'] | Should -Match '; it was still throttled at the capture''s end\.$'
        $result['stormy']['findings']['cosmosdb.T5.recovery']['status'] | Should -Be 'Warning'
        $result['stormy']['findings']['cosmosdb.T5.recovery']['finding'] | Should -Be 'T5 cosmos01-abc123 was still throttled (429s) at the capture''s end, 18:02 UTC: its last throttling began at 17:20 UTC.'

        # No 429 at all: a Pass, the 429s all 0, and no episode or recovery to tell.
        $calm = $result['calm']
        @($calm['findings'].Keys | Sort-Object) | Should -Be @('cosmosdb.T5.capture', 'cosmosdb.T5.throttling')
        $calm['findings']['cosmosdb.T5.throttling']['status'] | Should -Be 'Pass'
        $calm['findings']['cosmosdb.T5.throttling']['finding'] | Should -Be 'No throttled requests (429s) on T5 cosmos01-abc123 from 2026-11-13 17:02 to 2026-11-13 18:02 UTC, 11,400 requests; normalized RU consumption peaked at 100% at 2026-11-13 17:05 UTC.'
        @($calm['rows'] | Where-Object { $_['metric'] -eq 'ThrottledRequests' -and $_['value'] -ne 0 }).Count | Should -Be 0

        $result['invalid']['rows'].Count | Should -Be 0
        @($result['invalid']['findings'].Keys) | Should -Be @('cosmosdb.T5.capture')
        $result['invalid']['findings']['cosmosdb.T5.capture']['status'] | Should -Be 'Fail'
        $result['invalid']['findings']['cosmosdb.T5.capture']['finding'] | Should -Be 'T5''s metrics in COSMOS_METRICS weren''t added: it isn''t a version 1 document.'

        $result['empty']['rows'].Count | Should -Be 0
        $result['empty']['findings'].Count | Should -Be 0
        @($result['empty']['printed']).Count | Should -Be 1
        @($result['empty']['printed'])[0] | Should -Match '^T5''s Azure Cosmos DB metrics weren''t passed in \(COSMOS_METRICS is empty\), so this run adds none'
    }
}

Describe 'The Incident RCA''s evidence in NB_DatabaseHub_LiveActivity (ADR 0031)' {
    BeforeAll {
        $live = Get-Notebook -Name 'NB_DatabaseHub_LiveActivity'
        $part4 = @($live.Code | Where-Object { $_.Source -match '^# Helpers, part 4' })
        $contract = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'rca/history-tables.json') -Raw | ConvertFrom-Json -AsHashtable

        # The notebook's own cells run here (parameters, the four helper cells, section 3, and the persist cell) against a
        # lakehouse in memory, with the contract's fixtures: their parts, staged as the control notebook stages them.
        $rcaReport = $null
        $rcaSkip = ''
        if (-not $pandasPython) {
            $rcaSkip = 'Python 3 is not installed (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
        }
        else {
            $PSNativeCommandUseErrorActionPreference = $false
            $null = & $pandasPython -c 'import pandas' 2>&1
            if ($LASTEXITCODE -ne 0) {
                $rcaSkip = 'pandas is not installed for that Python (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            }
        }
        if (-not $rcaSkip) {
            $script = Join-Path -Path $TestDrive -ChildPath 'rca_evidence.py'
            Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import base64, contextlib, copy, datetime as dt, gzip, hashlib, io, json, re, sys, types

sys.modules.setdefault("requests", types.SimpleNamespace(RequestException=Exception))
spark_types = types.ModuleType("pyspark.sql.types")
for name in ("StringType", "BooleanType", "TimestampType", "DoubleType", "LongType", "IntegerType", "DateType"):
    setattr(spark_types, name, type(name, (), {}))
spark_types.StructField = lambda name, kind, nullable: name
spark_types.StructType = list
pyspark_sql = types.ModuleType("pyspark.sql")
pyspark_sql.types = spark_types
sys.modules.update({"pyspark": types.ModuleType("pyspark"), "pyspark.sql": pyspark_sql, "pyspark.sql.types": spark_types})

notebook, repo = sys.argv[1], sys.argv[2]
code = ["".join(cell["source"]) for cell in json.load(open(notebook, encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
setup = [cell for cell in code if cell.startswith(("# Parameters cell", "# Helpers, part"))]
this_session = next(cell for cell in code if cell.startswith("# This session"))
persist = next(cell for cell in code if cell.startswith("# Persist:"))
spec = {table["name"]: table for table in json.load(open(repo + "/rca/history-tables.json", encoding="utf-8"))["tables"]}


def fixture(name):
    return json.load(open(repo + "/rca/fixtures/" + name, encoding="utf-8"))


PARAMETER = fixture("rca-evidence.parameter.json")
DOCUMENTS = {document["documentId"]: document for document in (fixture("t1-blocking-chain.evidence.json"), fixture("t4-replica-lag.evidence.json"))}
SID = PARAMETER["sessionId"]
# GUID-shaped IDs, built here so no file holds one.
WS = "-".join(("1" * 8, "2" * 4, "3" * 4, "4" * 4, "5" * 12))
LH = "-".join(("6" * 8, "7" * 4, "8" * 4, "9" * 4, "a" * 12))
ROOT = "abfss://%s@onelake.dfs.fabric.microsoft.com/%s/" % (WS, LH)


class Files:
    """notebookutils.fs over the lakehouse's Files, in memory: files by their OneLake path, and folders."""

    def __init__(self):
        self.files, self.folders, self.reads = {}, set(), []

    def add(self, relative, text):
        self.files[ROOT + relative] = text
        parent = (ROOT + relative).rsplit("/", 1)[0]
        while parent.startswith(ROOT + "Files/"):
            self.folders.add(parent)
            parent = parent.rsplit("/", 1)[0]

    def head(self, path, max_bytes):
        self.reads.append(path[len(ROOT):])
        return self.files[path][:max_bytes]

    def exists(self, path):
        return path in self.files or path in self.folders

    def ls(self, path):
        prefix = path.rstrip("/") + "/"
        names = {item[len(prefix):].split("/")[0] for item in list(self.files) + list(self.folders) if item.startswith(prefix)}
        return [types.SimpleNamespace(name=name) for name in sorted(names)]

    def rm(self, path, recurse=False):
        if path in self.files:
            del self.files[path]
        elif self.ls(path) and not recurse:
            raise IOError("the folder isn't empty")
        else:
            self.folders.discard(path)
        return True

    def left(self):
        return sorted(item[len(ROOT):] for item in self.files) + sorted(item[len(ROOT):] + "/" for item in self.folders)


class Rows:
    def __init__(self, rows):
        self.rows = rows

    def filter(self, condition):
        column, value = re.fullmatch(r"(\w+) = '([^']*)'", condition).groups()
        return Rows([row for row in self.rows if row.get(column) == value])

    def limit(self, count):
        return Rows(self.rows[:count])

    def count(self):
        return len(self.rows)


class Lake:
    def __init__(self):
        self.tables, self.columns, self.log = {}, {}, []
        self.catalog = types.SimpleNamespace(tableExists=lambda name: name in self.tables)
        self.conf = types.SimpleNamespace(get=lambda key: "UTC", set=lambda key, value: None)

    def table(self, name):
        rows = Rows(self.tables[name])
        rows.schema = types.SimpleNamespace(fields=[types.SimpleNamespace(name=column) for column, _ in self.columns[name]])
        return rows

    def createDataFrame(self, data, schema):
        lake, rows = self, [dict(zip(schema, values)) for values in data]

        class Writer:
            def format(self, name):
                return self

            def mode(self, name):
                return self

            def option(self, key, value):
                return self

            def saveAsTable(self, table):
                lake.log.append("append %s %d" % (table, len(rows)))
                lake.tables.setdefault(table, []).extend(rows)

        return types.SimpleNamespace(coalesce=lambda count: types.SimpleNamespace(write=Writer()))

    def sql(self, statement):
        result = []
        by_run = re.fullmatch(r"DELETE FROM (\w+) WHERE run_id = '([^']*)'", statement)
        by_document = re.fullmatch(r"DELETE FROM (\w+) WHERE document_id IN \(('[^']*'(?:, '[^']*')*)\)", statement)
        if by_run or by_document:
            column, gone = ("run_id", {by_run.group(2)}) if by_run else ("document_id", set(re.findall(r"'([^']*)'", by_document.group(2))))
            name = (by_run or by_document).group(1)
            kept = [row for row in self.tables[name] if row.get(column) not in gone]
            self.log.append("delete %s %d" % (name, len(self.tables[name]) - len(kept)))
            self.tables[name][:] = kept
        elif statement.startswith("CREATE TABLE IF NOT EXISTS "):
            self.tables.setdefault(statement.split()[5], [])
        elif statement.startswith("SELECT DISTINCT document_id FROM rca_coverage WHERE document_id IN ("):
            wanted = set(re.findall(r"'([^']*)'", statement))
            result = [{"document_id": value} for value in sorted({row["document_id"] for row in self.tables["rca_coverage"]} & wanted)]
        elif statement.startswith("SELECT COUNT(*) AS n FROM "):
            result = [{"n": 0}]
        elif statement.startswith("DESCRIBE DETAIL "):
            result = [{"numFiles": 1}]
        else:
            raise AssertionError("unexpected statement: " + statement)
        return types.SimpleNamespace(collect=lambda: result)


def run(lake, files, session_id=SID, evidence_file="", evidence="", rca_only=False, save=True, reference=False):
    """One run of the notebook: its setup, section 3, and the persist cell, which sections 4 to 10 add nothing to here."""
    exits, printed = [], io.StringIO()
    utils = types.SimpleNamespace(fs=files, notebook=types.SimpleNamespace(exit=exits.append))
    ns = {}
    with contextlib.redirect_stdout(printed):
        exec(setup[0], ns)
        ns.update(SESSION_ID=session_id, SESSION_PLAN="", RCA_EVIDENCE=evidence, RCA_EVIDENCE_FILE=evidence_file, RCA_ONLY=rca_only,
                  SAVE_RESULTS=save, WORKSPACE_ID=WS, LAKEHOUSE_ID=LH)
        for cell in setup[1:]:
            exec(cell, ns)
        lake.columns = ns["TABLE_COLUMNS"]
        ns.update(_spark=lambda: lake, runtime_context=lambda: {"defaultLakehouseId": LH}, _notebookutils=lambda: utils,
                  REFERENCE_RUN=reference, incident_window_rows=lambda: ([], []),
                  merge_incident_windows=lambda session, recorded, detected: (0, 0))
        exec(this_session, ns)
        exec(persist, ns)
    state = ns["RCA_STATE"]
    findings = [row for row in lake.tables.get("analysis_findings", []) if row["analysis"] == "rca_evidence"]
    return {"status": state["status"], "message": state["message"], "documents": state["documents"], "skipped": state["skipped"],
            "exits": exits, "findings": [[row["status"], row["target"], row["finding"]] for row in findings],
            "counts": {name: len(lake.tables[name]) for name in ns["RCA_TABLES"] if name in lake.tables},
            "telemetry": len(lake.tables.get("telemetry_snapshots", [])), "left": files.left(), "reads": list(files.reads)}, ns


def encode(document, size=2400):
    """The runner's part lines for a document (rca/README.md, Part lines)."""
    stream = gzip.compress(json.dumps(document, separators=(",", ":")).encode("utf-8"))
    digest = hashlib.sha256(stream).hexdigest()
    chunks = [stream[index:index + size] for index in range(0, len(stream), size)]
    return ["DBHUBDEMO-RCA 1 %s %d/%d %s %s" % (document["documentId"], index + 1, len(chunks), digest, base64.b64encode(chunk).decode("ascii"))
            for index, chunk in enumerate(chunks)]


def evidence(parts, **changes):
    return json.dumps(dict({"kind": "ContosoCare.RcaEvidenceParts", "version": 1, "sessionId": SID, "parts": parts}, **changes))


def plain(value):
    return value.isoformat() if isinstance(value, (dt.datetime, dt.date)) else value


def expected(document):
    """The document's rows decoded on their own, from the contract, to compare with what the notebook wrote."""
    epoch = dt.datetime.fromisoformat(document["epochUtc"].replace("Z", "+00:00"))
    rows = {}
    for tables, strings in ((document["tables"], document["strings"]), (document["answerKey"]["tables"], document["answerKey"]["strings"])):
        for name, table in tables.items():
            kinds = {column["name"]: column["type"] for column in spec[name]["columns"]}
            decoded = []
            for index in range(table["rows"]):
                row = {}
                for column, values in table["columns"].items():
                    value = values[index]
                    if value is not None and kinds[column] == "string":
                        value = strings[value]
                    elif value is not None and kinds[column] == "timestamp":
                        value = (epoch + dt.timedelta(milliseconds=value)).isoformat()
                    elif value is not None and kinds[column] == "double":
                        value = float(value)
                    row[column] = value
                decoded.append(row)
            rows[name] = decoded
    return rows


report = {}
lake, files = Lake(), Files()
ns = run(lake, files, evidence_file="")[1]
report["contract"] = {
    "tables": {name: {"role": table["role"], "primary": table["primary"], "columns": [list(column) for column in table["columns"]],
                      "required": list(table["required"])} for name, table in ns["RCA_TABLES"].items()},
    "tableColumns": {name: [list(column) for column in ns["TABLE_COLUMNS"][name]] for name in ns["RCA_TABLES"]},
    "dateSources": {name: list(ns["REPORT_DATE_SOURCES"][name]) for name in ns["RCA_TABLES"]}}
decoded, skipped = ns["decode_rca_parts"](PARAMETER["parts"])
report["decode"] = {"same": decoded == DOCUMENTS, "documents": sorted(decoded), "skipped": skipped}

# The fixtures' parts, staged as the control notebook stages them, in a reference run of the session's save.
lake, files = Lake(), Files()
staged = "Files/rca/inbox/20261120T172500Z-5f1c0e7a-0001.json"
files.add(staged, json.dumps(PARAMETER))
first, ns = run(lake, files, evidence_file=staged, reference=True)
mismatches, others, dates, leaks = [], [], [], []
answers = {value for document in DOCUMENTS.values() for row in expected(document).get("rca_answer_key", [])
           for value in (row["scenario"], row["scenario_run_id"])}
for document_id, document in DOCUMENTS.items():
    for name, rows in expected(document).items():
        written = [row for row in lake.tables[name] if row["document_id"] == document_id]
        if len(written) != len(rows):
            mismatches.append("%s %s: %d rows, not %d" % (document_id, name, len(written), len(rows)))
            continue
        for want, got in zip(rows, written):
            if {column: plain(got[column]) for column in want} != want:
                mismatches.append("%s %s: a row differs" % (document_id, name))
            if any(got[column["name"]] is not None for column in spec[name]["columns"] if column["name"] not in want):
                mismatches.append("%s %s: a column the document left out isn't null" % (document_id, name))
            if got["run_id"] != "session-" + SID:
                others.append(got["run_id"])
            primary = got[spec[name]["primaryTime"]]
            if got["report_date_utc"] != primary.date():
                dates.append("%s %s" % (name, got["report_date_utc"]))
for name, rows in lake.tables.items():
    if name in ns["RCA_DETECTION_TABLES"]:
        leaks += sorted({str(value) for row in rows for value in row.values() if value in answers})
first.update(mismatches=mismatches, otherRunIds=sorted(set(others)), badDates=dates, leaks=leaks,
             answerKeyRows=len(lake.tables["rca_answer_key"]),
             expectedCounts={name: sum(len(expected(document).get(name, [])) for document in DOCUMENTS.values()) for name in spec})
report["fixtures"] = first

# The same evidence again, inline: its coverage rows say it's written, so nothing is written twice or deleted.
before = len(lake.log)
again, _ = run(lake, files, evidence=json.dumps(PARAMETER))
again["writes"] = [entry for entry in lake.log[before:] if entry.split()[1].startswith("rca_")]
report["again"] = again

# A write cut off before a document's coverage rows: the next save deletes what it left and writes the document whole.
lake, files = Lake(), Files()
t1 = "20261120T165000Z-sqlvm01-0001"
run(lake, files, evidence=evidence([part for part in PARAMETER["parts"] if t1 in part]))
lake.tables["rca_coverage"][:] = [row for row in lake.tables["rca_coverage"] if row["document_id"] != t1]
before = len(lake.log)
resumed, _ = run(lake, files, evidence=json.dumps(PARAMETER))
resumed["deleted"] = sum(int(entry.split()[-1]) for entry in lake.log[before:] if entry.startswith("delete rca_"))
report["resumed"] = resumed

# A document with a missing part, one whose SHA-256 doesn't match, and a newer version's, beside one that's whole.
parts = list(PARAMETER["parts"])
t4 = "20261120T170000Z-sqlvm01-0002"
missing = [part for part in parts if not part.startswith("DBHUBDEMO-RCA 1 %s 2/" % t4)]
report["missing"] = run(Lake(), Files(), evidence=evidence(missing))[0]
corrupt = [re.sub(r" ([0-9a-f]{64}) ", " " + "0" * 64 + " ", part) if t4 in part else part for part in parts]
report["corrupt"] = run(Lake(), Files(), evidence=evidence(corrupt))[0]
newer = copy.deepcopy(DOCUMENTS[t4])
newer["version"] = 2
report["newerDocument"] = run(Lake(), Files(), evidence=evidence([part for part in parts if t4 not in part] + encode(newer)))[0]
report["newerParameter"] = run(Lake(), Files(), evidence=evidence(parts, version=2))[0]
report["otherSession"] = run(Lake(), Files(), session_id="f" * 32, evidence=evidence(parts))[0]
report["unreadable"] = run(Lake(), Files(), evidence=evidence(parts + ["DBHUBDEMO-RCA 2 something else"]))[0]

# A staged file nothing was written from stays, so a deleted file means written (review of 37a546bc): every document
# another session's, or a file that can't be used; the control notebook and the scripts then find it left. Each is staged
# now, as Run all stages it: the inbox sweep deletes a file staged more than a day ago, whatever its run wrote.
fresh = "Files/rca/inbox/%s-5f1c0e7a-0001.json" % dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
files = Files()
files.add(fresh, json.dumps(PARAMETER))
report["stagedOtherSession"] = run(Lake(), files, session_id="f" * 32, evidence_file=fresh)[0]
report["stagedOtherSession"]["staged"] = fresh
files = Files()
files.add(fresh, evidence(parts, version=2))
report["stagedUnusable"] = run(Lake(), files, evidence_file=fresh)[0]
report["stagedUnusable"]["staged"] = fresh

# A secret-looking string in a document is redacted before it's written; a document passed inline is read the same way.
leaky = copy.deepcopy(DOCUMENTS["20261120T165000Z-sqlvm01-0001"])
token = "eyJ" + "a" * 12 + "." + "b" * 12 + "." + "c" * 12
first_statement = next(value for value in leaky["tables"]["rca_sessions"]["columns"]["statement_text"] if value is not None)
leaky["strings"][first_statement] = "SELECT 1 -- " + token
lake = Lake()
report["redacted"] = run(lake, Files(), evidence=evidence(encode(leaky)))[0]
report["redacted"]["statement"] = next(row["statement_text"] for row in lake.tables["rca_sessions"] if row["statement_text"] is not None)

# Nothing passed: Not selected, no RCA row and no finding, and the eight tables all the same, so the model frames them.
lake = Lake()
report["none"] = run(lake, Files())[0]
report["none"]["tables"] = sorted(name for name in lake.tables if name.startswith("rca_"))

# The staged file: one outside the inbox isn't read; one that SAVE_RESULTS False leaves stays; a day-old one goes.
files = Files()
files.add("Files/other.json", json.dumps(PARAMETER))
report["outside"] = run(Lake(), files, evidence_file="Files/other.json")[0]
files = Files()
files.add(staged, json.dumps(PARAMETER))
report["unsaved"] = run(Lake(), files, evidence_file=staged, save=False)[0]
files = Files()
now = dt.datetime.now(dt.timezone.utc)
old = "Files/rca/inbox/%s-5f1c0e7a-0009.json" % (now - dt.timedelta(days=2)).strftime("%Y%m%dT%H%M%SZ")
recent = "Files/rca/inbox/%s-5f1c0e7a-0010.json" % (now - dt.timedelta(hours=1)).strftime("%Y%m%dT%H%M%SZ")
for name in (old, recent, "Files/rca/inbox/notes.txt"):
    files.add(name, "{}")
report["sweep"] = run(Lake(), files)[0]
report["sweep"]["old"], report["sweep"]["recent"] = old, recent

# Both parameters (review of 15ad76d): their parts merged, each document written once; one that can't be used is skipped
# and named, and the other's documents are still written; a staged file that couldn't be read stays for a later run.
t1_parts = [part for part in PARAMETER["parts"] if t1 in part]
t4_parts = [part for part in PARAMETER["parts"] if t4 in part]
files = Files()
files.add(staged, evidence(t1_parts))
report["both"] = run(Lake(), files, evidence_file=staged, evidence=evidence(t4_parts + t1_parts[:1]))[0]
files = Files()
files.add(staged, json.dumps(PARAMETER))
report["bothInlineNewer"] = run(Lake(), files, evidence_file=staged, evidence=evidence(t4_parts, version=2))[0]
missing_file = "Files/rca/inbox/20261120T172500Z-5f1c0e7a-0002.json"
report["bothFileUnread"] = run(Lake(), Files(), evidence_file=missing_file, evidence=json.dumps(PARAMETER))[0]
report["bothFileUnread"]["file"] = missing_file

# RCA_ONLY: an earlier session's evidence alone, under its session's run ID, with SAVE_RESULTS False as the control passes
# it (so a copy from before the Incident RCA saves nothing); nothing else is written, and the run ends.
lake, files = Lake(), Files()
files.add(staged, json.dumps(PARAMETER))
only, _ = run(lake, files, evidence_file=staged, rca_only=True, save=False)
only["runIds"] = sorted({row["run_id"] for name in spec for row in lake.tables.get(name, [])})
report["rcaOnly"] = only
print(json.dumps(report, default=str))
'@
            $PSNativeCommandUseErrorActionPreference = $false
            $output = & $pandasPython $script $live.Path $repoRoot 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ('The RCA evidence script failed: {0}' -f ($output -join "`n"))
            }
            $rcaReport = ($output | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable
        }
    }

    It 'has one helpers cell for it, which makes no network call and reads no secret' {
        $part4.Count | Should -Be 1
        # RCA_EVIDENCE_FILE as rca/transport.schema.json's evidenceFile says, read with notebookutils.fs.head and 262144 bytes.
        $schema = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'rca/transport.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $pattern = $schema['$defs']['evidenceFile']['pattern']
        $part4[0].Source | Should -Match ('(?m)^RCA_EVIDENCE_FILE_PATTERN = re\.compile\(r"{0}"\)$' -f [regex]::Escape($pattern.TrimStart('^').TrimEnd('$')))
        $part4[0].Source | Should -Match '"fileBytes": 262144'
        $part4[0].Source | Should -Match 'utils\.fs\.head\(_rca_path\(RCA_EVIDENCE_FILE\), RCA_LIMITS\["fileBytes"\]\)'
        $part4[0].Source | Should -Not -Match 'requests\.|get_token\(|getToken\(|getSecret\(|KEY_VAULT|vault\.azure\.net'
        foreach ($url in [regex]::Matches($part4[0].Source, 'https://[^\s)"]+')) {
            $url.Value | Should -Match '^https://learn\.microsoft\.com/'
        }
    }

    It 'mirrors rca/history-tables.json: the evidence document''s eight tables, their columns and types in order, the required ones, the primary times, and the notebook''s columns' {
        if ($rcaSkip) {
            Set-ItResult -Skipped -Because $rcaSkip
            return
        }
        # The sidecar's tables come with the sidecar's decoder (rca/README.md, The sidecar); the evidence document's are the eight.
        $evidenceTables = @($contract['tables'] | Where-Object { $_['document'] -eq 'evidence' })
        $tables = $rcaReport['contract']['tables']
        @($tables.Keys) | Should -Be @($evidenceTables | ForEach-Object { $_['name'] })
        foreach ($table in $evidenceTables) {
            $name = $table['name']
            $mine = $tables[$name]
            $mine['role'] | Should -Be ($(if ($table['role'] -eq 'answerKey') { 'answerKey' } else { 'detection' })) -Because $name
            $mine['primary'] | Should -Be $table['primaryTime'] -Because $name
            @($mine['columns'] | ForEach-Object { $_ -join ':' }) | Should -Be @($table['columns'] | ForEach-Object { '{0}:{1}' -f $_['name'], $_['type'] }) -Because $name
            @($mine['required']) | Should -Be @($table['columns'] | Where-Object { $_['required'] } | ForEach-Object { $_['name'] }) -Because $name
            $notebookColumns = @($contract['notebookColumns'] | ForEach-Object { '{0}:{1}' -f $_['name'], $_['type'] })
            @($rcaReport['contract']['tableColumns'][$name] | ForEach-Object { $_ -join ':' }) | Should -Be @($notebookColumns[0..1] + @($table['columns'] | ForEach-Object { '{0}:{1}' -f $_['name'], $_['type'] }) + $notebookColumns[2]) -Because $name
            @($rcaReport['contract']['dateSources'][$name]) | Should -Be @($table['primaryTime']) -Because $name
        }
        @($contract['purge'] | Where-Object { $_ -in @($tables.Keys) }) | Should -Be @($tables.Keys)
    }

    It 'decodes the fixtures'' parts into the fixture documents, and writes their rows once to the right tables, the answer key only to rca_answer_key' {
        if ($rcaSkip) {
            Set-ItResult -Skipped -Because $rcaSkip
            return
        }
        $rcaReport['decode']['same'] | Should -BeTrue
        @($rcaReport['decode']['skipped']) | Should -BeNullOrEmpty
        $fixtures = $rcaReport['fixtures']
        $fixtures['status'] | Should -Be 'Pass'
        $fixtures['message'] | Should -Match '^Wrote 2 evidence document\(s\) from sqlvm01 \(T1, T4, T4-replica; 2026-11-20 16:50 to 17:20 UTC\): \d+ detection row\(s\)\.$'
        @($fixtures['documents']) | Should -Be @('20261120T165000Z-sqlvm01-0001', '20261120T170000Z-sqlvm01-0002')
        @($fixtures['mismatches']) | Should -BeNullOrEmpty
        @($fixtures['otherRunIds']) | Should -BeNullOrEmpty
        @($fixtures['badDates']) | Should -BeNullOrEmpty
        foreach ($name in $fixtures['expectedCounts'].Keys) {
            [int]$fixtures['counts'][$name] | Should -Be ([int]$fixtures['expectedCounts'][$name]) -Because $name
        }
        $fixtures['answerKeyRows'] | Should -BeGreaterThan 0
        # Blind detection: no detection row holds a scenario or an injected run's ID, which only rca_answer_key has.
        @($fixtures['leaks']) | Should -BeNullOrEmpty
        # The finding (analysis_findings, which the answer key's side reads), and the reference run's exit value.
        @($fixtures['findings'] | ForEach-Object { $_[0..1] -join ' ' }) | Should -Be @('Pass all')
        $fixtures['findings'][0][2] | Should -BeExactly ('RCA.EVIDENCE: ' + $fixtures['message'])
        @($fixtures['exits']) | Should -Be @('RCA.EVIDENCE Pass: ' + $fixtures['message'])
        # The staged file was read once and deleted, and the inbox with it.
        @($fixtures['reads']) | Should -Be @('Files/rca/inbox/20261120T172500Z-5f1c0e7a-0001.json')
        @($fixtures['left']) | Should -BeNullOrEmpty
    }

    It 'writes each document once: a second save finds it written, and a document cut off before its coverage rows is written again whole' {
        if ($rcaSkip) {
            Set-ItResult -Skipped -Because $rcaSkip
            return
        }
        $again = $rcaReport['again']
        $again['status'] | Should -Be 'Pass'
        $again['message'] | Should -Match '^The 2 evidence document\(s\) from sqlvm01 \(T1, T4, T4-replica; 2026-11-20 16:50 to 17:20 UTC\) were in the history already: each is written once\.$'
        foreach ($name in $rcaReport['fixtures']['counts'].Keys) {
            $again['counts'][$name] | Should -Be $rcaReport['fixtures']['counts'][$name] -Because $name
        }
        @($again['writes']) | Should -BeNullOrEmpty
        # rca_coverage goes last, so a document without its coverage rows was cut off: its other rows go, then it's written whole.
        $resumed = $rcaReport['resumed']
        $resumed['status'] | Should -Be 'Pass'
        $resumed['message'] | Should -Match '^Wrote 2 evidence document\(s\) '
        foreach ($name in $rcaReport['fixtures']['expectedCounts'].Keys) {
            [int]$resumed['counts'][$name] | Should -Be ([int]$rcaReport['fixtures']['expectedCounts'][$name]) -Because $name
        }
        $resumed['deleted'] | Should -BeGreaterThan 0
    }

    It 'skips a document with a missing part, a bad SHA-256, a newer version, or another session, and says why' -ForEach @(
        @{ Case = 'missing'; Written = 1; Why = 'part\(s\) 2 of 2 are missing' }
        @{ Case = 'corrupt'; Written = 1; Why = 'SHA-256 doesn''t match' }
        @{ Case = 'newerDocument'; Written = 1; Why = 'version 2 is newer than this notebook''s 1 \(\./scripts/deploy\.ps1 updates the notebook\)' }
        @{ Case = 'newerParameter'; Written = 0; Why = 'version 2 is newer than this notebook''s 1' }
        @{ Case = 'otherSession'; Written = 0; Why = 'it''s session 5f1c0e7a''s evidence, not this run''s \(ffffffff\)' }
        @{ Case = 'unreadable'; Written = 2; Why = '1 part line\(s\) that part format 1 doesn''t describe' }
    ) {
        if ($rcaSkip) {
            Set-ItResult -Skipped -Because $rcaSkip
            return
        }
        $result = $rcaReport[$Case]
        $result['status'] | Should -Be 'Warning'
        $result['message'] | Should -Match $Why
        @($result['documents']).Count | Should -Be $Written
        if ($Written -eq 1) {
            # The whole document is written; the other one isn't, not even in part.
            @($result['documents']) | Should -Be @('20261120T165000Z-sqlvm01-0001')
            $result['counts']['rca_replica'] | Should -Be 0
        }
        @($result['findings'] | ForEach-Object { $_[0] }) | Should -Be @('Warning')
    }

    It 'redacts a value that looks like a secret, and reads evidence passed inline the same way' {
        if ($rcaSkip) {
            Set-ItResult -Skipped -Because $rcaSkip
            return
        }
        $rcaReport['redacted']['status'] | Should -Be 'Pass'
        $rcaReport['redacted']['statement'] | Should -BeExactly 'SELECT 1 -- [REDACTED:jwt]'
    }

    It 'is Not selected without evidence, and still creates the eight tables, so the history model frames them' {
        if ($rcaSkip) {
            Set-ItResult -Skipped -Because $rcaSkip
            return
        }
        $none = $rcaReport['none']
        $none['status'] | Should -Be 'Not selected'
        @($none['findings']) | Should -BeNullOrEmpty
        @($none['exits']) | Should -BeNullOrEmpty
        @($none['tables']) | Should -Be @($contract['purge'] | Sort-Object)
        foreach ($name in $contract['purge']) {
            $none['counts'][$name] | Should -Be 0 -Because $name
        }
    }

    It 'reads only a file in Files/rca/inbox, keeps one that SAVE_RESULTS False didn''t write, and deletes a day-old one a failed run left' {
        if ($rcaSkip) {
            Set-ItResult -Skipped -Because $rcaSkip
            return
        }
        $outside = $rcaReport['outside']
        $outside['status'] | Should -Be 'Warning'
        $outside['message'] | Should -Match 'RCA_EVIDENCE_FILE must name a file in Files/rca/inbox'
        @($outside['reads']) | Should -BeNullOrEmpty
        @($outside['left']) | Should -Be @('Files/other.json')

        $unsaved = $rcaReport['unsaved']
        $unsaved['status'] | Should -Be 'Not selected'
        @($unsaved['left']) | Should -Contain 'Files/rca/inbox/20261120T172500Z-5f1c0e7a-0001.json'

        # Any run sweeps the inbox: only the notebook's own names, and only after a day.
        $sweep = $rcaReport['sweep']
        $sweep['status'] | Should -Be 'Not selected'
        @($sweep['left']) | Should -Not -Contain $sweep['old']
        @($sweep['left']) | Should -Contain $sweep['recent']
        @($sweep['left']) | Should -Contain 'Files/rca/inbox/notes.txt'
    }

    It 'keeps a staged file it wrote nothing from, so a deleted file means written (review of 37a546bc)' {
        if ($rcaSkip) {
            Set-ItResult -Skipped -Because $rcaSkip
            return
        }
        foreach ($case in 'stagedOtherSession', 'stagedUnusable') {
            $result = $rcaReport[$case]
            $result['status'] | Should -Be 'Warning' -Because $case
            @($result['documents']) | Should -BeNullOrEmpty -Because $case
            @($result['left']) | Should -Contain $result['staged'] -Because ('{0}: the control notebook and the scripts read a deleted file as written' -f $case)
        }
        # One it wrote from goes: the fixtures' run above.
        @($rcaReport['fixtures']['left']) | Should -BeNullOrEmpty
    }

    It 'merges the staged file''s parts with the inline RCA_EVIDENCE when both are passed, and writes each document once (review of 15ad76d)' {
        if ($rcaSkip) {
            Set-ItResult -Skipped -Because $rcaSkip
            return
        }
        $ids = @('20261120T165000Z-sqlvm01-0001', '20261120T170000Z-sqlvm01-0002')
        # T1's document staged, T4's inline (with one of T1's parts again): both written, the file deleted.
        $both = $rcaReport['both']
        $both['status'] | Should -Be 'Pass' -Because $both['message']
        @($both['documents']) | Should -Be $ids
        @($both['skipped']) | Should -BeNullOrEmpty
        @($both['left']) | Should -BeNullOrEmpty
        $both['counts']['rca_coverage'] | Should -BeGreaterThan 0
        foreach ($name in $both['counts'].Keys) {
            $both['counts'][$name] | Should -Be $rcaReport['fixtures']['expectedCounts'][$name] -Because "$name holds both documents' rows once"
        }
        # The inline document can't be used: the staged file's documents are still written, and the Warning names it.
        $newer = $rcaReport['bothInlineNewer']
        $newer['status'] | Should -Be 'Warning'
        @($newer['documents']) | Should -Be $ids
        $newer['message'] | Should -Match 'RCA_EVIDENCE: not used, because its version 2 is newer than this notebook''s 1'
        @($newer['left']) | Should -BeNullOrEmpty
        # The staged file can't be read: the inline documents are written, and the file isn't deleted.
        $unread = $rcaReport['bothFileUnread']
        $unread['status'] | Should -Be 'Warning'
        @($unread['documents']) | Should -Be $ids
        @($unread['reads']) | Should -Be @($unread['file'])
        $unread['message'] | Should -Match ('{0}: not used, because the staged file couldn''t be read' -f [regex]::Escape($unread['file']))
    }

    It 'writes only the RCA evidence with RCA_ONLY, under its session''s run ID, and ends the run with RCA.EVIDENCE' {
        if ($rcaSkip) {
            Set-ItResult -Skipped -Because $rcaSkip
            return
        }
        $only = $rcaReport['rcaOnly']
        $only['status'] | Should -Be 'Pass'
        @($only['runIds']) | Should -Be @('session-5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21')
        $only['telemetry'] | Should -Be 0
        @($only['exits']) | Should -Be @('RCA.EVIDENCE Pass: ' + $only['message'])
        @($only['left']) | Should -BeNullOrEmpty
    }
}

Describe 'Report tables for the Power BI history report (Phase 19)' {
    BeforeAll {
        $deployment = Get-Notebook -Name 'NB_DatabaseHub_Deployment'
        $live = Get-Notebook -Name 'NB_DatabaseHub_LiveActivity'
        $deploymentCode = ($deployment.Code | ForEach-Object Source) -join "`n"
        $liveCode = ($live.Code | ForEach-Object Source) -join "`n"

        # TABLE_COLUMNS as an ordered map of table name to "column:type" strings, parsed from the helper source.
        function Get-TableColumn {
            param([string] $Code)
            $block = [regex]::Match($Code, '(?ms)^TABLE_COLUMNS = \{\n(.*?)\n\}\n').Groups[1].Value
            $tables = [ordered]@{}
            foreach ($table in [regex]::Matches($block, '(?ms)^    "(\w+)": \[\n(.*?)\n    \],')) {
                $tables[$table.Groups[1].Value] = @([regex]::Matches($table.Groups[2].Value, '\("(\w+)", "(\w+)"\)') | ForEach-Object { '{0}:{1}' -f $_.Groups[1].Value, $_.Groups[2].Value })
            }
            $tables
        }
        $deploymentTables = Get-TableColumn -Code $deploymentCode
        $liveTables = Get-TableColumn -Code $liveCode
        $reportDateSources = { param([string] $Code) [regex]::Match($Code, '(?ms)^REPORT_DATE_SOURCES = \{\n.*?\n\}\n').Value }
    }

    It 'gives every table that <Name> writes report_date_utc, a date, as its last column' -ForEach @(
        @{ Name = 'NB_DatabaseHub_Deployment'; Expected = @('validation_results', 'telemetry_snapshots') }
        @{ Name = 'NB_DatabaseHub_LiveActivity'; Expected = @('validation_results', 'scenario_runs', 'telemetry_snapshots', 'analysis_findings', 'incident_windows') }
    ) {
        $tables = if ($Name -eq 'NB_DatabaseHub_Deployment') { $deploymentTables } else { $liveTables }
        @($tables.Keys) | Should -Be $Expected
        foreach ($table in $tables.Keys) {
            $tables[$table][-1] | Should -Be 'report_date_utc:date' -Because $table
            @($tables[$table] | Where-Object { $_ -like 'report_date_utc:*' }).Count | Should -Be 1
        }
    }

    It 'keeps the shared tables identical in both notebooks, so either one can create them' {
        foreach ($table in $deploymentTables.Keys) {
            ($liveTables[$table] -join ',') | Should -BeExactly ($deploymentTables[$table] -join ',')
        }
    }

    It 'gives incident_windows the 18 columns of the report spec' {
        $liveTables['incident_windows'] | Should -Be @(
            'incident_key:string', 'incident_label:string', 'incident_sort:long', 'source:string', 'target:string', 'scenario:string',
            'signal_family:string', 'request_id:string', 'window_start_utc:timestamp', 'window_end_utc:timestamp',
            'duration_minutes:double', 'peak_value:double', 'peak_unit:string', 'correlation_status:string',
            'correlation_evidence:string', 'run_id:string', 'captured_at_utc:timestamp', 'report_date_utc:date')
    }

    It 'derives report_date_utc from the same primary times in both notebooks, and only from timestamp columns' {
        $sources = & $reportDateSources $liveCode
        $sources | Should -Not -BeNullOrEmpty
        (& $reportDateSources $deploymentCode) | Should -BeExactly $sources
        foreach ($entry in [regex]::Matches($sources, '"(\w+)": \(([^)]*)\)')) {
            $table = $entry.Groups[1].Value
            $liveTables.Keys | Should -Contain $table
            foreach ($column in [regex]::Matches($entry.Groups[2].Value, '"(\w+)"')) {
                $liveTables[$table] | Should -Contain ('{0}:timestamp' -f $column.Groups[1].Value)
            }
        }
        foreach ($code in $deploymentCode, $liveCode) {
            $code | Should -Match '"date": spark_types\.DateType\(\)'
            $code | Should -Match 'report_date\(table, row\) if name == "report_date_utc"'
        }
    }

    It 'writes one Parquet file per write in both notebooks' {
        foreach ($code in $deploymentCode, $liveCode) {
            $code | Should -Match 'frame\.coalesce\(1\)\.write\.format\("delta"\)\.mode\("append"\)'
            $code | Should -Not -Match '(?m)^\s+frame\.write\.'
        }
    }

    It 'prepares the report tables in the persist cell, after the RCA evidence and both writes, and only when SAVE_RESULTS is True' {
        $persist = @($live.Code | Where-Object { $_.Source -match '^# Persist:' })
        $persist.Count | Should -Be 1
        # The RCA evidence first, so its RCA.EVIDENCE finding is saved with the others (ADR 0031); a reference run that was
        # passed evidence ends with RCA.EVIDENCE as its exit value, after the session's rows.
        $persist[0].Source | Should -Match '(?s)if SAVE_RESULTS:\s+#[^\n]*\n\s+save_rca_evidence\(\)\s+write_delta\("telemetry_snapshots", SNAPSHOT_ROWS\)\s+write_delta\("analysis_findings", FINDINGS\)\s+REPORT_TABLES = prepare_report_tables\(\)\s+#[^\n]*\n\s+SESSION_ROWS = [^\n]*\n\s+if SESSION_ROWS:\s+write_delta\("scenario_runs", SESSION_ROWS\)\s+if REFERENCE_RUN and RCA_STATE\["passed"\] and _notebookutils\(\) is not None:\s+#[^\n]*\n\s+_notebookutils\(\)\.notebook\.exit\(rca_exit_value\(\)\)\s+else:'
    }

    It 'creates missing tables, adds and backfills report_date_utc in UTC, and compacts tables with many files' {
        $prepare = [regex]::Match($liveCode, '(?ms)^def prepare_report_tables\(\):.*?(?=^\S)').Value
        $prepare | Should -Match 'CREATE TABLE IF NOT EXISTS %s \(%s\) USING DELTA'
        $prepare | Should -Match 'ALTER TABLE %s ADD COLUMNS \(report_date_utc DATE\)'
        $prepare | Should -Match '_sql_in_utc\(session, "UPDATE %s SET report_date_utc = to_date\(coalesce\(%s\)\) WHERE report_date_utc IS NULL"'
        $prepare | Should -Match 'DESCRIBE DETAIL %s'
        $prepare | Should -Match 'OPTIMIZE %s'
        $liveCode | Should -Match '(?m)^OPTIMIZE_FILE_THRESHOLD = 200$'
        $liveCode | Should -Match 'session\.conf\.set\("spark\.sql\.session\.timeZone", "UTC"\)'
        $prepare | Should -Not -Match '\bDROP\b'
    }

    It 'merges incident windows on incident_key and unions detected episodes with stored ones' {
        $liveCode | Should -Match 'MERGE INTO incident_windows AS target USING incident_windows_updates AS source "\s+"ON target\.incident_key = source\.incident_key'
        $liveCode | Should -Match '(?m)^def union_episodes\(stored, detected\):'
        $liveCode | Should -Match '(?m)^def reconcile_recorded\(recorded, stored\):'
        $liveCode | Should -Match '"request:%s" % window\["request_id"\]'
        $liveCode | Should -Match '"detected:%s:%s:%s" % \(episode\["target"\], family, episode\["start"\]\.strftime\("%Y%m%dT%H%M"\)\)'
        $liveCode | Should -Match '"incident_sort": -int\(start\.timestamp\(\) // 60\)'
        # Deletes touch only keys the notebook built itself.
        $liveCode | Should -Match '_INCIDENT_KEY = re\.compile\(r"\(request\|detected\):\[A-Za-z0-9:\._-\]\{1,120\}"\)'
        $liveCode | Should -Match 'if _INCIDENT_KEY\.fullmatch\(key\)'
    }

    It 'sets the detection defaults in the parameters cell and validates them' {
        $parameters = @($live.Code | Where-Object { @($_.Metadata['tags']) -contains 'parameters' })[0].Source
        $parameters | Should -Match '(?m)^EPISODE_CPU_PERCENT = 80\b'
        $parameters | Should -Match '(?m)^EPISODE_PAGEIOLATCH_SECONDS = 1\b'
        $parameters | Should -Match '(?m)^EPISODE_MIN_BINS = 2\b'
        $liveCode | Should -Match 'raise ValueError\("EPISODE_CPU_PERCENT must be'
        $liveCode | Should -Match '\("blocking", 0\.0, True, 1\),\s+\("cpu", EPISODE_CPU_PERCENT, False, EPISODE_MIN_BINS\),\s+\("io", EPISODE_PAGEIOLATCH_SECONDS, False, EPISODE_MIN_BINS\),\s+\("log_rate", 0\.0, True, 1\),'
    }

    It 'detects episodes with signal_episodes, which blocking_incidents reuses' {
        $liveCode | Should -Match '(?m)^def signal_episodes\(series, threshold, bin_minutes, min_bins, strict=False\):'
        $blocking = [regex]::Match($liveCode, '(?ms)^def blocking_incidents\(.*?(?=^\S)').Value
        $blocking | Should -Match 'signal_episodes\(blocked, 0, bin_minutes, 1, strict=True\)'
        # expected_signals moved to the helpers, so preparing the report tables doesn't need section 8 to run first.
        $helpers = @($live.Code | Where-Object { $_.Source -match '^# Helpers, part 2' })[0].Source
        $helpers | Should -Match '(?m)^def expected_signals\(profile\):'
        ([regex]::Matches($liveCode, '(?m)^def expected_signals\(')).Count | Should -Be 1
    }

    It 'knows every incident scenario in scenarios/ with its expected signal' {
        $scenarioFolder = Join-Path -Path $repoRoot -ChildPath 'scenarios'
        # T4-only scenarios (connection-surge, idle-in-transaction, replica-lag) have no scenario windows here: T4's metrics
        # aren't in the telemetry endpoint. Its history comes from POSTGRES_METRICS instead (ADR 0025). The same goes for
        # T5-only ones (ru-storm) and COSMOS_METRICS (2026-11-18, ADR 0027).
        $scenarios = @(Get-ChildItem -LiteralPath $scenarioFolder -Directory | Where-Object {
                $_.Name -ne 'healthy-baseline' -and @((Get-Content -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'scenario.json') -Raw | ConvertFrom-Json).targets.applicable | Where-Object { $_ -notin 'T4', 'T5' }).Count -gt 0
            })
        $scenarios.Count | Should -BeGreaterThan 5
        $signals = [regex]::Match($liveCode, '(?s)SCENARIO_SIGNALS = \{(.*?)\n\}').Groups[1].Value
        foreach ($scenario in $scenarios) {
            $signals | Should -Match ('"{0}": \(' -f [regex]::Escape($scenario.Name))
        }
        $signals | Should -Match '"resource-governance": \("cpu",\)'
        $signals | Should -Match '"log-rate-pressure": \("log_rate",\)'
    }

    It 'writes nothing outside the lakehouse and keeps the resource-changing gates' {
        foreach ($name in 'prepare_report_tables', 'merge_incident_windows', 'incident_window_rows', 'union_episodes') {
            $body = [regex]::Match($liveCode, "(?ms)^def $name\(.*?(?=^\S)").Value
            $body | Should -Not -BeNullOrEmpty
            $body | Should -Not -Match 'https://|requests\.|dispatch_workflow|submit_simulation_request|getSecret|get_token'
        }
    }

    It 'drops incident_windows and every Incident RCA table in the deployment notebook''s cleanup, with the staged evidence and the acknowledgements, and says the semantic model needs the tables back' {
        $cleanup = @($deployment.Code | Where-Object { $_.Source -match '^# RESOURCE-CHANGING CELL: drops' })[0].Source
        $tables = @([regex]::Matches([regex]::Match($cleanup, '(?s)DEMO_TABLES = \((.*?)\)\n').Groups[1].Value, '"(\w+)"') | ForEach-Object { $_.Groups[1].Value })
        $purge = (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'rca/history-tables.json') -Raw | ConvertFrom-Json).purge
        $tables | Should -Be (@('validation_results', 'scenario_runs', 'telemetry_snapshots', 'analysis_findings', 'incident_windows') + @($purge))
        $cleanup | Should -Match ('DEMO_FOLDERS = \({0}\)' -f [regex]::Escape((@((Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'rca/history-tables.json') -Raw | ConvertFrom-Json).purgeFiles) | ForEach-Object { '"{0}"' -f $_ }) -join ', '))
        $cleanup | Should -Match 'SM_DatabaseHub_History'
        $cleanup | Should -Match 'NB_DatabaseHub_LiveActivity runs with SAVE_RESULTS = True and recreates the tables'
    }

    It 'runs signal_episodes and report_date as specified when pandas is available' {
        $python = $pandasPython
        if (-not $python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $PSNativeCommandUseErrorActionPreference = $false
        $null = & $python -c 'import pandas' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because 'pandas is not installed for this Python'
            return
        }
        $script = Join-Path -Path $TestDrive -ChildPath 'episodes.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import datetime as dt, json, sys, types
import pandas as pd
sys.modules.setdefault("requests", types.SimpleNamespace(RequestException=Exception))
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"]]
ns = {}
for index, cell in enumerate(cells):
    if cell.startswith(("# Parameters cell", "# Helpers, part")):
        exec(compile(cell, "cell-%d" % index, "exec"), ns)
base = pd.Timestamp("2026-10-21T14:00:00Z")
series = pd.DataFrame({"Target": "T2", "Bucket": [base + pd.Timedelta(minutes=i) for i in range(6)], "Value": [40, 85, 90, 40, 95, 40]})
episodes = ns["signal_episodes"](series, ns["EPISODE_CPU_PERCENT"], 1, ns["EPISODE_MIN_BINS"])
assert [(e["start"], e["end"], e["peak"]) for e in episodes] == [(base + pd.Timedelta(minutes=1), base + pd.Timedelta(minutes=3), 90.0)], episodes
assert len(ns["signal_episodes"](series, 0, 1, 1, strict=True)) == 1
east = dt.timezone(dt.timedelta(hours=-4))
assert ns["report_date"]("telemetry_snapshots", {"bucket_utc": dt.datetime(2026, 10, 21, 22, 30, tzinfo=east)}) == dt.date(2026, 10, 22)
assert ns["report_date"]("scenario_runs", {"window_start_utc": None, "requested_at_utc": base}) == dt.date(2026, 10, 21)
print("ok")
'@
        $output = & $python $script $live.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }

    It 'expects connection-surge''s connections, never IO by a keyword inside a word, and counts T4''s slots from the template''s max_connections (F34)' {
        # Live (2026-11-21): the surge's refused attempts weren't in Azure Monitor's failed connections; its connections reached
        # the slots clients can use. The notebook and the app count those slots the same way, from config/versions.json.
        $postgres = (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable)['postgresql']
        $liveCode | Should -Match ('(?m)^POSTGRES_MAX_CONNECTIONS = {0}$' -f $postgres['maxConnections'])
        $liveCode | Should -Match '(?m)^POSTGRES_RESERVED_CONNECTIONS = 15$'
        $insights = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'fabric/app/src/lib/insights.ts') -Raw
        $insights | Should -Match ('export const POSTGRES_MAX_CONNECTIONS = {0};' -f $postgres['maxConnections'])
        $insights | Should -Match 'export const POSTGRES_RESERVED_CONNECTIONS = 15;'
        (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'fabric/app/src/lib/scoreboard.ts') -Raw) | Should -Match '"connection-surge": \["connections"\]'
        $python = $pandasPython
        if (-not $python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $PSNativeCommandUseErrorActionPreference = $false
        $null = & $python -c 'import pandas' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because 'pandas is not installed for this Python'
            return
        }
        $script = Join-Path -Path $TestDrive -ChildPath 'expected.py'
        Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @'
import json, sys, types
sys.modules.setdefault("requests", types.SimpleNamespace(RequestException=Exception))
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"]]
ns = {}
for index, cell in enumerate(cells):
    if cell.startswith(("# Parameters cell", "# Helpers, part")):
        exec(compile(cell, "cell-%d" % index, "exec"), ns)
signals = ns["expected_signals"]
print(json.dumps({profile: list(signals("incident:" + profile)) for profile in ("connection-surge", "idle-in-transaction", "io-pressure", "session-locking", "index-io-mix", "ru-storm")}))
'@
        $output = & $python $script $live.Path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $expected = ($output | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable
        @($expected['connection-surge']) | Should -Be @('connections')
        # Before, "io" inside "connection", "transaction", and "session" read as IO pressure.
        @($expected['idle-in-transaction']) | Should -Be @('activity')
        @($expected['session-locking']) | Should -Be @('blocking')
        @($expected['io-pressure']) | Should -Be @('io')
        @($expected['index-io-mix']) | Should -Be @('cpu', 'io')
        @($expected['ru-storm']) | Should -Be @('activity')
    }
}
