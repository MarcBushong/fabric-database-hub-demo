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

    In a subscription that already has the environment (issue 60, 2026-11-18), Initialize-DemoConfig writes the
    configuration from what's deployed when it's yours, and names a new environment, with a free prefix, when it isn't
    (INIT.EXISTING). Note is then its one line, which deploy.ps1 puts on its start banner and its status page; the WHAT IF
    ending says it too.

    Returns Ran, Ready, Results, Path, NextSteps, Outcome, and Note.

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

    $full = Resolve-DemoUserPath -Path $ConfigPath
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        return [pscustomobject]@{ Ran = $false; Ready = $true; Results = @(); Path = $full; NextSteps = @(); Outcome = $null; Note = @() }
    }
    if ($null -eq $Environment) {
        $Environment = Get-DemoRunEnvironment
    }
    $dryRun = -not $PSCmdlet.ShouldProcess($full, 'Write the demo configuration, as init.ps1 does')
    $command = Get-DemoDeployCommand -ConfigPath $full
    Write-DemoLog -Message 'No configuration yet, so deploy.ps1 writes it first, as ./scripts/init.ps1 does: it reads your Azure CLI sign-in (it never signs in for you), asks only when there''s a real choice, and creates the admin group when it''s missing. When this subscription already has the environment, it writes it from what''s deployed if it''s yours, and picks a new prefix if it isn''t.'
    $init = Initialize-DemoConfig -Path $full -CreateAdminGroup -NonInteractive:(-not [bool]$Environment.Interactive) -WhatIf:$dryRun -Confirm:$false
    $results = @($init.Results)
    $existing = Get-DemoMemberValue -InputObject $init -Name 'Existing'
    $note = @([string](Get-DemoMemberValue -InputObject $existing -Name 'Note') | Where-Object { $_ })
    $open = @($results | Where-Object { [string]$_.status -in 'Fail', 'Manual action required' })
    # The run's own command, with its -ConfigPath (2026-11-19), so a copied command never deploys config/demo.config.json.
    $resume = 'If this window closes or the PC restarts, run {0} again; it continues where it stopped.' -f $command
    if ([bool]$init.Written -and $open.Count -eq 0) {
        Write-DemoLog -Message ('The configuration is written ({0}); deploy.ps1 goes on with the deployment.' -f (Split-Path -Path $full -Leaf))
        return [pscustomobject]@{ Ran = $true; Ready = $true; Results = $results; Path = $full; NextSteps = @($init.NextSteps); Outcome = $null; Note = $note }
    }
    $fails = @($open | Where-Object { [string]$_.status -eq 'Fail' })
    if ($dryRun) {
        $outcome = [pscustomobject]@{
            Kind        = 'WhatIf'
            Done        = $false
            Reason      = $(if ($fails.Count -gt 0) { 'What if: the first-run setup found a problem ({0}), so nothing would be deployed.' -f $fails[0].checkId } else { 'What if: deploy.ps1 would write the configuration first (the results above say what it would hold), then deploy. Nothing was written or deployed.{0}' -f $(if ($note.Count -gt 0) { ' ' + $note[0] } else { '' }) })
            Next        = ('Run {0} without -WhatIf to write the configuration and deploy.' -f $command)
            NextCommand = $command
            Notes       = @()
            Optional    = @()
            Unfinished  = @()
            Missing     = @()
            ExitCode    = $(if ($fails.Count -gt 0) { 1 } else { 0 })
            Resume      = $resume
        }
        return [pscustomobject]@{ Ran = $true; Ready = $false; Results = $results; Path = $full; NextSteps = @($init.NextSteps); Outcome = $outcome; Note = $note }
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
    return [pscustomobject]@{ Ran = $true; Ready = $false; Results = $results; Path = $full; NextSteps = @($init.NextSteps); Outcome = $outcome; Note = $note }
}
