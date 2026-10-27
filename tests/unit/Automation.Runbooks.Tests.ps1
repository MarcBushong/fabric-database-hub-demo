BeforeAll {
    # The on-demand activity control's runbooks (ADR 0020): automation/runbooks/DbHubControl.Common.ps1, dot-sourced
    # here with Azure Resource Manager mocked (Invoke-DbHubArm), and the settings the module bakes into them. IDs are
    # placeholders.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
    $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
    $config['autoShutdownTime'] = '1900'
    $config['autoShutdownTimeZone'] = 'Eastern Standard Time'
    $script:config = $config
    $script:settingsJson = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config } {
        $name = Get-DemoActivityControlName -Config $Config
        ConvertTo-Json -InputObject (Get-DemoActivityControlRunbookSetting -Config $Config -Name $name -IdentityClientId '99999999-9999-9999-9999-999999999999') -Depth 16 -Compress
    }
    . (Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1')
    $script:settings = ConvertFrom-DbHubSetting -Json $script:settingsJson
    $script:sub = '/subscriptions/11111111-2222-3333-4444-555555555555'
    $script:demo = $script:sub + '/resourceGroups/rg-dbhub-demo'
    $script:account = $script:sub + '/resourceGroups/rg-dbhub-control/providers/Microsoft.Automation/automationAccounts/aa-dbhub-control'

    function New-TestContext([datetime] $NowUtc = [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc), [string] $JobId = 'aaaaaaaa-0000-0000-0000-00000000000a') {
        $context = Initialize-DbHubContext -Settings $script:settings -JobId $JobId -NowUtc $NowUtc
        $context.Token = 'test-token-not-real'
        return $context
    }

    function New-Webhook([object] $Body) {
        $text = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 8 -Compress }
        return [pscustomobject]@{ WebhookName = 'dbhub-activity-test'; RequestBody = $text; RequestHeader = @{ 'Content-Type' = 'application/json' } }
    }

    function New-Response([int] $Status, [string] $Json = '') {
        $body = if ($Json) { $Json | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ StatusCode = $Status; Body = $body; Error = $(if ($Status -ge 400) { 'HTTP {0}' -f $Status } else { '' }) }
    }

    # A small Azure: the VMs' power states, T3, T4, the auto-stop schedule, and the control account's jobs.
    function Reset-TestAzure {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'deallocated' }
        $script:t4 = ''
        $script:t3 = 200
        $script:group = 200
        $script:jobs = @()
        $script:autostop = ''
        $script:plugin = 'Running'
        $script:runCommandStatus = 201
        $script:t4ActionStatus = 202
    }

    function Invoke-TestAzure([string] $Method, [string] $Path, [object] $Body) {
        switch -Regex ($Path) {
            '/resourceGroups/rg-dbhub-demo$' {
                if ($script:group -ne 200) { return (New-Response $script:group) }
                return (New-Response 200 '{"name":"rg-dbhub-demo","tags":{"deploymentId":"abc123"}}')
            }
            '/jobs\?' {
                return (New-Response 200 (ConvertTo-Json -InputObject @{ value = @($script:jobs) } -Depth 8))
            }
            '/schedules/dbhub-autostop$' {
                if ($Method -eq 'GET') {
                    if (-not $script:autostop) { return (New-Response 404) }
                    return (New-Response 200 (ConvertTo-Json -InputObject @{ properties = @{ startTime = $script:autostop } }))
                }
                if ($Method -eq 'PUT') { $script:autostop = [string]$Body.properties.startTime; return (New-Response 201 '{}') }
                if ($Method -eq 'DELETE') { $script:autostop = ''; return (New-Response 200) }
            }
            '/jobSchedules$' { return (New-Response 200 '{"value":[]}') }
            '/jobSchedules/' { return (New-Response 201 '{}') }
            '/virtualMachines/(\w+)/instanceView$' {
                $name = $Matches[1]
                return (New-Response 200 (ConvertTo-Json -InputObject @{ statuses = @(@{ code = 'ProvisioningState/succeeded' }, @{ code = ('PowerState/{0}' -f $script:vm[$name]) }) } -Depth 4))
            }
            '/virtualMachines/(\w+)/start$' { $script:vm[$Matches[1]] = 'running'; return (New-Response 202) }
            '/virtualMachines/(\w+)/deallocate$' { $script:vm[$Matches[1]] = 'deallocating'; return (New-Response 202) }
            '/extensions/SqlIaasExtension' {
                return (New-Response 200 (ConvertTo-Json -InputObject @{ properties = @{ instanceView = @{ statuses = @(@{ message = ('DatabaseMonitorArcPlugin: {{"State":"{0}","MetricsUploadStatus":"OK"}}' -f $script:plugin) }) } } } -Depth 6))
            }
            '/virtualMachines/(\w+)/runCommands$' { return (New-Response 200 ('{{"value":[{{"name":"DbHubControl-{0}-20261026000000"}},{{"name":"DbHubDemo-Other"}}]}}' -f $Matches[1])) }
            '/runCommands/' {
                if ($Method -eq 'PUT') { return (New-Response $script:runCommandStatus '{}') }
                return (New-Response 202)
            }
            '/servers/azuresql01-abc123/databases/ContosoCare$' { return (New-Response $script:t3 '{}') }
            '/flexibleServers/pgflex01-abc123$' {
                if (-not $script:t4) { return (New-Response 404) }
                return (New-Response 200 (ConvertTo-Json -InputObject @{ properties = @{ state = $script:t4 } }))
            }
            '/flexibleServers/pgflex01-abc123/(start|stop)$' {
                if ($script:t4ActionStatus -ne 202) { return (New-Response $script:t4ActionStatus '{"error":{"code":"UnsupportedMediaType","message":"Unsupported media type."}}') }
                $script:t4 = $(if ($Matches[1] -eq 'start') { 'Starting' } else { 'Stopping' }); return (New-Response 202)
            }
        }
        return (New-Response 404)
    }
}

Describe 'DbHub-Control request validation (Test-DbHubControlRequest)' {
    It 'accepts <Name>' -ForEach @(
        @{ Name = 'one incident'; Body = @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'blocking-chain' }); durationMinutes = 20 } }
        @{ Name = 'three targets with options'; Body = @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'deadlock-storm'; intensity = 8; concurrency = 3 }, @{ target = 'T2'; scenario = 'baseline' }, @{ target = 'T3'; scenario = 'cpu-pressure'; intensity = 1 }); durationMinutes = 120; requestedBy = 'presenter@contoso' } }
        @{ Name = 'Stop now'; Body = @{ action = 'stop' } }
        @{ Name = 'a reset of two targets'; Body = @{ action = 'reset'; targets = @('T1', 'T3') } }
        @{ Name = 'a reset of one target'; Body = @{ action = 'reset'; targets = @('T2') } }
        @{ Name = 'a reset of every target'; Body = @{ action = 'reset' } }
    ) {
        $request = Test-DbHubControlRequest -WebhookData (New-Webhook $Body) -Settings $script:settings
        $request.Reason | Should -BeNullOrEmpty
        $request.Valid | Should -BeTrue
        $request.Action | Should -Be $Body.action
    }

    It 'keeps a one-item list a list (the pipeline would unwrap it)' {
        $run = Test-DbHubControlRequest -WebhookData (New-Webhook '{"action":"run","activities":[{"target":"T2","scenario":"blocking-chain"}],"durationMinutes":20}') -Settings $script:settings
        $run.Valid | Should -BeTrue
        @($run.Activities).Count | Should -Be 1
        $run.Activities[0].Target | Should -Be 'T2'
        $run.Activities[0].Scenario | Should -Be 'blocking-chain'
        $run.Activities[0].Intensity | Should -Be 0
        $run.Activities[0].Concurrency | Should -Be 0
        $run.DurationMinutes | Should -Be 20
        $run.RequestedBy | Should -Be 'notebook'
        $reset = Test-DbHubControlRequest -WebhookData (New-Webhook '{"action":"reset","targets":["T3"]}') -Settings $script:settings
        $reset.Valid | Should -BeTrue
        @($reset.Targets) | Should -Be @('T3')
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a job started without the webhook'; Raw = $null; Match = 'only from its webhook' }
        @{ Name = 'an empty body'; Raw = ' '; Match = 'no body' }
        @{ Name = 'a body over 4 KB'; Raw = ('{"action":"stop","requestedBy":"' + ('x' * 4100) + '"}'); Match = 'larger than 4096' }
        @{ Name = 'text that isn''t JSON'; Raw = 'start everything'; Match = 'isn''t JSON' }
        @{ Name = 'a JSON array'; Raw = '[{"action":"stop"}]'; Match = 'JSON object' }
        @{ Name = 'an unknown action'; Raw = '{"action":"delete"}'; Match = 'action must be' }
        @{ Name = 'an action in another case'; Raw = '{"action":"Run","activities":[{"target":"T1","scenario":"baseline"}],"durationMinutes":10}'; Match = 'action must be' }
        @{ Name = 'an extra field'; Raw = '{"action":"stop","vm":"sqlvm01"}'; Match = 'isn''t allowed' }
        @{ Name = 'a run without a duration'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"baseline"}]}'; Match = 'durationMinutes' }
        @{ Name = 'a duration under 5 minutes'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"baseline"}],"durationMinutes":4}'; Match = 'durationMinutes' }
        @{ Name = 'a duration over 120 minutes'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"baseline"}],"durationMinutes":121}'; Match = 'durationMinutes' }
        @{ Name = 'a duration as text'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"baseline"}],"durationMinutes":"20"}'; Match = 'durationMinutes' }
        @{ Name = 'a fractional duration'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"baseline"}],"durationMinutes":20.5}'; Match = 'durationMinutes' }
        @{ Name = 'no activity'; Raw = '{"action":"run","activities":[],"durationMinutes":20}'; Match = 'activities must be' }
        @{ Name = 'an unknown target'; Raw = '{"action":"run","activities":[{"target":"T9","scenario":"baseline"}],"durationMinutes":20}'; Match = 'target must be' }
        @{ Name = 'two activities on one target'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"baseline"},{"target":"T1","scenario":"cpu-pressure"}],"durationMinutes":20}'; Match = 'more than one activity' }
        @{ Name = 'an unknown scenario'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"drop-database"}],"durationMinutes":20}'; Match = 'isn''t a scenario' }
        @{ Name = 'the baseline scenario by its catalog name'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"healthy-baseline"}],"durationMinutes":20}'; Match = 'isn''t a scenario' }
        @{ Name = 'an extra activity field'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"baseline","sql":"select 1"}],"durationMinutes":20}'; Match = 'isn''t allowed' }
        @{ Name = 'an intensity of 11'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"cpu-pressure","intensity":11}],"durationMinutes":20}'; Match = 'intensity' }
        @{ Name = 'a concurrency over the scenario''s maximum'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"blocking-chain","concurrency":5}],"durationMinutes":20}'; Match = 'concurrency' }
        @{ Name = 'a concurrency for the baseline'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"baseline","concurrency":2}],"durationMinutes":20}'; Match = 'concurrency' }
        @{ Name = 'a requestedBy with spaces'; Raw = '{"action":"stop","requestedBy":"a b"}'; Match = 'requestedBy' }
        @{ Name = 'a reset of one target twice'; Raw = '{"action":"reset","targets":["T1","T1"]}'; Match = 'distinct' }
        @{ Name = 'a reset whose targets aren''t a list'; Raw = '{"action":"reset","targets":"T1"}'; Match = 'targets must be a list' }
        @{ Name = 'activities that aren''t a list'; Raw = '{"action":"run","activities":{"target":"T1","scenario":"baseline"},"durationMinutes":20}'; Match = 'activities must be' }
    ) {
        $data = if ($null -eq $Raw) { $null } else { New-Webhook $Raw }
        $request = Test-DbHubControlRequest -WebhookData $data -Settings $script:settings
        $request.Valid | Should -BeFalse
        $request.Reason | Should -Match $Match
    }

    It 'allows the catalog''s targets and scenarios only, from scenarios/*/scenario.json' {
        # T4 is in the catalog since Phase 24's scenarios (connection-surge, idle-in-transaction) list it.
        @($script:settings.targets.PSObject.Properties.Name) | Should -Be @('T1', 'T2', 'T3', 'T4')
        $scenarios = @($script:settings.scenarios.PSObject.Properties.Name)
        $scenarios | Should -Contain 'connection-surge'
        $scenarios | Should -Contain 'blocking-chain'
        $scenarios | Should -Contain 'capacity-max'
        $scenarios | Should -Not -Contain 'healthy-baseline'
        $script:settings.scenarios.'blocking-chain'.maxMinutes | Should -Be 30
        $script:settings.scenarios.'capacity-max'.maxMinutes | Should -Be 20
        $script:settings.scenarios.'blocking-chain'.maxConcurrency | Should -Be 4
    }
}

Describe 'DbHub-Control run planning (Get-DbHubRunPlan)' {
    It 'caps each activity at its scenario''s maximum and the baseline at 120 minutes' {
        $request = Test-DbHubControlRequest -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'capacity-max' }, @{ target = 'T3'; scenario = 'baseline' }); durationMinutes = 90 }) -Settings $script:settings
        $now = [datetime]::new(2026, 10, 27, 14, 0, 0, [System.DateTimeKind]::Utc)
        $plan = Get-DbHubRunPlan -Request $request -Settings $script:settings -NowUtc $now
        $plan.Valid | Should -BeTrue
        @($plan.Activities | Where-Object Target -EQ 'T1')[0].Minutes | Should -Be 20
        @($plan.Activities | Where-Object Target -EQ 'T3')[0].Minutes | Should -Be 90
        $plan.RunEndUtc | Should -Be $now.AddMinutes(90)
        $plan.AutoStopUtc | Should -Be $now.AddMinutes(100)
    }

    It 'ends every activity 2 minutes before the VMs'' auto-shutdown' {
        $request = Test-DbHubControlRequest -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 60 }) -Settings $script:settings
        # 2026-10-27 is in Eastern daylight time: 19:00 local is 23:00 UTC.
        $plan = Get-DbHubRunPlan -Request $request -Settings $script:settings -NowUtc ([datetime]::new(2026, 10, 27, 22, 30, 0, [System.DateTimeKind]::Utc))
        $plan.Valid | Should -BeTrue
        $plan.ShutdownUtc | Should -Be ([datetime]::new(2026, 10, 27, 23, 0, 0, [System.DateTimeKind]::Utc))
        $plan.Activities[0].Minutes | Should -Be 28
    }

    It 'refuses a run that would have less than 5 minutes before the auto-shutdown' {
        $request = Test-DbHubControlRequest -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 60 }) -Settings $script:settings
        $plan = Get-DbHubRunPlan -Request $request -Settings $script:settings -NowUtc ([datetime]::new(2026, 10, 27, 22, 55, 0, [System.DateTimeKind]::Utc))
        $plan.Valid | Should -BeFalse
        $plan.Reason | Should -Match 'auto-shutdown'
    }

    It 'computes the next auto-shutdown as the module does, across daylight saving time' -ForEach @(
        @{ Now = [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc) }
        @{ Now = [datetime]::new(2026, 11, 1, 23, 30, 0, [System.DateTimeKind]::Utc) }
        @{ Now = [datetime]::new(2026, 3, 8, 6, 0, 0, [System.DateTimeKind]::Utc) }
    ) {
        $expected = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $script:config; Now = $Now } { Get-DemoNextShutdownUtc -Config $Config -NowUtc $Now }
        Get-DbHubNextShutdownUtc -Settings $script:settings -NowUtc $Now | Should -Be $expected
    }
}

Describe 'DbHub-Control and DbHub-Stop against a mocked Azure Resource Manager' {
    BeforeEach {
        Reset-TestAzure
        Mock Start-Sleep { }
        Mock Invoke-DbHubArm {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            return (Invoke-TestAzure -Method $Method -Path $Path -Body $Body)
        }
    }

    It 'refuses a run while another DbHub-Control job runs, and changes nothing' {
        $script:jobs = @(@{ properties = @{ jobId = 'bbbbbbbb-0000-0000-0000-00000000000b'; status = 'Running'; runbook = @{ name = 'DbHub-Control' }; creationTime = '2026-10-27T14:59:00Z' } })
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Refused'
        $result.message | Should -Match 'Another DbHub-Control job'
        @($script:calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
    }

    It 'lets the older of two jobs that started together go on' {
        $script:jobs = @(
            @{ properties = @{ jobId = 'aaaaaaaa-0000-0000-0000-00000000000a'; status = 'Running'; runbook = @{ name = 'DbHub-Control' }; creationTime = '2026-10-27T14:59:00Z' } }
            @{ properties = @{ jobId = 'cccccccc-0000-0000-0000-00000000000c'; status = 'New'; runbook = @{ name = 'DbHub-Control' }; creationTime = '2026-10-27T14:59:05Z' } }
        )
        (Get-DbHubActiveRun -Context (New-TestContext)).Active | Should -BeFalse
        (Get-DbHubActiveRun -Context (New-TestContext -JobId 'cccccccc-0000-0000-0000-00000000000c')).Active | Should -BeTrue
    }

    It 'refuses a run while the last run''s end is still ahead, and allows one once it has passed' {
        $script:autostop = '2026-10-27T15:20:00Z'
        $active = Get-DbHubActiveRun -Context (New-TestContext)
        $active.Active | Should -BeTrue
        $active.Reason | Should -Match 'Stop now'
        (Get-DbHubActiveRun -Context (New-TestContext -NowUtc ([datetime]::new(2026, 10, 27, 15, 11, 0, [System.DateTimeKind]::Utc)))).Active | Should -BeFalse
    }

    It 'treats jobs it can''t read as an active run' {
        Mock Invoke-DbHubArm { return (New-Response 403) } -ParameterFilter { $Path -match '/jobs\?' }
        (Get-DbHubActiveRun -Context (New-TestContext)).Active | Should -BeTrue
    }

    It 'creates the auto-stop before it starts anything, then starts the VMs and dispatches one Run Command per VM' {
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'blocking-chain'; intensity = 7 }, @{ target = 'T2'; scenario = 'tempdb-contention' }, @{ target = 'T3'; scenario = 'baseline' }); durationMinutes = 25 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        $writes = @($script:calls | Where-Object Method -NE 'GET')
        $firstStart = [array]::FindIndex([object[]]$writes, [Predicate[object]] { param($call) $call.Path -match '/start$' })
        $schedule = [array]::FindIndex([object[]]$writes, [Predicate[object]] { param($call) $call.Method -eq 'PUT' -and $call.Path -match '/schedules/dbhub-autostop$' })
        $schedule | Should -BeGreaterOrEqual 0
        $schedule | Should -BeLessThan $firstStart
        $script:autostop | Should -Be '2026-10-27T15:35:00Z'
        @($writes | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/start$' }).Count | Should -Be 2
        $commands = @($writes | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-' })
        $commands.Count | Should -Be 2
        foreach ($command in $commands) {
            $command.Body.properties.asyncExecution | Should -BeTrue
            $command.Body.location | Should -Be 'westus3'
        }
        $sqlvm = ($commands | Where-Object { $_.Path -match '/sqlvm01/' }).Body.properties.source.script
        $sqlvm | Should -Match "Invoke-DemoWorkloadControl\.ps1"
        $sqlvm | Should -Not -Match 'Get-VM'
        $archost = ($commands | Where-Object { $_.Path -match '/archost01/' }).Body.properties.source.script
        $archost | Should -Match "Get-VM -Name 'arcsql01'"
        @($writes | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/runCommands/DbHubControl-sqlvm01-20261026000000$' }).Count | Should -Be 1
        @($writes | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match 'DbHubDemo-Other' }) | Should -BeNullOrEmpty
    }

    It 'sends each target the same VM-side request the module would, with the planned minutes and the requester' {
        $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'blocking-chain'; intensity = 7; concurrency = 2 }, @{ target = 'T3'; scenario = 'baseline' }); durationMinutes = 45 }) -Context (New-TestContext)
        $sqlvmScript = ($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/sqlvm01/runCommands/DbHubControl-sqlvm01-' }).Body.properties.source.script
        $requests = @([regex]::Matches($sqlvmScript, "-RequestBase64 '([A-Za-z0-9+/=]+)'") | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_.Groups[1].Value)) | ConvertFrom-Json })
        $requests.Count | Should -Be 2
        $t1 = $requests | Where-Object target -EQ 'T1'
        $t1.arguments | Should -Be @('profile', 'set', '--name', 'incident:blocking-chain', '--duration', '30m', '--not-after', '{{NEXT_SHUTDOWN}}', '--concurrency', '2', '--intensity', '7', '--requested-by', 'notebook/aaaaaaaa')
        ($requests | Where-Object target -EQ 'T3').arguments | Should -Be @('profile', 'set', '--name', 'baseline', '--duration', '45m', '--not-after', '{{NEXT_SHUTDOWN}}', '--requested-by', 'notebook/aaaaaaaa')
        $single = InModuleScope -ModuleName DbHubDemo -Parameters @{ Request = [ordered]@{ target = 'T1'; arguments = @($t1.arguments); timeoutSeconds = 600 } } { Get-DemoWorkloadControlScript -Action Runner -Request $Request }
        $sqlvmScript.Contains($single) | Should -BeTrue
    }

    It 'restarts T1''s monitoring plugin when it isn''t running, as start-demo.ps1 does' {
        $script:plugin = 'NotRunning'
        $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $restart = $script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' }
        $restart.Body.properties.source.script | Should -Match "Restart-Service -Name 'SQLIaaSExtension'"
    }

    It 'skips T3 when it isn''t deployed and still runs the rest' {
        $script:t3 = 404
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }, @{ target = 'T3'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        ($result.skipped -join '; ') | Should -Match 'T3 \(not deployed'
        @($result.dispatched).Count | Should -Be 1
    }

    It 'skips T4 at once when Azure refuses its start, and dispatches the rest without waiting for it' {
        # Phase 25d, live: the PostgreSQL resource provider refused the start (HTTP 415), and the run then waited 15
        # minutes for a T4 that never started.
        $script:t4 = 'Stopped'
        $script:t4ActionStatus = 415
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'cpu-pressure' }, @{ target = 'T4'; scenario = 'idle-in-transaction' }); durationMinutes = 10 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        ($result.skipped -join '; ') | Should -Match 'T4 \(pgflex01-abc123 didn''t accept the start\)'
        @($result.dispatched) | Should -Be @('T1: cpu-pressure for 10 minutes')
        @($script:calls | Where-Object { $_.Method -eq 'GET' -and $_.Path -match '/flexibleServers/pgflex01-abc123$' }).Count | Should -Be 1
    }

    It 'skips a T4 that''s still stopping, without starting it or waiting for it' {
        $script:t4 = 'Stopping'
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }, @{ target = 'T4'; scenario = 'baseline' }); durationMinutes = 10 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        ($result.skipped -join '; ') | Should -Match 'T4 \(stopping\)'
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/start$' }) | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Method -eq 'GET' -and $_.Path -match '/flexibleServers/pgflex01-abc123$' }).Count | Should -Be 1
    }

    It 'starts a stopped T4 and dispatches its activity once it''s Ready' {
        $script:t4 = 'Stopped'
        Mock Get-DbHubT4 { return [pscustomobject]@{ Name = 'pgflex01-abc123'; State = $(if ($script:t4 -eq 'Starting') { 'Ready' } else { $script:t4 }) } }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }, @{ target = 'T4'; scenario = 'idle-in-transaction' }); durationMinutes = 10 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/flexibleServers/pgflex01-abc123/start$' }).Count | Should -Be 1
        @($result.dispatched) | Should -Contain 'T4: idle-in-transaction for 10 minutes'
        @($result.skipped) | Should -BeNullOrEmpty
    }

    It 'stops everything again when nothing could be dispatched' {
        $script:runCommandStatus = 409
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Failed'
        @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/deallocate$' }).Count | Should -BeGreaterThan 0
        $script:autostop | Should -BeNullOrEmpty
    }

    It 'Stop now removes the auto-stop, deallocates both VMs, and stops T4, without Run Command' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        $script:t4 = 'Ready'
        $script:autostop = '2026-10-27T15:30:00Z'
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop' }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        @($script:calls | Where-Object { $_.Path -match '/deallocate$' }).Count | Should -Be 2
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/stop$' }).Count | Should -Be 1
        $script:autostop | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Path -match '/runCommands' }) | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Path -match '/start$' }) | Should -BeNullOrEmpty
    }

    It 'the auto-stop (DbHub-Stop -Scope All) does what Stop now does, without Run Command' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $result = Invoke-DbHubStop -Scope All -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        @($script:calls | Where-Object { $_.Path -match '/sqlvm01/deallocate$' }).Count | Should -Be 1
        @($script:calls | Where-Object { $_.Path -match '/archost01/deallocate$' }) | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Path -match '/runCommands' }) | Should -BeNullOrEmpty
    }

    It 'the daily safety stop (DbHub-Stop -Scope T4) stops a running T4 only, and never starts anything' -ForEach @(
        @{ State = 'Ready'; Stops = 1; Status = 'Stopped' }
        @{ State = 'Stopped'; Stops = 0; Status = 'Skipped' }
        @{ State = ''; Stops = 0; Status = 'Skipped' }
    ) {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        $script:t4 = $State
        $result = Invoke-DbHubStop -Scope T4 -Context (New-TestContext)
        $result.status | Should -Be $Status
        @($script:calls | Where-Object { $_.Path -match '/stop$' }).Count | Should -Be $Stops
        @($script:calls | Where-Object { $_.Path -match '/(start|deallocate)$' -or $_.Path -match '/runCommands' -or $_.Path -match '/schedules/' }) | Should -BeNullOrEmpty
    }

    It 'exits cleanly when the demo resource group <Name>' -ForEach @(
        @{ Name = 'doesn''t exist'; Code = 404; Match = 'doesn''t exist' }
        @{ Name = 'can''t be read (A1 missing after a redeploy)'; Code = 403; Match = '-GrantRole' }
    ) {
        $script:group = $Code
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'NoEnvironment'
        $result.message | Should -Match $Match
        @($script:calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
    }

    It 'resets only the targets whose VM runs' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'reset' }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        @($result.dispatched) | Should -Be @('T1', 'T3')
        $result.message | Should -Match 'T2 \(archost01 isn''t running\)'
        @($script:calls | Where-Object { $_.Path -match '/start$' }) | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DbHubArm''s requests' {
    BeforeEach {
        $script:sent = $null
        Mock Invoke-WebRequest {
            $script:sent = [pscustomobject]@{ Method = $Method; ContentType = $ContentType; Body = $(if ($null -ne $Body) { [System.Text.Encoding]::UTF8.GetString([byte[]]$Body) } else { $null }) }
            return [pscustomobject]@{ StatusCode = 202; Content = '' }
        }
    }

    It 'sends a POST without a body as an empty JSON object, not as a form' {
        # Phase 25d, live: Windows PowerShell 5.1 sent T4's start as application/x-www-form-urlencoded, and the
        # PostgreSQL resource provider refused it with HTTP 415.
        $result = Invoke-DbHubArm -Context (New-TestContext) -Method POST -Path ($script:demo + '/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123/start') -ApiVersion '2024-08-01'
        $result.StatusCode | Should -Be 202
        $script:sent.Method | Should -Be 'POST'
        $script:sent.ContentType | Should -Be 'application/json'
        $script:sent.Body | Should -Be '{}'
    }

    It 'sends a body as JSON, and a GET without either' {
        $null = Invoke-DbHubArm -Context (New-TestContext) -Method PUT -Path ($script:account + '/schedules/dbhub-autostop') -ApiVersion '2024-10-23' -Body @{ properties = @{ frequency = 'OneTime' } }
        $script:sent.ContentType | Should -Be 'application/json'
        $script:sent.Body | Should -Be '{"properties":{"frequency":"OneTime"}}'
        $null = Invoke-DbHubArm -Context (New-TestContext) -Method GET -Path ($script:demo + '/providers/Microsoft.Compute/virtualMachines/sqlvm01/instanceView') -ApiVersion '2024-07-01'
        $script:sent.ContentType | Should -BeNullOrEmpty
        $script:sent.Body | Should -BeNullOrEmpty
    }
}

Describe 'The published runbooks' {
    It '<_> is self-contained: settings and the shared code in place of its markers, ASCII, and it parses' -ForEach @('DbHub-Control', 'DbHub-Stop') {
        $content = InModuleScope -ModuleName DbHubDemo -Parameters @{ Name = $_; Json = $script:settingsJson } { Get-DemoActivityControlRunbookContent -Name $Name -Setting ($Json | ConvertFrom-Json -AsHashtable) }
        $content | Should -Not -Match '__DBHUB_SETTINGS__'
        $content | Should -Not -Match '# __DBHUB_COMMON__'
        $content | Should -Match 'function Invoke-DbHubArm'
        [regex]::Matches($content, '[^\x00-\x7F]').Count | Should -Be 0
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $content | Should -Not -Match '(?i)azure-automation\.net/webhooks\?token='
    }

    It 'never call action Run Command, a Key Vault, Fabric, or anything outside Azure Resource Manager' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1') -Raw
        $text | Should -Not -Match 'runCommand/'
        $text | Should -Not -Match '(?i)vault\.azure\.net|api\.fabric\.microsoft\.com|graph\.microsoft\.com'
        @([regex]::Matches($text, 'https://[A-Za-z0-9.-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique) | Should -Be @('https://learn.microsoft.com', 'https://management.azure.com')
    }

    It 'validate requests the same way in Windows PowerShell 5.1' {
        $powershell = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue
        if (-not $IsWindows -or -not $powershell) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 runs on Windows only'
            return
        }
        $bodies = @(
            '{"action":"run","activities":[{"target":"T1","scenario":"blocking-chain","intensity":5}],"durationMinutes":20}'
            '{"action":"run","activities":[{"target":"T1","scenario":"baseline"}],"durationMinutes":20.5}'
            '{"action":"stop"}'
            '{"action":"reset","targets":["T2"]}'
            '{"action":"run","activities":[{"target":"T1","scenario":"drop-database"}],"durationMinutes":20}'
            '[{"action":"stop"}]'
            '[1,2]'
        )
        $expected = @($bodies | ForEach-Object { (Test-DbHubControlRequest -WebhookData (New-Webhook $_) -Settings $script:settings).Valid })
        ($expected | ForEach-Object { $_.ToString() }) -join ',' | Should -Be 'True,False,True,True,False,False,False'
        $requestFile = Join-Path -Path $TestDrive -ChildPath 'requests.json'
        Set-Content -LiteralPath $requestFile -Value (ConvertTo-Json -InputObject @{ settings = $script:settingsJson; bodies = $bodies } -Depth 4) -Encoding utf8
        $common = Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1'
        $command = ". '{0}'; `$in = Get-Content -LiteralPath '{1}' -Raw | ConvertFrom-Json; `$settings = ConvertFrom-DbHubSetting -Json `$in.settings; `$out = @(foreach (`$b in `$in.bodies) {{ (Test-DbHubControlRequest -WebhookData ([pscustomobject]@{{ RequestBody = [string]`$b }}) -Settings `$settings).Valid }}); `$out -join ','" -f $common, $requestFile
        $output = & $powershell.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command
        $LASTEXITCODE | Should -Be 0
        ([string]($output | Select-Object -Last 1)).Trim() | Should -Be (($expected | ForEach-Object { $_.ToString() }) -join ',')
    }
}
