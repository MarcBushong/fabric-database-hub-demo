import { describe, expect, it } from "vitest";

import { catalogForCheck, checkIncidentRange, estateQuery, findingsQuery, incidentSeriesQuery, targetNamesQuery } from "./queries";
import { toBins, toChecks, toIncidents, toMeta, toTargetNames, toTargets, toWaitFlows, waitFamily } from "./model";

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
});

describe("query catalog", () => {
    const latest = new Date(Date.UTC(2026, 9, 21));
    const catalog = catalogForCheck(latest);

    it("has 14 bounded, unique, read-only queries", () => {
        expect(catalog).toHaveLength(14);
        expect(new Set(catalog.map((q) => q.id)).size).toBe(14);
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
});
