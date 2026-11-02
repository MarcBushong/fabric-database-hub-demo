function Test-DemoTeardownResidue {
    <#
    .SYNOPSIS
    Checks that a destroyed environment left nothing behind, Arc resources included (ADR 0002, Phase 16).
    destroy.ps1 runs it after the resource group is gone, destroy.ps1 -ResidueOnly runs it again on its own, and so do
    the opt-in teardown tests.

    .DESCRIPTION
    Read-only. Azure Resource Graph and Microsoft Entra are eventually consistent, so it polls for up to
    -WaitMinutes until the required checks are clean. Only this environment is matched: its resource group by the
    exact name rg-<prefix>-<environment>, and its resources by the manifest's deploymentId tag, never by the solution
    and environment tags alone (another prefix's environment of the same name carries them too) or by a resource's
    name (Phase 28 follow-up, live 2026-11-02). Each check is one result (area teardown):
    - TEARDOWN.RESIDUAL.RESOURCEGROUP: the resource group is gone.
    - TEARDOWN.RESIDUAL.TAGGED: no resource or resource group carries the environment's deploymentId, and the
      group isn't listed; rg-<prefix>-control stays. Without a deploymentId (no manifest), only the group is looked
      for, and the check is a Warning.
    - TEARDOWN.RESIDUAL.GROUPRESOURCES: Resource Graph lists nothing in the group.
    - TEARDOWN.RESIDUAL.ARC: no Arc machine, machine extension, or SQL Server instance (or its databases) in
      the group, carrying the environment's deploymentId, or hosted by a machine or VM of the group.
    - TEARDOWN.RESIDUAL.ROLEASSIGNMENTS: no role assignment at or under the group, and none for the identities in
      the manifest in the demo's other resource groups (a Fail). One for a deleted identity anywhere else is a
      Warning that names its scope: the demo gives its managed identities role assignments only at or under its
      group (the Arc onboarding identity's, with assignRoles), so something else made it, such as a tenant policy
      with a DeployIfNotExists effect. It's left as "Identity not found" for an Owner or User Access Administrator to
      remove, and never deleted here.
    - TEARDOWN.RESIDUAL.IDENTITIES: the manifest's identities are gone from Microsoft Entra, and none of them
      is still a member of the P6 group.
    - TEARDOWN.RESIDUAL.DEPLOYMENTS: no subscription-scope deployment <prefix>-<environment>-*.
    - TEARDOWN.RESIDUAL.BUDGET: the budget at the group's scope is gone.
    - TEARDOWN.RESIDUAL.REFERENCES: no resource outside the group still names it (a Warning: such a
      resource, for example one Azure Policy created, may be shared).
    - TEARDOWN.RESIDUAL.RECORDS: what Defender for Cloud (assessments), Azure Policy (compliance states), guest
      configuration, and Resource Graph's own index still list for the deleted resources. They aren't resources,
      don't bill, and age out on their own, so they're evidence, not residue: Pass either way, Warning only when
      unreadable.
    - TEARDOWN.RESIDUAL.KEYVAULT: with the Key Vault opt-in, a soft-deleted vault is a Warning (ADR 0009);
      Not selected otherwise.
    Resource Graph's index lags behind deletes (live, 2026-11-02: an Arc SQL Server instance's databases stayed listed
    in their deleted group for more than 30 minutes), so the resources it still lists are confirmed with Azure
    Resource Manager, at most -MaxResourceReads GETs for the whole check (Confirm-DemoResidueResource). One that
    Resource Manager says is gone (HTTP 404 with ResourceNotFound, ResourceGroupNotFound, or ParentResourceNotFound)
    is a stale index record, reported under RECORDS; one it returns is residue (a Fail); one it couldn't confirm is
    a Warning.
    A check that can't be read is a Warning, never a Pass (ADR 0012). Azure Resource Graph, Azure Resource Manager's
    confirmations, and Microsoft Graph are read through Invoke-DemoRestRequest with tokens verified for the
    configured tenant and caller (ADR 0011, guard update), and each graph only after a canary: Resource Graph must
    list the configured subscription, and Microsoft Graph must answer for the configured tenant. When a canary fails,
    its checks are Warnings, and the check doesn't wait for them. A manifest that didn't record the identities (taken
    after the group was gone) makes IDENTITIES a Warning, not a Pass.

    Sources (checked 2026-10-21, and 2026-11-02 for Resource Manager's reads and role assignments):
    - Resource Graph tables (resources, resourcecontainers, authorizationresources, securityresources,
      policyresources, guestconfigurationresources):
      https://learn.microsoft.com/azure/governance/resource-graph/reference/supported-tables-resources
    - Resources - Get By Id: https://learn.microsoft.com/rest/api/resources/resources/get-by-id; Providers - Get:
      https://learn.microsoft.com/rest/api/resources/providers/get; not-found errors:
      https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-not-found
    - Removing role assignments: https://learn.microsoft.com/azure/role-based-access-control/role-assignments-remove;
      "Identity not found": https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#symptom---role-assignments-with-identity-not-found
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
    identities are unknown: only the resource group is looked for by name, and the tag and identity checks report
    a Warning.

    .PARAMETER WaitMinutes
    How long to poll while something still shows up (0: check once).

    .PARAMETER PollSeconds
    Seconds between polls.

    .PARAMETER MaxResourceReads
    At most this many Azure Resource Manager GETs confirm what Resource Graph still lists (0: none, so every such
    row is a Warning).

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
        [int] $PollSeconds = 30,

        [ValidateRange(0, 100)]
        [int] $MaxResourceReads = 25
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

    # What Resource Graph still lists is confirmed with Azure Resource Manager, within one budget of reads.
    $confirmation = New-DemoResidueConfirmation -MaxReads $MaxResourceReads
    $rowsOf = {
        param([object] $Snapshot)
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($id in @(@($Snapshot.Tagged) + @($Snapshot.GroupResources) + @($Snapshot.Arc))) {
            if ($id) {
                $null = $set.Add([string]$id)
            }
        }
        , [string[]]@($set)
    }
    $isGone = { param([string] $Id) $confirmation.Outcome.ContainsKey($Id) -and $confirmation.Outcome[$Id] -eq 'Gone' }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    # Bounded by passes as well as time, so a run whose waits return at once (a test) can't spin.
    $maxPasses = 1 + [int][math]::Ceiling($WaitMinutes * 60 / $PollSeconds)
    $passes = 0
    while ($true) {
        $passes++
        $snapshot = Get-DemoResidueSnapshot -Setting $setting
        $rows = & $rowsOf $snapshot
        if ($rows.Count -gt 0 -and -not $snapshot.GroupExists) {
            # Each row is read at most once while polling; rows Resource Manager says are gone stop the wait.
            Confirm-DemoResidueResource -SubscriptionId $subscriptionId -Id $rows -State $confirmation -NewOnly
        }
        $listed = @($rows | Where-Object { -not (& $isGone $_) })
        $required = @($listed) + @($snapshot.RoleAssignments) + @($snapshot.Principals) + @($snapshot.Members) + @($snapshot.Deployments)
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
    $finalRows = & $rowsOf $final
    if ($finalRows.Count -gt 0) {
        # Rows the poll read are read again while reads are left, so one deleted meanwhile isn't reported as left. While
        # the group still exists, the destroy isn't done: what Resource Graph lists counts as it is.
        Confirm-DemoResidueResource -SubscriptionId $subscriptionId -Id $finalRows -State $confirmation -AssumePresent:([bool]$final.GroupExists)
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $waited = [math]::Round($watch.Elapsed.TotalMinutes, 1)
    $add = {
        param([string] $Name, [string] $Status, [string] $Message, [object[]] $Items = @(), [string] $Remediation = '', [string] $DocUrl = '', [string] $Target = 'subscription', [System.Collections.IDictionary] $More = $null)
        $evidence = [ordered]@{ remaining = @($Items | Where-Object { $_ } | Select-Object -First 50); waitedMinutes = $waited; passes = $passes }
        if ($null -ne $More) {
            foreach ($key in $More.Keys) {
                $evidence[$key] = $More[$key]
            }
        }
        $results.Add((New-DemoResult -CheckId ('TEARDOWN.RESIDUAL.{0}' -f $Name) -Area 'teardown' -Target $Target -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $DocUrl))
    }
    $verdict = {
        param([string] $Key, [object[]] $Items)
        if ($final.Errors.Contains($Key)) { 'Warning' } elseif (@($Items | Where-Object { $_ }).Count -gt 0) { 'Fail' } else { 'Pass' }
    }
    $count = { param([object[]] $Items) @($Items | Where-Object { $_ }).Count }
    $graphDoc = 'https://learn.microsoft.com/azure/governance/resource-graph/reference/supported-tables-resources'
    $readDoc = 'https://learn.microsoft.com/rest/api/resources/resources/get-by-id'
    $rerun = 'Run destroy.ps1 again: it deletes whatever is left in the group and checks again.'
    $deleteByName = 'delete them in the portal, or with az resource delete --resource-group <group> --name <name> --resource-type <type>'
    $recheck = 'Run the check again later, read-only: ./scripts/destroy.ps1 -ResidueOnly, which reads the saved manifest and deletes nothing. Resource Graph drops a deleted resource from its index on its own.'
    # Resource Graph's rows, sorted by what Resource Manager said about each.
    $sort = {
        param([object[]] $Items)
        $split = Split-DemoResidueResource -Id @($Items | Where-Object { $_ } | ForEach-Object { [string]$_ }) -State $confirmation
        $codes = @($split.Gone | ForEach-Object { $confirmation.Detail[$_] } | Select-Object -Unique)
        $more = [ordered]@{
            indexRecords         = @($split.Gone | Select-Object -First 50)
            unconfirmed          = @($split.Unconfirmed | Select-Object -First 50)
            resourceManagerReads = $confirmation.Reads
            maxResourceReads     = $confirmation.MaxReads
        }
        [pscustomobject]@{ Present = $split.Present; Gone = $split.Gone; Unconfirmed = $split.Unconfirmed; Reasons = ($split.Reasons -join '; '); Codes = ($codes -join ', '); Types = ((Get-DemoResidueTypeCount -Id $split.Gone) -join ', '); More = $more }
    }

    $status = if ($final.Errors.Contains('Group')) { 'Warning' } elseif ($final.GroupExists) { 'Fail' } else { 'Pass' }
    & $add 'RESOURCEGROUP' $status $(switch ($status) { 'Pass' { '{0} is gone.' -f $resourceGroupName } 'Fail' { '{0} still exists.' -f $resourceGroupName } default { 'Whether {0} exists couldn''t be read: {1}' -f $resourceGroupName, $final.Errors['Group'] } }) @() $(if ($status -eq 'Fail') { $rerun } else { '' }) 'https://learn.microsoft.com/cli/azure/group#az-group-exists'

    # Only this environment: its deploymentId, or its resource group by name; never the solution and environment tags alone.
    $tagText = if ($deploymentId) { 'deploymentId {0}, or the resource group {1}' -f $deploymentId, $resourceGroupName } else { 'the resource group {0}; the deploymentId is unknown without the manifest' -f $resourceGroupName }
    if ($final.Errors.Contains('Tagged')) {
        & $add 'TAGGED' 'Warning' ('Resource Graph couldn''t be read: {0}' -f $final.Errors['Tagged']) @() '' $graphDoc
    }
    else {
        $rows = & $sort $final.Tagged
        if ($rows.Present.Count) {
            & $add 'TAGGED' 'Fail' ('{0} resource(s) or resource group(s) still carry the environment''s tags ({1}); Azure Resource Manager returned them.' -f $rows.Present.Count, $tagText) (@($rows.Present) + @($rows.Unconfirmed)) ('Check that they belong to this environment, then {0}; run the check again.' -f $deleteByName) $graphDoc 'subscription' $rows.More
        }
        elseif ($rows.Unconfirmed.Count) {
            & $add 'TAGGED' 'Warning' ('Resource Graph still lists {0} resource(s) or resource group(s) with the environment''s tags ({1}) that Azure Resource Manager didn''t confirm: {2}.' -f $rows.Unconfirmed.Count, $tagText, $rows.Reasons) $rows.Unconfirmed $recheck $readDoc 'subscription' $rows.More
        }
        elseif (-not $deploymentId) {
            & $add 'TAGGED' 'Warning' ('Nothing outside {0} was looked for by tag: the deploymentId is unknown (no manifest, or one that didn''t record it), and the solution and environment tags alone would match other environments with the same environment name. {0} itself isn''t listed.' -f $resourceGroupName) @() 'Run the check with the manifest that destroy.ps1 wrote before it deleted anything (out/destroy-manifest-<environment>.json): ./scripts/destroy.ps1 -ResidueOnly -ManifestPath <file>.' $graphDoc 'subscription' $rows.More
        }
        elseif ($rows.Gone.Count) {
            & $add 'TAGGED' 'Pass' ('Nothing in the subscription carries the environment''s tags ({0}). Resource Graph still lists {1} deleted one(s) ({2}), which Azure Resource Manager says are gone ({3}): index records (TEARDOWN.RESIDUAL.RECORDS).' -f $tagText, $rows.Gone.Count, $rows.Types, $rows.Codes) @() '' $graphDoc 'subscription' $rows.More
        }
        else {
            & $add 'TAGGED' 'Pass' ('Nothing in the subscription carries the environment''s tags ({0}).' -f $tagText) @() '' $graphDoc 'subscription' $rows.More
        }
    }

    if ($final.Errors.Contains('GroupResources')) {
        & $add 'GROUPRESOURCES' 'Warning' ('Resource Graph couldn''t be read: {0}' -f $final.Errors['GroupResources']) @() '' $graphDoc
    }
    else {
        $rows = & $sort $final.GroupResources
        if ($rows.Present.Count) {
            & $add 'GROUPRESOURCES' 'Fail' ('{0} resource(s) are still in {1}: Azure Resource Manager returned them.' -f $rows.Present.Count, $resourceGroupName) (@($rows.Present) + @($rows.Unconfirmed)) $rerun $graphDoc 'subscription' $rows.More
        }
        elseif ($rows.Unconfirmed.Count) {
            & $add 'GROUPRESOURCES' 'Warning' ('Resource Graph still lists {0} resource(s) in {1} that Azure Resource Manager didn''t confirm: {2}.' -f $rows.Unconfirmed.Count, $resourceGroupName, $rows.Reasons) $rows.Unconfirmed $recheck $readDoc 'subscription' $rows.More
        }
        elseif ($rows.Gone.Count) {
            & $add 'GROUPRESOURCES' 'Pass' ('Only index records remain: Resource Graph still lists {0} resource(s) in {1} ({2}), but Azure Resource Manager says they''re gone ({3}). They aren''t resources, don''t bill, and age out on their own (TEARDOWN.RESIDUAL.RECORDS).' -f $rows.Gone.Count, $resourceGroupName, $rows.Types, $rows.Codes) @() '' $readDoc 'subscription' $rows.More
        }
        else {
            & $add 'GROUPRESOURCES' 'Pass' ('Resource Graph lists nothing in {0}.' -f $resourceGroupName) @() '' $graphDoc 'subscription' $rows.More
        }
    }

    $arcDoc = 'https://learn.microsoft.com/sql/sql-server/azure-arc/delete-from-azure-arc'
    if ($final.Errors.Contains('Arc')) {
        & $add 'ARC' 'Warning' ('The Arc resources couldn''t be read: {0}' -f $final.Errors['Arc']) @() '' $arcDoc 'T2'
    }
    else {
        $rows = & $sort $final.Arc
        if ($rows.Present.Count) {
            & $add 'ARC' 'Fail' ('{0} Arc resource(s) are left: Azure Resource Manager returned them.' -f $rows.Present.Count) (@($rows.Present) + @($rows.Unconfirmed)) ('Run destroy.ps1 again, or {0}: the SQL Server instances first, then the machines.' -f $deleteByName) $arcDoc 'T2' $rows.More
        }
        elseif ($rows.Unconfirmed.Count) {
            & $add 'ARC' 'Warning' ('Resource Graph still lists {0} Arc resource(s) that Azure Resource Manager didn''t confirm: {1}.' -f $rows.Unconfirmed.Count, $rows.Reasons) $rows.Unconfirmed $recheck $readDoc 'T2' $rows.More
        }
        elseif ($rows.Gone.Count) {
            & $add 'ARC' 'Pass' ('No Arc machine, machine extension, or SQL Server instance of this environment is left. Only index records remain: Resource Graph still lists {0} deleted Arc resource(s) ({1}), which Azure Resource Manager says are gone ({2}).' -f $rows.Gone.Count, $rows.Types, $rows.Codes) @() '' $readDoc 'T2' $rows.More
        }
        else {
            & $add 'ARC' 'Pass' 'No Arc machine, machine extension, or SQL Server instance of this environment is left.' @() '' $arcDoc 'T2' $rows.More
        }
    }

    # The demo's own role assignments are at or under its group (assignRoles only); one for a deleted identity anywhere
    # else was made by something else, such as a tenant policy, and is left for someone who may remove it.
    $removeDoc = 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-remove'
    $orphanDoc = 'https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#symptom---role-assignments-with-identity-not-found'
    $orphaned = @($final.OrphanedAssignments | Where-Object { $null -ne $_ })
    $orphanScopes = @($orphaned | ForEach-Object { [string]$_.Scope } | Select-Object -Unique)
    $orphanText = '{0} role assignment(s) for the environment''s deleted identities are left outside the demo''s resource groups, at {1}{2}. The demo didn''t create them: it gives its managed identities role assignments only at or under {3}, and only with assignRoles. Something else did, such as a tenant policy with a DeployIfNotExists effect. They''re orphaned (the portal lists them as Identity not found), and destroy.ps1 never deletes them.' -f $orphaned.Count, (@($orphanScopes | Select-Object -First 5) -join '; '), $(if ($orphanScopes.Count -gt 5) { ' and {0} more scope(s)' -f ($orphanScopes.Count - 5) } else { '' }), $resourceGroupName
    $orphanFix = 'An Owner or User Access Administrator (or Role Based Access Control Administrator) of each scope can remove an orphaned assignment: in the Azure portal, open the scope, then Access control (IAM) > Role assignments, where it shows as Identity not found, and remove it ({0}). Contributor can''t. Its identity is gone, so the assignment applies to no one.' -f $removeDoc
    $orphanEvidence = [ordered]@{ orphaned = @($orphaned | Select-Object -First 50 | ForEach-Object { [ordered]@{ id = $_.Id; scope = $_.Scope; principalId = $_.PrincipalId; roleDefinitionId = $_.RoleDefinitionId } }) }
    $status = & $verdict 'RoleAssignments' $final.RoleAssignments
    if ($status -eq 'Warning') {
        & $add 'ROLEASSIGNMENTS' 'Warning' ('The role assignments couldn''t be read: {0}' -f $final.Errors['RoleAssignments']) @() '' $removeDoc
    }
    elseif ($status -eq 'Fail') {
        & $add 'ROLEASSIGNMENTS' 'Fail' ('{0} role assignment(s) are left at or under the group, or for its identities in the demo''s resource groups.{1}' -f (& $count $final.RoleAssignments), $(if ($orphaned.Count) { ' ' + $orphanText } else { '' })) $final.RoleAssignments 'Someone who can delete role assignments (Owner, User Access Administrator, or Role Based Access Control Administrator; Contributor can''t) removes them in the portal under Access control (IAM), Role assignments, where an orphaned one shows as Identity not found.' $removeDoc 'subscription' $orphanEvidence
    }
    elseif ($orphaned.Count) {
        & $add 'ROLEASSIGNMENTS' 'Warning' $orphanText @() $orphanFix $orphanDoc 'subscription' $orphanEvidence
    }
    else {
        & $add 'ROLEASSIGNMENTS' 'Pass' 'No role assignment is left at or under the group, or for the environment''s identities.' @() '' $removeDoc
    }

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

    # Platform records about deleted resources are evidence, not residue: nothing to delete, nothing billed. Resource
    # Graph's own index of deleted resources, as Resource Manager confirmed them, is one of them.
    $indexed = @((Split-DemoResidueResource -Id $finalRows -State $confirmation).Gone)
    $records = @(@($final.Records | Where-Object { $_ }) + @(Get-DemoResidueTypeCount -Id $indexed | ForEach-Object { 'Azure Resource Graph index of deleted resources, {0}' -f $_ }))
    if ($final.Errors.Contains('Records')) {
        & $add 'RECORDS' 'Warning' ('Defender for Cloud, Azure Policy, and guest configuration records couldn''t be read: {0}' -f $final.Errors['Records']) @() 'Run the check again later.' $graphDoc 'subscription' ([ordered]@{ indexRecords = @($indexed | Select-Object -First 50) })
    }
    elseif ($records.Count) {
        & $add 'RECORDS' 'Pass' ('Only records remain: Defender for Cloud, Azure Policy, guest configuration, or Azure Resource Graph''s index still list the deleted resources ({0}). They aren''t resources, don''t bill, and age out on their own.' -f ($records -join ', ')) $records '' $graphDoc 'subscription' ([ordered]@{ indexRecords = @($indexed | Select-Object -First 50) })
    }
    else {
        & $add 'RECORDS' 'Pass' 'Neither Defender for Cloud, Azure Policy, guest configuration, nor Azure Resource Graph''s index lists anything for the deleted resources.' @() '' $graphDoc
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
