import { describe, expect, it } from "vitest";
import { analyzeQueries, notInHistoryYet, QS_EVIDENCE_FIX, QS_RETENTION_DAYS, type QueryIncident } from "./queries";
import { emptySidecar, type QueryCoverage, type SidecarEvidence } from "./sidecar";
import { fixtureSidecar, namesAScenario, readContractText } from "./testdata/contract";

const at = (text: string) => new Date(`2026-11-${text}Z`);
const NOW = at("21T12:00:00");
const cpuAt = (start: string): QueryIncident => ({ family: "cpu", start: at(start), end: at("20T17:11:00"), last: at("20T17:10:00") });

/** T3's CPU incident in the sidecar's minutes (rca/fixtures/README.md, What a blind RCA finds in the sidecars). */
const t3 = (sidecar: SidecarEvidence = fixtureSidecar("t3"), incident: QueryIncident | undefined = cpuAt("20T17:04:00")) =>
    analyzeQueries({ target: "T3", from: at("20T17:03:00"), to: at("20T17:10:00"), sidecar, now: NOW, incident });

describe("Query Store's rules: T3's plan regression (t3-plan-regression)", () => {
    // The review of d441fe13: the facts through details, and the text only for its numbers, so the reader's own words (the
    // plan summaries, A1's) can change without changing what the rules found.
    it("finds the regression from the sidecar alone: both plans, the baseline, the mixed interval, and the response as measured", () => {
        const a = t3();
        expect(a.rootCause?.ruleIds).toEqual(["QS-PLAN-REGRESSION", "QS-PLAN-FORCED"]);
        expect(a.rootCause?.confidence).toBe("high");
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
        expect(a.details.forcings).toEqual([expect.objectContaining({ kind: "forced", queryId: "412", planId: "31", forcingType: "AUTO", from: "2026-11-20T17:09:00Z", at: "2026-11-20T17:10:00Z" })]);
        expect(a.details.forcings[0].after).toMatchObject({ executions: 371, from: "2026-11-20T17:15:00Z", openWhenRead: true });
        expect(a.details.forcings[0].after?.cpuMs).toBeCloseTo(2.1, 1);
        // Automatic tuning's recommendation, from its first appearance (Active, with no state before it).
        expect(a.details.tuning.map((t) => [t.state, t.previousState ?? null, t.at])).toEqual([
            ["Active", null, "2026-11-20T17:06:00Z"],
            ["Executing", "Active", "2026-11-20T17:09:30Z"],
            ["Verifying", "Executing", "2026-11-20T17:10:30Z"],
        ]);
        expect(a.details).toMatchObject({ recorded: "yes", intervalMinutes: 15, intervals: { from: "2026-11-20T17:00:00Z", to: "2026-11-20T17:15:00Z" }, state: { state: "READ_WRITE", captureMode: "AUTO", intervalMinutes: 15 } });
        // The statement says the same numbers.
        const s = a.rootCause!.statement;
        for (const figure of ["plan 58", "17:03:11 UTC", "176 ms", "524 executions", "2.1 ms for plan 31", "83 times", "668 times", "96 %", "92,224 of 95,644 ms", "17:09:00 and 17:10:00 UTC", "371 times", "17:20:10 UTC"]) expect(s, figure).toContain(figure);
        // Automatic plan correction already forced it: no advice to turn it on.
        expect(a.recommendations.map((r) => r.id)).toContain("CPU-FORCE-PLAN");
        expect(a.recommendations.map((r) => r.id)).not.toContain("CPU-AUTO-CORRECT");
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

    // Decision C (unit 2's plan, revision 2; the review of d441fe13): after a Run all session the capture did read Query
    // Store, and its evidence waits on the VMs, so "it didn't read Query Store then" was a false cause.
    it("says minutes with no coverage row aren't in this history yet, or were saved by an older part, with the fix, never that they weren't captured", () => {
        const a = analyzeQueries({ ...window, sidecar: emptySidecar() });
        expect(a.details).toMatchObject({ recorded: "no-rows", state: null });
        expect(a.notCaptured).toEqual([
            `T3: Query Store's evidence from 17:03:00 to 17:10:00 UTC isn't in this history yet, or those minutes were saved by a part of the demo older than Query Store's evidence. ${QS_EVIDENCE_FIX} That says nothing about Query Store on T3.`,
        ]);
        expect(a.notCaptured[0]).not.toMatch(/not captured|no Query Store\b|didn't read|wasn't running/i);
    });

    // The re-check of fc430a78: where the evidence waits, for how long, and the fix are one sentence, QS_EVIDENCE_FIX, so T2c
    // (Run all's own path) changes them in one place; and the runner deletes a sidecar no save took 30 days after sealing it.
    it("says where a Run all session's evidence waits, for as long as the runner keeps it, and the fix, in the one sentence", () => {
        const days = /A sealed sidecar stays until it's acknowledged, or for (\d+) days after its sealing\./.exec(readContractText("README.md"))?.[1];
        expect(days, "rca/README.md, The sidecar: how long the runner keeps a sealed sidecar").toBeDefined();
        expect(QS_EVIDENCE_FIX).toMatch(
            new RegExp(`^After a Run all session, that evidence waits on the VMs for ${days} days for a save from the scripts to take it: \\./scripts/deploy\\.ps1, then \\./scripts/stop-demo\\.ps1 -SaveHistory with the VMs running \\(\\./scripts/start-demo\\.ps1 first when they're stopped\\)\\.$`),
        );
        // The words around it name none of the path: no Run all, VMs, script, or time the runner keeps it.
        for (const line of [notInHistoryYet("T3", "Which queries drove it"), notInHistoryYet("T4", "who held the connections from 10:06:00 to 10:12:00 UTC")]) {
            expect(line.split(QS_EVIDENCE_FIX)).toHaveLength(2);
            expect(line.replace(QS_EVIDENCE_FIX, "")).not.toMatch(/Run all|\bVMs?\b|\bscripts?\b|\.ps1|\bdays?\b|\bwaits?\b/i);
        }
    });

    it("says what the capture read held no query, with Query Store's state when it's worth saying, and each gap as its own line", () => {
        const readOnly = emptySidecar();
        readOnly.coverage.push({ target: "T3", from: at("20T16:50:00"), to: at("20T17:20:00"), state: "READ_ONLY", backfill: false, sources: ["RCA-SQL-15"], gaps: ["Query Store was READ_ONLY from 16:58: it reached its size limit (readonly_reason 65536)."] });
        const a = analyzeQueries({ ...window, sidecar: readOnly });
        expect(a.details).toMatchObject({ recorded: "no-rows", state: { state: "READ_ONLY" } });
        expect(a.notCaptured).toEqual([
            "T3: Query Store's evidence in this history holds no query from 17:03:00 to 17:10:00 UTC: Query Store was READ_ONLY when the capture read it.",
            "T3: Query Store was READ_ONLY from 16:58: it reached its size limit (readonly_reason 65536).",
        ]);
        for (const line of a.notCaptured) expect(line).not.toMatch(/T3 (has|doesn't have) (no )?Query Store/);
    });

    // The review of d441fe13: on PostgreSQL the state is the capture mode, and "all" read as an abnormal state.
    it("says T4's capture mode only when it's none, and only the gaps of rows whose own window holds the minutes", () => {
        const minutes = { target: "T4" as const, from: at("20T18:00:00"), to: at("20T18:10:00"), now: NOW };
        const row = (state: string, gaps: string[]): QueryCoverage => ({ target: "T4", from: at("20T17:55:00"), to: at("20T18:20:00"), state, readFrom: at("20T17:45:00"), readTo: at("20T18:15:00"), backfill: false, sources: ["RCA-PG-13"], gaps });
        const holding = "T4: Query Store's evidence in this history holds no query from 18:00:00 to 18:10:00 UTC";
        const all = { ...emptySidecar(), coverage: [row("all", ["Pending publication: Query Store shows an interval only once it ends, so 18:15 to 18:20 is read at the next start while T4 runs."])] };
        expect(analyzeQueries({ ...minutes, sidecar: all }).notCaptured).toEqual([`${holding}.`]);
        expect(analyzeQueries({ ...minutes, sidecar: { ...emptySidecar(), coverage: [row("none", [])] } }).notCaptured).toEqual([`${holding}: its capture mode was none.`]);
        // A row whose read reached the minutes, but whose own window doesn't hold them, says nothing of them.
        const earlier = { ...emptySidecar(), coverage: [{ ...row("all", ["The sidecar's budget cut each plan's waits past its three largest."]), from: at("20T17:30:00"), to: at("20T17:55:00") }] };
        expect(analyzeQueries({ ...minutes, sidecar: earlier }).notCaptured).toEqual([`${holding}.`]);
    });

    // The review of d441fe13: with Query Store's rows there, a cut of the sidecar's budget or a refused read vanished.
    it("says each overlapping row's gaps beside Query Store's rows too, as lines with their target", () => {
        const s = fixtureSidecar("t3");
        const gaps = ["The sidecar's budget cut the plan summaries of query 377's plans.", "RCA-AZ-04 was refused: it needs VIEW SERVER PERFORMANCE STATE, through ##MS_ServerStateReader##."];
        s.coverage = s.coverage.map((c) => ({ ...c, gaps }));
        const a = t3(s);
        expect(a.details.recorded).toBe("yes");
        expect(a.notCaptured).toEqual(gaps.map((g) => `T3: ${g}`));
        expect(t3().notCaptured).toEqual([]);
    });

    // Contract b1c12d23: a backfill that finds T4 started again during a pending range calls what Query Store doesn't show of
    // it "Lost when T4 stopped", never pending (A2's gap, as the runner writes it).
    it("takes a range a backfill finished out of what's pending, and says what it lost in its gap's words", () => {
        const lost = "Lost when T4 stopped: Query Store shows nothing of 2026-11-20 17:15 to 2026-11-20 17:20 UTC, which it still held in memory when T4 stopped, and T4 has started again since, so none of it will show.";
        const backfill = (extra: Partial<QueryCoverage>): QueryCoverage => ({ target: "T4", from: at("20T17:15:00"), to: at("20T17:20:00"), state: "all", backfill: true, sources: ["RCA-PG-13"], gaps: [], ...extra });
        const minutes = { target: "T4" as const, from: at("20T17:15:00"), to: at("20T17:20:00"), now: NOW };
        const s = fixtureSidecar("t4");
        s.coverage.push(backfill({ gaps: [lost] }));
        const a = analyzeQueries({ ...minutes, sidecar: s });
        expect(a.details).toMatchObject({ recorded: "no-rows", pending: [] });
        expect(a.notCaptured).toEqual(["T4: Query Store's evidence in this history holds no query from 17:15:00 to 17:20:00 UTC.", `T4: ${lost}`]);
        expect(a.notCaptured.join(" ")).not.toMatch(/pending publication|next start/i);
        // A backfill that still waits takes the range's place with what's left of it.
        const waits = fixtureSidecar("t4");
        waits.coverage.push(backfill({ readFrom: at("20T17:15:00"), readTo: at("20T17:15:00"), pendingFrom: at("20T17:15:00"), pendingTo: at("20T17:20:00") }));
        expect(analyzeQueries({ ...minutes, sidecar: waits }).details.pending).toEqual([{ from: "2026-11-20T17:15:00Z", to: "2026-11-20T17:20:00Z", expired: false }]);
        // One that waited, then one that finished: neither range is pending any more.
        const twice = fixtureSidecar("t4");
        twice.coverage.push(backfill({ readFrom: at("20T17:15:00"), readTo: at("20T17:15:00"), pendingFrom: at("20T17:15:00"), pendingTo: at("20T17:20:00") }), backfill({ gaps: [lost] }));
        const after = analyzeQueries({ ...minutes, sidecar: twice });
        expect(after.details.pending).toEqual([]);
        expect(after.notCaptured).toContain(`T4: ${lost}`);
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
