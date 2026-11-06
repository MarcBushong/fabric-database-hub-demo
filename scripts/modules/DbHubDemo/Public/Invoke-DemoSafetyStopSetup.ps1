function Invoke-DemoSafetyStopSetup {
    <#
    .SYNOPSIS
    Sets up the nightly safety stop (ADR 0024), part of every deployment, or, with -GrantRole, only assigns its role.

    .DESCRIPTION
    The nightly safety stop backs up the VMs' own auto-shutdown and covers what it doesn't: at autoShutdownTime, in
    autoShutdownTimeZone, its runbook deallocates the demo's VMs that aren't deallocated and stops T4 when it runs (a
    stopped flexible server starts itself again after 7 days); a short second job afterward reads T3's status through
    Azure Resource Manager to say whether it paused, without waking it. It never starts anything, never uses Run Command,
    and never connects to a database. It doesn't need the optional on-demand activity control (ADR 0020).

    Default (deploy.ps1 runs it after the template, on every run; Contributor is enough for all but the role):
    1. infra/safetystop/safetystop.bicep in the demo resource group: the identity id-<prefix>-<environment>-safetystop and
       the Automation account aa-<prefix>-<environment>-safetystop (SAFETYSTOP.RESOURCES).
    2. The DbHub-Stop runbook (automation/runbooks) with its own settings, published unless the published one is the
       same (SAFETYSTOP.RUNBOOK).
    3. Its two daily schedules, dbhub-safety-stop (Scope Nightly) and dbhub-safety-t3check (Scope T3Check)
       (SAFETYSTOP.SCHEDULE).
    4. Its one role, "DbHub Demo Safety Stop", at the demo resource group, created and assigned when the caller may: an
       Owner, a User Access Administrator, or a Role Based Access Control Administrator once the role exists
       (SAFETYSTOP.ROLE; the owner's decision of 2026-11-05, an exception to ADR 0008's no role assignments by default).

    Every problem is a Warning, never a Fail: the demo works without the safety stop, and the VMs' nightly auto-shutdown
    and T3's auto-pause still apply. A role it can't assign names the exact command an Owner runs once:
    ./scripts/grant-safety-stop.ps1, which calls this with -GrantRole. Every Azure call goes through the subscription
    guard; -WhatIf changes nothing and reports what each step would do.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER ConfigPath
    The configuration file's path, for the command that results print.

    .PARAMETER GrantRole
    Only create the role and assign it (the Owner's command): the identity must exist, which deploy.ps1 makes.

    .PARAMETER NowUtc
    For tests: the current time.

    .EXAMPLE
    Invoke-DemoSafetyStopSetup -Config $config -ConfigPath ./config/demo.config.json

    .EXAMPLE
    Invoke-DemoSafetyStopSetup -Config $config -GrantRole -WhatIf
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'An orchestrator: each step it calls (Invoke-DemoSafetyStopTemplate, Publish-DemoSafetyStopRunbook, Set-DemoSafetyStopSchedule, and Grant-DemoSafetyStopRole) calls ShouldProcess itself, and -WhatIf and -Confirm flow to them.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [switch] $GrantRole,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $name = Get-DemoSafetyStopName -Config $Config
    try {
        if ($GrantRole) {
            # The Owner's own command runs in a process of its own: the subscription guard first (deploy.ps1 ran it already).
            try {
                $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
            }
            catch {
                $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing changed. Sign in yourself (az login --tenant <tenantId>) and run grant-safety-stop.ps1 again.'))
                return $results.ToArray()
            }
            $principalId = Get-DemoSafetyStopPrincipalId -Name $name
            $results.Add((Grant-DemoSafetyStopRole -Name $name -PrincipalId $principalId -ConfigPath $ConfigPath))
            return $results.ToArray()
        }
        $template = Invoke-DemoSafetyStopTemplate -Config $Config -Name $name
        $results.Add($template.Result)
        if ($null -eq $template.Outputs) {
            return $results.ToArray()
        }
        $setting = Get-DemoSafetyStopRunbookSetting -Config $Config -Name $name -IdentityClientId ([string]$template.Outputs['identityClientId'])
        $results.Add((Publish-DemoSafetyStopRunbook -Config $Config -Name $name -Setting $setting))
        $results.Add((Set-DemoSafetyStopSchedule -Config $Config -Name $name -NowUtc $NowUtc))
        $results.Add((Grant-DemoSafetyStopRole -Name $name -PrincipalId ([string]$template.Outputs['identityPrincipalId']) -ConfigPath $ConfigPath))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'SAFETYSTOP.SETUP' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('The nightly safety stop couldn''t be set up: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/deploy.ps1 again; it sets the safety stop up each time. Meanwhile the VMs'' nightly auto-shutdown and T3''s auto-pause still apply.' -DocUrl 'https://learn.microsoft.com/azure/automation/shared-resources/schedules'))
    }
    return $results.ToArray()
}
