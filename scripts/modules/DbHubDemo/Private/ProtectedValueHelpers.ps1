function Add-DemoProtectedValueLogHelper {
    <#
    .SYNOPSIS
    Inserts vm/bootstrap/ProtectedValueLog.ps1's functions (Disable-DemoSessionEventLog and
    Clear-DemoProtectedValueLog) into a Run Command's script, right after its param block, so the script can
    clear its own protected value from the Windows PowerShell log (ADR 0009, Phase 26f). Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ScriptText
    )

    $helper = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/ProtectedValueLog.ps1') -Raw
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($ScriptText, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        throw ('The Run Command script doesn''t parse: {0}' -f $errors[0].Message)
    }
    $offset = if ($null -ne $ast.ParamBlock) { $ast.ParamBlock.Extent.EndOffset } else { 0 }
    return ('{0}{1}{2}{1}{3}' -f $ScriptText.Substring(0, $offset), "`n", $helper.Trim(), $ScriptText.Substring($offset))
}

function Get-DemoProtectedValueLogResult {
    <#
    .SYNOPSIS
    Reads the line 'DBHUBDEMO-LOG found=<n> cleared=<True|False> error=<type>' that a Run Command script writes
    after Clear-DemoProtectedValueLog. Returns Found, Cleared, Error, and Reported (false when the script wrote
    no such line). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $Output = ''
    )

    $match = [regex]::Match($Output, 'DBHUBDEMO-LOG found=(\d+) cleared=(True|False) error=([A-Za-z.]*)')
    if (-not $match.Success) {
        return [pscustomobject]@{ Reported = $false; Found = 0; Cleared = $false; Error = '' }
    }
    return [pscustomobject]@{ Reported = $true; Found = [int]$match.Groups[1].Value; Cleared = $match.Groups[2].Value -eq 'True'; Error = $match.Groups[3].Value }
}
