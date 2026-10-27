BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    $baseConfig = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
    # Obviously fake IDs: every group repeats one digit. The management group has no GUID at all.
    $baseConfig['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
    $baseConfig['tenantId'] = '66666666-7777-8888-9999-000000000000'

    $mg = '/providers/Microsoft.Management/managementGroups/contoso-root/providers/Microsoft.Authorization'
    $builtIn = '/providers/Microsoft.Authorization'
    $subscriptionScope = '/subscriptions/11111111-2222-3333-4444-555555555555'

    function New-TestConfig {
        param([hashtable] $Override = @{})
        $config = @{}
        foreach ($key in $baseConfig.Keys) { $config[$key] = $baseConfig[$key] }
        foreach ($key in $Override.Keys) { $config[$key] = $Override[$key] }
        return $config
    }

    function New-Definition {
        param([string] $DisplayName, [hashtable] $Condition, [hashtable] $Then, [hashtable] $Parameters = @{})
        @{ properties = @{ displayName = $DisplayName; policyType = 'Custom'; mode = 'All'; parameters = $Parameters; policyRule = @{ 'if' = $Condition; 'then' = $Then } } }
    }

    # Fake policy definitions, shaped like the ARM responses. Display names echo the kinds of policy a
    # tenant can assign; none of this is a real tenant's data.
    function New-DefinitionSet {
        param([string[]] $BlockedSkus = @('Standard_HB60rs', 'Standard_HC44rs'), [string[]] $NotAllowedTypes = @('microsoft.classiccompute/virtualmachines', 'microsoft.classicstorage/storageaccounts'))
        @{
            "$mg/policySetDefinitions/contoso-deploy"         = @{ properties = @{
                    displayName       = 'Contoso deploy policies'
                    parameters        = @{ sqlEffect = @{ type = 'String'; defaultValue = 'Audit' }; storageEffect = @{ type = 'String'; defaultValue = 'Modify' } }
                    policyDefinitions = @(
                        @{ policyDefinitionReferenceId = 'sql-public'; policyDefinitionId = "$mg/policyDefinitions/sql-public-modify"; parameters = @{ effect = @{ value = "[parameters('sqlEffect')]" } } }
                        @{ policyDefinitionReferenceId = 'storage-local-auth'; policyDefinitionId = "$mg/policyDefinitions/storage-modify"; parameters = @{ effect = @{ value = "[parameters('storageEffect')]" } } }
                        @{ policyDefinitionReferenceId = 'defender-servers'; policyDefinitionId = "$builtIn/policyDefinitions/defender-servers-dine" }
                        @{ policyDefinitionReferenceId = 'guest-config'; policyDefinitionId = "$builtIn/policyDefinitions/guest-config-dine" }
                        @{ policyDefinitionReferenceId = 'pip-tags'; policyDefinitionId = "$mg/policyDefinitions/pip-append" }
                        @{ policyDefinitionReferenceId = 'vm-identity'; policyDefinitionId = "$mg/policyDefinitions/vm-identity-modify" }
                        @{ policyDefinitionReferenceId = 'redis-diag'; policyDefinitionId = "$mg/policyDefinitions/redis-diag-dine" }
                        @{ policyDefinitionReferenceId = 'audit-only'; policyDefinitionId = "$builtIn/policyDefinitions/audit-vm" }
                        @{ policyDefinitionReferenceId = 'locked'; policyDefinitionId = "$mg/policyDefinitions/locked-definition" }
                    )
                }
            }
            "$mg/policySetDefinitions/contoso-deny"           = @{ properties = @{
                    displayName       = 'Contoso deny policies'
                    parameters        = @{}
                    policyDefinitions = @(
                        @{ policyDefinitionReferenceId = 'block-h'; policyDefinitionId = "$mg/policyDefinitions/block-vm-sizes"; parameters = @{ BlockedSKUs = @{ value = $BlockedSkus } } }
                        @{ policyDefinitionReferenceId = 'not-allowed-types'; policyDefinitionId = "$builtIn/policyDefinitions/not-allowed-types"; parameters = @{ listOfResourceTypesNotAllowed = @{ value = $NotAllowedTypes } } }
                        @{ policyDefinitionReferenceId = 'sql-entra-only'; policyDefinitionId = "$mg/policyDefinitions/sql-entra-only-deny" }
                    )
                }
            }
            "$mg/policyDefinitions/sql-public-modify"         = New-Definition -DisplayName 'SQL servers should disable public network access (example)' -Parameters @{ effect = @{ type = 'String'; defaultValue = 'Audit' } } -Condition @{
                allOf = @(
                    @{ field = 'type'; equals = 'Microsoft.Sql/servers' }
                    @{ field = 'Microsoft.Sql/servers/publicNetworkAccess'; notEquals = 'Disabled' }
                )
            } -Then @{ effect = "[parameters('effect')]"; details = @{ roleDefinitionIds = @('/providers/Microsoft.Authorization/roleDefinitions/role'); operations = @(@{ operation = 'addOrReplace'; field = 'Microsoft.Sql/servers/publicNetworkAccess'; value = 'Disabled' }) } }
            "$mg/policyDefinitions/storage-modify"            = New-Definition -DisplayName 'Storage accounts should disable shared key access (example)' -Parameters @{ effect = @{ type = 'String'; defaultValue = 'Disabled' } } -Condition @{
                field = 'type'; equals = 'Microsoft.Storage/storageAccounts'
            } -Then @{ effect = "[parameters('effect')]"; details = @{ operations = @(@{ operation = 'addOrReplace'; field = 'Microsoft.Storage/storageAccounts/allowSharedKeyAccess'; value = $false }) } }
            "$builtIn/policyDefinitions/defender-servers-dine" = New-Definition -DisplayName 'Configure Defender for Servers to be enabled' -Condition @{
                field = 'type'; equals = 'Microsoft.Resources/subscriptions'
            } -Then @{ effect = 'DeployIfNotExists'; details = @{ type = 'Microsoft.Security/pricings'; name = 'VirtualMachines' } }
            "$builtIn/policyDefinitions/guest-config-dine"     = New-Definition -DisplayName 'Deploy the Guest Configuration extension' -Condition @{
                AllOf = @(@{ Field = 'type'; Equals = 'Microsoft.Compute/virtualMachines' })
            } -Then @{ effect = 'deployIfNotExists'; details = @{ type = 'Microsoft.Compute/virtualMachines/extensions'; existenceCondition = @{ allOf = @(
                            @{ field = 'Microsoft.Compute/virtualMachines/extensions/publisher'; equals = 'Microsoft.GuestConfiguration' }
                            @{ field = 'Microsoft.Compute/virtualMachines/extensions/type'; equals = 'ConfigurationforWindows' }
                        ) 
                    } 
                } 
            }
            "$mg/policyDefinitions/pip-append"                = New-Definition -DisplayName 'Public IP addresses get an IP tag (example)' -Condition @{
                allOf = @(
                    @{ field = 'type'; equals = 'Microsoft.Network/publicIPAddresses' }
                    @{ count = @{ field = 'Microsoft.Network/publicIPAddresses/ipTags[*]' }; less = 1 }
                )
            } -Then @{ effect = 'append'; details = @(@{ field = 'Microsoft.Network/publicIPAddresses/ipTags[*]'; value = @{ ipTagType = 'RoutingPreference'; tag = 'Internet' } }) }
            "$mg/policyDefinitions/vm-identity-modify"        = New-Definition -DisplayName 'Add system-assigned identity to VMs' -Condition @{
                allOf = @(
                    @{ field = 'type'; equals = 'Microsoft.Compute/virtualMachines' }
                    @{ field = 'identity.type'; exists = 'false' }
                )
            } -Then @{ effect = 'modify'; details = @{ operations = @(@{ operation = 'addOrReplace'; field = 'identity.type'; value = 'SystemAssigned' }) } }
            "$mg/policyDefinitions/redis-diag-dine"           = New-Definition -DisplayName 'Diagnostics for Redis' -Condition @{
                field = 'type'; equals = 'Microsoft.Cache/Redis'
            } -Then @{ effect = 'DeployIfNotExists'; details = @{ type = 'Microsoft.Insights/diagnosticSettings' } }
            "$builtIn/policyDefinitions/audit-vm"             = New-Definition -DisplayName 'Audit VMs' -Condition @{
                field = 'type'; equals = 'Microsoft.Compute/virtualMachines'
            } -Then @{ effect = 'Audit' }
            "$mg/policyDefinitions/block-vm-sizes"            = New-Definition -DisplayName 'Block VM SKU Sizes' -Parameters @{ BlockedSKUs = @{ type = 'Array' } } -Condition @{
                AllOf = @(
                    @{ AnyOf = @(
                            @{ field = 'type'; in = @('Microsoft.Compute/virtualMachines') }
                            @{ field = 'type'; in = @('Microsoft.Compute/virtualMachineScaleSets') }
                        ) 
                    }
                    @{ anyOf = @(
                            @{ AllOf = @(
                                    @{ field = 'Microsoft.Compute/virtualMachines/sku.name'; in = "[parameters('BlockedSKUs')]" }
                                    @{ field = 'Microsoft.Compute/virtualMachines/priority'; notEquals = 'Spot' }
                                ) 
                            }
                            @{ AllOf = @(
                                    @{ field = 'Microsoft.Compute/virtualMachineScaleSets/sku.name'; in = "[parameters('BlockedSKUs')]" }
                                    @{ field = 'Microsoft.Compute/virtualMachineScaleSets/virtualMachineProfile.priority'; notEquals = 'Spot' }
                                ) 
                            }
                        ) 
                    }
                )
            } -Then @{ effect = 'Deny' }
            "$builtIn/policyDefinitions/not-allowed-types"    = New-Definition -DisplayName 'Not allowed resource types' -Parameters @{ listOfResourceTypesNotAllowed = @{ type = 'Array' }; effect = @{ type = 'String'; defaultValue = 'Deny' } } -Condition @{
                allOf = @(
                    @{ field = 'type'; in = "[parameters('listOfResourceTypesNotAllowed')]" }
                    @{ value = "[field('type')]"; exists = $true }
                )
            } -Then @{ effect = "[parameters('effect')]" }
            "$mg/policyDefinitions/sql-entra-only-deny"       = New-Definition -DisplayName 'SQL servers should use Microsoft Entra-only authentication (example)' -Parameters @{ effect = @{ type = 'String'; defaultValue = 'deny' } } -Condition @{
                allOf = @(
                    @{ field = 'type'; equals = 'Microsoft.Sql/servers' }
                    @{ value = '[resourcegroup().managedBy]'; notContains = '/providers/Microsoft.Synapse/' }
                    @{ field = 'Microsoft.Sql/servers/administrators.azureADOnlyAuthentication'; notEquals = $true }
                )
            } -Then @{ effect = "[parameters('effect')]" }
            "$builtIn/policyDefinitions/mfa-write"            = New-Definition -DisplayName 'Multi Factor Authentication Enforcement - Write' -Condition @{
                field = 'type'; notEquals = 'Microsoft.Resources/deployments'
            } -Then @{ effect = 'Deny' }
            "$mg/policyDefinitions/paused-deny"               = New-Definition -DisplayName 'Paused deny' -Condition @{ field = 'type'; equals = 'Microsoft.Sql/servers' } -Then @{ effect = 'Deny' }
        }
    }

    function New-AssignmentSet {
        param([hashtable] $DeployParameters = @{ sqlEffect = @{ value = 'Modify' } }, [object[]] $DeployOverrides = @())
        @(
            @{ name = 'contoso-deploy'; properties = @{ displayName = 'Contoso deploy'; scope = '/providers/Microsoft.Management/managementGroups/contoso-root'; enforcementMode = 'Default'; policyDefinitionId = "$mg/policySetDefinitions/contoso-deploy"; parameters = $DeployParameters; overrides = $DeployOverrides } }
            @{ name = 'contoso-deny'; properties = @{ displayName = 'Contoso deny'; scope = '/providers/Microsoft.Management/managementGroups/contoso-root'; enforcementMode = 'Default'; policyDefinitionId = "$mg/policySetDefinitions/contoso-deny" } }
            @{ name = 'sys.mfa-write'; properties = @{ displayName = 'MFA write'; scope = '/providers/Microsoft.Management/managementGroups/contoso-root'; enforcementMode = 'Default'; policyDefinitionId = "$builtIn/policyDefinitions/mfa-write" } }
            @{ name = 'paused'; properties = @{ displayName = 'Paused deny'; scope = $subscriptionScope; enforcementMode = 'DoNotEnforce'; policyDefinitionId = "$mg/policyDefinitions/paused-deny" } }
            @{ name = 'sub-guest-config'; properties = @{ displayName = 'Guest configuration'; scope = $subscriptionScope; enforcementMode = 'Default'; policyDefinitionId = "$builtIn/policyDefinitions/guest-config-dine" } }
        )
    }

    function Get-PolicyFakeResult([string] $Url) {
        if ($Url -match 'policyAssignments\?') {
            if ($script:listFails) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (AuthorizationFailed) The client does not have authorization to perform this action.'; StatusCode = 403 }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = (@{ value = $script:assignments } | ConvertTo-Json -Depth 40); StdErr = ''; StatusCode = 200 }
        }
        $id = $Url -replace '^https://management\.azure\.com', '' -replace '\?api-version=.*$', ''
        if ($id -like '*/locked-definition') {
            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 403: {"error":{"code":"AuthorizationFailed","message":"The client does not have authorization to read this definition."}}'; StatusCode = 403 }
        }
        if ($script:definitions.ContainsKey($id)) {
            return [pscustomobject]@{ ExitCode = 0; StdOut = ($script:definitions[$id] | ConvertTo-Json -Depth 40); StdErr = ''; StatusCode = 200 }
        }
        [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 404: {"error":{"code":"PolicyDefinitionNotFound","message":"The policy definition could not be found."}}'; StatusCode = 404 }
    }

    function Set-PolicyMock {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
        # URLs under the subscription go through az rest; built-in and management group definitions through
        # Invoke-DemoRestRequest, with a token verified for the configured tenant.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { Get-PolicyFakeResult -Url ([string]$ArgumentList[4]) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith { Get-PolicyFakeResult -Url $Uri }
    }

    function Get-Check {
        param([object] $Policy, [string] $Name)
        $Policy.Results | Where-Object { $_.checkId -eq "PREFLIGHT.POLICY.$Name" }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoPolicyConstraint' {
    BeforeEach {
        $script:listFails = $false
        $script:assignments = New-AssignmentSet
        $script:definitions = New-DefinitionSet
        Set-PolicyMock
    }

    It 'lists the assignments that apply to the subscription with read-only GET calls' {
        $policy = Get-DemoPolicyConstraint -Config (New-TestConfig)
        $policy.AssignmentCount | Should -Be 5
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[4] -eq 'https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft.Authorization/policyAssignments?$filter=atScope()&api-version=2023-04-01'
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[0] -ne 'rest' -or $ArgumentList[1] -ne '--method' -or $ArgumentList[2] -ne 'get' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 0 -ParameterFilter { $Method -ne 'GET' }
    }

    It 'reads built-in and management group definitions with a verified token, never through az rest' {
        Get-DemoPolicyConstraint -Config (New-TestConfig) | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[4] -like 'https://management.azure.com/providers/*' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 1 -Exactly -ParameterFilter { $Uri -like 'https://management.azure.com/providers/Microsoft.Management/managementGroups/contoso-root/providers/Microsoft.Authorization/policySetDefinitions/contoso-deploy?*' }
    }

    It 'reads each definition once, even when two assignments use it' {
        Get-DemoPolicyConstraint -Config (New-TestConfig) | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*/policyDefinitions/guest-config-dine?api-version=2023-04-01' }
    }

    It 'reports DoNotEnforce assignments and never reads their definitions' {
        $policy = Get-DemoPolicyConstraint -Config (New-TestConfig)
        $policy.DoNotEnforce | Should -Be 'Paused deny'
        (Get-Check $policy 'INVENTORY').message | Should -Match 'DoNotEnforce: Paused deny'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[4] -like '*/paused-deny?*' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 0 -ParameterFilter { $Uri -like '*/paused-deny?*' }
    }

    It 'resolves effects through the assignment, the set member, the set default, and the definition default' {
        $rules = (Get-DemoPolicyConstraint -Config (New-TestConfig)).Rules
        # The assignment's sqlEffect (Modify) wins over the set default (Audit) and the definition default (Audit).
        ($rules | Where-Object Policy -eq 'SQL servers should disable public network access (example)').Effect | Should -Be 'Modify'
        # The set default (Modify) wins over the definition default (Disabled).
        ($rules | Where-Object Policy -eq 'Storage accounts should disable shared key access (example)').Effect | Should -Be 'Modify'
        # The definition default, lowercase in the definition.
        ($rules | Where-Object Policy -eq 'SQL servers should use Microsoft Entra-only authentication (example)').Effect | Should -Be 'Deny'
        # Audit isn't one of the kept effects.
        $rules.Policy | Should -Not -Contain 'Audit VMs'
    }

    It 'drops a rule whose effect the assignment sets to a value that is not kept' {
        $script:assignments = New-AssignmentSet -DeployParameters @{ sqlEffect = @{ value = 'Audit' } }
        $rules = (Get-DemoPolicyConstraint -Config (New-TestConfig)).Rules
        $rules.Policy | Should -Not -Contain 'SQL servers should disable public network access (example)'
    }

    It 'applies a policyEffect override to the selected set members' {
        $script:assignments = New-AssignmentSet -DeployOverrides @(@{ kind = 'policyEffect'; value = 'Disabled'; selectors = @(@{ kind = 'policyDefinitionReferenceId'; in = @('pip-tags') }) })
        $policy = Get-DemoPolicyConstraint -Config (New-TestConfig)
        $policy.Rules.Policy | Should -Not -Contain 'Public IP addresses get an IP tag (example)'
        Get-Check $policy 'PUBLICIP' | Should -BeNullOrEmpty
    }

    It 'classifies every kept rule' {
        $categories = @{}
        foreach ($rule in (Get-DemoPolicyConstraint -Config (New-TestConfig)).Rules) {
            $categories[$rule.Policy] = $rule.Category
        }
        $categories['SQL servers should disable public network access (example)'] | Should -Be 'SQLPUBLIC'
        $categories['SQL servers should use Microsoft Entra-only authentication (example)'] | Should -Be 'SQLENTRAONLY'
        $categories['Block VM SKU Sizes'] | Should -Be 'VMSIZE'
        $categories['Not allowed resource types'] | Should -Be 'RESOURCETYPES'
        $categories['Configure Defender for Servers to be enabled'] | Should -Be 'DEFENDER'
        $categories['Deploy the Guest Configuration extension'] | Should -Be 'EXTENSIONS'
        $categories['Public IP addresses get an IP tag (example)'] | Should -Be 'PUBLICIP'
        $categories['Storage accounts should disable shared key access (example)'] | Should -Be 'STORAGE'
        $categories['Multi Factor Authentication Enforcement - Write'] | Should -Be 'MFA'
        $categories['Add system-assigned identity to VMs'] | Should -Be 'OTHER'
        $categories['Diagnostics for Redis'] | Should -Be 'UNRELATED'
    }

    It 'reports every conflict with the status model' {
        $policy = Get-DemoPolicyConstraint -Config (New-TestConfig)
        $expected = [ordered]@{
            INVENTORY     = 'Warning'
            SQLPUBLIC     = 'Pass'
            SQLENTRAONLY  = 'Pass'
            VMSIZE        = 'Pass'
            RESOURCETYPES = 'Pass'
            DEFENDER      = 'Warning'
            EXTENSIONS    = 'Warning'
            PUBLICIP      = 'Warning'
            STORAGE       = 'Pass'
            MFA           = 'Pass'
            OTHER         = 'Warning'
        }
        $policy.Results.checkId | Should -Be @($expected.Keys | ForEach-Object { "PREFLIGHT.POLICY.$_" })
        foreach ($name in $expected.Keys) {
            (Get-Check $policy $name).status | Should -Be $expected[$name] -Because $name
        }
        $policy.Results.area | Select-Object -Unique | Should -Be 'preflight'
        (Get-Check $policy 'INVENTORY').evidence.unrelatedRules | Should -Be 1
    }

    It 'resolves networkMode auto to private and records the effective mode in the evidence' {
        $policy = Get-DemoPolicyConstraint -Config (New-TestConfig -Override @{ networkMode = 'auto' })
        $policy.NetworkMode.EffectiveMode | Should -Be 'private'
        $check = Get-Check $policy 'SQLPUBLIC'
        $check.evidence.effectiveNetworkMode | Should -Be 'private'
        $check.evidence.configuredNetworkMode | Should -Be 'auto'
        $check.evidence.policies | Should -Be 'SQL servers should disable public network access (example)'
        $check.message | Should -Match 'resolves to private'
    }

    It 'fails an explicit public network mode when a policy turns public network access off' {
        $check = Get-Check (Get-DemoPolicyConstraint -Config (New-TestConfig -Override @{ networkMode = 'public' })) 'SQLPUBLIC'
        $check.status | Should -Be 'Fail'
        $check.evidence.effectiveNetworkMode | Should -Be 'public'
        $check.remediation | Should -Match 'auto or private'
    }

    It 'names what it could not read as a Warning, without the management group ID' {
        $policy = Get-DemoPolicyConstraint -Config (New-TestConfig)
        $policy.Complete | Should -BeFalse
        $inventory = Get-Check $policy 'INVENTORY'
        $inventory.status | Should -Be 'Warning'
        $inventory.message | Should -Match 'locked-definition \(management group\) in assignment "Contoso deploy" \(AuthorizationFailed\)'
        $inventory.message | Should -Not -Match 'contoso-root'
    }

    It 'notes that SQL servers must be created Entra-only' {
        (Get-Check (Get-DemoPolicyConstraint -Config (New-TestConfig)) 'SQLENTRAONLY').message | Should -Match 'azureADOnlyAuthentication'
    }

    It 'names the extensions policy adds and the machines they land on' {
        $message = (Get-Check (Get-DemoPolicyConstraint -Config (New-TestConfig)) 'EXTENSIONS').message
        $message | Should -Match 'ConfigurationforWindows on T1 and the T2 host'
        $message | Should -Match 'retry when Azure returns Conflict'
    }

    It 'describes the public IP change' {
        (Get-Check (Get-DemoPolicyConstraint -Config (New-TestConfig)) 'PUBLICIP').message | Should -Match 'ipTag RoutingPreference=Internet'
    }

    It 'reads the IP tag from the assigned rule''s effect at run time, from a Modify too, so no tag or policy name is hard-coded (ADR 0022)' {
        $script:definitions["$mg/policyDefinitions/pip-append"] = New-Definition -DisplayName 'Tag public IP addresses (example)' -Condition @{
            field = 'type'; equals = 'Microsoft.Network/publicIPAddresses'
        } -Then @{ effect = 'modify'; details = @{ roleDefinitionIds = @('/providers/Microsoft.Authorization/roleDefinitions/role'); operations = @(@{ operation = 'add'; field = 'Microsoft.Network/publicIPAddresses/ipTags[*]'; value = @{ ipTagType = 'NetworkDomain'; tag = 'contoso.example' } }) } }
        $check = Get-Check (Get-DemoPolicyConstraint -Config (New-TestConfig)) 'PUBLICIP'
        $check.status | Should -Be 'Warning'
        $check.message | Should -Match 'ipTag NetworkDomain=contoso\.example'
        $check.message | Should -Not -Match 'RoutingPreference'
        $check.evidence.policies | Should -Be 'Tag public IP addresses (example)'
    }

    It 'says workload identities are not affected by MFA enforcement' {
        (Get-Check (Get-DemoPolicyConstraint -Config (New-TestConfig)) 'MFA').message | Should -Match 'Workload identities'
    }

    It 'fails a blocked VM size, ignoring case, and suggests profiles whose sizes are allowed' {
        $script:definitions = New-DefinitionSet -BlockedSkus @('standard_d2s_v5', 'Standard_HB60rs')
        $check = Get-Check (Get-DemoPolicyConstraint -Config (New-TestConfig -Override @{ profile = 'lowest-cost' })) 'VMSIZE'
        $check.status | Should -Be 'Fail'
        $check.message | Should -Match 'T1 size Standard_D2s_v5 \(Block VM SKU Sizes\)'
        $check.message | Should -Not -Match 'T2 host'
        $check.remediation | Should -Match 'demo-day \(T1 Standard_D4as_v5'
        $check.remediation | Should -Match 'enhanced-performance'
    }

    It 'passes a size the policy blocks only for Regular priority when the VM is Spot' {
        $script:definitions = New-DefinitionSet -BlockedSkus @('Standard_D2s_v5')
        $check = Get-Check (Get-DemoPolicyConstraint -Config (New-TestConfig -Override @{ profile = 'lowest-cost'; t1Priority = 'Spot' })) 'VMSIZE'
        $check.status | Should -Be 'Pass'
    }

    It 'fails when a policy denies a resource type the demo creates' {
        $script:definitions = New-DefinitionSet -NotAllowedTypes @('microsoft.classiccompute/virtualmachines', 'Microsoft.Network/bastionHosts')
        $check = Get-Check (Get-DemoPolicyConstraint -Config (New-TestConfig)) 'RESOURCETYPES'
        $check.status | Should -Be 'Fail'
        $check.message | Should -Match 'Microsoft.Network/bastionHosts \(Not allowed resource types\)'
        $check.evidence.denied.Count | Should -Be 1
    }

    It 'warns, skips the other checks, and assumes private mode when the assignments cannot be read' {
        $script:listFails = $true
        $policy = Get-DemoPolicyConstraint -Config (New-TestConfig -Override @{ networkMode = 'auto' })
        $policy.Results.checkId | Should -Be @('PREFLIGHT.POLICY.INVENTORY', 'PREFLIGHT.POLICY.SQLPUBLIC')
        (Get-Check $policy 'INVENTORY').status | Should -Be 'Warning'
        (Get-Check $policy 'INVENTORY').message | Should -Match 'AuthorizationFailed'
        $sql = Get-Check $policy 'SQLPUBLIC'
        $sql.status | Should -Be 'Warning'
        $sql.evidence.effectiveNetworkMode | Should -Be 'private'
        $sql.evidence.assumed | Should -BeTrue
    }

    It 'passes a subscription with no policy assignments and resolves auto to public' {
        $script:assignments = @()
        $policy = Get-DemoPolicyConstraint -Config (New-TestConfig -Override @{ networkMode = 'auto' })
        $policy.Results.checkId | Should -Be @('PREFLIGHT.POLICY.INVENTORY', 'PREFLIGHT.POLICY.SQLPUBLIC', 'PREFLIGHT.POLICY.VMSIZE', 'PREFLIGHT.POLICY.RESOURCETYPES')
        $policy.Results.status | Should -Be @('Pass', 'Pass', 'Pass', 'Pass')
        (Get-Check $policy 'SQLPUBLIC').evidence.effectiveNetworkMode | Should -Be 'public'
        $policy.Complete | Should -BeTrue
    }
}

Describe 'Resolve-DemoNetworkMode' {
    It '<Configured> with <Case> resolves to <Effective> (<Status>)' -ForEach @(
        @{ Configured = 'auto'; Case = 'a policy that turns public access off'; Policies = @('Deny SQL public access'); Unknown = $false; Effective = 'private'; Status = 'Pass'; Assumed = $false }
        @{ Configured = 'auto'; Case = 'no such policy'; Policies = @(); Unknown = $false; Effective = 'public'; Status = 'Pass'; Assumed = $false }
        @{ Configured = 'auto'; Case = 'an incomplete inventory'; Policies = @(); Unknown = $true; Effective = 'private'; Status = 'Warning'; Assumed = $true }
        @{ Configured = 'auto'; Case = 'a policy and an incomplete inventory'; Policies = @('Deny SQL public access'); Unknown = $true; Effective = 'private'; Status = 'Pass'; Assumed = $false }
        @{ Configured = 'public'; Case = 'a policy that turns public access off'; Policies = @('Deny SQL public access'); Unknown = $false; Effective = 'public'; Status = 'Fail'; Assumed = $false }
        @{ Configured = 'public'; Case = 'no such policy'; Policies = @(); Unknown = $false; Effective = 'public'; Status = 'Pass'; Assumed = $false }
        @{ Configured = 'public'; Case = 'an incomplete inventory'; Policies = @(); Unknown = $true; Effective = 'public'; Status = 'Warning'; Assumed = $false }
        @{ Configured = 'private'; Case = 'a policy that turns public access off'; Policies = @('Deny SQL public access'); Unknown = $false; Effective = 'private'; Status = 'Pass'; Assumed = $false }
        @{ Configured = 'private'; Case = 'an incomplete inventory'; Policies = @(); Unknown = $true; Effective = 'private'; Status = 'Pass'; Assumed = $false }
    ) {
        $result = Resolve-DemoNetworkMode -ConfiguredMode $Configured -SqlPublicAccessPolicy $Policies -PolicyUnknown:$Unknown
        $result.ConfiguredMode | Should -Be $Configured
        $result.EffectiveMode | Should -Be $Effective
        $result.Status | Should -Be $Status
        $result.Assumed | Should -Be $Assumed
        $result.Message | Should -Not -BeNullOrEmpty
        if ($Status -ne 'Pass') {
            $result.Remediation | Should -Not -BeNullOrEmpty
        }
    }

    It 'names the policy in the message' {
        (Resolve-DemoNetworkMode -ConfiguredMode auto -SqlPublicAccessPolicy 'Deny SQL public access').Message | Should -Match 'Deny SQL public access'
    }
}

Describe 'Policy rule evaluation' {
    It 'evaluates <Case>' -ForEach @(
        @{ Case = 'in with a parameter list, ignoring case'; Condition = @{ field = 'type'; in = "[parameters('types')]" }; Fact = @{ type = 'Microsoft.Sql/servers' }; Parameter = @{ types = @('microsoft.sql/SERVERS') }; Expected = $true }
        @{ Case = 'notIn with a parameter list'; Condition = @{ field = 'type'; notIn = "[parameters('types')]" }; Fact = @{ type = 'Microsoft.Sql/servers' }; Parameter = @{ types = @('Microsoft.Web/sites') }; Expected = $true }
        @{ Case = 'like with a wildcard'; Condition = @{ field = 'type'; like = 'Microsoft.Network/*' }; Fact = @{ type = 'Microsoft.Network/bastionHosts' }; Parameter = @{}; Expected = $true }
        @{ Case = 'match with digits'; Condition = @{ field = 'Microsoft.Compute/virtualMachines/sku.name'; match = 'Standard_D#s_v5' }; Fact = @{ type = 'Microsoft.Compute/virtualMachines'; 'Microsoft.Compute/virtualMachines/sku.name' = 'Standard_D2s_v5' }; Parameter = @{}; Expected = $true }
        @{ Case = 'an unknown property as unknown'; Condition = @{ field = 'location'; equals = 'westus3' }; Fact = @{ type = 'Microsoft.Sql/servers' }; Parameter = @{}; Expected = $null }
        @{ Case = 'an unresolved parameter as unknown'; Condition = @{ field = 'type'; in = "[parameters('missing')]" }; Fact = @{ type = 'Microsoft.Sql/servers' }; Parameter = @{}; Expected = $null }
        @{ Case = 'an alias of another resource type as absent'; Condition = @{ field = 'Microsoft.Compute/virtualMachineScaleSets/sku.name'; exists = 'true' }; Fact = @{ type = 'Microsoft.Compute/virtualMachines' }; Parameter = @{}; Expected = $false }
        @{ Case = 'a namespace-level alias as unknown'; Condition = @{ field = 'Microsoft.Compute/imagePublisher'; equals = 'MicrosoftSQLServer' }; Fact = @{ type = 'Microsoft.Compute/virtualMachines' }; Parameter = @{}; Expected = $null }
        @{ Case = 'allOf as false when one part is false, even with an unknown part'; Condition = @{ allOf = @(@{ field = 'location'; equals = 'x' }, @{ field = 'type'; equals = 'Microsoft.Web/sites' }) }; Fact = @{ type = 'Microsoft.Sql/servers' }; Parameter = @{}; Expected = $false }
        @{ Case = 'anyOf as unknown when no part is true and one is unknown'; Condition = @{ anyOf = @(@{ field = 'location'; equals = 'x' }, @{ field = 'type'; equals = 'Microsoft.Web/sites' }) }; Fact = @{ type = 'Microsoft.Sql/servers' }; Parameter = @{}; Expected = $null }
        @{ Case = 'not around a known result'; Condition = @{ not = @{ field = 'type'; equals = 'Microsoft.Web/sites' } }; Fact = @{ type = 'Microsoft.Sql/servers' }; Parameter = @{}; Expected = $true }
        @{ Case = 'a count as unknown'; Condition = @{ count = @{ field = 'Microsoft.Network/publicIPAddresses/ipTags[*]' }; less = 1 }; Fact = @{ type = 'Microsoft.Network/publicIPAddresses' }; Parameter = @{}; Expected = $null }
    ) {
        $result = InModuleScope DbHubDemo -Parameters @{ Condition = $Condition; Fact = $Fact; Parameter = $Parameter } {
            Test-DemoPolicyCondition -Condition (ConvertTo-DemoPolicyData -InputObject $Condition) -Fact $Fact -Parameter $Parameter
        }
        if ($null -eq $Expected) {
            $result | Should -BeNullOrEmpty
        }
        else {
            $result | Should -Be $Expected
        }
    }

    It 'lists the types a rule selects and the fields it reads' {
        $facts = InModuleScope DbHubDemo {
            $condition = ConvertTo-DemoPolicyData -InputObject @{ allOf = @(
                    @{ anyOf = @(@{ field = 'type'; equals = 'Microsoft.Compute/virtualMachines' }, @{ not = @{ field = 'type'; notIn = @('Microsoft.Compute/virtualMachineScaleSets') } }) }
                    @{ field = 'Microsoft.Compute/virtualMachines/sku.name'; in = @('Standard_HB60rs') }
                    @{ value = "[field('location')]"; equals = 'westus3' }
                ) 
            }
            Get-DemoPolicyRuleFact -Condition $condition -Parameter @{}
        }
        $facts.Types | Sort-Object | Should -Be @('Microsoft.Compute/virtualMachines', 'Microsoft.Compute/virtualMachineScaleSets')
        $facts.AnyType | Should -BeFalse
        $facts.Fields | Sort-Object | Should -Be @('location', 'Microsoft.Compute/virtualMachines/sku.name')
    }
}

Describe 'Get-DemoPolicyConstraint cache' {
    BeforeEach {
        $script:listFails = $false
        $script:assignments = New-AssignmentSet
        $script:definitions = New-DefinitionSet
        # A complete inventory: drop the set member whose definition answers 403.
        $deploySet = $script:definitions["$mg/policySetDefinitions/contoso-deploy"]['properties']
        $deploySet['policyDefinitions'] = @($deploySet['policyDefinitions'] | Where-Object { $_['policyDefinitionReferenceId'] -ne 'locked' })
        Set-PolicyMock
        $script:definitionReads = 0
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith { $script:definitionReads++; Get-PolicyFakeResult -Url $Uri }
        $script:cacheDirectory = Join-Path -Path $TestDrive -ChildPath ('cache-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:statusList = { param([object] $Policy) @($Policy.Results | ForEach-Object { '{0}={1}' -f $_.checkId, $_.status }) }
    }

    It 'saves and reuses nothing when CacheHours is 0' {
        Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheDirectory $script:cacheDirectory | Out-Null
        Test-Path -LiteralPath $script:cacheDirectory | Should -BeFalse
    }

    It 'reuses a complete inventory while nothing it depends on changed, without reading a definition' {
        $first = Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheHours 24 -CacheDirectory $script:cacheDirectory
        (Get-Check -Policy $first -Name 'INVENTORY').status | Should -Be 'Pass'
        $reads = $script:definitionReads
        $reads | Should -BeGreaterThan 0
        $files = @(Get-ChildItem -LiteralPath $script:cacheDirectory -Filter 'policy-inventory-*.clixml')
        $files.Count | Should -Be 1
        $files[0].Name | Should -Not -Match '11111111'

        $second = Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheHours 24 -CacheDirectory $script:cacheDirectory
        $script:definitionReads | Should -Be $reads
        (& $script:statusList $second) | Should -Be (& $script:statusList $first)
        $second.NetworkMode.EffectiveMode | Should -Be $first.NetworkMode.EffectiveMode
        $second.AssignmentCount | Should -Be $first.AssignmentCount
        $inventory = Get-Check -Policy $second -Name 'INVENTORY'
        $inventory.message | Should -Match 'Reused from the inventory of .* UTC'
        $inventory.evidence['reusedFromUtc'] | Should -Not -BeNullOrEmpty
        (Get-Check -Policy $second -Name 'SQLPUBLIC').evidence['reusedFromUtc'] | Should -Not -BeNullOrEmpty
        $second.ReusedFromUtc | Should -Not -BeNullOrEmpty
    }

    It 'reads every definition again when an assignment changed' {
        Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheHours 24 -CacheDirectory $script:cacheDirectory | Out-Null
        $reads = $script:definitionReads
        $script:assignments[1]['properties']['enforcementMode'] = 'DoNotEnforce'
        $second = Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheHours 24 -CacheDirectory $script:cacheDirectory
        $script:definitionReads | Should -BeGreaterThan $reads
        (Get-Check -Policy $second -Name 'INVENTORY').message | Should -Not -Match 'Reused'
    }

    It 'reads every definition again when a configuration value it reads changed' {
        Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheHours 24 -CacheDirectory $script:cacheDirectory | Out-Null
        $reads = $script:definitionReads
        Get-DemoPolicyConstraint -Config (New-TestConfig -Override @{ networkMode = 'private' }) -CacheHours 24 -CacheDirectory $script:cacheDirectory | Out-Null
        $script:definitionReads | Should -BeGreaterThan $reads
    }

    It 'reads every definition again when the cache is older than CacheHours' {
        Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheHours 24 -CacheDirectory $script:cacheDirectory | Out-Null
        $reads = $script:definitionReads
        $file = (Get-ChildItem -LiteralPath $script:cacheDirectory -Filter 'policy-inventory-*.clixml' | Select-Object -First 1).FullName
        $entry = Import-Clixml -LiteralPath $file
        $entry.CreatedUtc = [System.DateTime]::UtcNow.AddHours(-30).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        Export-Clixml -InputObject $entry -LiteralPath $file -Depth 12
        $second = Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheHours 24 -CacheDirectory $script:cacheDirectory
        $script:definitionReads | Should -BeGreaterThan $reads
        (Get-Check -Policy $second -Name 'INVENTORY').message | Should -Not -Match 'Reused'
    }

    It 'never saves an incomplete inventory' {
        $script:definitions = New-DefinitionSet
        $policy = Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheHours 24 -CacheDirectory $script:cacheDirectory
        (Get-Check -Policy $policy -Name 'INVENTORY').status | Should -Be 'Warning'
        @(Get-ChildItem -LiteralPath $script:cacheDirectory -Filter '*.clixml' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'reads every definition again when the cache file is unreadable' {
        Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheHours 24 -CacheDirectory $script:cacheDirectory | Out-Null
        $reads = $script:definitionReads
        $file = (Get-ChildItem -LiteralPath $script:cacheDirectory -Filter 'policy-inventory-*.clixml' | Select-Object -First 1).FullName
        Set-Content -LiteralPath $file -Value 'not clixml'
        $second = Get-DemoPolicyConstraint -Config (New-TestConfig) -CacheHours 24 -CacheDirectory $script:cacheDirectory
        $script:definitionReads | Should -BeGreaterThan $reads
        (Get-Check -Policy $second -Name 'INVENTORY').status | Should -Be 'Pass'
    }
}

Describe 'Get-DemoCanonicalText' {
    It 'gives the same text whatever the key order, and different text when a value changes' {
        InModuleScope DbHubDemo {
            $a = [ordered]@{ b = 1; a = @{ y = 'x'; x = @(1, 'two', $true) } }
            $b = [ordered]@{ a = [ordered]@{ x = @(1, 'two', $true); y = 'x' }; b = 1 }
            $c = [ordered]@{ a = [ordered]@{ x = @(1, 'two', $false); y = 'x' }; b = 1 }
            Get-DemoCanonicalText -Value $a | Should -Be (Get-DemoCanonicalText -Value $b)
            Get-DemoCanonicalText -Value $a | Should -Not -Be (Get-DemoCanonicalText -Value $c)
            Get-DemoCanonicalText -Value ([pscustomobject]@{ b = 1; a = 'z' }) | Should -Be '{"a":"z","b":1}'
        }
    }
}
