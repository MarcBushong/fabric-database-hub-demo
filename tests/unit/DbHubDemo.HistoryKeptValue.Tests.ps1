BeforeAll {
    # F35 (2026-11-23): Fabric's Livy client (FabricLivyHelpers.ps1), the history's kept values through it
    # (Invoke-DemoHistoryKeptValue), and deploy.ps1's use of them. Every request is mocked; no test touches the network or
    # the Azure CLI, and every ID is an obvious placeholder.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    $script:api = 'https://api.fabric.microsoft.com/v1'
    $script:workspaceId = '13131313-1313-1313-1313-131313131313'
    $script:lakehouseId = '14141414-1414-1414-1414-141414141414'
    $script:sessions = '{0}/workspaces/{1}/lakehouses/{2}/livyapi/versions/2023-12-01/sessions' -f $script:api, $script:workspaceId, $script:lakehouseId
    $script:stepCode = 'import json; print(json.dumps(kept_value_step(spark)))'
    # The module the steps send: a kept_value.py with kept_value_step, as the notebook's work has it (the branch's own is the
    # groundwork's, which hasn't).
    $script:fakeModule = "def kept_value_step(spark, table=`"telemetry_snapshots`", add_columns=True, run_id=None, everything=False):`n    return {}`n"
    # The fix lines F35's docs name, word for word (the review of c96f790a).
    $script:again = './scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity'
    $script:trackAgain = './scripts/deploy.ps1 -FromStage Fabric'
    $script:asBefore = 'Until a later run works them out, the history''s totals read as before F35, where overlapping saves can count twice.'
    $script:modelBefore = 'This run''s history model reads the release''s form, so its totals read as before F35, where overlapping saves can count twice, until the Fabric track runs again.'
    function Get-TestLater([string] $Again) {
        'Nothing to do now: a later deploy.ps1, stop-demo.ps1 -SaveHistory, or configure-fabric.ps1 -RunLiveActivity works them out; to do it now, run {0}.' -f $Again
    }
    function Get-TestModelLater([string] $Again) {
        'Run {0}: it works out what''s left and deploys the history model in the kept values'' form.' -f $Again
    }

    function ConvertTo-TestSecureString([string] $Value) {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in $Value.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        return $secure
    }
    # Built at run time, so secret scanners don't flag the fixture.
    $script:token = ConvertTo-TestSecureString ('livy' + '-test')

    function New-LivyResponse([int] $Status, [object] $Body) {
        $content = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { '' }
        [pscustomobject]@{ StatusCode = $Status; Headers = @{}; Content = $content }
    }

    function New-StatementAnswer([int] $Id, [string] $Text, [string] $Status = 'ok', [string] $ErrorName = '', [string] $ErrorValue = '') {
        $output = if ($Status -eq 'ok') { @{ status = 'ok'; data = @{ 'text/plain' = $Text } } } else { @{ status = 'error'; ename = $ErrorName; evalue = $ErrorValue } }
        New-LivyResponse 200 @{ id = $Id; state = 'available'; output = $output }
    }

    # kept_value_step's JSON line, every key there (the resolve module's interface), with -Change over the defaults.
    function New-StepLine([hashtable] $Change = @{}) {
        $step = [ordered]@{ version = 1; table = 'telemetry_snapshots'; exists = $true; missing = @('grain_minutes', 'kept_value', 'resolved_at_utc'); added = @('grain_minutes', 'kept_value', 'resolved_at_utc'); form = 'Kept'; scope = 'unresolved'; read = 31162; resolved = 29840; pending = 0; attempts = 1; seconds = 41.5; error = $null }
        foreach ($key in $Change.Keys) { $step[$key] = $Change[$key] }
        return ($step | ConvertTo-Json -Depth 5 -Compress)
    }

    # Records every Invoke-WebRequest call and answers it from routes: @{ Method; Match (regex on the URI); Responses }, the
    # last response repeating.
    function Set-LivyRoute([object[]] $Routes) {
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:routes = foreach ($route in $Routes) {
            [pscustomobject]@{ Method = $route.Method; Match = $route.Match; Responses = [System.Collections.Generic.Queue[object]]::new([object[]]$route.Responses) }
        }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $requests.Add([pscustomobject]@{ Method = [string]$Method; Uri = [string]$Uri; Body = (Get-Variable -Name 'Body' -ValueOnly -ErrorAction Ignore) })
            foreach ($route in $routes) {
                if ($route.Method -eq $Method -and [string]$Uri -match $route.Match) {
                    if ($route.Responses.Count -gt 1) { return $route.Responses.Dequeue() }
                    return $route.Responses.Peek()
                }
            }
            throw ('unexpected request {0} {1}' -f $Method, $Uri)
        }
    }

    function Get-StatementCode {
        @($script:requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*/statements' } | ForEach-Object { ($_.Body | ConvertFrom-Json).code })
    }

    # A session that's idle at once, two statements' answers (kept_value.py's text, then the step), and its deletion.
    function Set-KeptValueRoute([object] $Load = (New-StatementAnswer 0 ''), [object] $Step = (New-StatementAnswer 1 ("resolving...`n" + (New-StepLine)))) {
        Set-LivyRoute @(
            @{ Method = 'Post'; Match = 'livyapi/versions/2023-12-01/sessions$'; Responses = @(New-LivyResponse 202 @{ id = 'aaaa-1111'; state = 'not_started' }) }
            @{ Method = 'Get'; Match = '/sessions/aaaa-1111$'; Responses = @(New-LivyResponse 200 @{ state = 'idle' }) }
            @{ Method = 'Post'; Match = '/sessions/aaaa-1111/statements$'; Responses = @($Load, $Step) }
            @{ Method = 'Delete'; Match = '/sessions/aaaa-1111$'; Responses = @(New-LivyResponse 200 $null) }
        )
    }

    function New-TestConfig([switch] $NamesOnly) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        if (-not $NamesOnly) {
            $config['fabric']['workspaceId'] = $script:workspaceId
            $config['fabric']['lakehouseId'] = $script:lakehouseId
        }
        return $config
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Fabric''s Livy client (F35, 2026-11-23)' {
    It 'starts a session on the lakehouse''s Livy endpoint, once, and waits until it''s idle' {
        Set-LivyRoute @(
            @{ Method = 'Post'; Match = 'sessions$'; Responses = @(New-LivyResponse 202 @{ id = 'aaaa-1111'; state = 'not_started' }) }
            @{ Method = 'Get'; Match = '/sessions/aaaa-1111$'; Responses = @((New-LivyResponse 200 @{ state = 'not_started'; fabricSessionStateInfo = @{ state = 'acquiringSession' } }), (New-LivyResponse 200 @{ state = 'starting' }), (New-LivyResponse 200 @{ state = 'idle' })) }
        )
        $open = InModuleScope DbHubDemo -Parameters @{ W = $script:workspaceId; L = $script:lakehouseId; T = $script:token } { Open-DemoLivySession -WorkspaceId $W -LakehouseId $L -Token $T -Name 'dbhub-test' }
        $open.Status | Should -Be 'Idle'
        $open.States | Should -Be @('not_started (acquiringSession)', 'starting', 'idle')
        $open.Session.Uri | Should -Be ('{0}/aaaa-1111' -f $script:sessions)
        $requests[0].Method | Should -Be 'Post'
        $requests[0].Uri | Should -Be $script:sessions
        ($requests[0].Body | ConvertFrom-Json).name | Should -Be 'dbhub-test'
        @($requests | Where-Object Method -NE 'Get').Count | Should -Be 1 -Because 'an idle session is the caller''s to delete'
    }

    It 'says why Fabric didn''t start a session: <Expected>' -TestCases @(
        @{ Status = 403; Body = @{ errorCode = 'InsufficientScopes'; message = 'The caller has no access.' }; Expected = 'Refused' }
        @{ Status = 404; Body = @{ errorCode = 'CapacityNotActive'; message = 'The capacity is not active.' }; Expected = 'CapacityInactive' }
        @{ Status = 400; Body = @{ errorCode = 'BadRequest'; message = 'Something else.' }; Expected = 'Failed' }
    ) {
        param($Status, $Body, $Expected)
        Set-LivyRoute @(@{ Method = 'Post'; Match = 'sessions$'; Responses = @(New-LivyResponse $Status $Body) })
        $open = InModuleScope DbHubDemo -Parameters @{ W = $script:workspaceId; L = $script:lakehouseId; T = $script:token } { Open-DemoLivySession -WorkspaceId $W -LakehouseId $L -Token $T }
        $open.Status | Should -Be $Expected
        $open.Session | Should -BeNullOrEmpty
        $open.Error | Should -Match ('HTTP {0} {1}' -f $Status, $Body.errorCode)
        $requests.Count | Should -Be 1 -Because 'nothing was created, so nothing is deleted, and a create is never sent twice'
    }

    It 'deletes a session that ended, or wasn''t idle in time, before it says so' -TestCases @(
        @{ Answer = @{ state = 'dead'; errorInfo = @(@{ errorCode = 'SparkSessionFailed'; message = 'The session failed to start.' }) }; Expected = 'Ended'; Text = 'the session is dead: SparkSessionFailed The session failed to start' }
        @{ Answer = @{ state = 'not_started'; fabricSessionStateInfo = @{ state = 'queued' } }; Expected = 'TimedOut'; Text = 'still not_started \(queued\) after 1 minutes' }
    ) {
        param($Answer, $Expected, $Text)
        Set-LivyRoute @(
            @{ Method = 'Post'; Match = 'sessions$'; Responses = @(New-LivyResponse 202 @{ id = 'bbbb-2222' }) }
            @{ Method = 'Get'; Match = '/sessions/bbbb-2222$'; Responses = @(New-LivyResponse 200 $Answer) }
            @{ Method = 'Delete'; Match = '/sessions/bbbb-2222$'; Responses = @(New-LivyResponse 200 $null) }
        )
        $open = InModuleScope DbHubDemo -Parameters @{ W = $script:workspaceId; L = $script:lakehouseId; T = $script:token } { Open-DemoLivySession -WorkspaceId $W -LakehouseId $L -Token $T -TimeoutSeconds 60 -PollSeconds 5 }
        $open.Status | Should -Be $Expected
        $open.Error | Should -Match $Text
        $open.Session | Should -BeNullOrEmpty
        @($requests | Where-Object Method -EQ 'Delete').Count | Should -Be 1
    }

    It 'runs a statement, waits for it, and returns what it printed' {
        Set-LivyRoute @(
            @{ Method = 'Post'; Match = '/statements$'; Responses = @(New-LivyResponse 200 @{ id = 7; state = 'waiting' }) }
            @{ Method = 'Get'; Match = '/statements/7$'; Responses = @((New-LivyResponse 200 @{ id = 7; state = 'running' }), (New-StatementAnswer 7 "1`n")) }
        )
        $session = [pscustomobject]@{ Uri = ('{0}/cccc-3333' -f $script:sessions); Id = 'cccc-3333'; Name = 'dbhub-test'; Token = $script:token }
        $run = InModuleScope DbHubDemo -Parameters @{ S = $session } { Invoke-DemoLivyStatement -Session $S -Code 'print(1)' }
        $run.Status | Should -Be 'Ok'
        $run.Output.Trim() | Should -Be '1'
        $run.StatementId | Should -Be '7'
        $body = $requests[0].Body | ConvertFrom-Json
        $body.code | Should -Be 'print(1)'
        $body.kind | Should -Be 'pyspark'
    }

    It 'returns the exception of a statement that raised' {
        Set-LivyRoute @(@{ Method = 'Post'; Match = '/statements$'; Responses = @(New-StatementAnswer 2 '' 'error' 'AnalysisException' '[TABLE_OR_VIEW_NOT_FOUND] telemetry_snapshots') })
        $session = [pscustomobject]@{ Uri = ('{0}/cccc-3333' -f $script:sessions); Id = 'cccc-3333'; Name = 'dbhub-test'; Token = $script:token }
        $run = InModuleScope DbHubDemo -Parameters @{ S = $session } { Invoke-DemoLivyStatement -Session $S -Code 'x' }
        $run.Status | Should -Be 'Error'
        $run.ErrorName | Should -Be 'AnalysisException'
        $run.ErrorValue | Should -Match 'TABLE_OR_VIEW_NOT_FOUND'
    }

    It 'cancels a statement that outlives its time' {
        Set-LivyRoute @(
            @{ Method = 'Post'; Match = '/statements$'; Responses = @(New-LivyResponse 200 @{ id = 3; state = 'running' }) }
            @{ Method = 'Get'; Match = '/statements/3$'; Responses = @(New-LivyResponse 200 @{ id = 3; state = 'running' }) }
            @{ Method = 'Post'; Match = '/statements/3/cancel$'; Responses = @(New-LivyResponse 200 @{ msg = 'canceled' }) }
        )
        $session = [pscustomobject]@{ Uri = ('{0}/cccc-3333' -f $script:sessions); Id = 'cccc-3333'; Name = 'dbhub-test'; Token = $script:token }
        $run = InModuleScope DbHubDemo -Parameters @{ S = $session } { Invoke-DemoLivyStatement -Session $S -Code 'x' -TimeoutSeconds 30 -PollSeconds 10 }
        $run.Status | Should -Be 'TimedOut'
        $run.ErrorValue | Should -Match 'still running after 1 minutes, so it was cancelled'
        @($requests | Where-Object { $_.Uri -like '*/statements/3/cancel' }).Count | Should -Be 1
    }

    It 'counts a session that''s already gone as deleted, and never throws when the delete fails' {
        $session = [pscustomobject]@{ Uri = ('{0}/dddd-4444' -f $script:sessions); Id = 'dddd-4444'; Name = 'dbhub-test'; Token = $script:token }
        Set-LivyRoute @(@{ Method = 'Delete'; Match = '/sessions/dddd-4444$'; Responses = @(New-LivyResponse 404 @{ errorCode = 'NotFound'; message = 'Gone.' }) })
        (InModuleScope DbHubDemo -Parameters @{ S = $session } { Close-DemoLivySession -Session $S }).Deleted | Should -BeTrue
        Set-LivyRoute @(@{ Method = 'Delete'; Match = '/sessions/dddd-4444$'; Responses = @(New-LivyResponse 400 @{ errorCode = 'BadRequest'; message = 'No.' }) })
        $closed = InModuleScope DbHubDemo -Parameters @{ S = $session } { Close-DemoLivySession -Session $S }
        $closed.Deleted | Should -BeFalse
        $closed.Error | Should -Match 'HTTP 400 BadRequest'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -MockWith { throw [System.InvalidOperationException]::new('the connection was reset') }
        { InModuleScope DbHubDemo -Parameters @{ S = $session } { Close-DemoLivySession -Session $S } } | Should -Not -Throw
    }

    It 'reads the JSON object a statement''s output ends with, and nothing else' {
        InModuleScope DbHubDemo {
            (ConvertFrom-DemoLivyJsonLine -Text "log line`n{`"form`": `"Kept`"}`n`n").form | Should -Be 'Kept'
            ConvertFrom-DemoLivyJsonLine -Text "{`"form`": `"Kept`"}`nlast line" | Should -BeNullOrEmpty
            ConvertFrom-DemoLivyJsonLine -Text '[1, 2]' | Should -BeNullOrEmpty
            ConvertFrom-DemoLivyJsonLine -Text '' | Should -BeNullOrEmpty
        }
    }

    It 'deletes the session it created when the wait for it throws, and lets the error through (the review of c96f790a)' {
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $requests.Add([pscustomobject]@{ Method = [string]$Method; Uri = [string]$Uri })
            if ($Method -eq 'Post') { return (New-LivyResponse 202 @{ id = 'kkkk-1111' }) }
            if ($Method -eq 'Get') { throw [System.Net.Http.HttpRequestException]::new('The connection was reset.') }
            return (New-LivyResponse 200 $null)
        }
        { InModuleScope DbHubDemo -Parameters @{ W = $script:workspaceId; L = $script:lakehouseId; T = $script:token } { Open-DemoLivySession -WorkspaceId $W -LakehouseId $L -Token $T } } | Should -Throw '*connection was reset*'
        @($requests | Where-Object Method -EQ 'Get').Count | Should -BeGreaterThan 1 -Because 'a read is retried before its error goes through'
        @($requests | Where-Object Method -EQ 'Delete').Count | Should -Be 1
        $requests[-1].Method | Should -Be 'Delete'
        $requests[-1].Uri | Should -Be ('{0}/kkkk-1111' -f $script:sessions)
    }
}

Describe 'Get-DemoKeptValueCode (the review of c96f790a)' {
    It 'reads a kept_value.py as it is only when it defines kept_value_step' {
        $with = Join-Path -Path $TestDrive -ChildPath 'with.py'
        $without = Join-Path -Path $TestDrive -ChildPath 'without.py'
        $text = "import json`r`n`r`ndef kept_value_step(spark, table=`"telemetry_snapshots`"):`n    return {}`n"
        [System.IO.File]::WriteAllText($with, $text)
        [System.IO.File]::WriteAllText($without, "def kept_values(rows):`n    return []`n")
        InModuleScope DbHubDemo -Parameters @{ With = $with; Without = $without; Missing = (Join-Path -Path $TestDrive -ChildPath 'missing.py'); Text = $text } {
            Get-DemoKeptValueCode -Path $With | Should -BeExactly $Text
            Get-DemoKeptValueCode -Path $Without | Should -BeExactly '' -Because 'the groundwork''s module has no kept_value_step: every step would fail on a NameError'
            Get-DemoKeptValueCode -Path $Missing | Should -BeExactly ''
        }
    }
}

Describe 'Invoke-DemoHistoryKeptValue (F35, 2026-11-23)' {
    BeforeEach {
        $script:rows = [System.Collections.Generic.List[object]]::new()
        # Bound parameters only: a call without -Status leaves $Status unset, which StrictMode refuses (the review of c96f790a).
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { $rows.Add([pscustomobject]@{ Id = @($PesterBoundParameters['Id'])[0]; State = $PesterBoundParameters['State']; Status = $PesterBoundParameters['Status']; Message = $PesterBoundParameters['Message'] }) }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith { throw 'the configuration''s IDs are resolved already' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { throw 'the test passes a token' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoKeptValueCode -MockWith { $fakeModule }
    }

    It 'sends this checkout''s kept_value.py as it is, then kept_value_step, and passes once every row is worked out' {
        Set-KeptValueRoute
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -CheckId 'DEPLOY.FABRIC.KEPTVALUE' -ProgressPath 'progress.json' -ProgressId 'Fabric.KeptValues'
        $codes = @(Get-StatementCode)
        $codes.Count | Should -Be 2
        $codes[0] | Should -BeExactly $script:fakeModule
        $codes[1] | Should -BeExactly $script:stepCode
        $result.checkId | Should -Be 'DEPLOY.FABRIC.KEPTVALUE'
        $result.status | Should -Be 'Pass'
        $result.message | Should -BeExactly 'Worked out the history''s kept values: 29,840 rows this time; it added grain_minutes, kept_value, resolved_at_utc to telemetry_snapshots, none left.'
        $result.evidence.nonBlocking | Should -Be 'keptValue'
        $result.evidence.outcome | Should -Be 'Done'
        $result.evidence.form | Should -Be 'Kept'
        $result.evidence.step.read | Should -Be 31162
        $result.evidence.session.deleted | Should -BeTrue
        @($requests | Where-Object Method -EQ 'Delete').Count | Should -Be 1
        InModuleScope DbHubDemo -Parameters @{ R = $result } { Get-DemoKeptValueForm -Result $R } | Should -Be 'Kept'
        @($rows | ForEach-Object { '{0}:{1}' -f $_.Id, $_.State }) | Should -Be @('Fabric.KeptValues:Running', 'Fabric.KeptValues:Done')
        $rows[0].Message | Should -BeExactly 'Working out the history''s kept values through Livy: a Spark session in the lakehouse, about 1 to 3 minutes (the first time, the whole history), at most 15 minutes. It doesn''t block DONE.'
        Should -Invoke -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -Times 0 -Exactly
    }

    It 'passes when nothing was left to do' {
        Set-KeptValueRoute -Step (New-StatementAnswer 1 (New-StepLine @{ missing = @(); added = @(); read = 0; resolved = 0 }))
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token
        $result.status | Should -Be 'Pass'
        $result.message | Should -Be 'The history''s kept values were already worked out: nothing was left to do.'
        $result.checkId | Should -Be 'FABRIC.KEPTVALUE'
    }

    It 'is Not selected, and allows only the release''s form, when the lakehouse has no history table yet' {
        Set-KeptValueRoute -Step (New-StatementAnswer 1 (New-StepLine @{ exists = $false; missing = @(); added = @(); form = 'Release'; read = 0; resolved = 0 }))
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token
        $result.status | Should -Be 'Not selected'
        $result.evidence.outcome | Should -Be 'NoTable'
        InModuleScope DbHubDemo -Parameters @{ R = $result } { Get-DemoKeptValueForm -Result $R } | Should -Be ''
    }

    It 'is a Warning when the step stopped with rows left, and still allows the kept form, whose columns exist' {
        Set-KeptValueRoute -Step (New-StatementAnswer 1 (New-StepLine @{ resolved = 1200; pending = 340; attempts = 5; error = 'ConcurrentAppendException after 5 attempts' }))
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -RunAgain './scripts/deploy.ps1 -FromStage Fabric'
        $result.status | Should -Be 'Warning'
        $result.evidence.outcome | Should -Be 'Partial'
        $result.message | Should -Match '1,200 rows this time.*340 still to do \(ConcurrentAppendException after 5 attempts\)\. Until a later run works them out'
        $result.remediation | Should -Match 'to do it now, run \./scripts/deploy\.ps1 -FromStage Fabric\.$'
        InModuleScope DbHubDemo -Parameters @{ R = $result } { Get-DemoKeptValueForm -Result $R } | Should -Be 'Kept'
    }

    It 'is a Warning, with the session deleted and no step run, when kept_value.py fails to load' {
        Set-KeptValueRoute -Load (New-StatementAnswer 0 '' 'error' 'SyntaxError' 'invalid syntax (<stdin>, line 12)')
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -ProgressPath 'progress.json' -ProgressId 'Fabric.HistoryKept'
        $result.status | Should -Be 'Warning'
        $result.evidence.outcome | Should -Be 'StepFailed'
        $result.message | Should -Match 'kept_value\.py didn''t load in the Livy session \(SyntaxError: invalid syntax'
        @(Get-StatementCode).Count | Should -Be 1
        @($requests | Where-Object Method -EQ 'Delete').Count | Should -Be 1
        $rows[-1].State | Should -Be 'Action needed'
        InModuleScope DbHubDemo -Parameters @{ R = $result } { Get-DemoKeptValueForm -Result $R } | Should -Be ''
    }

    It 'is a Warning when the answer doesn''t end with the step''s JSON, or lacks its keys: <Name>' -TestCases @(
        @{ Name = 'no JSON'; Text = 'done'; Pattern = 'didn''t end with its JSON' }
        @{ Name = 'a key missing'; Text = '{"version": 1, "exists": true, "form": "Kept"}'; Pattern = 'lacked table, missing, added, scope, read, resolved, pending, attempts, seconds, error' }
    ) {
        param($Name, $Text, $Pattern)
        Set-KeptValueRoute -Step (New-StatementAnswer 1 $Text)
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token
        $result.status | Should -Be 'Warning' -Because $Name
        $result.evidence.outcome | Should -Be 'NoAnswer'
        $result.message | Should -Match $Pattern
        $result.evidence.form | Should -Be ''
    }

    It 'is a Warning, never a Fail, when Fabric refuses the session or the capacity is paused: <Outcome>' -TestCases @(
        @{ Status = 403; Body = @{ errorCode = 'Forbidden'; message = 'No access.' }; Outcome = 'Refused'; Fix = 'Contributor or higher on the demo''s workspace' }
        @{ Status = 404; Body = @{ errorCode = 'CapacityNotActive'; message = 'The capacity is not active.' }; Outcome = 'CapacityPaused'; Fix = '^Resume the capacity' }
    ) {
        param($Status, $Body, $Outcome, $Fix)
        Set-LivyRoute @(@{ Method = 'Post'; Match = 'sessions$'; Responses = @(New-LivyResponse $Status $Body) })
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token
        $result.status | Should -Be 'Warning'
        $result.evidence.outcome | Should -Be $Outcome
        $result.remediation | Should -Match $Fix
        $result.message | Should -Match 'overlapping saves can count twice'
        @(Get-StatementCode).Count | Should -Be 0
    }

    It 'cancels a step that outlives -TimeoutMinutes, deletes the session, and says the rest waits for a later run' {
        Set-LivyRoute @(
            @{ Method = 'Post'; Match = 'sessions$'; Responses = @(New-LivyResponse 202 @{ id = 'eeee-5555' }) }
            @{ Method = 'Get'; Match = '/sessions/eeee-5555$'; Responses = @(New-LivyResponse 200 @{ state = 'idle' }) }
            @{ Method = 'Post'; Match = '/sessions/eeee-5555/statements$'; Responses = @((New-StatementAnswer 0 ''), (New-LivyResponse 200 @{ id = 1; state = 'running' })) }
            @{ Method = 'Get'; Match = '/statements/1$'; Responses = @(New-LivyResponse 200 @{ id = 1; state = 'running' }) }
            @{ Method = 'Post'; Match = '/statements/1/cancel$'; Responses = @(New-LivyResponse 200 @{}) }
            @{ Method = 'Delete'; Match = '/sessions/eeee-5555$'; Responses = @(New-LivyResponse 200 $null) }
        )
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -TimeoutMinutes 1
        $result.status | Should -Be 'Warning'
        $result.evidence.outcome | Should -Be 'TimedOut'
        $result.message | Should -Match 'didn''t finish in 1 minutes, so it was stopped'
        @($requests | Where-Object { $_.Uri -like '*/statements/1/cancel' }).Count | Should -Be 1
        @($requests | Where-Object Method -EQ 'Delete').Count | Should -Be 1
    }

    It 'finds the workspace and the lakehouse by name, read-only, when the configuration has only names' {
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith {
            $copy = @{ fabric = @{ workspaceId = '13131313-1313-1313-1313-131313131313'; lakehouseId = '14141414-1414-1414-1414-141414141414' } }
            [pscustomobject]@{ Resolved = $true; Config = $copy; Results = @() }
        }
        Set-KeptValueRoute
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig -NamesOnly) -Token $script:token
        $result.status | Should -Be 'Pass'
        $requests[0].Uri | Should -Be $script:sessions
        Should -Invoke -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters['Create'] }
    }

    It 'is a Warning with no Livy request when the lakehouse list says the capacity is paused' {
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith {
            $paused = New-DemoResult -CheckId 'FABRIC.RESOLVE.LAKEHOUSE' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The capacity is paused.' -Evidence @{ capacityInactive = $true }
            [pscustomobject]@{ Resolved = $false; Config = @{}; Results = @($paused) }
        }
        Set-LivyRoute @()
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig -NamesOnly) -Token $script:token
        $result.status | Should -Be 'Warning'
        $result.evidence.outcome | Should -Be 'CapacityPaused'
        $requests.Count | Should -Be 0
    }

    It 'gets the Azure CLI''s Fabric token when none is given, and is a Warning without one' {
        Set-LivyRoute @()
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig)
        $result.status | Should -Be 'Warning'
        $result.evidence.outcome | Should -Be 'NoToken'
        $result.remediation | Should -BeExactly ("Sign in once with 'az login --tenant <tenantId>', then run {0}." -f $script:again)
        $result.message | Should -BeExactly ('No Fabric token, so the history''s kept values weren''t worked out: the test passes a token. {0}' -f $script:asBefore)
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq '11111111-2222-3333-4444-555555555555' }
    }

    It 'turns an error that lasts into a Warning, and lets a stop of the run through' {
        Set-LivyRoute @()
        Mock -ModuleName DbHubDemo -CommandName Open-DemoLivySession -MockWith { throw [System.InvalidOperationException]::new('the step broke') }
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token
        $result.status | Should -Be 'Warning'
        $result.evidence.outcome | Should -Be 'Failed'
        $result.message | Should -Match 'the step broke'
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Open-DemoLivySession -MockWith { throw [System.OperationCanceledException]::new('the run was stopped') }
        { Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token } | Should -Throw -ExceptionType ([System.OperationCanceledException])
    }

    It 'is Not selected, with no request, when this checkout''s kept_value.py has no kept_value_step yet (the review of c96f790a)' {
        # The groundwork's module defines no kept_value_step: before the notebook's work merges, every step would fail on a
        # NameError.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoKeptValueCode -MockWith { '' }
        Set-LivyRoute @()
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -CheckId 'DEPLOY.FABRIC.KEPTVALUE' -DecidesModelForm
        $result.status | Should -Be 'Not selected'
        $result.evidence.outcome | Should -Be 'NoModule'
        $result.message | Should -BeExactly 'This checkout''s fabric/history/kept_value.py has no kept_value_step, or isn''t there, so the history''s kept values weren''t worked out.'
        $requests.Count | Should -Be 0
        InModuleScope DbHubDemo -Parameters @{ R = $result } { Get-DemoKeptValueForm -Result $R } | Should -Be ''
    }

    It 'says a session that didn''t start, with its exact fix line' {
        Set-LivyRoute @(
            @{ Method = 'Post'; Match = 'sessions$'; Responses = @(New-LivyResponse 202 @{ id = 'hhhh-8888' }) }
            @{ Method = 'Get'; Match = '/sessions/hhhh-8888$'; Responses = @(New-LivyResponse 200 @{ state = 'dead'; errorInfo = @(@{ errorCode = 'SparkSessionFailed'; message = 'The session failed to start.' }) }) }
            @{ Method = 'Delete'; Match = '/sessions/hhhh-8888$'; Responses = @(New-LivyResponse 200 $null) }
        )
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token
        $result.evidence.outcome | Should -Be 'SessionFailed'
        $result.message | Should -BeExactly ('The Livy session that works out the history''s kept values didn''t start: the session is dead: SparkSessionFailed The session failed to start. {0}' -f $script:asBefore)
        $result.remediation | Should -BeExactly ('Run {0} in a few minutes: a busy capacity queues a Spark session.' -f $script:again)
        @($requests | Where-Object Method -EQ 'Delete').Count | Should -Be 1
    }

    It 'says a table still without the columns, with its exact fix line' {
        Set-KeptValueRoute -Step (New-StatementAnswer 1 (New-StepLine @{ form = 'Release'; added = @(); missing = @('kept_value', 'resolved_at_utc'); resolved = 0; error = 'MetadataChangedException' }))
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token
        $result.evidence.outcome | Should -Be 'NoColumns'
        $result.message | Should -BeExactly ('telemetry_snapshots still lacks kept_value, resolved_at_utc (MetadataChangedException), so the history''s kept values weren''t worked out. {0}' -f $script:asBefore)
        $result.remediation | Should -BeExactly (Get-TestLater $script:again)
    }

    It 'says kept_value_step raising, with its exact fix line' {
        Set-KeptValueRoute -Step (New-StatementAnswer 1 '' 'error' 'Py4JJavaError' 'An error occurred while calling o123.sql.')
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token
        $result.evidence.outcome | Should -Be 'StepFailed'
        $result.message | Should -BeExactly ('kept_value_step failed in the Livy session (Py4JJavaError: An error occurred while calling o123.sql.), so the history''s kept values weren''t worked out. {0}' -f $script:asBefore)
        $result.remediation | Should -BeExactly ('Run {0}; if it fails the same way, it''s a bug: open an issue with this record.' -f $script:again)
    }

    It 'says Fabric''s HTTP answer to a statement by its status, never as a bug: <Name> (the review of c96f790a)' -TestCases @(
        @{ Name = 'HTTP 503 past the retries'; Status = 503; Body = @{ errorCode = 'ServiceUnavailable'; message = 'Try again later.' }; Outcome = 'Failed' }
        @{ Name = 'HTTP 429 past the retries'; Status = 429; Body = @{ errorCode = 'TooManyRequests'; message = 'Slow down.' }; Outcome = 'Failed' }
        @{ Name = 'HTTP 401'; Status = 401; Body = @{ errorCode = 'TokenExpired'; message = 'The token is expired.' }; Outcome = 'Refused' }
        @{ Name = 'a paused capacity'; Status = 404; Body = @{ errorCode = 'CapacityNotActive'; message = 'The capacity is not active.' }; Outcome = 'CapacityPaused' }
    ) {
        param($Name, $Status, $Body, $Outcome)
        Set-LivyRoute @(
            @{ Method = 'Post'; Match = 'sessions$'; Responses = @(New-LivyResponse 202 @{ id = 'iiii-9999' }) }
            @{ Method = 'Get'; Match = '/sessions/iiii-9999$'; Responses = @(New-LivyResponse 200 @{ state = 'idle' }) }
            @{ Method = 'Post'; Match = '/sessions/iiii-9999/statements$'; Responses = @((New-StatementAnswer 0 ''), (New-LivyResponse 200 @{ id = 1; state = 'running' })) }
            @{ Method = 'Get'; Match = '/statements/1$'; Responses = @(New-LivyResponse $Status $Body) }
            @{ Method = 'Delete'; Match = '/sessions/iiii-9999$'; Responses = @(New-LivyResponse 200 $null) }
        )
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token
        $result.evidence.outcome | Should -Be $Outcome -Because $Name
        $result.remediation | Should -Not -Match 'it''s a bug'
        $text = 'HTTP {0} {1} {2}' -f $Status, $Body.errorCode, $Body.message
        if ($Outcome -eq 'Failed') {
            $result.message | Should -BeExactly ('Fabric''s Livy API didn''t run a statement in the session that works out the history''s kept values ({0}). {1}' -f $text, $script:asBefore)
            $result.remediation | Should -BeExactly (Get-TestLater $script:again)
        }
        elseif ($Outcome -eq 'Refused') {
            $result.message | Should -BeExactly ('Fabric refused a statement in the Livy session that works out the history''s kept values ({0}). {1}' -f $text, $script:asBefore)
            $result.remediation | Should -BeExactly ('Check that your account has Contributor or higher on the demo''s workspace, and that a Fabric administrator allows the Livy API in the tenant settings; then run {0}.' -f $script:again)
        }
        else {
            $result.remediation | Should -Match ('^Resume the capacity.*Then run {0}\.$' -f [regex]::Escape($script:again))
        }
        @($requests | Where-Object Method -EQ 'Delete').Count | Should -Be 1
    }

    It 'gives a network error that lasts the network note before its fix' {
        Set-LivyRoute @()
        Mock -ModuleName DbHubDemo -CommandName Open-DemoLivySession -MockWith { throw [System.Net.Http.HttpRequestException]::new('A network error reached api.fabric.microsoft.com on each of 4 attempts: The SSL connection could not be established.') }
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token
        $result.evidence.outcome | Should -Be 'Failed'
        $result.evidence.networkError | Should -BeTrue
        $result.remediation | Should -BeExactly ('A network error stopped it (requests that are safe to repeat were retried). {0}' -f (Get-TestLater $script:again))
    }

    It 'says the Fabric track''s model reads the release''s form when its step doesn''t allow the kept one, and only then (-DecidesModelForm, the review of c96f790a)' {
        # No session: no answer, so no kept form, and the model the track deploys next reads the release's.
        Set-LivyRoute @(@{ Method = 'Post'; Match = 'sessions$'; Responses = @(New-LivyResponse 430 @{ errorCode = 'TooManyRequestsForCapacity'; message = 'All the available capacity is in use.' }) })
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -CheckId 'DEPLOY.FABRIC.KEPTVALUE' -RunAgain $script:trackAgain -DecidesModelForm
        $result.evidence.outcome | Should -Be 'SessionFailed'
        $result.message | Should -BeExactly ('The Livy session that works out the history''s kept values didn''t start: HTTP 430 TooManyRequestsForCapacity All the available capacity is in use. {0}' -f $script:modelBefore)
        $result.remediation | Should -BeExactly ('Run {0} in a few minutes: a busy capacity queues a Spark session.' -f $script:trackAgain)

        # The columns still missing: the release's form, so the Fabric track again.
        Set-KeptValueRoute -Step (New-StatementAnswer 1 (New-StepLine @{ form = 'Release'; added = @(); missing = @('kept_value'); resolved = 0 }))
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -CheckId 'DEPLOY.FABRIC.KEPTVALUE' -RunAgain $script:trackAgain -DecidesModelForm
        $result.evidence.outcome | Should -Be 'NoColumns'
        $result.message | Should -BeExactly ('telemetry_snapshots still lacks kept_value, so the history''s kept values weren''t worked out. {0}' -f $script:modelBefore)
        $result.remediation | Should -BeExactly (Get-TestModelLater $script:trackAgain)

        # Rows left, but the columns are there: the kept form, and a later run works out the rest.
        Set-KeptValueRoute -Step (New-StatementAnswer 1 (New-StepLine @{ resolved = 1200; pending = 340 }))
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -CheckId 'DEPLOY.FABRIC.KEPTVALUE' -RunAgain $script:trackAgain -DecidesModelForm
        $result.evidence.outcome | Should -Be 'Partial'
        $result.message | Should -Match ([regex]::Escape($script:asBefore) + '$')
        $result.remediation | Should -BeExactly (Get-TestLater $script:trackAgain)
    }

    It 'is a Warning when every row is worked out while this run''s history model reads the release''s form (-ModelOnRelease, the review of c96f790a)' {
        Set-KeptValueRoute -Step (New-StatementAnswer 1 (New-StepLine @{ missing = @(); added = @(); resolved = 120 }))
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -CheckId 'DEPLOY.FABRIC.KEPTVALUE.END' -RunAgain $script:trackAgain -ModelOnRelease -ProgressPath 'progress.json' -ProgressId 'Fabric.HistoryKept'
        $result.status | Should -Be 'Warning'
        $result.evidence.outcome | Should -Be 'ModelOnRelease'
        $result.message | Should -BeExactly ('The history''s kept values are worked out, 120 rows this time, with none left, but the history model doesn''t read them yet. {0}' -f $script:modelBefore)
        $result.remediation | Should -BeExactly (Get-TestModelLater $script:trackAgain)
        $rows[-1].State | Should -Be 'Action needed'
    }

    It 'keeps the whole step, the session''s start and kept_value.py''s load included, within -TimeoutMinutes (the review of c96f790a)' {
        # The module's clock moves only with the polls' sleeps: the session is idle after 4 minutes, the load takes 6 more
        # (more than the 300 seconds it once had of its own), and the step never finishes.
        $script:clock = [pscustomobject]@{ Start = [datetime]::new(2026, 11, 23, 12, 0, 0, [System.DateTimeKind]::Utc); Now = [datetime]::new(2026, 11, 23, 12, 0, 0, [System.DateTimeKind]::Utc) }
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $clock.Now }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $clock.Now = $clock.Now.AddSeconds([int]$PesterBoundParameters['Seconds']) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $uri = [string]$Uri
            $requests.Add([pscustomobject]@{ Method = [string]$Method; Uri = $uri; At = $clock.Now })
            $minutes = ($clock.Now - $clock.Start).TotalMinutes
            if ($Method -eq 'Post' -and $uri -match 'sessions$') { return (New-LivyResponse 202 @{ id = 'jjjj-0000' }) }
            if ($Method -eq 'Get' -and $uri -match '/sessions/jjjj-0000$') { return (New-LivyResponse 200 @{ state = $(if ($minutes -lt 4) { 'starting' } else { 'idle' }) }) }
            if ($Method -eq 'Post' -and $uri -match '/statements$') { $n = @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -match '/statements$' }).Count; return (New-LivyResponse 200 @{ id = $n - 1; state = 'running' }) }
            if ($Method -eq 'Get' -and $uri -match '/statements/0$') { if ($minutes -lt 10) { return (New-LivyResponse 200 @{ id = 0; state = 'running' }) }; return (New-StatementAnswer 0 '') }
            if ($Method -eq 'Get' -and $uri -match '/statements/1$') { return (New-LivyResponse 200 @{ id = 1; state = 'running' }) }
            if ($Method -eq 'Post' -and $uri -match '/statements/1/cancel$') { return (New-LivyResponse 200 @{}) }
            if ($Method -eq 'Delete') { return (New-LivyResponse 200 $null) }
            throw ('unexpected request {0} {1}' -f $Method, $uri)
        }
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -CheckId 'STOP.FABRIC.KEPTVALUE' -TimeoutMinutes 15 -SessionTimeoutMinutes 5
        $result.evidence.outcome | Should -Be 'TimedOut'
        $result.evidence.session.secondsToReady | Should -Be 240
        $result.evidence.load.status | Should -Be 'Ok' -Because 'the load has no limit of its own, only what the one deadline leaves'
        $result.evidence.seconds | Should -Be 900
        $cancel = @($requests | Where-Object { $_.Uri -like '*/statements/1/cancel' })
        $cancel.Count | Should -Be 1
        ($cancel[0].At - $clock.Start).TotalSeconds | Should -Be 900 -Because 'the step had what the session and the load left of the 15 minutes'
        @($requests | Where-Object Method -EQ 'Delete').Count | Should -Be 1
    }

    It 'waits for the session no longer than -TimeoutMinutes, whatever -SessionTimeoutMinutes says (the review of c96f790a)' {
        $script:clock = [pscustomobject]@{ Start = [datetime]::new(2026, 11, 23, 12, 0, 0, [System.DateTimeKind]::Utc); Now = [datetime]::new(2026, 11, 23, 12, 0, 0, [System.DateTimeKind]::Utc) }
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $clock.Now }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $clock.Now = $clock.Now.AddSeconds([int]$PesterBoundParameters['Seconds']) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $uri = [string]$Uri
            $requests.Add([pscustomobject]@{ Method = [string]$Method; Uri = $uri; At = $clock.Now })
            if ($Method -eq 'Post' -and $uri -match 'sessions$') { return (New-LivyResponse 202 @{ id = 'llll-2222' }) }
            if ($Method -eq 'Get' -and $uri -match '/sessions/llll-2222$') { return (New-LivyResponse 200 @{ state = 'starting' }) }
            if ($Method -eq 'Delete') { return (New-LivyResponse 200 $null) }
            throw ('unexpected request {0} {1}' -f $Method, $uri)
        }
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -TimeoutMinutes 3 -SessionTimeoutMinutes 10
        $result.evidence.outcome | Should -Be 'SessionFailed'
        $result.message | Should -Match '^The Livy session that works out the history''s kept values didn''t start: the session was still starting after 3 minutes\. '
        $result.evidence.seconds | Should -Be 180
        $requests[-1].Method | Should -Be 'Delete'
        ($requests[-1].At - $clock.Start).TotalSeconds | Should -Be 180
    }
}

Describe 'deploy.ps1''s kept-value steps (F35, 2026-11-23)' {
    It 'works out the history snapshot''s kept values at the run''s end only when it saved: <Outcome>' -TestCases @(
        @{ Outcome = 'Saved'; Runs = $true }
        @{ Outcome = 'SavedNotRefreshed'; Runs = $true }
        @{ Outcome = 'CapacityPaused'; Runs = $false }
        @{ Outcome = 'NotSelected'; Runs = $false }
    ) {
        param($Outcome, $Runs)
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHistoryKeptValue -MockWith { New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Worked out.' }
        $snapshot = New-DemoResult -CheckId 'DEPLOY.FABRIC.HISTORY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Saved.' -Evidence @{ nonBlocking = 'historySnapshot'; outcome = $Outcome }
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); R = @($snapshot) } { Invoke-DemoKeptValueEndStep -Config $C -Result $R -ProgressPath 'progress.json' }
        $result.checkId | Should -Be 'DEPLOY.FABRIC.KEPTVALUE.END'
        if ($Runs) {
            $result.status | Should -Be 'Pass'
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoHistoryKeptValue -Times 1 -Exactly -ParameterFilter { $CheckId -eq 'DEPLOY.FABRIC.KEPTVALUE.END' -and $ProgressId -eq 'Fabric.HistoryKept' -and $ProgressPath -eq 'progress.json' }
        }
        else {
            $result.status | Should -Be 'Not selected'
            $result.message | Should -Match 'saved nothing in this run'
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoHistoryKeptValue -Times 0 -Exactly
            Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -Times 1 -Exactly -ParameterFilter { @($Id)[0] -eq 'Fabric.HistoryKept' -and $State -eq 'Skipped' }
        }
    }

    It 'runs nothing at the end with -WhatIfRun or -SkipFabric' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHistoryKeptValue -MockWith { throw 'not expected' }
        $whatIf = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { Invoke-DemoKeptValueEndStep -Config $C -WhatIfRun }
        $whatIf.status | Should -Be 'Not selected'
        $whatIf.message | Should -Match '^What if: nothing ran'
        (InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { Invoke-DemoKeptValueEndStep -Config $C -SkipFabric }).message | Should -Match '-SkipFabric'
    }

    It 'tells the end''s step whether this run''s history model reads the release''s form, from the Fabric track''s step: <Name> (the review of c96f790a)' -TestCases @(
        @{ Name = 'the kept form'; Form = 'Kept'; Track = $true; Release = $false }
        @{ Name = 'the release''s form'; Form = 'Release'; Track = $true; Release = $true }
        @{ Name = 'no answer'; Form = ''; Track = $true; Release = $true }
        @{ Name = 'no Fabric track in this run'; Form = ''; Track = $false; Release = $false }
    ) {
        param($Name, $Form, $Track, $Release)
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHistoryKeptValue -MockWith { New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Worked out.' }
        $records = @(New-DemoResult -CheckId 'DEPLOY.FABRIC.HISTORY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Saved.' -Evidence @{ nonBlocking = 'historySnapshot'; outcome = 'Saved' })
        if ($Track) {
            $records = @(New-DemoResult -CheckId 'DEPLOY.FABRIC.KEPTVALUE' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'The track''s step.' -Evidence @{ nonBlocking = 'keptValue'; form = $Form }) + $records
        }
        $null = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); R = $records } { Invoke-DemoKeptValueEndStep -Config $C -Result $R }
        $expected = if ($Release) { './scripts/deploy.ps1 -FromStage Fabric' } else { './scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoHistoryKeptValue -Times 1 -Exactly -ParameterFilter { [bool]$ModelOnRelease -eq $Release -and $RunAgain -eq $expected } -Because $Name
    }

    It 'gives the history model the kept form only when the step allowed it and configure-powerbi.ps1 takes it' -TestCases @(
        @{ Form = 'Kept'; Declared = $true; Expected = 'Kept' }
        @{ Form = 'Kept'; Declared = $false; Expected = '' }
        @{ Form = ''; Declared = $true; Expected = '' }
    ) {
        param($Form, $Declared, $Expected)
        $script:declared = $Declared
        $script:sent = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { [string]$Name -like '*configure-powerbi.ps1' } -MockWith {
            $parameters = @{ ConfigPath = $null; OutputPath = $null }
            if ($declared) { $parameters['SnapshotValueForm'] = $null }
            [pscustomobject]@{ Parameters = $parameters }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricScriptStep -MockWith { $sent.Add($Argument); @() }
        $null = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); F = $Form } { Invoke-DemoPowerBIStage -Config $C -SnapshotValueForm $F }
        [string]$sent[0]['SnapshotValueForm'] | Should -Be $Expected
        $null = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { Invoke-DemoPowerBIStage -Config $C -SnapshotValueForm 'Kept' -CheckModelData }
        $sent[1].Contains('SnapshotValueForm') | Should -BeFalse -Because 'the data check deploys nothing'
    }

    It 'lists the kept values under what didn''t work, without blocking DONE, until a later step settles them, and a Pass at the end only when the track''s step allowed the kept form' {
        $warning = New-DemoResult -CheckId 'DEPLOY.FABRIC.KEPTVALUE' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'Fabric refused the Livy session.' -Remediation 'Check your role; then run ./scripts/deploy.ps1 -FromStage Fabric.' -Evidence @{ nonBlocking = 'keptValue' }
        $partial = New-DemoResult -CheckId 'DEPLOY.FABRIC.KEPTVALUE' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'Only partly worked out.' -Remediation 'Nothing to do now.' -Evidence @{ nonBlocking = 'keptValue'; form = 'Kept' }
        $settled = New-DemoResult -CheckId 'DEPLOY.FABRIC.KEPTVALUE.END' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Worked out.'
        $skipped = New-DemoResult -CheckId 'DEPLOY.FABRIC.KEPTVALUE.END' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'Saved nothing.'
        InModuleScope DbHubDemo -Parameters @{ W = $warning; K = $partial; P = $settled; S = $skipped } {
            $items = @(Get-DemoNonBlockingItem -Result @($W, $S))
            $items.Count | Should -Be 1
            $items[0].name | Should -Be 'the history''s kept values (F35)'
            $items[0].state | Should -Be 'Action needed'
            $items[0].howTo | Should -Be 'Check your role; then run ./scripts/deploy.ps1 -FromStage Fabric.'
            # The track's step allowed the kept form, so the model reads them: the end's Pass settles it.
            @(Get-DemoNonBlockingItem -Result @($K, $P)).Count | Should -Be 0
            # It didn't, so this run's model reads the release's form: the track's fix stays (the review of c96f790a).
            $open = @(Get-DemoNonBlockingItem -Result @($W, $P))
            $open.Count | Should -Be 1
            $open[0].howTo | Should -Be 'Check your role; then run ./scripts/deploy.ps1 -FromStage Fabric.'
            Test-DemoNonBlockingResult -Result $W | Should -BeTrue
            Test-DemoNonBlockingResult -Result $P | Should -BeTrue
        }
    }
}

Describe 'The status page''s kept-value rows (F35, 2026-11-23)' {
    It 'shows the Fabric track''s step between the workspace''s items and the history report, and the end''s after the snapshot, both non-blocking' {
        InModuleScope DbHubDemo {
            $catalog = @(Get-DemoProgressCatalog -T4Enabled -T5Enabled)
            $fabric = @(@($catalog | Where-Object { $_['name'] -eq 'Fabric' })[0]['steps'])
            @($fabric | ForEach-Object { $_['id'] })[0..2] | Should -Be @('Fabric.Items', 'Fabric.KeptValues', 'Fabric.Report')
            @($fabric | Where-Object { $_['id'] -eq 'Fabric.KeptValues' })[0]['nonBlocking'] | Should -BeTrue
            $validation = @(@(@($catalog | Where-Object { $_['name'] -eq 'Validation' })[0]['steps']) | ForEach-Object { $_['id'] })
            $validation[[array]::IndexOf($validation, 'Fabric.History') + 1] | Should -Be 'Fabric.HistoryKept'
            @(Get-DemoProgressStepId -Track 'Fabric' -Step 'Fabric') | Should -Contain 'Fabric.KeptValues'
            @(@(Get-DemoProgressCatalog -SkipFabric) | ForEach-Object { @($_['steps']) } | ForEach-Object { $_['id'] }) | Should -Not -Contain 'Fabric.HistoryKept'
        }
    }
}
