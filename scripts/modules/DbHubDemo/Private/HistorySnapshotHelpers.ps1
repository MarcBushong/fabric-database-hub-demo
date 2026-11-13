# deploy.ps1's history snapshot (2026-11-06; ADR 0014's amendment): at the end of each run, once DONE's telemetry checks
# have passed and the VMs got the run's activity profile, NB_DatabaseHub_LiveActivity runs once, analyze-only, and the
# history model is refreshed (Direct Lake framing), so the history report has data right after a deployment. It never
# blocks DONE: its one record, DEPLOY.FABRIC.HISTORY, is Pass, Warning, or Not selected, never a Fail or Manual action
# required, and the status page's Fabric.History row and its Needs attention box say what didn't work.
# Sources (checked 2026-11-06):
# - Run On Demand Item Job: https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job
# - Run a notebook on demand with parameters: https://learn.microsoft.com/fabric/data-engineering/notebook-public-api
# - Direct Lake framing and automatic updates: https://learn.microsoft.com/fabric/fundamentals/direct-lake-how-it-works
# - Refresh Dataset In Group: https://learn.microsoft.com/rest/api/power-bi/datasets/refresh-dataset-in-group
# - Pause and resume a Fabric capacity: https://learn.microsoft.com/fabric/enterprise/pause-resume

$script:HistorySnapshotCheckId = 'DEPLOY.FABRIC.HISTORY'
$script:HistorySnapshotRowId = 'Fabric.History'
$script:HistorySnapshotNotebook = 'NB_DatabaseHub_LiveActivity'
$script:HistorySnapshotRunAgain = './scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity'

function Get-DemoHistorySnapshotParameter {
    <#
    .SYNOPSIS
    The parameters deploy.ps1's history snapshot sends NB_DatabaseHub_LiveActivity (2026-11-06): analyze-only. Pure.
    Internal.

    .DESCRIPTION
    - CONFIRM false: the notebook's Run all would otherwise send its activity request through GitHub (P9, 240 minutes of
      business-day), on top of the one the deployment started.
    - STOP_ACTIVITY false: it never stops what runs.
    - SAVE_RESULTS true, over the last -WindowMinutes (WINDOW_MINUTES): it writes only the lakehouse's history tables.
    - KEY_VAULT_URL empty: no GitHub token is read.
    - RESOURCE_GROUP: the demo's resource group, which the notebook's queries are scoped to, as stop-demo.ps1 -SaveHistory
      sends it.
    Invoke-DemoFabricNotebookRun adds the resolved WORKSPACE_ID and LAKEHOUSE_ID.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(15, 10080)]
        [int] $WindowMinutes = 1440
    )

    return [ordered]@{
        CONFIRM        = $false
        STOP_ACTIVITY  = $false
        SAVE_RESULTS   = $true
        WINDOW_MINUTES = $WindowMinutes
        KEY_VAULT_URL  = ''
        RESOURCE_GROUP = (Get-DemoResourceGroupName -Config $Config)
    }
}

function Get-DemoHistorySnapshotSkip {
    <#
    .SYNOPSIS
    Why deploy.ps1's history snapshot doesn't run: Message and Remediation for its Not selected record, or $null when it
    runs (2026-11-06). Pure. Internal.

    .DESCRIPTION
    In this order:
    - -WhatIfRun: nothing runs.
    - -SkipFabric.
    - -GitHubActions: deploy.ps1 runs as the workflow's identity there, and the demo has no supported way for it to run
      notebooks (ADR 0014; deploy.yml skips Fabric by default), so the person who ran the deployment runs it instead.
    - DONE's checks didn't run (-DoneChecked false): a track didn't finish, or a check failed.
    - A TELEMETRY.* requirement in -Requirement without a Pass in -Result: the notebook would have nothing to save.
    Whether the notebook and the lakehouse exist is read in Fabric by the step itself (Invoke-DemoHistorySnapshotRun).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowEmptyCollection()]
        [string[]] $Requirement = @(),

        [switch] $DoneChecked,

        [switch] $SkipFabric,

        [switch] $WhatIfRun,

        [switch] $GitHubActions
    )

    $notebook = $script:HistorySnapshotNotebook
    $answer = { param([string] $Message, [string] $Remediation = '') [pscustomobject]@{ Message = $Message; Remediation = $Remediation } }
    if ($WhatIfRun) {
        return (& $answer ('What if: nothing ran. A deployment runs {0} once at its end, analyze-only, so the history report gets its snapshots.' -f $notebook))
    }
    if ($SkipFabric) {
        return (& $answer ('The Fabric track was skipped (-SkipFabric), so {0} didn''t run, and the history report got no snapshot.' -f $notebook))
    }
    if ($GitHubActions) {
        return (& $answer ('In GitHub Actions, deploy.ps1 runs as the workflow''s identity, and the demo has no supported way for it to run notebooks (ADR 0014; deploy.yml skips Fabric by default), so {0} didn''t run, and the history report got no snapshot.' -f $notebook) ('From a terminal where you''re signed in to Azure: {0}.' -f $script:HistorySnapshotRunAgain))
    }
    if (-not $DoneChecked) {
        return (& $answer ('DONE''s checks didn''t run in this deployment (a track didn''t finish, or a check failed), so {0} didn''t run: the history report''s snapshots come at the end of the deploy.ps1 run that passes them.' -f $notebook))
    }
    $telemetry = @($Requirement | Where-Object { [string]$_ -like 'TELEMETRY.*' })
    $missing = @((Test-DemoDoneEvidence -Result $Result -Requirement $telemetry).Missing)
    if ($missing.Count -gt 0) {
        return (& $answer ('DONE''s telemetry checks didn''t pass ({0}), so {1} didn''t run: it would have had nothing to save. The deploy.ps1 run that passes them takes the history report''s snapshots at its end.' -f ($missing -join ', '), $notebook))
    }
    return $null
}

function Invoke-DemoHistorySnapshotRun {
    <#
    .SYNOPSIS
    The Fabric part of deploy.ps1's history snapshot (Invoke-DemoHistorySnapshotStep): the notebook's run, then the history
    model's refresh. Returns Status (Pass, Warning, or Not selected), Outcome, Message, Remediation, ReportedStatus (Fail
    for an error, otherwise empty), and Evidence; throws only what its calls throw. Internal.

    .DESCRIPTION
    As whoever ran deploy.ps1: the Azure CLI's Fabric token after the subscription guard (Get-DemoFabricToken).
    1. The workspace and the lakehouse by name, read-only (Resolve-DemoFabricConfig without -Create), and the notebook by
       name (Find-DemoFabricItem). One that a list that answered doesn't have is Not selected (Outcome NotSelected): the
       Fabric track didn't create or import it. One whose list Fabric refused because the capacity is paused or inactive
       is the Warning below (Outcome CapacityPaused; live finding, 2026-11-10), and one that couldn't be read otherwise is
       a Warning with the error (Outcome Failed).
    2. The capacity (Test-DemoFabricWorkspace, FABRIC.P5.CAPACITY): a capacity that isn't Active runs nothing, and the
       Warning says so (Outcome CapacityPaused), as does a submit that Fabric refuses with CapacityNotActive. Nothing here
       resumes, pauses, or scales it.
    3. The run (Invoke-DemoFabricNotebookRun with -Parameter, at most -TimeoutMinutes): Completed goes on to the refresh;
       a job still running then is a Warning (StillRunning), and it keeps running in Fabric; a deduplicated one too
       (Deduped); a failure is a Warning with Fabric's reason (Failed).
    4. The refresh (Find-DemoSemanticModel, Invoke-DemoSemanticModelRefresh with -TableRetryMinutes 0, at most
       -RefreshTimeoutSeconds): Direct Lake framing, so the report shows the new rows now. Pass (Saved) when it passed;
       otherwise a Warning (SavedNotRefreshed): the snapshots are saved, and Direct Lake picks them up by itself (Keep
       your Direct Lake data up to date, on by default) or at the next refresh.
    Pass says what stays partial: incidents start only at the end of the run, so incident measures such as Blocking
    Incidents stay blank until incidents have run and the notebook runs again.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Parameter,

        [Parameter(Mandatory)]
        [pscustomobject] $ActivityProfile,

        [switch] $ModelCheckedBefore,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [ValidateRange(1, 60)]
        [int] $TimeoutMinutes = 10,

        [ValidateRange(30, 3600)]
        [int] $RefreshTimeoutSeconds = 300,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 15
    )

    $notebook = $script:HistorySnapshotNotebook
    $again = $script:HistorySnapshotRunAgain
    $window = [int]$Parameter['WINDOW_MINUTES']
    $evidence = [ordered]@{ windowMinutes = $window; timeoutMinutes = $TimeoutMinutes }
    $answer = {
        param([string] $Status, [string] $Outcome, [string] $Message, [string] $Remediation = '', [string] $ReportedStatus = '')
        [pscustomobject]@{ Status = $Status; Outcome = $Outcome; Message = $Message; Remediation = $Remediation; ReportedStatus = $ReportedStatus; Evidence = $evidence }
    }
    # A paused capacity, as Fabric and Power BI answer it (Invoke-DemoSemanticModelRefresh reads it the same way).
    $paused = $script:FabricCapacityInactivePattern
    $resumeFix = Get-DemoFabricCapacityResumeFix -Then ('run {0}, or ./scripts/stop-demo.ps1 -SaveHistory at the end of the session.' -f $again)
    $laterFix = 'Check the run in the workspace''s Monitor hub. Once it''s done, the history report shows its snapshots after Direct Lake''s automatic update, or after ./scripts/configure-powerbi.ps1 refreshes the model.'

    $token = Get-DemoFabricToken -SubscriptionId ([string]$Config['subscriptionId'])
    # Read-only: the Fabric track creates what's missing; this step only uses what it made.
    $resolution = Resolve-DemoFabricConfig -Config $Config -Token $token -Confirm:$false
    if (-not $resolution.Resolved) {
        $open = @($resolution.Results | Where-Object { [string]$_.status -notin 'Pass', 'Not selected' })
        $why = (@($open | ForEach-Object { '{0}: {1}' -f [string]$_.checkId, [string]$_.message }) -join ' ').Trim()
        # A list that didn't answer says nothing about whether the workspace or the lakehouse exists (evidence listed
        # $false; live finding, 2026-11-10: a paused capacity's lakehouse list was taken for a lakehouse the Fabric track
        # didn't create).
        $unlisted = @($open | Where-Object { (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'evidence') -Name 'listed') -eq $false })
        $inactive = @($unlisted | Where-Object { (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'evidence') -Name 'capacityInactive') -eq $true }) | Select-Object -First 1
        if ($null -ne $inactive) {
            $listError = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $inactive -Name 'evidence') -Name 'error')
            return (& $answer 'Warning' 'CapacityPaused' ('The history report got no snapshot: the workspace''s capacity isn''t running ({0}), so {1} couldn''t run. deploy.ps1 never resumes, pauses, or scales a capacity.' -f $(if ($listError) { $listError.TrimEnd('.', ' ') } else { 'the lakehouses couldn''t be listed' }), $notebook) $resumeFix)
        }
        if (@($open | Where-Object { [string]$_.status -eq 'Fail' }).Count -gt 0 -or $unlisted.Count -gt 0) {
            return (& $answer 'Warning' 'Failed' ('The history report got no snapshot: the Fabric workspace and lakehouse couldn''t be read. {0}' -f $why).Trim() ('Run {0} once Fabric answers.' -f $again) 'Fail')
        }
        return (& $answer 'Not selected' 'NotSelected' ('The Fabric track didn''t create the workspace or the lakehouse, so {0} didn''t run. {1}' -f $notebook, $why).Trim() ('./scripts/deploy.ps1 creates them (its Fabric track), then runs {0} at its end.' -f $notebook))
    }
    $resolved = $resolution.Config
    $workspaceId = [string]$resolution.WorkspaceId
    $workspaceName = [string]$resolution.WorkspaceName

    # The capacity first: a paused one runs nothing, and deploy.ps1 never resumes it.
    $capacity = @(Test-DemoFabricWorkspace -Config $resolved -Token $token | Where-Object { [string]$_.checkId -eq 'FABRIC.P5.CAPACITY' }) | Select-Object -First 1
    $capacityEvidence = Get-DemoMemberValue -InputObject $capacity -Name 'evidence'
    $capacityState = [string](Get-DemoMemberValue -InputObject $capacityEvidence -Name 'state')
    $capacityName = [string](Get-DemoMemberValue -InputObject $capacityEvidence -Name 'capacityName')
    if ($capacityState) {
        $evidence['capacityState'] = $capacityState
    }
    if ($capacityState -and $capacityState -ine 'Active') {
        return (& $answer 'Warning' 'CapacityPaused' ('The history report got no snapshot: the workspace''s capacity{0} is {1}, so {2} couldn''t run. deploy.ps1 never resumes, pauses, or scales a capacity.' -f $(if ($capacityName) { ' "{0}"' -f $capacityName } else { '' }), $capacityState, $notebook) $resumeFix)
    }

    $found = Find-DemoFabricItem -WorkspaceId $workspaceId -DisplayName $notebook -Type 'Notebook' -Token $token
    if ($found.StatusCode -ne 200) {
        $listError = [string]$found.Error
        if ($listError -match $paused) {
            return (& $answer 'Warning' 'CapacityPaused' ('The history report got no snapshot: the workspace''s capacity isn''t running ({0}), so {1} couldn''t run. deploy.ps1 never resumes, pauses, or scales a capacity.' -f $listError, $notebook) $resumeFix)
        }
        return (& $answer 'Warning' 'Failed' ('The history report got no snapshot: the workspace''s notebooks couldn''t be listed (HTTP {0}): {1}' -f $found.StatusCode, $listError) ('Run {0} once Fabric answers.' -f $again) 'Fail')
    }
    if (@($found.Items).Count -eq 0) {
        return (& $answer 'Not selected' 'NotSelected' ('The Fabric track didn''t import {0}: it isn''t in the workspace "{1}", so the history report got no snapshot.' -f $notebook, $workspaceName) ('./scripts/deploy.ps1 imports it (its Fabric track), then runs it at its end; or run ./scripts/configure-fabric.ps1 -SkipHubChecks, then {0}.' -f $again))
    }

    $run = Invoke-DemoFabricNotebookRun -Config $resolved -Name $notebook -Parameter $Parameter -Token $token -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds
    $runEvidence = Get-DemoMemberValue -InputObject $run -Name 'evidence'
    $jobStatus = [string](Get-DemoMemberValue -InputObject $runEvidence -Name 'status')
    $seconds = Get-DemoMemberValue -InputObject $runEvidence -Name 'seconds'
    $evidence['jobStatus'] = $jobStatus
    $evidence['seconds'] = $seconds
    $runStatus = [string]$run.status
    $runText = ConvertTo-DemoPlainText -Value $run.message
    if ($runStatus -eq 'Not selected') {
        return (& $answer 'Not selected' 'NotSelected' $runText)
    }
    if ($runStatus -eq 'Warning') {
        if ($jobStatus -eq 'Deduped') {
            return (& $answer 'Warning' 'Deduped' ('{0} was already running, so this run was deduplicated: the history report''s snapshots come from that run once it finishes, and the history model wasn''t refreshed for them.' -f $notebook) $laterFix)
        }
        if ($jobStatus -and $jobStatus -notin 'Completed', 'Failed', 'Cancelled') {
            return (& $answer 'Warning' 'StillRunning' ('{0} was still {1} after {2} minutes, so deploy.ps1 stopped waiting: the run goes on in Fabric and saves its snapshots when it finishes, and the history model wasn''t refreshed for them.' -f $notebook, $jobStatus, $TimeoutMinutes) $laterFix)
        }
        # Accepted, but with no job to follow.
        return (& $answer 'Warning' 'Unconfirmed' ('{0} The history model wasn''t refreshed for it.' -f $runText) $laterFix)
    }
    if ($runStatus -ne 'Pass') {
        if ($runText -match $paused) {
            return (& $answer 'Warning' 'CapacityPaused' ('The history report got no snapshot: the workspace''s capacity isn''t running, so {0} couldn''t start. {1}' -f $notebook, $runText) $resumeFix)
        }
        $fix = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $run -Name 'remediation')
        return (& $answer 'Warning' 'Failed' ('The history report got no snapshot: {0}' -f $runText) ('{0}Then run {1}.' -f $(if ($fix) { $fix.TrimEnd() + ' ' } else { '' }), $again) 'Fail')
    }

    # The snapshots are saved: frame the Direct Lake model on them, so the report shows them now.
    $took = if ($null -ne $seconds -and [string]$seconds) { ' in about {0} seconds' -f $seconds } else { '' }
    $saved = '{0} ran once, analyze-only (no activity request), and saved the last {1} minutes to the lakehouse{2}' -f $notebook, $window, $took
    Set-DemoProgressStep -Path $ProgressPath -Id $script:HistorySnapshotRowId -State 'Running' -Message ('{0}; refreshing the history model (Direct Lake framing).' -f $saved)
    $modelName = [string](Get-DemoFabricAppSetting)['semanticModelName']
    if (-not $modelName) {
        $modelName = 'SM_DatabaseHub_History'
    }
    $notRefreshed = {
        param([string] $Why, [string] $Fix = '', [string] $Reported = '')
        $later = 'The history report shows them once Direct Lake updates the model by itself (Keep your Direct Lake data up to date, on by default), or after ./scripts/configure-powerbi.ps1 refreshes it.'
        & $answer 'Warning' 'SavedNotRefreshed' ('{0}, but the history model wasn''t refreshed: {1}' -f $saved, $Why) $(if ($Fix) { '{0} {1}' -f $later, $Fix } else { $later }) $Reported
    }
    $powerBIToken = Get-DemoPowerBIToken -SubscriptionId ([string]$Config['subscriptionId'])
    $lookup = Find-DemoSemanticModel -WorkspaceId $workspaceId -Name $modelName -Token $powerBIToken
    if ($lookup.StatusCode -ne 200) {
        return (& $notRefreshed ('the workspace''s semantic models couldn''t be listed: {0}' -f $lookup.Error) '' 'Fail')
    }
    if (-not $lookup.Id) {
        return (& $notRefreshed ('{0} semantic models named {1} are in the workspace, not one.' -f $lookup.Count, $modelName) './scripts/deploy.ps1 deploys it (its Fabric track''s configure-powerbi.ps1).')
    }
    $refresh = Invoke-DemoSemanticModelRefresh -WorkspaceId $workspaceId -SemanticModelId $lookup.Id -Token $powerBIToken -TimeoutSeconds $RefreshTimeoutSeconds -TableRetryMinutes 0 -Confirm:$false
    $evidence['refreshStatus'] = [string]$refresh.status
    if ([string]$refresh.status -ne 'Pass') {
        $reported = if ([string]$refresh.status -eq 'Fail') { 'Fail' } else { '' }
        return (& $notRefreshed (ConvertTo-DemoPlainText -Value $refresh.message) (ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $refresh -Name 'remediation')) $reported)
    }

    # Pass, with what's still partial, said plainly (the user's decision).
    $evidence['incidentsPending'] = $true
    $partial = if ([bool]$ActivityProfile.HasIncidents) {
        'They''re partial for now: {0}''s incidents start only at the end of this run, after DONE''s checks, so incident measures such as Blocking Incidents stay blank until incidents have run and the notebook runs again (./scripts/stop-demo.ps1 -SaveHistory at the end of the session, {1}, or the next ./scripts/deploy.ps1).' -f $ActivityProfile.Name, $again
    }
    else {
        'They''re partial: the activity profile is {0}, with no incidents, so incident measures such as Blocking Incidents stay blank; after an incident (./scripts/demo-control.ps1), run {1}.' -f $ActivityProfile.Name, $again
    }
    $checkedNote = if ($ModelCheckedBefore) { ' This run''s FABRIC.SEMANTICMODEL.* checks ran before this snapshot; ./scripts/configure-powerbi.ps1 -CheckModelData checks the measures again.' } else { '' }
    return (& $answer 'Pass' 'Saved' ('Saved the history report''s snapshots: {0}, and the history model was refreshed, so the report shows them. {1}{2}' -f $saved, $partial, $checkedNote))
}

function Invoke-DemoHistorySnapshotStep {
    <#
    .SYNOPSIS
    deploy.ps1's last step (2026-11-06): NB_DatabaseHub_LiveActivity once, analyze-only, then the history model's refresh,
    so the history report shows the deployment's data. Returns one DEPLOY.FABRIC.HISTORY record, never a Fail or Manual
    action required, and shows it on the status page's Fabric.History row. Internal.

    .DESCRIPTION
    Both deployment paths call it at the end of a run that reaches its validation, after DONE's checks and the switch to
    the run's activity profile (Send-DemoPendingActivitySwitch): the notebook doesn't touch the VMs, so the switch doesn't
    wait for Spark, and DONE's checks have read what they need. A -WhatIf run calls it with -WhatIfRun. A resumed run that
    has nothing left to do runs it again: each run saves its own rows (the notebook replaces a run's rows only when that
    run saves again), so another snapshot only adds what happened since, such as incidents.

    - Not selected (Get-DemoHistorySnapshotSkip): -WhatIfRun, -SkipFabric, GitHub Actions (-Environment, read with
      Get-DemoRunEnvironment when it isn't given), DONE's checks that didn't run (-DoneChecked), or DONE's telemetry
      checks that didn't pass (-Requirement, -Result); the row is Skipped with the reason.
    - Otherwise Invoke-DemoHistorySnapshotRun, with Get-DemoHistorySnapshotParameter's analyze-only parameters: Pass, or
      a Warning with its reason and fix, also when the capacity is paused or the job outlives -TimeoutMinutes; an error
      (evidence reportedStatus Fail) shows the row Failed, any other Warning Action needed, and the console says so at
      once. An exception becomes that Warning too; only a stop of the run (Ctrl+C) goes through.
    Every record carries evidence nonBlocking historySnapshot (Test-DemoNonBlockingResult); DONE, NOT DONE, DEPLOY.SUMMARY,
    and the status page's Needs attention box list one that didn't work (Get-DemoHistorySnapshotItem).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowEmptyCollection()]
        [string[]] $Requirement = @(),

        [switch] $DoneChecked,

        [switch] $SkipFabric,

        [switch] $WhatIfRun,

        [AllowNull()]
        [object] $Environment = $null,

        [AllowNull()]
        [object] $ActivityProfile = $null,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [ValidateRange(1, 60)]
        [int] $TimeoutMinutes = 10,

        [ValidateRange(15, 10080)]
        [int] $WindowMinutes = 1440,

        [ValidateRange(30, 3600)]
        [int] $RefreshTimeoutSeconds = 300,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 15
    )

    $rowId = $script:HistorySnapshotRowId
    $record = {
        param([pscustomobject] $Answer)
        $evidence = [ordered]@{ nonBlocking = 'historySnapshot'; outcome = [string]$Answer.Outcome; notebook = $script:HistorySnapshotNotebook }
        if ([string]$Answer.ReportedStatus) {
            $evidence['reportedStatus'] = [string]$Answer.ReportedStatus
        }
        $more = $Answer.Evidence
        if ($more -is [System.Collections.IDictionary]) {
            foreach ($key in $more.Keys) {
                $evidence[[string]$key] = $more[$key]
            }
        }
        New-DemoResult -CheckId $script:HistorySnapshotCheckId -Area 'fabric' -Target 'fabric' -Status ([string]$Answer.Status) -Message ([string]$Answer.Message) -Evidence $evidence -Remediation ([string]$Answer.Remediation) -DocUrl 'https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job'
    }

    if ($null -eq $Environment -and -not $WhatIfRun -and -not $SkipFabric) {
        $Environment = Get-DemoRunEnvironment
    }
    $gitHubActions = [bool](Get-DemoMemberValue -InputObject $Environment -Name 'GitHubActions')
    $skip = Get-DemoHistorySnapshotSkip -Result $Result -Requirement $Requirement -DoneChecked:$DoneChecked -SkipFabric:$SkipFabric -WhatIfRun:$WhatIfRun -GitHubActions:$gitHubActions
    if ($null -ne $skip) {
        Set-DemoProgressStep -Path $ProgressPath -Id $rowId -State 'Skipped' -Status 'Not selected' -Message ([string]$skip.Message) -MaxLength 1200
        return (& $record ([pscustomobject]@{ Status = 'Not selected'; Outcome = 'NotSelected'; Message = $skip.Message; Remediation = $skip.Remediation; ReportedStatus = ''; Evidence = @{} }))
    }

    if ($null -eq $ActivityProfile) {
        $ActivityProfile = Get-DemoActivityProfile -Config $Config
    }
    $parameters = Get-DemoHistorySnapshotParameter -Config $Config -WindowMinutes $WindowMinutes
    # T4's and its read replica's Azure Monitor metrics (2026-11-13, ADR 0025): the notebook can't read Azure Monitor, so they
    # come with the run (POSTGRES_METRICS); without them it saves the SQL targets' history as before.
    try {
        $capture = Get-DemoPostgresHistoryCapture -Config $Config -WindowMinutes $WindowMinutes
        if ($null -ne $capture -and [string]$capture.Json) {
            $parameters['POSTGRES_METRICS'] = [string]$capture.Json
        }
    }
    catch {
        Write-DemoLog -Level Warning -Message ('T4''s metrics weren''t captured for the history snapshot: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    $sent = [ordered]@{ CONFIRM = $false; STOP_ACTIVITY = $false; SAVE_RESULTS = $true; WINDOW_MINUTES = $WindowMinutes; KEY_VAULT_URL = ''; POSTGRES_METRICS = $(if ($parameters.Contains('POSTGRES_METRICS')) { 'sent' } else { '' }) }
    $modelChecked = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -like 'FABRIC.SEMANTICMODEL.*' }).Count -gt 0
    try {
        Set-DemoProgressStep -Path $ProgressPath -Id $rowId -State 'Running' -Message ('{0} runs once, analyze-only (CONFIRM false: no activity request), and saves the last {1} minutes to the lakehouse; Spark''s start and the analysis take about 2 to 5 minutes, at most {2} here. Then the history model is refreshed. It doesn''t block DONE.' -f $script:HistorySnapshotNotebook, $WindowMinutes, $TimeoutMinutes)
        $answer = Invoke-DemoHistorySnapshotRun -Config $Config -Parameter $parameters -ActivityProfile $ActivityProfile -ModelCheckedBefore:$modelChecked -ProgressPath $ProgressPath -TimeoutMinutes $TimeoutMinutes -RefreshTimeoutSeconds $RefreshTimeoutSeconds -PollSeconds $PollSeconds
    }
    catch {
        # A stop of the run goes through; anything else is this step's own failure, which never blocks DONE.
        if ($_.Exception -is [System.Management.Automation.PipelineStoppedException] -or ($_.Exception -is [System.OperationCanceledException] -and (Test-DemoRunCancelled))) {
            throw
        }
        $network = Test-DemoNetworkFailure -Exception $_.Exception
        $fix = 'Run {0} to take it; it never blocks DONE.' -f $script:HistorySnapshotRunAgain
        $answer = [pscustomobject]@{
            Status         = 'Warning'
            Outcome        = 'Failed'
            Message        = ('The history snapshot stopped, so the history report got no snapshot: {0}' -f (Get-DemoExceptionText -Exception $_.Exception))
            Remediation    = $(if ($network) { '{0} {1}' -f (Get-DemoNetworkErrorNote), $fix } else { $fix })
            ReportedStatus = 'Fail'
            Evidence       = [ordered]@{ networkError = [bool]$network }
        }
    }
    $answer.Evidence['parameters'] = $sent
    $item = & $record $answer
    $state = switch ([string]$item.status) {
        'Pass' { 'Done' }
        'Not selected' { 'Skipped' }
        default { if ([string]$answer.ReportedStatus -eq 'Fail') { 'Failed' } else { 'Action needed' } }
    }
    $rowStatus = if ([string]$answer.ReportedStatus) { [string]$answer.ReportedStatus } else { [string]$item.status }
    $rowText = if ([string]$item.status -eq 'Warning' -and [string]$item.remediation) { '{0} {1}' -f [string]$item.message, [string]$item.remediation } else { [string]$item.message }
    Set-DemoProgressStep -Path $ProgressPath -Id $rowId -State $state -Status $rowStatus -Message $rowText -MaxLength 1200
    if ([string]$item.status -eq 'Warning') {
        # The console says so at once, as for the Insights app, and that the run goes on.
        Write-DemoLog -Level Warning -Message ('The history snapshot didn''t work; it doesn''t block DONE. {0} {1}' -f [string]$item.message, [string]$item.remediation)
    }
    return $item
}

function Get-DemoHistorySnapshotItem {
    <#
    .SYNOPSIS
    What DONE, NOT DONE, DEPLOY.SUMMARY, and the status page's Needs attention box say when deploy.ps1's history snapshot
    didn't work (2026-11-06): the latest DEPLOY.FABRIC.HISTORY that's neither Pass nor Not selected, as an item of
    Get-DemoNonBlockingItem (name, state, message, howTo), Failed for an error (evidence reportedStatus Fail) and Action
    needed otherwise, or $null. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $latest = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq $script:HistorySnapshotCheckId }) | Select-Object -Last 1
    if ($null -eq $latest -or [string]$latest.status -in 'Pass', 'Not selected') {
        return $null
    }
    $reported = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $latest -Name 'evidence') -Name 'reportedStatus')
    return [ordered]@{
        name    = 'the history report''s snapshot'
        state   = $(if ($reported -eq 'Fail') { 'Failed' } else { 'Action needed' })
        message = ConvertTo-DemoPlainText -Value $latest.message
        howTo   = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $latest -Name 'remediation')
    }
}
