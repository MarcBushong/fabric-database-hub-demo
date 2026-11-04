# The activity profile a run uses, business-day's hourly incidents, and the switch from the interim baseline. The owner's
# decision of 2026-11-03 (ADR 0010): business-day is the default, so Database Hub's Performance page has problems to show.
# A run sets baseline first and switches to a profile with incidents only once its own Run Commands on a VM are done, so
# no incident slows them (the live finding of 2026-10-23: Run Commands on a busy VM took minutes).

function Get-DemoDefaultActivityProfile {
    # The schema's default for activityProfile (config/environment.schema.json): business-day since 2026-11-03. Reads
    # the schema each time, so it stays the one place the default is defined. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $schema = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/environment.schema.json') -Raw | ConvertFrom-Json -AsHashtable
    return [string]$schema['properties']['activityProfile']['default']
}

function Get-DemoActivityProfile {
    <#
    .SYNOPSIS
    The activity profile a run uses, and how it starts (ADR 0010). Pure, apart from reading the schema's default.
    Internal.

    .DESCRIPTION
    - Name: -Requested (start-demo.ps1 -ActivityProfile), else the configuration's activityProfile, else the schema's
      default, business-day (the owner's decision of 2026-11-03). Get-DemoConfig leaves activityProfile out of a
      configuration that doesn't set it, so a run can tell, and say once, that it uses the default.
    - Source: parameter, configuration, or default; Defaulted is true for default.
    - HasIncidents: business-day and incident:<scenario> run incidents; baseline and off don't.
    - Interim: what a run sets first, and what the VMs set by themselves (after a runner install, and at a boot with
      activityProfileOnBoot): baseline in place of a profile with incidents, so T3 stays awake and telemetry flows, but no
      incident slows the run's own Run Commands on a VM. The run switches to Name once those are done
      (Invoke-DemoActivitySwitch).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $Requested = ''
    )

    $source = 'default'
    $name = ''
    if ($Requested) {
        $source = 'parameter'
        $name = $Requested
    }
    elseif ($Config.Contains('activityProfile') -and -not [string]::IsNullOrWhiteSpace([string]$Config['activityProfile'])) {
        $source = 'configuration'
        $name = [string]$Config['activityProfile']
    }
    else {
        $name = Get-DemoDefaultActivityProfile
    }
    $incidents = $name -ceq 'business-day' -or $name.StartsWith('incident:', [System.StringComparison]::Ordinal)
    return [pscustomobject]@{
        Name         = $name
        Source       = $source
        Defaulted    = ($source -eq 'default')
        HasIncidents = $incidents
        Interim      = $(if ($incidents) { 'baseline' } else { $name })
    }
}

function Get-DemoBusinessDaySchedule {
    <#
    .SYNOPSIS
    The business-day profile's incidents, from scenarios/activity-profiles.json, which the runner embeds: each target,
    scenario, start minute past each UTC hour, and duration in minutes, sorted by target and start minute. -Target keeps
    only those targets. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string[]] $Target = @()
    )

    $definition = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'scenarios/activity-profiles.json') -Raw | ConvertFrom-Json -AsHashtable
    $node = $definition['profiles']['business-day']
    $cycle = [int]$node['cycleMinutes']
    $slots = foreach ($slot in @($node['incidents'])) {
        if ($Target.Count -gt 0 -and [string]$slot['target'] -notin $Target) {
            continue
        }
        [pscustomobject]@{
            Target          = [string]$slot['target']
            Scenario        = [string]$slot['scenario']
            StartMinute     = [int]$slot['startMinute']
            DurationMinutes = [int]$slot['durationMinutes']
            CycleMinutes    = $cycle
        }
    }
    return @($slots | Sort-Object -Property Target, StartMinute)
}

function Join-DemoActivityList {
    # "a", "a and b", or "a, b, and c". Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [string[]] $Item = @()
    )

    $items = @($Item | Where-Object { $_ })
    switch ($items.Count) {
        0 { return '' }
        1 { return $items[0] }
        2 { return ('{0} and {1}' -f $items[0], $items[1]) }
        default { return ('{0}, and {1}' -f (($items | Select-Object -First ($items.Count - 1)) -join ', '), $items[-1]) }
    }
}

function Format-DemoBusinessDaySchedule {
    <#
    .SYNOPSIS
    business-day's hourly incidents as text: for every target, "T1 at :10 and :40, T2 at :05, :20, :35, and :50, ...",
    or with -Target one target's, "at :05 (cpu-pressure, 8 minutes), :20 (missing-index, 8 minutes), ...". Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target = ''
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Target) {
        $slots = @(Get-DemoBusinessDaySchedule -Target $Target)
        return ('at {0} past each UTC hour' -f (Join-DemoActivityList -Item @($slots | ForEach-Object { ':{0} ({1}, {2} minutes)' -f $_.StartMinute.ToString('00', $invariant), $_.Scenario, $_.DurationMinutes })))
    }
    $parts = foreach ($group in @(Get-DemoBusinessDaySchedule | Group-Object -Property Target | Sort-Object -Property Name)) {
        '{0} at {1}' -f $group.Name, (Join-DemoActivityList -Item @($group.Group | ForEach-Object { ':{0}' -f $_.StartMinute.ToString('00', $invariant) }))
    }
    return ('{0} past each UTC hour' -f (Join-DemoActivityList -Item @($parts)))
}

function Get-DemoT3IncidentShare {
    # The share of each business-day cycle that T3 runs an incident (resource-governance and log-rate-pressure: 10 of
    # 60 minutes), from scenarios/activity-profiles.json, for the cost estimate's increment (ADR 0016). Internal.
    [CmdletBinding()]
    [OutputType([double])]
    param()

    $slots = @(Get-DemoBusinessDaySchedule -Target 'T3')
    if ($slots.Count -eq 0 -or [int]$slots[0].CycleMinutes -le 0) {
        return 0.0
    }
    $minutes = 0.0
    foreach ($slot in $slots) {
        $minutes += [double]$slot.DurationMinutes
    }
    return [System.Math]::Min(1.0, $minutes / [double]$slots[0].CycleMinutes)
}

function Get-DemoActivityProfileNotice {
    # The notice a run says once when the configuration doesn't set activityProfile (2026-11-03): '' otherwise. Pure.
    # Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $ActivityProfile
    )

    if (-not $ActivityProfile.Defaulted) {
        return ''
    }
    if ($ActivityProfile.Name -ceq 'business-day') {
        return 'activityProfile isn''t set, so this run uses the new default, business-day (incidents every hour); set it to baseline for the quieter demo.'
    }
    return ('activityProfile isn''t set, so this run uses the default, {0}.' -f $ActivityProfile.Name)
}

function New-DemoActivityProfileNotice {
    <#
    .SYNOPSIS
    The one-time notice for a run whose configuration doesn't set activityProfile: one console line and one
    <CheckPrefix>.ACTIVITYPROFILE result (Pass: nothing to fix), or nothing when the configuration sets it. preflight
    (deploy.ps1's included), a deploy.ps1 run that skips preflight, and start-demo.ps1 call it once. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record and logs one line; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $ActivityProfile,

        [Parameter(Mandatory)]
        [ValidateSet('PREFLIGHT', 'DEPLOY', 'START')]
        [string] $CheckPrefix
    )

    $notice = Get-DemoActivityProfileNotice -ActivityProfile $ActivityProfile
    if (-not $notice) {
        return $null
    }
    Write-DemoLog -Level Warning -Message $notice
    $evidence = [ordered]@{ activityProfile = $ActivityProfile.Name; source = $ActivityProfile.Source; schedule = (Format-DemoBusinessDaySchedule) }
    return (New-DemoResult -CheckId ('{0}.ACTIVITYPROFILE' -f $CheckPrefix) -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0} Its incidents run {1}; the cost checks count them (ADR 0016).' -f $notice, (Format-DemoBusinessDaySchedule)) -Evidence $evidence -Remediation 'To keep the quieter demo, set "activityProfile": "baseline" in the configuration.' -DocUrl 'https://learn.microsoft.com/fabric/database/hub/monitor-sql')
}

function Get-DemoActivitySummaryLine {
    <#
    .SYNOPSIS
    The "Activity:" line for deploy.ps1's DONE, start-demo.ps1, and the status page: what runs, where it shows, and how to
    choose the other profile. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $ActivityProfile
    )

    $now = './scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25'
    $name = [string]$ActivityProfile.Name
    if ($name -ceq 'business-day') {
        $default = if ($ActivityProfile.Defaulted) { ' (the default)' } else { '' }
        return ('Activity: business-day{0}: bounded incidents at fixed minutes every hour ({1}) show on Database Hub''s Performance page a few minutes after each starts; set activityProfile to baseline for a quiet demo. For one right now: {2}.' -f $default, (Format-DemoBusinessDaySchedule), $now)
    }
    if ($name -ceq 'baseline') {
        return ('Activity: baseline: the steady mix with no incidents, so the Performance page''s problem panels stay empty. business-day, the default, adds bounded incidents every hour (set activityProfile to business-day); for one right now: {0}.' -f $now)
    }
    if ($name -ceq 'off') {
        return ('Activity: off: no workload runs. Set activityProfile to business-day (the default) for bounded incidents every hour, or start one now: {0}.' -f $now)
    }
    return ('Activity: {0}: one bounded run of that scenario, with the baseline beside it. business-day, the default, runs bounded incidents every hour.' -f $name)
}

function Get-DemoProfileStatusNote {
    <#
    .SYNOPSIS
    The sentence status.ps1 adds to STATUS.PROFILE_<target> (2026-11-03): for business-day, the target's incidents and
    how to choose the quieter baseline; for a baseline that the configuration's profile with incidents hasn't replaced
    yet, that a run switches it and how to now; for a configured baseline, how to choose business-day. '' otherwise.
    Starts with a space. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target,

        [AllowEmptyString()]
        [string] $ActiveName = '',

        [Parameter(Mandatory)]
        [pscustomobject] $ActivityProfile
    )

    if ($ActiveName -ceq 'business-day') {
        return (' Bounded incidents run {0}; Database Hub''s Performance page shows each a few minutes after it starts. For a quiet demo, set activityProfile to baseline.' -f (Format-DemoBusinessDaySchedule -Target $Target))
    }
    if ($ActiveName -cne 'baseline') {
        return ''
    }
    if ($ActivityProfile.HasIncidents) {
        return (' The configuration asks for {0}: deploy.ps1 and start-demo.ps1 switch to it once their own Run Commands are done; to switch now: ./scripts/demo-control.ps1 -Target {1} -Scenario {0} -Duration 240.' -f $ActivityProfile.Name, $Target)
    }
    return ' No incidents run, so the Performance page''s problem panels stay empty; business-day, the default, adds bounded incidents every hour (set activityProfile to business-day).'
}

function Register-DemoActivitySwitch {
    <#
    .SYNOPSIS
    Notes that a VM may run the interim baseline because of this run (the run set it, or the VM set it itself after a
    runner install or at a boot), so the run switches that VM's targets at its end, or when it's stopped or fails
    (Send-DemoPendingActivitySwitch). In this process, and, from deploy.ps1's track processes, in the run's private handoff
    directory, which deploy.ps1 reads even after a stop (Ctrl+C). Never throws. Internal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('sqlvm01', 'archost01')]
        [string] $VmName,

        [AllowEmptyString()]
        [string] $HandoffPath = ''
    )

    $null = $script:DemoActivitySwitchVm.Add($VmName)
    if ($HandoffPath -and [System.IO.Directory]::Exists($HandoffPath)) {
        try {
            Write-DemoTrackHandoff -Path $HandoffPath -Name ('activity-{0}' -f $VmName) -Value ([pscustomobject]@{ VmName = $VmName; Utc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }) -Confirm:$false
        }
        catch {
            Write-DemoLog -Level Debug -Message ('The interim profile on {0} wasn''t handed over: {1}' -f $VmName, $_.Exception.Message)
        }
    }
}

function Clear-DemoActivitySwitch {
    # Forgets the VMs Register-DemoActivitySwitch noted in this process, at the start of a run. Only this process's
    # memory changes, so -WhatIf runs it too. Internal.
    [CmdletBinding()]
    param()

    $script:DemoActivitySwitchVm.Clear()
}

function Get-DemoActivitySwitchVm {
    # The VMs Register-DemoActivitySwitch noted and no switch has been sent to yet: in this process and in -HandoffPath.
    # Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyString()]
        [string] $HandoffPath = ''
    )

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in $script:DemoActivitySwitchVm) {
        $found.Add([string]$vm)
    }
    if ($HandoffPath -and [System.IO.Directory]::Exists($HandoffPath)) {
        foreach ($vm in 'sqlvm01', 'archost01') {
            if ($vm -notin $found -and (Test-Path -LiteralPath (Join-Path -Path $HandoffPath -ChildPath ('activity-{0}.xml' -f $vm)) -PathType Leaf)) {
                $found.Add($vm)
            }
        }
    }
    return @($found | Sort-Object -Unique)
}

function Get-DemoActivitySwitchTarget {
    <#
    .SYNOPSIS
    The targets a run switches from the interim baseline: those of the VMs it noted (Get-DemoActivitySwitchVm) that the
    configuration has (T1, T3, and T4 when t4Enabled on sqlvm01; T2 on archost01 in the nested mode), except a target
    whose <CheckPrefix>.PROFILE_<target> in -Result is Not selected: the run skipped it on purpose (not set up yet, or
    left alone). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [string[]] $VmName = @(),

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [ValidateSet('DEPLOY', 'START')]
        [string] $CheckPrefix = 'DEPLOY'
    )

    $targets = [System.Collections.Generic.List[string]]::new()
    if ('sqlvm01' -in $VmName) {
        $targets.Add('T1')
        $targets.Add('T3')
        if (Test-DemoT4Enabled -Config $Config) {
            $targets.Add('T4')
        }
    }
    if ('archost01' -in $VmName -and (Get-DemoHostVmName -Config $Config) -eq 'archost01') {
        $targets.Add('T2')
    }
    $skipped = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -match ('^{0}\.PROFILE_T[1-4]$' -f $CheckPrefix) -and [string]$_.status -eq 'Not selected' } | ForEach-Object { ([string]$_.checkId).Substring(([string]$_.checkId).Length - 2) })
    return @($targets | Where-Object { $_ -notin $skipped })
}

function Get-DemoProfileRunCommandScript {
    <#
    .SYNOPSIS
    The managed Run Command script that sets the activity profile of one VM's targets: the module's workload-control
    template once per target (Get-DemoWorkloadControlScript, action Runner, the request Set-DemoTargetProfile sends), as
    the on-demand control's runbook builds its scripts (ADR 0020). Each target prints one short DBHUBDEMO-WORKLOAD line,
    in order, with the target in its evidence: the template's own line is captured and cut to its status, the end of its
    message, and the runner's exit code, so the lines of up to four targets fit in the 4 KB of output the instance view
    keeps. After -NotAfterUtc the script changes nothing and prints an expired line per target, so one that a
    deallocation held back never changes a profile when the VM starts again. With -RetrySeconds, each target's request is
    tried again that many seconds apart until the runner sets it, until it says the target isn't set up, or until
    -NotAfterUtc (review of PR 16, 2026-11-04): on a VM that has just booted, T1's and T2's profiles live in a SQL Server
    that's still starting, and T2's behind a guest that boots after its host, and the runner retries only transient
    errors. T3's and T4's profiles are files on T1 (CommandLine.cs, Store), so with -RetrySeconds they're set first,
    before T1's retries, and only the last target is ever tried again. Each line's evidence has the attempts. Windows
    PowerShell 5.1. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string[]] $Target,

        [Parameter(Mandatory)]
        [ValidatePattern('^(off|baseline|business-day|incident:[a-z0-9][a-z0-9-]{0,47})$')]
        [string] $ProfileName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._@/-]{1,64}$')]
        [string] $RequestedBy,

        [Parameter(Mandatory)]
        [datetime] $NotAfterUtc,

        [ValidateRange(30, 1800)]
        [int] $RunnerTimeoutSeconds = 300,

        [ValidateRange(0, 120)]
        [int] $RetrySeconds = 0
    )

    $notAfter = $NotAfterUtc.ToUniversalTime()
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# DbHubDemo activity profiles (ADR 0010), generated by the DbHubDemo module; it holds no secrets.')
    $lines.Add(('$dbhubNotAfter = New-Object -TypeName System.DateTime -ArgumentList ([long]{0}), ([System.DateTimeKind]::Utc)' -f $notAfter.Ticks.ToString($invariant)))
    $lines.Add('if ([System.DateTime]::UtcNow -gt $dbhubNotAfter) {')
    foreach ($item in $Target) {
        $expired = [ordered]@{
            marker   = 'DBHUBDEMO-WORKLOAD'
            action   = 'Runner'
            status   = 'Not selected'
            message  = ('{0}: not run: the request to set {1} expired at {2:yyyy-MM-ddTHH:mm:ssZ} before the VM ran it.' -f $item, $ProfileName, $notAfter)
            evidence = [ordered]@{ target = $item; expired = $true }
        }
        $json = ConvertTo-Json -InputObject $expired -Depth 4 -Compress
        if ($json -match "'") {
            throw 'The expired line holds a single quote.'
        }
        $lines.Add(('    [Console]::Out.WriteLine(''DBHUBDEMO-WORKLOAD {0}'')' -f $json))
    }
    $lines.Add('}')
    $lines.Add('else {')
    $order = if ($RetrySeconds -gt 0) { @($Target | Where-Object { $_ -in 'T3', 'T4' }) + @($Target | Where-Object { $_ -in 'T1', 'T2' }) } else { $Target }
    foreach ($item in $order) {
        $arguments = @('profile', 'set', '--name', $ProfileName, '--requested-by', $RequestedBy)
        if ($ProfileName -ne 'off') {
            $arguments += @('--not-after', '{{NEXT_SHUTDOWN}}')
        }
        # The template's line, captured and cut short, so every target's line survives the instance view's 4 KB; with
        # -RetrySeconds, tried again until the runner sets it, says the target isn't set up, or the expiry comes.
        $lines.Add('$dbhubAttempts = 0')
        $lines.Add('while ($true) {')
        $lines.Add('$dbhubAttempts++')
        $lines.Add('$dbhubOut = [Console]::Out')
        $lines.Add('$dbhubWriter = New-Object -TypeName System.IO.StringWriter')
        $lines.Add('[Console]::SetOut($dbhubWriter)')
        $lines.Add('try {')
        $lines.Add((Get-DemoWorkloadControlScript -Action 'Runner' -Request @{ target = $item; arguments = $arguments; timeoutSeconds = $RunnerTimeoutSeconds }))
        $lines.Add('}')
        $lines.Add('finally {')
        $lines.Add('    [Console]::SetOut($dbhubOut)')
        $lines.Add('}')
        $lines.Add('$dbhubResult = $null')
        $lines.Add('foreach ($dbhubText in ($dbhubWriter.ToString() -split "`r?`n")) {')
        $lines.Add('    $dbhubAt = $dbhubText.IndexOf(''DBHUBDEMO-WORKLOAD {'')')
        $lines.Add('    if ($dbhubAt -ge 0) {')
        $lines.Add('        try { $dbhubResult = $dbhubText.Substring($dbhubAt + 19) | ConvertFrom-Json } catch { $dbhubResult = $null }')
        $lines.Add('    }')
        $lines.Add('}')
        if ($RetrySeconds -gt 0) {
            $lines.Add('$dbhubState = [string]::Empty')
            $lines.Add('$dbhubSaid = [string]::Empty')
            $lines.Add('if ($null -ne $dbhubResult) { $dbhubState = [string]$dbhubResult.status; $dbhubSaid = [string]$dbhubResult.message }')
            $lines.Add('if ($dbhubState -eq ''Pass'' -or $dbhubState -eq ''Warning'') { break }')
            $lines.Add('if ($dbhubSaid -match ''(?i)not installed|no workload runner|isn.t set up yet|no valid module file|has no T3 server|has no T4 server'') { break }')
            $lines.Add(('if ([System.DateTime]::UtcNow.AddSeconds({0}) -ge $dbhubNotAfter) {{ break }}' -f $RetrySeconds))
            $lines.Add(('Start-Sleep -Seconds {0}' -f $RetrySeconds))
        }
        else {
            $lines.Add('break')
        }
        $lines.Add('}')
        $lines.Add(('$dbhubShort = @{{ marker = ''DBHUBDEMO-WORKLOAD''; action = ''Runner''; status = ''Fail''; message = ''{0}: the runner printed no result line.''; evidence = @{{ target = ''{0}''; attempts = $dbhubAttempts }} }}' -f $item))
        $lines.Add('if ($null -ne $dbhubResult) {')
        $lines.Add('    $dbhubMessage = [string]$dbhubResult.message')
        $lines.Add('    if ($dbhubMessage.Length -gt 300) { $dbhubMessage = ''...'' + $dbhubMessage.Substring($dbhubMessage.Length - 300) }')
        $lines.Add('    $dbhubExit = $null')
        $lines.Add('    if ($null -ne $dbhubResult.evidence) { $dbhubExit = $dbhubResult.evidence.exitCode }')
        $lines.Add(('    $dbhubShort = @{{ marker = ''DBHUBDEMO-WORKLOAD''; action = ''Runner''; status = [string]$dbhubResult.status; message = $dbhubMessage; evidence = @{{ target = ''{0}''; exitCode = $dbhubExit; attempts = $dbhubAttempts }} }}' -f $item))
        $lines.Add('}')
        $lines.Add('[Console]::Out.WriteLine(''DBHUBDEMO-WORKLOAD '' + (ConvertTo-Json -InputObject $dbhubShort -Depth 4 -Compress))')
    }
    $lines.Add('}')
    return (($lines -join "`n") + "`n")
}

function ConvertFrom-DemoProfileRunCommandOutput {
    <#
    .SYNOPSIS
    The DBHUBDEMO-WORKLOAD lines in a profile Run Command's output, matched to -Target: by the target in a line's
    evidence, else in order from the end, because the instance view keeps only the output's last 4 KB
    (https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed). Returns a hashtable target -> the
    line's data (marker, action, status, message, evidence); a target whose line is missing has none. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Output,

        [Parameter(Mandatory)]
        [string[]] $Target
    )

    $parsed = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @(([string]$Output) -split '\r?\n')) {
        $index = $line.IndexOf('DBHUBDEMO-WORKLOAD {', [System.StringComparison]::Ordinal)
        if ($index -lt 0) {
            continue
        }
        try {
            $data = $line.Substring($index + 'DBHUBDEMO-WORKLOAD '.Length) | ConvertFrom-Json -AsHashtable -Depth 16
        }
        catch {
            continue
        }
        if ($data -is [System.Collections.IDictionary] -and [string]$data['marker'] -eq 'DBHUBDEMO-WORKLOAD') {
            $parsed.Add($data)
        }
    }
    $byTarget = @{}
    $unnamed = [System.Collections.Generic.List[object]]::new()
    foreach ($data in $parsed) {
        $evidence = $data['evidence']
        $named = if ($evidence -is [System.Collections.IDictionary]) { [string]$evidence['target'] } else { '' }
        if ($named -and $named -in $Target -and -not $byTarget.ContainsKey($named)) {
            $byTarget[$named] = $data
        }
        else {
            $unnamed.Add($data)
        }
    }
    # Lines without a target are in the targets' order; the output's start may be cut, so they line up from the end.
    $open = @($Target | Where-Object { -not $byTarget.ContainsKey($_) })
    $offset = $open.Count - $unnamed.Count
    for ($i = 0; $i -lt $unnamed.Count; $i++) {
        $position = $offset + $i
        if ($position -ge 0 -and $position -lt $open.Count) {
            $byTarget[$open[$position]] = $unnamed[$i]
        }
    }
    return $byTarget
}

function Send-DemoProfileRunCommand {
    <#
    .SYNOPSIS
    Sets the activity profile of several targets at once through one managed Run Command per VM, DbHubDemo-Profile (T1,
    T3, and T4 on sqlvm01; T2 through archost01), and waits for both VMs together, at most -WaitSeconds (ADR 0010).
    Returns one record per target, in -Target's order: Target, VmName, Outcome, Detail, Data, and Seconds. Internal.

    .DESCRIPTION
    - Managed Run Command runs a script asynchronously, beside the VM's other Run Commands
      (https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed), so both VMs work at once and
      the wait stays bounded however busy a VM is: on 2026-10-23 an action Run Command waited 654 seconds on a saturated
      sqlvm01 (ADR 0020).
    - One name per VM, replaced by each request: Azure runs a managed Run Command again when its script changes, and the
      script carries its own expiry, so they never pile up (25 per VM at most,
      https://learn.microsoft.com/azure/virtual-machines/run-command-overview) and none is left to delete;
      status.ps1 counts it as the scripts' own, like the bootstrap loader. Once its expiry (-ExpiresMinutes) passes, the
      script changes nothing (Get-DemoProfileRunCommandScript), and -RetrySeconds has the VM try each target again until
      then.
    - A state from an earlier request under the same name doesn't count: only an execution that started after this
      request's PUT, less a minute for the clocks.
    - Outcome: Set (the runner set the profile), NotSetUp (the target has no runner yet: T2 before SQL Server setup, or T3
      or T4 that T1 doesn't drive yet), Failed (the runner or the Run Command failed; Detail says why), TimedOut (no
      result within -WaitSeconds: the Run Command goes on, until its expiry), NotSent (Azure didn't accept it, for
      example on a VM that isn't running), or, with -WaitSeconds 0, Sent (accepted, not waited for; its Data has what
      Wait-DemoProfileRunCommand needs to wait for it later).
    - -OnSent runs with the VM's name as soon as Azure accepts that VM's request, before the next VM's, so a caller can
      forget a VM only once its request is in, even when a stop (Ctrl+C) ends this midway (review of PR 16, 2026-11-04).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string[]] $Target,

        [Parameter(Mandatory)]
        [ValidatePattern('^(off|baseline|business-day|incident:[a-z0-9][a-z0-9-]{0,47})$')]
        [string] $ProfileName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._@/-]{1,64}$')]
        [string] $RequestedBy,

        [ValidateRange(0, 1800)]
        [int] $WaitSeconds = 180,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10,

        [ValidateRange(5, 120)]
        [int] $ExpiresMinutes = 30,

        [ValidateRange(0, 120)]
        [int] $RetrySeconds = 0,

        [ValidateRange(30, 1800)]
        [int] $RunnerTimeoutSeconds = 300,

        [AllowNull()]
        [scriptblock] $OnSent = $null
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $hostVm = Get-DemoHostVmName -Config $Config
    $apiVersion = Get-DemoRunCommandApiVersion
    $sentUtc = [DateTime]::UtcNow
    $notBefore = $sentUtc.AddMinutes(-1)
    $expiresUtc = $sentUtc.AddMinutes($ExpiresMinutes)
    $deadline = $sentUtc.AddSeconds($WaitSeconds)
    $groups = [ordered]@{}
    foreach ($item in $Target) {
        $vm = if ($item -eq 'T2') { $hostVm } else { 'sqlvm01' }
        if (-not $groups.Contains($vm)) {
            $groups[$vm] = [System.Collections.Generic.List[string]]::new()
        }
        if (-not $groups[$vm].Contains($item)) {
            $groups[$vm].Add($item)
        }
    }
    $records = @{}
    $record = {
        param([string] $Item, [string] $Vm, [string] $Outcome, [string] $Detail, [object] $Data = $null)
        $records[$Item] = [pscustomobject]@{ Target = $Item; VmName = $Vm; Outcome = $Outcome; Detail = $Detail; Data = $Data; Seconds = [int]([DateTime]::UtcNow - $sentUtc).TotalSeconds }
    }
    $sent = [ordered]@{}
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-profile'
    try {
        foreach ($vm in @($groups.Keys)) {
            $script = Get-DemoProfileRunCommandScript -Target @($groups[$vm]) -ProfileName $ProfileName -RequestedBy $RequestedBy -NotAfterUtc $expiresUtc -RetrySeconds $RetrySeconds -RunnerTimeoutSeconds $RunnerTimeoutSeconds
            $body = [ordered]@{
                location   = [string]$Config['location']
                properties = [ordered]@{
                    source                          = [ordered]@{ script = $script }
                    asyncExecution                  = $true
                    treatFailureAsDeploymentFailure = $false
                    timeoutInSeconds                = 900
                }
            }
            $bodyPath = Write-DemoPrivateFile -Directory $directory -Name ('{0}.json' -f $vm) -Content ($body | ConvertTo-Json -Depth 6 -Compress)
            $url = '{0}/DbHubDemo-Profile?api-version={1}' -f (Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $vm), $apiVersion
            $put = $null
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                $put = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'put', '--url', $url, '--body', "@$bodyPath") -AllowFailure -TimeoutSeconds 60
                if ($put.ExitCode -eq 0 -or -not (Test-DemoAzConflict -Text ([string]$put.StdErr)) -or $WaitSeconds -le 0 -or [DateTime]::UtcNow.AddSeconds(10) -ge $deadline) {
                    break
                }
                Start-Sleep -Seconds 10
            }
            if ($put.ExitCode -eq 0) {
                $sent[$vm] = $url
                if ($null -ne $OnSent) {
                    $null = & $OnSent $vm
                }
                continue
            }
            $why = if (Test-DemoAzVmNotRunning -Text ([string]$put.StdErr)) { '{0} isn''t running' -f $vm } else { Get-DemoDeploymentErrorText -Text ([string]$put.StdErr) -MaxLength 300 }
            foreach ($item in $groups[$vm]) {
                & $record $item $vm 'NotSent' ('Azure didn''t accept the Run Command on {0}: {1}' -f $vm, $why)
            }
        }
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }

    foreach ($vm in $sent.Keys) {
        foreach ($item in $groups[$vm]) {
            & $record $item $vm 'Sent' ('Sent to {0}; it runs there when the VM gets to it.' -f $vm) ([pscustomobject]@{ Url = $sent[$vm]; NotBefore = $notBefore; SentUtc = $sentUtc; ExpiresUtc = $expiresUtc })
        }
    }
    if ($WaitSeconds -gt 0 -and $sent.Count -gt 0) {
        $waitable = @(foreach ($item in $Target) { if ($records.ContainsKey($item) -and $records[$item].Outcome -eq 'Sent') { $records[$item] } })
        $left = [int][System.Math]::Max(1, [System.Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds))
        foreach ($item in @(Wait-DemoProfileRunCommand -Config $Config -Record $waitable -WaitSeconds $left -PollSeconds $PollSeconds -ReportedWaitSeconds $WaitSeconds)) {
            $records[[string]$item.Target] = $item
        }
    }
    return @(foreach ($item in $Target) {
            if ($records.ContainsKey($item)) {
                $records[$item]
            }
        })
}

function Wait-DemoProfileRunCommand {
    <#
    .SYNOPSIS
    Waits for DbHubDemo-Profile Run Commands that Send-DemoProfileRunCommand sent without waiting (its Sent records, whose
    Data has the Run Command's URL and when it was sent), for every VM together, at most -WaitSeconds, and returns each
    target's record as a send that waits does: Set, NotSetUp, Failed, or TimedOut. Any other record, and one without a
    URL, is returned as it is. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Record = @(),

        [ValidateRange(1, 1800)]
        [int] $WaitSeconds = 180,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10,

        [ValidateRange(0, 3600)]
        [int] $ReportedWaitSeconds = 0
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    $shown = if ($ReportedWaitSeconds -gt 0) { $ReportedWaitSeconds } else { $WaitSeconds }
    $order = [System.Collections.Generic.List[string]]::new()
    $records = @{}
    $groups = [ordered]@{}
    foreach ($item in @($Record | Where-Object { $null -ne $_ })) {
        $name = [string]$item.Target
        $order.Add($name)
        $url = [string](Get-DemoMemberValue -InputObject $item.Data -Name 'Url')
        if ([string]$item.Outcome -ne 'Sent' -or -not $url) {
            $records[$name] = $item
            continue
        }
        $vm = [string]$item.VmName
        if (-not $groups.Contains($vm)) {
            $groups[$vm] = [pscustomobject]@{ Url = $url; NotBefore = (Get-DemoMemberValue -InputObject $item.Data -Name 'NotBefore'); SentUtc = (Get-DemoMemberValue -InputObject $item.Data -Name 'SentUtc'); Targets = [System.Collections.Generic.List[string]]::new() }
        }
        $groups[$vm].Targets.Add($name)
    }
    $addRecord = {
        param([string] $Item, [string] $Vm, [string] $Outcome, [string] $Detail, [object] $Data = $null)
        $from = $groups[$Vm].SentUtc
        $seconds = if ($from -is [datetime]) { [int]([DateTime]::UtcNow - $from).TotalSeconds } else { 0 }
        $records[$Item] = [pscustomobject]@{ Target = $Item; VmName = $Vm; Outcome = $Outcome; Detail = $Detail; Data = $Data; Seconds = $seconds }
    }
    $terminal = @('Succeeded', 'Failed', 'TimedOut', 'Canceled')
    $pending = [System.Collections.Generic.List[string]]::new([string[]]@($groups.Keys))
    while ($pending.Count -gt 0) {
        foreach ($vm in @($pending)) {
            $group = $groups[$vm]
            $state = Get-DemoRunCommandState -SubscriptionId $subscriptionId -Url $group.Url
            $startTime = Get-DemoMemberValue -InputObject $state -Name 'StartTime'
            $fresh = $null -eq $startTime -or $null -eq $group.NotBefore -or $startTime -ge $group.NotBefore
            $done = $state.Found -and $fresh -and ($state.ExecutionState -in $terminal -or $state.ProvisioningState -eq 'Failed')
            if (-not $done) {
                continue
            }
            $null = $pending.Remove($vm)
            $lines = ConvertFrom-DemoProfileRunCommandOutput -Output ([string]$state.Output) -Target @($group.Targets)
            foreach ($item in $group.Targets) {
                $data = $lines[$item]
                if ($null -eq $data) {
                    $detail = if ($state.ExecutionState -ne 'Succeeded') { 'the Run Command ended {0}{1}' -f $(if ($state.ExecutionState) { $state.ExecutionState } else { 'with provisioning state ' + $state.ProvisioningState }), $(if ($state.Error) { ': ' + $state.Error } else { '' }) } else { 'its result line isn''t in the output the Run Command kept' }
                    & $addRecord $item $vm 'Failed' $detail
                    continue
                }
                $status = [string]$data['status']
                $message = Protect-DemoText -Text ([string]$data['message'])
                if ($status -in 'Pass', 'Warning') {
                    & $addRecord $item $vm 'Set' $message $data
                }
                elseif (($item -eq 'T2' -and (Test-DemoT2NotSetUpText -Text $message)) -or $message -match '(?i)runner is not installed|has no T3 server|has no T4 server') {
                    & $addRecord $item $vm 'NotSetUp' $message $data
                }
                else {
                    & $addRecord $item $vm 'Failed' $message $data
                }
            }
        }
        if ($pending.Count -eq 0 -or [DateTime]::UtcNow -ge $deadline) {
            break
        }
        Start-Sleep -Seconds ([int][System.Math]::Max(1, [System.Math]::Min($PollSeconds, ($deadline - [DateTime]::UtcNow).TotalSeconds)))
    }
    foreach ($vm in $pending) {
        foreach ($item in $groups[$vm].Targets) {
            & $addRecord $item $vm 'TimedOut' ('{0} didn''t finish it within {1} seconds' -f $vm, $shown)
        }
    }
    return @(foreach ($item in $order) {
            if ($records.ContainsKey($item)) {
                $records[$item]
            }
        })
}

function Invoke-DemoActivitySwitch {
    <#
    .SYNOPSIS
    Switches targets from the interim baseline to the run's activity profile once the run's own Run Commands on their
    VMs are done (2026-11-03, ADR 0010): deploy.ps1 after DONE's checks, start-demo.ps1 at the warm-up's start. One
    managed Run Command per VM, at most -WaitSeconds for both (Send-DemoProfileRunCommand), and one
    <CheckPrefix>.INCIDENTS_<target> result each, never a Fail. Internal.

    .DESCRIPTION
    - Pass: the profile is set; its incidents start at their next fixed minute.
    - Not selected: the target has no runner yet, so there was nothing to switch.
    - Warning: the switch failed, wasn't accepted, or didn't finish in time (the Run Command then goes on, and does
      nothing after 30 minutes); the remediation gives the command that sets the profile.
    - -NoWait, for a run that's stopped (Ctrl+C) or failed: the Run Commands are only sent, in a few seconds, so no VM
      stays on the interim baseline; one console line says so, and nothing is returned, because nothing reads the
      results then. Sending them doesn't stop the run: a failure is logged.
    - -OnSent goes to Send-DemoProfileRunCommand: it runs for each VM once Azure accepts that VM's request.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $ActivityProfile,

        [AllowEmptyCollection()]
        [string[]] $Target = @(),

        [Parameter(Mandatory)]
        [ValidateSet('DEPLOY', 'START')]
        [string] $CheckPrefix,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._@/-]{1,64}$')]
        [string] $RequestedBy,

        [ValidateRange(1, 1800)]
        [int] $WaitSeconds = 180,

        [switch] $NoWait,

        [AllowNull()]
        [scriptblock] $OnSent = $null
    )

    $targets = @($Target | Where-Object { $_ } | Select-Object -Unique)
    if (-not $ActivityProfile.HasIncidents -or $targets.Count -eq 0) {
        return @()
    }
    $name = [string]$ActivityProfile.Name
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
    $hostVm = Get-DemoHostVmName -Config $Config
    $vmText = Join-DemoActivityList -Item @(@(if (@($targets | Where-Object { $_ -ne 'T2' }).Count -gt 0) { 'sqlvm01' }) + @(if ('T2' -in $targets) { $hostVm }))
    $verb = if ($targets.Count -eq 1) { 'switches' } else { 'switch' }
    if ($NoWait) {
        try {
            $sent = @(Send-DemoProfileRunCommand -Config $Config -Target $targets -ProfileName $name -RequestedBy $RequestedBy -WaitSeconds 0 -OnSent $OnSent)
            $failed = @($sent | Where-Object { $_.Outcome -ne 'Sent' })
            if ($failed.Count -eq 0) {
                Write-DemoLog -Level Warning -Message ('The run stopped before its end, so {0} was sent to {1} without waiting: {2} {3} from the interim baseline when the VM runs it.' -f $name, $vmText, (Join-DemoActivityList -Item $targets), $verb)
            }
            else {
                Write-DemoLog -Level Warning -Message ('The run stopped before its end, and {0} couldn''t be sent to every target ({1}); those keep the interim baseline until the next auto-shutdown. Set it with ./scripts/demo-control.ps1 -Target all -Scenario {0} -Duration 240.' -f $name, (($failed | ForEach-Object { '{0}: {1}' -f $_.Target, $_.Detail }) -join '; '))
            }
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The run stopped before its end, and {0} couldn''t be sent: {1}. The VMs keep the interim baseline until the next auto-shutdown; set it with ./scripts/demo-control.ps1 -Target all -Scenario {0} -Duration 240.' -f $name, (Protect-DemoText -Text $_.Exception.Message))
        }
        return @()
    }

    Write-DemoLog -Message ('This run''s own Run Commands on {0} are done, so {1} {2} from the interim baseline to {3} now.' -f $vmText, (Join-DemoActivityList -Item $targets), $verb, $name)
    $records = @()
    try {
        $records = @(Send-DemoProfileRunCommand -Config $Config -Target $targets -ProfileName $name -RequestedBy $RequestedBy -WaitSeconds $WaitSeconds -OnSent $OnSent)
    }
    catch {
        $problem = Protect-DemoText -Text $_.Exception.Message
        $records = @(foreach ($item in $targets) { [pscustomobject]@{ Target = $item; VmName = $(if ($item -eq 'T2') { $hostVm } else { 'sqlvm01' }); Outcome = 'NotSent'; Detail = $problem; Data = $null; Seconds = 0 } })
    }
    $results = foreach ($record in $records) {
        $item = [string]$record.Target
        $checkId = '{0}.INCIDENTS_{1}' -f $CheckPrefix, $item
        $evidence = [ordered]@{ profile = $name; interim = 'baseline'; vm = $record.VmName; outcome = $record.Outcome; seconds = $record.Seconds; runCommand = 'DbHubDemo-Profile' }
        $fix = './scripts/demo-control.ps1 -Target {0} -Scenario {1} -Duration 240 sets it (or ./scripts/start-demo.ps1 -ActivityProfile {1}); until then the baseline runs, until the next auto-shutdown.' -f $item, $name
        switch ($record.Outcome) {
            'Set' {
                $what = if ($name -ceq 'business-day') { 'business-day from now on, until two minutes before the next auto-shutdown: the baseline plus bounded incidents {0}' -f (Format-DemoBusinessDaySchedule -Target $item) } else { '{0} from now on: one bounded run of it, with the baseline beside it' -f $name }
                $message = '{0}: {1}. They started only once this run''s own Run Commands on {2} were done, so none slowed them; Database Hub shows each a few minutes after it starts.' -f $item, $what, $record.VmName
                if ($item -eq 'T3') {
                    $message += ' While it runs, T3''s serverless database stays awake and bills compute (ADR 0016).'
                }
                if ($ActivityProfile.Defaulted) {
                    $message += ' business-day is the default because activityProfile isn''t set; set it to baseline for the quieter demo.'
                }
                New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Pass' -Message $message -Evidence $evidence -DocUrl $docUrl
            }
            'NotSetUp' {
                New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Not selected' -Message ('{0}: not switched to {1}: {2}' -f $item, $name, $record.Detail) -Evidence $evidence -DocUrl $docUrl
            }
            'TimedOut' {
                New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Warning' -Message ('{0}: the switch to {1} was sent to {2}, but it didn''t finish within {3} seconds; the VM runs it when its Run Commands allow, within 30 minutes. ./scripts/status.ps1 shows the profile.' -f $item, $name, $record.VmName, $WaitSeconds) -Evidence $evidence -Remediation $fix -DocUrl $docUrl
            }
            default {
                New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Warning' -Message ('{0}: the switch to {1} failed: {2}.' -f $item, $name, $record.Detail) -Evidence $evidence -Remediation $fix -DocUrl $docUrl
            }
        }
    }
    return @($results)
}

function Send-DemoPendingActivitySwitch {
    <#
    .SYNOPSIS
    The switch for the VMs this process's run noted and hasn't switched yet (Get-DemoActivitySwitchVm), or for those of
    -VmName among them, which it then forgets: their targets (Get-DemoActivitySwitchTarget) get the run's activity profile
    through Invoke-DemoActivitySwitch. Returns its results; none with -NoWait or when nothing is pending. Internal.

    .DESCRIPTION
    Where a run switches (2026-11-03, ADR 0010):
    - deploy.ps1: after DONE's checks, whether the run is DONE or not, in both the parallel and the -Sequential paths,
      including a -Sequential run that stops at a Fail; and, with -NoWait, in Complete-DemoDeploymentRun, which ends
      every run, when the run ended before its switch (Ctrl+C, an error).
    - start-demo.ps1: at the warm-up's start, once its own Run Commands are done; a VM whose Run Commands the script still
      sends (-Interactive -ResetAdminPassword sets the host password afterward) is switched by the script after them; and
      with -NoWait when the start ends before its switch.
    A VM is forgotten once Azure accepts its request, and the rest once the switch returns: a stop (Ctrl+C) that ends the
    switch midway skips every catch block, so a VM forgotten before its request was in would leave the fallback (-NoWait)
    nothing to send and nothing to say (review of PR 16, 2026-11-04).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $ActivityProfile,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [Parameter(Mandatory)]
        [ValidateSet('DEPLOY', 'START')]
        [string] $CheckPrefix,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._@/-]{1,64}$')]
        [string] $RequestedBy,

        [AllowEmptyCollection()]
        [string[]] $VmName = @(),

        [ValidateRange(1, 1800)]
        [int] $WaitSeconds = 180,

        [switch] $NoWait
    )

    $pending = @(Get-DemoActivitySwitchVm)
    $vms = @(if ($VmName.Count -gt 0) { $pending | Where-Object { $_ -in $VmName } } else { $pending })
    if ($vms.Count -eq 0) {
        return @()
    }
    $targets = @(Get-DemoActivitySwitchTarget -Config $Config -VmName $vms -Result $Result -CheckPrefix $CheckPrefix)
    $forget = { param([string] $Vm) $null = $script:DemoActivitySwitchVm.Remove($Vm) }
    $switched = @(Invoke-DemoActivitySwitch -Config $Config -ActivityProfile $ActivityProfile -Target $targets -CheckPrefix $CheckPrefix -RequestedBy $RequestedBy -WaitSeconds $WaitSeconds -NoWait:$NoWait -OnSent $forget)
    # The switch returned, so each VM's outcome is reported (or logged); only a stop leaves a VM here.
    foreach ($vm in $vms) {
        & $forget $vm
    }
    return $switched
}

function Invoke-DemoActivityQuiet {
    <#
    .SYNOPSIS
    A run sets the interim baseline on a VM's targets before its own Run Commands there (2026-11-03, ADR 0010): on a VM
    that's already running, where an earlier start, or a deploy.ps1 that ended NOT DONE, can have left business-day's
    incidents running; and (-Started) on a VM the run started, as soon as it runs, because its profile host resumes the
    profile stored there about 2 minutes after the boot, while the run's own Run Commands go on (review of PR 16,
    2026-11-04). Run Commands on a busy VM took minutes (2026-10-23). Internal.

    .DESCRIPTION
    One managed Run Command per VM, which does nothing after 10 minutes. On a VM that's already running it's sent without
    waiting. On a VM the run started (-Started), its SQL Server, or for T2 its guest, can still be starting, so the VM
    tries each target every 15 seconds until it's set or the 10 minutes pass (Get-DemoProfileRunCommandScript
    -RetrySeconds), and the caller waits for it with Wait-DemoActivityInterim before its own Run Commands there (re-review
    of PR 16, 2026-11-04). Each VM is noted before its request goes out, so a stop (Ctrl+C) during the send still leaves it
    to the run's switch at its end, or to the one a stop or a failure sends, which brings the profile back; a VM Azure
    refused, which nothing else had noted, is forgotten again. -PassThru returns the send's records (Sent, or NotSent with
    why). Nothing for a profile without incidents. Never throws, apart from a stop.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $ActivityProfile,

        [AllowEmptyCollection()]
        [string[]] $VmName = @(),

        [AllowEmptyCollection()]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string[]] $Target = @(),

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._@/-]{1,64}$')]
        [string] $RequestedBy,

        [switch] $Started,

        [switch] $PassThru
    )

    $vms = @($VmName | Where-Object { $_ -in 'sqlvm01', 'archost01' } | Select-Object -Unique)
    if (-not $ActivityProfile.HasIncidents -or $vms.Count -eq 0) {
        return
    }
    $own = @(Get-DemoActivitySwitchTarget -Config $Config -VmName $vms)
    $targets = @(if ($Target.Count -gt 0) { $own | Where-Object { $_ -in $Target } } else { $own })
    if ($targets.Count -eq 0) {
        return
    }
    $hostVm = Get-DemoHostVmName -Config $Config
    $sending = @($targets | ForEach-Object { if ($_ -eq 'T2') { $hostVm } else { 'sqlvm01' } } | Select-Object -Unique | Where-Object { $_ -in $vms })
    $known = @(Get-DemoActivitySwitchVm)
    foreach ($vm in $sending) {
        Register-DemoActivitySwitch -VmName $vm
    }
    $reachedVms = @()
    $sent = @()
    try {
        $retry = if ($Started) { @{ RetrySeconds = 15; RunnerTimeoutSeconds = 120 } } else { @{} }
        $sent = @(Send-DemoProfileRunCommand -Config $Config -Target $targets -ProfileName $ActivityProfile.Interim -RequestedBy $RequestedBy -WaitSeconds 0 -ExpiresMinutes 10 @retry)
        $reached = @($sent | Where-Object { $_.Outcome -eq 'Sent' })
        $reachedVms = @($reached | ForEach-Object { [string]$_.VmName } | Select-Object -Unique)
        foreach ($vm in $sending) {
            if ($vm -notin $reachedVms -and $vm -notin $known) {
                $null = $script:DemoActivitySwitchVm.Remove($vm)
            }
        }
        if ($reachedVms.Count -gt 0) {
            $vmText = Join-DemoActivityList -Item $reachedVms
            $targetText = Join-DemoActivityList -Item @($reached | ForEach-Object { [string]$_.Target })
            $message = if ($Started) {
                '{0} started, so {1} get the interim {2} before this run''s own Run Commands there: its profile host resumes the profile stored there about 2 minutes after the boot. {3} tries every 15 seconds until it''s set, for at most 10 minutes, while its SQL Server starts; {4} comes back at the end.' -f $vmText, $targetText, $ActivityProfile.Interim, $(if ($reachedVms.Count -eq 1) { 'The VM' } else { 'Each VM' }), $ActivityProfile.Name
            }
            else {
                '{0} {1} already running, so {2} get the interim {3} first, without waiting: no incident slows this run''s own Run Commands there, and {4} comes back at the end.' -f $vmText, $(if ($reachedVms.Count -eq 1) { 'was' } else { 'were' }), $targetText, $ActivityProfile.Interim, $ActivityProfile.Name
            }
            Write-DemoLog -Message $message
        }
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The interim baseline wasn''t sent to {0}: {1}' -f (Join-DemoActivityList -Item $sending), (Protect-DemoText -Text $_.Exception.Message))
    }
    if ($PassThru) {
        return $sent
    }
}

function Wait-DemoActivityInterim {
    <#
    .SYNOPSIS
    Waits for the interim baseline Invoke-DemoActivityQuiet -Started sent to VMs the run started, so the run's own first
    Run Command on such a VM starts only once the baseline is set there or its bound has passed (re-review of PR 16,
    2026-11-04): every VM together, until its Run Command ends, at most until its 10-minute expiry plus one attempt and a
    margin. Returns one <CheckPrefix>.INTERIM_<target> per target: Pass when it's set, Not selected when the target has no
    runner yet, and a Warning with the exact commands when it wasn't set in time, failed, or wasn't accepted. Nothing for
    a profile without incidents, or without records. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $ActivityProfile,

        [AllowEmptyCollection()]
        [object[]] $Record = @(),

        [Parameter(Mandatory)]
        [ValidateSet('DEPLOY', 'START')]
        [string] $CheckPrefix,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10
    )

    $items = @($Record | Where-Object { $null -ne $_ })
    if (-not $ActivityProfile.HasIncidents -or $items.Count -eq 0) {
        return @()
    }
    $name = [string]$ActivityProfile.Name
    $interim = [string]$ActivityProfile.Interim
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
    # The last attempt can start just before the expiry and take the runner's 2 minutes, so the bound adds those and 30 s.
    $until = $null
    foreach ($item in $items) {
        $expires = Get-DemoMemberValue -InputObject $item.Data -Name 'ExpiresUtc'
        if ($expires -is [datetime] -and ($null -eq $until -or $expires -gt $until)) {
            $until = $expires
        }
    }
    if ($null -eq $until) {
        $until = [DateTime]::UtcNow.AddMinutes(10)
    }
    $waitSeconds = [int][System.Math]::Min(1800, [System.Math]::Max(1, [System.Math]::Ceiling(($until.AddSeconds(150) - [DateTime]::UtcNow).TotalSeconds)))
    $vms = @($items | Where-Object { $_.Outcome -eq 'Sent' } | ForEach-Object { [string]$_.VmName } | Select-Object -Unique)
    if ($vms.Count -gt 0) {
        Write-DemoLog -Message ('Waiting for the interim {0} on {1}, which this run started, before its own Run Commands there: at most {2} minutes.' -f $interim, (Join-DemoActivityList -Item $vms), [int][System.Math]::Ceiling($waitSeconds / 60.0))
    }
    $records = @(Wait-DemoProfileRunCommand -Config $Config -Record $items -WaitSeconds $waitSeconds -PollSeconds $PollSeconds)
    $results = foreach ($entry in $records) {
        $item = [string]$entry.Target
        $vm = [string]$entry.VmName
        $checkId = '{0}.INTERIM_{1}' -f $CheckPrefix, $item
        $attempts = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $entry.Data -Name 'evidence') -Name 'attempts'
        $evidence = [ordered]@{ profile = $interim; switchTo = $name; vm = $vm; outcome = [string]$entry.Outcome; seconds = $entry.Seconds; attempts = $attempts; runCommand = 'DbHubDemo-Profile' }
        $fix = './scripts/validate.ps1 -Area Workload -Target {0} says whether {0}''s runner answers now. If this run''s switch to {1} ({2}.INCIDENTS_{0}) didn''t pass, set it once it does: ./scripts/demo-control.ps1 -Target {0} -Scenario {1} -Duration 240.' -f $item, $name, $CheckPrefix
        $risk = 'This run''s own Run Commands there went on, so the profile stored there could run its incidents beside them.'
        switch ([string]$entry.Outcome) {
            'Set' {
                $tries = if ($attempts -as [int]) { ' and {0} attempt(s)' -f [int]$attempts } else { '' }
                New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Pass' -Message ('{0}: the interim {1} is set on {2}, which this run started, in {3} seconds{4}, before this run''s own Run Commands there; {5} comes back at the end.' -f $item, $interim, $vm, $entry.Seconds, $tries, $name) -Evidence $evidence -DocUrl $docUrl
            }
            'NotSetUp' {
                New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Not selected' -Message ('{0}: no interim {1} to set on {2}: {3}' -f $item, $interim, $vm, $entry.Detail) -Evidence $evidence -DocUrl $docUrl
            }
            'TimedOut' {
                New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Warning' -Message ('{0}: the interim {1} on {2}, which this run started, wasn''t set within {3} seconds. {4}' -f $item, $interim, $vm, $waitSeconds, $risk) -Evidence $evidence -Remediation $fix -DocUrl $docUrl
            }
            default {
                New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Warning' -Message ('{0}: the interim {1} couldn''t be set on {2}, which this run started: {3}. {4}' -f $item, $interim, $vm, ([string]$entry.Detail).TrimEnd('.'), $risk) -Evidence $evidence -Remediation $fix -DocUrl $docUrl
            }
        }
    }
    return @($results)
}

function Get-DemoScheduledIncident {
    <#
    .SYNOPSIS
    The business-day incident due on one of -Target at -NowUtc, when the configured activity profile is business-day
    (2026-11-03): the slot whose window, from its start minute to its end plus -SlackMinutes for the runner to end its
    sessions and the load to settle, covers the time. With several, the one that clears last. $null for any other
    profile, which runs no incident on a schedule, or when none is due. Internal.

    .DESCRIPTION
    The cycles are counted from UTC midnight, as the runner's ProfileScheduler counts them, so this cycle's slot and the
    previous cycle's, whose slack can reach into this one, are both checked. It reads only the schedule
    (scenarios/activity-profiles.json). -ProfileName, the profile a VM's status says the target runs, replaces the
    configured one; without it, whether the profile is active on the VM isn't known here, so callers use it only to
    explain a read that failed the way load makes reads fail, never to pass one (ConvertTo-DemoIncidentAwareResult).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string[]] $Target,

        [datetime] $NowUtc = [System.DateTime]::UtcNow,

        [ValidateRange(0, 30)]
        [int] $SlackMinutes = 3,

        [AllowEmptyString()]
        [string] $ProfileName = ''
    )

    $name = if ($ProfileName) { $ProfileName } else { (Get-DemoActivityProfile -Config $Config).Name }
    if ($name -cne 'business-day') {
        return $null
    }
    $now = $NowUtc.ToUniversalTime()
    $dayStart = [System.DateTime]::new($now.Year, $now.Month, $now.Day, 0, 0, 0, [System.DateTimeKind]::Utc)
    $found = $null
    foreach ($slot in @(Get-DemoBusinessDaySchedule -Target $Target)) {
        $cycle = [System.Math]::Max(1, [int]$slot.CycleMinutes)
        $cycleStart = $dayStart.AddMinutes($cycle * [System.Math]::Floor(($now - $dayStart).TotalMinutes / $cycle))
        foreach ($start in $cycleStart.AddMinutes($slot.StartMinute), $cycleStart.AddMinutes($slot.StartMinute - $cycle)) {
            $end = $start.AddMinutes($slot.DurationMinutes)
            $clear = $end.AddMinutes($SlackMinutes)
            if ($now -ge $start -and $now -lt $clear -and ($null -eq $found -or $clear -gt $found.ClearUtc)) {
                $found = [pscustomobject]@{ Target = [string]$slot.Target; Scenario = [string]$slot.Scenario; StartUtc = $start; EndUtc = $end; ClearUtc = $clear }
            }
        }
    }
    return $found
}

function Test-DemoLoadFailureText {
    <#
    .SYNOPSIS
    True when a failed read's text says load made it fail, the only failure one of business-day's incidents can cause
    (review of PR 16, 2026-11-04): a Run Command, the runner, or the Azure CLI that didn't finish in time; Azure's 409
    Conflict (another operation in progress); a SQL Server, Azure SQL, or PostgreSQL time-out, lock time-out, or deadlock;
    or a resource or connection limit (Azure SQL 10928, 10936, 40501; PostgreSQL 53300). False for a fault no incident
    causes, which wins when both appear: settings.json missing, no runner, a target that isn't set up, a refused login, a
    missing server or database, or a VM that isn't running. False for any other text too, so an unknown failure stays a
    Fail. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }
    $fixed = '(?i)\bis missing\b|not installed|no workload runner|isn''t set up yet|no valid module file|bootstrap bundle|has no T[34] server|login failed|password authentication failed|\b28P01\b|\b28000\b|permission denied|access (is )?denied|AuthorizationFailed|not authori[sz]ed|\bForbidden\b|OperationNotAllowed|isn''t running|not running|deallocat|does not exist|doesn''t exist|could not be found|\bnot found\b|NotFound|cannot open (database|server)'
    if ($value -match $fixed) {
        return $false
    }
    $load = '(?i)did not finish within|didn''t finish within|\(409\)|\b409\b|\bConflict\b|AnotherOperationInProgress|another operation|operation (is )?(already )?in progress|already in progress|Execution Timeout Expired|Connection Timeout Expired|timeout period elapsed|wait operation timed out|\btimed out\b|lock request time ?out|\block timeout\b|statement timeout|\b57014\b|\b55P03\b|TimeoutException|Timeout during|\bdeadlock|request limit|session limit|resource limit|\b10928\b|\b10936\b|\b40501\b|service is currently busy|too many clients|\b53300\b|remaining connection slots|connection pool has been exhausted|server is not responding'
    return ($value -match $load)
}

function Get-DemoRunnerActiveProfile {
    <#
    .SYNOPSIS
    The activity profile the runner's 'status --json' output says its target runs (review of PR 16, 2026-11-04): the
    profile node's name while its expiresAt is unset or after -NowUtc. -ProfileNode, the name and expiry the VM's relay
    read from the whole output before cutting it (the Runner action's evidence.profile), comes first: a Run Command keeps
    only the last 4,096 bytes of output and the relay the last 1,800 characters of the runner's, the profile comes first
    in the status, and a status with two or more runs leaves it out of that tail (re-review of PR 16). Without it, the
    output's own profile node; '' when the profile is off or has expired, or when neither has a profile. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $StdOut,

        [AllowNull()]
        [object] $ProfileNode = $null,

        [datetime] $NowUtc = [System.DateTime]::UtcNow
    )

    $node = $ProfileNode
    if (-not [string](Get-DemoMemberValue -InputObject $node -Name 'name')) {
        $node = Get-DemoMemberValue -InputObject (ConvertFrom-DemoRunnerDocument -StdOut $StdOut) -Name 'profile'
    }
    if ($null -eq $node -or $node -is [string]) {
        return ''
    }
    $name = [string](Get-DemoMemberValue -InputObject $node -Name 'name')
    if (-not $name -or $name -ceq 'off') {
        return ''
    }
    $expires = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $node -Name 'expiresAt')
    if ($null -ne $expires -and $expires -le $NowUtc.ToUniversalTime()) {
        return ''
    }
    return $name
}

function ConvertTo-DemoIncidentAwareResult {
    <#
    .SYNOPSIS
    validate.ps1 mustn't Fail just because an incident is running (2026-11-03), and mustn't hide a fault behind one
    either (review of PR 16, 2026-11-04): a Fail from a check that reads a target through its own load becomes a Warning
    only when an incident can explain it, with the incident in the message and the evidence, and the time to check again
    in the remediation. Any other result is returned as it is. Internal.

    .DESCRIPTION
    - -Kind Read (WORKLOAD.<target>.COMMAND, and T3.PROPERTY when its T-SQL didn't run): the read failed the way load makes
      reads fail (Test-DemoLoadFailureText: a time-out, a 409, a lock, or a resource limit), and the configured profile is
      business-day with an incident due on -IncidentTarget (Get-DemoScheduledIncident). A failed read can't say which
      profile the VM runs, so the schedule decides; settings.json missing, no runner, a refused login, and any failure it
      doesn't know stay a Fail.
    - -Kind Host (WORKLOAD.<target>.HOST): the status the host check read says the target runs business-day itself
      (-RunnerProfile, the relay's evidence.profile, else -RunnerStdOut; Get-DemoRunnerActiveProfile), whatever the
      configuration says, an incident is due, and the host's process is alive: a profile host that ended is a fault no
      incident causes, and a VM on baseline or off runs none.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Result,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string[]] $IncidentTarget,

        [Parameter(Mandatory)]
        [ValidateSet('T3', 'Workload')]
        [string] $ValidationArea,

        [ValidateSet('Read', 'Host')]
        [string] $Kind = 'Read',

        [AllowNull()]
        [object] $RunnerProfile = $null,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $RunnerStdOut = '',

        [datetime] $NowUtc = [System.DateTime]::UtcNow
    )

    if ([string]$Result.status -ne 'Fail') {
        return $Result
    }
    $sourceEvidence = if ($Result.evidence -is [System.Collections.IDictionary]) { $Result.evidence } else { @{} }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Kind -eq 'Host') {
        $running = Get-DemoRunnerActiveProfile -StdOut $RunnerStdOut -ProfileNode $RunnerProfile -NowUtc $NowUtc
        if ($running -cne 'business-day') {
            return $Result
        }
        if ($sourceEvidence.Contains('processAlive') -and $sourceEvidence['processAlive'] -is [bool] -and -not $sourceEvidence['processAlive']) {
            return $Result
        }
        $incident = Get-DemoScheduledIncident -Config $Config -Target $IncidentTarget -NowUtc $NowUtc -ProfileName $running
    }
    else {
        $text = @([string]$Result.message) + @(if ($sourceEvidence.Contains('stderr')) { [string]$sourceEvidence['stderr'] })
        if (-not (Test-DemoLoadFailureText -Text ($text -join "`n"))) {
            return $Result
        }
        $incident = Get-DemoScheduledIncident -Config $Config -Target $IncidentTarget -NowUtc $NowUtc
    }
    if ($null -eq $incident) {
        return $Result
    }
    $evidence = [ordered]@{}
    foreach ($key in $sourceEvidence.Keys) {
        $evidence[$key] = $sourceEvidence[$key]
    }
    $evidence['incident'] = [ordered]@{ target = $incident.Target; scenario = $incident.Scenario; startUtc = $incident.StartUtc.ToString('o', $invariant); endUtc = $incident.EndUtc.ToString('o', $invariant) }
    $evidence['failedDuringIncident'] = $true
    $evidence['downgrade'] = if ($Kind -eq 'Host') { 'profileOnVm' } else { 'loadFailure' }
    $base = ([string]$Result.message).TrimEnd()
    if ($base -notmatch '[.!?]$') {
        $base += '.'
    }
    $window = '{0} to {1} UTC' -f $incident.StartUtc.ToString('HH:mm', $invariant), $incident.EndUtc.ToString('HH:mm', $invariant)
    $message = if ($Kind -eq 'Host') {
        '{0} {1} runs business-day, as its status says, and its {2} incident on {3} ({4}) can slow this lane, so it''s a Warning, not a Fail.' -f $base, $Result.target, $incident.Scenario, $incident.Target, $window
    }
    else {
        '{0} It failed the way load makes a read fail (a time-out or a busy VM) during business-day''s {1} incident on {2} ({3}), so it''s a Warning, not a Fail.' -f $base, $incident.Scenario, $incident.Target, $window
    }
    $targetOption = if ([string]$Result.target -in 'T1', 'T2', 'T3', 'T4') { ' -Target {0}' -f $Result.target } else { '' }
    $remediation = 'Run ./scripts/validate.ps1 -Area {0}{1} again after {2} UTC, once the incident has ended; a Fail then is a fault.' -f $ValidationArea, $targetOption, $incident.ClearUtc.ToString('HH:mm', $invariant)
    if ([string]$Result.remediation) {
        $remediation += ' ' + [string]$Result.remediation
    }
    return (New-DemoResult -CheckId ([string]$Result.checkId) -Area ([string]$Result.area) -Target ([string]$Result.target) -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl ([string]$Result.docUrl) -EvaluationOnly:([bool]$Result.evaluationOnly))
}
