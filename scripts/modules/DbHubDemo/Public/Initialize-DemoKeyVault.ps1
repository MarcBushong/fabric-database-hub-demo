function Initialize-DemoKeyVault {
    <#
    .SYNOPSIS
    Deploys the opt-in Key Vault for the one-time T2 host password and gives the operator access to it,
    only when keyVault.enabled is true (ADR 0008, ADR 0009). deploy.ps1 runs it after the template, and
    start-demo.ps1 -Interactive -ResetAdminPassword makes sure of it before it writes the password.

    .DESCRIPTION
    - Off (the default): Not selected, and nothing is called. The default path creates no vault and no role
      assignment.
    - The vault: infra/modules/keyvault.bicep, deployed into the demo resource group with 'az deployment
      group create' as kv-<prefix><environment>-<deploymentId>, with RBAC authorization, soft delete
      (keyVault.softDeleteRetentionDays, 7 days by default), purge protection only with
      keyVault.purgeProtection, and the firewall open unless keyVault.allowedIpRanges lists addresses. Key
      Vault fixes the retention when the vault is created, and purge protection can't be turned off, so an
      existing vault keeps its own values. A vault that destroy.ps1 soft-deleted is recovered under the same
      name ('az keyvault recover'), because a soft-deleted vault's name can't be reused until its retention
      ends. A tenant policy that denies the vault fails the deployment with the policy's name in the message.
    - Access, on the vault only: the signed-in caller and keyVault.operatorObjectIds get "Key Vault Secrets
      Officer" (write and disable the password), and keyVault.readerObjectIds get "Key Vault Secrets User"
      (read it in the portal). The roles are resolved by name ('az role definition list --name'), principals
      that already hold them are skipped ('az role assignment list --include-inherited'), and the rest are
      created ('az role assignment create --assignee-object-id --assignee-principal-type'; the caller's type
      comes from the subscription guard's verified token, and the configured principals' types from
      Microsoft Graph's directoryObjects/getByIds with a token verified for the configured tenant). That needs
      Microsoft.Authorization/roleAssignments/write, which is why keyVault.enabled requires assignRoles; the
      permission is checked before a new vault is deployed, so no vault is left that nobody can use.
    - -EnsureOnly (start-demo.ps1): an existing vault isn't redeployed; only missing role assignments are
      added.
    Returns INFRA.KEYVAULT and INFRA.KEYVAULT.ACCESS. A new role assignment can take several minutes to reach
    Key Vault; Set-DemoHostPasswordSecret waits for it.

    Sources (checked 2026-10-21):
    - Key Vault RBAC and its built-in roles: https://learn.microsoft.com/azure/key-vault/general/rbac-guide
    - Soft delete and recovery: https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview
    - az keyvault show, show-deleted, recover: https://learn.microsoft.com/cli/azure/keyvault
    - az role assignment: https://learn.microsoft.com/cli/azure/role/assignment

    .PARAMETER Config
    Configuration from Get-DemoConfig (keyVault, assignRoles).

    .PARAMETER EnsureOnly
    Leave an existing vault as it is; only add missing role assignments.

    .EXAMPLE
    Initialize-DemoKeyVault -Config $config
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $EnsureOnly
    )

    $settings = Get-DemoKeyVaultSetting -Config $Config
    $docUrl = 'https://learn.microsoft.com/azure/key-vault/general/rbac-guide'
    if (-not $settings.Enabled) {
        return @(New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message 'The Key Vault opt-in is off (keyVault.enabled): the one-time host password goes to the clipboard, and no vault or role assignment is created.' -DocUrl $docUrl)
    }
    if (-not $Config['assignRoles']) {
        return @(New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message 'keyVault.enabled needs assignRoles true: access to the vault is a role assignment on the vault (ADR 0008).' -Remediation 'Set assignRoles to true and run as an Owner, User Access Administrator, or Role Based Access Control Administrator; or set keyVault.enabled to false and use the clipboard.' -DocUrl $docUrl)
    }

    $subscriptionId = [string]$Config['subscriptionId']
    $vault = Get-DemoKeyVaultTarget -Config $Config
    if (-not $vault.Name) {
        return @(New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('{0} or its deploymentId tag doesn''t exist, so the vault has no name yet.' -f $vault.ResourceGroup) -Remediation 'Run deploy.ps1 first: its Infrastructure stage creates the vault after the template.' -DocUrl $docUrl)
    }
    $results = [System.Collections.Generic.List[object]]::new()
    $groupScope = '/subscriptions/{0}/resourceGroups/{1}' -f $subscriptionId, $vault.ResourceGroup
    $permissionsApi = [string](Get-DemoHubSetting)['authorizationPermissionsApiVersion']
    $canAssign = {
        param([string] $Scope)
        $url = 'https://management.azure.com{0}/providers/Microsoft.Authorization/permissions?api-version={1}' -f $Scope, $permissionsApi
        $permissions = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $url) -AsJson -AllowFailure
        # Get-DemoMemberValue returns an array whole; assigned first, it's enumerated below.
        $permissionValue = Get-DemoMemberValue -InputObject $permissions -Name 'value'
        $entries = @($permissionValue | Where-Object { $null -ne $_ })
        return ($null -ne $permissions -and (Test-DemoPermission -Permission $entries -Action 'Microsoft.Authorization/roleAssignments/write'))
    }

    # Who gets which role: the caller and keyVault.operatorObjectIds write, keyVault.readerObjectIds read.
    $caller = Get-DemoCallerIdentity -SubscriptionId $subscriptionId
    $grants = [System.Collections.Generic.List[object]]::new()
    $officers = [System.Collections.Generic.List[string]]::new()
    if ($caller.ObjectId) {
        $officers.Add($caller.ObjectId)
        $grants.Add([pscustomobject]@{ ObjectId = $caller.ObjectId; PrincipalType = $caller.PrincipalType; RoleName = 'Key Vault Secrets Officer' })
    }
    foreach ($id in $settings.OperatorObjectIds) {
        if (-not $officers.Contains($id)) {
            $officers.Add($id)
            $grants.Add([pscustomobject]@{ ObjectId = $id; PrincipalType = ''; RoleName = 'Key Vault Secrets Officer' })
        }
    }
    foreach ($id in $settings.ReaderObjectIds) {
        if (-not $officers.Contains($id)) {
            $grants.Add([pscustomobject]@{ ObjectId = $id; PrincipalType = ''; RoleName = 'Key Vault Secrets User' })
        }
    }
    # The Azure CLI looks a principal's type up in its default account's tenant unless the type is given, so
    # it's read from Microsoft Graph here with a token verified for the configured tenant.
    $untyped = @($grants | Where-Object { -not $_.PrincipalType } | ForEach-Object { $_.ObjectId })
    if ($untyped.Count -gt 0) {
        $types = Resolve-DemoPrincipalType -SubscriptionId $subscriptionId -ObjectId $untyped
        foreach ($grant in $grants) {
            if (-not $grant.PrincipalType -and $types.ContainsKey($grant.ObjectId)) {
                $grant.PrincipalType = $types[$grant.ObjectId]
            }
        }
    }
    $adminText = {
        param([object[]] $Items)
        $commands = foreach ($item in $Items) {
            $type = if ($item.PrincipalType) { $item.PrincipalType } else { '<User|Group|ServicePrincipal>' }
            'az role assignment create --subscription {0} --assignee-object-id {1} --assignee-principal-type {2} --role "{3}" --scope {4}' -f $subscriptionId, $item.ObjectId, $type, $item.RoleName, $vault.Id
        }
        'An Owner, User Access Administrator, or Role Based Access Control Administrator runs: {0}' -f (@($commands) -join ' ; ')
    }

    # The vault: deployed when it's missing (or recovered when destroy.ps1 soft-deleted it), redeployed otherwise.
    $evidence = [ordered]@{ vaultName = $vault.Name; softDeleteRetentionDays = $settings.RetentionDays; purgeProtection = $settings.PurgeProtection; allowedIpRanges = $settings.AllowedIpRanges.Count; recovered = $false }
    $existing = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('keyvault', 'show', '--name', $vault.Name, '--resource-group', $vault.ResourceGroup) -AsJson -AllowFailure
    $deploy = ($null -eq $existing) -or (-not $EnsureOnly)
    if ($null -eq $existing) {
        if (-not (& $canAssign $groupScope)) {
            $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('No vault was deployed: the caller can''t create role assignments on {0}, so nobody could use it.' -f $vault.ResourceGroup) -Evidence $evidence -Remediation 'Run deploy.ps1 as an Owner, User Access Administrator, or Role Based Access Control Administrator of the resource group, or set keyVault.enabled to false and use the clipboard.' -DocUrl 'https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview'))
            return $results.ToArray()
        }
        $deleted = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('keyvault', 'show-deleted', '--name', $vault.Name) -AsJson -AllowFailure
        if ($null -ne $deleted) {
            if (-not $PSCmdlet.ShouldProcess($vault.Name, 'Recover the soft-deleted Key Vault')) {
                $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('What if: the soft-deleted vault {0} wasn''t recovered.' -f $vault.Name) -Evidence $evidence))
                return $results.ToArray()
            }
            $deletedLocation = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $deleted -Name 'properties') -Name 'location')
            $recoverArguments = @('keyvault', 'recover', '--name', $vault.Name, '--resource-group', $vault.ResourceGroup)
            if ($deletedLocation) {
                $recoverArguments += @('--location', $deletedLocation)
            }
            Write-DemoLog -Message ('Recovering the soft-deleted vault {0}: a soft-deleted name can''t be reused until its retention ends.' -f $vault.Name)
            $recover = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $recoverArguments -AllowFailure
            if ($recover.ExitCode -ne 0) {
                $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('The soft-deleted vault {0} couldn''t be recovered: {1}' -f $vault.Name, (Get-DemoDeploymentErrorText -Text $recover.StdErr -MaxLength 600)) -Evidence $evidence -Remediation ('Recover it in the portal (Key vaults, then Manage deleted vaults), or, without purge protection, purge it: az keyvault purge --subscription {0} --name {1}. Then run deploy.ps1 -FromStage Infrastructure -StopAfter Infrastructure.' -f $subscriptionId, $vault.Name) -DocUrl 'https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview'))
                return $results.ToArray()
            }
            $evidence['recovered'] = $true
            $existing = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('keyvault', 'show', '--name', $vault.Name, '--resource-group', $vault.ResourceGroup) -AsJson -AllowFailure
            $deploy = $true
        }
    }

    if ($deploy) {
        $location = [string]$Config['location']
        $retention = $settings.RetentionDays
        $purge = $settings.PurgeProtection
        if ($null -ne $existing) {
            # Fixed at creation (retention) or irreversible (purge protection): an existing vault keeps its own.
            $properties = Get-DemoMemberValue -InputObject $existing -Name 'properties'
            $currentRetention = Get-DemoMemberValue -InputObject $properties -Name 'softDeleteRetentionInDays'
            if ($null -ne $currentRetention -and [int]$currentRetention -ne $retention) {
                Write-DemoLog -Level Warning -Message ('{0} keeps its soft-delete retention of {1} days: Key Vault fixes it when the vault is created.' -f $vault.Name, $currentRetention)
                $retention = [int]$currentRetention
            }
            if ([bool](Get-DemoMemberValue -InputObject $properties -Name 'enablePurgeProtection') -and -not $purge) {
                Write-DemoLog -Level Warning -Message ('{0} keeps purge protection: it can''t be turned off.' -f $vault.Name)
                $purge = $true
            }
            $currentLocation = [string](Get-DemoMemberValue -InputObject $existing -Name 'location')
            if ($currentLocation) {
                $location = $currentLocation
            }
        }
        $evidence['softDeleteRetentionDays'] = $retention
        $evidence['purgeProtection'] = $purge
        if (-not $PSCmdlet.ShouldProcess($vault.ResourceGroup, ('Deploy the Key Vault {0}' -f $vault.Name))) {
            $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} wasn''t deployed, and no role was assigned.' -f $vault.Name) -Evidence $evidence))
            return $results.ToArray()
        }
        $stateTags = @((Get-DemoDeploymentStateTagName).Values)
        $keep = @{}
        foreach ($key in $vault.Tags.Keys) {
            if ($key -notin $stateTags) {
                $keep[$key] = $vault.Tags[$key]
            }
        }
        $parameters = [ordered]@{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = [ordered]@{
                location                  = @{ value = $location }
                vaultName                 = @{ value = $vault.Name }
                softDeleteRetentionInDays = @{ value = $retention }
                enablePurgeProtection     = @{ value = $purge }
                allowedIpRanges           = @{ value = [object[]]@($settings.AllowedIpRanges) }
                tags                      = @{ value = $keep }
            }
        }
        $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-keyvault'
        try {
            $path = Write-DemoPrivateFile -Directory $directory -Name 'keyvault.parameters.json' -Content ($parameters | ConvertTo-Json -Depth 10)
            Write-DemoLog -Message ('Deploying the Key Vault {0} (RBAC authorization, soft delete).' -f $vault.Name)
            $run = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('deployment', 'group', 'create', '--resource-group', $vault.ResourceGroup, '--name', 'keyvault-opt-in', '--template-file', (Join-Path -Path $script:RepoRoot -ChildPath 'infra/modules/keyvault.bicep'), '--parameters', "@$path") -AllowFailure
        }
        finally {
            Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
        }
        if ($run.ExitCode -ne 0) {
            $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('Deploying the Key Vault {0} failed: {1}' -f $vault.Name, (Get-DemoDeploymentErrorText -Text $run.StdErr -MaxLength 600)) -Evidence $evidence -Remediation 'A tenant policy may require purge protection (keyVault.purgeProtection), a firewall (keyVault.allowedIpRanges), or deny Key Vault; the error names the policy. Adjust the configuration and run deploy.ps1 -FromStage Infrastructure -StopAfter Infrastructure, or set keyVault.enabled to false and use the clipboard.' -DocUrl 'https://learn.microsoft.com/azure/key-vault/general/azure-policy'))
            return $results.ToArray()
        }
        $how = if ($evidence['recovered']) { 'recovered and deployed' } elseif ($null -eq $existing) { 'deployed' } else { 'up to date' }
        $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('The Key Vault {0} is {1}: RBAC authorization, soft delete for {2} days{3}, {4}.' -f $vault.Name, $how, $retention, $(if ($purge) { ' with purge protection' } else { '' }), $(if ($settings.AllowedIpRanges.Count) { 'firewall open to {0} range(s)' -f $settings.AllowedIpRanges.Count } else { 'firewall open to all networks (a role is still needed)' })) -Evidence $evidence -DocUrl $docUrl))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('The Key Vault {0} exists.' -f $vault.Name) -Evidence $evidence -DocUrl $docUrl))
    }

    # Access on the vault only, with the roles resolved by name.
    $accessEvidence = [ordered]@{ vaultName = $vault.Name; callerResolved = [bool]$caller.ObjectId; principals = $grants.Count }
    if ($grants.Count -eq 0) {
        $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT.ACCESS' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message 'Nobody was given access to the vault: the subscription guard hasn''t confirmed the caller''s object ID in this process, and keyVault.operatorObjectIds is empty.' -Evidence $accessEvidence -Remediation 'Run deploy.ps1 -FromStage Infrastructure -StopAfter Infrastructure, which runs the guard first; its PREFLIGHT.GUARD.CONTEXT evidence has your objectId. Or add that object ID to keyVault.operatorObjectIds.' -DocUrl $docUrl))
        return $results.ToArray()
    }
    $definitionIds = @{}
    foreach ($roleName in @($grants | ForEach-Object { $_.RoleName } | Select-Object -Unique)) {
        $definitions = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('role', 'definition', 'list', '--name', $roleName, '--scope', $groupScope) -AsJson -AllowFailure
        $definition = @($definitions) | Where-Object { $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'roleName') -ieq $roleName } | Select-Object -First 1
        if ($definition) {
            $definitionIds[$roleName] = [string](Get-DemoMemberValue -InputObject $definition -Name 'id')
        }
    }
    $states = [ordered]@{}
    $failed = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($grant in $grants) {
        $key = '{0} ({1})' -f $grant.ObjectId, $grant.RoleName
        $definitionId = $definitionIds[$grant.RoleName]
        if (-not $definitionId) {
            $states[$key] = 'failed'
            $failed.Add($grant)
            $errors.Add(('The role ''{0}'' wasn''t found by name.' -f $grant.RoleName))
            continue
        }
        $existingAssignments = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('role', 'assignment', 'list', '--assignee-object-id', $grant.ObjectId, '--role', $definitionId, '--scope', $vault.Id, '--include-inherited', '--fill-principal-name', 'false') -AsJson -AllowFailure
        if (@($existingAssignments | Where-Object { $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'principalId') -ieq $grant.ObjectId }).Count -gt 0) {
            $states[$key] = 'existing'
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($grant.ObjectId, ('Assign {0} on {1}' -f $grant.RoleName, $vault.Name))) {
            $states[$key] = 'pending'
            continue
        }
        if (-not $grant.PrincipalType) {
            $states[$key] = 'failed'
            $failed.Add($grant)
            $errors.Add(('{0}: its principal type couldn''t be read from Microsoft Graph, and without it the Azure CLI would look the principal up in its default account''s tenant.' -f $grant.ObjectId))
            continue
        }
        $createArguments = @('role', 'assignment', 'create', '--assignee-object-id', $grant.ObjectId, '--assignee-principal-type', $grant.PrincipalType, '--role', $definitionId, '--scope', $vault.Id)
        $create = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $createArguments -AllowFailure
        if ($create.ExitCode -eq 0) {
            $states[$key] = 'created'
            Write-DemoLog -Level Success -Message ('Assigned {0} on {1} to {2}.' -f $grant.RoleName, $vault.Name, $grant.ObjectId)
        }
        elseif ([string]$create.StdErr -match 'RoleAssignmentExists|already exists') {
            $states[$key] = 'existing'
        }
        else {
            $states[$key] = 'failed'
            $failed.Add($grant)
            $errors.Add(('{0}: {1}' -f $grant.ObjectId, (Get-DemoDeploymentErrorText -Text $create.StdErr -MaxLength 300)))
        }
    }
    $accessEvidence['assignments'] = $states
    $count = { param([string] $Name) @($states.Values | Where-Object { $_ -eq $Name }).Count }
    if ($failed.Count -gt 0) {
        $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT.ACCESS' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('{0} role assignment(s) on {1} failed: {2}' -f $failed.Count, $vault.Name, ($errors -join ' | ')) -Evidence $accessEvidence -Remediation (& $adminText $failed.ToArray()) -DocUrl $docUrl))
    }
    elseif ((& $count 'pending') -gt 0) {
        $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT.ACCESS' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} role assignment(s) on {1} weren''t created.' -f (& $count 'pending'), $vault.Name) -Evidence $accessEvidence -DocUrl $docUrl))
    }
    elseif (-not $caller.ObjectId) {
        $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT.ACCESS' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('The configured principals have their roles on {0}, but the subscription guard hasn''t confirmed the caller''s object ID in this process, so the caller got none.' -f $vault.Name) -Evidence $accessEvidence -Remediation 'If this identity writes or disables the password (start-demo.ps1, stop-demo.ps1), add its object ID (PREFLIGHT.GUARD.CONTEXT evidence) to keyVault.operatorObjectIds.' -DocUrl $docUrl))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'INFRA.KEYVAULT.ACCESS' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('Access to {0} is in place: {1} assigned now, {2} already there. A new assignment can take several minutes to reach Key Vault.' -f $vault.Name, (& $count 'created'), (& $count 'existing')) -Evidence $accessEvidence -DocUrl $docUrl))
    }
    return $results.ToArray()
}
