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

Step 1, the Database Hub checklist (Invoke-DemoHubReadiness; -SkipHubChecks skips it). Database Hub (preview)
has no public API or ARM resource, so the checklist uses documented interfaces only and never calls a Hub route
(docs/architecture.md, "Database Hub integration"):
- The subscription guard first: it stops the checklist with Fail unless the Azure CLI context matches the
  configured subscription and tenant and a token is available without interaction. It never signs in.
- P4: the Fabric tenant setting "Users can access the Database hub (preview)", through the Fabric admin API
  only with -FabricAdmin; otherwise Manual action required with the exact portal steps.
- P5: Contributor or higher on the resolved workspace and an F or Trial capacity, through Fabric REST with your
  Fabric token.
- P11 (optional, Phase 18): Power BI viewer licensing on the workspace's capacity (PREFLIGHT.FABRIC.VIEWERLICENSE):
  a Warning below F64, where viewers of the Phase 19 report and app need Pro, PPU, or a trial.
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
nothing is imported. Its GITHUB_REPOSITORY and GITHUB_ENVIRONMENT come from github.repository and github.environment,
unless the repository is still the example configuration's placeholder. With -NewNotebooksOnly, which deploy.ps1
passes while fabric.importNotebooks is false, a notebook that isn't in the workspace yet is imported without asking
and one that is stays as it is (Not selected).
The step runs only when the module has those functions; otherwise FABRIC.NOTEBOOKS.IMPORT is
Manual action required. Without a workspace (resolved, or -WorkspaceId), it's Not selected. After a
failed subscription guard, it runs only with -FabricToken or -WhatIf. Running this script without
-NewNotebooksOnly is the explicit request to create or update both notebooks. -WhatIf validates the
notebooks and shows the planned requests; without the checklist or a token, it sends no request at all.

Step 3, the Real-Time Dashboard (Phase 18; only with -ImportDashboard). Get-DemoFabricDashboardDefinition
validates fabric/realtime/RealTimeDashboard.json and fills in the demo resource group, and Import-DemoFabricItem
creates the KQLDashboard item or overrides its definition, then reads the definition back with Get Item Definition
(FABRIC.IMPORT.* and FABRIC.READBACK.*). The dashboard's data source is the documented SQL ADX proxy, queried with
each viewer's own identity; the definition holds no credential and no ID. -WhatIf validates it and shows the plan.

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
You are a Fabric administrator, so P4 is read through the Fabric admin API (Tenants - List Tenant Settings).

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
Step 2 imports only the notebooks that aren't in the workspace yet, and leaves the ones that are as they are.
deploy.ps1's Fabric track passes it while fabric.importNotebooks is false, so a new workspace or lakehouse gets its
notebooks without asking, and updating existing notebooks stays opt-in (Phase 26a).

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
current. It waits up to -TimeoutSeconds (at least 5 minutes) for the job. Step 5 also runs once by itself when
step 2 created the notebook, or bound it to a lakehouse that step 0 created, so a new lakehouse gets the tables.

.PARAMETER LiveActivityWindowMinutes
With -RunLiveActivity: the notebook's WINDOW_MINUTES and TELEMETRY_LOOKBACK_MINUTES (default 1440, one day).

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

    [switch] $ImportDashboard,

    [switch] $CheckDashboardData,

    [switch] $SkipDashboardDataCheck,

    [switch] $RunLiveActivity,

    [ValidateRange(15, 10080)]
    [int] $LiveActivityWindowMinutes = 1440,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/configure-fabric.jsonl'),

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
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

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
# -NewNotebooksOnly (deploy.ps1 while fabric.importNotebooks is false): a notebook that isn't in the workspace yet,
# as in a workspace or lakehouse that step 0 just created, is imported without asking; one that is stays as it is.
$createOnly = $NewNotebooksOnly -and -not $SkipNotebookImport
$importNote = if ($createOnly) { 'fabric.importNotebooks is false, so deploy.ps1 imports a missing notebook without asking and updates one that exists only when it''s true (or when you run ./scripts/configure-fabric.ps1 yourself).' } else { '' }
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
    if ($config -and -not $fabric['importNotebooks'] -and -not $createOnly) {
        Write-DemoLog -Message 'fabric.importNotebooks is false, so deploy.ps1 imports only the notebooks that are missing. Running this script is an explicit request, so it creates or updates them.'
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
    $importAction = if ($createOnly) { 'Create through the Fabric REST API when it''s missing' } else { 'Create or update through the Fabric REST API' }
    # Only a create-only import passes the Phase 26a parameters, so the call stays the same as before otherwise.
    $importMode = if ($createOnly) { @{ CreateOnly = $true; Note = $importNote } } else { @{} }
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
if ($newLakehouse -and $liveOperation -eq 'unchanged') {
    $results.Add((New-DemoResult -CheckId 'FABRIC.NOTEBOOKS.IMPORT' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' `
                -Message ('The lakehouse "{0}" was just created, but NB_DatabaseHub_LiveActivity was already in the workspace and was left as it is, so it may still be bound to another lakehouse, and the history tables weren''t created.' -f [string]$fabric['lakehouseName']) `
                -Remediation 'Run ./scripts/configure-fabric.ps1 -SkipHubChecks -RunLiveActivity: it updates the notebooks, binds them to the new lakehouse, and runs NB_DatabaseHub_LiveActivity once to create the tables.' `
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
        if ($null -eq $runToken) {
            $null = Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])
            $runToken = Get-DemoFabricToken -SubscriptionId $config['subscriptionId']
        }
        $notebookParameters = [ordered]@{
            CONFIRM                    = $false
            STOP_ACTIVITY              = $false
            SAVE_RESULTS               = $true
            WINDOW_MINUTES             = $LiveActivityWindowMinutes
            TELEMETRY_LOOKBACK_MINUTES = $LiveActivityWindowMinutes
            KEY_VAULT_URL              = ''
        }
        $results.Add((Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity' -Parameter $notebookParameters -Token $runToken -TimeoutMinutes ([Math]::Max(5, [int][Math]::Ceiling($TimeoutSeconds / 60.0)))))
    }
}
#endregion Live-activity notebook run (Phase 20)

$results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
foreach ($item in $results | Where-Object { $_.status -in 'Fail', 'Manual action required', 'Warning' -and $_.remediation }) {
    Write-DemoLog -Level Warning -Message ('{0}: {1}' -f $item.checkId, $item.remediation)
}
Export-DemoResult -Result $results.ToArray() -Path $OutputPath
exit (Get-DemoExitCode -Result $results.ToArray() -TreatManualAsError:$TreatManualAsError)
