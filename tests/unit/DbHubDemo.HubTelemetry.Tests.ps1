BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    $schemaPath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/schemas/validation-result.schema.json'

    function Get-SummaryEntry([string] $Target, [int] $Rows = 120, [double] $LastMinutesAgo = 2.5) {
        $map = @{
            T1 = @{ Id = $script:HubT1Id; Type = 'virtualMachines'; Name = 'sqlvm01' }
            T2 = @{ Id = $script:HubT2Id; Type = 'machines'; Name = 'arcsql01' }
            T3 = @{ Id = $script:HubT3Id; Type = 'servers/databases'; Name = 'azuresql01-abc123/ContosoCare' }
        }
        $entry = $map[$Target].Clone()
        $entry['Rows'] = $Rows
        $entry['First'] = $script:HubNow.AddMinutes(-55)
        $entry['Last'] = $script:HubNow.AddMinutes(-$LastMinutesAgo)
        return $entry
    }

    function Set-SummaryResponse([object[]] $Entry, [int] $StatusCode = 200, [string] $Json = '') {
        $script:summaryJson = if ($StatusCode -eq 200 -and -not $Json) { ConvertTo-HubSummaryJson -Entry $Entry } else { $Json }
        $script:summaryStatus = $StatusCode
        Initialize-HubHttpMock -Handler {
            $Csl = $script:HubRequest.Csl
            if ($Csl -match 'SqlServerCPUUtilization') {
                return ConvertTo-HubHttpResponse -StatusCode $script:summaryStatus -Json $script:summaryJson
            }
            if ($Csl -match 'union withsource') {
                $rows = [System.Collections.Generic.List[object]]::new()
                $rows.Add([object[]]@($script:HubT1Id, 'SqlServerWaitStats', 900, '2026-10-20T11:59:00Z'))
                return ConvertTo-HubHttpResponse -Json (ConvertTo-HubKustoJson -Column 'ResourceID', 'TableName', 'Rows', 'LastSampleUTC' -Type 'string', 'string', 'long', 'datetime' -Row $rows)
            }
            if ($Csl -match 'SqlServerWaitStats') {
                $rows = [System.Collections.Generic.List[object]]::new()
                $rows.Add([object[]]@($script:HubT1Id, 'MSSQLSERVER', 'Lock', 81000, 12, 81.0))
                return ConvertTo-HubHttpResponse -Json (ConvertTo-HubKustoJson -Column 'ResourceID', 'SqlServerInstanceName', 'WaitCategory', 'WaitMs', 'Tasks', 'WaitSeconds' -Type 'string', 'string', 'string', 'long', 'long', 'real' -Row $rows)
            }
            if ($Csl -match '65792') {
                $rows = [System.Collections.Generic.List[object]]::new()
                $rows.Add([object[]]@($script:HubT1Id, 'MSSQLSERVER', 'Processes blocked', 65792, 0.4, 0.0, 3.0, '2026-10-20T11:59:00Z'))
                return ConvertTo-HubHttpResponse -Json (ConvertTo-HubKustoJson -Column 'ResourceID', 'SqlServerInstanceName', 'CounterName', 'CounterType', 'AvgValue', 'MinValue', 'MaxValue', 'LastSampleUTC' -Type 'string', 'string', 'string', 'int', 'real', 'real', 'real', 'datetime' -Row $rows)
            }
            $rows = [System.Collections.Generic.List[object]]::new()
            $rows.Add([object[]]@($script:HubT1Id, 'MSSQLSERVER', 'Number of Deadlocks/sec', 2.0, 1800, 0.001))
            ConvertTo-HubHttpResponse -Json (ConvertTo-HubKustoJson -Column 'ResourceID', 'SqlServerInstanceName', 'CounterName', 'TotalEvents', 'ElapsedSec', 'PerSecond' -Type 'string', 'string', 'string', 'real', 'long', 'real' -Row $rows)
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Test-DemoHubTelemetry' {
    BeforeEach {
        Clear-DemoSecret
        $script:token = Get-HubFakeToken
        $config = Get-HubTestConfig
        Initialize-HubAzMock -Token $script:token
        Mock -ModuleName DbHubDemo -CommandName Get-DemoHubUtcNow -MockWith { [datetime]::new(2026, 10, 20, 12, 0, 0, [System.DateTimeKind]::Utc) }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
    }

    It 'passes for every target with fresh rows, with the row count, newest sample, and lag' {
        Set-SummaryResponse -Entry @((Get-SummaryEntry T1), (Get-SummaryEntry T2 -Rows 60 -LastMinutesAgo 4), (Get-SummaryEntry T3 -Rows 30 -LastMinutesAgo 1))
        $results = @(Test-DemoHubTelemetry -Config $config)
        $results.Count | Should -Be 3
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('TELEMETRY.T1', 'TELEMETRY.T2', 'TELEMETRY.T3')
        $results | ForEach-Object { $_.status | Should -Be 'Pass'; $_.area | Should -Be 'hub' }
        $results[0].evidence.rows | Should -Be 120
        $results[0].evidence.lagMinutes | Should -Be 2.5
        ([datetime]$results[0].evidence.lastSampleUtc).ToUniversalTime() | Should -Be ([datetime]::new(2026, 10, 20, 11, 57, 30, [System.DateTimeKind]::Utc))
        $results[0].evidence.resourceId | Should -Be $script:HubT1Id
        $results[1].evidence.lagMinutes | Should -Be 4
        $results[2].evidence.resourceId | Should -Be $script:HubT3Id
        $results[0].message | Should -Match '120 CPU samples in the last 60 minutes'
        foreach ($result in $results) {
            Test-Json -Json ($result | ConvertTo-Json -Depth 8) -SchemaFile $schemaPath | Should -BeTrue
        }
        # One query for all three targets, keyed by ResourceID, with the documented time filter first.
        $script:HubHttpCalls.Count | Should -Be 1
        $script:HubHttpCalls[0].Csl | Should -Match ([regex]::Escape($script:HubT3Id))
    }

    It 'warns when the newest sample is older than FreshMinutes' {
        Set-SummaryResponse -Entry @((Get-SummaryEntry T1 -LastMinutesAgo 48.2))
        $result = @(Test-DemoHubTelemetry -Config $config -Target T1)[0]
        $result.status | Should -Be 'Warning'
        $result.evidence.lagMinutes | Should -Be 48.2
        $result.message | Should -Match '48\.2 minutes old'
        $result.remediation | Should -Match 'start-demo\.ps1'
    }

    It 'fails a target without rows, with the documented causes for that target' {
        Set-SummaryResponse -Entry @((Get-SummaryEntry T1))
        $results = @(Test-DemoHubTelemetry -Config $config)
        $results[0].status | Should -Be 'Pass'
        $results[1].status | Should -Be 'Fail'
        $results[1].remediation | Should -Match 'configure-arc\.ps1'
        $results[1].remediation | Should -Match '\*\.westus3\.arcdataservices\.com'
        $results[2].status | Should -Be 'Fail'
        $results[2].remediation | Should -Match 'MS_EnablePerformanceMonitoringPreview'
        $results[2].remediation | Should -Match 'Reader'
        $results[2].remediation | Should -Match 'Microsoft\.Sql'
        $results[2].evidence.rows | Should -Be 0
    }

    It 'warns when a target''s telemetry arrives under a different ResourceID' {
        $entry = Get-SummaryEntry T1
        $entry['Id'] = $script:HubT1Id.Replace('/providers/Microsoft.Compute/', '/providers/Microsoft.SqlVirtualMachine/')
        Set-SummaryResponse -Entry @($entry)
        $result = @(Test-DemoHubTelemetry -Config $config -Target T1)[0]
        $result.status | Should -Be 'Warning'
        $result.evidence.telemetryResourceId | Should -Match 'Microsoft.SqlVirtualMachine'
    }

    It 'reports targets outside -Target as Not selected and doesn''t read the T3 tag then' {
        Set-SummaryResponse -Entry @((Get-SummaryEntry T1))
        $results = @(Test-DemoHubTelemetry -Config $config -Target T1)
        $results[1].status | Should -Be 'Not selected'
        $results[2].status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'group' }
    }

    It 'reports T2 as Not supported in Developer mode and labels the evaluation-only mode' {
        Set-SummaryResponse -Entry @((Get-SummaryEntry T1), (Get-SummaryEntry T3))
        $config['t2SqlInstallMode'] = 'Developer'
        @(Test-DemoHubTelemetry -Config $config)[1].status | Should -Be 'Not supported'

        $config['t2SqlInstallMode'] = 'ProductKey'
        $config['t2Mode'] = 'EvaluationOnlyAzureVm'
        Set-SummaryResponse -Entry @((Get-SummaryEntry T2))
        $t2 = @(Test-DemoHubTelemetry -Config $config -Target T2)[1]
        $t2.status | Should -Be 'Pass'
        $t2.evaluationOnly | Should -BeTrue
        $t2.message | Should -BeLike 'EVALUATION ONLY:*'
    }

    It 'maps endpoint errors to statuses: 403 Fail, 400 Manual action required' {
        Set-SummaryResponse -StatusCode 403 -Json '{"error":{"code":"Forbidden","message":"denied"}}'
        $denied = @(Test-DemoHubTelemetry -Config $config -Target T1, T3)
        $denied[0].status | Should -Be 'Fail'
        $denied[0].remediation | Should -Match 'az provider register --namespace Microsoft\.Sql'
        $denied[2].status | Should -Be 'Fail'

        Set-SummaryResponse -StatusCode 400
        $bad = @(Test-DemoHubTelemetry -Config $config -Target T1)[0]
        $bad.status | Should -Be 'Manual action required'
        $bad.remediation | Should -Match 'getschema'
    }

    It 'keeps polling until fresh rows arrive, within the wait' {
        $script:polls = 0
        $script:freshJson = ConvertTo-HubSummaryJson -Entry @((Get-SummaryEntry T1))
        $script:emptyJson = ConvertTo-HubSummaryJson -Entry @()
        Initialize-HubHttpMock -Handler {
            $script:polls++
            ConvertTo-HubHttpResponse -Json $(if ($script:polls -lt 2) { $script:emptyJson } else { $script:freshJson })
        }
        $result = @(Test-DemoHubTelemetry -Config $config -Target T1 -WaitMinutes 15 -PollSeconds 60)[0]
        $result.status | Should -Be 'Pass'
        $result.evidence.polls | Should -Be 2
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 60 }
    }

    It 'bounds the number of polls even when the clock doesn''t move' {
        Set-SummaryResponse -Entry @()
        $result = @(Test-DemoHubTelemetry -Config $config -Target T1 -WaitMinutes 2 -PollSeconds 60)[0]
        $result.status | Should -Be 'Fail'
        $result.evidence.polls | Should -Be 3
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly
    }

    It 'resolves T3 from the resource group''s deploymentId tag' {
        Set-SummaryResponse -Entry @((Get-SummaryEntry T3))
        (@(Test-DemoHubTelemetry -Config $config -Target T3)[2]).status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -like 'group show --name rg-dbhub-demo --query tags.deploymentId --output tsv*' }
    }

    It 'uses -DeploymentId without reading the resource group' {
        Set-SummaryResponse -Entry @((Get-SummaryEntry T3))
        (@(Test-DemoHubTelemetry -Config $config -Target T3 -DeploymentId 'abc123')[2]).status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'group' }
    }

    It 'fails T3 when its deploymentId can''t be found' {
        Initialize-HubAzMock -Token $script:token -DeploymentIdTag ''
        Set-SummaryResponse -Entry @()
        $result = @(Test-DemoHubTelemetry -Config $config -Target T3)[2]
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'deploymentId'
    }

    It 'adds tables, wait categories, and counters with -Detail' {
        Set-SummaryResponse -Entry @((Get-SummaryEntry T1))
        $result = @(Test-DemoHubTelemetry -Config $config -Target T1 -Detail)[0]
        $result.status | Should -Be 'Pass'
        $result.evidence.tables[0].table | Should -Be 'SqlServerWaitStats'
        $result.evidence.waitCategories[0].category | Should -Be 'Lock'
        $result.evidence.waitCategories[0].waitSeconds | Should -Be 81
        $result.evidence.gaugeCounters[0].counter | Should -Be 'Processes blocked'
        $result.evidence.gaugeCounters[0].max | Should -Be 3
        $result.evidence.rateCounters[0].counter | Should -Be 'Number of Deadlocks/sec'
        $script:HubHttpCalls.Count | Should -Be 5
    }

    It 'downgrades Pass to Warning when the query failed partway' {
        $json = ConvertTo-HubSummaryJson -Entry @((Get-SummaryEntry T1))
        $document = $json | ConvertFrom-Json
        $document.Tables[0].Rows = @($document.Tables[0].Rows) + @([pscustomobject]@{ Exceptions = @('limits exceeded') })
        Set-SummaryResponse -StatusCode 200 -Json ($document | ConvertTo-Json -Depth 10)
        $result = @(Test-DemoHubTelemetry -Config $config -Target T1)[0]
        $result.status | Should -Be 'Warning'
        $result.evidence.errorKind | Should -Be 'PartialFailure'
    }
}

Describe 'Tokens never reach logs or results' {
    It 'redacts the token from every stream and record, even when an error echoes it' {
        Clear-DemoSecret
        $script:token = Get-HubFakeToken
        $config = Get-HubTestConfig
        Initialize-HubAzMock -Token $script:token
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        $script:echo = '{"error":{"code":"Forbidden","message":"token ' + $script:token + ' is not allowed"}}'
        Initialize-HubHttpMock -Handler { ConvertTo-HubHttpResponse -StatusCode 403 -Json $script:echo }
        $output = Test-DemoHubTelemetry -Config $config -Target T1 -Detail *>&1
        $text = ($output | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Depth 8 } }) -join "`n"
        $text | Should -Match 'TELEMETRY.T1'
        $text | Should -Not -Match ([regex]::Escape($script:token))
        $text | Should -Match '\[REDACTED\]'
    }
}
