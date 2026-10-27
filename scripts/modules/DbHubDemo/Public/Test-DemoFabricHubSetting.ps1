function Test-DemoFabricHubSetting {
    <#
    .SYNOPSIS
    Checks prerequisite P4: the Fabric tenant setting "Users can access the Database hub (preview)" is
    enabled (FABRIC.P4.HUBSETTING).

    .DESCRIPTION
    Database Hub is a tenant opt-in during the preview: a Fabric administrator enables "Users can access the
    Database hub (preview)" in the Fabric admin portal's tenant settings
    (https://learn.microsoft.com/fabric/database/hub/monitor-sql, checked 2026-10-20). The only documented
    way to read tenant settings is the Fabric admin API "Tenants - List Tenant Settings"
    (GET https://api.fabric.microsoft.com/v1/admin/tenantsettings,
    https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings), which needs a Fabric
    administrator (delegated scope Tenant.Read.All). So:
    - Without -FabricAdmin, nothing is called: Manual action required, with the exact portal steps.
    - With -FabricAdmin, the API is called through the Phase 12 Fabric REST helpers (Get-DemoFabricToken and
      Invoke-DemoFabricRequest: the caller's token, from -Token or the Azure CLI, sent only as a SecureString
      bearer token) and every page is read. The setting is matched by settingName when config/versions.json
      records one, otherwise by its documented title (TODO(verify): Learn doesn't document the settingName).
      Enabled for the whole organization: Pass. Enabled only for security groups: Warning (presenters
      must be members). Disabled, not found, no token, the Phase 12 helpers missing from the build, or the API
      refused the call (HTTP 401 or 403: not a Fabric administrator): Manual action required.
    Hub users also need at least a Fabric Free license, which no API here checks; the steps say so.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER FabricAdmin
    The caller is a Fabric administrator, so read the setting through the admin API.

    .PARAMETER Token
    A Fabric REST API token the operator already has, as a SecureString. Without it, Get-DemoFabricToken
    gets one from the signed-in Azure CLI.

    .PARAMETER MaxPages
    The most pages of tenant settings to read.

    .EXAMPLE
    Test-DemoFabricHubSetting -Config $config -FabricAdmin
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $FabricAdmin,

        [securestring] $Token,

        [ValidateRange(1, 50)]
        [int] $MaxPages = 10
    )

    $fabric = (Get-DemoHubSetting)['fabric']
    $setting = $fabric['hubTenantSetting']
    $title = [string]$setting['title']
    $settingName = [string]$setting['settingName']
    $docUrl = [string]$setting['docUrl']
    $steps = ('A Fabric administrator opens the Fabric admin portal, selects Tenant settings, finds "{0}", sets it to Enabled for the entire organization (or for security groups that include every presenter), and selects Apply. Every Hub user also needs at least a Fabric Free license, and My workspace must not be on a capacity in North Europe or West Europe.' -f $title)

    function ConvertTo-HubSettingResult([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation = '') {
        New-DemoResult -CheckId 'FABRIC.P4.HUBSETTING' -Area 'fabric' -Target 'tenant' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl
    }

    if (-not $FabricAdmin) {
        return ConvertTo-HubSettingResult 'Manual action required' ('Confirm that the Fabric tenant setting "{0}" is enabled; reading it needs a Fabric administrator.' -f $title) @{ checkedThroughApi = $false } ('{0} If you are a Fabric administrator, run configure-fabric.ps1 -FabricAdmin to check it automatically.' -f $steps)
    }

    $access = Get-DemoHubFabricAccess -SubscriptionId ([string]$Config['subscriptionId']) -Token $Token
    if (-not $access.Token) {
        return ConvertTo-HubSettingResult 'Manual action required' ('The Fabric tenant settings could not be read: {0}' -f $access.Error) @{ checkedThroughApi = $false } $steps
    }

    $list = Read-DemoHubFabricList -Uri ('{0}/admin/tenantsettings' -f $fabric['apiBaseUrl']) -Token $access.Token -MaxPages $MaxPages
    if (-not $list.Succeeded) {
        $evidence = [ordered]@{ checkedThroughApi = $true; statusCode = $list.StatusCode }
        if ($list.StatusCode -in 401, 403) {
            return ConvertTo-HubSettingResult 'Manual action required' ('The Fabric admin API refused to list tenant settings ({0}), so the caller isn''t a Fabric administrator or the token lacks Tenant.Read.All.' -f $list.Error) $evidence $steps
        }
        return ConvertTo-HubSettingResult 'Manual action required' ('The Fabric tenant settings could not be read: {0}' -f $list.Error) $evidence $steps
    }

    $settings = @($list.Items)
    $found = $null
    if ($settingName) {
        $found = $settings | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'settingName') -ieq $settingName } | Select-Object -First 1
    }
    if (-not $found) {
        $found = $settings | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'title') -ieq $title } | Select-Object -First 1
    }
    $evidence = [ordered]@{ checkedThroughApi = $true; settingsRead = $settings.Count; pages = $list.Pages; complete = $list.Complete }
    if (-not $found) {
        $candidates = @($settings | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'title') } | Where-Object { $_ -match '(?i)database\s*hub' })
        $evidence['similarTitles'] = $candidates
        return ConvertTo-HubSettingResult 'Manual action required' ('The tenant setting "{0}" wasn''t found among {1} settings; the preview may have renamed it.' -f $title, $settings.Count) $evidence ('{0} Then record its settingName in config/versions.json (databaseHub.fabric.hubTenantSetting).' -f $steps)
    }

    $groupsValue = Get-DemoMemberValue -InputObject $found -Name 'enabledSecurityGroups'
    $groups = @(@($groupsValue) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
    $excludedValue = Get-DemoMemberValue -InputObject $found -Name 'excludedSecurityGroups'
    $evidence['settingName'] = [string](Get-DemoMemberValue -InputObject $found -Name 'settingName')
    $evidence['tenantSettingGroup'] = [string](Get-DemoMemberValue -InputObject $found -Name 'tenantSettingGroup')
    $evidence['enabled'] = [bool](Get-DemoMemberValue -InputObject $found -Name 'enabled')
    $evidence['enabledSecurityGroups'] = $groups
    $evidence['excludedSecurityGroups'] = @(@($excludedValue) | Where-Object { $null -ne $_ }).Count

    if (-not $evidence['enabled']) {
        return ConvertTo-HubSettingResult 'Manual action required' ('The Fabric tenant setting "{0}" is disabled, so nobody in the tenant can open the Database Hub.' -f $title) $evidence $steps
    }
    if ($groups.Count -gt 0) {
        return ConvertTo-HubSettingResult 'Warning' ('The Fabric tenant setting "{0}" is enabled only for these security groups: {1}. Every presenter must be a member.' -f $title, ($groups -join ', ')) $evidence 'Add each presenter to one of the groups, or have a Fabric administrator enable the setting for the entire organization.'
    }
    return ConvertTo-HubSettingResult 'Pass' ('The Fabric tenant setting "{0}" is enabled for the organization.' -f $title) $evidence
}
