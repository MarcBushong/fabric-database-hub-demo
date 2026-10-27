function Write-DemoResultReport {
    <#
    .SYNOPSIS
    Prints results as a table, logs the remediation of every Fail, Manual action required, and Warning, and
    in GitHub Actions also writes them to the job summary.

    .DESCRIPTION
    The scripts' shared ending (deploy.ps1, start-demo.ps1, stop-demo.ps1, status.ps1, destroy.ps1,
    demo-control.ps1, setup-github-oidc.ps1). Manual action required items are listed last with their exact
    steps, so they're never hidden (plan section 9.2). When GITHUB_STEP_SUMMARY is set, a Markdown table is
    appended to that file; messages are already redacted by New-DemoResult. In GitHub Actions, the table, the
    summary, and the log lines also show identifiers as *** (Protect-DemoLogText, ADR 0022).

    Source: https://docs.github.com/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary
    (checked 2026-10-20).

    .PARAMETER Result
    Results from New-DemoResult.

    .PARAMETER Title
    The heading for the job summary.

    .EXAMPLE
    Write-DemoResultReport -Result $results -Title 'deploy.ps1'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [Parameter(Mandatory)]
        [string] $Title
    )

    $items = @($Result | Where-Object { $null -ne $_ })
    Protect-DemoLogText -Text ($items | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220) | Write-Information -InformationAction Continue
    foreach ($item in $items | Where-Object { $_.status -in 'Fail', 'Warning' -and $_.remediation }) {
        Write-DemoLog -Level Warning -Message ('{0}: {1}' -f $item.checkId, $item.remediation)
    }
    $manual = @($items | Where-Object { $_.status -eq 'Manual action required' })
    if ($manual.Count -gt 0) {
        Write-DemoLog -Level Warning -Message ('{0} item(s) need you (Manual action required):' -f $manual.Count)
        foreach ($item in $manual) {
            $steps = if ($item.remediation) { $item.remediation } else { $item.message }
            Write-DemoLog -Level Warning -Message ('  {0}: {1}' -f $item.checkId, $steps)
        }
    }

    $summary = [string]$env:GITHUB_STEP_SUMMARY
    if ($summary) {
        $escape = { param([string] $Text) ((Protect-DemoLogText -Text $Text) -replace '\*', '\*' -replace '\|', '\|' -replace '[\r\n]+', ' ').Trim() }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add(('## {0}' -f $Title))
        $lines.Add('')
        $lines.Add('| Check | Status | Message |')
        $lines.Add('|---|---|---|')
        foreach ($item in $items) {
            $lines.Add(('| {0} | {1} | {2} |' -f (& $escape $item.checkId), (& $escape $item.status), (& $escape $item.message)))
        }
        if ($manual.Count -gt 0) {
            $lines.Add('')
            $lines.Add('### Manual action required')
            $lines.Add('')
            foreach ($item in $manual) {
                $lines.Add(('- **{0}:** {1}' -f $item.checkId, (& $escape $(if ($item.remediation) { $item.remediation } else { $item.message }))))
            }
        }
        $lines.Add('')
        [System.IO.File]::AppendAllText($summary, (($lines -join "`n") + "`n"))
    }
}
