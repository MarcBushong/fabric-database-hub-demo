BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 200

    . (Join-Path -Path $PSScriptRoot -ChildPath 'Infra.Helpers.ps1')

    # T5's network in the compiled template (2026-11-21, ADR 0027): the demo module decides t5Private and passes it on, the
    # network module adds T1's subnet's Azure Cosmos DB service endpoint, and cosmos01 has a private endpoint or a virtual
    # network rule.
    $demoDeployment = Get-TemplateNode -Root $template | Where-Object { $_['type'] -eq 'Microsoft.Resources/deployments' -and [string]$_['name'] -like '*demo-*' } | Select-Object -First 1
    $demoTemplate = $demoDeployment['properties']['template']
    $networkModule = Get-NestedDeployment -Root $demoTemplate -Name 'network'
    $cosmosModule = Get-NestedDeployment -Root $demoTemplate -Name 'cosmos01'
    $networkTemplate = $networkModule['properties']['template']
    $cosmosTemplate = $cosmosModule['properties']['template']
    $subnetIds = @('sqlvm', 'archost', 'pe') | ForEach-Object { '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/virtualNetworks/vnet-dbhub-demo/subnets/snet-{0}' -f $_ }

    # What the demo module passes on for deploy.ps1's t5PrivateAccess in a network mode.
    function Get-T5Wiring {
        param([bool] $T5PrivateAccess, [string] $NetworkMode, [bool] $T5Enabled = $true)
        $context = @{ Template = $demoTemplate; Parameters = @{ t5PrivateAccess = $T5PrivateAccess; networkMode = $NetworkMode; t5Enabled = $T5Enabled }; VariableCache = @{} }
        [pscustomobject]@{
            CosmosServiceEndpoint = [bool](Resolve-ArmValue -Value $networkModule['properties']['parameters']['cosmosServiceEndpoint']['value'] -Context $context)
            PrivateAccess         = [bool](Resolve-ArmValue -Value $cosmosModule['properties']['parameters']['privateAccess']['value'] -Context $context)
        }
    }

    # snet-sqlvm's service endpoints, as the network module sends them to the virtual network, joined with commas.
    function Get-SqlvmServiceEndpoint {
        param([string] $NetworkMode, [bool] $CosmosServiceEndpoint)
        $subnet = Get-TemplateNode -Root $networkTemplate | Where-Object { $_['name'] -eq 'snet-sqlvm' -and $_.Contains('serviceEndpoints') } | Select-Object -First 1
        $context = @{ Template = $networkTemplate; Parameters = @{ networkMode = $NetworkMode; cosmosServiceEndpoint = $CosmosServiceEndpoint }; VariableCache = @{} }
        $endpoints = Resolve-ArmValue -Value $subnet['serviceEndpoints'] -Context $context
        return (@($endpoints) -join ',')
    }

    # cosmos01's resources, with its expressions resolved.
    function Get-T5Resource {
        param([bool] $PrivateAccess)
        $parameters = @{
            location                = 'westus3'
            tags                    = @{ solution = 'fabric-database-hub-demo' }
            accountName             = 'cosmos01-abc123'
            databaseName            = 'contosocare'
            containerName           = 'patient-events'
            partitionKeyPath        = '/patientId'
            partitionKeyVersion     = 2
            indexingPolicy          = @{ indexingMode = 'consistent' }
            throughput              = 400
            enableFreeTier          = $false
            privateAccess           = $PrivateAccess
            allowedSubnetId         = $subnetIds[0]
            privateEndpointSubnetId = $subnetIds[2]
            virtualNetworkId        = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/virtualNetworks/vnet-dbhub-demo'
            privateEndpointName     = 'pe-dbhub-demo-cosmos01'
            privateDnsZoneName      = 'privatelink.documents.azure.com'
            privateEndpointGroupId  = 'Sql'
        }
        (Invoke-ArmTemplate -Template $cosmosTemplate -Parameters $parameters).Resources
    }
}

Describe 'T5''s network in the compiled template (azuredeploy.json, 2026-11-21, ADR 0027)' {
    It 'changes nothing on an update of a T5 that has its private endpoint: the endpoint, its zone, snet-sqlvm''s service endpoints, and public access off' {
        # deploy.ps1 keeps t5PrivateAccess for an existing account with its endpoint (Resolve-DemoT5NetworkAccess: Existing).
        foreach ($mode in 'public', 'private') {
            $wiring = Get-T5Wiring -T5PrivateAccess $true -NetworkMode $mode
            $wiring.PrivateAccess | Should -BeTrue
            $wiring.CosmosServiceEndpoint | Should -BeFalse
            Get-SqlvmServiceEndpoint -NetworkMode $mode -CosmosServiceEndpoint $wiring.CosmosServiceEndpoint | Should -Be $(if ($mode -eq 'public') { 'Microsoft.Sql' } else { '' }) -Because 'snet-sqlvm keeps the service endpoints it had before T5 could go without one'
        }
        $resources = Get-T5Resource -PrivateAccess $true
        $account = ($resources | Where-Object Type -eq 'Microsoft.DocumentDB/databaseAccounts').Properties
        $account['publicNetworkAccess'] | Should -Be 'Disabled'
        $account['isVirtualNetworkFilterEnabled'] | Should -BeFalse
        @($account['virtualNetworkRules']) | Should -BeNullOrEmpty
        @($account['ipRules']) | Should -BeNullOrEmpty
        $endpoint = $resources | Where-Object Type -eq 'Microsoft.Network/privateEndpoints'
        $endpoint.Name | Should -Be 'pe-dbhub-demo-cosmos01'
        $endpoint.Properties['subnet']['id'] | Should -Match '/subnets/snet-pe$'
        $endpoint.Properties['privateLinkServiceConnections'][0]['properties']['groupIds'] | Should -Be @('Sql')
        ($resources | Where-Object Type -eq 'Microsoft.Network/privateDnsZones').Name | Should -Be 'privatelink.documents.azure.com'
        ($resources | Where-Object Type -eq 'Microsoft.Network/privateDnsZones/virtualNetworkLinks').Name | Should -Be 'privatelink.documents.azure.com/link-vnet-dbhub-demo'
        ($resources | Where-Object Type -eq 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups').Name | Should -Be 'pe-dbhub-demo-cosmos01/default'
    }

    It 'keeps the private endpoint in private mode even when told otherwise' {
        $wiring = Get-T5Wiring -T5PrivateAccess $false -NetworkMode private
        $wiring.PrivateAccess | Should -BeTrue
        $wiring.CosmosServiceEndpoint | Should -BeFalse
    }

    It 'reaches a T5 without a private endpoint from T1''s subnet alone: its service endpoint and one virtual network rule, no IP rule' {
        $wiring = Get-T5Wiring -T5PrivateAccess $false -NetworkMode public
        $wiring.PrivateAccess | Should -BeFalse
        $wiring.CosmosServiceEndpoint | Should -BeTrue
        Get-SqlvmServiceEndpoint -NetworkMode public -CosmosServiceEndpoint $true | Should -Be 'Microsoft.Sql,Microsoft.AzureCosmosDB'
        $resources = Get-T5Resource -PrivateAccess $false
        $account = ($resources | Where-Object Type -eq 'Microsoft.DocumentDB/databaseAccounts').Properties
        $account['publicNetworkAccess'] | Should -Be 'Enabled'
        $account['isVirtualNetworkFilterEnabled'] | Should -BeTrue
        @($account['virtualNetworkRules']).Count | Should -Be 1
        $account['virtualNetworkRules'][0]['id'] | Should -Match '/subnets/snet-sqlvm$'
        $account['virtualNetworkRules'][0]['ignoreMissingVNetServiceEndpoint'] | Should -BeFalse
        @($account['ipRules']) | Should -BeNullOrEmpty
        $account['disableLocalAuth'] | Should -BeTrue
        @($resources | Where-Object Type -like 'Microsoft.Network/private*') | Should -BeNullOrEmpty
    }

    It 'adds no service endpoint with T5 off' {
        (Get-T5Wiring -T5PrivateAccess $false -NetworkMode public -T5Enabled $false).CosmosServiceEndpoint | Should -BeFalse
    }
}
