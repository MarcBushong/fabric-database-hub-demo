BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    $script:arcRole = 'Azure Hybrid Database Administrator - Read Only Service Role'
    $script:presenterA = '77777777-7777-7777-7777-777777777777'
    $script:presenterB = '88888888-8888-8888-8888-888888888888'
    $script:roleIds = @{
        'Reader' = '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -f $script:HubSubscriptionId
        $script:arcRole = '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -f $script:HubSubscriptionId
    }

    function Initialize-RbacMock {
        # Azure CLI mock for role work: permissions, definitions by name, existing assignments, and creates.
        param([string[]] $Actions = @('*'), [string[]] $Existing = @(), [string[]] $MissingRole = @(), [string] $CreateError = '')
        $script:rbacActions = $Actions
        $script:rbacExisting = $Existing
        $script:rbacMissing = $MissingRole
        $script:rbacCreateError = $CreateError
        $script:rbacCreates = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            if ($joined -like 'rest --method get --url https://management.azure.com/subscriptions/*/providers/Microsoft.Authorization/permissions?api-version=2022-04-01*') {
                $body = @{ value = @(@{ actions = $script:rbacActions; notActions = @() }) } | ConvertTo-Json -Depth 5
                return [pscustomobject]@{ ExitCode = 0; StdOut = $body; StdErr = '' }
            }
            if ($joined -like 'role definition list --name *') {
                $name = $ArgumentList[[array]::IndexOf($ArgumentList, '--name') + 1]
                $items = if ($name -in $script:rbacMissing) { @() } else { @(@{ roleName = $name; name = ($script:roleIds[$name] -split '/')[-1]; id = $script:roleIds[$name] }) }
                return [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject $items -Depth 5); StdErr = '' }
            }
            if ($joined -like 'role assignment list *') {
                $who = $ArgumentList[[array]::IndexOf($ArgumentList, '--assignee-object-id') + 1]
                $items = if ($who -in $script:rbacExisting) { @(@{ principalId = $who; roleDefinitionId = $ArgumentList[[array]::IndexOf($ArgumentList, '--role') + 1] }) } else { @() }
                return [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject $items -Depth 5); StdErr = '' }
            }
            if ($joined -like 'role assignment create *') {
                $script:rbacCreates.Add($joined)
                if ($script:rbacCreateError) {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = $script:rbacCreateError }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
            }
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('unexpected az call: {0}' -f $joined) }
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Set-DemoPresenterAccess (assignRoles gate, ADR 0008)' {
    BeforeEach {
        Clear-DemoSecret
        $config = Get-HubTestConfig
        $config['presenterObjectIds'] = @($script:presenterA, $script:presenterB)
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
    }

    It 'prints the exact administrator commands and calls nothing when assignRoles is false' {
        Initialize-RbacMock
        $results = @(Set-DemoPresenterAccess -Config $config)
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('HUB.PRESENTER.READER', 'HUB.PRESENTER.ARCTELEMETRY')
        $results | ForEach-Object { $_.status | Should -Be 'Manual action required' }
        $sub = $script:HubSubscriptionId
        $results[0].remediation | Should -Match ([regex]::Escape("az role assignment create --subscription $sub --assignee-object-id $script:presenterA --assignee-principal-type User --role Reader --scope /subscriptions/$sub"))
        $results[0].remediation | Should -Match ([regex]::Escape("--assignee-object-id $script:presenterB --assignee-principal-type User --role Reader"))
        $results[1].remediation | Should -Match ([regex]::Escape("az role assignment create --subscription $sub --assignee-object-id $script:presenterA --assignee-principal-type User --role `"$script:arcRole`" --scope /subscriptions/$sub/resourceGroups/rg-dbhub-demo"))
        $results[1].target | Should -Be 'T2'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'is Not selected without presenters, and Not supported for the Arc role in Developer mode' {
        Initialize-RbacMock
        $config['presenterObjectIds'] = @()
        $config['assignRoles'] = $true
        @(Set-DemoPresenterAccess -Config $config) | ForEach-Object { $_.status | Should -Be 'Not selected' }
        $config['presenterObjectIds'] = @($script:presenterA)
        $config['assignRoles'] = $false
        $config['t2SqlInstallMode'] = 'Developer'
        @(Set-DemoPresenterAccess -Config $config)[1].status | Should -Be 'Not supported'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'resolves each role by name and assigns it with the Azure CLI when assignRoles is true' {
        Initialize-RbacMock
        $config['assignRoles'] = $true
        $results = @(Set-DemoPresenterAccess -Config $config -Confirm:$false)
        $results | ForEach-Object { $_.status | Should -Be 'Pass' }
        $results[0].evidence.assignments[$script:presenterA] | Should -Be 'created'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -like "role definition list --name Reader --scope /subscriptions/$($script:HubSubscriptionId) *" }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -like "role definition list --name $script:arcRole --scope /subscriptions/$($script:HubSubscriptionId)/resourceGroups/rg-dbhub-demo *" }
        $script:rbacCreates.Count | Should -Be 4
        $script:rbacCreates[0] | Should -BeLike "role assignment create --assignee-object-id $script:presenterA --assignee-principal-type User --role $($script:roleIds['Reader']) --scope /subscriptions/$($script:HubSubscriptionId) --subscription *"
        $script:rbacCreates[2] | Should -BeLike "role assignment create --assignee-object-id $script:presenterA --assignee-principal-type User --role $($script:roleIds[$script:arcRole]) --scope /subscriptions/$($script:HubSubscriptionId)/resourceGroups/rg-dbhub-demo *"
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { ($ArgumentList -join ' ') -match '--assignee |ad sp|ad user|ad group' }
    }

    It 'skips presenters who already hold the role and treats RoleAssignmentExists as success' {
        Initialize-RbacMock -Existing $script:presenterA -CreateError 'ERROR: (RoleAssignmentExists) The role assignment already exists.'
        $config['assignRoles'] = $true
        $results = @(Set-DemoPresenterAccess -Config $config -Confirm:$false)
        $results | ForEach-Object { $_.status | Should -Be 'Pass' }
        $results[0].evidence.assignments[$script:presenterA] | Should -Be 'existing'
        $results[0].evidence.assignments[$script:presenterB] | Should -Be 'existing'
        $script:rbacCreates.Count | Should -Be 2
    }

    It 'fails with the administrator commands when a create fails' {
        Initialize-RbacMock -CreateError 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.'
        $config['assignRoles'] = $true
        $result = @(Set-DemoPresenterAccess -Config $config -Confirm:$false)[0]
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'AuthorizationFailed'
        $result.remediation | Should -Match 'az role assignment create'
    }

    It 'fails without role-assignment rights, and when a role can''t be found by name, before creating anything' {
        Initialize-RbacMock -Actions 'Microsoft.Resources/*'
        $config['assignRoles'] = $true
        $results = @(Set-DemoPresenterAccess -Config $config -Confirm:$false)
        $results | ForEach-Object { $_.status | Should -Be 'Fail' }
        $results[0].remediation | Should -Match 'assignRoles to false'
        $script:rbacCreates.Count | Should -Be 0

        Initialize-RbacMock -MissingRole $script:arcRole
        $missing = @(Set-DemoPresenterAccess -Config $config -Confirm:$false)
        $missing[0].status | Should -Be 'Pass'
        $missing[1].status | Should -Be 'Fail'
        $missing[1].message | Should -Match 'wasn''t found by name'
    }

    It 'creates nothing with -WhatIf' {
        Initialize-RbacMock
        $config['assignRoles'] = $true
        $results = @(Set-DemoPresenterAccess -Config $config -WhatIf)
        $results | ForEach-Object { $_.status | Should -Be 'Not selected'; $_.message | Should -BeLike 'WhatIf:*' }
        $script:rbacCreates.Count | Should -Be 0
    }

    It 'never pins a role definition ID in the module' {
        $root = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo'
        foreach ($file in 'Public/Set-DemoPresenterAccess.ps1', 'Private/HubHelpers.ps1') {
            Get-Content -LiteralPath (Join-Path -Path $root -ChildPath $file) -Raw | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        }
    }
}

Describe 'Test-DemoFabricHubSetting (P4)' {
    BeforeEach {
        Clear-DemoSecret
        $config = Get-HubTestConfig
        $script:token = Get-HubFakeToken
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'P4 makes no Azure CLI call of its own' }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:title = 'Users can access the Database hub (preview)'
        function Set-SettingPage([object[]] $Page) {
            $script:settingPages = $Page
            Initialize-HubFabricMock -Token $script:token -Handler {
                $index = if ($script:HubFabricRequest.Uri -match 'continuationToken=page2') { 1 } else { 0 }
                ConvertTo-HubFabricResponse -Body $script:settingPages[$index]
            }
        }
    }

    It 'asks for the manual check, with the portal steps, without calling anything unless -FabricAdmin' {
        Initialize-HubFabricMock -Handler { throw 'must not be called' }
        $result = Test-DemoFabricHubSetting -Config $config
        $result.checkId | Should -Be 'FABRIC.P4.HUBSETTING'
        $result.status | Should -Be 'Manual action required'
        $result.remediation | Should -Match ([regex]::Escape($script:title))
        $result.remediation | Should -Match 'Tenant settings'
        $result.remediation | Should -Match '-FabricAdmin'
        $script:HubFabricCalls.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 0
    }

    It 'passes when the setting is enabled for the organization, reading every page with the Phase 12 token' {
        Set-SettingPage @(
            @{ value = @(@{ settingName = 'Other'; title = 'Something else'; enabled = $true }); continuationUri = 'https://api.fabric.microsoft.com/v1/admin/tenantsettings?continuationToken=page2'; continuationToken = 'page2' }
            @{ value = @(@{ settingName = 'HubSetting'; title = $script:title; enabled = $true; tenantSettingGroup = 'Database hub' }) }
        )
        $result = Test-DemoFabricHubSetting -Config $config -FabricAdmin
        $result.status | Should -Be 'Pass'
        $result.evidence.settingName | Should -Be 'HubSetting'
        $result.evidence.pages | Should -Be 2
        $result.evidence.complete | Should -BeTrue
        $script:HubFabricCalls[0].Method | Should -Be 'Get'
        $script:HubFabricCalls[0].Uri | Should -Be 'https://api.fabric.microsoft.com/v1/admin/tenantsettings'
        $script:HubFabricCalls[1].Uri | Should -Be 'https://api.fabric.microsoft.com/v1/admin/tenantsettings?continuationToken=page2'
        $script:HubFabricCalls[0].Token | Should -Be $script:token
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:HubSubscriptionId }
        ($result | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($script:token))
    }

    It 'uses a token the operator passes instead of the Azure CLI, and follows continuationToken' {
        Set-SettingPage @(
            @{ value = @(); continuationToken = 'page2' }
            @{ value = @(@{ settingName = 'HubSetting'; title = $script:title; enabled = $true }) }
        )
        $passed = Get-HubFakeToken
        $result = Test-DemoFabricHubSetting -Config $config -FabricAdmin -Token (ConvertTo-HubSecureString $passed)
        $result.status | Should -Be 'Pass'
        $script:HubFabricCalls[1].Uri | Should -Be 'https://api.fabric.microsoft.com/v1/admin/tenantsettings?continuationToken=page2'
        $script:HubFabricCalls | ForEach-Object { $_.Token | Should -Be $passed }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 0
    }

    It 'warns when only security groups have it, and asks for action when it''s disabled or missing' {
        Set-SettingPage @(@{ value = @(@{ settingName = 'HubSetting'; title = $script:title; enabled = $true; enabledSecurityGroups = @(@{ graphId = '99999999-9999-9999-9999-999999999999'; name = 'sg-presenters' }) }) })
        $grouped = Test-DemoFabricHubSetting -Config $config -FabricAdmin
        $grouped.status | Should -Be 'Warning'
        $grouped.message | Should -Match 'sg-presenters'

        Set-SettingPage @(@{ value = @(@{ settingName = 'HubSetting'; title = $script:title; enabled = $false }) })
        (Test-DemoFabricHubSetting -Config $config -FabricAdmin).status | Should -Be 'Manual action required'

        Set-SettingPage @(@{ value = @(@{ settingName = 'X'; title = 'Database Hub insights (preview)'; enabled = $true }) })
        $missing = Test-DemoFabricHubSetting -Config $config -FabricAdmin
        $missing.status | Should -Be 'Manual action required'
        $missing.evidence.similarTitles | Should -Contain 'Database Hub insights (preview)'
    }

    It 'asks for the manual check when the admin API refuses the caller' {
        Initialize-HubFabricMock -Handler { ConvertTo-HubFabricResponse -StatusCode 403 -Body @{ errorCode = 'Forbidden'; message = 'The caller is not a Fabric administrator' } }
        $result = Test-DemoFabricHubSetting -Config $config -FabricAdmin
        $result.status | Should -Be 'Manual action required'
        $result.message | Should -Match 'Fabric administrator'
        $result.message | Should -Match 'HTTP 403: Forbidden'
        $result.evidence.statusCode | Should -Be 403
    }

    It 'asks for the manual check without a token, after a network error, or without the Phase 12 helpers' {
        Initialize-HubFabricMock -TokenFails -Handler { throw 'must not be called' }
        $noToken = Test-DemoFabricHubSetting -Config $config -FabricAdmin
        $noToken.status | Should -Be 'Manual action required'
        $noToken.message | Should -Match 'No Fabric token'
        $script:HubFabricCalls.Count | Should -Be 0

        Initialize-HubFabricMock -Handler { throw 'No such host is known.' }
        $network = Test-DemoFabricHubSetting -Config $config -FabricAdmin
        $network.status | Should -Be 'Manual action required'
        $network.message | Should -Match 'No such host'
        $network.evidence.statusCode | Should -Be 0

        Initialize-HubFabricMock -Handler { throw 'must not be called' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubFabricRest -MockWith { $false }
        $missing = Test-DemoFabricHubSetting -Config $config -FabricAdmin
        $missing.status | Should -Be 'Manual action required'
        $missing.message | Should -Match 'Phase 12'
        $script:HubFabricCalls.Count | Should -Be 0
        # Mocks keep their call history within a test: only the first two cases asked for a token.
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 2 -Exactly
    }

    It 'never follows a continuation link to another host' {
        Set-SettingPage @(@{ value = @(); continuationUri = 'https://example.invalid/v1/admin/tenantsettings?continuationToken=x' })
        $result = Test-DemoFabricHubSetting -Config $config -FabricAdmin
        $result.status | Should -Be 'Manual action required'
        $result.evidence.complete | Should -BeFalse
        $script:HubFabricCalls.Count | Should -Be 1
    }

    It 'matches the settingName once config/versions.json records it' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoHubSetting -MockWith {
            $versions = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
            $hub = $versions['databaseHub']
            $hub['fabric']['hubTenantSetting']['settingName'] = 'DatabaseHubTenant'
            $hub
        }
        Set-SettingPage @(@{ value = @(@{ settingName = 'DatabaseHubTenant'; title = 'Renamed in the portal'; enabled = $true }) })
        (Test-DemoFabricHubSetting -Config $config -FabricAdmin).status | Should -Be 'Pass'
    }
}

Describe 'Test-DemoFabricWorkspace (P5 and capacity)' {
    BeforeEach {
        Clear-DemoSecret
        $config = Get-HubTestConfig
        $script:workspaceId = $config['fabric']['workspaceId']
        $script:token = Get-HubFakeToken
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'P5 makes no Azure CLI call of its own' }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        function Set-FabricState([int] $WorkspaceStatus = 200, [string] $CapacityId = '33333333-3333-3333-3333-333333333333', [string] $Progress = 'Completed', [bool] $Contributor = $true, [string] $Sku = 'F2', [string] $State = 'Active', [bool] $CapacityVisible = $true, [switch] $TokenFails) {
            $script:fabricState = @{ WorkspaceStatus = $WorkspaceStatus; CapacityId = $CapacityId; Progress = $Progress; Contributor = $Contributor; Sku = $Sku; State = $State; CapacityVisible = $CapacityVisible }
            Initialize-HubFabricMock -Token $script:token -TokenFails:$TokenFails -Handler {
                $Uri = $script:HubFabricRequest.Uri
                $s = $script:fabricState
                if ($Uri -like '*/workspaces/*') {
                    if ($s.WorkspaceStatus -ne 200) { return ConvertTo-HubFabricResponse -StatusCode $s.WorkspaceStatus -Body @{ errorCode = 'WorkspaceNotFound'; message = 'not found' } }
                    $workspace = @{ id = $script:workspaceId; displayName = 'DbHub demo'; type = 'Workspace'; capacityRegion = 'West US 3' }
                    if ($s.CapacityId) { $workspace['capacityId'] = $s.CapacityId; $workspace['capacityAssignmentProgress'] = $s.Progress }
                    return ConvertTo-HubFabricResponse -Body $workspace
                }
                if ($Uri -like '*/workspaces?roles=*') {
                    $items = if ($s.Contributor) { @(@{ id = $script:workspaceId; displayName = 'DbHub demo' }) } else { @() }
                    return ConvertTo-HubFabricResponse -Body @{ value = $items }
                }
                $capacities = if ($s.CapacityVisible) { @(@{ id = $s.CapacityId; displayName = 'Demo capacity'; sku = $s.Sku; region = 'West US 3'; state = $s.State }) } else { @() }
                ConvertTo-HubFabricResponse -Body @{ value = $capacities }
            }
        }
    }

    It 'passes with Contributor or higher on a workspace on an Active F capacity' {
        Set-FabricState
        $results = @(Test-DemoFabricWorkspace -Config $config)
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('FABRIC.P5.WORKSPACE', 'FABRIC.P5.CAPACITY')
        $results | ForEach-Object { $_.status | Should -Be 'Pass' }
        $results[1].evidence.sku | Should -Be 'F2'
        $script:HubFabricCalls[0].Uri | Should -Be ('https://api.fabric.microsoft.com/v1/workspaces/{0}' -f $script:workspaceId)
        $script:HubFabricCalls[1].Uri | Should -Be 'https://api.fabric.microsoft.com/v1/workspaces?roles=Admin,Member,Contributor'
        $script:HubFabricCalls[2].Uri | Should -Be 'https://api.fabric.microsoft.com/v1/capacities'
        $script:HubFabricCalls | ForEach-Object { $_.Token | Should -Be $script:token }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 1 -Exactly
        ($results | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($script:token))
    }

    It 'reports <Name>' -ForEach @(
        @{ Name = 'a Viewer'; State = @{ Contributor = $false }; Workspace = 'Manual action required'; Capacity = 'Pass' }
        @{ Name = 'no capacity'; State = @{ CapacityId = '' }; Workspace = 'Pass'; Capacity = 'Manual action required' }
        @{ Name = 'a paused capacity'; State = @{ State = 'Inactive' }; Workspace = 'Pass'; Capacity = 'Manual action required' }
        @{ Name = 'a capacity SKU that isn''t verified (Trial)'; State = @{ Sku = 'FT1' }; Workspace = 'Pass'; Capacity = 'Manual action required' }
        @{ Name = 'a capacity you can''t see'; State = @{ CapacityVisible = $false }; Workspace = 'Pass'; Capacity = 'Warning' }
        @{ Name = 'an assignment in progress'; State = @{ Progress = 'InProgress' }; Workspace = 'Pass'; Capacity = 'Warning' }
        @{ Name = 'a workspace you can''t read'; State = @{ WorkspaceStatus = 404 }; Workspace = 'Manual action required'; Capacity = 'Manual action required' }
        @{ Name = 'no Fabric token'; State = @{ TokenFails = $true }; Workspace = 'Manual action required'; Capacity = 'Manual action required' }
    ) {
        Set-FabricState @State
        $results = @(Test-DemoFabricWorkspace -Config $config)
        $results[0].status | Should -Be $Workspace
        $results[1].status | Should -Be $Capacity
    }

    It 'uses a token the operator passes instead of the Azure CLI' {
        Set-FabricState
        $passed = Get-HubFakeToken
        $results = @(Test-DemoFabricWorkspace -Config $config -Token (ConvertTo-HubSecureString $passed))
        $results[0].status | Should -Be 'Pass'
        $script:HubFabricCalls | ForEach-Object { $_.Token | Should -Be $passed }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 0
    }

    It 'asks for the manual check without the Phase 12 helpers' {
        Set-FabricState
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubFabricRest -MockWith { $false }
        $results = @(Test-DemoFabricWorkspace -Config $config)
        $results | ForEach-Object { $_.status | Should -Be 'Manual action required' }
        $results[0].message | Should -Match 'Phase 12'
        $script:HubFabricCalls.Count | Should -Be 0
    }

    It 'is Not selected without a workspace' {
        Initialize-HubFabricMock -Handler { throw 'must not be called' }
        $config['fabric'].Remove('workspaceId')
        @(Test-DemoFabricWorkspace -Config $config) | ForEach-Object { $_.status | Should -Be 'Not selected' }
        $script:HubFabricCalls.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 0
    }
}
