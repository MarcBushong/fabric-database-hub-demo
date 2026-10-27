function Exit-DemoKeepAwake {
    <#
    .SYNOPSIS
    Lets this Windows PC sleep again after Enter-DemoKeepAwake (SetThreadExecutionState with ES_CONTINUOUS only).
    Returns whether it took effect; on other platforms it does nothing and returns $false.

    .EXAMPLE
    $null = Exit-DemoKeepAwake
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not $IsWindows -or -not ('DbHubDemo.KeepAwake' -as [type])) {
        return $false
    }
    return ([DbHubDemo.KeepAwake]::SetThreadExecutionState([uint32]2147483648) -ne 0)
}