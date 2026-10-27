BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')

    function Set-T3Telemetry {
        # T3's row in the ResourceSummary response; no arguments means no rows at all.
        param([int] $Rows = 0, [int] $RowsSince = 0, [object] $FirstSince = $null, [object] $Last = $null, [int] $StatusCode = 200)
        $entries = @()
        if ($Rows -gt 0) {
            $entries = @(@{ Id = $script:HubT3Id; Type = 'servers/databases'; Name = 'azuresql01-abc123/ContosoCare'; Rows = $Rows; RowsSince = $RowsSince; First = $script:HubNow.AddDays(-3); FirstSince = $FirstSince; Last = $Last })
        }
        $script:t3Json = ConvertTo-HubSummaryJson -Entry $entries
        $script:t3Status = $StatusCode
        Initialize-HubHttpMock -Handler {
            if ($script:t3Status -ne 200) {
                return ConvertTo-HubHttpResponse -StatusCode $script:t3Status -Json '{"error":{"code":"Forbidden","message":"denied"}}'
            }
            ConvertTo-HubHttpResponse -Json $script:t3Json
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Test-DemoHubEstate' {
    BeforeEach {
        Clear-DemoSecret
        $config = Get-HubTestConfig
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
    }

    It 'passes every target that Resource Graph lists, through the documented Resources API with a body file' {
        Initialize-HubAzMock -Token (Get-HubFakeToken) -GraphRow (Get-HubGraphRow)
        $results = @(Test-DemoHubEstate -Config $config)
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('HUB.ESTATE.T1', 'HUB.ESTATE.T2', 'HUB.ESTATE.T3', 'HUB.ESTATE.T4')
        $results | ForEach-Object { $_.status | Should -Be 'Pass' }
        $results[3].evidence.state | Should -Be 'Ready'
        $results[3].message | Should -Match 'metrics only'
        $results[0].evidence.sqlImageSku | Should -Be 'Standard'
        $results[1].evidence.licenseType | Should -Be 'PAYG'
        $results[2].evidence.resourceId | Should -Be $script:HubT3Id
        $results[2].message | Should -Match 'manual check'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Uri -eq 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01' -and $SubscriptionId -eq $script:HubSubscriptionId
        }
        # Resource Graph has no subscription in its URL, so 'az rest' would use the Azure CLI's default account.
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'rest' }
        $script:HubGraphBodies[0].subscriptions | Should -Be @($script:HubSubscriptionId)
        $script:HubGraphBodies[0].query | Should -Match "resourceGroup =~ 'rg-dbhub-demo'"
        $script:HubGraphBodies[0].options.resultFormat | Should -Be 'objectArray'
    }

    It 'fails T4 when its flexible server isn''t listed, and leaves it out when T4 is off' {
        Initialize-HubAzMock -Token (Get-HubFakeToken) -GraphRow (Get-HubGraphRow -Without 'microsoft.dbforpostgresql/flexibleservers|pgflex01-abc123')
        $result = @(Test-DemoHubEstate -Config $config -Target T4)[3]
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'pgflex01-abc123'
        $config['t4Enabled'] = $false
        @(Test-DemoHubEstate -Config $config -Target T4)[3].status | Should -Be 'Not selected'
    }

    It 'fails T1 when the VM has no SQL virtual machine resource' {
        Initialize-HubAzMock -Token (Get-HubFakeToken) -GraphRow (Get-HubGraphRow -Without 'microsoft.sqlvirtualmachine/sqlvirtualmachines|sqlvm01')
        $result = @(Test-DemoHubEstate -Config $config -Target T1)[0]
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'SQL virtual machine resource is missing'
    }

    It 'reports an Arc machine without a SQL instance as the pending wizard step, or a Warning in the other modes' {
        Initialize-HubAzMock -Token (Get-HubFakeToken) -GraphRow (Get-HubGraphRow -Without 'microsoft.azurearcdata/sqlserverinstances|arcsql01')
        @(Test-DemoHubEstate -Config $config -Target T2)[1].status | Should -Be 'Manual action required'
        $config['t2SqlInstallMode'] = 'ProductKey'
        @(Test-DemoHubEstate -Config $config -Target T2)[1].status | Should -Be 'Warning'
    }

    It 'fails T2 without an Arc machine and labels the evaluation-only mode' {
        $config['t2Mode'] = 'EvaluationOnlyAzureVm'
        Initialize-HubAzMock -Token (Get-HubFakeToken) -GraphRow (Get-HubGraphRow -Without 'microsoft.azurearcdata/sqlserverinstances|arcsql01', 'microsoft.hybridcompute/machines|arcsql01')
        $result = @(Test-DemoHubEstate -Config $config -Target T2)[1]
        $result.status | Should -Be 'Fail'
        $result.message | Should -BeLike 'EVALUATION ONLY:*'
    }

    It 'finds T3 through its single azuresql01 server when the resource group has no deploymentId tag' {
        Initialize-HubAzMock -Token (Get-HubFakeToken) -DeploymentIdTag '' -GraphRow (Get-HubGraphRow)
        $result = @(Test-DemoHubEstate -Config $config -Target T3)[2]
        $result.status | Should -Be 'Pass'
        $result.evidence.resolvedFrom | Should -Be 'resourceGraph'
    }

    It 'fails T3 when only its server is listed, and when nothing is' {
        Initialize-HubAzMock -Token (Get-HubFakeToken) -GraphRow (Get-HubGraphRow -Without 'microsoft.sql/servers/databases|ContosoCare')
        @(Test-DemoHubEstate -Config $config -Target T3)[2].message | Should -Match 'database ContosoCare isn''t'
        Initialize-HubAzMock -Token (Get-HubFakeToken) -GraphRow @()
        @(Test-DemoHubEstate -Config $config -Target T3)[2].remediation | Should -Match 'start-demo\.ps1 recreates it'
    }

    It 'fails the selected targets when Resource Graph can''t be queried, and skips the rest' {
        Initialize-HubAzMock -Token (Get-HubFakeToken) -GraphFails
        $results = @(Test-DemoHubEstate -Config $config -Target T1, T2)
        $results[0].status | Should -Be 'Fail'
        $results[1].status | Should -Be 'Fail'
        $results[2].status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'group' }
    }
}

Describe 'Test-DemoT3Readiness (the warm-up gate)' {
    BeforeEach {
        Clear-DemoSecret
        $config = Get-HubTestConfig
        Initialize-HubAzMock -Token (Get-HubFakeToken) -GraphRow (Get-HubGraphRow)
        Mock -ModuleName DbHubDemo -CommandName Get-DemoHubUtcNow -MockWith { [datetime]::new(2026, 10, 20, 12, 0, 0, [System.DateTimeKind]::Utc) }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        # T3 was created at 11:00 UTC (Get-HubGraphRow); the pinned clock says 12:00 UTC.
        $isSet = { param($Settings) $Settings.Count -gt 0 }
    }

    It 'is ready when all three hold, and measures the lag from creation to the first sample' {
        Set-T3Telemetry -Rows 500 -RowsSince 200 -FirstSince $script:HubNow.AddMinutes(-53) -Last $script:HubNow.AddMinutes(-1)
        $gate = Test-DemoT3Readiness -Config $config -PerformanceMonitoringCheck $isSet
        $gate.Ready | Should -BeTrue
        $gate.LagMinutes | Should -Be 7
        ($gate.Results | ForEach-Object { $_.checkId }) | Should -Be @('T3.READINESS.RESOURCEGRAPH', 'T3.READINESS.PERFPROPERTY', 'T3.READINESS.TELEMETRY', 'T3.READINESS.GATE')
        $gate.Results | ForEach-Object { $_.status | Should -Be 'Pass' }
        $gate.Results[3].message | Should -Match '7 minutes after T3 was created'
        # Earlier sessions under the same ResourceID stay queryable within retention.
        $gate.Results[2].evidence.priorSessionRows | Should -Be 300
        $gate.Results[2].evidence.priorSessionRowsQueryable | Should -BeTrue
        $script:HubHttpCalls[0].Csl | Should -Match 'let lookback = 10080m;'
        $script:HubHttpCalls[0].Csl | Should -Match 'let since = datetime\(2026-10-20T11:00:00\.0000000Z\);'
    }

    It 'warns with the lag so far when no telemetry has arrived since creation' {
        Set-T3Telemetry
        $gate = Test-DemoT3Readiness -Config $config -PerformanceMonitoringCheck $isSet
        $gate.Ready | Should -BeFalse
        $gate.LagMinutes | Should -Be 60
        $gate.Results[2].status | Should -Be 'Warning'
        $gate.Results[3].status | Should -Be 'Warning'
        $gate.Results[3].message | Should -Match 'waiting for: telemetry'
        $gate.Results[3].message | Should -Match '60 minutes after T3 was created'
        $gate.Results[3].evidence.lagMinutes | Should -Be 60
    }

    It 'asks for a manual check of the extended property when no check is supplied' {
        Set-T3Telemetry -Rows 200 -RowsSince 200 -FirstSince $script:HubNow.AddMinutes(-50) -Last $script:HubNow.AddMinutes(-1)
        $gate = Test-DemoT3Readiness -Config $config
        $gate.Ready | Should -BeFalse
        $gate.Results[1].status | Should -Be 'Manual action required'
        $gate.Results[1].remediation | Should -Match "MS_EnablePerformanceMonitoringPreview"
        $gate.Results[3].status | Should -Be 'Warning'
        $gate.Results[3].message | Should -Match 'extended property'
    }

    It 'reads the check''s answer: <Name>' -ForEach @(
        @{ Name = 'false'; Check = { $false }; Status = 'Warning' }
        @{ Name = 'a Fail record'; Check = { [pscustomobject]@{ checkId = 'T3.MONITORING.PROPERTY'; status = 'Fail'; message = 'property missing' } }; Status = 'Warning' }
        @{ Name = 'a Pass record'; Check = { [pscustomobject]@{ checkId = 'T3.MONITORING.PROPERTY'; status = 'Pass'; message = 'set' } }; Status = 'Pass' }
        @{ Name = 'an exception'; Check = { throw 'sqlcmd failed' }; Status = 'Warning' }
        @{ Name = 'something else'; Check = { 'maybe' }; Status = 'Manual action required' }
    ) {
        Set-T3Telemetry -Rows 200 -RowsSince 200 -FirstSince $script:HubNow.AddMinutes(-50) -Last $script:HubNow.AddMinutes(-1)
        $gate = Test-DemoT3Readiness -Config $config -PerformanceMonitoringCheck $Check
        $gate.Results[1].status | Should -Be $Status
        $gate.Ready | Should -Be ($Status -eq 'Pass')
    }

    It 'warns when T3 isn''t in Resource Graph, but still queries its telemetry by ResourceID' {
        Initialize-HubAzMock -Token (Get-HubFakeToken) -GraphRow (Get-HubGraphRow -Without 'microsoft.sql/servers/databases|ContosoCare')
        Set-T3Telemetry -Rows 300 -RowsSince 300 -FirstSince $script:HubNow.AddDays(-3) -Last $script:HubNow.AddHours(-20)
        $gate = Test-DemoT3Readiness -Config $config -PerformanceMonitoringCheck $isSet
        $gate.Results[0].status | Should -Be 'Warning'
        $gate.Results[3].status | Should -Be 'Warning'
        $gate.Results[3].message | Should -Match 'creation time is unknown'
        $script:HubHttpCalls.Count | Should -Be 1
    }

    It 'fails the telemetry part when the endpoint denies access, and keeps the gate a Warning' {
        Set-T3Telemetry -StatusCode 403
        $gate = Test-DemoT3Readiness -Config $config -PerformanceMonitoringCheck $isSet
        $gate.Results[2].status | Should -Be 'Fail'
        $gate.Results[3].status | Should -Be 'Warning'
    }

    It 'warns that a paused T3 sends no fresh telemetry' {
        Set-T3Telemetry -Rows 100 -RowsSince 100 -FirstSince $script:HubNow.AddMinutes(-55) -Last $script:HubNow.AddMinutes(-40)
        $gate = Test-DemoT3Readiness -Config $config -PerformanceMonitoringCheck $isSet
        $gate.Results[2].status | Should -Be 'Warning'
        $gate.Results[2].message | Should -Match 'paused'
        $gate.Ready | Should -BeFalse
    }

    It 'polls until ready and stops calling the property check once it passes' {
        $script:polls = 0
        $script:readyJson = ConvertTo-HubSummaryJson -Entry @(@{ Id = $script:HubT3Id; Type = 'servers/databases'; Name = 'azuresql01-abc123/ContosoCare'; Rows = 20; RowsSince = 20; First = $script:HubNow.AddMinutes(-5); FirstSince = $script:HubNow.AddMinutes(-5); Last = $script:HubNow.AddMinutes(-1) })
        $script:emptyJson = ConvertTo-HubSummaryJson -Entry @()
        Initialize-HubHttpMock -Handler {
            $script:polls++
            ConvertTo-HubHttpResponse -Json $(if ($script:polls -lt 3) { $script:emptyJson } else { $script:readyJson })
        }
        $script:checks = 0
        $gate = Test-DemoT3Readiness -Config $config -WaitMinutes 30 -PollSeconds 60 -PerformanceMonitoringCheck { $script:checks++; $true }
        $gate.Ready | Should -BeTrue
        $gate.LagMinutes | Should -Be 55
        $gate.Results[3].evidence.polls | Should -Be 3
        $script:checks | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly
    }
}
