BeforeAll {
    # T4's PostgreSQL metrics for the history (2026-11-13, ADR 0025): Get-DemoPostgresHistoryParameter reads T4's and its
    # read replica's Azure Monitor metrics with the Azure CLI and returns the notebook's POSTGRES_METRICS JSON. No network:
    # Invoke-DemoAz is mocked, and its metrics answer with points for the timespan and interval the read asked for.
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

    $script:units = @{
        cpu_percent                           = 'Percent'
        memory_percent                        = 'Percent'
        active_connections                    = 'Count'
        connections_failed                    = 'Count'
        physical_replication_delay_in_bytes   = 'Bytes'
        physical_replication_delay_in_seconds = 'Seconds'
    }

    # The value of a metric at the i-th interval of a read, or $null for no data. The last interval of every read has no
    # value, as Azure Monitor answers for an interval that hasn't closed yet.
    function Get-TestValue([string] $Server, [string] $Metric, [int] $Index, [int] $Count) {
        if ($Index -eq $Count - 1 -or $script:fake[$Server].NoData) {
            return $null
        }
        switch ($Metric) {
            'cpu_percent' { return $(if ($Server -eq 'pgflex01') { $(if ($Index -eq 7) { 91.26 } else { 40.04 + ($Index % 3) }) } else { 10.26 }) }
            'memory_percent' { return 30.15 }
            'active_connections' { return [double](12 + ($Index % 3)) }
            'connections_failed' { return [double]($Index % 4) }
            'physical_replication_delay_in_bytes' { return 184 }
            'physical_replication_delay_in_seconds' { return $(if ($Index -eq 3) { 241.37 } else { 2 + ($Index % 5) }) }
        }
        return $null
    }

    # A Metrics - List answer for the read's timespan, interval, metric names, and aggregation.
    function New-MetricsBody([string] $Server, [System.Collections.IDictionary] $Query) {
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $range = ([string]$Query['timespan']).Split('/')
        $start = [datetime]::Parse($range[0], [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        $end = [datetime]::Parse($range[1], [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        $step = @{ PT1M = 1; PT5M = 5; PT15M = 15; PT30M = 30; PT1H = 60 }[[string]$Query['interval']]
        $count = [int][System.Math]::Ceiling(($end - $start).TotalMinutes / $step)
        $field = ([string]$Query['aggregation']).ToLowerInvariant()
        $metrics = foreach ($name in ([string]$Query['metricnames']).Split(',')) {
            $data = for ($index = 0; $index -lt $count; $index++) {
                $point = [ordered]@{ timeStamp = $start.AddMinutes($index * $step).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) }
                $value = Get-TestValue -Server $Server -Metric $name -Index $index -Count $count
                if ($null -ne $value) {
                    $point[$field] = $value
                }
                $point
            }
            [ordered]@{ name = @{ value = $name; localizedValue = $name }; unit = $script:units[$name]; timeseries = @(@{ metadatavalues = @(); data = @($data) }) }
        }
        [ordered]@{ cost = 0; timespan = $Query['timespan']; interval = $Query['interval']; value = @($metrics) }
    }

    # A mock of Invoke-DemoAz for the reads: the resource group's tag, each server, and its metrics. $script:fake holds what
    # exists, and $script:azCalls and $script:urlParameters what the reads sent.
    function Initialize-PostgresAzMock {
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
                $tags = if ($script:fake.Tagged) { [pscustomobject]@{ deploymentId = 'abc123' } } else { [pscustomobject]@{} }
                if ($AsJson) {
                    return [pscustomobject]@{ tags = $tags }
                }
                return (New-AzResult -Json @{ tags = $tags })
            }
            if ($text -match '--url \S+/flexibleServers/(pgflex01|pgreplica01)-abc123/providers/Microsoft\.Insights/metrics ') {
                $server = $Matches[1]
                if ($script:fake[$server].MetricsThrow) {
                    throw 'The Azure CLI isn''t installed.'
                }
                if ($script:fake[$server].MetricsError) {
                    return (New-AzResult -ExitCode 1 -StdErr ('ERROR: (InvalidAuthenticationToken) The access token expired. Authorization: Bearer {0}' -f ('Z' * 24)))
                }
                return (New-AzResult -Json (New-MetricsBody -Server $server -Query $query))
            }
            if ($text -match '--method get --url \S+/flexibleServers/(pgflex01|pgreplica01)-abc123\?') {
                $server = $Matches[1]
                if (-not $script:fake[$server].Exists) {
                    return (New-AzResult -ExitCode 1 -StdErr ("ERROR: (ResourceNotFound) The Resource 'Microsoft.DBforPostgreSQL/flexibleServers/{0}-abc123' under resource group 'rg-dbhub-demo' was not found." -f $server))
                }
                return (New-AzResult -Json @{ name = ('{0}-abc123' -f $server); sku = @{ name = $script:fake[$server].Sku; tier = 'GeneralPurpose' }; properties = @{ state = 'Ready' } })
            }
            throw "unexpected Azure CLI call: $text"
        }
    }

    function Reset-PostgresFake {
        $script:fake = @{
            Tagged      = $true
            pgflex01    = @{ Exists = $true; Sku = 'Standard_D4ds_v5'; NoData = $false; MetricsError = $false; MetricsThrow = $false }
            pgreplica01 = @{ Exists = $true; Sku = 'Standard_D4ds_v5'; NoData = $false; MetricsError = $false; MetricsThrow = $false }
        }
    }

    # 18:02:37 UTC: the window ends at 18:02 and starts on the interval boundary before 18:02 minus the window.
    $script:now = [datetime]::new(2026, 11, 13, 18, 2, 37, [System.DateTimeKind]::Utc)
    $script:capture = {
        param([hashtable] $Extra = @{})
        $arguments = @{ Config = (New-TestConfig); NowUtc = $script:now; WindowMinutes = 60 }
        foreach ($key in $Extra.Keys) {
            $arguments[$key] = $Extra[$key]
        }
        InModuleScope DbHubDemo -Parameters @{ Arguments = $arguments } { param($Arguments) Get-DemoPostgresHistoryParameter @Arguments }
    }
    $script:seriesOf = {
        param([object] $Document, [string] $Role, [string] $Metric)
        @($Document.series | Where-Object { $_.role -eq $Role -and $_.metric -eq $Metric }) | Select-Object -First 1
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoPostgresHistoryParameter (2026-11-13, ADR 0025)' {
    BeforeEach {
        Reset-PostgresFake
        Initialize-PostgresAzMock
    }

    It 'reads T4 and its read replica and returns compact version 1 JSON with only the points that have a value' {
        $result = & $script:capture
        $result.Status | Should -Be 'Pass'
        $result.ServerCount | Should -Be 2
        $result.SeriesCount | Should -Be 8
        $result.IntervalMinutes | Should -Be 5
        $result.Json | Should -Not -Match '\s' -Because 'the parameter is compact JSON'
        $result.Bytes | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount($result.Json))
        $document = ConvertFrom-TestJson -Json $result.Json
        $document.version | Should -Be 1
        $document.capturedUtc | Should -Be '2026-11-13T18:02:00Z'
        $document.startUtc | Should -Be '2026-11-13T17:00:00Z'
        $document.endUtc | Should -Be '2026-11-13T18:02:00Z'
        $document.windowMinutes | Should -Be 60
        $document.intervalMinutes | Should -Be 5
        $result.Json | Should -Match ([regex]::Escape('"servers":[{"role":"primary","target":"T4","resourceName":"pgflex01-abc123","sku":"Standard_D4ds_v5"},{"role":"replica","target":"T4-replica","resourceName":"pgreplica01-abc123","sku":"Standard_D4ds_v5"}],"series":['))
        @($document.series | ForEach-Object { '{0}:{1}:{2}:{3}' -f $_.role, $_.metric, $_.aggregation, $_.unit }) | Should -Be @(
            'primary:cpu_percent:Maximum:Percent', 'primary:memory_percent:Maximum:Percent', 'primary:active_connections:Maximum:Count',
            'primary:physical_replication_delay_in_bytes:Maximum:Bytes', 'primary:connections_failed:Total:Count',
            'replica:physical_replication_delay_in_seconds:Maximum:Seconds', 'replica:cpu_percent:Maximum:Percent', 'replica:active_connections:Maximum:Count')
        # 17:00 to 18:02 is 13 intervals; the last one (18:00) has no value yet, so 12 points remain in each series.
        $lag = & $script:seriesOf $document 'replica' 'physical_replication_delay_in_seconds'
        @($lag.points).Count | Should -Be 12
        $lag.resourceName | Should -Be 'pgreplica01-abc123'
        $lag.points[0][0] | Should -Be '2026-11-13T17:00:00Z'
        $lag.points[3][1] | Should -Be 241.4 -Because 'seconds keep one decimal'
        $lag.points[-1][0] | Should -Be '2026-11-13T17:55:00Z'
        $result.PointCount | Should -Be 96
        # Percent keeps one decimal, counts and bytes are whole numbers, written without decimals.
        (& $script:seriesOf $document 'primary' 'cpu_percent').points[7][1] | Should -Be 91.3
        $result.Json | Should -Match '"metric":"active_connections","aggregation":"Maximum","unit":"Count","points":\[\["2026-11-13T17:00:00Z",12\],'
        $result.Json | Should -Match '"physical_replication_delay_in_bytes","aggregation":"Maximum","unit":"Bytes","points":\[\["2026-11-13T17:00:00Z",184\],'
        # Names and numbers only: no resource ID or subscription.
        $result.Json | Should -Not -Match '(?i)/subscriptions/|11111111-2222|resourceGroups|management\.azure\.com'
        @($result.Servers | ForEach-Object { '{0}={1}' -f $_.Target, $_.ResourceName }) | Should -Be @('T4=pgflex01-abc123', 'T4-replica=pgreplica01-abc123')
        $result.Notes | Should -BeNullOrEmpty
        $result.Message | Should -Match '^Azure Monitor metrics for the history: T4 \(pgflex01-abc123\) and T4''s read replica \(pgreplica01-abc123\), 8 series and 96 points from 2026-11-13 17:00 to 2026-11-13 18:02 UTC, every 5 minutes'
    }

    It 'reads each server''s metrics with Metrics - List, its query parameters in a file, at the interval asked for' {
        $null = & $script:capture
        $metricCalls = @($script:azCalls | Where-Object { $_ -match 'providers/Microsoft\.Insights/metrics' })
        $metricCalls.Count | Should -Be 3
        $metricCalls | ForEach-Object { $_ | Should -Match '^rest --method get --url https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft\.DBforPostgreSQL/flexibleServers/pg(flex|replica)01-abc123/providers/Microsoft\.Insights/metrics --url-parameters @\S+metrics-\d\.json --output json$' }
        @($script:urlParameters | ForEach-Object { '{0}|{1}' -f $_['aggregation'], $_['metricnames'] }) | Should -Be @(
            'Maximum|cpu_percent,memory_percent,active_connections,physical_replication_delay_in_bytes', 'Total|connections_failed',
            'Maximum|physical_replication_delay_in_seconds,cpu_percent,active_connections')
        $script:urlParameters | ForEach-Object {
            $_['interval'] | Should -Be 'PT5M'
            $_['timespan'] | Should -Be '2026-11-13T17:00:00Z/2026-11-13T18:02:00Z'
            $_['api-version'] | Should -Not -BeNullOrEmpty
        }
        @($script:azCalls | Where-Object { $_ -match '--method (post|put|patch|delete)' }).Count | Should -Be 0 -Because 'it only reads'
        InModuleScope DbHubDemo { Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Directory -Filter 'dbhub-pghistory*' -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty -Because 'the parameter files are removed after the reads'
    }

    It 'leaves out a read replica that doesn''t exist, between sessions, with a note' {
        $script:fake.pgreplica01.Exists = $false
        $result = & $script:capture
        $result.Status | Should -Be 'Pass'
        $result.ServerCount | Should -Be 1
        $result.SeriesCount | Should -Be 5
        $document = ConvertFrom-TestJson -Json $result.Json
        @($document.servers | ForEach-Object { $_.resourceName }) | Should -Be @('pgflex01-abc123')
        @($document.series | Where-Object { $_.role -eq 'replica' }).Count | Should -Be 0
        @($script:azCalls | Where-Object { $_ -match 'pgreplica01-abc123/providers/Microsoft\.Insights/metrics' }).Count | Should -Be 0 -Because 'a replica that doesn''t exist has no metrics to read'
        $result.Notes | Should -Be @('T4''s read replica (pgreplica01-abc123) doesn''t exist (it exists only during a session: start-demo.ps1 creates it, and stop-demo.ps1 deletes it), so it''s left out.')
        $result.Message | Should -Match 'doesn''t exist \(it exists only during a session'
    }

    It 'reads one server with -SkipReplica or -ReplicaOnly, and refuses both' {
        $primary = & $script:capture @{ SkipReplica = $true }
        @($primary.Servers.Target) | Should -Be @('T4')
        $replica = & $script:capture @{ ReplicaOnly = $true }
        @($replica.Servers.Target) | Should -Be @('T4-replica')
        @((ConvertFrom-TestJson -Json $replica.Json).series | ForEach-Object { $_.metric }) | Should -Be @('physical_replication_delay_in_seconds', 'cpu_percent', 'active_connections')
        { & $script:capture @{ SkipReplica = $true; ReplicaOnly = $true } } | Should -Throw '*leave nothing to read*'
    }

    It 'combines intervals, 5 into 15 minutes, to keep a day''s document within the size bound' {
        $result = & $script:capture @{ WindowMinutes = 1440 }
        $result.Status | Should -Be 'Pass'
        $result.IntervalMinutes | Should -Be 15 -Because '288 five-minute points in each of 8 series are over 24 KB, and 96 fifteen-minute ones fit'
        $result.Bytes | Should -BeLessOrEqual 24576
        $result.Bytes | Should -BeGreaterThan 8192
        $document = ConvertFrom-TestJson -Json $result.Json
        $document.intervalMinutes | Should -Be 15
        $document.startUtc | Should -Be '2026-11-12T18:00:00Z'
        @($script:urlParameters | ForEach-Object { $_['interval'] }) | Should -Be @('PT5M', 'PT5M', 'PT5M') -Because 'Azure Monitor is read once; the intervals are combined here'
        # Total adds the three 5-minute counts up (0 + 1 + 2, then 3 + 0 + 1), and Maximum keeps the highest (40.04, 41.04, 42.04).
        $failed = & $script:seriesOf $document 'primary' 'connections_failed'
        $failed.points[0] | Should -Be @('2026-11-12T18:00:00Z', 3)
        $failed.points[1] | Should -Be @('2026-11-12T18:15:00Z', 4)
        (& $script:seriesOf $document 'primary' 'cpu_percent').points[0] | Should -Be @('2026-11-12T18:00:00Z', 42)
        (& $script:seriesOf $document 'replica' 'physical_replication_delay_in_seconds').points[1][1] | Should -Be 241.4 -Because 'the 18:15 interval holds the 18:15 peak'
        $result.Notes | Should -Contain 'Combined the 5-minute intervals into 15-minute ones to keep the document within 24,576 bytes.'
    }

    It 'keeps combining past an hour under a smaller bound, never going over it' {
        $result = & $script:capture @{ WindowMinutes = 1440; MaxBytes = 4096 }
        $result.Status | Should -Be 'Pass'
        $result.IntervalMinutes | Should -Be 180
        $result.Bytes | Should -BeLessOrEqual 4096
        (ConvertFrom-TestJson -Json $result.Json).intervalMinutes | Should -Be 180
    }

    It 'returns no JSON and a Warning when Azure Monitor has no data for either server' {
        $script:fake.pgflex01.NoData = $true
        $script:fake.pgreplica01.NoData = $true
        $result = & $script:capture
        $result.Json | Should -Be ''
        $result.Status | Should -Be 'Warning'
        $result.ServerCount | Should -Be 0
        $result.PointCount | Should -Be 0
        $result.Notes.Count | Should -Be 2
        $result.Notes[0] | Should -Be 'T4 (pgflex01-abc123) had no Azure Monitor data from 2026-11-13 17:00 to 2026-11-13 18:02 UTC (stopped, or its metrics haven''t arrived yet), so it''s left out.'
        $result.Message | Should -Match '^No PostgreSQL metrics go to the history: T4 \(pgflex01-abc123\) had no Azure Monitor data'
    }

    It 'never throws for a failed read: <Case>' -ForEach @(
        @{ Case = 'an Azure CLI error, redacted'; Setting = 'MetricsError' }
        @{ Case = 'an exception from the Azure CLI call'; Setting = 'MetricsThrow' }
    ) {
        $script:fake.pgflex01[$Setting] = $true
        $script:fake.pgreplica01[$Setting] = $true
        $result = & $script:capture
        $result.Json | Should -Be ''
        $result.Status | Should -Be 'Warning'
        $result.Message | Should -Match '^T4''s Azure Monitor metrics couldn''t be read, so none go to the history: T4''s cpu_percent, memory_percent, active_connections, physical_replication_delay_in_bytes \(Maximum\) couldn''t be read: '
        @($result.Notes).Count | Should -Be 3 -Because 'each of the three reads failed'
        ($result.Notes -join ' ') | Should -Not -Match ('Z' * 24) -Because 'errors are redacted'
    }

    It 'keeps what it read when only the replica''s read fails, as a Warning' {
        $script:fake.pgreplica01.MetricsError = $true
        $result = & $script:capture
        $result.Status | Should -Be 'Warning'
        @($result.Servers.Target) | Should -Be @('T4')
        $result.SeriesCount | Should -Be 5
        $result.Notes | Should -HaveCount 1
        $result.Notes[0] | Should -Match '^T4''s read replica''s physical_replication_delay_in_seconds, cpu_percent, active_connections \(Maximum\) couldn''t be read: ERROR: \(InvalidAuthenticationToken\) .*Bearer \[REDACTED\]'
    }

    It 'reads nothing when there''s nothing to read: <Case>' -ForEach @(
        @{ Case = 'T4 turned off'; Pattern = '^T4 is turned off \(t4Enabled is false\)'; Calls = 0 }
        @{ Case = 'no deploymentId tag'; Pattern = '^T4''s server isn''t known \(the resource group has no deploymentId tag'; Calls = 1 }
        @{ Case = 'T4 not deployed'; Pattern = '^No PostgreSQL metrics go to the history: T4 \(pgflex01-abc123\) doesn''t exist \(T4 isn''t deployed\), so it''s left out\.$'; Calls = 2 }
    ) {
        $config = New-TestConfig
        switch ($Case) {
            'T4 turned off' { $config['t4Enabled'] = $false }
            'no deploymentId tag' { $script:fake.Tagged = $false }
            default {
                $script:fake.pgflex01.Exists = $false
                $script:fake.pgreplica01.Exists = $false
            }
        }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config; NowUtc = $script:now } { Get-DemoPostgresHistoryParameter -Config $Config -NowUtc $NowUtc -WindowMinutes 60 }
        $result.Status | Should -Be 'Not selected'
        $result.Json | Should -Be ''
        $result.Message | Should -Match $Pattern
        @($script:azCalls).Count | Should -Be $Calls -Because 'the resource group''s tag, then T4, is read only when it''s needed, and a replica can''t exist without T4'
        @($script:azCalls | Where-Object { $_ -match 'Microsoft\.Insights/metrics' }).Count | Should -Be 0
    }
}
