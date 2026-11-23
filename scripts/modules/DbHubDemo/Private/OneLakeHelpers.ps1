# OneLake's ADLS Gen2 API (2026-11-20, ADR 0031), for the Incident RCA: the demo lakehouse's table folders, which the
# history model's step reads to leave out an RCA table the lakehouse doesn't have yet (Get-DemoRcaModelTablePlan), and the
# evidence that stop-demo.ps1 -SaveHistory and deploy.ps1's history snapshot stage in its Files/rca/inbox for
# NB_DatabaseHub_LiveActivity (RCA_EVIDENCE_FILE). The Storage-audience token comes from the signed-in Azure CLI, and the
# operator's workspace role from deploy (Admin, Member, or Contributor) already reads and writes OneLake: nothing here
# requests or assigns a role.
# - OneLake APIs and the Storage audience: https://learn.microsoft.com/fabric/onelake/onelake-access-api
# - Workspace roles write to OneLake: https://learn.microsoft.com/fabric/onelake/security/best-practices-secure-data-in-onelake
# - Path - Create, Update (append, flush), List, Delete: https://learn.microsoft.com/rest/api/storageservices/data-lake-storage-gen2
$script:OneLakeDfsUri = 'https://onelake.dfs.fabric.microsoft.com'
$script:StorageTokenResource = 'https://storage.azure.com/'
# The version OneLake's own samples answer with (onelake-access-api).
$script:OneLakeApiVersion = '2021-06-08'
$script:OneLakeGuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

function Get-DemoStorageToken {
    <#
    .SYNOPSIS
    A token in the Storage audience, which OneLake's APIs take, for the signed-in Azure CLI user, as a SecureString.
    Internal.

    .DESCRIPTION
    Get-DemoAccessToken ('az account get-access-token --resource https://storage.azure.com/ --subscription <id>' through
    Invoke-DemoAz) checks the token's tenant and caller against the context the subscription guard validated, and
    registers it for redaction. Call Assert-DemoAzContext first. It never signs in, and it requests no role: OneLake
    answers with the caller's workspace role.
    - OneLake only supports tokens in the Storage audience: https://learn.microsoft.com/fabric/onelake/onelake-access-api
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId
    )

    $issued = Get-DemoAccessToken -SubscriptionId $SubscriptionId -Resource $script:StorageTokenResource
    if ($null -eq $issued.Token) {
        throw ('No verified OneLake (Storage) token is available: {0}' -f $issued.Error)
    }
    return $issued.Token
}

function Invoke-DemoOneLakeRequest {
    <#
    .SYNOPSIS
    One request to OneLake's ADLS Gen2 API for a path in a Fabric item, by the workspace's and the item's IDs. Returns
    StatusCode, Headers, and Content (text); an HTTP error doesn't throw. Internal.

    .DESCRIPTION
    Only https://onelake.dfs.fabric.microsoft.com/<workspaceId>/<itemId>/..., so the token can't go anywhere else; only
    the ADLS Gen2 path operations the RCA evidence needs (GET to list or read, PUT to create, PATCH to append or flush,
    DELETE). Transient failures are retried as the module's other REST calls are (Invoke-DemoTransientRetry); an append
    isn't sent twice once it reached the service (-NotIdempotent).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Put', 'Patch', 'Delete')]
        [string] $Method,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        # The path after the workspace: '<itemId>/Files/...' for a path, or '' with -Query for the workspace's list.
        [AllowEmptyString()]
        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(/[A-Za-z0-9._-]+)*$')]
        [string] $Path = '',

        [AllowEmptyString()]
        [string] $Query = '',

        [Parameter(Mandatory)]
        [securestring] $Token,

        [byte[]] $Body,

        [switch] $NotIdempotent
    )

    $uri = '{0}/{1}' -f $script:OneLakeDfsUri, $WorkspaceId.ToLowerInvariant()
    if ($Path) {
        $uri += '/' + $Path
    }
    if ($Query) {
        $uri += '?' + $Query
    }
    $request = @{
        Uri                     = $uri
        Method                  = $Method
        Authentication          = 'Bearer'
        Token                   = $Token
        Headers                 = @{ 'x-ms-version' = $script:OneLakeApiVersion }
        SkipHttpErrorCheck      = $true
        TimeoutSec              = 120
        OperationTimeoutSeconds = 120
        ErrorAction             = 'Stop'
    }
    if ($null -ne $Body) {
        $request['Body'] = $Body
        $request['ContentType'] = 'application/octet-stream'
    }
    $response = Invoke-DemoTransientRetry -Send { param([hashtable] $Call) Invoke-WebRequest @Call } -State $request -Target ([uri]$uri).Host -NotIdempotent:$NotIdempotent
    [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        Headers    = $response.Headers
        Content    = [string]$response.Content
    }
}

function Get-DemoOneLakeError {
    # An ADLS Gen2 error answer, as one redacted line: the HTTP status and the error's code and message.
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Response
    )

    $text = 'HTTP {0}' -f $Response.StatusCode
    try {
        $body = $Response.Content | ConvertFrom-Json -Depth 8
        $detail = Get-DemoMemberValue -InputObject $body -Name 'error'
        foreach ($name in 'code', 'message') {
            $value = [string](Get-DemoMemberValue -InputObject $detail -Name $name)
            if ($value) {
                $text += ' ' + ($value -split "`n")[0].Trim()
            }
        }
    }
    catch {
        $null = $_
    }
    return (Protect-DemoText -Text $text)
}

function Get-DemoLakehouseTable {
    <#
    .SYNOPSIS
    The Delta tables in a lakehouse schema's folder (Tables/<schema>), by name: Path - List on OneLake, read-only. Returns
    Names and Error ('' when the list was read; a folder that doesn't exist yet lists no table). Internal.

    .DESCRIPTION
    The lakehouse has schemas (the history model reads schema dbo), whose tables Fabric's List Tables API doesn't list, so
    the folders under Tables/dbo are read instead, a page of up to 5,000 at a time.
    - Path - List: https://learn.microsoft.com/rest/api/storageservices/datalakestoragegen2/path/list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $LakehouseId,

        [ValidatePattern('^[A-Za-z0-9_]{1,128}$')]
        [string] $Schema = 'dbo',

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    $directory = '{0}/Tables/{1}' -f $LakehouseId.ToLowerInvariant(), $Schema
    $names = [System.Collections.Generic.List[string]]::new()
    $continuation = ''
    for ($page = 0; $page -lt 20; $page++) {
        $query = 'resource=filesystem&recursive=false&directory={0}' -f [uri]::EscapeDataString($directory)
        if ($continuation) {
            $query += '&continuation=' + [uri]::EscapeDataString($continuation)
        }
        $response = Invoke-DemoOneLakeRequest -Method Get -WorkspaceId $WorkspaceId -Query $query -Token $Token
        if ($response.StatusCode -eq 404) {
            break
        }
        if ($response.StatusCode -ne 200) {
            return [pscustomobject]@{ Names = @(); Error = (Get-DemoOneLakeError -Response $response) }
        }
        try {
            $listed = $response.Content | ConvertFrom-Json -Depth 8
        }
        catch {
            return [pscustomobject]@{ Names = @(); Error = 'OneLake''s list of the lakehouse''s tables wasn''t JSON.' }
        }
        # Into a variable first: Get-DemoMemberValue returns the array whole, and @() around the call would nest it.
        $paths = Get-DemoMemberValue -InputObject $listed -Name 'paths'
        foreach ($path in @($paths)) {
            if ($null -ne $path -and [string](Get-DemoMemberValue -InputObject $path -Name 'isDirectory') -eq 'true') {
                $names.Add(([string](Get-DemoMemberValue -InputObject $path -Name 'name')).Split('/')[-1])
            }
        }
        $continuation = [string](@($response.Headers['x-ms-continuation']) | Select-Object -First 1)
        if (-not $continuation) {
            break
        }
    }
    return [pscustomobject]@{ Names = $names.ToArray(); Error = '' }
}

function Send-DemoOneLakeFile {
    <#
    .SYNOPSIS
    Writes a text file, UTF-8 without a byte order mark, to a path in a lakehouse's Files, replacing one that's there:
    Path - Create, then Path - Update's append and flush. Returns Status ('Pass' or 'Fail') and Error. Internal.
    - Path - Create: https://learn.microsoft.com/rest/api/storageservices/datalakestoragegen2/path/create
    - Path - Update: https://learn.microsoft.com/rest/api/storageservices/datalakestoragegen2/path/update
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes one staged file in the demo lakehouse; its callers gate it.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $LakehouseId,

        # Under Files only.
        [Parameter(Mandatory)]
        [ValidatePattern('^Files(/[A-Za-z0-9._-]+)+$')]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content,

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    $target = '{0}/{1}' -f $LakehouseId.ToLowerInvariant(), $Path
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
    $created = Invoke-DemoOneLakeRequest -Method Put -WorkspaceId $WorkspaceId -Path $target -Query 'resource=file' -Token $Token
    if ($created.StatusCode -notin 200, 201) {
        return [pscustomobject]@{ Status = 'Fail'; Error = ('creating {0}: {1}' -f $Path, (Get-DemoOneLakeError -Response $created)) }
    }
    if ($bytes.Length -gt 0) {
        $appended = Invoke-DemoOneLakeRequest -Method Patch -WorkspaceId $WorkspaceId -Path $target -Query 'action=append&position=0' -Body $bytes -Token $Token -NotIdempotent
        if ($appended.StatusCode -ne 202) {
            return [pscustomobject]@{ Status = 'Fail'; Error = ('writing {0}: {1}' -f $Path, (Get-DemoOneLakeError -Response $appended)) }
        }
    }
    $flushed = Invoke-DemoOneLakeRequest -Method Patch -WorkspaceId $WorkspaceId -Path $target -Query ('action=flush&position={0}' -f $bytes.Length) -Token $Token
    if ($flushed.StatusCode -ne 200) {
        return [pscustomobject]@{ Status = 'Fail'; Error = ('saving {0}: {1}' -f $Path, (Get-DemoOneLakeError -Response $flushed)) }
    }
    return [pscustomobject]@{ Status = 'Pass'; Error = '' }
}

function Remove-DemoOneLakeFile {
    <#
    .SYNOPSIS
    Deletes a file in a lakehouse's Files: Path - Delete. One that's gone already counts as deleted. Returns Status
    ('Pass' or 'Fail'), Found ($true when the file was there and this deleted it, $false when it was gone already: HTTP
    404; review of 3b1348a), and Error. Internal.
    - Path - Delete: https://learn.microsoft.com/rest/api/storageservices/datalakestoragegen2/path/delete
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Deletes one staged file in the demo lakehouse; its callers gate it.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $LakehouseId,

        [Parameter(Mandatory)]
        [ValidatePattern('^Files(/[A-Za-z0-9._-]+)+$')]
        [string] $Path,

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    $deleted = Invoke-DemoOneLakeRequest -Method Delete -WorkspaceId $WorkspaceId -Path ('{0}/{1}' -f $LakehouseId.ToLowerInvariant(), $Path) -Token $Token
    if ($deleted.StatusCode -in 200, 202, 204) {
        return [pscustomobject]@{ Status = 'Pass'; Found = $true; Error = '' }
    }
    if ($deleted.StatusCode -eq 404) {
        return [pscustomobject]@{ Status = 'Pass'; Found = $false; Error = '' }
    }
    return [pscustomobject]@{ Status = 'Fail'; Found = $false; Error = ('deleting {0}: {1}' -f $Path, (Get-DemoOneLakeError -Response $deleted)) }
}

function Get-DemoRcaHistoryTable {
    <#
    .SYNOPSIS
    The Incident RCA's history tables of one document (rca/history-tables.json): Name (the lakehouse's) and Model (the
    history model's), in the contract's order. The evidence document's eight by default; -Document sidecar for the
    sidecar's, which the history model gets with the sidecar's notebook (rca/README.md, The sidecar). Pure (reads the
    repository's file). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = (Join-Path -Path $script:RepoRoot -ChildPath 'rca/history-tables.json'),

        [ValidateSet('evidence', 'sidecar')]
        [string] $Document = 'evidence'
    )

    $contract = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 16
    foreach ($table in @($contract.tables)) {
        # A contract from before the sidecar names no document: every table is the evidence document's.
        $carrier = if ($table.PSObject.Properties['document']) { [string]$table.document } else { 'evidence' }
        if ($carrier -eq $Document) {
            [pscustomobject]@{ Name = [string]$table.name; Model = [string]$table.model; Role = [string]$table.role }
        }
    }
}
