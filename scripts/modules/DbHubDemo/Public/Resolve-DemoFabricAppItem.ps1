function Resolve-DemoFabricAppItem {
    <#
    .SYNOPSIS
    Finds, by name, the Fabric items the app reads or links to: the semantic model (required), the Real-Time Dashboard,
    and the Power BI report, and builds the app's new-tab links from their IDs (FABRIC.APP.ITEMS).

    .DESCRIPTION
    Uses Items - List Items through the Phase 12 Fabric REST helpers (Find-DemoFabricItem), with the caller's Fabric
    token sent only as a SecureString (https://learn.microsoft.com/rest/api/fabric/core/items/list-items). The
    evidence carries the semantic model's ID (for the connector) and the links the app shows:
    - databaseHub: the Database Hub page of the Fabric portal (the repository's documented entry point).
    - workspace: the workspace's item list.
    - realTimeDashboard: the dashboard's page; the Fabric portal path for a Real-Time Dashboard isn't documented on
      Learn, TODO(verify), and the workspace link is the fallback.
    - report: the report's page (the same path the Power BI REST API returns as webUrl).
    Every link carries ?ctid=<tenant>, so it opens in the demo's tenant. The evidence goes only to the Git-ignored
    out/ folder and the stage's public/dbhub-app.json, never to Git.
    No single model with the name is Manual action required (run configure-powerbi.ps1); a missing dashboard or
    report is a Warning, because the app explains how to add them.

    .PARAMETER WorkspaceId
    The Fabric workspace (fabric.workspaceId).

    .PARAMETER TenantId
    The demo's tenant, for the links' ctid.

    .PARAMETER Token
    A Fabric REST API token, as a SecureString.

    .EXAMPLE
    Resolve-DemoFabricAppItem -WorkspaceId $ws -TenantId $tenant -Token $token
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    $settings = Get-DemoFabricAppSetting
    $docUrl = 'https://learn.microsoft.com/rest/api/fabric/core/items/list-items'
    $portal = ([string]$settings['portalUrl']).TrimEnd('/')
    $problems = [System.Collections.Generic.List[string]]::new()
    $fabricToken = $Token
    $find = {
        param([string] $Name, [string] $Type)
        $found = Find-DemoFabricItem -WorkspaceId $WorkspaceId -DisplayName $Name -Type $Type -Token $fabricToken
        if ($found.StatusCode -ne 200) {
            $problems.Add(('{0}: {1}' -f $Name, $found.Error))
            return ''
        }
        if (@($found.Items).Count -eq 1) {
            return [string](Get-DemoMemberValue -InputObject @($found.Items)[0] -Name 'id')
        }
        if (@($found.Items).Count -gt 1) {
            $problems.Add(('{0}: {1} items have that name' -f $Name, @($found.Items).Count))
        }
        return ''
    }
    $modelId = & $find ([string]$settings['semanticModelName']) 'SemanticModel'
    $dashboardId = & $find ([string]$settings['dashboardName']) 'KQLDashboard'
    $reportId = & $find ([string]$settings['reportName']) 'Report'

    $ctid = '?ctid={0}' -f $TenantId.ToLowerInvariant()
    $workspace = $WorkspaceId.ToLowerInvariant()
    $links = [ordered]@{
        databaseHub = '{0}/workloads/fdh/databaseHub{1}' -f $portal, $ctid
        workspace   = '{0}/groups/{1}/list{2}' -f $portal, $workspace, $ctid
    }
    if ($dashboardId) {
        $links['realTimeDashboard'] = '{0}/groups/{1}/kustodashboards/{2}{3}' -f $portal, $workspace, $dashboardId.ToLowerInvariant(), $ctid
    }
    if ($reportId) {
        $links['report'] = '{0}/groups/{1}/reports/{2}{3}' -f $portal, $workspace, $reportId.ToLowerInvariant(), $ctid
    }
    $evidence = [ordered]@{ semanticModelId = $modelId; dashboardId = $dashboardId; reportId = $reportId; links = $links }
    if ($problems.Count -gt 0) {
        $evidence['problems'] = @($problems)
    }

    if (-not $modelId) {
        return New-DemoResult -CheckId 'FABRIC.APP.ITEMS' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message ('The semantic model {0} isn''t in the workspace (or more than one item has that name), and the app reads only it.' -f $settings['semanticModelName']) -Evidence $evidence -Remediation 'Run ./scripts/configure-powerbi.ps1 to deploy the history model, then run this script again.' -DocUrl $docUrl
    }
    $missing = @(@(if (-not $dashboardId) { $settings['dashboardName'] }; if (-not $reportId) { $settings['reportName'] }) | Where-Object { $_ })
    if ($missing.Count -gt 0) {
        return New-DemoResult -CheckId 'FABRIC.APP.ITEMS' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('Found {0}; not found: {1}, so the app''s Live links page explains how to add them.' -f $settings['semanticModelName'], ($missing -join ', ')) -Evidence $evidence -Remediation 'Run ./scripts/configure-fabric.ps1 -ImportDashboard and ./scripts/configure-powerbi.ps1, then run this script again.' -DocUrl $docUrl
    }
    return New-DemoResult -CheckId 'FABRIC.APP.ITEMS' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('Found {0}, {1}, and {2}; the app links to them in a new tab.' -f $settings['semanticModelName'], $settings['dashboardName'], $settings['reportName']) -Evidence $evidence -DocUrl $docUrl
}
