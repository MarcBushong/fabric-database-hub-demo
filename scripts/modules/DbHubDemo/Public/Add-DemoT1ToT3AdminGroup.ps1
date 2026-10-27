function Add-DemoT1ToT3AdminGroup {
    <#
    .SYNOPSIS
    Adds T1's system-assigned managed identity to the P6 group, T3's Entra administrator (ADR 0008).

    .DESCRIPTION
    Idempotent. It reads T1's identity ('az vm show') unless -PrincipalId is given, checks the membership
    (Microsoft Graph checkMemberGroups), and adds it only when it's missing (Microsoft Graph's add member,
    POST /groups/{id}/members/$ref), with the caller's delegated rights as a group owner (prerequisite P6).
    Both go through Invoke-DemoRestRequest with a token verified for the configured tenant: 'az ad group
    member' calls Graph with the Azure CLI's default account, which can be in another tenant (live finding,
    2026-10-21). After adding, it waits until Microsoft Graph reports the membership, then waits
    -SettleSeconds more: managed identity tokens are cached for each resource for up to about 24 hours, so T1
    must not request an Azure SQL token before Microsoft Entra ID applies the membership. Run it before
    anything on T1 connects to T3.

    Returns one T3.ADMINGROUP result:
    - Pass: T1 is already a member, or was added and Microsoft Graph reports it.
    - Warning: T1 was added, but Microsoft Graph didn't report the membership within -WaitSeconds.
    - Manual action required: the caller can't add members (not a group owner, for example the GitHub
      identity in Actions), or the group doesn't exist. The remediation has the exact command for a group
      owner, and the fallback is the interactive T-SQL step (ADR 0007).
    - Fail: T1 or its identity doesn't exist, or Microsoft Graph returned an unexpected error.
    With -WhatIf, nothing is added and no result is returned.

    Sources (checked 2026-10-21):
    - checkMemberGroups: https://learn.microsoft.com/graph/api/directoryobject-checkmembergroups
    - Add members: https://learn.microsoft.com/graph/api/group-post-members
    - az ad group member (the command printed for a group owner): https://learn.microsoft.com/cli/azure/ad/group/member
    - Managed identity token caching: https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations

    .PARAMETER PrincipalId
    T1's managed identity object ID, for example the deployment output t1PrincipalId. Read from T1 when
    omitted.

    .PARAMETER WaitSeconds
    How long to wait for Microsoft Graph to report a new membership.

    .PARAMETER SettleSeconds
    Extra wait after a new membership is visible, before anything on T1 asks for a token.

    .EXAMPLE
    Add-DemoT1ToT3AdminGroup -Config $config -PrincipalId $outputs.t1PrincipalId.value
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $PrincipalId = '',

        [ValidateRange(0, 900)]
        [int] $WaitSeconds = 120,

        [ValidateRange(0, 600)]
        [int] $SettleSeconds = 60,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10
    )

    $subscriptionId = $Config['subscriptionId']
    $groupId = [string]$Config['t3AdminGroupObjectId']
    $resourceGroup = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $docUrl = 'https://learn.microsoft.com/graph/api/group-post-members'
    $graph = 'https://graph.microsoft.com/v1.0'

    function Get-GroupResult([string] $Status, [string] $Message, [hashtable] $Evidence = @{}, [string] $Remediation = '') {
        $Evidence['groupObjectId'] = $groupId
        New-DemoResult -CheckId 'T3.ADMINGROUP' -Area 't3' -Target 'T3' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl
    }

    function Test-Membership([string] $MemberId) {
        $body = @{ groupIds = @($groupId) } | ConvertTo-Json -Compress
        $check = Invoke-DemoRestRequest -SubscriptionId $subscriptionId -Method 'POST' -Uri ('{0}/directoryObjects/{1}/checkMemberGroups' -f $graph, $MemberId) -Body $body
        if ($check.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$check.StdOut)) {
            return $null
        }
        $groups = Get-DemoMemberValue -InputObject ([string]$check.StdOut | ConvertFrom-Json -Depth 8) -Name 'value'
        return (@($groups) -contains $groupId)
    }

    if (-not $PrincipalId) {
        $vm = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--name', 'sqlvm01', '--resource-group', $resourceGroup) -AsJson -AllowFailure
        $PrincipalId = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $vm -Name 'identity') -Name 'principalId')
        if (-not $PrincipalId) {
            $reason = if ($null -eq $vm) { "T1 (sqlvm01) wasn't found in $resourceGroup" } else { 'T1 (sqlvm01) has no system-assigned identity' }
            return Get-GroupResult 'Fail' ("{0}, so it can't join the T3 administrator group." -f $reason) -Remediation 'Deploy T1 (deploy.ps1 -Resume); the template gives it a system-assigned identity.'
        }
    }

    $command = "az ad group member add --group {0} --member-id {1} (az ad uses the Azure CLI's default account, so run it where that account is in tenant {2}, for example in Cloud Shell or under a separate AZURE_CONFIG_DIR, or add the member in the Microsoft Entra admin center)" -f $groupId, $PrincipalId, $Config['tenantId']
    $evidence = @{ principalId = $PrincipalId }
    if (Test-Membership -MemberId $PrincipalId) {
        return Get-GroupResult 'Pass' "T1's managed identity is already a member of the T3 administrator group (P6)." $evidence
    }
    if (-not $PSCmdlet.ShouldProcess("group $groupId", "Add T1's managed identity $PrincipalId")) {
        return
    }

    # A managed identity that was just created can take a moment to appear in Microsoft Graph, so a
    # not-found answer is retried before it's reported.
    $add = $null
    $reference = @{ '@odata.id' = ('{0}/directoryObjects/{1}' -f $graph, $PrincipalId) } | ConvertTo-Json -Compress
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $add = Invoke-DemoRestRequest -SubscriptionId $subscriptionId -Method 'POST' -Uri ('{0}/groups/{1}/members/$ref' -f $graph, $groupId) -Body $reference
        if ($add.ExitCode -eq 0 -or $attempt -eq 4 -or [string]$add.StdErr -notmatch '(?i)Request_ResourceNotFound|does not exist|not found') {
            break
        }
        Start-Sleep -Seconds ($PollSeconds * 2)
    }
    $addedAt = [System.DateTime]::UtcNow
    if ($add.ExitCode -ne 0) {
        $errorText = (Protect-DemoText -Text ([string]$add.StdErr)).Trim()
        if ($errorText -match '(?i)already exist') {
            return Get-GroupResult 'Pass' "T1's managed identity is already a member of the T3 administrator group (P6)." $evidence
        }
        $fallback = 'Otherwise, run the T3 T-SQL interactively as a member of the group (ADR 0007, ADR 0008).'
        if ($errorText -match '(?i)Insufficient privileges|Authorization_RequestDenied|Forbidden|\b403\b') {
            return Get-GroupResult 'Manual action required' "The caller can't add members to the T3 administrator group (P6): only its owners can." $evidence ("Ask an owner of group $groupId to run: $command. $fallback")
        }
        if ($errorText -match '(?i)Request_ResourceNotFound|does not exist|not found') {
            return Get-GroupResult 'Manual action required' ("The T3 administrator group {0} or T1's identity wasn't found in Microsoft Entra ID (prerequisite P6)." -f $groupId) $evidence ("Create a security group you own, set t3AdminGroupObjectId, and run: $command. $fallback")
        }
        $short = if ($errorText.Length -gt 300) { $errorText.Substring(0, 300) + '...' } else { $errorText }
        return Get-GroupResult 'Fail' ("Adding T1's managed identity to the T3 administrator group failed: {0}" -f $short) $evidence ("Run: $command. $fallback")
    }

    $evidence['addedAtUtc'] = $addedAt.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $visible = [bool](Test-Membership -MemberId $PrincipalId)
    while (-not $visible -and $clock.Elapsed.TotalSeconds -lt $WaitSeconds) {
        Start-Sleep -Seconds $PollSeconds
        $visible = [bool](Test-Membership -MemberId $PrincipalId)
    }
    $evidence['visibleAfterSeconds'] = [int]$clock.Elapsed.TotalSeconds
    if (-not $visible) {
        return Get-GroupResult 'Warning' ("T1's managed identity was added to the T3 administrator group, but Microsoft Graph didn't report the membership within {0} seconds." -f $WaitSeconds) $evidence "Wait a few minutes before T1 configures T3; Invoke-DemoT3SqlFromT1 retries the login and reports how long it took."
    }
    if ($SettleSeconds -gt 0) {
        Write-DemoLog -Message ('T1 joined the T3 administrator group; waiting {0} seconds before T1 asks for an Azure SQL token.' -f $SettleSeconds)
        Start-Sleep -Seconds $SettleSeconds
    }
    $evidence['settleSeconds'] = $SettleSeconds
    Get-GroupResult 'Pass' ("T1's managed identity was added to the T3 administrator group (P6); Microsoft Graph reported it after {0} seconds." -f $evidence['visibleAfterSeconds']) $evidence
}
