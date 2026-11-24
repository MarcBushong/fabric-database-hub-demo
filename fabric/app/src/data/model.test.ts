import { describe, expect, it } from "vitest";

import { postgresEpisodes } from "@/lib/scoreboard";
import { FIXTURES } from "@/test/render";
import { catalogForCheck, checkIncidentRange, cosmosSeriesQuery, estateQuery, findingsQuery, incidentSeriesQuery, MONITOR_SERIES_ROW_LIMIT, postgresFindingsQuery, postgresSeriesQuery, targetNamesQuery } from "./queries";
import {
    beatFor,
    COSMOS_METRICS,
    cosmosSeries,
    latestCosmosCapture,
    latestPostgresCapture,
    oneReadingEach,
    perMinute,
    POSTGRES_METRICS,
    throttledRuns,
    throttleEpisodes,
    toCosmosCapture,
    postgresPeak,
    postgresSeries,
    postgresSkus,
    toAgentBeats,
    toBins,
    toChecks,
    toIncidents,
    toMeta,
    toPostgresCapture,
    toPostgresFindings,
    toTargetNames,
    toTargets,
    toWaitFlows,
    waitFamily,
} from "./model";

describe("model parsers", () => {
    it("reads the meta row, with blank measures as null", () => {
        const meta = toMeta([{ LatestCapture: "2026-10-21T20:30:00", LatestDay: "2026-10-21T00:00:00", HoursSince: null, NotebookRuns: 3, HasBins: 1 }]);
        expect(meta?.latestCapture?.toISOString()).toBe("2026-10-21T20:30:00.000Z");
        expect(meta?.hoursSince).toBeNull();
        expect(meta?.hasBins).toBe(true);
        expect(meta?.incidents).toBe(0);
        expect(toMeta([])).toBeNull();
    });

    it("keeps only the three SQL targets", () => {
        const targets = toTargets([{ "Target Key": "T3", CpuPeak: 97.5, Bins: 96 }, { "Target Key": "fabric" }, { "Target Key": "T1" }]);
        expect(targets.map((t) => t.key)).toEqual(["T3", "T1"]);
        expect(targets[0].cpuPeak).toBe(97.5);
        expect(targets[0].name).toBe("T3 · Azure SQL Database");
        expect(targets[1].bins).toBe(0);
    });

    it("sorts bins by time and drops rows without a target or time", () => {
        const bins = toBins([
            { "Bucket UTC": "2026-10-21T10:15:00", "Target Key": "T3", Cpu: 40 },
            { "Bucket UTC": "2026-10-21T10:00:00", "Target Key": "T3", Cpu: 20 },
            { "Bucket UTC": "junk", "Target Key": "T3" },
            { "Bucket UTC": "2026-10-21T10:00:00", "Target Key": "TX" },
        ]);
        expect(bins.map((b) => b.cpu)).toEqual([20, 40]);
    });

    it("sorts incidents newest first and computes missing durations", () => {
        const incidents = toIncidents([
            { Key: "a", TargetKey: "T2", Start: "2026-10-20T20:00:00", End: "2026-10-20T20:30:00", Family: "io" },
            { Key: "b", TargetKey: "T3", Start: "2026-10-21T10:00:00", End: "2026-10-21T17:00:00", DurationMin: 420, Family: "io" },
            { Key: "c", TargetKey: "T3", Start: null, End: "2026-10-21T17:00:00" },
        ]);
        expect(incidents.map((i) => i.key)).toEqual(["b", "a"]);
        expect(incidents[1].durationMin).toBe(30);
    });

    it("drops non-https documentation links", () => {
        const checks = toChecks([
            { RunId: "r", CheckId: "a", DocUrl: "https://learn.microsoft.com/fabric/" },
            { RunId: "r", CheckId: "b", DocUrl: "javascript:alert(1)" },
        ]);
        expect(checks.map((c) => c.docUrl)).toEqual(["https://learn.microsoft.com/fabric/", ""]);
    });

    it("keeps positive waits on SQL targets and groups categories into families", () => {
        const flows = toWaitFlows([
            { Metric: "Buffer IO (PAGEIOLATCH)", "Target Key": "T3", WaitS: 50 },
            { Metric: "CPU", "Target Key": "T3", WaitS: 0 },
            { Metric: "CPU", "Target Key": "tenant", WaitS: 5 },
        ]);
        expect(flows).toEqual([{ category: "Buffer IO (PAGEIOLATCH)", target: "T3", seconds: 50 }]);
        expect(waitFamily("Buffer IO (PAGEIOLATCH)")).toBe("Storage IO");
        expect(waitFamily("Worker Thread")).toBe("CPU and scheduling");
        expect(waitFamily("Lock")).toBe("Locks and latches");
        expect(waitFamily("Log Rate Governor")).toBe("Resource governance");
        expect(waitFamily("Something new")).toBe("Other");
    });

    it("names each target from the distinct name rows: the resource row wins, ContosoCare is the database", () => {
        const names = toTargetNames([
            { TargetKey: "T2", ResourceType: null, ResourceName: "arcsql01", InstanceName: "MSSQLSERVER", DatabaseName: "master" },
            { TargetKey: "T2", ResourceType: "machines", ResourceName: "arcsql01", InstanceName: null, DatabaseName: null },
            { TargetKey: "T2", ResourceType: null, ResourceName: null, InstanceName: null, DatabaseName: "ContosoCare" },
            { TargetKey: "T3", ResourceType: null, ResourceName: "azuresql01-test01/ContosoCare", InstanceName: "azuresql01-test01", DatabaseName: null },
            { TargetKey: "T1", ResourceType: "virtualMachines", ResourceName: "<script>", InstanceName: null, DatabaseName: null },
            { TargetKey: "fabric", ResourceType: "x", ResourceName: "y", InstanceName: null, DatabaseName: null },
        ]);
        expect(names.T2).toEqual({ resource: "arcsql01", resourceType: "machines", instance: "MSSQLSERVER", database: "ContosoCare" });
        expect(names.T3).toEqual({ resource: "azuresql01-test01/ContosoCare", resourceType: null, instance: "azuresql01-test01", database: null });
        expect(names.T1).toEqual({ resource: null, resourceType: null, instance: null, database: null });
        expect(Object.keys(names)).toEqual(["T1", "T2", "T3"]);
        expect(toTargetNames([])).toEqual({});
    });

    it("reads T4's latest PostgreSQL capture: its targets, servers, window, interval, and points, oldest first (ADR 0025)", () => {
        const row = (Bucket: string, TargetKey: unknown, Metric: string, Value: unknown, ResourceName = "pgreplica01-test01") => ({
            Bucket,
            TargetKey,
            ResourceName,
            Metric,
            Value,
            WindowStart: "2026-11-13T17:00:00",
            WindowEnd: "2026-11-13T18:02:00",
            CapturedAt: "2026-11-13T18:06:00",
        });
        const capture = toPostgresCapture([
            row("2026-11-13T17:05:00", "T4-replica", "physical_replication_delay_in_seconds", 241.4),
            row("2026-11-13T17:00:00", "T4-replica", "physical_replication_delay_in_seconds", 6),
            row("2026-11-13T17:10:00", "T4-replica", "physical_replication_delay_in_seconds", 241.4),
            row("2026-11-13T17:00:00", "T4", "cpu_percent", 43.3, "pgflex01-test01"),
            row("2026-11-13T17:00:00", "T1", "cpu_percent", 99),
            row("2026-11-13T17:00:00", "T4", "cpu_percent", null),
            row("junk", "T4", "cpu_percent", 1),
            row("2026-11-13T17:00:00", "T4", "<script>", 1),
        ]);
        expect(capture?.points).toHaveLength(4);
        expect(capture?.servers).toEqual({ "T4-replica": "pgreplica01-test01", T4: "pgflex01-test01" });
        expect(capture?.windowStart?.toISOString()).toBe("2026-11-13T17:00:00.000Z");
        expect(capture?.windowEnd?.toISOString()).toBe("2026-11-13T18:02:00.000Z");
        expect(capture?.capturedAt?.toISOString()).toBe("2026-11-13T18:06:00.000Z");
        expect(capture?.intervalMinutes).toBe(5);
        const lag = postgresSeries(capture, "T4-replica", "physical_replication_delay_in_seconds");
        expect(lag.map((p) => p.value)).toEqual([6, 241.4, 241.4]);
        expect(postgresPeak(lag)).toEqual({ value: 241.4, at: new Date(Date.UTC(2026, 10, 13, 17, 5)) });
        expect(postgresPeak([])).toBeNull();
        expect(postgresSeries(null, "T4", "cpu_percent")).toEqual([]);
        expect(toPostgresCapture([row("2026-11-13T17:00:00", "T3", "cpu_percent", 1)])).toBeNull();
    });

    it("reads the capture's findings worst first, and each server's size from the capture finding's evidence", () => {
        const findings = toPostgresFindings([
            { FindingId: "postgresql.T4.capture", TargetKey: "T4", Status: "Pass", StatusSort: 4, Evidence: '{"servers": [{"role": "primary", "sku": "Standard_D4ds_v5"}, {"role": "replica", "sku": "<b>"}, {"role": "other", "sku": "X"}]}' },
            { FindingId: "postgresql.T4-replica.lag", TargetKey: "T4-replica", Status: "Warning", StatusSort: 3, Evidence: "not json" },
            { FindingId: "", Status: "Fail", StatusSort: 1 },
        ]);
        expect(findings.map((f) => f.id)).toEqual(["postgresql.T4-replica.lag", "postgresql.T4.capture"]);
        expect(findings[0].evidence).toBeNull();
        expect(postgresSkus(findings)).toEqual({ T4: "Standard_D4ds_v5" });
        expect(postgresSkus([])).toEqual({});
    });

    it("reads T5's latest Cosmos DB capture: its account, its 1-minute interval, its series, and its throttling episodes", () => {
        const capture = toCosmosCapture(FIXTURES["cosmos-series"]);
        expect(capture).toMatchObject({ account: "cosmos01-test01", intervalMinutes: 1 });
        expect(cosmosSeries(capture, COSMOS_METRICS.throttled).map((p) => p.value)).toEqual([0, 0, 800, 760, 0, 0]);
        expect(cosmosSeries(capture, COSMOS_METRICS.provisioned)).toHaveLength(1);
        expect(toCosmosCapture([{ Bucket: "2026-11-13T17:00:00", Metric: "bad metric!", Value: 1 }])).toBeNull();
        expect(throttleEpisodes(FIXTURES["cosmos-findings"]).map((e) => [e.id, e.start?.toISOString()])).toEqual([["cosmosdb.T5.throttle.20261113T1702", "2026-11-13T17:02:00.000Z"]]);
        // Only the intervals that throttled are shaded, not the calm minutes of an episode.
        expect(throttledRuns(capture).map((r) => [r.from.toISOString(), r.to.toISOString()])).toEqual([["2026-11-13T17:02:00.000Z", "2026-11-13T17:04:00.000Z"]]);
        expect(throttledRuns(null)).toEqual([]);
    });
    it("reads each Database Agent beat's regression, response, and CPU from its evidence, and matches it to the incident it overlaps", () => {
        const beats = toAgentBeats([
            { FindingId: "a1", TargetKey: "T3", Status: "Pass", Finding: "Database Agent loop", Evidence: '{"regressUtc": "2026-10-21T10:03:00Z", "respondUtc": "2026-10-21T10:26:00Z", "cpuBeforePercent": 84, "cpuAfterPercent": 22.5}', RequestId: "session:abcd1234:05", WindowStart: "2026-10-21T10:00:00", WindowEnd: "2026-10-21T10:30:00" },
            { FindingId: "a0", TargetKey: "T3", Status: "Warning", Evidence: "not json", WindowStart: "2026-10-20T10:00:00", WindowEnd: "2026-10-20T10:30:00" },
            { FindingId: "", TargetKey: "T3" },
        ]);
        expect(beats.map((b) => b.id)).toEqual(["a1", "a0"]);
        expect(beats[0]).toMatchObject({ requestId: "session:abcd1234:05", cpuBefore: 84, cpuAfter: 22.5 });
        expect(beats[0].respondAt?.toISOString()).toBe("2026-10-21T10:26:00.000Z");
        expect(beats[1]).toMatchObject({ regressAt: null, respondAt: null, cpuBefore: null });
        const at = (iso: string) => new Date(`${iso}Z`);
        expect(beatFor({ target: "T3", start: at("2026-10-21T10:10:00"), end: at("2026-10-21T11:00:00") }, beats)?.id).toBe("a1");
        expect(beatFor({ target: "T1", start: at("2026-10-21T10:10:00"), end: at("2026-10-21T11:00:00") }, beats)).toBeNull();
        expect(beatFor({ target: "T3", start: at("2026-10-21T10:30:00"), end: at("2026-10-21T11:00:00") }, beats)).toBeNull();
    });
});

describe("query catalog", () => {
    const latest = new Date(Date.UTC(2026, 9, 21));
    const catalog = catalogForCheck(latest);

    it("has 21 bounded, unique, read-only queries, and marks the ones a healthy new environment has no rows for", () => {
        expect(catalog).toHaveLength(21);
        expect(new Set(catalog.map((q) => q.id)).size).toBe(21);
        expect(catalog.filter((q) => q.mayBeEmpty).map((q) => q.id)).toEqual(["readiness-checks", "scenario-runs", "agent-loop", "cosmos-series", "cosmos-findings"]);
        for (const q of catalog) {
            expect(q.dax.trimStart().startsWith("EVALUATE") || q.dax.trimStart().startsWith("DEFINE")).toBe(true);
            expect(q.rowLimit).toBeGreaterThan(0);
            expect(q.rowLimit).toBeLessThanOrEqual(20000);
            expect(q.columns.length).toBeGreaterThan(0);
        }
    });

    it("applies the target and date filters", () => {
        const q = estateQuery({ targets: ["T2"], window: { from: new Date(Date.UTC(2026, 9, 15)), to: latest } });
        expect(q.dax).toContain(`TREATAS ( { "T2" }, 'Target'[Target Key] )`);
        expect(q.dax).toContain("DATESBETWEEN ( 'Date'[Date], DATE ( 2026, 10, 15 ), DATE ( 2026, 10, 21 ) )");
        expect(findingsQuery({ targets: ["T1", "T2", "T3"], window: null }).dax).not.toContain("DATESBETWEEN");
    });

    it("bounds the replay to the incident's bins on one target", () => {
        const q = incidentSeriesQuery({ target: "T3", start: new Date(Date.UTC(2026, 9, 21, 9)), end: new Date(Date.UTC(2026, 9, 21, 18)) });
        expect(q.id).toBe("replay-T3");
        expect(q.dax).toContain(`TREATAS ( { "T3" }, 'Target'[Target Key] )`);
        expect(q.dax).toContain("TIME ( 9, 0, 0 )");
    });

    // Phase 25a (2026-10-26): the check anchored T3's replay at midnight at the start of the newest day, 2026-10-22
    // 21:00 to 2026-10-23 00:00, so replay-T3 and spotlight-T3 found no bins in the newest day's 20:00-21:28 history.
    describe("the check's T3 replay range", () => {
        const newest = new Date(Date.UTC(2026, 9, 23));
        const ids = [
            "connector-check",
            "history-meta",
            "estate-targets",
            "headlines",
            "findings-latest",
            "signals-per-bin",
            "waits-by-category",
            "incident-windows",
            "replay-T3",
            "spotlight-T3",
            "readiness-checks",
            "readiness-summary",
            "telemetry-coverage",
            "target-names",
            "postgres-series",
            "postgres-findings",
            "scenario-runs",
            "daily-trend",
            "agent-loop",
            "cosmos-series",
            "cosmos-findings",
        ];

        it("lies in the newest telemetry day when history-meta has no anchors", () => {
            const range = checkIncidentRange(newest);
            expect(range).toEqual({ target: "T3", start: newest, end: new Date(Date.UTC(2026, 9, 24)) });
            const replay = catalogForCheck(newest).find((q) => q.id === "replay-T3");
            expect(replay?.dax).toContain("'Telemetry Snapshots'[Bucket UTC] >= DATE ( 2026, 10, 23 ) + TIME ( 0, 0, 0 )");
            expect(replay?.dax).toContain("'Telemetry Snapshots'[Bucket UTC] <= DATE ( 2026, 10, 24 ) + TIME ( 0, 0, 0 )");
            // Phase 25a's live bins (20:00 to 21:28 on the newest day) now fall inside.
            const bin = Date.UTC(2026, 9, 23, 20, 13);
            expect(bin >= range.start.getTime() && bin <= range.end.getTime()).toBe(true);
        });

        it("takes the newest T3 incident window, padded by 15 minutes, when history-meta has one", () => {
            const range = checkIncidentRange(newest, {
                t3IncidentStart: new Date(Date.UTC(2026, 9, 23, 20, 13)),
                t3IncidentEnd: new Date(Date.UTC(2026, 9, 23, 20, 34)),
                t3LatestBucket: new Date(Date.UTC(2026, 9, 23, 21, 27)),
            });
            expect(range).toEqual({ target: "T3", start: new Date(Date.UTC(2026, 9, 23, 19, 58)), end: new Date(Date.UTC(2026, 9, 23, 20, 49)) });
        });

        it("keeps a long incident's last 3 hours, so the spotlight stays under its row bound", () => {
            const range = checkIncidentRange(newest, { t3IncidentStart: new Date(Date.UTC(2026, 9, 23, 8)), t3IncidentEnd: new Date(Date.UTC(2026, 9, 23, 20)) });
            expect(range.end.getTime() - range.start.getTime()).toBe(3 * 3600000);
            expect(range.end).toEqual(new Date(Date.UTC(2026, 9, 23, 20, 15)));
        });

        it("falls back to the 3 hours up to T3's newest bin, and ignores an incident without a valid end", () => {
            const bucket = new Date(Date.UTC(2026, 9, 23, 21, 27));
            expect(checkIncidentRange(newest, { t3LatestBucket: bucket })).toEqual({ target: "T3", start: new Date(Date.UTC(2026, 9, 23, 18, 27)), end: bucket });
            expect(checkIncidentRange(newest, { t3IncidentStart: new Date(Date.UTC(2026, 9, 23, 21)), t3IncidentEnd: new Date(Date.UTC(2026, 9, 23, 20)), t3LatestBucket: bucket }).end).toEqual(bucket);
            expect(checkIncidentRange(newest, { t3IncidentStart: new Date(Number.NaN), t3IncidentEnd: bucket }).start).toEqual(newest);
        });

        it("anchors to the start of the newest day even from a later instant", () => {
            expect(checkIncidentRange(new Date(Date.UTC(2026, 9, 23, 15, 30))).start).toEqual(newest);
        });

        it("keeps every query ID, and ends the week with the newest day", () => {
            expect(catalogForCheck(newest).map((q) => q.id)).toEqual(ids);
            expect(catalogForCheck(newest, { t3LatestBucket: new Date(Date.UTC(2026, 9, 23, 21)) }).map((q) => q.id)).toEqual(ids);
            const estate = catalogForCheck(newest).find((q) => q.id === "estate-targets");
            expect(estate?.dax).toContain("DATESBETWEEN ( 'Date'[Date], DATE ( 2026, 10, 17 ), DATE ( 2026, 10, 23 ) )");
        });

        it("asks history-meta for the anchors", () => {
            const meta = catalogForCheck(newest).find((q) => q.id === "history-meta");
            expect(meta?.dax).toContain(`"T3IncidentStart", MAXX ( TOPN ( 1, CALCULATETABLE ( 'Incident Windows', REMOVEFILTERS (), TREATAS ( { "T3" }, 'Target'[Target Key] ) ), 'Incident Windows'[Window Start UTC], DESC ), 'Incident Windows'[Window Start UTC] )`);
            expect(meta?.dax).toContain(`"T3IncidentEnd", MAXX ( TOPN ( 1,`);
            expect(meta?.dax).toContain(`"T3LatestBucket", CALCULATE ( MAX ( 'Telemetry Snapshots'[Bucket UTC] ), REMOVEFILTERS (), TREATAS ( { "T3" }, 'Target'[Target Key] ) )`);
            expect(meta?.columns.map((c) => c.key)).toEqual(expect.arrayContaining(["LatestDay", "T3IncidentStart", "T3IncidentEnd", "T3LatestBucket"]));
        });
    });

    it("reads the target names from the snapshots of the three SQL targets only", () => {
        const q = targetNamesQuery();
        expect(q.id).toBe("target-names");
        expect(q.dax).toContain(`'Telemetry Snapshots'[Target Key] IN { "T1", "T2", "T3" }`);
        expect(q.columns.map((c) => c.key)).toEqual(["TargetKey", "ResourceType", "ResourceName", "InstanceName", "DatabaseName"]);
    });

    it("reads T4's findings from the latest PostgreSQL capture's run, and T4's and T5's metrics from every save in its window, whatever the filters (ADR 0025, F35)", () => {
        const latestRun = `CALCULATE ( MAX ( 'Analysis Findings'[Captured At UTC] ), REMOVEFILTERS (), 'Analysis Findings'[Analysis Key] = "postgresql" )`;
        for (const q of [postgresSeriesQuery(), postgresFindingsQuery()]) {
            expect(q.dax).toContain(latestRun);
            expect(q.dax).not.toContain("DATESBETWEEN");
            expect(q.dax).not.toContain("'Target'[Target Key]");
        }
        expect(postgresFindingsQuery().dax).toContain(`'Analysis Findings'[Analysis Key] = "postgresql",\n            TREATAS ( LatestRun, 'Analysis Findings'[Run ID] )`);
        for (const [q, analysis] of [
            [postgresSeriesQuery(), "postgresql"],
            [cosmosSeriesQuery(), "cosmosdb"],
        ] as const) {
            // The latest run gives the window; every save's points in it, and a day before it for their steps, the newest first.
            expect(q.dax).toContain(`VAR WindowStart =\n    CALCULATE ( MIN ( 'Telemetry Snapshots'[Window Start UTC] ), REMOVEFILTERS (), 'Telemetry Snapshots'[Analysis Key] = "${analysis}", TREATAS ( LatestRun, 'Telemetry Snapshots'[Run ID] ) )`);
            expect(q.dax).toContain(`'Telemetry Snapshots'[Window End UTC] > WindowStart,\n            'Telemetry Snapshots'[Window Start UTC] < WindowEnd,\n            'Telemetry Snapshots'[Bucket UTC] >= WindowStart - 1,\n            'Telemetry Snapshots'[Bucket UTC] <= WindowEnd\n        ),`);
            expect(q.dax).not.toContain("TREATAS ( LatestRun, 'Telemetry Snapshots'[Run ID] )\n        ),");
            expect(q.dax).toMatch(/ORDER BY \[CapturedAt\] DESC, \[Bucket\] ASC/);
            expect(q.rowLimit).toBe(MONITOR_SERIES_ROW_LIMIT);
            expect(q.columns.map((c) => c.key)).toEqual(["Bucket", "TargetKey", "ResourceName", "Metric", "Value", "Unit", "WindowStart", "WindowEnd", "CapturedAt"]);
        }
    });
});

// A live test's saves (2026-11-21): the session's own at its end (T4 every 5 minutes, T5 every minute) and a day-long one
// four hours later (every 15 minutes), with the real values, under placeholder names.
describe("T4's and T5's metrics from every save in the latest capture's window (F35)", () => {
    const at = (hhmm: string) => new Date(`2026-11-21T${hhmm}:00Z`);
    const hm = (d: Date) => d.toISOString().slice(11, 16);
    const every = (from: string, minutes: number, values: readonly number[]) => values.map((v, i) => [hm(new Date(at(from).getTime() + i * minutes * 60000)), v] as const);
    const row = (save: Record<string, string>, target: string, resource: string, metric: string) => ([bucket, value]: readonly [string, number]) => ({ Bucket: `2026-11-21T${bucket}:00`, TargetKey: target, ResourceName: resource, Metric: metric, Value: value, ...save });

    const T4_SESSION = { CapturedAt: "2026-11-21T17:09:30.083", WindowStart: "2026-11-21T15:14:00", WindowEnd: "2026-11-21T16:57:00" };
    const T4_DAY = { CapturedAt: "2026-11-21T21:33:42.797", WindowStart: "2026-11-20T21:25:00", WindowEnd: "2026-11-21T21:26:00" };
    const sessionLag = every("15:40", 5, [1, 2, 1, 2, 2, 2, 1, 148, 178, 2, 2, 1, 1, 1, 1, 8]).map(row(T4_SESSION, "T4-replica", "pgreplica01", POSTGRES_METRICS.lag));
    const dayLag = (
        [
            ["15:45", 2],
            ["16:00", 2],
            ["16:15", 178],
            ["16:30", 2],
            ["16:45", 34],
        ] as const
    ).map(row(T4_DAY, "T4-replica", "pgreplica01", POSTGRES_METRICS.lag));

    it("keeps the session's own 5-minute lag beside a later day-long save, and the day's 34 s for 16:57 to 17:00 only", () => {
        const capture = latestPostgresCapture([...dayLag, ...sessionLag]);
        expect(capture).toMatchObject({ saves: 2, intervalMinutes: 15, servers: { "T4-replica": "pgreplica01" } });
        expect(capture?.capturedAt?.toISOString()).toBe("2026-11-21T21:33:42.797Z");
        expect(capture?.windowStart?.toISOString()).toBe("2026-11-20T21:25:00.000Z");
        const lag = postgresSeries(capture, "T4-replica", POSTGRES_METRICS.lag);
        expect(lag.map((p) => [hm(p.at), p.value, p.minutes])).toEqual([...sessionLag.map((r) => [r.Bucket.slice(11, 16), r.Value, r.Bucket.endsWith("16:55:00") ? 2 : 5]), ["16:57", 34, 3]]);
        // Each point's span above, and its save's own interval here: the remainder is 3 minutes of a 15-minute interval.
        expect(lag.map((p) => p.grain)).toEqual([...sessionLag.map(() => 5), 15]);
        expect(postgresPeak(lag)).toEqual({ value: 178, at: at("16:20") });
        // Its lag episode by its own 5-minute points: from 16:15, back under 60 s at 16:25 (the day's 15 minutes: 16:30).
        const episodes = postgresEpisodes(capture).filter((e) => e.family === "replica_lag");
        expect(episodes.map((e) => [hm(e.visibleAt), e.recoveredAt && hm(e.recoveredAt), e.peak])).toEqual([["16:15", "16:25", 178]]);
    });

    it("leaves out another server's points, and an older save's outside the latest capture's window", () => {
        const older = { CapturedAt: "2026-11-21T15:05:00", WindowStart: "2026-11-20T15:00:00", WindowEnd: "2026-11-21T15:00:00" };
        const elsewhere = { ...T4_DAY, CapturedAt: "2026-11-21T12:00:00", WindowStart: "2026-11-21T15:00:00", WindowEnd: "2026-11-21T17:00:00" };
        const capture = latestPostgresCapture([
            ...sessionLag,
            ...every("14:30", 15, [300, 300]).map(row(older, "T4-replica", "pgreplica01", POSTGRES_METRICS.lag)),
            ...every("16:00", 5, [999, 999]).map(row(elsewhere, "T4-replica", "pgreplica01-old", POSTGRES_METRICS.lag)),
        ]);
        expect(capture?.saves).toBe(1);
        expect(postgresSeries(capture, "T4-replica", POSTGRES_METRICS.lag).map((p) => p.value)).toEqual(sessionLag.map((r) => r.Value));
    });

    // The review of 576c356e: a point cut by its window has a shorter span, never a shorter interval.
    it("keeps a save's own 5 minutes as its interval when its window starts inside one", () => {
        const save = { CapturedAt: "2026-11-21T15:41:00", WindowStart: "2026-11-21T15:14:00", WindowEnd: "2026-11-21T15:40:00" };
        const capture = latestPostgresCapture(every("15:10", 5, [10, 20, 30, 40, 50, 60]).map(row(save, "T4", "pgflex01", POSTGRES_METRICS.cpu)));
        expect(capture?.intervalMinutes).toBe(5);
        const cpu = postgresSeries(capture, "T4", POSTGRES_METRICS.cpu);
        expect([hm(cpu[0].at), cpu[0].minutes, cpu[0].grain]).toEqual(["15:14", 1, 5]);
        expect(cpu.slice(1).every((p) => p.minutes === 5 && p.grain === 5)).toBe(true);
    });

    it("keeps one CPU run across the session's cut last point and the day's next interval, by their saves' intervals", () => {
        const session = row(T4_SESSION, "T4", "pgflex01", POSTGRES_METRICS.cpu);
        const day = row(T4_DAY, "T4", "pgflex01", POSTGRES_METRICS.cpu);
        const capture = latestPostgresCapture([...every("16:45", 5, [85, 90, 88]).map(session), ...every("16:45", 15, [80, 92]).map(day)]);
        // The day's 80 % from 16:45 isn't higher than the session's points there, so 16:57 to 17:00 adds nothing; 17:00 is 5 minutes on.
        expect(postgresSeries(capture, "T4", POSTGRES_METRICS.cpu).map((p) => [hm(p.at), p.value])).toEqual([
            ["16:45", 85],
            ["16:50", 90],
            ["16:55", 88],
            ["17:00", 92],
        ]);
        const cpu = postgresEpisodes(capture).filter((e) => e.family === "cpu");
        expect(cpu.map((e) => [hm(e.visibleAt), e.ongoing, e.peak])).toEqual([["16:45", true, 92]]);
    });

    const T5_SESSION = { CapturedAt: "2026-11-21T17:09:30.107", WindowStart: "2026-11-21T15:15:00", WindowEnd: "2026-11-21T15:45:00" };
    const T5_DAY = { CapturedAt: "2026-11-21T21:33:44.05", WindowStart: "2026-11-20T21:26:00", WindowEnd: "2026-11-21T21:26:00" };
    const DAY_BUCKETS = ["11:30", "11:45", "12:00", "12:15", "12:30", "12:45", "13:00", "13:15", "13:30", "15:15", "15:30", "15:45"];
    const day = (metric: string, values: readonly number[]) => values.map((v, i) => [DAY_BUCKETS[i], v] as const).map(row(T5_DAY, "T5", "cosmos01", metric));
    const session = (metric: string, values: readonly number[]) => every("15:15", 1, values).map(row(T5_SESSION, "T5", "cosmos01", metric));
    const T5_ROWS = [
        ...day(COSMOS_METRICS.requests, [306, 1030, 930, 8955, 14118, 261, 0, 5, 965, 103, 27630, 23858]),
        ...day(COSMOS_METRICS.throttled, [0, 0, 0, 3860, 6522, 0, 0, 0, 0, 0, 14593, 13215]),
        ...day(COSMOS_METRICS.normalizedRu, [11, 5, 6, 100, 100, 7, 0, 11, 4, 11, 100, 100]),
        ...session(COSMOS_METRICS.requests, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 36, 67, 66, 1356, 3837, 3905, 996, 957, 3436, 3922, 1481, 1469, 3932, 2006, 159, 66, 42]),
        ...session(COSMOS_METRICS.throttled, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 680, 2065, 2187, 565, 472, 1805, 2176, 789, 729, 2069, 1039, 17, 0, 0]),
        ...session(COSMOS_METRICS.normalizedRu, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11, 0, 0, 7, 4, 4, 100, 100, 100, 3, 100, 100, 100, 5, 100, 100, 100, 4, 4, 4]),
    ];

    it("counts T5's requests once across a day-long save and the session's own minutes, and ends each throttled interval at its own end", () => {
        const capture = latestCosmosCapture(T5_ROWS);
        expect(capture).toMatchObject({ account: "cosmos01", saves: 2, intervalMinutes: 15 });
        const requests = cosmosSeries(capture, COSMOS_METRICS.requests);
        const session = requests.filter((p) => p.at >= at("15:15") && p.at < at("15:45"));
        expect(session.reduce((a, p) => a + p.value, 0)).toBe(103 + 27630);
        expect(session.every((p) => p.minutes === 1)).toBe(true);
        expect(throttledRuns(capture).map((r) => [hm(r.from), hm(r.to)])).toEqual([
            ["12:15", "12:45"],
            ["15:31", "15:43"],
            ["15:45", "16:00"],
        ]);
        // Totals per minute where the saves' intervals differ: the day's 306 requests from 11:30 are 20.4 a minute.
        const rates = perMinute(requests, capture);
        expect(rates.find((p) => hm(p.at) === "11:30")?.value).toBeCloseTo(20.4);
        expect(rates.find((p) => hm(p.at) === "15:32")?.value).toBe(3837);
        expect(perMinute(requests, capture && { ...capture, saves: 1 })).toEqual(requests);
    });

    // The review of b36f6357: a day-long save's RU of 100 from 15:30, beside a session that saved only 15:33 to 15:38.
    it("keeps a peak split over two stretches as one reading: both points marked, one throttled run", () => {
        const short = { ...T5_SESSION, WindowStart: "2026-11-21T15:33:00", WindowEnd: "2026-11-21T15:38:00" };
        const capture = latestCosmosCapture([
            ...(
                [
                    ["15:15", 11],
                    ["15:30", 100],
                    ["15:45", 7],
                ] as const
            ).map(row(T5_DAY, "T5", "cosmos01", COSMOS_METRICS.normalizedRu)),
            ...every("15:33", 1, [3, 5, 4, 4, 4]).map(row(short, "T5", "cosmos01", COSMOS_METRICS.normalizedRu)),
        ]);
        const ru = cosmosSeries(capture, COSMOS_METRICS.normalizedRu);
        const source = `T5|${COSMOS_METRICS.normalizedRu}|${at("15:30").getTime()}`;
        expect(ru.filter((p) => p.upperBound).map((p) => [hm(p.at), p.value, p.source, p.minutes, p.grain])).toEqual([
            ["15:30", 100, source, 3, 15],
            ["15:38", 100, source, 7, 15],
        ]);
        expect(oneReadingEach(ru).filter((p) => p.upperBound).map((p) => hm(p.at))).toEqual(["15:30"]);
        expect(throttledRuns(capture).map((r) => [hm(r.from), hm(r.to)])).toEqual([["15:30", "15:33"]]);
    });
});
