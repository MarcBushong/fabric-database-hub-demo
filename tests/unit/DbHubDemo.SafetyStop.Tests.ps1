BeforeAll {
    # The nightly safety stop's module side (ADR 0024): its names, its role, its times, its setup against a fake Azure (the
    # template, the runbook, the schedules, and the role, as an Owner, a Contributor, and a Role Based Access Control
    # Administrator), its state and status, the cost estimate's and the stop text's view of it, DONE's note, and the Owner's
    # command. Azure is a fake behind Invoke-DemoAzCli, so Invoke-DemoAz (the subscription guard) and the private body files
    # run for real. IDs are placeholders.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')

    $script:sub = '11111111-2222-3333-4444-555555555555'
    $script:group = '/subscriptions/{0}/resourceGroups/rg-dbhub-demo' -f $script:sub
    $script:account = '{0}/providers/Microsoft.Automation/automationAccounts/aa-dbhub-demo-safetystop' -f $script:group
    $script:principal = 'cccccccc-0000-0000-0000-00000000000c'
    $script:clientId = '99999999-9999-9999-9999-999999999999'
    $script:approvedActions = @(
        'Microsoft.Resources/subscriptions/resourceGroups/read'
        'Microsoft.Compute/virtualMachines/read'
        'Microsoft.Compute/virtualMachines/instanceView/read'
        'Microsoft.Compute/virtualMachines/deallocate/action'
        'Microsoft.Sql/servers/databases/read'
        'Microsoft.DBforPostgreSQL/flexibleServers/read'
        'Microsoft.DBforPostgreSQL/flexibleServers/stop/action'
    )
    $script:now = [datetime]::new(2026, 11, 5, 18, 0, 0, [System.DateTimeKind]::Utc)

    function New-SafetyConfig([string] $Zone = 'Pacific Standard Time', [string] $Shutdown = '1900', [object] $AutoPause = 15) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = $script:sub
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['autoShutdownTime'] = $Shutdown
        $config['autoShutdownTimeZone'] = $Zone
        $config['t3AutoPauseMinutes'] = $AutoPause
        return $config
    }

    function New-AzResult([int] $ExitCode = 0, [string] $StdOut = '', [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
    }

    function Get-ArgumentValue([object[]] $Arguments, [string] $Name) {
        $index = [array]::IndexOf($Arguments, $Name)
        if ($index -ge 0 -and $index + 1 -lt $Arguments.Count) {
            return [string]$Arguments[$index + 1]
        }
        return ''
    }

    function Get-NotFound([string] $What) {
        return (New-AzResult -ExitCode 3 -StdErr ("ERROR: (ResourceNotFound) The Resource '{0}' was not found." -f $What))
    }

    # A schedule as Azure Automation answers for it: the zone in its IANA form, whatever form it was given (Phase 25d).
    function New-ScheduleAnswer([string] $LocalTime, [bool] $Enabled = $true) {
        $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')
        $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($script:now, $zone)
        $parts = $LocalTime -split ':'
        $next = [datetime]::new($local.Year, $local.Month, $local.Day, [int]$parts[0], [int]$parts[1], 0, [System.DateTimeKind]::Unspecified)
        if ($next -le $local) {
            $next = $next.AddDays(1)
        }
        @{ isEnabled = $Enabled; timeZone = 'America/Los_Angeles'; nextRun = [System.TimeZoneInfo]::ConvertTimeToUtc($next, $zone).ToString('o') }
    }

    # The fake Azure Resource Manager behind 'az rest'. -Query is what --url-parameters carried.
    function Invoke-FakeArm([string] $Method, [string] $Url, [string] $Body, [string] $Query = '') {
        $path = ([uri]$Url).AbsolutePath
        $query = [uri]::UnescapeDataString(([uri]$Url).Query) + $Query
        switch -Regex ($path) {
            '^/subscriptions/[^/]+/providers/Microsoft\.Authorization/permissions$' {
                $actions = if ($script:canDefine) { @('*') } else { @('*/read') }
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = @(@{ actions = $actions; notActions = @() }) } -Depth 5))
            }
            '/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Authorization/permissions$' {
                $actions = if ($script:canAssign) { @('*/read', 'Microsoft.Authorization/roleAssignments/write') } else { @('*/read') }
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = @(@{ actions = $actions; notActions = @() }) } -Depth 5))
            }
            '/providers/Microsoft\.Authorization/roleDefinitions$' {
                if ($script:roleReadFails) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (AuthorizationFailed) The client has no access.')
                }
                $value = @(if ($script:roleId) { @{ name = $script:roleId; properties = @{ roleName = 'DbHub Demo Safety Stop'; permissions = @(@{ actions = @($script:roleActions) }) } } })
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = $value } -Depth 8))
            }
            '/providers/Microsoft\.Authorization/roleDefinitions/([0-9a-f-]+)$' {
                if ($Method -eq 'put') {
                    $properties = ($Body | ConvertFrom-Json -AsHashtable)['properties']
                    $script:roleId = $Matches[1]
                    $script:roleActions = @($properties['permissions'][0]['actions'])
                    $script:roleDefinitions.Add($properties)
                }
                return (New-AzResult -StdOut '{}')
            }
            '/userAssignedIdentities/id-dbhub-demo-safetystop$' {
                if (-not $script:identityExists) {
                    return (Get-NotFound 'id-dbhub-demo-safetystop')
                }
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ properties = @{ principalId = $script:principal; clientId = $script:clientId } }))
            }
            '^(?<scope>.+)/providers/Microsoft\.Authorization/roleAssignments$' {
                $scope = $Matches['scope']
                $value = @($script:assignments | Where-Object { $query -match "principalId eq '([0-9a-f-]+)'" -and $_.principalId -eq $Matches[1] -and $_.scope -eq $scope } | ForEach-Object { @{ properties = @{ scope = $_.scope; roleDefinitionId = $_.roleDefinitionId; principalId = $_.principalId } } })
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = $value } -Depth 6))
            }
            '^(?<scope>.+)/providers/Microsoft\.Authorization/roleAssignments/(?<name>[0-9a-f-]+)$' {
                $properties = ($Body | ConvertFrom-Json -AsHashtable)['properties']
                $script:assignments.Add([pscustomobject]@{ name = $Matches['name']; scope = $Matches['scope']; roleDefinitionId = $properties['roleDefinitionId']; principalId = $properties['principalId']; principalType = $properties['principalType'] })
                return (New-AzResult -StdOut '{}')
            }
            '/runbooks/DbHub-Stop/content$' {
                if (-not $script:published) {
                    return (Get-NotFound 'DbHub-Stop')
                }
                return (New-AzResult -StdOut $script:published)
            }
            '/runbooks/DbHub-Stop/draft/content$' {
                $script:draft = $Body
                return (New-AzResult)
            }
            '/runbooks/DbHub-Stop/publish$' {
                $script:published = $script:draft
                return (New-AzResult)
            }
            '/runbooks/DbHub-Stop$' {
                return (New-AzResult -StdOut '{}')
            }
            '/schedules/(?<schedule>[^/]+)$' {
                $name = $Matches['schedule']
                if ($Method -eq 'get') {
                    if (-not $script:schedules.Contains($name)) {
                        return (Get-NotFound $name)
                    }
                    return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ name = $name; properties = $script:schedules[$name] } -Depth 6))
                }
                if ($Method -eq 'delete') {
                    $script:schedules.Remove($name)
                    return (New-AzResult)
                }
                $properties = ($Body | ConvertFrom-Json -AsHashtable)['properties']
                # ConvertFrom-Json turns an ISO 8601 text into a DateTime: the start time is read from the body as sent.
                $properties['startTime'] = [regex]::Match($Body, '"startTime":"([^"]+)"').Groups[1].Value
                $script:scheduleBodies.Add([pscustomobject]@{ Name = $name; Properties = $properties })
                $offset = [DateTimeOffset]::Parse([string]$properties['startTime'], [System.Globalization.CultureInfo]::InvariantCulture)
                $script:schedules[$name] = @{ isEnabled = $true; timeZone = 'America/Los_Angeles'; nextRun = $offset.UtcDateTime.ToString('o') }
                return (New-AzResult -StdOut '{}')
            }
            '/jobSchedules$' {
                # As live (2026-11-09) and as Learn's sample answer: the list returns no parameters.
                $value = @($script:links | ForEach-Object { @{ properties = @{ jobScheduleId = $_.Id; schedule = @{ name = $_.Schedule }; runbook = @{ name = $_.Runbook }; parameters = $null; runOn = $null } } })
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = $value } -Depth 8))
            }
            '/jobSchedules/(?<id>[0-9a-f-]{36})$' {
                $id = $Matches['id']
                if ($Method -eq 'get') {
                    # Job Schedule - Get returns the link's parameters.
                    $script:linkReads++
                    if ($script:linkReadFails) {
                        return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (InternalServerError) The service is unavailable.')
                    }
                    $link = $script:links | Where-Object Id -EQ $id | Select-Object -First 1
                    if ($null -eq $link) {
                        return (Get-NotFound $id)
                    }
                    return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ properties = @{ jobScheduleId = $link.Id; schedule = @{ name = $link.Schedule }; runbook = @{ name = $link.Runbook }; parameters = $link.Parameters; runOn = $null } } -Depth 8))
                }
                if ($Method -eq 'delete') {
                    $script:links = [System.Collections.Generic.List[object]]@($script:links | Where-Object Id -NE $id)
                    return (New-AzResult)
                }
                $properties = ($Body | ConvertFrom-Json -AsHashtable)['properties']
                $script:links.Add([pscustomobject]@{ Id = $id; Schedule = [string]$properties['schedule']['name']; Runbook = [string]$properties['runbook']['name']; Parameters = $properties['parameters'] })
                return (New-AzResult -StdOut '{}')
            }
            '/automationAccounts/aa-dbhub-demo-safetystop/jobs$' {
                if ($script:jobsReadFails) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (AuthorizationFailed) The client has no access to read the jobs.')
                }
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = @($script:jobs) } -Depth 6))
            }
            '/jobs/(?<job>[^/]+)/output$' {
                # Job - Get Output answers for a job's ID and for its name alike (live, 2026-11-09).
                $key = $Matches['job']
                $script:outputReads++
                $script:outputKeys.Add($key)
                $id = if ($script:jobNames.ContainsKey($key)) { $script:jobNames[$key] } else { $key }
                return (New-AzResult -StdOut ([string]$script:outputs[$id]))
            }
            '/automationAccounts/aa-dbhub-demo-safetystop/jobs/(?<job>[^/]+)$' {
                # Job - Get returns the job's parameters; the list doesn't.
                $key = $Matches['job']
                $script:jobReads.Add($key)
                if ($script:jobReadFails) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (InternalServerError) The service is unavailable.')
                }
                $id = if ($script:jobNames.ContainsKey($key)) { $script:jobNames[$key] } else { $key }
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ name = $key; properties = @{ jobId = $id; parameters = @{ Scope = [string]$script:jobScopes[$id] } } } -Depth 6))
            }
        }
        return (New-AzResult -ExitCode 1 -StdErr ('ERROR: the fake has no answer for {0} {1}' -f $Method, $path))
    }

    function Reset-FakeAzure {
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:writes = [System.Collections.Generic.List[string]]::new()
        $script:deployments = [System.Collections.Generic.List[object]]::new()
        $script:assignments = [System.Collections.Generic.List[object]]::new()
        $script:roleDefinitions = [System.Collections.Generic.List[object]]::new()
        $script:scheduleBodies = [System.Collections.Generic.List[object]]::new()
        $script:links = [System.Collections.Generic.List[object]]::new()
        $script:schedules = [ordered]@{}
        $script:canDefine = $true
        $script:canAssign = $true
        $script:roleId = ''
        $script:roleActions = @()
        $script:roleReadFails = $false
        $script:identityExists = $true
        $script:published = ''
        $script:draft = ''
        $script:templateFails = $false
        $script:jobs = @()
        $script:jobsReadFails = $false
        $script:outputs = @{}
        $script:outputReads = 0
        $script:outputKeys = [System.Collections.Generic.List[string]]::new()
        $script:jobNames = @{}
        $script:jobScopes = @{}
        $script:jobReads = [System.Collections.Generic.List[string]]::new()
        $script:jobReadFails = $false
        $script:linkReads = 0
        $script:linkReadFails = $false
    }

    function Register-FakeAzure {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $words = @($ArgumentList)
            $text = $words -join ' '
            $script:azCalls.Add($text)
            foreach ($word in $words) {
                if ([string]$word -match '["%]') {
                    throw "An Azure CLI argument contains '`"' or '%', which cmd.exe can't pass to az.cmd unchanged."
                }
            }
            if ($words[0] -eq 'rest') {
                $method = Get-ArgumentValue $words '--method'
                $bodyText = ''
                $bodyArgument = Get-ArgumentValue $words '--body'
                if ($bodyArgument) {
                    $bodyText = Get-Content -LiteralPath $bodyArgument.Substring(1) -Raw
                }
                $queryText = ''
                $queryArgument = Get-ArgumentValue $words '--url-parameters'
                if ($queryArgument) {
                    $parameters = Get-Content -LiteralPath $queryArgument.Substring(1) -Raw | ConvertFrom-Json -AsHashtable
                    $queryText = '?' + ((@($parameters.Keys) | ForEach-Object { '{0}={1}' -f $_, $parameters[$_] }) -join '&')
                }
                if ($method -ne 'get') {
                    $script:writes.Add(('{0} {1}' -f $method, ([uri](Get-ArgumentValue $words '--url')).AbsolutePath))
                }
                return (Invoke-FakeArm -Method $method -Url (Get-ArgumentValue $words '--url') -Body $bodyText -Query $queryText)
            }
            switch -Wildcard ($text) {
                'group show*' {
                    return (New-AzResult -StdOut '{"name":"rg-dbhub-demo","tags":{"solution":"fabric-database-hub-demo","environment":"demo","owner":"owner@contoso.example","purpose":"customer-demo","costCenter":"demo","autoShutdown":"1900 Pacific Standard Time","deploymentId":"abc123","DbHubDeployStage":"Validation","ArcSQLServerExtensionDeployment":"PAYG"}}')
                }
                'deployment group create*' {
                    $file = (Get-ArgumentValue $words '--parameters').Substring(1)
                    $script:deployments.Add([pscustomobject]@{ Text = $text; Parameters = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable) })
                    if ($script:templateFails) {
                        return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (RequestDisallowedByPolicy) Resource ''aa-dbhub-demo-safetystop'' was disallowed by policy.')
                    }
                    return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ identityPrincipalId = @{ value = $script:principal }; identityClientId = @{ value = $script:clientId }; automationAccountId = @{ value = $script:account } }))
                }
            }
            return (New-AzResult -ExitCode 1 -StdErr ('ERROR: the fake has no answer for: {0}' -f $text))
        }
    }

    # What a deployment run has once the safety stop is in place: the schedules, their links, the role, its assignment, and
    # the published runbook.
    function Set-FakeInPlace {
        $config = New-SafetyConfig
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config; Now = $script:now } { Invoke-DemoSafetyStopSetup -Config $Config -NowUtc $Now -Confirm:$false }
        $script:writes.Clear()
        $script:deployments.Clear()
    }

    # A job of the safety stop's runbook and its output's result line. -JobName is the job's name when it isn't its ID: a
    # schedule's job is named SCH_<guid>_<guid>_<ticks> (live, 2026-11-09). -NoJobId leaves properties.jobId out. -Scope is
    # the job's parameter, which only Job - Get returns.
    function Add-FakeJob([string] $Id, [string] $Status, [string] $Created, [hashtable] $Result, [string] $JobName = '', [switch] $NoJobId, [string] $Scope = '') {
        $name = if ($JobName) { $JobName } else { $Id }
        $properties = @{ status = $Status; creationTime = $Created; runbook = @{ name = 'DbHub-Stop' } }
        if (-not $NoJobId) {
            $properties['jobId'] = $Id
        }
        $script:jobs = @($script:jobs) + @(@{ name = $name; properties = $properties })
        $script:jobNames[$name] = $Id
        $script:jobScopes[$Id] = $Scope
        if ($null -ne $Result) {
            $script:outputs[$Id] = "[03:00:01Z] a log line`nDBHUB-STOP {0}`n" -f (ConvertTo-Json -InputObject $Result -Compress -Depth 6)
        }
    }

    function New-TestResult([string] $CheckId, [string] $Status = 'Pass') {
        New-DemoResult -CheckId $CheckId -Area 'infra' -Target 'subscription' -Status $Status -Message ('{0} {1}' -f $CheckId, $Status)
    }
}

AfterAll {
    Initialize-GuardTestContext -Clear
}

Describe 'The nightly safety stop''s names, role, and times (ADR 0024)' {
    It 'names its identity, account, runbook, and schedules in the demo resource group' {
        $name = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { Get-DemoSafetyStopName -Config $Config }
        $name.ResourceGroup | Should -Be 'rg-dbhub-demo'
        $name.AutomationAccount | Should -Be 'aa-dbhub-demo-safetystop'
        $name.AutomationAccountId | Should -Be $script:account
        $name.Identity | Should -Be 'id-dbhub-demo-safetystop'
        $name.Runbook | Should -Be 'DbHub-Stop'
        $name.StopSchedule | Should -Be 'dbhub-safety-stop'
        $name.CheckSchedule | Should -Be 'dbhub-safety-t3check'
        $name.RoleName | Should -Be 'DbHub Demo Safety Stop'
    }

    It 'has exactly the owner-approved actions, as ADR 0024 lists them, and nothing that starts, writes, or deletes' {
        $definition = InModuleScope DbHubDemo { Get-DemoSafetyStopRoleDefinition -SubscriptionId '11111111-2222-3333-4444-555555555555' }
        $actions = @($definition.properties.permissions[0].actions)
        $actions | Should -Be $script:approvedActions
        @($definition.properties.permissions[0].notActions) | Should -BeNullOrEmpty
        @($definition.properties.permissions[0].dataActions) | Should -BeNullOrEmpty
        @($definition.properties.assignableScopes) | Should -Be @('/subscriptions/11111111-2222-3333-4444-555555555555')
        @($actions | Where-Object { $_ -match '\*|/start/|/write$|/delete$|runCommand|Microsoft\.Authorization|Microsoft\.Automation|Microsoft\.KeyVault' }) | Should -BeNullOrEmpty
        $adr = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'docs/adr/0024-nightly-safety-stop.md') -Raw
        $section = [regex]::Match($adr, '(?s)### The role: DbHub Demo Safety Stop(.+?)\n### ').Groups[1].Value
        @([regex]::Matches($section, '(?m)^- `([^`]+)`$') | ForEach-Object { $_.Groups[1].Value }) | Should -Be $script:approvedActions
    }

    It 'runs at the auto-shutdown time and checks T3 <Offset> minutes later for an auto-pause of <AutoPause>' -ForEach @(
        @{ AutoPause = 15; Offset = 30; Check = '19:30' }
        @{ AutoPause = 60; Offset = 75; Check = '20:15' }
        @{ AutoPause = -1; Offset = 30; Check = '19:30' }
        @{ AutoPause = 1440; Offset = 345; Check = '00:45' }
    ) {
        $when = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig -AutoPause $AutoPause); Now = $script:now } { Get-DemoSafetyStopTime -Config $Config -NowUtc $Now }
        $when.TimeZone | Should -Be 'Pacific Standard Time'
        $when.StopLocalTime | Should -Be '19:00'
        $when.CheckLocalTime | Should -Be $Check
        $when.CheckOffsetMinutes | Should -Be $Offset
        $when.AutoPauseMinutes | Should -Be $AutoPause
        # 2026-11-05 18:00 UTC is 10:00 in Pacific Standard Time, so the next stop is that evening.
        $when.StopStartTime | Should -Be '2026-11-05T19:00:00-08:00'
    }

    It 'takes T3''s auto-pause from the profile when t3AutoPauseMinutes is 0, and starts tomorrow when today''s time is less than 10 minutes away' {
        $config = New-SafetyConfig -AutoPause 0
        $config['profile'] = 'demo-day'
        $when = InModuleScope DbHubDemo -Parameters @{ Config = $config; Now = [datetime]::new(2026, 11, 6, 2, 55, 0, [System.DateTimeKind]::Utc) } { Get-DemoSafetyStopTime -Config $Config -NowUtc $Now }
        $when.AutoPauseMinutes | Should -Be 60
        $when.CheckLocalTime | Should -Be '20:15'
        # 02:55 UTC is 18:55 Pacific: 19:00 is 5 minutes away, so the first stop is the next evening.
        $when.StopStartTime | Should -Be '2026-11-06T19:00:00-08:00'
        $when.CheckStartTime | Should -Be '2026-11-05T20:15:00-08:00'
    }
}

Describe 'Invoke-DemoSafetyStopSetup against a fake Azure (ADR 0024)' {
    BeforeEach {
        Reset-FakeAzure
        Register-FakeAzure
        Initialize-GuardTestContext
        $script:setup = { param([System.Collections.IDictionary] $Config = (New-SafetyConfig)) InModuleScope DbHubDemo -Parameters @{ Config = $Config; Now = $script:now } { @(Invoke-DemoSafetyStopSetup -Config $Config -ConfigPath './config/demo.config.json' -NowUtc $Now -Confirm:$false) } }
    }

    It 'as an Owner: deploys its identity and account, publishes its runbook, schedules it, and creates and assigns its role' {
        $results = & $script:setup
        @($results | ForEach-Object { '{0}={1}' -f $_.checkId, $_.status }) | Should -Be @('SAFETYSTOP.RESOURCES=Pass', 'SAFETYSTOP.RUNBOOK=Pass', 'SAFETYSTOP.SCHEDULE=Pass', 'SAFETYSTOP.ROLE=Pass')
        # The template: the demo's own tags plus component safety-stop, never deploy.ps1's state tags.
        $script:deployments.Count | Should -Be 1
        $script:deployments[0].Text | Should -Match 'deployment group create --resource-group rg-dbhub-demo --name dbhub-safetystop --template-file \S+safetystop\.bicep'
        $tags = $script:deployments[0].Parameters['parameters']['tags']['value']
        $tags['component'] | Should -Be 'safety-stop'
        $tags['deploymentId'] | Should -Be 'abc123'
        $tags['environment'] | Should -Be 'demo'
        $tags.Keys | Should -Not -Contain 'DbHubDeployStage'
        $tags.Keys | Should -Not -Contain 'ArcSQLServerExtensionDeployment'
        # The runbook: DbHub-Stop with the safety stop's settings.
        $script:published | Should -Match '"purpose":"safety-stop"'
        $script:published | Should -Match ('"identityClientId":"{0}"' -f $script:clientId)
        $script:published | Should -Not -Match '__DBHUB_SETTINGS__'
        # The schedules: daily, in the configured zone, each linked once to DbHub-Stop with its scope.
        @($script:scheduleBodies | ForEach-Object { '{0} {1} {2} {3} {4}' -f $_.Name, $_.Properties['frequency'], $_.Properties['interval'], $_.Properties['timeZone'], $_.Properties['startTime'] }) | Should -Be @('dbhub-safety-stop Day 1 Pacific Standard Time 2026-11-05T19:00:00-08:00', 'dbhub-safety-t3check Day 1 Pacific Standard Time 2026-11-05T19:30:00-08:00')
        @($script:links | ForEach-Object { '{0} {1} {2}' -f $_.Schedule, $_.Runbook, $_.Parameters['Scope'] }) | Should -Be @('dbhub-safety-stop DbHub-Stop Nightly', 'dbhub-safety-t3check DbHub-Stop T3Check')
        # The role: exactly its actions, then its one assignment at the demo resource group, for a service principal.
        @($script:roleDefinitions[0]['permissions'][0]['actions']) | Should -Be $script:approvedActions
        @($script:roleDefinitions[0]['assignableScopes']) | Should -Be @(('/subscriptions/{0}' -f $script:sub))
        $script:assignments.Count | Should -Be 1
        $script:assignments[0].scope | Should -Be $script:group
        $script:assignments[0].principalId | Should -Be $script:principal
        $script:assignments[0].principalType | Should -Be 'ServicePrincipal'
        $script:assignments[0].roleDefinitionId | Should -Match ('/roleDefinitions/{0}$' -f $script:roleId)
        ($results | Where-Object checkId -EQ 'SAFETYSTOP.SCHEDULE').message | Should -Be 'The nightly safety stop runs DbHub-Stop -Scope Nightly daily at 19:00 and its T3 check, which also stops a running T4, at 19:30 (Pacific Standard Time); it never starts anything.'
        ($script:scheduleBodies | Where-Object Name -EQ 'dbhub-safety-t3check').Properties['description'] | Should -Match 'reads whether T3 paused, through Azure Resource Manager only, and stops T4 when it runs'
    }

    It 'as a Contributor: sets up everything but the role, which is a Warning with the Owner''s one command, and DONE says what still applies' {
        $script:canDefine = $false
        $script:canAssign = $false
        $results = & $script:setup
        @($results | ForEach-Object { '{0}={1}' -f $_.checkId, $_.status }) | Should -Be @('SAFETYSTOP.RESOURCES=Pass', 'SAFETYSTOP.RUNBOOK=Pass', 'SAFETYSTOP.SCHEDULE=Pass', 'SAFETYSTOP.ROLE=Warning')
        $role = $results | Where-Object checkId -EQ 'SAFETYSTOP.ROLE'
        $role.message | Should -Match 'the custom role doesn''t exist yet in this subscription, and creating it needs Microsoft\.Authorization/roleDefinitions/write'
        $role.message | Should -Match 'T4 isn''t stopped after Azure starts it again; the VMs'' nightly auto-shutdown and T3''s auto-pause still apply\.$'
        $role.remediation | Should -Be 'An Owner of the subscription runs, once: ./scripts/grant-safety-stop.ps1 -ConfigPath ./config/demo.config.json'
        @($script:writes | Where-Object { $_ -match 'Microsoft\.Authorization' }) | Should -BeNullOrEmpty
        @($results | Where-Object status -In 'Fail', 'Manual action required') | Should -BeNullOrEmpty -Because 'the deployment is DONE without the role'
        $note = InModuleScope DbHubDemo -Parameters @{ Result = $results } { Get-DemoSafetyStopNote -Result $Result }
        $note | Should -Be 'The nightly safety stop is scheduled, but it can''t stop anything until its role is assigned: an Owner of the subscription runs, once, ./scripts/grant-safety-stop.ps1 -ConfigPath ./config/demo.config.json. Until then T4 isn''t stopped when Azure starts it again after 7 days; the VMs'' nightly auto-shutdown and T3''s auto-pause still apply.'
    }

    It 'as a Role Based Access Control Administrator: assigns the role when it exists, and needs an Owner to create it' {
        $script:canDefine = $false
        $script:roleId = 'eeeeeeee-0000-0000-0000-00000000000e'
        $script:roleActions = $script:approvedActions
        $results = & $script:setup
        ($results | Where-Object checkId -EQ 'SAFETYSTOP.ROLE').status | Should -Be 'Pass'
        $script:assignments.Count | Should -Be 1
        @($script:writes | Where-Object { $_ -match 'roleDefinitions' }) | Should -BeNullOrEmpty
        Reset-FakeAzure
        $script:canDefine = $false
        $missing = (& $script:setup) | Where-Object checkId -EQ 'SAFETYSTOP.ROLE'
        $missing.status | Should -Be 'Warning'
        $missing.message | Should -Match 'an Owner or a User Access Administrator'
        $script:assignments.Count | Should -Be 0
    }

    It 'keeps what''s in place on a rerun: nothing is written but the template''s deployment' {
        Set-FakeInPlace
        $script:linkReads = 0
        $results = & $script:setup
        @($results | ForEach-Object status | Select-Object -Unique) | Should -Be @('Pass')
        $script:deployments.Count | Should -Be 1
        $script:writes | Should -BeNullOrEmpty
        ($results | Where-Object checkId -EQ 'SAFETYSTOP.RUNBOOK').evidence.published | Should -Be 'unchanged'
        @(($results | Where-Object checkId -EQ 'SAFETYSTOP.SCHEDULE').evidence.kept).Count | Should -Be 2
        # The list of job schedules returns no parameters (live, 2026-11-09), so each link's scope is read from the link:
        # before, every run deleted and created both schedules and both links again.
        $script:linkReads | Should -Be 2
    }

    It 'keeps a schedule that''s right when deploy.ps1 runs minutes before its time, so that evening''s run stays' {
        Set-FakeInPlace
        $before = $script:schedules['dbhub-safety-stop'].nextRun
        # 2026-11-06 02:55 UTC is 18:55 Pacific: a schedule created now would first run the next evening.
        $results = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig); Now = [datetime]::new(2026, 11, 6, 2, 55, 0, [System.DateTimeKind]::Utc) } { @(Invoke-DemoSafetyStopSetup -Config $Config -NowUtc $Now -Confirm:$false) }
        ($results | Where-Object checkId -EQ 'SAFETYSTOP.SCHEDULE').status | Should -Be 'Pass'
        $script:writes | Should -BeNullOrEmpty
        $script:schedules['dbhub-safety-stop'].nextRun | Should -Be $before
        $before | Should -Be '2026-11-06T03:00:00.0000000Z'
    }

    It 'creates a schedule again when its link has another scope, read from the link itself' {
        Set-FakeInPlace
        ($script:links | Where-Object Schedule -EQ 'dbhub-safety-stop').Parameters = @{ Scope = 'T4' }
        $results = & $script:setup
        ($results | Where-Object checkId -EQ 'SAFETYSTOP.SCHEDULE').status | Should -Be 'Pass'
        @(($results | Where-Object checkId -EQ 'SAFETYSTOP.SCHEDULE').evidence.kept) | Should -Be @('dbhub-safety-t3check at 19:30')
        @($script:links | ForEach-Object { '{0} {1}' -f $_.Schedule, $_.Parameters['Scope'] } | Sort-Object) | Should -Be @('dbhub-safety-stop Nightly', 'dbhub-safety-t3check T3Check')
        @($script:writes | Where-Object { $_ -match '/schedules/dbhub-safety-t3check$|^delete .*/jobSchedules/' }).Count | Should -Be 1 -Because 'only the stop''s old link is deleted, and the T3 check is kept'
    }

    It 'warns, and changes no schedule, when a link can''t be read by its ID' {
        Set-FakeInPlace
        $script:linkReadFails = $true
        $results = & $script:setup
        $schedule = $results | Where-Object checkId -EQ 'SAFETYSTOP.SCHEDULE'
        $schedule.status | Should -Be 'Warning'
        $schedule.message | Should -Match '^The nightly safety stop''s job schedules couldn''t be read: the job schedule [0-9a-f-]{36} \(dbhub-safety-stop\) couldn''t be read: .*InternalServerError'
        @($script:writes | Where-Object { $_ -match '/(schedules|jobSchedules)/' }) | Should -BeNullOrEmpty
    }

    It 'turns a disabled schedule on again, links a schedule whose link is gone with a new link ID, and moves one whose time changed' {
        Set-FakeInPlace
        $script:schedules['dbhub-safety-stop'].isEnabled = $false
        $script:links = [System.Collections.Generic.List[object]]@($script:links | Where-Object Schedule -NE 'dbhub-safety-t3check')
        $results = & $script:setup
        ($results | Where-Object checkId -EQ 'SAFETYSTOP.SCHEDULE').status | Should -Be 'Pass'
        $script:schedules['dbhub-safety-stop'].isEnabled | Should -BeTrue
        @($script:links | Where-Object Schedule -EQ 'dbhub-safety-t3check').Count | Should -Be 1
        @($script:links | Where-Object Schedule -EQ 'dbhub-safety-stop').Count | Should -Be 1
        $script:scheduleBodies.Clear()
        $script:writes.Clear()
        # A new auto-shutdown time moves both.
        $null = & $script:setup (New-SafetyConfig -Shutdown '2030')
        @($script:scheduleBodies | ForEach-Object { '{0} {1}' -f $_.Name, $_.Properties['startTime'] }) | Should -Be @('dbhub-safety-stop 2026-11-05T20:30:00-08:00', 'dbhub-safety-t3check 2026-11-05T21:00:00-08:00')
    }

    It 'publishes the runbook again when its code or settings changed' {
        Set-FakeInPlace
        $script:published = $script:published.Replace('"t4WaitMinutes":10', '"t4WaitMinutes":5')
        $results = & $script:setup
        ($results | Where-Object checkId -EQ 'SAFETYSTOP.RUNBOOK').evidence.published | Should -Be 'now'
        @($script:writes | Where-Object { $_ -match '/runbooks/DbHub-Stop/publish$' }).Count | Should -Be 1
        $script:published | Should -Match '"t4WaitMinutes":10'
    }

    It 'updates the role when its actions differ and the caller may, and never widens it' {
        Set-FakeInPlace
        $script:roleActions = @($script:approvedActions) + @('Microsoft.Compute/virtualMachines/start/action')
        $results = & $script:setup
        ($results | Where-Object checkId -EQ 'SAFETYSTOP.ROLE').status | Should -Be 'Pass'
        @($script:roleActions) | Should -Be $script:approvedActions
    }

    It 'stops at a template it couldn''t deploy, with a Warning that names the cause, never a Fail' {
        $script:templateFails = $true
        $results = & $script:setup
        @($results | ForEach-Object { '{0}={1}' -f $_.checkId, $_.status }) | Should -Be @('SAFETYSTOP.RESOURCES=Warning')
        $results[0].message | Should -Match 'RequestDisallowedByPolicy'
        $results[0].remediation | Should -Match 'VMs'' nightly auto-shutdown and T3''s auto-pause still apply'
        $script:writes | Should -BeNullOrEmpty
        $note = InModuleScope DbHubDemo -Parameters @{ Result = $results } { Get-DemoSafetyStopNote -Result $Result }
        $note | Should -Match '^The nightly safety stop isn''t fully set up \(SAFETYSTOP\.RESOURCES\): .*RequestDisallowedByPolicy.* Until it is, T4 isn''t stopped when Azure starts it again after 7 days'
    }

    It 'changes nothing with -WhatIf' {
        $results = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig); Now = $script:now } { @(Invoke-DemoSafetyStopSetup -Config $Config -NowUtc $Now -WhatIf) }
        @($results | ForEach-Object { '{0}={1}' -f $_.checkId, $_.status }) | Should -Be @('SAFETYSTOP.RESOURCES=Not selected')
        $script:deployments | Should -BeNullOrEmpty
        $script:writes | Should -BeNullOrEmpty
    }

    It '-GrantRole (the Owner''s command) runs the subscription guard first, then only creates and assigns the role' {
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'Signed in.' }
        $results = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { @(Invoke-DemoSafetyStopSetup -Config $Config -GrantRole -Confirm:$false) }
        @($results | ForEach-Object { '{0}={1}' -f $_.checkId, $_.status }) | Should -Be @('PREFLIGHT.GUARD.CONTEXT=Pass', 'SAFETYSTOP.ROLE=Pass')
        $script:deployments | Should -BeNullOrEmpty
        @($script:writes | Where-Object { $_ -notmatch 'Microsoft\.Authorization/(roleDefinitions|roleAssignments)/' }) | Should -BeNullOrEmpty
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { throw 'The Azure CLI isn''t signed in to the configured tenant.' }
        $refused = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { @(Invoke-DemoSafetyStopSetup -Config $Config -GrantRole -Confirm:$false) }
        @($refused | ForEach-Object { '{0}={1}' -f $_.checkId, $_.status }) | Should -Be @('PREFLIGHT.GUARD.CONTEXT=Fail')
    }

    It 'says the identity is missing when -GrantRole comes before deploy.ps1 made it' {
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'Signed in.' }
        $script:identityExists = $false
        $role = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { @(Invoke-DemoSafetyStopSetup -Config $Config -GrantRole -Confirm:$false) } | Where-Object checkId -EQ 'SAFETYSTOP.ROLE'
        $role.status | Should -Be 'Warning'
        $role.message | Should -Match 'the identity id-dbhub-demo-safetystop doesn''t exist yet'
        $role.remediation | Should -Match '^Run \./scripts/deploy\.ps1'
    }
}

Describe 'The nightly safety stop''s state, runs, and status (ADR 0024)' {
    BeforeEach {
        Reset-FakeAzure
        Register-FakeAzure
        Initialize-GuardTestContext
        $script:state = { InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { Get-DemoSafetyStopState -Config $Config } }
        $script:status = { InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig); Now = $script:now } { Get-DemoSafetyStopStatus -Config $Config -NowUtc $Now } }
    }

    It 'reads <State> when <Case>' -ForEach @(
        @{ Case = 'everything is in place'; Setup = { Set-FakeInPlace }; State = 'InPlace'; Missing = '' }
        @{ Case = 'nothing is set up'; Setup = { }; State = 'NotScheduled'; Missing = 'the schedule dbhub-safety-stop doesn''t exist' }
        @{ Case = 'the stop schedule is disabled'; Setup = { Set-FakeInPlace; $script:schedules['dbhub-safety-stop'].isEnabled = $false }; State = 'NotScheduled'; Missing = 'is disabled' }
        @{ Case = 'the stop schedule isn''t linked with Scope Nightly'; Setup = { Set-FakeInPlace; foreach ($link in $script:links) { $link.Parameters = @{ Scope = 'T4' } } }; State = 'NotScheduled'; Missing = 'isn''t linked to DbHub-Stop -Scope Nightly' }
        @{ Case = 'the role isn''t assigned'; Setup = { Set-FakeInPlace; $script:assignments.Clear() }; State = 'NoRole'; Missing = 'id-dbhub-demo-safetystop doesn''t hold "DbHub Demo Safety Stop" at rg-dbhub-demo' }
        @{ Case = 'the role doesn''t exist'; Setup = { Set-FakeInPlace; $script:roleId = '' }; State = 'NoRole'; Missing = 'the custom role "DbHub Demo Safety Stop" doesn''t exist' }
        @{ Case = 'the role definitions can''t be read'; Setup = { Set-FakeInPlace; $script:roleReadFails = $true }; State = 'Unknown'; Missing = '' }
        @{ Case = 'a link can''t be read by its ID'; Setup = { Set-FakeInPlace; $script:linkReadFails = $true }; State = 'Unknown'; Missing = '' }
    ) {
        & $Setup
        $script:linkReads = 0
        $read = & $script:state
        $read.State | Should -Be $State
        $read.Missing | Should -Match ([regex]::Escape($Missing))
        if ($State -eq 'InPlace') {
            $read.RoleAssigned | Should -BeTrue
            $read.CheckScheduled | Should -BeTrue
            $read.NextRunUtc | Should -Be ([datetime]::new(2026, 11, 6, 3, 0, 0, [System.DateTimeKind]::Utc))
            # The list of job schedules returns no parameters (live, 2026-11-09): each link is read once by its ID.
            $script:linkReads | Should -Be 2
        }
        if ($Case -match 'by its ID') {
            $read.Error | Should -Match 'the job schedule [0-9a-f-]{36} \(dbhub-safety-stop\) couldn''t be read'
        }
    }

    It 'reads the scheduled runs, whose jobs are named SCH_ with two GUIDs and a time, by their job IDs (live, 2026-11-09)' {
        Set-FakeInPlace
        $stopId = 'bbbbbbbb-0000-0000-0000-000000000001'
        $checkId = 'bbbbbbbb-0000-0000-0000-000000000002'
        Add-FakeJob -Id $stopId -JobName 'SCH_cccccccc-0000-0000-0000-000000000001_dddddddd-0000-0000-0000-000000000001_639297810000000000' -Status 'Completed' -Created '2026-11-09T00:00:12Z' -Result @{ action = 'stop-nightly'; status = 'Stopped'; message = 'Nightly safety stop: sqlvm01 already deallocated, archost01 already deallocated, T4 already stopped.' }
        Add-FakeJob -Id $checkId -JobName 'SCH_cccccccc-0000-0000-0000-000000000002_dddddddd-0000-0000-0000-000000000001_639297828000000000' -Status 'Completed' -Created '2026-11-09T00:30:09Z' -Result @{ action = 'check-t3'; status = 'Checked'; t3 = 'Paused'; t4 = 'T4 already stopped'; failed = @(); message = 'T3 (azuresql01-abc123/ContosoCare) is Paused, 30 minutes after the safety stop: it bills no compute until something connects. T4 already stopped.' }
        $status = & $script:status
        $status.status | Should -Be 'Pass'
        $status.message | Should -Not -Match 'hasn''t run yet'
        $status.message | Should -Match 'Last run 2026-11-09 00:00 UTC \(job Completed\): Nightly safety stop: sqlvm01 already deallocated, archost01 already deallocated, T4 already stopped\. T3 check 2026-11-09 00:30 UTC: .* T4 already stopped\.$'
        $status.evidence.lastStopJobId | Should -Be $stopId
        $status.evidence.lastT3CheckJobId | Should -Be $checkId
        @($script:outputKeys) | Should -Be @($checkId, $stopId) -Because 'each output is read by its job''s ID, newest first, never by a schedule''s job name'
    }

    It 'reads a job whose name isn''t its ID by its ID, and a name only for a job without an ID, when it''s a GUID or a schedule''s job name' {
        Set-FakeInPlace
        # Started by name (PUT jobs/{name}): its ID differs from its name (live, 2026-11-09).
        Add-FakeJob -Id 'dddddddd-0000-0000-0000-000000000002' -JobName 'eeeeeeee-0000-0000-0000-000000000001' -Status 'Completed' -Created '2026-11-09T14:40:00Z' -Result @{ action = 'check-t3'; status = 'Checked'; t3 = 'Paused'; t4 = 'T4 already stopped'; failed = @(); message = 'T3 is Paused. T4 already stopped.' }
        # Without an ID: its name, a schedule's job name.
        $scheduled = 'SCH_cccccccc-0000-0000-0000-000000000001_dddddddd-0000-0000-0000-000000000001_639297810000000000'
        Add-FakeJob -Id 'dddddddd-0000-0000-0000-000000000003' -JobName $scheduled -NoJobId -Status 'Completed' -Created '2026-11-09T00:00:12Z' -Result @{ action = 'stop-nightly'; status = 'Stopped'; message = 'Nightly safety stop: T4 already stopped.' }
        # Never read: an ID that isn't a GUID (no fallback to its name), and, without an ID, a name of another form.
        Add-FakeJob -Id 'not-a-guid' -JobName 'ffffffff-0000-0000-0000-000000000001' -Status 'Completed' -Created '2026-11-09T14:50:00Z' -Result @{ action = 'stop-nightly'; status = 'Stopped'; message = 'never read' }
        Add-FakeJob -Id 'ffffffff-0000-0000-0000-000000000002' -JobName 'job/../other' -NoJobId -Status 'Completed' -Created '2026-11-09T14:55:00Z' -Result @{ action = 'stop-nightly'; status = 'Stopped'; message = 'never read' }
        $runs = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { Get-DemoSafetyStopLastRun -Name (Get-DemoSafetyStopName -Config $Config) }
        $runs.Ok | Should -BeTrue
        $runs.Check.JobId | Should -Be 'dddddddd-0000-0000-0000-000000000002'
        $runs.Check.Name | Should -Be 'eeeeeeee-0000-0000-0000-000000000001'
        $runs.Stop.JobId | Should -Be $scheduled
        $runs.Stop.Result['message'] | Should -Be 'Nightly safety stop: T4 already stopped.'
        @($script:outputKeys) | Should -Be @('dddddddd-0000-0000-0000-000000000002', $scheduled)
    }

    It 'counts a job that failed before its result line as the run its own Scope names (Job - Get): <Case>' -ForEach @(
        @{ Case = 'the T3 check'; Scope = 'T3Check'; ReadFails = $false; Match = 'Last run 2026-11-09 00:00 UTC \(job Completed\): Nightly safety stop: T4 already stopped\. T3 check 2026-11-09 00:30 UTC: its output had no result line\. To check: its last T3 check didn''t read T3\.$' }
        @{ Case = 'the stop'; Scope = 'Nightly'; ReadFails = $false; Match = 'Last run 2026-11-09 00:30 UTC \(job Failed\): its output had no result line\. To check: its last run didn''t finish its work\.$' }
        @{ Case = 'one whose parameters can''t be read, taken as the stop'; Scope = 'T3Check'; ReadFails = $true; Match = 'Last run 2026-11-09 00:30 UTC \(job Failed\): its output had no result line\. To check: its last run didn''t finish its work\.$' }
    ) {
        Set-FakeInPlace
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000011' -JobName 'SCH_cccccccc-0000-0000-0000-000000000001_dddddddd-0000-0000-0000-000000000001_639297810000000000' -Status 'Completed' -Created '2026-11-09T00:00:12Z' -Result @{ action = 'stop-nightly'; status = 'Stopped'; message = 'Nightly safety stop: T4 already stopped.' }
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000012' -JobName 'SCH_cccccccc-0000-0000-0000-000000000002_dddddddd-0000-0000-0000-000000000001_639297828000000000' -Status 'Failed' -Created '2026-11-09T00:30:09Z' -Result $null -Scope $Scope
        $script:jobReadFails = $ReadFails
        $status = & $script:status
        $status.status | Should -Be 'Warning'
        $status.message | Should -Match $Match
        @($script:jobReads) | Should -Be @('aaaaaaaa-0000-0000-0000-000000000012') -Because 'only a job without its result line is read again, by its ID'
    }

    It 'lets the cost estimate count about a day per restart after a scheduled stop that completed, and not after one that failed' {
        Set-FakeInPlace
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000021' -JobName 'SCH_cccccccc-0000-0000-0000-000000000001_dddddddd-0000-0000-0000-000000000001_639296946000000000' -Status 'Completed' -Created '2026-11-08T00:00:12Z' -Result @{ action = 'stop-nightly'; status = 'Stopped'; message = 'Nightly safety stop: T4 already stopped.' }
        $coverage = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { Get-DemoT4RestartCoverage -Config $Config }
        $coverage.Counts | Should -BeTrue
        $coverage.Reason | Should -Match 'its last run didn''t fail$'
        $coverage.Evidence['nightlyLastRun'] | Should -Be 'Completed (Stopped)'
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000022' -JobName 'SCH_cccccccc-0000-0000-0000-000000000001_dddddddd-0000-0000-0000-000000000001_639297810000000000' -Status 'Failed' -Created '2026-11-09T00:00:12Z' -Result @{ action = 'stop-nightly'; status = 'Partial'; message = 'Nightly safety stop: sqlvm01 already deallocated, archost01 already deallocated; failed: T4 (HTTP 409).' }
        $failed = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { Get-DemoT4RestartCoverage -Config $Config }
        $failed.Counts | Should -BeFalse
        $failed.Missing | Should -Be 'StopJob'
        $failed.Reason | Should -Match 'didn''t finish its work \(job Failed\)'
    }

    It 'finds the newest stop and T3 check by their result lines, reading as few outputs as it can' {
        Set-FakeInPlace
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000001' -Status 'Completed' -Created '2026-11-04T03:00:05Z' -Result @{ action = 'stop-nightly'; status = 'Stopped'; message = 'Nightly safety stop: old.' }
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000002' -Status 'Completed' -Created '2026-11-05T03:00:05Z' -Result @{ action = 'stop-nightly'; status = 'Stopped'; message = 'Nightly safety stop: sqlvm01 deallocated (was running), archost01 already deallocated, T4 stopped (was Ready).' }
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000003' -Status 'Completed' -Created '2026-11-05T03:30:05Z' -Result @{ action = 'check-t3'; status = 'Checked'; t3 = 'Paused'; message = 'T3 (azuresql01-abc123/ContosoCare) is Paused, 30 minutes after the safety stop: it bills no compute until something connects.' }
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000004' -Status 'Running' -Created '2026-11-05T18:00:00Z' -Result $null
        $runs = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { Get-DemoSafetyStopLastRun -Name (Get-DemoSafetyStopName -Config $Config) }
        $runs.Ok | Should -BeTrue
        $runs.Stop.JobId | Should -Be 'aaaaaaaa-0000-0000-0000-000000000002'
        $runs.Check.JobId | Should -Be 'aaaaaaaa-0000-0000-0000-000000000003'
        $runs.Check.Result['t3'] | Should -Be 'Paused'
        $script:outputReads | Should -Be 2 -Because 'the running job isn''t read, and the older stop isn''t needed'
        $status = & $script:status
        $status.checkId | Should -Be 'STATUS.SAFETYSTOP'
        $status.status | Should -Be 'Pass'
        $status.message | Should -Be 'The nightly safety stop runs at 19:00, and its T3 check, which also stops a running T4, at 19:30 (Pacific Standard Time) (next 2026-11-06 03:00 UTC). Last run 2026-11-05 03:00 UTC (job Completed): Nightly safety stop: sqlvm01 deallocated (was running), archost01 already deallocated, T4 stopped (was Ready). T3 check 2026-11-05 03:30 UTC: T3 (azuresql01-abc123/ContosoCare) is Paused, 30 minutes after the safety stop: it bills no compute until something connects.'
    }

    It 'shows what the T3 check did to T4, and warns when it couldn''t stop it (2026-11-09)' {
        Set-FakeInPlace
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000002' -Status 'Completed' -Created '2026-11-05T03:00:05Z' -Result @{ action = 'stop-nightly'; status = 'Stopped'; message = 'Nightly safety stop: sqlvm01 already deallocated, archost01 already deallocated, T4 already stopped.' }
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000003' -Status 'Completed' -Created '2026-11-05T03:30:05Z' -Result @{ action = 'check-t3'; status = 'Checked'; t3 = 'Paused'; t4 = 'T4 stopped (was Ready)'; failed = @(); message = 'T3 (azuresql01-abc123/ContosoCare) is Paused, 30 minutes after the safety stop: it bills no compute until something connects. T4 stopped (was Ready).' }
        $status = & $script:status
        $status.status | Should -Be 'Pass'
        $status.message | Should -Match 'T3 check 2026-11-05 03:30 UTC: T3 \(azuresql01-abc123/ContosoCare\) is Paused, 30 minutes after the safety stop: it bills no compute until something connects\. T4 stopped \(was Ready\)\.$'
        $script:jobs = @()
        $script:outputs = @{}
        Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000005' -Status 'Failed' -Created '2026-11-05T03:30:05Z' -Result @{ action = 'check-t3'; status = 'Partial'; t3 = 'Paused'; t4 = 'failed: it was still Starting after 10 minutes; tomorrow''s safety stop tries again'; failed = @('T4 (it was still Starting after 10 minutes; tomorrow''s safety stop tries again)'); message = 'T3 (azuresql01-abc123/ContosoCare) is Paused, 30 minutes after the safety stop: it bills no compute until something connects. T4 couldn''t be stopped: it was still Starting after 10 minutes; tomorrow''s safety stop tries again.' }
        $warned = & $script:status
        $warned.status | Should -Be 'Warning'
        $warned.message | Should -Match 'To check: its last T3 check couldn''t stop T4\.$'
        $warned.message | Should -Not -Match 'didn''t read T3'
        $warned.remediation | Should -Match 'Process Automation > Jobs'
    }

    It 'warns, with the fix, when <Case>' -ForEach @(
        @{ Case = 'it isn''t set up'; Setup = { }; Match = '^The nightly safety stop isn''t in place \(the schedule dbhub-safety-stop doesn''t exist\), so only the VMs'' own auto-shutdown stops them at 19:00, and nothing stops T4'; Fix = '^Run \./scripts/deploy\.ps1' }
        @{ Case = 'its role isn''t assigned'; Setup = { Set-FakeInPlace; $script:assignments.Clear() }; Match = 'but it can''t stop anything: id-dbhub-demo-safetystop doesn''t hold .* So T4 isn''t stopped when Azure starts it again after 7 days; the VMs'' nightly auto-shutdown and T3''s auto-pause still apply\.$'; Fix = '^An Owner of the subscription runs, once: \./scripts/grant-safety-stop\.ps1 -ConfigPath \./config/demo\.config\.json$' }
        @{ Case = 'its last run didn''t finish'; Setup = { Set-FakeInPlace; Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000002' -Status 'Failed' -Created '2026-11-05T03:00:05Z' -Result @{ action = 'stop-nightly'; status = 'Partial'; message = 'Nightly safety stop: archost01 already deallocated; failed: sqlvm01 (HTTP 409).' } }; Match = 'Last run 2026-11-05 03:00 UTC \(job Failed\): Nightly safety stop: archost01 already deallocated; failed: sqlvm01 \(HTTP 409\)\. To check: its last run didn''t finish its work\.$'; Fix = 'Process Automation > Jobs' }
        @{ Case = 'T3 stayed online past its delay'; Setup = { Set-FakeInPlace; Add-FakeJob -Id 'aaaaaaaa-0000-0000-0000-000000000003' -Status 'Completed' -Created '2026-11-05T03:30:05Z' -Result @{ action = 'check-t3'; status = 'Checked'; t3 = 'Awake'; message = 'T3 is Online, 30 minutes after the safety stop, past its 15-minute auto-pause delay: a session or a feature keeps it awake.' } }; Match = 'It hasn''t run yet\. T3 check 2026-11-05 03:30 UTC: .* To check: T3 was still online past its auto-pause delay\.$'; Fix = 'Resume Databases events' }
        @{ Case = 'its runs can''t be read'; Setup = { Set-FakeInPlace; $script:jobsReadFails = $true }; Match = 'To check: its runs couldn''t be read \(.*AuthorizationFailed.*\)\.$'; Fix = 'Process Automation > Jobs' }
    ) {
        & $Setup
        $status = & $script:status
        $status.status | Should -Be 'Warning'
        $status.message | Should -Match $Match
        $status.remediation | Should -Match $Fix
    }

    It 'is COST.SAFETYSTOP in validate.ps1''s Cost area' {
        Set-FakeInPlace
        $cost = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig); Now = $script:now } { Get-DemoSafetyStopStatus -Config $Config -NowUtc $Now -CheckId 'COST.SAFETYSTOP' -Area 'cost' }
        $cost.checkId | Should -Be 'COST.SAFETYSTOP'
        $cost.area | Should -Be 'cost'
        $cost.status | Should -Be 'Pass'
    }
}

Describe 'What stops T4 after its 7-day restart, and DONE (ADR 0024)' {
    It 'is <Expected> when the nightly safety stop is <Nightly> and the control''s is <Control>' -ForEach @(
        @{ Nightly = 'InPlace'; Control = 'Off'; Expected = 'Nightly' }
        @{ Nightly = 'InPlace'; Control = 'Scheduled'; Expected = 'Nightly' }
        @{ Nightly = 'NotScheduled'; Control = 'Scheduled'; Expected = 'Scheduled' }
        @{ Nightly = 'NoRole'; Control = 'Scheduled'; Expected = 'Scheduled' }
        @{ Nightly = 'NoRole'; Control = 'Off'; Expected = 'NoRole' }
        @{ Nightly = 'Unknown'; Control = 'Off'; Expected = 'Unknown' }
        @{ Nightly = 'NotScheduled'; Control = 'Unknown'; Expected = 'Unknown' }
        @{ Nightly = 'NotScheduled'; Control = 'Off'; Expected = 'NotScheduled' }
    ) {
        $script:nightlyState = $Nightly
        $script:controlState = $Control
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSafetyStopState -MockWith { [pscustomobject]@{ State = $script:nightlyState; NextRunUtc = $null; CheckNextRunUtc = $null; CheckScheduled = $true; RoleAssigned = $null; Missing = ''; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4SafetyStopState -MockWith { [pscustomobject]@{ State = $script:controlState; NextRunUtc = $null } }
        $restart = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { Get-DemoT4RestartStopState -Config $Config }
        $restart.State | Should -Be $Expected
        # Only the nightly safety stop's T3 check stops T4 too (2026-11-09).
        $restart.CheckStopsT4 | Should -Be ($Expected -eq 'Nightly')
    }

    It 'says the T3 check doesn''t stop T4 when the check isn''t scheduled' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSafetyStopState -MockWith { [pscustomobject]@{ State = 'InPlace'; NextRunUtc = $null; CheckNextRunUtc = $null; CheckScheduled = $false; RoleAssigned = $true; Missing = ''; Error = '' } }
        $restart = InModuleScope DbHubDemo -Parameters @{ Config = (New-SafetyConfig) } { Get-DemoT4RestartStopState -Config $Config }
        $restart.State | Should -Be 'Nightly'
        $restart.CheckStopsT4 | Should -BeFalse
    }

    It 'finds the first run that stops a T4 restarted at <Restart> UTC: <Run> at <Utc> UTC (<Case>)' -ForEach @(
        # The live case: the stop of 2026-11-07 00:01Z ended at 00:03Z, so Azure starts T4 again 3 minutes after the stop
        # of 2026-11-13 19:00 Eastern; the T3 check stops it that evening.
        @{ Case = 'just after the stop'; Zone = 'Eastern Standard Time'; AutoPause = 15; WithCheck = $true; Restart = '2026-11-14T00:03:00Z'; Run = 'Check'; Utc = '2026-11-14T00:30' }
        # The T3 check's own stop ends just after its time, so the next restart comes after it: the next evening's stop.
        @{ Case = 'just after the T3 check'; Zone = 'Eastern Standard Time'; AutoPause = 15; WithCheck = $true; Restart = '2026-11-14T00:33:00Z'; Run = 'Stop'; Utc = '2026-11-15T00:00' }
        @{ Case = 'without the T3 check'; Zone = 'Eastern Standard Time'; AutoPause = 15; WithCheck = $false; Restart = '2026-11-14T00:03:00Z'; Run = 'Stop'; Utc = '2026-11-15T00:00' }
        @{ Case = 'during the day'; Zone = 'Pacific Standard Time'; AutoPause = 15; WithCheck = $true; Restart = '2026-11-05T18:00:00Z'; Run = 'Stop'; Utc = '2026-11-06T03:00' }
        @{ Case = 'at the stop''s very minute'; Zone = 'Pacific Standard Time'; AutoPause = 15; WithCheck = $true; Restart = '2026-11-06T03:00:00Z'; Run = 'Stop'; Utc = '2026-11-06T03:00' }
        @{ Case = 'a T3 check after midnight'; Zone = 'Pacific Standard Time'; AutoPause = 1440; WithCheck = $true; Restart = '2026-11-06T03:10:00Z'; Run = 'Check'; Utc = '2026-11-06T08:45' }
        # Daylight saving time starts on 2026-03-08 in the US: 19:00 Eastern is 00:00 UTC before it and 23:00 UTC after.
        @{ Case = 'across daylight saving time'; Zone = 'Eastern Standard Time'; AutoPause = 15; WithCheck = $true; Restart = '2026-03-08T12:00:00Z'; Run = 'Stop'; Utc = '2026-03-08T23:00' }
    ) {
        $config = New-SafetyConfig -Zone $Zone -AutoPause $AutoPause
        $after = [datetime]::Parse($Restart, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $found = InModuleScope DbHubDemo -Parameters @{ Config = $config; After = $after; WithCheck = $WithCheck } { Get-DemoSafetyStopRunAfter -Config $Config -AfterUtc $After -WithCheck:$WithCheck }
        $found.Run | Should -Be $Run
        $found.Utc.ToString('yyyy-MM-ddTHH:mm', [System.Globalization.CultureInfo]::InvariantCulture) | Should -Be $Utc
        $found.Utc.Kind | Should -Be ([System.DateTimeKind]::Utc)
        $found.TimeZone | Should -Be $Zone
    }

    It 'adds no note to DONE when the safety stop is in place, and keeps a run with only its role missing DONE, with the note' {
        # T4 is part of every deployment (2026-11-09), so DONE needs it too.
        $config = New-SafetyConfig
        $config['t4Enabled'] = $true
        $ids = InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'PaygWizard' }
        $done = @(foreach ($id in $ids) { New-TestResult $id }) + @((New-TestResult 'SAFETYSTOP.RESOURCES'), (New-TestResult 'SAFETYSTOP.ROLE'))
        $state = [pscustomobject]@{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = 'Telemetry'; TrackFabric = 'Fabric'; T4Sku = ''; GuidedStopUtc = ''; HostPasswordUtc = '' }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $done; State = $state; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        @($outcome.Notes | Where-Object { $_ -match 'safety stop' }) | Should -BeNullOrEmpty
        $role = New-DemoResult -CheckId 'SAFETYSTOP.ROLE' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message 'The role isn''t assigned.' -Evidence ([ordered]@{ command = './scripts/grant-safety-stop.ps1 -ConfigPath ./config/demo.config.json' })
        $warned = @($done | Where-Object checkId -NE 'SAFETYSTOP.ROLE') + @($role)
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $warned; State = $state; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done' -Because 'a Warning never keeps the deployment from DONE'
        $outcome.ExitCode | Should -Be 0
        $lines = (InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) -join ' '
        $lines | Should -Match 'The nightly safety stop is scheduled, but it can''t stop anything until its role is assigned: an Owner of the subscription runs, once, \./scripts/grant-safety-stop\.ps1 -ConfigPath \./config/demo\.config\.json\. Until then T4 isn''t stopped when Azure starts it again after 7 days; the VMs'' nightly auto-shutdown and T3''s auto-pause still apply\.'
    }
}

Describe 'scripts/grant-safety-stop.ps1, the Owner''s one command' {
    It 'runs Invoke-DemoSafetyStopSetup -GrantRole with the configuration, writes its results, and exits 0 on a Warning' {
        $configPath = Join-Path -Path $TestDrive -ChildPath 'demo.config.json'
        Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Destination $configPath
        $outputPath = Join-Path -Path $TestDrive -ChildPath 'grant.jsonl'
        Mock -CommandName Invoke-DemoSafetyStopSetup -MockWith { New-DemoResult -CheckId 'SAFETYSTOP.ROLE' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message 'You can''t create role assignments.' }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/grant-safety-stop.ps1') -ConfigPath $configPath -OutputPath $outputPath
        $LASTEXITCODE | Should -Be 0
        Should -Invoke -CommandName Invoke-DemoSafetyStopSetup -Times 1 -ParameterFilter { $GrantRole -and $ConfigPath -eq $configPath }
        (Get-Content -LiteralPath $outputPath -Raw) | Should -Match 'SAFETYSTOP\.ROLE'
    }
}
