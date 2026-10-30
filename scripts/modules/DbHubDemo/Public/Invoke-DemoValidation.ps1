function Invoke-DemoValidation {
    <#
    .SYNOPSIS
    Runs the live validation catalog (ADR 0012) read-only and returns one result record per check.

    .DESCRIPTION
    The engine behind scripts/validate.ps1. It runs the subscription guard first, and stops there if it
    fails. Then it runs the selected areas in this order, each through the module's existing checks:
    - Preflight: Invoke-DemoPreflight without changes (no provider registration, no what-if).
    - Infrastructure: the resource group and its tags, the network, each VM's power state, the bootstrap
      loader (Wait-DemoBootstrapLoader), health.json (Get-DemoVmHealth), and the nested guest.
    - T1: Test-DemoSqlVmMonitoring and Test-DemoSqlVmAssociatedService. The second reads unified inventory,
      also while sqlvm01 is deallocated: Pass when it lists only the database engine, a Warning while it still
      lists Analysis Services or Integration Services (T1's AssociatedServices bootstrap step removes them).
    - T2: Get-DemoArcCheck, and the read-only isolation probe of the guest (T2.GUEST.ISOLATION).
    - T3: Test-DemoT3.
    - T4 (Phase 24, ADR 0019): Test-DemoT4 -IncludeMetrics: the PostgreSQL flexible server, Entra-only, its
      network, administrator, database, enhanced metrics, and METRICS.T4 (Azure Monitor has its metrics).
    - Hub: Test-DemoFabricHubSetting (P4), Test-DemoFabricWorkspace (P5), Test-DemoHubEstate, and presenter
      access (Set-DemoPresenterAccess in what-if mode whenever it would assign a role).
    - Telemetry: Test-DemoHubTelemetry over the retention window, and the T3 readiness gate
      (Test-DemoT3Readiness).
    - Workload: the runner's status on each target (Invoke-DemoWorkloadCommand status --json) and the
      scenario bounds.
    - Cost: the live-price estimate (Get-DemoCostEstimate, reused from Preflight), the budget, the
      auto-shutdown schedules, and a Bastion or public IP left billing.
    - Security: secret scans of the local output, the Run Command instance views, and the ARM deployments
      (Find-DemoSecretLeak); role assignments and Key Vaults (the Contributor-only footprint); public IPs and
      inbound rules.
    - Teardown: the read-only residual check of what destroy.ps1 would leave behind.

    Nothing is created, changed, or deleted, except that the Run Command checks run a read-only script and
    delete their Run Command, and T3.PROPERTY's query resumes a paused T3, which auto-pauses again. Stopped
    resources are expected: a check that needs a running VM reports a Warning while the VM is deallocated,
    with the command to start it, and never a Fail. A removed T3 (stop-demo.ps1 -RemoveT3) turns T3's
    failures into Warnings the same way. When the Hub area runs, its P4 and P5 checks replace preflight's
    manual reminders. An area that stops with an error reports one Fail (VALIDATE.<AREA>) and the others
    still run.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Area
    The areas to run; all of them by default.

    .PARAMETER Target
    The targets whose checks run; all four by default.

    .PARAMETER WaitMinutes
    How long the telemetry checks keep polling for fresh rows. 0 checks once.

    .PARAMETER ScanPath
    More files or folders for the Security area's secret scan, besides out/: for example downloaded GitHub
    Actions logs or an exported notebook.

    .PARAMETER DeploymentId
    The environment's deploymentId. Read from the resource group's tag when omitted; after destroy, pass it so
    the Teardown area can match resources by it.

    .PARAMETER FabricAdmin
    Accepted for compatibility: since Phase 28, P4 is read through the Fabric admin API on every run.

    .PARAMETER SkipPolicyInventory
    Skip preflight's policy inventory, which reads every policy definition that applies to the subscription.

    .PARAMETER PolicyCacheHours
    Passed to preflight (Get-DemoPolicyConstraint -CacheHours): reuse a complete policy inventory at most this
    many hours old while the assignments are unchanged. 0 (the default) reads everything.

    .EXAMPLE
    Invoke-DemoValidation -Config $config -Area Infrastructure, T1, T3 -Target T1, T3
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('Preflight', 'Infrastructure', 'T1', 'T2', 'T3', 'T4', 'Hub', 'Telemetry', 'Workload', 'Cost', 'Security', 'Teardown')]
        [string[]] $Area = @('Preflight', 'Infrastructure', 'T1', 'T2', 'T3', 'T4', 'Hub', 'Telemetry', 'Workload', 'Cost', 'Security', 'Teardown'),

        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string[]] $Target = @('T1', 'T2', 'T3', 'T4'),

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 0,

        [AllowEmptyCollection()]
        [string[]] $ScanPath = @(),

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [switch] $FabricAdmin,

        [switch] $SkipPolicyInventory,

        [ValidateRange(0, 720)]
        [int] $PolicyCacheHours = 0
    )

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId $Config['subscriptionId'] -TenantId $Config['tenantId'] -Account ([string]$Config['azureAccount'])))
    }
    catch {
        # The guard's message names the failed check and its fix (ADR 0011, guard update), so it isn't repeated here.
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing ran. Fix what the message names yourself (the scripts never sign in or change your Azure CLI context), then run validate.ps1 again.'))
        return $results.ToArray()
    }

    $context = New-DemoValidationContext -Config $Config -Target $Target -DeploymentId $DeploymentId -Results $results
    # Areas that read a deployed environment; without the resource group, Infrastructure reports it once.
    $deployedOnly = @('T1', 'T2', 'T3', 'T4', 'Hub', 'Telemetry', 'Workload')
    $resultAreas = @{
        Preflight = 'preflight'; Infrastructure = 'infra'; T1 = 't1'; T2 = 't2'; T3 = 't3'; T4 = 't4'; Hub = 'hub'; Telemetry = 'hub'
        Workload = 'workload'; Cost = 'cost'; Security = 'security'; Teardown = 'teardown'
    }
    $order = @('Preflight', 'Infrastructure', 'T1', 'T2', 'T3', 'T4', 'Hub', 'Telemetry', 'Workload', 'Cost', 'Security', 'Teardown')
    $groupReported = 'Infrastructure' -in $Area
    foreach ($name in $order) {
        if ($name -notin $Area) {
            continue
        }
        if ($name -in 'T1', 'T2', 'T3', 'T4' -and $name -notin $Target) {
            continue
        }
        if ($name -in $deployedOnly -and -not $context.GroupExists) {
            if (-not $groupReported) {
                $groupReported = $true
                $results.Add((New-DemoResult -CheckId 'VALIDATE.DEPLOYMENT' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('The resource group {0} doesn''t exist or can''t be read, so the deployment checks didn''t run. {1}' -f $context.ResourceGroup, $context.GroupError).Trim() -Remediation 'Deploy it with ./scripts/deploy.ps1. After destroy.ps1, run validate.ps1 -Area Teardown instead.' -DocUrl 'https://learn.microsoft.com/azure/azure-resource-manager/management/manage-resource-groups-cli'))
            }
            continue
        }
        Write-DemoLog -Message ('Validating {0}...' -f $name)
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $items = switch ($name) {
                'Preflight' { Invoke-DemoValidationPreflight -Context $context -SkipPolicyInventory:$SkipPolicyInventory -PolicyCacheHours $PolicyCacheHours }
                'Infrastructure' { Invoke-DemoValidationInfrastructure -Context $context }
                'T1' { Invoke-DemoValidationT1 -Context $context }
                'T2' { Invoke-DemoValidationT2 -Context $context }
                'T3' { Invoke-DemoValidationT3 -Context $context }
                'T4' { Invoke-DemoValidationT4 -Context $context }
                'Hub' { Invoke-DemoValidationHub -Context $context -FabricAdmin:$FabricAdmin }
                'Telemetry' { Invoke-DemoValidationTelemetry -Context $context -WaitMinutes $WaitMinutes }
                'Workload' { Invoke-DemoValidationWorkload -Context $context }
                'Cost' { Invoke-DemoValidationCost -Context $context }
                'Security' { Invoke-DemoValidationSecurity -Context $context -ScanPath $ScanPath }
                'Teardown' { Invoke-DemoValidationTeardown -Context $context }
            }
            foreach ($item in @($items)) {
                if ($null -ne $item) {
                    $results.Add($item)
                }
            }
        }
        catch {
            $results.Add((New-DemoResult -CheckId ('VALIDATE.{0}' -f $name.ToUpperInvariant()) -Area $resultAreas[$name] -Target 'subscription' -Status 'Fail' -Message ('The {0} checks stopped with an error: {1}' -f $name, $_.Exception.Message) -Remediation ('Run validate.ps1 -Area {0} again; if it repeats, report the error with out/validate.jsonl.' -f $name)))
        }
        Write-DemoLog -Message ('{0} took {1:N0} seconds.' -f $name, $clock.Elapsed.TotalSeconds)
    }

    $final = [System.Collections.Generic.List[object]]::new()
    $hasFabricP4 = @($results | Where-Object { $_.checkId -eq 'FABRIC.P4.HUBSETTING' }).Count -gt 0
    $hasFabricP5 = @($results | Where-Object { $_.checkId -like 'FABRIC.P5.*' }).Count -gt 0
    $t3Missing = $false
    if ($context.GroupExists -and @($results | Where-Object { $_.target -eq 'T3' -and $_.status -eq 'Fail' }).Count -gt 0) {
        $t3Missing = [bool](Get-DemoValidationT3State -Context $context).Missing
    }
    foreach ($item in $results) {
        if (($hasFabricP4 -and $item.checkId -eq 'PREFLIGHT.P4.HUBSETTING') -or ($hasFabricP5 -and $item.checkId -eq 'PREFLIGHT.P5.WORKSPACE')) {
            continue
        }
        if ($t3Missing -and $item.target -eq 'T3' -and $item.status -eq 'Fail') {
            $item = New-DemoResult -CheckId $item.checkId -Area $item.area -Target 'T3' -Status 'Warning' -Message ('T3 isn''t deployed now ({0} wasn''t found): stop-demo.ps1 -RemoveT3 removes it between demos, and start-demo.ps1 recreates it with the same names. {1}' -f $context.T3.ServerName, $item.message) -Evidence $item.evidence -Remediation 'If you removed it, start-demo.ps1 recreates it; otherwise deploy again (deploy.ps1 -Resume).' -DocUrl $item.docUrl
        }
        $final.Add($item)
    }
    return $final.ToArray()
}
