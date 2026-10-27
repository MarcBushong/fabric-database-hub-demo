function Get-DemoExitCode {
    <#
    .SYNOPSIS
    Converts a set of validation results to a process exit code (ADR 0012).

    .DESCRIPTION
    0: no Fail. 1: at least one Fail. 2: no Fail but at least one "Manual action required",
    when -TreatManualAsError is set.

    .EXAMPLE
    exit (Get-DemoExitCode -Result $results)
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [switch] $TreatManualAsError
    )

    if (@($Result | Where-Object { $_.status -eq 'Fail' }).Count -gt 0) {
        return 1
    }

    if ($TreatManualAsError -and @($Result | Where-Object { $_.status -eq 'Manual action required' }).Count -gt 0) {
        return 2
    }

    return 0
}
