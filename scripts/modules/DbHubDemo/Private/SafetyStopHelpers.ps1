# The nightly safety stop (ADR 0024), part of every deployment: deploy.ps1 sets it up after the template
# (Invoke-DemoSafetyStopSetup), scripts/grant-safety-stop.ps1 assigns its role for an Owner, and status.ps1
# (STATUS.SAFETYSTOP), validate.ps1 (COST.SAFETYSTOP), the cost estimate's T4 restart worst case, and stop-demo.ps1's and
# status.ps1's T4 texts read it. It doesn't depend on the optional on-demand activity control (ADR 0020): its own
# identity, Automation account, and schedules live in the demo resource group and go with it, and they run the same
# DbHub-Stop runbook code (automation/runbooks) with its own settings. Internal.

# The custom role, as the owner approved it on 2026-11-05 (ADR 0024) and as amended on 2026-11-19 (below): read, stop, and
# delete T5's session-only container, nothing else. It can't start, create, or change anything; it has no Run Command, no
# data action, and no Automation, Key Vault, Fabric, or role permission. Changing this list needs the owner's approval;
# tests/unit/DbHubDemo.SafetyStop.Tests.ps1 fails when it and the ADR differ.
# 2026-11-19 (ADR 0024 and ADR 0027, approved by the owner on 2026-11-19): read and delete T5's session-only container,
# so a session that ended without its stop doesn't leave its provisioned throughput billing all night. It could read or
# delete any Azure Cosmos DB for NoSQL container in the demo resource group, where T5's account is the only account, and
# the runbook deletes contosocare/patient-events only, and only while the DbHubT5Container tag is Session (a session
# creates it again). Nothing of the account, its keys, its network, or its data plane.
# https://learn.microsoft.com/azure/role-based-access-control/permissions/databases#microsoftdocumentdb
$script:SafetyStopRoleName = 'DbHub Demo Safety Stop'
$script:SafetyStopRoleDescription = 'Read and deallocate the Database Hub demo''s VMs, read and stop its PostgreSQL flexible server, read its Azure SQL database''s status, and read and delete its session-only Azure Cosmos DB container. Assigned only at the demo resource group, to the nightly safety stop''s identity.'
$script:SafetyStopRoleActions = @(
    'Microsoft.Resources/subscriptions/resourceGroups/read'
    'Microsoft.Compute/virtualMachines/read'
    'Microsoft.Compute/virtualMachines/instanceView/read'
    'Microsoft.Compute/virtualMachines/deallocate/action'
    'Microsoft.Sql/servers/databases/read'
    'Microsoft.DBforPostgreSQL/flexibleServers/read'
    'Microsoft.DBforPostgreSQL/flexibleServers/stop/action'
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/read'
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/delete'
)
$script:SafetyStopAutomationApiVersion = '2024-10-23'
$script:SafetyStopDoc = 'https://learn.microsoft.com/azure/automation/shared-resources/schedules'
$script:SafetyStopRoleDoc = 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-rest'
# The demo's own tags (infra/main.bicep's commonTags and expiresOn) that the safety stop's resources carry; never
# deploy.ps1's state tags.
$script:SafetyStopTagNames = @('solution', 'environment', 'owner', 'purpose', 'costCenter', 'autoShutdown', 'deploymentId', 'expiresOn')

function Get-DemoSafetyStopName {
    <#
    .SYNOPSIS
    The nightly safety stop's names and ARM IDs (ADR 0024), all in the demo resource group rg-<prefix>-<environment>.
    Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = ([string]$Config['subscriptionId']).ToLowerInvariant()
    $group = Get-DemoResourceGroupName -Config $Config
    $groupId = '/subscriptions/{0}/resourceGroups/{1}' -f $subscriptionId, $group
    $base = '{0}-{1}' -f $Config['prefix'], $Config['environment']
    $account = 'aa-{0}-safetystop' -f $base
    $identity = 'id-{0}-safetystop' -f $base
    return [pscustomobject]@{
        SubscriptionId      = $subscriptionId
        ResourceGroup       = $group
        ResourceGroupId     = $groupId
        AutomationAccount   = $account
        AutomationAccountId = '{0}/providers/Microsoft.Automation/automationAccounts/{1}' -f $groupId, $account
        Identity            = $identity
        IdentityId          = '{0}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{1}' -f $groupId, $identity
        Runbook             = 'DbHub-Stop'
        StopSchedule        = 'dbhub-safety-stop'
        CheckSchedule       = 'dbhub-safety-t3check'
        RoleName            = $script:SafetyStopRoleName
        TemplateDeployment  = 'dbhub-safetystop'
    }
}

function Get-DemoSafetyStopCommand {
    # The exact command an Owner runs once to assign the safety stop's role. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $ConfigPath = ''
    )

    $path = if ($ConfigPath) { $ConfigPath } else { './config/demo.config.json' }
    return ('./scripts/grant-safety-stop.ps1 -ConfigPath {0}' -f $path)
}

function Get-DemoSafetyStopAutoPauseDelay {
    # T3's auto-pause delay as the template sets it: t3AutoPauseMinutes, or the profile's value when it's 0 or missing;
    # -1 when auto-pause is off. Pure. Internal.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $configured = 0
    if ($null -ne $Config['t3AutoPauseMinutes'] -and [string]$Config['t3AutoPauseMinutes'] -ne '') {
        $configured = [int]$Config['t3AutoPauseMinutes']
    }
    if ($configured -ne 0) {
        return $configured
    }
    $profileName = if ($Config['profile']) { [string]$Config['profile'] } else { 'lowest-cost' }
    $t3 = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoProfile) -Name 'profiles') -Name $profileName) -Name 't3'
    $value = Get-DemoMemberValue -InputObject $t3 -Name 'autoPauseMinutes'
    if ($null -eq $value) {
        return 60
    }
    return [int]$value
}

function Get-DemoSafetyStopTime {
    <#
    .SYNOPSIS
    The nightly safety stop's two daily times (ADR 0024), in autoShutdownTimeZone: the stop at autoShutdownTime, the VMs'
    own auto-shutdown time, and its T3 check CheckOffsetMinutes later: 30 minutes, or T3's auto-pause delay plus 15 when
    that's longer, at most 345 (a longer delay, or none, is what the check reports). StopStartTime and CheckStartTime are
    each one's next time at least 10 minutes ahead (Azure Automation wants a schedule's start at least 5 minutes ahead),
    in ISO 8601 with the zone's offset. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $zoneId = if ($Config['autoShutdownTimeZone']) { [string]$Config['autoShutdownTimeZone'] } else { 'UTC' }
    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($zoneId)
    $stop = if ([string]$Config['autoShutdownTime'] -match '^([01]\d|2[0-3])([0-5]\d)$') { [timespan]::new([int]$Matches[1], [int]$Matches[2], 0) } else { [timespan]::new(19, 0, 0) }
    $pause = Get-DemoSafetyStopAutoPauseDelay -Config $Config
    $offset = if ($pause -ge 15) { [System.Math]::Min(345, [System.Math]::Max(30, $pause + 15)) } else { 30 }
    $check = [timespan]::FromMinutes(($stop.TotalMinutes + $offset) % 1440)
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc), $zone)
    $next = {
        param([timespan] $Time)
        $candidate = [datetime]::new($local.Year, $local.Month, $local.Day, 0, 0, 0, [System.DateTimeKind]::Unspecified).Add($Time)
        if ($candidate -le $local.AddMinutes(10)) {
            $candidate = $candidate.AddDays(1)
        }
        if ($zone.IsInvalidTime($candidate)) {
            $candidate = $candidate.AddHours(1)
        }
        ([DateTimeOffset]::new($candidate, $zone.GetUtcOffset($candidate))).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [pscustomobject]@{
        TimeZone           = $zoneId
        StopLocalTime      = '{0:hh\:mm}' -f $stop
        CheckLocalTime     = '{0:hh\:mm}' -f $check
        StopStartTime      = (& $next $stop)
        CheckStartTime     = (& $next $check)
        CheckOffsetMinutes = [int]$offset
        AutoPauseMinutes   = [int]$pause
    }
}

function Get-DemoSafetyStopRunAfter {
    <#
    .SYNOPSIS
    The nightly safety stop's first run at or after -AfterUtc that stops T4 (ADR 0024): its stop, daily at StopLocalTime,
    or with -WithCheck its T3 check, daily at CheckLocalTime, which also stops a running T4 since 2026-11-09
    (Get-DemoSafetyStopTime; both in autoShutdownTimeZone, so daylight saving time moves them in UTC). Returns Run (Stop or
    Check), Utc, LocalTime, and TimeZone. A run at the very minute counts: it waits up to 10 minutes for a T4 that's
    starting. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [datetime] $AfterUtc,

        [switch] $WithCheck
    )

    $after = if ($AfterUtc.Kind -eq [System.DateTimeKind]::Local) { $AfterUtc.ToUniversalTime() } else { [DateTime]::SpecifyKind($AfterUtc, [System.DateTimeKind]::Utc) }
    $when = Get-DemoSafetyStopTime -Config $Config -NowUtc $after
    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($when.TimeZone)
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($after, $zone)
    $runs = @([pscustomobject]@{ Run = 'Stop'; LocalTime = $when.StopLocalTime }) + @(if ($WithCheck) { [pscustomobject]@{ Run = 'Check'; LocalTime = $when.CheckLocalTime } })
    $first = $null
    foreach ($run in $runs) {
        $time = [timespan]::ParseExact($run.LocalTime, 'hh\:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        for ($day = -1; $day -le 2; $day++) {
            $candidate = [datetime]::new($local.Year, $local.Month, $local.Day, 0, 0, 0, [System.DateTimeKind]::Unspecified).AddDays($day).Add($time)
            if ($zone.IsInvalidTime($candidate)) {
                $candidate = $candidate.AddHours(1)
            }
            $utc = [System.TimeZoneInfo]::ConvertTimeToUtc($candidate, $zone)
            if ($utc -ge $after) {
                if ($null -eq $first -or $utc -lt $first.Utc) {
                    $first = [pscustomobject]@{ Run = $run.Run; Utc = $utc; LocalTime = $run.LocalTime; TimeZone = $when.TimeZone }
                }
                break
            }
        }
    }
    return $first
}

function Get-DemoSafetyStopRoleDefinition {
    <#
    .SYNOPSIS
    The custom role "DbHub Demo Safety Stop" as an Azure Resource Manager role definition body, assignable in the
    configured subscription only, with exactly the owner-approved actions. Internal and pure.
    https://learn.microsoft.com/rest/api/authorization/role-definitions/create-or-update
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    return [ordered]@{
        properties = [ordered]@{
            roleName         = $script:SafetyStopRoleName
            description      = $script:SafetyStopRoleDescription
            type             = 'CustomRole'
            permissions      = @([ordered]@{ actions = @($script:SafetyStopRoleActions); notActions = @(); dataActions = @(); notDataActions = @() })
            assignableScopes = @('/subscriptions/{0}' -f $SubscriptionId.ToLowerInvariant())
        }
    }
}

function Get-DemoSafetyStopRunbookSetting {
    <#
    .SYNOPSIS
    The settings baked into the safety stop's DbHub-Stop (ADR 0024): the names it acts on (since 2026-11-19 T5's account and
    container too, ADR 0027), the demo's shutdown time, its waits, and the pinned API versions. The shared code's checks
    also want the control's runbook and schedule names, so they're here with the control's values, though the Nightly and
    T3Check scopes never use them, and its account is this one. Nothing in it is secret: it holds the subscription ID and
    the identity's client ID, which live in Azure only. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $IdentityClientId
    )

    $apiVersions = [ordered]@{}
    # Microsoft.DocumentDB/databaseAccounts (2026-11-19, ADR 0027): T5's session-only container, which the nightly stop
    # deletes when a session's stop didn't.
    foreach ($type in 'Microsoft.Automation/automationAccounts', 'Microsoft.Compute/virtualMachines', 'Microsoft.Resources/resourceGroups', 'Microsoft.Sql/servers/databases', 'Microsoft.DBforPostgreSQL/flexibleServers', 'Microsoft.DocumentDB/databaseAccounts') {
        $apiVersions[$type] = Get-DemoPinnedApiVersion -ResourceType $type
    }
    # T5 (2026-11-19, ADR 0027): its account and container's names, and its throughput for the stop's text, when it's on.
    $t5On = Test-DemoT5Enabled -Config $Config
    $cosmos = Get-DemoCosmosSetting
    $t5Container = $null
    if ($t5On) {
        $t5Container = [ordered]@{ databaseName = [string]$cosmos['databaseName']; containerName = [string]$cosmos['containerName']; throughput = [int]$cosmos['throughputRUs'] }
    }
    return [ordered]@{
        schemaVersion         = 1
        purpose               = 'safety-stop'
        subscriptionId        = $Name.SubscriptionId
        location              = [string]$Config['location']
        demoResourceGroup     = $Name.ResourceGroup
        controlResourceGroup  = $Name.ResourceGroup
        automationAccount     = $Name.AutomationAccount
        identityClientId      = $IdentityClientId.ToLowerInvariant()
        controlRunbook        = 'DbHub-Control'
        stopRunbook           = $Name.Runbook
        monitorRunbook        = 'DbHub-Monitor'
        autoStopSchedule      = 'dbhub-autostop'
        autoStopBufferMinutes = 10
        monitorSchedulePrefix = 'dbhub-monitor-'
        monitorRecheckMinutes = 30
        maxDurationMinutes    = 120
        runCommandPrefix      = 'DbHubControl-'
        sqlVmName             = 'sqlvm01'
        hostVmName            = Get-DemoHostVmName -Config $Config
        t3ServerPrefix        = 'azuresql01-'
        demoDatabase          = 'ContosoCare'
        t4ServerPrefix        = 'pgflex01-'
        # T4's read replica (ADR 0025): the safety stop stops one a session left behind, only after T4 is stopped.
        t4ReplicaPrefix       = ('{0}-' -f (Get-DemoT4ReplicaSetting)['serverNamePrefix'])
        # T5's container (2026-11-19, ADR 0027): the nightly stop deletes one a session's stop didn't, while the demo
        # resource group's DbHubT5Container tag is Session; empty and $null when T5 is off.
        t5AccountPrefix       = $(if ($t5On) { '{0}-' -f $cosmos['accountNamePrefix'] } else { '' })
        t5Container           = $t5Container
        autoShutdownTime      = $(if ($Config['autoShutdownTime']) { [string]$Config['autoShutdownTime'] } else { '1900' })
        autoShutdownTimeZone  = $(if ($Config['autoShutdownTimeZone']) { [string]$Config['autoShutdownTimeZone'] } else { 'UTC' })
        t4WaitMinutes         = 10
        t3CheckMarginMinutes  = 10
        # The busy marker (2026-11-14): a marker further ahead than this is ignored, as no refresh writes it.
        busyMarkerMaximumMinutes = [int]$script:BusyMarkerSetting['maximumMinutes']
        apiVersions           = $apiVersions
    }
}

function Get-DemoSafetyStopLinkScope {
    # A job schedule's or a job's Scope parameter, whatever case Azure gives the parameter's name in; empty without one.
    # Only Job Schedule - Get and Job - Get return the parameters (Get-DemoSafetyStopLink, Get-DemoSafetyStopLastRun).
    # Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Link
    )

    $parameters = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Link -Name 'properties') -Name 'parameters'
    if ($parameters -is [System.Collections.IDictionary]) {
        foreach ($key in @($parameters.Keys)) {
            if ([string]$key -ieq 'Scope') {
                return [string]$parameters[$key]
            }
        }
    }
    elseif ($null -ne $parameters) {
        foreach ($property in @($parameters.PSObject.Properties)) {
            if ($property.Name -ieq 'Scope') {
                return [string]$property.Value
            }
        }
    }
    return ''
}

function Get-DemoSafetyStopLink {
    <#
    .SYNOPSIS
    The safety stop account's job schedules for -Schedule (ADR 0024), each with its Scope read from the link itself.
    Returns Ok, Missing (the account doesn't exist), Error, and Links: Id, Schedule, Runbook, and Scope (empty for a link
    to another runbook, or one without a Scope). Read-only. Internal.

    .DESCRIPTION
    Job Schedule - List By Automation Account gives each link's schedule and runbook, but not its parameters: live on
    2026-11-09 it returned "parameters": null for both safety stop links, whose jobs ran with {"Scope":"Nightly"} and
    {"Scope":"T3Check"}, and Learn's own sample answer shows null too. Job Schedule - Get of one link returns them. So each
    link of -Schedule to DbHub-Stop is read once more by its ID. A link deleted in between is left out; any other failed
    read makes the whole answer not Ok, so a caller never takes an unread link as unlinked.
    - Job Schedule - List By Automation Account: https://learn.microsoft.com/rest/api/automation/job-schedule/list-by-automation-account
    - Job Schedule - Get: https://learn.microsoft.com/rest/api/automation/job-schedule/get
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [string[]] $Schedule
    )

    $version = $script:SafetyStopAutomationApiVersion
    $list = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules' -f $Name.AutomationAccountId) -ApiVersion $version)
    if (-not $list.Ok) {
        return [pscustomobject]@{ Ok = $false; Missing = [bool]$list.Missing; Error = $list.Error; Links = @() }
    }
    $links = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-DemoActivityControlList -InputObject $list.Value -Name 'value')) {
        $properties = Get-DemoMemberValue -InputObject $item -Name 'properties'
        $scheduleName = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'schedule') -Name 'name')
        if ($scheduleName -notin $Schedule) {
            continue
        }
        $runbook = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'runbook') -Name 'name')
        $id = [string](Get-DemoMemberValue -InputObject $properties -Name 'jobScheduleId')
        $scope = ''
        if ($runbook -eq $Name.Runbook -and $id -match '^[0-9a-fA-F-]{36}$') {
            $read = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules/{1}' -f $Name.AutomationAccountId, $id) -ApiVersion $version)
            if ($read.Missing) {
                continue
            }
            if (-not $read.Ok) {
                return [pscustomobject]@{ Ok = $false; Missing = $false; Error = ('the job schedule {0} ({1}) couldn''t be read: {2}' -f $id, $scheduleName, $read.Error); Links = @() }
            }
            $scope = Get-DemoSafetyStopLinkScope -Link $read.Value
        }
        $links.Add([pscustomobject]@{ Id = $id; Schedule = $scheduleName; Runbook = $runbook; Scope = $scope })
    }
    return [pscustomobject]@{ Ok = $true; Missing = $false; Error = ''; Links = $links.ToArray() }
}

function Get-DemoSafetyStopScheduleLocalTime {
    # A schedule's next run as HH:mm in its own time zone, when that zone has the configured zone's rules (Azure
    # Automation gives back a Windows zone in its IANA form, Phase 25d live); empty otherwise. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Schedule,

        [Parameter(Mandatory)]
        [string] $TimeZone
    )

    $properties = Get-DemoMemberValue -InputObject $Schedule -Name 'properties'
    $next = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $properties -Name 'nextRun')
    $zone = Get-DemoActivityControlTimeZone -Id ([string](Get-DemoMemberValue -InputObject $properties -Name 'timeZone'))
    $wanted = Get-DemoActivityControlTimeZone -Id $TimeZone
    if ($null -eq $next -or $null -eq $zone -or $null -eq $wanted -or -not $zone.HasSameRules($wanted)) {
        return ''
    }
    return ('{0:HH\:mm}' -f [System.TimeZoneInfo]::ConvertTimeFromUtc($next, $zone))
}

function Get-DemoSafetyStopPrincipalId {
    # The safety stop identity's principal (object) ID; empty when it doesn't exist or can't be read. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name
    )

    $read = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $Name.IdentityId -ApiVersion (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.ManagedIdentity/userAssignedIdentities'))
    if (-not $read.Ok) {
        return ''
    }
    return [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $read.Value -Name 'properties') -Name 'principalId')
}

function Get-DemoSafetyStopRoleState {
    <#
    .SYNOPSIS
    The custom role "DbHub Demo Safety Stop" in the subscription, found by its name: Id (its GUID, empty when it doesn't
    exist), Actions, and Error (when the role definitions couldn't be read). Internal.
    https://learn.microsoft.com/rest/api/authorization/role-definitions/list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    $read = Invoke-DemoActivityControlArm -SubscriptionId $SubscriptionId -Method get -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions' -f $SubscriptionId) -Query ([ordered]@{ '$filter' = ("roleName eq '{0}'" -f $script:SafetyStopRoleName); 'api-version' = (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Authorization/roleAssignments') })
    if (-not $read.Ok) {
        return [pscustomobject]@{ Id = ''; Actions = @(); Error = $(if ($read.Error) { $read.Error } else { 'the role definitions couldn''t be read' }) }
    }
    $match = @(Get-DemoActivityControlList -InputObject $read.Value -Name 'value') | Where-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'roleName') -ceq $script:SafetyStopRoleName } | Select-Object -First 1
    if ($null -eq $match) {
        return [pscustomobject]@{ Id = ''; Actions = @(); Error = '' }
    }
    $permissions = @(Get-DemoActivityControlList -InputObject (Get-DemoMemberValue -InputObject $match -Name 'properties') -Name 'permissions')
    $actions = @(foreach ($permission in $permissions) { Get-DemoActivityControlList -InputObject $permission -Name 'actions' })
    return [pscustomobject]@{ Id = [string](Get-DemoMemberValue -InputObject $match -Name 'name'); Actions = @($actions | ForEach-Object { [string]$_ }); Error = '' }
}

function Get-DemoDeployerRolePermission {
    <#
    .SYNOPSIS
    Whether the signed-in deployer can write custom role definitions in the subscription (Microsoft.Authorization/
    roleDefinitions/write) and create role assignments at the demo resource group, or at the subscription before the group
    exists (roleAssignments/write): what deploy.ps1 needs to set up the nightly safety stop's and the session control's
    roles in its own run (2026-11-19, the coordinator's option 2). Returns CanDefine, CanAssign, and Error ('' when both were
    read). Never throws: what can't be read counts as $false (fail safe). Internal.
    https://learn.microsoft.com/rest/api/authorization/permissions/list-for-resource-group
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = [string]$Config['subscriptionId']
    try {
        $version = Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Authorization/roleAssignments'
        $subscriptionRead = Invoke-DemoActivityControlArm -SubscriptionId $subscriptionId -Method get -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/permissions?api-version={1}' -f $subscriptionId, $version)
        $groupRead = $subscriptionRead
        if (Test-DemoResourceGroupExist -Config $Config) {
            $groupRead = Invoke-DemoActivityControlArm -SubscriptionId $subscriptionId -Method get -Url ('https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Authorization/permissions?api-version={2}' -f $subscriptionId, (Get-DemoResourceGroupName -Config $Config), $version)
        }
        $canDefine = $subscriptionRead.Ok -and (Test-DemoPermission -Permission @(Get-DemoActivityControlList -InputObject $subscriptionRead.Value -Name 'value') -Action 'Microsoft.Authorization/roleDefinitions/write')
        $canAssign = $groupRead.Ok -and (Test-DemoPermission -Permission @(Get-DemoActivityControlList -InputObject $groupRead.Value -Name 'value') -Action 'Microsoft.Authorization/roleAssignments/write')
        $problem = @(@($subscriptionRead, $groupRead) | Where-Object { -not $_.Ok } | ForEach-Object { [string]$_.Error }) | Select-Object -First 1
        return [pscustomobject]@{ CanDefine = [bool]$canDefine; CanAssign = [bool]$canAssign; Error = [string]$problem }
    }
    catch {
        return [pscustomobject]@{ CanDefine = $false; CanAssign = $false; Error = (Protect-DemoText -Text $_.Exception.Message) }
    }
}

function Get-DemoSafetyStopPlan {
    <#
    .SYNOPSIS
    Whether deploy.ps1 puts the nightly safety stop fully in place in this run (2026-11-19, the coordinator's option 2): its
    template, runbook, and schedules need only Contributor, and its role needs the deployer to assign it at the demo
    resource group and, unless the custom role already has exactly its approved actions, to write it. Returns Planned,
    Reason, and Evidence. -Permission is Get-DemoDeployerRolePermission's answer, read when it isn't given. Never throws:
    what can't be read isn't planned (fail safe). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Permission = $null
    )

    try {
        if ($null -eq $Permission) {
            $Permission = Get-DemoDeployerRolePermission -Config $Config
        }
        $role = Get-DemoSafetyStopRoleState -SubscriptionId ([string]$Config['subscriptionId'])
        $roleReady = [bool]$role.Id -and -not $role.Error -and @(Compare-Object -ReferenceObject @($script:SafetyStopRoleActions) -DifferenceObject @($role.Actions)).Count -eq 0
        $planned = [bool]$Permission.CanAssign -and ([bool]$Permission.CanDefine -or $roleReady)
        $evidence = [ordered]@{ planned = $planned; canDefineRoles = [bool]$Permission.CanDefine; canAssignRoles = [bool]$Permission.CanAssign; roleReady = $roleReady; error = [string]$Permission.Error }
        $reason = if ($planned) {
            'deploy.ps1 sets up the nightly safety stop in this run, right after its template, and you can assign its role'
        }
        elseif (-not $Permission.CanAssign) {
            'you can''t assign the nightly safety stop''s role (it takes an Owner, a User Access Administrator, or a Role Based Access Control Administrator), so deploy.ps1 can''t put it fully in place'
        }
        else {
            'the nightly safety stop''s custom role needs writing first, which takes an Owner or a User Access Administrator'
        }
        return [pscustomobject]@{ Planned = $planned; Reason = $reason; Evidence = $evidence }
    }
    catch {
        return [pscustomobject]@{ Planned = $false; Reason = ('whether deploy.ps1 can set up the nightly safety stop couldn''t be read ({0})' -f (Protect-DemoText -Text $_.Exception.Message)); Evidence = [ordered]@{ planned = $false } }
    }
}

function Invoke-DemoSafetyStopTemplate {
    <#
    .SYNOPSIS
    Deploys infra/safetystop/safetystop.bicep into the demo resource group (ADR 0024): the identity
    id-<prefix>-<environment>-safetystop and the Automation account aa-<prefix>-<environment>-safetystop, with the demo's
    own tags and component safety-stop. Returns Result (SAFETYSTOP.RESOURCES) and Outputs (identityPrincipalId,
    identityClientId), $null when nothing was deployed. The parameters go in a file in a private directory. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name
    )

    $doc = 'https://learn.microsoft.com/azure/automation/automation-create-standalone-account'
    $evidence = [ordered]@{ resourceGroup = $Name.ResourceGroup; automationAccount = $Name.AutomationAccount; identity = $Name.Identity }
    if (-not $PSCmdlet.ShouldProcess($Name.ResourceGroup, ('Deploy infra/safetystop/safetystop.bicep: {0} and {1}' -f $Name.Identity, $Name.AutomationAccount))) {
        return [pscustomobject]@{ Result = (New-DemoResult -CheckId 'SAFETYSTOP.RESOURCES' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} and {1} (Basic, its only identity, local authentication off) would be deployed in {2}.' -f $Name.Identity, $Name.AutomationAccount, $Name.ResourceGroup) -Evidence $evidence -DocUrl $doc); Outputs = $null }
    }
    $tags = [ordered]@{}
    try {
        $groupTags = Get-DemoResourceGroupTag -SubscriptionId $Name.SubscriptionId -ResourceGroupName $Name.ResourceGroup
        foreach ($key in $script:SafetyStopTagNames) {
            if ($groupTags.Contains($key) -and [string]$groupTags[$key]) {
                $tags[$key] = [string]$groupTags[$key]
            }
        }
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The demo resource group''s tags weren''t read for the safety stop: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    $tags['component'] = 'safety-stop'
    $parameters = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{
            location              = @{ value = [string]$Config['location'] }
            automationAccountName = @{ value = $Name.AutomationAccount }
            identityName          = @{ value = $Name.Identity }
            tags                  = @{ value = $tags }
        }
    }
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-safetystop'
    try {
        $path = Write-DemoPrivateFile -Directory $directory -Name 'safetystop.parameters.json' -Content (ConvertTo-Json -InputObject $parameters -Depth 8)
        $template = Join-Path -Path $script:RepoRoot -ChildPath 'infra/safetystop/safetystop.bicep'
        $run = Invoke-DemoAz -SubscriptionId $Name.SubscriptionId -ArgumentList @('deployment', 'group', 'create', '--resource-group', $Name.ResourceGroup, '--name', $Name.TemplateDeployment, '--template-file', $template, '--parameters', "@$path", '--query', 'properties.outputs', '--output', 'json') -AllowFailure -TimeoutSeconds 900
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false -WhatIf:$false | Out-Null
    }
    if ($run.ExitCode -ne 0) {
        return [pscustomobject]@{ Result = (New-DemoResult -CheckId 'SAFETYSTOP.RESOURCES' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('The nightly safety stop isn''t set up: infra/safetystop/safetystop.bicep couldn''t be deployed: {0}' -f (Get-DemoDeploymentErrorText -Text ([string]$run.StdErr) -MaxLength 600)) -Evidence $evidence -Remediation 'Fix the cause (a policy denial names its policy), then run ./scripts/deploy.ps1 again. Meanwhile the VMs'' nightly auto-shutdown and T3''s auto-pause still apply.' -DocUrl $doc); Outputs = $null }
    }
    $raw = $null
    try {
        $raw = [string]$run.StdOut | ConvertFrom-Json -AsHashtable -Depth 16
    }
    catch {
        $raw = $null
    }
    $outputs = [ordered]@{}
    foreach ($key in 'identityPrincipalId', 'identityClientId') {
        $outputs[$key] = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $raw -Name $key) -Name 'value')
    }
    if ($outputs['identityClientId'] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        return [pscustomobject]@{ Result = (New-DemoResult -CheckId 'SAFETYSTOP.RESOURCES' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('{0} and {1} were deployed, but the deployment didn''t return the identity''s client ID, so the runbook wasn''t published.' -f $Name.Identity, $Name.AutomationAccount) -Evidence $evidence -Remediation 'Run ./scripts/deploy.ps1 again.' -DocUrl $doc); Outputs = $null }
    }
    $evidence['identityPrincipalId'] = $outputs['identityPrincipalId']
    return [pscustomobject]@{ Result = (New-DemoResult -CheckId 'SAFETYSTOP.RESOURCES' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('{0} and {1} are deployed in {2}.' -f $Name.Identity, $Name.AutomationAccount, $Name.ResourceGroup) -Evidence $evidence -DocUrl $doc); Outputs = $outputs }
}

function Publish-DemoSafetyStopRunbook {
    <#
    .SYNOPSIS
    Publishes DbHub-Stop (Windows PowerShell 5.1) in the safety stop's account with its own settings (ADR 0024), unless
    the published content is the same already (Runbook - Get Content). Returns SAFETYSTOP.RUNBOOK. Internal.
    - Runbook - Get Content: https://learn.microsoft.com/rest/api/automation/runbook/get-content
    - Runbook - Create Or Update: https://learn.microsoft.com/rest/api/automation/runbook/create-or-update
    - Runbook Draft - Replace Content: https://learn.microsoft.com/rest/api/automation/runbook-draft/replace-content
    - Runbook - Publish: https://learn.microsoft.com/rest/api/automation/runbook/publish
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Setting
    )

    $doc = 'https://learn.microsoft.com/rest/api/automation/runbook-draft/replace-content'
    $version = $script:SafetyStopAutomationApiVersion
    $content = Get-DemoActivityControlRunbookContent -Name $Name.Runbook -Setting $Setting
    $id = '{0}/runbooks/{1}' -f $Name.AutomationAccountId, $Name.Runbook
    $normalize = { param([string] $Text) ($Text -replace "`r`n", "`n").TrimEnd() }
    $published = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ($id + '/content') -ApiVersion $version)
    $evidence = [ordered]@{ automationAccount = $Name.AutomationAccount; runbook = $Name.Runbook }
    if ($published.Ok -and $published.Value -is [string] -and (& $normalize $published.Value) -ceq (& $normalize $content)) {
        $evidence['published'] = 'unchanged'
        return (New-DemoResult -CheckId 'SAFETYSTOP.RUNBOOK' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('{0} is published in {1} with the current code and settings.' -f $Name.Runbook, $Name.AutomationAccount) -Evidence $evidence -DocUrl $doc)
    }
    if (-not $PSCmdlet.ShouldProcess(('{0}/{1}' -f $Name.AutomationAccount, $Name.Runbook), 'Create, replace the content of, and publish the runbook')) {
        return (New-DemoResult -CheckId 'SAFETYSTOP.RUNBOOK' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} would be published in {1} (Windows PowerShell 5.1).' -f $Name.Runbook, $Name.AutomationAccount) -Evidence $evidence -DocUrl $doc)
    }
    $body = [ordered]@{ location = [string]$Config['location']; properties = [ordered]@{ runbookType = 'PowerShell'; logVerbose = $false; logProgress = $false; description = 'Nightly safety stop (ADR 0024): deallocates the demo''s VMs, stops T4, and checks that T3 paused. Published by deploy.ps1.'; draft = @{} } }
    $steps = @(
        @{ Method = 'put'; Url = (Get-DemoActivityControlUrl -Id $id -ApiVersion $version); Body = $body; ContentType = 'application/json'; Label = 'create' }
        @{ Method = 'put'; Url = (Get-DemoActivityControlUrl -Id ($id + '/draft/content') -ApiVersion $version); Body = $content; ContentType = 'text/powershell'; Label = 'replace the draft' }
        @{ Method = 'post'; Url = (Get-DemoActivityControlUrl -Id ($id + '/publish') -ApiVersion $version); Body = $null; ContentType = 'application/json'; Label = 'publish' }
    )
    foreach ($step in $steps) {
        $call = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method $step.Method -Url $step.Url -Body $step.Body -ContentType $step.ContentType
        if (-not $call.Ok) {
            return (New-DemoResult -CheckId 'SAFETYSTOP.RUNBOOK' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('The nightly safety stop''s runbook {0} couldn''t {1}: {2}' -f $Name.Runbook, $step.Label, $call.Error) -Evidence $evidence -Remediation 'Run ./scripts/deploy.ps1 again; it publishes the runbook each time it differs. Meanwhile the VMs'' nightly auto-shutdown and T3''s auto-pause still apply.' -DocUrl $doc)
        }
    }
    $evidence['published'] = 'now'
    return (New-DemoResult -CheckId 'SAFETYSTOP.RUNBOOK' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('{0} is published in {1} (Windows PowerShell 5.1) with the current code and settings.' -f $Name.Runbook, $Name.AutomationAccount) -Evidence $evidence -DocUrl $doc)
}

function Set-DemoSafetyStopSchedule {
    <#
    .SYNOPSIS
    The nightly safety stop's two daily schedules in its account (ADR 0024): dbhub-safety-stop at autoShutdownTime, linked
    to DbHub-Stop with Scope Nightly, and dbhub-safety-t3check CheckOffsetMinutes later (Get-DemoSafetyStopTime), linked
    with Scope T3Check, in autoShutdownTimeZone. A schedule that's enabled, at its time, and linked once with its scope is
    kept; any other is deleted with its links and created again, so a deploy.ps1 run turns a disabled one on again. Each
    new link has a new ID (Azure Automation refused the ID of a link deleted moments earlier, Phase 25d). Returns
    SAFETYSTOP.SCHEDULE. Internal.

    .DESCRIPTION
    Each link's scope is read from the link itself (Get-DemoSafetyStopLink), because the list of job schedules doesn't
    return parameters. Before 2026-11-09 it was read from the list, so no link ever matched, and every run deleted and
    created both schedules and both links again (the activity log of 2026-11-06, live). Keeping a schedule also keeps
    that evening's run: a schedule created again starts at its next time at least 10 minutes ahead
    (Get-DemoSafetyStopTime; Azure Automation wants at least 5), so one created again within 10 minutes of its time
    first runs the next day.
    - Schedule: https://learn.microsoft.com/rest/api/automation/schedule/create-or-update
    - Job schedule: https://learn.microsoft.com/rest/api/automation/job-schedule/create
    - Time zones (an IANA or a Windows ID), and a start at least five minutes ahead: https://learn.microsoft.com/powershell/module/az.automation/new-azautomationschedule
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $version = $script:SafetyStopAutomationApiVersion
    $when = Get-DemoSafetyStopTime -Config $Config -NowUtc $NowUtc
    $evidence = [ordered]@{ automationAccount = $Name.AutomationAccount; stopSchedule = $Name.StopSchedule; checkSchedule = $Name.CheckSchedule; stopLocalTime = $when.StopLocalTime; checkLocalTime = $when.CheckLocalTime; timeZone = $when.TimeZone; checkOffsetMinutes = $when.CheckOffsetMinutes; t3AutoPauseMinutes = $when.AutoPauseMinutes }
    $warn = {
        param([string] $Message)
        New-DemoResult -CheckId 'SAFETYSTOP.SCHEDULE' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message $Message -Evidence $evidence -Remediation 'Run ./scripts/deploy.ps1 again; it schedules the safety stop each time. Meanwhile the VMs'' nightly auto-shutdown and T3''s auto-pause still apply.' -DocUrl $script:SafetyStopDoc
    }
    $links = Get-DemoSafetyStopLink -Name $Name -Schedule @($Name.StopSchedule, $Name.CheckSchedule)
    if (-not $links.Ok) {
        return (& $warn ('The nightly safety stop''s job schedules couldn''t be read: {0}' -f $links.Error))
    }
    $plan = @(
        [pscustomobject]@{ Schedule = $Name.StopSchedule; Scope = 'Nightly'; LocalTime = $when.StopLocalTime; StartTime = $when.StopStartTime; Description = 'Nightly safety stop: DbHub-Stop -Scope Nightly deallocates the demo''s VMs and stops T4 at the VMs'' auto-shutdown time (ADR 0024).' }
        [pscustomobject]@{ Schedule = $Name.CheckSchedule; Scope = 'T3Check'; LocalTime = $when.CheckLocalTime; StartTime = $when.CheckStartTime; Description = 'Nightly safety stop''s T3 check: DbHub-Stop -Scope T3Check reads whether T3 paused, through Azure Resource Manager only, and stops T4 when it runs (ADR 0024).' }
    )
    $kept = [System.Collections.Generic.List[string]]::new()
    $made = [System.Collections.Generic.List[string]]::new()
    $whatIf = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $plan) {
        $scheduleId = '{0}/schedules/{1}' -f $Name.AutomationAccountId, $item.Schedule
        $existing = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $scheduleId -ApiVersion $version)
        if (-not $existing.Ok -and -not $existing.Missing) {
            return (& $warn ('The schedule {0} couldn''t be read: {1}' -f $item.Schedule, $existing.Error))
        }
        $mine = @($links.Links | Where-Object { $_.Schedule -eq $item.Schedule })
        $linked = @($mine | Where-Object { $_.Runbook -eq $Name.Runbook -and $_.Scope -eq $item.Scope })
        $enabled = $existing.Ok -and [bool](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $existing.Value -Name 'properties') -Name 'isEnabled')
        $current = if ($existing.Ok) { Get-DemoSafetyStopScheduleLocalTime -Schedule $existing.Value -TimeZone $when.TimeZone } else { '' }
        if ($enabled -and $current -eq $item.LocalTime -and $linked.Count -eq 1 -and $mine.Count -eq 1) {
            $kept.Add(('{0} at {1}' -f $item.Schedule, $item.LocalTime))
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($item.Schedule, ('Schedule {0} -Scope {1} daily at {2} ({3})' -f $Name.Runbook, $item.Scope, $item.LocalTime, $when.TimeZone))) {
            $whatIf.Add(('{0} at {1}' -f $item.Schedule, $item.LocalTime))
            continue
        }
        foreach ($link in $mine) {
            if ($link.Id -match '^[0-9a-fA-F-]{36}$') {
                $null = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules/{1}' -f $Name.AutomationAccountId, $link.Id) -ApiVersion $version)
            }
        }
        if ($existing.Ok) {
            $null = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id $scheduleId -ApiVersion $version)
        }
        $schedule = [ordered]@{ name = $item.Schedule; properties = [ordered]@{ description = $item.Description; startTime = $item.StartTime; frequency = 'Day'; interval = 1; timeZone = $when.TimeZone } }
        $created = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method put -Url (Get-DemoActivityControlUrl -Id $scheduleId -ApiVersion $version) -Body $schedule
        if (-not $created.Ok) {
            return (& $warn ('The schedule {0} couldn''t be created: {1}' -f $item.Schedule, $created.Error))
        }
        $link = [ordered]@{ properties = [ordered]@{ schedule = @{ name = $item.Schedule }; runbook = @{ name = $Name.Runbook }; parameters = @{ Scope = $item.Scope } } }
        $linkedNow = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method put -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules/{1}' -f $Name.AutomationAccountId, [guid]::NewGuid().ToString()) -ApiVersion $version) -Body $link
        if (-not $linkedNow.Ok) {
            return (& $warn ('The schedule {0} exists, but it couldn''t be linked to {1}: {2}' -f $item.Schedule, $Name.Runbook, $linkedNow.Error))
        }
        $made.Add(('{0} at {1}, first {2}' -f $item.Schedule, $item.LocalTime, $item.StartTime))
    }
    $evidence['kept'] = $kept.ToArray()
    $evidence['created'] = $made.ToArray()
    if ($whatIf.Count -gt 0) {
        return (New-DemoResult -CheckId 'SAFETYSTOP.SCHEDULE' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} would be scheduled ({1}).' -f ($whatIf -join ' and '), $when.TimeZone) -Evidence $evidence -DocUrl $script:SafetyStopDoc)
    }
    return (New-DemoResult -CheckId 'SAFETYSTOP.SCHEDULE' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('The nightly safety stop runs {0} -Scope Nightly daily at {1} and its T3 check, which also stops a running T4, at {2} ({3}); it never starts anything.' -f $Name.Runbook, $when.StopLocalTime, $when.CheckLocalTime, $when.TimeZone) -Evidence $evidence -DocUrl $script:SafetyStopDoc)
}

function Grant-DemoSafetyStopRole {
    <#
    .SYNOPSIS
    The safety stop identity's one role (ADR 0024): creates or updates the custom role "DbHub Demo Safety Stop" when it's
    missing or differs and the caller may (Microsoft.Authorization/roleDefinitions/write: an Owner or a User Access
    Administrator), and assigns it at the demo resource group when the caller may (roleAssignments/write there: also a
    Role Based Access Control Administrator). Returns SAFETYSTOP.ROLE. Internal.

    .DESCRIPTION
    deploy.ps1 calls it on every run (the owner's decision of 2026-11-05, an exception to ADR 0008's no role assignments
    by default), and scripts/grant-safety-stop.ps1 for an Owner. An assignment that can't be made is a Warning, never a
    Fail, with the exact command for an Owner: the deployment is done without it, and the VMs' nightly auto-shutdown and
    T3's auto-pause still apply. The principal type is set, so a new identity doesn't need to have replicated first.
    https://learn.microsoft.com/rest/api/authorization/role-definitions/create-or-update
    https://learn.microsoft.com/rest/api/authorization/role-assignments/create
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [AllowEmptyString()]
        [string] $PrincipalId = '',

        [string] $ConfigPath = ''
    )

    $command = Get-DemoSafetyStopCommand -ConfigPath $ConfigPath
    $label = '"{0}" for {1} at {2}' -f $script:SafetyStopRoleName, $Name.Identity, $Name.ResourceGroup
    $evidence = [ordered]@{ role = $script:SafetyStopRoleName; principal = $Name.Identity; principalId = $PrincipalId; scope = $Name.ResourceGroup; actions = @($script:SafetyStopRoleActions); command = $command }
    $until = 'Until then the nightly safety stop can''t stop anything, so T4 isn''t stopped after Azure starts it again; the VMs'' nightly auto-shutdown and T3''s auto-pause still apply.'
    $warn = {
        param([string] $Message, [string] $Remediation = '')
        $fix = if ($Remediation) { $Remediation } else { 'An Owner of the subscription runs, once: {0}' -f $command }
        New-DemoResult -CheckId 'SAFETYSTOP.ROLE' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('{0} {1}' -f $Message, $until) -Evidence $evidence -Remediation $fix -DocUrl $script:SafetyStopRoleDoc
    }
    if (-not $PrincipalId) {
        return (& $warn ('The role {0} wasn''t assigned: the identity {1} doesn''t exist yet.' -f $label, $Name.Identity) 'Run ./scripts/deploy.ps1, which creates the identity and assigns the role when you may.')
    }
    $permissionsVersion = Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Authorization/roleAssignments'
    $subscriptionPermissions = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/permissions?api-version={1}' -f $Name.SubscriptionId, $permissionsVersion)
    $groupPermissions = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url ('https://management.azure.com{0}/providers/Microsoft.Authorization/permissions?api-version={1}' -f $Name.ResourceGroupId, $permissionsVersion)
    $canDefine = $subscriptionPermissions.Ok -and (Test-DemoPermission -Permission @(Get-DemoActivityControlList -InputObject $subscriptionPermissions.Value -Name 'value') -Action 'Microsoft.Authorization/roleDefinitions/write')
    $canAssign = $groupPermissions.Ok -and (Test-DemoPermission -Permission @(Get-DemoActivityControlList -InputObject $groupPermissions.Value -Name 'value') -Action 'Microsoft.Authorization/roleAssignments/write')
    $evidence['callerCanDefineRoles'] = [bool]$canDefine
    $evidence['callerCanAssignRoles'] = [bool]$canAssign
    $role = Get-DemoSafetyStopRoleState -SubscriptionId $Name.SubscriptionId
    if ($role.Error) {
        return (& $warn ('The role {0} wasn''t checked: {1}.' -f $label, $role.Error))
    }
    $roleId = $role.Id
    $differs = $roleId -and (@(Compare-Object -ReferenceObject @($script:SafetyStopRoleActions) -DifferenceObject @($role.Actions)).Count -gt 0)
    if (-not $roleId -or $differs) {
        if (-not $canDefine) {
            if (-not $roleId) {
                return (& $warn ('The role {0} wasn''t assigned: the custom role doesn''t exist yet in this subscription, and creating it needs Microsoft.Authorization/roleDefinitions/write (an Owner or a User Access Administrator), which you don''t have.' -f $label))
            }
            $evidence['roleDiffers'] = $true
        }
        elseif (-not $PSCmdlet.ShouldProcess(('/subscriptions/{0}' -f $Name.SubscriptionId), ('{0} the custom role "{1}" with exactly its {2} approved actions' -f $(if ($roleId) { 'Update' } else { 'Create' }), $script:SafetyStopRoleName, $script:SafetyStopRoleActions.Count))) {
            return (New-DemoResult -CheckId 'SAFETYSTOP.ROLE' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('What if: the custom role "{0}" would be {1} with exactly these actions: {2}, and assigned to {3} at {4}.' -f $script:SafetyStopRoleName, $(if ($roleId) { 'updated' } else { 'created' }), ($script:SafetyStopRoleActions -join ', '), $Name.Identity, $Name.ResourceGroup) -Evidence $evidence -DocUrl $script:SafetyStopRoleDoc)
        }
        else {
            $definitionId = if ($roleId) { $roleId } else { ConvertTo-DemoStableGuid -Key ('{0}|{1}' -f $Name.SubscriptionId, $script:SafetyStopRoleName) }
            $write = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method put -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}?api-version={2}' -f $Name.SubscriptionId, $definitionId, $permissionsVersion) -Body (Get-DemoSafetyStopRoleDefinition -SubscriptionId $Name.SubscriptionId)
            if (-not $write.Ok) {
                return (& $warn ('The custom role "{0}" couldn''t be written: {1}.' -f $script:SafetyStopRoleName, $write.Error))
            }
            # What changed (2026-11-19): an existing role is updated in place, under its own ID, so its assignments stay; the
            # result says which actions it gained or lost, so an update's status page shows the role ready before a session.
            if ($roleId) {
                $evidence['updated'] = $true
                $evidence['added'] = @($script:SafetyStopRoleActions | Where-Object { $_ -cnotin @($role.Actions) })
                $evidence['removed'] = @(@($role.Actions) | Where-Object { $_ -cnotin $script:SafetyStopRoleActions })
            }
            $roleId = $definitionId
            $evidence['roleWritten'] = $true
        }
    }
    $evidence['roleId'] = $roleId
    $can = 'the nightly safety stop can stop the VMs and T4, read T3, and delete T5''s container between sessions'
    $updatedText = if ([bool]$evidence['updated']) { ' (its definition was updated in place, under the same ID, to exactly the {0} approved actions{1}{2})' -f $script:SafetyStopRoleActions.Count, $(if (@($evidence['added']).Count) { '; added: {0}' -f (@($evidence['added']) -join ', ') } else { '' }), $(if (@($evidence['removed']).Count) { '; removed: {0}' -f (@($evidence['removed']) -join ', ') } else { '' }) } else { '' }
    # A role this run couldn't write that doesn't have exactly its approved actions (review of ab91ee5): another environment's
    # older deploy.ps1 wrote it back for the whole subscription (R910), so the nightly stop can't do what it lacks, such as
    # deleting T5's container. A Warning that names them, never a Pass.
    $stale = {
        param([string] $State)
        $missing = @($script:SafetyStopRoleActions | Where-Object { $_ -cnotin @($role.Actions) })
        $extra = @(@($role.Actions) | Where-Object { $_ -cnotin $script:SafetyStopRoleActions })
        $evidence['missingActions'] = $missing
        $evidence['extraActions'] = $extra
        # Assigned, so the nightly stop runs and does what its actions still allow; DONE says which (the re-review of 0590bbe).
        $evidence['assigned'] = $true
        $gap = @(if ($missing.Count) { 'it doesn''t have {0}' -f ($missing -join ', ') }) + @(if ($extra.Count) { 'it has {0}, which isn''t approved' -f ($extra -join ', ') })
        $message = 'The role {0} is {1}, but the custom role "{2}" doesn''t have exactly its {3} approved actions: {4} (another environment''s deploy.ps1 on older code may have written it back for the whole subscription), and you can''t write it (it takes Microsoft.Authorization/roleDefinitions/write: an Owner or a User Access Administrator). Until then the nightly safety stop can''t do what it lacks{5}.' -f $label, $State, $script:SafetyStopRoleName, $script:SafetyStopRoleActions.Count, ($gap -join '; '), $(if (@($missing | Where-Object { $_ -like 'Microsoft.DocumentDB/*' }).Count) { ', such as deleting T5''s container between sessions' } else { '' })
        New-DemoResult -CheckId 'SAFETYSTOP.ROLE' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message $message -Evidence $evidence -Remediation ('An Owner of the subscription runs, once: {0}, or ./scripts/deploy.ps1, which writes it back to exactly its approved actions.' -f $command) -DocUrl $script:SafetyStopRoleDoc
    }
    $existing = Test-DemoActivityControlAssignment -SubscriptionId $Name.SubscriptionId -Scope $Name.ResourceGroupId -PrincipalId $PrincipalId -RoleId $roleId
    if ($existing.Exists) {
        if ([bool]$evidence['roleDiffers']) {
            return (& $stale 'assigned')
        }
        return (New-DemoResult -CheckId 'SAFETYSTOP.ROLE' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('The role {0} is in place{1}: {2}.' -f $label, $updatedText, $can) -Evidence $evidence -DocUrl $script:SafetyStopRoleDoc)
    }
    if ($existing.Error -and -not $existing.Missing) {
        return (& $warn ('The role {0} wasn''t checked: {1}.' -f $label, $existing.Error))
    }
    if (-not $canAssign) {
        return (& $warn ('The role {0} isn''t assigned: you can''t create role assignments there (it takes an Owner, a User Access Administrator, or a Role Based Access Control Administrator).' -f $label))
    }
    if (-not $PSCmdlet.ShouldProcess($Name.ResourceGroup, ('Assign "{0}" to {1} (object ID {2})' -f $script:SafetyStopRoleName, $Name.Identity, $PrincipalId))) {
        return (New-DemoResult -CheckId 'SAFETYSTOP.ROLE' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} (object ID {1}) would be assigned.' -f $label, $PrincipalId) -Evidence $evidence -DocUrl $script:SafetyStopRoleDoc)
    }
    $assignmentName = ConvertTo-DemoStableGuid -Key ('{0}|{1}|{2}' -f $Name.ResourceGroupId.ToLowerInvariant(), $roleId, $PrincipalId)
    $body = [ordered]@{ properties = [ordered]@{ roleDefinitionId = ('/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $Name.SubscriptionId, $roleId); principalId = $PrincipalId; principalType = 'ServicePrincipal' } }
    $write = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method put -Url ('https://management.azure.com{0}/providers/Microsoft.Authorization/roleAssignments/{1}?api-version={2}' -f $Name.ResourceGroupId, $assignmentName, $permissionsVersion) -Body $body
    if ($write.Ok -or $write.Error -match 'RoleAssignmentExists') {
        $evidence['assigned'] = $true
        if ([bool]$evidence['roleDiffers']) {
            return (& $stale 'assigned now')
        }
        return (New-DemoResult -CheckId 'SAFETYSTOP.ROLE' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('The role {0} is assigned{1}: {2}.' -f $label, $updatedText, $can) -Evidence $evidence -DocUrl $script:SafetyStopRoleDoc)
    }
    return (& $warn ('The role {0} couldn''t be assigned: {1}.' -f $label, $write.Error))
}

function Get-DemoSafetyStopState {
    <#
    .SYNOPSIS
    Whether the nightly safety stop is in place (ADR 0024), read-only. Never throws. Internal.

    .DESCRIPTION
    State is InPlace (dbhub-safety-stop is enabled and linked to DbHub-Stop with Scope Nightly, and the identity holds
    "DbHub Demo Safety Stop" at the demo resource group), NoRole (scheduled, but the role isn't assigned, so it can't stop
    anything), NotScheduled (its account, schedule, or link is missing, or the schedule is disabled), or Unknown (a read
    failed). Also NextRunUtc, CheckNextRunUtc, CheckScheduled (dbhub-safety-t3check is enabled and linked with Scope
    T3Check: the check that reads T3 and, since 2026-11-09, stops a running T4), RoleAssigned ($true, $false, or $null when
    unread), Missing (what isn't in place), and Error. Each link's scope comes from the link itself
    (Get-DemoSafetyStopLink): the list of job schedules returns no parameters, so before 2026-11-09 this said NotScheduled
    for a safety stop that ran every night (live).
    - Schedule: https://learn.microsoft.com/rest/api/automation/schedule/get
    - Job schedules: https://learn.microsoft.com/rest/api/automation/job-schedule/list-by-automation-account and
      https://learn.microsoft.com/rest/api/automation/job-schedule/get
    - Role assignments: https://learn.microsoft.com/rest/api/authorization/role-assignments/list-for-scope
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $answer = [ordered]@{ State = 'Unknown'; NextRunUtc = $null; CheckNextRunUtc = $null; CheckScheduled = $false; RoleAssigned = $null; Missing = ''; Error = '' }
    try {
        $name = Get-DemoSafetyStopName -Config $Config
        $version = $script:SafetyStopAutomationApiVersion
        $read = {
            param([string] $Schedule)
            Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/schedules/{1}' -f $name.AutomationAccountId, $Schedule) -ApiVersion $version)
        }
        $stop = & $read $name.StopSchedule
        $check = & $read $name.CheckSchedule
        $links = Get-DemoSafetyStopLink -Name $name -Schedule @($name.StopSchedule, $name.CheckSchedule)
        if ((-not $stop.Ok -and -not $stop.Missing) -or (-not $links.Ok -and -not $links.Missing)) {
            $answer.Error = if (-not $stop.Ok -and -not $stop.Missing) { $stop.Error } else { $links.Error }
            return [pscustomobject]$answer
        }
        $isLinked = {
            param([string] $Schedule, [string] $Scope)
            @($links.Links | Where-Object { $_.Schedule -eq $Schedule -and $_.Runbook -eq $name.Runbook -and $_.Scope -eq $Scope }).Count -gt 0
        }
        $stopProperties = Get-DemoMemberValue -InputObject $stop.Value -Name 'properties'
        $checkProperties = Get-DemoMemberValue -InputObject $check.Value -Name 'properties'
        $stopScheduled = $stop.Ok -and $links.Ok -and [bool](Get-DemoMemberValue -InputObject $stopProperties -Name 'isEnabled') -and (& $isLinked $name.StopSchedule 'Nightly')
        $answer.CheckScheduled = $check.Ok -and $links.Ok -and [bool](Get-DemoMemberValue -InputObject $checkProperties -Name 'isEnabled') -and (& $isLinked $name.CheckSchedule 'T3Check')
        if ($answer.CheckScheduled) {
            $answer.CheckNextRunUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $checkProperties -Name 'nextRun')
        }
        if (-not $stopScheduled) {
            $answer.State = 'NotScheduled'
            $answer.Missing = if (-not $stop.Ok) { 'the schedule {0} doesn''t exist' -f $name.StopSchedule } elseif (-not [bool](Get-DemoMemberValue -InputObject $stopProperties -Name 'isEnabled')) { 'the schedule {0} is disabled' -f $name.StopSchedule } else { 'the schedule {0} isn''t linked to {1} -Scope Nightly' -f $name.StopSchedule, $name.Runbook }
            return [pscustomobject]$answer
        }
        $answer.NextRunUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $stopProperties -Name 'nextRun')
        $role = Get-DemoSafetyStopRoleState -SubscriptionId $name.SubscriptionId
        if ($role.Error) {
            $answer.Error = $role.Error
            return [pscustomobject]$answer
        }
        $principalId = Get-DemoSafetyStopPrincipalId -Name $name
        if (-not $role.Id -or -not $principalId) {
            $answer.State = 'NoRole'
            $answer.RoleAssigned = $false
            $answer.Missing = if (-not $role.Id) { 'the custom role "{0}" doesn''t exist' -f $script:SafetyStopRoleName } else { 'the identity {0} doesn''t exist' -f $name.Identity }
            return [pscustomobject]$answer
        }
        $assignment = Test-DemoActivityControlAssignment -SubscriptionId $name.SubscriptionId -Scope $name.ResourceGroupId -PrincipalId $principalId -RoleId $role.Id
        if (-not $assignment.Exists -and $assignment.Error) {
            $answer.Error = $assignment.Error
            return [pscustomobject]$answer
        }
        $answer.RoleAssigned = [bool]$assignment.Exists
        if (-not $assignment.Exists) {
            $answer.State = 'NoRole'
            $answer.Missing = '{0} doesn''t hold "{1}" at {2}' -f $name.Identity, $script:SafetyStopRoleName, $name.ResourceGroup
            return [pscustomobject]$answer
        }
        $answer.State = 'InPlace'
        return [pscustomobject]$answer
    }
    catch {
        $answer.State = 'Unknown'
        $answer.Error = Protect-DemoText -Text $_.Exception.Message
        Write-DemoLog -Level Warning -Message ('Whether the nightly safety stop is in place couldn''t be read: {0}' -f $answer.Error)
        return [pscustomobject]$answer
    }
}

function Get-DemoStopResultOutcome {
    <#
    .SYNOPSIS
    What a DbHub-Stop job's result line (DBHUB-STOP) says it did to the VMs and T4, apart from T5's container (the re-review
    of 0590bbe): Status, the result's own status, except Stopped for a result that is Partial only because of T5's container;
    T5Only, true then; and T5Status, what happened to the container (t5Status, or, without it, NotGranted or Failed as the
    text says). Since 2026-11-19 (review of ab91ee5) the runbooks keep T5's outcome apart (t5Status), so a container they
    couldn't delete never makes a stop Partial; a result written before then has no t5Status, and is Partial only because of
    T5 when every entry of its failed list starts with "T5's container" (the nightly safety stop and the auto-stop), or, with
    no failed list (the daily T4 job), when its t5 text says the container wasn't deleted while T4's stop was accepted and
    its replica didn't fail. An environment whose runbooks are older counts T4 as stopped then, so its preflight doesn't stop
    deploy.ps1 before it publishes the runbooks that fix it. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Result
    )

    $status = [string](Get-DemoMemberValue -InputObject $Result -Name 'status')
    $names = if ($null -eq $Result) { @() } elseif ($Result -is [System.Collections.IDictionary]) { @($Result.Keys | ForEach-Object { [string]$_ }) } else { @($Result.PSObject.Properties.Name) }
    $outcome = [pscustomobject]@{ Status = $status; T5Only = $false; T5Status = [string](Get-DemoMemberValue -InputObject $Result -Name 't5Status') }
    if ($status -ne 'Partial' -or $names -contains 't5Status') {
        return $outcome
    }
    $t5Prefix = 'T5''s container'
    $t5Kind = {
        param([string] $Text)
        if ($Text -match 'role can''t delete it') { return 'NotGranted' }
        return 'Failed'
    }
    if ($names -contains 'failed') {
        # Assigned first: Get-DemoMemberValue returns an array as one object.
        $failedValue = Get-DemoMemberValue -InputObject $Result -Name 'failed'
        $failed = @(@($failedValue) | Where-Object { $null -ne $_ -and [string]$_ } | ForEach-Object { [string]$_ })
        if ($failed.Count -gt 0 -and @($failed | Where-Object { -not $_.StartsWith($t5Prefix, [System.StringComparison]::Ordinal) }).Count -eq 0) {
            $outcome.Status = 'Stopped'
            $outcome.T5Only = $true
            $outcome.T5Status = & $t5Kind ($failed -join ' ')
        }
        return $outcome
    }
    # The daily T4 job's result (DbHub-Stop -Scope T4) has no failed list: Partial when T4's stop wasn't accepted, its read
    # replica wasn't stopped, or T5's container wasn't deleted, as its message, replica, and t5 texts say.
    $t5Text = [string](Get-DemoMemberValue -InputObject $Result -Name 't5')
    $message = [string](Get-DemoMemberValue -InputObject $Result -Name 'message')
    $replica = [string](Get-DemoMemberValue -InputObject $Result -Name 'replica')
    if ($t5Text.StartsWith(($t5Prefix + ' not deleted'), [System.StringComparison]::Ordinal) -and $message -notmatch 'its stop was failed' -and $replica -notmatch '\) not stopped: ') {
        $outcome.Status = 'Stopped'
        $outcome.T5Only = $true
        $outcome.T5Status = & $t5Kind $t5Text
    }
    return $outcome
}

function Get-DemoSafetyStopJobResult {
    # The result line DbHub-Stop wrote in a job's output ('DBHUB-STOP <json>'), parsed, or $null (Job - Get Output:
    # https://learn.microsoft.com/rest/api/automation/job/get-output). -JobName is the job's ID (properties.jobId), which
    # Job - Get Output answers for as for the job's name (live, 2026-11-09). Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [string] $JobName
    )

    $output = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/jobs/{1}/output' -f $Name.AutomationAccountId, $JobName) -ApiVersion $script:SafetyStopAutomationApiVersion)
    if (-not $output.Ok -or $null -eq $output.Value) {
        return $null
    }
    $text = if ($output.Value -is [string]) { $output.Value } else { ConvertTo-Json -InputObject $output.Value -Depth 8 -Compress }
    $match = [regex]::Match($text, '(?m)^DBHUB-STOP (\{.*\})\s*$')
    if (-not $match.Success) {
        return $null
    }
    try {
        return ($match.Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 16)
    }
    catch {
        return $null
    }
}

function Get-DemoSafetyStopLastRun {
    <#
    .SYNOPSIS
    The nightly safety stop's newest finished runs (ADR 0024): its account's DbHub-Stop jobs that ended (Job - List By
    Automation Account), newest first, each one's result line read from its output until it has the newest of each
    kind, at most MaxOutputs reads. Returns Ok, Error, Stop, and Check: each $null, or JobId (the ID its output was read
    by), Name (the job's name), Status (the job's), CreatedUtc, and Result (the parsed DBHUB-STOP line, or $null). An
    account that doesn't exist has none. Never throws. Internal.

    .DESCRIPTION
    A job's output is read by its ID, properties.jobId, a GUID. A job that a schedule starts is named
    SCH_<guid>_<guid>_<ticks>, not by its ID, and the ID of a job started by name can differ from its name too (live,
    2026-11-09); before, only a job whose name was a GUID was read, so the scheduled runs never were and the status said
    "It hasn't run yet." The name is used only for a job without an ID, and only when it's a GUID or that schedule form.
    A job that ended without its result line is the stop or the check by its own Scope parameter (Job - Get).
    - Job - List By Automation Account: https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account
    - Job - Get: https://learn.microsoft.com/rest/api/automation/job/get
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [ValidateRange(1, 10)]
        [int] $MaxOutputs = 4
    )

    $guid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $answer = [pscustomobject]@{ Ok = $true; Error = ''; Stop = $null; Check = $null }
    try {
        $jobs = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url ('https://management.azure.com{0}/jobs' -f $Name.AutomationAccountId) -Query ([ordered]@{ '$filter' = ("properties/runbook/name eq '{0}'" -f $Name.Runbook); 'api-version' = $script:SafetyStopAutomationApiVersion })
        if (-not $jobs.Ok) {
            if (-not $jobs.Missing) {
                $answer.Ok = $false
                $answer.Error = $jobs.Error
            }
            return $answer
        }
        $ended = @(foreach ($job in @(Get-DemoActivityControlList -InputObject $jobs.Value -Name 'value')) {
                $properties = Get-DemoMemberValue -InputObject $job -Name 'properties'
                $status = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
                if ($status -notin $script:T4StopJobEndedStatuses) {
                    continue
                }
                $jobId = [string](Get-DemoMemberValue -InputObject $properties -Name 'jobId')
                $jobName = [string](Get-DemoMemberValue -InputObject $job -Name 'name')
                $readAs = if ($jobId -match ('^{0}$' -f $guid)) { $jobId } elseif (-not $jobId -and $jobName -match ('^(?:{0}|SCH_{0}_{0}_[0-9]{{1,20}})$' -f $guid)) { $jobName } else { '' }
                [pscustomobject]@{ JobId = $readAs; Name = $jobName; Status = $status; CreatedUtc = (ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $properties -Name 'creationTime')); Result = $null }
            }) | Sort-Object -Property { if ($null -ne $_.CreatedUtc) { $_.CreatedUtc } else { [datetime]::MinValue } } -Descending
        $reads = 0
        foreach ($job in $ended) {
            if (($null -ne $answer.Stop -and $null -ne $answer.Check) -or $reads -ge $MaxOutputs) {
                break
            }
            if (-not $job.JobId) {
                continue
            }
            $reads++
            $job.Result = Get-DemoSafetyStopJobResult -Name $Name -JobName $job.JobId
            $action = [string](Get-DemoMemberValue -InputObject $job.Result -Name 'action')
            if ($action -eq 'stop-nightly' -and $null -eq $answer.Stop) {
                $answer.Stop = $job
            }
            elseif ($action -eq 'check-t3' -and $null -eq $answer.Check) {
                $answer.Check = $job
            }
            elseif (-not $action -and $job.Status -ne 'Completed') {
                # A job that failed before it wrote its line (the sandbox, the token) is the run that didn't happen. Which
                # one, its own parameters say (Job - Get; the list doesn't return them); one that can't be read counts as
                # the stop, as before.
                $read = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/jobs/{1}' -f $Name.AutomationAccountId, $job.JobId) -ApiVersion $script:SafetyStopAutomationApiVersion)
                $scope = if ($read.Ok) { Get-DemoSafetyStopLinkScope -Link $read.Value } else { '' }
                if ($scope -eq 'T3Check') {
                    if ($null -eq $answer.Check) {
                        $answer.Check = $job
                    }
                }
                elseif ($null -eq $answer.Stop) {
                    $answer.Stop = $job
                }
            }
        }
        return $answer
    }
    catch {
        $answer.Ok = $false
        $answer.Error = Protect-DemoText -Text $_.Exception.Message
        return $answer
    }
}

function Get-DemoSafetyStopStatus {
    <#
    .SYNOPSIS
    The nightly safety stop in one result (ADR 0024), read-only: STATUS.SAFETYSTOP for status.ps1, COST.SAFETYSTOP for
    validate.ps1's Cost area. Pass when it's scheduled, its role is assigned, its last run stopped what ran, and its last
    T3 check found T3 paused (or about to) and stopped T4 if it ran; a Warning that names the fix otherwise. Internal.

    .DESCRIPTION
    Its times (Get-DemoSafetyStopTime), its state (Get-DemoSafetyStopState), and its last stop and T3 check with what they
    did, from the result line of each job (Get-DemoSafetyStopLastRun). A Warning when it isn't set up (deploy.ps1 sets
    it up), when its role isn't assigned (an Owner's command; T4 isn't covered until then), when its last stop didn't
    finish, when T3 was still online past its auto-pause delay or has auto-pause off, when the T3 check couldn't stop a
    running T4 (since 2026-11-09), or when anything couldn't be read.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [datetime] $NowUtc = [DateTime]::UtcNow,

        [ValidateSet('STATUS.SAFETYSTOP', 'COST.SAFETYSTOP')]
        [string] $CheckId = 'STATUS.SAFETYSTOP',

        [string] $Area = 'infra'
    )

    $name = Get-DemoSafetyStopName -Config $Config
    $command = Get-DemoSafetyStopCommand -ConfigPath $ConfigPath
    $when = Get-DemoSafetyStopTime -Config $Config -NowUtc $NowUtc
    $state = Get-DemoSafetyStopState -Config $Config
    $times = 'at {0}, and its T3 check, which also stops a running T4, at {1} ({2})' -f $when.StopLocalTime, $when.CheckLocalTime, $when.TimeZone
    $evidence = [ordered]@{ state = $state.State; automationAccount = $name.AutomationAccount; stopLocalTime = $when.StopLocalTime; checkLocalTime = $when.CheckLocalTime; timeZone = $when.TimeZone; nextRunUtc = $state.NextRunUtc; checkNextRunUtc = $state.CheckNextRunUtc; roleAssigned = $state.RoleAssigned }
    $identity = @{ CheckId = $CheckId; Area = $Area }
    $result = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult @identity -Target 'subscription' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $script:SafetyStopDoc
    }
    switch ($state.State) {
        'NotScheduled' {
            return (& $result 'Warning' ('The nightly safety stop isn''t in place ({0}), so only the VMs'' own auto-shutdown stops them at {1}, and nothing stops T4 when Azure starts it again after 7 days.' -f $state.Missing, $when.StopLocalTime) 'Run ./scripts/deploy.ps1: it sets the nightly safety stop up after the template.')
        }
        'NoRole' {
            return (& $result 'Warning' ('The nightly safety stop runs {0}, but it can''t stop anything: {1}. So T4 isn''t stopped when Azure starts it again after 7 days; the VMs'' nightly auto-shutdown and T3''s auto-pause still apply.' -f $times, $state.Missing) ('An Owner of the subscription runs, once: {0}' -f $command))
        }
        'Unknown' {
            return (& $result 'Warning' ('The nightly safety stop couldn''t be read: {0}.' -f $state.Error) 'Run ./scripts/status.ps1 again; Contributor can read it.')
        }
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    $parts.Add(('The nightly safety stop runs {0}{1}.' -f $times, $(if ($null -ne $state.NextRunUtc) { ' (next {0:yyyy-MM-dd HH:mm} UTC)' -f ([datetime]$state.NextRunUtc) } else { '' })))
    if (-not $state.CheckScheduled) {
        $problems.Add(('its T3 check {0} isn''t scheduled' -f $name.CheckSchedule))
    }
    $runs = Get-DemoSafetyStopLastRun -Name $name
    if (-not $runs.Ok) {
        $problems.Add(('its runs couldn''t be read ({0})' -f $runs.Error))
    }
    else {
        if ($null -eq $runs.Stop) {
            $parts.Add('It hasn''t run yet.')
        }
        else {
            $stopResult = $runs.Stop.Result
            # Partial only because of T5's container, from runbooks older than its t5Status (the re-review of 0590bbe): the
            # VMs and T4 were stopped, and T5's outcome is said below; its job Failed only because Partial fails a Nightly job.
            $stopOutcome = Get-DemoStopResultOutcome -Result $stopResult
            $stopStatus = $stopOutcome.Status
            $stopText = [string](Get-DemoMemberValue -InputObject $stopResult -Name 'message')
            if (-not $stopText) {
                $stopText = 'its output had no result line'
            }
            $evidence['lastStopUtc'] = $runs.Stop.CreatedUtc
            $evidence['lastStopJob'] = $runs.Stop.Status
            $evidence['lastStopJobId'] = $runs.Stop.JobId
            $evidence['lastStop'] = $stopStatus
            $parts.Add(('Last run {0:yyyy-MM-dd HH:mm} UTC (job {1}): {2}' -f ([datetime]$runs.Stop.CreatedUtc), $runs.Stop.Status, $stopText.TrimEnd('.') + '.'))
            # Deferred (2026-11-14): a deploy.ps1 run was still going, so it changed nothing, by design.
            if (($runs.Stop.Status -ne 'Completed' -and -not ($stopOutcome.T5Only -and $runs.Stop.Status -eq 'Failed')) -or $stopStatus -notin 'Stopped', 'Deferred') {
                $problems.Add('its last run didn''t finish its work')
            }
            # T5's container (2026-11-19, ADR 0027) is apart from its status (t5Status, review of ab91ee5), so a container it
            # couldn't delete never makes T4's stop look failed (R910), and it's said here instead.
            $t5Status = $stopOutcome.T5Status
            $evidence['lastStopT5'] = $t5Status
            if ($t5Status -eq 'NotGranted') {
                $problems.Add('its last run couldn''t read or delete T5''s container: its role doesn''t have the container''s actions, so the container, if it''s there, bills until ./scripts/stop-demo.ps1 deletes it')
            }
            elseif ($t5Status -eq 'Failed') {
                $problems.Add('its last run couldn''t delete T5''s container, so it bills until ./scripts/stop-demo.ps1 deletes it')
            }
        }
        if ($null -ne $runs.Check) {
            $checkResult = $runs.Check.Result
            $verdict = [string](Get-DemoMemberValue -InputObject $checkResult -Name 't3')
            $checkText = [string](Get-DemoMemberValue -InputObject $checkResult -Name 'message')
            if (-not $checkText) {
                $checkText = 'its output had no result line'
            }
            $evidence['lastT3CheckUtc'] = $runs.Check.CreatedUtc
            $evidence['lastT3CheckJobId'] = $runs.Check.JobId
            $evidence['lastT3Check'] = $verdict
            $parts.Add(('T3 check {0:yyyy-MM-dd HH:mm} UTC: {1}' -f ([datetime]$runs.Check.CreatedUtc), $checkText.TrimEnd('.') + '.'))
            $t3Problem = switch ($verdict) {
                'Awake' { 'T3 was still online past its auto-pause delay' }
                'AutoPauseOff' { 'T3''s auto-pause is off' }
                { $_ -in 'Paused', 'Pausing', 'Missing', 'TooEarly', 'Deferred' } { '' }
                default { 'its last T3 check didn''t read T3' }
            }
            if ($t3Problem) {
                $problems.Add($t3Problem)
            }
            # Since 2026-11-09 the T3 check also stops a running T4 (its result's failed list names it when it couldn't).
            if (@(Get-DemoActivityControlList -InputObject $checkResult -Name 'failed').Count -gt 0) {
                $problems.Add('its last T3 check couldn''t stop T4')
            }
            elseif (-not $t3Problem -and $runs.Check.Status -ne 'Completed') {
                $problems.Add(('its last T3 check didn''t finish (job {0})' -f $runs.Check.Status))
            }
        }
    }
    $message = $parts -join ' '
    if ($problems.Count -eq 0) {
        return (& $result 'Pass' $message)
    }
    $fix = if (@($problems | Where-Object { $_ -match 'online past' }).Count -gt 0) {
        'Something kept T3 awake: the activity log''s Resume Databases events name what resumed it (https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-monitor). Open the job in {0} (Process Automation > Jobs) for the rest.' -f $name.AutomationAccount
    }
    elseif (@($problems | Where-Object { $_ -match 'container''s actions' }).Count -gt 0) {
        'Run ./scripts/stop-demo.ps1 after each session, which deletes T5''s container with your rights. An Owner of the subscription runs, once: {0}. It gives the role the container''s actions again.' -f $command
    }
    else {
        'Open the job in {0} (Process Automation > Jobs) to see why, then run ./scripts/status.ps1 again; ./scripts/deploy.ps1 sets the safety stop up again.' -f $name.AutomationAccount
    }
    return (& $result 'Warning' ('{0} To check: {1}.' -f $message, ($problems -join '; ')) $fix)
}

function Get-DemoSafetyStopNote {
    <#
    .SYNOPSIS
    DONE's line about the nightly safety stop when this run set it up only in part (ADR 0024): its role missing, or a step
    that warned, with what still applies and the fix. Empty when it's in place, or when this run didn't set it up.
    Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $problems = @(@($Result) | Where-Object { $null -ne $_ -and [string]$_.checkId -like 'SAFETYSTOP.*' -and [string]$_.status -in 'Warning', 'Fail', 'Manual action required' })
    if ($problems.Count -eq 0) {
        return ''
    }
    $role = @($problems | Where-Object { [string]$_.checkId -eq 'SAFETYSTOP.ROLE' }) | Select-Object -Last 1
    if ($problems.Count -eq 1 -and $null -ne $role) {
        $roleEvidence = Get-DemoMemberValue -InputObject $role -Name 'evidence'
        $command = [string](Get-DemoMemberValue -InputObject $roleEvidence -Name 'command')
        if (-not $command) {
            $command = Get-DemoSafetyStopCommand
        }
        # Assigned, but without exactly its approved actions (the re-review of 0590bbe; R910: another environment's older
        # deploy.ps1 wrote the shared role back): the stop runs, and does all but what it lacks.
        if ([bool](Get-DemoMemberValue -InputObject $roleEvidence -Name 'roleDiffers') -and [bool](Get-DemoMemberValue -InputObject $roleEvidence -Name 'assigned')) {
            return (Get-DemoSafetyStopStaleNote -Evidence $roleEvidence -Command $command)
        }
        return ('The nightly safety stop is scheduled, but it can''t stop anything until its role is assigned: an Owner of the subscription runs, once, {0}. Until then T4 isn''t stopped when Azure starts it again after 7 days; the VMs'' nightly auto-shutdown and T3''s auto-pause still apply.' -f $command)
    }
    $first = $problems[0]
    $fix = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $first -Name 'remediation')
    return ('The nightly safety stop isn''t fully set up ({0}): {1} Until it is, T4 isn''t stopped when Azure starts it again after 7 days; the VMs'' nightly auto-shutdown and T3''s auto-pause still apply.{2}' -f [string]$first.checkId, (ConvertTo-DemoPlainText -Value $first.message).TrimEnd(), $(if ($fix) { ' ' + $fix } else { '' }))
}

function Get-DemoSafetyStopStaleNote {
    <#
    .SYNOPSIS
    DONE's line when the nightly safety stop's role is assigned but doesn't have exactly its approved actions (the re-review
    of 0590bbe; R910: another environment's deploy.ps1 on older code wrote the shared custom role back): what the stop still
    does, what it can't, and the fix, from SAFETYSTOP.ROLE's evidence (missingActions, extraActions). Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Evidence,

        [string] $Command = ''
    )

    if (-not $Command) {
        $Command = Get-DemoSafetyStopCommand
    }
    # Assigned first: Get-DemoMemberValue returns an array as one object.
    $missingValue = Get-DemoMemberValue -InputObject $Evidence -Name 'missingActions'
    $missing = @(@($missingValue) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $extraValue = Get-DemoMemberValue -InputObject $Evidence -Name 'extraActions'
    $extra = @(@($extraValue) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    # What each of its approved actions is for, in the order the nightly stop does it.
    $duties = @(
        [pscustomobject]@{ Prefix = 'Microsoft.Compute/'; Does = 'stops the VMs'; Cannot = 'stop the VMs' }
        [pscustomobject]@{ Prefix = 'Microsoft.DBforPostgreSQL/'; Does = 'stops T4'; Cannot = 'stop T4' }
        [pscustomobject]@{ Prefix = 'Microsoft.Sql/'; Does = 'reads T3'; Cannot = 'read T3' }
        [pscustomobject]@{ Prefix = 'Microsoft.DocumentDB/'; Does = 'deletes T5''s container between sessions'; Cannot = 'delete T5''s container between sessions' }
    )
    $blind = @($missing | Where-Object { $_ -like 'Microsoft.Resources/*' }).Count -gt 0
    $lacks = { param([object] $Duty) $blind -or @($missing | Where-Object { $_ -like ($Duty.Prefix + '*') }).Count -gt 0 }
    $does = @($duties | Where-Object { -not (& $lacks $_) } | ForEach-Object { $_.Does })
    $cannot = @($duties | Where-Object { & $lacks $_ } | ForEach-Object { $_.Cannot })
    $list = {
        param([string[]] $Item)
        if ($Item.Count -le 1) { return ($Item -join '') }
        if ($Item.Count -eq 2) { return ('{0} and {1}' -f $Item[0], $Item[1]) }
        return ('{0}, and {1}' -f (@($Item[0..($Item.Count - 2)]) -join ', '), $Item[-1])
    }
    $gap = @(if ($missing.Count) { 'it doesn''t have {0}' -f ($missing -join ', ') }) + @(if ($extra.Count) { 'it has {0}, which isn''t approved' -f ($extra -join ', ') })
    $what = if ($cannot.Count -eq 0) {
        'so it still does all it''s for: it {0}' -f (& $list $does)
    }
    elseif ($does.Count -eq 0) {
        'so it can''t {0}' -f (& $list $cannot)
    }
    else {
        'so it still {0}, but it can''t {1}' -f (& $list $does), (& $list $cannot)
    }
    return ('The nightly safety stop runs, but its role "{0}" doesn''t have exactly its {1} approved actions ({2}; another environment''s deploy.ps1 on older code may have written it back for the whole subscription), {3}. An Owner of the subscription runs, once, {4}, or ./scripts/deploy.ps1, which writes it back to exactly its approved actions.' -f $script:SafetyStopRoleName, $script:SafetyStopRoleActions.Count, ($gap -join '; '), $what, $Command)
}

function New-DemoSafetyStopPlanResult {
    <#
    .SYNOPSIS
    DEPLOY.COST.T4RESTART (2026-11-19, the coordinator's option 2): preflight counted the nightly safety stop that this run
    sets up (PREFLIGHT.COST.MONTHLY's t4RestartPlanned), but its setup didn't put it fully in place (a SAFETYSTOP.* result in
    -SetupResult that isn't a Pass), so T4's 7-day automatic restart counts the rest of the month again. A Warning with the
    worst case without it, the ceiling, and the fix; $null when preflight didn't count it, or the setup put it in place.
    Internal and pure.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowEmptyCollection()]
        [object[]] $SetupResult = @(),

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = ''
    )

    $monthly = @(@($Result) | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'PREFLIGHT.COST.MONTHLY' }) | Select-Object -Last 1
    $evidence = Get-DemoMemberValue -InputObject $monthly -Name 'evidence'
    if (-not [bool](Get-DemoMemberValue -InputObject $evidence -Name 't4RestartPlanned')) {
        return $null
    }
    $problems = @(@($SetupResult) | Where-Object { $null -ne $_ -and [string]$_.checkId -like 'SAFETYSTOP.*' -and [string]$_.status -ne 'Pass' })
    if ($problems.Count -eq 0) {
        return $null
    }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $worst = [double](Get-DemoMemberValue -InputObject $evidence -Name 'monthlyWorstCaseWithoutSafetyStop')
    $ceiling = [double]$Config['monthlyCeilingUsd']
    $over = $worst -gt $ceiling
    $first = $problems[0]
    $message = [string]::Format($culture, 'Preflight counted the nightly safety stop that this run sets up, but it isn''t fully in place ({0}: {1}), so T4''s 7-day automatic restart counts the rest of the month again: the worst case is {2:N2} USD a month, {3} monthlyCeilingUsd ({4:N2} USD).', [string]$first.checkId, (ConvertTo-DemoPlainText -Value $first.message).TrimEnd(), $worst, $(if ($over) { 'over' } else { 'within' }), $ceiling)
    $fix = [string]::Format($culture, 'An Owner of the subscription runs, once: {0}, which puts the nightly safety stop in place, so each restart counts as about a day again{1}', (Get-DemoSafetyStopCommand -ConfigPath $ConfigPath), $(if ($over) { [string]::Format($culture, '; or raise monthlyCeilingUsd to at least {0:N0} in your configuration.', [System.Math]::Ceiling($worst)) } else { '.' }))
    return (New-DemoResult -CheckId 'DEPLOY.COST.T4RESTART' -Area 'infra' -Target 'T4' -Status 'Warning' -Message $message -Evidence ([ordered]@{ worstCaseWithoutSafetyStop = $worst; monthlyCeilingUsd = $ceiling; overCeiling = $over; setupProblem = [string]$first.checkId }) -Remediation $fix -DocUrl $script:SafetyStopRoleDoc)
}

function Get-DemoT4RestartStopState {
    <#
    .SYNOPSIS
    What stops T4 again after Azure starts it on its own (7 days after a stop), for STATUS.T4 and STOP.T4.STOP
    (Format-DemoT4RestartText): Nightly (the nightly safety stop is in place, ADR 0024), Scheduled (otherwise the on-demand
    control's daily T4 safety stop, ADR 0020), NoRole (the nightly safety stop is scheduled but can't act), NotScheduled,
    or Unknown. Also NextRunUtc, and CheckStopsT4: with Nightly, whether its T3 check is scheduled too, which stops a
    running T4 since 2026-11-09. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $nightly = Get-DemoSafetyStopState -Config $Config
    if ($nightly.State -eq 'InPlace') {
        return [pscustomobject]@{ State = 'Nightly'; NextRunUtc = $nightly.NextRunUtc; CheckStopsT4 = [bool](Get-DemoMemberValue -InputObject $nightly -Name 'CheckScheduled') }
    }
    $control = Get-DemoT4SafetyStopState -Config $Config
    if ($control.State -eq 'Scheduled') {
        return [pscustomobject]@{ State = 'Scheduled'; NextRunUtc = $control.NextRunUtc; CheckStopsT4 = $false }
    }
    if ($nightly.State -eq 'NoRole') {
        return [pscustomobject]@{ State = 'NoRole'; NextRunUtc = $nightly.NextRunUtc; CheckStopsT4 = $false }
    }
    if ($nightly.State -eq 'Unknown' -or $control.State -eq 'Unknown') {
        return [pscustomobject]@{ State = 'Unknown'; NextRunUtc = $null; CheckStopsT4 = $false }
    }
    return [pscustomobject]@{ State = 'NotScheduled'; NextRunUtc = $null; CheckStopsT4 = $false }
}
