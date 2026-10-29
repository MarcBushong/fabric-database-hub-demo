#Requires -Version 7.4
<#
.SYNOPSIS
Deploys the read-only Fabric App APP_DatabaseHub_Insights (Phase 19b) over the SM_DatabaseHub_History semantic model,
unattended and idempotent, and checks it end to end.

.DESCRIPTION
Fabric Apps is a preview. The app's source is fabric/app (React and the Rayfin SDK); the Rayfin CLI pinned in
fabric/app/package-lock.json deploys it as a Fabric item (type AppBackend) with protected static hosting and one
read-only semantic model connector. Every step is a DbHubDemo module function that returns ADR 0012 records; the
script prints them, writes them as JSON lines to -OutputPath, and turns them into the exit code: 0 without a Fail,
1 with a Fail, 2 with -TreatManualAsError and a Manual action required. Re-runs converge: the item is found by name
(or by the stage's deployment record) and updated in place, and nothing is ever deleted.

Before any Fabric REST request, the subscription guard (Assert-DemoAzContext with the configuration's subscription,
tenant, and azureAccount) must pass; the Fabric token then comes from the Azure CLI (Get-DemoFabricToken). The Rayfin
CLI uses its own cached sign-in, which the operator creates once with 'rayfin login', or with -SignIn, which runs that
sign-in in this console when it's missing (the CLI's service principal sign-in isn't supported yet). The script never
signs in to Azure, never changes the Azure CLI context, and never pauses, resumes, or scales the capacity.

1. Source: rayfin/rayfin.yml holds only ${...} placeholders for IDs, protected asset access, and the pinned CLI
   (FABRIC.APP.SOURCE).
2. Workspace: Test-DemoFabricWorkspace confirms the role and an Active Fabric capacity (FABRIC.P5.*). 'rayfin up'
   can start a trial or assign a capacity when a workspace has none, so it runs only on an Active capacity.
3. Items: Find-DemoFabricItem resolves the semantic model (required), the Real-Time Dashboard, and the report by
   name (FABRIC.APP.ITEMS). Their IDs build the app's new-tab links.
4. Stage: Sync-DemoFabricAppStage mirrors fabric/app into the Git-ignored out/fabric-app, writes the connector's IDs
   to rayfin/.env and the links and the resource group name (for the Database Agent prompts) to
   public/dbhub-app.json, and runs npm ci when the lock file changed (FABRIC.APP.STAGE, FABRIC.APP.DEPENDENCIES).
5. Prerequisites: Test-DemoFabricAppPrerequisite checks Node.js, the CLI's sign-in to the demo's tenant, and the
   Fabric Apps (preview) and Execute Queries tenant settings (FABRIC.APP.NODE, .SIGNIN, .TENANTSETTING,
   .EXECUTEQUERIES). With -SignIn, a missing sign-in is done interactively first (Connect-DemoRayfinCli).
6. Deploy: Invoke-DemoFabricAppDeployment runs 'rayfin up --yes --json' and 'rayfin up status'
   (FABRIC.APP.DEPLOY, FABRIC.APP.STATUS).
7. Checks: Test-DemoFabricApp runs every DAX query the app uses through the connector, confirms that the hosted
   assets refuse anonymous requests, and lists the browser check (FABRIC.APP.CONNECTOR, .QUERIES, .HOSTING,
   .BROWSER). The supported way to open the app is its item in the Fabric workspace (embedded); opening the hosted
   URL directly is a known preview limitation. Without -FabricAdmin, a passing deploy proves the Fabric Apps setting
   and a passing connector check proves the Execute Queries setting, so both become a Pass.

-WhatIf validates the source and lists the plan without a token, a network call, or a write. -DryRun runs steps 1
to 5 and 'rayfin up --dry-run'. -CheckOnly runs step 7 against the deployed app, without deploying.

Sources:
- Fabric Apps overview: https://learn.microsoft.com/fabric/apps/overview
- Rayfin CLI reference: https://learn.microsoft.com/fabric/apps/cli-reference
- Deploy an app: https://learn.microsoft.com/fabric/apps/deploy-app
- Connectors: https://learn.microsoft.com/fabric/apps/connectors
- Hosting: https://learn.microsoft.com/fabric/apps/hosting
- Fabric authentication: https://learn.microsoft.com/fabric/apps/fabric-authentication
- Items - List Items: https://learn.microsoft.com/rest/api/fabric/core/items/list-items

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json): the subscription, tenant, azureAccount, and fabric.workspaceId.

.PARAMETER WorkspaceId
Deploy into this workspace instead of fabric.workspaceId.

.PARAMETER FabricToken
A Fabric REST API token you already have, as a SecureString. Without it, the script uses the Azure CLI after the
subscription guard.

.PARAMETER StagePath
The Git-ignored deploy stage (default: out/fabric-app). The Rayfin CLI keeps its deployment record there.

.PARAMETER DryRun
Run the checks and 'rayfin up --dry-run'; nothing is deployed.

.PARAMETER CheckOnly
Check the deployed app (connector, hosting, browser steps) without deploying.

.PARAMETER SkipInstall
Don't run npm ci in the stage.

.PARAMETER Queries
All runs every query the app uses through the connector (about 14 CLI calls); Probe runs only the connector check.

.PARAMETER FabricAdmin
The caller is a Fabric administrator, so read the Fabric Apps (preview) tenant setting through the admin API.

.PARAMETER SignIn
When the Rayfin CLI isn't signed in to the demo's tenant (FABRIC.APP.SIGNIN), sign it in now, interactively: the
stage's pinned CLI runs 'rayfin login --tenant <tenantId>' in this console and opens a browser, then the sign-in is
checked again (Connect-DemoRayfinCli; prerequisite P14). Only in an interactive session: in CI it's Not supported, and
nothing is deployed until a person signs in. The script never sees or keeps the sign-in.

.PARAMETER TimeoutSeconds
How long 'rayfin up' and npm ci may each run.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.PARAMETER TreatManualAsError
Exit with code 2 when a check is Manual action required and none failed.

.EXAMPLE
./scripts/configure-fabric-app.ps1 -WhatIf

.EXAMPLE
./scripts/configure-fabric-app.ps1

.EXAMPLE
./scripts/configure-fabric-app.ps1 -SignIn

.EXAMPLE
./scripts/configure-fabric-app.ps1 -CheckOnly -Queries Probe
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $WorkspaceId,

    [securestring] $FabricToken,

    [string] $StagePath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/fabric-app'),

    [switch] $DryRun,

    [switch] $CheckOnly,

    [switch] $SkipInstall,

    [ValidateSet('All', 'Probe')]
    [string] $Queries = 'All',

    [switch] $FabricAdmin,

    [switch] $SignIn,

    [ValidateRange(60, 7200)]
    [int] $TimeoutSeconds = 1200,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/configure-fabric-app.jsonl'),

    [switch] $TreatManualAsError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by deploy.ps1 or a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$StagePath = Resolve-DemoUserPath -Path $StagePath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$sourcePath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../fabric/app'))
$stage = [System.IO.Path]::GetFullPath($StagePath)
$versions = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
$app = $versions['fabricApp']
$itemName = [string]$app['itemName']
$resultsPath = $OutputPath
$manualIsError = [bool]$TreatManualAsError
$started = [System.Diagnostics.Stopwatch]::StartNew()
$results = [System.Collections.Generic.List[object]]::new()
$skip = {
    param([string] $CheckId, [string] $Message)
    $results.Add((New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message $Message))
}
$finish = {
    Write-DemoLog -Message ('configure-fabric-app.ps1 finished in {0} s.' -f [int]$started.Elapsed.TotalSeconds)
    $results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
    foreach ($item in $results | Where-Object { $_.status -in 'Fail', 'Manual action required' -and $_.remediation }) {
        Write-DemoLog -Level Warning -Message ('{0}: {1}' -f $item.checkId, $item.remediation)
    }
    $warnings = @($results | Where-Object { $_.status -eq 'Warning' })
    if ($warnings.Count -gt 0) {
        Write-DemoLog -Level Warning -Message ('{0} check(s) are Warnings; see {1}.' -f $warnings.Count, $resultsPath)
    }
    Export-DemoResult -Result $results.ToArray() -Path $resultsPath
    exit (Get-DemoExitCode -Result $results.ToArray() -TreatManualAsError:$manualIsError)
}

#region Step 1: source
$sourceProblems = [System.Collections.Generic.List[string]]::new()
$yamlPath = Join-Path -Path $sourcePath -ChildPath 'rayfin/rayfin.yml'
$packagePath = Join-Path -Path $sourcePath -ChildPath 'package.json'
if (-not (Test-Path -LiteralPath $yamlPath -PathType Leaf) -or -not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    $sourceProblems.Add('fabric/app/rayfin/rayfin.yml or fabric/app/package.json is missing')
}
else {
    $yaml = Get-Content -LiteralPath $yamlPath -Raw
    if ($yaml -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
        $sourceProblems.Add('rayfin.yml holds a literal ID; use the ${DBHUB_...} placeholders')
    }
    if ($yaml -notmatch '(?m)^\s+assetAccess:\s*protected\s*$') {
        $sourceProblems.Add('rayfin.yml doesn''t set staticHosting.assetAccess to protected')
    }
    if ($yaml -notmatch ('(?m)^\s+-\s*name:\s*{0}\s*$' -f [regex]::Escape([string]$app['connectorName']))) {
        $sourceProblems.Add(('rayfin.yml has no connector named {0}' -f $app['connectorName']))
    }
    $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json -AsHashtable
    $pinned = [string]$package['devDependencies'][[string]$app['cliPackage']]
    if ($pinned -ne [string]$app['cliVersion']) {
        $sourceProblems.Add(('package.json pins {0} {1}, but config/versions.json records {2}' -f $app['cliPackage'], $pinned, $app['cliVersion']))
    }
}
if ($sourceProblems.Count -gt 0) {
    $results.Add((New-DemoResult -CheckId 'FABRIC.APP.SOURCE' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('The app source isn''t ready: {0}.' -f ($sourceProblems -join '; ')) -Remediation 'Fix fabric/app and run the script again.' -DocUrl 'https://learn.microsoft.com/fabric/apps/project-structure'))
    & $finish
}
$results.Add((New-DemoResult -CheckId 'FABRIC.APP.SOURCE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('fabric/app is ready: placeholders only, protected assets, connector {0}, and the Rayfin CLI {1} pinned.' -f $app['connectorName'], $app['cliVersion']) -DocUrl 'https://learn.microsoft.com/fabric/apps/project-structure'))
#endregion Step 1: source

$config = $null
if (Test-Path -LiteralPath $ConfigPath) {
    $config = Get-DemoConfig -Path $ConfigPath
}
elseif (-not ($WorkspaceId -and $FabricToken)) {
    throw "Configuration file not found: $ConfigPath. Create it from config/demo.config.example.json, or pass -WorkspaceId and -FabricToken."
}
$tenantId = if ($config) { [string]$config['tenantId'] } else { '' }
# The workspace by name (Phase 26a, ADR 0021): resolved here, and created when it's missing and fabric.createIfMissing
# is true, or taken from the fabric.workspaceId override. The app needs no lakehouse of its own.
$resolveWorkspace = {
    param([securestring] $Token)
    $resolve = @{ Config = $config; Create = $true; SkipLakehouse = $true; TimeoutSeconds = $TimeoutSeconds; WhatIf = [bool]$WhatIfPreference; Confirm = $false }
    if ($null -ne $Token) {
        $resolve['Token'] = $Token
    }
    $resolution = Resolve-DemoFabricConfig @resolve
    $results.AddRange([object[]]@($resolution.Results))
    return $resolution.Config
}
$workspaceTarget = {
    $fabric = if ($config -and $config['fabric']) { $config['fabric'] } else { @{} }
    if ($WorkspaceId) { $WorkspaceId } else { [string]$fabric['workspaceId'] }
}
if ($tenantId -and $tenantId -notmatch $guidPattern) {
    & $skip 'FABRIC.APP.DEPLOY' 'No tenant (tenantId) is configured, so nothing was deployed.'
    & $finish
}

if ($WhatIfPreference) {
    # Dry run: no guard, no token, no network call, and no write. The plan only; without the fabric.workspaceId
    # override, it shows the all-zero placeholder for the workspace.
    if ($config) {
        $config = & $resolveWorkspace $null
    }
    $targetWorkspaceId = & $workspaceTarget
    if ($targetWorkspaceId -notmatch $guidPattern) {
        $targetWorkspaceId = '00000000-0000-0000-0000-000000000000'
    }
    if ($tenantId -notmatch $guidPattern) {
        $tenantId = '00000000-0000-0000-0000-000000000000'
    }
    $results.AddRange([object[]]@(Sync-DemoFabricAppStage -SourcePath $sourcePath -StagePath $stage -WhatIf))
    if ($SignIn) {
        & $skip 'FABRIC.APP.SIGNIN' 'Dry run: -SignIn would sign the Rayfin CLI in to the demo''s tenant (rayfin login --tenant; a browser opens) if rayfin login status says it isn''t.'
    }
    if (-not $CheckOnly) {
        $results.AddRange([object[]]@(Invoke-DemoFabricAppDeployment -StagePath $stage -WorkspaceId $targetWorkspaceId -TenantId $tenantId -ItemName $itemName -WhatIf))
    }
    & $skip 'FABRIC.APP.CONNECTOR' ('Planned: run the app''s DAX queries ({0}) through the {1} connector, check that the hosted assets refuse anonymous requests, and list the browser check.' -f $Queries, $app['connectorName'])
    & $finish
}

#region Step 2-3: guard, workspace, and items
if ($null -eq $FabricToken) {
    if (-not $config) {
        throw 'Pass -FabricToken, or create the configuration so the script can use the signed-in Azure CLI.'
    }
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message `
                    -Remediation "Sign in once with 'az login --tenant <tenantId>' as the configured azureAccount, then run the script again. Nothing was changed."))
        & $skip 'FABRIC.APP.DEPLOY' 'The subscription guard failed, so no token was requested and nothing was deployed.'
        & $finish
    }
    $FabricToken = Get-DemoFabricToken -SubscriptionId $config['subscriptionId']
}
if ($config) {
    $config = & $resolveWorkspace $FabricToken
}
$targetWorkspaceId = & $workspaceTarget
if ($targetWorkspaceId -notmatch $guidPattern -or $tenantId -notmatch $guidPattern) {
    & $skip 'FABRIC.APP.DEPLOY' 'The Fabric workspace isn''t resolved (FABRIC.RESOLVE.WORKSPACE says why) or no tenant (tenantId) is configured, so nothing was deployed.'
    & $finish
}

$capacityId = ''
$capacityReady = $false
$workspaceConfig = @{ subscriptionId = $(if ($config) { $config['subscriptionId'] } else { '' }); fabric = @{ workspaceId = $targetWorkspaceId } }
$workspaceResults = @(Test-DemoFabricWorkspace -Config $workspaceConfig -Token $FabricToken)
$results.AddRange([object[]]$workspaceResults)
$capacity = $workspaceResults | Where-Object { $_.checkId -eq 'FABRIC.P5.CAPACITY' } | Select-Object -First 1
if ($capacity) {
    # Warning means the SKU couldn't be read (deploy with the assigned capacity) or the assignment is still running (wait).
    $capacityId = [string]$capacity.evidence['capacityId']
    $progress = [string]$capacity.evidence['capacityAssignmentProgress']
    $capacityReady = $capacity.status -eq 'Pass' -or ($capacity.status -eq 'Warning' -and $capacityId -match $guidPattern -and $progress -ne 'InProgress')
}

$itemsResult = Resolve-DemoFabricAppItem -WorkspaceId $targetWorkspaceId -TenantId $tenantId -Token $FabricToken
$results.Add($itemsResult)
$modelId = [string]$itemsResult.evidence['semanticModelId']
$links = $itemsResult.evidence['links']
if ($modelId -notmatch $guidPattern) {
    & $skip 'FABRIC.APP.DEPLOY' 'The semantic model the app reads isn''t deployed, so the app wasn''t deployed.'
    & $finish
}
#endregion Step 2-3: guard, workspace, and items

#region Step 4-5: stage and prerequisites
$deployFile = [ordered]@{
    expectedAccount  = $(if ($config) { [string]$config['azureAccount'] } else { '' })
    expectedTenantId = $tenantId
    # Names only, for the app's Database Agent prompts: never an ID or a secret.
    resourceGroup    = $(if ($config -and $config['prefix'] -and $config['environment']) { 'rg-{0}-{1}' -f $config['prefix'], $config['environment'] } else { '' })
    links            = $links
}
$envValues = [ordered]@{ DBHUB_FABRIC_WORKSPACE_ID = $targetWorkspaceId; DBHUB_SEMANTIC_MODEL_ID = $modelId }
$stageResults = @(Sync-DemoFabricAppStage -SourcePath $sourcePath -StagePath $stage -EnvValues $envValues -DeployFile $deployFile -SkipInstall:$SkipInstall -TimeoutSeconds $TimeoutSeconds -Confirm:$false)
$results.AddRange([object[]]$stageResults)
if (@($stageResults | Where-Object { $_.status -eq 'Fail' }).Count -gt 0) {
    & $skip 'FABRIC.APP.DEPLOY' 'The deploy stage isn''t ready, so nothing was deployed.'
    & $finish
}
$prerequisites = @(Test-DemoFabricAppPrerequisite -Config $config -StagePath $stage -FabricAdmin:$FabricAdmin -Token $FabricToken)
$signInResult = $prerequisites | Where-Object { $_.checkId -eq 'FABRIC.APP.SIGNIN' } | Select-Object -First 1
if ($SignIn -and $config -and $signInResult -and $signInResult.status -ne 'Pass') {
    # The one-time interactive sign-in (P14, Phase 26b): only where a person can answer it, never in CI.
    $signedIn = Connect-DemoRayfinCli -Config $config -StagePath $stage -Confirm:$false
    $prerequisites = @($prerequisites | ForEach-Object { if ($_.checkId -eq 'FABRIC.APP.SIGNIN') { $signedIn } else { $_ } })
}
$settingIds = @(@($app['tenantSettings']) | ForEach-Object { [string]$_['checkId'] })
$tenantSettings = @($prerequisites | Where-Object { $_.checkId -in $settingIds })
$results.AddRange([object[]]@($prerequisites | Where-Object { $_.checkId -notin $settingIds }))
$blocking = @($prerequisites | Where-Object { ($_.checkId -eq 'FABRIC.APP.NODE' -and $_.status -in 'Fail', 'Manual action required') -or ($_.checkId -eq 'FABRIC.APP.SIGNIN' -and $_.status -ne 'Pass') })
#endregion Step 4-5: stage and prerequisites

#region Step 6: deploy
$hostingUrl = ''
$itemUrl = ''
$deployed = $false
if ($CheckOnly) {
    Write-DemoLog -Message 'Checking the deployed app only (-CheckOnly).'
}
elseif ($blocking.Count -gt 0) {
    & $skip 'FABRIC.APP.DEPLOY' ('Not deployed: {0} needs attention first.' -f (($blocking | ForEach-Object { $_.checkId }) -join ', '))
}
elseif (-not $capacityReady) {
    & $skip 'FABRIC.APP.DEPLOY' 'Not deployed: the workspace isn''t on an Active Fabric capacity (FABRIC.P5.CAPACITY), and rayfin up would try to start a trial or assign one.'
}
elseif ($PSCmdlet.ShouldProcess("Fabric app '$itemName' in Fabric workspace $targetWorkspaceId", $(if ($DryRun) { 'Validate with rayfin up --dry-run' } else { 'Deploy with rayfin up' }))) {
    $deploy = @(Invoke-DemoFabricAppDeployment -StagePath $stage -WorkspaceId $targetWorkspaceId -TenantId $tenantId -ItemName $itemName -DryRun:$DryRun -TimeoutSeconds $TimeoutSeconds -Confirm:$false)
    $results.AddRange([object[]]$deploy)
    $deployResult = $deploy | Where-Object { $_.checkId -eq 'FABRIC.APP.DEPLOY' } | Select-Object -First 1
    if ($deployResult -and $deployResult.status -eq 'Pass') {
        $deployed = $true
        $hostingUrl = [string]$deployResult.evidence['hostingUrl']
        $itemUrl = [string]$deployResult.evidence['itemUrl']
    }
}
else {
    & $skip 'FABRIC.APP.DEPLOY' 'Skipped at the confirmation prompt.'
}
#endregion Step 6: deploy

#region Step 7: checks
if ($DryRun) {
    & $skip 'FABRIC.APP.CONNECTOR' 'Dry run: the deployed app wasn''t checked.'
}
elseif ($deployed -or $CheckOnly) {
    if ($CheckOnly -and @($prerequisites | Where-Object { $_.checkId -eq 'FABRIC.APP.SIGNIN' -and $_.status -ne 'Pass' }).Count -gt 0) {
        & $skip 'FABRIC.APP.CONNECTOR' 'The Rayfin CLI isn''t signed in to the demo''s tenant, so the connector wasn''t checked.'
    }
    else {
        $results.AddRange([object[]]@(Test-DemoFabricApp -StagePath $stage -HostingUrl $hostingUrl -ItemUrl $itemUrl -Queries $Queries))
    }
}
else {
    & $skip 'FABRIC.APP.CONNECTOR' 'The app wasn''t deployed in this run, so it wasn''t checked. Run with -CheckOnly to check the deployed app.'
}
#endregion Step 7: checks

# Without -FabricAdmin, tenant settings can't be read, but the check each one gates proves it's on for the operator:
# creating or updating the item (Fabric Apps), and a DAX query through the connector (Execute Queries).
foreach ($setting in @($app['tenantSettings'])) {
    $current = $tenantSettings | Where-Object { $_.checkId -eq [string]$setting['checkId'] } | Select-Object -First 1
    $proof = $results | Where-Object { $_.checkId -eq [string]$setting['verifiedBy'] -and $_.status -eq 'Pass' } | Select-Object -First 1
    if ($current -and $current.status -eq 'Manual action required' -and -not $FabricAdmin -and $proof) {
        $current = New-DemoResult -CheckId ([string]$setting['checkId']) -Area 'fabric' -Target 'tenant' -Status 'Pass' -Message ('The Fabric tenant setting "{0}" is enabled for the operator: {1} passed, and the setting gates it (verified functionally; reading the setting itself needs -FabricAdmin).' -f $setting['title'], $setting['verifiedBy']) -Evidence @{ checkedThroughApi = $false; verifiedBy = [string]$setting['verifiedBy'] } -DocUrl ([string]$setting['docUrl'])
    }
    if ($current) {
        $results.Add($current)
    }
}

& $finish
