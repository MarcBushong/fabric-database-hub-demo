function Invoke-DemoDeployScript {
    <#
    .SYNOPSIS
    Runs ./scripts/deploy.ps1 in this process with -ConfigPath and -FromStage, and returns its exit code (2026-11-21).

    .DESCRIPTION
    reset-demo.ps1 -RebuildGuest asks the T2 host for the rebuild of its guest (RESET.GUEST), then runs this, so the rebuild
    is one command: deploy.ps1 -FromStage Artifacts runs each VM's bootstrap loader, which starts the generation that acts on
    the request, follows the rebuild to its end (DEPLOY.T2.REBUILD), and ends DONE or NOT DONE with the next command, on its
    console and status page as any deploy.ps1 run. Its output goes to the host; only the exit code returns.

    .PARAMETER ConfigPath
    The demo configuration, as reset-demo.ps1 got it.

    .PARAMETER FromStage
    Artifacts: the first stage that runs the bootstrap loaders.

    .EXAMPLE
    Invoke-DemoDeployScript -ConfigPath ./config/demo.config.json -FromStage Artifacts
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $ConfigPath,

        [ValidateSet('Artifacts')]
        [string] $FromStage = 'Artifacts'
    )

    & (Join-Path -Path $script:RepoRoot -ChildPath 'scripts/deploy.ps1') -ConfigPath $ConfigPath -FromStage $FromStage | Out-Host
    return [int]$LASTEXITCODE
}
