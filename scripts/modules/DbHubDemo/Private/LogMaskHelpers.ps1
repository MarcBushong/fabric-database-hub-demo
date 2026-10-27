function Get-DemoLogMaskCandidate {
    <#
    .SYNOPSIS
    Every GUID-shaped and email-shaped string anywhere in a configuration (nested hashtables, objects, and
    lists): the identifiers Register-DemoLogMask -Config masks in GitHub Actions (ADR 0022). Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [object] $InputObject,

        [ValidateRange(0, 32)]
        [int] $Depth = 0
    )

    if ($null -eq $InputObject -or $Depth -gt 16) {
        return
    }
    if ($InputObject -is [string]) {
        $text = $InputObject.Trim()
        if ($text -match ('^\{?' + $script:DemoLogGuidPattern + '\}?$') -or $text -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            $text
        }
        return
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) {
            Get-DemoLogMaskCandidate -InputObject $InputObject[$key] -Depth ($Depth + 1)
        }
        return
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        foreach ($item in $InputObject) {
            Get-DemoLogMaskCandidate -InputObject $item -Depth ($Depth + 1)
        }
        return
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $InputObject.PSObject.Properties) {
            Get-DemoLogMaskCandidate -InputObject $property.Value -Depth ($Depth + 1)
        }
    }
}

function Protect-DemoLogText {
    <#
    .SYNOPSIS
    Protect-DemoText for what leaves the process: log lines, job summaries, and out/*.jsonl results. In GitHub
    Actions it also turns into *** every identifier Register-DemoLogMask registered, any other GUID, and the T3 and
    T4 servers' random suffix (azuresql01-*** and pgflex01-***), because a public repository's Actions logs and
    artifacts are public (ADR 0022). Elsewhere it's Protect-DemoText. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    $safe = Protect-DemoText -Text $Text
    if ([string]::IsNullOrEmpty($safe) -or $env:GITHUB_ACTIONS -ne 'true') {
        return $safe
    }
    foreach ($mask in $script:DemoLogMasks) {
        $safe = $safe.Replace($mask, '***', [System.StringComparison]::OrdinalIgnoreCase)
    }
    $safe = [regex]::Replace($safe, $script:DemoLogGuidPattern, '***')
    return [regex]::Replace($safe, '(?i)\b(azuresql01|pgflex01)-[a-z0-9]{6}\b', '$1-***')
}
