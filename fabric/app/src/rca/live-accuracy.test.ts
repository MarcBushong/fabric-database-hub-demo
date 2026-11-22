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

    // The review of ebd1c6c3: asked in the second stall's first minute, before the capture's escalation at 16:21:42, the
    // chat explained the 12.5 s blip before it, by the first stall's lock: it read from the first sample at or after the
    // time less a minute, 16:20:42's 0.3 s, though the next, 21.6 s at 16:21:12, counted from a last replay at 16:20:51.
    it.each(["2026-11-21T16:21:00Z", "2026-11-21T16:21:20Z", "2026-11-21T16:21:42Z"])("gives the chat the second stall's finding when asked at %s, in its first minute", async (time) => {
        const view = await ask("explain_incident", { episodeKey: LIVE_KEYS.replicaSecond });
        const chat = await ask("explain_replica_lag", { at: time });
        expect(chat.rootCause).toEqual(view.rootCause);
        expect(chat.findings).toEqual(view.findings);
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
        expect(s).toContain("Azure Monitor's failed-connection count stayed at 0 in its 3 intervals from 15:25 to 15:40 UTC; in this demo's live check it counted none of the refusals at the connection limit, so the capture can't say how many there were.");
        expect(r.findings).toHaveLength(1);
        expect(r.recommendations.map((x) => x.id)).toEqual(["PG-POOL", "PG-IDLE-SESSION-TIMEOUT"]);
        expect(r.notCaptured).toContain("T4: how many clients were refused at the connection limit isn't captured: PostgreSQL refuses them before they reach a session, and in this demo's live check Azure Monitor's failed connections counted none of them.");
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
            expect(s, e.key).toMatch(/Azure Monitor's failed-connection count stayed at 0 in its \d+ intervals? from .* UTC; in this demo's live check it counted none of the refusals at the connection limit\./);
        }
    });

    it("ends a surge Stop now cut off where its own capture ended, never in the next session's samples 37 minutes later", async () => {
        const [cut] = (await tools().episodes(live("18:45:00"), live("19:45:00"), ["T4"])).filter((e) => e.key === LIVE_KEYS.connectionsCutOff);
        expect(cut.end ?? null).toBeNull();
        expect(cut.last.getTime()).toBeLessThanOrEqual(live("18:53:22").getTime());
        expect(Math.round(cut.peak * 10) / 10).toBe(97.1);
        // The review of 803f2b1a: its last samples read 32, 8, and 8 of 35, so it wasn't "still on": it fell under the level
        // by 18:53:12, and the capture ended at 18:53:22, before its 60 s under 70 % could confirm the end.
        expect(describeEpisode(cut)).toContain("from 18:51:52 UTC, under its level by 18:53:12 UTC (the capture ended at 18:53:22 UTC, before it could confirm the end)");
        const r = await ask("explain_incident", { episodeKey: LIVE_KEYS.connectionsCutOff });
        const s = r.rootCause!.statement;
        expect(s).toMatch(/^T4's client connections reached 34 of the 35 slots clients can use .* at 18:51:52 UTC, /);
        expect(s).toContain("The connections fell under 80 % of the limit by 18:53:12 UTC; the capture ended at 18:53:22 UTC, before it could confirm the end.");
        expect(s).not.toMatch(/still on/);
        expect(s).not.toMatch(/19:\d\d/);
    });

    it("is triage's to explain_incident, with its key, for the chat", async () => {
        const r = await ask("triage_window", { from: "2026-11-21T15:25:00Z", to: "2026-11-21T15:40:00Z", targets: ["T4"] });
        const hypotheses = r.details?.hypotheses as Array<{ family: string; nextTool: string; episodeKey?: string }>;
        expect(hypotheses.find((h) => h.family === "connections")).toMatchObject({ nextTool: "explain_incident", episodeKey: LIVE_KEYS.connections });
    });

    // The review of 2e19adfc: asked about 16:10 to 16:18, the episode read "still on at 16:18:00 … peak 96.6 s at 16:17:57",
    // while its cause, read on to the rise's recovery, read "176.7 s at 16:19:17": two peaks in one answer, unsaid.
    it("says when the replica's explanation reads past the minutes asked about, to the rise's recovery", async () => {
        const r = await ask("explain_incident", { target: "T4-replica", from: "2026-11-21T16:10:00Z", to: "2026-11-21T16:18:00Z" });
        expect((r.details?.episodes as Array<{ text: string }>)[0].text).toContain("from 16:17:12 UTC (still on at 16:18:00 UTC, where the minutes read end), peak 96.6 s at 16:17:57 UTC");
        expect(r.rootCause?.statement).toMatch(/to 176\.7 s at 16:19:17 UTC .*\(read past the minutes asked about, which end at 16:18:00 UTC, to its recovery at 16:19:27 UTC\): replay stood still\./);
        // Asked about minutes that hold the whole rise, it says nothing of the kind.
        const whole = await ask("explain_incident", { target: "T4-replica", from: "2026-11-21T16:10:00Z", to: "2026-11-21T16:21:00Z" });
        expect(whole.rootCause?.statement).not.toMatch(/read past/);
    });

    // The review of 97fdf5ba: RCA Events are read up to a window's end, so a surge that relaxed after it read as one its
    // capture cut off: "(the capture ended at 15:30:51 …)", though the next wave read 33 at 15:31:01, the capture relaxed it
    // at 15:35:11, and T4's coverage in the same read ran to 15:55. The review of 858c50c2: it read "still on" then, though
    // its samples in the minutes read had fallen under the level: 8, 10, 10, and 20 of 35, and the replica's to 0.4 s.
    it("says where a surge or a stall the minutes read end in fell, never that its capture ended it, nor that it was still on", async () => {
        const summary = (r: InvestigationResult, family: string) => (r.details?.hypotheses as Array<{ family: string; summary: string }>).find((h) => h.family === family)?.summary;
        expect(summary(await ask("triage_window", { at: "2026-11-21T15:26:00Z", targets: ["T4"] }), "connections")).toContain(
            "from 15:26:41 UTC, under its level by 15:30:21 UTC (the minutes read end at 15:31:00 UTC, before its capture confirmed the end)",
        );
        expect(summary(await ask("find_incidents", { at: "2026-11-21T15:28:00Z", targets: ["T4"] }), "connections")).toContain(
            "from 15:26:41 UTC, under its level by 15:32:31 UTC (the minutes read end at 15:33:00 UTC, before its capture confirmed the end)",
        );
        // It relaxed at 16:20:03, after the minutes read: not "ended at 16:19:58", nor "still on at 16:20:00".
        const stall = await ask("explain_incident", { target: "T4-replica", from: "2026-11-21T16:10:00Z", to: "2026-11-21T16:20:00Z" });
        expect((stall.details?.episodes as Array<{ text: string }>)[0].text).toContain("from 16:17:12 UTC, under its level by 16:19:27 UTC (the minutes read end at 16:20:00 UTC, before its capture confirmed the end)");
        expect(stall.rootCause?.statement).toContain("and was back to 0.4 s at 16:19:27 UTC");
        // One end in one answer: its episode's, and its explanation's.
        const r = await ask("explain_incident", { target: "T4", from: "2026-11-21T15:21:00Z", to: "2026-11-21T15:31:00Z" });
        expect(r.rootCause?.statement).toContain("The connections fell under 80 % of the limit by 15:30:21 UTC; the minutes read end at 15:31:00 UTC, before the capture confirmed the end.");
        for (const text of [...(r.details?.episodes as Array<{ text: string }>).map((e) => e.text), r.rootCause!.statement]) {
            expect(text).toContain("15:30:21 UTC");
            expect(text).toMatch(/the minutes read end at 15:31:00 UTC, before (its|the) capture confirmed the end/);
            expect(text).not.toMatch(/the capture ended|still on/);
        }
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
        expect(r.rootCause?.statement).toContain("reached 100 % in at least one second of 9 of the 11 intervals from 15:31 to 15:42 UTC");
        expect(r.rootCause?.statement).toContain("Azure Monitor counted 24820 requests in those 9 intervals, 13222 of them throttled (429, 53.3 %)");
        // Final tests' check of ddebd4c3 (F6): the 429s of 15:34 and 15:38, under 100 %, were only in the page's errors table,
        // 14,593 from 15:31 to 15:43 with 15:42's. The statement counts them too, so the two add up.
        const throttledAt = (keep: (t: number) => boolean) => cosmos.points.filter((p) => p.metric === COSMOS_METRICS.throttled && keep(p.at.getTime())).reduce((n, p) => n + p.value, 0);
        const between = throttledAt((t) => t >= live("15:31:00").getTime() && t < live("15:42:00").getTime() && !at100.has(t));
        expect(between).toBe(1354);
        expect(r.rootCause?.statement).toContain(" In the other 2 intervals, where normalized RU consumption stayed under 100 %, Azure Monitor counted 1354 more throttled requests.");
        const storm = await ask("explain_incident", { episodeKey: "T5-throttling-20261121T153100Z" });
        expect(storm.rootCause?.statement).toContain("(14593, 15:31:00 to 15:43:00 UTC,");
        expect(13222 + between + throttledAt((t) => t === live("15:42:00").getTime())).toBe(14593);
        // One note that T5 wasn't captured, the incident's, not its part's too (the coordinator's note on 803f2b1a), in the
        // form B's model gives it: T5's coverage rows are marked not captured (Final tests' check of ddebd4c3, F2).
        expect(r.notCaptured.filter((line) => /^T5: no RCA (capture recorded|evidence)/.test(line))).toEqual(["T5: no RCA evidence for 15:27:09-15:55:03 UTC"]);
    });

    // The re-review of bb70161f: the storm from 15:46 read T5's history from 15:16, so it missed 15:00's hourly provisioned
    // throughput, and said nothing of why a new partition key wouldn't help.
    it("reads the hour's provisioned throughput for the storm 46 minutes into its hour", async () => {
        const r = await ask("explain_incident", { episodeKey: "T5-ru-20261121T154600Z" });
        expect(r.rootCause?.statement).toContain("At 400 RU/s, under the 10,000 RU/s one physical partition serves, the container needs only one physical partition");
        expect(r.notCaptured.join(" ")).not.toMatch(/provisioned throughput/);
        // Final tests' check of ddebd4c3 (F2): its part, reading wider minutes, also said "no RCA evidence for 15:55:03-16:24:58
        // UTC", after the storm had ended. The incident says it once, for its own minutes.
        expect(r.notCaptured.filter((line) => line.startsWith("T5: no RCA"))).toEqual(["T5: no RCA evidence for 15:27:09-15:55:03 UTC"]);
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
        // A key from an earlier list still reads as the incident that holds its time, and says so where the view and
        // Copilot look (the review of 803f2b1a); a later one only within the interval of the key's own point.
        const joined = (await tools().investigate("explain_incident", { episodeKey: "T5-ru-20261121T123000Z" })) as InvestigationResult;
        expect(joined.details?.readAs).toEqual({ key: "T5-ru-20261121T123000Z", as: ["T5-ru-20261121T121500Z"] });
        expect(joined.rootCause?.ruleIds).toEqual(["RU-THROTTLED"]);
        expect(joined.notCaptured[0]).toBe("T5-ru-20261121T123000Z: in its own minutes, the history has no incident with this key; it reads as T5-ru-20261121T121500Z, which holds its time, so this report is that one's.");
        const stall = (await tools().investigate("explain_incident", { episodeKey: "T4-replica-replica_lag-20261121T161500Z" })) as InvestigationResult;
        expect(stall.details?.readAs).toEqual({ key: "T4-replica-replica_lag-20261121T161500Z", as: [LIVE_KEYS.replicaFirst] });
        expect(stall.notCaptured[0]).toContain(`it reads as ${LIVE_KEYS.replicaFirst}, which starts within the interval of its own point`);
        expect(await tools().investigate("explain_incident", { episodeKey: "T5-ru-20261121T150000Z" })).toMatch(/^No episode /);
    });

    // The review of ebd1c6c3, with the shared finestPerInterval (a390db00): the day save's 34 s at 16:45 fell in 16:57 to
    // 17:00, after the session's window, and dropping that point lost it; `…164500Z`, listed at 3732317d, answered "No
    // episode". A remainder spans only part of its save's interval, and a run of its grain steps by that interval (stepped by
    // its 3-minute span, T4's CPU from 16:35 lost its end). Its words give its own 3 minutes, never the save's 15 (Final
    // tests' check of ddebd4c3, F4: "its highest value in each 15-minute interval … in the 3 minutes from 16:57:00").
    it("lists the day save's 34 s from 16:57 as its own incident, worded by its own minutes, and reads the old key as it", async () => {
        const listed = await ask("find_incidents", { from: "2026-11-21T11:00:00Z", to: "2026-11-21T20:00:00Z" });
        expect((listed.episodes ?? []).map((e) => e.key)).toContain("T4-replica-replica_lag-20261121T165700Z");
        const late = await ask("explain_incident", { episodeKey: "T4-replica-replica_lag-20261121T164500Z" });
        expect(late.details?.readAs).toEqual({ key: "T4-replica-replica_lag-20261121T164500Z", as: ["T4-replica-replica_lag-20261121T165700Z"] });
        expect(late.rootCause?.statement).toMatch(
            /^Read Replica Lag \(its highest value in each interval\) reached 34 s in the 3 minutes from 16:57:00 UTC \(1 s, 8 s, 34 s\)\. Azure Monitor's highest value in those 3 minutes can't say whether replay stood still or slowed, and nothing captured says why\.$/,
        );
        expect(late.notCaptured).toContain("Azure Monitor's Read Replica Lag here is its highest value in the 3 minutes from 16:57:00 UTC, so when the lag rose and peaked is known to those 3 minutes only.");
        expect([late.rootCause?.statement, ...late.notCaptured].join(" ")).not.toMatch(/15-minute|3-minute/);
        // The review of c4c63abe: it opened on its one sample because its rule opens on one, not by being far over its level.
        expect((late.details?.episodes as Array<{ text: string }>)[0].text).toContain("peak 34 s at 16:57:00 UTC, in one sample: low confidence (Azure Monitor).");
        const cpu = await ask("explain_incident", { episodeKey: "T4-cpu-20261121T163500Z" });
        expect((cpu.details?.episodes as Array<{ text: string }>)[0].text).toContain("from 16:35:00 to 16:50:00 UTC");
    });

    // The review of 97fdf5ba: keys the list gave T5's session storms until ebd1c6c3, from the day-long save's 15-minute
    // points, answered "No episode" once a key's interval came from the 1-minute point kept at its time. The RCA page keeps
    // a selected key in its address and its remembered view.
    it.each([
        ["T5-ru-20261121T153000Z", LIVE_KEYS.ru],
        ["T5-throttling-20261121T153000Z", "T5-throttling-20261121T153100Z"],
        ["T5-ru-20261121T154500Z", "T5-ru-20261121T154600Z"],
        ["T5-throttling-20261121T154500Z", "T5-throttling-20261121T154600Z"],
    ])("still reads %s, a key from the day-long save's 15 minutes, as the storm in them", async (key, as) => {
        const r = await ask("explain_incident", { episodeKey: key });
        expect(r.details?.readAs).toEqual({ key, as: [as] });
        expect(r.notCaptured[0]).toContain("which starts within the interval of its own point");
    });

    // The review of ebd1c6c3: the 429s' span ended at the last count's start: "10382, 12:15:00 to 12:30:00 UTC", though
    // 6,522 of them were counted for 12:30 to 12:45, and "15:31:00 to 15:42:00" for 1-minute counts that ran to 15:43.
    it("gives the 429s' span to the end of the last count's interval", async () => {
        const day = await ask("explain_errors", { from: "2026-11-21T12:10:00Z", to: "2026-11-21T12:50:00Z", targets: ["T5"] });
        expect(day.rootCause?.statement).toMatch(/^Most errors were throttled requests \(429\) \(10382, 12:15:00 to 12:45:00 UTC,/);
        const storm = await ask("explain_incident", { episodeKey: "T5-throttling-20261121T153100Z" });
        expect(storm.rootCause?.statement).toMatch(/^Most errors were throttled requests \(429\) \(14593, 15:31:00 to 15:43:00 UTC,/);
        expect(storm.findings[0].detail).toContain("on T5 between 15:31:00 and 15:43:00 UTC");
    });
});