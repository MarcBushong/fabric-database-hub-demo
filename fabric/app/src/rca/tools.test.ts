import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { validateTools } from "../../../../ask-relay/src/protocol";
import { toolSpecs } from "@/copilot/tools";
import { COSMOS_METRICS, type CosmosCapture, type PostgresCapture } from "@/data/model";
import { decodeEvidence } from "./evidence";
import { LAG_METRIC } from "./replica";
import { fixtureEvidence, namesAScenario } from "./testdata/contract";
import { live, liveSources } from "./testdata/live-rb-2233e0ae";
import { createInvestigationTools, EXPLAINED_FAMILIES, INVESTIGATION_TOOL_NAMES, INVESTIGATION_TOOL_SPECS, type Telemetry } from "./tools";
import { emptyEvidence, type Evidence, type InvestigationResult, type RcaTarget } from "./types";

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
        expect(r.notCaptured).toContain(
            "T1: the blocked processes from 16:00:00 to 16:02:30 UTC left no blocking chain in the capture: it samples chains (RCA-SQL-01) every 10 s once its 30-s sentinel sees a blocked process, so blocking that began and ended between the sentinel's samples has none, and neither the head blocker nor its statement is known.",
        );
    });

    it("explains T5's normalized RU at 100 % that throttled nothing", async () => {
        const points = Array.from({ length: 10 }, (_, i) => [
            { at: minute("17:00:00", i), metric: COSMOS_METRICS.normalizedRu, value: i < 3 ? 100 : 40 },
            { at: minute("17:00:00", i), metric: COSMOS_METRICS.requests, value: 1000 },
            { at: minute("17:00:00", i), metric: COSMOS_METRICS.throttled, value: 0 },
        ]).flat();
        const cosmos: CosmosCapture = { account: "cosmos01", capturedAt: at("17:20:00"), windowStart: at("17:00:00"), windowEnd: at("17:10:00"), intervalMinutes: 1, points };
        const r = await ask("explain_incident", { episodeKey: "T5-ru-20261120T170000Z" }, tools({ evidence: emptyEvidence(), telemetry: { cosmos } }));
        expect(r.rootCause).toMatchObject({ ruleIds: ["RU-AT-LIMIT"], confidence: "medium" });
        expect(r.rootCause?.statement).toMatch(/reached 100 % in 3 intervals from 17:00 to 17:03 UTC\. Azure Monitor counted 5000 requests in those minutes, none of them throttled/);
    });
});
