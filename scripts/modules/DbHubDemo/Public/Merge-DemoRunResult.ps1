function Merge-DemoRunResult {
    <#
    .SYNOPSIS
    deploy.ps1's results with what its ending added (Complete-DemoDeploymentRun's Added): the run's results, then the
    ending's, where an Insights app record of the ending replaces the run's earlier ones with the same check ID. Pure.

    .DESCRIPTION
    The ending adds its own records (DEPLOY.NIGHTLYSTOP, DEPLOY.CARRIED, DEPLOY.ENDSTOP) to the run's results. Since
    2026-11-20 (F18) it may also deploy the Insights app once more, after the stop at the end of an update saw T2's first
    migration assessment upload (Complete-DemoInsightsAppMigration): those records replace the app step's earlier records
    with the same check IDs, as Complete-DemoInsightsAppManage's do during the run, so the report, out/deploy.jsonl, and
    the exit code read the app as it is now, once (FABRIC.APP.ESTATE with t2MigrationReadAt). Only the Insights app's
    records (Test-DemoInsightsAppRecord) are replaced; every other record stays, in order.

    .PARAMETER Result
    The run's results.

    .PARAMETER Added
    What the run's ending added (the outcome's Added).

    .EXAMPLE
    $results = Merge-DemoRunResult -Result $results -Added @($outcome.Added)
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowEmptyCollection()]
        [object[]] $Added = @()
    )

    $ending = @($Added | Where-Object { $null -ne $_ })
    $replaced = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in @($ending | Where-Object { Test-DemoInsightsAppRecord -Result $_ })) {
        $null = $replaced.Add([string]$item.checkId)
    }
    $kept = @($Result | Where-Object { $null -eq $_ -or -not ($replaced.Contains([string]$_.checkId) -and (Test-DemoInsightsAppRecord -Result $_)) })
    return [object[]]@(@($kept) + @($ending))
}
