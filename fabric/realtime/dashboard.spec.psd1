# Layout of the Real-Time Dashboard (Phase 18): the presenter's live view, as code.
#
# Export-DemoRealTimeDashboard builds fabric/realtime/RealTimeDashboard.json from this file and the KQL in
# scripts/modules/DbHubDemo/Kql: each query is Live.Prelude.kql followed by the fragments listed in Kql. The Live.*
# bodies are the live-activity notebook's own KQL (a test keeps them identical), and the Dashboard.* fragments add
# the Target parameter and each tile's shape. Edit this file or the KQL, run Export-DemoRealTimeDashboard, and
# commit both; tests/unit/Fabric.Dashboard.Tests.ps1 fails when the committed JSON is out of date.
#
# The format is the KQL dashboard item definition (RealTimeDashboard.json) at the schema version pinned in
# config/versions.json (databaseHub.realTimeDashboard). Element IDs are deterministic UUIDs derived from the keys
# below, so a rebuild changes nothing unless the layout does. Real IDs never appear here: the data source is the
# documented SQL ADX proxy, and the resource group is filled in at import time.
#
# Look ("operations cockpit"): status numbers in large multi stat tiles, and color only for status, through
# conditional formatting (red, yellow, green). The schema has no theme property, so the dashboard follows the
# Fabric portal's appearance. Layout units follow the dashboard grid, 24 columns wide.
@{
    Title       = 'Database Hub demo - live view'

    # Auto-refresh every minute; viewers can't pick a faster rate, which keeps the load on the proxy small.
    AutoRefresh = @{ Enabled = $true; DefaultInterval = '1m'; MinInterval = '1m' }

    DataSource  = @{ Key = 'telemetry'; Name = 'SQL telemetry (Database Hub, preview)' }

    # The demo's fixed names (docs/architecture.md). _target() in Live.Prelude.kql maps telemetry rows to T1-T3
    # by these names; the resource group comes from the configuration at import time.
    Names       = @{
        Database       = 'ContosoCare'
        VmName         = 'sqlvm01'
        ArcMachineName = 'arcsql01'
        ServerPrefix   = 'azuresql01-'
    }

    Parameters  = @{
        TimeRange = @{ DisplayName = 'Time range'; DefaultHours = 1 }
        Targets   = @{
            DisplayName = 'Target'
            Description = 'T1, T2, T3, or all of them.'
            Values      = @(
                @{ Value = 'T1'; DisplayText = 'T1 sqlvm01 (SQL Server on Azure VM)' }
                @{ Value = 'T2'; DisplayText = 'T2 arcsql01 (SQL Server enabled by Azure Arc)' }
                @{ Value = 'T3'; DisplayText = 'T3 ContosoCare (Azure SQL Database)' }
            )
        }
    }

    Pages       = @(
        @{ Key = 'estate-pulse'; Name = 'Estate pulse' }
        @{ Key = 'incident'; Name = 'Incident' }
        @{ Key = 'resources'; Name = 'Resources' }
    )

    Queries     = @(
        @{ Key = 'estate-pulse'; Kql = @('Live.EstatePulse', 'Dashboard.SelectTargets', 'Dashboard.EstatePulse') }
        @{ Key = 'heartbeat'; Kql = @('Dashboard.Heartbeat', 'Dashboard.SelectTargets') }
        @{ Key = 'blocked-now'; Kql = @('Live.CounterGauges', 'Dashboard.SelectTargets', 'Dashboard.BlockedNow') }
        @{ Key = 'blocked-timeline'; Kql = @('Live.CounterGauges', 'Dashboard.SelectTargets', 'Dashboard.BlockedTimeline') }
        @{ Key = 'wait-categories'; Kql = @('Live.WaitDeltas', 'Dashboard.SelectTargets', 'Dashboard.WaitCategoryTimeline') }
        @{ Key = 'sessions'; Kql = @('Live.ActiveSessions', 'Dashboard.SelectTargets', 'Dashboard.SessionsTimeline') }
        @{ Key = 'batch-requests'; Kql = @('Live.CounterDeltas', 'Dashboard.SelectTargets', 'Dashboard.BatchRequestsTimeline') }
        @{ Key = 'cpu-timeline'; Kql = @('Live.CpuTimeline', 'Dashboard.SelectTargets', 'Dashboard.CpuTimeline') }
        @{ Key = 'cpu-summary'; Kql = @('Live.CpuSummary', 'Dashboard.SelectTargets', 'Dashboard.CpuSummary') }
        @{ Key = 'memory-clerks'; Kql = @('Live.MemoryClerks', 'Dashboard.SelectTargets', 'Dashboard.MemoryClerks') }
        @{ Key = 'storage-io-timeline'; Kql = @('Live.StorageIoDeltas', 'Dashboard.SelectTargets', 'Dashboard.StorageIoTimeline') }
        @{ Key = 'storage-io-summary'; Kql = @('Live.StorageIoDeltas', 'Dashboard.SelectTargets', 'Dashboard.StorageIoSummary') }
    )

    Tiles       = @(
        # Estate pulse: is every target reporting, and how fresh is its newest sample?
        @{
            Key      = 'note'
            Page     = 'estate-pulse'
            Title    = 'About this view'
            Visual   = 'markdownCard'
            Layout   = @{ X = 0; Y = 0; Width = 24; Height = 2 }
            Markdown = '**Live view of the Database Hub telemetry endpoint (preview).** Samples arrive a few minutes after the activity, and each viewer sees only the resources their own Azure access allows. No data is not zero.'
        }
        @{
            Key        = 'freshness'
            Page       = 'estate-pulse'
            Title      = 'Freshness per target'
            Visual     = 'multistat'
            Query      = 'estate-pulse'
            Layout     = @{ X = 0; Y = 2; Width = 10; Height = 5 }
            Label      = 'Target'
            Value      = 'Freshness'
            Slots      = 3
            ColorRules = @(
                @{ Name = 'Fresh'; Column = 'State'; Operator = '=='; Values = @('Fresh'); Color = 'green'; Icon = 'completed' }
                @{ Name = 'Stale'; Column = 'State'; Operator = '=='; Values = @('Stale'); Color = 'yellow'; Icon = 'warning' }
                @{ Name = 'No data'; Column = 'State'; Operator = '=='; Values = @('No data'); Color = 'red'; Icon = 'critical' }
            )
        }
        @{
            Key        = 'reporting'
            Page       = 'estate-pulse'
            Title      = 'Reporting per target: tables, rows, and the newest sample'
            Visual     = 'table'
            Query      = 'estate-pulse'
            Layout     = @{ X = 10; Y = 2; Width = 14; Height = 5 }
            ColorRules = @(
                @{ Name = 'Fresh'; Column = 'State'; Operator = '=='; Values = @('Fresh'); Color = 'green'; Icon = 'completed' }
                @{ Name = 'Stale'; Column = 'State'; Operator = '=='; Values = @('Stale'); Color = 'yellow'; Icon = 'warning' }
                @{ Name = 'No data'; Column = 'State'; Operator = '=='; Values = @('No data'); Color = 'red'; Icon = 'critical' }
            )
        }
        @{
            Key    = 'heartbeat'
            Page   = 'estate-pulse'
            Title  = 'Telemetry heartbeat: CPU samples per bin'
            Visual = 'timechart'
            Query  = 'heartbeat'
            Layout = @{ X = 0; Y = 7; Width = 24; Height = 6 }
            X      = 'Bucket'
            Y      = @('Samples')
            Series = @('Target')
            YTitle = 'samples'
        }

        # Incident: blocking, waits, sessions, throughput, and CPU, side by side.
        @{
            Key        = 'blocked-now'
            Page       = 'incident'
            Title      = 'Processes blocked, latest sample'
            Visual     = 'multistat'
            Query      = 'blocked-now'
            Layout     = @{ X = 0; Y = 0; Width = 24; Height = 3 }
            Label      = 'Target'
            Value      = 'BlockedProcesses'
            Slots      = 3
            ColorRules = @(
                @{ Name = 'No blocking'; Column = 'BlockedProcesses'; Operator = '=='; Values = @('0'); Color = 'green'; Icon = 'completed' }
                @{ Name = 'Blocking'; Column = 'BlockedProcesses'; Operator = '>'; Values = @('0'); Color = 'red'; Icon = 'critical' }
            )
        }
        @{
            Key    = 'blocked-timeline'
            Page   = 'incident'
            Title  = 'Processes blocked'
            Visual = 'timechart'
            Query  = 'blocked-timeline'
            Layout = @{ X = 0; Y = 3; Width = 12; Height = 6 }
            X      = 'Bucket'
            Y      = @('BlockedProcesses')
            Series = @('Target')
            YTitle = 'processes'
        }
        @{
            Key    = 'wait-categories'
            Page   = 'incident'
            Title  = 'Waits by category, seconds per bin (Lock means blocking)'
            Visual = 'timechart'
            Query  = 'wait-categories'
            Layout = @{ X = 12; Y = 3; Width = 12; Height = 6 }
            X      = 'Bucket'
            Y      = @('WaitSeconds')
            Series = @('WaitCategory')
            YTitle = 'seconds'
        }
        @{
            Key    = 'sessions'
            Page   = 'incident'
            Title  = 'Active sessions in ContosoCare'
            Visual = 'timechart'
            Query  = 'sessions'
            Layout = @{ X = 0; Y = 9; Width = 8; Height = 6 }
            X      = 'Bucket'
            Y      = @('ActiveSessions')
            Series = @('Target')
            YTitle = 'sessions'
        }
        @{
            Key    = 'batch-requests'
            Page   = 'incident'
            Title  = 'Batch requests per second'
            Visual = 'timechart'
            Query  = 'batch-requests'
            Layout = @{ X = 8; Y = 9; Width = 8; Height = 6 }
            X      = 'Bucket'
            Y      = @('BatchRequestsPerSec')
            Series = @('Target')
            YTitle = 'requests/s'
        }
        @{
            Key    = 'cpu'
            Page   = 'incident'
            Title  = 'CPU % (T3: % of the service tier limit)'
            Visual = 'timechart'
            Query  = 'cpu-timeline'
            Layout = @{ X = 16; Y = 9; Width = 8; Height = 6 }
            X      = 'Bucket'
            Y      = @('CpuPercent')
            Series = @('Target')
            YTitle = '% CPU'
        }

        # Resources: CPU, memory, and storage IO.
        @{
            Key        = 'cpu-p95'
            Page       = 'resources'
            Title      = 'CPU, 95th percentile over the time range (%)'
            Visual     = 'multistat'
            Query      = 'cpu-summary'
            Layout     = @{ X = 0; Y = 0; Width = 24; Height = 3 }
            Label      = 'Target'
            Value      = 'P95CpuPercent'
            Slots      = 3
            # The last matching rule wins, so 85 is red, not yellow.
            ColorRules = @(
                @{ Name = 'Under 70'; Column = 'P95CpuPercent'; Operator = '<'; Values = @('70'); Color = 'green'; Icon = 'completed' }
                @{ Name = '70 or more'; Column = 'P95CpuPercent'; Operator = '>='; Values = @('70'); Color = 'yellow'; Icon = 'warning' }
                @{ Name = '80 or more'; Column = 'P95CpuPercent'; Operator = '>='; Values = @('80'); Color = 'red'; Icon = 'critical' }
            )
        }
        @{
            Key    = 'cpu'
            Page   = 'resources'
            Title  = 'CPU % (T3: % of the service tier limit)'
            Visual = 'timechart'
            Query  = 'cpu-timeline'
            Layout = @{ X = 0; Y = 3; Width = 12; Height = 6 }
            X      = 'Bucket'
            Y      = @('CpuPercent')
            Series = @('Target')
            YTitle = '% CPU'
        }
        @{
            Key    = 'memory'
            Page   = 'resources'
            Title  = 'Largest memory clerks, MB at the latest sample'
            Visual = 'bar'
            Query  = 'memory-clerks'
            Layout = @{ X = 12; Y = 3; Width = 12; Height = 6 }
            X      = 'MemoryClerkType'
            Y      = @('MemoryMB')
            Series = @('Target')
            YTitle = 'MB'
        }
        @{
            Key    = 'storage-io'
            Page   = 'resources'
            Title  = 'Data and log IO, MB per bin'
            Visual = 'timechart'
            Query  = 'storage-io-timeline'
            Layout = @{ X = 0; Y = 9; Width = 12; Height = 6 }
            X      = 'Bucket'
            Y      = @('IoMB')
            Series = @('Target')
            YTitle = 'MB'
        }
        @{
            Key    = 'storage-io-summary'
            Page   = 'resources'
            Title  = 'Storage IO over the time range (latency not available for T3)'
            Visual = 'table'
            Query  = 'storage-io-summary'
            Layout = @{ X = 12; Y = 9; Width = 12; Height = 6 }
        }
    )
}
