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
        # P12 and P13 (2026-11-05) have their own tests (DbHubDemo.FabricAppSignIn.Tests.ps1); here it sends nothing.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricAppTenantSetting -MockWith {
            New-DemoResult -CheckId 'PREFLIGHT.FABRIC.APPSETTINGS' -Area 'preflight' -Target 'tenant' -Status $script:appSettingsStatus -Message 'The tenant settings the Insights app needs.'
        }
        $script:appSettingsStatus = 'Pass'
        # The .NET SDK check (2026-11-09) has its own tests (DbHubDemo.DotNetSdk.Tests.ps1); here it runs no dotnet.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoDotNetSdk -MockWith {
            New-DemoResult -CheckId 'PREFLIGHT.TOOLS.DOTNETSDK' -Area 'preflight' -Target 'repo' -Status $script:dotnetSdkStatus -Message 'The .NET SDK that builds the workload runner.'
        }
        $script:dotnetSdkStatus = 'Pass'
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
        # No test here runs a real dotnet (DbHubDemo.DotNetSdk.Tests.ps1 tests the check).
        Mock -ModuleName DbHubDemo -CommandName Test-DemoDotNetSdk -MockWith {
            New-DemoResult -CheckId 'PREFLIGHT.TOOLS.DOTNETSDK' -Area 'preflight' -Target 'repo' -Status $script:dotnetSdkStatus -Message 'The .NET SDK that builds the workload runner.'
        }
        $script:dotnetSdkStatus = 'Pass'
    }

    It 'checks the .NET SDK that builds the workload runner right after the guard, and a Fail there fails preflight before anything is created (2026-11-09 live finding)' {
        Set-HappyAzMock
        $script:dotnetSdkStatus = 'Fail'
        $results = @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory)
        $ids = @($results | ForEach-Object { [string]$_.checkId })
        $ids[0] | Should -Be 'PREFLIGHT.GUARD.CONTEXT'
        $ids[1] | Should -Be 'PREFLIGHT.TOOLS.DOTNETSDK'
        ($results | Where-Object checkId -EQ 'PREFLIGHT.TOOLS.DOTNETSDK').status | Should -Be 'Fail'
        (Get-DemoExitCode -Result $results) | Should -Not -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoDotNetSdk -Times 1 -Exactly
    }

    It 'needs no .NET SDK with -SkipRunner: Not selected, and no dotnet runs' {
        Set-HappyAzMock
        $results = @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory -SkipRunner)
        $sdk = $results | Where-Object checkId -EQ 'PREFLIGHT.TOOLS.DOTNETSDK'
        $sdk.status | Should -Be 'Not selected'
        $sdk.message | Should -Match '-SkipRunner'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoDotNetSdk -Times 0 -Exactly
    }

    It 'checks nothing when the guard fails, the .NET SDK included' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { throw 'wrong tenant' }
        $results = @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory)
        @($results.checkId) | Should -Be @('PREFLIGHT.GUARD.CONTEXT')
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoDotNetSdk -Times 0 -Exactly
    }

    It 'says once that a configuration without activityProfile uses the new default, business-day, before the cost checks that count it (2026-11-03)' {
        Set-HappyAzMock
        $unset = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $unset[$key] = $config[$key] }
        $unset.Remove('activityProfile')
        $results = @(Invoke-DemoPreflight -Config $unset -SkipWhatIf -SkipPolicyInventory)
        $notice = @($results | Where-Object checkId -EQ 'PREFLIGHT.ACTIVITYPROFILE')
        $notice.Count | Should -Be 1
        $notice[0].status | Should -Be 'Pass'
        $notice[0].message | Should -Match '^activityProfile isn''t set, so this run uses the new default, business-day \(incidents every hour\); set it to baseline for the quieter demo\.'
        [array]::IndexOf(@($results | ForEach-Object { [string]$_.checkId }), 'PREFLIGHT.ACTIVITYPROFILE') | Should -BeLessThan ([array]::IndexOf(@($results | ForEach-Object { [string]$_.checkId }), 'PREFLIGHT.COST.SESSION'))
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'activityProfile isn''t set*' } -Times 1 -Exactly
        $unset.Contains('activityProfile') | Should -BeFalse -Because 'preflight never writes the configuration'

        # A configuration that names its profile gets no notice.
        @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -EQ 'PREFLIGHT.ACTIVITYPROFILE').Count | Should -Be 0
    }

    It 'checks the Insights app''s tenant settings (P12, P13) after P11, and a Warning there never stops preflight (2026-11-05)' {
        Set-HappyAzMock
        $script:appSettingsStatus = 'Warning'
        $results = @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory)
        $ids = @($results | ForEach-Object { [string]$_.checkId })
        $ids | Should -Contain 'PREFLIGHT.FABRIC.APPSETTINGS'
        [array]::IndexOf($ids, 'PREFLIGHT.FABRIC.APPSETTINGS') | Should -BeGreaterThan ([array]::IndexOf($ids, 'PREFLIGHT.FABRIC.VIEWERLICENSE'))
        @($results | Where-Object { $_.status -eq 'Fail' }).Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricAppTenantSetting -Times 1 -Exactly
    }

    It 'passes JumpstartImage, the default, on the nested host, and fails it with the evaluation-only Azure VM (2026-11-05)' {
        Set-HappyAzMock
        $check = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T2.MODE'
        $check.status | Should -Be 'Pass'
        $check.message | Should -Match 'no T2 step needs a person'

        $evaluation = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $evaluation[$key] = $config[$key] }
        $evaluation['t2Mode'] = 'EvaluationOnlyAzureVm'
        $evaluation['t2SqlInstallMode'] | Should -Be 'JumpstartImage'
        $check = Invoke-DemoPreflight -Config $evaluation -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T2.MODE'
        $check.status | Should -Be 'Fail'
        $check.remediation | Should -Match 't2Mode Nested'
        $evaluation['t2SqlInstallMode'] = 'Developer'
        (Invoke-DemoPreflight -Config $evaluation -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T2.MODE').status | Should -Be 'Warning'
    }

    It 'fails T4 on a size Azure refused for the same zone, warns for one more try in another zone, and says nothing without a refusal (Phase 24)' {
        Set-HappyAzMock
        # Live, 2026-10-26: the capability list included Standard_B1ms, and Azure still refused it with SkuNotAvailable;
        # the code is in the server's deployment operation, not in the deployment's own error.
        $refused = { param([string] $Sku, [string] $Zone) ConvertTo-Json -Depth 20 -InputObject @{ name = 'pgflex01'; properties = @{ provisioningState = 'Failed'; timestamp = '2026-10-26T14:11:42Z'; parameters = @{ sizing = @{ value = @{ skuName = $Sku; tier = $(if ($Sku -like 'Standard_B*') { 'Burstable' } else { 'GeneralPurpose' }) } }; availabilityZone = @{ value = $Zone } }; error = @{ code = 'DeploymentFailed'; details = @(@{ code = 'ResourceDeploymentFailure'; details = $null }) } } } }
        $script:pgOperationsJson = ConvertTo-Json -Depth 20 -InputObject @(@{ properties = @{ provisioningState = 'Failed'; targetResource = @{ resourceType = 'Microsoft.DBforPostgreSQL/flexibleServers' }; statusMessage = @{ status = 'Failed'; error = @{ code = 'SkuNotAvailable'; message = 'Specified SKU is not supported in this region. Please choose a different SKU.' } } } })
        $script:pgDeploymentJson = & $refused 'Standard_D4ds_v5' ''
        # Phase 28: the default size falls back on its own, so a refusal on record starts the run one size on (a Warning).
        $check = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU'
        $check.status | Should -Be 'Warning'
        $check.message | Should -Match 'starts with Standard_D4ads_v5, General Purpose with 4 vCores too'
        $check.evidence.startSku | Should -Be 'Standard_D4ads_v5'

        # A size the configuration sets never changes on its own: that refusal is still a Fail.
        $pinned = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $pinned[$key] = $config[$key] }
        $pinned['t4SkuName'] = 'Standard_D4ds_v5'
        $check = Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU'
        $check.status | Should -Be 'Fail'
        $check.remediation | Should -Match 'Set t4SkuName to Standard_D4ads_v5 \(General Purpose, 4 vCores on AMD processors'

        $zoned = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $zoned[$key] = $config[$key] }
        $zoned['t4AvailabilityZone'] = '2'
        $check = Invoke-DemoPreflight -Config $zoned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU'
        $check.status | Should -Be 'Warning'
        $check.message | Should -Match 'once more in zone 2'

        $zoned['t4SkuName'] = 'Standard_D4ads_v5'
        @(Invoke-DemoPreflight -Config $zoned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU').Count | Should -Be 0 -Because 'the refusal was for another size'

        # A refusal of the fallback's 4-vCore size: the remediation names the default and the 2-vCore size.
        $script:pgDeploymentJson = & $refused 'Standard_D4ads_v5' ''
        $check = Invoke-DemoPreflight -Config $zoned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU'
        $check.status | Should -Be 'Warning' -Because 'this configuration pins zone 2, and the refusal had no zone'
        $check.remediation | Should -Match 'Set t4SkuName to Standard_D4ds_v5 \(or remove it'
        $check.remediation | Should -Match 'Region access request'
        $check.remediation | Should -Match 'Standard_D2ds_v5 \(2 vCores; autonomous tuning turns off'
        $check.remediation | Should -Not -Match 'Set t4SkuName to Standard_D4ads_v5'

        $script:pgDeploymentJson = '{"name":"pgflex01","properties":{"provisioningState":"Succeeded"}}'
        @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU').Count | Should -Be 0
    }

    It 'checks that the region offers T4''s size and PostgreSQL version, from the Location Based Capabilities API (Phase 24)' {
        Set-HappyAzMock
        $capabilities = { param([string[]] $Versions) ConvertTo-Json -Depth 10 -InputObject @{ value = @(@{ supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_B1ms' }, @{ name = 'Standard_B2s' }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @(@{ name = 'Standard_D4ds_v5' }, @{ name = 'Standard_D4ads_v5' }, @{ name = 'Standard_D2ds_v5' }) }); supportedServerVersions = @($Versions | ForEach-Object { @{ name = $_ } }) }) } }
        $script:pgCapabilitiesJson = & $capabilities @('17', '18')
        $check = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Pass'
        $check.message | Should -Match 'GeneralPurpose Standard_D4ds_v5 and PostgreSQL 18'
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

    It 'reads T4''s sizes with az postgres flexible-server list-skus first, and starts the fallback early when the default isn''t listed (Phase 28; 2026-11-04)' {
        Set-HappyAzMock
        $script:listSkus = { param([string[]] $GeneralPurpose) ConvertTo-Json -Depth 10 -InputObject @(@{ name = 'FlexibleServerCapabilities'; supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_B1ms' }, @{ name = 'Standard_B2s' }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @($GeneralPurpose | ForEach-Object { @{ name = $_ } }) }); supportedServerVersions = @(@{ name = '17' }, @{ name = '18' }) }) }
        $script:listSkusJson = & $script:listSkus @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -match '^postgres flexible-server list-skus' } -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:listSkusJson; StdErr = '' } }
        $check = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Pass'
        $check.evidence.source | Should -Be 'az postgres flexible-server list-skus'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match 'locations/westus3/capabilities' }

        $script:listSkusJson = & $script:listSkus @('Standard_D4ads_v5', 'Standard_D2ds_v5')
        $check = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Warning'
        $check.evidence.startSku | Should -Be 'Standard_D4ads_v5'
        $check.message | Should -Match 'starts with Standard_D4ads_v5'

        $script:listSkusJson = & $script:listSkus @('Standard_D2ds_v5')
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory
        $check = $results | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Warning'
        # Neither 4-vCore size listed, so the 2-vCore fallback is next, after its cost check, with autonomous tuning off.
        $check.evidence.startSku | Should -Be 'Standard_D2ds_v5'
        $check.message | Should -Match '2-vCore fallback, Standard_D2ds_v5, with autonomous tuning off, once its cost check passes'
        $tuning = $results | Where-Object checkId -eq 'PREFLIGHT.T4.TUNING'
        $tuning.status | Should -Be 'Warning'
        $tuning.message | Should -Match 'Standard_D2ds_v5 \(General Purpose, 2 vCores\).*deploy\.ps1''s fallback uses Standard_D2ds_v5'
        # With t4AutonomousTuning true, that's a Fail: the fallback stops after the 4-vCore sizes.
        $strict = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $strict[$key] = $config[$key] }
        $strict['t4AutonomousTuning'] = $true
        $tuning = Invoke-DemoPreflight -Config $strict -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.TUNING'
        $tuning.status | Should -Be 'Fail'
        $tuning.remediation | Should -Match 'set t4AutonomousTuning to false'

        # None of the fallback's sizes listed: no T4, and DONE says why.
        $script:listSkusJson = & $script:listSkus @('Standard_D8ds_v5')
        $check = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Warning'
        $check.evidence.startSku | Should -Be 'None'
        $check.remediation | Should -Match 't4Enabled to false'

        # A size the configuration sets that the region doesn't list is a Fail before anything is created.
        $pinned = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $pinned[$key] = $config[$key] }
        $pinned['t4SkuName'] = 'Standard_D4ds_v5'
        $script:listSkusJson = & $script:listSkus @('Standard_D4ads_v5')
        (Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY').status | Should -Be 'Fail'
    }

    It 'says once that an existing T4 that no record keeps moves to the default, prices it at the default, and checks the region offers it (2026-11-04)' {
        Set-HappyAzMock
        $script:listSkus = { param([string[]] $GeneralPurpose) ConvertTo-Json -Depth 10 -InputObject @(@{ name = 'FlexibleServerCapabilities'; supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_B1ms' }, @{ name = 'Standard_B2s' }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @($GeneralPurpose | ForEach-Object { @{ name = $_ } }) }); supportedServerVersions = @(@{ name = '18' }) }) }
        $script:listSkusJson = & $script:listSkus @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -match '^postgres flexible-server list-skus' } -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:listSkusJson; StdErr = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = $true; State = 'Ready'; Server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_B1ms'; tier = 'Burstable' } } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith { [pscustomobject]@{ LightUseMonthly = 10.0; SessionCost = 1.0; T4AutoRestartWorstCaseMonthly = 1.0; T4FixedMonthly = 1.0; DefenderIncluded = $true; MissingPrices = @(); Components = @(); Results = @() } }
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory
        $size = $results | Where-Object checkId -eq 'PREFLIGHT.T4.SIZE'
        $size.status | Should -Be 'Warning'
        $size.message | Should -Match 'T4 exists as Standard_B1ms \(Burstable\), and your configuration doesn''t set t4SkuName, so deploy\.ps1 scales it to the default'
        $size.remediation | Should -Match 'set t4SkuName to Standard_B1ms'
        $capability = $results | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $capability.status | Should -Be 'Pass'
        $capability.message | Should -Match 'offers the default it moves to, GeneralPurpose Standard_D4ds_v5'
        ($results | Where-Object checkId -eq 'PREFLIGHT.T4.TUNING').status | Should -Be 'Pass'
        # Priced at the default it moves to, not the server's own size.
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -ParameterFilter { -not $Config.Contains('t4SkuSource') -and -not $Config.Contains('t4SkuName') }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 0 -Exactly -ParameterFilter { [string]$Config['t4SkuName'] -eq 'Standard_B1ms' }

        # A configuration that sets its size gets no notice: that size is what it keeps.
        $pinned = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $pinned[$key] = $config[$key] }
        $pinned['t4SkuName'] = 'Standard_B1ms'
        $results = Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory
        @($results | Where-Object checkId -eq 'PREFLIGHT.T4.SIZE').Count | Should -Be 0
        ($results | Where-Object checkId -eq 'PREFLIGHT.T4.TUNING').status | Should -Be 'Warning'
        ($results | Where-Object checkId -eq 'PREFLIGHT.T4.TUNING').message | Should -Match 't4SkuName sets Standard_B1ms\.$'
    }

    It 'prices T4''s General Purpose fallback before anything is created, with its full-month worst case against both ceilings (Phase 28 follow-up)' {
        Set-HappyAzMock
        # Its numbers are set against a 250 USD ceiling, kept here (the default is 375 since 2026-11-04).
        $copy = [ordered]@{}
        foreach ($key in $config.Keys) { $copy[$key] = $config[$key] }
        $copy['monthlyCeilingUsd'] = 250
        $config = $copy
        # Fake estimates in Get-DemoCostEstimate's shape, with T4's compute at the size priced; obviously fake prices.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith {
            $sku = if ($Config['t4Enabled'] -eq $false) { '' } elseif ($Config['t4SkuName']) { [string]$Config['t4SkuName'] } else { 'Standard_D4ds_v5' }
            $vcores = if ($sku -eq 'Standard_D2ds_v5') { 2 } elseif ($sku -like 'Standard_D4*') { 4 } else { 1 }
            $unit = if ($sku -eq 'Standard_D2ds_v5') { 0.1 } else { 0.01 }
            [pscustomobject]@{
                LightUseMonthly               = $script:lightUse
                SessionCost                   = 9.0
                T4AutoRestartWorstCaseMonthly = $(if ($sku) { [System.Math]::Round($unit * $vcores * 690, 2) } else { $null })
                T4FixedMonthly                = $(if ($sku) { 20.0 } else { $null })
                DefenderIncluded              = $true
                MissingPrices                 = @()
                Components                    = @(if ($sku) { [pscustomobject]@{ Name = ('T4 compute ({0})' -f $sku); UnitPrice = $unit; Quantity = $vcores } })
                Results                       = @(New-DemoResult -CheckId 'PREFLIGHT.COST.MONTHLY' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message ('Priced with T4 at {0}.' -f $(if ($sku) { $sku } else { 'nothing' })))
            }
        }
        $script:listSkus = { param([string[]] $GeneralPurpose) ConvertTo-Json -Depth 10 -InputObject @(@{ name = 'FlexibleServerCapabilities'; supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_B1ms' }, @{ name = 'Standard_B2s' }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @($GeneralPurpose | ForEach-Object { @{ name = $_ } }) }); supportedServerVersions = @(@{ name = '18' }) }) }
        $script:listSkusJson = & $script:listSkus @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -match '^postgres flexible-server list-skus' } -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:listSkusJson; StdErr = '' } }

        # A 4-vCore start: the 2-vCore step is priced ahead, since Azure can still refuse a listed size. Within
        # both ceilings: 60 + 0.2 x 690 = 198 USD for the month, 9 for a session.
        $script:lightUse = 60.0
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory
        # T4's restart (2026-11-04): the example configuration's nightly safety stop isn't set up (ADR 0024), and it has no
        # on-demand control, so the rest of the month counts.
        $restart = $results | Where-Object checkId -eq 'PREFLIGHT.COST.T4RESTART'
        $restart.status | Should -Be 'Warning'
        $restart.message | Should -Match 'the nightly safety stop isn''t in place yet'
        $restart.remediation | Should -Match '\./scripts/deploy\.ps1 sets it up after its template, so the checks after that run count about a day per restart \(a first deployment''s own preflight can''t: it runs before the template\)'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -ParameterFilter { $null -ne $T4RestartCoverage -and $T4RestartCoverage.Missing -eq 'SafetyStop' }
        $fallback = $results | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK'
        $fallback.status | Should -Be 'Pass'
        $fallback.evidence.startSku | Should -Be ''
        $fallback.evidence.hourlyUsd | Should -Be 0.2
        $fallback.evidence.monthlyWorstCaseUsd | Should -Be 198.0
        $fallback.message | Should -Match 'deploy\.ps1 creates T4 as General Purpose Standard_D2ds_v5, with autonomous tuning off \(it needs 4 vCores\): about 0\.200 USD an hour'
        ($results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Be 'Priced with T4 at Standard_D4ds_v5.'
        ($results | Where-Object checkId -eq 'PREFLIGHT.T4.TUNING').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $Config['t4SkuName'] -eq 'Standard_D2ds_v5' -and $null -ne $PriceCache }

        # Over monthlyCeilingUsd (150 + 138 = 288 USD): a Warning that T4 would be left out, and how to allow it.
        $script:lightUse = 150.0
        $fallback = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK'
        $fallback.status | Should -Be 'Warning'
        $fallback.evidence.skipReason | Should -Be 'MonthlyCeiling'
        $fallback.message | Should -Match 'would leave T4 out instead: its worst case, every hour of a month'
        $fallback.remediation | Should -Match '^Nothing to do unless Azure refuses both 4-vCore sizes\. To have the fallback create T4 then, raise monthlyCeilingUsd to at least 288'

        # The region lists neither 4-vCore size: the run starts at the 2-vCore size, so the run's own estimate prices it,
        # and over a ceiling T4 is left out (startSku None) and the ceilings are checked without it, not failed.
        $script:listSkusJson = & $script:listSkus @('Standard_D2ds_v5')
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory
        $fallback = $results | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK'
        $fallback.status | Should -Be 'Warning'
        $fallback.evidence.startSku | Should -Be 'None'
        $fallback.evidence.skipReason | Should -Be 'MonthlyCeiling'
        @($results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Be @('Priced with T4 at nothing.')
        (InModuleScope DbHubDemo -Parameters @{ Results = $results } { Select-DemoT4StartSku -Sku @($Results | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_.evidence -Name 'startSku') }) }) | Should -Be 'None'
        $script:lightUse = 60.0
        $fallback = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK'
        $fallback.status | Should -Be 'Warning' -Because 'a General Purpose T4 is said loudly'
        $fallback.evidence.startSku | Should -Be 'Standard_D2ds_v5'
        $fallback.message | Should -Match 'so this run creates T4 as General Purpose Standard_D2ds_v5'

        # A size the configuration sets has no fallback to price, and T4 turned off has nothing to price.
        $pinned = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $pinned[$key] = $config[$key] }
        $pinned['t4SkuName'] = 'Standard_B1ms'
        $script:listSkusJson = & $script:listSkus @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
        (Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK').status | Should -Be 'Not selected'
        $pinned.Remove('t4SkuName')
        $pinned['t4Enabled'] = $false
        @(Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK').Count | Should -Be 0
    }

    It 'keeps the run''s own cost checks, a monthly-ceiling Fail included, when the fallback''s extra estimate fails: <Case> (review of 20e855c)' -ForEach @(
        @{ Case = 'a 4-vCore start, the 2-vCore estimate refused (HTTP 429)'; GeneralPurpose = @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5'); Throws = 'fallback'; StartSku = ''; Status = 'Warning'; SkipReason = 'Price'; Match = 'deploy\.ps1 prices its 2-vCore fallback, Standard_D2ds_v5, right before it would create it; right now, its price couldn''t be read from the Azure Retail Prices API \(HTTP 429' }
        @{ Case = 'a 2-vCore start over a ceiling, the estimate without T4 refused (HTTP 429)'; GeneralPurpose = @('Standard_D2ds_v5'); Throws = 'off'; StartSku = 'None'; Status = 'Warning'; SkipReason = 'MonthlyCeiling'; Match = 'The ceilings without T4 couldn''t be checked \(HTTP 429.*\), so PREFLIGHT\.COST\.\* still price T4 at Standard_D2ds_v5' }
        @{ Case = 'the fallback''s check itself throws'; GeneralPurpose = @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5'); Throws = 'check'; StartSku = ''; Status = 'Warning'; SkipReason = 'Price'; Match = '^T4''s 2-vCore fallback couldn''t be priced in preflight: HTTP 429' }
    ) {
        Set-HappyAzMock
        # The run's own estimate is over monthlyCeilingUsd, a Fail; obviously fake prices.
        $script:throws = $Throws
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith {
            $sku = if ($Config['t4Enabled'] -eq $false) { '' } elseif ($Config['t4SkuName']) { [string]$Config['t4SkuName'] } else { 'Standard_D4ds_v5' }
            if (($script:throws -eq 'off' -and -not $sku) -or ($script:throws -eq 'fallback' -and $sku -eq 'Standard_D2ds_v5')) {
                throw 'HTTP 429: Too Many Requests (after 3 retries).'
            }
            $unit = if ($sku -eq 'Standard_D2ds_v5') { 0.1 } else { 0.01 }
            [pscustomobject]@{
                LightUseMonthly               = 260.0
                SessionCost                   = 9.0
                T4AutoRestartWorstCaseMonthly = $(if ($sku) { [System.Math]::Round($unit * 2 * 690, 2) } else { $null })
                T4FixedMonthly                = $(if ($sku) { 20.0 } else { $null })
                DefenderIncluded              = $true
                MissingPrices                 = @()
                Components                    = @(if ($sku) { [pscustomobject]@{ Name = ('T4 compute ({0})' -f $sku); UnitPrice = $unit; Quantity = 2 } })
                Results                       = @(New-DemoResult -CheckId 'PREFLIGHT.COST.MONTHLY' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message ('Over monthlyCeilingUsd with T4 at {0}.' -f $(if ($sku) { $sku } else { 'nothing' })))
            }
        }
        if ($Throws -eq 'check') {
            Mock -ModuleName DbHubDemo -CommandName Get-DemoT4FallbackPreflight -MockWith { throw 'HTTP 429: Too Many Requests (after 3 retries).' }
        }
        $script:listSkusJson = ConvertTo-Json -Depth 10 -InputObject @(@{ name = 'FlexibleServerCapabilities'; supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_B1ms' }, @{ name = 'Standard_B2s' }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @($GeneralPurpose | ForEach-Object { @{ name = $_ } }) }); supportedServerVersions = @(@{ name = '18' }) })
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -match '^postgres flexible-server list-skus' } -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:listSkusJson; StdErr = '' } }

        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory
        $monthly = @($results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY')
        $monthly.Count | Should -Be 1
        $monthly[0].status | Should -Be 'Fail' -Because 'a hard ceiling is never dropped, whatever the fallback''s estimate does'
        @($results | Where-Object { $_.status -eq 'Fail' }).Count | Should -BeGreaterOrEqual 1
        @($results | Where-Object { [string]$_.message -match 'could not be computed' }) | Should -BeNullOrEmpty
        $fallback = @($results | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK')
        $fallback.Count | Should -Be 1
        $fallback[0].status | Should -Be $Status
        [string]$fallback[0].evidence.startSku | Should -Be $StartSku
        $fallback[0].evidence.skipReason | Should -Be $SkipReason
        $fallback[0].message | Should -Match $Match
    }

    It 'leaves the policy inventory to deploy.ps1 only with networkMode private, and keeps it with public and auto (Phase 28; review finding 7)' {
        Set-HappyAzMock
        $private = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $private[$key] = $config[$key] }
        $private['networkMode'] = 'private'
        $results = Invoke-DemoPreflight -Config $private -SkipWhatIf -DeferPolicyInventory
        $inventory = $results | Where-Object checkId -eq 'PREFLIGHT.POLICY.INVENTORY'
        $inventory.status | Should -Be 'Not selected'
        $inventory.message | Should -Match 'Deferred'
        $inventory.evidence.deferred | Should -BeTrue
        $sqlPrivate = $results | Where-Object checkId -eq 'PREFLIGHT.POLICY.SQLPUBLIC'
        $sqlPrivate.status | Should -Be 'Not selected'
        $sqlPrivate.evidence.effectiveNetworkMode | Should -Be 'private'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match 'policyAssignments' }

        # networkMode public under a Modify policy that turns SQL public access off: the what-if catches only Deny, so
        # preflight's own SQL public-access check must stop the run before anything is created, as before Phase 28.
        $public = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $public[$key] = $config[$key] }
        $public['networkMode'] = 'public'
        $script:policyAssignmentsJson = $script:sqlPublicOffAssignmentsJson
        $publicResults = Invoke-DemoPreflight -Config $public -SkipWhatIf -DeferPolicyInventory
        ($publicResults | Where-Object checkId -eq 'PREFLIGHT.POLICY.INVENTORY').message | Should -Not -Match 'Deferred'
        ($publicResults | Where-Object checkId -eq 'PREFLIGHT.POLICY.SQLPUBLIC').status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -match 'policyAssignments' }

        # networkMode auto needs the inventory, so it isn't deferred either.
        $script:policyAssignmentsJson = '{"value":[]}'
        $auto = Invoke-DemoPreflight -Config $config -SkipWhatIf -DeferPolicyInventory
        ($auto | Where-Object checkId -eq 'PREFLIGHT.POLICY.INVENTORY').status | Should -Be 'Pass'
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
        # Twice, with the same parameters: the demo's estimate, and T4's General Purpose fallback's, which shares its price
        # cache (Phase 28 follow-up).
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 2 -Exactly -ParameterFilter {
            $NetworkMode -eq 'private' -and @($DefenderPlans).Count -eq 2 -and $DefenderPlans[0].name -eq 'VirtualMachines' -and $null -ne $PriceCache
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter { $Config['t4SkuName'] -eq 'Standard_D2ds_v5' -and $Config['t4SkuSource'] -eq 'fallback' }
    }

    It 'resolves networkMode auto to public when no policy turns public access off' {
        Set-HappyAzMock
        Invoke-DemoPreflight -Config $config | Out-Null
        $script:whatIfParameters.parameters.networkMode.value | Should -Be 'public'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 2 -Exactly -ParameterFilter { $NetworkMode -eq 'public' }
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
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 2 -Exactly -ParameterFilter { $null -eq $DefenderPlans }
    }

    It 'checks the T3 free offer and passes the result to the cost estimate' {
        Set-HappyAzMock
        $results = Invoke-DemoPreflight -Config $config
        $freeOffer = $results | Where-Object checkId -eq 'PREFLIGHT.T3.FREEOFFER'
        $freeOffer.status | Should -Be 'Pass'
        $freeOffer.evidence.useFreeLimit | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 2 -Exactly -ParameterFilter { $T3UseFreeLimit -eq $true }
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
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 2 -Exactly -ParameterFilter { $T3UseFreeLimit -eq $false }
        $script:whatIfParameters.parameters.t3UseFreeLimit.value | Should -BeFalse
    }

    It 'gives the what-if the budget''s own start date, read as text, as the deployment sends it (Phase 28 live finding, 2026-11-02)' {
        Set-HappyAzMock
        # az applies --query and --output itself: only the start date as the API wrote it, or else the whole budget as JSON.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -match '^rest --method get --url https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Consumption/budgets/budget-dbhub-demo\?' } -MockWith {
            if (-not $script:budgetStartText) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: Not Found({"error":{"code":"NotFound","message":"Budget budget-dbhub-demo was not found."}})' }
            }
            $text = if ($ArgumentList -contains '--query') { $script:budgetStartText } else { '{"name":"budget-dbhub-demo","properties":{"timeGrain":"Monthly","timePeriod":{"startDate":"' + $script:budgetStartText + '"}}}' }
            [pscustomobject]@{ ExitCode = 0; StdOut = $text; StdErr = '' }
        }
        $script:budgetStartText = '2026-10-01T00:00:00Z'
        Invoke-DemoPreflight -Config $config -SkipPolicyInventory | Out-Null
        $script:whatIfParameters.parameters.budgetStartDate.value | Should -Be '2026-10-01'

        # Without a budget, the template's default applies, as for a new deployment.
        $script:budgetStartText = ''
        Invoke-DemoPreflight -Config $config -SkipPolicyInventory | Out-Null
        $script:whatIfParameters.parameters.Contains('budgetStartDate') | Should -BeFalse
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
        $document.parameters.t4SkuName.value | Should -Be 'Standard_D4ds_v5' -Because 'General Purpose with 4 vCores is the default since 2026-11-04'
        $document.parameters.t4AutonomousTuning.value | Should -BeTrue
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
        $parameters.t2SqlInstallMode.value | Should -Be 'JumpstartImage'
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
