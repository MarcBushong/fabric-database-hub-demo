function Invoke-DemoActivityControlSetup {
    <#
    .SYNOPSIS
    Sets up, grants, rotates, or removes the optional on-demand activity control (ADR 0020): an Azure Automation
    webhook that a Fabric notebook calls to start the demo's targets and run bounded scenarios, with every stop layer.

    .DESCRIPTION
    The control is optional and off by default (control.enabled). Its resources live in rg-<prefix>-control, which
    destroy.ps1 keeps. Every write goes through the subscription guard (Invoke-DemoAz) or the Fabric REST API, and
    -WhatIf changes nothing: each step reports Not selected with what it would do.

    Default (Contributor on the subscription, and Admin of the workspaces it creates):
    1. The vault's network mode from control.vaultNetworkMode: auto reads the tenant's policy assignments
       (Get-DemoPolicyConstraint, as preflight's PREFLIGHT.POLICY.* checks do) and picks private when a policy makes
       new vaults private (for example a Modify that sets publicNetworkAccess to Disabled), public otherwise; public and private force a path. public in a
       tenant whose policy would make the vault private is a Fail, and the policy's exclusion tag is never added.
    2. Microsoft.Automation registered, and rg-<prefix>-control created when it doesn't exist.
    3. infra/control/control.bicep: id-<prefix>-automation, aa-<prefix>-control, and kv-<prefix>-ctl-<suffix> in that mode.
    4. The runbooks DbHub-Control and DbHub-Stop (Windows PowerShell 5.1), published with the current scenario catalog.
    5. The daily T4 safety stop (DbHub-Stop -Scope T4).
    6. A webhook for DbHub-Control and its URL in the secret dbhub-activity-webhook, when there's no valid one (or with
       -RotateWebhook): created through infra/control/webhook.bicep with the URL as a secure parameter only.
    7. The control notebook NB_DatabaseHub_Control: in a folder of the existing workspace (public), or in the
       "DBHub Control" workspace on the same capacity with a managed private endpoint to the vault, approved on the
       vault (private). The Fabric capacity is never resumed, paused, or scaled.

    -GrantRole (an Owner, signed in with multifactor authentication): creates or updates the custom role
    "DbHub Demo Activity Operator" with exactly the approved actions, and assigns A1 (the identity at the demo
    resource group), A2 (the identity at the control account), and A3 (Key Vault Secrets User on the one secret, for
    the signed-in owner and control.notebookUserObjectIds). It shows the identity's object ID before it assigns
    anything. This is the only path that creates the role; deploy.ps1 re-grants A1 after a redeploy when assignRoles
    and control.enabled are true, with the same function.

    -RotateWebhook: a new webhook and a new secret version, then the old webhook is deleted.

    -Remove: deletes A1-A3 and the custom role (an Owner), the Fabric notebook, folder, control workspace, and managed
    private endpoint, and the Automation account, the identity, and the vault (then purges it); the group only when
    nothing else is left in it.

    Returns ADR 0012 results (CONTROL.*); deployment success alone is never Pass.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER ConfigPath
    The configuration file's path, for the commands that results print.

    .PARAMETER GrantRole
    Create the custom role and assign A1-A3 (needs an Owner).

    .PARAMETER RotateWebhook
    Replace the webhook and its secret.

    .PARAMETER Remove
    Remove the control (ConfirmImpact High).

    .PARAMETER Force
    With -Remove: don't ask before each deletion.

    .PARAMETER SkipFabric
    Leave Fabric alone (for example while the capacity is paused); run again later for the notebook.

    .EXAMPLE
    Invoke-DemoActivityControlSetup -Config $config -WhatIf

    .EXAMPLE
    Invoke-DemoActivityControlSetup -Config $config -GrantRole
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Setup')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [Parameter(ParameterSetName = 'Grant', Mandatory)]
        [switch] $GrantRole,

        [Parameter(ParameterSetName = 'Setup')]
        [switch] $RotateWebhook,

        [Parameter(ParameterSetName = 'Remove', Mandatory)]
        [switch] $Remove,

        [Parameter(ParameterSetName = 'Setup')]
        [Parameter(ParameterSetName = 'Remove')]
        [switch] $SkipFabric,

        [Parameter(ParameterSetName = 'Remove')]
        [switch] $Force,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $setting = Get-DemoActivityControlSetting -Config $Config
    if (-not $setting.Enabled -and -not $Remove) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.SETUP' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message 'The on-demand activity control is off (control.enabled is false), so nothing was done. demo-control.ps1 and the demo-control workflow start activity without it.' -Remediation 'Set control.enabled to true to use it (ADR 0020); it needs an Owner once (-GrantRole).' -DocUrl $script:ActivityControlDoc))
        return $results.ToArray()
    }
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing changed. Sign in yourself (az login) and run setup-activity-control.ps1 again.'))
        return $results.ToArray()
    }
    $name = Get-DemoActivityControlName -Config $Config
    $fabricToken = $null
    $getToken = {
        if ($SkipFabric -or $WhatIfPreference) {
            return $null
        }
        try {
            return (Get-DemoFabricToken -SubscriptionId $name.SubscriptionId)
        }
        catch {
            $results.Add((New-DemoResult -CheckId 'CONTROL.FABRIC.TOKEN' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message ('No Fabric token: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Sign in with an account that can use the Fabric workspace, then run setup-activity-control.ps1 again.' -DocUrl 'https://learn.microsoft.com/rest/api/fabric/articles/get-started/fabric-api-quickstart'))
            return $null
        }
    }

    if ($GrantRole) {
        foreach ($item in @(Grant-DemoActivityControlRole -Config $Config -IncludeDefinition -ConfigPath $ConfigPath)) {
            $results.Add($item)
        }
        return $results.ToArray()
    }

    if ($Remove) {
        $ask = @{}
        if ($Force) {
            $ask['Confirm'] = $false
        }
        if (-not $SkipFabric) {
            $fabricToken = & $getToken
            $results.Add((Remove-DemoActivityControlFabric -Config $Config -Name $name -Token $fabricToken @ask))
        }
        $results.Add((Remove-DemoActivityControlRole -Name $name @ask))
        $results.Add((Remove-DemoActivityControlResource -Config $Config -Name $name @ask))
        return $results.ToArray()
    }

    # 1. The vault's network mode.
    $inventory = $null
    if ($setting.VaultNetworkMode -ne 'private') {
        try {
            $inventory = Get-DemoPolicyConstraint -Config $Config -CacheHours 168
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The policy assignments couldn''t be read: {0}' -f $_.Exception.Message)
        }
    }
    $unknown = $null -eq $inventory -or @(@($inventory.Results) | Where-Object { $_.checkId -eq 'PREFLIGHT.POLICY.INVENTORY' -and $_.status -ne 'Pass' }).Count -gt 0
    $mode = Resolve-DemoActivityControlVaultMode -ConfiguredMode $setting.VaultNetworkMode -Rule @(if ($null -ne $inventory) { $inventory.Rules }) -PolicyUnknown:$unknown
    $results.Add((New-DemoResult -CheckId 'CONTROL.MODE' -Area 'workload' -Target 'subscription' -Status $mode.Status -Message $mode.Message -Evidence $mode.Evidence -Remediation $mode.Remediation -DocUrl $mode.DocUrl))
    if ($mode.Status -eq 'Fail') {
        return $results.ToArray()
    }

    # 2-3. The provider, the group, and the template.
    foreach ($item in @(Initialize-DemoActivityControlGroup -Config $Config -Name $name -Confirm:$false)) {
        $results.Add($item)
    }
    if (@($results | Where-Object { $_.checkId -in 'CONTROL.PROVIDER', 'CONTROL.GROUP' -and $_.status -eq 'Fail' }).Count -gt 0) {
        return $results.ToArray()
    }
    $deployment = Invoke-DemoActivityControlTemplate -Config $Config -Name $name -Mode $mode.Mode -Confirm:$false
    $results.Add($deployment.Result)
    if ($deployment.Result.status -eq 'Fail') {
        return $results.ToArray()
    }
    $clientId = if ($null -ne $deployment.Outputs) { [string]$deployment.Outputs['identityClientId'] } else { '00000000-0000-0000-0000-000000000000' }
    $runbookSetting = Get-DemoActivityControlRunbookSetting -Config $Config -Name $name -IdentityClientId $clientId

    # 4-6. The runbooks, the safety stop, and the webhook.
    $runbooks = Publish-DemoActivityControlRunbook -Config $Config -Name $name -Setting $runbookSetting -Confirm:$false
    $results.Add($runbooks)
    if ($runbooks.status -eq 'Fail') {
        return $results.ToArray()
    }
    $results.Add((Set-DemoActivityControlSafetyStop -Config $Config -Name $name -NowUtc $NowUtc -Confirm:$false))
    $hooks = if ($WhatIfPreference) { $null } else { Get-DemoActivityControlWebhook -Name $name }
    $newest = if ($null -ne $hooks) { @($hooks.Webhooks | Where-Object { $_.Enabled }) | Select-Object -First 1 } else { $null }
    $valid = $null -ne $newest -and $null -ne $newest.ExpiryUtc -and $newest.ExpiryUtc -gt $NowUtc.AddDays(14) -and $hooks.SecretExists
    if ($RotateWebhook -or -not $valid) {
        $results.Add((New-DemoActivityControlWebhook -Config $Config -Name $name -NowUtc $NowUtc -Confirm:$false))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'CONTROL.WEBHOOK' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The webhook {0} is valid until {1:yyyy-MM-dd}, and its URL is in the secret {2}; -RotateWebhook replaces it.' -f $newest.Name, $newest.ExpiryUtc, $name.Secret) -Evidence ([ordered]@{ webhook = $newest.Name; expiresUtc = $newest.ExpiryUtc }) -DocUrl $script:ActivityControlDoc))
    }

    # 7. The notebook.
    if ($SkipFabric) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.FABRIC.NOTEBOOK' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'The Fabric part was skipped (-SkipFabric); run setup-activity-control.ps1 again for the notebook.'))
    }
    else {
        $fabricToken = & $getToken
        if ($null -ne $fabricToken -or $WhatIfPreference) {
            foreach ($item in @(Set-DemoActivityControlFabric -Config $Config -Name $name -Mode $mode.Mode -Setting $runbookSetting -Token $fabricToken -Confirm:$false)) {
                $results.Add($item)
            }
        }
    }

    # What's left for the owner: the roles.
    if (-not $WhatIfPreference) {
        foreach ($item in @(Test-DemoActivityControlRole -Config $Config -ConfigPath $ConfigPath)) {
            $results.Add($item)
        }
    }
    $manual = @($results | Where-Object { $_.status -eq 'Manual action required' })
    $failed = @($results | Where-Object { $_.status -eq 'Fail' })
    $summaryStatus = if ($failed.Count) { 'Fail' } elseif ($manual.Count) { 'Manual action required' } elseif ($WhatIfPreference) { 'Not selected' } else { 'Pass' }
    $where = if ($mode.Mode -eq 'public') { 'the folder "{0}" of the existing workspace' -f $name.FabricFolder } else { 'the workspace "{0}"' -f $name.FabricWorkspace }
    $summary = if ($failed.Count) { '{0} step(s) failed; fix them and run setup-activity-control.ps1 again.' -f $failed.Count } elseif ($manual.Count) { '{0} item(s) need you: {1}' -f $manual.Count, (@($manual | ForEach-Object { '{0}: {1}' -f $_.checkId, $(if ($_.remediation) { $_.remediation } else { $_.message }) }) -join ' | ') } else { 'The control is ready: open {0} in {1}, set its parameters, and run it.' -f $name.Notebook, $where }
    $results.Add((New-DemoResult -CheckId 'CONTROL.SUMMARY' -Area 'workload' -Target 'subscription' -Status $summaryStatus -Message $summary -Evidence ([ordered]@{ mode = $mode.Mode; resourceGroup = $name.ResourceGroup; notebook = $name.Notebook; notebookPlace = $where }) -DocUrl $script:ActivityControlDoc))
    return $results.ToArray()
}
