function Export-DemoResult {
    <#
    .SYNOPSIS
    Writes validation results as JSON lines and, in GitHub Actions, as a job summary table.

    .DESCRIPTION
    Every line is redacted (Protect-DemoText). In GitHub Actions, where the workflows upload out/*.jsonl as
    artifacts and a public repository's artifacts and job summaries are public, the identifiers
    Register-DemoLogMask registered, any other GUID, and the T3 and T4 servers' random suffix are also written as
    *** (Protect-DemoLogText, ADR 0022). The results in memory keep their values.

    .EXAMPLE
    Export-DemoResult -Result $results -Path ./out/validation.jsonl
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [string] $Path
    )

    if ($Path) {
        $directory = Split-Path -Path $Path -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        $lines = foreach ($item in $Result) {
            Protect-DemoLogText -Text ($item | Select-Object -Property * -ExcludeProperty PSTypeName | ConvertTo-Json -Depth 8 -Compress)
        }
        Set-Content -LiteralPath $Path -Value $lines -Encoding utf8NoBOM
    }

    if ($env:GITHUB_STEP_SUMMARY) {
        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.AppendLine('| Check | Target | Status | Message |')
        [void]$builder.AppendLine('|---|---|---|---|')
        foreach ($item in $Result) {
            $message = (Protect-DemoLogText -Text ([string]$item.message)).Replace('*', '\*').Replace('|', '\|')
            [void]$builder.AppendLine("| $($item.checkId) | $($item.target) | $($item.status) | $message |")
        }
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $builder.ToString() -Encoding utf8NoBOM
    }
}
