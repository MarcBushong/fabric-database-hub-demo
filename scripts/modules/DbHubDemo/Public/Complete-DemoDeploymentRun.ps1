function Complete-DemoDeploymentRun {
    <#
    .SYNOPSIS
    Ends one deploy.ps1 run's experience (Phase 28): decides DONE or NOT DONE (Get-DemoDeploymentOutcome), records it in
    the progress model with the optional items, stops the status page's writer, and writes the page a last time.

    .DESCRIPTION
    The outcome reads the resource group's state after the run (each track's last finished step), unless -State is
    given. Returns the outcome: Kind (Done, NotDone, or WhatIf), Done, Reason, Next, NextCommand, Optional, Unfinished,
    ExitCode, Resume, and Minutes. Never throws: a run that can't be judged is NOT DONE.

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
    group's state, so the ending takes no Azure call; a Ctrl+C that Enable-DemoRunCancelWatch recorded counts too. Steps
    still running on the status page go back to Pending with the reason (Phase 28 live finding).

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
    # Whether the guided stop was open when the run stopped: the model's guidedStop says so without an Azure call.
    $guidedOpen = $false
    if ($wasStopped -and $Run.ProgressPath) {
        try {
            $model = Read-DemoProgress -Path ([string]$Run.ProgressPath)
            $guidedOpen = $null -ne $model -and [string]$model['guidedStop']['state'] -in 'Preparing', 'Ready'
        }
        catch {
            $guidedOpen = $false
        }
    }
    try {
        $outcome = Get-DemoDeploymentOutcome -Result @($Result) -State $judgedState -Config $Config -Command ([string]$Run.Command) -WhatIfRun:$WhatIfRun -StopAfter $StopAfter -SkipFabric:$SkipFabric -Sequential:$Sequential -Stopped:$wasStopped -GuidedStopOpen:$guidedOpen
    }
    catch {
        $outcome = [pscustomobject]@{ Kind = 'NotDone'; Done = $false; Reason = ('The run couldn''t be judged: {0}' -f (Protect-DemoText -Text $_.Exception.Message)); Next = ('Run {0} again.' -f $Run.Command); NextCommand = [string]$Run.Command; Optional = @(); Unfinished = @(); ExitCode = 2; Resume = 'If this window closes or the PC restarts, run ./scripts/deploy.ps1 again; it continues where it stopped.' }
    }
    $minutes = [int][System.Math]::Round(([System.DateTime]::UtcNow - [datetime]$Run.StartedUtc).TotalMinutes)
    $outcome | Add-Member -NotePropertyName 'Minutes' -NotePropertyValue $minutes -Force
    if ($Run.ProgressPath) {
        $runState = if ($outcome.Kind -eq 'Done') { 'Done' } else { 'NotDone' }
        # The notes are an array, which Get-DemoMemberValue returns whole: assigned first, then each note is its own item,
        # not "System.String[]" (Phase 28 live finding, 2026-10-30).
        $notes = Get-DemoMemberValue -InputObject $outcome -Name 'Notes'
        $reason = (@([string]$outcome.Reason) + @($notes) | Where-Object { $_ } | ForEach-Object { [string]$_ }) -join ' '
        Set-DemoProgressValue -Path $Run.ProgressPath -Section 'run' -Value ([ordered]@{ state = $runState; endedAt = (Get-DemoUnixTime); reason = $reason; next = [string]$outcome.Next; nextCommand = [string]$outcome.NextCommand; exitCode = [int]$outcome.ExitCode })
        Set-DemoProgressValue -Path $Run.ProgressPath -Section 'optional' -Value @($outcome.Optional)
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
    # The run is over: a later Ctrl+C in this session belongs to another command.
    Disable-DemoRunCancelWatch
    return $outcome
}
