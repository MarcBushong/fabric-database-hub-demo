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
            throw ('Unexpected REST call: {0}' -f $Uri)
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

    It 'without a manifest, checks the environment''s solution and environment tags and never matches untagged resources' {
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest $null -WaitMinutes 0)
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.TAGGED' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.TAGGED' }).message | Should -Match 'deploymentId is unknown'
        ($results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.IDENTITIES' }).status | Should -Be 'Warning'
        $script:queries | Should -Not -Match 'deploymentId'
        $tagged = $script:queries | Where-Object { $_ -match 'union' } | Select-Object -First 1
        $tagged | Should -Match "tostring\(tags.solution\) =~ 'fabric-database-hub-demo' and tostring\(tags.environment\) =~ 'demo'"
        ($script:queries | Where-Object { $_ -match 'hybridcompute' } | Select-Object -First 1) | Should -Match "resourceGroup =~ 'rg-dbhub-demo'"
    }

    It 'scopes the tag and Arc queries to the environment''s tags and the group, and never counts the GitHub identity''s group' {
        $null = Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0
        $tagged = $script:queries | Where-Object { $_ -match 'union' } | Select-Object -First 1
        $tagged | Should -Match "tostring\(tags.deploymentId\) == 'abc123' or \(tostring\(tags.solution\) =~ 'fabric-database-hub-demo' and tostring\(tags.environment\) =~ 'demo'\)"
        $tagged | Should -Match "resources \| where .* \| where resourceGroup !~ 'rg-dbhub-control'"
        $tagged | Should -Match "resourcecontainers \| where .* \| where name !~ 'rg-dbhub-control'"
        $arc = $script:queries | Where-Object { $_ -match 'hybridcompute' } | Select-Object -First 1
        $arc | Should -Match "resourceGroup =~ 'rg-dbhub-demo'"
        $arc | Should -Match "contains '/resourcegroups/rg-dbhub-demo/'"
        $arc | Should -Match "tostring\(tags.deploymentId\) == 'abc123'"
        $arc | Should -Match 'microsoft.azurearcdata/sqlserverinstances'
        $arc | Should -Match 'microsoft.hybridcompute/machines/extensions'
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

    It 'counts role assignments at the group, under it, or for its identities, and none of another group' {
        $group = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/rg-dbhub-demo'
        $script:graph['roleassignments'] = New-GraphResult -Rows @(
            [pscustomobject]@{ id = 'ra-group'; assignmentScope = $group; principalId = 'dddddddd-1111-2222-3333-444444444444' }
            [pscustomobject]@{ id = 'ra-child'; assignmentScope = $group + '/providers/microsoft.compute/virtualmachines/sqlvm01'; principalId = 'dddddddd-1111-2222-3333-444444444444' }
            [pscustomobject]@{ id = 'ra-other-group'; assignmentScope = $group + '2'; principalId = 'dddddddd-1111-2222-3333-444444444444' }
            [pscustomobject]@{ id = 'ra-identity'; assignmentScope = '/subscriptions/11111111-2222-3333-4444-555555555555'; principalId = 'aaaaaaaa-1111-2222-3333-444444444444' }
        )
        $results = @(Test-DemoTeardownResidue -Config $config -Manifest (New-TestManifest) -WaitMinutes 0)
        $assignments = $results | Where-Object { $_.checkId -eq 'TEARDOWN.RESIDUAL.ROLEASSIGNMENTS' }
        $assignments.status | Should -Be 'Fail'
        $assignments.evidence.remaining | Should -Be @('ra-group', 'ra-child', 'ra-identity')
        ($script:queries | Where-Object { $_ -match 'roleassignments' } | Select-Object -First 1) | Should -Match "principalId in \('aaaaaaaa-1111-2222-3333-444444444444', 'bbbbbbbb-1111-2222-3333-444444444444'\)"
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
        $script:order | Should -Be @('vm show --resource-group', 'Manifest', 'group delete --name', 'deployment sub show', 'deployment sub delete', 'rest --method get', 'rest --method delete', 'Residue:abc123')
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
        $residual.remediation | Should -Match 'Invoke-TeardownTest\.ps1'
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
        $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
        $guard = $results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN.GUARD' }
        $guard.status | Should -Be 'Fail'
        $guard.remediation | Should -Match '-WithoutGolden'
        $script:order | Should -Not -Contain 'group delete --name'
        $script:order | Should -Not -Contain 'Manifest'
        Get-DemoExitCode -Result $results | Should -Be 1
    }

    It 'deletes a PaygWizard host that a boot-verified golden snapshot keeps, and keeps the golden group' {
        $script:hostName = 'archost01'
        $script:goldenGroupExists = $true
        $script:goldenSnapshots = @([pscustomobject]@{ Name = 'snap-dbhub-t2golden-202601010000'; BootVerifiedUtc = [datetime]'2026-01-01'; EvalDaysLeft = 100 })
        $results = @(Remove-DemoEnvironment -Config $config -Confirm:$false)
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
        ($(Remove-DemoEnvironment -Config $config -Confirm:$false) | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN.GUARD' }).status | Should -Be 'Fail'
    }

    It 'accepts losing the wizard state with -WithoutGolden, as a Warning' {
        $script:hostName = 'archost01'
        $results = @(Remove-DemoEnvironment -Config $config -WithoutGolden -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN.GUARD' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).status | Should -Be 'Pass'
    }

    It 'skips the guard when the environment has no PaygWizard install' {
        $script:hostName = 'archost01'
        $developer = New-TestConfig
        $developer['t2SqlInstallMode'] = 'Developer'
        $results = @(Remove-DemoEnvironment -Config $developer -Confirm:$false)
        $results | Where-Object { $_.checkId -eq 'DESTROY.GOLDEN.GUARD' } | Should -BeNullOrEmpty
        $script:order | Should -Not -Contain 'vm show --resource-group'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).status | Should -Be 'Pass'
    }

    It 'deletes the golden group too with -IncludeGolden' {
        $script:hostName = 'archost01'
        $script:goldenGroupExists = $true
        $script:goldenSnapshots = @([pscustomobject]@{ Name = 'snap-dbhub-t2golden-202601010000'; BootVerifiedUtc = [datetime]'2026-01-01'; EvalDaysLeft = 100 })
        $results = @(Remove-DemoEnvironment -Config $config -IncludeGolden -Confirm:$false)
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
