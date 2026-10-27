function Read-DemoValidationAzJson {
    <#
    .SYNOPSIS
    One read-only Azure CLI call through Invoke-DemoAz, parsed as JSON. Internal.

    .DESCRIPTION
    Returns Ok, Value, NotFound, and Error. Value keeps an empty array as an empty array, so a caller can tell
    an empty list from a failed read (Invoke-DemoAz -AsJson returns $null for both).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList
    )

    $arguments = [System.Collections.Generic.List[string]]::new([string[]]$ArgumentList)
    if (-not ($arguments.Contains('--output') -or $arguments.Contains('-o'))) {
        $arguments.AddRange([string[]]@('--output', 'json'))
    }
    $result = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList $arguments.ToArray() -AllowFailure
    if ($result.ExitCode -ne 0) {
        $errorText = Protect-DemoText -Text ([string]$result.StdErr).Trim()
        return [pscustomobject]@{ Ok = $false; Value = $null; NotFound = ($errorText -match '(?i)NotFound|could not be found|was not found|\(404\)'); Error = $errorText }
    }
    $value = $null
    $text = [string]$result.StdOut
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        $value = ConvertFrom-Json -InputObject $text -Depth 64 -NoEnumerate
    }
    [pscustomobject]@{ Ok = $true; Value = $value; NotFound = $false; Error = '' }
}

function Get-DemoValidationKeyVaultOptIn {
    <#
    .SYNOPSIS
    The opt-in Key Vault for the one-time T2 host password (keyVault.enabled, Phase 13; ADR 0009) as the
    Security area expects it: Enabled, the vault's Name when it's known, and a Pattern that matches it. Internal.

    .DESCRIPTION
    Phase 13's Get-DemoKeyVaultSetting and Get-DemoKeyVaultName decide when the module has them. Without
    them, keyVault.enabled in the configuration decides, and any kv-<name>-<deploymentId> vault matches.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $config = $Context.Config
    if (Get-Command -Name 'Get-DemoKeyVaultSetting' -CommandType Function -ErrorAction SilentlyContinue) {
        $enabled = [bool](Get-DemoKeyVaultSetting -Config $config).Enabled
    }
    else {
        $section = $config['keyVault']
        $enabled = ($section -is [System.Collections.IDictionary]) -and [bool]$section['enabled']
    }
    $name = ''
    $pattern = ''
    if ($enabled -and $Context.DeploymentId -match '^[a-z0-9]{6}$') {
        if (Get-Command -Name 'Get-DemoKeyVaultName' -CommandType Function -ErrorAction SilentlyContinue) {
            $name = [string](Get-DemoKeyVaultName -Config $config -DeploymentId $Context.DeploymentId)
        }
        $pattern = if ($name) { '^{0}$' -f [regex]::Escape($name) } else { '^kv-[a-z0-9-]+-{0}$' -f $Context.DeploymentId }
    }
    [pscustomobject]@{ Enabled = $enabled; Name = $name; Pattern = $pattern }
}

function New-DemoValidationContext {
    <#
    .SYNOPSIS
    What every validation area shares, read once: the resource group and its tags, the deploymentId, the T2
    target, and caches for VM power states, health.json reads, and T3's state. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only; the Azure calls it makes are reads.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string[]] $Target = @('T1', 'T2', 'T3', 'T4'),

        [AllowEmptyString()]
        [string] $DeploymentId = '',

        [AllowNull()]
        [System.Collections.Generic.List[object]] $Results
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroup = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $group = Read-DemoValidationAzJson -SubscriptionId $subscriptionId -ArgumentList @('group', 'show', '--name', $resourceGroup)
    $tags = @{}
    $source = Get-DemoMemberValue -InputObject $group.Value -Name 'tags'
    if ($null -ne $source) {
        foreach ($property in $source.PSObject.Properties) {
            $tags[$property.Name] = [string]$property.Value
        }
    }
    if (-not $DeploymentId -and [string]$tags['deploymentId'] -match '^[a-z0-9]{6}$') {
        $DeploymentId = [string]$tags['deploymentId']
    }
    $arc = Get-DemoArcTarget -Config $Config
    $vmNames = [ordered]@{}
    if ('T1' -in $Target) {
        $vmNames['T1'] = 'sqlvm01'
    }
    if ('T2' -in $Target) {
        $vmNames['T2'] = $arc.HostVmName
    }
    if ($null -eq $Results) {
        $Results = [System.Collections.Generic.List[object]]::new()
    }

    [pscustomobject]@{
        PSTypeName        = 'DbHubDemo.ValidationContext'
        Config            = $Config
        SubscriptionId    = $subscriptionId
        ResourceGroup     = $resourceGroup
        GroupExists       = [bool]$group.Ok
        GroupNotFound     = [bool]$group.NotFound
        GroupError        = [string]$group.Error
        Tags              = $tags
        DeploymentId      = $DeploymentId
        Target            = @($Target)
        Arc               = $arc
        VmNames           = $vmNames
        VmStates          = @{}
        Health            = @{}
        T3                = $null
        NetworkMode       = ''
        NetworkModeSource = ''
        T3UseFreeLimit    = $null
        Results           = $Results
    }
}

function Get-DemoValidationVmState {
    <#
    .SYNOPSIS
    A demo VM's power state from its instance view ('az vm get-instance-view'), read once per validation:
    running, deallocated, stopped, starting, stopping, deallocating, unknown, or not found. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    if ($Context.VmStates.ContainsKey($VmName)) {
        return $Context.VmStates[$VmName]
    }
    $read = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('vm', 'get-instance-view', '--resource-group', $Context.ResourceGroup, '--name', $VmName)
    $codes = @(foreach ($status in (Get-DemoMemberList -InputObject (Get-DemoMemberValue -InputObject $read.Value -Name 'instanceView') -Name 'statuses')) {
            [string](Get-DemoMemberValue -InputObject $status -Name 'code')
        })
    $power = @($codes | Where-Object { $_ -like 'PowerState/*' } | Select-Object -First 1)
    $powerState = if ($power.Count -gt 0) {
        $power[0].Substring('PowerState/'.Length).ToLowerInvariant()
    }
    elseif ($read.NotFound) {
        'not found'
    }
    else {
        'unknown'
    }
    $state = [pscustomobject]@{
        Name              = $VmName
        Exists            = [bool]$read.Ok
        PowerState        = $powerState
        Running           = $powerState -eq 'running'
        ProvisioningState = [string](Get-DemoMemberValue -InputObject $read.Value -Name 'provisioningState')
        Error             = [string]$read.Error
    }
    $Context.VmStates[$VmName] = $state
    return $state
}

function New-DemoValidationStoppedResult {
    <#
    .SYNOPSIS
    The result for a check that needs a running VM when the VM isn't running. Stopped VMs are expected (the
    nightly auto-shutdown deallocates them), so that's a Warning with the start command, never a Fail; only a
    VM that doesn't exist fails. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $CheckId,

        [Parameter(Mandatory)]
        [string] $Area,

        [Parameter(Mandatory)]
        [string] $Target,

        [Parameter(Mandatory)]
        [pscustomobject] $VmState,

        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [Parameter(Mandatory)]
        [string] $Checks,

        [switch] $EvaluationOnly
    )

    $vm = $VmState.Name
    $start = 'az vm start --resource-group {0} --name {1} --subscription {2}' -f $Context.ResourceGroup, $vm, $Context.SubscriptionId
    $again = 'then run validate.ps1 again'
    $status = 'Warning'
    switch ($VmState.PowerState) {
        'not found' {
            $status = 'Fail'
            $message = '{0} doesn''t exist in {1}, so {2} can''t run.' -f $vm, $Context.ResourceGroup, $Checks
            $remediation = 'Deploy it with ./scripts/deploy.ps1 (deploy.ps1 -Resume continues a stopped deployment).'
        }
        'deallocated' {
            $message = '{0} is deallocated (the nightly auto-shutdown or stop-demo.ps1 deallocates it), so {1} can''t run; start it to run them.' -f $vm, $Checks
            $remediation = 'Start the demo with ./scripts/start-demo.ps1, or run: {0}; {1}.' -f $start, $again
        }
        'stopped' {
            $message = '{0} is stopped but not deallocated, so its compute still bills, and {1} can''t run.' -f $vm, $Checks
            $remediation = 'Start it ({0}) and {1}, or deallocate it with ./scripts/stop-demo.ps1.' -f $start, $again
        }
        { $_ -in 'starting', 'stopping', 'deallocating' } {
            $message = '{0} is {1}, so {2} can''t run yet.' -f $vm, $VmState.PowerState, $Checks
            $remediation = 'Wait a few minutes, {0}.' -f $again
        }
        default {
            $message = 'The power state of {0} couldn''t be read, so {1} didn''t run: {2}' -f $vm, $Checks, $(if ($VmState.Error) { $VmState.Error } else { 'no PowerState status.' })
            $remediation = 'Check the subscription guard and that you can read the resource group, {0}.' -f $again
        }
    }
    New-DemoResult -CheckId $CheckId -Area $Area -Target $Target -Status $status -Message $message -Evidence @{ vmName = $vm; powerState = $VmState.PowerState } -Remediation $remediation -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/states-billing' -EvaluationOnly:$EvaluationOnly
}

function Get-DemoValidationHealth {
    <#
    .SYNOPSIS
    A running VM's health.json summary (Get-DemoVmHealth through a read-only Run Command), read once per
    validation. Returns Health, or Error with the reason. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    if ($Context.Health.ContainsKey($VmName)) {
        return $Context.Health[$VmName]
    }
    try {
        $entry = [pscustomobject]@{ Health = (Get-DemoVmHealth -Config $Context.Config -VmName $VmName -View Summary -TimeoutSeconds 120); Error = '' }
    }
    catch {
        $entry = [pscustomobject]@{ Health = $null; Error = (Protect-DemoText -Text $_.Exception.Message) }
    }
    $Context.Health[$VmName] = $entry
    return $entry
}

function Get-DemoValidationRunCommandNote {
    # Why a read-only Run Command may not finish, for messages. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $ErrorText
    )

    if ($ErrorText -match 'OperationNotAllowed') {
        return 'Run Commands fail with OperationNotAllowed while a VM is deallocated (live finding, 2026-10-20).'
    }
    # Invoke-DemoVmRunCommand's error for a stale result (its Stale property).
    if ($ErrorText -match 'reported an earlier run') {
        return 'A managed Run Command created again soon after it was deleted can report the previous run instead of running; it was tried twice, a minute apart, and its result was ignored (live finding, 2026-10-21).'
    }
    return 'A policy-driven extension update, such as MDE.Windows, can hold a VM''s Run Commands for about 10 minutes (live finding, 2026-10-20).'
}

function Get-DemoValidationT3State {
    <#
    .SYNOPSIS
    Whether T3's logical server exists, its public network access, and the database's status (Online or
    Paused), read once per validation. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    if ($null -ne $Context.T3) {
        return $Context.T3
    }
    $names = Get-DemoT3Name -Config $Context.Config -DeploymentId $Context.DeploymentId -NoLookup
    $state = [pscustomobject]@{
        ServerName          = $names.ServerName
        DatabaseName        = $names.DatabaseName
        Known               = [bool]$names.ServerName
        Exists              = $false
        Missing             = $false
        PublicNetworkAccess = ''
        DatabaseStatus      = ''
        Error               = ''
    }
    if ($state.Known) {
        $server = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('sql', 'server', 'show', '--name', $names.ServerName, '--resource-group', $Context.ResourceGroup)
        $state.Exists = [bool]$server.Ok
        $state.Missing = [bool]$server.NotFound
        $state.Error = [string]$server.Error
        $state.PublicNetworkAccess = [string](Get-DemoMemberValue -InputObject $server.Value -Name 'publicNetworkAccess')
        if ($server.Ok) {
            $database = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('sql', 'db', 'show', '--name', $names.DatabaseName, '--server', $names.ServerName, '--resource-group', $Context.ResourceGroup)
            $state.DatabaseStatus = [string](Get-DemoMemberValue -InputObject $database.Value -Name 'status')
            if (-not $database.Ok -and $database.NotFound) {
                $state.Exists = $false
                $state.Missing = $true
            }
        }
    }
    $Context.T3 = $state
    return $state
}

function Get-DemoValidationNetworkMode {
    <#
    .SYNOPSIS
    The effective network mode for T3's checks and the cost estimate: the configured public or private; for
    auto, the policy inventory's resolution when preflight ran in this validation, otherwise the deployed
    server's public network access (Disabled means private). Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $configured = [string]$Context.Config['networkMode']
    if ($configured -in 'public', 'private') {
        $Context.NetworkMode = $configured
        $Context.NetworkModeSource = 'configuration'
    }
    elseif (-not $Context.NetworkMode) {
        $t3 = Get-DemoValidationT3State -Context $Context
        if ($t3.PublicNetworkAccess) {
            $Context.NetworkMode = if ($t3.PublicNetworkAccess -eq 'Disabled') { 'private' } else { 'public' }
            $Context.NetworkModeSource = 'the deployed T3 server'
        }
        else {
            $Context.NetworkMode = 'private'
            $Context.NetworkModeSource = 'assumed (private works under any policy)'
        }
    }
    return $Context.NetworkMode
}

function Get-DemoValidationQuietReason {
    <#
    .SYNOPSIS
    Why a target sends no telemetry by design right now, or an empty string: its VM isn't running, or T3 is
    paused or removed. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target
    )

    if ($Target -eq 'T4') {
        $t4 = Get-DemoT4State -Config $Context.Config -DeploymentId ([string]$Context.DeploymentId)
        if (-not $t4.Exists) {
            return 'T4 isn''t deployed now'
        }
        if ($t4.State -ne 'Ready') {
            return ('T4 is {0}' -f $t4.State)
        }
        return ''
    }
    if ($Target -eq 'T3') {
        $t3 = Get-DemoValidationT3State -Context $Context
        if ($t3.Missing) {
            return 'T3 isn''t deployed now'
        }
        if ($t3.DatabaseStatus -match '(?i)^paus') {
            return ('T3 is {0} (serverless auto-pause)' -f $t3.DatabaseStatus)
        }
        return ''
    }
    $vmName = if ($Target -eq 'T1') { 'sqlvm01' } else { $Context.Arc.HostVmName }
    $state = Get-DemoValidationVmState -Context $Context -VmName $vmName
    if (-not $state.Running) {
        return ('{0} is {1}' -f $vmName, $state.PowerState)
    }
    return ''
}

function Test-DemoValidationWorkloadBound {
    <#
    .SYNOPSIS
    WORKLOAD.<target>.BOUNDS from the runner's 'status --json' document: every running scenario has a
    deadline within its maximum duration and isn't past it, and an activity profile other than off has an
    end time (ADR 0010). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target,

        [AllowEmptyString()]
        [string] $StdOut,

        [datetime] $NowUtc = [System.DateTime]::UtcNow
    )

    $checkId = 'WORKLOAD.{0}.BOUNDS' -f $Target
    $docUrl = 'https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-sessions-transact-sql'
    $document = $null
    $start = ([string]$StdOut).IndexOf('{')
    $end = ([string]$StdOut).LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        try {
            $document = $StdOut.Substring($start, $end - $start + 1) | ConvertFrom-Json -Depth 16
        }
        catch {
            $document = $null
        }
    }
    if ($null -eq $document -or $null -eq (Get-DemoMemberValue -InputObject $document -Name 'profile')) {
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target $Target -Status 'Warning' -Message ('The runner''s status for {0} couldn''t be parsed (a Run Command keeps only the last 4,096 bytes of output), so the scenario bounds weren''t checked.' -f $Target) -Remediation ('Run Invoke-DemoWorkloadCommand -Target {0} -ArgumentList status, --runs, 3 and read the deadlines.' -f $Target) -DocUrl $docUrl)
    }

    $profileNode = Get-DemoMemberValue -InputObject $document -Name 'profile'
    $profileName = [string](Get-DemoMemberValue -InputObject $profileNode -Name 'name')
    $expires = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $profileNode -Name 'expiresAt')
    $failures = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($profileName -and $profileName -ne 'off' -and $null -eq $expires) {
        $warnings.Add(('the activity profile ''{0}'' has no end time' -f $profileName))
    }
    $allRuns = Get-DemoMemberList -InputObject $document -Name 'runs'
    $running = @($allRuns | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'status') -eq 'Running' })
    $runEvidence = [System.Collections.Generic.List[object]]::new()
    foreach ($run in $running) {
        $runId = [string](Get-DemoMemberValue -InputObject $run -Name 'runId')
        $started = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $run -Name 'startedAt')
        $deadline = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $run -Name 'deadlineAt')
        $maximum = [int](Get-DemoMemberValue -InputObject $run -Name 'maxDurationSeconds')
        if ($null -eq $deadline) {
            $failures.Add(('run {0} has no deadline' -f $runId))
        }
        elseif ($null -ne $started -and $maximum -gt 0 -and ($deadline - $started).TotalSeconds -gt ($maximum + 60)) {
            $failures.Add(('run {0} ends {1:N0} seconds after it started, beyond its {2}-second maximum' -f $runId, ($deadline - $started).TotalSeconds, $maximum))
        }
        elseif ($deadline -lt $NowUtc.AddMinutes(-5)) {
            $warnings.Add(('run {0} is still Running {1:N0} minutes after its deadline' -f $runId, ($NowUtc - $deadline).TotalMinutes))
        }
        $runEvidence.Add([ordered]@{ runId = $runId; scenario = [string](Get-DemoMemberValue -InputObject $run -Name 'scenario'); deadlineAt = [string](Get-DemoMemberValue -InputObject $run -Name 'deadlineAt'); maxDurationSeconds = $maximum })
    }
    $evidence = [ordered]@{
        profile          = $profileName
        profileExpiresAt = if ($expires) { $expires.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { $null }
        runningRuns      = $running.Count
        runs             = $runEvidence.ToArray()
        demoSessions     = (Get-DemoMemberList -InputObject $document -Name 'demoSessions').Count
    }
    if ($failures.Count -gt 0) {
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target $Target -Status 'Fail' -Message ('A scenario on {0} isn''t bounded: {1}.' -f $Target, ($failures -join '; ')) -Evidence $evidence -Remediation ('Stop it: Invoke-DemoWorkloadCommand -Target {0} -ArgumentList stop; then report the run (ADR 0010).' -f $Target) -DocUrl $docUrl)
    }
    if ($warnings.Count -gt 0) {
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target $Target -Status 'Warning' -Message ('The workload on {0} needs a look: {1}.' -f $Target, ($warnings -join '; ')) -Evidence $evidence -Remediation ('Set the profile with an end time (Invoke-DemoWorkloadCommand -Target {0} -ArgumentList profile, set, --name, <profile>, --not-after, {{{{NEXT_SHUTDOWN}}}}), or stop the late run.' -f $Target) -DocUrl $docUrl)
    }
    $profileText = if ($profileName -eq 'off' -or -not $profileName) { 'the activity profile is off' } else { 'the activity profile ''{0}'' ends at {1:u}' -f $profileName, $expires }
    return (New-DemoResult -CheckId $checkId -Area 'workload' -Target $Target -Status 'Pass' -Message ('{0} running scenario(s) on {1}, each within its deadline and maximum duration; {2}.' -f $running.Count, $Target, $profileText) -Evidence $evidence -DocUrl $docUrl)
}

function ConvertFrom-DemoRunnerDocument {
    <#
    .SYNOPSIS
    The JSON object in a runner command's standard output (first '{' to last '}'), or $null when there's none or
    it doesn't parse (a Run Command keeps only the output's tail). Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $StdOut
    )

    $text = [string]$StdOut
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) {
        return $null
    }
    try {
        return ($text.Substring($start, $end - $start + 1) | ConvertFrom-Json -Depth 16)
    }
    catch {
        Write-Verbose -Message 'The runner output is not one whole JSON document.'
        return $null
    }
}

function Get-DemoRunnerHostNode {
    <#
    .SYNOPSIS
    The 'host' node of the runner's 'status --json' or 'profile get --json' output (Phase 25b): the profile host
    lane's ADR 0012 status, derived on the VM from host-lanes.json. The runner writes it last, so it's found even
    when a Run Command kept only the output's tail and the whole document no longer parses. $null when there's
    none (a runner older than Phase 25b). Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $StdOut
    )

    $document = ConvertFrom-DemoRunnerDocument -StdOut $StdOut
    $node = Get-DemoMemberValue -InputObject $document -Name 'host'
    if ($null -ne $node) {
        return $node
    }
    $text = [string]$StdOut
    $index = $text.LastIndexOf('"host":')
    $open = if ($index -ge 0) { $text.IndexOf('{', $index) } else { -1 }
    if ($open -lt 0) {
        return $null
    }
    # The node's own braces, skipping any inside its strings.
    $depth = 0
    $inString = $false
    $escaped = $false
    for ($i = $open; $i -lt $text.Length; $i++) {
        $character = $text[$i]
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            }
            elseif ($character -eq [char]'\') {
                $escaped = $true
            }
            elseif ($character -eq [char]'"') {
                $inString = $false
            }
            continue
        }
        if ($character -eq [char]'"') {
            $inString = $true
        }
        elseif ($character -eq [char]'{') {
            $depth++
        }
        elseif ($character -eq [char]'}') {
            $depth--
            if ($depth -eq 0) {
                try {
                    return ($text.Substring($open, $i - $open + 1) | ConvertFrom-Json -Depth 8)
                }
                catch {
                    Write-Verbose -Message 'The runner''s host node doesn''t parse.'
                    return $null
                }
            }
        }
    }
    return $null
}

function Test-DemoValidationWorkloadHost {
    <#
    .SYNOPSIS
    WORKLOAD.<target>.HOST from the runner's 'status --json' output (Phase 25b): the status the runner derived on
    the VM from host-lanes.json, the heartbeat of the profile host (DbHubDemo-Workload) that serves the target.
    Pass while the target's lane polls; Warning while it's slow, restarting, recently restarted, or failing to read
    its profile, while no host runs, or when the output has no host state; Fail while a profile is active and
    nothing runs it (the host ended without a clean stop, or its heartbeat is stale), or when the lane keeps failing
    (three restarts in an hour); Not selected when the host doesn't serve the target and its profile is off. T4's
    lane runs in T1's profile host, like T3's (Phase 24).
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $StdOut,

        [string] $VmName = ''
    )

    $checkId = 'WORKLOAD.{0}.HOST' -f $Target
    $docUrl = 'https://learn.microsoft.com/powershell/module/scheduledtasks/start-scheduledtask'
    if (-not $VmName) {
        $VmName = if ($Target -eq 'T2') { 'the T2 host' } else { 'sqlvm01' }
    }
    $where = if ($Target -eq 'T2') { 'in the guest on {0}' -f $VmName } else { 'on {0}' -f $VmName }
    $node = Get-DemoRunnerHostNode -StdOut $StdOut
    if ($null -eq $node) {
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target $Target -Status 'Warning' -Message ('The runner''s status for {0} has no profile host state: the runner {1} predates Phase 25b, or the output was cut short.' -f $Target, $where) -Remediation 'Deploy the current runner with deploy.ps1, then run validate.ps1 -Area Workload again.' -DocUrl $docUrl)
    }

    $status = [string](Get-DemoMemberValue -InputObject $node -Name 'status')
    if ($status -notin 'Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected') {
        $status = 'Warning'
    }
    $lane = Get-DemoMemberValue -InputObject $node -Name 'lane'
    $evidence = [ordered]@{
        processId           = Get-DemoMemberValue -InputObject $node -Name 'processId'
        heartbeatAt         = [string](Get-DemoMemberValue -InputObject $node -Name 'heartbeatAt')
        heartbeatAgeSeconds = Get-DemoMemberValue -InputObject $node -Name 'heartbeatAgeSeconds'
        processAlive        = Get-DemoMemberValue -InputObject $node -Name 'processAlive'
        stoppedAt           = [string](Get-DemoMemberValue -InputObject $node -Name 'stoppedAt')
        stopReason          = [string](Get-DemoMemberValue -InputObject $node -Name 'stopReason')
    }
    if ($null -ne $lane) {
        foreach ($name in 'state', 'generation', 'restarts', 'restartsLastHour', 'lastRestartReason', 'lastPollAgeSeconds', 'operation', 'consecutiveFailures', 'lastError', 'runningRuns') {
            $evidence[$name] = Get-DemoMemberValue -InputObject $lane -Name $name
        }
    }
    $message = '{0}: {1}' -f $Target, (Protect-DemoText -Text ([string](Get-DemoMemberValue -InputObject $node -Name 'message')))
    $remediation = if ($status -in 'Warning', 'Fail') {
        'The host replaces a stalled or failed lane by itself within about 5 minutes; run validate.ps1 -Area Workload again. If it stays, restart the DbHubDemo-Workload task {0}: stop-demo.ps1, then start-demo.ps1, which restarts the VM and the task with it. The host''s log is C:\ProgramData\DbHubDemo\logs\workload-<yyyyMMdd>.log {0}.' -f $where
    }
    else {
        ''
    }
    return (New-DemoResult -CheckId $checkId -Area 'workload' -Target $Target -Status $status -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
}
