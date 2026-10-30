# deploy.ps1's start, expectations, and ending (Phase 28, brief goals 1, 7 and prompting items 1, 2, 3, 7, 8, 13, 15):
# the start banner with the expected timeline and the person's part, the notices for sessions that can't take keyboard
# input and for GitHub Codespaces, and the one ending: DONE (every target ready, where to look, the optional items) or
# NOT DONE (why, the single next action as an exact command, and how to resume), with a nonzero exit code when it isn't
# done.
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

function Get-DemoDeploymentExpectation {
    <#
    .SYNOPSIS
    What a deploy.ps1 run can expect, as estimates from documented step times, not a measured run: the whole first run,
    a redeploy from a golden snapshot, and in PaygWizard mode when a person is needed and for how long. Pure. Internal.

    .DESCRIPTION
    The T2 guest build to the setup step takes 60 to 90 minutes (an ADR 0018 estimate; Phase 16 measured about 35
    minutes for a whole Developer guest build); before it, preflight takes 2 to 13 minutes (the policy inventory is 7 to
    13 of them on a first run with networkMode auto), the template 7 to 9, and the artifacts and the loader about 5. So
    the person is needed about 60 to 90 minutes after the start (it can be later; the run waits for them): about 10
    minutes of clicks, then 10 to 15 minutes while setup installs. Afterward, the sign-in cleanup, the database, Arc's
    PAYG and monitoring, and telemetry take about 30 to 45 minutes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('PaygWizard', 'ProductKey', 'Developer')]
        [string] $InstallMode = 'PaygWizard',

        [switch] $WaitForT2,

        [ValidateRange(0, 600)]
        [int] $T2WaitMinutes = 180
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('What to expect (estimates from documented step times, not a measured run):')
    if ($InstallMode -eq 'PaygWizard') {
        $lines.Add('- A first deployment takes about 2 to 3 hours in all; the T2 guest build alone is 60 to 90 minutes.')
    }
    else {
        $lines.Add('- A first deployment takes about 1.5 to 2.5 hours in all; the T2 guest build alone is 60 to 90 minutes. No step needs a person.')
    }
    $lines.Add('- A redeploy from a golden snapshot (./scripts/capture-t2-golden.ps1) takes about 30 to 45 minutes, with no build and no guided stop.')
    $human = ''
    if ($InstallMode -eq 'PaygWizard') {
        $human = 'about 60 to 90 minutes after the start (an estimate; it can be later, and the run waits), for about 10 minutes, plus 10 to 15 minutes while SQL Server setup installs: you sign in to archost01 through Bastion, choose pay-as-you-go and Standard in the pre-filled setup, and sign in to Azure on its Azure page.'
        if ($WaitForT2) {
            $lines.Add(('- The run asks a person for one step after the T2 guest build, {0} Keep this window open: the run waits up to {1} minutes for the build and the step, and at least 45 minutes once it asks.' -f $human, $T2WaitMinutes))
        }
        else {
            $lines.Add('- T2 builds in the background (-NoWaitForT2): this run finishes T1, T3, T4, and Fabric, and a later ./scripts/deploy.ps1 guides you through T2''s one step.')
        }
    }
    $lines.Add('- This PC stays awake while deploy.ps1 runs (Windows); keep it plugged in, and don''t close this window.')
    $lines.Add('- If this window closes or the PC restarts, run ./scripts/deploy.ps1 again; it continues where it stopped.')
    $text = if ($InstallMode -eq 'PaygWizard') { 'A first deployment takes about 2 to 3 hours (estimate); a redeploy from a golden snapshot about 30 to 45 minutes.' } else { 'A first deployment takes about 1.5 to 2.5 hours (estimate); a redeploy from a golden snapshot about 30 to 45 minutes.' }
    return [pscustomobject]@{
        Lines      = $lines.ToArray()
        Text       = $text
        HumanText  = $human
        GuidedStop = ($InstallMode -eq 'PaygWizard' -and [bool]$WaitForT2)
    }
}

function Get-DemoDeploymentNotice {
    <#
    .SYNOPSIS
    The start banner's notices (brief items 7, 8, 13): a session that can't take keyboard input (an assistant, a script,
    or CI) and what the guided stop then needs, with the alternatives; a GitHub Codespaces idle timeout; and the plain
    line an assistant can relay ahead of the guided stop. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Environment,

        [ValidateSet('PaygWizard', 'ProductKey', 'Developer')]
        [string] $InstallMode = 'PaygWizard',

        [switch] $WaitForT2,

        [string] $PagePath = ''
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $guided = $InstallMode -eq 'PaygWizard' -and $WaitForT2
    if ($guided -and -not [bool]$Environment.Interactive) {
        $lines.Add('This session doesn''t take keyboard input (its input is redirected, or it runs in an automation shell or under an assistant). That''s fine, but the PaygWizard guided stop needs a person at a browser for about 10 minutes, about 60 to 90 minutes from now, and no assistant can do its sign-ins. If nobody will be there, stop now (Ctrl+C) and choose one:')
        $lines.Add('  -NoWaitForT2: T1, T3, T4, and Fabric now; T2 builds in the background, and a later ./scripts/deploy.ps1 guides you through its step.')
        $lines.Add('  t2SqlInstallMode ProductKey: fully unattended with your own SQL Server Standard product key; T2 gets performance data and the agent''s findings.')
        $lines.Add('  t2SqlInstallMode Developer: fully unattended, but T2 shows in Database Hub''s Estate only, with no T2 performance data or findings.')
    }
    if ([bool]$Environment.Codespaces) {
        $lines.Add('GitHub Codespaces stops a codespace after 30 minutes without activity by default, and always after 12 hours. Terminal output counts as activity, and deploy.ps1 prints progress at least every 5 minutes, but raise the idle timeout to be safe: GitHub Settings > Codespaces > Default idle timeout (up to 240 minutes; it applies to codespaces you create afterward), or gh codespace create --idle-timeout 240m. An organization policy can lower it.')
    }
    if ($guided) {
        $page = if ($PagePath) { $PagePath } else { 'out/deploy-status.html' }
        $lines.Add(('PLAN FOR A PERSON: DEPLOY.T2.GUIDEDSTOP - about 60 to 90 minutes after the start, a person signs in to archost01 through Bastion and finishes SQL Server setup in arcsql01 (about 10 minutes, plus setup''s install). The run waits for them. Status page: {0}.' -f $page))
    }
    return $lines.ToArray()
}

function Get-DemoOptionalItem {
    <#
    .SYNOPSIS
    The optional parts that didn't finish and never block DONE (brief item 15): the Insights app (its step's records,
    Get-DemoInsightsAppSummary) and the history report's data check when the Execute Queries setting is off
    (FABRIC.SEMANTICMODEL.* Manual action required), each with the actual reason and how to add it later (Phase 28 live
    finding). Pure. Internal.
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
    if ($null -ne $app -and $app.Status -eq 'Manual action required' -and -not [bool](Get-DemoMemberValue -InputObject $app -Name 'ConfirmOnly')) {
        $items.Add([ordered]@{
                name    = $(if ($app.Deployed) { 'the Insights app' } else { 'the Insights app (Fabric Apps preview)' })
                message = $app.Reason
                howTo   = $app.HowTo
            })
    }
    $model = @($open | Where-Object { [string]$_.checkId -like 'FABRIC.SEMANTICMODEL.*' -and [string]$_.status -eq 'Manual action required' })
    if ($model.Count -gt 0) {
        $items.Add([ordered]@{
                name    = 'the history report''s data check'
                message = 'The report is deployed; its DAX data check needs a tenant setting.'
                howTo   = 'A Fabric administrator turns on Dataset Execute Queries REST API; then run ./scripts/configure-powerbi.ps1 -CheckModelData.'
            })
    }
    return $items.ToArray()
}

function Test-DemoInsightsAppRecord {
    # True for a record of the optional Insights app's step: its own checks (FABRIC.APP.*, DEPLOY.FABRIC.APP), or one its
    # step reported and marked optional (Invoke-DemoFabricAppStage). Internal.
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
    return ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Result -Name 'evidence') -Name 'optional') -eq 'insightsApp')
}

function Get-DemoInsightsAppSummary {
    <#
    .SYNOPSIS
    The optional Insights app's outcome from its step's records, never a Fail (brief item 15; Phase 28 live finding):
    State (Done or Skipped, for the status page), Status (Pass, Warning, Manual action required, or Not selected), Reason
    (the first record that kept it from being added, with its check ID), HowTo (that record's own fix, then the
    sign-in that adds it), StepMessage (both, in one line), and Deployed. $null without any of its records. Pure.
    Internal.
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
    $signIn = 'run ./scripts/configure-fabric-app.ps1 -SignIn, which opens a browser for your own sign-in (an assistant can''t do that sign-in for you), then deploys the app'
    $deployed = @($records | Where-Object { [string]$_.checkId -eq 'FABRIC.APP.DEPLOY' -and [string]$_.status -eq 'Pass' }).Count -gt 0
    $open = @($records | Where-Object { [string]$_.status -in 'Fail', 'Manual action required' })
    $blocking = @($open | Where-Object { [string]$_.checkId -ne 'FABRIC.APP.BROWSER' })
    if ($blocking.Count -gt 0) {
        $first = $blocking[0]
        $lead = if ($deployed) { 'It''s deployed, but' } else { 'It wasn''t added:' }
        $reason = '{0} {1}: {2}' -f $lead, [string]$first.checkId, (([string]$first.message) -replace '^Optional Insights app: ', '').TrimEnd()
        $fix = ([string](Get-DemoMemberValue -InputObject $first -Name 'remediation')).Trim()
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
        $howTo = 'To add it later: {0}.' -f ($steps -join '; then ')
        return [pscustomobject]@{ State = $(if ($deployed) { 'Done' } else { 'Skipped' }); Status = 'Manual action required'; Reason = $reason; HowTo = $howTo; StepMessage = ('Optional. {0} {1}' -f $reason, $howTo); Deployed = $deployed }
    }
    if ($open.Count -gt 0) {
        # Deployed and checked; a person confirms it once in the browser, which a rerun can't do: listed under "Please
        # confirm", never as optional work left (Phase 28 live finding, 2026-10-30).
        $reason = 'It''s deployed: {0}' -f ([string]$open[0].message).TrimEnd()
        $howTo = ([string](Get-DemoMemberValue -InputObject $open[0] -Name 'remediation')).Trim()
        return [pscustomobject]@{ State = 'Done'; Status = 'Manual action required'; Reason = $reason; HowTo = $howTo; StepMessage = ('Optional. {0} {1}' -f $reason, $howTo).TrimEnd(); Deployed = $true; ConfirmOnly = $true }
    }
    if ($deployed) {
        # A Not selected record beside a deploy that passed (the workspace passed in, for example) changes nothing.
        $statuses = @($records | ForEach-Object { [string]$_.status } | Where-Object { $_ -ne 'Not selected' })
        $worst = if ($statuses.Count -gt 0) { Get-DemoWorstStatus -Status $statuses } else { 'Pass' }
        return [pscustomobject]@{ State = 'Done'; Status = $worst; Reason = 'It''s deployed and checked.'; HowTo = ''; StepMessage = 'Optional: deployed and checked.'; Deployed = $true }
    }
    # Not deployed, with nothing for a person to fix: skipped on purpose (a dry run, or a checkout without the app).
    $skipped = @($records | Where-Object { [string]$_.status -eq 'Not selected' -and [string]$_.checkId -in 'FABRIC.APP.DEPLOY', 'DEPLOY.FABRIC.APP' }) + @($records | Where-Object { [string]$_.status -eq 'Not selected' })
    $reason = if ($skipped.Count -gt 0) { 'It wasn''t added: {0}' -f ([string]$skipped[0].message).TrimEnd() } else { 'It wasn''t added.' }
    $howTo = 'To add it later, {0}.' -f $signIn
    return [pscustomobject]@{ State = 'Skipped'; Status = 'Not selected'; Reason = $reason; HowTo = $howTo; StepMessage = ('Optional. {0} {1}' -f $reason, $howTo); Deployed = $false }
}

function Test-DemoOptionalResult {
    # True for a result that never blocks DONE: the optional Insights app's (Test-DemoInsightsAppRecord), or the history
    # report's data check waiting for the Execute Queries setting (brief item 15). Internal.
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
    return ((Test-DemoInsightsAppRecord -Result $Result) -or ($id -like 'FABRIC.SEMANTICMODEL.*' -and [string]$Result.status -eq 'Manual action required'))
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
    - FABRIC.APP.BROWSER: the optional Insights app, confirmed once in the browser.
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
        & $add 'FABRIC.APP.BROWSER' 'FABRIC.APP.BROWSER' ('The optional Insights app is deployed; confirm it once in the browser. {0}' -f [string]$app.HowTo)
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
    with the failed checks; Manual action required with the items a person or a rerun acts on, each with its fix; and
    the confirm-only items (Get-DemoConfirmItem), each once, saying that none of them keeps the run from DONE. Every
    text is one plain line (ConvertTo-DemoPlainText). Pure. Internal.
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
    $actionable = @($manual | Where-Object { -not (Test-DemoConfirmOnlyResult -Result $_ -Context $all) -and -not (Test-DemoOptionalResult -Result $_) })
    $steps = @($actionable | ForEach-Object {
            $fix = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $_ -Name 'remediation')
            '{0}: {1}' -f [string]$_.checkId, $(if ($fix) { $fix } else { ConvertTo-DemoPlainText -Value $_.message })
        })
    $confirm = @(Get-DemoConfirmItem -Result $all | ForEach-Object { [string]$_['text'] })
    $confirmText = if ($confirm.Count -gt 0) { ' Please confirm (none of these keeps the run from DONE): {0}' -f ($confirm -join ' | ') } else { '' }
    $optional = @(Get-DemoOptionalItem -Result $all | ForEach-Object { [string]$_['name'] })
    $optionalText = if ($optional.Count -gt 0) { ' Optional, not needed for the demo: {0}.' -f ($optional -join ', ') } else { '' }
    $status = if ($failed.Count -gt 0) { 'Fail' } elseif ($manual.Count -gt 0) { 'Manual action required' } else { 'Pass' }
    $message = if ($failed.Count -gt 0) {
        '{0} check(s) failed.{1}' -f $failed.Count, $(if ($steps.Count -gt 0) { ' Also {0} item(s) need you: {1}' -f $steps.Count, ($steps -join ' | ') } else { '' })
    }
    elseif ($steps.Count -gt 0) {
        '{0} item(s) need you: {1}{2}' -f $steps.Count, ($steps -join ' | '), $confirmText
    }
    elseif ($manual.Count -gt 0) {
        '{0} Nothing else needs you for DONE.{1}{2}' -f $FinishedText, $confirmText, $optionalText
    }
    else {
        $FinishedText
    }
    return [pscustomobject]@{ Status = $status; Message = $message.Trim(); Evidence = ([ordered]@{ manual = $steps; confirm = $confirm; failed = @($failed | ForEach-Object { [string]$_.checkId }) }) }
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
    # Why T4 isn't deployed, or '' when it is (brief item 16): t4Enabled false in the configuration, or the Burstable
    # fallback (Phase 28) found no size Azure accepts. Decided from the effective configuration, as the deployment
    # decides (Resolve-DemoEffectiveConfig), so a t4SkuName the configuration sets wins over a recorded "no T4" (review
    # finding 5). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [System.Collections.IDictionary] $Config = @{},

        [AllowNull()]
        [object] $State
    )

    if (-not (Test-DemoT4Enabled -Config $Config)) {
        return 'T4 (Azure Database for PostgreSQL) isn''t deployed: t4Enabled is false in your configuration.'
    }
    if (-not (Test-DemoT4Enabled -Config (Resolve-DemoEffectiveConfig -Config $Config -State $State))) {
        return ('T4 (Azure Database for PostgreSQL) isn''t deployed: Azure refused both Burstable sizes, Standard_B1ms and Standard_B2s, in {0} (SkuNotAvailable). To add it, set t4SkuName to Standard_D2ds_v5 (General Purpose; DEPLOY.T4.SKU gives its price), then run ./scripts/deploy.ps1.' -f [string]$Config['location'])
    }
    return ''
}

function Get-DemoDoneRequirement {
    <#
    .SYNOPSIS
    The checks DONE needs to pass (brief item 16; the same list stops ADR 0018's clock): Database Hub's own views of
    every target. HUB.ESTATE.T1 to T4; TELEMETRY.T1, T2, and T3; METRICS.T4; T2.ARC.SQLINSTANCE (Standard with PAYG or
    Paid) and T2.ARC.MONITORING in PaygWizard and ProductKey modes; T1.SQLVM.ASSOCIATEDSERVICES (T1's inventory); and
    FABRIC.ITEMS.REQUIRED (the workspace, the lakehouse, the notebooks, the Real-Time Dashboard, and the history model and
    report). T4's are left out when T4 is off; Developer mode (opt-in) leaves out T2's performance telemetry and its
    PAYG and monitoring. The Insights app is never required (item 15). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [ValidateSet('PaygWizard', 'ProductKey', 'Developer')]
        [string] $InstallMode = 'PaygWizard',

        [switch] $T4Off,

        [switch] $SkipFabric
    )

    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($target in 'T1', 'T2', 'T3') {
        $ids.Add(('HUB.ESTATE.{0}' -f $target))
    }
    if (-not $T4Off) {
        $ids.Add('HUB.ESTATE.T4')
    }
    $ids.Add('TELEMETRY.T1')
    if ($InstallMode -ne 'Developer') {
        $ids.Add('TELEMETRY.T2')
    }
    $ids.Add('TELEMETRY.T3')
    if (-not $T4Off) {
        $ids.Add('METRICS.T4')
    }
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
    # missing one's latest result, or $null when it wasn't checked). Pure. Internal.
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
        if (@($items | Where-Object { [string]$_.status -eq 'Pass' }).Count -gt 0) {
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
    and the history model and report (Items - List Items). The Insights app isn't required. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $checkId = 'FABRIC.ITEMS.REQUIRED'
    $docUrl = 'https://learn.microsoft.com/rest/api/fabric/core/items/list-items'
    try {
        $token = Get-DemoFabricToken -SubscriptionId ([string]$Config['subscriptionId'])
        $resolution = Resolve-DemoFabricConfig -Config $Config -Token $token -Confirm:$false
        $settings = Get-DemoFabricAppSetting
        $fabric = $Config['fabric']
        $workspaceName = [string](Get-DemoMemberValue -InputObject $fabric -Name 'workspaceName')
        $lakehouseName = [string](Get-DemoMemberValue -InputObject $fabric -Name 'lakehouseName')
        if (-not $resolution.WorkspaceId) {
            return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('The Fabric workspace "{0}" isn''t there.' -f $workspaceName) -Remediation 'Run ./scripts/deploy.ps1 again: its Fabric track creates the workspace, the lakehouse, and the items.' -DocUrl $docUrl)
        }
        $missing = [System.Collections.Generic.List[string]]::new()
        if (-not $resolution.LakehouseId) {
            $missing.Add(('the lakehouse {0}' -f $(if ($lakehouseName) { $lakehouseName } else { 'LH_DatabaseHub' })))
        }
        $wanted = @(
            foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/notebooks') -Filter '*.ipynb' -File)) {
                @{ Name = $file.BaseName; Type = 'Notebook' }
            }
            @{ Name = [string]$settings['dashboardName']; Type = 'KQLDashboard' }
            @{ Name = [string]$settings['semanticModelName']; Type = 'SemanticModel' }
            @{ Name = [string]$settings['reportName']; Type = 'Report' }
        )
        foreach ($item in $wanted) {
            $found = Find-DemoFabricItem -WorkspaceId ([string]$resolution.WorkspaceId) -DisplayName $item.Name -Type $item.Type -Token $token
            if ($found.StatusCode -ne 200 -or @($found.Items).Count -eq 0) {
                $missing.Add($item.Name)
            }
        }
        $names = @(@($wanted | ForEach-Object { $_.Name }) + @($(if ($lakehouseName) { $lakehouseName } else { 'LH_DatabaseHub' })))
        if ($missing.Count -gt 0) {
            return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('The workspace "{0}" is missing: {1}.' -f $workspaceName, ($missing -join ', ')) -Evidence ([ordered]@{ missing = $missing.ToArray() }) -Remediation 'Run ./scripts/deploy.ps1 again: its Fabric track imports what''s missing (configure-fabric.ps1 and configure-powerbi.ps1).' -DocUrl $docUrl)
        }
        return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('The workspace "{0}" has the lakehouse, the notebooks, the Real-Time Dashboard, and the history model and report.' -f $workspaceName) -Evidence ([ordered]@{ items = $names }) -DocUrl $docUrl)
    }
    catch {
        return (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('The Fabric items couldn''t be checked: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/deploy.ps1 again once Fabric answers (a paused capacity answers nothing).' -DocUrl $docUrl)
    }
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
      running after the short grace, once; the status page says "Restarting T1's monitoring plugin, which stopped after a
      restart; no action needed."
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
    results don't already show passing, read-only, so a resumed run judges every target and not only the ones it
    worked on. Returns the new results. Internal.

    .DESCRIPTION
    The telemetry comes last (Invoke-DemoTelemetryCheck): when nothing else this gate checked failed, a target whose
    telemetry didn't come gets its monitoring checked, and its telemetry once more, before the run is judged (Phase 28
    live finding, 2026-10-30: T1's plugin had stopped after a restart, and the run ended NOT DONE on TELEMETRY.T1).
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
    $estate = @($missing | Where-Object { $_ -like 'HUB.ESTATE.*' } | ForEach-Object { $_.Substring(11) })
    if ($estate.Count -gt 0) {
        $results.AddRange([object[]]@(Test-DemoHubEstate -Config $Config -Target $estate))
    }
    $telemetry = @($missing | Where-Object { $_ -like 'TELEMETRY.*' } | ForEach-Object { $_.Substring(10) })
    if ('METRICS.T4' -in $missing) {
        $t4 = Get-DemoT4State -Config $Config
        $results.Add((Test-DemoT4MetricFlow -Config $Config -ServerId $t4.Names.ServerId -State $t4.State -WaitMinutes $TelemetryWaitMinutes))
    }
    $arc = @(@(if ('T2.ARC.SQLINSTANCE' -in $missing) { 'SqlInstance' }) + @(if ('T2.ARC.MONITORING' -in $missing) { 'Monitoring' }))
    if ($arc.Count -gt 0) {
        $results.AddRange([object[]]@(Get-DemoArcCheck -Config $Config -Check $arc))
    }
    if ('T1.SQLVM.ASSOCIATEDSERVICES' -in $missing) {
        $results.Add((Test-DemoSqlVmAssociatedService -Config $Config -WaitMinutes 10 -ListedStatus 'Fail'))
    }
    if ('FABRIC.ITEMS.REQUIRED' -in $missing) {
        $results.Add((Test-DemoFabricRequiredItem -Config $Config))
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

function Get-DemoDeploymentOutcome {
    <#
    .SYNOPSIS
    The one ending of a deploy.ps1 run (brief item 1): Kind Done, NotDone, or WhatIf, with Reason, Next (the single next
    action), NextCommand (the exact command), Notes (what DONE states plainly: T4 off and why, Developer mode's T2),
    Optional (items that never block DONE), Unfinished (tracks that didn't finish), Missing (DONE requirements without a
    Pass), and ExitCode: 0 when DONE, 1 when NOT DONE with a Fail, 2 when NOT DONE otherwise; -WhatIfRun is 0 unless a
    check failed. Pure. Internal.

    .DESCRIPTION
    DONE (brief item 16) needs every track this configuration has (T1, T2, T4 unless it's off, and Fabric unless
    -SkipFabric) finished according to the resource group's state; a Pass for every DONE requirement
    (Get-DemoDoneRequirement: Database Hub's own views of every target); no Fail; and no Manual action required except
    what only a person can confirm, which a rerun can't resolve (Test-DemoConfirmOnlyResult: the Hub tenant setting
    that couldn't be read, from either check, decided by its evidence, a capacity SKU, presenters' roles, the app's
    browser check; Phase 28 live finding, 2026-10-30), and the optional parts (Test-DemoOptionalResult). Confirm, on every
    outcome, lists the confirm-only items once each (Get-DemoConfirmItem), which DONE's banner shows under "Please
    confirm". Without a state, this run's DEPLOY.TRACK results stand in. -Sequential (deploy.ps1
    -Sequential, which records stages and no tracks) needs the recorded stage Validation instead of the tracks (or,
    without a state, this run's DEPLOY.STAGE.VALIDATION Pass), and the same DONE requirements, which its validation
    checks (review finding 4). -Stopped (Ctrl+C) is NOT DONE with the resume command, and -GuidedStopOpen adds what the
    open guided stop leaves until then (Phase 28 live finding). DONE also never comes while the state records what a
    guided stop or session left open (Get-DemoGuidedStopLeftover: the guided stop's Bastion, a handed-over host password
    that isn't rotated): that's NOT DONE naming stop-demo.ps1 -RemoveBastionOnly (Phase 28 review). A NOT DONE's reason
    names only what blocks DONE, and its next step is that item's own fix (a requirement's latest result included),
    never a plain rerun for something a rerun can't change.
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

        [switch] $GuidedStopOpen,

        # What this run started or created (Get-DemoStartedVm): a NOT DONE or stopped run names it, since it bills until
        # a stop (Phase 28).
        [AllowEmptyCollection()]
        [string[]] $StartedVm = @()
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $billing = Get-DemoBillingNote -Config $Config -Name $StartedVm -Command $Command
    $core = @($all | Where-Object { -not (Test-DemoOptionalResult -Result $_) })
    $fails = @($core | Where-Object { [string]$_.status -eq 'Fail' -and [string]$_.checkId -ne 'DEPLOY.SUMMARY' })
    # Only what a person or a rerun can act on blocks DONE; what only a person can confirm is listed instead.
    $manual = @($core | Where-Object { [string]$_.status -eq 'Manual action required' -and [string]$_.checkId -ne 'DEPLOY.SUMMARY' -and -not (Test-DemoConfirmOnlyResult -Result $_ -Context $all) })
    $optional = @(Get-DemoOptionalItem -Result $all)
    $confirm = @(Get-DemoConfirmItem -Result $all)
    $resume = 'If this window closes or the PC restarts, run ./scripts/deploy.ps1 again; it continues where it stopped.'
    $installMode = if ($Config.Contains('t2SqlInstallMode') -and $Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'PaygWizard' }
    $t4Off = Get-DemoT4OffReason -Config $Config -State $State
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($t4Off) {
        $notes.Add($t4Off)
    }
    if ($installMode -eq 'Developer') {
        $notes.Add('T2 runs SQL Server Developer edition (t2SqlInstallMode Developer, which you chose): it''s in Database Hub''s Estate, but T2 has no performance data or Database Agent findings. ProductKey or PaygWizard mode gives them.')
    }
    $outcome = [ordered]@{ Kind = 'NotDone'; Done = $false; Reason = ''; Next = ''; NextCommand = $Command; Notes = $notes.ToArray(); Optional = $optional; Confirm = $confirm; Unfinished = @(); Missing = @(); ExitCode = 2; Resume = $resume }
    if ($WhatIfRun) {
        $outcome.Kind = 'WhatIf'
        $outcome.ExitCode = if ($fails.Count -gt 0) { 1 } else { 0 }
        $outcome.Reason = if ($fails.Count -gt 0) { ('What if: {0} check(s) failed, so a deployment would stop at preflight: {1}.' -f $fails.Count, (($fails | Select-Object -First 3 | ForEach-Object { $_.checkId }) -join ', ')) } else { 'What if: the checks and the template''s what-if ran; nothing was deployed.' }
        $outcome.Next = 'Run ./scripts/deploy.ps1 without -WhatIf to deploy.'
        return [pscustomobject]$outcome
    }
    if ($Stopped) {
        # Ctrl+C (Phase 28 live finding): whatever it had reached, a stopped run isn't DONE, and nothing is lost.
        $outcome.Reason = 'You stopped deploy.ps1 (Ctrl+C) before it finished. What it finished is kept, and the resource group''s state records where it stopped.'
        $outcome.Next = 'Run {0} again when you''re ready: it continues where it stopped.' -f $Command
        if ($GuidedStopOpen) {
            $outcome.Next += ' It stopped at the guided stop: on-demand Bastion stays up, and the host password from the guided stop stays valid, until the next run cleans them up when it gets to T2, whether or not setup finished meanwhile (it isn''t DONE before), or ./scripts/stop-demo.ps1 does. Stopping for the day? Run ./scripts/stop-demo.ps1 now.'
        }
        if ($billing) {
            $outcome.Notes = @($outcome.Notes) + @($billing)
        }
        return [pscustomobject]$outcome
    }
    # What a guided stop or session left open (Phase 28 review): DONE never comes with it.
    $leftover = Get-DemoGuidedStopLeftover -State $State
    $stopCommand = Get-DemoStopDemoCommand -Command $Command
    $leftoverNext = 'Run {0}: it removes Bastion and rotates the host password, and leaves the VMs running. Then run {1} again.' -f $stopCommand, $Command
    $expected = [ordered]@{ T1 = 'Telemetry'; T2 = 'Telemetry' }
    if (-not $t4Off) {
        $expected['T4'] = 'Telemetry'
    }
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
    $evidence = Test-DemoDoneEvidence -Result $core -Requirement (Get-DemoDoneRequirement -InstallMode $installMode -T4Off:([bool]$t4Off) -SkipFabric:$SkipFabric)
    $outcome.Missing = @($evidence.Missing)
    if ($fails.Count -eq 0 -and $manual.Count -eq 0 -and $unfinished.Count -eq 0 -and $evidence.Complete -and -not $StopAfter -and -not $leftover) {
        $outcome.Kind = 'Done'
        $outcome.Done = $true
        $outcome.ExitCode = 0
        $outcome.NextCommand = ''
        $targets = if ($t4Off) { 'T1, T2, and T3' } else { 'T1, T2, T3, and T4' }
        $performance = if ($installMode -eq 'Developer') { 'performance telemetry from T1 and T3' } else { 'performance telemetry from T1, T2, and T3' }
        $metrics = if ($t4Off) { '' } else { ' and T4''s Azure Monitor metrics' }
        $t2 = if ($installMode -eq 'Developer') { '' } else { ' T2 runs SQL Server Standard with pay-as-you-go (or your license) and monitoring on.' }
        $fabricText = if ($SkipFabric) { ' Fabric was skipped (-SkipFabric).' } else { ' Fabric has the workspace, the lakehouse, the notebooks, the Real-Time Dashboard, and the history report.' }
        $outcome.Reason = 'Database Hub shows every target: {0} in Estate, with {1}{2}.{3}{4}' -f $targets, $performance, $metrics, $t2, $fabricText
        return [pscustomobject]$outcome
    }
    $leftoverShown = $false
    $blocking = @($fails) + @($manual) | Select-Object -First 1
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
        else {
            $fix = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $blocking -Name 'remediation')
            $outcome.Next = if ($fix) { $fix } else { 'Fix the cause in the message above.' }
            if ($outcome.Next -notmatch 'deploy\.ps1') {
                $outcome.Next = '{0} Then run {1}.' -f $outcome.Next.TrimEnd(), $Command
            }
        }
    }
    elseif ($StopAfter) {
        $outcome.Reason = 'Stopped after {0}, as asked (-StopAfter).' -f $StopAfter
        $outcome.Next = 'Run {0} to continue.' -f $Command
    }
    elseif ($unfinished.Count -gt 0 -and $Sequential) {
        $outcome.Reason = 'Not every stage finished: the last one recorded is {0}.' -f $(if ($lastStage) { $lastStage } else { 'none' })
        $outcome.Next = 'Run {0}: it continues after the last stage that finished, with the guided stop that -Sequential doesn''t have.' -f $Command
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
        $outcome.Next = if ($fix) {
            if ($fix -match 'deploy\.ps1') { $fix } else { '{0} Then run {1}.' -f $fix.TrimEnd(), $Command }
        }
        else {
            'Telemetry and estate entries can take a few more minutes after a deployment. Wait about 10 minutes, then run {0}: it checks again.' -f $Command
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
    switch ($Outcome.Kind) {
        'Done' {
            foreach ($line in (Get-DemoBannerLine -Title 'DONE')) { $lines.Add($line) }
            $lines.Add(('The demo is complete. {0}{1}' -f $Outcome.Reason, $(if ($Minutes -gt 0) { ' This run took {0} minutes.' -f $Minutes } else { '' })))
            foreach ($note in @($notes)) {
                if ($note) { $lines.Add([string]$note) }
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
            foreach ($item in @($Outcome.Optional)) {
                $lines.Add(('Optional, not needed for the demo: {0}. {1} {2}' -f $item['name'], $item['message'], $item['howTo']))
            }
            $lines.Add('Each session: ./scripts/start-demo.ps1, then ./scripts/stop-demo.ps1 -SaveHistory.')
            $lines.Add('Capture a golden snapshot with ./scripts/capture-t2-golden.ps1 to make future redeploys skip the build and the guided stop.')
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
            foreach ($item in @($Outcome.Optional)) {
                $lines.Add(('Optional, not needed for the demo: {0}. {1} {2}' -f $item['name'], $item['message'], $item['howTo']))
            }
        }
    }
    return $lines.ToArray()
}
