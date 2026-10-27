function Get-DemoRetailPrice {
    <#
    .SYNOPSIS
    Queries the public Azure Retail Prices API and returns every matching price item.

    .DESCRIPTION
    Follows NextPageLink, so broad filters return every page (capped at 20 pages). The API is public
    and needs no authentication; this function makes no call to Azure Resource Manager.

    .EXAMPLE
    Get-DemoRetailPrice -Filter "serviceName eq 'Azure Bastion' and armRegionName eq 'westus3'"
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Filter,

        [ValidatePattern('^[A-Z]{3}$')]
        [string] $CurrencyCode = 'USD'
    )

    $uri = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode={0}&$filter={1}' -f $CurrencyCode, [uri]::EscapeDataString($Filter)
    $items = [System.Collections.Generic.List[object]]::new()
    $pages = 0
    while ($uri -and $pages -lt 20) {
        $response = Invoke-DemoRetailPriceRequest -Uri $uri
        foreach ($item in @($response.Items)) {
            $items.Add($item)
        }
        $uri = $response.NextPageLink
        $pages++
    }

    return $items.ToArray()
}
