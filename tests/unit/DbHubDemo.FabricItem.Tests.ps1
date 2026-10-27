BeforeAll {
    # Phase 18: Get-DemoFabricDashboardDefinition, Import-DemoFabricItem (with the Get Item Definition read-back),
    # Test-DemoFabricViewerLicense, and configure-fabric.ps1 -ImportDashboard. Every request is mocked; no test
    # touches the network, and every ID is an obvious placeholder.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    # The guard's unit-test hook (DbHubDemo.Guard.Helpers.ps1, through the Hub helpers): token requests need a
    # validated Azure CLI context, as after Assert-DemoAzContext.
    Initialize-GuardTestContext -SubscriptionId $script:HubSubscriptionId -TenantId $script:HubTenantId
    $script:configureFabric = Join-Path -Path $repoRoot -ChildPath 'scripts/configure-fabric.ps1'
    $script:api = 'https://api.fabric.microsoft.com/v1'
    $script:workspaceId = '11111111-1111-1111-1111-111111111111'
    $script:itemId = '22222222-2222-2222-2222-222222222222'
    $script:operationId = '33333333-3333-3333-3333-333333333333'
    $script:capacityId = '77777777-7777-7777-7777-777777777777'
    # Built at run time so secret scanners don't flag the fixture.
    $script:plainToken = 'ey' + 'J' + ('t' * 24) + '.' + 'ey' + 'J' + ('p' * 24) + '.' + ('s' * 24)

    function ConvertTo-TestSecureString([string] $Value) {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in $Value.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        return $secure
    }

    function New-FabricResponse([int] $Status, [object] $Body, [hashtable] $Headers = @{}) {
        $content = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { '' }
        [pscustomobject]@{ StatusCode = $Status; Headers = $Headers; Content = $content }
    }

    # Records every Invoke-WebRequest call and answers it from routes: @{ Method; Match (regex on the URI); Responses }.
    function Set-FabricMock([object[]] $Routes) {
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:routes = foreach ($route in $Routes) {
            [pscustomobject]@{ Method = $route.Method; Match = $route.Match; Responses = [System.Collections.Generic.Queue[object]]::new([object[]]$route.Responses) }
        }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $requests.Add([pscustomobject]@{
                    Method         = $Method
                    Uri            = [string]$Uri
                    Body           = Get-Variable -Name 'Body' -ValueOnly -ErrorAction Ignore
                    Authentication = Get-Variable -Name 'Authentication' -ValueOnly -ErrorAction Ignore
                    Token          = Get-Variable -Name 'Token' -ValueOnly -ErrorAction Ignore
                    Headers        = Get-Variable -Name 'Headers' -ValueOnly -ErrorAction Ignore
                })
            foreach ($route in $routes) {
                if ($route.Method -eq $Method -and [string]$Uri -match $route.Match) {
                    if ($route.Responses.Count -gt 1) { return $route.Responses.Dequeue() }
                    return $route.Responses.Peek()
                }
            }
            throw "Unexpected request: $Method $Uri"
        }
    }

    function Get-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = $script:HubSubscriptionId
        $config['tenantId'] = $script:HubTenantId
        $config['fabric']['workspaceId'] = $script:workspaceId
        return $config
    }

    function ConvertTo-ReadBackBody([string] $Json, [string] $Path = 'RealTimeDashboard.json') {
        @{ definition = @{ parts = @(@{ path = $Path; payload = [System.Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Json)); payloadType = 'InlineBase64' }) } }
    }

    $script:listUri = [regex]::Escape("$script:api/workspaces/$script:workspaceId/items?type=KQLDashboard")
    $script:createUri = '^' + [regex]::Escape("$script:api/workspaces/$script:workspaceId/items") + '$'
    $script:updateUri = '^' + [regex]::Escape("$script:api/workspaces/$script:workspaceId/items/$script:itemId/updateDefinition") + '$'
    $script:readUri = '^' + [regex]::Escape("$script:api/workspaces/$script:workspaceId/items/$script:itemId/getDefinition") + '$'
    $script:operationUri = '^' + [regex]::Escape("$script:api/operations/$script:operationId") + '$'
    $script:resultUri = '^' + [regex]::Escape("$script:api/operations/$script:operationId/result") + '$'
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoFabricDashboardDefinition' {
    It 'builds the documented definition: one RealTimeDashboard.json part, InlineBase64, with the resource group filled in' {
        $definition = Get-DemoFabricDashboardDefinition -Config (Get-TestConfig)
        $definition.PSObject.TypeNames | Should -Contain 'DbHubDemo.FabricItemDefinition'
        $definition.DisplayName | Should -Be 'RTD_DatabaseHub_LiveView'
        $definition.Type | Should -Be 'KQLDashboard'
        @($definition.Definition.Keys) | Should -Be @('parts')
        @($definition.Definition.parts).Count | Should -Be 1
        $definition.Definition.parts[0].path | Should -Be 'RealTimeDashboard.json'
        $definition.Definition.parts[0].payloadType | Should -Be 'InlineBase64'
        $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($definition.Definition.parts[0].payload))
        $text | Should -BeExactly $definition.Content
        $text | Should -Not -Match '\{\{'
        $text | Should -Match ([regex]::Escape("let _rg = 'rg-dbhub-demo';"))
        $definition.Sha256 | Should -Be ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant())
        $definition.Evidence.resourceGroup | Should -Be 'rg-dbhub-demo'
        $definition.Evidence.schemaVersion | Should -Be '52'
        $definition.Evidence.tiles | Should -BeGreaterThan 0
    }

    It 'uses the configured prefix and environment, or -ResourceGroup, and changes nothing else' {
        $config = Get-TestConfig
        $config['prefix'] = 'contoso'
        $config['environment'] = 'rehearsal'
        $fromConfig = Get-DemoFabricDashboardDefinition -Config $config
        $fromConfig.Content | Should -Match ([regex]::Escape("let _rg = 'rg-contoso-rehearsal';"))
        $explicit = Get-DemoFabricDashboardDefinition -ResourceGroup 'rg-contoso-rehearsal'
        $explicit.Content | Should -BeExactly $fromConfig.Content
        $template = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath 'fabric/realtime/RealTimeDashboard.json'))
        $explicit.Content | Should -BeExactly $template.Replace('{{ResourceGroup}}', "'rg-contoso-rehearsal'")
    }

    It 'refuses a resource group that could change the query' {
        { Get-DemoFabricDashboardDefinition -ResourceGroup "rg'x" } | Should -Throw
        $config = Get-TestConfig
        $config['environment'] = "demo' or 1==1"
        { Get-DemoFabricDashboardDefinition -Config $config } | Should -Throw '*valid resource group*'
    }

    It 'refuses a template that fails validation, such as one with a foreign ID' {
        $tampered = Join-Path -Path $TestDrive -ChildPath 'tampered.json'
        $text = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath 'fabric/realtime/RealTimeDashboard.json'))
        Set-Content -LiteralPath $tampered -Value $text.Replace('"Database Hub demo - live view"', '"Workspace 99999999-8888-7777-6666-555555555555"') -Encoding utf8NoBOM -NoNewline
        { Get-DemoFabricDashboardDefinition -ResourceGroup 'rg-dbhub-demo' -Path $tampered } | Should -Throw '*ID it doesn''t define*'
    }

    It 'writes the rendered JSON with -OutFile, for the portal''s Replace with file' {
        $out = Join-Path -Path $TestDrive -ChildPath 'RealTimeDashboard.json'
        $definition = Get-DemoFabricDashboardDefinition -ResourceGroup 'rg-dbhub-demo' -OutFile $out
        [System.IO.File]::ReadAllText($out) | Should -BeExactly $definition.Content
    }
}

Describe 'Import-DemoFabricItem with the Real-Time Dashboard' {
    BeforeAll {
        $script:secureToken = ConvertTo-TestSecureString -Value $script:plainToken
        $script:dashboard = Get-DemoFabricDashboardDefinition -ResourceGroup 'rg-dbhub-demo'
    }

    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
    }

    It 'sends nothing and needs no token with -WhatIf, and plans the read-back' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { throw 'no network calls expected' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        $result = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -ReadBack -WhatIf)
        $result.Count | Should -Be 1
        $result[0].status | Should -Be 'Not selected'
        $result[0].checkId | Should -Be 'FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW'
        ($result[0].evidence.plannedRequests -join ' ') | Should -Match ([regex]::Escape("$api/workspaces/$workspaceId/items?type=KQLDashboard"))
        ($result[0].evidence.plannedRequests -join ' ') | Should -Match 'getDefinition'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
    }

    It 'creates the KQLDashboard item with Create Item, then reads it back identical with Get Item Definition' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId; type = 'KQLDashboard'; displayName = 'RTD_DatabaseHub_LiveView' }) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 200 -Body (ConvertTo-ReadBackBody -Json $dashboard.Content)) }
        )
        $results = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -ReadBack -Confirm:$false)
        $results.checkId | Should -Be @('FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW', 'FABRIC.READBACK.RTD_DATABASEHUB_LIVEVIEW')
        $results.status | Should -Be @('Pass', 'Pass')
        $results[0].evidence.operation | Should -Be 'created'
        $results[1].evidence.identical | Should -BeTrue
        $results[1].message | Should -Match 'identical'
        $requests.Count | Should -Be 3
        $requests[0].Uri | Should -BeExactly "$api/workspaces/$workspaceId/items?type=KQLDashboard"
        $body = $requests[1].Body | ConvertFrom-Json -Depth 32
        $body.displayName | Should -Be 'RTD_DatabaseHub_LiveView'
        $body.type | Should -Be 'KQLDashboard'
        @($body.definition.parts).Count | Should -Be 1
        $body.definition.parts[0].path | Should -Be 'RealTimeDashboard.json'
        $body.definition.parts[0].payloadType | Should -Be 'InlineBase64'
        $body.definition.PSObject.Properties.Name | Should -Not -Contain 'format'
        $requests[2].Method | Should -Be 'Post'
        $requests[2].Uri | Should -BeExactly "$api/workspaces/$workspaceId/items/$itemId/getDefinition"
        $requests[2].Body | Should -BeNullOrEmpty
    }

    It 'updates an existing dashboard and follows a long-running read-back to its operation result' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'RTD_DatabaseHub_LiveView'; type = 'KQLDashboard' }) }) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ 'x-ms-operation-id' = @($operationId); 'Retry-After' = @('2') }) }
            @{ Method = 'Get'; Match = $operationUri; Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Succeeded' }) }
            @{ Method = 'Get'; Match = $resultUri; Responses = @(New-FabricResponse -Status 200 -Body (ConvertTo-ReadBackBody -Json $dashboard.Content)) }
        )
        $results = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -ReadBack -Confirm:$false)
        $results.status | Should -Be @('Pass', 'Pass')
        $results[0].evidence.operation | Should -Be 'updated'
        @(($requests[1].Body | ConvertFrom-Json).PSObject.Properties.Name) | Should -Be @('definition')
        @($requests | Where-Object { $_.Uri -match $resultUri }).Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 2 } -Times 1 -Exactly
    }

    It 'passes the round trip as identical in content when Fabric stores CRLF line endings, as it did live' {
        $stored = $dashboard.Content.TrimEnd("`n").Replace("`n", "`r`n")
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'RTD_DatabaseHub_LiveView' }) }) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 200 -Body (ConvertTo-ReadBackBody -Json $stored)) }
        )
        $read = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -ReadBack -Confirm:$false)[1]
        $read.status | Should -Be 'Pass'
        $read.evidence.identical | Should -BeTrue
        $read.evidence.byteIdentical | Should -BeFalse
        $read.evidence.readSha256 | Should -Not -Be $read.evidence.sentSha256
        $read.message | Should -Match 'identical to what was sent in content'
    }

    It 'passes the round trip when Fabric only normalizes fields such as the schema version, and lists them' {
        $normalized = $dashboard.Content | ConvertFrom-Json -AsHashtable -Depth 64
        $normalized['schema_version'] = '53'
        $normalized['id'] = $itemId
        $normalized['eTag'] = 'AAAA'
        $normalized['tiles'][0]['visualOptions']['extra'] = $true
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'RTD_DatabaseHub_LiveView' }) }) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 200 -Body (ConvertTo-ReadBackBody -Json ($normalized | ConvertTo-Json -Depth 64))) }
        )
        $read = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -ReadBack -Confirm:$false)[1]
        $read.status | Should -Be 'Pass'
        $read.evidence.identical | Should -BeFalse
        @($read.evidence.normalizedFields) | Should -Contain 'schema_version'
        @($read.evidence.normalizedFields) | Should -Contain 'eTag'
        @($read.evidence.normalizedFields) | Should -Contain 'tiles'
        $read.message | Should -Match 'normalized'
    }

    It 'fails the round trip when a tile or a query comes back changed or missing' {
        $broken = $dashboard.Content | ConvertFrom-Json -AsHashtable -Depth 64
        $broken['tiles'] = @($broken['tiles'] | Select-Object -Skip 1)
        $broken['queries'][0]['text'] = 'SqlServerCPUUtilization | take 1'
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'RTD_DatabaseHub_LiveView' }) }) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 200 -Body (ConvertTo-ReadBackBody -Json ($broken | ConvertTo-Json -Depth 64))) }
        )
        $read = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -ReadBack -Confirm:$false)[1]
        $read.status | Should -Be 'Fail'
        ($read.evidence.differences -join ' ') | Should -Match 'tiles .*: missing'
        ($read.evidence.differences -join ' ') | Should -Match 'queries .*: changed'
    }

    It 'fails the round trip when the part comes back under another path' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'RTD_DatabaseHub_LiveView' }) }) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 200 -Body (ConvertTo-ReadBackBody -Json $dashboard.Content -Path 'Other.json')) }
        )
        $read = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -ReadBack -Confirm:$false)[1]
        $read.status | Should -Be 'Fail'
        $read.message | Should -Match 'RealTimeDashboard\.json is missing'
    }

    It 'reports a read-back that can''t complete as a Warning, because the import succeeded' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'RTD_DatabaseHub_LiveView' }) }) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 403 -Body @{ errorCode = 'InsufficientPrivileges'; message = 'The caller does not have sufficient permissions.' }) }
        )
        $results = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -ReadBack -Confirm:$false)
        $results.status | Should -Be @('Pass', 'Warning')
        $results[1].message | Should -Match 'HTTP 403 InsufficientPrivileges'
    }

    It 'returns only the import record without -ReadBack' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
        )
        $results = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -Confirm:$false)
        $results.checkId | Should -Be @('FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW')
        @($requests | Where-Object { $_.Uri -like '*getDefinition*' }).Count | Should -Be 0
    }

    It 'sends the token only as a SecureString bearer token to the Fabric API, and never into a result' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 200 -Body (ConvertTo-ReadBackBody -Json $dashboard.Content)) }
        )
        $results = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -ReadBack -Confirm:$false)
        foreach ($request in $requests) {
            $request.Authentication | Should -Be 'Bearer'
            $request.Token | Should -BeOfType ([securestring])
            $request.Headers | Should -BeNullOrEmpty
            $request.Uri | Should -BeLike "$api/*"
        }
        ($results | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($plainToken))
    }

    It 'refuses to guess when two dashboards share the name' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'RTD_DatabaseHub_LiveView' }, @{ id = $operationId; displayName = 'RTD_DatabaseHub_LiveView' }) }) }
        )
        $result = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -ReadBack -Confirm:$false)
        $result.Count | Should -Be 1
        $result[0].status | Should -Be 'Fail'
        $result[0].message | Should -Match '2 Real-Time Dashboards named'
        @($requests | Where-Object { $_.Method -eq 'Post' }).Count | Should -Be 0
    }

    It 'reports a paused capacity as Manual action required with the resume steps, on <Operation>' -ForEach @(
        @{ Operation = 'create'; Existing = @() }
        @{ Operation = 'update'; Existing = @(@{ id = '22222222-2222-2222-2222-222222222222'; displayName = 'RTD_DatabaseHub_LiveView' }) }
    ) {
        # Phase 12's live finding: with a paused F capacity, List Items works and definition calls answer HTTP 404 CapacityNotActive.
        $paused = New-FabricResponse -Status 404 -Body @{ errorCode = 'CapacityNotActive'; message = 'Internal error CapacityNotActive.Capacity is not active'; isRetriable = $false }
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = $Existing }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @($paused) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @($paused) }
        )
        $result = @(Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token $secureToken -ReadBack -Confirm:$false)
        $result.Count | Should -Be 1
        $result[0].status | Should -Be 'Manual action required'
        $result[0].message | Should -Match 'HTTP 404 CapacityNotActive'
        $result[0].remediation | Should -Match 'Resume'
        $result[0].remediation | Should -Not -Match 'workspaceId'
        $result[0].docUrl | Should -Be 'https://learn.microsoft.com/fabric/enterprise/pause-resume'
        $result[0].evidence.httpStatus | Should -Be 404
        $requests.Count | Should -Be 2
        @($requests | Where-Object { $_.Uri -like '*getDefinition*' }).Count | Should -Be 0
    }
}

Describe 'Test-DemoFabricViewerLicense (PREFLIGHT.FABRIC.VIEWERLICENSE)' {
    BeforeEach {
        Clear-DemoSecret
        $script:capacitySku = 'F16'
        $script:capacityListed = $true
        Initialize-HubFabricMock -Handler {
            if ($script:HubFabricRequest.Uri -like '*/workspaces/*') {
                return ConvertTo-HubFabricResponse -Body @{ id = $script:workspaceId; displayName = 'Database Hub Demo'; capacityId = $script:capacityId }
            }
            if ($script:HubFabricRequest.Uri -like '*/capacities*') {
                $listed = @(if ($script:capacityListed) { @{ id = $script:capacityId; displayName = 'shared'; sku = $script:capacitySku; state = 'Active'; region = 'West US 3' } })
                return ConvertTo-HubFabricResponse -Body @{ value = $listed }
            }
            throw ('unexpected request: {0}' -f $script:HubFabricRequest.Uri)
        }
    }

    It 'reports <Sku> as <Status>' -ForEach @(
        @{ Sku = 'F2'; Status = 'Warning'; NeedsPro = $true }
        @{ Sku = 'F16'; Status = 'Warning'; NeedsPro = $true }
        @{ Sku = 'F32'; Status = 'Warning'; NeedsPro = $true }
        @{ Sku = 'F64'; Status = 'Pass'; NeedsPro = $false }
        @{ Sku = 'F128'; Status = 'Pass'; NeedsPro = $false }
        @{ Sku = 'P1'; Status = 'Pass'; NeedsPro = $false }
        @{ Sku = 'A2'; Status = 'Warning'; NeedsPro = $true }
        @{ Sku = 'FT1'; Status = 'Warning'; NeedsPro = $null }
    ) {
        $script:capacitySku = $Sku
        $result = Test-DemoFabricViewerLicense -Config (Get-TestConfig)
        $result.checkId | Should -Be 'PREFLIGHT.FABRIC.VIEWERLICENSE'
        $result.area | Should -Be 'preflight'
        $result.status | Should -Be $Status
        $result.evidence.sku | Should -Be $Sku
        $result.evidence.viewersNeedProOrPpu | Should -Be $NeedsPro
        $result.docUrl | Should -Be 'https://learn.microsoft.com/fabric/enterprise/licenses'
        if ($Status -eq 'Warning') {
            $result.message | Should -Match 'Pro, PPU, or (an )?individual trial'
            $result.remediation | Should -Match 'P11'
            $result.remediation | Should -Match 'sharing your screen'
        }
    }

    It 'reads the SKU with Get Workspace and List Capacities only, with the operator''s token' {
        $passed = Get-HubFakeToken
        $null = Test-DemoFabricViewerLicense -Config (Get-TestConfig) -Token (ConvertTo-HubSecureString $passed)
        @($script:HubFabricCalls | ForEach-Object { '{0} {1}' -f $_.Method, $_.Uri }) | Should -Be @("Get $api/workspaces/$workspaceId", "Get $api/capacities")
        @($script:HubFabricCalls | Where-Object { $_.Token -ne $passed }).Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 0
    }

    It 'is a Warning, never a Fail, when the SKU can''t be read' {
        $script:capacityListed = $false
        $result = Test-DemoFabricViewerLicense -Config (Get-TestConfig)
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'couldn''t be read'
        $result.message | Should -Match 'administer or contribute to'
    }

    It 'is a Warning without a Fabric token, and sends nothing' {
        Initialize-HubFabricMock -TokenFails -Handler { throw 'no Fabric request expected' }
        $result = Test-DemoFabricViewerLicense -Config (Get-TestConfig)
        $result.status | Should -Be 'Warning'
        $script:HubFabricCalls.Count | Should -Be 0
    }

    It 'reuses the SKU from FABRIC.P5.CAPACITY and sends no request' {
        $capacity = New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'capacity' -Evidence @{ capacityId = $capacityId; sku = 'F64'; state = 'Active' }
        $result = Test-DemoFabricViewerLicense -Config (Get-TestConfig) -CapacityResult $capacity
        $result.status | Should -Be 'Pass'
        $result.evidence.skuSource | Should -Be 'FABRIC.P5.CAPACITY'
        $script:HubFabricCalls.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 0

        $unknown = New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'The SKU could not be read.' -Evidence @{ capacityId = $capacityId }
        $result = Test-DemoFabricViewerLicense -Config (Get-TestConfig) -CapacityResult $unknown
        $result.status | Should -Be 'Warning'
        $script:HubFabricCalls.Count | Should -Be 0
    }

    It 'is Not selected without a configured workspace, and sends nothing' {
        $config = Get-TestConfig
        $config['fabric'].Remove('workspaceId')
        (Test-DemoFabricViewerLicense -Config $config).status | Should -Be 'Not selected'
        $script:HubFabricCalls.Count | Should -Be 0
    }
}

Describe 'configure-fabric.ps1 -ImportDashboard' {
    BeforeAll {
        $config = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $config.Remove('$schema')
        $config['subscriptionId'] = $script:HubSubscriptionId
        $config['tenantId'] = $script:HubTenantId
        $config['fabric']['workspaceId'] = $script:workspaceId
        $script:configPath = Join-Path -Path $TestDrive -ChildPath 'demo.config.json'
        Set-Content -LiteralPath $script:configPath -Value ($config | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        $config['fabric'].Remove('workspaceId')
        $script:noWorkspacePath = Join-Path -Path $TestDrive -ChildPath 'no-workspace.config.json'
        Set-Content -LiteralPath $script:noWorkspacePath -Value ($config | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        $script:outputPath = Join-Path -Path $TestDrive -ChildPath 'configure-fabric.jsonl'
        $script:rendered = (Get-DemoFabricDashboardDefinition -ResourceGroup 'rg-dbhub-demo').Content

        # Step 0 (Phase 26a) adds FABRIC.RESOLVE.* records first; DbHubDemo.FabricResolve.Tests covers them.
        function Read-DashboardResult {
            @(Get-Content -LiteralPath $outputPath | ConvertFrom-Json | Where-Object { $_.checkId -notlike 'FABRIC.RESOLVE.*' })
        }
    }

    BeforeEach {
        Clear-DemoSecret
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
        # Step 4 (the tile data check) has its own tests in DbHubDemo.DashboardData.Tests.ps1.
        Mock -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'guard' }
        Mock -CommandName Test-DemoRealTimeDashboardData -MockWith { New-DemoResult -CheckId 'FABRIC.DASHBOARD.DATA' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'tiles' }
    }

    It 'plans the dashboard import and read-back under -WhatIf without a token or any call' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { throw 'no network calls expected' }
        $null = & $configureFabric -ConfigPath $configPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -ImportDashboard -WhatIf *>&1
        $LASTEXITCODE | Should -Be 0
        $results = Read-DashboardResult
        $results.checkId | Should -Be @('FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW', 'FABRIC.DASHBOARD.DATA')
        $results.status | Should -Be @('Not selected', 'Not selected')
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -CommandName Test-DemoRealTimeDashboardData -Times 0 -Exactly
    }

    It 'imports the dashboard with the passed token, reads it back, checks its tiles after the guard, and exits 0' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 200 -Body (ConvertTo-ReadBackBody -Json $rendered)) }
        )
        $output = & $configureFabric -ConfigPath $configPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -ImportDashboard -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $results = Read-DashboardResult
        $results.checkId | Should -Be @('FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW', 'FABRIC.READBACK.RTD_DATABASEHUB_LIVEVIEW', 'PREFLIGHT.GUARD.CONTEXT', 'FABRIC.DASHBOARD.DATA')
        $results.status | Should -Be @('Pass', 'Pass', 'Pass', 'Pass')
        Should -Invoke -CommandName Test-DemoRealTimeDashboardData -Times 1 -Exactly
        $output | Should -Not -Match ([regex]::Escape($plainToken))
        ((Get-Content -LiteralPath $outputPath -Raw)) | Should -Not -Match ([regex]::Escape($plainToken))
    }

    It 'skips the tile check with -SkipDashboardDataCheck, and when the read-back doesn''t pass' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 200 -Body (ConvertTo-ReadBackBody -Json $rendered)) }
        )
        $null = & $configureFabric -ConfigPath $configPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -ImportDashboard -SkipDashboardDataCheck -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        (Read-DashboardResult).checkId | Should -Be @('FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW', 'FABRIC.READBACK.RTD_DATABASEHUB_LIVEVIEW')

        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
            @{ Method = 'Post'; Match = $readUri; Responses = @(New-FabricResponse -Status 200 -Body (ConvertTo-ReadBackBody -Json $rendered -Path 'Other.json')) }
        )
        $null = & $configureFabric -ConfigPath $configPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -ImportDashboard -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        $results = Read-DashboardResult
        $results.checkId | Should -Be @('FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW', 'FABRIC.READBACK.RTD_DATABASEHUB_LIVEVIEW', 'FABRIC.DASHBOARD.DATA')
        $results.status | Should -Be @('Pass', 'Fail', 'Not selected')
        Should -Invoke -CommandName Test-DemoRealTimeDashboardData -Times 0 -Exactly
    }

    It 'reports the dashboard import as Not selected without a workspace' {
        # No token here, so the workspace can't be looked up by name: step 0 says so, and nothing is imported.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Mock -CommandName Get-DemoFabricToken -MockWith { throw 'no token in this test' }
        $null = & $configureFabric -ConfigPath $noWorkspacePath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -ImportDashboard -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        (@(Get-Content -LiteralPath $outputPath | ConvertFrom-Json) | Where-Object checkId -EQ 'FABRIC.RESOLVE.WORKSPACE').status | Should -Be 'Manual action required'
        $results = Read-DashboardResult
        $results.checkId | Should -Be @('FABRIC.DASHBOARD.IMPORT', 'FABRIC.DASHBOARD.DATA')
        $results.status | Should -Be @('Not selected', 'Not selected')
    }

    It 'leaves the dashboard alone without -ImportDashboard' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { throw 'no network calls expected' }
        $null = & $configureFabric -ConfigPath $configPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        @(Get-Content -LiteralPath $outputPath | Where-Object { $_ }).Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 0 -Exactly
    }
}
