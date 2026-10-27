function Get-DemoRegionSku {
    <#
    .SYNOPSIS
    Lists the resource SKUs of one region in one read-only call (Compute Resource SKUs REST API).

    .DESCRIPTION
    Internal. GET /subscriptions/<id>/providers/Microsoft.Compute/skus with $filter=location eq '<region>'
    through 'az rest' (Invoke-DemoAz), following nextLink. The records are the ones 'az vm list-skus --all'
    prints (name, resourceType, locationInfo, capabilities, restrictions), but the call takes seconds:
    'az vm list-skus' builds an object for each of the region's SKUs whatever its filter (measured on
    2026-10-22 in westus3: 97-107 seconds for 'az vm list-skus', 7 seconds for this call, about 1,400 SKUs).
    One call serves every VM size and the disk SKUs.
    https://learn.microsoft.com/rest/api/compute/resource-skus/list
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9]+$')]
        [string] $Location
    )

    $skus = [System.Collections.Generic.List[object]]::new()
    $url = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.Compute/skus?api-version=2021-07-01&$filter=location eq ''{1}''' -f $SubscriptionId, $Location.ToLowerInvariant()
    for ($page = 0; $url -and $page -lt 20; $page++) {
        $response = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $url, '--output', 'json') -AsJson
        $pageItems = Get-DemoMemberValue -InputObject $response -Name 'value'
        foreach ($item in @($pageItems)) {
            if ($null -ne $item) {
                $skus.Add($item)
            }
        }
        $url = [string](Get-DemoMemberValue -InputObject $response -Name 'nextLink')
    }
    return $skus.ToArray()
}
