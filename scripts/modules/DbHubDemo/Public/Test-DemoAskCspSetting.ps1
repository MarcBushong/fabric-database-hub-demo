function Test-DemoAskCspSetting {
    <#
    .SYNOPSIS
    ASK.CSP: whether the Fabric tenant setting "Enforce a strict content security policy for static-hosted Fabric Apps
    (preview)" (EnforceStrictCspForStaticHostedFabricApps) is off, as Ask needs: with it on, the Insights app's pages
    can't reach their chat relay. Pass, Warning, or Not selected (Ask never blocks DONE).

    .DESCRIPTION
    The only documented way to read it is the Fabric admin API, Tenants - List Tenant Settings, which needs a Fabric
    administrator; it's read through the Phase 12 Fabric REST helpers, as preflight reads the app's own settings.
    - Off: Pass. It's off by default.
    - On, for the organization or for security groups: Warning, with the portal steps (only a Fabric administrator can
      change it).
    - Not read (not an administrator, no token, not found): Not selected, with what to look for when the dock says it
      can't reach its relay.
    Source: https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings

    .EXAMPLE
    Test-DemoAskCspSetting -Config (Get-DemoConfig)
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [securestring] $Token,

        [ValidateRange(1, 50)]
        [int] $MaxPages = 10
    )

    $title = 'Enforce a strict content security policy for static-hosted Fabric Apps (preview)'
    $doc = 'https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings'
    $steps = 'A Fabric administrator opens the Fabric admin portal, selects Tenant settings, finds "{0}" under Microsoft Fabric, sets it to Disabled, and selects Apply.' -f $title
    $result = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation = '')
        New-DemoResult -CheckId 'ASK.CSP' -Area 'fabric' -Target 'tenant' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $doc
    }
    $unread = {
        param([string] $Why, [System.Collections.IDictionary] $Evidence)
        & $result 'Not selected' ('The Fabric tenant setting "{0}" wasn''t read ({1}). It''s off by default, as Ask needs; while it''s on, the Insights app''s Copilot dock can''t reach its chat relay.' -f $title, $Why) $Evidence ('Nothing to do while it''s off. If the dock says it can''t reach the relay: {0}' -f $steps)
    }

    $access = Get-DemoHubFabricAccess -SubscriptionId ([string]$Config['subscriptionId']) -Token $Token
    if (-not $access.Token) {
        return (& $unread 'no Fabric token' ([ordered]@{ checkedThroughApi = $false }))
    }
    $list = Read-DemoHubFabricList -Uri ('{0}/admin/tenantsettings' -f (Get-DemoHubSetting)['fabric']['apiBaseUrl']) -Token $access.Token -MaxPages $MaxPages
    if (-not $list.Succeeded) {
        $why = if ($list.StatusCode -in 401, 403) { 'reading it needs a Fabric administrator; HTTP {0}' -f $list.StatusCode } else { 'the Fabric admin API answered {0}' -f ([string]$list.Error).TrimEnd('.') }
        return (& $unread $why ([ordered]@{ checkedThroughApi = $true; statusCode = $list.StatusCode }))
    }
    $items = @($list.Items)
    $found = @($items | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'settingName') -ieq 'EnforceStrictCspForStaticHostedFabricApps' }) | Select-Object -First 1
    if ($null -eq $found) {
        $found = @($items | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'title') -eq $title }) | Select-Object -First 1
    }
    $enabled = if ($null -ne $found) { [string](Get-DemoMemberValue -InputObject $found -Name 'enabled') } else { '' }
    $evidence = [ordered]@{ checkedThroughApi = $true; statusCode = 200; settingsRead = $items.Count; enabled = $enabled }
    if ($enabled -notin 'True', 'False') {
        return (& $unread ('not found among the {0} settings the admin API returned' -f $items.Count) $evidence)
    }
    if ($enabled -eq 'False') {
        return (& $result 'Pass' ('The Fabric tenant setting "{0}" is off, so the Insights app''s pages can reach Ask''s chat relay (read through the Fabric admin API).' -f $title) $evidence)
    }
    $groupsValue = Get-DemoMemberValue -InputObject $found -Name 'enabledSecurityGroups'
    $groups = @(@($groupsValue) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
    $evidence['groups'] = $groups
    $scope = if ($groups.Count -gt 0) { 'for {0}' -f ($groups -join ', ') } else { 'for the organization' }
    return (& $result 'Warning' ('The Fabric tenant setting "{0}" is on {1}: the Insights app''s pages can''t reach Ask''s chat relay, so its Copilot dock says it can''t connect. Everything else in the app works.' -f $title, $scope) $evidence $steps)
}
