function Set-DemoFabricAppManageSetting {
    <#
    .SYNOPSIS
    Writes the Insights app's Manage settings into the deploy stage (rayfin/functions/src/manage.generated.ts) and says
    how Manage sends its actions in this deployment (FABRIC.APP.ACTIONS, ADR 0029).

    .DESCRIPTION
    The app's Manage function checks each caller with the app's own keys, at the app's API, and runs
    NB_DatabaseHub_Control through the Fabric job API for the operators. This writes what it needs, IDs and names only,
    never a secret, over the empty placeholder that Git holds and Sync-DemoFabricAppStage copies:
    - apiUrl, tenantId, workspaceId, and appId: the app's API and IDs, from the stage's deployment record
      (rayfin/.deployments.json: fabricApiUrl, fabricTenantId, fabricWorkspaceId, fabricItemId), which bind a caller's
      token to this app. The app's first rayfin up records them, so configure-fabric-app.ps1 writes the settings again
      after it, and deploys once more. issuer and audience stay empty until the identity proof shows their exact form.
    - controlWorkspaceId and controlNotebookId: NB_DatabaseHub_Control's, from Resolve-DemoFabricAppItem. deploy.ps1's
      parallel path puts the notebook in Fabric after its tracks, so a first deployment's Fabric track has none; the run
      then deploys the app once more (Complete-DemoInsightsAppManage, 2026-11-19), and -Sequential puts it there first.
    - operators: their object IDs and lowercased names, from Resolve-DemoFabricAppOperator.
    - catalog: the control's own rules (Get-DemoFabricAppManageCatalog: its targets, T5 only while it's on, its incidents,
      and a run's and a session's minutes), so the function sends only what the control accepts.

    Returns one FABRIC.APP.ACTIONS result, whose evidence has the apiUrl it wrote:
    - Pass: the settings are complete, so an operator sends the app's actions from the app, after confirming each one.
    - Warning: the app's API and IDs, the control notebook, the control's catalog, or the operators are missing; the
      function then says it isn't set up, and the app copies each request for Run all in NB_DatabaseHub_Control instead.
    - Not supported: the app has no functions (rayfin.yml's services.functions isn't enabled), so it copies them too.

    Source (checked 2026-11-18): https://learn.microsoft.com/fabric/apps/functions

    .PARAMETER StagePath
    The deploy stage (out/fabric-app), after Sync-DemoFabricAppStage.

    .PARAMETER ControlWorkspaceId
    The workspace NB_DatabaseHub_Control is in.

    .PARAMETER ControlNotebookId
    NB_DatabaseHub_Control's item ID.

    .PARAMETER Operator
    The operators, as FABRIC.APP.OPERATORS's evidence has them: objectId and names.

    .PARAMETER Config
    The demo's configuration, for the control's catalog (whether T5 is on, among the rest).

    .EXAMPLE
    Set-DemoFabricAppManageSetting -StagePath out/fabric-app -ControlWorkspaceId $workspaceId -ControlNotebookId $notebookId -Operator $operators -Config $config
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $StagePath,

        [AllowEmptyString()]
        [string] $ControlWorkspaceId = '',

        [AllowEmptyString()]
        [string] $ControlNotebookId = '',

        [AllowEmptyCollection()]
        [object[]] $Operator = @(),

        [System.Collections.IDictionary] $Config = $null
    )

    $docUrl = 'https://learn.microsoft.com/fabric/apps/functions'
    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $stage = [System.IO.Path]::GetFullPath($StagePath)
    $yml = Join-Path -Path $stage -ChildPath 'rayfin/rayfin.yml'
    # services.functions with enabled: true at its own level (four spaces), not a nested key's.
    $functionsOn = (Test-Path -LiteralPath $yml -PathType Leaf) -and ((Get-Content -LiteralPath $yml -Raw) -match '(?m)^  functions:[ \t]*\r?\n(?:    .*\r?\n)*?    enabled:[ \t]*true\b')

    $record = Get-DemoFabricAppDeploymentRecord -StagePath $stage
    $apiUrl = if ($null -ne $record -and [string]$record.ApiUrl -match '^https://[^\s"''\\]+$') { [string]$record.ApiUrl } else { '' }
    $appIds = [ordered]@{}
    foreach ($pair in @(@('tenantId', 'TenantId'), @('workspaceId', 'WorkspaceId'), @('appId', 'ItemId'))) {
        $value = if ($null -ne $record) { [string]$record.($pair[1]) } else { '' }
        $appIds[$pair[0]] = if ($value -match $guid) { $value.ToLowerInvariant() } else { '' }
    }
    $catalog = if ($Config) { Get-DemoFabricAppManageCatalog -Config $Config } else { $null }
    $workspace = if ($ControlWorkspaceId -match $guid) { $ControlWorkspaceId.ToLowerInvariant() } else { '' }
    $notebook = if ($workspace -and $ControlNotebookId -match $guid) { $ControlNotebookId.ToLowerInvariant() } else { '' }
    $operators = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Operator)) {
        $id = ([string](Get-DemoMemberValue -InputObject $item -Name 'objectId')).ToLowerInvariant()
        if ($id -notmatch $guid) {
            continue
        }
        # Assigned first: Get-DemoMemberValue returns the array as one object, which @(...) would nest.
        $rawNames = Get-DemoMemberValue -InputObject $item -Name 'names'
        $names = @($rawNames | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ -and $_.Length -le 256 } | Select-Object -Unique)
        $operators.Add([ordered]@{ objectId = $id; names = $names })
    }

    $written = $false
    $source = Join-Path -Path $stage -ChildPath 'rayfin/functions/src'
    if ((Test-Path -LiteralPath $source -PathType Container) -and $PSCmdlet.ShouldProcess($source, 'Write manage.generated.ts')) {
        $settings = [ordered]@{ apiUrl = $apiUrl; tenantId = $appIds['tenantId']; workspaceId = $appIds['workspaceId']; appId = $appIds['appId']; issuer = ''; audience = ''; controlWorkspaceId = $workspace; controlNotebookId = $notebook; operators = @($operators); catalog = $catalog }
        $text = @(
            '// Written by scripts/configure-fabric-app.ps1 in the deploy stage: Manage''s settings (ADR 0029), IDs and names',
            '// only, never a secret. Git holds an empty placeholder.',
            'import type { ManageSettings } from "./manage-core.js";',
            '',
            ('export const MANAGE_SETTINGS: ManageSettings = {0};' -f (ConvertTo-Json -InputObject $settings -Depth 8 -Compress)),
            ''
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path -Path $source -ChildPath 'manage.generated.ts'), $text, [System.Text.UTF8Encoding]::new($false))
        $written = $true
    }

    $evidence = [ordered]@{ functionsEnabled = [bool]$functionsOn; written = $written; apiUrl = $apiUrl; appId = $appIds['appId']; controlWorkspaceId = $workspace; controlNotebookId = $notebook; operators = $operators.Count; controlTargets = @(if ($catalog) { $catalog['targets'] }) }
    if (-not $functionsOn) {
        return New-DemoResult -CheckId 'FABRIC.APP.ACTIONS' -Area 'fabric' -Target 'fabric' -Status 'Not supported' -Message 'This app has no functions (rayfin.yml''s services.functions), so Manage copies each request for Run all in NB_DatabaseHub_Control, which sends it with the same checks.' -Evidence $evidence -DocUrl $docUrl
    }
    $missing = [System.Collections.Generic.List[string]]::new()
    $fixes = [System.Collections.Generic.List[string]]::new()
    if (-not $apiUrl -or @($appIds.Values | Where-Object { -not $_ }).Count -gt 0) {
        $missing.Add('the app''s API and IDs (its first deploy records them)')
        $fixes.Add('Run ./scripts/configure-fabric-app.ps1 again once the app is deployed.')
    }
    if (-not $notebook) {
        $missing.Add('NB_DatabaseHub_Control')
        $fixes.Add('Run ./scripts/deploy.ps1: it puts the session control''s notebook in Fabric, then deploys the app once more with its IDs (DEPLOY.CONTROL says what the notebook still needs).')
    }
    if ($null -eq $catalog -or @($catalog['targets']).Count -eq 0) {
        $missing.Add('the control''s catalog')
        $fixes.Add('Run ./scripts/configure-fabric-app.ps1 with the demo''s configuration (-ConfigPath).')
    }
    if ($operators.Count -eq 0) {
        $missing.Add('operators')
        $fixes.Add('FABRIC.APP.OPERATORS says why there are none.')
    }
    if ($missing.Count -gt 0) {
        $list = if ($missing.Count -eq 1) { $missing[0] } elseif ($missing.Count -eq 2) { '{0} and {1}' -f $missing[0], $missing[1] } else { '{0}, and {1}' -f ($missing[0..($missing.Count - 2)] -join ', '), $missing[-1] }
        return New-DemoResult -CheckId 'FABRIC.APP.ACTIONS' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('Manage''s function is missing {0}, so the app copies each request for Run all in NB_DatabaseHub_Control instead of sending it.' -f $list) -Evidence $evidence -Remediation ($fixes -join ' ') -DocUrl $docUrl
    }
    return New-DemoResult -CheckId 'FABRIC.APP.ACTIONS' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('Manage sends its actions from the app for {0} {1}: its function checks each caller with the app''s own keys, and runs NB_DatabaseHub_Control through the Fabric job API after the caller confirms.' -f $operators.Count, $(if ($operators.Count -eq 1) { 'operator' } else { 'operators' })) -Evidence $evidence -DocUrl $docUrl
}
