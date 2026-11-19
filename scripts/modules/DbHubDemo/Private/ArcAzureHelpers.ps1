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

function ConvertFrom-DemoJsonStringMap {
    <#
    .SYNOPSIS
    The members of a JSON object as name -> the text Azure returned, read with System.Text.Json; an empty hashtable
    when the JSON (or its -Property) isn't an object. Internal.

    .DESCRIPTION
    PowerShell 7's ConvertFrom-Json turns an ISO 8601 string into a [datetime] (a value with an offset into local time),
    and its [string] is "MM/dd/yyyy HH:mm:ss", so a value read that way and written back changes. This reads each
    string as it is; null is '', and any other value is its raw JSON text.
    https://learn.microsoft.com/dotnet/api/system.text.json.jsondocument
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Json,

        [string] $Property = ''
    )

    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Json)) {
        return $map
    }
    $document = [System.Text.Json.JsonDocument]::Parse($Json)
    try {
        $element = $document.RootElement
        if ($Property) {
            $member = [System.Text.Json.JsonElement]::new()
            if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or -not $element.TryGetProperty($Property, [ref]$member)) {
                return $map
            }
            $element = $member
        }
        if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            return $map
        }
        foreach ($item in $element.EnumerateObject()) {
            $kind = $item.Value.ValueKind
            $map[$item.Name] = if ($kind -eq [System.Text.Json.JsonValueKind]::String) { $item.Value.GetString() } elseif ($kind -eq [System.Text.Json.JsonValueKind]::Null) { '' } else { $item.Value.GetRawText() }
        }
    }
    finally {
        $document.Dispose()
    }
    return $map
}

function Get-DemoResourceGroupTag {
    <#
    .SYNOPSIS
    The demo resource group's tags as a hashtable of the values exactly as Azure holds them; empty when the group can't
    be read. Internal.

    .DESCRIPTION
    Read as text (ConvertFrom-DemoJsonStringMap), never through ConvertFrom-Json: a redeploy's template writes these
    tags back (existingResourceGroupTags), and an ISO 8601 date in any of them, a person's own included, came back as
    "MM/dd/yyyy HH:mm:ss" (Phase 28 follow-up). Tags written that way before the fix stay readable: the readers parse
    both forms with the invariant culture, as UTC.
    https://learn.microsoft.com/cli/azure/group#az-group-show
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName
    )

    $group = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('group', 'show', '--name', $ResourceGroupName, '--output', 'json') -AllowFailure
    $tags = @{}
    if ($group.ExitCode -eq 0) {
        $tags = ConvertFrom-DemoJsonStringMap -Json ([string]$group.StdOut) -Property 'tags'
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

    return (Get-DemoVmPowerInfo -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -VmName $VmName).PowerState
}

function Get-DemoVmPowerInfo {
    <#
    .SYNOPSIS
    A VM's power state code (PowerState/running, PowerState/deallocated, ...; empty when unknown) and SinceUtc, the
    time of its provisioning status in the instance view ("the time of the status"), which a start or a deallocation
    sets when it completes; $null when there's none. Internal.
    Source: https://learn.microsoft.com/rest/api/compute/virtual-machines/instance-view (InstanceViewStatus, checked
    2026-11-03).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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
    $power = ''
    $since = $null
    foreach ($status in @($statuses)) {
        $code = [string](Get-DemoMemberValue -InputObject $status -Name 'code')
        if ($code -like 'PowerState/*' -and -not $power) {
            $power = $code
        }
        elseif ($code -like 'ProvisioningState/*' -and $null -eq $since) {
            $since = ConvertTo-DemoUtcDate -Value (Get-DemoMemberValue -InputObject $status -Name 'time')
        }
    }
    return [pscustomobject]@{ PowerState = $power; SinceUtc = $since }
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

function Invoke-DemoArcMigrationAssessmentUpdate {
    <#
    .SYNOPSIS
    Turns on migration assessment for one SQL Server instance with the documented REST API (Sql Server Instances - Update):
    PATCH properties.migration.assessment.enabled = true, at the sqlServerInstances API version in config/versions.json
    (2026-11-18). Returns $true once the setting reads back as on, $false when it doesn't within -WaitSeconds. Internal.

    .DESCRIPTION
    The assessment is free for every edition and runs weekly once it's on (migration-assessment). The body goes through a
    private temporary file, because cmd.exe can't pass JSON to az.cmd; a 409 Conflict is retried. Update can answer
    202 Accepted, and az rest doesn't follow the long-running operation, so the instance is read back until the setting is
    on, every -PollSeconds, at most -WaitSeconds (2026-11-18 review). Throws a redacted error when Azure refuses the
    change, for example a policy's RequestDisallowedByPolicy.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._-]{1,128}$')]
        [string] $InstanceName,

        [ValidateRange(0, 900)]
        [int] $WaitSeconds = 180,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15
    )

    if (-not $PSCmdlet.ShouldProcess($InstanceName, 'Set properties.migration.assessment.enabled = true')) {
        return $false
    }
    $url = Get-DemoArcSqlInstanceUrl -Target $Target -Name $InstanceName
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-arm'
    try {
        $bodyPath = Write-DemoPrivateFile -Directory $directory -Name 'body.json' -Content '{"properties":{"migration":{"assessment":{"enabled":true}}}}'
        $patch = Invoke-DemoAzWithConflictRetry -SubscriptionId $Target.SubscriptionId -ArgumentList @('rest', '--method', 'patch', '--url', $url, '--body', "@$bodyPath") -Label ('Turning on migration assessment for {0}' -f $InstanceName)
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    if ($patch.ExitCode -ne 0) {
        throw ('Turning on migration assessment for {0} failed: {1}' -f $InstanceName, (Protect-DemoText -Text ([string]$patch.StdErr).Trim()))
    }
    $attempts = 1 + [int][System.Math]::Ceiling($WaitSeconds / $PollSeconds)
    for ($i = 0; $i -lt $attempts; $i++) {
        $instance = $null
        foreach ($item in (Get-DemoArmCollection -SubscriptionId $Target.SubscriptionId -Url $Target.SqlInstancesUrl)) {
            if ([string](Get-DemoMemberValue -InputObject $item -Name 'name') -eq $InstanceName) {
                $instance = $item
                break
            }
        }
        $assessment = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $instance -Name 'properties') -Name 'migration') -Name 'assessment'
        if ([bool](Get-DemoMemberValue -InputObject $assessment -Name 'enabled')) {
            Write-DemoLog -Message ('Turned on migration assessment for the SQL Server instance {0}.' -f $InstanceName)
            return $true
        }
        if ($i -lt $attempts - 1) {
            Start-Sleep -Seconds $PollSeconds
        }
    }
    Write-DemoLog -Level Warning -Message ('Azure accepted turning on migration assessment for {0}, but it didn''t read as on within {1} seconds.' -f $InstanceName, $WaitSeconds)
    return $false
}

function Start-DemoArcMigrationAssessment {
    <#
    .SYNOPSIS
    Starts a migration assessment of one SQL Server instance now, as the portal's Run assessment does, with the documented
    REST API (Sql Server Instances - Run Migration Assessment: POST .../runMigrationAssessment), and returns the job's
    status (NotStarted, InProgress, Succeeded, or Failed; "accepted" when the response has none). Internal.

    .DESCRIPTION
    A new assessment replaces the last successful one, so a run is started only until the first one is uploaded
    (Set-DemoArcSqlConfiguration). Throws a redacted error when Azure refuses it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._-]{1,128}$')]
        [string] $InstanceName
    )

    if (-not $PSCmdlet.ShouldProcess($InstanceName, 'Run a migration assessment now')) {
        return ''
    }
    $url = '{0}{1}/runMigrationAssessment?api-version={2}' -f $Target.SqlInstanceUrlStart, $InstanceName, $Target.Setting.SqlInstanceApiVersion
    $post = Invoke-DemoAzWithConflictRetry -SubscriptionId $Target.SubscriptionId -ArgumentList @('rest', '--method', 'post', '--url', $url) -Label ('Starting a migration assessment of {0}' -f $InstanceName)
    if ($post.ExitCode -ne 0) {
        throw ('Starting a migration assessment of {0} failed: {1}' -f $InstanceName, (Protect-DemoText -Text ([string]$post.StdErr).Trim()))
    }
    $status = ''
    if (-not [string]::IsNullOrWhiteSpace($post.StdOut)) {
        try {
            $status = [string](Get-DemoMemberValue -InputObject ($post.StdOut | ConvertFrom-Json -Depth 32) -Name 'jobStatus')
        }
        catch {
            Write-Debug -Message 'The run''s response wasn''t JSON.'
        }
    }
    if ($status -notmatch '^[A-Za-z]{1,32}$') {
        $status = 'accepted'
    }
    Write-DemoLog -Message ('Started a migration assessment of the SQL Server instance {0} (job {1}).' -f $InstanceName, $status)
    return $status
}

function Test-DemoArcMigrationAssessmentRetry {
    <#
    .SYNOPSIS
    Whether a T2.ARC.MIGRATIONASSESSMENT result says the assessment is on, none was uploaded yet, and no run was started:
    the case a later try fixes (Invoke-DemoArcMigrationAssessmentRetry). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Result
    )

    if ($null -eq $Result -or [string](Get-DemoMemberValue -InputObject $Result -Name 'checkId') -ne 'T2.ARC.MIGRATIONASSESSMENT' -or [string](Get-DemoMemberValue -InputObject $Result -Name 'status') -ne 'Warning') {
        return $false
    }
    $evidence = Get-DemoMemberValue -InputObject $Result -Name 'evidence'
    return ([bool](Get-DemoMemberValue -InputObject $evidence -Name 'enabled') -and -not [string](Get-DemoMemberValue -InputObject $evidence -Name 'uploadedAt') -and -not [string](Get-DemoMemberValue -InputObject $evidence -Name 'runStarted'))
}

function Invoke-DemoArcMigrationAssessmentRetry {
    <#
    .SYNOPSIS
    Starts T2's first migration assessment again, every -PollSeconds for at most -WaitMinutes, until Azure takes the run,
    and returns the T2.ARC.MIGRATIONASSESSMENT result. Internal.

    .DESCRIPTION
    Live, 2026-11-18: right after the assessment is turned on, Azure refuses a run (HTTP 500, "There was an unexpected
    problem communicating with the Arc Sql Extension") until the Azure extension for SQL Server has the setting, and a
    try minutes later is taken. deploy.ps1's T2 track calls this after T2's host is Ready, when its first try failed. It
    stops early when the assessment is off, already uploaded, or T2 has no SQL Server instance resource.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(0, 60)]
        [int] $WaitMinutes = 10,

        [ValidateRange(1, 600)]
        [int] $PollSeconds = 120
    )

    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $run = ''
    $problem = ''
    while ($true) {
        $state = Get-DemoArcState -Config $Config
        $info = Get-DemoArcInstanceInfo -Instance @($state.HostedInstances) -MinimumCores $state.Target.Setting.MinimumCoresPerOse
        if ($null -eq $info -or -not $info.MigrationAssessment.Enabled -or $info.MigrationAssessment.UploadedAt) {
            break
        }
        try {
            $run = Start-DemoArcMigrationAssessment -Target $state.Target -InstanceName $info.Name -Confirm:$false
            $problem = ''
            break
        }
        catch {
            $problem = $_.Exception.Message
        }
        if ((Get-Date).AddSeconds($PollSeconds) -gt $deadline) {
            break
        }
        Start-Sleep -Seconds $PollSeconds
    }
    return (Test-DemoArcMigrationAssessment -State $state -RunStatus $run -RunProblem $problem)
}

function Wait-DemoVmHealthState {
    <#
    .SYNOPSIS
    Reads a demo VM's health summary until it reports one of -State, at most -MaxPolls more times. Internal.

    .DESCRIPTION
    Every read is a read-only Run Command (Get-DemoVmHealth). A failed read (for example while the host
    restarts) is logged and retried; it's thrown only when no read succeeded. Returns Health (the last summary
    read), Polls (how many waits were used), so a caller can share one budget across waits, and Full: true when
    the wait stopped because reads found no room for a fresh Run Command name for -FullMinutes, whatever -MaxPolls
    allows (Azure keeps the VM's Run Commands in Deleting; 2026-11-13 live finding).
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
        [int] $PollSeconds = 300,

        [ValidateRange(0, 240)]
        [int] $FullMinutes = 15
    )

    $health = $null
    $lastError = $null
    $polls = 0
    $fullSince = $null
    $full = $false
    while ($true) {
        try {
            $read = Get-DemoVmHealth -Config $Config -VmName $VmName -View Summary
            if ($null -eq $read) {
                break
            }
            $health = $read
            $lastError = $null
            $fullSince = $null
        }
        catch {
            $lastError = $_
            Write-DemoLog -Level Warning -Message ('Reading the health of {0} failed: {1}' -f $VmName, $_.Exception.Message)
            if (Test-DemoRunCommandFullError -Text $_.Exception.Message) {
                if ($null -eq $fullSince) {
                    $fullSince = [System.DateTime]::UtcNow
                }
            }
            else {
                $fullSince = $null
            }
        }
        $current = [string](Get-DemoMemberValue -InputObject $health -Name 'state')
        $full = $null -ne $fullSince -and ([System.DateTime]::UtcNow - $fullSince).TotalMinutes -ge $FullMinutes
        if (($null -ne $health -and $null -eq $lastError -and $current -in $State) -or $polls -ge $MaxPolls -or $full) {
            break
        }
        Write-DemoLog -Message ('{0} reports {1} (step {2}); reading its health again in {3} seconds.' -f $VmName, $(if ($current) { $current } else { 'nothing yet' }), (Get-DemoMemberValue -InputObject $health -Name 'currentStep'), $PollSeconds)
        Start-Sleep -Seconds $PollSeconds
        $polls++
    }
    if ($full) {
        Write-DemoLog -Level Warning -Message ('{0}: its health couldn''t be read for {1} minutes, because Azure keeps its Run Commands in Deleting, so this wait stops here (DEPLOY.RUNCOMMAND.STUCK_{2}).' -f $VmName, $FullMinutes, $VmName.ToUpperInvariant())
    }
    if ($null -eq $health -and $null -ne $lastError) {
        throw $lastError
    }
    return [pscustomobject]@{ Health = $health; Polls = $polls; Full = $full }
}
