function Resolve-DemoT3FreeOfferError {
    <#
    .SYNOPSIS
    Decides whether a failed deployment failed because Azure rejected the Azure SQL Database free offer for T3.

    .DESCRIPTION
    Pure: no Azure calls. deploy.ps1 (Phase 13) passes the error text of a failed deployment, for example the
    standard error of 'az deployment sub create'. When this returns IsFreeOfferError, deploy.ps1 deploys
    again with t3UseFreeLimit false, so T3 falls back to regular General Purpose serverless, and it records
    the returned Warning (ADR 0016, C7).

    Microsoft Learn doesn't list the error codes for an unavailable free offer (the free-offer page and FAQ,
    checked 2026-10-20), so the match is deliberately conservative: an error detail must name the offer
    itself - the useFreeLimit or freeLimitExhaustionBehavior property, or a phrase such as "free database",
    "free offer", "free limit", or "paid database to free database". A generic code such as
    ProvisioningDisabled or DeploymentFailed alone never matches. A false match would be expensive: an
    existing database can't be converted to the free offer, so T3 would stay on regular pricing until
    'stop-demo.ps1 -RemoveT3' recreates it. A missed match only fails the deployment, with Azure's own
    error. Known example (community report, 2026-05): "ProvisioningDisabled: Cannot update paid database to
    free database."

    Returns IsFreeOfferError, Code (the closest error code, or empty), Message (redacted, at most 300
    characters), and Result (a T3.FREEOFFER Warning when IsFreeOfferError, otherwise $null).

    .PARAMETER ErrorText
    The error text: Azure CLI output, a deployment error's JSON, or an exception message.

    .EXAMPLE
    $verdict = Resolve-DemoT3FreeOfferError -ErrorText $deployment.StdErr
    if ($verdict.IsFreeOfferError) { $parameters.parameters.t3UseFreeLimit.value = $false }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $ErrorText
    )

    $offerPattern = '(?i)\buseFreeLimit\b|\bfreeLimitExhaustionBehavior\b|\bfree[ -](?:database|db|offer|limit|tier|amount)s?\b|paid database to free database'
    $text = [string]$ErrorText
    $verdict = [pscustomobject]@{
        PSTypeName       = 'DbHubDemo.T3FreeOfferError'
        IsFreeOfferError = $false
        Code             = ''
        Message          = ''
        Result           = $null
    }
    if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch $offerPattern) {
        return $verdict
    }

    # Collect (code, message) pairs from JSON error details and from the Azure CLI's "(Code) Message" lines.
    $pairs = [System.Collections.Generic.List[object]]::new()
    $jsonPairs = '"code"\s*:\s*"(?<code>[^"]*)"\s*,\s*(?:"target"\s*:\s*"[^"]*"\s*,\s*)?"message"\s*:\s*"(?<message>(?:[^"\\]|\\.)*)"'
    foreach ($match in [regex]::Matches($text, $jsonPairs)) {
        $pairs.Add([pscustomobject]@{ Code = $match.Groups['code'].Value; Message = [regex]::Unescape($match.Groups['message'].Value) })
    }
    foreach ($match in [regex]::Matches($text, '(?m)\((?<code>[A-Za-z][A-Za-z0-9_.]*)\)\s*(?<message>[^\r\n]+)')) {
        $pairs.Add([pscustomobject]@{ Code = $match.Groups['code'].Value; Message = $match.Groups['message'].Value })
    }
    foreach ($match in [regex]::Matches($text, '(?m)Code:\s*(?<code>[A-Za-z][A-Za-z0-9_.]*)\s*\r?\n\s*Message:\s*(?<message>[^\r\n]+)')) {
        $pairs.Add([pscustomobject]@{ Code = $match.Groups['code'].Value; Message = $match.Groups['message'].Value })
    }

    $hit = $pairs | Where-Object { $_.Message -match $offerPattern -or $_.Code -match $offerPattern } | Select-Object -First 1
    if (-not $hit) {
        # The offer is named, but not inside a recognizable error detail: use the line that names it.
        $line = @($text -split '\r?\n' | Where-Object { $_ -match $offerPattern }) | Select-Object -First 1
        $hit = [pscustomobject]@{ Code = ''; Message = $line }
    }

    $message = ((Protect-DemoText -Text ([string]$hit.Message)) -replace '\s+', ' ').Trim()
    if ($message.Length -gt 300) {
        $message = $message.Substring(0, 300) + '...'
    }
    $verdict.IsFreeOfferError = $true
    $verdict.Code = [string]$hit.Code
    $verdict.Message = $message
    $codeText = if ($verdict.Code) { '{0}: ' -f $verdict.Code } else { '' }
    $verdict.Result = New-DemoResult -CheckId 'T3.FREEOFFER' -Area 't3' -Target 'T3' -Status 'Warning' -Message ('Azure rejected the Azure SQL Database free offer for T3 ({0}{1}), so T3 is deployed as regular General Purpose serverless instead.' -f $codeText, $message) -Evidence @{ useFreeLimit = $false; code = $verdict.Code; fallback = $true } -Remediation 'The estimate without the offer applies. To retry the offer later, free a slot (at most 10 free databases per subscription, all in one region), then run stop-demo.ps1 -RemoveT3; the next start recreates T3.' -DocUrl 'https://learn.microsoft.com/azure/azure-sql/database/free-offer'
    return $verdict
}
