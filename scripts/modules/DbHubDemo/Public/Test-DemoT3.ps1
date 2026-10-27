function Test-DemoT3 {
    <#
    .SYNOPSIS
    Verifies T3 as deployed: Entra-only, the network mode, the database, the free offer, and the Hub property.

    .DESCRIPTION
    Read-only Azure CLI calls through Invoke-DemoAz, plus one read-only T-SQL status query that T1 runs on
    T3 (Invoke-DemoT3SqlFromT1 -Name Status). Results (ADR 0012), all with area t3:
    - T3.EXISTS: the logical server azuresql01-<deploymentId> and the ContosoCare database exist. When they
      don't, it's the only result.
    - T3.ENTRAONLY: Microsoft Entra-only authentication is on, the administrator is the P6 group, and the
      minimum TLS version is 1.2 or later.
    - T3.NETWORK: public network access matches the effective mode. Private: the private endpoint is
      provisioned and approved for this server, its DNS zone group points at the privatelink zone, and the
      zone is linked to the VNet. Public: a ready VNet rule for snet-sqlvm and no IP firewall rules (so no
      0.0.0.0 "Allow Azure services" rule).
    - T3.DATABASE: General Purpose serverless, with the profile's vCores and size and the configured
      auto-pause delay.
    - T3.FREEOFFER: whether the database uses the free offer, and with "continue using database for
      additional charges" (BillOverUsage).
    - T3.PROPERTY: the extended property MS_EnablePerformanceMonitoringPreview is 'true'. A Warning when T1
      isn't running or its login isn't effective yet; Not selected with -SkipSqlCheck.

    Sources (checked 2026-10-20):
    - az sql server show --expand-ad-admin: https://learn.microsoft.com/cli/azure/sql/server
    - Microsoft Entra-only authentication: https://learn.microsoft.com/azure/azure-sql/database/authentication-azure-ad-only-authentication
    - Private endpoints for Azure SQL: https://learn.microsoft.com/azure/azure-sql/database/private-endpoint-overview
    - VNet rules: https://learn.microsoft.com/azure/azure-sql/database/vnet-service-endpoint-rule-overview
    - Free offer: https://learn.microsoft.com/azure/azure-sql/database/free-offer
    - Enable performance monitoring: https://learn.microsoft.com/fabric/database/hub/add-sql

    .PARAMETER NetworkMode
    The effective network mode, public or private (Resolve-DemoNetworkMode). Required when the
    configuration's networkMode is auto.

    .PARAMETER T3UseFreeLimit
    The free-offer setting the deployment used (preflight's PREFLIGHT.T3.FREEOFFER evidence, or false after
    a fallback). Without it, t3FreeOffer off expects no free offer, and auto only reports what's there.

    .PARAMETER SkipSqlCheck
    Skip the T-SQL status query on T1 (for example while T1 is deallocated).

    .EXAMPLE
    Test-DemoT3 -Config $config -NetworkMode private -T3UseFreeLimit $true
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('public', 'private')]
        [string] $NetworkMode,

        [bool] $T3UseFreeLimit,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [switch] $SkipSqlCheck,

        [ValidateRange(0, 1800)]
        [int] $MaxLoginWaitSeconds = 120
    )

    $effectiveMode = if ($NetworkMode) {
        $NetworkMode
    }
    elseif ($Config['networkMode'] -in 'public', 'private') {
        [string]$Config['networkMode']
    }
    else {
        throw "networkMode is '$($Config['networkMode'])' in the configuration, so pass the effective mode with -NetworkMode public or private (Resolve-DemoNetworkMode)."
    }
    $expectedFree = if ($PSBoundParameters.ContainsKey('T3UseFreeLimit')) {
        $T3UseFreeLimit
    }
    elseif ([string]$Config['t3FreeOffer'] -eq 'off') {
        $false
    }
    else {
        $null
    }

    $subscriptionId = $Config['subscriptionId']
    $groupId = [string]$Config['t3AdminGroupObjectId']
    $sizing = (Get-DemoProfile).profiles[[string]$Config['profile']].t3
    $results = [System.Collections.Generic.List[object]]::new()
    $names = Get-DemoT3Name -Config $Config -DeploymentId $DeploymentId

    function Add-T3Result([string] $CheckId, [string] $Status, [string] $Message, [hashtable] $Evidence = @{}, [string] $Remediation = '', [string] $DocUrl = '') {
        $results.Add((New-DemoResult -CheckId $CheckId -Area 't3' -Target 'T3' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl))
    }

    function Read-Az([string[]] $Arguments) {
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $Arguments -AsJson -AllowFailure
    }

    function Get-Value([object] $InputObject, [string[]] $Path) {
        $value = $InputObject
        foreach ($segment in $Path) {
            $value = Get-DemoMemberValue -InputObject $value -Name $segment
        }
        return $value
    }

    $server = $null
    if ($names.ServerName) {
        $server = Read-Az @('sql', 'server', 'show', '--name', $names.ServerName, '--resource-group', $names.ResourceGroup, '--expand-ad-admin')
    }
    if ($null -eq $server) {
        $serverText = if ($names.ServerName) { $names.ServerName } else { 'azuresql01-<deploymentId>' }
        Add-T3Result 'T3.EXISTS' 'Fail' ("T3's logical server {0} wasn't found in {1}." -f $serverText, $names.ResourceGroup) -Remediation 'Deploy or recreate T3 (deploy.ps1 -Resume), then run the checks again.'
        return $results.ToArray()
    }
    $database = Read-Az @('sql', 'db', 'show', '--name', $names.DatabaseName, '--server', $names.ServerName, '--resource-group', $names.ResourceGroup)
    if ($null -eq $database) {
        Add-T3Result 'T3.EXISTS' 'Fail' ("T3's logical server {0} exists, but its database {1} wasn't found." -f $names.ServerName, $names.DatabaseName) -Remediation 'Deploy T3 again (deploy.ps1 -Resume); the template recreates the database.'
        return $results.ToArray()
    }
    $databaseStatus = [string](Get-DemoMemberValue -InputObject $database -Name 'status')
    Add-T3Result 'T3.EXISTS' 'Pass' ('T3 exists: logical server {0} ({1}) with database {2} ({3}).' -f $names.ServerName, (Get-DemoMemberValue -InputObject $server -Name 'state'), $names.DatabaseName, $databaseStatus) @{ server = $names.ServerName; database = $names.DatabaseName; databaseStatus = $databaseStatus }

    # T3.ENTRAONLY
    $admin = Get-DemoMemberValue -InputObject $server -Name 'administrators'
    $entraOnly = [bool](Get-DemoMemberValue -InputObject $admin -Name 'azureADOnlyAuthentication')
    $adminSid = [string](Get-DemoMemberValue -InputObject $admin -Name 'sid')
    $tls = [string](Get-DemoMemberValue -InputObject $server -Name 'minimalTlsVersion')
    $evidence = @{ azureADOnlyAuthentication = $entraOnly; administratorSid = $adminSid; principalType = [string](Get-DemoMemberValue -InputObject $admin -Name 'principalType'); minimalTlsVersion = $tls }
    $entraDoc = 'https://learn.microsoft.com/azure/azure-sql/database/authentication-azure-ad-only-authentication'
    if ($null -eq $admin -or -not $adminSid) {
        Add-T3Result 'T3.ENTRAONLY' 'Fail' 'T3 has no Microsoft Entra administrator.' $evidence 'Deploy T3 again; the template sets the P6 group as the administrator.' $entraDoc
    }
    elseif (-not $entraOnly) {
        Add-T3Result 'T3.ENTRAONLY' 'Fail' 'T3 allows SQL authentication: Microsoft Entra-only authentication is off.' $evidence ("Turn it on: az sql server ad-only-auth enable --name {0} --resource-group {1}." -f $names.ServerName, $names.ResourceGroup) $entraDoc
    }
    elseif ($adminSid -ine $groupId) {
        Add-T3Result 'T3.ENTRAONLY' 'Fail' "T3's Microsoft Entra administrator isn't the P6 group in t3AdminGroupObjectId, so T1 can't administer it through the group." $evidence 'Deploy T3 again; the template sets the P6 group as the administrator.' $entraDoc
    }
    elseif ($tls -notin '1.2', '1.3') {
        Add-T3Result 'T3.ENTRAONLY' 'Fail' ("T3 accepts TLS older than 1.2 (minimal TLS version '{0}')." -f $tls) $evidence 'Deploy T3 again; the template sets the minimum TLS version to 1.2.' $entraDoc
    }
    else {
        Add-T3Result 'T3.ENTRAONLY' 'Pass' ('T3 is Microsoft Entra-only, its administrator is the P6 group, and it requires TLS {0} or later.' -f $tls) $evidence -DocUrl $entraDoc
    }

    # T3.NETWORK
    $publicAccess = [string](Get-DemoMemberValue -InputObject $server -Name 'publicNetworkAccess')
    $firewallRules = @(Read-Az @('sql', 'server', 'firewall-rule', 'list', '--server', $names.ServerName, '--resource-group', $names.ResourceGroup) | Where-Object { $null -ne $_ })
    $problems = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $evidence = @{ networkMode = $effectiveMode; publicNetworkAccess = $publicAccess; firewallRules = @($firewallRules | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') }) }
    if ($effectiveMode -eq 'private') {
        $networkDoc = 'https://learn.microsoft.com/azure/azure-sql/database/private-endpoint-overview'
        if ($publicAccess -ne 'Disabled') {
            $problems.Add("public network access is '$publicAccess', not Disabled")
        }
        $endpoint = Read-Az @('network', 'private-endpoint', 'show', '--name', $names.PrivateEndpointName, '--resource-group', $names.ResourceGroup)
        if ($null -eq $endpoint) {
            $problems.Add("the private endpoint $($names.PrivateEndpointName) is missing")
        }
        else {
            $connections = (Get-DemoMemberList -InputObject $endpoint -Name 'privateLinkServiceConnections') + (Get-DemoMemberList -InputObject $endpoint -Name 'manualPrivateLinkServiceConnections')
            $connection = $connections | Where-Object { [string](Get-Value $_ @('privateLinkServiceId')) -ieq [string](Get-DemoMemberValue -InputObject $server -Name 'id') } | Select-Object -First 1
            $approval = [string](Get-Value $connection @('privateLinkServiceConnectionState', 'status'))
            $evidence['privateEndpointState'] = [string](Get-DemoMemberValue -InputObject $endpoint -Name 'provisioningState')
            $evidence['privateEndpointConnection'] = $approval
            if ($evidence['privateEndpointState'] -ne 'Succeeded') {
                $problems.Add("the private endpoint is '$($evidence['privateEndpointState'])', not Succeeded")
            }
            if ($null -eq $connection) {
                $problems.Add('the private endpoint isn''t connected to this server')
            }
            elseif ($approval -ne 'Approved') {
                $problems.Add("the private endpoint connection is '$approval', not Approved")
            }
            $fqdn = [string](Get-DemoMemberValue -InputObject $server -Name 'fullyQualifiedDomainName')
            $zoneName = if ($fqdn.StartsWith($names.ServerName + '.', [System.StringComparison]::OrdinalIgnoreCase)) { 'privatelink.' + $fqdn.Substring($names.ServerName.Length + 1) } else { 'privatelink.database.windows.net' }
            $evidence['privateDnsZone'] = $zoneName
            $zoneGroups = @(Read-Az @('network', 'private-endpoint', 'dns-zone-group', 'list', '--endpoint-name', $names.PrivateEndpointName, '--resource-group', $names.ResourceGroup) | Where-Object { $null -ne $_ })
            $zoneIds = @(foreach ($zoneGroup in $zoneGroups) {
                    foreach ($zoneConfig in (Get-DemoMemberList -InputObject $zoneGroup -Name 'privateDnsZoneConfigs')) {
                        [string](Get-DemoMemberValue -InputObject $zoneConfig -Name 'privateDnsZoneId')
                    }
                })
            if (-not ($zoneIds | Where-Object { $_ -match ('(?i)/privateDnsZones/' + [regex]::Escape($zoneName) + '$') })) {
                $problems.Add("the private endpoint has no DNS zone group for $zoneName")
            }
            $links = @(Read-Az @('network', 'private-dns', 'link', 'vnet', 'list', '--zone-name', $zoneName, '--resource-group', $names.ResourceGroup) | Where-Object { $null -ne $_ })
            $linked = $links | Where-Object { [string](Get-Value $_ @('virtualNetwork', 'id')) -match ('(?i)/virtualNetworks/' + [regex]::Escape($names.VirtualNetworkName) + '$') }
            if (-not $linked) {
                $problems.Add("the $zoneName zone isn't linked to $($names.VirtualNetworkName)")
            }
        }
        if ($firewallRules.Count -gt 0) {
            $notes.Add(('{0} IP firewall rule(s) exist; they have no effect while public network access is off' -f $firewallRules.Count))
        }
    }
    else {
        $networkDoc = 'https://learn.microsoft.com/azure/azure-sql/database/vnet-service-endpoint-rule-overview'
        if ($publicAccess -ne 'Enabled') {
            $problems.Add("public network access is '$publicAccess', so T1 can't reach T3 through its VNet rule; use networkMode auto or private")
        }
        $vnetRules = @(Read-Az @('sql', 'server', 'vnet-rule', 'list', '--server', $names.ServerName, '--resource-group', $names.ResourceGroup) | Where-Object { $null -ne $_ })
        $evidence['vnetRules'] = @($vnetRules | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        $sqlvmRule = $vnetRules | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'virtualNetworkSubnetId') -match '(?i)/subnets/snet-sqlvm$' } | Select-Object -First 1
        if ($null -eq $sqlvmRule) {
            $problems.Add('there is no VNet rule for snet-sqlvm')
        }
        elseif ([string](Get-DemoMemberValue -InputObject $sqlvmRule -Name 'state') -notin '', 'Ready') {
            $problems.Add(("the snet-sqlvm VNet rule is '{0}', not Ready" -f (Get-DemoMemberValue -InputObject $sqlvmRule -Name 'state')))
        }
        if ($vnetRules.Count -gt 1) {
            $notes.Add(('{0} VNet rules exist; only snet-sqlvm is expected' -f $vnetRules.Count))
        }
        if ($firewallRules.Count -gt 0) {
            $problems.Add(('{0} IP firewall rule(s) exist ({1}); public mode allows only the VNet rule, with no "Allow Azure services" rule' -f $firewallRules.Count, ($evidence['firewallRules'] -join ', ')))
        }
    }
    if ($problems.Count -gt 0) {
        Add-T3Result 'T3.NETWORK' 'Fail' ('T3''s network doesn''t match {0} mode: {1}.' -f $effectiveMode, ($problems -join '; ')) $evidence 'Deploy T3 again with the effective network mode (deploy.ps1 -Resume), and remove any firewall rule added by hand.' $networkDoc
    }
    elseif ($notes.Count -gt 0) {
        Add-T3Result 'T3.NETWORK' 'Warning' ('T3''s network matches {0} mode, but {1}.' -f $effectiveMode, ($notes -join '; ')) $evidence 'Remove what the template doesn''t create.' $networkDoc
    }
    else {
        $summary = if ($effectiveMode -eq 'private') { 'public network access is off, and T1 reaches T3 through an approved private endpoint that resolves in the VNet' } else { 'T1 reaches T3 through the snet-sqlvm VNet rule, with no IP firewall rules' }
        Add-T3Result 'T3.NETWORK' 'Pass' ('T3''s network matches {0} mode: {1}.' -f $effectiveMode, $summary) $evidence -DocUrl $networkDoc
    }

    # T3.DATABASE
    $sku = Get-DemoMemberValue -InputObject $database -Name 'currentSku'
    if ($null -eq $sku) {
        $sku = Get-DemoMemberValue -InputObject $database -Name 'sku'
    }
    $skuName = [string](Get-DemoMemberValue -InputObject $sku -Name 'name')
    $capacity = Get-DemoMemberValue -InputObject $sku -Name 'capacity'
    $autoPause = Get-DemoMemberValue -InputObject $database -Name 'autoPauseDelay'
    $minCapacity = Get-DemoMemberValue -InputObject $database -Name 'minCapacity'
    $maxSizeBytes = Get-DemoMemberValue -InputObject $database -Name 'maxSizeBytes'
    $expectedPause = [int]$Config['t3AutoPauseMinutes']
    if ($expectedPause -eq 0) {
        # Same rule as demo.bicep: 0, or no value, means the profile's auto-pause delay.
        $expectedPause = [int]$sizing.autoPauseMinutes
    }
    $evidence = @{ sku = $skuName; maxVcores = $capacity; minVcores = $minCapacity; autoPauseDelay = $autoPause; maxSizeBytes = $maxSizeBytes; status = $databaseStatus }
    $sqlDoc = 'https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-overview'
    if ($skuName -notlike 'GP_S_*') {
        Add-T3Result 'T3.DATABASE' 'Fail' ("T3's database isn't General Purpose serverless (SKU '{0}')." -f $skuName) $evidence 'Deploy T3 again; the template sets GP_S_Gen5.' $sqlDoc
    }
    else {
        $drift = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $autoPause -and [int]$autoPause -ne $expectedPause) {
            $drift.Add(('auto-pause after {0} minutes, not {1}' -f $autoPause, $expectedPause))
        }
        if ($null -ne $capacity -and [double]$capacity -ne [double]$sizing.maxVcores) {
            $drift.Add(('{0} maximum vCores, not {1}' -f $capacity, $sizing.maxVcores))
        }
        if ($null -ne $minCapacity -and [double]$minCapacity -ne [double]$sizing.minVcores) {
            $drift.Add(('{0} minimum vCores, not {1}' -f $minCapacity, $sizing.minVcores))
        }
        if ($null -ne $maxSizeBytes -and [long]$maxSizeBytes -ne ([long]$sizing.maxSizeGB * 1GB)) {
            $drift.Add(('a maximum size of {0} bytes, not {1} GB' -f $maxSizeBytes, $sizing.maxSizeGB))
        }
        if ($drift.Count -gt 0) {
            Add-T3Result 'T3.DATABASE' 'Warning' ("T3's database is General Purpose serverless, but with {0}." -f ($drift -join ', ')) $evidence 'Deploy T3 again with the configured profile and t3AutoPauseMinutes.' $sqlDoc
        }
        else {
            Add-T3Result 'T3.DATABASE' 'Pass' ("T3's database is General Purpose serverless: {0} to {1} vCores, {2} GB, auto-pause after {3} minutes; it's {4}." -f $minCapacity, $capacity, $sizing.maxSizeGB, $autoPause, $databaseStatus) $evidence -DocUrl $sqlDoc
        }
    }

    # T3.FREEOFFER
    $useFree = [bool](Get-DemoMemberValue -InputObject $database -Name 'useFreeLimit')
    $behavior = [string](Get-DemoMemberValue -InputObject $database -Name 'freeLimitExhaustionBehavior')
    $evidence = @{ useFreeLimit = $useFree; freeLimitExhaustionBehavior = $behavior; expected = $expectedFree; configured = [string]$Config['t3FreeOffer'] }
    $freeDoc = 'https://learn.microsoft.com/azure/azure-sql/database/free-offer'
    if ($useFree -and $behavior -eq 'BillOverUsage') {
        Add-T3Result 'T3.FREEOFFER' 'Pass' 'T3 uses the Azure SQL Database free offer with "continue using database for additional charges", so it never pauses for the monthly limit.' $evidence -DocUrl $freeDoc
    }
    elseif ($useFree) {
        Add-T3Result 'T3.FREEOFFER' 'Warning' ("T3 uses the free offer, but the behavior at the limit is '{0}': the database would pause until next month when the allowance runs out." -f $behavior) $evidence 'Set "continue using database for additional charges" (BillOverUsage) on the database; it can''t be reverted.' $freeDoc
    }
    elseif ([string]$Config['t3FreeOffer'] -eq 'off') {
        Add-T3Result 'T3.FREEOFFER' 'Not selected' 't3FreeOffer is off, so T3 uses regular General Purpose serverless.' $evidence -DocUrl $freeDoc
    }
    else {
        $why = if ($expectedFree -eq $false) { 'The free offer wasn''t available, so T3 uses regular General Purpose serverless.' } else { 'T3 doesn''t use the free offer; an existing database can''t be converted to it.' }
        Add-T3Result 'T3.FREEOFFER' 'Warning' $why $evidence 'To move T3 to the free offer when a slot is free, run stop-demo.ps1 -RemoveT3 between demos; the next start recreates it.' $freeDoc
    }

    # T3.PROPERTY
    $hubDoc = 'https://learn.microsoft.com/fabric/database/hub/add-sql'
    if ($SkipSqlCheck) {
        Add-T3Result 'T3.PROPERTY' 'Not selected' 'The T-SQL check of the extended property was skipped (-SkipSqlCheck).' -DocUrl $hubDoc
    }
    else {
        $run = Invoke-DemoT3SqlFromT1 -Config $Config -Name Status -DeploymentId $names.DeploymentId -CheckId 'T3.PROPERTY' -MaxLoginWaitSeconds $MaxLoginWaitSeconds -Confirm:$false -WhatIf:$false
        $evidence = @{ reason = $run.Reason }
        if ($run.Status -eq 'Pass') {
            $row = @($run.Rows) | Select-Object -First 1
            $value = [string](Get-DemoMemberValue -InputObject $row -Name 'performance_monitoring')
            $evidence['value'] = $value
            $evidence['seedStatus'] = [string](Get-DemoMemberValue -InputObject $row -Name 'seed_status')
            $evidence['queryStore'] = [string](Get-DemoMemberValue -InputObject $row -Name 'query_store_state')
            if ($value -eq 'true') {
                Add-T3Result 'T3.PROPERTY' 'Pass' 'MS_EnablePerformanceMonitoringPreview is ''true'' on ContosoCare, so Database Hub collects performance data for T3.' $evidence -DocUrl $hubDoc
            }
            else {
                $shown = if ($value) { "'$value'" } else { 'missing' }
                Add-T3Result 'T3.PROPERTY' 'Fail' ("MS_EnablePerformanceMonitoringPreview is {0} on ContosoCare, so Database Hub doesn't collect performance data for T3." -f $shown) $evidence 'Run Invoke-DemoT3SqlFromT1 -Name PerformanceMonitoring (or -Name Setup).' $hubDoc
            }
        }
        elseif ($run.Reason -eq 'T1NotRunning' -or $run.Status -eq 'Warning') {
            Add-T3Result 'T3.PROPERTY' 'Warning' ('The extended property couldn''t be checked: {0}' -f $run.Message) $evidence $run.Result.remediation $hubDoc
        }
        else {
            Add-T3Result 'T3.PROPERTY' 'Fail' ('The extended property couldn''t be checked: {0}' -f $run.Message) $evidence $run.Result.remediation $hubDoc
        }
    }

    return $results.ToArray()
}
