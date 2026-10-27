function Test-DemoActivityControl {
    <#
    .SYNOPSIS
    Read-only checks of the optional on-demand activity control (ADR 0020), for validate.ps1's Workload area and
    status.ps1.

    .DESCRIPTION
    With control.enabled false, one CONTROL.SETUP result that's Not selected. Otherwise:
    - CONTROL.SETUP: the Automation account, both runbooks published, and the vault (its network access in the
      evidence).
    - CONTROL.WEBHOOK: the newest webhook and its secret: Pass with more than 14 days left, Warning within 14 days
      (setup-activity-control.ps1 -RotateWebhook), Manual action required when it has expired or is missing.
    - CONTROL.ROLE.A1, CONTROL.ROLE.A2, CONTROL.ROLE.A3: Pass when present; Manual action required with the exact
      -GrantRole command when missing (a redeploy deletes A1 with the demo resource group).
    - CONTROL.AUTOSTOP: Pass with no pending auto-stop or one in the future (a run is active); Warning for one that
      should have run more than an hour ago.
    - CONTROL.SAFETYSTOP: the daily T4 safety stop's schedule and its link to DbHub-Stop.
    Metadata only: no secret value is read.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER ConfigPath
    The configuration file's path, for the -GrantRole command in remediations.

    .PARAMETER NowUtc
    For tests: the current time.

    .EXAMPLE
    Test-DemoActivityControl -Config $config | Format-Table checkId, status, message
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $doc = $script:ActivityControlDoc
    if (-not (Get-DemoActivityControlSetting -Config $Config).Enabled) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.SETUP' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message 'The on-demand activity control is off (control.enabled is false).' -DocUrl $doc))
        return $results.ToArray()
    }
    $name = Get-DemoActivityControlName -Config $Config
    $setup = Get-DemoActivityControlCommand -ConfigPath $ConfigPath
    $setup = $setup -replace ' -GrantRole$', ''
    $version = '2024-10-23'

    $account = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $name.AutomationAccountId -ApiVersion $version)
    if (-not $account.Ok) {
        $status = if ($account.Missing) { 'Manual action required' } else { 'Warning' }
        $results.Add((New-DemoResult -CheckId 'CONTROL.SETUP' -Area 'workload' -Target 'subscription' -Status $status -Message ('{0} {1}.' -f $name.AutomationAccount, $(if ($account.Missing) { 'doesn''t exist: the control isn''t set up' } else { 'couldn''t be read: ' + $account.Error })) -Remediation ('Run {0}.' -f $setup) -DocUrl $doc))
        return $results.ToArray()
    }
    $states = [ordered]@{}
    foreach ($runbook in $name.ControlRunbook, $name.StopRunbook) {
        $read = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/runbooks/{1}' -f $name.AutomationAccountId, $runbook) -ApiVersion $version)
        $states[$runbook] = if ($read.Ok) { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $read.Value -Name 'properties') -Name 'state') } else { 'Missing' }
    }
    $vault = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $name.KeyVaultId -ApiVersion '2026-02-01')
    $access = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $vault.Value -Name 'properties') -Name 'publicNetworkAccess')
    $evidence = [ordered]@{ automationAccount = $name.AutomationAccount; runbooks = $states; keyVault = $name.KeyVault; vaultPublicNetworkAccess = $access }
    $unpublished = @($states.Keys | Where-Object { $states[$_] -ne 'Published' })
    if ($unpublished.Count -gt 0 -or -not $vault.Ok) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.SETUP' -Area 'workload' -Target 'subscription' -Status 'Manual action required' -Message ('The control is incomplete: {0}.' -f ((@($unpublished | ForEach-Object { '{0} is {1}' -f $_, $states[$_] }) + @(if (-not $vault.Ok) { '{0} is missing' -f $name.KeyVault })) -join '; ')) -Evidence $evidence -Remediation ('Run {0}.' -f $setup) -DocUrl $doc))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'CONTROL.SETUP' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0} has {1} and {2} published; {3} has public network access {4}.' -f $name.AutomationAccount, $name.ControlRunbook, $name.StopRunbook, $name.KeyVault, $access) -Evidence $evidence -DocUrl $doc))
    }

    $hooks = Get-DemoActivityControlWebhook -Name $name
    $newest = @($hooks.Webhooks | Where-Object { $_.Enabled }) | Select-Object -First 1
    $hookEvidence = [ordered]@{ webhook = $(if ($newest) { $newest.Name } else { '' }); expiresUtc = $(if ($newest) { $newest.ExpiryUtc } else { $null }); secretExists = $hooks.SecretExists }
    if ($null -eq $newest -or $null -eq $newest.ExpiryUtc -or $newest.ExpiryUtc -le $NowUtc -or -not $hooks.SecretExists) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.WEBHOOK' -Area 'workload' -Target 'subscription' -Status 'Manual action required' -Message ('There''s no working webhook: {0}.' -f $(if ($null -eq $newest) { 'none exists' } elseif (-not $hooks.SecretExists) { 'its secret is missing' } else { 'it has expired' })) -Evidence $hookEvidence -Remediation ('Run {0} -RotateWebhook.' -f $setup) -DocUrl $doc))
    }
    elseif ($newest.ExpiryUtc -le $NowUtc.AddDays(14)) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.WEBHOOK' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The webhook {0} expires on {1:yyyy-MM-dd}, in {2:N0} days.' -f $newest.Name, $newest.ExpiryUtc, ($newest.ExpiryUtc - $NowUtc).TotalDays) -Evidence $hookEvidence -Remediation ('Run {0} -RotateWebhook.' -f $setup) -DocUrl $doc))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'CONTROL.WEBHOOK' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The webhook {0} is valid until {1:yyyy-MM-dd}; its URL is only in the secret {2}.' -f $newest.Name, $newest.ExpiryUtc, $name.Secret) -Evidence $hookEvidence -DocUrl $doc))
    }

    foreach ($item in @(Test-DemoActivityControlRole -Config $Config -ConfigPath $ConfigPath)) {
        $results.Add($item)
    }

    $autostop = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/schedules/{1}' -f $name.AutomationAccountId, $name.AutoStopSchedule) -ApiVersion $version)
    $stopDoc = 'https://learn.microsoft.com/azure/automation/shared-resources/schedules'
    if (-not $autostop.Ok -and $autostop.Missing) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.AUTOSTOP' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message 'No on-demand run is pending: there''s no auto-stop schedule.' -DocUrl $stopDoc))
    }
    elseif (-not $autostop.Ok) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.AUTOSTOP' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The auto-stop schedule couldn''t be read: {0}' -f $autostop.Error) -DocUrl $stopDoc))
    }
    else {
        $start = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $autostop.Value -Name 'properties') -Name 'startTime')
        if ($null -ne $start -and $start -gt $NowUtc) {
            $results.Add((New-DemoResult -CheckId 'CONTROL.AUTOSTOP' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('An on-demand run is active; its auto-stop deallocates the VMs and stops T4 at {0:yyyy-MM-dd HH:mm} UTC.' -f $start) -Evidence ([ordered]@{ autoStopUtc = $start }) -DocUrl $stopDoc))
        }
        elseif ($null -ne $start -and $start -lt $NowUtc.AddHours(-1)) {
            $results.Add((New-DemoResult -CheckId 'CONTROL.AUTOSTOP' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The auto-stop for {0:yyyy-MM-dd HH:mm} UTC is still there, so its DbHub-Stop job may have failed; the nightly auto-shutdown still stops the VMs.' -f $start) -Evidence ([ordered]@{ autoStopUtc = $start }) -Remediation 'Check the DbHub-Stop job in the Automation account, then use Stop now, stop-demo.ps1, or the portal.' -DocUrl $stopDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'CONTROL.AUTOSTOP' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message 'The last auto-stop just ran or is running now.' -DocUrl $stopDoc))
        }
    }

    $safety = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/schedules/{1}' -f $name.AutomationAccountId, $name.SafetyStopSchedule) -ApiVersion $version)
    $links = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules' -f $name.AutomationAccountId) -ApiVersion $version)
    $linked = @(@(Get-DemoActivityControlList -InputObject $links.Value -Name 'value') | Where-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'schedule') -Name 'name') -eq $name.SafetyStopSchedule }).Count -gt 0
    $enabled = $safety.Ok -and [bool](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $safety.Value -Name 'properties') -Name 'isEnabled')
    if ($enabled -and $linked) {
        $next = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $safety.Value -Name 'properties') -Name 'nextRun')
        $results.Add((New-DemoResult -CheckId 'CONTROL.SAFETYSTOP' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The daily T4 safety stop is scheduled{0}.' -f $(if ($null -ne $next) { ' (next {0:yyyy-MM-dd HH:mm} UTC)' -f $next } else { '' })) -DocUrl 'https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server'))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'CONTROL.SAFETYSTOP' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message 'The daily T4 safety stop isn''t scheduled, so a stopped T4 starts itself after 7 days and bills until something stops it.' -Remediation ('Run {0}.' -f $setup) -DocUrl 'https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server'))
    }
    return $results.ToArray()
}
