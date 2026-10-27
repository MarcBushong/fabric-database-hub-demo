function Invoke-DemoSignInDataAction {
    <#
    .SYNOPSIS
    Runs vm/bootstrap/Invoke-DemoSignInResidue.ps1 on a VM in a managed Run Command and parses its last JSON
    line. Returns Succeeded, Data, Error, and Seconds. Internal.

    .DESCRIPTION
    The script finds sign-in data on the VM and, with Scope Both, in the T2 guest over PowerShell Direct; with
    Clean it removes what it found and scans again (ADR 0009). It takes no secret: every parameter is public,
    its output holds counts and locations only, and the Run Command is deleted afterward
    (Invoke-DemoVmRunCommand). A Clean clears a PowerShell or Application event log only when it holds a
    token-shaped value, and never the Security log, unless an operator asks for it with -ClearSecurityLog.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('sqlvm01', 'archost01', 'arcsql01')]
        [string] $VmName,

        [ValidateSet('Scan', 'Clean')]
        [string] $Action = 'Scan',

        [ValidateSet('Local', 'Guest', 'Both')]
        [string] $Scope = 'Local',

        [switch] $IncludeBrowserCache,

        [switch] $KeepEventLogs,

        [switch] $ClearSecurityLog,

        [string] $ResourceGroupName = '',

        [ValidateRange(300, 7200)]
        [int] $TimeoutSeconds = 2400
    )

    $script = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/Invoke-DemoSignInResidue.ps1') -Raw
    $values = [ordered]@{
        ResidueAction       = $Action
        ResidueScope        = $Scope
        IncludeBrowserCache = $(if ($IncludeBrowserCache) { 'true' } else { 'false' })
        ClearEventLogs      = $(if ($KeepEventLogs) { 'false' } else { 'true' })
        ClearSecurityLog    = $(if ($ClearSecurityLog) { 'true' } else { 'false' })
    }
    $arguments = @{
        Config              = $Config
        VmName              = $VmName
        RunCommandName      = 'DbHubDemo-SignInData'
        Script              = $script
        Parameter           = $values
        TimeoutSeconds      = $TimeoutSeconds
        PollIntervalSeconds = 15
        Confirm             = $false
    }
    if ($ResourceGroupName) {
        $arguments['ResourceGroupName'] = $ResourceGroupName
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $run = Invoke-DemoVmRunCommand @arguments
    }
    catch {
        return [pscustomobject]@{ Succeeded = $false; Data = $null; Error = (Protect-DemoText -Text $_.Exception.Message); Seconds = [int]$watch.Elapsed.TotalSeconds }
    }
    $data = $null
    if ($null -ne $run) {
        $data = ConvertFrom-DemoRunCommandOutput -Text ([string]$run.Output)
    }
    $succeeded = ($null -ne $run -and $run.Succeeded -and $null -ne $data -and [bool](Get-DemoMemberValue -InputObject $data -Name 'succeeded'))
    $errorText = ''
    if (-not $succeeded) {
        $errorText = [string](Get-DemoMemberValue -InputObject $data -Name 'error')
        if (-not $errorText -and $null -ne $run) {
            $errorText = if ($run.Error) { [string]$run.Error } else { 'execution state {0}, exit code {1}' -f $run.ExecutionState, $run.ExitCode }
        }
    }
    return [pscustomobject]@{ Succeeded = $succeeded; Data = $data; Error = (Protect-DemoText -Text $errorText); Seconds = [int]$watch.Elapsed.TotalSeconds }
}

function Get-DemoSignInDataSummary {
    <#
    .SYNOPSIS
    Reads one machine's part of the sweep's output (local or guest): whether it was reached and passed, what
    was found and is left, and a short description of what's left. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Part,

        [Parameter(Mandatory)]
        [string] $Label
    )

    if ($null -eq $Part) {
        return $null
    }
    $count = {
        param($Counts, [string] $Name)
        [int](Get-DemoMemberValue -InputObject $Counts -Name $Name)
    }
    $reachable = [bool](Get-DemoMemberValue -InputObject $Part -Name 'reachable')
    $found = Get-DemoMemberValue -InputObject $Part -Name 'found'
    $remaining = Get-DemoMemberValue -InputObject $Part -Name 'remaining'
    $left = [System.Collections.Generic.List[string]]::new()
    if (-not $reachable) {
        $state = [string](Get-DemoMemberValue -InputObject $Part -Name 'state')
        $left.Add(('{0} couldn''t be reached ({1})' -f $Label, $(if ($state) { $state } else { 'no answer' })))
    }
    else {
        $userData = (& $count $remaining 'user') + (& $count $remaining 'other')
        if ($userData -gt 0) { $left.Add(('{0} sign-in token(s) in {1} file(s)' -f $userData, (& $count $remaining 'files'))) }
        if ((& $count $remaining 'logUser') -gt 0) { $left.Add(('{0} sign-in token(s) in event logs' -f (& $count $remaining 'logUser'))) }
        if ((& $count $remaining 'keys') -gt 0) { $left.Add(('{0} product key(s) in files' -f (& $count $remaining 'keys'))) }
        if ((& $count $remaining 'logKeys') -gt 0) { $left.Add(('{0} product key(s) in event logs' -f (& $count $remaining 'logKeys'))) }
        if ((& $count $remaining 'caches') -gt 0) { $left.Add(('{0} browser sign-in cache(s)' -f (& $count $remaining 'caches'))) }
        if ((& $count $remaining 'archives') -gt 0) { $left.Add(('{0} archive(s) in setup''s log folders that couldn''t be checked' -f (& $count $remaining 'archives'))) }
        if ((& $count $remaining 'unverified') -gt 0) { $left.Add(('{0} file(s) that couldn''t be read' -f (& $count $remaining 'unverified'))) }
    }
    $appTokens = 0
    $security = 0
    if ($reachable) {
        $appTokens = (& $count $found 'app') + (& $count $found 'logApp')
        $security = & $count $remaining 'security'
    }
    $actions = Get-DemoMemberValue -InputObject $Part -Name 'actions'
    $cleared = Get-DemoMemberValue -InputObject $actions -Name 'logsCleared'
    # Get-DemoMemberValue keeps an array intact, so each is unrolled from a variable.
    $eventLogs = Get-DemoMemberValue -InputObject $Part -Name 'eventLogs'
    $foundAt = Get-DemoMemberValue -InputObject $Part -Name 'found_at'
    $leftAt = Get-DemoMemberValue -InputObject $Part -Name 'left_at'
    return [pscustomobject]@{
        Label     = $Label
        Reachable = $reachable
        Pass      = $reachable -and [bool](Get-DemoMemberValue -InputObject $Part -Name 'pass')
        Found     = $found
        Remaining = $remaining
        Left      = $left.ToArray()
        AppTokens = $appTokens
        Security  = $security
        Cleared   = @($cleared | Where-Object { $_ })
        Actions   = $actions
        EventLogs = @($eventLogs | Where-Object { $null -ne $_ })
        FoundAt   = @($foundAt | Where-Object { $null -ne $_ })
        LeftAt    = @($leftAt | Where-Object { $null -ne $_ })
    }
}

function Get-DemoSignInDataResult {
    <#
    .SYNOPSIS
    The ADR 0012 result for one sweep (Invoke-DemoSignInDataAction), in this order:
    - Fail when the sweep couldn't run or reach a machine it had to, or a user's token, an unclassified token, a
      browser sign-in cache, or an unreadable file in setup's or the Run Command handlers' folders is left in a
      file or in the PowerShell and Application logs (fail closed);
    - Manual action required when a token-shaped value is in the Security log, which nothing clears on its own:
      the remediation gives the exact command;
    - Warning when the cleanup cleared an event log (endpoint protection may report that), or only an
      application's or a managed identity's token was found;
    - Pass otherwise.
    Evidence holds counts and locations only. Internal.
    #>
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
        [string] $VmName,

        [Parameter(Mandatory)]
        [object] $Outcome,

        [string] $GuestName = '',

        [string] $Remediation = 'Run ./scripts/check-sign-in-data.ps1 -Clean, then check again; read docs/security-model.md for what each location is.'
    )

    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
    $evidence = [ordered]@{ vm = $VmName; seconds = $Outcome.Seconds }
    if (-not $Outcome.Succeeded) {
        $evidence['error'] = $Outcome.Error
        return (New-DemoResult -CheckId $CheckId -Area $Area -Target $Target -Status 'Fail' -Message ('Sign-in data on {0} couldn''t be checked, so it''s treated as left (fail closed): {1}' -f $VmName, $Outcome.Error) -Evidence $evidence -Remediation 'Make sure the VM is running and Run Command works on it (a policy-installed extension can hold it for minutes), then run the check again.' -DocUrl $docUrl)
    }
    $data = $Outcome.Data
    $evidence['action'] = [string](Get-DemoMemberValue -InputObject $data -Name 'action')
    $parts = @(
        Get-DemoSignInDataSummary -Part (Get-DemoMemberValue -InputObject $data -Name 'local') -Label $VmName
        if ($GuestName) { Get-DemoSignInDataSummary -Part (Get-DemoMemberValue -InputObject $data -Name 'guest') -Label ('{0} (guest)' -f $GuestName) }
    ) | Where-Object { $null -ne $_ }
    if ($parts.Count -lt $(if ($GuestName) { 2 } else { 1 })) {
        return (New-DemoResult -CheckId $CheckId -Area $Area -Target $Target -Status 'Fail' -Message ('The sign-in data check on {0} returned no result for every machine it had to check, so sign-in data is treated as left (fail closed).' -f $VmName) -Evidence $evidence -Remediation $Remediation -DocUrl $docUrl)
    }
    foreach ($part in $parts) {
        $evidence[$part.Label] = [ordered]@{
            reachable = $part.Reachable
            pass      = $part.Pass
            found     = $part.Found
            remaining = $part.Remaining
            actions   = $part.Actions
            eventLogs = $part.EventLogs
            foundAt   = $part.FoundAt
            leftAt    = $part.LeftAt
        }
    }
    $failed = @($parts | Where-Object { -not $_.Pass })
    $cleaned = $evidence['action'] -eq 'Clean'
    if ($failed.Count -gt 0) {
        $detail = @($failed | ForEach-Object { '{0}: {1}' -f $_.Label, ($(if ($_.Left.Count) { $_.Left -join ', ' } else { 'not verified' })) }) -join '; '
        $message = '{0}sign-in data is left (fail closed): {1}.' -f $(if ($cleaned) { 'After the cleanup, ' } else { '' }), $detail
        return (New-DemoResult -CheckId $CheckId -Area $Area -Target $Target -Status 'Fail' -Message $message -Evidence $evidence -Remediation $Remediation -DocUrl $docUrl)
    }
    $names = ($parts | ForEach-Object { $_.Label }) -join ' and '
    $security = @($parts | Where-Object { $_.Security -gt 0 })
    if ($security.Count -gt 0) {
        $where = @($security | ForEach-Object { '{0}: {1}' -f $_.Label, $_.Security }) -join '; '
        $message = 'The Security log holds token-shaped value(s) ({0}). Nothing clears that log on its own, because clearing it erases the audit trail and endpoint protection may report it.' -f $where
        $command = './scripts/check-sign-in-data.ps1 -VmName {0} -Clean -ClearSecurityLog' -f $VmName
        return (New-DemoResult -CheckId $CheckId -Area $Area -Target $Target -Status 'Manual action required' -Message $message -Evidence $evidence -Remediation ('After you review it, clear it with: {0} (or, on the VM in an elevated prompt: wevtutil clear-log Security), then check again.' -f $command) -DocUrl 'https://learn.microsoft.com/windows-server/administration/windows-commands/wevtutil')
    }
    $cleared = @($parts | ForEach-Object { foreach ($log in @($_.Cleared)) { '{0} on {1}' -f $log, $_.Label } })
    if ($cleared.Count -gt 0) {
        $message = 'Sign-in data was removed from {0}, and none is left; the cleanup cleared {1}, which endpoint protection may report as a cleared event log.' -f $names, ($cleared -join ', ')
        return (New-DemoResult -CheckId $CheckId -Area $Area -Target $Target -Status 'Warning' -Message $message -Evidence $evidence -Remediation 'Nothing to do if your security team expects it; the logs held token-shaped values, which the cleanup must remove.' -DocUrl $docUrl)
    }
    $apps = @($parts | Where-Object { $_.AppTokens -gt 0 })
    if ($apps.Count -gt 0) {
        $message = 'No sign-in data from a person is left on {0}; {1} token(s) of an application or a managed identity were found{2}.' -f $names, (($apps | Measure-Object -Property AppTokens -Sum).Sum), $(if ($cleaned) { ' and removed' } else { '' })
        return (New-DemoResult -CheckId $CheckId -Area $Area -Target $Target -Status 'Warning' -Message $message -Evidence $evidence -Remediation 'An extension or agent logged its own token. Nothing from your sign-in is involved; run ./scripts/check-sign-in-data.ps1 -Clean to remove it.' -DocUrl $docUrl)
    }
    $message = if ($cleaned) { 'Sign-in data was removed from {0}, and none is left.' -f $names } else { 'No sign-in data is left on {0}.' -f $names }
    return (New-DemoResult -CheckId $CheckId -Area $Area -Target $Target -Status 'Pass' -Message $message -Evidence $evidence -DocUrl $docUrl)
}

function Invoke-DemoDiskWipeAction {
    <#
    .SYNOPSIS
    Runs vm/bootstrap/Invoke-DemoDiskWipe.ps1 on the T2 host in a managed Run Command (DbHubDemo-DiskWipe, no
    secret) and parses its last JSON line: GuestFill (the guest's free space zeroed and trimmed) or HostCompact
    (the guest's VHDX compacted, then the host's free space zeroed and trimmed). Returns Succeeded, Data, Error,
    and Seconds. Internal (ADR 0009, Phase 26d).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('GuestFill', 'HostCompact')]
        [string] $Action,

        [ValidateRange(10, 1000)]
        [int] $MinHostFreeGB = 45,

        [ValidateRange(600, 10800)]
        [int] $TimeoutSeconds = 7200
    )

    $script = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/Invoke-DemoDiskWipe.ps1') -Raw
    $values = [ordered]@{
        WipeAction    = $Action
        MinHostFreeGB = [string]$MinHostFreeGB
        MaxMinutes    = [string][int][System.Math]::Max(10, ($TimeoutSeconds / 60) - 10)
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $run = Invoke-DemoVmRunCommand -Config $Config -VmName 'archost01' -RunCommandName 'DbHubDemo-DiskWipe' -Script $script -Parameter $values -TimeoutSeconds $TimeoutSeconds -PollIntervalSeconds 30 -Confirm:$false
    }
    catch {
        return [pscustomobject]@{ Succeeded = $false; Data = $null; Error = (Protect-DemoText -Text $_.Exception.Message); Seconds = [int]$watch.Elapsed.TotalSeconds }
    }
    $data = $null
    if ($null -ne $run) {
        $data = ConvertFrom-DemoRunCommandOutput -Text ([string]$run.Output)
    }
    $succeeded = ($null -ne $run -and $run.Succeeded -and $null -ne $data -and [bool](Get-DemoMemberValue -InputObject $data -Name 'succeeded'))
    $errorText = ''
    if (-not $succeeded) {
        $errorText = [string](Get-DemoMemberValue -InputObject $data -Name 'error')
        if (-not $errorText -and $null -ne $run) {
            $errorText = if ($run.Error) { [string]$run.Error } else { 'execution state {0}, exit code {1}' -f $run.ExecutionState, $run.ExitCode }
        }
    }
    return [pscustomobject]@{ Succeeded = $succeeded; Data = $data; Error = (Protect-DemoText -Text $errorText); Seconds = [int]$watch.Elapsed.TotalSeconds }
}
