// The evaluation set, Phase 1 (ADR 0031): each question's facts are in what the tools hand the model, blind; and each
// dataset's blind incidents are graded against its answer key by the scoreboard's own rule (inSearch, searchEndOf):
// caught, missed, or not graded with why, with the time to detect; an incident no run explains is a false alarm, or, where
// the key has no row for a run the demo ran, detected with no key row; and no run of a key is left out unsaid. The key is
// read here only, never by the tools.

import { describe, expect, it } from "vitest";

import { toAgentBeats, toBins, toIncidents, toSessions, toWaitBins, withCategoryWaits, type Bin, type SessionRun } from "@/data/model";
import { agentLoopQuery, incidentWaitsQuery, incidentsQuery, seriesQuery, sessionsQuery, type Filters } from "@/data/queries";
import { expectedFamilies, inSearch, scenarioOf, scorePlan, searchEndOf, toPlans } from "@/lib/scoreboard";
import { sampleRows } from "@/preview/sample-data";
import { SESSION_KEY } from "@/preview/sample-session";
import { episodesFromBins } from "./detector";
import { answerKeyOf, fixtureEvidence, fixtureSidecar, namesAScenario, scenarioIds } from "./testdata/contract";
import { EVAL_SET, EVAL_SIDECARS, EVAL_WINDOWS, NO_KEY_ROW, NOT_GRADABLE, T4_BEATS, type EvalCase, type EvalData } from "./testdata/eval-set";
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
    const evidence = data === "t3" ? emptyEvidence() : fixtureEvidence(data);
    const sidecar = EVAL_SIDECARS[data];
    const rows = sidecar ? fixtureSidecar(sidecar) : null;
    return createInvestigationTools({
        load: async (f, t, ts) => window(evidence, f, t, ts),
        telemetry: async () => ({}),
        // Query Store's evidence, whatever the minutes read (its rules keep each row's own), on a clock within its retention.
        ...(rows ? { sidecar: async () => rows, now: () => new Date("2026-11-21T12:00:00Z") } : {}),
        timeZone: "UTC",
        latestDay: new Date("2026-11-20T00:00:00Z"),
        latest: new Date("2026-11-20T17:30:00Z"),
    });
}

interface Run {
    scenario: string;
    target: string;
    start: Date;
    end: Date;
}

/** A dataset's answer key: the runs it records. The live files record the connection surges, each to its run-end; the sidecar fixtures, none. */
function runsOf(data: EvalData): Run[] {
    if (data === "t3") return [];
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
    /** Its recovery, or null when its end isn't known: its data ended, or broke off, first. */
    end: string | null;
    /** Its last sample at its level: with no known end, as far as it's known to have lasted. */
    last: string;
}

/**
 * The episodes that catch a fault by the scoreboard's rule, earliest first, and when: of its families on its target at its
 * level in the bin that holds the fault's start or later, before TELEMETRY_LAG_MINUTES after its end or the start of the
 * next fault on its target that raises the same signal, whichever comes first. One that starts in those minutes catches it
 * in the bin that holds its start; one still open at the fault's start, in the bin that holds that start, where the
 * scoreboard's first bin at its level is too (the review of 96abcf65: a deadlock storm right after a blocking chain, in one
 * episode with it, was missed). With no known end, an episode is open only as far as its last sample at its level.
 */
function catchesOf(fault: SessionRun, faults: readonly SessionRun[], episodes: readonly Listed[]): Array<{ episode: Listed; at: number }> {
    const scenario = scenarioOf(fault);
    const target = T4_BEATS[scenario]?.target ?? fault.target;
    const from = (fault.windowStart as Date).getTime();
    const fromBin = Math.floor(from / BIN) * BIN;
    const open = (e: Listed) => binOf(e.start) < fromBin && (e.end !== null ? Date.parse(e.end) > from : binOf(e.last) >= fromBin);
    const hits = familiesOf(scenario).flatMap((family) => {
        const to = searchEndOf(fault, family, faults, familiesOf);
        return episodes.filter((e) => e.target === target && e.family === family && (inSearch(binOf(e.start), BIN, from, to) || open(e))).map((episode) => ({ episode, at: Math.max(binOf(episode.start), fromBin) }));
    });
    return hits.sort((a, b) => a.at - b.at || Date.parse(a.episode.start) - Date.parse(b.episode.start));
}

/** The earliest catch of a fault, which gives its time to detect, as the scoreboard's first bin at its level does; or null. */
const catchOf = (fault: SessionRun, faults: readonly SessionRun[], episodes: readonly Listed[]) => catchesOf(fault, faults, episodes)[0] ?? null;

/**
 * The incidents the graded faults explain: every one that catches a fault, not only its earliest (the review of 3c0f5aeb:
 * the chain's incident, still open at a deadlock storm's start, gave the storm its time, and the storm's own incident was
 * then left unexplained, a false alarm). `faults` are all of them in the minutes, for each one's cap at the next.
 */
function explainedBy(graded: readonly SessionRun[], faults: readonly SessionRun[], episodes: readonly Listed[]): Set<string> {
    return new Set(graded.flatMap((f) => catchesOf(f, faults, episodes).map((h) => h.episode.key)));
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
    // Each listed incident's last sample at its level, from the detector's own list for the same minutes.
    const lasts = new Map((await toolsFor(data).episodes(new Date(from), new Date(to))).map((e) => [e.key, e.last.toISOString()]));
    const listed: Listed[] = found.episodes.map((e) => ({ key: e.key, target: e.target, family: e.family, start: e.start, end: e.end, last: lasts.get(e.key) ?? e.start }));
    const name = (r: Run) => `${r.scenario} ${r.target} ${clock(r.start)}`;
    const within = (r: Run) => r.start.getTime() >= Date.parse(from) && r.start.getTime() < Date.parse(to);
    const inMinutes = key.filter(within);
    const faults = inMinutes.map(asFault);
    const notGradable = NOT_GRADABLE[data] ?? {};
    // Each run's earliest catch gives its time to detect; every incident that catches a run is one it explains.
    const caught = explainedBy(faults.filter((_, i) => !notGradable[inMinutes[i].scenario]), faults, listed);
    const runs = inMinutes.map((r, i) => {
        if (notGradable[r.scenario]) return `${name(r)}: not graded (${notGradable[r.scenario]})`;
        if (familiesOf(r.scenario).length === 0) return `${name(r)}: no rule`;
        const c = catchOf(faults[i], faults, listed);
        if (!c) return `${name(r)}: missed`;
        return `${name(r)}: caught by ${c.episode.key} after ${Math.max(0, Date.parse(c.episode.start) - r.start.getTime()) / 1000} s`;
    });
    // The families the key grades: a fixture's key records every run, so all of them; a live key file, its runs' only.
    const graded = new Set(inMinutes.filter((r) => !notGradable[r.scenario]).flatMap((r) => familiesOf(r.scenario).map((f) => `${T4_BEATS[r.scenario]?.target ?? r.target}|${f}`)));
    const complete = data === "t1" || data === "t4";
    const keyless = NO_KEY_ROW[data] ?? {};
    const unexplained = listed.filter((e) => !caught.has(e.key));
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

    /** The detector's episodes in some bins, as the grading lists them. */
    const listedOf = (bins: readonly Bin[]): Listed[] => episodesFromBins(bins).map((e) => ({ key: e.key, target: e.target, family: e.family, start: e.start.toISOString(), end: e.end ? e.end.toISOString() : null, last: e.last.toISOString() }));
    const scoreboardOf = (plan: ReturnType<typeof toPlans>[number], context: Parameters<typeof scorePlan>[1]) => Object.fromEntries(scorePlan(plan, context).map((s) => [s.key.slice(-2), s.status === "Pass" ? s.visibleAt : null]));
    const evaluationOf = (faults: readonly SessionRun[], episodes: readonly Listed[]) => Object.fromEntries(faults.map((f) => [f.requestId.slice(-2), ((c) => (c ? new Date(c.at) : null))(catchOf(f, faults, episodes))]));

    it("catches what the scoreboard sees in the same telemetry, and nothing else: the bin that holds a fault's start, 14 and exactly 15 minutes after its end, the next fault that raises its signal, and a signal already up at its start, a bin early only after a one-bin dip there", () => {
        const pair = [fault("00", "blocking-chain", 0, 10), fault("01", "deadlock-storm", 11, 21)];
        const cases: Array<{ name: string; faults: SessionRun[]; blocked: number[]; expected: Record<string, Date | null>; scoreboard?: Record<string, Date | null> }> = [
            { name: "the bin that holds its start", faults: [fault("00", "blocking-chain", 0.5, 10)], blocked: [0, 1, 2], expected: { "00": at(0) } },
            { name: "14 minutes after its end", faults: [fault("00", "blocking-chain", 0, 10)], blocked: [24], expected: { "00": at(24) } },
            { name: "exactly 15 minutes after its end", faults: [fault("00", "blocking-chain", 0, 10)], blocked: [25], expected: { "00": null } },
            { name: "after the next fault that raises its signal", faults: pair, blocked: [12, 13, 14, 15, 16, 17, 18], expected: { "00": null, "01": at(12) } },
            // The review of 96abcf65: a storm whose blocking runs on from the chain's is in the chain's episode, open at its
            // start, which the set took for nothing.
            { name: "a signal already up at its start", faults: pair, blocked: Array.from({ length: 21 }, (_, i) => i + 1), expected: { "00": at(1), "01": at(11) } },
            // With one bin's dip at the storm's start, the episode runs on across it (two samples under its level end one),
            // and has no values per bin: the set catches the storm at its start's bin, the scoreboard at the bin after the dip.
            { name: "a dip of one bin at its start", faults: pair, blocked: [...Array.from({ length: 10 }, (_, i) => i + 1), ...Array.from({ length: 10 }, (_, i) => i + 12)], expected: { "00": at(1), "01": at(11) }, scoreboard: { "00": at(1), "01": at(12) } },
        ];
        for (const c of cases) {
            const runs = [session, ...c.faults];
            const bins = blockedIn(c.blocked);
            const plan = toPlans(runs).find((p) => p.key === SESSION)!;
            expect(scoreboardOf(plan, { bins, beats: [], runs }), c.name).toEqual(c.scoreboard ?? c.expected);
            expect(evaluationOf(c.faults, listedOf(bins)), c.name).toEqual(c.expected);
        }
    });

    it("counts an episode in the bin that holds its start, and one still open at the fault's start, and reads a scenario's families as the scoreboard does", () => {
        const f = fault("00", "locking-blocking", 0.5, 10);
        const episode = (family: string, start: Date, end: Date | null = null, last = start): Listed => ({ key: `T1-${family}-${start.toISOString()}`, target: "T1", family, start: start.toISOString(), end: end ? end.toISOString() : null, last: last.toISOString() });
        // 13:30:10 is in the bin that holds the fault's start, 13:30:30; 13:29:40 is in the bin before, and over before it.
        expect(catchOf(f, [f], [episode("blocking", new Date(T0 + 10_000))])?.at).toEqual(T0);
        expect(catchOf(f, [f], [episode("blocking", new Date(T0 - 20_000))])).toBeNull();
        expect(catchOf(f, [f], [episode("blocking", at(-5), at(0))])).toBeNull();
        // Recovered right at the fault's start: its first sample back under its level is that instant, so it's not open.
        expect(catchOf(f, [f], [episode("blocking", at(-5), new Date(T0 + 30_000))])).toBeNull();
        // Still open at its start: recovered after it, or with no known end, last at its level in the bin that holds it.
        expect(catchOf(f, [f], [episode("blocking", at(-5), at(1))])?.at).toEqual(T0);
        expect(catchOf(f, [f], [episode("blocking", at(-5), null, at(0))])?.at).toEqual(T0);
        expect(catchOf(f, [f], [episode("blocking", at(-5), null, at(-1))])).toBeNull();
        // Locking and blocking raises blocked processes (the notebook's SCENARIO_SIGNALS): a deadlock alone doesn't catch it.
        expect(catchOf(f, [f], [episode("deadlock", at(2))])).toBeNull();
    });

    // The review of 3c0f5aeb: with the chain's incident still open at a deadlock storm's start, that incident gave the storm
    // its time, as the scoreboard's first bin does, and the storm's own incident from 13:44 was left unexplained, so a key
    // that grades T1's blocking would have called it a false alarm.
    it("explains every incident that catches a fault, not only its earliest: a blocking chain, then a deadlock storm", () => {
        const pair = [fault("00", "blocking-chain", 0, 10), fault("01", "deadlock-storm", 11, 21)];
        // Blocked processes from 13:31 to 13:41, none at 13:42 and 13:43, then again from 13:44 to 13:50.
        const listed = listedOf(blockedIn([...Array.from({ length: 11 }, (_, i) => i + 1), ...Array.from({ length: 7 }, (_, i) => i + 14)]));
        expect(listed.map((e) => [e.key, e.end])).toEqual([
            ["T1-blocking-20261117T133100Z", at(12).toISOString()],
            ["T1-blocking-20261117T134400Z", at(21).toISOString()],
        ]);
        // The earliest catch of each, as the scoreboard times them: the storm's by the chain's incident, open at its start.
        expect(evaluationOf(pair, listed)).toEqual({ "00": at(1), "01": at(11) });
        expect(catchesOf(pair[1], pair, listed).map((h) => h.episode.key)).toEqual(["T1-blocking-20261117T133100Z", "T1-blocking-20261117T134400Z"]);
        // And both incidents are explained: none is a false alarm.
        expect([...explainedBy(pair, pair, listed)].sort()).toEqual(["T1-blocking-20261117T133100Z", "T1-blocking-20261117T134400Z"]);
    });

    // The review of 96abcf65: on the preview's sample session, 7 of its 35 faults graded otherwise than the scoreboard's
    // scorePlan, which reads the same bins. Every one is caught or missed alike now; six are caught a bin apart, each for
    // a reason the set can't read: its episodes have no values per bin, its levels are the notebook's episode levels, not
    // the scoreboard's bounds over their baselines, and it reads no Database Agent beat.
    it("grades the preview's sample session as its scoreboard does: all 35 faults caught or missed alike, and six a bin apart, each for its reason", () => {
        const filters: Filters = { targets: ["T1", "T2", "T3"], window: null };
        const runs = toSessions(sampleRows(sessionsQuery(filters)));
        const plan = toPlans(runs).find((p) => p.key === SESSION_KEY)!;
        const plain = toBins(sampleRows(seriesQuery(filters)));
        const around = { start: new Date(plan.start.getTime() - 30 * MIN), end: new Date(plan.end.getTime() + 45 * MIN) };
        const bins = (["T1", "T2", "T3"] as const).flatMap((t) => withCategoryWaits(plain.filter((b) => b.target === t), toWaitBins(sampleRows(incidentWaitsQuery({ target: t, ...around })))));
        const scoreboard = scoreboardOf(plan, { bins, beats: toAgentBeats(sampleRows(agentLoopQuery(filters))), runs, incidents: toIncidents(sampleRows(incidentsQuery(filters))) });
        const evaluation = evaluationOf(plan.faults, listedOf(bins));
        expect(plan.faults).toHaveLength(35);
        const apart: Record<string, string> = {};
        for (const [id, seen] of Object.entries(scoreboard)) {
            const caught = evaluation[id];
            expect(caught === null, `fault ${id}`).toBe(seen === null);
            if (seen && caught && seen.getTime() !== caught.getTime()) apart[id] = `${(seen.getTime() - caught.getTime()) / MIN} min later on the scoreboard`;
        }
        expect(apart).toEqual({
            // T1's deadlock storms, right after its blocking chains: a dip of one bin at each storm's start.
            "05": "1 min later on the scoreboard",
            "18": "1 min later on the scoreboard",
            "28": "1 min later on the scoreboard",
            // T3's Log Rate Governor waits stay at 0.05 s a minute at rest: over the detector's level, the notebook's (above
            // 0), so the episode is open at the fault's start; under the scoreboard's bound, 1.5 times that baseline.
            "11": "1 min later on the scoreboard",
            "34": "1 min later on the scoreboard",
            // T3's plan regression with the Database Agent beat: the scoreboard looks from the regression, at 14:03, and the
            // set from the window's start, where the missing index's CPU from 14:02 is.
            "13": "1 min later on the scoreboard",
        });
    });
});
