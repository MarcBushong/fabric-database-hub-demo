# deploy.ps1's session control (ADR 0026, 2026-11-14): the control notebook's Run all is part of every deployment, a new
# one and an existing one, so deploy.ps1 sets the control up, adopts one set up earlier as it is, and says what it did.

function ConvertTo-DemoControlDeployResult {
    <#
    .SYNOPSIS
    The control setup's results as deploy.ps1 reports them: never a Fail and never a blocking Manual action required (a
    Warning with its fix instead, as the nightly safety stop's are), the setup's own summary, its -SkipFabric note, and
    the guard's repeated Pass left out, and "setup-activity-control.ps1" in a fix read as "./scripts/deploy.ps1", which
    does the same. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $output = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Result | Where-Object { $null -ne $_ })) {
        $checkId = [string]$item.checkId
        if ($checkId -eq 'CONTROL.SUMMARY' -or ($checkId -eq 'PREFLIGHT.GUARD.CONTEXT' -and [string]$item.status -eq 'Pass') -or ($checkId -eq 'CONTROL.FABRIC.NOTEBOOK' -and [string]$item.status -eq 'Not selected')) {
            continue
        }
        if ([string]$item.status -in 'Fail', 'Manual action required') {
            $item.status = 'Warning'
            if (-not [string]$item.remediation) {
                $item.remediation = 'Run ./scripts/deploy.ps1 again; it sets the session control up each time. Meanwhile ./scripts/start-demo.ps1 runs a session from this PC.'
            }
        }
        foreach ($field in 'message', 'remediation') {
            $text = [string]$item.$field
            if ($text -match 'setup-activity-control\.ps1') {
                # The grant first (it keeps its -ConfigPath), then any other use, which deploy.ps1 does too.
                $text = $text -replace '(?:\./scripts/)?setup-activity-control\.ps1((?: -ConfigPath \S+)?) -GrantRole', './scripts/grant-safety-stop.ps1$1'
                $item.$field = $text -replace '(?:\./scripts/)?setup-activity-control\.ps1', './scripts/deploy.ps1'
            }
        }
        $output.Add($item)
    }
    return $output.ToArray()
}

function Invoke-DemoControlDeployStep {
    <#
    .SYNOPSIS
    The session control in a deploy.ps1 run (ADR 0026): -Part Azure sets it up in rg-<prefix>-control while the tracks
    run, and -Part Fabric puts the control notebook in Fabric after the Fabric track. Returns CONTROL.* results and, after
    the Fabric part, DEPLOY.CONTROL; never a Fail. Internal.

    .DESCRIPTION
    - Azure (Invoke-DemoActivityControlSetup -SkipFabric): the vault's network mode, the group, the template, the
      runbooks with this code, the T4 safety stop, the webhook, the session's secrets, and the control's roles when the
      deployer may grant them (otherwise each missing one is a Warning with ./scripts/grant-safety-stop.ps1). A control
      set up before 2026-11-14 is adopted: the same names, so the same resources, updated in place. An older
      configuration's "enabled": false is ignored, with a note (DEPLOY.CONTROL.ON).
    - Fabric: the notebook NB_DatabaseHub_Control, in a folder of the demo's workspace (a public vault) or in the control
      workspace with a managed private endpoint to the vault (a private one), as the vault actually is
      (Set-DemoActivityControlFabric). Nothing in Fabric changes while the capacity isn't Active (a Warning; the next
      deploy.ps1 does it), and the capacity is never resumed or paused.
    The status page's "Session control" row follows both parts, and DEPLOY.CONTROL says where Run all is.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('Azure', 'Fabric')]
        [string] $Part,

        [string] $ConfigPath = '',

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [switch] $SkipFabric
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $doc = 'https://learn.microsoft.com/azure/automation/automation-webhooks'
    $name = Get-DemoActivityControlName -Config $Config
    if ($Part -eq 'Azure') {
        $setting = Get-DemoActivityControlSetting -Config $Config
        if ($setting.LegacyOff) {
            $text = 'The session control is part of every deployment since 2026-11-14 (ADR 0026), so it''s set up although your configuration says "enabled": false under "control"; that setting no longer turns it off.'
            Write-DemoLog -Message $text
            $results.Add((New-DemoResult -CheckId 'DEPLOY.CONTROL.ON' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message $text -DocUrl $doc))
        }
        Set-DemoProgressStep -Path $ProgressPath -Id 'Control' -State 'Running' -Message ('Setting up the session control in {0}.' -f $name.ResourceGroup)
        $setup = @()
        try {
            $setup = @(Invoke-DemoActivityControlSetup -Config $Config -ConfigPath $ConfigPath -SkipFabric -AssumeGuarded -Confirm:$false)
        }
        catch {
            $setup = @(New-DemoResult -CheckId 'CONTROL.SETUP' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The session control couldn''t be set up: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/deploy.ps1 again; it sets the session control up each time. Meanwhile ./scripts/start-demo.ps1 runs a session from this PC.' -DocUrl $doc)
        }
        $converted = @(ConvertTo-DemoControlDeployResult -Result $setup)
        foreach ($item in $converted) {
            $results.Add($item)
        }
        $open = @($converted | Where-Object { [string]$_.status -eq 'Warning' })
        $next = if ($SkipFabric) { '' } else { ' The notebook follows the Fabric track.' }
        $message = if ($open.Count) { '{0} item(s) need attention: {1}.{2}' -f $open.Count, (@($open | Select-Object -First 2 | ForEach-Object { ([string]$_.message).TrimEnd('.') }) -join '. '), $next } else { 'Set up in {0}: the runbooks, the webhook, the session''s secrets, and the roles.{1}' -f $name.ResourceGroup, $next }
        if ($SkipFabric) {
            Set-DemoProgressStep -Path $ProgressPath -Id 'Control' -State 'Done' -Status $(if ($open.Count) { 'Warning' } else { 'Pass' }) -Message ('{0} The notebook wasn''t set up (-SkipFabric).' -f $message) -MaxLength 1200
        }
        else {
            Set-DemoProgressStep -Path $ProgressPath -Id 'Control' -State 'Running' -Message $message -MaxLength 1200
        }
        if ($open.Count) {
            Write-DemoLog -Level Warning -Message ('The session control: {0}' -f $message)
        }
        return $results.ToArray()
    }

    # The Fabric part.
    if ($SkipFabric) {
        return $results.ToArray()
    }
    Set-DemoProgressStep -Path $ProgressPath -Id 'Control' -State 'Running' -Message ('Putting {0} in Fabric.' -f $name.Notebook)
    $fabric = @()
    try {
        $vault = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $name.KeyVaultId -ApiVersion '2026-02-01')
        $identity = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $name.IdentityId -ApiVersion '2024-11-30')
        $clientId = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $identity.Value -Name 'properties') -Name 'clientId')
        if (-not $vault.Ok -or -not $identity.Ok -or -not $clientId) {
            $missing = @(@(if (-not $vault.Ok) { $name.KeyVault }) + @(if (-not $identity.Ok -or -not $clientId) { $name.Identity }))
            $fabric = @(New-DemoResult -CheckId 'CONTROL.FABRIC.NOTEBOOK' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('{0} wasn''t put in Fabric: {1} isn''t there (the session control''s Azure part says why).' -f $name.Notebook, ($missing -join ' and ')) -Remediation 'Run ./scripts/deploy.ps1 again; it sets the session control up each time.' -DocUrl $doc)
        }
        else {
            $access = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $vault.Value -Name 'properties') -Name 'publicNetworkAccess')
            $mode = if ($access -eq 'Disabled') { 'private' } else { 'public' }
            $runbookSetting = Get-DemoActivityControlRunbookSetting -Config $Config -Name $name -IdentityClientId $clientId
            $token = Get-DemoFabricToken -SubscriptionId $name.SubscriptionId
            $fabric = @(Set-DemoActivityControlFabric -Config $Config -Name $name -Mode $mode -Setting $runbookSetting -Token $token -Confirm:$false)
        }
    }
    catch {
        $fabric = @(New-DemoResult -CheckId 'CONTROL.FABRIC.NOTEBOOK' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('{0} wasn''t put in Fabric: {1}' -f $name.Notebook, (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/deploy.ps1 again; it sets the session control up each time.' -DocUrl $doc)
    }
    $converted = @(ConvertTo-DemoControlDeployResult -Result $fabric)
    foreach ($item in $converted) {
        $results.Add($item)
    }
    $notebookResult = @($converted | Where-Object { [string]$_.checkId -eq 'CONTROL.FABRIC.NOTEBOOK' }) | Select-Object -Last 1
    $placed = $null -ne $notebookResult -and [string]$notebookResult.status -eq 'Pass'
    $demoWorkspace = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceName')
    $placeMode = if ($null -ne $notebookResult) { [string](Get-DemoMemberValue -InputObject $notebookResult.evidence -Name 'mode') } else { '' }
    $placeFolder = if ($null -ne $notebookResult) { [string](Get-DemoMemberValue -InputObject $notebookResult.evidence -Name 'folder') } else { '' }
    $where = if ($placeMode -eq 'private') { 'the workspace "{0}"' -f $name.FabricWorkspace } elseif ($placeFolder) { 'the folder "{0}" of the workspace "{1}"' -f $placeFolder, $demoWorkspace } else { 'the workspace "{0}"' -f $demoWorkspace }
    $open = @($converted | Where-Object { [string]$_.status -eq 'Warning' })
    if ($placed -and -not $open.Count) {
        $message = 'Run all is ready: open {0} in {1} and select Run all. It runs the whole session and stops it.' -f $name.Notebook, $where
        $status = 'Pass'
    }
    elseif ($placed) {
        $message = '{0} is in {1}; {2} item(s) need attention: {3}' -f $name.Notebook, $where, $open.Count, (@($open | Select-Object -First 2 | ForEach-Object { [string]$_.message }) -join ' ')
        $status = 'Warning'
    }
    else {
        $message = '{0} isn''t in Fabric yet: {1}' -f $name.Notebook, (@($open | Select-Object -First 2 | ForEach-Object { [string]$_.message }) -join ' ')
        $status = 'Warning'
    }
    $fix = [string](@($open | ForEach-Object { [string]$_.remediation } | Where-Object { $_ }) | Select-Object -First 1)
    $results.Add((New-DemoResult -CheckId 'DEPLOY.CONTROL' -Area 'workload' -Target 'fabric' -Status $status -Message $message -Evidence ([ordered]@{ notebook = $name.Notebook; place = $where; resourceGroup = $name.ResourceGroup; ready = ($status -eq 'Pass') }) -Remediation $fix -DocUrl $doc))
    Set-DemoProgressStep -Path $ProgressPath -Id 'Control' -State 'Done' -Status $status -Message $(if ($fix) { '{0} {1}' -f $message, $fix } else { $message }) -MaxLength 1200
    if ($status -ne 'Pass') {
        Write-DemoLog -Level Warning -Message ('The session control: {0}' -f $message)
    }
    return $results.ToArray()
}

function Get-DemoControlDeployNote {
    <#
    .SYNOPSIS
    DONE's line about the session control (ADR 0026): where Run all is, or what it still needs, from this run's
    DEPLOY.CONTROL and the control's role Warnings (an Owner runs ./scripts/grant-safety-stop.ps1 once). Empty when this
    run didn't reach the control. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $control = @($all | Where-Object { [string]$_.checkId -eq 'DEPLOY.CONTROL' }) | Select-Object -Last 1
    $roles = @($all | Where-Object { [string]$_.checkId -like 'CONTROL.ROLE.*' -and [string]$_.status -eq 'Warning' })
    # The Azure part's other Warnings, such as a template the tenant refused; the runbooks' have their own line
    # (Get-DemoActivityControlRunbookNote), and the Fabric part's are in DEPLOY.CONTROL.
    $azure = @($all | Where-Object { [string]$_.checkId -like 'CONTROL.*' -and [string]$_.checkId -notlike 'CONTROL.ROLE.*' -and [string]$_.checkId -notlike 'CONTROL.FABRIC.*' -and [string]$_.checkId -ne 'CONTROL.RUNBOOKS' -and [string]$_.status -eq 'Warning' })
    if ($null -eq $control -and $roles.Count -eq 0 -and $azure.Count -eq 0) {
        return ''
    }
    $text = if ($null -ne $control) { [string]$control.message } else { 'The session control''s notebook isn''t in Fabric yet; the next ./scripts/deploy.ps1 puts it there.' }
    if ($null -ne $control -and [string]$control.status -ne 'Pass' -and [string]$control.remediation) {
        $text = '{0} {1}' -f $text, [string]$control.remediation
    }
    if ($azure.Count) {
        $first = $azure[0]
        $text = '{0} In Azure: {1}{2}' -f $text, [string]$first.message, $(if ([string]$first.remediation) { ' ' + [string]$first.remediation } else { '' })
    }
    if ($roles.Count) {
        $grant = [string](@($roles | ForEach-Object { [string]$_.remediation } | Where-Object { $_ }) | Select-Object -First 1)
        $text = '{0} Until its roles are granted, Run all runs a session without what they allow (T4''s read replica, the busy marker, the history''s metrics, or the session itself): {1}' -f $text, $(if ($grant) { $grant } else { 'an Owner of the subscription runs ./scripts/grant-safety-stop.ps1 once.' })
    }
    return (ConvertTo-DemoPlainText -Value $text).Trim()
}
