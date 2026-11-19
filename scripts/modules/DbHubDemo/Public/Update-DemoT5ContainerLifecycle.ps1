function Update-DemoT5ContainerLifecycle {
    <#
    .SYNOPSIS
    Sets T5's container lifecycle up (2026-11-19, ADR 0027): the container exists only during a session once the session
    control's role can create it again, so its provisioned throughput bills only while the demo runs. Records it in the
    demo resource group's DbHubT5Container tag and returns DEPLOY.T5.LIFECYCLE (or GRANT.T5.LIFECYCLE).

    .DESCRIPTION
    An Azure Cosmos DB account has no stop, and a container's throughput can't be taken away, only deleted with the
    container. So stop-demo.ps1, the session's end, and the nightly safety stop delete T5's container, and start-demo.ps1
    and Run all create it again, but only where a session can't run without it (the owner's condition, 2026-11-19): the
    session control's custom role has the container's actions, and its identity holds that role at the demo resource group;
    or its identity holds no role at all (the coordinator's fix 1, 2026-11-19), so Run all can't start a session, and
    start-demo.ps1 creates the container with the person's own rights. A control that holds a role without the actions keeps
    the container between sessions.
    deploy.ps1 calls this right after the session control's setup, which updates the role when the deployer is an Owner
    and publishes the runbooks that create the container (-Purpose Deploy); grant-safety-stop.ps1 calls it after an Owner's
    grants (-Purpose Grant). Until then the container stays between sessions (AlwaysOn), so a session never runs without it:
    a Warning with the grant command, or a Pass on the free tier, where that costs nothing. The status page's
    T5.Lifecycle row says the same (-ProgressPath).
    Source: https://learn.microsoft.com/azure/role-based-access-control/permissions/databases#microsoftdocumentdb

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Purpose
    Deploy (deploy.ps1: Session or AlwaysOn) or Grant (grant-safety-stop.ps1: AlwaysOn becomes Session when the role can
    create the container now; an environment deployed before 2026-11-19 keeps its lifecycle for deploy.ps1 to set up).

    .PARAMETER ConfigPath
    The configuration's path, for the grant command in a Warning.

    .PARAMETER ProgressPath
    The status page's progress model (deploy.ps1).

    .PARAMETER PriorResult
    The run's results so far (deploy.ps1): when CONTROL.ROLE.DEFINITION or SAFETYSTOP.ROLE added the container's actions,
    the result and the status page's T5.Lifecycle row say this run updated the roles first. When PREFLIGHT.COST.MONTHLY
    priced the container for a session's hours only and this run records AlwaysOn, they give the month's worst case again,
    against monthlyCeilingUsd.

    .EXAMPLE
    Update-DemoT5ContainerLifecycle -Config $config -Purpose Grant -ConfigPath ./config/demo.config.json
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'An orchestrator: the one step that changes anything, Resolve-DemoT5ContainerLifecycle''s tag write, calls ShouldProcess itself, and -WhatIf flows to it.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('Deploy', 'Grant')]
        [string] $Purpose = 'Deploy',

        [string] $ConfigPath = '',

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $PriorResult = @()
    )

    $checkId = if ($Purpose -eq 'Grant') { 'GRANT.T5.LIFECYCLE' } else { 'DEPLOY.T5.LIFECYCLE' }
    if (-not (Test-DemoT5Enabled -Config $Config)) {
        $offText = if ([string]$Config['t5LeftOut']) { 'T5 is left out of this run because Azure didn''t create its account (DEPLOY.T5 says why), so its container''s lifecycle is set by the run that creates it.' } else { 'T5 is off in this configuration (t5Enabled is false).' }
        $off = New-DemoResult -CheckId $checkId -Area 't5' -Target 'T5' -Status 'Not selected' -Message $offText
        Set-DemoProgressStep -Path $ProgressPath -Id 'T5.Lifecycle' -State 'Skipped' -Status 'Not selected' -Message ([string]$off.message)
        return @($off)
    }
    Set-DemoProgressStep -Path $ProgressPath -Id 'T5.Lifecycle' -State 'Running' -Message 'Checking that the session control can create T5''s container again after a stop deletes it.'
    try {
        $state = Get-DemoDeploymentState -Config $Config
        $t5 = Get-DemoT5State -Config $Config -DeploymentId ([string](Get-DemoMemberValue -InputObject $state.Tags -Name 'deploymentId'))
        $lifecycle = Resolve-DemoT5ContainerLifecycle -Config $Config -Purpose $Purpose -State $state -WhatIf:$WhatIfPreference
        $result = Get-DemoT5LifecycleResult -Lifecycle $lifecycle -CheckId $checkId -FreeTier ([bool]$t5.FreeTier) -ConfigPath $ConfigPath
    }
    catch {
        $result = New-DemoResult -CheckId $checkId -Area 't5' -Target 'T5' -Status 'Warning' -Message ('T5''s container lifecycle wasn''t checked, so nothing deletes the container yet: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/deploy.ps1 again.'
    }
    # The roles this run updated first, for the status page (the coordinator, 2026-11-19: an Owner's deploy.ps1 updates
    # their definitions before the first session relies on them, and says so): the container actions that
    # CONTROL.ROLE.DEFINITION and SAFETYSTOP.ROLE added.
    $roleNotes = @(foreach ($item in @($PriorResult)) {
            if ($null -eq $item -or [string](Get-DemoMemberValue -InputObject $item -Name 'checkId') -notin 'CONTROL.ROLE.DEFINITION', 'SAFETYSTOP.ROLE') {
                continue
            }
            $evidence = Get-DemoMemberValue -InputObject $item -Name 'evidence'
            # Assigned first: Get-DemoMemberValue returns an array as one object.
            $addedValue = Get-DemoMemberValue -InputObject $evidence -Name 'added'
            $added = @(@($addedValue) | Where-Object { [string]$_ -like 'Microsoft.DocumentDB/*' })
            if ($added.Count -gt 0) {
                '"{0}" gained {1}' -f [string](Get-DemoMemberValue -InputObject $evidence -Name 'role'), (($added | ForEach-Object { ([string]$_ -split '/')[-1] }) -join ', ')
            }
        })
    if ($roleNotes.Count -gt 0) {
        $result.message = '{0} This run updated the roles first: {1} (the container''s actions).' -f $result.message, ($roleNotes -join '; ')
        if ($result.evidence -is [System.Collections.IDictionary]) {
            $result.evidence['rolesUpdated'] = $roleNotes
        }
    }
    # Preflight priced T5's throughput for a session's hours only (Get-DemoT5CostLifecycle -ThisRunDeploys; the coordinator's
    # gap fix, 2026-11-19), and this run recorded AlwaysOn (a role update that failed, for example): the month's worst case
    # against monthlyCeilingUsd again.
    $monthly = @(@($PriorResult) | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq 'PREFLIGHT.COST.MONTHLY' }) | Select-Object -Last 1
    $priced = Get-DemoMemberValue -InputObject $monthly -Name 'evidence'
    $pricedWorst = Get-DemoMemberValue -InputObject $priced -Name 'monthlyWorstCase'
    if ([string]$result.status -eq 'Warning' -and [string](Get-DemoMemberValue -InputObject $result.evidence -Name 'lifecycle') -ceq $script:T5LifecycleAlwaysOn -and [string](Get-DemoMemberValue -InputObject $priced -Name 't5ContainerLifecycle') -ceq $script:T5LifecycleSession -and $null -ne $pricedWorst) {
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $extra = [double](Get-DemoMemberValue -InputObject $priced -Name 't5AlwaysOnExtraMonthly')
        $worst = [System.Math]::Round([double]$pricedWorst + $extra, 2)
        $ceiling = [double]$Config['monthlyCeilingUsd']
        $over = $worst -gt $ceiling
        $result.message = [string]::Format($culture, '{0} Preflight priced its throughput for a session''s hours only, so the month''s worst case is about {1:N2} USD more than its estimate: {2:N2} USD, {3} monthlyCeilingUsd ({4:N2} USD).', $result.message, $extra, $worst, $(if ($over) { 'over' } else { 'within' }), $ceiling)
        if ($over) {
            $result.remediation = [string]::Format($culture, '{0} Or raise monthlyCeilingUsd to at least {1:N0} in your configuration.', $result.remediation, [System.Math]::Ceiling($worst))
        }
        if ($result.evidence -is [System.Collections.IDictionary]) {
            $result.evidence['monthlyWorstCase'] = $worst
            $result.evidence['overCeiling'] = $over
        }
    }
    Set-DemoProgressStep -Path $ProgressPath -Id 'T5.Lifecycle' -State 'Done' -Status ([string]$result.status) -Message (('{0} {1}' -f $result.message, $result.remediation).Trim()) -MaxLength 1200
    if ([string]$result.status -eq 'Warning') {
        Write-DemoLog -Level Warning -Message ([string]$result.message)
    }
    return @($result)
}
