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
        # The P11 check has its own tests (DbHubDemo.FabricItem.Tests.ps1); here it only has to be called. Since 2026-11-14
        # the viewers' licenses are assumed, so it's Not selected.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricViewerLicense -MockWith {
            New-DemoResult -CheckId 'PREFLIGHT.FABRIC.VIEWERLICENSE' -Area 'preflight' -Target 'fabric' -Status 'Not selected' -Message 'Power BI viewer licenses are assumed.'
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

    It 'fails right after P5 when another demo environment records the workspace P5 found, and adds nothing when nobody else does (DEPLOY.FABRIC.SHARED, 2026-11-19)' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricResolution -MockWith {
            [pscustomobject]@{ Result = (New-DemoResult -CheckId 'PREFLIGHT.P5.WORKSPACE' -Area 'preflight' -Target 'fabric' -Status 'Pass' -Message 'The workspace is ready.' -Evidence ([ordered]@{ workspaceName = 'Database Hub Demo'; workspaceId = 'dddddddd-0000-0000-0000-000000000001' })); Config = $Config; CapacityResult = $null }
        }
        $script:recorders = @([pscustomobject]@{ Name = 'rg-dbhubother-demo'; SubscriptionId = '11111111-2222-3333-4444-555555555555'; Label = 'rg-dbhubother-demo'; Tagged = $true; Claims = @('dddddddd-0000-0000-0000-000000000001') })
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricWorkspaceClaim -MockWith { [pscustomobject]@{ Ok = $true; Error = ''; Others = $script:recorders; Own = [pscustomobject]@{ Found = $false; FabricWorkspaceId = ''; Claims = @(); UsedFabric = $false } } }
        $results = @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory)
        $ids = @($results | ForEach-Object { [string]$_.checkId })
        $shared = @($results | Where-Object checkId -EQ 'DEPLOY.FABRIC.SHARED')
        $shared.Count | Should -Be 1
        $shared[0].status | Should -Be 'Fail' -Because 'a Fail in preflight stops deploy.ps1 before anything is created'
        $shared[0].message | Should -Match 'is the one rg-dbhubother-demo records as its own, not this environment''s \(rg-dbhub-demo\)'
        [array]::IndexOf($ids, 'DEPLOY.FABRIC.SHARED') | Should -Be ([array]::IndexOf($ids, 'PREFLIGHT.P5.WORKSPACE') + 1)
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricWorkspaceClaim -Times 1 -Exactly -ParameterFilter { $Config['prefix'] -eq 'dbhub' }

        $script:recorders = @()
        $results = @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory)
        @($results | Where-Object checkId -EQ 'DEPLOY.FABRIC.SHARED').Count | Should -Be 0
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
        $check.remediation | Should -Match '^Set t2SqlInstallMode to ProductKey \(.*\) or Developer \(.*\); both install unattended on the evaluation-only Azure VM'
        $check.remediation | Should -Match 't2Mode Nested'
        $check.remediation | Should -Not -Match 'PaygWizard'
        # An older configuration's PaygWizard (its default before 2026-11-05) runs as JumpstartImage, which this VM can't run:
        # the fix names only the unattended modes, never the retired one (review of 849d4c2, 2026-11-09).
        $evaluation['t2SqlInstallModeSource'] = 'legacy'
        $legacy = Invoke-DemoPreflight -Config $evaluation -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T2.MODE'
        $legacy.status | Should -Be 'Fail'
        $legacy.message | Should -Match '^t2SqlInstallMode PaygWizard in your configuration is retired: the one-click deployment has no SQL Server setup wizard'
        $legacy.remediation | Should -Match '^Set t2SqlInstallMode to ProductKey \(.*\) or Developer \(.*\); both install unattended'
        $legacy.remediation | Should -Not -Match 'PaygWizard|t2Mode Nested'
        $evaluation.Remove('t2SqlInstallModeSource')
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

        # A size the configuration sets falls back too since 2026-11-09 (user-directed): deploy.ps1 tries it again, since
        # Azure's regional capacity changes, and then the next size Azure accepts, cheapest first. A Warning, never a Fail,
        # and no fix that asks for another size.
        $pinned = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $pinned[$key] = $config[$key] }
        $pinned['t4SkuName'] = 'Standard_D4ds_v5'
        $check = Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.SKU'
        $check.status | Should -Be 'Warning'
        $check.message | Should -Match 'so deploy\.ps1 tries it again, since Azure''s regional capacity changes, once more in another zone the region lists, and then the next size Azure accepts, cheapest first \(Standard_D4ads_v5, Standard_D2ds_v5, Standard_B2s, Standard_B1ms\)\.'
        $check.evidence.startSku | Should -Be ''
        $check.evidence.pinnedSku | Should -Be 'Standard_D4ds_v5'
        $check.remediation | Should -Not -Match 'Set t4SkuName'

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
        $check.message | Should -Match 'tries Standard_D4ads_v5 once more in zone 2, as t4AvailabilityZone says; if Azure refuses it again, deploy\.ps1''s fallback moves on to its next size by itself'
        $check.remediation | Should -Match '^Nothing to do'
        $check.remediation | Should -Not -Match 't4SkuName' -Because 'the fallback chooses the size, so no fix asks for one (2026-11-09)'

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
        # A Burstable size listed under another edition isn't offered as Burstable; since 2026-11-09 the fallback for a size
        # t4SkuName sets starts at the next size the region lists, here Standard_B1ms, a Warning.
        $check = Invoke-DemoPreflight -Config $gp -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Warning'
        $check.evidence.startSku | Should -Be 'Standard_B1ms'

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
        # Neither 4-vCore size listed, so the 2-vCore fallback is next, with autonomous tuning off; its cost check only
        # reports (PREFLIGHT.T4.FALLBACK): it never leaves T4 out (2026-11-09).
        $check.evidence.startSku | Should -Be 'Standard_D2ds_v5'
        $check.message | Should -Match '2-vCore fallback, Standard_D2ds_v5, with autonomous tuning off \(PREFLIGHT\.T4\.FALLBACK gives its price\)'
        $check.remediation | Should -Not -Match 't4Enabled'
        $tuning = $results | Where-Object checkId -eq 'PREFLIGHT.T4.TUNING'
        $tuning.status | Should -Be 'Warning'
        $tuning.message | Should -Match 'Standard_D2ds_v5 \(General Purpose, 2 vCores\).*deploy\.ps1''s fallback uses Standard_D2ds_v5'
        # With t4AutonomousTuning true, that's a Warning too: tuning never leaves T4 out, so the fallback goes on to the
        # 2-vCore size (2026-11-09). Only a t4SkuName the file sets to a size that can't run it is a Fail.
        $strict = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $strict[$key] = $config[$key] }
        $strict['t4AutonomousTuning'] = $true
        $tuning = Invoke-DemoPreflight -Config $strict -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.TUNING'
        $tuning.status | Should -Be 'Warning'
        $tuning.message | Should -Match 'T4 is part of every deployment, so it''s created with autonomous tuning off'
        $tuning.remediation | Should -Match 'Region access request'
        $strict['t4SkuName'] = 'Standard_D2ds_v5'
        $tuning = Invoke-DemoPreflight -Config $strict -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.TUNING'
        $tuning.status | Should -Be 'Fail'
        $tuning.remediation | Should -Match 'set t4AutonomousTuning to false'

        # None of the fallback's sizes listed: T4 is part of every deployment, so deploy.ps1 tries them all anyway, from the
        # default (the list can lag), and only Azure's refusal of every size ends the run NOT DONE (2026-11-09).
        $script:listSkusJson = & $script:listSkus @('Standard_D8ds_v5')
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory
        $check = $results | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Warning'
        $check.evidence.startSku | Should -Be ''
        $check.message | Should -Match 'T4 is part of every deployment, so deploy\.ps1 tries them anyway, and if Azure refuses them all, the run ends NOT DONE with the fix'
        $check.remediation | Should -Match 'Region access request'
        $check.remediation | Should -Not -Match 't4Enabled'
        (InModuleScope DbHubDemo -Parameters @{ Results = $results } { Select-DemoT4StartSku -Sku @($Results | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_.evidence -Name 'startSku') }) }) | Should -Be '' -Because 'deploy.ps1 starts from the default size'

        # A size the configuration sets that the region doesn't list: since 2026-11-09 (user-directed) deploy.ps1 starts at
        # the next size the region lists in its fallback order, a 4-vCore size's peer first, with a Warning, never a Fail.
        $pinned = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $pinned[$key] = $config[$key] }
        $pinned['t4SkuName'] = 'Standard_D4ds_v5'
        $script:listSkusJson = & $script:listSkus @('Standard_D4ads_v5')
        $results = Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory
        $check = $results | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Warning'
        $check.evidence.startSku | Should -Be 'Standard_D4ads_v5'
        $check.message | Should -Match 'doesn''t list Standard_D4ds_v5, the size t4SkuName sets, so deploy\.ps1 creates T4 as Standard_D4ads_v5, the next size the region lists in the fallback''s order, cheapest first; a Warning then names the size and both monthly estimates'
        (InModuleScope DbHubDemo -Parameters @{ Results = $results; Config = $pinned } { Select-DemoT4StartSku -Sku @($Results | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_.evidence -Name 'startSku') }) -Order ([string[]]@(@('') + @(Get-DemoT4FallbackOrder -Config $Config))) }) | Should -Be 'Standard_D4ads_v5'
        $fallback = $results | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK'
        $fallback.status | Should -Be 'Pass'
        $fallback.message | Should -Match '^t4SkuName sets Standard_D4ds_v5 \(deploy\.ps1 starts at Standard_D4ads_v5: PREFLIGHT\.T4\.CAPABILITY or PREFLIGHT\.T4\.SKU says why\)\. If Azure refuses it when it creates T4 \(SkuNotAvailable\), deploy\.ps1 tries it once more in another zone the region lists, then the next size Azure accepts, cheapest first: Standard_D4ads_v5, Standard_D2ds_v5, Standard_B2s, Standard_B1ms\.'
        @($fallback.evidence.order) | Should -Be @('Standard_D4ads_v5', 'Standard_D2ds_v5', 'Standard_B2s', 'Standard_B1ms')

        # Standard_B1ms, the size the tester's configuration set (2026-11-09), in a region that lists only General Purpose
        # sizes: the fallback starts at the cheapest of them, Standard_D2ds_v5.
        $pinned['t4SkuName'] = 'Standard_B1ms'
        $script:listSkusJson = ConvertTo-Json -Depth 10 -InputObject @(@{ name = 'FlexibleServerCapabilities'; supportedServerEditions = @(@{ name = 'GeneralPurpose'; supportedServerSkus = @(@{ name = 'Standard_D4ds_v5' }, @{ name = 'Standard_D4ads_v5' }, @{ name = 'Standard_D2ds_v5' }) }); supportedServerVersions = @(@{ name = '18' }) })
        $check = Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $check.status | Should -Be 'Warning'
        $check.evidence.startSku | Should -Be 'Standard_D2ds_v5'
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

    It 'says an existing T4 moves to the size t4SkuName sets, and prices that size (#24)' {
        Set-HappyAzMock
        $script:listSkusJson = ConvertTo-Json -Depth 10 -InputObject @(@{ name = 'FlexibleServerCapabilities'; supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_B1ms' }, @{ name = 'Standard_B2s' }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @(@{ name = 'Standard_D4ds_v5' }, @{ name = 'Standard_D4ads_v5' }, @{ name = 'Standard_D2ds_v5' }) }); supportedServerVersions = @(@{ name = '18' }) })
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -match '^postgres flexible-server list-skus' } -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:listSkusJson; StdErr = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = $true; State = 'Ready'; Server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D4ds_v5'; tier = 'GeneralPurpose' } } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith { [pscustomobject]@{ LightUseMonthly = 10.0; SessionCost = 1.0; T4AutoRestartWorstCaseMonthly = 1.0; T4FixedMonthly = 1.0; DefenderIncluded = $true; MissingPrices = @(); Components = @(); Results = @() } }
        $pinned = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $pinned[$key] = $config[$key] }
        $pinned['t4SkuName'] = 'Standard_D2ds_v5'
        $results = Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory
        $size = @($results | Where-Object checkId -eq 'PREFLIGHT.T4.SIZE')
        $size.Count | Should -Be 1
        $size[0].status | Should -Be 'Warning'
        $size[0].message | Should -Match '^T4 exists as Standard_D4ds_v5 \(General Purpose\), and your configuration sets t4SkuName to Standard_D2ds_v5, so deploy\.ps1 scales it, which restarts it'
        $size[0].evidence.explicit | Should -BeTrue
        $size[0].remediation | Should -Match 'set t4SkuName back to Standard_D4ds_v5'
        ($results | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY').message | Should -Match 'offers the size t4SkuName sets it moves to, GeneralPurpose Standard_D2ds_v5'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -ParameterFilter { [string]$Config['t4SkuName'] -eq 'Standard_D2ds_v5' }
    }

    It 'reads the size a refused scale kept from the resource group, so it neither announces that scale nor prices the default (#24)' {
        # preflight.ps1 and validate.ps1 hand preflight the file's configuration; deploy.ps1 resolves the record first.
        Set-HappyAzMock
        $script:listSkusJson = ConvertTo-Json -Depth 10 -InputObject @(@{ name = 'FlexibleServerCapabilities'; supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_B1ms' }, @{ name = 'Standard_B2s' }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @(@{ name = 'Standard_D4ds_v5' }, @{ name = 'Standard_D4ads_v5' }, @{ name = 'Standard_D2ds_v5' }) }); supportedServerVersions = @(@{ name = '18' }) })
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -match '^postgres flexible-server list-skus' } -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:listSkusJson; StdErr = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = $true; State = 'Ready'; Server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ Exists = $true; T4Sku = 'Standard_D2ds_v5'; T4Refused = 'Standard_D4ds_v5@any;kept;2026-11-04T10:00:00Z'; Tags = @{ deploymentId = 'abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith { [pscustomobject]@{ LightUseMonthly = 10.0; SessionCost = 1.0; T4AutoRestartWorstCaseMonthly = 1.0; T4FixedMonthly = 1.0; DefenderIncluded = $true; MissingPrices = @(); Components = @(); Results = @() } }
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory
        @($results | Where-Object checkId -eq 'PREFLIGHT.T4.SIZE').Count | Should -Be 0
        ($results | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY').message | Should -Match '^T4 exists as GeneralPurpose Standard_D2ds_v5, and deploy\.ps1 keeps its size'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -ParameterFilter { [string]$Config['t4SkuName'] -eq 'Standard_D2ds_v5' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 0 -Exactly -ParameterFilter { -not $Config.Contains('t4SkuName') -or [string]$Config['t4SkuName'] -eq 'Standard_D4ds_v5' }
    }

    It 'reads a T4 server Azure is deleting as no server, so its size neither moves the fallback''s start nor counts as T4''s (live, 2026-11-09)' {
        Set-HappyAzMock
        $script:listSkusJson = ConvertTo-Json -Depth 10 -InputObject @(@{ name = 'FlexibleServerCapabilities'; supportedServerEditions = @(@{ name = 'Burstable'; supportedServerSkus = @(@{ name = 'Standard_B1ms' }, @{ name = 'Standard_B2s' }) }, @{ name = 'GeneralPurpose'; supportedServerSkus = @(@{ name = 'Standard_D4ds_v5' }, @{ name = 'Standard_D4ads_v5' }, @{ name = 'Standard_D2ds_v5' }) }); supportedServerVersions = @(@{ name = '18' }) })
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -match '^postgres flexible-server list-skus' } -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:listSkusJson; StdErr = '' } }
        # The shell of a Standard_D4ads_v5 that Azure refused: Dropping, with the size it was begun at.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = $false; Present = $true; Removing = $true; State = 'Dropping'; Server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D4ads_v5'; tier = 'GeneralPurpose' } }; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith { [pscustomobject]@{ LightUseMonthly = 10.0; SessionCost = 1.0; T4AutoRestartWorstCaseMonthly = 1.0; T4FixedMonthly = 1.0; DefenderIncluded = $true; MissingPrices = @(); Components = @(); Results = @() } }
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory
        @($results | Where-Object checkId -eq 'PREFLIGHT.T4.SIZE').Count | Should -Be 0
        $capability = $results | Where-Object checkId -eq 'PREFLIGHT.T4.CAPABILITY'
        $capability.status | Should -Be 'Pass'
        $capability.message | Should -Match 'offers T4''s GeneralPurpose Standard_D4ds_v5 and PostgreSQL'
        $capability.evidence.sku | Should -Be 'Standard_D4ds_v5'
        $capability.evidence.exists | Should -BeFalse
        $capability.evidence.startSku | Should -BeNullOrEmpty
    }

    It 'counts the nightly safety stop that this run sets up only when the deployer can assign its role, and prices T5 for a session''s hours, for an Owner and a Contributor (2026-11-19, the coordinator''s option 2 and fix 1)' {
        Set-HappyAzMock
        $script:permission = [pscustomobject]@{ CanDefine = $true; CanAssign = $true; Error = '' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeployerRolePermission -MockWith { $script:permission }
        $owner = @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory)
        $restart = $owner | Where-Object checkId -EQ 'PREFLIGHT.COST.T4RESTART'
        $restart.status | Should -Be 'Pass'
        $restart.message | Should -Match 'and deploy\.ps1 sets up the nightly safety stop in this run, right after its template, and you can assign its role, so the monthly ceiling counts each restart as about a day'
        $restart.message | Should -Match 'If its setup then doesn''t put it in place, the run says so \(DEPLOY\.COST\.T4RESTART\)'
        $restart.evidence['plan']['planned'] | Should -BeTrue
        # Its own estimate and the 2-vCore fallback's both count it.
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -ParameterFilter { $T4RestartCoverage.Counts -and $T4RestartCoverage.Planned -and $T4RestartCoverage.WithoutReason -match 'isn''t in place yet' -and $T5ContainerLifecycle -eq 'Session' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 0 -Exactly -ParameterFilter { -not $T4RestartCoverage.Counts }
        # A Contributor, the documented minimum: the rest of the month, as before, and T5 all month (review of ab91ee5): its
        # session control gets no role, and no nightly safety stop deletes the container, so only stop-demo.ps1 does.
        $script:permission = [pscustomobject]@{ CanDefine = $false; CanAssign = $false; Error = '' }
        $contributor = @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory)
        $warned = $contributor | Where-Object checkId -EQ 'PREFLIGHT.COST.T4RESTART'
        $warned.status | Should -Be 'Warning'
        $warned.evidence['plan']['planned'] | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -ParameterFilter { -not $T4RestartCoverage.Counts -and $T4RestartCoverage.Missing -eq 'SafetyStop' -and $T5ContainerLifecycle -eq 'AlwaysOn' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeployerRolePermission -Times 2 -Exactly -Because 'preflight reads the deployer''s permissions once a run'
    }

    It 'tells the estimate when a Contributor''s update of an environment from main, with no T5 yet, prices T5 all month only because nothing automatic deletes its container, at <Ceiling> USD (the re-review of 0590bbe)' -ForEach @(
        @{ Ceiling = 375 }
        @{ Ceiling = 390 }
    ) {
        # Deployed from main by a Contributor: no T5 and no tag yet, a nightly safety stop without its role, and a session
        # control that never got one. Only stop-demo.ps1 would delete T5's container, so its all-month price never fails the
        # month by itself (Get-DemoCostEstimate -T5ManualDeleteOnly, which DbHubDemo.Cost.Tests.ps1 tests).
        Set-HappyAzMock
        $fromMain = [ordered]@{}
        foreach ($key in $config.Keys) { $fromMain[$key] = $config[$key] }
        $fromMain['monthlyCeilingUsd'] = $Ceiling
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ Exists = $true; T5Container = ''; Tags = @{ deploymentId = 'abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeployerRolePermission -MockWith { [pscustomobject]@{ CanDefine = $false; CanAssign = $false; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4RestartCoverage -MockWith { [pscustomobject]@{ Counts = $false; Missing = 'Role'; Reason = 'the nightly safety stop can''t stop T4: its role isn''t assigned'; Fix = 'An Owner of the subscription runs ./scripts/grant-safety-stop.ps1 once.'; Evidence = [ordered]@{ counts = $false; missing = 'Role'; nightly = 'NoRole' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT5ControlRoleState -MockWith { [pscustomobject]@{ Mode = 'NoRole'; Why = 'id-dbhub-demo-control holds no role at rg-dbhub-demo yet'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = @('Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write'); IdentityExists = $true; HoldsRole = $false; HoldsOther = $false } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT5SafetyStopDelete -MockWith { $false }
        $null = @(Invoke-DemoPreflight -Config $fromMain -SkipWhatIf -SkipPolicyInventory)
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -ParameterFilter { $T5ContainerLifecycle -ceq 'AlwaysOn' -and $T5ManualDeleteOnly -and [double]$Config['monthlyCeilingUsd'] -eq $Ceiling -and -not $T4RestartCoverage.Counts }
        $fromMain['monthlyCeilingUsd'] | Should -Be $Ceiling -Because 'preflight never changes the configured ceiling'
        # A control that keeps a role without the container's actions: no stop deletes the container, so it's no exception.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT5ControlRoleState -MockWith { [pscustomobject]@{ Mode = 'Lacking'; Why = 'its role doesn''t have the container''s actions'; RoleName = 'DbHub Demo Activity Operator'; RoleExists = $true; Lacking = @('Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write'); IdentityExists = $true; HoldsRole = $true; HoldsOther = $false } }
        $null = @(Invoke-DemoPreflight -Config $fromMain -SkipWhatIf -SkipPolicyInventory)
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -ParameterFilter { $T5ContainerLifecycle -ceq 'AlwaysOn' -and -not $T5ManualDeleteOnly }
    }
    It 'prices T4''s General Purpose fallback before anything is created, with its full-month worst case against both ceilings (Phase 28 follow-up)' {
        Set-HappyAzMock
        # Its numbers are set against a 250 USD ceiling, kept here (the default is 415 for a new configuration since 2026-11-19).
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

        # Over monthlyCeilingUsd (150 + 138 = 288 USD): a Warning that the fallback would still create T4, because T4 is part
        # of every deployment (2026-11-09), and how to keep the month within the ceilings.
        $script:lightUse = 150.0
        $fallback = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK'
        $fallback.status | Should -Be 'Warning'
        $fallback.evidence.skipReason | Should -Be 'MonthlyCeiling'
        $fallback.message | Should -Match 'would still create T4, because T4 is part of every deployment, though its cost check doesn''t pass: its worst case, every hour of a month'
        $fallback.remediation | Should -Match '^Nothing to do unless Azure refuses both 4-vCore sizes\. To keep the month within your ceilings then, raise monthlyCeilingUsd to at least 288'
        $fallback.remediation | Should -Not -Match 't4Enabled'

        # The region lists neither 4-vCore size: the run starts at the 2-vCore size, so the run's own estimate prices it. Over
        # a ceiling, the fallback's check says so (its start stays Standard_D2ds_v5, never None any more) but never leaves T4
        # out: there's no estimate without T4, and the run's own cost checks stay (2026-11-09).
        $script:listSkusJson = & $script:listSkus @('Standard_D2ds_v5')
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory
        $fallback = $results | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK'
        $fallback.status | Should -Be 'Warning'
        $fallback.evidence.startSku | Should -Be 'Standard_D2ds_v5'
        $fallback.evidence.skipReason | Should -Be 'MonthlyCeiling'
        $fallback.message | Should -Match 'so this run creates T4 as General Purpose Standard_D2ds_v5 \(2 vCores, 8 GiB\), with autonomous tuning off, although its cost check doesn''t pass: .*brings the demo''s month to 288\.00 USD, over monthlyCeilingUsd \(250\.00 USD\)\. T4 is part of every deployment, so a ceiling never leaves it out\.'
        $fallback.remediation | Should -Match '^To keep the month within your ceilings, raise monthlyCeilingUsd to at least 288 in your configuration \(the budget follows it\), and stop T4 between sessions with \./scripts/stop-demo\.ps1\.$'
        @($results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Be @('Priced with T4 at Standard_D2ds_v5.')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 0 -Exactly -ParameterFilter { $Config['t4Enabled'] -eq $false }
        (InModuleScope DbHubDemo -Parameters @{ Results = $results } { Select-DemoT4StartSku -Sku @($Results | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_.evidence -Name 'startSku') }) }) | Should -Be 'Standard_D2ds_v5'
        $script:lightUse = 60.0
        $fallback = Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK'
        $fallback.status | Should -Be 'Warning' -Because 'a General Purpose T4 is said loudly'
        $fallback.evidence.startSku | Should -Be 'Standard_D2ds_v5'
        $fallback.message | Should -Match 'so this run creates T4 as General Purpose Standard_D2ds_v5'

        # A size the configuration sets has its own fallback since 2026-11-09, which this check names (a Pass; each size is
        # priced right before it's tried), and a configuration with T4 off in memory (Get-DemoConfig never gives one since
        # 2026-11-09) has nothing to price.
        $pinned = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $pinned[$key] = $config[$key] }
        $pinned['t4SkuName'] = 'Standard_B1ms'
        $script:listSkusJson = & $script:listSkus @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
        $pinnedFallback = Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK'
        $pinnedFallback.status | Should -Be 'Pass'
        $pinnedFallback.message | Should -Match '^t4SkuName sets Standard_B1ms\. If Azure refuses it when it creates T4 \(SkuNotAvailable\), deploy\.ps1 tries it once more in another zone the region lists, then the next size Azure accepts, cheapest first: Standard_B2s, Standard_D2ds_v5, Standard_D4ds_v5, Standard_D4ads_v5\.'
        $pinned.Remove('t4SkuName')
        $pinned['t4Enabled'] = $false
        @(Invoke-DemoPreflight -Config $pinned -SkipWhatIf -SkipPolicyInventory | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK').Count | Should -Be 0
    }

    It 'keeps the run''s own cost checks, a monthly-ceiling Fail included, whatever the fallback''s check does: <Case> (review of 20e855c)' -ForEach @(
        @{ Case = 'a 4-vCore start, the 2-vCore estimate refused (HTTP 429)'; GeneralPurpose = @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5'); Throws = 'fallback'; StartSku = ''; Status = 'Warning'; SkipReason = 'Price'; MonthlyMessage = 'Over monthlyCeilingUsd with T4 at Standard_D4ds_v5.'; Match = 'deploy\.ps1 prices its 2-vCore fallback, Standard_D2ds_v5, right before it would create it; right now, its price couldn''t be read from the Azure Retail Prices API \(HTTP 429' }
        # 2026-11-09: T4 is part of every deployment, so a 2-vCore start over a ceiling is a Warning, T4 is created anyway,
        # and no estimate without T4 is made (one would throw here).
        @{ Case = 'a 2-vCore start over a ceiling, which still creates T4 and makes no estimate without it (2026-11-09)'; GeneralPurpose = @('Standard_D2ds_v5'); Throws = 'off'; StartSku = 'Standard_D2ds_v5'; Status = 'Warning'; SkipReason = 'MonthlyCeiling'; MonthlyMessage = 'Over monthlyCeilingUsd with T4 at Standard_D2ds_v5.'; Match = 'so this run creates T4 as General Purpose Standard_D2ds_v5 \(2 vCores, 8 GiB\), with autonomous tuning off, although its cost check doesn''t pass: .*brings the demo''s month to 418\.00 USD, over monthlyCeilingUsd \(415\.00 USD\)\. T4 is part of every deployment, so a ceiling never leaves it out\.' }
        @{ Case = 'the fallback''s check itself throws'; GeneralPurpose = @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5'); Throws = 'check'; StartSku = ''; Status = 'Warning'; SkipReason = 'Price'; MonthlyMessage = 'Over monthlyCeilingUsd with T4 at Standard_D4ds_v5.'; Match = '^T4''s 2-vCore fallback couldn''t be priced in preflight: HTTP 429' }
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
                LightUseMonthly               = 280.0
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
        $monthly[0].message | Should -Be $MonthlyMessage
        @($results | Where-Object { $_.status -eq 'Fail' }).Count | Should -BeGreaterOrEqual 1
        @($results | Where-Object { [string]$_.message -match 'could not be computed' }) | Should -BeNullOrEmpty
        $fallback = @($results | Where-Object checkId -eq 'PREFLIGHT.T4.FALLBACK')
        $fallback.Count | Should -Be 1
        $fallback[0].status | Should -Be $Status
        [string]$fallback[0].evidence.startSku | Should -Be $StartSku
        $fallback[0].evidence.skipReason | Should -Be $SkipReason
        $fallback[0].message | Should -Match $Match
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 0 -Exactly -ParameterFilter { $Config['t4Enabled'] -eq $false } -Because 'no cost check leaves T4 out (2026-11-09)'
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

    It 'leaves a new T5''s private endpoint out of the estimate only after a complete inventory, and keeps it when the inventory is skipped or fails (2026-11-21, ADR 0027)' {
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT5State -MockWith { [pscustomobject]@{ Names = [pscustomobject]@{ AccountName = 'cosmos-dbhub-t5'; PrivateEndpointName = 'pe-cosmos-dbhub-t5' }; Exists = $false; State = 'NotFound'; FreeTier = $false; Account = $null; Error = '' } }
        $public = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $public[$key] = $config[$key] }
        $public['networkMode'] = 'public'

        # A complete inventory without a policy on Azure Cosmos DB's public network access: no endpoint, so none is priced.
        $complete = Invoke-DemoPreflight -Config $public -SkipWhatIf
        $cosmos = $complete | Where-Object checkId -EQ 'PREFLIGHT.POLICY.COSMOSPUBLIC'
        $cosmos.status | Should -Be 'Pass'
        $cosmos.evidence.privateEndpointRequired | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 2 -Exactly -ParameterFilter { $T5PrivateEndpoint -eq $false }

        # Skipped: the endpoint, which works under any policy, and the estimate prices it.
        $skipped = Invoke-DemoPreflight -Config $public -SkipWhatIf -SkipPolicyInventory
        $cosmos = $skipped | Where-Object checkId -EQ 'PREFLIGHT.POLICY.COSMOSPUBLIC'
        $cosmos.status | Should -Be 'Not selected'
        $cosmos.evidence.privateEndpointRequired | Should -BeTrue
        $cosmos.evidence.complete | Should -BeFalse
        $cosmos.message | Should -Match 'The policy inventory didn''t run \(-SkipPolicyInventory\), so a new T5 gets a private endpoint'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 2 -Exactly -ParameterFilter { $T5PrivateEndpoint -eq $true }

        # Failed: the same.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoPolicyConstraint -MockWith { throw 'Resource Graph throttled the read' }
        $failed = Invoke-DemoPreflight -Config $public -SkipWhatIf
        $cosmos = $failed | Where-Object checkId -EQ 'PREFLIGHT.POLICY.COSMOSPUBLIC'
        $cosmos.status | Should -Be 'Not selected'
        $cosmos.evidence.privateEndpointRequired | Should -BeTrue
        $cosmos.message | Should -Match '\(the inventory failed\)'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 4 -Exactly -ParameterFilter { $T5PrivateEndpoint -eq $true }
    }

    It 'checks the T5 the template step deploys, and moves it behind its endpoint when a policy the inventory doesn''t read denies it with public network access (the review of fae05b4, 2026-11-22)' {
        Set-HappyAzMock
        $script:t5StateRead = 'NotFound'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT5State -MockWith {
            $names = [pscustomobject]@{ AccountName = 'cosmos01-abc123'; PrivateEndpointName = 'pe-dbhub-demo-cosmos01' }
            if ($script:t5StateRead -eq 'Public') {
                return [pscustomobject]@{ Names = $names; Exists = $true; State = 'Succeeded'; FreeTier = $false; Account = [pscustomobject]@{ properties = [pscustomobject]@{ publicNetworkAccess = 'Enabled' } }; Error = '' }
            }
            [pscustomobject]@{ Names = $names; Exists = $false; State = $script:t5StateRead; FreeTier = $false; Account = $null; Error = $(if ($script:t5StateRead -eq 'NotFound') { '' } else { 'AuthorizationFailed' }) }
        }
        # A policy assigned to the existing demo resource group, which the inventory doesn't read, as Azure refuses it.
        $script:whatIfSent = [System.Collections.Generic.List[object]]::new()
        $script:whatIfDenies = @('cosmos01-abc123')
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { ($ArgumentList -join ' ') -like 'deployment sub what-if *' } -MockWith {
            $parameterFile = ($ArgumentList | Where-Object { $_ -like '@*' } | Select-Object -First 1).Substring(1)
            $sent = Get-Content -LiteralPath $parameterFile -Raw | ConvertFrom-Json -AsHashtable
            $script:whatIfSent.Add($sent)
            if (@($script:whatIfDenies).Count -gt 0 -and -not $sent['parameters']['t5PrivateAccess']['value']) {
                $details = @(foreach ($name in $script:whatIfDenies) { '{{"code":"RequestDisallowedByPolicy","target":"{0}","message":"Resource ''{0}'' was disallowed by policy. Policy identifiers: ''[{{\"policyAssignment\":{{\"name\":\"Deny public Cosmos DB (example)\"}}}}]''."}}' -f $name }) -join ','
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('ERROR: {{"error":{{"code":"InvalidTemplateDeployment","message":"The template deployment failed because of policy violation.","details":[{0}]}}}}' -f $details) }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"status":"Succeeded","changes":[{"changeType":"Create"},{"changeType":"Create"}]}'; StdErr = '' }
        }
        $public = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        foreach ($key in 'subscriptionId', 'tenantId', 't3AdminGroupObjectId') { $public[$key] = $config[$key] }
        $public['networkMode'] = 'public'

        # The inventory finds nothing, so T5 would be public: the what-if checks that, Azure denies it, and T5 gets its endpoint.
        $results = @(Invoke-DemoPreflight -Config $public)
        $script:whatIfSent.Count | Should -Be 2
        $script:whatIfSent[0]['parameters']['t5PrivateAccess']['value'] | Should -BeFalse -Because 'the what-if checks the public T5 the template step would deploy'
        $script:whatIfSent[1]['parameters']['t5PrivateAccess']['value'] | Should -BeTrue
        @($script:whatIfSent | ForEach-Object { [bool]$_['parameters']['t5WasPublic']['value'] }) | Should -Be @($false, $false) -Because 'a new T5 isn''t public yet'
        $whatIf = $results | Where-Object checkId -EQ 'PREFLIGHT.POLICY.WHATIF'
        $whatIf.status | Should -Be 'Pass'
        $whatIf.message | Should -Match 'with T5 behind its private endpoint, because Azure Policy denies it with public network access'
        $cosmos = @($results | Where-Object checkId -EQ 'PREFLIGHT.POLICY.COSMOSPUBLIC')
        $cosmos.Count | Should -Be 1
        $cosmos[0].status | Should -Be 'Pass'
        $cosmos[0].evidence.privateEndpointRequired | Should -BeTrue
        $cosmos[0].evidence.reason | Should -Be 'Policy'
        $cosmos[0].evidence.complete | Should -BeTrue
        $cosmos[0].evidence.whatIfDenied | Should -Be 'RequestDisallowedByPolicy: Azure Policy disallowed cosmos01-abc123'
        $cosmos[0].message | Should -Match '^The what-if found that Azure Policy denies T5 with public network access .*one assigned to the resource group'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 2 -Exactly -ParameterFilter { $T5PrivateEndpoint -eq $true }
        # The template step decides from that evidence: the endpoint.
        $decided = InModuleScope DbHubDemo -Parameters @{ Config = $public; Policy = $cosmos[0].evidence } { Resolve-DemoT5NetworkAccess -Config $Config -NetworkMode public -Policy $Policy -AccountState ([pscustomobject]@{ Names = [pscustomobject]@{ AccountName = 'cosmos01-abc123'; PrivateEndpointName = 'pe-dbhub-demo-cosmos01' }; Exists = $false; State = 'NotFound'; Account = $null; Error = '' }) }
        $decided.PrivateAccess | Should -BeTrue
        $decided.Reason | Should -Be 'Policy'

        # A denial that names another resource too isn't T5's alone: one what-if, and its Fail, as before.
        $script:whatIfSent.Clear()
        $script:whatIfDenies = @('cosmos01-abc123', 'vnet-dbhub-demo')
        $results = @(Invoke-DemoPreflight -Config $public)
        $script:whatIfSent.Count | Should -Be 1
        ($results | Where-Object checkId -EQ 'PREFLIGHT.POLICY.WHATIF').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'PREFLIGHT.POLICY.COSMOSPUBLIC').evidence.privateEndpointRequired | Should -BeFalse

        # Without the policy: one what-if, of the public T5.
        $script:whatIfSent.Clear()
        $script:whatIfDenies = @()
        $results = @(Invoke-DemoPreflight -Config $public)
        $script:whatIfSent.Count | Should -Be 1
        $script:whatIfSent[0]['parameters']['t5PrivateAccess']['value'] | Should -BeFalse
        ($results | Where-Object checkId -EQ 'PREFLIGHT.POLICY.WHATIF').message | Should -Not -Match 'T5'

        # Not known (an account that can't be read): the endpoint, the template's default, in the what-if as in the template step.
        $script:whatIfSent.Clear()
        $script:whatIfDenies = @('cosmos01-abc123')
        $script:t5StateRead = 'Unknown'
        $results = @(Invoke-DemoPreflight -Config $public)
        $script:whatIfSent.Count | Should -Be 1
        $script:whatIfSent[0]['parameters']['t5PrivateAccess']['value'] | Should -BeTrue
        ($results | Where-Object checkId -EQ 'PREFLIGHT.POLICY.WHATIF').status | Should -Be 'Pass'

        # An existing public T5 under such a policy (2026-11-22): both what-ifs keep snet-sqlvm's Azure Cosmos DB service
        # endpoint, as the template step does while the account moves.
        $script:whatIfSent.Clear()
        $script:t5StateRead = 'Public'
        $results = @(Invoke-DemoPreflight -Config $public)
        $script:whatIfSent.Count | Should -Be 2
        $script:whatIfSent[0]['parameters']['t5PrivateAccess']['value'] | Should -BeFalse
        $script:whatIfSent[1]['parameters']['t5PrivateAccess']['value'] | Should -BeTrue
        @($script:whatIfSent | ForEach-Object { [bool]$_['parameters']['t5WasPublic']['value'] }) | Should -Be @($true, $true)
        ($results | Where-Object checkId -EQ 'PREFLIGHT.POLICY.WHATIF').status | Should -Be 'Pass'
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
        $p6.remediation | Should -Match 'Create an Entra security group'
    }

    It 'asks for a new sign-in, not a new group, when Microsoft Graph refuses the token (live, 2026-11-16)' {
        # Live, 2026-11-16: after the tenant's sign-in policies changed, Graph answered 401 with Continuous Access
        # Evaluation's InteractionRequired, also for one fresh token, and P6 told the user to create a new group.
        Set-HappyAzMock
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -ParameterFilter { $Uri -like 'https://graph.microsoft.com/v1.0/groups/*' } -MockWith {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 401 on GET https://graph.microsoft.com/v1.0/groups/x: {"error":{"code":"InvalidAuthenticationToken","message":"Continuous access evaluation resulted in challenge with result: InteractionRequired and code: TokenCreatedWithOutdatedPolicies"}}'; StatusCode = 401; Challenge = 'Claims challenge (Continuous Access Evaluation) on the cached token, and the request failed again with one fresh token.' }
        }
        $p6 = Invoke-DemoPreflight -Config $config | Where-Object checkId -eq 'PREFLIGHT.P6.GROUP'
        $p6.status | Should -Be 'Fail'
        $p6.message | Should -Match 'refused the Azure CLI''s sign-in and asks for a new one'
        $p6.remediation | Should -Match '^Sign in again yourself: az login'
        $p6.remediation | Should -Match 'nothing in the configuration changes'
        $p6.remediation | Should -Not -Match 'Create an Entra security group' -Because 'the group exists; only the sign-in is refused'
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

    It 'reports the optional P11 viewer licensing once, asking it for nothing but the configuration (2026-11-14)' {
        Set-HappyAzMock
        $results = Invoke-DemoPreflight -Config $config -SkipWhatIf
        $license = @($results | Where-Object checkId -eq 'PREFLIGHT.FABRIC.VIEWERLICENSE')
        $license.Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricViewerLicense -Times 1 -Exactly -ParameterFilter {
            $Config['fabric']['workspaceId'] -eq $config['fabric']['workspaceId'] -and @($PesterBoundParameters.Keys) -join ',' -eq 'Config'
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

Describe 'Get-DemoFabricSharedResult: deploy.ps1 never puts an environment in another environment''s Fabric workspace (2026-11-19)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
        $script:ownerId = 'dddddddd-0000-0000-0000-000000000001'
        # A second environment, rg-dbhubfn-demo, whose configuration names the owner's workspace (init.ps1 at 9a218e0, or a
        # hand edit), which rg-dbhub-demo records.
        $script:second = $config | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
        $script:second['prefix'] = 'dbhubfn'
        $script:second['fabric']['workspaceName'] = 'Database Hub Demo'
        $script:others = @([pscustomobject]@{ Name = 'rg-dbhub-demo'; SubscriptionId = '11111111-2222-3333-4444-555555555555'; Label = 'rg-dbhub-demo'; Tagged = $true; Claims = @($script:ownerId) })
        $script:own = [pscustomobject]@{ Found = $false; FabricWorkspaceId = ''; Claims = @(); UsedFabric = $false }
        $script:claimOk = $true
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricWorkspaceClaim -MockWith { [pscustomobject]@{ Ok = $script:claimOk; Error = $(if ($script:claimOk) { '' } else { 'AccessDenied' }); Others = $script:others; Own = $script:own } }
        $script:check = { param([System.Collections.IDictionary] $Config, [string] $Id) InModuleScope DbHubDemo -Parameters @{ Config = $Config; Id = $Id } { Get-DemoFabricSharedResult -Config $Config -WorkspaceId $Id } }
    }

    It 'is a Fail before anything is created when another environment records the workspace and this new one doesn''t (the final tests'' F5)' {
        $shared = & $script:check $script:second $script:ownerId
        $shared.checkId | Should -Be 'DEPLOY.FABRIC.SHARED'
        $shared.status | Should -Be 'Fail'
        $shared.message | Should -Be 'The Fabric workspace "Database Hub Demo" (fabric.workspaceName) is the one rg-dbhub-demo records as its own, not this environment''s (rg-dbhubfn-demo), so deploy.ps1 stops before it creates anything: it would put this environment''s lakehouse, history model, report, notebooks, and Insights app there, over the other environment''s.'
        $shared.remediation | Should -Be 'Give this environment its own workspace: set fabric.workspaceName in its configuration to a name no other environment uses, for example "Database Hub Demo dbhubfn", or run ./scripts/init.ps1 -Force -Prefix dbhubfn -WorkspaceName "Database Hub Demo dbhubfn"; then run ./scripts/deploy.ps1 again.'
        $shared.evidence.outcome | Should -Be 'claimed'
        @($shared.evidence.claimedBy) | Should -Be @('rg-dbhub-demo')

        # An environment that records another workspace (its configuration edited by hand since), or none and never finished
        # a Fabric step (a first run that stopped before it): a Fail too.
        foreach ($own in @(
                [pscustomobject]@{ Found = $true; FabricWorkspaceId = 'dddddddd-0000-0000-0000-000000000009'; Claims = @('dddddddd-0000-0000-0000-000000000009'); UsedFabric = $true }
                [pscustomobject]@{ Found = $true; FabricWorkspaceId = ''; Claims = @(); UsedFabric = $false }
            )) {
            $script:own = $own
            (& $script:check $script:second $script:ownerId).status | Should -Be 'Fail'
        }
    }

    It 'keeps an environment that shares the workspace already going, with a Warning and how to move, so its update never breaks' {
        # The existing user who updates: rg-dbhubfn-demo records the workspace too.
        $script:own = [pscustomobject]@{ Found = $true; FabricWorkspaceId = $script:ownerId; Claims = @($script:ownerId); UsedFabric = $true }
        $shared = & $script:check $script:second $script:ownerId
        $shared.status | Should -Be 'Warning'
        $shared.message | Should -Be 'The Fabric workspace "Database Hub Demo" is this environment''s (rg-dbhubfn-demo records it), and rg-dbhub-demo records it too, so the environments share it: each deploy.ps1 puts its own notebooks there, over the other''s. This run goes on with it, as before.'
        $shared.remediation | Should -Be 'To move this environment to a workspace of its own, set fabric.workspaceName in its configuration to a name no other environment uses, for example "Database Hub Demo dbhubfn", and run ./scripts/deploy.ps1: it creates that workspace with the demo''s items and records it, and "Database Hub Demo" stays as it is for rg-dbhub-demo.'
        $shared.evidence.outcome | Should -Be 'shared'

        # One deployed before 2026-11-17 used Fabric and records nothing: it may be its own workspace, so a Warning too.
        $script:own = [pscustomobject]@{ Found = $true; FabricWorkspaceId = ''; Claims = @(); UsedFabric = $true }
        $unrecorded = & $script:check $script:second $script:ownerId
        $unrecorded.status | Should -Be 'Warning'
        $unrecorded.evidence.outcome | Should -Be 'unrecorded'
        $unrecorded.message | Should -Match '^The Fabric workspace "Database Hub Demo" is the one rg-dbhub-demo records as its own, and this environment \(rg-dbhubfn-demo\) records none: it was deployed before 2026-11-17'
    }

    It 'says nothing for a workspace nobody else records or one that doesn''t exist yet, and warns when Resource Graph can''t say' {
        & $script:check $config 'dddddddd-0000-0000-0000-000000000009' | Should -BeNullOrEmpty
        & $script:check $script:second '' | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricWorkspaceClaim -Times 1 -Exactly -Because 'a workspace that doesn''t exist yet is nobody''s, so Resource Graph isn''t asked'
        $script:claimOk = $false
        $unread = & $script:check $script:second $script:ownerId
        $unread.status | Should -Be 'Warning' -Because 'never a silent Pass, and never a Fail that a Resource Graph outage causes'
        $unread.message | Should -Match '^Whether another demo environment records the Fabric workspace "Database Hub Demo" couldn''t be checked before anything is created: AccessDenied\. deploy\.ps1 goes on with it'
    }

    It 'looks the workspace up by name, read-only, for a run without preflight (-Resolve)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoHubFabricAccess -MockWith { [pscustomobject]@{ Available = $true; Token = [System.Security.SecureString]::new(); Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith { [pscustomobject]@{ WorkspaceId = 'dddddddd-0000-0000-0000-000000000001'; WorkspaceName = 'Database Hub Demo'; Results = @() } }
        $shared = InModuleScope DbHubDemo -Parameters @{ Config = $script:second } { Get-DemoFabricSharedResult -Config $Config -Resolve }
        $shared.status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -Times 1 -Exactly -ParameterFilter { [bool]$SkipLakehouse -and -not $PesterBoundParameters.ContainsKey('Create') }
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

Describe 'The Azure Automation accounts a deployment adds (PREFLIGHT.P3.AUTOMATION, F30)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
        # Whether Azure Resource Manager has each of the two accounts: there, missing (HTTP 404), or unread.
        $script:accountState = @{ control = 'missing'; safety = 'missing' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoActivityControlArm -MockWith {
            $state = if ($Url -match '/automationAccounts/aa-dbhub-control\?') { $script:accountState['control'] } elseif ($Url -match '/automationAccounts/aa-dbhub-demo-safetystop\?') { $script:accountState['safety'] } else { throw ('unexpected ARM call: {0}' -f $Url) }
            switch ($state) {
                'there' { [pscustomobject]@{ Ok = $true; Missing = $false; Value = @{ name = 'account' }; Error = '' } }
                'missing' { [pscustomobject]@{ Ok = $false; Missing = $true; Value = $null; Error = 'ResourceNotFound' } }
                default { [pscustomobject]@{ Ok = $false; Missing = $false; Value = $null; Error = 'AuthorizationFailed' } }
            }
        }
        # The accounts Azure Resource Graph lists in the region, by name. Live, 2026-11-21: 10 in westus3 (five environments,
        # two each), in a Microsoft internal subscription. The fake leaves out the names a query's name !in~ (...) lists,
        # case-insensitively, as Resource Graph does.
        $script:others = { param([int] $Count) if ($Count -gt 0) { 1..$Count | ForEach-Object { 'aa-env{0}-account' -f $_ } } }
        $script:regionAccounts = @(& $script:others 10)
        $script:graphFails = $false
        $script:graphQueries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHubResourceGraph -MockWith {
            $script:graphQueries.Add($Query)
            if ($script:graphFails) {
                return [pscustomobject]@{ Succeeded = $false; Error = 'AuthorizationFailed.'; Rows = @(); Truncated = $false }
            }
            $leftOut = if ($Query -match 'name !in~ \(([^)]*)\)') { @([regex]::Matches($Matches[1], "'([^']*)'") | ForEach-Object { $_.Groups[1].Value }) } else { @() }
            $total = @($script:regionAccounts | Where-Object { $leftOut -notcontains $_ }).Count
            [pscustomobject]@{ Succeeded = $true; Error = ''; Rows = @([pscustomobject]@{ total = $total }); Truncated = $false }
        }
        $script:quotaId = 'Internal_2014-09-01'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSubscriptionQuotaId -MockWith { $script:quotaId }
        # The demo resource group: missing, deployed (a stage recorded), created (tags, no stage), or unread.
        $script:group = 'missing'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { $ArgumentList[0] -eq 'group' -and $ArgumentList[1] -eq 'exists' } -MockWith {
            switch ($script:group) {
                'missing' { [pscustomobject]@{ ExitCode = 0; StdOut = "false`n"; StdErr = '' } }
                'unread' { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: The operation timed out.' } }
                default { [pscustomobject]@{ ExitCode = 0; StdOut = "true`n"; StdErr = '' } }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith {
            switch ($script:group) {
                'deployed' { @{ solution = 'fabric-database-hub-demo'; DbHubDeployStage = 'Validation' } }
                'created' { @{ costCenter = 'demo' } }
                default { @{} }
            }
        }
        $script:check = {
            param([System.Collections.IDictionary] $Settings = $config)
            InModuleScope -ModuleName DbHubDemo -Parameters @{ Settings = $Settings } { Get-DemoAutomationAccountQuotaResult -Config $Settings }
        }
    }

    It 'stops a new deployment whose two accounts don''t fit, before anything is created (live, dbhubra: 10 of 10 in westus3)' {
        $result = & $script:check
        $result.checkId | Should -Be 'PREFLIGHT.P3.AUTOMATION'
        $result.status | Should -Be 'Fail'
        # Microsoft's internal offer isn't on Learn, so its default is labeled as observed (the review of F30).
        $result.message | Should -BeExactly 'The subscription has 10 other Azure Automation account(s) in westus3; with this deployment''s aa-dbhub-control (for the session control) and aa-dbhub-demo-safetystop (for the nightly safety stop), it would have 12, more than the default quota of 10 for a Microsoft internal subscription (as observed; Learn doesn''t list this offer), so Azure would refuse them unless the subscription''s quota there is higher. Nothing was created.'
        $result.remediation | Should -BeExactly 'The default quota for a Microsoft internal subscription is 10 per region, as observed (Learn doesn''t list this offer). If the subscription''s quota for Automation accounts in westus3 is higher (the Azure portal''s Quotas page, provider Automation accounts, shows it), set automationAccountQuota in your configuration to it, and preflight checks it. Otherwise free an Automation account in westus3: ./scripts/destroy.ps1 on a demo environment you no longer use deletes its two (Azure Resource Graph can list a deleted one for a few more minutes). Or raise the subscription''s quota for Automation accounts in westus3 (the Azure portal''s Quotas page, provider Automation accounts, or a support request), then set automationAccountQuota in your configuration to it. Or set location to another region. Then run ./scripts/deploy.ps1 again.'
        $result.docUrl | Should -Be 'https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#automation-limits'
        $result.evidence['adds'] | Should -Be 2
        $result.evidence['existing'] | Should -Be 10
        $result.evidence['needed'] | Should -Be 12
        $result.evidence['quota'] | Should -Be 10
        $result.evidence['quotaSource'] | Should -Be 'offer'
        $result.evidence['newDeployment'] | Should -BeTrue
        @($script:graphQueries) | Should -Be @("resources | where type =~ 'microsoft.automation/automationaccounts' and location =~ 'westus3' and name !in~ ('aa-dbhub-control', 'aa-dbhub-demo-safetystop') | summarize total = count()")
        # A resource group created ahead, which no run has deployed into, is a new deployment too.
        $script:group = 'created'
        (& $script:check).status | Should -Be 'Fail'
    }

    It 'counts the accounts it adds once when Resource Graph still lists them, deleted minutes ago (deploy.ps1 right after destroy.ps1; the review of F30)' {
        # Resource Manager answers 404 for both, and Resource Graph still lists them, in any case.
        $script:quotaId = 'PayAsYouGo_2014-09-01'
        $script:regionAccounts = @('aa-dbhub-control', 'AA-DBHUB-DEMO-SAFETYSTOP')
        $result = & $script:check
        $result.status | Should -Be 'Pass'
        $result.message | Should -BeExactly 'The subscription has 0 other Azure Automation account(s) in westus3; with this deployment''s aa-dbhub-control (for the session control) and aa-dbhub-demo-safetystop (for the nightly safety stop), it would have 2, within Learn''s default quota of 2 for a pay-as-you-go subscription.'
        $result.evidence['existing'] | Should -Be 0
        $result.evidence['needed'] | Should -Be 2
        # Another environment's account, deleted minutes ago, still counts: the fix says so.
        $script:regionAccounts += 'aa-env1-account'
        $result = & $script:check
        $result.status | Should -Be 'Fail'
        $result.remediation | Should -Match 'Azure Resource Graph can list a deleted one for a few more minutes'
    }

    It 'never stops an update whose accounts are there, and reads nothing more' {
        $script:accountState = @{ control = 'there'; safety = 'there' }
        $result = & $script:check
        $result.status | Should -Be 'Pass'
        $result.message | Should -BeExactly 'This deployment adds no Azure Automation account: aa-dbhub-control and aa-dbhub-demo-safetystop are there.'
        $script:graphQueries | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoSubscriptionQuotaId -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'group' }
    }

    It 'warns, and never stops, an environment that has deployed before and lacks its accounts (dbhubra''s next run), or when that can''t be read' {
        $script:group = 'deployed'
        $result = & $script:check
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'so Azure would refuse them unless the subscription''s quota there is higher\. This environment has deployed before, so its update goes on, and DEPLOY\.CONTROL and SAFETYSTOP\.RESOURCES say what''s missing\.$'
        $result.remediation | Should -Match '^The default quota for a Microsoft internal subscription is 10 per region, as observed '
        $result.evidence['newDeployment'] | Should -BeFalse
        foreach ($unreadable in 'unread', 'tagsunread') {
            $script:group = $unreadable
            $result = & $script:check
            $result.status | Should -Be 'Warning' -Because $unreadable
            $result.message | Should -Match 'Whether this is a new deployment couldn''t be read, so it goes on' -Because $unreadable
        }
    }

    It 'passes when they fit: <Case>' -ForEach @(
        @{ Case = 'an Enterprise subscription with 8'; QuotaId = 'EnterpriseAgreement_2014-09-01'; Others = 8; Control = 'missing'; Adds = 2; Needed = 10; Quota = 'Learn''s default quota of 10 for an Enterprise Agreement or Microsoft Customer Agreement subscription' }
        @{ Case = 'a pay-as-you-go subscription with none'; QuotaId = 'PayAsYouGo_2014-09-01'; Others = 0; Control = 'missing'; Adds = 2; Needed = 2; Quota = 'Learn''s default quota of 2 for a pay-as-you-go subscription' }
        @{ Case = 'Learn''s spelling of pay-as-you-go'; QuotaId = 'Pay-as-you-go_2014-09-01'; Others = 0; Control = 'missing'; Adds = 2; Needed = 2; Quota = 'Learn''s default quota of 2 for a pay-as-you-go subscription' }
        @{ Case = 'a new environment of a prefix whose session control is there'; QuotaId = 'MSDN_2014-09-01'; Others = 0; Control = 'there'; Adds = 1; Needed = 2; Quota = 'Learn''s default quota of 2 for a Visual Studio \(MSDN\) subscription' }
    ) {
        $script:quotaId = $QuotaId
        $script:regionAccounts = @(& $script:others $Others)
        $script:accountState['control'] = $Control
        $listed = $Others
        if ($Control -eq 'there') {
            # Resource Graph counts an account that's there: Resource Manager answered for the ones the deployment adds.
            $script:regionAccounts += 'aa-dbhub-control'
            $listed++
        }
        $result = & $script:check
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match ('^The subscription has {0} other Azure Automation account\(s\) in westus3; with this deployment''s .+, it would have {1}, within {2}\.$' -f $listed, $Needed, $Quota)
        $result.evidence['adds'] | Should -Be $Adds
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'group' }
    }

    It 'stops a new pay-as-you-go deployment that one account already in the region leaves no room for' {
        $script:quotaId = 'PayAsYouGo_2014-09-01'
        $script:regionAccounts = @(& $script:others 1)
        $result = & $script:check
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match '^The subscription has 1 other Azure Automation account\(s\) in westus3; with this deployment''s .+, it would have 3, more than Learn''s default quota of 2 for a pay-as-you-go subscription, so Azure would refuse them unless the subscription''s quota there is higher\. Nothing was created\.$'
    }

    It 'calls an offer''s default the default, not the quota, and leads its fix with automationAccountQuota (the review of F30: an Enterprise subscription with 9)' {
        $script:quotaId = 'EnterpriseAgreement_2014-09-01'
        $script:regionAccounts = @(& $script:others 9)
        $result = & $script:check
        $result.status | Should -Be 'Fail'
        $result.message | Should -BeExactly 'The subscription has 9 other Azure Automation account(s) in westus3; with this deployment''s aa-dbhub-control (for the session control) and aa-dbhub-demo-safetystop (for the nightly safety stop), it would have 11, more than Learn''s default quota of 10 for an Enterprise Agreement or Microsoft Customer Agreement subscription, so Azure would refuse them unless the subscription''s quota there is higher. Nothing was created.'
        $result.message | Should -Not -Match 'where its quota is'
        $result.remediation | Should -Match '^Learn''s default quota for an Enterprise Agreement or Microsoft Customer Agreement subscription is 10 per region\. If the subscription''s quota for Automation accounts in westus3 is higher \(the Azure portal''s Quotas page, provider Automation accounts, shows it\), set automationAccountQuota in your configuration to it, and preflight checks it\. Otherwise free an Automation account in westus3: '
    }

    It 'uses automationAccountQuota, a quota that was raised, in place of the offer''s default' {
        $config['automationAccountQuota'] = 15
        try {
            $script:regionAccounts = @(& $script:others 13)
            $result = & $script:check
            $result.status | Should -Be 'Pass'
            $result.message | Should -Match ', it would have 15, within its quota of 15 \(automationAccountQuota\)\.$'
            $result.evidence['quotaSource'] | Should -Be 'configuration'
            $script:regionAccounts = @(& $script:others 14)
            $result = & $script:check
            $result.status | Should -Be 'Fail'
            # The quota the configuration gives is the quota: no "unless", and the fix frees or raises.
            $result.message | Should -Match ', it would have 16, more than its quota of 15 \(automationAccountQuota\), so Azure would refuse them\. Nothing was created\.$'
            $result.remediation | Should -Match '^Free an Automation account in westus3: '
        }
        finally {
            $config.Remove('automationAccountQuota')
        }
    }

    It 'warns when the region has more accounts than the offer''s default: a raised quota it can''t read' {
        $script:quotaId = 'PayAsYouGo_2014-09-01'
        $script:regionAccounts = @(& $script:others 5)
        $result = & $script:check
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match '^The subscription has 5 other Azure Automation account\(s\) in westus3, more than Learn''s default quota of 2 for a pay-as-you-go subscription, so its quota there is higher, by how much can''t be read'
        $result.remediation | Should -Match '^Set automationAccountQuota in your configuration to the subscription''s quota for Automation accounts in westus3 '
    }

    It 'passes two accounts in an empty region for an offer Learn names no default for, and warns above that' {
        $script:quotaId = 'MSDNDevTest_2014-09-01'
        $script:regionAccounts = @()
        $result = & $script:check
        $result.status | Should -Be 'Pass'
        $result.evidence['quotaSource'] | Should -Be 'unknown'
        $script:regionAccounts = @(& $script:others 3)
        $result = & $script:check
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'Learn names no default quota of Automation accounts for its offer, MSDNDevTest_2014-09-01, so whether '
        $script:quotaId = ''
        (& $script:check).message | Should -Match 'for its offer, which couldn''t be read, so whether '
    }

    It 'stops a new deployment in a Free Trial subscription, whose one account per region can''t be raised' {
        $script:quotaId = 'FreeTrial_2014-09-01'
        $script:regionAccounts = @()
        $result = & $script:check
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match ', it would have 2, more than Learn''s default quota of 1 for a Free Trial subscription, which can''t be raised, so Azure would refuse them\. Nothing was created\.$'
        $result.remediation | Should -Match '^A Free Trial subscription has at most one Automation account per region, in East US, East US 2, West US, North Europe, Southeast Asia, and Japan West 2 only, and its quota can''t be raised, while every demo environment has two: use a pay-as-you-go or Enterprise subscription'
    }

    It 'warns when the accounts can''t be counted, or only an account it can''t read would be over' {
        $script:graphFails = $true
        $result = & $script:check
        $result.status | Should -Be 'Warning'
        $result.message | Should -BeExactly 'The subscription''s Azure Automation accounts in westus3 couldn''t be counted (AuthorizationFailed), so whether this deployment''s aa-dbhub-control (for the session control) and aa-dbhub-demo-safetystop (for the nightly safety stop) fit its quota there isn''t known.'
        $script:graphFails = $false
        $script:quotaId = 'PayAsYouGo_2014-09-01'
        $script:regionAccounts = @('aa-dbhub-demo-safetystop', 'aa-env1-account')
        $script:accountState = @{ control = 'unread'; safety = 'there' }
        $result = & $script:check
        $result.status | Should -Be 'Warning'
        $result.message | Should -BeExactly 'The subscription has 2 other Azure Automation account(s) in westus3; with this deployment''s aa-dbhub-control (for the session control), it would have 3, more than Learn''s default quota of 2 for a pay-as-you-go subscription. Whether aa-dbhub-control is there couldn''t be read: if it isn''t, Azure would refuse it unless the subscription''s quota there is higher; if it is, nothing is added. So preflight goes on, and DEPLOY.CONTROL and SAFETYSTOP.RESOURCES say what''s missing.'
        $result.remediation | Should -Match '^Nothing to do now\. '
    }

    It 'counts an account it can''t read once, whether it''s there or not' {
        $script:quotaId = 'PayAsYouGo_2014-09-01'
        $script:accountState = @{ control = 'unread'; safety = 'missing' }
        foreach ($listed in @(@('aa-env1-account'), @('aa-env1-account', 'aa-dbhub-control'))) {
            # The region after the deployment has the other account, the session control's, and the safety stop's: 3 of 2.
            $script:regionAccounts = $listed
            $result = & $script:check
            $result.status | Should -Be 'Fail' -Because ($listed -join ', ')
            $result.evidence['needed'] | Should -Be 3 -Because ($listed -join ', ')
            $result.message | Should -Match ' Whether aa-dbhub-control is there couldn''t be read, so it counts as added\. Nothing was created\.$'
        }
        # One account of room: it fits either way.
        $script:regionAccounts = @()
        $result = & $script:check
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match ', it would have 2, within Learn''s default quota of 2 for a pay-as-you-go subscription\. Whether aa-dbhub-control is there couldn''t be read, so it counts as added\.$'
    }

    It 'runs in preflight after the public IP check, and a Fail there fails preflight' {
        $script:policyAssignmentsJson = '{"value":[]}'
        $script:groupOwnersJson = '{"value":[{"id":"88888888-8888-8888-8888-888888888888"}]}'
        $script:whatIfParameters = $null
        $script:pgCapabilitiesJson = '{}'
        $script:pgDeploymentJson = '{}'
        $script:pgOperationsJson = '[]'
        Set-HappyAzMock
        $results = @(Invoke-DemoPreflight -Config $config -SkipWhatIf -SkipPolicyInventory)
        $ids = @($results | ForEach-Object { [string]$_.checkId })
        $ids.IndexOf('PREFLIGHT.P3.AUTOMATION') | Should -Be ($ids.IndexOf('PREFLIGHT.P3.PUBLICIP') + 1)
        ($results | Where-Object checkId -EQ 'PREFLIGHT.P3.AUTOMATION').status | Should -Be 'Fail'
        (Get-DemoExitCode -Result $results) | Should -Not -Be 0
    }
}
