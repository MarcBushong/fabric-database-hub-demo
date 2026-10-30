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
    Warnings that share the same remediation, 3 or more of them, are logged as one line with their count, their check
    IDs' common prefix, and two examples (Phase 28 live run, 2026-10-30: about 58 blank-measure Warnings with the same
    remediation came right before the DONE banner); every Fail keeps its own line, and the table, the job summary, and
    the results the caller exports keep every result. A check ID with the same remediation (or, for Manual action
    required, the same steps) is logged once, however many sources reported it (Phase 28 live run, 2026-10-30:
    PREFLIGHT.FABRIC.VIEWERLICENSE twice).

    Source: https://docs.github.com/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary
    (checked 2026-10-20).

    .PARAMETER Result
    Results from New-DemoResult.

    .PARAMETER Title
    The heading for the job summary.

    .PARAMETER OutcomeDone
    deploy.ps1's run ended DONE: the heading of the Manual action required items says that none of them keeps it from
    DONE (what only a person can confirm, and the optional parts).

    .EXAMPLE
    Write-DemoResultReport -Result $results -Title 'deploy.ps1'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [Parameter(Mandatory)]
        [string] $Title,

        [switch] $OutcomeDone
    )

    $items = @($Result | Where-Object { $null -ne $_ })
    Protect-DemoLogText -Text ($items | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220) | Write-Information -InformationAction Continue
    # The same check with the same remediation from two sources (Phase 28 live run: PREFLIGHT.FABRIC.VIEWERLICENSE from
    # preflight and from the Fabric track) is logged once; a Fail's pair wins over the same Warning's.
    $pairOf = { param([object] $Item) '{0}|{1}' -f [string]$Item.checkId, [string]$Item.remediation }
    $candidates = @($items | Where-Object { $_.status -in 'Fail', 'Warning' -and $_.remediation })
    $failPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in @($candidates | Where-Object { $_.status -eq 'Fail' })) {
        $null = $failPairs.Add((& $pairOf $item))
    }
    $seenPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $open = @(foreach ($item in $candidates) {
            $pair = & $pairOf $item
            if (($item.status -eq 'Warning' -and $failPairs.Contains($pair)) -or -not $seenPairs.Add($pair)) {
                continue
            }
            $item
        })
    $shared = [System.Collections.Generic.Dictionary[string, object[]]]::new([System.StringComparer]::Ordinal)
    foreach ($group in @($open | Where-Object { $_.status -eq 'Warning' } | Group-Object -Property { [string]$_.remediation } -CaseSensitive | Where-Object { $_.Count -ge 3 })) {
        $shared[[string]$group.Name] = @($group.Group)
    }
    # "58 checks (FABRIC.SEMANTICMODEL.MEASURE.*, e.g. A, B)": the count, the IDs' common prefix to a dot, two examples.
    $groupLabel = {
        param([object[]] $Group)
        $ids = @($Group | ForEach-Object { [string]$_.checkId } | Select-Object -Unique)
        if ($ids.Count -eq 1) {
            return ('{0} checks ({1})' -f $Group.Count, $ids[0])
        }
        $prefix = $ids[0]
        foreach ($id in $ids) {
            $length = 0
            while ($length -lt [System.Math]::Min($prefix.Length, $id.Length) -and $prefix[$length] -ceq $id[$length]) {
                $length++
            }
            $prefix = $prefix.Substring(0, $length)
        }
        $cut = $prefix.LastIndexOf('.')
        $pattern = if ($cut -gt 0) { '{0}*, ' -f $prefix.Substring(0, $cut + 1) } else { '' }
        return ('{0} checks ({1}e.g. {2})' -f $Group.Count, $pattern, (@($ids | Select-Object -First 2) -join ', '))
    }
    $logged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $open) {
        $remediation = [string]$item.remediation
        if ($item.status -eq 'Warning' -and $shared.ContainsKey($remediation)) {
            if ($logged.Add($remediation)) {
                Write-DemoLog -Level Warning -Message ('{0}: {1}' -f (& $groupLabel $shared[$remediation]), $remediation)
            }
            continue
        }
        Write-DemoLog -Level Warning -Message ('{0}: {1}' -f $item.checkId, $item.remediation)
    }
    $manual = @($items | Where-Object { $_.status -eq 'Manual action required' })
    $manualSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $manualLines = @(foreach ($item in $manual) {
            $steps = if ($item.remediation) { [string]$item.remediation } else { [string]$item.message }
            if ($manualSeen.Add(('{0}|{1}' -f [string]$item.checkId, $steps))) {
                '  {0}: {1}' -f $item.checkId, $steps
            }
        })
    if ($manualLines.Count -gt 0) {
        $heading = if ($OutcomeDone) { '{0} item(s) are Manual action required; none of them keeps this run from DONE:' } else { '{0} item(s) need you (Manual action required):' }
        Write-DemoLog -Level Warning -Message ($heading -f $manualLines.Count)
        foreach ($line in $manualLines) {
            Write-DemoLog -Level Warning -Message $line
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
