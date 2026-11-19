function Resolve-DemoFabricAppOperator {
    <#
    .SYNOPSIS
    Resolves who may send the Insights app's Manage actions: the deployer and the users in the demo's admin group
    (t3AdminGroupObjectId), for the app's Manage function (FABRIC.APP.OPERATORS, ADR 0027).

    .DESCRIPTION
    The coordinator's decision for the user (2026-11-18): operators are the deployer plus the members of the demo's
    admin group, which deploy.ps1 already uses for T1 to T3. Every deploy resolves them again, so a redeploy refreshes
    the list. Read through Microsoft Graph with the deployer's delegated rights, through Invoke-DemoRestRequest (a token
    verified for the configured tenant):
    - the deployer: GET /me (id, userPrincipalName, mail);
    - the group's users: GET /groups/{id}/members/microsoft.graph.user (id, userPrincipalName, mail), every page. Its
      other members, such as T1's managed identity, aren't people, so they're left out.

    Returns one FABRIC.APP.OPERATORS result whose evidence has the operators (objectIds, and names: their UPNs and mail
    addresses, lowercased), never a token:
    - Pass: the deployer and the group's users.
    - Warning: the group's members couldn't be read, so the deployer only, with the reason and the fix.
    - Fail: not even the deployer could be read; Manage then stays read-only for everyone in the app.

    Sources (checked 2026-11-18):
    - Get the signed-in user: https://learn.microsoft.com/graph/api/user-get
    - List group members, cast to users: https://learn.microsoft.com/graph/api/group-list-members

    .PARAMETER Config
    The demo's configuration: subscriptionId (the guard) and t3AdminGroupObjectId.

    .EXAMPLE
    Resolve-DemoFabricAppOperator -Config $config
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $graph = 'https://graph.microsoft.com/v1.0'
    $docUrl = 'https://learn.microsoft.com/graph/api/group-list-members'
    $subscriptionId = [string]$Config['subscriptionId']
    $groupId = [string]$Config['t3AdminGroupObjectId']
    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $operators = [System.Collections.Generic.List[object]]::new()
    $read = {
        param([string] $Uri)
        $answer = Invoke-DemoRestRequest -SubscriptionId $subscriptionId -Method 'GET' -Uri $Uri
        if ($answer.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$answer.StdOut)) {
            return [pscustomobject]@{ Ok = $false; Body = $null; Error = [string]$answer.StdErr }
        }
        return [pscustomobject]@{ Ok = $true; Body = ([string]$answer.StdOut | ConvertFrom-Json -Depth 8); Error = '' }
    }
    $add = {
        param($User, [string] $Source)
        $id = ([string](Get-DemoMemberValue -InputObject $User -Name 'id')).ToLowerInvariant()
        if ($id -notmatch $guid -or @($operators | Where-Object { $_['objectId'] -eq $id }).Count -gt 0) {
            return
        }
        $names = @(@((Get-DemoMemberValue -InputObject $User -Name 'userPrincipalName'), (Get-DemoMemberValue -InputObject $User -Name 'mail')) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
        $operators.Add([ordered]@{ objectId = $id; names = $names; source = $Source })
    }

    $me = & $read ('{0}/me?$select=id,userPrincipalName,mail' -f $graph)
    if (-not $me.Ok) {
        return New-DemoResult -CheckId 'FABRIC.APP.OPERATORS' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('Microsoft Graph didn''t say who you are ({0}), so the app has no operators, and Manage is read-only for everyone.' -f (Protect-DemoText -Text $me.Error)) -Evidence ([ordered]@{ operators = @() }) -Remediation 'Sign in with az login as the configured azureAccount, then run ./scripts/deploy.ps1 again.' -DocUrl 'https://learn.microsoft.com/graph/api/user-get'
    }
    & $add $me.Body 'deployer'

    $problem = ''
    if ($groupId -notmatch $guid) {
        $problem = 't3AdminGroupObjectId isn''t a group''s object ID'
    }
    else {
        $uri = '{0}/groups/{1}/members/microsoft.graph.user?$select=id,userPrincipalName,mail&$top=100' -f $graph, $groupId.ToLowerInvariant()
        for ($page = 0; $uri -and $page -lt 20; $page++) {
            $members = & $read $uri
            if (-not $members.Ok) {
                $problem = Protect-DemoText -Text $members.Error
                break
            }
            # Assigned first: Get-DemoMemberValue returns the array as one object, which @(...) would nest.
            $users = Get-DemoMemberValue -InputObject $members.Body -Name 'value'
            foreach ($user in @($users)) {
                & $add $user 'adminGroup'
            }
            $uri = [string](Get-DemoMemberValue -InputObject $members.Body -Name '@odata.nextLink')
        }
    }

    $evidence = [ordered]@{ operators = @($operators); adminGroupObjectId = $groupId.ToLowerInvariant() }
    if ($problem) {
        return New-DemoResult -CheckId 'FABRIC.APP.OPERATORS' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('The admin group''s members couldn''t be read ({0}), so the app''s Manage actions are yours only.' -f $problem) -Evidence $evidence -Remediation 'Reading a group''s members needs the right to read the group, for example as one of its owners (P6). Then run ./scripts/deploy.ps1 again; every deploy refreshes the list.' -DocUrl $docUrl
    }
    $others = $operators.Count - 1
    return New-DemoResult -CheckId 'FABRIC.APP.OPERATORS' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('The app''s Manage actions are for you and {0} other {1} of the demo''s admin group; every deploy refreshes the list.' -f $others, $(if ($others -eq 1) { 'member' } else { 'members' })) -Evidence $evidence -DocUrl $docUrl
}
