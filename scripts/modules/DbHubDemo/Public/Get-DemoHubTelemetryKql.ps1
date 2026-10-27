function Get-DemoHubTelemetryKql {
    <#
    .SYNOPSIS
    Builds a read-only KQL query for the Database Hub telemetry endpoint from a template in
    scripts/modules/DbHubDemo/Kql.

    .DESCRIPTION
    Every template follows the rules in "Query performance monitoring telemetry (preview)"
    (https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry,
    checked 2026-10-20): it filters on SampleTimeUTC first, takes deltas of cumulative counters instead of
    summing them, branches on CounterType, groups by ResourceID and SqlServerInstanceName, compares
    ResourceID case-insensitively, and limits its rows. Parameters are rendered as KQL literals, so they
    can't change the query's structure.

    - ResourceSummary: rows, first and last sample, and instances per target (CPU table, query 1).
    - TableSummary: rows per telemetry table per target.
    - WaitCategoryDeltas: wait seconds per wait category from deltas of the cumulative wait counters (query 5).
    - CounterGauges: gauge and percentage counters (CounterType 65792 and 537003264), read directly (query 8).
    - CounterRates: cumulative counters (CounterType 272696576) as totals and per-second rates (query 9).

    The output can be pasted into the Azure Data Explorer web UI (connection
    https://adx.centralus.arcdataservices.com/kusto/, database ArcSqlTelemetry) when the REST call isn't
    available.

    .PARAMETER Name
    The template.

    .PARAMETER ResourceId
    Azure Resource Manager IDs of the targets (the telemetry ResourceID column).

    .PARAMETER LookbackMinutes
    How far back to read, at most the 7-day retention.

    .PARAMETER Since
    ResourceSummary only: rows at or after this UTC time are also counted separately (RowsSince,
    FirstSampleSinceUTC), for example since a database was created. Defaults to the start of the lookback.

    .PARAMETER SubscriptionId
    ResourceSummary only: with ResourceGroup, rows from other resources in that resource group are returned
    too, so a ResourceID mismatch is visible.

    .PARAMETER ResourceGroup
    ResourceSummary only; see SubscriptionId.

    .PARAMETER CounterName
    CounterGauges and CounterRates only: the counters to read. The defaults are the blocking, load, and
    throughput counters the demo scenarios produce.

    .EXAMPLE
    Get-DemoHubTelemetryKql -Name ResourceSummary -ResourceId $t1Id, $t3Id -LookbackMinutes 60
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ResourceSummary', 'TableSummary', 'WaitCategoryDeltas', 'CounterGauges', 'CounterRates')]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/[A-Za-z0-9.]+/[A-Za-z0-9./_-]+$')]
        [string[]] $ResourceId,

        [ValidateRange(1, 10080)]
        [int] $LookbackMinutes = 60,

        [datetime] $Since,

        [AllowEmptyString()]
        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId = '',

        [AllowEmptyString()]
        [ValidatePattern('^$|^[A-Za-z0-9._()-]{1,90}$')]
        [string] $ResourceGroup = '',

        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Za-z0-9 ()/%_.:-]+$')]
        [string[]] $CounterName
    )

    $parameters = [ordered]@{
        Lookback = ConvertTo-DemoKqlLiteral -Value ([timespan]::FromMinutes($LookbackMinutes)) -Type Timespan
        Targets  = ConvertTo-DemoKqlLiteral -Value $ResourceId -Type StringArray
    }

    switch ($Name) {
        'ResourceSummary' {
            # Without -Since, every row in the lookback counts as "since".
            $parameters['Since'] = if ($PSBoundParameters.ContainsKey('Since')) { ConvertTo-DemoKqlLiteral -Value $Since -Type Datetime } else { 'ago(lookback)' }
            $parameters['SubscriptionId'] = ConvertTo-DemoKqlLiteral -Value $SubscriptionId -Type String
            $parameters['ResourceGroup'] = ConvertTo-DemoKqlLiteral -Value $ResourceGroup -Type String
        }
        'CounterGauges' {
            $names = if ($PSBoundParameters.ContainsKey('CounterName')) { $CounterName } else { @('Processes blocked', 'Active Transactions', 'User Connections', 'Page life expectancy', 'Buffer cache hit ratio') }
            $parameters['CounterNames'] = ConvertTo-DemoKqlLiteral -Value $names -Type StringArray
        }
        'CounterRates' {
            $names = if ($PSBoundParameters.ContainsKey('CounterName')) { $CounterName } else { @('Batch Requests/sec', 'Transactions/sec', 'Number of Deadlocks/sec', 'SQL Compilations/sec', 'Errors/sec', 'Page reads/sec') }
            $parameters['CounterNames'] = ConvertTo-DemoKqlLiteral -Value $names -Type StringArray
        }
    }

    return (Format-DemoKqlTemplate -Name ('Telemetry.{0}' -f $Name) -Parameters $parameters)
}
