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
    running; the evidence has its start time). Not selected without a configured workspace. It never pauses, resumes,
    or scales the capacity; a paused capacity fails the submit, and the message says so.

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
    How long to wait for the job.

    .PARAMETER PollSeconds
    Seconds between reads of the job instance.

    .EXAMPLE
    Invoke-DemoFabricNotebookRun -Config $config -Name NB_DatabaseHub_LiveActivity -Parameter @{ SAVE_RESULTS = $true; WINDOW_MINUTES = 1440 }
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
        [int] $PollSeconds = 20
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
    if ($found.StatusCode -ne 200 -or @($found.Items).Count -ne 1) {
        $why = if ($found.StatusCode -ne 200) { 'the workspace couldn''t be read ({0})' -f $found.Error } else { 'it isn''t in the workspace' }
        return (& $result 'Fail' ('{0} didn''t run: {1}.' -f $Name, $why) @{} 'Import the notebooks first: ./scripts/configure-fabric.ps1 -SkipHubChecks.')
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
    # IDs are named in the log, never shown.
    Write-DemoLog -Message ('Running {0} on demand ({1}).' -f $Name, (($parameters.Keys | ForEach-Object { if ($_ -like '*_ID') { '{0}=(resolved)' -f $_ } else { '{0}={1}' -f $_, $parameters[$_].value } }) -join ', '))
    $submit = Invoke-DemoFabricRequest -Method 'Post' -Uri $submitUri -Token $Token -Body $body
    if ($submit.StatusCode -ne 202) {
        return (& $result 'Fail' ('{0} wasn''t started: HTTP {1}, {2}' -f $Name, $submit.StatusCode, (Get-DemoFabricErrorText -Response $submit)) @{} 'Check that the workspace''s capacity is running (the scripts never resume it), then run the notebook again.')
    }
    $location = [string](Get-DemoFabricHeaderValue -Headers $submit.Headers -Name 'Location')
    if (-not $location.StartsWith($script:FabricApiBaseUri + '/', [System.StringComparison]::Ordinal)) {
        return (& $result 'Warning' ('{0} was accepted, but the response had no job location to follow; check its run in the workspace.' -f $Name))
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'NotStarted'
    $state = $null
    $maxPolls = [int][System.Math]::Ceiling($TimeoutMinutes * 60.0 / $PollSeconds)
    for ($poll = 1; $poll -le $maxPolls; $poll++) {
        Start-Sleep -Seconds $PollSeconds
        $read = Invoke-DemoFabricRequest -Method 'Get' -Uri $location -Token $Token
        if ($read.StatusCode -ne 200) {
            continue
        }
        $state = $read.Body
        $status = [string](Get-DemoMemberValue -InputObject $state -Name 'status')
        if ($status -in 'Completed', 'Failed', 'Cancelled', 'Deduped') {
            break
        }
    }
    $evidence = [ordered]@{
        notebook     = $Name
        status       = $status
        seconds      = [int]$watch.Elapsed.TotalSeconds
        startTimeUtc = [string](Get-DemoMemberValue -InputObject $state -Name 'startTimeUtc')
        endTimeUtc   = [string](Get-DemoMemberValue -InputObject $state -Name 'endTimeUtc')
        parameters   = @($parameters.Keys)
    }
    switch ($status) {
        'Completed' {
            return (& $result 'Pass' ('{0} ran on demand and completed in about {1:N0} seconds.' -f $Name, $watch.Elapsed.TotalSeconds) $evidence)
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
