function Test-DemoT5 {
    <#
    .SYNOPSIS
    Checks T5, the Azure Cosmos DB for NoSQL account (2026-11-18, ADR 0027): the account and its state, Microsoft
    Entra-only access (local authentication off), the private endpoint with public network access off, the database and
    container with their partition key and throughput, the free tier, T1's data-plane role, and with -IncludeMetrics
    whether Azure Monitor has its requests and normalized RU (METRICS.T5).

    .DESCRIPTION
    Reads only, with the documented REST APIs through 'az rest --method get'. Results: T5.ACCOUNT, T5.ENTRAONLY,
    T5.NETWORK, T5.CONTAINER, T5.LIFECYCLE (with -IncludeLifecycle), T5.FREETIER, T5.ACCESS, and METRICS.T5. Since
    2026-11-19 the container exists only during a session once its lifecycle is Session (the demo resource group's
    DbHubT5Container tag): a missing container is then a Pass while sqlvm01 is stopped, and one that's there while it's
    stopped is a Warning (its throughput bills until a stop deletes it). Database Hub monitors a Cosmos DB account through
    Azure Monitor platform metrics, which every account sends with no setup, so METRICS.T5 passing is what its Cosmos DB
    views need; seeing T5 on the Estate page stays a manual check (HUB.ESTATE.T5 checks Resource Graph). Its Security page
    evaluates the same three settings T5.ENTRAONLY and T5.NETWORK read, plus customer-managed keys, which the demo leaves
    off (a Suggestion there). T5 turned off (t5Enabled false) is Not selected.

    Sources (checked 2026-11-18):
    - https://learn.microsoft.com/fabric/database/hub/monitor-cosmos-db
    - https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/database-accounts/get
    - https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/get-sql-container
    - https://learn.microsoft.com/azure/cosmos-db/how-to-connect-role-based-access-control
    - https://learn.microsoft.com/azure/cosmos-db/how-to-configure-private-endpoints
    - https://learn.microsoft.com/azure/cosmos-db/free-tier

    .PARAMETER DeploymentId
    The deployment's six-character suffix. Read from the resource group's deploymentId tag when omitted.

    .PARAMETER IncludeMetrics
    Also read the last 15 minutes of T5's Azure Monitor metrics (METRICS.T5).

    .PARAMETER IncludeLifecycle
    Also report T5's container lifecycle, as the demo resource group records it (T5.LIFECYCLE, 2026-11-19): whether the
    container exists only during a session. validate.ps1 and status.ps1 use it; deploy.ps1 reports DEPLOY.T5.LIFECYCLE.

    .EXAMPLE
    Test-DemoT5 -Config $config -IncludeMetrics
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [switch] $IncludeMetrics,

        [switch] $IncludeLifecycle,

        [ValidateRange(5, 1440)]
        [int] $MetricMinutes = 15
    )

    $cosmos = Get-DemoCosmosSetting
    $docs = $cosmos['docUrls']
    $results = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string] $CheckId, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '', [string] $DocUrl = '')
        $area = if ($CheckId -like 'METRICS.*') { 'hub' } else { 't5' }
        $results.Add((New-DemoResult -CheckId $CheckId -Area $area -Target 'T5' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl))
    }
    $later = @('T5.ENTRAONLY', 'T5.NETWORK', 'T5.CONTAINER') + @(if ($IncludeLifecycle) { 'T5.LIFECYCLE' }) + @('T5.FREETIER', 'T5.ACCESS') + @(if ($IncludeMetrics) { 'METRICS.T5' })

    $names = Get-DemoT5Name -Config $Config -DeploymentId $DeploymentId
    if (-not $names.Enabled) {
        & $add 'T5.ACCOUNT' 'Not selected' 'T5 is off in this configuration (t5Enabled is false).'
        return $results.ToArray()
    }
    $current = Get-DemoT5State -Config $Config -DeploymentId $DeploymentId
    if (-not $current.Exists) {
        $message = if (-not $names.AccountName) { 'T5''s account name isn''t known: the resource group has no deploymentId tag.' } elseif ($current.State -eq 'NotFound') { 'T5 ({0}) doesn''t exist in {1}.' -f $names.AccountName, $names.ResourceGroup } elseif ($current.State -eq 'Unknown') { 'T5 ({0}) couldn''t be read: {1}' -f $names.AccountName, $current.Error } else { 'T5 ({0}) is {1}, so it isn''t deployed.' -f $names.AccountName, $current.State }
        & $add 'T5.ACCOUNT' 'Fail' $message @{ account = $names.AccountName } 'Deploy it with ./scripts/deploy.ps1: the template creates cosmos01-<deploymentId>.' $docs['hubMonitor']
        foreach ($checkId in $later) {
            & $add $checkId 'Not selected' 'T5 doesn''t exist, so this wasn''t checked.'
        }
        return $results.ToArray()
    }

    $properties = Get-DemoMemberValue -InputObject $current.Account -Name 'properties'
    $state = [string]$current.State
    $accountEvidence = [ordered]@{ account = $names.AccountName; resourceId = $names.AccountId; provisioningState = $state; documentEndpoint = [string](Get-DemoMemberValue -InputObject $properties -Name 'documentEndpoint'); kind = [string](Get-DemoMemberValue -InputObject $current.Account -Name 'kind') }
    if ($state -eq 'Succeeded') {
        & $add 'T5.ACCOUNT' 'Pass' ('T5 ({0}) is an Azure Cosmos DB for NoSQL account, and it''s ready (Succeeded). An account has no stop: what bills by the hour is its container''s throughput (T5.CONTAINER).' -f $names.AccountName) $accountEvidence
    }
    else {
        & $add 'T5.ACCOUNT' 'Warning' ('T5 ({0}) is {1}.' -f $names.AccountName, $state) $accountEvidence 'Check again in a few minutes.' $docs['hubMonitor']
    }

    $localAuth = [string](Get-DemoMemberValue -InputObject $properties -Name 'disableLocalAuth')
    $metadataWrite = [string](Get-DemoMemberValue -InputObject $properties -Name 'disableKeyBasedMetadataWriteAccess')
    $authEvidence = [ordered]@{ disableLocalAuth = $localAuth; disableKeyBasedMetadataWriteAccess = $metadataWrite }
    if ($localAuth -ieq 'true') {
        & $add 'T5.ENTRAONLY' 'Pass' 'T5 accepts Microsoft Entra ID only: local (key) authentication is off, so no account key works for its data, and Database Hub''s Security page lists no local-authentication suggestion for it.' $authEvidence
    }
    else {
        & $add 'T5.ENTRAONLY' 'Fail' 'T5 still allows local (key) authentication; the demo expects Microsoft Entra ID only.' $authEvidence 'Run ./scripts/deploy.ps1, which sets disableLocalAuth on the account.' $docs['disableLocalAuth']
    }

    $public = [string](Get-DemoMemberValue -InputObject $properties -Name 'publicNetworkAccess')
    $connections = Get-DemoMemberList -InputObject $properties -Name 'privateEndpointConnections'
    $approved = @($connections | Where-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'privateLinkServiceConnectionState') -Name 'status') -ieq 'Approved' })
    $endpoints = @($approved | ForEach-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'privateEndpoint') -Name 'id') -replace '^.*/privateEndpoints/', '' })
    # In public mode without a policy that needs the endpoint (2026-11-21, ADR 0027): public network access on, limited by a
    # virtual network rule to T1's subnet, snet-sqlvm in the demo resource group's network, through its service endpoint,
    # with no IP rule (DEPLOY.T5.NETWORK).
    $filtered = [string](Get-DemoMemberValue -InputObject $properties -Name 'isVirtualNetworkFilterEnabled') -ieq 'true'
    $ruleIds = @(foreach ($rule in (Get-DemoMemberList -InputObject $properties -Name 'virtualNetworkRules')) { [string](Get-DemoMemberValue -InputObject $rule -Name 'id') })
    $subnets = @($ruleIds | ForEach-Object { $_ -replace '^.*/subnets/', '' })
    $ownSubnet = '(?i)/resourceGroups/{0}/providers/Microsoft\.Network/virtualNetworks/[^/]+/subnets/snet-sqlvm$' -f [regex]::Escape([string]$names.ResourceGroup)
    $ipRules = Get-DemoMemberList -InputObject $properties -Name 'ipRules'
    $viaRule = $public -ieq 'Enabled' -and $filtered -and $ipRules.Count -eq 0 -and $ruleIds.Count -gt 0 -and @($ruleIds | Where-Object { $_ -notmatch $ownSubnet }).Count -eq 0
    $networkEvidence = [ordered]@{ path = $(if ($public -ieq 'Disabled') { 'PrivateEndpoint' } elseif ($viaRule) { 'ServiceEndpoint' } else { 'Open' }); publicNetworkAccess = $public; privateEndpoints = @($endpoints); expectedPrivateEndpoint = $names.PrivateEndpointName; privateDnsZone = $names.PrivateDnsZoneName; virtualNetworkFilter = $filtered; virtualNetworkRules = @($subnets); ipRules = $ipRules.Count }
    if ($public -ieq 'Disabled' -and $endpoints -contains $names.PrivateEndpointName) {
        & $add 'T5.NETWORK' 'Pass' ('T5 is reachable only through its private endpoint {0} in snet-pe (public network access is off); only T1''s subnet reaches it, over HTTPS. It has one in private mode, under a policy that needs it, or because it was created with one (DEPLOY.T5.NETWORK says which).' -f $names.PrivateEndpointName) $networkEvidence
    }
    elseif ($public -ieq 'Disabled') {
        & $add 'T5.NETWORK' 'Fail' ('T5''s public network access is off, but its private endpoint {0} isn''t approved, so T1 can''t reach it.' -f $names.PrivateEndpointName) $networkEvidence 'Run ./scripts/deploy.ps1, which creates the private endpoint and its DNS zone group.' $docs['privateEndpoint']
    }
    elseif ($viaRule) {
        & $add 'T5.NETWORK' 'Pass' 'T5 is reachable from T1''s subnet only: its public network access is on, limited to snet-sqlvm by a virtual network rule through that subnet''s service endpoint, with no IP rule and no private endpoint, as T3 in public mode, since no policy needs one. Database Hub''s Security page lists T5''s public network access, as it does T3''s.' $networkEvidence
    }
    else {
        & $add 'T5.NETWORK' 'Fail' ('T5''s public network access is {0}, and not limited to T1''s subnet alone by a virtual network rule (subnets: {1}; IP rules: {2}), so it''s open wider than the demo sets it.' -f $(if ($public) { $public } else { 'not set' }), $(if ($subnets.Count -gt 0) { $subnets -join ', ' } else { 'none' }), $ipRules.Count) $networkEvidence 'Run ./scripts/deploy.ps1, which sets T5''s network again: a private endpoint with public network access off, or T1''s subnet alone (DEPLOY.T5.NETWORK says which).' $docs['vnetServiceEndpoint']
    }

    $containerPath = Get-DemoT5ContainerPath
    $container = Get-DemoT5Resource -Config $Config -AccountId $names.AccountId -Child $containerPath
    $throughput = if ($container.Found) { Get-DemoT5Resource -Config $Config -AccountId $names.AccountId -Child ('{0}/throughputSettings/default' -f $containerPath) } else { [pscustomobject]@{ Found = $false; NotFound = $true; Value = $null; Error = '' } }
    $resource = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $container.Value -Name 'properties') -Name 'resource'
    $paths = @(foreach ($path in (Get-DemoMemberList -InputObject (Get-DemoMemberValue -InputObject $resource -Name 'partitionKey') -Name 'paths')) { [string]$path })
    $ru = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $throughput.Value -Name 'properties') -Name 'resource') -Name 'throughput'
    # The container's lifecycle (2026-11-19): with Session it exists only during a session, so whether it should be there
    # depends on whether the demo runs (sqlvm01, whose runner sends T5's requests, is running).
    $deploymentState = Get-DemoDeploymentState -Config $Config
    $lifecycle = [string](Get-DemoMemberValue -InputObject $deploymentState -Name 'T5Container')
    $session = $lifecycle -ceq $script:T5LifecycleSession
    $demoRunning = $null
    if ($session) {
        $power = Get-DemoVmPowerState -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName $names.ResourceGroup -VmName $names.T1VmName
        $demoRunning = [string]$power -in 'PowerState/running', 'PowerState/starting'
    }
    $containerEvidence = [ordered]@{ database = $names.DatabaseName; container = $names.ContainerName; partitionKeyPaths = @($paths); throughput = $ru; expectedThroughput = $names.Throughput; lifecycle = $lifecycle; demoRunning = $demoRunning }
    $between = 'it exists only during a session: start-demo.ps1 and Run all create it, and stop-demo.ps1, the session''s end, and the nightly safety stop delete it'
    if (-not $container.Found -and $container.NotFound -and $session -and -not $demoRunning) {
        & $add 'T5.CONTAINER' 'Pass' ('T5''s container {0} isn''t there now, because {1}, so its throughput doesn''t bill between sessions.' -f $names.ContainerName, $between) $containerEvidence '' $docs['provisionThroughput']
    }
    elseif (-not $container.Found -and $container.NotFound -and $session) {
        & $add 'T5.CONTAINER' 'Warning' ('T5''s container {0} isn''t there while {1} runs, so T5''s activity has nothing to write to: {2}.' -f $names.ContainerName, $names.T1VmName, $between) $containerEvidence 'Run ./scripts/start-demo.ps1, which creates it, or start a session with Run all in the control notebook.' $docs['createContainer']
    }
    elseif (-not $container.Found) {
        & $add 'T5.CONTAINER' 'Fail' ('T5''s container {0} in {1} wasn''t found{2}.' -f $names.ContainerName, $names.DatabaseName, $(if ($container.NotFound) { '' } else { ': ' + $container.Error })) $containerEvidence 'Run ./scripts/start-demo.ps1 or ./scripts/deploy.ps1, which create the container.' $docs['hubMonitor']
    }
    elseif ($paths -notcontains $names.PartitionKeyPath) {
        & $add 'T5.CONTAINER' 'Fail' ('T5''s container {0} has the partition key {1}, not {2}, which the runner writes by.' -f $names.ContainerName, ($paths -join ', '), $names.PartitionKeyPath) $containerEvidence 'A partition key can''t change: delete the container, then run ./scripts/deploy.ps1 to create it again.' $docs['hubMonitor']
    }
    elseif ($null -eq $ru) {
        & $add 'T5.CONTAINER' 'Warning' ('T5''s container {0} exists with the partition key {1}, but its throughput couldn''t be read{2}.' -f $names.ContainerName, $names.PartitionKeyPath, $(if ($throughput.Error) { ': ' + $throughput.Error } else { '' })) $containerEvidence 'Run the check again.' $docs['normalizedRu']
    }
    elseif ([int]$ru -ne $names.Throughput) {
        & $add 'T5.CONTAINER' 'Warning' ('T5''s container {0} has {1} RU/s, not {2}: ru-storm drives normalized RU to 100% at {2} RU/s, and more throughput bills more.' -f $names.ContainerName, $ru, $names.Throughput) $containerEvidence 'Run ./scripts/deploy.ps1, which sets it back.' $docs['normalizedRu']
    }
    elseif ($session -and -not $demoRunning -and -not $current.FreeTier) {
        & $add 'T5.CONTAINER' 'Warning' ('T5''s container {0} is there while the demo is stopped ({1} isn''t running), so its {2} RU/s bill until a stop deletes it: {3}.' -f $names.ContainerName, $names.T1VmName, $ru, $between) $containerEvidence 'Run ./scripts/stop-demo.ps1, which deletes it; the next session creates it again.' $docs['provisionThroughput']
    }
    else {
        & $add 'T5.CONTAINER' 'Pass' ('T5''s container {0} in {1} is partitioned by {2}, at {3} RU/s of manual throughput.' -f $names.ContainerName, $names.DatabaseName, $names.PartitionKeyPath, $ru) $containerEvidence
    }
    if ($IncludeLifecycle) {
        # As recorded on the demo resource group (DbHubT5Container); deploy.ps1, grant-safety-stop.ps1, and stop-demo.ps1 set it.
        # Read as stop-demo.ps1 would decide it (-WhatIf: nothing is written), with the session control's mode and whether
        # something automatic deletes the container after a session (review of ab91ee5).
        $recorded = if ($lifecycle -ceq $script:T5LifecycleSession) {
            Resolve-DemoT5ContainerLifecycle -Config $Config -Purpose Stop -State $deploymentState -WhatIf
        }
        else {
            [pscustomobject]@{ Lifecycle = $lifecycle; Recorded = $lifecycle; Changed = $false; Known = $true; Why = ''; RoleName = (Get-DemoActivityControlName -Config $Config).RoleName }
        }
        $said = Get-DemoT5LifecycleText -Lifecycle $recorded -FreeTier ([bool]$current.FreeTier)
        & $add 'T5.LIFECYCLE' $said.Status $said.Text ([ordered]@{ lifecycle = $lifecycle; mode = [string](Get-DemoMemberValue -InputObject $recorded -Name 'Mode'); autoDelete = Get-DemoMemberValue -InputObject $recorded -Name 'AutoDelete'; freeTier = [bool]$current.FreeTier }) $said.Fix $docs['provisionThroughput']
    }

    $freeEvidence = [ordered]@{ enableFreeTier = [bool]$current.FreeTier; t5UseFreeTier = (Test-DemoT5FreeTierWanted -Config $Config) }
    if ($current.FreeTier) {
        & $add 'T5.FREETIER' 'Pass' ('T5 has the subscription''s free tier: the first {0} RU/s and {1} GB are free, so its {2} RU/s cost nothing.' -f $cosmos['freeTierRUs'], $cosmos['freeTierStorageGB'], $names.Throughput) $freeEvidence '' $docs['freeTier']
    }
    else {
        & $add 'T5.FREETIER' 'Pass' ('T5 doesn''t have the free tier (another account in the subscription has it, the subscription is internal, where Azure doesn''t offer it, t5UseFreeTier is false, or it was created without it), so its container''s {0} RU/s bill every hour it exists; estimate-cost.ps1 prices them. Azure sets the free tier only when an account is created.' -f $names.Throughput) $freeEvidence '' $docs['freeTier']
    }

    $principalId = Get-DemoT1PrincipalId -Config $Config
    if (-not $principalId) {
        & $add 'T5.ACCESS' 'Fail' 'T1''s managed identity wasn''t found (sqlvm01 or its system-assigned identity is missing), so it has no data-plane role on T5.' @{} 'Deploy T1 with ./scripts/deploy.ps1.' $docs['dataPlaneRbac']
    }
    else {
        $access = Get-DemoT5Access -Config $Config -AccountId $names.AccountId -PrincipalId $principalId
        $accessEvidence = [ordered]@{ principalId = $principalId; role = 'Cosmos DB Built-in Data Contributor'; roleDefinitionId = [string]$cosmos['dataContributorRoleDefinitionId'] }
        if ($access.Found) {
            & $add 'T5.ACCESS' 'Pass' 'T1''s managed identity has the Cosmos DB Built-in Data Contributor data-plane role on T5, scoped to the account: the runner reads and writes documents with a Microsoft Entra token, and no key exists anywhere.' $accessEvidence
        }
        elseif (-not $access.Read) {
            & $add 'T5.ACCESS' 'Warning' ('T5''s data-plane role assignments couldn''t be read: {0}' -f $access.Error) $accessEvidence 'Run the check again.' $docs['dataPlaneRbac']
        }
        else {
            & $add 'T5.ACCESS' 'Fail' 'T1''s managed identity has no Cosmos DB Built-in Data Contributor role on T5, so the runner can''t reach its data.' $accessEvidence 'Run ./scripts/deploy.ps1: the template assigns it (a data-plane role assignment, which Contributor can create).' $docs['dataPlaneRbac']
        }
    }

    if ($IncludeMetrics) {
        $results.Add((Test-DemoT5MetricFlow -Config $Config -AccountId $names.AccountId -Minutes $MetricMinutes))
    }
    return $results.ToArray()
}
