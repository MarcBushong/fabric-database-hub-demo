# deploy.ps1's session control (ADR 0026, 2026-11-14): the control notebook's Run all is part of every deployment, a new
# one and an existing one, so deploy.ps1 sets the control up, adopts one set up earlier as it is, and says what it did.

# The session control's Azure steps before Run all's webhook (Invoke-DemoActivityControlSetup), in its order. A Warning in
# one of them in this run means its setup stopped there: ConvertTo-DemoControlDeployResult made its Fail a Warning, and
# these steps have no other Warning (F28, 2026-11-21). CONTROL.MODE's can be a note too, so it counts only when nothing
# after it ran.
$script:ControlSetupStopIds = @('CONTROL.SETUP', 'CONTROL.PROVIDER', 'CONTROL.GROUP', 'CONTROL.RESOURCES')

function Get-DemoControlSetupStop {
    <#
    .SYNOPSIS
    The result of this run's session control setup where it stopped before the runbooks (F28, 2026-11-21): a Warning from
    CONTROL.SETUP, CONTROL.PROVIDER, CONTROL.GROUP, or CONTROL.RESOURCES, or from CONTROL.MODE when no step after it ran.
    $null when it didn't stop there, or didn't run in this run. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $ids = @($all | ForEach-Object { [string]$_.checkId })
    foreach ($item in $all) {
        $id = [string]$item.checkId
        if ([string]$item.status -ne 'Warning') {
            continue
        }
        if ($id -in $script:ControlSetupStopIds -or ($id -eq 'CONTROL.MODE' -and $ids -notcontains 'CONTROL.PROVIDER')) {
            return $item
        }
    }
    return $null
}

function Get-DemoControlGap {
    <#
    .SYNOPSIS
    What Run all still lacks in Azure after this run's setup of the session control (F28, 2026-11-21): its Azure Automation
    account, the control vault, a webhook that starts DbHub-Control whose URL the vault keeps, or the session's status secret,
    which Run all reads first. Returns Missing (Account, Vault, Webhook, StatusSecret, or '' when nothing is missing or it
    couldn't be read),
    Present (all of them read and there), Message (what's missing and why), Remediation, CauseId (the step of this run's
    setup that says why, from -PriorResult), and Problem (the same for the control notebook, with when deploy.ps1 found it).
    A read of metadata through Azure Resource Manager, never a secret's value; never throws. Internal.

    .DESCRIPTION
    Live, 2026-11-21 (dbhubra): Azure refused the control's Automation account (the subscription's quota for Automation
    accounts in westus3 was used up), but created its identity and vault, so the notebook was put in Fabric and DEPLOY.CONTROL
    said "Run all is ready", and Run all then said the user needed Key Vault Secrets User. Only an answer that something isn't
    there (HTTP 404) counts as missing; a read that fails otherwise changes nothing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [AllowEmptyCollection()]
        [object[]] $PriorResult = @(),

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $none = [pscustomobject]@{ Missing = ''; Present = $false; Message = ''; Remediation = ''; CauseId = ''; Problem = '' }
    $missing = ''
    $present = $false
    try {
        $account = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $Name.AutomationAccountId -ApiVersion (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Automation/automationAccounts'))
        if ($account.Missing) {
            $missing = 'Account'
        }
        elseif ($account.Ok -and (Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $Name.KeyVaultId -ApiVersion '2026-02-01')).Missing) {
            $missing = 'Vault'
        }
        elseif ($account.Ok) {
            $hooks = Get-DemoActivityControlWebhook -Name $Name
            $live = @($hooks.Webhooks | Where-Object { $_.Enabled -and ($null -eq $_.ExpiryUtc -or $_.ExpiryUtc -gt $NowUtc) })
            if (($hooks.Read -and $live.Count -eq 0) -or $hooks.SecretMissing) {
                $missing = 'Webhook'
            }
            else {
                $status = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $Name.StatusSecretId -ApiVersion '2026-02-01')
                if ($status.Missing) {
                    $missing = 'StatusSecret'
                }
                else {
                    $present = [bool]($hooks.Read -and $hooks.SecretExists -and $status.Ok)
                }
            }
        }
    }
    catch {
        Write-DemoLog -Level Warning -Message ('Whether the session control has what Run all needs couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        return $none
    }
    if (-not $missing) {
        $none.Present = $present
        return $none
    }
    $what = switch ($missing) {
        'Account' { 'the session control''s Azure Automation account {0} isn''t in {1}' -f $Name.AutomationAccount, $Name.ResourceGroup }
        'Vault' { 'the control vault {0} isn''t in {1}' -f $Name.KeyVault, $Name.ResourceGroup }
        'Webhook' { 'the session control''s Azure Automation account {0} has no webhook that starts {1}, or the control vault {2} doesn''t keep its URL ({3})' -f $Name.AutomationAccount, $Name.ControlRunbook, $Name.KeyVault, $Name.Secret }
        default { 'the control vault {0} has no session status ({1}), which Run all reads first' -f $Name.KeyVault, $Name.StatusSecret }
    }
    # Why: where this run's setup stopped, or else the later step that didn't finish.
    $cause = Get-DemoControlSetupStop -Result $PriorResult
    $stopped = $null -ne $cause
    if (-not $stopped) {
        $cause = @($PriorResult | Where-Object { $null -ne $_ -and [string]$_.checkId -in 'CONTROL.RUNBOOKS', 'CONTROL.WEBHOOK', 'CONTROL.SECRETS' -and [string]$_.status -eq 'Warning' }) | Select-Object -First 1
    }
    $location = [string]$Config['location']
    $quota = if ($null -ne $cause) { Get-DemoAutomationQuotaText -Text ([string]$cause.message) -Location $location } else { $null }
    if ($null -ne $quota) {
        $message = '{0}: Azure refused it because {1}' -f $what, $quota.Reason
        $fix = $quota.Remediation
        $why = ': Azure refused it because {0}' -f $quota.Reason
    }
    elseif ($null -ne $cause) {
        $step = if ($stopped) { 'this run''s setup of the session control stopped at {0}' -f [string]$cause.checkId } else { 'this run''s {0} says' -f [string]$cause.checkId }
        $message = '{0}; {1}: {2}' -f $what, $step, (Get-DemoDeploymentErrorText -Text ([string]$cause.message) -MaxLength 400).TrimEnd('.')
        $fix = if ([string]$cause.remediation) { [string]$cause.remediation } else { 'Run ./scripts/deploy.ps1 again; it sets the session control up each time.' }
        $why = ' ({0} {1}; DONE and the status page of deploy.ps1 say why)' -f $(if ($stopped) { 'its setup stopped at' } else { 'see' }), [string]$cause.checkId
    }
    else {
        $message = $what
        $fix = 'Run ./scripts/deploy.ps1 again; it sets the session control up each time.'
        $why = ''
    }
    $found = $NowUtc.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    $fix = ([string]$fix -replace '\s*Meanwhile \./scripts/start-demo\.ps1 runs a session from this PC\.\s*$', '').Trim()
    return [pscustomobject]@{
        Missing     = $missing
        Present     = $false
        Message     = $message
        Remediation = '{0} Meanwhile ./scripts/start-demo.ps1 runs a session from this PC.' -f $fix
        CauseId     = $(if ($null -ne $cause) { [string]$cause.checkId } else { '' })
        Problem     = './scripts/deploy.ps1 found on {0} UTC that Run all can''t start a session: {1}{2}. Fix: {3} Meanwhile ./scripts/start-demo.ps1 runs a session from a PC, and ./scripts/stop-demo.ps1 stops the demo.' -f $found, $what, $why, $fix
    }
}

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
    The status page's "Session control" row follows both parts, and DEPLOY.CONTROL says where Run all is. After the
    Fabric part, Invoke-DemoFabricOwnershipStep records the workspaces this environment uses on its resource group and
    checks that no other environment records them (DEPLOY.FABRIC.SHARED, 2026-11-17).
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

        # This run's results so far (F28, 2026-11-21): the Fabric part reads where the Azure part's setup stopped from them.
        [AllowEmptyCollection()]
        [object[]] $PriorResult = @(),

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
    # What Run all still lacks in Azure, and where this run's setup of the session control stopped, if it did (F28,
    # 2026-11-21): live on dbhubra, Azure refused the control's Automation account, the notebook was put in Fabric anyway,
    # and DEPLOY.CONTROL said "Run all is ready".
    $stop = Get-DemoControlSetupStop -Result $PriorResult
    $gap = Get-DemoControlGap -Config $Config -Name $name -PriorResult $PriorResult
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
            $fabric = @(Set-DemoActivityControlFabric -Config $Config -Name $name -Mode $mode -Setting $runbookSetting -Token $token -ControlProblem $gap.Problem -Confirm:$false)
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
    $fix = [string](@($open | ForEach-Object { [string]$_.remediation } | Where-Object { $_ }) | Select-Object -First 1)
    $ready = $false
    $cause = ''
    if ($gap.Missing) {
        # Run all can't start a session (F28): never "ready", whatever Fabric has.
        $message = if ($placed) { '{0} is in {1}, but Run all can''t start a session yet: {2}.' -f $name.Notebook, $where, $gap.Message } else { '{0} isn''t in Fabric yet, and Run all can''t start a session: {1}.' -f $name.Notebook, $gap.Message }
        $status = 'Warning'
        $fix = $gap.Remediation
        $cause = $gap.CauseId
    }
    elseif ($null -ne $stop) {
        # This run's setup stopped before the runbooks, but what an earlier run set up may still start a session (F28).
        $ready = $placed -and $gap.Present -and -not $open.Count
        $lead = if ($ready) { '{0} is in {1}, and Run all starts a session with the session control an earlier ./scripts/deploy.ps1 set up in {2}' -f $name.Notebook, $where, $name.ResourceGroup } elseif ($placed) { '{0} is in {1}, but Run all may not start a session' -f $name.Notebook, $where } else { '{0} isn''t in Fabric yet' -f $name.Notebook }
        $message = '{0}: this run''s setup of the session control stopped at {1}: {2}.{3}' -f $lead, [string]$stop.checkId, (Get-DemoDeploymentErrorText -Text ([string]$stop.message) -MaxLength 400).TrimEnd('.'), $(if ($open.Count) { ' ' + (@($open | Select-Object -First 2 | ForEach-Object { [string]$_.message }) -join ' ') } else { '' })
        $status = 'Warning'
        $fix = if ([string]$stop.remediation) { [string]$stop.remediation } else { 'Run ./scripts/deploy.ps1 again; it sets the session control up each time.' }
        if (-not $ready -and $fix -notmatch 'start-demo\.ps1') {
            $fix = '{0} Meanwhile ./scripts/start-demo.ps1 runs a session from this PC.' -f $fix
        }
        $cause = [string]$stop.checkId
    }
    elseif ($placed -and -not $open.Count) {
        $message = 'Run all is ready: open {0} in {1} and select Run all. It runs the whole session and stops it.' -f $name.Notebook, $where
        $status = 'Pass'
        $ready = $true
    }
    elseif ($placed) {
        $message = '{0} is in {1}; {2} item(s) need attention: {3}' -f $name.Notebook, $where, $open.Count, (@($open | Select-Object -First 2 | ForEach-Object { [string]$_.message }) -join ' ')
        $status = 'Warning'
    }
    else {
        $message = '{0} isn''t in Fabric yet: {1}' -f $name.Notebook, (@($open | Select-Object -First 2 | ForEach-Object { [string]$_.message }) -join ' ')
        $status = 'Warning'
    }
    $results.Add((New-DemoResult -CheckId 'DEPLOY.CONTROL' -Area 'workload' -Target 'fabric' -Status $status -Message $message -Evidence ([ordered]@{ notebook = $name.Notebook; place = $where; resourceGroup = $name.ResourceGroup; ready = $ready; missing = $gap.Missing; cause = $cause }) -Remediation $fix -DocUrl $doc))
    # The Fabric workspaces this environment uses, recorded on its resource group for destroy.ps1, and whether another
    # environment uses the same ones (2026-11-17); a Warning shows on the status page's row too. Never a Fail.
    $ownership = $null
    try {
        $ownership = Invoke-DemoFabricOwnershipStep -Config $Config -Result $converted
    }
    catch {
        $ownership = New-DemoResult -CheckId 'DEPLOY.FABRIC.SHARED' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('The Fabric workspaces this environment uses couldn''t be recorded: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/deploy.ps1 again.'
    }
    $row = if ($fix) { '{0} {1}' -f $message, $fix } else { $message }
    $rowStatus = $status
    if ($null -ne $ownership) {
        $results.Add($ownership)
        if ([string]$ownership.status -eq 'Warning') {
            $rowStatus = 'Warning'
            $row = '{0} {1} {2}' -f $row, [string]$ownership.message, [string]$ownership.remediation
            Write-DemoLog -Level Warning -Message ([string]$ownership.message)
        }
    }
    Set-DemoProgressStep -Path $ProgressPath -Id 'Control' -State 'Done' -Status $rowStatus -Message $row.Trim() -MaxLength 1200
    if ($status -ne 'Pass') {
        Write-DemoLog -Level Warning -Message ('The session control: {0}' -f $message)
    }
    return $results.ToArray()
}

function Get-DemoControlDeployNote {
    <#
    .SYNOPSIS
    DONE's line about the session control (ADR 0026): where Run all is, or what it still needs, from this run's
    DEPLOY.CONTROL and the control's role Warnings (an Owner runs ./scripts/grant-safety-stop.ps1 once). -OmitGrant leaves
    the roles' part out when DONE's first note says it already (Get-DemoOwnerGrantNote). Empty when this run didn't reach
    the control. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [switch] $OmitGrant
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $control = @($all | Where-Object { [string]$_.checkId -eq 'DEPLOY.CONTROL' }) | Select-Object -Last 1
    $roles = @($all | Where-Object { [string]$_.checkId -like 'CONTROL.ROLE.*' -and [string]$_.status -eq 'Warning' })
    # The step DEPLOY.CONTROL already names as the cause (F28, 2026-11-21), which isn't said twice.
    $cause = if ($null -ne $control) { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $control -Name 'evidence') -Name 'cause') } else { '' }
    # The Azure part's other Warnings, such as a template the tenant refused; the runbooks' have their own line
    # (Get-DemoActivityControlRunbookNote), and the Fabric part's are in DEPLOY.CONTROL.
    $azure = @($all | Where-Object { [string]$_.checkId -like 'CONTROL.*' -and [string]$_.checkId -notlike 'CONTROL.ROLE.*' -and [string]$_.checkId -notlike 'CONTROL.FABRIC.*' -and [string]$_.checkId -ne 'CONTROL.RUNBOOKS' -and [string]$_.status -eq 'Warning' -and (-not $cause -or [string]$_.checkId -ne $cause) })
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
    if ($roles.Count -and -not $OmitGrant) {
        $grant = [string](@($roles | ForEach-Object { [string]$_.remediation } | Where-Object { $_ }) | Select-Object -First 1)
        $text = '{0} Until its roles are granted, Run all runs a session without what they allow (T4''s read replica, the busy marker, the history''s metrics, or the session itself): {1}' -f $text, $(if ($grant) { $grant } else { 'an Owner of the subscription runs ./scripts/grant-safety-stop.ps1 once.' })
    }
    return (ConvertTo-DemoPlainText -Value $text).Trim()
}
