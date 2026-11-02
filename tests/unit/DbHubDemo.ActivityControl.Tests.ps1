BeforeAll {
    # The on-demand activity control's module side (ADR 0020): names, the approved role and assignments, the vault mode,
    # the webhook's secrecy, -WhatIf, -Remove, deploy.ps1's A1 re-grant, validation, status, and cost. Azure is a fake
    # behind Invoke-DemoAzCli, so Invoke-DemoAz (the subscription guard) and the private body files run for real. IDs
    # are placeholders, and the webhook URL is built at run time so that no scanner finds one in the repository.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')

    $script:sub = '11111111-2222-3333-4444-555555555555'
    $script:callerId = 'aaaaaaaa-0000-0000-0000-000000000001'
    $script:identityPrincipal = 'dddddddd-0000-0000-0000-000000000004'
    $script:customRoleId = 'eeeeeeee-0000-0000-0000-000000000005'
    $script:approvedActions = @(
        'Microsoft.Resources/subscriptions/resourceGroups/read'
        'Microsoft.Compute/virtualMachines/read'
        'Microsoft.Compute/virtualMachines/instanceView/read'
        'Microsoft.Compute/virtualMachines/start/action'
        'Microsoft.Compute/virtualMachines/deallocate/action'
        'Microsoft.Compute/virtualMachines/extensions/read'
        'Microsoft.Compute/virtualMachines/runCommands/read'
        'Microsoft.Compute/virtualMachines/runCommands/write'
        'Microsoft.Compute/virtualMachines/runCommands/delete'
        'Microsoft.Sql/servers/databases/read'
        'Microsoft.DBforPostgreSQL/flexibleServers/read'
        'Microsoft.DBforPostgreSQL/flexibleServers/start/action'
        'Microsoft.DBforPostgreSQL/flexibleServers/stop/action'
        'Microsoft.Automation/automationAccounts/read'
        'Microsoft.Automation/automationAccounts/runbooks/read'
        'Microsoft.Automation/automationAccounts/jobs/read'
        'Microsoft.Automation/automationAccounts/schedules/read'
        'Microsoft.Automation/automationAccounts/schedules/write'
        'Microsoft.Automation/automationAccounts/schedules/delete'
        'Microsoft.Automation/automationAccounts/jobSchedules/read'
        'Microsoft.Automation/automationAccounts/jobSchedules/write'
        'Microsoft.Automation/automationAccounts/jobSchedules/delete'
    )

    function New-ControlConfig([bool] $Enabled = $true, [bool] $AssignRoles = $false, [string] $Mode = 'auto') {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = $script:sub
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['assignRoles'] = $AssignRoles
        $config['autoShutdownTime'] = '1900'
        $config['autoShutdownTimeZone'] = 'Eastern Standard Time'
        $config['control']['enabled'] = $Enabled
        $config['control']['vaultNetworkMode'] = $Mode
        $config['fabric']['workspaceId'] = 'abcdabcd-abcd-abcd-abcd-abcdabcdabcd'
        return $config
    }

    function New-AzResult([int] $ExitCode = 0, [string] $StdOut = '', [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
    }

    function Get-ArgumentValue([object[]] $Arguments, [string] $Name) {
        $index = [array]::IndexOf($Arguments, $Name)
        if ($index -ge 0 -and $index + 1 -lt $Arguments.Count) {
            return [string]$Arguments[$index + 1]
        }
        return ''
    }

    function Get-ControlName([System.Collections.IDictionary] $Config) {
        InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $Config } { Get-DemoActivityControlName -Config $Config }
    }

    function New-TestWebhookUrl {
        $token = [System.Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(30)).Replace('+', '%2b').Replace('/', '%2f').Replace('=', '%3d')
        return ('https://{0}.webhook.wus3.{1}/webhooks?token={2}' -f [guid]::NewGuid().ToString('N'), ('azure-' + 'automation.net'), $token)
    }

    function Get-NotFound([string] $What) {
        return (New-AzResult -ExitCode 3 -StdErr ("ERROR: (ResourceNotFound) The Resource '{0}' was not found." -f $What))
    }

    function New-TestSecureString {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in [guid]::NewGuid().ToString('N').ToCharArray()) {
            $secure.AppendChar($character)
        }
        return $secure
    }

    # The fake Azure Resource Manager behind 'az rest'. -Query is what --url-parameters carried.
    function Invoke-FakeArm([string] $Method, [string] $Url, [string] $Body, [string] $Query = '') {
        $path = ([uri]$Url).AbsolutePath
        $query = [uri]::UnescapeDataString(([uri]$Url).Query) + $Query
        switch -Regex ($path) {
            '/providers/Microsoft\.Authorization/permissions$' {
                $actions = if ($script:canAssign) { @('*') } else { @('*/read') }
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = @(@{ actions = $actions; notActions = @() }) } -Depth 5))
            }
            '/providers/Microsoft\.Authorization/roleDefinitions$' {
                if ($script:roleReadFails) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (AuthorizationFailed) The client has no access.')
                }
                $value = @(if ($script:roleExists) { @{ name = $script:customRoleId; properties = @{ roleName = 'DbHub Demo Activity Operator' } } })
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = $value } -Depth 5))
            }
            '/providers/Microsoft\.Authorization/roleDefinitions/([0-9a-f-]+)$' {
                if ($Method -eq 'put') {
                    $script:roleExists = $true
                    $script:customRoleId = $Matches[1]
                }
                elseif ($Method -eq 'delete') {
                    $script:roleExists = $false
                }
                return (New-AzResult -StdOut '{}')
            }
            '/userAssignedIdentities/' {
                if (-not $script:identityExists) {
                    return (Get-NotFound 'id-dbhub-automation')
                }
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ properties = @{ principalId = $script:identityPrincipal } }))
            }
            '^(?<scope>.+)/providers/Microsoft\.Authorization/roleAssignments$' {
                $scope = $Matches['scope']
                if ($scope -match '/resourceGroups/rg-dbhub-demo$' -and -not $script:demoGroupExists) {
                    return (New-AzResult -ExitCode 3 -StdErr "ERROR: (ResourceGroupNotFound) Resource group 'rg-dbhub-demo' could not be found.")
                }
                if ($scope -match '/secrets/' -and -not $script:secretExists) {
                    return (Get-NotFound 'dbhub-activity-webhook')
                }
                $value = @($script:assignments | Where-Object {
                        ($query -match 'atScope\(\)' -and $_.scope -eq $scope) -or
                        ($query -match "principalId eq '([0-9a-f-]+)'" -and $_.principalId -eq $Matches[1] -and ($_.scope -eq $scope -or $_.scope.StartsWith($scope + '/')))
                    } | ForEach-Object { @{ id = ('{0}/providers/Microsoft.Authorization/roleAssignments/{1}' -f $_.scope, $_.name); properties = @{ scope = $_.scope; roleDefinitionId = $_.roleDefinitionId; principalId = $_.principalId } } })
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = $value } -Depth 6))
            }
            '^(?<scope>.+)/providers/Microsoft\.Authorization/roleAssignments/(?<name>[0-9a-f-]+)$' {
                $scope = $Matches['scope']
                $name = $Matches['name']
                if ($Method -eq 'put') {
                    $properties = ($Body | ConvertFrom-Json -AsHashtable)['properties']
                    $script:assignments.Add([pscustomobject]@{ name = $name; scope = $scope; roleDefinitionId = $properties['roleDefinitionId']; principalId = $properties['principalId']; principalType = $properties['principalType'] })
                }
                elseif ($Method -eq 'delete') {
                    $script:assignments = [System.Collections.Generic.List[object]]@($script:assignments | Where-Object { $_.name -ne $name })
                }
                return (New-AzResult -StdOut '{}')
            }
            '/automationAccounts/aa-dbhub-control$' {
                if (-not $script:accountExists) {
                    return (Get-NotFound 'aa-dbhub-control')
                }
                return (New-AzResult -StdOut '{"name":"aa-dbhub-control"}')
            }
            '/runbooks/(DbHub-Control|DbHub-Stop)$' {
                return (New-AzResult -StdOut '{"properties":{"state":"Published"}}')
            }
            '/privateEndpointConnections$' {
                $value = @(foreach ($connection in $script:connections) { @{ id = ('{0}/{1}' -f $path, $connection.name); properties = @{ privateLinkServiceConnectionState = @{ status = $connection.status; description = $connection.description } } } })
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = $value } -Depth 8))
            }
            '/privateEndpointConnections/(?<connection>[^/]+)$' {
                $connectionName = $Matches['connection']
                if ($Method -eq 'put') {
                    $state = ($Body | ConvertFrom-Json -AsHashtable)['properties']['privateLinkServiceConnectionState']
                    foreach ($connection in @($script:connections | Where-Object name -EQ $connectionName)) {
                        $connection.status = $state['status']
                        $connection.description = $state['description']
                    }
                }
                return (New-AzResult -StdOut '{}')
            }
            '/vaults/kv-dbhub-ctl-[0-9a-f]{6}$' {
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ properties = @{ publicNetworkAccess = $script:vaultAccess } }))
            }
            '/secrets/dbhub-activity-webhook$' {
                if (-not $script:secretExists) {
                    return (Get-NotFound 'dbhub-activity-webhook')
                }
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ properties = @{ attributes = @{ exp = [DateTimeOffset]::new($script:webhookExpiry).ToUnixTimeSeconds() } } } -Depth 4))
            }
            '/webhooks/generateUri$' {
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject $script:webhookUrl))
            }
            '/webhooks$' {
                $value = @($script:webhooks | ForEach-Object { @{ name = $_; properties = @{ isEnabled = $true; expiryTime = $script:webhookExpiry.ToString('o'); runbook = @{ name = 'DbHub-Control' } } } })
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = $value } -Depth 6))
            }
            '/webhooks/' {
                return (New-AzResult -StdOut '{}')
            }
            '/schedules/dbhub-autostop$' {
                if ($Method -eq 'delete' -and $script:autoStopDeleteFails) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (AuthorizationFailed) The client has no access to delete the schedule.')
                }
                if (-not $script:autoStop) {
                    return (Get-NotFound 'dbhub-autostop')
                }
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ properties = @{ startTime = $script:autoStop.ToString('o') } }))
            }
            '/schedules/dbhub-t4-safety-stop$' {
                if (-not $script:safetyStop) {
                    return (Get-NotFound 'dbhub-t4-safety-stop')
                }
                # Azure Automation reports the zone in its IANA form, whatever form it was given (Phase 25d, live).
                return (New-AzResult -StdOut '{"properties":{"isEnabled":true,"timeZone":"America/New_York","nextRun":"2026-10-27T23:15:00Z"}}')
            }
            '/automationAccounts/aa-dbhub-control/jobs$' {
                # An old finished DbHub-Stop job and a running DbHub-Control job are always listed; $script:stopJobStates
                # gives a DbHub-Stop job's status for each read, the last one repeating.
                $script:jobReads++
                if (-not $script:accountExists) {
                    return (Get-NotFound 'aa-dbhub-control')
                }
                if ($script:jobsReadFailAt -gt 0 -and $script:jobReads -ge $script:jobsReadFailAt) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (AuthorizationFailed) The client has no access to read the jobs.')
                }
                $value = [System.Collections.Generic.List[object]]::new()
                $value.Add(@{ properties = @{ jobId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'; status = 'Completed'; runbook = @{ name = 'DbHub-Stop' } } })
                $value.Add(@{ properties = @{ jobId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'; status = 'Running'; runbook = @{ name = 'DbHub-Control' } } })
                $states = @($script:stopJobStates)
                if ($states.Count -gt 0) {
                    $value.Add(@{ properties = @{ jobId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; status = $states[[Math]::Min($script:jobReads, $states.Count) - 1]; runbook = @{ name = 'DbHub-Stop' } } })
                }
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = $value.ToArray() } -Depth 6))
            }
            '/jobSchedules$' {
                $value = @(
                    if ($script:safetyStop -and $script:safetyStopLinked) { @{ properties = @{ jobScheduleId = 'ffffffff-0000-0000-0000-000000000006'; schedule = @{ name = 'dbhub-t4-safety-stop' }; runbook = @{ name = 'DbHub-Stop' } } } }
                    if ($script:autoStop) { @{ properties = @{ jobScheduleId = 'ffffffff-0000-0000-0000-000000000007'; schedule = @{ name = 'dbhub-autostop' }; runbook = @{ name = 'DbHub-Stop' } } } }
                )
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ value = $value } -Depth 6))
            }
            '/deletedVaults/.+/purge$' {
                return (New-AzResult -StdOut '{}')
            }
        }
        if ($Method -in 'put', 'post', 'delete', 'patch') {
            return (New-AzResult -StdOut '{}')
        }
        return (Get-NotFound $path)
    }

    function Reset-FakeAzure {
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:ops = [System.Collections.Generic.List[string]]::new()
        $script:policyRules = @()
        $script:rest = [System.Collections.Generic.List[object]]::new()
        $script:bodyFiles = [System.Collections.Generic.List[string]]::new()
        $script:deployments = [System.Collections.Generic.List[object]]::new()
        $script:assignments = [System.Collections.Generic.List[object]]::new()
        $script:canAssign = $true
        $script:roleExists = $true
        $script:roleReadFails = $false
        $script:customRoleId = 'eeeeeeee-0000-0000-0000-000000000005'
        $script:identityExists = $true
        $script:demoGroupExists = $true
        $script:secretExists = $true
        $script:accountExists = $true
        $script:groupExists = $true
        $script:leftInGroup = 0
        $script:vaultAccess = 'Enabled'
        $script:webhooks = @()
        $script:webhookExpiry = [datetime]::new(2027, 1, 25, 15, 0, 0, [System.DateTimeKind]::Utc)
        $script:webhookUrl = ''
        $script:autoStop = $null
        $script:autoStopDeleteFails = $false
        $script:stopJobStates = @()
        $script:jobReads = 0
        $script:jobsReadFailAt = 0
        $script:safetyStop = $true
        $script:safetyStopLinked = $true
        $script:connections = [System.Collections.Generic.List[object]]::new()
    }

    function Register-FakeAzure {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logs.Add([string]$Message) }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $words = @($ArgumentList)
            $text = $words -join ' '
            $script:azCalls.Add($text)
            # The real Invoke-DemoAzCli refuses these (ConvertTo-DemoBatchArgument): cmd.exe can't pass them to az.cmd
            # (Phase 25d, live: the role checks' encoded filters failed that way, which this mock didn't catch).
            foreach ($word in $words) {
                if ([string]$word -match '["%]') {
                    throw "An Azure CLI argument contains '`"' or '%', which cmd.exe can't pass to az.cmd unchanged. Put the value in a file and pass '@<path>' instead."
                }
            }
            if ($words[0] -eq 'rest') {
                $bodyText = ''
                $bodyArgument = Get-ArgumentValue $words '--body'
                if ($bodyArgument) {
                    $file = $bodyArgument.Substring(1)
                    $script:bodyFiles.Add($file)
                    $bodyText = Get-Content -LiteralPath $file -Raw
                }
                $queryText = ''
                $queryArgument = Get-ArgumentValue $words '--url-parameters'
                if ($queryArgument) {
                    $parameters = Get-Content -LiteralPath $queryArgument.Substring(1) -Raw | ConvertFrom-Json -AsHashtable
                    $queryText = '?' + ((@($parameters.Keys) | ForEach-Object { '{0}={1}' -f $_, $parameters[$_] }) -join '&')
                }
                $script:rest.Add([pscustomobject]@{ Method = (Get-ArgumentValue $words '--method'); Url = (Get-ArgumentValue $words '--url'); Query = $queryText; Body = $bodyText })
                if ((Get-ArgumentValue $words '--method') -ne 'get') {
                    $script:ops.Add(('arm {0} {1}' -f (Get-ArgumentValue $words '--method'), ([uri](Get-ArgumentValue $words '--url')).AbsolutePath))
                }
                return (Invoke-FakeArm -Method (Get-ArgumentValue $words '--method') -Url (Get-ArgumentValue $words '--url') -Body $bodyText -Query $queryText)
            }
            switch -Wildcard ($text) {
                'provider show*' { return (New-AzResult -StdOut "Registered`n") }
                'group exists*' { return (New-AzResult -StdOut ($(if ($script:groupExists) { 'true' } else { 'false' }) + "`n")) }
                'deployment group create*' {
                    $file = (Get-ArgumentValue $words '--parameters').Substring(1)
                    $script:deployments.Add([pscustomobject]@{ Text = $text; File = $file; Parameters = (Get-Content -LiteralPath $file -Raw) })
                    return (New-AzResult -StdOut '{"identityClientId":{"value":"99999999-9999-9999-9999-999999999999"}}')
                }
                'deployment group delete*' { return (New-AzResult) }
                'resource list*' { return (New-AzResult -StdOut ("{0}`n" -f $script:leftInGroup)) }
                'group delete*' { return (New-AzResult) }
            }
            return (New-AzResult -ExitCode 1 -StdErr ('ERROR: the fake has no answer for: {0}' -f $text))
        }
    }
}

Describe 'The control''s names' {
    It 'derives the vault''s suffix from the subscription and prefix, so its global name is stable' {
        $name = Get-ControlName (New-ControlConfig)
        $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes(('{0}|dbhub|control' -f $script:sub)))
        $suffix = -join ($hash[0..2] | ForEach-Object { $_.ToString('x2') })
        $name.KeyVault | Should -Be ('kv-dbhub-ctl-{0}' -f $suffix)
        $name.ResourceGroup | Should -Be 'rg-dbhub-control'
        $name.AutomationAccount | Should -Be 'aa-dbhub-control'
        $name.Identity | Should -Be 'id-dbhub-automation'
        $name.DemoResourceGroupId | Should -Be ('/subscriptions/{0}/resourceGroups/rg-dbhub-demo' -f $script:sub)
        $name.SecretId | Should -Be ('/subscriptions/{0}/resourceGroups/rg-dbhub-control/providers/Microsoft.KeyVault/vaults/kv-dbhub-ctl-{1}/secrets/dbhub-activity-webhook' -f $script:sub, $suffix)
        $upper = New-ControlConfig
        $upper['subscriptionId'] = $script:sub.ToUpperInvariant()
        (Get-ControlName $upper).KeyVault | Should -Be $name.KeyVault
    }

    It 'fits Key Vault''s 24-character limit with the longest prefix the schema allows' {
        $config = New-ControlConfig
        $config['prefix'] = 'abcdefgh'
        (Get-ControlName $config).KeyVault.Length | Should -BeLessOrEqual 24
    }

    It 'tags the control without environment or deploymentId, so destroy.ps1''s residual check never matches it' {
        $tags = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig) } { Get-DemoActivityControlTag -Config $Config }
        $tags['component'] | Should -Be 'activity-control'
        $tags.Contains('environment') | Should -BeFalse
        $tags.Contains('deploymentId') | Should -BeFalse
    }
}

Describe 'The custom role "DbHub Demo Activity Operator" (owner-approved, 2026-10-26)' {
    It 'has exactly the approved actions and nothing else' {
        $definition = InModuleScope -ModuleName DbHubDemo -Parameters @{ Sub = $script:sub } { Get-DemoActivityControlRoleDefinition -SubscriptionId $Sub }
        $permissions = $definition['properties']['permissions']
        @($permissions).Count | Should -Be 1
        @($permissions[0]['actions']) | Should -Be $script:approvedActions
        @($permissions[0]['notActions']).Count | Should -Be 0
        @($permissions[0]['dataActions']).Count | Should -Be 0
        @($permissions[0]['notDataActions']).Count | Should -Be 0
        @($definition['properties']['assignableScopes']) | Should -Be @(('/subscriptions/{0}' -f $script:sub))
        foreach ($action in $permissions[0]['actions']) {
            $action | Should -Not -Match '\*' -Because 'no wildcard'
            $action | Should -Not -Match '^Microsoft\.Authorization/' -Because 'it never grants roles'
            $action | Should -Not -Match 'runCommand/action' -Because 'the runbook uses managed Run Command only'
        }
    }

    It 'matches the list ADR 0020 records' {
        $adr = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'docs/adr/0020-on-demand-activity-control.md') -Raw
        $section = [regex]::Match($adr, '(?s)### The role\b(.+?)(?=\n### |\n## |\z)').Groups[1].Value
        $section | Should -Not -BeNullOrEmpty
        $listed = @([regex]::Matches($section, '`(Microsoft\.[A-Za-z]+/[A-Za-z/]+)`') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        @($listed | Sort-Object) | Should -Be @($script:approvedActions | Sort-Object)
    }

    It 'plans A1, A2, and A3 at exactly their approved scopes' {
        $config = New-ControlConfig
        $config['control']['notebookUserObjectIds'] = @('BBBBBBBB-0000-0000-0000-000000000002', $script:callerId)
        $name = Get-ControlName $config
        $plan = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config; Name = $name; Role = $script:customRoleId; Principal = $script:identityPrincipal; Caller = $script:callerId } {
                Get-DemoActivityControlGrantPlan -Name $Name -Config $Config -RoleId $Role -PrincipalId $Principal -CallerObjectId $Caller -CallerPrincipalType 'User'
            })
        @($plan | ForEach-Object Id) | Should -Be @('A1', 'A2', 'A3', 'A3')
        $plan[0].Scope | Should -Be $name.DemoResourceGroupId
        $plan[0].PrincipalId | Should -Be $script:identityPrincipal
        $plan[0].PrincipalType | Should -Be 'ServicePrincipal'
        $plan[0].Role | Should -Be 'DbHub Demo Activity Operator'
        $plan[1].Scope | Should -Be $name.AutomationAccountId
        $plan[1].PrincipalType | Should -Be 'ServicePrincipal'
        foreach ($item in $plan[2..3]) {
            $item.Scope | Should -Be $name.SecretId
            $item.Role | Should -Be 'Key Vault Secrets User'
            $item.RoleDefinitionId | Should -Match '/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6$'
        }
        $plan[2].PrincipalId | Should -Be $script:callerId
        $plan[2].PrincipalType | Should -Be 'User'
        $plan[3].PrincipalId | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002' -Because 'the caller is listed once'
        @(InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config; Name = $name } { Get-DemoActivityControlGrantPlan -Name $Name -Config $Config -RoleId 'x' -PrincipalId 'y' -Assignment 'A1' }).Count | Should -Be 1
    }
}

Describe 'The vault''s network mode (control.vaultNetworkMode)' {
    BeforeAll {
        # Shaped like a tenant's Key Vault network policy assignment (2026-10-26 probe), with placeholder names.
        $script:modifyRule = [pscustomobject]@{
            Policy = 'Key Vaults should disable public network access (example)'; Effect = 'Modify'; Types = @('Microsoft.KeyVault/vaults'); AnyType = $false
            Fields = @('Microsoft.KeyVault/vaults/publicNetworkAccess'); Condition = @{}
            Then = @{ details = @{ operations = @(@{ field = 'Microsoft.KeyVault/vaults/publicNetworkAccess'; operation = 'addOrReplace'; value = 'Disabled' }) }; effect = "[parameters('effect')]" }
            Parameters = @{ AllowedTagName = 'ExampleControl'; AllowedTagValue = 'Ignore'; effect = 'modify' }
        }
        $script:hsmRule = [pscustomobject]@{
            Policy = 'Managed HSMs need purge protection (example)'; Effect = 'Deny'; Types = @('Microsoft.KeyVault/managedHSMs'); AnyType = $false
            Fields = @('Microsoft.KeyVault/managedHsms/enablePurgeProtection'); Condition = @{ field = 'type'; equals = 'Microsoft.KeyVault/managedHSMs' }; Then = @{}; Parameters = @{}
        }
        $script:denyRule = [pscustomobject]@{
            Policy = 'Deny public vaults (example)'; Effect = 'Deny'; Types = @('Microsoft.KeyVault/vaults'); AnyType = $false
            Fields = @('Microsoft.KeyVault/vaults/publicNetworkAccess')
            Condition = @{ allOf = @(@{ field = 'type'; equals = 'Microsoft.KeyVault/vaults' }, @{ field = 'Microsoft.KeyVault/vaults/publicNetworkAccess'; notEquals = 'Disabled' }) }
            Then = @{}; Parameters = @{}
        }
        $script:storageRule = [pscustomobject]@{
            Policy = 'Storage example'; Effect = 'Modify'; Types = @('Microsoft.Storage/storageAccounts'); AnyType = $false; Fields = @(); Condition = @{}
            Then = @{ details = @{ operations = @(@{ field = 'Microsoft.Storage/storageAccounts/publicNetworkAccess'; operation = 'addOrReplace'; value = 'Disabled' }) } }; Parameters = @{}
        }
        $script:unresolvedRule = [pscustomobject]@{
            Policy = 'Parameterized example'; Effect = 'Modify'; Types = @('Microsoft.KeyVault/vaults'); AnyType = $false; Fields = @(); Condition = @{}
            Then = @{ details = @{ operations = @(@{ field = 'Microsoft.KeyVault/vaults/publicNetworkAccess'; operation = 'addOrReplace'; value = "[parameters('access')]" }) } }; Parameters = @{}
        }
        function Resolve-Mode([string] $Mode, [object[]] $Rule = @(), [switch] $Unknown) {
            InModuleScope -ModuleName DbHubDemo -Parameters @{ Mode = $Mode; Rule = $Rule; Unknown = [bool]$Unknown } { Resolve-DemoActivityControlVaultMode -ConfiguredMode $Mode -Rule $Rule -PolicyUnknown:$Unknown }
        }
    }

    It '<Case>' -ForEach @(
        @{ Case = 'auto with no forcing policy: public (a folder of the existing workspace)'; Mode = 'auto'; Rules = 'none'; Unknown = $false; Expected = 'public'; Status = 'Pass' }
        @{ Case = 'auto with a Modify to Disabled: private (the DBHub Control workspace)'; Mode = 'auto'; Rules = 'modify'; Unknown = $false; Expected = 'private'; Status = 'Pass' }
        @{ Case = 'auto with a Deny on public vaults: private'; Mode = 'auto'; Rules = 'deny'; Unknown = $false; Expected = 'private'; Status = 'Pass' }
        @{ Case = 'auto with a Modify to a value it can''t resolve: private'; Mode = 'auto'; Rules = 'unresolved'; Unknown = $false; Expected = 'private'; Status = 'Pass' }
        @{ Case = 'auto with policies for other types only: public'; Mode = 'auto'; Rules = 'others'; Unknown = $false; Expected = 'public'; Status = 'Pass' }
        @{ Case = 'auto when the policy can''t be read: private, with a Warning'; Mode = 'auto'; Rules = 'none'; Unknown = $true; Expected = 'private'; Status = 'Warning' }
        @{ Case = 'private: private whatever the policy says'; Mode = 'private'; Rules = 'none'; Unknown = $false; Expected = 'private'; Status = 'Pass' }
        @{ Case = 'public with no forcing policy: public'; Mode = 'public'; Rules = 'others'; Unknown = $false; Expected = 'public'; Status = 'Pass' }
        @{ Case = 'public when the policy can''t be read: public, with a Warning'; Mode = 'public'; Rules = 'none'; Unknown = $true; Expected = 'public'; Status = 'Warning' }
        @{ Case = 'public where a Modify would flip the vault: Fail, and nothing is created'; Mode = 'public'; Rules = 'modify'; Unknown = $false; Expected = 'public'; Status = 'Fail' }
    ) {
        $rules = switch ($Rules) {
            'modify' { @($script:modifyRule, $script:hsmRule) }
            'deny' { @($script:denyRule) }
            'unresolved' { @($script:unresolvedRule) }
            'others' { @($script:hsmRule, $script:storageRule) }
            default { @() }
        }
        $result = Resolve-Mode -Mode $Mode -Rule $rules -Unknown:$Unknown
        $result.Mode | Should -Be $Expected
        $result.Status | Should -Be $Status
        $result.Evidence['configuredMode'] | Should -Be $Mode
        $result.DocUrl | Should -Be 'https://learn.microsoft.com/fabric/security/security-managed-vnets-fabric-overview'
    }

    It 'names the forcing policy and its exclusion tag, and never offers to add the tag' {
        $result = Resolve-Mode -Mode 'public' -Rule @($script:modifyRule)
        $result.Evidence['forcingPolicies'] | Should -Be @('Key Vaults should disable public network access (example) (Modify)')
        $result.Evidence['exclusionTags'] | Should -Be @('ExampleControl=Ignore')
        $result.Message | Should -Match 'never adds that tag'
        $result.Remediation | Should -Match 'auto or private'
    }
}

Describe 'The runbooks'' settings' {
    It 'hold the allow-lists from the scenario catalog, the bounds, the pinned API versions, and the template, and no secret' {
        $config = New-ControlConfig
        $setting = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config } { Get-DemoActivityControlRunbookSetting -Config $Config -Name (Get-DemoActivityControlName -Config $Config) -IdentityClientId '99999999-9999-9999-9999-999999999999' }
        @($setting['targets'].Keys) | Should -Be @('T1', 'T2', 'T3', 'T4')
        $setting['scenarios'].Contains('healthy-baseline') | Should -BeFalse
        $folders = @(Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scenarios') -Directory | Where-Object Name -NE 'healthy-baseline' | ForEach-Object Name)
        @($setting['scenarios'].Keys | Sort-Object) | Should -Be @($folders | Sort-Object)
        $setting['minDurationMinutes'] | Should -Be 5
        $setting['maxDurationMinutes'] | Should -Be 120
        $setting['maxBodyBytes'] | Should -Be 4096
        $setting['autoStopBufferMinutes'] | Should -Be 10
        $setting['shutdownMarginMinutes'] | Should -Be 2
        foreach ($type in $setting['apiVersions'].Keys) {
            $setting['apiVersions'][$type] | Should -Match '^\d{4}-\d{2}-\d{2}(-preview)?$' -Because $type
        }
        $setting['controlScriptTemplate'] | Should -Match '__REQUEST__'
        $setting['controlScriptTemplate'] | Should -Not -Match '__ACTION__'
        $setting['controlScriptTemplate'] | Should -Match "-Action 'Runner'"
        $json = ConvertTo-Json -InputObject $setting -Depth 16 -Compress
        $json | Should -Not -Match '(?i)"[^"]*(password|secret|token)[^"]*"\s*:' -Because 'no setting is a credential'
        $json | Should -Not -Match '(?i)token=|vault\.azure\.net'
    }
}

Describe 'Granting the roles (setup-activity-control.ps1 -GrantRole)' {
    BeforeEach {
        Reset-FakeAzure
        $script:logs = [System.Collections.Generic.List[string]]::new()
        Register-FakeAzure
        Initialize-GuardTestContext -ObjectId $script:callerId
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { [pscustomobject]@{ checkId = 'PREFLIGHT.GUARD.CONTEXT'; status = 'Pass'; message = 'ok'; remediation = '' } }
    }

    It 'creates the role with exactly the approved actions, then assigns A1, A2, and A3 at their scopes only' {
        $script:roleExists = $false
        $config = New-ControlConfig
        $name = Get-ControlName $config
        $results = @(Invoke-DemoActivityControlSetup -Config $config -ConfigPath './config/demo.config.json' -GrantRole -Confirm:$false)
        $definition = @($script:rest | Where-Object { $_.Method -eq 'put' -and $_.Url -match '/roleDefinitions/' })
        $definition.Count | Should -Be 1
        $body = $definition[0].Body | ConvertFrom-Json -AsHashtable
        @($body['properties']['permissions'][0]['actions']) | Should -Be $script:approvedActions
        @($body['properties']['assignableScopes']) | Should -Be @(('/subscriptions/{0}' -f $script:sub))
        @($script:assignments | ForEach-Object scope) | Should -Be @($name.DemoResourceGroupId, $name.AutomationAccountId, $name.SecretId)
        $script:assignments[0].principalId | Should -Be $script:identityPrincipal
        $script:assignments[0].principalType | Should -Be 'ServicePrincipal'
        $script:assignments[1].principalType | Should -Be 'ServicePrincipal'
        $script:assignments[2].principalId | Should -Be $script:callerId
        $script:assignments[2].principalType | Should -Be 'User'
        $script:assignments[2].roleDefinitionId | Should -Match '/4633458b-17de-408a-b874-0445c86b69e6$'
        foreach ($id in 'CONTROL.ROLE.DEFINITION', 'CONTROL.ROLE.A1', 'CONTROL.ROLE.A2', 'CONTROL.ROLE.A3') {
            ($results | Where-Object checkId -EQ $id).status | Should -Be 'Pass' -Because $id
        }
        foreach ($file in $script:bodyFiles) {
            Test-Path -LiteralPath $file | Should -BeFalse -Because 'each request body''s private file is deleted'
        }
    }

    It 'keeps assignments that exist, and writes nothing then' {
        $config = New-ControlConfig
        $name = Get-ControlName $config
        $role = '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $script:sub, $script:customRoleId
        $script:assignments.Add([pscustomobject]@{ name = '1'; scope = $name.DemoResourceGroupId; roleDefinitionId = $role; principalId = $script:identityPrincipal })
        $script:assignments.Add([pscustomobject]@{ name = '2'; scope = $name.AutomationAccountId; roleDefinitionId = $role; principalId = $script:identityPrincipal })
        $script:assignments.Add([pscustomobject]@{ name = '3'; scope = $name.SecretId; roleDefinitionId = ('/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6' -f $script:sub); principalId = $script:callerId })
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config } { Grant-DemoActivityControlRole -Config $Config -Confirm:$false })
        @($script:rest | Where-Object Method -NE 'get') | Should -BeNullOrEmpty
        @($results | Where-Object status -NE 'Pass') | Should -BeNullOrEmpty
    }

    It 'changes nothing with -WhatIf, and says what it would do' {
        $script:roleExists = $false
        $results = @(Invoke-DemoActivityControlSetup -Config (New-ControlConfig) -GrantRole -WhatIf)
        @($script:rest | Where-Object Method -NE 'get') | Should -BeNullOrEmpty
        foreach ($id in 'CONTROL.ROLE.DEFINITION', 'CONTROL.ROLE.A1', 'CONTROL.ROLE.A2', 'CONTROL.ROLE.A3') {
            ($results | Where-Object checkId -EQ $id).status | Should -Be 'Not selected' -Because $id
        }
        ($results | Where-Object checkId -EQ 'CONTROL.ROLE.DEFINITION').message | Should -Match 'Microsoft\.Compute/virtualMachines/deallocate/action'
    }

    It 'reports Manual action required with the exact command when the caller can''t create role assignments' {
        $script:canAssign = $false
        $results = @(Invoke-DemoActivityControlSetup -Config (New-ControlConfig) -ConfigPath './config/demo.config.json' -GrantRole -Confirm:$false)
        @($script:rest | Where-Object Method -NE 'get') | Should -BeNullOrEmpty
        foreach ($id in 'CONTROL.ROLE.DEFINITION', 'CONTROL.ROLE.A1', 'CONTROL.ROLE.A2', 'CONTROL.ROLE.A3') {
            $result = $results | Where-Object checkId -EQ $id
            $result.status | Should -Be 'Manual action required' -Because $id
            $result.remediation | Should -Match ([regex]::Escape('./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -GrantRole'))
        }
    }
}

Describe 'deploy.ps1''s A1 re-grant (Invoke-DemoActivityControlRegrant)' {
    BeforeEach {
        Reset-FakeAzure
        $script:logs = [System.Collections.Generic.List[string]]::new()
        Register-FakeAzure
        Initialize-GuardTestContext -ObjectId $script:callerId
    }

    It 'does nothing when control.enabled is false' {
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig -Enabled $false -AssignRoles $true) } { Invoke-DemoActivityControlRegrant -Config $Config -Confirm:$false })
        $results.Count | Should -Be 0
        $script:azCalls.Count | Should -Be 0
    }

    It 'grants A1 only, with the -GrantRole function, when assignRoles and control.enabled are true' {
        $config = New-ControlConfig -AssignRoles $true
        Mock -ModuleName DbHubDemo -CommandName Grant-DemoActivityControlRole -MockWith { @([pscustomobject]@{ checkId = 'CONTROL.ROLE.A1'; status = 'Pass' }) }
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoActivityControlRegrant -Config $Config -Confirm:$false })
        $results[0].status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Grant-DemoActivityControlRole -Times 1 -Exactly -ParameterFilter { @($Assignment) -join ',' -eq 'A1' -and -not $IncludeDefinition }
    }

    It 'assigns A1 at the demo resource group after a redeploy' {
        $config = New-ControlConfig -AssignRoles $true
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoActivityControlRegrant -Config $Config -Confirm:$false })
        @($results | ForEach-Object checkId) | Should -Be @('CONTROL.ROLE.A1')
        $results[0].status | Should -Be 'Pass'
        @($script:assignments | ForEach-Object scope) | Should -Be @((Get-ControlName $config).DemoResourceGroupId)
        @($script:rest | Where-Object { $_.Method -eq 'put' -and $_.Url -match '/roleDefinitions/' }) | Should -BeNullOrEmpty
    }

    It 'reports Manual action required with the -GrantRole command when <Case>' -ForEach @(
        @{ Case = 'assignRoles is false'; AssignRoles = $false; Setup = { } }
        @{ Case = 'the caller can''t assign roles'; AssignRoles = $true; Setup = { $script:canAssign = $false } }
        @{ Case = 'the role definition is missing'; AssignRoles = $true; Setup = { $script:roleExists = $false } }
        @{ Case = 'the role definitions can''t be read'; AssignRoles = $true; Setup = { $script:roleReadFails = $true } }
    ) {
        & $Setup
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig -AssignRoles $AssignRoles) } { Invoke-DemoActivityControlRegrant -Config $Config -ConfigPath './config/demo.config.json' -Confirm:$false })
        $a1 = $results | Where-Object checkId -EQ $(if ($Case -match 'can''t be read') { 'CONTROL.ROLE.DEFINITION' } else { 'CONTROL.ROLE.A1' })
        $a1.status | Should -Be 'Manual action required'
        $a1.remediation | Should -Match ([regex]::Escape('./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -GrantRole'))
        $script:assignments.Count | Should -Be 0
    }

    It 'reports Manual action required when the grant throws' {
        Mock -ModuleName DbHubDemo -CommandName Grant-DemoActivityControlRole -MockWith { throw 'AADSTS50076: multifactor authentication is required.' }
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig -AssignRoles $true) } { Invoke-DemoActivityControlRegrant -Config $Config -Confirm:$false })
        $results[0].checkId | Should -Be 'CONTROL.ROLE.A1'
        $results[0].status | Should -Be 'Manual action required'
        $results[0].remediation | Should -Match '-GrantRole'
    }

    It 'is called after the Infrastructure stage on both deploy paths, and DEPLOY.SUMMARY lists what needs an Owner' {
        foreach ($file in 'Public/Invoke-DemoDeployment.ps1', 'Private/ParallelDeployment.ps1') {
            $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath ('scripts/modules/DbHubDemo/{0}' -f $file)) -Raw
            $text | Should -Match 'Invoke-DemoActivityControlRegrant -Config \$Config -ConfigPath \$ConfigPath -Confirm:\$false' -Because $file
            # Since Phase 28 both paths build DEPLOY.SUMMARY in one place, which keeps an Owner's step apart from what
            # only a person can confirm.
            $text | Should -Match 'Get-DemoDeploySummary -Result \$all' -Because $file
        }
        $summary = InModuleScope -ModuleName DbHubDemo {
            $grant = New-DemoResult -CheckId 'CONTROL.ROLE.A1' -Area 'workload' -Target 'subscription' -Status 'Manual action required' -Message 'A1 wasn''t granted: the caller isn''t an Owner.' -Remediation 'An Owner of the subscription runs, signed in with multifactor authentication: ./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -GrantRole'
            Get-DemoDeploySummary -Result @($grant)
        }
        $summary.Status | Should -Be 'Manual action required'
        $summary.Message | Should -Match ([regex]::Escape('1 item(s) need you: CONTROL.ROLE.A1: An Owner of the subscription runs, signed in with multifactor authentication: ./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -GrantRole'))
        @($summary.Evidence['manual']).Count | Should -Be 1
    }
}

Describe 'Setting up the control (setup-activity-control.ps1)' {
    BeforeEach {
        Reset-FakeAzure
        $script:logs = [System.Collections.Generic.List[string]]::new()
        Register-FakeAzure
        Initialize-GuardTestContext -ObjectId $script:callerId
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { [pscustomobject]@{ checkId = 'PREFLIGHT.GUARD.CONTEXT'; status = 'Pass'; message = 'ok'; remediation = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoPolicyConstraint -MockWith { [pscustomobject]@{ Rules = @($script:policyRules); Results = @([pscustomobject]@{ checkId = 'PREFLIGHT.POLICY.INVENTORY'; status = 'Pass' }) } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { throw 'a test must not reach Fabric' }
    }

    It 'keeps a daily safety stop that''s already scheduled and linked, though Azure names its zone in IANA form' {
        # Phase 25d, live: the zone came back as America/New_York, the check expected Eastern Standard Time, so a
        # rerun of setup replaced the schedule, and then couldn't link it again with the link's old ID.
        $result = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig) } { Set-DemoActivityControlSafetyStop -Config $Config -Name (Get-DemoActivityControlName -Config $Config) -NowUtc ([datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc)) -Confirm:$false }
        $result.status | Should -Be 'Pass'
        @($script:ops | Where-Object { $_ -match '/(schedules|jobSchedules)/' }) | Should -BeNullOrEmpty
    }

    It 'links the daily safety stop again, each time with a new link ID, when its link is gone' {
        $script:safetyStopLinked = $false
        foreach ($attempt in 1, 2) {
            $result = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig) } { Set-DemoActivityControlSafetyStop -Config $Config -Name (Get-DemoActivityControlName -Config $Config) -NowUtc ([datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc)) -Confirm:$false }
            $result.status | Should -Be 'Pass'
        }
        $links = @($script:ops | Where-Object { $_ -match '^arm put .*/jobSchedules/' } | ForEach-Object { ($_ -split '/')[-1] })
        $links.Count | Should -Be 2
        $links[0] | Should -Not -Be $links[1]
        ($script:rest | Where-Object { $_.Method -eq 'put' -and $_.Url -match '/jobSchedules/' } | Select-Object -First 1).Body | Should -Match '"Scope":\s*"T4"'
    }

    It 'does nothing while control.enabled is false' {
        $results = @(Invoke-DemoActivityControlSetup -Config (New-ControlConfig -Enabled $false))
        $results.Count | Should -Be 1
        $results[0].checkId | Should -Be 'CONTROL.SETUP'
        $results[0].status | Should -Be 'Not selected'
        $script:azCalls.Count | Should -Be 0
    }

    It 'changes nothing with -WhatIf: every step is Not selected' {
        $script:groupExists = $false
        $script:safetyStop = $false
        $results = @(Invoke-DemoActivityControlSetup -Config (New-ControlConfig) -WhatIf)
        @($script:rest | Where-Object Method -NE 'get') | Should -BeNullOrEmpty
        @($script:azCalls | Where-Object { $_ -match '^(group create|provider register|deployment group create|deployment group delete|group delete)' }) | Should -BeNullOrEmpty
        foreach ($id in 'CONTROL.GROUP', 'CONTROL.RESOURCES', 'CONTROL.RUNBOOKS', 'CONTROL.SAFETYSTOP', 'CONTROL.WEBHOOK', 'CONTROL.FABRIC.NOTEBOOK', 'CONTROL.SUMMARY') {
            ($results | Where-Object checkId -EQ $id).status | Should -Be 'Not selected' -Because $id
        }
        ($results | Where-Object checkId -EQ 'CONTROL.MODE').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'CONTROL.FABRIC.NOTEBOOK').message | Should -Match 'folder "DBHub Control"'
    }

    It 'refuses public where a policy would make the vault private, before it creates anything' {
        $script:policyRules = @([pscustomobject]@{ Policy = 'Example'; Effect = 'Modify'; Types = @('Microsoft.KeyVault/vaults'); AnyType = $false; Fields = @(); Condition = @{}; Then = @{ details = @{ operations = @(@{ field = 'Microsoft.KeyVault/vaults/publicNetworkAccess'; value = 'Disabled' }) } }; Parameters = @{} })
        $results = @(Invoke-DemoActivityControlSetup -Config (New-ControlConfig -Mode 'public') -Confirm:$false)
        ($results | Where-Object checkId -EQ 'CONTROL.MODE').status | Should -Be 'Fail'
        $script:azCalls.Count | Should -Be 0
    }

    It 'stores the webhook URL only through the secure template parameter, never in a result or the log' {
        $script:webhookUrl = New-TestWebhookUrl
        $result = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig) } { New-DemoActivityControlWebhook -Config $Config -Name (Get-DemoActivityControlName -Config $Config) -NowUtc ([datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc)) -Confirm:$false }
        $result.status | Should -Be 'Pass'
        $script:deployments.Count | Should -Be 1
        $script:deployments[0].Text | Should -Match 'webhook\.bicep'
        $script:deployments[0].Text | Should -Not -Match 'token='
        ($script:deployments[0].Parameters | ConvertFrom-Json -AsHashtable)['parameters']['webhookUri']['value'] | Should -Be $script:webhookUrl
        Test-Path -LiteralPath $script:deployments[0].File | Should -BeFalse -Because 'the parameters file is deleted'
        $token = ($script:webhookUrl -split 'token=')[1]
        (ConvertTo-Json -InputObject $result -Depth 8) | Should -Not -Match ([regex]::Escape($token))
        ($script:logs -join "`n") | Should -Not -Match ([regex]::Escape($token))
        (Protect-DemoText -Text ('POST {0}' -f $script:webhookUrl)) | Should -Not -Match ([regex]::Escape($token))
        $result.message | Should -Match 'until 2027-01-25'
    }

    It 'replaces only the control''s own older webhooks' {
        $script:webhookUrl = New-TestWebhookUrl
        $script:webhooks = @('dbhub-activity-202607010000', 'someone-elses-webhook')
        $null = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig) } { New-DemoActivityControlWebhook -Config $Config -Name (Get-DemoActivityControlName -Config $Config) -NowUtc ([datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc)) -Confirm:$false }
        @($script:rest | Where-Object Method -EQ 'delete' | ForEach-Object { ([uri]$_.Url).AbsolutePath.Split('/')[-1] }) | Should -Be @('dbhub-activity-202607010000')
    }

    It 'fails without a URL when generateUri answers something else, and deploys nothing' {
        $script:webhookUrl = 'not a webhook URL'
        $result = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig) } { New-DemoActivityControlWebhook -Config $Config -Name (Get-DemoActivityControlName -Config $Config) -Confirm:$false }
        $result.status | Should -Be 'Fail'
        $script:deployments.Count | Should -Be 0
    }
}

Describe 'Putting the notebook in Fabric (Set-DemoActivityControlFabric)' {
    BeforeEach {
        Reset-FakeAzure
        $script:logs = [System.Collections.Generic.List[string]]::new()
        Register-FakeAzure
        Initialize-GuardTestContext -ObjectId $script:callerId
        $script:shared = 'abcdabcd-abcd-abcd-abcd-abcdabcdabcd'
        $script:capacityStatus = 'Pass'
        $script:folders = @()
        $script:folderStatus = 201
        $script:fabricWorkspaces = @(@{ id = $script:shared; displayName = 'Demo workspace' })
        $script:outbound = 'Allow'
        $script:endpoints = @()
        $script:fabricPosts = [System.Collections.Generic.List[object]]::new()
        $script:imports = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -MockWith { @([pscustomobject]@{ checkId = 'FABRIC.P5.CAPACITY'; status = $script:capacityStatus; message = ('The capacity is {0}.' -f $(if ($script:capacityStatus -eq 'Pass') { 'Active' } else { 'Paused' })) }) }
        Mock -ModuleName DbHubDemo -CommandName Import-DemoFabricNotebook -MockWith {
            # A parameter that wasn't passed has no variable in a mock's body under strict mode.
            $folder = [string](Get-Variable -Name 'FolderId' -ValueOnly -ErrorAction SilentlyContinue)
            $script:imports.Add([pscustomobject]@{ WorkspaceId = $WorkspaceId; FolderId = $folder })
            [pscustomobject]@{ status = 'Pass'; message = 'was imported.'; remediation = '' }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -MockWith {
            $path = ([uri]$Uri).AbsolutePath
            if ($Method -eq 'Post') {
                $script:fabricPosts.Add([pscustomobject]@{ Path = $path; Body = $Body })
                switch -Regex ($path) {
                    '/folders$' { return [pscustomobject]@{ StatusCode = $script:folderStatus; Body = @{ id = '0f0f0f0f-0000-0000-0000-000000000002'; errorCode = 'PreviewApiNotEnabled' } } }
                    '^/v1/workspaces$' { return [pscustomobject]@{ StatusCode = 201; Body = @{ id = '0c0c0c0c-0000-0000-0000-000000000002' } } }
                    '/managedPrivateEndpoints$' { return [pscustomobject]@{ StatusCode = 201; Body = @{ id = 'endpoint-new' } } }
                }
                return [pscustomobject]@{ StatusCode = 400; Body = $null }
            }
            switch -Regex ($path) {
                '/folders$' { return [pscustomobject]@{ StatusCode = 200; Body = @{ value = @($script:folders) } } }
                '/networking/communicationPolicy$' { return [pscustomobject]@{ StatusCode = 200; Body = @{ outbound = @{ publicAccessRules = @{ defaultAction = $script:outbound } } } } }
                '/managedPrivateEndpoints$' { return [pscustomobject]@{ StatusCode = 200; Body = @{ value = @($script:endpoints) } } }
                '^/v1/workspaces$' { return [pscustomobject]@{ StatusCode = 200; Body = @{ value = @($script:fabricWorkspaces) } } }
                '^/v1/workspaces/[^/]+$' { return [pscustomobject]@{ StatusCode = 200; Body = @{ id = $script:shared; capacityId = 'capacity-1' } } }
            }
            return [pscustomobject]@{ StatusCode = 404; Body = $null }
        }
        function Invoke-Placement([string] $Mode) {
            $config = New-ControlConfig
            InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config; Mode = $Mode; Token = (New-TestSecureString) } {
                $name = Get-DemoActivityControlName -Config $Config
                $setting = Get-DemoActivityControlRunbookSetting -Config $Config -Name $name -IdentityClientId '99999999-9999-9999-9999-999999999999'
                Set-DemoActivityControlFabric -Config $Config -Name $name -Mode $Mode -Setting $setting -Token $Token -ApprovalWaitMinutes 0 -Confirm:$false
            }
        }
    }

    It 'public: imports the notebook into the existing folder "DBHub Control"' {
        $script:folders = @(@{ id = '0f0f0f0f-0000-0000-0000-000000000001'; displayName = 'DBHub Control' })
        $results = @(Invoke-Placement -Mode 'public')
        ($results | Where-Object checkId -EQ 'CONTROL.FABRIC.FOLDER').status | Should -Be 'Pass'
        $script:fabricPosts.Count | Should -Be 0
        $script:imports.Count | Should -Be 1
        $script:imports[0].WorkspaceId | Should -Be $script:shared
        $script:imports[0].FolderId | Should -Be '0f0f0f0f-0000-0000-0000-000000000001'
    }

    It 'public: creates the folder (Folders - Create Folder), then imports the notebook into it' {
        $results = @(Invoke-Placement -Mode 'public')
        @($script:fabricPosts | ForEach-Object Path) | Should -Be @(('/v1/workspaces/{0}/folders' -f $script:shared))
        $script:fabricPosts[0].Body['displayName'] | Should -Be 'DBHub Control'
        $script:imports[0].FolderId | Should -Be '0f0f0f0f-0000-0000-0000-000000000002'
        ($results | Where-Object checkId -EQ 'CONTROL.FABRIC.NOTEBOOK').status | Should -Be 'Pass'
    }

    It 'public: puts the notebook in the workspace''s root, with a Warning, when the preview Folders API refuses' {
        $script:folderStatus = 403
        $results = @(Invoke-Placement -Mode 'public')
        ($results | Where-Object checkId -EQ 'CONTROL.FABRIC.FOLDER').status | Should -Be 'Warning'
        $script:imports[0].WorkspaceId | Should -Be $script:shared
        $script:imports[0].FolderId | Should -BeNullOrEmpty
    }

    It 'creates nothing, and never touches the capacity, when it isn''t Active' {
        $script:capacityStatus = 'Fail'
        $results = @(Invoke-Placement -Mode 'private')
        $results.Count | Should -Be 1
        $results[0].status | Should -Be 'Manual action required'
        $results[0].message | Should -Match 'never resumes, pauses, or scales'
        $script:fabricPosts.Count | Should -Be 0
        $script:imports.Count | Should -Be 0
        @($script:rest | Where-Object Method -NE 'get') | Should -BeNullOrEmpty
    }

    It 'private: creates the DBHub Control workspace on the same capacity, a managed private endpoint to the vault, approves it on the vault, and imports the notebook there' {
        $script:connections.Add([pscustomobject]@{ name = 'connection-1'; status = 'Pending'; description = 'DBHub Control notebook to the control vault (ADR 0020)' })
        $script:connections.Add([pscustomobject]@{ name = 'connection-2'; status = 'Pending'; description = 'Someone else''s endpoint' })
        $name = Get-ControlName (New-ControlConfig)
        $results = @(Invoke-Placement -Mode 'private')
        @($script:fabricPosts | ForEach-Object Path) | Should -Be @('/v1/workspaces', '/v1/workspaces/0c0c0c0c-0000-0000-0000-000000000002/managedPrivateEndpoints')
        $script:fabricPosts[0].Body['displayName'] | Should -Be 'DBHub Control'
        $script:fabricPosts[0].Body['capacityId'] | Should -Be 'capacity-1'
        $endpoint = $script:fabricPosts[1].Body
        $endpoint['name'] | Should -Be $name.PrivateEndpoint
        $endpoint['targetPrivateLinkResourceId'] | Should -Be $name.KeyVaultId
        $endpoint['targetSubresourceType'] | Should -Be 'vault'
        $script:connections[0].status | Should -Be 'Approved'
        $script:connections[1].status | Should -Be 'Pending' -Because 'only the control''s own request is approved'
        @($script:rest | Where-Object Method -EQ 'put' | ForEach-Object { ([uri]$_.Url).AbsolutePath }) | Should -Be @(('{0}/privateEndpointConnections/connection-1' -f $name.KeyVaultId))
        $script:imports[0].WorkspaceId | Should -Be '0c0c0c0c-0000-0000-0000-000000000002'
        foreach ($id in 'CONTROL.FABRIC.WORKSPACE', 'CONTROL.FABRIC.OUTBOUND', 'CONTROL.FABRIC.ENDPOINT', 'CONTROL.FABRIC.NOTEBOOK') {
            ($results | Where-Object checkId -EQ $id).status | Should -Be 'Pass' -Because $id
        }
    }

    It 'private: reports outbound access protection that someone turned on as a Fail, and never changes it' {
        $script:fabricWorkspaces = @(@{ id = $script:shared; displayName = 'Demo workspace' }, @{ id = '0c0c0c0c-0000-0000-0000-000000000002'; displayName = 'DBHub Control' })
        $script:outbound = 'Deny'
        $script:endpoints = @(@{ id = 'endpoint-1'; name = (Get-ControlName (New-ControlConfig)).PrivateEndpoint })
        $script:connections.Add([pscustomobject]@{ name = 'connection-1'; status = 'Approved'; description = 'Approved by setup-activity-control.ps1 for the DBHub Control workspace (ADR 0020)' })
        $results = @(Invoke-Placement -Mode 'private')
        ($results | Where-Object checkId -EQ 'CONTROL.FABRIC.OUTBOUND').status | Should -Be 'Fail'
        $script:fabricPosts.Count | Should -Be 0 -Because 'the workspace and its endpoint exist, and nothing changes the policy'
        ($results | Where-Object checkId -EQ 'CONTROL.FABRIC.ENDPOINT').status | Should -Be 'Pass'
    }
}

Describe 'Removing the control (setup-activity-control.ps1 -Remove)' {
    BeforeEach {
        Reset-FakeAzure
        $script:logs = [System.Collections.Generic.List[string]]::new()
        Register-FakeAzure
        Initialize-GuardTestContext -ObjectId $script:callerId
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { [pscustomobject]@{ checkId = 'PREFLIGHT.GUARD.CONTEXT'; status = 'Pass'; message = 'ok'; remediation = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { New-TestSecureString }
        Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith { [pscustomobject]@{ Items = @(@{ id = 'notebook-1'; displayName = 'NB_DatabaseHub_Control' }) } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -MockWith {
            if ($Method -eq 'Delete') {
                $script:ops.Add(('fabric delete {0}' -f ([uri]$Uri).AbsolutePath))
                return [pscustomobject]@{ StatusCode = 200; Body = $null }
            }
            $path = ([uri]$Uri).AbsolutePath
            $value = switch -Regex ($path) {
                '/folders$' { @(@{ id = 'folder-1'; displayName = 'DBHub Control' }) }
                '/workspaces$' { @(@{ id = 'workspace-2'; displayName = 'DBHub Control' }, @{ id = 'workspace-3'; displayName = 'Someone else' }) }
                '/managedPrivateEndpoints$' { @(@{ id = 'endpoint-1'; name = 'mpe-kv' }) }
                default { @() }
            }
            return [pscustomobject]@{ StatusCode = 200; Body = @{ value = $value } }
        }
        $config = New-ControlConfig
        $name = Get-ControlName $config
        $role = '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $script:sub, $script:customRoleId
        $script:assignments.Add([pscustomobject]@{ name = '10000000-0000-0000-0000-000000000001'; scope = $name.DemoResourceGroupId; roleDefinitionId = $role; principalId = $script:identityPrincipal })
        $script:assignments.Add([pscustomobject]@{ name = '10000000-0000-0000-0000-000000000003'; scope = $name.SecretId; roleDefinitionId = ('/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6' -f $script:sub); principalId = $script:callerId })
    }

    It 'deletes nothing with -WhatIf' {
        $results = @(Invoke-DemoActivityControlSetup -Config (New-ControlConfig) -Remove -WhatIf)
        $script:ops.Count | Should -Be 0
        @($script:rest | Where-Object Method -NE 'get') | Should -BeNullOrEmpty
        @($script:azCalls | Where-Object { $_ -match 'delete' }) | Should -BeNullOrEmpty
        foreach ($id in 'CONTROL.REMOVE.FABRIC', 'CONTROL.REMOVE.ROLES', 'CONTROL.REMOVE.RESOURCES') {
            ($results | Where-Object checkId -EQ $id).status | Should -Be 'Not selected' -Because $id
        }
    }

    It 'removes Fabric first, then the roles, then the resources, and keeps a group that still holds something' {
        $script:leftInGroup = 1
        $results = @(Invoke-DemoActivityControlSetup -Config (New-ControlConfig) -Remove -Force)
        $script:ops | Should -Contain 'fabric delete /v1/workspaces/abcdabcd-abcd-abcd-abcd-abcdabcdabcd/items/notebook-1'
        $script:ops | Should -Contain 'fabric delete /v1/workspaces/workspace-2'
        $script:ops | Should -Not -Contain 'fabric delete /v1/workspaces/workspace-3'
        $ops = [string[]]$script:ops.ToArray()
        $lastFabric = [array]::FindLastIndex($ops, [Predicate[string]] { param($op) $op -like 'fabric delete*' })
        $firstRole = [array]::FindIndex($ops, [Predicate[string]] { param($op) $op -like 'arm delete */roleAssignments/*' })
        $lastRole = [array]::FindLastIndex($ops, [Predicate[string]] { param($op) $op -like 'arm delete */roleDefinitions/*' })
        $account = [array]::FindIndex($ops, [Predicate[string]] { param($op) $op -like 'arm delete */automationAccounts/aa-dbhub-control' })
        $lastFabric | Should -BeGreaterOrEqual 0
        $firstRole | Should -BeGreaterThan $lastFabric
        $lastRole | Should -BeGreaterThan $firstRole
        $account | Should -BeGreaterThan $lastRole
        $script:assignments.Count | Should -Be 0
        @($script:rest | Where-Object { $_.Method -eq 'post' -and $_.Url -match '/deletedVaults/.+/purge' }).Count | Should -Be 1
        @($script:azCalls | Where-Object { $_ -like 'group delete*' }) | Should -BeNullOrEmpty
        ($results | Where-Object checkId -EQ 'CONTROL.REMOVE.RESOURCES').message | Should -Match 'was kept'
    }

    It 'deletes the group when nothing else is left in it' {
        $script:leftInGroup = 0
        $null = @(Invoke-DemoActivityControlSetup -Config (New-ControlConfig) -Remove -Force -SkipFabric)
        @($script:azCalls | Where-Object { $_ -like 'group delete --name rg-dbhub-control*' }).Count | Should -Be 1
        @($script:ops | Where-Object { $_ -like 'fabric *' }) | Should -BeNullOrEmpty -Because '-SkipFabric leaves Fabric alone'
    }
}

Describe 'Validation and status (Test-DemoActivityControl, STATUS.CONTROL)' {
    BeforeEach {
        Reset-FakeAzure
        $script:logs = [System.Collections.Generic.List[string]]::new()
        Register-FakeAzure
        Initialize-GuardTestContext -ObjectId $script:callerId
        $config = New-ControlConfig
        $name = Get-ControlName $config
        $role = '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $script:sub, $script:customRoleId
        $script:assignments.Add([pscustomobject]@{ name = '1'; scope = $name.DemoResourceGroupId; roleDefinitionId = $role; principalId = $script:identityPrincipal })
        $script:assignments.Add([pscustomobject]@{ name = '2'; scope = $name.AutomationAccountId; roleDefinitionId = $role; principalId = $script:identityPrincipal })
        $script:assignments.Add([pscustomobject]@{ name = '3'; scope = $name.SecretId; roleDefinitionId = ('/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6' -f $script:sub); principalId = $script:callerId })
        $script:webhooks = @('dbhub-activity-202610270000')
        $script:now = [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc)
    }

    It 'is Not selected while control.enabled is false' {
        $results = @(Test-DemoActivityControl -Config (New-ControlConfig -Enabled $false))
        $results.Count | Should -Be 1
        $results[0].status | Should -Be 'Not selected'
        $script:azCalls.Count | Should -Be 0
    }

    It 'passes when everything is in place' {
        $results = @(Test-DemoActivityControl -Config (New-ControlConfig) -NowUtc $script:now)
        @($results | ForEach-Object checkId) | Should -Be @('CONTROL.SETUP', 'CONTROL.WEBHOOK', 'CONTROL.ROLE.A1', 'CONTROL.ROLE.A2', 'CONTROL.ROLE.A3', 'CONTROL.AUTOSTOP', 'CONTROL.SAFETYSTOP')
        @($results | Where-Object status -NE 'Pass') | Should -BeNullOrEmpty
        @($script:rest | Where-Object Method -NE 'get') | Should -BeNullOrEmpty -Because 'validation only reads'
    }

    It 'reports a missing A1 after a redeploy as Manual action required with the -GrantRole command' {
        $script:assignments.RemoveAt(0)
        $results = @(Test-DemoActivityControl -Config (New-ControlConfig) -ConfigPath './config/demo.config.json' -NowUtc $script:now)
        $a1 = $results | Where-Object checkId -EQ 'CONTROL.ROLE.A1'
        $a1.status | Should -Be 'Manual action required'
        $a1.remediation | Should -Match ([regex]::Escape('./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -GrantRole'))
    }

    It 'warns 14 days before the webhook expires, and needs a rotation once it has' -ForEach @(
        @{ Days = 10; Status = 'Warning' }
        @{ Days = -1; Status = 'Manual action required' }
    ) {
        $script:webhookExpiry = $script:now.AddDays($Days)
        $hook = @(Test-DemoActivityControl -Config (New-ControlConfig) -NowUtc $script:now) | Where-Object checkId -EQ 'CONTROL.WEBHOOK'
        $hook.status | Should -Be $Status
        $hook.remediation | Should -Match '-RotateWebhook'
    }

    It 'reports an active run, and warns about an auto-stop that should have run long ago' -ForEach @(
        @{ Minutes = 30; Status = 'Pass'; Match = 'is active' }
        @{ Minutes = -90; Status = 'Warning'; Match = 'may have failed' }
    ) {
        $script:autoStop = $script:now.AddMinutes($Minutes)
        $stop = @(Test-DemoActivityControl -Config (New-ControlConfig) -NowUtc $script:now) | Where-Object checkId -EQ 'CONTROL.AUTOSTOP'
        $stop.status | Should -Be $Status
        $stop.message | Should -Match $Match
    }

    It 'sums the checks up in STATUS.CONTROL with the worst status' {
        $script:assignments.RemoveAt(0)
        $status = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig); Now = $script:now } { Get-DemoActivityControlStatus -Config $Config -NowUtc $Now }
        $status.checkId | Should -Be 'STATUS.CONTROL'
        $status.status | Should -Be 'Manual action required'
        $status.remediation | Should -Match '-GrantRole'
    }

    It 'lets Security validation accept A1 at the demo group only when the control is on' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/Private/ValidationSecurity.ps1') -Raw
        $text | Should -Match '\$controlOn -and \$role -eq \$script:ActivityControlRoleName -and \[string\]::Equals\(\$scope, \$groupScope'
    }
}

Describe 'stop-demo.ps1, start-demo.ps1, and a pending auto-stop (Clear-DemoActivityControlAutoStop)' {
    BeforeEach {
        Reset-FakeAzure
        $script:logs = [System.Collections.Generic.List[string]]::new()
        Register-FakeAzure
        Initialize-GuardTestContext -ObjectId $script:callerId
        $script:now = [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc)
        function Invoke-Clear([string] $Purpose, [switch] $DryRun) {
            InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = (New-ControlConfig); Purpose = $Purpose; Now = $script:now; DryRun = [bool]$DryRun } {
                Clear-DemoActivityControlAutoStop -Config $Config -Purpose $Purpose -NowUtc $Now -WhatIf:$DryRun -Confirm:$false
            }
        }
        function Get-Deleted {
            @($script:rest | Where-Object Method -EQ 'delete' | ForEach-Object { ([uri]$_.Url).AbsolutePath.Split('/')[-1] })
        }
    }

    It 'stop-demo.ps1 removes the pending auto-stop and its link, and leaves the daily safety stop alone' {
        $script:autoStop = $script:now.AddMinutes(30)
        $result = Invoke-Clear -Purpose Stop
        $result.checkId | Should -Be 'STOP.CONTROL.AUTOSTOP'
        $result.status | Should -Be 'Pass'
        Get-Deleted | Should -Be @('ffffffff-0000-0000-0000-000000000007', 'dbhub-autostop')
    }

    It 'has nothing to do when no run is pending, and changes nothing with -WhatIf' {
        (Invoke-Clear -Purpose Stop).status | Should -Be 'Not selected'
        $script:autoStop = $script:now.AddMinutes(30)
        (Invoke-Clear -Purpose Stop -DryRun).status | Should -Be 'Not selected'
        (Invoke-Clear -Purpose Start -DryRun).status | Should -Be 'Not selected'
        $script:autoStop = $null
        $script:stopJobStates = @('Running')
        @(Invoke-Clear -Purpose Start -DryRun).Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
        @($script:rest | Where-Object Method -NE 'get') | Should -BeNullOrEmpty
    }

    It 'start-demo.ps1 cancels a pending auto-stop, with a Warning that says until when the VMs now run' {
        $script:autoStop = $script:now.AddMinutes(30)
        $result = Invoke-Clear -Purpose Start
        $result.checkId | Should -Be 'START.CONTROL.AUTOSTOP'
        $result.status | Should -Be 'Warning'
        $result.message | Should -BeExactly "An on-demand run's auto-stop was cancelled; the VMs now run until stop-demo.ps1 or the nightly auto-shutdown at 2026-10-27 23:00 UTC (19:00 Eastern Standard Time)."
        $result.remediation | Should -Match 'stop-demo\.ps1'
        Get-Deleted | Should -Be @('ffffffff-0000-0000-0000-000000000007', 'dbhub-autostop')
    }

    It 'start-demo.ps1 carries on when the auto-stop can''t be cancelled, with a Warning that gives its time and how to cancel it' {
        $script:autoStop = $script:now.AddMinutes(30)
        $script:autoStopDeleteFails = $true
        $result = Invoke-Clear -Purpose Start
        $result.checkId | Should -Be 'START.CONTROL.AUTOSTOP'
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'still pending and deallocates the VMs at 2026-10-27 15:30 UTC'
        $result.message | Should -Match 'AuthorizationFailed'
        $result.message | Should -Match 'The start carried on'
        $result.remediation | Should -Match 'delete the schedule dbhub-autostop in the Automation account aa-dbhub-control'
        $result.remediation | Should -Match 'start-demo\.ps1 again'
    }

    It 'start-demo.ps1 leaves alone an auto-stop whose time passed over an hour ago: it isn''t pending' {
        $script:autoStop = $script:now.AddHours(-2)
        $result = Invoke-Clear -Purpose Start
        $result.status | Should -Be 'Not selected'
        $result.message | Should -Match 'has passed'
        Get-Deleted | Should -BeNullOrEmpty
    }

    It 'start-demo.ps1 starts at once when no stop job is queued or running, even just after an auto-stop''s time' {
        $script:autoStop = $script:now.AddMinutes(-5)
        $results = @(Invoke-Clear -Purpose Start)
        $results.Count | Should -Be 1
        $results[0].checkId | Should -Be 'START.CONTROL.AUTOSTOP'
        $results[0].status | Should -Be 'Not selected'
        Get-Deleted | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
        $jobReads = @($script:rest | Where-Object { ([uri]$_.Url).AbsolutePath -like '*/automationAccounts/aa-dbhub-control/jobs' })
        $jobReads.Count | Should -Be 1
        $jobReads[0].Query | Should -Match '\$filter=properties/runbook/name eq ''DbHub-Stop'''
        $jobReads[0].Url | Should -Not -Match '[%?]' -Because 'an encoded query string has %, which cmd.exe can''t pass to az.cmd'
    }

    It 'start-demo.ps1 waits for a queued or running stop job, polling every 30 seconds, then starts with an Info line' {
        $script:stopJobStates = @('New', 'Running', 'Completed')
        $results = @(Invoke-Clear -Purpose Start)
        @($results | ForEach-Object checkId) | Should -Be @('START.CONTROL.AUTOSTOP', 'START.CONTROL.STOPJOB')
        $results[0].status | Should -Be 'Not selected'
        $results[1].status | Should -Be 'Pass'
        $results[1].message | Should -Match 'DbHub-Stop \(bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\) finished after about a minute, before anything started'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 30 } -Times 2 -Exactly
        $script:logs | Should -Contain 'Waited about a minute for the on-demand stop job DbHub-Stop (bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb) to finish; starting now.'
        @($script:rest | Where-Object Method -NE 'get') | Should -BeNullOrEmpty
    }

    It 'start-demo.ps1 waits up to 10 minutes, then warns and carries on when the stop job still runs, and never stops it' {
        $script:stopJobStates = @('Running')
        $stopJob = @(Invoke-Clear -Purpose Start) | Where-Object checkId -EQ 'START.CONTROL.STOPJOB'
        $stopJob.status | Should -Be 'Warning'
        $stopJob.message | Should -Match 'was still Running after about 10 minutes: the start carried on, and that job may deallocate the VMs this start brings up'
        $stopJob.remediation | Should -Match 'start-demo\.ps1 never stops it'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 30 } -Times 20 -Exactly
        $script:jobReads | Should -Be 21
        @($script:rest | Where-Object Method -NE 'get') | Should -BeNullOrEmpty
    }

    It 'start-demo.ps1 warns with the auto-stop''s due time when the stop jobs can''t be read' {
        $script:autoStop = $script:now.AddMinutes(-5)
        $script:jobsReadFailAt = 1
        $results = @(Invoke-Clear -Purpose Start)
        $results[0].status | Should -Be 'Not selected'
        $stopJob = $results | Where-Object checkId -EQ 'START.CONTROL.STOPJOB'
        $stopJob.status | Should -Be 'Warning'
        $stopJob.message | Should -Match 'auto-stop was due at 2026-10-27 14:55 UTC, so its DbHub-Stop job may be running now and deallocate the VMs this start brings up'
        $stopJob.message | Should -Match 'AuthorizationFailed'
        $stopJob.remediation | Should -Match 'run start-demo\.ps1 again'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
    }

    It 'start-demo.ps1 warns and carries on when the stop jobs can''t be read while it waits' {
        $script:stopJobStates = @('Running')
        $script:jobsReadFailAt = 3
        $stopJob = @(Invoke-Clear -Purpose Start) | Where-Object checkId -EQ 'START.CONTROL.STOPJOB'
        $stopJob.status | Should -Be 'Warning'
        $stopJob.message | Should -Match '^A DbHub-Stop job may be running now'
        $stopJob.message | Should -Match 'had waited about a minute for job bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb, and carried on'
    }

    It 'start-demo.ps1 has no stop job to wait for when the control''s Automation account doesn''t exist' {
        $script:accountExists = $false
        $results = @(Invoke-Clear -Purpose Start)
        $results.Count | Should -Be 1
        $results[0].status | Should -Be 'Not selected'
    }

    It 'counts a job as queued or running exactly as the runbooks do' {
        $runbook = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1') -Raw
        $runbook -match '\$script:DbHubActiveJobStatuses = @\((?<list>[^)]+)\)' | Should -BeTrue
        $fromRunbook = @([regex]::Matches($Matches['list'], "'([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value })
        $fromModule = @(InModuleScope -ModuleName DbHubDemo { $script:ActivityControlActiveJobStatuses })
        $fromModule | Should -Be $fromRunbook
        $fromModule | Should -Contain 'New'
        $fromModule | Should -Contain 'Running'
    }

    It 'stop-demo.ps1 warns when it can''t remove the auto-stop, and says start-demo.ps1 cancels it at the next start' {
        $script:autoStop = $script:now.AddMinutes(30)
        $script:autoStopDeleteFails = $true
        $result = Invoke-Clear -Purpose Stop
        $result.checkId | Should -Be 'STOP.CONTROL.AUTOSTOP'
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'start-demo\.ps1 cancels it when the next session starts'
        $result.remediation | Should -Match 'run stop-demo\.ps1 again'
    }

    It 'is called by Stop-DemoEnvironment for a full stop with the control on, and not for -ParkT2' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/Public/Stop-DemoEnvironment.ps1') -Raw
        $text | Should -Match 'if \(-not \$ParkT2 -and \(Get-DemoActivityControlSetting -Config \$Config\)\.Enabled\) \{\s+#[^\n]*\n\s+\$results\.Add\(\(Clear-DemoActivityControlAutoStop -Config \$Config -Confirm:\$false\)\)'
    }
}

Describe 'The daily T4 safety stop''s time' {
    It '<Case>' -ForEach @(
        @{ Case = 'defaults to 15 minutes after the auto-shutdown'; Configured = ''; Shutdown = '1900'; Now = [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc); Local = '19:15'; Start = '2026-10-27T19:15:00-04:00' }
        @{ Case = 'takes control.t4SafetyStopTime'; Configured = '06:30'; Shutdown = '1900'; Now = [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc); Local = '06:30'; Start = '2026-10-28T06:30:00-04:00' }
        @{ Case = 'wraps past midnight'; Configured = ''; Shutdown = '2350'; Now = [datetime]::new(2026, 10, 27, 15, 0, 0, [System.DateTimeKind]::Utc); Local = '00:05'; Start = '2026-10-28T00:05:00-04:00' }
        @{ Case = 'starts tomorrow when today''s time is less than 10 minutes away'; Configured = ''; Shutdown = '1900'; Now = [datetime]::new(2026, 10, 27, 23, 10, 0, [System.DateTimeKind]::Utc); Local = '19:15'; Start = '2026-10-28T19:15:00-04:00' }
        @{ Case = 'follows the zone''s offset after daylight saving time ends'; Configured = ''; Shutdown = '1900'; Now = [datetime]::new(2026, 11, 2, 15, 0, 0, [System.DateTimeKind]::Utc); Local = '19:15'; Start = '2026-11-02T19:15:00-05:00' }
    ) {
        $config = New-ControlConfig
        $config['autoShutdownTime'] = $Shutdown
        $config['control']['t4SafetyStopTime'] = $Configured
        $when = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config; Now = $Now } { Get-DemoActivityControlSafetyStopTime -Config $Config -NowUtc $Now }
        $when.LocalTime | Should -Be $Local
        $when.StartTime | Should -Be $Start
        $when.TimeZone | Should -Be 'Eastern Standard Time'
    }
}
