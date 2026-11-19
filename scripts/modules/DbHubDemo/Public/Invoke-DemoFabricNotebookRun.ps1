function Invoke-DemoFabricNotebookRun {
    <#
    .SYNOPSIS
    Runs a demo notebook in the configured Fabric workspace on demand and waits for it to finish (Phase 20).

    .DESCRIPTION
    Finds the notebook by name (Find-DemoFabricItem), submits Run On Demand Item Job with jobType RunNotebook and the
    given parameters in executionData.parameters (each as { value, type }; they override the notebook's parameters
    cell), then reads the job instance at the Location the API returns, every -PollSeconds, until it's Completed,
    Failed, Cancelled, or Deduped, or -TimeoutMinutes passes. The repo's notebooks hold no Fabric IDs (ADR 0021), so
    every run also passes WORKSPACE_ID and LAKEHOUSE_ID from the configuration that Resolve-DemoFabricConfig resolved,
    unless -Parameter sets them; the log names them without showing them.

    Returns FABRIC.NOTEBOOKRUN.<NAME>: Pass when the job completed; Fail when it failed or was cancelled, with the
    failure reason; Warning when another run was already in progress (Deduped) or the wait ran out (the job keeps
    running; the evidence has its start time and, since 2026-11-19, its location, jobLocation, which deploy.ps1 follows
    for a first history run, #68). Evidence queuedSeconds says how long the job waited in the capacity's queue. Not
    selected without a configured workspace. It never pauses, resumes,
    or scales the capacity; a paused capacity fails the submit, and the message says so. When the notebook couldn't be
    looked up, the list's error isn't a missing notebook (live finding, 2026-11-10): a paused or inactive capacity is
    Manual action required, with the resume as the fix, and any other error a Fail whose fix is to run it again.

    The token comes from the Azure CLI after the subscription guard (Get-DemoFabricToken), unless -Token is passed.

    Sources (checked 2026-10-22):
    - Run On Demand Item Job: https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job
    - Get Item Job Instance: https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/get-item-job-instance
    - Run a notebook on demand with parameters: https://learn.microsoft.com/fabric/data-engineering/notebook-public-api

    .PARAMETER Config
    Configuration from Get-DemoConfig, resolved by Resolve-DemoFabricConfig: the subscription, tenant, azureAccount,
    fabric.workspaceId, and fabric.lakehouseId.

    .PARAMETER Name
    The notebook: NB_DatabaseHub_Deployment or NB_DatabaseHub_LiveActivity.

    .PARAMETER Parameter
    Notebook parameters by name. A [bool] is sent as type bool, an [int] or [long] as int, anything else as string.

    .PARAMETER Token
    A Fabric REST API token you already have, as a SecureString.

    .PARAMETER TimeoutMinutes
    How long to wait for the job, in elapsed time, the reads included.

    .PARAMETER PollSeconds
    Seconds between reads of the job instance.

    .PARAMETER ProgressPath
    The status page's model (deploy-progress.json): while the job is queued on the capacity or runs, its -ProgressId row
    says so, with the minutes so far and -TimeoutMinutes (#68). Nothing without it.

    .PARAMETER ProgressId
    The status page's row for -ProgressPath.

    .PARAMETER ProgressNote
    What that row adds after the wait, such as what comes once the job completes.

    .EXAMPLE
    Invoke-DemoFabricNotebookRun -Config $config -Name NB_DatabaseHub_LiveActivity -Parameter @{ CONFIRM = $false; STOP_ACTIVITY = $false; SAVE_RESULTS = $true; WINDOW_MINUTES = 1440; RESOURCE_GROUP = 'rg-dbhub-demo' }

    Analyze-only (CONFIRM false: no activity request), scoped to the demo's resource group, which the notebook's queries
    filter on.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('NB_DatabaseHub_Deployment', 'NB_DatabaseHub_LiveActivity')]
        [string] $Name,

        [System.Collections.IDictionary] $Parameter = @{},

        [securestring] $Token,

        [ValidateRange(1, 120)]
        [int] $TimeoutMinutes = 30,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 20,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [AllowEmptyString()]
        [string] $ProgressId = '',

        [AllowEmptyString()]
        [string] $ProgressNote = ''
    )

    $checkId = 'FABRIC.NOTEBOOKRUN.{0}' -f $Name.ToUpperInvariant()
    $docUrl = 'https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job'
    $result = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '')
        New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl
    }

    $workspaceId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')
    if ($workspaceId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or $workspaceId -eq '00000000-0000-0000-0000-000000000000') {
        return (& $result 'Not selected' ('No Fabric workspace is configured (fabric.workspaceId), so {0} didn''t run.' -f $Name))
    }
    if ($null -eq $Token) {
        $Token = Get-DemoFabricToken -SubscriptionId ([string]$Config['subscriptionId'])
    }

    $found = Find-DemoFabricItem -WorkspaceId $workspaceId -DisplayName $Name -Type 'Notebook' -Token $Token
    if ($found.StatusCode -ne 200 -and (Test-DemoFabricCapacityInactiveText -Text ([string]$found.Error))) {
        # A list that failed isn't a missing notebook (live finding, 2026-11-10): a paused capacity is resumed by its owner.
        return (& $result 'Manual action required' ('{0} didn''t run: the workspace''s capacity is paused or inactive ({1}).' -f $Name, ([string]$found.Error).TrimEnd('.', ' ')) @{} (Get-DemoFabricCapacityResumeFix -Then 'run it again.'))
    }
    if ($found.StatusCode -ne 200 -or @($found.Items).Count -ne 1) {
        $why = if ($found.StatusCode -ne 200) { 'the workspace couldn''t be read ({0})' -f $found.Error } else { 'it isn''t in the workspace' }
        $fix = if ($found.StatusCode -ne 200) { 'Run it again in a few minutes: the workspace''s notebooks couldn''t be listed.' } else { 'Import the notebooks first: ./scripts/configure-fabric.ps1 -SkipHubChecks.' }
        return (& $result 'Fail' ('{0} didn''t run: {1}.' -f $Name, $why) @{} $fix)
    }
    $itemId = [string](Get-DemoMemberValue -InputObject @($found.Items)[0] -Name 'id')

    $parameters = [ordered]@{}
    # The notebooks' parameters cell holds no Fabric IDs (ADR 0021): every run passes the resolved workspace and
    # lakehouse, unless the caller set them itself.
    $runParameter = [ordered]@{}
    foreach ($key in @($Parameter.Keys)) {
        $runParameter[[string]$key] = $Parameter[$key]
    }
    $lakehouseId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'lakehouseId')
    if (-not $runParameter.Contains('WORKSPACE_ID')) {
        $runParameter['WORKSPACE_ID'] = $workspaceId
    }
    if (-not $runParameter.Contains('LAKEHOUSE_ID') -and $lakehouseId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -and $lakehouseId -ne '00000000-0000-0000-0000-000000000000') {
        $runParameter['LAKEHOUSE_ID'] = $lakehouseId
    }
    foreach ($key in @($runParameter.Keys | Sort-Object)) {
        $value = $runParameter[$key]
        $type = if ($value -is [bool]) { 'bool' } elseif ($value -is [int] -or $value -is [long]) { 'int' } else { 'string' }
        $text = if ($value -is [bool]) { ([string]$value).ToLowerInvariant() } else { [string]$value }
        $parameters[[string]$key] = [ordered]@{ value = $text; type = $type }
    }
    $body = [ordered]@{ executionData = [ordered]@{ parameters = $parameters } }
    $submitUri = '{0}/workspaces/{1}/items/{2}/jobs/instances?jobType=RunNotebook' -f $script:FabricApiBaseUri, $workspaceId, $itemId
    # IDs are named in the log, never shown, and a long value (POSTGRES_METRICS, T4's metrics as JSON, 2026-11-13) by its size.
    Write-DemoLog -Message ('Running {0} on demand ({1}).' -f $Name, (($parameters.Keys | ForEach-Object { if ($_ -like '*_ID') { '{0}=(resolved)' -f $_ } elseif ($parameters[$_].value.Length -gt 200) { '{0}=({1:N0} characters)' -f $_, $parameters[$_].value.Length } else { '{0}={1}' -f $_, $parameters[$_].value } }) -join ', '))
    # A second submit would start a second run, so it's sent again only when it never reached the service.
    $submit = Invoke-DemoFabricRequest -Method 'Post' -Uri $submitUri -Token $Token -Body $body -NotIdempotent
    if ($submit.StatusCode -ne 202) {
        return (& $result 'Fail' ('{0} wasn''t started: HTTP {1}, {2}' -f $Name, $submit.StatusCode, (Get-DemoFabricErrorText -Response $submit)) @{} 'Check that the workspace''s capacity is running (the scripts never resume it), then run the notebook again.')
    }
    $location = [string](Get-DemoFabricHeaderValue -Headers $submit.Headers -Name 'Location')
    if (-not $location.StartsWith($script:FabricApiBaseUri + '/', [System.StringComparison]::Ordinal)) {
        return (& $result 'Warning' ('{0} was accepted, but the response had no job location to follow; check its run in the workspace.' -f $Name))
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    # Wait-DemoFabricNotebookJob: elapsed time bounds the polls, the reads included, and the status page's -ProgressId row
    # says while the job is queued on the capacity or runs (#68).
    $wait = Wait-DemoFabricNotebookJob -Location $location -Token $Token -Name $Name -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds -ProgressPath $ProgressPath -ProgressId $ProgressId -ProgressNote $ProgressNote
    $status = [string]$wait.Status
    $state = $wait.State
    $evidence = [ordered]@{
        notebook      = $Name
        status        = $status
        seconds       = [int]$wait.Seconds
        queuedSeconds = [int]$wait.QueuedSeconds
        startTimeUtc  = [string](Get-DemoMemberValue -InputObject $state -Name 'startTimeUtc')
        endTimeUtc    = [string](Get-DemoMemberValue -InputObject $state -Name 'endTimeUtc')
        parameters    = @($parameters.Keys)
    }
    if ($status -notin 'Completed', 'Failed', 'Cancelled', 'Deduped') {
        # The job keeps running: deploy.ps1 follows a first history run from here (Invoke-DemoHistoryFirstRunFollowUp).
        $evidence['jobLocation'] = $location
    }
    switch ($status) {
        'Completed' {
            if ($wait.QueuedSeconds -ge 60) {
                return (& $result 'Pass' ('{0} waited about {1} minutes in the capacity''s queue, then ran on demand and completed, about {2:N0} seconds in all.' -f $Name, [int][System.Math]::Round($wait.QueuedSeconds / 60.0), $wait.Seconds) $evidence)
            }
            return (& $result 'Pass' ('{0} ran on demand and completed in about {1:N0} seconds.' -f $Name, $(if ($wait.Seconds -gt 0) { $wait.Seconds } else { $watch.Elapsed.TotalSeconds })) $evidence)
        }
        'Deduped' {
            return (& $result 'Warning' ('{0} was already running, so this run was deduplicated; its results come from that run.' -f $Name) $evidence)
        }
        { $_ -in 'Failed', 'Cancelled' } {
            $reason = Get-DemoMemberValue -InputObject $state -Name 'failureReason'
            $text = [string](Get-DemoMemberValue -InputObject $reason -Name 'message')
            return (& $result 'Fail' ('{0} {1}: {2}' -f $Name, $status.ToLowerInvariant(), $(if ($text) { Protect-DemoText -Text $text } else { 'no reason was given' })) $evidence 'Open the notebook''s run in the workspace (Monitor hub) for the cell that failed, fix it, and run it again.')
        }
        default {
            return (& $result 'Warning' ('{0} is still {1} after {2} minutes; it keeps running. Check its run in the workspace (Monitor hub).' -f $Name, $status, $TimeoutMinutes) $evidence)
        }
    }
}
