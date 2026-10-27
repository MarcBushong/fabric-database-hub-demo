function Test-DemoT4Enabled {
    # True unless the configuration turns T4 off (t4Enabled false; Phase 24, ADR 0019). Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    return -not ($Config.Contains('t4Enabled') -and $null -ne $Config['t4Enabled'] -and -not [bool]$Config['t4Enabled'])
}

function Get-DemoPostgresSetting {
    # config/versions.json's postgresql block: T4's pinned major version, names, runner role, and metric lists. Internal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    return $versions['postgresql']
}

function Get-DemoT4SkuName {
    <#
    T4's compute size: the t4SkuName setting, or the profile's size (Standard_B1ms) when it isn't set. Standard_B2s
    is the documented fallback when Azure answers SkuNotAvailable for B1ms, and Standard_D2ds_v5 the documented
    General Purpose option the owner chose on 2026-10-26 after both were refused; nothing changes it on its own
    (Phase 24, ADR 0019). Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ($Config.Contains('t4SkuName') -and $Config['t4SkuName']) {
        return [string]$Config['t4SkuName']
    }
    $catalog = Get-DemoProfile
    $profileName = if ($Config['profile']) { [string]$Config['profile'] } else { 'lowest-cost' }
    return [string]$catalog.profiles[$profileName].t4.skuName
}

function Get-DemoT4SkuSpec {
    <#
    A documented T4 size's tier, vCores, and Retail Prices meter. The tier follows the size, as in
    infra/modules/demo.bicep: Standard_B sizes are Burstable (one meter per server-hour), and Standard_D<n>ds_v5 is
    General Purpose (a vCore-hour meter times its vCores). Internal.
    Source: https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-compute
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SkuName
    )

    if ($SkuName -match '^Standard_B') {
        return [pscustomobject]@{ SkuName = $SkuName; Tier = 'Burstable'; VCores = $(if ($SkuName -eq 'Standard_B1ms') { 1 } else { 2 }); Product = 'Azure Database for PostgreSQL Flexible Server Burstable BS Series Compute'; Meter = ($SkuName -replace '^Standard_', '').ToUpperInvariant(); PerVCore = $false }
    }
    if ($SkuName -match '^Standard_D(\d+)ds_v5$') {
        return [pscustomobject]@{ SkuName = $SkuName; Tier = 'GeneralPurpose'; VCores = [int]$Matches[1]; Product = 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'; Meter = 'vCore'; PerVCore = $true }
    }
    throw ('{0} isn''t a documented T4 size (Standard_B1ms, Standard_B2s, or Standard_D2ds_v5).' -f $SkuName)
}

function Select-DemoT4ComputePrice {
    # T4's compute meter among Retail Prices items: the size's own meter for Burstable, the vCore meter for General Purpose. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Item = @(),

        [Parameter(Mandatory)]
        [pscustomobject] $Spec
    )

    $hourly = @($Item | Where-Object { $_.unitOfMeasure -eq '1 Hour' })
    if ($Spec.PerVCore) {
        return ($hourly | Where-Object { [string]$_.meterName -eq 'vCore' } | Sort-Object -Property retailPrice | Select-Object -First 1)
    }
    return ($hourly | Where-Object { ([string]$_.skuName).ToUpperInvariant() -eq $Spec.Meter } | Select-Object -First 1)
}

function Get-DemoT4HourlyPrice {
    <#
    T4's compute list price per hour at its configured size, in USD, from the Azure Retail Prices API at run time
    (ADR 0016: no hard-coded prices), or $null when it can't be read. Never throws. Internal.
    https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[double]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    try {
        $spec = Get-DemoT4SkuSpec -SkuName (Get-DemoT4SkuName -Config $Config)
        $items = @(Get-DemoRetailPrice -Filter ("serviceName eq 'Azure Database for PostgreSQL' and armRegionName eq '{0}' and productName eq '{1}' and priceType eq 'Consumption'" -f [string]$Config['location'], $spec.Product) -CurrencyCode 'USD')
        $item = Select-DemoT4ComputePrice -Item $items -Spec $spec
        if ($null -eq $item) {
            return $null
        }
        return [double]$item.retailPrice * $(if ($spec.PerVCore) { $spec.VCores } else { 1 })
    }
    catch {
        Write-DemoLog -Level Warning -Message ('T4''s hourly price couldn''t be read from the Retail Prices API: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-DemoT4AvailabilityZone {
    # The zone T4 is created in (t4AvailabilityZone): empty for no preference, or 1, 2, or 3. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ($Config.Contains('t4AvailabilityZone') -and $null -ne $Config['t4AvailabilityZone']) {
        return [string]$Config['t4AvailabilityZone']
    }
    return ''
}

function Get-DemoT4CreateFailure {
    <#
    .SYNOPSIS
    T4's last refused creation: the resource group's pgflex01 deployment (the template's T4 module) when it
    failed with SkuNotAvailable. Returns Sku, Zone, and TimeUtc, or $null. A read. Internal.

    .DESCRIPTION
    Azure answers SkuNotAvailable ("Specified SKU is not supported in this region") when a size isn't offered
    in the region or is temporarily unavailable there, even when the Location Based Capabilities API lists it
    (live, 2026-10-26). Learn's remedy is another size; this demo's documented fallback is Standard_B2s
    (t4SkuName), which nothing sets on its own. Deploy and preflight use this to report it.
    Sources: https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors,
    https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-show,
    https://learn.microsoft.com/cli/azure/deployment/operation/group#az-deployment-operation-group-list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'group', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', 'pgflex01', '--output', 'json') -AllowFailure
    if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
        return $null
    }
    $deployment = [string]$read.StdOut | ConvertFrom-Json -Depth 64
    $properties = Get-DemoMemberValue -InputObject $deployment -Name 'properties'
    if ([string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState') -ne 'Failed') {
        return $null
    }
    # The deployment's own error stops at ResourceDeploymentFailure; the refusal's code is in the server's
    # operation (live, 2026-10-26), so the operations are read too (Deployment Operations - List).
    $errorText = ConvertTo-Json -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'error') -Depth 64 -Compress
    $operations = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'operation', 'group', 'list', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', 'pgflex01', '--output', 'json') -AllowFailure
    if ($operations.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$operations.StdOut)) {
        foreach ($operation in @([string]$operations.StdOut | ConvertFrom-Json -Depth 64)) {
            $operationProperties = Get-DemoMemberValue -InputObject $operation -Name 'properties'
            if ([string](Get-DemoMemberValue -InputObject $operationProperties -Name 'provisioningState') -eq 'Failed') {
                $errorText += ConvertTo-Json -InputObject (Get-DemoMemberValue -InputObject $operationProperties -Name 'statusMessage') -Depth 64 -Compress
            }
        }
    }
    if ($errorText -notmatch 'SkuNotAvailable') {
        return $null
    }
    $parameters = Get-DemoMemberValue -InputObject $properties -Name 'parameters'
    $sizing = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $parameters -Name 'sizing') -Name 'value'
    # ConvertFrom-Json turns the ISO timestamp into a DateTime; it's reported in UTC, culture-independent.
    $stamp = Get-DemoMemberValue -InputObject $properties -Name 'timestamp'
    $timeUtc = if ($stamp -is [datetime]) { $stamp.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$stamp }
    [pscustomobject]@{
        Sku     = [string](Get-DemoMemberValue -InputObject $sizing -Name 'skuName')
        Zone    = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $parameters -Name 'availabilityZone') -Name 'value')
        TimeUtc = $timeUtc
    }
}

function New-DemoT4SkuFailureResult {
    <#
    The Fail (or, for a first try in another zone, Warning) for a T4 size Azure refused with SkuNotAvailable: its
    remediation names the documented fallback, Standard_B2s, and never changes the size itself. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $CheckId,

        [Parameter(Mandatory)]
        [pscustomobject] $Failure,

        [ValidateSet('Fail', 'Warning')]
        [string] $Status = 'Fail',

        [string] $NextZone = ''
    )

    $where = if ($Failure.Zone) { 'zone {0}' -f $Failure.Zone } else { 'no zone preference' }
    $evidence = [ordered]@{ refusedSku = $Failure.Sku; refusedZone = $Failure.Zone; refusedUtc = $Failure.TimeUtc; fallbackSku = 'Standard_B2s' }
    $remediation = 'Set t4SkuName to Standard_B2s, the documented fallback (2 vCores, 4 GiB; about four times the hourly list price of B1ms, which estimate-cost.ps1 prices at run time), and run deploy.ps1 again; or keep the size and try once more with t4AvailabilityZone set to another zone the region lists. Nothing changes the size on its own.'
    if ($Failure.Sku -eq 'Standard_B2s') {
        # Live, 2026-10-26: West US 3 refused the fallback too; the owner then chose the General Purpose option.
        $remediation = 'Standard_B2s is already the documented Burstable fallback. Ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors), try once more with t4AvailabilityZone set to a zone the region lists, set t4SkuName to Standard_D2ds_v5, the documented General Purpose option (2 vCores, 8 GiB; a much higher hourly price and 7-day restart worst case, which estimate-cost.ps1 prices at run time), or set t4Enabled to false until Azure accepts the size. Nothing changes the size on its own.'
    }
    elseif ($Failure.Sku -match '^Standard_D') {
        $remediation = 'The demo documents no further size. Ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors), and set t4Enabled to false until Azure accepts a size. Nothing changes the size on its own.'
    }
    $docUrl = 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors'
    if ($Status -eq 'Warning') {
        $message = 'Azure refused T4''s size {0} with {1} at {2} (SkuNotAvailable: not supported in the region, or temporarily unavailable). This run tries {0} once more in zone {3}; if Azure refuses it again, the deployment reports a Fail.' -f $Failure.Sku, $where, $Failure.TimeUtc, $NextZone
        return (New-DemoResult -CheckId $CheckId -Area 't4' -Target 'T4' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
    }
    $message = 'Azure refused to create T4 at size {0} with {1} at {2}: SkuNotAvailable ("Specified SKU is not supported in this region"), although the region''s capability list includes it, so the size is unavailable there for now.' -f $Failure.Sku, $where, $Failure.TimeUtc
    return (New-DemoResult -CheckId $CheckId -Area 't4' -Target 'T4' -Status 'Fail' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
}

function Get-DemoT4Name {
    <#
    .SYNOPSIS
    Returns T4's names: resource group, the flexible server pgflex01-<deploymentId>, its resource ID and FQDN,
    the database, the runner's role, and T1. Internal.

    .DESCRIPTION
    The server's name is stable across stops and redeployments (infra/modules/demo.bicep). The deploymentId
    comes from -DeploymentId or the resource group's deploymentId tag (Get-DemoT3Name); with -NoLookup nothing
    is read, and ServerName is empty when -DeploymentId wasn't given. Enabled is false when the configuration
    sets t4Enabled to false.
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
    $postgres = Get-DemoPostgresSetting
    $serverName = if ($t3.DeploymentId) { '{0}-{1}' -f $postgres['serverNamePrefix'], $t3.DeploymentId } else { '' }
    [pscustomobject]@{
        Enabled       = (Test-DemoT4Enabled -Config $Config)
        ResourceGroup = $t3.ResourceGroup
        DeploymentId  = $t3.DeploymentId
        ServerName    = $serverName
        ServerId      = if ($serverName) { '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{2}' -f $Config['subscriptionId'], $t3.ResourceGroup, $serverName } else { '' }
        Fqdn          = if ($serverName) { '{0}.postgres.database.azure.com' -f $serverName } else { '' }
        DatabaseName  = [string]$postgres['databaseName']
        RunnerRole    = [string]$postgres['runnerRole']
        MajorVersion  = [string]$postgres['majorVersion']
        T1VmName      = $t3.T1VmName
    }
}

function Get-DemoT4Resource {
    <#
    .SYNOPSIS
    Reads T4's server, or one of its child resources, through 'az rest --method get' with the pinned API
    version. Returns Found, NotFound, Value, and Error. Internal.

    .DESCRIPTION
    -Child is the path under the server, for example 'databases/contosocare', 'administrators', or
    'configurations/metrics.collector_database_activity'. A read: it works while the server is stopped.
    Source: https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/get
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ServerId,

        [ValidatePattern('^$|^[A-Za-z]+(/[A-Za-z0-9._-]+)?$')]
        [string] $Child = ''
    )

    $type = 'Microsoft.DBforPostgreSQL/flexibleServers'
    if ($Child) {
        $type = '{0}/{1}' -f $type, $Child.Split('/')[0]
    }
    $url = 'https://management.azure.com{0}{1}?api-version={2}' -f $ServerId, $(if ($Child) { '/' + $Child } else { '' }), (Get-DemoPinnedApiVersion -ResourceType $type)
    $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'get', '--url', $url, '--output', 'json') -AllowFailure
    if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
        return [pscustomobject]@{ Found = $true; NotFound = $false; Value = ([string]$result.StdOut | ConvertFrom-Json -Depth 32); Error = '' }
    }
    $errorText = Protect-DemoText -Text ([string]$result.StdErr).Trim()
    $missing = $errorText -match '(?i)ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound|\bNot ?Found\b|\(404\)'
    return [pscustomobject]@{ Found = $false; NotFound = $missing; Value = $null; Error = $errorText }
}

function Get-DemoT4State {
    <#
    .SYNOPSIS
    T4's server state (Ready, Stopped, Starting, Stopping, Updating, ...), or NotFound or Unknown, with the
    server's properties when it exists. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $DeploymentId = ''
    )

    $names = Get-DemoT4Name -Config $Config -DeploymentId $DeploymentId
    if (-not $names.ServerName) {
        return [pscustomobject]@{ Names = $names; Exists = $false; State = 'NotFound'; Server = $null; Error = 'The resource group has no deploymentId tag.' }
    }
    $read = Get-DemoT4Resource -Config $Config -ServerId $names.ServerId
    if ($read.Found) {
        $state = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $read.Value -Name 'properties') -Name 'state')
        return [pscustomobject]@{ Names = $names; Exists = $true; State = $(if ($state) { $state } else { 'Unknown' }); Server = $read.Value; Error = '' }
    }
    return [pscustomobject]@{ Names = $names; Exists = $false; State = $(if ($read.NotFound) { 'NotFound' } else { 'Unknown' }); Server = $null; Error = $read.Error }
}

function Wait-DemoT4State {
    # Polls T4's state until it's one of -State or -TimeoutMinutes pass; returns the last state read. Internal.
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
        $current = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
        if ($current.State -in $State -or [DateTime]::UtcNow -ge $deadline) {
            return $current
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Invoke-DemoT4PowerAction {
    <#
    .SYNOPSIS
    Starts or stops T4 with the documented REST operations (Servers - Start, Servers - Stop), unless it's
    already in that state, and with -WaitMinutes waits for Ready or Stopped. Returns <CheckPrefix>.T4.<ACTION>.
    Internal.

    .DESCRIPTION
    start-demo.ps1 starts T4 and stop-demo.ps1 stops it; deploy.ps1 starts a stopped T4 before the template,
    because a stopped flexible server rejects every other management operation. A stopped server starts on
    its own after seven days (Learn: Stop an Azure Database for PostgreSQL flexible server), so the stop
    result says when that happens. A missing server, or T4 turned off (t4Enabled false), is Not selected.
    -Requested says that the caller already sent this operation in an earlier call (-WaitMinutes 0), so a server
    that's in the wanted state by now "is now" running or stopped, not "was already" (Phase 25d).
    Sources: https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server,
    https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/start,
    https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/stop
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Callers confirm once for the whole start, stop, or deployment.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('Start', 'Stop')]
        [string] $Action,

        [ValidateRange(0, 60)]
        [int] $WaitMinutes = 0,

        [ValidateSet('DEPLOY', 'START', 'STOP')]
        [string] $CheckPrefix = 'START',

        [string] $DeploymentId = '',

        [switch] $Requested
    )

    $checkId = '{0}.T4.{1}' -f $CheckPrefix, $Action.ToUpperInvariant()
    $postgres = Get-DemoPostgresSetting
    $docUrl = [string]$postgres['docUrls']['stopServer']
    $names = Get-DemoT4Name -Config $Config -DeploymentId $DeploymentId
    if (-not $names.Enabled) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Not selected' -Message 'T4 is off in this configuration (t4Enabled is false).')
    }
    $current = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
    if (-not $current.Exists) {
        $status = if ($current.State -eq 'NotFound') { 'Not selected' } else { 'Warning' }
        $message = if ($current.State -eq 'NotFound') { 'T4 isn''t deployed, so there''s nothing to {0}.' -f $Action.ToLowerInvariant() } else { 'T4''s state couldn''t be read: {0}' -f $current.Error }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status $status -Message $message -Evidence @{ server = $names.ServerName } -DocUrl $docUrl)
    }

    $wanted = if ($Action -eq 'Start') { 'Ready' } else { 'Stopped' }
    $before = $current.State
    $evidence = [ordered]@{ server = $names.ServerName; stateBefore = $before }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    if ($before -ne $wanted) {
        # A server that's moving the other way finishes first; the operation is then sent once.
        $settling = if ($Action -eq 'Start') { 'Stopping' } else { 'Starting' }
        if ($before -eq $settling) {
            $current = Wait-DemoT4State -Config $Config -State @('Ready', 'Stopped') -TimeoutMinutes 15 -DeploymentId $DeploymentId
        }
        if ($current.State -ne $wanted -and $current.State -ne $(if ($Action -eq 'Start') { 'Starting' } else { 'Stopping' })) {
            $url = 'https://management.azure.com{0}/{1}?api-version={2}' -f $names.ServerId, $Action.ToLowerInvariant(), (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers')
            $post = Invoke-DemoAzWithConflictRetry -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('rest', '--method', 'post', '--url', $url) -Label ('T4 {0}: {1}' -f $names.ServerName, $Action.ToLowerInvariant()) -MaxConflictRetries 4
            if ($post.ExitCode -ne 0) {
                $evidence['error'] = Protect-DemoText -Text ([string]$post.StdErr).Trim()
                return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Fail' -Message ('T4 ({0}) couldn''t be {1}: {2}' -f $names.ServerName, $(if ($Action -eq 'Start') { 'started' } else { 'stopped' }), $evidence['error']) -Evidence $evidence -Remediation ('Run the script again in a few minutes; a server that''s updating rejects {0} until it finishes.' -f $Action.ToLowerInvariant()) -DocUrl $docUrl)
            }
        }
        if ($WaitMinutes -gt 0) {
            $current = Wait-DemoT4State -Config $Config -State @($wanted) -TimeoutMinutes $WaitMinutes -DeploymentId $DeploymentId
        }
        else {
            $current = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
        }
    }
    $evidence['stateAfter'] = $current.State
    $evidence['seconds'] = [int]$clock.Elapsed.TotalSeconds
    $autoStart = ''
    if ($Action -eq 'Stop') {
        $days = [int]$postgres['autoStartAfterStoppedDays']
        $evidence['autoStartsAfterDays'] = $days
        $autoStart = (' A stopped flexible server starts on its own after {0} days, so stop it again (stop-demo.ps1) within {0} days, or delete it, if the demo stays idle longer.' -f $days)
    }
    if ($current.State -eq $wanted) {
        $verb = if ($Action -eq 'Start') { 'running (Ready)' } else { 'stopped' }
        $how = if ($before -eq $wanted -and -not $Requested) { 'was already' } else { 'is now' }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4 ({0}) {1} {2}.{3}' -f $names.ServerName, $how, $verb, $autoStart) -Evidence $evidence -DocUrl $docUrl)
    }
    $pending = if ($Action -eq 'Start') { 'Starting' } else { 'Stopping' }
    if ($WaitMinutes -eq 0 -and $current.State -in @($pending, $before)) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4 ({0}) is {1}; the operation runs in the background.{2}' -f $names.ServerName, $pending.ToLowerInvariant(), $autoStart) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('T4 ({0}) is {1}, not {2}, after {3} minute(s).{4}' -f $names.ServerName, $current.State, $wanted, $WaitMinutes, $autoStart) -Evidence $evidence -Remediation 'Check it again with status.ps1 in a few minutes; a Burstable server that has used up its CPU credits can take longer to stop or start.' -DocUrl $docUrl)
}

function Get-DemoT4MetricSnapshot {
    <#
    .SYNOPSIS
    T4's latest Azure Monitor metrics at a one-minute grain over the last -Minutes: the metrics Database Hub's
    PostgreSQL dashboard charts, the Burstable CPU credits, and the enhanced metrics (sessions by state and by
    wait event type, the oldest transaction and query, deadlocks). Internal.

    .DESCRIPTION
    Four reads of the documented Metrics - List REST API (az rest --method get): the maximum-aggregated
    metrics, the summed ones, and the two split by a dimension. The query parameters go in a file
    (--url-parameters @<path>, which the Azure CLI encodes), because an encoded query string has '%', which
    cmd.exe can't pass to az.cmd (live, 2026-10-26). Returns Succeeded, Error, Latest (metric -> newest value),
    LatestUtc, ByState, and ByWaitEventType. Native metric queries are free up to a monthly allowance;
    status.ps1 and validate.ps1 make four per call.
    Sources: https://learn.microsoft.com/rest/api/monitor/metrics/list,
    https://learn.microsoft.com/cli/azure/reference-index#az-rest,
    https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-dbforpostgresql-flexibleservers-metrics
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ServerId,

        [ValidateRange(5, 1440)]
        [int] $Minutes = 15,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $end = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)
    $timespan = '{0}/{1}' -f $end.AddMinutes(-$Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant), $end.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    $apiVersion = Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Insights/metrics'
    $maximum = @('cpu_percent', 'memory_percent', 'storage_percent', 'iops', 'active_connections', 'cpu_credits_remaining', 'cpu_credits_consumed', 'disk_iops_consumed_percentage', 'longest_transaction_time_sec', 'longest_query_time_sec', 'oldest_backend_xmin_age')
    $total = @('connections_failed', 'deadlocks')
    $reads = @(
        @{ Names = $maximum; Aggregation = 'Maximum'; Filter = ''; Split = '' }
        @{ Names = $total; Aggregation = 'Total'; Filter = ''; Split = '' }
        @{ Names = @('sessions_by_state'); Aggregation = 'Maximum'; Filter = "State eq '*'"; Split = 'state' }
        @{ Names = @('sessions_by_wait_event_type'); Aggregation = 'Maximum'; Filter = "WaitEventType eq '*'"; Split = 'waiteventtype' }
    )
    $latest = [ordered]@{}
    $byState = [ordered]@{}
    $byWait = [ordered]@{}
    $newest = $null
    $errors = [System.Collections.Generic.List[string]]::new()
    $url = 'https://management.azure.com{0}/providers/Microsoft.Insights/metrics' -f $ServerId
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-t4metrics'
    try {
        $index = 0
        foreach ($read in $reads) {
            $index++
            $parameters = [ordered]@{ timespan = $timespan; interval = 'PT1M'; metricnames = ($read.Names -join ','); aggregation = $read.Aggregation; 'api-version' = $apiVersion }
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
            foreach ($metric in (Get-DemoMemberList -InputObject $body -Name 'value')) {
                $name = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $metric -Name 'name') -Name 'value')
                foreach ($series in (Get-DemoMemberList -InputObject $metric -Name 'timeseries')) {
                    $field = $read.Aggregation.ToLowerInvariant()
                    $data = Get-DemoMemberList -InputObject $series -Name 'data'
                    $point = $data | Where-Object { $null -ne (Get-DemoMemberValue -InputObject $_ -Name $field) } | Select-Object -Last 1
                    if ($null -eq $point) {
                        continue
                    }
                    $value = [double](Get-DemoMemberValue -InputObject $point -Name $field)
                    $stamp = ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $point -Name 'timeStamp')
                    if ($null -ne $stamp -and ($null -eq $newest -or $stamp -gt $newest)) {
                        $newest = $stamp
                    }
                    if ($read.Split) {
                        $dimensions = Get-DemoMemberList -InputObject $series -Name 'metadatavalues'
                        $dimension = $dimensions | Where-Object { ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'name') -Name 'value')).ToLowerInvariant() -eq $read.Split } | Select-Object -First 1
                        $key = [string](Get-DemoMemberValue -InputObject $dimension -Name 'value')
                        if (-not $key) {
                            $key = 'unknown'
                        }
                        if ($read.Split -eq 'state') {
                            $byState[$key] = $value
                        }
                        else {
                            $byWait[$key] = $value
                        }
                    }
                    else {
                        $latest[$name] = $value
                    }
                }
            }
        }
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    [pscustomobject]@{
        Succeeded       = ($errors.Count -lt $reads.Count)
        Error           = ($errors | Select-Object -First 1)
        Latest          = $latest
        LatestUtc       = $(if ($null -ne $newest) { $newest.ToString('o', $invariant) } else { '' })
        ByState         = $byState
        ByWaitEventType = $byWait
        Minutes         = $Minutes
    }
}

function Test-DemoT4MetricFlow {
    <#
    .SYNOPSIS
    METRICS.T4: whether Azure Monitor has T4's CPU and connection metrics from the last -Minutes, with the
    latest values (and the enhanced metrics) as evidence. With -WaitMinutes, reads again every minute until
    they arrive. Internal.

    .DESCRIPTION
    Database Hub's PostgreSQL monitoring charts these Azure Monitor metrics; it has no query-level
    diagnostics for PostgreSQL (https://learn.microsoft.com/fabric/database/hub/monitor-postgresql, checked
    2026-10-23). A server that isn't Ready sends no fresh metrics: Warning.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ServerId,

        [Parameter(Mandatory)]
        [string] $State,

        [ValidateRange(5, 1440)]
        [int] $Minutes = 15,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 0
    )

    $docUrl = [string](Get-DemoPostgresSetting)['docUrls']['hubMonitor']
    if (-not $ServerId) {
        return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Warning' -Message 'T4''s server isn''t known (the resource group has no deploymentId tag), so its metrics weren''t read.' -Remediation 'Deploy it with scripts/deploy.ps1.' -DocUrl $docUrl)
    }
    if ($State -ne 'Ready') {
        return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Warning' -Message ('T4 is {0}, so it sends no fresh metrics.' -f $State) -Evidence ([ordered]@{ state = $State }) -Remediation 'start-demo.ps1 starts it; metrics arrive within a few minutes.' -DocUrl $docUrl)
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    while ($true) {
        $snapshot = Get-DemoT4MetricSnapshot -Config $Config -ServerId $ServerId -Minutes $Minutes
        $evidence = [ordered]@{ latestUtc = $snapshot.LatestUtc; minutes = $Minutes; latest = $snapshot.Latest; sessionsByState = $snapshot.ByState; sessionsByWaitEventType = $snapshot.ByWaitEventType }
        $flowing = $snapshot.Succeeded -and $snapshot.Latest.Contains('cpu_percent') -and $snapshot.Latest.Contains('active_connections')
        if ($flowing -or [DateTime]::UtcNow -ge $deadline) {
            break
        }
        Start-Sleep -Seconds 60
    }
    if (-not $snapshot.Succeeded) {
        return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Fail' -Message ('Azure Monitor''s metrics for T4 couldn''t be read: {0}' -f $snapshot.Error) -Evidence $evidence -Remediation 'Check that you can read the resource group (Reader or higher) and run again.' -DocUrl 'https://learn.microsoft.com/rest/api/monitor/metrics/list')
    }
    if ($flowing) {
        $enhanced = if ($snapshot.ByState.Count -gt 0) { ', with the enhanced metrics' } else { '; the enhanced metrics have no data yet' }
        return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Pass' -Message ('Azure Monitor has T4''s metrics from the last {0} minutes (CPU {1:N0}%, {2:N0} active connection(s){3}), which Database Hub''s PostgreSQL dashboard charts.' -f $Minutes, $snapshot.Latest['cpu_percent'], $snapshot.Latest['active_connections'], $enhanced) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId 'METRICS.T4' -Area 'hub' -Target 'T4' -Status 'Warning' -Message ('Azure Monitor has no CPU or connection metrics for T4 from the last {0} minutes yet.' -f $Minutes) -Evidence $evidence -Remediation 'A server that just started or was just created sends metrics within a few minutes; run validate.ps1 -Area T4 again.' -DocUrl $docUrl)
}

function Get-DemoT4StoppedUtc {
    <#
    .SYNOPSIS
    When T4 was last stopped, from the Azure activity log's last succeeded stop operation within the last
    eight days, or $null. A stopped flexible server starts on its own seven days later. Internal.

    .DESCRIPTION
    The query passes --end-time as well: with --start-time alone, the Azure CLI ends the range at the start
    plus --offset (6 hours by default), so an eight-day look-back found nothing (live, 2026-10-26).
    Sources: https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server,
    https://learn.microsoft.com/cli/azure/monitor/activity-log#az-monitor-activity-log-list
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[datetime]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ServerId,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $now = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)
    $start = $now.AddDays(-8).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    $end = $now.AddMinutes(5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    $events = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('monitor', 'activity-log', 'list', '--resource-id', $ServerId, '--start-time', $start, '--end-time', $end, '--max-events', '1000', '--query', '[].{operation: operationName.value, status: status.value, time: eventTimestamp}', '--output', 'json') -AsJson -AllowFailure
    $stops = foreach ($entry in @($events)) {
        if ([string](Get-DemoMemberValue -InputObject $entry -Name 'operation') -ieq 'Microsoft.DBforPostgreSQL/flexibleServers/stop/action' -and [string](Get-DemoMemberValue -InputObject $entry -Name 'status') -ieq 'Succeeded') {
            ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $entry -Name 'time')
        }
    }
    $latest = @($stops | Where-Object { $null -ne $_ } | Sort-Object -Descending) | Select-Object -First 1
    return $latest
}

function Format-DemoT4MetricText {
    # One line for status.ps1 from a metric snapshot: CPU, memory, connections, sessions by state and wait, the
    # oldest transaction, and deadlocks. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Snapshot
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $latest = $Snapshot.Latest
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in @(@('cpu_percent', 'CPU {0:N0}%'), @('memory_percent', 'memory {0:N0}%'), @('active_connections', '{0:N0} active connection(s)'), @('cpu_credits_remaining', '{0:N0} CPU credit(s) left'), @('storage_percent', 'storage {0:N0}%'))) {
        if ($latest.Contains($pair[0])) {
            $parts.Add([string]::Format($culture, $pair[1], $latest[$pair[0]]))
        }
    }
    if ($Snapshot.ByState.Count -gt 0) {
        $parts.Add('sessions ' + (@($Snapshot.ByState.Keys | ForEach-Object { [string]::Format($culture, '{0} {1:N0}', $_, $Snapshot.ByState[$_]) }) -join ', '))
    }
    $waits = @($Snapshot.ByWaitEventType.Keys | Where-Object { $Snapshot.ByWaitEventType[$_] -gt 0 })
    if ($waits.Count -gt 0) {
        $parts.Add('waiting on ' + (@($waits | ForEach-Object { [string]::Format($culture, '{0} {1:N0}', $_, $Snapshot.ByWaitEventType[$_]) }) -join ', '))
    }
    if ($latest.Contains('longest_transaction_time_sec')) {
        $parts.Add([string]::Format($culture, 'oldest transaction {0:N0} s', $latest['longest_transaction_time_sec']))
    }
    if ($latest.Contains('deadlocks')) {
        $parts.Add([string]::Format($culture, '{0:N0} deadlock(s) in the last minute with data', $latest['deadlocks']))
    }
    if ($parts.Count -eq 0) {
        return 'no Azure Monitor metrics in the last {0} minutes yet' -f $Snapshot.Minutes
    }
    return ($parts -join '; ')
}

function ConvertFrom-DemoT4ServerJson {
    # The "server" object from the runner's 'status --json' output for T4, even when Run Command cut the front of
    # the output: it's near the document's end, before the profile host's node (Phase 25b). $null when it isn't
    # there. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    $index = $Text.LastIndexOf('"server"', [System.StringComparison]::Ordinal)
    if ($index -lt 0) {
        return $null
    }
    $start = $Text.IndexOf('{', $index)
    if ($start -lt 0) {
        return $null
    }
    $depth = 0
    for ($i = $start; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '{') {
            $depth++
        }
        elseif ($Text[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) {
                try {
                    return ($Text.Substring($start, $i - $start + 1) | ConvertFrom-Json -Depth 8)
                }
                catch {
                    return $null
                }
            }
        }
    }
    return $null
}
