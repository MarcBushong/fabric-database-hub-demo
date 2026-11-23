# T5 (2026-11-18, ADR 0027): the Azure Cosmos DB for NoSQL account cosmos01-<deploymentId>. Its names, its reads through the
# documented REST APIs, the subscription's free tier, its Azure Monitor metrics, its container's lifecycle, and the DEPLOY.T5
# lines of deploy.ps1.

# The account's provisioning states while it's there (Database Accounts - Get, provisioningState): Succeeded once created,
# Updating while a change applies, Creating while Azure creates it. Deleting means it isn't T5 any more.
# https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/database-accounts/get (checked 2026-11-18)
$script:T5DeployedStates = @('Succeeded', 'Updating', 'Creating')

# T5's container lifecycle (2026-11-19, ADR 0027), the demo resource group's DbHubT5Container tag. A container's provisioned
# throughput can't be taken away, only deleted with it, so the container exists only during a session once the session
# control's role can create it again (Session): the stop paths delete it, and the start paths create it. While it can't
# (AlwaysOn), or in an environment deployed before then (no tag), nothing deletes it, so a session never runs without it.
# The session control's runbooks read the same tag (Get-DbHubT5Lifecycle).
$script:T5LifecycleSession = 'Session'
$script:T5LifecycleAlwaysOn = 'AlwaysOn'
# What the session control's role needs to create T5's container again after a stop deletes it, and to delete it (in
# ActivityControlHelpers.ps1's approved list since 2026-11-19).
# https://learn.microsoft.com/azure/role-based-access-control/permissions/databases#microsoftdocumentdb
$script:T5ContainerControlActions = @(
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/read'
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write'
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/delete'
)
# What the nightly safety stop's role needs to delete T5's container between sessions (in SafetyStopHelpers.ps1's approved list
# since 2026-11-19): with the session control holding no role, it's the only automatic stop that deletes it (review of ab91ee5).
$script:T5SafetyStopContainerActions = @(
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/read'
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/delete'
)

function Test-DemoT5Enabled {
    # True unless the configuration turns T5 off (t5Enabled false; ADR 0027). Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    return -not ($Config.Contains('t5Enabled') -and $null -ne $Config['t5Enabled'] -and -not [bool]$Config['t5Enabled'])
}

function Test-DemoT5FreeTierWanted {
    # True unless the configuration says never to use the free tier (t5UseFreeTier false; ADR 0027). Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    return -not ($Config.Contains('t5UseFreeTier') -and $null -ne $Config['t5UseFreeTier'] -and -not [bool]$Config['t5UseFreeTier'])
}

function Get-DemoCosmosSetting {
    # config/versions.json's cosmosdb block: T5's names, throughput, data-plane role, private DNS zone, and metric names. Internal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    return $versions['cosmosdb']
}

function Get-DemoT5Name {
    <#
    .SYNOPSIS
    Returns T5's names: resource group, the account cosmos01-<deploymentId>, its resource ID and documents host, the
    database and container, the private endpoint, and T1. Internal.

    .DESCRIPTION
    The account's name is stable across redeployments (infra/modules/demo.bicep). The deploymentId comes from -DeploymentId
    or the resource group's deploymentId tag (Get-DemoT3Name); with -NoLookup nothing is read, and AccountName is empty when
    -DeploymentId wasn't given. Enabled is false when the configuration sets t5Enabled to false.
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

    $t3 = Get-DemoT3Name -Config $Config -DeploymentId $DeploymentId -NoLookup:$NoLookup
    $cosmos = Get-DemoCosmosSetting
    $accountName = if ($t3.DeploymentId) { '{0}-{1}' -f $cosmos['accountNamePrefix'], $t3.DeploymentId } else { '' }
    [pscustomobject]@{
        Enabled             = (Test-DemoT5Enabled -Config $Config)
        ResourceGroup       = $t3.ResourceGroup
        DeploymentId        = $t3.DeploymentId
        AccountName         = $accountName
        AccountId           = if ($accountName) { '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DocumentDB/databaseAccounts/{2}' -f $Config['subscriptionId'], $t3.ResourceGroup, $accountName } else { '' }
        AccountHost         = if ($accountName) { '{0}.documents.azure.com' -f $accountName } else { '' }
        DatabaseName        = [string]$cosmos['databaseName']
        ContainerName       = [string]$cosmos['containerName']
        PartitionKeyPath    = [string]$cosmos['partitionKeyPath']
        Throughput          = [int]$cosmos['throughputRUs']
        PrivateEndpointName = 'pe-{0}-{1}-cosmos01' -f $Config['prefix'], $Config['environment']
        PrivateDnsZoneName  = [string]$cosmos['privateDnsZoneName']
        T1VmName            = $t3.T1VmName
    }
}

function Get-DemoT5Resource {
    <#
    .SYNOPSIS
    Reads T5's account, or one of its child resources, through 'az rest --method get' with the pinned API version. Returns
    Found, NotFound, Value, and Error. Internal.

    .DESCRIPTION
    -Child is the path under the account, for example 'sqlDatabases/contosocare/containers/patient-events',
    'sqlDatabases/contosocare/containers/patient-events/throughputSettings/default', or 'sqlRoleAssignments'. Reads only.
    Sources: https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/database-accounts/get,
    https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/get-sql-container
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $AccountId,

        [ValidatePattern('^$|^[A-Za-z]+(/[A-Za-z0-9._-]+)*$')]
        [string] $Child = ''
    )

    # Child resources share the account's pinned version (config/versions.json pins one version for all of them).
    $url = 'https://management.azure.com{0}{1}?api-version={2}' -f $AccountId, $(if ($Child) { '/' + $Child } else { '' }), (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DocumentDB/databaseAccounts')
    $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'get', '--url', $url, '--output', 'json') -AllowFailure
    if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
        return [pscustomobject]@{ Found = $true; NotFound = $false; Value = ([string]$result.StdOut | ConvertFrom-Json -Depth 32); Error = '' }
    }
    $errorText = Protect-DemoText -Text ([string]$result.StdErr).Trim()
    $missing = $errorText -match '(?i)ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound|\bNot ?Found\b|\(404\)'
    return [pscustomobject]@{ Found = $false; NotFound = $missing; Value = $null; Error = $errorText }
}

function Get-DemoT5State {
    <#
    .SYNOPSIS
    T5's account: whether it exists, its provisioning state, whether it has the free tier, and its properties. Internal.

    .DESCRIPTION
    Exists means the account is there and Azure isn't deleting it (provisioningState Succeeded, Updating, or Creating).
    FreeTier is the account's enableFreeTier, which Azure sets only when the account is created.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $DeploymentId = ''
    )

    $names = Get-DemoT5Name -Config $Config -DeploymentId $DeploymentId
    if (-not $names.AccountName) {
        return [pscustomobject]@{ Names = $names; Exists = $false; State = 'NotFound'; FreeTier = $false; Account = $null; Error = 'The resource group has no deploymentId tag.' }
    }
    $read = Get-DemoT5Resource -Config $Config -AccountId $names.AccountId
    if ($read.Found) {
        $properties = Get-DemoMemberValue -InputObject $read.Value -Name 'properties'
        $state = [string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState')
        $freeTier = [string](Get-DemoMemberValue -InputObject $properties -Name 'enableFreeTier') -ieq 'true'
        return [pscustomobject]@{ Names = $names; Exists = ($state -in $script:T5DeployedStates -or -not $state); State = $(if ($state) { $state } else { 'Unknown' }); FreeTier = $freeTier; Account = $read.Value; Error = '' }
    }
    return [pscustomobject]@{ Names = $names; Exists = $false; State = $(if ($read.NotFound) { 'NotFound' } else { 'Unknown' }); FreeTier = $false; Account = $null; Error = $read.Error }
}

function Get-DemoT5FreeTierHolder {
    <#
    .SYNOPSIS
    The Azure Cosmos DB accounts in the configured subscription that have the free tier, from Azure Resource Graph.
    Returns Succeeded, Error, and Accounts (name, resourceGroup, id). Internal.

    .DESCRIPTION
    A subscription has one free-tier account at most, and Azure sets it only when an account is created
    (https://learn.microsoft.com/azure/cosmos-db/free-tier, checked 2026-11-18). Resource Graph lists the accounts the caller
    can read; Contributor on the subscription reads them all. A read.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $query = "resources | where subscriptionId =~ '{0}' | where type =~ 'microsoft.documentdb/databaseaccounts' | where tostring(properties.enableFreeTier) =~ 'true' | project id, name, resourceGroup | take 10" -f $subscriptionId
    $graph = Invoke-DemoHubResourceGraph -SubscriptionId $subscriptionId -Query $query
    if (-not $graph.Succeeded) {
        return [pscustomobject]@{ Succeeded = $false; Error = $graph.Error; Accounts = @() }
    }
    $accounts = @(foreach ($row in @($graph.Rows)) {
            [pscustomobject]@{
                Name          = [string](Get-DemoMemberValue -InputObject $row -Name 'name')
                ResourceGroup = [string](Get-DemoMemberValue -InputObject $row -Name 'resourceGroup')
                Id            = [string](Get-DemoMemberValue -InputObject $row -Name 'id')
            }
        })
    return [pscustomobject]@{ Succeeded = $true; Error = ''; Accounts = $accounts }
}

function Get-DemoSubscriptionQuotaId {
    <#
    .SYNOPSIS
    The configured subscription's offer, as Azure Resource Manager's subscriptionPolicies.quotaId (for example
    Internal_2014-09-01), or '' when it couldn't be read. A read; never throws. Internal.

    .DESCRIPTION
    Azure Cosmos DB refuses the free tier in an internal subscription ("Free tier is not supported for Internal
    subscriptions", live 2026-11-18, quotaId Internal_2014-09-01), which a first deployment otherwise learns only from a
    failed template, about 7 minutes later. Source: Subscriptions - Get
    (https://learn.microsoft.com/rest/api/resources/subscriptions/get, checked 2026-11-18).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = [string]$Config['subscriptionId']
    try {
        $url = 'https://management.azure.com/subscriptions/{0}?api-version={1}' -f $subscriptionId, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Resources/subscriptions')
        $read = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $url, '--query', 'subscriptionPolicies.quotaId', '--output', 'tsv') -AllowFailure
        if ($read.ExitCode -eq 0) {
            return ([string]$read.StdOut).Trim()
        }
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The subscription''s offer couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    return ''
}

function Test-DemoT5FreeTierOffered {
    # Whether Azure Cosmos DB offers the free tier to a subscription with this quotaId: not to an internal one (live
    # 2026-11-18). An empty quotaId (not read) counts as offered; the template's refusal retry is the backstop. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $QuotaId = ''
    )

    return -not ($QuotaId -like 'Internal_*')
}

function Resolve-DemoT5FreeTier {
    <#
    .SYNOPSIS
    Whether this deployment creates T5 with the subscription's free tier, and DEPLOY.T5.FREETIER, which says why (ADR 0027).
    Returns UseFreeTier, Exists, Holder, Reason, and Result. Internal.

    .DESCRIPTION
    - An existing T5 keeps what it has: Azure sets enableFreeTier only at creation, so the template gets the account's own
      value and a redeploy changes nothing (Reason Existing).
    - t5UseFreeTier false: no free tier (Reason Configured).
    - An internal subscription (quotaId Internal_*): no free tier, which Azure refuses there, with a Warning (Reason Offer).
    - Otherwise the free tier when Azure Resource Graph lists no other account in the subscription with it (Reason Free).
      Another account has it: no free tier, and the result names that account (Reason Holder). Resource Graph can't be
      read: no free tier, with a Warning, because asking for a free tier that's taken fails the account's creation; the
      throughput is billed then (Reason Unread).
    -AccountState is Get-DemoT5State's answer when the caller has read it already.
    Sources: https://learn.microsoft.com/azure/cosmos-db/free-tier and
    https://learn.microsoft.com/rest/api/resources/subscriptions/get (checked 2026-11-18).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $DeploymentId = '',

        [AllowNull()]
        [object] $AccountState = $null
    )

    $cosmos = Get-DemoCosmosSetting
    $docUrl = [string]$cosmos['docUrls']['freeTier']
    $current = if ($null -ne $AccountState) { $AccountState } else { Get-DemoT5State -Config $Config -DeploymentId $DeploymentId }
    $accountName = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $current -Name 'Names') -Name 'AccountName')
    $make = {
        param([bool] $Use, [string] $Status, [string] $Message, [string] $Reason, [string] $Holder = '', [string] $Remediation = '')
        [pscustomobject]@{
            UseFreeTier = $Use
            Exists      = [bool]$current.Exists
            Holder      = $Holder
            Reason      = $Reason
            Result      = (New-DemoResult -CheckId 'DEPLOY.T5.FREETIER' -Area 't5' -Target 'T5' -Status $Status -Message $Message -Evidence ([ordered]@{ account = $accountName; exists = [bool]$current.Exists; useFreeTier = $Use; holder = $Holder; reason = $Reason }) -Remediation $Remediation -DocUrl $docUrl)
        }
    }
    if ($current.Exists) {
        if ($current.FreeTier) {
            return (& $make $true 'Pass' ('T5 ({0}) has the subscription''s free tier, so its {1} RU/s cost nothing.' -f $accountName, $cosmos['throughputRUs']) 'Existing')
        }
        return (& $make $false 'Pass' ('T5 ({0}) exists without the free tier, which Azure sets only when an account is created, so it keeps that: its {1} RU/s bill at list price while its container exists (DEPLOY.T5.LIFECYCLE says when; estimate-cost.ps1 prices them).' -f $accountName, $cosmos['throughputRUs']) 'Existing')
    }
    if (-not (Test-DemoT5FreeTierWanted -Config $Config)) {
        return (& $make $false 'Pass' 't5UseFreeTier is false in the configuration, so T5 is created without the free tier: its throughput bills at list price while its container exists (DEPLOY.T5.LIFECYCLE says when; estimate-cost.ps1 prices it).' 'Configured')
    }
    $quotaId = Get-DemoSubscriptionQuotaId -Config $Config
    if (-not (Test-DemoT5FreeTierOffered -QuotaId $quotaId)) {
        return (& $make $false 'Warning' ('Azure Cosmos DB''s free tier isn''t offered to this subscription (an internal subscription, {0}: Azure refuses it there), so T5 is created without it: its {1} RU/s bill at list price while its container exists (DEPLOY.T5.LIFECYCLE says when; estimate-cost.ps1 prices them).' -f $quotaId, $cosmos['throughputRUs']) 'Offer' '' 'Nothing to do. In a subscription that isn''t internal, T5 gets the free tier when it''s created there and no other account has it.')
    }
    $holders = Get-DemoT5FreeTierHolder -Config $Config
    if (-not $holders.Succeeded) {
        return (& $make $false 'Warning' ('Azure Resource Graph couldn''t be read to find whether another account has the subscription''s free tier ({0}), so T5 is created without it: its throughput bills at list price while its container exists.' -f $holders.Error) 'Unread' '' 'Nothing to do. The free tier can only be set when an account is created.')
    }
    $other = @($holders.Accounts | Where-Object { $_.Name -ine $accountName }) | Select-Object -First 1
    if ($null -ne $other) {
        $holder = '{0} (resource group {1})' -f $other.Name, $other.ResourceGroup
        return (& $make $false 'Warning' ('The subscription''s one free-tier Azure Cosmos DB account is {0}, so T5 is created without it: its throughput bills at list price while its container exists (estimate-cost.ps1 prices it).' -f $holder) 'Holder' $holder 'Nothing to do. To have T5 use the free tier, delete that account before T5 is created; once created, T5 keeps what it has.')
    }
    return (& $make $true 'Pass' ('No account in the subscription has the free tier, so T5 is created with it: the first {0} RU/s and {1} GB are free, which covers T5''s {2} RU/s.' -f $cosmos['freeTierRUs'], $cosmos['freeTierStorageGB'], $cosmos['throughputRUs']) 'Free')
}

function Get-DemoT5PolicyAccess {
    <#
    .SYNOPSIS
    What the policies mean for a new T5's network (2026-11-21, ADR 0027): whether it needs a private endpoint, with
    PREFLIGHT.POLICY.COSMOSPUBLIC's status and message. Returns Required, Reason, Policies, Status, and Message. Pure.
    Internal.

    .DESCRIPTION
    As T3 does, a private endpoint only when something needs it:
    - networkMode private: the endpoint (Reason NetworkMode).
    - A policy that turns Azure Cosmos DB public network access off (Modify) or denies an account with it on (Deny), the
      COSMOSPUBLIC category of Get-DemoPolicyRuleCategory: the endpoint, which works under it (Reason Policy).
    - The policies couldn't all be read, or weren't read (-NotRead): the endpoint, which works under any policy (Reason
      Unknown).
    - Preflight's what-if found that Azure Policy denies a T5 with public network access (-Denied, Azure's reason), under
      a policy the inventory doesn't read, such as one assigned to the resource group: the endpoint (Reason Policy; the
      review of fae05b4, 2026-11-22).
    - Otherwise none (Reason None): public network access on, limited to T1's subnet through its service endpoint.
    An existing account keeps what it has, whatever this says, unless a policy needs the endpoint
    (Resolve-DemoT5NetworkAccess).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('public', 'private')]
        [string] $NetworkMode,

        [AllowEmptyCollection()]
        [string[]] $Policy = @(),

        [bool] $Complete = $false,

        [switch] $NotRead,

        [string] $Why = '',

        [string] $Denied = ''
    )

    $policies = @($Policy | Where-Object { $_ } | Select-Object -Unique)
    $make = {
        param([bool] $Required, [string] $Reason, [string] $Status, [string] $Message)
        [pscustomobject]@{ Required = $Required; Reason = $Reason; Policies = $policies; Status = $Status; Message = $Message }
    }
    $kept = 'so T5 keeps a private endpoint in snet-pe, with public network access off'
    if ($NetworkMode -eq 'private') {
        return (& $make $true 'NetworkMode' $(if ($NotRead) { 'Not selected' } else { 'Pass' }) ('networkMode is private, {0}, as T3 does.' -f $kept))
    }
    if ($Denied) {
        return (& $make $true 'Policy' 'Pass' ('The what-if found that Azure Policy denies T5 with public network access ({0}), under a policy the inventory doesn''t read (one assigned to the resource group, say), so T5 is deployed behind a private endpoint in snet-pe, with public network access off, which works under it. Its endpoint and private DNS zone bill all month (estimate-cost.ps1 prices them).' -f (Protect-DemoText -Text $Denied.TrimEnd('.'))))
    }
    if ($policies.Count -gt 0) {
        $list = (@($policies | Select-Object -First 3) -join '; ') + $(if ($policies.Count -gt 3) { '; and {0} more' -f ($policies.Count - 3) } else { '' })
        return (& $make $true 'Policy' 'Pass' ('Azure Policy turns Azure Cosmos DB public network access off or denies it ({0}), {1}, which works under it. Its endpoint and private DNS zone bill all month (estimate-cost.ps1 prices them).' -f $list, $kept))
    }
    if ($NotRead -or -not $Complete) {
        $what = if ($NotRead) { 'The policy inventory didn''t run' } else { 'Not every policy that applies could be read' }
        return (& $make $true 'Unknown' $(if ($NotRead) { 'Not selected' } else { 'Pass' }) ('{0}{1}, so a new T5 gets a private endpoint in snet-pe, with public network access off, which works under any policy; its endpoint and private DNS zone bill all month. An existing T5 keeps what it has (DEPLOY.T5.NETWORK).' -f $what, $(if ($Why) { ' ({0})' -f $Why.TrimEnd('.') } else { '' })))
    }
    return (& $make $false 'None' 'Pass' 'No policy turns Azure Cosmos DB public network access off or denies it, so in public mode a new T5 has no private endpoint: its public network access is on, limited to T1''s subnet through that subnet''s service endpoint, as T3''s, which saves the endpoint and its private DNS zone. Database Hub''s Security page then lists T5''s public network access, as it does T3''s. An existing T5 keeps what it has (DEPLOY.T5.NETWORK).')
}

function Resolve-DemoT5NetworkAccess {
    <#
    .SYNOPSIS
    Whether this deployment keeps T5 behind a private endpoint (the template's t5PrivateAccess), and DEPLOY.T5.NETWORK, which
    says why (2026-11-21, ADR 0027). Returns PrivateAccess, Reason, and Result. A read. Internal.

    .DESCRIPTION
    - networkMode private: the endpoint, as T3 (Reason NetworkMode).
    - An existing account keeps what it has, so an update changes nothing in T5's network: public network access off (an
      account with its private endpoint, as every account deployed before 2026-11-21) keeps its endpoint and DNS zone, and
      snet-sqlvm keeps its service endpoints (Reason Existing); on keeps T1's subnet rule (Reason ExistingPublic), unless a
      policy now needs the endpoint (Reason Policy).
    - A new account (Get-DemoT5State: NotFound): the endpoint when a policy needs it, or when the policies couldn't all be
      read or weren't (-Policy, PREFLIGHT.POLICY.COSMOSPUBLIC's evidence; none at all counts as not read: Reason
      PolicyUnknown); otherwise public network access limited to T1's subnet through its service endpoint (Reason Public).
    - An account that couldn't be read, or is being deleted: the endpoint, which works in every case (Reason Unread).
    - -PolicyFound, what the template step found that preflight didn't (the review of fae05b4, 2026-11-22): Azure Policy
      denied T5 with public network access (Denied, Azure's reason in -PolicyFoundText), or turned it off when the template
      deployed it, with no endpoint (Modified). Either way the endpoint, which works under the policy, deployed again in
      the same run (Reason Policy).
    -AccountState is Get-DemoT5State's answer when the caller has read it already.
    Sources: https://learn.microsoft.com/azure/cosmos-db/how-to-configure-private-endpoints,
    https://learn.microsoft.com/azure/cosmos-db/how-to-configure-vnet-service-endpoint (checked 2026-11-21), and
    https://learn.microsoft.com/azure/governance/policy/concepts/effect-modify and
    https://learn.microsoft.com/azure/governance/policy/concepts/effect-deny (checked 2026-11-22).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('public', 'private')]
        [string] $NetworkMode,

        [AllowNull()]
        [object] $Policy = $null,

        [string] $DeploymentId = '',

        [AllowNull()]
        [object] $AccountState = $null,

        [ValidateSet('', 'Denied', 'Modified')]
        [string] $PolicyFound = '',

        [string] $PolicyFoundText = ''
    )

    $cosmos = Get-DemoCosmosSetting
    $current = if ($null -ne $AccountState) { $AccountState } else { Get-DemoT5State -Config $Config -DeploymentId $DeploymentId }
    $names = Get-DemoMemberValue -InputObject $current -Name 'Names'
    $accountName = [string](Get-DemoMemberValue -InputObject $names -Name 'AccountName')
    $endpointName = [string](Get-DemoMemberValue -InputObject $names -Name 'PrivateEndpointName')
    $exists = [bool](Get-DemoMemberValue -InputObject $current -Name 'Exists')
    $state = [string](Get-DemoMemberValue -InputObject $current -Name 'State')
    $public = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $current -Name 'Account') -Name 'properties') -Name 'publicNetworkAccess')
    $required = Get-DemoMemberValue -InputObject $Policy -Name 'privateEndpointRequired'
    $policyReason = [string](Get-DemoMemberValue -InputObject $Policy -Name 'reason')
    $policies = @(foreach ($item in (Get-DemoMemberList -InputObject $Policy -Name 'policies')) { if ($item) { [string]$item } })
    $policyText = if ($policies.Count -gt 0) { ' ({0})' -f ((@($policies | Select-Object -First 3) -join '; ') + $(if ($policies.Count -gt 3) { '; and {0} more' -f ($policies.Count - 3) } else { '' })) } else { '' }
    $label = if ($accountName) { 'T5 ({0})' -f $accountName } else { 'T5' }
    $make = {
        param([bool] $Private, [string] $Reason, [string] $Status, [string] $Message, [string] $Remediation = '')
        $evidence = [ordered]@{ account = $accountName; privateAccess = $Private; reason = $Reason; networkMode = $NetworkMode; existed = $exists; publicNetworkAccess = $public; privateEndpoint = $(if ($Private) { $endpointName } else { '' }); policies = $policies }
        if ($PolicyFound) {
            $evidence['policyFound'] = $PolicyFound
        }
        $doc = if ($Private) { [string]$cosmos['docUrls']['privateEndpoint'] } else { [string]$cosmos['docUrls']['vnetServiceEndpoint'] }
        [pscustomobject]@{ PrivateAccess = $Private; Reason = $Reason; Result = (New-DemoResult -CheckId 'DEPLOY.T5.NETWORK' -Area 't5' -Target 'T5' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $doc) }
    }
    $endpointText = 'its private endpoint {0} in snet-pe, with public network access off' -f $endpointName
    if ($NetworkMode -eq 'private') {
        return (& $make $true 'NetworkMode' 'Pass' ('{0} is reached through {1}: networkMode is private, as for T3.' -f $label, $endpointText))
    }
    if ($PolicyFound) {
        $found = if ($PolicyFound -eq 'Denied') { 'Azure Policy denied it with public network access ({0})' -f $(if ($PolicyFoundText) { Protect-DemoText -Text $PolicyFoundText.TrimEnd('.') } else { 'RequestDisallowedByPolicy' }) } else { 'Azure Policy turned its public network access off when the template deployed it, and it had no private endpoint for T1 to reach it through' }
        return (& $make $true 'Policy' 'Pass' ('{0} is reached through {1}: {2}, under a policy that preflight didn''t find (one assigned to the resource group, say), so this run deployed it again with the endpoint, which works under it. Its endpoint and private DNS zone bill all month (estimate-cost.ps1 prices them).' -f $label, $endpointText, $found))
    }
    if ($exists -and $public -ine 'Enabled') {
        return (& $make $true 'Existing' 'Pass' ('{0} keeps {1}, and its private DNS zone: an update changes nothing in an existing account''s network. In public mode, a new T5 gets none unless a policy needs it (ADR 0027).' -f $label, $endpointText))
    }
    if ($exists) {
        if ($policyReason -eq 'Policy') {
            return (& $make $true 'Policy' 'Pass' ('{0} moves to a private endpoint ({1}), because Azure Policy now turns Azure Cosmos DB public network access off or denies it{2}.' -f $label, $endpointText, $policyText))
        }
        return (& $make $false 'ExistingPublic' 'Pass' ('{0} keeps its network as it is: public network access on, limited to T1''s subnet (snet-sqlvm) through that subnet''s service endpoint, as T3''s, with no private endpoint. T5.NETWORK checks it.' -f $label))
    }
    if ($state -ne 'NotFound') {
        $problem = [string](Get-DemoMemberValue -InputObject $current -Name 'Error')
        return (& $make $true 'Unread' 'Warning' ('{0} couldn''t be read ({1}), so it keeps, or gets, {2}, which works in every case.' -f $label, $(if ($problem) { Protect-DemoText -Text $problem } else { 'its state is {0}' -f $(if ($state) { $state } else { 'unknown' }) }), $endpointText) 'Nothing to do: the next ./scripts/deploy.ps1 reads it again.')
    }
    if ($required -is [bool] -and -not $required) {
        return (& $make $false 'Public' 'Pass' ('{0} has no private endpoint: networkMode is public, and no policy turns Azure Cosmos DB public network access off or denies it, so its public network access is on, limited to T1''s subnet (snet-sqlvm) through that subnet''s service endpoint, as T3''s. That saves the endpoint and its private DNS zone; Database Hub''s Security page lists T5''s public network access, as it does T3''s. T5.NETWORK checks it.' -f $label))
    }
    if ($policyReason -eq 'Policy') {
        return (& $make $true 'Policy' 'Pass' ('{0} is reached through {1}, because Azure Policy turns Azure Cosmos DB public network access off or denies it{2}.' -f $label, $endpointText, $policyText))
    }
    return (& $make $true 'PolicyUnknown' 'Pass' ('{0} gets {1}: not every policy that applies was read (PREFLIGHT.POLICY.COSMOSPUBLIC), and the endpoint works under any policy.' -f $label, $endpointText))
}

function Get-DemoT5PrivateEndpointStatus {
    <#
    .SYNOPSIS
    Whether T5 has, or gets, its private endpoint and private DNS zone, for the cost estimate (Get-DemoCostEstimate
    -T5PrivateEndpoint; 2026-11-21, ADR 0027): $true, $false, or $null when T5 is off or it can't be told, which the estimate
    prices as an upper bound. Resolve-DemoT5NetworkAccess's answer, with -Policy when preflight has it; without it, a new
    account's answer isn't known (only preflight reads the policies). Never throws. A read. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [ValidateSet('', 'public', 'private')]
        [string] $NetworkMode = '',

        [AllowNull()]
        [object] $Policy = $null,

        [string] $DeploymentId = '',

        [AllowNull()]
        [object] $AccountState = $null
    )

    if (-not (Test-DemoT5Enabled -Config $Config)) {
        return $null
    }
    try {
        $mode = if ($NetworkMode) { $NetworkMode } elseif ([string]$Config['networkMode'] -in 'public', 'private') { [string]$Config['networkMode'] } else { '' }
        $current = if ($null -ne $AccountState) { $AccountState } else { Get-DemoT5State -Config $Config -DeploymentId $DeploymentId }
        if (-not $mode) {
            # networkMode auto, not resolved here: an existing account says what it has; a new one isn't known.
            if ([bool](Get-DemoMemberValue -InputObject $current -Name 'Exists')) {
                return ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $current -Name 'Account') -Name 'properties') -Name 'publicNetworkAccess') -ine 'Enabled')
            }
            return $null
        }
        $resolved = Resolve-DemoT5NetworkAccess -Config $Config -NetworkMode $mode -Policy $Policy -AccountState $current
        if ($resolved.Reason -eq 'Unread' -or ($resolved.Reason -eq 'PolicyUnknown' -and $null -eq $Policy)) {
            return $null
        }
        return [bool]$resolved.PrivateAccess
    }
    catch {
        Write-DemoLog -Level Warning -Message ('Whether T5 has a private endpoint couldn''t be read, so the estimate prices it: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        return $null
    }
}

function Get-DemoT5SubnetServiceEndpoint {
    <#
    .SYNOPSIS
    Whether T1's subnet, snet-sqlvm, has the Microsoft.AzureCosmosDB service endpoint now (the review of 31ccf40, 2026-11-22),
    which a T5 without a private endpoint needs: only the service endpoint sends the subnet's identity to Azure Cosmos DB,
    and the account's virtual network rule refuses every other source (403). Returns Present ($true, $false, or $null when
    it can't be read), State (the endpoint's provisioningState), Subnet, and Error. -SubnetId names the subnet, a T5 virtual
    network rule's; without it, the demo's own snet-sqlvm. A read. Never throws. Internal.
    Sources: https://learn.microsoft.com/cli/azure/network/vnet/subnet#az-network-vnet-subnet-show and
    https://learn.microsoft.com/azure/cosmos-db/how-to-configure-vnet-service-endpoint (checked 2026-11-22).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $SubnetId = ''
    )

    $group = Get-DemoResourceGroupName -Config $Config
    $network = 'vnet-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $subnet = 'snet-sqlvm'
    if ($SubnetId -match '(?i)^/subscriptions/[^/]+/resourceGroups/(?<group>[^/]+)/providers/Microsoft\.Network/virtualNetworks/(?<network>[^/]+)/subnets/(?<subnet>[^/]+)$') {
        $group = $Matches['group']
        $network = $Matches['network']
        $subnet = $Matches['subnet']
    }
    $make = {
        param([object] $Present, [string] $State = '', [string] $Problem = '')
        [pscustomobject]@{ Present = $Present; State = $State; Subnet = $subnet; Error = $Problem }
    }
    try {
        $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('network', 'vnet', 'subnet', 'show', '--resource-group', $group, '--vnet-name', $network, '--name', $subnet, '--output', 'json') -AllowFailure
        if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
            $problem = Protect-DemoText -Text ([string]$read.StdErr).Trim()
            if ($problem -match '(?i)ResourceNotFound|ParentResourceNotFound|ResourceGroupNotFound|\(404\)') {
                return (& $make $false '' $problem)
            }
            return (& $make $null '' $(if ($problem) { $problem } else { 'no answer' }))
        }
        $value = [string]$read.StdOut | ConvertFrom-Json -Depth 32
        # Assigned first: Get-DemoMemberList returns its array as one object.
        $endpoints = Get-DemoMemberList -InputObject $value -Name 'serviceEndpoints'
        $cosmos = $endpoints | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'service') -ieq 'Microsoft.AzureCosmosDB' } | Select-Object -First 1
        if ($null -eq $cosmos) {
            return (& $make $false)
        }
        return (& $make $true ([string](Get-DemoMemberValue -InputObject $cosmos -Name 'provisioningState')))
    }
    catch {
        return (& $make $null '' (Protect-DemoText -Text $_.Exception.Message))
    }
}

function Test-DemoT5WasPublic {
    <#
    .SYNOPSIS
    Whether T5's account has public network access on now, before this deployment (the review of 31ccf40, 2026-11-22): the
    template's t5WasPublic, which keeps snet-sqlvm's Azure Cosmos DB service endpoint, in either network mode, while the
    account moves to its private endpoint. A move that Azure refuses (a policy the endpoint doesn't satisfy, say) then
    leaves T5 as it was, reachable, and the next deployment drops the service endpoint once the account reads public
    network access off. -AccountState is Get-DemoT5State's answer, $null when it couldn't be read: then snet-sqlvm decides,
    because the demo gives it that service endpoint only for a public T5, so a T5 with its private endpoint never gets one
    (Get-DemoT5SubnetServiceEndpoint; a subnet that can't be read counts as without). False with T5 off and for a new
    account. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $AccountState = $null
    )

    if (-not (Test-DemoT5Enabled -Config $Config)) {
        return $false
    }
    if ([bool](Get-DemoMemberValue -InputObject $AccountState -Name 'Exists')) {
        $public = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $AccountState -Name 'Account') -Name 'properties') -Name 'publicNetworkAccess')
        return ($public -ieq 'Enabled')
    }
    if ([string](Get-DemoMemberValue -InputObject $AccountState -Name 'State') -eq 'NotFound') {
        return $false
    }
    return ((Get-DemoT5SubnetServiceEndpoint -Config $Config).Present -eq $true)
}

function Test-DemoT5FreeTierRefusal {
    <#
    .SYNOPSIS
    True when a failed deployment's error says Azure refused T5's free tier: the subscription's offer doesn't include it
    ("Free tier is not supported for Internal subscriptions", live 2026-11-18), or another account took it meanwhile
    ("Free tier has already been applied to another Azure Cosmos DB account in this subscription"). Internal.

    .DESCRIPTION
    Microsoft Learn lists no error code for it, so the match needs an error detail that names the free tier and is Azure
    Cosmos DB's (review, 2026-11-19): the text around "free tier", from the error target that precedes it to the next
    one, names Cosmos DB, its resource provider (Microsoft.DocumentDB, Microsoft.Azure.Documents), or T5's nested
    deployment (cosmos01). Invoke-DemoTemplateDeployment checks T5's refusal before T3's free offer, so an Azure SQL error
    that says "free tier" never costs T5 the free tier, which Azure sets only when an account is created. Validated by
    unit tests with Azure's own texts: every subscription the live tests use is internal, where T5 never asks for it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Text = ''
    )

    $cosmosPattern = '(?i)cosmos|documentdb|Microsoft\.Azure\.Documents|documents\.azure\.com'
    $targetPattern = '(?i)"target"\s*:|\bTarget:\s'
    $flat = ($Text -replace '\\r\\n|\\n|\\r|\\"', ' ') -replace '\s+', ' '
    foreach ($phrase in [regex]::Matches($flat, '(?i)free[ -]?tier')) {
        # The phrase's error detail: from the error target before it (at most 600 characters back) to the next one (at
        # most 300 characters on). JSON details name their target first, the Azure CLI's "Target:" lines before their
        # inner details.
        $from = [Math]::Max(0, $phrase.Index - 600)
        $before = $flat.Substring($from, $phrase.Index - $from)
        $targets = [regex]::Matches($before, $targetPattern)
        if ($targets.Count -gt 0) {
            $before = $before.Substring($targets[$targets.Count - 1].Index)
        }
        $after = $flat.Substring($phrase.Index, [Math]::Min(300, $flat.Length - $phrase.Index))
        $next = [regex]::Match($after, $targetPattern)
        if ($next.Success) {
            $after = $after.Substring(0, $next.Index)
        }
        if (($before + $after) -match $cosmosPattern) {
            return $true
        }
    }
    return $false
}

function Get-DemoT5FreeTierRefusalReason {
    # Azure's reason for refusing T5's free tier, in a few words for DEPLOY.T5.FREETIER, from the failed deployment's error.
    # Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Text = ''
    )

    $flat = $Text -replace '\\r\\n|\\n|\\"', ' '
    $match = [regex]::Match($flat, '(?i)free[ -]?tier is not supported for ([A-Za-z]+) subscriptions')
    if ($match.Success) {
        return ('"Free tier is not supported for {0} subscriptions": the subscription''s offer doesn''t include it' -f $match.Groups[1].Value)
    }
    if ($flat -match '(?i)free[ -]?tier has already been applied to another (?:Azure )?Cosmos DB account') {
        return '"Free tier has already been applied to another Azure Cosmos DB account in this subscription": the subscription''s one free-tier account is taken'
    }
    return 'the subscription''s one free-tier account is taken, or its offer doesn''t include the free tier'
}

function Get-DemoT5MissingResult {
    <#
    .SYNOPSIS
    DEPLOY.T5.MISSING (2026-11-18): a resumed run starts from preflight instead when Azure says T5's account doesn't exist,
    as in a demo deployed before T5. A resume skips the template, which creates it. Returns that Pass, or $null when the
    resume can go on: T5 off, no deploymentId to name the account by, an account that exists, or one that couldn't be read
    (fail safe). A read. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State
    )

    if (-not (Test-DemoT5Enabled -Config $Config)) {
        return $null
    }
    # An earlier run recorded that Azure didn't create the account (DbHubT5Refused; review, 2026-11-19): a resume leaves T5
    # out (Resolve-DemoT5LeftOut) instead of starting from preflight, which would fail the same way.
    if ([string](Get-DemoMemberValue -InputObject $State -Name 'T5Refused')) {
        return $null
    }
    $tags = Get-DemoMemberValue -InputObject $State -Name 'Tags'
    $deploymentId = ''
    if ($tags -is [System.Collections.IDictionary] -and $tags.Contains('deploymentId')) {
        $deploymentId = [string]$tags['deploymentId']
    }
    if (-not $deploymentId) {
        return $null
    }
    $current = Get-DemoT5State -Config $Config -DeploymentId $deploymentId
    if ([string]$current.State -ne 'NotFound') {
        return $null
    }
    $accountName = [string]$current.Names.AccountName
    $message = 'T5 (Azure Cosmos DB) isn''t deployed yet: its account {0} doesn''t exist (a demo deployed before T5, or an account that was deleted). Resuming would skip it, so this run starts from preflight instead: the template creates it, and T1''s runner adds it. What earlier runs finished is checked again and kept.' -f $accountName
    return (New-DemoResult -CheckId 'DEPLOY.T5.MISSING' -Area 't5' -Target 'T5' -Status 'Pass' -Message $message -Evidence ([ordered]@{ accountName = $accountName; recordedStage = [string](Get-DemoMemberValue -InputObject $State -Name 'Stage'); state = [string]$current.State }) -DocUrl ([string](Get-DemoCosmosSetting)['docUrls']['hubMonitor']))
}

# T5's nested deployments, the module names in infra/modules/demo.bicep (Get-DemoT5OnlyFailure; review, 2026-11-19).
$script:T5DeploymentNames = @('cosmos01', 'cosmos01-access')

function Get-DemoT5OnlyFailure {
    <#
    .SYNOPSIS
    Whether a failed template deployment failed in T5's resources alone (review, 2026-11-19): every innermost error of its
    failed operations (Get-DemoDeploymentFailure's Errors) is T5's or, when Azure refused the deployment before it ran,
    every resource a policy disallowed is. Returns T5Only and Text (Azure's reason, redacted). Pure. Internal.

    .DESCRIPTION
    T5's resources (infra/modules/cosmos01.bicep and cosmos01-access.bicep): the Microsoft.DocumentDB types, the nested
    deployments cosmos01 and cosmos01-access, the private endpoint pe-<prefix>-<environment>-cosmos01 with its DNS zone
    group, and the private DNS zone privatelink.documents.azure.com with its link. A failure without an error that names
    a resource is never T5's alone.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Cause,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $ErrorText = ''
    )

    $names = Get-DemoT5Name -Config $Config -NoLookup
    $prefix = [string](Get-DemoCosmosSetting)['accountNamePrefix']
    $isT5 = {
        param([string] $Type, [string] $Name)
        $first = ($Name -split '/')[0]
        if ($Type -like 'Microsoft.DocumentDB/*') {
            return $true
        }
        if ($Type -eq 'Microsoft.Resources/deployments') {
            return ($first -in $script:T5DeploymentNames)
        }
        if ($Type -like 'Microsoft.Network/privateEndpoints*') {
            return ($first -eq $names.PrivateEndpointName)
        }
        if ($Type -like 'Microsoft.Network/privateDnsZones*') {
            return ($first -eq $names.PrivateDnsZoneName)
        }
        if (-not $Type) {
            return ($first -like ('{0}-*' -f $prefix) -or $first -eq $names.PrivateEndpointName -or $first -eq $names.PrivateDnsZoneName)
        }
        return $false
    }
    # Assigned first: Get-DemoMemberValue returns an array as one object.
    $causeErrors = Get-DemoMemberValue -InputObject $Cause -Name 'Errors'
    $errors = @(@($causeErrors) | Where-Object { $null -ne $_ })
    if ($errors.Count -gt 0) {
        $t5 = @($errors | Where-Object { & $isT5 ([string]$_.ResourceType) ([string]$_.ResourceName) })
        return [pscustomobject]@{ T5Only = ($t5.Count -eq $errors.Count); Text = [string](Get-DemoMemberValue -InputObject $Cause -Name 'Text') }
    }
    # Refused before it ran (InvalidTemplateDeployment): a policy names each resource it disallowed.
    $text = [string]$ErrorText
    $disallowed = @([regex]::Matches($text, '(?i)Resource ''([^'']+)'' was disallowed by policy') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($disallowed.Count -gt 0 -and $text -match '(?i)\bRequestDisallowedByPolicy\b') {
        $t5 = @($disallowed | Where-Object { & $isT5 '' $_ })
        return [pscustomobject]@{ T5Only = ($t5.Count -eq $disallowed.Count); Text = (Protect-DemoText -Text ('RequestDisallowedByPolicy: Azure Policy disallowed {0}' -f ($disallowed -join ', '))) }
    }
    return [pscustomobject]@{ T5Only = $false; Text = '' }
}

function Copy-DemoT5OffConfig {
    # A copy of the configuration with T5 left out of this run (review, 2026-11-19): t5Enabled false, and t5LeftOut, why, so
    # the run says T5 is left out rather than off in the configuration (New-DemoT5OffResult). The file isn't changed. Pure.
    # Internal.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $Reason = ''
    )

    $copy = [ordered]@{}
    foreach ($key in $Config.Keys) {
        $copy[$key] = $Config[$key]
    }
    $copy['t5Enabled'] = $false
    $copy['t5LeftOut'] = if ($Reason) { $Reason } else { 'Azure didn''t create its account' }
    return $copy
}

function New-DemoT5LeftOutResult {
    <#
    .SYNOPSIS
    DEPLOY.T5, a Warning (review, 2026-11-19): this run leaves T5 out because Azure didn't create its account, from the
    template's failure (-Cause, Azure's reason) or, in a resume, from an earlier run's record (-RecordedUtc,
    DbHubT5Refused). Its evidence's leftOut tells DONE not to wait for T5's checks (Test-DemoT5LeftOut). Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $Cause = '',

        [AllowEmptyString()]
        [string] $RecordedUtc = ''
    )

    $message = if ($Cause) {
        'Azure didn''t create T5''s Azure Cosmos DB account ({0}), and nothing else failed, so the template was deployed again without T5: this run finishes the rest, and Database Hub shows T1 to T4.' -f $Cause.TrimEnd('.')
    }
    else {
        'Azure didn''t create T5''s Azure Cosmos DB account in an earlier run of this deployment ({0}), so this resume leaves T5 out too, and Database Hub shows T1 to T4.' -f $(if ($RecordedUtc) { 'recorded ' + $RecordedUtc } else { 'recorded on the resource group' })
    }
    $remediation = 'Nothing to do when it was temporary: the next ./scripts/deploy.ps1 that deploys the template (one that isn''t a resume) tries T5 again. When Azure keeps refusing it (a region without capacity for new Azure Cosmos DB accounts, or a policy that denies them), set "t5Enabled": false in config/demo.config.json, or deploy the demo in another region.'
    return (New-DemoResult -CheckId 'DEPLOY.T5' -Area 't5' -Target 'T5' -Status 'Warning' -Message $message -Evidence ([ordered]@{ leftOut = $true; cause = $Cause; recordedUtc = $RecordedUtc }) -Remediation $remediation -DocUrl ([string](Get-DemoCosmosSetting)['docUrls']['hubMonitor']))
}

function Test-DemoT5LeftOut {
    # True when this run left T5 out (DEPLOY.T5 with leftOut, New-DemoT5LeftOutResult): DONE doesn't wait for T5's checks
    # then, though the configuration has T5 on (review, 2026-11-19). Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    foreach ($item in @($Result)) {
        if ($null -ne $item -and [string](Get-DemoMemberValue -InputObject $item -Name 'checkId') -eq 'DEPLOY.T5' -and [bool](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'evidence') -Name 'leftOut')) {
            return $true
        }
    }
    return $false
}

function Resolve-DemoT5LeftOut {
    <#
    .SYNOPSIS
    A resume after an earlier run of this deployment left T5 out because Azure didn't create its account (DbHubT5Refused;
    review, 2026-11-19): returns Config (Copy-DemoT5OffConfig) and Result (DEPLOY.T5, a Warning) when T5 is on, the record
    is there, this run doesn't deploy the template, and the account doesn't exist; otherwise $null, and a run that deploys
    the template tries T5 again. An account that can't be read keeps T5 on. A read. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State,

        [switch] $TemplateRuns
    )

    if ($TemplateRuns -or -not (Test-DemoT5Enabled -Config $Config)) {
        return $null
    }
    $recorded = [string](Get-DemoMemberValue -InputObject $State -Name 'T5Refused')
    if (-not $recorded) {
        return $null
    }
    $tags = Get-DemoMemberValue -InputObject $State -Name 'Tags'
    $deploymentId = if ($tags -is [System.Collections.IDictionary] -and $tags.Contains('deploymentId')) { [string]$tags['deploymentId'] } else { '' }
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        return $null
    }
    $current = Get-DemoT5State -Config $Config -DeploymentId $deploymentId
    if ($current.Exists -or [string]$current.State -eq 'Unknown') {
        return $null
    }
    $result = New-DemoT5LeftOutResult -RecordedUtc $recorded
    return [pscustomobject]@{ Config = (Copy-DemoT5OffConfig -Config $Config -Reason ('Azure didn''t create its account in an earlier run ({0})' -f $recorded)); Result = $result }
}

function New-DemoT5OffResult {
    # DEPLOY.T5.OFF: the configuration turns T5 off (t5Enabled false), so this run neither creates nor checks it, and an
    # existing account stays as it is; $null when T5 is on, or when this run left it out (t5LeftOut, DEPLOY.T5 says why).
    # Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ((Test-DemoT5Enabled -Config $Config) -or [string]$Config['t5LeftOut']) {
        return $null
    }
    return (New-DemoResult -CheckId 'DEPLOY.T5.OFF' -Area 't5' -Target 'T5' -Status 'Not selected' -Message 'T5 (Azure Cosmos DB) is off in this configuration (t5Enabled is false), so this run neither creates nor checks it, and Database Hub shows T1 to T4 only. An account an earlier run created stays as it is, and keeps billing its throughput.' -Remediation 'To add T5, remove t5Enabled from the configuration (or set it to true) and run ./scripts/deploy.ps1. To remove an existing account, ./scripts/destroy.ps1 removes it with the resource group.' -DocUrl ([string](Get-DemoCosmosSetting)['docUrls']['hubMonitor']))
}

function Get-DemoT5FreeTierStatus {
    <#
    .SYNOPSIS
    Whether T5 has, or would get, the subscription's free tier, for the cost estimate (Get-DemoCostEstimate -T5FreeTier):
    $true, $false, or $null when T5 is off or it couldn't be read. Never throws. A read (Resolve-DemoT5FreeTier). Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $DeploymentId = ''
    )

    if (-not (Test-DemoT5Enabled -Config $Config)) {
        return $null
    }
    try {
        $resolved = Resolve-DemoT5FreeTier -Config $Config -DeploymentId $DeploymentId
        if ([string]$resolved.Reason -eq 'Unread') {
            # Resource Graph couldn't be read: the estimate says it wasn't checked.
            return $null
        }
        return [bool]$resolved.UseFreeTier
    }
    catch {
        Write-DemoLog -Level Warning -Message ('Whether T5 has the free tier couldn''t be read, so the estimate prices it at list price: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        return $null
    }
}

function Get-DemoT5ContainerPath {
    # T5's container under its account: sqlDatabases/<database>/containers/<container> (config/versions.json). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $cosmos = Get-DemoCosmosSetting
    return ('sqlDatabases/{0}/containers/{1}' -f $cosmos['databaseName'], $cosmos['containerName'])
}

function Get-DemoT5CostLifecycle {
    <#
    .SYNOPSIS
    How the cost estimate prices T5's throughput (Get-DemoCostEstimate -T5ContainerLifecycle; 2026-11-19, ADR 0027):
    Session, for the running hours only, where something automatic deletes the container after a session; AlwaysOn, all
    month, otherwise. With no environment yet, Session. An existing environment: AlwaysOn when its DbHubT5Container tag
    isn't Session (its session control can't create the container yet, or it was deployed before then); with Session,
    Session only while the session control's role can (Control), or, while it holds no role at all, while the nightly
    safety stop deletes the container (review of ab91ee5): otherwise only stop-demo.ps1 deletes it, so AlwaysOn, as when
    the role can't be read. Never throws: a deployment state that can't be read is Session. Internal.

    .DESCRIPTION
    -ThisRunDeploys (deploy.ps1's preflight, 2026-11-19, the coordinator's gap fix): what this run's lifecycle step will
    lead to: Session when the session control will be able to create the container (its role has the container's actions,
    or the deployer can write them, and its identity holds it, or the deployer can assign it), or will have no role at all
    while the nightly safety stop already deletes the container; AlwaysOn when it will hold a role without the actions, no
    role with nothing automatic to delete it, or when that can't be read (fail safe).

    -Detail (the re-review of 0590bbe, 2026-11-19) returns Lifecycle, Reason, and ManualDeleteOnly instead of the
    lifecycle alone. Reason is Session, NoEnvironment, or Unread for Session; NoAutoDelete, Lacking, NotRecorded, or
    Unknown for AlwaysOn. ManualDeleteOnly is true for NoAutoDelete only: the container is priced all month only because
    nothing automatic deletes it after a session (the session control holds no role, and no nightly safety stop can),
    while ./scripts/stop-demo.ps1 still does; Get-DemoCostEstimate -T5ManualDeleteOnly then never makes the hard ceiling
    a Fail by itself.
    #>
    [CmdletBinding()]
    [OutputType([string], [pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        # Get-DemoDeploymentState's result; read when it isn't given.
        [AllowNull()]
        [object] $State = $null,

        [switch] $ThisRunDeploys,

        # Get-DemoDeployerRolePermission's answer, for -ThisRunDeploys; read when it isn't given.
        [AllowNull()]
        [object] $Permission = $null,

        [switch] $Detail
    )

    $asDetail = [bool]$Detail
    $reply = {
        param([string] $Lifecycle, [string] $Reason)
        if ($asDetail) {
            return [pscustomobject]@{ Lifecycle = $Lifecycle; Reason = $Reason; ManualDeleteOnly = ($Reason -ceq 'NoAutoDelete') }
        }
        return $Lifecycle
    }
    try {
        if ($null -eq $State) {
            $State = Get-DemoDeploymentState -Config $Config
        }
        $exists = [bool](Get-DemoMemberValue -InputObject $State -Name 'Exists')
        $recorded = [string](Get-DemoMemberValue -InputObject $State -Name 'T5Container')
        if ($ThisRunDeploys) {
            if ($null -eq $Permission) {
                $Permission = Get-DemoDeployerRolePermission -Config $Config
            }
            $control = Get-DemoT5ControlRoleState -Config $Config
            if ($control.Mode -eq 'Unknown') {
                return (& $reply $script:T5LifecycleAlwaysOn 'Unknown')
            }
            # The run writes the control's role to exactly its approved actions ($script:ActivityControlRoleActions), so a
            # deployer who can write it adds the container's actions only while they're approved there.
            $approved = @($script:T5ContainerControlActions | Where-Object { $_ -notin $script:ActivityControlRoleActions }).Count -eq 0
            $willHaveActions = @($control.Lacking).Count -eq 0 -or ([bool]$Permission.CanDefine -and $approved)
            $willHold = [bool]$control.HoldsRole -or [bool]$Permission.CanAssign
            if ($willHold -and -not $willHaveActions) {
                return (& $reply $script:T5LifecycleAlwaysOn 'Lacking')
            }
            if (-not $willHold -and [bool]$control.HoldsOther) {
                return (& $reply $script:T5LifecycleAlwaysOn 'Lacking')
            }
            # No role at all (review of ab91ee5): only stop-demo.ps1 deletes the container then, unless the nightly safety stop
            # does already; this run can't set that up either, since it can't assign roles.
            if (-not $willHold -and -not (Test-DemoT5SafetyStopDelete -Config $Config)) {
                return (& $reply $script:T5LifecycleAlwaysOn 'NoAutoDelete')
            }
            return (& $reply $script:T5LifecycleSession 'Session')
        }
        if (-not $exists) {
            return (& $reply $script:T5LifecycleSession 'NoEnvironment')
        }
        if ($recorded -cne $script:T5LifecycleSession) {
            return (& $reply $script:T5LifecycleAlwaysOn 'NotRecorded')
        }
        # Recorded Session: for a session's hours only where something automatic deletes the container (review of
        # ab91ee5): the session control's role, or, while it holds none, the nightly safety stop. Otherwise only
        # stop-demo.ps1 does, so it's priced all month, and a role that can't be read is too (fail safe).
        $control = Get-DemoT5ControlRoleState -Config $Config
        if ($control.Mode -eq 'Control') {
            return (& $reply $script:T5LifecycleSession 'Session')
        }
        if ($control.Mode -eq 'NoRole') {
            if (Test-DemoT5SafetyStopDelete -Config $Config) {
                return (& $reply $script:T5LifecycleSession 'Session')
            }
            return (& $reply $script:T5LifecycleAlwaysOn 'NoAutoDelete')
        }
        return (& $reply $script:T5LifecycleAlwaysOn $(if ($control.Mode -eq 'Lacking') { 'Lacking' } else { 'Unknown' }))
    }
    catch {
        Write-DemoLog -Level Debug -Message ('T5''s container lifecycle wasn''t read for the estimate, so it''s priced as Session: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    return (& $reply $script:T5LifecycleSession 'Unread')
}

function Get-DemoT5CeilingExceptionText {
    <#
    .SYNOPSIS
    Why a month over monthlyCeilingUsd is a Warning and never a Fail when it's over only because T5's container is priced
    all month while nothing automatic deletes it after a session (2026-11-19, the re-review of 0590bbe; ADR 0016's
    exceptions): Text, the sentence that says so, and Fix, the three ways to clear it. PREFLIGHT.COST.MONTHLY (preflight and
    start-demo.ps1) and DEPLOY.T5.LIFECYCLE's worst case after the run say the same. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # What pricing the container all month adds, in USD a month.
        [Parameter(Mandatory)]
        [double] $ExtraMonthly,

        # The month with the container for the running hours only: within the ceiling.
        [Parameter(Mandatory)]
        [double] $SessionMonthly,

        # The month after an Owner's grant-safety-stop.ps1: the container for the running hours only, and T4's restart
        # about a day each.
        [Parameter(Mandatory)]
        [double] $GrantMonthly,

        # The month's worst case, over the ceiling.
        [Parameter(Mandatory)]
        [double] $WorstMonthly,

        [string] $ConfigPath = ''
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $text = [string]::Format($culture, 'This is a Warning, not a Fail: T5''s container is priced all month, {0:N2} USD more than for the running hours only, because no role can delete it automatically after a session (the session control has no role, and the nightly safety stop''s role can''t delete it), so only ./scripts/stop-demo.ps1 does; with it deleted after each session, the month would be {1:N2} USD, within the ceiling.', $ExtraMonthly, $SessionMonthly)
    $fix = [string]::Format($culture, 'deploy.ps1 and start-demo.ps1 go on. To clear it, any one of these: an Owner of the subscription runs, once: {0}, which gives the session control and the nightly safety stop their roles, so the worst case falls to about {1:N2} USD; or raise monthlyCeilingUsd to at least {2:N0} in your configuration (the budget follows it at the next deploy.ps1 -FromStage Infrastructure); or set t5Enabled to false, which leaves T5 out. Until then, run ./scripts/stop-demo.ps1 after each session: it deletes T5''s container.', (Get-DemoSafetyStopCommand -ConfigPath $ConfigPath), $GrantMonthly, [System.Math]::Ceiling($WorstMonthly))
    return [pscustomobject]@{ Text = $text; Fix = $fix }
}

function Get-DemoT5ContainerBody {
    <#
    .SYNOPSIS
    The body that creates T5's container through Azure Resource Manager (2026-11-19, ADR 0027): config/versions.json's
    partition key, indexing policy, and throughput, exactly as infra/modules/cosmos01.bicep deploys them, and the demo
    resource group's own tags (the names the safety stop's resources carry), which a tenant's tag policy may require.
    Pure. Internal.
    Source: https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/create-update-sql-container
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $GroupTag = $null
    )

    $cosmos = Get-DemoCosmosSetting
    $tags = [ordered]@{}
    if ($null -ne $GroupTag) {
        foreach ($key in $script:SafetyStopTagNames) {
            if ($GroupTag.Contains($key) -and [string]$GroupTag[$key]) {
                $tags[$key] = [string]$GroupTag[$key]
            }
        }
    }
    return [ordered]@{
        tags       = $tags
        properties = [ordered]@{
            resource = [ordered]@{
                id             = [string]$cosmos['containerName']
                partitionKey   = [ordered]@{ paths = @([string]$cosmos['partitionKeyPath']); kind = 'Hash'; version = [int]$cosmos['partitionKeyVersion'] }
                indexingPolicy = $cosmos['indexingPolicy']
            }
            options  = [ordered]@{ throughput = [int]$cosmos['throughputRUs'] }
        }
    }
}

function Wait-DemoT5Container {
    <#
    .SYNOPSIS
    Reads T5's container every -PollSeconds until it's there (-Present) or gone (without it), for at most -TimeoutSeconds.
    Returns Reached, Found, Error, and Seconds. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $AccountId,

        [switch] $Present,

        [ValidateRange(0, 3600)]
        [int] $TimeoutSeconds = 300,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 10
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $read = Get-DemoT5Resource -Config $Config -AccountId $AccountId -Child (Get-DemoT5ContainerPath)
        $reached = if ($Present) { [bool]$read.Found } else { [bool]$read.NotFound }
        if ($reached -or ($watch.Elapsed.TotalSeconds + $PollSeconds) -gt $TimeoutSeconds) {
            return [pscustomobject]@{ Reached = $reached; Found = [bool]$read.Found; Error = [string]$read.Error; Seconds = [int][System.Math]::Round($watch.Elapsed.TotalSeconds) }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function New-DemoT5Container {
    <#
    .SYNOPSIS
    Makes sure T5's container exists before T5's activity starts (2026-11-19, ADR 0027): when it's missing, creates it
    through Azure Resource Manager with config/versions.json's definition and waits until Azure reads it back. Returns
    -CheckId's result: Pass when it was there or was created, Fail when it couldn't be (with the fix), Not selected when
    T5 is off or its account isn't there. Internal.

    .DESCRIPTION
    The container exists only during a session once its lifecycle is Session (the DbHubT5Container tag): stop-demo.ps1,
    the session's end, and the nightly safety stop delete it, so start-demo.ps1, deploy.ps1 (whose template creates it
    too, but a resumed run skips the template), and demo-control.ps1 create it before T5's activity. The account, the
    database, and T1's data-plane role (scoped to the account) stay, so a new container needs nothing else. Azure refuses a
    container's name for a moment while it still deletes the last one (a conflict), so the create is tried again every
    -PollSeconds until -WaitMinutes pass. Sources (checked 2026-11-19):
    https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/create-update-sql-container,
    https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/get-sql-container
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        # Get-DemoT5State's result; read when it isn't given.
        [AllowNull()]
        [object] $State = $null,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [ValidatePattern('^[A-Z][A-Z0-9_.]+$')]
        [string] $CheckId = 'START.T5.CONTAINER',

        [ValidateRange(1, 30)]
        [int] $WaitMinutes = 5,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 10
    )

    $cosmos = Get-DemoCosmosSetting
    $docs = $cosmos['docUrls']
    $resultCheckId = $CheckId
    if ($null -eq $State) {
        $State = Get-DemoT5State -Config $Config -DeploymentId $DeploymentId
    }
    $names = $State.Names
    $evidence = [ordered]@{ account = [string]$names.AccountName; database = [string]$names.DatabaseName; container = [string]$names.ContainerName; throughputRUs = [int]$names.Throughput; action = 'none' }
    $result = {
        param([string] $Status, [string] $Message, [string] $Remediation = '', [string] $DocUrl = '')
        New-DemoResult -CheckId $resultCheckId -Area 't5' -Target 'T5' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $DocUrl
    }
    if (-not $names.Enabled) {
        return (& $result 'Not selected' 'T5 is off in this configuration (t5Enabled is false).')
    }
    if (-not $State.Exists) {
        return (& $result 'Not selected' ('T5''s account ({0}) isn''t there, so its container wasn''t created.' -f $(if ($names.AccountName) { $names.AccountName } else { 'cosmos01-<deploymentId>' })) 'Run ./scripts/deploy.ps1: it creates T5.' $docs['hubMonitor'])
    }
    $path = Get-DemoT5ContainerPath
    $read = Get-DemoT5Resource -Config $Config -AccountId $names.AccountId -Child $path
    if ($read.Found) {
        return (& $result 'Pass' ('T5''s container {0} is there, with its {1} RU/s.' -f $names.ContainerName, $names.Throughput))
    }
    if (-not $read.NotFound) {
        $evidence['action'] = 'unread'
        return (& $result 'Fail' ('T5''s container {0} couldn''t be read, so it wasn''t created: {1}' -f $names.ContainerName, $read.Error) 'Run the same command again in a few minutes.' $docs['createContainer'])
    }
    if (-not $PSCmdlet.ShouldProcess(('{0}/{1}' -f $names.AccountName, $path), ('Create T5''s container with {0} RU/s' -f $names.Throughput))) {
        $evidence['action'] = 'whatif'
        return (& $result 'Not selected' ('What if: T5''s container {0} would be created, with {1} RU/s.' -f $names.ContainerName, $names.Throughput))
    }
    $groupTag = $null
    try {
        $groupTag = Get-DemoResourceGroupTag -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName $names.ResourceGroup
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The demo resource group''s tags weren''t read for T5''s container: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    $url = 'https://management.azure.com{0}/{1}?api-version={2}' -f $names.AccountId, $path, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DocumentDB/databaseAccounts')
    $body = Get-DemoT5ContainerBody -GroupTag $groupTag
    $evidence['action'] = 'create'
    $limit = $WaitMinutes * 60
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $attempts = 0
    $accepted = $false
    $errorText = ''
    while ($true) {
        $attempts++
        $put = Invoke-DemoActivityControlArm -SubscriptionId ([string]$Config['subscriptionId']) -Method put -Url $url -Body $body
        if ($put.Ok) {
            $accepted = $true
            break
        }
        $errorText = [string]$put.Error
        # Azure refuses the name while the last container with it is still being deleted.
        $conflict = $errorText -match '(?i)\b(409|412)\b|Conflict|PreconditionFailed|being deleted|in progress|another operation'
        if (-not $conflict -or ($watch.Elapsed.TotalSeconds + $PollSeconds) -gt $limit) {
            break
        }
        Write-DemoLog -Message ('T5: Azure doesn''t take the container {0} yet ({1}); trying again in {2} seconds.' -f $names.ContainerName, $errorText, $PollSeconds)
        Start-Sleep -Seconds $PollSeconds
    }
    $evidence['attempts'] = $attempts
    $fix = 'Run ./scripts/start-demo.ps1 again. If it keeps failing, run ./scripts/deploy.ps1, whose template creates the container.'
    if (-not $accepted) {
        $evidence['seconds'] = [int][System.Math]::Round($watch.Elapsed.TotalSeconds)
        return (& $result 'Fail' ('T5''s container {0} couldn''t be created, so T5''s activity can''t start: {1}' -f $names.ContainerName, $errorText) $fix $docs['createContainer'])
    }
    $waited = Wait-DemoT5Container -Config $Config -AccountId $names.AccountId -Present -TimeoutSeconds ([int][System.Math]::Max(30, $limit - $watch.Elapsed.TotalSeconds)) -PollSeconds $PollSeconds
    $seconds = [int][System.Math]::Round($watch.Elapsed.TotalSeconds)
    $evidence['seconds'] = $seconds
    if (-not $waited.Reached) {
        return (& $result 'Fail' ('T5''s container {0} was requested, but Azure didn''t show it within {1} minutes{2}.' -f $names.ContainerName, $WaitMinutes, $(if ($waited.Error) { ': ' + $waited.Error } else { '' })) $fix $docs['createContainer'])
    }
    return (& $result 'Pass' ('T5''s container {0} wasn''t there, so it was created, with {1} RU/s, in {2} seconds.' -f $names.ContainerName, $names.Throughput, $seconds) '' $docs['createContainer'])
}

function Remove-DemoT5Container {
    <#
    .SYNOPSIS
    Deletes T5's container through Azure Resource Manager (2026-11-19, ADR 0027), so its provisioned throughput stops
    billing until a session creates it again; the account and the database stay, with the private endpoint and the DNS zone
    when it has them.
    Returns Outcome (Deleted, Missing, Failed, or WhatIf), Seconds, and Error. It doesn't check the lifecycle:
    Invoke-DemoT5ContainerStop does. Internal.
    Source: https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/delete-sql-container
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        # Get-DemoT5Name's result.
        [Parameter(Mandatory)]
        [object] $Names,

        [ValidateRange(0, 30)]
        [int] $WaitMinutes = 5,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 10
    )

    $path = Get-DemoT5ContainerPath
    if (-not $PSCmdlet.ShouldProcess(('{0}/{1}' -f $Names.AccountName, $path), 'Delete T5''s container')) {
        return [pscustomobject]@{ Outcome = 'WhatIf'; Seconds = 0; Error = '' }
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    # Read first: Azure can answer a delete of a container that isn't there with success, so only a read tells "already
    # gone" from "deleted now".
    $before = Get-DemoT5Resource -Config $Config -AccountId $Names.AccountId -Child $path
    if (-not $before.Found -and $before.NotFound) {
        return [pscustomobject]@{ Outcome = 'Missing'; Seconds = [int][System.Math]::Round($watch.Elapsed.TotalSeconds); Error = '' }
    }
    $url = 'https://management.azure.com{0}/{1}?api-version={2}' -f $Names.AccountId, $path, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DocumentDB/databaseAccounts')
    $delete = Invoke-DemoActivityControlArm -SubscriptionId ([string]$Config['subscriptionId']) -Method delete -Url $url
    if (-not $delete.Ok) {
        $outcome = if ($delete.Missing) { 'Missing' } else { 'Failed' }
        return [pscustomobject]@{ Outcome = $outcome; Seconds = [int][System.Math]::Round($watch.Elapsed.TotalSeconds); Error = $(if ($delete.Missing) { '' } else { [string]$delete.Error }) }
    }
    if ($WaitMinutes -le 0) {
        return [pscustomobject]@{ Outcome = 'Deleted'; Seconds = [int][System.Math]::Round($watch.Elapsed.TotalSeconds); Error = '' }
    }
    $waited = Wait-DemoT5Container -Config $Config -AccountId $Names.AccountId -TimeoutSeconds ($WaitMinutes * 60) -PollSeconds $PollSeconds
    if ($waited.Reached) {
        return [pscustomobject]@{ Outcome = 'Deleted'; Seconds = [int][System.Math]::Round($watch.Elapsed.TotalSeconds); Error = '' }
    }
    return [pscustomobject]@{ Outcome = 'Failed'; Seconds = [int][System.Math]::Round($watch.Elapsed.TotalSeconds); Error = ('it was still there {0} minutes after its deletion was accepted{1}' -f $WaitMinutes, $(if ($waited.Error) { ' (' + $waited.Error + ')' } else { '' })) }
}

function Test-DemoT5SafetyStopDelete {
    <#
    .SYNOPSIS
    Whether the nightly safety stop deletes T5's container between sessions (review of ab91ee5): it's in place
    (Get-DemoSafetyStopState: its schedule linked, its role assigned at the demo resource group), and its custom role has the
    container's read and delete. With the session control holding no role, it's the only automatic stop that deletes the
    container. Never throws: what can't be read is $false. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    try {
        $state = Get-DemoSafetyStopState -Config $Config
        if ([string](Get-DemoMemberValue -InputObject $state -Name 'State') -ne 'InPlace') {
            return $false
        }
        $role = Get-DemoSafetyStopRoleState -SubscriptionId ([string]$Config['subscriptionId'])
        if ($role.Error -or -not $role.Id) {
            return $false
        }
        return @($script:T5SafetyStopContainerActions | Where-Object { $_ -notin @($role.Actions) }).Count -eq 0
    }
    catch {
        Write-DemoLog -Level Debug -Message ('Whether the nightly safety stop deletes T5''s container wasn''t read: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        return $false
    }
}
function Get-DemoT5ControlRoleState {
    <#
    .SYNOPSIS
    What the session control can do with T5's container (2026-11-19, ADR 0027), read once: Mode, Why, RoleName, and the
    facts behind them (RoleExists, Lacking, IdentityExists, HoldsRole, HoldsOther). Internal.

    .DESCRIPTION
    Mode:
    - Control: its custom role has the container's actions ($script:T5ContainerControlActions), and its identity holds it at
      the demo resource group, so Run all creates the container at a session's start.
    - NoRole: its identity holds no role at the demo resource group (or doesn't exist yet), so Run all can't start a session
      at all, and only start-demo.ps1 and demo-control.ps1 do, which create the container with the person's own rights (the
      coordinator's fix 1, 2026-11-19).
    - Lacking: its identity holds its role, which doesn't have the container's actions (an earlier grant, and a deployer who
      can't write the role), or holds another role there: Run all could start a session that couldn't create the container.
    - Unknown: the role or the assignments couldn't be read.
    Reads: the role definitions, the identity, and its role assignments at the demo resource group (at, above, or below).
    https://learn.microsoft.com/rest/api/authorization/role-assignments/list-for-scope
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $name = Get-DemoActivityControlName -Config $Config
    $answer = [ordered]@{ Mode = 'Unknown'; Why = ''; RoleName = $name.RoleName; RoleExists = $false; Lacking = @($script:T5ContainerControlActions); IdentityExists = $false; HoldsRole = $false; HoldsOther = $false }
    try {
        $role = Get-DemoActivityControlRoleId -SubscriptionId $name.SubscriptionId -RoleName $name.RoleName -WithActions
        $answer.RoleExists = [bool]$role.Id
        $answer.Lacking = @(if ($role.Id) { $script:T5ContainerControlActions | Where-Object { $_ -notin @($role.Actions) } } else { $script:T5ContainerControlActions })
        $principalId = Get-DemoActivityControlPrincipalId -Name $name
        $answer.IdentityExists = [bool]$principalId
        if ($principalId) {
            $held = Test-DemoActivityControlAssignment -SubscriptionId $name.SubscriptionId -Scope $name.DemoResourceGroupId -PrincipalId $principalId -RoleId ([string]$role.Id)
            if ([string]$held.Error -and -not [bool]$held.Missing) {
                $answer.Why = 'the session control''s role assignments couldn''t be read: {0}' -f $held.Error
                return [pscustomobject]$answer
            }
            $answer.HoldsRole = [bool]$held.Exists
            $answer.HoldsOther = [bool](Get-DemoMemberValue -InputObject $held -Name 'Other')
        }
    }
    catch {
        $answer.Why = 'the session control''s role couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message)
        return [pscustomobject]$answer
    }
    if ($answer.HoldsRole -and $answer.Lacking.Count -eq 0) {
        $answer.Mode = 'Control'
    }
    elseif ($answer.HoldsRole) {
        $answer.Mode = 'Lacking'
        $answer.Why = 'the session control''s custom role "{0}" doesn''t have {1} yet' -f $name.RoleName, ($answer.Lacking -join ', ')
    }
    elseif ($answer.HoldsOther) {
        $answer.Mode = 'Lacking'
        $answer.Why = 'the session control''s identity {0} holds another role at {1}, not "{2}"' -f $name.Identity, $name.DemoResourceGroup, $name.RoleName
    }
    else {
        $answer.Mode = 'NoRole'
        $answer.Why = if (-not $answer.IdentityExists) { 'the session control''s identity {0} doesn''t exist yet' -f $name.Identity } else { '{0} holds no role at {1} yet' -f $name.Identity, $name.DemoResourceGroup }
    }
    return [pscustomobject]$answer
}

function Resolve-DemoT5ContainerLifecycle {
    <#
    .SYNOPSIS
    Whether T5's container can exist only during a session (2026-11-19, ADR 0027), recorded on the demo resource group's
    DbHubT5Container tag when it changes. Returns Lifecycle (Session or AlwaysOn), Recorded (the tag before), Changed,
    Known, and Why (what keeps it AlwaysOn). Internal.

    .DESCRIPTION
    A stop deletes the container only when a session can't run without it (the owner's condition, 2026-11-19): the
    session control can create it at a session's start (Get-DemoT5ControlRoleState's Control: its custom role has the
    container's actions, and its identity holds it at the demo resource group), or it has no role there at all (NoRole,
    the coordinator's fix 1, 2026-11-19): Run all can't start a session then, and start-demo.ps1 and demo-control.ps1 create
    the container with the person's own rights. A control that holds a role without the container's actions (Lacking)
    keeps the container between sessions. -Purpose says what may change the tag:
    - Deploy (deploy.ps1, right after the session control's setup, which updates the role for an Owner and publishes the
      runbooks that create the container): Session for Control or NoRole, AlwaysOn otherwise.
    - Grant (grant-safety-stop.ps1, after an Owner's grants): AlwaysOn becomes Session when the control can now; an
      environment without the tag (deployed before 2026-11-19, whose runbooks can't create the container) keeps none,
      because deploy.ps1 sets it up.
    - Stop (stop-demo.ps1, before it deletes the container): Session becomes AlwaysOn when the control holds a role that
      can't any more (a shared role that another deployment changed back, for example); nothing becomes Session.
    When the role can't be read, the recorded value stands. -WhatIf reads, and records nothing. Mode says which case.
    AutoDelete says whether something automatic deletes the container after a session (the session control's role, or, with
    no role, the nightly safety stop: Test-DemoT5SafetyStopDelete; review of ab91ee5), and Price how the estimate prices it:
    Session only when the lifecycle is Session and AutoDelete is true, AlwaysOn otherwise.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('Deploy', 'Grant', 'Stop')]
        [string] $Purpose = 'Deploy',

        # Get-DemoDeploymentState's result; read when it isn't given.
        [AllowNull()]
        [object] $State = $null
    )

    if ($null -eq $State) {
        $State = Get-DemoDeploymentState -Config $Config
    }
    $recorded = [string](Get-DemoMemberValue -InputObject $State -Name 'T5Container')
    $control = Get-DemoT5ControlRoleState -Config $Config
    $known = $control.Mode -ne 'Unknown'
    $able = $control.Mode -in 'Control', 'NoRole'
    $why = [string]$control.Why
    $session = $script:T5LifecycleSession
    $alwaysOn = $script:T5LifecycleAlwaysOn
    $lifecycle = switch ($Purpose) {
        'Deploy' { if (-not $known) { if ($recorded -ceq $session) { $session } else { $alwaysOn } } elseif ($able) { $session } else { $alwaysOn } }
        'Grant' { if ($known -and $able -and $recorded -ceq $alwaysOn) { $session } elseif ($known -and -not $able -and $recorded -ceq $session) { $alwaysOn } else { $recorded } }
        default { if ($known -and -not $able -and $recorded -ceq $session) { $alwaysOn } else { $recorded } }
    }
    # Whether something automatic deletes the container after a session (review of ab91ee5): the session control's role, or,
    # while it holds no role, the nightly safety stop. Without either, the tag stays Session, so stop-demo.ps1 still deletes
    # it, but it's priced all month (Price) and reported as a Warning.
    $autoDelete = switch ($control.Mode) {
        'Control' { $true }
        'NoRole' { [bool](Test-DemoT5SafetyStopDelete -Config $Config) }
        default { -not $known }
    }
    $changed = $lifecycle -cne $recorded
    if ($changed -and $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), ('Record T5''s container lifecycle: {0}' -f $lifecycle))) {
        try {
            Set-DemoDeploymentStateLocked -Config $Config -Value @{ T5Container = $lifecycle } -Confirm:$false
        }
        catch {
            Write-DemoLog -Level Warning -Message ('T5''s container lifecycle ({0}) wasn''t recorded on the resource group: {1}' -f $lifecycle, (Protect-DemoText -Text $_.Exception.Message))
            $why = ('{0}{1}it wasn''t recorded on the resource group' -f $why, $(if ($why) { '; ' } else { '' }))
            $lifecycle = $recorded
            $changed = $false
        }
    }
    $price = if ($lifecycle -ceq $session -and $autoDelete) { $session } else { $alwaysOn }
    return [pscustomobject]@{ Lifecycle = $lifecycle; Recorded = $recorded; Changed = $changed; Known = $known; Why = $why; RoleName = $control.RoleName; Mode = $control.Mode; AutoDelete = [bool]$autoDelete; Price = $price }
}

function Get-DemoT5LifecycleText {
    <#
    .SYNOPSIS
    What T5's container lifecycle (Resolve-DemoT5ContainerLifecycle) means, for a result: Status, Text (a sentence that
    starts with "T5's container"), and Fix. Session is a Pass; AlwaysOn a Warning with the grant command, and none (an
    environment deployed before 2026-11-19) a Warning with deploy.ps1, both a Pass on the free tier, where an always-on
    container costs nothing. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Lifecycle,

        [bool] $FreeTier = $false,

        [string] $ConfigPath = ''
    )

    $ru = [int](Get-DemoCosmosSetting)['throughputRUs']
    $value = [string]$Lifecycle.Lifecycle
    if ($value -ceq $script:T5LifecycleSession -and [string](Get-DemoMemberValue -InputObject $Lifecycle -Name 'Mode') -eq 'NoRole') {
        # The coordinator's fix 1 (2026-11-19): with no role, Run all can't start a session, and the person's own scripts
        # create and delete the container. Review of ab91ee5: only while the nightly safety stop deletes it too is that a
        # Pass; otherwise only stop-demo.ps1 deletes it, and the estimate prices it all month.
        $grant = Get-DemoActivityControlGrantCommand -ConfigPath $ConfigPath
        $auto = Get-DemoMemberValue -InputObject $Lifecycle -Name 'AutoDelete'
        if ($null -eq $auto -or [bool]$auto) {
            $text = 'T5''s container exists only during a session{0}: start-demo.ps1 creates it with your own rights, and stop-demo.ps1 and the nightly safety stop delete it, so its {1} RU/s bill only while the demo runs. The session control has no role yet ({2}), so Run all can''t start a session; once an Owner runs, once, {3}, Run all creates the container at each session''s start too.' -f $(if ($Lifecycle.Changed) { ' from now on' } else { '' }), $ru, $Lifecycle.Why, $grant
            return [pscustomobject]@{ Status = 'Pass'; Text = $text; Fix = '' }
        }
        $billing = if ($FreeTier) { 'which costs nothing on the free tier' } else { 'so its {0} RU/s bill around the clock until the next stop-demo.ps1, and the estimate prices them all month' -f $ru }
        $text = 'T5''s container is deleted only when you run ./scripts/stop-demo.ps1: the session control has no role yet ({0}), and the nightly safety stop can''t delete it (its role isn''t assigned here, or doesn''t have the container''s actions), so a session that ends any other way, such as the VMs'' nightly auto-shutdown, leaves it there, {1}. start-demo.ps1 creates it with your own rights, and Run all can''t start a session yet.' -f $Lifecycle.Why, $billing
        if ($FreeTier) {
            return [pscustomobject]@{ Status = 'Pass'; Text = $text; Fix = '' }
        }
        return [pscustomobject]@{ Status = 'Warning'; Text = $text; Fix = ('Run ./scripts/stop-demo.ps1 after each session. Or an Owner runs, once: {0}; from then on Run all, the session''s end, and the nightly safety stop delete it too.' -f $grant) }
    }
    if ($value -ceq $script:T5LifecycleSession) {
        $text = 'T5''s container exists only during a session{0}: start-demo.ps1 and Run all create it, and stop-demo.ps1, the session''s end, and the nightly safety stop delete it, so its {1} RU/s bill only while the demo runs. The session control''s role ("{2}") can create it again, and the account and its database stay, with its private endpoint and DNS zone when it has them, so Database Hub keeps T5 in its estate.' -f $(if ($Lifecycle.Changed) { ' from now on' } else { '' }), $ru, $Lifecycle.RoleName
        return [pscustomobject]@{ Status = 'Pass'; Text = $text; Fix = '' }
    }
    $cost = if ($FreeTier) { 'which costs nothing on the free tier' } else { 'so its {0} RU/s bill around the clock (estimate-cost.ps1 prices them)' -f $ru }
    if ($value -ceq $script:T5LifecycleAlwaysOn) {
        $text = 'T5''s container stays between sessions, {0}: a stop deletes it only when Run all can create it again, and {1}.' -f $cost, $(if ($Lifecycle.Why) { $Lifecycle.Why } else { 'the session control''s role can''t yet' })
        $fix = 'Run ./scripts/deploy.ps1 as an Owner of the subscription, or an Owner runs, once: {0}. From then on the container exists only during a session.' -f (Get-DemoActivityControlGrantCommand -ConfigPath $ConfigPath)
    }
    else {
        $text = 'T5''s container stays between sessions, {0}: this environment was deployed before 2026-11-19, when the container started to exist only during a session, so nothing deletes it yet.' -f $cost
        $fix = 'Run ./scripts/deploy.ps1: it sets the container''s lifecycle up, with nothing else to do.'
    }
    if ($FreeTier) {
        return [pscustomobject]@{ Status = 'Pass'; Text = $text; Fix = '' }
    }
    return [pscustomobject]@{ Status = 'Warning'; Text = $text; Fix = $fix }
}

function Get-DemoT5LifecycleResult {
    # -CheckId's result for T5's container lifecycle (Get-DemoT5LifecycleText): DEPLOY.T5.LIFECYCLE and the grant's. Pure.
    # Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Lifecycle,

        [ValidatePattern('^[A-Z][A-Z0-9_.]+$')]
        [string] $CheckId = 'DEPLOY.T5.LIFECYCLE',

        [bool] $FreeTier = $false,

        [string] $ConfigPath = ''
    )

    $said = Get-DemoT5LifecycleText -Lifecycle $Lifecycle -FreeTier $FreeTier -ConfigPath $ConfigPath
    $evidence = [ordered]@{ lifecycle = [string]$Lifecycle.Lifecycle; recorded = [string]$Lifecycle.Recorded; changed = [bool]$Lifecycle.Changed; known = [bool]$Lifecycle.Known; mode = [string](Get-DemoMemberValue -InputObject $Lifecycle -Name 'Mode'); autoDelete = Get-DemoMemberValue -InputObject $Lifecycle -Name 'AutoDelete'; price = [string](Get-DemoMemberValue -InputObject $Lifecycle -Name 'Price'); role = [string]$Lifecycle.RoleName; freeTier = $FreeTier }
    return (New-DemoResult -CheckId $CheckId -Area 't5' -Target 'T5' -Status $said.Status -Message $said.Text -Evidence $evidence -Remediation $said.Fix -DocUrl ([string](Get-DemoCosmosSetting)['docUrls']['provisionThroughput']))
}

function Invoke-DemoT5LifecycleRecheck {
    <#
    .SYNOPSIS
    DEPLOY.T5.LIFECYCLE once more at a deploy.ps1 run's end (2026-11-19, F14), when its first check didn't see the session
    control's role that this run's grant reports in place. Returns the new result, or $null when it isn't checked again.
    Internal.

    .DESCRIPTION
    The run checks T5's container lifecycle right after the session control's Azure part (Update-DemoT5ContainerLifecycle),
    whose last step grants the control's roles, and a role assignment that was just created can be missing from a read for
    a while. So on a new environment the status page's T5.Lifecycle row said the session control had no role yet and Run all
    couldn't start a session, while the Control row said Run all was ready (live, 2026-11-19, two new environments). Once
    the control is done, when this run's CONTROL.ROLE.A1 is a Pass (the role is assigned at the demo resource group) and the
    first check found no role (NoRole), couldn't read it (Unknown, or no mode), or found it without the container's actions
    although this run's CONTROL.ROLE.DEFINITION is a Pass (Lacking), it checks again with Update-DemoT5ContainerLifecycle,
    which rewrites the row, and the new result replaces the first in -Results, so the console, the status page, and DONE
    say what holds at the run's end. A first check that found the role (Control), T5 off, or a run that couldn't grant the
    role (a Contributor's) isn't checked again. deploy.ps1 calls it at a full run's end, and after -StopAfter Infrastructure's
    wait for the policy inventory. While the new check still contradicts the grant (the review of f213a47: a run that ends
    soon after the grant, such as -Sequential -StopAfter Infrastructure, or a slow replication), it reads again up to
    -Retries more times, -RetrySeconds apart: at most a minute by default.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        # The run's results, changed in place: the new DEPLOY.T5.LIFECYCLE replaces the first.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]] $Results,

        [ValidateRange(0, 10)]
        [int] $Retries = 3,

        [ValidateRange(0, 300)]
        [int] $RetrySeconds = 20
    )

    $index = -1
    for ($i = $Results.Count - 1; $i -ge 0; $i--) {
        if ($null -ne $Results[$i] -and [string](Get-DemoMemberValue -InputObject $Results[$i] -Name 'checkId') -eq 'DEPLOY.T5.LIFECYCLE') {
            $index = $i
            break
        }
    }
    if ($index -lt 0) {
        return $null
    }
    $first = $Results[$index]
    $modeOf = { param([object] $Answer) [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Answer -Name 'evidence') -Name 'mode') }
    $mode = & $modeOf $first
    if ([string]$first.status -eq 'Not selected') {
        return $null
    }
    $last = { param([string] $CheckId) @($Results | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq $CheckId }) | Select-Object -Last 1 }
    $assigned = & $last 'CONTROL.ROLE.A1'
    if ($null -eq $assigned -or [string]$assigned.status -ne 'Pass') {
        return $null
    }
    $definition = & $last 'CONTROL.ROLE.DEFINITION'
    $defined = $null -ne $definition -and [string]$definition.status -eq 'Pass'
    # What contradicts this run's grant: the role not seen (NoRole), not read (Unknown, or no mode), or seen without the
    # container's actions although this run wrote them (Lacking).
    $missed = { param([string] $Seen) $Seen -in 'NoRole', 'Unknown', '' -or ($Seen -eq 'Lacking' -and $defined) }
    if (-not (& $missed $mode)) {
        return $null
    }
    $prior = @(for ($i = 0; $i -lt $Results.Count; $i++) { if ($i -ne $index) { $Results[$i] } })
    $again = $null
    $reads = 0
    while ($true) {
        $answer = @(Update-DemoT5ContainerLifecycle -Config $Config -ConfigPath $ConfigPath -ProgressPath $ProgressPath -PriorResult $prior -Confirm:$false) | Select-Object -Last 1
        if ($null -eq $answer) {
            break
        }
        $again = $answer
        $reads++
        if (-not (& $missed (& $modeOf $answer)) -or $reads -gt $Retries) {
            break
        }
        Write-DemoLog -Message ('The session control''s role doesn''t show in T5''s check yet ({0}); reading it again in {1} seconds ({2} of {3}).' -f $(if (& $modeOf $answer) { & $modeOf $answer } else { 'unread' }), $RetrySeconds, $reads, $Retries)
        Start-Sleep -Seconds $RetrySeconds
    }
    if ($null -eq $again) {
        return $null
    }
    $evidence = Get-DemoMemberValue -InputObject $again -Name 'evidence'
    if ($evidence -is [System.Collections.IDictionary]) {
        $evidence['checkedAgain'] = $true
        $evidence['firstMode'] = $mode
        $evidence['reads'] = $reads
    }
    $Results[$index] = $again
    if ([string](Get-DemoMemberValue -InputObject $evidence -Name 'mode') -ne $mode -or [string]$again.status -ne [string]$first.status) {
        Write-DemoLog -Message ('T5''s container lifecycle, checked again at the run''s end, once the session control''s role showed: {0}' -f [string]$again.message)
    }
    return $again
}

function Invoke-DemoT5ContainerStop {
    <#
    .SYNOPSIS
    STOP.T5 (2026-11-19, ADR 0027): after a session, deletes T5's container when its lifecycle is Session (checked again
    first: Resolve-DemoT5ContainerLifecycle -Purpose Stop), so its provisioned throughput stops billing until the next
    session creates it again; otherwise keeps it, and says why and what bills. Not selected when T5 isn't deployed; never
    a Fail. Internal.

    .DESCRIPTION
    An Azure Cosmos DB account has no stop or pause, and a container's throughput can't be taken away, only deleted with
    it. The account, its database (no throughput of its own), its private endpoint and DNS zone when it has them (2026-11-21),
    and T1's data-plane role (scoped to the account) stay, so Database Hub keeps T5 in its estate, and its Azure Monitor
    metrics stay readable.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        # Get-DemoT5State's result.
        [AllowNull()]
        [object] $State = $null,

        # Get-DemoDeploymentState's result; read when it isn't given.
        [AllowNull()]
        [object] $DeploymentState = $null,

        [string] $ConfigPath = '',

        [ValidateRange(0, 30)]
        [int] $WaitMinutes = 5,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 10
    )

    $cosmos = Get-DemoCosmosSetting
    $ru = [int]$cosmos['throughputRUs']
    if ($null -eq $State -or -not [bool](Get-DemoMemberValue -InputObject $State -Name 'Exists')) {
        return (New-DemoResult -CheckId 'STOP.T5' -Area 't5' -Target 'T5' -Status 'Not selected' -Message 'T5 (Azure Cosmos DB) isn''t deployed, so nothing of it bills.' -DocUrl ([string]$cosmos['docUrls']['hubMonitor']))
    }
    $names = Get-DemoMemberValue -InputObject $State -Name 'Names'
    $free = [bool](Get-DemoMemberValue -InputObject $State -Name 'FreeTier')
    $lifecycle = Resolve-DemoT5ContainerLifecycle -Config $Config -Purpose Stop -State $DeploymentState -WhatIf:$WhatIfPreference
    $evidence = [ordered]@{ account = [string]$names.AccountName; container = [string]$names.ContainerName; lifecycle = [string]$lifecycle.Lifecycle; freeTier = $free; throughputRUs = $ru }
    # 2026-11-21 (ADR 0027): an account with public network access on (T1's subnet rule) has no private endpoint, so then
    # nothing of T5 bills between sessions.
    $publicAccess = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $State -Name 'Account') -Name 'properties') -Name 'publicNetworkAccess')
    $stays = if ($publicAccess -ieq 'Enabled') { 'nothing of T5 bills between sessions: it has no private endpoint (DEPLOY.T5.NETWORK)' } else { 'only its private endpoint and private DNS zone bill between sessions (estimate-cost.ps1 prices them)' }
    if ([string]$lifecycle.Lifecycle -cne $script:T5LifecycleSession) {
        $said = Get-DemoT5LifecycleText -Lifecycle $lifecycle -FreeTier $free -ConfigPath $ConfigPath
        $evidence['outcome'] = 'Kept'
        $message = 'T5''s activity is off, and its container {0} was kept: {1}' -f $names.ContainerName, ($said.Text -replace '^T5''s container ', 'it ')
        return (New-DemoResult -CheckId 'STOP.T5' -Area 't5' -Target 'T5' -Status $said.Status -Message $message -Evidence $evidence -Remediation $said.Fix -DocUrl ([string]$cosmos['docUrls']['provisionThroughput']))
    }
    $removed = Remove-DemoT5Container -Config $Config -Names $names -WaitMinutes $WaitMinutes -PollSeconds $PollSeconds
    $evidence['outcome'] = [string]$removed.Outcome
    $evidence['seconds'] = [int]$removed.Seconds
    $doc = [string]$cosmos['docUrls']['deleteContainer']
    switch ([string]$removed.Outcome) {
        'Deleted' {
            return (New-DemoResult -CheckId 'STOP.T5' -Area 't5' -Target 'T5' -Status 'Pass' -Message ('T5''s container {0} was deleted ({1} seconds), so its {2} RU/s stop billing until the next session creates it again (start-demo.ps1 or Run all). The account stays, so Database Hub keeps T5 in its estate, and {3}.' -f $names.ContainerName, $removed.Seconds, $ru, $stays) -Evidence $evidence -DocUrl $doc)
        }
        'Missing' {
            return (New-DemoResult -CheckId 'STOP.T5' -Area 't5' -Target 'T5' -Status 'Pass' -Message ('T5''s container {0} isn''t there (an earlier stop deleted it), so {1}.' -f $names.ContainerName, $stays) -Evidence $evidence -DocUrl $doc)
        }
        'WhatIf' {
            return (New-DemoResult -CheckId 'STOP.T5' -Area 't5' -Target 'T5' -Status 'Not selected' -Message ('What if: T5''s container {0} would be deleted; the next session creates it again.' -f $names.ContainerName) -Evidence $evidence -DocUrl $doc)
        }
        default {
            return (New-DemoResult -CheckId 'STOP.T5' -Area 't5' -Target 'T5' -Status 'Warning' -Message ('T5''s container {0} wasn''t deleted: {1}. Its {2} RU/s keep billing until it is.' -f $names.ContainerName, $removed.Error, $ru) -Evidence $evidence -Remediation 'Run ./scripts/stop-demo.ps1 again; the nightly safety stop deletes it tonight too.' -DocUrl $doc)
        }
    }
}

function Get-DemoT5Access {
    <#
    .SYNOPSIS
    Whether T1's managed identity has the Cosmos DB Built-in Data Contributor data-plane role on T5's account. Returns Found,
    Read, Assignment, and Error. Internal.

    .DESCRIPTION
    Lists the account's sqlRoleAssignments (Sql Resources - List Sql Role Assignments) and looks for -PrincipalId with the
    built-in role's definition ID, scoped to the account. A read.
    Source: https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/list-sql-role-assignments
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $AccountId,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $PrincipalId
    )

    $roleId = [string](Get-DemoCosmosSetting)['dataContributorRoleDefinitionId']
    $read = Get-DemoT5Resource -Config $Config -AccountId $AccountId -Child 'sqlRoleAssignments'
    if (-not $read.Found) {
        return [pscustomobject]@{ Found = $false; Read = $false; Assignment = $null; Error = $read.Error }
    }
    $match = foreach ($entry in (Get-DemoMemberList -InputObject $read.Value -Name 'value')) {
        $properties = Get-DemoMemberValue -InputObject $entry -Name 'properties'
        $definition = [string](Get-DemoMemberValue -InputObject $properties -Name 'roleDefinitionId')
        $principal = [string](Get-DemoMemberValue -InputObject $properties -Name 'principalId')
        $scope = [string](Get-DemoMemberValue -InputObject $properties -Name 'scope')
        if ($PrincipalId -and $principal -ieq $PrincipalId -and $definition -match ('/sqlRoleDefinitions/{0}$' -f [regex]::Escape($roleId)) -and $scope -ieq $AccountId) {
            $entry
        }
    }
    $first = @($match) | Select-Object -First 1
    return [pscustomobject]@{ Found = ($null -ne $first); Read = $true; Assignment = $first; Error = '' }
}

function Get-DemoT5MetricSnapshot {
    <#
    .SYNOPSIS
    T5's Azure Monitor metrics over the last -Minutes at a one-minute grain: the peak and latest normalized RU consumption,
    the requests, the throttled (429) requests, and the request units. Internal.

    .DESCRIPTION
    Four reads of the documented Metrics - List REST API (az rest --method get), as Get-DemoT4MetricSnapshot makes them: the
    query parameters go in a file (--url-parameters @<path>), because an encoded query string has '%', which cmd.exe can't
    pass to az.cmd. NormalizedRUConsumption (Maximum), TotalRequestUnits (Total), TotalRequests (Count), and TotalRequests
    filtered to StatusCode 429 (Count), the signals Database Hub's Cosmos DB views chart. Returns Succeeded, Error,
    PeakNormalizedRu, LatestNormalizedRu, Requests, Throttled, RequestUnits, LatestUtc, ThrottledLastUtc, and Minutes.
    Sources: https://learn.microsoft.com/rest/api/monitor/metrics/list,
    https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-documentdb-databaseaccounts-metrics,
    https://learn.microsoft.com/fabric/database/hub/monitor-cosmos-db
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $AccountId,

        [ValidateRange(5, 1440)]
        [int] $Minutes = 15,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $end = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)
    $timespan = '{0}/{1}' -f $end.AddMinutes(-$Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant), $end.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    $apiVersion = Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Insights/metrics'
    $reads = @(
        @{ Key = 'NormalizedRu'; Name = 'NormalizedRUConsumption'; Aggregation = 'Maximum'; Filter = '' }
        @{ Key = 'RequestUnits'; Name = 'TotalRequestUnits'; Aggregation = 'Total'; Filter = '' }
        @{ Key = 'Requests'; Name = 'TotalRequests'; Aggregation = 'Count'; Filter = '' }
        @{ Key = 'Throttled'; Name = 'TotalRequests'; Aggregation = 'Count'; Filter = "StatusCode eq '429'" }
    )
    $series = @{}
    $errors = [System.Collections.Generic.List[string]]::new()
    $url = 'https://management.azure.com{0}/providers/Microsoft.Insights/metrics' -f $AccountId
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-t5metrics'
    try {
        $index = 0
        foreach ($read in $reads) {
            $index++
            $parameters = [ordered]@{ timespan = $timespan; interval = 'PT1M'; metricnames = $read.Name; aggregation = $read.Aggregation; 'api-version' = $apiVersion }
            if ($read.Filter) {
                $parameters['$filter'] = $read.Filter
            }
            $path = Write-DemoPrivateFile -Directory $directory -Name ('metrics-{0}.json' -f $index) -Content ($parameters | ConvertTo-Json -Compress)
            $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'get', '--url', $url, '--url-parameters', "@$path", '--output', 'json') -AllowFailure
            if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
                $errors.Add((Protect-DemoText -Text ([string]$result.StdErr).Trim()))
                continue
            }
            $body = [string]$result.StdOut | ConvertFrom-Json -Depth 32
            $field = $read.Aggregation.ToLowerInvariant()
            $points = [System.Collections.Generic.List[object]]::new()
            foreach ($metric in (Get-DemoMemberList -InputObject $body -Name 'value')) {
                foreach ($timeseries in (Get-DemoMemberList -InputObject $metric -Name 'timeseries')) {
                    foreach ($point in (Get-DemoMemberList -InputObject $timeseries -Name 'data')) {
                        $value = Get-DemoMemberValue -InputObject $point -Name $field
                        if ($null -ne $value) {
                            $points.Add([pscustomobject]@{ Utc = (ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $point -Name 'timeStamp')); Value = [double]$value })
                        }
                    }
                }
            }
            $series[$read.Key] = $points.ToArray()
        }
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    # No Measure-Object here: with -Property it writes nothing for an empty series, such as the 429 filter's when nothing was
    # throttled, and .Sum of nothing throws under strict mode (live, 2026-11-18, deploy.ps1's METRICS.T5).
    $sum = {
        param([string] $Key)
        if (-not $series.Contains($Key)) {
            return $null
        }
        $total = 0.0
        foreach ($point in @($series[$Key])) {
            $total += [double]$point.Value
        }
        return $total
    }
    $normalized = if ($series.Contains('NormalizedRu')) { @($series['NormalizedRu'] | Sort-Object -Property Utc) } else { @() }
    $peak = $null
    foreach ($point in $normalized) {
        if ($null -eq $peak -or [double]$point.Value -gt $peak) {
            $peak = [double]$point.Value
        }
    }
    $newest = @(foreach ($key in $series.Keys) { $series[$key] | Where-Object { $null -ne $_.Utc } | ForEach-Object { $_.Utc } }) | Sort-Object -Descending | Select-Object -First 1
    $lastThrottled = if ($series.Contains('Throttled')) { @($series['Throttled'] | Where-Object { $_.Value -gt 0 -and $null -ne $_.Utc } | Sort-Object -Property Utc -Descending) | Select-Object -First 1 } else { $null }
    [pscustomobject]@{
        Succeeded          = ($errors.Count -lt $reads.Count)
        Error              = ($errors | Select-Object -First 1)
        PeakNormalizedRu   = $peak
        LatestNormalizedRu = $(if ($normalized.Count -gt 0) { [double]$normalized[-1].Value } else { $null })
        Requests           = (& $sum 'Requests')
        Throttled          = (& $sum 'Throttled')
        RequestUnits       = (& $sum 'RequestUnits')
        LatestUtc          = $(if ($null -ne $newest) { ([datetime]$newest).ToString('o', $invariant) } else { '' })
        ThrottledLastUtc   = $(if ($null -ne $lastThrottled) { ([datetime]$lastThrottled.Utc).ToString('o', $invariant) } else { '' })
        Minutes            = $Minutes
    }
}

function Test-DemoT5MetricFlow {
    <#
    .SYNOPSIS
    METRICS.T5: whether Azure Monitor has T5's request and normalized RU metrics from the last -Minutes, with the values as
    evidence. With -WaitMinutes, reads again every minute until they arrive. Internal.

    .DESCRIPTION
    Database Hub's Cosmos DB views chart these Azure Monitor platform metrics, which every account sends with no setup
    (https://learn.microsoft.com/fabric/database/hub/monitor-cosmos-db, checked 2026-11-18). An account sends request
    metrics only while something sends it requests: the runner's activity on T1 does, so an account without requests yet
    is a Warning.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $AccountId,

        [ValidateRange(5, 1440)]
        [int] $Minutes = 15,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 0
    )

    $docUrl = [string](Get-DemoCosmosSetting)['docUrls']['hubMonitor']
    if (-not $AccountId) {
        return (New-DemoResult -CheckId 'METRICS.T5' -Area 'hub' -Target 'T5' -Status 'Warning' -Message 'T5''s account isn''t known (the resource group has no deploymentId tag), so its metrics weren''t read.' -Remediation 'Deploy it with scripts/deploy.ps1.' -DocUrl $docUrl)
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    $failedReads = 0
    while ($true) {
        $snapshot = Get-DemoT5MetricSnapshot -Config $Config -AccountId $AccountId -Minutes $Minutes
        $flowing = $snapshot.Succeeded -and $null -ne $snapshot.Requests -and $snapshot.Requests -gt 0 -and $null -ne $snapshot.PeakNormalizedRu
        # A read that fails three times in a row won't be fixed by waiting longer: its Fail says why.
        $failedReads = if ($snapshot.Succeeded) { 0 } else { $failedReads + 1 }
        if ($flowing -or $failedReads -ge 3 -or [DateTime]::UtcNow -ge $deadline) {
            break
        }
        Start-Sleep -Seconds 60
    }
    $evidence = [ordered]@{ latestUtc = $snapshot.LatestUtc; minutes = $Minutes; peakNormalizedRuPercent = $snapshot.PeakNormalizedRu; latestNormalizedRuPercent = $snapshot.LatestNormalizedRu; requests = $snapshot.Requests; throttled = $snapshot.Throttled; requestUnits = $snapshot.RequestUnits; throttledLastUtc = $snapshot.ThrottledLastUtc }
    if (-not $snapshot.Succeeded) {
        return (New-DemoResult -CheckId 'METRICS.T5' -Area 'hub' -Target 'T5' -Status 'Fail' -Message ('Azure Monitor''s metrics for T5 couldn''t be read: {0}' -f $snapshot.Error) -Evidence $evidence -Remediation 'Check that you can read the resource group (Reader or higher) and run again.' -DocUrl 'https://learn.microsoft.com/rest/api/monitor/metrics/list')
    }
    if ($flowing) {
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $throttledText = if ($snapshot.Throttled -gt 0) { [string]::Format($culture, ', {0:N0} of them throttled (429)', $snapshot.Throttled) } else { ', none throttled' }
        return (New-DemoResult -CheckId 'METRICS.T5' -Area 'hub' -Target 'T5' -Status 'Pass' -Message ([string]::Format($culture, 'Azure Monitor has T5''s metrics from the last {0} minutes ({1:N0} requests{2}; normalized RU consumption peaked at {3:N0}%), which Database Hub''s Cosmos DB views chart.', $Minutes, $snapshot.Requests, $throttledText, $snapshot.PeakNormalizedRu)) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId 'METRICS.T5' -Area 'hub' -Target 'T5' -Status 'Warning' -Message ('Azure Monitor has no request metrics for T5 from the last {0} minutes yet: an account sends them while something sends it requests, which the runner''s activity on T1 does.' -f $Minutes) -Evidence $evidence -Remediation 'Check that T5 has an activity profile (./scripts/status.ps1 -Detail), then run validate.ps1 -Area T5 again in a few minutes.' -DocUrl $docUrl)
}

function Format-DemoT5MetricText {
    # One line for status.ps1 from a T5 metric snapshot: requests, throttled requests, request units, and normalized RU. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Snapshot
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Snapshot.Requests -and $null -eq $Snapshot.PeakNormalizedRu) {
        return 'no Azure Monitor metrics in the last {0} minutes yet' -f $Snapshot.Minutes
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Snapshot.Requests) {
        $parts.Add([string]::Format($culture, '{0:N0} request(s)', $Snapshot.Requests))
    }
    if ($null -ne $Snapshot.Throttled) {
        $parts.Add([string]::Format($culture, '{0:N0} throttled (429)', $Snapshot.Throttled))
    }
    if ($null -ne $Snapshot.RequestUnits) {
        $parts.Add([string]::Format($culture, '{0:N0} RU', $Snapshot.RequestUnits))
    }
    if ($null -ne $Snapshot.PeakNormalizedRu) {
        $parts.Add([string]::Format($culture, 'normalized RU peak {0:N0}%, latest {1:N0}%', $Snapshot.PeakNormalizedRu, $Snapshot.LatestNormalizedRu))
    }
    return ('{0} in the last {1} minutes' -f ($parts -join ', '), $Snapshot.Minutes)
}

function Invoke-DemoT5WarmUp {
    <#
    .SYNOPSIS
    WORKLOAD.T5.WARMUP: whether T1's managed identity reads and writes T5 with its data-plane role: the runner's warmup on
    sqlvm01 (a token, a read of the container, and an upsert and a point read of one document), tried again while the
    role assignment comes into effect or the account's private DNS name starts to resolve. Internal.

    .DESCRIPTION
    The template assigns T1's identity the Cosmos DB Built-in Data Contributor role (infra/modules/cosmos01-access.bicep),
    and a new assignment can take a few minutes before the data plane honours it; a new private endpoint's DNS record
    too. So a refusal (401 or 403), a name that doesn't resolve, a time-out, or a retryable status (408, 429, 449, 503) is
    tried again every -RetrySeconds until -WaitMinutes pass; anything else is the answer. Each attempt is one action Run
    Command on sqlvm01 (Invoke-DemoWorkloadCommand), so it never runs beside another one there. -ServiceEndpoint
    (2026-11-21): T5 is reached through T1's subnet's service endpoint and its virtual network rule (T5.NETWORK's path),
    which Learn says can take up to 15 minutes to come into effect, with a 403 meanwhile, so the wait is 20 minutes at least.
    Sources: https://learn.microsoft.com/azure/cosmos-db/nosql/troubleshoot-unauthorized,
    https://learn.microsoft.com/rest/api/cosmos-db/http-status-codes-for-cosmosdb,
    https://learn.microsoft.com/azure/cosmos-db/how-to-configure-vnet-service-endpoint
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(0, 60)]
        [int] $WaitMinutes = 10,

        [ValidateRange(5, 300)]
        [int] $RetrySeconds = 45,

        [switch] $ServiceEndpoint
    )

    $cosmos = Get-DemoCosmosSetting
    $docUrl = [string]$cosmos['docUrls']['dataPlaneRbac']
    if ($ServiceEndpoint) {
        $WaitMinutes = [System.Math]::Max($WaitMinutes, 20)
    }
    $path = if ($ServiceEndpoint) { 'through T1''s subnet''s service endpoint' } else { 'through the private endpoint' }
    $deadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    $attempts = 0
    $run = $null
    $text = ''
    while ($true) {
        $attempts++
        try {
            $run = Invoke-DemoWorkloadCommand -Config $Config -Target 'T5' -ArgumentList @('warmup', '--json') -TimeoutSeconds 300 -Confirm:$false
            $text = '{0} {1}' -f [string]$run.Result.message, [string]$run.StdErr
        }
        catch {
            $run = $null
            $text = Protect-DemoText -Text $_.Exception.Message
        }
        if ($null -ne $run -and $run.Status -in 'Pass', 'Warning') {
            break
        }
        $transient = $text -match '(?i)\b(401|403|408|429|449|503)\b|Forbidden|Unauthorized|data-plane role|role assignment|no such host is known|could not be resolved|name or service not known|timed out|did not finish within'
        if (-not $transient -or [DateTime]::UtcNow.AddSeconds($RetrySeconds) -ge $deadline) {
            break
        }
        Write-DemoLog -Message ('T5: T1 can''t reach the Cosmos DB account yet (attempt {0}); trying again in {1} seconds, for at most {2} minutes, while its data-plane role and {3} come into effect.' -f $attempts, $RetrySeconds, $WaitMinutes, $(if ($ServiceEndpoint) { 'T1''s subnet''s service endpoint' } else { 'private DNS name' }))
        Start-Sleep -Seconds $RetrySeconds
    }
    $record = if ($null -ne $run) { @($run.Records) | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -like 'WORKLOAD.T5.WARMUP*' } | Select-Object -Last 1 } else { $null }
    $evidence = [ordered]@{ attempts = $attempts; waitMinutes = $WaitMinutes; exitCode = $(if ($null -ne $run) { $run.ExitCode } else { $null }) }
    if ($null -ne $run -and $run.Status -in 'Pass', 'Warning') {
        $said = [string](Get-DemoMemberValue -InputObject $record -Name 'message')
        $message = 'T1''s managed identity reads and writes T5 with its data-plane role (Cosmos DB Built-in Data Contributor), {0}{1}.{2}' -f $path, $(if ($attempts -gt 1) { ' after {0} attempts' -f $attempts } else { '' }), $(if ($said) { ' Runner: ' + $said } else { '' })
        return (New-DemoResult -CheckId 'WORKLOAD.T5.WARMUP' -Area 'workload' -Target 'T5' -Status $run.Status -Message $message -Evidence $evidence -DocUrl $docUrl)
    }
    $why = (ConvertTo-DemoPlainText -Value $text).Trim()
    if ($why.Length -gt 600) {
        $why = '...' + $why.Substring($why.Length - 600)
    }
    $remediation = if ($ServiceEndpoint) {
        'Run ./scripts/deploy.ps1 again: the template assigns T1''s identity the data-plane role, and a new assignment, or T1''s subnet''s new service endpoint, can take up to 15 minutes. If it keeps failing, check that ./scripts/validate.ps1 -Area T5 passes T5.NETWORK (T5''s virtual network rule allows snet-sqlvm) and T5.ACCESS.'
    }
    else {
        'Run ./scripts/deploy.ps1 again: the template assigns T1''s identity the data-plane role, and a new assignment can take a few minutes. If it keeps failing, check that sqlvm01 resolves the account''s documents host to the private endpoint (privatelink.documents.azure.com) and that ./scripts/validate.ps1 -Area T5 passes T5.ACCESS.'
    }
    return (New-DemoResult -CheckId 'WORKLOAD.T5.WARMUP' -Area 'workload' -Target 'T5' -Status 'Fail' -Message ('T1 couldn''t read and write T5 with its managed identity ({0} attempt(s)): {1}' -f $attempts, $(if ($why) { $why } else { 'the runner gave no reason' })) -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
}
