function Clear-DemoSecret {
    <#
    .SYNOPSIS
    Clears every secret registered with Register-DemoSecret.

    .DESCRIPTION
    Used by tests and at the end of long-running sessions. It doesn't unmask values that GitHub
    Actions already masked.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($PSCmdlet.ShouldProcess('registered demo secrets', 'Clear')) {
        $script:DemoSecrets.Clear()
    }
}
