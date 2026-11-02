function Resolve-DemoUserPath {
    <#
    .SYNOPSIS
    Turns a path someone typed into an absolute file-system path, relative to PowerShell's current location.

    .DESCRIPTION
    .NET's file APIs resolve a relative path against the process's working directory
    ([System.Environment]::CurrentDirectory), which Set-Location and Push-Location don't change. So a script given
    ./config/proof.local.json after a cd into the repository would read or write a file in another directory (found
    while setting up Phase 28's live proof). Every script that takes a path (-ConfigPath, -OutputPath, and the rest)
    resolves it with this first, and so does the module wherever it turns such a path into an absolute one.

    Uses PathIntrinsics.GetUnresolvedProviderPathFromPSPath, so the file needn't exist yet; '..' and '~' are resolved,
    and an absolute path comes back normalized. An empty or whitespace path stays empty. A path that resolves outside
    the file system (for example while the current location is a registry key) throws.
    Source: https://learn.microsoft.com/dotnet/api/system.management.automation.pathintrinsics.getunresolvedproviderpathfrompspath
    (checked 2026-10-29).

    .PARAMETER Path
    One or more paths, absolute or relative to PowerShell's current location.

    .EXAMPLE
    $ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]] $Path
    )

    process {
        foreach ($item in @($Path)) {
            if ([string]::IsNullOrWhiteSpace($item)) {
                ''
                continue
            }
            $provider = $null
            $drive = $null
            $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($item, [ref]$provider, [ref]$drive)
            if ($null -eq $provider -or $provider.Name -ne 'FileSystem') {
                throw ("The path '{0}' isn't a file-system path from the current location ({1}). Change to a folder first, or give an absolute path." -f $item, $ExecutionContext.SessionState.Path.CurrentLocation)
            }
            $resolved
        }
    }
}
