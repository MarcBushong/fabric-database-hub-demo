// The evaluation set, Phase 1 (ADR 0031): each question's facts are in what the tools hand the model, blind; and each
// dataset's blind incidents are graded against its answer key, as Wave 2's scoreboard will grade them: caught, missed,
// or a false alarm, with the time to detect. The key is read here only, never by the tools.

import { describe, expect, it } from "vitest";

import { answerKeyOf, fixtureEvidence, namesAScenario, scenarioIds } from "./testdata/contract";
import { CAUGHT_BY, EVAL_SET, EVAL_WINDOWS, type EvalCase, type EvalData } from "./testdata/eval-set";
import { live, liveAnswerKey, liveSources } from "./testdata/live-rb-2233e0ae";
import { createInvestigationTools, type InvestigationTools } from "./tools";
import { emptyEvidence, type Evidence, type InvestigationResult, type RcaTarget } from "./types";

const MIN = 60_000;

/** A fixture's rows for a window and its targets, as the loader reads them. */
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

function toolsFor(data: EvalData): InvestigationTools {
    if (data === "rb" || data === "ra") return createInvestigationTools({ ...liveSources(data), timeZone: "UTC", latestDay: live("00:00:00"), latest: live("21:33:15") });
    const evidence = fixtureEvidence(data);
    return createInvestigationTools({ load: async (f, t, ts) => window(evidence, f, t, ts), telemetry: async () => ({}), timeZone: "UTC", latestDay: new Date("2026-11-20T00:00:00Z"), latest: new Date("2026-11-20T17:30:00Z") });
}

interface Run {
    scenario: string;
    target: string;
    start: Date;
    end: Date;
}

/** A dataset's answer key: the runs it records. The live files record the connection surges, each to its run-end. */
function runsOf(data: EvalData): Run[] {
    if (data === "t1" || data === "t4") return answerKeyOf(data).flatMap((k) => (k.kind === "run" && k.end ? [{ scenario: k.scenario, target: k.target, start: k.at, end: k.end }] : []));
    const rows = liveAnswerKey(data);
    return rows
        .filter((r) => r.kind === "run")
        .map((r) => {
            const end = rows.find((e) => e.name === "run-end" && e.at > r.at)?.at ?? r.at;
            const events = rows.filter((e) => e.kind === "run-event" && e.at >= r.at && e.at <= end && e.name !== "run-end");
            return { scenario: events.length > 0 && events.every((e) => e.name?.startsWith("surge-")) ? "connection-surge" : "unknown", target: "T4", start: r.at, end };
        });
}

async function runCase(c: EvalCase): Promise<{ outputs: Array<InvestigationResult | string>; text: string }> {
    const tools = toolsFor(c.data);
    const outputs: Array<InvestigationResult | string> = [];
    for (const step of c.steps) outputs.push(await tools.investigate(step.tool, step.args));
    return { outputs, text: outputs.map((o) => (typeof o === "string" ? o : JSON.stringify(o))).join("\n") };
}

const clock = (d: Date) => d.toISOString().slice(11, 19);

/** Each run of a dataset's key in its minutes, graded against its blind incidents, and the incidents no run of a graded family explains. */
async function grade(data: EvalData, key: Run[] = runsOf(data)): Promise<{ runs: string[]; falseAlarms: string[]; ungraded: string[] }> {
    const { from, to } = EVAL_WINDOWS[data];
    const found = await toolsFor(data).investigate("find_incidents", { from, to });
    if (typeof found === "string") throw new Error(found);
    const inMinutes = key.filter((r) => r.start.getTime() >= Date.parse(from) && r.start.getTime() < Date.parse(to));
    const caught = new Set<string>();
    const runs = inMinutes.map((r) => {
        const rule = CAUGHT_BY[r.scenario];
        const name = `${r.scenario} ${r.target} ${clock(r.start)}`;
        if (!rule) return `${name}: no rule`;
        if ("phase" in rule) return `${name}: Phase 2 (${rule.why})`;
        const target = rule.target ?? r.target;
        const e = found.episodes.find((x) => x.target === target && rule.families.includes(x.family) && Date.parse(x.start) >= r.start.getTime() && Date.parse(x.start) <= r.end.getTime() + 15 * MIN);
        if (!e) return `${name}: missed`;
        caught.add(e.key);
        return `${name}: caught by ${e.key} after ${(Date.parse(e.start) - r.start.getTime()) / 1000} s`;
    });
    // A false alarm is an incident of a family the key grades that no run explains; the rest the key can't grade.
    const graded = new Set(inMinutes.flatMap((r) => { const rule = CAUGHT_BY[r.scenario]; return rule && !("phase" in rule) ? rule.families.map((f) => `${rule.target ?? r.target}|${f}`) : []; }));
    const complete = data === "t1" || data === "t4";
    const falseAlarms = found.episodes.filter((e) => !caught.has(e.key) && (complete || graded.has(`${e.target}|${e.family}`))).map((e) => e.key);
    const ungraded = found.episodes.filter((e) => !caught.has(e.key) && !complete && !graded.has(`${e.target}|${e.family}`)).map((e) => e.key);
    return { runs, falseAlarms, ungraded };
}

describe("the evaluation set, Phase 1 (ADR 0031): every answer's facts are in what the tools hand the model, blind", () => {
    it.each(EVAL_SET.map((c) => [c.id, c] as const))(
        "%s",
        async (_id, c) => {
            // The question and the tool calls name no scenario, and nothing injected.
            expect(namesAScenario(c.question), c.question).toEqual([]);
            expect(c.question).not.toMatch(/inject/i);
            expect(namesAScenario(JSON.stringify(c.steps)), c.id).toEqual([]);
            const { outputs, text } = await runCase(c);
            for (const o of outputs) expect(typeof o, `${c.id}: ${String(o)}`).toBe("object");
            for (const fact of c.mustContain) expect(text, `${c.id} must contain /${fact}/`).toMatch(new RegExp(fact));
            for (const wrong of c.mustNotContain ?? []) expect(text, `${c.id} must not contain /${wrong}/`).not.toMatch(new RegExp(wrong));
            if (c.rootCauseRule) {
                const causes = outputs.flatMap((o) => (typeof o === "object" && o.rootCause ? o.rootCause.ruleIds : []));
                expect(causes, `${c.id}'s root cause`).toContain(c.rootCauseRule);
            }
            // Blind: what the tools hand the model names no scenario, and nothing injected.
            expect(namesAScenario(text), c.id).toEqual([]);
            expect(text, c.id).not.toMatch(/inject/i);
            // Grounded: every finding cites its rows, except triage's and the list's pointers to the next tool.
            for (const o of outputs) {
                if (typeof o !== "object" || o.tool === "triage_window" || o.tool === "find_incidents") continue;
                for (const f of o.findings) expect(f.evidence.length, `${c.id}: ${f.ruleId} cites its rows`).toBeGreaterThan(0);
            }
            // Graded against a run its data's key records, or it says why there's none.
            if (c.key) expect(runsOf(c.data).some((r) => r.scenario === c.key?.scenario && r.target === c.key?.target), `${c.id}'s run is in the key`).toBe(true);
            else expect(c.note, `${c.id} says why it has no key`).toBeTruthy();
        },
        30_000,
    );
});

describe("each dataset's blind incidents, graded against its answer key (ADR 0031's scoreboard rule)", () => {
    it("catches every run Phase 1 covers in the contract's fixtures, within a minute, with no false alarm: their keys record every run", async () => {
        expect(await grade("t1")).toEqual({
            runs: [
                "blocking-chain T1 16:52:00: caught by T1-blocking-20261120T165230Z after 30 s",
                `log-flush-waits T1 16:54:00: Phase 2 (${(CAUGHT_BY["log-flush-waits"] as { why: string }).why})`,
            ],
            falseAlarms: [],
            ungraded: [],
        });
        expect(await grade("t4")).toEqual({
            runs: [
                "locking-blocking T4 17:02:00: caught by T4-blocking-20261120T170230Z after 30 s",
                "replica-lag T4 17:11:00: caught by T4-replica-replica_lag-20261120T171200Z after 60 s",
            ],
            falseAlarms: [],
            ungraded: [],
        });
    });

    it("catches every connection surge in B's and A's live rows, and no surge alarm is false; what their key files don't record isn't graded", async () => {
        const b = await grade("rb");
        expect(b.runs).toEqual([
            "connection-surge T4 15:26:39: caught by T4-connections-20261121T152641Z after 1.637 s",
            "connection-surge T4 15:56:20: caught by T4-connections-20261121T155642Z after 21.983 s",
            "connection-surge T4 16:26:20: caught by T4-connections-20261121T162643Z after 22.063 s",
        ]);
        expect(b.falseAlarms).toEqual([]);
        // T5's storms, T4's CPU after each surge, and the replica's stalls: B's key file has no row for them.
        expect(b.ungraded.map((k) => k.replace(/-\d{8}T\d{6}Z$/, "")).sort()).toEqual(["T4-cpu", "T4-cpu", "T4-cpu", "T4-replica-replica_lag", "T4-replica-replica_lag", "T4-replica-replica_lag", "T5-ru", "T5-ru", "T5-throttling", "T5-throttling"]);
        const a = await grade("ra");
        expect(a).toEqual({
            runs: ["connection-surge T4 13:08:02: caught by T4-connections-20261121T130832Z after 29.323 s", "connection-surge T4 14:08:06: caught by T4-connections-20261121T140836Z after 29.883 s"],
            falseAlarms: [],
            ungraded: [],
        });
    });

    it("grades a blind incident no run explains as a false alarm, and a run no incident catches as missed", async () => {
        const t4 = await grade("t4", runsOf("t4").filter((r) => r.scenario !== "replica-lag"));
        expect(t4.falseAlarms).toEqual(["T4-replica-replica_lag-20261120T171200Z"]);
        const late = { scenario: "locking-blocking", target: "T1", start: new Date("2026-11-20T17:05:00Z"), end: new Date("2026-11-20T17:08:00Z") };
        const t1 = await grade("t1", [...runsOf("t1"), late]);
        expect(t1.runs).toContain("locking-blocking T1 17:05:00: missed");
    });

    it("names what Phase 1's set can't grade yet: scenarios with no run in its data, which step 1.8's recordings and Phase 2 add", () => {
        const graded = new Set(["t1", "t4", "rb", "ra"].flatMap((d) => runsOf(d as EvalData).map((r) => r.scenario)));
        expect([...graded].sort()).toEqual(["blocking-chain", "connection-surge", "locking-blocking", "log-flush-waits", "replica-lag"]);
        for (const scenario of Object.keys(CAUGHT_BY)) expect(scenarioIds(), scenario).toContain(scenario);
        expect(scenarioIds().filter((s) => !graded.has(s))).toHaveLength(16);
    });
});
