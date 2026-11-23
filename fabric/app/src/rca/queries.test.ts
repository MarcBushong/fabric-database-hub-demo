import { describe, expect, it } from "vitest";
import { analyzeQueries, QS_RETENTION_DAYS, type QueryIncident } from "./queries";
import { emptySidecar, type SidecarEvidence } from "./sidecar";
import { fixtureSidecar, namesAScenario } from "./testdata/contract";

const at = (text: string) => new Date(`2026-11-${text}Z`);
const NOW = at("21T12:00:00");
const cpuAt = (start: string): QueryIncident => ({ family: "cpu", start: at(start), end: at("20T17:11:00"), last: at("20T17:10:00") });

/** T3's CPU incident in the sidecar's minutes (rca/fixtures/README.md, What a blind RCA finds in the sidecars). */
const t3 = (sidecar: SidecarEvidence = fixtureSidecar("t3"), incident: QueryIncident | undefined = cpuAt("20T17:04:00")) =>
    analyzeQueries({ target: "T3", from: at("20T17:03:00"), to: at("20T17:10:00"), sidecar, now: NOW, incident });

describe("Query Store's rules: T3's plan regression (t3-plan-regression)", () => {
    it("finds the regression from the sidecar alone: both plans, the baseline, the mixed interval, and the response as measured", () => {
        const a = t3();
        expect(a.rootCause?.ruleIds).toEqual(["QS-PLAN-REGRESSION", "QS-PLAN-FORCED"]);
        expect(a.rootCause?.confidence).toBe("high");
        const s = a.rootCause!.statement;
        expect(s).toContain("Query 412 ([demo].[usp_visit_summary_lookup]) changed to a new plan: plan 58, compiled at 17:03:11 UTC, which took 176 ms of CPU an execution over its 524 executions from 17:03:12 to 17:09:40 UTC, against 2.1 ms for plan 31 in Query Store's 15-minute intervals from 16:15 to 17:00 UTC: 83 times as much.");
        expect(s).toContain("Query Store's 15-minute interval from 17:00 to 17:15 UTC is mixed: plan 31 also ran 668 times in it, and plan 58 used 96 % of the captured top queries' CPU in it (92,224 of 95,644 ms).");
        expect(s).toContain("Plan 58's shape, from its showplan: Clustered Index Scan on [care].[appointments].[pk_appointments], every row");
        expect(s).toContain(
            "The response, as measured: Plan 31 of query 412 was forced by automatic plan correction between 17:09:00 and 17:10:00 UTC (automatic tuning's recommendation: Executing at 17:09:30 UTC, Verifying at 17:10:30 UTC). It was compiled again at 17:09:41 UTC. Plan 58 last ran at 17:09:40 UTC. From Query Store's 15-minute interval from 17:15 to 17:30 UTC, plan 31 ran alone, 371 times at 2.1 ms of CPU each; the last interval was still open when the capture last read it, at 17:20:10 UTC.",
        );
        const change = a.details.planChanges[0];
        expect(change).toMatchObject({ queryId: "412", measure: "cpu", regression: true, mixed: { start: "2026-11-20T17:00:00Z", end: "2026-11-20T17:15:00Z", otherExecutions: 668 } });
        expect(change.newPlan).toMatchObject({ planId: "58", compiledInWindow: true, isParallel: true, maxDop: 4, estimatedCost: 38.6, executions: 524, firstExecutionUtc: "2026-11-20T17:03:12Z" });
        expect(change.newPlan.perExecution.cpuMs).toBeCloseTo(176, 1);
        expect(change.before).toEqual([expect.objectContaining({ planId: "31", intervals: 3, from: "2026-11-20T16:15:00Z", to: "2026-11-20T17:00:00Z", executions: 3576, estimatedCost: 0.0331 })]);
        expect(change.times).toBeCloseTo(83.4, 1);
        // Plan 58's waits, by Query Store's categories, are in its query's view.
        expect(a.details.top[0].waits.slice(0, 2)).toEqual([
            { category: "CPU", waitMs: 18_900 },
            { category: "Parallelism", waitMs: 11_620 },
        ]);
        // Automatic plan correction already forced it: no advice to turn it on.
        expect(a.recommendations.map((r) => r.id)).toEqual(["CPU-FORCE-PLAN", "CPU-MISSING-INDEX"]);
        expect(a.details.forcings).toEqual([expect.objectContaining({ kind: "forced", queryId: "412", planId: "31", forcingType: "AUTO", from: "2026-11-20T17:09:00Z", at: "2026-11-20T17:10:00Z" })]);
        expect(a.details.tuning.map((t) => t.state)).toEqual(["Executing", "Verifying"]);
        expect(a.details).toMatchObject({ recorded: "yes", intervalMinutes: 15, intervals: { from: "2026-11-20T17:00:00Z", to: "2026-11-20T17:15:00Z" }, state: { state: "READ_WRITE", captureMode: "AUTO", intervalMinutes: 15 } });
    });

    it("says why it's sure: the CPU's rise at the new plan's first run, or a tuning recommendation naming the same plans; medium with neither", () => {
        const withoutTuning = { ...fixtureSidecar("t3"), events: fixtureSidecar("t3").events.filter((e) => e.kind !== "tuning") };
        expect(t3(withoutTuning).rootCause?.confidence).toBe("high");
        expect(t3(withoutTuning).rootCause?.statement).toContain("The CPU rose at 17:04:00 UTC, as the new plan first ran.");
        expect(t3(withoutTuning, cpuAt("20T17:30:00")).rootCause?.confidence).toBe("medium");
        expect(t3(fixtureSidecar("t3"), cpuAt("20T17:30:00")).rootCause?.statement).toContain("Automatic tuning recommended forcing the earlier plan for the same query.");
    });

    it("says new only when the plan was compiled in the minutes, and otherwise only that the query hadn't run it in the hour before", () => {
        const s = fixtureSidecar("t3");
        s.plans = s.plans.map((p) => (p.planId === "58" ? { ...p, compiled: at("20T09:00:00") } : p));
        const a = t3(s);
        expect(a.details.planChanges[0].newPlan.compiledInWindow).toBe(false);
        expect(a.rootCause?.statement).toContain("changed to a plan it hadn't run in the hour before: plan 58, compiled at 09:00:00 UTC, before these minutes, which took 176 ms");
        expect(a.rootCause?.statement).not.toContain("a new plan");
    });

    it("compares only with a baseline: at least 2 intervals in the hour before, never one", () => {
        const s = fixtureSidecar("t3");
        s.stats = s.stats.filter((r) => r.intervalStart.getTime() >= at("20T16:45:00").getTime());
        const a = t3(s);
        expect(a.details.planChanges[0]).toMatchObject({ times: null, regression: false });
        expect(a.rootCause?.ruleIds).toEqual(["QS-TOP-CPU"]);
        expect(a.details.top.find((q) => q.queryId === "377")?.change.kind).toBe("no-baseline");
    });

    it("counts an interval read twice once, with its latest read", () => {
        const s = fixtureSidecar("t3");
        const earlier = s.stats.filter((r) => r.intervalStart.getTime() === at("20T17:00:00").getTime()).map((r) => ({ ...r, capturedAt: at("20T17:08:00"), executions: Math.round(r.executions / 2), cpuMs: (r.cpuMs ?? 0) / 2 }));
        s.stats = [...earlier, ...s.stats];
        expect(t3(s).rootCause?.statement).toBe(t3().rootCause?.statement);
    });

    it("lists the top queries with their shares of the captured top lists, and what changed against the hour before", () => {
        const top = t3().details.top;
        expect(top.map((q) => [q.queryId, q.figures.executions, Math.round(q.share!.percent), q.change.kind])).toEqual([
            ["412", 1192, 98, "plan-change"],
            ["377", 401, 2, "costlier"],
            ["902", 30, 0, "not-in-top-lists-before"],
        ]);
        expect(top[1].change.text).toBe("the same plan costing more: 4.7 ms of CPU an execution, against 0.9 ms in the hour before");
        expect(top[2].change.text).toBe("not in the capture's top lists in the hour before, which doesn't mean it didn't run then");
        expect(t3().findings.find((f) => f.ruleId === "QS-TOP-CPU")?.detail).toContain('query 902 ("SELECT r.session_id, r.status, r.wait_type, r.wait_time, r.cpu_time FROM…"): 30 executions, 151 ms of CPU, under 1 % of the captured top queries\' CPU');
    });

    it("names a wait family's queries by its Query Store category and figure", () => {
        const a = analyzeQueries({ target: "T3", from: at("20T17:03:00"), to: at("20T17:10:00"), sidecar: fixtureSidecar("t3"), now: NOW, incident: { family: "parallelism", start: at("20T17:04:00"), end: at("20T17:10:00"), last: at("20T17:10:00") } });
        const waits = a.findings.find((f) => f.ruleId === "QS-WAITS")!;
        expect(waits.detail).toBe(
            "In Query Store's 15-minute interval from 17:00 to 17:15 UTC, the queries by Parallelism waits: query 412 ([demo].[usp_visit_summary_lookup]) 11,620 ms; and by the highest degree of parallelism: query 412 ([demo].[usp_visit_summary_lookup]) 4; query 377 (\"SELECT TOP (?) p.patient_id, p.last_name, p.first_name FROM care.patient…\") 1; query 902 (\"SELECT r.session_id, r.status, r.wait_type, r.wait_time, r.cpu_time FROM…\") 1.",
        );
        expect(a.recommendations.map((r) => r.id)).toContain("PAR-MAXDOP");
    });
});

describe("Query Store's rules: T4 (t4-query-store)", () => {
    const blocking: QueryIncident = { family: "blocking", start: at("20T17:02:30"), end: at("20T17:12:20"), last: at("20T17:11:20") };

    it("names the queries that waited on locks, by time, with their sampled waits, and states the interval before without comparing", () => {
        const a = analyzeQueries({ target: "T4", from: at("20T17:02:30"), to: at("20T17:12:20"), sidecar: fixtureSidecar("t4"), now: NOW, incident: blocking });
        expect(a.findings.find((f) => f.ruleId === "QS-LOCK-WAITS")?.detail).toBe(
            'In Query Store\'s 15-minute interval from 17:00 to 17:15 UTC, the queries that waited on locks: query -6412873301142229951 ("UPDATE care.work_queues SET status = $1, claimed_at = now() WHERE queue_…"), run by contosocare_runner, 214 executions at 1,174 ms each, the longest 20,050 ms, waits Lock:transactionid 2,480 times (about 248 s from its samples). In the interval before, from 16:45 to 17:00 UTC, it ran 220 times in 61.6 ms, with no lock waits recorded.',
        );
        // A 64-bit query ID whole, and the plan PostgreSQL's Query Store reports here, 0.
        expect(a.details.top[0]).toMatchObject({ queryId: "-6412873301142229951", plans: ["0"], login: "contosocare_runner", baseline: null, change: { kind: "no-baseline" } });
        expect(a.details.planChanges).toEqual([]);
        expect(a.notCaptured).toContain("T4: PostgreSQL's Query Store records no CPU time, and here no plans (pg_qs.store_query_plans is off), so its queries are ranked by their time, and a plan change can't be told.");
    });

    it("says T4's last minutes are pending publication, never not captured, and expired past its 7 days", () => {
        const pending = analyzeQueries({ target: "T4", from: at("20T17:15:00"), to: at("20T17:20:00"), sidecar: fixtureSidecar("t4"), now: NOW });
        expect(pending.details).toMatchObject({ recorded: "pending", pending: [{ from: "2026-11-20T17:15:00Z", to: "2026-11-20T17:20:00Z", expired: false }] });
        expect(pending.notCaptured).toEqual([
            "T4: Query Store's minutes from 17:15:00 to 17:20:00 UTC are pending publication: PostgreSQL's Query Store shows an interval only once it ends (https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store), so the capture couldn't read them when it stopped. Its next start, with T4 running, reads them into this history; until then, which queries ran in them isn't known.",
        ]);
        expect(pending.notCaptured.join(" ")).not.toMatch(/not captured|no Query Store statistics/);
        const later = analyzeQueries({ target: "T4", from: at("20T17:15:00"), to: at("20T17:20:00"), sidecar: fixtureSidecar("t4"), now: new Date(at("20T17:20:00").getTime() + (QS_RETENTION_DAYS.T4! + 1) * 86_400_000) });
        expect(later.details.pending[0].expired).toBe(true);
        expect(later.notCaptured[0]).toMatch(/were pending publication when the capture read them, and are past what T4's Query Store keeps \(7 days, pg_qs\.retention_period_in_days\)/);
        // A later read of those intervals (a backfill) takes them out of what's pending.
        const s = fixtureSidecar("t4");
        s.coverage.push({ ...s.coverage[0], from: at("21T09:00:00"), to: at("21T09:20:00"), readFrom: at("20T17:15:00"), readTo: at("20T17:30:00"), pendingFrom: undefined, pendingTo: undefined, backfill: true, gaps: [] });
        expect(analyzeQueries({ target: "T4", from: at("20T17:15:00"), to: at("20T17:20:00"), sidecar: s, now: NOW }).details.pending).toEqual([]);
    });

    it("says a read replica records nothing in Query Store, and T5 has none, whatever the history holds", () => {
        const replica = analyzeQueries({ target: "T4-replica", from: at("20T17:11:00"), to: at("20T17:15:00"), sidecar: fixtureSidecar("t4"), now: NOW });
        expect(replica.details.recorded).toBe("replica");
        expect(replica.notCaptured).toEqual(["T4-replica: Query Store doesn't record a read replica's queries (https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store), so neither this history nor T4-replica has them."]);
        expect(analyzeQueries({ target: "T5", from: at("20T17:11:00"), to: at("20T17:15:00"), sidecar: fixtureSidecar("t4"), now: NOW }).details.recorded).toBe("none");
    });
});

describe("Query Store's rules: what this history doesn't hold", () => {
    const window = { target: "T3" as const, from: at("20T17:03:00"), to: at("20T17:10:00"), now: NOW };

    it("says a model from before the sidecar lacks the tables, with its fix, never that the target has no Query Store", () => {
        const a = analyzeQueries({ ...window, sidecar: { ...emptySidecar(), missing: ["RCA Query Coverage", "RCA Query Stats"] } });
        expect(a.details.recorded).toBe("model-missing");
        expect(a.notCaptured).toEqual(["T3: this history's model doesn't have Query Store's tables yet (RCA Query Coverage, RCA Query Stats), so it holds no per-query statistics; ./scripts/deploy.ps1 updates the model."]);
    });

    it("says why there are no rows: what the capture read of Query Store, or that it didn't read it then", () => {
        expect(analyzeQueries({ ...window, sidecar: emptySidecar() }).notCaptured).toEqual([
            "T3: the capture holds no Query Store statistics from 17:03:00 to 17:10:00 UTC: it didn't read Query Store then (a history saved before it did, or the capture wasn't running), which says nothing about Query Store on T3.",
        ]);
        const readOnly = emptySidecar();
        readOnly.coverage.push({ target: "T3", from: at("20T16:50:00"), to: at("20T17:20:00"), state: "READ_ONLY", backfill: false, sources: ["RCA-SQL-15"], gaps: ["Query Store was READ_ONLY from 16:58: it reached its size limit (readonly_reason 65536)."] });
        expect(analyzeQueries({ ...window, sidecar: readOnly }).notCaptured).toEqual([
            "T3: the capture holds no Query Store statistics from 17:03:00 to 17:10:00 UTC: Query Store was READ_ONLY when it read it (Query Store was READ_ONLY from 16:58: it reached its size limit (readonly_reason 65536).).",
        ]);
        for (const line of analyzeQueries({ ...window, sidecar: emptySidecar() }).notCaptured) expect(line).not.toMatch(/T3 (has|doesn't have) (no )?Query Store/);
    });

    it("sends a DBA to the target's own Query Store while it keeps the minutes, and says when it no longer does", () => {
        expect(t3().nextSteps[0]).toMatch(/^Read the queries and plans in Query Store on T3 for from 17:03:00 to 17:10:00 UTC while it keeps them \(14 days\)/);
        const late = analyzeQueries({ ...window, sidecar: fixtureSidecar("t3"), now: at("20T17:10:00") });
        expect(late.details.retention).toEqual({ days: 14, past: false });
        const past = analyzeQueries({ ...window, sidecar: fixtureSidecar("t3"), now: new Date(at("20T17:10:00").getTime() + 15 * 86_400_000) });
        expect(past.details.retention).toEqual({ days: 14, past: true });
        expect(past.nextSteps[0]).toBe("Query Store on T3 keeps 14 days (STALE_QUERY_THRESHOLD_DAYS), less when it nears its size limit, so it no longer holds from 17:03:00 to 17:10:00 UTC: this history's rows are what's left of them.");
    });
});

describe("Query Store's rules, blind", () => {
    it("names no scenario in what they say", () => {
        const said = [t3(), analyzeQueries({ target: "T4", from: at("20T17:00:00"), to: at("20T17:20:00"), sidecar: fixtureSidecar("t4"), now: NOW })];
        expect(namesAScenario(JSON.stringify(said))).toEqual([]);
    });

    it("never branches on a module's or a statement's text: the same rows under other names reach the same causes and figures", () => {
        const renamed = fixtureSidecar("t3");
        const rename = <T extends { module?: string; statement?: string }>(r: T): T => ({ ...r, ...(r.module ? { module: "[x].[m]" } : {}), ...(r.statement ? { statement: "S" } : {}) });
        renamed.stats = renamed.stats.map(rename);
        renamed.plans = renamed.plans.map(rename);
        const a = t3();
        const b = t3(renamed);
        expect(b.rootCause?.ruleIds).toEqual(a.rootCause?.ruleIds);
        expect(b.findings.map((f) => f.ruleId)).toEqual(a.findings.map((f) => f.ruleId));
        expect(b.details.planChanges.map((c) => [c.queryId, c.newPlan.planId, c.times])).toEqual(a.details.planChanges.map((c) => [c.queryId, c.newPlan.planId, c.times]));
        expect(b.details.top.map((q) => [q.queryId, q.figures, q.change.kind])).toEqual(a.details.top.map((q) => [q.queryId, q.figures, q.change.kind]));
    });
});
