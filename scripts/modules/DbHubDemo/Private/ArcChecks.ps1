function New-DemoArcResult {
    # One T2 result; labeled EVALUATION ONLY in the evaluation-only mode (ADR 0012). Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $CheckId,

        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [string] $Status,

        [Parameter(Mandatory)]
        [string] $Message,

        [System.Collections.IDictionary] $Evidence = @{},

        [string] $Remediation = '',

        [string] $DocUrl = ''
    )

    New-DemoResult -CheckId $CheckId -Area 't2' -Target 'T2' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl -EvaluationOnly:$Target.EvaluationOnly
}

function ConvertTo-DemoUtcDate {
    # A timestamp from ARM JSON (a string, or a DateTime that ConvertFrom-Json produced) as UTC, or $null. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [System.DateTimeOffset]) {
        return $Value.UtcDateTime
    }
    $parsed = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }
    return $null
}

function Get-DemoArcExtensionInfo {
    # The facts the checks need from a Microsoft.HybridCompute/machines/extensions resource, or $null. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Extension
    )

    if ($null -eq $Extension) {
        return $null
    }
    $properties = Get-DemoMemberValue -InputObject $Extension -Name 'properties'
    $instanceView = Get-DemoMemberValue -InputObject $properties -Name 'instanceView'
    # instanceView.typeHandlerVersion is the full version (manage-configuration's Resource Graph query reads it).
    $version = [string](Get-DemoMemberValue -InputObject $instanceView -Name 'typeHandlerVersion')
    if (-not $version) {
        $version = [string](Get-DemoMemberValue -InputObject $properties -Name 'typeHandlerVersion')
    }
    $settings = Get-DemoMemberValue -InputObject $properties -Name 'settings'
    [pscustomobject]@{
        Name                    = [string](Get-DemoMemberValue -InputObject $Extension -Name 'name')
        Location                = [string](Get-DemoMemberValue -InputObject $Extension -Name 'location')
        Publisher               = [string](Get-DemoMemberValue -InputObject $properties -Name 'publisher')
        Type                    = [string](Get-DemoMemberValue -InputObject $properties -Name 'type')
        Version                 = $version
        TypeHandlerVersion      = [string](Get-DemoMemberValue -InputObject $properties -Name 'typeHandlerVersion')
        ProvisioningState       = [string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState')
        LicenseType             = [string](Get-DemoMemberValue -InputObject $settings -Name 'LicenseType')
        AutoUpgradeMinorVersion = Get-DemoMemberValue -InputObject $properties -Name 'autoUpgradeMinorVersion'
        EnableAutomaticUpgrade  = Get-DemoMemberValue -InputObject $properties -Name 'enableAutomaticUpgrade'
        Settings                = $settings
    }
}

function Get-DemoArcInstanceInfo {
    <#
    .SYNOPSIS
    The facts the checks need from the machine's Microsoft.AzureArcData/sqlServerInstances resources: the
    default instance (MSSQLSERVER), or the first one. $null when there's none. Internal.

    .DESCRIPTION
    vCore is "the number of logical processors used by the SQL Server instance" and cores "the number of
    total cores of the OSE hosting the SQL Server instance" (REST reference, api-version 2026-01-01). Pay-as-you-go
    usage on a VM is metered on the OSE's virtual cores, with a minimum of four per OSE (manage-license-billing),
    so the billable estimate is the larger of four and cores (or vCore when cores is missing).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Instance = @(),

        [ValidateRange(0, 64)]
        [int] $MinimumCores = 4
    )

    $items = @($Instance | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        return $null
    }
    $chosen = $items | Where-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'instanceName') -eq 'MSSQLSERVER' } | Select-Object -First 1
    if ($null -eq $chosen) {
        $chosen = $items[0]
    }
    $properties = Get-DemoMemberValue -InputObject $chosen -Name 'properties'
    $monitoring = Get-DemoMemberValue -InputObject $properties -Name 'monitoring'
    $vCore = 0
    $cores = 0
    [int]::TryParse([string](Get-DemoMemberValue -InputObject $properties -Name 'vCore'), [ref]$vCore) | Out-Null
    [int]::TryParse([string](Get-DemoMemberValue -InputObject $properties -Name 'cores'), [ref]$cores) | Out-Null
    $basis = if ($cores -gt 0) { $cores } else { $vCore }
    [pscustomobject]@{
        Name                = [string](Get-DemoMemberValue -InputObject $chosen -Name 'name')
        InstanceName        = [string](Get-DemoMemberValue -InputObject $properties -Name 'instanceName')
        Edition             = [string](Get-DemoMemberValue -InputObject $properties -Name 'edition')
        LicenseType         = [string](Get-DemoMemberValue -InputObject $properties -Name 'licenseType')
        Version             = [string](Get-DemoMemberValue -InputObject $properties -Name 'version')
        CurrentVersion      = [string](Get-DemoMemberValue -InputObject $properties -Name 'currentVersion')
        Status              = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
        VCore               = $vCore
        Cores               = $cores
        BillableCores       = if ($basis -gt 0) { [System.Math]::Max($MinimumCores, $basis) } else { 0 }
        MonitoringEnabled   = [bool](Get-DemoMemberValue -InputObject $monitoring -Name 'enabled')
        LastUsageUploadTime = [string](Get-DemoMemberValue -InputObject $properties -Name 'lastUsageUploadTime')
        Count               = $items.Count
    }
}

function Get-DemoArcState {
    <#
    .SYNOPSIS
    One read-only snapshot of T2's Arc resources for the checks: the machine arcsql01, every Arc machine and
    SQL Server instance in the resource group, the Azure extension for SQL Server, and optionally the host's
    power state. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $IncludeHostPowerState
    )

    $target = Get-DemoArcTarget -Config $Config
    $machine = Get-DemoArcArmResource -SubscriptionId $target.SubscriptionId -Url $target.MachineUrl
    $machines = Get-DemoArmCollection -SubscriptionId $target.SubscriptionId -Url $target.MachinesUrl
    $instances = Get-DemoArmCollection -SubscriptionId $target.SubscriptionId -Url $target.SqlInstancesUrl
    $hosted = Select-DemoArcSqlInstance -Instance $instances -MachineId $target.MachineId
    $extension = $null
    if ($null -ne $machine) {
        $extension = Get-DemoArcArmResource -SubscriptionId $target.SubscriptionId -Url $target.ExtensionUrl
    }
    $powerState = ''
    if ($IncludeHostPowerState) {
        $powerState = Get-DemoVmPowerState -SubscriptionId $target.SubscriptionId -ResourceGroupName $target.ResourceGroupName -VmName $target.HostVmName
    }
    [pscustomobject]@{
        Target          = $target
        Machine         = $machine
        Machines        = $machines
        Instances       = $instances
        HostedInstances = $hosted
        Extension       = $extension
        HostPowerState  = $powerState
    }
}

function Test-DemoArcConnected {
    # T2.ARC.CONNECTED: the Arc machine exists and reports Connected. Internal; see Get-DemoArcCheck.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State,

        [datetime] $Now = [datetime]::UtcNow
    )

    $target = $State.Target
    $docUrl = $target.Setting.DocUrls['machinesRest']
    if ($null -eq $State.Machine) {
        return (New-DemoArcResult -CheckId 'T2.ARC.CONNECTED' -Target $target -Status 'Fail' -Message ('The Arc machine {0} doesn''t exist: T2 isn''t onboarded.' -f $target.MachineName) -Remediation 'Run ./scripts/configure-arc.ps1 when the host reports WaitingForArcOnboarding.' -DocUrl $docUrl)
    }
    $properties = Get-DemoMemberValue -InputObject $State.Machine -Name 'properties'
    $status = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
    $changed = ConvertTo-DemoUtcDate -Value (Get-DemoMemberValue -InputObject $properties -Name 'lastStatusChange')
    $evidence = [ordered]@{
        status            = $status
        lastStatusChange  = if ($changed) { $changed.ToString('o') } else { '' }
        agentVersion      = [string](Get-DemoMemberValue -InputObject $properties -Name 'agentVersion')
        provisioningState = [string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState')
        vmId              = [string](Get-DemoMemberValue -InputObject $properties -Name 'vmId')
        hostPowerState    = $State.HostPowerState
    }
    if ($status -eq 'Connected') {
        return (New-DemoArcResult -CheckId 'T2.ARC.CONNECTED' -Target $target -Status 'Pass' -Message ('The Arc machine {0} is Connected.' -f $target.MachineName) -Evidence $evidence -DocUrl $docUrl)
    }
    if ($status -eq 'Disconnected') {
        $hostRunning = $State.HostPowerState -eq 'PowerState/running'
        $minutes = if ($changed) { ($Now - $changed).TotalMinutes } else { [double]::MaxValue }
        if (-not $hostRunning -or $minutes -lt 30) {
            return (New-DemoArcResult -CheckId 'T2.ARC.CONNECTED' -Target $target -Status 'Warning' -Message ('The Arc machine {0} is Disconnected while {1} is {2}; it reconnects within minutes of the host starting.' -f $target.MachineName, $target.HostVmName, $(if ($State.HostPowerState) { $State.HostPowerState } else { 'in an unknown state' })) -Evidence $evidence -Remediation 'Start the demo (./scripts/start-demo.ps1), wait a few minutes, and validate again.' -DocUrl $docUrl)
        }
        return (New-DemoArcResult -CheckId 'T2.ARC.CONNECTED' -Target $target -Status 'Fail' -Message ('The Arc machine {0} has been Disconnected for {1:N0} minutes although {2} is running.' -f $target.MachineName, $minutes, $target.HostVmName) -Evidence $evidence -Remediation 'Check the guest is running and can reach the Arc endpoints (azcmagent check in the guest), then run configure-arc.ps1 -Force.' -DocUrl $target.Setting.DocUrls['show'])
    }
    return (New-DemoArcResult -CheckId 'T2.ARC.CONNECTED' -Target $target -Status 'Fail' -Message ('The Arc machine {0} reports status ''{1}''.' -f $target.MachineName, $status) -Evidence $evidence -Remediation 'Run azcmagent show in the guest; to rebuild the connection run configure-arc.ps1 -Force, which removes a stale machine first.' -DocUrl $docUrl)
}

function Test-DemoArcNoDuplicate {
    <#
    .SYNOPSIS
    T2.ARC.NODUPLICATES: exactly one Arc machine, arcsql01, in the resource group; every Arc-hosted SQL Server
    instance belongs to it; and no instance name appears twice. Internal; see Get-DemoArcCheck.

    .DESCRIPTION
    SQL Server instances that unified inventory creates for T1 point at the Azure VM, not at an Arc machine,
    so they're left out (https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/unified-inventory-sql-vm).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State
    )

    $target = $State.Target
    $machineNames = @(foreach ($machine in @($State.Machines)) { [string](Get-DemoMemberValue -InputObject $machine -Name 'name') })
    $extra = @($machineNames | Where-Object { -not [string]::Equals($_, $target.MachineName, [System.StringComparison]::OrdinalIgnoreCase) })
    $arcInstances = @(foreach ($instance in @($State.Instances)) {
            $container = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $instance -Name 'properties') -Name 'containerResourceId')
            if ($container -match '/providers/Microsoft\.HybridCompute/machines/') {
                $instance
            }
        })
    $orphans = @(foreach ($instance in $arcInstances) {
            $container = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $instance -Name 'properties') -Name 'containerResourceId')
            $owner = ($container.TrimEnd('/') -split '/')[-1]
            if (-not [string]::Equals($container.TrimEnd('/'), $target.MachineId, [System.StringComparison]::OrdinalIgnoreCase) -and $owner -notin $machineNames) {
                [string](Get-DemoMemberValue -InputObject $instance -Name 'name')
            }
        })
    $instanceNames = @(foreach ($instance in @($State.HostedInstances)) { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $instance -Name 'properties') -Name 'instanceName') })
    $repeated = @($instanceNames | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    $evidence = [ordered]@{
        arcMachines       = $machineNames
        arcSqlInstances   = @($arcInstances | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        extraMachines     = $extra
        orphanInstances   = $orphans
        repeatedInstances = $repeated
    }
    $docUrl = $target.Setting.DocUrls['deleteFromArc']
    if ($extra.Count -gt 0 -or $orphans.Count -gt 0 -or $repeated.Count -gt 0) {
        $problems = @()
        if ($extra.Count -gt 0) {
            $problems += ('other Arc machines: {0}' -f ($extra -join ', '))
        }
        if ($orphans.Count -gt 0) {
            $problems += ('SQL Server instances without their machine: {0}' -f ($orphans -join ', '))
        }
        if ($repeated.Count -gt 0) {
            $problems += ('instance names reported twice: {0}' -f ($repeated -join ', '))
        }
        return (New-DemoArcResult -CheckId 'T2.ARC.NODUPLICATES' -Target $target -Status 'Fail' -Message ('Duplicate or stale Arc resources in {0}: {1}.' -f $target.ResourceGroupName, ($problems -join '; ')) -Evidence $evidence -Remediation 'Delete the extra sqlServerInstances first, then the extra machines (az resource delete), and run configure-arc.ps1 again.' -DocUrl $docUrl)
    }
    if ($null -eq $State.Machine) {
        return (New-DemoArcResult -CheckId 'T2.ARC.NODUPLICATES' -Target $target -Status 'Warning' -Message ('There''s no Arc machine in {0} yet, so nothing is duplicated; T2.ARC.CONNECTED reports the onboarding.' -f $target.ResourceGroupName) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoArcResult -CheckId 'T2.ARC.NODUPLICATES' -Target $target -Status 'Pass' -Message ('Exactly one Arc machine, {0}, with {1} SQL Server instance resource(s) and no stale ones.' -f $target.MachineName, @($State.HostedInstances).Count) -Evidence $evidence -DocUrl $docUrl)
}

function Test-DemoArcSqlExtension {
    # T2.ARC.SQLEXTENSION: the Azure extension for SQL Server is Succeeded, recent enough, and licensed as the mode expects. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State
    )

    $target = $State.Target
    $setting = $target.Setting
    $minimum = [string]$setting.SqlExtension['minimumVersion']
    $docUrl = $setting.DocUrls['monitoring']
    $expectation = Get-DemoArcExpectation -InstallMode $target.InstallMode
    if ($null -eq $State.Machine) {
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLEXTENSION' -Target $target -Status 'Fail' -Message ('The Arc machine {0} doesn''t exist, so it has no Azure extension for SQL Server.' -f $target.MachineName) -Remediation 'Run ./scripts/configure-arc.ps1.' -DocUrl $setting.DocUrls['autoDeploy'])
    }
    $sqlDetected = Test-DemoArcSqlDetected -Machine $State.Machine
    $extension = Get-DemoArcExtensionInfo -Extension $State.Extension
    if ($null -eq $extension) {
        $evidence = [ordered]@{ sqlDetected = $sqlDetected }
        if (-not $sqlDetected -and $target.InstallMode -eq 'PaygWizard') {
            return (New-DemoArcResult -CheckId 'T2.ARC.SQLEXTENSION' -Target $target -Status 'Manual action required' -Message 'SQL Server isn''t installed in arcsql01 yet: finish the PaygWizard setup-wizard step. The extension is deployed when SQL Server is detected.' -Evidence $evidence -Remediation 'Follow the setup-wizard steps in docs/deployment.md (health.json on the host lists them), then run configure-arc.ps1 again.' -DocUrl $setting.DocUrls['autoDeploy'])
        }
        if (-not $sqlDetected) {
            return (New-DemoArcResult -CheckId 'T2.ARC.SQLEXTENSION' -Target $target -Status 'Warning' -Message ('The Arc machine {0} doesn''t report SQL Server yet, so the extension isn''t deployed yet.' -f $target.MachineName) -Evidence $evidence -Remediation 'Wait for the host to finish installing SQL Server, then run configure-arc.ps1 again.' -DocUrl $setting.DocUrls['autoDeploy'])
        }
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLEXTENSION' -Target $target -Status 'Fail' -Message ('SQL Server is detected on {0}, but the {1} extension is missing.' -f $target.MachineName, $setting.SqlExtension['name']) -Evidence $evidence -Remediation 'Run ./scripts/configure-arc.ps1, which installs it with license type PAYG.' -DocUrl $setting.DocUrls['configuration'])
    }
    $versionOk = Test-DemoVersionAtLeast -Version $extension.Version -Minimum $minimum
    $licenseOk = $expectation.LicenseTypes.Count -eq 0 -or ($extension.LicenseType -in $expectation.LicenseTypes)
    $evidence = [ordered]@{
        version                = $extension.Version
        minimumVersion         = $minimum
        provisioningState      = $extension.ProvisioningState
        licenseType            = $extension.LicenseType
        expectedLicenseTypes   = $expectation.LicenseTypes
        enableAutomaticUpgrade = $extension.EnableAutomaticUpgrade
    }
    if ($extension.ProvisioningState -eq 'Failed') {
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLEXTENSION' -Target $target -Status 'Fail' -Message ('The {0} extension on {1} failed to provision.' -f $setting.SqlExtension['name'], $target.MachineName) -Evidence $evidence -Remediation 'Look at the extension''s status in the portal (Azure Arc > Machines > arcsql01 > Extensions), then run configure-arc.ps1 again.' -DocUrl $setting.DocUrls['autoDeploy'])
    }
    if ($extension.ProvisioningState -ne 'Succeeded') {
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLEXTENSION' -Target $target -Status 'Warning' -Message ('The {0} extension on {1} is {2}.' -f $setting.SqlExtension['name'], $target.MachineName, $extension.ProvisioningState) -Evidence $evidence -Remediation 'Wait a few minutes and run configure-arc.ps1 again.' -DocUrl $setting.DocUrls['autoDeploy'])
    }
    if (-not $versionOk) {
        $status = if ($expectation.MonitoringSupported) { 'Fail' } else { 'Warning' }
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLEXTENSION' -Target $target -Status $status -Message ('The {0} extension is version {1}; monitoring needs {2} or later.' -f $setting.SqlExtension['name'], $extension.Version, $minimum) -Evidence $evidence -Remediation 'Upgrade the extension (az connectedmachine extension update, or the portal), or turn on automatic extension upgrades.' -DocUrl $setting.DocUrls['autoDeploy'])
    }
    if (-not $licenseOk) {
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLEXTENSION' -Target $target -Status 'Fail' -Message ('The extension''s license type is ''{0}''; {1} mode expects {2}.' -f $extension.LicenseType, $target.InstallMode, ($expectation.LicenseTypes -join ' or ')) -Evidence $evidence -Remediation 'Run ./scripts/configure-arc.ps1, which sets license type PAYG and keeps the other settings.' -DocUrl $setting.DocUrls['configuration'])
    }
    return (New-DemoArcResult -CheckId 'T2.ARC.SQLEXTENSION' -Target $target -Status 'Pass' -Message ('The {0} extension {1} is Succeeded with license type {2}.' -f $setting.SqlExtension['name'], $extension.Version, $(if ($extension.LicenseType) { $extension.LicenseType } else { 'unset' })) -Evidence $evidence -DocUrl $docUrl)
}

function Test-DemoArcSqlInstance {
    # T2.ARC.SQLINSTANCE: the SQL Server instance resource exists with the mode's edition and license type, and records billable cores. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State
    )

    $target = $State.Target
    $setting = $target.Setting
    $expectation = Get-DemoArcExpectation -InstallMode $target.InstallMode
    $docUrl = $setting.DocUrls['sqlInstancesRest']
    if ($null -eq $State.Machine) {
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLINSTANCE' -Target $target -Status 'Fail' -Message ('The Arc machine {0} doesn''t exist, so there''s no SQL Server instance resource.' -f $target.MachineName) -Remediation 'Run ./scripts/configure-arc.ps1.' -DocUrl $docUrl)
    }
    $info = Get-DemoArcInstanceInfo -Instance @($State.HostedInstances) -MinimumCores $setting.MinimumCoresPerOse
    if ($null -eq $info) {
        $sqlDetected = Test-DemoArcSqlDetected -Machine $State.Machine
        if (-not $sqlDetected -and $target.InstallMode -eq 'PaygWizard') {
            return (New-DemoArcResult -CheckId 'T2.ARC.SQLINSTANCE' -Target $target -Status 'Manual action required' -Message 'There''s no SQL Server instance resource yet: SQL Server is installed by the PaygWizard setup-wizard step, which is still pending.' -Remediation 'Follow the setup-wizard steps in docs/deployment.md, then run configure-arc.ps1 again.' -DocUrl $setting.DocUrls['autoDeploy'])
        }
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLINSTANCE' -Target $target -Status 'Warning' -Message ('There''s no SQL Server instance resource for {0} yet; the extension creates it within minutes of detecting SQL Server.' -f $target.MachineName) -Evidence ([ordered]@{ sqlDetected = $sqlDetected }) -Remediation 'Run configure-arc.ps1 again in a few minutes.' -DocUrl $setting.DocUrls['autoDeploy'])
    }
    $evidence = [ordered]@{
        name                = $info.Name
        instanceName        = $info.InstanceName
        edition             = $info.Edition
        licenseType         = $info.LicenseType
        version             = $info.Version
        currentVersion      = $info.CurrentVersion
        status              = $info.Status
        vCore               = $info.VCore
        cores               = $info.Cores
        billableCores       = $info.BillableCores
        billableCoresBasis  = ('the larger of {0} and the OSE''s cores (manage-license-billing, Metering section); replaces the t2ArcBillableCores assumption' -f $setting.MinimumCoresPerOse)
        lastUsageUploadTime = $info.LastUsageUploadTime
        instances           = $info.Count
    }
    $editionOk = $info.Edition -in $expectation.Editions
    $licenseOk = $expectation.LicenseTypes.Count -eq 0 -or ($info.LicenseType -in $expectation.LicenseTypes)
    if (-not $editionOk) {
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLINSTANCE' -Target $target -Status 'Fail' -Message ('The SQL Server instance {0} is {1} edition; {2} mode expects {3}.' -f $info.Name, $info.Edition, $target.InstallMode, ($expectation.Editions -join ' or ')) -Evidence $evidence -Remediation 'Rebuild the guest with the intended install mode (reset-demo.ps1 -RebuildGuest), or change t2SqlInstallMode to match.' -DocUrl $setting.DocUrls['licenseBilling'])
    }
    if (-not $licenseOk) {
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLINSTANCE' -Target $target -Status 'Fail' -Message ('The SQL Server instance {0} has license type ''{1}''; {2} mode expects {3}.' -f $info.Name, $info.LicenseType, $target.InstallMode, ($expectation.LicenseTypes -join ' or ')) -Evidence $evidence -Remediation 'Run ./scripts/configure-arc.ps1, which sets the host license type; the instance follows within minutes.' -DocUrl $setting.DocUrls['configuration'])
    }
    if ($info.Version -and $info.Version -notmatch '2022') {
        return (New-DemoArcResult -CheckId 'T2.ARC.SQLINSTANCE' -Target $target -Status 'Warning' -Message ('The SQL Server instance {0} reports version {1}; the demo installs SQL Server 2022.' -f $info.Name, $info.Version) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoArcResult -CheckId 'T2.ARC.SQLINSTANCE' -Target $target -Status 'Pass' -Message ('The SQL Server instance {0} is {1} edition with license type {2} ({3}; about {4} billable cores).' -f $info.Name, $info.Edition, $(if ($info.LicenseType) { $info.LicenseType } else { 'unset' }), $(if ($info.Version) { $info.Version } else { 'version not reported' }), $info.BillableCores) -Evidence $evidence -DocUrl $docUrl)
}

function Test-DemoArcMonitoring {
    # T2.ARC.MONITORING: properties.monitoring.enabled on the instance, with the documented prerequisites. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State
    )

    $target = $State.Target
    $setting = $target.Setting
    $docUrl = $setting.DocUrls['monitoring']
    $expectation = Get-DemoArcExpectation -InstallMode $target.InstallMode
    if (-not $expectation.MonitoringSupported) {
        return (New-DemoArcResult -CheckId 'T2.ARC.MONITORING' -Target $target -Status 'Not supported' -Message 'Developer mode: SQL Server enabled by Azure Arc monitoring needs Standard or Enterprise with Software Assurance or pay-as-you-go, so T2 shows in the Estate view only (ADR 0006).' -DocUrl $docUrl)
    }
    if ($null -eq $State.Machine) {
        return (New-DemoArcResult -CheckId 'T2.ARC.MONITORING' -Target $target -Status 'Fail' -Message ('The Arc machine {0} doesn''t exist, so monitoring can''t be on.' -f $target.MachineName) -Remediation 'Run ./scripts/configure-arc.ps1.' -DocUrl $docUrl)
    }
    $info = Get-DemoArcInstanceInfo -Instance @($State.HostedInstances) -MinimumCores $setting.MinimumCoresPerOse
    if ($null -eq $info) {
        $sqlDetected = Test-DemoArcSqlDetected -Machine $State.Machine
        if (-not $sqlDetected -and $target.InstallMode -eq 'PaygWizard') {
            return (New-DemoArcResult -CheckId 'T2.ARC.MONITORING' -Target $target -Status 'Manual action required' -Message 'Monitoring is turned on once SQL Server exists: the PaygWizard setup-wizard step is still pending.' -Remediation 'Finish the setup-wizard step, then run configure-arc.ps1 again.' -DocUrl $docUrl)
        }
        return (New-DemoArcResult -CheckId 'T2.ARC.MONITORING' -Target $target -Status 'Warning' -Message 'There''s no SQL Server instance resource yet, so monitoring can''t be turned on yet.' -Remediation 'Run configure-arc.ps1 again in a few minutes.' -DocUrl $docUrl)
    }
    $extension = Get-DemoArcExtensionInfo -Extension $State.Extension
    $extensionVersion = if ($extension) { $extension.Version } else { '' }
    $problems = @()
    if (-not (Test-DemoVersionAtLeast -Version $extensionVersion -Minimum ([string]$setting.SqlExtension['minimumVersion']))) {
        $problems += ('the extension is version ''{0}'', below {1}' -f $extensionVersion, $setting.SqlExtension['minimumVersion'])
    }
    if ($info.Edition -notin 'Standard', 'Enterprise') {
        $problems += ('the edition is {0}, not Standard or Enterprise' -f $info.Edition)
    }
    if ($info.LicenseType -notin 'PAYG', 'Paid') {
        $problems += ('the license type is ''{0}'', not pay-as-you-go or Software Assurance' -f $info.LicenseType)
    }
    $evidence = [ordered]@{
        instance          = $info.Name
        monitoringEnabled = $info.MonitoringEnabled
        extensionVersion  = $extensionVersion
        edition           = $info.Edition
        licenseType       = $info.LicenseType
        egress            = ('*.{0}.arcdataservices.com' -f $target.Location)
    }
    if (-not $info.MonitoringEnabled) {
        return (New-DemoArcResult -CheckId 'T2.ARC.MONITORING' -Target $target -Status 'Fail' -Message ('Monitoring is off for the SQL Server instance {0}.' -f $info.Name) -Evidence $evidence -Remediation 'Run ./scripts/configure-arc.ps1 or configure-monitoring.ps1, which set properties.monitoring.enabled = true (api-version 2023-09-01-preview).' -DocUrl $docUrl)
    }
    if ($problems.Count -gt 0) {
        return (New-DemoArcResult -CheckId 'T2.ARC.MONITORING' -Target $target -Status 'Fail' -Message ('Monitoring is on for {0}, but Azure collects nothing until the prerequisites are met: {1}.' -f $info.Name, ($problems -join '; ')) -Evidence $evidence -Remediation 'Fix the listed prerequisites; configure-arc.ps1 sets the license type and reports the extension version.' -DocUrl $docUrl)
    }
    return (New-DemoArcResult -CheckId 'T2.ARC.MONITORING' -Target $target -Status 'Pass' -Message ('Monitoring is on for the SQL Server instance {0}, and its documented prerequisites are met; telemetry rows are checked in Phase 9.' -f $info.Name) -Evidence $evidence -DocUrl $docUrl)
}

function Test-DemoArcDisconnection {
    <#
    .SYNOPSIS
    T2.ARC.DISCONNECTEDDAYS: how long the Arc machine has been disconnected (ADR 0006, ADR 0012). Internal.

    .DESCRIPTION
    A pay-as-you-go subscription that stays disconnected for more than 30 days expires, and you're no longer
    authorized to use the software (manage-license-billing). Pass under 21 days (normal while the host is
    stopped), Warning from 21 days, a stronger Warning from 28, and Fail after 30.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State,

        [datetime] $Now = [datetime]::UtcNow
    )

    $target = $State.Target
    $docUrl = $target.Setting.DocUrls['licenseBilling']
    $payg = $target.InstallMode -ne 'Developer'
    if ($null -eq $State.Machine) {
        return (New-DemoArcResult -CheckId 'T2.ARC.DISCONNECTEDDAYS' -Target $target -Status 'Warning' -Message ('The Arc machine {0} doesn''t exist, so there''s no disconnection to measure; T2.ARC.CONNECTED reports the onboarding.' -f $target.MachineName) -DocUrl $docUrl)
    }
    $properties = Get-DemoMemberValue -InputObject $State.Machine -Name 'properties'
    $status = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
    $changed = ConvertTo-DemoUtcDate -Value (Get-DemoMemberValue -InputObject $properties -Name 'lastStatusChange')
    $utcNow = if ($Now.Kind -eq [System.DateTimeKind]::Local) { $Now.ToUniversalTime() } else { $Now }
    if ($status -eq 'Connected') {
        return (New-DemoArcResult -CheckId 'T2.ARC.DISCONNECTEDDAYS' -Target $target -Status 'Pass' -Message ('The Arc machine {0} is Connected.' -f $target.MachineName) -Evidence ([ordered]@{ status = $status; daysDisconnected = 0 }) -DocUrl $docUrl)
    }
    if ($null -eq $changed) {
        return (New-DemoArcResult -CheckId 'T2.ARC.DISCONNECTEDDAYS' -Target $target -Status 'Warning' -Message ('The Arc machine {0} is {1}, and Azure doesn''t say since when.' -f $target.MachineName, $status) -Evidence ([ordered]@{ status = $status }) -Remediation 'Start the demo so the machine reconnects.' -DocUrl $docUrl)
    }
    $days = [System.Math]::Round(($utcNow - $changed).TotalDays, 1)
    $evidence = [ordered]@{ status = $status; lastStatusChange = $changed.ToString('o'); daysDisconnected = $days; payAsYouGo = $payg }
    $lapse = if ($payg) { 'pay-as-you-go expires after more than 30 days disconnected, and then you''re no longer authorized to use the software' } else { 'a long disconnection can expire the agent''s connection' }
    if ($days -gt 30) {
        return (New-DemoArcResult -CheckId 'T2.ARC.DISCONNECTEDDAYS' -Target $target -Status 'Fail' -Message ('The Arc machine {0} has been disconnected for {1} days: {2}.' -f $target.MachineName, $days, $lapse) -Evidence $evidence -Remediation 'Start archost01 so the guest reconnects and check T2.ARC.CONNECTED; if it doesn''t recover, rebuild T2 (reset-demo.ps1 -RebuildGuest) or destroy it.' -DocUrl $docUrl)
    }
    if ($days -ge 28) {
        return (New-DemoArcResult -CheckId 'T2.ARC.DISCONNECTEDDAYS' -Target $target -Status 'Warning' -Message ('Reconnect now: the Arc machine {0} has been disconnected for {1} days, and {2}.' -f $target.MachineName, $days, $lapse) -Evidence $evidence -Remediation 'Start the demo today (./scripts/start-demo.ps1), or park or destroy T2 on purpose.' -DocUrl $docUrl)
    }
    if ($days -ge 21) {
        return (New-DemoArcResult -CheckId 'T2.ARC.DISCONNECTEDDAYS' -Target $target -Status 'Warning' -Message ('The Arc machine {0} has been disconnected for {1} days; {2}.' -f $target.MachineName, $days, $lapse) -Evidence $evidence -Remediation 'Start the demo within the next week (./scripts/start-demo.ps1).' -DocUrl $docUrl)
    }
    return (New-DemoArcResult -CheckId 'T2.ARC.DISCONNECTEDDAYS' -Target $target -Status 'Pass' -Message ('The Arc machine {0} has been {1} for {2} days, which is fine while the host is stopped.' -f $target.MachineName, $status, $days) -Evidence $evidence -DocUrl $docUrl)
}
