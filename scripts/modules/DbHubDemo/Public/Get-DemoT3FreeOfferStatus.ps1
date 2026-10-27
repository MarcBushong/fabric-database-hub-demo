function Get-DemoT3FreeOfferStatus {
    <#
    .SYNOPSIS
    Checks, read-only, whether T3 can use the Azure SQL Database free offer (ADR 0016, C7).

    .DESCRIPTION
    Microsoft allows up to 10 free-offer General Purpose databases per subscription, and once a free
    database's region is chosen, every free database in the subscription uses that region. This function
    lists the subscription's SQL servers and their databases through Invoke-DemoAz ('az sql server list',
    'az sql db list'), then decides:
    - t3FreeOffer is off: Not selected. T3 uses regular General Purpose serverless.
    - The demo's database already exists: it keeps its setting, because an existing database can't be
      converted to the free offer. Without the free offer that's a Warning; after 'stop-demo.ps1 -RemoveT3'
      the next start recreates T3 on the free offer.
    - Ten or more other free databases, or other free databases in another region: Warning. T3 falls back to
      regular General Purpose serverless (minimum 0.5 vCore, auto-pause after 15 minutes).
    - Otherwise Pass: T3 uses the free offer with 'continue using database for additional charges', so it
      never pauses when the allowance runs out; usage above the allowance bills at serverless rates.
    - Not every server could be read: Warning. T3 tries the free offer, and the deployment falls back to
      regular serverless if Azure rejects it.
    Returns UseFreeLimit, the setting for the deployment and the cost estimate, and the
    PREFLIGHT.T3.FREEOFFER result. Source: https://learn.microsoft.com/azure/azure-sql/database/free-offer
    (checked 2026-10-20).

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER MaximumServers
    The most SQL servers to read. Above it, the check reports a Warning instead of reading them all.

    .EXAMPLE
    (Get-DemoT3FreeOfferStatus -Config $config).UseFreeLimit
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(1, 500)]
        [int] $MaximumServers = 50
    )

    $subscriptionId = $Config['subscriptionId']
    $location = ([string]$Config['location']).Replace(' ', '').ToLowerInvariant()
    $resourceGroupName = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $databaseName = 'ContosoCare'
    $freeLimitPerSubscription = 10
    $docUrl = 'https://learn.microsoft.com/azure/azure-sql/database/free-offer'
    $configured = if ($Config['t3FreeOffer']) { [string]$Config['t3FreeOffer'] } else { 'auto' }

    function ConvertTo-FreeOfferStatus([bool] $UseFreeLimit, [string] $Status, [string] $Message, [hashtable] $Evidence, [string] $Remediation = '') {
        $Evidence['configured'] = $configured
        $Evidence['useFreeLimit'] = $UseFreeLimit
        [pscustomobject]@{
            PSTypeName   = 'DbHubDemo.T3FreeOffer'
            UseFreeLimit = $UseFreeLimit
            Result       = New-DemoResult -CheckId 'PREFLIGHT.T3.FREEOFFER' -Area 'preflight' -Target 'T3' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl
        }
    }

    function Read-Json([string[]] $Arguments) {
        $raw = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList ($Arguments + @('--output', 'json')) -AllowFailure
        if ($raw.ExitCode -ne 0) {
            return [pscustomobject]@{ Ok = $false; Items = @() }
        }
        $text = ([string]$raw.StdOut).Trim()
        $items = if ($text) { @($text | ConvertFrom-Json -Depth 64) } else { @() }
        [pscustomobject]@{ Ok = $true; Items = $items }
    }

    if ($configured -eq 'off') {
        return ConvertTo-FreeOfferStatus $false 'Not selected' 't3FreeOffer is off, so T3 uses regular General Purpose serverless.' @{}
    }

    $fallbackText = 'T3 uses regular General Purpose serverless instead (minimum 0.5 vCore, auto-pause after 15 minutes), and the cost estimate prices it that way.'
    $unknownText = 'T3 tries the free offer, and the deployment falls back to regular serverless if Azure rejects it.'
    $serverList = Read-Json @('sql', 'server', 'list')
    if (-not $serverList.Ok) {
        return ConvertTo-FreeOfferStatus $true 'Warning' ("The subscription's SQL servers couldn't be listed, so the free offer's availability is unknown. {0}" -f $unknownText) @{ serversChecked = 0 }
    }

    $servers = @($serverList.Items | Where-Object { $_ })
    $unread = [System.Collections.Generic.List[string]]::new()
    if ($servers.Count -gt $MaximumServers) {
        $unread.Add(('{0} server(s) above the limit of {1}' -f ($servers.Count - $MaximumServers), $MaximumServers))
        $servers = @($servers | Select-Object -First $MaximumServers)
    }

    $ownDatabase = $null
    $otherFree = [System.Collections.Generic.List[object]]::new()
    foreach ($server in $servers) {
        $databases = Read-Json @('sql', 'db', 'list', '--server', [string]$server.name, '--resource-group', [string]$server.resourceGroup)
        if (-not $databases.Ok) {
            $unread.Add(('server {0}' -f $server.name))
            continue
        }
        foreach ($database in @($databases.Items | Where-Object { $_ })) {
            $isFree = [bool](Get-DemoMemberValue -InputObject $database -Name 'useFreeLimit')
            if ([string]$server.resourceGroup -ieq $resourceGroupName -and [string]$database.name -ieq $databaseName) {
                $ownDatabase = [pscustomobject]@{ Server = [string]$server.name; UseFreeLimit = $isFree }
            }
            elseif ($isFree) {
                $otherFree.Add([pscustomobject]@{ Location = ([string]$database.location).Replace(' ', '').ToLowerInvariant() })
            }
        }
    }

    $otherRegions = @($otherFree | ForEach-Object { $_.Location } | Where-Object { $_ -and $_ -ne $location } | Select-Object -Unique)
    $evidence = @{
        serversChecked     = $servers.Count
        otherFreeDatabases = $otherFree.Count
        otherFreeRegions   = @($otherFree | ForEach-Object { $_.Location } | Select-Object -Unique)
        demoDatabaseExists = $null -ne $ownDatabase
    }

    if ($null -ne $ownDatabase) {
        if ($ownDatabase.UseFreeLimit) {
            return ConvertTo-FreeOfferStatus $true 'Pass' ('The T3 database {0} already uses the Azure SQL Database free offer.' -f $databaseName) $evidence
        }
        return ConvertTo-FreeOfferStatus $false 'Warning' ("The T3 database {0} already exists without the free offer, and an existing database can't be converted, so it keeps regular General Purpose serverless pricing." -f $databaseName) $evidence 'To move T3 to the free offer, run stop-demo.ps1 -RemoveT3 between demos; the next start recreates it on the free offer when it is available.'
    }
    if ($otherFree.Count -ge $freeLimitPerSubscription) {
        return ConvertTo-FreeOfferStatus $false 'Warning' ('The subscription already has {0} free-offer databases, the most Microsoft allows. {1}' -f $otherFree.Count, $fallbackText) $evidence 'Delete an unused free-offer database to make room, or keep regular serverless.'
    }
    if ($otherRegions.Count -gt 0) {
        return ConvertTo-FreeOfferStatus $false 'Warning' ("The subscription's free-offer databases are in {0}, and every free database in a subscription uses the same region, so T3 in {1} can't use the offer. {2}" -f ($otherRegions -join ', '), $location, $fallbackText) $evidence 'Deploy the demo in the region the free databases use, or keep regular serverless.'
    }
    if ($unread.Count -gt 0) {
        $evidence['unread'] = $unread.ToArray()
        return ConvertTo-FreeOfferStatus $true 'Warning' ('Not every SQL server could be read ({0}), so the free offer may not be available. {1}' -f ($unread -join '; '), $unknownText) $evidence
    }
    return ConvertTo-FreeOfferStatus $true 'Pass' ('The Azure SQL Database free offer is available ({0} of {1} free databases in use in this subscription). T3 uses it with "continue using database for additional charges", so it never pauses when the monthly allowance runs out.' -f $otherFree.Count, $freeLimitPerSubscription) $evidence
}
