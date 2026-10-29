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
    if ($ConfigPath -and [System.IO.Path]::GetFullPath($ConfigPath) -ne $default) {
        $full = [System.IO.Path]::GetFullPath($ConfigPath)
        $root = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd('\', '/')
        $shown = if ($full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { './' + ($full.Substring($root.Length + 1) -replace '\\', '/') } else { $ConfigPath }
        return ('./scripts/deploy.ps1 -ConfigPath "{0}"' -f $shown)
    }
    return './scripts/deploy.ps1'
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
    The optional parts that didn't finish and never block DONE (brief item 15): the Insights app (FABRIC.APP.*,
    DEPLOY.FABRIC.APP) and the history report's data check when the Execute Queries setting is off
    (FABRIC.SEMANTICMODEL.* Manual action required), each with how to add it later. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $open = @($Result | Where-Object { $null -ne $_ -and [string]$_.status -in 'Fail', 'Manual action required' })
    $app = @($open | Where-Object { [string]$_.checkId -like 'FABRIC.APP.*' -or [string]$_.checkId -eq 'DEPLOY.FABRIC.APP' })
    if ($app.Count -gt 0) {
        $onlyBrowser = @($app | Where-Object { [string]$_.checkId -ne 'FABRIC.APP.BROWSER' }).Count -eq 0
        if ($onlyBrowser) {
            $items.Add([ordered]@{ name = 'the Insights app'; message = 'It''s deployed; a person confirms it once in the browser.'; howTo = [string]$app[0].remediation })
        }
        else {
            $first = $app | Where-Object { [string]$_.checkId -ne 'FABRIC.APP.BROWSER' } | Select-Object -First 1
            $items.Add([ordered]@{
                    name    = 'the Insights app (Fabric Apps preview)'
                    message = ('It wasn''t added: {0}' -f [string]$first.message)
                    howTo   = 'To add it later: a Fabric administrator turns on the tenant settings Fabric Apps (preview) and Dataset Execute Queries REST API; then you run ./scripts/configure-fabric-app.ps1 -SignIn, which opens a browser for your own sign-in (an assistant can''t do that sign-in for you).'
                })
        }
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

function Test-DemoOptionalResult {
    # True for a result that never blocks DONE: the optional Insights app's, or the history report's data check waiting
    # for the Execute Queries setting (brief item 15). Internal.
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
    return ($id -like 'FABRIC.APP.*' -or $id -eq 'DEPLOY.FABRIC.APP' -or ($id -like 'FABRIC.SEMANTICMODEL.*' -and [string]$Result.status -eq 'Manual action required'))
}

function Get-DemoT4OffReason {
    # Why T4 isn't deployed, or '' when it is (brief item 16): t4Enabled false in the configuration, or the Burstable
    # fallback (Phase 28) found no size Azure accepts. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [System.Collections.IDictionary] $Config = @{},

        [AllowNull()]
        [object] $State
    )

    if ($Config.Contains('t4Enabled') -and $null -ne $Config['t4Enabled'] -and -not [bool]$Config['t4Enabled'] -and [string](Get-DemoMemberValue -InputObject $State -Name 'T4Sku') -ne 'None') {
        return 'T4 (Azure Database for PostgreSQL) isn''t deployed: t4Enabled is false in your configuration.'
    }
    if ([string](Get-DemoMemberValue -InputObject $State -Name 'T4Sku') -eq 'None') {
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

function Invoke-DemoDoneGate {
    <#
    .SYNOPSIS
    At the end of a run whose tracks all finished: runs each DONE requirement (Get-DemoDoneRequirement) that this run's
    results don't already show passing, read-only, so a resumed run judges every target and not only the ones it
    worked on. Returns the new results. Internal.
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
        [int] $TelemetryWaitMinutes = 15
    )

    $missing = @((Test-DemoDoneEvidence -Result $Result -Requirement $Requirement).Missing)
    if ($missing.Count -eq 0) {
        return @()
    }
    Write-DemoLog -Message ('Checking what DONE needs and this run didn''t show yet: {0}.' -f ($missing -join ', '))
    $results = [System.Collections.Generic.List[object]]::new()
    $estate = @($missing | Where-Object { $_ -like 'HUB.ESTATE.*' } | ForEach-Object { $_.Substring(11) })
    if ($estate.Count -gt 0) {
        $results.AddRange([object[]]@(Test-DemoHubEstate -Config $Config -Target $estate))
    }
    $telemetry = @($missing | Where-Object { $_ -like 'TELEMETRY.*' } | ForEach-Object { $_.Substring(10) })
    if ($telemetry.Count -gt 0) {
        $results.AddRange([object[]]@(Test-DemoHubTelemetry -Config $Config -Target $telemetry -WaitMinutes $TelemetryWaitMinutes))
    }
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
    the Hub tenant setting's reminder (PREFLIGHT.P4.HUBSETTING, which no API reads) and the optional parts
    (Test-DemoOptionalResult). Without a state, this run's DEPLOY.TRACK results stand in.
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

        [switch] $SkipFabric
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $core = @($all | Where-Object { -not (Test-DemoOptionalResult -Result $_) })
    $fails = @($core | Where-Object { [string]$_.status -eq 'Fail' -and [string]$_.checkId -ne 'DEPLOY.SUMMARY' })
    $manual = @($core | Where-Object { [string]$_.status -eq 'Manual action required' -and [string]$_.checkId -notin 'PREFLIGHT.P4.HUBSETTING', 'DEPLOY.SUMMARY' })
    $optional = @(Get-DemoOptionalItem -Result $all)
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
    $outcome = [ordered]@{ Kind = 'NotDone'; Done = $false; Reason = ''; Next = ''; NextCommand = $Command; Notes = $notes.ToArray(); Optional = $optional; Unfinished = @(); Missing = @(); ExitCode = 2; Resume = $resume }
    if ($WhatIfRun) {
        $outcome.Kind = 'WhatIf'
        $outcome.ExitCode = if ($fails.Count -gt 0) { 1 } else { 0 }
        $outcome.Reason = if ($fails.Count -gt 0) { ('What if: {0} check(s) failed, so a deployment would stop at preflight: {1}.' -f $fails.Count, (($fails | Select-Object -First 3 | ForEach-Object { $_.checkId }) -join ', ')) } else { 'What if: the checks and the template''s what-if ran; nothing was deployed.' }
        $outcome.Next = 'Run ./scripts/deploy.ps1 without -WhatIf to deploy.'
        return [pscustomobject]$outcome
    }
    $expected = [ordered]@{ T1 = 'Telemetry'; T2 = 'Telemetry' }
    if (-not $t4Off) {
        $expected['T4'] = 'Telemetry'
    }
    if (-not $SkipFabric) {
        $expected['Fabric'] = 'Fabric'
    }
    $unfinished = [System.Collections.Generic.List[string]]::new()
    foreach ($track in $expected.Keys) {
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
    if ($fails.Count -eq 0 -and $manual.Count -eq 0 -and $unfinished.Count -eq 0 -and $evidence.Complete -and -not $StopAfter) {
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
    $blocking = @($fails) + @($manual) | Select-Object -First 1
    if ($null -ne $blocking) {
        $message = [string]$blocking.message
        if ($message.Length -gt 400) {
            $message = $message.Substring(0, 397) + '...'
        }
        $outcome.Reason = '{0}: {1}' -f $blocking.checkId, $message
        $fix = [string]$blocking.remediation
        $outcome.Next = if ($fix) { $fix } else { 'Fix the cause in the message above.' }
        if ($outcome.Next -notmatch 'deploy\.ps1') {
            $outcome.Next = '{0} Then run {1}.' -f $outcome.Next.TrimEnd(), $Command
        }
    }
    elseif ($StopAfter) {
        $outcome.Reason = 'Stopped after {0}, as asked (-StopAfter).' -f $StopAfter
        $outcome.Next = 'Run {0} to continue.' -f $Command
    }
    elseif ($unfinished.Count -gt 0) {
        $outcome.Reason = 'Not every target finished: {0}.' -f ($unfinished -join ', ')
        $outcome.Next = 'Run {0}: it continues the unfinished track(s).' -f $Command
    }
    else {
        $first = $evidence.Missing[0]
        $outcome.Reason = if ($null -ne $evidence.Problem) { '{0} hasn''t passed yet ({1}): {2}' -f $first, $evidence.Problem.status, ([string]$evidence.Problem.message) } else { '{0} wasn''t checked yet. Database Hub must show it before the demo is done.' -f $first }
        $outcome.Next = 'Telemetry and estate entries can take a few more minutes after a deployment. Wait about 10 minutes, then run {0}: it checks again.' -f $Command
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
    switch ($Outcome.Kind) {
        'Done' {
            foreach ($line in (Get-DemoBannerLine -Title 'DONE')) { $lines.Add($line) }
            $lines.Add(('The demo is complete. {0}{1}' -f $Outcome.Reason, $(if ($Minutes -gt 0) { ' This run took {0} minutes.' -f $Minutes } else { '' })))
            foreach ($note in @(Get-DemoMemberValue -InputObject $Outcome -Name 'Notes')) {
                if ($note) { $lines.Add([string]$note) }
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
            foreach ($note in @(Get-DemoMemberValue -InputObject $Outcome -Name 'Notes')) {
                if ($note) { $lines.Add([string]$note) }
            }
            foreach ($item in @($Outcome.Optional)) {
                $lines.Add(('Optional, not needed for the demo: {0}. {1}' -f $item['name'], $item['howTo']))
            }
        }
    }
    return $lines.ToArray()
}
