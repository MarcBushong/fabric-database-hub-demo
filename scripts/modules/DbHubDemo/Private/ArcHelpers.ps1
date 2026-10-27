function Get-DemoArcSetting {
    <#
    .SYNOPSIS
    Arc onboarding and SQL Server enabled by Azure Arc settings from config/versions.json (the arc and sqlVm
    sections, and the API versions the scripts call). Internal.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $arc = $versions['arc']
    $apiVersions = $versions['apiVersions']
    if ($null -eq $arc -or $null -eq $versions['sqlVm']) {
        throw 'config/versions.json has no arc or sqlVm section.'
    }
    $setting = @{
        MachineName           = [string]$arc['machineName']
        Cloud                 = [string]$arc['cloud']
        Agent                 = $arc['agent']
        SqlExtension          = $arc['sqlExtension']
        MonitoringApiVersion  = [string]$arc['monitoringApiVersion']
        MinimumCoresPerOse    = [int]$arc['billing']['minimumCoresPerOse']
        DocUrls               = $arc['docUrls']
        SqlVm                 = $versions['sqlVm']
        MachineApiVersion     = [string]$apiVersions['Microsoft.HybridCompute/machines']
        ExtensionApiVersion   = [string]$apiVersions['Microsoft.HybridCompute/machines/extensions']
        SqlInstanceApiVersion = [string]$apiVersions['Microsoft.AzureArcData/sqlServerInstances']
        SqlVmApiVersion       = [string]$apiVersions['Microsoft.SqlVirtualMachine/sqlVirtualMachines']
    }
    foreach ($key in 'MachineName', 'MonitoringApiVersion', 'MachineApiVersion', 'ExtensionApiVersion', 'SqlInstanceApiVersion') {
        if (-not $setting[$key]) {
            throw ('config/versions.json is missing the Arc setting {0}.' -f $key)
        }
    }
    return $setting
}

function Get-DemoArcTarget {
    <#
    .SYNOPSIS
    Names, IDs, and ARM URLs for T2's Arc resources, derived from the configuration. Internal.

    .DESCRIPTION
    In the default Nested mode the Run Commands go to the host archost01, which reaches the guest arcsql01 over
    PowerShell Direct. In the opt-in EvaluationOnlyAzureVm mode (ADR 0006) arcsql01 is itself an Azure VM, so
    the Run Commands go to it, and every result is labeled EVALUATION ONLY.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $setting = Get-DemoArcSetting
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $t2Mode = if ($Config.Contains('t2Mode') -and $Config['t2Mode']) { [string]$Config['t2Mode'] } else { 'Nested' }
    $installMode = if ($Config.Contains('t2SqlInstallMode') -and $Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'PaygWizard' }
    $evaluationOnly = $t2Mode -eq 'EvaluationOnlyAzureVm'
    $machineName = $setting.MachineName
    $hostVmName = if ($evaluationOnly) { $machineName } else { 'archost01' }
    $groupPath = '/subscriptions/{0}/resourceGroups/{1}' -f $subscriptionId, $resourceGroupName
    $machineId = '{0}/providers/Microsoft.HybridCompute/machines/{1}' -f $groupPath, $machineName
    $arm = 'https://management.azure.com'

    [pscustomobject]@{
        SubscriptionId      = $subscriptionId
        TenantId            = [string]$Config['tenantId']
        ResourceGroupName   = $resourceGroupName
        Location            = [string]$Config['location']
        T2Mode              = $t2Mode
        InstallMode         = $installMode
        EvaluationOnly      = $evaluationOnly
        MachineName         = $machineName
        HostVmName          = $hostVmName
        MachineId           = $machineId
        MachineUrl          = '{0}{1}?api-version={2}' -f $arm, $machineId, $setting.MachineApiVersion
        MachinesUrl         = '{0}{1}/providers/Microsoft.HybridCompute/machines?api-version={2}' -f $arm, $groupPath, $setting.MachineApiVersion
        ExtensionUrl        = '{0}{1}/extensions/{2}?api-version={3}' -f $arm, $machineId, $setting.SqlExtension['name'], $setting.ExtensionApiVersion
        SqlInstancesUrl     = '{0}{1}/providers/Microsoft.AzureArcData/sqlServerInstances?api-version={2}' -f $arm, $groupPath, $setting.SqlInstanceApiVersion
        SqlInstanceUrlStart = '{0}{1}/providers/Microsoft.AzureArcData/sqlServerInstances/' -f $arm, $groupPath
        Setting             = $setting
    }
}

function Get-DemoArcSqlInstanceUrl {
    # ARM URL of one Microsoft.AzureArcData/sqlServerInstances resource. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._-]{1,128}$')]
        [string] $Name,

        [string] $ApiVersion = ''
    )

    if (-not $ApiVersion) {
        $ApiVersion = $Target.Setting.SqlInstanceApiVersion
    }
    return ('{0}{1}?api-version={2}' -f $Target.SqlInstanceUrlStart, $Name, $ApiVersion)
}

function Get-DemoArcExpectation {
    <#
    .SYNOPSIS
    What each T2 install mode should produce in Azure (ADR 0006). Internal.

    .DESCRIPTION
    - PaygWizard: Standard edition with license type PAYG.
    - ProductKey: Standard or Enterprise with PAYG or Paid (Software Assurance), per the customer's attested
      entitlement; the resource-group tag sets PAYG at automatic deployment.
    - Developer: Developer edition. Monitoring isn't supported (Standard or Enterprise only), and the license
      type doesn't change billing: Developer usage is reported on a 0 USD meter (manage-license-billing).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PaygWizard', 'ProductKey', 'Developer')]
        [string] $InstallMode
    )

    switch ($InstallMode) {
        'PaygWizard' { [pscustomobject]@{ Editions = @('Standard'); LicenseTypes = @('PAYG'); MonitoringSupported = $true } }
        'ProductKey' { [pscustomobject]@{ Editions = @('Standard', 'Enterprise'); LicenseTypes = @('PAYG', 'Paid'); MonitoringSupported = $true } }
        default { [pscustomobject]@{ Editions = @('Developer'); LicenseTypes = @(); MonitoringSupported = $false } }
    }
}

function Test-DemoVersionAtLeast {
    <#
    .SYNOPSIS
    True when a dotted version string is at least the minimum, comparing each part as a number. Internal.

    .DESCRIPTION
    Extension versions such as 1.1.2504.99 and 2.0.229.0 have up to four parts; a missing part counts as 0.
    Anything that doesn't parse is false, never an error, so an unexpected preview response can't pass.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Version,

        [Parameter(Mandatory)]
        [string] $Minimum
    )

    $parse = {
        param([string] $Text)
        if ($Text -notmatch '^\s*v?(\d+)(\.\d+){0,3}\s*$') {
            return $null
        }
        $parts = @($Text.Trim().TrimStart('v').Split('.') | ForEach-Object { [long]$_ })
        while ($parts.Count -lt 4) {
            $parts += 0
        }
        return , $parts
    }
    $actual = & $parse $Version
    $wanted = & $parse $Minimum
    if ($null -eq $actual -or $null -eq $wanted) {
        return $false
    }
    for ($i = 0; $i -lt 4; $i++) {
        if ($actual[$i] -gt $wanted[$i]) {
            return $true
        }
        if ($actual[$i] -lt $wanted[$i]) {
            return $false
        }
    }
    return $true
}

function Get-DemoArcArmResource {
    <#
    .SYNOPSIS
    Reads one ARM resource with 'az rest --method get' through Invoke-DemoAz. Returns $null when it doesn't
    exist and throws a redacted error otherwise. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Url
    )

    $result = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $Url) -AllowFailure
    if ($result.ExitCode -eq 0) {
        if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
            return $null
        }
        return ($result.StdOut | ConvertFrom-Json -Depth 64)
    }
    if (Test-DemoAzNotFound -Text $result.StdErr) {
        return $null
    }
    throw ('Reading {0} failed: {1}' -f ($Url -replace '\?.*$', ''), (Protect-DemoText -Text ([string]$result.StdErr).Trim()))
}

function Get-DemoArmCollection {
    <#
    .SYNOPSIS
    Lists an ARM collection with 'az rest --method get', following nextLink. An empty or missing collection
    returns an empty array. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Url,

        [ValidateRange(1, 100)]
        [int] $MaxPages = 20
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Url
    for ($page = 0; $next -and $page -lt $MaxPages; $page++) {
        $response = Get-DemoArcArmResource -SubscriptionId $SubscriptionId -Url $next
        if ($null -eq $response) {
            break
        }
        $values = Get-DemoMemberValue -InputObject $response -Name 'value'
        foreach ($item in @($values)) {
            if ($null -ne $item) {
                $items.Add($item)
            }
        }
        $next = [string](Get-DemoMemberValue -InputObject $response -Name 'nextLink')
    }
    return , $items.ToArray()
}

function Remove-DemoArmResource {
    <#
    .SYNOPSIS
    Deletes one ARM resource with 'az rest --method delete' and waits until reads return Not Found. A 409
    Conflict is retried with backoff. Returns $true when the resource is gone. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Url,

        [ValidateRange(0, 7200)]
        [int] $WaitSeconds = 600,

        [ValidateRange(1, 300)]
        [int] $PollIntervalSeconds = 15
    )

    $resource = $Url -replace '\?.*$', ''
    if (-not $PSCmdlet.ShouldProcess($resource, 'Delete')) {
        return $false
    }
    $delete = Invoke-DemoAzWithConflictRetry -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', $Url) -Label ('Deleting {0}' -f $resource)
    if ($delete.ExitCode -ne 0 -and -not (Test-DemoAzNotFound -Text $delete.StdErr)) {
        throw ('Deleting {0} failed: {1}' -f $resource, (Protect-DemoText -Text ([string]$delete.StdErr).Trim()))
    }
    $attempts = [int][System.Math]::Max(1, [System.Math]::Ceiling($WaitSeconds / $PollIntervalSeconds))
    for ($i = 0; $i -le $attempts; $i++) {
        if ($null -eq (Get-DemoArcArmResource -SubscriptionId $SubscriptionId -Url $Url)) {
            return $true
        }
        if ($i -lt $attempts) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }
    return $false
}

function Set-DemoArmResource {
    <#
    .SYNOPSIS
    Creates or updates one ARM resource with 'az rest --method put --body @<file>', retrying a 409 Conflict
    with backoff. The body goes through a private temporary file, because cmd.exe can't pass JSON to az.cmd.
    Returns the parsed response. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Url,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Body
    )

    $resource = $Url -replace '\?.*$', ''
    if (-not $PSCmdlet.ShouldProcess($resource, 'Create or update')) {
        return $null
    }
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-arm'
    try {
        $bodyPath = Write-DemoPrivateFile -Directory $directory -Name 'body.json' -Content ($Body | ConvertTo-Json -Depth 32 -Compress)
        $put = Invoke-DemoAzWithConflictRetry -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'put', '--url', $Url, '--body', "@$bodyPath") -Label ('Writing {0}' -f $resource)
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    if ($put.ExitCode -ne 0) {
        throw ('Writing {0} failed: {1}' -f $resource, (Protect-DemoText -Text ([string]$put.StdErr).Trim()))
    }
    if ([string]::IsNullOrWhiteSpace($put.StdOut)) {
        return $null
    }
    return ($put.StdOut | ConvertFrom-Json -Depth 64)
}

function Select-DemoArcSqlInstance {
    <#
    .SYNOPSIS
    The Microsoft.AzureArcData/sqlServerInstances resources hosted on one Arc machine: the instance's
    containerResourceId is the machine's resource ID, compared without regard to case. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Instance = @(),

        [Parameter(Mandatory)]
        [string] $MachineId
    )

    $selected = @(foreach ($item in @($Instance)) {
            $properties = Get-DemoMemberValue -InputObject $item -Name 'properties'
            $container = [string](Get-DemoMemberValue -InputObject $properties -Name 'containerResourceId')
            if ([string]::Equals($container.TrimEnd('/'), $MachineId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $item
            }
        })
    return , $selected
}

function ConvertTo-DemoArcTagString {
    <#
    .SYNOPSIS
    The resource group's demo tags as the azcmagent --tags value: name=value pairs separated by commas.
    Internal.

    .DESCRIPTION
    Only the standard demo tags are carried to the Arc machine. A value with characters other than letters,
    digits, and . _ : / @ + - is left out (for example autoShutdown, which holds spaces), because azcmagent
    needs single quotes around such values and the Run Command command line can't carry them reliably.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Tag
    )

    if ($null -eq $Tag) {
        return ''
    }
    $pairs = foreach ($name in @('solution', 'environment', 'owner', 'purpose', 'costCenter', 'deploymentId')) {
        $value = $null
        foreach ($key in $Tag.Keys) {
            if ([string]::Equals([string]$key, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $value = [string]$Tag[$key]
            }
        }
        if ($value -and $value -match '^[A-Za-z0-9._:/@+-]{1,256}$') {
            '{0}={1}' -f $name, $value
        }
    }
    return (@($pairs) -join ',')
}

function Get-DemoArcOnboardingDecision {
    <#
    .SYNOPSIS
    The onboarding decision table (ADR 0005): what to do given the host's state, the guest agent's state, and
    the Azure machine resource. Pure; returns Action, Status, and Reason. Internal.

    .DESCRIPTION
    Actions, in the order they're checked:
    - ReportHostState: the host isn't in WaitingForArcOnboarding and -Force isn't set; nothing changes.
    - GuestUnreachable: the guest didn't answer over PowerShell Direct (or the probe failed).
    - GuestNotIsolated: the guest can reach IMDS (or, nested, the wire server); onboarding fails closed (ADR 0004).
    - AlreadyConnected: the agent is Connected to the expected machine, which exists in Azure; rewrite the marker.
    - ConnectedElsewhere: the agent is configured for another resource; manual action, nothing is deleted.
    - ConnectedUnverified: the agent says Connected but reports no resource details to compare; manual action.
    - AgentNotConnected: the agent is configured for the expected machine but isn't Connected right now (for
      example just after a host restart), and the machine exists; wait, nothing is deleted.
    - DisconnectLocalThenOnboard: the agent is configured for the expected machine, but the Azure resource
      was deleted; reset the agent locally (azcmagent disconnect --force-local-only), then onboard.
    - CleanupStaleThenOnboard: the agent has no resource (a rebuilt guest, or never connected) but the Azure
      machine exists and isn't Connected; delete its sqlServerInstances, then the machine (no documented
      cascade), then onboard. This prevents AZCM0044 and duplicates.
    - StaleMachineConnected: the same, but the Azure machine is Connected: another server checks in under that
      name (the original host, or another copy of a golden snapshot, ADR 0018); nothing is deleted (Fail).
    - Onboard: no agent connection and no Azure machine.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $HostState = '',

        [switch] $Force,

        [AllowNull()]
        [object] $Probe,

        [AllowNull()]
        [object] $Machine,

        [Parameter(Mandatory)]
        [string] $MachineName,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [switch] $EvaluationOnly
    )

    $decide = {
        param([string] $Action, [string] $Status, [string] $Reason)
        [pscustomobject]@{ Action = $Action; Status = $Status; Reason = $Reason }
    }
    $same = {
        param([string] $Left, [string] $Right)
        [string]::Equals([string]$Left, [string]$Right, [System.StringComparison]::OrdinalIgnoreCase)
    }

    if (-not $Force -and $HostState -ne 'WaitingForArcOnboarding') {
        return (& $decide 'ReportHostState' 'Warning' ("The host reports '{0}', not WaitingForArcOnboarding, so onboarding doesn't run now. Run configure-arc.ps1 again when the host waits for it, or use -Force." -f $HostState))
    }
    if ($null -eq $Probe -or -not [bool](Get-DemoMemberValue -InputObject $Probe -Name 'guestReachable')) {
        return (& $decide 'GuestUnreachable' 'Warning' 'The guest did not answer over PowerShell Direct; it may be starting. Run configure-arc.ps1 again in a few minutes.')
    }
    $imds = [bool](Get-DemoMemberValue -InputObject $Probe -Name 'imdsReachable')
    $wire = [bool](Get-DemoMemberValue -InputObject $Probe -Name 'wireServerReachable')
    if ($imds -or ($wire -and -not $EvaluationOnly)) {
        return (& $decide 'GuestNotIsolated' 'Fail' 'The guest can reach the Azure Instance Metadata Service or the wire server, so it would look like an Azure VM and could reach the host''s identity. Onboarding stops (fail closed); rerun the GuestHardening step (ADR 0004).')
    }

    $agentStatus = [string](Get-DemoMemberValue -InputObject $Probe -Name 'agentStatus')
    $agentName = [string](Get-DemoMemberValue -InputObject $Probe -Name 'agentResourceName')
    $agentGroup = [string](Get-DemoMemberValue -InputObject $Probe -Name 'agentResourceGroup')
    $agentSubscription = [string](Get-DemoMemberValue -InputObject $Probe -Name 'agentSubscriptionId')
    $agentVmId = [string](Get-DemoMemberValue -InputObject $Probe -Name 'agentVmId')
    $machineVmId = ''
    if ($null -ne $Machine) {
        $machineVmId = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Machine -Name 'properties') -Name 'vmId')
    }

    $hasIdentity = [bool]$agentName
    $matchesExpected = $false
    if ($hasIdentity) {
        $matchesExpected = (& $same $agentName $MachineName) -and
            (-not $agentGroup -or (& $same $agentGroup $ResourceGroupName)) -and
            (-not $agentSubscription -or (& $same $agentSubscription $SubscriptionId))
    }
    elseif ((& $same $agentStatus 'Connected')) {
        # The JSON keys of 'azcmagent show -j' beyond status aren't documented (TODO(verify)); fall back to vmId.
        if ($agentVmId -and $machineVmId -and (& $same $agentVmId $machineVmId)) {
            $hasIdentity = $true
            $matchesExpected = $true
        }
        else {
            return (& $decide 'ConnectedUnverified' 'Manual action required' 'The agent in the guest reports Connected, but not which resource it''s connected to, so nothing is changed. Run azcmagent show in the guest and compare it with the Azure machine.')
        }
    }

    if ($hasIdentity -and -not $matchesExpected) {
        return (& $decide 'ConnectedElsewhere' 'Fail' ("The agent in the guest is configured for '{0}' in resource group '{1}', not {2} in {3}. Nothing is deleted; run azcmagent disconnect in the guest, then configure-arc.ps1 again." -f $agentName, $agentGroup, $MachineName, $ResourceGroupName))
    }
    if ($hasIdentity -and $matchesExpected) {
        if ($null -eq $Machine) {
            return (& $decide 'DisconnectLocalThenOnboard' 'Pass' ('The agent is configured for {0}, but the Azure resource no longer exists; the agent is reset locally (azcmagent disconnect --force-local-only) and onboarded again.' -f $MachineName))
        }
        if (& $same $agentStatus 'Connected') {
            return (& $decide 'AlreadyConnected' 'Pass' ('The agent in the guest is already Connected to {0}; onboarding is skipped and the marker is written again.' -f $MachineName))
        }
        return (& $decide 'AgentNotConnected' 'Warning' ("The agent in the guest is configured for {0} but reports '{1}'. Nothing is deleted; check the guest's egress (azcmagent check) and run configure-arc.ps1 again." -f $MachineName, $agentStatus))
    }
    if ($null -ne $Machine) {
        # A Connected machine is checking in from somewhere else (the original host, or another copy of a golden
        # snapshot, ADR 0018): never delete it.
        $machineStatus = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Machine -Name 'properties') -Name 'status')
        if (& $same $machineStatus 'Connected') {
            return (& $decide 'StaleMachineConnected' 'Fail' ('The Azure machine {0} is Connected, but the guest''s agent has no identity: another server (the original host, or another copy of the golden snapshot) checks in as {0}. Nothing is deleted. Stop that server, or wait until the machine shows Disconnected (about 15 minutes after its last heartbeat), then run configure-arc.ps1 again.' -f $MachineName))
        }
        return (& $decide 'CleanupStaleThenOnboard' 'Pass' ('The Azure machine {0} exists but the guest''s agent isn''t connected to it (for example after a guest rebuild); its SQL Server instances and then the machine are deleted before onboarding, so azcmagent connect can''t fail with AZCM0044 or leave a duplicate.' -f $MachineName))
    }
    return (& $decide 'Onboard' 'Pass' ('The guest isn''t connected and no Azure machine named {0} exists; onboarding.' -f $MachineName))
}
