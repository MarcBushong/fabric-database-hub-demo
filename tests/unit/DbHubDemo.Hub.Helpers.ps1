# Shared fixtures for the Database Hub tests (Phase 9). Dot-sourced in BeforeAll; not a test file.
# Every ID is an obvious placeholder (each group repeats one digit), and tokens are built at run time so
# secret scanners don't flag them.

. (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')

$script:HubSubscriptionId = '11111111-2222-3333-4444-555555555555'
$script:HubTenantId = '66666666-7777-8888-9999-000000000000'
$script:HubGroupId = '/subscriptions/{0}/resourceGroups/rg-dbhub-demo' -f $script:HubSubscriptionId
$script:HubT1Id = '{0}/providers/Microsoft.Compute/virtualMachines/sqlvm01' -f $script:HubGroupId
$script:HubT2Id = '{0}/providers/Microsoft.HybridCompute/machines/arcsql01' -f $script:HubGroupId
$script:HubT3ServerId = '{0}/providers/Microsoft.Sql/servers/azuresql01-abc123' -f $script:HubGroupId
$script:HubT3Id = '{0}/databases/ContosoCare' -f $script:HubT3ServerId
$script:HubNow = [datetime]::new(2026, 10, 20, 12, 0, 0, [System.DateTimeKind]::Utc)

function Get-HubTestConfig {
    $config = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
    $config['subscriptionId'] = $script:HubSubscriptionId
    $config['tenantId'] = $script:HubTenantId
    $config['location'] = 'westus3'
    $config['fabric']['workspaceId'] = '99999999-8888-7777-6666-555555555555'
    return $config
}

function Get-HubFakeToken {
    # Not JWT-shaped (its first segment isn't a JWT header), so only its registration as a secret can redact
    # it. Its payload carries the tid and oid claims that Get-DemoAccessToken checks against the validated context.
    return (Get-GuardTestToken -TenantId $script:HubTenantId -ObjectId $script:GuardTestObjectId)
}

function ConvertTo-HubSecureString([string] $Value) {
    $secure = [System.Security.SecureString]::new()
    foreach ($character in $Value.ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    return $secure
}

function ConvertFrom-HubSecureString([securestring] $Value) {
    # Test-only: reads a fake token back so a test can check where it was sent.
    if ($null -eq $Value) {
        return ''
    }
    return [System.Net.NetworkCredential]::new('', $Value).Password
}

function Get-HubUtcText([object] $Value) {
    if ($null -eq $Value) {
        return $null
    }
    return ([datetime]$Value).ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-HubKustoJson {
    # A Kusto v1 response with the result table first and a status table after it, as the endpoint returns.
    param(
        [string[]] $Column,
        [string[]] $Type,
        [System.Collections.Generic.List[object]] $Row
    )
    $dataTypes = @{ string = 'String'; long = 'Int64'; int = 'Int32'; real = 'Double'; datetime = 'DateTime'; bool = 'Boolean' }
    $columns = for ($index = 0; $index -lt $Column.Count; $index++) {
        [ordered]@{ ColumnName = $Column[$index]; DataType = $dataTypes[$Type[$index]]; ColumnType = $Type[$index] }
    }
    $document = [ordered]@{
        Tables = @(
            [ordered]@{ TableName = 'Table_0'; Columns = @($columns); Rows = $Row.ToArray() }
            [ordered]@{ TableName = 'Table_1'; Columns = @([ordered]@{ ColumnName = 'Value'; DataType = 'String'; ColumnType = 'string' }); Rows = @() }
        )
    }
    return ($document | ConvertTo-Json -Depth 10)
}

function ConvertTo-HubSummaryJson {
    # Rows of the ResourceSummary template. Each entry: Id, Type, Name, Rows, RowsSince, First, FirstSince, Last, Instances.
    param([object[]] $Entry = @())
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Entry) {
        $rowsSince = if ($item.Contains('RowsSince')) { $item.RowsSince } else { $item.Rows }
        $firstSince = if ($item.Contains('FirstSince')) { $item.FirstSince } else { $item.First }
        $instances = if ($item.Contains('Instances')) { $item.Instances } else { 1 }
        $rows.Add([object[]]@($item.Id, $item.Type, $item.Name, 'rg-dbhub-demo', $item.Rows, $rowsSince, (Get-HubUtcText $item.First), (Get-HubUtcText $firstSince), (Get-HubUtcText $item.Last), $instances))
    }
    ConvertTo-HubKustoJson -Column 'ResourceID', 'ResourceType', 'ResourceName', 'ResourceGroup', 'Rows', 'RowsSince', 'FirstSampleUTC', 'FirstSampleSinceUTC', 'LastSampleUTC', 'Instances' -Type 'string', 'string', 'string', 'string', 'long', 'long', 'datetime', 'datetime', 'datetime', 'long' -Row $rows
}

function ConvertTo-HubHttpResponse {
    param(
        [int] $StatusCode = 200,
        [string] $Json = '',
        [object] $RetryAfterSeconds = $null,
        [string] $ErrorText = ''
    )
    $content = if ($Json) { $Json | ConvertFrom-Json } else { $null }
    [pscustomobject]@{ StatusCode = $StatusCode; Content = $content; RetryAfterSeconds = $RetryAfterSeconds; Error = $ErrorText }
}

function Initialize-HubAzMock {
    # Mocks every Azure CLI call (tokens and the resource group's deploymentId tag) and Resource Graph queries,
    # which go through Invoke-DemoRestRequest with a verified token. Also records the validated Azure CLI
    # context (the unit-test hook), because token requests need it.
    param(
        [string] $Token,
        [string] $DeploymentIdTag = 'abc123',
        [object[]] $GraphRow = @(),
        [switch] $GraphFails,
        [switch] $TokenFails
    )
    Initialize-GuardTestContext -SubscriptionId $script:HubSubscriptionId -TenantId $script:HubTenantId
    $script:HubAzToken = $Token
    $script:HubAzTag = $DeploymentIdTag
    $script:HubGraphRows = @($GraphRow)
    $script:HubGraphFails = [bool]$GraphFails
    $script:HubTokenFails = [bool]$TokenFails
    $script:HubGraphBodies = [System.Collections.Generic.List[object]]::new()
    $script:HubGraphUris = [System.Collections.Generic.List[string]]::new()
    Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
        $joined = $ArgumentList -join ' '
        if ($joined -like 'account get-access-token*') {
            if ($script:HubTokenFails) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: AADSTS50076: interaction required.' }
            }
            return (ConvertTo-GuardTestTokenResult -Token $script:HubAzToken)
        }
        if ($joined -like 'group show*') {
            return [pscustomobject]@{ ExitCode = 0; StdOut = $script:HubAzTag; StdErr = '' }
        }
        [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('unexpected az call: {0}' -f $joined) }
    }
    Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
        if ($Uri -notlike 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources*') {
            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('unexpected request: {0}' -f $Uri); StatusCode = 0 }
        }
        $script:HubGraphUris.Add($Uri)
        $script:HubGraphBodies.Add(($Body | ConvertFrom-Json -AsHashtable))
        if ($script:HubGraphFails) {
            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 403: {"error":{"code":"AuthorizationFailed","message":"The client does not have authorization."}}'; StatusCode = 403 }
        }
        $response = [ordered]@{ totalRecords = $script:HubGraphRows.Count; count = $script:HubGraphRows.Count; data = @($script:HubGraphRows); resultTruncated = 'false' }
        [pscustomobject]@{ ExitCode = 0; StdOut = ($response | ConvertTo-Json -Depth 8); StdErr = ''; StatusCode = 200 }
    }
}

function Initialize-HubHttpMock {
    # Mocks the single HTTP request. $Handler reads $script:HubRequest (Method, Uri, Token as plain text, Csl) and
    # returns a response object.
    param([scriptblock] $Handler)
    $script:HubHttpHandler = $Handler
    $script:HubHttpCalls = [System.Collections.Generic.List[object]]::new()
    Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHubHttp -MockWith {
        $csl = if ($Body) { [string](($Body | ConvertFrom-Json).csl) } else { '' }
        $script:HubRequest = [pscustomobject]@{ Method = $Method; Uri = $Uri; Token = (ConvertFrom-HubSecureString $Token); Body = $Body; Csl = $csl }
        $script:HubHttpCalls.Add($script:HubRequest)
        & $script:HubHttpHandler
    }
}

function ConvertTo-HubFabricResponse {
    # A response as Invoke-DemoFabricRequest (Phase 12) returns it: StatusCode, Headers, and the parsed JSON Body.
    param(
        [int] $StatusCode = 200,
        [object] $Body = $null
    )
    $parsed = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 64 } else { $null }
    [pscustomobject]@{ StatusCode = $StatusCode; Headers = @{}; Body = $parsed }
}

function Initialize-HubFabricMock {
    # Mocks the Phase 12 Fabric REST helpers that the P4 and P5 checks call. Get-DemoFabricToken returns $Token as a
    # SecureString (or throws with -TokenFails); Invoke-DemoFabricRequest runs $Handler, which reads
    # $script:HubFabricRequest (Method, Uri, Token as plain text) and returns ConvertTo-HubFabricResponse output or
    # throws. Until this branch is merged with Phase 12, module stubs with the same parameters stand in for them.
    param(
        [scriptblock] $Handler,
        [string] $Token = (Get-HubFakeToken),
        [switch] $TokenFails
    )
    & (Get-Module -Name DbHubDemo) {
        if (-not (Get-Command -Name 'Get-DemoFabricToken' -CommandType Function -ErrorAction SilentlyContinue)) {
            function script:Get-DemoFabricToken {
                [CmdletBinding()]
                [OutputType([securestring])]
                param([string] $SubscriptionId)
                throw ('Phase 12 stub for {0}; the tests mock it.' -f $SubscriptionId)
            }
        }
        if (-not (Get-Command -Name 'Invoke-DemoFabricRequest' -CommandType Function -ErrorAction SilentlyContinue)) {
            function script:Invoke-DemoFabricRequest {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param([string] $Method, [string] $Uri, [securestring] $Token, [System.Collections.IDictionary] $Body)
                throw ('Phase 12 stub for {0} {1} (token {2}, body {3}); the tests mock it.' -f $Method, $Uri, ($null -ne $Token), ($null -ne $Body))
            }
        }
    }
    $script:HubFabricHandler = $Handler
    $script:HubFabricToken = $Token
    $script:HubFabricTokenFails = [bool]$TokenFails
    $script:HubFabricCalls = [System.Collections.Generic.List[object]]::new()
    Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith {
        if ($script:HubFabricTokenFails) {
            throw 'ERROR: AADSTS50076: interaction required.'
        }
        ConvertTo-HubSecureString $script:HubFabricToken
    }
    Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -MockWith {
        $script:HubFabricRequest = [pscustomobject]@{ Method = $Method; Uri = $Uri; Token = (ConvertFrom-HubSecureString $Token) }
        $script:HubFabricCalls.Add($script:HubFabricRequest)
        & $script:HubFabricHandler
    }
}

function Get-HubGraphRow {
    # A complete demo estate as Resource Graph returns it; -Without drops rows by name.
    param([string[]] $Without = @())
    $rows = @(
        [ordered]@{ id = $script:HubT1Id; name = 'sqlvm01'; type = 'microsoft.compute/virtualmachines'; location = 'westus3'; resourceGroup = 'rg-dbhub-demo' }
        [ordered]@{ id = ('{0}/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/sqlvm01' -f $script:HubGroupId); name = 'sqlvm01'; type = 'microsoft.sqlvirtualmachine/sqlvirtualmachines'; location = 'westus3'; resourceGroup = 'rg-dbhub-demo'; sqlImageSku = 'Standard'; sqlServerLicenseType = 'PAYG'; provisioningState = 'Succeeded' }
        [ordered]@{ id = $script:HubT2Id; name = 'arcsql01'; type = 'microsoft.hybridcompute/machines'; location = 'westus3'; resourceGroup = 'rg-dbhub-demo'; status = 'Connected' }
        [ordered]@{ id = ('{0}/providers/Microsoft.AzureArcData/sqlServerInstances/arcsql01' -f $script:HubGroupId); name = 'arcsql01'; type = 'microsoft.azurearcdata/sqlserverinstances'; location = 'westus3'; resourceGroup = 'rg-dbhub-demo'; edition = 'Standard'; licenseType = 'PAYG'; version = 'SQL Server 2022'; monitoringEnabled = 'true' }
        [ordered]@{ id = $script:HubT3ServerId; name = 'azuresql01-abc123'; type = 'microsoft.sql/servers'; location = 'westus3'; resourceGroup = 'rg-dbhub-demo' }
        [ordered]@{ id = $script:HubT3Id; name = 'ContosoCare'; type = 'microsoft.sql/servers/databases'; location = 'westus3'; resourceGroup = 'rg-dbhub-demo'; status = 'Online'; createdUtc = '2026-10-20T11:00:00.0000000Z'; skuName = 'GP_S_Gen5' }
        [ordered]@{ id = ('{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' -f $script:HubGroupId); name = 'pgflex01-abc123'; type = 'microsoft.dbforpostgresql/flexibleservers'; location = 'westus3'; resourceGroup = 'rg-dbhub-demo'; status = 'Ready'; version = '18'; skuName = 'Standard_B1ms' }
    )
    @($rows | Where-Object { $_.type + '|' + $_.name -notin $Without })
}
