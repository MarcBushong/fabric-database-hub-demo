function Get-DemoResourceGroupName {
    # rg-<prefix>-<environment>, the demo resource group (ADR 0002). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    return ('rg-{0}-{1}' -f $Config['prefix'], $Config['environment'])
}

function Get-DemoMainDeploymentName {
    # The template's subscription-scope deployment record: <prefix>-<environment>-main, which is dbhub-demo-main with the
    # defaults, as before. With the prefix in it (Phase 28), an environment with its own prefix, such as a throwaway proof,
    # never replaces, reads, or deletes another environment's record. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $prefix = if ([string]$Config['prefix']) { [string]$Config['prefix'] } else { 'dbhub' }
    return ('{0}-{1}-main' -f $prefix, $Config['environment'])
}

function Get-DemoHostVmName {
    # The T2 VM: archost01 (nested, the default) or arcsql01 (evaluation-only mode, ADR 0006). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ([string]$Config['t2Mode'] -eq 'EvaluationOnlyAzureVm') {
        return 'arcsql01'
    }
    return 'archost01'
}

function Get-DemoVmTarget {
    # The result target for a demo VM (ADR 0012): T1 for sqlvm01, T2 for the T2 VM. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $VmName
    )

    if ($VmName -eq 'sqlvm01') {
        return 'T1'
    }
    return 'T2'
}

function Get-DemoDeploymentStateTagName {
    # The resource group tags that hold deploy.ps1's state, so -Resume works from any machine and from
    # GitHub Actions (plan section 9.2). Internal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return [ordered]@{
        Stage             = 'DbHubDeployStage'
        StageUtc          = 'DbHubDeployStageUtc'
        BundleSha256      = 'DbHubBundleSha256'
        BundleChunkCount  = 'DbHubBundleChunks'
        RunnerSha256      = 'DbHubRunnerSha256'
        RunnerChunkCount  = 'DbHubRunnerChunks'
        BundleSentTo      = 'DbHubBundleSentTo'
        RunnerSentTo      = 'DbHubRunnerSentTo'
        NetworkMode       = 'DbHubNetworkMode'
        T3UseFreeLimit    = 'DbHubT3FreeOffer'
        T3AdminGroupName  = 'DbHubT3AdminGroup'
        BastionExpiresUtc = 'DbHubBastionExpiresUtc'
        HostPasswordSet   = 'DbHubHostPasswordUtc'
        TrackT1           = 'DbHubTrackT1'
        TrackT2           = 'DbHubTrackT2'
        TrackT4           = 'DbHubTrackT4'
        TrackFabric       = 'DbHubTrackFabric'
        T2Source          = 'DbHubT2Source'
        # fabric.manageCapacity (Phase 26b): the capacity start-demo.ps1 resumed, "<resource group>/<name>", and when.
        FabricCapacityResumed    = 'DbHubFabricCapacityResumed'
        FabricCapacityResumedUtc = 'DbHubFabricCapacityResumedUtc'
        # Phase 28: until when the PaygWizard guided stop's request on the T2 host is valid (empty when there's none), and the
        # size T4's Burstable fallback settled on (Standard_B2s, or None when Azure refused both) for later runs.
        GuidedStopUtc            = 'DbHubGuidedStopUtc'
        T4Sku                    = 'DbHubT4Sku'
        # Phase 28 review follow-up: when the T2 host's loader started a bootstrap generation that nobody has seen finish (empty
        # when none runs), so deploy.ps1's watchdog never restarts the host during its guest build (Get-DemoHostRestartBlocker).
        T2BuildUtc               = 'DbHubT2BuildUtc'
    }
}

function Get-DemoDeploymentStageName {
    # deploy.ps1's stages, in order (plan section 9.2). Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @('Preflight', 'Infrastructure', 'Artifacts', 'Bootstraps', 'T3', 'T4', 'Activity', 'Monitoring', 'T2', 'Fabric', 'Validation')
}

function Test-DemoDeploymentStageReached {
    # True when the recorded stage is this stage or a later one. The recorded stage never moves past an open
    # stage (Manual action required), so a stage that's reached is finished. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Recorded,

        [Parameter(Mandatory)]
        [string] $Stage
    )

    $stages = @(Get-DemoDeploymentStageName)
    if ($Recorded -notin $stages -or $Stage -notin $stages) {
        return $false
    }
    return ([array]::IndexOf($stages, $Recorded) -ge [array]::IndexOf($stages, $Stage))
}

function Get-DemoPinnedApiVersion {
    # The API version config/versions.json pins for a resource type that scripts call through az rest. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceType
    )

    $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $apiVersion = [string]$versions.apiVersions[$ResourceType]
    if (-not $apiVersion) {
        throw ('config/versions.json has no API version for {0}.' -f $ResourceType)
    }
    return $apiVersion
}

function Get-DemoExistingVmName {
    # Names of the demo VMs that exist in the resource group; empty when the group doesn't exist. Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('vm', 'list', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--query', '[].name', '--output', 'json') -AllowFailure
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
        return @()
    }
    return @(([string]$result.StdOut | ConvertFrom-Json) | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

function Test-DemoResourceGroupExist {
    # True when the demo resource group exists. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('group', 'exists', '--name', (Get-DemoResourceGroupName -Config $Config)) -AllowFailure
    return ($result.ExitCode -eq 0 -and ([string]$result.StdOut).Trim() -eq 'true')
}

function Get-DemoBudgetStartDate {
    <#
    .SYNOPSIS
    The existing budget's start date (yyyy-MM-dd), or empty when there's no budget yet. A redeployment must
    keep it: the template's default is the first day of the current month. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $url = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Consumption/budgets/budget-{2}-{3}?api-version={4}' -f $subscriptionId, (Get-DemoResourceGroupName -Config $Config), $Config['prefix'], $Config['environment'], (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Consumption/budgets')
    $budget = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $url) -AsJson -AllowFailure
    $start = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $budget -Name 'properties') -Name 'timePeriod') -Name 'startDate')
    if ($start -match '^(\d{4}-\d{2}-\d{2})') {
        return $Matches[1]
    }
    return ''
}

function Get-DemoDeploymentErrorText {
    # The error text of a failed 'az deployment' call, redacted and shortened for a result message. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [ValidateRange(100, 4000)]
        [int] $MaxLength = 1200
    )

    $clean = (Protect-DemoText -Text ([string]$Text)).Trim()
    if ($clean.Length -gt $MaxLength) {
        $clean = $clean.Substring(0, $MaxLength) + '...'
    }
    return $clean
}

function ConvertTo-DemoDeploymentOutput {
    # The template outputs as name -> value. Internal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object] $Deployment
    )

    $outputs = @{}
    $source = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Deployment -Name 'properties') -Name 'outputs'
    if ($null -eq $source) {
        return $outputs
    }
    $properties = if ($source -is [System.Collections.IDictionary]) { $source.Keys } else { $source.PSObject.Properties.Name }
    foreach ($name in $properties) {
        $outputs[[string]$name] = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $source -Name $name) -Name 'value'
    }
    return $outputs
}

function Get-DemoT1PrincipalId {
    # T1's system-assigned identity, which joins the P6 group (ADR 0008). Empty when T1 doesn't exist. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('vm', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', 'sqlvm01', '--query', 'identity.principalId', '--output', 'tsv') -AllowFailure
    if ($result.ExitCode -ne 0) {
        return ''
    }
    return ([string]$result.StdOut).Trim()
}

function Get-DemoT3State {
    <#
    .SYNOPSIS
    Whether T3's database exists and its status (Online, Paused, ...), read with az sql db show. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $DeploymentId = ''
    )

    $id = $DeploymentId
    if (-not $id) {
        $id = [string](Get-DemoResourceGroupTag -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName (Get-DemoResourceGroupName -Config $Config))['deploymentId']
    }
    $server = 'azuresql01-{0}' -f $id
    $database = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('sql', 'db', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--server', $server, '--name', 'ContosoCare') -AsJson -AllowFailure
    $status = [string](Get-DemoMemberValue -InputObject $database -Name 'status')
    return [pscustomobject]@{
        Exists       = ($null -ne $database)
        Status       = $status
        ServerName   = $server
        DeploymentId = $id
    }
}

function Get-DemoNextShutdownUtc {
    <#
    .SYNOPSIS
    The next auto-shutdown in UTC from autoShutdownTime (HHmm) and autoShutdownTimeZone (a Windows time zone
    ID), the same schedule as the DevTest Labs auto-shutdown. Internal.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $time = if ($Config['autoShutdownTime']) { [string]$Config['autoShutdownTime'] } else { '1900' }
    $zoneId = if ($Config['autoShutdownTimeZone']) { [string]$Config['autoShutdownTimeZone'] } else { 'UTC' }
    if ($time -notmatch '^([01]\d|2[0-3])([0-5]\d)$') {
        throw "autoShutdownTime '$time' isn't HHmm."
    }
    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($zoneId)
    $now = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($now, $zone)
    $candidate = [datetime]::new($local.Year, $local.Month, $local.Day, [int]$Matches[1], [int]$Matches[2], 0, [System.DateTimeKind]::Unspecified)
    if ($candidate -le $local) {
        $candidate = $candidate.AddDays(1)
    }
    return [System.TimeZoneInfo]::ConvertTimeToUtc($candidate, $zone)
}

function Invoke-DemoRepositoryScript {
    <#
    .SYNOPSIS
    Runs one of the repository's scripts (for example scripts/configure-fabric.ps1) from module code as an operator
    would run it, outside DbHubDemo's session state, and returns its output. Internal.

    .DESCRIPTION
    A script that a module function runs with the call operator runs in the module's session state, so the script's
    own scope becomes the script scope of every DbHubDemo function it calls, and those functions no longer find the
    module's $script: variables (live, 2026-10-22: deploy.ps1's Fabric track stopped at once, because Get-DemoConfig's
    default schema path reads $script:RepoRoot). A script block bound to a separate dynamic module runs the script in
    that module's session state instead, so DbHubDemo's functions keep their own script scope, including the
    subscription guard's validated context.
    https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_scopes
    https://learn.microsoft.com/dotnet/api/system.management.automation.psmoduleinfo.newboundscriptblock
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [System.Collections.IDictionary] $Argument = @{}
    )

    $hostModule = New-Module -Name 'DbHubDemoScriptHost' -ScriptBlock { Export-ModuleMember -Function @() }
    $invoke = $hostModule.NewBoundScriptBlock({
            param([string] $ScriptPath, [System.Collections.IDictionary] $Arguments)
            & $ScriptPath @Arguments
        })
    return (& $invoke $Path $Argument)
}

function Invoke-DemoFabricStage {
    <#
    .SYNOPSIS
    deploy.ps1's Fabric stage: runs scripts/configure-fabric.ps1 (the Database Hub checklist with the T3
    readiness gate, and the notebook import when asked) and returns its results. Internal.

    .DESCRIPTION
    The script stays the one implementation of the import loop (Phases 9 and 12). Telemetry is left to the
    validation stage (-SkipTelemetry). Without -ConfigPath, the configuration goes to a file in a private
    temporary directory that's deleted afterward; it holds no secrets.

    deploy.ps1's parallel Fabric track (ADR 0018) passes -SkipHubChecks and -ImportDashboard: it imports the
    notebooks and the Real-Time Dashboard while the targets deploy, and leaves the Hub checklist, the T3
    gate, and the dashboard's tile check to the validation, which passes -CheckDashboardData once telemetry
    flows, and -T3PerformanceMonitoringCheck with the T3.PROPERTY result, so the gate's extended-property part
    isn't left as a manual step. While fabric.importNotebooks is false, deploy passes -NewNotebooksOnly: notebooks
    that aren't in the workspace yet are imported without asking, and existing ones stay as they are (Phase 26a).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [switch] $ImportNotebooks,

        [switch] $NewNotebooksOnly,

        [switch] $ImportDashboard,

        [switch] $SkipHubChecks,

        [switch] $CheckDashboardData,

        [scriptblock] $T3PerformanceMonitoringCheck
    )

    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-fabric'
    try {
        $path = $ConfigPath
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            $path = Write-DemoPrivateFile -Directory $directory -Name 'demo.config.json' -Content ($Config | ConvertTo-Json -Depth 20)
        }
        $output = Join-Path -Path $directory -ChildPath 'configure-fabric.jsonl'
        $arguments = @{
            ConfigPath    = $path
            OutputPath    = $output
            SkipTelemetry = $true
            Confirm       = $false
        }
        if ($SkipHubChecks) {
            $arguments['SkipHubChecks'] = $true
        }
        else {
            $arguments['T3ReadinessGate'] = $true
            if ($null -ne $T3PerformanceMonitoringCheck) {
                $arguments['T3PerformanceMonitoringCheck'] = $T3PerformanceMonitoringCheck
            }
        }
        if ($NewNotebooksOnly -and -not $ImportNotebooks) {
            $arguments['NewNotebooksOnly'] = $true
        }
        elseif (-not $ImportNotebooks) {
            $arguments['SkipNotebookImport'] = $true
        }
        if ($ImportDashboard) {
            $arguments['ImportDashboard'] = $true
            if (-not $CheckDashboardData) {
                $arguments['SkipDashboardDataCheck'] = $true
            }
        }
        if ($CheckDashboardData) {
            $arguments['CheckDashboardData'] = $true
        }
        $null = Invoke-DemoRepositoryScript -Path (Join-Path -Path $script:RepoRoot -ChildPath 'scripts/configure-fabric.ps1') -Argument $arguments
        if (-not (Test-Path -LiteralPath $output)) {
            return @(New-DemoResult -CheckId 'DEPLOY.FABRIC' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'configure-fabric.ps1 wrote no results.' -Remediation 'Run ./scripts/configure-fabric.ps1 yourself to see its output.')
        }
        return @(Get-Content -LiteralPath $output | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
}

function Invoke-DemoFabricScriptStep {
    <#
    .SYNOPSIS
    Runs one of the repository's Fabric scripts in this process with the configuration and an output file, and
    returns the ADR 0012 records it wrote. Internal; Invoke-DemoPowerBIStage and Invoke-DemoFabricAppStage use it.

    .DESCRIPTION
    Only the parameters the script declares are passed (ConfigPath, OutputPath, and Confirm), plus -Argument. A
    script that throws, or writes no records, is reported as -CheckId Fail. Without -ConfigPath, the configuration
    goes to a file in a private temporary directory that's deleted afterward; it holds no secrets.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [Parameter(Mandatory)]
        [string] $ScriptPath,

        [Parameter(Mandatory)]
        [string] $CheckId,

        [System.Collections.IDictionary] $Argument = @{}
    )

    $name = Split-Path -Path $ScriptPath -Leaf
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-fabric'
    try {
        $path = $ConfigPath
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            $path = Write-DemoPrivateFile -Directory $directory -Name 'demo.config.json' -Content ($Config | ConvertTo-Json -Depth 20)
        }
        $output = Join-Path -Path $directory -ChildPath 'results.jsonl'
        $declared = (Get-Command -Name $ScriptPath -ErrorAction Stop).Parameters
        $arguments = @{}
        foreach ($pair in @(@('ConfigPath', $path), @('OutputPath', $output), @('Confirm', $false))) {
            if ($declared.ContainsKey($pair[0])) {
                $arguments[$pair[0]] = $pair[1]
            }
        }
        foreach ($key in $Argument.Keys) {
            $arguments[[string]$key] = $Argument[$key]
        }
        try {
            $null = Invoke-DemoRepositoryScript -Path $ScriptPath -Argument $arguments
        }
        catch {
            return @(New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('{0} stopped: {1}' -f $name, (Protect-DemoText -Text $_.Exception.Message)) -Remediation ('Run ./scripts/{0} yourself to see its output.' -f $name))
        }
        if (-not (Test-Path -LiteralPath $output)) {
            return @(New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('{0} wrote no results.' -f $name) -Remediation ('Run ./scripts/{0} yourself to see its output.' -f $name))
        }
        return @(Get-Content -LiteralPath $output | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
}

function Invoke-DemoPowerBIStage {
    <#
    .SYNOPSIS
    The Fabric track's Power BI step (Phase 19, ADR 0018): runs scripts/configure-powerbi.ps1 (the history semantic
    model, its refresh and data check, and the report) and returns its records. Internal.

    .DESCRIPTION
    -CheckModelData runs only the data check against the deployed model (configure-powerbi.ps1 -CheckModelData).
    Without a Fabric workspace and lakehouse in the configuration, the script reports Not selected itself.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [switch] $CheckModelData
    )

    $scriptPath = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/configure-powerbi.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return @(New-DemoResult -CheckId 'DEPLOY.POWERBI' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'scripts/configure-powerbi.ps1 (Phase 19) isn''t in this checkout, so the history report wasn''t deployed.')
    }
    $argument = @{}
    if ($CheckModelData) {
        $argument['CheckModelData'] = $true
    }
    return @(Invoke-DemoFabricScriptStep -Config $Config -ConfigPath $ConfigPath -ScriptPath $scriptPath -CheckId 'DEPLOY.POWERBI' -Argument $argument)
}

function Invoke-DemoFabricAppStage {
    <#
    .SYNOPSIS
    The Fabric track's app step: runs scripts/configure-fabric-app.ps1 (Phase 19b, the Fabric app over the history
    model) when this checkout has it, and returns its records; DEPLOY.FABRIC.APP is Not selected otherwise. Phase
    19b verifies the app itself. Internal.

    .DESCRIPTION
    The app is optional (brief item 15), so here its records are never a Fail: a Fail becomes Manual action required
    (evidence reportedStatus Fail), every record is marked optional (evidence optional insightsApp, which
    Test-DemoOptionalResult reads), and the records that aren't the app's own (the script's own workspace and capacity
    checks, for example) say they're the app's. -WorkspaceId is the workspace the Fabric step resolved or created, so
    the script doesn't look it up by name again (Phase 28 live finding).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [AllowEmptyString()]
        [string] $WorkspaceId = ''
    )

    $scriptPath = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/configure-fabric-app.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return @(New-DemoResult -CheckId 'DEPLOY.FABRIC.APP' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'scripts/configure-fabric-app.ps1 (Phase 19b) isn''t in this checkout, so the Fabric app wasn''t deployed.')
    }
    $argument = @{}
    if ($WorkspaceId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $argument['WorkspaceId'] = $WorkspaceId
    }
    $records = @(Invoke-DemoFabricScriptStep -Config $Config -ConfigPath $ConfigPath -ScriptPath $scriptPath -CheckId 'DEPLOY.FABRIC.APP' -Argument $argument)
    return @(foreach ($record in $records) {
            ConvertTo-DemoOptionalAppRecord -Record $record
        })
}

function ConvertTo-DemoOptionalAppRecord {
    # One record of the optional Insights app's step as deploy.ps1 reports it (brief item 15; Phase 28 live finding):
    # marked optional, a Fail as Manual action required, and named as the app's when it isn't one of its own checks.
    # Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [object] $Record
    )

    $own = [string]$Record.checkId -like 'FABRIC.APP.*' -or [string]$Record.checkId -eq 'DEPLOY.FABRIC.APP'
    $marks = [ordered]@{ optional = 'insightsApp' }
    if ([string]$Record.status -eq 'Fail') {
        $marks['reportedStatus'] = 'Fail'
        $Record.status = 'Manual action required'
        if (-not [string](Get-DemoMemberValue -InputObject $Record -Name 'remediation')) {
            $Record | Add-Member -NotePropertyName 'remediation' -NotePropertyValue 'To add the optional Insights app, run ./scripts/configure-fabric-app.ps1 -SignIn.' -Force
        }
    }
    $evidence = Get-DemoMemberValue -InputObject $Record -Name 'evidence'
    if ($evidence -is [System.Collections.IDictionary]) {
        foreach ($key in $marks.Keys) {
            $evidence[$key] = $marks[$key]
        }
    }
    elseif ($null -ne $evidence -and $evidence -isnot [string] -and $evidence -isnot [System.ValueType]) {
        foreach ($key in $marks.Keys) {
            $evidence | Add-Member -NotePropertyName $key -NotePropertyValue $marks[$key] -Force
        }
    }
    else {
        $Record | Add-Member -NotePropertyName 'evidence' -NotePropertyValue ([pscustomobject]$marks) -Force
    }
    if (-not $own -and [string]$Record.message -notlike 'Optional Insights app:*') {
        $Record.message = 'Optional Insights app: {0}' -f [string]$Record.message
    }
    return $Record
}

function Get-DemoResolvedWorkspaceId {
    # The Fabric workspace's ID that configure-fabric.ps1's records name (FABRIC.RESOLVE.WORKSPACE: found, created, or the
    # fabric.workspaceId override), or '' when none did. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $pattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $named = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'FABRIC.RESOLVE.WORKSPACE' -and [string]$_.status -ne 'Fail' })
    for ($index = $named.Count - 1; $index -ge 0; $index--) {
        $id = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $named[$index] -Name 'evidence') -Name 'workspaceId')
        if ($id -match $pattern -and $id -ne '00000000-0000-0000-0000-000000000000') {
            return $id.ToLowerInvariant()
        }
    }
    return ''
}
