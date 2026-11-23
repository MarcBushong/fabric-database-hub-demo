import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { validateTools } from "../../../../ask-relay/src/protocol";
import { toolSpecs } from "@/copilot/tools";
import { COSMOS_METRICS, type CosmosCapture, type PostgresCapture } from "@/data/model";
import { decodeEvidence } from "./evidence";
import { LAG_METRIC } from "./replica";
import { monitorTelemetry } from "./sources";
import { emptyListNote } from "./view/facts";
import { INVESTIGATION_PLAYBOOK } from "./playbook";
import { fixtureEvidence, namesAScenario } from "./testdata/contract";
import { live, liveSources } from "./testdata/live-rb-2233e0ae";
import { createInvestigationTools, EXPLAINED_FAMILIES, INVESTIGATION_TOOL_NAMES, INVESTIGATION_TOOL_SPECS, type Telemetry } from "./tools";
import { during, emptyEvidence, fromTo, openCountWords, type EventRow, type Evidence, type InvestigationResult, type RcaTarget } from "./types";

const at = (hms: string) => new Date(`2026-11-20T${hms}Z`);
const minute = (from: string, n: number) => new Date(at(from).getTime() + n * 60_000);

/** The owner's measured Azure Monitor metrics of 2026-11-20 (UTC): the replica's lag at 12:12 to 12:15 EST, and T5's RU storm. */
function liveTelemetry(): Telemetry {
    const lag = [0.5, 0.6, 0.5, 0.7, 0.6, 0.5, 0.6, 0.5, 0.6, 0.5, 0.6, 0.7, 45, 106, 166, 1, 0.8, 0.6, 0.5, 0.6];
    const postgres: PostgresCapture = {
        capturedAt: at("17:40:00"),
        windowStart: at("16:50:00"),
        windowEnd: at("17:40:00"),
        intervalMinutes: 1,
        servers: {},
        points: [
            ...lag.map((value, i) => ({ at: minute("17:00:00", i), target: "T4-replica" as const, server: "pgreplica01", metric: LAG_METRIC, value })),
            ...Array.from({ length: 40 }, (_, i) => ({ at: minute("16:50:00", i), target: "T4" as const, server: "pgflex01", metric: "cpu_percent", value: 8 })),
        ],
    };
    // 100 % normalized RU with 1,300 to 2,100 429s a minute, 16:56 to 17:06 UTC and from 17:11.
    const storm = (i: number) => (i >= 6 && i < 16) || i >= 21;
    const cosmos: CosmosCapture = {
        account: "cosmos01",
        capturedAt: at("17:40:00"),
        windowStart: at("16:50:00"),
        windowEnd: at("17:30:00"),
        intervalMinutes: 1,
        points: Array.from({ length: 40 }, (_, i) => [
            { at: minute("16:50:00", i), metric: "ThrottledRequests", value: storm(i) ? 1300 + ((i * 97) % 800) : 0 },
            { at: minute("16:50:00", i), metric: "NormalizedRUConsumption", value: storm(i) ? 100 : 22 },
        ]).flat(),
    };
    return { postgres, cosmos };
}

function window(e: Evidence, from: Date, to: Date, targets: readonly RcaTarget[]): Evidence {
    const t = (x: { target: RcaTarget }) => targets.includes(x.target);
    return {
        ...emptyEvidence(),
        sessions: e.sessions.filter((s) => t(s) && s.capturedAt >= from && s.capturedAt <= to),
        events: e.events.filter((x) => t(x) && x.at >= from && x.at <= to),
        resource: e.resource.filter((x) => t(x) && x.at >= from && x.at <= to),
        replica: e.replica.filter((x) => t(x) && x.at >= from && x.at <= to),
        coverage: e.coverage.filter((c) => t(c) && c.from <= to && c.to >= from),
    };
}

function tools(options: { evidence?: Evidence; telemetry?: Telemetry } = {}) {
    const evidence = options.evidence ?? fixtureEvidence("t1", "t4");
    const telemetry = options.telemetry ?? liveTelemetry();
    return createInvestigationTools({
        load: async (from, to, targets) => window(evidence, from, to, targets),
        telemetry: async () => telemetry,
        timeZone: "America/New_York",
        latestDay: at("00:00:00"),
    });
}

async function ask(name: string, args: Record<string, unknown>, deps = tools()): Promise<InvestigationResult> {
    const r = await deps.investigate(name, args);
    if (typeof r === "string") throw new Error(r);
    return r;
}

describe("the investigation tools in the dock", () => {
    it("are six, and with the dock's own four they fit the relay's limits", () => {
        expect(INVESTIGATION_TOOL_NAMES).toEqual(["find_incidents", "triage_window", "explain_incident", "explain_locking", "explain_errors", "explain_replica_lag"]);
        const all = [...toolSpecs({ estate: true }), ...INVESTIGATION_TOOL_SPECS];
        expect(all).toHaveLength(10);
        expect(validateTools(all)).toHaveLength(10);
        // Blind: no spec mentions what was planned.
        expect(JSON.stringify(INVESTIGATION_TOOL_SPECS)).not.toMatch(/inject|Scenario|scenario/);
    });
});

describe("the owner's four questions, at the live session's times (EST)", () => {
    it("'Why was ContosoCare slow at 11:56?': triage ranks T1's chain, T5's throttling, and T1's lock timeouts", async () => {
        const r = await ask("triage_window", { at: "11:56" });
        expect(r.window).toMatchObject({ fromUtc: "2026-11-20T16:51:00Z", toUtc: "2026-11-20T17:01:00Z", asked: "11:56 EST (16:56 UTC)" });
        const h = r.details!.hypotheses as Array<{ target: string; family: string; nextTool: string }>;
        expect(h.map((x) => `${x.target} ${x.family} ${x.nextTool}`)).toEqual(["T1 blocking explain_locking", "T5 throttling explain_errors", "T1 errors explain_errors"]);
        expect(h[1]).toMatchObject({ summary: expect.stringMatching(/^T5: throttled requests \(429\) above zero from 16:56:00 to 17:06:00 UTC, .* Normalized RU consumption was at 100 % in the same minutes\.$/) });
        expect(r.details!.quiet).toEqual(["T2", "T3", "T4", "T4-replica"]);
        expect(r.details!.nothingAbnormal).toBe(false);
    });

    it("'Who blocked whom at 12:05, and what should we do?': T4's chain, head first, and T1's, which had cleared", async () => {
        const r = await ask("explain_locking", { at: "12:05" });
        expect(r.window.asked).toBe("12:05 EST (17:05 UTC)");
        expect(r.rootCause?.ruleIds).toEqual(["BLK-PG-IDLE-IN-TRANSACTION"]);
        expect(r.rootCause?.statement).toContain("session 20432");
        expect((r.details!.chain as string[])[0]).toMatch(/^HEAD session 20432/);
        const chains = r.details!.chains as Array<{ target: string; head: number; activeAtAskedTime: boolean }>;
        expect(chains.map((c) => [c.target, c.head, c.activeAtAskedTime])).toEqual(expect.arrayContaining([["T4", 20432, true], ["T1", 63, false]]));
        expect(r.recommendations.map((x) => x.id)).toEqual(expect.arrayContaining(["PG-IDLE-TIMEOUT", "PG-LOCK-TIMEOUT"]));
    });

    it("'Why did the replica's lag spike at 12:14?': replay stood still behind a replica query's lock, not the network or the write volume", async () => {
        const r = await ask("explain_replica_lag", { at: "12:14" });
        expect(r.rootCause).toMatchObject({ confidence: "high", ruleIds: ["REPL-REPLAY-CONFLICT"] });
        // The capture's own samples tell the rise (live, 2026-11-21); Azure Monitor's minute values are cited beside them.
        expect(r.rootCause?.statement).toMatch(/^The replica's time since its last replay rose from 17:11:30 to 175\.4 s at 17:14:10 UTC \(15\.4 s, 100\.4 s, 160\.4 s, 175\.4 s\), counting from its last replay at 17:11:14 UTC, and was back to 0\.9 s at 17:14:15 UTC/);
        for (const fact of ["demo.replica_lag_marks", "AccessExclusiveLock", "AccessShareLock", "session 41872", "WAL about 1020 bytes/s", "nothing was cancelled"]) expect(r.rootCause?.statement).toContain(fact);
        expect(r.rootCause?.evidence.map((x) => x.text)).toEqual(expect.arrayContaining(["Read Replica Lag 166 s"]));
        expect(r.details).toMatchObject({ source: "RCA Replica", peak: { at: "2026-11-20T17:14:10Z", seconds: 175.4 }, lastReplay: "2026-11-20T17:11:14Z" });
        expect(r.episodes.map((e) => [e.target, e.family, e.source])).toContainEqual(["T4-replica", "replica_lag", "the RCA capture"]);
    });

    it("'What errors did the app hit during the incident?': T5's 429s from Azure Monitor and T1's lock timeouts, by class", async () => {
        const r = await ask("explain_errors", { from: "12:00", to: "12:10" });
        const classes = r.details!.classes as Array<{ class: string; count: number; targets: string[] }>;
        expect(classes[0]).toMatchObject({ class: "throttled", targets: ["T5"] });
        expect(classes.find((c) => c.class === "lock-timeout")).toMatchObject({ count: 6, targets: ["T1"] });
        expect(r.rootCause?.statement).toMatch(/^Most errors were throttled requests \(429\)/);
        expect(r.findings.find((f) => f.ruleId === "ERR-THROTTLED")?.evidence[0].table).toBe("Telemetry Snapshots");
    });
});

describe("incidents, blind", () => {
    it("lists the window's episodes with their keys, and explains one by its key", async () => {
        const found = await ask("find_incidents", { from: "11:50", to: "12:20" });
        const keys = found.episodes.map((e) => e.key);
        expect(keys).toEqual(expect.arrayContaining(["T1-blocking-20261120T165230Z", "T4-blocking-20261120T170230Z", "T4-replica-replica_lag-20261120T171200Z", "T5-throttling-20261120T165600Z"]));
        const r = await ask("explain_incident", { episodeKey: "T1-blocking-20261120T165230Z" });
        expect(r.rootCause?.ruleIds).toEqual(["BLK-IDLE-HEAD"]);
        expect((r.details!.episodes as Array<{ text: string }>)[0].text).toMatch(/^T1: blocked processes above zero from 16:52:30 to 17:01:40 UTC, peak 7 processes/);
    });

    it("explains a target's minutes from a link that passes only a target and a window", async () => {
        const r = await ask("explain_incident", { target: "T4-replica", from: "12:10", to: "12:16" });
        expect(r.rootCause?.ruleIds).toEqual(["REPL-REPLAY-CONFLICT"]);
        const quiet = await ask("explain_incident", { target: "T2", from: "12:10", to: "12:16" });
        expect(quiet.rootCause).toBeNull();
        expect(quiet.notCaptured.join(" ")).toMatch(/Nothing abnormal on T2/);
    });

    it("says what it doesn't know: an unknown key, and history saved before the capture existed", async () => {
        const deps = tools();
        expect(await deps.investigate("explain_incident", { episodeKey: "T1-blocking-20261120T120000Z" })).toMatch(/^No episode/);
        const old = await ask("triage_window", { at: "11:56" }, tools({ evidence: emptyEvidence() }));
        expect(old.notCaptured).toContain("T1: no RCA capture recorded for 16:51:00-17:01:00 UTC; only the telemetry (Telemetry Snapshots) is known");
        // T5's throttling is still found: its evidence is Azure Monitor's, which the history has either way.
        expect((old.details!.hypotheses as Array<{ target: string }>).some((h) => h.target === "T5")).toBe(true);
    });

    it("names no scenario and nothing planned in any answer, and stays inside its size", async () => {
        const deps = tools();
        const calls: Array<[string, Record<string, unknown>]> = [
            ["triage_window", { at: "11:56" }],
            ["find_incidents", { from: "11:50", to: "12:20" }],
            ["explain_locking", { at: "12:05" }],
            ["explain_errors", { from: "12:00", to: "12:10" }],
            ["explain_replica_lag", { at: "12:14" }],
            ["explain_incident", { episodeKey: "T1-blocking-20261120T165230Z" }],
        ];
        for (const [name, args] of calls) {
            const out = await deps.run(name, args);
            expect(out.ok, name).toBe(true);
            expect(out.text.length).toBeLessThanOrEqual(60_000);
            expect(namesAScenario(out.text), name).toEqual([]);
            expect(out.text, name).not.toMatch(/inject/i);
        }
    });
});

// The live findings' audit (2026-11-21): T4's connection surge was listed as explained, but only its errors were read, so
// its report was blank. Every family EXPLAINED_FAMILIES lists has an explainer now, which gives a cause or says exactly
// what's missing.
describe("every family the RCA explains", () => {
    it("is explained, or says what's missing for its target, for every episode in the fixtures, and each family has one", async () => {
        const pgLocal = decodeEvidence(JSON.parse(readFileSync(resolve(import.meta.dirname, "../preview/data/pg-local.evidence.json"), "utf8"))).evidence;
        // An error burst: 12 lock timeouts on T3 in one minute.
        const burst: Evidence = { ...emptyEvidence(), events: Array.from({ length: 12 }, (_, i) => ({ target: "T3" as const, at: new Date(at("16:10:00").getTime() + i * 4000), kind: "error" as const, code: "1222", count: 1, program: "ContosoCare.Demo", detail: "Lock request time out period exceeded." })) };
        const sets: Array<[string, ReturnType<typeof tools>, Date, Date]> = [
            ["the contract's fixtures", tools(), at("16:30:00"), at("17:40:00")],
            ["the live session", createInvestigationTools({ ...liveSources(), timeZone: "America/New_York", latestDay: live("00:00:00"), latest: live("21:33:15") }), live("15:20:00"), live("16:50:00")],
            ["the local PostgreSQL capture", tools({ evidence: pgLocal, telemetry: {} }), at("22:29:00"), at("22:32:00")],
            ["an error burst", tools({ evidence: burst, telemetry: {} }), at("16:05:00"), at("16:15:00")],
        ];
        const families = new Set<string>();
        for (const [name, deps, from, to] of sets) {
            for (const e of (await deps.episodes(from, to)).filter((x) => EXPLAINED_FAMILIES.includes(x.family))) {
                families.add(e.family);
                const r = await ask("explain_incident", { episodeKey: e.key }, deps);
                expect(r.rootCause !== null || r.notCaptured.some((s) => s.startsWith(`${e.target}: `)), `${name}: ${e.key}`).toBe(true);
            }
        }
        expect([...families].sort()).toEqual([...EXPLAINED_FAMILIES].sort());
    });

    it("says why a blocking episode has no chain, when the sentinel saw blocked processes between the chain's samples", async () => {
        const evidence: Evidence = {
            ...emptyEvidence(),
            events: [
                { target: "T1", at: at("16:00:00"), kind: "capture", name: "escalated", code: "T1-20261120T160000Z", count: 1, detail: "processes_blocked 2 >= 1: blocking detail (RCA-SQL-01) every 10 s." },
                { target: "T1", at: at("16:01:30"), kind: "capture", name: "relaxed", code: "T1-20261120T160000Z", count: 1, detail: "processes_blocked 0 for 60 s: back to the 30-s sentinel." },
            ],
            resource: [{ target: "T1", at: at("16:00:00"), source: "RCA-SQL-09", metric: "processes_blocked", value: 2 }],
            coverage: [{ target: "T1", from: at("15:30:00"), to: at("16:30:00"), captured: true, sources: ["RCA-SQL-01", "RCA-SQL-09"], gaps: [] }],
        };
        const r = await ask("explain_incident", { episodeKey: "T1-blocking-20261120T160000Z" }, tools({ evidence, telemetry: {} }));
        expect(r.rootCause).toBeNull();
        // The sentinel saw it, so it ended before the next chain sample (the review of 4e2c65ed: not "between the sentinel's samples").
        expect(r.notCaptured).toContain(
            "T1: the blocked processes from 16:00:00 to 16:02:30 UTC left no blocking chain in the capture: its 30-s sentinel saw a blocked process, and the capture samples the chain (RCA-SQL-01) every 10 s from then on, so the blocking ended before its next chain sample, and neither the head blocker nor its statement is known.",
        );
        // The review of eb89acbb: no chain is claimed for the minutes after the RCA Sessions read stopped.
        const sessionsTo = (until: string) =>
            createInvestigationTools({ load: async (from, to, targets) => ({ ...window(evidence, from, to, targets), cut: [{ table: "RCA Sessions", until: at(until) }] }), telemetry: async () => ({}), timeZone: "America/New_York", latestDay: at("00:00:00") });
        const minutesAsked = { from: "2026-11-20T16:00:00Z", to: "2026-11-20T16:02:30Z", targets: ["T1"] };
        const partly = await ask("explain_locking", minutesAsked, sessionsTo("16:01:00"));
        expect(partly.notCaptured).toContain(
            "T1: the blocked processes from 16:00:00 to 16:01:00 UTC, where the RCA Sessions read stopped, left no blocking chain in the capture: its 30-s sentinel saw a blocked process, and the capture samples the chain (RCA-SQL-01) every 10 s from then on, so the blocking ended before its next chain sample, and neither the head blocker nor its statement is known.",
        );
        const before = await ask("explain_locking", minutesAsked, sessionsTo("15:59:00"));
        expect(before.notCaptured.join(" ")).not.toMatch(/left no blocking chain/);
    });

    // The review of eb89acbb: a surge whose relaxed event is past where the RCA Events read stopped ends its minutes there,
    // in its episode and in its part alike.
    it("explains a connection surge the RCA Events read stopped in as on where the read stopped", async () => {
        const evidence: Evidence = {
            ...emptyEvidence(),
            events: [{ target: "T4", at: at("15:00:00"), kind: "capture", name: "escalated", code: "T4-20261120T150000Z", count: 1, detail: "client connections 30 >= 80 % of 35 (max_connections 50 minus 15 reserved)." }],
            coverage: [{ target: "T4", from: at("14:30:00"), to: at("15:30:00"), captured: true, sources: ["RCA-PG-10"], gaps: [] }],
        };
        for (let s = 0; s <= 110; s += 10) for (const [metric, value] of [["connections_total", 30], ["max_connections", 50], ["reserved_connections", 15]] as const) evidence.resource.push({ target: "T4", at: new Date(at("15:00:00").getTime() + s * 1000), source: "RCA-PG-10", metric, value });
        const deps = createInvestigationTools({ load: async (from, to, targets) => ({ ...window(evidence, from, to, targets), cut: [{ table: "RCA Events", until: at("15:01:00") }] }), telemetry: async () => ({}), timeZone: "America/New_York", latestDay: at("00:00:00") });
        const r = await ask("explain_incident", { episodeKey: "T4-connections-20261120T150000Z" }, deps);
        expect((r.details?.episodes as Array<{ text: string }>)[0].text).toContain("from 15:00:00 UTC (still on at 15:01:00 UTC, where the read stopped)");
        expect(r.rootCause?.statement).toContain("It was still on at 15:01:00 UTC, where the read stopped.");
    });

    it("explains T5's normalized RU at 100 % that throttled nothing, from the intervals it names, with no change to recommend", async () => {
        const points = Array.from({ length: 10 }, (_, i) => [
            { at: minute("17:00:00", i), metric: COSMOS_METRICS.normalizedRu, value: i < 3 ? 100 : 40 },
            { at: minute("17:00:00", i), metric: COSMOS_METRICS.requests, value: 1000 },
            { at: minute("17:00:00", i), metric: COSMOS_METRICS.throttled, value: 0 },
        ]).flat();
        const cosmos: CosmosCapture = { account: "cosmos01", capturedAt: at("17:20:00"), windowStart: at("17:00:00"), windowEnd: at("17:10:00"), intervalMinutes: 1, points };
        const r = await ask("explain_incident", { episodeKey: "T5-ru-20261120T170000Z" }, tools({ evidence: emptyEvidence(), telemetry: { cosmos } }));
        expect(r.rootCause).toMatchObject({ ruleIds: ["RU-AT-LIMIT"], confidence: "medium" });
        // 1,000 a minute in 3 intervals (the review of 4e2c65ed: it once counted 5,000, with the minutes past them).
        expect(r.rootCause?.statement).toMatch(/reached 100 % in at least one second of each of the 3 intervals from 17:00 to 17:03 UTC: .* Azure Monitor counted 3000 requests in those intervals, none of them throttled\./);
        expect(r.recommendations).toEqual([]);
    });

    // The review of 803f2b1a: a key with nothing in its own minutes read as the first storm within 15 minutes after it,
    // a different incident, and said so nowhere the view or Copilot looks.
    it("answers No episode for a key whose minutes hold no incident, rather than a later storm's", async () => {
        const points = Array.from({ length: 30 }, (_, i) => [
            { at: minute("15:30:00", i), metric: COSMOS_METRICS.normalizedRu, value: i >= 15 && i < 18 ? 100 : 30 },
            { at: minute("15:30:00", i), metric: COSMOS_METRICS.requests, value: 1000 },
            { at: minute("15:30:00", i), metric: COSMOS_METRICS.throttled, value: i >= 15 && i < 18 ? 200 : 0 },
        ]).flat();
        const cosmos: CosmosCapture = { account: "cosmos01", capturedAt: at("16:05:00"), windowStart: at("15:30:00"), windowEnd: at("16:00:00"), intervalMinutes: 1, points };
        const deps = tools({ evidence: emptyEvidence(), telemetry: { cosmos } });
        expect(await deps.investigate("explain_incident", { episodeKey: "T5-ru-20261120T153500Z" })).toBe('No episode "T5-ru-20261120T153500Z": call find_incidents for the keys.');
        const storm = await ask("explain_incident", { episodeKey: "T5-ru-20261120T154500Z" }, deps);
        expect(storm.rootCause?.ruleIds).toEqual(["RU-THROTTLED"]);
        expect(storm.details?.readAs).toBeUndefined();
    });

    // Final tests' check of ddebd4c3 (F1): read from its own time, a CPU incident on T2 that the day's list gave from 16:19
    // started a sample later, because the episode before it had no baseline of its own any more, so its key had none.
    it("answers a key of Database Hub's telemetry as the list that gave it reads it, and one a sample before an incident as that one", async () => {
        const cpu = (m: number) => (m >= 49 && m <= 63 ? 50 : m === 79 ? 20 : m === 81 || m === 82 ? 35 : m >= 80 && m <= 86 ? 30 : 5);
        const bins = Array.from({ length: 111 }, (_, m) => ({ at: minute("15:00:00", m), target: "T2" as const, cpu: cpu(m), blocked: null, lockWaitS: null, bufferIoS: null, logRateS: null, waitS: null, ioMb: null, batch: null, sessions: null }));
        const deps = createInvestigationTools({
            load: async () => emptyEvidence(),
            // As the telemetry query reads it: only the bins in the minutes asked for.
            telemetry: async (from, to) => ({ bins: bins.filter((b) => b.at >= from && b.at <= to) }),
            timeZone: "America/New_York",
            latestDay: at("00:00:00"),
        });
        const listed = (await deps.episodes(at("15:30:00"), at("17:00:00"), ["T2"])).filter((e) => e.family === "cpu").map((e) => e.key);
        expect(listed).toEqual(["T2-cpu-20261120T154900Z", "T2-cpu-20261120T161900Z"]);
        const r = await ask("explain_incident", { episodeKey: "T2-cpu-20261120T161900Z" }, deps);
        expect(r.details?.episodes).toMatchObject([{ key: "T2-cpu-20261120T161900Z" }]);
        expect(r.details?.readAs).toBeUndefined();
        // A key a sample before an incident's start reads as that incident, and says so; two samples before, it has none.
        const early = await ask("explain_incident", { episodeKey: "T2-cpu-20261120T161800Z" }, deps);
        expect(early.details?.readAs).toEqual({ key: "T2-cpu-20261120T161800Z", as: ["T2-cpu-20261120T161900Z"] });
        expect(early.notCaptured[0]).toBe("T2-cpu-20261120T161800Z: in its own minutes, the history has no incident with this key; it reads as T2-cpu-20261120T161900Z, which starts a sample after its time, so this report is that one's.");
        expect(await deps.investigate("explain_incident", { episodeKey: "T2-cpu-20261120T161700Z" })).toMatch(/^No episode /);
    });

    // Final tests' check of ddebd4c3 (F2): T5's coverage rows are marked not captured ("no RCA evidence for"), and a storm
    // that ended at 15:55 had its part read to 15:56, into the next row, which it said again, after the storm had ended.
    it("says once that an incident's target wasn't captured, also when its part reads into the next coverage row", async () => {
        const points = Array.from({ length: 40 }, (_, i) => [
            { at: minute("15:30:00", i), metric: COSMOS_METRICS.normalizedRu, value: i >= 16 && i <= 24 ? 100 : 30 },
            { at: minute("15:30:00", i), metric: COSMOS_METRICS.requests, value: 1000 },
            { at: minute("15:30:00", i), metric: COSMOS_METRICS.throttled, value: i >= 16 && i <= 24 ? 200 : 0 },
        ]).flat();
        const cosmos: CosmosCapture = { account: "cosmos01", capturedAt: at("16:15:00"), windowStart: at("15:30:00"), windowEnd: at("16:10:00"), intervalMinutes: 1, points };
        const row = (from: string, to: string) => ({ target: "T5" as const, from: at(from), to: at(to), captured: false, sources: [], gaps: [] });
        const evidence: Evidence = { ...emptyEvidence(), coverage: [row("15:27:09", "15:55:03"), row("15:55:03", "16:24:58")] };
        const r = await ask("explain_incident", { episodeKey: "T5-ru-20261120T154600Z" }, tools({ evidence, telemetry: { cosmos } }));
        expect(r.window).toMatchObject({ fromUtc: "2026-11-20T15:46:00Z", toUtc: "2026-11-20T15:55:00Z" });
        expect(r.notCaptured.filter((line) => line.startsWith("T5: no RCA"))).toEqual(["T5: no RCA evidence for 15:27:09-15:55:03 UTC"]);
    });

    // The re-review of bb70161f: an RU episode 30 minutes or more into its hour read the history from 30 minutes before it,
    // so it missed the hour's provisioned throughput, stamped with the hour's start.
    it("reads the hour's provisioned throughput for an RU episode late in the hour", async () => {
        const points = Array.from({ length: 60 }, (_, i) => [
            { at: minute("17:00:00", i), metric: COSMOS_METRICS.normalizedRu, value: i >= 45 && i < 48 ? 100 : 30 },
            { at: minute("17:00:00", i), metric: COSMOS_METRICS.requests, value: 1000 },
            { at: minute("17:00:00", i), metric: COSMOS_METRICS.throttled, value: i >= 45 && i < 48 ? 100 : 0 },
        ]).flat();
        const capture: CosmosCapture = { account: "cosmos01", capturedAt: at("18:05:00"), windowStart: at("17:00:00"), windowEnd: at("18:00:00"), intervalMinutes: 1, points: [...points, { at: at("17:00:00"), metric: COSMOS_METRICS.provisioned, value: 400 }] };
        // As the telemetry query reads it: only the buckets in the window.
        const deps = createInvestigationTools({
            load: async () => emptyEvidence(),
            telemetry: async (from, to) => ({ cosmos: { ...capture, points: capture.points.filter((p) => p.at >= from && p.at <= to) } }),
            timeZone: "America/New_York",
            latestDay: at("00:00:00"),
        });
        const [episode] = (await deps.episodes(at("17:40:00"), at("17:55:00"), ["T5"])).filter((e) => e.family === "ru");
        const r = await ask("explain_incident", { episodeKey: episode.key }, deps);
        expect(r.rootCause?.statement).toContain("At 400 RU/s, under the 10,000 RU/s one physical partition serves, the container needs only one physical partition unless it holds more than 50 GB");
        expect(r.notCaptured.join(" ")).not.toMatch(/Nor is its provisioned throughput/);
    });

    // The re-review of bb70161f: blocking that Database Hub's telemetry saw before the capture ran was said to be the
    // capture's sentinel's.
    it("says the capture wasn't running when the blocking came from Database Hub's telemetry before it", async () => {
        const bins = Array.from({ length: 20 }, (_, i) => ({ at: minute("15:05:00", i), target: "T1" as const, cpu: 20, blocked: i >= 7 && i <= 13 ? 3 : 0, lockWaitS: null, bufferIoS: null, logRateS: null, waitS: null, ioMb: null, batch: null, sessions: null }));
        const evidence: Evidence = { ...emptyEvidence(), coverage: [{ target: "T1", from: at("15:20:00"), to: at("16:00:00"), captured: true, sources: ["RCA-SQL-01", "RCA-SQL-09"], gaps: [] }] };
        const r = await ask("explain_locking", { at: "2026-11-20T15:19:00Z", targets: ["T1"] }, tools({ evidence, telemetry: { bins } }));
        expect(r.notCaptured).toContain("T1: the blocked processes from 15:12:00 to 15:19:00 UTC are in Database Hub's telemetry only: the capture wasn't running then, so it has no blocking chain for them, and neither the head blocker nor its statement is known.");
        expect(r.notCaptured.join(" ")).not.toMatch(/its 30-s sentinel saw/);
    });

    // Final tests' check of ddebd4c3 (F5): ten notes wrote one instant as a range, "from 19:30:00 to 19:30:00 UTC" and "no
    // RCA capture recorded for 19:30:00-19:30:00 UTC". Each says "at 19:30:00 UTC" now, and the incident still says its
    // target's note once, though its parts read wider minutes.
    it("says one instant 'at' it, in the telemetry-only note and the no-capture note, and the incident's note once", async () => {
        // Blocked processes in the telemetry's last bin only: an incident of one instant, with no recovery in the data.
        const bins = Array.from({ length: 11 }, (_, i) => ({ at: minute("15:05:00", i), target: "T1" as const, cpu: 20, blocked: i === 10 ? 3 : 0, lockWaitS: null, bufferIoS: null, logRateS: null, waitS: null, ioMb: null, batch: null, sessions: null }));
        const evidence: Evidence = { ...emptyEvidence(), coverage: [{ target: "T1", from: at("15:20:00"), to: at("16:00:00"), captured: true, sources: ["RCA-SQL-01", "RCA-SQL-09"], gaps: [] }] };
        const deps = tools({ evidence, telemetry: { bins } });
        const locking = await ask("explain_locking", { at: "2026-11-20T15:19:00Z", targets: ["T1"] }, deps);
        expect(locking.notCaptured).toContain("T1: the blocked processes at 15:15:00 UTC are in Database Hub's telemetry only: the capture wasn't running then, so it has no blocking chain for them, and neither the head blocker nor its statement is known.");
        const [episode] = (await deps.episodes(at("15:00:00"), at("15:30:00"), ["T1"])).filter((e) => e.family === "blocking");
        expect([episode.start, episode.last, episode.end]).toEqual([at("15:15:00"), at("15:15:00"), null]);
        const incident = await ask("explain_incident", { episodeKey: episode.key }, deps);
        expect(incident.notCaptured.filter((line) => line.startsWith("T1: no RCA"))).toEqual(["T1: no RCA capture recorded at 15:15:00 UTC; only the telemetry (Telemetry Snapshots) is known"]);
        expect(JSON.stringify([locking, incident])).not.toMatch(/(\d\d:\d\d:\d\d)(-| to )\1 UTC/);
        // A coverage row of one instant, marked not captured, says it so too, and the incident's note of it stands for its
        // target: the part's line for the row after it, which only the part's wider minutes read, goes.
        const rows: Evidence = {
            ...emptyEvidence(),
            coverage: [
                { target: "T1", from: at("15:15:00"), to: at("15:15:00"), captured: false, sources: [], gaps: [] },
                { target: "T1", from: at("15:15:30"), to: at("15:40:00"), captured: false, sources: [], gaps: [] },
            ],
        };
        const marked = await ask("explain_incident", { episodeKey: episode.key }, tools({ evidence: rows, telemetry: { bins } }));
        expect(marked.notCaptured.filter((line) => line.startsWith("T1: no RCA"))).toEqual(["T1: no RCA evidence at 15:15:00 UTC"]);
    });
});

// The review of 921d3097: F5 told one instant by its time of day alone, so a day's minutes read as one instant, "T2: no RCA
// capture recorded at 17:00:00 UTC", in answers the chat is grounded on. One instant is the same second now, and a span
// whose ends fall on two UTC days gives their dates, so it can't read "17:00:00-17:00:00" or run backwards across midnight.
describe("a span across two UTC days", () => {
    const bin = (when: Date, blocked: number) => ({ at: when, target: "T1" as const, cpu: 20, blocked, lockWaitS: null, bufferIoS: null, logRateS: null, waitS: null, ioMb: null, batch: null, sessions: null });
    const day1 = (hms: string) => new Date(`2026-11-19T${hms}Z`);
    const sameTime = /(\d\d:\d\d:\d\d)(-| to | and )\1 UTC/;

    it("says a day's minutes with their dates, never as one instant: the review's find_incidents call, and nothing abnormal in them", async () => {
        const deps = tools({ evidence: emptyEvidence() });
        const day = { from: "2026-11-19T17:00:00Z", to: "2026-11-20T17:00:00Z" };
        const found = await ask("find_incidents", { ...day, targets: ["T2"] }, deps);
        expect(found.notCaptured).toEqual(["T2: no RCA capture recorded from 2026-11-19 17:00:00 to 2026-11-20 17:00:00 UTC; only the telemetry (Telemetry Snapshots) is known"]);
        const nothing = await ask("explain_incident", { ...day, target: "T2" }, deps);
        expect(nothing.notCaptured).toContain("Nothing abnormal on T2 from 2026-11-19 17:00:00 to 2026-11-20 17:00:00 UTC: the detector found no episode there.");
        expect(JSON.stringify([found, nothing])).not.toMatch(sameTime);
        expect(JSON.stringify([found, nothing])).not.toMatch(/at 17:00:00 UTC/);
    });

    it("says a coverage row a day long with its dates", async () => {
        const evidence: Evidence = { ...emptyEvidence(), coverage: [{ target: "T1", from: day1("15:00:00"), to: at("15:00:00"), captured: false, sources: [], gaps: [] }] };
        const r = await ask("explain_errors", { from: "2026-11-19T14:00:00Z", to: "2026-11-20T16:00:00Z", targets: ["T1"] }, tools({ evidence, telemetry: {} }));
        expect(r.notCaptured).toContain("T1: no RCA evidence from 2026-11-19 15:00:00 to 2026-11-20 15:00:00 UTC");
        expect(JSON.stringify(r)).not.toMatch(/at 15:00:00 UTC/);
    });

    it("says blocked processes a day apart, and a day's minutes with no chain, as spans with their dates", async () => {
        // One bin of blocked processes at 15:15 on each day, each the telemetry's last before a break.
        const bins = [...Array.from({ length: 11 }, (_, i) => bin(new Date(day1("15:05:00").getTime() + i * 60_000), i === 10 ? 3 : 0)), ...Array.from({ length: 11 }, (_, i) => bin(minute("15:05:00", i), i === 10 ? 3 : 0))];
        const captured = (from: Date, to: Date): Evidence => ({ ...emptyEvidence(), coverage: [{ target: "T1", from, to, captured: true, sources: ["RCA-SQL-01", "RCA-SQL-09"], gaps: [] }] });
        // The capture started after both: they're the telemetry's only.
        const telemetryOnly = await ask("explain_locking", { from: "2026-11-19T15:00:00Z", to: "2026-11-20T15:30:00Z", targets: ["T1"] }, tools({ evidence: captured(at("15:20:00"), at("16:00:00")), telemetry: { bins } }));
        expect(telemetryOnly.notCaptured).toContain(
            "T1: the blocked processes from 2026-11-19 15:15:00 to 2026-11-20 15:15:00 UTC are in Database Hub's telemetry only: the capture wasn't running then, so it has no blocking chain for them, and neither the head blocker nor its statement is known.",
        );
        // The capture's sentinel saw blocked processes at 16:00, with no chain in its samples: asked about the day up to just
        // after them, the note gives the day's minutes with their dates.
        const sentinel: Evidence = {
            ...emptyEvidence(),
            events: [
                { target: "T1", at: at("16:00:00"), kind: "capture", name: "escalated", code: "T1-20261120T160000Z", count: 1, detail: "processes_blocked 2 >= 1: blocking detail (RCA-SQL-01) every 10 s." },
                { target: "T1", at: at("16:01:30"), kind: "capture", name: "relaxed", code: "T1-20261120T160000Z", count: 1, detail: "processes_blocked 0 for 60 s: back to the 30-s sentinel." },
            ],
            resource: [{ target: "T1", at: at("16:00:00"), source: "RCA-SQL-09", metric: "processes_blocked", value: 2 }],
            coverage: [{ target: "T1", from: at("15:30:00"), to: at("16:30:00"), captured: true, sources: ["RCA-SQL-01", "RCA-SQL-09"], gaps: [] }],
        };
        const noChain = await ask("explain_locking", { from: "2026-11-19T16:01:00Z", to: "2026-11-20T16:01:00Z", targets: ["T1"] }, tools({ evidence: sentinel, telemetry: {} }));
        expect(noChain.notCaptured.find((line) => line.startsWith("T1: the blocked processes"))).toMatch(/^T1: the blocked processes from 2026-11-19 16:01:00 to 2026-11-20 16:01:00 UTC left no blocking chain in the capture: /);
        expect(JSON.stringify([telemetryOnly, noChain])).not.toMatch(sameTime);
        expect(JSON.stringify([telemetryOnly, noChain])).not.toMatch(/at 15:15:00 UTC/);
    });

    it("says errors a day apart with their dates, in explain_errors and in triage, never backwards across the day", async () => {
        const events = [day1("16:00:00"), at("15:00:00")].map((when) => ({ target: "T1" as const, at: when, kind: "error" as const, code: "1222", count: 1, program: "ContosoCare.Demo", detail: "Lock request time out period exceeded." }));
        const deps = tools({ evidence: { ...emptyEvidence(), events }, telemetry: {} });
        const day = { from: "2026-11-19T15:00:00Z", to: "2026-11-20T16:00:00Z", targets: ["T1"] };
        const errors = await ask("explain_errors", day, deps);
        expect(errors.findings[0].detail).toContain("2 lock timeouts on T1 between 2026-11-19 16:00:00 and 2026-11-20 15:00:00 UTC");
        expect(errors.rootCause?.statement).toContain("(2, 2026-11-19 16:00:00 to 2026-11-20 15:00:00 UTC, mostly");
        const triage = await ask("triage_window", day, deps);
        expect(triage.findings.map((f) => f.title)).toContain("T1: 2 errors and cancels from 2026-11-19 16:00:00 to 2026-11-20 15:00:00 UTC.");
        expect(JSON.stringify([errors, triage])).not.toMatch(/16:00:00 (and|to) 15:00:00/);
        // Counts beside an interval whose length isn't known say their span the same way.
        expect(openCountWords({ count: 30, from: at("15:00:00"), intervals: 1 }, { count: 5, first: day1("16:00:00"), last: at("14:00:00") })).toBe(
            "30 in the interval from 15:00:00 UTC, whose length isn't known in these minutes, after the 5 counted from 2026-11-19 16:00:00 to 2026-11-20 14:00:00 UTC",
        );
    });

    it("still says one instant 'at' it, and a span within one UTC day by its times", async () => {
        expect([fromTo(at("15:15:00"), at("15:15:00")), during(at("15:15:00"), new Date(at("15:15:00").getTime() + 400))]).toEqual(["at 15:15:00", "at 15:15:00"]);
        expect([fromTo(at("15:15:00"), at("15:20:00")), during(at("15:15:00"), at("15:20:00"))]).toEqual(["from 15:15:00 to 15:20:00", "between 15:15:00 and 15:20:00"]);
        // Across midnight, its dates, though it lasts minutes.
        expect(fromTo(day1("23:55:00"), at("00:05:00"))).toBe("from 2026-11-19 23:55:00 to 2026-11-20 00:05:00");
    });

    it("says an incident's no-capture note across midnight once, though its part reads wider minutes", async () => {
        const bins = Array.from({ length: 21 }, (_, i) => bin(new Date(day1("23:50:00").getTime() + i * 60_000), i >= 5 && i <= 15 ? 3 : 0));
        const deps = tools({ evidence: emptyEvidence(), telemetry: { bins } });
        const [episode] = (await deps.episodes(day1("23:40:00"), at("00:20:00"), ["T1"])).filter((e) => e.family === "blocking");
        const end = episode.end ?? episode.last;
        expect([episode.start.toISOString(), end.toISOString().slice(0, 10)]).toEqual(["2026-11-19T23:55:00.000Z", "2026-11-20"]);
        const incident = await ask("explain_incident", { episodeKey: episode.key }, deps);
        expect(incident.notCaptured.filter((line) => line.startsWith("T1: no RCA"))).toEqual([
            `T1: no RCA capture recorded from 2026-11-19 23:55:00 to ${end.toISOString().slice(0, 19).replace("T", " ")} UTC; only the telemetry (Telemetry Snapshots) is known`,
        ]);
    });
});

// The review of 4e2c65ed: one more read left a stall that hadn't recovered by the end of the minutes read as it stood, so
// the chat and the RCA view explained one stall two ways, and an Azure Monitor interval counted in two adjacent windows.
describe("reading whole what a window cuts", () => {
    /** Read Replica Lag a minute at a time, from Azure Monitor only: replay stood still from 16:01 to 16:31. */
    function stall(): Telemetry {
        const lag = (i: number) => (i >= 12 && i <= 40 ? (i - 11) * 60 : i === 41 ? 0.6 : 0.5);
        const postgres: PostgresCapture = {
            capturedAt: at("16:55:00"),
            windowStart: at("15:50:00"),
            windowEnd: at("16:50:00"),
            intervalMinutes: 1,
            servers: {},
            points: Array.from({ length: 60 }, (_, i) => ({ at: minute("15:50:00", i), target: "T4-replica" as const, server: "pgreplica01", metric: LAG_METRIC, value: lag(i) })),
        };
        return { postgres };
    }

    it("reads a rise that hasn't recovered by the end of the minutes read again, so the chat asked in a 30-minute stall's first minute gives the view's finding", async () => {
        const deps = tools({ evidence: emptyEvidence(), telemetry: stall() });
        const [episode] = (await deps.episodes(at("15:55:00"), at("16:45:00"))).filter((e) => e.family === "replica_lag");
        const view = await ask("explain_incident", { episodeKey: episode.key }, deps);
        const chat = await ask("explain_replica_lag", { at: "2026-11-20T16:03:00Z" }, deps);
        expect(view.rootCause?.statement).toMatch(/^Read Replica Lag rose from 16:02:00 to 1740 s at 16:30:00 UTC \(.*\) and was back to 0\.6 s at 16:31:00 UTC/);
        expect(chat.rootCause).toEqual(view.rootCause);
        expect(chat.findings).toEqual(view.findings);
        // Azure Monitor's intervals bound when replay last advanced only from below: it's never given as the time.
        const details = chat.details as Record<string, unknown>;
        expect(details.lastReplay).toBeUndefined();
        expect(details).toMatchObject({ lastReplayNoEarlierThan: "2026-11-20T16:01:00Z", recovered: true });
    });

    it("counts an Azure Monitor interval in the window it starts in, not also in the one that ends where it starts", async () => {
        const postgres: PostgresCapture = {
            capturedAt: at("16:30:00"),
            windowStart: at("15:45:00"),
            windowEnd: at("16:20:00"),
            intervalMinutes: 5,
            servers: {},
            points: Array.from({ length: 7 }, (_, i) => ({ at: minute("15:45:00", 5 * i), target: "T4" as const, server: "pgflex01", metric: "connections_failed", value: i === 4 ? 7 : 0 })),
        };
        const deps = tools({ evidence: emptyEvidence(), telemetry: { postgres } });
        const before = await ask("explain_errors", { at: "2026-11-20T16:00:00Z", targets: ["T4"] }, deps);
        expect(before.notCaptured).toContain("No errors, cancels, failed connections, or 429s were recorded in the window.");
        const after = await ask("explain_errors", { at: "2026-11-20T16:10:00Z", targets: ["T4"] }, deps);
        expect((after.details!.classes as Array<{ count: number }>).reduce((n, c) => n + c.count, 0)).toBe(7);
        // The review of 858c50c2: triage dated the count by its interval's start, "from 16:05:00 to 16:05:00".
        const triaged = await ask("triage_window", { at: "2026-11-20T16:10:00Z", targets: ["T4"] }, deps);
        expect((triaged.details!.hypotheses as Array<{ family: string; summary: string }>).find((h) => h.family === "errors")?.summary).toBe("T4: 7 errors and cancels from 16:05:00 to 16:10:00 UTC (Azure Monitor counts included).");
        // The view's list has no episode for them, and says what the detector found instead (the review of eb89acbb).
        const listed = await ask("find_incidents", { at: "2026-11-20T16:10:00Z", targets: ["T4"] }, deps);
        expect(listed.episodes).toEqual([]);
        expect(emptyListNote(listed, "America/New_York")).toBe("No episode in these minutes; besides episodes, the detector found: T4: 7 errors and cancels from 16:05:00 to 16:10:00 UTC (Azure Monitor counts included).");
    });
});

describe("a coarser point a finer save holds part of", () => {
    const save = (capturedAt: string, from: string, to: string) => (bucket: string, metric: string, value: number) => ({
        Bucket: `2026-11-20T${bucket}:00`,
        TargetKey: "T5",
        ResourceName: "cosmos01",
        Metric: metric,
        Value: value,
        Unit: "Count",
        CapturedAt: `2026-11-20T${capturedAt}:00`,
        WindowStart: `2026-11-20T${from}:00`,
        WindowEnd: `2026-11-20T${to}:00`,
    });
    type MonitorRow = ReturnType<ReturnType<typeof save>>;
    /** The tools over Azure Monitor's rows through one call of the shared function: the rows of the minutes read, as the app reads them, or all of them in every read, as the review's probe did. */
    const reading = (rows: readonly MonitorRow[], all = false) =>
        createInvestigationTools({
            load: async () => emptyEvidence(),
            telemetry: async (from, to) => monitorTelemetry(all ? rows : rows.filter((r) => Date.parse(`${r.Bucket}Z`) >= from.getTime() && Date.parse(`${r.Bucket}Z`) <= to.getTime()), { from, to }),
            timeZone: "UTC",
            latestDay: at("00:00:00"),
            latest: at("18:00:00"),
        });
    const { normalizedRu: RU, requests: REQUESTS, throttled: THROTTLED } = COSMOS_METRICS;
    const texts = (r: InvestigationResult) => JSON.stringify(r);
    /** The throughput investigation's statement among an incident's findings. */
    const throughput = (r: InvestigationResult) => r.findings.find((f) => f.ruleId === "RU-THROTTLED" || f.ruleId === "RU-AT-LIMIT")?.detail;

    // The review of c4c63abe: a day save's 15:30 point (100 % RU, 9,000 requests, 800 429s) with a session's save from
    // 15:33 to 15:38 inside it. The shared function keeps what the session doesn't hold as two pieces, 15:30 to 15:33 and
    // 15:38 to 15:45, a total split by their length: its 800 429s read as two incidents, peaks 240 and 560, and its shares
    // as Azure Monitor's counts, "2550 requests in that interval, 240 of them throttled (9.4 %)". Each part reads only its
    // episode's own minutes, so, as in the review's probe, every read here holds all the rows: the session's too.
    it("is one reading: one candidate, said as Azure Monitor counted it over its whole interval, with what the finer save holds", async () => {
        const day = save("21:33", "00:00", "21:30");
        const session = save("17:09", "15:33", "15:38");
        const tools = reading([
            ...["15:00", "15:15", "15:30", "15:45", "16:00"].flatMap((b) => [day(b, RU, b === "15:30" ? 100 : 11), day(b, REQUESTS, b === "15:30" ? 9000 : 3000), day(b, THROTTLED, b === "15:30" ? 800 : 0)]),
            ...[3, 4, 5, 6, 7].flatMap((m) => [session(`15:3${m}`, RU, 40), session(`15:3${m}`, REQUESTS, 100), session(`15:3${m}`, THROTTLED, 0)]),
        ], true);
        const listed = await ask("find_incidents", { from: "2026-11-20T15:00:00Z", to: "2026-11-20T16:00:00Z", targets: ["T5"] }, tools);
        const throttling = (listed.episodes ?? []).filter((e) => e.family === "throttling");
        expect(throttling.map((e) => [e.key, e.peak])).toEqual([["T5-throttling-20261120T153000Z", "800 requests"]]);
        const ru = await ask("explain_incident", { episodeKey: "T5-ru-20261120T153000Z" }, tools);
        expect(ru.rootCause?.statement).toContain("Azure Monitor keeps the highest in each 15-minute interval) reached 100 % in at least one second of the interval from 15:30 to 15:45 UTC");
        expect(ru.rootCause?.statement).toContain("Azure Monitor counted 9000 requests in that interval, 800 of them throttled (429, 8.9 %)");
        expect(ru.rootCause?.statement).toContain("A finer save holds 15:33 to 15:38 UTC of that interval: 500 requests, none of them throttled.");
        expect(ru.rootCause?.statement).toBe(throughput(ru));
        const incident = await ask("explain_incident", { episodeKey: "T5-throttling-20261120T153000Z" }, tools);
        expect(incident.rootCause?.statement).toMatch(/^Most errors were throttled requests \(429\) \(800, 15:30:00 to 15:45:00 UTC, mostly the container's clients\)/);
        expect(incident.findings[0].evidence.map((e) => e.text)).toEqual(["429: 800 throttled requests (429) in the 15 minutes from 15:30 UTC (Azure Monitor; a finer save holds none of them, in 15:33 to 15:38)"]);
        const errors = await ask("explain_errors", { from: "2026-11-20T15:00:00Z", to: "2026-11-20T16:00:00Z", targets: ["T5"] }, tools);
        expect(errors.rootCause?.statement).toMatch(/^Most errors were throttled requests \(429\) \(800, 15:30:00 to 15:45:00 UTC, mostly the container's clients\)/);
        expect(errors.findings[0].evidence.map((e) => e.text)).toEqual(["429: 800 throttled requests (429) in the 15 minutes from 15:30 UTC (Azure Monitor; a finer save holds none of them, in 15:33 to 15:38)"]);
        // Never a share by length as Azure Monitor's count, or as its own interval.
        for (const r of [listed, incident, ru, errors]) expect(texts(r)).not.toMatch(/\b(2550|5950|240|560)\b/);
        // Minutes inside the finer save read that save, never the coarser reading around them.
        const inside = await ask("explain_errors", { from: "2026-11-20T15:34:00Z", to: "2026-11-20T15:37:00Z", targets: ["T5"] }, tools);
        expect(inside.notCaptured).toContain("No errors, cancels, failed connections, or 429s were recorded in the window.");
    });

    // The review of c4c63abe: minutes holding only one of a 60-minute save's points can't tell its step, and the fallback
    // read it as an instant or a minute: "each 1-minute interval ... from 15:00 to 15:00 UTC ... counted 60000 requests in
    // that interval, 3000 of them throttled".
    it("says an interval the minutes read can't tell the length of as unknown, never an instant or a minute", async () => {
        const hourly = save("18:05", "14:00", "18:00");
        const tools = reading(["14:00", "15:00", "16:00", "17:00"].flatMap((b) => [hourly(b, RU, b === "15:00" ? 100 : 20), hourly(b, REQUESTS, b === "15:00" ? 60000 : 10000), hourly(b, THROTTLED, b === "15:00" ? 3000 : 0)]));
        const incident = await ask("explain_incident", { target: "T5", from: "2026-11-20T15:00:00Z", to: "2026-11-20T15:20:00Z" }, tools);
        expect(throughput(incident)).toContain("Azure Monitor keeps the highest in each interval of its save, whose length isn't known in these minutes) reached 100 % in at least one second of the interval from 15:00 UTC:");
        expect(throughput(incident)).toContain("Azure Monitor counted 60000 requests in that interval, 3000 of them throttled (429, 5 %)");
        const errors = await ask("explain_errors", { from: "2026-11-20T15:00:00Z", to: "2026-11-20T15:20:00Z", targets: ["T5"] }, tools);
        // The review of 4667459c: never an hour's count at one second, "(3000, at 15:00:00 UTC ...)".
        expect(errors.rootCause?.statement).toMatch(/^Most errors were throttled requests \(429\) \(3000 in the interval from 15:00:00 UTC, whose length isn't known in these minutes, mostly the container's clients\)/);
        expect(errors.findings[0].detail).toMatch(/^3000 throttled requests \(429\) on T5 in the interval from 15:00:00 UTC, whose length isn't known in these minutes, mostly /);
        expect(errors.findings[0].evidence.map((e) => e.text)).toEqual(["429: 3000 throttled requests (429) in the interval from 15:00 UTC, whose length isn't known in these minutes (Azure Monitor)"]);
        for (const r of [incident, errors]) expect(texts(r)).not.toMatch(/1-minute|15:00(:00)? to 15:00/);
        // It stands for minutes from its start, so it isn't in the minutes that end there.
        const before = await ask("explain_errors", { from: "2026-11-20T14:40:00Z", to: "2026-11-20T15:00:00Z", targets: ["T5"] }, tools);
        expect(before.notCaptured).toContain("No errors, cancels, failed connections, or 429s were recorded in the window.");
        // Triage's count of errors that no episode holds reads the same (the review of 4667459c).
        const failed = reading(["14:00", "15:00", "16:00", "17:00"].map((b) => ({ ...hourly(b, "connections_failed", b === "15:00" ? 7 : 0), TargetKey: "T4", ResourceName: "pgflex01" })));
        const triaged = await ask("triage_window", { from: "2026-11-20T15:00:00Z", to: "2026-11-20T15:20:00Z", targets: ["T4"] }, failed);
        expect((triaged.details!.hypotheses as Array<{ family: string; summary: string }>).find((h) => h.family === "errors")?.summary).toBe("T4: 7 errors and cancels in the interval from 15:00:00 UTC, whose length isn't known in these minutes (Azure Monitor counts included).");
    });

    // The review of 11b7c4b9: a 60-minute save's 3,000 429s at 15:00, beside 100 a minute from 15:14 that a finer save holds,
    // read "4600 ... in the interval from 15:00:00 UTC, whose length isn't known": the hour's count may hold the others.
    it("never adds a count of unknown interval to the known counts it may hold", async () => {
        const hourly = save("18:05", "14:00", "18:00");
        const minutes = save("16:00", "15:14", "15:30");
        const counts = (metric: string, target: string, hour: number, each: number) => [
            ...["14:00", "15:00", "16:00", "17:00"].map((b) => ({ ...hourly(b, metric, b === "15:00" ? hour : 0), TargetKey: target })),
            ...Array.from({ length: 16 }, (_, i) => ({ ...minutes(`15:${String(14 + i).padStart(2, "0")}`, metric, each), TargetKey: target })),
        ];
        const errors = await ask("explain_errors", { from: "2026-11-20T15:00:00Z", to: "2026-11-20T15:30:00Z", targets: ["T5"] }, reading(counts(THROTTLED, "T5", 3000, 100)));
        expect(errors.rootCause?.statement).toMatch(/^Most errors were throttled requests \(429\) \(3000 in the interval from 15:00:00 UTC, whose length isn't known in these minutes, which may hold the 1600 counted from 15:14:00 to 15:30:00 UTC, mostly the container's clients\)/);
        expect(errors.findings[0].title).toBe("Throttled requests (429): 3000 in an interval of unknown length, 1600 counted");
        expect(errors.findings[0].detail).toMatch(/^3000 throttled requests \(429\) on T5 in the interval from 15:00:00 UTC, whose length isn't known in these minutes, which may hold the 1600 counted from 15:14:00 to 15:30:00 UTC, mostly /);
        expect(texts(errors)).not.toMatch(/\b4600\b/);
        // Triage's count of errors that no episode holds: T4's failed connections the same way.
        const triaged = await ask("triage_window", { from: "2026-11-20T15:00:00Z", to: "2026-11-20T15:30:00Z", targets: ["T4"] }, reading(counts("connections_failed", "T4", 7, 1).map((r) => ({ ...r, ResourceName: "pgflex01" }))));
        expect((triaged.details!.hypotheses as Array<{ family: string; summary: string }>).find((h) => h.family === "errors")?.summary).toBe("T4: 7 errors and cancels in the interval from 15:00:00 UTC, whose length isn't known in these minutes, which may hold the 16 counted from 15:14:00 to 15:30:00 UTC (Azure Monitor counts included).");
    });

    // The re-review of 087e096a: known counts that end before an interval of unknown length begins can't be in it, but the
    // class counted only the larger, so 100 429s from 14:40 and 3,000 from 15:00 ranked as 3,000, under 3,050 failed
    // connections. They're added for its count, rank, and severity, and for triage's, while its words still say them apart.
    it("adds known counts that end before an interval of unknown length begins, for a class's rank and severity, and for triage", async () => {
        const clock = (start: string, i: number) => new Date(Date.parse(`2026-11-20T${start}:00Z`) + i * 60_000).toISOString().slice(11, 16);
        const hourly = save("18:05", "14:00", "18:00");
        const hour = (metric: string, value: number) => ["14:00", "15:00", "16:00", "17:00"].map((b) => hourly(b, metric, b === "15:00" ? value : 0));
        const minutes = (from: string, to: string, n: number, metric: string, each: (i: number) => number) => Array.from({ length: n }, (_, i) => save("15:15", from, to)(clock(from, i), metric, each(i)));
        const onT4 = <T extends object>(r: T) => ({ ...r, TargetKey: "T4", ResourceName: "pgflex01" });
        const asked = { from: "2026-11-20T14:40:00Z", to: "2026-11-20T15:10:00Z" };
        const ranked = await ask("explain_errors", { ...asked, targets: ["T4", "T5"] }, reading([...hour(THROTTLED, 3000), ...minutes("14:40", "15:00", 20, THROTTLED, () => 5), ...minutes("14:40", "15:10", 30, "connections_failed", (i) => (i === 5 ? 3050 : 0)).map(onT4)]));
        expect((ranked.details!.classes as Array<{ class: string; count: number }>).map((c) => [c.class, c.count])).toEqual([["throttled", 3100], ["connection-refused", 3050]]);
        expect(ranked.rootCause?.statement).toMatch(/^Most errors were throttled requests \(429\) \(3000 in the interval from 15:00:00 UTC, whose length isn't known in these minutes, after the 100 counted from 14:40:00 to 15:00:00 UTC, mostly /);
        const severe = await ask("explain_errors", { ...asked, targets: ["T5"] }, reading([...hour(THROTTLED, 60), ...minutes("14:50", "15:00", 10, THROTTLED, () => 5)]));
        expect((severe.details!.classes as Array<{ count: number }>)[0].count).toBe(110);
        expect(severe.findings[0].severity).toBe("critical");
        const triaged = await ask("triage_window", { ...asked, targets: ["T4"] }, reading([...hour("connections_failed", 7), ...minutes("14:40", "15:00", 20, "connections_failed", () => 1)].map(onT4)));
        const errors = (triaged.details!.hypotheses as Array<{ family: string; summary: string; score: number }>).find((h) => h.family === "errors");
        expect(errors?.summary).toBe("T4: 7 errors and cancels in the interval from 15:00:00 UTC, whose length isn't known in these minutes, after the 20 counted from 14:40:00 to 15:00:00 UTC (Azure Monitor counts included).");
        expect(errors?.score).toBe(5.4);
    });

    // The re-review of 8b43102e: triage pooled every kind of error under one interval of unknown length, so an hour's 30 failed
    // connections from 15:00 "may hold the 7 counted", 5 statement-timeout cancels among them, which a failed-connections
    // count can't hold: it counted 30 where explain_errors counts 35. And one instant read "from 15:20:00 to 15:20:00".
    const refusals = (times: readonly string[]) => {
        const hourly = save("18:05", "14:00", "18:00");
        const failed = ["14:00", "15:00", "16:00", "17:00"].map((b) => ({ ...hourly(b, "connections_failed", b === "15:00" ? 30 : 0), TargetKey: "T4", ResourceName: "pgflex01" }));
        const event = (time: string, code: string, detail: string): EventRow => ({ target: "T4", at: at(time), kind: "error", code, count: 1, detail });
        const events = [...Array.from({ length: 5 }, () => event("15:20:00", "57014", "canceling statement due to statement timeout")), ...times.map((t) => event(t, "53300", "sorry, too many clients already"))];
        return createInvestigationTools({
            load: async () => ({ ...emptyEvidence(), events }),
            telemetry: async (from, to) => monitorTelemetry(failed.filter((r) => Date.parse(`${r.Bucket}Z`) >= from.getTime() && Date.parse(`${r.Bucket}Z`) <= to.getTime()), { from, to }),
            timeZone: "UTC",
            latestDay: at("00:00:00"),
            latest: at("18:00:00"),
        });
    };
    const refusalWindow = { from: "2026-11-20T15:00:00Z", to: "2026-11-20T15:30:00Z", targets: ["T4"] };

    it("counts triage's errors by class, as explain_errors does", async () => {
        const tools = refusals(["15:20:00", "15:25:00"]);
        const errors = await ask("explain_errors", refusalWindow, tools);
        expect((errors.details!.classes as Array<{ class: string; count: number }>).map((c) => [c.class, c.count])).toEqual([["connection-refused", 30], ["timeout-or-cancel", 5]]);
        const triaged = await ask("triage_window", refusalWindow, tools);
        const hypothesis = (triaged.details!.hypotheses as Array<{ family: string; summary: string; score: number }>).find((h) => h.family === "errors");
        expect(hypothesis?.summary).toBe("T4: 35 errors and cancels: 30 refused connections and failed logins in the interval from 15:00:00 UTC, whose length isn't known in these minutes, which may hold the 2 counted from 15:20:00 to 15:25:00 UTC; 5 timeouts and cancels (attentions) at 15:20:00 UTC (Azure Monitor counts included).");
        expect(hypothesis?.score).toBe(5.6);
    });

    it("says one instant of known counts beside an interval of unknown length as one", async () => {
        const tools = refusals(["15:20:00", "15:20:00"]);
        const errors = await ask("explain_errors", refusalWindow, tools);
        expect(errors.rootCause?.statement).toMatch(/^Most errors were refused connections and failed logins \(30 in the interval from 15:00:00 UTC, whose length isn't known in these minutes, which may hold the 2 counted at 15:20:00 UTC, mostly /);
        const triaged = await ask("triage_window", refusalWindow, tools);
        for (const r of [errors, triaged]) expect(texts(r)).not.toMatch(/15:20:00 to 15:20:00/);
    });

    // A peak kept around a finer save is only an upper bound of each stretch it's kept for: the replica's rise is said as
    // Azure Monitor's highest over the whole interval, never as the highest in either stretch.
    it("says the replica's lag kept around a finer save as Azure Monitor's highest over its whole interval", async () => {
        const replica = (capturedAt: string, from: string, to: string) => (bucket: string, value: number) => ({ ...save(capturedAt, from, to)(bucket, LAG_METRIC, value), TargetKey: "T4-replica", ResourceName: "pgreplica01", Unit: "Seconds" });
        const day = replica("21:33", "00:00", "21:30");
        const session = replica("17:09", "15:33", "15:38");
        const tools = reading([...["15:00", "15:15", "15:30", "15:45", "16:00"].map((b) => day(b, b === "15:30" ? 120 : 0.5)), ...[3, 4, 5, 6, 7].map((m) => session(`15:3${m}`, 2))], true);
        const lag = await ask("explain_replica_lag", { at: "2026-11-20T15:31:00Z" }, tools);
        expect(lag.rootCause?.statement).toMatch(/^Read Replica Lag \(its highest value in each 15-minute interval\) reached 120 s in the 15 minutes from 15:30:00 UTC /);
        expect(texts(lag)).not.toMatch(/in the (3|7) minutes from 15:(30|38)/);
    });
});

// The owner, 2026-11-23: the chat read "the CPU's cause (Query Store's plans, waits per query) isn't captured yet" as "T1
// doesn't have Query Store". A cause the capture doesn't explain yet says what this history lacks, per target, and never
// what the target lacks, with where the target's own Query Store has it as its next step.
describe("Query Store, in the words of a cause the capture doesn't explain yet", () => {
    /** A claim that a target has no Query Store, or that it's off. */
    const LACKS = /(?:has no|hasn't got|doesn't have|does not have|lacks|without)(?: a| any| its)? Query Store|Query Store (?:is|was) (?:off|disabled|not (?:on|enabled|turned on))|Query Store (?:isn't|wasn't) (?:on|enabled|turned on)|no Query Store/i;
    const busy = (m: number) => (m >= 40 && m < 50 ? 95 : 10);
    const bin = (target: "T1" | "T2" | "T3", m: number, waits?: Record<string, number>) => ({ at: minute("15:00:00", m), target, cpu: waits ? 10 : busy(m), blocked: 0, lockWaitS: null, bufferIoS: null, logRateS: null, waitS: null, ioMb: null, batch: null, sessions: null, ...(waits ? { waits } : {}) });
    const bins = [
        ...Array.from({ length: 60 }, (_, m) => bin("T1", m)),
        ...Array.from({ length: 60 }, (_, m) => bin("T3", m)),
        // T2's buffer latch waits, a wait class, beside a quiet CPU.
        ...Array.from({ length: 60 }, (_, m) => bin("T2", m, { "Buffer Latch": m >= 40 && m < 50 ? 30 : 0 })),
    ];
    const postgres: PostgresCapture = {
        capturedAt: at("16:05:00"),
        windowStart: at("15:00:00"),
        windowEnd: at("16:00:00"),
        intervalMinutes: 1,
        servers: {},
        points: (["T4", "T4-replica"] as const).flatMap((target) => Array.from({ length: 60 }, (_, m) => ({ at: minute("15:00:00", m), target, server: target === "T4" ? "pgflex01" : "pgreplica01", metric: "cpu_percent", value: busy(m) }))),
    };
    const deps = createInvestigationTools({
        load: async () => emptyEvidence(),
        telemetry: async (from, to) => ({ bins: bins.filter((b) => b.at >= from && b.at <= to), postgres }),
        timeZone: "America/New_York",
        latestDay: at("00:00:00"),
    });
    async function incidentOn(target: RcaTarget, family: string): Promise<InvestigationResult> {
        const [episode] = (await deps.episodes(at("15:30:00"), at("16:00:00"), [target])).filter((e) => e.family === family);
        expect(episode, `${target} ${family}`).toBeDefined();
        return ask("explain_incident", { episodeKey: episode.key }, deps);
    }
    const SQL_LEARN = "https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store";
    const PG_LEARN = "https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store";

    it("says on T1 to T3 that this history doesn't hold Query Store's statistics yet, the capture's limit, and where the target's own has them", async () => {
        for (const target of ["T1", "T3"] as const) {
            const r = await incidentOn(target, "cpu");
            expect(r.rootCause?.ruleIds).toEqual(["TELEMETRY-ONLY"]);
            expect(r.rootCause?.statement).toMatch(new RegExp(`UTC\\b.*Which queries drove it isn't in this history: the capture doesn't collect Query Store's per-query statistics yet, a limit of the capture, not of ${target}\\.$`));
            expect(r.notCaptured).toContain(`${target}: which queries drove the CPU isn't in this history, because the capture doesn't collect Query Store's per-query statistics yet. That's the capture's limit, not ${target}'s: Query Store on ${target} keeps those minutes' plans and per-query CPU, duration, and waits, and validate.ps1's ${target}.QUERYSTORE says whether it's on.`);
            expect(r.nextSteps).toContain(`Read Query Store on ${target} for the queries and plans that used the CPU from 15:40:00 to 15:50:00 UTC: its Top Resource Consuming Queries and Regressed Queries reports on ContosoCare in SQL Server Management Studio, or sys.query_store_runtime_stats for the intervals that hold those minutes (${SQL_LEARN}).`);
        }
        const latch = await incidentOn("T2", "latch");
        expect(latch.notCaptured).toContain("T2: which queries drove the buffer latch waits isn't in this history, because the capture doesn't collect Query Store's per-query statistics yet. That's the capture's limit, not T2's: Query Store on T2 keeps those minutes' plans and per-query CPU, duration, and waits, and validate.ps1's T2.QUERYSTORE says whether it's on.");
        expect(latch.nextSteps).toContain(`Read Query Store on T2 for the queries that waited on Buffer Latch from 15:40:00 to 15:50:00 UTC: its Query Wait Statistics report on ContosoCare in SQL Server Management Studio, or sys.query_store_wait_stats and sys.query_store_runtime_stats for the intervals that hold those minutes (${SQL_LEARN}).`);
    });

    it("says the same on T4, in its azure_sys database at every size but Burstable, and that a read replica's queries are in neither", async () => {
        const t4 = await incidentOn("T4", "cpu");
        expect(t4.rootCause?.statement).toMatch(/Which queries drove it isn't in this history: the capture doesn't collect Query Store's per-query statistics yet, a limit of the capture, not of T4\.$/);
        expect(t4.notCaptured).toContain("T4: which queries drove the CPU isn't in this history, because the capture doesn't collect Query Store's per-query statistics yet. That's the capture's limit, not T4's: at every size but Burstable, where Learn advises against it, Query Store on T4 keeps those minutes' per-query statistics and wait samples in its azure_sys database, and validate.ps1's T4.QUERYSTORE says whether it's on.");
        expect(t4.nextSteps).toContain(`Read Query Store on T4 for the queries that took the most time from 15:40:00 to 15:50:00 UTC, at every size but Burstable: query_store.qs_view in its azure_sys database, and query_store.pgms_wait_sampling_view for what they waited on, for the intervals that hold those minutes (${PG_LEARN}).`);
        const replica = await incidentOn("T4-replica", "cpu");
        expect(replica.rootCause?.statement).toMatch(/Which queries drove it is in neither this history nor Query Store, which doesn't record a read replica's queries\.$/);
        expect(replica.notCaptured).toContain(`T4-replica: which queries drove the CPU is in neither this history nor Query Store: Query Store doesn't record the queries a read replica runs (${PG_LEARN}), and the capture samples the replica's sessions only while its replay stands still.`);
        expect(replica.nextSteps.join(" ")).not.toMatch(/Query Store/);
    });

    it("never says that a target has no Query Store, in any tool's result or in the playbook, and drops the old words", async () => {
        const results = [
            ...(await Promise.all([incidentOn("T1", "cpu"), incidentOn("T2", "latch"), incidentOn("T3", "cpu"), incidentOn("T4", "cpu"), incidentOn("T4-replica", "cpu")])),
            await ask("triage_window", { from: "2026-11-20T15:30:00Z", to: "2026-11-20T16:00:00Z" }, deps),
            await ask("find_incidents", { from: "2026-11-20T15:30:00Z", to: "2026-11-20T16:00:00Z" }, deps),
        ];
        const text = JSON.stringify(results);
        expect(text).not.toMatch(LACKS);
        expect(text).not.toMatch(/isn't captured yet|plans and waits per query|plans, waits per query/);
        expect(namesAScenario(text)).toEqual([]);
        // The playbook says it only as what never to say, and for the documented exception: Azure Cosmos DB has none.
        const sentences = INVESTIGATION_PLAYBOOK.split(/(?<=[.:])\s+/).filter((s) => LACKS.test(s));
        expect(sentences.length).toBeGreaterThan(0);
        for (const s of sentences) expect(s, s).toMatch(/^Never say that a target has no Query Store|Azure Cosmos DB \(T5\) has no Query Store/);
        expect(INVESTIGATION_PLAYBOOK).toContain("this history doesn't hold Query Store's per-query statistics yet, which is the capture's limit, not the target's");
        expect(INVESTIGATION_PLAYBOOK).not.toMatch(/comes later/);
    });
});
