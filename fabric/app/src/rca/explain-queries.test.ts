import { describe, expect, it } from "vitest";
import { cpuIncidentIn, EXPLAIN_QUERIES, EXPLAIN_QUERIES_PROPS, explainQueries, queryArgs, queryReadWindow, type QueryArgs } from "./explain-queries";
import { emptySidecar, type SidecarEvidence } from "./sidecar";
import { fixtureSidecar, namesAScenario } from "./testdata/contract";
import type { Episode, InvestigationResult, RcaTarget } from "./types";

const at = (text: string) => new Date(`2026-11-${text}Z`);
const NOW = at("21T12:00:00");
const FROM = at("20T17:03:00");
const TO = at("20T17:10:00");

const episode = (target: RcaTarget, family: string, start: string, last: string): Episode => ({
    key: `${target}-${family}-${start}`,
    target,
    family,
    signal: family,
    unit: "%",
    start: at(start),
    end: null,
    last: at(last),
    peak: 95,
    peakAt: at(start),
    level: 80,
    baseline: 20,
    valued: 6,
    unknown: 0,
    atLevel: 6,
    support: "sustained",
    source: "Database Hub's telemetry",
    confidence: "high",
});

/** The envelope tools.ts gives it: the window, the targets, and a line of what wasn't captured, which the answer keeps. */
const envelope = (target: RcaTarget, from: Date, to: Date): InvestigationResult => ({
    tool: EXPLAIN_QUERIES,
    version: 1,
    window: { fromUtc: from.toISOString(), toUtc: to.toISOString() },
    targets: [target],
    episodes: [],
    findings: [],
    rootCause: null,
    recommendations: [],
    nextSteps: [],
    notCaptured: [`${target}: the envelope's line.`],
});

/** explain_queries on a sidecar, with what its loader was asked. */
async function explain(args: QueryArgs, sidecar: SidecarEvidence, from = FROM, to = TO, episodes: Episode[] = []) {
    const asked: Array<{ from: string; to: string; targets: readonly RcaTarget[] }> = [];
    const result = await explainQueries({
        args,
        from,
        to,
        base: envelope(args.target, from, to),
        sidecar: async (f, t, targets) => {
            asked.push({ from: f.toISOString(), to: t.toISOString(), targets });
            return sidecar;
        },
        episodes,
        resource: [],
        now: NOW,
    });
    return { result, asked };
}

describe("explain_queries' arguments", () => {
    it("takes a target, a query's ID as its digits, and what to rank by", () => {
        expect(queryArgs({ target: "T3" })).toEqual({ target: "T3", rankBy: "cpu" });
        expect(queryArgs({ target: "T4", queryId: "-6412873301142229951", rankBy: "duration" })).toEqual({ target: "T4", queryId: "-6412873301142229951", rankBy: "duration" });
        expect(queryArgs({ target: "T3", queryId: 412 })).toEqual({ target: "T3", queryId: "412", rankBy: "cpu" });
        expect(queryArgs({ target: "T3", queryId: " 412 ", rankBy: "executions" })).toEqual({ target: "T3", queryId: "412", rankBy: "executions" });
        expect(new RegExp(EXPLAIN_QUERIES_PROPS.queryId.pattern).test("-6412873301142229951")).toBe(true);
        expect(new RegExp(EXPLAIN_QUERIES_PROPS.queryId.pattern).test("1e5")).toBe(false);
    });

    it("refuses what it doesn't take, in words, so a guess is never read as an answer", () => {
        expect(queryArgs({ target: "T9" })).toBe('target takes T1, T2, T3, T4, T4-replica, T5; "T9" isn\'t one of them.');
        expect(queryArgs({})).toMatch(/^target takes .*; null isn't one of them\.$/);
        // A 64-bit ID as a JSON number has already lost its last digits.
        expect(queryArgs({ target: "T4", queryId: Number("-6412873301142229951") })).toMatch(/^queryId takes a query's Query Store ID as its digits, in quotes; .* \(a 64-bit ID loses digits as a number\)\.$/);
        for (const queryId of ["412a", "", 4.5, true]) expect(queryArgs({ target: "T3", queryId }), String(queryId)).toMatch(/^queryId takes/);
        expect(queryArgs({ target: "T3", rankBy: "memory" })).toBe('rankBy takes cpu, duration, reads, waits, executions; "memory" isn\'t one of them.');
    });
});

describe("the minutes explain_queries reads", () => {
    it("reads the hour and an interval before the minutes, for a baseline, and an interval after, for a forcing's figures", () => {
        expect(queryReadWindow(FROM, TO)).toEqual({ from: at("20T15:48:00"), to: at("20T17:25:00") });
    });

    it("ties the earliest CPU incident on the target in the minutes to them, never another target's or signal's", () => {
        const episodes = [episode("T3", "cpu", "20T17:30:00", "20T17:40:00"), episode("T1", "cpu", "20T17:02:00", "20T17:08:00"), episode("T3", "blocking", "20T17:01:00", "20T17:09:00"), episode("T3", "cpu", "20T17:04:00", "20T17:10:00")];
        expect(cpuIncidentIn(episodes, "T3", FROM, TO)).toEqual({ family: "cpu", start: at("20T17:04:00"), end: null, last: at("20T17:10:00") });
        expect(cpuIncidentIn([...episodes, episode("T3", "cpu", "20T16:58:00", "20T17:05:00")], "T3", FROM, TO)?.start).toEqual(at("20T16:58:00"));
        expect(cpuIncidentIn(episodes, "T2", FROM, TO)).toBeUndefined();
    });
});

describe("explain_queries' answer", () => {
    it("answers T3's plan regression from the sidecar alone, on the envelope, and reads the minutes it says", async () => {
        const { result, asked } = await explain({ target: "T3", rankBy: "cpu" }, fixtureSidecar("t3"), FROM, TO, [episode("T3", "cpu", "20T17:04:00", "20T17:10:00")]);
        expect(asked).toEqual([{ from: "2026-11-20T15:48:00.000Z", to: "2026-11-20T17:25:00.000Z", targets: ["T3"] }]);
        expect(result).toMatchObject({ tool: EXPLAIN_QUERIES, window: { fromUtc: FROM.toISOString(), toUtc: TO.toISOString() }, targets: ["T3"] });
        expect(result.rootCause).toMatchObject({ ruleIds: ["QS-PLAN-REGRESSION", "QS-PLAN-FORCED"], confidence: "high" });
        expect(result.rootCause?.statement).toContain("The CPU rose at 17:04:00 UTC, as the new plan first ran");
        // Without a CPU incident in the minutes, the rise isn't claimed: the window's episodes are what ties it.
        expect((await explain({ target: "T3", rankBy: "cpu" }, fixtureSidecar("t3"))).result.rootCause?.statement).not.toContain("The CPU rose");
        expect(result.details).toMatchObject({ target: "T3", recorded: "yes", rankBy: "cpu" });
        expect(result.details.top[0].queryId).toBe("412");
        expect(result.recommendations.map((r) => r.id)).toEqual(["CPU-FORCE-PLAN", "CPU-MISSING-INDEX"]);
        expect(result.notCaptured).toContain("T3: the envelope's line.");
        const text = JSON.stringify(result);
        expect(JSON.parse(text)).toMatchObject({ tool: EXPLAIN_QUERIES });
        expect(namesAScenario(text)).toEqual([]);
    });

    it("answers about one query when asked, and says when the capture's top lists don't hold it", async () => {
        const one = (await explain({ target: "T3", queryId: "412", rankBy: "cpu" }, fixtureSidecar("t3"))).result;
        expect(one.details.top.map((q) => q.queryId)).toEqual(["412"]);
        expect(one.details.planChanges.map((c) => c.queryId)).toEqual(["412"]);
        expect(one.rootCause?.ruleIds).toContain("QS-PLAN-REGRESSION");

        const absent = (await explain({ target: "T3", queryId: "999", rankBy: "cpu" }, fixtureSidecar("t3"))).result;
        expect(absent.details.top).toEqual([]);
        expect(absent.details.planChanges).toEqual([]);
        expect(absent.notCaptured).toContain("T3: query 999 isn't in Query Store's top lists in these minutes, as the capture read them.");
    });

    it("keeps T4's 64-bit query ID whole", async () => {
        const id = "-6412873301142229951";
        const { result } = await explain({ target: "T4", queryId: id, rankBy: "duration" }, fixtureSidecar("t4"), at("20T17:02:30"), at("20T17:12:20"));
        expect(result.details.top.map((q) => q.queryId)).toEqual([id]);
        expect(JSON.stringify(result)).toContain(`"queryId":"${id}"`);
    });

    it("says what a read at its limit left out, and nothing about one query when the history has no rows to look in", async () => {
        const cut: SidecarEvidence = { ...fixtureSidecar("t3"), cut: [{ table: "RCA Query Stats", until: at("20T17:05:00") }] };
        expect((await explain({ target: "T3", rankBy: "cpu" }, cut)).result.notCaptured).toContain(
            "RCA Query Stats: the window holds more rows than one query returns, so what it holds from 17:05:00 UTC on wasn't read; ask about a narrower window",
        );
        const older: SidecarEvidence = { ...emptySidecar(), missing: ["RCA Query Coverage", "RCA Query Stats"] };
        const { result } = await explain({ target: "T3", queryId: "412", rankBy: "cpu" }, older);
        expect(result.details.recorded).toBe("model-missing");
        expect(result.rootCause).toBeNull();
        expect(result.notCaptured).toEqual([
            "T3: the envelope's line.",
            "T3: this history's model doesn't have Query Store's tables yet (RCA Query Coverage, RCA Query Stats), so it holds no per-query statistics; ./scripts/deploy.ps1 updates the model.",
        ]);
    });
});
