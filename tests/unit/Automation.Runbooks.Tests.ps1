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

    # A small Azure: the VMs' power states, T3, T4, the auto-stop and monitoring re-check schedules and their links,
    # the control account's jobs, T1's monitoring plugin, and a clock that Start-Sleep moves.
    function Reset-TestAzure {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:clock = [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc)
        $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'deallocated' }
        # Minutes from a VM's start until it runs, by VM name; without an entry, it runs at once.
        $script:vmStartMinutes = @{}
        $script:vmRunningAt = @{}
        $script:t4 = ''
        # T4's size in its Servers - Get answer (sku.name and sku.tier); without one, the answer has no sku.
        $script:t4Sku = ''
        $script:t4Tier = ''
        $script:t3 = 200
        # T3's status and auto-pause delay in its Databases - Get answer (the nightly safety stop's T3 check, ADR 0024).
        $script:t3Status = 'Paused'
        $script:t3Delay = 15
        # The nightly safety stop: an HTTP status a VM's deallocate answers with, by VM name (409 while another operation runs),
        # the state a VM is in after that answer, and when a starting T4 is Ready.
        $script:deallocateStatus = @{}
        $script:conflictState = @{}
        $script:t4ReadyAt = $null
        $script:group = 200
        # The demo resource group's tags beside deploymentId: the busy marker's (2026-11-14), when a test sets them.
        $script:groupTags = @{}
        $script:jobs = @()
        $script:autostop = ''
        $script:rechecks = @{}
        $script:links = [System.Collections.Generic.List[object]]::new()
        # T1's plugin state, or a script block that returns it for the clock; '' means the agent reports no plugin
        # status yet.
        $script:plugin = 'Running'
        # When the agent's main service last reported (MainServiceLastReportedTime), a script block for the clock; by
        # default it reports all the time, as live (2026-11-04). $null leaves the time out, as an agent that doesn't report it.
        $script:pluginReported = { $script:clock }
        # A VM's latest start in its instance view (the provisioning status's time), by VM name; without an entry, no time.
        $script:vmSince = @{}
        $script:flag = $true
        $script:restartedAt = $null
        $script:runCommandStatus = 201
        $script:t4ActionStatus = 202
        # T4's read replica (ADR 0025): its state ('' for none, as between sessions), and the minutes T4's stop and the
        # replica's start take in this fake; without them, T4 stays Stopping and the replica Starting.
        $script:replica = ''
        $script:replicaStartMinutes = $null
        $script:replicaReadyAt = $null
        $script:t4StopMinutes = $null
        $script:t4StoppedAt = $null
        # Run Commands listed on a VM, by VM name; without an entry, the earlier run's DbHubControl-<vm>-20261026000000
        # and someone else's DbHubDemo-Other, without instance views.
        $script:runCommands = @{}
    }

    function Get-TestVmState([string] $Name) {
        if ($script:vm[$Name] -eq 'starting' -and $script:vmRunningAt.ContainsKey($Name) -and $script:clock -ge $script:vmRunningAt[$Name]) {
            $script:vm[$Name] = 'running'
        }
        return $script:vm[$Name]
    }

    function Invoke-TestAzure([string] $Method, [string] $Path, [object] $Body) {
        switch -Regex ($Path) {
            '/resourceGroups/rg-dbhub-demo$' {
                if ($script:group -ne 200) { return (New-Response $script:group) }
                # The busy marker's tags (2026-11-14) and any others a test sets, beside the deployment ID.
                $groupTags = @{ deploymentId = 'abc123' }
                foreach ($key in @($script:groupTags.Keys)) { $groupTags[$key] = $script:groupTags[$key] }
                return (New-Response 200 (ConvertTo-Json -InputObject @{ name = 'rg-dbhub-demo'; tags = $groupTags } -Depth 4))
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
            '/schedules/(dbhub-monitor-\d+)$' {
                $name = $Matches[1]
                if ($Method -eq 'PUT') { $script:rechecks[$name] = [string]$Body.properties.startTime; return (New-Response 201 '{}') }
                if ($Method -eq 'DELETE') {
                    if (-not $script:rechecks.ContainsKey($name)) { return (New-Response 404) }
                    $script:rechecks.Remove($name); return (New-Response 200)
                }
                if ($script:rechecks.ContainsKey($name)) { return (New-Response 200 '{}') }
                return (New-Response 404)
            }
            '/jobSchedules$' {
                return (New-Response 200 (ConvertTo-Json -InputObject @{ value = @($script:links | ForEach-Object { @{ properties = @{ jobScheduleId = $_.Id; schedule = @{ name = $_.Schedule }; runbook = @{ name = $_.Runbook } } } }) } -Depth 8))
            }
            '/jobSchedules/([0-9a-f-]{36})$' {
                $id = $Matches[1]
                if ($Method -eq 'PUT') {
                    # DbHub-Monitor's links have no parameters: an index, so strict mode allows the missing key.
                    $script:links.Add([pscustomobject]@{ Id = $id; Schedule = [string]$Body.properties.schedule.name; Runbook = [string]$Body.properties.runbook.name; Parameters = $Body.properties['parameters'] })
                    return (New-Response 201 '{}')
                }
                if ($Method -eq 'DELETE') {
                    $script:links = [System.Collections.Generic.List[object]]@($script:links | Where-Object Id -NE $id)
                    return (New-Response 200)
                }
                return (New-Response 404)
            }
            '/virtualMachines/(\w+)/instanceView$' {
                $name = $Matches[1]
                $provisioning = @{ code = 'ProvisioningState/succeeded' }
                if ($script:vmSince.ContainsKey($name)) {
                    $provisioning['time'] = $script:vmSince[$name].ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                return (New-Response 200 (ConvertTo-Json -InputObject @{ statuses = @($provisioning, @{ code = ('PowerState/{0}' -f (Get-TestVmState $name)) }) } -Depth 4))
            }
            '/virtualMachines/(\w+)/start$' {
                $name = $Matches[1]
                if ($script:vmStartMinutes.ContainsKey($name)) {
                    $script:vm[$name] = 'starting'
                    $script:vmRunningAt[$name] = $script:clock.AddMinutes($script:vmStartMinutes[$name])
                }
                else {
                    $script:vm[$name] = 'running'
                }
                return (New-Response 202)
            }
            '/virtualMachines/(\w+)/deallocate$' {
                $name = $Matches[1]
                if ($script:deallocateStatus.ContainsKey($name) -and $script:deallocateStatus[$name] -ne 202) {
                    if ($script:conflictState.ContainsKey($name)) { $script:vm[$name] = $script:conflictState[$name] }
                    return (New-Response $script:deallocateStatus[$name] '{"error":{"code":"OperationNotAllowed","message":"Another operation on this VM is in progress."}}')
                }
                $script:vm[$name] = 'deallocating'; return (New-Response 202)
            }
            '/extensions/SqlIaasExtension' {
                $state = if ($script:plugin -is [scriptblock]) { & $script:plugin } else { [string]$script:plugin }
                $statuses = @(@{ code = 'ProvisioningState/succeeded'; message = 'SQL Server IaaS Agent is running.' })
                if ($state) {
                    $statuses += @{ message = ('DatabaseMonitorArcPlugin: {{"State":"{0}","MetricsUploadStatus":"OK"}}' -f $state) }
                }
                $flags = @(@{ Name = 'DatabaseWatcheronAzureVM'; Enable = $script:flag })
                # Shaped like the live substatus (2026-11-04): the agent's health report, with its main service's last report.
                $substatuses = @()
                $reportedAt = & $script:pluginReported
                if ($null -ne $reportedAt) {
                    $substatuses += @{ code = 'ComponentStatus/Resource Provider Plugin/succeeded'; message = ('{{"ExtensionServiceHealthReport":{{"MainServiceStatus":"Running","MainServiceLastReportedTime":"{0}"}}}}' -f ([datetime]$reportedAt).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)) }
                }
                return (New-Response 200 (ConvertTo-Json -InputObject @{ properties = @{ settings = @{ FeatureFlags = $flags }; instanceView = @{ statuses = $statuses; substatuses = $substatuses } } } -Depth 8))
            }
            '/virtualMachines/(\w+)/runCommands(\?\$expand=instanceView)?$' {
                if ($script:runCommands.ContainsKey($Matches[1])) {
                    return (New-Response 200 (ConvertTo-Json -InputObject @{ value = @($script:runCommands[$Matches[1]]) } -Depth 8))
                }
                return (New-Response 200 ('{{"value":[{{"name":"DbHubControl-{0}-20261026000000"}},{{"name":"DbHubDemo-Other"}}]}}' -f $Matches[1]))
            }
            '/runCommands/' {
                if ($Method -eq 'PUT') {
                    if ($Path -match '/runCommands/DbHubControl-monitoring-' -and $script:runCommandStatus -in 200, 201) { $script:restartedAt = $script:clock }
                    return (New-Response $script:runCommandStatus '{}')
                }
                return (New-Response 202)
            }
            '/servers/azuresql01-abc123/databases/ContosoCare$' {
                if ($script:t3 -ne 200) { return (New-Response $script:t3 '{}') }
                return (New-Response 200 (ConvertTo-Json -InputObject @{ properties = @{ status = $script:t3Status; autoPauseDelay = $script:t3Delay } }))
            }
            '/flexibleServers/pgflex01-abc123$' {
                if (-not $script:t4) { return (New-Response 404) }
                if ($script:t4 -eq 'Starting' -and $null -ne $script:t4ReadyAt -and $script:clock -ge $script:t4ReadyAt) { $script:t4 = 'Ready' }
                if ($script:t4 -eq 'Stopping' -and $null -ne $script:t4StoppedAt -and $script:clock -ge $script:t4StoppedAt) { $script:t4 = 'Stopped' }
                if ($script:t4Sku) {
                    return (New-Response 200 (ConvertTo-Json -InputObject @{ sku = @{ name = $script:t4Sku; tier = $script:t4Tier }; properties = @{ state = $script:t4 } }))
                }
                return (New-Response 200 (ConvertTo-Json -InputObject @{ properties = @{ state = $script:t4 } }))
            }
            '/flexibleServers/pgflex01-abc123/(start|stop)$' {
                if ($script:t4ActionStatus -ne 202) { return (New-Response $script:t4ActionStatus '{"error":{"code":"UnsupportedMediaType","message":"Unsupported media type."}}') }
                # Azure's order (SourceReplicasStartStopOrder, live 2026-11-13): T4 starts only once its replica is Ready.
                if ($Matches[1] -eq 'start' -and $script:replica -in 'Stopped', 'Starting') { return (New-Response 400 '{"error":{"code":"SourceReplicasStartStopOrder","message":"Start the replicas first."}}') }
                if ($Matches[1] -eq 'stop' -and $null -ne $script:t4StopMinutes) { $script:t4StoppedAt = $script:clock.AddMinutes($script:t4StopMinutes) }
                $script:t4 = $(if ($Matches[1] -eq 'start') { 'Starting' } else { 'Stopping' }); return (New-Response 202)
            }
            '/flexibleServers/pgreplica01-abc123$' {
                if (-not $script:replica) { return (New-Response 404) }
                if ($script:replica -eq 'Starting' -and $null -ne $script:replicaReadyAt -and $script:clock -ge $script:replicaReadyAt) { $script:replica = 'Ready' }
                return (New-Response 200 (ConvertTo-Json -InputObject @{ properties = @{ state = $script:replica; replicationRole = 'AsyncReplica' } }))
            }
            '/flexibleServers/pgreplica01-abc123/(start|stop)$' {
                # Azure's order: the replica stops only once T4 is stopped.
                if ($Matches[1] -eq 'stop' -and $script:t4 -notin 'Stopped', '') { return (New-Response 400 '{"error":{"code":"SourceReplicasStartStopOrder","message":"Stop the source first."}}') }
                if ($Matches[1] -eq 'start' -and $null -ne $script:replicaStartMinutes) { $script:replicaReadyAt = $script:clock.AddMinutes($script:replicaStartMinutes) }
                $script:replica = $(if ($Matches[1] -eq 'start') { 'Starting' } else { 'Stopping' }); return (New-Response 202)
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
        @{ Name = 'the showcase on every target'; Body = @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'showcase' }, @{ target = 'T2'; scenario = 'showcase' }, @{ target = 'T3'; scenario = 'showcase' }, @{ target = 'T4'; scenario = 'showcase' }); durationMinutes = 90 } }
        @{ Name = 'the showcase with a target off'; Body = @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'showcase' }, @{ target = 'T2'; scenario = 'off' }); durationMinutes = 120 } }
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
        @{ Name = 'an intensity for the showcase'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"showcase","intensity":5}],"durationMinutes":90}'; Match = 'don''t apply to showcase' }
        @{ Name = 'a concurrency for off'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"showcase"},{"target":"T2","scenario":"off","concurrency":2}],"durationMinutes":90}'; Match = 'don''t apply to off' }
        @{ Name = 'a run of off only'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"off"},{"target":"T4","scenario":"off"}],"durationMinutes":20}'; Match = 'at least one activity that isn''t off' }
        @{ Name = 'the showcase in another case'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"Showcase"}],"durationMinutes":20}'; Match = 'isn''t a scenario' }
        @{ Name = 'business-day, which the control doesn''t run'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"business-day"}],"durationMinutes":20}'; Match = 'isn''t a scenario' }
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

    It 'allows the showcase profile, from scenarios/activity-profiles.json: 90 minutes by default, 120 at most, on T1 to T4' {
        @($script:settings.profiles.PSObject.Properties.Name) | Should -Be @('showcase')
        $script:settings.profiles.showcase.defaultMinutes | Should -Be 90
        $script:settings.profiles.showcase.maxMinutes | Should -Be 120
        @($script:settings.profiles.showcase.targets) | Should -Be @('T1', 'T2', 'T3', 'T4')
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

    It 'gives the showcase its minutes up to its 120, off none, and ends the showcase with the run' {
        $request = Test-DbHubControlRequest -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'showcase' }, @{ target = 'T2'; scenario = 'off' }, @{ target = 'T3'; scenario = 'capacity-max' }); durationMinutes = 90 }) -Settings $script:settings
        $now = [datetime]::new(2026, 10, 27, 14, 0, 0, [System.DateTimeKind]::Utc)
        $plan = Get-DbHubRunPlan -Request $request -Settings $script:settings -NowUtc $now
        $plan.Valid | Should -BeTrue
        $showcase = @($plan.Activities | Where-Object Target -EQ 'T1')[0]
        $showcase.Minutes | Should -Be 90
        $showcase.NotAfterUtc | Should -Be $now.AddMinutes(92)
        @($plan.Activities | Where-Object Target -EQ 'T2')[0].Minutes | Should -Be 0
        @($plan.Activities | Where-Object Target -EQ 'T2')[0].NotAfterUtc | Should -BeNullOrEmpty
        @($plan.Activities | Where-Object Target -EQ 'T3')[0].Minutes | Should -Be 20
        @($plan.Activities | Where-Object Target -EQ 'T3')[0].NotAfterUtc | Should -BeNullOrEmpty
        $plan.RunEndUtc | Should -Be $now.AddMinutes(90)
        # Near the auto-shutdown, the showcase ends with the shortened run.
        $late = Get-DbHubRunPlan -Request $request -Settings $script:settings -NowUtc ([datetime]::new(2026, 10, 27, 22, 30, 0, [System.DateTimeKind]::Utc))
        @($late.Activities | Where-Object Target -EQ 'T1')[0].Minutes | Should -Be 28
        @($late.Activities | Where-Object Target -EQ 'T1')[0].NotAfterUtc | Should -Be ([datetime]::new(2026, 10, 27, 23, 0, 0, [System.DateTimeKind]::Utc))
    }

    It 'reads T4''s vCores from its size''s name: <Sku> is <VCores>' -ForEach @(
        @{ Sku = 'Standard_B1ms'; VCores = 1 }
        @{ Sku = 'Standard_B2s'; VCores = 2 }
        @{ Sku = 'Standard_D2ds_v5'; VCores = 2 }
        @{ Sku = 'Standard_D4ds_v5'; VCores = 4 }
        @{ Sku = 'Standard_D4ads_v5'; VCores = 4 }
        @{ Sku = 'Standard_E16ds_v5'; VCores = 16 }
        @{ Sku = ''; VCores = 0 }
        @{ Sku = 'GP_Gen5_2'; VCores = 0 }
    ) {
        Get-DbHubT4VCore -SkuName $Sku | Should -Be $VCores
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
    # Start-Sleep moves the fake clock (Get-DbHubUtcNow), so the run's waits take no real time.
    BeforeEach {
        Reset-TestAzure
        Mock Get-DbHubUtcNow { return $script:clock }
        Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
        Mock Invoke-DbHubArm {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body; At = $script:clock })
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
        $single = InModuleScope -ModuleName DbHubDemo -Parameters @{ Request = [ordered]@{ target = 'T1'; arguments = @($t1.arguments); timeoutSeconds = 300; readySeconds = 600 } } { Get-DemoWorkloadControlScript -Action Runner -Request $Request }
        $sqlvmScript.Contains($single) | Should -BeTrue
    }

    It 'sends the showcase with the run''s end as --not-after, T4''s with its tier and vCores, and off as off' {
        $script:t4 = 'Ready'
        $script:t4Sku = 'Standard_D4ds_v5'
        $script:t4Tier = 'GeneralPurpose'
        # An off goes only to a VM that already runs (review of PR 20).
        $script:vm['archost01'] = 'running'
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'showcase' }, @{ target = 'T2'; scenario = 'off' }, @{ target = 'T3'; scenario = 'showcase' }, @{ target = 'T4'; scenario = 'showcase' }); durationMinutes = 90 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        @($result.dispatched) | Should -Be @('T1: showcase for 90 minutes', 'T3: showcase for 90 minutes', 'T4: showcase for 90 minutes', 'T2: off')
        $decode = { param($Pattern) @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match $Pattern } | ForEach-Object { [regex]::Matches($_.Body.properties.source.script, "-RequestBase64 '([A-Za-z0-9+/=]+)'") | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_.Groups[1].Value)) } }) }
        # Read as JSON text: PowerShell 7's ConvertFrom-Json would turn the time into a DateTime; the VM side (Windows
        # PowerShell 5.1) keeps it a string.
        $arguments = { param([string] $Json) ([regex]::Match($Json, '"arguments":\[([^\]]*)\]').Groups[1].Value) }
        $sqlvm = & $decode '/sqlvm01/runCommands/DbHubControl-sqlvm01-'
        # 15:00 UTC plus 90 minutes is the run's end; the runner stops 2 minutes before --not-after.
        & $arguments @($sqlvm | Where-Object { $_ -match '"target":"T1"' })[0] | Should -BeExactly '"profile","set","--name","showcase","--duration","90m","--not-after","2026-10-27T16:32:00+00:00","--requested-by","notebook/aaaaaaaa"'
        & $arguments @($sqlvm | Where-Object { $_ -match '"target":"T3"' })[0] | Should -BeExactly '"profile","set","--name","showcase","--duration","90m","--not-after","2026-10-27T16:32:00+00:00","--requested-by","notebook/aaaaaaaa"'
        & $arguments @($sqlvm | Where-Object { $_ -match '"target":"T4"' })[0] | Should -BeExactly '"profile","set","--name","showcase","--duration","90m","--not-after","2026-10-27T16:32:00+00:00","--tier","GeneralPurpose","--vcores","4","--requested-by","notebook/aaaaaaaa"'
        & $arguments @(& $decode '/archost01/runCommands/DbHubControl-archost01-' | Where-Object { $_ -match '"target":"T2"' })[0] | Should -BeExactly '"profile","set","--name","off","--requested-by","notebook/aaaaaaaa"'
        @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/archost01/start$' }) | Should -BeNullOrEmpty
        $script:autostop | Should -Be '2026-10-27T16:40:00Z'
    }

    It 'never starts a VM or T4 for an off: a T2 off on a stopped host and a T4 off on a stopped server issue no start and no wait (review of PR 20)' {
        # The reviewer's request: T1 and T3 showcase, T2 off, T4 off, with everything stopped. Before, it booted archost01
        # and started the 4-vCore T4, waited up to 15 and 20 minutes, and sent off; both billed until the auto-stop.
        $script:t4 = 'Stopped'
        $script:t4Sku = 'Standard_D4ds_v5'
        $script:t4Tier = 'GeneralPurpose'
        $start = $script:clock
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'showcase' }, @{ target = 'T2'; scenario = 'off' }, @{ target = 'T3'; scenario = 'showcase' }, @{ target = 'T4'; scenario = 'off' }); durationMinutes = 90 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        $posts = @($script:calls | Where-Object Method -EQ 'POST' | ForEach-Object { $_.Path })
        @($posts | Where-Object { $_ -match '/sqlvm01/start$' }).Count | Should -Be 1
        @($posts | Where-Object { $_ -match '/archost01/start$|/flexibleServers/[^/]+/start$' }) | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/' }) | Should -BeNullOrEmpty -Because 'T4''s off neither reads, starts, nor waits for T4'
        $script:vm['archost01'] | Should -Be 'deallocated'
        $script:t4 | Should -Be 'Stopped'
        @($result.dispatched) | Should -Be @('T1: showcase for 90 minutes', 'T3: showcase for 90 minutes', 'T4: off')
        @($result.skipped) | Should -Be @('T2 (off not sent: archost01 is deallocated, so nothing runs there)')
        # T4's off goes in sqlvm01's own Run Command, which doesn't wait for it, and the job ends once T1's plugin is
        # settled, 20 seconds in, not 20 minutes later.
        $commands = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/sqlvm01/runCommands/DbHubControl-sqlvm01-' })
        $commands.Count | Should -Be 1
        $requests = @([regex]::Matches($commands[0].Body.properties.source.script, "-RequestBase64 '([A-Za-z0-9+/=]+)'") | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_.Groups[1].Value)) })
        $t4Request = @($requests | Where-Object { $_ -match '"target":"T4"' })[0]
        [regex]::Match($t4Request, '"arguments":\[([^\]]*)\]').Groups[1].Value | Should -BeExactly '"profile","set","--name","off","--requested-by","notebook/aaaaaaaa"'
        $t4Request | Should -Match '"readySeconds":0[,}]'
        @($script:calls | Where-Object { $_.Path -match '/runCommands/DbHubControl-sqlvm01-t4-' }) | Should -BeNullOrEmpty
        ($script:clock - $start).TotalMinutes | Should -BeLessThan 2
    }

    It 'sends an off to a VM that already runs without starting it, skips one that doesn''t run, and leaves T1''s plugin alone when T1 is off' {
        $script:vm['sqlvm01'] = 'running'
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'off' }, @{ target = 'T2'; scenario = 'showcase' }, @{ target = 'T3'; scenario = 'off' }, @{ target = 'T4'; scenario = 'off' }); durationMinutes = 60 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        $posts = @($script:calls | Where-Object Method -EQ 'POST' | ForEach-Object { $_.Path })
        @($posts | Where-Object { $_ -match '/archost01/start$' }).Count | Should -Be 1
        @($posts | Where-Object { $_ -match '/sqlvm01/start$|/flexibleServers/' }) | Should -BeNullOrEmpty
        @($result.dispatched) | Should -Be @('T1: off', 'T3: off', 'T4: off', 'T2: showcase for 60 minutes')
        $result.monitoring | Should -BeNullOrEmpty
        @($result.rechecks) | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Path -match '/extensions/|/flexibleServers/' }) | Should -BeNullOrEmpty

        # The same offs on a stopped sqlvm01 aren't sent, and nothing starts it.
        Reset-TestAzure
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'off' }, @{ target = 'T2'; scenario = 'showcase' }, @{ target = 'T4'; scenario = 'off' }); durationMinutes = 30 }) -Context (New-TestContext)
        @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/sqlvm01/start$' }) | Should -BeNullOrEmpty
        @($result.skipped) | Should -Be @('T1 (off not sent: sqlvm01 is deallocated, so nothing runs there)', 'T4 (off not sent: sqlvm01 is deallocated, so nothing runs there)')
        @($result.dispatched) | Should -Be @('T2: showcase for 30 minutes')
    }

    It 'stops what it started when the only activities it could dispatch are off' {
        $script:vm['archost01'] = 'running'
        $script:vmStartMinutes['sqlvm01'] = 60
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'showcase' }, @{ target = 'T2'; scenario = 'off' }); durationMinutes = 30 }) -Context (New-TestContext)
        @($result.dispatched) | Should -Be @('T2: off')
        $result.status | Should -Be 'Failed'
        $result.message | Should -Match '^No activity could be dispatched \(T1 \(sqlvm01 isn''t running yet\)\), so everything was stopped again'
        @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/deallocate$' }).Count | Should -Be 2
    }

    It 'sends T4''s showcase without a tier or vCores when its size can''t be read' {
        $script:t4 = 'Ready'
        $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T4'; scenario = 'showcase' }); durationMinutes = 30 }) -Context (New-TestContext)
        $source = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/sqlvm01/runCommands/DbHubControl-sqlvm01-' })[0].Body.properties.source.script
        $request = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([regex]::Match($source, "-RequestBase64 '([A-Za-z0-9+/=]+)'").Groups[1].Value))
        [regex]::Match($request, '"arguments":\[([^\]]*)\]').Groups[1].Value | Should -BeExactly '"profile","set","--name","showcase","--duration","30m","--not-after","2026-10-27T15:32:00+00:00","--requested-by","notebook/aaaaaaaa"'
    }

    It 'restarts T1''s monitoring plugin when it isn''t running, as start-demo.ps1 does' {
        $script:plugin = 'NotRunning'
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $restart = $script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' }
        $restart.Body.properties.source.script | Should -Match "Restart-Service -Name 'SQLIaaSExtension'"
        # It reads the plugin again after the restart, for at most monitoring.verifyMinutes.
        $result.monitoring | Should -Be 'StillNotRunning'
        $result.message | Should -Match 'still didn''t run after its restart'
        ($script:clock - $restart.At).TotalMinutes | Should -BeGreaterOrEqual 5
        ($script:clock - $restart.At).TotalMinutes | Should -BeLessThan 6
    }

    It 'waits for the plugin''s first status, and leaves a plugin that then runs alone (live, 2026-11-03)' {
        # Right after a start the agent reports no plugin status yet; a restart then left the plugin NotRunning for
        # hours (2026-10-26), and reading it once and moving on sent no restart at all (2026-11-03).
        $script:pluginAt = $script:clock.AddMinutes(3)
        $script:plugin = { if ($script:clock -lt $script:pluginAt) { '' } else { 'Running' } }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        $result.monitoring | Should -Be 'Running'
        $result.message | Should -Match 'monitoring plugin runs'
        @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' }) | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Method -eq 'GET' -and $_.Path -match '/extensions/SqlIaasExtension' }).Count | Should -BeGreaterThan 1
    }

    It 'restarts the plugin''s agent when the plugin reports no status for 8 minutes, then sees it run' {
        $start = $script:clock
        $script:plugin = { if ($null -ne $script:restartedAt -and $script:clock -ge $script:restartedAt.AddMinutes(2)) { 'Running' } else { '' } }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.monitoring | Should -Be 'Restarted'
        $result.message | Should -Match 'was restarted and runs'
        $restart = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-20261027150000$' })
        $restart.Count | Should -Be 1
        # monitoring.settleMinutes is 8 since 2026-11-04 (5 before).
        ($restart[0].At - $start).TotalMinutes | Should -BeGreaterOrEqual 8
        ($restart[0].At - $start).TotalMinutes | Should -BeLessThan 9
        # The activity went out first: the plugin never holds back a dispatch.
        (@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-sqlvm01-' })[0].At) | Should -Be $start
    }

    It 'leaves the plugin alone when performance monitoring isn''t turned on' {
        $script:flag = $false
        $script:plugin = 'NotRunning'
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.monitoring | Should -Be 'NotSelected'
        @($script:calls | Where-Object { $_.Path -match '/runCommands/DbHubControl-monitoring-' }) | Should -BeNullOrEmpty
    }

    It 'counts only a plugin status reported after the run''s start of sqlvm01: a stale Running gets one restart when no fresh status comes (live, 2026-11-04)' {
        # Live: the run started sqlvm01 at 14:34:25Z; at 14:35:12Z the instance view still said Running and OK from before
        # the stop, so no restart went out; at 14:46:51Z it said NotRunning, and T1 had sent no telemetry for 12 minutes.
        $start = $script:clock
        $script:staleAt = $start.AddHours(-3)
        $script:pluginReported = { if ($null -ne $script:restartedAt -and $script:clock -ge $script:restartedAt.AddMinutes(2)) { $script:clock } else { $script:staleAt } }
        $context = New-TestContext
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'showcase' }); durationMinutes = 90 }) -Context $context
        $result.status | Should -Be 'Dispatched'
        $result.monitoring | Should -Be 'Restarted'
        $restart = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' })
        $restart.Count | Should -Be 1 -Because 'the agent is restarted once'
        ($restart[0].At - $start).TotalMinutes | Should -BeGreaterOrEqual 8 -Because 'it waits monitoring.settleMinutes for a fresh status first'
        ($restart[0].At - $start).TotalMinutes | Should -BeLessThan 9
        (@($context.Log) -join [System.Environment]::NewLine) | Should -Match ([regex]::Escape('T1''s monitoring plugin: no fresh plugin status since sqlvm01''s start at 2026-10-27T15:00:00Z (waited 8 minutes); the last one, reported at 2026-10-27T12:00:00Z, said DatabaseMonitorArcPlugin: {"State":"Running","MetricsUploadStatus":"OK"}; the SQL IaaS Agent service is restarted.'))
    }

    It 'restarts the plugin''s agent at once when a fresh status says NotRunning' {
        $start = $script:clock
        $script:plugin = { if ($null -ne $script:restartedAt -and $script:clock -ge $script:restartedAt.AddMinutes(2)) { 'Running' } else { 'NotRunning' } }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.monitoring | Should -Be 'Restarted'
        $restart = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' })
        $restart.Count | Should -Be 1
        # The first read comes as the start is accepted, before the agent can report; the next one, 20 seconds later, is fresh.
        ($restart[0].At - $start).TotalSeconds | Should -Be 20
    }

    It 'leaves the plugin alone when a fresh status says Running' {
        $start = $script:clock
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.monitoring | Should -Be 'Running'
        $result.message | Should -Match 'monitoring plugin runs'
        @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' }) | Should -BeNullOrEmpty
        ($script:clock - $start).TotalMinutes | Should -BeLessThan 1
    }

    It 'restarts the plugin''s agent once after a cold start when the agent reports no time, after the wait' {
        # Without MainServiceLastReportedTime a status can't be told from the one before the stop, so a cold start gets the
        # restart the 2026-10-22 and 2026-10-30 findings call for; after it, the agent is taken at its word.
        $start = $script:clock
        $script:pluginReported = { $null }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.monitoring | Should -Be 'Restarted'
        $restart = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' })
        $restart.Count | Should -Be 1
        ($restart[0].At - $start).TotalMinutes | Should -BeGreaterOrEqual 8
        ($restart[0].At - $start).TotalMinutes | Should -BeLessThan 9
    }

    It 'compares the status with sqlvm01''s latest start in its instance view when the run didn''t start it' {
        $script:vm['sqlvm01'] = 'running'
        # Started in the portal 2 minutes ago: the status from before that start is stale.
        $script:vmSince['sqlvm01'] = $script:clock.AddMinutes(-2)
        $script:staleAt = $script:clock.AddHours(-3)
        $script:pluginReported = { if ($null -ne $script:restartedAt) { $script:clock } else { $script:staleAt } }
        $start = $script:clock
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.monitoring | Should -Be 'Restarted'
        (@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' })[0].At - $start).TotalMinutes | Should -BeGreaterOrEqual 8

        # Running for hours, with an agent that reports no time: taken at its word, as before.
        Reset-TestAzure
        $script:vm['sqlvm01'] = 'running'
        $script:vmSince['sqlvm01'] = $script:clock.AddHours(-2)
        $script:pluginReported = { $null }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.monitoring | Should -Be 'Running'
        @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' }) | Should -BeNullOrEmpty
    }

    It 'neither reads the plugin nor schedules re-checks for a run that doesn''t use sqlvm01' {
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T2'; scenario = 'baseline' }); durationMinutes = 120 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        $result.monitoring | Should -BeNullOrEmpty
        @($result.rechecks) | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Path -match '/extensions/|/schedules/dbhub-monitor-' -and $_.Method -ne 'DELETE' }) | Should -BeNullOrEmpty
    }

    It 'checks the plugin again every 30 minutes of a long run, and Stop now takes the re-checks away' {
        # Live, 2026-10-30: the plugin stopped again within 90 minutes after a start; a run lasts up to 120.
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 120 }) -Context (New-TestContext)
        @($result.rechecks) | Should -Be @('dbhub-monitor-1', 'dbhub-monitor-2', 'dbhub-monitor-3')
        $script:rechecks['dbhub-monitor-1'] | Should -Be '2026-10-27T15:30:00Z'
        $script:rechecks['dbhub-monitor-3'] | Should -Be '2026-10-27T16:30:00Z'
        $monitors = @($script:links | Where-Object Runbook -EQ 'DbHub-Monitor')
        $monitors.Count | Should -Be 3
        foreach ($link in $monitors) {
            $link.Parameters | Should -BeNullOrEmpty
        }
        # A short run gets none: its end comes before the first re-check.
        $script:autostop = ''
        $short = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        @($short.rechecks) | Should -BeNullOrEmpty
        $script:rechecks.Count | Should -Be 0 -Because 'the next run removes the last run''s re-checks with its auto-stop'
        $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 120 }) -Context (New-TestContext -NowUtc ([datetime]::new(2026, 10, 27, 15, 40, 0, [System.DateTimeKind]::Utc)))
        $script:rechecks.Count | Should -Be 3
        $stop = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop' }) -Context (New-TestContext)
        $stop.status | Should -Be 'Stopped'
        $script:rechecks.Count | Should -Be 0
        @($script:links) | Should -BeNullOrEmpty
    }

    It 'dispatches each VM as soon as it runs: T1 and T3 don''t wait for T2''s host (live, 2026-11-03)' {
        $start = $script:clock
        $script:vmStartMinutes = @{ archost01 = 6 }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }, @{ target = 'T2'; scenario = 'baseline' }, @{ target = 'T3'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        @($result.dispatched).Count | Should -Be 3
        $sqlvm = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/sqlvm01/runCommands/DbHubControl-sqlvm01-' })
        $archost = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/archost01/runCommands/DbHubControl-archost01-' })
        $sqlvm[0].At | Should -Be $start
        ($archost[0].At - $start).TotalMinutes | Should -BeGreaterOrEqual 6
        ($archost[0].At - $start).TotalMinutes | Should -BeLessThan 7
    }

    It 'skips the activities of a VM that isn''t running after 15 minutes, and still sends the others' {
        $script:vmStartMinutes = @{ archost01 = 30 }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }, @{ target = 'T2'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        @($result.dispatched) | Should -Be @('T1: baseline for 20 minutes')
        ($result.skipped -join '; ') | Should -Match 'T2 \(archost01 isn''t running yet\)'
        @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/archost01/runCommands/' }) | Should -BeNullOrEmpty
    }

    It 'sends T4''s activity on its own once T4 is Ready, without holding back T1 and T3 (live, 2026-11-03)' {
        $start = $script:clock
        $script:t4 = 'Stopped'
        $script:t4ReadyAt = $start.AddMinutes(8)
        Mock Get-DbHubT4 { return [pscustomobject]@{ Name = 'pgflex01-abc123'; State = $(if ($script:t4 -eq 'Starting' -and $script:clock -ge $script:t4ReadyAt) { 'Ready' } else { $script:t4 }) } }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'cpu-pressure' }, @{ target = 'T3'; scenario = 'baseline' }, @{ target = 'T4'; scenario = 'idle-in-transaction' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        @($result.dispatched).Count | Should -Be 3
        @($result.skipped) | Should -BeNullOrEmpty
        $decode = { param($Call) @([regex]::Matches($Call.Body.properties.source.script, "-RequestBase64 '([A-Za-z0-9+/=]+)'") | ForEach-Object { ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_.Groups[1].Value)) | ConvertFrom-Json).target }) }
        $first = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-sqlvm01-20261027150000$' })
        $late = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-sqlvm01-t4-20261027150000$' })
        $first[0].At | Should -Be $start
        & $decode $first[0] | Should -Be @('T1', 'T3')
        & $decode $late[0] | Should -Be @('T4')
        ($late[0].At - $start).TotalMinutes | Should -BeGreaterOrEqual 8
        ($late[0].At - $start).TotalMinutes | Should -BeLessThan 9
        # The late dispatch keeps the run's first Run Command: only the earlier run's are deleted.
        @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/runCommands/DbHubControl-sqlvm01-(t4-)?20261027150000$' }) | Should -BeNullOrEmpty
    }

    It 'skips T4 when it isn''t Ready after 20 minutes, while T1 went out at once' {
        $start = $script:clock
        $script:t4 = 'Stopped'
        Mock Get-DbHubT4 { return [pscustomobject]@{ Name = 'pgflex01-abc123'; State = $script:t4 } }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }, @{ target = 'T4'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        @($result.dispatched) | Should -Be @('T1: baseline for 20 minutes')
        ($result.skipped -join '; ') | Should -Match 'T4 \(pgflex01-abc123 isn''t Ready yet\)'
        @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-sqlvm01-' })[0].At | Should -Be $start
        @($script:calls | Where-Object { $_.Path -match '-t4-' }) | Should -BeNullOrEmpty
        ($script:clock - $start).TotalMinutes | Should -BeGreaterOrEqual 20
        ($script:clock - $start).TotalMinutes | Should -BeLessThan 21
    }

    It 'sends each request its readiness bound, and gives each Run Command the time its waits can take' {
        $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'blocking-chain' }, @{ target = 'T2'; scenario = 'baseline' }, @{ target = 'T3'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $decode = { param($Call) @([regex]::Matches($Call.Body.properties.source.script, "-RequestBase64 '([A-Za-z0-9+/=]+)'") | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_.Groups[1].Value)) | ConvertFrom-Json }) }
        $archost = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/archost01/runCommands/DbHubControl-archost01-' })[0]
        $t2 = & $decode $archost
        $t2.target | Should -Be 'T2'
        $t2.readySeconds | Should -Be 1200
        $t2.timeoutSeconds | Should -Be 300
        # 5 minutes, plus T2's readiness bound and runner timeout, plus the 12-minute heartbeat wait in front of it.
        $archost.Body.properties.timeoutInSeconds | Should -Be (300 + 1200 + 300 + 720)
        $sqlvm = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/sqlvm01/runCommands/DbHubControl-sqlvm01-' })[0]
        @(& $decode $sqlvm | ForEach-Object readySeconds) | Should -Be @(600, 600)
        $sqlvm.Body.properties.timeoutInSeconds | Should -Be (300 + 2 * (600 + 300))
        # Clear-DbHubOldRunCommand counts a Run Command as finished an hour after the time in its name.
        Get-DbHubRunCommandTimeout -Request @(1..9 | ForEach-Object { @{ target = 'T2'; readySeconds = 1200; timeoutSeconds = 300 } }) | Should -Be 3000
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
        # No replica (ADR 0025): the run says plainly that its replica beat isn't there, and how to get it.
        $result.replica | Should -Match '^T4''s read replica isn''t there: on-demand runs don''t create it, so Database Hub''s Read replica lag stays empty and the replica-lag scenario can''t run in this run\. For that beat, start the demo with \./scripts/start-demo\.ps1'
        $result.message | Should -Match 'T4''s read replica isn''t there: on-demand runs don''t create it'
    }

    It 'starts a stopped read replica a session left behind before T4, because Azure starts T4 only after its replicas (ADR 0025)' {
        $script:t4 = 'Stopped'
        $script:replica = 'Stopped'
        $script:replicaStartMinutes = 2
        Mock Get-DbHubT4 { return [pscustomobject]@{ Name = 'pgflex01-abc123'; State = $(if ($script:t4 -eq 'Starting') { 'Ready' } else { $script:t4 }) } }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }, @{ target = 'T4'; scenario = 'idle-in-transaction' }); durationMinutes = 10 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        $starts = @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/flexibleServers/(pgreplica01|pgflex01)-abc123/start$' })
        @($starts | ForEach-Object { $_.Path -replace '^.*/flexibleServers/', '' }) | Should -Be @('pgreplica01-abc123/start', 'pgflex01-abc123/start')
        $starts[1].At | Should -BeGreaterOrEqual $script:replicaReadyAt
        @($result.dispatched) | Should -Contain 'T4: idle-in-transaction for 10 minutes'
        $result.replica | Should -BeNullOrEmpty -Because 'the replica is there, so the beat is too'
    }

    It 'skips T4, and says why, when a left-over replica can''t be started first' {
        $script:t4 = 'Stopped'
        $script:replica = 'Stopped'
        Mock Get-DbHubT4 { return [pscustomobject]@{ Name = 'pgflex01-abc123'; State = $script:t4 } }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }, @{ target = 'T4'; scenario = 'baseline' }); durationMinutes = 10 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        ($result.skipped -join '; ') | Should -Match 'T4 \(its read replica pgreplica01-abc123 couldn''t be started first: it was still Starting after 10 minutes\)'
        $result.replica | Should -Match 'Azure starts T4 only after its replicas, so T4 sits this run out'
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/start$' }) | Should -BeNullOrEmpty
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

    It 'deletes the control''s finished Run Commands on a running VM the run doesn''t use, and keeps one that still runs (Phase 28 follow-up)' {
        # Live, 2026-11-02: a run's Run Command stayed on a VM that later runs didn't use; a VM takes 25 managed ones.
        $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'running' }
        $script:runCommands['archost01'] = @(
            @{ name = 'DbHubControl-archost01-20261026000000'; properties = @{ instanceView = @{ executionState = 'Succeeded' } } }
            @{ name = 'DbHubControl-archost01-reset-20261027145500'; properties = @{ instanceView = @{ executionState = 'Running' } } }
            @{ name = 'DbHubControl-archost01-20261027120000'; properties = @{ provisioningState = 'Succeeded' } }
            @{ name = 'DbHubDemo-Bootstrap'; properties = @{ instanceView = @{ executionState = 'Succeeded' } } }
        )
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        @($script:calls | Where-Object { $_.Method -eq 'GET' -and $_.Path -match '/archost01/runCommands\?\$expand=instanceView$' }).Count | Should -Be 1
        $deleted = @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/archost01/runCommands/' } | ForEach-Object { $_.Path -replace '^.*/runCommands/', '' })
        # The finished one, and one whose instance view is gone but whose time is more than an hour old; never one that
        # still runs, or anything that isn't the control's.
        $deleted | Should -Be @('DbHubControl-archost01-20261026000000', 'DbHubControl-archost01-20261027120000')
        # The VM it dispatched to gets its own cleanup, as before.
        @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/sqlvm01/runCommands/DbHubControl-sqlvm01-20261026000000$' }).Count | Should -Be 1
    }

    It 'a reset cleans the other running VM''s finished Run Commands too, and touches no VM that isn''t running' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'reset'; targets = @('T2') }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/sqlvm01/runCommands/DbHubControl-sqlvm01-20261026000000$' }).Count | Should -Be 1
        @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match 'DbHubDemo-Other' }) | Should -BeNullOrEmpty
        $script:calls.Clear()
        $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'running' }
        $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'reset'; targets = @('T2') }) -Context (New-TestContext)
        @($script:calls | Where-Object { $_.Path -match '/sqlvm01/runCommands' }) | Should -BeNullOrEmpty
    }

    It 'sends a Run Command with only its script, no parameters or protected parameters, and nothing secret in it' {
        $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'blocking-chain'; intensity = 7 }, @{ target = 'T2'; scenario = 'baseline' }); durationMinutes = 20; requestedBy = 'notebook' }) -Context (New-TestContext)
        $puts = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-' })
        $puts.Count | Should -Be 2
        foreach ($put in $puts) {
            @($put.Body.Keys | Sort-Object) | Should -Be @('location', 'properties')
            @($put.Body.properties.Keys | Sort-Object) | Should -Be @('asyncExecution', 'source', 'timeoutInSeconds', 'treatFailureAsDeploymentFailure')
            @($put.Body.properties.source.Keys) | Should -Be @('script')
            (Find-DemoSecretLeak -Text $put.Body.properties.source.script -Source $put.Path).Findings | Should -BeNullOrEmpty
        }
        # The identity's role allows exactly what the cleanup and the dispatch do on Run Commands (ADR 0020).
        $actions = InModuleScope -ModuleName DbHubDemo { $script:ActivityControlRoleActions }
        foreach ($action in 'read', 'write', 'delete') {
            $actions | Should -Contain ('Microsoft.Compute/virtualMachines/runCommands/{0}' -f $action)
        }
    }
}

Describe 'The nightly safety stop (DbHub-Stop -Scope Nightly and T3Check, ADR 0024) against a mocked Azure Resource Manager' {
    # Start-Sleep moves the fake clock (Get-DbHubUtcNow), so the waits take no real time.
    BeforeEach {
        Reset-TestAzure
        Mock Get-DbHubUtcNow { return $script:clock }
        Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
        Mock Invoke-DbHubArm {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body; At = $script:clock })
            return (Invoke-TestAzure -Method $Method -Path $Path -Body $Body)
        }
        function Get-TestWrite {
            @($script:calls | Where-Object Method -NE 'GET')
        }
    }

    It 'deallocates the running VMs and stops a running T4, through Azure Resource Manager only, and starts nothing' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        $script:t4 = 'Ready'
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.action | Should -Be 'stop-nightly'
        $result.status | Should -Be 'Stopped'
        $result.message | Should -Be 'Nightly safety stop: sqlvm01 deallocated (was running), archost01 deallocated (was running), T4 stopped (was Ready).'
        @($result.failed) | Should -BeNullOrEmpty
        $result.vms['sqlvm01'] | Should -Be 'deallocated (was running)'
        $result.t4 | Should -Be 'T4 stopped (was Ready)'
        @(Get-TestWrite | ForEach-Object { '{0} {1}' -f $_.Method, ($_.Path -replace '^.*/providers/', '') }) | Should -Be @('POST Microsoft.Compute/virtualMachines/sqlvm01/deallocate', 'POST Microsoft.Compute/virtualMachines/archost01/deallocate', 'POST Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123/stop')
        @($script:calls | Where-Object { $_.Path -match '/start$|/runCommands|/schedules|/jobSchedules|/jobs' }) | Should -BeNullOrEmpty
    }

    It 'leaves VMs that are deallocated or deallocating, and a T4 that''s stopped or stopping, alone' -ForEach @(
        @{ Sql = 'deallocated'; HostVm = 'deallocating'; T4 = 'Stopped'; Text = 'sqlvm01 already deallocated, archost01 already deallocating, T4 already stopped' }
        @{ Sql = 'deallocated'; HostVm = 'deallocated'; T4 = 'Stopping'; Text = 'sqlvm01 already deallocated, archost01 already deallocated, T4 already stopping' }
        @{ Sql = 'deallocated'; HostVm = 'deallocated'; T4 = ''; Text = 'sqlvm01 already deallocated, archost01 already deallocated, T4 missing' }
    ) {
        $script:vm = @{ sqlvm01 = $Sql; archost01 = $HostVm }
        $script:t4 = $T4
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.message | Should -Be ('Nightly safety stop: {0}.' -f $Text)
        Get-TestWrite | Should -BeNullOrEmpty
    }

    It 'deallocates a VM stopped from inside its guest, which still bills its compute' {
        $script:vm = @{ sqlvm01 = 'stopped'; archost01 = 'deallocated' }
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.vms['sqlvm01'] | Should -Be 'deallocated (was stopped)'
        @($script:calls | Where-Object { $_.Path -match '/sqlvm01/deallocate$' }).Count | Should -Be 1
    }

    It 'counts a VM its auto-shutdown is deallocating already (409 Conflict) as done, without trying again' {
        # The DevTest Labs auto-shutdown runs at the same minute: Azure refuses a second operation while it runs.
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $script:deallocateStatus['sqlvm01'] = 409
        $script:conflictState['sqlvm01'] = 'deallocating'
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.vms['sqlvm01'] | Should -Be 'already deallocating (its auto-shutdown)'
        @($script:calls | Where-Object { $_.Path -match '/sqlvm01/deallocate$' }).Count | Should -Be 1
    }

    It 'tries a VM again after a 409 while another operation holds it, and reports it when it never takes' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $script:deallocateStatus['sqlvm01'] = 409
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Partial'
        $result.message | Should -Match 'failed: sqlvm01 \(HTTP 409\)\.$'
        @($script:calls | Where-Object { $_.Path -match '/sqlvm01/deallocate$' }).Count | Should -Be 3
        # Its attempts were 30 seconds apart: the fake clock moved twice.
        ($script:clock - [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc)).TotalSeconds | Should -Be 60
        @($script:calls | Where-Object { $_.Path -match '/start$' }) | Should -BeNullOrEmpty
    }

    It 'waits for a T4 that''s starting (its 7-day restart), then stops it once it''s Ready' {
        $script:t4 = 'Starting'
        $script:t4ReadyAt = $script:clock.AddMinutes(4)
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.t4 | Should -Be 'T4 stopped (was Starting)'
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/stop$' }).Count | Should -Be 1
        $stop = @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/stop$' })[0]
        $stop.At | Should -BeGreaterOrEqual $script:t4ReadyAt
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/start$' }) | Should -BeNullOrEmpty
    }

    It 'gives up on a T4 that''s still starting after 10 minutes, says so, and never starts it' {
        $script:t4 = 'Starting'
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Partial'
        $result.t4 | Should -Match '^failed: it was still Starting after 10 minutes; tomorrow''s safety stop tries again$'
        ($script:clock - [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc)).TotalMinutes | Should -BeLessOrEqual 11
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/(start|stop)$' }) | Should -BeNullOrEmpty
    }

    It 'stops a read replica a session left behind once T4 is stopped (Azure''s order), and says so plainly with the fix (ADR 0025)' {
        $script:t4 = 'Ready'
        $script:t4StopMinutes = 2
        $script:replica = 'Ready'
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.replica | Should -Be 'T4''s read replica pgreplica01-abc123 stopped (a session left it behind without stop-demo.ps1; stopped it still bills its storage and Defender plans until ./scripts/stop-demo.ps1 deletes it)'
        $result.message | Should -Match 'T4 stopped \(was Ready\), T4''s read replica pgreplica01-abc123 stopped \(a session left it behind'
        @(Get-TestWrite | ForEach-Object { '{0} {1}' -f $_.Method, ($_.Path -replace '^.*/providers/', '') }) | Should -Be @('POST Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123/stop', 'POST Microsoft.DBforPostgreSQL/flexibleServers/pgreplica01-abc123/stop')
        @(Get-TestWrite)[1].At | Should -BeGreaterOrEqual $script:t4StoppedAt -Because 'Azure stops a replica only after its primary'
        @($script:calls | Where-Object { $_.Path -match '/start$' }) | Should -BeNullOrEmpty
        # It never deletes the replica: the safety stop's role can't, and stop-demo.ps1 does.
        @($script:calls | Where-Object { $_.Method -eq 'DELETE' }) | Should -BeNullOrEmpty
    }

    It 'leaves a stopped replica alone, and says how to delete it; says nothing when there''s none' {
        $script:t4 = 'Stopped'
        $script:replica = 'Stopped'
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.message | Should -Be 'Nightly safety stop: sqlvm01 already deallocated, archost01 already deallocated, T4 already stopped, T4''s read replica pgreplica01-abc123 already stopped (a session left it behind; ./scripts/stop-demo.ps1 deletes it).'
        Get-TestWrite | Should -BeNullOrEmpty
        $script:calls.Clear()
        $script:replica = ''
        (Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)).message | Should -Be 'Nightly safety stop: sqlvm01 already deallocated, archost01 already deallocated, T4 already stopped.'
    }

    It 'reports a left-over replica it couldn''t stop, without waiting, when T4''s own stop failed' {
        $script:t4 = 'Ready'
        $script:t4ActionStatus = 409
        $script:replica = 'Ready'
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Partial'
        @($result.failed) -join ' | ' | Should -Match 'T4''s read replica pgreplica01-abc123 \(a session left it behind\) not stopped: T4 wasn''t stopped, and Azure stops a read replica only after its primary; \./scripts/stop-demo\.ps1 deletes it'
        @($script:calls | Where-Object { $_.Path -match '/pgreplica01-abc123/stop$' }) | Should -BeNullOrEmpty
    }

    It 'the T3 check and the control''s daily T4 stop stop a left-over replica after T4 too (ADR 0025)' {
        $script:t4 = 'Ready'
        $script:t4StopMinutes = 2
        $script:replica = 'Ready'
        $now = [datetime]::new(2026, 10, 27, 23, 30, 0, [System.DateTimeKind]::Utc)
        $check = Invoke-DbHubStop -Scope T3Check -Context (New-TestContext -NowUtc $now)
        $check.replica | Should -Match '^T4''s read replica pgreplica01-abc123 stopped'
        $check.message | Should -Match 'T4 stopped \(was Ready\); T4''s read replica pgreplica01-abc123 stopped'
        $script:replica | Should -Be 'Stopping'
        Reset-TestAzure
        $script:t4 = 'Ready'
        $script:t4StopMinutes = 2
        $script:replica = 'Ready'
        $daily = Invoke-DbHubStop -Scope T4 -Context (New-TestContext)
        $daily.status | Should -Be 'Stopped'
        $daily.message | Should -Match '^T4 \(pgflex01-abc123\) was Ready; its stop was accepted\. T4''s read replica pgreplica01-abc123 stopped'
        $script:replica | Should -Be 'Stopping'
    }

    It 'says <Status>, and changes nothing, when the demo resource group <Name>' -ForEach @(
        @{ Name = 'can''t be read: the role isn''t assigned'; Code = 403; Status = 'NotGranted'; Match = 'role "DbHub Demo Safety Stop" isn''t assigned there yet \(an Owner runs \./scripts/grant-safety-stop\.ps1\)' }
        @{ Name = 'doesn''t answer'; Code = 500; Status = 'Partial'; Match = 'couldn''t be read' }
        @{ Name = 'doesn''t exist'; Code = 404; Status = 'NoEnvironment'; Match = 'Missing; nothing was stopped' }
    ) {
        $script:group = $Code
        foreach ($scope in 'Nightly', 'T3Check') {
            $script:calls.Clear()
            $result = Invoke-DbHubStop -Scope $scope -Context (New-TestContext)
            $result.status | Should -Be $Status
            $result.message | Should -Match $Match
            Get-TestWrite | Should -BeNullOrEmpty
        }
    }

    Context 'the busy marker (2026-11-14): a deploy.ps1 run or a session that''s still going isn''t cut off' {
        It 'changes nothing while the marker is ahead (<By>), for the stop, its T3 check, and the control''s daily T4 stop, and completes' -ForEach @(
            @{ By = 'deploy'; Who = 'deploy\.ps1 is still running' }
            @{ By = 'deploy-grace'; Who = 'deploy\.ps1 finished after the nightly stop, and its grace period runs' }
            @{ By = 'session'; Who = 'a demo session is running' }
        ) {
            # Live, 2026-11-13: the 19:00 stop and the 19:30 check stopped T4 and its replica under a running deploy.ps1.
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
            $script:t4 = 'Ready'
            $script:replica = 'Ready'
            $script:groupTags = @{ DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = $By }
            foreach ($scope in 'Nightly', 'T3Check', 'T4') {
                $script:calls.Clear()
                $result = Invoke-DbHubStop -Scope $scope -Context (New-TestContext)
                $result.status | Should -Be 'Deferred'
                $result.message | Should -Match ('^Deferred: {0} \(busy until 2026-10-27T15:45:00Z\), so nothing was stopped now\.' -f $Who)
                $result.busyUntil | Should -Be '2026-10-27T15:45:00Z'
                $result.busyBy | Should -Be $By
                Get-TestWrite | Should -BeNullOrEmpty
                @($script:calls | Where-Object { $_.Path -match '/virtualMachines/|/flexibleServers/|/databases/' }) | Should -BeNullOrEmpty -Because 'it reads nothing else either'
            }
            # The T3 check's verdict says so too, so status.ps1 doesn't take it as an unread T3 (Get-DemoSafetyStopStatus).
            (Invoke-DbHubStop -Scope T3Check -Context (New-TestContext)).t3 | Should -Be 'Deferred'
            (Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)).action | Should -Be 'stop-nightly'
        }

        It 'stops as usual once the marker has expired, and ignores one further ahead than 3 hours, or one that isn''t a time' -ForEach @(
            @{ Name = 'expired'; Until = '2026-10-27T14:59:59Z'; Logged = '' }
            @{ Name = 'too far ahead'; Until = '2026-10-27T18:00:01Z'; Logged = 'further ahead than a run refreshes it' }
            @{ Name = 'not a time'; Until = 'soon'; Logged = 'not a time' }
        ) {
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
            $script:t4 = 'Ready'
            $script:groupTags = @{ DbHubBusyUntilUtc = $Until; DbHubBusyBy = 'deploy' }
            $context = New-TestContext
            $result = Invoke-DbHubStop -Scope Nightly -Context $context
            $result.status | Should -Be 'Stopped'
            @($script:calls | Where-Object { $_.Path -match '/sqlvm01/deallocate$' }).Count | Should -Be 1
            @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/stop$' }).Count | Should -Be 1
            if ($Logged) {
                @($context.Log | Where-Object { $_ -match 'The busy marker .* was ignored' -and $_ -match [regex]::Escape($Logged) }).Count | Should -Be 1
            }
        }

        It 'counts a marker exactly 3 hours ahead, the most a refresh can set' {
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
            $script:groupTags = @{ DbHubBusyUntilUtc = '2026-10-27T18:00:00Z'; DbHubBusyBy = 'deploy' }
            (Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)).status | Should -Be 'Deferred'
            Get-TestWrite | Should -BeNullOrEmpty
        }

        It 'never defers the per-run auto-stop (Scope All): it''s a session''s own end' {
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
            $script:groupTags = @{ DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'session' }
            $result = Invoke-DbHubStop -Scope All -Context (New-TestContext)
            $result.status | Should -Be 'Stopped'
            @($script:calls | Where-Object { $_.Path -match '/sqlvm01/deallocate$' }).Count | Should -Be 1
        }

        It 'DbHub-Stop completes a Deferred job: only Error, Partial, and NotGranted fail it' {
            $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHub-Stop.ps1') -Raw
            $text | Should -Match ([regex]::Escape("[string]`$result.status -in 'Partial', 'NotGranted'"))
            $text | Should -Not -Match 'Deferred.*throw'
        }
    }

    It 'the T3 check reads T3''s status through Azure Resource Manager only and says what it found: <Case>' -ForEach @(
        @{ Case = 'paused'; Code = 200; Status = 'Paused'; Delay = 15; Minutes = 30; Verdict = 'Paused'; Job = 'Checked'; Match = 'is Paused, 30 minutes after the safety stop: it bills no compute' }
        @{ Case = 'pausing'; Code = 200; Status = 'Pausing'; Delay = 15; Minutes = 30; Verdict = 'Pausing'; Job = 'Checked'; Match = 'its auto-pause has begun' }
        @{ Case = 'online past its delay'; Code = 200; Status = 'Online'; Delay = 15; Minutes = 30; Verdict = 'Awake'; Job = 'Checked'; Match = 'past its 15-minute auto-pause delay: a session or a feature keeps it awake\. The activity log''s Resume Databases events name what resumed it\. T4 missing\.$' }
        @{ Case = 'online before its delay'; Code = 200; Status = 'Online'; Delay = 60; Minutes = 30; Verdict = 'TooEarly'; Job = 'Checked'; Match = 'its 60-minute auto-pause delay, plus 10 minutes, hasn''t passed yet' }
        @{ Case = 'auto-pause off'; Code = 200; Status = 'Online'; Delay = -1; Minutes = 30; Verdict = 'AutoPauseOff'; Job = 'Checked'; Match = 'its auto-pause is off \(delay -1\)' }
        @{ Case = 'removed'; Code = 404; Status = ''; Delay = 15; Minutes = 30; Verdict = 'Missing'; Job = 'Checked'; Match = 'doesn''t exist \(stop-demo\.ps1 -RemoveT3 removed it' }
        @{ Case = 'unread'; Code = 500; Status = ''; Delay = 15; Minutes = 30; Verdict = 'Unread'; Job = 'Partial'; Match = 'couldn''t be read' }
    ) {
        $script:t3 = $Code
        $script:t3Status = $Status
        $script:t3Delay = $Delay
        # The tests' auto-shutdown is 19:00 Eastern: 23:00 UTC on 2026-10-27 (daylight saving time).
        $now = [datetime]::new(2026, 10, 27, 23, 0, 0, [System.DateTimeKind]::Utc).AddMinutes($Minutes)
        $result = Invoke-DbHubStop -Scope T3Check -Context (New-TestContext -NowUtc $now)
        $result.action | Should -Be 'check-t3'
        $result.status | Should -Be $Job
        $result.t3 | Should -Be $Verdict
        $result.minutesSinceStop | Should -Be $Minutes
        $result.message | Should -Match $Match
        # No T4 is deployed here: the check reads it, and says so.
        $result.t4 | Should -Be 'T4 missing'
        $result.message | Should -Match ' T4 missing\.$'
        Get-TestWrite | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Path -notmatch '/resourceGroups/rg-dbhub-demo$' } | ForEach-Object { $_.Path -replace '^.*/providers/', '' }) | Should -Be @('Microsoft.Sql/servers/azuresql01-abc123/databases/ContosoCare', 'Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123', 'Microsoft.DBforPostgreSQL/flexibleServers/pgreplica01-abc123')
        $result.replica | Should -BeNullOrEmpty -Because 'between sessions there''s no replica, and nothing to say about it'
    }

    It 'the T3 check stops a T4 that runs, after reading T3, through Azure Resource Manager only, and starts nothing (2026-11-09)' {
        # Azure started T4 again just after the evening's stop (its 7-day restart): the T3 check stops it that evening.
        $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'deallocated' }
        $script:t4 = 'Ready'
        $now = [datetime]::new(2026, 10, 27, 23, 30, 0, [System.DateTimeKind]::Utc)
        $result = Invoke-DbHubStop -Scope T3Check -Context (New-TestContext -NowUtc $now)
        $result.action | Should -Be 'check-t3'
        $result.status | Should -Be 'Checked'
        $result.t3 | Should -Be 'Paused'
        $result.t4 | Should -Be 'T4 stopped (was Ready)'
        @($result.failed) | Should -BeNullOrEmpty
        $result.message | Should -Be 'T3 (azuresql01-abc123/ContosoCare) is Paused, 30 minutes after the safety stop: it bills no compute until something connects. T4 stopped (was Ready).'
        @(Get-TestWrite | ForEach-Object { '{0} {1}' -f $_.Method, ($_.Path -replace '^.*/providers/', '') }) | Should -Be @('POST Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123/stop')
        # T3 is only read (Databases - Get), before T4; nothing starts, and no VM, schedule, or job is touched.
        @($script:calls | Where-Object { $_.Path -match '/servers/azuresql01-abc123/' } | ForEach-Object Method | Select-Object -Unique) | Should -Be @('GET')
        $t3Read = [array]::IndexOf(@($script:calls | ForEach-Object Path), @($script:calls | Where-Object { $_.Path -match '/databases/ContosoCare$' })[0].Path)
        $t4Read = [array]::IndexOf(@($script:calls | ForEach-Object Path), @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123$' })[0].Path)
        $t3Read | Should -BeLessThan $t4Read
        @($script:calls | Where-Object { $_.Path -match '/start$|/deallocate$|/virtualMachines/|/runCommands|/schedules|/jobSchedules|/jobs' }) | Should -BeNullOrEmpty
    }

    It 'the T3 check waits for a T4 that''s starting, then stops it once it''s Ready, and never starts it' {
        $script:t4 = 'Starting'
        $script:t4ReadyAt = $script:clock.AddMinutes(3)
        $result = Invoke-DbHubStop -Scope T3Check -Context (New-TestContext -NowUtc ([datetime]::new(2026, 10, 27, 23, 30, 0, [System.DateTimeKind]::Utc)))
        $result.status | Should -Be 'Checked'
        $result.t4 | Should -Be 'T4 stopped (was Starting)'
        $stop = @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/stop$' })
        $stop.Count | Should -Be 1
        $stop[0].At | Should -BeGreaterOrEqual $script:t4ReadyAt
        @($script:calls | Where-Object { $_.Path -match '/start$' }) | Should -BeNullOrEmpty
    }

    It 'the T3 check leaves a T4 that''s <State> alone and says so' -ForEach @(
        @{ State = 'Stopped'; Text = 'T4 already stopped' }
        @{ State = 'Stopping'; Text = 'T4 already stopping' }
        @{ State = 'Disabled'; Text = 'T4 disabled' }
    ) {
        $script:t4 = $State
        $result = Invoke-DbHubStop -Scope T3Check -Context (New-TestContext -NowUtc ([datetime]::new(2026, 10, 27, 23, 30, 0, [System.DateTimeKind]::Utc)))
        $result.status | Should -Be 'Checked'
        $result.t4 | Should -Be $Text
        $result.message | Should -Match ([regex]::Escape(' {0}.' -f $Text) + '$')
        Get-TestWrite | Should -BeNullOrEmpty
    }

    It 'the T3 check reports a T4 it couldn''t stop as Partial, so its job fails, and never starts it' {
        $script:t4 = 'Starting'
        $result = Invoke-DbHubStop -Scope T3Check -Context (New-TestContext -NowUtc ([datetime]::new(2026, 10, 27, 23, 30, 0, [System.DateTimeKind]::Utc)))
        $result.status | Should -Be 'Partial'
        $result.t3 | Should -Be 'Paused'
        $result.t4 | Should -Be 'failed: it was still Starting after 10 minutes; tomorrow''s safety stop tries again'
        @($result.failed) | Should -Be @('T4 (it was still Starting after 10 minutes; tomorrow''s safety stop tries again)')
        $result.message | Should -Match 'it bills no compute until something connects\. T4 couldn''t be stopped: it was still Starting after 10 minutes; tomorrow''s safety stop tries again\.$'
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/(start|stop)$' }) | Should -BeNullOrEmpty
        # The result line as DbHub-Stop writes it, in the JSON status.ps1 reads.
        $line = $result | ConvertTo-Json -Depth 6 -Compress
        ($line | ConvertFrom-Json).failed.Count | Should -Be 1
    }

    It 'counts the minutes since the latest scheduled shutdown, across midnight and in winter time' {
        $settings = $script:settings
        # 2026-11-03 01:15 UTC is 2026-11-02 20:15 Eastern Standard Time: the stop was at 19:00, 75 minutes earlier.
        (Get-DbHubLastShutdownUtc -Settings $settings -NowUtc ([datetime]::new(2026, 11, 3, 1, 15, 0, [System.DateTimeKind]::Utc))) | Should -Be ([datetime]::new(2026, 11, 3, 0, 0, 0, [System.DateTimeKind]::Utc))
        # Before that day's 19:00, the latest is the day before's.
        (Get-DbHubLastShutdownUtc -Settings $settings -NowUtc ([datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc))) | Should -Be ([datetime]::new(2026, 10, 26, 23, 0, 0, [System.DateTimeKind]::Utc))
    }
    It 'DbHub-Stop takes the Nightly and T3Check scopes, and its safety stop settings pass the shared checks and assemble into a script that parses' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHub-Stop.ps1'), [ref]$null, [ref]$null)
        $scope = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Scope' })[0]
        $set = @($scope.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })[0]
        @($set.PositionalArguments | ForEach-Object { $_.Value }) | Should -Be @('All', 'T4', 'Nightly', 'T3Check')
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHub-Stop.ps1') -Raw
        # A Nightly or T3Check job that couldn't do its work fails after its result line, so the job history shows it.
        $text | Should -Match ([regex]::Escape("`$Scope -in 'Nightly', 'T3Check' -and [string]`$result.status -in 'Partial', 'NotGranted'"))
        $json = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $script:config } {
            $name = Get-DemoSafetyStopName -Config $Config
            ConvertTo-Json -InputObject (Get-DemoSafetyStopRunbookSetting -Config $Config -Name $name -IdentityClientId '99999999-9999-9999-9999-999999999999') -Depth 16 -Compress
        }
        $settings = ConvertFrom-DbHubSetting -Json $json
        $settings.purpose | Should -Be 'safety-stop'
        $settings.automationAccount | Should -Be 'aa-dbhub-demo-safetystop'
        $settings.controlResourceGroup | Should -Be 'rg-dbhub-demo'
        $settings.identityClientId | Should -Be '99999999-9999-9999-9999-999999999999'
        $settings.t4WaitMinutes | Should -Be 10
        $content = InModuleScope -ModuleName DbHubDemo -Parameters @{ Json = $json } { Get-DemoActivityControlRunbookContent -Name 'DbHub-Stop' -Setting ($Json | ConvertFrom-Json -AsHashtable) }
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $content | Should -Match '"purpose":"safety-stop"'
        [regex]::Matches($content, '[^\x00-\x7F]').Count | Should -Be 0
    }
}
Describe 'T1''s monitoring plugin status: when it was reported, and whether it''s fresh (live, 2026-11-04)' {
    It 'reads MainServiceLastReportedTime from <Case>' -ForEach @(
        @{ Case = 'the agent''s health report'; Message = @('{"ExtensionServiceHealthReport":{"MainServiceStatus":"Running","MainServiceLastReportedTime":"2026-11-04T14:46:32Z"}}'); Expected = '2026-11-04T14:46:32' }
        @{ Case = 'escaped JSON with fractions and an offset'; Message = @('{\"ExtensionServiceHealthReport\":{\"MainServiceLastReportedTime\":\"2026-11-04T15:46:32.1234567+01:00\"}}'); Expected = '2026-11-04T14:46:32' }
        @{ Case = 'a time without a zone, which is UTC'; Message = @('MainServiceLastReportedTime: 2026-11-04 14:46:32'); Expected = '2026-11-04T14:46:32' }
        @{ Case = 'two messages, the latest of them'; Message = @('"MainServiceLastReportedTime":"2026-11-04T14:20:00Z"', 'SQL Server IaaS Agent: Healthy', '"MainServiceLastReportedTime":"2026-11-04T14:46:32Z"'); Expected = '2026-11-04T14:46:32' }
    ) {
        $time = Get-DbHubPluginReportedUtc -Message $Message
        $time.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) | Should -Be $Expected
        $time.Kind | Should -Be 'Utc'
    }

    It 'has no time when no message holds one' {
        Get-DbHubPluginReportedUtc -Message @('SQL Server IaaS Agent: Healthy;DatabaseMonitorArcPlugin: {"State":"Running"}', '') | Should -BeNullOrEmpty
        Get-DbHubPluginReportedUtc -Message @('"MainServiceLastReportedTime":"not a time"') | Should -BeNullOrEmpty
    }

    It 'is fresh <Case>' -ForEach @(
        @{ Case = 'when there''s no start to compare with'; Reported = $null; Since = $null; Expected = $true }
        @{ Case = 'when reported after the start'; Reported = [datetime]::new(2026, 11, 4, 14, 46, 32, [System.DateTimeKind]::Utc); Since = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Expected = $true }
        @{ Case = 'not when reported before the start (the stale Running of 2026-11-04)'; Reported = [datetime]::new(2026, 11, 3, 23, 10, 0, [System.DateTimeKind]::Utc); Since = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Expected = $false }
        @{ Case = 'not when reported at the start itself'; Reported = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Since = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Expected = $false }
        @{ Case = 'not without a time, 12 minutes after the start'; Reported = $null; Since = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Expected = $false }
        @{ Case = 'without a time, more than 30 minutes after the start'; Reported = $null; Since = [datetime]::new(2026, 11, 4, 14, 16, 0, [System.DateTimeKind]::Utc); Expected = $true }
    ) {
        $plugin = [pscustomobject]@{ State = 'Running'; ReportedUtc = $Reported }
        Test-DbHubPluginFresh -Plugin $plugin -SinceUtc $Since -NowUtc ([datetime]::new(2026, 11, 4, 14, 46, 51, [System.DateTimeKind]::Utc)) | Should -Be $Expected
        # The module's check before a start-demo.ps1 or deploy.ps1 run is the same rule.
        InModuleScope -ModuleName DbHubDemo -Parameters @{ Plugin = $plugin; Since = $Since } { Test-DemoSqlVmPluginFresh -Plugin $Plugin -SinceUtc $Since -NowUtc ([datetime]::new(2026, 11, 4, 14, 46, 51, [System.DateTimeKind]::Utc)) } | Should -Be $Expected
    }
}

Describe 'DbHub-Monitor (Invoke-DbHubMonitor) against a mocked Azure Resource Manager' {
    BeforeEach {
        Reset-TestAzure
        Mock Get-DbHubUtcNow { return $script:clock }
        Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
        Mock Invoke-DbHubArm {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body; At = $script:clock })
            return (Invoke-TestAzure -Method $Method -Path $Path -Body $Body)
        }
    }

    It 'does nothing <Case>' -ForEach @(
        @{ Case = 'once the run has ended (no auto-stop is pending)'; Setup = { $script:vm['sqlvm01'] = 'running' } }
        @{ Case = 'when the run''s auto-stop time has passed'; Setup = { $script:vm['sqlvm01'] = 'running'; $script:autostop = '2026-10-27T15:05:00Z' } }
        @{ Case = 'while sqlvm01 doesn''t run'; Setup = { $script:autostop = '2026-10-27T16:40:00Z' } }
    ) {
        $script:plugin = 'NotRunning'
        & $Setup
        $result = Invoke-DbHubMonitor -Context (New-TestContext)
        $result.status | Should -Be 'Skipped'
        @($script:calls | Where-Object { $_.Method -ne 'GET' -or $_.Path -match '/extensions/' }) | Should -BeNullOrEmpty
    }

    It 'restarts the plugin''s agent during a run when the plugin has stopped, and starts or stops nothing' {
        $script:vm['sqlvm01'] = 'running'
        $script:autostop = '2026-10-27T16:40:00Z'
        $script:plugin = { if ($null -ne $script:restartedAt) { 'Running' } else { 'NotRunning' } }
        $result = Invoke-DbHubMonitor -Context (New-TestContext)
        $result.status | Should -Be 'Checked'
        $result.monitoring | Should -Be 'Restarted'
        $writes = @($script:calls | Where-Object Method -NE 'GET')
        $writes.Count | Should -Be 1
        $writes[0].Path | Should -Match '/sqlvm01/runCommands/DbHubControl-monitoring-20261027150000$'
        $writes[0].Body.properties.source.script | Should -Match "Restart-Service -Name 'SQLIaaSExtension'"
    }

    It 'leaves a running plugin alone' {
        $script:vm['sqlvm01'] = 'running'
        $script:autostop = '2026-10-27T16:40:00Z'
        $result = Invoke-DbHubMonitor -Context (New-TestContext)
        $result.monitoring | Should -Be 'Running'
        @($script:calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
    }

    It 'reports a plugin that still doesn''t run after the restart, within its bound' {
        $script:vm['sqlvm01'] = 'running'
        $script:autostop = '2026-10-27T16:40:00Z'
        $script:plugin = 'NotRunning'
        $start = $script:clock
        $result = Invoke-DbHubMonitor -Context (New-TestContext)
        $result.status | Should -Be 'Partial'
        $result.monitoring | Should -Be 'StillNotRunning'
        $result.message | Should -Match 'start-demo\.ps1'
        ($script:clock - $start).TotalMinutes | Should -BeLessThan 11
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
    It '<_> is self-contained: settings and the shared code in place of its markers, ASCII, and it parses' -ForEach @('DbHub-Control', 'DbHub-Stop', 'DbHub-Monitor') {
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
