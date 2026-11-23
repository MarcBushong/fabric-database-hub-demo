// The postmortem's blind Cause (ADR 0031, section 9): the session's incidents in the Root cause view's order, each with
// explain_incident's root cause, on the preview's sample session and on stubbed investigations.

import { describe, expect, it } from "vitest";

import { answerKeyIn } from "@/copilot/answer-key";
import { ANSWER_KEY_MEASURES } from "@/copilot/model-guide.generated";
import { createSourceClient } from "@/data/query-client";
import { sampleRows } from "@/preview/sample-data";
import { sampleRcaRows } from "@/preview/sample-rca";
import { SESSION_END, SESSION_START } from "@/preview/sample-session";
import { createRcaClient, type RcaClient } from "./client";
import { RcaReadError, type DaxLog } from "./loader";
import { blindCauses, MAX_CAUSES } from "./postmortem";
import { namesAScenario } from "./testdata/contract";
import type { InvestigationTools } from "./tools";
import type { InvestigationResult } from "./types";

const MIN = 60_000;
const from = new Date(SESSION_START);
const to = new Date(SESSION_END + 15 * MIN);

/** The preview's own source: the RCA tables from the contract's fixtures, the rest from the sample history. */
const sampleRca = () => createRcaClient(createSourceClient([{ provenance: "sample", answers: () => true, fetch: async (spec) => ({ rows: sampleRcaRows(spec) ?? sampleRows(spec), requestId: "sample" }) }]), { timeZone: "UTC" });

type Listed = InvestigationResult["episodes"][number];

const episode = (key: string, family: string, source: string, start: string): Listed => ({ key, target: key.split("-")[0] as Listed["target"], family, signal: family, support: "sustained", source, start, end: null, peak: "" });

const result = (patch: Partial<InvestigationResult>): InvestigationResult => ({
    tool: "stub",
    version: 1,
    window: { fromUtc: from.toISOString(), toUtc: to.toISOString() },
    targets: [],
    episodes: [],
    findings: [],
    rootCause: null,
    recommendations: [],
    nextSteps: [],
    notCaptured: [],
    ...patch,
});

/** An RCA client whose investigations answer as `answer` says (a result, a string, or a throw), each logging its query: find_incidents RCA Sessions', every explanation the same RCA Events'. */
function stubbed(answer: (name: string, args: Record<string, unknown>) => Promise<InvestigationResult | string>): RcaClient & { asked: string[] } {
    const asked: string[] = [];
    let logs: DaxLog[] = [];
    const tools = {
        investigate: async (name: string, args: Record<string, unknown>) => {
            asked.push(name === "explain_incident" ? `${name} ${String(args.episodeKey)}` : name);
            const table = name === "find_incidents" ? "RCA Sessions" : "RCA Events";
            logs.push({ table, query: `EVALUATE '${table}'`, rows: 1 });
            return answer(name, args);
        },
    } as unknown as InvestigationTools;
    const drainLogs = () => {
        const out = logs;
        logs = [];
        return out;
    };
    return { timeZone: "UTC", tools: async () => tools, latest: async () => null, drainLogs, asked };
}

describe("the postmortem's blind Cause (ADR 0031, section 9)", () => {
    it("explains the sample session's incidents, the capture's first: T1's chain, its head blocker, and the rows it cites", async () => {
        const rca = await blindCauses(sampleRca(), from, to);
        expect(rca.error).toBeUndefined();
        expect(rca.causes).toHaveLength(MAX_CAUSES);
        // The capture's incidents first (T1's chain, T4's deadlock and chain, the replica's stall), then the others the
        // investigations explain, each group in time order, as the Root cause view lists them.
        expect(rca.causes.map((c) => c.key)).toEqual([
            "T1-blocking-20261117T140230Z",
            "T4-deadlock-20261117T142100Z",
            "T4-blocking-20261117T142135Z",
            "T4-replica-replica_lag-20261117T142200Z",
            "T1-blocking-20261117T133100Z",
            "T5-throttling-20261117T133400Z",
        ]);
        const [chain] = rca.causes;
        expect(chain.confidence).toBe("high");
        expect(chain.statement).toMatch(/^\[scheduling\]\.\[usp_assign_work_item\] \(session 63; ContosoCare\.Demo, login .+\) sat idle with its transaction open for up to \d+ s, holding X KEY lock on \[care\]\.\[work_queues\]/);
        expect(chain.statement).toContain("in 2 branches, 4 levels deep at the peak");
        expect(chain.evidence).toHaveLength(3);
        expect(chain.evidence[0]).toMatch(/^head 63: sleeping, open transactions 1, idle \d+ s, \[scheduling\]\.\[usp_assign_work_item\] \(RCA Sessions, 14:03:00 UTC\)$/);
        // One with only the telemetry says why it has no root cause.
        const telemetryOnly = rca.causes[4];
        expect(telemetryOnly.statement).toBeNull();
        expect(telemetryOnly.notes).toEqual(["T1: no RCA capture recorded for 13:31:00-13:52:00 UTC; only the telemetry (Telemetry Snapshots) is known"]);
        // The rest are counted, by target, for the Root cause page.
        expect(rca.more).toMatch(/^\d+ more incidents in these minutes \((T[1-5] \d+, )*T[1-5] \d+\), with less evidence: the Root cause page explains each\.$/);
        expect(rca.notCaptured).toContain("T2: no RCA capture recorded for 13:30:00-15:15:00 UTC; only the telemetry (Telemetry Snapshots) is known");
        // Every query behind it, each once, and none of them, nor any word of it, reads the answer key.
        expect(rca.queries.length).toBeGreaterThan(0);
        expect(new Set(rca.queries.map((q) => q.dax)).size).toBe(rca.queries.length);
        for (const q of rca.queries) expect(q.title).toMatch(/^Incident RCA: /);
        const text = JSON.stringify(rca);
        expect(answerKeyIn(text, ANSWER_KEY_MEASURES)).toBeNull();
        expect(namesAScenario(text)).toEqual([]);
        expect(text).not.toMatch(/inject/i);
    }, 30000);

    it("orders the incidents as the view does, explains at most MAX_CAUSES of them, and keeps a key's note on what it read", async () => {
        const capture = "the RCA capture";
        const telemetry = "Database Hub's telemetry";
        const listed = [
            episode("T3-cpu-20261117T133000Z", "cpu", telemetry, "2026-11-17T13:30:00Z"),
            episode("T1-blocking-20261117T135000Z", "blocking", telemetry, "2026-11-17T13:50:00Z"),
            episode("T1-blocking-20261117T140000Z", "blocking", capture, "2026-11-17T14:00:00Z"),
            episode("T5-ru-20261117T133500Z", "ru", "Azure Monitor", "2026-11-17T13:35:00Z"),
            episode("T4-blocking-20261117T134000Z", "blocking", capture, "2026-11-17T13:40:00Z"),
            episode("T2-io-20261117T133100Z", "io", telemetry, "2026-11-17T13:31:00Z"),
            episode("T3-memory-20261117T134500Z", "memory", telemetry, "2026-11-17T13:45:00Z"),
            episode("T1-errors-20261117T134100Z", "errors", "the RCA capture's errors", "2026-11-17T13:41:00Z"),
        ];
        const client = stubbed(async (name, args) => {
            if (name === "find_incidents") return result({ episodes: listed });
            const key = String(args.episodeKey);
            return result({
                rootCause: { statement: `cause of ${key}`, confidence: "medium", ruleIds: [], evidence: [{ table: "RCA Sessions", at: "2026-11-17T14:00:05Z", target: "T1", text: "row" }] },
                notCaptured: [`${key}: read as the episode from 14:00:10 UTC, in its own minutes`, "T2: no RCA capture recorded"],
            });
        });
        const rca = await blindCauses(client, from, to);
        expect(rca.causes.map((c) => c.key)).toEqual([
            "T4-blocking-20261117T134000Z",
            "T1-blocking-20261117T140000Z",
            "T5-ru-20261117T133500Z",
            "T1-errors-20261117T134100Z",
            "T1-blocking-20261117T135000Z",
            "T3-cpu-20261117T133000Z",
        ]);
        expect(client.asked).toEqual(["find_incidents", ...rca.causes.map((c) => `explain_incident ${c.key}`)]);
        // Every query behind it, each once.
        expect(rca.queries).toEqual([
            { title: "Incident RCA: RCA Sessions", dax: "EVALUATE 'RCA Sessions'" },
            { title: "Incident RCA: RCA Events", dax: "EVALUATE 'RCA Events'" },
        ]);
        expect(rca.more).toBe("2 more incidents in these minutes (T2 1, T3 1), with less evidence: the Root cause page explains each.");
        // With a root cause, only the key's own note stays beside it: the target's coverage is the list's to say.
        expect(rca.causes[0].notes).toEqual(["T4-blocking-20261117T134000Z: read as the episode from 14:00:10 UTC, in its own minutes"]);
        // The rows it cites name their target only when it isn't the incident's.
        expect(rca.causes[0].evidence).toEqual(["row (RCA Sessions, T1, 14:00:05 UTC)"]);
        expect(rca.causes[1].evidence).toEqual(["row (RCA Sessions, 14:00:05 UTC)"]);
    });

    it("says a read that failed as such, for one incident or for the list, never as no cause or nothing abnormal", async () => {
        const listed = [episode("T1-blocking-20261117T140000Z", "blocking", "the RCA capture", "2026-11-17T14:00:00Z"), episode("T4-blocking-20261117T141000Z", "blocking", "the RCA capture", "2026-11-17T14:10:00Z")];
        const one = await blindCauses(
            stubbed(async (name, args) => {
                if (name === "find_incidents") return result({ episodes: listed });
                if (args.episodeKey === listed[0].key) throw new RcaReadError([{ table: "RCA Sessions", error: new Error("The model didn't answer.") }]);
                return `No episode ${JSON.stringify(args.episodeKey)}: call find_incidents for the keys.`;
            }),
            from,
            to,
        );
        expect(one.error).toBeUndefined();
        expect(one.causes.map((c) => c.failed)).toEqual([expect.stringContaining("RCA Sessions"), 'No episode "T4-blocking-20261117T141000Z": call find_incidents for the keys.']);
        expect(one.causes.every((c) => c.statement === null && c.confidence === null)).toBe(true);

        const thrown = await blindCauses(stubbed(async () => Promise.reject(new RcaReadError([{ table: "Telemetry Snapshots (T1's bins)", error: new Error("429") }]))), from, to);
        expect(thrown).toMatchObject({ causes: [], error: expect.stringContaining("Telemetry Snapshots (T1's bins)") });
        expect(thrown.none).toBeUndefined();
        const refused = await blindCauses(stubbed(async () => "from and to must be times, with from before to."), from, to);
        expect(refused).toMatchObject({ causes: [], error: "from and to must be times, with from before to." });
    });

    it("words an empty list as the view does, in UTC: nothing abnormal only when every read was whole", async () => {
        const whole = await blindCauses(stubbed(async () => result({ details: { nothingAbnormal: true } })), from, to);
        expect(whole).toMatchObject({ causes: [], none: "Nothing abnormal in these minutes: the detector found no episode." });
        expect(whole.more).toBeUndefined();
        const stopped = await blindCauses(stubbed(async () => result({ details: { nothingAbnormal: false, readStoppedAt: "2026-11-17T14:10:30Z" } })), from, to);
        expect(stopped.none).toBe("Nothing abnormal up to 14:10 UTC, where the read stopped: the detector found no episode there, and what came after it wasn't read.");
    });

    it("explains no further incident once it's stopped, so a closed dialog spends no more of the viewer's queries", async () => {
        const stop = new AbortController();
        const listed = ["T1-blocking-20261117T140000Z", "T4-blocking-20261117T141000Z", "T4-deadlock-20261117T141100Z"].map((key, i) => episode(key, key.split("-")[1], "the RCA capture", `2026-11-17T14:${10 * i}0:00Z`));
        const client = stubbed(async (name) => {
            if (name === "find_incidents") return result({ episodes: listed });
            stop.abort();
            return result({});
        });
        await blindCauses(client, from, to, stop.signal);
        expect(client.asked).toEqual(["find_incidents", "explain_incident T1-blocking-20261117T140000Z"]);
    });
});
