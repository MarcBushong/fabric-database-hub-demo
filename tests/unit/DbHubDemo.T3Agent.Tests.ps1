BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # Obviously fake IDs: every group repeats one character.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['location'] = 'westus3'
        $config
    }

    function New-RestAnswer {
        param([object] $Json = $null, [int] $ExitCode = 0, [string] $StdErr = '', [int] $StatusCode = 200)
        $text = if ($null -eq $Json) { '' } else { ConvertTo-Json -InputObject $Json -Depth 10 -Compress }
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $text; StdErr = $StdErr; StatusCode = $StatusCode; Retried = $false; Challenge = ''; Authenticate = ''; NetworkError = $false }
    }

    function New-Tuning {
        param([string] $Desired, [string] $Actual, [string] $Reason = 'AutoConfigured')
        @{ properties = @{ desiredState = 'Inherit'; actualState = 'Auto'; options = @{ forceLastGoodPlan = @{ desiredState = $Desired; actualState = $Actual; reasonCode = 2; reasonDesc = $Reason } } } }
    }

    $script:online = [pscustomobject]@{ Exists = $true; Status = 'Online'; ServerName = 'azuresql01-abc123'; DeploymentId = 'abc123' }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'T3''s FORCE_LAST_GOOD_PLAN in status.ps1 and stop-demo.ps1 (Invoke-DemoT3AutoTuningCheck, 2026-11-18)' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:tuning = New-Tuning -Desired 'Default' -Actual 'On'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $(if ($PesterBoundParameters.ContainsKey('Body')) { $PesterBoundParameters['Body'] } else { $null }) })
            if ($script:tuning -is [pscustomobject]) {
                return $script:tuning
            }
            return (New-RestAnswer -Json $script:tuning)
        }
        $script:released = [pscustomobject]@{ Ran = $true; Released = $true; RestoredState = 'DEFAULT'; Error = '' }
        $script:noHold = [pscustomobject]@{ Ran = $true; Released = $false; RestoredState = ''; Error = '' }
        $script:notRun = [pscustomobject]@{ Ran = $false; Released = $false; RestoredState = ''; Error = 'T1 (sqlvm01) isn''t running' }
    }

    It 'reads it with Database Automatic Tuning - Get on T3''s database, and passes when it''s on' {
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $script:online } { Invoke-DemoT3AutoTuningCheck -Config $C -T3 $T -CheckId 'STATUS.T3.AUTOTUNING' }
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'FORCE_LAST_GOOD_PLAN is on \(desired Default\)'
        $script:calls.Count | Should -Be 1
        $script:calls[0].Method | Should -Be 'GET'
        $script:calls[0].Uri | Should -BeExactly 'https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Sql/servers/azuresql01-abc123/databases/ContosoCare/automaticTuning/current?api-version=2025-01-01'
    }

    It 'doesn''t read a T3 that isn''t Online, because reading it could wake it, and returns nothing without T3' {
        $paused = [pscustomobject]@{ Exists = $true; Status = 'Paused'; ServerName = 'azuresql01-abc123' }
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $paused } { Invoke-DemoT3AutoTuningCheck -Config $C -T3 $T -CheckId 'STOP.T3.AUTOTUNING' }
        $result.status | Should -Be 'Not selected'
        $result.message | Should -Match '^T3 is Paused, so FORCE_LAST_GOOD_PLAN wasn''t read: reading it could wake T3\. If a session''s Database Agent beat held it, the next run on T3 puts it back'
        $missing = [pscustomobject]@{ Exists = $false; Status = ''; ServerName = 'azuresql01-abc123' }
        InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $missing } { Invoke-DemoT3AutoTuningCheck -Config $C -T3 $T -CheckId 'STATUS.T3.AUTOTUNING' } | Should -BeNullOrEmpty
        $script:calls.Count | Should -Be 0
    }

    It 'warns in status.ps1 when it''s off, saying the beat holds it and what puts it back, and changes nothing' {
        $script:tuning = New-Tuning -Desired 'Off' -Actual 'Off'
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $script:online } { Invoke-DemoT3AutoTuningCheck -Config $C -T3 $T -CheckId 'STATUS.T3.AUTOTUNING' }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'A session''s Database Agent beat holds it off from the regression to its response'
        $result.remediation | Should -Match 'the next run on T3 puts it back when it starts, and so do \./scripts/reset-demo\.ps1 and \./scripts/deploy\.ps1\.'
        @($script:calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    It 'reports in stop-demo.ps1 what the release through T3 put back, and never writes through Azure Resource Manager (2026-11-18 review)' {
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $script:online; R = $script:released } { Invoke-DemoT3AutoTuningCheck -Config $C -T3 $T -CheckId 'STOP.T3.AUTOTUNING' -Release $R }
        $result.status | Should -Be 'Pass'
        $result.area | Should -Be 'infra'
        $result.message | Should -Match '^stop-demo\.ps1 put back what the Database Agent beat''s hold recorded \(DEFAULT\)\. T3''s FORCE_LAST_GOOD_PLAN is on'
        $result.evidence.release.released | Should -BeTrue
        @($script:calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    It 'leaves an off that was set outside the demo as it is, and says so (2026-11-18 review)' {
        $script:tuning = New-Tuning -Desired 'Off' -Actual 'Off'
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $script:online; R = $script:noHold } { Invoke-DemoT3AutoTuningCheck -Config $C -T3 $T -CheckId 'STOP.T3.AUTOTUNING' -Release $R }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'no Database Agent beat holds it, so it was set outside the demo, and stop-demo\.ps1 leaves it as it is'
        $result.remediation | Should -Match 'FORCE_LAST_GOOD_PLAN = DEFAULT'
        @($script:calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    It 'warns with what puts it back when the release couldn''t run, or the read fails' {
        $script:tuning = New-Tuning -Desired 'Off' -Actual 'Off'
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $script:online; R = $script:notRun } { Invoke-DemoT3AutoTuningCheck -Config $C -T3 $T -CheckId 'STOP.T3.AUTOTUNING' -Release $R }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'whether a Database Agent beat holds it couldn''t be checked \(T1 \(sqlvm01\) isn''t running\)'
        $result.remediation | Should -Match 'the next run on T3 puts it back'
        $script:tuning = New-RestAnswer -ExitCode 1 -StdErr 'ResourceNotFound' -StatusCode 404
        $unread = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $script:online } { Invoke-DemoT3AutoTuningCheck -Config $C -T3 $T -CheckId 'STATUS.T3.AUTOTUNING' }
        $unread.status | Should -Be 'Warning'
        $unread.message | Should -Match 'couldn''t be read: ResourceNotFound'
        @($script:calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    It 'warns with the reason when its desired state isn''t in effect' {
        $script:tuning = New-Tuning -Desired 'Default' -Actual 'Off' -Reason 'QueryStoreReadOnly'
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $script:online } { Invoke-DemoT3AutoTuningCheck -Config $C -T3 $T -CheckId 'STATUS.T3.AUTOTUNING' }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'desired state on T3 is Default, but it''s Off \(QueryStoreReadOnly\)'
    }
}

Describe 'stop-demo.ps1 releases the Database Agent beat''s hold through T3 itself (Invoke-DemoT3AutoTuningRelease, 2026-11-18 review)' {
    BeforeEach {
        $script:sql = [System.Collections.Generic.List[object]]::new()
        $script:answer = [pscustomobject]@{ Status = 'Pass'; Reason = 'Ok'; Message = ''; Rows = @([pscustomobject]@{ released = 1; restored_state = 'DEFAULT' }) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith {
            $script:sql.Add([pscustomobject]@{ Query = @($Query) -join "`n"; Login = $MaxLoginWaitSeconds; Resume = $MaxResumeWaitSeconds; Batch = $BatchTimeoutSeconds; Attempts = $RunCommandAttempts; DeploymentId = $DeploymentId })
            $script:answer
        }
    }

    It 'runs the release once, bounded, with @force and who did it, and returns what it put back' {
        $outcome = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $script:online } { Invoke-DemoT3AutoTuningRelease -Config $C -T3 $T -DeploymentId 'abc123' }
        $outcome.Ran | Should -BeTrue
        $outcome.Released | Should -BeTrue
        $outcome.RestoredState | Should -Be 'DEFAULT'
        $script:sql.Count | Should -Be 1
        $script:sql[0].Query | Should -Match "EXEC demo\.usp_release_auto_tuning_hold @force = 1, @by = N'stop-demo\.ps1'"
        $script:sql[0].Login | Should -Be 0
        $script:sql[0].Resume | Should -Be 0
        $script:sql[0].Batch | Should -Be 120
        $script:sql[0].Attempts | Should -Be 1
        $script:sql[0].DeploymentId | Should -Be 'abc123'
    }

    It 'says when there was no hold, and doesn''t run on a T3 that isn''t Online or when T1 can''t run it' {
        $script:answer = [pscustomobject]@{ Status = 'Pass'; Reason = 'Ok'; Message = ''; Rows = @([pscustomobject]@{ released = 0; restored_state = $null }) }
        $none = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $script:online } { Invoke-DemoT3AutoTuningRelease -Config $C -T3 $T }
        $none.Ran | Should -BeTrue
        $none.Released | Should -BeFalse

        $paused = [pscustomobject]@{ Exists = $true; Status = 'Paused'; ServerName = 'azuresql01-abc123' }
        $skipped = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $paused } { Invoke-DemoT3AutoTuningRelease -Config $C -T3 $T }
        $skipped.Ran | Should -BeFalse
        $skipped.Error | Should -Match 'T3 is Paused, and running T-SQL there would wake it'
        $script:sql.Count | Should -Be 1

        $script:answer = [pscustomobject]@{ Status = 'Fail'; Reason = 'T1NotRunning'; Message = 'T1 (sqlvm01) isn''t running (VM deallocated), so it can''t run T-SQL on T3.'; Rows = @() }
        $failed = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); T = $script:online } { Invoke-DemoT3AutoTuningRelease -Config $C -T3 $T }
        $failed.Ran | Should -BeFalse
        $failed.Error | Should -Match 'isn''t running'
    }
}

Describe 'T3''s FORCE_LAST_GOOD_PLAN in validate.ps1 and deploy.ps1 (ConvertTo-DemoT3AutoTuningResult, 2026-11-18)' {
    It 'reads <Case>' -ForEach @(
        @{ Case = 'on as T3''s default: Pass'; Row = @{ force_last_good_plan_desired = 'DEFAULT'; force_last_good_plan_actual = 'ON' }; Status = 'Pass'; Message = 'is on \(desired DEFAULT\)' }
        @{ Case = 'held off by the beat''s running run: Pass, the beat working as designed'; Row = @{ force_last_good_plan_desired = 'OFF'; force_last_good_plan_actual = 'OFF'; auto_tuning_hold_run = 'run-1'; auto_tuning_hold_status = 'Running' }; Status = 'Pass'; Message = 'held off on T3 by the Database Agent beat''s run run-1, which is running' }
        @{ Case = 'held by a run that stopped: Warning, with what puts it back'; Row = @{ force_last_good_plan_desired = 'OFF'; force_last_good_plan_actual = 'OFF'; auto_tuning_hold_run = 'run-1'; auto_tuning_hold_status = 'TimedOut' }; Status = 'Warning'; Message = 'still held off on T3 \(desired OFF\): the Database Agent beat''s run run-1 \(TimedOut\) stopped before putting it back' }
        @{ Case = 'off with no hold: Warning, turned off outside the demo'; Row = @{ force_last_good_plan_desired = 'OFF'; force_last_good_plan_actual = 'OFF' }; Status = 'Warning'; Message = 'something outside the demo turned it off' }
        @{ Case = 'on but not in effect: Warning, with Query Store''s state'; Row = @{ force_last_good_plan_desired = 'DEFAULT'; force_last_good_plan_actual = 'OFF'; query_store_state = 'READ_ONLY' }; Status = 'Warning'; Message = 'is DEFAULT but not in effect \(actual OFF; Query Store READ_ONLY\)' }
        @{ Case = 'a row without it: Warning'; Row = @{ performance_monitoring = 'true' }; Status = 'Warning'; Message = 'wasn''t in its status' }
    ) {
        $result = InModuleScope DbHubDemo -Parameters @{ R = $Row } { ConvertTo-DemoT3AutoTuningResult -Row $R }
        $result.checkId | Should -Be 'T3.AUTOTUNING'
        $result.status | Should -Be $Status
        $result.message | Should -Match $Message
        if ($Status -eq 'Warning' -and $Case -like 'held by*') {
            $result.remediation | Should -Match 'The next run on T3 puts it back when it starts'
        }
    }
}

Describe 'What Database Agents needs from T3 (Test-DemoT3AgentReadiness, 2026-11-18)' {
    BeforeEach {
        $script:permissions = @{ value = @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Delete', 'Microsoft.Authorization/*/Write') }) }
        $script:database = @{ name = 'ContosoCare'; status = 'Online'; currentSku = @{ name = 'GP_S_Gen5'; tier = 'GeneralPurpose'; capacity = 2 } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            if ($script:permissions -is [pscustomobject]) {
                return $script:permissions
            }
            return (New-RestAnswer -Json $script:permissions)
        }
    }

    It 'passes for a two-vCore serverless T3 outside any pool that the signed-in account can write, with monitoring on' {
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); D = $script:database } { Test-DemoT3AgentReadiness -Config $C -ServerName 'azuresql01-abc123' -Database $D -PerformanceMonitoring 'true' }
        $result.checkId | Should -Be 'T3.AGENT'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Be 'Database Agents can monitor T3: it''s a 2-vCore serverless database outside any pool, and your account can save it in Database agent settings, with performance monitoring on.'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Uri -eq 'https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Sql/servers/azuresql01-abc123/databases/ContosoCare/providers/Microsoft.Authorization/permissions?api-version=2022-04-01' }
    }

    It 'warns, with each fix, for a one-vCore serverless T3 in a pool, an account without write access, and monitoring off' {
        $script:database.currentSku.capacity = 1
        $script:database['elasticPoolId'] = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Sql/servers/azuresql01-abc123/elasticPools/pool1'
        # Reader, and a role whose notActions take the database write away.
        $script:permissions = @{ value = @(@{ actions = @('*/read'); notActions = @() }, @{ actions = @('Microsoft.Sql/*'); notActions = @('Microsoft.Sql/servers/databases/write') }) }
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); D = $script:database } { Test-DemoT3AgentReadiness -Config $C -ServerName 'azuresql01-abc123' -Database $D -PerformanceMonitoring 'false' }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'one-vCore serverless database, which Database Agents doesn''t support'
        $result.message | Should -Match 'in an elastic pool'
        $result.message | Should -Match 'can''t save T3 in Database agent settings, which needs Azure write access on the database \(Microsoft\.Sql/servers/databases/write\)'
        $result.message | Should -Match 'performance monitoring is off'
        $result.message | Should -Match 'The rest of the demo doesn''t need it\.$'
        $result.remediation | Should -Match 'scales T3 to the profile''s 2 vCores online'
        $result.remediation | Should -Match 'Contributor or SQL DB Contributor on T3'
    }

    It 'grants write through a matching wildcard, and warns without failing when the permissions can''t be read' {
        $script:permissions = @{ value = @(@{ actions = @('Microsoft.Sql/servers/databases/*'); notActions = @() }) }
        (InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { Test-DemoT3AgentPermission -Config $C -ServerName 'azuresql01-abc123' }).Allowed | Should -BeTrue
        $script:permissions = New-RestAnswer -ExitCode 1 -StdErr 'network error' -StatusCode 0
        $result = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig); D = $script:database } { Test-DemoT3AgentReadiness -Config $C -ServerName 'azuresql01-abc123' -Database $D }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match '^Database Agents can monitor T3: it''s a 2-vCore serverless database outside any pool\. But your write access on T3 couldn''t be read \(network error\)'
    }
}

Describe 'The one-time agent selection deploy.ps1 lists under "Please confirm" (Get-DemoT3AgentSetupItem, 2026-11-18)' {
    It 'gives Database Hub''s link in the demo''s tenant, the exact database, the Agent policy, T3''s region, and that it''s optional and once per deployment' {
        $item = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { Get-DemoT3AgentSetupItem -Config $C -ServerName 'azuresql01-abc123' -Region 'westus3' }
        $item.checkId | Should -Be 'HUB.AGENT.T3'
        $item.status | Should -Be 'Manual action required'
        $item.message | Should -Match '^Optional, for the Database Agent loop: select T3 in Database Agents, once per deployment \(it stays selected across sessions and upgrades, unless T3 is recreated\)\. Open https://app\.fabric\.microsoft\.com/workloads/fdh/databaseHub\?ctid=66666666-7777-8888-9999-000000000000, select Manage agents, then Database agent settings; turn Enabled on, select azuresql01-abc123/ContosoCare, and under Agent policy turn on Flag long-running queries, Force last known good plans, Flag high CPU; select Apply, then Save'
        $item.message | Should -Match 'T3''s region \(westus3\)'
        $item.evidence.database | Should -Be 'azuresql01-abc123/ContosoCare'
        InModuleScope DbHubDemo { Test-DemoConfirmOnlyResult -Result $args[0] } -ArgumentList $item | Should -BeTrue
        InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { Get-DemoT3AgentSetupItem -Config $C -ServerName '' } | Should -BeNullOrEmpty
    }
}
