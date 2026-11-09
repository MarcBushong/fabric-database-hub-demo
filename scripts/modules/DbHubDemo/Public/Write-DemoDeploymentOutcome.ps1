function Write-DemoDeploymentOutcome {
    <#
    .SYNOPSIS
    Prints deploy.ps1's one ending (Phase 28, brief item 1): DONE, with where to look in Database Hub and what didn't
    work but never blocks DONE (the Insights app, with its actual error and how to fix it; 2026-11-05), or NOT DONE,
    with why, the single next action, the exact command, how to resume, and the diagnostics bundle. Every line is
    redacted.

    .PARAMETER Outcome
    What Complete-DemoDeploymentRun returned.

    .PARAMETER WorkspaceName
    The Fabric workspace, named in the DONE banner.

    .EXAMPLE
    Write-DemoDeploymentOutcome -Outcome $outcome
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Outcome,

        [string] $WorkspaceName = ''
    )

    $minutes = [int](Get-DemoMemberValue -InputObject $Outcome -Name 'Minutes')
    $color = switch ([string]$Outcome.Kind) { 'Done' { 'Green' } 'WhatIf' { 'Cyan' } default { 'Red' } }
    Write-DemoConsoleBlock -Color 'White' -Line @('')
    Write-DemoConsoleBlock -Color $color -Line (Get-DemoDeploymentOutcomeLine -Outcome $Outcome -Minutes $minutes -WorkspaceName $WorkspaceName)
}
