# Real-Time Dashboard (KQL dashboard) definition helpers (Phase 18). Internal; Export-DemoRealTimeDashboard,
# Get-DemoFabricDashboardDefinition, and Import-DemoFabricItem use them.
# - The item definition: one part, RealTimeDashboard.json, InlineBase64, with the dashboard JSON whose payload
#   example has schema_version 52:
#   https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/kql-dashboard-definition
# - The dashboard JSON outline and its $schema property:
#   https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create#export-dashboards
# - The published JSON Schema for that version (dashboard.json, tile.json, query.json, parameter.json):
#   https://dataexplorer.azure.com/static/d/schema/52/dashboard.json
# The validator below checks the rules of that schema the dashboard relies on, without a copy of the schema.

# RFC 4122 URL namespace (6ba7b811-9dad-11d1-80b4-00c04fd430c8) in network byte order, and the URL prefix of the
# element keys that ConvertTo-DemoStableGuid hashes.
$script:DashboardIdNamespace = [byte[]]@(0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8)
$script:DashboardIdPrefix = 'https://github.com/MarcBushong/fabric-database-hub-demo/fabric/realtime#'
# The parameter variables the dashboard declares: the time range parameter's pair and the Target parameter.
$script:DashboardVariables = @('_startTime', '_endTime', '_selectedTargets')
$script:DashboardGridColumns = 24
$script:DashboardChartVisuals = @('timechart', 'line', 'area', 'bar', 'column')
$script:DashboardUuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

function ConvertTo-DemoStableGuid {
    <#
    .SYNOPSIS
    Returns the name-based UUID (RFC 4122 section 4.3, version 5) of a dashboard element key. Internal.

    .DESCRIPTION
    SHA-1 over the URL namespace and the key's URL, so a key always gets the same ID and rebuilding the dashboard
    definition changes nothing unless its layout does. The IDs only name elements inside the definition.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Key
    )

    $name = [System.Text.Encoding]::UTF8.GetBytes($script:DashboardIdPrefix + $Key)
    $hash = [System.Security.Cryptography.SHA1]::HashData([byte[]]($script:DashboardIdNamespace + $name))
    $bytes = [byte[]]$hash[0..15]
    $bytes[6] = [byte](($bytes[6] -band 0x0F) -bor 0x50)
    $bytes[8] = [byte](($bytes[8] -band 0x3F) -bor 0x80)
    $hex = [System.Convert]::ToHexString($bytes).ToLowerInvariant()
    return ('{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12))
}

function Get-DemoDashboardPin {
    <#
    .SYNOPSIS
    Returns the dashboard pin (databaseHub.realTimeDashboard) and the telemetry endpoint from config/versions.json.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $hub = Get-DemoHubSetting
    $pin = $hub['realTimeDashboard']
    if ($null -eq $pin -or -not $hub['telemetry']['connectionUri']) {
        throw 'config/versions.json has no databaseHub.realTimeDashboard block or no telemetry connectionUri.'
    }
    [pscustomobject]@{
        DisplayName    = [string]$pin['displayName']
        ItemType       = [string]$pin['itemType']
        DefinitionPart = [string]$pin['definitionPart']
        SchemaVersion  = [string]$pin['schemaVersion']
        SchemaUrl      = [string]$pin['schemaUrl']
        ClusterUri     = [string]$hub['telemetry']['connectionUri']
        Database       = [string]$hub['telemetry']['database']
    }
}

function ConvertTo-DemoDashboardVisualOption {
    <#
    .SYNOPSIS
    Builds one tile's visualOptions from its spec entry: multi stat, table, or chart. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Tile,

        [Parameter(Mandatory)]
        [string] $TileKey
    )

    $ruleSpecs = @(if ($Tile.Contains('ColorRules')) { $Tile['ColorRules'] })
    $rules = @(for ($index = 0; $index -lt $ruleSpecs.Count; $index++) {
            $rule = $ruleSpecs[$index]
            [ordered]@{
                id               = ConvertTo-DemoStableGuid -Key ('colorrule/{0}/{1}' -f $TileKey, $index)
                ruleName         = [string]$rule['Name']
                applyTo          = 'cells'
                visualType       = [string]$Tile['Visual']
                ruleType         = 'colorByCondition'
                chainingOperator = 'and'
                colorStyle       = 'bold'
                applyToColumn    = if ($Tile['Visual'] -eq 'table') { [string]$rule['Column'] } else { $null }
                conditions       = @([ordered]@{ column = [string]$rule['Column']; operator = [string]$rule['Operator']; values = @($rule['Values'] | ForEach-Object { [string]$_ }) })
                color            = [string]$rule['Color']
                tag              = if ($rule['Tag']) { [string]$rule['Tag'] } else { '' }
                icon             = if ($rule['Icon']) { [string]$rule['Icon'] } else { $null }
                hideText         = $false
            }
        })

    switch ($Tile['Visual']) {
        'multistat' {
            return [ordered]@{
                multiStat__textSize           = 'large'
                multiStat__labelColumn        = [string]$Tile['Label']
                multiStat__valueColumn        = [string]$Tile['Value']
                multiStat__displayOrientation = 'horizontal'
                multiStat__slot               = [ordered]@{ width = [int]$Tile['Slots']; height = 1 }
                colorRulesDisabled            = $rules.Count -eq 0
                colorRules                    = $rules
            }
        }
        'table' {
            return [ordered]@{
                table__enableRenderLinks = $false
                table__renderLinks       = @()
                colorRulesDisabled       = $rules.Count -eq 0
                colorRules               = $rules
                crossFilterDisabled      = $false
                crossFilter              = @()
                drillthroughDisabled     = $false
                drillthrough             = @()
            }
        }
        { $_ -in $script:DashboardChartVisuals } {
            return [ordered]@{
                xColumn              = [string]$Tile['X']
                yColumns             = @($Tile['Y'] | ForEach-Object { [string]$_ })
                seriesColumns        = @($Tile['Series'] | ForEach-Object { [string]$_ })
                hideLegend           = $false
                legendLocation       = 'bottom'
                xColumnTitle         = ''
                yColumnTitle         = [string]$Tile['YTitle']
                xAxisScale           = 'linear'
                yAxisScale           = 'linear'
                yAxisMinimumValue    = $null
                yAxisMaximumValue    = $null
                yAxisRight           = $false
                horizontalLine       = ''
                verticalLine         = ''
                crossFilterDisabled  = $false
                crossFilter          = @()
                drillthroughDisabled = $false
                drillthrough         = @()
                multipleYAxes        = [ordered]@{
                    base               = [ordered]@{ id = '-1'; columns = @(); label = ''; yAxisMinimumValue = $null; yAxisMaximumValue = $null; yAxisScale = 'linear'; horizontalLines = @() }
                    additional         = @()
                    showMultiplePanels = $false
                }
            }
        }
        default {
            throw ('Tile {0}: the visual type {1} isn''t one the dashboard builder supports.' -f $TileKey, $Tile['Visual'])
        }
    }
}

function ConvertTo-DemoDashboardDocument {
    <#
    .SYNOPSIS
    Builds the dashboard document (the RealTimeDashboard.json content) from the layout spec and the KQL files.
    Internal; local only.

    .DESCRIPTION
    Each query is Live.Prelude.kql, rendered for the dashboard (the time range parameter's _startTime and
    _endTime, a bin chosen from the range as the live-activity notebook chooses it, the demo's fixed names, and
    the {{ResourceGroup}} placeholder that Get-DemoFabricDashboardDefinition fills in at import time), followed by
    the query's fragments. usedVariables lists the parameter variables each query uses. Element IDs come from
    ConvertTo-DemoStableGuid, so the output is the same on every run.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $SpecPath
    )

    if (-not (Test-Path -LiteralPath $SpecPath -PathType Leaf)) {
        throw "Dashboard spec not found: $SpecPath"
    }
    $spec = Import-PowerShellDataFile -LiteralPath $SpecPath
    $pin = Get-DemoDashboardPin
    $names = $spec['Names']

    $prelude = Format-DemoKqlTemplate -Name 'Live.Prelude' -Parameters ([ordered]@{
            Start          = '_startTime'
            End            = '_endTime'
            Bin            = 'case(_endTime - _startTime <= 2h, 1m, _endTime - _startTime <= 12h, 5m, 15m)'
            ResourceGroup  = '{{ResourceGroup}}'
            Database       = ConvertTo-DemoKqlLiteral -Value $names['Database'] -Type String
            VmName         = ConvertTo-DemoKqlLiteral -Value $names['VmName'] -Type String
            ArcMachineName = ConvertTo-DemoKqlLiteral -Value $names['ArcMachineName'] -Type String
            ServerPrefix   = ConvertTo-DemoKqlLiteral -Value $names['ServerPrefix'] -Type String
            DatabaseSuffix = ConvertTo-DemoKqlLiteral -Value ('/' + $names['Database']) -Type String
        })

    $dataSourceId = ConvertTo-DemoStableGuid -Key ('datasource/' + $spec['DataSource']['Key'])
    $dataSource = [ordered]@{
        id         = $dataSourceId
        name       = [string]$spec['DataSource']['Name']
        scopeId    = 'kusto'
        kind       = 'manual-kusto'
        clusterUri = $pin.ClusterUri
        database   = $pin.Database
    }

    $pageIds = @{}
    $pages = @(foreach ($page in $spec['Pages']) {
            $id = ConvertTo-DemoStableGuid -Key ('page/' + $page['Key'])
            $pageIds[$page['Key']] = $id
            [ordered]@{ name = [string]$page['Name']; id = $id }
        })

    $timeRange = $spec['Parameters']['TimeRange']
    $targets = $spec['Parameters']['Targets']
    $parameters = @(
        [ordered]@{
            kind              = 'duration'
            id                = ConvertTo-DemoStableGuid -Key 'parameter/time-range'
            displayName       = [string]$timeRange['DisplayName']
            description       = ''
            beginVariableName = '_startTime'
            endVariableName   = '_endTime'
            defaultValue      = [ordered]@{ kind = 'dynamic'; count = [int]$timeRange['DefaultHours']; unit = 'hours' }
            showOnPages       = [ordered]@{ kind = 'all' }
        }
        [ordered]@{
            kind             = 'string'
            id               = ConvertTo-DemoStableGuid -Key 'parameter/targets'
            displayName      = [string]$targets['DisplayName']
            description      = [string]$targets['Description']
            variableName     = '_selectedTargets'
            selectionType    = 'array'
            includeAllOption = $true
            allIsNull        = $true
            defaultValue     = [ordered]@{ kind = 'all' }
            dataSource       = [ordered]@{
                kind   = 'static'
                values = @(foreach ($value in $targets['Values']) { [ordered]@{ displayText = [string]$value['DisplayText']; value = [string]$value['Value'] } })
            }
            showOnPages      = [ordered]@{ kind = 'all' }
        }
    )

    $queryIds = @{}
    $queries = @(foreach ($query in $spec['Queries']) {
            $id = ConvertTo-DemoStableGuid -Key ('query/' + $query['Key'])
            $queryIds[$query['Key']] = $id
            $fragments = @(foreach ($fragment in $query['Kql']) { Format-DemoKqlTemplate -Name $fragment -Parameters @{} })
            $text = (@($prelude) + $fragments) -join "`n"
            $used = @($script:DashboardVariables | Where-Object { $text -match ('(?<![A-Za-z0-9_])' + [regex]::Escape($_) + '(?![A-Za-z0-9_])') })
            [ordered]@{
                dataSource    = [ordered]@{ kind = 'inline'; dataSourceId = $dataSourceId }
                text          = $text
                id            = $id
                usedVariables = $used
            }
        })

    $tiles = @(foreach ($tile in $spec['Tiles']) {
            $tileKey = '{0}/{1}' -f $tile['Page'], $tile['Key']
            if (-not $pageIds.ContainsKey($tile['Page'])) {
                throw ('Tile {0} is on a page the spec doesn''t define.' -f $tileKey)
            }
            $entry = [ordered]@{
                id         = ConvertTo-DemoStableGuid -Key ('tile/' + $tileKey)
                title      = [string]$tile['Title']
                visualType = [string]$tile['Visual']
                pageId     = $pageIds[$tile['Page']]
                layout     = [ordered]@{ x = [int]$tile['Layout']['X']; y = [int]$tile['Layout']['Y']; width = [int]$tile['Layout']['Width']; height = [int]$tile['Layout']['Height'] }
            }
            if ($tile['Visual'] -eq 'markdownCard') {
                $entry['markdownText'] = [string]$tile['Markdown']
                $entry['visualOptions'] = [ordered]@{}
            }
            else {
                if (-not $queryIds.ContainsKey($tile['Query'])) {
                    throw ('Tile {0} uses a query the spec doesn''t define: {1}.' -f $tileKey, $tile['Query'])
                }
                $entry['queryRef'] = [ordered]@{ kind = 'query'; queryId = $queryIds[$tile['Query']] }
                $entry['visualOptions'] = ConvertTo-DemoDashboardVisualOption -Tile $tile -TileKey $tileKey
            }
            $entry
        })

    $refresh = $spec['AutoRefresh']
    return [ordered]@{
        '$schema'      = $pin.SchemaUrl
        schema_version = $pin.SchemaVersion
        title          = [string]$spec['Title']
        autoRefresh    = [ordered]@{ enabled = [bool]$refresh['Enabled']; defaultInterval = [string]$refresh['DefaultInterval']; minInterval = [string]$refresh['MinInterval'] }
        baseQueries    = @()
        dataSources    = @($dataSource)
        pages          = $pages
        parameters     = $parameters
        queries        = $queries
        tiles          = $tiles
    }
}

function ConvertTo-DemoDashboardJson {
    <#
    .SYNOPSIS
    Serializes a dashboard document as indented JSON with LF line endings and a final newline. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Document
    )

    $json = $Document | ConvertTo-Json -Depth 32
    return (($json -replace "`r`n", "`n") + "`n")
}

function ConvertTo-DemoCanonicalJson {
    <#
    .SYNOPSIS
    Compact JSON with every object's keys in ordinal order, for comparing two documents. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $InputObject
    )

    function ConvertTo-SortedValue([object] $Value) {
        if ($Value -is [System.Collections.IDictionary]) {
            $sorted = [ordered]@{}
            foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
                $sorted[$key] = ConvertTo-SortedValue $Value[$key]
            }
            return $sorted
        }
        if ($Value -is [System.Collections.IList]) {
            return , @(foreach ($item in $Value) { ConvertTo-SortedValue $item })
        }
        return $Value
    }

    return (ConvertTo-Json -InputObject (ConvertTo-SortedValue $InputObject) -Depth 64 -Compress)
}

function Test-DemoDashboardDocument {
    <#
    .SYNOPSIS
    Checks a dashboard document against the rules of the pinned schema that the dashboard relies on, and the
    repo's rules. Returns the problems found, or nothing. Internal.

    .DESCRIPTION
    Schema rules (dashboard.json, tile.json, query.json, and parameter.json at the pinned version): the required
    and allowed top-level properties, UUID element IDs, one or more pages, each data source's kind and fields,
    parameter kinds and variable names, queries with an inline data source and their used variables, tile layouts
    (x and y at least 0, width at least 2, height at least 1), a queryRef on every tile but markdown, and color
    rules with their enums. Repo rules: one data source, the documented SQL ADX proxy and ArcSqlTelemetry; tiles
    inside the 24-column grid that don't overlap; each used variable declared by a parameter; no element ID that
    the definition doesn't define (so no subscription, tenant, workspace, or resource ID); no /subscriptions/
    path; and the {{ResourceGroup}} placeholder only in a template, never in a rendered definition.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Document,

        [switch] $Rendered
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $allowed = @('$schema', 'schema_version', 'id', 'title', 'eTag', 'autoRefresh', 'baseQueries', 'dataSources', 'pages', 'tiles', 'parameters', 'queries')
    $required = @('schema_version', 'title', 'tiles', 'baseQueries', 'parameters', 'dataSources', 'pages', 'queries')
    foreach ($key in $Document.Keys) {
        if ($key -cnotin $allowed) { $problems.Add(('Unknown top-level property: {0}.' -f $key)) }
    }
    foreach ($key in $required) {
        if (-not $Document.Contains($key)) { $problems.Add(('Missing top-level property: {0}.' -f $key)) }
    }
    if ($problems.Count -gt 0) {
        return $problems.ToArray()
    }
    try {
        Test-DemoDashboardDocumentBody -Document $Document -Problems $problems -Rendered:$Rendered
    }
    catch {
        $problems.Add(('The definition doesn''t have the expected shape: {0}' -f $_.Exception.Message))
    }
    return $problems.ToArray()
}

function Test-DemoDashboardDocumentBody {
    <#
    .SYNOPSIS
    The checks of Test-DemoDashboardDocument after the top-level properties; adds to -Problems. Internal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Document,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Problems,

        [switch] $Rendered
    )

    $problems = $Problems
    $pin = Get-DemoDashboardPin
    $intervals = @('1s', '10s', '30s', '1m', '5m', '15m', '30m', '1h', '2h', '1d')
    $variablePattern = '^(?!__)[ a-zA-Z0-9._-]+(?<!__)$'
    $isUuid = { param($Value) $Value -is [string] -and $Value -cmatch $script:DashboardUuidPattern }
    $isText = { param($Value) $Value -is [string] -and $Value -match '\S' -and $Value -notmatch '[\r\n]' }

    foreach ($key in 'id', 'eTag') {
        if ($Document.Contains($key)) { $problems.Add(('The definition sets {0}, which Fabric owns.' -f $key)) }
    }
    if ([string]$Document['schema_version'] -cne $pin.SchemaVersion -or $Document['schema_version'] -isnot [string]) {
        $problems.Add(('schema_version must be the string "{0}", pinned in config/versions.json.' -f $pin.SchemaVersion))
    }
    if (-not (& $isText $Document['title'])) { $problems.Add('The title must be one line of text.') }

    $refresh = $Document['autoRefresh']
    if ($null -ne $refresh) {
        if ($refresh['enabled'] -isnot [bool]) { $problems.Add('autoRefresh.enabled must be true or false.') }
        foreach ($key in 'defaultInterval', 'minInterval') {
            if ($refresh.Contains($key) -and $refresh[$key] -cnotin $intervals) { $problems.Add(('autoRefresh.{0} must be one of {1}.' -f $key, ($intervals -join ', '))) }
        }
    }

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $addId = {
        param([string] $Kind, $Value)
        if (-not (& $isUuid $Value)) { $problems.Add(('{0} has an ID that isn''t a lowercase UUID: {1}.' -f $Kind, $Value)) }
        elseif (-not $ids.Add($Value)) { $problems.Add(('{0} reuses the ID {1}.' -f $Kind, $Value)) }
    }

    $dataSources = @($Document['dataSources'])
    if ($dataSources.Count -ne 1) { $problems.Add(('Expected one data source; found {0}.' -f $dataSources.Count)) }
    $dataSourceIds = @()
    foreach ($source in $dataSources) {
        & $addId 'A data source' $source['id']
        $dataSourceIds += [string]$source['id']
        if (-not (& $isText $source['name'])) { $problems.Add('A data source needs a name.') }
        if ($source['kind'] -cne 'manual-kusto' -or $source['scopeId'] -cne 'kusto') { $problems.Add('The data source must be kind manual-kusto with scopeId kusto (an Azure Data Explorer cluster).') }
        if ($source['clusterUri'] -cne $pin.ClusterUri) { $problems.Add(('The data source must be the documented SQL ADX proxy {0}.' -f $pin.ClusterUri)) }
        if ($source['database'] -cne $pin.Database) { $problems.Add(('The data source must use the database {0}.' -f $pin.Database)) }
    }

    $pageIds = @()
    $pages = @($Document['pages'])
    if ($pages.Count -lt 1) { $problems.Add('A dashboard needs at least one page.') }
    foreach ($page in $pages) {
        & $addId 'A page' $page['id']
        $pageIds += [string]$page['id']
        if (-not (& $isText $page['name'])) { $problems.Add('Every page needs a name.') }
    }

    $declared = [System.Collections.Generic.List[string]]::new()
    foreach ($parameter in @($Document['parameters'])) {
        & $addId 'A parameter' $parameter['id']
        if (-not (& $isText $parameter['displayName'])) { $problems.Add('Every parameter needs a display name.') }
        if ($parameter['description'] -isnot [string]) { $problems.Add(('Parameter {0} needs a description, which can be empty.' -f $parameter['displayName'])) }
        $kind = [string]$parameter['kind']
        if ($kind -cnotin 'string', 'real', 'decimal', 'int', 'bool', 'datetime', 'long', 'duration', 'dataSource') { $problems.Add(('Parameter {0} has an unknown kind: {1}.' -f $parameter['displayName'], $kind)) }
        if ($parameter['showOnPages'] -isnot [System.Collections.IDictionary] -or $parameter['showOnPages']['kind'] -cnotin 'all', 'selection') { $problems.Add(('Parameter {0} needs showOnPages.' -f $parameter['displayName'])) }
        if ($kind -ceq 'duration') {
            foreach ($key in 'beginVariableName', 'endVariableName') {
                if ([string]$parameter[$key] -cnotmatch $variablePattern) { $problems.Add(('Parameter {0} has an invalid {1}.' -f $parameter['displayName'], $key)) }
                else { $declared.Add([string]$parameter[$key]) }
            }
            if ($parameter['defaultValue']['kind'] -cnotin 'dynamic', 'fixed') { $problems.Add(('Parameter {0} needs a dynamic or fixed default.' -f $parameter['displayName'])) }
        }
        elseif ($kind -cne 'dataSource') {
            if ([string]$parameter['variableName'] -cnotmatch $variablePattern) { $problems.Add(('Parameter {0} has an invalid variableName.' -f $parameter['displayName'])) }
            else { $declared.Add([string]$parameter['variableName']) }
            if ($parameter['selectionType'] -cnotin 'freetext', 'scalar', 'array') { $problems.Add(('Parameter {0} has an invalid selectionType.' -f $parameter['displayName'])) }
            if ($parameter['defaultValue'] -isnot [System.Collections.IDictionary] -or $parameter['defaultValue']['kind'] -cnotin 'value', 'values', 'all', 'no-selection', 'query-result') { $problems.Add(('Parameter {0} has an invalid default.' -f $parameter['displayName'])) }
            if ($parameter['selectionType'] -cin 'scalar', 'array') {
                if ($parameter['includeAllOption'] -isnot [bool]) { $problems.Add(('Parameter {0} needs includeAllOption.' -f $parameter['displayName'])) }
                if ($parameter['dataSource'] -isnot [System.Collections.IDictionary] -or $parameter['dataSource']['kind'] -cnotin 'static', 'query') { $problems.Add(('Parameter {0} needs a static or query data source.' -f $parameter['displayName'])) }
            }
        }
    }

    $queryIds = @()
    foreach ($query in @($Document['queries'])) {
        & $addId 'A query' $query['id']
        $queryIds += [string]$query['id']
        $text = [string]$query['text']
        if ($query['dataSource']['kind'] -cne 'inline' -or [string]$query['dataSource']['dataSourceId'] -notin $dataSourceIds) { $problems.Add(('Query {0} must use the dashboard''s data source inline.' -f $query['id'])) }
        if (-not $text.Trim()) { $problems.Add(('Query {0} has no text.' -f $query['id'])) }
        $used = @($query['usedVariables'] | ForEach-Object { [string]$_ })
        foreach ($variable in $used) {
            if ($variable -notin $declared) { $problems.Add(('Query {0} uses {1}, which no parameter declares.' -f $query['id'], $variable)) }
        }
        foreach ($variable in $declared) {
            $inText = $text -match ('(?<![A-Za-z0-9_])' + [regex]::Escape($variable) + '(?![A-Za-z0-9_])')
            if ($inText -ne ($variable -in $used)) { $problems.Add(('Query {0}: usedVariables and the text disagree about {1}.' -f $query['id'], $variable)) }
        }
        $placeholders = @([regex]::Matches($text, '\{\{([A-Za-z]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($Rendered -and $placeholders.Count -gt 0) { $problems.Add(('Query {0} still has placeholders: {1}.' -f $query['id'], ($placeholders -join ', '))) }
        if (-not $Rendered -and @($placeholders | Where-Object { $_ -cne 'ResourceGroup' }).Count -gt 0) { $problems.Add(('Query {0} has placeholders other than ResourceGroup.' -f $query['id'])) }
    }

    $occupied = @{}
    foreach ($tile in @($Document['tiles'])) {
        & $addId 'A tile' $tile['id']
        $name = [string]$tile['title']
        if (-not (& $isText $tile['title'])) { $problems.Add(('Tile {0} needs a one-line title.' -f $tile['id'])) }
        if ([string]$tile['pageId'] -notin $pageIds) { $problems.Add(('Tile "{0}" is on a page the dashboard doesn''t define.' -f $name)) }
        if ($tile['visualType'] -isnot [string] -or -not $tile['visualType']) { $problems.Add(('Tile "{0}" needs a visual type.' -f $name)) }
        if ($tile['visualOptions'] -isnot [System.Collections.IDictionary]) { $problems.Add(('Tile "{0}" needs visualOptions.' -f $name)) }
        $layout = $tile['layout']
        $x = [int]$layout['x']; $y = [int]$layout['y']; $width = [int]$layout['width']; $height = [int]$layout['height']
        if ($x -lt 0 -or $y -lt 0 -or $width -lt 2 -or $height -lt 1) { $problems.Add(('Tile "{0}" has an invalid layout.' -f $name)) }
        if ($x + $width -gt $script:DashboardGridColumns) { $problems.Add(('Tile "{0}" is wider than the {1}-column grid.' -f $name, $script:DashboardGridColumns)) }
        for ($column = $x; $column -lt $x + $width; $column++) {
            for ($row = $y; $row -lt $y + $height; $row++) {
                $cell = '{0}|{1}|{2}' -f $tile['pageId'], $column, $row
                if ($occupied.ContainsKey($cell)) {
                    $problems.Add(('Tiles "{0}" and "{1}" overlap.' -f $occupied[$cell], $name))
                    $column = $x + $width
                    break
                }
                $occupied[$cell] = $name
            }
        }
        if ($tile['visualType'] -ceq 'markdownCard') {
            if ($tile['markdownText'] -isnot [string]) { $problems.Add(('Markdown tile "{0}" needs markdownText.' -f $name)) }
        }
        elseif ($tile['queryRef'] -isnot [System.Collections.IDictionary] -or $tile['queryRef']['kind'] -cne 'query' -or [string]$tile['queryRef']['queryId'] -notin $queryIds) {
            $problems.Add(('Tile "{0}" must reference one of the dashboard''s queries.' -f $name))
        }
        if ($tile['visualOptions'] -is [System.Collections.IDictionary] -and $tile['visualOptions'].Contains('colorRules')) {
            foreach ($rule in @($tile['visualOptions']['colorRules'])) {
                & $addId ('A color rule on "{0}"' -f $name) $rule['id']
                if ($rule['applyTo'] -cnotin 'cells', 'rows' -or $rule['ruleType'] -cnotin 'colorByCondition', 'colorByValue' -or -not ($rule['ruleName'] -is [string])) { $problems.Add(('A color rule on "{0}" is missing applyTo, ruleType, or ruleName.' -f $name)) }
                if ($rule['ruleType'] -ceq 'colorByCondition') {
                    if ($rule['color'] -cnotin 'red', 'yellow', 'green', 'blue' -or $rule['colorStyle'] -cnotin 'light', 'bold' -or $rule['chainingOperator'] -cnotin 'and', 'or') { $problems.Add(('A color rule on "{0}" has an invalid color, style, or chaining operator.' -f $name)) }
                    $conditions = @($rule['conditions'])
                    if ($conditions.Count -lt 1 -or $conditions.Count -gt 2) { $problems.Add(('A color rule on "{0}" needs one or two conditions.' -f $name)) }
                    foreach ($condition in $conditions) {
                        if ($condition['operator'] -cnotin '>', '>=', '<', '<=', '==', '!=', 'between' -or @($condition['values'] | Where-Object { $_ -isnot [string] }).Count -gt 0) { $problems.Add(('A color rule on "{0}" has an invalid condition.' -f $name)) }
                    }
                }
            }
        }
    }

    # No IDs from outside the definition, and no Azure resource paths.
    $json = ConvertTo-Json -InputObject $Document -Depth 64 -Compress
    $known = [System.Collections.Generic.HashSet[string]]::new($ids, [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches($json, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')) {
        if (-not $known.Contains($match.Value)) {
            $problems.Add(('The definition holds an ID it doesn''t define: {0}. Real IDs are filled in at import time, never stored.' -f $match.Value))
        }
    }
    if ($json -match '(?i)/subscriptions/') {
        $problems.Add('The definition holds an Azure resource path (/subscriptions/...).')
    }
}

function Get-DemoDashboardEssential {
    <#
    .SYNOPSIS
    The parts of a dashboard document that must survive a round trip: title, data sources, pages, parameters,
    queries (with their text), and tiles (with their page, query, visual type, and layout). Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Document
    )

    [ordered]@{
        title       = [string]$Document['title']
        dataSources = @(foreach ($item in @($Document['dataSources'])) { [ordered]@{ id = [string]$item['id']; kind = [string]$item['kind']; clusterUri = [string]$item['clusterUri']; database = [string]$item['database'] } })
        pages       = @(foreach ($item in @($Document['pages'])) { [ordered]@{ id = [string]$item['id']; name = [string]$item['name'] } })
        parameters  = @(foreach ($item in @($Document['parameters'])) { [ordered]@{ id = [string]$item['id']; kind = [string]$item['kind']; variables = (@($item['variableName'], $item['beginVariableName'], $item['endVariableName']) | Where-Object { $_ }) -join ',' } })
        queries     = @(foreach ($item in @($Document['queries'])) { [ordered]@{ id = [string]$item['id']; dataSourceId = [string]$item['dataSource']['dataSourceId']; text = ([string]$item['text'] -replace "`r`n", "`n").TrimEnd() } })
        tiles       = @(foreach ($item in @($Document['tiles'])) {
                $queryRef = $item['queryRef']
                [ordered]@{
                    id         = [string]$item['id']
                    title      = [string]$item['title']
                    pageId     = [string]$item['pageId']
                    visualType = [string]$item['visualType']
                    queryId    = if ($queryRef -is [System.Collections.IDictionary]) { [string]$queryRef['queryId'] } else { '' }
                    layout     = '{0},{1},{2},{3}' -f $item['layout']['x'], $item['layout']['y'], $item['layout']['width'], $item['layout']['height']
                }
            })
    }
}

function Compare-DemoDashboardDocument {
    <#
    .SYNOPSIS
    Compares a dashboard definition read back from Fabric with the one that was sent. Internal.

    .DESCRIPTION
    Returns Identical (the same JSON, ignoring key order), EssentialMatch (every page, data source, parameter,
    query text, and tile survived), Differences (the essential elements that differ, by section and ID), and
    NormalizedFields (top-level properties that differ although the essentials match, for example a schema
    version that Fabric upgraded).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Expected,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Actual
    )

    $identical = (ConvertTo-DemoCanonicalJson -InputObject $Expected) -ceq (ConvertTo-DemoCanonicalJson -InputObject $Actual)
    $wanted = Get-DemoDashboardEssential -Document $Expected
    $found = Get-DemoDashboardEssential -Document $Actual
    $differences = [System.Collections.Generic.List[string]]::new()
    foreach ($section in $wanted.Keys) {
        if ($section -eq 'title') {
            if ($wanted.title -cne $found.title) { $differences.Add('title') }
            continue
        }
        $byId = @{}
        foreach ($item in @($found[$section])) { $byId[$item['id']] = ConvertTo-DemoCanonicalJson -InputObject $item }
        foreach ($item in @($wanted[$section])) {
            if (-not $byId.ContainsKey($item['id'])) { $differences.Add(('{0} {1}: missing' -f $section, $item['id'])) }
            elseif ($byId[$item['id']] -cne (ConvertTo-DemoCanonicalJson -InputObject $item)) { $differences.Add(('{0} {1}: changed' -f $section, $item['id'])) }
        }
        if (@($found[$section]).Count -ne @($wanted[$section]).Count) { $differences.Add(('{0}: {1} expected, {2} read back' -f $section, @($wanted[$section]).Count, @($found[$section]).Count)) }
    }

    $normalized = @(foreach ($key in @(@($Expected.Keys) + @($Actual.Keys) | Select-Object -Unique)) {
            $left = if ($Expected.Contains($key)) { ConvertTo-DemoCanonicalJson -InputObject $Expected[$key] } else { '<absent>' }
            $right = if ($Actual.Contains($key)) { ConvertTo-DemoCanonicalJson -InputObject $Actual[$key] } else { '<absent>' }
            if ($left -cne $right) { [string]$key }
        })
    [pscustomobject]@{
        Identical        = $identical
        EssentialMatch   = $differences.Count -eq 0
        Differences      = $differences.ToArray()
        NormalizedFields = $normalized
    }
}
