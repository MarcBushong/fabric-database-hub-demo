function Test-DemoFabricWorkspace {
    <#
    .SYNOPSIS
    Checks prerequisite P5: the caller has Contributor or higher on the Fabric workspace that holds the
    notebooks, and the workspace is on a Fabric (F) or Trial capacity (FABRIC.P5.WORKSPACE,
    FABRIC.P5.CAPACITY).

    .DESCRIPTION
    Uses only documented Fabric REST calls, through the Phase 12 Fabric REST helpers (Get-DemoFabricToken and
    Invoke-DemoFabricRequest) with the caller's Fabric token, from -Token or the Azure CLI, sent only as a
    SecureString bearer token and never logged:
    - Workspaces - Get Workspace (GET /v1/workspaces/{workspaceId}; any workspace role can read it) for the
      name and the capacity: capacityId, capacityAssignmentProgress, capacityRegion
      (https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-workspace).
    - Workspaces - List Workspaces with roles=Admin,Member,Contributor: the workspace is listed only when
      the caller has one of those roles, directly or through a group
      (https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces).
    - Capacities - List Capacities for the SKU and state of the workspace's capacity; it lists only
      capacities the caller administers or contributes to
      (https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities).
    Notebooks need an F or Trial capacity (https://learn.microsoft.com/fabric/enterprise/licenses). An
    Active capacity whose SKU matches databaseHub.fabric.notebookCapacitySkuPattern in config/versions.json
    (F SKUs) is a Pass. Any other SKU is Manual action required, because Learn doesn't document the SKU
    string of a Trial capacity (TODO(verify)). A capacity the caller can't see is a Warning. No access, no
    capacity, a paused capacity, a failed assignment, no token, or the Phase 12 helpers missing from the build
    is Manual action required, with the steps. Without a workspace ID (Resolve-DemoFabricConfig finds it by name,
    ADR 0021), both checks are Not selected; FABRIC.RESOLVE.WORKSPACE says why.

    .PARAMETER Config
    Configuration from Get-DemoConfig, resolved by Resolve-DemoFabricConfig (fabric.workspaceId).

    .PARAMETER Token
    A Fabric REST API token the operator already has, as a SecureString. Without it, Get-DemoFabricToken
    gets one from the signed-in Azure CLI.

    .PARAMETER MaxPages
    The most pages to read from each list call.

    .EXAMPLE
    Test-DemoFabricWorkspace -Config $config
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [securestring] $Token,

        [ValidateRange(1, 50)]
        [int] $MaxPages = 10
    )

    $fabric = (Get-DemoHubSetting)['fabric']
    $base = [string]$fabric['apiBaseUrl']
    $subscriptionId = [string]$Config['subscriptionId']
    $workspaceId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')
    $workspaceDoc = 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-workspace'
    $capacityDoc = 'https://learn.microsoft.com/fabric/enterprise/licenses'
    $skuPattern = [string]$fabric['notebookCapacitySkuPattern']
    $accessSteps = 'A workspace administrator opens the workspace, selects Manage access, and adds you (or a group you belong to) as Contributor, Member, or Admin.'
    $capacitySteps = 'A workspace administrator opens Workspace settings, selects License info, and assigns a Fabric (F) capacity or a Fabric Trial capacity; a capacity administrator resumes the capacity if it is paused.'

    function ConvertTo-WorkspaceResult([string] $CheckId, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation, [string] $DocUrl) {
        New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl
    }

    if (-not $workspaceId) {
        return @(
            ConvertTo-WorkspaceResult 'FABRIC.P5.WORKSPACE' 'Not selected' 'No Fabric workspace was resolved (FABRIC.RESOLVE.WORKSPACE says why), so this check didn''t run.' @{} '' $workspaceDoc
            ConvertTo-WorkspaceResult 'FABRIC.P5.CAPACITY' 'Not selected' 'No Fabric workspace was resolved (FABRIC.RESOLVE.WORKSPACE says why), so its capacity wasn''t checked.' @{} '' $capacityDoc
        )
    }

    $access = Get-DemoHubFabricAccess -SubscriptionId $subscriptionId -Token $Token
    if (-not $access.Token) {
        $evidence = [ordered]@{ workspaceId = $workspaceId; checkedThroughApi = $false }
        return @(
            ConvertTo-WorkspaceResult 'FABRIC.P5.WORKSPACE' 'Manual action required' ('The Fabric workspace {0} could not be checked: {1}' -f $workspaceId, $access.Error) $evidence ('Confirm you have Contributor or higher. {0}' -f $accessSteps) $workspaceDoc
            ConvertTo-WorkspaceResult 'FABRIC.P5.CAPACITY' 'Manual action required' 'The workspace''s capacity could not be checked, because the workspace itself could not be read.' $evidence $capacitySteps $capacityDoc
        )
    }
    $fabricToken = $access.Token

    $call = Invoke-DemoHubFabricGet -Uri ('{0}/workspaces/{1}' -f $base, $workspaceId) -Token $fabricToken
    if ($call.StatusCode -lt 200 -or $call.StatusCode -ge 300) {
        $evidence = [ordered]@{ workspaceId = $workspaceId; statusCode = $call.StatusCode }
        $why = if ($call.StatusCode -in 401, 403, 404) { 'You can''t read it, or it doesn''t exist' } else { 'It could not be read' }
        return @(
            ConvertTo-WorkspaceResult 'FABRIC.P5.WORKSPACE' 'Manual action required' ('The Fabric workspace {0} could not be checked. {1}: {2}' -f $workspaceId, $why, $call.Error) $evidence $accessSteps $workspaceDoc
            ConvertTo-WorkspaceResult 'FABRIC.P5.CAPACITY' 'Manual action required' 'The workspace''s capacity could not be checked, because the workspace itself could not be read.' $evidence $capacitySteps $capacityDoc
        )
    }

    $workspace = $call.Body
    $displayName = [string](Get-DemoMemberValue -InputObject $workspace -Name 'displayName')
    $capacityId = [string](Get-DemoMemberValue -InputObject $workspace -Name 'capacityId')
    $progress = [string](Get-DemoMemberValue -InputObject $workspace -Name 'capacityAssignmentProgress')
    $capacityRegion = [string](Get-DemoMemberValue -InputObject $workspace -Name 'capacityRegion')
    $results = [System.Collections.Generic.List[object]]::new()

    # Role: the workspace appears in List Workspaces filtered to Admin, Member, and Contributor.
    $roles = Read-DemoHubFabricList -Uri ('{0}/workspaces?roles=Admin,Member,Contributor' -f $base) -Token $fabricToken -MaxPages $MaxPages
    $roleEvidence = [ordered]@{ workspaceId = $workspaceId; displayName = $displayName; workspacesRead = @($roles.Items).Count; complete = $roles.Complete }
    if (-not $roles.Succeeded) {
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.WORKSPACE' 'Manual action required' ('You can read the workspace "{0}", but your role couldn''t be confirmed: {1}' -f $displayName, $roles.Error) $roleEvidence ('Confirm you have Contributor or higher. {0}' -f $accessSteps) $workspaceDoc))
    }
    elseif (@($roles.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'id') -ieq $workspaceId }).Count -gt 0) {
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.WORKSPACE' 'Pass' ('You have Contributor or higher on the Fabric workspace "{0}".' -f $displayName) $roleEvidence '' $workspaceDoc))
    }
    elseif (-not $roles.Complete) {
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.WORKSPACE' 'Manual action required' ('You can read the workspace "{0}", but it wasn''t in the first {1} pages of workspaces where you are Contributor or higher.' -f $displayName, $roles.Pages) $roleEvidence ('Confirm you have Contributor or higher. {0}' -f $accessSteps) $workspaceDoc))
    }
    else {
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.WORKSPACE' 'Manual action required' ('You can read the workspace "{0}" but have only the Viewer role, and importing or running the notebooks needs Contributor or higher.' -f $displayName) $roleEvidence $accessSteps $workspaceDoc))
    }

    # Capacity.
    $capacityEvidence = [ordered]@{ workspaceId = $workspaceId; capacityId = $capacityId; capacityAssignmentProgress = $progress; capacityRegion = $capacityRegion }
    if (-not $capacityId) {
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.CAPACITY' 'Manual action required' ('The Fabric workspace "{0}" isn''t on a capacity, and notebooks need a Fabric (F) or Trial capacity.' -f $displayName) $capacityEvidence $capacitySteps $capacityDoc))
        return $results.ToArray()
    }
    if ($progress -ieq 'Failed') {
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.CAPACITY' 'Manual action required' ('Assigning the Fabric workspace "{0}" to its capacity failed.' -f $displayName) $capacityEvidence $capacitySteps $capacityDoc))
        return $results.ToArray()
    }
    if ($progress -ieq 'InProgress') {
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.CAPACITY' 'Warning' ('The Fabric workspace "{0}" is still being assigned to its capacity.' -f $displayName) $capacityEvidence 'Wait a few minutes and run configure-fabric.ps1 again.' $capacityDoc))
        return $results.ToArray()
    }

    $capacities = Read-DemoHubFabricList -Uri ('{0}/capacities' -f $base) -Token $fabricToken -MaxPages $MaxPages
    $capacity = if ($capacities.Succeeded) { $capacities.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'id') -ieq $capacityId } | Select-Object -First 1 } else { $null }
    if (-not $capacity) {
        $reason = if ($capacities.Succeeded) { 'List Capacities shows only capacities you administer or contribute to' } else { 'the capacities could not be listed: {0}' -f $capacities.Error }
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.CAPACITY' 'Warning' ('The Fabric workspace "{0}" is on capacity {1} ({2}), but its SKU couldn''t be read: {3}.' -f $displayName, $capacityId, $capacityRegion, $reason) $capacityEvidence 'Confirm with the capacity administrator that it is a Fabric (F) or Trial capacity and that it is running.' $capacityDoc))
        return $results.ToArray()
    }

    $sku = [string](Get-DemoMemberValue -InputObject $capacity -Name 'sku')
    $state = [string](Get-DemoMemberValue -InputObject $capacity -Name 'state')
    $capacityName = [string](Get-DemoMemberValue -InputObject $capacity -Name 'displayName')
    $capacityEvidence['sku'] = $sku
    $capacityEvidence['state'] = $state
    $capacityEvidence['capacityName'] = $capacityName
    if ($state -ine 'Active') {
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.CAPACITY' 'Manual action required' ('The capacity "{0}" ({1}) of the Fabric workspace "{2}" is {3}, so notebooks can''t run.' -f $capacityName, $sku, $displayName, $state) $capacityEvidence 'A capacity administrator resumes the capacity in the Azure portal or the Fabric admin portal.' $capacityDoc))
    }
    elseif ($skuPattern -and $sku -match $skuPattern) {
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.CAPACITY' 'Pass' ('The Fabric workspace "{0}" is on the Active Fabric capacity "{1}" ({2}, {3}).' -f $displayName, $capacityName, $sku, $capacityRegion) $capacityEvidence '' $capacityDoc))
    }
    else {
        $results.Add((ConvertTo-WorkspaceResult 'FABRIC.P5.CAPACITY' 'Manual action required' ('The Fabric workspace "{0}" is on the capacity "{1}" with SKU {2}, which this check can''t confirm runs notebooks (only F SKUs are recognized; the Trial SKU name isn''t documented).' -f $displayName, $capacityName, $sku) $capacityEvidence ('Confirm that "{0}" is a Fabric Trial or F capacity. If it is a Trial, record its SKU in config/versions.json (databaseHub.fabric.notebookCapacitySkuPattern).' -f $capacityName) $capacityDoc))
    }
    return $results.ToArray()
}
