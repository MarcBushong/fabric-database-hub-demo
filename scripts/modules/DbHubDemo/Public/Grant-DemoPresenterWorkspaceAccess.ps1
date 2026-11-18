function Grant-DemoPresenterWorkspaceAccess {
    <#
    .SYNOPSIS
    Shares the demo workspace, and with it the Real-Time Dashboard RTD_DatabaseHub_LiveView, the history report, and
    the Insights app, with the presenters in presenterObjectIds as Viewers (FABRIC.PRESENTER.VIEWER, 2026-11-18).

    .DESCRIPTION
    The coordinator's Ignite review, item 5: the demo's dashboard is shared with the presenters automatically. Fabric's
    REST API has no operation to share one item, so the workspace's Viewer role, through the documented Workspaces - List
    Workspace Role Assignments and Add Workspace Role Assignment, is how it's shared. A presenter who already has any role
    on the workspace keeps it; the others get Viewer, the least role that opens the workspace's items. Every run of
    configure-fabric.ps1 -ImportDashboard (deploy.ps1's Fabric track) does it again, so a presenter added to the
    configuration later is shared with on the next deploy, and the same run changes nothing for the others.

    Results (ADR 0012), never a Fail, because the demo doesn't need it: Not selected without presenters or with -WhatIf;
    Pass when every presenter has a role; a Warning, with the steps in the Fabric portal, when the role assignments
    couldn't be listed or one couldn't be added (the caller must be an Admin or a Member of the workspace). The dashboard
    queries the telemetry as each viewer, so a presenter also needs Reader on the subscription, which
    Set-DemoPresenterAccess grants or prints (HUB.PRESENTER.READER).
    - Add Workspace Role Assignment: https://learn.microsoft.com/rest/api/fabric/core/workspaces/add-workspace-role-assignment
    - List Workspace Role Assignments: https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspace-role-assignments
    - Roles in workspaces: https://learn.microsoft.com/fabric/fundamentals/roles-workspaces

    .PARAMETER Config
    Configuration from Get-DemoConfig (presenterObjectIds).

    .PARAMETER WorkspaceId
    The demo workspace.

    .PARAMETER Token
    A Fabric token (Get-DemoFabricToken).

    .EXAMPLE
    Grant-DemoPresenterWorkspaceAccess -Config $config -WorkspaceId $workspaceId -Token (Get-DemoFabricToken -SubscriptionId $config.subscriptionId)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    $doc = 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/add-workspace-role-assignment'
    $steps = 'In Fabric, open the demo workspace, select Manage access, then Add people or groups, and add each presenter as Viewer; or run ./scripts/deploy.ps1 again, which adds them.'
    $guid = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    $presenters = @(@($Config['presenterObjectIds']) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    $result = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '')
        New-DemoResult -CheckId 'FABRIC.PRESENTER.VIEWER' -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $doc
    }
    if ($presenters.Count -eq 0) {
        return (& $result 'Not selected' 'No presenters are listed in presenterObjectIds, so the demo workspace isn''t shared with anyone else; its own members open the Real-Time Dashboard already.')
    }
    foreach ($presenter in $presenters) {
        if ($presenter -notmatch $guid) {
            throw "presenterObjectIds contains '$presenter', which isn't an object ID."
        }
    }

    $assigned = @{}
    $url = '{0}/workspaces/{1}/roleAssignments' -f $script:FabricApiBaseUri, $WorkspaceId.ToLowerInvariant()
    for ($page = 0; $page -lt 20 -and $url; $page++) {
        $response = Invoke-DemoFabricRequest -Method Get -Uri $url -Token $Token
        if ($response.StatusCode -ne 200) {
            return (& $result 'Warning' ('The demo workspace''s role assignments couldn''t be listed ({0}), so it wasn''t shared with the {1} presenter(s) in presenterObjectIds.' -f (Get-DemoFabricErrorText -Response $response), $presenters.Count) ([ordered]@{ presenters = $presenters.Count }) $steps)
        }
        foreach ($item in (Get-DemoMemberList -InputObject $response.Body -Name 'value')) {
            $principal = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'principal') -Name 'id')
            if ($principal) {
                $assigned[$principal.ToLowerInvariant()] = [string](Get-DemoMemberValue -InputObject $item -Name 'role')
            }
        }
        $next = [string](Get-DemoMemberValue -InputObject $response.Body -Name 'continuationUri')
        $url = if ($next.StartsWith($script:FabricApiBaseUri + '/', [System.StringComparison]::Ordinal)) { $next } else { '' }
    }

    $added = [System.Collections.Generic.List[string]]::new()
    $kept = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    $skipped = 0
    foreach ($presenter in $presenters) {
        if ($assigned.ContainsKey($presenter)) {
            $kept.Add(('{0} ({1})' -f $presenter, $assigned[$presenter]))
            continue
        }
        if (-not $PSCmdlet.ShouldProcess(('presenter {0} in Fabric workspace {1}' -f $presenter, $WorkspaceId), 'Add as Viewer')) {
            $skipped++
            continue
        }
        $body = [ordered]@{ principal = [ordered]@{ id = $presenter; type = 'User' }; role = 'Viewer' }
        $response = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces/{1}/roleAssignments' -f $script:FabricApiBaseUri, $WorkspaceId.ToLowerInvariant()) -Body $body -Token $Token -NotIdempotent
        if ($response.StatusCode -in 200, 201) {
            $added.Add($presenter)
        }
        elseif ($response.StatusCode -eq 409) {
            # A role assigned since the list (another run): the presenter has access.
            $kept.Add(('{0} (already assigned)' -f $presenter))
        }
        else {
            $failed.Add(('{0}: {1}' -f $presenter, (Get-DemoFabricErrorText -Response $response)))
        }
    }

    $evidence = [ordered]@{ presenters = $presenters.Count; added = $added.Count; alreadyAssigned = $kept.Count; failed = $failed.Count }
    if ($failed.Count -gt 0) {
        return (& $result 'Warning' ('{0} of the {1} presenter(s) in presenterObjectIds couldn''t be added to the demo workspace as Viewers, so they can''t open the Real-Time Dashboard yet: {2}.' -f $failed.Count, $presenters.Count, ($failed -join '; ')) $evidence $steps)
    }
    if ($skipped -gt 0) {
        return (& $result 'Not selected' ('What if: {0} presenter(s) would be added to the demo workspace as Viewers; {1} already have a role.' -f $skipped, $kept.Count) $evidence)
    }
    return (& $result 'Pass' ('The demo workspace is shared with the {0} presenter(s) in presenterObjectIds ({1} added as Viewers, {2} already had a role), so they can open RTD_DatabaseHub_LiveView, the history report, and the Insights app. The dashboard queries the telemetry as each viewer, so they also need Reader on the subscription (HUB.PRESENTER.READER).' -f $presenters.Count, $added.Count, $kept.Count) $evidence)
}
