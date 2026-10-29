function Initialize-DemoFirstRun {
    <#
    .SYNOPSIS
    deploy.ps1's first-run setup (Phase 28, brief goal 1): with no configuration file yet, it writes one as init.ps1 does,
    so one command after 'az login' deploys everything.

    .DESCRIPTION
    Nothing happens when the file exists (Ran false, Ready true). Otherwise Initialize-DemoConfig runs with
    -CreateAdminGroup (the P6 admin group is created, owned by you, when it's missing and your tenant lets you create
    it; otherwise Manual action required with the steps for an administrator), with the same prompts as init.ps1, and
    with -NonInteractive where nobody can answer a prompt (CI, redirected input, an assistant): an ambiguous choice is
    then Manual action required, as in init.ps1.

    Ready is true when the file was written and no INIT result is Fail or Manual action required. Otherwise Outcome is
    the NOT DONE ending (Get-DemoDeploymentOutcomeLine's shape) with the first open item's fix and the exact command to
    run again; with -WhatIf nothing is written, and Outcome is the WHAT IF ending. It never signs in and never changes the
    Azure CLI context. init.ps1 keeps working on its own.

    Returns Ran, Ready, Results, Path, NextSteps, and Outcome.

    .PARAMETER ConfigPath
    The configuration file deploy.ps1 reads.

    .PARAMETER Environment
    Where deploy.ps1 runs (Get-DemoRunEnvironment); read when it isn't given.

    .EXAMPLE
    $firstRun = Initialize-DemoFirstRun -ConfigPath ./config/demo.config.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ConfigPath,

        [AllowNull()]
        [pscustomobject] $Environment = $null
    )

    $full = [System.IO.Path]::GetFullPath($ConfigPath)
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        return [pscustomobject]@{ Ran = $false; Ready = $true; Results = @(); Path = $full; NextSteps = @(); Outcome = $null }
    }
    if ($null -eq $Environment) {
        $Environment = Get-DemoRunEnvironment
    }
    $dryRun = -not $PSCmdlet.ShouldProcess($full, 'Write the demo configuration, as init.ps1 does')
    $command = Get-DemoDeployCommand -ConfigPath $full
    Write-DemoLog -Message 'No configuration yet, so deploy.ps1 writes it first, as ./scripts/init.ps1 does: it reads your Azure CLI sign-in (it never signs in for you), asks only when there''s a real choice, and creates the admin group when it''s missing.'
    $init = Initialize-DemoConfig -Path $full -CreateAdminGroup -NonInteractive:(-not [bool]$Environment.Interactive) -WhatIf:$dryRun -Confirm:$false
    $results = @($init.Results)
    $open = @($results | Where-Object { [string]$_.status -in 'Fail', 'Manual action required' })
    $resume = 'If this window closes or the PC restarts, run ./scripts/deploy.ps1 again; it continues where it stopped.'
    if ([bool]$init.Written -and $open.Count -eq 0) {
        Write-DemoLog -Message ('The configuration is written ({0}); deploy.ps1 goes on with the deployment.' -f (Split-Path -Path $full -Leaf))
        return [pscustomobject]@{ Ran = $true; Ready = $true; Results = $results; Path = $full; NextSteps = @($init.NextSteps); Outcome = $null }
    }
    $fails = @($open | Where-Object { [string]$_.status -eq 'Fail' })
    if ($dryRun) {
        $outcome = [pscustomobject]@{
            Kind        = 'WhatIf'
            Done        = $false
            Reason      = $(if ($fails.Count -gt 0) { 'What if: the first-run setup found a problem ({0}), so nothing would be deployed.' -f $fails[0].checkId } else { 'What if: deploy.ps1 would write the configuration first (the results above say what it would hold), then deploy. Nothing was written or deployed.' })
            Next        = 'Run ./scripts/deploy.ps1 without -WhatIf to write the configuration and deploy.'
            NextCommand = $command
            Notes       = @()
            Optional    = @()
            Unfinished  = @()
            Missing     = @()
            ExitCode    = $(if ($fails.Count -gt 0) { 1 } else { 0 })
            Resume      = $resume
        }
        return [pscustomobject]@{ Ran = $true; Ready = $false; Results = $results; Path = $full; NextSteps = @($init.NextSteps); Outcome = $outcome }
    }
    $first = $open | Select-Object -First 1
    $reason = if ($null -ne $first) { '{0}: {1}' -f $first.checkId, $first.message } else { 'The configuration wasn''t written.' }
    $fix = if ($null -ne $first -and [string]$first.remediation) { [string]$first.remediation } else { 'Read the first-run results above.' }
    $outcome = [pscustomobject]@{
        Kind        = 'NotDone'
        Done        = $false
        Reason      = ('The first-run setup needs you before anything is deployed. {0}' -f $reason)
        Next        = ('{0} Then run {1} again: it writes the configuration (when it isn''t there yet) and deploys.' -f $fix.TrimEnd(), $command)
        NextCommand = $command
        Notes       = @()
        Optional    = @()
        Unfinished  = @()
        Missing     = @()
        ExitCode    = $(if ($fails.Count -gt 0) { 1 } else { 2 })
        Resume      = $resume
    }
    return [pscustomobject]@{ Ran = $true; Ready = $false; Results = $results; Path = $full; NextSteps = @($init.NextSteps); Outcome = $outcome }
}
