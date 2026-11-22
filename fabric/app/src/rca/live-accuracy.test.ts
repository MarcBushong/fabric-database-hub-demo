import { describe, expect, it } from "vitest";

import { COSMOS_METRICS } from "@/data/model";
import { describeEpisode } from "./detector";
import { LIVE_A_KEYS, LIVE_KEYS, live, liveAnswerKey, liveSources } from "./testdata/live-rb-2233e0ae";
import { createInvestigationTools } from "./tools";
import type { InvestigationResult } from "./types";

// Final tests' live findings at 94a17ff7 and its live check of 4e2c65ed (dbhubrb, 2026-11-21), on the history model's own
// rows (testdata/live-rb-2233e0ae.rows.json, and A's two surges in live-ra-4e2c65ed.rows.json). Finding 1: the RCA view explained the replica's first stall as slow replay at
// 16:15, from Azure Monitor's 5-minute intervals, while explain_replica_lag found the replay conflict. Finding 2: the
// connection surge's report had no cause. The live check of 4e2c65ed: a surge said no client was refused while the
// workload's answer key recorded refused attempts, a surge Stop now cut off read the next session's, four waves read as
// one, and a key find_incidents listed had no episode.

const tools = () => createInvestigationTools({ ...liveSources(), timeZone: "America/New_York", latestDay: live("00:00:00"), latest: live("21:33:15") });

async function ask(name: string, args: Record<string, unknown>): Promise<InvestigationResult> {
    const r = await tools().investigate(name, args);
    if (typeof r === "string") throw new Error(r);
    return r;
}

const part = (r: InvestigationResult, tool: string) => (r.details?.parts as Array<{ tool: string; details: Record<string, unknown> }>).find((p) => p.tool === tool)?.details;

describe("the replica's lag (finding 1)", () => {
    it("explains the first stall from its own minutes: replay stood still behind session 5883's lock, as the capture's samples tell it", async () => {
        const r = await ask("explain_incident", { episodeKey: LIVE_KEYS.replicaFirst });
        expect(r.rootCause).toMatchObject({ confidence: "high", ruleIds: ["REPL-REPLAY-CONFLICT"] });
        // Word for word as Final tests read it live at 4e2c65ed.
        expect(r.rootCause?.statement).toMatch(
            /^The replica's time since its last replay rose from 16:16:42 to 176\.7 s at 16:19:17 UTC \(21\.4 s, 96\.6 s, 156\.7 s, 176\.7 s\), counting from its last replay at 16:16:20 UTC, and was back to 0\.4 s at 16:19:27 UTC; it grew 1 s per second: replay stood still\. /,
        );
        for (const fact of [
            "waited for AccessExclusiveLock on demo.replica_lag_marks from 16:16:21 UTC",
            "(AccessShareLock; session 5883, ContosoCare.Demo: SELECT r.marks_seen",
            "578598600 bytes received but not replayed",
            "write and flush lag at most 7.132 s",
            "the query ended before that, so nothing was cancelled",
        ]) {
            expect(r.rootCause?.statement).toContain(fact);
        }
        // Database Hub's chart, cited beside the samples: Azure Monitor's 5-minute interval that holds the stall, from the
        // session's own save; the day-long save's 15 minutes (178 s, the second stall's) is left out (the review of 803f2b1a).
        expect(r.rootCause?.evidence.map((e) => e.text)).toContain("Read Replica Lag 148 s, its highest from 16:15 to 16:20 UTC");
        // The timeline is the capture's own samples, from before the stall to its recovery, not two 5-minute intervals.
        const lag = part(r, "explain_replica_lag")?.lag as Array<{ at: string; seconds: number; source: string }>;
        expect(lag[lag.length - 1]).toMatchObject({ at: "2026-11-21T16:19:27Z", seconds: 0.4 });
        expect(lag.length).toBeGreaterThan(20);
        expect(lag.every((p) => p.source === "RCA Replica")).toBe(true);
        expect(r.recommendations.map((x) => x.id)).toEqual(["RPL-SHORT-REPORTS", "RPL-STANDBY-DELAY", "RPL-NO-EXCLUSIVE"]);
    });

    it.each([
        ["the harness's live call", { at: "2026-11-21T16:17:12Z", minutesBefore: 5, minutesAfter: 15 }],
        ["the stall's escalation", { at: "2026-11-21T16:17:12Z" }],
        ["a local time in it", { at: "11:18" }],
        ["its peak", { at: "2026-11-21T16:19:17Z" }],
        ["a window that cuts off its start", { at: "2026-11-21T16:19:30Z", minutesBefore: 1, minutesAfter: 1 }],
    ])("gives the chat the RCA view's finding when asked at %s", async (_, args) => {
        const view = await ask("explain_incident", { episodeKey: LIVE_KEYS.replicaFirst });
        const chat = await ask("explain_replica_lag", args);
        expect(chat.rootCause).toEqual(view.rootCause);
        expect(chat.findings).toEqual(view.findings);
    });

    it("explains the second stall as its own, behind its own holder", async () => {
        const r = await ask("explain_incident", { episodeKey: LIVE_KEYS.replicaSecond });
        expect(r.rootCause).toMatchObject({ confidence: "high", ruleIds: ["REPL-REPLAY-CONFLICT"] });
        expect(r.rootCause?.statement).toMatch(/^The replica's time since its last replay rose from 16:21:12 to 177\.7 s at 16:23:48 UTC .*counting from its last replay at 16:20:51 UTC/);
        expect(r.rootCause?.statement).toContain("session 6553");
        expect(r.rootCause?.statement).not.toContain("session 5883");
    });
});

describe("T4's connection surges (finding 2, and the live check of 4e2c65ed)", () => {
    it("explains the first by what held the slots, in its four waves, with what the capture can and can't say of refusals", async () => {
        const r = await ask("explain_incident", { episodeKey: LIVE_KEYS.connections });
        expect(r.rootCause).toMatchObject({ ruleIds: ["CONN-IDLE"], confidence: "high" });
        const s = r.rootCause!.statement;
        expect(s).toMatch(/^T4's client connections reached 35 of the 35 slots clients can use \(max_connections 50 less 15 reserved; the capture's own connection among them\) at 15:26:51 UTC, /);
        // The live series ran in 4 waves, with drops to 8 to 10 connections between them, never one continuous surge.
        expect(s).toContain("in 4 waves at 80 % of the limit or more between 15:26:41 and 15:34:11 UTC, with peaks of 35, 33, 33, and 33 and the connections falling to 8, 8, and 8 between them; 32 of the 53 samples from 15:26:41 to 15:35:41 UTC were at that level.");
        expect(s).toContain("Every usable slot was in use in 4 samples between 15:26:51 and 15:27:21 UTC (35 of 35), so a client connecting then would have been refused (SQLSTATE 53300, too many clients).");
        expect(s).toContain("Azure Monitor's failed-connection count stayed at 0 in its 3 intervals from 15:25 to 15:40 UTC; it doesn't count refusals at the connection limit, so the capture can't say how many there were.");
        expect(r.findings).toHaveLength(1);
        expect(r.recommendations.map((x) => x.id)).toEqual(["PG-POOL", "PG-IDLE-SESSION-TIMEOUT"]);
        expect(r.notCaptured).toContain("T4: how many clients were refused at the connection limit isn't captured: PostgreSQL refuses them before they reach a session, and Azure Monitor's failed connections don't count them.");
        const details = part(r, "explain_connections");
        expect(details).toMatchObject({ limit: 35, maxConnections: 50, reserved: 15, failedConnections: 0, samplesAtLimit: 4, peak: { at: "2026-11-21T15:26:51Z", total: 35, idle: 34 } });
        expect((details?.waves as unknown[]).length).toBe(4);
        // find_incidents and triage say the same: some of its samples, not "in a row".
        const [episode] = (await tools().episodes(live("15:26:00"), live("15:36:00"), ["T4"])).filter((e) => e.key === LIVE_KEYS.connections);
        expect(describeEpisode(episode)).toMatch(/in 3\d of its \d+ samples/);
    });

    // Graded against the answer key, the workload's own record, which the RCA never reads.
    it("never says no client was refused where the workload's answer key recorded refused attempts", async () => {
        const key = liveAnswerKey();
        const refusedIn = (from: Date, to: Date) =>
            key.filter((r) => r.name === "surge-overshoot" && r.at >= from && r.at <= to).reduce((n, r) => n + Number(/(\d+) attempt\(s\) past the limit refused/.exec(r.detail ?? "")?.[1] ?? 0), 0);
        const surges = (await tools().episodes(live("15:15:00"), live("19:45:00"), ["T4"])).filter((e) => e.family === "connections");
        expect(surges.map((e) => e.key)).toEqual(expect.arrayContaining([LIVE_KEYS.connections, LIVE_KEYS.connectionsCutOff, LIVE_KEYS.connectionsNext]));
        let graded = 0;
        for (const e of surges) {
            const refused = refusedIn(new Date(e.start.getTime() - 60_000), e.end ?? e.last);
            const r = await ask("explain_incident", { episodeKey: e.key });
            const s = r.rootCause?.statement ?? "";
            expect(s, e.key).not.toMatch(/No client was refused|no client asked|none (was|were) refused/i);
            if (refused > 0) {
                graded++;
                expect(s, e.key).toMatch(/would have been refused|whether a client was refused isn't known/);
            }
        }
        expect(graded).toBeGreaterThanOrEqual(4);
    });

    // A's two surges (dbhubra), graded against A's answer key: each wave's refusals came in a fill of about 0.1 s, which the
    // 10-s samples never saw, so the samples peaked at 34 of 35.
    it("grades A's surges the same way: refusals between the samples are said to be unknown, never absent", async () => {
        const a = createInvestigationTools({ ...liveSources("ra"), timeZone: "America/New_York", latestDay: live("00:00:00"), latest: live("21:33:15") });
        const key = liveAnswerKey("ra");
        const surges = (await a.episodes(live("13:00:00"), live("14:20:00"), ["T4"])).filter((e) => e.family === "connections");
        expect(surges.map((e) => e.key)).toEqual([LIVE_A_KEYS.first, LIVE_A_KEYS.second]);
        for (const e of surges) {
            const refused = key
                .filter((r) => r.name === "surge-overshoot" && r.at >= new Date(e.start.getTime() - 60_000) && r.at <= (e.end ?? e.last))
                .reduce((n, r) => n + Number(/(\d+) attempt\(s\) past the limit refused/.exec(r.detail ?? "")?.[1] ?? 0), 0);
            expect(refused, e.key).toBe(4);
            const r = await a.investigate("explain_incident", { episodeKey: e.key });
            if (typeof r === "string") throw new Error(r);
            expect(r.rootCause?.ruleIds, e.key).toEqual(["CONN-IDLE"]);
            const s = r.rootCause?.statement ?? "";
            expect(s, e.key).not.toMatch(/No client was refused|no client asked|none (was|were) refused/i);
            expect(s, e.key).toContain("The capture's samples saw at most 34 of the 35 usable slots in use; between them the slots may have filled, so whether a client was refused isn't known.");
            expect(s, e.key).toMatch(/Azure Monitor's failed-connection count stayed at 0 in its \d+ intervals? from .* UTC; it doesn't count refusals at the connection limit\./);
        }
    });

    it("ends a surge Stop now cut off where its own capture ended, never in the next session's samples 37 minutes later", async () => {
        const [cut] = (await tools().episodes(live("18:45:00"), live("19:45:00"), ["T4"])).filter((e) => e.key === LIVE_KEYS.connectionsCutOff);
        expect(cut.end ?? null).toBeNull();
        expect(cut.last.getTime()).toBeLessThanOrEqual(live("18:53:22").getTime());
        expect(Math.round(cut.peak * 10) / 10).toBe(97.1);
        expect(describeEpisode(cut)).toContain("(the capture ended while it was still on, so its end isn't known)");
        const r = await ask("explain_incident", { episodeKey: LIVE_KEYS.connectionsCutOff });
        const s = r.rootCause!.statement;
        expect(s).toMatch(/^T4's client connections reached 34 of the 35 slots clients can use .* at 18:51:52 UTC, /);
        expect(s).toContain("The capture ended at 18:53:22 UTC while it was still on (it recorded no end), so what came after isn't known.");
        expect(s).not.toMatch(/19:\d\d/);
    });

    it("is triage's to explain_incident, with its key, for the chat", async () => {
        const r = await ask("triage_window", { from: "2026-11-21T15:25:00Z", to: "2026-11-21T15:40:00Z", targets: ["T4"] });
        const hypotheses = r.details?.hypotheses as Array<{ family: string; nextTool: string; episodeKey?: string }>;
        expect(hypotheses.find((h) => h.family === "connections")).toMatchObject({ nextTool: "explain_incident", episodeKey: LIVE_KEYS.connections });
    });
});

describe("T5's normalized RU and every listed incident (the live check of 4e2c65ed)", () => {
    // The review of 803f2b1a: B's day-long save kept 15:30's 15-minute total (27630 requests) beside the session's own
    // 1-minute points, and the sums counted both. One point per interval now, the finest: 9 intervals at 100 % from 15:31.
    it("counts T5's requests and 429s from the intervals at 100 % that it names, as the raw rows hold them, each once", async () => {
        const r = await ask("explain_incident", { episodeKey: LIVE_KEYS.ru });
        const cosmos = (await liveSources().telemetry(live("15:30:00"), live("15:43:00"), ["T5"])).cosmos!;
        const at100 = new Set(cosmos.points.filter((p) => p.metric === COSMOS_METRICS.normalizedRu && p.value >= 100 && p.at < live("15:43:00")).map((p) => p.at.getTime()));
        const sum = (metric: string) => cosmos.points.filter((p) => p.metric === metric && at100.has(p.at.getTime())).reduce((n, p) => n + p.value, 0);
        expect(at100.size).toBe(9);
        expect([sum(COSMOS_METRICS.requests), sum(COSMOS_METRICS.throttled)]).toEqual([24820, 13222]);
        expect(r.rootCause?.statement).toContain("reached 100 % in at least one second of each of the 9 intervals from 15:31 to 15:42 UTC");
        expect(r.rootCause?.statement).toContain("Azure Monitor counted 24820 requests in those intervals, 13222 of them throttled (429, 53.3 %)");
        // One "no RCA capture" note for T5, the incident's, not its part's too (the coordinator's note on 803f2b1a).
        expect(r.notCaptured.filter((line) => line.startsWith("T5: no RCA capture recorded"))).toEqual(["T5: no RCA capture recorded for 15:31:00-15:42:00 UTC; only the telemetry (Telemetry Snapshots) is known"]);
    });

    // The re-review of bb70161f: the storm from 15:46 read T5's history from 15:16, so it missed 15:00's hourly provisioned
    // throughput, and said nothing of why a new partition key wouldn't help.
    it("reads the hour's provisioned throughput for the storm 46 minutes into its hour", async () => {
        const r = await ask("explain_incident", { episodeKey: "T5-ru-20261121T154600Z" });
        expect(r.rootCause?.statement).toContain("At 400 RU/s, under the 10,000 RU/s one physical partition serves, the container needs only one physical partition");
        expect(r.notCaptured.join(" ")).not.toMatch(/provisioned throughput/);
    });

    it("resolves every incident find_incidents lists over the day, also where its own minutes read it differently", async () => {
        const listed = await ask("find_incidents", { from: "2026-11-21T11:00:00Z", to: "2026-11-21T20:00:00Z" });
        const keys = (listed.episodes ?? []).map((e) => e.key);
        expect(keys).toEqual(expect.arrayContaining(["T5-ru-20261121T121500Z", LIVE_KEYS.ru, LIVE_KEYS.replicaFirst, LIVE_KEYS.connectionsCutOff]));
        // One incident per storm and stall (the review of 803f2b1a): the day-long save's 15-minute points no longer split
        // 12:15 from 12:30, or list Azure Monitor's 16:15 beside the capture's own stall from 16:17:12.
        for (const twin of ["T5-ru-20261121T123000Z", "T5-ru-20261121T153000Z", "T4-replica-replica_lag-20261121T161500Z"]) expect(keys).not.toContain(twin);
        for (const key of keys) {
            const r = await tools().investigate("explain_incident", { episodeKey: key });
            expect(typeof r, key).not.toBe("string");
            const result = r as InvestigationResult;
            expect(result.rootCause !== null || result.notCaptured.length > 0, key).toBe(true);
        }
        // A key from an earlier list still reads as the incident that holds its time.
        const joined = (await tools().investigate("explain_incident", { episodeKey: "T5-ru-20261121T123000Z" })) as InvestigationResult;
        expect(joined.details?.readAs).toEqual({ key: "T5-ru-20261121T123000Z", as: ["T5-ru-20261121T121500Z"] });
        expect(joined.rootCause?.ruleIds).toEqual(["RU-THROTTLED"]);
    });
});