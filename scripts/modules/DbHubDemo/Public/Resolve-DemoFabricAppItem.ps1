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
    - controlNotebook: NB_DatabaseHub_Control's page (2026-11-18), for the app's Manage page: in the demo workspace (the
      control's folder, with a public vault) or in the control workspace, found by its name (a private vault). The
      portal path for a notebook isn't documented on Learn, TODO(verify); without it, Manage copies requests and doesn't
      open the notebook.
    - t2MigrationAssessment: with -Config, T2's SQL Server instance enabled by Azure Arc in the Azure portal (2026-11-18),
      built from the instance resource's own ID (one read-only ARM list, Get-DemoT2Migration); the app's
      migration card links to it when Database Hub isn't read live, and names the path, Migration, Assessments.
    With -Config, the evidence's t2Migration is that instance's migration assessment as Azure has it now, from the same
    read (R924): its readiness per Azure SQL target and the recommended tier and size, which the app's migration card
    shows, with its time, when Database Hub's live view isn't available to the app.
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

    .PARAMETER Config
    The demo's configuration, for the control's Fabric workspace (control.fabricWorkspaceName, or its default), where a
    private vault's control notebook is; without it, only the demo workspace is searched for the notebook.

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
        [securestring] $Token,

        [System.Collections.IDictionary] $Config
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
    # The control notebook, for Manage (2026-11-18): the demo workspace's control folder (a public vault), else the
    # control workspace (a private vault). Not finding it changes nothing but the link.
    $controlWorkspaceId = ''
    $controlNotebookId = ''
    $notebook = Find-DemoFabricItem -WorkspaceId $WorkspaceId -DisplayName 'NB_DatabaseHub_Control' -Type 'Notebook' -Token $fabricToken
    if ($notebook.StatusCode -eq 200 -and @($notebook.Items).Count -eq 1) {
        $controlWorkspaceId = $WorkspaceId
        $controlNotebookId = [string](Get-DemoMemberValue -InputObject @($notebook.Items)[0] -Name 'id')
    }
    elseif ($Config) {
        $ControlWorkspaceName = (Get-DemoActivityControlSetting -Config $Config).FabricWorkspaceName
        $workspaces = Get-DemoActivityControlFabricList -Uri ('{0}/workspaces' -f $script:FabricApiBaseUri) -Token $fabricToken
        $control = @($workspaces.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') -ceq $ControlWorkspaceName }) | Select-Object -First 1
        $controlId = if ($null -ne $control) { [string](Get-DemoMemberValue -InputObject $control -Name 'id') } else { '' }
        if ($controlId -match '^[0-9a-fA-F-]{36}$') {
            $notebook = Find-DemoFabricItem -WorkspaceId $controlId -DisplayName 'NB_DatabaseHub_Control' -Type 'Notebook' -Token $fabricToken
            if ($notebook.StatusCode -eq 200 -and @($notebook.Items).Count -eq 1) {
                $controlWorkspaceId = $controlId
                $controlNotebookId = [string](Get-DemoMemberValue -InputObject @($notebook.Items)[0] -Name 'id')
            }
        }
    }
    if ($controlNotebookId -match '^[0-9a-fA-F-]{36}$') {
        $links['controlNotebook'] = '{0}/groups/{1}/synapsenotebooks/{2}{3}' -f $portal, $controlWorkspaceId.ToLowerInvariant(), $controlNotebookId.ToLowerInvariant(), $ctid
    }
    # T2's migration assessment in the Azure portal (2026-11-18), for the app's migration card when Database Hub isn't
    # read live: from the Arc SQL Server instance's own resource ID. Without it, the card names the portal path. From the
    # same read, the assessment's verdict as Azure has it now (R924), which the card shows, with its time, instead.
    $t2Migration = $null
    if ($Config) {
        $migration = Get-DemoT2Migration -Config $Config
        if ($migration.Link) {
            $links['t2MigrationAssessment'] = $migration.Link
        }
        $t2Migration = $migration.Verdict
    }
    $evidence = [ordered]@{ semanticModelId = $modelId; dashboardId = $dashboardId; reportId = $reportId; controlWorkspaceId = $controlWorkspaceId; controlNotebookId = $controlNotebookId; links = $links }
    if ($null -ne $t2Migration) {
        $evidence['t2Migration'] = $t2Migration
    }
    if ($problems.Count -gt 0) {
        $evidence['problems'] = @($problems)
    }

    if (-not $modelId) {
        return New-DemoResult -CheckId 'FABRIC.APP.ITEMS' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message ('The semantic model {0} isn''t in the workspace (or more than one item has that name), and the app reads only it.' -f $settings['semanticModelName']) -Evidence $evidence -Remediation 'Run ./scripts/configure-powerbi.ps1 to deploy the history model, then run this script again.' -DocUrl $docUrl
    }
    $missing = @(@(if (-not $dashboardId) { $settings['dashboardName'] }; if (-not $reportId) { $settings['reportName'] }) | Where-Object { $_ })
    if ($missing.Count -gt 0) {
        return New-DemoResult -CheckId 'FABRIC.APP.ITEMS' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('Found {0}; not found: {1}, so the app''s Live views page explains how to add them.' -f $settings['semanticModelName'], ($missing -join ', ')) -Evidence $evidence -Remediation 'Run ./scripts/deploy.ps1: its Fabric track imports the dashboard and the history model, then the app.' -DocUrl $docUrl
    }
    return New-DemoResult -CheckId 'FABRIC.APP.ITEMS' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('Found {0}, {1}, and {2}; the app links to them in a new tab.' -f $settings['semanticModelName'], $settings['dashboardName'], $settings['reportName']) -Evidence $evidence -DocUrl $docUrl
}
