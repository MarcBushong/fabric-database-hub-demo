function Get-DemoEnvironmentStatus {
    <#
    .SYNOPSIS
    The demo's status for status.ps1 (plan section 9.6): health per target, the activity profile, evaluation
    days left, Arc days disconnected, Bastion, month-to-date cost, the next auto-shutdown, and the expiry.

    .DESCRIPTION
    Read-only. Every item is an ADR 0012 result with the check ID STATUS.*:
    - STATUS.DEPLOYMENT: the resource group, the last deploy.ps1 stage, the bundle and runner, and the expiry
      tag (expiresOn); Warning when the expiry has passed.
    - STATUS.VM_SQLVM01 and STATUS.VM_<T2 VM>: the power state and, for a running VM, its health summary
      (Get-DemoVmHealth, a read-only Run Command). With -Detail, the full health, which includes the guest's
      evaluation days left and the workload runner.
    - STATUS.T2.AUTOSIGNIN (Phase 28, Get-DemoGuidedSignInStatus), only when there's something to say: Pass while the
      guest's one-time automatic sign-in waits for a guided stop; a Warning when it's armed with no guided stop
      waiting or its last cleanup didn't finish (archost01's next pass removes the leftovers; status stays read-only).
    - STATUS.T3: whether T3 exists and its status (Online, Paused); Not selected after stop-demo.ps1 -RemoveT3.
    - STATUS.T4 (Phase 24, ADR 0019): T4's state; while it runs, its live Azure Monitor metrics from the last
      15 minutes (CPU, memory, connections, CPU credits, and the enhanced metrics: sessions by state and by
      wait event type, the oldest transaction, deadlocks); while it's stopped, when it starts on its own (seven
      days after the stop in the activity log; a Warning within a day). STATUS.PROFILE_T4 is its activity
      profile, and with -Detail STATUS.T4.LIVE is T1's runner's live view of T4 (connections against
      max_connections, sessions by state, blockers, the oldest transaction, deadlocks).
    - T1.SQLVM.ASSOCIATEDSERVICES (Phase 7, read-only): the SQL Server instances unified inventory lists for
      T1, Pass with the engine only and a Warning while associated services are still listed; and T1.SQLVM.MONITORING while sqlvm01
      runs (an extension that's Updating after a redeployment is a Warning).
    - STATUS.PROFILE_T1 and STATUS.PROFILE_T3 (sqlvm01 running): the active activity profile and its end,
      read with 'profile get' (a Run Command each; the T3 profile is a file on T1, so T3 isn't woken).
      STATUS.PROFILE_T2 with -Detail. Each takes on the Warning or Fail of the profile host lane that serves the
      target (Phase 25b, from host-lanes.json): a stalled, restarting, or failing lane, or an active profile that
      nothing runs.
    - STATUS.ARC: Arc's connection and days disconnected (Get-DemoArcCheck).
    - STATUS.BASTION: on-demand Bastion and its public IP, with their list price per hour from the Azure
      Retail Prices API; a Warning while either exists, including a public IP left over after an interrupted
      delete (stop-demo.ps1 -RemoveBastionOnly removes it).
    - STATUS.KEYVAULT, with the Key Vault opt-in only (Get-DemoKeyVaultStatus): whether the vault exists, and
      whether a readable one-time password is in it; a Warning for a missing vault or a readable password
      past its expiry.
    - STATUS.CONTROL, with control.enabled only (Get-DemoActivityControlStatus, ADR 0020): the on-demand activity
      control's checks in one line: an active run and its auto-stop, the webhook's expiry (a Warning 14 days before),
      and any role an Owner must grant again after a redeploy (Manual action required).
    - STATUS.FABRIC (Get-DemoFabricStatus, Phase 26a, ADR 0021): the Fabric workspace and lakehouse, found by name
      and never created here, and the state of the workspace's capacity, which runs at its administrator's choice.
    - STATUS.T2.GOLDEN (Get-DemoT2GoldenStatus, ADR 0018): the newest usable golden snapshot and its guest's
      evaluation days; Warnings at 30 and 7 days and before expiresOn.
    - STATUS.COST: month-to-date actual cost of the resource group, plus rg-<prefix>-golden while it holds a
      snapshot (Cost Management Query API), against monthlyCeilingUsd; Warning above 80%.
    - STATUS.SHUTDOWN: the next auto-shutdown.
    - STATUS.FABRIC.CAPACITY, with fabric.manageCapacity true or a DbHubFabricCapacityResumed record only (Phase 26b,
      Get-DemoFabricCapacityStatus): the capacity's state, and whether start-demo.ps1 resumed it (the record, which
      stop-demo.ps1 pauses and clears). Read-only: a stale record is shown, and stop-demo.ps1 clears it.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Detail
    Read the full health and T2's activity profile too (each a Run Command, about 30 to 60 seconds).

    .PARAMETER NowUtc
    For tests: the current time.

    .EXAMPLE
    Get-DemoEnvironmentStatus -Config $config -Detail
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $Detail,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Sign in yourself and run status.ps1 again.'))
        return $results.ToArray()
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $state = Get-DemoDeploymentState -Config $Config
    if (-not $state.Exists) {
        $results.Add((New-DemoResult -CheckId 'STATUS.DEPLOYMENT' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('{0} doesn''t exist: nothing is deployed.' -f $resourceGroupName) -Remediation 'Run deploy.ps1.'))
        return $results.ToArray()
    }

    $expires = [string]$state.Tags['expiresOn']
    $expiryStatus = 'Pass'
    $expiryText = 'no expiry tag'
    if ($expires) {
        $expiryText = 'expires ' + $expires
        $expiry = [datetime]::MinValue
        if ([datetime]::TryParse($expires, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiry) -and $expiry -lt $NowUtc) {
            $expiryStatus = 'Warning'
            $expiryText = 'expired on ' + $expires
        }
    }
    $stage = if ($state.Stage) { $state.Stage } else { 'none recorded' }
    $results.Add((New-DemoResult -CheckId 'STATUS.DEPLOYMENT' -Area 'infra' -Target 'subscription' -Status $expiryStatus -Message ('{0}: last deploy.ps1 stage {1}; {2}.' -f $resourceGroupName, $stage, $expiryText) -Evidence ([ordered]@{ stage = $state.Stage; stageUtc = $state.StageUtc; bundleSha256 = $state.BundleSha256; runnerSha256 = $state.RunnerSha256; expiresOn = $expires }) -Remediation $(if ($expiryStatus -eq 'Warning') { 'The expiry workflow destroys expired environments; run destroy.ps1, or move expiresOn in the configuration and run deploy.ps1 -FromStage Infrastructure.' } else { '' })))
    # fabric.manageCapacity (Phase 26b): the capacity's state and the DbHubFabricCapacityResumed record, read-only; no line
    # with the default (false) and no record.
    $capacityStatus = Get-DemoFabricCapacityStatus -Config $Config -State $state
    if ($null -ne $capacityStatus) {
        $results.Add($capacityStatus)
    }

    $hostVm = Get-DemoHostVmName -Config $Config
    $running = @{}
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in 'sqlvm01', $hostVm) {
        $target = if ($vm -eq 'sqlvm01') { 'T1' } else { 'T2' }
        $power = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $vm
        $running[$vm] = ($power -eq 'PowerState/running')
        if (-not $power) {
            $results.Add((New-DemoResult -CheckId ('STATUS.VM_{0}' -f $vm.ToUpperInvariant()) -Area $target.ToLowerInvariant() -Target $target -Status 'Fail' -Message ('{0} wasn''t found.' -f $vm) -Remediation 'Run deploy.ps1 -Resume.'))
            continue
        }
        $found.Add($vm)
        if (-not $running[$vm]) {
            $results.Add((New-DemoResult -CheckId ('STATUS.VM_{0}' -f $vm.ToUpperInvariant()) -Area $target.ToLowerInvariant() -Target $target -Status 'Pass' -Message ('{0} is {1}; start-demo.ps1 starts it.' -f $vm, $power.Split('/')[1]) -Evidence ([ordered]@{ powerState = $power })))
            continue
        }
        try {
            $health = Get-DemoVmHealth -Config $Config -VmName $vm -View $(if ($Detail) { 'Full' } else { 'Summary' })
            $healthStatus = [string](Get-DemoMemberValue -InputObject $health -Name 'status')
            if ($healthStatus -notin @('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')) {
                $healthStatus = 'Warning'
            }
            $evidence = [ordered]@{
                powerState  = $power
                state       = [string](Get-DemoMemberValue -InputObject $health -Name 'state')
                currentStep = [string](Get-DemoMemberValue -InputObject $health -Name 'currentStep')
                updatedUtc  = [string](Get-DemoMemberValue -InputObject $health -Name 'updatedUtc')
            }
            $details = Get-DemoMemberValue -InputObject $health -Name 'details'
            $guest = Get-DemoMemberValue -InputObject $details -Name 'guest'
            $days = Get-DemoMemberValue -InputObject $guest -Name 'evaluationDaysLeft'
            if ($null -ne $days) {
                $evidence['evaluationDaysLeft'] = $days
            }
            $workload = Get-DemoMemberValue -InputObject $details -Name 'workload'
            if ($null -eq $workload) {
                $workload = Get-DemoMemberValue -InputObject $guest -Name 'workload'
            }
            if ($null -ne $workload) {
                $evidence['workload'] = $workload
            }
            $message = '{0} is running; bootstrap {1}: {2}' -f $vm, $evidence['state'], [string](Get-DemoMemberValue -InputObject $health -Name 'message')
            if ($null -ne $days) {
                $message += (' Guest evaluation days left: {0}.' -f $days)
            }
            $results.Add((New-DemoResult -CheckId ('STATUS.VM_{0}' -f $vm.ToUpperInvariant()) -Area $target.ToLowerInvariant() -Target $target -Status $healthStatus -Message $message -Evidence $evidence))
            if ($vm -eq $hostVm) {
                # The guest's one-time automatic sign-in for the guided stop (Phase 28): armed or left over.
                $autoSignIn = Get-DemoGuidedSignInStatus -Health $health
                if ($null -ne $autoSignIn) {
                    $results.Add($autoSignIn)
                }
            }
        }
        catch {
            $results.Add((New-DemoResult -CheckId ('STATUS.VM_{0}' -f $vm.ToUpperInvariant()) -Area $target.ToLowerInvariant() -Target $target -Status 'Warning' -Message ('{0} is running, but its health couldn''t be read: {1}' -f $vm, $_.Exception.Message)))
        }
    }

    # The VMs' disks against the profile (Phase 24): the subscription's automation can switch a deallocated
    # VM's disks to Standard HDD; deploy.ps1 keeps the current type, and this says so (a read of each VM).
    if ($found.Count -gt 0) {
        $results.Add((New-DemoDiskDriftResult -CheckId 'STATUS.DISKS' -Drift @(Get-DemoVmDiskDrift -Config $Config -VmName $found.ToArray()) -VmName $found.ToArray()))
    }

    $t3 = Get-DemoT3State -Config $Config -DeploymentId ([string]$state.Tags['deploymentId'])
    # T1's SQL Server instances in unified inventory (Phase 7, read-only), and its monitoring while it runs.
    $results.Add((Test-DemoSqlVmAssociatedService -Config $Config))
    if ($running['sqlvm01']) {
        $results.Add((Test-DemoSqlVmMonitoring -Config $Config))
    }
    if ($t3.Exists) {
        $results.Add((New-DemoResult -CheckId 'STATUS.T3' -Area 't3' -Target 'T3' -Status 'Pass' -Message ('{0}/ContosoCare is {1}.' -f $t3.ServerName, $t3.Status) -Evidence ([ordered]@{ status = $t3.Status })))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'STATUS.T3' -Area 't3' -Target 'T3' -Status 'Not selected' -Message ('T3 ({0}) doesn''t exist; start-demo.ps1 recreates it under the same names.' -f $t3.ServerName)))
    }

    # T4 (Phase 24, ADR 0019): its state, its live Azure Monitor metrics with the enhanced ones while it runs,
    # and when a stopped server starts on its own.
    $t4 = $null
    $t4Ready = $false
    if (-not (Test-DemoT4Enabled -Config $Config)) {
        $results.Add((New-DemoResult -CheckId 'STATUS.T4' -Area 't4' -Target 'T4' -Status 'Not selected' -Message 'T4 is off in this configuration (t4Enabled is false).'))
    }
    else {
        $t4 = Get-DemoT4State -Config $Config -DeploymentId ([string]$state.Tags['deploymentId'])
        $t4Docs = (Get-DemoPostgresSetting)['docUrls']
        if (-not $t4.Exists) {
            $results.Add((New-DemoResult -CheckId 'STATUS.T4' -Area 't4' -Target 'T4' -Status 'Not selected' -Message ('T4 ({0}) doesn''t exist; deploy.ps1 creates it.' -f $t4.Names.ServerName)))
        }
        elseif ($t4.State -eq 'Ready') {
            $t4Ready = $true
            $snapshot = Get-DemoT4MetricSnapshot -Config $Config -ServerId $t4.Names.ServerId -Minutes 15
            $evidence = [ordered]@{ state = $t4.State; latestUtc = $snapshot.LatestUtc; latest = $snapshot.Latest; sessionsByState = $snapshot.ByState; sessionsByWaitEventType = $snapshot.ByWaitEventType }
            $results.Add((New-DemoResult -CheckId 'STATUS.T4' -Area 't4' -Target 'T4' -Status 'Pass' -Message ('{0} is running: {1} (Azure Monitor, last 15 minutes; Database Hub''s PostgreSQL dashboard charts the same metrics).' -f $t4.Names.ServerName, (Format-DemoT4MetricText -Snapshot $snapshot)) -Evidence $evidence -DocUrl ([string]$t4Docs['hubMonitor'])))
        }
        elseif ($t4.State -eq 'Stopped') {
            $days = [int](Get-DemoPostgresSetting)['autoStartAfterStoppedDays']
            $stopped = Get-DemoT4StoppedUtc -Config $Config -ServerId $t4.Names.ServerId -NowUtc $NowUtc
            if ($null -ne $stopped) {
                $restart = $stopped.AddDays($days)
                $hoursLeft = ($restart - [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)).TotalHours
                $soon = $hoursLeft -lt 24
                # What the restart bills, priced at run time (ADR 0016); a scheduled daily stop of T4 caps it once it's live.
                $hourly = Get-DemoT4HourlyPrice -Config $Config
                $billing = if ($null -ne $hourly) { ' It then bills compute at about {0:N2} USD an hour ({1}, list price) until it''s stopped, unless a scheduled daily stop of T4 stops it first.' -f $hourly, (Get-DemoT4SkuName -Config $Config) } else { ' It then bills compute at its size until it''s stopped, unless a scheduled daily stop of T4 stops it first.' }
                $message = ('{0} is stopped since {1:yyyy-MM-dd HH:mm} UTC; it starts on its own at {2:yyyy-MM-dd HH:mm} UTC unless it''s stopped again before then.' -f $t4.Names.ServerName, $stopped, $restart) + $billing
                $results.Add((New-DemoResult -CheckId 'STATUS.T4' -Area 't4' -Target 'T4' -Status $(if ($soon) { 'Warning' } else { 'Pass' }) -Message $message -Evidence ([ordered]@{ state = $t4.State; stoppedUtc = $stopped.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture); autoStartUtc = $restart.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture); hourlyUsd = $hourly; skuName = (Get-DemoT4SkuName -Config $Config) }) -Remediation $(if ($soon) { 'Run stop-demo.ps1 again after it starts, or start-demo.ps1 for a session; the 7-day restart bills compute until the next stop.' } else { '' }) -DocUrl ([string]$t4Docs['stopServer'])))
            }
            else {
                $results.Add((New-DemoResult -CheckId 'STATUS.T4' -Area 't4' -Target 'T4' -Status 'Pass' -Message ('{0} is stopped; it starts on its own {1} days after it was stopped (the stop isn''t in the last 8 days of the activity log).' -f $t4.Names.ServerName, $days) -Evidence ([ordered]@{ state = $t4.State }) -DocUrl ([string]$t4Docs['stopServer'])))
            }
        }
        else {
            $results.Add((New-DemoResult -CheckId 'STATUS.T4' -Area 't4' -Target 'T4' -Status 'Warning' -Message ('{0} is {1}.' -f $t4.Names.ServerName, $t4.State) -Evidence ([ordered]@{ state = $t4.State }) -Remediation 'Check again in a few minutes.'))
        }
    }

    if ($running['sqlvm01'] -and $state.RunnerSha256) {
        # The active profile (plan section 9.6). The T3 profile is a file on T1, so reading it doesn't wake T3.
        $profileTargets = @('T1') + @(if ($t3.Exists) { 'T3' }) + @(if ($null -ne $t4 -and $t4.Exists) { 'T4' })
        if ($Detail -and $hostVm -eq 'archost01' -and $running[$hostVm] -and 'archost01' -in $state.RunnerSentTo) {
            $profileTargets += 'T2'
        }
        foreach ($target in $profileTargets) {
            $read = $null
            try {
                $read = Invoke-DemoWorkloadCommand -Config $Config -Target $target -ArgumentList 'profile', 'get', '--json' -TimeoutSeconds 300 -Confirm:$false
            }
            catch {
                $results.Add((New-DemoResult -CheckId ('STATUS.PROFILE_{0}' -f $target) -Area 'workload' -Target $target -Status 'Warning' -Message ('{0}: the activity profile couldn''t be read: {1}' -f $target, $_.Exception.Message)))
                continue
            }
            # 'profile get --json' writes one JSON object, which Invoke-DemoWorkloadCommand returns as one record.
            $record = @($read.Records) | Where-Object { $null -ne (Get-DemoMemberValue -InputObject $_ -Name 'name') } | Select-Object -First 1
            $stdout = [string](Get-DemoMemberValue -InputObject $read -Name 'StdOut')
            if ($null -eq $record -or $read.Status -notin 'Pass', 'Warning') {
                $readStatus = if ($target -eq 'T2') { 'Warning' } else { [string]$read.Status }
                if ($readStatus -notin 'Pass', 'Warning') { $readStatus = 'Warning' }
                $results.Add((New-DemoResult -CheckId ('STATUS.PROFILE_{0}' -f $target) -Area 'workload' -Target $target -Status $readStatus -Message ('{0}: the activity profile couldn''t be read: {1}' -f $target, [string]$read.Result.message)))
                continue
            }
            $name = [string](Get-DemoMemberValue -InputObject $record -Name 'name')
            $description = [string](Get-DemoMemberValue -InputObject $record -Name 'description')
            $profileEvidence = [ordered]@{
                name      = $name
                expiresAt = [string](Get-DemoMemberValue -InputObject $record -Name 'expiresAt')
                setBy     = [string](Get-DemoMemberValue -InputObject $record -Name 'setBy')
                setAt     = [string](Get-DemoMemberValue -InputObject $record -Name 'setAt')
                onBoot    = [bool]$Config['activityProfileOnBoot']
            }
            $text = if ($description) { $description } else { $name }
            if ($target -eq 'T3' -and $name -ne 'off') {
                $text += ' While it''s active, T3 can''t auto-pause.'
            }
            # The profile host lane that serves the target (Phase 25b): a profile is only as good as the lane running it.
            $profileStatus = 'Pass'
            $message = '{0}: activity profile {1}' -f $target, $text
            $remediation = ''
            $hostNode = Get-DemoMemberValue -InputObject $record -Name 'host'
            if ($null -eq $hostNode) {
                $hostNode = Get-DemoRunnerHostNode -StdOut $stdout
            }
            if ($null -ne $hostNode) {
                $hostStatus = [string](Get-DemoMemberValue -InputObject $hostNode -Name 'status')
                $hostMessage = Protect-DemoText -Text ([string](Get-DemoMemberValue -InputObject $hostNode -Name 'message'))
                $profileEvidence['host'] = [ordered]@{
                    status    = $hostStatus
                    message   = $hostMessage
                    laneState = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $hostNode -Name 'lane') -Name 'state')
                }
                if ($hostStatus -in 'Warning', 'Fail') {
                    $profileStatus = $hostStatus
                    $message += (' Profile host: {0}' -f $hostMessage)
                    $remediation = 'The host replaces a stalled or failed lane by itself within about 5 minutes; run status.ps1 again. If it stays, run validate.ps1 -Area Workload for WORKLOAD.{0}.HOST, or stop-demo.ps1 and then start-demo.ps1, which restart the VM and its DbHubDemo-Workload task.' -f $target
                }
            }
            $results.Add((New-DemoResult -CheckId ('STATUS.PROFILE_{0}' -f $target) -Area 'workload' -Target $target -Status $profileStatus -Message $message -Evidence $profileEvidence -Remediation $remediation))
        }
        if ($Detail -and $t4Ready) {
            # T4's live view from T1's runner: connections against max_connections, sessions by state, waits,
            # blockers, the oldest transaction, and deadlocks (Database Hub has no query-level view for PostgreSQL).
            $live = Invoke-DemoWorkloadCommand -Config $Config -Target 'T4' -ArgumentList 'status', '--json', '--runs', '3' -TimeoutSeconds 300 -Confirm:$false
            # Run Command keeps the end of the output, and the server block is the end of the runner's JSON.
            $server = ConvertFrom-DemoT4ServerJson -Text ([string]$live.StdOut)
            if ($live.Status -in 'Pass', 'Warning' -and $null -ne $server) {
                $v = { param([string] $Name) Get-DemoMemberValue -InputObject $server -Name $Name }
                $message = 'T4 live: {0} of {1} connections ({2} left for applications); {3} active, {4} idle in transaction, {5} blocked; oldest transaction {6} s; {7} deadlock(s) since the statistics reset.' -f (& $v 'clientConnections'), (& $v 'maxConnections'), (& $v 'availableConnections'), (& $v 'active'), (& $v 'idleInTransaction'), (& $v 'blocked'), (& $v 'longestTransactionSeconds'), (& $v 'deadlocks')
                $results.Add((New-DemoResult -CheckId 'STATUS.T4.LIVE' -Area 'workload' -Target 'T4' -Status 'Pass' -Message $message -Evidence ([ordered]@{ server = $server })))
            }
            else {
                $results.Add((New-DemoResult -CheckId 'STATUS.T4.LIVE' -Area 'workload' -Target 'T4' -Status 'Warning' -Message ('T4''s live view from T1''s runner couldn''t be read: {0}' -f [string]$live.Result.message)))
            }
        }
    }

    if ($hostVm -eq 'archost01') {
        foreach ($item in @(Get-DemoArcCheck -Config $Config -Check 'Connected', 'DisconnectedDays' -Now $NowUtc)) {
            $results.Add($item)
        }
    }

    $bastion = Get-DemoBastionInfo -Config $Config
    if ($null -eq $bastion) {
        $results.Add((New-DemoResult -CheckId 'STATUS.BASTION' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('{0} couldn''t be listed, so Bastion wasn''t checked.' -f $resourceGroupName) -Remediation 'Run status.ps1 again; look for bas-* and pip-*-bastion in the portal, which bill by the hour.'))
    }
    elseif (-not $bastion.HostExists -and -not $bastion.PublicIpExists) {
        $results.Add((New-DemoResult -CheckId 'STATUS.BASTION' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'No Bastion host or Bastion public IP exists.'))
    }
    else {
        $prices = Get-DemoBastionHourlyPrice -Config $Config
        $hourly = 0.0
        $priced = $true
        if ($bastion.HostExists) {
            if ($null -eq $prices.Bastion) { $priced = $false } else { $hourly += [double]$prices.Bastion }
        }
        if ($bastion.PublicIpExists) {
            if ($null -eq $prices.PublicIp) { $priced = $false } else { $hourly += [double]$prices.PublicIp }
        }
        $costText = if ($priced) { 'about {0:N3} {1} per hour (list price, Azure Retail Prices API)' -f $hourly, $prices.Currency } else { 'by the hour (the Retail Prices API couldn''t be read)' }
        $evidence = [ordered]@{ bastionName = $bastion.Name; hostExists = $bastion.HostExists; publicIpName = $bastion.PublicIpName; publicIpExists = $bastion.PublicIpExists; expiresUtc = $bastion.ExpiresUtc; hourlyUsd = $(if ($priced) { [System.Math]::Round($hourly, 4) } else { $null }) }
        if ($bastion.Leftover) {
            $results.Add((New-DemoResult -CheckId 'STATUS.BASTION' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('The public IP {0} is left over from an interrupted Bastion delete and bills {1}.' -f $bastion.PublicIpName, $costText) -Evidence $evidence -Remediation 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly: it deletes the leftover public IP (the hourly bastion-cleanup workflow does too).' -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices'))
        }
        else {
            $expiry = if ($bastion.ExpiresUtc) { 'until ' + $bastion.ExpiresUtc } else { 'with no expiry tag' }
            $results.Add((New-DemoResult -CheckId 'STATUS.BASTION' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('{0} exists {1} and, with its public IP, bills {2}.' -f $bastion.Name, $expiry, $costText) -Evidence $evidence -Remediation 'When the setup-wizard step is done, run ./scripts/stop-demo.ps1 -RemoveBastionOnly; the bastion-cleanup workflow removes it after its expiry.' -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices'))
        }
    }

    if ((Get-DemoKeyVaultSetting -Config $Config).Enabled) {
        $results.Add((Get-DemoKeyVaultStatus -Config $Config -DeploymentId ([string]$state.Tags['deploymentId']) -VmName $hostVm -NowUtc $NowUtc))
    }

    # The optional on-demand activity control (ADR 0020): an active run, the webhook's expiry, and roles to grant again.
    if ((Get-DemoActivityControlSetting -Config $Config).Enabled) {
        $results.Add((Get-DemoActivityControlStatus -Config $Config -NowUtc $NowUtc))
    }

    # The Fabric workspace and lakehouse by name, and the capacity's state (Phase 26a, ADR 0021). Read-only.
    $results.Add((Get-DemoFabricStatus -Config $Config))

    # The T2 golden snapshot (ADR 0018): its guest's evaluation clock runs inside it.
    $goldenSnapshots = @()
    try {
        $goldenSnapshots = @(Get-DemoT2GoldenSnapshot -Config $Config -NowUtc $NowUtc)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The T2 golden snapshots couldn''t be listed: {0}' -f $_.Exception.Message)
    }
    $results.Add((Get-DemoT2GoldenStatus -Config $Config -Snapshot $goldenSnapshots))

    $cost = Get-DemoMonthToDateCost -Config $Config
    $goldenGroup = Get-DemoGoldenResourceGroupName -Config $Config
    $goldenCost = if ($goldenSnapshots.Count -gt 0) { Get-DemoMonthToDateCost -Config $Config -ResourceGroupName $goldenGroup } else { $null }
    if ($null -eq $cost) {
        $results.Add((New-DemoResult -CheckId 'STATUS.COST' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message 'Month-to-date cost couldn''t be read from Cost Management.' -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/query/usage'))
    }
    else {
        $ceiling = [double]$Config['monthlyCeilingUsd']
        $amount = [double]$cost.Amount + $(if ($null -ne $goldenCost) { [double]$goldenCost.Amount } else { 0.0 })
        $costStatus = if ($ceiling -gt 0 -and $amount -gt 0.8 * $ceiling) { 'Warning' } else { 'Pass' }
        $split = if ($null -ne $goldenCost) { ' ({0:N2} in {1}, {2:N2} in {3})' -f $cost.Amount, $resourceGroupName, $goldenCost.Amount, $goldenGroup } else { '' }
        $results.Add((New-DemoResult -CheckId 'STATUS.COST' -Area 'infra' -Target 'subscription' -Status $costStatus -Message ('Month-to-date cost: {0:N2} {1}{2} of the {3:N0} ceiling (Cost Management, actual cost; it lags by up to a day).' -f $amount, $cost.Currency, $split, $ceiling) -Evidence ([ordered]@{ amount = $amount; environmentAmount = $cost.Amount; goldenAmount = $(if ($null -ne $goldenCost) { $goldenCost.Amount } else { $null }); currency = $cost.Currency; ceiling = $ceiling }) -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/query/usage'))
    }

    $shutdown = Get-DemoNextShutdownUtc -Config $Config -NowUtc $NowUtc
    $results.Add((New-DemoResult -CheckId 'STATUS.SHUTDOWN' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('Next auto-shutdown: {0:yyyy-MM-dd HH:mm} UTC ({1} {2}).' -f $shutdown, $Config['autoShutdownTime'], $Config['autoShutdownTimeZone'])))
    return $results.ToArray()
}
