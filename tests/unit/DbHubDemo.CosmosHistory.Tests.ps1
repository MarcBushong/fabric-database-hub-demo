BeforeAll {
    # T5's Azure Cosmos DB metrics for the history (2026-11-18, ADR 0027): Get-DemoCosmosHistoryParameter reads T5's Azure
    # Monitor metrics with the Azure CLI and returns the notebook's COSMOS_METRICS JSON. No network: Invoke-DemoAz is
    # mocked, and its metrics answer with points for the timespan and interval the read asked for.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # Obviously fake IDs: every group repeats one character.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config
    }

    function New-AzResult([object] $Json = $null, [int] $ExitCode = 0, [string] $StdErr = '') {
        $text = if ($null -eq $Json) { '' } elseif ($Json -is [string]) { $Json } else { ConvertTo-Json -InputObject $Json -Depth 20 -Compress }
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $text; StdErr = $StdErr }
    }

    # Parses the document with System.Text.Json into ordered dictionaries and arrays, so its times stay text whichever
    # PowerShell 7 runs the tests (ConvertFrom-Json turns ISO 8601 strings into DateTime values).
    function ConvertFrom-TestJson([string] $Json) {
        $convert = {
            param([System.Text.Json.JsonElement] $Element)
            switch ($Element.ValueKind) {
                'Object' {
                    $table = [ordered]@{}
                    foreach ($property in $Element.EnumerateObject()) {
                        $table[$property.Name] = & $convert $property.Value
                    }
                    return $table
                }
                'Array' { return , @(foreach ($item in $Element.EnumerateArray()) { , (& $convert $item) }) }
                'String' { return $Element.GetString() }
                'Number' { return $Element.GetDouble() }
                'True' { return $true }
                'False' { return $false }
            }
            return $null
        }
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
        try {
            & $convert $document.RootElement
        }
        finally {
            $document.Dispose()
        }
    }

    $script:units = @{ NormalizedRUConsumption = 'Percent'; ServiceAvailability = 'Percent'; ServerSideLatencyGateway = 'MilliSeconds' }

    # The value of a metric at the i-th interval of a read, or $null for no data. The last interval of every read has no
    # value, as Azure Monitor answers for an interval that hasn't closed yet. An ru-storm throttles intervals 3, 4, and 6;
    # Azure Monitor sends no point for the 429s' other intervals.
    function Get-TestValue([string] $Metric, [bool] $Throttled, [int] $Index, [int] $Count) {
        if ($Index -eq $Count - 1 -or $script:fake.NoData) {
            return $null
        }
        if ($Throttled) {
            return @{ 3 = 50; 4 = 40; 6 = 30 }[$Index]
        }
        switch ($Metric) {
            'NormalizedRUConsumption' { return $(if ($Index -ge 3 -and $Index -le 7) { 100 } else { 20.04 }) }
            'TotalRequestUnits' { return 6000.4 }
            'TotalRequests' { return 600 }
            'ServerSideLatencyGateway' { return 5.256 }
            'ProvisionedThroughput' { return 400 }
            'ServiceAvailability' { return 99.99 }
        }
        return $null
    }

    # A Metrics - List answer for the read's timespan, interval, metric name, aggregation, and filter.
    function New-MetricsBody([System.Collections.IDictionary] $Query) {
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $range = ([string]$Query['timespan']).Split('/')
        $start = [datetime]::Parse($range[0], [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        $end = [datetime]::Parse($range[1], [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        $step = @{ PT1M = 1; PT5M = 5; PT15M = 15; PT30M = 30; PT1H = 60 }[[string]$Query['interval']]
        $count = [int][System.Math]::Ceiling(($end - $start).TotalMinutes / $step)
        $field = ([string]$Query['aggregation']).ToLowerInvariant()
        $name = [string]$Query['metricnames']
        $throttled = $Query.Contains('$filter')
        $data = for ($index = 0; $index -lt $count; $index++) {
            $point = [ordered]@{ timeStamp = $start.AddMinutes($index * $step).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) }
            $value = Get-TestValue -Metric $name -Throttled $throttled -Index $index -Count $count
            if ($null -ne $value) {
                $point[$field] = $value
            }
            $point
        }
        $unit = if ($script:units.ContainsKey($name)) { $script:units[$name] } else { 'Count' }
        [ordered]@{ cost = 0; timespan = $Query['timespan']; interval = $Query['interval']; value = @([ordered]@{ name = @{ value = $name; localizedValue = $name }; unit = $unit; timeseries = @(@{ metadatavalues = @(); data = @($data) }) }) }
    }

    # A mock of Invoke-DemoAz for the reads: the resource group's tag, T5's account, and its metrics. $script:fake holds what
    # exists, and $script:azCalls and $script:urlParameters what the reads sent.
    function Initialize-CosmosAzMock {
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:urlParameters = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            # Every argument must reach az.cmd unchanged, as the real Invoke-DemoAz requires (live, 2026-10-26: an encoded
            # metrics query string with '%' failed the T4 track).
            foreach ($argument in @($ArgumentList)) {
                $null = & (Get-Module -Name DbHubDemo) { param($Value) ConvertTo-DemoBatchArgument -Argument $Value } ([string]$argument)
            }
            $text = @($ArgumentList) -join ' '
            $query = $null
            $parametersIndex = [array]::IndexOf([string[]]@($ArgumentList), '--url-parameters')
            if ($parametersIndex -ge 0) {
                $query = Get-Content -LiteralPath ([string]$ArgumentList[$parametersIndex + 1]).Substring(1) -Raw | ConvertFrom-Json -AsHashtable
                $script:urlParameters.Add($query)
            }
            $script:azCalls.Add($text)
            if ($text -like 'group show*') {
                if ($script:fake.GroupThrow) {
                    throw 'The Azure CLI isn''t installed.'
                }
                $tags = if ($script:fake.Tagged) { [pscustomobject]@{ deploymentId = 'abc123' } } else { [pscustomobject]@{} }
                if ($AsJson) {
                    return [pscustomobject]@{ tags = $tags }
                }
                return (New-AzResult -Json @{ tags = $tags })
            }
            if ($text -match '--url \S+/databaseAccounts/cosmos01-abc123/providers/Microsoft\.Insights/metrics ') {
                if ($script:fake.MetricsThrow) {
                    throw 'The Azure CLI isn''t installed.'
                }
                if ($script:fake.MetricsMissing) {
                    return (New-AzResult -ExitCode 1 -StdErr "ERROR: (ResourceNotFound) The Resource 'Microsoft.DocumentDB/databaseAccounts/cosmos01-abc123' under resource group 'rg-dbhub-demo' was not found.")
                }
                if ($script:fake.MetricsError) {
                    return (New-AzResult -ExitCode 1 -StdErr ('ERROR: (InvalidAuthenticationToken) The access token expired. Authorization: Bearer {0}' -f ('Z' * 24)))
                }
                return (New-AzResult -Json (New-MetricsBody -Query $query))
            }
            if ($text -match '--method get --url \S+/databaseAccounts/cosmos01-abc123\?') {
                if (-not $script:fake.Exists) {
                    return (New-AzResult -ExitCode 1 -StdErr "ERROR: (ResourceNotFound) The Resource 'Microsoft.DocumentDB/databaseAccounts/cosmos01-abc123' under resource group 'rg-dbhub-demo' was not found.")
                }
                return (New-AzResult -Json @{ name = 'cosmos01-abc123'; properties = @{ provisioningState = 'Succeeded'; enableFreeTier = $true } })
            }
            throw "unexpected Azure CLI call: $text"
        }
    }

    function Reset-CosmosFake {
        $script:fake = @{ Tagged = $true; Exists = $true; NoData = $false; MetricsError = $false; MetricsThrow = $false; MetricsMissing = $false; GroupThrow = $false }
    }

    # 18:02:37 UTC: the window ends at 18:02 and starts on the interval boundary at or before 18:02 minus the window.
    $script:now = [datetime]::new(2026, 11, 18, 18, 2, 37, [System.DateTimeKind]::Utc)
    $script:capture = {
        param([hashtable] $Extra = @{})
        $arguments = @{ Config = (New-TestConfig); NowUtc = $script:now; WindowMinutes = 60 }
        foreach ($key in $Extra.Keys) {
            $arguments[$key] = $Extra[$key]
        }
        InModuleScope DbHubDemo -Parameters @{ Arguments = $arguments } { param($Arguments) Get-DemoCosmosHistoryParameter @Arguments }
    }
    $script:seriesOf = {
        param([object] $Document, [string] $Metric)
        @($Document.series | Where-Object { $_.metric -eq $Metric }) | Select-Object -First 1
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoCosmosHistoryParameter (2026-11-18, ADR 0027)' {
    BeforeEach {
        Reset-CosmosFake
        Initialize-CosmosAzMock
    }

    It 'reads T5''s seven signals and returns compact version 1 JSON with only the points that have a value' {
        $result = & $script:capture
        $result.Status | Should -Be 'Pass'
        $result.AccountName | Should -Be 'cosmos01-abc123'
        $result.SeriesCount | Should -Be 7
        $result.IntervalMinutes | Should -Be 1
        $result.Json | Should -Not -Match '\s' -Because 'the parameter is compact JSON'
        $result.Bytes | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount($result.Json))
        $document = ConvertFrom-TestJson -Json $result.Json
        $document.version | Should -Be 1
        $document.capturedUtc | Should -Be '2026-11-18T18:02:00Z'
        $document.startUtc | Should -Be '2026-11-18T17:02:00Z'
        $document.endUtc | Should -Be '2026-11-18T18:02:00Z'
        $document.windowMinutes | Should -Be 60
        $document.intervalMinutes | Should -Be 1
        $result.Json | Should -Match ([regex]::Escape('"accounts":[{"target":"T5","resourceName":"cosmos01-abc123"}],"series":['))
        @($document.series | ForEach-Object { '{0}:{1}:{2}:{3}' -f $_.metric, $_.aggregation, $_.unit, $_.intervalMinutes }) | Should -Be @(
            'NormalizedRUConsumption:Maximum:Percent:1', 'TotalRequestUnits:Total:Count:1', 'TotalRequests:Count:Count:1', 'ThrottledRequests:Count:Count:1',
            'ServerSideLatencyGateway:Average:MilliSeconds:1', 'ProvisionedThroughput:Maximum:Count:60', 'ServiceAvailability:Average:Percent:60')
        # 17:02 to 18:02 is 60 intervals; the last one (18:01) has no value yet, so 59 points remain in each 1-minute series.
        @((& $script:seriesOf $document 'NormalizedRUConsumption').points).Count | Should -Be 59
        (& $script:seriesOf $document 'NormalizedRUConsumption').points[0] | Should -Be @('2026-11-18T17:02:00Z', 20) -Because 'percent keeps one decimal, and a whole number is written without decimals'
        (& $script:seriesOf $document 'NormalizedRUConsumption').points[3] | Should -Be @('2026-11-18T17:05:00Z', 100)
        # The throttled requests: TotalRequests with StatusCode 429, only the intervals that had any.
        $throttled = & $script:seriesOf $document 'ThrottledRequests'
        $throttled.statusCode | Should -Be '429'
        $throttled.points | Should -Be @(@('2026-11-18T17:05:00Z', 50), @('2026-11-18T17:06:00Z', 40), @('2026-11-18T17:08:00Z', 30))
        $result.Json | Should -Match '"metric":"TotalRequestUnits","aggregation":"Total","unit":"Count","intervalMinutes":1,"points":\[\["2026-11-18T17:02:00Z",6000\],'
        $result.Json | Should -Match '"metric":"ServerSideLatencyGateway","aggregation":"Average","unit":"MilliSeconds","intervalMinutes":1,"points":\[\["2026-11-18T17:02:00Z",5.26\],'
        # Hourly, from the hour: one point, and availability keeps two decimals, so 99.99 % isn't written as 100.
        (& $script:seriesOf $document 'ProvisionedThroughput').points | Should -Be @(, @('2026-11-18T17:00:00Z', 400))
        (& $script:seriesOf $document 'ServiceAvailability').points | Should -Be @(, @('2026-11-18T17:00:00Z', 99.99))
        $result.PointCount | Should -Be 241
        $result.PeakNormalizedRu | Should -Be 100
        $result.Requests | Should -Be 35400
        $result.ThrottledRequests | Should -Be 120
        # Names and numbers only: no resource ID or subscription.
        $result.Json | Should -Not -Match '(?i)/subscriptions/|11111111-2222|resourceGroups|management\.azure\.com|documents\.azure\.com'
        $result.Notes | Should -BeNullOrEmpty
        $result.Message | Should -Match '^Azure Monitor metrics for the history: T5 \(cosmos01-abc123\), 7 series and 241 points from 2026-11-18 17:02 to 2026-11-18 18:02 UTC, every 1 minute\(s\) \(\d+\.\d KB\): normalized RU consumption peaked at 100%, 120 throttled request\(s\) \(429\) of 35,400\.$'
    }

    It 'reads each signal with Metrics - List, its query parameters in a file, the throttled requests filtered to StatusCode 429, and the hourly ones at PT1H' {
        $null = & $script:capture
        $metricCalls = @($script:azCalls | Where-Object { $_ -match 'providers/Microsoft\.Insights/metrics' })
        $metricCalls.Count | Should -Be 7
        $metricCalls | ForEach-Object { $_ | Should -Match '^rest --method get --url https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft\.DocumentDB/databaseAccounts/cosmos01-abc123/providers/Microsoft\.Insights/metrics --url-parameters @\S+metrics-\d\.json --output json$' }
        @($script:urlParameters | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_['metricnames'], $_['aggregation'], $_['interval'], $_['$filter'] }) | Should -Be @(
            'NormalizedRUConsumption|Maximum|PT1M|', 'TotalRequestUnits|Total|PT1M|', 'TotalRequests|Count|PT1M|', "TotalRequests|Count|PT1M|StatusCode eq '429'",
            'ServerSideLatencyGateway|Average|PT1M|', 'ProvisionedThroughput|Maximum|PT1H|', 'ServiceAvailability|Average|PT1H|')
        @($script:urlParameters | ForEach-Object { $_['timespan'] } | Select-Object -Unique) | Should -Be @('2026-11-18T17:02:00Z/2026-11-18T18:02:00Z', '2026-11-18T17:00:00Z/2026-11-18T18:02:00Z')
        $script:urlParameters | ForEach-Object { $_['api-version'] | Should -Not -BeNullOrEmpty }
        @($script:azCalls | Where-Object { $_ -match '--method (post|put|patch|delete)' }).Count | Should -Be 0 -Because 'it only reads'
        InModuleScope DbHubDemo { Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Directory -Filter 'dbhub-cosmoshistory*' -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty -Because 'the parameter files are removed after the reads'
    }

    It 'combines intervals to keep a day''s document within the size bound, Count as a sum and hourly series never finer than an hour' {
        $result = & $script:capture @{ WindowMinutes = 1440 }
        $result.Status | Should -Be 'Pass'
        $result.IntervalMinutes | Should -BeIn @(5, 15)
        $result.Bytes | Should -BeLessOrEqual 24576
        $document = ConvertFrom-TestJson -Json $result.Json
        $document.intervalMinutes | Should -Be $result.IntervalMinutes
        @($script:urlParameters | ForEach-Object { $_['interval'] }) | Should -Be @('PT1M', 'PT1M', 'PT1M', 'PT1M', 'PT1M', 'PT1H', 'PT1H') -Because 'Azure Monitor is read once; the intervals are combined here'
        # 18:02 the day before, three throttled minutes from 18:05: one interval holds all 120 of them.
        $throttled = & $script:seriesOf $document 'ThrottledRequests'
        $throttled.intervalMinutes | Should -Be $result.IntervalMinutes
        @($throttled.points | ForEach-Object { $_[1] } | Measure-Object -Sum).Sum | Should -Be 120
        (& $script:seriesOf $document 'NormalizedRUConsumption').points[0][1] | Should -Be 100 -Because 'Maximum keeps the storm''s peak'
        (& $script:seriesOf $document 'ProvisionedThroughput').intervalMinutes | Should -Be 60
        $result.Notes | Should -Contain ('Combined the 1-minute intervals into {0}-minute ones to keep the document within 24,576 bytes.' -f $result.IntervalMinutes)
    }

    It 'returns no JSON and a Warning when Azure Monitor has no data for T5' {
        $script:fake.NoData = $true
        $result = & $script:capture
        $result.Json | Should -Be ''
        $result.Status | Should -Be 'Warning'
        $result.PointCount | Should -Be 0
        $result.Notes | Should -Be @('T5 (cosmos01-abc123) had no Azure Monitor data from 2026-11-18 17:02 to 2026-11-18 18:02 UTC (no requests yet, or its metrics haven''t arrived), so it''s left out.')
        $result.Message | Should -Match '^No Azure Cosmos DB metrics go to the history: T5 \(cosmos01-abc123\) had no Azure Monitor data'
    }

    It 'never throws for a failed read: <Case>' -ForEach @(
        @{ Case = 'an Azure CLI error, redacted'; Setting = 'MetricsError' }
        @{ Case = 'an exception from the Azure CLI call'; Setting = 'MetricsThrow' }
    ) {
        $script:fake[$Setting] = $true
        $result = & $script:capture
        $result.Json | Should -Be ''
        $result.Status | Should -Be 'Warning'
        $result.Message | Should -Match '^T5''s Azure Monitor metrics couldn''t be read, so none go to the history: T5''s NormalizedRUConsumption \(Maximum\) couldn''t be read: '
        @($result.Notes).Count | Should -Be 7 -Because 'each of the seven reads failed'
        ($result.Notes -join ' ') | Should -Not -Match ('Z' * 24) -Because 'errors are redacted'
    }

    It 'reads nothing when there''s nothing to read: <Case>' -ForEach @(
        @{ Case = 'T5 turned off'; Pattern = '^T5 is turned off \(t5Enabled is false\)'; Calls = 0 }
        @{ Case = 'no deploymentId tag'; Pattern = '^T5''s account isn''t known \(the resource group has no deploymentId tag'; Calls = 1 }
        @{ Case = 'T5 not deployed'; Pattern = '^No Azure Cosmos DB metrics go to the history: T5 \(cosmos01-abc123\) doesn''t exist \(T5 isn''t deployed yet: \./scripts/deploy\.ps1 creates it\), so it''s left out\.$'; Calls = 2 }
        @{ Case = 'an account Azure Monitor doesn''t know'; Pattern = '^No Azure Cosmos DB metrics go to the history: T5 \(cosmos01-abc123\) isn''t there for Azure Monitor'; Calls = 3 }
    ) {
        $config = New-TestConfig
        switch ($Case) {
            'T5 turned off' { $config['t5Enabled'] = $false }
            'no deploymentId tag' { $script:fake.Tagged = $false }
            'T5 not deployed' { $script:fake.Exists = $false }
            default { $script:fake.MetricsMissing = $true }
        }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config; NowUtc = $script:now } { Get-DemoCosmosHistoryParameter -Config $Config -NowUtc $NowUtc -WindowMinutes 60 }
        $result.Status | Should -Be 'Not selected'
        $result.Json | Should -Be ''
        $result.Message | Should -Match $Pattern
        @($script:azCalls).Count | Should -Be $Calls -Because 'the resource group''s tag, then T5, then its first metric, is read only when it''s needed'
    }
}

Describe 'Get-DemoCosmosHistoryCapture (2026-11-18, ADR 0027)' {
    BeforeEach {
        Reset-CosmosFake
        Initialize-CosmosAzMock
    }

    It 'gives the JSON and a T5 result line with what was captured, under the caller''s check ID' {
        $capture = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoCosmosHistoryCapture -Config $Config -WindowMinutes 60 -CheckId 'FABRIC.T5.HISTORY' -DeploymentId 'abc123' }
        $capture.Json | Should -Match '^\{"version":1,'
        $capture.Result.checkId | Should -Be 'FABRIC.T5.HISTORY'
        $capture.Result.area | Should -Be 'fabric'
        $capture.Result.target | Should -Be 'T5'
        $capture.Result.status | Should -Be 'Pass'
        $capture.Result.docUrl | Should -Be 'https://learn.microsoft.com/fabric/database/hub/monitor-cosmos-db'
        $capture.Result.evidence['account'] | Should -Be 'cosmos01-abc123'
        $capture.Result.evidence['throttledRequests'] | Should -Be 120
        $capture.Result.evidence['peakNormalizedRuPercent'] | Should -Be 100
        @($script:azCalls | Where-Object { $_ -like 'group show*' }) | Should -BeNullOrEmpty -Because 'the caller gave the deploymentId'
    }

    It 'never throws, and logs nothing, when the Azure CLI fails: a Warning with what to do' {
        $script:fake.GroupThrow = $true
        $capture = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoCosmosHistoryCapture -Config $Config -WindowMinutes 60 }
        $capture.Json | Should -Be ''
        $capture.Result.checkId | Should -Be 'STOP.T5.HISTORY'
        $capture.Result.status | Should -Be 'Warning'
        $capture.Result.message | Should -Match '^T5''s metrics weren''t read for the history: its account couldn''t be resolved'
        $capture.Result.remediation | Should -Match 'stop-demo\.ps1 -SaveHistory'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 0 -Exactly
    }
}
