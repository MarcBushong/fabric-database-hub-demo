import { describe, expect, it, vi } from "vitest";
import { QueryFailure } from "@/data/query-client";
import { loadSidecar, PLAN_LAG_MINUTES, planDax, rcaDax, RcaReadError, sidecarDax, tableDax, type DaxLog } from "./loader";
import { decodeSidecar, emptySidecar, latestReads, parseExact, SidecarFormatError, toId, type QueryStat, type QueryWait, type SidecarEvidence } from "./sidecar";
import { RCA_SPEC, SIDECAR_SPEC, SIDECAR_TABLES, type SidecarTableKey } from "./spec";
import { fixtureSidecar, namesAScenario, readContract, readContractExact, SIDECAR_FIXTURES } from "./testdata/contract";

const at = (text: string) => new Date(`2026-11-${text}Z`);

describe("the sidecar documents (the contract's fixtures)", () => {
    it("reads T3's Query Store: both plans of query 412, their statistics, waits, plans, the forcing, and the coverage", () => {
        const s = fixtureSidecar("t3");
        expect(s.stats).toHaveLength(12);
        const plan58 = s.stats.find((r) => r.queryId === "412" && r.planId === "58")!;
        expect(plan58).toMatchObject({ target: "T3", module: "[demo].[usp_visit_summary_lookup]", executions: 524, cpuMs: 92_224, logicalReads: 2_148_400, maxDop: 4, waitMs: 31_440 });
        expect(plan58.intervalStart).toEqual(at("20T17:00:00"));
        expect(plan58.intervalEnd).toEqual(at("20T17:15:00"));
        expect(plan58.firstExecution).toEqual(at("20T17:03:12.640"));
        expect(plan58.lastExecution).toEqual(at("20T17:09:40.215"));
        expect(s.waits.filter((w) => w.planId === "58").map((w) => [w.category, w.waitMs])).toEqual([
            ["CPU", 18_900],
            ["Parallelism", 11_620],
            ["Buffer IO", 920],
        ]);
        // A plan's row is written when a read first returns it, and again when it changes (rca/fixtures/README.md, Plans): plan
        // 31 at 16:50 and, forced, at 17:17; plans 58 and 40 once each, at 17:17; and the final read writes none.
        const rowsOf = (planId: string) => s.plans.filter((p) => p.planId === planId).map((p) => [p.capturedAt.toISOString().slice(11, 16), p.isForced, p.forcingType]);
        expect(rowsOf("31")).toEqual([
            ["16:50", false, "NONE"],
            ["17:17", true, "AUTO"],
        ]);
        expect([rowsOf("58"), rowsOf("40")]).toEqual([[["17:17", false, "NONE"]], [["17:17", false, "NONE"]]]);
        expect(s.plans.filter((p) => p.capturedAt.getTime() === at("20T17:20:10.050").getTime())).toEqual([]);
        const plan = (planId: string) => s.plans.filter((p) => p.queryId === "412" && p.planId === planId).at(-1)!;
        expect([plan("31").isParallel, plan("31").estimatedCost, plan("31").lastCompiled]).toEqual([false, 0.0331, at("20T17:09:41.120")]);
        expect([plan("58").isParallel, plan("58").estimatedCost, plan("58").compiled]).toEqual([true, 38.6, at("20T17:03:11.870")]);
        expect(plan("31").summary).toContain("[care].[appointments].[ix_appointments_patient]");
        expect(plan("58").summary).toContain("[care].[appointments].[pk_appointments]");
        // Automatic tuning's recommendation from its first appearance, with no state before it.
        expect(s.events.map((e) => [e.kind, e.at.toISOString().slice(11, 19), e.from?.toISOString().slice(11, 19), e.queryId, e.planId, e.forcingType ?? null, e.state, e.previousState ?? null])).toEqual([
            ["tuning", "17:06:00", "17:05:30", "412", "31", null, "Active", null],
            ["tuning", "17:09:30", "17:09:00", "412", "31", null, "Executing", "Active"],
            ["forced", "17:10:00", "17:09:00", "412", "31", "AUTO", "forced", "not forced"],
            ["tuning", "17:10:30", "17:10:00", "412", "31", null, "Verifying", "Executing"],
        ]);
        expect(s.coverage).toEqual([expect.objectContaining({ target: "T3", state: "READ_WRITE", captureMode: "AUTO", intervalMinutes: 15, readFrom: at("20T16:15:00"), readTo: at("20T17:30:00"), backfill: false, gaps: [] })]);
        expect(s.coverage[0].sources).toEqual(["RCA-SQL-10", "RCA-SQL-11", "RCA-SQL-14", "RCA-SQL-15", "RCA-AZ-03", "RCA-AZ-04"]);
        expect(s.missing).toEqual([]);
    });

    it("keeps T4's 64-bit query IDs whole, past what a JavaScript number holds, and its pending publication and replica", () => {
        const s = fixtureSidecar("t4");
        const update = s.stats.filter((r) => r.queryId === "-6412873301142229951");
        expect(update.map((r) => [r.intervalStart.toISOString().slice(11, 16), r.planId, r.login, r.executions, r.durationMs, r.maxDurationMs])).toEqual([
            ["16:45", "0", "contosocare_runner", 220, 61.6, 1.4],
            ["17:00", "0", "contosocare_runner", 214, 251_300, 20_050],
        ]);
        // Rounded to a number, two of these hashes would read as other queries' IDs.
        expect(Number("-6412873301142229951").toString()).not.toBe("-6412873301142229951");
        expect(s.stats.map((r) => r.queryId)).toEqual(expect.arrayContaining(["8164251097732651127", "-1129384756610293847", "2871345566190021453"]));
        expect(s.stats.find((r) => r.queryId === "-1129384756610293847")?.login).toBeUndefined();
        expect(s.waits.filter((w) => w.queryId === "-6412873301142229951").map((w) => [w.category, w.event, w.samples, w.waitMs])).toEqual([
            ["Lock", "transactionid", 2480, 248_000],
            ["LWLock", "LockManager", 6, 600],
        ]);
        const t4 = s.coverage.find((c) => c.target === "T4")!;
        expect(t4).toMatchObject({ state: "all", readFrom: at("20T16:45:00"), readTo: at("20T17:15:00"), pendingFrom: at("20T17:15:00"), pendingTo: at("20T17:20:00"), backfill: false });
        expect(t4.gaps[0]).toMatch(/^Pending publication: /);
        const replica = s.coverage.find((c) => c.target === "T4-replica")!;
        expect(replica.state).toBeUndefined();
        expect(replica.gaps[0]).toMatch(/^T4-replica is a read replica, which records nothing in Query Store/);
    });

    it("reads who held T4's connections in the surge: the samples, the runs by their tokens, and the other application's without names", () => {
        const s = fixtureSidecar("surge");
        const times = [...new Set(s.connections.map((c) => c.capturedAt.getTime()))].sort((a, b) => a - b);
        expect(times).toHaveLength(37);
        expect(new Date(times[0])).toEqual(at("21T10:06:00"));
        expect(new Date(times[35])).toEqual(at("21T10:11:50"));
        expect(new Date(times[36])).toEqual(at("21T10:12:00"));
        const first = s.connections.filter((c) => c.capturedAt.getTime() === times[0]);
        expect(first.map((c) => [c.runToken ?? null, c.program ?? null, c.login ?? null, c.state, c.connections, c.isDemo])).toEqual([
            ["7c3e91a05bd2", "ContosoCare.Demo", "contosocare_runner", "idle", 28, true],
            ["2fa86c14e9b0", "ContosoCare.Demo", "contosocare_runner", "active", 2, true],
            [null, null, null, "idle", 3, false],
        ]);
        const total = (t: number) => s.connections.filter((c) => c.capturedAt.getTime() === t).reduce((n, c) => n + c.connections, 0);
        expect(Math.max(...times.map(total))).toBe(41);
        expect(s.stats.map((r) => [r.queryId, r.executions])).toEqual([
            ["4415920376611208842", 452],
            ["-1129384756610293847", 15],
        ]);
    });

    it("keeps the decoded sidecars blind: no scenario named anywhere in them", () => {
        expect(namesAScenario(JSON.stringify(fixtureSidecar("t3", "t4", "surge")))).toEqual([]);
    });

    it("refuses a document of another kind or version, rather than guess", () => {
        const doc = readContractExact<Record<string, unknown>>(SIDECAR_FIXTURES.t3);
        expect(() => decodeSidecar({ ...doc, version: 2 })).toThrow(SidecarFormatError);
        expect(() => decodeSidecar({ ...doc, kind: "ContosoCare.RcaEvidence" })).toThrow(SidecarFormatError);
        expect(() => decodeSidecar(readContract("fixtures/t1-blocking-chain.evidence.json"))).toThrow(SidecarFormatError);
        expect(() => decodeSidecar({ hello: "world" })).toThrow(SidecarFormatError);
    });

    it("takes an ID only as its exact digits: text, or a number while it's exact", () => {
        expect(parseExact('{"a":[-6412873301142229951,412,1.5]}')).toEqual({ a: ["-6412873301142229951", 412, 1.5] });
        expect(toId("-6412873301142229951")).toBe("-6412873301142229951");
        expect(toId(412)).toBe("412");
        expect(toId(Number("-6412873301142229951"))).toBeUndefined();
        expect(toId("4.12")).toBeUndefined();
    });
});

describe("the latest read of each interval (rca/README.md, Query Store)", () => {
    const stat = (capturedAt: string, executions: number, cpuMs: number): QueryStat => ({
        target: "T3",
        capturedAt: at(`20T${capturedAt}`),
        intervalStart: at("20T17:15:00"),
        intervalEnd: at("20T17:30:00"),
        queryId: "412",
        planId: "31",
        executions,
        cpuMs,
    });
    const wait = (capturedAt: string, category: string, waitMs: number): QueryWait => ({ target: "T3", capturedAt: at(`20T${capturedAt}`), intervalStart: at("20T17:15:00"), intervalEnd: at("20T17:30:00"), queryId: "412", planId: "31", category, waitMs });

    it("counts an interval read open at a capture's end, then whole by the next read, once, with the later read's counts and waits", () => {
        const got = latestReads({
            stats: [stat("17:20:10", 371, 780), stat("17:32:05", 1_190, 2_500), { ...stat("17:32:05", 40, 90), planId: "58" }],
            waits: [wait("17:20:10", "Buffer IO", 44), wait("17:20:10", "Network IO", 3), wait("17:32:05", "Buffer IO", 150), wait("17:32:05", "CPU", 60)],
        });
        expect(got.stats.map((s) => [s.planId, s.executions, s.cpuMs])).toEqual([
            ["31", 1_190, 2_500],
            ["58", 40, 90],
        ]);
        // The earlier read's top three aren't mixed into the later read's: Network IO fell out of them.
        expect(got.waits.map((w) => [w.category, w.waitMs])).toEqual([
            ["Buffer IO", 150],
            ["CPU", 60],
        ]);
    });

    it("keeps PostgreSQL's roles apart: one role's query isn't another's", () => {
        const got = latestReads({ stats: [{ ...stat("17:20:10", 5, 0), login: "contosocare_runner" }, { ...stat("17:20:10", 7, 0) }], waits: [] });
        expect(got.stats.map((s) => s.executions).sort()).toEqual([5, 7]);
    });
});

/** A sidecar's rows as DAX returns them: keyed by the model's columns, times as zoneless text, IDs as text (CONVERT). */
function asModelRows(sidecar: SidecarEvidence, key: SidecarTableKey): Array<Record<string, unknown>> {
    const member = { queryStats: "stats", queryWaits: "waits", queryPlans: "plans", queryEvents: "events", queryCoverage: "coverage", connections: "connections" } as const;
    const fields = SIDECAR_SPEC[key].fields as Record<string, { model: string; kind: string }>;
    return (sidecar[member[key]] as unknown as Array<Record<string, unknown>>).map((row) => {
        const out: Record<string, unknown> = {};
        for (const [name, field] of Object.entries(fields)) {
            let value = row[name];
            if (value instanceof Date) value = value.toISOString().replace("Z", "");
            if (name === "sources") value = (value as string[]).join(",");
            if (name === "gaps") value = (value as string[]).join("\n") || null;
            out[field.model] = value ?? null;
        }
        return out;
    });
}

describe("the sidecar's DAX loader", () => {
    it("leaves Phase 1's queries as they were", () => {
        const from = at("20T16:50:00");
        const to = at("20T17:05:00");
        expect(rcaDax("coverage", from, to, ["T1"])).toBe(
            [
                "EVALUATE",
                "CALCULATETABLE (",
                "    'RCA Coverage',",
                "    'RCA Coverage'[Window End UTC] >= DATE ( 2026, 11, 20 ) + TIME ( 16, 50, 0 ),",
                "    'RCA Coverage'[Window Start UTC] <= DATE ( 2026, 11, 20 ) + TIME ( 17, 5, 0 ),",
                `    TREATAS ( { "T1" }, 'Target'[Target Key] )`,
                ")",
                "ORDER BY 'RCA Coverage'[Window Start UTC]",
            ].join("\n"),
        );
        expect(rcaDax("sessions", from, to, ["T1"])).toBe(tableDax(RCA_SPEC.sessions, from, to, ["T1"]));
        expect(rcaDax("sessions", from, to, ["T1"])).not.toContain("SELECTCOLUMNS");
    });

    it("reads every interval that overlaps the window, with Query Store's IDs as text, oldest first", () => {
        const dax = sidecarDax("queryStats", at("20T16:00:00"), at("20T17:10:00"), ["T3", "T4"]);
        expect(dax).toMatch(/^EVALUATE\nSELECTCOLUMNS \(\n {4}CALCULATETABLE \(\n {8}'RCA Query Stats',\n/);
        expect(dax).toContain("'RCA Query Stats'[Interval End UTC] >= DATE ( 2026, 11, 20 ) + TIME ( 16, 0, 0 ),");
        expect(dax).toContain("'RCA Query Stats'[Interval Start UTC] <= DATE ( 2026, 11, 20 ) + TIME ( 17, 10, 0 ),");
        expect(dax).toContain(`TREATAS ( { "T3", "T4" }, 'Target'[Target Key] )\n    ),`);
        expect(dax).toContain(`"Query ID", CONVERT ( 'RCA Query Stats'[Query ID], STRING ),`);
        expect(dax).toContain(`"Plan ID", CONVERT ( 'RCA Query Stats'[Plan ID], STRING ),`);
        expect(dax).toContain(`"CPU (ms)", 'RCA Query Stats'[CPU (ms)],`);
        expect(dax).toMatch(/"Last Execution UTC", 'RCA Query Stats'\[Last Execution UTC\]\n\)\nORDER BY \[Interval Start UTC\]$/);
    });

    it("keeps a coverage row whose window, intervals read, or pending publication overlap the window", () => {
        const dax = sidecarDax("queryCoverage", at("20T17:15:00"), at("20T17:20:00"), ["T4"]);
        expect(dax).toContain(
            "FILTER ( 'RCA Query Coverage', ( 'RCA Query Coverage'[Window End UTC] >= DATE ( 2026, 11, 20 ) + TIME ( 17, 15, 0 ) && 'RCA Query Coverage'[Window Start UTC] <= DATE ( 2026, 11, 20 ) + TIME ( 17, 20, 0 ) ) || ( 'RCA Query Coverage'[Read To UTC] >= DATE ( 2026, 11, 20 ) + TIME ( 17, 15, 0 ) && 'RCA Query Coverage'[Read From UTC] <= DATE ( 2026, 11, 20 ) + TIME ( 17, 20, 0 ) ) || ( 'RCA Query Coverage'[Pending To UTC] >= DATE ( 2026, 11, 20 ) + TIME ( 17, 15, 0 ) && 'RCA Query Coverage'[Pending From UTC] <= DATE ( 2026, 11, 20 ) + TIME ( 17, 20, 0 ) ) ),",
        );
        // No ID in it: the table itself, as Phase 1's are.
        expect(dax).not.toContain("SELECTCOLUMNS");
    });

    it("reads the same rows through DAX as from the documents, IDs whole", async () => {
        const expected = fixtureSidecar("t3", "t4", "surge");
        const runDax = vi.fn(async (query: string) => {
            const key = SIDECAR_TABLES.find((k) => query.includes(`'${SIDECAR_SPEC[k].model}',`));
            return key ? asModelRows(expected, key) : [];
        });
        const got = await loadSidecar(runDax, at("20T16:00:00"), at("21T11:00:00"), ["T3", "T4", "T4-replica"]);
        expect(runDax).toHaveBeenCalledTimes(SIDECAR_TABLES.length);
        for (const member of ["stats", "waits", "plans", "events", "coverage", "connections"] as const) expect(got[member], member).toEqual(expected[member]);
        expect(got.stats.map((s) => s.queryId)).toContain("-6412873301142229951");
        expect(got.missing).toEqual([]);
        // The plans of the queries the statistics and events name, up to PLAN_LAG_MINUTES past the window, with no lower bound.
        const plans = runDax.mock.calls.map(([q]) => q).find((q) => q.includes("'RCA Query Plans',"))!;
        expect(plans).toContain(`'RCA Query Plans'[Captured At UTC] <= DATE ( 2026, 11, 21 ) + TIME ( 11, ${PLAN_LAG_MINUTES}, 0 ),`);
        expect(runDax.mock.calls.at(-1)![0]).toBe(plans);
    });

    // The review of d441fe13: plans were read from the window's start, so a plan that never changed, whose only row is its
    // first read's, dropped out of later windows.
    it("reads the plans of the window's queries newest first, with no lower bound, so a plan first read long before is there", async () => {
        const dax = planDax(at("20T17:45:00"), at("20T19:45:00"), ["T3"], ["412", "377", "412", "-6412873301142229951", "1e5"]);
        expect(dax).toContain(`'RCA Query Plans'[Captured At UTC] <= DATE ( 2026, 11, 20 ) + TIME ( 19, 45, 0 ),`);
        expect(dax).not.toMatch(/\[Captured At UTC\] >=/);
        expect(dax).toContain("'RCA Query Plans'[Query ID] IN { 412, 377, -6412873301142229951 },");
        expect(dax).toMatch(/\nORDER BY \[Captured At UTC\] DESC$/);
        expect(planDax(at("20T17:45:00"), at("20T19:45:00"), ["T3"])).not.toContain(" IN {");
        // The engine, as the DAX bounds it: a window from 19:00 whose query 412 last changed plan at 17:17.
        const fixture = fixtureSidecar("t3");
        const later = fixture.stats.filter((r) => r.queryId === "412" && r.planId === "31" && r.intervalStart.getTime() === at("20T17:15:00").getTime()).map((r) => ({ ...r, capturedAt: at("20T19:17:05"), intervalStart: at("20T19:00:00"), intervalEnd: at("20T19:15:00") }));
        const sidecar = { ...emptySidecar(), stats: later, plans: fixture.plans };
        const engine = async (query: string) => {
            const key = SIDECAR_TABLES.find((k) => query.includes(`'${SIDECAR_SPEC[k].model}',`))!;
            const bound = (op: ">=" | "<=") => {
                const m = new RegExp(`\\[(?:Captured At UTC|Interval (?:Start|End) UTC|Event Time UTC|Window (?:Start|End) UTC)\\] ${op} DATE \\( (\\d+), (\\d+), (\\d+) \\) \\+ TIME \\( (\\d+), (\\d+), (\\d+) \\)`).exec(query);
                return m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : null;
            };
            const [low, high] = [bound(">="), bound("<=")];
            const time = (row: Record<string, unknown>) => Date.parse(`${String(row[(SIDECAR_SPEC[key].fields as Record<string, { model: string }>)[SIDECAR_SPEC[key].time].model])}Z`);
            return key === "queryPlans" ? asModelRows(sidecar, key).filter((row) => (low === null || time(row) >= low) && (high === null || time(row) <= high)) : asModelRows(sidecar, key);
        };
        const got = await loadSidecar(engine, at("20T17:45:00"), at("20T19:15:00"), ["T3"]);
        expect(got.plans.filter((p) => p.queryId === "412").map((p) => [p.planId, p.capturedAt.toISOString().slice(11, 16)])).toEqual([
            ["31", "16:50"],
            ["31", "17:17"],
            ["58", "17:17"],
        ]);
    });

    it("names the tables a model from before the sidecar doesn't have, and reads the others", async () => {
        const logs: DaxLog[] = [];
        const runDax = async (query: string) => {
            const key = SIDECAR_TABLES.find((k) => query.includes(`'${SIDECAR_SPEC[k].model}',`))!;
            if (key !== "connections") throw new QueryFailure(`The model rejected the query: Query (1, 101) Cannot find table '<oii>${SIDECAR_SPEC[key].model}</oii>'.`, "query");
            return [];
        };
        const got = await loadSidecar(runDax, at("20T17:00:00"), at("20T17:20:00"), ["T4"], { onDax: (l) => logs.push(l) });
        expect(got.missing).toEqual(["RCA Query Coverage", "RCA Query Events", "RCA Query Plans", "RCA Query Stats", "RCA Query Waits"]);
        expect(logs.filter((l) => !l.error).map((l) => l.table)).toEqual(["RCA Connections"]);
    });

    it("fails the load when a read fails, also after its retries, rather than take it for no Query Store evidence", async () => {
        const throttled = new QueryFailure("Fabric couldn't run the query: You have exceeded the amount of requests allowed in the current time frame and further requests will fail. Retry in 60 seconds.", "api", "429");
        const load = loadSidecar(async (query) => {
            if (query.includes("'RCA Query Stats',")) throw throttled;
            return [];
        }, at("20T17:00:00"), at("20T17:20:00"), ["T3"]);
        await expect(load).rejects.toBeInstanceOf(RcaReadError);
        await expect(load).rejects.toMatchObject({ tables: ["RCA Query Stats"] });
    });

    it("says where a read at its limit stopped, by its rows' intervals", async () => {
        const rows = asModelRows(fixtureSidecar("t3"), "queryStats");
        const got = await loadSidecar(async (query, limit) => (query.includes("'RCA Query Stats',") ? rows.slice(0, limit) : []), at("20T16:15:00"), at("20T16:20:00"), ["T3"], { tables: ["queryStats"] });
        expect(got.cut).toBeUndefined();
        const many = Array.from({ length: 2000 }, () => rows[0]);
        const cut = await loadSidecar(async (query, limit) => (query.includes("'RCA Query Stats',") ? many.slice(0, limit) : []), at("20T16:15:00"), at("20T16:20:00"), ["T3"], { tables: ["queryStats"] });
        expect(cut.cut).toEqual([{ table: "RCA Query Stats", until: at("20T16:15:00") }]);
    });

    it("never queries the answer key (rca/blind-detection.json)", async () => {
        const blind = readContract<{ answerKey: { modelTables: string[] } }>("blind-detection.json");
        const queries: string[] = [];
        await loadSidecar(async (q) => (queries.push(q), []), at("20T16:00:00"), at("20T17:00:00"), ["T1", "T2", "T3", "T4", "T4-replica", "T5"]);
        expect(queries).toHaveLength(SIDECAR_TABLES.length);
        for (const q of queries) for (const table of blind.answerKey.modelTables) expect(q).not.toContain(table);
    });
});
