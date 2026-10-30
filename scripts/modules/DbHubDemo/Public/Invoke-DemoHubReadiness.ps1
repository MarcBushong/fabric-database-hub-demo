function Invoke-DemoHubReadiness {
    <#
    .SYNOPSIS
    Runs the Database Hub checklist and validations behind configure-fabric.ps1: the subscription guard,
    Fabric prerequisites P4 and P5, Estate visibility, performance telemetry per target, the optional T3
    readiness gate, and presenter access.

    .DESCRIPTION
    In order:
    1. The subscription guard (Assert-DemoAzContext). If it fails, only its Fail result is returned and
       nothing else runs.
    2. P4 (Test-DemoFabricHubSetting), P5 with the capacity (Test-DemoFabricWorkspace), and the optional P11 viewer
       licensing from that capacity's SKU (Test-DemoFabricViewerLicense, Phase 18), unless -SkipFabric.
    3. Estate visibility through Azure Resource Graph (Test-DemoHubEstate).
    4. Performance telemetry through the documented REST endpoint (Test-DemoHubTelemetry), unless
       -SkipTelemetry. A target without rows whose Estate check reports a pending manual step (T2 before
       the PaygWizard step) is Manual action required instead of Fail.
    5. With -T3ReadinessGate, the T3 readiness gate (Test-DemoT3Readiness), when T3 is selected.
    6. Presenter access (Set-DemoPresenterAccess): role assignments only when assignRoles is true, and not
       with -WhatIf.
    Database Hub has no public API, so nothing here calls the Hub itself; every call is a documented Azure
    or Fabric interface, and every Azure CLI call goes through Invoke-DemoAz. Returns the result records.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Target
    Targets for the Estate, telemetry, and gate checks.

    .PARAMETER FabricAdmin
    Accepted for compatibility: since Phase 28, P4 is read through the Fabric admin API on every run.

    .PARAMETER FabricToken
    A Fabric REST API token the operator already has, as a SecureString, for P4 and P5. Without it, the
    Phase 12 helper Get-DemoFabricToken gets one from the signed-in Azure CLI.

    .PARAMETER SkipFabric
    Skip P4 and P5.

    .PARAMETER SkipTelemetry
    Skip the telemetry check.

    .PARAMETER Detail
    Add table, wait-category, and counter evidence to the telemetry results.

    .PARAMETER T3ReadinessGate
    Also run the T3 readiness gate.

    .PARAMETER T3PerformanceMonitoringCheck
    The T3 extended property check for the gate (from Phase 8).

    .PARAMETER WaitMinutes
    How long the telemetry check and the gate keep polling.

    .PARAMETER LookbackMinutes
    The telemetry lookback.

    .PARAMETER FreshMinutes
    The oldest the newest telemetry sample can be for Pass.

    .PARAMETER DeploymentId
    The deploymentId in T3's server name. Read from the resource group's deploymentId tag when omitted.

    .EXAMPLE
    Invoke-DemoHubReadiness -Config $config -WaitMinutes 15
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('T1', 'T2', 'T3')]
        [string[]] $Target = @('T1', 'T2', 'T3'),

        [switch] $FabricAdmin,

        [securestring] $FabricToken,

        [switch] $SkipFabric,

        [switch] $SkipTelemetry,

        [switch] $Detail,

        [switch] $T3ReadinessGate,

        [scriptblock] $T3PerformanceMonitoringCheck,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 0,

        [ValidateRange(1, 10080)]
        [int] $LookbackMinutes = 60,

        [ValidateRange(1, 1440)]
        [int] $FreshMinutes = 15,

        [AllowEmptyString()]
        [string] $DeploymentId = ''
    )

    $results = [System.Collections.Generic.List[object]]::new()
    function Add-ResultItem([object[]] $Items) {
        foreach ($item in @($Items)) {
            if ($null -ne $item) {
                $results.Add($item)
            }
        }
    }

    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId $Config['subscriptionId'] -TenantId $Config['tenantId'] -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message))
        return $results.ToArray()
    }

    if (-not $SkipFabric) {
        Add-ResultItem @(Test-DemoFabricHubSetting -Config $Config -FabricAdmin:$FabricAdmin -Token $FabricToken)
        Add-ResultItem @(Test-DemoFabricWorkspace -Config $Config -Token $FabricToken)
        # P11 (optional, Phase 18): reuses the SKU that FABRIC.P5.CAPACITY read, so it sends no request of its own.
        Add-ResultItem @(Test-DemoFabricViewerLicense -Config $Config -Token $FabricToken -CapacityResult ($results | Where-Object { $_.checkId -eq 'FABRIC.P5.CAPACITY' } | Select-Object -First 1))
    }

    Add-ResultItem @(Test-DemoHubEstate -Config $Config -Target $Target -DeploymentId $DeploymentId)

    if (-not $SkipTelemetry) {
        # Telemetry can't exist before the SQL Server instance does: while HUB.ESTATE reports a pending manual
        # step for a target (T2's PaygWizard step), a target without rows is that manual step, not a failure.
        $estateStatus = @{}
        foreach ($item in $results) {
            if ($item.checkId -like 'HUB.ESTATE.T*') {
                $estateStatus[$item.target] = $item.status
            }
        }
        foreach ($item in @(Test-DemoHubTelemetry -Config $Config -Target $Target -LookbackMinutes $LookbackMinutes -FreshMinutes $FreshMinutes -WaitMinutes $WaitMinutes -DeploymentId $DeploymentId -Detail:$Detail)) {
            $rows = Get-DemoMemberValue -InputObject $item.evidence -Name 'rows'
            if ($item.status -eq 'Fail' -and $estateStatus[$item.target] -eq 'Manual action required' -and $null -ne $rows -and [long]$rows -eq 0) {
                $item = New-DemoResult -CheckId $item.checkId -Area $item.area -Target $item.target -Status 'Manual action required' -Message ('No performance telemetry from {0} yet, because its SQL Server instance isn''t set up: HUB.ESTATE.{0} reports a pending manual step.' -f $item.target) -Evidence $item.evidence -Remediation ('Finish the step that HUB.ESTATE.{0} describes, then run configure-fabric.ps1 again with -WaitMinutes 15.' -f $item.target) -DocUrl $item.docUrl -EvaluationOnly:$item.evaluationOnly
            }
            $results.Add($item)
        }
    }

    if ($T3ReadinessGate) {
        if ('T3' -in $Target) {
            $gate = Test-DemoT3Readiness -Config $Config -PerformanceMonitoringCheck $T3PerformanceMonitoringCheck -DeploymentId $DeploymentId -WaitMinutes $WaitMinutes -FreshMinutes $FreshMinutes
            Add-ResultItem @($gate.Results)
        }
        else {
            $results.Add((New-DemoResult -CheckId 'T3.READINESS.GATE' -Area 'hub' -Target 'T3' -Status 'Not selected' -Message 'T3 wasn''t selected, so the T3 readiness gate didn''t run.'))
        }
    }

    # Role assignments are the only change this function can make. Declining here, or -WhatIf, runs the
    # presenter step in what-if mode, so it still reports what it would assign.
    $apply = $PSCmdlet.ShouldProcess('presenters in presenterObjectIds', 'Assign the Database Hub roles (only when assignRoles is true)')
    Add-ResultItem @(Set-DemoPresenterAccess -Config $Config -WhatIf:(-not $apply) -Confirm:$false)

    return $results.ToArray()
}
