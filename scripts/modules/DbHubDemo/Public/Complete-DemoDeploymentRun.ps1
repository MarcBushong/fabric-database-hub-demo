function Complete-DemoDeploymentRun {
    <#
    .SYNOPSIS
    Ends one deploy.ps1 run's experience (Phase 28): decides DONE or NOT DONE (Get-DemoDeploymentOutcome), records it in
    the progress model with what didn't work but never blocks DONE (the Insights app; 2026-11-05), stops the status
    page's writer, and writes the page a last time.

    .DESCRIPTION
    The outcome reads the resource group's state after the run (each track's last finished step), unless -State is
    given. While T4 runs at a fallback size (DbHubT4Size Standard_D4ads_v5 or Standard_D2ds_v5), its hourly list price comes from
    this run's DEPLOY.T4.SKU, or from the Azure Retail Prices API now, for the note DONE and NOT DONE add (Phase 28
    follow-up). The note says T4 was created only with evidence that its server exists: this run's results, the T4
    track's record, or else a Servers - Get (review of 20e855c), which also decides when this run's template failed or
    T4.SERVER failed, since neither means the server is missing (review of 64c28b2). Returns the outcome: Kind (Done,
    NotDone, or WhatIf), Done, Reason, Next, NextCommand, NonBlocking, Unfinished, ExitCode, Resume, and Minutes. Never
    throws: a run that can't be judged is NOT DONE. The Insights app's sign-in, when it still runs because the run ended
    before it settled (Start-DemoFabricAppSignIn), is ended too.

    .PARAMETER Run
    What Start-DemoDeploymentRun returned.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Result
    The run's results.

    .PARAMETER State
    The deployment state to judge by; read from the resource group when it isn't given.

    .PARAMETER WhatIfRun
    The run was a what-if (deploy.ps1 -WhatIf).

    .PARAMETER StopAfter
    The run's -StopAfter.

    .PARAMETER SkipFabric
    The run skipped the Fabric track.

    .PARAMETER Sequential
    The run was deploy.ps1 -Sequential: judged by its recorded stage, since it records no tracks.

    .PARAMETER Stopped
    The run was stopped (Ctrl+C) before it finished: NOT DONE with the resume command, without reading the resource
    group's state, so the ending takes no Azure call but the switch below; a Ctrl+C that Enable-DemoRunCancelWatch recorded
    counts too. Steps still running on the status page go back to Pending with the reason (Phase 28 live finding).

    Whatever the outcome, a run that ended before its own switch (Ctrl+C, an error) sends it now, without waiting: the VMs
    it left on the interim baseline get the run's activity profile, so none stays on the baseline (2026-11-03, ADR 0010;
    Send-DemoPendingActivitySwitch). That takes a few seconds; a run that switched already sends nothing.

    .EXAMPLE
    $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result $results
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Run,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [object] $State,

        [switch] $WhatIfRun,

        [AllowEmptyString()]
        [string] $StopAfter = '',

        [switch] $SkipFabric,

        [switch] $Sequential,

        [switch] $Stopped
    )

    $wasStopped = [bool]$Stopped -or (-not $WhatIfRun -and (Test-DemoRunCancelled))
    # The run ended before its switch (Ctrl+C, an error): what it left on the interim baseline gets its activity profile
    # now, sent without waiting (2026-11-03). Nothing is pending after a run that switched.
    if (-not $WhatIfRun) {
        $runProfile = Get-DemoActivityProfile -Config $Config
        try {
            $null = Send-DemoPendingActivitySwitch -Config $Config -ActivityProfile $runProfile -Result @($Result) -CheckPrefix 'DEPLOY' -RequestedBy 'deploy' -NoWait
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The switch from the interim baseline couldn''t be sent: {0}. Set the profile with ./scripts/demo-control.ps1 -Target all -Scenario {1} -Duration 240.' -f (Protect-DemoText -Text $_.Exception.Message), $runProfile.Name)
        }
    }
    $judgedState = $State
    if (-not $PSBoundParameters.ContainsKey('State') -and -not $WhatIfRun -and -not $wasStopped) {
        try {
            $judgedState = Get-DemoDeploymentState -Config $Config
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The deployment state couldn''t be read to judge the run: {0}' -f $_.Exception.Message)
            $judgedState = $null
        }
    }
    # What this run started or created: the model says so without an Azure call.
    $model = $null
    if ($Run.ProgressPath) {
        try {
            $model = Read-DemoProgress -Path ([string]$Run.ProgressPath)
        }
        catch {
            $model = $null
        }
    }
    try {
        $startedVms = @(Get-DemoStartedVm -Result @($Result) -Model $model)
        # T4 at a fallback size is said with its hourly list price (ADR 0019): this run's, or read
        # from the Azure Retail Prices API now. It says "created" only with evidence that the server exists (review of
        # 20e855c): this run's results or the T4 track's record, or else a Servers - Get, which also decides after a failed
        # template or a T4.SERVER Fail: neither means the server is missing (review of 64c28b2).
        $t4Hourly = $null
        $t4Created = $null
        $t4Why = ''
        $t4Notice = ''
        if (-not $wasStopped -and -not $WhatIfRun -and (Test-DemoT4FallbackSize -Config $Config -State $judgedState)) {
            $priced = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'DEPLOY.T4.SKU' -and $null -ne (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'evidence') -Name 'hourlyUsd') }) | Select-Object -Last 1
            $t4Hourly = if ($null -ne $priced) { [double](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $priced -Name 'evidence') -Name 'hourlyUsd') } else { Get-DemoT4HourlyPrice -Config $Config -SkuName ([string](Get-DemoMemberValue -InputObject $judgedState -Name 'T4Sku')) }
            $t4Created = Get-DemoT4ServerEvidence -Result @($Result) -State $judgedState
            if ($null -eq $t4Created) {
                try {
                    $tags = Get-DemoMemberValue -InputObject $judgedState -Name 'Tags'
                    $deploymentId = if ($tags -is [System.Collections.IDictionary] -and [string]$tags['deploymentId'] -match '^[a-z0-9]{6}$') { [string]$tags['deploymentId'] } else { '' }
                    $server = Get-DemoT4State -Config $Config -DeploymentId $deploymentId
                    if ($server.Exists) {
                        $t4Created = $true
                    }
                    elseif ([string]$server.State -eq 'NotFound') {
                        $t4Created = $false
                    }
                }
                catch {
                    Write-DemoLog -Level Warning -Message ('Whether T4''s server exists couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
                }
            }
            if ($t4Created -is [bool] -and -not $t4Created -and @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'DEPLOY.TEMPLATE' -and [string]$_.status -eq 'Fail' }).Count -gt 0) {
                $t4Why = 'this run''s template deployment failed (DEPLOY.TEMPLATE says why)'
            }
            # The size change's notice (2026-11-09, user-directed): what was tried and refused, what was deployed, and both
            # monthly estimates with their difference, from this run's DEPLOY.T4.FALLBACK. A later run keeps the shorter
            # note, and status.ps1 gives the whole notice for it (STATUS.T4.SIZE).
            $change = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'DEPLOY.T4.FALLBACK' }) | Select-Object -Last 1
            if ($null -ne $change) {
                $t4Notice = [string]$change.message
            }
        }
        $outcome = Get-DemoDeploymentOutcome -Result @($Result) -State $judgedState -Config $Config -Command ([string]$Run.Command) -WhatIfRun:$WhatIfRun -StopAfter $StopAfter -SkipFabric:$SkipFabric -Sequential:$Sequential -Stopped:$wasStopped -StartedVm $startedVms -T4HourlyUsd $t4Hourly -T4Created $t4Created -T4Why $t4Why -T4Notice $t4Notice
    }
    catch {
        $outcome = [pscustomobject]@{ Kind = 'NotDone'; Done = $false; Reason = ('The run couldn''t be judged: {0}' -f (Protect-DemoText -Text $_.Exception.Message)); Next = ('Run {0} again.' -f $Run.Command); NextCommand = [string]$Run.Command; NonBlocking = @(); Unfinished = @(); ExitCode = 2; Resume = 'If this window closes or the PC restarts, run ./scripts/deploy.ps1 again; it continues where it stopped.' }
    }
    $minutes = [int][System.Math]::Round(([System.DateTime]::UtcNow - [datetime]$Run.StartedUtc).TotalMinutes)
    $outcome | Add-Member -NotePropertyName 'Minutes' -NotePropertyValue $minutes -Force
    # What runs now, and how to choose the other profile: DONE's "Activity:" line, on the console and the status page.
    $activityLine = ''
    try {
        $activityLine = Get-DemoActivitySummaryLine -ActivityProfile (Get-DemoActivityProfile -Config $Config)
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The activity line couldn''t be built: {0}' -f $_.Exception.Message)
    }
    $outcome | Add-Member -NotePropertyName 'Activity' -NotePropertyValue $activityLine -Force
    if ($Run.ProgressPath) {
        $runState = if ($outcome.Kind -eq 'Done') { 'Done' } else { 'NotDone' }
        # The notes are an array, which Get-DemoMemberValue returns whole: assigned first, then each note is its own item,
        # not "System.String[]" (Phase 28 live finding, 2026-10-30).
        $notes = Get-DemoMemberValue -InputObject $outcome -Name 'Notes'
        $reason = (@([string]$outcome.Reason) + @($notes) | Where-Object { $_ } | ForEach-Object { [string]$_ }) -join ' '
        Set-DemoProgressValue -Path $Run.ProgressPath -Section 'run' -Value ([ordered]@{ state = $runState; endedAt = (Get-DemoUnixTime); reason = $reason; next = [string]$outcome.Next; nextCommand = [string]$outcome.NextCommand; exitCode = [int]$outcome.ExitCode; activity = $activityLine })
        # What didn't work but never blocks DONE (the Insights app), with its error and fix (2026-11-05).
        $nonBlockingValue = Get-DemoMemberValue -InputObject $outcome -Name 'NonBlocking'
        Set-DemoProgressValue -Path $Run.ProgressPath -Section 'nonBlocking' -Value @(@($nonBlockingValue) | Where-Object { $null -ne $_ })
        # What only a person can confirm, once each, which never kept the run from DONE (Phase 28 live finding).
        $confirmValue = Get-DemoMemberValue -InputObject $outcome -Name 'Confirm'
        Set-DemoProgressValue -Path $Run.ProgressPath -Section 'confirm' -Value @(@($confirmValue) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'text') })
        if ($outcome.Kind -eq 'Done') {
            Set-DemoProgressStep -Path $Run.ProgressPath -Id 'Validation' -State 'Done' -Message ('Done in {0} minutes.' -f $minutes)
        }
        elseif ($wasStopped) {
            Set-DemoProgressStopped -Path $Run.ProgressPath -Message ('Stopped here (Ctrl+C); {0} continues from this step.' -f $Run.Command)
        }
    }
    Stop-DemoProgressPageWriter -Job $Run.Writer -ModelPath ([string]$Run.ProgressPath) -PagePath ([string]$Run.PagePath)
    # A sign-in for the Insights app that still runs (the run ended or was stopped before it settled) ends with the run.
    Stop-DemoFabricAppSignIn
    # The run is over: a later Ctrl+C in this session belongs to another command.
    Disable-DemoRunCancelWatch
    return $outcome
}
