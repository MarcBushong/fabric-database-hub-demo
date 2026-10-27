BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    $config = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
    # Obviously fake IDs: every group repeats one digit.
    $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
    $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
    $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
    # Every VM size in the profile catalog: the region's SKU list (Get-DemoRegionSku) is one REST read.
    $catalog = Get-DemoProfile
    $script:profileSizes = @(foreach ($name in @($catalog.profiles.Keys)) { $catalog.profiles[$name].t1.size; $catalog.profiles[$name].t2Host.size }) | Select-Object -Unique
    function ConvertTo-SkuListJson([object[]] $Sku) {
        ConvertTo-Json -InputObject @{ value = @($Sku) } -Depth 8
    }

    function Set-HappyAzMock {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
        # The guard has its own tests (DbHubDemo.Guard.Tests.ps1); here it passes, and the hook above records the context.
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith {
            New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'The subscription guard passed.'
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $json = switch -Regex ($joined) {
                '^rest .*permissions' { '{"value":[{"actions":["*"],"notActions":["Microsoft.Authorization/*/Delete","Microsoft.Authorization/*/Write","Microsoft.Authorization/elevateAccess/Action"]}]}' }
                '^rest .*policyAssignments' { $script:policyAssignmentsJson }
                '^provider list' { '[' + (('Microsoft.Sql', 'Microsoft.SqlVirtualMachine', 'Microsoft.AzureArcData', 'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.Consumption', 'Microsoft.DevTestLab' | ForEach-Object { '{"namespace":"' + $_ + '","registrationState":"Registered"}' }) -join ',') + ']' }
                '^rest .*Microsoft\.Compute/skus' { ConvertTo-SkuListJson -Sku @($script:profileSizes | ForEach-Object { [ordered]@{ name = $_; resourceType = 'virtualMachines'; restrictions = @() } }) }
                '^rest .*Microsoft\.DBforPostgreSQL/locations/[^/]+/capabilities' { $script:pgCapabilitiesJson }
                '^deployment group show .*--name pgflex01' { $script:pgDeploymentJson }
                '^deployment operation group list .*--name pgflex01' { $script:pgOperationsJson }
                '^vm list-usage' { '[{"name":{"value":"cores"},"currentValue":0,"limit":20},{"name":{"value":"standardDSv5Family"},"currentValue":0,"limit":10},{"name":{"value":"standardESv5Family"},"currentValue":0,"limit":10}]' }
                '^network list-usages' { '[{"name":{"value":"PublicIPAddresses"},"currentValue":0,"limit":20}]' }
                '^security pricing list' { '[{"name":"VirtualMachines","pricingTier":"Standard","subPlan":"P2"},{"name":"Dns","pricingTier":"Free","subPlan":null}]' }
                '^sql server list' { '[]' }
                '^deployment sub what-if' {
                    $parameterFile = ($ArgumentList | Where-Object { $_ -like '@*' } | Select-Object -First 1).Substring(1)
                    $script:whatIfParameters = Get-Content -LiteralPath $parameterFile -Raw | ConvertFrom-Json -AsHashtable
                    '{"status":"Succeeded","changes":[{"changeType":"Create"},{"changeType":"Create"}]}'
                }
                default { '{}' }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = $json; StdErr = '' }
        }
        # Microsoft Graph (P6) and tenant-level policy definitions go through Invoke-DemoRestRequest with a verified token.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            $body = switch -Regex ($Uri) {
                '^https://graph\.microsoft\.com/v1\.0/groups/[^/?]+/owners' { $script:groupOwnersJson; break }
                '^https://graph\.microsoft\.com/v1\.0/groups/' { '{"id":"77777777-7777-7777-7777-777777777777","displayName":"DbHub T3 admins"}'; break }
                'policyDefinitions/sql-public-off' { $script:sqlPublicOffJson; break }
                default { $null }
            }
            if ($null -eq $body) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('HTTP 404: no fake for {0}' -f $Uri); StatusCode = 404 }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = $body; StdErr = ''; StatusCode = 200 }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith {
            [pscustomobject]@{ Results = @(New-DemoResult -CheckId 'PREFLIGHT.COST.SESSION' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'Within the ceiling.') }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @() }
        # Phase 18's P11 check has its own tests (DbHubDemo.FabricItem.Tests.ps1); here it only has to be called.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricViewerLicense -MockWith {
            New-DemoResult -CheckId 'PREFLIGHT.FABRIC.VIEWERLICENSE' -Area 'preflight' -Target 'fabric' -Status 'Warning' -Message 'F16 is smaller than F64.'
        }
        # P5 by name (Phase 26a) has its own tests (DbHubDemo.FabricResolve.Tests.ps1); here it sends nothing.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricResolution -MockWith {
            [pscustomobject]@{ Result = (New-DemoResult -CheckId 'PREFLIGHT.P5.WORKSPACE' -Area 'preflight' -Target 'fabric' -Status 'Pass' -Message 'The workspace is ready.'); Config = $Config; CapacityResult = $null }
        }
    }

    # One policy assignment whose definition turns off public network access on SQL servers (fake data).
    $script:pgCapabilitiesJson = '{}'
    $script:pgDeploymentJson = '{}'
    $script:pgOperationsJson = '[]'
    $script:sqlPublicOffAssignmentsJson = (@{ value = @(@{ name = 'paas-network'; properties = @{ displayName = 'PaaS network access (example)'; scope = '/providers/Microsoft.Management/managementGroups/contoso-root'; enforcementMode = 'Default'; policyDefinitionId = '/providers/Microsoft.Management/managementGroups/contoso-root/providers/Microsoft.Authorization/policyDefinitions/sql-public-off' } }) } | ConvertTo-Json -Depth 10)
    $script:sqlPublicOffJson = (@{ properties = @{ displayName = 'SQL servers should disable public network access (example)'; parameters = @{}; policyRule = @{ 'if' = @{ field = 'type'; equals = 'Microsoft.Sql/servers' }; 'then' = @{ effect = 'Modify'; details = @{ operations = @(@{ operation = 'addOrReplace'; field = 'Microsoft.Sql/servers/publicNetworkAccess'; value = 'Disabled' }) } } } } } | ConvertTo-Json -Depth 20)
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Invoke-DemoPreflight' {
    BeforeEach {
        $script:policyAssignmentsJson = '{"value":[]}'
        $script:groupOwnersJson = '{"value":[{"id":"88888888-8888-8888-8888-888888888888"}]}'
        $script:whatIfParameters = $null
        $script:pgCapabilitiesJson = '{}'
        $script:pgDeploymentJson = '{}'
        $script:pgOperationsJson = '[]'
    }

    It 'fails T4 on a size Azure refused for the same zone, warns for one more try in another zone, and says nothing without a refusal (Phase 24)' {
        Set-HappyAzMock
        # Live, 2026-10-26: the capability list included Standard_B1ms, and Azure still refused it with SkuNotAvailable;
        # the code is in the server's deployment operation, not in the deployment's own error.
        $refused = { param([string] $Sku, [string] $Zone) ConvertTo-Json -Depth 20 -InputObject @{ name = 'pgflex01'; properties = @{ provisioningState = 'Failed'; timestamp = '2026-10-26T14:11:42Z'; parameters = @{ sizing = @{ value = @{ skuName = $Sku; tier = 'Burstable' } }; availabilityZone = @{ value = $Zone } }; error = @{ code = 'DeploymentFailed'; details = @(@{ code = 'ResourceDeploymentFailure'; details = $null }) } } } }
        $script:pgOperationsJson = ConvertTo-Json -Depth 20 -InputObject @(@{ properties = @{ provisioningState = 'Failed'; targetResource = @{ resourceType = 'Microsoft.DBforPostgreSQL/flexibleServers' }; statusMessage = @{ status = 'Failed'; error = @{ code = 'SkuNotAvailable'; message = 'Specified SKU is not supported in this region. Please choose a different SKU.' } } } })
        $script:pgDeploymentJson = & $refused 'Standard_B1ms' ''
        $check = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU'
        $check.status | Should -Be 'Fail'
        $check.remediation | Should -Match 'Set t4SkuName to Standard_B2s, the documented fallback'

        $zoned = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $zoned[$key] = $config[$key] }
        $zoned['t4AvailabilityZone'] = '2'
        $check = Invoke-DemoPreflight -Config $zoned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU'
        $check.status | Should -Be 'Warning'
        $check.message | Should -Match 'once more in zone 2'

        $zoned['t4SkuName'] = 'Standard_B2s'
        @(Invoke-DemoPreflight -Config $zoned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU').Count | Should -Be 0 -Because 'the refusal was for another size'

        # Live, 2026-10-26: West US 3 refused the fallback too; the remediation then names no further size.
        $script:pgDeploymentJson = & $refused 'Standard_B2s' ''
        $check = Invoke-DemoPreflight -Config $zoned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU'
        $check.status | Should -Be 'Warning' -Because 'this configuration pins zone 2, and the refusal had no zone'
        $check.remediation | Should -Match 'already the documented Burstable fallback'
        $check.remediation | Should -Match 'Region access request'
        $check.remediation | Should -Match 'Standard_D2ds_v5, the documented General Purpose option'
        $check.remediation | Should -Not -Match 'Set t4SkuName to Standard_B2s'

        $script:pgDeploymentJson = '{"name":"pgflex01","properties":{"provisioningState":"Succeeded"}}'
        @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU').Count | Should -Be 0
    }

    It 'checks that the region offers T4''s Burstable size and PostgreSQL version, from the Location Based Capabilities API (Phase 24)' {
        Set-HappyAzMock
        $capabilities = { param([string[]] $Versions) ConvertTo-Json -Depth 10 -InputObject @{ value = @(@{ supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_B1ms' }, @{ name = 'Standard_B2s' }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @(@{ name = 'Standard_D2ds_v5' }) }); supportedServerVersions = @($Versions | ForEach-Object { @{ name = $_ } }) }) } }
        $script:pgCapabilitiesJson = & $capabilities @('17', '18')
        $check = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Pass'
        $check.message | Should -Match 'Standard_B1ms and PostgreSQL 18'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -match '^rest --method get --url https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft\.DBforPostgreSQL/locations/westus3/capabilities\?api-version=' }

        $script:pgCapabilitiesJson = & $capabilities @('16', '17')
        (Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY').status | Should -Be 'Fail'

        # The documented General Purpose option is checked in its own edition (the tier follows the size).
        $gp = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $gp[$key] = $config[$key] }
        $gp['t4SkuName'] = 'Standard_D2ds_v5'
        $script:pgCapabilitiesJson = & $capabilities @('17', '18')
        $check = Invoke-DemoPreflight -Config $gp -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Pass'
        $check.message | Should -Match 'GeneralPurpose Standard_D2ds_v5 and PostgreSQL 18'
        $check.evidence.tier | Should -Be 'GeneralPurpose'
        $gp['t4SkuName'] = 'Standard_B2s'
        $script:pgCapabilitiesJson = ConvertTo-Json -Depth 10 -InputObject @{ value = @(@{ supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_B1ms' }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @(@{ name = 'Standard_B2s' }) }); supportedServerVersions = @(@{ name = '18' }) }) }
        (Invoke-DemoPreflight -Config $gp -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY').status | Should -Be 'Fail' -Because 'a Burstable size listed under another edition isn''t offered as Burstable'

        $script:pgCapabilitiesJson = '{}'
        (Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY').status | Should -Be 'Warning'

        $off = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $off[$key] = $config[$key] }
        $off['t4Enabled'] = $false
        (Invoke-DemoPreflight -Config $off -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY').status | Should -Be 'Not selected'
    }

    It 'passes every automated check in a ready subscription' {
        Set-HappyAzMock
        $results = Invoke-DemoPreflight -Config $config
        $failed = $results | Where-Object { $_.status -eq 'Fail' }
        $failed | Should -BeNullOrEmpty
        ($results | Where-Object checkId -eq 'PREFLIGHT.P1.CONTRIBUTOR').status | Should -Be 'Pass'
        ($results | Where-Object checkId -eq 'PREFLIGHT.P6.GROUP').status | Should -Be 'Pass'
        ($results | Where-Object checkId -eq 'PREFLIGHT.P4.HUBSETTING').status | Should -Be 'Manual action required'
        ($results | Where-Object checkId -eq 'PREFLIGHT.POLICY.INVENTORY').status | Should -Be 'Pass'
        ($results | Where-Object checkId -eq 'PREFLIGHT.POLICY.SQLPUBLIC').status | Should -Be 'Pass'
        ($results | Where-Object checkId -eq 'PREFLIGHT.POLICY.WHATIF').status | Should -Be 'Pass'
    }

    It 'reads the region''s SKUs once, with the Resource SKUs REST API instead of az vm list-skus' {
        Set-HappyAzMock
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.SIZE_T1').status | Should -Be 'Pass'
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.SIZE_T2HOST').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'rest' -and $ArgumentList[2] -eq 'get' -and $ArgumentList[4] -eq 'https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft.Compute/skus?api-version=2021-07-01&$filter=location eq ''westus3'''
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[1] -eq 'list-skus' }
    }

    It 'passes the policy cache limit to the policy inventory' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Get-DemoPolicyConstraint -MockWith {
            [pscustomobject]@{ Results = @(); NetworkMode = (Resolve-DemoNetworkMode -ConfiguredMode 'private') }
        }
        Invoke-DemoPreflight -Config $config -SkipWhatIf -PolicyCacheHours 168 | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoPolicyConstraint -Times 1 -Exactly -ParameterFilter { $CacheHours -eq 168 }
    }

    It 'resolves networkMode auto from Azure Policy and passes the effective mode to what-if and the cost estimate' {
        Set-HappyAzMock
        $script:policyAssignmentsJson = $script:sqlPublicOffAssignmentsJson
        $results = Invoke-DemoPreflight -Config $config
        $sql = $results | Where-Object checkId -eq 'PREFLIGHT.POLICY.SQLPUBLIC'
        $sql.status | Should -Be 'Pass'
        $sql.evidence.effectiveNetworkMode | Should -Be 'private'
        $script:whatIfParameters.parameters.networkMode.value | Should -Be 'private'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter {
            $NetworkMode -eq 'private' -and @($DefenderPlans).Count -eq 2 -and $DefenderPlans[0].name -eq 'VirtualMachines'
        }
    }

    It 'resolves networkMode auto to public when no policy turns public access off' {
        Set-HappyAzMock
        Invoke-DemoPreflight -Config $config | Out-Null
        $script:whatIfParameters.parameters.networkMode.value | Should -Be 'public'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $NetworkMode -eq 'public' }
    }

    It 'skips the policy inventory with -SkipPolicyInventory and resolves auto to private' {
        Set-HappyAzMock
        $results = Invoke-DemoPreflight -Config $config -SkipPolicyInventory
        ($results | Where-Object checkId -eq 'PREFLIGHT.POLICY.INVENTORY').status | Should -Be 'Not selected'
        $sql = $results | Where-Object checkId -eq 'PREFLIGHT.POLICY.SQLPUBLIC'
        $sql.status | Should -Be 'Not selected'
        $sql.evidence.effectiveNetworkMode | Should -Be 'private'
        $script:whatIfParameters.parameters.networkMode.value | Should -Be 'private'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { ($ArgumentList -join ' ') -match 'policyAssignments' }
    }

    It 'estimates cost without Defender when the plans cannot be read' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[0] -eq 'security' } -MockWith {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (AuthorizationFailed) no access' }
        }
        Invoke-DemoPreflight -Config $config | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $null -eq $DefenderPlans }
    }

    It 'checks the T3 free offer and passes the result to the cost estimate' {
        Set-HappyAzMock
        $results = Invoke-DemoPreflight -Config $config
        $freeOffer = $results | Where-Object checkId -eq 'PREFLIGHT.T3.FREEOFFER'
        $freeOffer.status | Should -Be 'Pass'
        $freeOffer.evidence.useFreeLimit | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $T3UseFreeLimit -eq $true }
        # The what-if deploys T3 with the same setting (Phase 8).
        $script:whatIfParameters.parameters.t3UseFreeLimit.value | Should -BeTrue
        $script:whatIfParameters.parameters.t3AdminGroupObjectId.value | Should -Be '77777777-7777-7777-7777-777777777777'
    }

    It 'falls back to regular serverless in the cost estimate when the free offer is unavailable' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT3FreeOfferStatus -MockWith {
            [pscustomobject]@{ UseFreeLimit = $false; Result = (New-DemoResult -CheckId 'PREFLIGHT.T3.FREEOFFER' -Area 'preflight' -Target 'T3' -Status 'Warning' -Message 'Ten free databases are in use.' -Evidence @{ useFreeLimit = $false }) }
        }
        $results = Invoke-DemoPreflight -Config $config
        ($results | Where-Object checkId -eq 'PREFLIGHT.T3.FREEOFFER').status | Should -Be 'Warning'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $T3UseFreeLimit -eq $false }
        $script:whatIfParameters.parameters.t3UseFreeLimit.value | Should -BeFalse
    }

    It 'stops after the guard when it fails' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith {
            throw "Subscription guard: check 'account' failed: the Azure CLI reaches subscription 11111111-2222-3333-4444-555555555555 as 'someone@example.com', not as azureAccount 'you@example.com'. Nothing was changed."
        }
        $results = Invoke-DemoPreflight -Config $config
        @($results).Count | Should -Be 1
        $results[0].status | Should -Be 'Fail'
        $results[0].checkId | Should -Be 'PREFLIGHT.GUARD.CONTEXT'
        $results[0].message | Should -Match "check 'account' failed"
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[0] -in 'rest', 'provider', 'vm', 'deployment', 'security' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 0
    }

    It 'passes the configured azureAccount to the guard' {
        Set-HappyAzMock
        Invoke-DemoPreflight -Config $config | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -Times 1 -Exactly -ParameterFilter {
            $SubscriptionId -eq '11111111-2222-3333-4444-555555555555' -and $TenantId -eq '66666666-7777-8888-9999-000000000000' -and $Account -eq 'you@example.com'
        }
    }

    It 'reads the P6 group from Microsoft Graph with a verified token, never with az ad' {
        Set-HappyAzMock
        $results = Invoke-DemoPreflight -Config $config
        ($results | Where-Object checkId -eq 'PREFLIGHT.P6.GROUP').status | Should -Be 'Pass'
        ($results | Where-Object checkId -eq 'PREFLIGHT.P6.GROUP').evidence.groupDisplayName | Should -Be 'DbHub T3 admins'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Uri -eq 'https://graph.microsoft.com/v1.0/groups/77777777-7777-7777-7777-777777777777?$select=id,displayName' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Uri -eq 'https://graph.microsoft.com/v1.0/groups/77777777-7777-7777-7777-777777777777/owners?$select=id' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'ad' }
    }

    It 'fails P6 when the group is not in the configured tenant' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -ParameterFilter { $Uri -like 'https://graph.microsoft.com/v1.0/groups/*' } -MockWith {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 404: {"error":{"code":"Request_ResourceNotFound"}}'; StatusCode = 404 }
        }
        $p6 = Invoke-DemoPreflight -Config $config | Where-Object checkId -eq 'PREFLIGHT.P6.GROUP'
        $p6.status | Should -Be 'Fail'
        $p6.message | Should -Match 'not found in the configured tenant'
    }

    It 'passes --subscription on every subscription-scoped call' {
        Set-HappyAzMock
        Invoke-DemoPreflight -Config $config | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter {
            $ArgumentList[0] -in 'provider', 'vm', 'network', 'deployment', 'security', 'sql' -and $ArgumentList -notcontains '--subscription'
        }
    }

    It 'fails P1 without Contributor-level permissions' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[0] -eq 'rest' -and ($ArgumentList -join ' ') -match 'Microsoft\.Authorization/permissions' } -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"value":[{"actions":["*/read"],"notActions":[]}]}'; StdErr = '' }
        }
        $results = Invoke-DemoPreflight -Config $config
        ($results | Where-Object checkId -eq 'PREFLIGHT.P1.CONTRIBUTOR').status | Should -Be 'Fail'
    }

    It 'registers missing providers and reports a Warning' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -like 'provider list*' } -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = '[{"namespace":"Microsoft.Compute","registrationState":"Registered"}]'; StdErr = '' }
        }
        $results = Invoke-DemoPreflight -Config $config
        ($results | Where-Object checkId -eq 'PREFLIGHT.P2.PROVIDERS').status | Should -Be 'Warning'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -like 'provider register --namespace Microsoft.AzureArcData*' } -Times 1 -Exactly
    }

    It 'only reports missing providers with -SkipProviderRegistration' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -like 'provider list*' } -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
        }
        $results = Invoke-DemoPreflight -Config $config -SkipProviderRegistration
        ($results | Where-Object checkId -eq 'PREFLIGHT.P2.PROVIDERS').status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[1] -eq 'register' } -Times 0
    }

    It 'fails quota when a family has too few vCPUs' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[1] -eq 'list-usage' } -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = '[{"name":{"value":"cores"},"currentValue":0,"limit":20},{"name":{"value":"standardDSv5Family"},"currentValue":0,"limit":10},{"name":{"value":"standardESv5Family"},"currentValue":9,"limit":10}]'; StdErr = '' }
        }
        $results = Invoke-DemoPreflight -Config $config
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.QUOTA').status | Should -Be 'Fail'
    }

    It 'warns when the caller does not own the T3 admin group' {
        Set-HappyAzMock
        $script:groupOwnersJson = '{"value":[{"id":"99999999-9999-9999-9999-999999999999"}]}'
        $results = Invoke-DemoPreflight -Config $config
        ($results | Where-Object checkId -eq 'PREFLIGHT.P6.GROUP').status | Should -Be 'Warning'
    }

    It 'fails the policy check when what-if reports a policy denial' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[0] -eq 'deployment' -and $ArgumentList[1] -eq 'sub' } -MockWith {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'RequestDisallowedByPolicy: storage accounts must disable shared key access' }
        }
        $results = Invoke-DemoPreflight -Config $config
        ($results | Where-Object checkId -eq 'PREFLIGHT.POLICY.WHATIF').status | Should -Be 'Fail'
    }

    It 'skips what-if with -SkipWhatIf' {
        Set-HappyAzMock
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.POLICY.WHATIF').status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[0] -eq 'deployment' -and $ArgumentList[1] -eq 'sub' } -Times 0
    }

    It 'reports the optional P11 viewer licensing (Phase 18) once, with the configuration and no token of its own' {
        Set-HappyAzMock
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf
        $license = @($results | Where-Object checkId -eq 'PREFLIGHT.FABRIC.VIEWERLICENSE')
        $license.Count | Should -Be 1
        $license[0].status | Should -Be 'Warning'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricViewerLicense -Times 1 -Exactly -ParameterFilter {
            $Config['fabric']['workspaceId'] -eq $config['fabric']['workspaceId'] -and $null -eq $Token -and $null -eq $CapacityResult
        }
        @($results | Where-Object { $_.status -eq 'Fail' }) | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DemoPreflight zones, disks, security types, and what-if parameters' {
    BeforeAll {
        function Copy-TestConfig([hashtable] $Override = @{}) {
            $copy = @{}
            foreach ($key in $config.Keys) { $copy[$key] = $config[$key] }
            $copy['securityType'] = @{ t1 = $config['securityType']['t1']; t2Host = $config['securityType']['t2Host'] }
            foreach ($key in $Override.Keys) { $copy[$key] = $Override[$key] }
            return $copy
        }

        function Set-ZonalSkuMock {
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[0] -eq 'rest' -and ($ArgumentList -join ' ') -match 'Microsoft\.Compute/skus' } -MockWith {
                $skus = @(
                    foreach ($size in $script:profileSizes) {
                        [ordered]@{ name = $size; resourceType = 'virtualMachines'; locationInfo = @([ordered]@{ location = 'westus3'; zones = @($script:vmZones) }); restrictions = @($script:vmRestrictions) }
                    }
                    [ordered]@{ name = 'Premium_LRS'; resourceType = 'disks'; locationInfo = @([ordered]@{ location = 'westus3'; zones = @('1', '2', '3') }); restrictions = @() }
                    [ordered]@{ name = 'PremiumV2_LRS'; resourceType = 'disks'; locationInfo = @([ordered]@{ location = 'westus3'; zones = @($script:diskZones) }); restrictions = @() }
                )
                [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-SkuListJson -Sku $skus); StdErr = '' }
            }
        }

        function Set-ImageMock([string] $Json) {
            $script:imageJson = $Json
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[0] -eq 'vm' -and $ArgumentList[1] -eq 'image' } -MockWith {
                [pscustomobject]@{ ExitCode = 0; StdOut = $script:imageJson; StdErr = '' }
            }
        }

        function Set-WhatIfCaptureMock([string] $ExistingVmsJson) {
            $script:existingVmsJson = $ExistingVmsJson
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[0] -eq 'vm' -and $ArgumentList[1] -eq 'list' } -MockWith {
                [pscustomobject]@{ ExitCode = 0; StdOut = $script:existingVmsJson; StdErr = '' }
            }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[0] -eq 'deployment' -and $ArgumentList[1] -eq 'sub' } -MockWith {
                $script:whatIfArguments = @($ArgumentList)
                $file = ($ArgumentList | Where-Object { $_.StartsWith('@') } | Select-Object -First 1).Substring(1)
                $script:whatIfParameters = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
                [pscustomobject]@{ ExitCode = 0; StdOut = '{"status":"Succeeded","changes":[{"changeType":"Create"}]}'; StdErr = '' }
            }
        }

        $trustedLaunchImage = '{"name":"16.0.250519","hyperVGeneration":"V2","features":[{"name":"SecurityType","value":"TrustedLaunchSupported"},{"name":"IsAcceleratedNetworkSupported","value":"True"}]}'
        $standardOnlyImage = '{"name":"16.0.250519","hyperVGeneration":"V2","features":[{"name":"IsAcceleratedNetworkSupported","value":"True"}]}'
    }

    BeforeEach {
        $script:vmZones = @('1', '2', '3')
        $script:vmRestrictions = @()
        $script:diskZones = @('1', '2', '3')
        $script:whatIfArguments = $null
        $script:whatIfParameters = $null
        Set-HappyAzMock
        Set-ZonalSkuMock
        Set-ImageMock -Json $trustedLaunchImage
    }

    AfterEach {
        Clear-DemoSecret
    }

    It 'reports the zone and Premium SSD v2 checks as Not selected without a zone' {
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ zone = $null; profile = 'demo-day' }) -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.ZONE').status | Should -Be 'Not selected'
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.PREMIUMV2').status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList -contains 'disks' } -Times 0
    }

    It 'passes the zone and Premium SSD v2 checks when the zone offers both' {
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ zone = '2'; profile = 'demo-day' }) -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.ZONE').status | Should -Be 'Pass'
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.PREMIUMV2').status | Should -Be 'Pass'
    }

    It 'fails the zone check when a size has a Zone restriction for the subscription' {
        $script:vmRestrictions = @([ordered]@{ type = 'Zone'; reasonCode = 'NotAvailableForSubscription'; values = @('westus3'); restrictionInfo = [ordered]@{ locations = @('westus3'); zones = @('2') } })
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ zone = '2'; profile = 'demo-day' }) -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.ZONE').status | Should -Be 'Fail'
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.SIZE_T1').status | Should -Be 'Pass'
    }

    It 'fails the zone check when a size is not offered in the zone' {
        $script:vmZones = @('1', '3')
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ zone = '2'; profile = 'lowest-cost' }) -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.ZONE').status | Should -Be 'Fail'
    }

    It 'fails Premium SSD v2 when the zone does not offer it' {
        $script:diskZones = @('1', '3')
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ zone = '2'; profile = 'enhanced-performance' }) -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.PREMIUMV2').status | Should -Be 'Fail'
    }

    It 'does not check Premium SSD v2 for a profile that does not use it' {
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ zone = '1'; profile = 'lowest-cost' }) -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.PREMIUMV2').status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList -contains 'disks' } -Times 0
    }

    It 'reports demo-day data disks as Standard SSD without a zone' {
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ zone = $null; profile = 'demo-day' }) -SkipWhatIf
        $zoneCheck = $results | Where-Object checkId -eq 'PREFLIGHT.P3.ZONE'
        $zoneCheck.evidence.t1DataDisk | Should -Be 'E10'
        $zoneCheck.evidence.t2HostDataDisk | Should -Be 'E10'
    }

    It 'reports that lowest-cost has no separate data disks' {
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ zone = $null; profile = 'lowest-cost' }) -SkipWhatIf
        $zoneCheck = $results | Where-Object checkId -eq 'PREFLIGHT.P3.ZONE'
        $zoneCheck.evidence.t1DataDisk | Should -Be 'None'
        $zoneCheck.evidence.t2HostDataDisk | Should -Be 'None'
        $zoneCheck.message | Should -Match 'no separate data disks'
    }

    It 'fails Premium SSD v2 without a zone when dataDiskSku is PremiumV2' {
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ zone = $null; profile = 'demo-day'; dataDiskSku = 'PremiumV2' }) -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.PREMIUMV2').status | Should -Be 'Fail'
    }

    It 'skips the Premium SSD v2 check in a zone when dataDiskSku forces another tier' {
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ zone = '2'; profile = 'demo-day'; dataDiskSku = 'P10' }) -SkipWhatIf
        $check = $results | Where-Object checkId -eq 'PREFLIGHT.P3.PREMIUMV2'
        $check.status | Should -Be 'Not selected'
        $check.evidence.t1DataDisk | Should -Be 'P10'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList -contains 'disks' } -Times 0
    }

    It 'resolves securityType.t1 Auto to TrustedLaunch when the image supports it, and deploys with it' {
        Set-WhatIfCaptureMock -ExistingVmsJson '[]'
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig)
        $check = $results | Where-Object checkId -eq 'PREFLIGHT.P3.SECURITYTYPE_T1'
        $check.status | Should -Be 'Pass'
        $check.message | Should -Match 'Trusted Launch'
        $script:whatIfParameters.parameters.t1SecurityType.value | Should -Be 'TrustedLaunch'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'vm' -and $ArgumentList[1] -eq 'image' -and $ArgumentList -contains '--urn' -and
            $ArgumentList[[array]::IndexOf($ArgumentList, '--urn') + 1] -like 'MicrosoftSQLServer:sql2022-ws2022:standard-gen2:*' -and $ArgumentList -contains '--subscription'
        }
    }

    It 'falls back to Standard with a Warning when the image does not advertise Trusted Launch' {
        Set-ImageMock -Json $standardOnlyImage
        Set-WhatIfCaptureMock -ExistingVmsJson '[]'
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig)
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.SECURITYTYPE_T1').status | Should -Be 'Warning'
        $script:whatIfParameters.parameters.t1SecurityType.value | Should -Be 'Standard'
    }

    It 'fails an explicit TrustedLaunch when the size reports TrustedLaunchDisabled' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[0] -eq 'rest' -and ($ArgumentList -join ' ') -match 'Microsoft\.Compute/skus' } -MockWith {
            $skus = @($script:profileSizes | ForEach-Object { [ordered]@{ name = $_; resourceType = 'virtualMachines'; restrictions = @(); capabilities = @([ordered]@{ name = 'TrustedLaunchDisabled'; value = 'True' }) } })
            [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-SkuListJson -Sku $skus); StdErr = '' }
        }
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ securityType = @{ t1 = 'TrustedLaunch'; t2Host = 'Standard' } }) -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.SECURITYTYPE_T1').status | Should -Be 'Fail'
    }

    It 'does not read the image when securityType.t1 is Standard' {
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ securityType = @{ t1 = 'Standard'; t2Host = 'Standard' } }) -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.SECURITYTYPE_T1').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[1] -eq 'image' } -Times 0
    }

    It 'warns about a Trusted Launch T2 host' {
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ securityType = @{ t1 = 'Auto'; t2Host = 'TrustedLaunch' } }) -SkipWhatIf
        ($results | Where-Object checkId -eq 'PREFLIGHT.P3.SECURITYTYPE_T2HOST').status | Should -Be 'Warning'
    }

    It 'fails Azure Hybrid Benefit without the attestation and passes with it' {
        $unattested = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ hybridBenefit = @{ windows = $true; sql = $false; entitlementAttested = $false } }) -SkipWhatIf
        ($unattested | Where-Object checkId -eq 'PREFLIGHT.C6.HYBRIDBENEFIT').status | Should -Be 'Fail'
        $attested = Invoke-DemoPreflight -Config (Copy-TestConfig -Override @{ hybridBenefit = @{ windows = $true; sql = $true; entitlementAttested = $true } }) -SkipWhatIf
        ($attested | Where-Object checkId -eq 'PREFLIGHT.C6.HYBRIDBENEFIT').status | Should -Be 'Pass'
    }

    It 'gives what-if a throwaway, redacted admin password when a VM would be created' {
        Set-WhatIfCaptureMock -ExistingVmsJson '["sqlvm01"]'
        $results = Invoke-DemoPreflight -Config (Copy-TestConfig)
        ($results | Where-Object checkId -eq 'PREFLIGHT.POLICY.WHATIF').status | Should -Be 'Pass'
        $passwordArgument = @($script:whatIfArguments | Where-Object { $_ -like 'adminPassword=*' })
        $passwordArgument.Count | Should -Be 1
        $throwaway = $passwordArgument[0].Substring('adminPassword='.Length)
        $throwaway.Length | Should -BeGreaterOrEqual 16
        ($results | ConvertTo-Json -Depth 10) | Should -Not -Match ([regex]::Escape($throwaway))
        Protect-DemoText -Text $throwaway | Should -Not -Be $throwaway
        $script:whatIfParameters.parameters.existingVmNames.value | Should -Be @('sqlvm01')
        ($script:whatIfParameters | ConvertTo-Json -Depth 10) | Should -Not -Match ([regex]::Escape($throwaway))
    }

    It 'leaves out the admin password and osProfile when both VMs exist' {
        Set-WhatIfCaptureMock -ExistingVmsJson '["archost01","sqlvm01","jumpbox"]'
        Invoke-DemoPreflight -Config (Copy-TestConfig) | Out-Null
        ($script:whatIfArguments -join ' ') | Should -Not -Match 'adminPassword'
        @($script:whatIfParameters.parameters.existingVmNames.value | Sort-Object) | Should -Be @('archost01', 'sqlvm01')
    }
}

Describe 'Resolve-DemoT1SecurityType' {
    It 'treats a missing image as a Standard fallback for Auto' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ImageNotFound' } }
        $resolved = Resolve-DemoT1SecurityType -Config $config
        $resolved.SecurityType | Should -Be 'Standard'
        $resolved.Status | Should -Be 'Warning'
        $resolved.Message | Should -Match 'could not be read'
    }

    It 'requires a Generation 2 image' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"hyperVGeneration":"V1","features":[{"name":"SecurityType","value":"TrustedLaunchSupported"}]}'; StdErr = '' }
        }
        (Resolve-DemoT1SecurityType -Config $config).SecurityType | Should -Be 'Standard'
    }
}

Describe 'Test-DemoPermission' {
    It 'allows an action covered by a wildcard and not excluded' {
        Test-DemoPermission -Permission @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Write') }) -Action 'Microsoft.Resources/deployments/write' | Should -BeTrue
    }

    It 'denies an action excluded by notActions in the same assignment' {
        Test-DemoPermission -Permission @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Write') }) -Action 'Microsoft.Authorization/roleAssignments/write' | Should -BeFalse
    }

    It 'allows an action granted by any one of several assignments' {
        $permissions = @(
            @{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Write') }
            @{ actions = @('Microsoft.Authorization/roleAssignments/*'); notActions = @() }
        )
        Test-DemoPermission -Permission $permissions -Action 'Microsoft.Authorization/roleAssignments/write' | Should -BeTrue
    }

    It 'denies everything with no assignments' {
        Test-DemoPermission -Permission @() -Action 'Microsoft.Resources/deployments/write' | Should -BeFalse
    }
}

Describe 'Get-DemoDeploymentParameter' {
    It 'produces only parameters that infra/main.bicep declares' {
        $declared = Select-String -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../infra/main.bicep') -Pattern '^param (\w+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        $document = Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -BudgetStartDate '2026-10-01' -NetworkMode public
        foreach ($name in $document.parameters.Keys) {
            $declared | Should -Contain $name
        }
    }

    It 'contains no secrets' {
        $json = Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode public | ConvertTo-Json -Depth 10
        $json | Should -Not -Match '(?i)password|secret|token|key"'
    }

    It 'passes T4''s size, and its zone only for a server that doesn''t exist yet (Phase 24)' {
        $document = Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode public
        $document.parameters.t4SkuName.value | Should -Be 'Standard_B1ms' -Because 'the smallest Burstable size is the default'
        $document.parameters.t4AvailabilityZone.value | Should -Be ''
        $copy = @{}
        foreach ($key in $config.Keys) { $copy[$key] = $config[$key] }
        $copy['t4SkuName'] = 'Standard_B2s'
        $copy['t4AvailabilityZone'] = '2'
        $document = Get-DemoDeploymentParameter -Config $copy -T3UseFreeLimit $true -NetworkMode public
        $document.parameters.t4SkuName.value | Should -Be 'Standard_B2s'
        $document.parameters.t4AvailabilityZone.value | Should -Be '2'
        (Get-DemoDeploymentParameter -Config $copy -T3UseFreeLimit $true -NetworkMode public -T4Exists).parameters.t4AvailabilityZone.value | Should -Be '' -Because 'a server keeps the zone it was created in'
    }

    It 'passes the current type of each drifted disk, and only the demo''s disks (Phase 24)' {
        $document = Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode public
        $document.parameters.Contains('diskSkuOverrides') | Should -BeFalse -Because 'nothing drifted'
        $document = Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode public -DiskSkuOverride @{ 'sqlvm01-osdisk' = 'Standard_LRS'; 'archost01-data01' = 'StandardSSD_LRS' }
        $document.parameters.diskSkuOverrides.value['sqlvm01-osdisk'] | Should -Be 'Standard_LRS'
        $document.parameters.diskSkuOverrides.value['archost01-data01'] | Should -Be 'StandardSSD_LRS'
        { Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode public -DiskSkuOverride @{ 'other-osdisk' = 'Standard_LRS' } } | Should -Throw '*demo disk names*'
        { Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode public -DiskSkuOverride @{ 'sqlvm01-osdisk' = 'Standard LRS; drop' } } | Should -Throw '*managed disk types*'
    }

    It 'rounds the budget up to whole dollars' {
        $copy = @{}
        foreach ($key in $config.Keys) { $copy[$key] = $config[$key] }
        $copy['monthlyCeilingUsd'] = 249.5
        (Get-DemoDeploymentParameter -Config $copy -T3UseFreeLimit $true -NetworkMode public).parameters.monthlyCeilingUsd.value | Should -Be 250
    }

    It 'refuses networkMode auto without the resolved mode, because the template takes only public or private' {
        $config['networkMode'] | Should -Be 'auto'
        { Get-DemoDeploymentParameter -Config $config } | Should -Throw '*must be resolved*-NetworkMode public or private*'
    }

    It 'uses the resolved network mode: <_>' -ForEach @('public', 'private') {
        (Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode $_).parameters.networkMode.value | Should -Be $_
    }

    It 'keeps an explicit network mode from the configuration' {
        $copy = @{}
        foreach ($key in $config.Keys) { $copy[$key] = $config[$key] }
        $copy['networkMode'] = 'private'
        (Get-DemoDeploymentParameter -Config $copy -T3UseFreeLimit $true).parameters.networkMode.value | Should -Be 'private'
    }

    It 'passes the VM settings, the existing VMs, and Standard for an unresolved Auto security type' {
        $copy = @{}
        foreach ($key in $config.Keys) { $copy[$key] = $config[$key] }
        $copy['zone'] = '3'
        $copy['profile'] = 'demo-day'
        $parameters = (Get-DemoDeploymentParameter -Config $copy -T3UseFreeLimit $true -NetworkMode private -ExistingVmName 'archost01').parameters
        $parameters.zone.value | Should -Be '3'
        $parameters.profile.value | Should -Be 'demo-day'
        $parameters.existingVmNames.value | Should -Be @('archost01')
        $parameters.t1SecurityType.value | Should -Be 'Standard'
        $parameters.hostSecurityType.value | Should -Be 'Standard'
        $parameters.t2SqlInstallMode.value | Should -Be 'PaygWizard'
        $parameters.Contains('adminPassword') | Should -BeFalse
        $parameters.Contains('bootstrapBundleUrl') | Should -BeFalse
        (Get-DemoDeploymentParameter -Config $copy -T3UseFreeLimit $true -NetworkMode private -T1SecurityType 'TrustedLaunch').parameters.t1SecurityType.value | Should -Be 'TrustedLaunch'
        (Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode private).parameters.zone.value | Should -Be ''
    }

    It 'fails closed when Azure Hybrid Benefit is requested without the attestation' {
        $copy = @{}
        foreach ($key in $config.Keys) { $copy[$key] = $config[$key] }
        $copy['hybridBenefit'] = @{ windows = $false; sql = $true; entitlementAttested = $false }
        { Get-DemoDeploymentParameter -Config $copy -T3UseFreeLimit $true -NetworkMode public } | Should -Throw '*entitlementAttested*'
        $copy['hybridBenefit'] = @{ windows = $true; sql = $true; entitlementAttested = $true }
        $parameters = (Get-DemoDeploymentParameter -Config $copy -T3UseFreeLimit $true -NetworkMode public).parameters
        $parameters.windowsHybridBenefit.value | Should -BeTrue
        $parameters.sqlHybridBenefit.value | Should -BeTrue
        $parameters.hybridBenefitAttested.value | Should -BeTrue
    }

    It 'leaves the bootstrap out until the bundle is delivered, then passes its SHA-256 and chunk count' {
        $without = (Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode private).parameters
        $without.Contains('bootstrapBundleSha256') | Should -BeFalse
        $without.Contains('bootstrapChunkCount') | Should -BeFalse

        $sha = 'AB' * 32
        $document = Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode private -ExistingVmName 'sqlvm01', 'archost01' -BootstrapBundleSha256 $sha -BootstrapChunkCount 3
        $document.parameters.bootstrapBundleSha256.value | Should -Be $sha.ToLowerInvariant()
        $document.parameters.bootstrapChunkCount.value | Should -Be 3
        $declared = Select-String -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../infra/main.bicep') -Pattern '^param (\w+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        foreach ($name in $document.parameters.Keys) {
            $declared | Should -Contain $name
        }
    }

    It 'requires the chunk count with the bundle SHA-256, and the SHA-256 with the count' {
        { Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode private -BootstrapBundleSha256 ('a' * 64) } | Should -Throw '*BootstrapChunkCount is required*'
        { Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode private -BootstrapChunkCount 2 } | Should -Throw '*needs -BootstrapBundleSha256*'
        { Get-DemoDeploymentParameter -Config $config -T3UseFreeLimit $true -NetworkMode private -BootstrapBundleSha256 'abc' -BootstrapChunkCount 1 } | Should -Throw
    }
}
