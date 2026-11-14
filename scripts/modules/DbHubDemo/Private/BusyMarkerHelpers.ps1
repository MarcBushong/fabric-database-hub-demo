# The busy marker (2026-11-14): a deploy.ps1 run that's still going when the nightly stop comes isn't cut off. It's two
# tags on the demo resource group, DbHubBusyUntilUtc and DbHubBusyBy (Get-DemoDeploymentStateTagName), which the run sets
# ahead and moves on while it goes on. The safety stop's DbHub-Stop changes nothing while the marker is ahead by at most
# maximumMinutes (automation/runbooks/DbHubControl.Common.ps1, Get-DbHubBusyMarker), so a marker that nothing moves on
# expires, and a run that was abandoned is still stopped. A run the nightly stop waited for gets a later pass,
# dbhub-safety-deferred, hourly from the marker's end until the next morning, so the demo is stopped the same night once
# the run ends, or once the marker of an abandoned run expires. The VMs' own auto-shutdown (DevTest Labs schedules,
# infra/modules/windows-vm.bicep) moves past the run the same way, and the run's end, start-demo.ps1, stop-demo.ps1, and
# the template put it back. Internal.

$script:BusyMarkerSetting = [ordered]@{
    # A marker further ahead than this is ignored: no refresh writes one, so no marker defers a stop for longer than this
    # after its last refresh.
    maximumMinutes        = 180
    # How far ahead a run sets the marker, and how often it moves it on.
    leadMinutes           = 60
    refreshMinutes        = 10
    # How long a run the nightly stop waited for keeps the demo up after it ends, before the deferred pass stops it.
    graceMinutes          = 60
    # The deferred pass starts this long after the marker's end (Azure Automation wants a start at least 5 minutes ahead).
    passMarginMinutes     = 5
    # A VM's auto-shutdown moves when it would come before the marker's end plus this, to about stepMinutes after the end.
    shutdownMarginMinutes = 15
    shutdownStepMinutes   = 60
    # The deferred pass ends this long after the night's first pass it stands in for.
    expiryHours           = 12
    deferredSchedule      = 'dbhub-safety-deferred'
}
$script:BusyMarkerRun = $null
$script:BusyMarkerDoc = 'https://learn.microsoft.com/rest/api/automation/schedule/create-or-update'
$script:AutoShutdownDoc = 'https://learn.microsoft.com/rest/api/dtl/global-schedules/create-or-update'

function ConvertTo-DemoBusyTimeText {
    # A UTC time as the marker holds it: yyyy-MM-ddTHH:mm:ssZ. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [datetime] $Utc
    )

    $value = if ($Utc.Kind -eq [System.DateTimeKind]::Local) { $Utc.ToUniversalTime() } else { $Utc }
    return $value.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-DemoBusyMarker {
    <#
    .SYNOPSIS
    The busy marker in the demo resource group's tags (2026-11-14), read as the safety stop's runbook reads it
    (Get-DbHubBusyMarker): Active while DbHubBusyUntilUtc is ahead by at most maximumMinutes, with UntilUtc, By (deploy,
    deploy-grace, or session), Text (the tag as written), and Reason (None, Unreadable, Expired, TooFar, or Active). Pure.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Tags,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $names = Get-DemoDeploymentStateTagName
    $now = if ($NowUtc.Kind -eq [System.DateTimeKind]::Local) { $NowUtc.ToUniversalTime() } else { [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc) }
    $text = [string](Get-DemoMemberValue -InputObject $Tags -Name $names['BusyUntilUtc'])
    $by = [string](Get-DemoMemberValue -InputObject $Tags -Name $names['BusyBy'])
    if ($by -notmatch '^[a-z][a-z-]{0,31}$') {
        $by = ''
    }
    $answer = [pscustomobject]@{ Active = $false; UntilUtc = $null; By = $by; Text = $text; Reason = 'None' }
    if (-not $text) {
        return $answer
    }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if (-not [datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $parsed)) {
        $answer.Reason = 'Unreadable'
        return $answer
    }
    $answer.UntilUtc = [DateTime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
    if ($answer.UntilUtc -le $now) {
        $answer.Reason = 'Expired'
    }
    elseif ($answer.UntilUtc -gt $now.AddMinutes([int]$script:BusyMarkerSetting['maximumMinutes'])) {
        $answer.Reason = 'TooFar'
    }
    else {
        $answer.Active = $true
        $answer.Reason = 'Active'
    }
    return $answer
}

function Set-DemoBusyMarker {
    <#
    .SYNOPSIS
    Marks the demo resource group busy until -UntilUtc (2026-11-14): DbHubBusyUntilUtc and DbHubBusyBy, merged into its
    tags (Set-DemoDeploymentState), which Contributor can do. -By ended with a time that's past says a run ended and left
    something to settle (a deferred pass, a moved auto-shutdown), which start-demo.ps1, stop-demo.ps1, and the next
    deploy.ps1 put back; the safety stop's runbook takes it as expired. Throws when the tags can't be written, such as
    before a first deployment's template has created the group. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('deploy', 'deploy-grace', 'session', 'ended')]
        [string] $By,

        [Parameter(Mandatory)]
        [datetime] $UntilUtc
    )

    $until = ConvertTo-DemoBusyTimeText -Utc $UntilUtc
    if ($PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), ('Mark the demo busy until {0} ({1})' -f $until, $By))) {
        Set-DemoDeploymentState -Config $Config -Value @{ BusyUntilUtc = $until; BusyBy = $By } -Confirm:$false
    }
}

function Clear-DemoBusyMarker {
    # Clears the busy marker (2026-11-14), so the nightly stop goes on as usual. Throws when the tags can't be written.
    # Internal.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ($PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), 'Clear the busy marker')) {
        Set-DemoDeploymentState -Config $Config -Value @{ BusyUntilUtc = ''; BusyBy = '' } -Confirm:$false
    }
}

function Get-DemoAutoShutdownSetting {
    # The VMs' auto-shutdown as the template sets it: Time (HHmm: autoShutdownTime, or 1900), TimeZoneId
    # (autoShutdownTimeZone, or UTC, as Get-DemoSafetyStopTime reads it), and Zone. Pure. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $time = if ([string]$Config['autoShutdownTime'] -match '^([01]\d|2[0-3])([0-5]\d)$') { [string]$Config['autoShutdownTime'] } else { '1900' }
    $zoneId = if ($Config['autoShutdownTimeZone']) { [string]$Config['autoShutdownTimeZone'] } else { 'UTC' }
    $zone = Get-DemoActivityControlTimeZone -Id $zoneId
    if ($null -eq $zone) {
        $zone = [System.TimeZoneInfo]::Utc
    }
    return [pscustomobject]@{ Time = $time; TimeZoneId = $zoneId; Zone = $zone }
}

function Get-DemoDailyNextUtc {
    # The first time after -AfterUtc that a daily -Time (HHmm, in -Zone) comes, in UTC; $null for a time that isn't HHmm.
    # A time that daylight saving time skips comes an hour later, as Get-DemoSafetyStopTime takes it. Pure. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyString()]
        [string] $Time,

        [Parameter(Mandatory)]
        [System.TimeZoneInfo] $Zone,

        [Parameter(Mandatory)]
        [datetime] $AfterUtc
    )

    if ($Time -notmatch '^([01]\d|2[0-3])([0-5]\d)$') {
        return $null
    }
    $hour = [int]$Matches[1]
    $minute = [int]$Matches[2]
    $after = if ($AfterUtc.Kind -eq [System.DateTimeKind]::Local) { $AfterUtc.ToUniversalTime() } else { [DateTime]::SpecifyKind($AfterUtc, [System.DateTimeKind]::Utc) }
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($after, $Zone)
    for ($day = 0; $day -le 2; $day++) {
        $candidate = [datetime]::new($local.Year, $local.Month, $local.Day, $hour, $minute, 0, [System.DateTimeKind]::Unspecified).AddDays($day)
        if ($Zone.IsInvalidTime($candidate)) {
            $candidate = $candidate.AddHours(1)
        }
        $utc = [DateTime]::SpecifyKind([System.TimeZoneInfo]::ConvertTimeToUtc($candidate, $Zone), [System.DateTimeKind]::Utc)
        if ($utc -gt $after) {
            return $utc
        }
    }
    return $null
}

function Get-DemoBusyLocalTime {
    <#
    .SYNOPSIS
    -Utc in -Zone, rounded up to the next multiple of -StepMinutes on the zone's clock: Utc, Clock (HHmm, for a DevTest Labs
    schedule), Text (HH:mm), and ZoneTime (ISO 8601 with the zone's offset, for an Azure Automation schedule). Pure.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [datetime] $Utc,

        [Parameter(Mandatory)]
        [System.TimeZoneInfo] $Zone,

        [ValidateRange(1, 60)]
        [int] $StepMinutes = 1
    )

    $value = if ($Utc.Kind -eq [System.DateTimeKind]::Local) { $Utc.ToUniversalTime() } else { [DateTime]::SpecifyKind($Utc, [System.DateTimeKind]::Utc) }
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($value, $Zone)
    $whole = [datetime]::new($local.Year, $local.Month, $local.Day, $local.Hour, $local.Minute, 0, [System.DateTimeKind]::Unspecified)
    if ($local -gt $whole) {
        $whole = $whole.AddMinutes(1)
    }
    $over = ($whole.Hour * 60 + $whole.Minute) % $StepMinutes
    if ($over -gt 0) {
        $whole = $whole.AddMinutes($StepMinutes - $over)
    }
    if ($Zone.IsInvalidTime($whole)) {
        $whole = $whole.AddHours(1)
    }
    $utcValue = [DateTime]::SpecifyKind([System.TimeZoneInfo]::ConvertTimeToUtc($whole, $Zone), [System.DateTimeKind]::Utc)
    return [pscustomobject]@{
        Utc      = $utcValue
        Clock    = $whole.ToString('HHmm', [System.Globalization.CultureInfo]::InvariantCulture)
        Text     = $whole.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        ZoneTime = ([DateTimeOffset]::new($whole, $Zone.GetUtcOffset($whole))).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

function Get-DemoBusyNightlyPass {
    <#
    .SYNOPSIS
    The nightly safety stop's first pass at or after -FromUtc, its stop or its T3 check (Get-DemoSafetyStopRunAfter
    -WithCheck), when it comes no later than -UntilUtc: Run (Stop or Check), Utc, LocalTime (HH:mm), and TimeZone; $null
    when none does. A run whose busy window holds one is one the nightly stop waits for. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [datetime] $FromUtc,

        [Parameter(Mandatory)]
        [datetime] $UntilUtc
    )

    $first = Get-DemoSafetyStopRunAfter -Config $Config -AfterUtc $FromUtc -WithCheck
    $until = if ($UntilUtc.Kind -eq [System.DateTimeKind]::Local) { $UntilUtc.ToUniversalTime() } else { [DateTime]::SpecifyKind($UntilUtc, [System.DateTimeKind]::Utc) }
    if ($null -eq $first -or $first.Utc -gt $until) {
        return $null
    }
    return $first
}

function Get-DemoBusyPassText {
    # How a nightly pass reads in a sentence: "19:00 stop" or "19:30 T3 check", with its time zone. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Pass
    )

    $what = if ([string]$Pass.Run -eq 'Check') { 'T3 check' } else { 'stop' }
    return ('{0} {1} ({2})' -f [string]$Pass.LocalTime, $what, [string]$Pass.TimeZone)
}

function Get-DemoAutoShutdownId {
    # A VM's DevTest Labs auto-shutdown schedule, as infra/modules/windows-vm.bicep names it. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    return ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DevTestLab/schedules/shutdown-computevm-{2}' -f ([string]$Config['subscriptionId']).ToLowerInvariant(), (Get-DemoResourceGroupName -Config $Config), $VmName)
}

function Read-DemoAutoShutdown {
    <#
    .SYNOPSIS
    A VM's auto-shutdown schedule (Global Schedules - Get): Ok, Missing, VmName, Time (HHmm), Enabled, Value (the schedule
    as read), and Error. Never throws. Internal.
    https://learn.microsoft.com/rest/api/dtl/global-schedules/get
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    $read = Invoke-DemoActivityControlArm -SubscriptionId ([string]$Config['subscriptionId']) -Method get -Url (Get-DemoActivityControlUrl -Id (Get-DemoAutoShutdownId -Config $Config -VmName $VmName) -ApiVersion (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DevTestLab/schedules'))
    $properties = Get-DemoMemberValue -InputObject $read.Value -Name 'properties'
    $time = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'dailyRecurrence') -Name 'time')
    return [pscustomobject]@{
        Ok      = [bool]$read.Ok
        Missing = [bool]$read.Missing
        VmName  = $VmName
        Time    = $time
        Enabled = [string](Get-DemoMemberValue -InputObject $properties -Name 'status') -eq 'Enabled'
        Value   = $read.Value
        Error   = $(if ($read.Ok -or $read.Missing) { '' } else { [string]$read.Error })
    }
}

function Set-DemoAutoShutdownTime {
    <#
    .SYNOPSIS
    Moves a VM's auto-shutdown to -Time (HHmm) and changes nothing else (Global Schedules - Create Or Update, with the
    schedule as -Schedule read it): Global Schedules - Update changes only tags. Contributor can, and so can the control's
    identity (Microsoft.DevTestLab/schedules/write at the demo resource group). Returns Ok and Error. Internal.
    https://learn.microsoft.com/rest/api/dtl/global-schedules/create-or-update
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Schedule,

        [Parameter(Mandatory)]
        [ValidatePattern('^([01]\d|2[0-3])[0-5]\d$')]
        [string] $Time
    )

    $properties = Get-DemoMemberValue -InputObject $Schedule.Value -Name 'properties'
    $body = [ordered]@{
        location   = [string](Get-DemoMemberValue -InputObject $Schedule.Value -Name 'location')
        properties = [ordered]@{
            status               = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
            taskType             = [string](Get-DemoMemberValue -InputObject $properties -Name 'taskType')
            dailyRecurrence      = [ordered]@{ time = $Time }
            timeZoneId           = [string](Get-DemoMemberValue -InputObject $properties -Name 'timeZoneId')
            notificationSettings = (Get-DemoMemberValue -InputObject $properties -Name 'notificationSettings')
            targetResourceId     = [string](Get-DemoMemberValue -InputObject $properties -Name 'targetResourceId')
        }
    }
    $tags = Get-DemoMemberValue -InputObject $Schedule.Value -Name 'tags'
    if ($null -ne $tags) {
        $body['tags'] = $tags
    }
    if ($null -eq $body.properties.notificationSettings) {
        $body.properties.Remove('notificationSettings')
    }
    if (-not $PSCmdlet.ShouldProcess(('shutdown-computevm-{0}' -f $Schedule.VmName), ('Move the auto-shutdown to {0}' -f $Time))) {
        return [pscustomobject]@{ Ok = $false; Error = 'what if' }
    }
    $put = Invoke-DemoActivityControlArm -SubscriptionId ([string]$Config['subscriptionId']) -Method put -Url (Get-DemoActivityControlUrl -Id (Get-DemoAutoShutdownId -Config $Config -VmName $Schedule.VmName) -ApiVersion (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.DevTestLab/schedules')) -Body $body
    return [pscustomobject]@{ Ok = [bool]$put.Ok; Error = [string]$put.Error }
}

function Sync-DemoAutoShutdownForBusy {
    <#
    .SYNOPSIS
    Keeps the VMs' auto-shutdown out of a busy run's way, or puts it where the run's end wants it (2026-11-14). Returns
    each change: VmName, From, To, Ok, and Error. Never throws. Internal.

    .DESCRIPTION
    - With -UntilUtc (a run that's going on): a VM's auto-shutdown that would come before the marker's end plus
      shutdownMarginMinutes moves to shutdownStepMinutes after the marker's end, on a quarter hour; one that comes later
      is left as it is. The template sets it back to autoShutdownTime on each deployment, which the next check moves on.
      A moved time, not a disabled schedule, so an abandoned run's VMs still stop the same night, with or without the
      safety stop's role.
    - With -TargetClock: that time (the end of a run the nightly stop waited for).
    - With -Restore: autoShutdownTime.
    A schedule that's missing (a first deployment before its template) or disabled is left alone. The schedules are
    shutdown-computevm-sqlvm01 and that of the T2 host (infra/modules/windows-vm.bicep).
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Busy')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory, ParameterSetName = 'Busy')]
        [datetime] $UntilUtc,

        [Parameter(Mandatory, ParameterSetName = 'Target')]
        [ValidatePattern('^([01]\d|2[0-3])[0-5]\d$')]
        [string] $TargetClock,

        [Parameter(Mandatory, ParameterSetName = 'Restore')]
        [switch] $Restore,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $setting = Get-DemoAutoShutdownSetting -Config $Config
    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($vm in @('sqlvm01', (Get-DemoHostVmName -Config $Config))) {
        try {
            $schedule = Read-DemoAutoShutdown -Config $Config -VmName $vm
            if (-not $schedule.Ok) {
                if (-not $schedule.Missing) {
                    $changes.Add([pscustomobject]@{ VmName = $vm; From = ''; To = ''; Ok = $false; Error = ('its auto-shutdown couldn''t be read: {0}' -f $schedule.Error) })
                }
                continue
            }
            $wanted = if ($Restore) {
                $setting.Time
            }
            elseif ($PSCmdlet.ParameterSetName -eq 'Target') {
                $TargetClock
            }
            else {
                $limit = $UntilUtc.AddMinutes([int]$script:BusyMarkerSetting['shutdownMarginMinutes'])
                $next = Get-DemoDailyNextUtc -Time $schedule.Time -Zone $setting.Zone -AfterUtc $NowUtc
                if ($schedule.Enabled -and ($null -eq $next -or $next -le $limit)) {
                    (Get-DemoBusyLocalTime -Utc $UntilUtc.AddMinutes([int]$script:BusyMarkerSetting['shutdownStepMinutes']) -Zone $setting.Zone -StepMinutes 15).Clock
                }
                else {
                    $schedule.Time
                }
            }
            if ($wanted -eq $schedule.Time) {
                continue
            }
            if (-not $PSCmdlet.ShouldProcess(('shutdown-computevm-{0}' -f $vm), ('Move the auto-shutdown from {0} to {1}' -f $schedule.Time, $wanted))) {
                continue
            }
            $set = Set-DemoAutoShutdownTime -Config $Config -Schedule $schedule -Time $wanted -Confirm:$false
            $changes.Add([pscustomobject]@{ VmName = $vm; From = $schedule.Time; To = $wanted; Ok = [bool]$set.Ok; Error = [string]$set.Error })
        }
        catch {
            $changes.Add([pscustomobject]@{ VmName = $vm; From = ''; To = ''; Ok = $false; Error = (Protect-DemoText -Text $_.Exception.Message) })
        }
    }
    return $changes.ToArray()
}

function Format-DemoClockText {
    # HHmm as HH:mm. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Clock
    )

    if ($Clock -match '^(\d{2})(\d{2})$') {
        return ('{0}:{1}' -f $Matches[1], $Matches[2])
    }
    return $Clock
}

function Get-DemoBusyDeferredPass {
    <#
    .SYNOPSIS
    The deferred nightly pass, dbhub-safety-deferred, in the safety stop's Automation account (Schedule - Get): Exists,
    Missing (it or the account doesn't exist), Enabled, StartUtc, NextRunUtc, ExpiryUtc, and Error. Never throws. Internal.
    https://learn.microsoft.com/rest/api/automation/schedule/get
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $answer = [ordered]@{ Exists = $false; Missing = $false; Enabled = $false; StartUtc = $null; NextRunUtc = $null; ExpiryUtc = $null; Error = '' }
    try {
        $name = Get-DemoSafetyStopName -Config $Config
        $read = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/schedules/{1}' -f $name.AutomationAccountId, $script:BusyMarkerSetting['deferredSchedule']) -ApiVersion $script:SafetyStopAutomationApiVersion)
        if (-not $read.Ok) {
            $answer.Missing = [bool]$read.Missing
            $answer.Error = if ($read.Missing) { '' } else { [string]$read.Error }
            return [pscustomobject]$answer
        }
        $properties = Get-DemoMemberValue -InputObject $read.Value -Name 'properties'
        $answer.Exists = $true
        $answer.Enabled = [bool](Get-DemoMemberValue -InputObject $properties -Name 'isEnabled')
        $answer.StartUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $properties -Name 'startTime')
        $answer.NextRunUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $properties -Name 'nextRun')
        $answer.ExpiryUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $properties -Name 'expiryTime')
    }
    catch {
        $answer.Error = Protect-DemoText -Text $_.Exception.Message
    }
    return [pscustomobject]$answer
}

function Remove-DemoBusyDeferredPass {
    <#
    .SYNOPSIS
    Removes the deferred nightly pass, dbhub-safety-deferred, with its links (Job Schedule - Delete, then Schedule -
    Delete). Returns Removed (it existed and is gone) and Error. Never throws. Internal.
    https://learn.microsoft.com/rest/api/automation/schedule/delete
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $answer = [ordered]@{ Removed = $false; Error = '' }
    try {
        $pass = Get-DemoBusyDeferredPass -Config $Config
        if (-not $pass.Exists) {
            $answer.Error = $pass.Error
            return [pscustomobject]$answer
        }
        $schedule = [string]$script:BusyMarkerSetting['deferredSchedule']
        if (-not $PSCmdlet.ShouldProcess($schedule, 'Remove the deferred nightly pass and its links')) {
            return [pscustomobject]$answer
        }
        $name = Get-DemoSafetyStopName -Config $Config
        $version = $script:SafetyStopAutomationApiVersion
        $links = Get-DemoSafetyStopLink -Name $name -Schedule @($schedule)
        foreach ($link in @($links.Links)) {
            if ([string]$link.Id -match '^[0-9a-fA-F-]{36}$') {
                $null = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules/{1}' -f $name.AutomationAccountId, $link.Id) -ApiVersion $version)
            }
        }
        $deleted = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id ('{0}/schedules/{1}' -f $name.AutomationAccountId, $schedule) -ApiVersion $version)
        $answer.Removed = [bool]($deleted.Ok -or $deleted.Missing)
        $answer.Error = if ($answer.Removed) { '' } else { [string]$deleted.Error }
    }
    catch {
        $answer.Error = Protect-DemoText -Text $_.Exception.Message
    }
    return [pscustomobject]$answer
}

function Set-DemoBusyDeferredPass {
    <#
    .SYNOPSIS
    Schedules the deferred nightly pass (2026-11-14): dbhub-safety-deferred in the safety stop's Automation account, hourly
    from -StartUtc until -ExpiryUtc in autoShutdownTimeZone, linked to DbHub-Stop with Scope Nightly, in place of one
    that's there. Each pass stops the demo as the nightly stop does once the busy marker has expired, and changes nothing
    while it's ahead. Returns Ok, NoAccount (the account or its runbook isn't there yet: deploy.ps1 sets them up after its
    template), and Error. Never throws. Internal.

    .DESCRIPTION
    Azure Automation runs a schedule at most hourly and wants its start at least 5 minutes ahead; each new link has a new
    ID (Set-DemoSafetyStopSchedule). The safety stop's identity needs nothing new: the pass runs the same runbook with the
    same role (ADR 0024).
    - Schedule: https://learn.microsoft.com/rest/api/automation/schedule/create-or-update
    - Job schedule: https://learn.microsoft.com/rest/api/automation/job-schedule/create
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [datetime] $StartUtc,

        [Parameter(Mandatory)]
        [datetime] $ExpiryUtc
    )

    $answer = [ordered]@{ Ok = $false; NoAccount = $false; Error = '' }
    try {
        $name = Get-DemoSafetyStopName -Config $Config
        $version = $script:SafetyStopAutomationApiVersion
        $schedule = [string]$script:BusyMarkerSetting['deferredSchedule']
        $setting = Get-DemoAutoShutdownSetting -Config $Config
        $start = Get-DemoBusyLocalTime -Utc $StartUtc -Zone $setting.Zone
        $expiry = Get-DemoBusyLocalTime -Utc $ExpiryUtc -Zone $setting.Zone
        if (-not $PSCmdlet.ShouldProcess($schedule, ('Run {0} -Scope Nightly hourly from {1} until {2}' -f $name.Runbook, $start.ZoneTime, $expiry.ZoneTime))) {
            $answer.Error = 'what if'
            return [pscustomobject]$answer
        }
        $runbook = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/runbooks/{1}' -f $name.AutomationAccountId, $name.Runbook) -ApiVersion $version)
        if (-not $runbook.Ok) {
            $answer.NoAccount = [bool]$runbook.Missing
            $answer.Error = if ($runbook.Missing) { 'the safety stop''s runbook {0} isn''t in {1} yet' -f $name.Runbook, $name.AutomationAccount } else { [string]$runbook.Error }
            return [pscustomobject]$answer
        }
        $removed = Remove-DemoBusyDeferredPass -Config $Config -Confirm:$false
        if (-not $removed.Removed -and $removed.Error) {
            $answer.Error = 'the earlier deferred pass couldn''t be replaced: {0}' -f $removed.Error
            return [pscustomobject]$answer
        }
        $body = [ordered]@{
            name       = $schedule
            properties = [ordered]@{
                description = 'Deferred nightly stop (2026-11-14): DbHub-Stop -Scope Nightly, hourly, once the busy marker of a run the nightly stop waited for has expired. Scheduled by deploy.ps1; start-demo.ps1 and stop-demo.ps1 remove it.'
                startTime   = $start.ZoneTime
                expiryTime  = $expiry.ZoneTime
                frequency   = 'Hour'
                interval    = 1
                timeZone    = $setting.TimeZoneId
            }
        }
        $created = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method put -Url (Get-DemoActivityControlUrl -Id ('{0}/schedules/{1}' -f $name.AutomationAccountId, $schedule) -ApiVersion $version) -Body $body
        if (-not $created.Ok) {
            $answer.Error = 'the schedule couldn''t be created: {0}' -f $created.Error
            return [pscustomobject]$answer
        }
        $link = [ordered]@{ properties = [ordered]@{ schedule = @{ name = $schedule }; runbook = @{ name = $name.Runbook }; parameters = @{ Scope = 'Nightly' } } }
        $linked = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method put -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules/{1}' -f $name.AutomationAccountId, [guid]::NewGuid().ToString()) -ApiVersion $version) -Body $link
        if (-not $linked.Ok) {
            $answer.Error = 'the schedule exists, but it couldn''t be linked to {0}: {1}' -f $name.Runbook, $linked.Error
            return [pscustomobject]$answer
        }
        $answer.Ok = $true
    }
    catch {
        $answer.Error = Protect-DemoText -Text $_.Exception.Message
    }
    return [pscustomobject]$answer
}

function Update-DemoBusyMarker {
    <#
    .SYNOPSIS
    One refresh of a running deploy.ps1's busy marker (2026-11-14), from its refresher (Invoke-DemoBusyMarkerLoop): marks
    the demo busy until leadMinutes ahead; keeps the VMs' auto-shutdown out of the run's way
    (Sync-DemoAutoShutdownForBusy); and when a nightly pass falls inside the run (Get-DemoBusyNightlyPass), schedules the
    deferred pass unless one runs tonight already, and says so on the console and the status page's Nightly stop row.
    Returns MarkerWritten, UntilUtc, Pass, DeferredPass (Kept, Created, NoAccount, Failed, or empty), AutoShutdown, and
    Error. Never throws. Internal.

    .DESCRIPTION
    The deferred pass is scheduled only once the marker is written: a pass with no marker would stop the run. -Known
    carries what earlier refreshes said, so each line comes once.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('deploy', 'session')]
        [string] $By = 'deploy',

        [Parameter(Mandatory)]
        [datetime] $RunStartUtc,

        [datetime] $NowUtc = [DateTime]::UtcNow,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [System.Collections.IDictionary] $Known = @{}
    )

    $setting = $script:BusyMarkerSetting
    $until = $NowUtc.AddMinutes([int]$setting['leadMinutes'])
    $answer = [ordered]@{ MarkerWritten = $false; UntilUtc = $until; Pass = $null; DeferredPass = ''; AutoShutdown = @(); Error = '' }
    if (-not $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), ('Mark the demo busy until {0}' -f (ConvertTo-DemoBusyTimeText -Utc $until)))) {
        return [pscustomobject]$answer
    }
    $shutdown = Get-DemoAutoShutdownSetting -Config $Config
    try {
        Set-DemoBusyMarker -Config $Config -By $By -UntilUtc $until -Confirm:$false
        $answer.MarkerWritten = $true
        $Known['Written'] = $true
        $Known['Until'] = $until
    }
    catch {
        $answer.Error = Protect-DemoText -Text $_.Exception.Message
        if ($Known.Contains('Written') -and -not $Known.Contains('MarkerWarned')) {
            $Known['MarkerWarned'] = $true
            Write-DemoLog -Level Warning -Message ('The busy marker couldn''t be moved on ({0}); it''s tried again in a few minutes.' -f $answer.Error)
        }
    }
    $answer.AutoShutdown = @(Sync-DemoAutoShutdownForBusy -Config $Config -UntilUtc $until -NowUtc $NowUtc -Confirm:$false)
    foreach ($change in @($answer.AutoShutdown)) {
        if ($change.Ok) {
            $Known['ShutdownClock'] = $change.To
            Write-DemoLog -Message ('{0}''s auto-shutdown moved from {1} to {2} ({3}), so it doesn''t stop the VM while this run works; the run''s end, start-demo.ps1, stop-demo.ps1, and the next template put it back.' -f $change.VmName, (Format-DemoClockText -Clock $change.From), (Format-DemoClockText -Clock $change.To), $shutdown.TimeZoneId)
        }
        elseif (-not $Known.Contains(('ShutdownWarned-{0}' -f $change.VmName))) {
            $Known[('ShutdownWarned-{0}' -f $change.VmName)] = $true
            Write-DemoLog -Level Warning -Message ('{0}''s auto-shutdown couldn''t be moved out of this run''s way: {1}. It''s tried again in a few minutes.' -f $change.VmName, $change.Error)
        }
    }
    $pass = Get-DemoBusyNightlyPass -Config $Config -FromUtc $RunStartUtc -UntilUtc $until
    if ($null -eq $pass -or -not $answer.MarkerWritten) {
        return [pscustomobject]$answer
    }
    $answer.Pass = $pass
    $deferred = Get-DemoBusyDeferredPass -Config $Config
    if ($deferred.Exists -and $deferred.Enabled -and $null -ne $deferred.ExpiryUtc -and $deferred.ExpiryUtc -gt $until) {
        $answer.DeferredPass = 'Kept'
    }
    else {
        $start = (Get-DemoBusyLocalTime -Utc $until.AddMinutes([int]$setting['passMarginMinutes']) -Zone $shutdown.Zone).Utc
        $made = Set-DemoBusyDeferredPass -Config $Config -StartUtc $start -ExpiryUtc $pass.Utc.AddHours([int]$setting['expiryHours']) -Confirm:$false
        $answer.DeferredPass = if ($made.Ok) { 'Created' } elseif ($made.NoAccount) { 'NoAccount' } else { 'Failed' }
        if (-not $made.Ok -and -not $Known.Contains('PassWarned')) {
            $Known['PassWarned'] = $true
            Write-DemoLog -Level Warning -Message ('The deferred nightly pass couldn''t be scheduled yet ({0}); it''s tried again in a few minutes, and the run''s end schedules it.' -f $made.Error)
        }
    }
    $untilText = (Get-DemoBusyLocalTime -Utc $until -Zone $shutdown.Zone).Text
    $text = 'The nightly {0} waits for this run: the demo is marked busy until {1}, and the mark moves on every {2} minutes while the run goes on. When the run ends, DONE says when the demo stops.' -f (Get-DemoBusyPassText -Pass $pass), $untilText, [int]$setting['refreshMinutes']
    if (-not $Known.Contains('Crossed')) {
        $Known['Crossed'] = $true
        Write-DemoLog -Message $text
    }
    if ($ProgressPath) {
        Set-DemoProgressStep -Path $ProgressPath -Id 'NightlyStop' -State 'Running' -Message $text
    }
    return [pscustomobject]$answer
}

function Test-DemoBusyParentAlive {
    # Whether deploy.ps1's own process still runs: the one with -ProcessId that started at -StartTicks (UTC ticks; 0 takes
    # any). Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [int] $ProcessId,

        [long] $StartTicks = 0
    )

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $false
    }
    try {
        return ($StartTicks -le 0 -or $process.StartTime.ToUniversalTime().Ticks -eq $StartTicks)
    }
    catch {
        return $true
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-DemoBusyMarkerLoop {
    <#
    .SYNOPSIS
    The busy marker's refresher (2026-11-14), in its own process while deploy.ps1 runs (Start-DemoBusyMarkerRun): a
    refresh (Update-DemoBusyMarker) every refreshMinutes, every 2 minutes until the marker is first written (a first
    deployment's group doesn't exist until its template), and a check of the VMs' auto-shutdown every 2 minutes in the 16
    minutes before autoShutdownTime, when the template may have set it back. It ends when deploy.ps1's process is gone, so
    an abandoned run's marker expires. Internal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('deploy', 'session')]
        [string] $By = 'deploy',

        [Parameter(Mandatory)]
        [datetime] $RunStartUtc,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [int] $ParentId = 0,

        [long] $ParentStartTicks = 0,

        [int] $MaxTicks = 0
    )

    $known = @{}
    $setting = Get-DemoAutoShutdownSetting -Config $Config
    $last = [datetime]::MinValue
    $lastCheck = [datetime]::MinValue
    $ticks = 0
    while ($true) {
        if ($ParentId -gt 0 -and -not (Test-DemoBusyParentAlive -ProcessId $ParentId -StartTicks $ParentStartTicks)) {
            Write-DemoLog -Message 'deploy.ps1 ended, so the busy marker isn''t moved on any more: it expires on its own, and the nightly stop goes on.'
            return
        }
        $now = [DateTime]::UtcNow
        $every = if ($known.Contains('Written')) { [int]$script:BusyMarkerSetting['refreshMinutes'] } else { 2 }
        # A refresh that throws doesn't end the refresher: the next one tries again, well before the marker expires.
        try {
            if (($now - $last).TotalMinutes -ge $every) {
                $last = $now
                $lastCheck = $now
                $ticks++
                $null = Update-DemoBusyMarker -Config $Config -By $By -RunStartUtc $RunStartUtc -NowUtc $now -ProgressPath $ProgressPath -Known $known -Confirm:$false
            }
            elseif ($known.Contains('Until') -and ($now - $lastCheck).TotalMinutes -ge 2) {
                $next = Get-DemoDailyNextUtc -Time $setting.Time -Zone $setting.Zone -AfterUtc $now
                if ($null -ne $next -and ($next - $now).TotalMinutes -le 16) {
                    $lastCheck = $now
                    foreach ($change in @(Sync-DemoAutoShutdownForBusy -Config $Config -UntilUtc ([datetime]$known['Until']) -NowUtc $now -Confirm:$false | Where-Object { $_.Ok })) {
                        Write-DemoLog -Message ('{0}''s auto-shutdown moved from {1} to {2} ({3}), so it doesn''t stop the VM while this run works.' -f $change.VmName, (Format-DemoClockText -Clock $change.From), (Format-DemoClockText -Clock $change.To), $setting.TimeZoneId)
                    }
                }
            }
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The busy marker''s refresh failed this time ({0}); it''s tried again in a few minutes.' -f (Protect-DemoText -Text $_.Exception.Message))
        }
        if ($MaxTicks -gt 0 -and $ticks -ge $MaxTicks) {
            return
        }
        Start-Sleep -Seconds 30
    }
}

function Start-DemoBusyMarkerRun {
    <#
    .SYNOPSIS
    Starts a deploy.ps1 run's busy marker (2026-11-14), from Start-DemoDeploymentRun: its refresher runs in its own
    PowerShell process, with its own subscription guard, until Complete-DemoBusyMarkerRun ends it
    (Invoke-DemoBusyMarkerLoop). Returns Job, StartedUtc, By, and Completed, or $null with -WhatIf. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $ProgressPath = ''
    )

    if (-not $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), 'Mark the demo busy while deploy.ps1 runs, so the nightly stop waits for it')) {
        return $null
    }
    $modulePath = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1'
    $configXml = [System.Management.Automation.PSSerializer]::Serialize($Config, 20)
    $parentStart = [long]0
    try {
        $parentStart = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
    }
    catch {
        $parentStart = 0
    }
    $started = [DateTime]::UtcNow
    $refresher = {
        param([string] $BusyModulePath, [string] $BusyConfigXml, [long] $BusyStartTicks, [string] $Progress, [int] $ParentId, [long] $ParentStart)
        # This process's ID and start time first, so deploy.ps1 can end it at once (Stop-DemoRunJob).
        'DBHUB-PID {0} {1}' -f $PID, $(try { [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks } catch { 0 })
        $ErrorActionPreference = 'Stop'
        $env:DBHUB_LOG_TRACK = 'Nightly'
        Import-Module -Name $BusyModulePath -Force
        $configValue = [System.Management.Automation.PSSerializer]::Deserialize($BusyConfigXml)
        $module = Get-Module -Name 'DbHubDemo'
        & $module {
            param($LoopConfig, $LoopStartTicks, $LoopProgress, $LoopParent, $LoopParentStart)
            try {
                $null = Assert-DemoAzContext -SubscriptionId ([string]$LoopConfig['subscriptionId']) -TenantId ([string]$LoopConfig['tenantId']) -Account ([string]$LoopConfig['azureAccount'])
            }
            catch {
                Write-DemoLog -Level Warning -Message ('The nightly stop can''t wait for this run: the subscription guard failed in the busy marker''s process ({0}).' -f (Protect-DemoText -Text $_.Exception.Message).TrimEnd('.'))
                return
            }
            Invoke-DemoBusyMarkerLoop -Config $LoopConfig -By 'deploy' -RunStartUtc ([datetime]::new($LoopStartTicks, [System.DateTimeKind]::Utc)) -ProgressPath $LoopProgress -ParentId $LoopParent -ParentStartTicks $LoopParentStart
        } $configValue $BusyStartTicks $Progress $ParentId $ParentStart
    }
    $job = Start-Job -Name 'dbhub-busy-marker' -ScriptBlock $refresher -ArgumentList $modulePath, $configXml, $started.Ticks, $ProgressPath, $PID, $parentStart
    $run = [pscustomobject]@{ Job = $job; StartedUtc = $started; By = 'deploy'; Completed = $false }
    $script:BusyMarkerRun = $run
    return $run
}

function Receive-DemoBusyMarkerOutput {
    # What the busy marker's refresher logged since the last read goes to the console (its lines carry [Nightly]), and its
    # process ID is kept for Stop-DemoRunJob. Never throws. Internal.
    [CmdletBinding()]
    param()

    $run = $script:BusyMarkerRun
    if ($null -eq $run -or $null -eq $run.Job) {
        return
    }
    try {
        $null = Receive-DemoDeploymentTrackOutput -Job $run.Job
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The busy marker''s output couldn''t be read: {0}' -f $_.Exception.Message)
    }
}

function Get-DemoBusyMarkerEndText {
    # DEPLOY.NIGHTLYSTOP's message for a run the nightly stop waited for: -Pass is the nightly pass that came during the run,
    # or $null when an earlier run's deferred stop waited for this one too. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Pass,

        [Parameter(Mandatory)]
        [string] $StopText,

        [Parameter(Mandatory)]
        [string] $TimeZone,

        [int] $GraceMinutes = 60,

        [bool] $PassScheduled = $true,

        [AllowEmptyString()]
        [string] $PassError = '',

        [bool] $ShutdownSet = $true
    )

    $first = if ($null -ne $Pass) {
        'The nightly stop waited for this run: its {0} found deploy.ps1 still running, so it changed nothing.' -f (Get-DemoBusyPassText -Pass $Pass)
    }
    else {
        'The nightly stop was already waiting tonight, for an earlier run, and it waited for this one too.'
    }
    if ($PassScheduled) {
        $then = ' The demo now stops at {0} ({1}), {2} minutes after this run ended: the deferred pass dbhub-safety-deferred stops the VMs and T4{3}.' -f $StopText, $TimeZone, $GraceMinutes, $(if ($ShutdownSet) { ', and the VMs'' auto-shutdown is set to that time for tonight' } else { '' })
        return ($first + $then)
    }
    $why = if ($PassError) { ' ({0})' -f $PassError.TrimEnd('.') } else { '' }
    if ($ShutdownSet) {
        return ($first + (' The VMs'' auto-shutdown stops the VMs at {0} ({1}), {2} minutes after this run ended; the deferred pass that would stop T4 then couldn''t be scheduled{3}, so T4 runs until ./scripts/stop-demo.ps1 or the next nightly stop.' -f $StopText, $TimeZone, $GraceMinutes, $why))
    }
    return ($first + (' Neither the deferred pass{0} nor the VMs'' auto-shutdown could be set for tonight, so the demo runs until ./scripts/stop-demo.ps1 or the next nightly stop.' -f $why))
}

function Complete-DemoBusyMarkerRun {
    <#
    .SYNOPSIS
    Ends a deploy.ps1 run's busy marker (2026-11-14), from Complete-DemoDeploymentRun: stops its refresher, then settles
    what the nightly stop does tonight. Returns the results to add (DEPLOY.NIGHTLYSTOP, or none). Never throws. Internal.

    .DESCRIPTION
    - A nightly pass came during the run (Get-DemoBusyNightlyPass from the run's start until now), so the nightly stop
      waited for it, or an earlier run's deferred stop that hasn't run yet waited for it too: the marker becomes
      deploy-grace for graceMinutes, the deferred pass starts at its end plus passMarginMinutes, and the VMs'
      auto-shutdown is set to that time, so the demo still stops tonight, with or without the safety stop's role.
      DEPLOY.NIGHTLYSTOP is a Warning that says when, with the two commands that change it; DONE and NOT DONE say it too
      (Get-DemoBusyMarkerNote), and so does the status page's Nightly stop row.
    - Otherwise the deferred pass, when there's one, isn't needed (tonight's stop is still to come, it expired, or it
      already stopped the demo before this run started it again), so it's removed; the VMs' auto-shutdown goes back to
      autoShutdownTime, and the marker is cleared. DEPLOY.NIGHTLYSTOP is a Pass when something was put back.
    - -Stopped (Ctrl+C): the refresher stops, and the marker expires at once as 'ended', so the nightly stop goes on and
      start-demo.ps1, stop-demo.ps1, or the next deploy.ps1 puts back what the refresher moved; one tag write, so the
      ending stays fast.
    A step that fails leaves the marker expired as 'ended' too. Nothing is done after a run whose subscription guard
    failed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [AllowNull()]
        [object] $Run,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [switch] $Stopped,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    if ($null -eq $Run -or [bool](Get-DemoMemberValue -InputObject $Run -Name 'Completed')) {
        return @()
    }
    $Run.Completed = $true
    $job = Get-DemoMemberValue -InputObject $Run -Name 'Job'
    if ($null -ne $job) {
        try {
            $null = Receive-DemoDeploymentTrackOutput -Job $job
        }
        catch {
            Write-DemoLog -Level Debug -Message ('The busy marker''s output couldn''t be read: {0}' -f $_.Exception.Message)
        }
        $null = Stop-DemoRunJob -Job @($job) -GraceSeconds 2
    }
    if ([object]::ReferenceEquals($script:BusyMarkerRun, $Run)) {
        $script:BusyMarkerRun = $null
    }
    if (@($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'PREFLIGHT.GUARD.CONTEXT' -and [string]$_.status -eq 'Fail' }).Count -gt 0) {
        return @()
    }
    if (-not $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), 'Settle the nightly stop at the end of this run')) {
        return @()
    }
    $setting = $script:BusyMarkerSetting
    $shutdown = Get-DemoAutoShutdownSetting -Config $Config
    $doc = $script:BusyMarkerDoc
    if ($Stopped) {
        # One tag write and no read, so a stopped run's ending stays fast: the marker expires at once as 'ended', so the
        # nightly stop goes on, and start-demo.ps1, stop-demo.ps1, and the next deploy.ps1 put back what the refresher moved.
        # Before a first deployment's template there's no group to write to, and nothing to settle.
        try {
            Set-DemoBusyMarker -Config $Config -By 'ended' -UntilUtc $NowUtc -Confirm:$false
            Write-DemoLog -Message 'deploy.ps1 was stopped, so the nightly stop no longer waits for it.'
        }
        catch {
            Write-DemoLog -Level Debug -Message ('The busy marker wasn''t ended: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        }
        return @()
    }
    try {
        $state = Get-DemoDeploymentState -Config $Config
        if (-not [bool]$state.Exists) {
            return @()
        }
        $marker = ConvertTo-DemoBusyMarker -Tags $state.Tags -NowUtc $NowUtc
        $startUtc = [datetime](Get-DemoMemberValue -InputObject $Run -Name 'StartedUtc')
        $pass = Get-DemoBusyNightlyPass -Config $Config -FromUtc $startUtc -UntilUtc $NowUtc
        # A deferred pass that stands in for tonight's stop, which already came, and whose first run comes after this run
        # started (an earlier run's, during its grace): that stop now waits for this run too. One whose night's stop is still
        # to come, one that expired, and one that already stopped the demo before this run started it again, don't.
        $deferred = Get-DemoBusyDeferredPass -Config $Config
        $tonight = Get-DemoSafetyStopRunAfter -Config $Config -AfterUtc $NowUtc
        $pending = $deferred.Exists -and $deferred.Enabled -and $null -ne $deferred.ExpiryUtc -and $deferred.ExpiryUtc -gt $NowUtc -and ($null -eq $tonight -or $tonight.Utc -ge $deferred.ExpiryUtc) -and $null -ne $deferred.StartUtc -and $deferred.StartUtc -gt $startUtc
        if ($null -ne $pass -or $pending) {
            $graceEnd = $NowUtc.AddMinutes([int]$setting['graceMinutes'])
            Set-DemoBusyMarker -Config $Config -By 'deploy-grace' -UntilUtc $graceEnd -Confirm:$false
            $stopAt = Get-DemoBusyLocalTime -Utc $graceEnd.AddMinutes([int]$setting['passMarginMinutes']) -Zone $shutdown.Zone -StepMinutes 5
            $expiry = if ($null -ne $pass) { $pass.Utc.AddHours([int]$setting['expiryHours']) } else { [datetime]$deferred.ExpiryUtc }
            $scheduled = Set-DemoBusyDeferredPass -Config $Config -StartUtc $stopAt.Utc -ExpiryUtc $expiry -Confirm:$false
            $changes = @(Sync-DemoAutoShutdownForBusy -Config $Config -TargetClock $stopAt.Clock -NowUtc $NowUtc -Confirm:$false)
            $shutdownSet = @($changes | Where-Object { -not $_.Ok }).Count -eq 0
            $message = Get-DemoBusyMarkerEndText -Pass $pass -StopText $stopAt.Text -TimeZone $shutdown.TimeZoneId -GraceMinutes ([int]$setting['graceMinutes']) -PassScheduled ([bool]$scheduled.Ok) -PassError ([string]$scheduled.Error) -ShutdownSet $shutdownSet
            $remediation = 'To keep the demo running tonight, run ./scripts/start-demo.ps1: it cancels this stop, and the next nightly stop is tomorrow at {0}. To stop the demo now, run ./scripts/stop-demo.ps1.' -f (Format-DemoClockText -Clock $shutdown.Time)
            $evidence = [ordered]@{ pass = $(if ($null -ne $pass) { [string]$pass.Run } else { 'EarlierRun' }); passLocalTime = $(if ($null -ne $pass) { [string]$pass.LocalTime } else { '' }); timeZone = $shutdown.TimeZoneId; busyUntilUtc = (ConvertTo-DemoBusyTimeText -Utc $graceEnd); stopsAtUtc = (ConvertTo-DemoBusyTimeText -Utc $stopAt.Utc); stopsAt = $stopAt.Text; graceMinutes = [int]$setting['graceMinutes']; deferredPass = $(if ($scheduled.Ok) { 'Scheduled' } else { 'Failed' }); deferredPassError = [string]$scheduled.Error; autoShutdown = @($changes | ForEach-Object { '{0}: {1} -> {2}{3}' -f $_.VmName, $_.From, $_.To, $(if ($_.Ok) { '' } else { ' (failed: {0})' -f $_.Error }) }) }
            if ($ProgressPath) {
                Set-DemoProgressStep -Path $ProgressPath -Id 'NightlyStop' -State 'Done' -Status 'Warning' -Message ('{0} {1}' -f $message, $remediation)
            }
            return @(New-DemoResult -CheckId 'DEPLOY.NIGHTLYSTOP' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $doc)
        }
        $put = [System.Collections.Generic.List[string]]::new()
        $left = $false
        if ($deferred.Exists) {
            # Tonight's stop is still to come, or the pass expired: it's not needed.
            $removed = Remove-DemoBusyDeferredPass -Config $Config -Confirm:$false
            if ($removed.Removed) {
                $put.Add('the deferred pass dbhub-safety-deferred is removed')
            }
            elseif ($removed.Error) {
                $left = $true
                Write-DemoLog -Level Warning -Message ('The deferred nightly pass couldn''t be removed: {0}. start-demo.ps1, stop-demo.ps1, and the next deploy.ps1 try again.' -f $removed.Error)
            }
        }
        elseif ($deferred.Error) {
            $left = $true
        }
        foreach ($change in @(Sync-DemoAutoShutdownForBusy -Config $Config -Restore -NowUtc $NowUtc -Confirm:$false)) {
            if ($change.Ok) {
                $put.Add(('{0}''s auto-shutdown is back at {1}' -f $change.VmName, (Format-DemoClockText -Clock $change.To)))
            }
            else {
                $left = $true
                Write-DemoLog -Level Warning -Message ('{0}''s auto-shutdown couldn''t be put back at {1}: {2}. start-demo.ps1, stop-demo.ps1, and the next deploy.ps1 try again.' -f $change.VmName, (Format-DemoClockText -Clock $shutdown.Time), $change.Error)
            }
        }
        # The marker goes once nothing is left to settle; a step that failed leaves it expired as 'ended', so start-demo.ps1,
        # stop-demo.ps1, and the next deploy.ps1 settle it.
        if ($left) {
            Set-DemoBusyMarker -Config $Config -By 'ended' -UntilUtc $NowUtc -Confirm:$false
        }
        elseif ($marker.Text) {
            Clear-DemoBusyMarker -Config $Config -Confirm:$false
        }
        if ($put.Count -eq 0) {
            if ($ProgressPath) {
                Set-DemoProgressStep -Path $ProgressPath -Id 'NightlyStop' -State 'Skipped' -Message 'Not needed: no nightly stop came while this run worked.'
            }
            return @()
        }
        $upcoming = Get-DemoSafetyStopRunAfter -Config $Config -AfterUtc $NowUtc
        $endMessage = 'No nightly stop waits for this run: the next one runs as usual{0}, and {1}.' -f $(if ($null -ne $upcoming) { ' at {0} ({1})' -f $upcoming.LocalTime, $upcoming.TimeZone } else { '' }), ($put -join ', ')
        if ($ProgressPath) {
            Set-DemoProgressStep -Path $ProgressPath -Id 'NightlyStop' -State 'Done' -Status 'Pass' -Message $endMessage
        }
        return @(New-DemoResult -CheckId 'DEPLOY.NIGHTLYSTOP' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message $endMessage -Evidence ([ordered]@{ put = $put.ToArray(); timeZone = $shutdown.TimeZoneId }) -DocUrl $doc)
    }
    catch {
        $text = Protect-DemoText -Text $_.Exception.Message
        if ($ProgressPath) {
            Set-DemoProgressStep -Path $ProgressPath -Id 'NightlyStop' -State 'Done' -Status 'Warning' -Message ('The nightly stop couldn''t be settled at the end of this run: {0}' -f $text)
        }
        return @(New-DemoResult -CheckId 'DEPLOY.NIGHTLYSTOP' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('The nightly stop couldn''t be settled at the end of this run: {0}. The busy marker expires within {1} minutes of its last move, and the nightly stop goes on after that.' -f $text, [int]$setting['leadMinutes']) -Remediation 'Run ./scripts/stop-demo.ps1 to stop the demo now, or ./scripts/start-demo.ps1 to keep it running tonight; either one settles it.' -DocUrl $doc)
    }
}

function Get-DemoBusyMarkerNote {
    # DONE's and NOT DONE's line when the nightly stop waited for this run (DEPLOY.NIGHTLYSTOP, a Warning): when the demo
    # stops tonight, and the two commands that change it. Empty otherwise. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $item = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'DEPLOY.NIGHTLYSTOP' -and [string]$_.status -eq 'Warning' }) | Select-Object -Last 1
    if ($null -eq $item) {
        return ''
    }
    $fix = [string](Get-DemoMemberValue -InputObject $item -Name 'remediation')
    return ('{0} {1}' -f ([string]$item.message).TrimEnd(), $fix).Trim()
}

function Resolve-DemoBusyNightlyStop {
    <#
    .SYNOPSIS
    start-demo.ps1 and stop-demo.ps1 settle the nightly stop (2026-11-14): a session that starts takes over from a run the
    nightly stop waited for, and a stop stops everything now. Only when the busy marker's tag holds anything (a run that's
    going on, its grace, or 'ended' with something left to settle): the deferred pass is removed, the VMs' auto-shutdown
    goes back to autoShutdownTime, and then the marker is cleared, or kept expired as 'ended' when part of it failed, so the
    next run tries again. start-demo.ps1 leaves alone the marker of a deploy.ps1 or a session that's still going on.
    Returns START.NIGHTLYSTOP or STOP.NIGHTLYSTOP: a Pass when it changed something, a Warning when part of it failed;
    nothing otherwise. Never throws. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State,

        [Parameter(Mandatory)]
        [ValidateSet('Start', 'Stop')]
        [string] $Purpose,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $checkId = '{0}.NIGHTLYSTOP' -f $Purpose.ToUpperInvariant()
    $shutdown = Get-DemoAutoShutdownSetting -Config $Config
    $marker = ConvertTo-DemoBusyMarker -Tags (Get-DemoMemberValue -InputObject $State -Name 'Tags') -NowUtc $NowUtc
    if (-not $marker.Text) {
        return @()
    }
    if ($Purpose -eq 'Start' -and $marker.Active -and $marker.By -in 'deploy', 'session') {
        return @()
    }
    if (-not $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), 'Settle the nightly stop for this session')) {
        return @()
    }
    $done = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    $removed = Remove-DemoBusyDeferredPass -Config $Config -Confirm:$false
    if ($removed.Removed) {
        $done.Add('the deferred nightly pass dbhub-safety-deferred is removed')
    }
    elseif ($removed.Error) {
        $failed.Add(('the deferred nightly pass couldn''t be removed: {0}' -f $removed.Error))
    }
    foreach ($change in @(Sync-DemoAutoShutdownForBusy -Config $Config -Restore -NowUtc $NowUtc -Confirm:$false)) {
        if ($change.Ok) {
            $done.Add(('{0}''s auto-shutdown is back at {1}' -f $change.VmName, (Format-DemoClockText -Clock $change.To)))
        }
        else {
            $failed.Add(('{0}''s auto-shutdown: {1}' -f $change.VmName, $change.Error))
        }
    }
    try {
        if ($failed.Count -gt 0) {
            Set-DemoBusyMarker -Config $Config -By 'ended' -UntilUtc $NowUtc -Confirm:$false
        }
        else {
            # Cleared without a word when nothing else needed putting back (a run stopped before anything moved).
            Clear-DemoBusyMarker -Config $Config -Confirm:$false
            if ($done.Count -gt 0) {
                $done.Add(('the busy marker ({0}) is cleared' -f $(if ($marker.By) { $marker.By } else { 'unknown' })))
            }
        }
    }
    catch {
        $failed.Add(('the busy marker couldn''t be written: {0}' -f (Protect-DemoText -Text $_.Exception.Message)))
    }
    if ($done.Count -eq 0 -and $failed.Count -eq 0) {
        return @()
    }
    $why = if ($Purpose -eq 'Start') { 'This session takes over from a run the nightly stop waited for' } else { 'Everything stops now, so nothing waits for the nightly stop' }
    $next = if ($Purpose -eq 'Start') { ' The demo runs until ./scripts/stop-demo.ps1 or the next nightly stop at {0} ({1}).' -f (Format-DemoClockText -Clock $shutdown.Time), $shutdown.TimeZoneId } else { '' }
    $evidence = [ordered]@{ done = $done.ToArray(); failed = $failed.ToArray(); marker = $marker.Text; markerBy = $marker.By }
    if ($failed.Count -gt 0) {
        return @(New-DemoResult -CheckId $checkId -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('{0}, but not all of it was put back: {1}.{2}' -f $why, ($failed -join '; '), $next) -Evidence $evidence -Remediation ('Run ./scripts/{0}-demo.ps1 again; ./scripts/status.ps1 shows what''s left (STATUS.NIGHTLYSTOP).' -f $Purpose.ToLowerInvariant()) -DocUrl $script:BusyMarkerDoc)
    }
    return @(New-DemoResult -CheckId $checkId -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('{0}: {1}.{2}' -f $why, ($done -join ', '), $next) -Evidence $evidence -DocUrl $script:BusyMarkerDoc)
}

function Get-DemoBusyMarkerStatus {
    <#
    .SYNOPSIS
    STATUS.NIGHTLYSTOP for status.ps1 (2026-11-14), read-only, when the busy marker's tag holds anything: the marker while
    it's ahead, the deferred pass while it's to come, and the VMs' auto-shutdown when it isn't at autoShutdownTime. A Pass
    while a run or the pass explains it; a Warning for an auto-shutdown that's moved with neither, with the commands that
    put it back. $null when the tag is empty. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    try {
        $shutdown = Get-DemoAutoShutdownSetting -Config $Config
        $marker = ConvertTo-DemoBusyMarker -Tags (Get-DemoMemberValue -InputObject $State -Name 'Tags') -NowUtc $NowUtc
        if (-not $marker.Text) {
            # Nothing a run moved is left without its marker (Complete-DemoBusyMarkerRun, Resolve-DemoBusyNightlyStop).
            return $null
        }
        $deferred = Get-DemoBusyDeferredPass -Config $Config
        $parts = [System.Collections.Generic.List[string]]::new()
        $evidence = [ordered]@{ marker = $marker.Text; markerBy = $marker.By; markerState = $marker.Reason }
        if ($marker.Active) {
            $who = switch ($marker.By) {
                'deploy' { 'deploy.ps1 is running' }
                'deploy-grace' { 'deploy.ps1 ended after the nightly stop waited for it' }
                'session' { 'a demo session is running' }
                default { 'a run is busy' }
            }
            $untilText = (Get-DemoBusyLocalTime -Utc $marker.UntilUtc -Zone $shutdown.Zone).Text
            $parts.Add(('{0}, so the nightly stop waits until {1} ({2}).' -f $who, $untilText, $shutdown.TimeZoneId))
        }
        $passPending = $deferred.Exists -and $deferred.Enabled -and $null -ne $deferred.NextRunUtc -and ($null -eq $deferred.ExpiryUtc -or $deferred.NextRunUtc -lt $deferred.ExpiryUtc)
        if ($passPending) {
            $evidence['deferredNextRunUtc'] = ConvertTo-DemoBusyTimeText -Utc $deferred.NextRunUtc
            $parts.Add(('The deferred nightly pass dbhub-safety-deferred runs next at {0} ({1}), hourly until the morning, and stops the demo once no run keeps it busy.' -f (Get-DemoBusyLocalTime -Utc $deferred.NextRunUtc -Zone $shutdown.Zone).Text, $shutdown.TimeZoneId))
        }
        $moved = [System.Collections.Generic.List[string]]::new()
        foreach ($vm in @('sqlvm01', (Get-DemoHostVmName -Config $Config))) {
            $schedule = Read-DemoAutoShutdown -Config $Config -VmName $vm
            if ($schedule.Ok -and $schedule.Time -and $schedule.Time -ne $shutdown.Time) {
                $moved.Add(('{0} at {1}' -f $vm, (Format-DemoClockText -Clock $schedule.Time)))
            }
        }
        $evidence['autoShutdownMoved'] = $moved.ToArray()
        if ($moved.Count -gt 0) {
            $parts.Add(('The VMs'' auto-shutdown is moved from {0} ({1}): {2}.' -f (Format-DemoClockText -Clock $shutdown.Time), $shutdown.TimeZoneId, ($moved -join ', ')))
        }
        if ($parts.Count -eq 0) {
            return $null
        }
        if ($moved.Count -gt 0 -and -not $marker.Active -and -not $passPending) {
            return (New-DemoResult -CheckId 'STATUS.NIGHTLYSTOP' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message (($parts -join ' ') + ' No run keeps it there: a run was abandoned, or it ended without the safety stop''s role.') -Evidence $evidence -Remediation ('./scripts/start-demo.ps1, ./scripts/stop-demo.ps1, and ./scripts/deploy.ps1 put it back at {0}.' -f (Format-DemoClockText -Clock $shutdown.Time)) -DocUrl $script:AutoShutdownDoc)
        }
        return (New-DemoResult -CheckId 'STATUS.NIGHTLYSTOP' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ($parts -join ' ') -Evidence $evidence -DocUrl $script:BusyMarkerDoc)
    }
    catch {
        return (New-DemoResult -CheckId 'STATUS.NIGHTLYSTOP' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('Whether the nightly stop waits for a run couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/status.ps1 again.' -DocUrl $script:BusyMarkerDoc)
    }
}
