function Test-DemoT4 {
    <#
    .SYNOPSIS
    Checks T4, the Azure Database for PostgreSQL flexible server (Phase 24, ADR 0019): the server and its
    state, its pinned version and size, Microsoft Entra-only authentication with the P6 group as its
    administrator, virtual network integration without public access, the contosocare database, the enhanced
    metrics, max_connections, and with -IncludeMetrics whether Azure Monitor has fresh metrics (METRICS.T4).

    .DESCRIPTION
    Reads only, with the documented REST APIs through 'az rest --method get' (they work while T4 is stopped).
    Results: T4.SERVER, T4.CONFIG, T4.ENTRAONLY, T4.NETWORK, T4.ADMIN, T4.DATABASE, T4.ENHANCEDMETRICS,
    T4.MAXCONNECTIONS, and METRICS.T4. Database Hub's PostgreSQL monitoring reads the same Azure Monitor metrics (it's metrics-only,
    with no query-level diagnostics), so METRICS.T4 passing is what the Hub's PostgreSQL dashboard needs;
    seeing T4 on the Estate page stays a manual check (HUB.ESTATE.T4 checks Resource Graph).
    T4.MAXCONNECTIONS (2026-11-03): the template sets max_connections to config/versions.json's postgresql.maxConnections
    on every size, so connection-surge reaches the limit and Database Hub's Failed connections fill; a static parameter,
    so a new value waits for a restart (isConfigPendingRestart), which deploy.ps1 does before T1 sets T4 up.
    T4 turned off (t4Enabled false) is Not selected.

    Sources (checked 2026-10-23; the server parameter pages 2026-11-03):
    - https://learn.microsoft.com/fabric/database/hub/monitor-postgresql
    - https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private
    - https://learn.microsoft.com/azure/postgresql/security/security-manage-entra-users
    - https://learn.microsoft.com/azure/postgresql/monitor/concepts-monitoring
    - https://learn.microsoft.com/rest/api/monitor/metrics/list
    - https://learn.microsoft.com/azure/postgresql/server-parameters/param-connections-authentication-connection-settings
    - https://learn.microsoft.com/rest/api/postgresql/configurations/get

    .PARAMETER DeploymentId
    The deployment's six-character suffix. Read from the resource group's deploymentId tag when omitted.

    .PARAMETER IncludeMetrics
    Also read the last 15 minutes of T4's Azure Monitor metrics (METRICS.T4).

    .EXAMPLE
    Test-DemoT4 -Config $config -IncludeMetrics
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [switch] $IncludeMetrics,

        [ValidateRange(5, 1440)]
        [int] $MetricMinutes = 15
    )

    $postgres = Get-DemoPostgresSetting
    $docs = $postgres['docUrls']
    $results = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string] $CheckId, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '', [string] $DocUrl = '')
        $area = if ($CheckId -like 'METRICS.*') { 'hub' } else { 't4' }
        $results.Add((New-DemoResult -CheckId $CheckId -Area $area -Target 'T4' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl))
    }
    $later = @('T4.CONFIG', 'T4.ENTRAONLY', 'T4.NETWORK', 'T4.ADMIN', 'T4.DATABASE', 'T4.ENHANCEDMETRICS', 'T4.MAXCONNECTIONS') + @(if ($IncludeMetrics) { 'METRICS.T4' })

    $names = Get-DemoT4Name -Config $Config -DeploymentId $DeploymentId
    if (-not $names.Enabled) {
        & $add 'T4.SERVER' 'Not selected' 'T4 is off in this configuration (t4Enabled is false).'
        return $results.ToArray()
    }
    $current = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
    if (-not $current.Exists) {
        $message = if (-not $names.ServerName) { 'T4''s server name isn''t known: the resource group has no deploymentId tag.' } elseif ($current.State -eq 'NotFound') { 'T4 ({0}) doesn''t exist in {1}.' -f $names.ServerName, $names.ResourceGroup } else { 'T4 ({0}) couldn''t be read: {1}' -f $names.ServerName, $current.Error }
        & $add 'T4.SERVER' 'Fail' $message @{ server = $names.ServerName } 'Deploy it with scripts/deploy.ps1 (or -Resume); the template creates pgflex01-<deploymentId>.' $docs['networkingPrivate']
        foreach ($checkId in $later) {
            & $add $checkId 'Not selected' 'T4 doesn''t exist, so this wasn''t checked.'
        }
        return $results.ToArray()
    }

    $properties = Get-DemoMemberValue -InputObject $current.Server -Name 'properties'
    $sku = Get-DemoMemberValue -InputObject $current.Server -Name 'sku'
    $state = $current.State
    $serverEvidence = [ordered]@{ server = $names.ServerName; resourceId = $names.ServerId; state = $state; fqdn = [string](Get-DemoMemberValue -InputObject $properties -Name 'fullyQualifiedDomainName') }
    switch ($state) {
        'Ready' { & $add 'T4.SERVER' 'Pass' ('T4 ({0}) is running (Ready).' -f $names.ServerName) $serverEvidence }
        'Stopped' { & $add 'T4.SERVER' 'Warning' ('T4 ({0}) is stopped: it sends no metrics and runs no activity. A stopped server starts on its own after {1} days.' -f $names.ServerName, $postgres['autoStartAfterStoppedDays']) $serverEvidence 'start-demo.ps1 starts it with the rest of the demo.' $docs['stopServer'] }
        default { & $add 'T4.SERVER' 'Warning' ('T4 ({0}) is {1}.' -f $names.ServerName, $state) $serverEvidence 'Check again in a few minutes.' $docs['stopServer'] }
    }

    # The size is the t4SkuName setting, or what T4's fallback settled when it isn't set (Resolve-DemoEffectiveConfig;
    # Phase 24, Phase 28 and its follow-up).
    $wantedSku = Get-DemoT4SkuName -Config $Config
    $version = [string](Get-DemoMemberValue -InputObject $properties -Name 'version')
    $skuName = [string](Get-DemoMemberValue -InputObject $sku -Name 'name')
    $storage = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'storage') -Name 'storageSizeGB'
    $configEvidence = [ordered]@{ version = $version; pinnedMajorVersion = $names.MajorVersion; sku = $skuName; tier = [string](Get-DemoMemberValue -InputObject $sku -Name 'tier'); wantedSku = $wantedSku; storageSizeGB = $storage }
    if ($version -eq $names.MajorVersion -and (-not $wantedSku -or $skuName -eq $wantedSku)) {
        & $add 'T4.CONFIG' 'Pass' ('T4 runs PostgreSQL {0} on {1} ({2} GiB of storage), as pinned.' -f $version, $skuName, $storage) $configEvidence
    }
    elseif ($version -eq $names.MajorVersion -and -not (Test-DemoT4SkuExplicit -Config $Config)) {
        # Without t4SkuName, deploy.ps1 keeps an existing server's size: its fallback never resizes one.
        & $add 'T4.CONFIG' 'Warning' ('T4 runs PostgreSQL {0} on {1}, not {2}, which this configuration would choose for a new server; deploy.ps1 keeps an existing server''s size.' -f $version, $skuName, $wantedSku) $configEvidence 'Nothing to do to keep it. To change T4''s size, set t4SkuName to the size you want, then run deploy.ps1.' $docs['versionPolicy']
    }
    else {
        & $add 'T4.CONFIG' 'Warning' ('T4 runs PostgreSQL {0} on {1}; the pins are {2} on {3}.' -f $version, $skuName, $names.MajorVersion, $wantedSku) $configEvidence 'Redeploy with scripts/deploy.ps1 -Resume; a major version upgrade is a separate, documented operation.' $docs['versionPolicy']
    }

    $auth = Get-DemoMemberValue -InputObject $properties -Name 'authConfig'
    $entra = [string](Get-DemoMemberValue -InputObject $auth -Name 'activeDirectoryAuth')
    $password = [string](Get-DemoMemberValue -InputObject $auth -Name 'passwordAuth')
    if ($entra -eq 'Enabled' -and $password -eq 'Disabled') {
        & $add 'T4.ENTRAONLY' 'Pass' 'T4 accepts Microsoft Entra authentication only; password authentication is off, so no PostgreSQL password exists anywhere.' ([ordered]@{ activeDirectoryAuth = $entra; passwordAuth = $password })
    }
    else {
        & $add 'T4.ENTRAONLY' 'Fail' ('T4''s authentication is Entra {0}, password {1}; the demo expects Entra only.' -f $entra, $password) ([ordered]@{ activeDirectoryAuth = $entra; passwordAuth = $password }) 'Redeploy with scripts/deploy.ps1 -Resume, which sets Entra-only authentication.' $docs['entraRoles']
    }

    $network = Get-DemoMemberValue -InputObject $properties -Name 'network'
    $public = [string](Get-DemoMemberValue -InputObject $network -Name 'publicNetworkAccess')
    $subnet = [string](Get-DemoMemberValue -InputObject $network -Name 'delegatedSubnetResourceId')
    $zone = [string](Get-DemoMemberValue -InputObject $network -Name 'privateDnsZoneArmResourceId')
    $networkEvidence = [ordered]@{ publicNetworkAccess = $public; delegatedSubnet = ($subnet -replace '^.*/virtualNetworks/', ''); privateDnsZone = ($zone -replace '^.*/privateDnsZones/', '') }
    if ($public -eq 'Disabled' -and $subnet -match '/subnets/snet-pg$' -and $zone) {
        & $add 'T4.NETWORK' 'Pass' 'T4 is in the delegated subnet snet-pg with a private DNS zone and no public access; only T1''s subnet reaches port 5432.' $networkEvidence
    }
    else {
        & $add 'T4.NETWORK' 'Fail' 'T4 isn''t integrated in snet-pg without public access.' $networkEvidence 'Redeploy with scripts/deploy.ps1 -Resume. Virtual network integration is chosen when the server is created; a server created otherwise must be deleted and created again.' $docs['networkingPrivate']
    }

    $groupId = [string]$Config['t3AdminGroupObjectId']
    $admins = Get-DemoT4Resource -Config $Config -ServerId $names.ServerId -Child 'administrators'
    $entries = if ($admins.Found) { Get-DemoMemberList -InputObject $admins.Value -Name 'value' } else { @() }
    $admin = $entries | Where-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'objectId') -eq $groupId } | Select-Object -First 1
    if ($admin) {
        $adminProperties = Get-DemoMemberValue -InputObject $admin -Name 'properties'
        & $add 'T4.ADMIN' 'Pass' ('The P6 group ({0}) is T4''s Microsoft Entra administrator; T1''s identity signs in through it to set T4 up.' -f (Get-DemoMemberValue -InputObject $adminProperties -Name 'principalName')) ([ordered]@{ principalName = [string](Get-DemoMemberValue -InputObject $adminProperties -Name 'principalName'); principalType = [string](Get-DemoMemberValue -InputObject $adminProperties -Name 'principalType') })
    }
    elseif (-not $admins.Found) {
        & $add 'T4.ADMIN' 'Warning' ('T4''s administrators couldn''t be read: {0}' -f $admins.Error) @{} 'Run the check again.' $docs['entraRoles']
    }
    else {
        & $add 'T4.ADMIN' 'Fail' 'The P6 group isn''t one of T4''s Microsoft Entra administrators.' ([ordered]@{ administrators = @($entries).Count }) 'Redeploy with scripts/deploy.ps1 -Resume, which adds it.' $docs['entraRoles']
    }

    $database = Get-DemoT4Resource -Config $Config -ServerId $names.ServerId -Child ('databases/{0}' -f $names.DatabaseName)
    if ($database.Found) {
        & $add 'T4.DATABASE' 'Pass' ('T4''s database {0} exists.' -f $names.DatabaseName) ([ordered]@{ charset = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $database.Value -Name 'properties') -Name 'charset') })
    }
    else {
        & $add 'T4.DATABASE' 'Fail' ('T4''s database {0} wasn''t found{1}.' -f $names.DatabaseName, $(if ($database.NotFound) { '' } else { ': ' + $database.Error })) @{} 'Redeploy with scripts/deploy.ps1 -Resume.'
    }

    $parameterName = [string]$postgres['enhancedMetricsParameter']
    $setting = Get-DemoT4Resource -Config $Config -ServerId $names.ServerId -Child ('configurations/{0}' -f $parameterName)
    $value = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $setting.Value -Name 'properties') -Name 'value')
    if ($value -ieq 'on') {
        & $add 'T4.ENHANCEDMETRICS' 'Pass' ('Enhanced metrics are on ({0}): sessions by state and by wait event type, the oldest transaction and query, and deadlocks reach Azure Monitor at no extra charge.' -f $parameterName) ([ordered]@{ parameter = $parameterName; value = $value })
    }
    else {
        & $add 'T4.ENHANCEDMETRICS' 'Warning' ('Enhanced metrics are off ({0} = {1}), so the waits, sessions, and oldest-transaction metrics are missing.' -f $parameterName, $(if ($value) { $value } else { 'unknown' })) ([ordered]@{ parameter = $parameterName; value = $value }) 'Redeploy with scripts/deploy.ps1 -Resume, which sets it.' $docs['monitoring']
    }

    # max_connections on every size (2026-11-03): a static parameter, so a new value waits for a restart.
    $wantedConnections = [string]$postgres['maxConnections']
    $connections = Get-DemoT4ParameterState -Config $Config -ServerId $names.ServerId -Name 'max_connections'
    $connectionEvidence = [ordered]@{ parameter = 'max_connections'; value = $connections.Value; wanted = $wantedConnections; pendingRestart = $connections.PendingRestart; source = $connections.Source }
    if (-not $connections.Found) {
        & $add 'T4.MAXCONNECTIONS' 'Warning' ('T4''s max_connections couldn''t be read: {0}' -f $connections.Error) $connectionEvidence 'Run the check again.' $docs['serverParameters']
    }
    elseif ($connections.Value -ne $wantedConnections) {
        & $add 'T4.MAXCONNECTIONS' 'Warning' ('max_connections is {0}, not {1}, so connection-surge may not reach the limit on this size, and Database Hub''s Failed connections may stay empty.' -f $connections.Value, $wantedConnections) $connectionEvidence 'Run ./scripts/deploy.ps1 -FromStage Infrastructure: the template sets it, and the T4 setup restarts T4 to apply it.' $docs['serverParameters']
    }
    elseif ($connections.PendingRestart) {
        & $add 'T4.MAXCONNECTIONS' 'Warning' ('max_connections {0} is set but waits for a restart (a static parameter), so the old limit still applies.' -f $connections.Value) $connectionEvidence 'deploy.ps1 restarts T4 before T1 sets it up (DEPLOY.T4.RESTART), or restart it yourself (az postgres flexible-server restart).' $docs['restartServer']
    }
    else {
        & $add 'T4.MAXCONNECTIONS' 'Pass' ('max_connections is {0} and in effect, so connection-surge reaches the limit and Database Hub''s Failed connections fill on this size.' -f $connections.Value) $connectionEvidence
    }

    if ($IncludeMetrics) {
        $results.Add((Test-DemoT4MetricFlow -Config $Config -ServerId $names.ServerId -State $state -Minutes $MetricMinutes))
    }
    return $results.ToArray()
}
