# What an earlier run of the same deployment found, which a resumed run's ending still shows (F10, 2026-11-19). A plain
# deploy.ps1 after NOT DONE resumes past the steps that made these results (the Fabric track's Insights app and Ask,
# preflight's Hub tenant setting, the Fabric stage's presenters' check), so its DONE and its status page lost what only a
# person can confirm and the Insights app's state. Each run's ending saves them for its environment in the Git-ignored out
# folder (deploy-carry-<resource group>.json), and the next run of the same deployment (the same subscription, resource
# group, and deploymentId) shows them again, unless it checked them itself: a fresh result always wins, group by group.
# Carried results are listed, never judged: they never change whether a run is DONE, its exit code, or its results file.
# Not in GitHub Actions, for a what-if, or for a run stopped with Ctrl+C, whose ending reads no state.

function Get-DemoCarryGroup {
    <#
    .SYNOPSIS
    The group a result belongs to for the next run's ending (F10), or '' for a result that isn't carried. A group is
    carried, or replaced by this run's results, whole: InsightsApp (the Insights app's records, Test-DemoInsightsAppRecord),
    Ask (ASK.*), SemanticModel (FABRIC.SEMANTICMODEL.*), HubSetting (the Hub tenant setting, from either check), Presenter
    (HUB.PRESENTER.*), Capacity (FABRIC.P5.CAPACITY), AgentT3 (HUB.AGENT.T3), and any other result only a person can
    confirm (Test-DemoConfirmOnlyResult), by its check ID. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Result
    )

    $id = [string](Get-DemoMemberValue -InputObject $Result -Name 'checkId')
    if (-not $id) {
        return ''
    }
    if (Test-DemoInsightsAppRecord -Result $Result) {
        return 'InsightsApp'
    }
    if ($id -like 'ASK.*') {
        return 'Ask'
    }
    if ($id -like 'FABRIC.SEMANTICMODEL.*') {
        return 'SemanticModel'
    }
    if ($id -in 'PREFLIGHT.P4.HUBSETTING', 'FABRIC.P4.HUBSETTING') {
        return 'HubSetting'
    }
    if ($id -like 'HUB.PRESENTER.*') {
        return 'Presenter'
    }
    if ($id -eq 'FABRIC.P5.CAPACITY') {
        return 'Capacity'
    }
    if ($id -eq 'HUB.AGENT.T3') {
        return 'AgentT3'
    }
    if (Test-DemoConfirmOnlyResult -Result $Result) {
        return $id
    }
    return ''
}

function Get-DemoCarryGroupName {
    # How DONE's note names a carried group (Get-DemoCarryGroup). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Group
    )

    switch ($Group) {
        'InsightsApp' { return 'the Insights app' }
        'Ask' { return 'the Copilot chat in the Insights app (Ask)' }
        'SemanticModel' { return 'the history report''s data check' }
        'HubSetting' { return 'the Database Hub tenant setting' }
        'Presenter' { return 'the presenters'' access' }
        'Capacity' { return 'the Fabric capacity''s SKU' }
        'AgentT3' { return 'Database Agents on T3' }
        default { return $Group }
    }
}

function Get-DemoCarryPath {
    # The file of one environment's carried results: <out>/deploy-carry-<resource group>.json, the name in lower case, with
    # any character but a letter, a digit, a period, an underscore, or a hyphen as an underscore. '' without a directory or
    # a resource group. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Directory,

        [AllowEmptyString()]
        [string] $ResourceGroup
    )

    if (-not $Directory -or -not $ResourceGroup) {
        return ''
    }
    return (Join-Path -Path $Directory -ChildPath ('deploy-carry-{0}.json' -f ($ResourceGroup.ToLowerInvariant() -replace '[^a-z0-9._-]', '_')))
}

function ConvertTo-DemoCarryUtc {
    # A stored time as UTC: an ISO 8601 string, or the DateTime that ConvertFrom-Json makes of one. $null for anything
    # else. Pure. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Local) {
            return $Value.ToUniversalTime()
        }
        return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
    }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ($Value -is [string] -and $Value -and [datetime]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Read-DemoCarriedResult {
    <#
    .SYNOPSIS
    What an earlier run of this deployment saved for the next one (Save-DemoCarriedResult; F10, 2026-11-19): Items, the
    stored items (key, runUtc, and result), and SavedUtc, when they were saved. Only from a file that names the same
    subscription and resource group (in any case) and the same deploymentId; no items otherwise: no file, a file that
    doesn't parse, or another deployment's, which the run's own save then replaces. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $Path,

        [AllowEmptyString()]
        [string] $SubscriptionId,

        [AllowEmptyString()]
        [string] $ResourceGroup,

        [AllowEmptyString()]
        [string] $DeploymentId
    )

    $none = [pscustomobject]@{ Items = @(); SavedUtc = $null }
    if (-not $Path -or -not $DeploymentId -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $none
    }
    try {
        $store = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The results an earlier run saved couldn''t be read ({0}): {1}' -f $Path, (Protect-DemoText -Text $_.Exception.Message))
        return $none
    }
    if ($store -isnot [System.Collections.IDictionary]) {
        return $none
    }
    $same = [string]::Equals([string]$store['subscriptionId'], $SubscriptionId, [System.StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$store['resourceGroup'], $ResourceGroup, [System.StringComparison]::OrdinalIgnoreCase) -and [string]$store['deploymentId'] -ceq $DeploymentId
    if (-not $same) {
        return $none
    }
    return [pscustomobject]@{ Items = @(@($store['items']) | Where-Object { $_ -is [System.Collections.IDictionary] }); SavedUtc = (ConvertTo-DemoCarryUtc -Value $store['savedUtc']) }
}

function Select-DemoCarriedResult {
    <#
    .SYNOPSIS
    Of the stored items (Read-DemoCarriedResult), what this run's ending shows and what it keeps for the next run (F10,
    2026-11-19). A stored group that this run has a result of, or a stored result whose check ID this run reported, is
    this run's now: a fresh result always wins. Kept is every other stored item, as stored. Shown is each kept item as a
    result again (New-DemoResult, so it's validated and redacted again), with its stored timestamp and evidence
    carriedFromUtc, except, with -SkipFabric, the Fabric items' groups (InsightsApp, Ask, SemanticModel, Capacity), which
    stay kept for a later run. Groups names the shown groups in order, and RunUtc is the latest run they came from. An
    item that isn't a valid result is dropped. Pure; never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Item = @(),

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [switch] $SkipFabric
    )

    $freshGroups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $freshIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Result | Where-Object { $null -ne $_ })) {
        $group = Get-DemoCarryGroup -Result $entry
        if ($group) {
            $null = $freshGroups.Add($group)
        }
        $id = [string](Get-DemoMemberValue -InputObject $entry -Name 'checkId')
        if ($id) {
            $null = $freshIds.Add($id)
        }
    }
    $kept = [System.Collections.Generic.List[object]]::new()
    $shown = [System.Collections.Generic.List[object]]::new()
    $groups = [System.Collections.Generic.List[string]]::new()
    $latest = $null
    foreach ($entry in @($Item | Where-Object { $_ -is [System.Collections.IDictionary] })) {
        $key = [string]$entry['key']
        $stored = $entry['result']
        if (-not $key -or $stored -isnot [System.Collections.IDictionary]) {
            continue
        }
        $id = [string]$stored['checkId']
        $runUtc = ConvertTo-DemoCarryUtc -Value $entry['runUtc']
        if ($null -eq $runUtc -or $freshGroups.Contains($key) -or ($id -and $freshIds.Contains($id))) {
            continue
        }
        $stamp = $runUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        try {
            $evidence = [ordered]@{}
            if ($stored['evidence'] -is [System.Collections.IDictionary]) {
                foreach ($name in @($stored['evidence'].Keys)) {
                    $evidence[[string]$name] = $stored['evidence'][$name]
                }
            }
            $evidence['carriedFromUtc'] = $stamp
            $again = New-DemoResult -CheckId $id -Area ([string]$stored['area']) -Target ([string]$stored['target']) -Status ([string]$stored['status']) -Message ([string]$stored['message']) -Evidence $evidence -Remediation ([string]$stored['remediation']) -DocUrl ([string]$stored['docUrl']) -EvaluationOnly:([bool]$stored['evaluationOnly'])
        }
        catch {
            continue
        }
        $made = ConvertTo-DemoCarryUtc -Value $stored['timestamp']
        if ($null -ne $made) {
            $again.timestamp = $made.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $kept.Add([ordered]@{ key = $key; runUtc = $stamp; result = $stored })
        if ($SkipFabric -and $key -in 'InsightsApp', 'Ask', 'SemanticModel', 'Capacity') {
            continue
        }
        $shown.Add($again)
        if (-not $groups.Contains($key)) {
            $groups.Add($key)
        }
        if ($null -eq $latest -or $runUtc -gt $latest) {
            $latest = $runUtc
        }
    }
    return [pscustomobject]@{ Shown = $shown.ToArray(); Kept = $kept.ToArray(); Groups = $groups.ToArray(); RunUtc = $latest }
}

function Save-DemoCarriedResult {
    <#
    .SYNOPSIS
    Saves what the next run of this deployment shows unless it checks it again (F10, 2026-11-19): this run's results of
    every carry group (Get-DemoCarryGroup), as of -RunUtc, and the stored items no fresh result replaced (-Kept, from
    Select-DemoCarriedResult), with the subscription, the resource group, and the deploymentId that a later read must
    match. Redacted (Protect-DemoText), written under a temporary name first and then renamed. Never throws: a failure is
    a Warning in the log. Internal.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Path,

        [AllowEmptyString()]
        [string] $SubscriptionId,

        [AllowEmptyString()]
        [string] $ResourceGroup,

        [AllowEmptyString()]
        [string] $DeploymentId,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [Parameter(Mandatory)]
        [datetime] $RunUtc,

        [AllowEmptyCollection()]
        [object[]] $Kept = @()
    )

    if (-not $Path -or -not $DeploymentId) {
        return
    }
    $temp = ''
    try {
        $stamp = (ConvertTo-DemoCarryUtc -Value $RunUtc).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($Result | Where-Object { $null -ne $_ })) {
            $group = Get-DemoCarryGroup -Result $entry
            if (-not $group) {
                continue
            }
            $evidence = Get-DemoMemberValue -InputObject $entry -Name 'evidence'
            $record = [ordered]@{}
            foreach ($name in 'checkId', 'area', 'target', 'status', 'message', 'remediation', 'docUrl', 'timestamp') {
                $record[$name] = [string](Get-DemoMemberValue -InputObject $entry -Name $name)
            }
            $record['evidence'] = if ($null -ne $evidence) { $evidence } else { @{} }
            $record['evaluationOnly'] = [bool](Get-DemoMemberValue -InputObject $entry -Name 'evaluationOnly')
            $items.Add([ordered]@{ key = $group; runUtc = $stamp; result = $record })
        }
        foreach ($entry in @($Kept | Where-Object { $_ -is [System.Collections.IDictionary] })) {
            $items.Add($entry)
        }
        $store = [ordered]@{
            version        = 1
            subscriptionId = $SubscriptionId
            resourceGroup  = $ResourceGroup
            deploymentId   = $DeploymentId
            savedUtc       = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            items          = $items.ToArray()
        }
        $json = Protect-DemoText -Text ($store | ConvertTo-Json -Depth 30)
        $directory = Split-Path -Path $Path -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        $temp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
        [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temp, $Path, $true)
        $temp = ''
    }
    catch {
        Write-DemoLog -Level Warning -Message ('What this run found couldn''t be saved for the next run ({0}): {1}' -f $Path, (Protect-DemoText -Text $_.Exception.Message))
    }
    finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-DemoCarriedRunResult {
    <#
    .SYNOPSIS
    The carried results for one deploy.ps1 run's ending (F10, 2026-11-19): what an earlier run of this deployment saved
    (Read-DemoCarriedResult), less what this run checked again (Select-DemoCarriedResult). Returns Enabled, Path,
    SubscriptionId, ResourceGroup, DeploymentId, Shown, Kept, Groups, and RunUtc. Enabled is $false, with nothing read,
    for a what-if, a run stopped with Ctrl+C, a run in GitHub Actions, a run object without its out folder
    (Start-DemoDeploymentRun's OutputDirectory), or a state without the deployment's deploymentId. Never throws.
    Internal.

    .DESCRIPTION
    configure-fabric-app.ps1, run on its own since the save (its results file, out/configure-fabric-app.jsonl, is newer;
    deploy.ps1's own app step writes its results elsewhere), may have added or changed the Insights app and Ask, so their
    earlier state is neither shown nor kept: DONE says nothing about them rather than something stale. That run's own
    results aren't used: its file doesn't say which environment it was for.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Run,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [object] $State,

        [switch] $SkipFabric,

        [switch] $WhatIfRun,

        [switch] $Stopped
    )

    $off = [pscustomobject]@{ Enabled = $false; Path = ''; SubscriptionId = ''; ResourceGroup = ''; DeploymentId = ''; Shown = @(); Kept = @(); Groups = @(); RunUtc = $null }
    try {
        $environment = Get-DemoMemberValue -InputObject $Run -Name 'Environment'
        if ($WhatIfRun -or $Stopped -or [bool](Get-DemoMemberValue -InputObject $environment -Name 'GitHubActions')) {
            return $off
        }
        $tags = Get-DemoMemberValue -InputObject $State -Name 'Tags'
        $deploymentId = if ($tags -is [System.Collections.IDictionary] -and [string]$tags['deploymentId'] -match '^[a-z0-9]{6}$') { [string]$tags['deploymentId'] } else { '' }
        $resourceGroup = Get-DemoResourceGroupName -Config $Config
        $directory = [string](Get-DemoMemberValue -InputObject $Run -Name 'OutputDirectory')
        $path = Get-DemoCarryPath -Directory $directory -ResourceGroup $resourceGroup
        if (-not $path -or -not $deploymentId) {
            return $off
        }
        $subscription = [string]$Config['subscriptionId']
        $stored = Read-DemoCarriedResult -Path $path -SubscriptionId $subscription -ResourceGroup $resourceGroup -DeploymentId $deploymentId
        $items = @($stored.Items)
        $appRun = Join-Path -Path $directory -ChildPath 'configure-fabric-app.jsonl'
        if ($null -ne $stored.SavedUtc -and (Test-Path -LiteralPath $appRun -PathType Leaf) -and (Get-Item -LiteralPath $appRun).LastWriteTimeUtc -gt $stored.SavedUtc) {
            $items = @($items | Where-Object { [string]$_['key'] -notin 'InsightsApp', 'Ask' })
            Write-DemoLog -Level Debug -Message 'configure-fabric-app.ps1 ran since the last deploy.ps1 run, so the Insights app''s and Ask''s earlier state isn''t shown.'
        }
        $selected = Select-DemoCarriedResult -Item $items -Result @($Result) -SkipFabric:$SkipFabric
        return [pscustomobject]@{ Enabled = $true; Path = $path; SubscriptionId = $subscription; ResourceGroup = $resourceGroup; DeploymentId = $deploymentId; Shown = @($selected.Shown); Kept = @($selected.Kept); Groups = @($selected.Groups); RunUtc = $selected.RunUtc }
    }
    catch {
        Write-DemoLog -Level Warning -Message ('What an earlier run of this deployment found couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        return $off
    }
}

function Complete-DemoCarriedRunResult {
    <#
    .SYNOPSIS
    The carried results' part of one deploy.ps1 run's ending (F10, 2026-11-19), once the outcome is judged: saves this
    run's results of every carry group, with the stored ones no fresh result replaced, for the next run
    (Save-DemoCarriedResult); adds the outcome one note that names what it shows from an earlier run, and when; shows the
    Insights app's and Ask's earlier state on their status page rows when this run didn't run their step (the row says
    "Finished in an earlier run."); and returns DEPLOY.CARRIED (Pass), which lists the carried results, or $null when it
    showed none. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Carry,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [object] $Outcome,

        [AllowNull()]
        [object] $RunStartedUtc,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [AllowNull()]
        [System.Collections.IDictionary] $Model = $null
    )

    if (-not [bool]$Carry.Enabled) {
        return $null
    }
    try {
        $runUtc = ConvertTo-DemoCarryUtc -Value $RunStartedUtc
        if ($null -eq $runUtc) {
            $runUtc = [DateTime]::UtcNow
        }
        Save-DemoCarriedResult -Path ([string]$Carry.Path) -SubscriptionId ([string]$Carry.SubscriptionId) -ResourceGroup ([string]$Carry.ResourceGroup) -DeploymentId ([string]$Carry.DeploymentId) -Result @($Result) -RunUtc $runUtc -Kept @($Carry.Kept)
        $shown = @($Carry.Shown | Where-Object { $null -ne $_ })
        if ($shown.Count -eq 0) {
            return $null
        }
        $when = Get-DemoAutoStopClockText -Config $Config -Utc $Carry.RunUtc
        $kind = [string](Get-DemoMemberValue -InputObject $Outcome -Name 'Kind')
        # The note names what the ending shows from the earlier run: what's still open, and the Insights app on DONE, whose
        # reason names it.
        $named = @(foreach ($group in @($Carry.Groups)) {
                $open = @($shown | Where-Object { (Get-DemoCarryGroup -Result $_) -eq $group -and [string]$_.status -in 'Fail', 'Manual action required', 'Warning' }).Count -gt 0
                if ($open -or ($group -eq 'InsightsApp' -and $kind -eq 'Done')) {
                    Get-DemoCarryGroupName -Group $group
                }
            })
        if ($named.Count -gt 0 -and $null -ne $Outcome -and $null -ne $Outcome.PSObject.Properties['Notes']) {
            # Get-DemoMemberValue returns the notes array whole: assigned first, then each note is its own item.
            $notes = Get-DemoMemberValue -InputObject $Outcome -Name 'Notes'
            $Outcome.Notes = [string[]]@(@(@($notes) | Where-Object { $_ }) + @(('From the earlier run at {0}, since this run didn''t check them again: {1}.' -f $when, (Join-DemoActivityList -Item $named))))
        }
        if ($ProgressPath -and $null -ne $Model) {
            $rows = [ordered]@{
                'Fabric.App' = Get-DemoInsightsAppSummary -Result @($shown | Where-Object { (Get-DemoCarryGroup -Result $_) -eq 'InsightsApp' })
                'Fabric.Ask' = Get-DemoAskSummary -Result @($shown | Where-Object { (Get-DemoCarryGroup -Result $_) -eq 'Ask' })
            }
            foreach ($id in @($rows.Keys)) {
                $summary = $rows[$id]
                $step = Find-DemoProgressStep -Model $Model -Id $id
                if ($null -eq $summary -or $null -eq $step -or [string]$step['message'] -ne 'Finished in an earlier run.') {
                    continue
                }
                Set-DemoProgressStep -Path $ProgressPath -Id $id -State ([string]$summary.State) -Status ([string]$summary.Status) -Message ('From the earlier run at {0}: {1}' -f $when, [string]$summary.StepMessage) -MaxLength 1200
            }
        }
        $items = @(foreach ($item in $shown) {
                $from = ConvertTo-DemoCarryUtc -Value (Get-DemoMemberValue -InputObject $item.evidence -Name 'carriedFromUtc')
                [ordered]@{ checkId = [string]$item.checkId; status = [string]$item.status; runUtc = $(if ($null -ne $from) { $from.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }) }
            })
        $list = ($items | ForEach-Object { '{0} ({1})' -f $_['checkId'], $_['status'] }) -join ', '
        return (New-DemoResult -CheckId 'DEPLOY.CARRIED' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('The ending and the status page include {0} result(s) from the earlier run at {1}, which this run didn''t check again: {2}. A run that checks them again replaces them.' -f $items.Count, $when, $list) -Evidence ([ordered]@{ groups = @($Carry.Groups); items = $items }))
    }
    catch {
        Write-DemoLog -Level Warning -Message ('What an earlier run of this deployment found couldn''t be added to this run''s ending: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        return $null
    }
}
