# The Fabric workspaces each environment uses (2026-11-17, the coordinator's decision: destroy.ps1 never deletes what
# another environment might use). deploy.ps1 records them on its demo resource group, warns when another environment
# records the same ones, and destroy.ps1 deletes a workspace only when no other environment records it or might use it.
# Since 2026-11-19 a new environment never takes another's: init.ps1 gives it a workspace of its own
# (Resolve-DemoFabricWorkspaceClaim), and deploy.ps1 stops before it creates anything in one that another environment
# records (Get-DemoFabricSharedResult).

function Get-DemoFabricWorkspaceClaim {
    <#
    .SYNOPSIS
    The other demo environments that Azure Resource Graph lists across every subscription the caller can read, with the
    Fabric workspaces each records, in one read-only query. Returns Ok, Error, Others: each other demo resource
    group's Name, SubscriptionId, Label, Tagged (it records the workspace it uses), and Claims (the workspace IDs it
    records, lowercase), and Own: this environment's own group (Found, FabricWorkspaceId, Claims, and UsedFabric: an
    earlier run finished a Fabric step, by DbHubTrackFabric or DbHubDeployStage; 2026-11-19). Internal.

    .DESCRIPTION
    A demo environment is a resource group with the deploymentId tag (the template's) or the DbHubDeployStage tag
    (deploy.ps1's state). The golden group and the session control's groups carry the solution tag too, but neither of
    those, so they aren't counted; neither is this environment's own group, which is Own. The query is its own canary: it
    must list the configured subscription, because Resource Graph leaves out what the caller can't read, so an answer
    without it could mean "can't read" rather than "nothing else". Ok is $false when the query fails, its answer is cut
    short, or the canary is missing.
    Sources: https://learn.microsoft.com/azure/governance/resource-graph/concepts/query-language#query-scope and
    https://learn.microsoft.com/rest/api/azureresourcegraph/resourcegraph/resources/resources (checked 2026-11-17).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $ownGroup = Get-DemoResourceGroupName -Config $Config
    $names = Get-DemoDeploymentStateTagName
    $own = [pscustomobject]@{ Found = $false; FabricWorkspaceId = ''; Claims = @(); UsedFabric = $false }
    $answer = [ordered]@{ Ok = $false; Error = ''; Others = @(); Own = $own }
    # contains is case-insensitive, and a tag's name keeps the case it was written with.
    $query = "resourcecontainers | where (type =~ 'microsoft.resources/subscriptions' and subscriptionId =~ '{0}') or (type =~ 'microsoft.resources/subscriptions/resourcegroups' and (tostring(tags) contains 'deploymentId' or tostring(tags) contains '{1}')) | project id, name, type, subscriptionId, tags" -f $subscriptionId, $names['Stage']
    try {
        $read = Invoke-DemoHubResourceGraph -SubscriptionId $subscriptionId -Query $query -AllSubscriptions
    }
    catch {
        $answer.Error = (Protect-DemoText -Text $_.Exception.Message).Trim()
        return [pscustomobject]$answer
    }
    if (-not $read.Succeeded) {
        $answer.Error = [string]$read.Error
        return [pscustomobject]$answer
    }
    if ($read.Truncated) {
        $answer.Error = 'Resource Graph''s answer was cut short'
        return [pscustomobject]$answer
    }
    $canary = $false
    $others = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($read.Rows)) {
        $rowSubscription = [string](Get-DemoMemberValue -InputObject $row -Name 'subscriptionId')
        if ([string](Get-DemoMemberValue -InputObject $row -Name 'type') -ieq 'microsoft.resources/subscriptions') {
            if ($rowSubscription -ieq $subscriptionId) {
                $canary = $true
            }
            continue
        }
        $name = [string](Get-DemoMemberValue -InputObject $row -Name 'name')
        $tags = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $rowTags = Get-DemoMemberValue -InputObject $row -Name 'tags'
        if ($rowTags -is [System.Collections.IDictionary]) {
            foreach ($key in $rowTags.Keys) {
                $tags[[string]$key] = [string]$rowTags[$key]
            }
        }
        elseif ($null -ne $rowTags) {
            foreach ($property in $rowTags.PSObject.Properties) {
                $tags[$property.Name] = [string]$property.Value
            }
        }
        if (-not ($tags.ContainsKey('deploymentId') -or $tags.ContainsKey($names['Stage']))) {
            continue
        }
        $claims = @(foreach ($key in $names['FabricWorkspaceId'], $names['ControlWorkspaceId']) {
                if ($tags.ContainsKey($key) -and $tags[$key].Trim() -match $script:GuidPattern) {
                    $tags[$key].Trim().ToLowerInvariant()
                }
            })
        $tagged = $tags.ContainsKey($names['FabricWorkspaceId']) -and $tags[$names['FabricWorkspaceId']].Trim() -match $script:GuidPattern
        if ($rowSubscription -ieq $subscriptionId -and $name -ieq $ownGroup) {
            # This environment's own group (2026-11-19): what it records, and whether an earlier run finished a Fabric step,
            # which an environment deployed before 2026-11-17 did without recording its workspace.
            $stage = if ($tags.ContainsKey($names['Stage'])) { $tags[$names['Stage']].Trim() } else { '' }
            $own = [pscustomobject]@{
                Found             = $true
                FabricWorkspaceId = $(if ($tagged) { $tags[$names['FabricWorkspaceId']].Trim().ToLowerInvariant() } else { '' })
                Claims            = @($claims | Select-Object -Unique)
                UsedFabric        = ($tags.ContainsKey($names['TrackFabric']) -and [bool]$tags[$names['TrackFabric']].Trim()) -or (Test-DemoDeploymentStageReached -Recorded $stage -Stage 'Fabric')
            }
            continue
        }
        $label = if ($rowSubscription -ieq $subscriptionId) { $name } else { '{0} (subscription {1})' -f $name, $rowSubscription }
        $others.Add([pscustomobject]@{ Name = $name; SubscriptionId = $rowSubscription; Label = $label; Tagged = $tagged; Claims = @($claims | Select-Object -Unique) })
    }
    if (-not $canary) {
        $answer.Error = ('Resource Graph didn''t list the subscription {0}, so its answer can''t show what else uses the workspace' -f $subscriptionId)
        return [pscustomobject]$answer
    }
    $answer.Ok = $true
    $answer.Others = $others.ToArray()
    $answer.Own = $own
    return [pscustomobject]$answer
}

function Get-DemoFabricWorkspaceGuard {
    <#
    .SYNOPSIS
    Whether destroy.ps1 may delete a Fabric workspace that its own checks found to be this environment's: only when
    Resource Graph answered (Get-DemoFabricWorkspaceClaim), no other demo environment records it (DbHubFabricWorkspaceId
    or DbHubControlWorkspaceId), and none was deployed by a version that doesn't record its workspaces, so might use it.
    Returns Free, Guard ('' when free, Unreadable, Claimed, or Untagged), ClaimedBy and Untagged (the other environments'
    labels), Reason, and Remediation. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Claim,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $WorkspaceId
    )

    $remove = 'delete it in Fabric once nothing uses it (Workspace settings > Remove this workspace)'
    $answer = [ordered]@{ Free = $false; Guard = ''; ClaimedBy = @(); Untagged = @(); Reason = ''; Remediation = '' }
    if (-not [bool]$Claim.Ok) {
        $answer.Guard = 'Unreadable'
        $answer.Reason = ('Azure Resource Graph couldn''t be read, so destroy.ps1 can''t tell whether another environment uses it ({0})' -f ([string]$Claim.Error).TrimEnd('.'))
        $answer.Remediation = ('Run ./scripts/destroy.ps1 again when Azure Resource Graph answers; or {0}.' -f $remove)
        return [pscustomobject]$answer
    }
    $id = $WorkspaceId.Trim().ToLowerInvariant()
    $join = { param([string[]] $Items) if ($Items.Count -le 2) { $Items -join ' and ' } else { '{0}, and {1}' -f ($Items[0..($Items.Count - 2)] -join ', '), $Items[-1] } }
    $answer.ClaimedBy = @(@($Claim.Others) | Where-Object { $id -and $id -in @($_.Claims) } | ForEach-Object { [string]$_.Label })
    $answer.Untagged = @(@($Claim.Others) | Where-Object { -not [bool]$_.Tagged } | ForEach-Object { [string]$_.Label })
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($answer.ClaimedBy.Count -gt 0) {
        $answer.Guard = 'Claimed'
        $reasons.Add(('{0} {1} it as {2}' -f (& $join $answer.ClaimedBy), $(if ($answer.ClaimedBy.Count -eq 1) { 'records' } else { 'record' }), $(if ($answer.ClaimedBy.Count -eq 1) { 'its own' } else { 'theirs' })))
        $answer.Remediation = ('Run ./scripts/destroy.ps1 again once {0} {1} destroyed, or {2}. To keep environments apart, give each its own fabric.workspaceName and control.fabricWorkspaceName.' -f (& $join $answer.ClaimedBy), $(if ($answer.ClaimedBy.Count -eq 1) { 'is' } else { 'are' }), $remove)
    }
    if ($answer.Untagged.Count -gt 0) {
        if (-not $answer.Guard) {
            $answer.Guard = 'Untagged'
            $answer.Remediation = ('Run ./scripts/destroy.ps1 again after the next ./scripts/deploy.ps1 of {0}, which records the workspaces {1}, or after {2} destroy; or {3}.' -f (& $join $answer.Untagged), $(if ($answer.Untagged.Count -eq 1) { 'it uses' } else { 'each uses' }), $(if ($answer.Untagged.Count -eq 1) { 'its' } else { 'their' }), $remove)
        }
        $reasons.Add(('{0} {1} deployed by an earlier version of the demo, which doesn''t record the workspaces it uses, so {2} might use it' -f (& $join $answer.Untagged), $(if ($answer.Untagged.Count -eq 1) { 'was' } else { 'were' }), $(if ($answer.Untagged.Count -eq 1) { 'it' } else { 'they' })))
    }
    if ($reasons.Count -eq 0) {
        $answer.Free = $true
        return [pscustomobject]$answer
    }
    $answer.Reason = $reasons -join '; '
    return [pscustomobject]$answer
}

function Invoke-DemoFabricOwnershipStep {
    <#
    .SYNOPSIS
    deploy.ps1 records the Fabric workspaces this environment uses on its demo resource group (DbHubFabricWorkspaceId,
    DbHubControlWorkspaceId), on every run that puts the control notebook in Fabric, and checks that no other
    environment records the same ones. Returns DEPLOY.FABRIC.SHARED, or nothing when no workspace was resolved. Never a
    Fail. Internal.

    .DESCRIPTION
    The IDs come from CONTROL.FABRIC.NOTEBOOK's evidence (Set-DemoActivityControlFabric): the demo's workspace, and the
    one the control notebook is in (its own workspace, or the demo's when it's in a folder there). DEPLOY.FABRIC.SHARED
    is Pass when they're recorded and no other environment records them; a Warning that names the other environment
    when one does, because each deploy.ps1 then puts its own notebooks in the same workspace, and destroy.ps1 keeps a
    workspace another environment records; a Warning when the record or the check couldn't be done.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $doc = 'https://learn.microsoft.com/azure/governance/resource-graph/concepts/query-language#query-scope'
    $notebook = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq 'CONTROL.FABRIC.NOTEBOOK' }) | Select-Object -Last 1
    $evidence = if ($null -ne $notebook) { Get-DemoMemberValue -InputObject $notebook -Name 'evidence' } else { $null }
    $demoId = ([string](Get-DemoMemberValue -InputObject $evidence -Name 'demoWorkspaceId')).Trim().ToLowerInvariant()
    $controlId = ([string](Get-DemoMemberValue -InputObject $evidence -Name 'workspaceId')).Trim().ToLowerInvariant()
    $record = [ordered]@{}
    if ($demoId -match $script:GuidPattern) {
        $record['FabricWorkspaceId'] = $demoId
    }
    if ($controlId -match $script:GuidPattern) {
        $record['ControlWorkspaceId'] = $controlId
    }
    if ($record.Count -eq 0) {
        return
    }
    $group = Get-DemoResourceGroupName -Config $Config
    $demoName = [string](Get-DemoFabricResolveSetting -Config $Config).WorkspaceName
    $controlName = [string](Get-DemoActivityControlName -Config $Config).FabricWorkspace
    $label = [ordered]@{}
    if ($record.Contains('FabricWorkspaceId')) {
        $label[$record['FabricWorkspaceId']] = 'the workspace "{0}"' -f $demoName
    }
    if ($record.Contains('ControlWorkspaceId') -and -not $label.Contains($record['ControlWorkspaceId'])) {
        $label[$record['ControlWorkspaceId']] = 'the workspace "{0}"' -f $controlName
    }
    $outEvidence = [ordered]@{ resourceGroup = $group; fabricWorkspaceId = [string]$record['FabricWorkspaceId']; controlWorkspaceId = [string]$record['ControlWorkspaceId']; sharedWith = @() }
    $problems = [System.Collections.Generic.List[string]]::new()
    $fixes = [System.Collections.Generic.List[string]]::new()
    try {
        Set-DemoDeploymentState -Config $Config -Value $record -Confirm:$false
    }
    catch {
        $problems.Add(('The Fabric workspaces this environment uses couldn''t be recorded on {0} ({1}), so destroy.ps1 in another environment keeps them until a later deploy.ps1 records them.' -f $group, (Protect-DemoText -Text $_.Exception.Message).Trim().TrimEnd('.')))
        $fixes.Add('Run ./scripts/deploy.ps1 again.')
    }
    $claim = Get-DemoFabricWorkspaceClaim -Config $Config
    if (-not [bool]$claim.Ok) {
        $problems.Add(('Whether another environment uses the same Fabric workspaces couldn''t be checked: {0}.' -f ([string]$claim.Error).TrimEnd('.')))
        if ($fixes.Count -eq 0) {
            $fixes.Add('Nothing to do now: deploy.ps1 checks again on its next run, and destroy.ps1 keeps a workspace it can''t check.')
        }
    }
    else {
        $shared = [System.Collections.Generic.List[string]]::new()
        foreach ($other in @($claim.Others)) {
            $hits = @(@($other.Claims) | Where-Object { $label.Contains($_) } | ForEach-Object { $label[$_] } | Select-Object -Unique)
            if ($hits.Count -gt 0) {
                $shared.Add(('{0} records {1}' -f $other.Label, ($hits -join ' and ')))
            }
        }
        if ($shared.Count -gt 0) {
            $outEvidence['sharedWith'] = $shared.ToArray()
            $problems.Add(('Another environment uses the same Fabric workspace as this one: {0}. Each deploy.ps1 then puts its own notebooks there, over the other''s, and destroy.ps1 keeps a workspace that another environment records.' -f ($shared -join '; ')))
            $fixes.Insert(0, 'Give each environment its own fabric.workspaceName and control.fabricWorkspaceName in its configuration, then run ./scripts/deploy.ps1 for it.')
        }
    }
    if ($problems.Count -gt 0) {
        return (New-DemoResult -CheckId 'DEPLOY.FABRIC.SHARED' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ($problems -join ' ') -Evidence $outEvidence -Remediation ($fixes -join ' ') -DocUrl $doc)
    }
    $what = (@($label.Values | Select-Object -Unique) -join ' and ')
    return (New-DemoResult -CheckId 'DEPLOY.FABRIC.SHARED' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('Recorded the Fabric workspaces this environment uses on {0} ({1}), and no other environment records them.' -f $group, $what) -Evidence $outEvidence -DocUrl $doc)
}

function Get-DemoFabricWorkspaceNameCandidate {
    <#
    .SYNOPSIS
    The names an environment's own Fabric workspace can have (2026-11-19): "<name> <prefix>", which a first run gives
    every prefix but the default, then "<name> <prefix> 2" to "<name> <prefix> 9", without -Except (Fabric compares
    names ignoring case). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Prefix,

        [string] $DefaultName = 'Database Hub Demo',

        [AllowEmptyString()]
        [string] $Except = ''
    )

    $base = '{0} {1}' -f $DefaultName, $Prefix
    $names = @($base) + @(foreach ($number in 2..9) { '{0} {1}' -f $base, $number })
    return @($names | Where-Object { -not [string]::Equals($_, $Except, [System.StringComparison]::OrdinalIgnoreCase) })
}

function Resolve-DemoFabricWorkspaceClaim {
    <#
    .SYNOPSIS
    init.ps1's answer for a Fabric workspace that exists, when another demo environment may record it (2026-11-19): the
    workspace the configuration gets, and what INIT.FABRIC.WORKSPACE says. Pure. Internal.

    .DESCRIPTION
    -Workspace is what List Workspaces returned, and -Claim Get-DemoFabricWorkspaceClaim's answer. When the one workspace
    named -WorkspaceName is one that another demo environment records (DbHubFabricWorkspaceId or DbHubControlWorkspaceId):
    - This environment records it too (-OwnId), or -Origin recovered and it records none (deployed before 2026-11-17,
      when environments began recording their workspaces, so it may be its own): kept, a Warning that the environments
      share it, with how to move.
    - -Origin option (init.ps1 -WorkspaceName): kept, Manual action required that names the environment that records it,
      with the fix, another -WorkspaceName.
    - Otherwise, a default name: the environment's own, the first of Get-DemoFabricWorkspaceNameCandidate that no other
      environment records (one that doesn't exist yet, or one that exists and nobody else records), a Warning that says
      so; Manual action required when none is.
    Resource Graph that couldn't answer is a Warning that says so, never a silent Pass. A workspace that nobody else
    records, that doesn't exist yet (deploy.ps1 creates it), or whose name more than one has: Status '', nothing to add.
    Returns WorkspaceName, Renamed, From, Status ('', Warning, or Manual action required), Note (the sentence the result
    adds, or its whole message for Manual action required), Remediation, and ClaimedBy (the other environments' labels).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceName,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Workspace = @(),

        [AllowNull()]
        [pscustomobject] $Claim = $null,

        [ValidateSet('default', 'option', 'recovered')]
        [string] $Origin = 'default',

        [AllowEmptyCollection()]
        [string[]] $OwnId = @(),

        [Parameter(Mandatory)]
        [string] $Prefix,

        [string] $DefaultName = 'Database Hub Demo',

        [AllowEmptyString()]
        [string] $ResourceGroup = ''
    )

    $answer = [ordered]@{ WorkspaceName = $WorkspaceName; Renamed = $false; From = ''; Status = ''; Note = ''; Remediation = ''; ClaimedBy = @() }
    $items = @($Workspace | Where-Object { $null -ne $_ })
    $found = @(Select-DemoFabricNamed -Items $items -Name $WorkspaceName)
    if ($found.Count -ne 1) {
        return [pscustomobject]$answer
    }
    $fix = 'init.ps1 -Force -Prefix {0} -WorkspaceName <a name no other environment uses>' -f $Prefix
    if ($null -eq $Claim -or -not [bool](Get-DemoMemberValue -InputObject $Claim -Name 'Ok')) {
        $why = if ($null -ne $Claim) { ([string](Get-DemoMemberValue -InputObject $Claim -Name 'Error')).Trim().TrimEnd('.') } else { '' }
        $answer.Status = 'Warning'
        $answer.Note = 'Whether another demo environment records it couldn''t be checked{0}, so it may be another environment''s.' -f $(if ($why) { ' ({0})' -f $why } else { '' })
        $answer.Remediation = 'If it''s another environment''s, run {0}. deploy.ps1 checks again before it creates anything (DEPLOY.FABRIC.SHARED).' -f $fix
        return [pscustomobject]$answer
    }
    # Assign before wrapping: Get-DemoMemberValue returns an array as one object.
    $others = Get-DemoMemberValue -InputObject $Claim -Name 'Others'
    $idOf = { param([object] $Item) ([string](Get-DemoMemberValue -InputObject $Item -Name 'id')).Trim().ToLowerInvariant() }
    $claimedBy = { param([string] $Id) @(@($others) | Where-Object { $null -ne $_ -and $Id -and $Id -in @($_.Claims) } | ForEach-Object { [string]$_.Label }) }
    $by = @(& $claimedBy (& $idOf $found[0]))
    if ($by.Count -eq 0) {
        return [pscustomobject]$answer
    }
    $answer.ClaimedBy = $by
    $byText = Join-DemoActivityList -Item $by
    $one = $by.Count -eq 1
    $recordsPhrase = '{0} {1}' -f $byText, $(if ($one) { 'records as its own' } else { 'record as theirs' })
    # This environment's own name: the first that doesn't exist yet, or that exists and no other environment records.
    $free = ''
    foreach ($candidate in @(Get-DemoFabricWorkspaceNameCandidate -Prefix $Prefix -DefaultName $DefaultName -Except $WorkspaceName)) {
        $hits = @(Select-DemoFabricNamed -Items $items -Name $candidate)
        if ($hits.Count -eq 0 -or ($hits.Count -eq 1 -and @(& $claimedBy (& $idOf $hits[0])).Count -eq 0)) {
            $free = $candidate
            break
        }
    }
    $example = if ($free) { ', for example "{0}"' -f $free } else { '' }
    $ownIds = @($OwnId | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    $group = if ($ResourceGroup) { $ResourceGroup } else { 'This environment' }
    $move = 'To give this environment a workspace of its own, set fabric.workspaceName in its configuration to a name no other environment uses{0}, then run ./scripts/deploy.ps1: it creates that workspace with the demo''s items and records it, and "{1}" stays as it is for {2}.' -f $example, $WorkspaceName, $byText
    if ((& $idOf $found[0]) -in $ownIds) {
        $answer.Status = 'Warning'
        $answer.Note = '{0} records it as its own, and so {1} {2}: the environments share it, and each deploy.ps1 puts its own notebooks there, over the other''s. The configuration keeps it, as deployed.' -f $group, $(if ($one) { 'does' } else { 'do' }), $byText
        $answer.Remediation = $move
        return [pscustomobject]$answer
    }
    if ($Origin -eq 'recovered' -and $ownIds.Count -eq 0) {
        $answer.Status = 'Warning'
        $answer.Note = '{0} records no Fabric workspace (it was deployed before 2026-11-17), and this is the one {1}, so the environments may share it: each deploy.ps1 puts its own notebooks there, over the other''s. The configuration keeps it, as deployed.' -f $group, $recordsPhrase
        $answer.Remediation = $move
        return [pscustomobject]$answer
    }
    if ($Origin -eq 'option') {
        $answer.Status = 'Manual action required'
        $answer.Note = 'The Fabric workspace "{0}" (-WorkspaceName) is the one {1}, so init.ps1 doesn''t give it to this environment: deploy.ps1 would put this environment''s lakehouse, history model, report, notebooks, and Insights app there, over the other environment''s, so it stops before it creates anything (DEPLOY.FABRIC.SHARED).' -f $WorkspaceName, $recordsPhrase
        $answer.Remediation = 'Run {0}{1}.' -f $fix, $example
        return [pscustomobject]$answer
    }
    if (-not $free) {
        $tried = @(Get-DemoFabricWorkspaceNameCandidate -Prefix $Prefix -DefaultName $DefaultName -Except $WorkspaceName)
        $answer.Status = 'Manual action required'
        $answer.Note = 'The Fabric workspace "{0}", the name this environment would have had, is the one {1}, and none of the names init.ps1 tries instead ("{2}" to "{3}") is free, so it gives this environment none of them.' -f $WorkspaceName, $recordsPhrase, $tried[0], $tried[-1]
        $answer.Remediation = 'Run {0}.' -f $fix
        return [pscustomobject]$answer
    }
    $answer.WorkspaceName = $free
    $answer.Renamed = $true
    $answer.From = $WorkspaceName
    $answer.Status = 'Warning'
    $answer.Note = 'It''s this environment''s own: "{0}", the name it would have had, is the workspace {1}, so init.ps1 doesn''t give it to this environment.' -f $WorkspaceName, $recordsPhrase
    $answer.Remediation = 'Nothing to do. To choose another name, run {0}.' -f $fix
    return [pscustomobject]$answer
}

function Get-DemoFabricSharedResult {
    <#
    .SYNOPSIS
    deploy.ps1's check before it creates anything (2026-11-19): DEPLOY.FABRIC.SHARED is a Fail when the Fabric workspace
    fabric.workspaceName names is one that another demo environment records and this one doesn't, so a second
    environment never puts its items in another environment's workspace. Returns the result, or nothing when the
    workspace is nobody else's, or doesn't exist yet. Internal.

    .DESCRIPTION
    Preflight passes the ID that P5 found by name (Test-DemoFabricResolution); a run without preflight (a resume) passes
    -Resolve, and the workspace is looked up by name, read-only (Resolve-DemoFabricConfig without -Create). One Azure
    Resource Graph query (Get-DemoFabricWorkspaceClaim) says which demo environments record it, in
    DbHubFabricWorkspaceId or DbHubControlWorkspaceId, and what this one records:
    - Another environment does, and this one records another workspace, or none and never finished a Fabric step (a new
      environment, or a configuration edited by hand): Fail, with the fix, a fabric.workspaceName of its own (edit it,
      or init.ps1 -Force -Prefix <prefix> -WorkspaceName).
    - Another environment does, and this one records it too, or records none but finished a Fabric step before (it was
      deployed before 2026-11-17, when environments began recording their workspaces): a Warning, never a Fail, so its
      update goes on as before; the remediation says how to move to a workspace of its own.
    - Resource Graph can't answer: a Warning; the run goes on, and the control step checks again when it records the
      workspaces (Invoke-DemoFabricOwnershipStep).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $WorkspaceId = '',

        [switch] $Resolve
    )

    $doc = 'https://learn.microsoft.com/azure/governance/resource-graph/concepts/query-language#query-scope'
    $name = [string](Get-DemoFabricResolveSetting -Config $Config).WorkspaceName
    $id = $WorkspaceId.Trim().ToLowerInvariant()
    if ($Resolve -and $id -notmatch $script:GuidPattern) {
        try {
            $access = Get-DemoHubFabricAccess -SubscriptionId ([string]$Config['subscriptionId'])
            if ($null -ne $access.Token) {
                $resolution = Resolve-DemoFabricConfig -Config $Config -Token $access.Token -SkipLakehouse
                $id = ([string]$resolution.WorkspaceId).Trim().ToLowerInvariant()
            }
        }
        catch {
            Write-DemoLog -Level Debug -Message ('The Fabric workspace "{0}" couldn''t be looked up for DEPLOY.FABRIC.SHARED: {1}' -f $name, (Protect-DemoText -Text $_.Exception.Message))
        }
    }
    if ($id -notmatch $script:GuidPattern) {
        # It doesn't exist yet (deploy.ps1 creates it), or Fabric couldn't say: nothing another environment can record.
        return
    }
    $group = Get-DemoResourceGroupName -Config $Config
    $prefix = if ([string]$Config['prefix']) { [string]$Config['prefix'] } else { 'dbhub' }
    $suggestion = @(Get-DemoFabricWorkspaceNameCandidate -Prefix $prefix -Except $name)[0]
    $evidence = [ordered]@{ workspaceName = $name; workspaceId = $id; resourceGroup = $group; claimedBy = @(); outcome = '' }
    $result = { param([string] $Status, [string] $Message, [string] $Remediation) New-DemoResult -CheckId 'DEPLOY.FABRIC.SHARED' -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $doc }
    try {
        $claim = Get-DemoFabricWorkspaceClaim -Config $Config
    }
    catch {
        $claim = [pscustomobject]@{ Ok = $false; Error = (Protect-DemoText -Text $_.Exception.Message).Trim(); Others = @() }
    }
    if (-not [bool]$claim.Ok) {
        $evidence['outcome'] = 'unreadable'
        return (& $result 'Warning' ('Whether another demo environment records the Fabric workspace "{0}" couldn''t be checked before anything is created: {1}. deploy.ps1 goes on with it, and checks again at its end, when it records the workspaces this environment uses.' -f $name, ([string]$claim.Error).Trim().TrimEnd('.')) ('Nothing to do if "{0}" is this environment''s. If it''s another environment''s, set fabric.workspaceName in this environment''s configuration to a name no other environment uses, for example "{1}", and run ./scripts/deploy.ps1 again.' -f $name, $suggestion))
    }
    $by = @(@($claim.Others) | Where-Object { $null -ne $_ -and $id -in @($_.Claims) } | ForEach-Object { [string]$_.Label })
    if ($by.Count -eq 0) {
        return
    }
    $evidence['claimedBy'] = $by
    $byText = Join-DemoActivityList -Item $by
    $one = $by.Count -eq 1
    $recordsPhrase = '{0} {1}' -f $byText, $(if ($one) { 'records as its own' } else { 'record as theirs' })
    $own = Get-DemoMemberValue -InputObject $claim -Name 'Own'
    # Assign before wrapping: Get-DemoMemberValue returns an array as one object.
    $ownClaims = Get-DemoMemberValue -InputObject $own -Name 'Claims'
    $ownWorkspace = [string](Get-DemoMemberValue -InputObject $own -Name 'FabricWorkspaceId')
    $usedFabric = [bool](Get-DemoMemberValue -InputObject $own -Name 'UsedFabric')
    $move = 'To move this environment to a workspace of its own, set fabric.workspaceName in its configuration to a name no other environment uses, for example "{0}", and run ./scripts/deploy.ps1: it creates that workspace with the demo''s items and records it, and "{1}" stays as it is for {2}.' -f $suggestion, $name, $byText
    if ($id -in @($ownClaims)) {
        $evidence['outcome'] = 'shared'
        return (& $result 'Warning' ('The Fabric workspace "{0}" is this environment''s ({1} records it), and {2} {3} it too, so the environments share it: each deploy.ps1 puts its own notebooks there, over the other''s. This run goes on with it, as before.' -f $name, $group, $byText, $(if ($one) { 'records' } else { 'record' })) $move)
    }
    if (-not $ownWorkspace -and $usedFabric) {
        $evidence['outcome'] = 'unrecorded'
        return (& $result 'Warning' ('The Fabric workspace "{0}" is the one {1}, and this environment ({2}) records none: it was deployed before 2026-11-17, when environments began recording their workspaces, and it used Fabric then. So the environments may share it: each deploy.ps1 puts its own notebooks there, over the other''s. This run goes on with it, as before, and records it at its end.' -f $name, $recordsPhrase, $group) $move)
    }
    $evidence['outcome'] = 'claimed'
    return (& $result 'Fail' ('The Fabric workspace "{0}" (fabric.workspaceName) is the one {1}, not this environment''s ({2}), so deploy.ps1 stops before it creates anything: it would put this environment''s lakehouse, history model, report, notebooks, and Insights app there, over the other environment''s.' -f $name, $recordsPhrase, $group) ('Give this environment its own workspace: set fabric.workspaceName in its configuration to a name no other environment uses, for example "{0}", or run ./scripts/init.ps1 -Force -Prefix {1} -WorkspaceName "{0}"; then run ./scripts/deploy.ps1 again.' -f $suggestion, $prefix))
}
