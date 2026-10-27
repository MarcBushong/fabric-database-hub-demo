function Get-DemoPowerBIToken {
    <#
    .SYNOPSIS
    Gets a Power BI REST API token for the signed-in Azure CLI user, as a SecureString.

    .DESCRIPTION
    Gets the token with Get-DemoAccessToken ('az account get-access-token --resource
    https://analysis.windows.net/powerbi/api --subscription <id>' through Invoke-DemoAz), which takes the account
    and tenant from the configured subscription, never from the default one, and checks the token's tid and oid
    claims against the context the subscription guard validated. Call Assert-DemoAzContext first.
    The token is registered for redaction and returned only as a SecureString; it's never written to the console, a
    log, or a file. The function never signs in. configure-powerbi.ps1 uses it for the refresh, Execute Queries, and
    the report checks (Phase 19).

    - Power BI REST API audience: https://learn.microsoft.com/rest/api/power-bi/
    - az account get-access-token: https://learn.microsoft.com/cli/azure/account#az-account-get-access-token

    .EXAMPLE
    $token = Get-DemoPowerBIToken -SubscriptionId $config['subscriptionId']
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId
    )

    $issued = Get-DemoAccessToken -SubscriptionId $SubscriptionId -Resource $script:PowerBITokenResource
    if ($null -eq $issued.Token) {
        throw ("No verified Power BI token is available: {0} Sign in once with 'az login --tenant <tenantId>'; you don't need to change the default subscription." -f $issued.Error)
    }
    return $issued.Token
}
