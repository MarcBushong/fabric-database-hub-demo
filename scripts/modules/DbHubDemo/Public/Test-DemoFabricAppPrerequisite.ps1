function Test-DemoFabricAppPrerequisite {
    <#
    .SYNOPSIS
    Checks what deploying the Fabric App needs on the operator's side: a supported Node.js, the Rayfin CLI signed in
    to the demo's tenant, and the two tenant settings the app depends on (FABRIC.APP.NODE, FABRIC.APP.SIGNIN,
    FABRIC.APP.TENANTSETTING, FABRIC.APP.EXECUTEQUERIES).

    .DESCRIPTION
    - Node.js: the pinned Rayfin CLI supports the Node.js majors in config/versions.json (fabricApp.supportedNodeMajors,
      from its engines field). A supported major is a Pass; a newer one is a Warning (npm prints EBADENGINE, and the
      CLI still ran on Node.js 26 in the live check, 2026-10-22); an older one or no Node.js is a Fail.
    - Sign-in: 'rayfin login status --json' from the stage's pinned CLI. It reads the CLI's own token cache and never
      opens a browser. Signed in to the configured tenant: Pass. Not signed in, or signed in to another tenant:
      Manual action required with the one-time command the operator runs (https://learn.microsoft.com/fabric/apps/cli-reference).
      The CLI's service principal sign-in is listed there but not supported yet, so unattended runs reuse the
      operator's cached sign-in.
    - Tenant settings (config/versions.json, fabricApp.tenantSettings): Fabric Apps (preview), which gates creating
      and opening app items (https://learn.microsoft.com/fabric/apps/overview), and Dataset Execute Queries REST API
      (Integration settings; newer portals say "Semantic Model"), which gates the Power BI Execute Queries API
      (https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group) that the semantic model
      connector's runtime calls. Reading tenant settings needs the Fabric admin API
      (https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings), so with -FabricAdmin they're
      read through the Phase 12 Fabric REST helpers; without it each is Manual action required, and
      configure-fabric-app.ps1 replaces it with a Pass when the check named in its verifiedBy (the deploy, or the
      connector check) passes, which proves the setting is on for the operator.

    .PARAMETER Config
    Configuration from Get-DemoConfig (tenantId, subscriptionId).

    .PARAMETER StagePath
    The deploy stage whose pinned CLI checks the sign-in (out/fabric-app, after Sync-DemoFabricAppStage).

    .PARAMETER FabricAdmin
    The caller is a Fabric administrator, so read the tenant setting through the admin API.

    .PARAMETER Token
    A Fabric REST API token for -FabricAdmin, as a SecureString. Without it, Get-DemoFabricToken uses the Azure CLI.

    .PARAMETER SkipSignIn
    Don't check the CLI's sign-in (FABRIC.APP.SIGNIN is Not selected), for -WhatIf.

    .EXAMPLE
    Test-DemoFabricAppPrerequisite -Config $config -StagePath ./out/fabric-app
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $StagePath,

        [switch] $FabricAdmin,

        [securestring] $Token,

        [switch] $SkipSignIn
    )

    $settings = Get-DemoFabricAppSetting
    $supported = @($settings['supportedNodeMajors'] | ForEach-Object { [int]$_ })
    $cliReference = 'https://learn.microsoft.com/fabric/apps/cli-reference'
    $tenantId = [string]$Config['tenantId']
    $loginCommand = 'npx --yes --package={0}@{1} -- rayfin login --tenant {2}' -f $settings['cliPackage'], $settings['cliVersion'], $(if ($tenantId) { $tenantId } else { '<tenantId>' })
    $results = [System.Collections.Generic.List[object]]::new()

    # Node.js
    $nodeVersion = ''
    try {
        $node = Invoke-DemoFabricAppProcess -Tool 'node' -ArgumentList @('--version') -WorkingDirectory $script:RepoRoot -TimeoutSeconds 60
        if ($node.ExitCode -eq 0) {
            $nodeVersion = ([string]$node.StdOut).Trim()
        }
    }
    catch {
        $nodeVersion = ''
    }
    $nodeDoc = 'https://nodejs.org/en/about/previous-releases'
    if ($nodeVersion -notmatch '^v(\d+)\.') {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.NODE' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'Node.js wasn''t found on PATH, and the Rayfin CLI and the app build need it.' -Remediation ('Install Node.js {0} (LTS), which includes npm, and run the script again.' -f ($supported -join ', ')) -DocUrl $nodeDoc))
    }
    else {
        $major = [int]$Matches[1]
        $evidence = [ordered]@{ version = $nodeVersion; supportedMajors = $supported }
        if ($supported -contains $major) {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.NODE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('Node.js {0} is a version the Rayfin CLI {1} supports.' -f $nodeVersion, $settings['cliVersion']) -Evidence $evidence -DocUrl $nodeDoc))
        }
        elseif ($major -gt ($supported | Measure-Object -Maximum).Maximum) {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.NODE' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('Node.js {0} is newer than the versions the Rayfin CLI {1} declares ({2}); npm warns (EBADENGINE), and the CLI ran on Node.js 26 in the live check.' -f $nodeVersion, $settings['cliVersion'], ($supported -join ', ')) -Evidence $evidence -Remediation ('If a CLI step fails, run the script with Node.js {0}.' -f ($supported | Measure-Object -Maximum).Maximum) -DocUrl $nodeDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.NODE' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('Node.js {0} is older than the versions the Rayfin CLI {1} supports ({2}).' -f $nodeVersion, $settings['cliVersion'], ($supported -join ', ')) -Evidence $evidence -Remediation ('Install Node.js {0} and run the script again.' -f ($supported | Measure-Object -Maximum).Maximum) -DocUrl $nodeDoc))
        }
    }

    # Sign-in
    if ($SkipSignIn) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Not selected' -Message 'The Rayfin CLI''s sign-in wasn''t checked (dry run).' -DocUrl $cliReference))
    }
    else {
        $status = $null
        $failure = ''
        # A read-only status query of the Rayfin CLI's own token cache; nothing here signs in or out.
        $statusQuery = @('login', 'status', '--json')
        try {
            $status = Invoke-DemoRayfinCli -StagePath $StagePath -ArgumentList $statusQuery -TimeoutSeconds 120
        }
        catch {
            $failure = $_.Exception.Message
        }
        $data = if ($status) { $status.Data } else { $null }
        $state = if ($data) { [string]$data['status'] } else { '' }
        $signedTenant = if ($data) { [string]$data['tenant'] } else { '' }
        $evidence = [ordered]@{ status = $state; identityType = $(if ($data) { [string]$data['identityType'] } else { '' }); tenantMatches = ($signedTenant -and $tenantId -and $signedTenant -ieq $tenantId) }
        if ($state -eq 'ok' -and $evidence['tenantMatches']) {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Pass' -Message 'The Rayfin CLI is signed in to the demo''s tenant (its own cached sign-in; no browser was opened).' -Evidence $evidence -DocUrl $cliReference))
        }
        elseif ($state -eq 'ok') {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'The Rayfin CLI is signed in to another tenant than the demo''s (tenantId).' -Evidence $evidence -Remediation ('Sign in once as the demo''s Fabric user, from any folder: {0}' -f $loginCommand) -DocUrl $cliReference))
        }
        elseif ($state -eq 'not-signed-in') {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'The Rayfin CLI isn''t signed in, so the app can''t be deployed unattended.' -Evidence $evidence -Remediation ('Sign in once as the demo''s Fabric user (it opens a browser), then run the script again: {0}' -f $loginCommand) -DocUrl $cliReference))
        }
        else {
            $why = if ($failure) { $failure } elseif ($data -and $data['error']) { [string]$data['error'] } elseif ($status) { ('exit code {0}: {1}' -f $status.ExitCode, (@($status.StdErr, $status.StdOut) | Where-Object { $_ } | Select-Object -First 1)) } else { 'no output' }
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message ('The Rayfin CLI''s sign-in couldn''t be read: {0}' -f $why) -Evidence $evidence -Remediation ('Sign in again as the demo''s Fabric user: {0}' -f $loginCommand) -DocUrl $cliReference))
        }
    }

    # Tenant settings: one result per setting in config/versions.json.
    $tenantSettings = @($settings['tenantSettings'])
    $describe = {
        param([System.Collections.IDictionary] $Setting)
        $title = [string]$Setting['title']
        [pscustomobject]@{
            CheckId = [string]$Setting['checkId']
            Title   = $title
            DocUrl  = [string]$Setting['docUrl']
            Steps   = ('A Fabric administrator opens the Fabric admin portal, selects Tenant settings, finds "{0}", sets it to Enabled for the entire organization (or for security groups that include the deploying user and every viewer), and selects Apply. Changes can take a few minutes.' -f $title)
        }
    }
    if (-not $FabricAdmin) {
        foreach ($setting in $tenantSettings) {
            $info = & $describe $setting
            $results.Add((New-DemoResult -CheckId $info.CheckId -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message ('Confirm that the Fabric tenant setting "{0}" is enabled; reading it needs a Fabric administrator.' -f $info.Title) -Evidence @{ checkedThroughApi = $false } -Remediation ('{0} When {1} passes, configure-fabric-app.ps1 reports the setting as verified.' -f $info.Steps, $setting['verifiedBy']) -DocUrl $info.DocUrl))
        }
        return $results.ToArray()
    }
    $access = Get-DemoHubFabricAccess -SubscriptionId ([string]$Config['subscriptionId']) -Token $Token
    $list = if ($access.Token) { Read-DemoHubFabricList -Uri ('{0}/admin/tenantsettings' -f (Get-DemoHubSetting)['fabric']['apiBaseUrl']) -Token $access.Token -MaxPages 10 } else { $null }
    $items = if ($list -and $list.Succeeded) { @($list.Items) } else { @() }
    foreach ($setting in $tenantSettings) {
        $info = & $describe $setting
        if (-not $access.Token) {
            $results.Add((New-DemoResult -CheckId $info.CheckId -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message ('The Fabric tenant settings couldn''t be read: {0}' -f $access.Error) -Evidence @{ checkedThroughApi = $false } -Remediation $info.Steps -DocUrl $info.DocUrl))
            continue
        }
        if (-not $list.Succeeded) {
            $results.Add((New-DemoResult -CheckId $info.CheckId -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message ('The Fabric admin API didn''t list the tenant settings ({0}); the caller may not be a Fabric administrator.' -f $list.Error) -Evidence @{ checkedThroughApi = $true; statusCode = $list.StatusCode } -Remediation $info.Steps -DocUrl $info.DocUrl))
            continue
        }
        $titles = @(@($info.Title) + @($setting['alternateTitles'] | Where-Object { $_ }))
        $found = $null
        if ($setting['settingName']) {
            $found = $items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'settingName') -ieq [string]$setting['settingName'] } | Select-Object -First 1
        }
        if (-not $found) {
            $found = $items | Where-Object { $titles -contains [string](Get-DemoMemberValue -InputObject $_ -Name 'title') } | Select-Object -First 1
        }
        $evidence = [ordered]@{ checkedThroughApi = $true; settingsRead = $items.Count }
        if (-not $found) {
            $results.Add((New-DemoResult -CheckId $info.CheckId -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message ('The tenant setting "{0}" wasn''t found among {1} settings; the preview may have renamed it.' -f $info.Title, $items.Count) -Evidence $evidence -Remediation ('{0} Then record its settingName in config/versions.json (fabricApp.tenantSettings).' -f $info.Steps) -DocUrl $info.DocUrl))
            continue
        }
        $groupsValue = Get-DemoMemberValue -InputObject $found -Name 'enabledSecurityGroups'
        $groups = @(@($groupsValue) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        $evidence['settingName'] = [string](Get-DemoMemberValue -InputObject $found -Name 'settingName')
        $evidence['enabled'] = [bool](Get-DemoMemberValue -InputObject $found -Name 'enabled')
        $evidence['enabledSecurityGroups'] = $groups
        if (-not $evidence['enabled']) {
            $results.Add((New-DemoResult -CheckId $info.CheckId -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message ('The Fabric tenant setting "{0}" is disabled.' -f $info.Title) -Evidence $evidence -Remediation $info.Steps -DocUrl $info.DocUrl))
        }
        elseif ($groups.Count -gt 0) {
            $results.Add((New-DemoResult -CheckId $info.CheckId -Area 'fabric' -Target 'tenant' -Status 'Warning' -Message ('The Fabric tenant setting "{0}" is enabled only for these security groups: {1}. The deploying user and every viewer must be members.' -f $info.Title, ($groups -join ', ')) -Evidence $evidence -Remediation 'Add each presenter to one of the groups, or have a Fabric administrator enable the setting for the entire organization.' -DocUrl $info.DocUrl))
        }
        else {
            $results.Add((New-DemoResult -CheckId $info.CheckId -Area 'fabric' -Target 'tenant' -Status 'Pass' -Message ('The Fabric tenant setting "{0}" is enabled for the organization.' -f $info.Title) -Evidence $evidence -DocUrl $info.DocUrl))
        }
    }
    return $results.ToArray()
}
