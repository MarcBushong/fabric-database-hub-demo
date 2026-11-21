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
