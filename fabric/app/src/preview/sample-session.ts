// The preview's latest session, shaped exactly as the history records one (ADR 0026, ADR 0030): the control's plan in
// Scenario Runs at the session's end (its row, and one row per beat on T1 to T3, from the showcase profile's 30-minute
// rotation), one-minute telemetry bins with their wait categories, the Database Agent beat on T3, a recorded incident
// window per beat, and T4's and T5's Azure Monitor captures. Made up: no IDs, URLs, or accounts from a real deployment.
// T2's IO pressure in the third cycle shows no signal on purpose, so the scoreboard has a fault it didn't catch.

import type { QuerySpec } from "@/data/queries";
import type { Row } from "@/data/query-client";

const MIN = 60000;
export const SESSION_ID = "7f3a9c21-1111-1111-1111-111111111111";
export const SESSION_KEY = `session:${SESSION_ID}`;
/** 17 Nov 2026, 13:30 to 15:00 UTC: three of the showcase's 30-minute cycles. */
export const SESSION_START = Date.UTC(2026, 10, 17, 13, 30);
export const SESSION_END = SESSION_START + 90 * MIN;
/** The one-minute bins cover the session with room on each side; the week's 15-minute bins cover the rest. */
const BINS_FROM = SESSION_START - 15 * MIN;
const BINS_TO = SESSION_END + 30 * MIN;

const iso = (ms: number) => new Date(ms).toISOString().slice(0, 19);
const round = (v: number, d = 1) => Math.round(v * 10 ** d) / 10 ** d;

type Sql = "T1" | "T2" | "T3";

interface Beat {
    target: Sql;
    scenario: string;
    start: number;
    end: number;
    /** Minutes after the injection its signal shows in the samples; null: it never shows. */
    delay: number | null;
    agent?: { regress: number; respond: number };
}

/** The showcase's beats on T1 to T3 for three cycles (scenarios/activity-profiles.json). */
function plannedBeats(): Beat[] {
    const out: Beat[] = [];
    const add = (target: Sql, scenario: string, cycle: number, from: number, to: number, delay: number | null = target === "T2" ? 2 : 1) => {
        const base = SESSION_START + cycle * 30 * MIN;
        out.push({ target, scenario, start: base + from * MIN, end: base + to * MIN, delay });
    };
    for (let c = 0; c < 3; c++) {
        add("T1", "blocking-chain", c, 0, 10);
        add("T1", "log-flush-waits", c, 2, 10);
        add("T1", "deadlock-storm", c, 11, 21);
        add("T1", "cpu-pressure", c, 22, 29);
        add("T2", "cpu-pressure", c, 2, 14);
        add("T2", "memory-grant-pressure", c, 10, 18);
        add("T2", "io-pressure", c, 18, 26, c === 2 ? null : 2);
        add("T2", c === 1 ? "tempdb-contention" : "parallel-scans", c, 22, 29);
    }
    add("T3", "resource-governance", 0, 1, 13);
    add("T3", "locking-blocking", 0, 13, 23);
    add("T3", "slow-consumer", 0, 15, 25);
    add("T3", "log-rate-pressure", 0, 25, 30);
    add("T3", "missing-index", 1, 1, 10);
    add("T3", "deadlock-storm", 1, 13, 25);
    add("T3", "resource-governance", 2, 5, 15);
    add("T3", "locking-blocking", 2, 13, 23);
    add("T3", "plan-regression", 2, 15, 25);
    add("T3", "log-rate-pressure", 2, 25, 30);
    // The Database Agent beat: the plan regresses 3 minutes in; the run forces the last good plan at 85 % of the run.
    out.push({ target: "T3", scenario: "plan-regression", start: SESSION_START + 30 * MIN, end: SESSION_START + 60 * MIN, delay: 1, agent: { regress: SESSION_START + 33 * MIN, respond: SESSION_START + 56 * MIN } });
    return out.sort((a, b) => a.start - b.start || a.target.localeCompare(b.target));
}

let cachedBeats: Beat[] | null = null;
function beats(): Beat[] {
    cachedBeats ??= plannedBeats();
    return cachedBeats;
}

const FAMILY: Record<string, string> = {
    "blocking-chain": "blocking",
    "locking-blocking": "blocking",
    "deadlock-storm": "blocking",
    "log-flush-waits": "tran_log",
    "cpu-pressure": "cpu",
    "resource-governance": "cpu",
    "plan-regression": "cpu",
    "missing-index": "cpu",
    "memory-grant-pressure": "memory",
    "io-pressure": "io",
    "tempdb-contention": "latch",
    "parallel-scans": "parallelism",
    "slow-consumer": "network",
    "log-rate-pressure": "log_rate",
};

const BASE: Record<Sql, { cpu: number; batch: number; sessions: number; io: number; mb: number }> = {
    T1: { cpu: 18, batch: 430, sessions: 9, io: 0.4, mb: 4 },
    T2: { cpu: 12, batch: 240, sessions: 6, io: 0.6, mb: 6 },
    T3: { cpu: 26, batch: 1030, sessions: 14, io: 0.3, mb: 3 },
};

interface SessionBin {
    at: number;
    target: Sql;
    cpu: number;
    blocked: number;
    lockWaitS: number;
    bufferIoS: number;
    logRateS: number;
    waitS: number;
    ioMb: number;
    batch: number;
    sessions: number;
    waits: Record<string, number>;
}

function wobble(at: number, target: Sql): number {
    const x = Math.sin(at / 97000 + target.charCodeAt(1)) * 0.5 + Math.sin(at / 31000) * 0.5;
    return 0.92 + 0.08 * x;
}

let cachedBins: SessionBin[] | null = null;

/** One-minute bins of T1 to T3 around the session, each with its wait categories. */
export function sessionBins(): SessionBin[] {
    if (cachedBins) return cachedBins;
    const out: SessionBin[] = [];
    for (let at = BINS_FROM; at < BINS_TO; at += MIN) {
        for (const target of ["T1", "T2", "T3"] as const) {
            const b = BASE[target];
            const n = wobble(at, target);
            const waits: Record<string, number> = {
                CPU: 2.4 * n,
                Lock: 0.05,
                "Buffer IO (PAGEIOLATCH)": b.io * n,
                "Tran Log IO": 0.3 * n,
                Memory: 0.1,
                "Buffer Latch": 0.1,
                "Network IO": 0.2 * n,
                Parallelism: 0.2,
                "Worker Thread": 0.3 * n,
            };
            if (target === "T3") waits["Log Rate Governor"] = 0.05;
            let cpu = b.cpu * n;
            let blocked = 0;
            for (const beat of beats().filter((x) => x.target === target && x.delay !== null)) {
                const family = FAMILY[beat.scenario];
                if (beat.agent) {
                    if (at >= beat.agent.regress + MIN && at <= beat.agent.respond) {
                        cpu = Math.max(cpu, 84 * n);
                        waits.CPU += 22;
                    } else if (at > beat.agent.respond && at < beat.end + 6 * MIN) cpu = Math.min(cpu, 22 * n);
                    continue;
                }
                const on = at >= beat.start + (beat.delay as number) * MIN && at < beat.end + MIN;
                if (!on) continue;
                if (family === "cpu") {
                    const lift = beat.scenario === "plan-regression" ? 30 : beat.scenario === "missing-index" ? 38 : 58;
                    cpu = Math.min(99, Math.max(cpu, (b.cpu + lift) * n));
                    waits.CPU += 18;
                    if (beat.scenario === "missing-index") waits["Buffer IO (PAGEIOLATCH)"] += 3;
                } else if (family === "blocking") {
                    blocked = Math.max(blocked, beat.scenario === "deadlock-storm" ? 4 : 7);
                    waits.Lock += 38 * n;
                } else if (family === "tran_log") waits["Tran Log IO"] += 24 * n;
                else if (family === "memory") waits.Memory += 31 * n;
                else if (family === "io") waits["Buffer IO (PAGEIOLATCH)"] += 6.5 * n;
                else if (family === "latch") waits["Buffer Latch"] += 27 * n;
                else if (family === "network") waits["Network IO"] += 21 * n;
                else if (family === "parallelism") {
                    waits.Parallelism += 16 * n;
                    cpu = Math.min(99, Math.max(cpu, (b.cpu + 22) * n));
                } else if (family === "log_rate") waits["Log Rate Governor"] = (waits["Log Rate Governor"] ?? 0) + 33 * n;
            }
            for (const key of Object.keys(waits)) waits[key] = round(waits[key], 2);
            const waitS = round(Object.values(waits).reduce((a, v) => a + v, 0), 2);
            out.push({
                at,
                target,
                cpu: round(cpu),
                blocked,
                lockWaitS: waits.Lock,
                bufferIoS: waits["Buffer IO (PAGEIOLATCH)"],
                logRateS: waits["Log Rate Governor"] ?? 0,
                waitS,
                ioMb: round(b.mb * n + waits["Buffer IO (PAGEIOLATCH)"] * 9),
                batch: Math.round(b.batch * n),
                sessions: Math.round(b.sessions * n + (blocked > 0 ? 8 : 0)),
                waits,
            });
        }
    }
    cachedBins = out;
    return out;
}

const binRow = (b: SessionBin, withTarget: boolean): Row => ({
    "Bucket UTC": iso(b.at),
    ...(withTarget ? { "Target Key": b.target } : {}),
    Cpu: b.cpu,
    Blocked: b.blocked,
    LockWaitS: b.lockWaitS,
    BufferIoS: b.bufferIoS,
    LogRateS: b.logRateS,
    WaitS: b.waitS,
    IoMb: b.ioMb,
    Batch: b.batch,
    Sessions: b.sessions,
});

const beatId = (i: number) => `${SESSION_KEY}:${String(i).padStart(2, "0")}`;

/** The session's Scenario Runs rows, as NB_DatabaseHub_LiveActivity writes them at its end. */
export function sessionRuns(): Row[] {
    const short = SESSION_ID.slice(0, 8);
    const base = { RequestedAt: iso(SESSION_START), Intensity: null, Concurrency: null, Dispatch: "session", Status: "Pass" };
    return [
        { ...base, RequestId: SESSION_KEY, TargetKey: "all", Profile: "session", DurationMin: 90, Message: `Session ${short}: NB_DatabaseHub_Control's Run all (ADR 0026).`, WindowStart: iso(SESSION_START), WindowEnd: iso(SESSION_END) },
        ...beats().map((beat, i) => ({
            ...base,
            RequestId: beatId(i),
            TargetKey: beat.target,
            Profile: `incident:${beat.scenario}`,
            DurationMin: Math.round((beat.end - beat.start) / MIN),
            Message: beat.agent
                ? `Session ${short}'s Database Agent beat: the plan regresses at ${iso(beat.agent.regress).slice(11, 16)} UTC; the run's response forces the last good plan at ${iso(beat.agent.respond).slice(11, 16)} UTC.`
                : `Session ${short}'s showcase beat.`,
            WindowStart: iso(beat.start),
            WindowEnd: iso(beat.end),
        })),
    ];
}

/** The Database Agent beat's database_agent finding. */
export function sessionAgentLoop(): Row[] {
    const index = beats().findIndex((b) => b.agent);
    const beat = beats()[index];
    if (!beat?.agent) return [];
    const hhmm = (ms: number) => iso(ms).slice(11, 16);
    return [
        {
            FindingId: `database_agent.T3.${beatId(index)}`,
            TargetKey: "T3",
            Status: "Pass",
            Finding: `Database Agent loop on T3: the plan regressed at ${hhmm(beat.agent.regress)} UTC and the run's response forced the last good plan at ${hhmm(beat.agent.respond)} UTC; T3's CPU fell from 84% to 22%.`,
            Evidence: JSON.stringify({ sessionId: SESSION_ID, regressUtc: `${iso(beat.agent.regress)}Z`, respondUtc: `${iso(beat.agent.respond)}Z`, cpuBeforePercent: 84, cpuAfterPercent: 22 }),
            RequestId: beatId(index),
            WindowStart: iso(beat.start),
            WindowEnd: iso(beat.end),
            CapturedAt: iso(SESSION_END + 6 * MIN),
        },
    ];
}

const FAMILY_SHORT: Record<string, string> = { cpu: "cpu", blocking: "blocking", io: "io", log_rate: "log_rate", tran_log: "tran_log", memory: "memory", latch: "latch", network: "network", parallelism: "parallelism" };

/** A recorded incident window per beat, with the notebook's expected-signal verdict. */
export function sessionIncidentWindows(): Row[] {
    return beats().map((beat, i) => {
        const family = FAMILY_SHORT[FAMILY[beat.scenario]] ?? "cpu";
        return {
            Key: `request:${beatId(i)}`,
            Label: `${beat.target} ${beat.scenario}`,
            Source: "Recorded request",
            TargetKey: beat.target,
            Scenario: beat.scenario,
            Family: family,
            Start: iso(beat.start),
            End: iso(beat.end),
            DurationMin: (beat.end - beat.start) / MIN,
            PeakValue: null,
            PeakUnit: "",
            Verdict: beat.delay === null ? "Warning" : "Pass",
        };
    });
}

/** T4 and its read replica, every 5 minutes through the session: a connection surge, CPU, and the replica's lag in the even cycle. */
export function sessionPostgresSeries(): Row[] {
    const out: Row[] = [];
    const points = 19;
    const at = (i: number) => SESSION_START + i * 5 * MIN;
    const inCycle = (i: number) => (i * 5) % 30;
    const series: Array<[string, string, (i: number) => number]> = [
        ["T4-replica", "physical_replication_delay_in_seconds", (i) => ({ 10: 96.5, 11: 241.4, 12: 18 })[i] ?? 2 + (i % 3)],
        ["T4", "cpu_percent", (i) => (inCycle(i) >= 10 && inCycle(i) < 20 ? 84 + (i % 3) * 3 : 36 + (i % 4) * 3)],
        ["T4-replica", "cpu_percent", (i) => 9 + (i % 3) * 2],
        ["T4", "memory_percent", (i) => 31 + (i % 2)],
        ["T4", "active_connections", (i) => (inCycle(i) < 10 ? 58 : 13 + (i % 3))],
        ["T4-replica", "active_connections", () => 1],
        ["T4", "connections_failed", (i) => (i === 1 ? 3 : i === 7 ? 1 : 0)],
    ];
    for (const [target, metric, f] of series) {
        for (let i = 0; i < points; i++) {
            out.push({
                Bucket: iso(at(i)),
                TargetKey: target,
                ResourceName: target === "T4" ? "pgflex01-sample" : "pgreplica01-sample",
                Metric: metric,
                Value: round(f(i)),
                Unit: "",
                WindowStart: iso(SESSION_START),
                WindowEnd: iso(SESSION_END + 2 * MIN),
                CapturedAt: iso(SESSION_END + 6 * MIN),
            });
        }
    }
    return out;
}

export function sessionPostgresFindings(): Row[] {
    const at = iso(SESSION_END + 6 * MIN);
    return [
        {
            FindingId: "postgresql.T4.capture",
            TargetKey: "T4",
            Status: "Pass",
            StatusSort: 4,
            Finding: "Azure Monitor metrics of T4 pgflex01-sample (Standard_D2ds_v5) and its read replica pgreplica01-sample (Standard_D2ds_v5) from 17 Nov 13:30 to 15:02 UTC, every 5 minutes.",
            Evidence: '{"intervalMinutes": 5, "servers": [{"resourceName": "pgflex01-sample", "role": "primary", "sku": "Standard_D2ds_v5", "target": "T4"}, {"resourceName": "pgreplica01-sample", "role": "replica", "sku": "Standard_D2ds_v5", "target": "T4-replica"}]}',
            CapturedAt: at,
        },
        { FindingId: "postgresql.T4-replica.lag", TargetKey: "T4-replica", Status: "Warning", StatusSort: 3, Finding: "Read replica lag on pgreplica01-sample peaked at 241.4 s at 14:25 UTC (a Warning at 60 s or more).", Evidence: '{"peakSeconds": 241.4}', CapturedAt: at },
        { FindingId: "postgresql.T4.connections_failed", TargetKey: "T4", Status: "Warning", StatusSort: 3, Finding: "Failed connections on T4 (pgflex01-sample): 4 from 13:30 to 14:10 UTC.", Evidence: '{"total": 4}', CapturedAt: at },
    ];
}

/** T5's throttling episodes from its captured series: one per ru-storm wave, with its 429s, its requests, and its recovery. */
export function sessionCosmosFindings(series: readonly Row[]): Row[] {
    const at = iso(SESSION_END + 6 * MIN);
    const by = (metric: string) => new Map(series.filter((r) => r.Metric === metric).map((r) => [Date.parse(`${String(r.Bucket)}Z`), Number(r.Value)]));
    const ru = by("NormalizedRUConsumption");
    const throttled = by("ThrottledRequests");
    const requests = by("TotalRequests");
    const minutes = [...ru.keys()].sort((a, b) => a - b);
    const hot = (t: number) => (throttled.get(t) ?? 0) > 0 || (ru.get(t) ?? 0) >= 100;
    const episodes: Array<{ from: number; to: number }> = [];
    for (const t of minutes) {
        if (!hot(t)) continue;
        const last = episodes[episodes.length - 1];
        if (last && t - last.to <= MIN) last.to = t + MIN;
        else episodes.push({ from: t, to: t + MIN });
    }
    let throttledAll = 0;
    const rows: Row[] = episodes.map((e) => {
        const span = minutes.filter((t) => t >= e.from && t < e.to);
        const t429 = span.reduce((a, t) => a + (throttled.get(t) ?? 0), 0);
        const req = span.reduce((a, t) => a + (requests.get(t) ?? 0), 0);
        throttledAll += t429;
        const hhmm = (ms: number) => iso(ms).slice(11, 16);
        return {
            FindingId: `cosmosdb.T5.throttle.${iso(e.from).replace(/[-:]/g, "").slice(0, 13)}`,
            TargetKey: "T5",
            Status: "Warning",
            StatusSort: 3,
            Finding: `Normalized RU consumption on T5 reached 100% with ${t429.toLocaleString("en-US")} throttled requests (429s) of ${req.toLocaleString("en-US")} requests between ${hhmm(e.from)} and ${hhmm(e.to)} UTC; the throttling stopped at ${hhmm(e.to)} UTC, and normalized RU fell back from ${hhmm(e.to)} UTC.`,
            Evidence: JSON.stringify({ throttled: t429, requests: req, peakNormalizedRuPercent: 100, stopped: true, recoveredAtUtc: `${iso(e.to)}Z` }),
            WindowStart: iso(e.from),
            WindowEnd: iso(e.to),
            CapturedAt: at,
        };
    });
    const total = [...requests.values()].reduce((a, v) => a + v, 0);
    const last = episodes[episodes.length - 1];
    return [
        {
            FindingId: "cosmosdb.T5.throttling",
            TargetKey: "T5",
            Status: "Warning",
            StatusSort: 3,
            Finding: `Normalized RU consumption on T5 cosmos01-sample reached 100% with ${throttledAll.toLocaleString("en-US")} throttled requests (429s) of ${total.toLocaleString("en-US")} requests in ${episodes.length} episodes between 13:33 and ${last ? iso(last.to).slice(11, 16) : "15:00"} UTC.`,
            Evidence: JSON.stringify({ throttled: throttledAll, requests: total, episodes: episodes.length }),
            WindowStart: iso(SESSION_START),
            WindowEnd: iso(SESSION_END),
            CapturedAt: at,
        },
        ...rows,
        { FindingId: "cosmosdb.T5.recovery", TargetKey: "T5", Status: "Pass", StatusSort: 4, Finding: `T5 cosmos01-sample was back at its baseline before the capture's end: its last throttling stopped at ${last ? iso(last.to).slice(11, 16) : "–"} UTC, with no 429s after it.`, Evidence: "{}", WindowStart: last ? iso(last.from) : iso(SESSION_START), WindowEnd: iso(SESSION_END), CapturedAt: at },
        { FindingId: "cosmosdb.T5.capture", TargetKey: "T5", Status: "Pass", StatusSort: 4, Finding: "Azure Monitor metrics of T5 cosmos01-sample (400 RU/s) from 13:30 to 15:00 UTC, every minute.", Evidence: '{"intervalMinutes": 1}', WindowStart: iso(SESSION_START), WindowEnd: iso(SESSION_END), CapturedAt: at },
    ];
}

interface Filtered {
    targets: string[];
    from: number | null;
    to: number | null;
}

function filtersOf(spec: QuerySpec): Filtered {
    const p = (spec.params ?? {}) as { targets?: string[]; from?: string; to?: string };
    return {
        targets: Array.isArray(p.targets) && p.targets.length > 0 ? p.targets : ["T1", "T2", "T3"],
        from: p.from ? Date.parse(`${p.from}T00:00:00Z`) : null,
        to: p.to ? Date.parse(`${p.to}T00:00:00Z`) + 86400000 : null,
    };
}

const inBins = (at: number) => at >= BINS_FROM && at < BINS_TO;
const rowTime = (r: Row, key: string) => Date.parse(`${String(r[key])}Z`);

/**
 * The session laid over the week's sample: its one-minute bins in place of the 15-minute ones they cover, its plan in
 * Scenario Runs, its recorded incident windows, its Database Agent beat, and T4's and T5's captures from its window.
 * `base` answers a query from the week's sample.
 */
export function withSession(spec: QuerySpec, base: (spec: QuerySpec) => Row[]): Row[] {
    const replay = /^replay-(T[123])$/.exec(spec.id);
    const spot = /^spotlight-(T[123])$/.exec(spec.id);
    if (replay || spot) {
        const target = (replay ?? spot)![1];
        const p = (spec.params ?? {}) as { start?: string; end?: string };
        const from = p.start ? Date.parse(`${p.start}Z`) : 0;
        const to = p.end ? Date.parse(`${p.end}Z`) : Number.MAX_SAFE_INTEGER;
        const outside = base(spec).filter((r) => !inBins(rowTime(r, "Bucket UTC")));
        const mine = sessionBins().filter((b) => b.target === target && b.at >= from && b.at <= to);
        const inside: Row[] = replay ? mine.map((b) => binRow(b, false)) : mine.flatMap((b) => Object.entries(b.waits).map(([metric, seconds]) => ({ "Bucket UTC": iso(b.at), Metric: metric, WaitS: seconds })));
        return [...outside, ...inside].sort((a, b) => rowTime(a, "Bucket UTC") - rowTime(b, "Bucket UTC"));
    }
    const f = filtersOf(spec);
    const inWindow = (at: number) => (f.from === null || at >= f.from) && (f.to === null || at < f.to);
    switch (spec.id) {
        case "signals-per-bin": {
            const outside = base(spec).filter((r) => !inBins(rowTime(r, "Bucket UTC")));
            const inside = sessionBins()
                .filter((b) => f.targets.includes(b.target) && inWindow(b.at))
                .map((b) => binRow(b, true));
            return [...outside, ...inside].sort((a, b) => rowTime(a, "Bucket UTC") - rowTime(b, "Bucket UTC") || String(a["Target Key"]).localeCompare(String(b["Target Key"])));
        }
        case "scenario-runs": {
            const older = base(spec).filter((r) => !inBins(rowTime(r, "RequestedAt")));
            const mine = inWindow(SESSION_START) ? sessionRuns() : [];
            return [...mine, ...older];
        }
        case "incident-windows": {
            const older = base(spec).filter((r) => !inBins(rowTime(r, "Start")));
            const mine = sessionIncidentWindows().filter((r) => f.targets.includes(String(r.TargetKey)) && inWindow(rowTime(r, "Start")));
            return [...mine.reverse(), ...older];
        }
        case "agent-loop":
            return f.targets.includes("T3") && inWindow(SESSION_START) ? sessionAgentLoop() : [];
        case "postgres-series":
            return sessionPostgresSeries();
        case "postgres-findings":
            return sessionPostgresFindings();
        case "cosmos-findings":
            return sessionCosmosFindings(base({ ...spec, id: "cosmos-series" }));
        default:
            return base(spec);
    }
}
