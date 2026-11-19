BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig([hashtable] $Override = @{}) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # Obviously fake IDs: every group repeats one character.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        foreach ($key in $Override.Keys) {
            $config[$key] = $Override[$key]
        }
        $config
    }

    function New-AzResult([object] $Json = $null, [int] $ExitCode = 0, [string] $StdErr = '') {
        $text = if ($null -eq $Json) { '' } elseif ($Json -is [string]) { $Json } else { ConvertTo-Json -InputObject $Json -Depth 20 -Compress }
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $text; StdErr = $StdErr }
    }

    $script:accountId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DocumentDB/databaseAccounts/cosmos01-abc123'
    $script:principalId = '99999999-8888-7777-6666-555555555555'

    function New-AccountJson {
        param([string] $State = 'Succeeded', [string] $LocalAuthOff = 'true', [string] $Public = 'Disabled', [string] $FreeTier = 'true', [string] $Connection = 'Approved')
        @{
            id         = $script:accountId
            name       = 'cosmos01-abc123'
            kind       = 'GlobalDocumentDB'
            properties = @{
                provisioningState                  = $State
                documentEndpoint                   = 'https://cosmos01-abc123.documents.azure.com:443/'
                disableLocalAuth                   = $LocalAuthOff
                disableKeyBasedMetadataWriteAccess = 'true'
                publicNetworkAccess                = $Public
                enableFreeTier                     = $FreeTier
                privateEndpointConnections         = @(
                    @{ properties = @{ privateEndpoint = @{ id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/privateEndpoints/pe-dbhub-demo-cosmos01' }; privateLinkServiceConnectionState = @{ status = $Connection } } }
                )
            }
        }
    }

    # A mock of Invoke-DemoAz for T5's reads: the resource group's tag, the account and its children through 'az rest', and
    # Azure Monitor's metrics. $script:t5 holds what Azure "has".
    function Initialize-T5AzMock {
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:t5 = @{
            Account     = (New-AccountJson)
            PartitionKey = '/patientId'
            Throughput  = 400
            Assignments = @(@{ properties = @{ roleDefinitionId = ($script:accountId + '/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'); principalId = $script:principalId; scope = $script:accountId } })
            Metrics     = @{ NormalizedRUConsumption = @(35.0, 100.0, 62.0); TotalRequestUnits = @(9000.0, 24000.0, 15000.0); TotalRequests = @(400.0, 900.0, 500.0); Throttled = @(0.0, 120.0, 0.0) }
            QuotaId     = 'PayAsYouGo_2014-09-01'
        }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT1PrincipalId -MockWith { $script:principalId }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $text = @($ArgumentList) -join ' '
            $parametersIndex = [array]::IndexOf([string[]]@($ArgumentList), '--url-parameters')
            $query = $null
            if ($parametersIndex -ge 0) {
                $query = Get-Content -LiteralPath ([string]$ArgumentList[$parametersIndex + 1]).Substring(1) -Raw | ConvertFrom-Json -AsHashtable
            }
            $script:azCalls.Add($text)
            if ($text -like 'group show*') {
                return [pscustomobject]@{ tags = [pscustomobject]@{ deploymentId = 'abc123' } }
            }
            if ($text -match 'providers/Microsoft\.Insights/metrics' -and $null -ne $query) {
                $key = if ($query.Contains('$filter')) { 'Throttled' } else { [string]$query['metricnames'] }
                $field = ([string]$query['aggregation']).ToLowerInvariant()
                $start = [datetime]::new(2026, 11, 18, 20, 0, 0, [System.DateTimeKind]::Utc)
                $points = @(for ($i = 0; $i -lt @($script:t5.Metrics[$key]).Count; $i++) { @{ timeStamp = $start.AddMinutes($i).ToString('o'); $field = @($script:t5.Metrics[$key])[$i] } })
                return (New-AzResult -Json @{ value = @(@{ name = @{ value = [string]$query['metricnames'] }; timeseries = @(@{ data = $points }) }) })
            }
            if ($null -eq $script:t5.Account -and $text -match 'databaseAccounts/cosmos01-abc123') {
                return (New-AzResult -ExitCode 1 -StdErr "ERROR: (ResourceNotFound) The Resource 'Microsoft.DocumentDB/databaseAccounts/cosmos01-abc123' under resource group 'rg-dbhub-demo' was not found.")
            }
            if ($text -match 'sqlRoleAssignments\?') {
                return (New-AzResult -Json @{ value = @($script:t5.Assignments) })
            }
            if ($text -match 'throughputSettings/default\?') {
                return (New-AzResult -Json @{ properties = @{ resource = @{ throughput = $script:t5.Throughput } } })
            }
            if ($text -match 'containers/patient-events\?') {
                return (New-AzResult -Json @{ properties = @{ resource = @{ id = 'patient-events'; partitionKey = @{ paths = @($script:t5.PartitionKey); kind = 'Hash'; version = 2 } } } })
            }
            if ($text -match 'databaseAccounts/cosmos01-abc123\?') {
                return (New-AzResult -Json $script:t5.Account)
            }
            if ($text -match 'management\.azure\.com/subscriptions/[0-9a-f-]+\?api-version=' -and $text -match 'subscriptionPolicies\.quotaId') {
                return (New-AzResult -Json ([string]$script:t5.QuotaId))
            }
            return (New-AzResult -ExitCode 1 -StdErr ('unexpected: {0}' -f $text))
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'T5''s names and settings (ADR 0027)' {
    It 'names the account after the deploymentId, so a redeploy keeps it, with the private endpoint and the container' {
        $names = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT5Name -Config $Config -DeploymentId 'abc123' }
        $names.Enabled | Should -BeTrue -Because 'T5 is on unless the configuration turns it off, so an upgrade adds it'
        $names.AccountName | Should -Be 'cosmos01-abc123'
        $names.AccountId | Should -Be $script:accountId
        $names.AccountHost | Should -Be 'cosmos01-abc123.documents.azure.com'
        $names.PrivateEndpointName | Should -Be 'pe-dbhub-demo-cosmos01'
        $names.DatabaseName | Should -Be 'contosocare'
        $names.ContainerName | Should -Be 'patient-events'
        $names.Throughput | Should -Be 400
    }

    It 'is off only when the configuration says so, and asks for the free tier unless t5UseFreeTier is false' {
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Test-DemoT5Enabled -Config $Config } | Should -BeTrue
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Override @{ t5Enabled = $false }) } { Test-DemoT5Enabled -Config $Config } | Should -BeFalse
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Test-DemoT5FreeTierWanted -Config $Config } | Should -BeTrue
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Override @{ t5UseFreeTier = $false }) } { Test-DemoT5FreeTierWanted -Config $Config } | Should -BeFalse
    }

    It 'sends t5Enabled and the free tier the deployment decided to the template, and never a free tier with T5 off' {
        $config = New-TestConfig
        $on = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDeploymentParameter -Config $Config -NetworkMode private -ExistingResourceGroupTags @{ deploymentId = 'abc123' } -T3UseFreeLimit $true -T5FreeTier $true }
        $on['parameters']['t5Enabled']['value'] | Should -BeTrue
        $on['parameters']['t5FreeTier']['value'] | Should -BeTrue
        $off = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Override @{ t5Enabled = $false }) } { Get-DemoDeploymentParameter -Config $Config -NetworkMode private -ExistingResourceGroupTags @{ deploymentId = 'abc123' } -T3UseFreeLimit $true -T5FreeTier $true }
        $off['parameters']['t5Enabled']['value'] | Should -BeFalse
        $off['parameters']['t5FreeTier']['value'] | Should -BeFalse
    }
}

Describe 'Resolve-DemoT5FreeTier' {
    BeforeEach {
        Initialize-T5AzMock
        $script:holders = [pscustomobject]@{ Succeeded = $true; Error = ''; Rows = @() }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHubResourceGraph -MockWith { $script:holders }
    }

    It 'keeps what an existing account has, because Azure sets the free tier only at creation, and reads nothing else' {
        $script:t5.Account = New-AccountJson -FreeTier 'false'
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Resolve-DemoT5FreeTier -Config $Config -DeploymentId 'abc123' }
        $resolved.UseFreeTier | Should -BeFalse
        $resolved.Result.checkId | Should -Be 'DEPLOY.T5.FREETIER'
        $resolved.Result.status | Should -Be 'Pass'
        $resolved.Result.message | Should -Match 'Azure sets only when an account is created'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoHubResourceGraph -Times 0 -Exactly
    }

    It 'asks for the free tier for a new account when no other account in the subscription has it' {
        $script:t5.Account = $null
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Resolve-DemoT5FreeTier -Config $Config -DeploymentId 'abc123' }
        $resolved.UseFreeTier | Should -BeTrue
        $resolved.Result.status | Should -Be 'Pass'
    }

    It 'leaves it out, with a Warning that names the account that has it, when another account does' {
        $script:t5.Account = $null
        $script:holders = [pscustomobject]@{ Succeeded = $true; Error = ''; Rows = @([pscustomobject]@{ id = '/subscriptions/x/resourceGroups/rg-other/providers/Microsoft.DocumentDB/databaseAccounts/someone-else'; name = 'someone-else'; resourceGroup = 'rg-other' }) }
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Resolve-DemoT5FreeTier -Config $Config -DeploymentId 'abc123' }
        $resolved.UseFreeTier | Should -BeFalse
        $resolved.Result.status | Should -Be 'Warning'
        $resolved.Result.message | Should -Match 'someone-else \(resource group rg-other\)'
    }

    It 'leaves it out when Resource Graph can''t be read, because asking for a free tier that''s taken fails the creation' {
        $script:t5.Account = $null
        $script:holders = [pscustomobject]@{ Succeeded = $false; Error = 'AuthorizationFailed'; Rows = @() }
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Resolve-DemoT5FreeTier -Config $Config -DeploymentId 'abc123' }
        $resolved.UseFreeTier | Should -BeFalse
        $resolved.Result.status | Should -Be 'Warning'
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT5FreeTierStatus -Config $Config -DeploymentId 'abc123' } | Should -BeNullOrEmpty -Because 'the estimate then says it wasn''t checked'
    }

    It 'leaves it out when t5UseFreeTier is false' {
        $script:t5.Account = $null
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Override @{ t5UseFreeTier = $false }) } { Resolve-DemoT5FreeTier -Config $Config -DeploymentId 'abc123' }
        $resolved.UseFreeTier | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoHubResourceGraph -Times 0 -Exactly
    }

    It 'leaves it out in an internal subscription, which Azure refuses it in, without a template that fails first (live 2026-11-18)' {
        $script:t5.Account = $null
        $script:t5.QuotaId = 'Internal_2014-09-01'
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Resolve-DemoT5FreeTier -Config $Config -DeploymentId 'abc123' }
        $resolved.UseFreeTier | Should -BeFalse
        $resolved.Reason | Should -Be 'Offer'
        $resolved.Result.status | Should -Be 'Warning'
        $resolved.Result.message | Should -Match 'internal subscription, Internal_2014-09-01'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoHubResourceGraph -Times 0 -Exactly
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT5FreeTierStatus -Config $Config -DeploymentId 'abc123' } | Should -BeFalse -Because 'the estimate prices the list price, not "not checked"'
    }

    It 'still asks for it when the subscription''s offer can''t be read; the template''s refusal retry is the backstop' {
        $script:t5.Account = $null
        $script:t5.QuotaId = $null
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSubscriptionQuotaId -MockWith { '' }
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Resolve-DemoT5FreeTier -Config $Config -DeploymentId 'abc123' }
        $resolved.UseFreeTier | Should -BeTrue
        $resolved.Reason | Should -Be 'Free'
    }

    It 'knows a refusal of the free tier from the template''s error text, and says Azure''s reason' {
        InModuleScope DbHubDemo { Test-DemoT5FreeTierRefusal -Text 'ERROR: (BadRequest) Free tier has already been applied to another Azure Cosmos DB account in this subscription.' } | Should -BeTrue
        InModuleScope DbHubDemo { Test-DemoT5FreeTierRefusal -Text 'ERROR: (ProvisioningDisabled) The free offer is not available in region westus3.' } | Should -BeFalse
        # The live refusal's text (2026-11-18), as az prints the nested deployment error.
        $live = 'ERROR: {"status":"Failed","error":{"details":[{"code":"BadRequest","message":"{\r\n  \"code\": \"BadRequest\",\r\n  \"message\": \"Free tier is not supported for Internal subscriptions.\\r\\nActivityId: 00000000-0000-0000-0000-000000000000, Microsoft.Azure.Documents.Common/2.14.0\"\r\n}"}]}}'
        InModuleScope DbHubDemo -Parameters @{ Text = $live } { Test-DemoT5FreeTierRefusal -Text $Text } | Should -BeTrue
        InModuleScope DbHubDemo -Parameters @{ Text = $live } { Get-DemoT5FreeTierRefusalReason -Text $Text } | Should -Match '"Free tier is not supported for Internal subscriptions"'
        InModuleScope DbHubDemo { Get-DemoT5FreeTierRefusalReason -Text 'ERROR: (BadRequest) Free tier has already been applied.' } | Should -Match 'taken'
        InModuleScope DbHubDemo { Get-DemoT5FreeTierRefusalReason -Text 'ERROR: (BadRequest) Free tier has already been applied to another Azure Cosmos DB account in this subscription.' } | Should -Match '^"Free tier has already been applied to another Azure Cosmos DB account in this subscription"'
    }

    It 'takes "free tier" as T5''s refusal only in Azure Cosmos DB''s own error detail (review, 2026-11-19): <Name>' -ForEach @(
        # The Azure CLI's other format: a detail's Target line comes before its inner details.
        @{ Name = 'the CLI''s Target lines, Cosmos DB'; Expected = $true; Text = "ERROR: (DeploymentFailed) At least one resource deployment operation failed.`nCode: DeploymentFailed`nException Details:`t(ResourceDeploymentFailure) The resource write operation failed to complete successfully, because it reached terminal provisioning state 'Failed'.`n`tCode: ResourceDeploymentFailure`n`tTarget: /subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Resources/deployments/cosmos01`n`tException Details:`t(BadRequest) Free tier is not supported for this subscription.`n`t`tCode: BadRequest" }
        @{ Name = 'the CLI''s Target lines, Azure SQL'; Expected = $false; Text = "ERROR: (DeploymentFailed) At least one resource deployment operation failed.`nCode: DeploymentFailed`nException Details:`t(ResourceDeploymentFailure) The resource write operation failed to complete successfully, because it reached terminal provisioning state 'Failed'.`n`tCode: ResourceDeploymentFailure`n`tTarget: /subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Resources/deployments/azuresql01`n`tException Details:`t(ProvisioningDisabled) The free tier isn't available for this database.`n`t`tCode: ProvisioningDisabled" }
        # A hypothetical Azure SQL error that says "free tier", next to T5's own failure that isn't about it, in either order:
        # T5 keeps its free tier.
        @{ Name = 'Azure SQL''s "free tier" before a Cosmos DB failure'; Expected = $false; Text = 'ERROR: {"status":"Failed","error":{"code":"DeploymentFailed","details":[{"code":"ResourceDeploymentFailure","target":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Resources/deployments/azuresql01","details":[{"code":"ProvisioningDisabled","message":"The free tier isn''t available for this database."}]},{"code":"ResourceDeploymentFailure","target":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Resources/deployments/cosmos01","details":[{"code":"ServiceUnavailable","message":"Sorry, we are currently experiencing high demand in this region. ActivityId: 00000000-0000-0000-0000-000000000000, Microsoft.Azure.Documents.Common/2.14.0"}]}]}}' }
        @{ Name = 'Azure SQL''s "free tier" after a Cosmos DB failure'; Expected = $false; Text = 'ERROR: {"status":"Failed","error":{"code":"DeploymentFailed","details":[{"code":"ResourceDeploymentFailure","target":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Resources/deployments/cosmos01","details":[{"code":"ServiceUnavailable","message":"Sorry, we are currently experiencing high demand in this region. ActivityId: 00000000-0000-0000-0000-000000000000, Microsoft.Azure.Documents.Common/2.14.0"}]},{"code":"ResourceDeploymentFailure","target":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Resources/deployments/azuresql01","details":[{"code":"ProvisioningDisabled","message":"The free tier isn''t available for this database."}]}]}}' }
        # Azure SQL's real refusal (Microsoft Q&A), and both refusals in one error.
        @{ Name = 'Azure SQL''s real refusal'; Expected = $false; Text = 'ERROR: {"status":"Failed","error":{"code":"DeploymentFailed","details":[{"code":"ResourceDeploymentFailure","target":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Resources/deployments/azuresql01","details":[{"code":"ProvisioningDisabled","message":"Provisioning of free limit database is not supported for provided service level objective or region"}]}]}}' }
        @{ Name = 'both refusals'; Expected = $true; Text = 'ERROR: {"status":"Failed","error":{"code":"DeploymentFailed","details":[{"code":"ResourceDeploymentFailure","target":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Resources/deployments/azuresql01","details":[{"code":"ProvisioningDisabled","message":"Provisioning of free limit database is not supported for provided service level objective or region"}]},{"code":"ResourceDeploymentFailure","target":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Resources/deployments/cosmos01","details":[{"code":"BadRequest","message":"Free tier has already been applied to another Azure Cosmos DB account in this subscription. To apply free tier to this account, you can select another subscription for this account or delete the existing free tier account."}]}]}}' }
    ) {
        InModuleScope DbHubDemo -Parameters @{ Text = $Text } { Test-DemoT5FreeTierRefusal -Text $Text } | Should -Be $Expected
    }
}

Describe 'T5 in an existing demo: DEPLOY.T5.MISSING and DEPLOY.T5.OFF' {
    BeforeEach {
        Initialize-T5AzMock
    }

    It 'starts a resume from preflight when the account doesn''t exist, as in a demo deployed before T5' {
        $script:t5.Account = $null
        $state = [pscustomobject]@{ Stage = 'Validation'; Tags = @{ deploymentId = 'abc123' } }
        $missing = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $state } { Get-DemoT5MissingResult -Config $Config -State $State }
        $missing.checkId | Should -Be 'DEPLOY.T5.MISSING'
        $missing.status | Should -Be 'Pass'
        $missing.message | Should -Match 'cosmos01-abc123 doesn''t exist'
    }

    It 'lets the resume go on when the account exists, when T5 is off, or without a deploymentId' {
        $state = [pscustomobject]@{ Stage = 'Validation'; Tags = @{ deploymentId = 'abc123' } }
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $state } { Get-DemoT5MissingResult -Config $Config -State $State } | Should -BeNullOrEmpty
        $script:t5.Account = $null
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Override @{ t5Enabled = $false }); State = $state } { Get-DemoT5MissingResult -Config $Config -State $State } | Should -BeNullOrEmpty
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = [pscustomobject]@{ Stage = 'Validation'; Tags = @{} } } { Get-DemoT5MissingResult -Config $Config -State $State } | Should -BeNullOrEmpty
    }

    It 'says once that T5 is off, and that an existing account keeps billing' {
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { New-DemoT5OffResult -Config $Config } | Should -BeNullOrEmpty
        $off = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Override @{ t5Enabled = $false }) } { New-DemoT5OffResult -Config $Config }
        $off.checkId | Should -Be 'DEPLOY.T5.OFF'
        $off.status | Should -Be 'Not selected'
        $off.message | Should -Match 'keeps billing'
    }
}

Describe 'Test-DemoT5' {
    BeforeEach {
        Initialize-T5AzMock
    }

    It 'passes every check for the account the template creates, with T1''s data-plane role and its metrics' {
        $results = @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123' -IncludeMetrics)
        $results.checkId | Should -Be @('T5.ACCOUNT', 'T5.ENTRAONLY', 'T5.NETWORK', 'T5.CONTAINER', 'T5.FREETIER', 'T5.ACCESS', 'METRICS.T5')
        @($results | Where-Object status -NE 'Pass') | Should -BeNullOrEmpty
        ($results | Where-Object checkId -EQ 'T5.ACCOUNT').message | Should -Match 'no stop'
        $metrics = $results | Where-Object checkId -EQ 'METRICS.T5'
        $metrics.evidence['peakNormalizedRuPercent'] | Should -Be 100
        $metrics.evidence['throttled'] | Should -Be 120
        $metrics.evidence['requests'] | Should -Be 1800
        $metrics.message | Should -Match '120 of them throttled \(429\)'
        # Reads only: every call is a GET.
        @($script:azCalls | Where-Object { $_ -like 'rest *' -and $_ -notlike 'rest --method get *' }) | Should -BeNullOrEmpty
    }

    It 'fails an account that still allows keys, a public account, and one without T1''s role, each with its fix' {
        $script:t5.Account = New-AccountJson -LocalAuthOff 'false' -Public 'Enabled'
        $script:t5.Assignments = @()
        $results = @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123')
        ($results | Where-Object checkId -EQ 'T5.ENTRAONLY').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'T5.NETWORK').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'T5.ACCESS').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'T5.ACCESS').remediation | Should -Match 'deploy\.ps1'
    }

    It 'warns when the container has other throughput than ru-storm is sized for' {
        $script:t5.Throughput = 1000
        $container = @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123') | Where-Object checkId -EQ 'T5.CONTAINER'
        $container.status | Should -Be 'Warning'
        $container.message | Should -Match '1000 RU/s, not 400'
    }

    It 'fails a missing account with the upgrade''s command, and checks nothing more' {
        $script:t5.Account = $null
        $results = @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123' -IncludeMetrics)
        ($results | Where-Object checkId -EQ 'T5.ACCOUNT').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'T5.ACCOUNT').remediation | Should -Match 'deploy\.ps1'
        @($results | Where-Object checkId -NE 'T5.ACCOUNT' | Where-Object status -NE 'Not selected') | Should -BeNullOrEmpty
    }

    It 'is Not selected when T5 is off, and reads nothing' {
        $results = @(Test-DemoT5 -Config (New-TestConfig -Override @{ t5Enabled = $false }) -DeploymentId 'abc123')
        $results.status | Should -Be @('Not selected')
        @($script:azCalls) | Should -BeNullOrEmpty
    }

    It 'calls METRICS.T5 a Warning, not a Fail, while nothing has sent the account requests' {
        $script:t5.Metrics = @{ NormalizedRUConsumption = @(0.0); TotalRequestUnits = @(0.0); TotalRequests = @(0.0); Throttled = @(0.0) }
        $metrics = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); AccountId = $script:accountId } { Test-DemoT5MetricFlow -Config $Config -AccountId $AccountId }
        $metrics.status | Should -Be 'Warning'
        $metrics.remediation | Should -Match 'activity profile'
    }

    It 'passes with no 429s at all, when Azure returns no point for the 429 filter (live 2026-11-18: .Sum of nothing stopped deploy.ps1)' {
        $script:t5.Metrics = @{ NormalizedRUConsumption = @(12.0, 18.0); TotalRequestUnits = @(900.0, 1100.0); TotalRequests = @(60.0, 70.0); Throttled = @() }
        $snapshot = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); AccountId = $script:accountId } { Get-DemoT5MetricSnapshot -Config $Config -AccountId $AccountId }
        $snapshot.Succeeded | Should -BeTrue
        $snapshot.Throttled | Should -Be 0
        $snapshot.Requests | Should -Be 130
        $snapshot.PeakNormalizedRu | Should -Be 18
        $metrics = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); AccountId = $script:accountId } { Test-DemoT5MetricFlow -Config $Config -AccountId $AccountId }
        $metrics.status | Should -Be 'Pass'
        $metrics.evidence['throttled'] | Should -Be 0
    }
}

Describe 'T5 has no stop: STOP.T5' {
    It 'says what bills between sessions, Not supported rather than a Fail, and names the free tier' {
        $state = [pscustomobject]@{ Exists = $true; FreeTier = $false; Names = [pscustomobject]@{ AccountName = 'cosmos01-abc123' } }
        $stop = InModuleScope DbHubDemo -Parameters @{ State = $state } { Get-DemoT5StopResult -State $State }
        $stop.checkId | Should -Be 'STOP.T5'
        $stop.status | Should -Be 'Not supported'
        $stop.message | Should -Match 'can''t be stopped or paused'
        $stop.message | Should -Match '400 RU/s of throughput bill every hour'
        $state.FreeTier = $true
        (InModuleScope DbHubDemo -Parameters @{ State = $state } { Get-DemoT5StopResult -State $State }).message | Should -Match 'cost nothing on the free tier'
        (InModuleScope DbHubDemo { Get-DemoT5StopResult -State $null }).status | Should -Be 'Not selected'
    }
}

Describe 'Invoke-DemoT5WarmUp' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:attempt = 0
    }

    It 'tries again while T1''s new data-plane role comes into effect, then passes, through one Run Command at a time' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $script:attempt++
            if ($script:attempt -lt 3) {
                return [pscustomobject]@{ Status = 'Fail'; ExitCode = 1; StdErr = ''; Records = @(); Result = [pscustomobject]@{ message = 'T5: 403 Forbidden: the request isn''t authorized by a data-plane role assignment yet.' } }
            }
            [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; StdErr = ''; Records = @([pscustomobject]@{ checkId = 'WORKLOAD.T5.WARMUP'; message = 'Read, upserted, and read back one document.' }); Result = [pscustomobject]@{ message = 'ok' } }
        }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT5WarmUp -Config $Config -WaitMinutes 10 -RetrySeconds 30 }
        $result.checkId | Should -Be 'WORKLOAD.T5.WARMUP'
        $result.status | Should -Be 'Pass'
        $result.evidence['attempts'] | Should -Be 3
        $result.message | Should -Match 'after 3 attempts'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -Times 3 -Exactly -ParameterFilter { $Target -eq 'T5' -and ($ArgumentList -join ' ') -eq 'warmup --json' }
    }

    It 'stops at once on an error that isn''t transient, with the fix' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            [pscustomobject]@{ Status = 'Fail'; ExitCode = 2; StdErr = ''; Records = @(); Result = [pscustomobject]@{ message = 'T5: the container patient-events doesn''t exist in contosocare.' } }
        }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT5WarmUp -Config $Config -WaitMinutes 10 -RetrySeconds 30 }
        $result.status | Should -Be 'Fail'
        $result.evidence['attempts'] | Should -Be 1
        $result.remediation | Should -Match 'validate\.ps1 -Area T5'
    }
}
