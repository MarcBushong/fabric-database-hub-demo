// Wave 1 (ADR 0030): the scoreboard's times, the business lens's words, the postmortem's Markdown, and the kiosk's
// rotation, each pinned to measured inputs.

import { describe, expect, it } from "vitest";

import type { AgentBeat, Bin, CosmosCapture, Incident, PostgresCapture, SessionRun } from "@/data/model";
import type { Row } from "@/data/query-client";
import { sessionsQuery } from "@/data/queries";
import { impactOf, SERVICES, serviceOf } from "@/lib/business";
import { postgresHealth } from "@/lib/health";
import { buildPostmortem, postmortemAsk, postmortemFileName } from "@/lib/postmortem";
import {
    aggregate,
    cosmosEpisodes,
    detectionBound,
    howMeasured,
    minutesText,
    nextInjection,
    planEvents,
    postgresEpisodes,
    scorePlan,
    stateAt,
    summarize,
    toPlans,
    type FaultScore,
} from "@/lib/scoreboard";
import { ESTATE_TARGETS } from "@/lib/view-state";
import { mapNodes } from "@/mission/nodes";

const T0 = Date.UTC(2026, 10, 17, 13, 30);
const at = (minute: number) => new Date(T0 + minute * 60000);

/** One-minute bins from 13:30 to 15:30 UTC: a calm baseline, with what each test sets on top. */
function bins(target: "T1" | "T2" | "T3", set: (minute: number) => Partial<Bin> = () => ({})): Bin[] {
    return Array.from({ length: 121 }, (_, m) => ({
        at: at(m),
        target,
        cpu: 20,
        blocked: 0,
        lockWaitS: 0.1,
        bufferIoS: 0.5,
        logRateS: 0,
        waitS: 12,
        ioMb: 100,
        batch: 1000,
        sessions: 6,
        ...set(m),
    }));
}

const run = (requestId: string, target: string, profile: string, from: number, to: number, status = "Pass"): SessionRun => ({
    requestId,
    requestedAt: at(from),
    target,
    profile,
    durationMin: to - from,
    status,
    message: "",
    windowStart: at(from),
    windowEnd: at(to),
    dispatch: "session",
});

const SESSION = "session:7f3a9c21-1111-2222-3333-444444444444";
const RUNS: SessionRun[] = [
    run(SESSION, "all", "session", 0, 90),
    run(`${SESSION}:00`, "T1", "incident:blocking-chain", 0, 10),
    run(`${SESSION}:01`, "T2", "incident:memory-grant-pressure", 10, 18),
    run(`${SESSION}:02`, "T3", "incident:plan-regression", 30, 60),
    run(`${SESSION}:03`, "T2", "incident:io-pressure", 40, 48),
    run("r9", "T1", "incident:cpu-pressure", -1440, -1430),
    run("r10", "T2", "incident:healthy-baseline", 0, 90),
    run("r11", "T3", "incident:log-rate-pressure", -2000, -1990, "Fail"),
];

const BEAT: AgentBeat = {
    id: `database_agent.T3.${SESSION}:02`,
    target: "T3",
    status: "Pass",
    text: "",
    requestId: `${SESSION}:02`,
    windowStart: at(30),
    windowEnd: at(60),
    regressAt: at(33),
    respondAt: at(56),
    cpuBefore: 84,
    cpuAfter: 22,
};

const BINS: Bin[] = [
    ...bins("T1", (m) => (m >= 2 && m < 10 ? { blocked: 6 } : {})),
    ...bins("T2", (m) => ({ waits: { Memory: m >= 11 && m < 18 ? 30 : 0.2, CPU: 4 } })),
    ...bins("T3", (m) => (m >= 34 && m <= 56 ? { cpu: 85 } : {})),
];

function scored(): FaultScore[] {
    const [plan] = toPlans(RUNS);
    return scorePlan(plan, { bins: BINS, beats: [BEAT], runs: RUNS });
}

describe("the business lens", () => {
    it("maps every target to one ContosoCare service, from the story", () => {
        expect(ESTATE_TARGETS.every((t) => SERVICES[t].service.length > 0)).toBe(true);
        expect(serviceOf("T3")?.service).toBe("Scheduling");
        expect(serviceOf("T5")?.service).toBe("Patient events");
        expect(serviceOf("T9")).toBeNull();
    });

    it("puts the business words next to the measured signal they come from, and invents no figure", () => {
        expect(impactOf({ target: "T5", family: "throttle", durationMin: 10, peak: 100, throttled: 520, requests: 1000 }).sentence).toBe(
            "Patient events: 52 % of requests throttled for 10 min (normalized RU 100.0 %, 429s on 520 of 1,000 requests)",
        );
        expect(impactOf({ target: "T3", family: "cpu", durationMin: 23, peak: 85, baseline: 20 }).sentence).toBe("Scheduling: under heavy load for 23 min (CPU peak 85.0 %, 4.3 times its baseline)");
        expect(impactOf({ target: "T4-replica", family: "replica_lag", durationMin: 10, peak: 241.4 }).sentence).toBe("Reports' DR copy: 4.0 min behind its primary for 10 min (read replica lag peak 241 s)");
        expect(impactOf({ target: "T1", family: "blocking", durationMin: 8, ongoing: true, peak: 6, baseline: 0 }).sentence).toBe("Billing: work blocked behind other work for at least 8 min (up to 6 blocked processes)");
        // Nothing measured, nothing said: no duration, no number, no latency.
        const bare = impactOf({ target: "T2", family: "io", durationMin: null, peak: null });
        expect(bare.sentence).toBe("Front desk: waiting on storage (Buffer IO waits)");
        expect(bare.sentence).not.toMatch(/\d|latency|slow/i);
    });

    it("writes a blocked-process peak that isn't whole with its decimals, never rounded to a whole count", () => {
        // A bin's value is its highest sample: never "up to 7" for 6.6, or "up to 0" for 0.4.
        expect(impactOf({ target: "T1", family: "blocking", durationMin: 8, peak: 6.6, baseline: 0 }).evidence).toBe("up to 6.6 blocked processes");
        expect(impactOf({ target: "T1", family: "blocking", durationMin: 8, peak: 0.4, baseline: 0.3 }).sentence).toBe("Billing: work blocked behind other work for 8 min (up to 0.4 blocked processes, 1.3 times its baseline)");
        expect(impactOf({ target: "T1", family: "blocking", durationMin: 3, peak: 1, baseline: 0 }).evidence).toBe("up to 1 blocked process");
        // Through the scoreboard: a fault whose bins reach 0.6 blocked processes, over a baseline of 0.3, and its postmortem.
        const runs = [run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T1", "incident:blocking-chain", 30, 40)];
        const plan = toPlans(runs)[0];
        const [score] = scorePlan(plan, { bins: bins("T1", (m) => ({ blocked: m >= 31 && m <= 38 ? 0.6 : 0.3 })), beats: [], runs });
        expect(score.status).toBe("Pass");
        expect(score.impact?.evidence).toBe("up to 0.6 blocked processes, 2.0 times its baseline");
        const { markdown } = buildPostmortem({ plan, scores: [score], episodes: [], beat: null, asOf: null, provenance: "history", specs: [], generatedAt: at(130) });
        expect(markdown).toContain("| up to 0.6 blocked processes, 2.0 times its baseline |");
    });
});

describe("the scoreboard", () => {
    it("groups the faults under their session, newest first, and leaves out the baseline and failed requests", () => {
        const plans = toPlans(RUNS);
        expect(plans.map((p) => `${p.kind}:${p.label}:${p.faults.length}`)).toEqual(["session:Session 7f3a9c21:4", "request:CPU pressure on T1:1"]);
        expect(plans[0].faults.map((f) => f.requestId.slice(-2))).toEqual(["00", "01", "02", "03"]);
    });

    it("sets the detection bound from the notebook's rules: CPU's 1.5 times and 10 points, or its 80 % episode level", () => {
        expect(detectionBound("cpu", 20)).toMatchObject({ value: 30, minBins: 2 });
        expect(detectionBound("cpu", 60)).toMatchObject({ value: 80 });
        expect(detectionBound("cpu", null)).toMatchObject({ value: 80 });
        expect(detectionBound("blocking", 0)).toMatchObject({ value: 0, strict: true, minBins: 1 });
        expect(detectionBound("io", 2)).toMatchObject({ value: 3, strict: false });
        expect(detectionBound("memory", 0.2)).toMatchObject({ value: 5, minBins: 2 });
        expect(detectionBound("activity", 1)).toBeNull();
    });

    it("measures when each injected fault's signal showed, when it was answered, and when it recovered", () => {
        const [blocking, memory, plan, io] = scored();
        // T1: blocked processes from 13:32; back to 0 at 13:40.
        expect(blocking).toMatchObject({ status: "Pass", signal: "blocked processes", ttdMin: 2, ttrMin: 10, visibleMin: 8, answeredAt: null });
        expect(blocking.visibleAt).toEqual(at(2));
        expect(blocking.recoveredAt).toEqual(at(10));
        // T2: a wait category, read from the bins' categories at the notebook's 5 s per bin.
        expect(memory).toMatchObject({ status: "Pass", family: "memory", ttdMin: 1, ttrMin: 8 });
        // T3: injected when the plan regressed (13:63 = 14:03), visible at 14:04, answered at 14:26, recovered at 14:27.
        expect(plan.injectedAt).toEqual(at(33));
        expect(plan).toMatchObject({ status: "Pass", baseline: 20, ttdMin: 1, ttrMin: 24, visibleMin: 23, peak: 85 });
        expect(plan.bound).toMatchObject({ value: 30 });
        expect(plan.answeredAt).toEqual(at(56));
        expect(plan.answer).toMatch(/last good plan/);
        expect(plan.impact?.sentence).toBe("Scheduling: under heavy load for 23 min (CPU peak 85.0 %, 4.3 times its baseline)");
        // T2's IO pressure never reached 1 s of Buffer IO waits per bin: not visible, and said why, with what it measured.
        expect(io).toMatchObject({ status: "Warning", visibleAt: null, ttdMin: null, impact: null });
        expect(io.note).toBe("Not visible: Buffer IO (PAGEIOLATCH) waits stayed under 1.0 s until 14:33 UTC, 15 minutes after its window; its peak was 0.5 s at 14:10 UTC.");
    });

    it("says what a fault's signal measured when it wasn't visible, never that it stayed under a level a bin reached (F23)", () => {
        const runs = [run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T1", "incident:cpu-pressure", 30, 40)];
        const plan = toPlans(runs)[0];
        const note = (b: Bin[]) => {
            const [score] = scorePlan(plan, { bins: b, beats: [], runs });
            expect(score.status).toBe("Warning");
            return score.note;
        };
        // CPU's baseline is 20 %, so its level is 30 %, for 2 bins in a row; one bin rises, at 14:03 in 1-minute bins or 14:05 in 5-minute ones.
        const oneMinute = (cpu: number) => bins("T1", (m) => (m === 33 ? { cpu } : {}));
        const fiveMinute = (cpu: number) => Array.from({ length: 25 }, (_, i): Bin => ({ ...bins("T1")[0], at: at(i * 5), cpu: i === 7 ? cpu : 20 }));
        // Over its level in one bin, short of its rule's two in a row: what it reached, never "stayed under".
        expect(note(oneMinute(66))).toBe("Not visible by its rule: CPU reached 30.0 % or more in 1 bin, never 2 in a row, until 14:25 UTC, 15 minutes after its window; its peak was 66.0 % at 14:03 UTC.");
        expect(note(fiveMinute(66))).toBe("Not visible by its rule: CPU reached 30.0 % or more in 1 bin, never 2 in a row, until 14:25 UTC, 15 minutes after its window; its peak was 66.0 % at 14:05 UTC.");
        // Under its level throughout: "stayed under", with the peak it measured.
        expect(note(oneMinute(25))).toBe("Not visible: CPU stayed under 30.0 % until 14:25 UTC, 15 minutes after its window; its peak was 25.0 % at 14:03 UTC.");
        expect(note(fiveMinute(25))).toBe("Not visible: CPU stayed under 30.0 % until 14:25 UTC, 15 minutes after its window; its peak was 25.0 % at 14:05 UTC.");
        // As found live: a baseline near 0 % (a level of 10 %), bins at 65.95 %, and bins without a CPU value between them.
        const sparse = bins("T1", (m) => ({ cpu: m >= 30 && m < 40 ? (m % 3 === 0 ? 65.95 : null) : 0 }));
        expect(note(sparse)).toBe(
            "Not visible by its rule: CPU reached 10.0 % or more in 4 bins, never 2 in a row (6 of its 25 bins had no value), until 14:25 UTC, 15 minutes after its window; its peak was 66.0 % at 14:00 UTC.",
        );
    });

    it("says a signal was still visible at the telemetry's end only when its last bin was, and when it went back under too late to confirm (F23)", () => {
        const runs = [run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T1", "incident:cpu-pressure", 30, 40)];
        const plan = toPlans(runs)[0];
        // CPU at 90 % from 14:01 to 14:08; the telemetry ends with one bin back under it, at 14:09.
        const ending = bins("T1", (m) => (m >= 31 && m <= 38 ? { cpu: 90 } : {})).filter((b) => b.at < at(40));
        const [under] = scorePlan(plan, { bins: ending, beats: [], runs });
        expect(under).toMatchObject({ status: "Pass", recoveredAt: null, ongoing: false, visibleMin: 8, recoveryWord: "Unconfirmed" });
        expect(under.recoveryNote).toBe("Back under its bound at 14:09 UTC, but its telemetry ends before 2 bins in a row under it.");
        expect(under.impact?.sentence).toBe("Billing: under heavy load for 8 min (CPU peak 90.0 %, 4.5 times its baseline)");
        // Its last bin still at the level: still visible, for at least the time it was.
        const [still] = scorePlan(plan, { bins: ending.filter((b) => b.at < at(39)), beats: [], runs });
        expect(still).toMatchObject({ ongoing: true, recoveryWord: "Still visible", recoveryNote: "Still visible when the telemetry ends." });
    });

    it("never writes a peak equal to the level it stayed under: more decimals, or 'just under' (the review of F23)", () => {
        const note = (profile: string, b: Bin[]) => {
            const runs = [run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T1", profile, 30, 40)];
            const [score] = scorePlan(toPlans(runs)[0], { bins: b, beats: [], runs });
            // The detection is unchanged: not visible, a Warning.
            expect(score.status).toBe("Warning");
            return score.note;
        };
        const until = "until 14:25 UTC, 15 minutes after its window";
        // Buffer IO waits' level is the notebook's 1 s (their baseline is 0.5 s): a bin at 0.96 s, which one decimal writes as 1.0 s.
        expect(note("incident:io-pressure", bins("T1", (m) => (m === 33 ? { bufferIoS: 0.96 } : {})))).toBe(`Not visible: Buffer IO (PAGEIOLATCH) waits stayed under 1.0 s ${until}; its peak was 0.96 s at 14:03 UTC.`);
        // CPU's level is 30 % (a baseline of 20 %): a bin at 29.97 %.
        expect(note("incident:cpu-pressure", bins("T1", (m) => (m === 33 ? { cpu: 29.97 } : {})))).toBe(`Not visible: CPU stayed under 30.0 % ${until}; its peak was 29.97 % at 14:03 UTC.`);
        // Alike even at 4 decimals: "just under", with no number for the peak.
        expect(note("incident:io-pressure", bins("T1", (m) => (m === 33 ? { bufferIoS: 0.99999 } : {})))).toBe(`Not visible: Buffer IO (PAGEIOLATCH) waits stayed under 1.0 s ${until}; its peak, at 14:03 UTC, was just under it.`);
        // Apart at one decimal: as before.
        expect(note("incident:io-pressure", bins("T1", (m) => (m === 33 ? { bufferIoS: 0.9 } : {})))).toBe(`Not visible: Buffer IO (PAGEIOLATCH) waits stayed under 1.0 s ${until}; its peak was 0.9 s at 14:03 UTC.`);
        // A strict bound, the notebook's floor of 0, reads "at or under", which a peak of 0 is.
        expect(note("incident:blocking-chain", bins("T1"))).toBe(`Not visible: blocked processes stayed at or under 0 ${until}; its peak was 0 at 14:00 UTC.`);
    });

    it("writes a level that isn't whole with its decimals, in the note, the scoreboard's column, and the postmortem's table, never 'at least 0' (the review of F23)", () => {
        const runs = [run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T1", "incident:blocking-chain", 30, 40)];
        const plan = toPlans(runs)[0];
        // Blocked processes average 0.3 per bin outside the fault, so its level is 1.5 times that, 0.45.
        const score = (during: number) => scorePlan(plan, { bins: bins("T1", (m) => ({ blocked: m >= 31 && m <= 38 ? during : 0.3 })), beats: [], runs })[0];
        const visible = score(2);
        expect(visible.status).toBe("Pass");
        expect(visible.note).toBe("Visible: blocked processes at least 0.45 (1.5 times its baseline of 0.3).");
        expect(howMeasured(visible)).toBe("at least 0.45 (baseline 0.3)");
        const { markdown } = buildPostmortem({ plan, scores: [visible], episodes: [], beat: null, asOf: null, provenance: "history", specs: [], generatedAt: at(130) });
        expect(markdown).toContain("| Deep blocking chain and lock escalation | T1 | blocked processes | at least 0.45 (1.5 times its baseline of 0.3) |");
        // Under its level: the same level, and the peak with its decimals.
        const under = score(0.4);
        expect(under.status).toBe("Warning");
        expect(howMeasured(under)).toBe("at least 0.45 (baseline 0.3). Not visible: blocked processes stayed under 0.45 until 14:25 UTC, 15 minutes after its window; its peak was 0.4 at 14:01 UTC.");
        expect([visible.note, howMeasured(visible), markdown, howMeasured(under)].join("\n")).not.toMatch(/at least 0(?![.\d])|under 0(?![.\d])/);
    });

    it("says the telemetry breaks off, never that it ends, when a hole follows a signal's last bin at its level, and ends its visible time there (the review of F23)", () => {
        const runs = [run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T1", "incident:cpu-pressure", 30, 40)];
        const plan = toPlans(runs)[0];
        const hot = (m: number) => m >= 31 && m <= 38;
        // CPU at 90 % from 14:01 to 14:08, no value at 14:09, then 20 % to 15:30; or no bin at all at 14:09 and 14:10.
        const noValue = bins("T1", (m) => (hot(m) ? { cpu: 90 } : m === 39 ? { cpu: null } : {}));
        const gap = bins("T1", (m) => (hot(m) ? { cpu: 90 } : {})).filter((b) => b.at < at(39) || b.at >= at(41));
        for (const shape of [noValue, gap]) {
            const [score] = scorePlan(plan, { bins: shape, beats: [], runs });
            // The detection is unchanged: visible at 14:01, a minute after its injection, and no recovery time.
            expect(score).toMatchObject({ status: "Pass", ttdMin: 1, recoveredAt: null, ttrMin: null });
            expect(score.visibleAt).toEqual(at(31));
            expect(summarize([score])).toMatchObject({ faults: 1, visible: 1, notVisible: 0, recovered: 0 });
            // What it says: its telemetry breaks off after 14:08, and it was visible until then, at least.
            expect(score).toMatchObject({ ongoing: false, visibleMin: 8, recoveryWord: "Telemetry breaks off" });
            expect(score.recoveryNote).toBe("Its telemetry breaks off after 14:08 UTC, its last bin at its bound, so its recovery isn't measured.");
            expect(score.impact?.sentence).toBe("Billing: under heavy load for at least 8 min (CPU peak 90.0 %, 4.5 times its baseline)");
            // The postmortem's follow-up says the same, never that it hadn't recovered when the telemetry ends.
            const { markdown } = buildPostmortem({ plan, scores: [score], episodes: [], beat: null, asOf: null, provenance: "history", specs: [], generatedAt: at(130) });
            expect(markdown).toContain("- **CPU pressure on T1 has no recovery time:** Its telemetry breaks off after 14:08 UTC, its last bin at its bound, so its recovery isn't measured.");
            expect(markdown).not.toContain("when the telemetry ends");
        }
    });

    it("shares a signal between faults that raise it at once, keeps the agent's response to its own beat, and reads a deadlock as blocking", () => {
        const runs = [
            run(SESSION, "all", "session", 0, 90),
            run(`${SESSION}:00`, "T1", "incident:blocking-chain", 0, 10),
            run(`${SESSION}:01`, "T1", "incident:deadlock-storm", 11, 21),
            run(`${SESSION}:02`, "T3", "incident:plan-regression", 30, 60),
            run(`${SESSION}:03`, "T3", "incident:missing-index", 31, 40),
        ];
        const bins3 = [...bins("T1", (m) => (m >= 1 && m < 11) || (m >= 12 && m < 22) ? { blocked: 5 } : {}), ...bins("T3", (m) => (m >= 32 && m <= 56 ? { cpu: 85 } : {}))];
        const [blocking, deadlock, plan, missing] = scorePlan(toPlans(runs)[0], { bins: bins3, beats: [BEAT], runs });
        // Back to back on the same signal: the chain's recovery can't be told apart from the storm that follows it.
        expect(blocking).toMatchObject({ status: "Pass", recoveredAt: null, ongoing: false });
        expect(blocking.note).toMatch(/The next fault with this signal began first\.$/);
        expect(blocking.recoveryNote).toBe("The next fault with this signal began first.");
        expect(blocking.recoveryWord).toBe("Next fault first");
        // The storm reads blocked processes, and recovers once nothing raises them.
        expect(deadlock).toMatchObject({ status: "Pass", signal: "blocked processes (deadlocks)", ttdMin: 1, ttrMin: 11 });
        // The missing index runs inside the agent's beat: both see T3's CPU, but only the beat has the agent's response.
        expect(plan).toMatchObject({ status: "Pass", ttdMin: 0 });
        expect(plan.answeredAt).toEqual(at(56));
        expect(missing).toMatchObject({ status: "Pass", answeredAt: null, ttdMin: 1 });
        expect(missing.injectedAt).toEqual(at(31));
    });

    it("reads each fault in its own bins' step, beside a session the history keeps in another bin size", () => {
        // A later session of 170 minutes, which the notebook saves in 5-minute bins, beside the 1-minute one above.
        const LONG = "session:b2c3d4e5-1111-1111-1111-111111111111";
        const fiveMinute: Bin[] = Array.from({ length: 37 }, (_, i) => {
            const m = 150 + i * 5;
            return { ...bins("T1")[0], at: at(m), cpu: m >= 210 && m <= 220 ? 95 : 20, blocked: m === 270 ? 4 : 0, bufferIoS: m === 175 || m === 180 ? 8 : 2.5 };
        });
        const runs = [
            ...RUNS,
            run(LONG, "all", "session", 155, 325),
            run(`${LONG}:00`, "T1", "incident:io-pressure", 170, 185),
            run(`${LONG}:01`, "T1", "incident:cpu-pressure", 210, 225),
            run(`${LONG}:02`, "T1", "incident:blocking-chain", 270, 275),
        ];
        const plan = toPlans(runs).find((p) => p.key === LONG);
        const scores = plan ? scorePlan(plan, { bins: [...BINS, ...fiveMinute], beats: [], runs }) : [];
        const [io, cpu, blocking] = [":00", ":01", ":02"].map((n) => scores.find((s) => s.key === `${LONG}${n}`));
        // Its baseline comes from bins of its own size (2.5 s of Buffer IO waits per 5 minutes), not the 0.5 s of 1-minute ones.
        expect(io).toMatchObject({ status: "Pass", binMinutes: 5, baseline: 2.5 });
        expect(io?.visibleAt).toEqual(at(175));
        // Two 5-minute bins in a row at 95 % meet CPU's two-bin rule, and two under it make the recovery.
        expect(cpu).toMatchObject({ status: "Pass", binMinutes: 5, ttdMin: 0, ttrMin: 15, peak: 95 });
        // A one-bin rule recovers at the next 5-minute bin, not "still visible" for want of a 1-minute one.
        expect(blocking).toMatchObject({ status: "Pass", ttdMin: 0, ttrMin: 5, ongoing: false, recoveryWord: "" });
    });

    it("says when no telemetry covers a fault, and when its target's signal isn't measured", () => {
        const [lone] = toPlans(RUNS).slice(1);
        const [score] = scorePlan(lone, { bins: BINS, beats: [], runs: RUNS });
        expect(score).toMatchObject({ status: "Warning", visibleAt: null });
        expect(score.note).toMatch(/^No telemetry from T1 covers it/);
        const [noCategories] = scorePlan(toPlans(RUNS)[0], { bins: BINS.map((b) => ({ ...b, waits: undefined })), beats: [], runs: RUNS }).filter((s) => s.target === "T2");
        expect(noCategories.status).toBe("Not supported");
    });

    it("summarizes a session and aggregates the times per engine and per fault type, with how many each median rests on", () => {
        const scores = scored();
        expect(summarize(scores)).toMatchObject({ faults: 4, visible: 3, notVisible: 1, answered: 1, recovered: 3, ttdMedian: 1, ttrMedian: 10 });
        const engines = aggregate(scores, "engine");
        expect(engines.map((e) => `${e.label}: ${e.visible}/${e.faults}, TTD ${e.ttdMedian} (${e.ttdN}), TTR ${e.ttrMedian} (${e.ttrN})`)).toEqual([
            "SQL Server: 2/3, TTD 1.5 (2), TTR 9 (2)",
            "Azure SQL Database: 1/1, TTD 1 (1), TTR 24 (1)",
        ]);
        expect(aggregate(scores, "type").map((a) => a.label)).toContain("Plan regression (automatic plan correction)");
    });

    it("orders the plan's moments, counts down to the next injection, and knows each target's state at a moment", () => {
        const scores = scored();
        const t3 = planEvents(scores).filter((e) => e.target === "T3");
        expect(t3.map((e) => `${e.kind} ${e.at.toISOString().slice(11, 16)}`)).toEqual(["injected 14:03", "visible 14:04", "answered 14:26", "recovered 14:27"]);
        const next = nextInjection(scores, at(28));
        expect(next?.score.title).toBe("Plan regression (automatic plan correction)");
        expect(next?.inMin).toBe(5);
        expect(nextInjection(scores, at(80))).toBeNull();
        expect([stateAt(scores, [], "T3", at(33.5)), stateAt(scores, [], "T3", at(40)), stateAt(scores, [], "T3", at(56.5)), stateAt(scores, [], "T3", at(58))]).toEqual(["injected", "visible", "answered", "calm"]);
        expect(minutesText(0.4, 1)).toBe("≤ 1 min");
        expect(minutesText(24)).toBe("24 min");
        expect(minutesText(null)).toBe("–");
    });

    it("reads T5's throttling episodes from the notebook's findings, and T4's replica lag from its metrics", () => {
        const findings: Row[] = [
            {
                FindingId: "cosmosdb.T5.throttle.20261117T1405",
                WindowStart: "2026-11-17T14:05:00",
                WindowEnd: "2026-11-17T14:14:00",
                Evidence: JSON.stringify({ throttled: 520, requests: 1000, peakNormalizedRuPercent: 100, stopped: true, recoveredAtUtc: "2026-11-17T14:15:00Z" }),
            },
            { FindingId: "cosmosdb.T5.recovery", WindowStart: "2026-11-17T14:14:00", WindowEnd: "2026-11-17T15:00:00", Evidence: "{}" },
        ];
        const [storm] = cosmosEpisodes(null, findings);
        expect(storm).toMatchObject({ target: "T5", visibleMin: 10, ongoing: false });
        expect(storm.impact.sentence).toBe("Patient events: 52 % of requests throttled for 10 min (normalized RU 100.0 %, 429s on 520 of 1,000 requests)");
        // Without the findings, the capture's own throttled intervals.
        const capture: CosmosCapture = {
            account: "cosmos01-test",
            capturedAt: null,
            windowStart: at(0),
            windowEnd: at(6),
            intervalMinutes: 1,
            points: [
                ...[10, 100, 100, 30, 12, 11].map((value, m) => ({ at: at(m), metric: "NormalizedRUConsumption", value })),
                ...[0, 400, 380, 0, 0, 0].map((value, m) => ({ at: at(m), metric: "ThrottledRequests", value })),
                ...[300, 1000, 1000, 900, 300, 300].map((value, m) => ({ at: at(m), metric: "TotalRequests", value })),
            ],
        };
        const [fromSeries] = cosmosEpisodes(capture, []);
        expect(fromSeries).toMatchObject({ throttled: 780, requests: 2000, visibleMin: 2, peak: 100 });
        const pg: PostgresCapture = {
            capturedAt: null,
            windowStart: at(0),
            windowEnd: at(25),
            intervalMinutes: 5,
            servers: {},
            points: [6, 241.4, 80, 30, 2].map((value, i) => ({ at: at(i * 5), target: "T4-replica" as const, server: "pgreplica01-test", metric: "physical_replication_delay_in_seconds", value })),
        };
        const [lag] = postgresEpisodes(pg);
        expect(lag).toMatchObject({ target: "T4-replica", family: "replica_lag", peak: 241.4, visibleMin: 10, ongoing: false });
        expect(lag.recoveredAt).toEqual(at(15));
    });

    it("calls an episode recovered only when its recovery was measured: T5's 429s that only stopped, T4's metrics that break off", () => {
        const [stopped] = cosmosEpisodes(null, [
            { FindingId: "cosmosdb.T5.throttle.20261117T1405", WindowStart: "2026-11-17T14:05:00", WindowEnd: "2026-11-17T14:14:00", Evidence: JSON.stringify({ throttled: 520, requests: 1000, peakNormalizedRuPercent: 100, stopped: true }) },
        ]);
        expect(stopped).toMatchObject({ recoveredAt: null, ongoing: false, visibleMin: 9, note: "The 429s stopped; its recovery isn't in the capture." });
        expect(stopped.endAt).toEqual(new Date("2026-11-17T14:14:00Z"));
        // T4's CPU at 85 to 90 % and its replica's lag at 120 s or more, then an interval missing from the capture, then calm.
        const series = (target: "T4" | "T4-replica", server: string, metric: string, values: Array<number | null>) =>
            values.flatMap((value, i) => (value === null ? [] : [{ at: at(i * 5), target, server, metric, value }]));
        const pg: PostgresCapture = {
            capturedAt: null,
            windowStart: at(0),
            windowEnd: at(35),
            intervalMinutes: 5,
            servers: {},
            points: [
                ...series("T4", "pg01-test", "cpu_percent", [20, 85, 90, 88, null, 20, 20]),
                ...series("T4-replica", "pgreplica01-test", "physical_replication_delay_in_seconds", [5, 120, 130, null, 4, 3, 2]),
            ],
        };
        const episodes = postgresEpisodes(pg);
        const cpu = episodes.find((e) => e.family === "cpu");
        const lag = episodes.find((e) => e.family === "replica_lag");
        // Each ends at its last point plus one interval, with no recovery known: not "still at 80 % at the capture's end".
        expect(cpu).toMatchObject({ recoveredAt: null, ongoing: false, visibleMin: 15, note: "Its metrics break off after 13:45 UTC, so its recovery isn't in the capture." });
        expect(cpu?.endAt).toEqual(at(20));
        expect(lag).toMatchObject({ recoveredAt: null, ongoing: false, visibleMin: 10 });
        expect(lag?.endAt).toEqual(at(15));
    });
});

describe("the service map's nodes", () => {
    it("gives the DR copy its status from the capture's read replica lag, and No data without a lag series", () => {
        const capture = (lag: number[]): PostgresCapture => ({
            capturedAt: at(40),
            windowStart: at(0),
            windowEnd: at(25),
            intervalMinutes: 5,
            servers: {},
            points: [
                ...[30, 40, 35, 30, 30].map((value, i) => ({ at: at(i * 5), target: "T4" as const, server: "pg01-test", metric: "cpu_percent", value })),
                ...lag.map((value, i) => ({ at: at(i * 5), target: "T4-replica" as const, server: "pgreplica01-test", metric: "physical_replication_delay_in_seconds", value })),
            ],
        });
        const dr = (pg: PostgresCapture) => mapNodes([postgresHealth(pg, [])], [], [], pg).find((n) => n.target === "T4-replica");
        expect(dr(capture([]))?.status).toBeNull();
        expect(dr(capture([6, 241.4, 80, 30, 2]))?.status).toBe("Warning");
        expect(dr(capture([2, 3, 4, 3, 2]))?.status).toBe("Pass");
    });
});
describe("the postmortem", () => {
    const plan = toPlans(RUNS)[0];
    const input = {
        plan,
        scores: scored(),
        episodes: [],
        beat: BEAT,
        asOf: at(96),
        provenance: "history" as const,
        specs: [sessionsQuery({ targets: ["T1", "T2", "T3"], window: null })],
        generatedAt: new Date(Date.UTC(2026, 10, 18, 9, 5)),
    };

    it("writes the session's postmortem in Markdown from the data alone, with every query behind it", () => {
        const { title, fileName, markdown } = buildPostmortem(input);
        expect(title).toBe("Postmortem: ContosoCare session 7f3a9c21");
        expect(fileName).toBe("contosocare-postmortem-7f3a9c21-20261118T0905Z.md");
        const sections = markdown.split("\n").filter((l) => l.startsWith("## "));
        expect(sections).toEqual(["## Summary", "## Timeline (UTC)", "## Impact on ContosoCare", "## Cause", "## Response", "## Times to signal and recover", "## Follow-ups", "## How this was measured", "## Queries"]);
        expect(markdown).toContain("- 4 faults injected by the demo's session control on T1, T2, T3 (Scenario Runs); 3 had their signal visible in the telemetry, 1 didn't.");
        expect(markdown).toContain("- Median time to signal: 1 min. Median time to recover: 10 min.");
        expect(markdown).toContain("- The Database Agent loop on T3: the plan regressed at 14:03 UTC, and the run forced the last good plan at 14:26 UTC; T3's CPU fell from 84.0 % to 22.0 %.");
        expect(markdown).toContain("| Scheduling | T3 | under heavy load for 23 min | CPU peak 85.0 %, 4.3 times its baseline |");
        expect(markdown).toContain("| 14:26 | T3 | Answered | The run forced the last good plan (Query Store), the documented response |");
        expect(markdown).toContain("| Plan regression (automatic plan correction) | T3 | 14:03 | 14:04 | 1 min | 14:26 | 14:27 | 24 min | Pass |");
        expect(markdown).toContain("| Deep blocking chain and lock escalation | T1 | 13:30 | 13:32 | 2 min | – | 13:40 | 10 min | Pass |");
        expect(markdown).toContain("**IO pressure on T2 wasn't visible:**");
        expect(markdown).toContain("```dax\n// Sessions and activity requests\nEVALUATE");
        expect(markdown).not.toMatch(/Database Hub (detected|saw it)/);
        expect(postmortemFileName({ ...plan, kind: "request", key: "r9/../x" }, input.generatedAt)).toBe("contosocare-postmortem-r9-x-20261118T0905Z.md");
    });

    it("says every signal recovered only when each one has a recovery time, and lists the ones that don't", () => {
        const recovered = buildPostmortem({ ...input, scores: input.scores.slice(0, 2), beat: null });
        expect(recovered.markdown).toContain("- None from the data: every signal showed and recovered.");
        const runs = [run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T1", "incident:blocking-chain", 0, 10), run(`${SESSION}:01`, "T1", "incident:deadlock-storm", 11, 21)];
        const t1 = bins("T1", (m) => ((m >= 1 && m < 11) || (m >= 12 && m < 22) ? { blocked: 5 } : {}));
        const scores = scorePlan(toPlans(runs)[0], { bins: t1, beats: [], runs });
        const cpu = [20, 85, 90, 88, null, 20].flatMap((value, i) => (value === null ? [] : [{ at: at(i * 5), target: "T4" as const, server: "pg01-test", metric: "cpu_percent", value }]));
        const pg: PostgresCapture = { capturedAt: null, windowStart: at(0), windowEnd: at(30), intervalMinutes: 5, servers: {}, points: cpu };
        const { markdown } = buildPostmortem({ ...input, scores, episodes: postgresEpisodes(pg), beat: null });
        expect(markdown).not.toContain("every signal showed and recovered");
        expect(markdown).toContain("- **Deep blocking chain and lock escalation on T1 has no recovery time:** The next fault with this signal began first.");
        expect(markdown).toContain("- **Reporting (T4), CPU from 13:35 UTC, has no recovery time:** Its metrics break off after 13:45 UTC, so its recovery isn't in the capture.");
        expect(buildPostmortem({ ...input, plan: { ...plan, faults: [] }, scores: [], episodes: [], beat: null }).markdown).toContain("- None from the data: nothing was injected or measured in this window.");
    });

    it("reads what was injected from the plan: faults the telemetry couldn't score are not measured, never 'nothing was injected'", () => {
        const unscored = { ...input, scores: [], episodes: [], beat: null };
        const { markdown } = buildPostmortem(unscored);
        expect(markdown).not.toMatch(/No fault was injected|Nothing was injected|nothing was injected/);
        expect(markdown).toContain("- 4 faults injected by the demo's session control on T1, T2, T3 (Scenario Runs) aren't measured here: the telemetry didn't load.");
        expect(markdown).toContain("| 13:30 | T1 | Injected | Deep blocking chain and lock escalation on T1 (not measured) |");
        expect(markdown).toContain("- **Deep blocking chain and lock escalation** on T1 (Billing), 13:30 to 13:40 UTC.");
        expect(markdown).toContain("- **The telemetry didn't load, so its 4 faults aren't measured:** select Retry on the page, then write the postmortem again.");
        // Copilot gets the same faults, each marked not measured, rather than no rows at all.
        const ctx = postmortemAsk(unscored);
        expect(ctx.totalRows).toBe(4);
        expect(ctx.rows?.[0]).toMatchObject({ target: "T1", fault: "Deep blocking chain and lock escalation", visible: null, evidence: "Not measured: the telemetry didn't load." });
    });

    it("hands Copilot the template, the measured rows, and the queries through the ask contract", () => {
        const ctx = postmortemAsk(input);
        expect(ctx).toMatchObject({ title: "Postmortem: ContosoCare session 7f3a9c21", page: "scoreboard", visualId: "postmortem.plan", source: "history", totalRows: 4 });
        expect(ctx.prompt).toMatch(/^Write the postmortem of ContosoCare session 7f3a9c21 .+ with exactly these sections: Summary, Timeline \(UTC\), Impact on ContosoCare, Cause, Response, Times to signal and recover, Follow-ups\./);
        expect(ctx.prompt).toMatch(/never that Database Hub detected something/);
        expect(ctx.rows?.[2]).toMatchObject({ target: "T3", service: "Scheduling", injected: "2026-11-17T14:03:00.000Z", ttdMin: 1, ttrMin: 24, status: "Pass" });
        expect(ctx.dax).toMatch(/^\/\/ Sessions and activity requests\nEVALUATE/);
    });

    it("says no fault's signal was visible by its rule, never that no signal showed, when each rose short of its rule (F23)", () => {
        const runs = [run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T1", "incident:cpu-pressure", 30, 40)];
        const sessionPlan = toPlans(runs)[0];
        const scores = scorePlan(sessionPlan, { bins: bins("T1", (m) => (m === 33 ? { cpu: 66 } : {})), beats: [], runs });
        const { markdown } = buildPostmortem({ ...input, plan: sessionPlan, scores, episodes: [], beat: null });
        expect(markdown).not.toMatch(/no signal showed|stayed under/);
        expect(markdown).toContain("No measured impact: no fault's signal was visible by its rule in this window; the follow-ups say what each one's signal reached.");
        expect(markdown).toContain("- **CPU pressure on T1 wasn't visible:** Not visible by its rule: CPU reached 30.0 % or more in 1 bin, never 2 in a row, until 14:25 UTC, 15 minutes after its window; its peak was 66.0 % at 14:03 UTC.");
    });

    it("says something of every fault in an empty impact only when it's so of every fault (the review of F23)", () => {
        const impactOfPlan = (runs: SessionRun[], b: Bin[], incidents: Incident[] = []) => {
            const sessionPlan = toPlans(runs)[0];
            const scores = scorePlan(sessionPlan, { bins: b, beats: [], runs, incidents });
            const { markdown } = buildPostmortem({ ...input, plan: sessionPlan, scores, episodes: [], beat: null });
            return { statuses: scores.map((s) => s.status), markdown, line: markdown.split("## Impact on ContosoCare\n\n")[1]?.split("\n")[0] };
        };
        const neutral = "No measured impact in this view; the follow-ups say what was measured for each fault, or why it wasn't.";
        // A lone RU storm on T5 with no T5 episode in view isn't measured: never "not visible by its rule".
        const storm = impactOfPlan([run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T5", "incident:ru-storm", 30, 40)], []);
        expect(storm.statuses).toEqual(["Not supported"]);
        expect(storm.markdown).toContain("and 1 had no signal the history measures.");
        expect(storm.line).toBe(neutral);
        // A Warning measured in view beside a Pass from the notebook's own check: never "their bins aren't in this view".
        const passed: Incident = { key: `request:${SESSION}:01`, label: "", source: "", target: "T3", scenario: "cpu-pressure", family: "cpu", start: at(50), end: at(60), durationMin: 10, peakValue: null, peakUnit: "", verdict: "Pass" };
        const t3 = run(`${SESSION}:01`, "T3", "incident:cpu-pressure", 50, 60);
        const mixed = impactOfPlan([run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T1", "incident:cpu-pressure", 30, 40), t3], bins("T1", (m) => (m === 33 ? { cpu: 66 } : {})), [passed]);
        expect(mixed.statuses).toEqual(["Warning", "Pass"]);
        expect(mixed.line).toBe(neutral);
        // The notebook's check alone, for every fault: then it says so.
        expect(impactOfPlan([run(SESSION, "all", "session", 0, 90), t3], [], [passed]).line).toBe("No impact in business words: the notebook's own check saw these faults' signals, and their bins aren't in this view.");
    });

    it("tells a fault's injection before its signal, though the signal's bin starts before the injection (F17)", () => {
        // The control injected at 13:30:20, and the signal shows in the bin that starts at 13:30:00.
        const runs = [run(SESSION, "all", "session", 0, 90), run(`${SESSION}:00`, "T1", "incident:blocking-chain", 20 / 60, 10)];
        const sessionPlan = toPlans(runs)[0];
        const [score] = scorePlan(sessionPlan, { bins: bins("T1", (m) => (m < 10 ? { blocked: 5 } : {})), beats: [], runs });
        expect(score.visibleAt).toEqual(at(0));
        // Never a negative time to signal: 0, written as at most one bin.
        expect(score.ttdMin).toBe(0);
        expect(planEvents([score]).map((e) => e.kind)).toEqual(["injected", "visible", "recovered"]);
        const { markdown } = buildPostmortem({ ...input, plan: sessionPlan, scores: [score], episodes: [], beat: null });
        expect(markdown.split("\n").filter((l) => l.startsWith("| 13:30 | T1 |")).map((l) => l.split(" | ")[2])).toEqual(["Injected", "Signal visible"]);
        expect(markdown).toContain("| Deep blocking chain and lock escalation | T1 | 13:30 | 13:30 | ≤ 1 min |");
        // In a 5-minute bin, the signal's time can be minutes before the injection: it's still told after it.
        const late = { ...score, injectedAt: new Date(T0 + 140000), visibleAt: at(0), recoveredAt: at(15) };
        expect(planEvents([late]).map((e) => `${e.kind} ${e.at.toISOString().slice(11, 16)}`)).toEqual(["injected 13:32", "visible 13:30", "recovered 13:45"]);
    });
});
