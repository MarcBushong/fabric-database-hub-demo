function Enter-DemoKeepAwake {
    <#
    .SYNOPSIS
    Keeps this Windows PC and its display awake during a long run, such as a golden capture and its test
    (SetThreadExecutionState with ES_CONTINUOUS, ES_SYSTEM_REQUIRED, and ES_DISPLAY_REQUIRED: without the display
    flag, Modern Standby froze an earlier run). Exit-DemoKeepAwake ends it. Returns whether it took effect; on
    other platforms it does nothing and returns $false.

    .DESCRIPTION
    The setting belongs to the calling thread and lasts until Exit-DemoKeepAwake or the end of the PowerShell
    process. https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate

    .EXAMPLE
    $null = Enter-DemoKeepAwake; try { ... } finally { $null = Exit-DemoKeepAwake }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not $IsWindows) {
        return $false
    }
    if (-not ('DbHubDemo.KeepAwake' -as [type])) {
        Add-Type -Namespace 'DbHubDemo' -Name 'KeepAwake' -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    }
    # ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x1) | ES_DISPLAY_REQUIRED (0x2).
    return ([DbHubDemo.KeepAwake]::SetThreadExecutionState([uint32]2147483651) -ne 0)
}