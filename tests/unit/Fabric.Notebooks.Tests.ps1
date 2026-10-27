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

    It 'defaults GITHUB_REPOSITORY to the public repository, which the import replaces with github.repository' {
        $parameters[0].Source | Should -Match '(?m)^GITHUB_REPOSITORY = "MarcBushong/fabric-database-hub-demo"\s*$'
    }

    It 'defaults every safety switch to False' {
        $parameters[0].Source | Should -Match '(?m)^CONFIRM = False\s*$'
        foreach ($switchName in [regex]::Matches($parameters[0].Source, '(?m)^(STOP_ACTIVITY|PURGE_DEMO_TABLES) = (\w+)')) {
            $switchName.Groups[2].Value | Should -Be 'False'
        }
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
                $block | Should -Not -Match 'sum\((WaitTimeMs|WaitingTasksCount|NumOfBytesRead|NumOfBytesWritten|IOStallReadMs|IOStallWriteMs|NumOfReads|NumOfWrites|CounterValue)\)'
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
}

Describe 'NB_DatabaseHub_LiveActivity content' {
    BeforeAll {
        $nb = Get-Notebook -Name 'NB_DatabaseHub_LiveActivity'
        $markdown = ($nb.Cells | Where-Object Type -EQ 'markdown' | ForEach-Object Source) -join "`n"
        $allCode = ($nb.Code | ForEach-Object Source) -join "`n"
        $adrInputs = @('environment', 'target', 'scenario', 'duration', 'concurrency', 'intensity', 'reset-before', 'auto-cleanup')
    }

    It 'narrates section <_>' -ForEach @(
        'Parameters', 'Helpers', 'Simulation control', 'Telemetry access', 'Estate pulse', 'Locks and blocking', 'Overall consumption',
        'Correlation: scenario windows and telemetry', 'See it in the Hub', 'Optional: Real-Time Dashboard', 'Persist', 'Stop and clean up', 'Next steps'
    ) {
        $markdown | Should -Match ('(?m)^## \d+\. ' + [regex]::Escape($_) + '$')
    }

    It 'offers the four activity profiles' {
        $allCode | Should -Match 'PROFILES = \("baseline", "business-day", "off"\)'
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

    It 'sends only the demo-control.yml inputs that ADR 0011 defines' {
        $block = [regex]::Match($allCode, '(?s)    inputs = \{(.*?)\n    \}').Groups[1].Value
        $keys = @([regex]::Matches($block, '"([a-z-]+)":') | ForEach-Object { $_.Groups[1].Value }) + @([regex]::Matches($allCode, 'inputs\["([a-z-]+)"\] =') | ForEach-Object { $_.Groups[1].Value })
        $keys | Should -Not -BeNullOrEmpty
        foreach ($key in $keys) {
            $key | Should -BeIn $adrInputs
        }
        $workflow = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath '.github/workflows/demo-control.yml') -Raw
        $declared = [regex]::Match($workflow, '(?ms)^\s+workflow_dispatch:\s*\n\s+inputs:\s*\n(.*?)(?=^\S|^\s{0,2}\w|\z)')
        if (-not $declared.Success) {
            Set-ItResult -Skipped -Because 'demo-control.yml declares no workflow_dispatch inputs yet (Phase 13)'
            return
        }
        foreach ($key in $keys) {
            $declared.Groups[1].Value | Should -Match ('(?m)^\s+' + [regex]::Escape($key) + ':')
        }
    }

    It 'reads the GitHub token only from Key Vault, and only when P9 is configured' {
        $nb.Code[0].Source | Should -Match '(?m)^KEY_VAULT_URL = ""'
        foreach ($call in [regex]::Matches($allCode, 'getSecret\(([^)]*)\)')) {
            $call.Groups[1].Value | Should -Be 'KEY_VAULT_URL, GITHUB_TOKEN_SECRET_NAME'
        }
        $allCode | Should -Match 'Refusing to send the GitHub token outside this repository'
        $allCode | Should -Match 'GITHUB_API = "https://api\.github\.com"'
    }

    It 'prints the GitHub link and CLI command when P9 is not configured' {
        $allCode | Should -Match 'def print_manual_trigger'
        $allCode | Should -Match '"gh", "workflow", "run", GITHUB_WORKFLOW_FILE'
    }

    It 'records each request in scenario_runs and saves telemetry_snapshots and analysis_findings' {
        $allCode | Should -Match 'write_delta\("scenario_runs", \[record\], replace_run=False\)'
        $allCode | Should -Match 'write_delta\("telemetry_snapshots"'
        $allCode | Should -Match 'write_delta\("analysis_findings"'
    }

    It 'analyzes blocking, consumption, and T3 log-rate governance with charts' {
        foreach ($signal in "'Processes blocked'", "'Active Transactions'", "'Number of Deadlocks/sec'", 'SqlServerActiveSessions', 'SqlServerCPUUtilization', 'SqlServerMemoryUtilization', 'SqlServerStorageIO', 'SqlServerDatabaseStorageUtilization', 'Log Rate Governor', 'PAGEIOLATCH') {
            $allCode | Should -Match ([regex]::Escape($signal))
        }
        $allCode | Should -Match 'import matplotlib\.pyplot as plt'
        $allCode | Should -Match 'axvspan'
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

    It 'prepares the report tables in the persist cell, after both writes and only when SAVE_RESULTS is True' {
        $persist = @($live.Code | Where-Object { $_.Source -match '^# Persist:' })
        $persist.Count | Should -Be 1
        $persist[0].Source | Should -Match '(?s)if SAVE_RESULTS:\s+write_delta\("telemetry_snapshots", SNAPSHOT_ROWS\)\s+write_delta\("analysis_findings", FINDINGS\)\s+REPORT_TABLES = prepare_report_tables\(\)\s+else:'
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

    It 'knows every incident scenario in scenarios/ with its default target and expected signal' {
        $scenarioFolder = Join-Path -Path $repoRoot -ChildPath 'scenarios'
        # T4-only scenarios (connection-surge, idle-in-transaction) have no history in the report: T4's metrics
        # aren't in the telemetry endpoint, and its history export is a follow-up (Phase 24, ADR 0019).
        $scenarios = @(Get-ChildItem -LiteralPath $scenarioFolder -Directory | Where-Object {
                $_.Name -ne 'healthy-baseline' -and @((Get-Content -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'scenario.json') -Raw | ConvertFrom-Json).targets.applicable | Where-Object { $_ -ne 'T4' }).Count -gt 0
            })
        $scenarios.Count | Should -BeGreaterThan 5
        $known = [regex]::Match($liveCode, '(?s)KNOWN_SCENARIOS = \((.*?)\)').Groups[1].Value
        $defaults = [regex]::Match($liveCode, '(?s)SCENARIO_DEFAULT_TARGET = \{(.*?)\}').Groups[1].Value
        $signals = [regex]::Match($liveCode, '(?s)SCENARIO_SIGNALS = \{(.*?)\n\}').Groups[1].Value
        foreach ($scenario in $scenarios) {
            $definition = Get-Content -LiteralPath (Join-Path -Path $scenario.FullName -ChildPath 'scenario.json') -Raw | ConvertFrom-Json
            $known | Should -Match ('"{0}"' -f [regex]::Escape($scenario.Name))
            $defaults | Should -Match ('"{0}": "{1}"' -f [regex]::Escape($scenario.Name), @($definition.targets.default)[0])
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

    It 'drops incident_windows in the deployment notebook''s cleanup and says the semantic model needs the tables back' {
        $cleanup = @($deployment.Code | Where-Object { $_.Source -match '^# RESOURCE-CHANGING CELL: drops' })[0].Source
        $cleanup | Should -Match 'DEMO_TABLES = \("validation_results", "scenario_runs", "telemetry_snapshots", "analysis_findings", "incident_windows"\)'
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
}
