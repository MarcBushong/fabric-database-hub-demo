# deploy.ps1's start, expectations, and ending (Phase 28, brief goals 1, 7 and prompting items 1, 2, 3, 7, 8, 13, 15):
# the start banner with the expected timeline and the person's part, the notices for sessions that can't take keyboard
# input and for GitHub Codespaces, and the one ending: DONE (every target ready, where to look, and what didn't work but
# never blocks DONE, such as the Insights app, with its error and fix; 2026-11-05) or NOT DONE (why, the single next
# action as an exact command, and how to resume), with a nonzero exit code when it isn't done.
# Sources (checked 2026-10-29):
# - Codespaces idle timeout: https://docs.github.com/codespaces/setting-your-user-preferences/setting-your-timeout-period-for-github-codespaces
# - Codespaces maximum lifetime: https://docs.github.com/codespaces/about-codespaces/understanding-the-codespace-lifecycle

function Get-DemoDeployCommand {
    # The exact deploy.ps1 command for this configuration: './scripts/deploy.ps1', with -ConfigPath when the file isn't
    # config/demo.config.json. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $ConfigPath = ''
    )

    $default = [System.IO.Path]::GetFullPath((Join-Path -Path $script:RepoRoot -ChildPath 'config/demo.config.json'))
    # Relative to PowerShell's current location, not the process's working directory (review fix 8).
    $full = Resolve-DemoUserPath -Path $ConfigPath
    if ($full -and $full -ne $default) {
        $root = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd('\', '/')
        $shown = if ($full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { './' + ($full.Substring($root.Length + 1) -replace '\\', '/') } else { $full }
        return ('./scripts/deploy.ps1 -ConfigPath "{0}"' -f $shown)
    }
    return './scripts/deploy.ps1'
}

function Get-DemoStopDemoCommand {
    # The exact './scripts/stop-demo.ps1 -RemoveBastionOnly' for the configuration of a deploy.ps1 command
    # (Get-DemoDeployCommand), with its -ConfigPath. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Command = './scripts/deploy.ps1'
    )

    $stop = './scripts/stop-demo.ps1 -RemoveBastionOnly'
    if ($Command -match '^\./scripts/deploy\.ps1(?<rest>( .*)?)$') {
        return ('{0}{1}' -f $stop, $Matches['rest'])
    }
    return $stop
}

function Resolve-DemoDeployCommandText {
    <#
    .SYNOPSIS
    A remediation's text with each deploy.ps1 it tells you to run written as this run's own command (-Command, from
    Get-DemoDeployCommand, so it keeps -ConfigPath), every other ./scripts/*.ps1 it names given the same -ConfigPath, and
    the first such deploy.ps1 command with that text's parameters. Returns Text and Command; Command is empty when the text
    names no deploy.ps1 to run. Pure. Internal.

    .DESCRIPTION
    Live finding (2026-11-06): NOT DONE said "run ./scripts/deploy.ps1 -FromStage Artifacts" while its Run line gave the
    plain command, and both dropped the run's -ConfigPath, so a copied command would have deployed config/demo.config.json,
    and a copied destroy.ps1 would have removed that environment. A deploy.ps1 mention is a command when it's
    ./scripts/deploy.ps1, when "run" comes right before it, or when deploy.ps1's own parameters follow it (a stage name or a
    number for those that take one); "deploy.ps1's" and other mentions in passing stay as they are, and so does a script
    that already names -ConfigPath. Every script in scripts/ takes -ConfigPath. -Resume, which remediations from before
    Phase 28 name, is left out of the command: a plain run resumes by itself whenever the state allows it, and after a run
    whose recorded stage reached Validation (a rerun after DONE whose template then failed, for example) it starts over,
    template included, where -Resume would run only the validation (review finding, 2026-11-06).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [AllowEmptyString()]
        [string] $Command = './scripts/deploy.ps1'
    )

    if (-not $Command) {
        $Command = './scripts/deploy.ps1'
    }
    if (-not $Text) {
        return [pscustomobject]@{ Text = [string]$Text; Command = '' }
    }
    $stage = '(?:Preflight|Infrastructure|Artifacts|Bootstraps|T3|T4|Activity|Monitoring|T2|Fabric|Validation)'
    $parameter = '[ ]+(?:-(?:FromStage|StopAfter)[ ]+{0}\b|-(?:T1WaitMinutes|T2WaitMinutes|MonitoringWaitMinutes|TelemetryWaitMinutes|PolicyCacheHours)[ ]+\d+\b|-(?:Resume|SkipRunner|SkipFabric|ImportNotebooks|SkipPolicyInventory|Sequential|WaitForT2|NoWaitForT2|NoStatusPage|NoBrowser|WhatIf|TreatManualAsError)\b)' -f $stage
    $pattern = '(?<![\w./\\-])(?<path>(?:\./)?scripts/)?deploy\.ps1(?![\w''])(?<parameters>(?:{0})*)' -f $parameter
    $found = @{ Command = '' }
    $source = $Text
    $rewritten = [regex]::Replace($Text, $pattern, {
            param($Match)
            $before = $source.Substring(0, $Match.Index)
            $after = $source.Substring($Match.Index + $Match.Length)
            $parameters = $Match.Groups['parameters'].Value
            $isCommand = $Match.Groups['path'].Success -or $parameters -or $before -match '(?i)\brun\s+$'
            if (-not $isCommand -or $after -match '^[^.;:,()]*?\s-ConfigPath\b') {
                return $Match.Value
            }
            $named = '{0}{1}' -f $Command, ($parameters -replace '[ ]+-Resume\b', '')
            if (-not $found.Command) {
                $found.Command = $named
            }
            return $named
        })
    # The run's own -ConfigPath (what follows deploy.ps1 in -Command) for the other scripts the text names.
    $rest = if ($Command -match '^\./scripts/deploy\.ps1(?<rest>( .*)?)$') { [string]$Matches['rest'] } else { '' }
    if ($rest) {
        $other = $rewritten
        $rewritten = [regex]::Replace($other, '(?<![\w./\\-])\./scripts/(?!deploy\.ps1)[A-Za-z0-9-]+\.ps1(?![\w''])', {
                param($Match)
                if ($other.Substring($Match.Index + $Match.Length) -match '^[^.;:,()]*?\s-ConfigPath\b') {
                    return $Match.Value
                }
                return ('{0}{1}' -f $Match.Value, $rest)
            })
    }
    return [pscustomobject]@{ Text = $rewritten; Command = $found.Command }
}

function Get-DemoDeploymentExpectation {
    <#
    .SYNOPSIS
    What a deploy.ps1 run can expect: the whole first run and a redeploy from a golden snapshot; no T2 step needs a
    person in any mode (the guided stop is retired, 2026-11-09). In JumpstartImage mode, the default, the first run is
    the one measured live on 2026-11-06; the rest are estimates from documented step times, not a measured run. Pure.
    Internal.

    .DESCRIPTION
    A T2 guest build takes 60 to 90 minutes (an ADR 0018 estimate; Phase 16 measured about 35 minutes for a whole
    Developer guest build); before it, preflight takes 2 to 13 minutes (the policy inventory is 7 to 13 of them on a
    first run with networkMode auto), the template 7 to 9, and the artifacts and the loader about 5. Afterward, the
    sign-in cleanup, the database, Arc's PAYG and monitoring, and telemetry take about 30 to 45 minutes.
    JumpstartImage mode (the default since 2026-11-05) replaces the guest build with the Jumpstart image's 34 GiB download
    and its first boot, and needs no person: a clean first deployment took 91 minutes when measured on 2026-11-06, of
    which T2's host build took about 27 and its Arc onboarding about 33. Without
    -SkipFabric, it says that the Insights app deploys with the Azure CLI's sign-in (2026-11-09), and that the Rayfin
    CLI's own sign-in opens a browser at the start only after Fabric refused that token, which the run doesn't wait for
    (2026-11-05). -Note (2026-11-09) adds the lines that say what the run ignores in the configuration (its
    PaygWizard, its t4Enabled false), to the banner and the status page.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('JumpstartImage', 'PaygWizard', 'ProductKey', 'Developer')]
        [string] $InstallMode = 'JumpstartImage',

        [switch] $SkipFabric,

        [AllowEmptyCollection()]
        [string[]] $Note = @()
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($InstallMode -eq 'JumpstartImage') {
        $lines.Add('What to expect (the first deployment as measured on 2026-11-06; the rest are estimates from documented step times):')
    }
    else {
        $lines.Add('What to expect (estimates from documented step times, not a measured run):')
    }
    $notes = @($Note | Where-Object { $_ })
    foreach ($item in $notes) {
        # 2026-11-09: what the run ignores in the configuration (Get-DemoT2LegacyModeText, Get-DemoT4IgnoredText).
        $lines.Add(('- {0}' -f $item))
    }
    if ($InstallMode -eq 'JumpstartImage') {
        $lines.Add('- A first deployment takes about 1.5 hours in all: 91 minutes when measured on 2026-11-06, of which T2''s host build, with the Jumpstart image''s download and first boot, took about 27 and its Arc onboarding about 33. No T2 step needs a person.')
    }
    else {
        $lines.Add('- A first deployment takes about 1.5 to 2.5 hours in all; the T2 guest build alone is 60 to 90 minutes. No T2 step needs a person.')
    }
    $lines.Add('- A redeploy from a golden snapshot (./scripts/capture-t2-golden.ps1) takes about 30 to 45 minutes, with no T2 build.')
    if (-not $SkipFabric) {
        $lines.Add('- The Insights app deploys with your Azure CLI sign-in (az login), so no browser opens for it. Only after Fabric refused that token in an earlier run does a browser open for the Rayfin CLI''s own sign-in right at the start; the run goes on meanwhile, only the app waits for it, and without it the app isn''t created, which doesn''t keep the run from DONE.')
    }
    $lines.Add('- This PC stays awake while deploy.ps1 runs (Windows); keep it plugged in, and don''t close this window.')
    $lines.Add('- If this window closes or the PC restarts, run ./scripts/deploy.ps1 again; it continues where it stopped.')
    $text = if ($InstallMode -eq 'JumpstartImage') { 'A first deployment takes about 1.5 hours (91 minutes, measured on 2026-11-06); a redeploy from a golden snapshot about 30 to 45 minutes (estimate).' } else { 'A first deployment takes about 1.5 to 2.5 hours (estimate); a redeploy from a golden snapshot about 30 to 45 minutes.' }
    if ($notes.Count -gt 0) {
        $text = '{0} {1}' -f $text, ($notes -join ' ')
    }
    return [pscustomobject]@{
        Lines = $lines.ToArray()
        Text  = $text
    }
}

function Get-DemoDeploymentNotice {
    <#
    .SYNOPSIS
    The start banner's notices (brief items 7, 8, 13): in a session that can't take keyboard input (an assistant, a
    script, or CI), that the Insights app's browser sign-in, needed only when Fabric refuses the Azure CLI's token
    (2026-11-09), isn't started there (2026-11-05); and a GitHub Codespaces idle timeout. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Environment,

        [switch] $SkipFabric
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $SkipFabric -and -not [bool]$Environment.Interactive) {
        $lines.Add('The Insights app deploys with your Azure CLI sign-in (az login). Only if Fabric refuses that token does it need the Rayfin CLI''s browser sign-in, which isn''t started in a session like this one: the run still finishes, and ./scripts/configure-fabric-app.ps1 -SignIn, which you run yourself in a terminal, adds the app later.')
    }
    if ([bool]$Environment.Codespaces) {
        $lines.Add('GitHub Codespaces stops a codespace after 30 minutes without activity by default, and always after 12 hours. Terminal output counts as activity, and deploy.ps1 prints progress at least every 5 minutes, but raise the idle timeout to be safe: GitHub Settings > Codespaces > Default idle timeout (up to 240 minutes; it applies to codespaces you create afterward), or gh codespace create --idle-timeout 240m. An organization policy can lower it.')
    }
    return $lines.ToArray()
}

function Get-DemoNonBlockingItem {
    <#
    .SYNOPSIS
    What didn't work but never blocks DONE (2026-11-05), each with the actual reason and how to fix it: the Insights app
    when it wasn't created or doesn't work (Get-DemoInsightsAppSummary: State Failed; it's part of every deployment),
    the history report's data check while the Execute Queries setting is off (FABRIC.SEMANTICMODEL.* Manual action
    required), and deploy.ps1's history snapshot at the end of the run when it didn't work (Get-DemoHistorySnapshotItem,
    2026-11-06). Each item has name, state (Failed or Action needed, as on the status page), message, and howTo;
    Format-DemoNonBlockingLine words it the same everywhere. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $open = @($Result | Where-Object { $null -ne $_ -and [string]$_.status -in 'Fail', 'Manual action required' })
    $app = Get-DemoInsightsAppSummary -Result $Result
    # A deployed app that only waits for its browser check is under "Please confirm" instead (Get-DemoConfirmItem).
    if ($null -ne $app -and [bool](Get-DemoMemberValue -InputObject $app -Name 'Failed')) {
        $items.Add([ordered]@{
                name    = 'the Insights app'
                state   = 'Failed'
                message = $app.Reason
                howTo   = $app.HowTo
            })
    }
    $model = @($open | Where-Object { [string]$_.checkId -like 'FABRIC.SEMANTICMODEL.*' -and [string]$_.status -eq 'Manual action required' })
    if ($model.Count -gt 0) {
        $items.Add([ordered]@{
                name    = 'the history report''s data check'
                state   = 'Action needed'
                message = 'The report is deployed; its DAX data check needs a tenant setting.'
                howTo   = 'A Fabric administrator turns on Dataset Execute Queries REST API; then run ./scripts/configure-powerbi.ps1 -CheckModelData.'
            })
    }
    # deploy.ps1's history snapshot at the end of the run, when it didn't work (2026-11-06).
    $history = Get-DemoHistorySnapshotItem -Result $Result
    if ($null -ne $history) {
        $items.Add($history)
    }
    return $items.ToArray()
}

function Format-DemoNonBlockingLine {
    # One line for an item that didn't work but never blocks DONE (Get-DemoNonBlockingItem), the same on the console, in
    # DONE and NOT DONE, in DEPLOY.SUMMARY's evidence, and on the status page (2026-11-05): "Failed (doesn't block DONE):
    # the Insights app. <its actual reason> <how to fix it>". '' for nothing. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Item
    )

    if ($null -eq $Item) {
        return ''
    }
    $state = [string](Get-DemoMemberValue -InputObject $Item -Name 'state')
    if ($state -notin 'Failed', 'Action needed') {
        $state = 'Failed'
    }
    $name = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $Item -Name 'name')
    $message = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $Item -Name 'message')
    $howTo = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $Item -Name 'howTo')
    if (-not $name -and -not $message) {
        return ''
    }
    return (('{0} (doesn''t block DONE): {1}. {2} {3}' -f $state, $name.TrimEnd('.'), $message, $howTo) -replace '\s+', ' ').Trim()
}

function Test-DemoInsightsAppRecord {
    # True for a record of the Insights app's step: its own checks (FABRIC.APP.*, DEPLOY.FABRIC.APP), or one its step
    # reported and marked non-blocking (ConvertTo-DemoInsightsAppRecord). Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Result
    )

    if ($null -eq $Result) {
        return $false
    }
    $id = [string]$Result.checkId
    if ($id -like 'FABRIC.APP.*' -or $id -eq 'DEPLOY.FABRIC.APP') {
        return $true
    }
    return ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Result -Name 'evidence') -Name 'nonBlocking') -eq 'insightsApp')
}

function Get-DemoInsightsAppSummary {
    <#
    .SYNOPSIS
    The Insights app's outcome from its step's records (2026-11-05): State for the status page (Done, Failed, or
    Skipped), Status (the worst status its open records reported, so an error reads Fail), Reason (the first record that
    kept it from working, with its check ID), HowTo (that record's own fix, then the tenant settings while they're open,
    then the sign-in that adds it), StepMessage (both, in one line), Deployed, ConfirmOnly, and Failed. $null without any
    of its records. Pure. Internal.

    .DESCRIPTION
    The app is part of every deployment, and it never blocks DONE (Test-DemoNonBlockingResult), so this is what shows
    when it didn't work, never "Skipped" or "Optional" (Phase 28 showed it Skipped):
    - Not created, or deployed with a check that failed: Failed, with the actual error.
    - Deployed, with only its browser check open (FABRIC.APP.BROWSER): Done; DONE lists that check under "Please
      confirm" (Phase 28 live finding).
    - Deployed and checked: Done.
    - Only DEPLOY.FABRIC.APP Not selected (this checkout has no configure-fabric-app.ps1): Skipped.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $records = @($Result | Where-Object { Test-DemoInsightsAppRecord -Result $_ })
    if ($records.Count -eq 0) {
        return $null
    }
    $signIn = 'run ./scripts/configure-fabric-app.ps1 -SignIn, which deploys the app with your Azure CLI sign-in and opens a browser for the Rayfin CLI''s own sign-in only if Fabric refuses that (an assistant can''t do that sign-in for you)'
    $deployed = @($records | Where-Object { [string]$_.checkId -eq 'FABRIC.APP.DEPLOY' -and [string]$_.status -eq 'Pass' }).Count -gt 0
    $open = @($records | Where-Object { [string]$_.status -in 'Fail', 'Manual action required' })
    $blocking = @($open | Where-Object { [string]$_.checkId -ne 'FABRIC.APP.BROWSER' })
    if ($blocking.Count -gt 0) {
        $first = $blocking[0]
        $lead = if ($deployed) { 'It''s deployed, but' } else { 'It wasn''t created:' }
        $reason = '{0} {1}: {2}' -f $lead, [string]$first.checkId, ((ConvertTo-DemoPlainText -Value $first.message) -replace '^Insights app: ', '')
        $fix = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $first -Name 'remediation')
        # Its own fix first (unless it's the sign-in or a tenant setting), then the tenant settings while they're open, then
        # the sign-in that deploys the app.
        $steps = [System.Collections.Generic.List[string]]::new()
        if ([string]$first.checkId -notin 'FABRIC.APP.TENANTSETTING', 'FABRIC.APP.EXECUTEQUERIES', 'FABRIC.APP.SIGNIN' -and $fix -and $fix -notmatch 'configure-fabric-app\.ps1') {
            $steps.Add($fix.TrimEnd('.'))
        }
        if (@($open | Where-Object { [string]$_.checkId -in 'FABRIC.APP.TENANTSETTING', 'FABRIC.APP.EXECUTEQUERIES' }).Count -gt 0) {
            $steps.Add('a Fabric administrator turns on the tenant settings Fabric Apps (preview) and Dataset Execute Queries REST API, if they aren''t on')
        }
        $steps.Add($signIn)
        $howTo = '{0}: {1}.' -f $(if ($deployed) { 'To fix it' } else { 'To add it' }), ($steps -join '; then ')
        # An error the script reported (evidence reportedStatus Fail) reads Fail here, though its record is non-blocking.
        $statuses = @(foreach ($item in $blocking) {
                if ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'evidence') -Name 'reportedStatus') -eq 'Fail') { 'Fail' } else { [string]$item.status }
            })
        return [pscustomobject]@{ State = 'Failed'; Status = (Get-DemoWorstStatus -Status $statuses); Reason = $reason; HowTo = $howTo; StepMessage = ('{0} {1}' -f $reason, $howTo); Deployed = $deployed; ConfirmOnly = $false; Failed = $true }
    }
    if ($open.Count -gt 0) {
        # Deployed and checked; a person confirms it once in the browser, which a rerun can't do: listed under "Please
        # confirm", never as something that didn't work (Phase 28 live finding, 2026-10-30).
        $reason = 'It''s deployed: {0}' -f (ConvertTo-DemoPlainText -Value $open[0].message)
        $howTo = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $open[0] -Name 'remediation')
        return [pscustomobject]@{ State = 'Done'; Status = 'Manual action required'; Reason = $reason; HowTo = $howTo; StepMessage = ('{0} {1}' -f $reason, $howTo).TrimEnd(); Deployed = $true; ConfirmOnly = $true; Failed = $false }
    }
    if ($deployed) {
        # A Not selected record beside a deploy that passed (the workspace passed in, for example) changes nothing.
        $statuses = @($records | ForEach-Object { [string]$_.status } | Where-Object { $_ -ne 'Not selected' })
        $worst = if ($statuses.Count -gt 0) { Get-DemoWorstStatus -Status $statuses } else { 'Pass' }
        $warning = @($records | Where-Object { [string]$_.status -eq 'Warning' } | Select-Object -First 1)
        $text = if ($warning.Count -gt 0) { 'Deployed and checked; {0}: {1}' -f [string]$warning[0].checkId, (ConvertTo-DemoPlainText -Value $warning[0].message) } else { 'Deployed and checked: open it from its item in the Fabric workspace.' }
        return [pscustomobject]@{ State = 'Done'; Status = $worst; Reason = 'It''s deployed and checked.'; HowTo = ''; StepMessage = $text; Deployed = $true; ConfirmOnly = $false; Failed = $false }
    }
    # Not created, with nothing open: skipped on purpose only when this checkout has no configure-fabric-app.ps1;
    # otherwise it didn't work, and its records don't say why.
    $onPurpose = @($records | Where-Object { [string]$_.checkId -eq 'DEPLOY.FABRIC.APP' -and [string]$_.status -eq 'Not selected' }) | Select-Object -First 1
    $howTo = 'To add it, {0}.' -f $signIn
    if ($null -ne $onPurpose) {
        $reason = 'It wasn''t created: {0}' -f (ConvertTo-DemoPlainText -Value $onPurpose.message)
        return [pscustomobject]@{ State = 'Skipped'; Status = 'Not selected'; Reason = $reason; HowTo = $howTo; StepMessage = ('{0} {1}' -f $reason, $howTo); Deployed = $false; ConfirmOnly = $false; Failed = $false }
    }
    $reason = 'It wasn''t created, and its step didn''t say why.'
    return [pscustomobject]@{ State = 'Failed'; Status = 'Manual action required'; Reason = $reason; HowTo = $howTo; StepMessage = ('{0} {1}' -f $reason, $howTo); Deployed = $false; ConfirmOnly = $false; Failed = $true }
}

function Test-DemoNonBlockingResult {
    # True for a result that never blocks DONE (2026-11-05): the Insights app's (Test-DemoInsightsAppRecord; it's part of
    # every deployment, but DONE never waits for it), the history report's data check waiting for the Execute Queries
    # setting, or deploy.ps1's history snapshot (DEPLOY.FABRIC.HISTORY, 2026-11-06; never a Fail or Manual action required
    # anyway). Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Result
    )

    if ($null -eq $Result) {
        return $false
    }
    $id = [string]$Result.checkId
    return ((Test-DemoInsightsAppRecord -Result $Result) -or ($id -like 'FABRIC.SEMANTICMODEL.*' -and [string]$Result.status -eq 'Manual action required') -or $id -eq 'DEPLOY.FABRIC.HISTORY')
}

function Test-DemoTenantSettingRead {
    <#
    .SYNOPSIS
    How a P4 result (PREFLIGHT.P4.HUBSETTING or FABRIC.P4.HUBSETTING) read the Hub tenant setting, from its evidence
    (Test-DemoFabricHubSetting): Disabled when the Fabric admin API answered and the setting is off, Read when it
    answered with the setting on, or Unread for everything else: no token, HTTP 401 or 403, not found, an older result
    without evidence (Phase 28 live finding, 2026-10-30). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Result
    )

    $evidence = Get-DemoMemberValue -InputObject $Result -Name 'evidence'
    $checked = [string](Get-DemoMemberValue -InputObject $evidence -Name 'checkedThroughApi') -eq 'True'
    $settingRead = Get-DemoMemberValue -InputObject $evidence -Name 'settingRead'
    $enabled = Get-DemoMemberValue -InputObject $evidence -Name 'enabled'
    if (-not $checked -or ($null -ne $settingRead -and [string]$settingRead -ne 'True') -or $null -eq $enabled -or [string]$enabled -notin 'True', 'False') {
        return 'Unread'
    }
    if ([string]$enabled -eq 'False') {
        return 'Disabled'
    }
    return 'Read'
}

function Get-DemoHubSettingLatestRead {
    # The latest P4 result (PREFLIGHT.P4.HUBSETTING or FABRIC.P4.HUBSETTING) that read the Hub tenant setting through the
    # Fabric admin API (Test-DemoTenantSettingRead Read or Disabled), or $null when none did. A later read supersedes an
    # earlier one, so a setting an administrator turned on during the run counts as on (Phase 28 review). Pure. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    return (@($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -in 'PREFLIGHT.P4.HUBSETTING', 'FABRIC.P4.HUBSETTING' -and (Test-DemoTenantSettingRead -Result $_) -ne 'Unread' }) | Select-Object -Last 1)
}

function Test-DemoConfirmOnlyResult {
    <#
    .SYNOPSIS
    True for a Manual action required result that only a person can confirm, which a rerun can't resolve, so it never
    keeps deploy.ps1 from DONE (Phase 28 live finding, 2026-10-30: three such reminders made a run whose every DONE
    requirement passed end NOT DONE, with a rerun as the next step). Get-DemoConfirmItem lists them under "Please
    confirm". Internal.

    .DESCRIPTION
    - The Database Hub tenant setting (P4: PREFLIGHT.P4.HUBSETTING, FABRIC.P4.HUBSETTING) that wasn't read (no token, not
      a Fabric administrator, not found): decided from its evidence (Test-DemoTenantSettingRead), so a setting the Fabric
      admin API read as disabled still blocks DONE, whichever check ID read it. With -Context (the run's results), the
      latest read decides (Get-DemoHubSettingLatestRead): only that read blocks, and only when it says disabled, so the
      Fabric track's read supersedes preflight's (Phase 28 review).
    - FABRIC.P5.CAPACITY on an Active capacity whose SKU the check doesn't recognize (a Trial: its SKU name isn't
      documented).
    - HUB.PRESENTER.*: with assignRoles false (the default, ADR 0008), an administrator grants the presenters' roles.
    - FABRIC.APP.BROWSER: the Insights app, deployed and confirmed once in the browser.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Result,

        [AllowEmptyCollection()]
        [object[]] $Context = @()
    )

    if ($null -eq $Result -or [string](Get-DemoMemberValue -InputObject $Result -Name 'status') -ne 'Manual action required') {
        return $false
    }
    $id = [string]$Result.checkId
    if ($id -in 'PREFLIGHT.P4.HUBSETTING', 'FABRIC.P4.HUBSETTING') {
        if (@($Context).Count -eq 0) {
            return ((Test-DemoTenantSettingRead -Result $Result) -ne 'Disabled')
        }
        $latest = Get-DemoHubSettingLatestRead -Result $Context
        return -not ($null -ne $latest -and [object]::ReferenceEquals($latest, $Result) -and (Test-DemoTenantSettingRead -Result $Result) -eq 'Disabled')
    }
    if ($id -eq 'FABRIC.P5.CAPACITY') {
        $evidence = Get-DemoMemberValue -InputObject $Result -Name 'evidence'
        return ([string](Get-DemoMemberValue -InputObject $evidence -Name 'state') -eq 'Active' -and [bool][string](Get-DemoMemberValue -InputObject $evidence -Name 'sku'))
    }
    return ($id -like 'HUB.PRESENTER.*' -or $id -eq 'FABRIC.APP.BROWSER')
}

function Get-DemoConfirmItem {
    <#
    .SYNOPSIS
    What deploy.ps1's ending lists under "Please confirm" (Phase 28 live finding, 2026-10-30): one line per item a
    person confirms (Test-DemoConfirmOnlyResult), each once. The Hub tenant setting is one line whichever check reported
    it, and none once a check read it: none when it's on for the organization, the Warning's groups when it's on only
    for groups, and none when it's off, which blocks DONE instead. Returns Key, CheckId, and Text for each. Pure.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $add = {
        param([string] $Key, [string] $CheckId, [string] $Text)
        if ($Text -and $seen.Add($Key)) {
            $items.Add([ordered]@{ key = $Key; checkId = $CheckId; text = (ConvertTo-DemoPlainText -Value $Text) })
        }
    }
    # P4: the latest read decides (on for the organization: nothing; on only for groups: its Warning; off: it blocks DONE
    # instead, Phase 28 review); without a read, the latest reminder, which says it couldn't be checked and why.
    $hub = @($all | Where-Object { [string]$_.checkId -in 'PREFLIGHT.P4.HUBSETTING', 'FABRIC.P4.HUBSETTING' })
    $latestRead = Get-DemoHubSettingLatestRead -Result $all
    if ($null -ne $latestRead) {
        if ([string]$latestRead.status -eq 'Warning') {
            & $add 'P4' ([string]$latestRead.checkId) ([string]$latestRead.message)
        }
    }
    else {
        $unread = @($hub | Where-Object { Test-DemoConfirmOnlyResult -Result $_ } | Select-Object -Last 1)
        if ($unread.Count -gt 0) {
            & $add 'P4' ([string]$unread[0].checkId) ([string]$unread[0].message)
        }
    }
    foreach ($item in @($all | Where-Object { [string]$_.checkId -notin 'PREFLIGHT.P4.HUBSETTING', 'FABRIC.P4.HUBSETTING', 'FABRIC.APP.BROWSER' -and (Test-DemoConfirmOnlyResult -Result $_) })) {
        $id = [string]$item.checkId
        $text = if ($id -eq 'FABRIC.P5.CAPACITY') { [string](Get-DemoMemberValue -InputObject $item -Name 'remediation') } else { '{0} The commands are in its result ({1}).' -f ([string]$item.message).TrimEnd(), $id }
        & $add $id $id $text
    }
    $app = Get-DemoInsightsAppSummary -Result $all
    if ($null -ne $app -and [bool](Get-DemoMemberValue -InputObject $app -Name 'ConfirmOnly')) {
        & $add 'FABRIC.APP.BROWSER' 'FABRIC.APP.BROWSER' ('The Insights app is deployed; confirm it once in the browser. {0}' -f [string]$app.HowTo)
    }
    return $items.ToArray()
}

function ConvertTo-DemoPlainText {
    # One line of text from any value: an array's items joined with spaces, never "System.String[]" (Phase 28 live
    # finding, 2026-10-30), and whitespace collapsed. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return ''
    }
    $parts = if ($Value -is [string]) { @($Value) } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) { @($Value | ForEach-Object { ConvertTo-DemoPlainText -Value $_ }) } else { @([string]$Value) }
    return ((@($parts | Where-Object { $_ }) -join ' ') -replace '\s+', ' ').Trim()
}

function Get-DemoPreflightPassText {
    # The Preflight step's Pass message in plain words (Phase 28 live run, 2026-10-30: it said "T3 free offer False" and
    # "T2 source existing-build"). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $NetworkMode = '',

        [bool] $T3UseFreeLimit,

        [AllowEmptyString()]
        [string] $T2Source = ''
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add(('network mode: {0}' -f $(if ($NetworkMode) { $NetworkMode } else { 'not decided yet' })))
    $parts.Add(('T3 free offer: {0}' -f $(if ($T3UseFreeLimit) { 'used' } else { 'not used' })))
    if ($T2Source) {
        $source = switch ($T2Source) {
            'golden' { 'a copy of the golden snapshot' }
            'existing-golden' { 'the existing host, from the golden snapshot' }
            'existing-build' { 'the existing host, built from the image' }
            'build' { 'a new build from the image' }
            default { $T2Source }
        }
        $parts.Add(('T2 source: {0}' -f $source))
    }
    return ('Preflight passed ({0}).' -f ($parts -join '; '))
}

function Get-DemoDeploySummary {
    <#
    .SYNOPSIS
    DEPLOY.SUMMARY's status, message, and evidence for both deployment paths (Phase 28 live finding, 2026-10-30): Fail
    with the failed checks; Manual action required with the items a person or a rerun acts on, each with its fix; the
    confirm-only items (Get-DemoConfirmItem), each once, saying that none of them keeps the run from DONE; and, in every
    case, what didn't work but never blocks DONE (Get-DemoNonBlockingItem: the Insights app, 2026-11-05). Every text is
    one plain line (ConvertTo-DemoPlainText). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [string] $FinishedText = 'Every stage that ran finished.'
    )

    $all = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -ne 'DEPLOY.SUMMARY' })
    $failed = @($all | Where-Object { [string]$_.status -eq 'Fail' })
    $manual = @($all | Where-Object { [string]$_.status -eq 'Manual action required' })
    $actionable = @($manual | Where-Object { -not (Test-DemoConfirmOnlyResult -Result $_ -Context $all) -and -not (Test-DemoNonBlockingResult -Result $_) })
    $steps = @($actionable | ForEach-Object {
            $fix = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $_ -Name 'remediation')
            '{0}: {1}' -f [string]$_.checkId, $(if ($fix) { $fix } else { ConvertTo-DemoPlainText -Value $_.message })
        })
    $confirm = @(Get-DemoConfirmItem -Result $all | ForEach-Object { [string]$_['text'] })
    $confirmText = if ($confirm.Count -gt 0) { ' Please confirm (none of these keeps the run from DONE): {0}' -f ($confirm -join ' | ') } else { '' }
    $nonBlockingItems = @(Get-DemoNonBlockingItem -Result $all)
    $nonBlocking = @($nonBlockingItems | ForEach-Object { '{0} ({1})' -f [string]$_['name'], ([string]$_['state']).ToLowerInvariant() })
    $nonBlockingText = if ($nonBlocking.Count -gt 0) { ' Doesn''t block DONE: {0}.' -f ($nonBlocking -join ', ') } else { '' }
    $status = if ($failed.Count -gt 0) { 'Fail' } elseif ($manual.Count -gt 0) { 'Manual action required' } else { 'Pass' }
    $message = if ($failed.Count -gt 0) {
        '{0} check(s) failed.{1}{2}' -f $failed.Count, $(if ($steps.Count -gt 0) { ' Also {0} item(s) need you: {1}' -f $steps.Count, ($steps -join ' | ') } else { '' }), $nonBlockingText
    }
    elseif ($steps.Count -gt 0) {
        '{0} item(s) need you: {1}{2}{3}' -f $steps.Count, ($steps -join ' | '), $confirmText, $nonBlockingText
    }
    elseif ($manual.Count -gt 0) {
        '{0} Nothing else needs you for DONE.{1}{2}' -f $FinishedText, $confirmText, $nonBlockingText
    }
    else {
        $FinishedText
    }
    return [pscustomobject]@{ Status = $status; Message = $message.Trim(); Evidence = ([ordered]@{ manual = $steps; confirm = $confirm; failed = @($failed | ForEach-Object { [string]$_.checkId }); nonBlocking = @($nonBlockingItems | ForEach-Object { Format-DemoNonBlockingLine -Item $_ }) }) }
}

function Get-DemoStartedVm {
    # What this run started or created, which runs and bills until a stop (Phase 28): the progress model's record
    # (Add-DemoProgressStartedVm; the only one after Ctrl+C) and this run's DEPLOY.VMSTART evidence, each once. Pure.
    # Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [object] $Model
    )

    $names = [System.Collections.Generic.List[string]]::new()
    $add = {
        param($Value)
        foreach ($item in @($Value)) {
            if ($item -and -not $names.Contains([string]$item)) {
                $names.Add([string]$item)
            }
        }
    }
    if ($null -ne $Model) {
        $run = Get-DemoMemberValue -InputObject $Model -Name 'run'
        $recorded = Get-DemoMemberValue -InputObject $run -Name 'startedVms'
        & $add $recorded
    }
    # What this run itself started (evidence started; never a VM that was already starting), less a VM whose start failed
    # (notRunning names it).
    $down = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'DEPLOY.VMSTART' })) {
        $evidence = Get-DemoMemberValue -InputObject $item -Name 'evidence'
        $started = Get-DemoMemberValue -InputObject $evidence -Name 'started'
        $notRunning = Get-DemoMemberValue -InputObject $evidence -Name 'notRunning'
        & $add $started
        foreach ($name in @($notRunning)) {
            if ($name) {
                $down.Add([string]$name)
            }
        }
        if ([string](Get-DemoMemberValue -InputObject $evidence -Name 't4') -eq 'Pass') {
            & $add 'T4'
        }
    }
    return @($names | Where-Object { $_ -notin $down })
}

function Get-DemoBillingNote {
    # The one line a NOT DONE or stopped run's banner adds when this run started or created VMs (Phase 28): what runs and
    # bills now, and how it stops: stop-demo.ps1 now, or the nightly auto-shutdown at its configured time. '' when
    # nothing was started. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [System.Collections.IDictionary] $Config = @{},

        [AllowEmptyCollection()]
        [string[]] $Name = @(),

        [string] $Command = './scripts/deploy.ps1'
    )

    $names = @($Name | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) {
        return ''
    }
    $join = { param([string[]] $Items) if ($Items.Count -le 2) { $Items -join ' and ' } else { '{0}, and {1}' -f ($Items[0..($Items.Count - 2)] -join ', '), $Items[-1] } }
    $them = if ($names.Count -eq 1) { 'it' } else { 'them' }
    $stop = (Get-DemoStopDemoCommand -Command $Command) -replace ' -RemoveBastionOnly', ''
    $vms = @($names | Where-Object { $_ -ne 'T4' })
    $shutdown = ''
    if ($vms.Count -gt 0 -and [string]$Config['autoShutdownTime'] -match '^([01]\d|2[0-3])([0-5]\d)$') {
        $clock = '{0}:{1}' -f $Matches[1], $Matches[2]
        $zone = if ([string]$Config['autoShutdownTimeZone']) { ' ({0})' -f [string]$Config['autoShutdownTimeZone'] } else { '' }
        $shutdown = '; otherwise the nightly auto-shutdown stops {0} at {1}{2}' -f $(if ($vms.Count -eq $names.Count) { $them } else { & $join $vms }), $clock, $zone
    }
    return ('Running and billing, because this run started or created {0}: {1}. {2} stops {0} now{3}.' -f $them, (& $join $names), $stop, $shutdown)
}

function Get-DemoT4OffReason {
    <#
    Why T4 isn't deployed, or '' when it is (brief item 16). Since 2026-11-09 (user-directed: "making sure postgres is
    deployed with the deployment and not being an optional component") T4 is part of every deployment, and DONE needs it:
    the configuration can't turn it off (Get-DemoConfig ignores t4Enabled false), no cost check or recorded fallback
    leaves it out (Resolve-DemoEffectiveConfig), and a run leaves it out only when Azure refused every size its fallback
    tries (DEPLOY.T4.SKU, a Fail with the fix, from -Result). Decided from the effective configuration, as the deployment
    decides. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [System.Collections.IDictionary] $Config = @{},

        [AllowNull()]
        [object] $State,

        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $refused = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'DEPLOY.T4.SKU' -and [string]$_.status -eq 'Fail' }) | Select-Object -Last 1
    if ($null -ne $refused) {
        return ('T4 (Azure Database for PostgreSQL) isn''t deployed, and DONE needs it: {0} {1}' -f $refused.message, $refused.remediation).Trim()
    }
    if (Test-DemoT4Enabled -Config (Resolve-DemoEffectiveConfig -Config $Config -State $State)) {
        return ''
    }
    return 'T4 (Azure Database for PostgreSQL) isn''t deployed in this run, and DONE needs it. Run ./scripts/deploy.ps1 again: it deploys the template, which creates T4, after preflight checks its cost.'
}

function New-DemoT4OffResult {
    <#
    .SYNOPSIS
    DEPLOY.T4.OFF (2026-11-09): T4 is never out of a deployment silently. A Fail, because DONE needs T4, with the exact
    reason and fix (Get-DemoT4OffReason: Azure refused every size, with a Region access request or t4SkuName as the fix).
    $null when T4 is deployed. Pure. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [System.Collections.IDictionary] $Config = @{},

        [AllowNull()]
        [object] $State,

        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $reason = Get-DemoT4OffReason -Config $Config -State $State -Result $Result
    if (-not $reason) {
        return $null
    }
    return (New-DemoResult -CheckId 'DEPLOY.T4.OFF' -Area 't4' -Target 'T4' -Status 'Fail' -Message $reason -Evidence ([ordered]@{ recorded = [string](Get-DemoMemberValue -InputObject $State -Name 'T4Sku') }) -Remediation 'Ask for access with a Region access request for Azure Database for PostgreSQL flexible server (Learn: Resolve capacity errors), or set t4SkuName to a size Azure offers you in the region, then run ./scripts/deploy.ps1, which tries again.' -DocUrl 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors')
}
function Get-DemoDoneRequirement {
    <#
    .SYNOPSIS
    The checks DONE needs to pass (brief item 16; the same list stops ADR 0018's clock): Database Hub's own views of
    every target. HUB.ESTATE.T1 to T4; TELEMETRY.T1, T2, and T3; METRICS.T4; T4's read replica in Estate and in Azure
    Monitor (HUB.ESTATE.T4.REPLICA and METRICS.T4.REPLICA, 2026-11-13, ADR 0025; Not supported meets them on a Burstable
    T4); T2.ARC.SQLINSTANCE (Standard with PAYG or
    Paid) and T2.ARC.MONITORING in JumpstartImage, PaygWizard, and ProductKey modes; T1.SQLVM.ASSOCIATEDSERVICES (T1's
    inventory); and FABRIC.ITEMS.REQUIRED (the workspace, the lakehouse, the notebooks, the Real-Time Dashboard, and the
    history model and report). T4's are always in (2026-11-09, user-directed: T4 isn't optional); Developer mode (opt-in)
    leaves out T2's performance telemetry and its PAYG and monitoring. The Insights app is part of every deployment, but DONE never needs it
    (2026-11-05): when it didn't work, DONE says so (Get-DemoNonBlockingItem). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [ValidateSet('JumpstartImage', 'PaygWizard', 'ProductKey', 'Developer')]
        [string] $InstallMode = 'JumpstartImage',

        [switch] $SkipFabric
    )

    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($target in 'T1', 'T2', 'T3', 'T4') {
        $ids.Add(('HUB.ESTATE.{0}' -f $target))
    }
    $ids.Add('TELEMETRY.T1')
    if ($InstallMode -ne 'Developer') {
        $ids.Add('TELEMETRY.T2')
    }
    $ids.Add('TELEMETRY.T3')
    $ids.Add('METRICS.T4')
    $ids.Add('HUB.ESTATE.T4.REPLICA')
    $ids.Add('METRICS.T4.REPLICA')
    if ($InstallMode -ne 'Developer') {
        $ids.Add('T2.ARC.SQLINSTANCE')
        $ids.Add('T2.ARC.MONITORING')
    }
    $ids.Add('T1.SQLVM.ASSOCIATEDSERVICES')
    if (-not $SkipFabric) {
        $ids.Add('FABRIC.ITEMS.REQUIRED')
    }
    return $ids.ToArray()
}

function Test-DemoDoneEvidence {
    # Which of -Requirement have a Pass among -Result: Complete, Missing (the ones without), and Problem (the first
    # missing one's latest result, or $null when it wasn't checked). T4's read replica's requirements (ADR 0025) are met
    # by Not supported too: a Burstable T4, which Azure supports no read replica on, says so with its fix and isn't kept
    # from DONE. Pure. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowEmptyCollection()]
        [string[]] $Requirement = @()
    )

    $missing = [System.Collections.Generic.List[string]]::new()
    $problem = $null
    foreach ($id in $Requirement) {
        $items = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq $id })
        $met = if ($id -in 'HUB.ESTATE.T4.REPLICA', 'METRICS.T4.REPLICA') { @('Pass', 'Not supported') } else { @('Pass') }
        if (@($items | Where-Object { [string]$_.status -in $met }).Count -gt 0) {
            continue
        }
        $missing.Add($id)
        if ($null -eq $problem -and $items.Count -gt 0) {
            $problem = $items[-1]
        }
    }
    return [pscustomobject]@{ Complete = ($missing.Count -eq 0); Missing = $missing.ToArray(); Problem = $problem }
}

function Test-DemoFabricRequiredItem {
    <#
    .SYNOPSIS
    FABRIC.ITEMS.REQUIRED (brief item 16): the required Fabric items exist by name, read-only: the workspace and the
    lakehouse (Resolve-DemoFabricConfig without -Create), the notebooks in fabric/notebooks, the Real-Time Dashboard,
    and the history model and report (Items - List Items). The Insights app isn't a DONE requirement. Internal.

    .DESCRIPTION
    Only a list that answered without an item makes it missing: a Fail, whose fix is the rerun that imports it. A list
    that failed says nothing about whether an item exists, so that item couldn't be checked (live finding, 2026-11-10:
    List Lakehouses answered HTTP 404 CapacityNotActive while the capacity's owner had paused it, and the run called the
    lakehouse missing, with a rerun as the fix):
    - Fabric answered that the workspace's capacity is paused or inactive (Get-DemoFabricListFailureKind): Manual action
      required, with evidence capacityInactive. The capacity is read then (Test-DemoFabricWorkspace), and its
      FABRIC.P5.CAPACITY record comes first in the output when it says so too, so the run names it
      (Get-DemoFabricCapacityBlock). The fix is to resume it, or have its administrator resume it, then run deploy.ps1
      again: deploy.ps1 never resumes, pauses, or scales a capacity, and importing what's missing needs it running too.
    - HTTP 401 or 403: Manual action required, with the access fix.
    - Anything else, throttling (HTTP 429) and service errors (5xx) included: a Warning with the HTTP status, whose fix
      is to run deploy.ps1 again in a few minutes; a Fail when other items are missing besides.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $checkId = 'FABRIC.ITEMS.REQUIRED'
    $docUrl = 'https://learn.microsoft.com/rest/api/fabric/core/items/list-items'
    $rerun = 'Run ./scripts/deploy.ps1 again: its Fabric track imports what''s missing (configure-fabric.ps1 and configure-powerbi.ps1).'
    try {
        $token = Get-DemoFabricToken -SubscriptionId ([string]$Config['subscriptionId'])
        $resolution = Resolve-DemoFabricConfig -Config $Config -Token $token -Confirm:$false
        # Assigned before it's enumerated: Get-DemoMemberValue returns an array whole.
        $resolveValue = Get-DemoMemberValue -InputObject $resolution -Name 'Results'
        $resolveRecords = @($resolveValue | Where-Object { $null -ne $_ })
        $setting = Get-DemoFabricResolveSetting -Config $Config
        $settings = Get-DemoFabricAppSetting
        $workspaceName = $setting.WorkspaceName
        $workspaceId = [string](Get-DemoMemberValue -InputObject $resolution -Name 'WorkspaceId')
        # What couldn't be checked, each with the list's answer: Name, StatusCode, Error, and Kind.
        $unchecked = [System.Collections.Generic.List[object]]::new()
        $addUnchecked = {
            param([string] $Name, [int] $StatusCode, [string] $ErrorText, [string] $Kind = '')
            if (-not $Kind) {
                $Kind = Get-DemoFabricListFailureKind -StatusCode $StatusCode -ErrorText $ErrorText
            }
            $unchecked.Add([pscustomobject]@{ Name = $Name; StatusCode = $StatusCode; Error = ([string]$ErrorText).TrimEnd('.', ' '); Kind = $Kind })
        }
        # The resolver's record of a list that didn't answer (evidence listed $false), as StatusCode, Error, and Kind; or $null.
        $unlisted = {
            param([string] $Id)
            $record = @($resolveRecords | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq $Id }) | Select-Object -Last 1
            $evidence = Get-DemoMemberValue -InputObject $record -Name 'evidence'
            if ($null -eq $record -or (Get-DemoMemberValue -InputObject $evidence -Name 'listed') -ne $false) {
                return $null
            }
            $code = Get-DemoMemberValue -InputObject $evidence -Name 'statusCode'
            $text = [string](Get-DemoMemberValue -InputObject $evidence -Name 'error')
            $kind = if ((Get-DemoMemberValue -InputObject $evidence -Name 'capacityInactive') -eq $true) { 'CapacityInactive' } elseif ($null -eq $code) { 'Access' } else { '' }
            return [pscustomobject]@{ StatusCode = [int]$code; Error = $(if ($text) { $text } else { [string](Get-DemoMemberValue -InputObject $record -Name 'message') }); Kind = $kind }
        }
        if (-not $workspaceId) {
            $failure = & $unlisted 'FABRIC.RESOLVE.WORKSPACE'
            if ($null -eq $failure) {
                return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('The Fabric workspace "{0}" isn''t there.' -f $workspaceName) -Remediation 'Run ./scripts/deploy.ps1 again: its Fabric track creates the workspace, the lakehouse, and the items.' -DocUrl $docUrl)
            }
            & $addUnchecked ('the workspace "{0}"' -f $workspaceName) $failure.StatusCode $failure.Error $failure.Kind
        }
        $missing = [System.Collections.Generic.List[string]]::new()
        $wanted = @(
            foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/notebooks') -Filter '*.ipynb' -File)) {
                @{ Name = $file.BaseName; Type = 'Notebook' }
            }
            @{ Name = [string]$settings['dashboardName']; Type = 'KQLDashboard' }
            @{ Name = [string]$settings['semanticModelName']; Type = 'SemanticModel' }
            @{ Name = [string]$settings['reportName']; Type = 'Report' }
        )
        if ($workspaceId) {
            $lakehouseLabel = 'the lakehouse {0}' -f $setting.LakehouseName
            if (-not [string](Get-DemoMemberValue -InputObject $resolution -Name 'LakehouseId')) {
                $failure = & $unlisted 'FABRIC.RESOLVE.LAKEHOUSE'
                if ($null -ne $failure) {
                    & $addUnchecked $lakehouseLabel $failure.StatusCode $failure.Error $failure.Kind
                }
                else {
                    $missing.Add($lakehouseLabel)
                }
            }
            foreach ($item in $wanted) {
                $found = Find-DemoFabricItem -WorkspaceId $workspaceId -DisplayName $item.Name -Type $item.Type -Token $token
                if ($found.StatusCode -ne 200) {
                    & $addUnchecked $item.Name $found.StatusCode ([string]$found.Error)
                }
                elseif (@($found.Items).Count -eq 0) {
                    $missing.Add($item.Name)
                }
            }
        }
        if ($missing.Count -eq 0 -and $unchecked.Count -eq 0) {
            $names = @(@($wanted | ForEach-Object { $_.Name }) + @($setting.LakehouseName))
            return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('The workspace "{0}" has the lakehouse, the notebooks, the Real-Time Dashboard, and the history model and report.' -f $workspaceName) -Evidence ([ordered]@{ items = $names }) -DocUrl $docUrl)
        }
        $evidence = [ordered]@{ missing = $missing.ToArray() }
        if ($unchecked.Count -eq 0) {
            return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('The workspace "{0}" is missing: {1}.' -f $workspaceName, ($missing -join ', ')) -Evidence $evidence -Remediation $rerun -DocUrl $docUrl)
        }

        # What couldn't be checked isn't missing (live finding, 2026-11-10).
        $evidence['unchecked'] = @($unchecked | ForEach-Object { [ordered]@{ name = $_.Name; statusCode = $_.StatusCode; error = $_.Error } })
        $one = $unchecked.Count -eq 1
        $names = (@($unchecked | ForEach-Object { $_.Name }) -join ', ')
        $how = if ($workspaceId) { 'couldn''t all be checked' } else { 'couldn''t be checked' }
        $besides = if ($missing.Count -gt 0) { ' Missing besides, from lists that answered: {0}.' -f ($missing -join ', ') } else { '' }
        $paused = @($unchecked | Where-Object { $_.Kind -eq 'CapacityInactive' })
        if ($paused.Count -gt 0) {
            # The capacity's own record, so the run names it first (Get-DemoFabricCapacityBlock).
            $evidence['capacityInactive'] = $true
            $capacityRecord = $null
            $resolvedConfig = Get-DemoMemberValue -InputObject $resolution -Name 'Config'
            $whose = 'the capacity of the workspace "{0}" is paused or inactive' -f $workspaceName
            if ($null -ne $resolvedConfig -and $workspaceId) {
                $read = @(Test-DemoFabricWorkspace -Config $resolvedConfig -Token $token | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq 'FABRIC.P5.CAPACITY' }) | Select-Object -First 1
                $readEvidence = Get-DemoMemberValue -InputObject $read -Name 'evidence'
                $state = [string](Get-DemoMemberValue -InputObject $readEvidence -Name 'state')
                if ($null -ne $read -and $state -and $state -ine 'Active') {
                    $capacityRecord = $read
                    $capacityName = [string](Get-DemoMemberValue -InputObject $readEvidence -Name 'capacityName')
                    $sku = [string](Get-DemoMemberValue -InputObject $readEvidence -Name 'sku')
                    $evidence['capacityName'] = $capacityName
                    $evidence['capacityState'] = $state
                    $whose = 'the capacity "{0}"{1} of the workspace "{2}" is {3}' -f $capacityName, $(if ($sku) { ' ({0})' -f $sku } else { '' }), $workspaceName, $state
                }
            }
            $message = 'The required Fabric items {0}: {1}, so Fabric didn''t list {2} ({3}). That doesn''t mean {4} missing: Fabric lists {5} again once the capacity is resumed.{6}' -f $how, $whose, $names, $paused[0].Error, $(if ($one) { 'it''s' } else { 'they''re' }), $(if ($one) { 'it' } else { 'them' }), $besides
            $items = New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message $message -Evidence $evidence -Remediation (Get-DemoFabricCapacityResumeFix -Then 'run ./scripts/deploy.ps1 again.') -DocUrl 'https://learn.microsoft.com/fabric/enterprise/pause-resume'
            if ($null -ne $capacityRecord) {
                return @($capacityRecord, $items)
            }
            return $items
        }

        $detail = (@($unchecked | ForEach-Object { '{0} ({1})' -f $_.Name, $(if ($_.Error) { $_.Error } else { 'HTTP {0}' -f $_.StatusCode }) }) -join '; ')
        $kinds = @($unchecked | ForEach-Object { $_.Kind })
        $codes = (@($unchecked | Where-Object { $_.StatusCode -gt 0 } | ForEach-Object { 'HTTP {0}' -f $_.StatusCode } | Select-Object -Unique) -join ', ')
        $status = if ($missing.Count -gt 0) { 'Fail' } elseif ('Access' -in $kinds) { 'Manual action required' } else { 'Warning' }
        $remediation = if ($missing.Count -gt 0) {
            $rerun
        }
        elseif ('Access' -in $kinds) {
            'Check your role in the workspace "{0}" (Contributor or higher; a workspace administrator adds you in Manage access) and your Azure CLI sign-in (az login --tenant <tenantId>), then run ./scripts/deploy.ps1 again.' -f $workspaceName
        }
        elseif ('Other' -in $kinds) {
            'Run ./scripts/deploy.ps1 again; if Fabric answers the same, look at the workspace "{0}" in the Fabric portal.' -f $workspaceName
        }
        elseif ('Unavailable' -in $kinds) {
            'Fabric didn''t answer the list{0}, even after retries: run ./scripts/deploy.ps1 again in a few minutes.' -f $(if ($codes) { ' ({0})' -f $codes } else { '' })
        }
        else {
            'Fabric is throttling requests (HTTP 429), even after retries: run ./scripts/deploy.ps1 again in a few minutes.'
        }
        $message = if ($missing.Count -gt 0) {
            'The workspace "{0}" is missing: {1}. Fabric didn''t list {2}, so {3} couldn''t be checked.' -f $workspaceName, ($missing -join ', '), $detail, $(if ($one) { 'that one' } else { 'those' })
        }
        else {
            'The required Fabric items {0}: Fabric didn''t list {1}. That doesn''t mean {2} missing.' -f $how, $detail, $(if ($one) { 'it''s' } else { 'they''re' })
        }
        return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status $status -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
    }
    catch {
        $text = Protect-DemoText -Text $_.Exception.Message
        if (Test-DemoFabricCapacityInactiveText -Text $text) {
            return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message ('The Fabric items couldn''t be checked: the workspace''s capacity is paused or inactive ({0}). That doesn''t mean they''re missing.' -f $text.TrimEnd('.', ' ')) -Evidence ([ordered]@{ capacityInactive = $true }) -Remediation (Get-DemoFabricCapacityResumeFix -Then 'run ./scripts/deploy.ps1 again.') -DocUrl 'https://learn.microsoft.com/fabric/enterprise/pause-resume')
        }
        return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('The Fabric items couldn''t be checked: {0}' -f $text) -Remediation 'Run ./scripts/deploy.ps1 again in a few minutes, once Fabric answers.' -DocUrl $docUrl)
    }
}

function Get-DemoFabricTrackRecheck {
    <#
    .SYNOPSIS
    Whether a resumed deploy.ps1 runs the Fabric step again although an earlier run recorded it as finished
    (DbHubTrackFabric): FABRIC.ITEMS.REQUIRED's read-only check (Test-DemoFabricRequiredItem), when it's a Fail, which it is
    only when a list that answered lacks the workspace, the lakehouse, or an item. Returns that record, or $null when
    everything is there or the check couldn't tell (a paused capacity, access, throttling, an error): the run then goes on
    as recorded, and its DONE check says why. Internal.

    .DESCRIPTION
    Live finding, 2026-11-13 (rg-dbhubup-demo, on main too): a first run met a paused capacity, so the workspace couldn't be
    created, but the step's records were "Manual action required", not "Fail", and the step was recorded as finished. Every
    later run skipped it, and DONE's check said "run deploy.ps1 again" each time. A Fabric step with "Manual action required"
    isn't recorded any more (Invoke-DemoDeploymentTrack); this covers a record that an earlier version wrote.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    try {
        $check = @(Test-DemoFabricRequiredItem -Config $Config | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq 'FABRIC.ITEMS.REQUIRED' }) | Select-Object -Last 1
    }
    catch {
        Write-DemoLog -Level Warning -Message ('Whether the Fabric workspace and its items are there couldn''t be checked, so the Fabric step goes on as recorded: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        return $null
    }
    if ($null -ne $check -and [string](Get-DemoMemberValue -InputObject $check -Name 'status') -eq 'Fail') {
        return $check
    }
    return $null
}

function Get-DemoTelemetryRetryTarget {
    <#
    .SYNOPSIS
    The targets whose latest TELEMETRY.<target> result says their data didn't come (Test-DemoHubTelemetry: a Fail with
    no rows, or the Warning whose newest sample is too old): what a stopped plugin, an agent that isn't sending, or a
    paused database causes, and what Invoke-DemoTelemetryRecovery addresses (Phase 28 live finding, 2026-10-30). Not an
    access or query error (evidence errorKind), an unknown resource ID, or rows under another ResourceID: checking the
    monitoring again doesn't change those. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $targets = [System.Collections.Generic.List[string]]::new()
    foreach ($target in 'T1', 'T2', 'T3') {
        $latest = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq ('TELEMETRY.{0}' -f $target) }) | Select-Object -Last 1
        if ($null -eq $latest -or [string]$latest.status -notin 'Fail', 'Warning') {
            continue
        }
        $evidence = Get-DemoMemberValue -InputObject $latest -Name 'evidence'
        if (-not [string](Get-DemoMemberValue -InputObject $evidence -Name 'resourceId') -or
            [string](Get-DemoMemberValue -InputObject $evidence -Name 'errorKind') -or
            [string](Get-DemoMemberValue -InputObject $evidence -Name 'telemetryResourceId')) {
            continue
        }
        $targets.Add($target)
    }
    return $targets.ToArray()
}

function Invoke-DemoTelemetryRecovery {
    <#
    .SYNOPSIS
    Before a run is judged NOT DONE for a target's telemetry (Get-DemoTelemetryRetryTarget), checks that target's
    monitoring once, and, when it's on, waits for the telemetry, bounded, and checks it again (Phase 28 live finding,
    2026-10-30). Returns Results (the monitoring checks, then the new TELEMETRY results) and Rechecked (the targets whose
    telemetry was checked again). Internal.

    .DESCRIPTION
    Live: T1's monitoring plugin stopped after a restart (DatabaseMonitorArcPlugin NotRunning less than 90 minutes after
    start-demo.ps1 found it Running), the run's T1 track had finished in an earlier run, and the final check failed
    TELEMETRY.T1; restarting the SQL IaaS Agent service brought the plugin back in 161 seconds.
    - T1: Invoke-DemoT1MonitoringCheck (DEPLOY.T1.MONITORING): the plugin's state, and the agent's restart when it isn't
      running, once; the status page says "Restarting T1's monitoring plugin, which stopped after a restart; no action
      needed."
    - T2: Get-DemoArcCheck -Check Connected, Monitoring, read-only. There's no cheap repair: monitoring is a setting of
      the Arc SQL Server instance, which a restart doesn't turn off, and the T2 step converges it.
    - T3: Invoke-DemoT3WarmUp (T3.WARMUP, T3.PROPERTY): wakes a paused database, and reads its extended property.
    A target whose monitoring isn't on afterward isn't waited for: its own result says why. The rest get one
    Test-DemoHubTelemetry -WaitMinutes, shown on the status page's -ProgressStepId.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3')]
        [string[]] $Target,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 15,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [AllowEmptyString()]
        [string] $ProgressStepId = ''
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $wait = [System.Collections.Generic.List[string]]::new()
    $passed = { param([object[]] $Items, [string] $CheckId) @($Items | Where-Object { $null -ne $_ -and [string]$_.checkId -eq $CheckId -and [string]$_.status -eq 'Pass' }).Count -gt 0 }
    Write-DemoLog -Message ('No current telemetry from {0} in Database Hub; checking the monitoring once, then the telemetry again, before the run is judged.' -f (@($Target) -join ' and '))
    foreach ($name in @($Target | Select-Object -Unique)) {
        switch ($name) {
            'T1' {
                $plugin = Invoke-DemoT1MonitoringCheck -Config $Config -Occasion 'the deployment' -ProgressPath $ProgressPath
                $results.Add($plugin)
                if ([string]$plugin.status -eq 'Pass') {
                    $wait.Add('T1')
                }
            }
            'T2' {
                $arc = @(Get-DemoArcCheck -Config $Config -Check 'Connected', 'Monitoring' | Where-Object { $null -ne $_ })
                $results.AddRange([object[]]$arc)
                $connectedFailed = @($arc | Where-Object { [string]$_.checkId -eq 'T2.ARC.CONNECTED' -and [string]$_.status -eq 'Fail' }).Count -gt 0
                if ((& $passed $arc 'T2.ARC.MONITORING') -and -not $connectedFailed) {
                    $wait.Add('T2')
                }
            }
            'T3' {
                $warm = @(Invoke-DemoT3WarmUp -Config $Config | Where-Object { $null -ne $_ })
                $results.AddRange([object[]]$warm)
                if (& $passed $warm 'T3.PROPERTY') {
                    $wait.Add('T3')
                }
            }
        }
    }
    if ($wait.Count -gt 0) {
        if ($ProgressStepId) {
            Set-DemoProgressStep -Path $ProgressPath -Id $ProgressStepId -State 'Running' -AzureSide -Message ('Waiting up to {0} minutes for telemetry from {1} in Database Hub, after checking its monitoring: no action needed.' -f $WaitMinutes, ($wait -join ' and '))
        }
        $again = @(Test-DemoHubTelemetry -Config $Config -Target $wait.ToArray() -WaitMinutes $WaitMinutes | Where-Object { $null -ne $_ -and [string]$_.status -ne 'Not selected' })
        $results.AddRange([object[]]$again)
    }
    return [pscustomobject]@{ Results = $results.ToArray(); Rechecked = $wait.ToArray() }
}

function Invoke-DemoTelemetryCheck {
    <#
    .SYNOPSIS
    Test-DemoHubTelemetry for -Target, then, for each target whose data didn't come (Get-DemoTelemetryRetryTarget), the
    recovery once (Invoke-DemoTelemetryRecovery), whose new TELEMETRY results replace the first ones, so a run isn't
    judged NOT DONE on telemetry that a stopped plugin held back (Phase 28 live finding, 2026-10-30). -NoRecovery only
    checks, for a caller that already knows the run isn't DONE. Returns the results. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3')]
        [string[]] $Target,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 15,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [AllowEmptyString()]
        [string] $ProgressStepId = '',

        [switch] $NoRecovery
    )

    $checks = @(Test-DemoHubTelemetry -Config $Config -Target $Target -WaitMinutes $WaitMinutes | Where-Object { $null -ne $_ })
    if ($NoRecovery) {
        return $checks
    }
    $retry = @(Get-DemoTelemetryRetryTarget -Result $checks | Where-Object { $_ -in $Target })
    if ($retry.Count -eq 0) {
        return $checks
    }
    $recovery = Invoke-DemoTelemetryRecovery -Config $Config -Target $retry -WaitMinutes $WaitMinutes -ProgressPath $ProgressPath -ProgressStepId $ProgressStepId
    $replaced = @(@($recovery.Rechecked) | ForEach-Object { 'TELEMETRY.{0}' -f $_ })
    $kept = @($checks | Where-Object { [string]$_.checkId -notin $replaced })
    return @(@($kept) + @($recovery.Results))
}

function Invoke-DemoDoneGate {
    <#
    .SYNOPSIS
    At the end of a run whose tracks all finished: runs each DONE requirement (Get-DemoDoneRequirement) that this run's
    results don't already show passing, read-only except for T4's read replica, so a resumed run judges every target and
    not only the ones it worked on. Returns the new results. Internal.

    .DESCRIPTION
    The telemetry comes last (Invoke-DemoTelemetryCheck): when nothing else this gate checked failed, a target whose
    telemetry didn't come gets its monitoring checked, and its telemetry once more, before the run is judged (Phase 28
    live finding, 2026-10-30: T1's plugin had stopped after a restart, and the run ended NOT DONE on TELEMETRY.T1).
    T4's read replica exists only during a session (ADR 0025), so a run that didn't create it (a resumed run whose T4
    track finished earlier, after stop-demo.ps1 deleted it) creates it here, as the T4 track does, before it reads it
    (Invoke-DemoT4ReplicaDoneCheck).
    -ProgressPath is the status page's model, whose Validation step says so. When the latest read of the Hub tenant
    setting in -Result says it's off, it's read once more (FABRIC.P4.HUBSETTING, one call to the Fabric admin API), so a
    setting an administrator turned on during the run doesn't keep it from DONE (Phase 28 review).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowEmptyCollection()]
        [string[]] $Requirement = @(),

        [ValidateRange(0, 120)]
        [int] $TelemetryWaitMinutes = 15,

        [AllowEmptyString()]
        [string] $ProgressPath = ''
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $hubRead = Get-DemoHubSettingLatestRead -Result $Result
    if ($null -ne $hubRead -and (Test-DemoTenantSettingRead -Result $hubRead) -eq 'Disabled') {
        Write-DemoLog -Message ('{0} read the Hub tenant setting as disabled earlier in this run; reading it once more before the run is judged.' -f [string]$hubRead.checkId)
        $results.Add((Test-DemoFabricHubSetting -Config $Config -CheckId 'FABRIC.P4.HUBSETTING'))
    }
    $missing = @((Test-DemoDoneEvidence -Result $Result -Requirement $Requirement).Missing)
    if ($missing.Count -eq 0) {
        return $results.ToArray()
    }
    Write-DemoLog -Message ('Checking what DONE needs and this run didn''t show yet: {0}.' -f ($missing -join ', '))
    $estate = @($missing | Where-Object { $_ -like 'HUB.ESTATE.T?' } | ForEach-Object { $_.Substring(11) })
    if ($estate.Count -gt 0) {
        $results.AddRange([object[]]@(Test-DemoHubEstate -Config $Config -Target $estate))
    }
    $telemetry = @($missing | Where-Object { $_ -like 'TELEMETRY.*' } | ForEach-Object { $_.Substring(10) })
    if ('METRICS.T4' -in $missing) {
        $t4 = Get-DemoT4State -Config $Config
        $results.Add((Test-DemoT4MetricFlow -Config $Config -ServerId $t4.Names.ServerId -State $t4.State -WaitMinutes $TelemetryWaitMinutes))
    }
    if ('METRICS.T4.REPLICA' -in $missing -or 'HUB.ESTATE.T4.REPLICA' -in $missing) {
        # T4's read replica (ADR 0025) exists only during a session: a run that didn't create it (a resumed run's
        # validation, after stop-demo.ps1 deleted it) creates it now, as the T4 track does, then reads it.
        $results.AddRange([object[]]@(Invoke-DemoT4ReplicaDoneCheck -Config $Config -Missing $missing -WaitMinutes $TelemetryWaitMinutes))
    }
    $arc = @(@(if ('T2.ARC.SQLINSTANCE' -in $missing) { 'SqlInstance' }) + @(if ('T2.ARC.MONITORING' -in $missing) { 'Monitoring' }))
    if ($arc.Count -gt 0) {
        $results.AddRange([object[]]@(Get-DemoArcCheck -Config $Config -Check $arc))
    }
    if ('T1.SQLVM.ASSOCIATEDSERVICES' -in $missing) {
        $results.Add((Test-DemoSqlVmAssociatedService -Config $Config -WaitMinutes 10 -ListedStatus 'Fail'))
    }
    if ('FABRIC.ITEMS.REQUIRED' -in $missing) {
        # Its FABRIC.P5.CAPACITY first when the workspace's capacity is paused (live finding, 2026-11-10).
        $results.AddRange([object[]]@(Test-DemoFabricRequiredItem -Config $Config | Where-Object { $null -ne $_ }))
    }
    if ($telemetry.Count -gt 0) {
        # The recovery only when everything else DONE needs passed: otherwise the run isn't DONE whatever the telemetry shows.
        $others = @($Requirement | Where-Object { $_ -notlike 'TELEMETRY.*' })
        $blocked = @($results | Where-Object { $null -ne $_ -and [string]$_.status -in 'Fail', 'Manual action required' }).Count -gt 0 -or
            -not (Test-DemoDoneEvidence -Result (@($Result) + @($results.ToArray())) -Requirement $others).Complete
        $results.AddRange([object[]]@(Invoke-DemoTelemetryCheck -Config $Config -Target $telemetry -WaitMinutes $TelemetryWaitMinutes -ProgressPath $ProgressPath -ProgressStepId 'Validation' -NoRecovery:$blocked))
    }
    return $results.ToArray()
}

function Get-DemoFabricCapacityBlock {
    <#
    .SYNOPSIS
    The record that says the Fabric workspace's capacity is paused or inactive, when that's the latest word on it in
    -Result, or $null (live finding, 2026-11-10). Get-DemoDeploymentOutcome names it first among what blocks DONE: the
    Fabric records a paused capacity causes, which can come earlier in the run (a lakehouse list that Fabric refuses,
    FABRIC.RESOLVE.LAKEHOUSE; the required items that couldn't be checked, FABRIC.ITEMS.REQUIRED), share its fix, which
    only its owner or administrator can do. Pure. Internal.

    .DESCRIPTION
    In the results' order: FABRIC.P5.CAPACITY as a Fail or Manual action required that read a state other than Active is
    the capacity's own record, and preferred; a Pass of it (Active when read) settles every earlier sign; any other Fail
    or Manual action required with evidence capacityInactive is a sign, named when no capacity record says so.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $capacity = $null
    $sign = $null
    foreach ($item in @($Result | Where-Object { $null -ne $_ })) {
        $status = [string](Get-DemoMemberValue -InputObject $item -Name 'status')
        $evidence = Get-DemoMemberValue -InputObject $item -Name 'evidence'
        if ([string](Get-DemoMemberValue -InputObject $item -Name 'checkId') -eq 'FABRIC.P5.CAPACITY') {
            $state = [string](Get-DemoMemberValue -InputObject $evidence -Name 'state')
            if ($status -eq 'Pass') {
                $capacity = $null
                $sign = $null
            }
            elseif ($status -in 'Fail', 'Manual action required' -and $state -and $state -ine 'Active') {
                $capacity = $item
            }
            continue
        }
        if ($status -in 'Fail', 'Manual action required' -and (Get-DemoMemberValue -InputObject $evidence -Name 'capacityInactive') -eq $true) {
            $sign = $item
        }
    }
    if ($null -ne $capacity) {
        return $capacity
    }
    return $sign
}

function Get-DemoDeploymentOutcome {
    <#
    .SYNOPSIS
    The one ending of a deploy.ps1 run (brief item 1): Kind Done, NotDone, or WhatIf, with Reason, Next (the single next
    action), NextCommand (the exact command), Notes (what DONE states plainly: T4 off and why, T4 on the General Purpose
    fallback with its hourly price from -T4HourlyUsd, "created" only when -T4Created or this run's evidence shows the
    server, a nightly safety stop this run set up only in part (Get-DemoSafetyStopNote, ADR 0024), the nightly stop that
    waited for this run and when the demo stops tonight (Get-DemoBusyMarkerNote, 2026-11-14), Run Commands that ran
    under a fresh name because Azure kept their own in Deleting (Get-DemoRunCommandStuckNote), Developer mode's T2),
    NonBlocking (what didn't work but never blocks DONE, such as the Insights app; Get-DemoNonBlockingItem), Unfinished
    (tracks that didn't finish), Missing (DONE requirements without a Pass), and ExitCode: 0 when DONE, 1 when NOT DONE
    with a Fail, 2 when NOT DONE otherwise; -WhatIfRun is 0 unless a check failed. Pure. Internal.

    .DESCRIPTION
    DONE (brief item 16) needs every track this configuration has (T1, T2, T4 unless it's off, and Fabric unless
    -SkipFabric) finished according to the resource group's state; a Pass for every DONE requirement
    (Get-DemoDoneRequirement: Database Hub's own views of every target); no Fail; and no Manual action required except
    what only a person can confirm, which a rerun can't resolve (Test-DemoConfirmOnlyResult: the Hub tenant setting
    that couldn't be read, from either check, decided by its evidence, a capacity SKU, presenters' roles, the app's
    browser check; Phase 28 live finding, 2026-10-30), and the non-blocking parts (Test-DemoNonBlockingResult: the
    Insights app's records, which are part of every deployment but never block DONE, whatever they say, a network error
    included, so a rerun of the whole deployment is never the next step for them; 2026-11-05). Confirm, on every
    outcome, lists the confirm-only items once each (Get-DemoConfirmItem), which DONE's banner shows under "Please
    confirm". Without a state, this run's DEPLOY.TRACK results stand in. -Sequential (deploy.ps1
    -Sequential, which records stages and no tracks) needs the recorded stage Validation instead of the tracks (or,
    without a state, this run's DEPLOY.STAGE.VALIDATION Pass), and the same DONE requirements, which its validation
    checks (review finding 4). -Stopped (Ctrl+C) is NOT DONE with the resume command (Phase 28 live finding). DONE also
    never comes while the state records what a
    guided stop or session left open (Get-DemoGuidedStopLeftover: the guided stop's Bastion, a handed-over host password
    that isn't rotated): that's NOT DONE naming stop-demo.ps1 -RemoveBastionOnly (Phase 28 review). A NOT DONE's reason
    names only what blocks DONE, and its next step is that item's own fix (a requirement's latest result included),
    never a plain rerun for something a rerun can't change; a step that a network error stopped (Test-DemoNetworkResult)
    is exactly that, so its next step is the rerun, which resumes (Phase 28 live finding). A fix that names a deploy.ps1
    command (-FromStage Artifacts, for example) names it as this run's own -Command with that fix's parameters, and
    NextCommand is that command, so the Run line and the text agree and keep the run's -ConfigPath
    (Resolve-DemoDeployCommandText; live finding, 2026-11-06).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [object] $State,

        [System.Collections.IDictionary] $Config = @{},

        [string] $Command = './scripts/deploy.ps1',

        [switch] $WhatIfRun,

        [AllowEmptyString()]
        [string] $StopAfter = '',

        [switch] $SkipFabric,

        [switch] $Sequential,

        [switch] $Stopped,

        # What this run started or created (Get-DemoStartedVm): a NOT DONE or stopped run names it, since it bills until
        # a stop (Phase 28).
        [AllowEmptyCollection()]
        [string[]] $StartedVm = @(),

        # T4's hourly list price at a fallback size (ADR 0019), from the Azure Retail Prices API;
        # the caller reads it, so this stays pure.
        [AllowNull()]
        [object] $T4HourlyUsd = $null,

        # Whether T4's server exists (review of 20e855c): $true or $false from the caller's Servers - Get; $null takes
        # this run's results and the T4 track's record (Get-DemoT4ServerEvidence). The fallback note says "created" only
        # when it's $true, and -T4Why says why it isn't.
        [AllowNull()]
        [object] $T4Created = $null,

        [string] $T4Why = '',

        # The size change's notice (2026-11-09; Format-DemoT4SizeChangeText): what was tried and refused, what was deployed,
        # and both monthly estimates, which the caller made, so this stays pure.
        [string] $T4Notice = ''
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $billing = Get-DemoBillingNote -Config $Config -Name $StartedVm -Command $Command
    $core = @($all | Where-Object { -not (Test-DemoNonBlockingResult -Result $_) })
    $fails = @($core | Where-Object { [string]$_.status -eq 'Fail' -and [string]$_.checkId -ne 'DEPLOY.SUMMARY' })
    # Only what a person or a rerun can act on blocks DONE; what only a person can confirm is listed instead.
    $manual = @($core | Where-Object { [string]$_.status -eq 'Manual action required' -and [string]$_.checkId -ne 'DEPLOY.SUMMARY' -and -not (Test-DemoConfirmOnlyResult -Result $_ -Context $all) })
    $nonBlocking = @(Get-DemoNonBlockingItem -Result $all)
    $confirm = @(Get-DemoConfirmItem -Result $all)
    $resume = 'If this window closes or the PC restarts, run ./scripts/deploy.ps1 again; it continues where it stopped.'
    $installMode = if ($Config.Contains('t2SqlInstallMode') -and $Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'JumpstartImage' }
    $t4Off = Get-DemoT4OffReason -Config $Config -State $State -Result $all
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($t4Off) {
        $notes.Add($t4Off)
    }
    # Said loudly (ADR 0019): T4 runs at a fallback size, with whether autonomous tuning is on and its price; "created" only with
    # evidence that the server exists (review of 20e855c).
    $t4Created = if ($null -ne $T4Created) { [bool]$T4Created } else { Get-DemoT4ServerEvidence -Result $all -State $State }
    $t4Fallback = Get-DemoT4FallbackNote -Config $Config -State $State -HourlyUsd $T4HourlyUsd -Created $t4Created -Why $T4Why -Notice $T4Notice
    if ($t4Fallback) {
        $notes.Add($t4Fallback)
    }
    # The nightly safety stop (ADR 0024), said plainly when this run set it up only in part, such as without its role.
    $safetyStop = Get-DemoSafetyStopNote -Result $all
    if ($safetyStop) {
        $notes.Add($safetyStop)
    }
    # The busy marker (2026-11-14): the nightly stop waited for this run, and when the demo stops tonight.
    $busyNote = Get-DemoBusyMarkerNote -Result $all
    if ($busyNote) {
        $notes.Add($busyNote)
    }
    # T4's read replica (ADR 0025): created for this session, at another size than T4's (its notice), or Not supported.
    $replicaNote = Get-DemoT4ReplicaNote -Result $all
    if ($replicaNote) {
        $notes.Add($replicaNote)
    }
    # The on-demand control's runbooks, when this run couldn't publish them with this code (2026-11-13).
    $controlNote = Get-DemoActivityControlRunbookNote -Result $all
    if ($controlNote) {
        $notes.Add($controlNote)
    }
    # The session control (ADR 0026): where Run all is, or what it still needs and who does it.
    $sessionControl = Get-DemoControlDeployNote -Result $all
    if ($sessionControl) {
        $notes.Add($sessionControl)
    }
    # Run Commands that ran under a fresh name because Azure kept their own in Deleting (2026-11-13 live finding).
    $stuckNote = Get-DemoRunCommandStuckNote -Result $all
    if ($stuckNote) {
        $notes.Add($stuckNote)
    }
    if ($installMode -eq 'Developer') {
        $notes.Add('T2 runs SQL Server Developer edition (t2SqlInstallMode Developer, which you chose): it''s in Database Hub''s Estate, but T2 has no performance data or Database Agent findings. JumpstartImage (the default) or ProductKey mode gives them.')
    }
    $outcome = [ordered]@{ Kind = 'NotDone'; Done = $false; Reason = ''; Next = ''; NextCommand = $Command; Notes = $notes.ToArray(); NonBlocking = $nonBlocking; Confirm = $confirm; Unfinished = @(); Missing = @(); ExitCode = 2; Resume = $resume }
    if ($WhatIfRun) {
        $outcome.Kind = 'WhatIf'
        $outcome.ExitCode = if ($fails.Count -gt 0) { 1 } else { 0 }
        $outcome.Reason = if ($fails.Count -gt 0) { ('What if: {0} check(s) failed, so a deployment would stop at preflight: {1}.' -f $fails.Count, (($fails | Select-Object -First 3 | ForEach-Object { $_.checkId }) -join ', ')) } else { 'What if: the checks and the template''s what-if ran; nothing was deployed.' }
        $outcome.Next = 'Run ./scripts/deploy.ps1 without -WhatIf to deploy.'
        return [pscustomobject]$outcome
    }
    if ($Stopped) {
        # Ctrl+C (Phase 28 live finding): whatever it had reached, a stopped run isn't DONE, and nothing is lost. A fix pulled
        # before the rerun reaches the VMs: the resume sends them a bootstrap bundle or workload runner that changed
        # (Resolve-DemoArtifactResend; live finding, 2026-11-06).
        $outcome.Reason = 'You stopped deploy.ps1 (Ctrl+C) before it finished. What it finished is kept, and the resource group''s state records where it stopped.'
        $outcome.Next = 'Run {0} again when you''re ready: it continues where it stopped, and when the bootstrap bundle or the workload runner changed meanwhile (a fix you pulled, for example), it sends them to the VMs again first.' -f $Command
        if ($billing) {
            $outcome.Notes = @($outcome.Notes) + @($billing)
        }
        return [pscustomobject]$outcome
    }
    # What a guided stop or session left open (Phase 28 review): DONE never comes with it.
    $leftover = Get-DemoGuidedStopLeftover -State $State
    $stopCommand = Get-DemoStopDemoCommand -Command $Command
    $leftoverNext = 'Run {0}: it removes Bastion and rotates the host password, and leaves the VMs running. Then run {1} again.' -f $stopCommand, $Command
    # T4 is part of every deployment (2026-11-09): its track is always expected.
    $expected = [ordered]@{ T1 = 'Telemetry'; T2 = 'Telemetry'; T4 = 'Telemetry' }
    if (-not $SkipFabric) {
        $expected['Fabric'] = 'Fabric'
    }
    $unfinished = [System.Collections.Generic.List[string]]::new()
    $lastStage = ''
    if ($Sequential) {
        # deploy.ps1 -Sequential records only its last finished stage, never a track (review finding 4): its stages are
        # done once Validation is recorded, or, without a state, once this run's validation passed.
        if ($null -ne $State) {
            $lastStage = [string](Get-DemoMemberValue -InputObject $State -Name 'Stage')
            $stagesDone = $lastStage -eq 'Validation'
        }
        else {
            $stagesDone = @($all | Where-Object { [string]$_.checkId -eq 'DEPLOY.STAGE.VALIDATION' -and [string]$_.status -eq 'Pass' }).Count -gt 0
        }
        if (-not $stagesDone) {
            $unfinished.Add('Stages')
        }
    }
    foreach ($track in @($expected.Keys | Where-Object { -not $Sequential })) {
        $done = $false
        if ($null -ne $State) {
            $done = [string](Get-DemoMemberValue -InputObject $State -Name ('Track{0}' -f $track)) -eq $expected[$track]
        }
        else {
            $summary = @($all | Where-Object { [string]$_.checkId -eq ('DEPLOY.TRACK.{0}' -f $track.ToUpperInvariant()) }) | Select-Object -Last 1
            $done = $null -ne $summary -and [string]$summary.status -eq 'Pass'
        }
        if (-not $done) {
            $unfinished.Add($track)
        }
    }
    $outcome.Unfinished = $unfinished.ToArray()
    $evidence = Test-DemoDoneEvidence -Result $core -Requirement (Get-DemoDoneRequirement -InstallMode $installMode -SkipFabric:$SkipFabric)
    $outcome.Missing = @($evidence.Missing)
    if ($fails.Count -eq 0 -and $manual.Count -eq 0 -and $unfinished.Count -eq 0 -and $evidence.Complete -and -not $StopAfter -and -not $leftover) {
        $outcome.Kind = 'Done'
        $outcome.Done = $true
        $outcome.ExitCode = 0
        $outcome.NextCommand = ''
        $targets = 'T1, T2, T3, and T4'
        $performance = if ($installMode -eq 'Developer') { 'performance telemetry from T1 and T3' } else { 'performance telemetry from T1, T2, and T3' }
        $metrics = if (@($core | Where-Object { [string]$_.checkId -eq 'METRICS.T4.REPLICA' -and [string]$_.status -eq 'Pass' }).Count -gt 0) { ' and T4''s Azure Monitor metrics, with its read replica''s Read replica lag' } else { ' and T4''s Azure Monitor metrics' }
        $t2 = if ($installMode -eq 'Developer') { '' } else { ' T2 runs SQL Server Standard with pay-as-you-go (or your license) and monitoring on.' }
        # The Insights app, part of every deployment, when this run's records show it deployed and working.
        $app = Get-DemoInsightsAppSummary -Result $all
        $appText = if ($null -ne $app -and [bool]$app.Deployed -and -not [bool]$app.Failed) { ' the history report, and the Insights app' } else { ' and the history report' }
        $fabricText = if ($SkipFabric) { ' Fabric was skipped (-SkipFabric).' } else { ' Fabric has the workspace, the lakehouse, the notebooks, the Real-Time Dashboard,{0}.' -f $appText }
        $outcome.Reason = 'Database Hub shows every target: {0} in Estate, with {1}{2}.{3}{4}' -f $targets, $performance, $metrics, $t2, $fabricText
        return [pscustomobject]$outcome
    }
    $leftoverShown = $false
    # A paused or inactive Fabric capacity comes first (live finding, 2026-11-10): the Fabric records it causes, earlier in
    # the run or not, share its fix, which only its owner or administrator can do (Get-DemoFabricCapacityBlock).
    $capacityBlock = Get-DemoFabricCapacityBlock -Result $core
    $blocking = if ($null -ne $capacityBlock -and -not (Test-DemoConfirmOnlyResult -Result $capacityBlock -Context $all)) { $capacityBlock } else { @($fails) + @($manual) | Select-Object -First 1 }
    if ($null -ne $blocking) {
        $message = ConvertTo-DemoPlainText -Value $blocking.message
        if ($message.Length -gt 400) {
            $message = $message.Substring(0, 397) + '...'
        }
        $outcome.Reason = '{0}: {1}' -f $blocking.checkId, $message
        if ([string]$blocking.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER') {
            $outcome.Next = $leftoverNext
            $outcome.NextCommand = $stopCommand
            $leftoverShown = $true
        }
        elseif (Test-DemoNetworkResult -Result $blocking) {
            # A step that a network error stopped (Invoke-DemoTransientRetry) needs only a rerun, which resumes the step; the
            # script's own output wouldn't show more (Phase 28 live finding, 2026-10-30).
            $outcome.Next = 'Run {0} again: it resumes where it stopped. {1}' -f $Command, (Get-DemoNetworkErrorNote)
        }
        else {
            # The fix's own command, as this run's command with that fix's parameters (live finding, 2026-11-06).
            $fix = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $blocking -Name 'remediation')
            $named = Resolve-DemoDeployCommandText -Text $fix -Command $Command
            if ($named.Command) {
                $outcome.Next = $named.Text
                $outcome.NextCommand = $named.Command
            }
            else {
                $outcome.Next = '{0} Then run {1}.' -f $(if ($fix) { $named.Text.TrimEnd() } else { 'Fix the cause in the message above.' }), $Command
            }
        }
    }
    elseif ($StopAfter) {
        $outcome.Reason = 'Stopped after {0}, as asked (-StopAfter).' -f $StopAfter
        $outcome.Next = 'Run {0} to continue.' -f $Command
    }
    elseif ($unfinished.Count -gt 0 -and $Sequential) {
        $outcome.Reason = 'Not every stage finished: the last one recorded is {0}.' -f $(if ($lastStage) { $lastStage } else { 'none' })
        $outcome.Next = 'Run {0}: it continues after the last stage that finished.' -f $Command
    }
    elseif ($unfinished.Count -gt 0) {
        $outcome.Reason = 'Not every target finished: {0}.' -f ($unfinished -join ', ')
        $outcome.Next = 'Run {0}: it continues the unfinished track(s).' -f $Command
    }
    elseif ($leftover) {
        $outcome.Reason = 'Still open from an earlier guided stop or session: {0}. DONE never leaves access to the T2 host behind.' -f $leftover
        $outcome.Next = $leftoverNext
        $outcome.NextCommand = $stopCommand
        $leftoverShown = $true
    }
    else {
        $first = $evidence.Missing[0]
        $problem = $evidence.Problem
        $outcome.Reason = if ($null -ne $problem) { '{0} hasn''t passed yet ({1}): {2}' -f $first, $problem.status, (ConvertTo-DemoPlainText -Value $problem.message) } else { '{0} wasn''t checked yet. Database Hub must show it before the demo is done.' -f $first }
        # That requirement's own fix when its result has one (a rerun alone doesn't change a renamed resource ID, for
        # example); for telemetry, estate, or metrics that only lag, the wait they need after a deployment.
        $lag = $null -ne $problem -and [string]$problem.status -eq 'Warning' -and (($first -like 'TELEMETRY.*' -and @(Get-DemoTelemetryRetryTarget -Result @($problem)).Count -gt 0) -or $first -like 'HUB.ESTATE.*' -or $first -eq 'METRICS.T4')
        $fix = if ($null -ne $problem -and -not $lag) { ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $problem -Name 'remediation') } else { '' }
        $named = Resolve-DemoDeployCommandText -Text $fix -Command $Command
        if ($named.Command) {
            $outcome.Next = $named.Text
            $outcome.NextCommand = $named.Command
        }
        elseif ($fix) {
            $outcome.Next = '{0} Then run {1}.' -f $named.Text.TrimEnd(), $Command
        }
        else {
            $outcome.Next = 'Telemetry and estate entries can take a few more minutes after a deployment. Wait about 10 minutes, then run {0}: it checks again.' -f $Command
        }
    }
    if ($leftover -and -not $leftoverShown) {
        $outcome.Notes = @($outcome.Notes) + @(('Also still open from an earlier guided stop or session: {0}. {1} removes Bastion and rotates the host password; DONE waits for it.' -f $leftover, $stopCommand))
    }
    if ($billing) {
        $outcome.Notes = @($outcome.Notes) + @($billing)
    }
    $outcome.ExitCode = if ($fails.Count -gt 0) { 1 } else { 2 }
    return [pscustomobject]$outcome
}

function Get-DemoDeploymentOutcomeLine {
    # The DONE or NOT DONE banner's lines (brief item 1). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Outcome,

        [int] $Minutes = 0,

        [string] $WorkspaceName = ''
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    # Get-DemoMemberValue returns an array whole, so the notes are assigned first: each note is then its own line.
    $notes = Get-DemoMemberValue -InputObject $Outcome -Name 'Notes'
    # What didn't work but never blocks DONE (the Insights app; 2026-11-05), one line each, as on the status page.
    $nonBlockingValue = Get-DemoMemberValue -InputObject $Outcome -Name 'NonBlocking'
    $nonBlocking = @(@($nonBlockingValue) | Where-Object { $null -ne $_ } | ForEach-Object { Format-DemoNonBlockingLine -Item $_ } | Where-Object { $_ })
    switch ($Outcome.Kind) {
        'Done' {
            foreach ($line in (Get-DemoBannerLine -Title 'DONE')) { $lines.Add($line) }
            $lines.Add(('The demo is complete. {0}{1}' -f $Outcome.Reason, $(if ($Minutes -gt 0) { ' This run took {0} minutes.' -f $Minutes } else { '' })))
            foreach ($note in @($notes)) {
                if ($note) { $lines.Add([string]$note) }
            }
            foreach ($line in $nonBlocking) {
                $lines.Add($line)
            }
            # What only a person can confirm, once each; none of it kept the run from DONE (Phase 28 live finding).
            $confirmValue = Get-DemoMemberValue -InputObject $Outcome -Name 'Confirm'
            $confirm = @(@($confirmValue) | Where-Object { $null -ne $_ })
            if ($confirm.Count -gt 0) {
                $lines.Add('Please confirm (a rerun can''t check these, and none of them keeps the demo from being done):')
                foreach ($item in $confirm) {
                    $lines.Add(('- {0}' -f (ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $item -Name 'text'))))
                }
            }
            $lines.Add(('Where to look: open Database Hub in the Fabric portal and look at Estate and Performance; then start an incident (./scripts/demo-control.ps1) and investigate it with the Database Agent.{0}' -f $(if ($WorkspaceName) { ' The Real-Time Dashboard and the history report are in the workspace "{0}".' -f $WorkspaceName } else { '' })))
            # What runs now, and how to choose the other profile (2026-11-03): the incidents fill the Performance page.
            $activityLine = [string](Get-DemoMemberValue -InputObject $Outcome -Name 'Activity')
            if ($activityLine) {
                $lines.Add($activityLine)
            }
            $lines.Add('Each session: ./scripts/start-demo.ps1, then ./scripts/stop-demo.ps1 -SaveHistory.')
            $lines.Add('Capture a golden snapshot with ./scripts/capture-t2-golden.ps1 to make future redeploys skip T2''s build.')
        }
        'WhatIf' {
            foreach ($line in (Get-DemoBannerLine -Title 'WHAT IF: NOTHING WAS DEPLOYED')) { $lines.Add($line) }
            $lines.Add($Outcome.Reason)
            $lines.Add($Outcome.Next)
        }
        default {
            foreach ($line in (Get-DemoBannerLine -Title 'NOT DONE')) { $lines.Add($line) }
            $lines.Add(('Why: {0}' -f $Outcome.Reason))
            $lines.Add(('Next: {0}' -f $Outcome.Next))
            $lines.Add(('Run: {0}' -f $Outcome.NextCommand))
            $lines.Add($Outcome.Resume)
            $lines.Add('For help, ./scripts/collect-diagnostics.ps1 makes a redacted zip to attach to a Deployment problem issue.')
            foreach ($note in @($notes)) {
                if ($note) { $lines.Add([string]$note) }
            }
            foreach ($line in $nonBlocking) {
                $lines.Add($line)
            }
        }
    }
    return $lines.ToArray()
}
