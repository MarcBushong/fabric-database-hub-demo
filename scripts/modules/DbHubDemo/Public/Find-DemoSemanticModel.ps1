function Find-DemoSemanticModel {
    <#
    .SYNOPSIS
    Finds a semantic model by name in a workspace, read-only, and returns its ID when exactly one matches.

    .DESCRIPTION
    Datasets - Get Datasets In Group (GET /v1.0/myorg/groups/{groupId}/datasets) with a Power BI token from
    Get-DemoPowerBIToken; a semantic model's dataset ID is its Fabric item ID. configure-powerbi.ps1 uses it for
    -CheckModelData and -SkipModel, which check or bind to the deployed SM_DatabaseHub_History without importing it.
    The name comparison ignores case, as Fabric item names do.
    Returns StatusCode (200 when the list was read), Id (empty unless exactly one model matches), Count (the matches),
    and Error.

    https://learn.microsoft.com/rest/api/power-bi/datasets/get-datasets-in-group

    .EXAMPLE
    (Find-DemoSemanticModel -WorkspaceId $workspaceId -Name 'SM_DatabaseHub_History' -Token $powerBIToken).Id
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    $response = Invoke-DemoPowerBIRequest -Method Get -Uri ('{0}/groups/{1}/datasets' -f $script:PowerBIApiBaseUri, $WorkspaceId) -Token $Token
    if ($response.StatusCode -ne 200) {
        return [pscustomobject]@{ StatusCode = $response.StatusCode; Id = ''; Count = 0; Error = (Get-DemoPowerBIErrorText -Response $response) }
    }
    $matched = [System.Collections.Generic.List[object]]::new()
    # Get-DemoMemberValue returns an array as one object: enumerate it directly, not through @().
    foreach ($dataset in (Get-DemoMemberValue -InputObject $response.Body -Name 'value')) {
        $datasetName = Get-DemoMemberValue -InputObject $dataset -Name 'name'
        if ($datasetName -and [string]::Equals([string]$datasetName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matched.Add($dataset)
        }
    }
    $id = if ($matched.Count -eq 1) { [string](Get-DemoMemberValue -InputObject $matched[0] -Name 'id') } else { '' }
    [pscustomobject]@{ StatusCode = 200; Id = $id; Count = $matched.Count; Error = '' }
}
