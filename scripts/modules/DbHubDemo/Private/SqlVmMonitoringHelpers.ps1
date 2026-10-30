function Merge-DemoSqlIaasFeatureFlag {
    <#
    .SYNOPSIS
    Adds or replaces one feature flag in the SQL IaaS Agent extension's public settings, keeping every other
    setting and flag. Pure; returns an ordered dictionary to write back. Internal.

    .DESCRIPTION
    "SQL IaaS Agent extension settings aren't cumulative. When you update the extension, include all existing
    public settings to avoid unintentionally disabling another feature." This follows the documented merge:
    keep the existing FeatureFlags except one with the same Name, then add { Name, Enable }
    (https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm).
    Names compare without regard to case, as PowerShell's -ne does in the documented script, and an existing
    FeatureFlags key keeps its spelling.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [object] $Settings,

        [Parameter(Mandatory)]
        [string] $Name,

        [bool] $Enable = $true
    )

    $merged = [ordered]@{}
    if ($null -ne $Settings) {
        $copy = $Settings | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
        if ($copy -is [System.Collections.IDictionary]) {
            foreach ($key in $copy.Keys) {
                $merged[$key] = $copy[$key]
            }
        }
    }
    $flagsKey = 'FeatureFlags'
    foreach ($key in @($merged.Keys)) {
        if ([string]::Equals([string]$key, 'FeatureFlags', [System.StringComparison]::OrdinalIgnoreCase)) {
            $flagsKey = [string]$key
        }
    }
    $flags = [System.Collections.Generic.List[object]]::new()
    $existing = $null
    if ($merged.Contains($flagsKey)) {
        $existing = $merged[$flagsKey]
    }
    foreach ($flag in @($existing)) {
        if ($null -eq $flag) {
            continue
        }
        $flagName = [string](Get-DemoMemberValue -InputObject $flag -Name 'Name')
        if (-not [string]::Equals($flagName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $flags.Add($flag)
        }
    }
    $flags.Add([ordered]@{ Name = $Name; Enable = $Enable })
    $merged[$flagsKey] = $flags.ToArray()
    return $merged
}

function Test-DemoSqlIaasFeatureFlag {
    # True when the settings already hold the feature flag with Enable true. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Settings,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $flags = Get-DemoMemberValue -InputObject $Settings -Name 'FeatureFlags'
    foreach ($flag in @($flags)) {
        if ($null -eq $flag) {
            continue
        }
        if ([string]::Equals([string](Get-DemoMemberValue -InputObject $flag -Name 'Name'), $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $enable = Get-DemoMemberValue -InputObject $flag -Name 'Enable'
            return ($enable -eq $true -or [string]$enable -eq 'true')
        }
    }
    return $false
}

function Get-DemoSqlVmMonitoringStatus {
    <#
    .SYNOPSIS
    Finds the performance-monitoring plugin's status in the SQL IaaS Agent extension's instance view. Internal.

    .DESCRIPTION
    When monitoring runs and uploads, the status includes
    DatabaseMonitorArcPlugin: {"State":"Running","MetricsUploadStatus":"OK"} (enable-performance-monitoring-sql-vm,
    "Check the monitoring status"). The documented command reads statuses[0].message; every status and
    substatus message is searched here, so another plugin's line can't hide it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Extension,

        [string] $Plugin = 'DatabaseMonitorArcPlugin'
    )

    $result = [ordered]@{ Found = $false; State = ''; MetricsUploadStatus = ''; Message = '' }
    $instanceView = Get-DemoMemberValue -InputObject $Extension -Name 'instanceView'
    $messages = foreach ($listName in 'statuses', 'substatuses') {
        $list = Get-DemoMemberValue -InputObject $instanceView -Name $listName
        foreach ($status in @($list)) {
            [string](Get-DemoMemberValue -InputObject $status -Name 'message')
        }
    }
    $pattern = [regex]::Escape($Plugin) + '\s*:\s*(\{[^{}]*\})'
    foreach ($message in @($messages)) {
        $match = [regex]::Match([string]$message, $pattern)
        if (-not $match.Success) {
            continue
        }
        $result.Message = $match.Value
        try {
            $json = $match.Groups[1].Value | ConvertFrom-Json
            $result.Found = $true
            $result.State = [string](Get-DemoMemberValue -InputObject $json -Name 'State')
            $result.MetricsUploadStatus = [string](Get-DemoMemberValue -InputObject $json -Name 'MetricsUploadStatus')
        }
        catch {
            Write-Debug -Message 'The monitoring plugin status did not parse as JSON.'
        }
        break
    }
    return [pscustomobject]$result
}

function Restore-DemoSqlVmMonitoringPlugin {
    <#
    .SYNOPSIS
    After T1 starts, or after a deployment, gets Database Hub's monitoring plugin running again when it isn't, and
    returns START.T1.MONITORING (or -CheckId). Internal.

    .DESCRIPTION
    Live (2026-10-22): after a deallocation and a start, the SQL IaaS Agent extension reported
    DatabaseMonitorArcPlugin {"State":"NotRunning"} for more than 90 minutes, so T1 sent no performance
    telemetry; restarting the agent's service (SQLIaaSExtension) brought it to Running and OK within a minute.
    Live (2026-10-26, Phase 24): about a minute after boot the extension reported no plugin status at all. A
    restart then left the plugin NotRunning for hours, while the same restart once the agent had settled brought
    it to Running and OK in 144 seconds.
    So this reads the plugin's state from the extension's instance view (Get-DemoSqlVmMonitoringStatus) and,
    while there's no plugin status yet, waits up to -SettleMinutes for the agent to report one before it
    decides. Only when the DatabaseWatcheronAzureVM flag is set and the plugin isn't Running, or still has no
    status after that wait, it restarts the service with a Run Command and waits up to -WaitMinutes for Running
    and OK. Nothing else changes. A restart that doesn't help is a Warning, not a Fail (ADR 0012): the start's
    other steps hold, validate.ps1's TELEMETRY.T1 is the check that fails without T1 data, and a Fail here would
    also skip start-demo.ps1's -ResetAdminPassword step for T2.
    Live (2026-10-27, Phase 25d): a deployment's template run left the plugin NotRunning too (at 14:11 UTC, still
    at 14:45), while the deployment's Monitoring step only waited for it, so deploy.ps1 calls this as well
    (-CheckId DEPLOY.T1.MONITORING, -Occasion 'the deployment') when that wait ends without Running and OK.
    Live (2026-10-30, Phase 28): the plugin, Running after start-demo.ps1, was NotRunning again less than 90 minutes
    later, so deploy.ps1 checks it on every run (Invoke-DemoT1MonitoringCheck). With -ProgressPath, the status page's
    -ProgressStepId says so while the service restarts: "T1's monitoring stopped after a restart; restarting it, no
    action needed".
    Sources: https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm
    and https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-agent-extension-troubleshoot-known-issues
    (checked 2026-10-22).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $VmName = 'sqlvm01',

        [ValidateRange(0, 30)]
        [int] $SettleMinutes = 5,

        [ValidateRange(1, 30)]
        [int] $WaitMinutes = 5,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15,

        [ValidateSet('START.T1.MONITORING', 'DEPLOY.T1.MONITORING')]
        [string] $CheckId = 'START.T1.MONITORING',

        [ValidateSet('the start', 'the deployment')]
        [string] $Occasion = 'the start',

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [string] $ProgressStepId = 'T1.Monitoring'
    )

    $checkId = $CheckId
    $docUrl = 'https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm'
    $setting = (Get-DemoArcSetting).SqlVm
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $read = {
        $extension = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'extension', 'show', '--resource-group', $resourceGroupName, '--vm-name', $VmName, '--name', [string]$setting['extensionInstanceName'], '--instance-view') -AsJson -AllowFailure
        [pscustomobject]@{ Extension = $extension; Plugin = (Get-DemoSqlVmMonitoringStatus -Extension $extension -Plugin ([string]$setting['statusPlugin'])) }
    }
    $state = & $read
    if ($null -eq $state.Extension) {
        return (New-DemoResult -CheckId $checkId -Area 't1' -Target 'T1' -Status 'Warning' -Message ('The SQL IaaS Agent extension on {0} couldn''t be read, so its monitoring plugin wasn''t checked.' -f $VmName) -Remediation './scripts/configure-monitoring.ps1 checks and repairs T1''s monitoring.' -DocUrl $docUrl)
    }
    $settings = Get-DemoMemberValue -InputObject $state.Extension -Name 'settings'
    if (-not (Test-DemoSqlIaasFeatureFlag -Settings $settings -Name ([string]$setting['featureFlag']))) {
        return (New-DemoResult -CheckId $checkId -Area 't1' -Target 'T1' -Status 'Not selected' -Message ('Performance monitoring isn''t turned on for {0} ({1} isn''t set), so there''s no plugin to check.' -f $VmName, $setting['featureFlag']) -DocUrl $docUrl)
    }
    # Right after boot the agent hasn't reported the plugin yet, and a restart then can leave it NotRunning.
    $settlePolls = 0
    $maxSettlePolls = [int][Math]::Ceiling($SettleMinutes * 60 / $PollSeconds)
    $settle = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not ($state.Plugin.Found -and $state.Plugin.State) -and $settlePolls -lt $maxSettlePolls -and $settle.Elapsed.TotalMinutes -lt $SettleMinutes) {
        if ($settlePolls -eq 0) {
            Write-DemoLog -Message ('{0}''s SQL IaaS Agent reports no monitoring plugin status yet; waiting up to {1} minutes for one before deciding, because a restart this early can leave the plugin NotRunning.' -f $VmName, $SettleMinutes)
        }
        Start-Sleep -Seconds $PollSeconds
        $settlePolls++
        $state = & $read
    }
    $settledSeconds = [int]$settle.Elapsed.TotalSeconds
    $reported = [bool]($state.Plugin.Found -and $state.Plugin.State)
    $evidence = [ordered]@{ before = $state.Plugin.Message; settlePolls = $settlePolls; settledSeconds = $settledSeconds; restarted = $false; after = '' }
    if ($state.Plugin.State -eq 'Running') {
        $evidence['after'] = $state.Plugin.Message
        $waited = if ($settlePolls -gt 0) { ', reported {0:N0} seconds after the check began' -f $settledSeconds } else { '' }
        return (New-DemoResult -CheckId $checkId -Area 't1' -Target 'T1' -Status 'Pass' -Message ('{0}''s monitoring plugin is running (upload status ''{1}''){2}.' -f $VmName, $state.Plugin.MetricsUploadStatus, $waited) -Evidence $evidence -DocUrl $docUrl)
    }
    # The SQL IaaS Agent's main service (vm/dsc/sqlvm.psd1 AgentServiceName; the known-issues page above).
    $service = 'SQLIaaSExtension'
    $script = @"
`$ErrorActionPreference = 'Stop'
Restart-Service -Name '$service' -Force
[Console]::Out.WriteLine(('$service is {0}.' -f (Get-Service -Name '$service').Status))
"@
    $before = if ($reported) { $state.Plugin.Message } else { 'no plugin status after {0:N0} seconds' -f $settledSeconds }
    Write-DemoLog -Message ('{0}''s monitoring plugin reports {1}; restarting the SQL IaaS Agent service so it starts again.' -f $VmName, $before)
    Set-DemoProgressStep -Path $ProgressPath -Id $ProgressStepId -State 'Running' -AzureSide -Message 'T1''s monitoring stopped after a restart; restarting it, no action needed.'
    $run = Invoke-DemoVmRunCommand -Config $Config -VmName $VmName -RunCommandName 'DbHubDemo-MonitoringRestart' -Script $script -TimeoutSeconds 300
    $evidence['restarted'] = [bool]$run.Succeeded
    if (-not $run.Succeeded) {
        return (New-DemoResult -CheckId $checkId -Area 't1' -Target 'T1' -Status 'Warning' -Message ('{0}''s monitoring plugin isn''t running ({1}), and the SQL IaaS Agent service couldn''t be restarted.' -f $VmName, $before) -Remediation ('Restart the {0} service on {1}, or run ./scripts/configure-monitoring.ps1.' -f $service, $VmName) -Evidence $evidence -DocUrl $docUrl)
    }
    $polls = 0
    $maxPolls = [int][Math]::Ceiling($WaitMinutes * 60 / $PollSeconds)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($polls -lt $maxPolls -and $watch.Elapsed.TotalMinutes -lt $WaitMinutes) {
        Start-Sleep -Seconds $PollSeconds
        $polls++
        $state = & $read
        if ($state.Plugin.State -eq 'Running' -and $state.Plugin.MetricsUploadStatus -eq 'OK') {
            $evidence['after'] = $state.Plugin.Message
            return (New-DemoResult -CheckId $checkId -Area 't1' -Target 'T1' -Status 'Pass' -Message ('{0}''s monitoring plugin wasn''t running after {1} ({2}); the SQL IaaS Agent service was restarted, and it''s Running with uploads OK after {3:N0} seconds.' -f $VmName, $Occasion, $before, $watch.Elapsed.TotalSeconds) -Evidence $evidence -DocUrl $docUrl)
        }
    }
    $evidence['after'] = $state.Plugin.Message
    $after = if ($state.Plugin.Message) { $state.Plugin.Message } else { 'no plugin status' }
    return (New-DemoResult -CheckId $checkId -Area 't1' -Target 'T1' -Status 'Warning' -Message ('{0}''s monitoring plugin still reports {1} {2} minutes after the SQL IaaS Agent service was restarted, so T1 may send no performance telemetry.' -f $VmName, $after, $WaitMinutes) -Remediation './scripts/configure-monitoring.ps1 -WaitMinutes 15 checks it again; ./scripts/validate.ps1 -Area Telemetry shows whether data arrives.' -Evidence $evidence -DocUrl $docUrl)
}

function Invoke-DemoT1MonitoringCheck {
    <#
    .SYNOPSIS
    T1's monitoring plugin, checked by a deploy.ps1 run that has no T1 Monitoring step of its own, and before a NOT DONE
    for T1's telemetry (Phase 28 live finding, 2026-10-30): Restore-DemoSqlVmMonitoringPlugin as DEPLOY.T1.MONITORING,
    with the status page's T1 Monitoring step. Never throws: a check that can't run is a Warning. Internal.

    .DESCRIPTION
    Live: start-demo.ps1 found the plugin Running at 07:47; by 09:12 the SQL IaaS Agent extension reported
    DatabaseMonitorArcPlugin {"State":"NotRunning"}, and the resumed deploy.ps1, whose T1 track had finished in an earlier
    run, ended NOT DONE on TELEMETRY.T1. Restarting the agent's service brought the plugin to Running and OK in 161
    seconds.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('the start', 'the deployment')]
        [string] $Occasion = 'the deployment',

        [AllowEmptyString()]
        [string] $ProgressPath = ''
    )

    $stepId = 'T1.Monitoring'
    Set-DemoProgressStep -Path $ProgressPath -Id $stepId -State 'Running' -AzureSide -Message 'Checking T1''s monitoring plugin, which can stop after a restart: no action needed.'
    try {
        $result = Restore-DemoSqlVmMonitoringPlugin -Config $Config -CheckId 'DEPLOY.T1.MONITORING' -Occasion $Occasion -ProgressPath $ProgressPath -ProgressStepId $stepId
    }
    catch {
        $result = New-DemoResult -CheckId 'DEPLOY.T1.MONITORING' -Area 't1' -Target 'T1' -Status 'Warning' -Message ('T1''s monitoring plugin couldn''t be checked: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation './scripts/start-demo.ps1 checks it, and restarts the SQL IaaS Agent service when the plugin isn''t running; ./scripts/validate.ps1 -Area Telemetry shows whether T1''s data arrives.' -DocUrl 'https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm'
    }
    Set-DemoProgressStep -Path $ProgressPath -Id $stepId -Status ([string]$result.status) -Message ([string]$result.message)
    return $result
}
function Test-DemoSqlVmMonitoringStuck {
    <#
    .SYNOPSIS
    True when a T1.SQLVM.MONITORING result (Enable-DemoSqlVmMonitoring, after its wait) shows a running VM whose
    SqlIaasExtension is Succeeded with the monitoring flag set, while the plugin reports a state other than Running:
    waiting doesn't bring it back, and a restart of the agent does (Restore-DemoSqlVmMonitoringPlugin; live,
    2026-10-22, 2026-10-26, and 2026-10-27). Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Result
    )

    if ($null -eq $Result -or [string](Get-DemoMemberValue -InputObject $Result -Name 'status') -ne 'Warning') {
        return $false
    }
    $evidence = Get-DemoMemberValue -InputObject $Result -Name 'evidence'
    $power = [string](Get-DemoMemberValue -InputObject $evidence -Name 'powerState')
    return ([string](Get-DemoMemberValue -InputObject $evidence -Name 'provisioningState') -eq 'Succeeded' -and
        [bool](Get-DemoMemberValue -InputObject $evidence -Name 'featureFlagEnabled') -and
        [string](Get-DemoMemberValue -InputObject $evidence -Name 'pluginState') -ne 'Running' -and
        $power -in @('', 'PowerState/running'))
}

function Get-DemoSqlVmInventoryInstance {
    <#
    .SYNOPSIS
    T1's SQL Server instance resources from unified inventory, read-only: every
    Microsoft.AzureArcData/sqlServerInstances resource in the resource group whose containerResourceId is the
    Azure VM. That's the database engine plus any associated service the image installed; the SQL Server 2022
    Standard Marketplace image adds SSAS and SSIS (live finding, 2026-10-20). Throws when the list can't be
    read. Internal.
    https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/unified-inventory-sql-vm
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    $setting = Get-DemoArcSetting
    $url = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.AzureArcData/sqlServerInstances?api-version={2}' -f $SubscriptionId, $ResourceGroupName, $setting.SqlInstanceApiVersion
    $instances = Get-DemoArmCollection -SubscriptionId $SubscriptionId -Url $url
    # The container is the Compute VM's ID (confirmed live, 2026-10-20). It's matched by its last segment,
    # because the casing of the resourceGroups segment differs between instances.
    foreach ($instance in @($instances)) {
        $container = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $instance -Name 'properties') -Name 'containerResourceId')
        if ($container -notmatch '/Microsoft\.HybridCompute/' -and $container -match ('/{0}$' -f [regex]::Escape($VmName))) {
            $instance
        }
    }
}

function Get-DemoSqlVmMonitoringState {
    <#
    .SYNOPSIS
    Reads what T1 performance monitoring depends on, read-only: the SqlIaasExtension with its instance view,
    the VM's identity and power state, the Microsoft.Sql and Microsoft.AzureArcData registrations, and T1's
    SQL Server instance resources from unified inventory. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $VmName = 'sqlvm01'
    )

    $setting = Get-DemoArcSetting
    $sqlVm = $setting.SqlVm
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $extension = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'extension', 'show', '--resource-group', $resourceGroupName, '--vm-name', $VmName, '--name', [string]$sqlVm['extensionInstanceName'], '--instance-view') -AsJson -AllowFailure
    $vm = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $resourceGroupName, '--name', $VmName) -AsJson -AllowFailure
    # A deallocated VM's extension instance view is empty: no version and no plugin status (Phase 14 live finding).
    $powerState = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName
    # Learn lists "full management mode" among the prerequisites, while the SQL VM API now detects the mode
    # itself; the value is recorded as evidence only (az sql vm show,
    # https://learn.microsoft.com/cli/azure/sql/vm#az-sql-vm-show).
    $sqlVirtualMachine = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('sql', 'vm', 'show', '--resource-group', $resourceGroupName, '--name', $VmName) -AsJson -AllowFailure
    $sqlManagement = [string](Get-DemoMemberValue -InputObject $sqlVirtualMachine -Name 'sqlManagement')
    if (-not $sqlManagement) {
        $sqlManagement = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $sqlVirtualMachine -Name 'properties') -Name 'sqlManagement')
    }
    $providers = [ordered]@{}
    foreach ($namespace in 'Microsoft.Sql', 'Microsoft.AzureArcData') {
        $provider = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('provider', 'show', '--namespace', $namespace, '--query', 'registrationState', '--output', 'tsv') -AllowFailure
        $providers[$namespace] = if ($provider.ExitCode -eq 0) { ([string]$provider.StdOut).Trim() } else { 'Unknown' }
    }
    $inventory = @()
    try {
        $inventory = @(Get-DemoSqlVmInventoryInstance -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The SQL Server instances in {0} could not be read: {1}' -f $resourceGroupName, $_.Exception.Message)
    }
    [pscustomobject]@{
        VmName             = $VmName
        SubscriptionId     = $subscriptionId
        ResourceGroupName  = $resourceGroupName
        Location           = [string]$Config['location']
        Setting            = $sqlVm
        Extension          = $extension
        Vm                 = $vm
        PowerState         = $powerState
        SqlManagement      = $sqlManagement
        Providers          = $providers
        InventoryInstances = $inventory
    }
}

function ConvertTo-DemoSqlVmMonitoringResult {
    <#
    .SYNOPSIS
    T1.SQLVM.MONITORING from a monitoring state (Get-DemoSqlVmMonitoringState). Internal.

    .DESCRIPTION
    Fail: the extension is missing, not Succeeded, or older than 2.0.229.0; the VM has no system-assigned
    identity; Microsoft.AzureArcData isn't registered; the feature flag isn't set; or MetricsUploadStatus
    contains an HTTP error (the documented troubleshooting symptom for a blocked endpoint or identity).
    Warning: the flag is set but the plugin doesn't report Running and OK yet (allow 3 to 15 minutes; NotRunning
    can mean the setting hasn't applied yet), Microsoft.Sql isn't registered (Hub needs it), or unified
    inventory has no instance yet. Pass: DatabaseMonitorArcPlugin reports State Running and MetricsUploadStatus
    OK. With -PrerequisitesOnly, returns the first failed prerequisite, or $null when nothing blocks writing
    the feature flag.
    A VM that isn't running (State.PowerState, for example the nightly auto-shutdown) has an empty instance
    view, so its extension version and plugin status can't be read: what can be read is still checked, and
    the result is a Warning to start the VM, never a Fail on the missing version (Phase 14).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State,

        [string[]] $Action = @(),

        [switch] $PrerequisitesOnly
    )

    $setting = $State.Setting
    $docUrl = 'https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm'
    $minimum = [string]$setting['minimumVersion']
    $flagName = [string]$setting['featureFlag']
    $properties = $State.Extension
    $instanceView = Get-DemoMemberValue -InputObject $properties -Name 'instanceView'
    $version = [string](Get-DemoMemberValue -InputObject $instanceView -Name 'typeHandlerVersion')
    $provisioning = [string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState')
    $identityType = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $State.Vm -Name 'identity') -Name 'type')
    $flagSet = Test-DemoSqlIaasFeatureFlag -Settings (Get-DemoMemberValue -InputObject $properties -Name 'settings') -Name $flagName
    $plugin = Get-DemoSqlVmMonitoringStatus -Extension $properties -Plugin ([string]$setting['statusPlugin'])
    $editions = @($State.InventoryInstances | ForEach-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'edition') })
    $powerState = [string](Get-DemoMemberValue -InputObject $State -Name 'PowerState')
    $notRunning = $powerState -and $powerState -ne 'PowerState/running'
    $evidence = [ordered]@{
        vmName              = $State.VmName
        extensionVersion    = $version
        minimumVersion      = $minimum
        provisioningState   = $provisioning
        identityType        = $identityType
        featureFlag         = $flagName
        featureFlagEnabled  = $flagSet
        pluginState         = $plugin.State
        metricsUploadStatus = $plugin.MetricsUploadStatus
        providers           = $State.Providers
        inventoryInstances  = @($State.InventoryInstances).Count
        editions            = $editions
        sqlManagement       = $State.SqlManagement
        egress              = ('telemetry.{0}.arcdataservices.com:443' -f $State.Location)
        actions             = @($Action)
        pending             = $false
        powerState          = $powerState
    }
    $new = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $docUrl
    }

    if ($null -eq $properties) {
        return (& $new 'Fail' ('{0} has no SqlIaasExtension, so performance monitoring can''t run.' -f $State.VmName) 'Check the SQL virtual machine registration (sqlvm01.bicep), then run configure-monitoring.ps1 again.')
    }
    if ($provisioning -in @('Updating', 'Creating')) {
        # Live finding (Phase 13): a template deployment keeps the extension Updating for about 10 minutes, and
        # the monitoring flag survives it, so this is a wait, not a failure.
        $evidence['pending'] = $true
        return (& $new 'Warning' ('The SqlIaasExtension on {0} is {1}; a template deployment keeps it there for about 10 minutes.' -f $State.VmName, $provisioning) 'Wait, then run configure-monitoring.ps1 -Target T1 -WaitMinutes 15.')
    }
    if ($provisioning -ne 'Succeeded') {
        return (& $new 'Fail' ('The SqlIaasExtension on {0} is {1}, not Succeeded.' -f $State.VmName, $provisioning) 'Wait for the extension, or repair it in the portal (SQL virtual machines), then run configure-monitoring.ps1 again.')
    }
    if (-not ($notRunning -and -not $version) -and -not (Test-DemoVersionAtLeast -Version $version -Minimum $minimum)) {
        return (& $new 'Fail' ('The SqlIaasExtension on {0} is version ''{1}''; performance monitoring needs {2} or later.' -f $State.VmName, $version, $minimum) ('Update it: az vm extension set --resource-group {0} --vm-name {1} --name SqlIaasExtension --publisher Microsoft.SqlServer.Management (unified-inventory-sql-vm), then run configure-monitoring.ps1 again.' -f $State.ResourceGroupName, $State.VmName))
    }
    if ($identityType -notmatch 'SystemAssigned') {
        return (& $new 'Fail' ('{0} has no system-assigned managed identity, which the extension uploads telemetry with.' -f $State.VmName) 'Deploy the template again (windows-vm.bicep turns the identity on).')
    }
    if ([string]$State.Providers['Microsoft.AzureArcData'] -ne 'Registered') {
        return (& $new 'Fail' ('Microsoft.AzureArcData is {0}, not Registered.' -f $State.Providers['Microsoft.AzureArcData']) 'Run preflight.ps1, which registers it, or: az provider register --namespace Microsoft.AzureArcData.')
    }
    if ($notRunning) {
        $shown = $powerState -replace '^PowerState/', ''
        $start = 'Start it (./scripts/start-demo.ps1, or az vm start --resource-group {0} --name {1} --subscription {2}), wait a few minutes, then' -f $State.ResourceGroupName, $State.VmName, $State.SubscriptionId
        if (-not $PrerequisitesOnly -and -not $flagSet) {
            return (& $new 'Fail' ('The {0} feature flag isn''t set on {1}, which is {2}.' -f $flagName, $State.VmName, $shown) ('{0} run ./scripts/configure-monitoring.ps1, which merges it into the extension''s settings.' -f $start))
        }
        return (& $new 'Warning' ('{0} is {1}, so the SQL IaaS Agent extension can''t report its version or the {2} status; start it to run the T1 checks. What it can read: the {3} flag is {4}, the identity is {5}, and Microsoft.AzureArcData is Registered.' -f $State.VmName, $shown, $setting['statusPlugin'], $flagName, $(if ($flagSet) { 'set' } else { 'not set yet' }), $identityType) ('{0} run the checks again.' -f $start))
    }
    if ($PrerequisitesOnly) {
        return $null
    }
    if (-not $flagSet) {
        return (& $new 'Fail' ('The {0} feature flag isn''t set on {1}.' -f $flagName, $State.VmName) 'Run ./scripts/configure-monitoring.ps1, which merges it into the extension''s settings.')
    }
    if ($plugin.Found -and $plugin.MetricsUploadStatus -ne 'OK' -and $plugin.MetricsUploadStatus -match '(?i)http|error|\b[45]\d\d\b') {
        return (& $new 'Fail' ('Monitoring runs on {0}, but uploads fail: {1}.' -f $State.VmName, $plugin.MetricsUploadStatus) ('Check the VM''s system-assigned identity and outbound HTTPS to telemetry.{0}.arcdataservices.com:443.' -f $State.Location))
    }
    if (-not $plugin.Found -or $plugin.State -ne 'Running' -or $plugin.MetricsUploadStatus -ne 'OK') {
        $evidence['pending'] = $true
        return (& $new 'Warning' ('The {0} flag is set on {1}, but {2} doesn''t report Running and OK yet (state ''{3}'', upload ''{4}''); data usually appears within 3 to 15 minutes.' -f $flagName, $State.VmName, $setting['statusPlugin'], $plugin.State, $plugin.MetricsUploadStatus) 'Run configure-monitoring.ps1 -WaitMinutes 15, or check again later.')
    }
    if ([string]$State.Providers['Microsoft.Sql'] -ne 'Registered') {
        return (& $new 'Warning' 'T1 uploads telemetry, but Microsoft.Sql isn''t Registered; Database Hub needs it.' 'Run preflight.ps1, which registers it.')
    }
    if (@($State.InventoryInstances).Count -eq 0) {
        return (& $new 'Warning' ('T1 uploads telemetry, but unified inventory shows no SQL Server instance for {0} yet; dashboards need it.' -f $State.VmName) 'Wait at least 15 minutes, then check again (unified-inventory-sql-vm).')
    }
    return (& $new 'Pass' ('{0} reports {1} Running with MetricsUploadStatus OK.' -f $State.VmName, $setting['statusPlugin']))
}
