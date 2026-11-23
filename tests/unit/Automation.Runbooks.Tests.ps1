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
        $script:autostopDescription = ''
        $script:backupDescription = ''
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
        # VMs whose Run Commands Azure refuses (HTTP 400), by name (#27).
        $script:runCommandRefused = @()
        $script:t4ActionStatus = 202
        # T4's read replica (ADR 0025): its state ('' for none, as between sessions), and the minutes T4's stop and the
        # replica's start take in this fake; without them, T4 stays Stopping and the replica Starting.
        $script:replica = ''
        $script:replicaStartMinutes = $null
        $script:replicaReadyAt = $null
        $script:t4StopMinutes = $null
        # Stops that Azure accepts and then fails, leaving T4 Ready (SourceReplicasStartStopOrder after a replica's delete).
        $script:t4StopIgnored = 0
        $script:t4StoppedAt = $null
        # Run Commands listed on a VM, by VM name; without an entry, the earlier run's DbHubControl-<vm>-20261026000000
        # and someone else's DbHubDemo-Other, without instance views.
        $script:runCommands = @{}
        # The control session (2026-11-14, ADR 0026): the replica's creation (sizes Azure refuses, how many times T4 isn't
        # ready for it, whether the identity may, and the minutes it takes), its deletion, its parameter, the second
        # auto-stop, the control vault's secrets as the runbook writes them, and whether the group's tags can be written.
        $script:replicaRefuse = @()
        $script:replicaNotReady = 0
        $script:replicaForbidden = $false
        $script:replicaCreateMinutes = 9
        $script:replicaSku = ''
        $script:replicaRole = 'AsyncReplica'
        $script:replicaGoneAt = $null
        $script:replicaDeleteForbidden = $false
        $script:replicaParameter = ''
        $script:backup = ''
        $script:secrets = @{}
        $script:secretsForbidden = $false
        $script:tagsForbidden = $false
        # The session's hosts (2026-11-16): a VM's failed provisioning (Code and Time, by VM name), a Run Command's instance
        # view (by its name), and the control account's variables as Set-AutomationVariable and Get-AutomationVariable see
        # them, with a variable that doesn't exist, a count of the reads, and a script block each read runs first.
        $script:vmFailed = @{}
        # A VM's agent as its instance view reports it, by VM name: 'Ready' unless set ('' for no status at all, as during
        # a start whose goal state never arrives; live, 2026-11-17).
        $script:vmAgent = @{}
        $script:runCommandViews = @{}
        $script:automationVariables = @{}
        $script:variableMissing = $false
        $script:variableReads = 0
        $script:variableReadHook = $null
        # T5's Azure Cosmos DB account (2026-11-18, ADR 0027): $null when it isn't there (its metrics answer 404, as between
        # deployments without T5), or a hashtable when it is.
        $script:cosmos = $null
        # T5's container (2026-11-19, ADR 0027): Present (by default, as an environment deployed before its lifecycle),
        # '' when it's gone, or Creating or Deleting until t5ContainerAt; the methods Azure refuses the identity (403); how many
        # creates Azure refuses first with a conflict (it still deletes the last one); how many seconds a create and a delete
        # take; and the last create's body.
        $script:t5Container = 'Present'
        $script:t5ContainerAt = $null
        $script:t5ContainerForbidden = @()
        $script:t5ContainerConflicts = 0
        $script:t5ContainerCreateSeconds = 30
        $script:t5ContainerDeleteSeconds = 20
        $script:t5ContainerBody = $null
        # The Incident RCA's export (2026-11-20, ADR 0031): each Rca Run Command sent (its VM, name, decoded request, and
        # time), the ones deleted, and what the VM-side control answers, a script block given the command: an instance
        # view, or $null while it runs. By default the runner has nothing to export, as a runner with no capture.
        $script:rcaCommands = [System.Collections.Generic.List[object]]::new()
        $script:rcaDeleted = [System.Collections.Generic.List[string]]::new()
        $script:rcaRunner = { New-TestRcaView -Status 'Not selected' -Message 'runner rca export: nothing was captured since the last export.' }
        # The Query Store sidecar's Run Commands (2026-11-23): RcaSidecarExport, RcaAck, and a sidecar's parts. By default the
        # runner offers none (exit code 2), takes any acknowledgement, and has no part.
        $script:rcaSidecarRunner = {
            param($Command)
            switch ([string]$Command.Request.command) {
                'sidecar-export' { New-TestRcaView -Action 'RcaSidecarExport' -Status 'Not selected' -Message 'runner rca sidecar-export: there is no sidecar to fetch.' -Line 'DBHUBDEMO-RCAS-INDEX {"kind":"ContosoCare.RcaSidecarIndex","version":1,"page":1,"pages":0,"documents":[],"status":"Not selected","message":"Nothing to fetch: no sidecar here is new or waiting for an acknowledgement."}' -Evidence @{ exitCode = 2 } }
                'ack' { New-TestRcaView -Action 'RcaAck' -Status 'Pass' -Message 'runner rca ack: its line follows.' -Evidence @{ exitCode = 0 } }
                default { New-TestRcaView -Status 'Fail' -Message 'runner rca part: exit code 1. The document or part doesn''t exist.' -Evidence @{ exitCode = 1 } }
            }
        }
        # How many reads a deleted Rca Run Command stays listed for, by VM (Azure's deletes take a while; R871), and the reads
        # left for each one being deleted. By default a delete is done at once.
        $script:rcaDeleteDelay = @{}
        $script:rcaDeleteReads = @{}
        # The most Rca Run Commands a VM listed at once, a deleting one included, by VM.
        $script:rcaMostOpen = @{}
        # Whether a VM's list of Run Commands has its Rca ones too, with their instance views, as Azure lists them (review
        # of 93243d6). Off by default, so the other tests count only the Run Commands they set.
        $script:rcaListOpen = $false
        # Key Vault versions of the secrets the runbook writes, counted (Secrets - Create Or Update returns secretUriWithVersion).
        $script:secretVersions = 0
        # A script block each secret write runs first, given the secret's name and the request's body (review of 15ad76d).
        $script:secretWriteHook = $null
    }

    # An Rca Run Command's instance view (Invoke-DemoControlRca): its result line, then the runner's own line, if any. -Action
    # names the Query Store sidecar's actions (RcaSidecarExport, RcaAck; 2026-11-23) in the result line, as theirs do.
    function New-TestRcaView([string] $Status, [string] $Message = '', [string] $Line = '', [hashtable] $Evidence = @{}, [string] $Action = 'Rca') {
        $result = [ordered]@{ marker = 'DBHUBDEMO-WORKLOAD'; action = $Action; status = $Status; message = $Message; evidence = $Evidence }
        $output = 'DBHUBDEMO-WORKLOAD ' + (ConvertTo-Json -InputObject $result -Depth 4 -Compress)
        if ($Line) {
            $output = $output + "`n" + $Line
        }
        return @{ executionState = 'Succeeded'; exitCode = 0; output = $output }
    }

    # The request in an Rca Run Command's script (Get-DbHubRcaScript), decoded. A sidecar action's request gets the runner
    # command it runs as its command (sidecar-export, ack), and an empty documentId and part, so a filter on the evidence's
    # requests reads every request alike in strict mode.
    function ConvertFrom-TestRcaScript([string] $Script) {
        if ($Script -notmatch "-RequestBase64 '([A-Za-z0-9+/=]+)'") {
            return $null
        }
        $request = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Matches[1])) | ConvertFrom-Json
        $command = @{ RcaSidecarExport = 'sidecar-export'; RcaAck = 'ack' }[(Get-TestRcaAction -Script $Script)]
        if ($command) {
            $request | Add-Member -NotePropertyName 'command' -NotePropertyValue $command -Force
            foreach ($name in 'documentId', 'part') {
                if ($null -eq $request.PSObject.Properties[$name]) {
                    $request | Add-Member -NotePropertyName $name -NotePropertyValue $(if ($name -eq 'part') { 0 } else { '' })
                }
            }
        }
        return $request
    }

    # The VM-side control action an Rca Run Command's script runs (Get-DbHubRcaScript -Action).
    function Get-TestRcaAction([string] $Script) {
        if ($Script -match "-Action '([A-Za-z]+)'") {
            return $Matches[1]
        }
        return ''
    }

    # Which runner answers an Rca Run Command: the Query Store sidecar's (rcaSidecarRunner) for its actions and its parts,
    # the evidence's (rcaRunner) for the rest.
    function Get-TestRcaView([object] $Command) {
        $property = $Command.Request.PSObject.Properties['documentId']
        $documentId = ''
        if ($null -ne $property) {
            $documentId = [string]$property.Value
        }
        # A command a test adds by hand, as another job's, has no action: Rca's.
        $action = 'Rca'
        if ($null -ne $Command.PSObject.Properties['Action'] -and $Command.Action) {
            $action = [string]$Command.Action
        }
        if ($action -ne 'Rca' -or $documentId.EndsWith('-sidecar')) {
            return (& $script:rcaSidecarRunner $Command)
        }
        return (& $script:rcaRunner $Command)
    }

    # The Automation sandbox's internal cmdlets for an existing variable, as the runbooks call them.
    function Set-AutomationVariable([string] $Name, [object] $Value) {
        if ($script:variableMissing) {
            throw ("Variable '{0}' was not found." -f $Name)
        }
        $script:automationVariables[$Name] = [string]$Value
    }

    function Get-AutomationVariable([string] $Name) {
        $script:variableReads++
        if ($null -ne $script:variableReadHook) {
            & $script:variableReadHook
        }
        if ($script:variableMissing) {
            throw ("Variable '{0}' was not found." -f $Name)
        }
        return $script:automationVariables[$Name]
    }

    function Get-TestVmState([string] $Name) {
        if ($script:vm[$Name] -eq 'starting' -and $script:vmRunningAt.ContainsKey($Name) -and $script:clock -ge $script:vmRunningAt[$Name]) {
            $script:vm[$Name] = 'running'
        }
        return $script:vm[$Name]
    }

    function Invoke-TestAzure([string] $Method, [string] $Path, [object] $Body) {
        switch -Regex ($Path) {
            '/databaseAccounts/cosmos01-abc123/sqlDatabases/contosocare/containers/patient-events$' {
                # T5's container (2026-11-19): Sql Resources - Get, Create Update, and Delete Sql Container.
                if ($Method -in @($script:t5ContainerForbidden)) { return (New-Response 403 ('{{"error":{{"code":"AuthorizationFailed","message":"The client does not have authorization to perform action Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/{0}."}}}}' -f @{ GET = 'read'; PUT = 'write'; DELETE = 'delete' }[$Method])) }
                if ($script:t5Container -eq 'Creating' -and $script:clock -ge $script:t5ContainerAt) { $script:t5Container = 'Present' }
                if ($script:t5Container -eq 'Deleting' -and $script:clock -ge $script:t5ContainerAt) { $script:t5Container = '' }
                if ($Method -eq 'PUT') {
                    if ($script:t5ContainerConflicts -gt 0) {
                        $script:t5ContainerConflicts--
                        return (New-Response 409 '{"error":{"code":"Conflict","message":"Operation on the resource cannot be performed because the container is being deleted."}}')
                    }
                    $script:t5ContainerBody = $Body
                    $script:t5Container = 'Creating'
                    $script:t5ContainerAt = $script:clock.AddSeconds($script:t5ContainerCreateSeconds)
                    return (New-Response 202)
                }
                if ($Method -eq 'DELETE') {
                    if (-not $script:t5Container) { return (New-Response 204) }
                    $script:t5Container = 'Deleting'
                    $script:t5ContainerAt = $script:clock.AddSeconds($script:t5ContainerDeleteSeconds)
                    return (New-Response 202)
                }
                if ($script:t5Container -in 'Present', 'Deleting') { return (New-Response 200 '{"name":"patient-events","properties":{"resource":{"id":"patient-events"}}}') }
                return (New-Response 404 '{"error":{"code":"NotFound","message":"Resource Not Found."}}')
            }
            '/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Resources/tags/default$' {
                if ($script:tagsForbidden) { return (New-Response 403 '{"error":{"code":"AuthorizationFailed","message":"The client does not have authorization to perform action Microsoft.Resources/tags/write."}}') }
                foreach ($property in $Body.properties.tags.GetEnumerator()) { $script:groupTags[[string]$property.Key] = [string]$property.Value }
                return (New-Response 200 '{}')
            }
            '/vaults/kv-dbhub-ctl-[0-9a-f]{6}/secrets/(dbhub-session-status|dbhub-session-metrics)$' {
                if ($script:secretsForbidden) { return (New-Response 403 '{"error":{"code":"AuthorizationFailed","message":"The client does not have authorization to perform action Microsoft.KeyVault/vaults/secrets/write."}}') }
                $name = $Matches[1]
                if ($null -ne $script:secretWriteHook) { & $script:secretWriteHook $name $Body }
                if (-not $script:secrets.ContainsKey($name)) { $script:secrets[$name] = [System.Collections.Generic.List[object]]::new() }
                $script:secretVersions++
                $version = '{0:x32}' -f $script:secretVersions
                $script:secrets[$name].Add([pscustomobject]@{ Value = [string]$Body.properties.value; Tags = $Body['tags']; At = $script:clock; Version = $version })
                return (New-Response 200 ('{{"name":"{0}","properties":{{"secretUri":"https://kv-test.example/secrets/{0}","secretUriWithVersion":"https://kv-test.example/secrets/{0}/{1}"}}}}' -f $name, $version))
            }
            '/databaseAccounts/cosmos01-abc123/providers/Microsoft\.Insights/metrics\?' {
                # T5's metrics (2026-11-18): three 1-minute points of each, normalized RU at 100% in the middle one, which
                # alone has throttled requests (429s), and one hourly point for the hourly reads.
                if ($null -eq $script:cosmos) { return (New-Response 404 '{"error":{"code":"ResourceNotFound","message":"The Resource ''Microsoft.DocumentDB/databaseAccounts/cosmos01-abc123'' was not found."}}') }
                $null = $Path -match 'metricnames=([^&]+)'
                $name = $Matches[1]
                $null = $Path -match 'aggregation=(\w+)'
                $field = $Matches[1].ToLowerInvariant()
                $hourly = $Path -match 'interval=PT1H'
                $throttled = $Path -match '\$filter=StatusCode%20eq%20%27429%27'
                $values = switch ($name) {
                    'NormalizedRUConsumption' { @(35, 100, 40) }
                    'TotalRequestUnits' { @(1200, 24000, 1300) }
                    'TotalRequests' { if ($throttled) { @($null, 120, $null) } else { @(600, 900, 610) } }
                    'ServerSideLatencyGateway' { @(5.25, 9.5, 5) }
                    'ProvisionedThroughput' { @(400) }
                    'ServiceAvailability' { @(100) }
                }
                $points = for ($index = 0; $index -lt @($values).Count; $index++) {
                    $at = if ($hourly) { $script:clock.Date.AddHours(15) } else { $script:clock.Date.AddHours(15).AddMinutes($index) }
                    $point = @{ timeStamp = $at.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) }
                    if ($null -ne @($values)[$index]) { $point[$field] = @($values)[$index] }
                    $point
                }
                $unit = @{ NormalizedRUConsumption = 'Percent'; ServiceAvailability = 'Percent'; ServerSideLatencyGateway = 'MilliSeconds' }[$name]
                return (New-Response 200 (ConvertTo-Json -InputObject @{ value = @(@{ name = @{ value = $name }; unit = $(if ($unit) { $unit } else { 'Count' }); timeseries = @(@{ data = @($points) }) }) } -Depth 8))
            }
            '/flexibleServers/(pgflex01|pgreplica01)-abc123/providers/Microsoft\.Insights/metrics\?' {
                # Three 1-minute points of each metric asked for; Read Replica Lag climbs to 180 seconds and drops.
                $server = $Matches[1]
                $null = $Path -match 'metricnames=([^&]+)'
                $names = $Matches[1] -split ','
                $null = $Path -match 'aggregation=(\w+)'
                $field = $Matches[1].ToLowerInvariant()
                $value = foreach ($metric in $names) {
                    $points = foreach ($index in 0..2) {
                        $number = if ($metric -eq 'physical_replication_delay_in_seconds') { @(4, 180, 6)[$index] } else { 10 + $index }
                        @{ timeStamp = $script:clock.Date.AddHours(15).AddMinutes($index).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture); $field = $number }
                    }
                    @{ name = @{ value = $metric }; unit = $(if ($metric -match 'percent') { 'Percent' } elseif ($metric -match 'seconds') { 'Seconds' } elseif ($metric -match 'bytes') { 'Bytes' } else { 'Count' }); timeseries = @(@{ data = @($points) }); server = $server }
                }
                return (New-Response 200 (ConvertTo-Json -InputObject @{ value = @($value) } -Depth 8))
            }
            '/flexibleServers/pgreplica01-abc123/configurations/max_standby_streaming_delay$' {
                $script:replicaParameter = [string]$Body.properties.value
                return (New-Response 202)
            }
            '/schedules/dbhub-autostop-backup$' {
                if ($Method -eq 'GET') {
                    if (-not $script:backup) { return (New-Response 404) }
                    return (New-Response 200 (ConvertTo-Json -InputObject @{ properties = @{ startTime = $script:backup; description = $script:backupDescription } }))
                }
                if ($Method -eq 'PUT') { $script:backup = [string]$Body.properties.startTime; $script:backupDescription = [string]$Body.properties.description; return (New-Response 201 '{}') }
                if ($Method -eq 'DELETE') { $script:backup = ''; $script:backupDescription = ''; return (New-Response 200) }
            }
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
                # Its description too (2026-11-19): start-demo.ps1's own auto-stop begins with [start-demo.ps1].
                if ($Method -eq 'GET') {
                    if (-not $script:autostop) { return (New-Response 404) }
                    return (New-Response 200 (ConvertTo-Json -InputObject @{ properties = @{ startTime = $script:autostop; description = $script:autostopDescription } }))
                }
                if ($Method -eq 'PUT') { $script:autostop = [string]$Body.properties.startTime; $script:autostopDescription = [string]$Body.properties.description; return (New-Response 201 '{}') }
                if ($Method -eq 'DELETE') { $script:autostop = ''; $script:autostopDescription = ''; return (New-Response 200) }
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
                if ($script:vmFailed.ContainsKey($name)) {
                    $provisioning = @{ code = $script:vmFailed[$name].Code; message = 'The VM didn''t start in time.'; time = $script:vmFailed[$name].Time.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [System.Globalization.CultureInfo]::InvariantCulture) }
                }
                if ($script:vmSince.ContainsKey($name)) {
                    $provisioning['time'] = $script:vmSince[$name].ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                $agent = if ($script:vmAgent.ContainsKey($name)) { [string]$script:vmAgent[$name] } else { 'Ready' }
                $agentStatuses = @()
                if ($agent) {
                    $agentStatuses = @(@{ code = 'ProvisioningState/Unavailable'; displayStatus = $agent; message = 'VM status blob is found but not yet populated.' })
                }
                return (New-Response 200 (ConvertTo-Json -InputObject @{ statuses = @($provisioning, @{ code = ('PowerState/{0}' -f (Get-TestVmState $name)) }); vmAgent = @{ vmAgentVersion = '2.7.41491.1243'; statuses = $agentStatuses } } -Depth 5))
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
            '/virtualMachines/(\w+)/runCommands/(DbHubControl-rca-[A-Za-z0-9-]+)$' {
                # The Incident RCA's export (2026-11-20): the Rca Run Commands, recorded with their decoded requests.
                $vmName = $Matches[1]
                $name = $Matches[2]
                if ($Method -eq 'PUT') {
                    if ($script:runCommandRefused -contains $vmName) {
                        return (New-Response 400 '{"error":{"code":"BadRequest","message":"The Run Command was refused."}}')
                    }
                    # A Run Command created again under its name is a new one.
                    $null = $script:rcaDeleted.Remove($name)
                    $script:rcaCommands.Add([pscustomobject]@{ Vm = $vmName; Name = $name; Action = (Get-TestRcaAction -Script ([string]$Body.properties.source.script)); Request = (ConvertFrom-TestRcaScript -Script ([string]$Body.properties.source.script)); At = $script:clock })
                    $open = @($script:rcaCommands | Where-Object { $_.Vm -eq $vmName -and ($script:rcaDeleted -notcontains $_.Name -or ($script:rcaDeleteReads.ContainsKey($_.Name) -and $script:rcaDeleteReads[$_.Name] -gt 0)) }).Count
                    $script:rcaMostOpen[$vmName] = [System.Math]::Max([int]$script:rcaMostOpen[$vmName], $open)
                    return (New-Response 201 '{}')
                }
                if ($Method -eq 'DELETE') {
                    $script:rcaDeleted.Add($name)
                    if ($script:rcaDeleteDelay.ContainsKey($vmName) -and -not $script:rcaDeleteReads.ContainsKey($name)) {
                        $script:rcaDeleteReads[$name] = [int]$script:rcaDeleteDelay[$vmName]
                    }
                    return (New-Response 200)
                }
                if ($script:rcaDeleted -contains $name -and $script:rcaDeleteReads.ContainsKey($name) -and $script:rcaDeleteReads[$name] -gt 0) {
                    # Still being deleted: Azure lists it, and it counts toward the VM's 25.
                    $script:rcaDeleteReads[$name]--
                    return (New-Response 200 '{"properties":{"provisioningState":"Deleting"}}')
                }
                return (New-Response 404)
            }
            '/virtualMachines/(\w+)/runCommands/(DbHubControl-rca-[A-Za-z0-9-]+)\?\$expand=instanceView$' {
                $name = $Matches[2]
                $command = @($script:rcaCommands | Where-Object { $_.Name -eq $name }) | Select-Object -Last 1
                if ($null -eq $command -or $script:rcaDeleted -contains $name) {
                    return (New-Response 404)
                }
                $view = Get-TestRcaView -Command $command
                if ($null -eq $view) {
                    $view = @{ executionState = 'Running' }
                }
                return (New-Response 200 (ConvertTo-Json -InputObject @{ name = $name; properties = @{ instanceView = $view } } -Depth 6))
            }
            '/virtualMachines/(\w+)/runCommands(\?\$expand=instanceView)?$' {
                $listed = $Matches[1]
                $open = @()
                if ($script:rcaListOpen) {
                    $open = @($script:rcaCommands | Where-Object { $_.Vm -eq $listed -and $script:rcaDeleted -notcontains $_.Name } | ForEach-Object {
                            $view = Get-TestRcaView -Command $_
                            if ($null -eq $view) {
                                $view = @{ executionState = 'Running' }
                            }
                            @{ name = $_.Name; properties = @{ instanceView = $view } }
                        })
                    # The ones Azure is still deleting, which it lists too (R871): each list is one read of the delete.
                    foreach ($deleting in @($script:rcaCommands | Where-Object { $_.Vm -eq $listed -and $script:rcaDeleted -contains $_.Name -and $script:rcaDeleteReads.ContainsKey($_.Name) -and $script:rcaDeleteReads[$_.Name] -gt 0 })) {
                        $script:rcaDeleteReads[$deleting.Name]--
                        $open += @{ name = $deleting.Name; properties = @{ provisioningState = 'Deleting' } }
                    }
                }
                if ($script:runCommands.ContainsKey($listed)) {
                    # An entry can be a scriptblock, run at each list: a Run Command Azure lists only for a while.
                    $raw = @($script:runCommands[$listed] | ForEach-Object { if ($_ -is [scriptblock]) { & $_ } else { $_ } })
                    return (New-Response 200 (ConvertTo-Json -InputObject @{ value = @($raw + $open) } -Depth 8))
                }
                if ($open.Count -gt 0) {
                    return (New-Response 200 (ConvertTo-Json -InputObject @{ value = @(@(@{ name = ('DbHubControl-{0}-20261026000000' -f $listed) }, @{ name = 'DbHubDemo-Other' }) + $open) } -Depth 8))
                }
                return (New-Response 200 ('{{"value":[{{"name":"DbHubControl-{0}-20261026000000"}},{{"name":"DbHubDemo-Other"}}]}}' -f $listed))
            }
            '/runCommands/([A-Za-z0-9-]+)\?\$expand=instanceView$' {
                if ($script:runCommandViews.ContainsKey($Matches[1])) {
                    $view = $script:runCommandViews[$Matches[1]]
                    # A view can be a scriptblock, run when it's read, for output that depends on when the Run Command went out.
                    if ($view -is [scriptblock]) {
                        $view = & $view
                    }
                    return (New-Response 200 (ConvertTo-Json -InputObject @{ name = $Matches[1]; properties = @{ instanceView = $view } } -Depth 6))
                }
                return (New-Response 202)
            }
            '/runCommands/' {
                if ($Method -eq 'PUT') {
                    if ($Path -match '/virtualMachines/(\w+)/runCommands/' -and $script:runCommandRefused -contains $Matches[1]) {
                        return (New-Response 400 '{"error":{"code":"BadRequest","message":"The Run Command was refused."}}')
                    }
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
                # T4's location, subnet, private DNS zone, and storage, which its replica copies (the session, 2026-11-14).
                $server = @{ id = ($script:demo + '/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123'); location = 'westus3'; properties = @{ state = $script:t4; replicationRole = 'Primary'; network = @{ delegatedSubnetResourceId = ($script:demo + '/providers/Microsoft.Network/virtualNetworks/vnet-dbhub-demo/subnets/snet-pg'); privateDnsZoneArmResourceId = ($script:demo + '/providers/Microsoft.Network/privateDnsZones/dbhub.private.postgres.database.azure.com') }; storage = @{ storageSizeGB = 32; tier = 'P4' } } }
                if ($script:t4Sku) {
                    $server['sku'] = @{ name = $script:t4Sku; tier = $script:t4Tier }
                }
                return (New-Response 200 (ConvertTo-Json -InputObject $server -Depth 6))
            }
            '/flexibleServers/pgflex01-abc123/(start|stop)$' {
                if ($script:t4ActionStatus -ne 202) { return (New-Response $script:t4ActionStatus '{"error":{"code":"UnsupportedMediaType","message":"Unsupported media type."}}') }
                # Azure's order (SourceReplicasStartStopOrder, live 2026-11-13): T4 starts only once its replica is Ready.
                if ($Matches[1] -eq 'start' -and $script:replica -in 'Stopped', 'Starting') { return (New-Response 400 '{"error":{"code":"SourceReplicasStartStopOrder","message":"Start the replicas first."}}') }
                if ($Matches[1] -eq 'stop' -and $script:t4StopIgnored -gt 0) { $script:t4StopIgnored--; return (New-Response 202) }
                if ($Matches[1] -eq 'stop' -and $null -ne $script:t4StopMinutes) { $script:t4StoppedAt = $script:clock.AddMinutes($script:t4StopMinutes) }
                $script:t4 = $(if ($Matches[1] -eq 'start') { 'Starting' } else { 'Stopping' }); return (New-Response 202)
            }
            '/flexibleServers/pgreplica01-abc123$' {
                if ($Method -eq 'PUT') {
                    # The session's creation (createMode Replica): refused sizes, a T4 that isn't ready yet, or no grant.
                    $sku = [string]$Body.sku.name
                    if ($script:replicaForbidden) { return (New-Response 403 '{"error":{"code":"AuthorizationFailed","message":"The client does not have authorization to perform action Microsoft.DBforPostgreSQL/flexibleServers/write."}}') }
                    if ($script:replicaNotReady -gt 0) {
                        $script:replicaNotReady--
                        return (New-Response 409 '{"error":{"code":"ReadReplicaServerInUnexpectedState","message":"Cannot perform operation on read replica because it''s in ''Restarting'' state."}}')
                    }
                    if ($sku -in $script:replicaRefuse) { return (New-Response 400 ('{{"error":{{"code":"SkuNotAvailable","message":"The requested SKU {0} isn''t available in westus3."}}}}' -f $sku)) }
                    $script:replica = 'Provisioning'
                    $script:replicaSku = $sku
                    $script:replicaReadyAt = $script:clock.AddMinutes($script:replicaCreateMinutes)
                    return (New-Response 201 '{}')
                }
                if ($Method -eq 'DELETE') {
                    if ($script:replicaDeleteForbidden) { return (New-Response 403 '{"error":{"code":"AuthorizationFailed","message":"The client does not have authorization to perform action Microsoft.DBforPostgreSQL/flexibleServers/delete."}}') }
                    if (-not $script:replica) { return (New-Response 404) }
                    $script:replica = 'Dropping'
                    $script:replicaGoneAt = $script:clock.AddMinutes(2)
                    return (New-Response 202)
                }
                if ($script:replica -eq 'Dropping' -and $null -ne $script:replicaGoneAt -and $script:clock -ge $script:replicaGoneAt) { $script:replica = '' }
                if (-not $script:replica) { return (New-Response 404) }
                if ($script:replica -in 'Starting', 'Provisioning' -and $null -ne $script:replicaReadyAt -and $script:clock -ge $script:replicaReadyAt) { $script:replica = 'Ready' }
                $server = @{ properties = @{ state = $script:replica; replicationRole = $script:replicaRole } }
                if ($script:replicaSku) { $server['sku'] = @{ name = $script:replicaSku; tier = 'GeneralPurpose' } }
                return (New-Response 200 (ConvertTo-Json -InputObject $server -Depth 4))
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
        @{ Name = 'an ru-storm on T5, at its maximum concurrency'; Body = @{ action = 'run'; activities = @(@{ target = 'T5'; scenario = 'ru-storm'; intensity = 8; concurrency = 16 }); durationMinutes = 30 } }
        @{ Name = 'a reset of T5'; Body = @{ action = 'reset'; targets = @('T5') } }
        @{ Name = 'the golden capture''s read of the status''s lists (2026-11-23)'; Body = @{ action = 'pending'; requestedBy = 'capture-t2-golden.ps1' } }
    ) {
        $request = Test-DbHubControlRequest -WebhookData (New-Webhook $Body) -Settings $script:settings
        $request.Reason | Should -BeNullOrEmpty
        $request.Valid | Should -BeTrue
        $request.Action | Should -Be $Body.action
    }

    It 'reads WebhookData given as the JSON of its properties, as a job started through Azure Resource Manager can pass it (2026-11-23)' {
        # capture-t2-golden.ps1 starts the pending action as a job, with WebhookData as JSON (Learn: an [object] parameter
        # takes named values); Azure Automation gives the runbook an object, and its text reads the same.
        $text = ConvertTo-Json -Compress -InputObject ([ordered]@{ WebhookName = 'capture-t2-golden.ps1'; RequestBody = '{"action":"pending","requestedBy":"capture-t2-golden.ps1"}' })
        $request = Test-DbHubControlRequest -WebhookData $text -Settings $script:settings
        $request.Valid | Should -BeTrue
        $request.Action | Should -Be 'pending'
        $request.RequestedBy | Should -Be 'capture-t2-golden.ps1'
        (Test-DbHubControlRequest -WebhookData '{not json' -Settings $script:settings).Reason | Should -Match 'no body'
        (Test-DbHubControlRequest -WebhookData (ConvertTo-Json -Compress -InputObject @{ RequestBody = '{"action":"delete"}' }) -Settings $script:settings).Reason | Should -Match 'action must be'
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
        @{ Name = 'ru-storm on a SQL target'; Raw = '{"action":"run","activities":[{"target":"T1","scenario":"ru-storm"}],"durationMinutes":20}'; Match = 'T1' }
        @{ Name = 'an ru-storm over its maximum concurrency'; Raw = '{"action":"run","activities":[{"target":"T5","scenario":"ru-storm","concurrency":17}],"durationMinutes":20}'; Match = 'concurrency' }
        @{ Name = 'a target past T5'; Raw = '{"action":"run","activities":[{"target":"T6","scenario":"baseline"}],"durationMinutes":20}'; Match = 'target must be' }
        @{ Name = 'a session on the read of the status''s lists'; Raw = ('{"action":"pending","sessionId":"' + ('a' * 32) + '"}'); Match = 'isn''t allowed for pending' }
    ) {
        $data = if ($null -eq $Raw) { $null } else { New-Webhook $Raw }
        $request = Test-DbHubControlRequest -WebhookData $data -Settings $script:settings
        $request.Valid | Should -BeFalse
        $request.Reason | Should -Match $Match
    }

    It 'allows the catalog''s targets and scenarios only, from scenarios/*/scenario.json' {
        # T4 is in the catalog since Phase 24's scenarios (connection-surge, idle-in-transaction) list it, and T5 since
        # ru-storm does (2026-11-18, ADR 0027), with T5 on in the configuration.
        @($script:settings.targets.PSObject.Properties.Name) | Should -Be @('T1', 'T2', 'T3', 'T4', 'T5')
        $scenarios = @($script:settings.scenarios.PSObject.Properties.Name)
        $scenarios | Should -Contain 'connection-surge'
        $scenarios | Should -Contain 'ru-storm'
        $scenarios | Should -Contain 'blocking-chain'
        $scenarios | Should -Contain 'capacity-max'
        $scenarios | Should -Not -Contain 'healthy-baseline'
        $script:settings.scenarios.'blocking-chain'.maxMinutes | Should -Be 30
        $script:settings.scenarios.'capacity-max'.maxMinutes | Should -Be 20
        $script:settings.scenarios.'blocking-chain'.maxConcurrency | Should -Be 4
    }

    It 'allows the showcase profile, from scenarios/activity-profiles.json: 90 minutes by default, 120 at most, on T1 to T5' {
        @($script:settings.profiles.PSObject.Properties.Name) | Should -Be @('showcase')
        $script:settings.profiles.showcase.defaultMinutes | Should -Be 90
        $script:settings.profiles.showcase.maxMinutes | Should -Be 120
        @($script:settings.profiles.showcase.targets) | Should -Be @('T1', 'T2', 'T3', 'T4', 'T5')
        # A session the auto-shutdown cuts short ends after whole cycles (2026-11-14).
        $script:settings.profiles.showcase.cycleMinutes | Should -Be 30
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

    It 'reads the status copy''s lists for the golden capture, encrypted or not, and only reads (pending, 2026-11-23)' {
        # capture-t2-golden.ps1 starts this as a job when Resource Manager returns the variable with no value, as it does once a
        # tenant's policy has encrypted it: Get-AutomationVariable reads it all the same.
        $carry = [ordered]@{ sessionId = 'b' * 32; pending = @([ordered]@{ documentId = 'doc-earlier-t2'; parts = 1; sha256 = ('d' * 64); vm = 'archost01' }); leftVms = @('archost01'); expiresUtc = '2026-10-30T00:00:00Z'; bundles = @(('e' * 32)) }
        $copy = [ordered]@{ schemaVersion = 1; sessionId = 'a' * 32; phase = 'stopped'; updatedUtc = '2026-10-27T14:00:00Z'; steps = @([ordered]@{ step = 'Start'; status = 'Pass'; message = 'started' }); rca = [ordered]@{ sessionId = 'a' * 32; pending = @([ordered]@{ documentId = 'doc-own-t2'; parts = 2; sha256 = ('a' * 64); vm = 'archost01' }, [ordered]@{ documentId = 'doc-own-t1'; parts = 1; sha256 = ('b' * 64); vm = 'sqlvm01' }); leftVms = @('sqlvm01') }; rcaHandoff = @([ordered]@{ documentId = 'doc-handoff-t2'; parts = 1; sha256 = ('c' * 64); vm = 'archost01' }); rcaEarlierPending = @($carry) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $copy -Depth 8 -Compress
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'pending'; requestedBy = 'capture-t2-golden.ps1' }) -Context (New-TestContext)
        $result.action | Should -Be 'pending'
        $result.status | Should -Be 'Read'
        $result.message | Should -Be ('The session''s status copy was read: session {0}, stopped, last written 2026-10-27T14:00:00Z.' -f ('a' * 32))
        $result.pending.sessionId | Should -Be ('a' * 32)
        $result.pending.phase | Should -Be 'stopped'
        $result.pending.updatedUtc | Should -Be '2026-10-27T14:00:00Z'
        @($result.pending.rca.pending | ForEach-Object { '{0} {1}' -f $_['documentId'], $_['vm'] }) | Should -Be @('doc-own-t2 archost01', 'doc-own-t1 sqlvm01')
        @($result.pending.rcaHandoff | ForEach-Object { '{0} {1}' -f $_['documentId'], $_['vm'] }) | Should -Be @('doc-handoff-t2 archost01')
        @($result.pending.rcaEarlierPending).Count | Should -Be 1
        $result.pending.rcaEarlierPending[0]['sessionId'] | Should -Be ('b' * 32)
        $result.pending.rcaEarlierPending[0]['expiresUtc'] | Should -Be '2026-10-30T00:00:00Z'
        @($result.pending.rcaEarlierPending[0]['pending'] | ForEach-Object { $_['documentId'] }) | Should -Be @('doc-earlier-t2')
        # Only what the capture reads: no steps, parts, checksums, or bundles.
        @($result.pending.Keys) | Should -Be @('sessionId', 'phase', 'updatedUtc', 'rca', 'rcaHandoff', 'rcaEarlierPending')
        @($result.pending.rca.pending[0].Keys) | Should -Be @('documentId', 'vm')
        # The result line DbHub-Control prints keeps every list (ConvertTo-Json -Depth 6, as DbHub-Control.ps1 writes it).
        $line = ConvertTo-Json -InputObject $result -Depth 6 -Compress
        ($line | ConvertFrom-Json).pending.rcaEarlierPending[0].pending[0].documentId | Should -Be 'doc-earlier-t2'
        # Read only, and before the demo group's check: no Azure Resource Manager request at all, and nothing written.
        $script:calls | Should -BeNullOrEmpty
        $script:automationVariables['DbHubSessionStatus'] | Should -BeExactly (ConvertTo-Json -InputObject $copy -Depth 8 -Compress)
    }

    It 'says when the status copy holds no status, or can''t be read, rather than listing nothing (pending, 2026-11-23)' {
        $script:automationVariables['DbHubSessionStatus'] = '""'
        $empty = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'pending' }) -Context (New-TestContext)
        $empty.status | Should -Be 'Empty'
        $empty.pending | Should -BeNullOrEmpty
        $script:automationVariables['DbHubSessionStatus'] = '{not json'
        $broken = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'pending' }) -Context (New-TestContext)
        $broken.status | Should -Be 'Unread'
        $broken.message | Should -Be 'The variable DbHubSessionStatus isn''t the JSON of a status.'
        $script:variableMissing = $true
        $missing = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'pending' }) -Context (New-TestContext)
        $missing.status | Should -Be 'Unread'
        $missing.message | Should -Be 'The variable DbHubSessionStatus couldn''t be read: Variable ''DbHubSessionStatus'' was not found.'
        $script:calls | Should -BeNullOrEmpty
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

    It 'lets a run start while only start-demo.ps1''s auto-stop is pending, and replaces it, with its backup, by the run''s own plan (2026-11-19)' {
        # The newer session's plan wins: start-demo.ps1 marks its auto-stop, so a later Run all or the Insights app's Start
        # isn't refused, and that start-demo.ps1 auto-stop doesn't cut the run off.
        $script:autostop = '2026-10-27T18:00:00Z'
        $script:autostopDescription = '[start-demo.ps1] Stops the demo 4 hours after this start: the start-demo.ps1 session started at 2026-10-27T14:00:00Z.'
        $script:backup = '2026-10-27T18:30:00Z'
        $script:backupDescription = '[start-demo.ps1] Stops the demo if the auto-stop of the start-demo.ps1 session that started at 2026-10-27T14:00:00Z didn''t.'
        $script:links.Add([pscustomobject]@{ Id = 'ffffffff-0000-0000-0000-000000000001'; Schedule = 'dbhub-autostop'; Runbook = 'DbHub-Stop'; Parameters = @{ Scope = 'All' } })
        $script:links.Add([pscustomobject]@{ Id = 'ffffffff-0000-0000-0000-000000000002'; Schedule = 'dbhub-autostop-backup'; Runbook = 'DbHub-Stop'; Parameters = @{ Scope = 'All' } })
        $pending = Get-DbHubAutoStopRunEnd -Context (New-TestContext)
        $pending.State | Should -Be 'None'
        $pending.StartDemo | Should -BeTrue
        (Get-DbHubActiveRun -Context (New-TestContext)).Active | Should -BeFalse
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        $script:autostop | Should -Be '2026-10-27T15:30:00Z'
        $script:autostopDescription | Should -Not -Match '^\[start-demo\.ps1\]'
        $script:backupDescription | Should -Not -Match '^\[start-demo\.ps1\]'
        @($script:links | Where-Object { $_.Id -in 'ffffffff-0000-0000-0000-000000000001', 'ffffffff-0000-0000-0000-000000000002' }) | Should -BeNullOrEmpty
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

    It 'stops what it started when the only activities it could dispatch are off, and leaves the VM that ran before alone (#27)' {
        $script:vm['archost01'] = 'running'
        $script:vmStartMinutes['sqlvm01'] = 60
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'showcase' }, @{ target = 'T2'; scenario = 'off' }); durationMinutes = 30 }) -Context (New-TestContext)
        @($result.dispatched) | Should -Be @('T2: off')
        $result.status | Should -Be 'Failed'
        $result.message | Should -Match '^No activity could be dispatched \(T1 \(sqlvm01 isn''t running yet\)\), so this run stopped what it started: auto-stop removed, sqlvm01 deallocating\. '
        @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/deallocate$' } | ForEach-Object { ($_.Path -split '/')[-2] }) | Should -Be @('sqlvm01')
        $script:vm['archost01'] | Should -Be 'running'
        $result.left | Should -BeExactly 'This run didn''t start archost01 (running), so it left it running, as before; the nightly safety stop still stops it at 19:00 (Eastern Standard Time).'
        $result.leftFix | Should -BeExactly 'To stop everything now: set STOP_NOW = True and Run all in the control notebook, or run ./scripts/stop-demo.ps1.'
        $result.message | Should -Match ('{0} {1}$' -f [regex]::Escape($result.left), [regex]::Escape($result.leftFix))
    }

    It 'leaves a running sqlvm01 and T4 alone when it could send only T1''s off and archost01''s Run Command was refused (#27, the issue''s case)' {
        $script:vm['sqlvm01'] = 'running'
        $script:t4 = 'Ready'
        $script:runCommandRefused = @('archost01')
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'off' }, @{ target = 'T2'; scenario = 'showcase' }); durationMinutes = 30 }) -Context (New-TestContext)
        $result.status | Should -Be 'Failed'
        @($result.dispatched) | Should -Be @('T1: off')
        @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/deallocate$' } | ForEach-Object { ($_.Path -split '/')[-2] }) | Should -Be @('archost01')
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/stop$' }) | Should -BeNullOrEmpty
        $script:vm['sqlvm01'] | Should -Be 'running'
        $script:t4 | Should -Be 'Ready'
        $script:autostop | Should -BeNullOrEmpty
        $result.left | Should -BeExactly 'This run didn''t start sqlvm01 (running) and T4 (Ready), so it left them running, as before; the nightly safety stop still stops them at 19:00 (Eastern Standard Time).'
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

    It 'leaves a Running plugin alone after a cold start when the agent reports no time, and restarts a NotRunning one after the wait (#22)' {
        # Without MainServiceLastReportedTime nothing proves a Running status stale, so it's taken at its word; a NotRunning
        # one still waits out the start before the restart the 2026-10-22 and 2026-10-30 findings call for.
        $start = $script:clock
        $script:pluginReported = { $null }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.monitoring | Should -Be 'Running'
        @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' }) | Should -BeNullOrEmpty

        Reset-TestAzure
        $start = $script:clock
        $script:pluginReported = { $null }
        $script:plugin = { if ($null -ne $script:restartedAt) { 'Running' } else { 'NotRunning' } }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.monitoring | Should -Be 'Restarted'
        $restart = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' })
        $restart.Count | Should -Be 1
        ($restart[0].At - $start).TotalMinutes | Should -BeGreaterOrEqual 8
        ($restart[0].At - $start).TotalMinutes | Should -BeLessThan 9
    }

    It 'leaves a healthy plugin alone on a warm sqlvm01 whose latest start the control''s own Run Commands moved, when the agent reports no time (#22)' {
        # The provisioning status's time moves with every Run Command, the control's own and the restart included, so it
        # was 5 minutes old on every warm run and re-check, and the agent was restarted each time.
        $script:vm['sqlvm01'] = 'running'
        $script:vmSince['sqlvm01'] = $script:clock.AddMinutes(-5)
        $script:pluginReported = { $null }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 60 }) -Context (New-TestContext)
        $result.monitoring | Should -Be 'Running'
        $script:autostop = '2026-10-27T16:40:00Z'
        $script:vmSince['sqlvm01'] = $script:clock.AddMinutes(-3)
        $monitor = Invoke-DbHubMonitor -Context (New-TestContext -NowUtc $script:clock)
        $monitor.monitoring | Should -Be 'Running'
        @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-monitoring-' }) | Should -BeNullOrEmpty
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

    It 'stops again what it started when nothing could be dispatched' {
        $script:runCommandStatus = 409
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T1'; scenario = 'baseline' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Failed'
        @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/deallocate$' } | ForEach-Object { ($_.Path -split '/')[-2] }) | Should -Be @('sqlvm01')
        $script:autostop | Should -BeNullOrEmpty
        $result.left | Should -BeNullOrEmpty -Because 'nothing else runs'
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
        @{ Name = 'can''t be read (A1 missing after a redeploy)'; Code = 403; Match = 'an Owner runs \./scripts/grant-safety-stop\.ps1 \(A1\)' }
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
        # T5 (2026-11-18) goes with sqlvm01, as T1 and T3 do: Azure Cosmos DB has no stop.
        @($result.dispatched) | Should -Be @('T1', 'T3', 'T5')
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

Describe 'The control session (ADR 0026, 2026-11-14): one Run all, its read replica, its status, and its end' {
    BeforeEach {
        Reset-TestAzure
        Mock Get-DbHubUtcNow { return $script:clock }
        Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
        Mock Invoke-DbHubArm {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body; At = $script:clock })
            return (Invoke-TestAzure -Method $Method -Path $Path -Body $Body)
        }
        # An environment deploy.ps1 set the replica up in, with T4 stopped on its default size and no replica between sessions.
        $script:groupTags = @{ DbHubT4Replica = 'Session' }
        $script:t4 = 'Stopped'
        $script:t4Sku = 'Standard_D4ds_v5'
        $script:t4Tier = 'GeneralPurpose'
        $script:t4ReadyAt = $script:clock.AddMinutes(4)
        $script:sessionId = '0123456789abcdef0123456789abcdef'
        # The status the notebook reads: the latest write of the status secret, parsed.
        function Get-SessionStatus {
            $writes = $script:secrets['dbhub-session-status']
            return ($writes[$writes.Count - 1].Value | ConvertFrom-Json)
        }
    }

    It 'validates its requests: a session needs a sessionId, takes the showcase''s minutes, and runs the showcase on every target' {
        $session = Test-DbHubControlRequest -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Settings $script:settings
        $session.Valid | Should -BeTrue
        $session.Action | Should -Be 'session'
        $session.SessionId | Should -Be $script:sessionId
        $session.DurationMinutes | Should -Be 90
        @($session.Activities | ForEach-Object Target) | Should -Be @('T1', 'T2', 'T3', 'T4', 'T5')
        @($session.Activities | ForEach-Object Scenario | Select-Object -Unique) | Should -Be @('showcase')
        (Test-DbHubControlRequest -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId; durationMinutes = 120 }) -Settings $script:settings).DurationMinutes | Should -Be 120
        foreach ($body in @(
                @{ action = 'session' }
                @{ action = 'session'; sessionId = 'ABCDEF0123456789ABCDEF0123456789' }
                @{ action = 'session'; sessionId = $script:sessionId; durationMinutes = 20 }
                @{ action = 'session'; sessionId = $script:sessionId; durationMinutes = 121 }
                @{ action = 'session'; sessionId = $script:sessionId; activities = @() }
                @{ action = 'capture' }
            )) {
            (Test-DbHubControlRequest -WebhookData (New-Webhook $body) -Settings $script:settings).Valid | Should -BeFalse -Because ($body | ConvertTo-Json -Compress)
        }
        (Test-DbHubControlRequest -WebhookData (New-Webhook @{ action = 'capture'; sessionId = $script:sessionId }) -Settings $script:settings).Valid | Should -BeTrue
        $stop = Test-DbHubControlRequest -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:sessionId }) -Settings $script:settings
        $stop.Valid | Should -BeTrue
        $stop.SessionId | Should -Be $script:sessionId
    }

    It 'starts everything, marks the demo busy, asks for T4''s read replica once T4 is Ready, and says when the replica beat runs' {
        $context = New-TestContext
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId; requestedBy = 'presenter' }) -Context $context
        $result.action | Should -Be 'session'
        $result.status | Should -Be 'Started'
        $result.sessionId | Should -Be $script:sessionId
        # A session creates the replica, so it never says a run's "on-demand runs don't create it" (live, 2026-11-14).
        @($context.Log | Where-Object { $_ -match 'don''t create it' }) | Should -BeNullOrEmpty
        $result.replica | Should -Not -Match 'start-demo\.ps1'
        # The busy marker and the session's ID, before anything starts.
        $script:groupTags['DbHubBusyBy'] | Should -Be 'session'
        $script:groupTags['DbHubSessionId'] | Should -Be $script:sessionId
        $script:groupTags['DbHubSessionStartUtc'] | Should -Be '2026-10-27T15:00:00Z'
        $marker = @($script:calls | Where-Object { $_.Method -eq 'PATCH' }) | Select-Object -First 1
        $firstStart = @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/start$' }) | Select-Object -First 1
        $marker.At | Should -BeLessOrEqual $firstStart.At
        $script:calls.IndexOf($marker) | Should -BeLessThan $script:calls.IndexOf($firstStart)
        # The auto-stop and its second, 30 minutes later.
        $script:autostop | Should -Not -BeNullOrEmpty
        ([datetime]::Parse($script:backup, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) - [datetime]::Parse($script:autostop, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)).TotalMinutes | Should -Be 30
        @($script:links | Where-Object Schedule -EQ 'dbhub-autostop-backup' | ForEach-Object { $_.Parameters.Scope }) | Should -Be @('All')
        # The replica: once T4 is Ready, at T4's size, in T4's subnet and DNS zone, then its parameter and its size's record.
        $create = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/flexibleServers/pgreplica01-abc123$' })
        $create.Count | Should -Be 1
        $create[0].Body.properties.createMode | Should -Be 'Replica'
        $create[0].Body.sku.name | Should -Be 'Standard_D4ds_v5'
        $create[0].Body.properties.sourceServerResourceId | Should -Match '/flexibleServers/pgflex01-abc123$'
        $create[0].Body.properties.network.delegatedSubnetResourceId | Should -Match '/subnets/snet-pg$'
        $create[0].Body.properties.network.publicNetworkAccess | Should -Be 'Disabled'
        $create[0].Body.tags['component'] | Should -Be 't4-replica'
        $create[0].At | Should -BeGreaterOrEqual $script:t4ReadyAt
        $script:replica | Should -Be 'Ready'
        $script:replicaParameter | Should -Be '600000'
        $script:groupTags['DbHubT4ReplicaSize'] | Should -Be 'Standard_D4ds_v5@any'
        # The status the notebook reads.
        $status = Get-SessionStatus
        $status.sessionId | Should -Be $script:sessionId
        $status.phase | Should -Be 'running'
        $status.replica.state | Should -Be 'Ready'
        $status.replica.sizeUsed | Should -Be 'Standard_D4ds_v5'
        $status.busy.marked | Should -BeTrue
        $status.replicaLag.planned | Should -BeTrue
        @($status.replicaLag.windows).Count | Should -Be 1 -Because 'a 90-minute session has one even cycle after T4''s profile is set'
        @($status.dispatched) | Should -Contain 'T4: showcase for 90 minutes'
        # When each target's showcase began, for the notebook's guide: T1 and T3 on sqlvm01's dispatch, T4 on its own.
        $utcText = { param($Value) if ($Value -is [datetime]) { $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$Value } }
        foreach ($target in 'T1', 'T2', 'T3', 'T4') {
            (& $utcText $status.dispatchUtc.$target) | Should -Match '^2026-10-27T15:\d\d:\d\dZ$' -Because $target
        }
        (& $utcText $status.dispatchUtc.T3) | Should -Be (& $utcText $status.dispatchUtc.T1)
        (& $utcText $status.dispatchUtc.T4) | Should -Be (& $utcText $status.t4.dispatchUtc)
        @($status.steps | ForEach-Object step) | Should -Contain 'ReplicaLag'
        @($script:secrets['dbhub-session-status'] | ForEach-Object { ($_.Value | ConvertFrom-Json).phase } | Select-Object -Unique) | Should -Be @('accepted', 'starting', 'replica', 'running')
        @($script:secrets['dbhub-session-status'] | ForEach-Object { $_.Tags['sessionId'] } | Select-Object -Unique) | Should -Be @($script:sessionId)
    }

    It 'says on the status what a session that couldn''t send any activity left running, and how to stop everything (#27)' {
        # The presenter's archost01 ran before; its Run Command is refused, and sqlvm01 doesn't come up in time.
        $script:vm['archost01'] = 'running'
        $script:vmStartMinutes['sqlvm01'] = 60
        $script:runCommandRefused = @('archost01')
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId; requestedBy = 'presenter' }) -Context (New-TestContext)
        $result.status | Should -Be 'Failed'
        $script:vm['archost01'] | Should -Be 'running'
        @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/deallocate$' } | ForEach-Object { ($_.Path -split '/')[-2] }) | Should -Be @('sqlvm01')
        $status = Get-SessionStatus
        $status.phase | Should -Be 'failed'
        $start = @($status.steps | Where-Object { $_.step -eq 'Start' -and $_.state -eq 'Fail' })
        $start.Count | Should -Be 1
        $start[0].message | Should -Match '^No activity could be dispatched .*, so this run stopped what it started: auto-stop removed'
        $start[0].message | Should -Not -Match 'nightly safety stop' -Because 'what it left running is a step of its own'
        $stop = @($status.steps | Where-Object step -EQ 'Stop')
        $stop.Count | Should -Be 1
        $stop[0].state | Should -Be 'Warning'
        $stop[0].message | Should -BeExactly 'This run didn''t start archost01 (running), so it left it running, as before; the nightly safety stop still stops it at 19:00 (Eastern Standard Time).'
        $stop[0].fix | Should -BeExactly 'To stop everything now: set STOP_NOW = True and Run all in the control notebook, or run ./scripts/stop-demo.ps1.'
    }

    It 'moves to the next documented size when Azure refuses T4''s, and says so with what it used' {
        $script:replicaRefuse = @('Standard_D4ds_v5')
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.status | Should -Be 'Started'
        @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/flexibleServers/pgreplica01-abc123$' } | ForEach-Object { $_.Body.sku.name }) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5')
        $status = Get-SessionStatus
        $status.replica.sizeUsed | Should -Be 'Standard_D4ads_v5'
        @($status.replica.attempts | ForEach-Object outcome) | Should -Be @('SkuNotAvailable', 'Accepted')
        $status.replica.note | Should -Match 'Azure refused T4''s size \(Standard_D4ds_v5\) for the replica, so it runs on Standard_D4ads_v5'
        $script:groupTags['DbHubT4ReplicaSize'] | Should -Be 'Standard_D4ads_v5@any'
    }

    It 'asks again while T4 restarts (ReadReplicaServerInUnexpectedState, live 2026-11-13), then creates the replica' {
        $script:replicaNotReady = 3
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.status | Should -Be 'Started'
        @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/flexibleServers/pgreplica01-abc123$' }).Count | Should -Be 4
        $script:replica | Should -Be 'Ready'
    }

    It 'runs the session without the replica, and says why with the fix, when <Case>' -ForEach @(
        @{ Case = 'the control identity can''t create it yet'; Setup = { $script:replicaForbidden = $true }; State = 'NotGranted'; Match = 'grant-safety-stop\.ps1' }
        @{ Case = 'T4 is Burstable'; Setup = { $script:t4Sku = 'Standard_B1ms'; $script:t4Tier = 'Burstable' }; State = 'NotSupported'; Match = 't4SkuName' }
        @{ Case = 'deploy.ps1 hasn''t set the replica up here'; Setup = { $script:groupTags = @{} }; State = 'NotSetUp'; Match = 'deploy\.ps1' }
        @{ Case = 'Azure refuses every size'; Setup = { $script:replicaRefuse = @('Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5') }; State = 'Refused'; Match = 'Region access request' }
    ) {
        & $Setup
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.status | Should -Be $(if ($State -eq 'NotSupported') { 'Started' } else { 'Partial' })
        @($result.dispatched) | Should -Contain 'T1: showcase for 90 minutes'
        $status = Get-SessionStatus
        $status.phase | Should -Be 'running'
        $status.replica.state | Should -Be $State
        $status.replica.fix | Should -Match $Match
        $status.replicaLag.planned | Should -BeFalse
        $status.replicaLag.note | Should -Match 'doesn''t run this session'
        $script:replica | Should -BeNullOrEmpty
    }

    It 'ends after its last whole showcase cycle before the VMs'' auto-shutdown and says so, and refuses a session that would be shorter than 30 minutes' {
        # 18:20 Eastern: 38 minutes to the 19:00 auto-shutdown, less its 2-minute margin, so one whole 30-minute cycle: no
        # beat stops midway when the VMs' activity ends (2026-11-14).
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Context (New-TestContext -NowUtc ([datetime]::new(2026, 10, 27, 22, 20, 0, [System.DateTimeKind]::Utc)))
        $result.status | Should -Be 'Partial'
        $status = Get-SessionStatus
        $status.plannedMinutes | Should -Be 30
        ([datetime]$status.runEndUtc).ToUniversalTime() | Should -Be ([datetime]::new(2026, 10, 27, 22, 50, 0, [System.DateTimeKind]::Utc))
        @($status.dispatched) | Should -Contain 'T1: showcase for 30 minutes'
        (@($status.steps) | Where-Object step -EQ 'Plan').message | Should -Match 'runs 30 of the 90 minutes asked: it ends at 18:50, before the VMs'' auto-shutdown at 19:00 \(Eastern Standard Time\), when the activity on the VMs ends\. It ends after 1 whole 30-minute showcase cycle, so no beat is cut off\.'
        (@($status.steps) | Where-Object step -EQ 'Plan').fix | Should -Match 'autoShutdownTime'
        # 17:15 Eastern: 103 minutes left, so the 90 asked fit, whole cycles or not.
        Reset-TestAzure
        $script:groupTags = @{ DbHubT4Replica = 'Session' }
        $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Context (New-TestContext -NowUtc ([datetime]::new(2026, 10, 27, 21, 15, 0, [System.DateTimeKind]::Utc)))
        (Get-SessionStatus).plannedMinutes | Should -Be 90
        Reset-TestAzure
        $script:groupTags = @{ DbHubT4Replica = 'Session' }
        $late = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Context (New-TestContext -NowUtc ([datetime]::new(2026, 10, 27, 22, 40, 0, [System.DateTimeKind]::Utc)))
        $late.status | Should -Be 'Refused'
        $late.message | Should -Match 'too soon for a session of at least 30 minutes'
        (Get-SessionStatus).phase | Should -Be 'refused'
        @($script:calls | Where-Object { $_.Method -in 'POST', 'PATCH' }) | Should -BeNullOrEmpty -Because 'nothing starts and the demo isn''t marked busy'
    }

    It 'refuses a session while another run is active, and says how to end it' {
        $script:autostop = '2026-10-27T15:40:00Z'
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.status | Should -Be 'Refused'
        $status = Get-SessionStatus
        $status.phase | Should -Be 'refused'
        (@($status.steps) | Where-Object step -EQ 'Start').fix | Should -Match 'Stop now'
        @($script:calls | Where-Object { $_.Method -in 'POST', 'PATCH' }) | Should -BeNullOrEmpty
    }

    It 'Stop now saves the history''s metrics first, deletes the replica, then stops T4, and clears the session''s marker' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        $script:t4 = 'Ready'
        $script:replica = 'Ready'
        $script:replicaSku = 'Standard_D4ds_v5'
        $script:autostop = '2026-10-27T15:30:00Z'
        $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'session'; DbHubSessionId = $script:sessionId; DbHubSessionStartUtc = '2026-10-27T13:30:00Z' }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        # The metrics, while the replica exists: T4's and the replica's, with the session's ID.
        $metrics = $script:secrets['dbhub-session-metrics'][0]
        $document = $metrics.Value | ConvertFrom-Json
        $document.version | Should -Be 1
        $document.sessionId | Should -Be $script:sessionId
        @($document.servers | ForEach-Object role) | Should -Be @('primary', 'replica')
        $lag = @($document.series) | Where-Object metric -EQ 'physical_replication_delay_in_seconds'
        @($lag.points | ForEach-Object { $_[1] }) | Should -Be @(4, 180, 6)
        ([datetime]$document.startUtc).ToUniversalTime() | Should -Be ([datetime]::new(2026, 10, 27, 13, 20, 0, [System.DateTimeKind]::Utc)) -Because 'the window starts 10 minutes before the session'
        $metrics.Tags['replica'] | Should -Be 'yes'
        $capture = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Path -match '/secrets/dbhub-session-metrics$' }) | Select-Object -First 1))
        $delete = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/flexibleServers/pgreplica01-abc123$' }) | Select-Object -First 1))
        $t4Stop = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/stop$' }) | Select-Object -First 1))
        $capture | Should -BeLessThan $delete
        $delete | Should -BeLessThan $t4Stop
        $script:replica | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgreplica01-abc123/stop$' }) | Should -BeNullOrEmpty
        $script:groupTags['DbHubBusyUntilUtc'] | Should -BeNullOrEmpty
        $script:groupTags['DbHubBusyBy'] | Should -BeNullOrEmpty
        $status = Get-SessionStatus
        $status.phase | Should -Be 'stopped'
        $status.stoppedBy | Should -Be 'Stop now'
        @($status.done) | Should -Contain 'T4''s read replica pgreplica01-abc123 deleted'
        # Its only Run Commands are the evidence export's (ADR 0031), then the Query Store sidecars' index (2026-11-23), each
        # deleted once read; nothing is stopped through one.
        @($script:calls | Where-Object { $_.Path -match '/runCommands/' -and $_.Method -eq 'PUT' -and $_.Path -notmatch '/runCommands/DbHubControl-rca-' }) | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Path -match '/runCommands/' -and $_.Method -eq 'DELETE' -and $_.Path -notmatch '/runCommands/DbHubControl-rca-' }) | Should -BeNullOrEmpty
        @($script:rcaCommands | ForEach-Object { $_.Request.command }) | Should -Be @('export', 'export', 'sidecar-export', 'sidecar-export')
        @($script:rcaCommands | Where-Object { $script:rcaDeleted -notcontains $_.Name }) | Should -BeNullOrEmpty
    }

    It 'the auto-stop does the same, and writes its stop to the session the group names' {
        $script:t4 = 'Ready'
        $script:replica = 'Ready'
        $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'session'; DbHubSessionId = $script:sessionId; DbHubSessionStartUtc = '2026-10-27T13:30:00Z' }
        $result = Invoke-DbHubStop -Scope All -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $script:replica | Should -BeNullOrEmpty
        $status = Get-SessionStatus
        $status.stoppedBy | Should -Be 'Auto-stop'
        $status.sessionId | Should -Be $script:sessionId
        $status.metrics.status | Should -Be 'Pass'
        $result.PSObject.Properties.Name | Should -Not -Contain 'rcaLines'
    }

    It 'stops a Run all session for stop-demo.ps1 as the auto-stop does, says stop-demo.ps1 stopped it, and returns the lines its status got (2026-11-22)' {
        $script:t4 = 'Ready'
        $script:replica = 'Ready'
        $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'session'; DbHubSessionId = $script:sessionId; DbHubSessionStartUtc = '2026-10-27T13:30:00Z' }
        $result = Invoke-DbHubStop -Scope All -Context (New-TestContext) -RequestedBy 'stop-demo.ps1'
        $result.status | Should -Be 'Stopped'
        $result.requestedBy | Should -Be 'stop-demo.ps1'
        $result.message | Should -Match '^stop-demo\.ps1: auto-stop removed, '
        $script:replica | Should -BeNullOrEmpty
        $status = Get-SessionStatus
        $status.stoppedBy | Should -Be 'stop-demo.ps1'
        $status.metrics.status | Should -Be 'Pass'
        @($status.rcaLines).Count | Should -BeGreaterThan 0
        @($result.rcaLines | ForEach-Object { $_['step'] }) | Should -Be @($status.rcaLines | ForEach-Object { $_.step })
        @($result.rcaLines | ForEach-Object { $_['message'] }) | Should -Be @($status.rcaLines | ForEach-Object { $_.message })
        $result.PSObject.Properties.Name | Should -Not -Contain 'yieldedTo'
        # A copy that another job's status replaced after this job wrote its own gives this result none of its lines.
        $script:otherCopy = ($script:automationVariables['DbHubSessionStatus'] -replace '"jobId":"[^"]*"', '"jobId":"bbbbbbbb-0000-0000-0000-00000000000b"')
        $script:automationVariables.Remove('DbHubSessionStatus')
        Mock -CommandName Write-DbHubStopStatus -MockWith { $script:automationVariables['DbHubSessionStatus'] = $script:otherCopy }
        $again = Invoke-DbHubStop -Scope All -Context (New-TestContext) -RequestedBy 'stop-demo.ps1'
        @($again.rcaLines) | Should -BeNullOrEmpty
    }

    Context 'a second stop of a session (review of f5972d2d): one stop does the session''s own part' {
        BeforeEach {
            # The stop that ran first: stop-demo.ps1's handoff, whose status has the metrics' final version and the stop's lines.
            $script:firstJob = 'bbbbbbbb-0000-0000-0000-00000000000b'
            $script:firstStatus = [ordered]@{ schemaVersion = 1; sessionId = $script:sessionId; phase = 'stopped'; updatedUtc = '2026-10-27T14:58:00Z'; stoppedUtc = '2026-10-27T14:58:00Z'; stoppedBy = 'stop-demo.ps1'; jobId = $script:firstJob; done = @('auto-stop removed'); failed = @(); metrics = [ordered]@{ status = 'Pass'; message = 'saved'; version = ('c' * 32) }; planKept = $true; rcaLines = @([ordered]@{ step = 'RCA.EXPORT'; status = 'Pass'; message = 'The session''s evidence was exported.'; fix = '' }) }
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
            $script:t4 = 'Ready'
            $script:replica = 'Ready'
            $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'session'; DbHubSessionId = $script:sessionId; DbHubSessionStartUtc = '2026-10-27T13:30:00Z' }
            $script:sleeps = 0
            $script:sleepHook = $null
            Mock Start-Sleep {
                $script:clock = $script:clock.AddSeconds($Seconds)
                $script:sleeps++
                if ($null -ne $script:sleepHook) {
                    & $script:sleepHook
                }
            }
            # What the session's part writes: the export's Run Commands, the metrics, and the status.
            function Get-SessionPart {
                [pscustomobject]@{
                    Exports = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-rca-' }).Count
                    Metrics = $script:secrets.ContainsKey('dbhub-session-metrics')
                    Status  = $script:secrets.ContainsKey('dbhub-session-status')
                }
            }
        }

        It 'stops what''s left after the session''s stop ran, and keeps that stop''s status: Stop now, the auto-stop, and stop-demo.ps1''s' {
            $before = ConvertTo-Json -InputObject $script:firstStatus -Depth 8 -Compress
            $script:automationVariables['DbHubSessionStatus'] = $before
            # The notebook's own end after a handoff (its last status read said running): Stop now, with the session.
            $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:sessionId }) -Context (New-TestContext)
            $result.status | Should -Be 'Stopped'
            @($result.done) | Should -Contain 'session 01234567''s stop ran already (job bbbbbbbb, stop-demo.ps1): its evidence, metrics, and status are that stop''s'
            @($result.done) | Should -Contain 'sqlvm01 deallocating'
            $script:replica | Should -BeNullOrEmpty -Because 'the resources still stop'
            $part = Get-SessionPart
            $part.Exports | Should -Be 0
            $part.Metrics | Should -BeFalse
            $part.Status | Should -BeFalse
            $script:automationVariables['DbHubSessionStatus'] | Should -BeExactly $before
            # The session's auto-stop, and a later run's auto-stop that reads the session's ID from the group's tag: the same.
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
            $auto = Invoke-DbHubStop -Scope All -Context (New-TestContext -JobId 'dddddddd-0000-0000-0000-00000000000d')
            @($auto.done) | Should -Contain 'session 01234567''s stop ran already (job bbbbbbbb, stop-demo.ps1): its evidence, metrics, and status are that stop''s'
            (Get-SessionPart).Status | Should -BeFalse
            # stop-demo.ps1's: its result has that stop's lines, and says whose they are.
            $handed = Invoke-DbHubStop -Scope All -Context (New-TestContext -JobId 'eeeeeeee-0000-0000-0000-00000000000e') -RequestedBy 'stop-demo.ps1'
            $handed.yieldedTo['state'] | Should -Be 'Stopped'
            $handed.yieldedTo['jobId'] | Should -Be $script:firstJob
            @($handed.rcaLines | ForEach-Object { $_['message'] }) | Should -Be @('The session''s evidence was exported.')
            $script:automationVariables['DbHubSessionStatus'] | Should -BeExactly $before
        }

        It 'waits for another job''s stop of the session that still runs, and leaves the session''s part to it' {
            $running = [ordered]@{ schemaVersion = 1; sessionId = $script:sessionId; phase = 'running'; updatedUtc = '2026-10-27T14:59:00Z'; runEndUtc = '2026-10-27T15:30:00Z'; stopBegunUtc = '2026-10-27T14:59:00Z'; stopBegunJobId = $script:firstJob }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
            $script:jobs = @(@{ properties = @{ jobId = $script:firstJob; status = 'Running'; runbook = @{ name = 'DbHub-Stop' }; creationTime = '2026-10-27T14:58:30Z' } })
            # That stop ends two polls later, with its status.
            $script:sleepHook = {
                if ($script:sleeps -eq 2) {
                    $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $script:firstStatus -Depth 8 -Compress
                    $script:jobs = @(@{ properties = @{ jobId = $script:firstJob; status = 'Completed'; runbook = @{ name = 'DbHub-Stop' }; creationTime = '2026-10-27T14:58:30Z' } })
                }
            }
            $context = New-TestContext
            $result = Invoke-DbHubStop -Scope All -Context $context
            $result.status | Should -Be 'Stopped'
            @($result.done) | Should -Contain 'session 01234567''s stop ran already (job bbbbbbbb, stop-demo.ps1): its evidence, metrics, and status are that stop''s'
            @($context.Log | Where-Object { $_ -match 'Session 01234567''s stop began in job bbbbbbbb-0000-0000-0000-00000000000b, which still runs: this stop waits for it' }) | Should -Not -BeNullOrEmpty
            $part = Get-SessionPart
            $part.Exports | Should -Be 0
            $part.Metrics | Should -BeFalse
            $part.Status | Should -BeFalse
            # Still running once that mark's life ends: the rest is stopped, and the session's part is left to it.
            Reset-TestAzure
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
            $script:groupTags = @{ DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'session'; DbHubSessionId = $script:sessionId }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
            $script:jobs = @(@{ properties = @{ jobId = $script:firstJob; status = 'Running'; runbook = @{ name = 'DbHub-Stop' }; creationTime = '2026-10-27T14:58:30Z' } })
            $script:sleepHook = $null
            $late = Invoke-DbHubStop -Scope All -Context (New-TestContext)
            @($late.done) | Should -Contain 'session 01234567''s stop still runs (job bbbbbbbb): its evidence, metrics, and status are left to it'
            $script:clock | Should -Be ([datetime]::new(2026, 10, 27, 15, 14, 0, [System.DateTimeKind]::Utc)) -Because 'it waits until the mark''s life ends, 15 minutes after it began'
            (Get-SessionPart).Status | Should -BeFalse
            @($late.done) | Should -Contain 'sqlvm01 deallocating'
        }

        It 'does the whole work when that other job ended without stopping the session, and its own mark names its job' {
            $running = [ordered]@{ schemaVersion = 1; sessionId = $script:sessionId; phase = 'running'; updatedUtc = '2026-10-27T14:59:00Z'; runEndUtc = '2026-10-27T15:30:00Z'; stopBegunUtc = '2026-10-27T14:59:00Z'; stopBegunJobId = $script:firstJob }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
            $script:jobs = @(@{ properties = @{ jobId = $script:firstJob; status = 'Failed'; runbook = @{ name = 'DbHub-Control' }; creationTime = '2026-10-27T14:58:30Z' } })
            $script:marks = [System.Collections.Generic.List[string]]::new()
            $script:sleepHook = { $script:marks.Add([string](($script:automationVariables['DbHubSessionStatus'] | ConvertFrom-Json).stopBegunJobId)) }
            $result = Invoke-DbHubStop -Scope All -Context (New-TestContext)
            $result.status | Should -Be 'Stopped'
            @($result.done) | Should -Not -Contain 'session 01234567''s stop still runs (job bbbbbbbb): its evidence, metrics, and status are left to it'
            $script:marks[0] | Should -Be 'aaaaaaaa-0000-0000-0000-00000000000a' -Because 'the mark names this job, read back 5 seconds later'
            $part = Get-SessionPart
            $part.Metrics | Should -BeTrue
            $part.Status | Should -BeTrue
            (Get-SessionStatus).stoppedBy | Should -Be 'Auto-stop'
        }

        It 'of two stops that mark at once, leaves the session''s part to the one whose mark stands' {
            $running = [ordered]@{ schemaVersion = 1; sessionId = $script:sessionId; phase = 'running'; updatedUtc = '2026-10-27T14:59:00Z'; runEndUtc = '2026-10-27T15:30:00Z' }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
            $other = 'cccccccc-0000-0000-0000-00000000000c'
            $script:sleepHook = {
                if ($script:sleeps -eq 1) {
                    # Another stop marked right after this one, which reads its mark back now.
                    $copy = $script:automationVariables['DbHubSessionStatus'] | ConvertFrom-Json
                    $copy.stopBegunJobId = 'cccccccc-0000-0000-0000-00000000000c'
                    $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $copy -Depth 8 -Compress
                    $script:jobs = @(@{ properties = @{ jobId = 'cccccccc-0000-0000-0000-00000000000c'; status = 'Running'; runbook = @{ name = 'DbHub-Control' }; creationTime = '2026-10-27T15:00:00Z' } })
                }
                if ($script:sleeps -eq 3) {
                    $done = [ordered]@{ schemaVersion = 1; sessionId = $script:sessionId; phase = 'stopped'; stoppedUtc = '2026-10-27T15:01:00Z'; stoppedBy = 'Stop now'; jobId = 'cccccccc-0000-0000-0000-00000000000c'; metrics = [ordered]@{ status = 'Pass' } }
                    $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $done -Depth 8 -Compress
                }
            }
            $result = Invoke-DbHubStop -Scope All -Context (New-TestContext)
            @($result.done) | Should -Contain ('session 01234567''s stop ran already (job {0}, Stop now): its evidence, metrics, and status are that stop''s' -f $other.Substring(0, 8))
            $part = Get-SessionPart
            $part.Exports | Should -Be 0
            $part.Metrics | Should -BeFalse
            $part.Status | Should -BeFalse
        }

        It 'never writes its mark over another job''s that came between its reads, and waits for that stop (review of 0d0776e4)' {
            $running = [ordered]@{ schemaVersion = 1; sessionId = $script:sessionId; phase = 'running'; updatedUtc = '2026-10-27T14:59:00Z'; runEndUtc = '2026-10-27T15:30:00Z' }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
            # Another stop's mark lands after this stop read the copy unmarked, right as it reads the copy to mark it. Written
            # over, both stops read their own marks back once this one's write is slow, and both did the whole work.
            $script:landed = $false
            $script:variableReadHook = {
                if (-not $script:landed -and @(Get-PSCallStack | Where-Object { $_.Command -eq 'Set-DbHubStopBegun' }).Count -gt 0) {
                    $script:landed = $true
                    $copy = $script:automationVariables['DbHubSessionStatus'] | ConvertFrom-Json
                    $copy | Add-Member -NotePropertyName 'stopBegunUtc' -NotePropertyValue $script:clock.ToString('yyyy-MM-ddTHH:mm:ssZ') -Force
                    $copy | Add-Member -NotePropertyName 'stopBegunJobId' -NotePropertyValue 'cccccccc-0000-0000-0000-00000000000c' -Force
                    $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $copy -Depth 8 -Compress
                    $script:jobs = @(@{ properties = @{ jobId = 'cccccccc-0000-0000-0000-00000000000c'; status = 'Running'; runbook = @{ name = 'DbHub-Control' }; creationTime = '2026-10-27T15:00:00Z' } })
                }
            }
            # That stop ends two polls later, with its status.
            $script:sleepHook = {
                if ($script:sleeps -eq 2) {
                    $done = [ordered]@{ schemaVersion = 1; sessionId = $script:sessionId; phase = 'stopped'; stoppedUtc = '2026-10-27T15:01:00Z'; stoppedBy = 'Stop now'; jobId = 'cccccccc-0000-0000-0000-00000000000c'; metrics = [ordered]@{ status = 'Pass' } }
                    $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $done -Depth 8 -Compress
                }
            }
            $context = New-TestContext
            $result = Invoke-DbHubStop -Scope All -Context $context
            $script:landed | Should -BeTrue
            @($context.Log | Where-Object { $_ -match 'Session 01234567''s stop is marked begun by job cccccccc-0000-0000-0000-00000000000c already, so this stop didn''t mark it' }) | Should -Not -BeNullOrEmpty
            @($result.done) | Should -Contain 'session 01234567''s stop ran already (job cccccccc, Stop now): its evidence, metrics, and status are that stop''s'
            $part = Get-SessionPart
            $part.Exports | Should -Be 0
            $part.Metrics | Should -BeFalse
            $part.Status | Should -BeFalse
            # Its mark's life over, it's written over as before: a stop whose job the list no longer shows does the whole work.
            Reset-TestAzure
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
            $script:groupTags = @{ DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'session'; DbHubSessionId = $script:sessionId }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
            $script:landed = $false
            $script:clock = $script:clock.AddMinutes(16)
            $script:variableReadHook = {
                if (-not $script:landed -and @(Get-PSCallStack | Where-Object { $_.Command -eq 'Set-DbHubStopBegun' }).Count -gt 0) {
                    $script:landed = $true
                    $copy = $script:automationVariables['DbHubSessionStatus'] | ConvertFrom-Json
                    $copy | Add-Member -NotePropertyName 'stopBegunUtc' -NotePropertyValue $script:clock.AddMinutes(-16).ToString('yyyy-MM-ddTHH:mm:ssZ') -Force
                    $copy | Add-Member -NotePropertyName 'stopBegunJobId' -NotePropertyValue 'cccccccc-0000-0000-0000-00000000000c' -Force
                    $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $copy -Depth 8 -Compress
                }
            }
            $script:sleepHook = $null
            $whole = Invoke-DbHubStop -Scope All -Context (New-TestContext -NowUtc $script:clock)
            $script:landed | Should -BeTrue
            $whole.status | Should -Be 'Stopped'
            (Get-SessionPart).Status | Should -BeTrue
        }
    }

    It 'keeps the session''s plan in its stopped status, from the status its start wrote, never another session''s (2026-11-19)' {
        # The control notebook's Stop now and its next Run all's pre-check rebuild the session's beats from it, to save
        # its history with them when the run that was ending it stopped first.
        $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId; requestedBy = 'presenter' }) -Context (New-TestContext)
        $running = Get-SessionStatus
        $running.phase | Should -Be 'running'
        $plan = 'acceptedUtc', 'runEndUtc', 'dispatchUtc', 't4', 'replicaLag', 't5'
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:sessionId }) -Context (New-TestContext -NowUtc $script:clock)
        $result.status | Should -Be 'Stopped'
        $stopped = Get-SessionStatus
        $stopped.phase | Should -Be 'stopped'
        $stopped.stoppedBy | Should -Be 'Stop now'
        $stopped.metrics.status | Should -Be 'Pass'
        foreach ($name in $plan) {
            (ConvertTo-Json -InputObject $stopped.$name -Depth 8 -Compress) | Should -BeExactly (ConvertTo-Json -InputObject $running.$name -Depth 8 -Compress) -Because $name
        }
        $stopped.planKept | Should -BeTrue
        $stopped.PSObject.Properties.Name | Should -Not -Contain 'steps'
        $script:automationVariables['DbHubSessionStatus'] | Should -BeExactly $script:secrets['dbhub-session-status'][-1].Value
        # A copy of another session's status (one that started since) gives a stop of this session nothing of it.
        $script:automationVariables['DbHubSessionStatus'] = '{"sessionId":"fedcba9876543210fedcba9876543210","phase":"running","acceptedUtc":"2026-10-27T18:00:00Z","runEndUtc":"2026-10-27T19:30:00Z","dispatchUtc":{"T1":"2026-10-27T18:04:00Z"}}'
        $script:groupTags['DbHubSessionId'] = $script:sessionId
        $null = Invoke-DbHubStop -Scope All -Context (New-TestContext -NowUtc $script:clock)
        $again = Get-SessionStatus
        $again.stoppedBy | Should -Be 'Auto-stop'
        $again.sessionId | Should -Be $script:sessionId
        foreach ($name in $plan) {
            $again.PSObject.Properties.Name | Should -Not -Contain $name
        }
        $again.planKept | Should -BeFalse -Because 'the notebook says the runbook didn''t find the plan, rather than that the runbooks are old'
    }

    It 'asks T4 to stop again when Azure fails its first stop right after the replica''s delete (SourceReplicasStartStopOrder, live 2026-11-14)' {
        # Live: the session's auto-stop saw the replica's 404 about 20 seconds before its delete finished, and T4's stop,
        # accepted, failed a minute later, which left T4 running.
        $script:t4 = 'Ready'
        $script:replica = 'Ready'
        $script:t4StopIgnored = 1
        $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'session'; DbHubSessionId = $script:sessionId; DbHubSessionStartUtc = '2026-10-27T13:30:00Z' }
        $context = New-TestContext
        $result = Invoke-DbHubStop -Scope All -Context $context -PollSeconds 5
        $result.status | Should -Be 'Stopped'
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/stop$' }).Count | Should -Be 2
        $script:t4 | Should -BeIn @('Stopping', 'Stopped')
        @($result.done) | Should -Contain 'pgflex01-abc123 stopping'
        @($context.Log | Where-Object { $_ -match 'is stopping after 2 stops' }) | Should -Not -BeNullOrEmpty
    }

    It 'says T4 wasn''t stopped, with the nightly safety stop as its backstop, when Azure keeps failing its stop after the replica''s delete' {
        $script:t4 = 'Ready'
        $script:replica = 'Ready'
        $script:t4StopIgnored = 99
        $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'session'; DbHubSessionId = $script:sessionId; DbHubSessionStartUtc = '2026-10-27T13:30:00Z' }
        $result = Invoke-DbHubStop -Scope All -Context (New-TestContext) -PollSeconds 5
        $result.status | Should -Be 'Partial'
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgflex01-abc123/stop$' }).Count | Should -Be 3
        @($result.failed) | Should -Contain 'pgflex01-abc123 not stopped: it was still Ready after 3 stop(s) in 10 minutes; the nightly safety stop stops it tonight'
        (Get-SessionStatus).failed | Should -Contain 'pgflex01-abc123 not stopped: it was still Ready after 3 stop(s) in 10 minutes; the nightly safety stop stops it tonight'
    }

    It 'stops the replica after T4 instead when the control identity can''t delete it yet, and leaves a deploy.ps1''s marker alone' {
        $script:t4 = 'Ready'
        $script:t4StopMinutes = 2
        $script:replica = 'Ready'
        $script:replicaDeleteForbidden = $true
        $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'deploy' }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop' }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        @($script:calls | Where-Object { $_.Path -match '/flexibleServers/pgreplica01-abc123/stop$' }).Count | Should -Be 1
        $script:replica | Should -Be 'Stopping'
        $script:groupTags['DbHubBusyBy'] | Should -Be 'deploy'
        $script:secrets.ContainsKey('dbhub-session-status') | Should -BeFalse -Because 'no session is known'
    }

    It 'never deletes a server whose replicationRole isn''t a read replica''s' {
        $script:replica = 'Ready'
        $script:replicaRole = 'Primary'
        $removed = Remove-DbHubT4Replica -Context (New-TestContext) -Tags @{ deploymentId = 'abc123' }
        $removed.Outcome | Should -Be 'NotReplica'
        @($script:calls | Where-Object Method -EQ 'DELETE') | Should -BeNullOrEmpty
    }

    It 'captures the history''s metrics on request (capture), and starts or stops nothing' {
        $script:t4 = 'Ready'
        $script:replica = 'Ready'
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'capture'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.status | Should -Be 'Captured'
        $result.replica | Should -BeTrue
        ($script:secrets['dbhub-session-metrics'][0].Value | ConvertFrom-Json).sessionId | Should -Be $script:sessionId
        @($script:calls | Where-Object { $_.Method -in 'POST', 'DELETE', 'PATCH' }) | Should -BeNullOrEmpty
    }

    It 'removes the second auto-stop with the first, so it never stops a later run' {
        $script:autostop = '2026-10-27T15:30:00Z'
        $script:backup = '2026-10-27T16:00:00Z'
        $script:links.Add([pscustomobject]@{ Id = 'dddddddd-0000-0000-0000-00000000000d'; Schedule = 'dbhub-autostop-backup'; Runbook = 'DbHub-Stop'; Parameters = @{ Scope = 'All' } })
        Clear-DbHubAutoStop -Context (New-TestContext) | Should -BeTrue
        $script:backup | Should -BeNullOrEmpty
        @($script:links | Where-Object Schedule -EQ 'dbhub-autostop-backup') | Should -BeNullOrEmpty
    }

    It 'plans the replica beat''s windows from when T4''s profile was set' {
        $set = [datetime]::new(2026, 10, 27, 15, 10, 0, [System.DateTimeKind]::Utc)
        $ninety = Get-DbHubReplicaLagPlan -ProfileSetUtc $set -RunEndUtc $set.AddMinutes(85)
        @($ninety).Count | Should -Be 1
        $ninety[0]['startUtc'] | Should -Be '2026-10-27T16:00:00Z'
        $ninety[0]['endUtc'] | Should -Be '2026-10-27T16:09:00Z'
        # The plan comes back as one array (return , $windows): assigned, never wrapped in @() again.
        $long = Get-DbHubReplicaLagPlan -ProfileSetUtc $set -RunEndUtc $set.AddMinutes(118)
        $long.Count | Should -Be 2
        $long[1]['startUtc'] | Should -Be '2026-10-27T17:00:00Z'
        $long[1]['endUtc'] | Should -Be '2026-10-27T17:06:00Z' -Because 'the runner ends 2 minutes before the run'
        $short = Get-DbHubReplicaLagPlan -ProfileSetUtc $set -RunEndUtc $set.AddMinutes(45)
        $short.Count | Should -Be 0
    }

    It 'orders the replica''s sizes as the module does, never with fewer vCores than T4''s (shared cases)' -ForEach @(
        @{ T4 = 'Standard_D4ds_v5'; Record = ''; Expected = @('Standard_D4ds_v5', 'Standard_D4ads_v5') }
        @{ T4 = 'Standard_D2ds_v5'; Record = ''; Expected = @('Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5') }
        @{ T4 = 'Standard_D4ds_v5'; Record = 'Standard_D4ads_v5@any'; Expected = @('Standard_D4ads_v5', 'Standard_D4ds_v5') }
        @{ T4 = 'Standard_D2ds_v5'; Record = 'Standard_D4ads_v5@any'; Expected = @('Standard_D2ds_v5', 'Standard_D4ads_v5', 'Standard_D4ds_v5') }
        @{ T4 = 'Standard_D4ds_v5'; Record = 'Standard_D2ds_v5@any'; Expected = @('Standard_D4ds_v5', 'Standard_D4ads_v5') }
    ) {
        $sizes = @($script:settings.t4Replica.sizes)
        @(Get-DbHubReplicaSizeOrder -T4SkuName $T4 -Record $Record -Sizes $sizes) | Should -Be $Expected
        $module = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ T4 = $T4; Record = $Record } { Get-DemoT4ReplicaSizeOrder -T4SkuName $T4 -Record $Record | ForEach-Object SkuName })
        $module | Should -Be $Expected -Because 'the runbook and the module follow the same order'
    }

    It 'combines metric points into intervals as the module does (shared cases)' {
        $points = [System.Collections.Generic.SortedDictionary[datetime, double]]::new()
        foreach ($minute in 0..9) {
            $points[[datetime]::new(2026, 10, 27, 15, $minute, 0, [System.DateTimeKind]::Utc)] = [double](($minute * 7) % 11) + 0.04
        }
        foreach ($case in @(@{ Aggregation = 'Maximum'; Unit = 'Seconds'; Interval = 5 }, @{ Aggregation = 'Total'; Unit = 'Count'; Interval = 5 }, @{ Aggregation = 'Maximum'; Unit = 'Percent'; Interval = 1 })) {
            $runbook = ConvertTo-DbHubMetricPoint -Point $points -Aggregation $case.Aggregation -Unit $case.Unit -IntervalMinutes $case.Interval
            $module = InModuleScope -ModuleName DbHubDemo -Parameters @{ Points = $points; Case = $case } { ConvertTo-DemoPostgresHistoryPoint -Point $Points -Aggregation $Case.Aggregation -Unit $Case.Unit -IntervalMinutes $Case.Interval }
            (ConvertTo-Json -InputObject $runbook -Compress) | Should -Be (ConvertTo-Json -InputObject $module -Compress) -Because ($case | ConvertTo-Json -Compress)
        }
    }
}

Describe 'T5, the Azure Cosmos DB account (2026-11-18, ADR 0027): its showcase in a session, its stop, and its metrics' {
    BeforeEach {
        Reset-TestAzure
        Mock Get-DbHubUtcNow { return $script:clock }
        Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
        Mock Invoke-DbHubArm {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body; At = $script:clock })
            return (Invoke-TestAzure -Method $Method -Path $Path -Body $Body)
        }
        $script:sessionId = '0123456789abcdef0123456789abcdef'
        $script:decodeRequest = { param($Call) @([regex]::Matches($Call.Body.properties.source.script, "-RequestBase64 '([A-Za-z0-9+/=]+)'") | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_.Groups[1].Value)) | ConvertFrom-Json }) }
    }

    It 'says when T5 is back at its baseline after its last ru-storm, as the runner plans it: a profile of <Profile> minutes, minute <Expected> (risk R896)' -ForEach @(
        @{ Profile = 90; Expected = 88 }
        @{ Profile = 88; Expected = 88 }
        @{ Profile = 87; Expected = 75 }
        @{ Profile = 75; Expected = 75 }
        @{ Profile = 74; Expected = 58 }
        @{ Profile = 31; Expected = 28 }
        @{ Profile = 27; Expected = 15 }
        @{ Profile = 15; Expected = 15 }
        @{ Profile = 14; Expected = 0 }
        @{ Profile = 0; Expected = 0 }
    ) {
        # The showcase's T5 slots, baked from scenarios/activity-profiles.json: ru-storm from minute 3 for 10 minutes and from
        # minute 18 for 8, each with 2 minutes of recovery, in every 30-minute cycle; one runs only when it and its recovery
        # end by the profile's end.
        $slots = @($script:settings.profiles.showcase.t5Slots)
        @($slots | ForEach-Object { '{0}+{1}+{2}' -f $_.startMinute, $_.durationMinutes, $_.recoveryMinutes }) | Should -Be @('3+10+2', '18+8+2')
        Get-DbHubT5LastStormMinute -ProfileMinutes $Profile -CycleMinutes 30 -Slot $slots | Should -Be $Expected
    }

    It 'clips a T5 slot without recoveryMinutes at the profile''s end, as the runner does' {
        $slots = @([pscustomobject]@{ startMinute = 3; durationMinutes = 10; recoveryMinutes = $null }, [pscustomobject]@{ startMinute = 18; durationMinutes = 8 })
        Get-DbHubT5LastStormMinute -ProfileMinutes 87 -CycleMinutes 30 -Slot $slots | Should -Be 86
        Get-DbHubT5LastStormMinute -ProfileMinutes 80 -CycleMinutes 30 -Slot $slots | Should -Be 80
    }

    It 'runs T5''s showcase the whole run, and says at its dispatch when T5 is back at its baseline after its last ru-storm; other activities are left alone (risk R896)' {
        $now = [datetime]::new(2026, 10, 27, 15, 4, 0, [System.DateTimeKind]::Utc)
        $notAfter = [datetime]::new(2026, 10, 27, 16, 32, 0, [System.DateTimeKind]::Utc)
        $t5 = [pscustomobject]@{ Target = 'T5'; Scenario = 'showcase'; Intensity = 0; Concurrency = 0; Minutes = 90; NotAfterUtc = $notAfter }
        # The profile ends at 16:30, the runner's 2 minutes before --not-after: 86 minutes from 15:04, less 2 for its Run Command,
        # 84, so the third cycle's second ru-storm (minutes 78 to 86, and 2 of recovery) doesn't run, and T5 is back at its
        # baseline at minute 75 of its profile, after the first one. Its profile starts when the Run Command sets it, at most 2
        # minutes after the dispatch, so that's by minute 77 from the dispatch (review of ab91ee5).
        Get-DbHubT5LastStormEnd -Settings $script:settings -Activity $t5 -NowUtc $now | Should -Be $now.AddMinutes(77)
        $t5.Minutes | Should -Be 90 -Because 'nothing is cut: T5''s baseline runs on until the run ends'
        # A profile whose own minutes end first: 60, less 2, is 58, the end of the second cycle's second storm and its recovery,
        # by minute 60 from the dispatch.
        $short = [pscustomobject]@{ Target = 'T5'; Scenario = 'showcase'; Intensity = 0; Concurrency = 0; Minutes = 60; NotAfterUtc = $notAfter }
        Get-DbHubT5LastStormEnd -Settings $script:settings -Activity $short -NowUtc $now | Should -Be $now.AddMinutes(60)
        foreach ($other in @(
                [pscustomobject]@{ Target = 'T1'; Scenario = 'showcase'; Intensity = 0; Concurrency = 0; Minutes = 90; NotAfterUtc = $notAfter }
                [pscustomobject]@{ Target = 'T5'; Scenario = 'ru-storm'; Intensity = 0; Concurrency = 0; Minutes = 10; NotAfterUtc = $null }
                [pscustomobject]@{ Target = 'T5'; Scenario = 'baseline'; Intensity = 0; Concurrency = 0; Minutes = 30; NotAfterUtc = $notAfter })) {
            $minutes = $other.Minutes
            Get-DbHubT5LastStormEnd -Settings $script:settings -Activity $other -NowUtc $now | Should -BeNullOrEmpty
            $other.Minutes | Should -Be $minutes
        }
    }

    It 'creates T5''s container while the VMs start, sends T5''s showcase for the whole session with sqlvm01''s, and says both on the status (2026-11-19)' {
        $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubT5Container = 'Session' }
        $script:t5Container = ''
        $script:t4 = 'Stopped'
        $script:t4Sku = 'Standard_D4ds_v5'
        $script:t4Tier = 'GeneralPurpose'
        $script:t4ReadyAt = $script:clock.AddMinutes(4)
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.status | Should -Be 'Started'
        $script:t5Container | Should -Be 'Present'
        # The container's create goes out after the VMs' starts, so it overlaps them, and before sqlvm01's dispatch.
        $create = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/containers/patient-events$' })
        $create.Count | Should -Be 1
        $sqlvm = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/virtualMachines/sqlvm01/runCommands/DbHubControl-sqlvm01-\d' }) | Select-Object -First 1
        $vmStart = @($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/virtualMachines/sqlvm01/start$' }) | Select-Object -First 1
        $script:calls.IndexOf($vmStart) | Should -BeLessThan $script:calls.IndexOf($create[0])
        $script:calls.IndexOf($create[0]) | Should -BeLessThan $script:calls.IndexOf($sqlvm)
        $writes = $script:secrets['dbhub-session-status']
        $status = $writes[$writes.Count - 1].Value | ConvertFrom-Json
        $status.names.t5Account | Should -Be 'cosmos01-abc123'
        $dispatch = ConvertTo-DbHubUtc -Value $status.dispatchUtc.T5
        $dispatch | Should -Be (ConvertTo-DbHubUtc -Value $status.dispatchUtc.T1) -Because 'T5 goes with sqlvm01''s targets'
        # The container took 30 seconds, so sqlvm01's activity went out at 15:00:30.
        $dispatch | Should -Be ([datetime]::new(2026, 10, 27, 15, 0, 30, [System.DateTimeKind]::Utc))
        # T5's request in sqlvm01's Run Command: its showcase, for the whole session, as every target's.
        $request = @(& $script:decodeRequest $sqlvm) | Where-Object target -EQ 'T5'
        @($request).Count | Should -Be 1
        $arguments = @($request.arguments)
        $arguments[0..3] | Should -Be @('profile', 'set', '--name', 'showcase')
        $arguments[[array]::IndexOf($arguments, '--duration') + 1] | Should -Be '90m'
        @($status.dispatched) | Should -Contain 'T5: showcase for 90 minutes'
        # The session ends at 16:30; from 15:00:30 the profile has 89 minutes, less 2 for its Run Command, 87: the third
        # cycle's second ru-storm and its recovery (to minute 88) don't fit, so T5 is back at its baseline at minute 75 of its
        # profile, which starts at most 2 minutes after the dispatch: by 16:17:30.
        $t5End = ConvertTo-DbHubUtc -Value $status.t5.endUtc
        $t5End | Should -Be $dispatch.AddMinutes(77)
        $steps = @($status.steps | Where-Object step -EQ 'T5')
        @($steps | ForEach-Object state) | Should -Be @('Pass', 'Pass')
        $steps[0].message | Should -Be 'T5''s container contosocare/patient-events (cosmos01-abc123) was created for this session, with its 400 RU/s; the stop at its end deletes it, so it bills only while the demo runs.'
        $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
        $endText = [System.TimeZoneInfo]::ConvertTimeFromUtc($t5End, $zone).ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        $runEndText = [System.TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-DbHubUtc -Value $status.runEndUtc), $zone).ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        $steps[1].message | Should -Be ('T5 (cosmos01-abc123): its last ru-storm ends, and T5 is back at its baseline, with no throttled requests (429s), by {0} (Eastern Standard Time); its baseline runs on until the session ends at {1}, and the next Run all starts its ru-storm cycles again from the first.' -f $endText, $runEndText)
    }

    It 'runs the session without T5 when its container can''t be created, and says why with the fix (2026-11-19)' {
        $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubT5Container = 'Session' }
        $script:t5Container = ''
        $script:t5ContainerForbidden = @('PUT')
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.status | Should -Be 'Partial'
        @($result.skipped) | Should -Contain 'T5 (its container isn''t there: the session control''s role can''t create it yet; an Owner runs ./scripts/grant-safety-stop.ps1)'
        $writes = $script:secrets['dbhub-session-status']
        $status = $writes[$writes.Count - 1].Value | ConvertFrom-Json
        $status.phase | Should -Be 'running'
        $step = @($status.steps | Where-Object step -EQ 'T5')
        $step.Count | Should -Be 1
        $step[0].state | Should -Be 'Fail'
        $step[0].message | Should -Be 'T5''s container contosocare/patient-events (cosmos01-abc123) couldn''t be read or created: the session control''s role doesn''t have the container''s actions yet, so T5 gets no activity in this session; the other targets go on.'
        $step[0].fix | Should -Be 'An Owner runs ./scripts/grant-safety-stop.ps1 once, which gives the session control its role; then Run all again. ./scripts/start-demo.ps1 creates the container too.'
        # T5's activity isn't sent; the other targets' is.
        $sqlvm = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/virtualMachines/sqlvm01/runCommands/DbHubControl-sqlvm01-\d' }) | Select-Object -First 1
        @(& $script:decodeRequest $sqlvm | ForEach-Object target) | Should -Be @('T1', 'T3')
        @($status.dispatched) | Should -Not -Contain 'T5: showcase for 90 minutes'
        @($status.dispatched) | Should -Contain 'T1: showcase for 90 minutes'
    }

    It 'neither reads nor creates T5''s container when it stays between sessions (<Lifecycle>), and still sends T5 its showcase (2026-11-19: a non-Owner''s control role)' -ForEach @(@{ Lifecycle = 'AlwaysOn' }, @{ Lifecycle = '' }) {
        $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubT5Container = $Lifecycle }
        $script:t5Container = 'Present'
        # The control's role has no container actions yet: any container call would be refused.
        $script:t5ContainerForbidden = @('GET', 'PUT', 'DELETE')
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId }) -Context (New-TestContext)
        @($result.skipped | Where-Object { $_ -like 'T5 *' }) | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Path -match '/containers/patient-events' }) | Should -BeNullOrEmpty
        $writes = $script:secrets['dbhub-session-status']
        $status = $writes[$writes.Count - 1].Value | ConvertFrom-Json
        @($status.dispatched) | Should -Contain 'T5: showcase for 90 minutes'
        $step = @($status.steps | Where-Object step -EQ 'T5') | Select-Object -First 1
        $step.state | Should -Be 'Pass'
        $step.message | Should -Match 'stays between sessions \(.+\), so this session uses it as it is\.$'
    }

    It 'makes sure T5''s container is there: there already, or created once Azure has read it back, through its GET only (2026-11-19)' {
        $tags = @{ deploymentId = 'abc123'; solution = 'fabric-database-hub-demo'; environment = 'demo'; owner = 'presenter@contoso.example'; purpose = 'demo'; costCenter = 'cc-1'; autoShutdown = '1900'; expiresOn = '2026-12-31'; component = 'demo'; DbHubBusyBy = 'session'; DbHubT5Container = 'Session' }
        $present = New-DbHubT5Container -Context (New-TestContext) -Tags $tags
        $present.Outcome | Should -Be 'Present'
        $present.Name | Should -Be 'contosocare/patient-events'
        @($script:calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
        $script:t5Container = ''
        $script:calls.Clear()
        $created = New-DbHubT5Container -Context (New-TestContext) -Tags $tags
        $created.Outcome | Should -Be 'Created'
        $created.Throughput | Should -Be 400
        ($script:clock - [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc)).TotalSeconds | Should -Be 30 -Because 'it reads the container again every 10 seconds until Azure has created it'
        @($script:calls | ForEach-Object Method) | Should -Be @('GET', 'PUT', 'GET', 'GET', 'GET', 'GET')
        @($script:calls | Where-Object { $_.Path -notmatch '/providers/Microsoft\.DocumentDB/databaseAccounts/cosmos01-abc123/sqlDatabases/contosocare/containers/patient-events$' }) | Should -BeNullOrEmpty -Because 'never the asynchronous operation''s URL, which is outside the role'
        # The body: config/versions.json's definition, as cosmos01.bicep creates it, with the demo's own tags only.
        $body = $script:t5ContainerBody
        @($body['tags'].Keys | Sort-Object) | Should -Be @('autoShutdown', 'costCenter', 'deploymentId', 'environment', 'expiresOn', 'owner', 'purpose', 'solution')
        $body['tags']['deploymentId'] | Should -Be 'abc123'
        $body['tags']['owner'] | Should -Be 'presenter@contoso.example'
        $resource = $body['properties']['resource']
        $resource['id'] | Should -Be 'patient-events'
        @($resource['partitionKey']['paths']) | Should -Be @('/patientId')
        $resource['partitionKey']['kind'] | Should -Be 'Hash'
        $resource['partitionKey']['version'] | Should -Be 2
        $resource['indexingPolicy'].indexingMode | Should -Be 'consistent'
        @($resource['indexingPolicy'].excludedPaths | ForEach-Object path) | Should -Be @('/payload/?', '/"_etag"/?')
        $body['properties']['options']['throughput'] | Should -Be 400
    }

    It 'asks again while Azure still deletes the last container (a conflict), then creates it (2026-11-19)' {
        $script:t5Container = ''
        $script:t5ContainerConflicts = 2
        $created = New-DbHubT5Container -Context (New-TestContext) -Tags @{ deploymentId = 'abc123' }
        $created.Outcome | Should -Be 'Created'
        @($script:calls | Where-Object Method -EQ 'PUT').Count | Should -Be 3
    }

    It 'reports <Case> as NotGranted, with nothing created (2026-11-19)' -ForEach @(
        @{ Case = 'a container it can''t read'; Forbidden = @('GET', 'PUT', 'DELETE'); Puts = 0 }
        @{ Case = 'a create Azure refuses (403)'; Forbidden = @('PUT'); Puts = 1 }
    ) {
        $script:t5Container = ''
        $script:t5ContainerForbidden = $Forbidden
        $outcome = New-DbHubT5Container -Context (New-TestContext) -Tags @{ deploymentId = 'abc123' }
        $outcome.Outcome | Should -Be 'NotGranted'
        @($script:calls | Where-Object Method -EQ 'PUT').Count | Should -Be $Puts
        $script:t5Container | Should -Be ''
    }

    It 'keeps T5''s container, and sends nothing, when its lifecycle isn''t Session: <Lifecycle> (2026-11-19)' -ForEach @(
        @{ Lifecycle = 'AlwaysOn'; Reason = 'the session control''s role can''t create it yet, so its throughput keeps billing; an Owner runs ./scripts/grant-safety-stop.ps1 once' }
        @{ Lifecycle = ''; Reason = 'this environment was deployed before T5''s container lived only during a session, so its throughput keeps billing; ./scripts/deploy.ps1 sets that up' }
        @{ Lifecycle = 'session'; Reason = 'this environment was deployed before T5''s container lived only during a session, so its throughput keeps billing; ./scripts/deploy.ps1 sets that up' }
    ) {
        $kept = Remove-DbHubT5Container -Context (New-TestContext) -Tags @{ deploymentId = 'abc123'; DbHubT5Container = $Lifecycle }
        $kept.Outcome | Should -Be 'Kept'
        $kept.Reason | Should -Be $Reason
        Get-DbHubT5ContainerText -Outcome $kept | Should -Be ('T5''s container kept between sessions ({0})' -f $Reason)
        $script:calls.Count | Should -Be 0
        $script:t5Container | Should -Be 'Present'
    }

    It 'deletes T5''s container while its lifecycle is Session and waits until it''s gone, says when it''s already gone, and reports a delete it isn''t granted (2026-11-19)' {
        $tags = @{ deploymentId = 'abc123'; DbHubT5Container = 'Session' }
        $deleted = Remove-DbHubT5Container -Context (New-TestContext) -Tags $tags
        $deleted.Outcome | Should -Be 'Deleted'
        Get-DbHubT5ContainerText -Outcome $deleted | Should -Be 'T5''s container deleted (its 400 RU/s stop billing until the next session creates it)'
        $script:t5Container | Should -Be ''
        @($script:calls | ForEach-Object Method) | Should -Be @('GET', 'DELETE', 'GET', 'GET', 'GET')
        $script:calls.Clear()
        $missing = Remove-DbHubT5Container -Context (New-TestContext) -Tags $tags
        $missing.Outcome | Should -Be 'Missing'
        Get-DbHubT5ContainerText -Outcome $missing | Should -Be 'T5''s container already gone'
        @($script:calls | ForEach-Object Method) | Should -Be @('GET') -Because 'nothing is written when there''s nothing to delete'
        $script:t5Container = 'Present'
        $script:t5ContainerForbidden = @('DELETE')
        $refused = Remove-DbHubT5Container -Context (New-TestContext) -Tags $tags
        $refused.Outcome | Should -Be 'NotGranted'
        Get-DbHubT5ContainerText -Outcome $refused | Should -Be 'T5''s container kept: this identity''s role lacks the container''s actions (./scripts/stop-demo.ps1 deletes it if it''s there; an Owner runs ./scripts/grant-safety-stop.ps1 once)'
        $script:t5Container | Should -Be 'Present'
        # Without T5 in the settings, or without the group's deploymentId: nothing to say, and nothing sent.
        $script:calls.Clear()
        (Remove-DbHubT5Container -Context (New-TestContext) -Tags @{ DbHubT5Container = 'Session' }).Outcome | Should -Be 'NotConfigured'
        Get-DbHubT5ContainerText -Outcome ([pscustomobject]@{ Outcome = 'NotConfigured' }) | Should -BeNullOrEmpty
        $script:calls.Count | Should -Be 0
    }

    It 'deletes T5''s container on Stop now when its lifecycle is Session, and keeps it, saying why, when it''s AlwaysOn (2026-11-19)' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $script:groupTags = @{ DbHubT5Container = 'Session' }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop' }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        @($result.done) | Should -Contain 'T5''s container deleted (its 400 RU/s stop billing until the next session creates it)'
        $script:t5Container | Should -Be ''
        # After sqlvm01's deallocation, whose runner drives T5.
        $deallocate = @($script:calls | Where-Object { $_.Path -match '/sqlvm01/deallocate$' }) | Select-Object -First 1
        $delete = @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/containers/patient-events$' }) | Select-Object -First 1
        $script:calls.IndexOf($deallocate) | Should -BeLessThan $script:calls.IndexOf($delete)
        Reset-TestAzure
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $script:groupTags = @{ DbHubT5Container = 'AlwaysOn' }
        $kept = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop' }) -Context (New-TestContext)
        $kept.status | Should -Be 'Stopped'
        @($kept.done) | Should -Contain 'T5''s container kept between sessions (the session control''s role can''t create it yet, so its throughput keeps billing; an Owner runs ./scripts/grant-safety-stop.ps1 once)'
        @($script:calls | Where-Object { $_.Path -match 'databaseAccounts' }) | Should -BeNullOrEmpty
        $script:t5Container | Should -Be 'Present'
    }

    It 'deletes again the T5 container a run created when it stops what it started, and lists one it didn''t start as left running (#27, 2026-11-19)' {
        $script:groupTags = @{ DbHubT5Container = 'Session' }
        $script:t5Container = ''
        $script:runCommandRefused = @('sqlvm01')
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'run'; activities = @(@{ target = 'T5'; scenario = 'ru-storm' }); durationMinutes = 20 }) -Context (New-TestContext)
        $result.status | Should -Be 'Failed'
        $result.t5Container | Should -Be 'Created'
        $result.message | Should -Match 'so this run stopped what it started: auto-stop removed, sqlvm01 deallocating, T5''s container deleted \(its 400 RU/s stop billing until the next session creates it\)\.$'
        $script:t5Container | Should -Be ''
        # One it didn't create, while sqlvm01 ran before: left as it was, and said.
        Reset-TestAzure
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $script:groupTags = @{ DbHubT5Container = 'Session' }
        $left = Get-DbHubLeftRunning -Context (New-TestContext) -Tags @{ deploymentId = 'abc123'; DbHubT5Container = 'Session' }
        $left.Text | Should -Match '^This run didn''t start sqlvm01 \(running\) and T5''s container \(its throughput bills\), so it left them running'
        (Get-DbHubLeftRunning -Context (New-TestContext) -Tags @{ deploymentId = 'abc123'; DbHubT5Container = 'AlwaysOn' }).Text | Should -Not -Match 'T5'
    }

    It 'skips a reset of T5 when its container isn''t there, with a note (2026-11-19)' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $script:t5Container = ''
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'reset' }) -Context (New-TestContext)
        $result.status | Should -Be 'Dispatched'
        @($result.dispatched) | Should -Be @('T1', 'T3')
        @($result.skipped) | Should -Contain 'T5 (its container isn''t there between sessions, so there''s nothing to reset; the next session creates it)'
    }
    It 'saves T5''s metrics with T4''s in the metrics secret, as its cosmos member, the throttled requests read with StatusCode 429' {
        $script:t4 = 'Ready'
        $script:replica = 'Ready'
        $script:cosmos = @{}
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'capture'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.status | Should -Be 'Captured'
        $result.cosmos | Should -BeTrue
        $secret = $script:secrets['dbhub-session-metrics'][0]
        $secret.Tags['t5'] | Should -Be 'yes'
        [System.Text.Encoding]::UTF8.GetByteCount($secret.Value) | Should -BeLessOrEqual 24000
        $secret.Value | Should -Not -Match '(?i)/subscriptions/|resourceGroups|management\.azure\.com'
        $document = $secret.Value | ConvertFrom-Json
        @($document.servers | ForEach-Object role) | Should -Be @('primary', 'replica')
        $cosmos = $document.cosmos
        $cosmos.version | Should -Be 1
        $cosmos.sessionId | Should -Be $script:sessionId
        $cosmos.capturedBy | Should -Be 'control'
        @($cosmos.accounts | ForEach-Object { '{0}={1}' -f $_.target, $_.resourceName }) | Should -Be @('T5=cosmos01-abc123')
        @($cosmos.series | ForEach-Object metric) | Should -Be @('NormalizedRUConsumption', 'TotalRequestUnits', 'TotalRequests', 'ThrottledRequests', 'ServerSideLatencyGateway', 'ProvisionedThroughput', 'ServiceAvailability')
        $throttled = @($cosmos.series) | Where-Object metric -EQ 'ThrottledRequests'
        $throttled.statusCode | Should -Be '429'
        $throttled.aggregation | Should -Be 'Count'
        @($throttled.points | ForEach-Object { $_[1] }) | Should -Be @(120)
        @(@($cosmos.series) | Where-Object metric -EQ 'NormalizedRUConsumption' | ForEach-Object { $_.points } | ForEach-Object { $_[1] }) | Should -Be @(35, 100, 40)
        (@($cosmos.series) | Where-Object metric -EQ 'ProvisionedThroughput').intervalMinutes | Should -Be 60
        @($script:calls | Where-Object { $_.Path -match 'databaseAccounts/cosmos01-abc123/providers/Microsoft\.Insights/metrics\?.*\$filter=StatusCode%20eq%20%27429%27' }).Count | Should -Be 1

        # Without T5's account, the secret is T4's document alone, as before.
        Reset-TestAzure
        $script:t4 = 'Ready'
        $script:replica = 'Ready'
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'capture'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.status | Should -Be 'Captured'
        $result.cosmos | Should -BeFalse
        $script:secrets['dbhub-session-metrics'][0].Tags['t5'] | Should -Be 'no'
        ($script:secrets['dbhub-session-metrics'][0].Value | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'cosmos'

        # T5's alone, without T4: an empty T4 document carries it, which the notebook reads as no T4 metrics.
        Reset-TestAzure
        $script:cosmos = @{}
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'capture'; sessionId = $script:sessionId }) -Context (New-TestContext)
        $result.cosmos | Should -BeTrue
        $alone = $script:secrets['dbhub-session-metrics'][0].Value | ConvertFrom-Json
        @($alone.series).Count | Should -Be 0
        @($alone.servers).Count | Should -Be 0
        $alone.sessionId | Should -Be $script:sessionId
        @($alone.cosmos.series).Count | Should -Be 7
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
        # T5's container as between sessions in an environment on the current code (2026-11-19): its lifecycle is Session, and
        # the session's stop deleted it.
        $script:groupTags['DbHubT5Container'] = 'Session'
        $script:t5Container = ''
    }

    It 'deallocates the running VMs and stops a running T4, through Azure Resource Manager only, and starts nothing' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        $script:t4 = 'Ready'
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.action | Should -Be 'stop-nightly'
        $result.status | Should -Be 'Stopped'
        $result.message | Should -Be 'Nightly safety stop: sqlvm01 deallocated (was running), archost01 deallocated (was running), T4 stopped (was Ready), T5''s container already gone.'
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
        $result.message | Should -Be ('Nightly safety stop: {0}, T5''s container already gone.' -f $Text)
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
        $result.message | Should -Be 'Nightly safety stop: sqlvm01 already deallocated, archost01 already deallocated, T4 already stopped, T4''s read replica pgreplica01-abc123 already stopped (a session left it behind; ./scripts/stop-demo.ps1 deletes it), T5''s container already gone.'
        Get-TestWrite | Should -BeNullOrEmpty
        $script:calls.Clear()
        $script:replica = ''
        (Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)).message | Should -Be 'Nightly safety stop: sqlvm01 already deallocated, archost01 already deallocated, T4 already stopped, T5''s container already gone.'
    }

    It 'deletes T5''s container a session''s stop didn''t, after the VMs and T4, keeps it unless its lifecycle is Session, and reports a delete it isn''t granted apart from its status (2026-11-19)' {
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $script:t4 = 'Ready'
        $script:t5Container = 'Present'
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.t5 | Should -Be 'T5''s container deleted (its 400 RU/s stop billing until the next session creates it)'
        $result.message | Should -Be 'Nightly safety stop: sqlvm01 deallocated (was running), archost01 already deallocated, T4 stopped (was Ready), T5''s container deleted (its 400 RU/s stop billing until the next session creates it).'
        $script:t5Container | Should -Be ''
        @(Get-TestWrite | ForEach-Object { '{0} {1}' -f $_.Method, ($_.Path -replace '^.*/providers/', '') }) | Should -Be @('POST Microsoft.Compute/virtualMachines/sqlvm01/deallocate', 'POST Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123/stop', 'DELETE Microsoft.DocumentDB/databaseAccounts/cosmos01-abc123/sqlDatabases/contosocare/containers/patient-events')
        # AlwaysOn: kept, nothing sent.
        $script:calls.Clear()
        $script:t5Container = 'Present'
        $script:groupTags['DbHubT5Container'] = 'AlwaysOn'
        $kept = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $kept.status | Should -Be 'Stopped'
        $kept.t5 | Should -Be 'T5''s container kept between sessions (the session control''s role can''t create it yet, so its throughput keeps billing; an Owner runs ./scripts/grant-safety-stop.ps1 once)'
        @($script:calls | Where-Object { $_.Path -match 'databaseAccounts' }) | Should -BeNullOrEmpty
        # Without the role's container actions: kept, and said in t5Status, apart from the job's status (review of ab91ee5).
        $script:calls.Clear()
        $script:groupTags['DbHubT5Container'] = 'Session'
        $script:t5ContainerForbidden = @('DELETE')
        $refused = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $refused.status | Should -Be 'Stopped'
        @($refused.failed) | Should -BeNullOrEmpty
        $refused.t5Status | Should -Be 'NotGranted'
        $refused.t5 | Should -Be 'T5''s container kept: this identity''s role lacks the container''s actions (./scripts/stop-demo.ps1 deletes it if it''s there; an Owner runs ./scripts/grant-safety-stop.ps1 once)'
        $script:t5Container | Should -Be 'Present'
    }

    It 'keeps T5''s container apart from the status of the nightly stop, the daily T4 stop, and the auto-stop when its role lacks the container''s actions, so T4''s stop still counts (review of ab91ee5, R910)' {
        # The shared role written back to its 7 actions by older code (R910): a 403 on the container's GET, whether or not
        # it exists. The VMs and T4 stop as usual, so each job says Stopped (or Skipped), which the cost check of T4's
        # restart reads (Get-DemoT4RestartCoverage).
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $script:t4 = 'Ready'
        $script:t5Container = ''
        $script:t5ContainerForbidden = @('GET', 'PUT', 'DELETE')
        $nightly = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $nightly.status | Should -Be 'Stopped'
        @($nightly.failed) | Should -BeNullOrEmpty
        $nightly.t5Status | Should -Be 'NotGranted'
        $nightly.message | Should -Be 'Nightly safety stop: sqlvm01 deallocated (was running), archost01 already deallocated, T4 stopped (was Ready), T5''s container kept: this identity''s role lacks the container''s actions (./scripts/stop-demo.ps1 deletes it if it''s there; an Owner runs ./scripts/grant-safety-stop.ps1 once).'
        $nightly.message | Should -Not -Match 'keeps billing'
        Reset-TestAzure
        $script:groupTags['DbHubT5Container'] = 'Session'
        $script:t5ContainerForbidden = @('GET', 'PUT', 'DELETE')
        $script:t4 = 'Ready'
        $daily = Invoke-DbHubStop -Scope T4 -Context (New-TestContext)
        $daily.status | Should -Be 'Stopped'
        $daily.t5Status | Should -Be 'NotGranted'
        $script:t4 = 'Stopped'
        $stopped = Invoke-DbHubStop -Scope T4 -Context (New-TestContext)
        $stopped.status | Should -Be 'Skipped' -Because 'T4 was stopped already and nothing else was'
        $stopped.message | Should -Be 'T4 is Stopped. T5''s container kept: this identity''s role lacks the container''s actions (./scripts/stop-demo.ps1 deletes it if it''s there; an Owner runs ./scripts/grant-safety-stop.ps1 once).'
        Reset-TestAzure
        $script:groupTags['DbHubT5Container'] = 'Session'
        $script:t5ContainerForbidden = @('GET', 'PUT', 'DELETE')
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $script:t4 = 'Ready'
        $auto = Invoke-DbHubStop -Scope All -Context (New-TestContext)
        $auto.status | Should -Be 'Stopped'
        @($auto.failed) | Should -BeNullOrEmpty
        $auto.t5Status | Should -Be 'NotGranted'
        @($auto.done) | Should -Contain 'T5''s container kept: this identity''s role lacks the container''s actions (./scripts/stop-demo.ps1 deletes it if it''s there; an Owner runs ./scripts/grant-safety-stop.ps1 once)'
    }

    It 'leaves T5''s container alone when a session started sqlvm01 again while the nightly stop waited for T4 (review of ab91ee5)' {
        # The nightly stop read the busy marker once, at its start; a presenter's Run all right after the auto-shutdown
        # starts sqlvm01 while the nightly stop waits for a starting T4, and its session uses the container.
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $script:t4 = 'Starting'
        $script:t4ReadyAt = $script:clock.AddMinutes(4)
        $script:t5Container = 'Present'
        $script:sessionAt = $script:clock.AddMinutes(2)
        Mock Start-Sleep {
            $script:clock = $script:clock.AddSeconds($Seconds)
            if ($script:clock -ge $script:sessionAt -and $script:vm['sqlvm01'] -eq 'deallocating') {
                $script:vm['sqlvm01'] = 'starting'
            }
        }
        $result = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.t5Status | Should -Be 'InUse'
        $result.t5 | Should -Be 'T5''s container left alone: sqlvm01 is starting, so a session may use it'
        @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match 'databaseAccounts' }) | Should -BeNullOrEmpty
        $script:t5Container | Should -Be 'Present'
        # Once sqlvm01 is down for good, the next pass deletes it.
        $script:vm['sqlvm01'] = 'deallocated'
        (Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)).t5Status | Should -Be 'Deleted'
        $script:t5Container | Should -Be ''
        # A container kept between sessions (AlwaysOn) is said as kept, whatever sqlvm01 does: nothing would delete it.
        $script:groupTags['DbHubT5Container'] = 'AlwaysOn'
        $script:t5Container = 'Present'
        $script:vm['sqlvm01'] = 'running'
        $script:deallocateStatus['sqlvm01'] = 409
        $kept = Invoke-DbHubStop -Scope Nightly -Context (New-TestContext)
        $kept.t5Status | Should -Be 'Kept'
        $kept.t5 | Should -Match '^T5''s container kept between sessions \('
    }

    It 'deletes T5''s container in the control''s daily T4 stop too, only while sqlvm01 doesn''t run (2026-11-19)' {
        $script:t4 = 'Stopped'
        $script:t5Container = 'Present'
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
        $busy = Invoke-DbHubStop -Scope T4 -Context (New-TestContext)
        $busy.status | Should -Be 'Skipped'
        $busy.message | Should -Be 'T4 is Stopped; nothing to stop.'
        @($script:calls | Where-Object { $_.Path -match 'databaseAccounts' }) | Should -BeNullOrEmpty -Because 'a run on sqlvm01 may use it'
        $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'deallocated' }
        $result = Invoke-DbHubStop -Scope T4 -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.message | Should -Be 'T4 is Stopped. T5''s container deleted (its 400 RU/s stop billing until the next session creates it).'
        $result.t5 | Should -Be 'T5''s container deleted (its 400 RU/s stop billing until the next session creates it)'
        $script:t5Container | Should -Be ''
        (Invoke-DbHubStop -Scope T4 -Context (New-TestContext)).status | Should -Be 'Skipped' -Because 'T4 stopped and the container gone: nothing was stopped now'
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

        It 'moves start-demo.ps1''s auto-stop to 5 minutes after a deploy.ps1 run that''s still going, keeping its mark, and stops nothing now (2026-11-19)' {
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
            $script:groupTags = @{ DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'deploy' }
            $script:autostop = '2026-10-27T15:00:00Z'
            $script:autostopDescription = '[start-demo.ps1] Stops the demo 4 hours after this start: the start-demo.ps1 session started at 2026-10-27T11:00:00Z.'
            $result = Invoke-DbHubStop -Scope All -Context (New-TestContext)
            $result.status | Should -Be 'Deferred'
            $result.message | Should -Be 'Deferred: deploy.ps1 is still running (busy until 2026-10-27T15:45:00Z), so start-demo.ps1''s auto-stop stopped nothing now; it stops the demo at 2026-10-27T15:50:00Z.'
            $script:autostop | Should -Be '2026-10-27T15:50:00Z'
            $script:autostopDescription.StartsWith('[start-demo.ps1] ', [System.StringComparison]::Ordinal) | Should -BeTrue
            $script:backupDescription.StartsWith('[start-demo.ps1] ', [System.StringComparison]::Ordinal) | Should -BeTrue
            @($script:links | Where-Object { $_.Schedule -eq 'dbhub-autostop' -and $_.Runbook -eq 'DbHub-Stop' }).Count | Should -Be 1
            @($script:calls | Where-Object { $_.Path -match '/deallocate$' }) | Should -BeNullOrEmpty
        }

        It 'never moves the stop that stop-demo.ps1 hands the control: a person asked for it now (2026-11-22)' {
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
            $script:groupTags = @{ DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'deploy' }
            $script:autostop = '2026-10-27T15:00:00Z'
            $script:autostopDescription = '[start-demo.ps1] Stops the demo 4 hours after this start: the start-demo.ps1 session started at 2026-10-27T11:00:00Z.'
            $result = Invoke-DbHubStop -Scope All -Context (New-TestContext) -RequestedBy 'stop-demo.ps1'
            $result.status | Should -Be 'Stopped'
            @($script:calls | Where-Object { $_.Path -match '/sqlvm01/deallocate$' }).Count | Should -Be 1
            @($script:calls | Where-Object { $_.Path -match '/archost01/deallocate$' }).Count | Should -Be 1
        }

        It 'stops at once for <Case>' -ForEach @(
            @{ Case = 'a session''s auto-stop from the control notebook while deploy.ps1 runs'; Description = 'Stops the demo after the on-demand run that job aaaaaaaa started (ADR 0020).'; By = 'deploy' }
            @{ Case = 'start-demo.ps1''s auto-stop once deploy.ps1 has ended (its grace period)'; Description = '[start-demo.ps1] Stops the demo 4 hours after this start.'; By = 'deploy-grace' }
            @{ Case = 'start-demo.ps1''s auto-stop without a busy marker'; Description = '[start-demo.ps1] Stops the demo 4 hours after this start.'; By = '' }
        ) {
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
            if ($By) {
                $script:groupTags = @{ DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = $By }
            }
            $script:autostop = '2026-10-27T15:00:00Z'
            $script:autostopDescription = $Description
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
        # T5's container (2026-11-19, ADR 0027): the names, throughput, and API version the nightly stop deletes it with.
        $settings.t5AccountPrefix | Should -Be 'cosmos01-'
        '{0}/{1} {2}' -f $settings.t5Container.databaseName, $settings.t5Container.containerName, $settings.t5Container.throughput | Should -Be 'contosocare/patient-events 400'
        $settings.apiVersions.'Microsoft.DocumentDB/databaseAccounts' | Should -Be '2025-10-15'
        Get-DbHubT5ContainerPath -Settings $settings -Tags @{ deploymentId = 'abc123' } | Should -Be ($script:demo + '/providers/Microsoft.DocumentDB/databaseAccounts/cosmos01-abc123/sqlDatabases/contosocare/containers/patient-events')
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
        @{ Case = 'when there''s no start to compare with'; State = 'Running'; Reported = $null; Since = $null; Expected = $true }
        @{ Case = 'when reported after the start'; State = 'Running'; Reported = [datetime]::new(2026, 11, 4, 14, 46, 32, [System.DateTimeKind]::Utc); Since = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Expected = $true }
        @{ Case = 'not when reported before the start (the stale Running of 2026-11-04)'; State = 'Running'; Reported = [datetime]::new(2026, 11, 3, 23, 10, 0, [System.DateTimeKind]::Utc); Since = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Expected = $false }
        @{ Case = 'not when reported at the start itself'; State = 'Running'; Reported = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Since = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Expected = $false }
        @{ Case = 'when Running without a time, 12 minutes after the start: nothing proves it stale (#22)'; State = 'Running'; Reported = $null; Since = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Expected = $true }
        @{ Case = 'not when NotRunning without a time, 12 minutes after the start'; State = 'NotRunning'; Reported = $null; Since = [datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc); Expected = $false }
        @{ Case = 'when NotRunning without a time, more than 30 minutes after the start'; State = 'NotRunning'; Reported = $null; Since = [datetime]::new(2026, 11, 4, 14, 16, 0, [System.DateTimeKind]::Utc); Expected = $true }
    ) {
        $plugin = [pscustomobject]@{ State = $State; ReportedUtc = $Reported }
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

Describe 'The session''s hosts (2026-11-16, live: a host''s start failed mid-session, and its status still said its activity went out)' {
    BeforeEach {
        Reset-TestAzure
        Mock Get-DbHubUtcNow { return $script:clock }
        Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
        Mock Invoke-DbHubArm {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body; At = $script:clock })
            return (Invoke-TestAzure -Method $Method -Path $Path -Body $Body)
        }
        $script:groupTags = @{ DbHubT4Replica = 'Session' }
        $script:t4 = 'Stopped'
        $script:t4Sku = 'Standard_D4ds_v5'
        $script:t4Tier = 'GeneralPurpose'
        $script:t4ReadyAt = $script:clock.AddMinutes(4)
        $script:sessionId = '0123456789abcdef0123456789abcdef'
        function Get-SessionStatus {
            $writes = $script:secrets['dbhub-session-status']
            return ($writes[$writes.Count - 1].Value | ConvertFrom-Json)
        }
        function Start-TestSession {
            return (Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId; requestedBy = 'presenter' }) -Context (New-TestContext))
        }
        function Get-HostStep {
            return @((Get-SessionStatus).steps | Where-Object step -EQ 'Host')
        }
    }

    It 'says before the session runs that a host''s start failed, with the fix, and keeps what it wrote for DbHub-Monitor' {
        # Live: archost01's start ended VMStartTimedOut while its power state already said running.
        $script:vmFailed['archost01'] = @{ Code = 'ProvisioningState/failed/VMStartTimedOut'; Time = $script:clock.AddMinutes(2) }
        $result = Start-TestSession
        $result.status | Should -Be 'Partial'
        $status = Get-SessionStatus
        $status.phase | Should -Be 'running'
        $hostSteps = @(Get-HostStep)
        $hostSteps.Count | Should -Be 1
        $hostSteps[0].state | Should -Be 'Warning'
        $hostSteps[0].message | Should -BeExactly 'T2: Azure says archost01''s last operation failed (VMStartTimedOut), so T2 may have no activity this session.'
        $hostSteps[0].fix | Should -Match 'set STOP_NOW = True and Run all, then Run all again, which starts archost01 again'
        @($status.runCommands | ForEach-Object vm) | Should -Contain 'archost01'
        @($status.runCommands | Where-Object vm -EQ 'archost01' | ForEach-Object { $_.targets }) | Should -Be @('T2')
        $script:automationVariables['DbHubSessionStatus'] | Should -BeExactly $script:secrets['dbhub-session-status'][-1].Value
    }

    It 'blames neither a host that runs nor a failure from before the session started' {
        $script:vmFailed['sqlvm01'] = @{ Code = 'ProvisioningState/failed/VMExtensionProvisioningError'; Time = $script:clock.AddHours(-3) }
        $result = Start-TestSession
        $result.status | Should -Be 'Started'
        @(Get-HostStep) | Should -BeNullOrEmpty
    }

    It 'says when a dispatch Run Command failed, with how to see its output' {
        $script:runCommandViews['DbHubControl-archost01-20261027150000'] = @{ executionState = 'Failed'; exitCode = 1; executionMessage = 'The guest didn''t answer.' }
        $result = Start-TestSession
        $result.status | Should -Be 'Partial'
        $hostSteps = @(Get-HostStep)
        $hostSteps.Count | Should -Be 1
        $hostSteps[0].message | Should -BeExactly 'T2: the Run Command DbHubControl-archost01-20261027150000 that set its activity on archost01 ended Failed, exit code 1, so T2 may have no activity this session.'
        $hostSteps[0].fix | Should -Match ([regex]::Escape('az vm run-command show -g rg-dbhub-demo --vm-name archost01 -n DbHubControl-archost01-20261027150000 --instance-view'))
    }

    It 'names each target a dispatch Run Command couldn''t set, with why, and only those (#28; live, 2026-11-04: error 547 on T1)' {
        $output = @(
            'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"Runner","status":"Fail","message":"runner profile set --target T1: Fail. error=547 ck_activity_profile_name"}'
            'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"Runner","status":"Pass","message":"runner profile set --target T3: Pass."}'
            'DBHUB-DISPATCH {"failed":[{"target":"T1","status":"Fail","message":"runner profile set --target T1: Fail. error=547 ck_activity_profile_name","oldRunner":false}]}'
        ) -join "`n"
        $script:runCommandViews['DbHubControl-sqlvm01-20261027150000'] = @{ executionState = 'Failed'; exitCode = 1; output = $output }
        $result = Start-TestSession
        $result.status | Should -Be 'Partial'
        $hostSteps = @(Get-HostStep)
        $hostSteps.Count | Should -Be 1 -Because 'T3 got its activity from the same Run Command'
        $hostSteps[0].state | Should -Be 'Warning'
        $hostSteps[0].message | Should -BeExactly 'T1: its activity wasn''t set on sqlvm01 (Fail: runner profile set --target T1: Fail. error=547 ck_activity_profile_name), so T1 doesn''t get this session''s activity.'
        $hostSteps[0].fix | Should -Match ([regex]::Escape('az vm run-command show -g rg-dbhub-demo --vm-name sqlvm01 -n DbHubControl-sqlvm01-20261027150000 --instance-view'))
        $hostSteps[0].fix | Should -Match 'for T1, set STOP_NOW = True and Run all, then Run all again'
    }

    It 'says a target''s workload runner is older than the control, with deploy.ps1 as the fix, when it refused the activity (#21)' {
        $script:runCommandViews['DbHubControl-sqlvm01-20261027150000'] = @{ executionState = 'Failed'; exitCode = 1; output = 'DBHUB-DISPATCH {"failed":[{"target":"T3","status":"Fail","message":"runner profile set --target T3: Fail. Unknown activity profile ''showcase''.","oldRunner":true}]}' }
        $null = Start-TestSession
        $hostSteps = @(Get-HostStep)
        $hostSteps.Count | Should -Be 1
        $hostSteps[0].message | Should -BeExactly 'T3: sqlvm01''s workload runner is older than this session control and refused its activity, so T3 doesn''t get this session''s activity.'
        $hostSteps[0].fix | Should -Match 'set STOP_NOW = True and Run all to end the session, run \./scripts/deploy\.ps1, which updates the workload runner on sqlvm01, then Run all again'
    }

    It 'counts a dispatch Run Command that ended with a non-zero exit code as failed, whatever its state says' {
        $script:runCommandViews['DbHubControl-archost01-20261027150000'] = @{ executionState = 'Succeeded'; exitCode = 1 }
        $null = Start-TestSession
        @(Get-HostStep | ForEach-Object message) | Should -Be @('T2: the Run Command DbHubControl-archost01-20261027150000 that set its activity on archost01 ended with exit code 1, so T2 may have no activity this session.')
    }

    It 'moves each target''s dispatchUtc to when its Run Command''s script set it, before the session runs, and keeps the accepted time otherwise (2026-11-19)' {
        # Live, 2026-11-19: on a VM that had just started, sqlvm01's Run Command set T3's profile 2 minutes 41 seconds after
        # Azure accepted it, which is when T3's showcase counts its cycles from, so the control notebook's times for T3, its
        # "Now: T3 Respond" line included, came that much early.
        $script:runCommandViews['DbHubControl-sqlvm01-20261027150000'] = {
            $put = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/virtualMachines/sqlvm01/runCommands/DbHubControl-sqlvm01-' })[0]
            $set = [ordered]@{ T1 = $put.At.AddSeconds(158).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture); T3 = $put.At.AddSeconds(161).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) }
            return @{ executionState = 'Succeeded'; exitCode = 0; output = ("DBHUBDEMO-WORKLOAD {}`nDBHUB-SET " + (ConvertTo-Json -InputObject $set -Compress)) }
        }
        $context = New-TestContext
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId; requestedBy = 'presenter' }) -Context $context
        $result.status | Should -Be 'Started'
        @(Get-HostStep) | Should -BeNullOrEmpty -Because 'a later set is no problem'
        $status = Get-SessionStatus
        $status.phase | Should -Be 'running'
        $put = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/virtualMachines/sqlvm01/runCommands/DbHubControl-sqlvm01-' })[0]
        $text = { param($Value) ConvertTo-DbHubTimeText -Value (ConvertTo-DbHubUtc -Value $Value) }
        (& $text $status.dispatchUtc.T1) | Should -Be (& $text $put.At.AddSeconds(158))
        (& $text $status.dispatchUtc.T3) | Should -Be (& $text $put.At.AddSeconds(161))
        (& $text $status.dispatchUtc.T4) | Should -Be (& $text $status.t4.dispatchUtc) -Because 'T4 isn''t in the line, so it keeps the accepted time'
        @($context.Log | Where-Object { $_ -match 'T3: its activity was set on sqlvm01 at \d\d:\d\d:\d\d UTC, \d+ s after Azure accepted the Run Command' }).Count | Should -Be 1
    }

    It 'keeps the accepted time for a set within 5 seconds of it, before it, or more than an hour after it, and moves only the command''s own targets' {
        $script:vm['sqlvm01'] = 'running'
        $script:vm['archost01'] = 'running'
        $status = [ordered]@{
            sessionId   = $script:sessionId
            acceptedUtc = '2026-10-27T15:00:00Z'
            dispatchUtc = [ordered]@{ T1 = '2026-10-27T15:04:00Z'; T2 = '2026-10-27T15:04:00Z'; T3 = '2026-10-27T15:04:00Z'; T4 = '2026-10-27T15:04:00Z'; T5 = '2026-10-27T15:04:00Z' }
            runCommands = @([ordered]@{ vm = 'sqlvm01'; name = 'DbHubControl-sqlvm01-anchor'; targets = @('T1', 'T3', 'T4', 'T5') })
        }
        $script:runCommandViews['DbHubControl-sqlvm01-anchor'] = @{ executionState = 'Succeeded'; exitCode = 0; output = 'DBHUB-SET {"T1":"2026-10-27T15:04:04Z","T3":"2026-10-27T16:04:30Z","T4":"2026-10-27T15:03:00Z","T5":"2026-10-27T15:36:41Z","T2":"2026-10-27T15:06:41Z"}' }
        @(Get-DbHubSessionHealth -Context (New-TestContext -NowUtc $script:clock.AddMinutes(10)) -Status $status) | Should -BeNullOrEmpty
        $status['dispatchUtc']['T1'] | Should -Be '2026-10-27T15:04:00Z' -Because '4 seconds is within the 5'
        $status['dispatchUtc']['T3'] | Should -Be '2026-10-27T15:04:00Z' -Because 'more than an hour later isn''t a set time to trust'
        $status['dispatchUtc']['T4'] | Should -Be '2026-10-27T15:04:00Z' -Because 'a set never comes before its Run Command'
        $status['dispatchUtc']['T5'] | Should -Be '2026-10-27T15:36:41Z' -Because 'T2''s guest, say, can take more than 30 minutes after a cold start'
        $status['dispatchUtc']['T2'] | Should -Be '2026-10-27T15:04:00Z' -Because 'T2 isn''t one of this Run Command''s targets'
        # Idempotent: the next check finds the time it moved to, and changes nothing.
        @(Get-DbHubSessionHealth -Context (New-TestContext -NowUtc $script:clock.AddMinutes(40)) -Status $status) | Should -BeNullOrEmpty
        $status['dispatchUtc']['T5'] | Should -Be '2026-10-27T15:36:41Z'
    }

    It 'reads the last DBHUB-SET line''s targets and times, and nothing from output without one, or with one it can''t read (2026-11-19)' {
        $set = @(Get-DbHubDispatchSetTime -Output ("before`nDBHUB-SET {""T1"":""2026-10-27T15:01:00Z""}`nDBHUB-SET {""T1"":""2026-10-27T15:02:41Z"",""T3"":""2026-10-27T15:02:44Z"",""T9"":""2026-10-27T15:02:45Z"",""T4"":""soon""}`nDBHUB-DISPATCH {}"))
        @($set | ForEach-Object Target) | Should -Be @('T1', 'T3')
        (ConvertTo-DbHubTimeText -Value $set[0].SetUtc) | Should -Be '2026-10-27T15:02:41Z'
        (ConvertTo-DbHubTimeText -Value $set[1].SetUtc) | Should -Be '2026-10-27T15:02:44Z'
        @(Get-DbHubDispatchSetTime -Output 'DBHUB-SET {not json') | Should -BeNullOrEmpty
        @(Get-DbHubDispatchSetTime -Output 'DBHUB-DISPATCH {"failed":[]}') | Should -BeNullOrEmpty
        @(Get-DbHubDispatchSetTime -Output '') | Should -BeNullOrEmpty
    }

    It 'adds a host that stopped mid-session to the running session''s status once, through DbHub-Monitor, and starts or stops nothing' {
        $null = Start-TestSession
        $before = Get-SessionStatus
        $writes = $script:secrets['dbhub-session-status'].Count
        $script:vm['archost01'] = 'deallocated'
        $script:clock = $script:clock.AddMinutes(30)
        $checkedFrom = $script:calls.Count
        $result = Invoke-DbHubMonitor -Context (New-TestContext -NowUtc $script:clock)
        $result.session | Should -Be 'Warned'
        $result.status | Should -Be 'Partial'
        $result.monitoring | Should -Be 'Running'
        $result.message | Should -Match 'T2: archost01 is deallocated, so T2 has no activity now\.'
        $script:secrets['dbhub-session-status'].Count | Should -Be ($writes + 1)
        $after = Get-SessionStatus
        $after.phase | Should -Be 'running'
        $after.sessionId | Should -Be $script:sessionId
        @($after.steps).Count | Should -Be (@($before.steps).Count + 1) -Because 'the monitor keeps every step the session wrote'
        $after.runEndUtc | Should -Be $before.runEndUtc
        $hostSteps = @(Get-HostStep)
        $hostSteps.Count | Should -Be 1
        $hostSteps[0].message | Should -BeExactly 'T2: archost01 is deallocated, so T2 has no activity now.'
        $script:automationVariables['DbHubSessionStatus'] | Should -BeExactly $script:secrets['dbhub-session-status'][-1].Value
        @($script:calls | Select-Object -Skip $checkedFrom | Where-Object { $_.Method -eq 'POST' }) | Should -BeNullOrEmpty
        # The next check finds the same thing: nothing new is written.
        $again = Invoke-DbHubMonitor -Context (New-TestContext -NowUtc $script:clock.AddMinutes(30))
        $again.session | Should -Be 'Known'
        $script:secrets['dbhub-session-status'].Count | Should -Be ($writes + 1)
    }

    It 'says through DbHub-Monitor that a host''s VM agent isn''t Ready 15 minutes after its activity went out, once, and gives a host that has just started its time' {
        # Live, 2026-11-17: archost01 ran, its agent never got its goal state, and the status said T2's activity went out
        # for the whole session; Azure ends such a start VMStartTimedOut about 58 minutes in.
        $script:vmAgent['archost01'] = ''
        $null = Start-TestSession
        @(Get-HostStep) | Should -BeNullOrEmpty -Because 'the session''s own check comes right after the dispatch, inside the 15 minutes'
        $writes = $script:secrets['dbhub-session-status'].Count
        $script:clock = $script:clock.AddMinutes(30)
        $context = New-TestContext -NowUtc $script:clock
        $result = Invoke-DbHubMonitor -Context $context
        $result.session | Should -Be 'Warned'
        $hostSteps = @(Get-HostStep)
        $hostSteps.Count | Should -Be 1
        $hostSteps[0].state | Should -Be 'Warning'
        $hostSteps[0].message | Should -BeExactly 'T2: archost01''s VM agent wasn''t Ready 15 minutes after T2''s activity went out, so the Run Command that sets it can''t run, and T2 may have no activity this session.'
        $hostSteps[0].fix | Should -Match 'set STOP_NOW = True and Run all; ./scripts/status.ps1 shows archost01''s state'
        @($context.Log | Where-Object { $_ -match 'archost01: its VM agent isn''t Ready \(no status\)' }).Count | Should -Be 1
        $script:secrets['dbhub-session-status'].Count | Should -Be ($writes + 1)
        $script:vmAgent['archost01'] = 'Not Ready'
        $again = Invoke-DbHubMonitor -Context (New-TestContext -NowUtc $script:clock.AddMinutes(30))
        $again.session | Should -Be 'Known' -Because 'the words stay the same while the problem does'
    }

    It 'blames no agent that''s Ready, and no VM whose agent''s time hasn''t come' {
        $null = Start-TestSession
        $status = Get-SessionStatus | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
        $script:clock = $script:clock.AddMinutes(30)
        @(Get-DbHubSessionHealth -Context (New-TestContext -NowUtc $script:clock) -Status $status) | Should -BeNullOrEmpty
        $script:vmAgent['sqlvm01'] = 'Not Ready'
        $status['dispatchUtc'] = [ordered]@{}
        @(Get-DbHubSessionHealth -Context (New-TestContext -NowUtc $script:clock) -Status $status) | Should -BeNullOrEmpty -Because 'without a dispatch time there''s nothing to count from'
    }

    It 'never writes over a newer status: <Case> between its read and its write' -ForEach @(
        @{ Case = 'the session''s end'; Phase = 'stopped' }
        @{ Case = 'another job''s write'; Phase = 'running' }
    ) {
        $null = Start-TestSession
        $writes = $script:secrets['dbhub-session-status'].Count
        $script:vm['archost01'] = 'deallocated'
        $script:clock = $script:clock.AddMinutes(30)
        $newer = (Get-SessionStatus | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable)
        $newer['phase'] = $Phase
        $newer['updatedUtc'] = '2026-10-27T15:30:01Z'
        $script:newerJson = ConvertTo-Json -InputObject $newer -Depth 8 -Compress
        $script:variableReads = 0
        # The monitor's second read of the copy, right before its write, finds the newer one.
        $script:variableReadHook = { if ($script:variableReads -eq 2) { $script:automationVariables['DbHubSessionStatus'] = $script:newerJson } }
        $context = New-TestContext -NowUtc $script:clock
        $result = Invoke-DbHubMonitor -Context $context
        $result.session | Should -Be 'Changed'
        $script:secrets['dbhub-session-status'].Count | Should -Be $writes
        $script:automationVariables['DbHubSessionStatus'] | Should -BeExactly $script:newerJson
        @($context.Log | Where-Object { $_ -match 'changed while its hosts were checked .* didn''t write it' }).Count | Should -Be 1
    }

    It 'skips a variable that doesn''t exist, or a sandbox without the cmdlets, quietly: the session runs with its status, and DbHub-Monitor still checks T1''s plugin' {
        $script:variableMissing = $true
        $context = New-TestContext
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:sessionId; requestedBy = 'presenter' }) -Context $context
        $result.status | Should -Be 'Started'
        (Get-SessionStatus).phase | Should -Be 'running'
        @($context.Log | Where-Object { $_ -match 'couldn''t be kept for the monitoring re-checks' }).Count | Should -Be 1
        $script:vm['archost01'] = 'deallocated'
        $script:clock = $script:clock.AddMinutes(30)
        $monitor = Invoke-DbHubMonitor -Context (New-TestContext -NowUtc $script:clock)
        $monitor.session | Should -Be 'NoStatus'
        $monitor.monitoring | Should -Be 'Running'
        $monitor.status | Should -Be 'Checked'
        $script:variableMissing = $false
        Mock Get-Command { return $null } -ParameterFilter { $Name -in 'Set-AutomationVariable', 'Get-AutomationVariable' }
        $quiet = New-TestContext -NowUtc $script:clock
        (Save-DbHubSessionStatusCopy -Context $quiet -Json '{}') | Should -BeFalse
        Read-DbHubSessionStatusCopy -Context $quiet | Should -BeNullOrEmpty
        $quiet.Log | Should -BeNullOrEmpty
    }

    It 'finds a status''s hosts from the targets its activity went out to when it has no runCommands' {
        $script:vm['sqlvm01'] = 'running'
        $script:vm['archost01'] = 'deallocated'
        $status = [ordered]@{ sessionId = $script:sessionId; acceptedUtc = '2026-10-27T15:00:00Z'; dispatchUtc = [ordered]@{ T1 = '2026-10-27T15:04:00Z'; T2 = '2026-10-27T15:10:00Z' } }
        $findings = @(Get-DbHubSessionHealth -Context (New-TestContext) -Status $status)
        $findings.Count | Should -Be 1
        $findings[0].Message | Should -BeExactly 'T2: archost01 is deallocated, so T2 has no activity now.'
    }

    It 'says "have" for a host that drives several targets' {
        # Live, 2026-11-17: sqlvm01 drives T1, T3, and T4, and the Warning read "so T1, T3, and T4 has no activity now".
        $script:vm['sqlvm01'] = 'deallocated'
        $status = [ordered]@{ sessionId = $script:sessionId; acceptedUtc = '2026-10-27T15:00:00Z'; dispatchUtc = [ordered]@{ T1 = '2026-10-27T15:04:00Z'; T3 = '2026-10-27T15:04:00Z'; T4 = '2026-10-27T15:05:00Z' } }
        $findings = @(Get-DbHubSessionHealth -Context (New-TestContext) -Status $status)
        $findings.Count | Should -Be 1
        $findings[0].Message | Should -BeExactly 'T1, T3, and T4: sqlvm01 is deallocated, so T1, T3, and T4 have no activity now.'
    }
}

Describe 'The dispatch Run Command''s script: a target whose activity wasn''t set ends it Failed (#28, #21)' {
    BeforeAll {
        # Windows PowerShell 5.1 runs the script on the VMs; where it isn't installed, pwsh stands in.
        $script:shell = $null
        if ($IsWindows) {
            $script:shell = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
        }
        if (-not $script:shell) {
            $script:shell = (Get-Process -Id $PID).Path
        }
        # A stand-in for the VM-side control: like the real one, it writes its result line straight to the console, with the
        # status and message the test gives the request's target.
        $script:standIn = @(
            '$request = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(''__REQUEST__'')) | ConvertFrom-Json'
            '$outcome = (Get-Content -LiteralPath ''__OUTCOMES__'' -Raw | ConvertFrom-Json).($request.target)'
            'Write-Output (''before {0}'' -f $request.target)'
            'if ($null -ne $outcome.status) { [Console]::Out.WriteLine(''DBHUBDEMO-WORKLOAD '' + (ConvertTo-Json -InputObject @{ marker = ''DBHUBDEMO-WORKLOAD''; action = ''Runner''; status = $outcome.status; message = $outcome.message } -Compress)) }'
        ) -join "`n"
        function Invoke-DispatchScript([string[]] $Target, [hashtable] $Outcome, [switch] $RealTemplate) {
            $settings = $script:settings.PSObject.Copy()
            if (-not $RealTemplate) {
                $outcomes = Join-Path -Path $TestDrive -ChildPath ('outcomes-{0}.json' -f [guid]::NewGuid().ToString('N'))
                Set-Content -LiteralPath $outcomes -Value (ConvertTo-Json -InputObject $Outcome -Depth 4) -Encoding ascii
                $settings.controlScriptTemplate = $script:standIn.Replace('__OUTCOMES__', $outcomes)
            }
            $requests = @($Target | ForEach-Object { [ordered]@{ target = $_; arguments = @('profile', 'set', '--name', 'showcase', '--requested-by', 'test'); timeoutSeconds = 300; readySeconds = 0 } })
            $path = Join-Path -Path $TestDrive -ChildPath ('dispatch-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $path -Value (Get-DbHubWorkloadScript -Settings $settings -Request $requests) -Encoding ascii
            $lines = @(& $script:shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path)
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines | ForEach-Object { [string]$_ }); Failed = @(Get-DbHubDispatchFailure -Output ($lines -join "`n")) }
        }
    }

    It 'ends with exit code 1 and names the target whose profile set failed, after every target''s own lines (live, 2026-11-04)' {
        $run = Invoke-DispatchScript -Target 'T1', 'T3' -Outcome @{ T1 = @{ status = 'Fail'; message = 'runner profile set --target T1: Fail. error=547 ck_activity_profile_name' }; T3 = @{ status = 'Pass'; message = 'runner profile set --target T3: Pass.' } }
        $run.ExitCode | Should -Be 1
        @($run.Lines | Where-Object { $_ -match '^before T[13]$' }) | Should -Be @('before T1', 'before T3')
        @($run.Lines | Where-Object { $_.StartsWith('DBHUBDEMO-WORKLOAD ') }).Count | Should -Be 2
        $run.Lines[-1] | Should -Match '^DBHUB-DISPATCH '
        $run.Failed.Count | Should -Be 1
        $run.Failed[0].Target | Should -Be 'T1'
        $run.Failed[0].Status | Should -Be 'Fail'
        $run.Failed[0].Message | Should -Match 'error=547'
        $run.Failed[0].OldRunner | Should -BeFalse
    }

    It 'says when a runner older than the control refused the profile or an option (#21)' {
        $run = Invoke-DispatchScript -Target 'T3', 'T4' -Outcome @{ T3 = @{ status = 'Fail'; message = 'runner profile set --target T3: Fail. Unknown activity profile ''showcase''. Use off, baseline, business-day, or incident:<scenario>.' }; T4 = @{ status = 'Fail'; message = 'runner profile set --target T4: Fail. Unrecognized command or argument ''--vcores''.' } }
        $run.ExitCode | Should -Be 1
        @($run.Failed | ForEach-Object Target) | Should -Be @('T3', 'T4')
        @($run.Failed | ForEach-Object OldRunner) | Should -Be @($true, $true)
    }

    It 'ends with exit code 0, and no DBHUB-DISPATCH line, when every target got its activity' {
        $run = Invoke-DispatchScript -Target 'T1', 'T3' -Outcome @{ T1 = @{ status = 'Pass'; message = 'ok' }; T3 = @{ status = 'Warning'; message = 'set, with a warning' } }
        $run.ExitCode | Should -Be 0
        @($run.Lines | Where-Object { $_.StartsWith('DBHUBDEMO-WORKLOAD ') }).Count | Should -Be 2
        @($run.Lines | Where-Object { $_.StartsWith('DBHUB-DISPATCH ') }) | Should -BeNullOrEmpty
        $run.Lines[-1] | Should -Match '^DBHUB-SET ' -Because 'each target''s set time is the last line then'
    }

    It 'writes one DBHUB-SET line with each target that got its activity and the VM''s UTC time right after its set, before DBHUB-DISPATCH (2026-11-19)' {
        # Live, 2026-11-19: on a VM that had just started, sqlvm01's Run Command set T3's profile 2 minutes 41 seconds after
        # Azure accepted it, which is when T3's showcase counts its cycles from.
        $before = [DateTime]::UtcNow.AddSeconds(-1)
        $run = Invoke-DispatchScript -Target 'T1', 'T3', 'T4' -Outcome @{ T1 = @{ status = 'Pass'; message = 'ok' }; T3 = @{ status = 'Fail'; message = 'runner profile set --target T3: Fail. error=547' }; T4 = @{ status = 'Warning'; message = 'set, with a warning' } }
        $after = [DateTime]::UtcNow.AddSeconds(1)
        $run.ExitCode | Should -Be 1
        $run.Lines[-1] | Should -Match '^DBHUB-DISPATCH ' -Because 'DBHUB-DISPATCH stays the last line'
        @($run.Lines | Where-Object { $_.StartsWith('DBHUB-SET ') }).Count | Should -Be 1
        $set = @(Get-DbHubDispatchSetTime -Output ($run.Lines -join "`n"))
        @($set | ForEach-Object Target) | Should -Be @('T1', 'T4') -Because 'T3''s activity wasn''t set'
        foreach ($item in $set) {
            $item.SetUtc | Should -BeGreaterOrEqual $before.AddTicks(-($before.Ticks % [TimeSpan]::TicksPerSecond))
            $item.SetUtc | Should -BeLessOrEqual $after
        }
        @($run.Failed | ForEach-Object Target) | Should -Be @('T3')
    }

    It 'fails a target that wrote no result line, and with the module''s own template a VM without the control' {
        $run = Invoke-DispatchScript -Target 'T1' -Outcome @{ T1 = @{ status = $null; message = $null } }
        $run.ExitCode | Should -Be 1
        $run.Failed[0].Status | Should -Be 'NoResult'
        @($run.Lines | Where-Object { $_.StartsWith('DBHUB-SET ') }) | Should -BeNullOrEmpty -Because 'no target got its activity'
        if (Test-Path -LiteralPath 'C:\ProgramData\DbHubDemo\settings.json') {
            Set-ItResult -Skipped -Because 'this machine has the VM-side control'
            return
        }
        $real = Invoke-DispatchScript -Target 'T1' -RealTemplate
        $real.ExitCode | Should -Be 1
        $real.Failed[0].Target | Should -Be 'T1'
        $real.Failed[0].Message | Should -Match 'settings\.json is missing'
    }
}

Describe 'The Incident RCA''s evidence (ADR 0031): the export through managed Run Commands, its bundles, and its index' {
    BeforeAll {
        $script:rcaRoot = Join-Path -Path $repoRoot -ChildPath 'rca'
        $script:transportSchema = Join-Path -Path $script:rcaRoot -ChildPath 'transport.schema.json'
        $script:fixtureSession = '5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21'
        $script:fixtureIndex = Get-Content -LiteralPath (Join-Path -Path $script:rcaRoot -ChildPath 'fixtures/export-index.json') -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 5 -Compress
        $script:fixtureParts = @(Get-ChildItem -Path (Join-Path -Path $script:rcaRoot -ChildPath 'fixtures') -Filter '*.parts.txt' -File | Sort-Object -Property Name | ForEach-Object { Get-Content -LiteralPath $_.FullName } | Where-Object { $_ })
        $script:fixtureIds = @('20261120T165000Z-sqlvm01-0001', '20261120T170000Z-sqlvm01-0002')

        # The runner on sqlvm01 with the fixtures' documents: each export lists the next of -Batches (comma-separated
        # document IDs), and 'rca part' prints a fixture's part; archost01's runner has nothing to export.
        function Set-FixtureRunner([string[]] $Batches = @($script:fixtureIds -join ',')) {
            $script:exportBatches = [System.Collections.Generic.Queue[string]]::new()
            foreach ($batch in $Batches) {
                $script:exportBatches.Enqueue($batch)
            }
            $script:rcaRunner = {
                param($Command)
                $request = $Command.Request
                if ($Command.Vm -ne 'sqlvm01') {
                    return (New-TestRcaView -Status 'Not selected' -Message 'runner rca export: nothing was captured since the last export.')
                }
                if ($request.command -eq 'export') {
                    if ($null -eq $Command.PSObject.Properties['Answer']) {
                        $ids = if ($script:exportBatches.Count -gt 0) { $script:exportBatches.Dequeue().Split(',') } else { @() }
                        $index = $script:fixtureIndex | ConvertFrom-Json
                        $index.documents = @($index.documents | Where-Object { $_.documentId -in $ids })
                        $Command | Add-Member -NotePropertyName 'Answer' -NotePropertyValue ('DBHUBDEMO-RCA-INDEX ' + (ConvertTo-Json -InputObject $index -Depth 5 -Compress))
                    }
                    if (@(($Command.Answer.Substring(20) | ConvertFrom-Json).documents).Count -eq 0) {
                        return (New-TestRcaView -Status 'Not selected' -Message 'runner rca export: nothing was captured since the last export.')
                    }
                    return (New-TestRcaView -Status 'Pass' -Message 'runner rca export: its line follows.' -Line $Command.Answer)
                }
                $line = @($script:fixtureParts | Where-Object { $_.Split(' ')[2] -eq $request.documentId -and $_.Split(' ')[3].StartsWith(('{0}/' -f $request.part)) }) | Select-Object -First 1
                if (-not $line) {
                    return (New-TestRcaView -Status 'Fail' -Message 'runner rca part: exit code 1. The document or part doesn''t exist.')
                }
                return (New-TestRcaView -Status 'Pass' -Message 'runner rca part: its line follows.' -Line $line)
            }
        }

        # The documents in bundles' parts, decoded as the notebook decodes them (rca/README.md, Part lines).
        function Expand-TestBundle([string[]] $Json) {
            $parts = @(foreach ($text in $Json) { ($text | ConvertFrom-Json).parts })
            $documents = [ordered]@{}
            foreach ($group in ($parts | Group-Object -Property { $_.Split(' ')[2] })) {
                $buffer = [System.IO.MemoryStream]::new()
                foreach ($line in ($group.Group | Sort-Object -Property { [int]$_.Split(' ')[3].Split('/')[0] })) {
                    $bytes = [System.Convert]::FromBase64String($line.Split(' ')[5])
                    $buffer.Write($bytes, 0, $bytes.Length)
                }
                $stream = [System.IO.Compression.GZipStream]::new([System.IO.MemoryStream]::new($buffer.ToArray()), [System.IO.Compression.CompressionMode]::Decompress)
                $reader = [System.IO.StreamReader]::new($stream)
                $documents[$group.Name] = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Dispose()
            }
            return $documents
        }

        # The runner when nothing new was captured: every export lists nothing, and 'rca part' prints a fixture's part on
        # either VM, as the runner keeps an exported document there (review of 3b1348a).
        function Set-PartsRunner {
            $script:rcaRunner = {
                param($Command)
                $request = $Command.Request
                if ($request.command -eq 'export') {
                    return (New-TestRcaView -Status 'Not selected' -Message 'runner rca export: nothing was captured since the last export.')
                }
                $line = @($script:fixtureParts | Where-Object { $_.Split(' ')[2] -eq $request.documentId -and $_.Split(' ')[3].StartsWith(('{0}/' -f $request.part)) }) | Select-Object -First 1
                return (New-TestRcaView -Status 'Pass' -Message 'runner rca part: its line follows.' -Line $line)
            }
        }

        # A session's start from deallocated VMs, as after the nightly stop: nothing runs, and no run is active.
        function Set-TestSessionStart {
            $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'deallocated' }
            $script:t4 = 'Stopped'
            $script:replica = ''
            $script:autostop = ''
            $script:groupTags = @{ DbHubT4Replica = 'Session' }
            $script:t4ReadyAt = $script:clock.AddMinutes(4)
        }

        # A document reference as a status keeps it, on a VM.
        function New-TestPending([string] $DocumentId, [string] $Vm) {
            $reference = @(($script:fixtureIndex | ConvertFrom-Json).documents | Where-Object documentId -EQ $DocumentId)[0]
            return [ordered]@{ documentId = $reference.documentId; parts = [int]$reference.parts; sha256 = $reference.sha256; vm = $Vm }
        }

        # A runner whose export on -Vm lists documents built from the T1 fixture with the IDs and sessions -Case gives (each
        # @{ Id; Session }), once per VM unless -EveryExport, and whose 'rca part' prints their parts, or a fixture's, on
        # any VM (review of 93243d6: the fixtures' documents are all one session's).
        function Set-ServedRunner([object[]] $Case, [string[]] $Vm = @('sqlvm01'), [switch] $EveryExport) {
            $template = Get-Content -LiteralPath (Join-Path -Path $script:rcaRoot -ChildPath 'fixtures/t1-blocking-chain.evidence.json') -Raw | ConvertFrom-Json
            $script:servedParts = @{}
            $references = foreach ($item in $Case) {
                $template.documentId = $item.Id
                $template.sessionId = $item.Session
                $plain = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $template -Depth 30 -Compress))
                $memory = [System.IO.MemoryStream]::new()
                $gzip = [System.IO.Compression.GZipStream]::new($memory, [System.IO.Compression.CompressionLevel]::Optimal, $true)
                $gzip.Write($plain, 0, $plain.Length)
                $gzip.Dispose()
                $bytes = $memory.ToArray()
                $sha = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
                $count = [int][System.Math]::Ceiling($bytes.Length / 2400.0)
                $script:servedParts[$item.Id] = @(for ($i = 0; $i -lt $count; $i++) { 'DBHUBDEMO-RCA 1 {0} {1}/{2} {3} {4}' -f $item.Id, ($i + 1), $count, $sha, [System.Convert]::ToBase64String($bytes, $i * 2400, [System.Math]::Min(2400, $bytes.Length - $i * 2400)) })
                [ordered]@{ documentId = $item.Id; parts = $count; sha256 = $sha }
            }
            $script:servedIndex = 'DBHUBDEMO-RCA-INDEX ' + (ConvertTo-Json -InputObject ([ordered]@{ kind = 'ContosoCare.RcaExportIndex'; version = 1; documents = @($references); status = 'Pass'; message = ('{0} documents.' -f @($references).Count) }) -Depth 5 -Compress)
            $script:servedVms = $Vm
            $script:servedEvery = [bool]$EveryExport
            $script:servedTo = [System.Collections.Generic.List[string]]::new()
            $script:rcaRunner = {
                param($Command)
                $request = $Command.Request
                if ($request.command -eq 'export') {
                    if ($null -eq $Command.PSObject.Properties['Answer']) {
                        $answer = ''
                        if ($Command.Vm -in $script:servedVms -and ($script:servedEvery -or -not $script:servedTo.Contains($Command.Vm))) {
                            $script:servedTo.Add($Command.Vm)
                            $answer = $script:servedIndex
                        }
                        $Command | Add-Member -NotePropertyName 'Answer' -NotePropertyValue $answer
                    }
                    if (-not $Command.Answer) {
                        return (New-TestRcaView -Status 'Not selected' -Message 'runner rca export: nothing was captured since the last export.')
                    }
                    return (New-TestRcaView -Status 'Pass' -Message 'runner rca export: its line follows.' -Line $Command.Answer)
                }
                $parts = @($script:servedParts[[string]$request.documentId]) + @($script:fixtureParts | Where-Object { $_.Split(' ')[2] -eq $request.documentId })
                $line = @($parts | Where-Object { $_ -and $_.Split(' ')[3].StartsWith(('{0}/' -f $request.part)) }) | Select-Object -First 1
                if (-not $line) {
                    return (New-TestRcaView -Status 'Fail' -Message 'runner rca part: exit code 1. The document or part doesn''t exist.')
                }
                return (New-TestRcaView -Status 'Pass' -Message 'runner rca part: its line follows.' -Line $line)
            }
        }
    }

    BeforeEach {
        Reset-TestAzure
        Mock Get-DbHubUtcNow { return $script:clock }
        Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
        Mock Invoke-DbHubArm {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body; At = $script:clock })
            return (Invoke-TestAzure -Method $Method -Path $Path -Body $Body)
        }
        $script:t4 = 'Ready'
        $script:replica = 'Ready'
        $script:replicaSku = 'Standard_D4ds_v5'
        $script:t4Sku = 'Standard_D4ds_v5'
        $script:t4Tier = 'GeneralPurpose'
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        $script:autostop = '2026-10-27T15:30:00Z'
        $script:groupTags = @{ DbHubT4Replica = 'Session'; DbHubBusyUntilUtc = '2026-10-27T15:45:00Z'; DbHubBusyBy = 'session'; DbHubSessionId = $script:fixtureSession; DbHubSessionStartUtc = '2026-10-27T13:30:00Z' }
        function Get-SessionStatus {
            $writes = $script:secrets['dbhub-session-status']
            return ($writes[$writes.Count - 1].Value | ConvertFrom-Json)
        }
        function Get-RcaBundle {
            return @($script:secrets['dbhub-session-metrics'] | Where-Object { [string]$_.Tags['rca'] -eq 'bundle' })
        }
    }

    It 'Stop now exports the session''s evidence before the VMs deallocate: its bundles first, then the metrics'' final version, whose rca member lists them' {
        Set-FixtureRunner
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.rca.status | Should -Be 'Pass'
        $result.rca.documents | Should -Be 2
        $versions = @($script:secrets['dbhub-session-metrics'])
        $versions.Count | Should -Be 2 -Because 'one bundle of the 4 parts, then the metrics'
        $bundle = $versions[0]
        [string]$bundle.Tags['rca'] | Should -Be 'bundle'
        [string]$bundle.Tags['sessionId'] | Should -Be $script:fixtureSession
        Test-Json -Json $bundle.Value -SchemaFile $script:transportSchema | Should -BeTrue
        @(($bundle.Value | ConvertFrom-Json).parts | Sort-Object) | Should -Be @($script:fixtureParts | Sort-Object)
        $final = $versions[1]
        [string]$final.Tags['rca'] | Should -Be 'yes'
        $document = $final.Value | ConvertFrom-Json
        @($document.series).Count | Should -BeGreaterThan 0 -Because 'T4''s metrics stay, beside the index'
        Test-Json -Json (ConvertTo-Json -InputObject $document.rca -Depth 6 -Compress) -SchemaFile $script:transportSchema | Should -BeTrue
        [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $document.rca -Depth 6 -Compress)) | Should -BeLessOrEqual 4000
        @($document.rca.bundles) | Should -Be @($bundle.Version)
        @($document.rca.documents.documentId) | Should -Be $script:fixtureIds
        $document.rca.sessionId | Should -Be $script:fixtureSession
        $document.rca.status | Should -Be 'Pass'
        [System.Text.Encoding]::UTF8.GetByteCount($final.Value) | Should -BeLessOrEqual 24000
        # The parts decode to the fixture documents.
        $decoded = Expand-TestBundle -Json @($bundle.Value)
        @($decoded.Keys) | Should -Be $script:fixtureIds
        $decoded[$script:fixtureIds[1]].final | Should -BeTrue
        # Every Run Command of the export went out, and was deleted, before the first deallocation.
        $firstDeallocate = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Path -match '/deallocate$' }) | Select-Object -First 1))
        $lastRca = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Path -match '/runCommands/DbHubControl-rca-' -and $_.Method -in 'PUT', 'DELETE' }) | Select-Object -Last 1))
        $firstDeallocate | Should -BeGreaterThan 0
        $lastRca | Should -BeLessThan $firstDeallocate
        $metricsWrite = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Path -match '/secrets/dbhub-session-metrics$' }) | Select-Object -Last 1))
        $metricsWrite | Should -BeLessThan $firstDeallocate
        @($script:rcaCommands | Where-Object { $script:rcaDeleted -notcontains $_.Name }) | Should -BeNullOrEmpty
        $exports = @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' })
        @($exports | ForEach-Object Vm | Sort-Object) | Should -Be @('archost01', 'sqlvm01')
        @($exports | ForEach-Object { $_.Request.sessionId } | Select-Object -Unique) | Should -Be @($script:fixtureSession)
        @($exports | ForEach-Object { $_.Request.final } | Select-Object -Unique) | Should -Be @($true)
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' }).Count | Should -Be 4
        # The stopped status keeps the state, and the lines the notebook prints.
        $status = Get-SessionStatus
        $status.rca.final | Should -BeTrue
        @($status.rca.bundles) | Should -Be @($bundle.Version)
        @($status.rcaLines | ForEach-Object step) | Should -Be @('RCA.EXPORT', 'RCA.CAPTURE.T1', 'RCA.CAPTURE.T4', 'RCA.CAPTURE.T4-replica')
        @($status.rcaLines | ForEach-Object status | Select-Object -Unique) | Should -Be @('Pass')
        ($status.rcaLines | Where-Object step -EQ 'RCA.CAPTURE.T1').message | Should -Be 'T1: the observer captured from 16:50 to 17:05 UTC.'
    }

    It 'fetches at most 10 parts at a time on a VM, and never more than its 25 managed Run Commands allow' {
        $index = [ordered]@{ kind = 'ContosoCare.RcaExportIndex'; version = 1; documents = @(1..3 | ForEach-Object { [ordered]@{ documentId = ('20261120T1{0}0000Z-sqlvm01-000{0}' -f $_); parts = 9; sha256 = ([string]$_ * 64) } }); status = 'Pass'; message = '3 documents.' }
        $script:indexLine = 'DBHUBDEMO-RCA-INDEX ' + (ConvertTo-Json -InputObject $index -Depth 5 -Compress)
        $script:most = 0
        $script:rcaRunner = {
            param($Command)
            $open = @($script:rcaCommands | Where-Object { $_.Vm -eq 'sqlvm01' -and $script:rcaDeleted -notcontains $_.Name }).Count
            $script:most = [System.Math]::Max($script:most, $open)
            if ($Command.Vm -ne 'sqlvm01') { return (New-TestRcaView -Status 'Not selected' -Message 'nothing') }
            if ($Command.Request.command -eq 'export') { return (New-TestRcaView -Status 'Pass' -Message 'ok' -Line $script:indexLine) }
            # Each part runs a minute, and ends without its line, as when PowerShell Direct breaks: the next export tries again.
            if (($script:clock - $Command.At).TotalSeconds -lt 60) { return $null }
            return (New-TestRcaView -Status 'Fail' -Message 'runner rca part in arcsql01: The pipe has been ended.')
        }
        $context = New-TestContext
        $done = Invoke-DbHubRcaSessionExport -Context $context -SessionId $script:fixtureSession -Final -Minutes 30 -OnlyVm @('sqlvm01')
        $script:most | Should -Be 10 -Because 'ten parts, and nothing else of the export, at a time'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' }).Count | Should -Be 27
        $done.State['status'] | Should -Be 'Warning'
        @($done.State['pending']).Count | Should -Be 3
        # 20 other Run Commands on the VM leave room for 5: the export's, then 4 parts at a time.
        Reset-TestAzure
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        $script:runCommands['sqlvm01'] = @(1..20 | ForEach-Object { @{ name = ('DbHubDemo-Other-{0}' -f $_) } })
        $script:most = 0
        $script:rcaRunner = {
            param($Command)
            $open = @($script:rcaCommands | Where-Object { $_.Vm -eq 'sqlvm01' -and $script:rcaDeleted -notcontains $_.Name }).Count
            $script:most = [System.Math]::Max($script:most, $open)
            if ($Command.Request.command -eq 'export') { return (New-TestRcaView -Status 'Pass' -Message 'ok' -Line $script:indexLine) }
            if (($script:clock - $Command.At).TotalSeconds -lt 60) { return $null }
            return (New-TestRcaView -Status 'Fail' -Message 'runner rca part in arcsql01: The pipe has been ended.')
        }
        $null = Invoke-DbHubRcaSessionExport -Context (New-TestContext) -SessionId $script:fixtureSession -Final -Minutes 30 -OnlyVm @('sqlvm01')
        $script:most | Should -Be 5
    }

    It 'fetches the T2 host''s parts one Run Command at a time, each gone before the next, and stops sending when Azure doesn''t delete one (R871)' {
        # archost01's runner exports T1's fixture document, two parts; Azure takes two reads to delete each Run Command there.
        $first = @($script:fixtureParts | Where-Object { $_.Split(' ')[2] -eq $script:fixtureIds[0] })
        $index = [ordered]@{ kind = 'ContosoCare.RcaExportIndex'; version = 1; documents = @([ordered]@{ documentId = $script:fixtureIds[0]; parts = $first.Count; sha256 = $first[0].Split(' ')[4] }); status = 'Pass'; message = '1 document.' }
        $script:hostIndex = 'DBHUBDEMO-RCA-INDEX ' + (ConvertTo-Json -InputObject $index -Depth 5 -Compress)
        $script:hostParts = $first
        $script:rcaDeleteDelay = @{ archost01 = 2 }
        $script:rcaRunner = {
            param($Command)
            if ($Command.Request.command -eq 'export') {
                return (New-TestRcaView -Status 'Pass' -Message 'runner rca export: its line follows.' -Line $script:hostIndex)
            }
            $line = @($script:hostParts | Where-Object { $_.Split(' ')[3].StartsWith(('{0}/' -f $Command.Request.part)) })[0]
            return (New-TestRcaView -Status 'Pass' -Message 'runner rca part: its line follows.' -Line $line)
        }
        $done = Invoke-DbHubRcaSessionExport -Context (New-TestContext) -SessionId $script:fixtureSession -Final -Minutes 30 -OnlyVm @('archost01')
        $script:rcaMostOpen['archost01'] | Should -Be 1
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' }).Count | Should -Be $first.Count
        @($done.State['documents'] | ForEach-Object { $_['documentId'] }) | Should -Be @($script:fixtureIds[0])
        $done.State['status'] | Should -Be 'Pass'

        # Azure never finishes a delete there: asked twice, then the host gets no more parts, which wait for the next export.
        $runner = $script:rcaRunner
        Reset-TestAzure
        $script:rcaRunner = $runner
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        $script:rcaDeleteDelay = @{ archost01 = 100000 }
        $done = Invoke-DbHubRcaSessionExport -Context (New-TestContext) -SessionId $script:fixtureSession -Final -Minutes 30 -OnlyVm @('archost01')
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' }) | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/runCommands/DbHubControl-rca-archost01-x-' }).Count | Should -Be 2
        @($done.State['pending'] | ForEach-Object { '{0}@{1}' -f $_['documentId'], $_['vm'] }) | Should -Be @(('{0}@archost01' -f $script:fixtureIds[0]))
        $line = @($done.Lines | Where-Object { $_.Step -eq 'RCA.EXPORT' })[0]
        $line.Status | Should -Be 'Warning'
        $line.Message | Should -Match 'Azure didn''t delete a Run Command on archost01 twice, so it got no more parts in this export \(R871\)\.'
    }

    It 'sends the T2 host its stop''s export only once another job''s Rca Run Command there is gone, without holding up sqlvm01 (live 2026-11-21, R871)' {
        # A re-check's last part still runs on archost01 when the stop begins (live: 18:51:38 to 18:53:18 UTC, beside the
        # stop's export from 18:51:33); that job deletes it 40 seconds into the stop.
        Set-FixtureRunner
        $script:rcaListOpen = $true
        $script:otherName = 'DbHubControl-rca-archost01-0102-{0}' -f $script:clock.AddMinutes(-2).ToString('yyyyMMddHHmmss')
        $script:rcaCommands.Add([pscustomobject]@{ Vm = 'archost01'; Name = $script:otherName; Request = [pscustomobject]@{ command = 'part'; documentId = $script:fixtureIds[0]; part = 2 }; At = $script:clock })
        $script:otherGoneAt = $script:clock.AddSeconds(40)
        Mock Start-Sleep {
            $script:clock = $script:clock.AddSeconds($Seconds)
            if ($script:clock -ge $script:otherGoneAt -and $script:rcaDeleted -notcontains $script:otherName) {
                $script:rcaDeleted.Add($script:otherName)
            }
        }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $sqlExport = @($script:rcaCommands | Where-Object { $_.Vm -eq 'sqlvm01' -and $_.Request.command -eq 'export' })
        $hostExport = @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'export' })
        $sqlExport.Count | Should -Be 1
        $hostExport.Count | Should -Be 1
        $sqlExport[0].At | Should -BeLessThan $script:otherGoneAt -Because 'sqlvm01 doesn''t wait for the T2 host, and its export went before the other job''s Run Command was gone'
        $hostExport[0].At | Should -BeGreaterOrEqual $script:otherGoneAt
        $script:rcaMostOpen['archost01'] | Should -Be 1 -Because 'the T2 host takes one Run Command at a time, across jobs too'
        $result.rca.status | Should -Be 'Pass'
        $result.rca.documents | Should -Be 2
        $status = Get-SessionStatus
        @($status.rca.leftVms) | Should -BeNullOrEmpty
        @($status.rcaLines | ForEach-Object status | Select-Object -Unique) | Should -Be @('Pass')
    }

    It 'leaves the T2 host''s capture for the next start when another job''s Rca Run Command is still there at the stop''s deadline (R871)' {
        Set-FixtureRunner
        $script:rcaListOpen = $true
        $other = 'DbHubControl-rca-archost01-0102-{0}' -f $script:clock.AddMinutes(-2).ToString('yyyyMMddHHmmss')
        $script:rcaCommands.Add([pscustomobject]@{ Vm = 'archost01'; Name = $other; Request = [pscustomobject]@{ command = 'part'; documentId = $script:fixtureIds[0]; part = 2 }; At = $script:clock })
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Name -ne $other }) | Should -BeNullOrEmpty -Because 'nothing goes there beside another job''s Run Command'
        @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match ('/runCommands/{0}$' -f $other) }) | Should -BeNullOrEmpty -Because 'another job may still have to read it'
        $result.rca.status | Should -Be 'Warning'
        $result.rca.documents | Should -Be 2 -Because 'sqlvm01''s documents were still fetched'
        $status = Get-SessionStatus
        @($status.rca.leftVms) | Should -Be @('archost01') -Because 'the next start exports what the stop couldn''t, with this session''s ID'
        $status.rca.final | Should -BeFalse
        $export = $status.rcaLines | Where-Object step -EQ 'RCA.EXPORT'
        $export.status | Should -Be 'Warning'
        $export.message | Should -Match 'archost01 takes one Run Command at a time \(R871\), and another job''s export Run Commands were still there when this export''s time was up, so this export sent nothing there'
        $export.fix | Should -Match '^What''s still on the VMs stays there, and a later session''s start exports it'
        $t2 = $status.rcaLines | Where-Object step -EQ 'RCA.CAPTURE.T2'
        $t2.status | Should -Be 'Warning'
        $t2.message | Should -Match '^T2: not exported\. archost01 takes one Run Command at a time'
        ($status.rcaLines | Where-Object step -EQ 'RCA.PENDING').message | Should -Match '^Still on the VMs, for this session''s history: the capture on archost01 that no export took, for the next start that sends activity there, until \d{4}-\d\d-\d\d \d\d:\d\d UTC, when the runner deletes it\.$'
    }

    Context 'the capture''s end at a session''s stop (O1, Final tests'' live round at d7df4f9f)' {
        BeforeAll {
            # The runner's note when a final export's wait ran out while its observer still captured (Exporter.StillCapturing).
            $script:stillCapturing = 'The observer was still capturing here, so what it captured after its last complete time stays for the next export.'
            # sqlvm01's runner, whose index says what -Note gives after its summary, and archost01's, which has nothing new; with
            # -Old, sqlvm01's VM-side control ran the export without --end-capture, for a runner that predates it, and with
            # -OldScript, a VM-side control that predates the option ran it without, and so says neither.
            function Set-CapturingRunner([string] $Note = '', [switch] $Old, [switch] $OldScript, [switch] $NothingNew) {
                $index = $script:fixtureIndex | ConvertFrom-Json
                if ($NothingNew) {
                    $index.documents = @()
                    $index.status = 'Not selected'
                    $index.message = 'Nothing new to export: the RCA observer captured nothing since the previous export.'
                }
                if ($Note) {
                    $index.message = '{0} {1}' -f $index.message, $Note
                    if (-not $NothingNew) {
                        $index.status = 'Warning'
                    }
                }
                $script:capturingIndex = 'DBHUBDEMO-RCA-INDEX ' + (ConvertTo-Json -InputObject $index -Depth 5 -Compress)
                $script:capturingEvidence = @{ host = 'SqlVm'; command = 'export'; exitCode = 0 }
                if ($Old) {
                    $script:capturingEvidence['endCaptureUnsupported'] = $true
                }
                elseif (-not $OldScript) {
                    $script:capturingEvidence['endCapture'] = $true
                }
                $script:capturingNothingNew = [bool]$NothingNew
                $script:rcaRunner = {
                    param($Command)
                    $request = $Command.Request
                    if ($Command.Vm -ne 'sqlvm01') {
                        return (New-TestRcaView -Status 'Not selected' -Message 'runner rca export: nothing was captured since the last export.')
                    }
                    if ($request.command -eq 'export') {
                        if ($script:capturingNothingNew) {
                            return (New-TestRcaView -Status 'Not selected' -Message 'runner rca export: nothing was captured since the last export.' -Line $script:capturingIndex -Evidence $script:capturingEvidence)
                        }
                        return (New-TestRcaView -Status 'Pass' -Message 'runner rca export: its line follows.' -Line $script:capturingIndex -Evidence $script:capturingEvidence)
                    }
                    $line = @($script:fixtureParts | Where-Object { $_.Split(' ')[2] -eq $request.documentId -and $_.Split(' ')[3].StartsWith(('{0}/' -f $request.part)) }) | Select-Object -First 1
                    return (New-TestRcaView -Status 'Pass' -Message 'runner rca part: its line follows.' -Line $line)
                }
            }
        }

        It 'asks each runner to end the capture in the stop''s own export, and in no other Run Command' {
            Set-FixtureRunner
            $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
            $result.status | Should -Be 'Stopped'
            $exports = @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' })
            @($exports | ForEach-Object Vm | Sort-Object) | Should -Be @('archost01', 'sqlvm01')
            @($exports | ForEach-Object { '{0}:{1}:{2}' -f $_.Vm, $_.Request.final, $_.Request.endCapture } | Sort-Object) | Should -Be @('archost01:True:True', 'sqlvm01:True:True')
            @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' }).Count | Should -Be 2 -Because 'the end rides in the export''s own Run Command: the stop sends no other'
            @($script:rcaCommands | Where-Object { $_.Request.command -ne 'export' -and $null -ne $_.Request.PSObject.Properties['endCapture'] }) | Should -BeNullOrEmpty
            $status = Get-SessionStatus
            @($status.rca.leftVms) | Should -BeNullOrEmpty
            $status.rca.final | Should -BeTrue
            @($status.rcaLines | Where-Object step -EQ 'RCA.PENDING') | Should -BeNullOrEmpty
        }

        It 'never asks for the end in a re-check''s export, or in the export of an earlier session''s capture that a start sends first (the review of 1ca916a9)' {
            # Only the stop's own export ends the capture. DbHub-Monitor's re-check runs while the session does, and a start
            # exports what an earlier session left on a VM right before its own activity goes out there.
            $session = $script:fixtureSession
            $running = [ordered]@{ schemaVersion = 1; sessionId = $session; phase = 'running'; acceptedUtc = '2026-10-27T15:00:00Z'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $session) }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
            $script:clock = [datetime]::new(2026, 10, 27, 15, 30, 0, [System.DateTimeKind]::Utc)
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
            Set-FixtureRunner
            $null = Update-DbHubSessionRca -Context (New-TestContext -NowUtc $script:clock) -Tags @{ DbHubSessionId = $session }
            $recheck = @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' })
            @($recheck | ForEach-Object Vm | Sort-Object) | Should -Be @('archost01', 'sqlvm01')
            @($script:rcaCommands | Where-Object { $null -ne $_.Request.PSObject.Properties['endCapture'] }) | Should -BeNullOrEmpty

            # The nightly stop ends the session after that re-check, so its own final export never runs: the next start
            # exports what it left on each VM first, final and with its ID, and still leaves the capture on.
            $script:rcaCommands.Clear()
            Set-TestSessionStart
            Set-FixtureRunner
            $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('b' * 32); requestedBy = 'presenter' }) -Context (New-TestContext -NowUtc $script:clock)
            $started.status | Should -BeIn 'Started', 'Partial'
            $earlier = @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' -and $_.Request.sessionId -eq $session })
            @($earlier | ForEach-Object { '{0}:{1}' -f $_.Vm, $_.Request.final } | Sort-Object) | Should -Be @('archost01:True', 'sqlvm01:True')
            @($script:rcaCommands | Where-Object { $null -ne $_.Request.PSObject.Properties['endCapture'] }) | Should -BeNullOrEmpty
        }

        It 'names a VM whose observer still captured when the stop''s export ended: its leftVms, RCA.PENDING, and RCA.EXPORT''s Warning say so' {
            Set-CapturingRunner -Note $script:stillCapturing
            $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
            $result.status | Should -Be 'Stopped'
            $result.rca.documents | Should -Be 2 -Because 'what it took is saved as before'
            $status = Get-SessionStatus
            @($status.rca.leftVms) | Should -Be @('sqlvm01')
            $status.rca.final | Should -BeFalse
            $status.rca.finalRan | Should -BeTrue
            $export = $status.rcaLines | Where-Object step -EQ 'RCA.EXPORT'
            $export.status | Should -Be 'Warning'
            $export.message | Should -Match 'sqlvm01''s observer was still capturing when its export ended \(its capture didn''t end in time\), so what it captured after that stays on sqlvm01 for a later start \(RCA\.PENDING\)\.'
            $export.fix | Should -Match '^What''s still on the VMs stays there, and a later session''s start exports it'
            $export.fix | Should -Not -Match 'deploy\.ps1'
            ($status.rcaLines | Where-Object step -EQ 'RCA.PENDING').message | Should -Match '^Still on the VMs, for this session''s history: the capture on sqlvm01 that no export took, for the next start that sends activity there, until \d{4}-\d\d-\d\d \d\d:\d\d UTC, when the runner deletes it\.$'
            # The next start exports it first there, with this session's ID.
            $backlog = Get-DbHubRcaBacklog -Settings (New-TestContext).Settings -Previous (ConvertTo-DbHubDictionary -InputObject $status) -SessionId ('b' * 32) -NowUtc $script:clock
            $entry = @($backlog.Entries | Where-Object { $_['sessionId'] -eq $script:fixtureSession })
            $entry.Count | Should -Be 1
            @($entry[0]['leftVms']) | Should -Be @('sqlvm01')
        }

        It 'says when the runner predates the capture''s end, with ./scripts/deploy.ps1 as the fix' {
            Set-CapturingRunner -Note $script:stillCapturing -Old
            $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
            $status = Get-SessionStatus
            @($status.rca.leftVms) | Should -Be @('sqlvm01')
            $export = $status.rcaLines | Where-Object step -EQ 'RCA.EXPORT'
            $export.message | Should -Match 'sqlvm01''s observer was still capturing when its export ended \(its workload runner predates ending the capture at a stop\)'
            $export.fix | Should -Match 'a runner or bootstrap bundle that predates ending the capture at a session''s stop is updated by \./scripts/deploy\.ps1\.$'
        }

        It 'says when the VM''s bootstrap bundle predates the capture''s end, whose control script passes nothing on, with ./scripts/deploy.ps1 as the fix' {
            Set-CapturingRunner -Note $script:stillCapturing -OldScript
            $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
            $status = Get-SessionStatus
            @($status.rca.leftVms) | Should -Be @('sqlvm01')
            $export = $status.rcaLines | Where-Object step -EQ 'RCA.EXPORT'
            $export.message | Should -Match 'sqlvm01''s observer was still capturing when its export ended \(its bootstrap bundle predates ending the capture at a stop\)'
            $export.fix | Should -Match 'a runner or bootstrap bundle that predates ending the capture at a session''s stop is updated by \./scripts/deploy\.ps1\.$'
        }

        It 'names a VM whose stop''s export found nothing new while its observer still captured' {
            Set-CapturingRunner -Note $script:stillCapturing -NothingNew
            $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
            $status = Get-SessionStatus
            @($status.rca.leftVms) | Should -Be @('sqlvm01')
            ($status.rcaLines | Where-Object step -EQ 'RCA.EXPORT').status | Should -Be 'Warning'
            ($status.rcaLines | Where-Object step -EQ 'RCA.PENDING').message | Should -Match 'the capture on sqlvm01 that no export took'
        }

        It 'names no VM from the note when the export didn''t ask for the end, as an earlier session''s at a start, which a profile set at boot can keep capturing' {
            Set-CapturingRunner -Note $script:stillCapturing
            $done = Invoke-DbHubRcaSessionExport -Context (New-TestContext) -SessionId $script:fixtureSession -Final -Minutes 30
            @($done.State['leftVms']) | Should -BeNullOrEmpty
            $done.State['final'] | Should -BeTrue
            $line = @($done.Lines | Where-Object { $_.Step -eq 'RCA.EXPORT' })[0]
            $line.Status | Should -Be 'Pass'
            $line.Message | Should -Not -Match 'still capturing'
        }
    }

    It 'counts the sessions ahead of a stop''s evidence the same in Windows PowerShell 5.1, whose Sort-Object reverses equal times (the transport review of f99451f7)' {
        $powershell = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue
        if (-not $IsWindows -or -not $powershell) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 runs on Windows only'
            return
        }
        # An earlier session's documents that the runner deletes when it deletes this session's: a start fetches the first of
        # equal times, and this session's entry is the last, so it waits for the start after the next.
        $probe = {
            param([string] $Common, [string] $SettingsJson, [string] $Session)
            . $Common
            $settings = ConvertFrom-DbHubSetting -Json $SettingsJson
            $now = New-Object -TypeName DateTime -ArgumentList 2026, 11, 21, 18, 55, 0, ([System.DateTimeKind]::Utc)
            $earlier = [ordered]@{ sessionId = 'fedcba9876543210fedcba9876543210'; pending = @([ordered]@{ documentId = '20261119T100000Z-sqlvm01-0001'; parts = 1; sha256 = ('a' * 64); vm = 'sqlvm01' }); leftVms = @(); expiresUtc = '2026-11-28T18:55:00Z' }
            $state = [ordered]@{ sessionId = $Session; bundles = @(); documents = @(); pending = @([ordered]@{ documentId = '20261121T182100Z-sqlvm01-0001'; parts = 1; sha256 = ('b' * 64); vm = 'sqlvm01' }); leftVms = @(); final = $false; finalRan = $true; status = 'Warning'; message = ''; boundVms = @() }
            $status = [ordered]@{ schemaVersion = 1; sessionId = $Session; phase = 'stopped'; updatedUtc = ''; acceptedUtc = '2026-11-21T18:00:00Z'; metrics = [ordered]@{ status = 'Pass' }; rca = $state; rcaEarlierPending = @($earlier) }
            return [string](Get-DbHubRcaStopLeftLine -Settings $settings -Status $status -NowUtc $now)['message']
        }
        $common = Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1'
        $here = & $probe $common $script:settingsJson $script:fixtureSession
        $inputFile = Join-Path -Path $TestDrive -ChildPath 'ahead.json'
        Set-Content -LiteralPath $inputFile -Value (ConvertTo-Json -InputObject @{ common = $common; settings = $script:settingsJson; session = $script:fixtureSession; probe = $probe.ToString() } -Depth 4) -Encoding utf8
        $command = "`$in = Get-Content -LiteralPath '{0}' -Raw | ConvertFrom-Json; `$probe = [scriptblock]::Create(`$in.probe); `$out = & `$probe `$in.common `$in.settings `$in.session; [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]`$out))" -f $inputFile
        $output = @(& $powershell.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command)
        $LASTEXITCODE | Should -Be 0
        $there = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(([string]($output | Select-Object -Last 1)).Trim()))
        $there | Should -Match 'the first from 18:21 UTC, which a later start fetches, behind 1 earlier session\(s\), one per start, until 2026-11-28 18:55 UTC, when the runner deletes them\.$'
        $there | Should -Be $here
    }

    It 'keeps equal times in the backlog''s order in the queue a start writes for later starts, in Windows PowerShell 5.1 too (the re-review of 087e096a)' {
        $powershell = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue
        if (-not $IsWindows -or -not $powershell) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 runs on Windows only'
            return
        }
        # Three earlier sessions whose documents the runner deletes at the same time: a later start fetches the first of equal
        # times, and a stop's RCA.PENDING line counts the others ahead of its own, so the queue keeps their order. With settings
        # from before the export, the start fetches none of them, and only writes the queue.
        $probe = {
            param([string] $Common, [string] $SettingsJson)
            . $Common
            $settings = ConvertFrom-DbHubSetting -Json $SettingsJson
            $settings.rcaScriptTemplate = ''
            $now = New-Object -TypeName DateTime -ArgumentList 2026, 11, 22, 18, 0, 0, ([System.DateTimeKind]::Utc)
            $context = Initialize-DbHubContext -Settings $settings -JobId 'aaaaaaaa-0000-0000-0000-00000000000a' -NowUtc $now
            $make = { param([string] $Id, [string] $Document) [ordered]@{ sessionId = $Id; pending = @([ordered]@{ documentId = $Document; parts = 1; sha256 = ('a' * 64); vm = 'sqlvm01' }); leftVms = @(); boundVms = @(); expiresUtc = $now.AddDays(5); heldUntilUtc = $now.AddDays(20); startUtc = $null; endUtc = $null; rca = $null; previous = $false; known = $true; mustFetch = $false } }
            $entries = @((& $make ('a' * 32) '20261120T100000Z-sqlvm01-0001'), (& $make ('b' * 32) '20261120T110000Z-sqlvm01-0001'), (& $make ('c' * 32) '20261120T120000Z-sqlvm01-0001'))
            $status = [ordered]@{ schemaVersion = 1; sessionId = '0123456789abcdef0123456789abcdef'; phase = 'starting'; steps = @() }
            Invoke-DbHubRcaEarlier -Context $context -Status $status -Entry $entries
            return ((@($status['rcaEarlierPending']) | ForEach-Object { ([string]$_['sessionId']).Substring(0, 1) }) -join ',')
        }
        $common = Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1'
        $here = & $probe $common $script:settingsJson
        $inputFile = Join-Path -Path $TestDrive -ChildPath 'queue.json'
        Set-Content -LiteralPath $inputFile -Value (ConvertTo-Json -InputObject @{ common = $common; settings = $script:settingsJson; probe = $probe.ToString() } -Depth 4) -Encoding utf8
        $command = "`$in = Get-Content -LiteralPath '{0}' -Raw | ConvertFrom-Json; `$probe = [scriptblock]::Create(`$in.probe); `$out = & `$probe `$in.common `$in.settings; [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]`$out))" -f $inputFile
        $output = @(& $powershell.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command)
        $LASTEXITCODE | Should -Be 0
        $there = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(([string]($output | Select-Object -Last 1)).Trim()))
        $there | Should -Be 'a,b,c'
        $there | Should -Be $here
    }

    It 'writes a stopped session''s RCA.PENDING line again when a re-check routes another session''s documents ahead of its own (the transport review of f99451f7)' {
        $state = [ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); pending = @(New-TestPending -DocumentId $script:fixtureIds[1] -Vm 'sqlvm01'); leftVms = @(); final = $false; finalRan = $true; status = 'Warning'; message = ''; boundVms = @() }
        $older = 'Still on the VMs, for this session''s history: 1 document(s) on sqlvm01 not fetched whole, the first from 17:00 UTC, which the next session''s start fetches, until 2026-11-03 14:00 UTC, when the runner deletes them.'
        # The stop wrote its status at 14:00; the re-check hands its documents over at 15:00, and its write sets the time again,
        # which the next start counts this session's documents from.
        $status = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'stopped'; updatedUtc = '2026-10-27T14:00:00Z'; acceptedUtc = '2026-10-27T13:30:00Z'; metrics = [ordered]@{ status = 'Pass' }; rca = $state; rcaLines = @([ordered]@{ step = 'RCA.PENDING'; status = 'Info'; message = $older; fix = '' }) }
        $other = [ordered]@{ documentId = '20261027T143000Z-sqlvm01-0001'; parts = 1; sha256 = ('b' * 64); vm = 'sqlvm01'; sessionId = 'fedcba9876543210fedcba9876543210' }
        $own = Add-DbHubRcaHandoff -Context (New-TestContext) -Status $status -SessionId $script:fixtureSession -Document @() -Elsewhere @($other)
        $own | Should -Be 0 -Because 'none of the documents is the session''s own'
        $left = @((Get-SessionStatus).rcaLines | Where-Object step -EQ 'RCA.PENDING')
        $left.Count | Should -Be 1
        $left[0].message | Should -Match '^Still on the VMs, for this session''s history: 1 document\(s\) on sqlvm01 not fetched whole, the first from 17:00 UTC, which a later start fetches, behind 1 earlier session\(s\), one per start, until '
    }
    It 'says what a stop leaves on the VMs, which start takes it, and until when, behind an earlier session''s evidence (step 1.8''s finding 4)' {
        $now = [datetime]::new(2026, 11, 21, 18, 55, 0, [System.DateTimeKind]::Utc)
        $earlier = [ordered]@{ sessionId = 'fedcba9876543210fedcba9876543210'; pending = @([ordered]@{ documentId = '20261119T100000Z-sqlvm01-0001'; parts = 1; sha256 = ('a' * 64); vm = 'sqlvm01' }); leftVms = @(); expiresUtc = '2026-11-25T10:00:00Z' }
        $state = [ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); pending = @((New-TestPending -DocumentId $script:fixtureIds[1] -Vm 'sqlvm01'), (New-TestPending -DocumentId $script:fixtureIds[0] -Vm 'sqlvm01')); leftVms = @('archost01'); final = $false; finalRan = $true; status = 'Warning'; message = ''; boundVms = @() }
        $status = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'stopped'; updatedUtc = ''; acceptedUtc = '2026-11-21T18:00:00Z'; metrics = [ordered]@{ status = 'Pass' }; rca = $state; rcaEarlierPending = @($earlier) }
        $line = Get-DbHubRcaStopLeftLine -Settings (New-TestContext).Settings -Status $status -NowUtc $now
        $line.step | Should -Be 'RCA.PENDING'
        $line.status | Should -Be 'Info'
        $line.message | Should -Be 'Still on the VMs, for this session''s history: 2 document(s) on sqlvm01 not fetched whole, the first from 16:50 UTC, which a later start fetches, behind 1 earlier session(s), one per start, until 2026-11-28 18:55 UTC; and the capture on archost01 that no export took, for the next start that sends activity there, until 2026-12-21 18:00 UTC, when the runner deletes each.'
        # Its lines keep one such line, the newest.
        $status['rcaLines'] = @([ordered]@{ step = 'RCA.EXPORT'; status = 'Warning'; message = 'm'; fix = '' }, [ordered]@{ step = 'RCA.PENDING'; status = 'Info'; message = 'older'; fix = '' })
        $lines = @(Get-DbHubRcaStopLineList -Settings (New-TestContext).Settings -Status $status -NowUtc $now)
        @($lines | ForEach-Object { $_['step'] }) | Should -Be @('RCA.EXPORT', 'RCA.PENDING')
        $lines[1]['message'] | Should -Be $line.message
        # Nothing left there: no line.
        $state['pending'] = @()
        $state['leftVms'] = @()
        $state['final'] = $true
        Get-DbHubRcaStopLeftLine -Settings (New-TestContext).Settings -Status $status -NowUtc $now | Should -BeNullOrEmpty
    }

    It 'sends the T2 host its stop''s export beside an Rca Run Command more than an hour old that Azure keeps listing while it deletes it (review of 242a3ef7)' {
        # F31: Azure listed a Run Command in Deleting for hours. Get-DbHubRcaRoom asks for its delete each time; the mock's
        # own list keeps it, as Azure did, whatever is asked of it.
        Set-FixtureRunner
        $script:rcaListOpen = $true
        $began = $script:clock
        $stuck = 'DbHubControl-rca-archost01-0102-{0}' -f $script:clock.AddHours(-3).ToString('yyyyMMddHHmmss')
        $script:runCommands['archost01'] = @(@{ name = $stuck; properties = @{ provisioningState = 'Deleting' } })
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $hostExport = @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'export' })
        $hostExport.Count | Should -Be 1 -Because 'a name more than an hour old holds nothing up for long'
        # The re-review of e55e000b: its delete first, for 90 s from the export's start; then beside it, as stuck.
        $hostExport[0].At | Should -BeGreaterOrEqual $began.AddSeconds(90)
        $result.rca.status | Should -Be 'Pass'
        $status = Get-SessionStatus
        @($status.rca.leftVms) | Should -BeNullOrEmpty
    }

    It 'waits for the delete of an hour-old Rca Run Command before the T2 host''s export, and sends once Azure no longer lists it (re-review of e55e000b)' {
        # A crashed job's leftover, finished: Get-DbHubRcaRoom deletes it, and Azure lists it for 20 s more.
        Set-FixtureRunner
        $script:rcaListOpen = $true
        $began = $script:clock
        $script:leftover = 'DbHubControl-rca-archost01-0102-{0}' -f $script:clock.AddHours(-3).ToString('yyyyMMddHHmmss')
        $script:goneAt = $script:clock.AddSeconds(20)
        $script:runCommands['archost01'] = @({ if ($script:clock -lt $script:goneAt) { @{ name = $script:leftover; properties = @{ provisioningState = 'Deleting' } } } })
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $script:rcaDeleted | Should -Contain $script:leftover -Because 'Get-DbHubRcaRoom asks for its delete'
        $hostExport = @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'export' })
        $hostExport.Count | Should -Be 1
        $hostExport[0].At | Should -BeGreaterOrEqual $script:goneAt -Because 'R871: never beside its delete'
        $hostExport[0].At | Should -BeLessThan $began.AddSeconds(90) -Because 'it goes once the delete is done, not at the bound'
        $result.rca.status | Should -Be 'Pass'
    }

    It 'says the T2 host''s Run Commands couldn''t be listed, not that another job''s were there, when its list fails to the stop''s deadline (review of 242a3ef7)' {
        Set-FixtureRunner
        Mock Get-DbHubRcaListed { [pscustomobject]@{ Ok = $false; Names = @(); Stale = @() } }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' }) | Should -BeNullOrEmpty -Because 'a host whose list fails keeps waiting, as it should'
        $export = (Get-SessionStatus).rcaLines | Where-Object step -EQ 'RCA.EXPORT'
        $export.status | Should -Be 'Warning'
        $export.message | Should -Match 'archost01 takes one Run Command at a time \(R871\), and its Run Commands couldn''t be listed when this export''s time was up, so this export sent nothing there'
        $export.message | Should -Not -Match 'another job'
    }

    It 'lists the T2 host only from 60 seconds after the stop''s mark, past a re-check''s three PUTs and two conflict waits (review of 242a3ef7)' {
        # A running session's status copy, which the stop marks (stopBegunUtc) before its export.
        $running = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T14:50:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        Set-FixtureRunner
        $script:rcaListOpen = $true
        $begun = $script:clock
        # The export's own check, by when it runs: the stop's other lists of Run Commands (Clear-DbHubOldRunCommand) aren't it.
        $script:listedAt = [System.Collections.Generic.List[datetime]]::new()
        $script:realListed = ${function:Get-DbHubRcaListed}
        Mock Get-DbHubRcaListed {
            $script:listedAt.Add($script:clock)
            & $script:realListed -Context $Context -VmName $VmName
        }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $result.rca.status | Should -Be 'Pass'
        $script:listedAt.Count | Should -BeGreaterThan 0
        @($script:listedAt | Where-Object { $_ -lt $begun.AddSeconds(60) }) | Should -BeNullOrEmpty -Because 'a re-check that read the mark open just before it may still send there'
        $hostExport = @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'export' })
        $hostExport.Count | Should -Be 1
        $hostExport[0].At | Should -BeGreaterOrEqual $begun.AddSeconds(60)
        $sqlExport = @($script:rcaCommands | Where-Object { $_.Vm -eq 'sqlvm01' -and $_.Request.command -eq 'export' })
        $sqlExport[0].At | Should -BeLessThan $begun.AddSeconds(60) -Because 'sqlvm01 doesn''t wait for it'
    }

    It 'takes a document of no session with the session''s evidence, as the notebook writes it, and hands another session''s to that session (review of 93243d6)' {
        # The operator's scripts export with --session none: a span they bound keeps no session for its later documents.
        Set-ServedRunner -Case @(@{ Id = '20261120T180000Z-sqlvm01-0003'; Session = $null }, @{ Id = '20261120T181500Z-sqlvm01-0004'; Session = ('a' * 32) }) -EveryExport
        $done = Invoke-DbHubRcaSessionExport -Context (New-TestContext) -SessionId $script:fixtureSession -Final -Minutes 30 -OnlyVm @('sqlvm01')
        @($done.State['documents'] | ForEach-Object { $_['documentId'] }) | Should -Be @('20261120T180000Z-sqlvm01-0003')
        $line = @($done.Lines | Where-Object { $_.Step -eq 'RCA.EXPORT' })[0]
        $line.Status | Should -Be 'Pass' -Because 'the runner keeps a span bound to the session of the first export that took from it, so its later documents are that session''s'
        $line.Message | Should -Match '1 document\(s\) of another session go with that session''s evidence \(RCA\.EARLIER\)\.$'
        @($done.Others | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_['documentId'], $_['sessionId'], $_['vm'], $_['parts'] }) | Should -Be @(('20261120T181500Z-sqlvm01-0004|{0}|sqlvm01|{1}' -f ('a' * 32), @($script:servedParts['20261120T181500Z-sqlvm01-0004']).Count))
        @(Get-RcaBundle | ForEach-Object { ($_.Value | ConvertFrom-Json).parts } | ForEach-Object { $_.Split(' ')[2] } | Select-Object -Unique) | Should -Be @('20261120T180000Z-sqlvm01-0003') -Because 'another session''s document isn''t written under this one'
        # A stop of no session (start-demo.ps1's auto-stop through the control) takes any session's.
        $runner = $script:rcaRunner
        Reset-TestAzure
        $script:rcaRunner = $runner
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        $done = Invoke-DbHubRcaSessionExport -Context (New-TestContext) -SessionId '' -Final -Minutes 30 -OnlyVm @('sqlvm01')
        @($done.State['documents'] | ForEach-Object { $_['documentId'] } | Sort-Object) | Should -Be @('20261120T180000Z-sqlvm01-0003', '20261120T181500Z-sqlvm01-0004')
    }

    It 'stops at its time, deletes what''s still running, and keeps the documents it didn''t fetch whole for the next export' {
        Set-FixtureRunner
        $fixture = $script:rcaRunner
        # The second document's parts never end.
        $script:rcaRunner = {
            param($Command)
            if ($Command.Request.command -eq 'part' -and $Command.Request.documentId -eq '20261120T170000Z-sqlvm01-0002') { return $null }
            return (& $fixture $Command)
        }.GetNewClosure()
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped' -Because 'the export never fails the stop'
        $result.rca.status | Should -Be 'Warning'
        $status = Get-SessionStatus
        $status.rca.final | Should -BeFalse
        @($status.rca.documents.documentId) | Should -Be @('20261120T165000Z-sqlvm01-0001')
        @($status.rca.pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @('20261120T170000Z-sqlvm01-0002@sqlvm01')
        ($status.rcaLines | Where-Object step -EQ 'RCA.EXPORT').message | Should -Match '1 document\(s\) weren''t fetched whole in time; they stay on sqlvm01 for the next export'
        ($status.rcaLines | Where-Object step -EQ 'RCA.EXPORT').fix | Should -Be 'What''s still on the VMs stays there, and a later session''s start exports it, one earlier session''s per start; that start''s RCA.EARLIER lines say until when.'
        # Step 1.8's finding 4: what the stop leaves on the VMs, which start takes it, and until when.
        $left = $status.rcaLines | Where-Object step -EQ 'RCA.PENDING'
        $left.status | Should -Be 'Info'
        $left.message | Should -Be ('Still on the VMs, for this session''s history: 1 document(s) on sqlvm01 not fetched whole, the first from 17:00 UTC, which the next session''s start fetches, until {0} UTC, when the runner deletes them.' -f $script:clock.AddDays(7).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture))
        @($status.rcaLines | ForEach-Object step)[-1] | Should -Be 'RCA.PENDING'
        $status.rca.finalRan | Should -BeTrue -Because 'its final export ran on every VM, so the next start sends none: it fetches the document''s parts'
        @($script:rcaCommands | Where-Object { $script:rcaDeleted -notcontains $_.Name }) | Should -BeNullOrEmpty
        $index = ($script:secrets['dbhub-session-metrics'][-1].Value | ConvertFrom-Json).rca
        @($index.documents.documentId) | Should -Be @('20261120T165000Z-sqlvm01-0001')
        $index.status | Should -Be 'Warning'
    }

    It 'says a runner or a bootstrap bundle older than the export is updated by deploy.ps1, as RCA.EXPORT and RCA.CAPTURE Warnings, and still stops' -ForEach @(
        @{ Case = 'runner'; View = { New-TestRcaView -Status 'Not supported' -Message 'runner rca export: this VM''s runner predates the RCA export (ADR 0031), so nothing was exported; ./scripts/deploy.ps1 updates it.' -Evidence @{ oldRunner = $true } }; Says = 'workload runner predates the RCA export' }
        @{ Case = 'bundle'; View = { New-TestRcaView -Status 'Fail' -Message 'Unknown action; use EnableT3, EnableT4, Runner, or StopGuest.' }; Says = 'bootstrap bundle predates the RCA export' }
    ) {
        $script:oldView = $View
        $script:rcaRunner = { & $script:oldView }
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
        $result.status | Should -Be 'Stopped'
        $lines = @((Get-SessionStatus).rcaLines)
        ($lines | Where-Object step -EQ 'RCA.EXPORT').status | Should -Be 'Warning'
        ($lines | Where-Object step -EQ 'RCA.EXPORT').message | Should -Match $Says
        @($lines | Where-Object step -Like 'RCA.CAPTURE.*' | ForEach-Object step) | Should -Be @('RCA.CAPTURE.T1', 'RCA.CAPTURE.T2', 'RCA.CAPTURE.T3', 'RCA.CAPTURE.T4', 'RCA.CAPTURE.T4-replica')
        ($lines | Where-Object step -EQ 'RCA.CAPTURE.T2').fix | Should -Be 'Run ./scripts/deploy.ps1, which updates the runner and its bootstrap bundle on the VMs.'
        @(Get-RcaBundle) | Should -BeNullOrEmpty
        ($script:secrets['dbhub-session-metrics'][-1].Value | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'rca'
    }

    It 'skips a document whose parts don''t add up to its SHA-256, and says so' {
        Set-FixtureRunner
        $fixture = $script:rcaRunner
        $script:rcaRunner = {
            param($Command)
            $view = & $fixture $Command
            if ($Command.Request.command -eq 'part' -and $Command.Request.documentId -eq '20261120T165000Z-sqlvm01-0001' -and $Command.Request.part -eq 2) {
                # Other valid Base64 in the part's slice: the part's own checks pass, the document's SHA-256 doesn't.
                $lines = $view['output'] -split "`n"
                $fields = $lines[-1].Split(' ')
                $fields[5] = $(if ($fields[5].StartsWith('AAAA')) { 'BBBB' } else { 'AAAA' }) + $fields[5].Substring(4)
                $lines[-1] = $fields -join ' '
                $view['output'] = $lines -join "`n"
            }
            return $view
        }.GetNewClosure()
        $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
        $result.rca.status | Should -Be 'Warning'
        $status = Get-SessionStatus
        @($status.rca.documents.documentId) | Should -Be @('20261120T170000Z-sqlvm01-0002')
        ($status.rcaLines | Where-Object step -EQ 'RCA.EXPORT').message | Should -Match '20261120T165000Z-sqlvm01-0001 was skipped: its SHA-256 doesn''t match\.'
        @((Get-RcaBundle)[0].Value | ConvertFrom-Json | ForEach-Object { $_.parts } | ForEach-Object { $_.Split(' ')[2] } | Select-Object -Unique) | Should -Be @('20261120T170000Z-sqlvm01-0002')
    }

    It 'exports at each re-check while the session runs, and the stop''s index lists every bundle of the session' {
        $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'deallocated' }
        $script:t4 = 'Stopped'
        $script:replica = ''
        $script:autostop = ''
        $script:groupTags = @{ DbHubT4Replica = 'Session' }
        $script:t4ReadyAt = $script:clock.AddMinutes(4)
        Set-FixtureRunner -Batches '20261120T165000Z-sqlvm01-0001'
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:fixtureSession; requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands) | Should -BeNullOrEmpty -Because 'no earlier session left evidence behind'
        (Get-SessionStatus).rca.sessionId | Should -Be $script:fixtureSession
        $script:clock = $script:clock.AddMinutes(30)
        $check = Invoke-DbHubMonitor -Context (New-TestContext -NowUtc $script:clock)
        $check.rca | Should -Be 'Exported'
        $running = Get-SessionStatus
        $running.phase | Should -Be 'running'
        @($running.rca.documents.documentId) | Should -Be @('20261120T165000Z-sqlvm01-0001')
        @($running.rca.bundles).Count | Should -Be 1
        $running.rca.final | Should -BeFalse
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { $_.Request.final } | Select-Object -Unique) | Should -Be @($false)
        @($running.steps | Where-Object step -EQ 'RCA.EXPORT').Count | Should -Be 1
        # Nothing new at the next re-check: nothing is written.
        $writes = $script:secrets['dbhub-session-status'].Count
        $again = Invoke-DbHubMonitor -Context (New-TestContext -NowUtc $script:clock.AddMinutes(5))
        $again.rca | Should -Be 'Nothing'
        $script:secrets['dbhub-session-status'].Count | Should -Be $writes
        # The stop's export holds the second document; its index lists both bundles.
        Set-FixtureRunner -Batches '20261120T170000Z-sqlvm01-0002'
        $stop = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext -NowUtc $script:clock.AddMinutes(40))
        $stop.status | Should -BeIn 'Stopped', 'Partial'
        $index = ($script:secrets['dbhub-session-metrics'][-1].Value | ConvertFrom-Json).rca
        @($index.bundles).Count | Should -Be 2
        @($index.bundles) | Should -Be @(Get-RcaBundle | ForEach-Object Version)
        @($index.documents.documentId) | Should -Be $script:fixtureIds
        @((Expand-TestBundle -Json @(Get-RcaBundle | ForEach-Object Value)).Keys) | Should -Be $script:fixtureIds
        (Get-SessionStatus).rca.final | Should -BeTrue
    }

    It 'leaves a re-check''s last minutes to the stop, and reports nothing for a VM that doesn''t run between them' {
        $status = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T15:05:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $status -Depth 8 -Compress
        (Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }).Outcome | Should -Be 'Late'
        @($script:rcaCommands) | Should -BeNullOrEmpty
        $status['runEndUtc'] = '2026-10-27T16:30:00Z'
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $status -Depth 8 -Compress
        $script:vm['archost01'] = 'deallocated'
        (Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }).Outcome | Should -Be 'Nothing'
        $script:secrets.ContainsKey('dbhub-session-status') | Should -BeFalse -Because 'nothing new was exported, and a VM that doesn''t run is the host check''s to report'
    }

    It 'writes no re-check bundle once the session''s stop has begun, and the next start exports what the re-check found (review of 15ad76d)' {
        # DbHub-Monitor's re-check exports while the session runs, and Stop now ends the session while it fetches the parts.
        $running = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        Set-FixtureRunner -Batches @($script:fixtureIds[0], $script:fixtureIds[1])
        $script:fixtureRunner = $script:rcaRunner
        $script:stopFired = $false
        $script:rcaRunner = {
            param($Command)
            if (-not $script:stopFired -and $Command.Request.command -eq 'part') {
                $script:stopFired = $true
                $script:stopped = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext -NowUtc $script:clock)
            }
            return (& $script:fixtureRunner $Command)
        }
        $check = Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }
        $check.Outcome | Should -Be 'Changed'
        $script:stopped.status | Should -Be 'Stopped'
        $versions = @($script:secrets['dbhub-session-metrics'])
        [string]$versions[-1].Tags['rca'] | Should -Not -Be 'bundle' -Because 'nothing is written after the stop''s final version of the metrics'
        @(Get-RcaBundle).Count | Should -Be 1 -Because 'the stop''s own bundle only'
        $status = Get-SessionStatus
        $status.phase | Should -Be 'stopped'
        $status.metrics.version | Should -Be $versions[-1].Version
        $final = $versions[-1].Value | ConvertFrom-Json
        @($final.series).Count | Should -BeGreaterThan 0
        @($final.rca.documents.documentId) | Should -Be @($script:fixtureIds[1])
        # The re-check's document goes to the stop's status, still to export.
        @($status.rca.pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @(('{0}@sqlvm01' -f $script:fixtureIds[0]))
        $status.rca.final | Should -BeFalse
        $status.PSObject.Properties.Name | Should -Not -Contain 'stopBegunUtc'
        $script:automationVariables['DbHubSessionStatus'] | Should -BeExactly $script:secrets['dbhub-session-status'][-1].Value
        # The next session's start exports it, and Run all saves it with that session's history.
        $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'deallocated' }
        $script:t4 = 'Stopped'
        $script:replica = ''
        $script:autostop = ''
        $script:groupTags = @{ DbHubT4Replica = 'Session' }
        $script:t4ReadyAt = $script:clock.AddMinutes(4)
        $script:rcaRunner = $script:fixtureRunner
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = 'fedcba9876543210fedcba9876543210'; requestedBy = 'presenter' }) -Context (New-TestContext -NowUtc $script:clock)
        $started.status | Should -BeIn 'Started', 'Partial'
        $earlier = (Get-SessionStatus).rcaEarlier
        $earlier.sessionId | Should -Be $script:fixtureSession
        @($earlier.documents.documentId | Sort-Object) | Should -Be $script:fixtureIds
    }

    It 'sends no more Run Commands from a re-check once the session''s stop has begun, and hands its document to the stop (live 2026-11-21, R871)' {
        # The re-check fetches a T2 document from archost01, one part at a time; Stop now begins while its first part runs
        # (live: the re-check sent its last two parts after the stop had begun, beside the stop's export there).
        $running = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        $id = '20261027T142000Z-archost01-0001'
        Set-ServedRunner -Case @(@{ Id = $id; Session = $script:fixtureSession }) -Vm @('archost01')
        $parts = @($script:servedParts[$id]).Count
        $parts | Should -BeGreaterThan 1 -Because 'the document needs a part after the first'
        $script:servedRunner = $script:rcaRunner
        $script:stopFired = $false
        $script:rcaRunner = {
            param($Command)
            if (-not $script:stopFired -and $Command.Vm -eq 'archost01' -and $Command.Request.command -eq 'part') {
                $script:stopFired = $true
                $script:stopAt = $script:clock
                $script:stopped = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext -NowUtc $script:clock)
            }
            return (& $script:servedRunner $Command)
        }
        $check = Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }
        $check.Outcome | Should -Be 'Changed'
        $script:stopped.status | Should -Be 'Stopped'
        $exports = @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'export' })
        $exports.Count | Should -Be 2 -Because 'the re-check''s, then the stop''s'
        $exports[1].Request.final | Should -BeTrue
        # Each export names its Run Commands with the time it began.
        $recheckStamp = '-' + $exports[0].Name.Split('-')[-1]
        $exports[1].Name.EndsWith($recheckStamp) | Should -BeFalse
        $recheck = @($script:rcaCommands | Where-Object { $_.Name.EndsWith($recheckStamp) })
        @($recheck | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'part' }).Count | Should -Be 1 -Because 'the re-check sends nothing once the stop has begun'
        @($recheck | Where-Object { $_.At -ge $script:stopAt }) | Should -BeNullOrEmpty
        @(Get-RcaBundle) | Should -BeNullOrEmpty -Because 'no re-check bundle goes after the stop''s final version of the metrics'
        # What the re-check listed goes to the stopped status, still to export, for the next session's start.
        $status = Get-SessionStatus
        $status.phase | Should -Be 'stopped'
        @($status.rca.pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @(('{0}@archost01' -f $id))
        # Step 1.8's finding 4: the stop's lines say so, with the re-check's document, which start takes it, and until when.
        $left = @($status.rcaLines | Where-Object step -EQ 'RCA.PENDING')
        $left.Count | Should -Be 1
        $left[0].message | Should -Match '^Still on the VMs, for this session''s history: 1 document\(s\) on archost01 not fetched whole, the first from 14:20 UTC, which the next session''s start fetches, until \d{4}-\d\d-\d\d \d\d:\d\d UTC, when the runner deletes them\.$'
    }

    It 'keeps the stop''s export off the T2 host while a running re-check''s Run Command is listed there, never two at once (review of 242a3ef7)' {
        # The fence test above with Azure's list of the export's Run Commands on: the stop begins while the re-check's first
        # part runs on archost01, so its own export there waits for that part, which the re-check reads only after the stop
        # (both run in this one test's flow), and ends Busy, leaving the T2 host's capture to the next start.
        $running = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        $id = '20261027T142000Z-archost01-0001'
        Set-ServedRunner -Case @(@{ Id = $id; Session = $script:fixtureSession }) -Vm @('archost01')
        $script:rcaListOpen = $true
        $script:servedRunner = $script:rcaRunner
        $script:stopFired = $false
        $script:rcaRunner = {
            param($Command)
            if (-not $script:stopFired -and $Command.Vm -eq 'archost01' -and $Command.Request.command -eq 'part') {
                $script:stopFired = $true
                $script:stopped = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext -NowUtc $script:clock)
            }
            return (& $script:servedRunner $Command)
        }
        $check = Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }
        $check.Outcome | Should -Be 'Changed'
        $script:stopped.status | Should -Be 'Stopped'
        @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'export' }).Count | Should -Be 1 -Because 'only the re-check''s: the stop sent none beside its part'
        $script:rcaMostOpen['archost01'] | Should -Be 1 -Because 'the T2 host takes one Run Command at a time, across jobs too'
        $status = Get-SessionStatus
        $status.phase | Should -Be 'stopped'
        @($status.rca.leftVms) | Should -Contain 'archost01'
        @($status.rca.pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @(('{0}@archost01' -f $id))
    }

    It 'names the metrics'' final version in the stop''s status, so a re-check bundle written right after it changes nothing the notebook reads (review of 15ad76d)' {
        $running = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        Set-FixtureRunner -Batches @($script:fixtureIds[0], $script:fixtureIds[1])
        # The whole stop runs between the re-check's last look at the status and its bundle's write.
        $script:stopFired = $false
        $script:secretWriteHook = {
            param($Name, $Body)
            if (-not $script:stopFired -and $Name -eq 'dbhub-session-metrics' -and [string]$Body['tags']['rca'] -eq 'bundle') {
                $script:stopFired = $true
                $script:stopped = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext -NowUtc $script:clock)
            }
        }
        $check = Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }
        $check.Outcome | Should -Be 'Changed'
        $script:stopped.status | Should -Be 'Stopped'
        $versions = @($script:secrets['dbhub-session-metrics'])
        [string]$versions[-1].Tags['rca'] | Should -Be 'bundle' -Because 'the re-check''s write came right after the stop''s'
        $status = Get-SessionStatus
        $pinned = @($versions | Where-Object { $_.Version -eq $status.metrics.version })
        $pinned.Count | Should -Be 1
        $final = $pinned[0].Value | ConvertFrom-Json
        @($final.series).Count | Should -BeGreaterThan 0 -Because 'T4''s metrics are in the version the notebook reads'
        $final.rca.kind | Should -Be 'ContosoCare.RcaBundleIndex'
        @($final.rca.documents.documentId) | Should -Be @($script:fixtureIds[1])
        # That bundle is in no index, so its document goes to the next start, which exports it again.
        @($status.rca.pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @(('{0}@sqlvm01' -f $script:fixtureIds[0]))
    }

    It 'exports at the next session''s start what an earlier session''s stop didn''t, right before each VM''s activity, and keeps its index for Run all' {
        # The earlier session: the nightly stop ended it, after a re-check had exported part of it.
        $earlier = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T13:00:00Z'; steps = @(); rca = [ordered]@{ sessionId = $script:fixtureSession; bundles = @('0123456789abcdef0123456789abcdef'); documents = @(); pending = @(); leftVms = @(); final = $false; status = 'Pass'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $earlier -Depth 8 -Compress
        $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'deallocated' }
        $script:t4 = 'Stopped'
        $script:replica = ''
        $script:autostop = ''
        $script:groupTags = @{ DbHubT4Replica = 'Session' }
        $script:t4ReadyAt = $script:clock.AddMinutes(4)
        Set-FixtureRunner
        # Azure lists the export's Run Commands with their instance views (review of 93243d6: at 93243d6, the start's own
        # listing deleted the finished exports it had sent before it read them).
        $script:rcaListOpen = $true
        $next = 'fedcba9876543210fedcba9876543210'
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $next; requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        $exports = @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' })
        @($exports | ForEach-Object Vm | Sort-Object) | Should -Be @('archost01', 'sqlvm01')
        @($exports | ForEach-Object { $_.Request.sessionId } | Select-Object -Unique) | Should -Be @($script:fixtureSession)
        foreach ($vm in 'sqlvm01', 'archost01') {
            $export = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match ('/virtualMachines/{0}/runCommands/DbHubControl-rca-' -f $vm) }) | Select-Object -First 1))
            $dispatch = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match ('/virtualMachines/{0}/runCommands/DbHubControl-{0}-\d{{14}}$' -f $vm) }) | Select-Object -First 1))
            $export | Should -BeLessThan $dispatch -Because "$vm's export holds none of the new session's activity"
        }
        $status = Get-SessionStatus
        $status.sessionId | Should -Be $next
        $status.rcaEarlier.sessionId | Should -Be $script:fixtureSession
        @($status.rcaEarlier.bundles).Count | Should -Be 2 -Because 'the earlier session''s re-check bundle, and this start''s'
        @($status.rcaEarlier.documents.documentId) | Should -Be $script:fixtureIds
        Test-Json -Json (ConvertTo-Json -InputObject $status.rcaEarlier -Depth 6 -Compress) -SchemaFile $script:transportSchema | Should -BeTrue
        ($status.steps | Where-Object step -EQ 'RCA.EXPORT').message | Should -Match '^The evidence that session 5f1c0e7a''s stop didn''t export: 2 new evidence document'
        $status.rca.sessionId | Should -Be $next
        @($status.rca.bundles) | Should -BeNullOrEmpty -Because 'the new session''s own state starts empty'
        @($script:rcaCommands | Where-Object { $script:rcaDeleted -notcontains $_.Name }) | Should -BeNullOrEmpty
    }

    It 'fetches at the next start an earlier session''s pending document on a VM whose final export ran, not only on the VMs it left (review of 15ad76d)' {
        # Its stop's export didn't run on sqlvm01, and left one document on archost01 that it didn't fetch whole.
        $reference = @(($script:fixtureIndex | ConvertFrom-Json).documents | Where-Object documentId -EQ $script:fixtureIds[1])[0]
        $pending = [ordered]@{ documentId = $reference.documentId; parts = [int]$reference.parts; sha256 = $reference.sha256; vm = 'archost01' }
        $earlier = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'stopped'; updatedUtc = '2026-10-27T13:00:00Z'; rca = [ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); pending = @($pending); leftVms = @('sqlvm01'); final = $false; status = 'Warning'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $earlier -Depth 8 -Compress
        $script:vm = @{ sqlvm01 = 'deallocated'; archost01 = 'deallocated' }
        $script:t4 = 'Stopped'
        $script:replica = ''
        $script:autostop = ''
        $script:groupTags = @{ DbHubT4Replica = 'Session' }
        $script:t4ReadyAt = $script:clock.AddMinutes(4)
        # Neither VM has anything new to export; archost01 still has the document.
        $script:rcaRunner = {
            param($Command)
            $request = $Command.Request
            if ($request.command -eq 'export') {
                return (New-TestRcaView -Status 'Not selected' -Message 'runner rca export: nothing was captured since the last export.')
            }
            $line = @($script:fixtureParts | Where-Object { $_.Split(' ')[2] -eq $request.documentId -and $_.Split(' ')[3].StartsWith(('{0}/' -f $request.part)) }) | Select-Object -First 1
            return (New-TestRcaView -Status 'Pass' -Message 'runner rca part: its line follows.' -Line $line)
        }
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = 'fedcba9876543210fedcba9876543210'; requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        # sqlvm01 gets its final export; archost01 only has its document's parts fetched, which an export listed before
        # (review of 3b1348a: an export there would take the T2 host's one Run Command at a time for nothing).
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object Vm | Sort-Object) | Should -Be @('sqlvm01')
        @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'part' }).Count | Should -Be ([int]$reference.parts)
        $status = Get-SessionStatus
        @($status.rcaEarlier.documents.documentId) | Should -Be @($reference.documentId)
        @($status.rcaEarlier.bundles).Count | Should -Be 1
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending' -Because 'nothing of it is left on the VMs'
    }

    It 'carries an earlier session''s documents that a start doesn''t fetch in time, through the next stop, to the start after it, which fetches them (review of 3b1348a)' {
        # Session A's stop left a 2-part document on archost01, where Azure deletes Run Commands slowly (R871): B's start
        # fetches one part in its 6 minutes.
        $pending = New-TestPending -DocumentId $script:fixtureIds[1] -Vm 'archost01'
        $a = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'stopped'; updatedUtc = '2026-10-27T13:00:00Z'; rca = [ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); pending = @($pending); leftVms = @(); final = $false; finalRan = $true; status = 'Warning'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $a -Depth 8 -Compress
        Set-TestSessionStart
        Set-PartsRunner
        $script:rcaDeleteDelay['archost01'] = 40
        $b = 'b' * 32
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $b; requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' }) | Should -BeNullOrEmpty -Because 'A''s final export ran on both VMs'
        @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'part' }).Count | Should -Be 1
        $status = Get-SessionStatus
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlier' -Because 'no document was fetched whole'
        @($status.rcaEarlierPending).Count | Should -Be 1
        $status.rcaEarlierPending[0].sessionId | Should -Be $script:fixtureSession
        @($status.rcaEarlierPending[0].pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @(('{0}@archost01' -f $script:fixtureIds[1]))
        ([datetime]$status.rcaEarlierPending[0].expiresUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-11-03T13:00:00Z' -Because 'the runner keeps an exported document 7 days'
        @($status.steps | Where-Object step -EQ 'RCA.EARLIER' | ForEach-Object message) | Should -Be @('Session 5f1c0e7a''s evidence still on the VMs: 1 document(s) on archost01 that an export listed but didn''t fetch whole, which the next session''s start fetches, or the start after it when this session ends without its stop''s export, until 2026-11-03 13:00 UTC, when the runner deletes them.')
        ($status.steps | Where-Object step -EQ 'RCA.EXPORT').fix | Should -Be 'What''s still on the VMs stays there, and a later session''s start exports it, one earlier session''s per start; that start''s RCA.EARLIER lines say until when.'
        # B's stop keeps it.
        $script:rcaDeleteDelay.Clear()
        $stop = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $b }) -Context (New-TestContext -NowUtc $script:clock)
        $stop.status | Should -BeIn 'Stopped', 'Partial'
        $stopped = Get-SessionStatus
        $stopped.phase | Should -Be 'stopped'
        @($stopped.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($script:fixtureSession)
        # C's start fetches both parts, and Run all saves the document with A's history.
        $script:rcaCommands.Clear()
        Set-TestSessionStart
        $next = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $next.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'part' }).Count | Should -Be 2
        $status = Get-SessionStatus
        $status.rcaEarlier.sessionId | Should -Be $script:fixtureSession
        @($status.rcaEarlier.documents.documentId) | Should -Be @($script:fixtureIds[1])
        $bundles = @($script:secrets['dbhub-session-metrics'] | Where-Object { $_.Version -in @($status.rcaEarlier.bundles) } | ForEach-Object Value)
        @((Expand-TestBundle -Json $bundles).Keys) | Should -Be @($script:fixtureIds[1])
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending'
        ($status.steps | Where-Object step -EQ 'RCA.EXPORT').message | Should -Match 'Run all saves it with that session''s history at this session''s end\.$'
    }

    It 'says an earlier session''s capture that a VM couldn''t export at a start isn''t in any history any more, and never exports it under the wrong session later (reviews of 93243d6 and 02d398a)' {
        # The nightly stop ended session A after a re-check, so its final export never ran. At B's start archost01 already
        # has 24 managed Run Commands, so it can't take A's export, and B's T2 activity goes there anyway: the runner gives
        # what no export took to the first export that takes it, B's, which keeps only what B captured.
        $a = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T13:00:00Z'; steps = @(); rca = [ordered]@{ sessionId = $script:fixtureSession; bundles = @('0123456789abcdef0123456789abcdef'); documents = @(); pending = @(); leftVms = @(); final = $false; status = 'Pass'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $a -Depth 8 -Compress
        Set-TestSessionStart
        Set-FixtureRunner
        $script:runCommands['archost01'] = @(1..24 | ForEach-Object { @{ name = ('Other-{0:d2}' -f $_) } })
        $b = 'b' * 32
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $b; requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}' -f $_.Vm, $_.Request.sessionId }) | Should -Be @(('sqlvm01:{0}' -f $script:fixtureSession))
        $status = Get-SessionStatus
        @($status.rcaEarlier.documents.documentId) | Should -Be $script:fixtureIds -Because 'sqlvm01''s export went out'
        @($status.rcaEarlier.bundles).Count | Should -Be 2 -Because 'A''s re-check bundle, and this start''s'
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending' -Because 'no later export can tell A''s capture on archost01 from B''s'
        $apart = @($status.steps | Where-Object { $_.step -eq 'RCA.EARLIER' -and $_.state -eq 'Warning' })
        @($apart | ForEach-Object message) | Should -Be @('Session 5f1c0e7a''s capture on archost01 that no export took isn''t in any history now: session bbbbbbbb''s activity ran there before it was exported (no room for another managed Run Command there, or Azure refused its export), so the runner gave it to bbbbbbbb''s export, which keeps only what bbbbbbbb captured.')
        $apart[0].fix | Should -Match '^Nothing separates it now\.'
        # The nightly stop ends B too, so its own final export never runs. C's start exports B's capture on both VMs with
        # B's ID, before C's activity there, and never A's (at 93243d6, A's export on archost01 took B's capture there too).
        $script:runCommands.Remove('archost01')
        $script:rcaCommands.Clear()
        Set-TestSessionStart
        $next = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $next.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}:{2}' -f $_.Vm, $_.Request.sessionId, $_.Request.final } | Sort-Object) | Should -Be @(('archost01:{0}:True' -f $b), ('sqlvm01:{0}:True' -f $b))
        $status = Get-SessionStatus
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending'
        ($status.steps | Where-Object step -EQ 'RCA.EXPORT').message | Should -Match '^The evidence that session bbbbbbbb''s stop didn''t export: '
    }

    It 'records the VMs where a document carried the session''s own ID, and not one of no session (re-check of d2067d69)' {
        # The runner binds a span to the session of the first export that takes from it (Exporter.cs). A document of no
        # session comes from a span that an export with no session took first, so only the session's own ID says the rest
        # of that capture stays the session's. At d2067d69 nothing recorded it.
        $session = $script:fixtureSession
        $running = [ordered]@{ schemaVersion = 1; sessionId = $session; phase = 'running'; acceptedUtc = '2026-10-27T15:00:00Z'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $session) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        $script:clock = [datetime]::new(2026, 10, 27, 15, 30, 0, [System.DateTimeKind]::Utc)
        Set-ServedRunner -Case @(@{ Id = '20261027T151000Z-sqlvm01-0031'; Session = $null })
        $null = Update-DbHubSessionRca -Context (New-TestContext -NowUtc $script:clock) -Tags @{ DbHubSessionId = $session }
        $status = Get-SessionStatus
        @($status.rca.documents.documentId) | Should -Be @('20261027T151000Z-sqlvm01-0031')
        $status.rca.PSObject.Properties.Name | Should -Contain 'boundVms' -Because 'the state says where the runner bound the session''s capture'
        @($status.rca.boundVms) | Should -BeNullOrEmpty -Because 'a document of no session binds nothing to the session'
        $script:clock = $script:clock.AddMinutes(30)
        Set-ServedRunner -Case @(@{ Id = '20261027T152000Z-archost01-0032'; Session = $session }) -Vm @('archost01')
        $null = Update-DbHubSessionRca -Context (New-TestContext -NowUtc $script:clock) -Tags @{ DbHubSessionId = $session }
        $status = Get-SessionStatus
        @($status.rca.documents.documentId) | Should -Be @('20261027T151000Z-sqlvm01-0031', '20261027T152000Z-archost01-0032')
        @($status.rca.boundVms) | Should -Be @('archost01')
    }

    It 'says at a start that an earlier session''s capture its export there couldn''t take is still its own where a document of its own had bound it, and saves the rest with its history (re-check of d2067d69)' {
        # Session A's re-checks exported on archost01 (boundVms), but the nightly stop ended it before its stop's export. At
        # B's start, A's export there fails before the runner runs, as PowerShell Direct does into a guest that's still
        # starting, and B's T2 activity goes out. The runner keeps A's capture there bound to A, so B's next export there
        # lists the rest with A's ID. At d2067d69 the start said it wasn't in any history.
        $a = $script:fixtureSession
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $a; phase = 'running'; acceptedUtc = '2026-10-27T11:00:00Z'; runEndUtc = '2026-10-27T12:45:00Z'; updatedUtc = '2026-10-27T12:31:00Z'; dispatchUtc = [ordered]@{ T2 = '2026-10-27T11:06:00Z' }; steps = @(); rca = [ordered]@{ sessionId = $a; bundles = @('0123456789abcdef0123456789abcdef'); documents = @(); pending = @(); leftVms = @(); final = $false; status = 'Pass'; message = ''; boundVms = @('archost01') } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        Set-ServedRunner -Case @(@{ Id = '20261027T123500Z-archost01-0033'; Session = $a }) -Vm @('archost01')
        $script:servedRunner = $script:rcaRunner
        $script:guestDown = $true
        $script:rcaRunner = {
            param($Command)
            if ($script:guestDown -and $Command.Vm -eq 'archost01' -and $Command.Request.command -eq 'export') {
                return (New-TestRcaView -Status 'Fail' -Message 'runner rca export in contoso-sql: The virtual machine contoso-sql is not in running state.' -Evidence @{ host = 'ArcHost'; command = 'export'; guest = 'contoso-sql' })
            }
            return (& $script:servedRunner $Command)
        }
        $b = 'b' * 32
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $b; requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}' -f $_.Vm, $_.Request.sessionId }) | Should -Be @(('archost01:{0}' -f $a))
        $status = Get-SessionStatus
        @($status.steps | Where-Object step -EQ 'RCA.EARLIER' | ForEach-Object { '{0}|{1}' -f $_.state, $_.message }) | Should -Be @('Info|Session 5f1c0e7a''s capture on archost01 wasn''t exported before this session''s activity there (its export failed), but it''s still 5f1c0e7a''s: an export of 5f1c0e7a''s had already taken from it, so this session''s next export there lists the rest with 5f1c0e7a''s ID, and a later start saves it with 5f1c0e7a''s history.')
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending' -Because 'B''s own exports there aren''t held back'
        # B's first re-check lists the rest with A's ID, for A's entry.
        $script:guestDown = $false
        $script:clock = $script:clock.AddMinutes(30)
        $null = Update-DbHubSessionRca -Context (New-TestContext -NowUtc $script:clock) -Tags @{ DbHubSessionId = $b }
        $status = Get-SessionStatus
        @($status.rca.documents) | Should -BeNullOrEmpty
        @($status.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($a)
        @($status.rcaEarlierPending[0].pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @('20261027T123500Z-archost01-0033@archost01')
        # B's stop keeps it, and C's start saves it with A's history.
        $stop = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $b }) -Context (New-TestContext -NowUtc $script:clock)
        $stop.status | Should -BeIn 'Stopped', 'Partial'
        $script:rcaCommands.Clear()
        Set-TestSessionStart
        $next = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext -NowUtc $script:clock)
        $next.status | Should -BeIn 'Started', 'Partial'
        $status = Get-SessionStatus
        $status.rcaEarlier.sessionId | Should -Be $a
        @($status.rcaEarlier.documents.documentId) | Should -Be @('20261027T123500Z-archost01-0033')
        $bundles = @($script:secrets['dbhub-session-metrics'] | Where-Object { $_.Version -in @($status.rcaEarlier.bundles) } | ForEach-Object Value)
        (Expand-TestBundle -Json $bundles)['20261027T123500Z-archost01-0033'].sessionId | Should -Be $a
    }

    It 'says at a start whether an earlier session''s capture there is lost when its export there couldn''t take it: <Case> (re-check of d2067d69)' -ForEach @(
        @{ Case = 'a carried session that a document of its own had bound, and an export that failed before the runner ran'; Bound = $true; ExitCode = $null; State = 'Info'; Says = 'Session 5f1c0e7a''s capture on archost01 wasn''t exported before this session''s activity there (its export failed), but it''s still 5f1c0e7a''s: an export of 5f1c0e7a''s had already taken from it, so this session''s next export there lists the rest with 5f1c0e7a''s ID, and a later start saves it with 5f1c0e7a''s history.' }
        @{ Case = 'nothing of its own had bound it'; Bound = $false; ExitCode = $null; State = 'Warning'; Says = 'Session 5f1c0e7a''s capture on archost01 that no export took isn''t in any history now: session bbbbbbbb''s activity ran there before it was exported (its export failed), so the runner gave it to bbbbbbbb''s export, which keeps only what bbbbbbbb captured.' }
        @{ Case = 'its export ran the runner, and wasn''t read'; Bound = $true; ExitCode = 1; State = 'Warning'; Says = 'Session 5f1c0e7a''s capture on archost01 that no export took may not be in any history: this start''s export there may have listed what was left of it, but wasn''t read (its export failed), and the runner lists a document only once.' }
    ) {
        # Session A held archost01 when session E's start began, so E's status carries it, and E's stop exported everything
        # else. At B's start, A's export on archost01 fails, and B's T2 activity goes out.
        $a = $script:fixtureSession
        $carry = [ordered]@{ sessionId = $a; pending = @(); leftVms = @('archost01'); heldUntilUtc = '2026-11-20T11:00:00Z'; startUtc = '2026-10-27T11:00:00Z'; endUtc = '2026-10-27T12:45:00Z' }
        if ($Bound) {
            $carry['boundVms'] = @('archost01')
        }
        $e = 'e' * 32
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $e; phase = 'stopped'; acceptedUtc = '2026-10-27T13:00:00Z'; stoppedUtc = '2026-10-27T14:00:00Z'; updatedUtc = '2026-10-27T14:00:00Z'; dispatchUtc = [ordered]@{ T1 = '2026-10-27T13:05:00Z' }; metrics = [ordered]@{ status = 'Pass'; message = '' }; rca = [ordered]@{ sessionId = $e; bundles = @(); documents = @(); pending = @(); leftVms = @(); final = $true; finalRan = $true; status = 'Pass'; message = '' }; rcaEarlierPending = @($carry) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        $evidence = @{ host = 'ArcHost'; command = 'export'; guest = 'contoso-sql' }
        if ($null -ne $ExitCode) {
            $evidence['exitCode'] = $ExitCode
        }
        $script:failedExport = New-TestRcaView -Status 'Fail' -Message 'runner rca export in contoso-sql: it didn''t export.' -Evidence $evidence
        $script:rcaRunner = {
            param($Command)
            if ($Command.Vm -eq 'archost01' -and $Command.Request.command -eq 'export') {
                return $script:failedExport
            }
            return (New-TestRcaView -Status 'Not selected' -Message 'runner rca export: nothing was captured since the last export.')
        }
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('b' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}' -f $_.Vm, $_.Request.sessionId }) | Should -Be @(('archost01:{0}' -f $a))
        $line = @((Get-SessionStatus).steps | Where-Object { $_.step -eq 'RCA.EARLIER' -and $_.message -like 'Session 5f1c0e7a''s capture on archost01*' })
        $line.Count | Should -Be 1
        $line[0].state | Should -Be $State
        $line[0].message | Should -Be $Says
    }

    It 'exports each VM''s capture that no export took with the ID of the session that holds it, before the new session''s activity there, whichever session''s documents the start fetches (review of 93243d6)' {
        # Session B's stop exported on sqlvm01 but not on archost01, where its T2 activity ran, and it carried session A's
        # document on sqlvm01, which the runner deletes sooner. At 93243d6, A went first and B's capture got no export.
        $a = [ordered]@{ sessionId = $script:fixtureSession; pending = @(New-TestPending -DocumentId $script:fixtureIds[0] -Vm 'sqlvm01'); leftVms = @(); finalRan = $true; expiresUtc = '2026-10-30T13:00:00Z' }
        $b = 'b' * 32
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $b; phase = 'stopped'; acceptedUtc = '2026-10-27T11:00:00Z'; updatedUtc = '2026-10-27T13:00:00Z'; dispatchUtc = [ordered]@{ T1 = '2026-10-27T11:05:00Z'; T2 = '2026-10-27T11:06:00Z' }; metrics = [ordered]@{ status = 'Pass'; message = '' }; rca = [ordered]@{ sessionId = $b; bundles = @(); documents = @(); pending = @(); leftVms = @('archost01'); final = $false; finalRan = $true; status = 'Warning'; message = '' }; rcaEarlierPending = @($a) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        # archost01's runner has what its observer captured for B since B's last export there; Azure lists the export
        # Run Commands with their instance views, as it does.
        Set-ServedRunner -Case @(@{ Id = '20261027T123000Z-archost01-0007'; Session = $b }) -Vm @('archost01')
        $script:rcaListOpen = $true
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}:{2}' -f $_.Vm, $_.Request.sessionId, $_.Request.final }) | Should -Be @(('archost01:{0}:True' -f $b)) -Because 'B holds archost01''s capture, and A''s documents need no export'
        $export = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/virtualMachines/archost01/runCommands/DbHubControl-rca-' }) | Select-Object -First 1))
        $dispatch = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/virtualMachines/archost01/runCommands/DbHubControl-archost01-\d{14}$' }) | Select-Object -First 1))
        $export | Should -BeLessThan $dispatch -Because 'C''s activity on archost01 starts once B''s capture there is exported'
        $status = Get-SessionStatus
        $status.rcaEarlier.sessionId | Should -Be $script:fixtureSession -Because 'one session''s documents per start: A''s, which the runner deletes first'
        @($status.rcaEarlier.documents.documentId) | Should -Be @($script:fixtureIds[0])
        @($status.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($b)
        @($status.rcaEarlierPending[0].pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @('20261027T123000Z-archost01-0007@archost01')
        @($status.rcaEarlierPending[0].leftVms) | Should -BeNullOrEmpty -Because 'its export ran, so the runner gave that capture to B'
        $until = ([datetime]$status.rcaEarlierPending[0].expiresUtc).ToUniversalTime()
        $until | Should -BeGreaterOrEqual ([datetime]::new(2026, 11, 3, 15, 0, 0, [System.DateTimeKind]::Utc))
        $until | Should -BeLessOrEqual ([datetime]::new(2026, 11, 3, 16, 0, 0, [System.DateTimeKind]::Utc)) -Because 'the runner deletes an exported document 7 days after its export'
        $earlier = @($status.steps | Where-Object step -EQ 'RCA.EARLIER')
        @($earlier | ForEach-Object state) | Should -Be @('Info', 'Info')
        $earlier[0].message | Should -Be 'Session bbbbbbbb''s capture on archost01 that no export had taken was exported with its own ID before this session''s activity there: 1 document(s).'
        $earlier[1].message | Should -Match '^Session bbbbbbbb''s evidence still on the VMs: 1 document\(s\) on archost01 that an export listed but didn''t fetch whole, which the next session''s start fetches, or the start after it when this session ends without its stop''s export, until 2026-11-03 1\d:\d\d UTC, when the runner deletes them\.$'
        # D's start fetches B's document, and Run all saves it with B's history.
        $script:rcaCommands.Clear()
        Set-TestSessionStart
        $later = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('d' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $later.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { $_.Request.sessionId } | Select-Object -Unique) | Should -Be @(('c' * 32)) -Because 'C''s own capture on the VMs goes with C''s ID'
        $status = Get-SessionStatus
        $status.rcaEarlier.sessionId | Should -Be $b
        @($status.rcaEarlier.documents.documentId) | Should -Be @('20261027T123000Z-archost01-0007')
        $bundles = @($script:secrets['dbhub-session-metrics'] | Where-Object { $_.Version -in @($status.rcaEarlier.bundles) } | ForEach-Object Value)
        (Expand-TestBundle -Json $bundles)['20261027T123000Z-archost01-0007'].sessionId | Should -Be $b
    }

    It 'says which earlier session''s capture on a VM isn''t in any history when two sessions hold it, and exports it with the later one''s ID (reviews of 93243d6 and 02d398a)' {
        # Session A still held archost01's capture when B's T2 activity ran there, and B's stop didn't export there either:
        # whichever export comes first takes both, so it goes with B's, which keeps only what B captured. At 93243d6, A's
        # export took it.
        $a = [ordered]@{ sessionId = $script:fixtureSession; pending = @(); leftVms = @('archost01'); heldUntilUtc = '2026-11-20T13:00:00Z' }
        $b = 'b' * 32
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $b; phase = 'stopped'; acceptedUtc = '2026-10-27T11:00:00Z'; updatedUtc = '2026-10-27T13:00:00Z'; dispatchUtc = [ordered]@{ T2 = '2026-10-27T11:06:00Z' }; metrics = [ordered]@{ status = 'Pass'; message = '' }; rca = [ordered]@{ sessionId = $b; bundles = @(); documents = @(); pending = @(); leftVms = @('archost01'); final = $false; finalRan = $true; status = 'Warning'; message = '' }; rcaEarlierPending = @($a) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}' -f $_.Vm, $_.Request.sessionId }) | Should -Be @(('archost01:{0}' -f $b))
        $status = Get-SessionStatus
        $apart = @($status.steps | Where-Object { $_.step -eq 'RCA.EARLIER' -and $_.state -eq 'Warning' })
        @($apart | ForEach-Object message) | Should -Be @('Session 5f1c0e7a''s capture on archost01 that no export took isn''t in any history now: session bbbbbbbb''s activity ran there before it was exported, so the runner gave it to bbbbbbbb''s export, which keeps only what bbbbbbbb captured.')
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending'
    }

    It 'leaves a VM that an earlier session holds out of the session''s re-checks and its stop, so that capture isn''t taken under this session (review of 93243d6)' {
        $a = 'a' * 32
        $held = [ordered]@{ sessionId = $a; pending = @(); leftVms = @('archost01'); heldUntilUtc = '2026-11-20T13:00:00Z' }
        $running = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession); rcaEarlierPending = @($held) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        Set-FixtureRunner -Batches @($script:fixtureIds[0], $script:fixtureIds[1])
        (Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }).Outcome | Should -Be 'Exported'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object Vm) | Should -Be @('sqlvm01')
        $status = Get-SessionStatus
        @($status.rcaEarlierPending | ForEach-Object { '{0}:{1}' -f $_.sessionId, (@($_.leftVms) -join ',') }) | Should -Be @(('{0}:archost01' -f $a))
        # The stop exports on sqlvm01 only too, and A still holds archost01 for the next start.
        $stop = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext -NowUtc $script:clock)
        $stop.status | Should -BeIn 'Stopped', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object Vm) | Should -Be @('sqlvm01', 'sqlvm01')
        $stopped = Get-SessionStatus
        $stopped.rca.status | Should -Be 'Pass' -Because 'a VM an earlier session holds is no problem of this session''s export'
        @($stopped.rca.documents.documentId) | Should -Be $script:fixtureIds
        @($stopped.rca.leftVms) | Should -Be @('archost01') -Because 'had this session''s activity gone there, the next start would export it with this session''s ID'
        @($stopped.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($a)
    }

    It 'hands another session''s documents that a re-check or the stop finds to that session''s entry, for a later start (review of 93243d6)' {
        # The runner keeps a span bound to the session of the first export that took from it, so what's left of session A's
        # comes with this session's exports, under A's ID. At 93243d6 they were skipped, and lost.
        $a = 'a' * 32
        $running = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        Set-ServedRunner -Case @(@{ Id = '20261027T150500Z-sqlvm01-0005'; Session = $a })
        $null = Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }
        $status = Get-SessionStatus
        @($status.rca.documents) | Should -BeNullOrEmpty
        @($status.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($a)
        @($status.rcaEarlierPending[0].pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @('20261027T150500Z-sqlvm01-0005@sqlvm01')
        ([datetime]$status.rcaEarlierPending[0].expiresUtc).ToUniversalTime() | Should -BeGreaterOrEqual ([datetime]::new(2026, 11, 3, 15, 0, 0, [System.DateTimeKind]::Utc))
        # The stop finds another, and its status keeps both for the next start.
        Set-ServedRunner -Case @(@{ Id = '20261027T153000Z-sqlvm01-0006'; Session = $a })
        $stop = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext -NowUtc $script:clock)
        $stop.status | Should -BeIn 'Stopped', 'Partial'
        $stopped = Get-SessionStatus
        @($stopped.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($a)
        @($stopped.rcaEarlierPending[0].pending | ForEach-Object documentId) | Should -Be @('20261027T150500Z-sqlvm01-0005', '20261027T153000Z-sqlvm01-0006')
        ($stopped.rcaLines | Where-Object step -EQ 'RCA.EXPORT').message | Should -Match '1 document\(s\) of another session go with that session''s evidence \(RCA\.EARLIER\)\.$'
    }

    It 'reads the export a start sent before its VM stopped again, when nothing could be dispatched, and keeps what it listed for the next start (review of 93243d6)' {
        # Session B's stop didn't finish its export on sqlvm01, where its activity went.
        $b = 'b' * 32
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $b; phase = 'stopped'; acceptedUtc = '2026-10-27T11:00:00Z'; updatedUtc = '2026-10-27T13:00:00Z'; dispatchUtc = [ordered]@{ T1 = '2026-10-27T11:05:00Z' }; metrics = [ordered]@{ status = 'Pass'; message = '' }; rca = [ordered]@{ sessionId = $b; bundles = @(); documents = @(); pending = @(); leftVms = @('sqlvm01'); final = $false; finalRan = $true; status = 'Warning'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        Set-ServedRunner -Case @(@{ Id = '20261027T125500Z-sqlvm01-0003'; Session = $b })
        # No dispatch is accepted, so the run deallocates the VMs it started (#27) before the start reads B's export.
        $accepted = $script:runCommandStatus
        $script:runCommandStatus = 409
        $failed = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $failed.status | Should -Be 'Failed'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}' -f $_.Vm, $_.Request.sessionId }) | Should -Be @(('sqlvm01:{0}' -f $b))
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' }) | Should -BeNullOrEmpty -Because 'sqlvm01 stopped before its parts could be fetched'
        $status = Get-SessionStatus
        $status.phase | Should -Be 'failed'
        @($status.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($b)
        @($status.rcaEarlierPending[0].pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @('20261027T125500Z-sqlvm01-0003@sqlvm01') -Because 'the runner lists a document only once'
        @($status.rcaEarlierPending[0].leftVms) | Should -BeNullOrEmpty -Because 'its export ran, so the runner gave that capture to B'
        @($script:rcaCommands | Where-Object { $script:rcaDeleted -notcontains $_.Name }) | Should -BeNullOrEmpty
        # The next start fetches it.
        $script:runCommandStatus = $accepted
        $script:rcaCommands.Clear()
        Set-TestSessionStart
        $next = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('d' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $next.status | Should -BeIn 'Started', 'Partial'
        $status = Get-SessionStatus
        $status.rcaEarlier.sessionId | Should -Be $b
        @($status.rcaEarlier.documents.documentId) | Should -Be @('20261027T125500Z-sqlvm01-0003')
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending'
    }

    It 'keeps another job''s export Run Command until its name is an hour old, finished or not, so that job can still read it (review of 93243d6)' {
        # A start's export sent before the VM's activity, and finished: at 93243d6 the next listing deleted it unread.
        $script:runCommands['sqlvm01'] = @(
            @{ name = 'DbHubControl-rca-sqlvm01-x-20261027145500'; properties = @{ instanceView = @{ executionState = 'Succeeded' } } }
            @{ name = 'DbHubControl-rca-sqlvm01-0101-20261027135500'; properties = @{ instanceView = @{ executionState = 'Running' } } }
            @{ name = 'DbHubControl-sqlvm01-20261027140000'; properties = @{ instanceView = @{ executionState = 'Succeeded' } } }
        )
        Get-DbHubRcaRoom -Context (New-TestContext) -VmName 'sqlvm01' | Should -Be 23
        @($script:calls | Where-Object { $_.Method -eq 'DELETE' } | ForEach-Object { ($_.Path -split '/')[-1] }) | Should -Be @('DbHubControl-rca-sqlvm01-0101-20261027135500')
        # A session's end clears this control's other finished Run Commands too, as before.
        $script:calls.Clear()
        Get-DbHubRcaRoom -Context (New-TestContext) -VmName 'sqlvm01' -ClearFinished | Should -Be 24
        @($script:calls | Where-Object { $_.Method -eq 'DELETE' } | ForEach-Object { ($_.Path -split '/')[-1] }) | Should -Be @('DbHubControl-rca-sqlvm01-0101-20261027135500', 'DbHubControl-sqlvm01-20261027140000')
    }

    It 'counts an earlier session''s documents that a start''s export listed 7 days from that export, even for an entry whose capture waited 30 days (review of 93243d6)' {
        # A carry from 93243d6: session A's final export never ran on sqlvm01, so it was asked for 30 days.
        $a = [ordered]@{ sessionId = $script:fixtureSession; pending = @(); leftVms = @('sqlvm01'); finalRan = $false; expiresUtc = '2026-11-25T13:00:00Z' }
        $previous = [ordered]@{ schemaVersion = 1; sessionId = ('f' * 32); phase = 'refused'; updatedUtc = '2026-10-27T13:00:00Z'; rcaEarlierPending = @($a) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        Set-FixtureRunner -Batches @($script:fixtureIds[1])
        $script:partFixture = $script:rcaRunner
        # The document's second part fails, so it isn't fetched whole.
        $script:rcaRunner = {
            param($Command)
            if ($Command.Request.command -eq 'part' -and $Command.Request.part -eq 2) {
                return (New-TestRcaView -Status 'Fail' -Message 'runner rca part: exit code 3.')
            }
            return (& $script:partFixture $Command)
        }
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}' -f $_.Vm, $_.Request.sessionId }) | Should -Be @(('sqlvm01:{0}' -f $script:fixtureSession))
        $status = Get-SessionStatus
        @($status.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($script:fixtureSession)
        @($status.rcaEarlierPending[0].pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @(('{0}@sqlvm01' -f $script:fixtureIds[1]))
        @($status.rcaEarlierPending[0].leftVms) | Should -BeNullOrEmpty
        $until = ([datetime]$status.rcaEarlierPending[0].expiresUtc).ToUniversalTime()
        $until | Should -BeGreaterOrEqual ([datetime]::new(2026, 11, 3, 15, 0, 0, [System.DateTimeKind]::Utc))
        $until | Should -BeLessOrEqual ([datetime]::new(2026, 11, 3, 16, 0, 0, [System.DateTimeKind]::Utc)) -Because 'the runner deletes an exported document 7 days after its export, not 30'
    }

    It 'keeps the earlier sessions'' evidence through a start that''s refused, for the start after it (review of 3b1348a)' {
        $pending = New-TestPending -DocumentId $script:fixtureIds[0] -Vm 'sqlvm01'
        $a = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'stopped'; updatedUtc = '2026-10-27T13:00:00Z'; rca = [ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); pending = @($pending); leftVms = @(); final = $false; finalRan = $true; status = 'Warning'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $a -Depth 8 -Compress
        Set-TestSessionStart
        Set-PartsRunner
        # Too close to the VMs' auto-shutdown (19:00 Eastern, 23:00 UTC that day): refused.
        $script:clock = [datetime]::new(2026, 10, 27, 22, 45, 0, [System.DateTimeKind]::Utc)
        $refused = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('b' * 32); requestedBy = 'presenter' }) -Context (New-TestContext -NowUtc $script:clock)
        $refused.status | Should -Be 'Refused'
        $status = Get-SessionStatus
        $status.phase | Should -Be 'refused'
        @($status.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($script:fixtureSession)
        @($script:rcaCommands) | Should -BeNullOrEmpty
        # The next day's start fetches A's document; the refused session had no activity, so it has nothing to export.
        $script:clock = [datetime]::new(2026, 10, 28, 15, 0, 0, [System.DateTimeKind]::Utc)
        Set-TestSessionStart
        $next = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext -NowUtc $script:clock)
        $next.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' }) | Should -BeNullOrEmpty
        $status = Get-SessionStatus
        $status.rcaEarlier.sessionId | Should -Be $script:fixtureSession
        @($status.rcaEarlier.documents.documentId) | Should -Be @($script:fixtureIds[0])
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending'
    }

    It 'doesn''t take into a session what the observer captured between the session before it and its start (a run, start-demo.ps1), and doesn''t fetch it (review of 02d398a)' {
        # The session before this one ended at 13:00, and a run outside a Run all session went to sqlvm01 at 14:00; that
        # span had no export, so this session's first re-check takes it under this session's ID. At 02d398a it was saved.
        $session = $script:fixtureSession
        $running = [ordered]@{ schemaVersion = 1; sessionId = $session; phase = 'running'; acceptedUtc = '2026-10-27T15:00:00Z'; rcaPreviousEndUtc = '2026-10-27T13:00:00Z'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $session) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        $script:clock = [datetime]::new(2026, 10, 27, 15, 30, 0, [System.DateTimeKind]::Utc)
        Set-ServedRunner -Case @(@{ Id = '20261027T140000Z-sqlvm01-0001'; Session = $session }, @{ Id = '20261027T151000Z-sqlvm01-0002'; Session = $session })
        (Update-DbHubSessionRca -Context (New-TestContext -NowUtc $script:clock) -Tags @{ DbHubSessionId = $session }).Outcome | Should -Be 'Exported'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' } | ForEach-Object { $_.Request.documentId } | Select-Object -Unique) | Should -Be @('20261027T151000Z-sqlvm01-0002') -Because 'the run''s document isn''t fetched'
        $status = Get-SessionStatus
        @($status.rca.documents.documentId) | Should -Be @('20261027T151000Z-sqlvm01-0002')
        @((Expand-TestBundle -Json @(Get-RcaBundle | ForEach-Object Value)).Keys) | Should -Be @('20261027T151000Z-sqlvm01-0002')
        $export = @($status.steps | Where-Object step -EQ 'RCA.EXPORT')
        $export[0].state | Should -Be 'Pass' -Because 'capture from outside a Run all session isn''t this session''s problem'
        $export[0].message | Should -Match '1 document\(s\) from before the session began or after it ended weren''t saved: no session''s history takes them\.$'
    }

    It 'keeps at the stop what the session before it captured last, and leaves out what ran between the sessions (review of 02d398a)' {
        # Session X (eeeeeeee) ended at 13:00; its stop's export ran while its activity still did, so its last capture comes
        # with this session's export under X's ID. Between 13:00 and 15:00 activity outside a Run all session ran: one span
        # bound to no session (a script's history save), and one this session's export took. At 02d398a both were saved here.
        $session = $script:fixtureSession
        $x = 'e' * 32
        $running = [ordered]@{ schemaVersion = 1; sessionId = $session; phase = 'running'; acceptedUtc = '2026-10-27T15:00:00Z'; rcaPreviousEndUtc = '2026-10-27T13:00:00Z'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $session) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        $script:clock = [datetime]::new(2026, 10, 27, 15, 40, 0, [System.DateTimeKind]::Utc)
        Set-ServedRunner -Case @(
            @{ Id = '20261027T125800Z-sqlvm01-0003'; Session = $x }
            @{ Id = '20261027T143000Z-sqlvm01-0004'; Session = $null }
            @{ Id = '20261027T152000Z-sqlvm01-0005'; Session = $session }
            @{ Id = '20261027T124000Z-sqlvm01-0006'; Session = $session }
        )
        $stopAt = $script:clock
        $stop = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $session }) -Context (New-TestContext -NowUtc $script:clock)
        $stop.status | Should -BeIn 'Stopped', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' } | ForEach-Object { $_.Request.documentId } | Select-Object -Unique | Sort-Object) | Should -Be @('20261027T124000Z-sqlvm01-0006', '20261027T125800Z-sqlvm01-0003', '20261027T152000Z-sqlvm01-0005') -Because 'what lies between the sessions isn''t fetched; what may be the session before''s is'
        $stopped = Get-SessionStatus
        ([datetime]$stopped.stoppedUtc).ToUniversalTime() | Should -BeGreaterOrEqual $stopAt -Because 'the stop says when it ended'
        $stopped.rca.status | Should -Be 'Pass'
        @($stopped.rca.documents.documentId) | Should -Be @('20261027T152000Z-sqlvm01-0005')
        @($stopped.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($x)
        @($stopped.rcaEarlierPending[0].pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @('20261027T125800Z-sqlvm01-0003@sqlvm01')
        ([datetime]$stopped.rcaEarlierPending[0].endUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-10-27T15:00:00Z' -Because 'X ended before this session began'
        ($stopped.rcaLines | Where-Object step -EQ 'RCA.EXPORT').message | Should -Match '2 document\(s\) from before the session began or after it ended weren''t saved'
    }

    It 'takes from an earlier session''s export at a start only what that session captured while its activity ran (review of 02d398a)' {
        # Session B (activity 11:00 to 12:45, stopped at 13:00) holds archost01, where a run ran at 14:00 and something
        # captured at 10:00 that no export took either: the holder's export at this start takes all three under B's ID.
        # At 02d398a all three went into B's history.
        $b = 'b' * 32
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $b; phase = 'stopped'; acceptedUtc = '2026-10-27T11:00:00Z'; runEndUtc = '2026-10-27T12:45:00Z'; stoppedUtc = '2026-10-27T13:00:00Z'; updatedUtc = '2026-10-27T13:00:00Z'; dispatchUtc = [ordered]@{ T2 = '2026-10-27T11:06:00Z' }; metrics = [ordered]@{ status = 'Pass'; message = '' }; rca = [ordered]@{ sessionId = $b; bundles = @(); documents = @(); pending = @(); leftVms = @('archost01'); final = $false; finalRan = $true; status = 'Warning'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        Set-ServedRunner -Case @(
            @{ Id = '20261027T123000Z-archost01-0007'; Session = $b }
            @{ Id = '20261027T140000Z-archost01-0008'; Session = $b }
            @{ Id = '20261027T100000Z-archost01-0009'; Session = $b }
        ) -Vm @('archost01')
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}' -f $_.Vm, $_.Request.sessionId }) | Should -Be @(('archost01:{0}' -f $b))
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' } | ForEach-Object { $_.Request.documentId } | Select-Object -Unique) | Should -Be @('20261027T123000Z-archost01-0007')
        $status = Get-SessionStatus
        ([datetime]$status.rcaPreviousEndUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-10-27T12:45:00Z' -Because 'B''s activity ended at its planned end, before its stop'
        $status.rcaEarlier.sessionId | Should -Be $b
        @($status.rcaEarlier.documents.documentId) | Should -Be @('20261027T123000Z-archost01-0007')
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending'
        ($status.steps | Where-Object step -EQ 'RCA.EXPORT').message | Should -Match '2 document\(s\) from before the session began or after it ended weren''t saved'
    }

    It 'exports with no session at a start, on a VM that ran before it, before that VM''s activity, and gives an earlier session that holds the VM only what it captured while its activity ran (review of 02d398a)' {
        # deploy.ps1 or start-demo.ps1 left the VMs running with an activity profile, after session E's stop, which didn't
        # export on sqlvm01: E's capture there (12:30, which no re-check had bound to E) and the activity outside a Run all
        # session (14:30) are both on it. At 02d398a this start sent E's export to sqlvm01 and nothing to archost01, so the
        # capture from outside a Run all session went into E's history, and into this session's on archost01.
        $e = 'e' * 32
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $e; phase = 'stopped'; acceptedUtc = '2026-10-27T11:00:00Z'; stoppedUtc = '2026-10-27T13:00:00Z'; updatedUtc = '2026-10-27T13:00:00Z'; dispatchUtc = [ordered]@{ T1 = '2026-10-27T11:05:00Z' }; metrics = [ordered]@{ status = 'Pass'; message = '' }; rca = [ordered]@{ sessionId = $e; bundles = @(); documents = @(); pending = @(); leftVms = @('sqlvm01'); final = $false; finalRan = $true; status = 'Warning'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        Set-ServedRunner -Case @(@{ Id = '20261027T123000Z-sqlvm01-0012'; Session = $null }, @{ Id = '20261027T143000Z-sqlvm01-0010'; Session = $null })
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        $exports = @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' })
        @($exports | ForEach-Object { '{0}:{1}:{2}' -f $_.Vm, [string]$_.Request.sessionId, $_.Request.final } | Sort-Object) | Should -Be @('archost01::False', 'sqlvm01::False')
        foreach ($vm in 'sqlvm01', 'archost01') {
            $export = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match ('/virtualMachines/{0}/runCommands/DbHubControl-rca-' -f $vm) }) | Select-Object -First 1))
            $dispatch = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match ('/virtualMachines/{0}/runCommands/DbHubControl-{0}-\d{{14}}$' -f $vm) }) | Select-Object -First 1))
            $export | Should -BeLessThan $dispatch -Because "$vm's export takes only what ran there before this session"
        }
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' } | ForEach-Object { $_.Request.documentId } | Select-Object -Unique) | Should -Be @('20261027T123000Z-sqlvm01-0012') -Because 'only what falls within E''s activity is fetched'
        @($script:rcaCommands | Where-Object { $script:rcaDeleted -notcontains $_.Name }) | Should -BeNullOrEmpty
        $status = Get-SessionStatus
        $status.rcaEarlier.sessionId | Should -Be $e
        @($status.rcaEarlier.documents.documentId) | Should -Be @('20261027T123000Z-sqlvm01-0012')
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending'
        ([datetime]$status.rcaPreviousEndUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-10-27T13:00:00Z'
        $lines = @($status.steps | Where-Object { $_.step -eq 'RCA.EXPORT' })
        @($lines | ForEach-Object state) | Should -Be @('Info', 'Info')
        $lines[0].message | Should -Match '^The evidence that session eeeeeeee''s stop didn''t export: 1 new evidence document'
        $lines[1].message | Should -Be 'sqlvm01 ran before this session''s start, so an export with no session took what the observer captured there outside a Run all session: 1 document(s), which no history takes.'
        @($status.steps | Where-Object { $_.step -eq 'RCA.EARLIER' -and $_.state -eq 'Warning' }) | Should -BeNullOrEmpty -Because 'when E''s capture was taken tells it apart'
    }

    It 'keeps the last capture of a session whose run ended minutes before this start and whose VMs still run, with that session (review of 02d398a)' {
        # Run all again within autoStopBufferMinutes of session D's run end: D's auto-stop hadn't run, so its VMs still ran
        # and its stop's export never did, and this start's exports there have no session. At 5585fd1 they took D's capture
        # since its last re-check into no history, with a Warning that blamed activity outside a Run all session.
        $d = 'd' * 32
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $d; phase = 'running'; acceptedUtc = '2026-10-27T14:00:00Z'; runEndUtc = '2026-10-27T14:50:00Z'; updatedUtc = '2026-10-27T14:31:00Z'; dispatchUtc = [ordered]@{ T1 = '2026-10-27T14:05:00Z'; T2 = '2026-10-27T14:06:00Z' }; steps = @(); rca = [ordered]@{ sessionId = $d; bundles = @('0123456789abcdef0123456789abcdef'); documents = @(); pending = @(); leftVms = @(); final = $false; status = 'Pass'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        Set-ServedRunner -Case @(@{ Id = '20261027T143000Z-sqlvm01-0014'; Session = $d })
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}' -f $_.Vm, [string]$_.Request.sessionId } | Sort-Object) | Should -Be @('archost01:', 'sqlvm01:') -Because 'both VMs ran before this start'
        $status = Get-SessionStatus
        ([datetime]$status.rcaPreviousEndUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-10-27T14:50:00Z'
        $status.rcaEarlier.sessionId | Should -Be $d
        @($status.rcaEarlier.documents.documentId) | Should -Be @('20261027T143000Z-sqlvm01-0014')
        @($status.rcaEarlier.bundles).Count | Should -Be 2 -Because 'D''s re-check bundle, and this start''s'
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending'
        @($status.steps | Where-Object { $_.step -like 'RCA.*' -and $_.state -eq 'Warning' }) | Should -BeNullOrEmpty
        @($status.steps | Where-Object step -EQ 'RCA.EXPORT' | ForEach-Object message) | Should -Not -Match 'ran before this session''s start'
    }

    It 'hands an earlier session what an export with no session found from within its activity, for a later start, when the start fetches another session (review of 02d398a)' {
        # The VMs ran before this start (start-demo.ps1). B holds archost01, where its capture (12:30) and activity outside a
        # Run all session (14:30) wait; A's document on sqlvm01 goes first, because the runner deletes it sooner.
        $a = [ordered]@{ sessionId = $script:fixtureSession; pending = @(New-TestPending -DocumentId $script:fixtureIds[0] -Vm 'sqlvm01'); leftVms = @(); finalRan = $true; expiresUtc = '2026-10-30T13:00:00Z' }
        $b = 'b' * 32
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $b; phase = 'stopped'; acceptedUtc = '2026-10-27T11:00:00Z'; stoppedUtc = '2026-10-27T13:00:00Z'; updatedUtc = '2026-10-27T13:00:00Z'; dispatchUtc = [ordered]@{ T2 = '2026-10-27T11:06:00Z' }; metrics = [ordered]@{ status = 'Pass'; message = '' }; rca = [ordered]@{ sessionId = $b; bundles = @(); documents = @(); pending = @(); leftVms = @('archost01'); final = $false; finalRan = $true; status = 'Warning'; message = '' }; rcaEarlierPending = @($a) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        Set-ServedRunner -Case @(@{ Id = '20261027T123000Z-archost01-0007'; Session = $null }, @{ Id = '20261027T143000Z-archost01-0018'; Session = $null }) -Vm @('archost01')
        $script:rcaListOpen = $true
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | ForEach-Object { '{0}:{1}' -f $_.Vm, [string]$_.Request.sessionId } | Sort-Object) | Should -Be @('archost01:', 'sqlvm01:')
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' } | ForEach-Object { $_.Request.documentId } | Select-Object -Unique) | Should -Be @($script:fixtureIds[0]) -Because 'B''s document waits for B''s turn'
        $status = Get-SessionStatus
        $status.rcaEarlier.sessionId | Should -Be $script:fixtureSession
        @($status.rcaEarlierPending | ForEach-Object sessionId) | Should -Be @($b)
        @($status.rcaEarlierPending[0].pending | ForEach-Object { '{0}@{1}' -f $_.documentId, $_.vm }) | Should -Be @('20261027T123000Z-archost01-0007@archost01')
        @($status.rcaEarlierPending[0].leftVms) | Should -BeNullOrEmpty -Because 'the export with no session took that capture, and its documents from within B''s activity are B''s'
        $earlier = @($status.steps | Where-Object step -EQ 'RCA.EARLIER')
        @($earlier | ForEach-Object state) | Should -Be @('Info', 'Info')
        $earlier[0].message | Should -Be 'Session bbbbbbbb''s capture on archost01 that no export had taken was exported before this session''s activity there, with no session because the VM ran before this start; the documents from within its activity are its: 1 document(s).'
        @($status.steps | Where-Object step -EQ 'RCA.EXPORT' | ForEach-Object message) | Should -Contain 'archost01 ran before this session''s start, so an export with no session took what the observer captured there outside a Run all session: 1 document(s), which no history takes.'
        @($status.steps | Where-Object { $_.step -like 'RCA.*' -and $_.state -eq 'Warning' }) | Should -BeNullOrEmpty
    }

    It 'says an earlier session''s capture on a VM that ran before the start is lost when its status doesn''t say when its activity ended (review of 02d398a)' {
        # E's stop status names no end (a runbook from before stoppedUtc, with no plan kept), so nothing tells E's capture on
        # sqlvm01 from the activity outside a Run all session that ran there since.
        $e = 'e' * 32
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $e; phase = 'stopped'; acceptedUtc = '2026-10-27T11:00:00Z'; updatedUtc = '2026-10-27T13:00:00Z'; dispatchUtc = [ordered]@{ T1 = '2026-10-27T11:05:00Z' }; metrics = [ordered]@{ status = 'Pass'; message = '' }; rca = [ordered]@{ sessionId = $e; bundles = @(); documents = @(); pending = @(); leftVms = @('sqlvm01'); final = $false; finalRan = $true; status = 'Warning'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        $script:vm = @{ sqlvm01 = 'running'; archost01 = 'running' }
        Set-ServedRunner -Case @(@{ Id = '20261027T123000Z-sqlvm01-0012'; Session = $null }, @{ Id = '20261027T143000Z-sqlvm01-0010'; Session = $null })
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.command -eq 'part' }) | Should -BeNullOrEmpty
        $status = Get-SessionStatus
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlier'
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending'
        @($status.steps | Where-Object { $_.step -eq 'RCA.EXPORT' } | ForEach-Object { '{0}|{1}' -f $_.state, $_.message }) | Should -Be @('Info|sqlvm01 ran before this session''s start, so an export with no session took what the observer captured there outside a Run all session: 2 document(s), which no history takes.')
        $apart = @($status.steps | Where-Object { $_.step -eq 'RCA.EARLIER' -and $_.state -eq 'Warning' })
        @($apart | ForEach-Object message) | Should -Be @('Session eeeeeeee''s capture on sqlvm01 that no export took isn''t in any history now: sqlvm01 was running before this session''s start, and session eeeeeeee''s status doesn''t say when its activity ended, so the export with no session that this start sent there couldn''t tell that capture from any activity outside a Run all session.')
        $apart[0].fix | Should -Match 'stop the demo \(\./scripts/stop-demo\.ps1\) before Run all'
    }

    It 'waits for the export a start sends to a VM to end before that VM''s activity goes out (review of 02d398a)' {
        # Managed Run Commands run in parallel on a VM: at 02d398a the activity went out right after the export, so an export
        # that ran a little later took the new session's first capture under the earlier session's ID.
        $b = 'b' * 32
        $previous = [ordered]@{ schemaVersion = 1; sessionId = $b; phase = 'stopped'; acceptedUtc = '2026-10-27T11:00:00Z'; updatedUtc = '2026-10-27T13:00:00Z'; dispatchUtc = [ordered]@{ T2 = '2026-10-27T11:06:00Z' }; metrics = [ordered]@{ status = 'Pass'; message = '' }; rca = [ordered]@{ sessionId = $b; bundles = @(); documents = @(); pending = @(); leftVms = @('archost01'); final = $false; finalRan = $true; status = 'Warning'; message = '' } }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
        Set-TestSessionStart
        Set-ServedRunner -Case @(@{ Id = '20261027T123000Z-archost01-0007'; Session = $b }) -Vm @('archost01')
        $script:servedRunner = $script:rcaRunner
        $script:exportReads = @{}
        # The export runs for two reads before it ends.
        $script:rcaRunner = {
            param($Command)
            if ($Command.Request.command -eq 'export') {
                $script:exportReads[$Command.Name] = 1 + [int]$script:exportReads[$Command.Name]
                if ($script:exportReads[$Command.Name] -le 2) {
                    return $null
                }
            }
            return (& $script:servedRunner $Command)
        }
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        $name = @($script:rcaCommands | Where-Object { $_.Vm -eq 'archost01' -and $_.Request.command -eq 'export' })[0].Name
        $reads = @($script:calls | Where-Object { $_.Method -eq 'GET' -and $_.Path -match ('/runCommands/{0}\?\$expand=instanceView$' -f $name) })
        $reads.Count | Should -BeGreaterOrEqual 3
        $ended = $script:calls.IndexOf($reads[2])
        $dispatch = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/virtualMachines/archost01/runCommands/DbHubControl-archost01-\d{14}$' }) | Select-Object -First 1))
        $dispatch | Should -BeGreaterThan $ended -Because 'archost01''s activity goes out once the export there has ended'
        (Get-SessionStatus).rcaEarlier.documents.documentId | Should -Be '20261027T123000Z-archost01-0007'
    }

    It 'doesn''t save this session''s capture that an earlier session''s ID took, and says so (review of 02d398a)' {
        # A VM that sets its activity profile at boot (activityProfileOnBoot) began capturing before an earlier session's
        # export at this session's start ran there, which took that span under the earlier session's ID; the span went on
        # through this session. At 02d398a its documents went into that earlier session's history.
        $session = $script:fixtureSession
        $running = [ordered]@{ schemaVersion = 1; sessionId = $session; phase = 'running'; acceptedUtc = '2026-10-27T15:00:00Z'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $session) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
        $script:clock = [datetime]::new(2026, 10, 27, 15, 30, 0, [System.DateTimeKind]::Utc)
        Set-ServedRunner -Case @(@{ Id = '20261027T151000Z-sqlvm01-0011'; Session = ('e' * 32) })
        $null = Update-DbHubSessionRca -Context (New-TestContext -NowUtc $script:clock) -Tags @{ DbHubSessionId = $session }
        $status = Get-SessionStatus
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending' -Because 'it isn''t that earlier session''s capture'
        @($status.rca.documents) | Should -BeNullOrEmpty
        $export = @($status.steps | Where-Object step -EQ 'RCA.EXPORT')
        $export[0].state | Should -Be 'Warning'
        $export[0].message | Should -Match '1 document\(s\) of this session''s capture went with an earlier session''s ID, so they aren''t saved'
        $export[0].fix | Should -Match 'activityProfileOnBoot'
    }

    It 'stops asking for an earlier session''s evidence 7 days after its export, and keeps at most 4 earlier sessions'', saying which (review of 3b1348a)' {
        $stale = [ordered]@{ sessionId = ('e' * 32); pending = @(New-TestPending -DocumentId $script:fixtureIds[1] -Vm 'archost01'); leftVms = @(); finalRan = $true; expiresUtc = '2026-10-20T13:00:00Z' }
        $fresh = [ordered]@{ sessionId = $script:fixtureSession; pending = @(New-TestPending -DocumentId $script:fixtureIds[0] -Vm 'sqlvm01'); leftVms = @(); finalRan = $true; expiresUtc = '2026-11-02T13:00:00Z' }
        $b = [ordered]@{ schemaVersion = 1; sessionId = ('b' * 32); phase = 'stopped'; updatedUtc = '2026-10-27T13:00:00Z'; rca = [ordered]@{ sessionId = ('b' * 32); bundles = @(); documents = @(); pending = @(); leftVms = @(); final = $true; finalRan = $true; status = 'Pass'; message = '' }; rcaEarlierPending = @($stale, $fresh) }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $b -Depth 8 -Compress
        Set-TestSessionStart
        Set-PartsRunner
        $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = ('c' * 32); requestedBy = 'presenter' }) -Context (New-TestContext)
        $started.status | Should -BeIn 'Started', 'Partial'
        @($script:rcaCommands | Where-Object { $_.Request.documentId -eq $script:fixtureIds[1] }) | Should -BeNullOrEmpty -Because 'the runner deleted it'
        $status = Get-SessionStatus
        $expired = @($status.steps | Where-Object { $_.step -eq 'RCA.EARLIER' -and $_.state -eq 'Warning' })
        $expired.Count | Should -Be 1
        $expired[0].message | Should -Be 'Session eeeeeeee''s 1 document(s) on archost01 that an export listed but didn''t fetch whole aren''t asked for any more, so they aren''t in its history: the runner deletes an exported document 7 days after its export, which for these was by 2026-10-20 13:00 UTC.'
        $status.rcaEarlier.sessionId | Should -Be $script:fixtureSession
        $status.PSObject.Properties.Name | Should -Not -Contain 'rcaEarlierPending'
        # At most 4 earlier sessions in a status: the first to expire goes, and the others keep their order.
        $carried = @(1..5 | ForEach-Object { [ordered]@{ sessionId = ([string]$_ * 32); pending = @(New-TestPending -DocumentId $script:fixtureIds[0] -Vm 'sqlvm01'); leftVms = @(); finalRan = $true; expiresUtc = ('2026-11-0{0}T13:00:00Z' -f (6 - $_)) } })
        $backlog = Get-DbHubRcaBacklog -Settings $script:settings -Previous ([ordered]@{ sessionId = ('f' * 32); phase = 'refused'; rcaEarlierPending = $carried }) -SessionId ('c' * 32) -NowUtc $script:clock
        @($backlog.Entries | ForEach-Object { $_['sessionId'].Substring(0, 1) }) | Should -Be @('1', '2', '3', '4')
        @($backlog.Dropped | ForEach-Object { $_['sessionId'].Substring(0, 1) }) | Should -Be @('5')
        @($backlog.Expired) | Should -BeNullOrEmpty
    }

    It 'lets a session''s re-checks go on once a stop''s mark is older than a stop takes, so a stop that failed doesn''t block them (review of 3b1348a)' {
        $status = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T14:50:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession); stopBegunUtc = '2026-10-27T14:55:00Z' }
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $status -Depth 8 -Compress
        Set-FixtureRunner -Batches @($script:fixtureIds[0])
        (Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }).Outcome | Should -Be 'NoSession' -Because 'a stop began 5 minutes ago'
        @($script:rcaCommands) | Should -BeNullOrEmpty
        # The stop began 20 minutes ago and wrote no stopped status: its job failed, and the session runs on.
        $status['stopBegunUtc'] = '2026-10-27T14:40:00Z'
        $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $status -Depth 8 -Compress
        (Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }).Outcome | Should -Be 'Exported'
        @((Get-SessionStatus).rca.documents.documentId) | Should -Be @($script:fixtureIds[0])
    }

    It 'exports nothing at a start after a session whose stop exported everything, or one from before the export' {
        foreach ($rca in @([ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); pending = @(); leftVms = @(); final = $true; status = 'Pass'; message = '' }, $null)) {
            $previous = [ordered]@{ sessionId = $script:fixtureSession; phase = 'stopped' }
            if ($null -ne $rca) {
                $previous['rca'] = $rca
            }
            Get-DbHubRcaEarlier -Settings $script:settings -Previous $previous -SessionId 'fedcba9876543210fedcba9876543210' | Should -BeNullOrEmpty
        }
        Get-DbHubRcaEarlier -Settings $script:settings -Previous ([ordered]@{ sessionId = $script:fixtureSession; rca = [ordered]@{ sessionId = $script:fixtureSession; final = $false } }) -SessionId $script:fixtureSession | Should -BeNullOrEmpty -Because 'a session is never its own earlier session'
    }

    It 'packs at most 6 parts in a bundle, each within 24,000 bytes, and reads the version each write created' {
        $lines = @(1..13 | ForEach-Object { $script:fixtureParts[($_ - 1) % 4] })
        $bundles = @(New-DbHubRcaBundle -SessionId $script:fixtureSession -Line $lines)
        @($bundles | ForEach-Object { @(($_ | ConvertFrom-Json).parts).Count }) | Should -Be @(6, 6, 1)
        foreach ($bundle in $bundles) {
            [System.Text.Encoding]::UTF8.GetByteCount($bundle) | Should -BeLessOrEqual 24000
            Test-Json -Json $bundle -SchemaFile $script:transportSchema | Should -BeTrue
        }
        (@(New-DbHubRcaBundle -SessionId '' -Line @($script:fixtureParts[0]))[0] | ConvertFrom-Json).sessionId | Should -BeNullOrEmpty
        $written = Set-DbHubVaultSecret -Context (New-TestContext) -Name 'dbhub-session-metrics' -Value '{}'
        $written.Version | Should -Match '^[0-9a-f]{32}$'
        $written.Version | Should -Be $script:secrets['dbhub-session-metrics'][-1].Version
    }

    Context 'the Query Store sidecars on Run all''s path (2026-11-23, rca/README.md, Run all''s path for the sidecars)' {
        BeforeAll {
            $script:sidecarIndexFixture = Get-Content -LiteralPath (Join-Path -Path $script:rcaRoot -ChildPath 'fixtures/sidecar-index.json') -Raw | ConvertFrom-Json
            $script:sidecarFixtureLines = @{}
            foreach ($file in @(Get-ChildItem -Path (Join-Path -Path $script:rcaRoot -ChildPath 'fixtures') -Filter '*.sidecar-parts.txt' -File)) {
                $lines = @(Get-Content -LiteralPath $file.FullName | Where-Object { $_ })
                $script:sidecarFixtureLines[$lines[0].Split(' ')[2]] = $lines
            }
            $script:nextSession = 'fedcba9876543210fedcba9876543210'

            # The fixtures' three sidecars as the runner offers them (sidecar-index.json): the session's two, and one of no session.
            function Get-FixtureSidecar {
                return @($script:sidecarIndexFixture.documents | ForEach-Object { [ordered]@{ documentId = [string]$_.documentId; sessionId = $_.sessionId; parts = [int]$_.parts; sha256 = [string]$_.sha256; state = [string]$_.state } })
            }

            # A sidecar of its own: the T4 Query Store fixture under -Id, padded with -Pad bytes that don't compress, so it takes
            # more parts. Its part lines go where the runner reads them; returns its reference as the runner offers it.
            function New-TestSidecar([string] $Id, [string] $Session = $script:fixtureSession, [int] $Pad = 0) {
                $template = Get-Content -LiteralPath (Join-Path -Path $script:rcaRoot -ChildPath 'fixtures/t4-query-store.sidecar.json') -Raw | ConvertFrom-Json
                $template.documentId = $Id
                $template.sessionId = $(if ($Session) { $Session } else { $null })
                if ($Pad -gt 0) {
                    $bytes = [byte[]]::new($Pad)
                    [System.Random]::new($Pad).NextBytes($bytes)
                    $template | Add-Member -NotePropertyName 'padding' -NotePropertyValue ([System.Convert]::ToBase64String($bytes))
                }
                $plain = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $template -Depth 30 -Compress))
                $memory = [System.IO.MemoryStream]::new()
                $gzip = [System.IO.Compression.GZipStream]::new($memory, [System.IO.Compression.CompressionLevel]::Optimal, $true)
                $gzip.Write($plain, 0, $plain.Length)
                $gzip.Dispose()
                $data = $memory.ToArray()
                $sha = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($data) | ForEach-Object { $_.ToString('x2') })
                $count = [int][System.Math]::Ceiling($data.Length / 2400.0)
                $script:sidecarFixtureLines[$Id] = @(for ($i = 0; $i -lt $count; $i++) { 'DBHUBDEMO-RCAS 1 {0} {1}/{2} {3} {4}' -f $Id, ($i + 1), $count, $sha, [System.Convert]::ToBase64String($data, $i * 2400, [System.Math]::Min(2400, $data.Length - $i * 2400)) })
                return [ordered]@{ documentId = $Id; sessionId = $(if ($Session) { $Session } else { $null }); parts = $count; sha256 = $sha; state = 'new' }
            }

            # The runners' sidecars by VM (-Offer: VM name to references, the oldest first), 8 a page as the runner's index
            # pages them; each part a Run Command of -PartSeconds, each acknowledgement one of -AckSeconds, and what 'rca ack'
            # took (sidecarAcked) no longer offered. -IndexStatus and -IndexMessage are the index's own; -Old makes a VM's
            # bootstrap bundle (OldBundle) or runner (OldRunner) predate the sidecar.
            function Set-SidecarRunner([hashtable] $Offer = @{}, [int] $PartSeconds = 0, [int] $AckSeconds = 0, [string] $IndexStatus = 'Pass', [string] $IndexMessage = 'Sidecars to fetch.', [hashtable] $Old = @{}) {
                $script:sidecarOffers = $Offer
                $script:sidecarPartSeconds = $PartSeconds
                $script:sidecarAckSeconds = $AckSeconds
                $script:sidecarIndexStatus = $IndexStatus
                $script:sidecarIndexMessage = $IndexMessage
                $script:sidecarOld = $Old
                $script:sidecarAcked = [System.Collections.Generic.List[object]]::new()
                $script:rcaSidecarRunner = {
                    param($Command)
                    $request = $Command.Request
                    $old = [string]$script:sidecarOld[$Command.Vm]
                    if ($Command.Action -ne 'Rca' -and $old -eq 'OldBundle') {
                        return (New-TestRcaView -Action $Command.Action -Status 'Fail' -Message 'Unknown action; use EnableT3, EnableT4, Runner, StopGuest, or Rca.')
                    }
                    if ($Command.Action -ne 'Rca' -and $old -eq 'OldRunner') {
                        return (New-TestRcaView -Action $Command.Action -Status 'Not supported' -Message 'runner rca sidecar-export: this VM''s runner predates the Query Store sidecar, so nothing was fetched; ./scripts/deploy.ps1 updates it.' -Evidence @{ oldRunner = $true; exitCode = 1 })
                    }
                    switch ([string]$request.command) {
                        'sidecar-export' {
                            $taken = @($script:sidecarAcked | Where-Object { $_.Vm -eq $Command.Vm } | ForEach-Object { $_.Id })
                            $offered = @(@($script:sidecarOffers[$Command.Vm]) | Where-Object { $null -ne $_ -and [string]$_['documentId'] -notin $taken })
                            $slice = @($offered | Select-Object -Skip ((([int]$request.page) - 1) * 8) -First 8)
                            $index = [ordered]@{ kind = 'ContosoCare.RcaSidecarIndex'; version = 1; page = [int]$request.page; pages = [int][System.Math]::Ceiling($offered.Count / 8); documents = $slice; status = $script:sidecarIndexStatus; message = $script:sidecarIndexMessage }
                            $line = 'DBHUBDEMO-RCAS-INDEX ' + (ConvertTo-Json -InputObject $index -Depth 5 -Compress)
                            if ($offered.Count -eq 0) {
                                # Exit code 2, and the index's own status stands (8afcca24).
                                $status = $(if ($script:sidecarIndexStatus -eq 'Warning') { 'Warning' } else { 'Not selected' })
                                return (New-TestRcaView -Action 'RcaSidecarExport' -Status $status -Message ('runner rca sidecar-export: there is no sidecar to fetch. {0}' -f $script:sidecarIndexMessage).Trim() -Line $line -Evidence @{ exitCode = 2 })
                            }
                            return (New-TestRcaView -Action 'RcaSidecarExport' -Status 'Pass' -Message 'runner rca sidecar-export: its line follows.' -Line $line -Evidence @{ exitCode = 0 })
                        }
                        'ack' {
                            if (($script:clock - $Command.At).TotalSeconds -lt $script:sidecarAckSeconds) {
                                return $null
                            }
                            if ($null -eq $Command.PSObject.Properties['Taken']) {
                                foreach ($id in @($request.documentIds)) {
                                    $script:sidecarAcked.Add([pscustomobject]@{ Vm = $Command.Vm; Id = [string]$id })
                                }
                                $Command | Add-Member -NotePropertyName 'Taken' -NotePropertyValue $true
                            }
                            return (New-TestRcaView -Action 'RcaAck' -Status 'Pass' -Message ('runner rca ack: {0} sidecar(s) acknowledged.' -f @($request.documentIds).Count) -Evidence @{ exitCode = 0; documents = @($request.documentIds).Count })
                        }
                        default {
                            if (($script:clock - $Command.At).TotalSeconds -lt $script:sidecarPartSeconds) {
                                return $null
                            }
                            $line = @(@($script:sidecarFixtureLines[[string]$request.documentId]) | Where-Object { $_ -and $_.Split(' ')[3].StartsWith(('{0}/' -f $request.part)) }) | Select-Object -First 1
                            if (-not $line) {
                                return (New-TestRcaView -Status 'Fail' -Message 'runner rca part: exit code 1. The document or part doesn''t exist.' -Evidence @{ exitCode = 1 })
                            }
                            return (New-TestRcaView -Status 'Pass' -Message 'runner rca part: its line follows.' -Line $line -Evidence @{ exitCode = 0 })
                        }
                    }
                }
            }

            # The metrics secret's versions of one RCA tag: bundle, sidecar-bundle, or sidecar-index.
            function Get-SidecarVersion([string] $Tag) {
                return @($script:secrets['dbhub-session-metrics'] | Where-Object { [string]$_.Tags['rca'] -eq $Tag })
            }

            # The metrics' final version, the stop's last write: its rca tag says yes or no, whether it holds the evidence's index.
            function Get-FinalMetric {
                return (@($script:secrets['dbhub-session-metrics'] | Where-Object { [string]$_.Tags['rca'] -in 'yes', 'no' })[-1].Value | ConvertFrom-Json)
            }

            # The sidecar's Run Commands that went out: the index's pages, the parts of sidecars, and the acknowledgements.
            function Get-SidecarCommand([string] $Kind, [string] $Vm = '') {
                return @($script:rcaCommands | Where-Object {
                        $command = $_
                        $kindMatches = switch ($Kind) {
                            'page' { $command.Request.command -eq 'sidecar-export' }
                            'part' { $command.Request.command -eq 'part' -and ([string]$command.Request.documentId).EndsWith('-sidecar') }
                            'ack' { $command.Request.command -eq 'ack' }
                        }
                        (-not $Vm -or $command.Vm -eq $Vm) -and $kindMatches
                    })
            }
        }

        It 'fetches the stop''s sidecars after its evidence, into sidecar bundles, their index, and the metrics'' pointer to it' {
            Set-FixtureRunner
            $sidecars = @(Get-FixtureSidecar)
            Set-SidecarRunner -Offer @{ sqlvm01 = $sidecars }
            $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
            $result.status | Should -Be 'Stopped'
            $result.rca.status | Should -Be 'Pass' -Because 'the evidence goes on as before'
            $result.rca.documents | Should -Be 2
            $result.rca.sidecars.documents | Should -Be 3
            # Written in this order: the evidence's bundle, the sidecars' bundle, their index, then the metrics' final version.
            $versions = @($script:secrets['dbhub-session-metrics'])
            @($versions | ForEach-Object { [string]$_.Tags['rca'] }) | Should -Be @('bundle', 'sidecar-bundle', 'sidecar-index', 'yes')
            $bundle = $versions[1]
            Test-Json -Json $bundle.Value -SchemaFile $script:transportSchema | Should -BeTrue
            ($bundle.Value | ConvertFrom-Json).kind | Should -Be 'ContosoCare.RcaSidecarBundle'
            @(($bundle.Value | ConvertFrom-Json).parts | Where-Object { -not $_.StartsWith('DBHUBDEMO-RCAS 1 ', [System.StringComparison]::Ordinal) }) | Should -BeNullOrEmpty -Because 'a sidecar bundle never holds an evidence line'
            $decoded = Expand-TestBundle -Json @($bundle.Value)
            @($decoded.Keys | Sort-Object) | Should -Be @($sidecars.documentId | Sort-Object)
            $decoded['20261120T170000Z-sqlvm01-0002-sidecar'].kind | Should -Be 'ContosoCare.RcaSidecar'
            $index = $versions[2]
            Test-Json -Json $index.Value -SchemaFile $script:transportSchema | Should -BeTrue
            [System.Text.Encoding]::UTF8.GetByteCount($index.Value) | Should -BeLessOrEqual 24000
            ($index.Value | ConvertFrom-Json).kind | Should -Be 'ContosoCare.RcaSidecarBundleIndex'
            @(($index.Value | ConvertFrom-Json).bundles) | Should -Be @($bundle.Version)
            @(($index.Value | ConvertFrom-Json).documents.documentId) | Should -Be @($sidecars.documentId)
            $final = $versions[3].Value | ConvertFrom-Json
            $pointer = ConvertTo-Json -InputObject $final.rcaSidecars -Compress
            Test-Json -Json $pointer -SchemaFile $script:transportSchema | Should -BeTrue
            [System.Text.Encoding]::UTF8.GetByteCount($pointer) | Should -BeLessOrEqual 300
            $final.rcaSidecars.kind | Should -Be 'ContosoCare.RcaSidecarPointer'
            $final.rcaSidecars.index | Should -Be $index.Version
            $final.rcaSidecars.documents | Should -Be 3
            $final.rcaSidecars.status | Should -Be 'Pass'
            @($final.rca.documents.documentId) | Should -Be $script:fixtureIds -Because 'the rca member is the evidence''s, as before'
            @($final.series).Count | Should -BeGreaterThan 0
            # The sidecars' first Run Command goes out once the evidence's last one has ended and gone.
            $evidenceLast = @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/runCommands/DbHubControl-rca-sqlvm01-(x|\d{4})-\d{14}$' }) | Select-Object -Last 1
            $sidecarFirst = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-rca-sqlvm01-(i\d{2}|s\d{5})-\d{14}$' }) | Select-Object -First 1
            $script:calls.IndexOf($sidecarFirst) | Should -BeGreaterThan $script:calls.IndexOf($evidenceLast)
            $pages = @(Get-SidecarCommand -Kind 'page' -Vm 'sqlvm01')
            $pages.Count | Should -Be 1
            $pages[0].Request.final | Should -BeTrue -Because 'the stop''s page 1 asks for the session''s last'
            $pages[0].Request.sessionId | Should -Be $script:fixtureSession
            @(Get-SidecarCommand -Kind 'part').Count | Should -Be 4
            @($script:rcaCommands | Where-Object { $script:rcaDeleted -notcontains $_.Name }) | Should -BeNullOrEmpty
            # The stopped status keeps the state with its index, and the line Run all prints.
            $status = Get-SessionStatus
            $status.rcaSidecar.index | Should -Be $index.Version
            @($status.rcaSidecar.bundles) | Should -Be @($bundle.Version)
            @($status.rcaSidecar.documents.documentId) | Should -Be @($sidecars.documentId)
            @($status.rcaLines | ForEach-Object step) | Should -Be @('RCA.EXPORT', 'RCA.CAPTURE.T1', 'RCA.CAPTURE.T4', 'RCA.CAPTURE.T4-replica', 'RCA.SIDECAR.EXPORT')
            $line = @($status.rcaLines | Where-Object step -EQ 'RCA.SIDECAR.EXPORT')[0]
            $line.status | Should -Be 'Pass'
            $line.message | Should -Be '3 new sidecar(s), 4 part(s), in 1 bundle(s) in the control vault; 3 in all for this session.'
        }

        It 'shares the stop''s bound with the evidence: nothing goes out past it, what still runs then is deleted, and what it cut stays on the VM' {
            # The evidence's parts take 5 minutes, so 1 of the stop's 6 is left for the sidecars, whose parts take 1 each.
            Set-FixtureRunner
            $script:fixtureRunner = $script:rcaRunner
            $script:rcaRunner = {
                param($Command)
                if ($Command.Request.command -eq 'part' -and ($script:clock - $Command.At).TotalSeconds -lt 300) {
                    return $null
                }
                return (& $script:fixtureRunner $Command)
            }
            Set-SidecarRunner -Offer @{ sqlvm01 = @(Get-FixtureSidecar) } -PartSeconds 60
            $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
            $result.rca.status | Should -Be 'Pass'
            $result.rca.documents | Should -Be 2 -Because 'the evidence first, whole'
            $deadline = @($script:rcaCommands | Where-Object { $_.Request.command -eq 'export' } | Sort-Object -Property At)[0].At.AddMinutes(6)
            $evidenceEnd = @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/runCommands/DbHubControl-rca-sqlvm01-\d{4}-\d{14}$' } | ForEach-Object At | Sort-Object)[-1]
            $sidecarCommands = @(@(Get-SidecarCommand -Kind 'page') + @(Get-SidecarCommand -Kind 'part'))
            $sidecarCommands.Count | Should -BeGreaterThan 1
            @($sidecarCommands | Where-Object { $_.At -lt $evidenceEnd }) | Should -BeNullOrEmpty -Because 'sidecars never go out before the evidence has ended'
            @($sidecarCommands | Where-Object { $_.At -ge $deadline }) | Should -BeNullOrEmpty -Because 'nothing goes out past the stop''s bound'
            @($script:rcaCommands | Where-Object { $script:rcaDeleted -notcontains $_.Name }) | Should -BeNullOrEmpty -Because 'what still ran at the bound was deleted'
            @(Get-SidecarVersion -Tag 'sidecar-bundle') | Should -BeNullOrEmpty
            @(Get-SidecarVersion -Tag 'sidecar-index') | Should -BeNullOrEmpty
            $final = Get-FinalMetric
            $final.rcaSidecars.index | Should -BeNullOrEmpty
            $final.rcaSidecars.status | Should -Be 'Not selected'
            $status = Get-SessionStatus
            $status.rcaSidecar.left | Should -Be 3
            $status.rcaSidecar.waiting | Should -BeTrue
            $line = @($status.rcaLines | Where-Object step -EQ 'RCA.SIDECAR.EXPORT')[0]
            $line.status | Should -Be 'Warning'
            $line.message | Should -Match '3 sidecar\(s\) weren''t fetched whole in time; they stay on sqlvm01 for the next export\.'
            $line.fix | Should -Match 'the next session''s exports fetch it'

            # The next export fetches what the cut left: the runner offers it again, and the session's state doesn't list it.
            Set-SidecarRunner -Offer @{ sqlvm01 = @(Get-FixtureSidecar) }
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
            $again = Invoke-DbHubRcaSidecarSession -Context (New-TestContext -NowUtc $script:clock) -SessionId $script:fixtureSession -Earlier $status.rcaSidecar -DeadlineUtc $script:clock.AddMinutes(8)
            @($again.State['documents'] | ForEach-Object { $_['documentId'] }) | Should -Be @((Get-FixtureSidecar).documentId)
            $again.State['left'] | Should -Be 0
        }

        It 'fetches the T2 host''s sidecars one Run Command at a time, each gone before the next, after its evidence there (R871)' {
            $id = '20261027T142000Z-archost01-0001'
            Set-ServedRunner -Case @(@{ Id = $id; Session = $script:fixtureSession }) -Vm @('archost01')
            $first = New-TestSidecar -Id '20261027T141500Z-arcsql01-0001-sidecar' -Pad 5000
            $second = New-TestSidecar -Id '20261027T143000Z-arcsql01-0002-sidecar'
            $first.parts | Should -BeGreaterThan 1 -Because 'the sidecar needs a part after the first'
            Set-SidecarRunner -Offer @{ archost01 = @($first, $second) }
            $script:rcaListOpen = $true
            $script:rcaDeleteDelay = @{ archost01 = 2 }
            $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
            $result.status | Should -Be 'Stopped'
            $script:rcaMostOpen['archost01'] | Should -Be 1 -Because 'the T2 host takes one Run Command at a time, the evidence''s and the sidecars'' alike'
            @(Get-SidecarCommand -Kind 'part' -Vm 'archost01').Count | Should -Be ($first.parts + $second.parts)
            $index = (Get-SidecarVersion -Tag 'sidecar-index')[0].Value | ConvertFrom-Json
            @($index.documents.documentId) | Should -Be @($first.documentId, $second.documentId)
            @((Expand-TestBundle -Json @(Get-SidecarVersion -Tag 'sidecar-bundle' | ForEach-Object Value)).Keys) | Should -Be @($first.documentId, $second.documentId)
            $result.rca.documents | Should -Be 1 -Because 'the evidence there went first'
        }

        It 'reads the index''s pages, the next after the parts of the one before, and takes no more than the session''s index holds' {
            $script:vm['archost01'] = 'deallocated'
            $offer = @(1..10 | ForEach-Object { New-TestSidecar -Id ('20261027T14{0:d2}00Z-sqlvm01-{0:d4}-sidecar' -f $_) })
            Set-SidecarRunner -Offer @{ sqlvm01 = $offer }
            $done = Invoke-DbHubRcaSidecarSession -Context (New-TestContext) -SessionId $script:fixtureSession -DeadlineUtc $script:clock.AddMinutes(8)
            $pages = @(Get-SidecarCommand -Kind 'page')
            @($pages | ForEach-Object { [int]$_.Request.page }) | Should -Be @(1, 2)
            @($pages | ForEach-Object { $_.Request.final } | Select-Object -Unique) | Should -Be @($false) -Because 'only a stop''s export is final'
            # Page 2 goes out once page 1's eight sidecars have been fetched.
            $pageTwo = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '-i02-\d{14}$' }))[0])
            $lastOfPageOne = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '-s00801-\d{14}$' }))[0])
            $pageTwo | Should -BeGreaterThan $lastOfPageOne
            @($done.State['documents'] | ForEach-Object { $_['documentId'] }) | Should -Be @($offer.documentId)
            @(Get-SidecarVersion -Tag 'sidecar-bundle').Count | Should -Be 2 -Because '10 parts in bundles of at most 6'
            $done.Lines[0].Status | Should -Be 'Pass'
            $done.Lines[0].Message | Should -Be '10 new sidecar(s), 10 part(s), in 2 bundle(s) in the control vault; 10 in all for this session.'

            # 30 offered: what a session's status keeps of them (DbHubRcaSidecarStateBytes), the oldest first, and no page past
            # the one that filled it.
            Reset-TestAzure
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
            $offer = @(1..30 | ForEach-Object { New-TestSidecar -Id ('20261027T15{0:d2}00Z-sqlvm01-{0:d4}-sidecar' -f $_) })
            Set-SidecarRunner -Offer @{ sqlvm01 = $offer }
            $fits = [int][System.Math]::Floor($script:DbHubRcaSidecarStateBytes / (Get-DbHubRcaSidecarSize -Reference $offer[0]))
            $fits | Should -BeLessThan 30
            $done = Invoke-DbHubRcaSidecarSession -Context (New-TestContext) -SessionId $script:fixtureSession -DeadlineUtc $script:clock.AddMinutes(8)
            @($done.State['documents'] | ForEach-Object { $_['documentId'] }) | Should -Be @($offer[0..($fits - 1)].documentId)
            @(Get-SidecarCommand -Kind 'part' | ForEach-Object { $_.Request.documentId } | Select-Object -Unique) | Should -Be @($offer[0..($fits - 1)].documentId)
            @(Get-SidecarCommand -Kind 'page').Count | Should -Be ([int][System.Math]::Ceiling(($fits + 1) / 8))
            $done.Lines[0].Status | Should -Be 'Warning'
            $done.Lines[0].Message | Should -Match 'sqlvm01 offers more sidecars than the session''s sidecar index takes \(16 bundles, 64 parts, and what its status keeps\); they wait there for the next session''s exports\.'
            $done.State['waiting'] | Should -BeTrue
        }

        It 'keeps the metrics'' pointer within 300 bytes, out of T5''s share, and T4''s half as it was' {
            $script:bounds = @()
            Mock Get-DbHubPostgresMetricDocument { $script:bounds += [pscustomobject]@{ Kind = 'T4'; Bytes = $MaxBytes }; return [pscustomobject]@{ Json = '{"version":1,"sessionId":"x","servers":[],"series":[]}'; Bytes = 52; Status = 'Pass'; Message = 'T4.'; Replica = $false } }
            Mock Read-DbHubCosmosMetricSeries { return [pscustomobject]@{ Found = $true; Failed = $false; Message = '' } }
            Mock ConvertTo-DbHubCosmosMetricDocument { $script:bounds += [pscustomobject]@{ Kind = 'T5'; Bytes = $MaxBytes }; return [pscustomobject]@{ Json = '{"version":1}'; Bytes = 13; Status = 'Pass'; Message = 'T5.'; CapturedUtc = ''; StartUtc = ''; EndUtc = ''; WindowMinutes = 0; IntervalMinutes = 1 } }
            $pointer = New-DbHubRcaSidecarPointer -Index ('a' * 32) -Documents 64 -Status 'Warning' -Message ('A long message, ' * 40)
            $json = ConvertTo-Json -InputObject $pointer -Compress
            [System.Text.Encoding]::UTF8.GetByteCount($json) | Should -BeLessOrEqual 300
            $pointer['message'].Length | Should -BeLessOrEqual 120
            Test-Json -Json $json -SchemaFile $script:transportSchema | Should -BeTrue
            # A message the bytes would let through is cut to its 120 characters.
            $cut = New-DbHubRcaSidecarPointer -Index ('a' * 32) -Documents 3 -Status 'Pass' -Message ('m' * 150)
            $cut['message'] | Should -Be (('m' * 117) + '...')
            Test-Json -Json (ConvertTo-Json -InputObject $cut -Compress) -SchemaFile $script:transportSchema | Should -BeTrue
            $rcaIndex = [ordered]@{ kind = 'ContosoCare.RcaBundleIndex'; version = 1; sessionId = $script:fixtureSession; bundles = @(); documents = @(); status = 'Pass'; message = '' }
            $null = Save-DbHubSessionMetric -Context (New-TestContext) -Tags $script:groupTags -SessionId $script:fixtureSession -Rca $rcaIndex
            $null = Save-DbHubSessionMetric -Context (New-TestContext) -Tags $script:groupTags -SessionId $script:fixtureSession -Rca $rcaIndex -RcaSidecars $pointer
            $t4 = @($script:bounds | Where-Object Kind -EQ 'T4')
            $t5 = @($script:bounds | Where-Object Kind -EQ 'T5')
            $t4[1].Bytes | Should -Be $t4[0].Bytes -Because 'T4''s half doesn''t change'
            ($t5[0].Bytes - $t5[1].Bytes) | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount($json) + 16) -Because 'the pointer comes out of T5''s share'
            $written = ($script:secrets['dbhub-session-metrics'][-1].Value | ConvertFrom-Json)
            ConvertTo-Json -InputObject $written.rcaSidecars -Compress | Should -Be $json
            $written.rca.kind | Should -Be 'ContosoCare.RcaBundleIndex'
            # Without T5, it comes out of T4's room.
            Mock Read-DbHubCosmosMetricSeries { return [pscustomobject]@{ Found = $false; Failed = $false; Message = '' } }
            $script:bounds = @()
            $null = Save-DbHubSessionMetric -Context (New-TestContext) -Tags $script:groupTags -SessionId $script:fixtureSession -RcaSidecars $pointer
            $script:bounds[0].Bytes | Should -Be (24000 - [System.Text.Encoding]::UTF8.GetByteCount($json) - 16)
            # Checked as written: a pointer over 300 bytes goes without its message.
            $long = [ordered]@{ kind = 'ContosoCare.RcaSidecarPointer'; version = 1; index = ('a' * 32); documents = 3; status = 'Warning'; message = ('x' * 400) }
            $null = Save-DbHubSessionMetric -Context (New-TestContext) -Tags $script:groupTags -SessionId $script:fixtureSession -RcaSidecars $long
            $written = ($script:secrets['dbhub-session-metrics'][-1].Value | ConvertFrom-Json)
            [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $written.rcaSidecars -Compress)) | Should -BeLessOrEqual 300
            $written.rcaSidecars.message | Should -Be ''
            $written.rcaSidecars.index | Should -Be ('a' * 32)
            $written.rcaSidecars.documents | Should -Be 3
        }

        It 'acknowledges the request''s sidecars on the VM each names once the start''s activity went out, one Run Command a VM, and records what it sent' {
            Set-TestSessionStart
            Set-SidecarRunner
            $script:rcaListOpen = $true
            $script:rcaDeleteDelay = @{ archost01 = 2 }
            # T2's guest's IDs go to the T2 host, which reaches its runner; the T2 host's own name and any other host are no
            # runner's, so their IDs stay for the notebook (review of the contract, 2026-11-23).
            $ids = @('20261120T165000Z-sqlvm01-0001-sidecar', '20261120T170000Z-sqlvm01-0002-sidecar', '20261120T165500Z-arcsql01-0001-sidecar', '20261120T165000Z-archost01-0001-sidecar', '20261120T165000Z-otherhost-0001-sidecar')
            $request = @{ action = 'session'; sessionId = $script:nextSession; requestedBy = 'presenter'; rcaAcks = [ordered]@{ kind = 'ContosoCare.RcaAckRequest'; version = 1; documents = $ids } }
            Test-Json -Json (ConvertTo-Json -InputObject $request.rcaAcks -Compress) -SchemaFile $script:transportSchema | Should -BeTrue
            # Each status write, with how many acknowledgements had gone out then (T2c-2's review: the notebook reads the
            # first rcaAcks it sees as final).
            $script:statusWrites = [System.Collections.Generic.List[object]]::new()
            $script:secretWriteHook = {
                param($Name, $Body)
                if ($Name -eq 'dbhub-session-status') {
                    $written = [string]$Body.properties.value | ConvertFrom-Json
                    $result = ''
                    if ($null -ne $written.PSObject.Properties['rcaAcks']) {
                        $result = ConvertTo-Json -InputObject $written.rcaAcks -Depth 4 -Compress
                    }
                    $script:statusWrites.Add([pscustomobject]@{ Result = $result; Acks = @(Get-SidecarCommand -Kind 'ack').Count })
                }
            }
            $started = Invoke-DbHubControl -WebhookData (New-Webhook $request) -Context (New-TestContext)
            $started.status | Should -BeIn 'Started', 'Partial'
            $script:secretWriteHook = $null
            @($script:statusWrites | Where-Object { $_.Result -and $_.Acks -lt 2 }) | Should -BeNullOrEmpty -Because 'no status carries rcaAcks before both VMs'' acknowledgements were attempted'
            @($script:statusWrites | Where-Object { -not $_.Result -and $_.Acks -lt 2 }).Count | Should -BeGreaterThan 0 -Because 'the start writes its status before then'
            @($script:statusWrites | Where-Object Result | ForEach-Object Result | Select-Object -Unique).Count | Should -Be 1 -Because 'it''s written once, and later writes keep it'
            $acks = @(Get-SidecarCommand -Kind 'ack')
            $acks.Count | Should -Be 2 -Because 'one Run Command a VM, with all its IDs'
            @(($acks | Where-Object Vm -EQ 'sqlvm01').Request.documentIds) | Should -Be $ids[0..1]
            @(($acks | Where-Object Vm -EQ 'archost01').Request.documentIds) | Should -Be @($ids[2]) -Because 'T2''s guest, arcsql01, is on the T2 host'
            foreach ($vm in 'sqlvm01', 'archost01') {
                $ack = ($acks | Where-Object Vm -EQ $vm).Name
                $sent = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match ('/runCommands/{0}$' -f $ack) }))[0])
                $dispatch = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match ('/virtualMachines/{0}/runCommands/DbHubControl-{0}-\d{{14}}$' -f $vm) }))[0])
                $dispatch | Should -BeGreaterThan -1
                $sent | Should -BeGreaterThan $dispatch -Because "$vm's acknowledgement waits until the start's activity has gone out there"
            }
            # On the T2 host the acknowledgement's Run Command is gone, as Azure lists it, before the job goes on.
            $script:rcaMostOpen['archost01'] | Should -Be 1
            $hostAck = ($acks | Where-Object Vm -EQ 'archost01').Name
            $deletedAt = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match ('/runCommands/{0}$' -f $hostAck) }))[0])
            @($script:calls | Select-Object -Skip ($deletedAt + 1) | Where-Object { $_.Method -eq 'GET' -and $_.Path -match ('/runCommands/{0}$' -f $hostAck) }).Count | Should -BeGreaterOrEqual 2
            $status = Get-SessionStatus
            Test-Json -Json (ConvertTo-Json -InputObject $status.rcaAcks -Depth 4 -Compress) -SchemaFile $script:transportSchema | Should -BeTrue
            @($status.rcaAcks.sent | Sort-Object) | Should -Be @($ids[0..2] | Sort-Object)
            @($status.rcaAcks.left) | Should -Be @($ids[3..4])
            @(@($status.rcaAcks.sent) + @($status.rcaAcks.left) | Sort-Object) | Should -Be @($ids | Sort-Object)
            $status.rcaAcks.status | Should -Be 'Warning'
            $status.rcaAcks.message | Should -Match '^3 of 5 sidecar acknowledgement\(s\) sent before the start''s sidecar fetch \(2 on sqlvm01, 1 on archost01\); the rest weren''t: 2 name a host this control doesn''t know\.$'
            @($status.steps | Where-Object step -EQ 'RCA.SIDECAR.ACK') | Should -BeNullOrEmpty -Because 'the control notebook prints RCA.SIDECAR.ACK from rcaAcks (T2c-2)'
            # The runner took them: no start fetches them again.
            $expected = @(('{0}@sqlvm01' -f $ids[0]), ('{0}@sqlvm01' -f $ids[1]), ('{0}@archost01' -f $ids[2])) | Sort-Object
            @($script:sidecarAcked | ForEach-Object { '{0}@{1}' -f $_.Id, $_.Vm } | Sort-Object) | Should -Be $expected
            # A host segment is the VM's name as the runner writes it (Hosts.Normalize): lower case, each run of other
            # characters one hyphen.
            $odd = [pscustomobject]@{ sqlVmName = 'SQL_VM.01'; hostVmName = 'archost01'; t2GuestName = 'ArcSql01' }
            Get-DbHubRcaSidecarVm -Settings $odd -DocumentId '20261120T165000Z-sql-vm-01-0001-sidecar' | Should -Be 'SQL_VM.01'
            Get-DbHubRcaSidecarVm -Settings $odd -DocumentId '20261120T165000Z-arcsql01-0001-sidecar' | Should -Be 'archost01'
            Get-DbHubRcaSidecarVm -Settings $odd -DocumentId '20261120T165000Z-archost01-0001-sidecar' | Should -Be ''
            Get-DbHubRcaSidecarVm -Settings $odd -DocumentId '20261120T165000Z-sqlvm01-0001-sidecar' | Should -Be ''
            # A VM that isn't running gets none, and its IDs wait for the next start.
            Reset-TestAzure
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
            Set-SidecarRunner
            $work = New-DbHubRcaAckWork -Settings $script:settings -Acks ([pscustomobject]@{ Present = $true; Ids = @($ids[0], $ids[2]); Problem = '' })
            Invoke-DbHubRcaAck -Context (New-TestContext) -Work $work -DeadlineUtc $script:clock.AddMinutes(6)
            @(Get-SidecarCommand -Kind 'ack' | ForEach-Object Vm) | Should -Be @('sqlvm01')
            $alone = [ordered]@{}
            Complete-DbHubRcaAck -Status $alone -Work $work
            @($alone['rcaAcks'].left) | Should -Be @($ids[2])
            $alone['rcaAcks'].message | Should -Match 'archost01 didn''t run during this start'
            # A VM's older runner: the message the notebook prints names ./scripts/deploy.ps1.
            Reset-TestAzure
            $script:vm = @{ sqlvm01 = 'running'; archost01 = 'deallocated' }
            Set-SidecarRunner -Old @{ sqlvm01 = 'OldRunner' }
            $work = New-DbHubRcaAckWork -Settings $script:settings -Acks ([pscustomobject]@{ Present = $true; Ids = @($ids[0]); Problem = '' })
            Invoke-DbHubRcaAck -Context (New-TestContext) -Work $work -DeadlineUtc $script:clock.AddMinutes(6)
            $old = [ordered]@{}
            Complete-DbHubRcaAck -Status $old -Work $work
            $old['rcaAcks'].status | Should -Be 'Warning'
            $old['rcaAcks'].message | Should -Be 'None of the 1 sidecar acknowledgement(s) was sent: sqlvm01''s workload runner predates the Query Store sidecar. Run ./scripts/deploy.ps1, which updates the runner, its bootstrap bundle, the runbooks, and the control notebook together.'
        }

        It 'sends the acknowledgements within the start''s bound, which the earlier session''s evidence and the sidecars share' {
            # The session before it left sidecars on the VMs, so the start fetches them, after its acknowledgements.
            $previous = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'stopped'; updatedUtc = '2026-10-27T13:00:00Z'; rca = [ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); pending = @(); leftVms = @(); final = $true; finalRan = $true; status = 'Pass'; message = '' }; rcaSidecar = [ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); offered = 3; fetched = 0; left = 3; waiting = $true; status = 'Warning'; message = 'cut'; index = '' } }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
            Set-TestSessionStart
            # sqlvm01's acknowledgement takes 100 seconds.
            Set-SidecarRunner -AckSeconds 100
            $script:fetch = $null
            Mock Invoke-DbHubRcaSidecarSession { $script:fetch = [pscustomobject]@{ At = $script:clock; DeadlineUtc = $DeadlineUtc }; return [pscustomobject]@{ State = (ConvertTo-DbHubRcaSidecarState -State $null -SessionId $SessionId); Lines = @() } }
            $request = @{ action = 'session'; sessionId = $script:nextSession; requestedBy = 'presenter'; rcaAcks = [ordered]@{ kind = 'ContosoCare.RcaAckRequest'; version = 1; documents = @('20261120T165000Z-sqlvm01-0001-sidecar') } }
            $started = Invoke-DbHubControl -WebhookData (New-Webhook $request) -Context (New-TestContext)
            $started.status | Should -BeIn 'Started', 'Partial'
            (Get-SessionStatus).rcaAcks.status | Should -Be 'Pass'
            (Get-SessionStatus).rcaAcks.message | Should -Be '1 sidecar acknowledgement(s) sent before the start''s sidecar fetch: 1 on sqlvm01.'
            $ack = @(Get-SidecarCommand -Kind 'ack')[0]
            ($script:fetch.DeadlineUtc - $ack.At).TotalSeconds | Should -BeLessOrEqual 360 -Because 'the bound began before the acknowledgement'
            $left = ($script:fetch.DeadlineUtc - $script:fetch.At).TotalSeconds
            $left | Should -BeLessOrEqual 260 -Because 'the acknowledgement''s 100 seconds or more come out of the start''s 360'
            $left | Should -BeGreaterOrEqual 240

            # One that doesn't end is cut at the bound, where the fetch begins with no time left; the next VM's get none, and
            # their IDs wait for the next start.
            Reset-TestAzure
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
            Set-TestSessionStart
            Set-SidecarRunner -AckSeconds 1000
            $script:fetch = $null
            $request.rcaAcks.documents = @('20261120T165000Z-sqlvm01-0001-sidecar', '20261120T165500Z-arcsql01-0001-sidecar')
            $null = Invoke-DbHubControl -WebhookData (New-Webhook $request) -Context (New-TestContext)
            $status = Get-SessionStatus
            @($status.rcaAcks.sent) | Should -BeNullOrEmpty
            @($status.rcaAcks.left) | Should -Be @($request.rcaAcks.documents)
            $status.rcaAcks.status | Should -Be 'Warning'
            $status.rcaAcks.message | Should -Be 'None of the 2 sidecar acknowledgement(s) was sent: sqlvm01''s acknowledgements didn''t end in the time the start had for them; no time was left for archost01''s in the start''s bound.'
            @(Get-SidecarCommand -Kind 'ack' -Vm 'archost01') | Should -BeNullOrEmpty
            @($script:rcaCommands | Where-Object { $script:rcaDeleted -notcontains $_.Name }) | Should -BeNullOrEmpty -Because 'what still ran was deleted'
            $over = ($script:fetch.At - $script:fetch.DeadlineUtc).TotalSeconds
            $over | Should -BeGreaterOrEqual 0
            $over | Should -BeLessOrEqual 10 -Because 'nothing runs past the bound but the poll that finds it'
        }

        It 'acknowledges at a start after the earlier session''s evidence on each VM and before the sidecar fetch, so the runner offers none the history holds' {
            # The session before it ended without its final export, so the start exports it right before each VM's activity,
            # and fetches its evidence and then the sidecars it left on sqlvm01, the first of which the history holds.
            $earlier = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T13:00:00Z'; steps = @(); rca = [ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); pending = @(); leftVms = @(); final = $false; status = 'Pass'; message = '' } }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $earlier -Depth 8 -Compress
            Set-TestSessionStart
            Set-FixtureRunner
            $sidecars = @(Get-FixtureSidecar)
            Set-SidecarRunner -Offer @{ sqlvm01 = $sidecars }
            $script:rcaListOpen = $true
            $ids = @($sidecars[0].documentId, '20261101T100000Z-arcsql01-0009-sidecar')
            $request = @{ action = 'session'; sessionId = $script:nextSession; requestedBy = 'presenter'; rcaAcks = [ordered]@{ kind = 'ContosoCare.RcaAckRequest'; version = 1; documents = $ids } }
            $started = Invoke-DbHubControl -WebhookData (New-Webhook $request) -Context (New-TestContext)
            $started.status | Should -BeIn 'Started', 'Partial'
            foreach ($vm in 'sqlvm01', 'archost01') {
                $evidence = @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match ('/virtualMachines/{0}/runCommands/DbHubControl-rca-{0}-(x|\d{{4}})-\d{{14}}$' -f $vm) })
                $evidence.Count | Should -BeGreaterThan 0
                $ackPut = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match ('/virtualMachines/{0}/runCommands/DbHubControl-rca-{0}-k01-\d{{14}}$' -f $vm) }))[0])
                $ackPut | Should -BeGreaterThan $script:calls.IndexOf($evidence[-1]) -Because "the earlier session's evidence on $vm comes first"
            }
            $ackGone = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Path -match '/runCommands/DbHubControl-rca-sqlvm01-k01-\d{14}$' }))[0])
            $page = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/runCommands/DbHubControl-rca-sqlvm01-i01-\d{14}$' }))[0])
            $page | Should -BeGreaterThan $ackGone -Because 'the sidecar fetch follows the acknowledgements'
            $status = Get-SessionStatus
            @($status.rcaAcks.sent | Sort-Object) | Should -Be @($ids | Sort-Object)
            @($status.rcaEarlier.documents.documentId) | Should -Be $script:fixtureIds -Because 'the evidence goes on as before'
            # The runner no longer offers the sidecar the history holds: the start fetches only the others, under the new
            # session.
            @($status.rcaSidecar.documents.documentId) | Should -Be @($sidecars[1..2].documentId)
            @(Get-SidecarCommand -Kind 'part' | Where-Object { $_.Request.documentId -eq $sidecars[0].documentId }) | Should -BeNullOrEmpty
            $status.rcaSidecar.sessionId | Should -Be $script:nextSession
            @($script:rcaCommands | Where-Object { $script:rcaDeleted -notcontains $_.Name }) | Should -BeNullOrEmpty
        }

        It 'starts a session whose rcaAcks doesn''t follow the contract, sends none of it, and says why with the fix' {
            Set-TestSessionStart
            Set-SidecarRunner
            $ids = @('20261120T165000Z-sqlvm01-0001-sidecar', '20261120T170000Z-sqlvm01-0002-sidecar')
            $request = @{ action = 'session'; sessionId = $script:nextSession; requestedBy = 'presenter'; rcaAcks = [ordered]@{ kind = 'ContosoCare.RcaAckRequest'; version = 2; documents = $ids } }
            $started = Invoke-DbHubControl -WebhookData (New-Webhook $request) -Context (New-TestContext)
            $started.status | Should -BeIn 'Started', 'Partial'
            @(Get-SidecarCommand -Kind 'ack') | Should -BeNullOrEmpty
            $status = Get-SessionStatus
            @($status.rcaAcks.sent) | Should -BeNullOrEmpty
            @($status.rcaAcks.left) | Should -Be $ids
            $status.rcaAcks.status | Should -Be 'Warning'
            $status.rcaAcks.message | Should -Be 'None of the 2 sidecar acknowledgement(s) was sent: its rcaAcks is of a kind or version this runbook doesn''t know. Run ./scripts/deploy.ps1, which updates the runner, its bootstrap bundle, the runbooks, and the control notebook together.'
            Test-Json -Json (ConvertTo-Json -InputObject $status.rcaAcks -Depth 4 -Compress) -SchemaFile $script:transportSchema | Should -BeTrue
            @($status.steps | Where-Object step -EQ 'RCA.SIDECAR.ACK') | Should -BeNullOrEmpty
            # Only a session takes rcaAcks.
            (Test-DbHubControlRequest -WebhookData (New-Webhook @{ action = 'stop'; rcaAcks = $request.rcaAcks }) -Settings $script:settings).Valid | Should -BeFalse
            $valid = Test-DbHubControlRequest -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:nextSession; rcaAcks = [ordered]@{ kind = 'ContosoCare.RcaAckRequest'; version = 1; documents = @($ids[0]) } }) -Settings $script:settings
            $valid.Valid | Should -BeTrue
            @($valid.RcaAcks.Ids) | Should -Be @($ids[0])
            $valid.RcaAcks.Problem | Should -BeNullOrEmpty
            (ConvertFrom-DbHubRcaAckRequest -Body ([pscustomobject]@{ rcaAcks = [pscustomobject]@{ kind = 'ContosoCare.RcaAckRequest'; version = 1; documents = @($ids[0], $ids[0]) } })).Problem | Should -Match 'each once'
            (ConvertFrom-DbHubRcaAckRequest -Body ([pscustomobject]@{ rcaAcks = [pscustomobject]@{ kind = 'ContosoCare.RcaAckRequest'; version = 1; documents = @('20261120T165000Z-sqlvm01-0001') } })).Problem | Should -Match 'sidecar IDs' -Because 'an evidence document''s ID is no sidecar''s'
        }

        It 'says a VM''s older <Old> is updated by deploy.ps1, as a Warning, and the evidence goes on as before' -ForEach @(
            @{ Old = 'OldBundle'; Text = 'sqlvm01''s bootstrap bundle predates the Query Store sidecar, so no sidecar was fetched from it\.' }
            @{ Old = 'OldRunner'; Text = 'sqlvm01''s workload runner predates the Query Store sidecar, so no sidecar was fetched from it\.' }
        ) {
            Set-FixtureRunner
            Set-SidecarRunner -Offer @{ sqlvm01 = @(Get-FixtureSidecar) } -Old @{ sqlvm01 = $Old }
            $result = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
            $result.status | Should -Be 'Stopped'
            $result.rca.status | Should -Be 'Pass'
            $result.rca.documents | Should -Be 2
            @(Get-SidecarCommand -Kind 'part') | Should -BeNullOrEmpty
            @(Get-SidecarVersion -Tag 'sidecar-bundle') | Should -BeNullOrEmpty
            $status = Get-SessionStatus
            ($status.rcaLines | Where-Object step -EQ 'RCA.EXPORT').status | Should -Be 'Pass'
            $line = @($status.rcaLines | Where-Object step -EQ 'RCA.SIDECAR.EXPORT')[0]
            $line.status | Should -Be 'Warning'
            $line.message | Should -Match $Text
            $line.fix | Should -Match '^A runner or bootstrap bundle that predates the Query Store sidecar is updated by \./scripts/deploy\.ps1'
            (Get-FinalMetric).rcaSidecars.status | Should -Be 'Not selected'
        }

        It 'reports the runner''s own Warning on its index, which exit code 2 still carries (8afcca24)' {
            Set-FixtureRunner
            Set-SidecarRunner -IndexStatus 'Warning' -IndexMessage 'Nothing to fetch: no sidecar here is new or waiting for an acknowledgement. 2 sidecars expired unread: sealed more than 30 days ago and never acknowledged, so their Query Store evidence isn''t in the history.'
            $null = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext)
            $status = Get-SessionStatus
            ($status.rcaLines | Where-Object step -EQ 'RCA.EXPORT').status | Should -Be 'Pass'
            $line = @($status.rcaLines | Where-Object step -EQ 'RCA.SIDECAR.EXPORT')[0]
            $line.status | Should -Be 'Warning'
            $line.message | Should -Match 'sqlvm01: Nothing to fetch: no sidecar here is new or waiting for an acknowledgement\. 2 sidecars expired unread'
        }

        It 'fetches at each re-check what''s new, never a sidecar the session bundled already, and the stop''s index lists every bundle of the session' {
            $running = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T15:00:00Z'; acceptedUtc = '2026-10-27T13:30:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession) }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
            $a = New-TestSidecar -Id '20261027T140000Z-sqlvm01-0001-sidecar'
            $b = New-TestSidecar -Id '20261027T143000Z-sqlvm01-0002-sidecar'
            $c = New-TestSidecar -Id '20261027T150000Z-sqlvm01-0003-sidecar'
            Set-SidecarRunner -Offer @{ sqlvm01 = @($a) }
            $check = Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }
            $check.Outcome | Should -Be 'Nothing' -Because 'its outcome is the evidence''s'
            $first = Get-SessionStatus
            @($first.rcaSidecar.documents.documentId) | Should -Be @($a.documentId)
            @($first.rcaSidecar.bundles).Count | Should -Be 1
            $step = @($first.steps | Where-Object step -EQ 'RCA.SIDECAR.EXPORT')
            $step.Count | Should -Be 1
            $step[0].state | Should -Be 'Pass'
            # The runner offers a again, pending until a save acknowledges it, and b: only b is fetched.
            Set-SidecarRunner -Offer @{ sqlvm01 = @($a, $b) }
            $null = Update-DbHubSessionRca -Context (New-TestContext -NowUtc $script:clock.AddMinutes(30)) -Tags @{ DbHubSessionId = $script:fixtureSession }
            @(Get-SidecarCommand -Kind 'part' | Where-Object { $_.Request.documentId -eq $a.documentId }).Count | Should -Be $a.parts -Because 'a sidecar the session bundled isn''t fetched again'
            @((Get-SessionStatus).rcaSidecar.documents.documentId) | Should -Be @($a.documentId, $b.documentId)
            # The stop's tail takes c, and its index lists the re-checks' bundles and its own.
            Set-FixtureRunner -Batches @()
            Set-SidecarRunner -Offer @{ sqlvm01 = @($a, $b, $c) }
            $stop = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext -NowUtc $script:clock.AddMinutes(40))
            $stop.status | Should -BeIn 'Stopped', 'Partial'
            $index = (Get-SidecarVersion -Tag 'sidecar-index')[0].Value | ConvertFrom-Json
            @($index.bundles) | Should -Be @(Get-SidecarVersion -Tag 'sidecar-bundle' | ForEach-Object Version)
            @($index.bundles).Count | Should -Be 3
            @($index.documents.documentId) | Should -Be @($a.documentId, $b.documentId, $c.documentId)
            @((Expand-TestBundle -Json @(Get-SidecarVersion -Tag 'sidecar-bundle' | ForEach-Object Value)).Keys) | Should -Be @($a.documentId, $b.documentId, $c.documentId)
            (Get-FinalMetric).rcaSidecars.documents | Should -Be 3
        }

        It 'writes no sidecar bundle from a re-check once the session''s stop has begun, and sends no more Run Commands: <Case>' -ForEach @(
            @{ Case = 'the stop begins during a part, with more to send'; Pad = 5000 }
            @{ Case = 'the stop begins during the part that makes a sidecar whole'; Pad = 0 }
        ) {
            $running = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'running'; updatedUtc = '2026-10-27T15:00:00Z'; runEndUtc = '2026-10-27T16:30:00Z'; steps = @(); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $script:fixtureSession) }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $running -Depth 8 -Compress
            # T2's guest's sidecar, whose parts the T2 host takes one at a time: with Pad, the re-check has more to send after
            # the first; without, its one part makes it whole, and only the bundle's write is left.
            $a = New-TestSidecar -Id '20261027T140000Z-arcsql01-0001-sidecar' -Pad $Pad
            ($a.parts -gt 1) | Should -Be ($Pad -gt 0)
            Set-SidecarRunner -Offer @{ archost01 = @($a) }
            # Stop now begins while the re-check's first sidecar part runs.
            $script:sidecarRunnerBefore = $script:rcaSidecarRunner
            $script:stopFired = $false
            $script:rcaSidecarRunner = {
                param($Command)
                if (-not $script:stopFired -and $Command.Request.command -eq 'part') {
                    $script:stopFired = $true
                    $script:stopAt = $script:clock
                    $script:stopped = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'stop'; sessionId = $script:fixtureSession }) -Context (New-TestContext -NowUtc $script:clock)
                }
                return (& $script:sidecarRunnerBefore $Command)
            }
            $check = Update-DbHubSessionRca -Context (New-TestContext) -Tags @{ DbHubSessionId = $script:fixtureSession }
            $check.Outcome | Should -Be 'Changed'
            $script:stopped.status | Should -Be 'Stopped'
            $versions = @($script:secrets['dbhub-session-metrics'])
            [string]$versions[-1].Tags['rca'] | Should -BeIn 'yes', 'no' -Because 'nothing goes after the stop''s final version of the metrics'
            # The stop's own tail took the sidecar: every sidecar bundle is the stop's, which its index lists.
            $index = @(Get-SidecarVersion -Tag 'sidecar-index')
            $index.Count | Should -Be 1
            @(($index[0].Value | ConvertFrom-Json).bundles) | Should -Be @(Get-SidecarVersion -Tag 'sidecar-bundle' | ForEach-Object Version)
            $recheckStamp = '-' + (Get-SidecarCommand -Kind 'page')[0].Name.Split('-')[-1]
            @(Get-SidecarCommand -Kind 'part' -Vm 'archost01' | Where-Object { $_.Name.EndsWith($recheckStamp) }).Count | Should -Be 1 -Because 'the re-check sends no more parts once the stop has begun'
            @($script:rcaCommands | Where-Object { $_.Name.EndsWith($recheckStamp) -and $_.At -gt $script:stopAt }) | Should -BeNullOrEmpty
            (Get-SessionStatus).phase | Should -Be 'stopped'
        }

        It 'fetches at a start the sidecars the session before it left on the VMs, after that session''s evidence, under its own session' {
            $previous = [ordered]@{ schemaVersion = 1; sessionId = $script:fixtureSession; phase = 'stopped'; updatedUtc = '2026-10-27T13:00:00Z'; rca = [ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); pending = @(); leftVms = @(); final = $true; finalRan = $true; status = 'Pass'; message = '' }; rcaSidecar = [ordered]@{ sessionId = $script:fixtureSession; bundles = @(); documents = @(); offered = 3; fetched = 0; left = 3; waiting = $true; status = 'Warning'; message = 'cut'; index = '' } }
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
            Set-TestSessionStart
            $sidecars = @(Get-FixtureSidecar)
            Set-SidecarRunner -Offer @{ sqlvm01 = $sidecars }
            $started = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:nextSession; requestedBy = 'presenter' }) -Context (New-TestContext)
            $started.status | Should -BeIn 'Started', 'Partial'
            $pages = @(Get-SidecarCommand -Kind 'page' -Vm 'sqlvm01')
            $pages.Count | Should -Be 1
            $pages[0].Request.sessionId | Should -Be $script:nextSession -Because 'a span it binds now is the new session''s'
            $pages[0].Request.final | Should -BeFalse
            $dispatch = $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/virtualMachines/sqlvm01/runCommands/DbHubControl-sqlvm01-\d{14}$' }))[0])
            $script:calls.IndexOf((@($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '-i01-\d{14}$' }))[0]) | Should -BeGreaterThan $dispatch -Because 'after the start'
            $status = Get-SessionStatus
            $status.rcaSidecar.sessionId | Should -Be $script:nextSession
            @($status.rcaSidecar.documents.documentId) | Should -Be @($sidecars.documentId)
            (@($status.steps | Where-Object step -EQ 'RCA.SIDECAR.EXPORT'))[0].state | Should -Be 'Pass'

            # A session before it whose sidecars don't wait, and no earlier evidence: the start sends no sidecar Run Command.
            Reset-TestAzure
            $previous['rcaSidecar']['waiting'] = $false
            $script:automationVariables['DbHubSessionStatus'] = ConvertTo-Json -InputObject $previous -Depth 8 -Compress
            Set-TestSessionStart
            Set-SidecarRunner -Offer @{ sqlvm01 = $sidecars }
            $again = Invoke-DbHubControl -WebhookData (New-Webhook @{ action = 'session'; sessionId = $script:nextSession; requestedBy = 'presenter' }) -Context (New-TestContext)
            $again.status | Should -BeIn 'Started', 'Partial'
            @($script:rcaCommands) | Should -BeNullOrEmpty
        }

        It 'reads and builds the sidecar''s records the same way in Windows PowerShell 5.1' {
            $powershell = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue
            if (-not $IsWindows -or -not $powershell) {
                Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 runs on Windows only'
                return
            }
            $probe = {
                param([string] $Common, [string] $IndexLine, [string[]] $Parts, [string] $Body, [string] $State)
                . $Common
                $out = @()
                $index = ConvertFrom-DbHubRcaSidecarIndex -Line $IndexLine
                $out += ('{0}|{1}|{2}|{3}' -f $index.Valid, $index.Pages, $index.Status, (ConvertTo-Json -InputObject @($index.Documents) -Depth 4 -Compress))
                $out += @(New-DbHubRcaBundle -SessionId '5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21' -Line $Parts -Kind 'ContosoCare.RcaSidecarBundle')
                foreach ($id in @($Parts | ForEach-Object { $_.Split(' ')[2] } | Select-Object -Unique)) {
                    $expanded = Expand-DbHubRcaDocument -Line @($Parts | Where-Object { $_.Split(' ')[2] -eq $id }) -Sidecar
                    $out += ('{0}|{1}|{2}' -f $id, $expanded.Ok, $expanded.Document.documentId)
                }
                $out += (ConvertTo-Json -InputObject (New-DbHubRcaSidecarPointer -Index ('a' * 32) -Documents 3 -Status 'Pass' -Message ('A long message, ' * 20)) -Compress)
                # Within 300 bytes as this engine writes it: 5.1 writes each ' as \u0027, 6 bytes, so it cuts this message.
                $apostrophes = New-DbHubRcaSidecarPointer -Index ('a' * 32) -Documents 3 -Status 'Warning' -Message ("it's " * 24)
                $out += [string]([System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $apostrophes -Depth 3 -Compress)) -le 300)
                $out += (@((ConvertTo-DbHubRcaHostSegment -Name 'SQL_VM.01'), (ConvertTo-DbHubRcaHostSegment -Name '--Arc Sql 01--'), (ConvertTo-DbHubRcaHostSegment -Name ''), (ConvertTo-DbHubRcaHostSegment -Name (('a' * 39) + '-b'))) -join '|')
                $acks = ConvertFrom-DbHubRcaAckRequest -Body ($Body | ConvertFrom-Json)
                $out += ('{0}|{1}|{2}' -f $acks.Present, ($acks.Ids -join ','), $acks.Problem)
                $out += (ConvertTo-Json -InputObject (ConvertTo-DbHubRcaSidecarState -State (ConvertTo-DbHubDictionary -InputObject ($State | ConvertFrom-Json)) -SessionId '5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21') -Depth 4 -Compress)
                $out += ('{0}|{1}|{2}' -f (Get-DbHubRcaSidecarVm -Settings ([pscustomobject]@{ sqlVmName = 'sqlvm01'; hostVmName = 'archost01'; t2GuestName = 'arcsql01' }) -DocumentId '20261120T165500Z-arcsql01-0001-sidecar'), (Get-DbHubRcaSidecarSize -Reference ([ordered]@{ documentId = '20261120T165000Z-sqlvm01-0001-sidecar'; sessionId = $null; parts = 2; sha256 = ('0' * 64); state = 'new' })), (ConvertFrom-DbHubRcaOutput -Output 'DBHUBDEMO-WORKLOAD {"status":"Fail","message":"Unknown action; use EnableT3, EnableT4, Runner, StopGuest, or Rca.","evidence":{}}' -Action 'RcaSidecarExport' -Sidecar).OldBundle)
                return $out
            }
            $indexLine = 'DBHUBDEMO-RCAS-INDEX ' + (Get-Content -LiteralPath (Join-Path -Path $script:rcaRoot -ChildPath 'fixtures/sidecar-index.json') -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 5 -Compress)
            $parts = @($script:sidecarFixtureLines['20261120T165000Z-sqlvm01-0001-sidecar'] + $script:sidecarFixtureLines['20261120T170000Z-sqlvm01-0002-sidecar'])
            $body = '{"action":"session","rcaAcks":{"kind":"ContosoCare.RcaAckRequest","version":1,"documents":["20261120T165000Z-sqlvm01-0001-sidecar"]}}'
            $state = '{"sessionId":"5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21","bundles":["0123456789abcdef0123456789abcdef"],"documents":[{"documentId":"20261120T170000Z-sqlvm01-0002-sidecar","sessionId":null,"parts":1,"sha256":"' + ('f' * 64) + '","state":"pending"}],"offered":3,"fetched":1,"left":2,"waiting":true,"status":"Warning","message":"m","index":"fedcba9876543210fedcba9876543210"}'
            $common = Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1'
            $here = @(& $probe $common $indexLine $parts $body $state)
            $inputFile = Join-Path -Path $TestDrive -ChildPath 'sidecar-probe.json'
            Set-Content -LiteralPath $inputFile -Value (ConvertTo-Json -InputObject @{ common = $common; index = $indexLine; parts = $parts; body = $body; state = $state; probe = $probe.ToString() } -Depth 4) -Encoding utf8
            $command = "`$in = Get-Content -LiteralPath '{0}' -Raw | ConvertFrom-Json; `$probe = [scriptblock]::Create(`$in.probe); `$out = & `$probe `$in.common `$in.index ([string[]]`$in.parts) `$in.body `$in.state; `$out | ForEach-Object {{ [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]`$_)) }}" -f $inputFile
            $output = @(& $powershell.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command)
            $LASTEXITCODE | Should -Be 0
            $there = @($output | Select-Object -Last $here.Count | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(([string]$_).Trim())) })
            $there | Should -Be $here
            $here[0] | Should -Match '^True\|1\|Pass\|\[\{"documentId":"20261120T165000Z-sqlvm01-0001-sidecar","sessionId":"5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21","parts":2,'
            $here[2] | Should -Be '20261120T165000Z-sqlvm01-0001-sidecar|True|20261120T165000Z-sqlvm01-0001-sidecar'
            $here[-5] | Should -Be 'True'
            $here[-4] | Should -Be ('sql-vm-01|arc-sql-01|host|{0}' -f ('a' * 39))
            $here[-3] | Should -Be 'True|20261120T165000Z-sqlvm01-0001-sidecar|'
            $here[-1] | Should -Be ('archost01|{0}|True' -f (Get-DbHubRcaSidecarSize -Reference ([ordered]@{ documentId = '20261120T165000Z-sqlvm01-0001-sidecar'; sessionId = $null; parts = 2; sha256 = ('0' * 64); state = 'new' })))
        }
    }

    It 'decodes, checks, and bundles the evidence the same way in Windows PowerShell 5.1' {
        $powershell = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue
        if (-not $IsWindows -or -not $powershell) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 runs on Windows only'
            return
        }
        $probe = {
            param([string] $Common, [string[]] $Parts)
            . $Common
            $out = @()
            foreach ($id in @($Parts | ForEach-Object { $_.Split(' ')[2] } | Select-Object -Unique)) {
                $expanded = Expand-DbHubRcaDocument -Line @($Parts | Where-Object { $_.Split(' ')[2] -eq $id })
                $coverage = @(Get-DbHubRcaCoverage -Document $expanded.Document | ForEach-Object { '{0}:{1}:{2:HH:mm}-{3:HH:mm}' -f $_.Target, $_.Captured, $_.StartUtc, $_.EndUtc })
                $out += ('{0}|{1}|{2}|{3}' -f $id, $expanded.Ok, $expanded.Document.documentId, ($coverage -join ','))
            }
            $out += @(New-DbHubRcaBundle -SessionId '5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21' -Line $Parts)
            $out += (ConvertTo-Json -InputObject (New-DbHubRcaIndex -State ([ordered]@{ sessionId = 'abc'; bundles = @('0123456789abcdef0123456789abcdef'); documents = @([ordered]@{ documentId = 'x'; parts = 2; sha256 = 'y' }); status = 'Pass'; message = 'ok' })) -Depth 5 -Compress)
            # The earlier sessions' evidence still on the VMs (reviews of 3b1348a and 93243d6): a carried session's
            # documents, then the replaced status's own capture that no export took, as a status carries them.
            $previous = [ordered]@{ sessionId = ('b' * 32); phase = 'running'; updatedUtc = '2026-10-27T13:00:00Z'; rca = [ordered]@{ sessionId = ('b' * 32); bundles = @(); documents = @(); pending = @(); leftVms = @(); final = $false }; rcaEarlierPending = @([ordered]@{ sessionId = ('a' * 32); pending = @([ordered]@{ documentId = '20261120T170000Z-sqlvm01-0002'; parts = 2; sha256 = ('0' * 64); vm = 'archost01' }); leftVms = @(); finalRan = $true; expiresUtc = '2026-11-03T13:00:00Z' }) }
            $backlog = Get-DbHubRcaBacklog -Settings ([pscustomobject]@{ sqlVmName = 'sqlvm01'; hostVmName = 'archost01' }) -Previous $previous -SessionId ('c' * 32) -NowUtc ([datetime]::new(2026, 10, 28, 15, 0, 0, [System.DateTimeKind]::Utc))
            $out += (ConvertTo-Json -InputObject @(foreach ($entry in @($backlog.Entries)) { ConvertTo-DbHubRcaCarry -Entry $entry }) -Depth 6 -Compress)
            # Two sessions holding one VM, another session's document handed to its entry, and the VMs a session's activity
            # went to (review of 93243d6).
            $hosts = [pscustomobject]@{ sqlVmName = 'sqlvm01'; hostVmName = 'archost01' }
            $conflict = [ordered]@{ sessionId = ('b' * 32); phase = 'stopped'; acceptedUtc = '2026-10-27T11:00:00Z'; updatedUtc = '2026-10-27T13:00:00Z'; dispatchUtc = [ordered]@{ T2 = '2026-10-27T11:06:00Z' }; metrics = [ordered]@{ status = 'Pass' }; rca = [ordered]@{ sessionId = ('b' * 32); leftVms = @('archost01'); finalRan = $true }; rcaEarlierPending = @([ordered]@{ sessionId = ('a' * 32); pending = @(); leftVms = @('archost01'); heldUntilUtc = '2026-11-20T13:00:00Z' }) }
            $split = Get-DbHubRcaBacklog -Settings $hosts -Previous $conflict -SessionId ('c' * 32) -NowUtc ([datetime]::new(2026, 10, 28, 15, 0, 0, [System.DateTimeKind]::Utc))
            $out += (ConvertTo-Json -InputObject ([ordered]@{ entries = @(@($split.Entries) | ForEach-Object { ConvertTo-DbHubRcaCarry -Entry $_ }); inseparable = @($split.Inseparable) }) -Depth 6 -Compress)
            $handed = [ordered]@{ sessionId = ('c' * 32) }
            $null = Add-DbHubRcaElsewhere -Status $handed -Document @([ordered]@{ documentId = '20261120T170000Z-sqlvm01-0002'; parts = 2; sha256 = ('0' * 64); vm = 'sqlvm01'; sessionId = ('a' * 32) }) -NowUtc ([datetime]::new(2026, 10, 28, 15, 0, 0, [System.DateTimeKind]::Utc))
            $out += (ConvertTo-Json -InputObject $handed -Depth 6 -Compress)
            $out += ((Get-DbHubRcaActivityVm -Settings $hosts -Status ([ordered]@{ dispatchUtc = [ordered]@{ T5 = '2026-10-27T11:05:00Z'; T2 = '2026-10-27T11:06:00Z' }; runCommands = @() })) -join ',')
            # When a document's window starts, and when a session's activity ended, as the time windows read them (review
            # of 02d398a): Windows PowerShell 5.1's ConvertFrom-Json keeps times as strings.
            $stopped = '{"phase":"stopped","runEndUtc":"2026-10-27T12:45:00Z","stoppedUtc":"2026-10-27T13:00:00Z"}' | ConvertFrom-Json
            $out += ('{0}|{1}|{2}' -f (ConvertFrom-DbHubRcaDocumentTime -DocumentId '20261027T140000Z-sqlvm01-0001').ToString('o'), (Get-DbHubRcaSessionEnd -Status (ConvertTo-DbHubDictionary -InputObject $stopped)).ToString('o'), [string](ConvertFrom-DbHubRcaDocumentTime -DocumentId 'not-a-document'))
            # Where a carried session's capture is bound to it, kept only for the VMs it holds, and whether an export's
            # runner ran, from the action's evidence (re-check of d2067d69).
            $bound = [ordered]@{ sessionId = ('e' * 32); phase = 'stopped'; metrics = [ordered]@{ status = 'Pass' }; rca = [ordered]@{ sessionId = ('e' * 32); final = $true; finalRan = $true }; rcaEarlierPending = @([ordered]@{ sessionId = ('a' * 32); pending = @(); leftVms = @('archost01'); boundVms = @('archost01', 'sqlvm01'); heldUntilUtc = '2026-11-20T13:00:00Z' }) }
            $out += (ConvertTo-Json -InputObject @(@((Get-DbHubRcaBacklog -Settings $hosts -Previous $bound -SessionId ('c' * 32) -NowUtc ([datetime]::new(2026, 10, 28, 15, 0, 0, [System.DateTimeKind]::Utc))).Entries) | ForEach-Object { ConvertTo-DbHubRcaCarry -Entry $_ }) -Depth 6 -Compress)
            $out += ('{0}|{1}' -f (ConvertFrom-DbHubRcaOutput -Output 'DBHUBDEMO-WORKLOAD {"status":"Fail","message":"m","evidence":{"host":"ArcHost"}}').Ran, (ConvertFrom-DbHubRcaOutput -Output 'DBHUBDEMO-WORKLOAD {"status":"Fail","message":"m","evidence":{"host":"ArcHost","exitCode":0}}').Ran)
            return $out
        }
        $common = Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1'
        $here = @(& $probe $common $script:fixtureParts)
        $inputFile = Join-Path -Path $TestDrive -ChildPath 'rca-probe.json'
        Set-Content -LiteralPath $inputFile -Value (ConvertTo-Json -InputObject @{ common = $common; parts = $script:fixtureParts; probe = $probe.ToString() } -Depth 4) -Encoding utf8
        $command = "`$in = Get-Content -LiteralPath '{0}' -Raw | ConvertFrom-Json; `$probe = [scriptblock]::Create(`$in.probe); `$out = & `$probe `$in.common ([string[]]`$in.parts); `$out | ForEach-Object {{ [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]`$_)) }}" -f $inputFile
        $output = @(& $powershell.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command)
        $LASTEXITCODE | Should -Be 0
        $there = @($output | Select-Object -Last $here.Count | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(([string]$_).Trim())) })
        $there | Should -Be $here
        $here[0] | Should -Be '20261120T165000Z-sqlvm01-0001|True|20261120T165000Z-sqlvm01-0001|T1:True:16:50-17:05'
        $here[1] | Should -Be '20261120T170000Z-sqlvm01-0002|True|20261120T170000Z-sqlvm01-0002|T4:True:17:00-17:20,T4-replica:True:17:00-17:20'
        $here[-7] | Should -Be ('[{{"sessionId":"{0}","pending":[{{"documentId":"20261120T170000Z-sqlvm01-0002","parts":2,"sha256":"{1}","vm":"archost01"}}],"leftVms":[],"expiresUtc":"2026-11-03T13:00:00Z"}},{{"sessionId":"{2}","pending":[],"leftVms":["sqlvm01","archost01"],"heldUntilUtc":"2026-11-26T13:00:00Z"}}]' -f ('a' * 32), ('0' * 64), ('b' * 32))
        $here[-6] | Should -Be ('{{"entries":[{{"sessionId":"{1}","pending":[],"leftVms":["archost01"],"heldUntilUtc":"2026-11-26T11:00:00Z","startUtc":"2026-10-27T11:00:00Z"}}],"inseparable":[{{"sessionId":"{0}","vm":"archost01","with":"{1}","why":""}}]}}' -f ('a' * 32), ('b' * 32))
        $here[-5] | Should -Be ('{{"sessionId":"{0}","rcaEarlierPending":[{{"sessionId":"{1}","pending":[{{"documentId":"20261120T170000Z-sqlvm01-0002","parts":2,"sha256":"{2}","vm":"sqlvm01"}}],"leftVms":[],"expiresUtc":"2026-11-04T15:00:00Z"}}]}}' -f ('c' * 32), ('a' * 32), ('0' * 64))
        $here[-4] | Should -Be 'sqlvm01,archost01'
        $here[-3] | Should -Be '2026-10-27T14:00:00.0000000Z|2026-10-27T12:45:00.0000000Z|'
        $here[-2] | Should -Be ('[{{"sessionId":"{0}","pending":[],"leftVms":["archost01"],"heldUntilUtc":"2026-11-20T13:00:00Z","boundVms":["archost01"]}}]' -f ('a' * 32))
        $here[-1] | Should -Be 'False|True'
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
            '{"action":"session","sessionId":"0123456789abcdef0123456789abcdef"}'
            '{"action":"session","sessionId":"0123456789abcdef0123456789abcdef","durationMinutes":120}'
            '{"action":"session"}'
            '{"action":"capture","sessionId":"0123456789abcdef0123456789abcdef"}'
            '{"action":"stop","sessionId":"0123456789abcdef0123456789abcdef"}'
            '{"action":"pending","requestedBy":"capture-t2-golden.ps1"}'
            '{"action":"pending","sessionId":"0123456789abcdef0123456789abcdef"}'
            # A start's rcaAcks (2026-11-23, rca/transport.schema.json, ackRequest), which only a session takes.
            '{"action":"session","sessionId":"0123456789abcdef0123456789abcdef","rcaAcks":{"kind":"ContosoCare.RcaAckRequest","version":1,"documents":["20261120T165000Z-sqlvm01-0001-sidecar","20261120T165500Z-arcsql01-0001-sidecar"]}}'
            '{"action":"stop","rcaAcks":{"kind":"ContosoCare.RcaAckRequest","version":1,"documents":["20261120T165000Z-sqlvm01-0001-sidecar"]}}'
        )
        $expected = @($bodies | ForEach-Object { (Test-DbHubControlRequest -WebhookData (New-Webhook $_) -Settings $script:settings).Valid })
        ($expected | ForEach-Object { $_.ToString() }) -join ',' | Should -Be 'True,False,True,True,False,False,False,True,True,False,True,True,True,False,True,False'
        $requestFile = Join-Path -Path $TestDrive -ChildPath 'requests.json'
        Set-Content -LiteralPath $requestFile -Value (ConvertTo-Json -InputObject @{ settings = $script:settingsJson; bodies = $bodies } -Depth 4) -Encoding utf8
        $common = Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1'
        $command = ". '{0}'; `$in = Get-Content -LiteralPath '{1}' -Raw | ConvertFrom-Json; `$settings = ConvertFrom-DbHubSetting -Json `$in.settings; `$out = @(foreach (`$b in `$in.bodies) {{ (Test-DbHubControlRequest -WebhookData ([pscustomobject]@{{ RequestBody = [string]`$b }}) -Settings `$settings).Valid }}); `$out -join ','" -f $common, $requestFile
        $output = & $powershell.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command
        $LASTEXITCODE | Should -Be 0
        ([string]($output | Select-Object -Last 1)).Trim() | Should -Be (($expected | ForEach-Object { $_.ToString() }) -join ',')
    }

    It 'orders the replica''s sizes, combines metric points, and writes a session''s JSON and T5''s container''s body the same way in Windows PowerShell 5.1 (2026-11-14, 2026-11-19)' {
        $powershell = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue
        if (-not $IsWindows -or -not $powershell) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 runs on Windows only'
            return
        }
        # The same pure work in both: Windows PowerShell 5.1's ConvertFrom-Json keeps times as strings, its ConvertTo-Json
        # differs in places, and .NET Framework has no DateTime.UnixEpoch.
        $probe = {
            param([string] $Common, [string] $SettingsJson)
            . $Common
            $settings = ConvertFrom-DbHubSetting -Json $SettingsJson
            $order = (Get-DbHubReplicaSizeOrder -T4SkuName 'Standard_D2ds_v5' -Record 'Standard_D4ads_v5@any' -Sizes @($settings.t4Replica.sizes)) -join ','
            $points = New-Object -TypeName 'System.Collections.Generic.SortedDictionary[datetime,double]'
            foreach ($minute in 0..9) {
                $points[(New-Object -TypeName DateTime -ArgumentList 2026, 10, 27, 15, $minute, 0, ([System.DateTimeKind]::Utc))] = [double](($minute * 7) % 11) + 0.04
            }
            $converted = ConvertTo-DbHubMetricPoint -Point $points -Aggregation 'Maximum' -Unit 'Seconds' -IntervalMinutes 5
            $document = [ordered]@{ version = 1; sessionId = 'abc'; servers = @([ordered]@{ role = 'replica'; target = 'T4-replica' }); series = @([ordered]@{ metric = 'physical_replication_delay_in_seconds'; points = $converted }) }
            $windows = Get-DbHubReplicaLagPlan -ProfileSetUtc (New-Object -TypeName DateTime -ArgumentList 2026, 10, 27, 15, 10, 0, ([System.DateTimeKind]::Utc)) -RunEndUtc (New-Object -TypeName DateTime -ArgumentList 2026, 10, 27, 17, 8, 0, ([System.DateTimeKind]::Utc))
            $status = [ordered]@{ windows = $windows; steps = @() }
            Add-DbHubSessionStep -Status $status -Step 'Replica' -State 'Pass' -Message 'Ready.'
            # T5's container's body as Invoke-DbHubArm sends it (2026-11-19): the settings' indexing policy, parsed by each runtime.
            $body = Get-DbHubT5ContainerBody -Settings $settings -Tags @{ deploymentId = 'abc123'; owner = 'presenter@contoso.example'; component = 'demo'; DbHubBusyBy = 'session' }
            return @($order, (ConvertTo-Json -InputObject $document -Depth 8 -Compress), (ConvertTo-Json -InputObject $status -Depth 8 -Compress), ($body | ConvertTo-Json -Depth 20 -Compress))
        }
        $common = Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1'
        $here = & $probe $common $script:settingsJson
        $inputFile = Join-Path -Path $TestDrive -ChildPath 'probe.json'
        Set-Content -LiteralPath $inputFile -Value (ConvertTo-Json -InputObject @{ common = $common; settings = $script:settingsJson; probe = $probe.ToString() } -Depth 4) -Encoding utf8
        $command = "`$in = Get-Content -LiteralPath '{0}' -Raw | ConvertFrom-Json; `$probe = [scriptblock]::Create(`$in.probe); `$out = & `$probe `$in.common `$in.settings; `$out | ForEach-Object {{ [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]`$_)) }}" -f $inputFile
        $output = @(& $powershell.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command)
        $LASTEXITCODE | Should -Be 0
        $there = @($output | Select-Object -Last 4 | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(([string]$_).Trim())) })
        $there[0] | Should -Be 'Standard_D2ds_v5,Standard_D4ads_v5,Standard_D4ds_v5'
        $there[0] | Should -Be $here[0]
        $there[1] | Should -Be $here[1]
        $there[1] | Should -Match '"points":\[\["2026-10-27T15:00:00Z",[0-9.]+\],\["2026-10-27T15:05:00Z",[0-9.]+\]\]'
        $there[2] | Should -Match '"windows":\[\{"startUtc":"2026-10-27T16:00:00Z","endUtc":"2026-10-27T16:09:00Z"\},\{"startUtc":"2026-10-27T17:00:00Z","endUtc":"2026-10-27T17:06:00Z"\}\]'
        $there[2] | Should -Match '"steps":\[\{"step":"Replica","state":"Pass"'
        $there[3] | Should -Be $here[3]
        $there[3] | Should -Be '{"tags":{"owner":"presenter@contoso.example","deploymentId":"abc123"},"properties":{"resource":{"id":"patient-events","partitionKey":{"paths":["/patientId"],"kind":"Hash","version":2},"indexingPolicy":{"indexingMode":"consistent","automatic":true,"includedPaths":[{"path":"/*"}],"excludedPaths":[{"path":"/payload/?"},{"path":"/\"_etag\"/?"}]}},"options":{"throughput":400}}}'
    }

    It 'prints the status copy''s lists for the golden capture the same way in Windows PowerShell 5.1 (pending, 2026-11-23)' {
        $powershell = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue
        if (-not $IsWindows -or -not $powershell) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 runs on Windows only'
            return
        }
        # The result line DbHub-Control prints, as DbHub-Control.ps1 writes it: Windows PowerShell 5.1's ConvertFrom-Json keeps
        # times as strings and has no -AsHashtable, and a one-item list must stay a list in both.
        $probe = {
            param([string] $Common, [string] $Copy)
            . $Common
            # The sandbox's cmdlet, answering with the copy.
            Set-Item -Path 'function:Get-AutomationVariable' -Value ([scriptblock]::Create(("param([string] `$Name) '{0}'" -f $Copy.Replace("'", "''"))))
            $context = [pscustomobject]@{ Log = (New-Object -TypeName 'System.Collections.Generic.List[string]') }
            $result = Get-DbHubRcaPendingList -Context $context
            return ($result | ConvertTo-Json -Depth 6 -Compress)
        }
        $copy = ConvertTo-Json -Depth 8 -Compress -InputObject ([ordered]@{
                sessionId = 'a' * 32; phase = 'stopped'; updatedUtc = '2026-11-20T19:00:00Z'
                rca = [ordered]@{ pending = @([ordered]@{ documentId = 'doc-own-t2'; parts = 1; sha256 = ('a' * 64); vm = 'archost01' }) }
                rcaHandoff = @()
                rcaEarlierPending = @([ordered]@{ sessionId = 'b' * 32; pending = @([ordered]@{ documentId = 'doc-earlier-t2'; vm = 'archost01' }); expiresUtc = '2026-11-25T00:00:00Z' })
            })
        $common = Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1'
        $here = & $probe $common $copy
        $inputFile = Join-Path -Path $TestDrive -ChildPath 'pending.json'
        Set-Content -LiteralPath $inputFile -Value (ConvertTo-Json -InputObject @{ common = $common; copy = $copy; probe = $probe.ToString() } -Depth 4) -Encoding utf8
        $command = "`$in = Get-Content -LiteralPath '{0}' -Raw | ConvertFrom-Json; `$probe = [scriptblock]::Create(`$in.probe); `$out = & `$probe `$in.common `$in.copy; [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]`$out))" -f $inputFile
        $output = @(& $powershell.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command)
        $LASTEXITCODE | Should -Be 0
        $there = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(([string]($output | Select-Object -Last 1)).Trim()))
        # Windows PowerShell 5.1's ConvertTo-Json escapes an apostrophe, which any JSON reader reads back the same.
        $there.Replace('\u0027', "'") | Should -Be $here
        $there | Should -Match ('"rca":\{"pending":\[\{"documentId":"doc-own-t2","vm":"archost01"\}\]\},"rcaHandoff":\[\],"rcaEarlierPending":\[\{"sessionId":"b{32}","pending":\[\{"documentId":"doc-earlier-t2","vm":"archost01"\}\],"expiresUtc":"2026-11-25T00:00:00Z"\}\]')
        $there | Should -Match '"updatedUtc":"2026-11-20T19:00:00Z"'
    }
}
