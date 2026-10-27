// The DAX catalog: every query the app runs against SM_DatabaseHub_History, with its row bound and the
// columns a visual shows. Measure and column names come from the model's TMDL
// (fabric/powerbi/SM_DatabaseHub_History.SemanticModel); "show the query" displays this exact text.

import { args, bucketRange, dateFilter, targetFilter, type DateWindow, type TargetKey } from "../lib/dax";

export type ColumnKind = "text" | "int" | "decimal" | "percent" | "seconds" | "minutes" | "mb" | "datetime" | "status" | "url";

export interface ColumnSpec {
    key: string;
    label: string;
    kind: ColumnKind;
}

export interface QuerySpec {
    /** Stable ID: the cache key prefix and the CSV file name. */
    id: string;
    title: string;
    dax: string;
    /** Sent as resultSetRowCountLimit: a result over the bound fails as 'overflow' instead of looking complete. */
    rowLimit: number;
    columns: ColumnSpec[];
}

export interface Filters {
    targets: TargetKey[];
    window: DateWindow | null;
}

const SERIES_MEASURES = [
    '"Cpu", [CPU (%)]',
    '"Blocked", [Blocked Processes (peak)]',
    '"LockWaitS", [Lock Wait (s)]',
    '"BufferIoS", [Buffer IO Wait (s)]',
    '"LogRateS", [Log Rate Governor Wait (s)]',
    '"WaitS", [Wait Time (s)]',
    '"IoMb", [Data and Log IO (MB)]',
    '"Batch", [Batch Requests]',
    '"Sessions", [Active Sessions (peak)]',
];

const SERIES_COLUMNS: ColumnSpec[] = [
    { key: "Cpu", label: "CPU, average (%)", kind: "percent" },
    { key: "Blocked", label: "Blocked processes, peak", kind: "int" },
    { key: "LockWaitS", label: "Lock waits (s)", kind: "seconds" },
    { key: "BufferIoS", label: "Buffer IO waits (s)", kind: "seconds" },
    { key: "LogRateS", label: "Log Rate Governor waits (s)", kind: "seconds" },
    { key: "WaitS", label: "Wait time (s)", kind: "seconds" },
    { key: "IoMb", label: "Data and log IO (MB)", kind: "mb" },
    { key: "Batch", label: "Batch requests", kind: "int" },
    { key: "Sessions", label: "Active sessions, peak", kind: "int" },
];

/**
 * Freshness and size of the history, without filters. Anchors the time windows to the newest data. The T3 columns
 * anchor the deploy-time check's replay (catalogForCheck): the newest T3 incident window, and T3's newest bin.
 */
export function metaQuery(): QuerySpec {
    const t3Incidents = `TOPN ( 1, CALCULATETABLE ( 'Incident Windows', REMOVEFILTERS (), ${targetFilter(["T3"])} ), 'Incident Windows'[Window Start UTC], DESC )`;
    return {
        id: "history-meta",
        title: "History freshness",
        rowLimit: 1,
        dax: `EVALUATE
ROW (
    "LatestCapture", [Latest Capture UTC],
    "LatestDay", CALCULATE ( MAX ( 'Telemetry Snapshots'[Report Date UTC] ), REMOVEFILTERS () ),
    "EarliestDay", CALCULATE ( MIN ( 'Telemetry Snapshots'[Report Date UTC] ), REMOVEFILTERS () ),
    "HoursSince", [Hours Since Latest Capture],
    "Freshness", [History Freshness Status],
    "NotebookRuns", [Notebook Runs Captured],
    "ScenarioRequests", [Scenario Requests],
    "Incidents", CALCULATE ( COUNTROWS ( 'Incident Windows' ), REMOVEFILTERS () ),
    "HasBins", [Has Telemetry Bins],
    "T3IncidentStart", MAXX ( ${t3Incidents}, 'Incident Windows'[Window Start UTC] ),
    "T3IncidentEnd", MAXX ( ${t3Incidents}, 'Incident Windows'[Window End UTC] ),
    "T3LatestBucket", CALCULATE ( MAX ( 'Telemetry Snapshots'[Bucket UTC] ), REMOVEFILTERS (), ${targetFilter(["T3"])} )
)`,
        columns: [
            { key: "LatestCapture", label: "Latest capture (UTC)", kind: "datetime" },
            { key: "LatestDay", label: "Newest telemetry day (UTC)", kind: "datetime" },
            { key: "EarliestDay", label: "Oldest telemetry day (UTC)", kind: "datetime" },
            { key: "HoursSince", label: "Hours since the latest capture", kind: "decimal" },
            { key: "Freshness", label: "History freshness", kind: "status" },
            { key: "NotebookRuns", label: "Notebook runs captured", kind: "int" },
            { key: "ScenarioRequests", label: "Scenario requests", kind: "int" },
            { key: "Incidents", label: "Incident windows", kind: "int" },
            { key: "HasBins", label: "Has telemetry bins", kind: "int" },
            { key: "T3IncidentStart", label: "Newest T3 incident window start (UTC)", kind: "datetime" },
            { key: "T3IncidentEnd", label: "Newest T3 incident window end (UTC)", kind: "datetime" },
            { key: "T3LatestBucket", label: "Newest T3 bin (UTC)", kind: "datetime" },
        ],
    };
}

/** One row per SQL target: the key signals, findings, coverage, and incidents in the window. */
export function estateQuery(f: Filters): QuerySpec {
    return {
        id: "estate-targets",
        title: "Estate: key signals per target",
        rowLimit: 10,
        dax: `EVALUATE
SUMMARIZECOLUMNS (
    ${args([
        "'Target'[Target Key]",
        "'Target'[Target]",
        "'Target'[Platform]",
        targetFilter(f.targets),
        dateFilter(f.window),
        '"CpuAvg", [CPU (%)]',
        '"CpuPeak", [CPU Peak (%)]',
        '"BlockedPeak", [Blocked Processes (peak)]',
        '"LockWaitS", [Lock Wait (s)]',
        '"BufferIoS", [Buffer IO Wait (s)]',
        '"LogRateS", [Log Rate Governor Wait (s)]',
        '"WaitS", [Wait Time (s)]',
        '"IoMb", [Data and Log IO (MB)]',
        '"BatchRequests", [Batch Requests]',
        '"SessionsPeak", [Active Sessions (peak)]',
        '"Deadlocks", [Deadlocks]',
        '"FindingsAttention", [Findings Needing Attention]',
        '"WorstFindingSort", [Worst Finding Status Sort]',
        '"LagMin", [Telemetry Lag at Capture (min)]',
        '"CoverageTables", [Coverage Tables (selected run)]',
        '"CoverageAgeMin", [Coverage Last Sample Age (min)]',
        '"Incidents", [Incidents]',
        "\"Bins\", CALCULATE ( DISTINCTCOUNT ( 'Telemetry Snapshots'[Bucket UTC] ), KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = \"cpu\" ) )",
    ])}
)
ORDER BY 'Target'[Target Key]`,
        columns: [
            { key: "Target Key", label: "Target", kind: "text" },
            { key: "Platform", label: "Platform", kind: "text" },
            { key: "CpuAvg", label: "CPU, average (%)", kind: "percent" },
            { key: "CpuPeak", label: "CPU, peak (%)", kind: "percent" },
            { key: "BlockedPeak", label: "Blocked processes, peak", kind: "int" },
            { key: "BufferIoS", label: "Buffer IO waits (s)", kind: "seconds" },
            { key: "LogRateS", label: "Log Rate Governor waits (s)", kind: "seconds" },
            { key: "WaitS", label: "Wait time (s)", kind: "seconds" },
            { key: "BatchRequests", label: "Batch requests", kind: "int" },
            { key: "SessionsPeak", label: "Active sessions, peak", kind: "int" },
            { key: "FindingsAttention", label: "Findings needing attention", kind: "int" },
            { key: "LagMin", label: "Telemetry lag at capture (min)", kind: "minutes" },
            { key: "CoverageTables", label: "Telemetry tables (latest validation run)", kind: "int" },
            { key: "CoverageAgeMin", label: "Newest sample age (min)", kind: "minutes" },
            { key: "Incidents", label: "Incident windows", kind: "int" },
            { key: "Bins", label: "CPU bins in the window", kind: "int" },
        ],
    };
}

/** The model's own headline sentences for the window (measures Estate Headline and Readiness Headline). */
export function headlineQuery(f: Filters): QuerySpec {
    const filter = dateFilter(f.window);
    const row = `ROW ( "EstateHeadline", [Estate Headline], "ReadinessHeadline", [Readiness Headline], "Freshness", [History Freshness Label] )`;
    return {
        id: "headlines",
        title: "Headlines from the model's measures",
        rowLimit: 1,
        dax: filter ? `EVALUATE\nCALCULATETABLE (\n    ${row},\n    ${filter}\n)` : `EVALUATE\n${row}`,
        columns: [
            { key: "EstateHeadline", label: "Estate headline", kind: "text" },
            { key: "ReadinessHeadline", label: "Readiness headline", kind: "text" },
            { key: "Freshness", label: "History freshness", kind: "text" },
        ],
    };
}

/** The latest capture of every finding in the window, worst status first. */
export function findingsQuery(f: Filters): QuerySpec {
    const filter = dateFilter(f.window);
    const scope = filter ? `CALCULATETABLE ( 'Analysis Findings', ${filter} )` : "'Analysis Findings'";
    return {
        id: "findings-latest",
        title: "What changed: the latest findings",
        rowLimit: 500,
        dax: `EVALUATE
VAR FindingRows = ${scope}
VAR LatestRows =
    FILTER (
        FindingRows,
        'Analysis Findings'[Captured At UTC]
            = CALCULATE ( MAX ( 'Analysis Findings'[Captured At UTC] ), ALLEXCEPT ( 'Analysis Findings', 'Analysis Findings'[Finding ID] ) )
    )
RETURN
    SELECTCOLUMNS (
        LatestRows,
        "FindingId", 'Analysis Findings'[Finding ID],
        "AnalysisKey", 'Analysis Findings'[Analysis Key],
        "Analysis", RELATED ( 'Analysis'[Analysis] ),
        "TargetKey", 'Analysis Findings'[Target Key],
        "Status", 'Analysis Findings'[Status Key],
        "StatusSort", RELATED ( 'Status'[Status Sort] ),
        "Finding", 'Analysis Findings'[Finding],
        "CapturedAt", 'Analysis Findings'[Captured At UTC]
    )
ORDER BY [StatusSort] ASC, [CapturedAt] DESC`,
        columns: [
            { key: "Status", label: "Status", kind: "status" },
            { key: "TargetKey", label: "Target", kind: "text" },
            { key: "Analysis", label: "Analysis", kind: "text" },
            { key: "Finding", label: "Finding", kind: "text" },
            { key: "CapturedAt", label: "Captured (UTC)", kind: "datetime" },
            { key: "FindingId", label: "Finding ID", kind: "text" },
        ],
    };
}

/** Every telemetry bin per target in the window, with the main signals (latest capture of each bin wins). */
export function seriesQuery(f: Filters): QuerySpec {
    return {
        id: "signals-per-bin",
        title: "Signals per bin and target",
        rowLimit: 20000,
        dax: `EVALUATE
SUMMARIZECOLUMNS (
    ${args(["'Telemetry Snapshots'[Bucket UTC]", "'Target'[Target Key]", targetFilter(f.targets), dateFilter(f.window), ...SERIES_MEASURES])}
)
ORDER BY 'Telemetry Snapshots'[Bucket UTC], 'Target'[Target Key]`,
        columns: [
            { key: "Bucket UTC", label: "Bin start (UTC)", kind: "datetime" },
            { key: "Target Key", label: "Target", kind: "text" },
            ...SERIES_COLUMNS,
        ],
    };
}

/** Wait seconds per wait category and target in the window. */
export function waitsQuery(f: Filters): QuerySpec {
    return {
        id: "waits-by-category",
        title: "Where the wait time went",
        rowLimit: 1000,
        dax: `EVALUATE
SUMMARIZECOLUMNS (
    ${args(["'Telemetry Snapshots'[Metric]", "'Target'[Target Key]", targetFilter(f.targets), dateFilter(f.window), '"WaitS", [Wait Time (s)]'])}
)
ORDER BY [WaitS] DESC`,
        columns: [
            { key: "Metric", label: "Wait category", kind: "text" },
            { key: "Target Key", label: "Target", kind: "text" },
            { key: "WaitS", label: "Wait time (s)", kind: "seconds" },
        ],
    };
}

/** Incident windows in the window, newest first. */
export function incidentsQuery(f: Filters): QuerySpec {
    return {
        id: "incident-windows",
        title: "Incident windows",
        rowLimit: 500,
        dax: `EVALUATE
SELECTCOLUMNS (
    CALCULATETABLE ( ${args(["'Incident Windows'", targetFilter(f.targets), dateFilter(f.window)], "")} ),
    "Key", 'Incident Windows'[Incident Key],
    "Label", 'Incident Windows'[Incident],
    "Source", 'Incident Windows'[Source],
    "TargetKey", 'Incident Windows'[Target Key],
    "Scenario", 'Incident Windows'[Scenario],
    "Family", 'Incident Windows'[Signal Family],
    "Start", 'Incident Windows'[Window Start UTC],
    "End", 'Incident Windows'[Window End UTC],
    "DurationMin", 'Incident Windows'[Duration (min)],
    "PeakValue", 'Incident Windows'[Peak Value],
    "PeakUnit", 'Incident Windows'[Peak Unit],
    "Verdict", 'Incident Windows'[Correlation Status Key]
)
ORDER BY [Start] DESC`,
        columns: [
            { key: "Label", label: "Incident", kind: "text" },
            { key: "Source", label: "Source", kind: "text" },
            { key: "TargetKey", label: "Target", kind: "text" },
            { key: "Family", label: "Signal", kind: "text" },
            { key: "Start", label: "Start (UTC)", kind: "datetime" },
            { key: "End", label: "End (UTC)", kind: "datetime" },
            { key: "DurationMin", label: "Duration (min)", kind: "minutes" },
            { key: "PeakValue", label: "Peak", kind: "decimal" },
            { key: "PeakUnit", label: "Peak unit", kind: "text" },
            { key: "Verdict", label: "Expected-signal verdict", kind: "status" },
        ],
    };
}

export interface IncidentRange {
    target: TargetKey;
    start: Date;
    end: Date;
}

/** Every bin of one target from `start` to `end`, for the replay. */
export function incidentSeriesQuery(r: IncidentRange): QuerySpec {
    return {
        id: `replay-${r.target}`,
        title: `Replay: ${r.target}, bin by bin`,
        rowLimit: 5000,
        dax: `EVALUATE
SUMMARIZECOLUMNS (
    ${args(["'Telemetry Snapshots'[Bucket UTC]", targetFilter([r.target]), bucketRange(r.start, r.end), ...SERIES_MEASURES])}
)
ORDER BY 'Telemetry Snapshots'[Bucket UTC]`,
        columns: [{ key: "Bucket UTC", label: "Bin start (UTC)", kind: "datetime" }, ...SERIES_COLUMNS],
    };
}

/** Wait seconds per category and bin on one target from `start` to `end`, for the before-and-after spotlight. */
export function incidentWaitsQuery(r: IncidentRange): QuerySpec {
    return {
        id: `spotlight-${r.target}`,
        title: `Waits before and during: ${r.target}`,
        rowLimit: 5000,
        dax: `EVALUATE
SUMMARIZECOLUMNS (
    ${args(["'Telemetry Snapshots'[Bucket UTC]", "'Telemetry Snapshots'[Metric]", targetFilter([r.target]), bucketRange(r.start, r.end), '"WaitS", [Wait Time (s)]'])}
)
ORDER BY 'Telemetry Snapshots'[Bucket UTC]`,
        columns: [
            { key: "Bucket UTC", label: "Bin start (UTC)", kind: "datetime" },
            { key: "Metric", label: "Wait category", kind: "text" },
            { key: "WaitS", label: "Wait time (s)", kind: "seconds" },
        ],
    };
}

/** Every check of the latest six validation runs. */
export function readinessChecksQuery(): QuerySpec {
    return {
        id: "readiness-checks",
        title: "Validation checks, latest six runs",
        rowLimit: 3000,
        dax: `EVALUATE
VAR Runs = TOPN ( 6, VALUES ( 'Validation Results'[Run ID] ), 'Validation Results'[Run ID], DESC )
RETURN
    SELECTCOLUMNS (
        CALCULATETABLE ( 'Validation Results', TREATAS ( Runs, 'Validation Results'[Run ID] ) ),
        "RunId", 'Validation Results'[Run ID],
        "CheckId", 'Validation Results'[Check ID],
        "Area", 'Validation Results'[Area],
        "TargetKey", 'Validation Results'[Target Key],
        "Status", 'Validation Results'[Status Key],
        "StatusSort", RELATED ( 'Status'[Status Sort] ),
        "Message", 'Validation Results'[Message],
        "Remediation", 'Validation Results'[Remediation],
        "DocUrl", 'Validation Results'[Documentation],
        "EvaluationOnly", 'Validation Results'[Evaluation Only],
        "CheckedAt", 'Validation Results'[Checked At UTC]
    )
ORDER BY [RunId] DESC, [StatusSort] ASC, [CheckId] ASC`,
        columns: [
            { key: "Status", label: "Status", kind: "status" },
            { key: "CheckId", label: "Check", kind: "text" },
            { key: "Area", label: "Area", kind: "text" },
            { key: "TargetKey", label: "Target", kind: "text" },
            { key: "Message", label: "Message", kind: "text" },
            { key: "Remediation", label: "Remediation", kind: "text" },
            { key: "DocUrl", label: "Documentation", kind: "url" },
            { key: "CheckedAt", label: "Checked (UTC)", kind: "datetime" },
            { key: "RunId", label: "Run", kind: "text" },
        ],
    };
}

/** The model's readiness measures for the latest validation run. */
export function readinessSummaryQuery(): QuerySpec {
    return {
        id: "readiness-summary",
        title: "Readiness of the latest validation run",
        rowLimit: 1,
        dax: `EVALUATE
ROW (
    "Checks", [Checks (selected run)],
    "Failed", [Checks Failed (selected run)],
    "Manual", [Checks Needing a Manual Step (selected run)],
    "Warnings", [Checks With Warnings (selected run)],
    "Passed", [Checks Passed (selected run)],
    "NotSupported", [Checks Not Supported (selected run)],
    "NotSelected", [Checks Not Selected (selected run)],
    "Readiness", [Readiness (%)],
    "RunLabel", [Validation Run Label]
)`,
        columns: [
            { key: "Checks", label: "Checks", kind: "int" },
            { key: "Failed", label: "Failed", kind: "int" },
            { key: "Manual", label: "Manual action required", kind: "int" },
            { key: "Warnings", label: "Warnings", kind: "int" },
            { key: "Passed", label: "Passed", kind: "int" },
            { key: "NotSupported", label: "Not supported", kind: "int" },
            { key: "NotSelected", label: "Not selected", kind: "int" },
            { key: "Readiness", label: "Readiness (share of applicable checks)", kind: "decimal" },
            { key: "RunLabel", label: "Run", kind: "text" },
        ],
    };
}

/** Telemetry coverage per SQL target from the latest validation run. */
export function coverageQuery(): QuerySpec {
    return {
        id: "telemetry-coverage",
        title: "Telemetry coverage per target",
        rowLimit: 10,
        dax: `EVALUATE
SUMMARIZECOLUMNS (
    'Target'[Target Key],
    ${targetFilter(["T1", "T2", "T3"])},
    "Tables", [Coverage Tables (selected run)],
    "AgeMin", [Coverage Last Sample Age (min)],
    "Attention", [Coverage Attention]
)
ORDER BY 'Target'[Target Key]`,
        columns: [
            { key: "Target Key", label: "Target", kind: "text" },
            { key: "Tables", label: "Telemetry tables", kind: "int" },
            { key: "AgeMin", label: "Newest sample age (min)", kind: "minutes" },
            { key: "Attention", label: "Freshness", kind: "text" },
        ],
    };
}

/** The connection check: one row that proves the connector returns data. */
export function probeQuery(): QuerySpec {
    return {
        id: "connector-check",
        title: "Connector check",
        rowLimit: 1,
        dax: `EVALUATE
ROW (
    "ValidationRows", COUNTROWS ( 'Validation Results' ),
    "SnapshotRows", COUNTROWS ( 'Telemetry Snapshots' ),
    "Incidents", COUNTROWS ( 'Incident Windows' )
)`,
        columns: [
            { key: "ValidationRows", label: "Validation checks", kind: "int" },
            { key: "SnapshotRows", label: "Telemetry rows", kind: "int" },
            { key: "Incidents", label: "Incident windows", kind: "int" },
        ],
    };
}

/** The resource, instance, and database names the telemetry reported per SQL target, for the Database Agent prompts. */
export function targetNamesQuery(): QuerySpec {
    return {
        id: "target-names",
        title: "Resource names per target",
        rowLimit: 500,
        dax: `EVALUATE
SELECTCOLUMNS (
    FILTER (
        SUMMARIZE (
            'Telemetry Snapshots',
            'Telemetry Snapshots'[Target Key],
            'Telemetry Snapshots'[Resource Type],
            'Telemetry Snapshots'[Resource Name],
            'Telemetry Snapshots'[Instance Name],
            'Telemetry Snapshots'[Database Name]
        ),
        'Telemetry Snapshots'[Target Key] IN { "T1", "T2", "T3" }
    ),
    "TargetKey", 'Telemetry Snapshots'[Target Key],
    "ResourceType", 'Telemetry Snapshots'[Resource Type],
    "ResourceName", 'Telemetry Snapshots'[Resource Name],
    "InstanceName", 'Telemetry Snapshots'[Instance Name],
    "DatabaseName", 'Telemetry Snapshots'[Database Name]
)
ORDER BY [TargetKey]`,
        columns: [
            { key: "TargetKey", label: "Target", kind: "text" },
            { key: "ResourceType", label: "Resource type", kind: "text" },
            { key: "ResourceName", label: "Resource name", kind: "text" },
            { key: "InstanceName", label: "SQL instance", kind: "text" },
            { key: "DatabaseName", label: "Database", kind: "text" },
        ],
    };
}

/** What history-meta found for the deploy-time check's T3 replay; every field is optional. */
export interface CheckAnchors {
    t3IncidentStart?: Date | null;
    t3IncidentEnd?: Date | null;
    t3LatestBucket?: Date | null;
}

const HOUR_MS = 3600000;
const DAY_MS = 24 * HOUR_MS;
/** The check's replay spans 3 hours at most, so the spotlight (bins times wait categories) stays under its row bound. */
const CHECK_RANGE_MS = 3 * HOUR_MS;
const CHECK_PAD_MS = 15 * 60000;

const isInstant = (value: Date | null | undefined): value is Date => value instanceof Date && Number.isFinite(value.getTime());

/** Midnight UTC at the start of the instant's day. */
function startOfUtcDay(value: Date): Date {
    return new Date(Date.UTC(value.getUTCFullYear(), value.getUTCMonth(), value.getUTCDate()));
}

/**
 * The T3 range the deploy-time check replays, so `replay-T3` and `spotlight-T3` find bins: the newest T3 incident
 * window with 15 minutes on each side (its last 3 hours when it's longer); without one, the 3 hours up to T3's newest
 * bin; without either, the whole newest telemetry day. Phase 25a: the range used to end at midnight at the start of
 * the newest day (`[latestDay - 3 h, latestDay]`), the evening before any of that day's data.
 */
export function checkIncidentRange(latestDay: Date, anchors: CheckAnchors = {}): IncidentRange {
    const { t3IncidentStart: start, t3IncidentEnd: end, t3LatestBucket: bucket } = anchors;
    if (isInstant(start) && isInstant(end) && end.getTime() >= start.getTime()) {
        const to = end.getTime() + CHECK_PAD_MS;
        return { target: "T3", start: new Date(Math.max(start.getTime() - CHECK_PAD_MS, to - CHECK_RANGE_MS)), end: new Date(to) };
    }
    if (isInstant(bucket)) {
        return { target: "T3", start: new Date(bucket.getTime() - CHECK_RANGE_MS), end: bucket };
    }
    const day = startOfUtcDay(latestDay);
    return { target: "T3", start: day, end: new Date(day.getTime() + DAY_MS) };
}

/**
 * Every query with representative filters, for `npm run queries:export` and the deploy-time check. The IDs never
 * change. The week ends with the newest telemetry day: DATESBETWEEN takes whole days, so DATE ( newest day )
 * includes all of it.
 */
export function catalogForCheck(latestDay: Date, anchors: CheckAnchors = {}): QuerySpec[] {
    const day = startOfUtcDay(latestDay);
    const window = { from: new Date(day.getTime() - 6 * DAY_MS), to: day };
    const all: Filters = { targets: ["T1", "T2", "T3"], window: null };
    const week: Filters = { targets: ["T1", "T2", "T3"], window };
    const range = checkIncidentRange(latestDay, anchors);
    return [
        probeQuery(),
        metaQuery(),
        estateQuery(week),
        headlineQuery(week),
        findingsQuery(all),
        seriesQuery(week),
        waitsQuery(week),
        incidentsQuery(all),
        incidentSeriesQuery(range),
        incidentWaitsQuery(range),
        readinessChecksQuery(),
        readinessSummaryQuery(),
        coverageQuery(),
        targetNamesQuery(),
    ];
}
