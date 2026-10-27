function Invoke-DemoT3WarmUp {
    <#
    .SYNOPSIS
    Wakes T3 from serverless auto-pause before a demo and confirms the Database Hub extended property.

    .DESCRIPTION
    Reads the database's status ('az sql db show'), then has T1 run the read-only status query on T3
    (Invoke-DemoT3SqlFromT1 -Name Status). The first connection to a paused serverless database resumes it;
    the T1 runner retries the documented transient error (40613) for up to -MaxResumeWaitSeconds, and the
    result reports how long T3 took to answer. The runner closes its connection, so T3 can auto-pause again
    after its delay.

    Returns two results:
    - T3.WARMUP: Pass when T3 answered, with its status before the warm-up and the time it took; Warning when
      T1's login isn't effective yet or T1 isn't running; Fail when T3 doesn't exist (start-demo.ps1
      recreates it in Phase 13) or doesn't answer.
    - T3.PROPERTY: Pass when MS_EnablePerformanceMonitoringPreview is 'true', Fail when it isn't, and Not
      selected when the query didn't run.

    TODO (Phase 9): the rest of the readiness gate for a recreated T3 (ADR 0016) - visibility in Azure
    Resource Graph and telemetry rows from the ADX endpoint, with the measured lag. Until then, Pass here
    means only that T3 is online and its property is set.

    Sources (checked 2026-10-20):
    - Serverless auto-pause and resume: https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume
    - Transient errors: https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-errors-issues

    .PARAMETER DeploymentId
    The deployment's six-character suffix. Read from the resource group's deploymentId tag when omitted.

    .EXAMPLE
    Invoke-DemoT3WarmUp -Config $config | Format-Table checkId, status, message
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [ValidateRange(0, 900)]
        [int] $MaxResumeWaitSeconds = 300,

        [ValidateRange(0, 1800)]
        [int] $MaxLoginWaitSeconds = 120
    )

    $docUrl = 'https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume'
    $hubDoc = 'https://learn.microsoft.com/fabric/database/hub/add-sql'
    $names = Get-DemoT3Name -Config $Config -DeploymentId $DeploymentId
    $database = $null
    if ($names.ServerName) {
        $database = Invoke-DemoAz -SubscriptionId $Config['subscriptionId'] -ArgumentList @('sql', 'db', 'show', '--name', $names.DatabaseName, '--server', $names.ServerName, '--resource-group', $names.ResourceGroup) -AsJson -AllowFailure
    }
    if ($null -eq $database) {
        $serverText = if ($names.ServerName) { $names.ServerName } else { 'azuresql01-<deploymentId>' }
        return @(
            New-DemoResult -CheckId 'T3.WARMUP' -Area 't3' -Target 'T3' -Status 'Fail' -Message ("T3 ({0}/{1}) doesn't exist, so it can't be warmed up." -f $serverText, $names.DatabaseName) -Remediation 'Recreate T3 by deploying again (deploy.ps1 -Resume); from Phase 13, start-demo.ps1 does it automatically.' -DocUrl $docUrl
            New-DemoResult -CheckId 'T3.PROPERTY' -Area 't3' -Target 'T3' -Status 'Not selected' -Message 'The extended property wasn''t checked because T3 doesn''t exist.' -DocUrl $hubDoc
        )
    }

    $before = [string](Get-DemoMemberValue -InputObject $database -Name 'status')
    $run = Invoke-DemoT3SqlFromT1 -Config $Config -Name Status -DeploymentId $names.DeploymentId -CheckId 'T3.WARMUP' -MaxResumeWaitSeconds $MaxResumeWaitSeconds -MaxLoginWaitSeconds $MaxLoginWaitSeconds -Confirm:$false -WhatIf:$false
    $evidence = @{ statusBefore = $before; reason = $run.Reason }
    if ($null -ne $run.Data) {
        foreach ($key in 'elapsedSeconds', 'transientFailures', 'loginFailures', 'loginWaitSeconds') {
            if ($run.Data.ContainsKey($key)) {
                $evidence[$key] = $run.Data[$key]
            }
        }
    }

    if ($run.Status -ne 'Pass') {
        $status = if ($run.Status -eq 'Warning' -or $run.Reason -eq 'T1NotRunning') { 'Warning' } else { 'Fail' }
        return @(
            New-DemoResult -CheckId 'T3.WARMUP' -Area 't3' -Target 'T3' -Status $status -Message ('T3 wasn''t warmed up (it was {0}): {1}' -f $before, $run.Message) -Evidence $evidence -Remediation $run.Result.remediation -DocUrl $docUrl
            New-DemoResult -CheckId 'T3.PROPERTY' -Area 't3' -Target 'T3' -Status 'Not selected' -Message 'The extended property wasn''t checked because the warm-up query didn''t run.' -DocUrl $hubDoc
        )
    }

    $row = @($run.Rows) | Select-Object -First 1
    $value = [string](Get-DemoMemberValue -InputObject $row -Name 'performance_monitoring')
    $resumed = if ([int]$evidence['transientFailures'] -gt 0) { ' It resumed from auto-pause, answering after {0} seconds.' -f $evidence['elapsedSeconds'] } else { ' It answered in {0} seconds.' -f $evidence['elapsedSeconds'] }
    $warm = New-DemoResult -CheckId 'T3.WARMUP' -Area 't3' -Target 'T3' -Status 'Pass' -Message ('T3 is online (it was {0}).{1}' -f $before, $resumed) -Evidence $evidence -DocUrl $docUrl
    $property = if ($value -eq 'true') {
        New-DemoResult -CheckId 'T3.PROPERTY' -Area 't3' -Target 'T3' -Status 'Pass' -Message 'MS_EnablePerformanceMonitoringPreview is ''true'' on ContosoCare.' -Evidence @{ value = $value } -DocUrl $hubDoc
    }
    else {
        $shown = if ($value) { "'$value'" } else { 'missing' }
        New-DemoResult -CheckId 'T3.PROPERTY' -Area 't3' -Target 'T3' -Status 'Fail' -Message ("MS_EnablePerformanceMonitoringPreview is {0} on ContosoCare, so Database Hub doesn't collect performance data for T3." -f $shown) -Evidence @{ value = $value } -Remediation 'Run Invoke-DemoT3SqlFromT1 -Name PerformanceMonitoring (or -Name Setup).' -DocUrl $hubDoc
    }
    return @($warm, $property)
}
