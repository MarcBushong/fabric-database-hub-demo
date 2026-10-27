function Set-DemoArcSqlConfiguration {
    <#
    .SYNOPSIS
    Verifies and converges SQL Server enabled by Azure Arc on T2: the Azure extension for SQL Server, its
    license type, the SQL Server instance resource, and monitoring (ADR 0006). Re-runnable.

    .DESCRIPTION
    While the Arc machine is Connected:
    1. Azure extension for SQL Server (WindowsAgent.SqlServer, publisher Microsoft.AzureData): the
       resource-group tag ArcSQLServerExtensionDeployment=PAYG makes Azure deploy it automatically when SQL
       Server is detected (manage-autodeploy). If SQL Server is detected and the extension is still missing,
       it's installed through the documented REST API (Machine Extensions - Create Or Update) with the
       documented settings { SqlManagement: { IsEnabled: true }, LicenseType: PAYG }. If the license type
       isn't one the install mode accepts (PAYG; PAYG or Paid in ProductKey mode), it's set to PAYG with
       every other setting kept, because an update replaces all settings (manage-configuration). Developer
       mode leaves the license type alone: Developer usage is reported on a 0 USD meter.
    2. Waits up to -WaitMinutes for the Microsoft.AzureArcData/sqlServerInstances resource.
    3. Turns on monitoring with the documented command: az resource update --set
       properties.monitoring.enabled=true --api-version 2023-09-01-preview (sql-monitoring). Not in Developer
       mode, where Arc monitoring isn't supported.
    Then it returns T2.ARC.CONFIGURATION (what was changed), T2.ARC.SQLEXTENSION, T2.ARC.SQLINSTANCE, and
    T2.ARC.MONITORING. In PaygWizard mode, nothing can converge until the setup-wizard step installs SQL
    Server; the SQL checks then report Manual action required. Under -WhatIf nothing changes.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER WaitMinutes
    How long to wait for the extension and the instance resource.

    .PARAMETER PollIntervalSeconds
    Seconds between reads while waiting.

    .EXAMPLE
    Set-DemoArcSqlConfiguration -Config $config -WaitMinutes 20
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 15,

        [ValidateRange(1, 300)]
        [int] $PollIntervalSeconds = 30
    )

    $target = Get-DemoArcTarget -Config $Config
    $setting = $target.Setting
    $expectation = Get-DemoArcExpectation -InstallMode $target.InstallMode
    $docUrl = $setting.DocUrls['configuration']
    if (-not $PSCmdlet.ShouldProcess($target.MachineName, 'Verify the Azure extension for SQL Server, enforce its license type, and turn on monitoring')) {
        return (New-DemoArcResult -CheckId 'T2.ARC.CONFIGURATION' -Target $target -Status 'Not selected' -Message 'What if: nothing was read or changed.' -DocUrl $docUrl)
    }

    $actions = [System.Collections.Generic.List[string]]::new()
    $failure = ''
    $connected = $false
    try {
        $state = Get-DemoArcState -Config $Config
        $machineStatus = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $state.Machine -Name 'properties') -Name 'status')
        $connected = $null -ne $state.Machine -and $machineStatus -eq 'Connected'
        if ($connected) {
            $location = [string](Get-DemoMemberValue -InputObject $state.Machine -Name 'location')
            $sqlDetected = Test-DemoArcSqlDetected -Machine $state.Machine
            $extension = Get-DemoArcExtensionInfo -Extension $state.Extension
            $waitExtension = [System.Math]::Max(1, $WaitMinutes)
            if ($null -eq $extension -and $sqlDetected) {
                $body = Get-DemoArcExtensionBody -SqlExtension $setting.SqlExtension -Location $location -Existing $null -LicenseType ([string]$setting.SqlExtension['licenseType'])
                Set-DemoArmResource -SubscriptionId $target.SubscriptionId -Url $target.ExtensionUrl -Body $body -Confirm:$false | Out-Null
                $actions.Add(('Installed {0} with license type {1}.' -f $setting.SqlExtension['name'], $setting.SqlExtension['licenseType']))
                Wait-DemoArcExtension -Target $target -WaitMinutes $waitExtension -PollIntervalSeconds $PollIntervalSeconds | Out-Null
            }
            elseif ($null -ne $extension -and $expectation.LicenseTypes.Count -gt 0 -and $extension.LicenseType -notin $expectation.LicenseTypes -and $extension.ProvisioningState -eq 'Succeeded') {
                $extensionLocation = if ($extension.Location) { $extension.Location } else { $location }
                $body = Get-DemoArcExtensionBody -SqlExtension $setting.SqlExtension -Location $extensionLocation -Existing $extension -LicenseType ([string]$setting.SqlExtension['licenseType'])
                Set-DemoArmResource -SubscriptionId $target.SubscriptionId -Url $target.ExtensionUrl -Body $body -Confirm:$false | Out-Null
                $actions.Add(('Set the extension''s license type from ''{0}'' to {1}, keeping its other settings.' -f $extension.LicenseType, $setting.SqlExtension['licenseType']))
                Wait-DemoArcExtension -Target $target -WaitMinutes $waitExtension -PollIntervalSeconds $PollIntervalSeconds | Out-Null
            }

            if ($sqlDetected -or $null -ne $extension -or $actions.Count -gt 0) {
                $hosted = Wait-DemoArcSqlInstance -Target $target -WaitMinutes $WaitMinutes -PollIntervalSeconds $PollIntervalSeconds
                $info = Get-DemoArcInstanceInfo -Instance @($hosted) -MinimumCores $setting.MinimumCoresPerOse
                if ($expectation.MonitoringSupported -and $null -ne $info -and -not $info.MonitoringEnabled) {
                    Invoke-DemoArcMonitoringUpdate -Target $target -InstanceName $info.Name -Confirm:$false
                    $actions.Add(('Turned on monitoring for {0} (api-version {1}).' -f $info.Name, $setting.MonitoringApiVersion))
                }
            }
        }
    }
    catch {
        $failure = $_.Exception.Message
    }

    try {
        $final = Get-DemoArcState -Config $Config
    }
    catch {
        $message = 'Azure couldn''t be read: {0}' -f $_.Exception.Message
        foreach ($id in 'T2.ARC.CONFIGURATION', 'T2.ARC.SQLEXTENSION', 'T2.ARC.SQLINSTANCE', 'T2.ARC.MONITORING') {
            New-DemoArcResult -CheckId $id -Target $target -Status 'Fail' -Message $message -DocUrl $docUrl
        }
        return
    }

    $evidence = [ordered]@{ actions = $actions.ToArray(); installMode = $target.InstallMode }
    if ($failure) {
        New-DemoArcResult -CheckId 'T2.ARC.CONFIGURATION' -Target $target -Status 'Fail' -Message ('Configuring SQL Server enabled by Azure Arc stopped: {0}' -f $failure) -Evidence $evidence -Remediation 'Fix the cause and run configure-arc.ps1 again; every step is re-runnable.' -DocUrl $docUrl
    }
    elseif (-not $connected) {
        New-DemoArcResult -CheckId 'T2.ARC.CONFIGURATION' -Target $target -Status 'Warning' -Message ('The Arc machine {0} isn''t Connected, so nothing was configured; T2.ARC.CONNECTED has the details.' -f $target.MachineName) -Evidence $evidence -Remediation 'Onboard or reconnect T2 (configure-arc.ps1), then run it again.' -DocUrl $docUrl
    }
    elseif ($actions.Count -gt 0) {
        New-DemoArcResult -CheckId 'T2.ARC.CONFIGURATION' -Target $target -Status 'Pass' -Message ('Configured SQL Server enabled by Azure Arc: {0}' -f ($actions -join ' ')) -Evidence $evidence -DocUrl $docUrl
    }
    else {
        New-DemoArcResult -CheckId 'T2.ARC.CONFIGURATION' -Target $target -Status 'Pass' -Message 'Nothing needed changing; the checks below report the state.' -Evidence $evidence -DocUrl $docUrl
    }
    Test-DemoArcSqlExtension -State $final
    Test-DemoArcSqlInstance -State $final
    Test-DemoArcMonitoring -State $final
}
