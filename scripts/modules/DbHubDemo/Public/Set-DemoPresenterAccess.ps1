function Set-DemoPresenterAccess {
    <#
    .SYNOPSIS
    Gives the presenters listed in presenterObjectIds the Azure access the Database Hub needs, only when
    assignRoles is true; otherwise prints the exact commands an administrator runs (HUB.PRESENTER.READER,
    HUB.PRESENTER.ARCTELEMETRY).

    .DESCRIPTION
    Contributors already have everything the Hub needs, so presenterObjectIds lists only presenters who
    aren't Contributors (prerequisite P8, ADR 0008). Two grants:
    - Reader on the subscription: Hub discovery and performance data need Reader (or higher) on each
      subscription (https://learn.microsoft.com/fabric/database/hub/monitor-sql).
    - "Azure Hybrid Database Administrator - Read Only Service Role" on the demo resource group: Arc SQL
      performance data needs Microsoft.AzureArcData/sqlServerInstances/getTelemetry/action, which Reader
      doesn't include and this built-in role does (https://learn.microsoft.com/fabric/database/hub/add-sql).
      The role is resolved by name at run time; its ID is never pinned (the RBAC catalog pages don't list
      it, risk R22). Not supported when t2SqlInstallMode is Developer, because T2 then has no telemetry.

    With assignRoles false (the default), nothing is called: each grant is Manual action required, with one
    'az role assignment create' command per presenter for an Owner, User Access Administrator, or Role Based
    Access Control Administrator. With assignRoles true, the function checks that the caller can create
    role assignments at the scope (Microsoft.Authorization/permissions), resolves the role definition by
    name ('az role definition list --name'), skips presenters who already hold it at the scope or above
    ('az role assignment list --include-inherited'), and creates the rest ('az role assignment create
    --assignee-object-id --assignee-principal-type User': presenters are people, and with the type given the
    Azure CLI makes no Microsoft Graph lookup, which would go to its default account's tenant). Every call
    goes through Invoke-DemoAz.
    With -WhatIf, nothing is created and the grant is reported as Not selected. No presenters: Not selected.
    https://learn.microsoft.com/cli/azure/role/assignment

    .PARAMETER Config
    Configuration from Get-DemoConfig (assignRoles, presenterObjectIds).

    .EXAMPLE
    Set-DemoPresenterAccess -Config $config -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $settings = Get-DemoHubSetting
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroup = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $subscriptionScope = '/subscriptions/{0}' -f $subscriptionId
    $groupScope = '{0}/resourceGroups/{1}' -f $subscriptionScope, $resourceGroup
    $installMode = if ($Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'PaygWizard' }
    $permissionsApi = [string]$settings['authorizationPermissionsApiVersion']
    $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $presenters = @(@($Config['presenterObjectIds']) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    foreach ($presenter in $presenters) {
        if ($presenter -notmatch $guidPattern) {
            throw "presenterObjectIds contains '$presenter', which isn't an object ID."
        }
    }

    $grants = @(
        [pscustomobject]@{
            CheckId  = 'HUB.PRESENTER.READER'
            Target   = 'subscription'
            RoleName = 'Reader'
            Scope    = $subscriptionScope
            Purpose  = 'Reader on the subscription (Hub discovery and performance data, prerequisite P8)'
            DocUrl   = 'https://learn.microsoft.com/fabric/database/hub/monitor-sql'
        }
        [pscustomobject]@{
            CheckId  = 'HUB.PRESENTER.ARCTELEMETRY'
            Target   = 'T2'
            RoleName = [string]$settings['arcTelemetryRole']['roleName']
            Scope    = $groupScope
            Purpose  = 'the Arc telemetry role on the demo resource group (Microsoft.AzureArcData/sqlServerInstances/getTelemetry/action for T2 performance data)'
            DocUrl   = [string]$settings['arcTelemetryRole']['docUrl']
        }
    )

    function Get-AssignCommand([object] $Grant, [string] $Presenter) {
        $role = if ($Grant.RoleName -match '\s') { '"{0}"' -f $Grant.RoleName } else { $Grant.RoleName }
        'az role assignment create --subscription {0} --assignee-object-id {1} --assignee-principal-type User --role {2} --scope {3}' -f $subscriptionId, $Presenter, $role, $Grant.Scope
    }
    function Get-AdminText([object] $Grant, [string[]] $Who) {
        $commands = @($Who | ForEach-Object { Get-AssignCommand $Grant $_ })
        'An Owner, User Access Administrator, or Role Based Access Control Administrator runs: {0}' -f ($commands -join ' ; ')
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($grant in $grants) {
        $evidence = [ordered]@{ roleName = $grant.RoleName; scope = $grant.Scope; presenters = $presenters.Count; assignRoles = [bool]$Config['assignRoles'] }
        if ($presenters.Count -eq 0) {
            $results.Add((New-DemoResult -CheckId $grant.CheckId -Area 'hub' -Target $grant.Target -Status 'Not selected' -Message ('No presenters are listed in presenterObjectIds, so {0} isn''t needed; Contributors already have Hub access.' -f $grant.Purpose) -Evidence $evidence -DocUrl $grant.DocUrl))
            continue
        }
        if ($grant.Target -eq 'T2' -and $installMode -eq 'Developer') {
            $results.Add((New-DemoResult -CheckId $grant.CheckId -Area 'hub' -Target $grant.Target -Status 'Not supported' -Message 'T2 runs SQL Server Developer edition, which sends no Arc performance telemetry, so the Arc telemetry role isn''t needed.' -Evidence $evidence -DocUrl $grant.DocUrl))
            continue
        }
        if (-not $Config['assignRoles']) {
            $results.Add((New-DemoResult -CheckId $grant.CheckId -Area 'hub' -Target $grant.Target -Status 'Manual action required' -Message ('assignRoles is false, so {0} must be granted by an administrator to {1} presenter(s).' -f $grant.Purpose, $presenters.Count) -Evidence $evidence -Remediation (Get-AdminText $grant $presenters) -DocUrl $grant.DocUrl))
            continue
        }

        # assignRoles is true: check the caller's rights at the scope first.
        $permissionUrl = 'https://management.azure.com{0}/providers/Microsoft.Authorization/permissions?api-version={1}' -f $grant.Scope, $permissionsApi
        $permissions = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $permissionUrl) -AsJson -AllowFailure
        $permissionValue = Get-DemoMemberValue -InputObject $permissions -Name 'value'
        $permissionEntries = @($permissionValue | Where-Object { $null -ne $_ })
        $allowed = $null -ne $permissions -and (Test-DemoPermission -Permission $permissionEntries -Action 'Microsoft.Authorization/roleAssignments/write')
        if (-not $allowed) {
            $results.Add((New-DemoResult -CheckId $grant.CheckId -Area 'hub' -Target $grant.Target -Status 'Fail' -Message ('assignRoles is true, but the caller can''t create role assignments at {0}.' -f $grant.Scope) -Evidence $evidence -Remediation ('Set assignRoles to false, or: {0}' -f (Get-AdminText $grant $presenters)) -DocUrl 'https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview'))
            continue
        }

        $definitions = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('role', 'definition', 'list', '--name', $grant.RoleName, '--scope', $grant.Scope) -AsJson -AllowFailure
        $definition = @($definitions) | Where-Object { $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'roleName') -ieq $grant.RoleName } | Select-Object -First 1
        if (-not $definition) {
            $results.Add((New-DemoResult -CheckId $grant.CheckId -Area 'hub' -Target $grant.Target -Status 'Fail' -Message ('The role ''{0}'' wasn''t found by name at {1}.' -f $grant.RoleName, $grant.Scope) -Evidence $evidence -Remediation ('Check the role name on {0}; the RBAC catalog pages don''t list every built-in role (risk R22).' -f $grant.DocUrl) -DocUrl $grant.DocUrl))
            continue
        }
        $definitionId = [string](Get-DemoMemberValue -InputObject $definition -Name 'id')
        $evidence['roleDefinitionId'] = $definitionId

        $states = [ordered]@{}
        $errors = [System.Collections.Generic.List[string]]::new()
        foreach ($presenter in $presenters) {
            $existing = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('role', 'assignment', 'list', '--assignee-object-id', $presenter, '--role', $definitionId, '--scope', $grant.Scope, '--include-inherited', '--fill-principal-name', 'false') -AsJson -AllowFailure
            if (@($existing | Where-Object { $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'principalId') -ieq $presenter }).Count -gt 0) {
                $states[$presenter] = 'existing'
                continue
            }
            if (-not $PSCmdlet.ShouldProcess($presenter, ('Assign {0} at {1}' -f $grant.RoleName, $grant.Scope))) {
                $states[$presenter] = 'pending'
                continue
            }
            $create = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('role', 'assignment', 'create', '--assignee-object-id', $presenter, '--assignee-principal-type', 'User', '--role', $definitionId, '--scope', $grant.Scope) -AllowFailure
            if ($create.ExitCode -eq 0) {
                $states[$presenter] = 'created'
                Write-DemoLog -Level Success -Message ('Assigned {0} at {1} to presenter {2}.' -f $grant.RoleName, $grant.Scope, $presenter)
            }
            elseif ([string]$create.StdErr -match 'RoleAssignmentExists|already exists') {
                $states[$presenter] = 'existing'
            }
            else {
                $states[$presenter] = 'failed'
                $errors.Add(('{0}: {1}' -f $presenter, (Protect-DemoText -Text ([string]$create.StdErr).Trim())))
            }
        }

        $evidence['assignments'] = $states
        $counts = @{}
        foreach ($state in 'created', 'existing', 'pending', 'failed') {
            $counts[$state] = @($states.Values | Where-Object { $_ -eq $state }).Count
        }
        if ($counts['failed'] -gt 0) {
            $failed = @($states.Keys | Where-Object { $states[$_] -eq 'failed' })
            $results.Add((New-DemoResult -CheckId $grant.CheckId -Area 'hub' -Target $grant.Target -Status 'Fail' -Message ('{0} couldn''t be assigned to {1} presenter(s): {2}' -f $grant.Purpose, $counts['failed'], ($errors -join ' | ')) -Evidence $evidence -Remediation (Get-AdminText $grant $failed) -DocUrl $grant.DocUrl))
        }
        elseif ($counts['pending'] -gt 0) {
            $results.Add((New-DemoResult -CheckId $grant.CheckId -Area 'hub' -Target $grant.Target -Status 'Not selected' -Message ('WhatIf: {0} would be assigned to {1} presenter(s); {2} already have it.' -f $grant.Purpose, $counts['pending'], $counts['existing']) -Evidence $evidence -DocUrl $grant.DocUrl))
        }
        else {
            $results.Add((New-DemoResult -CheckId $grant.CheckId -Area 'hub' -Target $grant.Target -Status 'Pass' -Message ('Presenters have {0}: {1} assigned now, {2} already had it.' -f $grant.Purpose, $counts['created'], $counts['existing']) -Evidence $evidence -DocUrl $grant.DocUrl))
        }
    }

    return $results.ToArray()
}
