// The evaluation set, Phase 1 (ADR 0031): each question's facts are in what the tools hand the model, blind; and each
// dataset's blind incidents are graded against its answer key by the scoreboard's own rule (inSearch, searchEndOf):
// caught, missed, or not graded with why, with the time to detect; an incident no run explains is a false alarm, or, where
// the key has no row for a run the demo ran, detected with no key row; and no run of a key is left out unsaid. The key is
// read here only, never by the tools.

import { describe, expect, it } from "vitest";

import type { Bin, SessionRun } from "@/data/model";
import { expectedFamilies, inSearch, scenarioOf, scorePlan, searchEndOf, toPlans } from "@/lib/scoreboard";
import { episodesFromBins } from "./detector";
import { answerKeyOf, fixtureEvidence, namesAScenario, scenarioIds } from "./testdata/contract";
import { EVAL_SET, EVAL_WINDOWS, NO_KEY_ROW, NOT_GRADABLE, T4_BEATS, type EvalCase, type EvalData } from "./testdata/eval-set";
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

/** Database Hub's bins, the scoreboard's grain: an episode counts in the bin that holds its start, as a bin holds its samples. */
const BIN = MIN;
const binOf = (iso: string) => Math.floor(Date.parse(iso) / BIN) * BIN;

/** The families a scenario raises: the scoreboard's (the notebook's SCENARIO_SIGNALS), or, for T4's beats, the set's own. */
const familiesOf = (scenario: string): readonly string[] => T4_BEATS[scenario]?.families ?? expectedFamilies(scenario);

/** A key run as the scoreboard reads a recorded fault. */
function asFault(r: Run, i: number): SessionRun {
    return { requestId: `key:${i}`, requestedAt: r.start, target: r.target, profile: `incident:${r.scenario}`, durationMin: (r.end.getTime() - r.start.getTime()) / MIN, status: "Pass", message: "", windowStart: r.start, windowEnd: r.end, dispatch: "session" };
}

interface Listed {
    key: string;
    target: string;
    family: string;
    start: string;
}

/**
 * The episode that catches a fault by the scoreboard's rule, or null: the first of one of its families on its target that
 * starts in the bin that holds the fault's start or later, before TELEMETRY_LAG_MINUTES after its end or the start of the
 * next fault on its target that raises the same signal, whichever comes first.
 */
function catchOf(fault: SessionRun, faults: readonly SessionRun[], episodes: readonly Listed[]): Listed | null {
    const scenario = scenarioOf(fault);
    const target = T4_BEATS[scenario]?.target ?? fault.target;
    const from = (fault.windowStart as Date).getTime();
    const hits = familiesOf(scenario).flatMap((family) => {
        const to = searchEndOf(fault, family, faults, familiesOf);
        return episodes.filter((e) => e.target === target && e.family === family && inSearch(binOf(e.start), BIN, from, to));
    });
    return hits.sort((a, b) => Date.parse(a.start) - Date.parse(b.start))[0] ?? null;
}

interface Graded {
    /** Each run of the key in the dataset's minutes: caught (by which incident, and after how long), missed, or not graded (why). */
    runs: string[];
    /** The key's runs outside those minutes, which nothing would grade: none may be (the review of b4370565). */
    outside: string[];
    /** Incidents of a family the key grades that its file has no run for, though the demo ran one (NO_KEY_ROW). */
    noKeyRow: string[];
    /** Incidents of a family the key grades that no run explains: false alarms. */
    falseAlarms: string[];
    /** Incidents of a family no run of the key grades. */
    ungraded: string[];
}

/** Each run of a dataset's key, graded against its blind incidents by the scoreboard's rule, and the incidents no run explains. */
async function grade(data: EvalData, key: Run[] = runsOf(data)): Promise<Graded> {
    const { from, to } = EVAL_WINDOWS[data];
    const found = await toolsFor(data).investigate("find_incidents", { from, to });
    if (typeof found === "string") throw new Error(found);
    const name = (r: Run) => `${r.scenario} ${r.target} ${clock(r.start)}`;
    const within = (r: Run) => r.start.getTime() >= Date.parse(from) && r.start.getTime() < Date.parse(to);
    const inMinutes = key.filter(within);
    const faults = inMinutes.map(asFault);
    const notGradable = NOT_GRADABLE[data] ?? {};
    const caught = new Set<string>();
    const runs = inMinutes.map((r, i) => {
        if (notGradable[r.scenario]) return `${name(r)}: not graded (${notGradable[r.scenario]})`;
        if (familiesOf(r.scenario).length === 0) return `${name(r)}: no rule`;
        const e = catchOf(faults[i], faults, found.episodes);
        if (!e) return `${name(r)}: missed`;
        caught.add(e.key);
        return `${name(r)}: caught by ${e.key} after ${Math.max(0, Date.parse(e.start) - r.start.getTime()) / 1000} s`;
    });
    // The families the key grades: a fixture's key records every run, so all of them; a live key file, its runs' only.
    const graded = new Set(inMinutes.filter((r) => !notGradable[r.scenario]).flatMap((r) => familiesOf(r.scenario).map((f) => `${T4_BEATS[r.scenario]?.target ?? r.target}|${f}`)));
    const complete = data === "t1" || data === "t4";
    const keyless = NO_KEY_ROW[data] ?? {};
    const unexplained = found.episodes.filter((e) => !caught.has(e.key));
    const gradedHere = (e: Listed) => complete || graded.has(`${e.target}|${e.family}`);
    return {
        runs,
        outside: key.filter((r) => !within(r)).map(name),
        noKeyRow: unexplained.filter((e) => gradedHere(e) && keyless[e.key]).map((e) => `${e.key}: detected, no key row (${keyless[e.key]})`),
        falseAlarms: unexplained.filter((e) => gradedHere(e) && !keyless[e.key]).map((e) => e.key),
        ungraded: unexplained.filter((e) => !gradedHere(e)).map((e) => e.key),
    };
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

describe("each dataset's blind incidents, graded against its answer key by the scoreboard's rule (ADR 0031)", () => {
    it("catches every run the contract's fixtures can grade, within a minute, with no false alarm: their keys record every run", async () => {
        expect(await grade("t1")).toEqual({
            runs: ["blocking-chain T1 16:52:00: caught by T1-blocking-20261120T165230Z after 30 s", `log-flush-waits T1 16:54:00: not graded (${NOT_GRADABLE.t1?.["log-flush-waits"]})`],
            outside: [],
            noKeyRow: [],
            falseAlarms: [],
            ungraded: [],
        });
        expect(await grade("t4")).toEqual({
            runs: [
                "locking-blocking T4 17:02:00: caught by T4-blocking-20261120T170230Z after 30 s",
                "replica-lag T4 17:11:00: caught by T4-replica-replica_lag-20261120T171200Z after 60 s",
            ],
            outside: [],
            noKeyRow: [],
            falseAlarms: [],
            ungraded: [],
        });
    });

    it("grades every run B's and A's keys record, over all their rows: each surge is caught, and the one B's key has no row for is detected, not a false alarm", async () => {
        const b = await grade("rb");
        expect(b.runs).toEqual([
            "connection-surge T4 15:26:39: caught by T4-connections-20261121T152641Z after 1.637 s",
            "connection-surge T4 15:56:20: caught by T4-connections-20261121T155642Z after 21.983 s",
            "connection-surge T4 16:26:20: caught by T4-connections-20261121T162643Z after 22.063 s",
            "connection-surge T4 19:30:04: caught by T4-connections-20261121T193006Z after 1.743 s",
        ]);
        expect(b.outside).toEqual([]);
        expect(b.noKeyRow).toEqual([`T4-connections-20261121T185152Z: detected, no key row (${NO_KEY_ROW.rb?.["T4-connections-20261121T185152Z"]})`]);
        expect(b.falseAlarms).toEqual([]);
        // T5's storms, T4's CPU after each surge, and the replica's stalls: B's key file has no row for them.
        expect(b.ungraded.map((k) => k.replace(/-\d{8}T\d{6}Z$/, "")).sort()).toEqual([
            ...["T4-cpu", "T4-cpu", "T4-cpu", "T4-cpu"],
            ...["T4-replica-replica_lag", "T4-replica-replica_lag", "T4-replica-replica_lag"],
            ...["T5-ru", "T5-ru", "T5-ru", "T5-throttling", "T5-throttling", "T5-throttling"],
        ]);
        expect(await grade("ra")).toEqual({
            runs: ["connection-surge T4 13:08:02: caught by T4-connections-20261121T130832Z after 29.323 s", "connection-surge T4 14:08:06: caught by T4-connections-20261121T140836Z after 29.883 s"],
            outside: [],
            noKeyRow: [],
            falseAlarms: [],
            ungraded: [],
        });
    });

    it("grades a blind incident no run explains as a false alarm and a run no incident catches as missed, and names a run outside the minutes", async () => {
        const t4 = await grade("t4", runsOf("t4").filter((r) => r.scenario !== "replica-lag"));
        expect(t4.falseAlarms).toEqual(["T4-replica-replica_lag-20261120T171200Z"]);
        const late = { scenario: "locking-blocking", target: "T1", start: new Date("2026-11-20T17:05:00Z"), end: new Date("2026-11-20T17:08:00Z") };
        const t1 = await grade("t1", [...runsOf("t1"), late]);
        expect(t1.runs).toContain("locking-blocking T1 17:05:00: missed");
        // A run outside the minutes is named, never left out unsaid (the review of b4370565).
        const after = { scenario: "blocking-chain", target: "T1", start: new Date("2026-11-20T17:30:00Z"), end: new Date("2026-11-20T17:40:00Z") };
        expect((await grade("t1", [...runsOf("t1"), after])).outside).toEqual(["blocking-chain T1 17:30:00"]);
    });

    it("names what Phase 1's set can't grade yet: scenarios with no run in its data, and T1's log-flush run, whose fixture has no telemetry", () => {
        const graded = new Set(["t1", "t4", "rb", "ra"].flatMap((d) => runsOf(d as EvalData).map((r) => r.scenario)));
        expect([...graded].sort()).toEqual(["blocking-chain", "connection-surge", "locking-blocking", "log-flush-waits", "replica-lag"]);
        for (const scenario of [...Object.keys(T4_BEATS), ...Object.keys(NOT_GRADABLE.t1 ?? {})]) expect(scenarioIds(), scenario).toContain(scenario);
        expect(scenarioIds().filter((s) => !graded.has(s))).toHaveLength(16);
    });
});

// The review of b4370565: the set's rule had no cap at the next fault that raises the same signal, didn't count the bin
// that holds a fault's start, ended at <= where the scoreboard ends at <, and read deadlock as locking-blocking's. It calls
// the scoreboard's own functions now, and these cases pin the two to agree on the telemetry both read.
describe("the evaluation set grades by the scoreboard's rule (ADR 0031)", () => {
    const T0 = Date.UTC(2026, 10, 17, 13, 30);
    const at = (m: number) => new Date(T0 + m * MIN);
    const SESSION = "session:abcd0000-1111-2222-3333-444444444444";
    const fault = (id: string, scenario: string, from: number, to: number): SessionRun => ({
        requestId: `${SESSION}:${id}`,
        requestedAt: at(from),
        target: "T1",
        profile: `incident:${scenario}`,
        durationMin: to - from,
        status: "Pass",
        message: "",
        windowStart: at(from),
        windowEnd: at(to),
        dispatch: "session",
    });
    const session: SessionRun = { ...fault("x", "x", -5, 85), requestId: SESSION, target: "all", profile: "session" };
    /** T1's one-minute bins from an hour before to 90 minutes after 13:30, with blocked processes in the given minutes. */
    const blockedIn = (minutes: readonly number[]): Bin[] =>
        Array.from({ length: 151 }, (_, i) => i - 60).map((m) => ({ at: at(m), target: "T1" as const, cpu: 20, blocked: minutes.includes(m) ? 3 : 0, lockWaitS: null, bufferIoS: null, logRateS: null, waitS: null, ioMb: null, batch: null, sessions: null }));

    it("catches what the scoreboard sees in the same telemetry, and nothing else: the bin that holds a fault's start, 14 and exactly 15 minutes after its end, and the next fault that raises its signal", () => {
        const cases = [
            { name: "the bin that holds its start", faults: [fault("00", "blocking-chain", 0.5, 10)], blocked: [0, 1, 2], expected: { "00": at(0) } },
            { name: "14 minutes after its end", faults: [fault("00", "blocking-chain", 0, 10)], blocked: [24], expected: { "00": at(24) } },
            { name: "exactly 15 minutes after its end", faults: [fault("00", "blocking-chain", 0, 10)], blocked: [25], expected: { "00": null } },
            { name: "after the next fault that raises its signal", faults: [fault("00", "blocking-chain", 0, 10), fault("01", "deadlock-storm", 11, 21)], blocked: [12, 13, 14, 15, 16, 17, 18], expected: { "00": null, "01": at(12) } },
        ];
        for (const c of cases) {
            const runs = [session, ...c.faults];
            const bins = blockedIn(c.blocked);
            const plan = toPlans(runs).find((p) => p.key === SESSION)!;
            const scoreboard = Object.fromEntries(scorePlan(plan, { bins, beats: [], runs }).map((s) => [s.key.slice(-2), s.status === "Pass" ? s.visibleAt : null]));
            const episodes = episodesFromBins(bins).map((e) => ({ key: e.key, target: e.target, family: e.family, start: e.start.toISOString() }));
            const evaluation = Object.fromEntries(c.faults.map((f) => [f.requestId.slice(-2), ((e) => (e ? new Date(binOf(e.start)) : null))(catchOf(f, c.faults, episodes))]));
            expect(evaluation, c.name).toEqual(scoreboard);
            expect(evaluation, c.name).toEqual(c.expected);
        }
    });

    it("counts an episode in the bin that holds its start, and reads a scenario's families as the scoreboard does", () => {
        const f = fault("00", "locking-blocking", 0.5, 10);
        const episode = (family: string, start: Date) => ({ key: `T1-${family}-${start.toISOString()}`, target: "T1", family, start: start.toISOString() });
        // 13:30:10 is in the bin that holds the fault's start, 13:30:30; 13:29:40 is in the bin before.
        expect(catchOf(f, [f], [episode("blocking", new Date(T0 + 10_000))])).not.toBeNull();
        expect(catchOf(f, [f], [episode("blocking", new Date(T0 - 20_000))])).toBeNull();
        // Locking and blocking raises blocked processes (the notebook's SCENARIO_SIGNALS): a deadlock alone doesn't catch it.
        expect(catchOf(f, [f], [episode("deadlock", at(2))])).toBeNull();
    });
});
