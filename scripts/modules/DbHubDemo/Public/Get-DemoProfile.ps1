function Get-DemoProfile {
    <#
    .SYNOPSIS
    Returns the cost and performance profiles from config/profiles.json (ADR 0016).

    .EXAMPLE
    (Get-DemoProfile).profiles['lowest-cost'].t2Host.size
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Path = (Join-Path -Path $script:RepoRoot -ChildPath 'config/profiles.json')
    )

    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable)
}
