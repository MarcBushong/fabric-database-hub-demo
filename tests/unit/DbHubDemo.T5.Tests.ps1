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
            # T5's container (2026-11-19): whether it's there, and what its creates and deletes did.
            Container   = $true
            PutErrors   = [System.Collections.Generic.List[string]]::new()
            Puts        = 0
            Deletes     = 0
            LastBody    = ''
        }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT1PrincipalId -MockWith { $script:principalId }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ deploymentId = 'abc123'; solution = 'dbhub-demo'; owner = 'demo-owner'; DbHubStage = 'Validation' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $text = @($ArgumentList) -join ' '
            $parametersIndex = [array]::IndexOf([string[]]@($ArgumentList), '--url-parameters')
            $query = $null
            if ($parametersIndex -ge 0) {
                $query = Get-Content -LiteralPath ([string]$ArgumentList[$parametersIndex + 1]).Substring(1) -Raw | ConvertFrom-Json -AsHashtable
            }
            $script:azCalls.Add($text)
            if ($text -match '^rest --method put .*containers/patient-events\?') {
                $script:t5.Puts++
                $bodyIndex = [array]::IndexOf([string[]]@($ArgumentList), '--body')
                $script:t5.LastBody = Get-Content -LiteralPath ([string]$ArgumentList[$bodyIndex + 1]).Substring(1) -Raw
                if ($script:t5.PutErrors.Count -gt 0) {
                    $failure = $script:t5.PutErrors[0]
                    $script:t5.PutErrors.RemoveAt(0)
                    return (New-AzResult -ExitCode 1 -StdErr $failure)
                }
                $script:t5.Container = $true
                return (New-AzResult -Json @{ status = 'Enqueued' })
            }
            if ($text -match '^rest --method delete .*containers/patient-events\?') {
                $script:t5.Deletes++
                if (-not $script:t5.Container) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (NotFound) Resource Not Found. Learn more: https://aka.ms/cosmosdb-tsg-not-found')
                }
                $script:t5.Container = $false
                return (New-AzResult)
            }
            if ($text -match 'containers/patient-events(/throughputSettings/default)?\?' -and -not $script:t5.Container) {
                return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (NotFound) Resource Not Found. Learn more: https://aka.ms/cosmosdb-tsg-not-found')
            }
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

Describe 'T5 left out when Azure doesn''t create its account (review, 2026-11-19)' {
    BeforeEach {
        Initialize-T5AzMock
        $script:t5.Account = $null
        $script:recordedState = [pscustomobject]@{ Stage = 'T3'; T5Refused = '2026-11-19T05:00:00Z'; Tags = @{ deploymentId = 'abc123' } }
    }

    It 'knows T5''s resources from the failed operations, and nothing else counts' {
        $config = New-TestConfig
        $t5Errors = @(
            [pscustomobject]@{ ResourceType = 'Microsoft.DocumentDB/databaseAccounts'; ResourceName = 'cosmos01-abc123'; Code = 'ServiceUnavailable'; Message = 'high demand' }
            [pscustomobject]@{ ResourceType = 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments'; ResourceName = 'cosmos01-abc123/55555555-5555-5555-5555-555555555555'; Code = 'NotFound'; Message = 'no account' }
            [pscustomobject]@{ ResourceType = 'Microsoft.Resources/deployments'; ResourceName = 'cosmos01-access'; Code = 'InvalidTemplateDeployment'; Message = 'RequestDisallowedByPolicy' }
            [pscustomobject]@{ ResourceType = 'Microsoft.Network/privateEndpoints'; ResourceName = 'pe-dbhub-demo-cosmos01'; Code = 'Canceled'; Message = 'canceled' }
            [pscustomobject]@{ ResourceType = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'; ResourceName = 'privatelink.documents.azure.com/link-vnet-dbhub-demo'; Code = 'Canceled'; Message = 'canceled' }
        )
        $only = InModuleScope DbHubDemo -Parameters @{ Config = $config; Cause = [pscustomobject]@{ Errors = $t5Errors; Text = 'T5 failed' } } { Get-DemoT5OnlyFailure -Config $Config -Cause $Cause }
        $only.T5Only | Should -BeTrue
        $only.Text | Should -Be 'T5 failed'
        # T3's private endpoint and its zone, another deployment, or no error that names a resource: never T5's alone.
        foreach ($other in @(
                [pscustomobject]@{ ResourceType = 'Microsoft.Network/privateEndpoints'; ResourceName = 'pe-dbhub-demo-azuresql01'; Code = 'Canceled'; Message = 'canceled' }
                [pscustomobject]@{ ResourceType = 'Microsoft.Network/privateDnsZones'; ResourceName = 'privatelink.database.windows.net'; Code = 'Conflict'; Message = 'busy' }
                [pscustomobject]@{ ResourceType = 'Microsoft.Resources/deployments'; ResourceName = 'azuresql01'; Code = 'DeploymentFailed'; Message = 'failed' }
            )) {
            $mixed = InModuleScope DbHubDemo -Parameters @{ Config = $config; Cause = [pscustomobject]@{ Errors = @($t5Errors[0], $other); Text = 'both' } } { Get-DemoT5OnlyFailure -Config $Config -Cause $Cause }
            $mixed.T5Only | Should -BeFalse -Because ('{0} {1} isn''t T5''s' -f $other.ResourceType, $other.ResourceName)
        }
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT5OnlyFailure -Config $Config -Cause $null -ErrorText 'ERROR: (Conflict) Another operation is in progress.' }).T5Only | Should -BeFalse
        # A policy's refusal before the deployment ran names each resource it disallowed.
        $policy = 'ERROR: {"error":{"code":"InvalidTemplateDeployment","details":[{"code":"RequestDisallowedByPolicy","message":"Resource ''cosmos01-abc123'' was disallowed by policy."},{"code":"RequestDisallowedByPolicy","message":"Resource ''pe-dbhub-demo-cosmos01'' was disallowed by policy."}]}}'
        (InModuleScope DbHubDemo -Parameters @{ Config = $config; Text = $policy } { Get-DemoT5OnlyFailure -Config $Config -Cause $null -ErrorText $Text }).T5Only | Should -BeTrue
        $both = $policy -replace 'pe-dbhub-demo-cosmos01', 'sqlvm01'
        (InModuleScope DbHubDemo -Parameters @{ Config = $config; Text = $both } { Get-DemoT5OnlyFailure -Config $Config -Cause $null -ErrorText $Text }).T5Only | Should -BeFalse
    }

    It 'names T5''s nested deployments as infra/modules/demo.bicep does' {
        $bicep = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/demo.bicep') -Raw
        foreach ($name in (& (Get-Module -Name DbHubDemo) { $script:T5DeploymentNames })) {
            $bicep | Should -Match ("module \w+ 'cosmos01[^']*\.bicep' = if \(t5Enabled\) \{\s+name: '" + [regex]::Escape($name) + "'")
        }
    }

    It 'doesn''t start a resume from preflight after a recorded failure, and the resume leaves T5 out with DEPLOY.T5' {
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:recordedState } { Get-DemoT5MissingResult -Config $Config -State $State } | Should -BeNullOrEmpty
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:recordedState } { Resolve-DemoT5LeftOut -Config $Config -State $State }
        $resolved.Config['t5Enabled'] | Should -BeFalse
        $resolved.Config['t5LeftOut'] | Should -Match '2026-11-19T05:00:00Z'
        $resolved.Result.checkId | Should -Be 'DEPLOY.T5'
        $resolved.Result.status | Should -Be 'Warning'
        $resolved.Result.message | Should -Match 'this resume leaves T5 out too'
        $resolved.Result.remediation | Should -Match '"t5Enabled": false'
        InModuleScope DbHubDemo -Parameters @{ Result = @($resolved.Result) } { Test-DemoT5LeftOut -Result $Result } | Should -BeTrue
        InModuleScope DbHubDemo -Parameters @{ Config = $resolved.Config } { New-DemoT5OffResult -Config $Config } | Should -BeNullOrEmpty -Because 'T5 is left out of this run, not off in the configuration'
    }

    It 'keeps T5 on when this run deploys the template, the account exists or can''t be read, or nothing is recorded' {
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:recordedState } { Resolve-DemoT5LeftOut -Config $Config -State $State -TemplateRuns } | Should -BeNullOrEmpty
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = [pscustomobject]@{ Stage = 'T3'; T5Refused = ''; Tags = @{ deploymentId = 'abc123' } } } { Resolve-DemoT5LeftOut -Config $Config -State $State } | Should -BeNullOrEmpty
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Override @{ t5Enabled = $false }); State = $script:recordedState } { Resolve-DemoT5LeftOut -Config $Config -State $State } | Should -BeNullOrEmpty
        $script:t5.Account = New-AccountJson
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:recordedState } { Resolve-DemoT5LeftOut -Config $Config -State $State } | Should -BeNullOrEmpty
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT5State -MockWith { [pscustomobject]@{ Names = $null; Exists = $false; State = 'Unknown'; FreeTier = $false; Account = $null; Error = 'throttled' } }
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:recordedState } { Resolve-DemoT5LeftOut -Config $Config -State $State } | Should -BeNullOrEmpty
        InModuleScope DbHubDemo -Parameters @{ Result = @(New-DemoResult -CheckId 'DEPLOY.T5.FREETIER' -Area 't5' -Target 'T5' -Status 'Warning' -Message 'free tier') } { Test-DemoT5LeftOut -Result $Result } | Should -BeFalse
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

    It 'passes a missing container between sessions once it exists only during a session, and warns about it while sqlvm01 runs (2026-11-19)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ T5Container = 'Session'; Tags = @{ deploymentId = 'abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { $script:power }
        $script:t5.Account = New-AccountJson -FreeTier 'false'
        $script:t5.Container = $false
        $script:power = 'PowerState/deallocated'
        $between = @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123') | Where-Object checkId -EQ 'T5.CONTAINER'
        $between.status | Should -Be 'Pass'
        $between.message | Should -Match 'isn''t there now, because it exists only during a session'
        $script:power = 'PowerState/running'
        $running = @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123') | Where-Object checkId -EQ 'T5.CONTAINER'
        $running.status | Should -Be 'Warning'
        $running.remediation | Should -Match 'start-demo\.ps1'
        # There while the demo is stopped: its throughput bills until a stop deletes it.
        $script:t5.Container = $true
        $script:power = 'PowerState/deallocated'
        $left = @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123') | Where-Object checkId -EQ 'T5.CONTAINER'
        $left.status | Should -Be 'Warning'
        $left.message | Should -Match 'while the demo is stopped'
        $left.remediation | Should -Match 'stop-demo\.ps1'
        $script:t5.Account = New-AccountJson -FreeTier 'true'
        (@(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123') | Where-Object checkId -EQ 'T5.CONTAINER').status | Should -Be 'Pass' -Because 'the free tier makes it cost nothing'
    }

    It 'fails a missing container when nothing creates it for a session: AlwaysOn, or a demo deployed before the lifecycle' {
        foreach ($recorded in 'AlwaysOn', '') {
            Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ T5Container = $recorded; Tags = @{ deploymentId = 'abc123' } } }.GetNewClosure()
            $script:t5.Container = $false
            $container = @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123') | Where-Object checkId -EQ 'T5.CONTAINER'
            $container.status | Should -Be 'Fail' -Because $recorded
            $container.remediation | Should -Match 'start-demo\.ps1 or \./scripts/deploy\.ps1'
        }
    }

    It 'reports the container''s lifecycle with -IncludeLifecycle, each case with its fix' {
        $script:t5.Account = New-AccountJson -FreeTier 'false'
        $cases = @(
            @{ Recorded = 'Session'; Status = 'Pass'; Message = 'exists only during a session'; Fix = '^$' }
            @{ Recorded = 'AlwaysOn'; Status = 'Warning'; Message = 'stays between sessions, so its 400 RU/s bill around the clock'; Fix = 'grant-safety-stop\.ps1' }
            @{ Recorded = ''; Status = 'Warning'; Message = 'deployed before 2026-11-19'; Fix = 'deploy\.ps1' }
        )
        # A recorded Session is read as stop-demo.ps1 would decide it (review of ab91ee5): here the control's role can.
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT5ContainerLifecycle -MockWith { [pscustomobject]@{ Lifecycle = 'Session'; Recorded = 'Session'; Changed = $false; Known = $true; Why = ''; RoleName = 'DbHub Demo Activity Operator'; Mode = 'Control'; AutoDelete = $true; Price = 'Session' } }
        foreach ($case in $cases) {
            Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ T5Container = $case.Recorded; Tags = @{ deploymentId = 'abc123' } } }.GetNewClosure()
            Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { 'PowerState/running' }
            $results = @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123' -IncludeLifecycle)
            $results.checkId | Should -Contain 'T5.LIFECYCLE'
            $lifecycle = $results | Where-Object checkId -EQ 'T5.LIFECYCLE'
            $lifecycle.status | Should -Be $case.Status -Because $case.Recorded
            $lifecycle.message | Should -Match $case.Message
            [string]$lifecycle.remediation | Should -Match $case.Fix
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Resolve-DemoT5ContainerLifecycle -Times 1 -Exactly -ParameterFilter { $Purpose -eq 'Stop' -and [bool]$PesterBoundParameters['WhatIf'] } -Because 'validate.ps1 writes nothing'
        # With no session-control role and no nightly safety stop that deletes it, a Warning that names stop-demo.ps1.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ T5Container = 'Session'; Tags = @{ deploymentId = 'abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT5ContainerLifecycle -MockWith { [pscustomobject]@{ Lifecycle = 'Session'; Recorded = 'Session'; Changed = $false; Known = $true; Why = 'id-dbhub-demo-control holds no role at rg-dbhub-demo yet'; RoleName = 'DbHub Demo Activity Operator'; Mode = 'NoRole'; AutoDelete = $false; Price = 'AlwaysOn' } }
        $manual = @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123' -IncludeLifecycle) | Where-Object checkId -EQ 'T5.LIFECYCLE'
        $manual.status | Should -Be 'Warning'
        $manual.message | Should -Match 'deleted only when you run \./scripts/stop-demo\.ps1'
        $manual.evidence['autoDelete'] | Should -BeFalse
        $script:t5.Account = New-AccountJson -FreeTier 'true'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ T5Container = 'AlwaysOn'; Tags = @{ deploymentId = 'abc123' } } }
        (@(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123' -IncludeLifecycle) | Where-Object checkId -EQ 'T5.LIFECYCLE').status | Should -Be 'Pass'
        @(Test-DemoT5 -Config (New-TestConfig) -DeploymentId 'abc123').checkId | Should -Not -Contain 'T5.LIFECYCLE'
    }
}

Describe 'T5''s container, only during a session (2026-11-19)' {
    BeforeEach {
        Initialize-T5AzMock
        $script:t5State = [pscustomobject]@{
            Names    = [pscustomobject]@{ Enabled = $true; ResourceGroup = 'rg-dbhub-demo'; AccountName = 'cosmos01-abc123'; AccountId = $script:accountId; DatabaseName = 'contosocare'; ContainerName = 'patient-events'; Throughput = 400 }
            Exists   = $true
            State    = 'Succeeded'
            FreeTier = $false
            Account  = $null
            Error    = ''
        }
    }

    It 'creates a missing container with the template''s definition and the group''s own tags, then waits until Azure shows it' {
        $script:t5.Container = $false
        $created = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:t5State } { New-DemoT5Container -Config $Config -State $State -Confirm:$false }
        $created.checkId | Should -Be 'START.T5.CONTAINER'
        $created.status | Should -Be 'Pass'
        $created.message | Should -Match 'wasn''t there, so it was created, with 400 RU/s'
        $created.evidence['action'] | Should -Be 'create'
        $script:t5.Puts | Should -Be 1
        $body = $script:t5.LastBody | ConvertFrom-Json -AsHashtable
        $body['properties']['resource']['id'] | Should -Be 'patient-events'
        $body['properties']['resource']['partitionKey']['paths'] | Should -Be @('/patientId')
        $body['properties']['resource']['partitionKey']['version'] | Should -Be 2
        $body['properties']['resource']['indexingPolicy']['excludedPaths'].path | Should -Contain '/payload/?'
        $body['properties']['options']['throughput'] | Should -Be 400
        $body['tags']['solution'] | Should -Be 'dbhub-demo'
        $body['tags'].Contains('DbHubStage') | Should -BeFalse -Because 'only the demo''s own tags go on the container, never deploy.ps1''s state'
    }

    It 'leaves a container that''s there alone, and sends nothing' {
        $present = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:t5State } { New-DemoT5Container -Config $Config -State $State -CheckId 'DEPLOY.T5.CONTAINER' -Confirm:$false }
        $present.checkId | Should -Be 'DEPLOY.T5.CONTAINER'
        $present.status | Should -Be 'Pass'
        $present.evidence['action'] | Should -Be 'none'
        @($script:azCalls | Where-Object { $_ -notlike 'rest --method get *' }) | Should -BeNullOrEmpty
    }

    It 'tries again while Azure still deletes the last container with its name, and fails with the fix on another error' {
        $script:t5.Container = $false
        $script:t5.PutErrors.Add('ERROR: (Conflict) Operation not allowed: the resource is being deleted. Status: 409')
        $created = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:t5State } { New-DemoT5Container -Config $Config -State $State -Confirm:$false }
        $created.status | Should -Be 'Pass'
        $created.evidence['attempts'] | Should -Be 2
        $script:t5.Container = $false
        $script:t5.PutErrors.Add('ERROR: (AuthorizationFailed) The client does not have authorization to perform action ''Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write''.')
        $failed = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:t5State } { New-DemoT5Container -Config $Config -State $State -Confirm:$false }
        $failed.status | Should -Be 'Fail'
        $failed.message | Should -Match 'AuthorizationFailed'
        $failed.remediation | Should -Match 'start-demo\.ps1'
    }

    It 'creates nothing for an account that isn''t there' {
        $script:t5State.Exists = $false
        $none = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:t5State } { New-DemoT5Container -Config $Config -State $State -Confirm:$false }
        $none.status | Should -Be 'Not selected'
        @($script:azCalls) | Should -BeNullOrEmpty
    }

    It 'deletes the container at a stop when a session can create it again, and says only the endpoint and zone bill then' {
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT5ContainerLifecycle -MockWith { [pscustomobject]@{ Lifecycle = 'Session'; Recorded = 'Session'; Changed = $false; Known = $true; Why = ''; RoleName = 'DbHub Demo Activity Operator' } }
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:t5State } { Invoke-DemoT5ContainerStop -Config $Config -State $State -DeploymentState ([pscustomobject]@{ T5Container = 'Session' }) -Confirm:$false }
        $stop.checkId | Should -Be 'STOP.T5'
        $stop.status | Should -Be 'Pass'
        $stop.message | Should -Match 'was deleted'
        $stop.message | Should -Match 'private endpoint and private DNS zone'
        $script:t5.Deletes | Should -Be 1
        $script:t5.Container | Should -BeFalse
        # A second stop finds nothing to delete.
        $again = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:t5State } { Invoke-DemoT5ContainerStop -Config $Config -State $State -DeploymentState ([pscustomobject]@{ T5Container = 'Session' }) -Confirm:$false }
        $again.status | Should -Be 'Pass'
        $again.message | Should -Match 'isn''t there'
    }

    It 'keeps the container, and deletes nothing, while Run all couldn''t create it again; a Warning with the grant command, a Pass on the free tier' {
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT5ContainerLifecycle -MockWith { [pscustomobject]@{ Lifecycle = 'AlwaysOn'; Recorded = 'AlwaysOn'; Changed = $false; Known = $true; Why = 'the session control''s custom role "DbHub Demo Activity Operator" doesn''t have Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write yet'; RoleName = 'DbHub Demo Activity Operator' } }
        $stop = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:t5State } { Invoke-DemoT5ContainerStop -Config $Config -State $State -DeploymentState ([pscustomobject]@{ T5Container = 'AlwaysOn' }) -Confirm:$false }
        $stop.status | Should -Be 'Warning'
        $stop.message | Should -Match 'was kept: it stays between sessions'
        $stop.message | Should -Match 'containers/write'
        $stop.remediation | Should -Match 'grant-safety-stop\.ps1'
        $script:t5.Deletes | Should -Be 0
        $script:t5State.FreeTier = $true
        $free = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $script:t5State } { Invoke-DemoT5ContainerStop -Config $Config -State $State -DeploymentState ([pscustomobject]@{ T5Container = 'AlwaysOn' }) -Confirm:$false }
        $free.status | Should -Be 'Pass'
        $free.message | Should -Match 'costs nothing on the free tier'
        (InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT5ContainerStop -Config $Config -State $null -Confirm:$false }).status | Should -Be 'Not selected'
    }
}

Describe 'Update-DemoT5ContainerLifecycle: the status page says the roles were updated before a session relies on them' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ T5Container = ''; Tags = @{ deploymentId = 'abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT5State -MockWith { [pscustomobject]@{ Names = $null; Exists = $true; State = 'Succeeded'; FreeTier = $false; Account = $null; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT5ContainerLifecycle -MockWith { [pscustomobject]@{ Lifecycle = 'Session'; Recorded = ''; Changed = $true; Known = $true; Why = ''; RoleName = 'DbHub Demo Activity Operator (dbhubc6)' } }
        $script:rows = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { $script:rows.Add(('{0}|{1}|{2}' -f (@($PesterBoundParameters['Id']) -join ','), [string]$PesterBoundParameters['Status'], [string]$PesterBoundParameters['Message'])) }
        $script:containerActions = @('read', 'write', 'delete' | ForEach-Object { 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/' + $_ })
    }

    It 'names the container actions this run added to both roles, on the result and the T5.Lifecycle row' {
        $prior = @(
            New-DemoResult -CheckId 'CONTROL.ROLE.DEFINITION' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message 'updated' -Evidence ([ordered]@{ role = 'DbHub Demo Activity Operator (dbhubc6)'; added = $script:containerActions })
            New-DemoResult -CheckId 'SAFETYSTOP.ROLE' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'updated' -Evidence ([ordered]@{ role = 'DbHub Demo Safety Stop'; added = @($script:containerActions[0], $script:containerActions[2]) })
            New-DemoResult -CheckId 'CONTROL.ROLE.WRITER' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message 'kept' -Evidence ([ordered]@{ role = 'DbHub Demo Session Writer'; added = @('Microsoft.KeyVault/vaults/secrets/write') })
        )
        $result = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Prior = $prior } { Update-DemoT5ContainerLifecycle -Config $Config -ProgressPath 'progress.json' -PriorResult $Prior -Confirm:$false })[0]
        $result.checkId | Should -Be 'DEPLOY.T5.LIFECYCLE'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'exists only during a session from now on'
        $result.message | Should -Match 'This run updated the roles first: "DbHub Demo Activity Operator \(dbhubc6\)" gained read, write, delete; "DbHub Demo Safety Stop" gained read, delete \(the container''s actions\)\.$'
        $script:rows[-1] | Should -Match '^T5\.Lifecycle\|Pass\|.*This run updated the roles first'
    }

    It 'adds nothing when this run added no container action, and says when the run left T5 out' {
        $prior = @(New-DemoResult -CheckId 'CONTROL.ROLE.DEFINITION' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message 'kept' -Evidence ([ordered]@{ role = 'DbHub Demo Activity Operator' }))
        $result = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Prior = $prior } { Update-DemoT5ContainerLifecycle -Config $Config -PriorResult $Prior -Confirm:$false })[0]
        $result.message | Should -Not -Match 'updated the roles'
        $leftOut = New-TestConfig -Override @{ t5Enabled = $false; t5LeftOut = 'ServiceUnavailable: high demand' }
        $off = @(InModuleScope DbHubDemo -Parameters @{ Config = $leftOut } { Update-DemoT5ContainerLifecycle -Config $Config -Confirm:$false })[0]
        $off.status | Should -Be 'Not selected'
        $off.message | Should -Match 'left out of this run because Azure didn''t create its account'
    }
}

Describe 'Resolve-DemoT5ContainerLifecycle: a stop deletes the container only when a session can create it again' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:roleActions = @('Microsoft.Compute/virtualMachines/read', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/read', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/delete')
        $script:held = $true
        $script:roleThrows = $false
        $script:recorded = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlRoleId -MockWith { if ($script:roleThrows) { throw 'The role definitions couldn''t be read: timeout' }; [pscustomobject]@{ Id = 'abababab-abab-abab-abab-abababababab'; Actions = @($script:roleActions) } }
        $script:other = $false
        $script:principal = '12121212-1212-1212-1212-121212121212'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlPrincipalId -MockWith { $script:principal }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoActivityControlAssignment -MockWith { [pscustomobject]@{ Exists = $script:held; Other = $script:other; Missing = $false; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentStateLocked -MockWith { $script:recorded.Add([string]$Value['T5Container']) }
        # Whether the nightly safety stop deletes the container (review of ab91ee5): not by default, as in a Contributor's run.
        $script:safetyDeletes = $false
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT5SafetyStopDeletes -MockWith { $script:safetyDeletes }
        function Resolve-Lifecycle([string] $Purpose, [string] $Recorded) {
            InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Purpose = $Purpose; State = [pscustomobject]@{ T5Container = $Recorded } } { Resolve-DemoT5ContainerLifecycle -Config $Config -Purpose $Purpose -State $State -Confirm:$false }
        }
    }

    It 'deploy.ps1 records Session when the control''s role has the container actions and is held at the demo group' {
        $lifecycle = Resolve-Lifecycle 'Deploy' ''
        $lifecycle.Lifecycle | Should -Be 'Session'
        $lifecycle.Changed | Should -BeTrue
        $script:recorded | Should -Be @('Session')
    }

    It 'deploy.ps1 records AlwaysOn, and says which action is missing, when the role lacks them (a non-Owner''s run)' {
        $script:roleActions = @('Microsoft.Compute/virtualMachines/read')
        $lifecycle = Resolve-Lifecycle 'Deploy' 'Session'
        $lifecycle.Lifecycle | Should -Be 'AlwaysOn'
        $lifecycle.Why | Should -Match 'containers/read, Microsoft\.DocumentDB/databaseAccounts/sqlDatabases/containers/write'
        $script:recorded | Should -Be @('AlwaysOn')
        $script:roleActions = @('Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/read', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/delete')
        $script:held = $false
        $script:other = $true
        $another = Resolve-Lifecycle 'Deploy' ''
        $another.Lifecycle | Should -Be 'AlwaysOn' -Because 'a control that holds another role at the group could start a session that can''t create the container'
        $another.Mode | Should -Be 'Lacking'
        $another.Why | Should -Match 'holds another role at rg-dbhub-demo'
    }

    It 'deploy.ps1 records Session when the session control holds no role at all (fix 1): Run all can''t start a session, and start-demo.ps1 creates the container with your own rights' {
        $script:held = $false
        $script:roleActions = @('Microsoft.Compute/virtualMachines/read')
        foreach ($recorded in '', 'AlwaysOn', 'Session') {
            $script:recorded.Clear()
            $none = Resolve-Lifecycle 'Deploy' $recorded
            $none.Lifecycle | Should -Be 'Session' -Because "a Contributor's run (recorded: '$recorded'), whose control has no role, even one without the container's actions"
            $none.Mode | Should -Be 'NoRole'
            $none.Why | Should -Match 'holds no role at rg-dbhub-demo yet'
        }
        $script:principal = ''
        $missing = Resolve-Lifecycle 'Deploy' ''
        $missing.Lifecycle | Should -Be 'Session'
        $missing.Mode | Should -Be 'NoRole'
        $missing.Why | Should -Match 'doesn''t exist yet'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoActivityControlAssignment -Times 3 -Exactly -Because 'an identity that doesn''t exist holds nothing, so its assignments aren''t read'
        # A stop keeps Session, and a grant turns AlwaysOn into Session.
        $script:principal = '12121212-1212-1212-1212-121212121212'
        (Resolve-Lifecycle 'Stop' 'Session').Lifecycle | Should -Be 'Session'
        (Resolve-Lifecycle 'Grant' 'AlwaysOn').Lifecycle | Should -Be 'Session'
    }

    It 'keeps the tag Session with no role, so stop-demo.ps1 deletes the container, but prices it all month unless the nightly safety stop deletes it too (review of ab91ee5)' {
        $script:held = $false
        $manual = Resolve-Lifecycle 'Deploy' ''
        $manual.Lifecycle | Should -Be 'Session' -Because 'stop-demo.ps1 deletes it only while the tag says Session'
        $manual.AutoDelete | Should -BeFalse
        $manual.Price | Should -Be 'AlwaysOn' -Because 'nothing automatic deletes it: the control has no role, and the nightly safety stop can''t'
        $script:safetyDeletes = $true
        $nightly = Resolve-Lifecycle 'Deploy' ''
        $nightly.AutoDelete | Should -BeTrue
        $nightly.Price | Should -Be 'Session'
        $script:held = $true
        $script:safetyDeletes = $false
        $control = Resolve-Lifecycle 'Deploy' ''
        $control.Mode | Should -Be 'Control'
        $control.AutoDelete | Should -BeTrue
        $control.Price | Should -Be 'Session'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoT5SafetyStopDeletes -Times 2 -Exactly -Because 'only a control with no role needs the nightly safety stop'
    }

    It 'says on the status page which mode applies and why, and names grant-safety-stop.ps1 where it helps' {
        $script:held = $false
        $noRole = Resolve-Lifecycle 'Deploy' ''
        # Review of ab91ee5: with no role and no nightly safety stop that deletes it, only stop-demo.ps1 does.
        $said = InModuleScope DbHubDemo -Parameters @{ Lifecycle = $noRole } { Get-DemoT5LifecycleResult -Lifecycle $Lifecycle -ConfigPath 'config/demo.config.json' }
        $said.status | Should -Be 'Warning'
        $said.evidence['mode'] | Should -Be 'NoRole'
        $said.evidence['price'] | Should -Be 'AlwaysOn'
        $said.message | Should -Match '^T5''s container is deleted only when you run \./scripts/stop-demo\.ps1'
        $said.message | Should -Match 'bill around the clock until the next stop-demo\.ps1, and the estimate prices them all month'
        $said.remediation | Should -Match '^Run \./scripts/stop-demo\.ps1 after each session\. Or an Owner runs, once: \./scripts/grant-safety-stop\.ps1'
        (InModuleScope DbHubDemo -Parameters @{ Lifecycle = $noRole } { Get-DemoT5LifecycleResult -Lifecycle $Lifecycle -FreeTier $true }).status | Should -Be 'Pass' -Because 'it costs nothing on the free tier'
        $script:safetyDeletes = $true
        $noRole = Resolve-Lifecycle 'Deploy' ''
        $said = InModuleScope DbHubDemo -Parameters @{ Lifecycle = $noRole } { Get-DemoT5LifecycleResult -Lifecycle $Lifecycle -ConfigPath 'config/demo.config.json' }
        $said.status | Should -Be 'Pass'
        $said.message | Should -Match 'start-demo\.ps1 creates it with your own rights, and stop-demo\.ps1 and the nightly safety stop delete it'
        $said.message | Should -Match 'Run all can''t start a session'
        $said.message | Should -Match 'grant-safety-stop\.ps1'
        $script:safetyDeletes = $false
        $script:held = $true
        $script:roleActions = @('Microsoft.Compute/virtualMachines/read')
        $lacking = Resolve-Lifecycle 'Deploy' ''
        $warned = InModuleScope DbHubDemo -Parameters @{ Lifecycle = $lacking } { Get-DemoT5LifecycleResult -Lifecycle $Lifecycle -ConfigPath 'config/demo.config.json' }
        $warned.status | Should -Be 'Warning'
        $warned.evidence['mode'] | Should -Be 'Lacking'
        $warned.message | Should -Match 'stays between sessions'
        $warned.remediation | Should -Match 'grant-safety-stop\.ps1'
        $script:roleActions = @('Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/read', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/delete')
        $control = Resolve-Lifecycle 'Deploy' ''
        $passed = InModuleScope DbHubDemo -Parameters @{ Lifecycle = $control } { Get-DemoT5LifecycleResult -Lifecycle $Lifecycle }
        $passed.status | Should -Be 'Pass'
        $passed.evidence['mode'] | Should -Be 'Control'
        $passed.message | Should -Match 'Run all create it'
    }

    It 'grant-safety-stop.ps1 turns AlwaysOn into Session, but leaves an environment deployed before the lifecycle to deploy.ps1' {
        (Resolve-Lifecycle 'Grant' 'AlwaysOn').Lifecycle | Should -Be 'Session'
        $before = Resolve-Lifecycle 'Grant' ''
        $before.Lifecycle | Should -Be ''
        $before.Changed | Should -BeFalse
    }

    It 'stop-demo.ps1 turns Session into AlwaysOn when the role can''t any more, and never turns anything into Session' {
        (Resolve-Lifecycle 'Stop' 'AlwaysOn').Lifecycle | Should -Be 'AlwaysOn'
        (Resolve-Lifecycle 'Stop' '').Lifecycle | Should -Be ''
        $script:roleActions = @('Microsoft.Compute/virtualMachines/read')
        (Resolve-Lifecycle 'Stop' 'Session').Lifecycle | Should -Be 'AlwaysOn'
    }

    It 'keeps what''s recorded when the role can''t be read' {
        $script:roleThrows = $true
        foreach ($purpose in 'Deploy', 'Stop') {
            $kept = Resolve-Lifecycle $purpose 'Session'
            $kept.Lifecycle | Should -Be 'Session' -Because $purpose
            $kept.Known | Should -BeFalse
        }
        (Resolve-Lifecycle 'Deploy' '').Lifecycle | Should -Be 'AlwaysOn'
    }
}

Describe 'Get-DemoT5CostLifecycle: how the cost estimate prices T5''s throughput (2026-11-19, the coordinator''s gap fix)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:actions = @('read', 'write', 'delete' | ForEach-Object { 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/' + $_ })
        # A new environment: no session control yet.
        $script:control = [pscustomobject]@{ Mode = 'NoRole'; Why = 'the session control''s identity id-dbhub-demo-control doesn''t exist yet'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $false; Lacking = $script:actions; IdentityExists = $false; HoldsRole = $false; HoldsOther = $false }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT5ControlRoleState -MockWith { $script:control }
        # Whether the nightly safety stop deletes the container (review of ab91ee5): not by default.
        $script:safetyDeletes = $false
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT5SafetyStopDeletes -MockWith { $script:safetyDeletes }
        $script:owner = [pscustomobject]@{ CanDefine = $true; CanAssign = $true; Error = '' }
        $script:contributor = [pscustomobject]@{ CanDefine = $false; CanAssign = $false; Error = '' }
        function Get-Priced([object] $State, [object] $Permission, [switch] $ThisRunDeploys) {
            InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $State; Permission = $Permission; Deploys = [bool]$ThisRunDeploys } { Get-DemoT5CostLifecycle -Config $Config -State $State -Permission $Permission -ThisRunDeploys:$Deploys }
        }
        $script:new = [pscustomobject]@{ Exists = $false; T5Container = '' }
        # An environment from main: deployed before 2026-11-19, so no tag, and its control holds its role without the
        # container's actions.
        $script:fromMain = [pscustomobject]@{ Exists = $true; T5Container = '' }
        $script:older = [pscustomobject]@{ Mode = 'Lacking'; Why = 'the session control''s custom role "DbHub Demo Activity Operator" doesn''t have them yet'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = $script:actions; IdentityExists = $true; HoldsRole = $true; HoldsOther = $false }
    }

    It 'prices a new environment session-only for an Owner, and all month for a Contributor, whose control gets no role and whose container only stop-demo.ps1 deletes (review of ab91ee5)' {
        Get-Priced -State $script:new -Permission $script:owner -ThisRunDeploys | Should -Be 'Session'
        Get-Priced -State $script:new -Permission $script:contributor -ThisRunDeploys | Should -Be 'AlwaysOn'
        # Where the nightly safety stop deletes the container already, a control with no role is session-only (fix 1).
        $script:safetyDeletes = $true
        Get-Priced -State $script:new -Permission $script:contributor -ThisRunDeploys | Should -Be 'Session'
    }

    It 'prices an update from main AlwaysOn when a Contributor runs it, since its control keeps a role without the container''s actions, and Session for an Owner, whose run updates the role' {
        $script:control = $script:older
        Get-Priced -State $script:fromMain -Permission $script:contributor -ThisRunDeploys | Should -Be 'AlwaysOn'
        Get-Priced -State $script:fromMain -Permission $script:owner -ThisRunDeploys | Should -Be 'Session'
        # Someone who can assign roles but not write them (a Role Based Access Control Administrator) can't add the actions.
        Get-Priced -State $script:fromMain -Permission ([pscustomobject]@{ CanDefine = $false; CanAssign = $true; Error = '' }) -ThisRunDeploys | Should -Be 'AlwaysOn'
    }

    It 'prices an update from main whose session control never got a role (a Contributor deployed it) by what deletes the container: the nightly safety stop, or only stop-demo.ps1' {
        $script:control = [pscustomobject]@{ Mode = 'NoRole'; Why = 'id-dbhub-demo-control holds no role at rg-dbhub-demo yet'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = $script:actions; IdentityExists = $true; HoldsRole = $false; HoldsOther = $false }
        Get-Priced -State $script:fromMain -Permission $script:contributor -ThisRunDeploys | Should -Be 'AlwaysOn'
        $script:safetyDeletes = $true
        Get-Priced -State $script:fromMain -Permission $script:contributor -ThisRunDeploys | Should -Be 'Session'
        $script:safetyDeletes = $false
        Get-Priced -State $script:fromMain -Permission $script:owner -ThisRunDeploys | Should -Be 'Session' -Because 'an Owner''s run assigns the control its role'
    }

    It 'prices a new environment AlwaysOn only for a deployer who can assign the shared role but not add its actions, where another environment''s older code left it without them' {
        $script:control = [pscustomobject]@{ Mode = 'NoRole'; Why = 'the session control''s identity doesn''t exist yet'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = $script:actions; IdentityExists = $false; HoldsRole = $false; HoldsOther = $false }
        Get-Priced -State $script:new -Permission ([pscustomobject]@{ CanDefine = $false; CanAssign = $true; Error = '' }) -ThisRunDeploys | Should -Be 'AlwaysOn'
        Get-Priced -State $script:new -Permission $script:contributor -ThisRunDeploys | Should -Be 'AlwaysOn' -Because 'with no role and no nightly safety stop, only stop-demo.ps1 deletes the container'
        Get-Priced -State $script:new -Permission $script:owner -ThisRunDeploys | Should -Be 'Session'
    }
    It 'prices a control whose role already has the container''s actions Session, and one that holds another role AlwaysOn, for any deployer' {
        $script:control = [pscustomobject]@{ Mode = 'Control'; Why = ''; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = @(); IdentityExists = $true; HoldsRole = $true; HoldsOther = $false }
        Get-Priced -State $script:fromMain -Permission $script:contributor -ThisRunDeploys | Should -Be 'Session'
        $script:control = [pscustomobject]@{ Mode = 'Lacking'; Why = 'it holds another role'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = @(); IdentityExists = $true; HoldsRole = $false; HoldsOther = $true }
        Get-Priced -State $script:fromMain -Permission $script:contributor -ThisRunDeploys | Should -Be 'AlwaysOn'
        Get-Priced -State $script:fromMain -Permission $script:owner -ThisRunDeploys | Should -Be 'Session' -Because 'an Owner''s run assigns the control its own role'
    }

    It 'prices an Owner''s update AlwaysOn when the control''s approved role no longer has the container''s actions, since the run writes only the approved ones' {
        $script:control = $script:older
        $saved = InModuleScope DbHubDemo { $script:ActivityControlRoleActions }
        try {
            InModuleScope DbHubDemo { $script:ActivityControlRoleActions = @($script:ActivityControlRoleActions | Where-Object { $_ -notlike 'Microsoft.DocumentDB/*' }) }
            Get-Priced -State $script:fromMain -Permission $script:owner -ThisRunDeploys | Should -Be 'AlwaysOn'
            $script:control = [pscustomobject]@{ Mode = 'NoRole'; Why = 'the session control''s identity doesn''t exist yet'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $false; Lacking = $script:actions; IdentityExists = $false; HoldsRole = $false; HoldsOther = $false }
            $script:safetyDeletes = $true
            Get-Priced -State $script:new -Permission $script:contributor -ThisRunDeploys | Should -Be 'Session' -Because 'with no role at all, the person''s own scripts create the container, and the nightly safety stop deletes it'
            $script:safetyDeletes = $false
            $script:control = $script:older
        }
        finally {
            InModuleScope DbHubDemo -Parameters @{ Saved = $saved } { $script:ActivityControlRoleActions = $Saved }
        }
        Get-Priced -State $script:fromMain -Permission $script:owner -ThisRunDeploys | Should -Be 'Session'
    }
    It 'prices a recorded Session by what deletes the container outside deploy.ps1 too, and what it can''t read AlwaysOn (fail safe; review of ab91ee5)' {
        $session = [pscustomobject]@{ Exists = $true; T5Container = 'Session' }
        # start-demo.ps1, estimate-cost.ps1, and validate.ps1: the session control's role deletes it, or nothing automatic does.
        $script:control = [pscustomobject]@{ Mode = 'Control'; Why = ''; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = @(); IdentityExists = $true; HoldsRole = $true; HoldsOther = $false }
        Get-Priced -State $session -Permission $null | Should -Be 'Session'
        $script:control = [pscustomobject]@{ Mode = 'NoRole'; Why = 'id-dbhub-demo-control holds no role at rg-dbhub-demo yet'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = $script:actions; IdentityExists = $true; HoldsRole = $false; HoldsOther = $false }
        Get-Priced -State $session -Permission $null | Should -Be 'AlwaysOn' -Because 'only stop-demo.ps1 deletes it'
        Get-Priced -State $session -Permission $script:contributor -ThisRunDeploys | Should -Be 'AlwaysOn' -Because 'a recorded Session is read again in deploy.ps1''s preflight too'
        $script:safetyDeletes = $true
        Get-Priced -State $session -Permission $null | Should -Be 'Session'
        $script:control = [pscustomobject]@{ Mode = 'Unknown'; Why = 'the role couldn''t be read'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $false; Lacking = $script:actions; IdentityExists = $false; HoldsRole = $false; HoldsOther = $false }
        Get-Priced -State $session -Permission $null | Should -Be 'AlwaysOn'
        Get-Priced -State $script:new -Permission $script:owner -ThisRunDeploys | Should -Be 'AlwaysOn'
        # No tag in an existing environment, and no environment yet.
        Get-Priced -State $script:fromMain -Permission $null | Should -Be 'AlwaysOn'
        Get-Priced -State $script:new -Permission $null | Should -Be 'Session'
    }

    It 'says why with -Detail, and ManualDeleteOnly only where nothing automatic deletes the container while stop-demo.ps1 does (the re-review of 0590bbe)' {
        $detail = {
            param([object] $State, [object] $Permission, [bool] $Deploys)
            InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $State; Permission = $Permission; Deploys = $Deploys } { Get-DemoT5CostLifecycle -Config $Config -State $State -Permission $Permission -ThisRunDeploys:$Deploys -Detail }
        }
        $reason = { param([object] $Answer) '{0}/{1}/{2}' -f $Answer.Lifecycle, $Answer.Reason, $Answer.ManualDeleteOnly }
        # A Contributor's update of an environment from main whose session control never got a role, and that environment
        # afterwards (its recorded Session, which start-demo.ps1 reads): only stop-demo.ps1 deletes the container.
        $script:control = [pscustomobject]@{ Mode = 'NoRole'; Why = 'id-dbhub-demo-control holds no role at rg-dbhub-demo yet'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = $script:actions; IdentityExists = $true; HoldsRole = $false; HoldsOther = $false }
        & $reason (& $detail $script:fromMain $script:contributor $true) | Should -Be 'AlwaysOn/NoAutoDelete/True'
        & $reason (& $detail ([pscustomobject]@{ Exists = $true; T5Container = 'Session' }) $null $false) | Should -Be 'AlwaysOn/NoAutoDelete/True'
        & $reason (& $detail $script:new $script:contributor $true) | Should -Be 'AlwaysOn/NoAutoDelete/True'
        & $reason (& $detail $script:fromMain $script:owner $true) | Should -Be 'Session/Session/False'
        # All month for another reason: no stop deletes the container, or the environment predates its lifecycle, or the
        # role can't be read.
        $script:control = $script:older
        & $reason (& $detail $script:fromMain $script:contributor $true) | Should -Be 'AlwaysOn/Lacking/False'
        & $reason (& $detail ([pscustomobject]@{ Exists = $true; T5Container = 'Session' }) $null $false) | Should -Be 'AlwaysOn/Lacking/False'
        & $reason (& $detail $script:fromMain $null $false) | Should -Be 'AlwaysOn/NotRecorded/False'
        $script:control = [pscustomobject]@{ Mode = 'Unknown'; Why = 'the role couldn''t be read'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $false; Lacking = $script:actions; IdentityExists = $false; HoldsRole = $false; HoldsOther = $false }
        & $reason (& $detail $script:new $script:owner $true) | Should -Be 'AlwaysOn/Unknown/False'
        & $reason (& $detail $script:new $null $false) | Should -Be 'Session/NoEnvironment/False'
        # Without -Detail, the lifecycle alone, as before.
        Get-Priced -State $script:new -Permission $null | Should -BeOfType [string]
    }
}

Describe 'Update-DemoT5ContainerLifecycle: the month''s worst case again when the run records what preflight didn''t price' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ T5Container = ''; Tags = @{ deploymentId = 'abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT5State -MockWith { [pscustomobject]@{ Names = $null; Exists = $true; State = 'Succeeded'; FreeTier = $false; Account = $null; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT5ContainerLifecycle -MockWith { [pscustomobject]@{ Lifecycle = 'AlwaysOn'; Recorded = ''; Changed = $true; Known = $true; Why = 'the session control''s custom role "DbHub Demo Activity Operator" doesn''t have Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write yet'; RoleName = 'DbHub Demo Activity Operator'; Mode = 'Lacking' } }
        function New-Priced([string] $Lifecycle, [double] $Worst) {
            New-DemoResult -CheckId 'PREFLIGHT.COST.MONTHLY' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'Within the ceiling.' -Evidence ([ordered]@{ t5ContainerLifecycle = $Lifecycle; t5AlwaysOnExtraMonthly = 22.32; monthlyWorstCase = $Worst })
        }
        function Update-Lifecycle([object[]] $Prior, [double] $Ceiling = 415) {
            $config = New-TestConfig
            $config['monthlyCeilingUsd'] = $Ceiling
            @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Prior = $Prior } { Update-DemoT5ContainerLifecycle -Config $Config -ConfigPath './config/demo.config.json' -PriorResult $Prior -Confirm:$false })[0]
        }
    }

    It 'adds the worst case, over the ceiling, with the ceiling to raise' {
        $over = Update-Lifecycle -Prior @(New-Priced 'Session' 400.00)
        $over.status | Should -Be 'Warning'
        $over.message | Should -Match 'Preflight priced its throughput for a session''s hours only, so the month''s worst case is about 22\.32 USD more than its estimate: 422\.32 USD, over monthlyCeilingUsd \(415\.00 USD\)\.$'
        $over.remediation | Should -Match 'grant-safety-stop\.ps1'
        $over.remediation | Should -Match 'Or raise monthlyCeilingUsd to at least 423 in your configuration\.$'
        $over.evidence['overCeiling'] | Should -BeTrue
        $over.evidence['monthlyWorstCase'] | Should -Be 422.32
    }

    It 'prices it again when the run ends with no session-control role and nothing automatic to delete the container, though the tag stays Session (review of ab91ee5)' {
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT5ContainerLifecycle -MockWith { [pscustomobject]@{ Lifecycle = 'Session'; Recorded = ''; Changed = $true; Known = $true; Why = 'id-dbhub-demo-control holds no role at rg-dbhub-demo yet'; RoleName = 'DbHub Demo Activity Operator'; Mode = 'NoRole'; AutoDelete = $false; Price = 'AlwaysOn' } }
        $manual = Update-Lifecycle -Prior @(New-Priced 'Session' 400.00)
        $manual.status | Should -Be 'Warning'
        $manual.evidence['lifecycle'] | Should -Be 'Session' -Because 'stop-demo.ps1 still deletes it'
        $manual.evidence['price'] | Should -Be 'AlwaysOn'
        $manual.message | Should -Match '^T5''s container is deleted only when you run \./scripts/stop-demo\.ps1'
        # Over the ceiling only because nothing automatic deletes the container: said as PREFLIGHT.COST.MONTHLY says it (the
        # re-review of 0590bbe).
        $manual.message | Should -Match 'the month''s worst case is about 22\.32 USD more than its estimate: 422\.32 USD, over monthlyCeilingUsd \(415\.00 USD\)\. This is a Warning, not a Fail: T5''s container is priced all month, 22\.32 USD more than for the running hours only, because no role can delete it automatically after a session \(the session control has no role, and the nightly safety stop''s role can''t delete it\), so only \./scripts/stop-demo\.ps1 does; with it deleted after each session, the month would be 400\.00 USD, within the ceiling\.$'
        $manual.remediation | Should -Match '^deploy\.ps1 and start-demo\.ps1 go on\. To clear it, any one of these: an Owner of the subscription runs, once: \./scripts/grant-safety-stop\.ps1 -ConfigPath \./config/demo\.config\.json, which gives the session control and the nightly safety stop their roles, so the worst case falls to about 400\.00 USD; or raise monthlyCeilingUsd to at least 423 in your configuration'
        $manual.remediation | Should -Match 'or set t5Enabled to false, which leaves T5 out\. Until then, run \./scripts/stop-demo\.ps1 after each session: it deletes T5''s container\.$'
        $manual.evidence['t5CeilingException']['sessionMonthlyUsd'] | Should -Be 400
        # With the nightly safety stop deleting it, nothing changes.
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT5ContainerLifecycle -MockWith { [pscustomobject]@{ Lifecycle = 'Session'; Recorded = ''; Changed = $true; Known = $true; Why = 'id-dbhub-demo-control holds no role at rg-dbhub-demo yet'; RoleName = 'DbHub Demo Activity Operator'; Mode = 'NoRole'; AutoDelete = $true; Price = 'Session' } }
        $nightly = Update-Lifecycle -Prior @(New-Priced 'Session' 400.00)
        $nightly.status | Should -Be 'Pass'
        $nightly.message | Should -Not -Match 'Preflight priced'
    }

    It 'counts T4''s restart for the rest of the month too when DEPLOY.COST.T4RESTART says the safety stop preflight counted isn''t in place, at <Ceiling> USD (the re-review of 0590bbe)' -ForEach @(
        @{ Ceiling = 415; Over = $false; Exception = $false }
        @{ Ceiling = 390; Over = $true; Exception = $true }
        @{ Ceiling = 360; Over = $true; Exception = $false }
    ) {
        # An Owner whose role writes a policy refused: preflight counted the safety stop and the session control this run sets
        # up (149.34 USD), DEPLOY.COST.T4RESTART says 371.48 without the stop, and the control ends with no role, so only
        # stop-demo.ps1 deletes T5's container: 26.74 USD more, 398.22 USD (ADR 0016's figures, 2026-11-19 list prices).
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT5ContainerLifecycle -MockWith { [pscustomobject]@{ Lifecycle = 'Session'; Recorded = ''; Changed = $true; Known = $true; Why = 'id-dbhub-demo-control holds no role at rg-dbhub-demo yet'; RoleName = 'DbHub Demo Activity Operator'; Mode = 'NoRole'; AutoDelete = $false; Price = 'AlwaysOn' } }
        $priced = New-DemoResult -CheckId 'PREFLIGHT.COST.MONTHLY' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'Within the ceiling.' -Evidence ([ordered]@{ t5ContainerLifecycle = 'Session'; t5AlwaysOnExtraMonthly = 26.74; monthlyWorstCase = 149.34; t4RestartPlanned = $true; monthlyWorstCaseWithoutSafetyStop = 371.48; t4AutoRestartWorstCaseMonthly = 34.18; t4AutoRestartWithSafetyStopMonthly = 34.18 })
        $restart = New-DemoResult -CheckId 'DEPLOY.COST.T4RESTART' -Area 'infra' -Target 'T4' -Status 'Warning' -Message 'Preflight counted the nightly safety stop that this run sets up, but it isn''t fully in place.' -Evidence ([ordered]@{ worstCaseWithoutSafetyStop = 371.48; monthlyCeilingUsd = $Ceiling; overCeiling = (371.48 -gt $Ceiling) })
        $result = Update-Lifecycle -Prior @($priced, $restart) -Ceiling $Ceiling
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match ('Preflight priced its throughput for a session''s hours only, so the month''s worst case is about 26\.74 USD more than DEPLOY\.COST\.T4RESTART''s, which counts T4''s restart for the rest of the month: 398\.22 USD, {0} monthlyCeilingUsd \({1}\.00 USD\)\.' -f $(if ($Over) { 'over' } else { 'within' }), $Ceiling)
        $result.evidence['monthlyWorstCase'] | Should -Be 398.22
        $result.evidence['worstCaseBasis'] | Should -Be 'WithoutSafetyStop'
        if ($Exception) {
            $result.message | Should -Match 'This is a Warning, not a Fail: T5''s container is priced all month, 26\.74 USD more than for the running hours only, because no role can delete it automatically after a session.*the month would be 371\.48 USD, within the ceiling\.$'
            $result.remediation | Should -Match 'so the worst case falls to about 149\.34 USD; or raise monthlyCeilingUsd to at least 399 in your configuration'
            $result.evidence['t5CeilingException']['grantMonthlyUsd'] | Should -Be 149.34
        }
        else {
            $result.message | Should -Not -Match 'This is a Warning, not a Fail'
            $result.evidence.Contains('t5CeilingException') | Should -BeFalse
        }
        if ($Over -and -not $Exception) {
            $result.remediation | Should -Match 'Or raise monthlyCeilingUsd to at least 399 in your configuration\.$' -Because 'over the ceiling with T5 for the running hours too: T4''s restart, not T5, puts it over'
        }
        # Without DEPLOY.COST.T4RESTART, preflight's own worst case.
        $planned = Update-Lifecycle -Prior @($priced) -Ceiling $Ceiling
        $planned.message | Should -Match 'about 26\.74 USD more than its estimate: 176\.08 USD, within monthlyCeilingUsd'
        $planned.evidence['worstCaseBasis'] | Should -Be 'Preflight'
    }

    It 'says it''s within the ceiling, and adds nothing when preflight priced AlwaysOn already or didn''t run' {
        $within = Update-Lifecycle -Prior @(New-Priced 'Session' 200.00)
        $within.message | Should -Match 'worst case is about 22\.32 USD more than its estimate: 222\.32 USD, within monthlyCeilingUsd \(415\.00 USD\)\.$'
        $within.remediation | Should -Not -Match 'raise monthlyCeilingUsd'
        (Update-Lifecycle -Prior @(New-Priced 'AlwaysOn' 380.00)).message | Should -Not -Match 'Preflight priced'
        (Update-Lifecycle -Prior @()).message | Should -Not -Match 'Preflight priced'
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
