# deploy.ps1's side of the guest restart that clears a broken PowerShell Direct channel into T2's guest (issue #65,
# 2026-11-18). The T2 host decides and restarts (vm/hyperv-guest/GuestVm.ps1, Invoke-DemoGuestRecovery), because only it
# sees the guest: its bootstrap, the Arc onboarding's Run Commands, and T2's relay (activity profiles, Run all) each clear
# a broken channel by restarting the guest at most once for the run that asks. deploy.ps1 gives its run a key of its own
# (New-DemoRunRecoveryKey), so a rerun gets its own restart, and reports each restart once, as DEPLOY.T2.GUESTRESTART, a
# Warning that says what broke and that the restart cleared it, in the run's results and summary, and on the status page's
# T2.GuestRestart row.

function New-DemoRunRecoveryKey {
    # A run's recovery key: 'deploy-' and 12 hexadecimal characters of the run's ID (the status page's runId), or of a new
    # GUID. Pure.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure: returns a new key; changes nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $RunId = '',

        [ValidatePattern('^[a-z]{1,10}$')]
        [string] $Prefix = 'deploy'
    )

    $hex = ($RunId -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
    if ($hex.Length -lt 12) {
        $hex = [guid]::NewGuid().ToString('N')
    }
    return ('{0}-{1}' -f $Prefix, $hex.Substring(0, 12))
}

function Set-DemoRunRecoveryKey {
    # The key this process passes to the T2 host's recovery (Get-DemoRunRecoveryKey); empty clears it. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets a module variable only.')]
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Key = ''
    )

    $script:DemoRunRecoveryKey = if ($Key -match '^[A-Za-z0-9._:-]{1,80}$') { $Key } else { '' }
}

function Get-DemoRunRecoveryKey {
    # The run's recovery key, or '' outside a run that set one: the host then restarts the guest at most once an hour.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [string]$script:DemoRunRecoveryKey
}

function ConvertTo-DemoRecoveryUtcText {
    # A restart's time as 'yyyy-MM-ddTHH:mm:ssZ', from the host's ISO text or the DateTime that PowerShell 7's
    # ConvertFrom-Json makes of it, so the same restart reads the same from every source. '' when it isn't a time. Pure.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Value
    )

    $when = [datetime]::MinValue
    if ($Value -is [datetime]) {
        $when = if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) } else { $Value.ToUniversalTime() }
    }
    elseif ($Value -is [datetimeoffset]) {
        $when = $Value.UtcDateTime
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$Value)) {
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        if (-not [datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$when)) {
            return ''
        }
    }
    else {
        return ''
    }
    return $when.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-DemoGuestRecovery {
    <#
    .SYNOPSIS
    One recovery from a broken PowerShell Direct channel, read from what reported it: the T2 host's health
    (guestRecovery, the last restart: startedUtc, endedUtc, by, seconds, stoppedBy, recovered, reason), or the Arc
    onboarding's or T2 relay's evidence (guestRecovery: action, restarted, recovered, atUtc, restartUtc, by, seconds,
    stoppedBy, reason). Returns Kind (Restart, or Retry: the break was over, and the step ran again without a restart),
    AtUtc, By, Seconds, StoppedBy, Recovered, and Reason, or $null when there's neither. Pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $restartUtc = ConvertTo-DemoRecoveryUtcText -Value (Get-DemoMemberValue -InputObject $InputObject -Name 'restartUtc')
    if (-not $restartUtc) {
        $restartUtc = ConvertTo-DemoRecoveryUtcText -Value (Get-DemoMemberValue -InputObject $InputObject -Name 'startedUtc')
    }
    $restarted = Get-DemoMemberValue -InputObject $InputObject -Name 'restarted'
    $kind = 'Restart'
    $at = $restartUtc
    if (-not $restartUtc -or ($null -ne $restarted -and -not [bool]$restarted)) {
        # A break that was over when the guest was probed again: the step ran again without a restart.
        $at = ConvertTo-DemoRecoveryUtcText -Value (Get-DemoMemberValue -InputObject $InputObject -Name 'atUtc')
        if ([string](Get-DemoMemberValue -InputObject $InputObject -Name 'action') -ne 'Healed' -or -not $at) {
            return $null
        }
        $kind = 'Retry'
    }
    # The host's record says endedUtc once its restart is over; one that's still going is reported by a later read.
    $ended = $InputObject.PSObject.Properties['endedUtc']
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains('endedUtc') -and -not [string]$InputObject['endedUtc']) {
            return $null
        }
    }
    elseif ($null -ne $ended -and -not [string]$ended.Value) {
        return $null
    }
    return [pscustomobject]@{
        Kind      = $kind
        AtUtc     = $at
        By        = [string](Get-DemoMemberValue -InputObject $InputObject -Name 'by')
        Seconds   = [int](Get-DemoMemberValue -InputObject $InputObject -Name 'seconds')
        StoppedBy = [string](Get-DemoMemberValue -InputObject $InputObject -Name 'stoppedBy')
        Recovered = [bool](Get-DemoMemberValue -InputObject $InputObject -Name 'recovered')
        Reason    = (Protect-DemoText -Text ([string](Get-DemoMemberValue -InputObject $InputObject -Name 'reason'))).Trim()
    }
}

function Get-DemoGuestRecoveryRunResult {
    <#
    .SYNOPSIS
    For each recovery from a broken PowerShell Direct channel since SinceUtc that Result's evidence (guestRecovery) or
    Health (the T2 host's guestRecovery) shows and Result doesn't report yet: <CheckPrefix>.T2.GUESTRETRY, a Warning, when
    the break was over and the step ran again; <CheckPrefix>.T2.GUESTRESTART, a Warning that says what broke and that the
    guest's restart cleared it, or a Fail when the guest still didn't answer. One per recovery (by its time). Pure.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [object] $Health = $null,

        [datetime] $SinceUtc = [datetime]::MinValue,

        [ValidateSet('DEPLOY', 'START')]
        [string] $CheckPrefix = 'DEPLOY',

        [AllowEmptyString()]
        [string] $GuestName = 'arcsql01'
    )

    $restartId = '{0}.T2.GUESTRESTART' -f $CheckPrefix
    $retryId = '{0}.T2.GUESTRETRY' -f $CheckPrefix
    $reported = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Result)) {
        if ($null -eq $item) {
            continue
        }
        $evidence = Get-DemoMemberValue -InputObject $item -Name 'evidence'
        if ([string]$item.checkId -in $restartId, $retryId) {
            [void]$reported.Add((ConvertTo-DemoRecoveryUtcText -Value (Get-DemoMemberValue -InputObject $evidence -Name 'atUtc')))
            continue
        }
        $recovery = ConvertTo-DemoGuestRecovery -InputObject (Get-DemoMemberValue -InputObject $evidence -Name 'guestRecovery')
        if ($null -ne $recovery) {
            $found.Add([pscustomobject]@{ Recovery = $recovery; From = [string]$item.checkId })
        }
    }
    $fromHealth = ConvertTo-DemoGuestRecovery -InputObject (Get-DemoMemberValue -InputObject $Health -Name 'guestRecovery')
    if ($null -ne $fromHealth) {
        $found.Add([pscustomobject]@{ Recovery = $fromHealth; From = 'health' })
    }
    $since = $SinceUtc.ToUniversalTime()
    $docUrl = 'https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct'
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $found) {
        $recovery = $entry.Recovery
        $when = [datetime]::MinValue
        if (-not [datetime]::TryParse($recovery.AtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$when)) {
            continue
        }
        if ($when -lt $since -or -not $reported.Add($recovery.AtUtc)) {
            continue
        }
        $who = if ($recovery.By) { $recovery.By } else { 'archost01' }
        $why = if ($recovery.Reason) { $recovery.Reason } else { 'it stopped answering while it ran with a healthy heartbeat' }
        $evidence = [ordered]@{ kind = $recovery.Kind; atUtc = $recovery.AtUtc; by = $who; seconds = $recovery.Seconds; stoppedBy = $recovery.StoppedBy; recovered = $recovery.Recovered; reason = $why; seenIn = $entry.From }
        if ($recovery.Kind -eq 'Retry') {
            $message = 'PowerShell Direct into {0} broke for a moment at {1:HH:mm} UTC ({2}), so {3} waited until {0} answered again and ran its step again, which went on.' -f $GuestName, $when, $why, $who
            $out.Add((New-DemoResult -CheckId $retryId -Area 't2' -Target 'T2' -Status 'Warning' -Message $message -Evidence $evidence -Remediation 'Nothing to do: the step ran again. If it happens on every run, open an issue with archost01''s C:\ProgramData\DbHubDemo\logs.' -DocUrl $docUrl))
            continue
        }
        $how = if ($recovery.StoppedBy -eq 'TurnOff') { 'turned it off after its shutdown didn''t finish, and started it again' } else { 'shut it down cleanly and started it again' }
        if ($recovery.Recovered) {
            $message = 'PowerShell Direct into {0} broke at {1:HH:mm} UTC ({2}), so {3} restarted {0} once for this run: it {4}, and {0} answered again after {5} seconds, so the step went on.' -f $GuestName, $when, $why, $who, $how, $recovery.Seconds
            $out.Add((New-DemoResult -CheckId $restartId -Area 't2' -Target 'T2' -Status 'Warning' -Message $message -Evidence $evidence -Remediation 'Nothing to do: the restart cleared it. If it happens on every run, open an issue with archost01''s C:\ProgramData\DbHubDemo\logs.' -DocUrl $docUrl))
        }
        else {
            $message = 'PowerShell Direct into {0} broke at {1:HH:mm} UTC ({2}), and {3} restarted {0} once for this run, but it still didn''t answer over PowerShell Direct.' -f $GuestName, $when, $why, $who
            $out.Add((New-DemoResult -CheckId $restartId -Area 't2' -Target 'T2' -Status 'Fail' -Message $message -Evidence $evidence -Remediation 'Run ./scripts/deploy.ps1 again: a new run restarts the guest once more. If it stays broken, run ./scripts/stop-demo.ps1, then ./scripts/deploy.ps1.' -DocUrl $docUrl))
        }
    }
    return $out.ToArray()
}

function Get-DemoGuestRestartNote {
    # What DONE or NOT DONE says about this run's recovery from a broken PowerShell Direct channel into T2's guest
    # (DEPLOY.T2.GUESTRESTART or DEPLOY.T2.GUESTRETRY, Warnings); '' without one. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $warnings = @($Result | Where-Object { $null -ne $_ -and [string]$_.status -eq 'Warning' })
    if (@($warnings | Where-Object { [string]$_.checkId -like '*.T2.GUESTRESTART' }).Count -gt 0) {
        return 'PowerShell Direct into arcsql01, T2''s guest, broke in this run, and archost01 restarted arcsql01 once, which cleared it, so T2''s steps went on (DEPLOY.T2.GUESTRESTART).'
    }
    if (@($warnings | Where-Object { [string]$_.checkId -like '*.T2.GUESTRETRY' }).Count -gt 0) {
        return 'PowerShell Direct into arcsql01, T2''s guest, broke for a moment in this run; the step ran again once arcsql01 answered, and went on (DEPLOY.T2.GUESTRETRY).'
    }
    return ''
}

function Set-DemoGuestRecoveryProgress {
    # The status page's T2.GuestRestart row from DEPLOY.T2.GUESTRESTART and DEPLOY.T2.GUESTRETRY results: Done with a
    # Warning (or Failed with a Fail) and their messages. Nothing without them. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes the Git-ignored local progress model only.')]
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $recoveries = @($Result | Where-Object { $null -ne $_ -and ([string]$_.checkId -like '*.T2.GUESTRESTART' -or [string]$_.checkId -like '*.T2.GUESTRETRY') })
    if (-not $ProgressPath -or $recoveries.Count -eq 0) {
        return
    }
    $failed = @($recoveries | Where-Object { [string]$_.status -eq 'Fail' })
    $message = (@($recoveries | ForEach-Object { [string]$_.message }) -join ' ')
    if ($failed.Count -gt 0) {
        Set-DemoProgressStep -Path $ProgressPath -Id 'T2.GuestRestart' -State 'Failed' -Status 'Fail' -Message $message
    }
    else {
        Set-DemoProgressStep -Path $ProgressPath -Id 'T2.GuestRestart' -State 'Done' -Status 'Warning' -Message $message
    }
}