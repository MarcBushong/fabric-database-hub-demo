function Invoke-DemoVmPowerAction {
    <#
    .SYNOPSIS
    Starts or deallocates a demo VM and waits until Azure reports the power state, within -TimeoutSeconds.
    Returns a result: START.VM_<NAME> or STOP.VM_<NAME>. Internal.

    .DESCRIPTION
    'az vm start' and 'az vm deallocate' with --no-wait, then polls the instance view (Get-DemoVmPowerState),
    so one slow VM doesn't hold the other's command. A VM already in the wanted state isn't touched. A VM
    that's starting, stopping, or shows no power state yet is waited for; only a VM that Azure says doesn't
    exist is reported missing. A 409 Conflict (a policy-installed extension) is retried
    (Invoke-DemoAzWithConflictRetry). -StartRequested says that the caller already asked Azure to start the VM
    (Request-DemoVmStart), so a VM that's running by now isn't reported as "already running" (Phase 25d: both VMs
    were deallocated, start-demo.ps1 started them, and the results said they were already running).
    Sources: https://learn.microsoft.com/cli/azure/vm#az-vm-start,
    https://learn.microsoft.com/cli/azure/vm#az-vm-deallocate (checked 2026-10-20).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [ValidateSet('Start', 'Deallocate')]
        [string] $Action,

        [ValidateRange(30, 3600)]
        [int] $TimeoutSeconds = 900,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15,

        [switch] $StartRequested
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $checkId = '{0}.VM_{1}' -f $(if ($Action -eq 'Start') { 'START' } else { 'STOP' }), $VmName.ToUpperInvariant()
    $target = if ($VmName -eq 'sqlvm01') { 'T1' } else { 'T2' }
    $wanted = if ($Action -eq 'Start') { 'PowerState/running' } else { 'PowerState/deallocated' }
    $requested = $StartRequested -and $Action -eq 'Start'
    $before = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName
    if ($before -eq $wanted) {
        $message = if ($requested) { '{0} is running; this start requested it.' -f $VmName } else { '{0} is already {1}.' -f $VmName, $wanted.Split('/')[1] }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Pass' -Message $message -Evidence ([ordered]@{ startRequested = [bool]$requested }))
    }
    # A VM that's still stopping or starting (for example the nightly auto-shutdown) rejects another power
    # operation with OperationNotAllowed, so wait until it settles. Right after a start request, the instance view
    # can also carry no power state at all (live, 2026-10-22: sqlvm01 just after both VMs' 'az vm start --no-wait'
    # was reported missing), so only a VM that Azure says doesn't exist is reported missing.
    $settle = [System.Diagnostics.Stopwatch]::StartNew()
    while ($before -in '', 'PowerState/deallocating', 'PowerState/stopping', 'PowerState/starting' -and $settle.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (-not $before) {
            $show = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $resourceGroupName, '--name', $VmName, '--query', 'id', '--output', 'tsv') -AllowFailure
            if ($show.ExitCode -ne 0 -and (Test-DemoAzNotFound -Text ([string]$show.StdErr))) {
                return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' -Message ('{0} wasn''t found in {1}.' -f $VmName, $resourceGroupName) -Remediation 'Run deploy.ps1 first.')
            }
            Write-DemoLog -Message ('{0} reports no power state yet; waiting.' -f $VmName)
        }
        else {
            Write-DemoLog -Message ('{0} is {1}; waiting until it settles.' -f $VmName, $before.Split('/')[1])
        }
        Start-Sleep -Seconds $PollSeconds
        $before = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName
    }
    if (-not $before) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Warning' -Message ('{0} reported no power state for {1} seconds.' -f $VmName, $TimeoutSeconds) -Remediation 'Check the VM in the portal; run the script again.')
    }
    if ($before -eq $wanted) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Pass' -Message ('{0} is {1}.' -f $VmName, $wanted.Split('/')[1]))
    }
    $verb = if ($Action -eq 'Start') { 'start' } else { 'deallocate' }
    $run = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList @('vm', $verb, '--resource-group', $resourceGroupName, '--name', $VmName, '--no-wait') -Label ('{0}: {1}' -f $VmName, $verb)
    if ($run.ExitCode -ne 0 -and -not ($Action -eq 'Deallocate' -and (Test-DemoAzVmNotRunning -Text ([string]$run.StdErr)))) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' -Message ('az vm {0} {1} failed: {2}' -f $verb, $VmName, (Get-DemoDeploymentErrorText -Text $run.StdErr -MaxLength 400)))
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $current = $before
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $PollSeconds
        $current = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName
        if ($current -eq $wanted) {
            return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Pass' -Message ('{0} is {1} after {2:N0} seconds.' -f $VmName, $wanted.Split('/')[1], $watch.Elapsed.TotalSeconds) -Evidence ([ordered]@{ before = $before; after = $current }))
        }
    }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Warning' -Message ('{0} is still {1} after {2} seconds.' -f $VmName, $current, $TimeoutSeconds) -Remediation 'Check the VM in the portal; run the script again.' -Evidence ([ordered]@{ before = $before; after = $current }))
}

function Request-DemoVmStart {
    <#
    .SYNOPSIS
    Asks Azure to start a deallocated or stopped demo VM without waiting ('az vm start --no-wait'), so several
    VMs boot at once; Invoke-DemoVmPowerAction then waits for each. Returns $true when a start was requested.
    Internal.

    .DESCRIPTION
    A VM in any other state is left alone (Invoke-DemoVmPowerAction handles it). A 409 Conflict (a
    policy-installed extension) is retried (Invoke-DemoAzWithConflictRetry). A failed request isn't an error
    here: Invoke-DemoVmPowerAction requests the start again and reports it.
    Source: https://learn.microsoft.com/cli/azure/vm#az-vm-start (checked 2026-10-22).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $power = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName
    if ($power -notin 'PowerState/deallocated', 'PowerState/stopped') {
        return $false
    }
    $run = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList @('vm', 'start', '--resource-group', $resourceGroupName, '--name', $VmName, '--no-wait') -Label ('{0}: start' -f $VmName)
    return ($run.ExitCode -eq 0)
}

function Request-DemoStoppedStart {
    <#
    .SYNOPSIS
    deploy.ps1 on an existing environment (Phase 28 live finding, 2026-10-30): asks Azure to start the demo VMs that are
    deallocated or stopped, and T4 when it's deployed and stopped, without waiting, so they boot while preflight runs.
    Returns what Wait-DemoStoppedStart waits for: Needed, Vms (each VM that wasn't running, with its power state and
    whether a start was requested), T4 (the start request's result, or $null), Names (for the status page), and Requested
    (what this run asked to start). Internal.

    .DESCRIPTION
    The nightly auto-shutdown, stop-demo.ps1, or a Ctrl+C followed by a stop leaves the VMs deallocated, and every Run
    Command then fails ("the VM isn't running"), so "run ./scripts/deploy.ps1 again; it continues where it stopped"
    didn't. Each VM's power state is read (Get-DemoVmPowerState): a running VM, and one that doesn't exist yet (a first
    deployment, or a golden restore the template creates), is left alone, read-only; a deallocated or stopped one gets
    'az vm start --no-wait' (Request-DemoVmStart); one that's still deallocating, stopping, or starting is only waited
    for later (Invoke-DemoVmPowerAction). T4 gets Servers - Start when it's deployed and stopped
    (Invoke-DemoT4PowerAction -WaitMinutes 0, which only reads a T4 that's Ready). T3, serverless, resumes on its own at
    the first connection. The status page's StartVms step says what starts, with no action needed.
    Source: https://learn.microsoft.com/cli/azure/vm#az-vm-start (checked 2026-10-30).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $SkipT4,

        [AllowEmptyString()]
        [string] $ProgressPath = ''
    )

    $request = [pscustomobject]@{ Needed = $false; Vms = [ordered]@{}; T4 = $null; Names = @(); Requested = @() }
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $power = [ordered]@{}
    foreach ($vm in 'sqlvm01', (Get-DemoHostVmName -Config $Config)) {
        $power[$vm] = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $vm
    }
    $stopped = @($power.Keys | Where-Object { $power[$_] -and $power[$_] -ne 'PowerState/running' })
    $t4On = -not $SkipT4 -and (Test-DemoT4Enabled -Config $Config)
    if (($stopped.Count -gt 0 -or $t4On) -and -not $PSCmdlet.ShouldProcess($resourceGroupName, 'Start the demo VMs, and T4, that are stopped')) {
        return $request
    }
    foreach ($vm in $stopped) {
        $requested = $false
        if ($power[$vm] -in 'PowerState/deallocated', 'PowerState/stopped') {
            $requested = [bool](Request-DemoVmStart -Config $Config -VmName $vm)
        }
        $request.Vms[$vm] = [pscustomobject]@{ Before = [string]$power[$vm]; Requested = $requested }
    }
    if ($t4On) {
        # A T4 that's Ready is only read; one whose start failed is reported by Wait-DemoStoppedStart.
        $t4 = Invoke-DemoT4PowerAction -Config $Config -Action Start -WaitMinutes 0 -CheckPrefix DEPLOY
        $before = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $t4 -Name 'evidence') -Name 'stateBefore')
        if ([string]$t4.status -eq 'Fail' -or ([string]$t4.status -eq 'Pass' -and $before -and $before -ne 'Ready')) {
            $request.T4 = $t4
        }
    }
    $names = @(foreach ($vm in $request.Vms.Keys) { '{0} ({1})' -f $vm, $request.Vms[$vm].Before.Split('/')[-1] }) + @(if ($null -ne $request.T4 -and [string]$request.T4.status -eq 'Pass') { 'T4 (stopped)' })
    $request.Names = @($names)
    # What this run itself asked to start, which bills until a stop (a VM that was still deallocating is only waited for).
    $request.Requested = @(@($request.Vms.Keys | Where-Object { $request.Vms[$_].Requested }) + @(if ($null -ne $request.T4 -and [string]$request.T4.status -eq 'Pass') { 'T4' }))
    $request.Needed = $request.Vms.Count -gt 0 -or $null -ne $request.T4
    if ($names.Count -gt 0) {
        Write-DemoLog -Message ('Starting what was stopped (the nightly auto-shutdown, stop-demo.ps1, or a stop): {0}. It boots while the run goes on.' -f ($names -join ', '))
        Set-DemoProgressStep -Path $ProgressPath -Id 'StartVms' -State 'Running' -Message ('Starting the VMs that were stopped: no action needed ({0}).' -f ($names -join ', '))
    }
    elseif (-not $request.Needed) {
        Set-DemoProgressStep -Path $ProgressPath -Id 'StartVms' -State 'Skipped' -Message 'Not needed: nothing was stopped.'
    }
    return $request
}

function Wait-DemoStoppedStart {
    <#
    .SYNOPSIS
    Waits for what Request-DemoStoppedStart started (Phase 28 live finding): each VM until it runs
    (Invoke-DemoVmPowerAction, START.VM_*), the guest of a golden snapshot's source host (Invoke-DemoGoldenSourceRelease,
    as start-demo.ps1 does; any other T2 guest starts with its host), and T4 until it's Ready (DEPLOY.T4.START). Returns
    the results with DEPLOY.VMSTART: Pass when every VM runs, Fail when one doesn't, because every Run Command on it would
    fail, so the caller stops there. Updates the status page's StartVms step. Nothing when nothing was stopped. T1's
    monitoring plugin, which can stop after a restart, is the caller's next check (Invoke-DemoT1MonitoringCheck), on
    every run without a T1 Monitoring step, whether or not this run started sqlvm01. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Request,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [ValidateRange(1, 60)]
        [int] $T4WaitMinutes = 15
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Request -or -not [bool]$Request.Needed) {
        return $results.ToArray()
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $notRunning = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in @($Request.Vms.Keys)) {
        $item = Invoke-DemoVmPowerAction -Config $Config -VmName $vm -Action Start -StartRequested:([bool]$Request.Vms[$vm].Requested)
        $results.Add($item)
        if ([string]$item.status -ne 'Pass') {
            $notRunning.Add($vm)
        }
    }
    # The T2 guest starts with its host (its automatic start action), except on a golden snapshot's source host,
    # whose air-gapped guest is reconnected first, as start-demo.ps1 does.
    $hostVm = Get-DemoHostVmName -Config $Config
    if ($Request.Vms.Contains($hostVm) -and $hostVm -notin $notRunning) {
        $release = Invoke-DemoGoldenSourceRelease -Config $Config
        if ($null -ne $release) {
            $results.Add($release)
        }
    }
    $t4 = $null
    if ($null -ne $Request.T4) {
        $t4 = if ([string]$Request.T4.status -eq 'Pass') { Invoke-DemoT4PowerAction -Config $Config -Action Start -WaitMinutes $T4WaitMinutes -CheckPrefix DEPLOY -Requested } else { $Request.T4 }
        $results.Add($t4)
    }
    $minutes = [int][System.Math]::Ceiling($watch.Elapsed.TotalMinutes)
    $vms = @($Request.Vms.Keys)
    $evidence = [ordered]@{ vms = $vms; notRunning = $notRunning.ToArray(); t4 = $(if ($null -ne $t4) { [string]$t4.status } else { '' }); minutes = $minutes }
    $t4Text = if ($null -eq $t4) { '' } elseif ([string]$t4.status -eq 'Pass') { ' T4 is Ready.' } else { ' T4: {0}' -f [string]$t4.message }
    if ($notRunning.Count -gt 0) {
        $message = '{0} isn''t running, so the steps that need it can''t run (Run Command needs a running VM).{1}' -f ($notRunning -join ' and '), $t4Text
        $results.Add((New-DemoResult -CheckId 'DEPLOY.VMSTART' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message $message -Evidence $evidence -Remediation ('Start {0} in the Azure portal, or run ./scripts/start-demo.ps1, then run ./scripts/deploy.ps1 again: it continues where it stopped.' -f ($notRunning -join ' and ')) -DocUrl 'https://learn.microsoft.com/cli/azure/vm#az-vm-start'))
        Set-DemoProgressStep -Path $ProgressPath -Id 'StartVms' -Status 'Fail' -Message $message
        return $results.ToArray()
    }
    $message = if ($vms.Count -gt 0) { 'Started {0}, which had been stopped, in about {1} minute(s).{2}' -f ($vms -join ' and '), $minutes, $t4Text } elseif ([string]$t4.status -eq 'Pass') { 'Started T4, which had been stopped; it''s Ready.' } else { 'T4 was stopped, and it isn''t Ready: {0}' -f [string]$t4.message }
    $status = if ($null -ne $t4 -and [string]$t4.status -ne 'Pass') { 'Warning' } else { 'Pass' }
    $results.Add((New-DemoResult -CheckId 'DEPLOY.VMSTART' -Area 'infra' -Target 'subscription' -Status $status -Message $message -Evidence $evidence -DocUrl 'https://learn.microsoft.com/cli/azure/vm#az-vm-start'))
    Set-DemoProgressStep -Path $ProgressPath -Id 'StartVms' -Status $status -Message $message
    return $results.ToArray()
}

function Get-DemoBastionInfo {
    <#
    .SYNOPSIS
    The on-demand Bastion: whether its host and its public IP exist, with the host's expiry tag. Returns
    $null when the resource group can't be listed. Internal.

    .DESCRIPTION
    One 'az resource list' of the demo resource group, filtered here: the Microsoft.Network/bastionHosts
    resource, and the public IP pip-<prefix>-<environment>-bastion. The IP is reported on its own, because an
    interrupted Bastion delete can leave it behind, still billing (Phase 13 live finding, 2026-10-20).
    Returns Name, Id, HostExists, ExpiresUtc, PublicIpName, PublicIpExists, and Leftover (the IP without
    its host).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('resource', 'list', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--output', 'json') -AllowFailure
    if ($result.ExitCode -ne 0) {
        return $null
    }
    $resources = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
        $resources = @([string]$result.StdOut | ConvertFrom-Json -Depth 20)
    }
    $publicIpName = 'pip-{0}-{1}-bastion' -f $Config['prefix'], $Config['environment']
    $bastion = $resources | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'type') -eq 'Microsoft.Network/bastionHosts' } | Select-Object -First 1
    $publicIp = $resources | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'type') -eq 'Microsoft.Network/publicIPAddresses' -and [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -eq $publicIpName } | Select-Object -First 1
    $name = 'bas-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $id = ''
    $expires = ''
    if ($null -ne $bastion) {
        $name = [string](Get-DemoMemberValue -InputObject $bastion -Name 'name')
        $id = [string](Get-DemoMemberValue -InputObject $bastion -Name 'id')
        $expires = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $bastion -Name 'tags') -Name 'DbHubBastionExpiresUtc')
    }
    return [pscustomobject]@{
        Name           = $name
        Id             = $id
        HostExists     = ($null -ne $bastion)
        ExpiresUtc     = $expires
        PublicIpName   = $publicIpName
        PublicIpExists = ($null -ne $publicIp)
        Leftover       = ($null -eq $bastion -and $null -ne $publicIp)
    }
}

function Get-DemoBastionHourlyPrice {
    <#
    .SYNOPSIS
    The list prices per hour of Bastion Basic and of a Standard static public IP in the configured region,
    from the Azure Retail Prices API at run time (ADR 0016: no hard-coded prices). Internal.

    .DESCRIPTION
    The same meters as Get-DemoCostEstimate: 'Basic Gateway' (Azure Bastion, Basic) and 'Standard IPv4 Static
    Public IP' (Virtual Network, IP Addresses). Returns Bastion and PublicIp (USD per hour, $null when a
    price can't be read) and Currency. Never throws.
    https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $location = [string]$Config['location']
    $price = { param([string] $Filter, [string] $Meter)
        try {
            $item = @(Get-DemoRetailPrice -Filter $Filter -CurrencyCode 'USD') | Where-Object { $_.meterName -eq $Meter } | Select-Object -First 1
            if ($null -ne $item) { [double]$item.retailPrice } else { $null }
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The Retail Prices API couldn''t be read: {0}' -f $_.Exception.Message)
            $null
        }
    }
    return [pscustomobject]@{
        Bastion  = & $price ("serviceName eq 'Azure Bastion' and armRegionName eq '{0}' and skuName eq 'Basic' and priceType eq 'Consumption'" -f $location) 'Basic Gateway'
        PublicIp = & $price ("serviceName eq 'Virtual Network' and armRegionName eq '{0}' and productName eq 'IP Addresses' and skuName eq 'Standard' and priceType eq 'Consumption'" -f $location) 'Standard IPv4 Static Public IP'
        Currency = 'USD'
    }
}

function Get-DemoMonthToDateCost {
    <#
    .SYNOPSIS
    The resource group's actual cost this month from the Cost Management Query API (Contributor can read
    it), or $null when it can't be read. Internal.

    .DESCRIPTION
    POST {scope}/providers/Microsoft.CostManagement/query with timeframe MonthToDate (the API version pinned in
    config/versions.json), through 'az rest --body @<file>'. -ResourceGroupName reads another group of the
    subscription (status.ps1 adds rg-<prefix>-golden). Source:
    https://learn.microsoft.com/rest/api/cost-management/query/usage (checked 2026-10-20).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ResourceGroupName = ''
    )
    $subscriptionId = [string]$Config['subscriptionId']
    $group = if ($ResourceGroupName) { $ResourceGroupName } else { Get-DemoResourceGroupName -Config $Config }
    $url = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.CostManagement/query?api-version={2}' -f $subscriptionId, $group, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.CostManagement/query')
    $body = [ordered]@{
        type      = 'ActualCost'
        timeframe = 'MonthToDate'
        dataset   = [ordered]@{
            granularity = 'None'
            aggregation = [ordered]@{ totalCost = [ordered]@{ name = 'Cost'; function = 'Sum' } }
        }
    }
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-cost'
    try {
        $path = Write-DemoPrivateFile -Directory $directory -Name 'query.json' -Content ($body | ConvertTo-Json -Depth 10)
        $response = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'post', '--url', $url, '--body', "@$path") -AsJson -AllowFailure
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    $properties = Get-DemoMemberValue -InputObject $response -Name 'properties'
    $columnValue = Get-DemoMemberValue -InputObject $properties -Name 'columns'
    $rowValue = Get-DemoMemberValue -InputObject $properties -Name 'rows'
    $columns = @($columnValue)
    $rows = @($rowValue)
    if ($null -eq $properties) {
        return $null
    }
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{ Amount = 0.0; Currency = '' }
    }
    $names = @($columns | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
    $row = @($rows[0])
    $costIndex = [array]::IndexOf($names, 'Cost')
    $currencyIndex = [array]::IndexOf($names, 'Currency')
    return [pscustomobject]@{
        Amount   = if ($costIndex -ge 0) { [double]$row[$costIndex] } else { [double]$row[0] }
        Currency = if ($currencyIndex -ge 0) { [string]$row[$currencyIndex] } else { '' }
    }
}

function Stop-DemoGuestVm {
    <#
    .SYNOPSIS
    Shuts the T2 guest down cleanly before the host deallocates (Invoke-DemoWorkloadControl.ps1 -Action
    StopGuest on archost01), as STOP.GUEST. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if (-not $PSCmdlet.ShouldProcess('arcsql01', 'Shut the T2 guest down')) {
        return (New-DemoResult -CheckId 'STOP.GUEST' -Area 'infra' -Target 'T2' -Status 'Not selected' -Message 'What if: the guest wasn''t stopped.')
    }
    $data = Invoke-DemoWorkloadAction -Config $Config -VmName 'archost01' -Action 'StopGuest'
    $status = [string]$data['status']
    if ($status -notin 'Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected') {
        $status = 'Warning'
    }
    $message = [string]$data['message']
    if (-not $message) {
        $message = 'The guest stop returned no message.'
    }
    $evidence = if ($data['evidence'] -is [System.Collections.IDictionary]) { $data['evidence'] } else { @{} }
    $remediation = if ($status -in 'Fail', 'Warning') { 'The host''s automatic stop action (ShutDown) still stops the guest when the host deallocates.' } else { '' }
    return (New-DemoResult -CheckId 'STOP.GUEST' -Area 'infra' -Target 'T2' -Status $status -Message $message -Evidence $evidence -Remediation $remediation)
}

function Test-DemoT2NotSetUpText {
    <#
    .SYNOPSIS
    True when a T2 workload command failed only because the guest isn't set up yet: it gets its demo module
    (C:\ProgramData\DbHubDemo\module\DbHubDemo.Vm.psd1) and the workload runner after SQL Server setup, so before that the
    guest's Import-Module fails ("was not loaded because no valid module file was found"), or the runner isn't installed.
    A Not selected, never a Warning (Phase 28 live finding: stop-demo.ps1 before T2's setup). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    return [bool]([string]$Text -match '(?i)not installed|no workload runner|isn''t set up yet|was not loaded because no valid module file was found')
}

function Set-DemoTargetProfile {
    <#
    .SYNOPSIS
    Sets one target's activity profile ('profile set' through Invoke-DemoWorkloadCommand) and returns
    <CheckPrefix>.PROFILE_<target>. Internal.

    .DESCRIPTION
    deploy.ps1's Activity stage, start-demo.ps1, and stop-demo.ps1 use it. A profile other than off ends
    before the next auto-shutdown (--not-after). The T3 and T4 profiles are files on T1, so setting them never
    wakes T3 or connects to T4. A target the caller can't reach (-SkipReason) is Not selected. A profile that can't be set is a
    Warning, not a Fail: the demo's resources are fine, the profile ends at the auto-shutdown anyway, and
    demo-control.yml or start-demo.ps1 -ActivityProfile sets it again; a T2 guest that isn't set up yet (no demo module or
    workload runner before SQL Server setup; Test-DemoT2NotSetUpText) is Not selected. -Attempts retries a target that
    isn't reachable yet, such as a T2 guest that's still
    booting.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Callers confirm once for the whole start or stop; Invoke-DemoWorkloadCommand is called with -Confirm:$false.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target,

        [Parameter(Mandatory)]
        [ValidatePattern('^(off|baseline|business-day|incident:[a-z0-9][a-z0-9-]{0,47})$')]
        [string] $ProfileName,

        [Parameter(Mandatory)]
        [ValidateSet('DEPLOY', 'START', 'STOP')]
        [string] $CheckPrefix,

        [AllowEmptyString()]
        [string] $SkipReason = '',

        [ValidatePattern('^[A-Za-z0-9._@/-]{1,64}$')]
        [string] $RequestedBy = 'DbHubDemo',

        [ValidateRange(1, 5)]
        [int] $Attempts = 1,

        [ValidateRange(0, 600)]
        [int] $RetrySeconds = 120
    )

    $checkId = '{0}.PROFILE_{1}' -f $CheckPrefix, $Target
    $docUrl = 'https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-overview#auto-pause'
    if ($SkipReason) {
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target $Target -Status 'Not selected' -Message ('{0}: the activity profile wasn''t set to {1}. {2}' -f $Target, $ProfileName, $SkipReason))
    }
    $arguments = @('profile', 'set', '--name', $ProfileName, '--requested-by', $RequestedBy)
    if ($ProfileName -ne 'off') {
        $arguments += @('--not-after', '{{NEXT_SHUTDOWN}}')
    }
    $run = $null
    $detail = ''
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $run = Invoke-DemoWorkloadCommand -Config $Config -Target $Target -ArgumentList $arguments -TimeoutSeconds 300 -Confirm:$false
            $detail = [string]$run.Result.message
        }
        catch {
            $run = $null
            $detail = $_.Exception.Message
        }
        if (($null -ne $run -and $run.Status -in 'Pass', 'Warning') -or $attempt -eq $Attempts) {
            break
        }
        Write-DemoLog -Level Warning -Message ('{0}: the activity profile couldn''t be set yet ({1}); retrying in {2} seconds ({3} of {4}).' -f $Target, $detail, $RetrySeconds, $attempt, $Attempts)
        Start-Sleep -Seconds $RetrySeconds
    }
    $evidence = [ordered]@{ profile = $ProfileName; requestedBy = $RequestedBy }
    if ($null -ne $run -and $run.Status -in 'Pass', 'Warning') {
        $message = if ($ProfileName -eq 'off') {
            '{0}: the activity profile is off. Nothing sets it again at boot unless activityProfileOnBoot is true.' -f $Target
        }
        else {
            '{0}: the activity profile is {1} until two minutes before the next auto-shutdown.' -f $Target, $ProfileName
        }
        if ($Target -eq 'T3' -and $ProfileName -ne 'off') {
            $message += ' While it runs, T3''s serverless database stays awake and bills compute (ADR 0016).'
        }
        if ($run.Status -eq 'Warning' -and $detail) {
            $message += ' Runner: ' + $detail
        }
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target $Target -Status $run.Status -Message $message -Evidence $evidence -DocUrl $docUrl)
    }
    if ($Target -eq 'T2' -and (Test-DemoT2NotSetUpText -Text $detail)) {
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T2' -Status 'Not selected' -Message ('T2 isn''t set up yet: the guest gets its demo module and workload runner after SQL Server setup, so its activity profile wasn''t set to {0}{1}.' -f $ProfileName, $(if ($ProfileName -eq 'off') { ', and no activity runs there to turn off' } else { '' })) -Evidence $evidence)
    }
    $remediation = if ($ProfileName -eq 'off') {
        'The profile still ends at the auto-shutdown it was set for, and nothing sets it again at boot unless activityProfileOnBoot is true. To turn it off now, run stop-demo.ps1 again while the VM runs, or demo-control.yml with scenario off.'
    }
    else {
        'Set it again with demo-control.yml, or ./scripts/start-demo.ps1 -ActivityProfile {0}.' -f $ProfileName
    }
    return (New-DemoResult -CheckId $checkId -Area 'workload' -Target $Target -Status 'Warning' -Message ('{0}: the activity profile couldn''t be set to {1}: {2}' -f $Target, $ProfileName, $detail) -Remediation $remediation -Evidence $evidence)
}

function Test-DemoStartCost {
    <#
    .SYNOPSIS
    The cost guardrail before start-demo.ps1 (plan section 9.4, ADR 0016): the live estimate against both
    ceilings, and this month's actual cost plus one session against monthlyCeilingUsd. Internal.

    .DESCRIPTION
    - PREFLIGHT.COST.SESSION and PREFLIGHT.COST.MONTHLY from Get-DemoCostEstimate (Azure Retail Prices API at
      run time, with the subscription's Defender for Cloud plans when they can be read): the same checks
      preflight runs before deploy.ps1. The monthly one is a hard ceiling (Fail).
    - START.COST.ACTUAL: the resource group's month-to-date actual cost (Cost Management, which lags by up to
      a day) plus one estimated session. Fail when the month already reached monthlyCeilingUsd, Warning when
      this session would cross it, Warning when the cost can't be read or isn't in USD.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('public', 'private')]
        [string] $NetworkMode,

        [AllowNull()]
        [object] $T3UseFreeLimit
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $docUrl = 'https://learn.microsoft.com/rest/api/cost-management/query/usage'
    $costParameters = @{ Config = $Config; NetworkMode = $NetworkMode }
    if ($null -ne $T3UseFreeLimit) {
        $costParameters['T3UseFreeLimit'] = [bool]$T3UseFreeLimit
    }
    try {
        $costParameters['DefenderPlans'] = @(Get-DemoDefenderPlan -SubscriptionId ([string]$Config['subscriptionId']))
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The Defender for Cloud plans couldn''t be read, so the estimate excludes them: {0}' -f $_.Exception.Message)
    }
    try {
        $costParameters['GoldenSnapshots'] = @(Get-DemoT2GoldenSnapshot -Config $Config)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The T2 golden snapshots couldn''t be listed, so the estimate leaves them out: {0}' -f $_.Exception.Message)
    }
    $sessionCost = 0.0
    try {
        $estimate = Get-DemoCostEstimate @costParameters
        $sessionCost = [double]$estimate.SessionCost
        foreach ($item in @($estimate.Results | Where-Object { $_.checkId -in 'PREFLIGHT.COST.SESSION', 'PREFLIGHT.COST.MONTHLY' })) {
            $results.Add($item)
        }
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.SESSION' -Area 'preflight' -Target 'subscription' -Status 'Warning' -Message ('The cost estimate couldn''t be computed: {0}' -f $_.Exception.Message) -Remediation 'Run ./scripts/estimate-cost.ps1 to see why; the ceilings weren''t checked.'))
    }

    $ceiling = [double]$Config['monthlyCeilingUsd']
    $actual = $null
    try {
        $actual = Get-DemoMonthToDateCost -Config $Config
    }
    catch {
        Write-DemoLog -Level Warning -Message ('Cost Management couldn''t be read: {0}' -f $_.Exception.Message)
    }
    if ($null -eq $actual) {
        $results.Add((New-DemoResult -CheckId 'START.COST.ACTUAL' -Area 'preflight' -Target 'subscription' -Status 'Warning' -Message 'This month''s actual cost couldn''t be read from Cost Management, so only the estimate was checked.' -DocUrl $docUrl))
        return $results.ToArray()
    }
    $evidence = [ordered]@{ monthToDate = $actual.Amount; currency = $actual.Currency; sessionEstimateUsd = $sessionCost; monthlyCeilingUsd = $ceiling }
    if ($actual.Currency -and $actual.Currency -ne 'USD') {
        $results.Add((New-DemoResult -CheckId 'START.COST.ACTUAL' -Area 'preflight' -Target 'subscription' -Status 'Warning' -Message ('This month''s actual cost is {0:N2} {1}; the ceiling is in USD, so they weren''t compared.' -f $actual.Amount, $actual.Currency) -Evidence $evidence -DocUrl $docUrl))
        return $results.ToArray()
    }
    if ($ceiling -gt 0 -and $actual.Amount -ge $ceiling) {
        $results.Add((New-DemoResult -CheckId 'START.COST.ACTUAL' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message ('This month''s actual cost, {0:N2} USD, already reached the monthly ceiling of {1:N2} USD.' -f $actual.Amount, $ceiling) -Evidence $evidence -Remediation 'Keep the demo stopped until next month, or raise monthlyCeilingUsd in the configuration (and the budget with it: deploy.ps1 -FromStage Infrastructure). start-demo.ps1 -SkipCostCheck starts anyway.' -DocUrl $docUrl))
    }
    elseif ($ceiling -gt 0 -and $actual.Amount + $sessionCost -gt $ceiling) {
        $results.Add((New-DemoResult -CheckId 'START.COST.ACTUAL' -Area 'preflight' -Target 'subscription' -Status 'Warning' -Message ('This month''s actual cost, {0:N2} USD, plus a session ({1:N2} USD) crosses the monthly ceiling of {2:N2} USD.' -f $actual.Amount, $sessionCost, $ceiling) -Evidence $evidence -Remediation 'Keep the session short, and stop the demo afterward (stop-demo.ps1).' -DocUrl $docUrl))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'START.COST.ACTUAL' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message ('This month''s actual cost, {0:N2} USD, plus a session ({1:N2} USD) stays under the monthly ceiling of {2:N2} USD (Cost Management lags by up to a day).' -f $actual.Amount, $sessionCost, $ceiling) -Evidence $evidence -DocUrl $docUrl))
    }
    return $results.ToArray()
}
