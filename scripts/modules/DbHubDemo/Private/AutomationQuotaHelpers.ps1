# The subscription's quota for Azure Automation accounts (F28, 2026-11-21): every deployment has two, the session control's
# (aa-<prefix>-control, ADR 0026) and the nightly safety stop's (aa-<prefix>-<environment>-safetystop, ADR 0024), both in the
# configured region, and Azure limits how many active Automation accounts a subscription has in a region, by offer:
# https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#automation-limits
# https://learn.microsoft.com/azure/automation/automation-limits-quotas (checked 2026-11-21)

function Get-DemoAutomationQuotaText {
    <#
    .SYNOPSIS
    When an error from Azure says the subscription's quota for Automation accounts in the region is used up, what that means
    and the fix, in plain words: Reason (a clause) and Remediation. $null for any other error. Pure. Internal.

    .DESCRIPTION
    Live, 2026-11-21 (dbhubra, in a subscription with 10 Automation accounts in westus3): "Conflict ... The operation could not
    be completed because it exceeded your quota for Automation accounts in your subscription in the region." The fix frees an
    account in the region, which ./scripts/destroy.ps1 does for an environment's two, or raises the quota (the Azure portal's
    Quotas page or a support request), which Free Trial and Azure for Students subscriptions can't.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [AllowEmptyString()]
        [string] $Location = ''
    )

    if ([string]$Text -notmatch '(?i)quota\s+for\s+(?:the\s+)?(?:Azure\s+)?Automation\s+accounts?') {
        return $null
    }
    $region = if ($Location) { $Location } else { 'the region' }
    return [pscustomobject]@{
        Reason      = 'the subscription''s quota for Azure Automation accounts in {0} is used up' -f $region
        Remediation = 'Free an Automation account in {0}: ./scripts/destroy.ps1 on a demo environment you no longer use deletes its two, the session control''s and the nightly safety stop''s. Or raise the subscription''s quota for Automation accounts in {0} (the Azure portal''s Quotas page, provider Automation accounts, or a support request; Free Trial and Azure for Students subscriptions can''t be raised). Then run ./scripts/deploy.ps1 again.' -f $region
    }
}

# Learn's default quota of active Automation accounts in a subscription in a region, by the subscription's offer as its
# quotaId (Subscriptions - Get's subscriptionPolicies.quotaId; the offers' IDs from "Understand Cost Management data",
# https://learn.microsoft.com/azure/cost-management-billing/costs/understand-cost-mgt-data, checked 2026-11-22). Learn
# names pay-as-you-go's "Pay-as-you-go_2014-09-01"; Azure answers "PayAsYouGo_2014-09-01". MSDNDevTest_2014-09-01 is the
# Dev/Test offer of an Enterprise Agreement (10) and of pay-as-you-go (2) alike, so it isn't here. Internal_2014-09-01,
# Microsoft's own subscriptions, isn't on Learn: 10, observed live on 2026-11-21 (the 11th account in westus3 refused).
$script:AutomationAccountDefaultQuota = @{
    'EnterpriseAgreement_2014-09-01' = @(10, 'an Enterprise Agreement or Microsoft Customer Agreement')
    'CSP_2015-05-01'                 = @(10, 'a Cloud Solution Provider')
    'CSP_MG_2017-12-01'              = @(10, 'a Cloud Solution Provider')
    'CSPDEVTEST_2018-05-01'          = @(10, 'a Cloud Solution Provider')
    'Internal_2014-09-01'            = @(10, 'a Microsoft internal')
    'PayAsYouGo_2014-09-01'          = @(2, 'a pay-as-you-go')
    'Pay-as-you-go_2014-09-01'       = @(2, 'a pay-as-you-go')
    'MSDN_2014-09-01'                = @(2, 'a Visual Studio (MSDN)')
    'MPN_2014-09-01'                 = @(2, 'a Microsoft Cloud Partner Program')
    'AzurePass_2014-09-01'           = @(2, 'an Azure Pass')
    'Sponsored_2016-01-01'           = @(2, 'an Azure Sponsorship')
    'FreeTrial_2014-09-01'           = @(1, 'a Free Trial')
    'AzureForStudents_2018-01-01'    = @(1, 'an Azure for Students')
    'DreamSpark_2015-02-01'          = @(1, 'an Azure for Students Starter')
    'AzureInOpen_2014-09-01'         = @(1, 'an Azure in Open')
}

function Get-DemoAutomationAccountLimit {
    <#
    .SYNOPSIS
    The subscription's quota of Azure Automation accounts in a region (F30, 2026-11-22): -Quota (automationAccountQuota, a
    raised quota you know) when set, else Learn's default for the offer (-QuotaId). Returns Limit (0: unknown), Default
    (the offer's, 0 when unknown), Offer (words for a message), Source (configuration, offer, or unknown), and Fixed (an
    offer whose quota can't be raised: Free Trial, Azure for Students, Azure in Open). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $QuotaId = '',

        [int] $Quota = 0
    )

    $known = if ($QuotaId -and $script:AutomationAccountDefaultQuota.ContainsKey($QuotaId)) { $script:AutomationAccountDefaultQuota[$QuotaId] } else { $null }
    $default = if ($null -ne $known) { [int]$known[0] } else { 0 }
    $offer = if ($null -ne $known) { '{0} subscription' -f $known[1] } elseif ($QuotaId) { 'a subscription whose offer is {0}' -f $QuotaId } else { 'a subscription whose offer couldn''t be read' }
    $source = if ($Quota -gt 0) { 'configuration' } elseif ($default -gt 0) { 'offer' } else { 'unknown' }
    return [pscustomobject]@{
        Limit   = $(if ($Quota -gt 0) { $Quota } else { $default })
        Default = $default
        Offer   = $offer
        Source  = $source
        Fixed   = $default -eq 1
    }
}

function Get-DemoAutomationAccountQuotaResult {
    <#
    .SYNOPSIS
    PREFLIGHT.P3.AUTOMATION (F30, 2026-11-22): whether the Azure Automation accounts this deployment adds fit the
    subscription's quota in the configured region. Every environment has two, the session control's
    (aa-<prefix>-control, in rg-<prefix>-control, which environments with one prefix share) and the nightly safety stop's
    (aa-<prefix>-<environment>-safetystop), both in the configured region. Returns one result; never throws. Internal.

    .DESCRIPTION
    Live, 2026-11-21 (dbhubra): a new deployment in a subscription with 10 accounts in westus3 got neither account, and
    only Warnings said so. Learn: at most 10 active accounts in a subscription in a region for Enterprise and CSP
    subscriptions, 2 for pay-as-you-go, Sponsored, MSDN, MPN, and Azure Pass ones, raisable, and 1 for Free Trial, Azure for
    Students, and Azure in Open ones, which can't be raised.
    - What this deployment adds: each account Azure Resource Manager answers isn't there (HTTP 404). An update whose two
      accounts are there adds none and passes, with nothing more read.
    - What the subscription has in the region: an Azure Resource Graph count, which can lag a create or a delete by a few
      minutes.
    - The quota: automationAccountQuota when set, else Learn's default for the subscription's offer. A count above that
      default means the quota was raised, by how much isn't readable (the Quotas API doesn't cover Automation accounts),
      so it's a Warning with the setting that says it.
    - Fail only when a new deployment (no demo resource group yet) adds an account that doesn't fit: nothing is created.
      For an existing environment it's a Warning, so an update is never stopped here: the session control and the
      nightly safety stop then say what's missing (DEPLOY.CONTROL, SAFETYSTOP.RESOURCES).
    Sources: https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#automation-limits,
    https://learn.microsoft.com/azure/automation/automation-subscription-limits-faq,
    https://learn.microsoft.com/azure/automation/automation-limits-quotas
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $checkId = 'PREFLIGHT.P3.AUTOMATION'
    $doc = 'https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#automation-limits'
    $location = [string]$Config['location']
    $subscriptionId = [string]$Config['subscriptionId']
    $result = { param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation) New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'subscription' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $doc }
    $control = Get-DemoActivityControlName -Config $Config
    $safety = Get-DemoSafetyStopName -Config $Config
    $apiVersion = Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Automation/automationAccounts'
    $accounts = @(foreach ($item in @(
                [pscustomobject]@{ Name = $control.AutomationAccount; Id = $control.AutomationAccountId; For = 'the session control' }
                [pscustomobject]@{ Name = $safety.AutomationAccount; Id = $safety.AutomationAccountId; For = 'the nightly safety stop' })) {
            $read = Invoke-DemoActivityControlArm -SubscriptionId $subscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $item.Id -ApiVersion $apiVersion)
            [pscustomobject]@{ Name = $item.Name; For = $item.For; State = $(if ($read.Ok) { 'there' } elseif ($read.Missing) { 'missing' } else { 'unread' }) }
        })
    $evidence = [ordered]@{ location = $location; accounts = @($accounts | ForEach-Object { '{0}: {1}' -f $_.Name, $_.State }) }
    $adding = @($accounts | Where-Object { $_.State -eq 'missing' })
    $unread = @($accounts | Where-Object { $_.State -eq 'unread' })
    $evidence['adds'] = $adding.Count
    if ($adding.Count + $unread.Count -eq 0) {
        return (& $result 'Pass' ('This deployment adds no Azure Automation account: {0} and {1} are there.' -f $control.AutomationAccount, $safety.AutomationAccount) $evidence '')
    }
    $what = @(@($adding) + @($unread) | ForEach-Object { '{0} (for {1})' -f $_.Name, $_.For }) -join ' and '
    $later = 'If Azure refuses one, DEPLOY.CONTROL or SAFETYSTOP.RESOURCES says so, with the fix.'

    # What the subscription has in the region.
    $count = Invoke-DemoHubResourceGraph -SubscriptionId $subscriptionId -Query ("resources | where type =~ 'microsoft.automation/automationaccounts' and location =~ '{0}' | summarize total = count()" -f ($location -replace "'", ''))
    if (-not $count.Succeeded) {
        return (& $result 'Warning' ('The subscription''s Azure Automation accounts in {0} couldn''t be counted ({1}), so whether this deployment''s {2} fit its quota there isn''t known.' -f $location, ([string]$count.Error).TrimEnd('.'), $what) $evidence ('Nothing to do now. {0}' -f $later))
    }
    $row = @($count.Rows) | Select-Object -First 1
    $total = if ($null -ne $row) { [int](Get-DemoMemberValue -InputObject $row -Name 'total') } else { 0 }
    $evidence['existing'] = $total

    # Its quota there.
    $quotaId = Get-DemoSubscriptionQuotaId -Config $Config
    $configured = if ($Config.Contains('automationAccountQuota') -and $null -ne $Config['automationAccountQuota']) { [int]$Config['automationAccountQuota'] } else { 0 }
    $limit = Get-DemoAutomationAccountLimit -QuotaId $quotaId -Quota $configured
    $evidence['quotaId'] = $quotaId
    $evidence['quota'] = $limit.Limit
    $evidence['quotaSource'] = $limit.Source
    $has = 'The subscription has {0} Azure Automation account(s) in {1}' -f $total, $location
    $needed = $total + $adding.Count
    $atMost = $needed + $unread.Count
    $setQuota = 'Set automationAccountQuota in your configuration to the subscription''s quota for Automation accounts in {0} (the Azure portal''s Quotas page, provider Automation accounts), and preflight checks it.' -f $location
    if ($limit.Source -eq 'unknown') {
        $learn = 'Learn''s defaults are 2 per region for pay-as-you-go, Visual Studio, and other offers, and 10 for Enterprise and CSP ones'
        if ($atMost -le 2) {
            return (& $result 'Pass' ('{0}; this deployment adds {1}, {2} in all, which fits the default quota of every offer that can have two ({3}).' -f $has, $what, $atMost, $learn) $evidence '')
        }
        $offer = if ($quotaId) { 'its offer, {0}' -f $quotaId } else { 'its offer, which couldn''t be read' }
        return (& $result 'Warning' ('{0}, and Learn names no default quota of Automation accounts for {1}, so whether this deployment''s {2} fit isn''t known ({3}).' -f $has, $offer, $what, $learn) $evidence ('{0} {1}' -f $setQuota, $later))
    }
    if ($limit.Source -eq 'offer' -and $total -gt $limit.Default) {
        # More accounts than the offer's default: the quota was raised, to a number this can't read (the Quotas API doesn't
        # cover Automation accounts).
        return (& $result 'Warning' ('{0}, more than the default quota of {1} for {2}, so its quota there was raised, by how much can''t be read: whether this deployment''s {3} fit isn''t known.' -f $has, $limit.Default, $limit.Offer, $what) $evidence ('{0} {1}' -f $setQuota, $later))
    }
    $quota = if ($limit.Source -eq 'configuration') { 'where its quota is {0} (automationAccountQuota)' -f $limit.Limit } else { 'where its quota is {0}, the default for {1}' -f $limit.Limit, $limit.Offer }
    if ($atMost -le $limit.Limit) {
        return (& $result 'Pass' ('{0}, {1}; this deployment adds {2}.' -f $has, $quota, $what) $evidence '')
    }
    $fix = 'Free an Automation account in {0}: ./scripts/destroy.ps1 on a demo environment you no longer use deletes its two (Azure Resource Graph can list a deleted one for a few more minutes). Or raise the subscription''s quota for Automation accounts in {0} (the Azure portal''s Quotas page, provider Automation accounts, or a support request), then set automationAccountQuota in your configuration to it. Or set location to another region. Then run ./scripts/deploy.ps1 again.' -f $location
    if ($limit.Fixed -and $limit.Source -eq 'offer') {
        $fix = '{0} has at most one Automation account per region, in East US, East US 2, West US, North Europe, Southeast Asia, and Japan West 2 only, and its quota can''t be raised, while every demo environment has two: use a pay-as-you-go or Enterprise subscription (Learn: Upgrade your Azure account), then run ./scripts/deploy.ps1 again.' -f ($limit.Offer.Substring(0, 1).ToUpperInvariant() + $limit.Offer.Substring(1))
    }
    if ($needed -le $limit.Limit) {
        # They fit, unless an account that couldn't be read is missing too.
        return (& $result 'Warning' ('{0}, {1}; whether {2} is there couldn''t be read, and if it isn''t, this deployment''s {3} won''t fit.' -f $has, $quota, (@($unread | ForEach-Object { $_.Name }) -join ' and '), $what) $evidence ('Nothing to do now. {0} {1}' -f $later, $fix))
    }
    $newDeployment = Test-DemoAutomationQuotaNewDeployment -Config $Config
    $evidence['newDeployment'] = $newDeployment
    $message = '{0}, {1}, so this deployment''s {2} won''t fit: Azure would refuse {3}.' -f $has, $quota, $what, $(if ($adding.Count + $unread.Count -gt 1) { 'them' } else { 'it' })
    if ($newDeployment -eq $true -and $adding.Count -gt 0) {
        return (& $result 'Fail' ('{0} Nothing was created.' -f $message) $evidence $fix)
    }
    $goesOn = if ($null -eq $newDeployment) { 'Whether this is a new deployment couldn''t be read, so it goes on' } else { 'This environment has deployed before, so its update goes on' }
    return (& $result 'Warning' ('{0} {1}, and DEPLOY.CONTROL and SAFETYSTOP.RESOURCES say what''s missing.' -f $message, $goesOn) $evidence $fix)
}

function Test-DemoAutomationQuotaNewDeployment {
    <#
    .SYNOPSIS
    Whether deploy.ps1 would make a new environment (F30, 2026-11-22): $true when the demo resource group doesn't exist, or
    exists with tags but no stage recorded (DbHubDeployStage: created ahead, never deployed into); $false when a run
    recorded one; $null when that couldn't be read, never a guess. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $group = Get-DemoResourceGroupName -Config $Config
    $exists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $group) -AllowFailure
    $answer = if ($exists.ExitCode -eq 0) { ([string]$exists.StdOut).Trim() } else { '' }
    if ($answer -eq 'false') {
        return $true
    }
    if ($answer -ne 'true') {
        return $null
    }
    # Get-DemoResourceGroupTag answers an empty table when it can't read them, and the template tags every demo group.
    $tags = Get-DemoResourceGroupTag -SubscriptionId $subscriptionId -ResourceGroupName $group
    if ($null -eq $tags -or $tags.Count -eq 0) {
        return $null
    }
    $stage = (Get-DemoDeploymentStateTagName)['Stage']
    return -not ($tags.Contains($stage) -and [string]$tags[$stage])
}
