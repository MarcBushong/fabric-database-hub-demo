BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    # Obviously fake IDs: every group repeats one digit; the sessions repeat one byte.
    $script:workspaceId = '13131313-1313-1313-1313-131313131313'
    $script:lakehouseId = '14141414-1414-1414-1414-141414141414'
    $script:sessionA = 'a1' * 16
    $script:sessionB = 'b2' * 16
    $script:schemaPath = Join-Path -Path $repoRoot -ChildPath 'rca/transport.schema.json'
    $script:sidecarFilePattern = (Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json -AsHashtable)['$defs']['sidecarFile']['pattern']

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['fabric']['workspaceId'] = $script:workspaceId
        $config['fabric']['lakehouseId'] = $script:lakehouseId
        return $config
    }

    # A sidecar as the runner seals it (rca/README.md, The sidecar and Part lines): a version 1 ContosoCare.RcaSidecar,
    # gzipped and cut into DBHUBDEMO-RCAS lines of 2,400 bytes of gzip; -NoiseBytes of incompressible text make it span
    # several parts.
    function New-TestSidecar([string] $DocumentId, [string] $SessionId = '', [int] $NoiseBytes = 0) {
        $random = [System.Random]::new($DocumentId.GetHashCode())
        $noise = [byte[]]::new($NoiseBytes)
        $random.NextBytes($noise)
        $session = if ($SessionId) { $SessionId } else { $null }
        $document = [ordered]@{
            kind = 'ContosoCare.RcaSidecar'; version = 1; documentId = $DocumentId; sessionId = $session; producer = [ordered]@{ host = 'sqlvm01'; version = 'test' }
            exportedUtc = '2026-11-20T17:31:00.000Z'; sequence = 1; final = $true; windowStartUtc = '2026-11-20T17:00:00.000Z'; windowEndUtc = '2026-11-20T17:15:00.000Z'
            targets = @('T1'); epochUtc = '2026-11-20T17:00:00.000Z'; strings = @('T1', [System.Convert]::ToBase64String($noise)); tables = [ordered]@{}
        }
        $plain = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $document -Depth 10 -Compress))
        $memory = [System.IO.MemoryStream]::new()
        $gzip = [System.IO.Compression.GZipStream]::new($memory, [System.IO.Compression.CompressionLevel]::Optimal, $true)
        $gzip.Write($plain, 0, $plain.Length)
        $gzip.Dispose()
        $bytes = $memory.ToArray()
        $sha = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $count = [int][System.Math]::Ceiling($bytes.Length / 2400.0)
        $lines = [string[]]@(for ($index = 0; $index -lt $count; $index++) {
                'DBHUBDEMO-RCAS 1 {0} {1}/{2} {3} {4}' -f $DocumentId, ($index + 1), $count, $sha, [System.Convert]::ToBase64String($bytes, $index * 2400, [System.Math]::Min(2400, $bytes.Length - $index * 2400))
            })
        return [pscustomobject]@{ Id = $DocumentId; SessionId = $session; Sha = $sha; Lines = $lines }
    }

    function Add-TestSidecar([string] $Vm, [object] $Sidecar) {
        $script:vms[$Vm].Sidecars[$Sidecar.Id] = [pscustomobject]@{ Sidecar = $Sidecar; Acked = $false }
    }

    function Get-TestControlLine([string] $Action, [string] $Status, [string] $Message, [string] $Evidence = '{}') {
        'DBHUBDEMO-WORKLOAD {{"marker":"DBHUBDEMO-WORKLOAD","action":"{0}","status":"{1}","message":"{2}","evidence":{3}}}' -f $Action, $Status, $Message, $Evidence
    }

    # What the VM-side control prints for each sidecar action on a fake VM, whose runner keeps its sidecars until 'rca ack'
    # (rca/README.md, The runner's commands): RcaSidecarExport's result line and index page, RcaAck's result line, and the
    # Rca action's part line.
    function Get-TestSidecarOutput([string] $Vm, [string] $Action, [System.Collections.IDictionary] $Request) {
        $state = $script:vms[$Vm]
        if ($Action -eq 'RcaAck') {
            if ($state.AckOutput) {
                return $state.AckOutput
            }
            foreach ($id in @($Request['documentIds'])) {
                if ($state.Sidecars.Contains([string]$id)) {
                    $state.Sidecars[[string]$id].Acked = $true
                }
            }
            return (Get-TestControlLine 'RcaAck' 'Pass' 'runner rca ack: acknowledged.')
        }
        if ($Action -eq 'RcaSidecarExport') {
            if ($state.ExportOutput) {
                return $state.ExportOutput
            }
            $waiting = @($state.Sidecars.Values | Where-Object { -not $_.Acked })
            if ($waiting.Count -eq 0) {
                return (Get-TestControlLine 'RcaSidecarExport' 'Not selected' 'runner rca sidecar-export: nothing to fetch.')
            }
            $page = [int]$Request['page']
            $documents = @(foreach ($item in @($waiting | Select-Object -Skip (($page - 1) * 8) -First 8)) {
                    $offered = if ($state.Offered.ContainsKey($item.Sidecar.Id)) { 'pending' } else { 'new' }
                    $state.Offered[$item.Sidecar.Id] = $true
                    [ordered]@{ documentId = $item.Sidecar.Id; sessionId = $item.Sidecar.SessionId; parts = $item.Sidecar.Lines.Count; sha256 = $item.Sidecar.Sha; state = $offered }
                })
            $index = ConvertTo-Json -InputObject ([ordered]@{ kind = 'ContosoCare.RcaSidecarIndex'; version = 1; page = $page; pages = [int][System.Math]::Ceiling($waiting.Count / 8.0); documents = $documents; status = $state.IndexStatus; message = $state.IndexMessage }) -Depth 5 -Compress
            return ((Get-TestControlLine 'RcaSidecarExport' 'Pass' 'runner rca sidecar-export: its line follows.') + "`n" + 'DBHUBDEMO-RCAS-INDEX ' + $index)
        }
        $id = [string]$Request['documentId']
        if (-not $state.Sidecars.Contains($id)) {
            return (Get-TestControlLine 'Rca' 'Fail' 'runner rca part: exit code 1.')
        }
        return ((Get-TestControlLine 'Rca' 'Pass' 'runner rca part: its line follows.') + "`n" + $state.Sidecars[$id].Sidecar.Lines[[int]$Request['part'] - 1])
    }

    # Managed Run Command on two fake VMs, through the module's one Azure CLI door (Invoke-DemoAz): create, read, list, and
    # delete. A delete on the T2 host takes one more read, or one more list, before the Run Command is gone, as Azure's do.
    function Initialize-TestSidecarAzure {
        $script:vms = @{
            sqlvm01   = [pscustomobject]@{ Sidecars = [ordered]@{}; Offered = @{}; ExportOutput = ''; AckOutput = ''; IndexStatus = 'Pass'; IndexMessage = 'sidecars' }
            archost01 = [pscustomobject]@{ Sidecars = [ordered]@{}; Offered = @{}; ExportOutput = ''; AckOutput = ''; IndexStatus = 'Pass'; IndexMessage = 'sidecars' }
        }
        $script:fake = @{
            Commands    = @{ sqlvm01 = [ordered]@{}; archost01 = [ordered]@{} }
            DeleteReads = @{ sqlvm01 = 0; archost01 = 1 }
            MostAtOnce  = @{ sqlvm01 = 0; archost01 = 0 }
            Requests    = [System.Collections.Generic.List[object]]::new()
            Deleted     = [System.Collections.Generic.List[string]]::new()
            Calls       = [System.Collections.Generic.List[string]]::new()
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $list = @($ArgumentList)
            $script:fake.Calls.Add(($list -join ' '))
            $method = [string]$list[[array]::IndexOf($list, '--method') + 1]
            $url = [string]$list[[array]::IndexOf($list, '--url') + 1]
            $answer = { param([object] $Body) [pscustomobject]@{ ExitCode = 0; StdOut = $(if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 8 -Compress } else { '' }); StdErr = '' } }
            $gone = [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (NotFound) The Resource was not found.' }
            if ($list[0] -ne 'rest' -or $url -notmatch '^https://management\.azure\.com/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/virtualMachines/(?<vm>[^/]+)/runCommands(/(?<name>[^?]+))?\?api-version=') {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'not a Run Command call' }
            }
            $vm = $Matches['vm']
            $name = $Matches['name']
            $commands = $script:fake.Commands[$vm]
            if ($method -eq 'put') {
                $body = Get-Content -LiteralPath ([string]$list[[array]::IndexOf($list, '--body') + 1]).Substring(1) -Raw | ConvertFrom-Json
                $encoded = [regex]::Match([string]$body.properties.source.script, "-RequestBase64 '([A-Za-z0-9+/=]+)'").Groups[1].Value
                $request = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded)) | ConvertFrom-Json -AsHashtable
                $action = [regex]::Match([string]$body.properties.source.script, "-Action '([A-Za-z]+)'").Groups[1].Value
                $commands[$name] = @{ Request = $request; Action = $action; Reads = 0; Deleting = -1 }
                $script:fake.Requests.Add([pscustomobject]@{ Vm = $vm; Name = $name; Request = $request; Action = $action })
                $script:fake.MostAtOnce[$vm] = [System.Math]::Max($script:fake.MostAtOnce[$vm], $commands.Count)
                return (& $answer @{})
            }
            if ($method -eq 'delete') {
                if ($commands.Contains($name)) {
                    $script:fake.Deleted.Add(('{0}/{1}' -f $vm, $name))
                    if ($script:fake.DeleteReads[$vm] -le 0) {
                        $commands.Remove($name)
                    }
                    elseif ($commands[$name].Deleting -lt 0) {
                        $commands[$name].Deleting = $script:fake.DeleteReads[$vm]
                    }
                }
                return (& $answer $null)
            }
            if (-not $name) {
                # Azure finishes the deletes it was asked for over time.
                foreach ($key in @($commands.Keys)) {
                    $entry = $commands[$key]
                    if ($entry.Deleting -eq 0) {
                        $commands.Remove($key)
                    }
                    elseif ($entry.Deleting -gt 0) {
                        $entry.Deleting--
                    }
                }
                return (& $answer @{ value = @($commands.Keys | ForEach-Object { @{ name = $_; properties = @{ provisioningState = $(if ($commands[$_].Deleting -ge 0) { 'Deleting' } else { 'Succeeded' }); instanceView = @{ executionState = 'Running' } } } }) })
            }
            if (-not $commands.Contains($name)) {
                return $gone
            }
            $entry = $commands[$name]
            if ($entry.Deleting -ge 0) {
                if ($entry.Deleting -eq 0) {
                    $commands.Remove($name)
                    return $gone
                }
                $entry.Deleting--
                return (& $answer @{ properties = @{ provisioningState = 'Deleting'; instanceView = @{ executionState = 'Succeeded' } } })
            }
            $entry.Reads++
            if ($entry.Reads -lt 2) {
                return (& $answer @{ properties = @{ provisioningState = 'Creating'; instanceView = @{ executionState = 'Running' } } })
            }
            $output = Get-TestSidecarOutput -Vm $vm -Action $entry.Action -Request $entry.Request
            return (& $answer @{ properties = @{ provisioningState = 'Succeeded'; instanceView = @{ executionState = 'Succeeded'; exitCode = 0; output = $output; startTime = '2026-11-20T17:31:00Z' } } })
        }
    }

    # The demo lakehouse's Files, through OneLake's ADLS Gen2 API (Invoke-DemoOneLakeRequest): create, append, flush,
    # read, and delete.
    function Initialize-TestLake {
        $script:lake = [ordered]@{}
        $script:oneLake = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoStorageToken -MockWith { [securestring]::new() }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoOneLakeRequest -MockWith {
            # A read or a delete passes no -Query, and strict mode doesn't bind an unbound parameter in a mock.
            $Query = [string]$PesterBoundParameters['Query']
            $script:oneLake.Add(('{0} {1}?{2}' -f $Method, $Path, $Query))
            $key = $Path.Substring(37)
            $reply = { param([int] $Code, [string] $Content = '') [pscustomobject]@{ StatusCode = $Code; Headers = @{}; Content = $Content } }
            switch ($Method) {
                'Put' { $script:lake[$key] = ''; return (& $reply 201) }
                'Patch' {
                    if ($Query -like 'action=append*') {
                        $script:lake[$key] += [System.Text.Encoding]::UTF8.GetString($Body)
                        return (& $reply 202)
                    }
                    return (& $reply 200)
                }
                'Get' {
                    if ($script:lake.Contains($key)) {
                        return (& $reply 200 ([string]$script:lake[$key]))
                    }
                    return (& $reply 404 '{"error":{"code":"PathNotFound","message":"The specified path does not exist."}}')
                }
                'Delete' {
                    if (-not $script:lake.Contains($key)) {
                        return (& $reply 404)
                    }
                    $script:lake.Remove($key)
                    return (& $reply 200)
                }
            }
        }
    }

    # NB_DatabaseHub_LiveActivity's sidecar cells, as B's notebook does them (rca/README.md, Acknowledgement): it reads the
    # payload RCA_SIDECAR_FILE names, writes each sidecar once (already when the history has it), acknowledges the payload
    # by ID in Files/rca/acks, and deletes the payload when every sidecar in it is written or already was. Mode: ack, none
    # (no acknowledgement: the run doesn't save results), stale-payload, or stale-documents.
    function Initialize-TestNotebook {
        $script:history = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $script:notebook = [pscustomobject]@{ Mode = 'ack'; Skip = @{}; JobStatus = 'Completed'; Knows = $true; Minutes = 0; Runs = [System.Collections.Generic.List[object]]::new() }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricNotebookParameter -MockWith { [pscustomobject]@{ Known = $true; Has = ($Parameter -ne 'RCA_SIDECAR_FILE' -or $script:notebook.Knows); Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -MockWith {
            $file = [string]$Parameter['RCA_SIDECAR_FILE']
            $copy = [ordered]@{}
            foreach ($key in @($Parameter.Keys)) {
                $copy[[string]$key] = $Parameter[$key]
            }
            $script:notebook.Runs.Add([pscustomobject]@{ Parameter = $copy; Content = $(if ($file -and $script:lake.Contains($file)) { [string]$script:lake[$file] } else { '' }); TimeoutMinutes = $TimeoutMinutes })
            $script:clock = $script:clock.AddMinutes($script:notebook.Minutes)
            if ($file -and $script:lake.Contains($file) -and $script:notebook.JobStatus -eq 'Completed' -and $script:notebook.Mode -ne 'none') {
                $payload = $script:lake[$file] | ConvertFrom-Json -AsHashtable
                $ids = @($payload['parts'] | ForEach-Object { $_.Split(' ')[2] } | Select-Object -Unique)
                $entries = [System.Collections.Generic.List[object]]::new()
                foreach ($id in $ids) {
                    if ($script:notebook.Skip.ContainsKey($id)) {
                        $entries.Add([ordered]@{ documentId = $id; kind = 'ContosoCare.RcaSidecar'; status = 'skipped'; reason = $script:notebook.Skip[$id] })
                    }
                    elseif ($script:history.Contains($id)) {
                        $entries.Add([ordered]@{ documentId = $id; kind = 'ContosoCare.RcaSidecar'; status = 'already' })
                    }
                    else {
                        $null = $script:history.Add($id)
                        $entries.Add([ordered]@{ documentId = $id; kind = 'ContosoCare.RcaSidecar'; status = 'written' })
                    }
                }
                $named = if ($script:notebook.Mode -eq 'stale-payload') { 'Files/rca/inbox/sidecar-20261101T000000Z.json' } else { $file }
                $listed = if ($script:notebook.Mode -eq 'stale-documents') { @($entries | Select-Object -Skip 1) } else { $entries.ToArray() }
                $name = $file.Substring($file.LastIndexOf('/') + 1) -replace '\.json$', ''
                $script:lake[('Files/rca/acks/{0}.ack.json' -f $name)] = ConvertTo-Json -InputObject ([ordered]@{ kind = 'ContosoCare.RcaAck'; version = 1; payload = $named; runId = 'run-test'; documents = @($listed) }) -Depth 5 -Compress
                if (@($entries | Where-Object { $_['status'] -eq 'skipped' }).Count -eq 0) {
                    $script:lake.Remove($file)
                }
            }
            $status = switch ($script:notebook.JobStatus) { 'Completed' { 'Pass' } 'Failed' { 'Fail' } default { 'Warning' } }
            New-DemoResult -CheckId 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY' -Area 'fabric' -Target 'fabric' -Status $status -Message 'ran' -Evidence @{ status = $script:notebook.JobStatus; seconds = 90 }
        }
    }

    # One history save as the scripts run it: the fetch after the evidence document's export, the run that stages the
    # first batch (Invoke-DemoRcaNotebookRun), with -Drain the runs for what's left, and the end (Complete-DemoRcaSidecarSave),
    # whose acknowledgements go at once with -Now, as deploy.ps1's snapshot and configure-fabric.ps1 send them, or are
    # deferred, as stop-demo.ps1 -SaveHistory keeps them.
    function Invoke-TestSave([string] $Prefix = 'DEPLOY', [switch] $Final, [int] $Runs = 3, [switch] $Now, [switch] $Drain, [switch] $NoRun) {
        $arguments = @{ Config = $script:config; CheckPrefix = $Prefix; Final = [bool]$Final; State = $script:state; Power = $script:power; PendingDirectory = $script:pendingDirectory; Runs = $Runs; Minutes = 60; PollSeconds = 1 }
        $sidecar = InModuleScope DbHubDemo -Parameters @{ A = $arguments } { Invoke-DemoRcaSidecarFetch @A }
        $run = $null
        if (-not $NoRun) {
            $run = InModuleScope DbHubDemo -Parameters @{ C = $script:config; S = $sidecar } { Invoke-DemoRcaNotebookRun -Config $C -Parameter ([ordered]@{ SAVE_RESULTS = $true; RESOURCE_GROUP = 'rg-dbhub-demo'; WINDOW_MINUTES = 1440 }) -Token ([securestring]::new()) -Sidecar $S }
        }
        if ($Drain) {
            InModuleScope DbHubDemo -Parameters @{ C = $script:config; S = $sidecar } { Invoke-DemoRcaSidecarDrain -Config $C -Sidecar $S -Token ([securestring]::new()) -Parameter ([ordered]@{ SAVE_RESULTS = $true; RESOURCE_GROUP = 'rg-dbhub-demo'; WINDOW_MINUTES = 1440 }) -PollSeconds 1 }
        }
        $line = InModuleScope DbHubDemo -Parameters @{ C = $script:config; S = $sidecar; N = [bool]$Now } { Complete-DemoRcaSidecarSave -Config $C -Sidecar $S -Now:$N -Why 'the session''s history wasn''t saved' -PollSeconds 1 }
        return [pscustomobject]@{ Sidecar = $sidecar; Run = $run; Line = $line }
    }

    function Read-TestList([string] $Which) {
        $path = Join-Path -Path $script:pendingDirectory -ChildPath ('rca-sidecar-{0}-rg-dbhub-demo.json' -f $Which)
        if (-not (Test-Path -LiteralPath $path)) {
            return $null
        }
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)
    }

    function Get-TestRequest([string] $Vm = '', [string] $Action = '') {
        @($script:fake.Requests | Where-Object { (-not $Vm -or $_.Vm -eq $Vm) -and (-not $Action -or $_.Action -eq $Action) })
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'The Incident RCA''s sidecars from the scripts (2026-11-23, rca/README.md, The sidecar)' {
    BeforeEach {
        $script:config = New-TestConfig
        $script:state = [pscustomobject]@{ RunnerSha256 = ('ab' * 32); RunnerSentTo = @('sqlvm01', 'archost01'); Tags = @{ deploymentId = 'abc123' } }
        $script:power = @{ sqlvm01 = 'PowerState/running'; archost01 = 'PowerState/running' }
        $script:pendingDirectory = Join-Path -Path $TestDrive -ChildPath ('pending-' + [guid]::NewGuid().ToString('N'))
        # A clock that moves 5 seconds a read, so a deadline comes without waiting for it.
        $script:clock = [datetime]::new(2026, 11, 23, 17, 30, 0, [System.DateTimeKind]::Utc)
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $script:clock = $script:clock.AddSeconds(5); $script:clock }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Initialize-TestSidecarAzure
        Initialize-TestLake
        Initialize-TestNotebook
    }

    It 'reads every page of <Count> sidecars and fetches each once, through the sidecar''s actions (F8)' -ForEach @(@{ Count = 9 }, @{ Count = 17 }) {
        $made = @(for ($n = 1; $n -le $Count; $n++) { New-TestSidecar -DocumentId ('20261120T1{0:d5}Z-sqlvm01-{1:d4}-sidecar' -f $n, $n) -SessionId $script:sessionA })
        foreach ($sidecar in $made) {
            Add-TestSidecar -Vm 'sqlvm01' -Sidecar $sidecar
        }
        $save = Invoke-TestSave -Now
        $pages = [int][System.Math]::Ceiling($Count / 8.0)
        @(Get-TestRequest -Vm 'sqlvm01' -Action 'RcaSidecarExport' | ForEach-Object { [int]$_.Request['page'] }) | Should -Be @(1..$pages)
        foreach ($item in (Get-TestRequest -Action 'RcaSidecarExport')) {
            $item.Request['sessionId'] | Should -Be '' -Because 'the scripts export with --session none'
            $item.Request['final'] | Should -BeFalse
            $item.Name | Should -Match ('^DbHubDemo-Rca-{0}-i[0-9]{{2}}-[0-9]{{14}}$' -f $item.Vm)
        }
        $parts = @(Get-TestRequest -Vm 'sqlvm01' -Action 'Rca')
        @($parts | ForEach-Object { '{0}/{1}' -f $_.Request['documentId'], $_.Request['part'] } | Sort-Object -Unique).Count | Should -Be @($made | ForEach-Object { $_.Lines.Count } | Measure-Object -Sum).Sum
        $parts.Count | Should -Be @($made | ForEach-Object { $_.Lines.Count } | Measure-Object -Sum).Sum -Because 'each part is fetched once'
        @($parts | ForEach-Object { $_.Request['command'] } | Select-Object -Unique) | Should -Be @('part')
        @($save.Sidecar.Fetched.Keys | Sort-Object) | Should -Be @($made.Id | Sort-Object)
        $payload = $script:notebook.Runs[0].Content | ConvertFrom-Json
        @($payload.parts | ForEach-Object { $_.Split(' ')[2] } | Sort-Object -Unique) | Should -Be @($made.Id | Sort-Object)
        @($payload.parts).Count | Should -Be @($payload.parts | Sort-Object -Unique).Count -Because 'each sidecar goes once'
        $save.Line.checkId | Should -Be 'DEPLOY.RCA.SIDECAR'
        $save.Line.status | Should -Be 'Pass'
        $save.Line.message | Should -BeLike ('{0} RCA sidecar(s) fetched from sqlvm01, {0} sent with 1 history run(s): {0} written, 0 already in the history. {0} acknowledged on sqlvm01, *' -f $Count)
        # Every Run Command is deleted once it's read, so no part of the evidence stays in an instance view.
        @($script:fake.Deleted | Sort-Object) | Should -Be @($script:fake.Requests | ForEach-Object { '{0}/{1}' -f $_.Vm, $_.Name } | Sort-Object)
        @($script:fake.Calls | Where-Object { $_ -notmatch '^rest --method (get|put|delete) --url https://management\.azure\.com/.+/virtualMachines/(sqlvm01|archost01)/runCommands' }) | Should -BeNullOrEmpty
    }

    It 'fetches one VM''s sidecars when the other''s bundle or runner predates them, and says ./scripts/deploy.ps1 fixes it (M2: <Case>)' -ForEach @(
        @{ Case = 'OldBundle'; Output = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"RcaSidecarExport","status":"Fail","message":"Unknown action; use EnableT3, EnableT4, Runner, StopGuest, or Rca.","evidence":{}}'; Said = 'archost01''s bootstrap bundle predates the RCA sidecar, so no sidecar was fetched from it; ./scripts/deploy.ps1 sends the current one.' }
        @{ Case = 'OldRunner'; Output = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"RcaSidecarExport","status":"Not supported","message":"runner rca sidecar-export: this VM''s runner predates the sidecar.","evidence":{"oldRunner":true}}'; Said = 'archost01''s workload runner predates the RCA sidecar, so no sidecar was fetched from it; ./scripts/deploy.ps1 updates it.' }
    ) {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        Add-TestSidecar -Vm 'archost01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-arcsql01-0001-sidecar')
        $script:vms['archost01'].ExportOutput = $Output
        $save = Invoke-TestSave -Now
        @($save.Sidecar.Fetched.Keys) | Should -Be @('20261120T170000Z-sqlvm01-0001-sidecar')
        @($save.Sidecar.Hosts | ForEach-Object { '{0}: {1}' -f $_.Vm, $_.Outcome }) | Should -Be @('sqlvm01: ', ('archost01: {0}' -f $Case))
        Get-TestRequest -Vm 'archost01' -Action 'Rca' | Should -BeNullOrEmpty
        $script:vms['sqlvm01'].Sidecars['20261120T170000Z-sqlvm01-0001-sidecar'].Acked | Should -BeTrue -Because 'one VM''s outcome is its own'
        $save.Line.status | Should -Be 'Warning'
        $save.Line.message | Should -Match ([regex]::Escape($Said))
        $save.Line.remediation | Should -Match ([regex]::Escape('Run ./scripts/deploy.ps1, which updates the runner and its bootstrap bundle on the VMs.'))
    }

    # 8afcca24: 'rca sidecar-export' exits 2 only when nothing is offerable, and prints its index line either way, whose
    # status stands: a Warning counts sidecars the runner let expire unread.
    It 'takes the index line''s Warning on exit code 2 as its VM''s own, and reads that VM whole (8afcca24: <Case>)' -ForEach @(
        @{ Case = 'today''s control script, Not selected'; Result = 'Not selected'; Said = 'runner rca sidecar-export: there is no sidecar to fetch.' }
        @{ Case = 'T2b''s next, the line''s Warning'; Result = 'Warning'; Said = '3 sidecar(s) expired unread: sealed more than 30 days ago and never acknowledged.' }
    ) {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        $index = 'DBHUBDEMO-RCAS-INDEX {"kind":"ContosoCare.RcaSidecarIndex","version":1,"page":1,"pages":0,"documents":[],"status":"Warning","message":"3 sidecar(s) expired unread: sealed more than 30 days ago and never acknowledged."}'
        $script:vms['archost01'].ExportOutput = (Get-TestControlLine 'RcaSidecarExport' $Result $Said '{"exitCode":2}') + "`n" + $index
        $save = Invoke-TestSave -Now
        @($save.Sidecar.Fetched.Keys) | Should -Be @('20261120T170000Z-sqlvm01-0001-sidecar')
        $archost = @($save.Sidecar.Hosts | Where-Object { $_.Vm -eq 'archost01' })[0]
        $archost.Outcome | Should -BeNullOrEmpty -Because 'nothing was offerable there, and that''s no failure'
        $archost.IndexComplete | Should -BeTrue
        $save.Line.status | Should -Be 'Warning'
        $save.Line.message | Should -Match ([regex]::Escape('archost01''s runner says: 3 sidecar(s) expired unread: sealed more than 30 days ago and never acknowledged.'))
        @($save.Line.evidence.runner) | Should -Be @('archost01: 3 sidecar(s) expired unread: sealed more than 30 days ago and never acknowledged.')
        $save.Line.remediation | Should -Match ([regex]::Escape('after Run all sessions, which leave theirs on the VMs until Run all takes them itself (a later release), ./scripts/start-demo.ps1, then ./scripts/stop-demo.ps1 -SaveHistory.'))
        $script:vms['sqlvm01'].Sidecars['20261120T170000Z-sqlvm01-0001-sidecar'].Acked | Should -BeTrue
    }

    It 'fetches what an index offers on exit code 0 and says what its Warning counts, once for its VM (8afcca24)' {
        foreach ($n in 1..9) {
            Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId ('20261120T1700{0:d2}Z-sqlvm01-{0:d4}-sidecar' -f $n) -SessionId $script:sessionA)
        }
        $script:vms['sqlvm01'].IndexStatus = 'Warning'
        $script:vms['sqlvm01'].IndexMessage = '1 sidecar(s) expired unread: sealed more than 30 days ago and never acknowledged.'
        $save = Invoke-TestSave -Now
        @(Get-TestRequest -Vm 'sqlvm01' -Action 'RcaSidecarExport').Count | Should -Be 2 -Because 'both pages carry the Warning'
        @($save.Sidecar.Fetched.Keys).Count | Should -Be 9
        $save.Line.status | Should -Be 'Warning'
        ([regex]::Matches($save.Line.message, [regex]::Escape('sqlvm01''s runner says: 1 sidecar(s) expired unread'))).Count | Should -Be 1
        $save.Line.message | Should -Match '9 acknowledged on sqlvm01'
    }

    It 'keeps a VM''s pending sidecars when its Warning comes without an index line, since its index isn''t known whole (8afcca24)' {
        $null = New-Item -ItemType Directory -Path $script:pendingDirectory -Force
        $list = [ordered]@{
            kind     = 'DbHubDemo.RcaSidecarPending'; version = 1
            sidecars = @([ordered]@{ documentId = '20261121T170000Z-arcsql01-0002-sidecar'; vm = 'archost01'; sessionId = $null; parts = 1; sha256 = ('c' * 64); reason = 'not acknowledged'; firstSeenUtc = '2026-11-21T18:00:00Z'; expiresUtc = '2026-12-21T17:00:00Z' })
        }
        Set-Content -LiteralPath (Join-Path -Path $script:pendingDirectory -ChildPath 'rca-sidecar-pending-rg-dbhub-demo.json') -Value (ConvertTo-Json -InputObject $list -Depth 5) -Encoding utf8NoBOM
        $script:vms['archost01'].ExportOutput = Get-TestControlLine 'RcaSidecarExport' 'Warning' '2 sidecar(s) expired unread.' '{"exitCode":2}'
        $save = Invoke-TestSave -Now
        $archost = @($save.Sidecar.Hosts | Where-Object { $_.Vm -eq 'archost01' })[0]
        $archost.Outcome | Should -BeNullOrEmpty
        $archost.IndexComplete | Should -BeFalse
        @((Read-TestList 'pending')['sidecars'] | ForEach-Object { $_['documentId'] }) | Should -Be @('20261121T170000Z-arcsql01-0002-sidecar') -Because 'a VM not read whole may still offer it'
        $save.Line.message | Should -Match ([regex]::Escape('archost01''s runner says: 2 sidecar(s) expired unread.'))
        $save.Line.evidence.expired | Should -Be 0
    }

    It 'tells a bundle from before the sidecar by its answer to <Action>, recorded from today''s control script, which names Rca (T2b)' -ForEach @(@{ Action = 'RcaSidecarExport' }, @{ Action = 'RcaAck' }) {
        $today = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"' + $Action + '","status":"Fail","message":"Unknown action; use EnableT3, EnableT4, Runner, StopGuest, or Rca.","evidence":{}}'
        $current = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"' + $Action + '","status":"Fail","message":"Unknown action; use EnableT3, EnableT4, Runner, StopGuest, Rca, RcaSidecarExport, or RcaAck.","evidence":{}}'
        InModuleScope DbHubDemo -Parameters @{ Today = $today; Current = $current; Action = $Action } {
            (ConvertFrom-DemoRcaRunOutput -Output $Today -Sidecar -Action $Action).OldBundle | Should -BeTrue
            (ConvertFrom-DemoRcaRunOutput -Output $Current -Sidecar -Action $Action).OldBundle | Should -BeFalse -Because 'a bundle whose list names the action has it'
        }
    }

    It 'keeps a VM''s deferred acknowledgements, and asks it nothing more, when its bundle answers RcaAck as one from before the sidecar (M2)' {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        Add-TestSidecar -Vm 'archost01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-arcsql01-0001-sidecar' -SessionId $script:sessionA)
        $null = Invoke-TestSave -Prefix 'STOP' -Final -Runs 1
        foreach ($action in 'RcaAck', 'RcaSidecarExport') {
            $old = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"' + $action + '","status":"Fail","message":"Unknown action; use EnableT3, EnableT4, Runner, StopGuest, or Rca.","evidence":{}}'
            if ($action -eq 'RcaAck') { $script:vms['archost01'].AckOutput = $old } else { $script:vms['archost01'].ExportOutput = $old }
        }
        $script:fake.Requests.Clear()
        $next = Invoke-TestSave -Now
        @(Get-TestRequest -Vm 'archost01' | ForEach-Object { $_.Action }) | Should -Be @('RcaAck') -Because 'its answer says its bundle has none of the sidecar''s actions'
        @($next.Sidecar.Hosts | ForEach-Object { '{0}: {1}' -f $_.Vm, $_.Outcome }) | Should -Be @('sqlvm01: ', 'archost01: OldBundle')
        @((Read-TestList 'acks')['acknowledgements'] | ForEach-Object { '{0}@{1}' -f $_['documentId'], $_['vm'] }) | Should -Be @('20261120T170000Z-arcsql01-0001-sidecar@archost01')
        $next.Line.status | Should -Be 'Warning'
        $next.Line.message | Should -Match ([regex]::Escape('archost01''s bootstrap bundle predates the RCA sidecar, so nothing of its sidecars was fetched or acknowledged; ./scripts/deploy.ps1 sends the current one.'))
        $next.Line.remediation | Should -Match ([regex]::Escape('Run ./scripts/deploy.ps1, which updates the runner and its bootstrap bundle on the VMs.'))
    }

    It 'lets the PC''s workload control send <Action> to a VM' -ForEach @(@{ Action = 'RcaSidecarExport' }, @{ Action = 'RcaAck' }) {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoActionRunCommand -MockWith { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'the fake VM is away' } }
        $answer = InModuleScope DbHubDemo -Parameters @{ C = $script:config; A = $Action } {
            $text = Get-DemoWorkloadControlScript -Action $A -Request ([ordered]@{ timeoutSeconds = 120 })
            $text | Should -Match ([regex]::Escape(('-Action ''{0}'' -RequestBase64 ''' -f $A)))
            Invoke-DemoWorkloadAction -Config $C -VmName 'sqlvm01' -Action $A -Request ([ordered]@{ timeoutSeconds = 120 })
        }
        $answer['action'] | Should -Be $Action
        Should -Invoke -CommandName Invoke-DemoActionRunCommand -ModuleName DbHubDemo -Times 1 -Exactly -ParameterFilter { $Script -match ('-Action ''{0}''' -f $Action) }
    }

    It 'defers the stop''s acknowledgements, then sends them first at the next export, whose index no longer offers them (F6, the order)' {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        Add-TestSidecar -Vm 'archost01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-arcsql01-0001-sidecar' -SessionId $script:sessionA)
        $stop = Invoke-TestSave -Prefix 'STOP' -Final -Runs 1
        $stop.Line.checkId | Should -Be 'STOP.RCA.SIDECAR'
        $stop.Line.status | Should -Be 'Pass'
        $stop.Line.message | Should -Match '2 acknowledgement\(s\) wait for the next export on archost01 and sqlvm01, which sends them first, since the stop deallocated the VMs before the notebook ran \(.*rca-sidecar-acks-rg-dbhub-demo\.json lists them\)\.'
        foreach ($item in (Get-TestRequest -Action 'RcaSidecarExport')) {
            $item.Request['final'] | Should -BeTrue -Because 'the stop''s save is the session''s last'
        }
        Get-TestRequest -Action 'RcaAck' | Should -BeNullOrEmpty -Because 'the VMs are deallocated before the notebook runs'
        $acks = Read-TestList 'acks'
        @($acks['acknowledgements'] | ForEach-Object { '{0}@{1}:{2}' -f $_['documentId'], $_['vm'], $_['status'] } | Sort-Object) | Should -Be @('20261120T170000Z-arcsql01-0001-sidecar@archost01:written', '20261120T170000Z-sqlvm01-0001-sidecar@sqlvm01:written')
        Read-TestList 'pending' | Should -BeNullOrEmpty

        # The next export with the VMs running: each VM's acknowledgement goes first, so the index offers nothing again.
        $script:fake.Requests.Clear()
        $next = Invoke-TestSave -Now
        foreach ($vm in 'sqlvm01', 'archost01') {
            $mine = @(Get-TestRequest -Vm $vm)
            $mine[0].Action | Should -Be 'RcaAck' -Because ('{0}''s deferred acknowledgement goes before its sidecar export' -f $vm)
            $mine[1].Action | Should -Be 'RcaSidecarExport'
        }
        @((Get-TestRequest -Vm 'sqlvm01' -Action 'RcaAck')[0].Request['documentIds']) | Should -Be @('20261120T170000Z-sqlvm01-0001-sidecar')
        @($next.Sidecar.Offered.Keys) | Should -BeNullOrEmpty -Because 'a sidecar the runner was told is in the history isn''t offered again'
        Get-TestRequest -Action 'Rca' | Should -BeNullOrEmpty
        Read-TestList 'acks' | Should -BeNullOrEmpty
        $next.Line.status | Should -Be 'Pass'
        $next.Line.message | Should -Match '2 acknowledgement\(s\) an earlier save deferred went to the VMs first\.'
    }

    It 'keeps a VM''s acknowledgements in the list when ''rca ack'' fails there, and sends them first at the next export (F5)' {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        Add-TestSidecar -Vm 'archost01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-arcsql01-0001-sidecar' -SessionId $script:sessionA)
        $null = Invoke-TestSave -Prefix 'STOP' -Final -Runs 1
        $script:vms['archost01'].AckOutput = Get-TestControlLine 'RcaAck' 'Fail' 'runner rca ack: exit code 3.'
        $script:fake.Requests.Clear()
        $second = Invoke-TestSave -Now
        @((Read-TestList 'acks')['acknowledgements'] | ForEach-Object { '{0}@{1}' -f $_['documentId'], $_['vm'] }) | Should -Be @('20261120T170000Z-arcsql01-0001-sidecar@archost01') -Because 'sqlvm01 took its own'
        # archost01 offers its sidecar again; the notebook answers already, and the tables don't change.
        @($second.Sidecar.Fetched.Keys) | Should -Be @('20261120T170000Z-arcsql01-0001-sidecar')
        $second.Line.message | Should -Match '0 written, 1 already in the history'
        $second.Line.message | Should -Match 'didn''t reach archost01 \(runner rca ack: exit code 3\); they go first at the next export there\.'
        $second.Line.status | Should -Be 'Warning'
        $second.Line.remediation | Should -Match 'The next history save takes what waits'

        $script:vms['archost01'].AckOutput = ''
        $script:fake.Requests.Clear()
        $third = Invoke-TestSave -Now
        (Get-TestRequest -Vm 'archost01')[0].Action | Should -Be 'RcaAck'
        @((Get-TestRequest -Vm 'archost01' -Action 'RcaAck')[0].Request['documentIds']) | Should -Be @('20261120T170000Z-arcsql01-0001-sidecar')
        Read-TestList 'acks' | Should -BeNullOrEmpty
        $third.Line.status | Should -Be 'Pass'
    }

    It 'acknowledges only what the notebook wrote, keeps a skipped sidecar pending with its reason, and the next save fetches only it (F1)' {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T171500Z-sqlvm01-0002-sidecar' -SessionId $script:sessionA)
        $script:notebook.Skip['20261120T171500Z-sqlvm01-0002-sidecar'] = 'its version 2 is newer than this notebook''s 1'
        $first = Invoke-TestSave -Now
        $acks = @(Get-TestRequest -Action 'RcaAck')
        $acks.Count | Should -Be 1
        @($acks[0].Request['documentIds']) | Should -Be @('20261120T170000Z-sqlvm01-0001-sidecar')
        $pending = (Read-TestList 'pending')['sidecars']
        @($pending | ForEach-Object { '{0}: {1}' -f $_['documentId'], $_['reason'] }) | Should -Be @('20261120T171500Z-sqlvm01-0002-sidecar: skipped by the notebook (its version 2 is newer than this notebook''s 1)')
        $pending[0]['vm'] | Should -Be 'sqlvm01'
        $pending[0]['sessionId'] | Should -Be $script:sessionA
        $first.Line.status | Should -Be 'Warning'
        $first.Line.message | Should -Match '1 sidecar\(s\) wait on the VMs, which keep them: 1 skipped by the notebook \(its version 2 is newer than this notebook''s 1\)'
        @($script:lake.Keys | Where-Object { $_ -like 'Files/rca/inbox/sidecar-*' }).Count | Should -Be 1 -Because 'the notebook keeps a payload that holds a skipped sidecar, and the scripts never delete one a run read'

        $script:notebook.Skip.Clear()
        $script:fake.Requests.Clear()
        $second = Invoke-TestSave -Now
        @(Get-TestRequest -Action 'Rca' | ForEach-Object { $_.Request['documentId'] } | Select-Object -Unique) | Should -Be @('20261120T171500Z-sqlvm01-0002-sidecar')
        Read-TestList 'pending' | Should -BeNullOrEmpty
        $second.Line.status | Should -Be 'Pass'
    }

    It 'acknowledges nothing, keeps everything pending, and warns, when the notebook wrote no acknowledgement (F3)' {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        Add-TestSidecar -Vm 'archost01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-arcsql01-0001-sidecar')
        $script:notebook.Mode = 'none'
        $save = Invoke-TestSave -Now
        Get-TestRequest -Action 'RcaAck' | Should -BeNullOrEmpty
        Read-TestList 'acks' | Should -BeNullOrEmpty
        @((Read-TestList 'pending')['sidecars'] | ForEach-Object { $_['reason'] } | Select-Object -Unique) | Should -Be @('not acknowledged: the notebook wrote no acknowledgement of them (its run failed, timed out, or didn''t save its results)')
        $save.Line.status | Should -Be 'Warning'
        $save.Line.remediation | Should -Be 'The next history save takes what waits: ./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity while the VMs run, again while this line says sidecars wait.'
    }

    It 'counts a stale acknowledgement as missing (F4: <Mode>)' -ForEach @(
        @{ Mode = 'stale-payload'; Why = 'their acknowledgement names another payload' }
        @{ Mode = 'stale-documents'; Why = 'their acknowledgement lists other sidecars than were sent' }
    ) {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T171500Z-sqlvm01-0002-sidecar')
        $script:notebook.Mode = $Mode
        $save = Invoke-TestSave -Now
        Get-TestRequest -Action 'RcaAck' | Should -BeNullOrEmpty
        @((Read-TestList 'pending')['sidecars']).Count | Should -Be 2
        @((Read-TestList 'pending')['sidecars'] | ForEach-Object { $_['reason'] } | Select-Object -Unique) | Should -Be @('not acknowledged: {0}' -f $Why)
        $save.Line.status | Should -Be 'Warning'
    }

    It 'stages two earlier Run all sessions'' sidecars and one of no session in one payload, as the notebook gets it (F7)' {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        Add-TestSidecar -Vm 'archost01' -Sidecar (New-TestSidecar -DocumentId '20261121T090000Z-arcsql01-0001-sidecar' -SessionId $script:sessionB -NoiseBytes 3000)
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261123T100000Z-sqlvm01-0002-sidecar')
        $save = Invoke-TestSave -Now
        $run = $script:notebook.Runs[0]
        $run.Parameter['RCA_SIDECAR_FILE'] | Should -Match $script:sidecarFilePattern
        $run.Parameter['RCA_SIDECAR_FILE'] | Should -Match '^Files/rca/inbox/sidecar-[0-9]{8}T[0-9]{6}Z-script-[0-9a-f]{8}\.json$' -Because 'the notebook''s sweep matches that name, and its day-old sweep of evidence files never does'
        $run.Parameter['SAVE_RESULTS'] | Should -BeTrue
        $run.Parameter.Contains('RCA_ONLY') | Should -BeFalse
        $schemaErrors = $null
        Test-Json -Json $run.Content -SchemaFile $script:schemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors | Should -BeTrue -Because ($schemaErrors | Out-String)
        $payload = $run.Content | ConvertFrom-Json -AsHashtable
        $payload['kind'] | Should -Be 'ContosoCare.RcaSidecarParts'
        $payload['sessionId'] | Should -BeNullOrEmpty -Because 'each sidecar goes under its own session''s run, whichever run reads it'
        $expected = @($script:vms['sqlvm01'].Sidecars['20261123T100000Z-sqlvm01-0002-sidecar'].Sidecar.Lines) + @($script:vms['sqlvm01'].Sidecars['20261120T170000Z-sqlvm01-0001-sidecar'].Sidecar.Lines) + @($script:vms['archost01'].Sidecars['20261121T090000Z-arcsql01-0001-sidecar'].Sidecar.Lines)
        @($payload['parts']) | Should -Be $expected -Because 'the one of no session goes first, then the others, oldest first'
        @($payload['parts'] | ForEach-Object { $_.Split(' ')[2] } | Select-Object -Unique).Count | Should -Be 3
        $save.Line.status | Should -Be 'Pass'
        $save.Line.evidence.written | Should -Be 3
    }

    It 'stages none for a notebook that doesn''t declare RCA_SIDECAR_FILE, keeps them pending, and names the notebook''s command' {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        $script:notebook.Knows = $false
        $save = Invoke-TestSave -Now
        $script:notebook.Runs[0].Parameter.Contains('RCA_SIDECAR_FILE') | Should -BeFalse
        @($script:oneLake | Where-Object { $_ -like 'Put *' }) | Should -BeNullOrEmpty
        (Read-TestList 'pending')['sidecars'][0]['reason'] | Should -Be 'not sent: the workspace''s NB_DatabaseHub_LiveActivity doesn''t know RCA_SIDECAR_FILE yet'
        $save.Line.status | Should -Be 'Warning'
        $save.Line.remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity -RunLiveActivity'))
    }

    It 'deletes a payload no run read, and keeps its sidecars pending (<Status>)' -ForEach @(@{ Status = 'Deduped'; Why = 'not read: the history run was deduplicated' }) {
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        $script:notebook.JobStatus = $Status
        $null = Invoke-TestSave -Now
        @($script:lake.Keys | Where-Object { $_ -like 'Files/rca/inbox/*' }) | Should -BeNullOrEmpty
        (Read-TestList 'pending')['sidecars'][0]['reason'] | Should -Be $Why
    }

    It 'takes whole sidecars up to 64 parts a run, runs the notebook again for what''s left within its bounds, and names the rest (F9)' {
        $made = @(for ($n = 1; $n -le 7; $n++) { New-TestSidecar -DocumentId ('20261120T1{0:d5}Z-sqlvm01-{1:d4}-sidecar' -f $n, $n) -SessionId $script:sessionA -NoiseBytes 57000 })
        $size = @($made | ForEach-Object { $_.Lines.Count } | Select-Object -Unique)
        $size.Count | Should -Be 1 -Because 'the test''s sidecars are the same size'
        $size[0] | Should -BeGreaterThan 21 -Because 'three of them are more than 64 parts'
        $size[0] | Should -BeLessOrEqual 32 -Because 'two of them fit in 64 parts'
        foreach ($sidecar in $made) {
            Add-TestSidecar -Vm 'sqlvm01' -Sidecar $sidecar
        }
        $save = Invoke-TestSave -Now -Drain
        $script:notebook.Runs.Count | Should -Be 3 -Because 'at most 3 runs carry sidecars in one save'
        foreach ($run in $script:notebook.Runs) {
            @(($run.Content | ConvertFrom-Json).parts).Count | Should -Be (2 * $size[0]) -Because 'two whole sidecars fit in 64 parts, and a third doesn''t'
        }
        foreach ($run in @($script:notebook.Runs | Select-Object -Skip 1)) {
            $run.Parameter['RCA_ONLY'] | Should -BeTrue -Because 'a drain''s run writes only the sidecars, not a second snapshot'
            $run.Parameter['SAVE_RESULTS'] | Should -BeFalse
            $run.Parameter['RESOURCE_GROUP'] | Should -Be 'rg-dbhub-demo'
        }
        # The seventh was never fetched: it waits on the VM, and the line names it.
        @(Get-TestRequest -Action 'Rca' | Where-Object { $_.Request['documentId'] -eq $made[6].Id }) | Should -BeNullOrEmpty
        @((Read-TestList 'pending')['sidecars'] | ForEach-Object { '{0}: {1}' -f $_['documentId'], $_['reason'] }) | Should -Be @(('{0}: past what this save''s history runs take (64 parts a run)' -f $made[6].Id))
        @((Get-TestRequest -Action 'RcaAck') | ForEach-Object { @($_.Request['documentIds']) } | Sort-Object) | Should -Be @($made[0..5].Id | Sort-Object)
        $save.Line.status | Should -Be 'Warning'
        $save.Line.message | Should -BeLike '6 RCA sidecar(s) fetched from sqlvm01, 6 sent with 3 history run(s)*1 sidecar(s) wait on the VMs, which keep them: 1 past what this save''s history runs take (64 parts a run)*'

        # The next save takes the seventh, nothing lost or doubled.
        $script:notebook.Runs.Clear()
        $next = Invoke-TestSave -Now -Drain
        $script:notebook.Runs.Count | Should -Be 1
        @(($script:notebook.Runs[0].Content | ConvertFrom-Json).parts | ForEach-Object { $_.Split(' ')[2] } | Select-Object -Unique) | Should -Be @($made[6].Id)
        $script:history.Count | Should -Be 7
        $next.Line.status | Should -Be 'Pass'

        # A stop's save runs the notebook once, and fetches only what that run takes.
        Initialize-TestSidecarAzure
        Initialize-TestNotebook
        foreach ($sidecar in $made) {
            Add-TestSidecar -Vm 'sqlvm01' -Sidecar $sidecar
        }
        $stop = Invoke-TestSave -Prefix 'STOP' -Final -Runs 1
        $script:notebook.Runs.Count | Should -Be 1
        @(Get-TestRequest -Action 'Rca' | ForEach-Object { $_.Request['documentId'] } | Select-Object -Unique | Sort-Object) | Should -Be @($made[0..1].Id | Sort-Object)
        $stop.Line.message | Should -Match '5 sidecar\(s\) wait on the VMs'
    }

    It 'starts no drain run once its 15 minutes have passed (F9)' {
        foreach ($n in 1..4) {
            Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId ('20261120T1{0:d5}Z-sqlvm01-{1:d4}-sidecar' -f $n, $n) -SessionId $script:sessionA -NoiseBytes 57000)
        }
        $script:notebook.Minutes = 15
        $null = Invoke-TestSave -Now -Drain
        $script:notebook.Runs.Count | Should -Be 2 -Because 'the first drain run used the 15 minutes'
        $script:notebook.Runs[1].TimeoutMinutes | Should -BeLessOrEqual 15
    }

    It 'stages at most 64 parts and 262,144 bytes of whole sidecars, and leaves the one past either (L3)' {
        InModuleScope DbHubDemo {
            $id = { param([int] $N) '20261120T1{0:d5}Z-sqlvm01-{1:d4}-sidecar' -f $N, $N }
            $references = @(for ($n = 1; $n -le 32; $n++) { [ordered]@{ documentId = (& $id $n); sessionId = $null; parts = 2; sha256 = ('a' * 64); vm = 'sqlvm01' } })
            @(Select-DemoRcaSidecarBatch -Reference $references).Count | Should -Be 32 -Because '32 sidecars of 2 parts are 64 parts'
            $over = $references + @([ordered]@{ documentId = (& $id 33); sessionId = $null; parts = 1; sha256 = ('a' * 64); vm = 'sqlvm01' })
            @(Select-DemoRcaSidecarBatch -Reference $over) | Should -Not -Contain (& $id 33)

            # Part lines of 3,400 characters, the longest the contract takes: 64 of them fit in 262,144 bytes.
            $line = { param([int] $N, [int] $Part, [int] $Count) $head = 'DBHUBDEMO-RCAS 1 {0} {1}/{2} {3} ' -f (& $id $N), $Part, $Count, ('a' * 64); $head + ('A' * (3400 - $head.Length)) }
            $lines = [ordered]@{}
            foreach ($n in 1..3) {
                $count = if ($n -lt 3) { 28 } else { 8 }
                $lines[(& $id $n)] = [string[]]@(for ($part = 1; $part -le $count; $part++) { & $line $n $part $count })
            }
            $payload = New-DemoRcaSidecarPayload -Line $lines
            @($payload.Ids).Count | Should -Be 3
            $payload.Parts | Should -Be 64
            $payload.Bytes | Should -BeLessOrEqual 262144
            $lines[(& $id 4)] = [string[]]@(& $line 4 1 1)
            $grown = New-DemoRcaSidecarPayload -Line $lines
            @($grown.Left) | Should -Be @((& $id 4)) -Because 'a 65th part is one too many'
            $grown.Parts | Should -Be 64

            # The bytes: exactly at the limit fits; a byte under the payload's size leaves the last sidecar.
            $three = [ordered]@{}
            foreach ($key in @($lines.Keys | Select-Object -First 2)) {
                $three[$key] = $lines[$key]
            }
            $size = (New-DemoRcaSidecarPayload -Line $three).Bytes
            @((New-DemoRcaSidecarPayload -Line $three -MaxBytes $size).Ids).Count | Should -Be 2
            $cut = New-DemoRcaSidecarPayload -Line $three -MaxBytes ($size - 1)
            @($cut.Ids) | Should -Be @((& $id 1))
            @($cut.Left) | Should -Be @((& $id 2))
        }
    }

    It 'says which sidecars expired unread, and drops them from the list (F11)' {
        $null = New-Item -ItemType Directory -Path $script:pendingDirectory -Force
        $entry = { param([string] $Id, [string] $Vm, [string] $Seen, [string] $Expires) [ordered]@{ documentId = $Id; vm = $Vm; sessionId = $null; parts = 1; sha256 = ('c' * 64); reason = 'not acknowledged'; firstSeenUtc = $Seen; expiresUtc = $Expires } }
        $list = [ordered]@{
            kind     = 'DbHubDemo.RcaSidecarPending'; version = 1
            sidecars = @(
                # Its VM, read whole, no longer offers it, and it's past its 30 days: the runner deleted it unread.
                (& $entry '20261020T170000Z-sqlvm01-0001-sidecar' 'sqlvm01' '2026-10-21T08:00:00Z' '2026-11-19T17:00:00Z')
                # Its VM isn't running, and the list first saw it 31 days ago, so it was sealed before then.
                (& $entry '20261021T170000Z-arcsql01-0001-sidecar' 'archost01' '2026-10-23T08:00:00Z' '2026-11-20T17:00:00Z')
                # Its VM isn't running, and it's recent: it waits.
                (& $entry '20261121T170000Z-arcsql01-0002-sidecar' 'archost01' '2026-11-21T18:00:00Z' '2026-12-21T17:00:00Z')
            )
        }
        Set-Content -LiteralPath (Join-Path -Path $script:pendingDirectory -ChildPath 'rca-sidecar-pending-rg-dbhub-demo.json') -Value (ConvertTo-Json -InputObject $list -Depth 5) -Encoding utf8NoBOM
        $script:power['archost01'] = 'PowerState/deallocated'
        $save = Invoke-TestSave -Now
        @((Read-TestList 'pending')['sidecars'] | ForEach-Object { '{0}: {1}' -f $_['documentId'], $_['reason'] }) | Should -Be @('20261121T170000Z-arcsql01-0002-sidecar: not fetched: archost01 isn''t running, so what its observer captured stays on it until the next export.')
        $save.Line.status | Should -Be 'Warning'
        $save.Line.message | Should -Match '2 sidecar\(s\) expired unread: the runner keeps one 30 days after its sealing, and no save took it in time\.'
        $save.Line.evidence.expired | Should -Be 2
        $save.Line.remediation | Should -Match 'stop-demo\.ps1 -SaveHistory'
    }

    It 'never loses a list it can''t read: it''s kept aside, and a new one starts' {
        $null = New-Item -ItemType Directory -Path $script:pendingDirectory -Force
        $pendingPath = Join-Path -Path $script:pendingDirectory -ChildPath 'rca-sidecar-pending-rg-dbhub-demo.json'
        $acksPath = Join-Path -Path $script:pendingDirectory -ChildPath 'rca-sidecar-acks-rg-dbhub-demo.json'
        Set-Content -LiteralPath $pendingPath -Value '{ "kind": "DbHubDemo.RcaSidecarPending", "version": 1, "sidecars": [ {' -Encoding utf8NoBOM
        Set-Content -LiteralPath $acksPath -Value '{ "kind": "DbHubDemo.RcaSidecarAcks", "version": 2, "acknowledgements": [] }' -Encoding utf8NoBOM
        Add-TestSidecar -Vm 'sqlvm01' -Sidecar (New-TestSidecar -DocumentId '20261120T170000Z-sqlvm01-0001-sidecar' -SessionId $script:sessionA)
        $save = Invoke-TestSave -Now
        $aside = @(Get-ChildItem -LiteralPath $script:pendingDirectory -Filter '*.unreadable-*.json' | Sort-Object -Property Name)
        $aside.Count | Should -Be 2
        (Get-Content -LiteralPath ($aside | Where-Object Name -Like 'rca-sidecar-pending-*').FullName -Raw).Trim() | Should -Be '{ "kind": "DbHubDemo.RcaSidecarPending", "version": 1, "sidecars": [ {'
        (Get-Content -LiteralPath ($aside | Where-Object Name -Like 'rca-sidecar-acks-*').FullName -Raw) | Should -Match '"version": 2'
        $save.Line.status | Should -Be 'Warning'
        $save.Line.message | Should -Match 'The PC''s list .*rca-sidecar-pending-rg-dbhub-demo\.json couldn''t be read \(it isn''t JSON'
        $save.Line.message | Should -Match 'rca-sidecar-acks-rg-dbhub-demo\.json couldn''t be read \(it isn''t a DbHubDemo\.RcaSidecarAcks list of version 1\), so it was kept as '
        $save.Line.evidence.written | Should -Be 1 -Because 'the save goes on'
    }

    It 'reads an acknowledgement that OneLake returns as bytes as its text' {
        $json = '{"kind":"ContosoCare.RcaAck","version":1}'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoOneLakeRequest -MockWith { throw 'not this one' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = [System.Text.Encoding]::UTF8.GetBytes($json) } }
        $answer = InModuleScope DbHubDemo -Parameters @{ W = $script:workspaceId; L = $script:lakehouseId } { & (Get-Command -Name Invoke-DemoOneLakeRequest -CommandType Function) -Method Get -WorkspaceId $W -Path ('{0}/Files/rca/acks/sidecar-20261123T173000Z-script-1a2b3c4d.ack.json' -f $L) -Token ([securestring]::new()) }
        $answer.Content | Should -BeExactly $json
    }
}
