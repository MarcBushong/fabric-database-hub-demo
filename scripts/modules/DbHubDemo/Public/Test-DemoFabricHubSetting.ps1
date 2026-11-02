function Test-DemoFabricHubSetting {
    <#
    .SYNOPSIS
    Checks prerequisite P4: the Fabric tenant setting "Users can access the Database hub (preview)" is
    enabled (FABRIC.P4.HUBSETTING, or -CheckId PREFLIGHT.P4.HUBSETTING in preflight).

    .DESCRIPTION
    Database Hub is a tenant opt-in during the preview: a Fabric administrator enables "Users can access the
    Database hub (preview)" in the Fabric admin portal's tenant settings
    (https://learn.microsoft.com/fabric/database/hub/monitor-sql, checked 2026-10-20). The only documented
    way to read tenant settings is the Fabric admin API "Tenants - List Tenant Settings"
    (GET https://api.fabric.microsoft.com/v1/admin/tenantsettings,
    https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings, checked 2026-10-30): the caller
    must be a Fabric administrator (delegated scope Tenant.Read.All), at most 25 requests per minute.
    Since Phase 28 (live finding, 2026-10-30) the API is tried on every call, through the Phase 12 Fabric REST helpers
    (Get-DemoFabricToken and Invoke-DemoFabricRequest: the caller's token, from -Token or the Azure CLI, sent only as a
    SecureString bearer token), and every page is read. Before, it was tried only with -FabricAdmin, which deploy.ps1
    never passed, so the check always said "Confirm that ... is enabled", which a run's ending showed as its reason
    while the setting was on. The setting is matched by settingName when config/versions.json records one, otherwise
    by its documented title (TODO(verify): Learn doesn't document the settingName):
    - Read, and enabled for the whole organization: Pass.
    - Read, and enabled only for security groups: Warning (presenters must be members).
    - Read, and disabled: Manual action required, "is disabled": the one case that keeps deploy.ps1 from DONE.
    - Not read (no token, the Phase 12 helpers missing from the build, HTTP 401 or 403 because the caller isn't a
      Fabric administrator, another HTTP error, or the setting not found among those read): Manual action required,
      "Couldn't check the Fabric tenant setting ...: please confirm it's enabled", which never keeps deploy.ps1 from
      DONE (Test-DemoConfirmOnlyResult); its ending lists it once under "Please confirm".
    The evidence says which: checkedThroughApi (the API was called), statusCode, settingsRead, pages, complete,
    settingRead (the setting was found and read), matchedBy (settingName or title), enabled, and readError. Each
    attempt and its outcome is logged (Write-DemoLog), never a token. Hub users also need at least a Fabric Free
    license, which no API here checks; the steps say so.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER FabricAdmin
    Accepted for compatibility (configure-fabric.ps1 -FabricAdmin, validate.ps1 -FabricAdmin): the admin API is now
    tried on every call, so it changes nothing.

    .PARAMETER Token
    A Fabric REST API token the operator already has, as a SecureString. Without it, Get-DemoFabricToken
    gets one from the signed-in Azure CLI.

    .PARAMETER MaxPages
    The most pages of tenant settings to read.

    .PARAMETER CheckId
    FABRIC.P4.HUBSETTING (the Database Hub checklist, area fabric), or PREFLIGHT.P4.HUBSETTING (preflight, area
    preflight).

    .EXAMPLE
    Test-DemoFabricHubSetting -Config $config
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $FabricAdmin,

        [securestring] $Token,

        [ValidateRange(1, 50)]
        [int] $MaxPages = 10,

        [ValidateSet('FABRIC.P4.HUBSETTING', 'PREFLIGHT.P4.HUBSETTING')]
        [string] $CheckId = 'FABRIC.P4.HUBSETTING'
    )

    $null = $FabricAdmin
    $fabric = (Get-DemoHubSetting)['fabric']
    $setting = $fabric['hubTenantSetting']
    $title = [string]$setting['title']
    $settingName = [string]$setting['settingName']
    $docUrl = [string]$setting['docUrl']
    $area = if ($CheckId -like 'PREFLIGHT.*') { 'preflight' } else { 'fabric' }
    $steps = ('A Fabric administrator opens the Fabric admin portal, selects Tenant settings, finds "{0}", sets it to Enabled for the entire organization (or for security groups that include every presenter), and selects Apply. Every Hub user also needs at least a Fabric Free license, and My workspace must not be on a capacity in North Europe or West Europe.' -f $title)
    $confirmSteps = ('Nothing to change when Database Hub opens for you and your presenters. To confirm it, a Fabric administrator opens the Fabric admin portal, selects Tenant settings, and finds "{0}"; if it''s off, they set it to Enabled for the entire organization (or for security groups that include every presenter) and select Apply. When a Fabric administrator runs deploy.ps1, this check reads the setting itself.' -f $title)

    function ConvertTo-HubSettingResult([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation = '') {
        New-DemoResult -CheckId $CheckId -Area $area -Target 'tenant' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl
    }
    # The setting couldn't be read: a reminder to confirm it, never "it's disabled" (Phase 28 live finding).
    function ConvertTo-UncheckedResult([string] $Why, [System.Collections.IDictionary] $Evidence, [string] $Extra = '') {
        $Evidence['settingRead'] = $false
        $Evidence['readError'] = $Why
        $detail = if ($Evidence.Contains('error') -and [string]$Evidence['error']) { ' The API said: {0}.' -f ([string]$Evidence['error']).TrimEnd('.') } else { '' }
        Write-DemoLog -Level Warning -Message ('P4 ({0}): couldn''t check the Fabric tenant setting "{1}" ({2}). It''s a reminder to confirm the setting, not a sign that it''s disabled.{3}' -f $CheckId, $title, $Why, $detail)
        ConvertTo-HubSettingResult 'Manual action required' ('Couldn''t check the Fabric tenant setting "{0}" ({1}): please confirm it''s enabled.' -f $title, $Why) $Evidence ('{0}{1}' -f $confirmSteps, $Extra)
    }

    $access = Get-DemoHubFabricAccess -SubscriptionId ([string]$Config['subscriptionId']) -Token $Token
    if (-not $access.Token) {
        $why = if (-not $access.Available) {
            'the Fabric REST helpers (Phase 12) aren''t in this build of the module'
        }
        else {
            'no Fabric token without interaction: {0}' -f (([string]$access.Error) -replace '^No Fabric token is available without interaction:\s*', '').TrimEnd('.')
        }
        return ConvertTo-UncheckedResult $why ([ordered]@{ checkedThroughApi = $false })
    }

    Write-DemoLog -Message ('P4 ({0}): reading the Fabric tenant settings through the admin API (Tenants - List Tenant Settings) for "{1}"; it needs a Fabric administrator.' -f $CheckId, $title)
    $list = Read-DemoHubFabricList -Uri ('{0}/admin/tenantsettings' -f $fabric['apiBaseUrl']) -Token $access.Token -MaxPages $MaxPages
    if (-not $list.Succeeded) {
        $evidence = [ordered]@{ checkedThroughApi = $true; statusCode = $list.StatusCode; pages = $list.Pages; error = [string]$list.Error }
        $why = if ($list.StatusCode -in 401, 403) {
            'needs a Fabric administrator; HTTP {0}' -f $list.StatusCode
        }
        elseif ($list.StatusCode -eq 0) {
            'the Fabric admin API didn''t answer: {0}' -f ([string]$list.Error).TrimEnd('.')
        }
        else {
            'the Fabric admin API answered {0}' -f ([string]$list.Error).TrimEnd('.')
        }
        return ConvertTo-UncheckedResult $why $evidence
    }

    $settings = @($list.Items)
    $found = $null
    $matchedBy = ''
    if ($settingName) {
        $found = $settings | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'settingName') -ieq $settingName } | Select-Object -First 1
        if ($found) {
            $matchedBy = 'settingName'
        }
    }
    if (-not $found) {
        $found = $settings | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'title') -ieq $title } | Select-Object -First 1
        if ($found) {
            $matchedBy = 'title'
        }
    }
    $evidence = [ordered]@{ checkedThroughApi = $true; statusCode = 200; settingsRead = $settings.Count; pages = $list.Pages; complete = $list.Complete }
    if (-not $found) {
        $candidates = @($settings | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'title') } | Where-Object { $_ -match '(?i)database\s*hub' })
        $evidence['similarTitles'] = $candidates
        $similar = if ($candidates.Count -gt 0) { '; similar titles: {0}' -f ($candidates -join '; ') } else { '' }
        $why = 'it wasn''t among the {0} tenant settings the admin API returned{1}{2}' -f $settings.Count, $(if ($list.Complete) { '' } else { ' (not every page was read)' }), $similar
        return ConvertTo-UncheckedResult $why $evidence ' If the preview renamed it, record its settingName in config/versions.json (databaseHub.fabric.hubTenantSetting).'
    }

    $groupsValue = Get-DemoMemberValue -InputObject $found -Name 'enabledSecurityGroups'
    $groups = @(@($groupsValue) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
    $excludedValue = Get-DemoMemberValue -InputObject $found -Name 'excludedSecurityGroups'
    $foundName = [string](Get-DemoMemberValue -InputObject $found -Name 'settingName')
    $evidence['matchedBy'] = $matchedBy
    $evidence['settingName'] = $foundName
    $evidence['tenantSettingGroup'] = [string](Get-DemoMemberValue -InputObject $found -Name 'tenantSettingGroup')
    # Only an explicit enabled value is read: one the answer doesn't have is a reminder, never "disabled".
    $enabledValue = Get-DemoMemberValue -InputObject $found -Name 'enabled'
    if ($null -eq $enabledValue -or [string]$enabledValue -notin 'True', 'False') {
        return ConvertTo-UncheckedResult ('the admin API''s answer has no enabled value for it (settingName {0})' -f $(if ($foundName) { $foundName } else { 'none' })) $evidence
    }
    $evidence['settingRead'] = $true
    $evidence['enabled'] = [string]$enabledValue -eq 'True'
    $evidence['enabledSecurityGroups'] = $groups
    $evidence['excludedSecurityGroups'] = @(@($excludedValue) | Where-Object { $null -ne $_ }).Count
    $state = if (-not $evidence['enabled']) { 'disabled' } elseif ($groups.Count -gt 0) { 'enabled for {0} security group(s)' -f $groups.Count } else { 'enabled for the organization' }
    Write-DemoLog -Message ('P4 ({0}): read {1} tenant setting(s) in {2} page(s); "{3}" matched by {4} (settingName {5}): {6}.' -f $CheckId, $settings.Count, $list.Pages, $title, $matchedBy, $(if ($foundName) { $foundName } else { 'none' }), $state)

    if (-not $evidence['enabled']) {
        return ConvertTo-HubSettingResult 'Manual action required' ('The Fabric tenant setting "{0}" is disabled (read through the Fabric admin API), so nobody in the tenant can open Database Hub.' -f $title) $evidence ('{0} Then run ./scripts/deploy.ps1 again.' -f $steps)
    }
    if ($groups.Count -gt 0) {
        return ConvertTo-HubSettingResult 'Warning' ('The Fabric tenant setting "{0}" is enabled only for these security groups: {1}. Every presenter must be a member.' -f $title, ($groups -join ', ')) $evidence 'Add each presenter to one of the groups, or have a Fabric administrator enable the setting for the entire organization.'
    }
    return ConvertTo-HubSettingResult 'Pass' ('The Fabric tenant setting "{0}" is enabled for the organization (read through the Fabric admin API).' -f $title) $evidence
}