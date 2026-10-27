function ConvertTo-DemoBatchArgument {
    <#
    .SYNOPSIS
    Quotes one argument so cmd.exe hands it unchanged to a batch-file wrapper such as az.cmd.

    .DESCRIPTION
    Internal. On Windows the Azure CLI entry point is az.cmd, so cmd.exe parses the command line before
    Python does, and PowerShell doesn't quote arguments that have no spaces. Unquoted, '&' and '|' end
    the command, '<' and '>' redirect, '^' disappears, and ')' closes the IF block inside az.cmd.
    Inside double quotes cmd.exe treats all of them as text, and Python's argument parser removes the
    quotes. cmd.exe can't pass '"' or '%' reliably even inside quotes, so an argument with either is
    refused; pass that content in a file with '@<path>' instead. The error never includes the value,
    because arguments can be protected.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Argument
    )

    if ($Argument.IndexOfAny([char[]]'"%') -ge 0) {
        throw "An Azure CLI argument contains '`"' or '%', which cmd.exe can't pass to az.cmd unchanged. Put the value in a file and pass '@<path>' instead."
    }
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s&|<>^()!,;=]') {
        return $Argument
    }

    # Backslashes right before the closing quote are doubled so the argument parser keeps them as text.
    $trailingBackslashes = [regex]::Match($Argument, '\\+$').Length
    return '"' + $Argument + ('\' * $trailingBackslashes) + '"'
}
