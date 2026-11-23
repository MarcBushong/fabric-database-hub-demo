import { describe, expect, it } from "vitest";
import type { PostgresCapture } from "@/data/model";
import { analyzeConnections } from "./connections";
import { LOCK_WAIT_TABLES, QUERY_STORE_TABLES } from "./explain-queries";
import { RcaReadError } from "./loader";
import { emptySidecar, type SidecarEvidence } from "./sidecar";
import type { SidecarTableKey } from "./spec";
import { fixtureSidecar, namesAScenario } from "./testdata/contract";
import { createInvestigationTools } from "./tools";
import { emptyEvidence, type Evidence, type InvestigationResult, type RcaTarget, type ResourcePoint, type SessionSample } from "./types";

// Query Store's evidence in the investigations (unit 2's C3): explain_incident's CPU and wait classes, explain_locking's
// lock waits, and explain_queries, from the sidecar fixtures' facts (rca/fixtures/README.md, What a blind RCA finds in the
// sidecars). Blind: each answer comes from the measured rows alone.

const at = (text: string) => new Date(`2026-11-${text}Z`);
const minute = (from: string, n: number) => new Date(at(from).getTime() + n * 60_000);
const NOW = at("21T12:00:00");

// T3's CPU, from Database Hub's bins: 95 % from 17:04 to 17:09 UTC on 2026-11-20, the minutes of T3's sidecar.
const bins = Array.from({ length: 90 }, (_, m) => ({ at: minute("20T16:00:00", m), target: "T3" as const, cpu: m >= 64 && m < 70 ? 95 : 10, blocked: 0, lockWaitS: null, bufferIoS: null, logRateS: null, waitS: null, ioMb: null, batch: null, sessions: null }));
// T4-replica's CPU in the same minutes, from Azure Monitor.
const postgres: PostgresCapture = {
    capturedAt: at("20T17:40:00"),
    windowStart: at("20T16:00:00"),
    windowEnd: at("20T17:30:00"),
    intervalMinutes: 1,
    servers: {},
    points: Array.from({ length: 90 }, (_, m) => ({ at: minute("20T16:00:00", m), target: "T4-replica" as const, server: "pgreplica01", metric: "cpu_percent", value: m >= 64 && m < 70 ? 95 : 10 })),
};

const QS_TABLES = ["RCA Query Coverage", "RCA Query Events", "RCA Query Plans", "RCA Query Stats", "RCA Query Waits"];

/** The investigations over the bins and the given evidence, reading the given sidecar (or failing with it), and what they read of it. */
function toolsWith(sidecar: SidecarEvidence | Error | null, evidence: Evidence = emptyEvidence()) {
    const reads: Array<{ from: string; to: string; targets: readonly RcaTarget[]; tables?: readonly SidecarTableKey[] }> = [];
    const tools = createInvestigationTools({
        load: async () => evidence,
        telemetry: async (from, to) => ({ bins: bins.filter((b) => b.at >= from && b.at <= to), postgres }),
        ...(sidecar
            ? {
                  sidecar: async (from: Date, to: Date, targets: readonly RcaTarget[], tables?: readonly SidecarTableKey[]) => {
                      reads.push({ from: from.toISOString(), to: to.toISOString(), targets, tables });
                      if (sidecar instanceof Error) throw sidecar;
                      return sidecar;
                  },
              }
            : {}),
        timeZone: "UTC",
        latestDay: at("20T00:00:00"),
        now: () => NOW,
    });
    return { tools, reads };
}

async function ask(tools: ReturnType<typeof createInvestigationTools>, name: string, args: Record<string, unknown>): Promise<InvestigationResult> {
    const r = await tools.investigate(name, args);
    if (typeof r === "string") throw new Error(r);
    return r;
}

/** explain_incident for the CPU episode on a target in T3's sidecar minutes. */
async function cpuIncident(tools: ReturnType<typeof createInvestigationTools>, target: RcaTarget = "T3") {
    const [episode] = (await tools.episodes(at("20T16:30:00"), at("20T17:30:00"), [target])).filter((e) => e.family === "cpu");
    expect(episode, `${target} cpu`).toBeDefined();
    expect(episode.start).toEqual(at("20T17:04:00"));
    return ask(tools, "explain_incident", { episodeKey: episode.key });
}

const failure = () => new RcaReadError([{ table: "RCA Query Stats", error: new Error("Service Unavailable") }]);

describe("explain_incident's CPU and wait classes, from Query Store's evidence", () => {
    it("names T3's plan regression as the CPU incident's cause, read from the sample before it, with the response as measured", async () => {
        const { tools, reads } = toolsWith(fixtureSidecar("t3"));
        const r = await cpuIncident(tools);
        // From 17:03, the sample before the incident's first busy minute, with the hour before and an interval after.
        expect(reads).toEqual([{ from: "2026-11-20T15:48:00.000Z", to: "2026-11-20T17:25:00.000Z", targets: ["T3"], tables: QUERY_STORE_TABLES }]);
        expect(r.rootCause).toMatchObject({ ruleIds: ["QS-PLAN-REGRESSION", "QS-PLAN-FORCED"], confidence: "high" });
        const s = r.rootCause!.statement;
        expect(s).toMatch(/^T3: CPU .*UTC.* Query 412 \(\[demo\]\.\[usp_visit_summary_lookup\]\) changed to a new plan: plan 58, compiled at 17:03:11 UTC,/);
        expect(s).toContain("The CPU rose at 17:04:00 UTC, as the new plan first ran, and automatic tuning recommended forcing the earlier plan for the same query.");
        expect(s).toContain("The response, as measured: Plan 31 of query 412 was forced by automatic plan correction between 17:09:00 and 17:10:00 UTC");
        expect(r.rootCause!.evidence.map((e) => e.table)).toEqual(["Telemetry Snapshots", "RCA Query Stats", "RCA Query Stats", "RCA Query Plans"]);
        expect(r.findings.map((f) => f.ruleId)).toEqual(expect.arrayContaining(["QS-PLAN-REGRESSION", "QS-PLAN-FORCED", "QS-TOP-CPU"]));
        expect(r.recommendations.map((x) => x.id)).toEqual(["CPU-FORCE-PLAN", "CPU-MISSING-INDEX"]);
        expect(r.nextSteps).toContain("Compare plan 58 with plan 31 of query 412: explain_queries with queryId 412 gives both plans' shapes and figures.");
        expect(r.nextSteps.join(" ")).toMatch(/^Read the queries and plans in Query Store on T3 for from 17:03:00 to 17:10:00 UTC while it keeps them \(14 days\)/);
        // What this history holds replaces what the capture didn't collect, and the ready-to-run query for minutes without it.
        expect(r.notCaptured.join(" ")).not.toMatch(/doesn't collect|isn't in this history/);
        expect(r.details).not.toHaveProperty("queryStoreQueries");
        const qs = r.details!.queryStore as Array<{ target: string; recorded: string; top: Array<{ queryId: string }> }>;
        expect(qs).toHaveLength(1);
        expect(qs[0]).toMatchObject({ target: "T3", recorded: "yes" });
        expect(qs[0].top[0].queryId).toBe("412");
        expect(namesAScenario(JSON.stringify(r))).toEqual([]);
    });

    it("says why this history names no query, about the history, and keeps the next step and ready-to-run query where it holds none", async () => {
        const older = await cpuIncident(toolsWith({ ...emptySidecar(), missing: QS_TABLES }).tools);
        expect(older.rootCause?.ruleIds).toEqual(["TELEMETRY-ONLY"]);
        expect(older.rootCause?.statement).toMatch(/UTC\b.* Which queries drove it isn't in this history: its model doesn't have Query Store's tables yet\.$/);
        expect(older.notCaptured).toContain(`T3: this history's model doesn't have Query Store's tables yet (${QS_TABLES.join(", ")}), so it holds no per-query statistics; ./scripts/deploy.ps1 updates the model.`);
        expect(older.nextSteps[0]).toMatch(/^Read Query Store on T3 for the queries and plans that used the CPU from 17:04:00 to 17:10:00 UTC: its Top Resource Consuming Queries/);
        expect(older.details!.queryStoreQueries).toEqual([expect.objectContaining({ target: "T3", language: "tsql", database: "ContosoCare", fromUtc: "2026-11-20T17:04:00Z", toUtc: "2026-11-20T17:10:00Z" })]);

        const none = await cpuIncident(toolsWith(emptySidecar()).tools);
        expect(none.rootCause?.statement).toMatch(/Which queries drove it isn't in this history: the capture holds no Query Store statistics for those minutes\.$/);
        expect(none.notCaptured).toContain("T3: the capture holds no Query Store statistics from 17:03:00 to 17:10:00 UTC: it didn't read Query Store then (a history saved before it did, or the capture wasn't running), which says nothing about Query Store on T3.");
        for (const r of [older, none]) expect(r.notCaptured.join(" ")).not.toMatch(/doesn't collect Query Store's per-query statistics yet/);
    });

    it("says a read that failed couldn't be read, never that nothing was recorded, and still answers with the telemetry", async () => {
        const r = await cpuIncident(toolsWith(failure()).tools);
        expect(r.rootCause).toMatchObject({ ruleIds: ["TELEMETRY-ONLY"], statement: expect.stringMatching(/Which queries drove it isn't known: this history's Query Store evidence couldn't be read\.$/) });
        expect(r.notCaptured).toContain(`T3: Query Store's evidence from 17:03:00 to 17:10:00 UTC couldn't be read, so nothing about those minutes' queries is concluded: ${failure().message}`);
        expect(r.notCaptured.join(" ")).not.toMatch(/holds no Query Store statistics/);
    });

    it("reads nothing for a read replica, whose queries Query Store doesn't record", async () => {
        const { tools, reads } = toolsWith(fixtureSidecar("t3"));
        const r = await cpuIncident(tools, "T4-replica");
        expect(reads).toEqual([]);
        expect(r.rootCause?.statement).toMatch(/Which queries drove it is in neither this history nor Query Store, which doesn't record a read replica's queries\.$/);
        expect(r.notCaptured).toContain("T4-replica: Query Store doesn't record a read replica's queries (https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store), so neither this history nor T4-replica has them.");
    });
});

describe("explain_locking's statements, from Query Store's lock waits", () => {
    // T4's chain as the capture samples it every 10 s, 17:02:30 to 17:11:20 UTC: 503 and 504 wait on 502, which is idle in a transaction.
    const chain: SessionSample[] = Array.from({ length: 54 }, (_, i) => new Date(at("20T17:02:30").getTime() + i * 10_000)).flatMap((capturedAt) => [
        { target: "T4", capturedAt, session: 502, blockedBy: [], status: "idle in transaction", openTransactions: 1, isDemo: true },
        { target: "T4", capturedAt, session: 503, blockedBy: [502], status: "active", waitType: "Lock:transactionid", openTransactions: 1, isDemo: true },
        { target: "T4", capturedAt, session: 504, blockedBy: [502], status: "active", waitType: "Lock:transactionid", openTransactions: 1, isDemo: true },
    ]);
    const evidence: Evidence = { ...emptyEvidence(), sessions: chain };
    const window = { from: "2026-11-20T17:00:00Z", to: "2026-11-20T17:15:00Z", targets: ["T4"] };

    it("adds the queries that waited on locks in the chain's intervals, beside the chain", async () => {
        const { tools, reads } = toolsWith(fixtureSidecar("t4"), evidence);
        const r = await ask(tools, "explain_locking", window);
        expect((r.details!.chains as unknown[]).length).toBeGreaterThan(0);
        expect(reads).toEqual([{ from: "2026-11-20T15:47:30.000Z", to: "2026-11-20T17:26:20.000Z", targets: ["T4"], tables: LOCK_WAIT_TABLES }]);
        const waits = r.findings.find((f) => f.ruleId === "QS-LOCK-WAITS");
        expect(waits?.detail).toContain('query -6412873301142229951 ("UPDATE care.work_queues SET status = $1, claimed_at = now() WHERE queue_…"), run by contosocare_runner, 214 executions at 1,174 ms each, the longest 20,050 ms, waits Lock:transactionid 2,480 times (about 248 s from its samples)');
        expect(r.findings[0].ruleId).not.toBe("QS-LOCK-WAITS");
    });

    it("keeps the chain when Query Store's evidence couldn't be read, and says so", async () => {
        const plain = await ask(toolsWith(null, evidence).tools, "explain_locking", window);
        const r = await ask(toolsWith(failure(), evidence).tools, "explain_locking", window);
        expect(r.rootCause).toEqual(plain.rootCause);
        expect(r.findings).toEqual(plain.findings);
        expect(r.notCaptured).toContain(`T4: Query Store's evidence from 17:02:30 to 17:11:20 UTC couldn't be read, so nothing about those minutes' queries is concluded: ${failure().message}`);
    });
});

describe("explain_queries, the chat's tool", () => {
    const minutes = { target: "T3", from: "2026-11-20T17:03:00Z", to: "2026-11-20T17:10:00Z" };

    it("answers from the sidecar with the window's CPU incident, as JSON that parses", async () => {
        const { tools, reads } = toolsWith(fixtureSidecar("t3"));
        const r = await ask(tools, "explain_queries", minutes);
        expect(reads).toEqual([{ from: "2026-11-20T15:48:00.000Z", to: "2026-11-20T17:25:00.000Z", targets: ["T3"], tables: QUERY_STORE_TABLES }]);
        expect(r).toMatchObject({ tool: "explain_queries", targets: ["T3"], rootCause: { ruleIds: ["QS-PLAN-REGRESSION", "QS-PLAN-FORCED"], confidence: "high" } });
        expect(r.rootCause?.statement).toContain("The CPU rose at 17:04:00 UTC, as the new plan first ran");
        const run = await tools.run("explain_queries", minutes);
        expect(run.ok).toBe(true);
        expect(JSON.parse(run.text)).toMatchObject({ tool: "explain_queries", details: { recorded: "yes" } });
    });

    it("refuses what it doesn't take, says when the app doesn't read the sidecar, and fails a read that failed", async () => {
        const { tools } = toolsWith(fixtureSidecar("t3"));
        expect(await tools.investigate("explain_queries", { ...minutes, target: "T9" })).toMatch(/^target takes /);
        expect(await tools.investigate("explain_queries", { ...minutes, queryId: 1.5 })).toMatch(/^queryId takes /);
        expect(await toolsWith(null).tools.investigate("explain_queries", minutes)).toBe("This app doesn't read Query Store's evidence: explain_incident and run_dax on the telemetry are what it has.");
        expect(await toolsWith(failure()).tools.run("explain_queries", minutes)).toEqual({ ok: false, text: failure().message });
    });
});

describe("T4's connections, by who held them (RCA Connections)", () => {
    const surge = fixtureSidecar("surge");
    const times = [...new Set(surge.connections.map((g) => g.capturedAt.getTime()))].sort((a, b) => a - b);
    // RCA-PG-10's counts at the same samples, as it counts them: by state, and a total with the capture's own connection.
    // max_connections 45 less 3 reserved: 42 slots clients can use, and the episode at 80 % of them from the first sample.
    const counts: ResourcePoint[] = times.flatMap((t) => {
        const rows = surge.connections.filter((g) => g.capturedAt.getTime() === t);
        const of = (state: string) => rows.filter((g) => g.state === state).reduce((n, g) => n + g.connections, 0);
        const values = { connections_total: of("active") + of("idle") + 1, connections_active: of("active"), connections_idle: of("idle"), connections_idle_in_transaction: 0, connections_waiting_lock: 0, max_connections: 45, reserved_connections: 3 };
        return Object.entries(values).map(([metric, value]) => ({ target: "T4" as const, at: new Date(t), source: "RCA-PG-10", metric, value }));
    });
    const minutes = { target: "T4" as const, from: at("21T10:06:00"), to: at("21T10:12:00"), resource: counts, sessions: [], metrics: [] };
    const RUN = "the run with token 7c3e91a05bd2 (ContosoCare.Demo, as contosocare_runner)";
    const WHO =
        `Who held them, as the capture counted them by program, login, and state in 37 samples from 10:06:00 to 10:12:00 UTC (RCA Connections): ${RUN} held 28 idle at 10:06:00 UTC and 36 from 10:10:00 to 10:11:50 UTC, the oldest idle for 40 s at its first sample and 6 min 30 s at its last; ` +
        "an application the capture doesn't name held 3 idle, the oldest idle for 23 s at its first sample and 18 s at its last; and the run with token 2fa86c14e9b0 (ContosoCare.Demo, as contosocare_runner) held 2 active. " +
        `Together they held 41 at most, from 10:10:00 to 10:11:50 UTC. At 10:12:00 UTC, the capture counted none of the idle connections of ${RUN}.`;
    const WHO_NOT = /who held (the|them)|list who holds/i;

    it("names who held the slots: each run by its opaque token, what it held and how long its oldest sat idle, and the most together", () => {
        const a = analyzeConnections({ ...minutes, holders: surge.connections });
        expect(a.rootCause?.ruleIds).toEqual(["CONN-IDLE"]);
        expect(a.rootCause?.statement).toContain(` ${WHO}`);
        expect(a.rootCause?.evidence).toContainEqual({
            table: "RCA Connections",
            at: "2026-11-21T10:10:00Z",
            target: "T4",
            text: `41 client connections by program, login, and state: 36 idle of ${RUN}; 2 active of the run with token 2fa86c14e9b0 (ContosoCare.Demo, as contosocare_runner); 3 idle of an application the capture doesn't name`,
        });
        // What the capture counted is no longer "not captured", nor a step to find out while it happens.
        expect(a.notCaptured.join(" ")).not.toMatch(WHO_NOT);
        expect(a.nextSteps.join(" ")).not.toMatch(WHO_NOT);
        expect(a.nextSteps).toContain("Size each application's pool to the queries it runs at once, below the limit, and let it close the connections it doesn't use.");
        expect(a.details.holders).toMatchObject({ samples: 37, from: "2026-11-21T10:06:00Z", to: "2026-11-21T10:12:00Z", peak: { connections: 41, from: "2026-11-21T10:10:00Z", to: "2026-11-21T10:11:50Z" } });
        expect((a.details.holders as { groups: unknown[] }).groups[0]).toEqual({ name: RUN, state: "idle", isWorkload: true, first: { at: "2026-11-21T10:06:00Z", connections: 28 }, most: 36, last: { at: "2026-11-21T10:11:50Z", connections: 36 }, oldestStateS: { first: 40, last: 390 } });
        expect(namesAScenario(JSON.stringify(a))).toEqual([]);
    });

    it("says who held them isn't captured only when nothing counted them, and leaves it to a caller that couldn't read them", () => {
        expect(analyzeConnections({ ...minutes, holders: [] }).notCaptured).toContain(
            "T4: who held the connections (their application, user, and client address) and how long each sat idle aren't captured for these minutes: RCA-PG-10 counts connections by state, and the capture samples sessions (RCA-PG-01) only while a client waits on a lock, which none did here.",
        );
        expect(analyzeConnections({ ...minutes, holdersUnread: true }).notCaptured.join(" ")).not.toMatch(WHO_NOT);
    });

    it("explain_incident reads them for the connections episode, and says when the model lacks them or the read failed", async () => {
        // The capture's connection episode, as it records one: escalated at the first sample at the level, relaxed when they fell.
        const code = "T4-20261121T100600Z";
        const evidence: Evidence = {
            ...emptyEvidence(),
            resource: counts,
            events: [
                { target: "T4", at: at("21T10:06:00"), kind: "capture", name: "escalated", code, count: 1, detail: "client connections 34 >= 80 % of 42 (max_connections 45 minus 3 reserved)." },
                { target: "T4", at: at("21T10:12:00"), kind: "capture", name: "relaxed", code, count: 1, detail: "client connections 6 < 80 % of 42." },
            ],
        };
        const explain = async (sidecar: SidecarEvidence | Error) => {
            const { tools, reads } = toolsWith(sidecar, evidence);
            const [episode] = (await tools.episodes(at("21T10:00:00"), at("21T10:20:00"), ["T4"])).filter((e) => e.family === "connections");
            expect(episode?.start).toEqual(at("21T10:06:00"));
            return { r: await ask(tools, "explain_incident", { episodeKey: episode.key }), reads };
        };
        const { r, reads } = await explain(surge);
        expect(reads).toEqual([{ from: "2026-11-21T10:06:00.000Z", to: "2026-11-21T10:13:00.000Z", targets: ["T4"], tables: ["connections"] }]);
        expect(r.rootCause?.statement).toContain(WHO);
        expect(r.notCaptured.join(" ")).not.toMatch(WHO_NOT);

        const older = (await explain({ ...emptySidecar(), missing: ["RCA Connections"] })).r;
        expect(older.notCaptured).toContain("T4: who held the connections isn't in this history: its model doesn't have RCA Connections yet; ./scripts/deploy.ps1 updates the model.");
        expect(older.notCaptured.join(" ")).not.toMatch(/aren't captured for these minutes/);

        const failed = (await explain(failure())).r;
        expect(failed.notCaptured).toContain(`T4: who held the connections from 10:06:00 to 10:13:00 UTC couldn't be read, so they aren't named: ${failure().message}`);
        expect(failed.rootCause?.statement).not.toContain("Who held them");
    });
});