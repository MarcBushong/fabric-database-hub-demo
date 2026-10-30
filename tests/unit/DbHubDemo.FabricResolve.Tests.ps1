BeforeAll {
    # Phase 26a (ADR 0021): the Fabric workspace and lakehouse by name. Every request is mocked: Invoke-WebRequest
    # answers from a route table, and Start-Sleep returns at once. No test reaches a real API.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    $script:api = 'https://api.fabric.microsoft.com/v1'

    # Obviously fake IDs: every group repeats one character.
    $script:subscriptionId = '44444444-4444-4444-4444-444444444444'
    $script:workspaceId = '11111111-1111-1111-1111-111111111111'
    $script:lakehouseId = '22222222-2222-2222-2222-222222222222'
    $script:capacityId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
    $script:otherCapacityId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
    $script:operationId = '33333333-3333-3333-3333-333333333333'
    # Built at run time so secret scanners don't flag the fixture.
    $script:plainToken = 'ey' + 'J' + ('t' * 24) + '.' + 'ey' + 'J' + ('p' * 24) + '.' + ('s' * 24)

    function ConvertTo-TestSecureString {
        param([string] $Value)
        $secure = [System.Security.SecureString]::new()
        foreach ($character in $Value.ToCharArray()) {
            $secure.AppendChar($character)
        }
        $secure.MakeReadOnly()
        return $secure
    }
    $script:token = ConvertTo-TestSecureString -Value $plainToken

    function New-FabricResponse {
        param([int] $Status, [object] $Body, [hashtable] $Headers = @{})
        $content = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { '' }
        [pscustomobject]@{ StatusCode = $Status; Headers = $Headers; Content = $content }
    }

    # Records every Invoke-WebRequest call and answers it from $routes: @{ Method; Match (regex on the URI);
    # Responses (queue) }. The last response repeats. An unexpected request fails the test.
    function Set-FabricMock {
        param([object[]] $Routes)
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:routes = foreach ($route in $Routes) {
            [pscustomobject]@{ Method = $route.Method; Match = $route.Match; Responses = [System.Collections.Generic.Queue[object]]::new([object[]]$route.Responses) }
        }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $requests.Add([pscustomobject]@{ Method = $Method; Uri = [string]$Uri; Body = (Get-Variable -Name 'Body' -ValueOnly -ErrorAction Ignore) })
            foreach ($route in $routes) {
                if ($route.Method -eq $Method -and [string]$Uri -match $route.Match) {
                    if ($route.Responses.Count -gt 1) {
                        return $route.Responses.Dequeue()
                    }
                    return $route.Responses.Peek()
                }
            }
            throw "Unexpected request: $Method $Uri"
        }
    }

    function New-TestConfig {
        param([hashtable] $Fabric = @{})
        # PowerShell variable names ignore case, so the merged section has a name of its own.
        $section = @{ workspaceName = 'Database Hub Demo'; lakehouseName = 'LH_DatabaseHub'; capacityName = 'demo-capacity'; createIfMissing = $true; importNotebooks = $false }
        foreach ($key in @($Fabric.Keys)) {
            $section[$key] = $Fabric[$key]
        }
        @{ subscriptionId = $subscriptionId; tenantId = '55555555-5555-5555-5555-555555555555'; fabric = $section }
    }

    function Get-Record {
        param([object] $Resolution, [string] $CheckId)
        @($Resolution.Results | Where-Object { $_.checkId -eq $CheckId }) | Select-Object -First 1
    }

    $script:workspacesUri = '^' + [regex]::Escape("$api/workspaces") + '$'
    $script:workspaceUri = '^' + [regex]::Escape("$api/workspaces/$workspaceId") + '$'
    $script:lakehousesUri = '^' + [regex]::Escape("$api/workspaces/$workspaceId/lakehouses") + '$'
    $script:capacitiesUri = '^' + [regex]::Escape("$api/capacities") + '$'
    $script:assignUri = '^' + [regex]::Escape("$api/workspaces/$workspaceId/assignToCapacity") + '$'
    $script:operationUri = '^' + [regex]::Escape("$api/operations/$operationId") + '$'
    $script:demoWorkspace = @{ id = $workspaceId; displayName = 'Database Hub Demo'; type = 'Workspace'; capacityId = $capacityId }
    $script:activeCapacity = @{ id = $capacityId; displayName = 'demo-capacity'; sku = 'F4'; state = 'Active'; region = 'West US 3' }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoFabricResolveSetting' {
    It 'applies the defaults and treats the all-zero placeholder as no override' {
        InModuleScope DbHubDemo {
            $setting = Get-DemoFabricResolveSetting -Config @{ fabric = @{ workspaceId = '00000000-0000-0000-0000-000000000000' } }
            $setting.WorkspaceName | Should -Be 'Database Hub Demo'
            $setting.LakehouseName | Should -Be 'LH_DatabaseHub'
            $setting.CapacityName | Should -Be ''
            $setting.CreateIfMissing | Should -BeTrue
            $setting.WorkspaceId | Should -Be ''
            $setting.LakehouseId | Should -Be ''
        }
    }
}

Describe 'Resolve-DemoFabricConfig' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
    }

    It 'uses ID overrides as they are and sends nothing' {
        Set-FabricMock -Routes @()
        $config = New-TestConfig -Fabric @{ workspaceId = $workspaceId; lakehouseId = $lakehouseId }
        $resolution = Resolve-DemoFabricConfig -Config $config -Token $token -Create
        $resolution.Resolved | Should -BeTrue
        $resolution.Config.fabric.workspaceId | Should -Be $workspaceId
        $resolution.Config.fabric.lakehouseId | Should -Be $lakehouseId
        $resolution.Results.status | Should -Be @('Not selected', 'Not selected')
        $requests.Count | Should -Be 0
        # The caller's configuration is never changed.
        $config.fabric.workspaceId | Should -Be $workspaceId
    }

    It 'sends nothing in a dry run without a token, and says what it would look up' {
        Set-FabricMock -Routes @()
        $resolution = Resolve-DemoFabricConfig -Config (New-TestConfig) -Create -WhatIf
        $resolution.Resolved | Should -BeFalse
        (Get-Record $resolution 'FABRIC.RESOLVE.WORKSPACE').message | Should -Match '^Dry run: the workspace "Database Hub Demo" would be looked up by name, and created'
        $resolution.Config.fabric.ContainsKey('workspaceId') | Should -BeFalse
        $requests.Count | Should -Be 0
    }

    It 'is Manual action required without a Fabric token' {
        Set-FabricMock -Routes @()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoHubFabricAccess -MockWith { [pscustomobject]@{ Available = $true; Token = $null; Error = 'No Fabric token is available without interaction.' } }
        $resolution = Resolve-DemoFabricConfig -Config (New-TestConfig)
        $resolution.Results.status | Should -Be @('Manual action required', 'Manual action required')
        (Get-Record $resolution 'FABRIC.RESOLVE.WORKSPACE').remediation | Should -Match 'az login --tenant'
        $requests.Count | Should -Be 0
    }

    It 'finds the workspace and the lakehouse by name, skips personal workspaces, and names them without IDs' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(
                            @{ id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; displayName = 'Database Hub Demo'; type = 'Personal' }
                            @{ id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; displayName = 'Another workspace'; type = 'Workspace' }
                            $demoWorkspace
                        ); continuationToken = $null }) }
            @{ Method = 'Get'; Match = $lakehousesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $lakehouseId; displayName = 'LH_DatabaseHub'; type = 'Lakehouse' }) }) }
        )
        $resolution = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -Create
        $resolution.Resolved | Should -BeTrue
        $resolution.WorkspaceCreated | Should -BeFalse
        $resolution.LakehouseCreated | Should -BeFalse
        $resolution.Config.fabric.workspaceId | Should -Be $workspaceId
        $resolution.Config.fabric.lakehouseId | Should -Be $lakehouseId
        $resolution.Results.status | Should -Be @('Pass', 'Pass')
        foreach ($record in $resolution.Results) {
            $record.message | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-'
        }
        @($requests | Where-Object { $_.Method -ne 'Get' }).Count | Should -Be 0
    }

    It 'matches names that differ only in case, and refuses to pick between two matches' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(
                    New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $workspaceId; displayName = 'database hub demo'; type = 'Workspace'; capacityId = $capacityId }) }
                    New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $workspaceId; displayName = 'DATABASE HUB DEMO'; type = 'Workspace' }, @{ id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; displayName = 'database hub demo'; type = 'Workspace' }) }
                ) }
        )
        $found = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -SkipLakehouse
        $found.WorkspaceId | Should -Be $workspaceId
        $twice = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -SkipLakehouse
        $twice.WorkspaceId | Should -Be ''
        (Get-Record $twice 'FABRIC.RESOLVE.WORKSPACE').status | Should -Be 'Manual action required'
        (Get-Record $twice 'FABRIC.RESOLVE.WORKSPACE').message | Should -Match 'More than one workspace'
    }

    It 'is a Warning for a missing workspace when the caller only reads, and Manual action required when createIfMissing is false' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
        )
        $read = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token
        (Get-Record $read 'FABRIC.RESOLVE.WORKSPACE').status | Should -Be 'Warning'
        (Get-Record $read 'FABRIC.RESOLVE.WORKSPACE').remediation | Should -Match 'create the workspace'
        (Get-Record $read 'FABRIC.RESOLVE.LAKEHOUSE').status | Should -Be 'Not selected'
        $off = Resolve-DemoFabricConfig -Config (New-TestConfig -Fabric @{ createIfMissing = $false }) -Token $token -Create
        (Get-Record $off 'FABRIC.RESOLVE.WORKSPACE').status | Should -Be 'Manual action required'
        @($requests | Where-Object { $_.Method -ne 'Get' }).Count | Should -Be 0
    }

    It 'creates the missing workspace on the named Active capacity, then the lakehouse with lakehouse schemas' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $otherCapacityId; displayName = 'other'; sku = 'F2'; state = 'Active' }, $activeCapacity) }) }
            @{ Method = 'Post'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $workspaceId; displayName = 'Database Hub Demo'; type = 'Workspace' }) }
            @{ Method = 'Get'; Match = $workspaceUri; Responses = @(
                    New-FabricResponse -Status 200 -Body @{ id = $workspaceId; capacityId = $capacityId; capacityAssignmentProgress = 'InProgress' }
                    New-FabricResponse -Status 200 -Body @{ id = $workspaceId; capacityId = $capacityId; capacityAssignmentProgress = 'Completed' }
                ) }
            @{ Method = 'Get'; Match = $lakehousesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $lakehousesUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $lakehouseId; displayName = 'LH_DatabaseHub'; type = 'Lakehouse' }) }
        )
        $resolution = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -Create -Confirm:$false
        $resolution.Resolved | Should -BeTrue
        $resolution.WorkspaceCreated | Should -BeTrue
        $resolution.LakehouseCreated | Should -BeTrue
        $resolution.Results.status | Should -Be @('Pass', 'Pass')
        (Get-Record $resolution 'FABRIC.RESOLVE.WORKSPACE').message | Should -Be 'Created the Fabric workspace "Database Hub Demo" on the capacity "demo-capacity" (F4).'
        $createWorkspace = $requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -match $workspacesUri }
        ($createWorkspace.Body | ConvertFrom-Json).capacityId | Should -Be $capacityId
        ($createWorkspace.Body | ConvertFrom-Json).displayName | Should -Be 'Database Hub Demo'
        $createLakehouse = $requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -match $lakehousesUri }
        ($createLakehouse.Body | ConvertFrom-Json).creationPayload.enableSchemas | Should -BeTrue
        ($createLakehouse.Body | ConvertFrom-Json).displayName | Should -Be 'LH_DatabaseHub'
        # It never creates or changes a capacity: the only writes are the workspace and the lakehouse.
        @($requests | Where-Object { $_.Method -ne 'Get' }).Uri | Should -Be @("$api/workspaces", "$api/workspaces/$workspaceId/lakehouses")
    }

    It 'follows a lakehouse''s long-running creation and reads the new lakehouse back by name' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($demoWorkspace) }) }
            @{ Method = 'Get'; Match = $workspaceUri; Responses = @(New-FabricResponse -Status 200 -Body @{ id = $workspaceId; capacityId = $capacityId }) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($activeCapacity) }) }
            @{ Method = 'Get'; Match = $lakehousesUri; Responses = @(
                    New-FabricResponse -Status 200 -Body @{ value = @() }
                    New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $lakehouseId; displayName = 'LH_DatabaseHub' }) }
                ) }
            @{ Method = 'Post'; Match = $lakehousesUri; Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ 'x-ms-operation-id' = $operationId; 'Retry-After' = '1'; Location = "$api/operations/$operationId" }) }
            @{ Method = 'Get'; Match = $operationUri; Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Succeeded' }) }
        )
        $resolution = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -Create -Confirm:$false
        $resolution.LakehouseId | Should -Be $lakehouseId
        $resolution.LakehouseCreated | Should -BeTrue
        (Get-Record $resolution 'FABRIC.RESOLVE.LAKEHOUSE').status | Should -Be 'Pass'
    }

    It 'assigns a found workspace that has no capacity to the named capacity' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $workspaceId; displayName = 'Database Hub Demo'; type = 'Workspace' }) }) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($activeCapacity) }) }
            @{ Method = 'Post'; Match = $assignUri; Responses = @(New-FabricResponse -Status 202 -Body $null) }
            @{ Method = 'Get'; Match = $workspaceUri; Responses = @(New-FabricResponse -Status 200 -Body @{ id = $workspaceId; capacityId = $capacityId; capacityAssignmentProgress = 'Completed' }) }
        )
        $resolution = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -Create -SkipLakehouse -Confirm:$false
        (Get-Record $resolution 'FABRIC.RESOLVE.CAPACITY').status | Should -Be 'Pass'
        (($requests | Where-Object { $_.Uri -match $assignUri }).Body | ConvertFrom-Json).capacityId | Should -Be $capacityId
    }

    It 'creates nothing on a paused capacity, or without a capacity name, and lists the capacities you can assign' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $capacityId; displayName = 'demo-capacity'; sku = 'F4'; state = 'Inactive' }) }) }
        )
        $paused = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -Create -Confirm:$false
        (Get-Record $paused 'FABRIC.RESOLVE.WORKSPACE').status | Should -Be 'Manual action required'
        (Get-Record $paused 'FABRIC.RESOLVE.WORKSPACE').message | Should -Match 'is Inactive.*never resume, pause, or scale'
        $unnamed = Resolve-DemoFabricConfig -Config (New-TestConfig -Fabric @{ capacityName = '' }) -Token $token -Create -Confirm:$false
        (Get-Record $unnamed 'FABRIC.RESOLVE.WORKSPACE').message | Should -Match 'fabric\.capacityName isn''t set.*Capacities you can assign: demo-capacity'
        $missing = Resolve-DemoFabricConfig -Config (New-TestConfig -Fabric @{ capacityName = 'nope' }) -Token $token -Create -Confirm:$false
        (Get-Record $missing 'FABRIC.RESOLVE.WORKSPACE').message | Should -Match 'No capacity named "nope"'
        @($requests | Where-Object { $_.Method -ne 'Get' }).Count | Should -Be 0
    }

    It 'is Manual action required when the tenant doesn''t let you create workspaces, or the name is taken' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($activeCapacity) }) }
            @{ Method = 'Post'; Match = $workspacesUri; Responses = @(
                    New-FabricResponse -Status 403 -Body @{ errorCode = 'InsufficientPrivileges'; message = 'The caller does not have sufficient permissions.' }
                    New-FabricResponse -Status 409 -Body @{ errorCode = 'WorkspaceNameAlreadyExists'; message = 'The name is in use.' }
                ) }
        )
        $denied = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -Create -Confirm:$false
        (Get-Record $denied 'FABRIC.RESOLVE.WORKSPACE').status | Should -Be 'Manual action required'
        (Get-Record $denied 'FABRIC.RESOLVE.WORKSPACE').remediation | Should -Match 'Create workspaces'
        $taken = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -Create -Confirm:$false
        (Get-Record $taken 'FABRIC.RESOLVE.WORKSPACE').remediation | Should -Match 'already exists, and you can''t access it'
    }

    It 'finds by name the workspace its own create made, when the create sent again after a lost answer finds the name taken (Phase 28 live finding)' {
        # The first create reached Fabric, but its answer was lost (HTTP 502); Invoke-DemoTransientRetry sent it again.
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(
                    New-FabricResponse -Status 200 -Body @{ value = @() }
                    New-FabricResponse -Status 200 -Body @{ value = @($demoWorkspace) }
                ) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($activeCapacity) }) }
            @{ Method = 'Post'; Match = $workspacesUri; Responses = @(
                    New-FabricResponse -Status 502 -Body $null
                    New-FabricResponse -Status 409 -Body @{ errorCode = 'WorkspaceNameAlreadyExists'; message = 'The name is in use.' }
                ) }
        )
        $resolution = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -Create -SkipLakehouse -Confirm:$false
        $record = Get-Record $resolution 'FABRIC.RESOLVE.WORKSPACE'
        $record.status | Should -Be 'Pass'
        $record.message | Should -Match '^Found the Fabric workspace "Database Hub Demo" by name: its create said it already exists'
        $record.evidence.source | Should -Be 'name'
        $resolution.WorkspaceId | Should -Be $workspaceId
        @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -match $workspacesUri }).Count | Should -Be 2
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It 'is a Fail for an unexpected error' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 500 -Body @{ errorCode = 'UnknownError'; message = 'An error occurred.' }) }
        )
        $resolution = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -Create
        (Get-Record $resolution 'FABRIC.RESOLVE.WORKSPACE').status | Should -Be 'Fail'
    }

    It 'reads but creates nothing under -WhatIf with a token' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($activeCapacity) }) }
        )
        $resolution = Resolve-DemoFabricConfig -Config (New-TestConfig) -Token $token -Create -WhatIf
        (Get-Record $resolution 'FABRIC.RESOLVE.WORKSPACE').status | Should -Be 'Not selected'
        (Get-Record $resolution 'FABRIC.RESOLVE.WORKSPACE').message | Should -Match '^What if: the Fabric workspace "Database Hub Demo" would be created'
        @($requests | Where-Object { $_.Method -ne 'Get' }).Count | Should -Be 0
    }
}

Describe 'Test-DemoFabricResolution (preflight P5)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
    }

    It 'is a Warning naming the capacity when deploy.ps1 would create the workspace, since the tenant setting can''t be read' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($activeCapacity) }) }
        )
        $token = $script:token
        $check = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Token = $token } { Test-DemoFabricResolution -Config $Config -Token $Token }
        $check.Result.checkId | Should -Be 'PREFLIGHT.P5.WORKSPACE'
        $check.Result.status | Should -Be 'Warning'
        $check.Result.message | Should -Match 'deploy\.ps1 creates it.*"demo-capacity" \(F4\)'
        @($requests | Where-Object { $_.Method -ne 'Get' }).Count | Should -Be 0
    }

    It 'reports what blocks creating it' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
        )
        $token = $script:token
        $check = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Token = $token } { Test-DemoFabricResolution -Config $Config -Token $Token }
        $check.Result.status | Should -Be 'Manual action required'
        $check.Result.message | Should -Match 'can''t create it: No capacity named "demo-capacity"'
    }

    It 'checks your role and the capacity of a workspace it finds' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($demoWorkspace) }) }
            @{ Method = 'Get'; Match = $lakehousesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $lakehouseId; displayName = 'LH_DatabaseHub' }) }) }
            @{ Method = 'Get'; Match = $workspaceUri; Responses = @(New-FabricResponse -Status 200 -Body @{ id = $workspaceId; displayName = 'Database Hub Demo'; capacityId = $capacityId; capacityAssignmentProgress = 'Completed'; capacityRegion = 'West US 3' }) }
            @{ Method = 'Get'; Match = [regex]::Escape("$api/workspaces?roles=Admin,Member,Contributor"); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($demoWorkspace) }) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($activeCapacity) }) }
        )
        $token = $script:token
        $check = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Token = $token } { Test-DemoFabricResolution -Config $Config -Token $Token }
        $check.Result.status | Should -Be 'Pass'
        $check.Config.fabric.workspaceId | Should -Be $workspaceId
        $check.CapacityResult.checkId | Should -Be 'FABRIC.P5.CAPACITY'
    }
}

Describe 'Get-DemoFabricStatus (status.ps1)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
    }

    It 'passes with the capacity''s state, paused or not, and never changes it' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @($demoWorkspace) }) }
            @{ Method = 'Get'; Match = $lakehousesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $lakehouseId; displayName = 'LH_DatabaseHub' }) }) }
            @{ Method = 'Get'; Match = $workspaceUri; Responses = @(New-FabricResponse -Status 200 -Body @{ id = $workspaceId; displayName = 'Database Hub Demo'; capacityId = $capacityId }) }
            @{ Method = 'Get'; Match = $capacitiesUri; Responses = @(
                    New-FabricResponse -Status 200 -Body @{ value = @($activeCapacity) }
                    New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $capacityId; displayName = 'demo-capacity'; sku = 'F4'; state = 'Inactive' }) }
                ) }
        )
        $token = $script:token
        $active = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Token = $token } { Get-DemoFabricStatus -Config $Config -Token $Token }
        $active.checkId | Should -Be 'STATUS.FABRIC'
        $active.status | Should -Be 'Pass'
        $active.message | Should -Be 'Fabric: the workspace "Database Hub Demo" and the lakehouse "LH_DatabaseHub" are there; its capacity "demo-capacity" (F4) is Active.'
        $paused = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Token = $token } { Get-DemoFabricStatus -Config $Config -Token $Token }
        $paused.status | Should -Be 'Pass'
        $paused.message | Should -Match 'is Inactive: its administrator resumes it'
        @($requests | Where-Object { $_.Method -ne 'Get' }).Count | Should -Be 0
    }

    It 'is a Warning when the workspace doesn''t exist yet' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspacesUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
        )
        $token = $script:token
        $status = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Token = $token } { Get-DemoFabricStatus -Config $Config -Token $Token }
        $status.status | Should -Be 'Warning'
        $status.message | Should -Match 'doesn''t exist'
    }

    It 'is a Warning when an ID override points to a workspace that can''t be read' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $workspaceUri; Responses = @(New-FabricResponse -Status 404 -Body @{ errorCode = 'WorkspaceNotFound'; message = 'The requested workspace was not found.' }) }
        )
        $token = $script:token
        $config = New-TestConfig -Fabric @{ workspaceId = $workspaceId; lakehouseId = $lakehouseId }
        $status = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $token } { Get-DemoFabricStatus -Config $Config -Token $Token }
        $status.status | Should -Be 'Warning'
        $status.message | Should -Match 'couldn''t be read'
    }
}

Describe 'Import-DemoFabricItem -CreateOnly' {
    It 'leaves an item that exists as it is, with the note in its message' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $lakehouseId; displayName = 'NB_Test'; type = 'Notebook' }) }) }
        )
        $item = [pscustomobject]@{ PSTypeName = 'DbHubDemo.FabricItemDefinition'; DisplayName = 'NB_Test'; Type = 'Notebook'; Label = 'notebook'; Sha256 = ('ab' * 32); SizeBytes = 2; Definition = @{ format = 'ipynb'; parts = @() } }
        $result = Import-DemoFabricItem -WorkspaceId $workspaceId -Item $item -Token $token -CreateOnly -Note 'Updating it is opt-in.' -Confirm:$false
        $result.status | Should -Be 'Not selected'
        $result.message | Should -Match 'already there, so it was left as it is\. Updating it is opt-in\.$'
        $result.evidence.operation | Should -Be 'unchanged'
        @($requests | Where-Object { $_.Method -ne 'Get' }).Count | Should -Be 0
    }
}
