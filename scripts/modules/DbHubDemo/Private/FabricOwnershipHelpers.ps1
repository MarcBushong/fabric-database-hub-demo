# The Fabric workspaces each environment uses (2026-11-17, the coordinator's decision: destroy.ps1 never deletes what
# another environment might use). deploy.ps1 records them on its demo resource group, warns when another environment
# records the same ones, and destroy.ps1 deletes a workspace only when no other environment records it or might use it.

function Get-DemoFabricWorkspaceClaim {
    <#
    .SYNOPSIS
    The other demo environments that Azure Resource Graph lists across every subscription the caller can read, with the
    Fabric workspaces each records, in one read-only query. Returns Ok, Error, and Others: each other demo resource
    group's Name, SubscriptionId, Label, Tagged (it records the workspace it uses), and Claims (the workspace IDs it
    records, lowercase). Internal.

    .DESCRIPTION
    A demo environment is a resource group with the deploymentId tag (the template's) or the DbHubDeployStage tag
    (deploy.ps1's state). The golden group and the session control's groups carry the solution tag too, but neither of
    those, so they aren't counted; neither is this environment's own group. The query is its own canary: it must list
    the configured subscription, because Resource Graph leaves out what the caller can't read, so an answer without it
    could mean "can't read" rather than "nothing else". Ok is $false when the query fails, its answer is cut short, or
    the canary is missing.
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
    $answer = [ordered]@{ Ok = $false; Error = ''; Others = @() }
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
        if ($rowSubscription -ieq $subscriptionId -and $name -ieq $ownGroup) {
            continue
        }
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
        $label = if ($rowSubscription -ieq $subscriptionId) { $name } else { '{0} (subscription {1})' -f $name, $rowSubscription }
        $others.Add([pscustomobject]@{ Name = $name; SubscriptionId = $rowSubscription; Label = $label; Tagged = $tagged; Claims = @($claims | Select-Object -Unique) })
    }
    if (-not $canary) {
        $answer.Error = ('Resource Graph didn''t list the subscription {0}, so its answer can''t show what else uses the workspace' -f $subscriptionId)
        return [pscustomobject]$answer
    }
    $answer.Ok = $true
    $answer.Others = $others.ToArray()
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
