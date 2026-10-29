function Test-DemoTeardownResidue {
    <#
    .SYNOPSIS
    Checks that a destroyed environment left nothing behind, Arc resources included (ADR 0002, Phase 16).
    destroy.ps1 runs it after the resource group is gone, and the opt-in teardown tests run it again.

    .DESCRIPTION
    Read-only. Azure Resource Graph and Microsoft Entra are eventually consistent, so it polls for up to
    -WaitMinutes until the required checks are clean. Each check is one result (area teardown):
    - TEARDOWN.RESIDUAL.RESOURCEGROUP: the resource group is gone.
    - TEARDOWN.RESIDUAL.TAGGED: no resource or resource group carries the environment's tags (its deploymentId,
      or solution fabric-database-hub-demo with its environment), except rg-<prefix>-control, which stays.
    - TEARDOWN.RESIDUAL.GROUPRESOURCES: Resource Graph lists nothing in the group.
    - TEARDOWN.RESIDUAL.ARC: no Arc machine, machine extension, or SQL Server instance (or its databases) in
      the group, carrying the environment's tags, or hosted by a machine or VM of the group.
    - TEARDOWN.RESIDUAL.ROLEASSIGNMENTS: no role assignment at or under the group, and none for the
      identities in the manifest (an assignment elsewhere would be left behind as "Identity not found").
    - TEARDOWN.RESIDUAL.IDENTITIES: the manifest's identities are gone from Microsoft Entra, and none of them
      is still a member of the P6 group.
    - TEARDOWN.RESIDUAL.DEPLOYMENTS: no subscription-scope deployment <prefix>-<environment>-*.
    - TEARDOWN.RESIDUAL.BUDGET: the budget at the group's scope is gone.
    - TEARDOWN.RESIDUAL.REFERENCES: no resource outside the group still names it (a Warning: such a
      resource, for example one Azure Policy created, may be shared).
    - TEARDOWN.RESIDUAL.RECORDS: what Defender for Cloud (assessments), Azure Policy (compliance states), and
      guest configuration still list for the deleted resources. They aren't resources, don't bill, and age
      out on their own, so they're evidence, not residue: Pass either way, Warning only when unreadable.
    - TEARDOWN.RESIDUAL.KEYVAULT: with the Key Vault opt-in, a soft-deleted vault is a Warning (ADR 0009);
      Not selected otherwise.
    A check that can't be read is a Warning, never a Pass (ADR 0012). Azure Resource Graph and Microsoft Graph
    are read through Invoke-DemoRestRequest with tokens verified for the configured tenant and caller (ADR
    0011, guard update), and each only after a canary: Resource Graph must list the configured subscription,
    and Microsoft Graph must answer for the configured tenant. When a canary fails, its checks are Warnings,
    and the check doesn't wait for them. A manifest that didn't record the identities (taken after the group
    was gone) makes IDENTITIES a Warning, not a Pass.

    Sources (checked 2026-10-21):
    - Resource Graph tables (resources, resourcecontainers, authorizationresources, securityresources,
      policyresources, guestconfigurationresources):
      https://learn.microsoft.com/azure/governance/resource-graph/reference/supported-tables-resources
    - az deployment sub list: https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-list
    - Microsoft Graph: get organization (the tenant canary), https://learn.microsoft.com/graph/api/organization-get;
      directoryObject getByIds (which identities still exist),
      https://learn.microsoft.com/graph/api/directoryobject-getbyids; checkMemberGroups (P6 membership),
      https://learn.microsoft.com/graph/api/directoryobject-checkmembergroups
    - Budgets REST: https://learn.microsoft.com/rest/api/consumption/budgets/get
    - az keyvault list-deleted: https://learn.microsoft.com/cli/azure/keyvault#az-keyvault-list-deleted

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Manifest
    What Get-DemoTeardownManifest recorded before the destroy. Without it, the deploymentId and the
    identities are unknown: the tag checks use the solution and environment tags only, and the identity
    check reports a Warning.

    .PARAMETER WaitMinutes
    How long to poll while something still shows up (0: check once).

    .PARAMETER PollSeconds
    Seconds between polls.

    .EXAMPLE
    Test-DemoTeardownResidue -Config $config -Manifest $manifest -WaitMinutes 10
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Manifest,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 10,

        [ValidateRange(5, 600)]
        [int] $PollSeconds = 30
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $deploymentId = [string](Get-DemoMemberValue -InputObject $Manifest -Name 'DeploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        $deploymentId = ''
    }
    # Assigned first: Get-DemoMemberValue returns an array as one object, which @() wouldn't unroll.
    $principals = Get-DemoMemberValue -InputObject $Manifest -Name 'Principals'
    $principalIds = @(foreach ($principal in @($principals)) {
            $id = [string](Get-DemoMemberValue -InputObject $principal -Name 'PrincipalId')
            if ($id -match $guid) {
                $id.ToLowerInvariant()
            }
        })
    $groupObjectId = [string]$Config['t3AdminGroupObjectId']
    $vaultName = [string](Get-DemoMemberValue -InputObject $Manifest -Name 'KeyVaultName')
    # A manifest records the identities only while the group exists and Resource Graph can read it; one taken
    # after the group was gone knows none, which isn't the same as "there were none". Older manifests lack the
    # field and were taken while the group existed.
    $recorded = Get-DemoMemberValue -InputObject $Manifest -Name 'IdentitiesRecorded'
    if ($null -eq $recorded) {
        $recorded = Get-DemoMemberValue -InputObject $Manifest -Name 'ResourceGroupExisted'
    }
    $identitiesKnown = $null -ne $Manifest -and ($null -eq $recorded -or [bool]$recorded)
    $setting = [pscustomobject]@{
        SubscriptionId    = $subscriptionId
        TenantId          = [string]$Config['tenantId']
        ResourceGroupName = $resourceGroupName
        ResourceGroupId   = ('/subscriptions/{0}/resourcegroups/{1}' -f $subscriptionId, $resourceGroupName).ToLowerInvariant()
        ControlGroupName  = ('rg-{0}-control' -f $Config['prefix'])
        GoldenGroupName   = (Get-DemoGoldenResourceGroupName -Config $Config)
        Environment       = [string]$Config['environment']
        DeploymentId      = $deploymentId
        DeploymentPrefix  = ((Get-DemoMainDeploymentName -Config $Config) -replace 'main$', '')
        BudgetUrl         = ('https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Consumption/budgets/budget-{2}-{3}?api-version={4}' -f $subscriptionId, $resourceGroupName, $Config['prefix'], $Config['environment'], (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Consumption/budgets'))
        PrincipalIds      = $principalIds
        GroupObjectId     = $(if ($groupObjectId -match $guid) { $groupObjectId } else { '' })
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    # Bounded by passes as well as time, so a run whose waits return at once (a test) can't spin.
    $maxPasses = 1 + [int][math]::Ceiling($WaitMinutes * 60 / $PollSeconds)
    $passes = 0
    while ($true) {
        $passes++
        $snapshot = Get-DemoResidueSnapshot -Setting $setting
        $required = @($snapshot.Tagged) + @($snapshot.GroupResources) + @($snapshot.Arc) + @($snapshot.RoleAssignments) + @($snapshot.Principals) + @($snapshot.Members) + @($snapshot.Deployments)
        # An error a canary explains (a token for another tenant) doesn't clear by waiting; anything else may.
        $transient = @($snapshot.Errors.Keys | Where-Object { $_ -notin @($snapshot.Unverifiable) })
        $settled = -not $snapshot.GroupExists -and -not $snapshot.BudgetExists -and @($required | Where-Object { $_ }).Count -eq 0 -and $transient.Count -eq 0
        if ($settled -or $passes -ge $maxPasses -or $watch.Elapsed.TotalMinutes -ge $WaitMinutes) {
            break
        }
        Write-DemoLog -Message ('Residual check {0}: something still shows up; checking again in {1} seconds (up to {2} minutes).' -f $passes, $PollSeconds, $WaitMinutes)
        Start-Sleep -Seconds $PollSeconds
    }
    $final = Get-DemoResidueSnapshot -Setting $setting -Extended

    $results = [System.Collections.Generic.List[object]]::new()
    $waited = [math]::Round($watch.Elapsed.TotalMinutes, 1)
    $add = {
        param([string] $Name, [string] $Status, [string] $Message, [object[]] $Items = @(), [string] $Remediation = '', [string] $DocUrl = '', [string] $Target = 'subscription')
        $evidence = [ordered]@{ remaining = @($Items | Where-Object { $_ } | Select-Object -First 50); waitedMinutes = $waited; passes = $passes }
        $results.Add((New-DemoResult -CheckId ('TEARDOWN.RESIDUAL.{0}' -f $Name) -Area 'teardown' -Target $Target -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $DocUrl))
    }
    $verdict = {
        param([string] $Key, [object[]] $Items)
        if ($final.Errors.Contains($Key)) { 'Warning' } elseif (@($Items | Where-Object { $_ }).Count -gt 0) { 'Fail' } else { 'Pass' }
    }
    $count = { param([object[]] $Items) @($Items | Where-Object { $_ }).Count }
    $graphDoc = 'https://learn.microsoft.com/azure/governance/resource-graph/reference/supported-tables-resources'
    $rerun = 'Run destroy.ps1 again: it deletes whatever is left in the group and checks again.'
    $deleteByName = 'delete them in the portal, or with az resource delete --resource-group <group> --name <name> --resource-type <type>'

    $status = if ($final.Errors.Contains('Group')) { 'Warning' } elseif ($final.GroupExists) { 'Fail' } else { 'Pass' }
    & $add 'RESOURCEGROUP' $status $(switch ($status) { 'Pass' { '{0} is gone.' -f $resourceGroupName } 'Fail' { '{0} still exists.' -f $resourceGroupName } default { 'Whether {0} exists couldn''t be read: {1}' -f $resourceGroupName, $final.Errors['Group'] } }) @() $(if ($status -eq 'Fail') { $rerun } else { '' }) 'https://learn.microsoft.com/cli/azure/group#az-group-exists'

    # Without the manifest the deploymentId is unknown, but every resource also carries solution and environment.
    $tagText = if ($deploymentId) { 'deploymentId {0}, or solution fabric-database-hub-demo with environment {1}' -f $deploymentId, $Config['environment'] } else { 'solution fabric-database-hub-demo with environment {0}; the deploymentId is unknown without the manifest' -f $Config['environment'] }
    $status = & $verdict 'Tagged' $final.Tagged
    & $add 'TAGGED' $status $(switch ($status) { 'Pass' { 'Nothing in the subscription carries the environment''s tags ({0}).' -f $tagText } 'Fail' { '{0} resource(s) or resource group(s) still carry the environment''s tags ({1}).' -f (& $count $final.Tagged), $tagText } default { 'Resource Graph couldn''t be read: {0}' -f $final.Errors['Tagged'] } }) $final.Tagged $(if ($status -eq 'Fail') { 'Check that they belong to this environment, then {0}; run the check again.' -f $deleteByName } else { '' }) $graphDoc

    $status = & $verdict 'GroupResources' $final.GroupResources
    & $add 'GROUPRESOURCES' $status $(switch ($status) { 'Pass' { 'Resource Graph lists nothing in {0}.' -f $resourceGroupName } 'Fail' { 'Resource Graph still lists {0} resource(s) in {1}.' -f (& $count $final.GroupResources), $resourceGroupName } default { 'Resource Graph couldn''t be read: {0}' -f $final.Errors['GroupResources'] } }) $final.GroupResources $(if ($status -eq 'Fail') { $rerun } else { '' }) $graphDoc

    $status = & $verdict 'Arc' $final.Arc
    & $add 'ARC' $status $(switch ($status) { 'Pass' { 'No Arc machine, machine extension, or SQL Server instance of this environment is left.' } 'Fail' { '{0} Arc resource(s) are left.' -f (& $count $final.Arc) } default { 'The Arc resources couldn''t be read: {0}' -f $final.Errors['Arc'] } }) $final.Arc $(if ($status -eq 'Fail') { 'Run destroy.ps1 again, or {0}: the SQL Server instances first, then the machines.' -f $deleteByName } else { '' }) 'https://learn.microsoft.com/sql/sql-server/azure-arc/delete-from-azure-arc' 'T2'

    $status = & $verdict 'RoleAssignments' $final.RoleAssignments
    & $add 'ROLEASSIGNMENTS' $status $(switch ($status) { 'Pass' { 'No role assignment is left at or under the group, or for the environment''s identities.' } 'Fail' { '{0} role assignment(s) are left.' -f (& $count $final.RoleAssignments) } default { 'The role assignments couldn''t be read: {0}' -f $final.Errors['RoleAssignments'] } }) $final.RoleAssignments $(if ($status -eq 'Fail') { 'Someone who can delete role assignments (Owner, User Access Administrator, or Role Based Access Control Administrator; Contributor can''t) removes them in the portal under Access control (IAM), Role assignments, where an orphaned one shows as Identity not found.' } else { '' }) 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-remove'

    if (-not $identitiesKnown) {
        & $add 'IDENTITIES' 'Warning' $(if ($null -eq $Manifest) { 'No manifest from before the destroy, so the identities weren''t checked.' } else { 'The manifest didn''t record the group''s identities (the group was already gone, or Resource Graph couldn''t read it), so they weren''t checked.' }) @() 'Microsoft Entra deletes a system-assigned identity with its resource. To check by hand, search Microsoft Entra ID, Enterprise applications, for the names of the VMs, the Arc machine, and the T3 server (application type Managed Identities).' 'https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview'
    }
    elseif ($principalIds.Count -eq 0 -and -not $final.Errors.Contains('Principals')) {
        & $add 'IDENTITIES' 'Pass' 'The environment had no managed identities to check.'
    }
    else {
        $left = @($final.Principals) + @($final.Members | ForEach-Object { 'member of the P6 group: {0}' -f $_ })
        $status = if ($final.Errors.Contains('Principals')) { 'Warning' } elseif (& $count $left) { 'Fail' } else { 'Pass' }
        & $add 'IDENTITIES' $status $(switch ($status) { 'Pass' { '{0} managed identit(ies) are gone from Microsoft Entra and from the P6 group.' -f $principalIds.Count } 'Fail' { '{0} of {1} identit(ies) or memberships are left.' -f (& $count $left), $principalIds.Count } default { 'Microsoft Entra couldn''t be read: {0}' -f $final.Errors['Principals'] } }) $left $(if ($status -eq 'Fail') { 'Microsoft Entra removes a managed identity with its resource, usually within minutes; run the check again later.' } else { '' }) 'https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview'
    }

    $status = & $verdict 'Deployments' $final.Deployments
    & $add 'DEPLOYMENTS' $status $(switch ($status) { 'Pass' { 'No subscription-scope deployment {0}* is left.' -f $setting.DeploymentPrefix } 'Fail' { 'Subscription-scope deployment(s) left: {0}.' -f (@($final.Deployments) -join ', ') } default { 'The deployments couldn''t be read: {0}' -f $final.Errors['Deployments'] } }) $final.Deployments $(if ($status -eq 'Fail') { 'az deployment sub delete --name <name> (destroy.ps1 does this).' } else { '' }) 'https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-delete'

    $status = if ($final.Errors.Contains('Budget')) { 'Warning' } elseif ($final.BudgetExists) { 'Fail' } else { 'Pass' }
    & $add 'BUDGET' $status $(switch ($status) { 'Pass' { 'The budget at the group''s scope is gone.' } 'Fail' { 'The budget at the group''s scope still exists.' } default { 'The budget couldn''t be read: {0}' -f $final.Errors['Budget'] } }) @() $(if ($status -eq 'Fail') { 'Run destroy.ps1 again (the budget goes with the resource group), or delete it in Cost Management under Budgets.' } else { '' }) 'https://learn.microsoft.com/rest/api/consumption/budgets/get'

    $status = if ($final.Errors.Contains('References')) { 'Warning' } elseif (& $count $final.References) { 'Warning' } else { 'Pass' }
    & $add 'REFERENCES' $status $(if ($final.Errors.Contains('References')) { 'Resources outside the group couldn''t be read: {0}' -f $final.Errors['References'] } elseif (& $count $final.References) { '{0} resource(s) outside the group still name it; Azure Policy or another workload may have created them, so they''re reported, not deleted.' -f (& $count $final.References) } else { 'No resource outside the group names it.' }) $final.References $(if ($status -eq 'Warning' -and (& $count $final.References)) { 'Check that nothing else uses them, then delete them yourself.' } else { '' }) $graphDoc

    # Platform records about deleted resources are evidence, not residue: nothing to delete, nothing billed.
    $records = @($final.Records | Where-Object { $_ })
    if ($final.Errors.Contains('Records')) {
        & $add 'RECORDS' 'Warning' ('Defender for Cloud, Azure Policy, and guest configuration records couldn''t be read: {0}' -f $final.Errors['Records']) @() 'Run the check again later.' $graphDoc
    }
    elseif ($records.Count) {
        & $add 'RECORDS' 'Pass' ('Only records remain: Defender for Cloud, Azure Policy, or guest configuration still list the deleted resources ({0}). They aren''t resources, don''t bill, and age out on their own.' -f ($records -join ', ')) $records '' $graphDoc
    }
    else {
        & $add 'RECORDS' 'Pass' 'Neither Defender for Cloud, Azure Policy, nor guest configuration lists anything for the deleted resources.' @() '' $graphDoc
    }

    if (-not (Get-DemoKeyVaultSetting -Config $Config).Enabled) {
        & $add 'KEYVAULT' 'Not selected' 'The Key Vault opt-in is off, so there''s no vault.'
    }
    elseif (-not $vaultName) {
        & $add 'KEYVAULT' 'Warning' 'The Key Vault opt-in is on, but the vault''s name is unknown (no deploymentId in the manifest).' @() 'az keyvault list-deleted shows soft-deleted vaults.'
    }
    else {
        $deleted = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('keyvault', 'list-deleted', '--resource-type', 'vault', '--query', '[].name') -AsJson -AllowFailure
        $soft = @(@($deleted) | Where-Object { [string]$_ -eq $vaultName })
        & $add 'KEYVAULT' $(if ($soft.Count) { 'Warning' } else { 'Pass' }) $(if ($soft.Count) { 'The vault {0} is soft-deleted by design (ADR 0009): no charge, recoverable by the next deploy.ps1, and purged after its retention.' -f $vaultName } else { 'The vault {0} is neither active nor soft-deleted.' -f $vaultName }) $soft $(if ($soft.Count) { 'To remove it now (without purge protection): az keyvault purge --name <vault>.' } else { '' }) 'https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview'
    }
    return $results.ToArray()
}
