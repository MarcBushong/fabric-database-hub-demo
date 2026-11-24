#Requires -Version 7.4
<#
.SYNOPSIS
Checks Database Hub readiness (Phase 9), then imports or updates the two Fabric notebooks (Phase 12).

.DESCRIPTION
A thin sequence over DbHubDemo module functions.

Step 0, the Fabric workspace and lakehouse by name (Phase 26a, ADR 0021). The repo stores no Fabric ID:
Resolve-DemoFabricConfig finds the workspace fabric.workspaceName and the lakehouse fabric.lakehouseName through
Fabric REST, creates them when they're missing and fabric.createIfMissing is true (the workspace on the Active
capacity fabric.capacityName, the lakehouse with lakehouse schemas), and every later step uses their IDs
(FABRIC.RESOLVE.*). fabric.workspaceId and fabric.lakehouseId, when set, are overrides used as they are. It runs
after the subscription guard, and -WhatIf creates nothing.

Step 1, the Database Hub checklist (Invoke-DemoHubReadiness; -SkipHubChecks skips it). Database Hub (generally
available since 2026-11-17) has no public API or ARM resource, so the checklist uses documented interfaces only and
never calls a Hub route
(docs/architecture.md, "Database Hub integration"):
- The subscription guard first: it stops the checklist with Fail unless the Azure CLI context matches the
  configured subscription and tenant and a token is available without interaction. It never signs in.
- P4: the Fabric tenant setting "Users can access the Database hub (preview)", through the Fabric admin API on
  every run (Phase 28): Pass when enabled; Manual action required when it's disabled, or when it couldn't be read
  (not a Fabric administrator, no token), which is a reminder to confirm it, worded as such.
- P5: Contributor or higher on the resolved workspace and an F or Trial capacity, through Fabric REST with your
  Fabric token.
- P11 (optional): Power BI viewer licensing (PREFLIGHT.FABRIC.VIEWERLICENSE), assumed since 2026-11-14: Not selected,
  with the rule (Pro, PPU, or a trial for viewers of the report and the app below F64), and nothing read.
- Estate: every selected target in Azure Resource Graph, the Hub's inventory source (HUB.ESTATE.*).
- Telemetry: rows, the newest sample, and the lag per target from the telemetry REST endpoint (TELEMETRY.T1,
  TELEMETRY.T2, TELEMETRY.T3). Telemetry takes 3 to 15 minutes to appear; use -WaitMinutes.
- With -T3ReadinessGate: the warm-up gate for a recreated T3 (T3.READINESS.*).
- Presenter access (P8): role assignments only when assignRoles is true in the configuration (ADR 0008);
  otherwise Manual action required with the commands an administrator runs.
The checklist only reads, except for those role assignments, so it also runs under -WhatIf.

Step 2, the notebook import (Phase 12; -SkipNotebookImport skips it). For each notebook in fabric/notebooks
(NB_DatabaseHub_Deployment and NB_DatabaseHub_LiveActivity), Get-DemoFabricNotebookDefinition validates the
file and Import-DemoFabricNotebook creates the notebook or overrides its definition through Fabric REST, so
re-runs converge. The uploaded copy is bound to the resolved lakehouse (ADR 0021); without a resolved lakehouse,
nothing is imported. NB_DatabaseHub_Deployment's GITHUB_REPOSITORY and GITHUB_ENVIRONMENT come from github.repository
and github.environment, unless the repository is still the example configuration's placeholder. With -NewNotebooksOnly,
a notebook that isn't in the workspace yet is imported without asking and one that is stays as it is (Not selected).
With -KeepEditedNotebooks, which deploy.ps1 passes while fabric.importNotebooks is false (follow-ups decision 2a,
2026-11-23), a missing notebook is created too, and one that's there is read first (Items - Get Item Definition, as
ipynb): an earlier version of the demo's, which nobody edited, is updated, and an edited one is kept, with the command
that replaces it (the -KeepEdited mode of Import-DemoFabricNotebook).
The step runs only when the module has those functions; otherwise FABRIC.NOTEBOOKS.IMPORT is
Manual action required. Without a workspace (resolved, or -WorkspaceId), it's Not selected. After a
failed subscription guard, it runs only with -FabricToken or -WhatIf. Running this script without
-NewNotebooksOnly or -KeepEditedNotebooks is the explicit request to create or update the notebooks, edited or not;
-Notebook names one. -WhatIf validates the
notebooks and shows the planned requests; without the checklist or a token, it sends no request at all.

Step 3, the Real-Time Dashboard (Phase 18; only with -ImportDashboard). Get-DemoFabricDashboardDefinition
validates fabric/realtime/RealTimeDashboard.json and fills in the demo resource group, and Import-DemoFabricItem
creates the KQLDashboard item or overrides its definition, then reads the definition back with Get Item Definition
(FABRIC.IMPORT.* and FABRIC.READBACK.*). The dashboard's data source is the documented SQL ADX proxy, queried with
each viewer's own identity; the definition holds no credential and no ID. -WhatIf validates it and shows the plan.
After a passing import and read-back, the presenters in presenterObjectIds get the Viewer role on the demo workspace
when they have no role there yet, which shares the dashboard with them (Grant-DemoPresenterWorkspaceAccess,
FABRIC.PRESENTER.VIEWER, 2026-11-18): Fabric's REST API has no operation to share one item.

Step 4, the dashboard's data (Phase 18; after a passing import and read-back, or alone with -CheckDashboardData).
Test-DemoRealTimeDashboardData runs each tile's KQL, read-only, against the telemetry endpoint for the last 24
hours, with a Kusto token for the configured subscription's account, after the subscription guard
(FABRIC.DASHBOARD.TILE.* and FABRIC.DASHBOARD.DATA): Pass when a tile gets rows, Warning when it's empty only
because there was nothing to show (for example, the VMs are deallocated right now), and Fail when it doesn't show
data that exists. It needs no workspace and changes nothing; -SkipDashboardDataCheck skips it after an import.
The same function is the deploy step for deploy.ps1's Fabric track.

The token belongs to the operator: pass -FabricToken (a SecureString you already have), or the script gets
one from the signed-in Azure CLI through Invoke-DemoAz, after the subscription guard. Tokens are registered as
secrets the moment they're issued and are never printed or saved. Results are printed, written as JSON lines
to -OutputPath, and turned into the exit code (ADR 0012): 0 without a Fail, 1 with a Fail, 2 with
-TreatManualAsError and a Manual action required.

Sources:
- Workspaces - List Workspaces: https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces
- Workspaces - Create Workspace: https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace
- Capacities - List Capacities: https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities
- Items - List Lakehouses and Create Lakehouse: https://learn.microsoft.com/rest/api/fabric/lakehouse/items/create-lakehouse
- Telemetry REST endpoint: https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
- Database Hub tenant setting: https://learn.microsoft.com/fabric/database/hub/monitor-sql
- Tenants - List Tenant Settings: https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings
- Workspaces - Get Workspace: https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-workspace
- Items - Create Item: https://learn.microsoft.com/rest/api/fabric/core/items/create-item
- Items - Update Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/update-item-definition
- Notebook definition: https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/notebook-definition
- KQL dashboard definition: https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/kql-dashboard-definition
- Items - Get Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition
- Long-running operations: https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json). It supplies the subscription and tenant, the workspace and
lakehouse names (fabric.workspaceName, fabric.lakehouseName), and the capacity to create the workspace on
(fabric.capacityName). Optional only when -WorkspaceId and -FabricToken are both given; the checklist is then
skipped, because it needs the subscription and tenant.

.PARAMETER Target
Targets for the Estate, telemetry, and gate checks. Others are reported as Not selected. While T2 waits for
the PaygWizard step, its telemetry check reports that manual step instead of a failure.

.PARAMETER FabricAdmin
Accepted for compatibility. Since Phase 28, P4 is read through the Fabric admin API (Tenants - List Tenant Settings) on every
run; for a caller who isn't a Fabric administrator it's a reminder to confirm the setting, never a blocker.

.PARAMETER WaitMinutes
How long the telemetry check and the T3 gate keep polling for fresh rows. 0 checks once; 15 covers the
documented delay after monitoring is enabled.

.PARAMETER LookbackMinutes
How far back the telemetry check looks for rows (at most 7 days, the retention).

.PARAMETER FreshMinutes
The oldest the newest telemetry sample can be for Pass.

.PARAMETER Detail
Add the tables with rows, wait seconds per category, and the blocking and throughput counters to the
telemetry evidence.

.PARAMETER T3ReadinessGate
Also run the T3 readiness gate (Resource Graph, extended property, telemetry, measured lag).

.PARAMETER T3PerformanceMonitoringCheck
For the gate: a script block that receives the configuration and returns whether T3's
MS_EnablePerformanceMonitoringPreview extended property is set (Phase 8 provides it). Without it, that part
of the gate is Manual action required.

.PARAMETER SkipFabric
Skip P4 and P5.

.PARAMETER SkipTelemetry
Skip the telemetry check.

.PARAMETER DeploymentId
The deploymentId in T3's server name. Read from the resource group's deploymentId tag when omitted.

.PARAMETER SkipHubChecks
Skip step 1, the Database Hub checklist, and only import the notebooks.

.PARAMETER Notebook
Which notebooks to import. Defaults to both.

.PARAMETER WorkspaceId
The workspace to import the notebooks into. Defaults to the resolved workspace; P5 and the lakehouse binding
always use the resolved one.

.PARAMETER FabricToken
A Fabric REST API token you already have, as a SecureString, for P4, P5, and the import. Without it, the
script uses the Azure CLI.

.PARAMETER TimeoutSeconds
How long to wait for a long-running Fabric operation.

.PARAMETER SkipNotebookImport
Skip step 2, the notebook import, and only run the checklist.

.PARAMETER NewNotebooksOnly
Step 2 imports only the notebooks that aren't in the workspace yet, and leaves the ones that are as they are. deploy.ps1
passed it while fabric.importNotebooks was false, from Phase 26a until -KeepEditedNotebooks (2026-11-23).

.PARAMETER KeepEditedNotebooks
Step 2 creates a notebook that isn't in the workspace yet, updates one that's an earlier version of the demo's, which
nobody edited (or this version bound to another workspace, lakehouse, or GitHub path), and keeps one someone edited.
deploy.ps1's Fabric track passes it while fabric.importNotebooks is false, so an update is one click again, and an edited
notebook stays as it is (follow-ups decision 2a, 2026-11-23). Not with -NewNotebooksOnly.

.PARAMETER ImportDashboard
Also run step 3: import or update the Real-Time Dashboard (fabric/realtime) in the workspace and read its
definition back, then step 4, the tile data check. Off by default, because it changes the workspace: run it with
the owner's go-ahead.

.PARAMETER CheckDashboardData
Run step 4 alone: check that every tile of the Real-Time Dashboard gets data, without importing anything.

.PARAMETER SkipDashboardDataCheck
With -ImportDashboard, skip step 4.

.PARAMETER RunLiveActivity
Also run step 5: NB_DatabaseHub_LiveActivity on demand with SAVE_RESULTS true (Invoke-DemoFabricNotebookRun), so
the lakehouse tables the history report reads (incident windows, telemetry snapshots, validation results) are
current. It runs analyze-only, scoped to the demo's resource group
(RESOURCE_GROUP, rg-<prefix>-<environment>). It waits up to -TimeoutSeconds (at least 5 minutes) for the job. After a
run that completed, the history's kept values are worked out through Fabric's Livy API with this checkout's
fabric/history/kept_value.py (F35; FABRIC.KEPTVALUE, Invoke-DemoHistoryKeptValue, never a Fail). Step 5
also runs once by itself when step 2 created the notebook, or bound it to a lakehouse that step 0 created, so a new
lakehouse gets the tables; that first run waits up to -HistoryRunWaitMinutes, since a busy capacity can keep it queued
for longer than 10 minutes (#68). With -RunLiveActivity and the Azure CLI's sign-in (not -FabricToken), the run also
takes the Incident RCA's evidence (2026-11-20, ADR 0031): the runners' export on the VMs that run, with what an earlier
save didn't take, staged as RCA_EVIDENCE_FILE (FABRIC.RCA.EXPORT, FABRIC.RCA.CAPTURE.<target>, FABRIC.RCA.PENDING).
Its sidecars (2026-11-23, Query Store's evidence) follow it: the acknowledgements an earlier stop deferred go to the
VMs first, then the sidecars they offer are fetched, staged as RCA_SIDECAR_FILE, taken by at most 3 runs in all (the
later ones RCA_ONLY, within 15 minutes), and acknowledged on the VMs at once (FABRIC.RCA.SIDECAR); run it again while
that line says sidecars wait.

.PARAMETER HistoryRunWaitMinutes
How long the first history run (step 5 by itself, above) is waited for while it's queued on the capacity or runs
(default 45; at least -TimeoutSeconds). A run still queued or running then keeps running, and its record says so with
its location (jobLocation), which deploy.ps1 follows.

.PARAMETER ProgressPath
The status page's model (deploy-progress.json), which deploy.ps1 passes: while the first history run is queued or runs,
its Fabric row says so, with the minutes so far and -HistoryRunWaitMinutes.

.PARAMETER LiveActivityWindowMinutes
With -RunLiveActivity: the notebook's WINDOW_MINUTES and TELEMETRY_LOOKBACK_MINUTES (default 1440, one day).

.PARAMETER PostgresMetricsPath
With -RunLiveActivity: a file that stop-demo.ps1 -SaveHistory kept in out/history-pending when the session's history
couldn't be saved (STOP.T4.HISTORY.PENDING, for example while the Fabric capacity was paused): T4's and its deleted read
replica's metrics from that session, which the run adds to the history as the notebook's POSTGRES_METRICS (ADR 0025).
After a run that passed, the file moves to out/history-pending/saved. Without it, the run sends T4's and a running
replica's metrics from Azure Monitor over the window, as deploy.ps1's history snapshot does. T5's (Azure Cosmos DB,
2026-11-18) always come from Azure Monitor over the window, as COSMOS_METRICS, when T5 is deployed.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.PARAMETER TreatManualAsError
Exit with code 2 when a check is Manual action required and none failed.

.EXAMPLE
./scripts/configure-fabric.ps1 -ConfigPath ./config/demo.config.json -WaitMinutes 15 -SkipNotebookImport

.EXAMPLE
./scripts/configure-fabric.ps1 -FabricAdmin -Detail -WhatIf

.EXAMPLE
./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity -WorkspaceId 00000000-0000-0000-0000-000000000000 -FabricToken $token

.EXAMPLE
./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -ImportDashboard -WhatIf

.EXAMPLE
./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -CheckDashboardData

.EXAMPLE
./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity

.EXAMPLE
./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity -PostgresMetricsPath ./out/history-pending/postgres-metrics-rg-dbhub-demo-20261113T190000Z.json
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidateSet('T1', 'T2', 'T3')]
    [string[]] $Target = @('T1', 'T2', 'T3'),

    [switch] $FabricAdmin,

    [ValidateRange(0, 120)]
    [int] $WaitMinutes = 0,

    [ValidateRange(1, 10080)]
    [int] $LookbackMinutes = 60,

    [ValidateRange(1, 1440)]
    [int] $FreshMinutes = 15,

    [switch] $Detail,

    [switch] $T3ReadinessGate,

    [scriptblock] $T3PerformanceMonitoringCheck,

    [switch] $SkipFabric,

    [switch] $SkipTelemetry,

    [string] $DeploymentId = '',

    [switch] $SkipHubChecks,

    [ValidateSet('NB_DatabaseHub_Deployment', 'NB_DatabaseHub_LiveActivity')]
    [string[]] $Notebook = @('NB_DatabaseHub_Deployment', 'NB_DatabaseHub_LiveActivity'),

    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $WorkspaceId,

    [securestring] $FabricToken,

    [ValidateRange(30, 3600)]
    [int] $TimeoutSeconds = 600,

    [switch] $SkipNotebookImport,

    [switch] $NewNotebooksOnly,

    [switch] $KeepEditedNotebooks,

    [switch] $ImportDashboard,

    [switch] $CheckDashboardData,

    [switch] $SkipDashboardDataCheck,

    [switch] $RunLiveActivity,

    [ValidateRange(5, 120)]
    [int] $HistoryRunWaitMinutes = 45,

    [AllowEmptyString()]
    [string] $ProgressPath = '',

    [ValidateRange(15, 10080)]
    [int] $LiveActivityWindowMinutes = 1440,

    [string] $PostgresMetricsPath = '',

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/configure-fabric.jsonl'),

    [switch] $TreatManualAsError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# This checkout's DbHubDemo, loaded again on every run, so a session that ran an earlier checkout's script doesn't keep
# that code (live finding, 2026-11-06). Not when the repository's own code runs this script (a DbHubDemo function,
# another script, or a test): it loaded the module already, and the module's state stays, such as the subscription
# guard's validated context, the redaction's registered values, or a test's mocks.
$entryRepoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..')).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$entryNested = $false
foreach ($entryFrame in @(Get-PSCallStack | Select-Object -Skip 1)) {
    $entryNested = $entryNested -or [bool]($entryFrame.ScriptName -and $entryFrame.ScriptName.StartsWith($entryRepoRoot, [System.StringComparison]::OrdinalIgnoreCase))
}
$module = Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1') -Force:(-not $entryNested) -PassThru
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath
$PostgresMetricsPath = Resolve-DemoUserPath -Path $PostgresMetricsPath
$ProgressPath = Resolve-DemoUserPath -Path $ProgressPath
if ($NewNotebooksOnly -and $KeepEditedNotebooks) {
    throw 'Pass -NewNotebooksOnly or -KeepEditedNotebooks, not both: the first leaves every notebook that''s there as it is.'
}
if ($PostgresMetricsPath) {
    if (-not $RunLiveActivity) {
        throw '-PostgresMetricsPath goes with -RunLiveActivity: the notebook run adds the file''s metrics to the history.'
    }
    if (-not (Test-Path -LiteralPath $PostgresMetricsPath -PathType Leaf)) {
        throw ('-PostgresMetricsPath: the file {0} doesn''t exist. stop-demo.ps1 -SaveHistory names it (STOP.T4.HISTORY.PENDING), in out/history-pending.' -f $PostgresMetricsPath)
    }
}

$config = $null
if (Test-Path -LiteralPath $ConfigPath) {
    $config = Get-DemoConfig -Path $ConfigPath
}
elseif (-not ($WorkspaceId -and $FabricToken)) {
    throw "Configuration file not found: $ConfigPath. Create it from config/demo.config.example.json, or pass both -WorkspaceId and -FabricToken."
}
$results = [System.Collections.Generic.List[object]]::new()

# Step 0 (Phase 26a, ADR 0021): the workspace and the lakehouse by name. The repo stores no Fabric ID, so the script
# resolves them first, and creates them when they're missing and fabric.createIfMissing is true; every later step
# reads fabric.workspaceId and fabric.lakehouseId from the resolved copy. The token comes from -FabricToken, or from
# the Azure CLI after the subscription guard; a dry run reads only with a token and creates nothing. It runs only for
# the steps that use the workspace (the checklist's P5, the imports, the notebook run), and looks up the lakehouse
# only for the notebooks; the tile check alone needs neither.
$sessionToken = $FabricToken
$needsWorkspace = (-not $SkipHubChecks) -or (-not $SkipNotebookImport) -or $ImportDashboard -or $RunLiveActivity
$needsLakehouse = (-not $SkipNotebookImport) -or $RunLiveActivity
if ($config -and $needsWorkspace) {
    $guardResult = $null
    if ($null -eq $sessionToken -and (-not $WhatIfPreference -or -not $SkipHubChecks)) {
        try {
            $guardResult = Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])
        }
        catch {
            $guardResult = New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message
        }
        if ($guardResult.status -ne 'Fail') {
            try {
                $sessionToken = Get-DemoFabricToken -SubscriptionId $config['subscriptionId']
            }
            catch {
                Write-DemoLog -Level Warning -Message ('No Fabric token for the name lookup: {0}' -f $_.Exception.Message)
            }
        }
    }
    if ($null -ne $guardResult -and $guardResult.status -eq 'Fail') {
        # A failed guard stops every step that needs the Azure CLI; the checklist would only report it again.
        $results.Add($guardResult)
    }
    else {
        # Creating is for the steps that write to Fabric; a run that only checks (the checklist, the tile data) reads.
        $writesFabric = (-not $SkipNotebookImport) -or $ImportDashboard -or $RunLiveActivity
        $resolve = @{ Config = $config; Create = $writesFabric; SkipLakehouse = (-not $needsLakehouse); TimeoutSeconds = $TimeoutSeconds; WhatIf = [bool]$WhatIfPreference }
        if ($null -ne $sessionToken) {
            $resolve['Token'] = $sessionToken
        }
        $resolve['Confirm'] = if ($PSBoundParameters.ContainsKey('Confirm')) { $PSBoundParameters['Confirm'] } else { $false }
        $resolution = Resolve-DemoFabricConfig @resolve
        $results.AddRange([object[]]@($resolution.Results))
        $config = $resolution.Config
    }
}

# Step 1: the Database Hub checklist (Phase 9).
$stepZeroGuardFailed = @($results | Where-Object { $_.checkId -eq 'PREFLIGHT.GUARD.CONTEXT' -and $_.status -eq 'Fail' }).Count -gt 0
if ($SkipHubChecks) {
    Write-DemoLog -Message 'Skipping the Database Hub checklist (-SkipHubChecks).'
}
elseif (-not $config) {
    Write-DemoLog -Level Warning -Message 'No configuration file, so the Database Hub checklist was skipped: it needs the configured subscription and tenant.'
}
elseif ($stepZeroGuardFailed) {
    Write-DemoLog -Level Warning -Message 'The subscription guard failed, so the Database Hub checklist was skipped.'
}
else {
    $readiness = @{
        Config                       = $config
        Target                       = $Target
        FabricAdmin                  = $FabricAdmin
        SkipFabric                   = $SkipFabric
        SkipTelemetry                = $SkipTelemetry
        Detail                       = $Detail
        T3ReadinessGate              = $T3ReadinessGate
        T3PerformanceMonitoringCheck = $T3PerformanceMonitoringCheck
        WaitMinutes                  = $WaitMinutes
        LookbackMinutes              = $LookbackMinutes
        FreshMinutes                 = $FreshMinutes
        DeploymentId                 = $DeploymentId
        WhatIf                       = [bool]$WhatIfPreference
    }
    if ($null -ne $sessionToken) {
        $readiness['FabricToken'] = $sessionToken
    }
    if ($PSBoundParameters.ContainsKey('Confirm')) {
        $readiness['Confirm'] = $PSBoundParameters['Confirm']
    }
    $results.AddRange([object[]]@(Invoke-DemoHubReadiness @readiness))
}
$guardFailed = @($results | Where-Object { $_.checkId -eq 'PREFLIGHT.GUARD.CONTEXT' -and $_.status -eq 'Fail' }).Count -gt 0

#region Notebook import (Phase 12)
# Step 2, and the merge point for Phase 12's import loop. It runs only when this build of the module has the
# Phase 12 functions (Get-Command), so the script works before and after the merge. The loop is Phase 12's,
# except: $notebookTarget (not $target, which would overwrite -Target); $importWorkspaceId (an empty value would
# trip -WorkspaceId's validation); Not selected instead of a throw without a workspace, so the checklist's
# results are still written; and no import after a failed subscription guard unless -FabricToken or -WhatIf
# means the Azure CLI isn't needed.
$importCommands = @('Get-DemoFabricNotebookDefinition', 'Import-DemoFabricNotebook', 'Get-DemoFabricToken')
$missingCommands = @($importCommands | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
$fabric = if ($config -and $config['fabric']) { $config['fabric'] } else { @{} }
$importWorkspaceId = if ($WorkspaceId) { $WorkspaceId } else { [string]$fabric['workspaceId'] }
$lakehouseBound = [bool]($fabric['lakehouseId'] -and $fabric['workspaceId'])
$resolved = (Test-Path -Path 'variable:resolution') -and $null -ne $resolution
$newLakehouse = $resolved -and [bool]$resolution.LakehouseCreated
# -NewNotebooksOnly: a notebook that isn't in the workspace yet, as in a workspace or lakehouse that step 0 just created,
# is imported without asking; one that is stays as it is. -KeepEditedNotebooks (deploy.ps1 while fabric.importNotebooks is
# false, since 2026-11-23): a missing one is created too, and one that's there is updated only when nobody edited it.
$createOnly = $NewNotebooksOnly -and -not $SkipNotebookImport
$keepEdited = $KeepEditedNotebooks -and -not $SkipNotebookImport
$importNote = if ($createOnly) { 'Only a missing notebook is imported (-NewNotebooksOnly): ./scripts/configure-fabric.ps1 without it updates one that exists.' } else { '' }
if ($SkipNotebookImport) {
    Write-DemoLog -Message 'Skipping the notebook import (-SkipNotebookImport).'
}
elseif ($missingCommands.Count -gt 0) {
    $results.Add((New-DemoResult -CheckId 'FABRIC.NOTEBOOKS.IMPORT' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' `
                -Message ('This build of the DbHubDemo module doesn''t include the notebook import (Phase 12: {0}), so the notebooks weren''t imported.' -f ($missingCommands -join ', ')) `
                -Remediation 'Import fabric/notebooks/*.ipynb into the workspace by hand: in the workspace, select Import, then Notebook, then From this computer.' `
                -DocUrl 'https://learn.microsoft.com/rest/api/fabric/core/items/create-item'))
}
elseif ($importWorkspaceId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    $results.Add((New-DemoResult -CheckId 'FABRIC.NOTEBOOKS.IMPORT' -Area 'fabric' -Target 'fabric' -Status 'Not selected' `
                -Message 'The Fabric workspace isn''t resolved (FABRIC.RESOLVE.WORKSPACE says why) or passed (-WorkspaceId), so the notebooks weren''t imported.'))
}
elseif ($config -and -not $lakehouseBound -and -not $WhatIfPreference) {
    $results.Add((New-DemoResult -CheckId 'FABRIC.NOTEBOOKS.IMPORT' -Area 'fabric' -Target 'fabric' -Status 'Not selected' `
                -Message 'The lakehouse isn''t resolved (FABRIC.RESOLVE.LAKEHOUSE says why), so the notebooks weren''t imported: they save their results to it.'))
}
elseif ($guardFailed -and $null -eq $FabricToken -and -not $WhatIfPreference) {
    Write-DemoLog -Level Warning -Message 'The notebooks weren''t imported: the import needs an Azure CLI token, and the subscription guard failed.'
}
else {
    if ($config -and -not $fabric['importNotebooks'] -and -not $createOnly -and -not $keepEdited) {
        Write-DemoLog -Message 'fabric.importNotebooks is false, so deploy.ps1 keeps a notebook that someone edited. Running this script is an explicit request, so it creates or updates the notebooks, edited or not.'
    }

    # The lakehouse lives in the configured workspace, even when -WorkspaceId imports the notebooks somewhere else.
    # The repo's notebooks hold no Fabric IDs (ADR 0021): the uploaded copies get the resolved ones.
    $binding = @{}
    if ($lakehouseBound) {
        $binding = @{
            LakehouseId          = [string]$fabric['lakehouseId']
            LakehouseName        = [string]$fabric['lakehouseName']
            LakehouseWorkspaceId = [string]$fabric['workspaceId']
        }
    }
    # The GitHub path (P7, P9): the uploaded copies point at github.repository and github.environment, unless the
    # repository is still the example configuration's placeholder; then the notebooks keep their defaults.
    $gitHub = if ($config -and $config['github']) { $config['github'] } else { @{} }
    $exampleConfigPath = Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.example.json'
    $exampleConfig = if (Test-Path -LiteralPath $exampleConfigPath) { Get-Content -LiteralPath $exampleConfigPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    $placeholderRepository = if ($exampleConfig['github']) { [string]$exampleConfig['github']['repository'] } else { '' }
    if ($gitHub['repository'] -and [string]$gitHub['repository'] -ne $placeholderRepository) {
        $binding['GitHubRepository'] = [string]$gitHub['repository']
        if ($gitHub['environment']) {
            $binding['GitHubEnvironment'] = [string]$gitHub['environment']
        }
    }
    $definitions = foreach ($name in $Notebook) {
        Get-DemoFabricNotebookDefinition -Path (Join-Path -Path $PSScriptRoot -ChildPath "../fabric/notebooks/$name.ipynb") @binding
    }

    $token = $sessionToken
    $importAction = if ($createOnly) { 'Create through the Fabric REST API when it''s missing' } elseif ($keepEdited) { 'Create through the Fabric REST API when it''s missing, or update it when nobody edited it' } else { 'Create or update through the Fabric REST API' }
    # Only a create-only import passes the Phase 26a parameters, and only deploy.ps1's keeps an edited notebook (2026-11-23),
    # so the call stays the same as before otherwise.
    $importMode = if ($createOnly) { @{ CreateOnly = $true; Note = $importNote } } elseif ($keepEdited) { @{ KeepEdited = $true } } else { @{} }
    foreach ($definition in $definitions) {
        $notebookTarget = "notebook '{0}' in Fabric workspace {1}" -f $definition.DisplayName, $importWorkspaceId
        if ($WhatIfPreference) {
            # Dry run: no token and no network call. The module function prints the "What if" line and the plan.
            $results.Add((Import-DemoFabricNotebook -WorkspaceId $importWorkspaceId -Notebook $definition @importMode -WhatIf))
        }
        elseif ($PSCmdlet.ShouldProcess($notebookTarget, $importAction)) {
            if ($null -eq $token) {
                if (-not $config) {
                    throw 'Pass -FabricToken, or create the configuration so the script can use the signed-in Azure CLI.'
                }
                $null = Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])
                $token = Get-DemoFabricToken -SubscriptionId $config['subscriptionId']
            }
            Write-DemoLog -Message ('Importing {0} ({1} bytes, SHA-256 {2}).' -f $notebookTarget, $definition.SizeBytes, $definition.Sha256.Substring(0, 12))
            $results.Add((Import-DemoFabricNotebook -WorkspaceId $importWorkspaceId -Notebook $definition -Token $token -TimeoutSeconds $TimeoutSeconds @importMode -Confirm:$false))
        }
        else {
            $results.Add((New-DemoResult -CheckId ('FABRIC.IMPORT.' + ($definition.DisplayName.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')) `
                        -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message ('Skipped at the confirmation prompt: {0}.' -f $notebookTarget)))
        }
    }
}
#endregion Notebook import (Phase 12)

#region Real-Time Dashboard import (Phase 18)
# Step 3, only with -ImportDashboard. The same token rules as step 2: the passed token, the one step 2 got, or the
# Azure CLI after the subscription guard; nothing is imported after a failed guard unless -FabricToken or -WhatIf
# means the Azure CLI isn't needed.
$dashboardImported = $false
if ($ImportDashboard) {
    if ($importWorkspaceId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $results.Add((New-DemoResult -CheckId 'FABRIC.DASHBOARD.IMPORT' -Area 'fabric' -Target 'fabric' -Status 'Not selected' `
                    -Message 'The Fabric workspace isn''t resolved (FABRIC.RESOLVE.WORKSPACE says why) or passed (-WorkspaceId), so the Real-Time Dashboard wasn''t imported.'))
    }
    elseif (-not $config) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.DASHBOARD.IMPORT' -Area 'fabric' -Target 'fabric' -Status 'Not selected' `
                    -Message 'The Real-Time Dashboard needs the configuration file for the demo resource group, so it wasn''t imported.'))
    }
    elseif ($guardFailed -and $null -eq $FabricToken -and -not $WhatIfPreference) {
        Write-DemoLog -Level Warning -Message 'The Real-Time Dashboard wasn''t imported: the import needs an Azure CLI token, and the subscription guard failed.'
    }
    else {
        $dashboard = Get-DemoFabricDashboardDefinition -Config $config
        $dashboardTarget = "Real-Time Dashboard '{0}' in Fabric workspace {1}" -f $dashboard.DisplayName, $importWorkspaceId
        if ($WhatIfPreference) {
            $results.Add((Import-DemoFabricItem -WorkspaceId $importWorkspaceId -Item $dashboard -ReadBack -WhatIf))
        }
        elseif ($PSCmdlet.ShouldProcess($dashboardTarget, 'Create or update through the Fabric REST API, then read it back')) {
            $dashboardToken = $sessionToken
            if ($null -eq $dashboardToken -and (Test-Path -Path 'variable:token')) {
                $dashboardToken = $token
            }
            if ($null -eq $dashboardToken) {
                $null = Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])
                $dashboardToken = Get-DemoFabricToken -SubscriptionId $config['subscriptionId']
            }
            Write-DemoLog -Message ('Importing {0} ({1} bytes, SHA-256 {2}).' -f $dashboardTarget, $dashboard.SizeBytes, $dashboard.Sha256.Substring(0, 12))
            $imported = @(Import-DemoFabricItem -WorkspaceId $importWorkspaceId -Item $dashboard -Token $dashboardToken -TimeoutSeconds $TimeoutSeconds -ReadBack -Confirm:$false)
            $results.AddRange([object[]]$imported)
            $dashboardImported = $imported.Count -eq 2 -and @($imported | Where-Object { $_.status -ne 'Pass' }).Count -eq 0
            if ($dashboardImported) {
                # 2026-11-18: the dashboard shared with the presenters in presenterObjectIds, as Viewers of the demo workspace,
                # because Fabric's REST API has no operation to share one item (FABRIC.PRESENTER.VIEWER).
                $results.Add((Grant-DemoPresenterWorkspaceAccess -Config $config -WorkspaceId $importWorkspaceId -Token $dashboardToken -Confirm:$false))
            }
        }
        else {
            $results.Add((New-DemoResult -CheckId ('FABRIC.IMPORT.' + ($dashboard.DisplayName.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')) `
                        -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message ('Skipped at the confirmation prompt: {0}.' -f $dashboardTarget)))
        }
    }
}
#endregion Real-Time Dashboard import (Phase 18)

#region Real-Time Dashboard data (Phase 18)
# Step 4, after a passing import and read-back (unless -SkipDashboardDataCheck), or alone with -CheckDashboardData.
# It only reads: each tile's KQL against the telemetry endpoint, with a Kusto token for the configured subscription's
# account. So it needs the configuration and the subscription guard, but no workspace. Under -WhatIf it sends nothing.
if ($CheckDashboardData -or ($ImportDashboard -and -not $SkipDashboardDataCheck)) {
    $dataSkipped = ''
    if (-not $config) {
        $dataSkipped = 'The tile check needs the configuration file (the subscription and the demo resource group), so it didn''t run.'
    }
    elseif ($WhatIfPreference) {
        $dataSkipped = 'Dry run: would run each tile''s KQL, read-only, against the telemetry endpoint for the last 24 hours. No request was sent.'
    }
    elseif ($ImportDashboard -and -not $dashboardImported) {
        $dataSkipped = 'The import or the read-back of the Real-Time Dashboard didn''t pass, so its tiles weren''t checked.'
    }
    elseif ($guardFailed) {
        $dataSkipped = 'The subscription guard failed, so no Kusto token was requested and no tile was checked.'
    }
    if ($dataSkipped) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.DASHBOARD.DATA' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message $dataSkipped))
    }
    else {
        # The Kusto token needs the context the guard validates; the guard caches it when it ran earlier in this run.
        try {
            $guard = Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])
        }
        catch {
            $guard = New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message
        }
        if (@($results | Where-Object { $_.checkId -eq 'PREFLIGHT.GUARD.CONTEXT' }).Count -eq 0) {
            $results.Add($guard)
        }
        if ($guard.status -eq 'Fail') {
            $results.Add((New-DemoResult -CheckId 'FABRIC.DASHBOARD.DATA' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'The subscription guard failed, so no Kusto token was requested and no tile was checked.'))
        }
        else {
            $results.AddRange([object[]]@(Test-DemoRealTimeDashboardData -Config $config))
        }
    }
}
#endregion Real-Time Dashboard data (Phase 18)

#region Live-activity notebook run (Phase 20)
# Step 5, with -RunLiveActivity, or once after step 2 created NB_DatabaseHub_LiveActivity, or bound it to a lakehouse
# that step 0 created (ADR 0021): the notebook runs on demand and saves its results, so the lakehouse tables the
# history report reads exist and are current (Invoke-DemoFabricNotebookRun). It writes only the lakehouse's tables.
# It needs the workspace and the subscription guard; under -WhatIf nothing runs.
$liveImport = @($results | Where-Object { $_.checkId -eq 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY' }) | Select-Object -Last 1
$liveOperation = ''
if ($null -ne $liveImport) {
    $liveEvidence = $liveImport.evidence
    $liveOperation = if ($liveEvidence -is [System.Collections.IDictionary]) { [string]$liveEvidence['operation'] } elseif ($null -ne $liveEvidence -and $liveEvidence.PSObject.Properties['operation']) { [string]$liveEvidence.operation } else { '' }
}
$liveReady = $null -ne $liveImport -and $liveImport.status -eq 'Pass'
$firstRun = $liveReady -and ($liveOperation -eq 'created' -or $newLakehouse)
# An update whose history model reads tables the lakehouse doesn't have yet (2026-11-20: the Incident RCA's eight, ADR
# 0031): this release's notebook, just updated, creates them on its next run, so it runs once now, as for a first
# deployment, and the history model's step that follows reads them. Read-only check (OneLake's Path - List), only after
# the subscription guard; one that can't list the tables runs nothing, and the model's step leaves the tables out.
if ($liveReady -and -not $firstRun -and -not $RunLiveActivity -and $liveOperation -eq 'updated' -and $config -and -not $WhatIfPreference -and -not $guardFailed) {
    $tablePlan = Get-DemoRcaModelTablePlan -Config $config -WorkspaceId ([string]$fabric['workspaceId']) -LakehouseId ([string]$fabric['lakehouseId'])
    $tableEvidence = $tablePlan.Result.evidence
    if (@($tablePlan.Excluded).Count -gt 0 -and [bool]$tableEvidence['listed']) {
        Write-DemoLog -Message ('NB_DatabaseHub_LiveActivity was updated, and the lakehouse doesn''t have {0} yet: the notebook runs once now and creates them, so the history model reads them.' -f (@($tableEvidence['excluded']) -join ', '))
        $firstRun = $true
    }
}
if ($newLakehouse -and $liveOperation -eq 'unchanged') {
    $results.Add((New-DemoResult -CheckId 'FABRIC.NOTEBOOKS.IMPORT' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' `
                -Message ('The lakehouse "{0}" was just created, but NB_DatabaseHub_LiveActivity was already in the workspace and was left as it is, so it may still be bound to another lakehouse, and the history tables weren''t created.' -f [string]$fabric['lakehouseName']) `
                -Remediation 'Run ./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity -RunLiveActivity: it updates that notebook alone, edited or not, binds it to the new lakehouse, and runs it once to create the tables.' `
                -DocUrl 'https://learn.microsoft.com/fabric/data-engineering/notebook-public-api'))
}
if ($RunLiveActivity -or $firstRun) {
    if (-not $RunLiveActivity) {
        Write-DemoLog -Message 'Running NB_DatabaseHub_LiveActivity once, so the lakehouse gets the history tables the model reads (it writes only those tables).'
    }
    $runSkipped = ''
    if (-not $config) {
        $runSkipped = 'The notebook run needs the configuration file, so NB_DatabaseHub_LiveActivity didn''t run.'
    }
    elseif ($WhatIfPreference) {
        $runSkipped = ('Dry run: would run NB_DatabaseHub_LiveActivity on demand with SAVE_RESULTS true over the last {0} minutes. Nothing ran.' -f $LiveActivityWindowMinutes)
    }
    elseif ($guardFailed -and $null -eq $FabricToken) {
        $runSkipped = 'The subscription guard failed, so NB_DatabaseHub_LiveActivity didn''t run.'
    }
    if ($runSkipped) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message $runSkipped))
    }
    else {
        $runToken = $sessionToken
        if ($null -eq $runToken -and (Test-Path -Path 'variable:token')) {
            $runToken = $token
        }
        # Azure Resource Manager reads only after the subscription guard passed in this run: with -FabricToken it doesn't run.
        $guarded = Get-Variable -Name 'guardResult' -ValueOnly -ErrorAction SilentlyContinue
        $azGuarded = $null -ne $guarded -and [string]$guarded.status -ne 'Fail'
        if ($null -eq $runToken) {
            $null = Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])
            $azGuarded = $true
            $runToken = Get-DemoFabricToken -SubscriptionId $config['subscriptionId']
        }
        $notebookParameters = [ordered]@{
            # For a notebook imported before 2026-11-14, whose Run all sent an activity request through GitHub: today's
            # notebook has none of these three (ADR 0026), and a job's extra parameters change nothing in it.
            CONFIRM                    = $false
            STOP_ACTIVITY              = $false
            SAVE_RESULTS               = $true
            WINDOW_MINUTES             = $LiveActivityWindowMinutes
            TELEMETRY_LOOKBACK_MINUTES = $LiveActivityWindowMinutes
            KEY_VAULT_URL              = ''
            # The demo's resource group, which scopes the notebook's queries, as stop-demo.ps1 -SaveHistory and deploy.ps1's
            # snapshot send it. Without it the notebook kept its default, rg-dbhub-demo, so another environment's run saved
            # no telemetry snapshots (live, 2026-11-06).
            RESOURCE_GROUP             = ('rg-{0}-{1}' -f $config['prefix'], $config['environment'])
        }
        # T4 and its read replica (2026-11-13, ADR 0025): the notebook can't read Azure Monitor, so their metrics come with
        # the run as POSTGRES_METRICS: a file stop-demo.ps1 kept when a session's history couldn't be saved (its replica
        # is deleted, and its metrics with it), or T4's and a running replica's now, as deploy.ps1's snapshot sends them.
        if ($PostgresMetricsPath) {
            $notebookParameters['POSTGRES_METRICS'] = [System.IO.File]::ReadAllText($PostgresMetricsPath)
            Write-DemoLog -Message ('Sending the PostgreSQL metrics kept in {0} with the run.' -f $PostgresMetricsPath)
        }
        elseif ($RunLiveActivity -and $azGuarded) {
            $postgresCapture = & $module { param($Configuration, $Minutes) Get-DemoPostgresHistoryCapture -Config $Configuration -WindowMinutes $Minutes -CheckId 'FABRIC.T4.HISTORY' } $config $LiveActivityWindowMinutes
            if ($null -ne $postgresCapture -and $null -ne $postgresCapture.Result) {
                $results.Add($postgresCapture.Result)
            }
            if ($null -ne $postgresCapture -and [string]$postgresCapture.Json) {
                $notebookParameters['POSTGRES_METRICS'] = [string]$postgresCapture.Json
            }
        }
        # T5 (2026-11-18, ADR 0027): its Azure Cosmos DB account stays between sessions, so its metrics come from Azure Monitor
        # over the window, as COSMOS_METRICS, the way deploy.ps1's snapshot and stop-demo.ps1 -SaveHistory send them.
        if ($RunLiveActivity -and $azGuarded) {
            $cosmosCapture = & $module { param($Configuration, $Minutes) Get-DemoCosmosHistoryCapture -Config $Configuration -WindowMinutes $Minutes -CheckId 'FABRIC.T5.HISTORY' } $config $LiveActivityWindowMinutes
            if ($null -ne $cosmosCapture -and $null -ne $cosmosCapture.Result) {
                $results.Add($cosmosCapture.Result)
            }
            if ($null -ne $cosmosCapture -and [string]$cosmosCapture.Json) {
                $notebookParameters['COSMOS_METRICS'] = [string]$cosmosCapture.Json
            }
        }
        # A copy of the notebook from before 2026-11-13 doesn't know POSTGRES_METRICS and would ignore them (2026-11-16): they
        # aren't sent, and a kept file stays where it is. One whose definition can't be read gets them, as before.
        $postgresWithheld = $false
        if ($notebookParameters.Contains('POSTGRES_METRICS')) {
            $knows = & $module { param($Configuration, $FabricToken) Test-DemoFabricNotebookParameter -WorkspaceId ([string](Get-DemoMemberValue -InputObject $Configuration['fabric'] -Name 'workspaceId')) -Name 'NB_DatabaseHub_LiveActivity' -Parameter 'POSTGRES_METRICS' -Token $FabricToken } $config $runToken
            if ($knows.Known -and -not $knows.Has) {
                $notebookParameters.Remove('POSTGRES_METRICS')
                $postgresWithheld = $true
                $results.Add((New-DemoResult -CheckId 'FABRIC.T4.HISTORY' -Area 'fabric' -Target 'T4' -Status 'Warning' -Message 'T4''s metrics weren''t sent with the run: the workspace''s NB_DatabaseHub_LiveActivity is from before T4''s history (2026-11-13), so it would ignore them.' -Remediation $(if ($PostgresMetricsPath) { 'Run this command again with -Notebook NB_DatabaseHub_LiveActivity in place of -SkipNotebookImport, which updates that notebook alone first, edited or not; the file stays where it is.' } elseif ([bool]$fabric['importNotebooks']) { 'Run ./scripts/deploy.ps1, which updates the notebook, or this script with -Notebook NB_DatabaseHub_LiveActivity in place of -SkipNotebookImport, which updates that notebook alone.' } else { 'Run ./scripts/deploy.ps1, which updates the notebook unless someone edited it, or this script with -Notebook NB_DatabaseHub_LiveActivity in place of -SkipNotebookImport, which updates that notebook alone, edited or not.' })))
            }
        }
        # The same for T5's, with a copy from before 2026-11-18; Azure Monitor keeps them, so a later run adds them.
        if ($notebookParameters.Contains('COSMOS_METRICS')) {
            $knowsCosmos = & $module { param($Configuration, $FabricToken) Test-DemoFabricNotebookParameter -WorkspaceId ([string](Get-DemoMemberValue -InputObject $Configuration['fabric'] -Name 'workspaceId')) -Name 'NB_DatabaseHub_LiveActivity' -Parameter 'COSMOS_METRICS' -Token $FabricToken } $config $runToken
            if ($knowsCosmos.Known -and -not $knowsCosmos.Has) {
                $notebookParameters.Remove('COSMOS_METRICS')
                $results.Add((New-DemoResult -CheckId 'FABRIC.T5.HISTORY' -Area 'fabric' -Target 'T5' -Status 'Warning' -Message 'T5''s metrics weren''t sent with the run: the workspace''s NB_DatabaseHub_LiveActivity is from before T5''s history (2026-11-18), so it would ignore them. Azure Monitor keeps them.' -Remediation $(if ([bool]$fabric['importNotebooks']) { 'Run ./scripts/deploy.ps1, which updates the notebook, or this script with -Notebook NB_DatabaseHub_LiveActivity in place of -SkipNotebookImport, which updates that notebook alone; then this command again adds them.' } else { 'Run ./scripts/deploy.ps1, which updates the notebook unless someone edited it, or this script with -Notebook NB_DatabaseHub_LiveActivity in place of -SkipNotebookImport, which updates that notebook alone, edited or not; then this command again adds them.' })))
            }
        }
        $runTimeout = [Math]::Max(5, [int][Math]::Ceiling($TimeoutSeconds / 60.0))
        $runProgress = @{}
        if (-not $RunLiveActivity) {
            # The first history run (#68): a busy capacity keeps it queued for a while (live, 2026-11-19: about 15 minutes on
            # a shared F4), and the history model reads the tables it creates, so it gets a longer wait, on the status page.
            $runTimeout = [Math]::Max($runTimeout, $HistoryRunWaitMinutes)
            if ($ProgressPath) {
                $runProgress = @{ ProgressPath = $ProgressPath; ProgressId = 'Fabric.Items'; ProgressNote = 'It''s the first history run: the history model refreshes once it has run.' }
            }
        }
        # The Incident RCA's evidence (2026-11-20, ADR 0031), with -RunLiveActivity after the subscription guard: the runners'
        # export, not a session's last, with what an earlier save didn't take, staged for the run as RCA_EVIDENCE_FILE, as
        # deploy.ps1's snapshot does it (FABRIC.RCA.EXPORT, FABRIC.RCA.CAPTURE.<target>); what the run doesn't take stays
        # listed in out/history-pending for the next save (FABRIC.RCA.PENDING). Its sidecars (2026-11-23) after it: fetched
        # (Invoke-DemoRcaSidecarFetch), staged with the run as RCA_SIDECAR_FILE, more runs for what's left while the VMs run
        # (Invoke-DemoRcaSidecarDrain), and acknowledged on the VMs at once (FABRIC.RCA.SIDECAR).
        $rcaExport = $null
        $rcaSidecar = $null
        if ($RunLiveActivity -and $azGuarded) {
            $rcaExport = & $module { param($Configuration) Invoke-DemoRcaScriptExport -Config $Configuration -CheckPrefix FABRIC } $config
            foreach ($item in @($rcaExport.Results)) {
                $results.Add($item)
            }
            $rcaSidecar = & $module { param($Configuration) Invoke-DemoRcaSidecarFetch -Config $Configuration -CheckPrefix FABRIC -Runs 3 } $config
        }
        $rcaRun = $null
        $rcaPending = $null
        $sidecarLine = $null
        try {
            $hasEvidence = $null -ne $rcaExport -and [string]$rcaExport.Evidence
            $hasSidecar = $null -ne $rcaSidecar -and @($rcaSidecar.Fetched.Keys).Count -gt 0
            if ($hasEvidence -or $hasSidecar) {
                $rcaRun = & $module { param($Configuration, $Parameters, $Token, $Evidence, $Minutes, $Options, $Sidecar) Invoke-DemoRcaNotebookRun -Config $Configuration -Parameter $Parameters -Token $Token -Evidence $Evidence -TimeoutMinutes $Minutes -RunOption $Options -Sidecar $Sidecar } $config $notebookParameters $runToken $(if ($hasEvidence) { [string]$rcaExport.Evidence } else { '' }) $runTimeout $runProgress $rcaSidecar
                $run = $rcaRun.Run
                if ($hasEvidence -and -not [bool]$rcaRun.RcaSent) {
                    $results.Add((New-DemoResult -CheckId 'FABRIC.RCA.EVIDENCE' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('The RCA evidence wasn''t sent with the run: {0}.' -f [string]$rcaRun.RcaNote) -Remediation $(if ([string]$rcaRun.RcaNote -notmatch 'from before the Incident RCA') { 'Run this command again: it stages the evidence again.' } elseif ([bool]$fabric['importNotebooks']) { 'Run ./scripts/deploy.ps1, or this script with -Notebook NB_DatabaseHub_LiveActivity in place of -SkipNotebookImport, which updates that notebook; then this command again sends the evidence.' } else { 'Run ./scripts/deploy.ps1, which updates the notebook unless someone edited it, or this script with -Notebook NB_DatabaseHub_LiveActivity in place of -SkipNotebookImport, which updates that notebook alone, edited or not; then this command again sends the evidence.' }) -DocUrl 'https://learn.microsoft.com/fabric/onelake/onelake-access-api'))
                }
                # The sidecars the first run couldn't take, while the VMs run (F9).
                & $module { param($Configuration, $Sidecar, $Token, $Parameters) Invoke-DemoRcaSidecarDrain -Config $Configuration -Sidecar $Sidecar -Token $Token -Parameter $Parameters } $config $rcaSidecar $runToken $notebookParameters
            }
            else {
                $run = Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity' -Parameter $notebookParameters -Token $runToken -TimeoutMinutes $runTimeout @runProgress
            }
        }
        finally {
            # The pending list whatever the run did (review of 3b1348a), as stop-demo.ps1 and deploy.ps1's snapshot keep it:
            # the runner lists an exported document once, so what the run didn't take stays listed for the next save.
            if ($null -ne $rcaExport) {
                $rcaSaved = $null -ne $rcaRun -and [bool]$rcaRun.RcaSaved
                $rcaWhy = if ($null -ne $rcaRun -and [string]$rcaRun.RcaNote) { [string]$rcaRun.RcaNote } else { 'the run didn''t complete' }
                $rcaPending = & $module { param($Configuration, $Export, $Saved, $Why) Save-DemoRcaPending -Config $Configuration -CheckPrefix FABRIC -Export $Export -Saved:$Saved -Why $Why -Confirm:$false } $config $rcaExport $rcaSaved $rcaWhy
            }
            # The sidecars: acknowledged on the VMs at once, since they run; the rest waits on them (FABRIC.RCA.SIDECAR).
            if ($null -ne $rcaSidecar) {
                $sidecarLine = & $module { param($Configuration, $Sidecar) Complete-DemoRcaSidecarSave -Config $Configuration -Sidecar $Sidecar -Now -Why 'the run didn''t complete' } $config $rcaSidecar
            }
        }
        $results.Add($run)
        if ($null -ne $rcaPending) {
            $results.Add($rcaPending)
        }
        if ($null -ne $sidecarLine) {
            $results.Add($sidecarLine)
        }
        if ($PostgresMetricsPath -and [string]$run.status -eq 'Pass' -and -not $postgresWithheld) {
            # Added to the history: the file moves aside, so it isn't sent again by mistake.
            $savedFolder = Join-Path -Path (Split-Path -Path $PostgresMetricsPath -Parent) -ChildPath 'saved'
            try {
                $null = New-Item -ItemType Directory -Path $savedFolder -Force
                Move-Item -LiteralPath $PostgresMetricsPath -Destination (Join-Path -Path $savedFolder -ChildPath (Split-Path -Path $PostgresMetricsPath -Leaf)) -Force
                Write-DemoLog -Message ('The PostgreSQL metrics in {0} are in the history now; the file moved to {1}.' -f $PostgresMetricsPath, $savedFolder)
            }
            catch {
                Write-DemoLog -Level Warning -Message ('The PostgreSQL metrics are in the history now, but {0} couldn''t be moved aside: {1}' -f $PostgresMetricsPath, $_.Exception.Message)
            }
        }
        # F35 (i, 2026-11-23): with -RunLiveActivity, the kept values of the rows the run saved, worked out through Livy with
        # this checkout's code (Invoke-DemoHistoryKeptValue), only after a run that completed. Never a Fail.
        if ($RunLiveActivity -and [string]$run.status -eq 'Pass') {
            $results.Add((Invoke-DemoHistoryKeptValue -Config $config -Token $runToken -CheckId 'FABRIC.KEPTVALUE'))
        }
    }
}
#endregion Live-activity notebook run (Phase 20)

$results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
foreach ($item in $results | Where-Object { $_.status -in 'Fail', 'Manual action required', 'Warning' -and $_.remediation }) {
    Write-DemoLog -Level Warning -Message ('{0}: {1}' -f $item.checkId, $item.remediation)
}
Export-DemoResult -Result $results.ToArray() -Path $OutputPath
exit (Get-DemoExitCode -Result $results.ToArray() -TreatManualAsError:$TreatManualAsError)
