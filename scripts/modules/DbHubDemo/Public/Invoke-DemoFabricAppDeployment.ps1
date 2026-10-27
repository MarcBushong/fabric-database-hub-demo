function Invoke-DemoFabricAppDeployment {
    <#
    .SYNOPSIS
    Deploys the Fabric App from its stage with 'rayfin up', unattended and idempotent, and reads the deployment back
    with 'rayfin up status' (FABRIC.APP.DEPLOY, FABRIC.APP.STATUS).

    .DESCRIPTION
    Runs the stage's pinned Rayfin CLI (https://learn.microsoft.com/fabric/apps/cli-reference):
      rayfin up --workspace-id <id> --item-name <name> --tenant <id> --yes --json [--dry-run]
    --yes reuses the item with the same name (or the one rayfin/.deployments.json records) instead of prompting, so a
    re-run updates APP_DatabaseHub_Insights in place and nothing is deleted. --json keeps the CLI silent and
    non-interactive: it never opens a browser. The JSON carries the app's publishable key, which is redacted before
    anything is kept. For a workspace without a usable capacity, the CLI can start a trial or assign one (it refuses
    --capacity-id together with --workspace-id), so the caller deploys only to a workspace whose capacity is Active.

    A "success" status is a Pass for FABRIC.APP.DEPLOY: the item exists and the build is hosted. Whether the app
    works is checked separately (Test-DemoFabricApp). "partial" (a connector failed to apply) and "error" are Fails,
    except an expired or missing sign-in, which is Manual action required with the login command. Then
    'rayfin up status --json' must report the item deployed and its endpoint reachable (FABRIC.APP.STATUS).

    The results' evidence holds the item ID, the hosting URL, and the portal deep link for the caller; they go only
    to the Git-ignored out/ folder.

    .PARAMETER StagePath
    The deploy stage (out/fabric-app) after Sync-DemoFabricAppStage.

    .PARAMETER WorkspaceId
    The Fabric workspace that holds the app item (fabric.workspaceId).

    .PARAMETER TenantId
    The demo's tenant (tenantId); the CLI refuses a sign-in to another tenant.

    .PARAMETER ItemName
    The app item's display name.

    .PARAMETER DryRun
    Validate the project and resolve the workspace without deploying (rayfin up --dry-run).

    .PARAMETER TimeoutSeconds
    How long 'rayfin up' may run (build, upload, and service provisioning).

    .EXAMPLE
    Invoke-DemoFabricAppDeployment -StagePath ./out/fabric-app -WorkspaceId $ws -TenantId $tenant -ItemName APP_DatabaseHub_Insights
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $StagePath,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,99}$')]
        [string] $ItemName,

        [switch] $DryRun,

        [ValidateRange(60, 7200)]
        [int] $TimeoutSeconds = 1200
    )

    $settings = Get-DemoFabricAppSetting
    $cliReference = 'https://learn.microsoft.com/fabric/apps/cli-reference'
    $deployDoc = 'https://learn.microsoft.com/fabric/apps/deploy-app'
    $loginCommand = 'npx --yes --package={0}@{1} -- rayfin login --tenant {2}' -f $settings['cliPackage'], $settings['cliVersion'], $TenantId
    $arguments = [System.Collections.Generic.List[string]]::new([string[]]@('up', '--workspace-id', $WorkspaceId, '--item-name', $ItemName, '--tenant', $TenantId, '--yes', '--json'))
    if ($DryRun) {
        $arguments.Add('--dry-run')
    }
    $planned = 'rayfin {0}' -f ($arguments -join ' ')
    $results = [System.Collections.Generic.List[object]]::new()

    if (-not $PSCmdlet.ShouldProcess(('Fabric app item {0} in workspace {1}' -f $ItemName, $WorkspaceId), $(if ($DryRun) { 'Validate with rayfin up --dry-run' } else { 'Deploy with rayfin up' }))) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message ('Planned: {0}' -f $planned) -Evidence @{ plannedCommand = $planned } -DocUrl $cliReference))
        return $results.ToArray()
    }

    $started = [System.Diagnostics.Stopwatch]::StartNew()
    $up = Invoke-DemoRayfinCli -StagePath $StagePath -ArgumentList $arguments.ToArray() -TimeoutSeconds $TimeoutSeconds
    $seconds = [int]$started.Elapsed.TotalSeconds
    $data = $up.Data
    $status = if ($data) { [string]$data['status'] } else { '' }
    $errorText = if ($data -and $data['error']) { [string]$data['error'] } elseif ($up.ExitCode -eq -1) { $up.StdErr } else { (@($up.StdErr, $up.StdOut) | Where-Object { $_ } | Select-Object -First 1) }
    if ($errorText -and $errorText.Length -gt 800) {
        $errorText = $errorText.Substring(0, 800)
    }
    $authProblem = $errorText -match '(?i)not signed in|sign in|signed in|login|re-?authenticate|interaction_required|AADSTS|token (has )?expired|expired token'

    if ($DryRun) {
        if ($up.ExitCode -eq 0 -and $status -ne 'error') {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message ('Dry run: rayfin up validated the project and resolved the workspace in {0} s; nothing was deployed.' -f $seconds) -Evidence @{ plannedCommand = $planned; seconds = $seconds } -DocUrl $cliReference))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status $(if ($authProblem) { 'Manual action required' } else { 'Fail' }) -Message ('Dry run: rayfin up --dry-run failed: {0}' -f $errorText) -Evidence @{ exitCode = $up.ExitCode; seconds = $seconds } -Remediation $(if ($authProblem) { 'Sign in again: {0}' -f $loginCommand } else { 'Fix the reported problem in fabric/app and run the script again.' }) -DocUrl $cliReference))
        }
        return $results.ToArray()
    }

    $deployment = if ($data -and $data['deployment'] -is [System.Collections.IDictionary]) { $data['deployment'] } else { @{} }
    $itemId = [string]$deployment['rayfinItemId']
    $evidence = [ordered]@{
        itemName         = $ItemName
        itemId           = $itemId
        hostingUrl       = [string]$deployment['hostingUrl']
        itemUrl          = [string]$deployment['fabricPortalUrl']
        status           = $status
        seconds          = $seconds
        failedConnectors = @(if ($data) { $data['failedConnectors'] | Where-Object { $_ } })
        steps            = @(if ($data -and $data['steps'] -is [System.Collections.IDictionary]) { $data['steps'].Keys | Sort-Object })
    }
    if ($status -eq 'success' -and $itemId) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('rayfin up deployed the Fabric app item {0} in {1} s (created or updated in place).' -f $ItemName, $seconds) -Evidence $evidence -DocUrl $deployDoc))
    }
    elseif ($status -eq 'partial') {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('rayfin up deployed {0}, but these connectors failed to apply: {1}.' -f $ItemName, ($evidence['failedConnectors'] -join ', ')) -Evidence $evidence -Remediation 'Check that the semantic model exists and that rayfin/.env in the stage has its IDs, then run the script again.' -DocUrl 'https://learn.microsoft.com/fabric/apps/connectors'))
        return $results.ToArray()
    }
    else {
        $state = if ($authProblem) { 'Manual action required' } else { 'Fail' }
        $remediation = if ($authProblem) { 'Sign in again as the demo''s Fabric user, then run the script again: {0}' -f $loginCommand } else { 'Fix the reported problem and run the script again; nothing is deleted, and a re-run reuses the item.' }
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status $state -Message ('rayfin up didn''t deploy {0} (exit code {1}, {2} s): {3}' -f $ItemName, $up.ExitCode, $seconds, $errorText) -Evidence $evidence -Remediation $remediation -DocUrl $deployDoc))
        return $results.ToArray()
    }

    $check = Invoke-DemoRayfinCli -StagePath $StagePath -ArgumentList @('up', 'status', '--json') -TimeoutSeconds 300
    $view = $check.Data
    $health = if ($view -and $view['endpointHealth'] -is [System.Collections.IDictionary]) { $view['endpointHealth'] } else { @{} }
    $statusEvidence = [ordered]@{
        deployed      = [bool]($view -and $view['deployed'])
        authenticated = [bool]($view -and $view['authenticated'])
        reachable     = [bool]$health['reachable']
        httpStatus    = $health['httpStatus']
        exitCode      = $check.ExitCode
    }
    if ($statusEvidence['deployed'] -and $statusEvidence['reachable'] -and -not $health['error'] -and $check.ExitCode -eq 0) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.STATUS' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('rayfin up status: {0} is deployed and its endpoint is reachable.' -f $ItemName) -Evidence $statusEvidence -DocUrl $cliReference))
    }
    else {
        $viewError = if ($view) { $view['error'] } else { $null }
        $why = if ($health['error']) { [string]$health['error'] } elseif ($viewError -is [System.Collections.IDictionary]) { [string]$viewError['message'] } elseif ($viewError) { [string]$viewError } else { 'the status didn''t report a deployed, reachable item' }
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.STATUS' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('rayfin up status: {0}' -f $why) -Evidence $statusEvidence -Remediation 'Wait a minute and run the script with -CheckOnly; a just-deployed item can take a moment to answer.' -DocUrl $cliReference))
    }
    return $results.ToArray()
}
