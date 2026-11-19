function Update-DemoT5ContainerLifecycle {
    <#
    .SYNOPSIS
    Sets T5's container lifecycle up (2026-11-19, ADR 0027): the container exists only during a session once the session
    control's role can create it again, so its provisioned throughput bills only while the demo runs. Records it in the
    demo resource group's DbHubT5Container tag and returns DEPLOY.T5.LIFECYCLE (or GRANT.T5.LIFECYCLE).

    .DESCRIPTION
    An Azure Cosmos DB account has no stop, and a container's throughput can't be taken away, only deleted with the
    container. So stop-demo.ps1, the session's end, and the nightly safety stop delete T5's container, and start-demo.ps1
    and Run all create it again, but only once a session can create it (the owner's condition, 2026-11-19): the session
    control's custom role has the container's actions, and its identity holds that role at the demo resource group.
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
        [string] $ProgressPath = ''
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
    Set-DemoProgressStep -Path $ProgressPath -Id 'T5.Lifecycle' -State 'Done' -Status ([string]$result.status) -Message (('{0} {1}' -f $result.message, $result.remediation).Trim()) -MaxLength 1200
    if ([string]$result.status -eq 'Warning') {
        Write-DemoLog -Level Warning -Message ([string]$result.message)
    }
    return @($result)
}
