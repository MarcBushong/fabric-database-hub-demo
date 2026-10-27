#Requires -Version 7.4
<#
.SYNOPSIS
Deploys the Power BI history report (Phase 19): the SM_DatabaseHub_History semantic model, its refresh and data
check, and the RPT_DatabaseHub_History report. Unattended and idempotent.

.DESCRIPTION
A deploy step that runs without prompts (deploy.ps1's parallel Fabric track calls it, as it calls
configure-fabric.ps1 -CheckDashboardData). Every step is a DbHubDemo module function that returns ADR 0012 records;
the script prints them, writes them as JSON lines to -OutputPath, and turns them into the exit code: 0 without a
Fail, 1 with a Fail, 2 with -TreatManualAsError and a Manual action required. Re-runs converge: items are found by
name and updated in place, and nothing is ever deleted.

Before any request, the subscription guard (Assert-DemoAzContext with the configuration's subscription, tenant, and
azureAccount) must pass; tokens then come from the Azure CLI through Invoke-DemoAz with --subscription (Fabric:
Get-DemoFabricToken; Power BI: Get-DemoPowerBIToken). A failed guard stops the run with nothing sent. The script
never signs in, never changes the Azure CLI context, and never pauses, resumes, or scales the capacity: a paused
capacity is Manual action required.

0. Fabric resources by name (Phase 26a, ADR 0021): Resolve-DemoFabricConfig finds the workspace and the lakehouse
   by name (fabric.workspaceName, fabric.lakehouseName) and creates them when they're missing and
   fabric.createIfMissing is true (FABRIC.RESOLVE.*). The repo stores no Fabric ID.
1. Semantic model: Get-DemoFabricSemanticModelDefinition reads the TMDL in fabric/powerbi and fills in the resolved
   lakehouse; Import-DemoFabricItem (Phase 18) creates the model or updates its definition
   (FABRIC.IMPORT.SM_DATABASEHUB_HISTORY).
2. Refresh: Invoke-DemoSemanticModelRefresh frames the Direct Lake model on the lakehouse's current tables
   (FABRIC.SEMANTICMODEL.REFRESH). Tables that a notebook has just created take a while to reach Direct Lake, so a
   refresh that can't see some of them (0xC14700DF) is sent again every 2 minutes for up to -RefreshRetryMinutes.
3. Data: Test-DemoSemanticModelData counts the rows of every Direct Lake table and evaluates every measure with DAX
   (FABRIC.SEMANTICMODEL.ROWS, .MEASURE.*, .INFOMEASURES, and the summary .DATA). A measure that is blank over the
   whole history is evaluated again per telemetry bin, incident, and signal, the context its visual sets; one that
   stays blank is a Warning until a scenario runs. DAX errors are Fails.
4. Report: Get-DemoFabricReportDefinition binds the generated PBIR to the model with the minimal byConnection form;
   Import-DemoFabricItem creates or updates it (FABRIC.IMPORT.RPT_DATABASEHUB_HISTORY); Test-DemoPowerBIReport checks
   the binding and the pages (FABRIC.REPORT.BINDING, FABRIC.REPORT.PAGES).

The script creates no app. The demo's Fabric app is a separate item, a Fabric Apps (preview) item built with the
Rayfin SDK and CLI over this semantic model (fabric/powerbi/README.md).

-WhatIf builds and validates both definitions from the files and lists the planned requests, without a token or a
network call; without ID overrides, the plan shows the all-zero placeholder for the workspace and the lakehouse. -CheckModelData runs step 3 alone against the deployed model, without importing anything.

Sources:
- Items - Create Item / Update Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/create-item
- SemanticModel definition: https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/semantic-model-definition
- Report definition: https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/report-definition
- Refresh Dataset In Group: https://learn.microsoft.com/rest/api/power-bi/datasets/refresh-dataset-in-group
- Execute Queries In Group: https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group
- Get Report In Group: https://learn.microsoft.com/rest/api/power-bi/reports/get-report-in-group

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json): the subscription, tenant, azureAccount, and the Fabric
workspace and lakehouse names (fabric.workspaceName and fabric.lakehouseName), or their ID overrides.

.PARAMETER WorkspaceId
Deploy into this workspace instead of the resolved one. The model still reads the resolved lakehouse.

.PARAMETER LakehouseId
The lakehouse the model reads, instead of the resolved one. It must be in the resolved workspace.

.PARAMETER FabricToken
A Fabric REST API token you already have, as a SecureString. Without it, the script uses the Azure CLI after the
subscription guard.

.PARAMETER PowerBIToken
A Power BI REST API token you already have, as a SecureString (audience https://analysis.windows.net/powerbi/api).

.PARAMETER CheckModelData
Run step 3 alone: evaluate every measure of the deployed model, without importing anything.

.PARAMETER SkipModel
Skip steps 1 to 3; the report binds to the deployed model, found by name.

.PARAMETER SkipRefresh
Skip step 2.

.PARAMETER SkipDataCheck
Skip step 3.

.PARAMETER SkipReport
Skip step 4.

.PARAMETER TimeoutSeconds
How long to wait for each long-running operation and for the refresh.

.PARAMETER RefreshRetryMinutes
How long to keep refreshing while Direct Lake can't see some of the lakehouse's tables yet (default 30; 0 turns it
off). In a new lakehouse, the tables the live-activity notebook created took about 20 minutes to reach Direct Lake.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.PARAMETER TreatManualAsError
Exit with code 2 when a check is Manual action required and none failed.

.EXAMPLE
./scripts/configure-powerbi.ps1 -WhatIf

.EXAMPLE
./scripts/configure-powerbi.ps1 -ConfigPath ./config/demo.config.json

.EXAMPLE
./scripts/configure-powerbi.ps1 -CheckModelData
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $WorkspaceId,

    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $LakehouseId,

    [securestring] $FabricToken,

    [securestring] $PowerBIToken,

    [switch] $CheckModelData,

    [switch] $SkipModel,

    [switch] $SkipRefresh,

    [switch] $SkipDataCheck,

    [switch] $SkipReport,

    [ValidateRange(30, 3600)]
    [int] $TimeoutSeconds = 600,

    [ValidateRange(0, 120)]
    [int] $RefreshRetryMinutes = 30,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/configure-powerbi.jsonl'),

    [switch] $TreatManualAsError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by deploy.ps1 or a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$placeholderId = '00000000-0000-0000-0000-000000000000'
$modelName = 'SM_DatabaseHub_History'
$reportName = 'RPT_DatabaseHub_History'
$resultsPath = $OutputPath
$manualIsError = [bool]$TreatManualAsError
$results = [System.Collections.Generic.List[object]]::new()
$skip = {
    param([string] $CheckId, [string] $Message)
    $results.Add((New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message $Message))
}
$finish = {
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

$config = $null
if (Test-Path -LiteralPath $ConfigPath) {
    $config = Get-DemoConfig -Path $ConfigPath
}
elseif (-not ($WorkspaceId -and $LakehouseId -and $FabricToken -and $PowerBIToken)) {
    throw "Configuration file not found: $ConfigPath. Create it from config/demo.config.example.json, or pass -WorkspaceId, -LakehouseId, -FabricToken, and -PowerBIToken."
}

# The definitions are built and validated from the files first, so a broken TMDL or PBIR folder stops the run before
# any request. The report's model ID is a placeholder until step 1 returns the real one, and the model is built again
# with the lakehouse once it's resolved; until then it's built with obviously fake IDs, which are never sent.
$modelCheck = Get-DemoFabricSemanticModelDefinition -WorkspaceId '11111111-1111-1111-1111-111111111111' -LakehouseId '22222222-2222-2222-2222-222222222222' -DisplayName $modelName
$reportCheck = Get-DemoFabricReportDefinition -SemanticModelId $placeholderId -DisplayName $reportName
Write-DemoLog -Message ('Semantic model {0}: {1} parts, {2} tables, {3} measures. Report {4}: {5} pages, {6} visuals.' -f $modelName, $modelCheck.Evidence.parts, $modelCheck.Evidence.tables, $modelCheck.Evidence.measures, $reportName, $reportCheck.Evidence.pages, $reportCheck.Evidence.visuals)

# The workspace and the lakehouse by name (Phase 26a, ADR 0021): the configuration holds names, and the IDs are
# resolved here (created when missing and fabric.createIfMissing is true), or taken from the ID overrides.
$resolveFabric = {
    param([securestring] $Token)
    $resolve = @{ Config = $config; Create = $true; TimeoutSeconds = $TimeoutSeconds; WhatIf = [bool]$WhatIfPreference; Confirm = $false }
    if ($null -ne $Token) {
        $resolve['Token'] = $Token
    }
    $resolution = Resolve-DemoFabricConfig @resolve
    $results.AddRange([object[]]@($resolution.Results))
    return $resolution.Config
}
$targets = {
    $fabric = if ($config -and $config['fabric']) { $config['fabric'] } else { @{} }
    $workspace = if ($WorkspaceId) { $WorkspaceId } else { [string]$fabric['workspaceId'] }
    [pscustomobject]@{
        Workspace          = $workspace
        LakehouseWorkspace = $(if ($fabric['workspaceId']) { [string]$fabric['workspaceId'] } else { $workspace })
        Lakehouse          = $(if ($LakehouseId) { $LakehouseId } else { [string]$fabric['lakehouseId'] })
    }
}

if ($WhatIfPreference) {
    # Dry run: no guard, no token, and no network call. Each function returns Not selected with its planned requests;
    # without ID overrides, the plan shows the all-zero placeholder for the workspace and the lakehouse.
    if ($config) {
        $config = & $resolveFabric $null
    }
    $target = & $targets
    $targetWorkspaceId = if ($target.Workspace -match $guidPattern) { $target.Workspace } else { $placeholderId }
    $model = if ($target.LakehouseWorkspace -match $guidPattern -and $target.Lakehouse -match $guidPattern) {
        Get-DemoFabricSemanticModelDefinition -WorkspaceId $target.LakehouseWorkspace -LakehouseId $target.Lakehouse -DisplayName $modelName
    }
    else {
        $modelCheck
    }
    if (-not $CheckModelData -and -not $SkipModel) {
        $results.Add((Import-DemoFabricItem -WorkspaceId $targetWorkspaceId -Item $model -WhatIf))
        if (-not $SkipRefresh) {
            $results.Add((Invoke-DemoSemanticModelRefresh -WorkspaceId $targetWorkspaceId -SemanticModelId $placeholderId -WhatIf))
        }
    }
    if ($CheckModelData -or (-not $SkipModel -and -not $SkipDataCheck)) {
        $results.AddRange([object[]]@(Test-DemoSemanticModelData -WorkspaceId $targetWorkspaceId -SemanticModelId $placeholderId -WhatIf))
    }
    if (-not $CheckModelData -and -not $SkipReport) {
        $results.Add((Import-DemoFabricItem -WorkspaceId $targetWorkspaceId -Item $reportCheck -WhatIf))
        $results.AddRange([object[]]@(Test-DemoPowerBIReport -WorkspaceId $targetWorkspaceId -ReportId $placeholderId -SemanticModelId $placeholderId -ExpectedPage $reportCheck.PageNames -WhatIf))
    }
    & $finish
}

# The subscription guard, before any token request or write. A failure stops the run with nothing sent.
if ($null -eq $FabricToken -or $null -eq $PowerBIToken) {
    if (-not $config) {
        throw 'Pass -FabricToken and -PowerBIToken, or create the configuration so the script can use the signed-in Azure CLI.'
    }
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message `
                    -Remediation "Sign in once with 'az login --tenant <tenantId>' as the configured azureAccount, then run the script again. Nothing was changed."))
        & $skip 'FABRIC.SEMANTICMODEL.DEPLOY' 'The subscription guard failed, so no token was requested and nothing was deployed.'
        & $finish
    }
    if ($null -eq $FabricToken) {
        $FabricToken = Get-DemoFabricToken -SubscriptionId $config['subscriptionId']
    }
    if ($null -eq $PowerBIToken) {
        $PowerBIToken = Get-DemoPowerBIToken -SubscriptionId $config['subscriptionId']
    }
}

if ($config) {
    $config = & $resolveFabric $FabricToken
}
$target = & $targets
$targetWorkspaceId = $target.Workspace
$lakehouseWorkspaceId = $target.LakehouseWorkspace
$targetLakehouseId = $target.Lakehouse
if ($targetWorkspaceId -notmatch $guidPattern -or $targetLakehouseId -notmatch $guidPattern -or $lakehouseWorkspaceId -notmatch $guidPattern) {
    & $skip 'FABRIC.SEMANTICMODEL.DEPLOY' 'The Fabric workspace and lakehouse aren''t resolved (FABRIC.RESOLVE.* says why) or passed, so nothing was deployed.'
    & $finish
}
$model = Get-DemoFabricSemanticModelDefinition -WorkspaceId $lakehouseWorkspaceId -LakehouseId $targetLakehouseId -DisplayName $modelName

#region Step 1-3: semantic model, refresh, and data
$modelId = ''
$modelReady = $false
if ($CheckModelData -or $SkipModel) {
    $lookup = Find-DemoSemanticModel -WorkspaceId $targetWorkspaceId -Name $modelName -Token $PowerBIToken
    $modelId = $lookup.Id
    $modelReady = $modelId -match $guidPattern
    if ($lookup.StatusCode -ne 200) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.DATA' -Area 'fabric' -Target 'fabric' -Status 'Fail' `
                    -Message ('The workspace''s semantic models couldn''t be listed, so {0} wasn''t found: {1}' -f $modelName, $lookup.Error) `
                    -Remediation 'Check that the signed-in account has a role in the workspace, then run the script again.' -DocUrl 'https://learn.microsoft.com/rest/api/power-bi/datasets/get-datasets-in-group'))
    }
    elseif (-not $modelReady) {
        & $skip 'FABRIC.SEMANTICMODEL.DATA' ('{0} semantic models named {1} are in the workspace, not one; run the script without -CheckModelData or -SkipModel to deploy it.' -f $lookup.Count, $modelName)
    }
}
elseif ($PSCmdlet.ShouldProcess("semantic model '$modelName' in Fabric workspace $targetWorkspaceId", 'Create or update through the Fabric REST API')) {
    Write-DemoLog -Message ('Importing semantic model {0} ({1} bytes, SHA-256 {2}).' -f $modelName, $model.SizeBytes, $model.Sha256.Substring(0, 12))
    $imported = @(Import-DemoFabricItem -WorkspaceId $targetWorkspaceId -Item $model -Token $FabricToken -TimeoutSeconds $TimeoutSeconds -Confirm:$false `
            -Description 'Database Hub demo history: Direct Lake on OneLake over LH_DatabaseHub, deployed by scripts/configure-powerbi.ps1.')
    $results.AddRange([object[]]$imported)
    $modelResult = $imported | Select-Object -First 1
    if ($modelResult.status -eq 'Pass') {
        $modelId = [string]$modelResult.evidence['itemId']
        $modelReady = $modelId -match $guidPattern
    }
    if ($modelReady -and -not $SkipRefresh) {
        $refresh = Invoke-DemoSemanticModelRefresh -WorkspaceId $targetWorkspaceId -SemanticModelId $modelId -Token $PowerBIToken -TimeoutSeconds $TimeoutSeconds -TableRetryMinutes $RefreshRetryMinutes -Confirm:$false
        $results.Add($refresh)
        $modelReady = $refresh.status -eq 'Pass'
    }
    elseif ($SkipRefresh) {
        & $skip 'FABRIC.SEMANTICMODEL.REFRESH' 'Skipped (-SkipRefresh).'
    }
}
else {
    & $skip 'FABRIC.SEMANTICMODEL.DEPLOY' 'Skipped at the confirmation prompt.'
}

if ($CheckModelData -or (-not $SkipModel -and -not $SkipDataCheck)) {
    if ($modelReady) {
        $results.AddRange([object[]]@(Test-DemoSemanticModelData -WorkspaceId $targetWorkspaceId -SemanticModelId $modelId -Token $PowerBIToken -Confirm:$false))
    }
    elseif (-not $CheckModelData) {
        & $skip 'FABRIC.SEMANTICMODEL.DATA' 'The import or the refresh of the semantic model didn''t pass, so its measures weren''t evaluated.'
    }
}
if ($CheckModelData) {
    & $finish
}
#endregion Step 1-3: semantic model, refresh, and data

#region Step 4: report
if ($SkipReport) {
    Write-DemoLog -Message 'Skipping the report (-SkipReport).'
}
else {
    if ($modelId -notmatch $guidPattern) {
        & $skip 'FABRIC.REPORT.IMPORT' ('The report needs the semantic model {0}, which isn''t deployed, so it wasn''t imported.' -f $modelName)
    }
    elseif ($PSCmdlet.ShouldProcess("report '$reportName' in Fabric workspace $targetWorkspaceId", 'Create or update through the Fabric REST API')) {
        $report = Get-DemoFabricReportDefinition -SemanticModelId $modelId -DisplayName $reportName
        Write-DemoLog -Message ('Importing report {0} ({1} bytes, SHA-256 {2}).' -f $reportName, $report.SizeBytes, $report.Sha256.Substring(0, 12))
        $imported = @(Import-DemoFabricItem -WorkspaceId $targetWorkspaceId -Item $report -Token $FabricToken -TimeoutSeconds $TimeoutSeconds -Confirm:$false `
                -Description 'Database Hub demo history report (four pages), deployed by scripts/configure-powerbi.ps1.')
        $results.AddRange([object[]]$imported)
        $reportResult = $imported | Select-Object -First 1
        if ($reportResult.status -eq 'Pass') {
            $reportId = [string]$reportResult.evidence['itemId']
            if ($reportId -match $guidPattern) {
                $results.AddRange([object[]]@(Test-DemoPowerBIReport -WorkspaceId $targetWorkspaceId -ReportId $reportId -SemanticModelId $modelId -ExpectedPage $report.PageNames -Token $PowerBIToken -Confirm:$false))
            }
        }
    }
    else {
        & $skip 'FABRIC.REPORT.IMPORT' 'Skipped at the confirmation prompt.'
    }
}
#endregion Step 4: report

& $finish
