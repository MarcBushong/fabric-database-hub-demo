BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable

    # Every node of the compiled template, depth first.
    function Get-TemplateNode {
        param([object] $Root)
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $node = $stack.Pop()
            if ($node -is [System.Collections.IDictionary]) {
                $node
                foreach ($value in $node.Values) { $stack.Push($value) }
            }
            elseif ($node -is [System.Collections.IList]) {
                foreach ($value in $node) { $stack.Push($value) }
            }
        }
    }

    function Get-NestedDeployment {
        param([object] $Root, [string] $Name)
        Get-TemplateNode -Root $Root | Where-Object { $_['type'] -eq 'Microsoft.Resources/deployments' -and $_['name'] -eq $Name } | Select-Object -First 1
    }

    # A small evaluator for the ARM template expressions the T3 module and its caller use. Unknown functions
    # throw, so a template change that needs more fails here visibly instead of being skipped.
    function ConvertTo-ArmToken {
        param([string] $Text)
        $tokens = [System.Collections.Generic.List[object]]::new()
        $i = 0
        while ($i -lt $Text.Length) {
            $c = $Text[$i]
            if ([char]::IsWhiteSpace($c)) { $i++; continue }
            if ($c -eq "'") {
                $builder = [System.Text.StringBuilder]::new()
                $i++
                while ($true) {
                    if ($Text[$i] -eq "'") {
                        if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { [void]$builder.Append("'"); $i += 2; continue }
                        $i++
                        break
                    }
                    [void]$builder.Append($Text[$i])
                    $i++
                }
                $tokens.Add(@{ Kind = 'value'; Value = $builder.ToString() })
                continue
            }
            if ($c -match '[0-9]' -or ($c -eq '-' -and $Text[$i + 1] -match '[0-9]')) {
                $start = $i
                $i++
                while ($i -lt $Text.Length -and $Text[$i] -match '[0-9.]') { $i++ }
                $tokens.Add(@{ Kind = 'value'; Value = [double]::Parse($Text.Substring($start, $i - $start), [System.Globalization.CultureInfo]::InvariantCulture) })
                continue
            }
            if ($c -match '[A-Za-z_$#]') {
                $start = $i
                while ($i -lt $Text.Length -and $Text[$i] -match '[A-Za-z0-9_$#]') { $i++ }
                $tokens.Add(@{ Kind = 'name'; Value = $Text.Substring($start, $i - $start) })
                continue
            }
            if ('(),.[]'.Contains($c)) {
                $tokens.Add(@{ Kind = 'punct'; Value = [string]$c })
                $i++
                continue
            }
            throw "Unexpected character '$c' in [$Text]"
        }
        return , $tokens
    }

    function Get-ArmMember {
        param([object] $Value, [object] $Name)
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                if ([string]::Equals([string]$key, [string]$Name, [System.StringComparison]::OrdinalIgnoreCase)) { return , $Value[$key] }
            }
            throw "No member '$Name'."
        }
        if ($Value -is [System.Collections.IList]) { return , $Value[[int]$Name] }
        throw "Can't read '$Name' from a $($Value.GetType().Name)."
    }

    function Invoke-ArmFunction {
        param([string] $Name, [object[]] $Arguments, [hashtable] $Context)
        switch ($Name.ToLowerInvariant()) {
            'parameters' {
                if (-not $Context.Parameters.ContainsKey($Arguments[0])) { throw "No value for parameter '$($Arguments[0])'." }
                return , $Context.Parameters[$Arguments[0]]
            }
            'variables' { return , (Get-ArmVariable -Name $Arguments[0] -Context $Context) }
            'equals' { return ([string]$Arguments[0] -ceq [string]$Arguments[1]) }
            'not' { return (-not [bool]$Arguments[0]) }
            'and' { return (@($Arguments | Where-Object { -not [bool]$_ }).Count -eq 0) }
            'or' { return (@($Arguments | Where-Object { [bool]$_ }).Count -gt 0) }
            'if' { if ([bool]$Arguments[0]) { return , $Arguments[1] } else { return , $Arguments[2] } }
            'true' { return $true }
            'false' { return $false }
            'createobject' {
                $object = [ordered]@{}
                for ($i = 0; $i -lt $Arguments.Count; $i += 2) { $object[[string]$Arguments[$i]] = $Arguments[$i + 1] }
                return , $object
            }
            'createarray' { return , @($Arguments) }
            'union' {
                $merged = [ordered]@{}
                foreach ($object in $Arguments) { foreach ($key in $object.Keys) { $merged[$key] = $object[$key] } }
                return , $merged
            }
            'mul' { return ([long]$Arguments[0] * [long]$Arguments[1]) }
            'format' { return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, [string]$Arguments[0], [object[]]@($Arguments | Select-Object -Skip 1)) }
            'split' { return , ([string]$Arguments[0]).Split([string]$Arguments[1]) }
            'last' { $items = $Arguments[0]; return , $items[$items.Count - 1] }
            'string' { return [string]$Arguments[0] }
            'json' { return , ([string]$Arguments[0] | ConvertFrom-Json -AsHashtable) }
            'replace' { return ([string]$Arguments[0]).Replace([string]$Arguments[1], [string]$Arguments[2]) }
            'environment' { return , @{ name = 'AzureCloud'; suffixes = @{ sqlServerHostname = '.database.windows.net' } } }
            'subscription' { return , @{ id = '/subscriptions/11111111-2222-3333-4444-555555555555'; subscriptionId = '11111111-2222-3333-4444-555555555555'; tenantId = '66666666-7777-8888-9999-000000000000' } }
            'resourceid' { return ('resourceId:{0}' -f (@($Arguments) -join '/')) }
            'reference' { return , @{ reference = $Arguments[0] } }
            default { throw "The test evaluator doesn't support the ARM function '$Name'." }
        }
    }

    function Read-ArmExpression {
        param([hashtable] $State, [hashtable] $Context)
        $token = $State.Tokens[$State.Position]
        $State.Position++
        if ($token.Kind -eq 'value') {
            $value = $token.Value
        }
        elseif ($token.Kind -eq 'name') {
            $State.Position++ # (
            $arguments = [System.Collections.Generic.List[object]]::new()
            while ($State.Tokens[$State.Position].Value -ne ')') {
                $arguments.Add((Read-ArmExpression -State $State -Context $Context))
                if ($State.Tokens[$State.Position].Value -eq ',') { $State.Position++ }
            }
            $State.Position++ # )
            $value = Invoke-ArmFunction -Name $token.Value -Arguments $arguments.ToArray() -Context $Context
        }
        else {
            throw "Unexpected '$($token.Value)'."
        }
        while ($State.Position -lt $State.Tokens.Count) {
            $next = $State.Tokens[$State.Position]
            if ($next.Kind -eq 'punct' -and $next.Value -eq '.') {
                $value = Get-ArmMember -Value $value -Name $State.Tokens[$State.Position + 1].Value
                $State.Position += 2
            }
            elseif ($next.Kind -eq 'punct' -and $next.Value -eq '[') {
                $State.Position++
                $index = Read-ArmExpression -State $State -Context $Context
                $State.Position++ # ]
                $value = Get-ArmMember -Value $value -Name $index
            }
            else {
                break
            }
        }
        return , $value
    }

    function Resolve-ArmValue {
        param([object] $Value, [hashtable] $Context)
        if ($Value -is [string]) {
            if ($Value.StartsWith('[[')) { return $Value.Substring(1) }
            if ($Value.StartsWith('[') -and $Value.EndsWith(']')) {
                $state = @{ Tokens = (ConvertTo-ArmToken -Text $Value.Substring(1, $Value.Length - 2)); Position = 0 }
                return , (Read-ArmExpression -State $state -Context $Context)
            }
            return $Value
        }
        if ($Value -is [System.Collections.IDictionary]) {
            $copy = [ordered]@{}
            foreach ($key in $Value.Keys) { $copy[$key] = Resolve-ArmValue -Value $Value[$key] -Context $Context }
            return , $copy
        }
        if ($Value -is [System.Collections.IList]) {
            return , @(foreach ($item in $Value) { , (Resolve-ArmValue -Value $item -Context $Context) })
        }
        return $Value
    }

    function Get-ArmVariable {
        param([string] $Name, [hashtable] $Context)
        if (-not $Context.VariableCache.ContainsKey($Name)) {
            $Context.VariableCache[$Name] = Resolve-ArmValue -Value $Context.Template['variables'][$Name] -Context $Context
        }
        return , $Context.VariableCache[$Name]
    }

    # Evaluates a (nested) template: every resource whose condition holds, with its expressions resolved.
    function Invoke-ArmTemplate {
        param([System.Collections.IDictionary] $Template, [hashtable] $Parameters)
        $values = @{}
        foreach ($name in $Template['parameters'].Keys) {
            if ($Parameters.ContainsKey($name)) { $values[$name] = $Parameters[$name] }
            elseif ($Template['parameters'][$name].Contains('defaultValue')) { $values[$name] = $Template['parameters'][$name]['defaultValue'] }
            else { throw "The test supplies no value for the required parameter '$name'." }
        }
        $context = @{ Template = $Template; Parameters = $values; VariableCache = @{} }
        $resources = if ($Template['resources'] -is [System.Collections.IDictionary]) { @($Template['resources'].Values) } else { @($Template['resources']) }
        $deployed = foreach ($resource in $resources) {
            if ($resource.Contains('condition') -and -not [bool](Resolve-ArmValue -Value $resource['condition'] -Context $context)) { continue }
            [pscustomobject]@{
                Type       = $resource['type']
                Name       = Resolve-ArmValue -Value $resource['name'] -Context $context
                Sku        = if ($resource.Contains('sku')) { Resolve-ArmValue -Value $resource['sku'] -Context $context } else { $null }
                Properties = if ($resource.Contains('properties')) { Resolve-ArmValue -Value $resource['properties'] -Context $context } else { $null }
                Location   = if ($resource.Contains('location')) { Resolve-ArmValue -Value $resource['location'] -Context $context } else { $null }
            }
        }
        [pscustomobject]@{ Resources = @($deployed); Context = $context }
    }

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
