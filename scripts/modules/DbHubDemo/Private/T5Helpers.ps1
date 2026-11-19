# T5 (2026-11-18, ADR 0027): the Azure Cosmos DB for NoSQL account cosmos01-<deploymentId>. Its names, its reads through the
# documented REST APIs, the subscription's free tier, its Azure Monitor metrics, and the DEPLOY.T5 lines of deploy.ps1.

# The account's provisioning states while it's there (Database Accounts - Get, provisioningState): Succeeded once created,
# Updating while a change applies, Creating while Azure creates it. Deleting means it isn't T5 any more.
# https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/database-accounts/get (checked 2026-11-18)
$script:T5DeployedStates = @('Succeeded', 'Updating', 'Creating')

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
        return (& $make $false 'Pass' ('T5 ({0}) exists without the free tier, which Azure sets only when an account is created, so it keeps that: its {1} RU/s are billed every hour (estimate-cost.ps1 prices them).' -f $accountName, $cosmos['throughputRUs']) 'Existing')
    }
    if (-not (Test-DemoT5FreeTierWanted -Config $Config)) {
        return (& $make $false 'Pass' 't5UseFreeTier is false in the configuration, so T5 is created without the free tier: its throughput is billed every hour (estimate-cost.ps1 prices it).' 'Configured')
    }
    $quotaId = Get-DemoSubscriptionQuotaId -Config $Config
    if (-not (Test-DemoT5FreeTierOffered -QuotaId $quotaId)) {
        return (& $make $false 'Warning' ('Azure Cosmos DB''s free tier isn''t offered to this subscription (an internal subscription, {0}: Azure refuses it there), so T5 is created without it: its {1} RU/s are billed every hour (estimate-cost.ps1 prices them).' -f $quotaId, $cosmos['throughputRUs']) 'Offer' '' 'Nothing to do. In a subscription that isn''t internal, T5 gets the free tier when it''s created there and no other account has it.')
    }
    $holders = Get-DemoT5FreeTierHolder -Config $Config
    if (-not $holders.Succeeded) {
        return (& $make $false 'Warning' ('Azure Resource Graph couldn''t be read to find whether another account has the subscription''s free tier ({0}), so T5 is created without it: its throughput is billed every hour.' -f $holders.Error) 'Unread' '' 'Nothing to do. The free tier can only be set when an account is created.')
    }
    $other = @($holders.Accounts | Where-Object { $_.Name -ine $accountName }) | Select-Object -First 1
    if ($null -ne $other) {
        $holder = '{0} (resource group {1})' -f $other.Name, $other.ResourceGroup
        return (& $make $false 'Warning' ('The subscription''s one free-tier Azure Cosmos DB account is {0}, so T5 is created without it: its throughput is billed every hour (estimate-cost.ps1 prices it).' -f $holder) 'Holder' $holder 'Nothing to do. To have T5 use the free tier, delete that account before T5 is created; once created, T5 keeps what it has.')
    }
    return (& $make $true 'Pass' ('No account in the subscription has the free tier, so T5 is created with it: the first {0} RU/s and {1} GB are free, which covers T5''s {2} RU/s.' -f $cosmos['freeTierRUs'], $cosmos['freeTierStorageGB'], $cosmos['throughputRUs']) 'Free')
}

function Test-DemoT5FreeTierRefusal {
    <#
    .SYNOPSIS
    True when a failed deployment's error says Azure refused T5's free tier: the subscription's offer doesn't include it
    ("Free tier is not supported for Internal subscriptions", live 2026-11-18), or another account took it meanwhile.
    Internal.

    .DESCRIPTION
    Microsoft Learn lists no error code for it, so the match needs an error that names the free tier, as
    Resolve-DemoT3FreeOfferError does for T3's free offer.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Text = ''
    )

    return ($Text -match '(?i)free[ -]?tier')
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

function New-DemoT5OffResult {
    # DEPLOY.T5.OFF: the configuration turns T5 off (t5Enabled false), so this run neither creates nor checks it, and an
    # existing account stays as it is; $null when T5 is on. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if (Test-DemoT5Enabled -Config $Config) {
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

function Get-DemoT5StopResult {
    <#
    .SYNOPSIS
    STOP.T5 (2026-11-18, ADR 0027): an Azure Cosmos DB account has no stop or pause, so stop-demo.ps1 turns its activity off
    and says what bills on between sessions: its provisioned throughput (nothing on the free tier), its storage, and its
    private endpoint and DNS zone. Not supported, never a Fail; Not selected when the account doesn't exist. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $State = $null
    )

    $cosmos = Get-DemoCosmosSetting
    if ($null -eq $State -or -not [bool](Get-DemoMemberValue -InputObject $State -Name 'Exists')) {
        return (New-DemoResult -CheckId 'STOP.T5' -Area 't5' -Target 'T5' -Status 'Not selected' -Message 'T5 (Azure Cosmos DB) isn''t deployed, so nothing of it bills.' -DocUrl ([string]$cosmos['docUrls']['hubMonitor']))
    }
    $names = Get-DemoMemberValue -InputObject $State -Name 'Names'
    $free = [bool](Get-DemoMemberValue -InputObject $State -Name 'FreeTier')
    $throughputText = if ($free) { 'its {0} RU/s of throughput cost nothing on the free tier' -f $cosmos['throughputRUs'] } else { 'its {0} RU/s of throughput bill every hour' -f $cosmos['throughputRUs'] }
    $message = 'T5 ({0}) has no stop: an Azure Cosmos DB account can''t be stopped or paused. Its activity is off and nothing sends it requests, but {1}, and its storage, private endpoint, and private DNS zone bill too (estimate-cost.ps1 prices them). destroy.ps1 deletes it with the resource group.' -f [string](Get-DemoMemberValue -InputObject $names -Name 'AccountName'), $throughputText
    return (New-DemoResult -CheckId 'STOP.T5' -Area 't5' -Target 'T5' -Status 'Not supported' -Message $message -Evidence ([ordered]@{ account = [string](Get-DemoMemberValue -InputObject $names -Name 'AccountName'); freeTier = $free; throughputRUs = [int]$cosmos['throughputRUs'] }) -DocUrl ([string]$cosmos['docUrls']['pricing']))
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
    $sum = { param([string] $Key) if ($series.Contains($Key)) { [double](@($series[$Key] | Measure-Object -Property Value -Sum).Sum) } else { $null } }
    $normalized = if ($series.Contains('NormalizedRu')) { @($series['NormalizedRu'] | Sort-Object -Property Utc) } else { @() }
    $newest = @(foreach ($key in $series.Keys) { $series[$key] | Where-Object { $null -ne $_.Utc } | ForEach-Object { $_.Utc } }) | Sort-Object -Descending | Select-Object -First 1
    $lastThrottled = if ($series.Contains('Throttled')) { @($series['Throttled'] | Where-Object { $_.Value -gt 0 -and $null -ne $_.Utc } | Sort-Object -Property Utc -Descending) | Select-Object -First 1 } else { $null }
    [pscustomobject]@{
        Succeeded          = ($errors.Count -lt $reads.Count)
        Error              = ($errors | Select-Object -First 1)
        PeakNormalizedRu   = $(if ($normalized.Count -gt 0) { [double](@($normalized | Measure-Object -Property Value -Maximum).Maximum) } else { $null })
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
    Command on sqlvm01 (Invoke-DemoWorkloadCommand), so it never runs beside another one there.
    Sources: https://learn.microsoft.com/azure/cosmos-db/nosql/troubleshoot-unauthorized,
    https://learn.microsoft.com/rest/api/cosmos-db/http-status-codes-for-cosmosdb
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(0, 60)]
        [int] $WaitMinutes = 10,

        [ValidateRange(5, 300)]
        [int] $RetrySeconds = 45
    )

    $cosmos = Get-DemoCosmosSetting
    $docUrl = [string]$cosmos['docUrls']['dataPlaneRbac']
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
        Write-DemoLog -Message ('T5: T1 can''t reach the Cosmos DB account yet (attempt {0}); trying again in {1} seconds, for at most {2} minutes, while its data-plane role and private DNS name come into effect.' -f $attempts, $RetrySeconds, $WaitMinutes)
        Start-Sleep -Seconds $RetrySeconds
    }
    $record = if ($null -ne $run) { @($run.Records) | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -like 'WORKLOAD.T5.WARMUP*' } | Select-Object -Last 1 } else { $null }
    $evidence = [ordered]@{ attempts = $attempts; waitMinutes = $WaitMinutes; exitCode = $(if ($null -ne $run) { $run.ExitCode } else { $null }) }
    if ($null -ne $run -and $run.Status -in 'Pass', 'Warning') {
        $said = [string](Get-DemoMemberValue -InputObject $record -Name 'message')
        $message = 'T1''s managed identity reads and writes T5 with its data-plane role (Cosmos DB Built-in Data Contributor), through the private endpoint{0}.{1}' -f $(if ($attempts -gt 1) { ' after {0} attempts' -f $attempts } else { '' }), $(if ($said) { ' Runner: ' + $said } else { '' })
        return (New-DemoResult -CheckId 'WORKLOAD.T5.WARMUP' -Area 'workload' -Target 'T5' -Status $run.Status -Message $message -Evidence $evidence -DocUrl $docUrl)
    }
    $why = (ConvertTo-DemoPlainText -Value $text).Trim()
    if ($why.Length -gt 600) {
        $why = '...' + $why.Substring($why.Length - 600)
    }
    $remediation = 'Run ./scripts/deploy.ps1 again: the template assigns T1''s identity the data-plane role, and a new assignment can take a few minutes. If it keeps failing, check that sqlvm01 resolves the account''s documents host to the private endpoint (privatelink.documents.azure.com) and that ./scripts/validate.ps1 -Area T5 passes T5.ACCESS.'
    return (New-DemoResult -CheckId 'WORKLOAD.T5.WARMUP' -Area 'workload' -Target 'T5' -Status 'Fail' -Message ('T1 couldn''t read and write T5 with its managed identity ({0} attempt(s)): {1}' -f $attempts, $(if ($why) { $why } else { 'the runner gave no reason' })) -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
}
