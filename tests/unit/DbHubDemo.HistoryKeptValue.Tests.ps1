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
}

Describe 'Invoke-DemoHistoryKeptValue (F35, 2026-11-23)' {
    BeforeEach {
        $script:rows = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { $rows.Add([pscustomobject]@{ Id = @($Id)[0]; State = $State; Status = $Status; Message = $Message }) }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith { throw 'the configuration''s IDs are resolved already' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { throw 'the test passes a token' }
    }

    It 'sends this checkout''s kept_value.py as it is, then kept_value_step, and passes once every row is worked out' {
        Set-KeptValueRoute
        $result = Invoke-DemoHistoryKeptValue -Config (New-TestConfig) -Token $script:token -CheckId 'DEPLOY.FABRIC.KEPTVALUE' -ProgressPath 'progress.json' -ProgressId 'Fabric.KeptValues'
        $codes = @(Get-StatementCode)
        $codes.Count | Should -Be 2
        $codes[0] | Should -BeExactly ([System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath 'fabric/history/kept_value.py'), [System.Text.Encoding]::UTF8))
        $codes[1] | Should -BeExactly $script:stepCode
        $result.checkId | Should -Be 'DEPLOY.FABRIC.KEPTVALUE'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'Worked out the history''s kept values: 29,840 rows this time; it added grain_minutes, kept_value, resolved_at_utc to telemetry_snapshots, none left'
        $result.evidence.nonBlocking | Should -Be 'keptValue'
        $result.evidence.outcome | Should -Be 'Done'
        $result.evidence.form | Should -Be 'Kept'
        $result.evidence.step.read | Should -Be 31162
        $result.evidence.session.deleted | Should -BeTrue
        @($requests | Where-Object Method -EQ 'Delete').Count | Should -Be 1
        InModuleScope DbHubDemo -Parameters @{ R = $result } { Get-DemoKeptValueForm -Result $R } | Should -Be 'Kept'
        @($rows | ForEach-Object { '{0}:{1}' -f $_.Id, $_.State }) | Should -Be @('Fabric.KeptValues:Running', 'Fabric.KeptValues:Done')
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
        Should -Invoke -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -Times 1 -Exactly -ParameterFilter { -not $Create }
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

    It 'lists the kept values under what didn''t work, without blocking DONE, until a later step settles them' {
        $warning = New-DemoResult -CheckId 'DEPLOY.FABRIC.KEPTVALUE' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'Fabric refused the Livy session.' -Remediation 'Check your role.' -Evidence @{ nonBlocking = 'keptValue' }
        $settled = New-DemoResult -CheckId 'DEPLOY.FABRIC.KEPTVALUE.END' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Worked out.'
        $skipped = New-DemoResult -CheckId 'DEPLOY.FABRIC.KEPTVALUE.END' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'Saved nothing.'
        InModuleScope DbHubDemo -Parameters @{ W = $warning; P = $settled; S = $skipped } {
            $items = @(Get-DemoNonBlockingItem -Result @($W, $S))
            $items.Count | Should -Be 1
            $items[0].name | Should -Be 'the history''s kept values (F35)'
            $items[0].state | Should -Be 'Action needed'
            $items[0].howTo | Should -Be 'Check your role.'
            @(Get-DemoNonBlockingItem -Result @($W, $P)).Count | Should -Be 0
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
