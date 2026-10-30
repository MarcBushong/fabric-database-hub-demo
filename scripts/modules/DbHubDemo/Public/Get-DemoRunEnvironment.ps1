function Get-DemoRunEnvironment {
    <#
    .SYNOPSIS
    Where deploy.ps1 runs (Phase 28): GitHub Actions or another CI system, a session that takes keyboard input or not,
    GitHub Codespaces, and Windows.

    .DESCRIPTION
    Interactive is false in CI (CI, GITHUB_ACTIONS, or TF_BUILD set), in a host that isn't interactive, and when
    standard input is redirected, as when a script or an assistant drives the run. Codespaces follows the CODESPACES
    variable that GitHub Codespaces sets
    (https://docs.github.com/codespaces/developing-in-a-codespace/default-environment-variables-for-your-codespace).

    .EXAMPLE
    (Get-DemoRunEnvironment).Interactive
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $flag = {
        param([string] $Name)
        $value = [System.Environment]::GetEnvironmentVariable($Name)
        [bool]($value -and $value -notin 'false', '0')
    }
    return [pscustomobject]@{
        GitHubActions = [string]$env:GITHUB_ACTIONS -eq 'true'
        Ci            = (& $flag 'CI') -or (& $flag 'GITHUB_ACTIONS') -or (& $flag 'TF_BUILD')
        Interactive   = Test-DemoInteractiveSession
        Codespaces    = [string]$env:CODESPACES -eq 'true'
        Windows       = [bool]$IsWindows
    }
}
