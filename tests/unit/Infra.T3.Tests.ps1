BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable

    . (Join-Path -Path $PSScriptRoot -ChildPath 'Infra.Helpers.ps1')

    $t3Deployment = Get-NestedDeployment -Root $template -Name 'azuresql01'
    $t3Template = $t3Deployment['properties']['template']

    function Get-T3Resource {
        param([string] $NetworkMode, [bool] $UseFreeLimit = $true)
        $parameters = @{
            location                = 'westus3'
            tags                    = @{ solution = 'fabric-database-hub-demo' }
            serverName              = 'azuresql01-abc123'
            databaseName            = 'ContosoCare'
            networkMode             = $NetworkMode
            adminGroupObjectId      = '77777777-7777-7777-7777-777777777777'
            adminGroupDisplayName   = 'sg-test-sqladmins'
            sizing                  = @{ minVcores = 0.5; maxVcores = 1; maxSizeGB = 32; autoPauseMinutes = 15 }
            autoPauseMinutes        = 15
            useFreeLimit            = $UseFreeLimit
            sqlvmSubnetId           = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/virtualNetworks/vnet-dbhub-demo/subnets/snet-sqlvm'
            privateEndpointSubnetId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/virtualNetworks/vnet-dbhub-demo/subnets/snet-pe'
            virtualNetworkId        = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/virtualNetworks/vnet-dbhub-demo'
            privateEndpointName     = 'pe-dbhub-demo-azuresql01'
        }
        (Invoke-ArmTemplate -Template $t3Template -Parameters $parameters).Resources
    }
}

Describe 'T3 in the compiled template (azuredeploy.json)' {
    It 'has the T3 module, deployed as azuresql01' {
        $t3Deployment | Should -Not -BeNullOrEmpty
        $t3Template['resources'] | Should -Not -BeNullOrEmpty
    }

    It 'creates the server Entra-only, with the P6 group as administrator, TLS 1.2, and no SQL authentication (<_> mode)' -ForEach @('public', 'private') {
        $server = Get-T3Resource -NetworkMode $_ | Where-Object Type -eq 'Microsoft.Sql/servers'
        @($server).Count | Should -Be 1
        $admin = $server.Properties['administrators']
        $admin['azureADOnlyAuthentication'] | Should -BeTrue
        $admin['administratorType'] | Should -Be 'ActiveDirectory'
        $admin['principalType'] | Should -Be 'Group'
        $admin['sid'] | Should -Be '77777777-7777-7777-7777-777777777777'
        $admin['login'] | Should -Be 'sg-test-sqladmins'
        $admin['tenantId'] | Should -Be '66666666-7777-8888-9999-000000000000'
        $server.Properties['minimalTlsVersion'] | Should -Be '1.2'
        $server.Properties.Contains('administratorLogin') | Should -BeFalse
        $server.Properties.Contains('administratorLoginPassword') | Should -BeFalse
    }

    It 'never sets SQL authentication or a firewall rule, so there is no 0.0.0.0 "Allow Azure services" rule' {
        $json = $t3Template | ConvertTo-Json -Depth 64 -Compress
        $json | Should -Not -Match 'administratorLogin'
        $json | Should -Not -Match '0\.0\.0\.0'
        @(Get-TemplateNode -Root $template | Where-Object { $_['type'] -is [string] -and $_['type'] -like 'Microsoft.Sql/servers/firewallRules' }) | Should -BeNullOrEmpty
        foreach ($mode in 'public', 'private') {
            @(Get-T3Resource -NetworkMode $mode | Where-Object Type -like '*firewallRules') | Should -BeNullOrEmpty
        }
    }

    It 'private mode: public network access off, a private endpoint in snet-pe, the privatelink zone linked to the VNet, and a zone group' {
        $resources = Get-T3Resource -NetworkMode 'private'
        ($resources | Where-Object Type -eq 'Microsoft.Sql/servers').Properties['publicNetworkAccess'] | Should -Be 'Disabled'
        @($resources | Where-Object Type -eq 'Microsoft.Sql/servers/virtualNetworkRules') | Should -BeNullOrEmpty

        $endpoint = $resources | Where-Object Type -eq 'Microsoft.Network/privateEndpoints'
        $endpoint.Name | Should -Be 'pe-dbhub-demo-azuresql01'
        $endpoint.Properties['subnet']['id'] | Should -Match '/subnets/snet-pe$'
        $connection = $endpoint.Properties['privateLinkServiceConnections'][0]['properties']
        $connection['groupIds'] | Should -Be @('sqlServer')
        $connection['privateLinkServiceId'] | Should -Be 'resourceId:Microsoft.Sql/servers/azuresql01-abc123'

        $zone = $resources | Where-Object Type -eq 'Microsoft.Network/privateDnsZones'
        $zone.Name | Should -Be 'privatelink.database.windows.net'
        $zone.Location | Should -Be 'global'

        $link = $resources | Where-Object Type -eq 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
        $link.Name | Should -Be 'privatelink.database.windows.net/link-vnet-dbhub-demo'
        $link.Properties['virtualNetwork']['id'] | Should -Match '/virtualNetworks/vnet-dbhub-demo$'
        $link.Properties['registrationEnabled'] | Should -BeFalse

        $group = $resources | Where-Object Type -eq 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
        $group.Name | Should -Be 'pe-dbhub-demo-azuresql01/default'
        $group.Properties['privateDnsZoneConfigs'][0]['properties']['privateDnsZoneId'] | Should -Be 'resourceId:Microsoft.Network/privateDnsZones/privatelink.database.windows.net'
    }

    It 'public mode: public network access on with one VNet rule for snet-sqlvm, and no private endpoint or DNS zone' {
        $resources = Get-T3Resource -NetworkMode 'public'
        ($resources | Where-Object Type -eq 'Microsoft.Sql/servers').Properties['publicNetworkAccess'] | Should -Be 'Enabled'
        $rules = @($resources | Where-Object Type -eq 'Microsoft.Sql/servers/virtualNetworkRules')
        $rules.Count | Should -Be 1
        $rules[0].Properties['virtualNetworkSubnetId'] | Should -Match '/subnets/snet-sqlvm$'
        $rules[0].Properties['ignoreMissingVnetServiceEndpoint'] | Should -BeFalse
        @($resources | Where-Object Type -like 'Microsoft.Network/private*') | Should -BeNullOrEmpty
    }

    It 'sends the free-offer properties only when the offer is used' {
        $free = (Get-T3Resource -NetworkMode 'private' -UseFreeLimit $true | Where-Object Type -eq 'Microsoft.Sql/servers/databases').Properties
        $free['useFreeLimit'] | Should -BeTrue
        $free['freeLimitExhaustionBehavior'] | Should -Be 'BillOverUsage'
        $regular = (Get-T3Resource -NetworkMode 'private' -UseFreeLimit $false | Where-Object Type -eq 'Microsoft.Sql/servers/databases').Properties
        $regular.Contains('useFreeLimit') | Should -BeFalse
        $regular.Contains('freeLimitExhaustionBehavior') | Should -BeFalse
    }

    It 'makes ContosoCare a regional General Purpose serverless database sized by the profile' {
        $database = Get-T3Resource -NetworkMode 'public' | Where-Object Type -eq 'Microsoft.Sql/servers/databases'
        $database.Name | Should -Be 'azuresql01-abc123/ContosoCare'
        $database.Sku['name'] | Should -Be 'GP_S_Gen5'
        $database.Sku['tier'] | Should -Be 'GeneralPurpose'
        $database.Sku['capacity'] | Should -Be 1
        $database.Properties['minCapacity'] | Should -Be 0.5
        $database.Properties['autoPauseDelay'] | Should -Be 15
        $database.Properties['maxSizeBytes'] | Should -Be 34359738368
        $database.Properties['zoneRedundant'] | Should -BeFalse
        $database.Properties['requestedBackupStorageRedundancy'] | Should -Be 'Local'
    }

    It 'sizes T3 from config/profiles.json as compiled, with at least 2 maximum vCores in every profile (2026-11-18)' {
        # Database Agents doesn't support one-vCore serverless databases (the owner's decision: lowest-cost went from 1 to 2).
        # deploy.ps1 deploys azuredeploy.json, so a profile change reaches T3 only once the template is rebuilt.
        $catalog = (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/profiles.json') -Raw | ConvertFrom-Json -AsHashtable).profiles
        # The demo module's variables: catalogProfile, and the profiles it indexes, which loadJsonContent compiled in.
        $variables = @(Get-TemplateNode -Root $template | Where-Object { $_['type'] -eq 'Microsoft.Resources/deployments' -and $_['properties'] -is [System.Collections.IDictionary] -and $_['properties']['template'] -is [System.Collections.IDictionary] -and $_['properties']['template']['variables'] -is [System.Collections.IDictionary] -and $_['properties']['template']['variables'].Contains('catalogProfile') }) | Select-Object -First 1 | ForEach-Object { $_['properties']['template']['variables'] }
        $compiled = @($variables.Values | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('lowest-cost') }) | Select-Object -First 1
        $compiled | Should -Not -BeNullOrEmpty
        foreach ($name in $catalog.Keys) {
            [double]$catalog[$name]['t3']['maxVcores'] | Should -BeGreaterOrEqual 2 -Because $name
            [double]$compiled[$name]['t3']['maxVcores'] | Should -Be ([double]$catalog[$name]['t3']['maxVcores']) -Because ('azuredeploy.json has {0}''s T3 as config/profiles.json does' -f $name)
        }
        $t3Deployment['properties']['parameters']['sizing']['value'] | Should -Be "[variables('catalogProfile').t3]"
    }

    It 'uses the stable names and wires snet-sqlvm and snet-pe from the network module' {
        $parameters = $t3Deployment['properties']['parameters']
        $parameters['serverName']['value'] | Should -Be "[format('azuresql01-{0}', parameters('deploymentId'))]"
        $parameters['databaseName']['value'] | Should -Be 'ContosoCare'
        $parameters['sqlvmSubnetId']['value'] | Should -Be "[reference('network').outputs.subnetIds.value[0]]"
        $parameters['privateEndpointSubnetId']['value'] | Should -Be "[reference('network').outputs.subnetIds.value[2]]"
        # The network module's subnetIds output follows its subnet order.
        $subnetList = Get-TemplateNode -Root (Get-NestedDeployment -Root $template -Name 'network') | Where-Object { $_.Contains('subnets') -and $_['subnets'] -is [System.Collections.IDictionary] -and $_['subnets'].Contains('value') } | Select-Object -First 1
        @($subnetList['subnets']['value'] | ForEach-Object { $_['name'] }) | Should -Be @('snet-sqlvm', 'snet-archost', 'snet-pe', 'AzureBastionSubnet', 'snet-pg')
    }

    It 'takes the auto-pause delay from the parameter, or from the profile when it is 0' {
        $demoTemplate = $template['resources']['demo']['properties']['template']
        $expression = $t3Deployment['properties']['parameters']['autoPauseMinutes']
        foreach ($case in @(@{ Profile = 'lowest-cost'; Value = 0; Expected = 15 }, @{ Profile = 'demo-day'; Value = 0; Expected = 60 }, @{ Profile = 'demo-day'; Value = 30; Expected = 30 }, @{ Profile = 'lowest-cost'; Value = -1; Expected = -1 })) {
            $context = @{ Template = $demoTemplate; Parameters = @{ profile = $case.Profile; t3AutoPauseMinutes = $case.Value }; VariableCache = @{} }
            (Resolve-ArmValue -Value $expression -Context $context)['value'] | Should -Be $case.Expected -Because "$($case.Profile) with $($case.Value)"
        }
    }

    It 'outputs names, the FQDN, and resource IDs, but nothing secret' {
        $t3Template['outputs'].Keys | Sort-Object | Should -Be @('databaseId', 'databaseName', 'privateDnsZoneId', 'privateEndpointId', 'serverFqdn', 'serverId', 'serverName')
        foreach ($name in 't3ServerName', 't3ServerFqdn', 't3DatabaseName', 't3ServerId', 't3DatabaseId', 't3PrivateEndpointId') {
            $template['outputs'].Keys | Should -Contain $name
        }
        $template['outputs'].Keys | Where-Object { $_ -match '(?i)password|secret|key|token|connectionString' } | Should -BeNullOrEmpty
    }

    It 'defaults t3UseFreeLimit to the free offer and requires the P6 group' {
        $template['parameters']['t3UseFreeLimit']['defaultValue'] | Should -BeTrue
        $template['parameters']['t3AutoPauseMinutes']['defaultValue'] | Should -Be 0
        $template['parameters']['t3AdminGroupObjectId'].Contains('defaultValue') | Should -BeFalse
    }
}
