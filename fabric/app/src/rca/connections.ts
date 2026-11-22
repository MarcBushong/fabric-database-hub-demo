// Why T4's client connections came close to their limit (ADR 0031), from what the capture and Azure Monitor recorded:
// the sentinel's counts by state against max_connections less the reserved slots (RCA-PG-10: every 30 s, every 10 s at
// 80 % of the limit or more), the sessions the capture sampled in those minutes (RCA-PG-01, only while a client waits on a
// lock), and Azure Monitor's failed connections (connections_failed, a total per interval): PostgreSQL refuses a
// connection past the limit (SQLSTATE 53300) and doesn't queue it, so a refused client never reaches the server's views.
// The rules, by what held the slots:
//   CONN-LOCK-WAIT      many waited on a lock: the connections piled up behind a blocker (explain_locking names it)
//   CONN-IDLE-IN-TX     many sat idle in a transaction: the application left transactions open
//   CONN-IDLE           most sat idle: clients kept connections open without using them
//   CONN-ACTIVE         most ran a query: the workload's own concurrency filled the slots
//   CONN-MIXED          no state held most of them
//   CONN-STATES-UNKNOWN the counts by state weren't captured, only the total
// Live, 2026-11-21: a surge to the limit had no explanation at all, since only the errors were read for it, and none was
// refused. https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW,
// https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-limits

import { recommend } from "./catalog";
import { hhmmss, iso, metricIn, plural, type Confidence, type EvidenceRef, type Finding, type MetricPoint, type RcaTarget, type Recommendation, type ResourcePoint, type SessionSample } from "./types";

/** The share of the limit at which the capture watches every 10 s, and the detector opens an episode. */
export const CONNECTION_LEVEL = 0.8;
const FAILED = "connections_failed";

export interface ConnectionSample {
    at: Date;
    total: number;
    active?: number;
    idle?: number;
    idleInTransaction?: number;
    waitingLock?: number;
    maxConnections?: number;
    reserved?: number;
}

export interface ConnectionAnalysis {
    findings: Finding[];
    rootCause: { statement: string; confidence: Confidence; ruleIds: string[]; evidence: EvidenceRef[] } | null;
    recommendations: Recommendation[];
    nextSteps: string[];
    notCaptured: string[];
    details: Record<string, unknown>;
}

/** RCA-PG-10's rows for a target, one sample per capture time, oldest first. */
export function connectionSamples(resource: readonly ResourcePoint[], target: RcaTarget, from: Date, to: Date): ConnectionSample[] {
    const byTime = new Map<number, Map<string, number>>();
    for (const r of resource) {
        if (r.target !== target || r.source !== "RCA-PG-10" || r.at < from || r.at > to) continue;
        const row = byTime.get(r.at.getTime()) ?? new Map<string, number>();
        row.set(r.metric, r.value);
        byTime.set(r.at.getTime(), row);
    }
    return [...byTime.entries()]
        .filter(([, row]) => row.has("connections_total"))
        .sort(([a], [b]) => a - b)
        .map(([t, row]) => ({
            at: new Date(t),
            total: row.get("connections_total") as number,
            active: row.get("connections_active"),
            idle: row.get("connections_idle"),
            idleInTransaction: row.get("connections_idle_in_transaction"),
            waitingLock: row.get("connections_waiting_lock"),
            maxConnections: row.get("max_connections"),
            reserved: row.get("reserved_connections"),
        }));
}

/** "5 min 10 s", "40 s". */
function span(ms: number): string {
    const s = Math.round(ms / 1000);
    return s >= 60 ? `${Math.floor(s / 60)} min${s % 60 ? ` ${s % 60} s` : ""}` : `${s} s`;
}

const hhmm = (d: Date) => hhmmss(d).slice(0, 5);

export function analyzeConnections(input: { target: RcaTarget; from: Date; to: Date; resource: readonly ResourcePoint[]; sessions: readonly SessionSample[]; metrics: readonly MetricPoint[] }): ConnectionAnalysis {
    const { target, from, to } = input;
    const notCaptured: string[] = [];
    const samples = connectionSamples(input.resource, target, from, to);

    // Failed connections: only Azure Monitor counts them. Each point stands for its whole interval.
    const failed = input.metrics.filter((m) => m.target === target && m.metric === FAILED && m.value !== null && metricIn(m, from, to)).sort((a, b) => a.at.getTime() - b.at.getTime());
    const refused = failed.reduce((n, m) => n + (m.value ?? 0), 0);
    const intervalEnd = (m: MetricPoint) => new Date(m.at.getTime() + (m.intervalMs ?? 0));
    const intervals = failed.length === 0 ? "" : `${failed.length === 1 ? "its interval" : `its ${failed.length} intervals`} from ${hhmm(failed[0].at)} to ${hhmm(intervalEnd(failed[failed.length - 1]))} UTC`;
    const refusedText = failed.length === 0
        ? null
        : refused > 0
          ? `Azure Monitor counted ${plural(refused, "failed connection")} in ${intervals}: with every slot taken, PostgreSQL refuses a new connection (SQLSTATE 53300, too many clients) rather than queue it.`
          : // Only what's measured (the review of 4e2c65ed): Learn documents connections_failed as the number of failed connections, not as the refusals at the limit, and live the capture saw every slot taken while it counted none.
            `Azure Monitor counted no failed connection in ${failed.length === 1 ? "" : "any of "}${intervals}.`;
    if (failed.length === 0) notCaptured.push(`${target}: Azure Monitor's failed connections aren't in the history for ${hhmmss(from)}-${hhmmss(to)} UTC, so whether a client was refused isn't known.`);
    const failedRefs: EvidenceRef[] = failed.filter((m) => (m.value ?? 0) > 0).slice(0, 2).map((m) => ({ table: "Telemetry Snapshots", at: iso(m.at), target, text: `${plural(m.value ?? 0, "failed connection")} from ${hhmm(m.at)} to ${hhmm(intervalEnd(m))} UTC (Azure Monitor)` }));

    if (samples.length === 0) {
        notCaptured.push(`${target}: the capture's connection counts (RCA-PG-10) aren't in the history for ${hhmmss(from)}-${hhmmss(to)} UTC, so how many connections there were, and in what state, isn't known.`);
        return { findings: [], rootCause: null, recommendations: [], nextSteps: [], notCaptured, details: { refused: failed.length ? refused : null } };
    }

    const peak = samples.reduce((best, s) => (s.total > best.total ? s : best));
    const maxConnections = peak.maxConnections ?? samples.find((s) => s.maxConnections !== undefined)?.maxConnections;
    const reserved = peak.reserved ?? samples.find((s) => s.reserved !== undefined)?.reserved ?? 0;
    const limit = maxConnections !== undefined && maxConnections - reserved > 0 ? maxConnections - reserved : null;
    const atLevel = limit ? samples.filter((s) => s.total >= CONNECTION_LEVEL * limit) : [];
    const watched = atLevel.length ? atLevel : samples;
    const first = watched[0];
    const last = watched[watched.length - 1];
    const ref = (s: ConnectionSample, text: string): EvidenceRef => ({ table: "RCA Resource", at: iso(s.at), target, text });

    const limitText = limit !== null
        ? `${peak.total} of the ${limit} slots clients can use (max_connections ${maxConnections} less ${reserved} reserved)`
        : `${peak.total} client connections (max_connections wasn't captured)`;
    const share = limit ? Math.round((100 * peak.total) / limit) : null;
    const reached = `${target}'s client connections reached ${limitText} at ${hhmmss(peak.at)} UTC`;
    const held = atLevel.length
        ? `, and stayed at ${Math.round(CONNECTION_LEVEL * 100)} % of the limit or more in ${plural(atLevel.length, "sample")} between ${hhmmss(first.at)} and ${hhmmss(last.at)} UTC (${span(last.at.getTime() - first.at.getTime())})`
        : "";

    // What held the slots: the peak's states, and the least of each across the samples at the level. RCA-PG-10 counts a
    // client waiting on a lock as active too (it's running the statement that waits).
    const states = peak.active !== undefined && peak.idle !== undefined;
    const least = (key: "idle" | "idleInTransaction" | "waitingLock" | "active") => Math.min(...watched.map((s) => s[key] ?? 0));
    const active = peak.active ?? 0;
    const idle = peak.idle ?? 0;
    const idleInTx = peak.idleInTransaction ?? 0;
    const waiting = peak.waitingLock ?? 0;
    const phrase = (n: number, some: string) => (n === 0 ? `none ${some}` : `${n} ${some}`);
    const running = phrase(Math.max(0, active - waiting), "ran a query");
    const idleText = phrase(idle, "sat idle");
    const idleInTxText = phrase(idleInTx, "sat idle in a transaction");
    const waitingText = phrase(waiting, "waited on a lock");

    let ruleId: string;
    let cause: string;
    let confidence: Confidence;
    let ids: string[];
    let nextSteps: string[];
    const consistent = (key: "idle" | "idleInTransaction" | "waitingLock" | "active", part: number) => watched.filter((s) => (s[key] ?? 0) >= part * s.total).length >= 0.8 * watched.length;
    if (waiting >= Math.max(3, 0.25 * peak.total)) {
        ruleId = "CONN-LOCK-WAIT";
        cause = `${waiting} of the ${peak.total} at the peak waited on a lock (${running}, ${idleText}, ${idleInTxText}): the connections piled up behind a blocker, each holding its slot while it waited. explain_locking for the same minutes names the blocker.`;
        confidence = consistent("waitingLock", 0.25) ? "high" : "medium";
        ids = ["PG-LOCK-TIMEOUT", "PG-IDLE-TIMEOUT", "PG-POOL"];
        nextSteps = [`explain_locking for ${target} from ${hhmmss(first.at)} to ${hhmmss(last.at)} UTC: the blocker the connections waited behind.`];
    } else if (idleInTx >= Math.max(3, 0.25 * peak.total)) {
        ruleId = "CONN-IDLE-IN-TX";
        cause = `${idleInTx} of the ${peak.total} at the peak sat idle in a transaction, and at least ${least("idleInTransaction")} in every sample (${running}, ${idleText}, ${waitingText}): the application opened transactions and left them open, and each kept its slot.`;
        confidence = consistent("idleInTransaction", 0.25) ? "high" : "medium";
        ids = ["PG-IDLE-TIMEOUT", "PG-POOL"];
        nextSteps = ["While it happens, find the code path that leaves its transaction open: pg_stat_activity's sessions in the state 'idle in transaction', with their application_name, usename, and the time since state_change."];
    } else if (states && idle >= 0.5 * peak.total) {
        ruleId = "CONN-IDLE";
        cause = `Most of them sat idle: ${idle} of the ${peak.total} at the peak, and at least ${least("idle")} in every sample (${running}, ${idleInTxText}, ${waitingText}). Clients kept connections open without using them, so the slots filled with idle connections, not with work.`;
        confidence = consistent("idle", 0.5) ? "high" : "medium";
        ids = ["PG-POOL", "PG-IDLE-SESSION-TIMEOUT"];
        nextSteps = ["While it happens, list who holds the idle connections: pg_stat_activity grouped by application_name, usename, client_addr, and state, with the longest time since state_change.", "Size each application's pool to the queries it runs at once, below the limit, and let it close the connections it doesn't use."];
    } else if (states && active >= 0.5 * peak.total) {
        ruleId = "CONN-ACTIVE";
        cause = `Most of them ran a query: ${active} of the ${peak.total} at the peak${waiting ? `, ${waiting} of them waiting on a lock` : ""} (${idleText}, ${idleInTxText}). The workload's own concurrency filled the slots.`;
        confidence = consistent("active", 0.5) ? "high" : "medium";
        ids = ["PG-POOL", "PG-CPU"];
        nextSteps = [`Compare ${target}'s CPU for the same minutes (Telemetry Snapshots): queries running at once compete for it.`];
    } else if (states) {
        ruleId = "CONN-MIXED";
        cause = `No one state held most of them at the peak: ${running}, ${idleText}, ${idleInTxText}, and ${waitingText}.`;
        confidence = "low";
        ids = ["PG-POOL"];
        nextSteps = ["While it happens, list who holds the connections: pg_stat_activity grouped by application_name, usename, client_addr, and state."];
    } else {
        ruleId = "CONN-STATES-UNKNOWN";
        cause = "The capture counted them, but not by state, so what held them isn't known.";
        confidence = "low";
        ids = ["PG-POOL"];
        nextSteps = ["While it happens, list who holds the connections: pg_stat_activity grouped by application_name, usename, client_addr, and state."];
        notCaptured.push(`${target}: the connections' states (active, idle, idle in a transaction) weren't captured, only their total.`);
    }
    if (refused > 0) ids.push("PG-MAXCONN");

    // Who held them: only the sessions the capture sampled, which are the ones not idle, and only while a client waited on a lock.
    const seen = input.sessions.filter((s) => s.target === target && s.capturedAt >= from && s.capturedAt <= to && (s.backendType === undefined || s.backendType === "client backend"));
    let who = "";
    if (seen.length > 0) {
        const groups = new Map<string, { sessions: Set<number>; idleMs: number }>();
        for (const s of seen) {
            const key = [s.program ?? "an application the capture didn't name", s.login && `as ${s.login}`].filter(Boolean).join(" ");
            const g = groups.get(key) ?? { sessions: new Set<number>(), idleMs: 0 };
            g.sessions.add(s.session);
            if (s.status.startsWith("idle in transaction")) g.idleMs = Math.max(g.idleMs, s.idleMs ?? 0);
            groups.set(key, g);
        }
        who = ` Of the sessions the capture sampled (only those not idle), ${[...groups.entries()].map(([k, g]) => `${plural(g.sessions.size, "session")} came from ${k}${g.idleMs ? `, idle in a transaction for up to ${span(g.idleMs)}` : ""}`).join("; ")}.`;
        notCaptured.push(`${target}: who held the idle connections isn't captured: the capture samples sessions (RCA-PG-01) that aren't idle, and only while a client waits on a lock; RCA-PG-10 counts the rest by state.`);
    } else {
        notCaptured.push(`${target}: who held the connections (their application, user, and client address) and how long each sat idle aren't captured for these minutes: RCA-PG-10 counts connections by state, and the capture samples sessions (RCA-PG-01) only while a client waits on a lock, which none did here.`);
    }

    const statement = `${reached}${held}. ${cause}${who}${refusedText ? ` ${refusedText}` : ""}`;
    const evidence: EvidenceRef[] = [
        ref(peak, `${peak.total} client connections${limit ? ` of ${limit} (${share} %)` : ""}: ${active} active, ${idle} idle, ${idleInTx} idle in a transaction, ${waiting} waiting on a lock`),
        ...(first.at.getTime() !== peak.at.getTime() ? [ref(first, `${first.total} client connections`)] : []),
        ...(last.at.getTime() !== peak.at.getTime() ? [ref(last, `${last.total} client connections`)] : []),
        ...failedRefs,
    ];
    const title = `${target}: ${limit ? `${share} % of the connection limit` : `${peak.total} connections`} at ${hhmmss(peak.at)} UTC`;
    return {
        findings: [{ ruleId, target, severity: share !== null && share >= 100 ? "critical" : "warning", title, detail: statement, evidence }],
        rootCause: { statement, confidence, ruleIds: [ruleId], evidence },
        recommendations: recommend(...ids),
        nextSteps: [...nextSteps, `Compare with Database Hub's PostgreSQL dashboard for ${target} (Connections and Failed connections) for the same minutes.`],
        notCaptured,
        details: {
            limit,
            maxConnections: maxConnections ?? null,
            reserved,
            peak: { at: iso(peak.at), total: peak.total, active, idle, idleInTransaction: idleInTx, waitingLock: waiting },
            samples: samples.map((s) => ({ at: iso(s.at), total: s.total, active: s.active ?? null, idle: s.idle ?? null, idleInTransaction: s.idleInTransaction ?? null, waitingLock: s.waitingLock ?? null })),
            refused: failed.length ? refused : null,
        },
    };
}
