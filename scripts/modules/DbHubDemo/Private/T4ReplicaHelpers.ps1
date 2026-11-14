# T4's read replica (2026-11-13, user-directed; ADR 0025): a same-region read replica of T4, pgreplica01-<deploymentId>,
# created for each session. deploy.ps1 and start-demo.ps1 create it from infra/replica/pgreplica01.bicep while it doesn't
# exist (a second deployment of that template fails: ReadReplicaAlreadyExistWithGivenName, live 2026-11-13), at T4's
# actual size, or a larger documented General Purpose size when Azure refuses it; stop-demo.ps1 deletes it, so nothing
# bills between sessions. Azure enforces the power order (SourceReplicasStartStopOrder, live 2026-11-13): T4 starts only
# once a stopped replica is Ready, and a replica stops only once T4 is Stopped. Azure Monitor has no metrics for a
# deleted replica (ResourceNotFound, live 2026-11-13), so its history is captured before stop-demo.ps1 deletes it.
# Sources (checked 2026-11-13):
# - Read replicas: https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas
# - Create a read replica: https://learn.microsoft.com/azure/postgresql/read-replica/how-to-create-read-replica
# - Servers - Get, Start, Delete: https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers
# - Capacity errors: https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors

function Get-DemoT4ReplicaSetting {
    # config/versions.json's postgresql.replica block: the replica's name prefix, template deployment, records, the
    # lag scenario's replay delay, bounds, sizes, metrics, and sources. Internal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return (Get-DemoPostgresSetting)['replica']
}

function Add-DemoT4ReplicaLoaderSetting {
    <#
    .SYNOPSIS
    T1's loader settings with T4's read replica (t4.replicaServerName and t4.replicaServerFqdn), when a run reads them from
    the outputs of a template deployment that predates the replica (2026-11-13 live finding): a resumed upgrade skips the
    template, so T1 never got the replica's name, and the replica-lag beat was refused. Computed as infra/modules/demo.bicep
    does: no FQDN for a Burstable T4. Returns the settings, with the names added or as they were. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $LoaderSettings
    )

    $t4 = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $LoaderSettings -Name 'sqlVm') -Name 't4'
    if ($null -eq $t4 -or $null -ne (Get-DemoMemberValue -InputObject $t4 -Name 'replicaServerName')) {
        return $LoaderSettings
    }
    $names = Get-DemoT4ReplicaName -Config $Config
    if (-not $names.ServerName) {
        return $LoaderSettings
    }
    $fqdn = if ((Get-DemoT4SkuName -Config $Config) -like 'Standard_B*') { '' } else { [string]$names.Fqdn }
    if ($t4 -is [System.Collections.IDictionary]) {
        $t4['replicaServerName'] = [string]$names.ServerName
        $t4['replicaServerFqdn'] = $fqdn
    }
    else {
        $t4 | Add-Member -NotePropertyName 'replicaServerName' -NotePropertyValue ([string]$names.ServerName) -Force
        $t4 | Add-Member -NotePropertyName 'replicaServerFqdn' -NotePropertyValue $fqdn -Force
    }
    Write-DemoLog -Message ('The last template deployment predates T4''s read replica, so T1''s settings get its name from this run: {0}.' -f $names.ServerName)
    return $LoaderSettings
}

function Get-DemoT4ReplicaName {
    <#
    .SYNOPSIS
    Returns the replica's names: resource group, the flexible server pgreplica01-<deploymentId>, its resource ID and FQDN,
    and T4's (the source's) name and resource ID. Internal.

    .DESCRIPTION
    The name is stable across sessions, so the runner, Database Hub's Estate, and the safety stop find each session's
    replica under it. The deploymentId comes from -DeploymentId or the resource group's deploymentId tag (Get-DemoT4Name);
    with -NoLookup nothing is read, and ServerName is empty when -DeploymentId wasn't given.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [switch] $NoLookup
    )

    $t4 = Get-DemoT4Name -Config $Config -DeploymentId $DeploymentId -NoLookup:$NoLookup
    $setting = Get-DemoT4ReplicaSetting
    $serverName = if ($t4.DeploymentId) { '{0}-{1}' -f $setting['serverNamePrefix'], $t4.DeploymentId } else { '' }
    [pscustomobject]@{
        ResourceGroup = $t4.ResourceGroup
        DeploymentId  = $t4.DeploymentId
        ServerName    = $serverName
        ServerId      = if ($serverName) { '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{2}' -f $Config['subscriptionId'], $t4.ResourceGroup, $serverName } else { '' }
        Fqdn          = if ($serverName) { '{0}.postgres.database.azure.com' -f $serverName } else { '' }
        SourceName    = $t4.ServerName
        SourceId      = $t4.ServerId
        DatabaseName  = $t4.DatabaseName
        RunnerRole    = $t4.RunnerRole
        TemplateName  = [string]$setting['templateDeploymentName']
    }
}

function Get-DemoT4ReplicaState {
    <#
    .SYNOPSIS
    The replica's state (Ready, Stopped, Starting, Stopping, Updating, Provisioning, ...), or NotFound or Unknown, with its
    size, zone, role, and source when it exists. Internal.

    .DESCRIPTION
    Exists means a replica is there and Azure isn't deleting it; one in Dropping has Removing $true and Present $true, so a
    new one with its name waits until it's gone (Azure keeps a server it refused as such a shell for a few minutes, ADR
    0019's 2026-11-09 finding). A read: it works while the replica is stopped.
    Source: https://learn.microsoft.com/rest/api/postgresql/servers/get
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $DeploymentId = ''
    )

    $names = Get-DemoT4ReplicaName -Config $Config -DeploymentId $DeploymentId
    $empty = [ordered]@{ Names = $names; Exists = $false; Present = $false; Removing = $false; State = 'NotFound'; Server = $null; SkuName = ''; Zone = ''; Role = ''; SourceId = ''; Error = '' }
    if (-not $names.ServerName) {
        $empty['Error'] = 'The resource group has no deploymentId tag.'
        return [pscustomobject]$empty
    }
    $read = Get-DemoT4Resource -Config $Config -ServerId $names.ServerId
    if (-not $read.Found) {
        $empty['State'] = if ($read.NotFound) { 'NotFound' } else { 'Unknown' }
        $empty['Error'] = [string]$read.Error
        return [pscustomobject]$empty
    }
    $properties = Get-DemoMemberValue -InputObject $read.Value -Name 'properties'
    $state = [string](Get-DemoMemberValue -InputObject $properties -Name 'state')
    $removing = $state -eq 'Dropping'
    [pscustomobject]@{
        Names    = $names
        Exists   = (-not $removing)
        Present  = $true
        Removing = $removing
        State    = $(if ($state) { $state } else { 'Unknown' })
        Server   = $read.Value
        SkuName  = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $read.Value -Name 'sku') -Name 'name')
        Zone     = [string](Get-DemoMemberValue -InputObject $properties -Name 'availabilityZone')
        Role     = [string](Get-DemoMemberValue -InputObject $properties -Name 'replicationRole')
        SourceId = [string](Get-DemoMemberValue -InputObject $properties -Name 'sourceServerResourceId')
        Error    = ''
    }
}

function Wait-DemoT4ReplicaState {
    # Polls the replica's state until it's one of -State (NotFound included) or -TimeoutMinutes pass; returns the last read.
    # Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string[]] $State,

        [ValidateRange(0, 60)]
        [int] $TimeoutMinutes = 15,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15,

        [string] $DeploymentId = ''
    )

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ($true) {
        $current = Get-DemoT4ReplicaState -Config $Config -DeploymentId $DeploymentId
        if ($current.State -in $State -or [DateTime]::UtcNow -ge $deadline) {
            return $current
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Test-DemoT4ReplicaSetUp {
    # True once deploy.ps1 has set T4's read replica up for this environment: the resource group's DbHubT4Replica tag is
    # Session (ADR 0025). An environment deployed before the replica has no such tag until its next ./scripts/deploy.ps1.
    # Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $State
    )

    return ([string](Get-DemoMemberValue -InputObject $State -Name 'T4Replica') -ceq [string](Get-DemoT4ReplicaSetting)['recordValue'])
}

function Get-DemoT4ReplicaSupport {
    <#
    .SYNOPSIS
    Whether T4 can have a read replica, from T4's own size (Get-DemoT4State's Server): Supported, Reason (Supported, NoT4,
    or Burstable), SkuName, Tier, VCores, Zone, and the subnet, DNS zone, location, and storage the replica copies. Pure.
    Internal.

    .DESCRIPTION
    "Read replicas are currently supported for the General Purpose and Memory Optimized server compute tiers. The Burstable
    server compute tier isn't supported." (Learn, read replicas, checked 2026-11-13).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $T4State
    )

    $server = Get-DemoMemberValue -InputObject $T4State -Name 'Server'
    $exists = [bool](Get-DemoMemberValue -InputObject $T4State -Name 'Exists')
    $sku = Get-DemoMemberValue -InputObject $server -Name 'sku'
    $properties = Get-DemoMemberValue -InputObject $server -Name 'properties'
    $network = Get-DemoMemberValue -InputObject $properties -Name 'network'
    $storage = Get-DemoMemberValue -InputObject $properties -Name 'storage'
    $skuName = [string](Get-DemoMemberValue -InputObject $sku -Name 'name')
    $tier = [string](Get-DemoMemberValue -InputObject $sku -Name 'tier')
    if (-not $tier -and $skuName) {
        $tier = if ($skuName -match '^Standard_B') { 'Burstable' } else { 'GeneralPurpose' }
    }
    $vcores = 0
    if ($skuName -cmatch '^Standard_[A-Z]+(\d{1,2})[a-z_0-9]*$') {
        $vcores = [int]$Matches[1]
    }
    $reason = if (-not $exists -or -not $skuName) { 'NoT4' } elseif ($tier -eq 'Burstable') { 'Burstable' } else { 'Supported' }
    [pscustomobject]@{
        Supported        = ($reason -eq 'Supported')
        Reason           = $reason
        SkuName          = $skuName
        Tier             = $tier
        VCores           = $vcores
        Zone             = [string](Get-DemoMemberValue -InputObject $properties -Name 'availabilityZone')
        Location         = [string](Get-DemoMemberValue -InputObject $server -Name 'location')
        SubnetId         = [string](Get-DemoMemberValue -InputObject $network -Name 'delegatedSubnetResourceId')
        PrivateDnsZoneId = [string](Get-DemoMemberValue -InputObject $network -Name 'privateDnsZoneArmResourceId')
        StorageSizeGB    = [int](Get-DemoMemberValue -InputObject $storage -Name 'storageSizeGB')
        StorageTier      = [string](Get-DemoMemberValue -InputObject $storage -Name 'tier')
    }
}

function Get-DemoT4ReplicaSizeOrder {
    <#
    .SYNOPSIS
    The sizes and zones the replica's creation tries, in order, never with fewer vCores than T4 (ADR 0025). Pure. Internal.

    .DESCRIPTION
    1. -Record (DbHubT4ReplicaSize, "<size>@<zone or any>"), the size the last replica used, first when it's a documented
       General Purpose size with T4's vCores, so a size Azure refused isn't asked for at every session again. A record
       with more vCores than T4 (a larger fallback, which costs more) comes only after T4's own size, so each session
       asks for T4's size first; one with fewer vCores is ignored.
    2. T4's size with no zone preference, then once in -Zone (another zone the region lists for it, which
       Get-DemoT4SkuZone reads), the way T4's own fallback retries (ADR 0019).
    3. The documented General Purpose sizes (postgresql.replica.generalPurposeSizes) with the same vCores, then larger
       ones: Learn requires "the same or a higher number of vCores as the source server".
    Returns objects with SkuName and Zone ('' for no preference).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $T4SkuName,

        [AllowEmptyString()]
        [string] $Record = '',

        [AllowEmptyCollection()]
        [string[]] $Zone = @()
    )

    $vcoresOf = {
        param([string] $Name)
        if ($Name -cmatch '^Standard_[A-Z]+(\d{1,2})[a-z_0-9]*$') { [int]$Matches[1] } else { 0 }
    }
    $t4VCores = & $vcoresOf $T4SkuName
    $documented = @((Get-DemoT4ReplicaSetting)['generalPurposeSizes'])
    $order = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $add = {
        param([string] $Sku, [string] $AtZone)
        if (-not $Sku -or $Sku -notmatch '^Standard_') {
            return
        }
        if ($seen.Add(('{0}@{1}' -f $Sku, $(if ($AtZone) { $AtZone } else { 'any' })))) {
            $order.Add([pscustomobject]@{ SkuName = $Sku; Zone = $AtZone })
        }
    }
    $later = $null
    if ($Record -match '^(Standard_[A-Za-z0-9_]+)@(any|[123])$') {
        $recordSku = $Matches[1]
        $recordZone = if ($Matches[2] -eq 'any') { '' } else { $Matches[2] }
        $recordVCores = & $vcoresOf $recordSku
        if ($recordSku -cin $documented -and $recordVCores -eq $t4VCores) {
            & $add $recordSku $recordZone
        }
        elseif ($recordSku -cin $documented -and $recordVCores -gt $t4VCores) {
            $later = [pscustomobject]@{ SkuName = $recordSku; Zone = $recordZone }
        }
    }
    & $add $T4SkuName ''
    foreach ($zoneName in @($Zone | Where-Object { $_ -in '1', '2', '3' } | Select-Object -First 1)) {
        & $add $T4SkuName $zoneName
    }
    if ($null -ne $later) {
        & $add $later.SkuName $later.Zone
    }
    $peers = @($documented | Where-Object { $_ -cne $T4SkuName -and (& $vcoresOf $_) -eq $t4VCores })
    $larger = @($documented | Where-Object { (& $vcoresOf $_) -gt $t4VCores } | Sort-Object -Property @{ Expression = { & $vcoresOf $_ } }, @{ Expression = { $documented.IndexOf($_) } })
    foreach ($sku in @($peers) + @($larger)) {
        & $add $sku ''
    }
    return $order.ToArray()
}

function Format-DemoT4ReplicaAttemptText {
    # One attempt as people read it: "Standard_D4ds_v5 (no zone preference)" or "Standard_D4ds_v5 in zone 2". Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Attempt
    )

    $zone = [string](Get-DemoMemberValue -InputObject $Attempt -Name 'Zone')
    if ($zone) {
        return ('{0} in zone {1}' -f [string](Get-DemoMemberValue -InputObject $Attempt -Name 'SkuName'), $zone)
    }
    return ('{0} (no zone preference)' -f [string](Get-DemoMemberValue -InputObject $Attempt -Name 'SkuName'))
}

function New-DemoT4ReplicaNotSetUpResult {
    # The record for a script that meets an environment deploy.ps1 hasn't set T4's read replica up in yet (deployed before
    # the replica, ADR 0025): it changes nothing and points to ./scripts/deploy.ps1. Pure. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $CheckId,

        [ValidateSet('Not selected', 'Warning')]
        [string] $Status = 'Not selected'
    )

    $setting = Get-DemoT4ReplicaSetting
    return (New-DemoResult -CheckId $CheckId -Area 'infra' -Target 'T4' -Status $Status -Message ('T4''s read replica isn''t deployed yet: this environment was deployed before the replica existed, so nothing was done for it. Database Hub''s Read replica lag stays empty until then.') -Remediation ('Run ./scripts/deploy.ps1: it adds the replica (about {0} minutes) and changes nothing else; after that, start-demo.ps1 creates it for each session and stop-demo.ps1 deletes it.' -f $setting['createMinutes']) -DocUrl ([string]$setting['docUrls']['concepts']))
}

function New-DemoT4ReplicaNotSupportedResult {
    # The record for a Burstable T4, which Azure doesn't support read replicas on (ADR 0025): Not supported, with the fix.
    # Pure. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $CheckId,

        [AllowEmptyString()]
        [string] $T4SkuName = ''
    )

    $setting = Get-DemoT4ReplicaSetting
    return (New-DemoResult -CheckId $CheckId -Area 'infra' -Target 'T4' -Status 'Not supported' -Message ('T4 runs on the Burstable size {0}, and Azure supports read replicas only on the General Purpose and Memory Optimized tiers, so T4 has no read replica and Database Hub''s Read replica lag stays empty.' -f $(if ($T4SkuName) { $T4SkuName } else { 'it has' })) -Evidence ([ordered]@{ t4SkuName = $T4SkuName; tier = 'Burstable' }) -Remediation 'To have the replica, remove t4SkuName from config/demo.config.json (the default is General Purpose Standard_D4ds_v5) or set it to Standard_D2ds_v5, then run ./scripts/deploy.ps1, which moves T4 to that size and adds the replica. A General Purpose T4 costs more: ./scripts/estimate-cost.ps1 shows by how much.' -DocUrl ([string]$setting['docUrls']['concepts']))
}

function Get-DemoT4ReplicaLagBlock {
    <#
    .SYNOPSIS
    Why the replica-lag scenario can't run now, as -CheckId's record, or $null when it can: T4 Ready, set up for its read
    replica, not Burstable, and the replica there and Ready. Read from this PC before demo-control.ps1 sends the scenario.
    Internal.

    .DESCRIPTION
    Live, 2026-11-13 (rg-dbhubha-demo): the safety stop's 19:30 pass had stopped T4 and its replica, and demo-control.ps1
    still said Pass for replica-lag, because it only stores the profile; T1's profile host then couldn't run it, and only
    its log on sqlvm01 said so. Each reason here is a Warning with the fix (start-demo.ps1 starts T4 and creates or starts
    the replica; deploy.ps1 sets the replica up), or Not supported on a Burstable T4. Whether T1's runner settings name the
    replica is checked on sqlvm01, in the same Run Command (Invoke-DemoWorkloadControl.ps1): only that VM has them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^[A-Z0-9]+(\.[A-Z0-9_]+)+$')]
        [string] $CheckId = 'CONTROL.T4'
    )

    $setting = Get-DemoT4ReplicaSetting
    $docUrl = [string]$setting['docUrls']['concepts']
    $notSent = 'so replica-lag wasn''t sent: it needs T4 and its read replica running, and T1''s profile host would refuse it'
    $again = 'then send replica-lag again'
    $warn = {
        param([string] $Message, [string] $Remediation, [System.Collections.IDictionary] $Evidence)
        New-DemoResult -CheckId $CheckId -Area 'workload' -Target 'T4' -Status 'Warning' -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl
    }
    $state = Get-DemoDeploymentState -Config $Config
    $deploymentId = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $state -Name 'Tags') -Name 'deploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        $deploymentId = ''
    }
    $t4 = Get-DemoT4State -Config $Config -DeploymentId $deploymentId
    $t4Name = [string]$t4.Names.ServerName
    $evidence = [ordered]@{ scenario = 'incident:replica-lag'; t4 = $t4Name; t4State = [string]$t4.State }
    if ([string]$t4.State -ne 'Ready') {
        switch -Regex ([string]$t4.State) {
            '^NotFound$' {
                return (& $warn ('T4 ({0}) isn''t there, {1}.' -f $(if ($t4Name) { $t4Name } else { 'pgflex01-<deploymentId>' }), $notSent) 'Run ./scripts/deploy.ps1: it creates T4 and its read replica.' $evidence)
            }
            '^(Stopped|Stopping|Disabled)$' {
                return (& $warn ('T4 ({0}) is {1}, {2}.' -f $t4Name, $t4.State, $notSent) ('Run ./scripts/start-demo.ps1: it starts T4 and creates or starts its read replica (about {0} minutes); {1}.' -f $setting['createMinutes'], $again) $evidence)
            }
            '^Unknown$' {
                $evidence['error'] = Protect-DemoText -Text ([string]$t4.Error)
                return (& $warn ('T4''s state couldn''t be read, {0}: {1}' -f $notSent, $evidence['error']) ('Run it again in a few minutes; ./scripts/status.ps1 shows T4.') $evidence)
            }
            default {
                return (& $warn ('T4 ({0}) is {1}, not Ready, {2}.' -f $t4Name, $t4.State, $notSent) ('Wait until T4 is Ready (./scripts/status.ps1 shows it, usually within minutes); {0}.' -f $again) $evidence)
            }
        }
    }
    $support = Get-DemoT4ReplicaSupport -T4State $t4
    if ($support.Reason -eq 'Burstable') {
        $burstable = New-DemoT4ReplicaNotSupportedResult -CheckId $CheckId -T4SkuName $support.SkuName
        $burstable.message = 'replica-lag wasn''t sent: ' + [string]$burstable.message
        return $burstable
    }
    if (-not (Test-DemoT4ReplicaSetUp -State $state)) {
        $notSetUp = New-DemoT4ReplicaNotSetUpResult -CheckId $CheckId -Status 'Warning'
        $notSetUp.message = 'replica-lag wasn''t sent: ' + [string]$notSetUp.message
        return $notSetUp
    }
    $replica = Get-DemoT4ReplicaState -Config $Config -DeploymentId $deploymentId
    $replicaName = [string]$replica.Names.ServerName
    $evidence['replica'] = $replicaName
    $evidence['replicaState'] = [string]$replica.State
    if ([string]$replica.State -eq 'Ready') {
        return $null
    }
    switch -Regex ([string]$replica.State) {
        '^NotFound$' {
            return (& $warn ('T4''s read replica ({0}) isn''t there, {1}. stop-demo.ps1 deletes it after each session.' -f $replicaName, $notSent) ('Run ./scripts/start-demo.ps1: it creates the replica (about {0} minutes); {1}.' -f $setting['createMinutes'], $again) $evidence)
        }
        '^(Stopped|Stopping|Disabled)$' {
            return (& $warn ('T4''s read replica ({0}) is {1}, {2}.' -f $replicaName, $replica.State, $notSent) ('Run ./scripts/start-demo.ps1: it starts the replica; {0}.' -f $again) $evidence)
        }
        '^Dropping$' {
            return (& $warn ('T4''s read replica ({0}) is being deleted, {1}.' -f $replicaName, $notSent) ('Run ./scripts/start-demo.ps1 once it''s gone (about 2 minutes): it creates the replica again; {0}.' -f $again) $evidence)
        }
        '^Unknown$' {
            $evidence['error'] = Protect-DemoText -Text ([string]$replica.Error)
            return (& $warn ('T4''s read replica ({0}) couldn''t be read, {1}: {2}' -f $replicaName, $notSent, $evidence['error']) 'Run it again in a few minutes; ./scripts/status.ps1 shows the replica.' $evidence)
        }
        default {
            return (& $warn ('T4''s read replica ({0}) is {1}, not Ready, {2}.' -f $replicaName, $replica.State, $notSent) ('Wait until it''s Ready (./scripts/status.ps1 shows it; creating it takes about {0} minutes); {1}.' -f $setting['createMinutes'], $again) $evidence)
        }
    }
}

function New-DemoT4ReplicaPreflightResult {
    # PREFLIGHT.T4.REPLICA (ADR 0025): what deploy.ps1 does about T4's read replica on the size T4 gets (-SkuName): Not
    # supported with the fix on a Burstable size, otherwise a Pass that says when it's created and deleted. Pure. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $SkuName = ''
    )

    if ($SkuName -and (Get-DemoT4SkuSpec -SkuName $SkuName).Tier -eq 'Burstable') {
        return (New-DemoT4ReplicaNotSupportedResult -CheckId 'PREFLIGHT.T4.REPLICA' -T4SkuName $SkuName)
    }
    $setting = Get-DemoT4ReplicaSetting
    $size = if ($SkuName) { $SkuName } else { 'T4''s size' }
    return (New-DemoResult -CheckId 'PREFLIGHT.T4.REPLICA' -Area 'preflight' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica is created at T4''s size ({0}) by deploy.ps1 for the first session and by start-demo.ps1 for each later one (about {1} minutes), and stop-demo.ps1 deletes it, so it bills only during sessions (PREFLIGHT.COST.* count it in a session''s cost). If Azure refuses that size, a larger one with at least T4''s vCores is tried, with a Warning that names it and its price.' -f $size, $setting['createMinutes']) -Evidence ([ordered]@{ skuName = $SkuName; serverNamePrefix = $setting['serverNamePrefix'] }) -DocUrl ([string]$setting['docUrls']['concepts']))
}

function Get-DemoT4ReplicaCreateFailure {
    <#
    .SYNOPSIS
    The replica's last failed creation: the resource group deployment dbhub-t4-replica, when it failed. Returns Code
    (SkuNotAvailable, AlreadyExists, SourceNotReady, or Other), Text, Sku, Zone, and TimeUtc, or $null. A read. Internal.

    .DESCRIPTION
    The deployment's own error stops at ResourceDeploymentFailure, so the server operation's status message is read too
    (Deployment Operations - List), as Get-DemoT4CreateFailure does for T4 (ADR 0019).
    Sources: https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-show,
    https://learn.microsoft.com/cli/azure/deployment/operation/group#az-deployment-operation-group-list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $resourceGroup = Get-DemoResourceGroupName -Config $Config
    $name = [string](Get-DemoT4ReplicaSetting)['templateDeploymentName']
    $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'group', 'show', '--resource-group', $resourceGroup, '--name', $name, '--output', 'json') -AllowFailure
    if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
        return $null
    }
    $deployment = [string]$read.StdOut | ConvertFrom-Json -Depth 64
    $properties = Get-DemoMemberValue -InputObject $deployment -Name 'properties'
    if ([string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState') -ne 'Failed') {
        return $null
    }
    $errorText = ConvertTo-Json -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'error') -Depth 64 -Compress
    $operations = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'operation', 'group', 'list', '--resource-group', $resourceGroup, '--name', $name, '--output', 'json') -AllowFailure
    if ($operations.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$operations.StdOut)) {
        foreach ($operation in @([string]$operations.StdOut | ConvertFrom-Json -Depth 64)) {
            $operationProperties = Get-DemoMemberValue -InputObject $operation -Name 'properties'
            if ([string](Get-DemoMemberValue -InputObject $operationProperties -Name 'provisioningState') -eq 'Failed') {
                $errorText += ConvertTo-Json -InputObject (Get-DemoMemberValue -InputObject $operationProperties -Name 'statusMessage') -Depth 64 -Compress
            }
        }
    }
    $code = if ($errorText -match 'SkuNotAvailable') { 'SkuNotAvailable' } elseif ($errorText -match 'ReadReplicaAlreadyExistWithGivenName') { 'AlreadyExists' } elseif ($errorText -match 'ReadReplicaServerInUnexpectedState') { 'SourceNotReady' } else { 'Other' }
    $parameters = Get-DemoMemberValue -InputObject $properties -Name 'parameters'
    $stamp = Get-DemoMemberValue -InputObject $properties -Name 'timestamp'
    $timeUtc = if ($stamp -is [datetime]) { $stamp.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$stamp }
    [pscustomobject]@{
        Code    = $code
        Text    = Get-DemoDeploymentErrorText -Text $errorText -MaxLength 600
        Sku     = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $parameters -Name 'skuName') -Name 'value')
        Zone    = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $parameters -Name 'availabilityZone') -Name 'value')
        TimeUtc = $timeUtc
    }
}

function Send-DemoT4ReplicaTemplate {
    <#
    .SYNOPSIS
    Deploys infra/replica/pgreplica01.bicep for one size and zone (resource group deployment dbhub-t4-replica), with the
    demo's own tags and component t4-replica, T4's location, subnet, private DNS zone, and storage, and the lag
    scenario's replay delay. With -NoWait it returns once Azure accepted the deployment. Returns ExitCode and Error.
    The parameters go in a file in a private directory. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Callers confirm once for the whole deployment or start.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Names,

        [Parameter(Mandatory)]
        [pscustomobject] $Support,

        [Parameter(Mandatory)]
        [string] $SkuName,

        [ValidateSet('', '1', '2', '3')]
        [string] $Zone = '',

        [switch] $NoWait
    )

    $setting = Get-DemoT4ReplicaSetting
    $tags = [ordered]@{}
    try {
        $groupTags = Get-DemoResourceGroupTag -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName $Names.ResourceGroup
        foreach ($key in $script:SafetyStopTagNames) {
            if ($groupTags.Contains($key) -and [string]$groupTags[$key]) {
                $tags[$key] = [string]$groupTags[$key]
            }
        }
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The demo resource group''s tags weren''t read for T4''s read replica: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    $tags['component'] = 't4-replica'
    $parameters = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{
            location                   = @{ value = $(if ($Support.Location) { $Support.Location } else { [string]$Config['location'] }) }
            tags                       = @{ value = $tags }
            serverName                 = @{ value = $Names.ServerName }
            sourceServerId             = @{ value = $Names.SourceId }
            skuName                    = @{ value = $SkuName }
            availabilityZone           = @{ value = $Zone }
            storageSizeGB              = @{ value = $(if ($Support.StorageSizeGB -gt 0) { $Support.StorageSizeGB } else { 32 }) }
            storageTier                = @{ value = $(if ($Support.StorageTier) { $Support.StorageTier } else { 'P4' }) }
            delegatedSubnetId          = @{ value = $Support.SubnetId }
            privateDnsZoneId           = @{ value = $Support.PrivateDnsZoneId }
            maxStandbyStreamingDelayMs = @{ value = [int]$setting['maxStandbyStreamingDelayMs'] }
        }
    }
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-t4replica'
    try {
        $path = Write-DemoPrivateFile -Directory $directory -Name 'pgreplica01.parameters.json' -Content (ConvertTo-Json -InputObject $parameters -Depth 8)
        $template = Join-Path -Path $script:RepoRoot -ChildPath 'infra/replica/pgreplica01.bicep'
        $arguments = @('deployment', 'group', 'create', '--resource-group', $Names.ResourceGroup, '--name', $Names.TemplateName, '--template-file', $template, '--parameters', "@$path", '--query', 'properties.provisioningState', '--output', 'json') + @(if ($NoWait) { '--no-wait' })
        $run = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList $arguments -AllowFailure -TimeoutSeconds $(if ($NoWait) { 300 } else { [int]$setting['createTimeoutMinutes'] * 60 })
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false -WhatIf:$false | Out-Null
    }
    return [pscustomobject]@{ ExitCode = $run.ExitCode; Error = $(if ($run.ExitCode -ne 0) { Get-DemoDeploymentErrorText -Text ([string]$run.StdErr) -MaxLength 600 } else { '' }) }
}

function Wait-DemoT4ReplicaTemplate {
    # Reads the dbhub-t4-replica deployment's provisioningState every -PollSeconds until it's Succeeded, Failed, or Canceled,
    # or -TimeoutMinutes pass; returns the last state ('' when it couldn't be read). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(1, 120)]
        [int] $TimeoutMinutes = 40,

        [ValidateRange(5, 120)]
        [int] $PollSeconds = 20
    )

    $name = [string](Get-DemoT4ReplicaSetting)['templateDeploymentName']
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $state = ''
    while ($true) {
        $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'group', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', $name, '--query', 'properties.provisioningState', '--output', 'tsv') -AllowFailure
        if ($read.ExitCode -eq 0) {
            $state = ([string]$read.StdOut).Trim()
        }
        if ($state -in 'Succeeded', 'Failed', 'Canceled' -or [DateTime]::UtcNow -ge $deadline) {
            return $state
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-DemoT4ReplicaPriceText {
    <#
    The replica's compute at -SkuName against -AskedSku (T4's size), per hour and for a session of -SessionHours, from the
    Azure Retail Prices API (Get-DemoT4HourlyPrice; ADR 0016: no prices in the code), or a sentence that says the price
    couldn't be read. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $SkuName,

        [Parameter(Mandatory)]
        [string] $AskedSku,

        [double] $SessionHours = 5
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $price = Get-DemoT4HourlyPrice -Config $Config -SkuName $SkuName
    $asked = if ($SkuName -ceq $AskedSku) { $price } else { Get-DemoT4HourlyPrice -Config $Config -SkuName $AskedSku }
    if ($null -eq $price) {
        return ('Its price couldn''t be read from the Azure Retail Prices API; ./scripts/estimate-cost.ps1 shows it.')
    }
    if ($SkuName -ceq $AskedSku -or $null -eq $asked) {
        return [string]::Format($culture, 'It costs about {0:N3} USD an hour of compute while it exists (an estimate from the Azure Retail Prices API).', $price)
    }
    $difference = $price - $asked
    return [string]::Format($culture, 'It costs about {0:N3} USD an hour of compute while it exists, against {1:N3} USD at {2}: {3}{4:N3} USD an hour, about {3}{5:N2} USD for a {6:N0}-hour session (estimates from the Azure Retail Prices API).', $price, $asked, $AskedSku, $(if ($difference -ge 0) { '+' } else { '' }), $difference, $difference * $SessionHours, $SessionHours)
}

function Start-DemoT4ReplicaCreate {
    <#
    .SYNOPSIS
    Begins making sure T4's read replica exists for a session (ADR 0025), and returns a context for
    Complete-DemoT4ReplicaCreate: Done (nothing to wait for), Results so far, and what's being created. Internal.

    .DESCRIPTION
    - start-demo.ps1 (-CheckPrefix START) in an environment deploy.ps1 hasn't set the replica up in: Not selected, with the
      upgrade's command (New-DemoT4ReplicaNotSetUpResult). deploy.ps1 (DEPLOY) sets it up.
    - T4 missing: Not selected. A Burstable T4: Not supported, with the fix.
    - A replica that's there: Ready is a Pass; Stopped (a session that ended without stop-demo.ps1, which the safety stop
      stopped) is started; starting or updating is waited for (Complete-DemoT4ReplicaCreate).
    - One that Azure is deleting (Dropping) is waited for, at most 15 minutes, before a new one.
    - T4 must be Ready (Azure refuses a replica of a stopped server: ReadReplicaServerInUnexpectedState, live 2026-11-13),
      and its max_connections must be in effect: a replica inherits the value, and a hot standby needs at least the
      primary's. With -WaitForRestartMinutes it waits for T1's T4 step to restart T4 (deploy.ps1's parallel tracks), then
      restarts it itself (Invoke-DemoT4PendingRestart).
    - Then the first size of Get-DemoT4ReplicaSizeOrder goes out (Send-DemoT4ReplicaTemplate -NoWait).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('DEPLOY', 'START')]
        [string] $CheckPrefix = 'START',

        [ValidateRange(0, 120)]
        [int] $WaitForRestartMinutes = 0,

        [string] $DeploymentId = ''
    )

    $checkId = '{0}.T4.REPLICA' -f $CheckPrefix
    $setting = Get-DemoT4ReplicaSetting
    $docUrl = [string]$setting['docUrls']['create']
    $context = [ordered]@{ Done = $true; Results = [System.Collections.Generic.List[object]]::new(); CheckPrefix = $CheckPrefix; Names = $null; Support = $null; Order = @(); Index = -1; Refused = [System.Collections.Generic.List[object]]::new(); StartUtc = [DateTime]::UtcNow; Waiting = ''; DeploymentId = $DeploymentId }
    $finish = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '')
        $context.Results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl))
        return [pscustomobject]$context
    }
    $state = Get-DemoDeploymentState -Config $Config
    if ($CheckPrefix -eq 'START' -and -not (Test-DemoT4ReplicaSetUp -State $state)) {
        $context.Results.Add((New-DemoT4ReplicaNotSetUpResult -CheckId $checkId))
        return [pscustomobject]$context
    }
    $names = Get-DemoT4ReplicaName -Config $Config -DeploymentId $DeploymentId
    $context.Names = $names
    if (-not $names.ServerName) {
        return (& $finish 'Not selected' 'T4''s read replica wasn''t created: the resource group has no deploymentId tag, so T4 isn''t deployed.' @{} 'Run ./scripts/deploy.ps1.')
    }
    $t4 = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
    $support = Get-DemoT4ReplicaSupport -T4State $t4
    $context.Support = $support
    if ($support.Reason -eq 'NoT4') {
        return (& $finish 'Not selected' ('T4 ({0}) isn''t deployed, so it has no read replica.' -f $names.SourceName) ([ordered]@{ t4State = $t4.State }) 'Run ./scripts/deploy.ps1: it creates T4, then its replica.')
    }
    if (-not $support.Supported) {
        $context.Results.Add((New-DemoT4ReplicaNotSupportedResult -CheckId $checkId -T4SkuName $support.SkuName))
        return [pscustomobject]$context
    }
    $replica = Get-DemoT4ReplicaState -Config $Config -DeploymentId $DeploymentId
    $evidence = [ordered]@{ replica = $names.ServerName; source = $names.SourceName; t4SkuName = $support.SkuName; stateBefore = $replica.State }
    if ($replica.Exists -and $replica.State -eq 'Ready') {
        return (& $finish 'Pass' ('T4''s read replica ({0}, {1}) is already running (Ready).' -f $names.ServerName, $replica.SkuName) $evidence)
    }
    if (-not $PSCmdlet.ShouldProcess($names.ServerName, 'Create or start T4''s read replica')) {
        return (& $finish 'Not selected' ('What if: T4''s read replica ({0}) would be created at {1}, or started.' -f $names.ServerName, $support.SkuName) $evidence)
    }
    if ($replica.Exists -and $replica.State -in 'Stopped', 'Stopping') {
        # A replica a session left (the safety stop stopped it after T4): start it, and Complete-DemoT4ReplicaCreate waits.
        if ($replica.State -eq 'Stopping') {
            $replica = Wait-DemoT4ReplicaState -Config $Config -State @('Stopped') -TimeoutMinutes ([int]$setting['powerWaitMinutes']) -DeploymentId $DeploymentId
        }
        $url = 'https://management.azure.com{0}/start?api-version={1}' -f $names.ServerId, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers')
        $post = Invoke-DemoAzWithConflictRetry -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'post', '--url', $url) -Label ('T4 replica {0}: start' -f $names.ServerName) -MaxConflictRetries 4
        if ($post.ExitCode -ne 0) {
            $evidence['error'] = Protect-DemoText -Text ([string]$post.StdErr).Trim()
            return (& $finish 'Warning' ('T4''s read replica ({0}) is stopped and couldn''t be started: {1}' -f $names.ServerName, $evidence['error']) $evidence 'Run ./scripts/stop-demo.ps1, which deletes it, then ./scripts/start-demo.ps1, which creates a new one.')
        }
        $context.Done = $false
        $context.Waiting = 'Start'
        return [pscustomobject]$context
    }
    if ($replica.Exists) {
        # Starting, Updating, Provisioning (a creation another run began), and the like: wait for Ready.
        $context.Done = $false
        $context.Waiting = 'Existing'
        return [pscustomobject]$context
    }
    if ($replica.Removing) {
        Write-DemoLog -Message ('T4''s read replica ({0}) is being deleted (Dropping); waiting until it''s gone before creating a new one, at most {1} minutes.' -f $names.ServerName, $setting['deleteTimeoutMinutes'])
        $replica = Wait-DemoT4ReplicaState -Config $Config -State @('NotFound') -TimeoutMinutes ([int]$setting['deleteTimeoutMinutes']) -DeploymentId $DeploymentId
        if ($replica.Present) {
            return (& $finish 'Warning' ('T4''s read replica ({0}) is still being deleted after {1} minutes, so a new one wasn''t created.' -f $names.ServerName, $setting['deleteTimeoutMinutes']) $evidence 'Run the script again in a few minutes: Azure finishes deleting it on its own.')
        }
    }
    elseif ($replica.State -ne 'NotFound') {
        $evidence['error'] = $replica.Error
        return (& $finish 'Warning' ('T4''s read replica ({0}) couldn''t be read, so it wasn''t created: {1}' -f $names.ServerName, $replica.Error) $evidence 'Run the script again; ./scripts/status.ps1 shows the replica.')
    }
    if ($t4.State -ne 'Ready') {
        return (& $finish 'Warning' ('T4 ({0}) is {1}, not Ready, so its read replica wasn''t created: Azure creates a replica only from a running server.' -f $names.SourceName, $t4.State) $evidence 'Run ./scripts/start-demo.ps1 once T4 is running; it creates the replica.')
    }
    # A replica inherits max_connections, and a hot standby needs at least the primary's value in effect, so a pending
    # restart (the template set 50 on a new server) comes first (ADR 0019, 2026-11-03).
    $connections = Get-DemoT4ParameterState -Config $Config -ServerId $names.SourceId -Name 'max_connections'
    if ($connections.Found -and $connections.PendingRestart -and $WaitForRestartMinutes -gt 0) {
        Write-DemoLog -Message ('T4''s max_connections {0} waits for the restart that T1''s T4 step does; T4''s read replica is created after it (at most {1} minutes).' -f $connections.Value, $WaitForRestartMinutes)
        $deadline = [DateTime]::UtcNow.AddMinutes($WaitForRestartMinutes)
        while ($connections.Found -and $connections.PendingRestart -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 30
            $connections = Get-DemoT4ParameterState -Config $Config -ServerId $names.SourceId -Name 'max_connections'
        }
    }
    if ($connections.Found -and $connections.PendingRestart) {
        $restart = Invoke-DemoT4PendingRestart -Config $Config -DeploymentId $DeploymentId
        if ($null -ne $restart) {
            $context.Results.Add($restart)
        }
        $t4 = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
        if ($t4.State -ne 'Ready') {
            return (& $finish 'Warning' ('T4 ({0}) is {1} after its restart, so its read replica wasn''t created.' -f $names.SourceName, $t4.State) $evidence 'Run ./scripts/start-demo.ps1 once T4 is Ready; it creates the replica.')
        }
    }
    # The restart's pending flag clears while T4 is still restarting (live, 2026-11-13: the replica went out then, and Azure
    # refused it with ReadReplicaServerInUnexpectedState, "in 'Restarting' state"), so T4 must read Ready again first.
    $t4 = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
    if ($t4.State -ne 'Ready') {
        Write-DemoLog -Message ('T4 ({0}) is {1}; T4''s read replica is created once it''s Ready again (at most {2} minutes).' -f $names.SourceName, $t4.State, $setting['powerWaitMinutes'])
        $t4 = Wait-DemoT4State -Config $Config -State @('Ready') -TimeoutMinutes ([int]$setting['powerWaitMinutes']) -DeploymentId $DeploymentId
        if ($t4.State -ne 'Ready') {
            return (& $finish 'Warning' ('T4 ({0}) is {1}, not Ready, after {2} minutes, so its read replica wasn''t created: Azure creates a replica only from a running server.' -f $names.SourceName, $t4.State, $setting['powerWaitMinutes']) $evidence 'Run ./scripts/start-demo.ps1 once T4 is Ready; it creates the replica.')
        }
    }
    $zones = @(Get-DemoT4SkuZone -Config $Config -SkuName $support.SkuName | Where-Object { $_ -ne $support.Zone })
    $context.Order = @(Get-DemoT4ReplicaSizeOrder -T4SkuName $support.SkuName -Record ([string]$state.T4ReplicaSize) -Zone $zones)
    $context.Index = 0
    $first = $context.Order[0]
    Write-DemoLog -Message ('Creating T4''s read replica ({0}) as {1}; it takes about {2} minutes.' -f $names.ServerName, (Format-DemoT4ReplicaAttemptText -Attempt $first), $setting['createMinutes'])
    $sent = Send-DemoT4ReplicaTemplate -Config $Config -Names $names -Support $support -SkuName $first.SkuName -Zone $first.Zone -NoWait
    if ($sent.ExitCode -ne 0) {
        $evidence['error'] = $sent.Error
        return (& $finish $(if ($CheckPrefix -eq 'DEPLOY') { 'Fail' } else { 'Warning' }) ('T4''s read replica ({0}) couldn''t be created: {1}' -f $names.ServerName, $sent.Error) $evidence 'Fix the cause (a policy denial names its policy), then run the script again.')
    }
    $context.Done = $false
    $context.Waiting = 'Create'
    return [pscustomobject]$context
}

function Complete-DemoT4ReplicaCreate {
    <#
    .SYNOPSIS
    Finishes what Start-DemoT4ReplicaCreate began: waits for the replica's creation or start, moves the size fallback on
    when Azure refuses a size (SkuNotAvailable), records the size used (DbHubT4ReplicaSize), and returns the results:
    <prefix>.T4.REPLICA, and <prefix>.T4.REPLICA.FALLBACK when another size or zone was used. Internal.

    .DESCRIPTION
    Only SkuNotAvailable for the size the attempt sent moves the fallback on (ADR 0019's rule, ADR 0025's order); a refused
    attempt's shell (Dropping) is waited for before the next one. Any other failure ends it: a Fail for deploy.ps1 and a
    Warning for start-demo.ps1, which goes on without the replica. When Azure refuses every size, deploy.ps1 ends NOT DONE
    with the fix (a Region access request); nothing is recorded, so the next run tries again.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [scriptblock] $RecordState = $null
    )

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Context.Results)) {
        $results.Add($item)
    }
    if ($Context.Done) {
        return $results.ToArray()
    }
    $setting = Get-DemoT4ReplicaSetting
    $docUrl = [string]$setting['docUrls']['create']
    $checkId = '{0}.T4.REPLICA' -f $Context.CheckPrefix
    $names = $Context.Names
    $support = $Context.Support
    $failStatus = if ($Context.CheckPrefix -eq 'DEPLOY') { 'Fail' } else { 'Warning' }
    $evidence = [ordered]@{ replica = $names.ServerName; source = $names.SourceName; t4SkuName = $support.SkuName }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Context.Waiting -in 'Start', 'Existing') {
        $replica = Wait-DemoT4ReplicaState -Config $Config -State @('Ready', 'Stopped', 'NotFound', 'Dropping', 'Disabled') -TimeoutMinutes ([int]$setting['createTimeoutMinutes']) -DeploymentId ([string]$Context.DeploymentId)
        $evidence['stateAfter'] = $replica.State
        $evidence['seconds'] = [int]$clock.Elapsed.TotalSeconds
        if ($replica.State -eq 'Ready') {
            $how = if ($Context.Waiting -eq 'Start') { 'was stopped, and is now running again' } else { 'is now running' }
            $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}, {1}) {2} (Ready, {3} s).' -f $names.ServerName, $replica.SkuName, $how, $evidence['seconds']) -Evidence $evidence -DocUrl $docUrl))
        }
        else {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $failStatus -Message ('T4''s read replica ({0}) is {1}, not Ready, after {2} minutes.' -f $names.ServerName, $replica.State, [int]$clock.Elapsed.TotalMinutes) -Evidence $evidence -Remediation 'Check it with ./scripts/status.ps1; ./scripts/stop-demo.ps1 deletes it, and the next ./scripts/start-demo.ps1 creates a new one.' -DocUrl $docUrl))
        }
        return $results.ToArray()
    }

    $index = [int]$Context.Index
    $order = @($Context.Order)
    $refused = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Context.Refused)) {
        $refused.Add($item)
    }
    $notReadyRetries = 0
    while ($true) {
        $attempt = $order[$index]
        $outcome = Wait-DemoT4ReplicaTemplate -Config $Config -TimeoutMinutes ([int]$setting['createTimeoutMinutes'])
        if ($outcome -eq 'Succeeded') {
            break
        }
        if ($outcome -notin 'Failed', 'Canceled') {
            $evidence['attempt'] = Format-DemoT4ReplicaAttemptText -Attempt $attempt
            $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) is still being created after {1} minutes ({2}); Azure goes on with it.' -f $names.ServerName, $setting['createTimeoutMinutes'], $evidence['attempt']) -Evidence $evidence -Remediation 'Check it with ./scripts/status.ps1 in a few minutes.' -DocUrl $docUrl))
            return $results.ToArray()
        }
        $failure = Get-DemoT4ReplicaCreateFailure -Config $Config
        if ($null -ne $failure -and $failure.Code -eq 'SourceNotReady' -and $notReadyRetries -lt 3) {
            # Azure refused the replica because T4 was busy (ReadReplicaServerInUnexpectedState, live 2026-11-13: T4 was
            # restarting for max_connections): the same size goes out again once T4 reads Ready and has settled a minute.
            $notReadyRetries++
            Write-DemoLog -Level Warning -Message ('Azure refused T4''s read replica because T4 wasn''t ready ({0}); trying {1} again once T4 is Ready (retry {2} of 3).' -f $failure.Text, (Format-DemoT4ReplicaAttemptText -Attempt $attempt), $notReadyRetries)
            $null = Wait-DemoT4State -Config $Config -State @('Ready') -TimeoutMinutes ([int]$setting['powerWaitMinutes']) -DeploymentId ([string]$Context.DeploymentId)
            $shell = Get-DemoT4ReplicaState -Config $Config -DeploymentId ([string]$Context.DeploymentId)
            if ($shell.Present) {
                $null = Wait-DemoT4ReplicaState -Config $Config -State @('NotFound') -TimeoutMinutes ([int]$setting['deleteTimeoutMinutes']) -DeploymentId ([string]$Context.DeploymentId)
            }
            Start-Sleep -Seconds 60
            $sent = Send-DemoT4ReplicaTemplate -Config $Config -Names $names -Support $support -SkuName $attempt.SkuName -Zone $attempt.Zone -NoWait
            if ($sent.ExitCode -ne 0) {
                $evidence['error'] = $sent.Error
                $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $failStatus -Message ('T4''s read replica ({0}) couldn''t be created as {1}: {2}' -f $names.ServerName, (Format-DemoT4ReplicaAttemptText -Attempt $attempt), $sent.Error) -Evidence $evidence -Remediation 'Fix the cause, then run the script again.' -DocUrl $docUrl))
                return $results.ToArray()
            }
            continue
        }
        $refusedSize = $null -ne $failure -and $failure.Code -eq 'SkuNotAvailable' -and ($failure.Sku -ceq $attempt.SkuName -or -not $failure.Sku)
        if (-not $refusedSize) {
            $why = if ($null -ne $failure) { $failure.Text } else { 'the deployment failed, and its error couldn''t be read' }
            $evidence['attempt'] = Format-DemoT4ReplicaAttemptText -Attempt $attempt
            $evidence['error'] = $why
            $fix = if ($null -ne $failure -and $failure.Code -eq 'SourceNotReady') { 'T4 stayed busy (restarting, updating, or starting) through 3 tries. Run the script again once ./scripts/status.ps1 shows T4 Ready: the replica is created when it''s missing.' } else { 'Fix the cause (a quota, or a policy denial, names itself), then run the script again; the replica is created when it''s missing.' }
            $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $failStatus -Message ('T4''s read replica ({0}) couldn''t be created as {1}: {2}' -f $names.ServerName, $evidence['attempt'], $why) -Evidence $evidence -Remediation $fix -DocUrl $docUrl))
            return $results.ToArray()
        }
        $refused.Add([pscustomobject]@{ SkuName = $attempt.SkuName; Zone = $attempt.Zone; TimeUtc = $failure.TimeUtc })
        Write-DemoLog -Level Warning -Message ('Azure refused {0} for T4''s read replica (SkuNotAvailable).' -f (Format-DemoT4ReplicaAttemptText -Attempt $attempt))
        $index++
        if ($index -ge $order.Count) {
            $tried = @($refused | ForEach-Object { Format-DemoT4ReplicaAttemptText -Attempt $_ }) -join ', '
            $evidence['refused'] = $tried
            $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $failStatus -Message ('T4''s read replica ({0}) wasn''t created: Azure refused every size it can have (SkuNotAvailable): {1}. Database Hub''s Read replica lag stays empty.' -f $names.ServerName, $tried) -Evidence $evidence -Remediation ('Ask for access with a Region access request for Azure Database for PostgreSQL flexible server in {0} (Learn: Resolve capacity errors), then run ./scripts/{1}; nothing is recorded, so it tries every size again.' -f [string]$Config['location'], $(if ($Context.CheckPrefix -eq 'DEPLOY') { 'deploy.ps1' } else { 'start-demo.ps1' })) -DocUrl ([string]$setting['docUrls']['capacityErrors'])))
            return $results.ToArray()
        }
        # Azure keeps a refused server as a shell for a few minutes (Dropping; ADR 0019, 2026-11-09): the next attempt,
        # which uses the same name, waits until it's gone.
        $shell = Get-DemoT4ReplicaState -Config $Config -DeploymentId ([string]$Context.DeploymentId)
        if ($shell.Present) {
            Write-DemoLog -Message ('Waiting for the refused replica''s shell ({0}, {1}) to go before the next size, at most {2} minutes.' -f $names.ServerName, $shell.State, $setting['deleteTimeoutMinutes'])
            $shell = Wait-DemoT4ReplicaState -Config $Config -State @('NotFound') -TimeoutMinutes ([int]$setting['deleteTimeoutMinutes']) -DeploymentId ([string]$Context.DeploymentId)
            if ($shell.Present) {
                $evidence['refused'] = @($refused | ForEach-Object { Format-DemoT4ReplicaAttemptText -Attempt $_ }) -join ', '
                $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $failStatus -Message ('Azure refused {0} for T4''s read replica, and its shell ({1}) was still there after {2} minutes, so the next size wasn''t tried.' -f $evidence['refused'], $shell.State, $setting['deleteTimeoutMinutes']) -Evidence $evidence -Remediation 'Run the script again in a few minutes: Azure removes the shell on its own.' -DocUrl ([string]$setting['docUrls']['capacityErrors'])))
                return $results.ToArray()
            }
        }
        $attempt = $order[$index]
        Write-DemoLog -Message ('Trying T4''s read replica as {0}.' -f (Format-DemoT4ReplicaAttemptText -Attempt $attempt))
        $sent = Send-DemoT4ReplicaTemplate -Config $Config -Names $names -Support $support -SkuName $attempt.SkuName -Zone $attempt.Zone -NoWait
        if ($sent.ExitCode -ne 0) {
            $evidence['error'] = $sent.Error
            $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $failStatus -Message ('T4''s read replica ({0}) couldn''t be created as {1}: {2}' -f $names.ServerName, (Format-DemoT4ReplicaAttemptText -Attempt $attempt), $sent.Error) -Evidence $evidence -Remediation 'Fix the cause, then run the script again.' -DocUrl $docUrl))
            return $results.ToArray()
        }
    }

    $replica = Get-DemoT4ReplicaState -Config $Config -DeploymentId ([string]$Context.DeploymentId)
    $created = $order[$index]
    $evidence['skuName'] = $replica.SkuName
    $evidence['zone'] = $replica.Zone
    $evidence['seconds'] = [int]([DateTime]::UtcNow - [datetime]$Context.StartUtc).TotalSeconds
    $record = '{0}@{1}' -f $created.SkuName, $(if ($created.Zone) { $created.Zone } else { 'any' })
    try {
        $values = @{ T4ReplicaSize = $record }
        if ($Context.CheckPrefix -eq 'DEPLOY') {
            $values['T4Replica'] = [string]$setting['recordValue']
        }
        if ($null -ne $RecordState) {
            & $RecordState $values
        }
        else {
            Set-DemoDeploymentState -Config $Config -Value $values -Confirm:$false
        }
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The replica''s size wasn''t recorded on the resource group: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    $where = if ($replica.Zone) { ' in zone {0}' -f $replica.Zone } else { '' }
    $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}) was created as {1}{2} in {3} s: a same-region read replica of {4}, in its subnet and private DNS zone, Microsoft Entra only. Database Hub''s Estate lists it, and its PostgreSQL dashboard charts its Read replica lag.' -f $names.ServerName, $replica.SkuName, $where, $evidence['seconds'], $names.SourceName) -Evidence $evidence -DocUrl $docUrl))
    if ($created.SkuName -cne $support.SkuName -or $refused.Count -gt 0) {
        $tried = @($refused | ForEach-Object { Format-DemoT4ReplicaAttemptText -Attempt $_ }) -join ', '
        $sessionHours = [double](Get-DemoProfile).assumptions.demoHoursPerSession
        $price = Get-DemoT4ReplicaPriceText -Config $Config -SkuName $created.SkuName -AskedSku $support.SkuName -SessionHours $sessionHours
        $notice = 'T4''s read replica was created as {0}, where T4''s size {1} was asked for, because Azure refused {2} (SkuNotAvailable). {3}' -f (Format-DemoT4ReplicaAttemptText -Attempt $created), $support.SkuName, $(if ($tried) { $tried } else { 'the first choice' }), $price
        $createdVCores = if ($created.SkuName -cmatch '^Standard_[A-Z]+(\d{1,2})[a-z_0-9]*$') { [int]$Matches[1] } else { 0 }
        $next = if ($createdVCores -gt $support.VCores) { 'Nothing to do: each session asks for T4''s size first again, and uses this larger size (recorded as DbHubT4ReplicaSize) only when Azure refuses it.' } else { 'Nothing to do: the next replica starts at this size (recorded as DbHubT4ReplicaSize), which has T4''s vCores, so Azure isn''t asked for the refused one at every session.' }
        $results.Add((New-DemoResult -CheckId ('{0}.T4.REPLICA.FALLBACK' -f $Context.CheckPrefix) -Area 'infra' -Target 'T4' -Status 'Warning' -Message $notice -Evidence ([ordered]@{ asked = $support.SkuName; created = $created.SkuName; zone = $created.Zone; refused = $tried; record = $record }) -Remediation $next -DocUrl ([string]$setting['docUrls']['capacityErrors'])))
    }
    return $results.ToArray()
}

function Invoke-DemoT4ReplicaCreate {
    # Start-DemoT4ReplicaCreate, then Complete-DemoT4ReplicaCreate: the whole creation in one call (deploy.ps1's T4 step).
    # Internal.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('DEPLOY', 'START')]
        [string] $CheckPrefix = 'DEPLOY',

        [ValidateRange(0, 120)]
        [int] $WaitForRestartMinutes = 0,

        [scriptblock] $RecordState = $null,

        [string] $DeploymentId = ''
    )

    $context = Start-DemoT4ReplicaCreate -Config $Config -CheckPrefix $CheckPrefix -WaitForRestartMinutes $WaitForRestartMinutes -DeploymentId $DeploymentId -WhatIf:$WhatIfPreference
    return @(Complete-DemoT4ReplicaCreate -Config $Config -Context $context -RecordState $RecordState)
}

function Remove-DemoT4Replica {
    <#
    .SYNOPSIS
    Deletes T4's read replica (Servers - Delete) and, unless -NoWait, waits until it's gone. Returns <prefix>.T4.REPLICA,
    or nothing with -Quiet when there's no replica. Internal.

    .DESCRIPTION
    stop-demo.ps1 deletes it after each session (ADR 0025), so nothing bills between sessions and no 7-day restart
    applies to it; deleting it leaves T4 Ready (live 2026-11-13: about 100 seconds), so T4's own stop follows.
    destroy.ps1 deletes it before the resource group ("delete the read replicas first before deleting the primary
    server"), and deploy.ps1 before T4 grows past it. A stopped replica is deleted too. Its Azure Monitor metrics go with
    it (ResourceNotFound, live 2026-11-13), so stop-demo.ps1 -SaveHistory captures them first.
    Source: https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/delete
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('STOP', 'DESTROY', 'DEPLOY')]
        [string] $CheckPrefix = 'STOP',

        [ValidatePattern('^$|^[A-Z0-9]+(\.[A-Z0-9_]+)+$')]
        [string] $CheckId = '',

        [switch] $NoWait,

        [switch] $Quiet,

        [string] $DeploymentId = ''
    )

    if (-not $CheckId) {
        $CheckId = '{0}.T4.REPLICA' -f $CheckPrefix
    }
    $checkId = $CheckId
    $setting = Get-DemoT4ReplicaSetting
    $docUrl = [string]$setting['docUrls']['concepts']
    $names = Get-DemoT4ReplicaName -Config $Config -DeploymentId $DeploymentId
    if (-not $names.ServerName) {
        if ($Quiet) {
            return
        }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Not selected' -Message 'T4''s read replica isn''t known (the resource group has no deploymentId tag), so nothing was deleted.')
    }
    $replica = Get-DemoT4ReplicaState -Config $Config -DeploymentId $DeploymentId
    $evidence = [ordered]@{ replica = $names.ServerName; stateBefore = $replica.State }
    if (-not $replica.Present) {
        if ($replica.State -ne 'NotFound') {
            if ($Quiet) {
                return
            }
            return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) couldn''t be read, so it wasn''t deleted: {1}' -f $names.ServerName, $replica.Error) -Evidence $evidence -Remediation 'Run the script again; ./scripts/status.ps1 shows the replica.' -DocUrl $docUrl)
        }
        if ($Quiet) {
            return
        }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}) isn''t there, so there''s nothing to delete.' -f $names.ServerName) -Evidence $evidence -DocUrl $docUrl)
    }
    if (-not $PSCmdlet.ShouldProcess($names.ServerName, 'Delete T4''s read replica')) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Not selected' -Message ('What if: T4''s read replica ({0}) would be deleted.' -f $names.ServerName) -Evidence $evidence -DocUrl $docUrl)
    }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $replica.Removing) {
        $url = 'https://management.azure.com{0}?api-version={1}' -f $names.ServerId, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers')
        $sent = Invoke-DemoAzWithConflictRetry -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'delete', '--url', $url) -Label ('T4 replica {0}: delete' -f $names.ServerName) -MaxConflictRetries 4
        if ($sent.ExitCode -ne 0 -and ([string]$sent.StdErr) -notmatch '(?i)ResourceNotFound|\(404\)') {
            $evidence['error'] = Protect-DemoText -Text ([string]$sent.StdErr).Trim()
            return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) couldn''t be deleted, so it still bills while it''s there: {1}' -f $names.ServerName, $evidence['error']) -Evidence $evidence -Remediation 'Run ./scripts/stop-demo.ps1 again in a few minutes; the nightly safety stop stops it meanwhile.' -DocUrl $docUrl)
        }
    }
    if ($NoWait) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}) is being deleted; it bills nothing once it''s gone (about 2 minutes).' -f $names.ServerName) -Evidence $evidence -DocUrl $docUrl)
    }
    $after = Wait-DemoT4ReplicaState -Config $Config -State @('NotFound') -TimeoutMinutes ([int]$setting['deleteTimeoutMinutes']) -PollSeconds 10 -DeploymentId $DeploymentId
    $evidence['seconds'] = [int]$clock.Elapsed.TotalSeconds
    $evidence['stateAfter'] = $after.State
    if (-not $after.Present) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}) was deleted in {1} s, so nothing bills for it until the next session creates it again.' -f $names.ServerName, $evidence['seconds']) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) is still {1} after {2} minutes.' -f $names.ServerName, $after.State, $setting['deleteTimeoutMinutes']) -Evidence $evidence -Remediation 'Check it with ./scripts/status.ps1 in a few minutes; Azure finishes deleting it on its own.' -DocUrl $docUrl)
}

function Invoke-DemoT4ReplicaStartFirst {
    <#
    .SYNOPSIS
    Before T4 starts: a stopped read replica starts first and is waited for until it's Ready, because Azure refuses to
    start T4 while a replica is stopped or still starting (SourceReplicasStartStopOrder, live 2026-11-13). Returns
    <prefix>.T4.REPLICA.START, or nothing when there's no replica or it already runs. Internal.

    .DESCRIPTION
    Only a session that ended without stop-demo.ps1 leaves a replica stopped (the nightly safety stop stops it after T4);
    stop-demo.ps1 deletes it otherwise. A replica that's stopping is waited for first.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Callers confirm once for the whole start or deployment.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('DEPLOY', 'START')]
        [string] $CheckPrefix = 'START',

        [string] $DeploymentId = ''
    )

    $setting = Get-DemoT4ReplicaSetting
    $checkId = '{0}.T4.REPLICA.START' -f $CheckPrefix
    $docUrl = [string]$setting['docUrls']['concepts']
    $replica = Get-DemoT4ReplicaState -Config $Config -DeploymentId $DeploymentId
    if (-not $replica.Exists -or $replica.State -in 'Ready', 'Updating', 'Provisioning') {
        return
    }
    $names = $replica.Names
    $evidence = [ordered]@{ replica = $names.ServerName; stateBefore = $replica.State }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    if ($replica.State -eq 'Stopping') {
        $replica = Wait-DemoT4ReplicaState -Config $Config -State @('Stopped') -TimeoutMinutes ([int]$setting['powerWaitMinutes']) -DeploymentId $DeploymentId
    }
    if ($replica.State -eq 'Stopped') {
        Write-DemoLog -Message ('T4''s read replica ({0}) is stopped (a session that ended without stop-demo.ps1); starting it first, because Azure starts T4 only after its replicas.' -f $names.ServerName)
        $url = 'https://management.azure.com{0}/start?api-version={1}' -f $names.ServerId, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers')
        $post = Invoke-DemoAzWithConflictRetry -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'post', '--url', $url) -Label ('T4 replica {0}: start' -f $names.ServerName) -MaxConflictRetries 4
        if ($post.ExitCode -ne 0) {
            $evidence['error'] = Protect-DemoText -Text ([string]$post.StdErr).Trim()
            return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) is stopped and couldn''t be started, so T4 can''t start either: {1}' -f $names.ServerName, $evidence['error']) -Evidence $evidence -Remediation 'Run ./scripts/stop-demo.ps1, which deletes the replica, then ./scripts/start-demo.ps1.' -DocUrl $docUrl)
        }
    }
    $replica = Wait-DemoT4ReplicaState -Config $Config -State @('Ready') -TimeoutMinutes ([int]$setting['powerWaitMinutes']) -DeploymentId $DeploymentId
    $evidence['stateAfter'] = $replica.State
    $evidence['seconds'] = [int]$clock.Elapsed.TotalSeconds
    if ($replica.State -eq 'Ready') {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}) was {1} and is running again ({2} s), so T4 can start: Azure starts a replica before its source.' -f $names.ServerName, $evidence['stateBefore'].ToLowerInvariant(), $evidence['seconds']) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) is {1}, not Ready, after {2} minutes, so T4 may not start (Azure starts a replica before its source).' -f $names.ServerName, $replica.State, $setting['powerWaitMinutes']) -Evidence $evidence -Remediation 'Run ./scripts/stop-demo.ps1, which deletes the replica, then ./scripts/start-demo.ps1.' -DocUrl $docUrl)
}

function Invoke-DemoT4StopConfirmed {
    <#
    .SYNOPSIS
    T4's stop right after this run asked for its read replica's deletion, confirmed: asked again until T4 is Stopping or
    Stopped, at most -Attempts times within -WaitMinutes. Returns STOP.T4.STOP. Internal.

    .DESCRIPTION
    Azure refuses a primary's stop while an operation still runs on its read replica (SourceReplicasStartStopOrder), and
    the replica's read answers 404 about 20 seconds before its delete finishes. Live on 2026-11-14, the session control's
    runbook sent T4's stop then twice: Azure accepted it, failed it a minute later, and T4 kept running and billing. So
    stop-demo.ps1 doesn't trust an accepted stop after the replica's deletion; it reads T4 until it's Stopping or Stopped,
    and asks again when it's still running after -SettleSeconds, as the runbook's Stop-DbHubT4Confirmed does (R843). A
    stop that Azure takes at once costs one read; a refused one costs about 2.5 minutes per try. A T4 still running after
    the last try is a Fail with the fix, never a silent Pass.
    https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'stop-demo.ps1 confirms once for the whole stop.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $DeploymentId = '',

        [ValidateRange(1, 5)]
        [int] $Attempts = 3,

        [ValidateRange(0, 600)]
        [int] $SettleSeconds = 150,

        [ValidateRange(1, 30)]
        [int] $WaitMinutes = 10,

        [ValidateRange(0, 60)]
        [int] $PollSeconds = 15
    )

    $giveUp = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    $tries = 0
    $state = ''
    $result = $null
    while ($tries -lt $Attempts -and [DateTime]::UtcNow -lt $giveUp) {
        $tries++
        $result = Invoke-DemoT4PowerAction -Config $Config -Action Stop -WaitMinutes 0 -CheckPrefix STOP -DeploymentId $DeploymentId -Requested:($tries -gt 1)
        if ([string]$result.status -ne 'Pass') {
            # A stop that Azure refused outright, or a T4 that isn't there, is already reported with its fix.
            return $result
        }
        # An accepted stop shows within seconds; a failed one leaves T4 running, and a second stop while the first still
        # runs is refused, so each try gets SettleSeconds to show.
        $settle = [DateTime]::UtcNow.AddSeconds($SettleSeconds)
        if ($settle -gt $giveUp) {
            $settle = $giveUp
        }
        do {
            Start-Sleep -Seconds $PollSeconds
            $state = [string](Get-DemoT4State -Config $Config -DeploymentId $DeploymentId).State
            if ($state -in 'Stopping', 'Stopped') {
                $result.evidence['stateAfter'] = $state
                $result.evidence['stopAttempts'] = $tries
                if ($tries -gt 1) {
                    $result.message = ('{0} It took {1} stops: Azure refused the first while T4''s read replica''s delete finished.' -f $result.message, $tries)
                    Write-DemoLog -Level Warning -Message ('T4 is {0} after {1} stops: Azure refused the first while its read replica''s delete finished.' -f $state.ToLowerInvariant(), $tries)
                }
                return $result
            }
        } while ([DateTime]::UtcNow -lt $settle)
        Write-DemoLog -Message ('T4 is still {0} after stop {1}; Azure can refuse a stop while its read replica''s delete finishes, so the stop is asked again.' -f $(if ($state) { $state } else { 'unknown' }), $tries)
    }
    $names = Get-DemoT4Name -Config $Config -DeploymentId $DeploymentId
    $evidence = [ordered]@{ server = $names.ServerName; stateAfter = $state; stopAttempts = $tries; waitMinutes = $WaitMinutes }
    return (New-DemoResult -CheckId 'STOP.T4.STOP' -Area 'infra' -Target 'T4' -Status 'Fail' -Message ('T4 ({0}) is still {1} after {2} stop(s) in {3} minutes: Azure accepted each stop and then refused it, which it does while an operation runs on its read replica, so T4 keeps running and billing.' -f $names.ServerName, $(if ($state) { $state } else { 'unknown' }), $tries, $WaitMinutes) -Evidence $evidence -Remediation 'Run ./scripts/stop-demo.ps1 again in a few minutes; otherwise the nightly safety stop stops T4 at its next run.' -DocUrl ([string](Get-DemoT4ReplicaSetting)['docUrls']['concepts']))
}

function Get-DemoT4ReplicaMetricSnapshot {
    <#
    .SYNOPSIS
    The replica's and T4's replication metrics from Azure Monitor over the last -Minutes, at a one-minute grain: Read
    Replica Lag (physical_replication_delay_in_seconds) and the replica's CPU, memory, connections, IOPS, and storage
    (Maximum), and T4's Max Physical Replication Lag (physical_replication_delay_in_bytes). Returns Succeeded, Error, Latest
    (metric -> newest value), Peak (metric -> highest value), PrimaryLatest, PrimaryPeak, and LatestUtc. Internal.

    .DESCRIPTION
    The documented Metrics - List REST API (az rest --method get), with the query parameters in a file (--url-parameters
    @<path>), as Get-DemoT4MetricSnapshot reads T4's. Read Replica Lag is on replicas only, and Max Physical Replication Lag
    on the primary only (Learn, read replicas, checked 2026-11-13).
    Sources: https://learn.microsoft.com/rest/api/monitor/metrics/list,
    https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas#monitor-replication
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ServerId,

        [AllowEmptyString()]
        [string] $PrimaryId = '',

        [ValidateRange(5, 1440)]
        [int] $Minutes = 15,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $setting = Get-DemoT4ReplicaSetting
    $end = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)
    $timespan = '{0}/{1}' -f $end.AddMinutes(-$Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant), $end.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    $apiVersion = Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Insights/metrics'
    $reads = @(@{ Id = $ServerId; Names = @($setting['metrics']['replica']); Key = 'replica' })
    if ($PrimaryId) {
        $reads += @{ Id = $PrimaryId; Names = @($setting['metrics']['primary']); Key = 'primary' }
    }
    $latest = [ordered]@{}
    $peak = [ordered]@{}
    $primaryLatest = [ordered]@{}
    $primaryPeak = [ordered]@{}
    $newest = $null
    $errors = [System.Collections.Generic.List[string]]::new()
    # At most 20 characters (Initialize-DemoPrivateDirectory); 'dbhub-t4replicametrics' threw live, 2026-11-13.
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-t4replmetrics'
    try {
        $index = 0
        foreach ($read in $reads) {
            $index++
            $parameters = [ordered]@{ timespan = $timespan; interval = 'PT1M'; metricnames = ($read.Names -join ','); aggregation = 'Maximum'; 'api-version' = $apiVersion }
            $path = Write-DemoPrivateFile -Directory $directory -Name ('metrics-{0}.json' -f $index) -Content ($parameters | ConvertTo-Json -Compress)
            $url = 'https://management.azure.com{0}/providers/Microsoft.Insights/metrics' -f $read.Id
            $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'get', '--url', $url, '--url-parameters', "@$path", '--output', 'json') -AllowFailure
            if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
                $errors.Add((Protect-DemoText -Text ([string]$result.StdErr).Trim()))
                continue
            }
            $body = [string]$result.StdOut | ConvertFrom-Json -Depth 32
            foreach ($metric in (Get-DemoMemberList -InputObject $body -Name 'value')) {
                $name = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $metric -Name 'name') -Name 'value')
                foreach ($series in (Get-DemoMemberList -InputObject $metric -Name 'timeseries')) {
                    # Assigned first: Get-DemoMemberList returns its list as one pipeline object, which Where-Object would
                    # get whole, and every point was left out (live, 2026-11-13).
                    $data = Get-DemoMemberList -InputObject $series -Name 'data'
                    $points = @($data | Where-Object { $null -ne (Get-DemoMemberValue -InputObject $_ -Name 'maximum') })
                    if ($points.Count -eq 0) {
                        continue
                    }
                    $last = $points[-1]
                    $highest = ($points | ForEach-Object { [double](Get-DemoMemberValue -InputObject $_ -Name 'maximum') } | Measure-Object -Maximum).Maximum
                    $stamp = ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $last -Name 'timeStamp')
                    if ($read.Key -eq 'replica') {
                        $latest[$name] = [double](Get-DemoMemberValue -InputObject $last -Name 'maximum')
                        $peak[$name] = [double]$highest
                        if ($null -ne $stamp -and ($null -eq $newest -or $stamp -gt $newest)) {
                            $newest = $stamp
                        }
                    }
                    else {
                        $primaryLatest[$name] = [double](Get-DemoMemberValue -InputObject $last -Name 'maximum')
                        $primaryPeak[$name] = [double]$highest
                    }
                }
            }
        }
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    [pscustomobject]@{
        Succeeded     = ($errors.Count -lt $reads.Count)
        Error         = ($errors | Select-Object -First 1)
        Latest        = $latest
        Peak          = $peak
        PrimaryLatest = $primaryLatest
        PrimaryPeak   = $primaryPeak
        LatestUtc     = $(if ($null -ne $newest) { $newest.ToString('o', $invariant) } else { '' })
        Minutes       = $Minutes
    }
}

function Format-DemoT4ReplicaMetricText {
    # One line from a replica metric snapshot: lag now and its peak, the replica's CPU and connections, and T4's bytes
    # behind. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Snapshot
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $lag = [string](Get-DemoT4ReplicaSetting)['metrics']['hubLag']
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($Snapshot.Latest.Contains($lag)) {
        $parts.Add([string]::Format($culture, 'Read replica lag {0:N0} s (peak {1:N0} s in the last {2} minutes)', $Snapshot.Latest[$lag], $Snapshot.Peak[$lag], $Snapshot.Minutes))
    }
    foreach ($pair in @(@('cpu_percent', 'CPU {0:N0}%'), @('active_connections', '{0:N0} active connection(s)'))) {
        if ($Snapshot.Latest.Contains($pair[0])) {
            $parts.Add([string]::Format($culture, $pair[1], $Snapshot.Latest[$pair[0]]))
        }
    }
    if ($Snapshot.PrimaryLatest.Contains('physical_replication_delay_in_bytes')) {
        $parts.Add([string]::Format($culture, 'T4 {0:N0} bytes ahead', $Snapshot.PrimaryLatest['physical_replication_delay_in_bytes']))
    }
    return ($parts -join ', ')
}

function Test-DemoT4ReplicaMetricFlow {
    <#
    .SYNOPSIS
    METRICS.T4.REPLICA: whether Azure Monitor has the replica's Read Replica Lag (physical_replication_delay_in_seconds),
    which Database Hub's PostgreSQL dashboard charts as Read replica lag, from the last -Minutes. With -WaitMinutes, reads
    again every minute until it arrives (a replica created minutes ago). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(5, 1440)]
        [int] $Minutes = 15,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 0,

        [string] $DeploymentId = ''
    )

    $setting = Get-DemoT4ReplicaSetting
    $docUrl = [string](Get-DemoPostgresSetting)['docUrls']['hubMonitor']
    $lag = [string]$setting['metrics']['hubLag']
    $state = Get-DemoDeploymentState -Config $Config
    if (-not (Test-DemoT4ReplicaSetUp -State $state)) {
        return (New-DemoT4ReplicaNotSetUpResult -CheckId 'METRICS.T4.REPLICA' -Status 'Warning')
    }
    $support = Get-DemoT4ReplicaSupport -T4State (Get-DemoT4State -Config $Config -DeploymentId $DeploymentId)
    if ($support.Reason -eq 'Burstable') {
        return (New-DemoT4ReplicaNotSupportedResult -CheckId 'METRICS.T4.REPLICA' -T4SkuName $support.SkuName)
    }
    $replica = Get-DemoT4ReplicaState -Config $Config -DeploymentId $DeploymentId
    if (-not $replica.Exists) {
        return (New-DemoResult -CheckId 'METRICS.T4.REPLICA' -Area 'hub' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) isn''t there, so it has no metrics: it exists only during a session.' -f $replica.Names.ServerName) -Evidence ([ordered]@{ state = $replica.State }) -Remediation './scripts/start-demo.ps1 creates it; its metrics arrive within a few minutes.' -DocUrl $docUrl)
    }
    if ($replica.State -ne 'Ready') {
        return (New-DemoResult -CheckId 'METRICS.T4.REPLICA' -Area 'hub' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) is {1}, so it sends no fresh metrics.' -f $replica.Names.ServerName, $replica.State) -Evidence ([ordered]@{ state = $replica.State }) -Remediation './scripts/start-demo.ps1 starts or creates it.' -DocUrl $docUrl)
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    while ($true) {
        $snapshot = Get-DemoT4ReplicaMetricSnapshot -Config $Config -ServerId $replica.Names.ServerId -PrimaryId $replica.Names.SourceId -Minutes $Minutes
        $flowing = $snapshot.Succeeded -and $snapshot.Latest.Contains($lag)
        if ($flowing -or [DateTime]::UtcNow -ge $deadline) {
            break
        }
        Start-Sleep -Seconds 60
    }
    $evidence = [ordered]@{ latestUtc = $snapshot.LatestUtc; minutes = $Minutes; latest = $snapshot.Latest; peak = $snapshot.Peak; primary = $snapshot.PrimaryLatest }
    if (-not $snapshot.Succeeded) {
        return (New-DemoResult -CheckId 'METRICS.T4.REPLICA' -Area 'hub' -Target 'T4' -Status 'Fail' -Message ('Azure Monitor''s metrics for T4''s read replica couldn''t be read: {0}' -f $snapshot.Error) -Evidence $evidence -Remediation 'Check that you can read the resource group (Reader or higher) and run again.' -DocUrl 'https://learn.microsoft.com/rest/api/monitor/metrics/list')
    }
    if ($flowing) {
        return (New-DemoResult -CheckId 'METRICS.T4.REPLICA' -Area 'hub' -Target 'T4' -Status 'Pass' -Message ('Azure Monitor has T4''s read replica''s metrics from the last {0} minutes ({1}), which Database Hub''s PostgreSQL dashboard charts as Read replica lag.' -f $Minutes, (Format-DemoT4ReplicaMetricText -Snapshot $snapshot)) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId 'METRICS.T4.REPLICA' -Area 'hub' -Target 'T4' -Status 'Warning' -Message ('Azure Monitor has no Read Replica Lag for T4''s read replica from the last {0} minutes yet.' -f $Minutes) -Evidence $evidence -Remediation 'A replica created minutes ago sends metrics within a few minutes; run ./scripts/validate.ps1 -Area T4 again.' -DocUrl $docUrl)
}

function Test-DemoT4ReplicaServer {
    <#
    .SYNOPSIS
    T4.REPLICA: the replica's checks (ADR 0025): it exists and replicates from T4 (replicationRole AsyncReplica, its
    source T4), its size has at least T4's vCores, it's in T4's subnet and private DNS zone, Microsoft Entra only, and its
    replay delay is the lag scenario's. Not set up, Not supported, and between sessions are reported as such. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State = $null,

        [string] $DeploymentId = ''
    )

    $checkId = 'T4.REPLICA'
    $setting = Get-DemoT4ReplicaSetting
    $docUrl = [string]$setting['docUrls']['concepts']
    if ($null -eq $State) {
        $State = Get-DemoDeploymentState -Config $Config
    }
    if (-not (Test-DemoT4ReplicaSetUp -State $State)) {
        return (New-DemoT4ReplicaNotSetUpResult -CheckId $checkId -Status 'Warning')
    }
    $t4 = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
    $support = Get-DemoT4ReplicaSupport -T4State $t4
    if ($support.Reason -eq 'Burstable') {
        return (New-DemoT4ReplicaNotSupportedResult -CheckId $checkId -T4SkuName $support.SkuName)
    }
    $replica = Get-DemoT4ReplicaState -Config $Config -DeploymentId $DeploymentId
    $names = $replica.Names
    if (-not $replica.Exists) {
        $status = if ($replica.State -in 'NotFound') { 'Pass' } else { 'Warning' }
        $message = if ($replica.State -eq 'NotFound') { 'T4''s read replica ({0}) isn''t there now: it exists only during a session (start-demo.ps1 creates it, stop-demo.ps1 deletes it), so nothing bills for it between sessions.' -f $names.ServerName } elseif ($replica.Removing) { 'T4''s read replica ({0}) is being deleted.' -f $names.ServerName } else { 'T4''s read replica ({0}) couldn''t be read: {1}' -f $names.ServerName, $replica.Error }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $status -Message $message -Evidence ([ordered]@{ replica = $names.ServerName; state = $replica.State }) -Remediation $(if ($status -eq 'Pass') { '' } else { 'Check it again in a few minutes.' }) -DocUrl $docUrl)
    }
    $properties = Get-DemoMemberValue -InputObject $replica.Server -Name 'properties'
    $network = Get-DemoMemberValue -InputObject $properties -Name 'network'
    $auth = Get-DemoMemberValue -InputObject $properties -Name 'authConfig'
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($replica.Role -notin 'AsyncReplica', 'GeoAsyncReplica') {
        $problems.Add(('its replication role is {0}, not a read replica' -f $(if ($replica.Role) { $replica.Role } else { 'unknown' })))
    }
    if ($replica.SourceId -and $names.SourceId -and $replica.SourceId -ne $names.SourceId) {
        $problems.Add('its source isn''t T4')
    }
    $vcores = 0
    if ($replica.SkuName -cmatch '^Standard_[A-Z]+(\d{1,2})[a-z_0-9]*$') {
        $vcores = [int]$Matches[1]
    }
    if ($support.VCores -gt 0 -and $vcores -lt $support.VCores) {
        $problems.Add(('{0} has fewer vCores than T4''s {1}' -f $replica.SkuName, $support.SkuName))
    }
    if ($support.SubnetId -and [string](Get-DemoMemberValue -InputObject $network -Name 'delegatedSubnetResourceId') -ne $support.SubnetId) {
        $problems.Add('it isn''t in T4''s subnet')
    }
    if ([string](Get-DemoMemberValue -InputObject $auth -Name 'passwordAuth') -eq 'Enabled') {
        $problems.Add('password authentication is on')
    }
    $delay = Get-DemoT4ParameterState -Config $Config -ServerId $names.ServerId -Name 'max_standby_streaming_delay'
    $evidence = [ordered]@{ replica = $names.ServerName; state = $replica.State; skuName = $replica.SkuName; zone = $replica.Zone; role = $replica.Role; t4SkuName = $support.SkuName; t4Zone = $support.Zone; maxStandbyStreamingDelayMs = $delay.Value }
    if ($delay.Found -and $delay.Value -ne [string]$setting['maxStandbyStreamingDelayMs']) {
        $problems.Add(('max_standby_streaming_delay is {0} ms, not {1}, so replica-lag shows less lag' -f $delay.Value, $setting['maxStandbyStreamingDelayMs']))
    }
    if ($problems.Count -gt 0) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) is there, but {1}.' -f $names.ServerName, ($problems -join '; ')) -Evidence $evidence -Remediation 'Run ./scripts/stop-demo.ps1, which deletes it, then ./scripts/start-demo.ps1, which creates it as the template says.' -DocUrl $docUrl)
    }
    $zones = if ($replica.Zone -and $support.Zone) { ' (zone {0}; T4 in zone {1})' -f $replica.Zone, $support.Zone } else { '' }
    $running = if ($replica.State -eq 'Ready') { 'running (Ready)' } else { $replica.State }
    $status = if ($replica.State -eq 'Ready') { 'Pass' } else { 'Warning' }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $status -Message ('T4''s read replica ({0}, {1}{2}) is {3}: a same-region read replica of {4}, in its subnet, Microsoft Entra only, with replay waiting up to {5} s for a report (replica-lag).' -f $names.ServerName, $replica.SkuName, $zones, $running, $names.SourceName, [int]([int]$setting['maxStandbyStreamingDelayMs'] / 1000)) -Evidence $evidence -Remediation $(if ($status -eq 'Pass') { '' } else { 'start-demo.ps1 starts it; stop-demo.ps1 deletes it.' }) -DocUrl $docUrl)
}

function Get-DemoT4ReplicaStatusResult {
    <#
    .SYNOPSIS
    STATUS.T4.REPLICA for status.ps1 (ADR 0025): not set up yet (the upgrade's command), Not supported on a Burstable T4,
    none between sessions, running with its lag and health, or left over while T4 is stopped (a session that ended
    without stop-demo.ps1), which bills storage and its Defender plans until stop-demo.ps1 deletes it. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State = $null,

        [AllowNull()]
        [object] $T4State = $null,

        [string] $DeploymentId = ''
    )

    $checkId = 'STATUS.T4.REPLICA'
    $setting = Get-DemoT4ReplicaSetting
    $docUrl = [string]$setting['docUrls']['concepts']
    if ($null -eq $State) {
        $State = Get-DemoDeploymentState -Config $Config
    }
    if (-not (Test-DemoT4ReplicaSetUp -State $State)) {
        return (New-DemoT4ReplicaNotSetUpResult -CheckId $checkId -Status 'Warning')
    }
    if ($null -eq $T4State) {
        $T4State = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
    }
    $support = Get-DemoT4ReplicaSupport -T4State $T4State
    if ($support.Reason -eq 'Burstable') {
        return (New-DemoT4ReplicaNotSupportedResult -CheckId $checkId -T4SkuName $support.SkuName)
    }
    $replica = Get-DemoT4ReplicaState -Config $Config -DeploymentId $DeploymentId
    $names = $replica.Names
    $evidence = [ordered]@{ replica = $names.ServerName; state = $replica.State; skuName = $replica.SkuName; zone = $replica.Zone; t4State = $T4State.State; record = [string]$State.T4ReplicaSize }
    if (-not $replica.Present) {
        if ($replica.State -ne 'NotFound') {
            return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) couldn''t be read: {1}' -f $names.ServerName, $replica.Error) -Evidence $evidence -Remediation 'Run ./scripts/status.ps1 again.' -DocUrl $docUrl)
        }
        $next = if ($T4State.State -eq 'Ready') { 'T4 runs without it: ./scripts/start-demo.ps1 creates it (about {0} minutes), and the replica-lag scenario needs it.' -f $setting['createMinutes'] } else { 'The next ./scripts/start-demo.ps1 creates it.' }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}) isn''t there: it exists only during a session, so nothing bills for it now. {1}' -f $names.ServerName, $next) -Evidence $evidence -DocUrl $docUrl)
    }
    if ($replica.Removing) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}) is being deleted (stop-demo.ps1, or a refused size''s shell).' -f $names.ServerName) -Evidence $evidence -DocUrl $docUrl)
    }
    if ($replica.State -eq 'Ready') {
        $snapshot = Get-DemoT4ReplicaMetricSnapshot -Config $Config -ServerId $names.ServerId -PrimaryId $names.SourceId -Minutes 15
        $evidence['latest'] = $snapshot.Latest
        $evidence['peak'] = $snapshot.Peak
        $metricText = if ($snapshot.Succeeded -and $snapshot.Latest.Count -gt 0) { ': {0}' -f (Format-DemoT4ReplicaMetricText -Snapshot $snapshot) } else { '; Azure Monitor has no fresh metrics for it yet' }
        if ($T4State.State -ne 'Ready') {
            return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) is running while T4 is {1}, so it bills its compute with nothing to replicate.' -f $names.ServerName, $T4State.State) -Evidence $evidence -Remediation 'Run ./scripts/stop-demo.ps1, which deletes it.' -DocUrl $docUrl)
        }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}, {1}) is running{2}.' -f $names.ServerName, $replica.SkuName, $metricText) -Evidence $evidence -DocUrl $docUrl)
    }
    if ($replica.State -eq 'Stopped') {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) is stopped: a session ended without stop-demo.ps1, and the nightly safety stop stopped it after T4. It bills its storage and Defender plans while it''s there, and Azure starts it again on its own after 7 days, until the safety stop stops it again.' -f $names.ServerName) -Evidence $evidence -Remediation 'Run ./scripts/stop-demo.ps1, which deletes it; the next ./scripts/start-demo.ps1 creates a new one. (start-demo.ps1 starts this one first if it''s still there, because Azure starts T4 only after its replicas.)' -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) is {1}.' -f $names.ServerName, $replica.State) -Evidence $evidence -Remediation 'Check it again in a few minutes.' -DocUrl $docUrl)
}

function Test-DemoT4ReplicaEstate {
    <#
    .SYNOPSIS
    HUB.ESTATE.T4.REPLICA: whether T4's read replica is in Azure Resource Graph, the inventory source of Database Hub's
    Overview and Estate pages, where the replica is a flexible server of its own (Estate lists flexible servers, not their
    databases). With -WaitMinutes, reads again every minute while a replica created minutes ago isn't listed yet.
    Not supported on a Burstable T4, which meets DONE (ADR 0025). Seeing it on the Estate page itself stays a manual
    check. Internal.

    .DESCRIPTION
    The same documented Resources API query as Test-DemoHubEstate (ResourceGraph.Estate), by the replica's exact name,
    so T4's own lookup by the pgflex01- prefix never takes it for T4.
    Sources: https://learn.microsoft.com/fabric/database/hub/monitor-postgresql (checked 2026-11-13),
    https://learn.microsoft.com/rest/api/azureresourcegraph/resourcegraph/resources/resources
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(0, 60)]
        [int] $WaitMinutes = 0,

        [string] $DeploymentId = ''
    )

    $checkId = 'HUB.ESTATE.T4.REPLICA'
    $docUrl = 'https://learn.microsoft.com/fabric/database/hub/monitor-postgresql'
    $state = Get-DemoDeploymentState -Config $Config
    if (-not (Test-DemoT4ReplicaSetUp -State $state)) {
        return (New-DemoT4ReplicaNotSetUpResult -CheckId $checkId -Status 'Warning')
    }
    $t4 = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
    $support = Get-DemoT4ReplicaSupport -T4State $t4
    if ($support.Reason -eq 'Burstable') {
        return (New-DemoT4ReplicaNotSupportedResult -CheckId $checkId -T4SkuName $support.SkuName)
    }
    $names = Get-DemoT4ReplicaName -Config $Config -DeploymentId $DeploymentId
    $resolved = Resolve-DemoHubTarget -Config $Config -DeploymentId $names.DeploymentId
    $query = Format-DemoKqlTemplate -Name 'ResourceGraph.Estate' -Parameters @{
        SubscriptionId = ConvertTo-DemoKqlLiteral -Value $resolved.SubscriptionId -Type String
        ResourceGroup  = ConvertTo-DemoKqlLiteral -Value $resolved.ResourceGroup -Type String
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    while ($true) {
        $graph = Invoke-DemoHubResourceGraph -SubscriptionId $resolved.SubscriptionId -Query $query
        $row = if ($graph.Succeeded) { @(@($graph.Rows) | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'type') -ieq 'microsoft.dbforpostgresql/flexibleservers' -and [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -ieq $names.ServerName }) | Select-Object -First 1 } else { $null }
        if ($null -ne $row -or -not $graph.Succeeded -or [DateTime]::UtcNow -ge $deadline) {
            break
        }
        Start-Sleep -Seconds 60
    }
    if (-not $graph.Succeeded) {
        return (New-DemoResult -CheckId $checkId -Area 'hub' -Target 'T4' -Status 'Fail' -Message ('Azure Resource Graph, the Hub''s inventory source, could not be queried for T4''s read replica: {0}' -f $graph.Error) -Evidence ([ordered]@{ resourceGroup = $resolved.ResourceGroup }) -Remediation 'Check that you can read the subscription (Reader or higher) and run again.' -DocUrl $docUrl)
    }
    if ($null -ne $row) {
        return (New-DemoResult -CheckId $checkId -Area 'hub' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}) is in Azure Resource Graph as an Azure Database for PostgreSQL flexible server of its own, which the Hub Estate lists next to T4, with its Read replica lag on the PostgreSQL dashboard. Seeing it on the Hub Estate page is a manual check.' -f $names.ServerName) -Evidence ([ordered]@{ resourceId = [string](Get-DemoMemberValue -InputObject $row -Name 'id'); state = [string](Get-DemoMemberValue -InputObject $row -Name 'status'); skuName = [string](Get-DemoMemberValue -InputObject $row -Name 'skuName') }) -DocUrl $docUrl)
    }
    $replica = Get-DemoT4ReplicaState -Config $Config -DeploymentId $DeploymentId
    if (-not $replica.Present) {
        return (New-DemoResult -CheckId $checkId -Area 'hub' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) isn''t there, so the Hub Estate doesn''t list it: it exists only during a session.' -f $names.ServerName) -Evidence ([ordered]@{ state = $replica.State }) -Remediation './scripts/start-demo.ps1 creates it; Resource Graph lists it within minutes.' -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId $checkId -Area 'hub' -Target 'T4' -Status 'Warning' -Message ('T4''s read replica ({0}) exists, but Azure Resource Graph doesn''t list it yet.' -f $names.ServerName) -Evidence ([ordered]@{ state = $replica.State }) -Remediation 'A new resource can take a few minutes to appear in Resource Graph; run ./scripts/validate.ps1 -Area Hub again.' -DocUrl $docUrl)
}

function Invoke-DemoT4ReplicaDoneCheck {
    <#
    .SYNOPSIS
    The DONE gate's part for T4's read replica (ADR 0025): when HUB.ESTATE.T4.REPLICA or METRICS.T4.REPLICA is missing
    from the run, it makes sure the replica exists, as the T4 track does (a run that didn't create it: a resumed run's
    validation after stop-demo.ps1 deleted it), then reads both. A Burstable T4 is Not supported, which meets DONE.
    Returns the results. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [string[]] $Missing = @(),

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 15
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $t4 = Get-DemoT4State -Config $Config
    $support = Get-DemoT4ReplicaSupport -T4State $t4
    if ($support.Reason -eq 'Burstable') {
        foreach ($id in @($Missing | Where-Object { $_ -in 'HUB.ESTATE.T4.REPLICA', 'METRICS.T4.REPLICA' })) {
            $results.Add((New-DemoT4ReplicaNotSupportedResult -CheckId $id -T4SkuName $support.SkuName))
        }
        return $results.ToArray()
    }
    $replica = Get-DemoT4ReplicaState -Config $Config
    if (-not $replica.Exists -and $support.Supported -and $t4.State -eq 'Ready') {
        Write-DemoLog -Message ('T4''s read replica ({0}) isn''t there, and DONE needs it: creating it, as the T4 track does (about {1} minutes).' -f $replica.Names.ServerName, (Get-DemoT4ReplicaSetting)['createMinutes'])
        foreach ($item in @(Invoke-DemoT4ReplicaCreate -Config $Config -CheckPrefix DEPLOY)) {
            $results.Add($item)
        }
    }
    if ('HUB.ESTATE.T4.REPLICA' -in $Missing) {
        $results.Add((Test-DemoT4ReplicaEstate -Config $Config -WaitMinutes ([System.Math]::Min(10, $WaitMinutes))))
    }
    if ('METRICS.T4.REPLICA' -in $Missing) {
        $results.Add((Test-DemoT4ReplicaMetricFlow -Config $Config -WaitMinutes $WaitMinutes))
    }
    return $results.ToArray()
}

function Get-DemoT4ReplicaNote {
    <#
    .SYNOPSIS
    What DONE or NOT DONE says about T4's read replica (ADR 0025), from a run's results, or '': its size change's notice
    (DEPLOY.T4.REPLICA.FALLBACK), Not supported on a Burstable T4 with the fix, or, once created, that it's there for this
    session only. A replica Azure refused every size of is DEPLOY.T4.REPLICA's Fail, which NOT DONE gives as its reason.
    Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $notice = @($all | Where-Object { [string]$_.checkId -eq 'DEPLOY.T4.REPLICA.FALLBACK' }) | Select-Object -Last 1
    if ($null -ne $notice) {
        return [string]$notice.message
    }
    $main = @($all | Where-Object { [string]$_.checkId -eq 'DEPLOY.T4.REPLICA' }) | Select-Object -Last 1
    if ($null -eq $main) {
        return ''
    }
    if ([string]$main.status -eq 'Not supported') {
        return ('{0} {1}' -f [string]$main.message, [string]$main.remediation).Trim()
    }
    if ([string]$main.status -eq 'Pass') {
        $name = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $main -Name 'evidence') -Name 'replica')
        return ('T4''s read replica{0} runs for this session only: ./scripts/stop-demo.ps1 deletes it, so nothing bills for it between sessions, and ./scripts/start-demo.ps1 creates it again (about {1} minutes).' -f $(if ($name) { ' ({0})' -f $name } else { '' }), (Get-DemoT4ReplicaSetting)['createMinutes'])
    }
    return ''
}

function Get-DemoPostgresHistoryCapture {
    <#
    .SYNOPSIS
    T4's and its read replica's Azure Monitor metrics for the history (2026-11-13, ADR 0025), captured on the operator's
    side for NB_DatabaseHub_LiveActivity's POSTGRES_METRICS parameter, because Fabric notebooks get no Azure Resource
    Manager token. Returns Json ('' when there's nothing), and Result (STOP.T4.HISTORY, or $null when T4 isn't
    deployed). Never throws. Internal.

    .DESCRIPTION
    stop-demo.ps1 -SaveHistory calls it before it deletes the replica, whose metrics Azure Monitor no longer answers for
    once it's gone (ResourceNotFound, live 2026-11-13), and deploy.ps1's history snapshot at its end. The reading and the
    JSON's shape are Get-DemoPostgresHistoryParameter's.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(15, 10080)]
        [int] $WindowMinutes = 720,

        [ValidatePattern('^[A-Z0-9]+(\.[A-Z0-9_]+)+$')]
        [string] $CheckId = 'STOP.T4.HISTORY'
    )

    $docUrl = [string](Get-DemoT4ReplicaSetting)['docUrls']['concepts']
    try {
        $t4 = Get-DemoT4State -Config $Config
        if (-not $t4.Exists) {
            return [pscustomobject]@{ Json = ''; Result = $null }
        }
        $capture = Get-DemoPostgresHistoryParameter -Config $Config -WindowMinutes $WindowMinutes
        $json = [string](Get-DemoMemberValue -InputObject $capture -Name 'Json')
        $servers = [int](Get-DemoMemberValue -InputObject $capture -Name 'ServerCount')
        $points = [int](Get-DemoMemberValue -InputObject $capture -Name 'PointCount')
        $evidence = [ordered]@{ servers = $servers; points = $points; bytes = $json.Length; windowMinutes = $WindowMinutes; notes = @(Get-DemoMemberValue -InputObject $capture -Name 'Notes') }
        if ($json -and $points -gt 0) {
            return [pscustomobject]@{ Json = $json; Result = (New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'T4' -Status 'Pass' -Message ('Captured {0} metric point(s) of T4 and its read replica from Azure Monitor over the last {1} minutes for the session''s history, before the replica is deleted (its metrics go with it).' -f $points, $WindowMinutes) -Evidence $evidence -DocUrl $docUrl) }
        }
        return [pscustomobject]@{ Json = $json; Result = (New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'T4' -Status 'Warning' -Message ('Azure Monitor had no metrics for T4 or its read replica over the last {0} minutes, so the session''s history has none of them.' -f $WindowMinutes) -Evidence $evidence -Remediation 'Database Hub''s PostgreSQL dashboard shows T4''s metrics for its retention; the replica''s go with it.' -DocUrl $docUrl) }
    }
    catch {
        return [pscustomobject]@{ Json = ''; Result = (New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'T4' -Status 'Warning' -Message ('T4''s and its read replica''s metrics weren''t captured for the session''s history: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Nothing to do for the demo; the history keeps the SQL targets.' -DocUrl $docUrl) }
    }
}

function Save-DemoPostgresHistoryPending {
    <#
    .SYNOPSIS
    Keeps T4's and its read replica's captured metrics (the POSTGRES_METRICS document) in out/history-pending when the
    session's history run didn't save them, for example while the Fabric capacity is paused (2026-11-13, ADR 0025).
    stop-demo.ps1 deletes the replica, and Azure Monitor no longer answers for a deleted replica's metrics
    (ResourceNotFound, live 2026-11-13), so without this file the session's Read replica lag would be gone. Returns
    STOP.T4.HISTORY.PENDING: a Warning that says so, names the file, and gives the command that adds it to the history
    once the capacity runs; or $null when there's nothing to keep. Never throws. Internal.

    .DESCRIPTION
    The file holds what the notebook's parameter would have: server names, sizes, metric names, times, and numbers; no
    resource ID, subscription, or credential (Get-DemoPostgresHistoryParameter). out/ is Git-ignored.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $Json = '',

        [string] $Directory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/history-pending'),

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    if (-not $Json) {
        return $null
    }
    $checkId = 'STOP.T4.HISTORY.PENDING'
    $docUrl = [string](Get-DemoT4ReplicaSetting)['docUrls']['concepts']
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $document = $null
    try {
        $document = $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The captured POSTGRES_METRICS document isn''t JSON: {0}' -f $_.Exception.Message)
    }
    # Get-DemoMemberValue keeps an array intact, so each list is assigned before it's enumerated.
    $serverList = Get-DemoMemberValue -InputObject $document -Name 'servers'
    $seriesList = Get-DemoMemberValue -InputObject $document -Name 'series'
    $replica = @(@($serverList) | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'role') -eq 'replica' }) | Select-Object -First 1
    $peak = $null
    foreach ($series in @($seriesList)) {
        if ($null -eq $series -or [string](Get-DemoMemberValue -InputObject $series -Name 'metric') -ne 'physical_replication_delay_in_seconds') {
            continue
        }
        $pointList = Get-DemoMemberValue -InputObject $series -Name 'points'
        foreach ($point in @($pointList)) {
            $value = @($point)[-1]
            if ($value -is [ValueType] -and $value -isnot [datetime] -and ($null -eq $peak -or [double]$value -gt $peak)) {
                $peak = [double]$value
            }
        }
    }
    $name = 'postgres-metrics-{0}-{1}.json' -f (Get-DemoResourceGroupName -Config $Config), $NowUtc.ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'", $invariant)
    $path = Join-Path -Path $Directory -ChildPath $name
    $lost = if ($null -ne $replica) { 'T4''s read replica is deleted, and Azure Monitor no longer has its metrics' } else { 'T4''s metrics weren''t added to the history' }
    if (-not $PSCmdlet.ShouldProcess($path, 'Keep T4''s captured metrics for the history')) {
        return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'T4' -Status 'Not selected' -Message ('What if: the captured metrics would be kept in {0}.' -f $path) -DocUrl $docUrl)
    }
    try {
        $null = New-Item -ItemType Directory -Path $Directory -Force
        [System.IO.File]::WriteAllText($path, $Json, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'T4' -Status 'Warning' -Message ('The session''s history wasn''t saved (STOP.FABRIC.SAVEHISTORY says why), and {0}; the metrics captured before the delete couldn''t be kept either ({1}), so this session''s are lost.' -f $lost, (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Database Hub''s PostgreSQL dashboard keeps T4''s own metrics for their retention. Next time, run stop-demo.ps1 -SaveHistory while the Fabric capacity runs.' -DocUrl $docUrl)
    }
    $shown = $path
    $root = $script:RepoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $shown = './' + $path.Substring($root.Length).Replace('\', '/')
    }
    $command = './scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity -PostgresMetricsPath {0}' -f $shown
    $lag = if ($null -ne $peak) { ' (Read replica lag up to {0} s)' -f $peak.ToString('0.#', $invariant) } else { '' }
    $message = 'The session''s history wasn''t saved (STOP.FABRIC.SAVEHISTORY says why), and {0}: the metrics captured before the delete{1} are kept in {2}, so they aren''t lost.' -f $lost, $lag, $shown
    return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'T4' -Status 'Warning' -Message $message -Evidence ([ordered]@{ path = $shown; replica = ($null -ne $replica); peakLagSeconds = $peak; command = $command }) -Remediation ('Once the Fabric capacity runs, run {0} (add -ConfigPath for another configuration): it adds them to the history.' -f $command) -DocUrl $docUrl)
}
