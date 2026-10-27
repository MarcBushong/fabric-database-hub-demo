function Get-DemoArmAccessToken {
    <#
    .SYNOPSIS
    The caller's short-lived Azure Resource Manager token for Arc onboarding (ADR 0005). Internal.

    .DESCRIPTION
    Gets the token with Get-DemoAccessToken ('az account get-access-token --resource
    https://management.azure.com/ --subscription <id>' through Invoke-DemoAz), which checks that its tid claim
    is the configured tenant and its oid claim the caller the subscription guard validated, and registers it
    with Register-DemoSecret before anything else touches it, so it's redacted everywhere and masked in GitHub
    Actions. Callers pass it only as a protected Run Command parameter.
    https://learn.microsoft.com/cli/azure/account#az-account-get-access-token
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    $issued = Get-DemoAccessToken -SubscriptionId $SubscriptionId -Resource $script:ArmTokenResource
    if ($null -eq $issued.Token) {
        throw ('No verified Azure Resource Manager token is available without interaction: {0}' -f $issued.Error)
    }
    return [System.Net.NetworkCredential]::new('', $issued.Token).Password
}

function Get-DemoArcHostIdentity {
    <#
    .SYNOPSIS
    Finds the Arc onboarding identity id-<prefix>-<env>-arc-onboard on the T2 host (ADR 0005, ADR 0009): Found and
    ClientId when it's attached to archost01, so the host requests its own token from IMDS and the operator's
    token isn't used. Internal.

    .DESCRIPTION
    Reads the host's user-assigned identities ('az vm show --query identity.userAssignedIdentities', read-only).
    deploy.ps1 creates and attaches the identity, with Azure Connected Machine Onboarding on the resource group,
    only when assignRoles is true; a redeploy without assignRoles detaches it. Returns Found, ClientId, Name, and
    Reason (why it isn't used).
    https://learn.microsoft.com/cli/azure/vm#az-vm-show
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [object] $Target
    )

    $name = 'id-{0}-{1}-arc-onboard' -f $Config['prefix'], $Config['environment']
    $notFound = {
        param([string] $Reason)
        [pscustomobject]@{ Found = $false; ClientId = ''; Name = $name; Reason = $Reason }
    }
    $read = Invoke-DemoAz -SubscriptionId $Target.SubscriptionId -ArgumentList @('vm', 'show', '--resource-group', $Target.ResourceGroupName, '--name', $Target.HostVmName, '--query', 'identity.userAssignedIdentities', '--output', 'json') -AllowFailure
    if ($read.ExitCode -ne 0) {
        return (& $notFound ('the identities of {0} couldn''t be read: {1}' -f $Target.HostVmName, (Protect-DemoText -Text ([string]$read.StdErr).Trim())))
    }
    $text = ([string]$read.StdOut).Trim()
    $identities = $null
    if ($text -and $text -ne 'null') {
        try {
            $identities = $text | ConvertFrom-Json -AsHashtable
        }
        catch {
            return (& $notFound ('the identities of {0} couldn''t be parsed' -f $Target.HostVmName))
        }
    }
    if ($identities -is [System.Collections.IDictionary]) {
        $suffix = '/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{0}' -f $name
        foreach ($key in $identities.Keys) {
            if (([string]$key).EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $clientId = [string](Get-DemoMemberValue -InputObject $identities[$key] -Name 'clientId')
                if ($clientId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    return [pscustomobject]@{ Found = $true; ClientId = $clientId; Name = $name; Reason = '' }
                }
                return (& $notFound ('{0} is attached to {1} without a client ID' -f $name, $Target.HostVmName))
            }
        }
    }
    return (& $notFound ('{0} isn''t attached to {1} (deploy.ps1 creates it only with assignRoles = true)' -f $name, $Target.HostVmName))
}

function Get-DemoResourceGroupTag {
    # The demo resource group's tags as a hashtable; empty when the group can't be read. Internal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName
    )

    $group = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('group', 'show', '--name', $ResourceGroupName) -AsJson -AllowFailure
    $tags = @{}
    $source = Get-DemoMemberValue -InputObject $group -Name 'tags'
    if ($source -is [System.Collections.IDictionary]) {
        foreach ($key in $source.Keys) {
            $tags[[string]$key] = [string]$source[$key]
        }
    }
    elseif ($null -ne $source) {
        foreach ($property in $source.PSObject.Properties) {
            $tags[$property.Name] = [string]$property.Value
        }
    }
    # In GitHub Actions only: the deployment's random suffix names T3 and T4, so it's masked in the job log (ADR 0022).
    if ($tags.ContainsKey('deploymentId')) {
        Register-DemoLogMask -Value @($tags['deploymentId'])
    }
    return $tags
}

function Get-DemoVmPowerState {
    # The VM's power state code, such as PowerState/running or PowerState/deallocated; empty when unknown. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    $view = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('vm', 'get-instance-view', '--resource-group', $ResourceGroupName, '--name', $VmName) -AsJson -AllowFailure
    $instanceView = Get-DemoMemberValue -InputObject $view -Name 'instanceView'
    $statuses = Get-DemoMemberValue -InputObject $instanceView -Name 'statuses'
    foreach ($status in @($statuses)) {
        $code = [string](Get-DemoMemberValue -InputObject $status -Name 'code')
        if ($code -like 'PowerState/*') {
            return $code
        }
    }
    return ''
}

function Remove-DemoArcStaleResource {
    <#
    .SYNOPSIS
    Deletes a stale Arc machine: first its Microsoft.AzureArcData/sqlServerInstances resources, then the
    Microsoft.HybridCompute/machines resource, each waited on until it's gone (ADR 0005). Internal.

    .DESCRIPTION
    No cascade from machines to sqlServerInstances is documented, so the instances go first
    (https://learn.microsoft.com/sql/sql-server/azure-arc/delete-from-azure-arc). The machine's extensions
    are child resources and go with it. Uses the caller's rights (Contributor); the optional onboarding
    identity can't delete. Returns the deleted resource names. Throws, deleting nothing more, if an
    instance doesn't go away in time, so a machine is never left half-cleaned with its instances.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [ValidateRange(0, 7200)]
        [int] $WaitSeconds = 900,

        [ValidateRange(1, 300)]
        [int] $PollIntervalSeconds = 15
    )

    if (-not $PSCmdlet.ShouldProcess($Target.MachineId, 'Delete the stale Arc machine and its SQL Server instances')) {
        return @()
    }
    $deleted = [System.Collections.Generic.List[string]]::new()
    $instances = Get-DemoArmCollection -SubscriptionId $Target.SubscriptionId -Url $Target.SqlInstancesUrl
    $hosted = Select-DemoArcSqlInstance -Instance $instances -MachineId $Target.MachineId
    foreach ($instance in @($hosted)) {
        $name = [string](Get-DemoMemberValue -InputObject $instance -Name 'name')
        $url = Get-DemoArcSqlInstanceUrl -Target $Target -Name $name
        Write-DemoLog -Message ('Deleting the stale SQL Server instance resource {0} before its machine.' -f $name)
        if (-not (Remove-DemoArmResource -SubscriptionId $Target.SubscriptionId -Url $url -WaitSeconds $WaitSeconds -PollIntervalSeconds $PollIntervalSeconds -Confirm:$false)) {
            throw ('The stale SQL Server instance {0} is still being deleted, so the machine {1} was left in place. Run configure-arc.ps1 again in a few minutes.' -f $name, $Target.MachineName)
        }
        $deleted.Add(('sqlServerInstances/{0}' -f $name))
    }
    Write-DemoLog -Message ('Deleting the stale Arc machine {0}.' -f $Target.MachineName)
    if (-not (Remove-DemoArmResource -SubscriptionId $Target.SubscriptionId -Url $Target.MachineUrl -WaitSeconds $WaitSeconds -PollIntervalSeconds $PollIntervalSeconds -Confirm:$false)) {
        throw ('The stale Arc machine {0} is still being deleted. Run configure-arc.ps1 again in a few minutes.' -f $Target.MachineName)
    }
    $deleted.Add(('machines/{0}' -f $Target.MachineName))
    return $deleted.ToArray()
}

function Wait-DemoArcMachineConnected {
    # Polls the Azure machine until its status is Connected; returns the last machine read, or $null. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [ValidateRange(0, 60)]
        [int] $WaitMinutes = 5,

        [ValidateRange(1, 300)]
        [int] $PollIntervalSeconds = 15
    )

    $attempts = [int][System.Math]::Max(1, [System.Math]::Ceiling($WaitMinutes * 60 / $PollIntervalSeconds))
    $machine = $null
    for ($i = 0; $i -lt $attempts; $i++) {
        $machine = Get-DemoArcArmResource -SubscriptionId $Target.SubscriptionId -Url $Target.MachineUrl
        $status = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $machine -Name 'properties') -Name 'status')
        if ($status -eq 'Connected') {
            return $machine
        }
        if ($i -lt $attempts - 1) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }
    return $machine
}

function Test-DemoArcSqlDetected {
    # True when the Arc machine reports a SQL Server installation (mssqlDiscovered). Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Machine
    )

    $properties = Get-DemoMemberValue -InputObject $Machine -Name 'properties'
    $direct = [string](Get-DemoMemberValue -InputObject $properties -Name 'mssqlDiscovered')
    $detected = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'detectedProperties') -Name 'mssqldiscovered')
    return ($direct -eq 'true' -or $detected -eq 'true')
}

function Get-DemoArcExtensionBody {
    <#
    .SYNOPSIS
    The PUT body for the Azure extension for SQL Server on the Arc machine, with license type PAYG. Internal.

    .DESCRIPTION
    Without an existing extension: publisher Microsoft.AzureData, type WindowsAgent.SqlServer, automatic
    upgrades on, and the documented settings { "SqlManagement": { "IsEnabled": true }, "LicenseType": "PAYG" }
    (manage-configuration). With one: a PUT replaces every setting ("The update command overwrites all
    settings"), so the existing settings are copied whole and only LicenseType changes, under its existing
    key's spelling.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $SqlExtension,

        [Parameter(Mandatory)]
        [string] $Location,

        [AllowNull()]
        [pscustomobject] $Existing,

        [string] $LicenseType = 'PAYG'
    )

    $properties = [ordered]@{
        publisher              = [string]$SqlExtension['publisher']
        type                   = [string]$SqlExtension['type']
        enableAutomaticUpgrade = $true
    }
    if ($null -eq $Existing) {
        $properties['settings'] = [ordered]@{ SqlManagement = [ordered]@{ IsEnabled = $true }; LicenseType = $LicenseType }
    }
    else {
        $settings = [ordered]@{}
        if ($null -ne $Existing.Settings) {
            $copy = $Existing.Settings | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable
            foreach ($key in $copy.Keys) {
                $settings[$key] = $copy[$key]
            }
        }
        $licenseKey = 'LicenseType'
        foreach ($key in @($settings.Keys)) {
            if ([string]::Equals([string]$key, 'LicenseType', [System.StringComparison]::OrdinalIgnoreCase)) {
                $licenseKey = [string]$key
            }
        }
        $settings[$licenseKey] = $LicenseType
        $properties['settings'] = $settings
        if ($Existing.TypeHandlerVersion) {
            $properties['typeHandlerVersion'] = $Existing.TypeHandlerVersion
        }
        if ($null -ne $Existing.AutoUpgradeMinorVersion) {
            $properties['autoUpgradeMinorVersion'] = [bool]$Existing.AutoUpgradeMinorVersion
        }
        if ($null -ne $Existing.EnableAutomaticUpgrade) {
            $properties['enableAutomaticUpgrade'] = [bool]$Existing.EnableAutomaticUpgrade
        }
    }
    return [ordered]@{ location = $Location; properties = $properties }
}

function Wait-DemoArcExtension {
    # Polls the extension until it's Succeeded or Failed; returns the last read, or $null. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 15,

        [ValidateRange(1, 300)]
        [int] $PollIntervalSeconds = 30
    )

    $attempts = [int][System.Math]::Max(1, [System.Math]::Ceiling($WaitMinutes * 60 / $PollIntervalSeconds))
    $extension = $null
    for ($i = 0; $i -lt $attempts; $i++) {
        $extension = Get-DemoArcArmResource -SubscriptionId $Target.SubscriptionId -Url $Target.ExtensionUrl
        $state = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $extension -Name 'properties') -Name 'provisioningState')
        if ($state -in 'Succeeded', 'Failed') {
            return $extension
        }
        if ($i -lt $attempts - 1) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }
    return $extension
}

function Wait-DemoArcSqlInstance {
    # Polls the resource group's SQL Server instances until the machine has one; returns them (possibly none). Internal.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 15,

        [ValidateRange(1, 300)]
        [int] $PollIntervalSeconds = 30
    )

    $attempts = [int][System.Math]::Max(1, [System.Math]::Ceiling($WaitMinutes * 60 / $PollIntervalSeconds))
    $hosted = @()
    for ($i = 0; $i -lt $attempts; $i++) {
        $instances = Get-DemoArmCollection -SubscriptionId $Target.SubscriptionId -Url $Target.SqlInstancesUrl
        $hosted = Select-DemoArcSqlInstance -Instance $instances -MachineId $Target.MachineId
        if (@($hosted).Count -gt 0) {
            break
        }
        if ($i -lt $attempts - 1) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }
    return , @($hosted)
}

function Invoke-DemoArcMonitoringUpdate {
    <#
    .SYNOPSIS
    Turns on monitoring for one SQL Server instance with the documented Azure CLI command (sql-monitoring):
    az resource update ... --set properties.monitoring.enabled=true --api-version 2023-09-01-preview. Internal.

    .DESCRIPTION
    The instance is named with --resource-group, --name, and --resource-type instead of --ids, because
    Invoke-DemoAz adds --subscription to every call. A 409 Conflict is retried. Throws a redacted error on
    failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._-]{1,128}$')]
        [string] $InstanceName
    )

    if (-not $PSCmdlet.ShouldProcess($InstanceName, 'Set properties.monitoring.enabled = true')) {
        return
    }
    $arguments = @(
        'resource', 'update'
        '--resource-group', $Target.ResourceGroupName
        '--name', $InstanceName
        '--resource-type', 'Microsoft.AzureArcData/sqlServerInstances'
        '--set', 'properties.monitoring.enabled=true'
        '--api-version', $Target.Setting.MonitoringApiVersion
    )
    $update = Invoke-DemoAzWithConflictRetry -SubscriptionId $Target.SubscriptionId -ArgumentList $arguments -Label ('Turning on monitoring for {0}' -f $InstanceName)
    if ($update.ExitCode -ne 0) {
        throw ('Turning on monitoring for {0} failed: {1}' -f $InstanceName, (Protect-DemoText -Text ([string]$update.StdErr).Trim()))
    }
    Write-DemoLog -Message ('Turned on monitoring for the SQL Server instance {0}.' -f $InstanceName)
}

function Wait-DemoVmHealthState {
    <#
    .SYNOPSIS
    Reads a demo VM's health summary until it reports one of -State, at most -MaxPolls more times. Internal.

    .DESCRIPTION
    Every read is a read-only Run Command (Get-DemoVmHealth). A failed read (for example while the host
    restarts) is logged and retried; it's thrown only when no read succeeded. Returns Health (the last summary
    read) and Polls (how many waits were used), so a caller can share one budget across waits.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string[]] $State,

        [ValidateRange(0, 1000)]
        [int] $MaxPolls = 0,

        [ValidateRange(1, 3600)]
        [int] $PollSeconds = 300
    )

    $health = $null
    $lastError = $null
    $polls = 0
    while ($true) {
        try {
            $read = Get-DemoVmHealth -Config $Config -VmName $VmName -View Summary
            if ($null -eq $read) {
                break
            }
            $health = $read
            $lastError = $null
        }
        catch {
            $lastError = $_
            Write-DemoLog -Level Warning -Message ('Reading the health of {0} failed: {1}' -f $VmName, $_.Exception.Message)
        }
        $current = [string](Get-DemoMemberValue -InputObject $health -Name 'state')
        if (($null -ne $health -and $null -eq $lastError -and $current -in $State) -or $polls -ge $MaxPolls) {
            break
        }
        Write-DemoLog -Message ('{0} reports {1} (step {2}); reading its health again in {3} seconds.' -f $VmName, $(if ($current) { $current } else { 'nothing yet' }), (Get-DemoMemberValue -InputObject $health -Name 'currentStep'), $PollSeconds)
        Start-Sleep -Seconds $PollSeconds
        $polls++
    }
    if ($null -eq $health -and $null -ne $lastError) {
        throw $lastError
    }
    return [pscustomobject]@{ Health = $health; Polls = $polls }
}
