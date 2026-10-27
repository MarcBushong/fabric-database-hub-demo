BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext

    function New-VaultConfig([bool] $Enabled = $true) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['assignRoles'] = $Enabled
        $config['keyVault']['enabled'] = $Enabled
        $config['keyVault']['operatorObjectIds'] = @('cccccccc-0000-0000-0000-000000000003')
        $config['keyVault']['readerObjectIds'] = @('bbbbbbbb-0000-0000-0000-000000000002', 'CCCCCCCC-0000-0000-0000-000000000003')
        return $config
    }

    function New-AzResult([int] $ExitCode = 0, [string] $StdOut = '', [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
    }

    function ConvertTo-TestSecureString([string] $Text) {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in $Text.ToCharArray()) {
            $secure.AppendChar($character)
        }
        return $secure
    }

    function Get-ArgumentValue([object[]] $Arguments, [string] $Name) {
        $index = [array]::IndexOf($Arguments, $Name)
        if ($index -ge 0 -and $index + 1 -lt $Arguments.Count) {
            return [string]$Arguments[$index + 1]
        }
        return ''
    }

    $script:vaultName = 'kv-dbhubdemo-abc123'
    $script:vaultId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.KeyVault/vaults/kv-dbhubdemo-abc123'
    $script:secretBase = 'https://kv-dbhubdemo-abc123.vault.azure.net/secrets/archost01-one-time-password/'
    $script:callerId = 'aaaaaaaa-0000-0000-0000-000000000001'
    # The Azure Run Command parameter rule (Invoke-DemoVmRunCommand): what a protected value may contain.
    $script:runCommandPattern = '^[A-Za-z0-9._:/@=,+?&%~-]*$'
}

Describe 'The Key Vault opt-in (keyVault.enabled)' {
    BeforeEach {
        $config = New-VaultConfig
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:deployments = [System.Collections.Generic.List[object]]::new()
        $script:creates = [System.Collections.Generic.List[object]]::new()
        $script:disabledIds = [System.Collections.Generic.List[string]]::new()
        $script:assigned = [System.Collections.Generic.List[string]]::new()
        $script:vault = $null
        $script:deleted = $false
        $script:canAssign = $true
        $script:callerType = 'user'
        $script:graphFails = $false
        $script:deployError = ''
        $script:forbidden = 0
        $script:firewall = $false
        $script:stored = $null
        $script:versions = @()
        $script:listError = ''
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        # The caller's object ID and type come from the subscription guard's verified token (the unit-test hook
        # here), and the configured principals' types from Microsoft Graph's getByIds with a verified token.
        Initialize-GuardTestContext -ObjectId $script:callerId
        $script:principalTypes = @{ 'bbbbbbbb-0000-0000-0000-000000000002' = 'user'; 'cccccccc-0000-0000-0000-000000000003' = 'servicePrincipal' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            $script:graphRequests.Add(('{0} {1} {2}' -f $Method, $Uri, $Body))
            $value = @(foreach ($id in @(($Body | ConvertFrom-Json).ids)) {
                    if ($script:principalTypes.ContainsKey($id)) {
                        @{ id = $id; '@odata.type' = ('#microsoft.graph.' + $script:principalTypes[$id]) }
                    }
                })
            [pscustomobject]@{ ExitCode = 0; StdOut = (@{ value = $value } | ConvertTo-Json -Depth 4); StdErr = ''; StatusCode = 200 }
        }
        $script:graphRequests = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $words = @($ArgumentList)
            $text = $words -join ' '
            $script:azCalls.Add($text)
            switch -Wildcard ($text) {
                'group show*' {
                    return (New-AzResult -StdOut (@{ name = 'rg-dbhub-demo'; tags = @{ deploymentId = 'abc123'; owner = 'your-alias'; DbHubDeployStage = 'T3' } } | ConvertTo-Json -Depth 5))
                }
                'account show*' {
                    return (New-AzResult -StdOut (@{ user = @{ type = $script:callerType; name = 'operator' } } | ConvertTo-Json))
                }
                'ad *' {
                    if ($script:graphFails) {
                        return (New-AzResult -ExitCode 1 -StdErr 'ERROR: Insufficient privileges to complete the operation.')
                    }
                    return (New-AzResult -StdOut ($script:callerId + "`n"))
                }
                'keyvault show-deleted*' {
                    if ($script:deleted) {
                        return (New-AzResult -StdOut (@{ name = $script:vaultName; properties = @{ location = 'westus3'; purgeProtectionEnabled = $false } } | ConvertTo-Json -Depth 5))
                    }
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (DeletedVaultNotFound) The deleted vault was not found.')
                }
                'keyvault recover*' {
                    $script:deleted = $false
                    $script:vault = @{ retention = 7; purge = $false; location = 'westus3' }
                    return (New-AzResult -StdOut '{}')
                }
                'keyvault show *' {
                    if ($null -eq $script:vault) {
                        return (New-AzResult -ExitCode 3 -StdErr "ERROR: (ResourceNotFound) The Resource 'Microsoft.KeyVault/vaults/kv-dbhubdemo-abc123' under resource group 'rg-dbhub-demo' was not found.")
                    }
                    return (New-AzResult -StdOut (@{ id = $script:vaultId; name = $script:vaultName; location = $script:vault.location; properties = @{ softDeleteRetentionInDays = $script:vault.retention; enablePurgeProtection = $script:vault.purge } } | ConvertTo-Json -Depth 5))
                }
                'rest --method get*' {
                    $actions = if ($script:canAssign) { @('*') } else { @('*/read') }
                    return (New-AzResult -StdOut (@{ value = @(@{ actions = $actions; notActions = @() }) } | ConvertTo-Json -Depth 5))
                }
                'deployment group create*' {
                    $file = (Get-ArgumentValue $words '--parameters').Substring(1)
                    $script:deployments.Add([pscustomobject]@{ Text = $text; Parameters = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable) })
                    if ($script:deployError) {
                        return (New-AzResult -ExitCode 1 -StdErr $script:deployError)
                    }
                    if ($null -eq $script:vault) {
                        $script:vault = @{ retention = 7; purge = $false; location = 'westus3' }
                    }
                    return (New-AzResult -StdOut '{}')
                }
                'role definition list*' {
                    $name = Get-ArgumentValue $words '--name'
                    $id = '/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft.Authorization/roleDefinitions/' + $(if ($name -eq 'Key Vault Secrets Officer') { 'officer-definition' } else { 'user-definition' })
                    return (New-AzResult -StdOut (ConvertTo-Json -InputObject @(@{ roleName = $name; id = $id }) -Depth 5))
                }
                'role assignment list*' {
                    $key = '{0}|{1}' -f (Get-ArgumentValue $words '--assignee-object-id'), (Get-ArgumentValue $words '--role').Split('/')[-1]
                    if ($script:assigned.Contains($key)) {
                        return (New-AzResult -StdOut (ConvertTo-Json -InputObject @(@{ principalId = (Get-ArgumentValue $words '--assignee-object-id') }) -Depth 5))
                    }
                    return (New-AzResult -StdOut '[]')
                }
                'role assignment create*' {
                    $script:creates.Add([pscustomobject]@{ ObjectId = (Get-ArgumentValue $words '--assignee-object-id'); Role = (Get-ArgumentValue $words '--role').Split('/')[-1]; Scope = (Get-ArgumentValue $words '--scope'); PrincipalType = (Get-ArgumentValue $words '--assignee-principal-type') })
                    return (New-AzResult -StdOut '{}')
                }
                'vm show*' {
                    return (New-AzResult -StdOut "demoadmin`n")
                }
                'keyvault secret set-attributes*' {
                    $script:disabledIds.Add((Get-ArgumentValue $words '--id'))
                    return (New-AzResult)
                }
                'keyvault secret set *' {
                    if ($script:firewall) {
                        return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (Forbidden) Client address is not authorized and caller is not a trusted service. Code: Forbidden Inner error: ForbiddenByFirewall')
                    }
                    if ($script:forbidden -gt 0) {
                        $script:forbidden--
                        return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (Forbidden) Caller is not authorized to perform action on resource. Code: Forbidden Inner error: ForbiddenByRbac')
                    }
                    $script:stored = [System.IO.File]::ReadAllText((Get-ArgumentValue $words '--file'))
                    return (New-AzResult -StdOut ($script:secretBase + "new1`n"))
                }
                'keyvault secret list-versions*' {
                    if ($script:listError) {
                        return (New-AzResult -ExitCode 1 -StdErr $script:listError)
                    }
                    return (New-AzResult -StdOut (ConvertTo-Json -InputObject @($script:versions) -Depth 5))
                }
            }
            return (New-AzResult -StdOut '{}')
        }
    }

    Context 'Off by default' {
        It 'creates no vault and no role assignment, and calls nothing, while keyVault.enabled is false' {
            $off = New-VaultConfig -Enabled $false
            (Initialize-DemoKeyVault -Config $off -Confirm:$false).status | Should -Be 'Not selected'
            (Set-DemoHostPasswordSecret -Config $off -Password (ConvertTo-TestSecureString 'Tq9-unused-value.x') -Confirm:$false).status | Should -Be 'Not selected'
            (Disable-DemoHostPasswordSecret -Config $off -Confirm:$false).status | Should -Be 'Not selected'
            $script:azCalls.Count | Should -Be 0
        }

        It 'needs assignRoles, and the schema says so too' {
            $config['assignRoles'] = $false
            $result = Initialize-DemoKeyVault -Config $config -Confirm:$false
            $result.status | Should -Be 'Fail'
            $result.remediation | Should -Match 'assignRoles'
            $script:azCalls.Count | Should -Be 0
            $example = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
            $example['keyVault']['enabled'] = $true
            Test-Json -Json ($example | ConvertTo-Json -Depth 10) -SchemaFile (Join-Path -Path $repoRoot -ChildPath 'config/environment.schema.json') -ErrorAction SilentlyContinue | Should -BeFalse
            $example['assignRoles'] = $true
            Test-Json -Json ($example | ConvertTo-Json -Depth 10) -SchemaFile (Join-Path -Path $repoRoot -ChildPath 'config/environment.schema.json') | Should -BeTrue
        }
    }

    Context 'Initialize-DemoKeyVault' {
        It 'deploys the vault from its own template, then grants Secrets Officer and Secrets User by role name, on the vault only' {
            $results = @(Initialize-DemoKeyVault -Config $config -Confirm:$false)
            ($results | Where-Object { $_.checkId -eq 'INFRA.KEYVAULT' }).status | Should -Be 'Pass'
            ($results | Where-Object { $_.checkId -eq 'INFRA.KEYVAULT.ACCESS' }).status | Should -Be 'Pass'
            $script:deployments.Count | Should -Be 1
            $deployment = $script:deployments[0]
            $deployment.Text | Should -Match 'infra[\\/]modules[\\/]keyvault\.bicep'
            $deployment.Parameters.parameters.vaultName.value | Should -Be $script:vaultName
            $deployment.Parameters.parameters.softDeleteRetentionInDays.value | Should -Be 7
            $deployment.Parameters.parameters.enablePurgeProtection.value | Should -BeFalse
            @($deployment.Parameters.parameters.allowedIpRanges.value).Count | Should -Be 0
            $deployment.Parameters.parameters.tags.value['owner'] | Should -Be 'your-alias'
            $deployment.Parameters.parameters.tags.value.Contains('DbHubDeployStage') | Should -BeFalse -Because 'the deployment state stays on the resource group only'
            $script:creates.Count | Should -Be 3
            foreach ($create in $script:creates) {
                $create.Scope | Should -Be $script:vaultId
            }
            $caller = $script:creates | Where-Object { $_.ObjectId -eq $script:callerId }
            $caller.Role | Should -Be 'officer-definition'
            $caller.PrincipalType | Should -Be 'User'
            ($script:creates | Where-Object { $_.ObjectId -eq 'cccccccc-0000-0000-0000-000000000003' }).Role | Should -Be 'officer-definition' -Because 'an operator listed as a reader too gets only Secrets Officer'
            ($script:creates | Where-Object { $_.ObjectId -eq 'bbbbbbbb-0000-0000-0000-000000000002' }).Role | Should -Be 'user-definition'
            $definitionCalls = @($script:azCalls | Where-Object { $_ -like 'role definition list*' }) -join ' | '
            $definitionCalls | Should -Match 'Key Vault Secrets Officer'
            $definitionCalls | Should -Match 'Key Vault Secrets User'
            $permission = $script:azCalls.FindIndex([System.Predicate[string]] { param($call) $call -like 'rest --method get*permissions*' })
            $deploy = $script:azCalls.FindIndex([System.Predicate[string]] { param($call) $call -like 'deployment group create*' })
            $permission | Should -BeGreaterOrEqual 0
            $permission | Should -BeLessThan $deploy -Because 'the permission is checked before a new vault is deployed'
            @($script:azCalls | Where-Object { $_ -like 'keyvault secret*' }).Count | Should -Be 0 -Because 'no secret goes through the deployment'
        }

        It 'deploys nothing when the caller can''t assign roles, so no vault is left that nobody can use' {
            $script:canAssign = $false
            $result = @(Initialize-DemoKeyVault -Config $config -Confirm:$false)
            $result.Count | Should -Be 1
            $result[0].status | Should -Be 'Fail'
            $result[0].message | Should -Match 'No vault was deployed'
            $script:deployments.Count | Should -Be 0
        }

        It 'recovers a vault that destroy.ps1 soft-deleted, under the same name, then deploys it' {
            $script:deleted = $true
            $results = @(Initialize-DemoKeyVault -Config $config -Confirm:$false)
            $recover = @($script:azCalls | Where-Object { $_ -like 'keyvault recover*' })
            $recover.Count | Should -Be 1
            $recover[0] | Should -Match ('--name {0} --resource-group rg-dbhub-demo --location westus3' -f $script:vaultName)
            $script:deployments.Count | Should -Be 1
            $vaultResult = $results | Where-Object { $_.checkId -eq 'INFRA.KEYVAULT' }
            $vaultResult.status | Should -Be 'Pass'
            $vaultResult.evidence.recovered | Should -BeTrue
        }

        It 'keeps an existing vault''s retention and purge protection, and with -EnsureOnly only adds missing role assignments' {
            $script:vault = @{ retention = 30; purge = $true; location = 'westus3' }
            Initialize-DemoKeyVault -Config $config -Confirm:$false | Out-Null
            $script:deployments[0].Parameters.parameters.softDeleteRetentionInDays.value | Should -Be 30
            $script:deployments[0].Parameters.parameters.enablePurgeProtection.value | Should -BeTrue

            $script:deployments.Clear()
            $script:creates.Clear()
            $script:assigned.Add(('{0}|officer-definition' -f $script:callerId))
            $script:assigned.Add('cccccccc-0000-0000-0000-000000000003|officer-definition')
            $results = @(Initialize-DemoKeyVault -Config $config -EnsureOnly -Confirm:$false)
            $script:deployments.Count | Should -Be 0
            $script:creates.Count | Should -Be 1
            $script:creates[0].ObjectId | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002'
            ($results | Where-Object { $_.checkId -eq 'INFRA.KEYVAULT.ACCESS' }).message | Should -Match '1 assigned now, 2 already there'
        }

        It 'reports a policy denial with the settings that may satisfy it' {
            $script:deployError = 'ERROR: (RequestDisallowedByPolicy) Resource ''kv-dbhubdemo-abc123'' was disallowed by policy. Policy identifiers: Key vaults should have deletion protection enabled.'
            $result = @(Initialize-DemoKeyVault -Config $config -Confirm:$false)
            $result[-1].checkId | Should -Be 'INFRA.KEYVAULT'
            $result[-1].status | Should -Be 'Fail'
            $result[-1].message | Should -Match 'RequestDisallowedByPolicy'
            $result[-1].remediation | Should -Match 'keyVault\.purgeProtection'
            $script:creates.Count | Should -Be 0
        }

        It 'still gives the configured principals their roles when the guard hasn''t confirmed the caller, with a Warning' {
            Initialize-GuardTestContext -ObjectId ''
            $results = @(Initialize-DemoKeyVault -Config $config -Confirm:$false)
            $script:creates.Count | Should -Be 2
            ($results | Where-Object { $_.checkId -eq 'INFRA.KEYVAULT.ACCESS' }).status | Should -Be 'Warning'
            ($results | Where-Object { $_.checkId -eq 'INFRA.KEYVAULT.ACCESS' }).remediation | Should -Match 'operatorObjectIds'
        }

        It 'passes every principal type, and never makes the Azure CLI look one up in its default account''s tenant' {
            Initialize-DemoKeyVault -Config $config -Confirm:$false | Out-Null
            ($script:creates | Where-Object { $_.ObjectId -eq 'cccccccc-0000-0000-0000-000000000003' }).PrincipalType | Should -Be 'ServicePrincipal'
            ($script:creates | Where-Object { $_.ObjectId -eq 'bbbbbbbb-0000-0000-0000-000000000002' }).PrincipalType | Should -Be 'User'
            $script:graphRequests.Count | Should -Be 1
            $script:graphRequests[0] | Should -BeLike 'POST https://graph.microsoft.com/v1.0/directoryObjects/getByIds *'
            @($script:azCalls | Where-Object { $_ -like 'ad *' -or $_ -like 'account show*' }) | Should -BeNullOrEmpty
        }

        It 'fails a principal whose type Microsoft Graph doesn''t return, with the administrator''s command' {
            $script:principalTypes.Remove('bbbbbbbb-0000-0000-0000-000000000002')
            $results = @(Initialize-DemoKeyVault -Config $config -Confirm:$false)
            $access = $results | Where-Object { $_.checkId -eq 'INFRA.KEYVAULT.ACCESS' }
            $access.status | Should -Be 'Fail'
            $access.message | Should -Match 'principal type'
            $access.remediation | Should -Match ([regex]::Escape('--assignee-object-id bbbbbbbb-0000-0000-0000-000000000002 --assignee-principal-type <User|Group|ServicePrincipal>'))
            @($script:creates | Where-Object { $_.ObjectId -eq 'bbbbbbbb-0000-0000-0000-000000000002' }).Count | Should -Be 0
        }

        It 'creates nothing with -WhatIf' {
            $results = @(Initialize-DemoKeyVault -Config $config -WhatIf)
            ($results | Where-Object { $_.checkId -eq 'INFRA.KEYVAULT' }).status | Should -Be 'Not selected'
            $script:deployments.Count | Should -Be 0
            $script:creates.Count | Should -Be 0
        }
    }

    Context 'Set-DemoHostPasswordSecret' {
        BeforeEach {
            $script:vault = @{ retention = 7; purge = $false; location = 'westus3' }
            $script:versions = @(
                @{ id = ($script:secretBase + 'old0'); attributes = @{ enabled = $false } }
                @{ id = ($script:secretBase + 'old1'); attributes = @{ enabled = $true } }
                @{ id = ($script:secretBase + 'new1'); attributes = @{ enabled = $true } }
            )
        }

        It 'stores the password from a private file, never on a command line, retries while a new role arrives, and disables older versions' {
            $plain = 'Tq' + [guid]::NewGuid().ToString('N').Substring(0, 14) + '#*x9'
            $script:forbidden = 2
            $result = Set-DemoHostPasswordSecret -Config $config -VmName archost01 -Password (ConvertTo-TestSecureString $plain) -ExpiresUtc '2026-10-21T22:00:00Z' -Confirm:$false
            $result.checkId | Should -Be 'START.KEYVAULT'
            $result.status | Should -Be 'Pass'
            $script:stored | Should -BeExactly $plain
            $script:stored | Should -Not -Be 'System.Security.SecureString'
            $writes = @($script:azCalls | Where-Object { $_ -like 'keyvault secret set *' })
            $writes.Count | Should -Be 3
            foreach ($write in $writes) {
                $write | Should -Not -Match ([regex]::Escape($plain))
                $write | Should -Match ('--vault-name {0} --name archost01-one-time-password' -f $script:vaultName)
                $write | Should -Match '--encoding utf-8 --content-type password --expires 2026-10-21T22:00:00Z'
                $write | Should -Match '--tags vmName=archost01 userName=demoadmin --query id --output tsv'
            }
            Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly
            @($script:disabledIds) | Should -Be @($script:secretBase + 'old1')
            $result.evidence.version | Should -Be 'new1'
            $result.evidence.olderVersionsDisabled | Should -Be 1
            $result.message | Should -Match 'Username and password'
            $result.message | Should -Match 'no Key Vault option'
            ($result | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($plain))
        }

        It 'doesn''t retry a firewall refusal, and says how to open it' {
            $script:firewall = $true
            $result = Set-DemoHostPasswordSecret -Config $config -Password (ConvertTo-TestSecureString 'Tq9-long-enough.value') -Confirm:$false
            $result.status | Should -Be 'Fail'
            $result.remediation | Should -Match 'keyVault\.allowedIpRanges'
            $result.remediation | Should -Match 'Nothing changed on the VM'
            @($script:azCalls | Where-Object { $_ -like 'keyvault secret set *' }).Count | Should -Be 1
            Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
        }

        It 'refuses a value that is a type name, what a SecureString bound to a string becomes' {
            $result = Set-DemoHostPasswordSecret -Config $config -Password (ConvertTo-TestSecureString 'System.Security.SecureString') -Confirm:$false
            $result.status | Should -Be 'Fail'
            @($script:azCalls | Where-Object { $_ -like 'keyvault secret set *' }).Count | Should -Be 0
        }

        It 'fails without writing when the vault doesn''t exist' {
            $script:vault = $null
            $result = Set-DemoHostPasswordSecret -Config $config -Password (ConvertTo-TestSecureString 'Tq9-long-enough.value') -Confirm:$false
            $result.status | Should -Be 'Fail'
            $result.remediation | Should -Match 'start-demo\.ps1 -Interactive -ResetAdminPassword'
            @($script:azCalls | Where-Object { $_ -like 'keyvault secret*' }).Count | Should -Be 0
        }
    }

    Context 'Disable-DemoHostPasswordSecret' {
        BeforeEach {
            $script:vault = @{ retention = 7; purge = $false; location = 'westus3' }
        }

        It 'disables every enabled version and deletes nothing' {
            $script:versions = @(
                @{ id = ($script:secretBase + 'old0'); attributes = @{ enabled = $false } }
                @{ id = ($script:secretBase + 'v1'); attributes = @{ enabled = $true } }
                @{ id = ($script:secretBase + 'v2'); attributes = @{ enabled = $true } }
            )
            $result = Disable-DemoHostPasswordSecret -Config $config -Confirm:$false
            $result.checkId | Should -Be 'STOP.KEYVAULT'
            $result.status | Should -Be 'Pass'
            $result.message | Should -Match 'Disabled 2 version'
            @($script:disabledIds) | Should -Be @(($script:secretBase + 'v1'), ($script:secretBase + 'v2'))
            @($script:azCalls | Where-Object { $_ -like '*delete*' -or $_ -like '*purge*' }).Count | Should -Be 0
        }

        It 'reports a refusal as a Warning with the portal steps, and a missing vault as Not selected' {
            $script:listError = 'ERROR: (Forbidden) Caller is not authorized to perform action on resource. Code: Forbidden Inner error: ForbiddenByRbac'
            $result = Disable-DemoHostPasswordSecret -Config $config -CheckId 'START.KEYVAULT.CLEANUP' -Confirm:$false
            $result.checkId | Should -Be 'START.KEYVAULT.CLEANUP'
            $result.status | Should -Be 'Warning'
            $result.remediation | Should -Match 'Enabled to No'
            $result.remediation | Should -Match 'operatorObjectIds'

            $script:vault = $null
            (Disable-DemoHostPasswordSecret -Config $config -Confirm:$false).status | Should -Be 'Not selected'
        }
    }

    Context 'Status and destroy' {
        It 'reports a readable password past its expiry as a Warning, a current one as Pass, and a missing vault as a Warning' {
            $script:vault = @{ retention = 7; purge = $false; location = 'westus3' }
            $script:versions = @(@{ id = ($script:secretBase + 'v1'); attributes = @{ enabled = $true; expires = '2026-10-21T22:00:00Z' } })
            $statusAt = {
                param([datetime] $Now)
                InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config; Now = $Now } -ScriptBlock {
                    param($Config, $Now)
                    Get-DemoKeyVaultStatus -Config $Config -DeploymentId 'abc123' -VmName 'archost01' -NowUtc $Now
                }
            }
            $late = & $statusAt ([datetime]::new(2026, 10, 21, 23, 0, 0, [System.DateTimeKind]::Utc))
            $late.checkId | Should -Be 'STATUS.KEYVAULT'
            $late.status | Should -Be 'Warning'
            $late.remediation | Should -Match 'stop-demo\.ps1 -RemoveBastionOnly'
            $current = & $statusAt ([datetime]::new(2026, 10, 21, 20, 0, 0, [System.DateTimeKind]::Utc))
            $current.status | Should -Be 'Pass'
            $current.message | Should -Match 'until 2026-10-21T22:00:00Z'
            $script:vault = $null
            (& $statusAt ([datetime]::new(2026, 10, 21, 20, 0, 0, [System.DateTimeKind]::Utc))).status | Should -Be 'Warning'
        }

        It 'reports that destroy.ps1 leaves the vault soft-deleted, and for how long' {
            $script:vault = @{ retention = 7; purge = $false; location = 'westus3' }
            $script:groupExists = $true
            Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'ok' }
            Mock -ModuleName DbHubDemo -CommandName Test-DemoResourceGroupExist -MockWith { $script:groupExists }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -MockWith { @() }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { $script:groupExists = $false; New-AzResult }
            # The manifest and the residual check have their own tests (DbHubDemo.Teardown.Tests.ps1).
            Mock -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -MockWith { [pscustomobject]@{ ResourceGroupName = 'rg-dbhub-demo'; ResourceGroupExisted = $true; DeploymentId = 'abc123'; Principals = @() } }
            Mock -ModuleName DbHubDemo -CommandName Test-DemoTeardownResidue -MockWith { New-DemoResult -CheckId 'TEARDOWN.RESIDUAL.KEYVAULT' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message 'soft-deleted' }
            # The golden snapshot guard (ADR 0018) has its own tests too; here a boot-verified snapshot keeps T2.
            Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @([pscustomobject]@{ Name = 'snap-dbhub-t2golden-202601010000'; BootVerifiedUtc = [datetime]'2026-01-01'; EvalDaysLeft = 100 }) }
            $results = Remove-DemoEnvironment -Config $config -Confirm:$false
            $note = $results | Where-Object { $_.checkId -eq 'DESTROY.KEYVAULT' }
            $note.status | Should -Be 'Pass'
            $note.area | Should -Be 'teardown'
            $note.message | Should -Match ('{0} is soft-deleted' -f $script:vaultName)
            $note.message | Should -Match '7 days'
            @($script:azCalls | Where-Object { $_ -like 'keyvault purge*' }).Count | Should -Be 0 -Because 'destroy never purges; a later deploy recovers the vault'
        }
    }
}
