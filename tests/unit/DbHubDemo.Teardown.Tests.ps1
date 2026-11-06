BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    # Destroy writes (group and deployment deletes) need the context the subscription guard validates.
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        return $config
    }

    function New-AzResult([int] $ExitCode = 0, [string] $StdOut = '', [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
    }

    function New-GraphResult([object[]] $Rows = @(), [bool] $Succeeded = $true) {
        [pscustomobject]@{ Succeeded = $Succeeded; Error = $(if ($Succeeded) { '' } else { 'Forbidden' }); Rows = @($Rows); Truncated = $false }
    }

    function New-TestManifest {
        [pscustomobject]@{
            ResourceGroupName = 'rg-dbhub-demo'
            DeploymentId      = 'abc123'
            KeyVaultName      = ''
            Principals        = @(
                [pscustomobject]@{ Name = 'sqlvm01'; Type = 'microsoft.compute/virtualmachines'; PrincipalId = 'aaaaaaaa-1111-2222-3333-444444444444' }
                [pscustomobject]@{ Name = 'arcsql01'; Type = 'microsoft.hybridcompute/machines'; PrincipalId = 'bbbbbbbb-1111-2222-3333-444444444444' }
            )
        }
    }

    # An Azure Resource Manager error as Invoke-DemoRestRequest returns it.
    function New-ArmError([int] $Status = 404, [string] $Code = 'ResourceGroupNotFound') {
        [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('HTTP {0}: {{"error":{{"code":"{1}","message":"Not found in this test."}}}}' -f $Status, $Code); StatusCode = $Status }
    }

    $script:sub = '/subscriptions/11111111-2222-3333-4444-555555555555'
    $script:notFound = "ERROR: (ResourceGroupNotFound) Resource group 'rg-dbhub-demo' could not be found."
}

Describe 'Test-DemoAzNotFound' {
    It 'treats <_> as gone' -ForEach @(
        "ERROR: (ResourceGroupNotFound) Resource group 'rg-dbhub-demo' could not be found."
        "ERROR: (DeploymentNotFound) Deployment 'dbhub-demo-main' could not be found."
        'ERROR: Resource ''x'' does not exist or one of its queried reference-property objects are not present. Request_ResourceNotFound'
        '(ResourceNotFound) The Resource was not found.'
        '(ParentResourceNotFound) Failed to perform the operation.'
        'Operation returned an invalid status ''Not Found'''
        'HTTP (404)'
    ) {
        InModuleScope DbHubDemo -Parameters @{ Text = $_ } { Test-DemoAzNotFound -Text $Text } | Should -BeTrue
    }

    It 'doesn''t treat <_> as gone' -ForEach @(
        '(Conflict) Another operation is in progress.'
        '(AuthorizationFailed) The client does not have authorization.'
        "ERROR: (SubscriptionNotFound) The subscription '11111111-2222-3333-4444-555555555555' could not be found."
        "ERROR: Subscription '11111111-2222-3333-4444-555555555555' not found. Check the spelling and casing and try again."
        "ERROR: (ResourceGroupBeingDeleted) The resource group 'rg-dbhub-demo' is in deprovisioning state and cannot perform this operation."
        ''
    ) {
        InModuleScope DbHubDemo -Parameters @{ Text = $_ } { Test-DemoAzNotFound -Text $Text } | Should -BeFalse
    }

    It 'still treats a resource that isn''t found under a named subscription as gone' {
        InModuleScope DbHubDemo { Test-DemoAzNotFound -Text "(ResourceNotFound) The Resource 'Microsoft.HybridCompute/machines/arcsql01' under subscription '11111111-2222-3333-4444-555555555555' was not found." } | Should -BeTrue
    }
}

Describe 'Get-DemoTeardownManifest' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:groupExists = $true
        $script:queries = [System.Collections.Generic.List[string]]::new()
        $script:reachable = '11111111-2222-3333-4444-555555555555'
        Mock -ModuleName DbHubDemo -CommandName Test-DemoResourceGroupExist -MockWith { $script:groupExists }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ deploymentId = 'abc123' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHubResourceGraph -MockWith {
            $script:queries.Add($Query)
            if ($Query -match 'project subscriptionId$') {
                return (New-GraphResult -Rows @([pscustomobject]@{ subscriptionId = $script:reachable }))
            }
            New-GraphResult -Rows @(
                [pscustomobject]@{ name = 'sqlvm01'; type = 'microsoft.compute/virtualmachines'; principalId = 'AAAAAAAA-1111-2222-3333-444444444444' }
                [pscustomobject]@{ name = 'arcsql01'; type = 'microsoft.hybridcompute/machines'; principalId = 'bbbbbbbb-1111-2222-3333-444444444444' }
                [pscustomobject]@{ name = 'id-dbhub-demo-arc-onboard'; type = 'microsoft.managedidentity/userassignedidentities'; principalId = 'cccccccc-1111-2222-3333-444444444444' }
                [pscustomobject]@{ name = 'vnet-dbhub-demo'; type = 'microsoft.network/virtualnetworks'; principalId = '' }
            )
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { New-AzResult -ExitCode 3 -StdErr "ERROR: (DeploymentNotFound) Deployment 'dbhub-demo-main' could not be found." }
    }

    It 'reads the deploymentId tag and every identity in the group before the destroy' {
        $manifest = Get-DemoTeardownManifest -Config $config
        $manifest.DeploymentId | Should -Be 'abc123'
        $manifest.ResourceGroupName | Should -Be 'rg-dbhub-demo'
        $manifest.DeploymentName | Should -Be 'dbhub-demo-main'
        $manifest.BudgetName | Should -Be 'budget-dbhub-demo'
        $manifest.ResourceCount | Should -Be 4
        $manifest.IdentitiesRecorded | Should -BeTrue
        @($manifest.Principals).Count | Should -Be 3
        $manifest.Principals[0].PrincipalId | Should -Be 'aaaaaaaa-1111-2222-3333-444444444444'
        $script:queries[-1] | Should -Match "resourceGroup =~ 'rg-dbhub-demo'"
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
    }

    It 'records no identities, and says so, when Resource Graph doesn''t list the configured subscription for this sign-in' {
        $script:reachable = '99999999-2222-3333-4444-555555555555'
        $manifest = Get-DemoTeardownManifest -Config $config
        $manifest.IdentitiesRecorded | Should -BeFalse
        @($manifest.Principals).Count | Should -Be 0
        $manifest.Notes | Should -Match 'identities weren''t recorded: Azure Resource Graph doesn''t list the configured subscription'
        $script:queries | Should -Not -Match "resourceGroup =~ 'rg-dbhub-demo'"
    }

    It 'falls back to the subscription deployment''s output when the group is gone' {
        $script:groupExists = $false
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { New-AzResult -StdOut "def456`n" }
        $manifest = Get-DemoTeardownManifest -Config $config
        $manifest.DeploymentId | Should -Be 'def456'
        $manifest.IdentitiesRecorded | Should -BeFalse
        @($manifest.Principals).Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoHubResourceGraph -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '^deployment sub show --name dbhub-demo-main' }
    }

    It 'records an unknown deploymentId instead of guessing' {
        $script:groupExists = $false
        $manifest = Get-DemoTeardownManifest -Config $config
        $manifest.DeploymentId | Should -BeNullOrEmpty
        $manifest.Notes | Should -Match 'deploymentId is unknown'
    }
}

Describe 'Test-DemoTeardownResidue' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:queries = [System.Collections.Generic.List[string]]::new()
        $script:graph = @{}
        $script:az = @{}
        $script:pass = 0
        # Microsoft Graph through Invoke-DemoRestRequest: the tenant it answers for, the identities that still
        # exist, and those still in the P6 group.
        $script:rest = [System.Collections.Generic.List[string]]::new()
        $script:orgTenant = '66666666-7777-8888-9999-000000000000'
        $script:orgResult = $null
        $script:existing = @()
        $script:memberOf = @()
        # Azure Resource Manager's answers for the residual check's confirmations (Resources - Get By Id), by URL
        # pattern; anything else is returned (HTTP 200). Providers - Get lists API versions for types nothing pins.
        $script:arm = [ordered]@{}
        $script:providers = @{
            'Microsoft.AzureArcData' = @(@{ resourceType = 'sqlServerInstances/databases'; apiVersions = @('2027-01-01-preview', '2026-01-01', '2025-03-01') })
        }
        # The canaries: Resource Graph lists the configured subscription, and Microsoft Graph answers for its tenant.
        $script:graph['project subscriptionId$'] = New-GraphResult -Rows @([pscustomobject]@{ subscriptionId = '11111111-2222-3333-4444-555555555555' })
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $script:pass++ }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            # A GET has no -Body; under Set-StrictMode (the static run) an unbound variable can't be read.
            $requestBody = [string](Get-Variable -Name 'Body' -ValueOnly -ErrorAction Ignore)
            $script:rest.Add(('{0} {1} {2}' -f $Method, $Uri, $requestBody))
            $answer = { param([object] $Value) [pscustomobject]@{ ExitCode = 0; StdOut = (@{ value = @($Value) } | ConvertTo-Json -Depth 5); StdErr = ''; StatusCode = 200 } }
            if ($Uri -match '/v1\.0/organization') {
                if ($null -ne $script:orgResult) {
                    return $script:orgResult
                }
                return (& $answer @([pscustomobject]@{ id = $script:orgTenant }))
            }
            if ($Uri -match '/v1\.0/directoryObjects/getByIds$') {
                $ids = @(($requestBody | ConvertFrom-Json).ids)
                return (& $answer @($ids | Where-Object { $_ -in $script:existing } | ForEach-Object { [pscustomobject]@{ id = $_ } }))
            }
            if ($Uri -match '/v1\.0/directoryObjects/([0-9a-f-]{36})/checkMemberGroups$') {
                return (& $answer @(if ($Matches[1] -in $script:memberOf) { '77777777-7777-7777-7777-777777777777' }))
            }
            if ($Method -eq 'GET' -and $Uri -match '^https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/providers/([^/?]+)\?api-version=') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = (@{ namespace = $Matches[1]; resourceTypes = @($script:providers[$Matches[1]]) } | ConvertTo-Json -Depth 6); StdErr = ''; StatusCode = 200 }
            }
            if ($Method -eq 'GET' -and $Uri -match '^https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/') {
                foreach ($key in $script:arm.Keys) {
                    if ($Uri -match $key) {
                        return $script:arm[$key]
                    }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = ''; StatusCode = 200 }
            }
            throw ('Unexpected REST call: {0} {1}' -f $Method, $Uri)
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHubResourceGraph -MockWith {
            $script:queries.Add($Query)
            foreach ($key in $script:graph.Keys) {
                if ($Query -match $key) {
                    $value = $script:graph[$key]
                    if ($value -is [scriptblock]) {
                        return (& $value)
                    }
                    return $value
                }
            }
            New-GraphResult
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $text = $ArgumentList -join ' '
            foreach ($key in $script:az.Keys) {
                if ($text -match $key) {
                    return $script:az[$key]
                }
            }
            switch -Regex ($text) {
                '^group exists' { return (New-AzResult -StdOut "false`n") }
                '^deployment sub list' { return (New-AzResult -StdOut '["dbhub-other-main", "something-else"]') }
                '^rest --method get --url .*budgets' { return (New-AzResult -ExitCode 3 -StdErr $script:notFound) }
                default { return (New-AzResult) }
            }
        }
    }

    It 'passes every check when nothing is left' {
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        foreach ($name in 'RESOURCEGROUP', 'TAGGED', 'GROUPRESOURCES', 'ARC', 'ROLEASSIGNMENTS', 'IDENTITIES', 'DEPLOYMENTS', 'BUDGET', 'REFERENCES', 'RECORDS') {
            ($results | Where-Object { $_.checkId -eq "TEARDOWN.RESIDUAL.$name" }).status | Should -Be 'Pass' -Because $name
        }
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.KEYVAULT' }).status | Should -Be 'Not selected'
        $results.area | Select-Object -Unique | Should -Be 'teardown'
    }

    It 'fails each check that finds something, Arc resources included' {
        $script:az['^group exists'] = New-AzResult -StdOut "true`n"
        $script:az['^deployment sub list'] = New-AzResult -StdOut '["dbhub-demo-main"]'
        $script:az['budgets'] = New-AzResult -StdOut '{"name": "budget-dbhub-demo"}'
        $script:existing = @('aaaaaaaa-1111-2222-3333-444444444444')
        $script:memberOf = @('aaaaaaaa-1111-2222-3333-444444444444')
        $script:graph['microsoft.hybridcompute/machines'] = New-GraphResult -Rows @([pscustomobject]@{ id = '/subscriptions/x/resourceGroups/rg-dbhub-demo/providers/Microsoft.HybridCompute/machines/arcsql01' })
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        foreach ($name in 'RESOURCEGROUP', 'ARC', 'IDENTITIES', 'DEPLOYMENTS', 'BUDGET') {
            ($results | Where-Object { $_.checkId -eq "TEARDOWN.RESIDUAL.$name" }).status | Should -Be 'Fail' -Because $name
        }
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.ARC' }).target | Should -Be 'T2'
        $identities = $results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }
        $identities.evidence.remaining | Should -Contain 'aaaaaaaa-1111-2222-3333-444444444444'
        $identities.evidence.remaining | Should -Contain 'member of the P6 group: aaaaaaaa-1111-2222-3333-444444444444'
        $identities.evidence.remaining | Should -Not -Contain 'bbbbbbbb-1111-2222-3333-444444444444'
        # Only identities that still exist get a membership check.
        @($script:rest | Where-Object { $_ -match 'checkMemberGroups' -and $_ -notmatch 'aaaaaaaa-1111' }).Count | Should -Be 0
    }

    It 'keeps polling while Resource Graph and Entra catch up, then passes' {
        $script:graph['resourceGroup =~'] = { if ($script:pass -lt 2) { New-GraphResult -Rows @([pscustomobject]@{ id = '/subscriptions/x/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/networkInterfaces/nic-sqlvm01' }) } else { New-GraphResult } }
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 5 -PollSeconds 5)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.GROUPRESOURCES' }).status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly
    }

    It 'stops after the passes its wait allows, even when the waits return at once' {
        $script:az['^group exists'] = New-AzResult -StdOut "true`n"
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 1 -PollSeconds 30)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.RESOURCEGROUP' }).status | Should -Be 'Fail'
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.RESOURCEGROUP' }).evidence.passes | Should -Be 3
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly
    }

    It 'reports a check it can''t read as a Warning, never a Pass' {
        $script:graph['resourceGroup =~'] = New-GraphResult -Succeeded $false
        $script:az['^deployment sub list'] = New-AzResult -ExitCode 1 -StdErr '(AuthorizationFailed) no access'
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.GROUPRESOURCES' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.DEPLOYMENTS' }).status | Should -Be 'Warning'
    }

    It 'reports the Resource Graph and identity checks as Warnings, without waiting, when they don''t answer for the configured subscription and tenant' {
        # Resource Graph doesn't list the configured subscription, so its empty answers prove nothing, and
        # Microsoft Graph answers for another tenant, where "not found" would prove nothing either.
        $script:graph['project subscriptionId$'] = New-GraphResult -Rows @([pscustomobject]@{ subscriptionId = '99999999-2222-3333-4444-555555555555' })
        $script:orgTenant = '99999999-7777-8888-9999-000000000000'
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 5 -PollSeconds 5)
        foreach ($name in 'TAGGED', 'GROUPRESOURCES', 'ARC', 'ROLEASSIGNMENTS', 'IDENTITIES', 'REFERENCES', 'RECORDS') {
            ($results | Where-Object { $_.checkId -eq "TEARDOWN.RESIDUAL.$name" }).status | Should -Be 'Warning' -Because $name
        }
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.TAGGED' }).message | Should -Match 'doesn''t list the configured subscription'
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).message | Should -Match 'another tenant'
        # The checks that name the subscription still pass.
        foreach ($name in 'RESOURCEGROUP', 'DEPLOYMENTS', 'BUDGET') {
            ($results | Where-Object { $_.checkId -eq "TEARDOWN.RESIDUAL.$name" }).status | Should -Be 'Pass' -Because $name
        }
        @($script:rest | Where-Object { $_ -match 'getByIds|checkMemberGroups' }).Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'ad' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
        @($script:queries | Where-Object { $_ -notmatch 'project subscriptionId$' }).Count | Should -Be 0
    }

    It 'reports a Microsoft Graph call that fails or is refused as a Warning instead of throwing' {
        $script:orgResult = [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 403: Forbidden'; StatusCode = 403 }
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).message | Should -Match 'HTTP 403'
        $script:orgResult = $null
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith { throw 'refused' } -ParameterFilter { $Uri -match 'getByIds' }
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).message | Should -Match 'refused'
    }

    It 'never calls az ad or az rest for Microsoft Graph or Resource Graph' {
        $script:existing = @('aaaaaaaa-1111-2222-3333-444444444444')
        $null = Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'ad' -or ($ArgumentList[0] -eq 'rest' -and ($ArgumentList -join ' ') -match 'graph\.microsoft\.com|Microsoft\.ResourceGraph') }
        @($script:rest | Where-Object { $_ -match '^GET https://graph\.microsoft\.com/v1\.0/organization' }).Count | Should -BeGreaterThan 0
        @($script:rest | Where-Object { $_ -match '^POST https://graph\.microsoft\.com/v1\.0/directoryObjects/getByIds ' }).Count | Should -BeGreaterThan 0
    }

    It 'reports a manifest that didn''t record the identities as a Warning, not as "no identities"' {
        $manifest = New-TestManifest
        $manifest.Principals = @()
        $manifest | Add-Member -NotePropertyName 'IdentitiesRecorded' -NotePropertyValue $false
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest $manifest -WaitMinutes 0)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).message | Should -Match 'didn''t record'
        $manifest.IdentitiesRecorded = $true
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest $manifest -WaitMinutes 0)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).status | Should -Be 'Pass'
    }

    It 'without a manifest, looks for the resource group by its name only, warns, and never matches by the solution and environment tags' {
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest $null -WaitMinutes 0)
        $tagged = $results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.TAGGED' }
        $tagged.status | Should -Be 'Warning'
        $tagged.message | Should -Match 'deploymentId is unknown'
        $tagged.remediation | Should -Match 'destroy\.ps1 -ResidueOnly -ManifestPath'
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).status | Should -Be 'Warning'
        $script:queries | Should -Not -Match 'deploymentId'
        $script:queries | Should -Not -Match 'tags\.solution|tags\.environment'
        ($script:queries | Where-Object { $_ -match "^resourcecontainers \| where type =~ 'microsoft\.resources/subscriptions/resourcegroups'" } | Select-Object -First 1) | Should -Match "where name =~ 'rg-dbhub-demo' \| where name !~ 'rg-dbhub-control' \| project id$"
        ($script:queries | Where-Object { $_ -match 'hybridcompute' } | Select-Object -First 1) | Should -Match "resourceGroup =~ 'rg-dbhub-demo'"
    }

    It 'scopes the tag and Arc queries to the deploymentId and the group''s exact name, and never counts the GitHub identity''s group' {
        $null = Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0
        $tagged = $script:queries | Where-Object { $_ -match 'union' } | Select-Object -First 1
        $tagged | Should -Be "resources | where tostring(tags.deploymentId) == 'abc123' | where resourceGroup !~ 'rg-dbhub-control' | project id | union (resourcecontainers | where type =~ 'microsoft.resources/subscriptions/resourcegroups' | where name =~ 'rg-dbhub-demo' or tostring(tags.deploymentId) == 'abc123' | where name !~ 'rg-dbhub-control' | project id)"
        $arc = $script:queries | Where-Object { $_ -match 'hybridcompute' } | Select-Object -First 1
        $arc | Should -Match "where resourceGroup =~ 'rg-dbhub-demo' or tolower\(tostring\(properties\.containerResourceId\)\) contains '/resourcegroups/rg-dbhub-demo/' or tostring\(tags\.deploymentId\) == 'abc123' \| project id$"
        $arc | Should -Match 'microsoft.azurearcdata/sqlserverinstances'
        $arc | Should -Match 'microsoft.hybridcompute/machines/extensions'
        # Never the solution and environment tags alone, and never a resource's name.
        $script:queries | Should -Not -Match 'tags\.solution|tags\.environment|fabric-database-hub-demo'
        $script:queries | Should -Not -Match "\bname (=~|==|in~) .*(sqlvm01|arcsql01)"
    }

    It 'never counts another prefix''s environment with the same environment name, or a resource by its name alone (live, 2026-11-02)' {
        # rg-dbhubalt-demo is another prefix's environment, also named demo, still deployed in the same subscription. Its
        # resources carry solution fabric-database-hub-demo and environment demo too, under another deploymentId, and
        # its VMs and Arc machine have this environment's names. A query that matched them by those tags, or by a
        # name, would get them back.
        $other = @(
            ($script:sub + '/resourceGroups/rg-dbhubalt-demo')
            ($script:sub + '/resourceGroups/rg-dbhubalt-demo/providers/Microsoft.Compute/virtualMachines/sqlvm01')
            ($script:sub + '/resourceGroups/rg-dbhubalt-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-zzz999')
            ($script:sub + '/resourceGroups/rg-dbhubalt-demo/providers/Microsoft.DevTestLab/schedules/shutdown-computevm-sqlvm01')
            ($script:sub + '/resourceGroups/rg-dbhubalt-demo/providers/Microsoft.HybridCompute/machines/arcsql01')
        )
        $script:graph["tags\.environment|tags\.solution|\bname (=~|==|in~) .*(sqlvm01|arcsql01)"] = New-GraphResult -Rows @($other | ForEach-Object { [pscustomobject]@{ id = $_ } })
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        foreach ($name in 'TAGGED', 'ARC', 'GROUPRESOURCES') {
            $result = $results | Where-Object { $_.checkId -eq "TEARDOWN.RESIDUAL.$name" }
            $result.status | Should -Be 'Pass' -Because $name
            @($result.evidence.remaining) | Should -BeNullOrEmpty -Because $name
        }
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.TAGGED' }).message | Should -Match 'deploymentId abc123, or the resource group rg-dbhub-demo'
        @($results | Where-Object { $_.status -eq 'Fail' }) | Should -BeNullOrEmpty
        @($script:rest | Where-Object { $_ -match 'rg-dbhubalt-demo' }) | Should -BeNullOrEmpty -Because 'nothing of the other environment is even read'
    }

    It 'reads every identity of a manifest loaded from JSON, one principal or several' {
        $two = (New-TestManifest | ConvertTo-Json -Depth 5) | ConvertFrom-Json -Depth 5
        $null = Test-DemoTeardownResidue -Config $config -Manifest $two -WaitMinutes 0
        $lookups = @($script:rest | Where-Object { $_ -match 'getByIds' })
        $lookups.Count | Should -Be 2 -Because 'one lookup per pass: the poll and the final read'
        $lookups | ForEach-Object { $_ | Should -Match 'aaaaaaaa-1111-2222-3333-444444444444'; $_ | Should -Match 'bbbbbbbb-1111-2222-3333-444444444444' }
        $script:rest.Clear()
        $one = '{"ResourceGroupName": "rg-dbhub-demo", "DeploymentId": "abc123", "Principals": [{"Name": "sqlvm01", "PrincipalId": "cccccccc-1111-2222-3333-444444444444"}]}' | ConvertFrom-Json -AsHashtable
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest $one -WaitMinutes 0)
        @($script:rest | Where-Object { $_ -match 'getByIds' -and $_ -match 'cccccccc-1111-2222-3333-444444444444' }).Count | Should -Be 2
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).message | Should -Match '^1 managed identit'
    }

    It 'counts role assignments at the group, under it, or for its identities in the demo''s groups, and none of another group' {
        $group = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/rg-dbhub-demo'
        $script:graph['roleassignments'] = New-GraphResult -Rows @(
            [pscustomobject]@{ id = 'ra-group'; assignmentScope = $group; principalId = 'dddddddd-1111-2222-3333-444444444444' }
            [pscustomobject]@{ id = 'ra-child'; assignmentScope = $group + '/providers/microsoft.compute/virtualmachines/sqlvm01'; principalId = 'dddddddd-1111-2222-3333-444444444444' }
            [pscustomobject]@{ id = 'ra-other-group'; assignmentScope = $group + '2'; principalId = 'dddddddd-1111-2222-3333-444444444444' }
            [pscustomobject]@{ id = 'ra-control'; assignmentScope = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/rg-dbhub-control'; principalId = 'bbbbbbbb-1111-2222-3333-444444444444' }
            [pscustomobject]@{ id = 'ra-identity'; assignmentScope = '/subscriptions/11111111-2222-3333-4444-555555555555'; principalId = 'aaaaaaaa-1111-2222-3333-444444444444' }
        )
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        $assignments = $results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.ROLEASSIGNMENTS' }
        $assignments.status | Should -Be 'Fail'
        $assignments.evidence.remaining | Should -Be @('ra-group', 'ra-child', 'ra-control')
        # One for an identity outside the demo's groups is named too, as an orphan someone else made.
        @($assignments.evidence.orphaned | ForEach-Object { $_.id }) | Should -Be @('ra-identity')
        $assignments.message | Should -Match 'outside the demo''s resource groups'
        ($script:queries | Where-Object { $_ -match 'roleassignments' } | Select-Object -First 1) | Should -Match "principalId in \('aaaaaaaa-1111-2222-3333-444444444444', 'bbbbbbbb-1111-2222-3333-444444444444'\)"
    }

    It 'warns, naming its scope, about a role assignment a tenant policy gave a deleted identity outside the demo''s groups, and deletes nothing (live, 2026-11-02)' {
        # A DeployIfNotExists policy assigned one of the demo's managed identities a role on a storage account elsewhere;
        # the identity went with the destroy, and the assignment stayed as "Identity not found". The demo creates none
        # outside its group: with assignRoles, its own are at or under rg-<prefix>-<environment>.
        $scope = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/rg-shared-policy/providers/microsoft.storage/storageaccounts/stsharedlogs01'
        $script:graph['roleassignments'] = New-GraphResult -Rows @(
            [pscustomobject]@{ id = ($scope + '/providers/Microsoft.Authorization/roleAssignments/eeeeeeee-1111-2222-3333-444444444444'); assignmentScope = $scope; principalId = 'aaaaaaaa-1111-2222-3333-444444444444'; roleDefinitionId = '/subscriptions/11111111-2222-3333-4444-555555555555/providers/microsoft.authorization/roledefinitions/ffffffff-1111-2222-3333-444444444444' }
        )
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 5 -PollSeconds 5)
        $assignments = $results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.ROLEASSIGNMENTS' }
        $assignments.status | Should -Be 'Warning'
        $assignments.message | Should -Match ([regex]::Escape($scope))
        $assignments.message | Should -Match 'didn''t create them: it gives its managed identities role assignments only at or under rg-dbhub-demo, and only with assignRoles'
        $assignments.message | Should -Match 'DeployIfNotExists'
        $assignments.message | Should -Match 'Identity not found'
        $assignments.remediation | Should -Match 'Owner or User Access Administrator'
        $assignments.remediation | Should -Match ([regex]::Escape('https://learn.microsoft.com/azure/role-based-access-control/role-assignments-remove'))
        $assignments.docUrl | Should -Be 'https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#symptom---role-assignments-with-identity-not-found'
        $assignments.evidence.orphaned[0].scope | Should -Be $scope
        $assignments.evidence.orphaned[0].principalId | Should -Be 'aaaaaaaa-1111-2222-3333-444444444444'
        @($results | Where-Object { $_.status -eq 'Fail' }) | Should -BeNullOrEmpty
        # It doesn't go away by waiting, and nothing deletes it.
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match 'role assignment delete|--method delete' }
        @($script:rest | Where-Object { $_ -notmatch '^(GET|POST) ' }) | Should -BeNullOrEmpty
    }

    It 'reports what Resource Graph still lists in the deleted group as index records once Resource Manager says it''s gone (live, 2026-11-02)' {
        # Live: Resource Graph listed ten databases of a deleted Arc SQL Server instance in their deleted group for more
        # than 30 minutes, while a Resource Manager GET of each answered 404 ResourceGroupNotFound.
        $databases = @(1..10 | ForEach-Object { '{0}/resourceGroups/rg-dbhub-demo/providers/Microsoft.AzureArcData/sqlServerInstances/ARCSQL01_MSSQLSERVER/databases/db{1:D2}' -f $script:sub, $_ })
        $rows = New-GraphResult -Rows @($databases | ForEach-Object { [pscustomobject]@{ id = $_ } })
        $script:graph["^resources \| where resourceGroup =~ 'rg-dbhub-demo' \| project id$"] = $rows
        $script:graph['microsoft\.azurearcdata/sqlserverinstances/databases'] = $rows
        $script:arm['/resourceGroups/rg-dbhub-demo/'] = New-ArmError -Status 404 -Code 'ResourceGroupNotFound'
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 10 -PollSeconds 30)
        foreach ($name in 'GROUPRESOURCES', 'ARC', 'RECORDS') {
            ($results | Where-Object { $_.checkId -eq "TEARDOWN.RESIDUAL.$name" }).status | Should -Be 'Pass' -Because $name
        }
        $group = $results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.GROUPRESOURCES' }
        $group.message | Should -Match '^Only index records remain: Resource Graph still lists 10 resource\(s\) in rg-dbhub-demo \(microsoft\.azurearcdata/sqlserverinstances/databases: 10\), but Azure Resource Manager says they''re gone \(ResourceGroupNotFound\)'
        @($group.evidence.remaining) | Should -BeNullOrEmpty
        @($group.evidence.indexRecords).Count | Should -Be 10
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.ARC' }).message | Should -Match 'Only index records remain: Resource Graph still lists 10 deleted Arc resource\(s\)'
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.RECORDS' }).message | Should -Match '^Only records remain: .*Azure Resource Graph index of deleted resources, microsoft\.azurearcdata/sqlserverinstances/databases: 10'
        @($results | Where-Object { $_.status -in 'Fail', 'Warning' }) | Should -BeNullOrEmpty
        # One Providers - Get for the type's API version (nothing pins it), then one read per row, through
        # Invoke-DemoRestRequest; the rows Resource Manager says are gone end the wait at once.
        @($script:rest | Where-Object { $_ -match '^GET https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft\.AzureArcData\?api-version=2021-04-01 ' }).Count | Should -Be 1
        $reads = @($script:rest | Where-Object { $_ -match '^GET https://management\.azure\.com/subscriptions/.*/databases/db\d\d\?api-version=2026-01-01 ' })
        $reads.Count | Should -Be 10
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'rest' -and ($ArgumentList -join ' ') -match 'databases' }
    }

    It 'reads at most 25 resources from Resource Manager, and reports what it couldn''t confirm as a Warning, never a Fail' {
        $nics = @(1..40 | ForEach-Object { '{0}/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/networkInterfaces/nic{1:D2}' -f $script:sub, $_ })
        $script:graph["^resources \| where resourceGroup =~ 'rg-dbhub-demo' \| project id$"] = New-GraphResult -Rows @($nics | ForEach-Object { [pscustomobject]@{ id = $_ } })
        $script:arm['/resourceGroups/rg-dbhub-demo/'] = New-ArmError -Status 404 -Code 'ResourceGroupNotFound'
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        $group = $results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.GROUPRESOURCES' }
        $group.status | Should -Be 'Warning'
        $group.message | Should -Match '^Resource Graph still lists 15 resource\(s\) in rg-dbhub-demo that Azure Resource Manager didn''t confirm: not read: the check reads at most 25 resources'
        $group.remediation | Should -Match 'destroy\.ps1 -ResidueOnly'
        $group.evidence.resourceManagerReads | Should -Be 25
        @($group.evidence.indexRecords).Count | Should -Be 25
        @($script:rest | Where-Object { $_ -match '^GET https://management\.azure\.com/subscriptions/' }).Count | Should -Be 25 -Because 'Network interfaces have a pinned API version, so no provider is read'
        @($results | Where-Object { $_.status -eq 'Fail' }) | Should -BeNullOrEmpty
        # 0 disables the reads: every row is unconfirmed.
        $script:rest.Clear()
        ($(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0 -MaxResourceReads 0) | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.GROUPRESOURCES' }).status | Should -Be 'Warning'
        @($script:rest | Where-Object { $_ -match '^GET https://management\.azure\.com/subscriptions/' }) | Should -BeNullOrEmpty
    }

    It 'still fails what Resource Manager returns, and warns about a row it answers with another error' {
        $vm = '{0}/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/sqlvm01' -f $script:sub
        $odd = '{0}/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/networkInterfaces/nic-sqlvm01' -f $script:sub
        $script:graph["^resources \| where resourceGroup =~ 'rg-dbhub-demo' \| project id$"] = New-GraphResult -Rows @([pscustomobject]@{ id = $vm }, [pscustomobject]@{ id = $odd })
        $script:arm['/networkInterfaces/nic-sqlvm01\?'] = New-ArmError -Status 404 -Code 'NoRegisteredProviderFound'
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        $group = $results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.GROUPRESOURCES' }
        $group.status | Should -Be 'Fail'
        $group.message | Should -Match '^1 resource\(s\) are still in rg-dbhub-demo: Azure Resource Manager returned them\.'
        $group.evidence.remaining | Should -Be @($vm, $odd)

        $script:graph["^resources \| where resourceGroup =~ 'rg-dbhub-demo' \| project id$"] = New-GraphResult -Rows @([pscustomobject]@{ id = $odd })
        $group = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0) | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.GROUPRESOURCES' }
        $group.status | Should -Be 'Warning'
        $group.message | Should -Match 'didn''t confirm: Azure Resource Manager answered HTTP 404: .*NoRegisteredProviderFound'
    }

    It 'reports resources outside the group that name it as a Warning, and platform records as evidence' {
        $script:graph['propertiesText'] = New-GraphResult -Rows @([pscustomobject]@{ id = '/subscriptions/x/resourceGroups/shared/providers/Microsoft.Network/networkWatchers/nw/flowLogs/fl' })
        $script:graph['securityresources'] = New-GraphResult -Rows @([pscustomobject]@{ item = 'microsoft.security/assessments: 3' })
        $script:graph['guestconfigurationresources'] = New-GraphResult -Rows @([pscustomobject]@{ item = 'microsoft.guestconfiguration/guestconfigurationassignments: 1' })
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.REFERENCES' }).status | Should -Be 'Warning'
        $records = $results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.RECORDS' }
        $records.status | Should -Be 'Pass'
        $records.message | Should -Match 'microsoft.security/assessments: 3'
        $records.evidence.remaining | Should -Contain 'microsoft.guestconfiguration/guestconfigurationassignments: 1'
        $references = $script:queries | Where-Object { $_ -match 'propertiesText' } | Select-Object -First 1
        $references | Should -Match "propertiesText contains '/resourcegroups/rg-dbhub-demo/'"
        $references | Should -Match "propertiesText contains '/resourcegroups/rg-dbhub-demo`"'"
    }

    It 'reports platform records it can''t read as a Warning' {
        $script:graph['policyresources'] = New-GraphResult -Succeeded $false
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.RECORDS' }).status | Should -Be 'Warning'
    }

    It 'with the Key Vault opt-in, reports the soft-deleted vault as a Warning' {
        $vaultConfig = New-TestConfig
        $vaultConfig['assignRoles'] = $true
        $vaultConfig['keyVault']['enabled'] = $true
        $manifest = New-TestManifest
        $manifest.KeyVaultName = 'kv-dbhubdemo-abc123'
        $script:az['^keyvault list-deleted'] = New-AzResult -StdOut '["kv-dbhubdemo-abc123"]'
        $results = @(Test-DemoTeardownResidue -Config $vaultConfig -Manifest $manifest -WaitMinutes 0)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.KEYVAULT' }).status | Should -Be 'Warning'
    }
}

Describe 'Remove-DemoEnvironment: manifest, deployment record, and residue' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:order = [System.Collections.Generic.List[string]]::new()
        $script:groupExists = $true
        $script:residueStatus = 'Pass'
        $script:recordStatus = New-AzResult -StdOut "dbhub-demo-main`n"
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoResourceGroupExist -MockWith { $script:groupExists }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -MockWith { $script:order.Add('Manifest'); New-TestManifest }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @($script:goldenSnapshots) }
        # The nightly safety stop's role definition (ADR 0024): none, unless a test says so.
        $script:safetyRoleId = ''
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSafetyStopRoleState -MockWith { [pscustomobject]@{ Id = $script:safetyRoleId; Actions = @(); Error = '' } }
        $script:goldenSnapshots = @()
        $script:hostName = ''
        $script:goldenGroupExists = $false
        Mock -ModuleName DbHubDemo -CommandName Test-DemoTeardownResidue -MockWith {
            $script:order.Add('Residue:' + [string]$Manifest.DeploymentId)
            New-DemoResult -CheckId 'TEARDOWN.RESIDUAL.ARC' -Area 'teardown' -Target 'T2' -Status $script:residueStatus -Message 'arc'
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $text = $ArgumentList -join ' '
            $script:order.Add(($ArgumentList[0..2] -join ' '))
            if ($text -match '^group delete --name rg-dbhub-golden') {
                $script:goldenGroupExists = $false
                return (New-AzResult)
            }
            if ($text -match '^group exists --name rg-dbhub-golden') {
                return (New-AzResult -StdOut $(if ($script:goldenGroupExists) { "true`n" } else { "false`n" }))
            }
            if ($text -match '^vm show .*--name archost01') {
                return (New-AzResult -StdOut $(if ($script:hostName) { $script:hostName + "`n" } else { '' }))
            }
            if ($text -match '^group delete') {
                $script:groupExists = $false
                return (New-AzResult)
            }
            if ($text -match '^deployment sub show') {
                return $script:recordStatus
            }
            New-AzResult
        }
    }

    It 'reads the manifest first, deletes the group, then the deployment record, then checks for residue' {
        $manifestPath = Join-Path -Path $TestDrive -ChildPath 'out/destroy-manifest.json'
        $results = @(Remove-DemoEnvironment -Config $config -ManifestPath $manifestPath -Confirm:$false)
        $script:order | Should -Be @('Manifest', 'group delete --name', 'deployment sub show', 'deployment sub delete', 'rest --method get', 'rest --method delete', 'Residue:abc123') -Because 'JumpstartImage, the default since 2026-11-05, has no golden guard, so destroy reads no host'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.DEPLOYMENT' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.BUDGET' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESIDUAL' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN' }).status | Should -Be 'Not selected'
        (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).DeploymentId | Should -Be 'abc123'
    }

    It 'finishes the cleanup when the group is already gone' {
        $script:groupExists = $false
        $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
        $script:order | Should -Be @('Manifest', 'deployment sub show', 'deployment sub delete', 'rest --method get', 'rest --method delete', 'Residue:abc123')
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).message | Should -Match 'doesn''t exist'
    }

    It 'says the nightly safety stop''s role stays, unassigned and free, with an Owner''s command to delete it (ADR 0024)' {
        $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
        $results | Where-Object { $_.checkId -eq 'DESTROY.SAFETYSTOP.ROLE' } | Should -BeNullOrEmpty

        $script:groupExists = $true
        $script:safetyRoleId = '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/eeeeeeee-0000-0000-0000-000000000024' -f $config['subscriptionId']
        $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
        $role = $results | Where-Object { $_.checkId -eq 'DESTROY.SAFETYSTOP.ROLE' }
        $role.status | Should -Be 'Not selected'
        $role.message | Should -Match 'no assignment left \(its one assignment went with rg-dbhub-demo\) and no cost'
        $role.message | Should -Match ([regex]::Escape(('az role definition delete --name "DbHub Demo Safety Stop" --scope /subscriptions/{0}' -f $config['subscriptionId'])))
        $role.evidence.roleId | Should -Be $script:safetyRoleId
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match 'role definition delete' }
    }

    Context 'the budget at the group''s scope, which outlives the group (live, 2026-10-22)' {
        BeforeEach {
            $script:restCalls = [System.Collections.Generic.List[string]]::new()
            $script:budgetRead = New-AzResult -StdOut '{"name": "budget-dbhub-demo"}'
            $script:budgetDelete = New-AzResult
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
                $text = $ArgumentList -join ' '
                if ($text -match '^rest --method (get|delete)') {
                    $script:restCalls.Add($text)
                    if ($Matches[1] -eq 'get') {
                        return $script:budgetRead
                    }
                    return $script:budgetDelete
                }
                if ($text -match '^group delete') {
                    $script:groupExists = $false
                }
                New-AzResult
            }
        }

        It 'deletes it by its URL in the configured subscription, with or without the group' -ForEach @(
            @{ GroupExists = $true }
            @{ GroupExists = $false }
        ) {
            $script:groupExists = $GroupExists
            $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)

            $budget = $results | Where-Object { $_.checkId -eq 'DESTROY.BUDGET' }
            $budget.status | Should -Be 'Pass'
            $budget.message | Should -Match 'Deleted the budget budget-dbhub-demo'
            $script:restCalls.Count | Should -Be 2
            foreach ($call in $script:restCalls) {
                $call | Should -Match ('--url https://management\.azure\.com/subscriptions/{0}/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Consumption/budgets/budget-dbhub-demo\?api-version=' -f [regex]::Escape([string]$config['subscriptionId']))
                $call | Should -Not -Match '--ids|\{subscriptionId\}'
            }
            $script:restCalls[1] | Should -Match '^rest --method delete'
        }

        It 'reports a Pass without a delete when the budget is already gone' {
            $script:budgetRead = New-AzResult -ExitCode 3 -StdErr $script:notFound
            $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
            ($results | Where-Object { $_.checkId -eq 'DESTROY.BUDGET' }).message | Should -Match 'There''s no budget budget-dbhub-demo'
            $script:restCalls.Count | Should -Be 1
        }

        It 'warns, with the place to delete it, when the delete is refused' {
            $script:budgetDelete = New-AzResult -ExitCode 1 -StdErr 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.'
            $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
            $budget = $results | Where-Object { $_.checkId -eq 'DESTROY.BUDGET' }
            $budget.status | Should -Be 'Warning'
            $budget.message | Should -Match 'AuthorizationFailed'
            $budget.remediation | Should -Match 'Cost Management under Budgets'
        }
    }

    It 'keeps the manifest recorded while the group existed when a run after an interruption finds the group gone' {
        $manifestPath = Join-Path -Path $TestDrive -ChildPath 'rerun/destroy-manifest-demo.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $manifestPath -Parent) -Force
        $recorded = New-TestManifest
        $recorded | Add-Member -NotePropertyName 'ResourceGroupExisted' -NotePropertyValue $true
        Set-Content -LiteralPath $manifestPath -Value ($recorded | ConvertTo-Json -Depth 6)
        $script:groupExists = $false
        Mock -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -MockWith { $script:order.Add('Manifest'); [pscustomobject]@{ ResourceGroupName = 'rg-dbhub-demo'; ResourceGroupExisted = $false; DeploymentId = ''; Principals = @() } }
        $null = @(Remove-DemoEnvironment -Config $config -ManifestPath $manifestPath -Confirm:$false)
        $script:order[-1] | Should -Be 'Residue:abc123'
        $kept = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $kept.ResourceGroupExisted | Should -BeTrue
        @($kept.Principals).Count | Should -Be 2
    }

    It 'replaces a manifest that belongs to another resource group' {
        $manifestPath = Join-Path -Path $TestDrive -ChildPath 'other/destroy-manifest-demo.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $manifestPath -Parent) -Force
        Set-Content -LiteralPath $manifestPath -Value '{"ResourceGroupName": "rg-dbhub-test", "ResourceGroupExisted": true, "DeploymentId": "zzz999", "Principals": []}'
        $script:groupExists = $false
        Mock -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -MockWith { $script:order.Add('Manifest'); [pscustomobject]@{ ResourceGroupName = 'rg-dbhub-demo'; ResourceGroupExisted = $false; DeploymentId = 'abc123'; Principals = @() } }
        $null = @(Remove-DemoEnvironment -Config $config -ManifestPath $manifestPath -Confirm:$false)
        (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).ResourceGroupName | Should -Be 'rg-dbhub-demo'
        $script:order[-1] | Should -Be 'Residue:abc123'
    }

    It 'replaces a manifest of the same resource group in another subscription, with a Warning, and never checks its deploymentId (review of 7fb941e)' {
        # The default path is shared by every subscription with the same environment name, so another subscription's
        # destroy of rg-dbhub-demo can have written it; its deploymentId and identities are another environment's.
        $manifestPath = Join-Path -Path $TestDrive -ChildPath 'othersub/destroy-manifest-demo.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $manifestPath -Parent) -Force
        $other = New-TestManifest
        $other.DeploymentId = 'zzz999'
        $other | Add-Member -NotePropertyName 'SubscriptionId' -NotePropertyValue '99999999-8888-7777-6666-555555555555'
        $other | Add-Member -NotePropertyName 'ResourceGroupExisted' -NotePropertyValue $true
        Set-Content -LiteralPath $manifestPath -Value ($other | ConvertTo-Json -Depth 6)
        $script:groupExists = $false
        Mock -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -MockWith { $script:order.Add('Manifest'); [pscustomobject]@{ SubscriptionId = '11111111-2222-3333-4444-555555555555'; ResourceGroupName = 'rg-dbhub-demo'; ResourceGroupExisted = $false; DeploymentId = 'abc123'; Principals = @() } }
        $null = @(Remove-DemoEnvironment -Config $config -ManifestPath $manifestPath -Confirm:$false)
        $script:order[-1] | Should -Be 'Residue:abc123'
        $kept = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $kept.DeploymentId | Should -Be 'abc123'
        $kept.SubscriptionId | Should -Be '11111111-2222-3333-4444-555555555555'
        @($kept.Principals).Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'is of rg-dbhub-demo in subscription 99999999-8888-7777-6666-555555555555, another environment, so it''s replaced' }
    }

    It 'keeps the earlier manifest of this subscription whatever the case of its ID, and one from before it was recorded' -ForEach @(
        @{ RecordedSubscription = '11111111-2222-3333-4444-555555555555'.ToUpperInvariant() }
        @{ RecordedSubscription = '' }
    ) {
        $manifestPath = Join-Path -Path $TestDrive -ChildPath ('samesub-{0}/destroy-manifest-demo.json' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $manifestPath -Parent) -Force
        $earlier = New-TestManifest
        if ($RecordedSubscription) {
            $earlier | Add-Member -NotePropertyName 'SubscriptionId' -NotePropertyValue $RecordedSubscription
        }
        $earlier | Add-Member -NotePropertyName 'ResourceGroupExisted' -NotePropertyValue $true
        Set-Content -LiteralPath $manifestPath -Value ($earlier | ConvertTo-Json -Depth 6)
        $script:groupExists = $false
        Mock -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -MockWith { $script:order.Add('Manifest'); [pscustomobject]@{ SubscriptionId = '11111111-2222-3333-4444-555555555555'; ResourceGroupName = 'rg-dbhub-demo'; ResourceGroupExisted = $false; DeploymentId = ''; Principals = @() } }
        $null = @(Remove-DemoEnvironment -Config $config -ManifestPath $manifestPath -Confirm:$false)
        $script:order[-1] | Should -Be 'Residue:abc123'
        @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).Principals).Count | Should -Be 2
    }

    It 'reports a missing deployment record as Pass without deleting anything' {
        $script:recordStatus = New-AzResult -ExitCode 3 -StdErr "ERROR: (DeploymentNotFound) Deployment 'dbhub-demo-main' could not be found."
        $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
        $script:order | Should -Not -Contain 'deployment sub delete'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.DEPLOYMENT' }).status | Should -Be 'Pass'
    }

    It 'fails DESTROY.RESIDUAL when something is left, so destroy.ps1 exits with 1' {
        $script:residueStatus = 'Fail'
        $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESIDUAL' }).status | Should -Be 'Fail'
        Get-DemoExitCode -Result $results | Should -Be 1
    }

    It 'skips the residue check with -SkipResidueCheck' {
        $results = @(Remove-DemoEnvironment -Config $config -SkipResidueCheck -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESIDUAL' }).status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoTeardownResidue -Times 0 -Exactly
    }

    It 'treats a group that disappears during the delete (ResourceGroupNotFound) as deleted' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $text = $ArgumentList -join ' '
            if ($text -match '^group delete') {
                $script:groupExists = $false
                return (New-AzResult -ExitCode 3 -StdErr $script:notFound)
            }
            New-AzResult
        }
        $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).status | Should -Be 'Pass'
    }

    It 'waits for a group that an interrupted run left being deleted, and checks the identities that run recorded too' {
        $manifestPath = Join-Path -Path $TestDrive -ChildPath 'deleting/destroy-manifest-demo.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $manifestPath -Parent) -Force
        $recorded = New-TestManifest
        $recorded | Add-Member -NotePropertyName 'ResourceGroupExisted' -NotePropertyValue $true
        Set-Content -LiteralPath $manifestPath -Value ($recorded | ConvertTo-Json -Depth 6)
        # The fresh read sees one identity: T1 is already deleted.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -MockWith {
            $script:order.Add('Manifest')
            [pscustomobject]@{ ResourceGroupName = 'rg-dbhub-demo'; ResourceGroupExisted = $true; IdentitiesRecorded = $true; DeploymentId = 'abc123'; Principals = @([pscustomobject]@{ Name = 'arcsql01'; Type = 'microsoft.hybridcompute/machines'; PrincipalId = 'bbbbbbbb-1111-2222-3333-444444444444' }) }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $text = $ArgumentList -join ' '
            if ($text -match '^group delete') {
                $script:groupExists = $false
                return (New-AzResult -ExitCode 1 -StdErr "ERROR: (ResourceGroupBeingDeleted) The resource group 'rg-dbhub-demo' is in deprovisioning state and cannot perform this operation.")
            }
            New-AzResult
        }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoTeardownResidue -MockWith {
            $script:checked = @(foreach ($principal in @($Manifest.Principals)) { $principal.PrincipalId })
            New-DemoResult -CheckId 'TEARDOWN.RESIDUAL.IDENTITIES' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message 'ok'
        }
        $results = @(Remove-DemoEnvironment -Config $config -ManifestPath $manifestPath -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).status | Should -Be 'Pass'
        $script:checked | Should -Be @('bbbbbbbb-1111-2222-3333-444444444444', 'aaaaaaaa-1111-2222-3333-444444444444')
        @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).Principals).Count | Should -Be 2
    }

    It 'doesn''t add identities from an earlier manifest of another deploymentId' {
        $manifestPath = Join-Path -Path $TestDrive -ChildPath 'olderid/destroy-manifest-demo.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $manifestPath -Parent) -Force
        $recorded = New-TestManifest
        $recorded.DeploymentId = 'zzz999'
        $recorded | Add-Member -NotePropertyName 'ResourceGroupExisted' -NotePropertyValue $true
        Set-Content -LiteralPath $manifestPath -Value ($recorded | ConvertTo-Json -Depth 6)
        Mock -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -MockWith { [pscustomobject]@{ ResourceGroupName = 'rg-dbhub-demo'; ResourceGroupExisted = $true; IdentitiesRecorded = $true; DeploymentId = 'abc123'; Principals = @() } }
        $null = @(Remove-DemoEnvironment -Config $config -ManifestPath $manifestPath -Confirm:$false)
        $kept = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $kept.DeploymentId | Should -Be 'abc123'
        @($kept.Principals).Count | Should -Be 0
    }

    It 'replaces an earlier manifest that can''t be read' {
        $manifestPath = Join-Path -Path $TestDrive -ChildPath 'broken/destroy-manifest-demo.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $manifestPath -Parent) -Force
        Set-Content -LiteralPath $manifestPath -Value '{ not json'
        $null = @(Remove-DemoEnvironment -Config $config -ManifestPath $manifestPath -Confirm:$false)
        (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).DeploymentId | Should -Be 'abc123'
        $script:order[-1] | Should -Be 'Residue:abc123'
    }

    It 'reports DESTROY.RESIDUAL as a Warning, after the deletes, when the residual check can''t run' {
        Mock -ModuleName DbHubDemo -CommandName Test-DemoTeardownResidue -MockWith { throw 'refused by the subscription guard' }
        $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.DEPLOYMENT' }).status | Should -Be 'Pass'
        $residual = $results | Where-Object { $_.checkId -eq 'DESTROY.RESIDUAL' }
        $residual.status | Should -Be 'Warning'
        $residual.message | Should -Match 'refused by the subscription guard'
        $residual.remediation | Should -Match 'destroy\.ps1 -ResidueOnly -ManifestPath'
    }

    Context 'destroy.ps1 -ResidueOnly: the residual check again, read-only (Phase 28 follow-up)' {
        BeforeEach {
            $script:manifestPath = Join-Path -Path $TestDrive -ChildPath ('residue-{0}/destroy-manifest-demo.json' -f [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $script:manifestPath -Parent) -Force
            $recorded = New-TestManifest
            $recorded | Add-Member -NotePropertyName 'ResourceGroupExisted' -NotePropertyValue $true
            $recorded | Add-Member -NotePropertyName 'RecordedUtc' -NotePropertyValue '2026-11-02T14:05:00.0000000Z'
            Set-Content -LiteralPath $script:manifestPath -Value ($recorded | ConvertTo-Json -Depth 6)
            Mock -ModuleName DbHubDemo -CommandName Test-DemoTeardownResidue -MockWith {
                # The mock runs in the test's scope, without the module's helpers; the manifest is $null without one.
                $script:order.Add('Residue:' + $(if ($null -ne $Manifest) { [string]$Manifest.DeploymentId } else { '' }))
                $script:checkedPrincipals = @(if ($null -ne $Manifest) { $Manifest.Principals | ForEach-Object { [string]$_.PrincipalId } })
                New-DemoResult -CheckId 'TEARDOWN.RESIDUAL.ARC' -Area 'teardown' -Target 'T2' -Status $script:residueStatus -Message 'arc'
            }
        }

        It 'reads the saved manifest, runs only the residual check, and deletes, records, and asks nothing' {
            $before = (Get-FileHash -LiteralPath $script:manifestPath -Algorithm SHA256).Hash
            $results = @(Remove-DemoEnvironment -Config $config -ResidueOnly -ManifestPath $script:manifestPath)
            $script:order | Should -Be @('Residue:abc123')
            $script:checkedPrincipals | Should -Be @('aaaaaaaa-1111-2222-3333-444444444444', 'bbbbbbbb-1111-2222-3333-444444444444')
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
            Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -Times 0 -Exactly
            Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -Times 0 -Exactly
            (Get-FileHash -LiteralPath $script:manifestPath -Algorithm SHA256).Hash | Should -Be $before
            $manifestResult = $results | Where-Object { $_.checkId -eq 'DESTROY.MANIFEST' }
            $manifestResult.status | Should -Be 'Pass'
            $manifestResult.message | Should -Match 'recorded 2026-11-02 14:05 UTC for rg-dbhub-demo \(deploymentId abc123, 2 identit\(ies\)\)\. Nothing is deleted\.'
            ($results | Where-Object { $_.checkId -eq 'DESTROY.RESIDUAL' }).status | Should -Be 'Pass'
            @($results | Where-Object { $_.checkId -like 'DESTROY.*' -and $_.checkId -notin 'DESTROY.MANIFEST', 'DESTROY.RESIDUAL' }) | Should -BeNullOrEmpty
            Get-DemoExitCode -Result $results | Should -Be 0
        }

        It 'sums up what''s left as Fail, so destroy.ps1 -ResidueOnly exits with 1' {
            $script:residueStatus = 'Fail'
            $results = @(Remove-DemoEnvironment -Config $config -ResidueOnly -ManifestPath $script:manifestPath)
            ($results | Where-Object { $_.checkId -eq 'DESTROY.RESIDUAL' }).status | Should -Be 'Fail'
            Get-DemoExitCode -Result $results | Should -Be 1
        }

        It 'runs without a manifest when there''s none there, and says so' {
            $results = @(Remove-DemoEnvironment -Config $config -ResidueOnly -ManifestPath (Join-Path -Path $TestDrive -ChildPath 'missing/destroy-manifest-demo.json'))
            $manifestResult = $results | Where-Object { $_.checkId -eq 'DESTROY.MANIFEST' }
            $manifestResult.status | Should -Be 'Warning'
            $manifestResult.message | Should -Match 'There''s no manifest at .*looks for rg-dbhub-demo by name only'
            $script:order | Should -Be @('Residue:')
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
        }

        It 'checks nothing with another resource group''s manifest, or one it can''t read' {
            Set-Content -LiteralPath $script:manifestPath -Value '{"ResourceGroupName": "rg-dbhubalt-demo", "ResourceGroupExisted": true, "DeploymentId": "zzz999", "Principals": []}'
            $results = @(Remove-DemoEnvironment -Config $config -ResidueOnly -ManifestPath $script:manifestPath)
            $manifestResult = $results | Where-Object { $_.checkId -eq 'DESTROY.MANIFEST' }
            $manifestResult.status | Should -Be 'Fail'
            $manifestResult.message | Should -Match 'is the manifest of rg-dbhubalt-demo, not of rg-dbhub-demo'
            Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoTeardownResidue -Times 0 -Exactly
            Set-Content -LiteralPath $script:manifestPath -Value '{ not json'
            $results = @(Remove-DemoEnvironment -Config $config -ResidueOnly -ManifestPath $script:manifestPath)
            ($results | Where-Object { $_.checkId -eq 'DESTROY.MANIFEST' }).message | Should -Match 'isn''t a readable manifest'
            Get-DemoExitCode -Result $results | Should -Be 1
            $script:order.Count | Should -Be 0
        }

        It 'checks nothing with the same resource group''s manifest from another subscription, and names both subscriptions (review of 7fb941e)' {
            # Reproduced in review: DESTROY.MANIFEST passed, and the check got the other subscription's deploymentId.
            $other = New-TestManifest
            $other.DeploymentId = 'zzz999'
            $other | Add-Member -NotePropertyName 'SubscriptionId' -NotePropertyValue '99999999-8888-7777-6666-555555555555'
            $other | Add-Member -NotePropertyName 'ResourceGroupExisted' -NotePropertyValue $true
            Set-Content -LiteralPath $script:manifestPath -Value ($other | ConvertTo-Json -Depth 6)
            $results = @(Remove-DemoEnvironment -Config $config -ResidueOnly -ManifestPath $script:manifestPath)
            $manifestResult = $results | Where-Object { $_.checkId -eq 'DESTROY.MANIFEST' }
            $manifestResult.status | Should -Be 'Fail'
            $manifestResult.message | Should -Match 'is the manifest of rg-dbhub-demo in subscription 99999999-8888-7777-6666-555555555555, not of rg-dbhub-demo in subscription 11111111-2222-3333-4444-555555555555, this configuration''s\.'
            $manifestResult.remediation | Should -Match 'shared by every prefix and subscription with that environment name'
            Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoTeardownResidue -Times 0 -Exactly
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
            @($results | Where-Object { $_.checkId -like 'TEARDOWN.*' -or $_.checkId -eq 'DESTROY.RESIDUAL' }) | Should -BeNullOrEmpty
            $script:order.Count | Should -Be 0
            Get-DemoExitCode -Result $results | Should -Be 1
        }

        It 'reads a manifest of this subscription whatever the case of its ID' {
            $recorded = New-TestManifest
            $recorded | Add-Member -NotePropertyName 'SubscriptionId' -NotePropertyValue '11111111-2222-3333-4444-555555555555'.ToUpperInvariant()
            Set-Content -LiteralPath $script:manifestPath -Value ($recorded | ConvertTo-Json -Depth 6)
            $results = @(Remove-DemoEnvironment -Config $config -ResidueOnly -ManifestPath $script:manifestPath)
            ($results | Where-Object { $_.checkId -eq 'DESTROY.MANIFEST' }).status | Should -Be 'Pass'
            $script:order | Should -Be @('Residue:abc123')
        }

        It 'stops before anything when the subscription guard fails' {
            Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { throw 'The Azure CLI is signed in to another tenant.' }
            $results = @(Remove-DemoEnvironment -Config $config -ResidueOnly -ManifestPath $script:manifestPath)
            $results.checkId | Should -Be @('PREFLIGHT.GUARD.CONTEXT')
            $script:order.Count | Should -Be 0
        }
    }

    It 'deletes the budget at the group''s scope, which outlives the group (R273, live 2026-10-22)' {
        $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'DESTROY.BUDGET' }).status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '^rest --method delete --url https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Consumption/budgets/budget-dbhub-demo\?api-version=' }
    }
    It 'deletes nothing and writes no manifest with -WhatIf' {
        $manifestPath = Join-Path -Path $TestDrive -ChildPath 'whatif/destroy-manifest.json'
        $results = @(Remove-DemoEnvironment -Config $config -ManifestPath $manifestPath -WhatIf)
        $script:order.Count | Should -Be 0
        Test-Path -LiteralPath $manifestPath | Should -BeFalse
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).status | Should -Be 'Not selected'
    }

    It 'deletes nothing when a PaygWizard host has no boot-verified golden snapshot (ADR 0018)' {
        $script:hostName = 'archost01'
        $script:goldenSnapshots = @([pscustomobject]@{ Name = 'snap-dbhub-t2golden-202601010000'; BootVerifiedUtc = $null; EvalDaysLeft = 100 })
        $wizard = New-TestConfig
        $wizard['t2SqlInstallMode'] = 'PaygWizard'
        $results = @(Remove-DemoEnvironment -Config $wizard -Confirm:$false)
        $guard = $results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN.GUARD' }
        $guard.status | Should -Be 'Fail'
        $guard.remediation | Should -Match '-WithoutGolden'
        $script:order | Should -Contain 'vm show --resource-group'
        $script:order | Should -Not -Contain 'group delete --name'
        $script:order | Should -Not -Contain 'Manifest'
        Get-DemoExitCode -Result $results | Should -Be 1
    }

    It 'deletes a PaygWizard host that a boot-verified golden snapshot keeps, and keeps the golden group' {
        $script:hostName = 'archost01'
        $script:goldenGroupExists = $true
        $script:goldenSnapshots = @([pscustomobject]@{ Name = 'snap-dbhub-t2golden-202601010000'; BootVerifiedUtc = [datetime]'2026-01-01'; EvalDaysLeft = 100 })
        $wizard = New-TestConfig
        $wizard['t2SqlInstallMode'] = 'PaygWizard'
        $results = @(Remove-DemoEnvironment -Config $wizard -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN.GUARD' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).status | Should -Be 'Pass'
        $golden = $results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN' }
        $golden.status | Should -Be 'Not selected'
        $golden.message | Should -Match '-IncludeGolden'
        @($script:order | Where-Object { $_ -eq 'group delete --name' }).Count | Should -Be 1
    }

    It 'treats a snapshot whose guest evaluation is over as no golden snapshot' {
        $script:hostName = 'archost01'
        $script:goldenSnapshots = @([pscustomobject]@{ Name = 'snap-dbhub-t2golden-202601010000'; BootVerifiedUtc = [datetime]'2026-01-01'; EvalDaysLeft = 0 })
        $wizard = New-TestConfig
        $wizard['t2SqlInstallMode'] = 'PaygWizard'
        ($(Remove-DemoEnvironment -Config $wizard -Confirm:$false) | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN.GUARD' }).status | Should -Be 'Fail'
    }

    It 'accepts losing the wizard state with -WithoutGolden, as a Warning' {
        $script:hostName = 'archost01'
        $wizard = New-TestConfig
        $wizard['t2SqlInstallMode'] = 'PaygWizard'
        $results = @(Remove-DemoEnvironment -Config $wizard -WithoutGolden -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN.GUARD' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).status | Should -Be 'Pass'
    }

    It 'skips the guard when the environment has no PaygWizard install (<_>)' -ForEach @('JumpstartImage', 'Developer') {
        $script:hostName = 'archost01'
        $other = New-TestConfig
        $other['t2SqlInstallMode'] = $_
        $results = @(Remove-DemoEnvironment -Config $other -Confirm:$false)
        $results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN.GUARD' } | Should -BeNullOrEmpty
        $script:order | Should -Not -Contain 'vm show --resource-group'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).status | Should -Be 'Pass'
    }

    It 'deletes the golden group too with -IncludeGolden' {
        $script:hostName = 'archost01'
        $script:goldenGroupExists = $true
        $script:goldenSnapshots = @([pscustomobject]@{ Name = 'snap-dbhub-t2golden-202601010000'; BootVerifiedUtc = [datetime]'2026-01-01'; EvalDaysLeft = 100 })
        $wizard = New-TestConfig
        $wizard['t2SqlInstallMode'] = 'PaygWizard'
        $results = @(Remove-DemoEnvironment -Config $wizard -IncludeGolden -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN.GUARD' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN' }).status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '^group delete --name rg-dbhub-golden --yes' }
        $script:goldenGroupExists | Should -BeFalse
    }
}

Describe 'Teardown tests stay out of the static run' {
    It 'skips every live teardown test without -Live or DBHUB_TEARDOWN_TESTS and a configuration' {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json
        $testFile = Join-Path -Path $repoRoot -ChildPath 'tests/teardown/Teardown.Residue.Tests.ps1'
        $childScript = @'
$env:DBHUB_TEARDOWN_TESTS = $null
$env:DBHUB_TEARDOWN_CONFIG = $null
Import-Module -Name Pester -RequiredVersion {0}
$configuration = New-PesterConfiguration
$configuration.Run.Path = '{1}'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
$run = Invoke-Pester -Configuration $configuration
'{{0}}/{{1}}/{{2}}/{{3}}' -f $run.TotalCount, $run.SkippedCount, $run.PassedCount, $run.FailedCount
'@ -f $versions.tools.pester, $testFile.Replace("'", "''")
        $pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $counts = (& $pwsh -NoProfile -NonInteractive -Command $childScript | Select-Object -Last 1) -split '/'
        [int]$counts[0] | Should -BeGreaterThan 0
        [int]$counts[1] | Should -Be ([int]$counts[0])
        [int]$counts[2] | Should -Be 0
        [int]$counts[3] | Should -Be 0
    }

    It 'the teardown scripts never call az login or az account set' {
        $hits = Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'tests/teardown') -Recurse -File -Include '*.ps1' |
            Select-String -Pattern "'(login|logout)'|account', 'set'|az login|az account set" |
            Where-Object { $_.Line -notmatch '^\s*#|az login --tenant' }
        $hits | Should -BeNullOrEmpty
    }

    It 'the teardown code never passes --ids, --resource-id, or a {subscriptionId} placeholder to the Azure CLI' {
        # Each of them would let a call escape the configured subscription that Invoke-DemoAz pins.
        $files = @(
            'scripts/destroy.ps1'
            'scripts/modules/DbHubDemo/Private/TeardownHelpers.ps1'
            'scripts/modules/DbHubDemo/Public/Get-DemoTeardownManifest.ps1'
            'scripts/modules/DbHubDemo/Public/Remove-DemoEnvironment.ps1'
            'scripts/modules/DbHubDemo/Public/Test-DemoTeardownResidue.ps1'
        ) | ForEach-Object { Join-Path -Path $repoRoot -ChildPath $_ }
        $files += @(Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'tests/teardown') -Recurse -File -Include '*.ps1' | ForEach-Object { $_.FullName })
        $hits = $files | Select-String -Pattern "'--ids'|'--resource-id'|/subscriptions/\{subscriptionId\}"
        $hits | Should -BeNullOrEmpty
    }

    It 'Invoke-TeardownTest.ps1 -Destroy refuses a mistyped environment, the demo environment, and a PaygWizard environment' {
        $example = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $example['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $example['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $runner = Join-Path -Path $repoRoot -ChildPath 'tests/teardown/Invoke-TeardownTest.ps1'
        $cases = @(
            @{ Environment = 'demo'; Mode = 'Developer'; Confirm = 'demo'; Expected = '*owner*explicit go-ahead*' }
            @{ Environment = 'test'; Mode = 'PaygWizard'; Confirm = 'test'; Expected = '*owner*explicit go-ahead*' }
            @{ Environment = 'test'; Mode = 'Developer'; Confirm = 'tset'; Expected = '*-ConfirmEnvironment test*' }
        )
        foreach ($case in $cases) {
            $example['environment'] = $case.Environment
            $example['t2SqlInstallMode'] = $case.Mode
            $path = Join-Path -Path $TestDrive -ChildPath ('{0}-{1}.json' -f $case.Environment, $case.Mode)
            Set-Content -LiteralPath $path -Value ($example | ConvertTo-Json -Depth 10)
            { & $runner -ConfigPath $path -Destroy -ConfirmEnvironment $case.Confirm } | Should -Throw -ExpectedMessage $case.Expected
        }
    }
}
