// Why T4's client connections came close to their limit (ADR 0031), from what the capture and Azure Monitor recorded:
// the sentinel's counts by state against max_connections less the reserved slots (RCA-PG-10: every 30 s, every 10 s at
// 80 % of the limit or more), the sessions the capture sampled in those minutes (RCA-PG-01, only while a client waits on a
// lock), and Azure Monitor's failed connections (connections_failed, a total per interval). PostgreSQL refuses a
// connection past the limit (SQLSTATE 53300) and doesn't queue it, so a refused client never reaches the server's views,
// and in this demo's live check Azure Monitor's failed connections counted none of those refusals either (Final tests'
// check of 4e2c65ed: the workload recorded 48 refused attempts while the metric stayed at 0; Learn documents the metric
// only as the number of failed connections): when every slot was in use, a client connecting then would have been
// refused, and how many were isn't known.
// The rules, by what held the slots:
//   CONN-LOCK-WAIT      many waited on a lock: the connections piled up behind a blocker (explain_locking names it)
//   CONN-IDLE-IN-TX     many sat idle in a transaction: the application left transactions open
//   CONN-IDLE           most sat idle: clients kept connections open without using them
//   CONN-ACTIVE         most ran a query: the workload's own concurrency filled the slots
//   CONN-MIXED          no state held most of them
//   CONN-STATES-UNKNOWN the counts by state weren't captured, only the total
// Live, 2026-11-21: a surge to the limit had no explanation at all, since only the errors were read for it, and Azure
// Monitor counted no failed connection. https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW,
// https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-limits

import { recommend } from "./catalog";
import type { ConnectionGroup } from "./sidecar";
import { asWholeReadings, hhmmss, iso, metricIn, plural, type Confidence, type EvidenceRef, type Finding, type MetricPoint, type RcaTarget, type Recommendation, type ResourcePoint, type SessionSample } from "./types";

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

/**
 * RCA-PG-10's rows for a target, one sample per capture time, oldest first. The total counts the capture's own connection,
 * and the states leave it out (3732317d); in rows from before that, the capture's own query was one of the active. Such a
 * row is one whose active, idle, and idle in a transaction add up to the total, which a later row's can't: its active is
 * read as one less, so every row's states are the other clients'.
 */
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
        .map(([t, row]) => {
            const total = row.get("connections_total") as number;
            const active = row.get("connections_active");
            const idle = row.get("connections_idle");
            const idleInTransaction = row.get("connections_idle_in_transaction");
            const ownCounted = active !== undefined && idle !== undefined && active >= 1 && active + idle + (idleInTransaction ?? 0) === total;
            return {
                at: new Date(t),
                total,
                active: ownCounted ? active - 1 : active,
                idle,
                idleInTransaction,
                waitingLock: row.get("connections_waiting_lock"),
                maxConnections: row.get("max_connections"),
                reserved: row.get("reserved_connections"),
            };
        });
}

/** "5 min 10 s", "40 s". */
function span(ms: number): string {
    const s = Math.round(ms / 1000);
    return s >= 60 ? `${Math.floor(s / 60)} min${s % 60 ? ` ${s % 60} s` : ""}` : `${s} s`;
}

const hhmm = (d: Date) => hhmmss(d).slice(0, 5);
const sayList = (items: readonly string[]) => (items.length < 3 ? items.join(" and ") : `${items.slice(0, -1).join(", ")}, and ${items[items.length - 1]}`);

/** Where the connections fall between two waves of a surge: under half the limit (live, they fell to 8 to 10 of 35). */
export const TROUGH_SHARE = 0.5;

interface Wave {
    from: ConnectionSample;
    to: ConnectionSample;
    peak: ConnectionSample;
    /** The fewest connections between the wave before and this one; null for the first. */
    low: number | null;
}

/**
 * A surge's waves: its runs of samples at the level, apart where the connections fell under the trough between them
 * (Final tests' live check of 4e2c65ed: four waves, with drops to 8 to 10 connections, read as one surge).
 */
function wavesOf(samples: readonly ConnectionSample[], level: number, trough: number): Wave[] {
    const waves: Wave[] = [];
    let low: number | null = null;
    let fell = false;
    for (const s of samples) {
        const current = waves[waves.length - 1];
        if (s.total >= level) {
            if (current && !fell) {
                current.to = s;
                if (s.total > current.peak.total) current.peak = s;
            } else {
                waves.push({ from: s, to: s, peak: s, low: current ? low : null });
            }
            low = null;
            fell = false;
        } else if (current) {
            low = low === null ? s.total : Math.min(low, s.total);
            if (s.total < trough) fell = true;
        }
    }
    return waves;
}

/** Who held the connections, as the capture counted them in a connection episode (RCA Connections): its sentence, evidence, and details. */
export interface Holders {
    text: string;
    ref: EvidenceRef;
    details: Record<string, unknown>;
}

/**
 * Who held a target's client connections in some minutes, from the capture's counts by program, login, and state in each
 * sample of a connection episode (RCA Connections; never the capture's own connection): each group's count and how it
 * changed, how long its oldest idle connection had sat idle, the most they held together, and the groups gone by the last
 * sample. A workload run is named by its opaque token, which names nothing; another application, which the capture
 * doesn't name, as such. Null without any of its rows in the minutes.
 */
export function holdersOf(groups: readonly ConnectionGroup[], target: RcaTarget, from: Date, to: Date): Holders | null {
    const rows = groups.filter((g) => g.target === target && g.capturedAt >= from && g.capturedAt <= to).sort((a, b) => a.capturedAt.getTime() - b.capturedAt.getTime());
    if (rows.length === 0) return null;
    const times = [...new Set(rows.map((g) => g.capturedAt.getTime()))].sort((a, b) => a - b);
    const series = new Map<string, ConnectionGroup[]>();
    for (const g of rows) {
        const key = [g.program ?? "", g.runToken ?? "", g.login ?? "", g.state].join("|");
        series.set(key, [...(series.get(key) ?? []), g]);
    }
    const nameOf = (g: ConnectionGroup) => {
        const who = [g.program, g.login && `as ${g.login}`].filter(Boolean).join(", ");
        return g.runToken ? `the run with token ${g.runToken}${who ? ` (${who})` : ""}` : who || "an application the capture doesn't name";
    };
    const most = (s: readonly ConnectionGroup[]) => Math.max(...s.map((g) => g.connections));
    const ordered = [...series.values()].sort((a, b) => most(b) - most(a));
    const at = (t: number) => hhmmss(new Date(t));
    const fromTo = (a: number, b: number) => (a === b ? `at ${at(a)}` : `from ${at(a)} to ${at(b)}`);
    const parts = ordered.map((s) => {
        const first = s[0];
        const end = s[s.length - 1];
        const top = most(s);
        const atTop = s.filter((g) => g.connections === top).map((g) => g.capturedAt.getTime());
        const counts = s.every((g) => g.connections === top) ? `${top} ${first.state}` : `${first.connections} ${first.state} at ${at(first.capturedAt.getTime())} UTC and ${top} ${fromTo(atTop[0], atTop[atTop.length - 1])} UTC`;
        const oldest =
            first.state.startsWith("idle") && first.oldestStateS !== undefined && end.oldestStateS !== undefined
                ? s.length > 1
                    ? `, the oldest ${first.state} for ${span(first.oldestStateS * 1000)} at its first sample and ${span(end.oldestStateS * 1000)} at its last`
                    : `, the oldest ${first.state} for ${span(first.oldestStateS * 1000)}`
                : "";
        return `${nameOf(first)} held ${counts}${oldest}`;
    });
    const totals = times.map((t) => ({ t, total: rows.filter((g) => g.capturedAt.getTime() === t).reduce((n, g) => n + g.connections, 0) }));
    const peak = Math.max(...totals.map((x) => x.total));
    const atPeak = totals.filter((x) => x.total === peak).map((x) => x.t);
    const last = times[times.length - 1];
    const gone = ordered.filter((s) => s[s.length - 1].capturedAt.getTime() < last).map((s) => `the ${s[s.length - 1].state} connections of ${nameOf(s[0])}`);
    const groupList = parts.length === 1 ? parts[0] : `${parts.slice(0, -1).join("; ")}; and ${parts[parts.length - 1]}`;
    const text =
        `Who held them, as the capture counted them by program, login, and state in ${plural(times.length, "sample")} ${fromTo(times[0], last)} UTC (RCA Connections): ${groupList}. ` +
        `Together they held ${peak} at most, ${fromTo(atPeak[0], atPeak[atPeak.length - 1])} UTC.${gone.length ? ` At ${at(last)} UTC, the capture counted none of ${sayList(gone)}.` : ""}`;
    const peakRows = rows.filter((g) => g.capturedAt.getTime() === atPeak[0]);
    return {
        text,
        ref: { table: "RCA Connections", at: iso(new Date(atPeak[0])), target, text: `${peak} client connections by program, login, and state: ${peakRows.map((g) => `${g.connections} ${g.state} of ${nameOf(g)}`).join("; ")}` },
        details: {
            samples: times.length,
            from: iso(new Date(times[0])),
            to: iso(new Date(last)),
            peak: { connections: peak, from: iso(new Date(atPeak[0])), to: iso(new Date(atPeak[atPeak.length - 1])) },
            groups: ordered.map((s) => ({
                name: nameOf(s[0]),
                state: s[0].state,
                isWorkload: s[0].isDemo,
                first: { at: iso(s[0].capturedAt), connections: s[0].connections },
                most: most(s),
                last: { at: iso(s[s.length - 1].capturedAt), connections: s[s.length - 1].connections },
                ...(s[0].oldestStateS !== undefined ? { oldestStateS: { first: s[0].oldestStateS, last: s[s.length - 1].oldestStateS ?? null } } : {}),
            })),
        },
    };
}

export function analyzeConnections(input: {
    target: RcaTarget;
    from: Date;
    to: Date;
    resource: readonly ResourcePoint[];
    sessions: readonly SessionSample[];
    metrics: readonly MetricPoint[];
    openEnded?: boolean;
    readEnd?: Date;
    readStopped?: boolean;
    /** Who held the connections, as the capture counted them in a connection episode (the sidecar's RCA Connections). */
    holders?: readonly ConnectionGroup[];
    /** Its caller couldn't read them (a failed read, or a model without the table) and says so itself: never "not captured". */
    holdersUnread?: boolean;
}): ConnectionAnalysis {
    const { target, from, to } = input;
    const notCaptured: string[] = [];
    const samples = connectionSamples(input.resource, target, from, to);

    // Failed connections: only Azure Monitor counts them. Each point stands for its whole interval, and a split point's
    // pieces for its one whole count (the review of c4c63abe).
    const failed = asWholeReadings(input.metrics.filter((m) => m.target === target && m.metric === FAILED && metricIn(m, from, to))).filter((m) => m.value !== null);
    const failedCount = failed.reduce((n, m) => n + (m.value ?? 0), 0);
    const intervalEnd = (m: MetricPoint) => new Date(m.at.getTime() + (m.intervalMs ?? 0));
    // An interval whose length the read can't tell has no end to give (the review of c4c63abe).
    const until = (m: MetricPoint) => (m.intervalUnknown ? "" : ` to ${hhmm(intervalEnd(m))}`);
    const lastFailed = failed[failed.length - 1];
    const intervals = failed.length === 0 ? "" : `${failed.length === 1 ? "its interval" : `its ${failed.length} intervals`} from ${hhmm(failed[0].at)}${until(lastFailed)} UTC${lastFailed.intervalUnknown ? ", whose length isn't known in these minutes" : ""}`;
    if (failed.length === 0) notCaptured.push(`${target}: Azure Monitor's failed connections aren't in the history for ${hhmmss(from)}-${hhmmss(to)} UTC.`);
    const failedRefs: EvidenceRef[] = failed.filter((m) => (m.value ?? 0) > 0).slice(0, 2).map((m) => ({ table: "Telemetry Snapshots", at: iso(m.at), target, text: `${plural(m.value ?? 0, "failed connection")} ${m.intervalUnknown ? "in the interval " : ""}from ${hhmm(m.at)}${until(m)} UTC (Azure Monitor)` }));

    if (samples.length === 0) {
        notCaptured.push(`${target}: the capture's connection counts (RCA-PG-10) aren't in the history for ${hhmmss(from)}-${hhmmss(to)} UTC, so how many connections there were, and in what state, isn't known.`);
        return { findings: [], rootCause: null, recommendations: [], nextSteps: [], notCaptured, details: { failedConnections: failed.length ? failedCount : null } };
    }

    const peak = samples.reduce((best, s) => (s.total > best.total ? s : best));
    const maxConnections = peak.maxConnections ?? samples.find((s) => s.maxConnections !== undefined)?.maxConnections;
    const reserved = peak.reserved ?? samples.find((s) => s.reserved !== undefined)?.reserved ?? 0;
    const limit = maxConnections !== undefined && maxConnections - reserved > 0 ? maxConnections - reserved : null;
    const level = limit !== null ? CONNECTION_LEVEL * limit : null;
    const atLevel = level !== null ? samples.filter((s) => s.total >= level) : [];
    const watched = atLevel.length ? atLevel : samples;
    const first = watched[0];
    const last = watched[watched.length - 1];
    const ref = (s: ConnectionSample, text: string): EvidenceRef => ({ table: "RCA Resource", at: iso(s.at), target, text });

    // The total counts the capture's own connection, which takes a slot like any other (3732317d's review). Past the
    // limit, the rest are roles that may use the reserved slots, or clients still connecting: "36 of the 35" read as nonsense.
    const own = "the capture's own connection among them";
    const limitText = limit !== null
        ? peak.total > limit
            ? `${peak.total}, over the ${limit} slots clients can use (max_connections ${maxConnections} less ${reserved} reserved, which only privileged roles can take; ${own})`
            : `${peak.total} of the ${limit} slots clients can use (max_connections ${maxConnections} less ${reserved} reserved; ${own})`
        : `${peak.total} client connections (max_connections wasn't captured; ${own})`;
    const share = limit ? Math.round((100 * peak.total) / limit) : null;
    const reached = `${target}'s client connections reached ${limitText} at ${hhmmss(peak.at)} UTC`;
    // The surge's shape: its waves, with their peaks and the troughs between them, and how many samples were at the level.
    const pct = Math.round(CONNECTION_LEVEL * 100);
    const waves = level !== null && limit !== null ? wavesOf(samples, level, TROUGH_SHARE * limit) : [];
    let held = "";
    if (waves.length > 1) {
        held =
            `, in ${waves.length} waves at ${pct} % of the limit or more between ${hhmmss(waves[0].from.at)} and ${hhmmss(waves[waves.length - 1].to.at)} UTC, with peaks of ${sayList(waves.map((w) => String(w.peak.total)))} ` +
            `and the connections falling to ${sayList(waves.slice(1).map((w) => String(w.low)))} between them; ${atLevel.length} of the ${samples.length} samples from ${hhmmss(samples[0].at)} to ${hhmmss(samples[samples.length - 1].at)} UTC were at that level`;
    } else if (atLevel.length) {
        const between = samples.filter((s) => s.at >= first.at && s.at <= last.at).length;
        held =
            between === atLevel.length
                ? `, and stayed at ${pct} % of the limit or more in ${plural(atLevel.length, "sample")} between ${hhmmss(first.at)} and ${hhmmss(last.at)} UTC (${span(last.at.getTime() - first.at.getTime())})`
                : `, and was at ${pct} % of the limit or more in ${atLevel.length} of the ${between} samples between ${hhmmss(first.at)} and ${hhmmss(last.at)} UTC (${span(last.at.getTime() - first.at.getTime())})`;
    }
    const lastSample = samples[samples.length - 1];
    // A surge with no end, cut off by its capture (openEnded) or past the minutes read (readEnd): still on only when its
    // last sample was at the level. Its samples back under the level after its last at it say when it fell (the review of
    // 803f2b1a: 32, 8, and 8 of 35 read as "still on"; the review of 858c50c2: 8, 10, 10, and 20 of 35 at the minutes' end).
    const lastAtLevel = level !== null ? [...samples].reverse().find((s) => s.total >= level) : undefined;
    const fell = (input.openEnded || input.readEnd) && lastAtLevel && lastSample.at > lastAtLevel.at ? samples.find((s) => s.at > lastAtLevel.at) : undefined;
    const cutOff = input.readEnd
        ? fell
            ? ` The connections fell under ${pct} % of the limit by ${hhmmss(fell.at)} UTC; the ${input.readStopped ? "read stopped" : "minutes read end"} at ${hhmmss(input.readEnd)} UTC, before the capture confirmed the end.`
            : ` It was still on at ${hhmmss(input.readEnd)} UTC, where the ${input.readStopped ? "read stopped" : "minutes read end"}.`
        : !input.openEnded
          ? ""
          : fell
            ? ` The connections fell under ${pct} % of the limit by ${hhmmss(fell.at)} UTC; the capture ended at ${hhmmss(lastSample.at)} UTC, before it could confirm the end.`
            : ` The capture ended at ${hhmmss(lastSample.at)} UTC while it was still on (it recorded no end), so what came after isn't known.`;

    // Every usable slot in use: a client connecting then would have been refused, and nothing here counts how many were
    // (Final tests' live check of 4e2c65ed: Azure Monitor's failed connections stayed at 0 through 48 such refusals). When
    // the samples never saw every slot in use, the slots may still have filled between them: live, a wave filled them for
    // 0.1 s, refusing 2 attempts, between two 10-s samples of 34 of 35.
    const full = limit !== null ? samples.filter((s) => s.total >= limit) : [];
    const most = full.length ? Math.max(...full.map((s) => s.total)) : 0;
    const fullText =
        limit === null
            ? ""
            : full.length
              ? ` Every usable slot was in use ${full.length === 1 ? `at ${hhmmss(full[0].at)} UTC` : `in ${full.length} samples between ${hhmmss(full[0].at)} and ${hhmmss(full[full.length - 1].at)} UTC`} (${most > limit ? `up to ${most} connections, over the ${limit}` : `${most} of ${limit}`}), so a client connecting then would have been refused (SQLSTATE 53300, too many clients).`
              : ` The capture's samples saw at most ${peak.total} of the ${limit} usable slots in use; between them the slots may have filled, so whether a client was refused isn't known.`;
    const monitorText =
        failed.length === 0
            ? ""
            : failedCount > 0
              ? ` Azure Monitor counted ${plural(failedCount, "failed connection")} in ${intervals}; in this demo's live check it counted none of the refusals at the connection limit, so these may have failed for another reason${full.length ? ", and how many clients were refused isn't known" : ""}.`
              : ` Azure Monitor's failed-connection count stayed at 0 in ${intervals}; in this demo's live check it counted none of the refusals at the connection limit${full.length ? ", so the capture can't say how many there were" : ""}.`;
    if (limit !== null) {
        notCaptured.push(
            full.length
                ? `${target}: how many clients were refused at the connection limit isn't captured: PostgreSQL refuses them before they reach a session, and in this demo's live check Azure Monitor's failed connections counted none of them.`
                : `${target}: whether a client was refused at the connection limit isn't captured: the slots may have filled between the capture's samples, PostgreSQL refuses a client before it reaches a session, and in this demo's live check Azure Monitor's failed connections counted none of those refusals.`,
        );
    }

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
    // More slots only when queries filled them all: idle or blocked connections fill them otherwise, and Azure Monitor's
    // failed connections, its trigger before, counted none of the refusals at the limit in the live check of 4e2c65ed.
    if (full.length > 0 && ruleId === "CONN-ACTIVE") ids.push("PG-MAXCONN");

    // Who held them: the capture's counts by program, login, and state in a connection episode (RCA Connections), idle
    // ones included; else only the sessions the capture sampled, which are the ones not idle, and only while a client
    // waited on a lock.
    const holders = holdersOf(input.holders ?? [], target, from, to);
    const seen = input.sessions.filter((s) => s.target === target && s.capturedAt >= from && s.capturedAt <= to && (s.backendType === undefined || s.backendType === "client backend"));
    let who = "";
    if (holders) {
        who = ` ${holders.text}`;
        nextSteps = nextSteps.filter((step) => !step.startsWith("While it happens, list who holds"));
    } else if (seen.length > 0) {
        const groups = new Map<string, { sessions: Set<number>; idleMs: number }>();
        for (const s of seen) {
            const key = [s.program ?? "an application the capture didn't name", s.login && `as ${s.login}`].filter(Boolean).join(" ");
            const g = groups.get(key) ?? { sessions: new Set<number>(), idleMs: 0 };
            g.sessions.add(s.session);
            if (s.status.startsWith("idle in transaction")) g.idleMs = Math.max(g.idleMs, s.idleMs ?? 0);
            groups.set(key, g);
        }
        who = ` Of the sessions the capture sampled (only those not idle), ${[...groups.entries()].map(([k, g]) => `${plural(g.sessions.size, "session")} came from ${k}${g.idleMs ? `, idle in a transaction for up to ${span(g.idleMs)}` : ""}`).join("; ")}.`;
        if (!input.holdersUnread) notCaptured.push(`${target}: who held the idle connections isn't captured: the capture samples sessions (RCA-PG-01) that aren't idle, and only while a client waits on a lock; RCA-PG-10 counts the rest by state.`);
    } else if (!input.holdersUnread) {
        notCaptured.push(`${target}: who held the connections (their application, user, and client address) and how long each sat idle aren't captured for these minutes: RCA-PG-10 counts connections by state, and the capture samples sessions (RCA-PG-01) only while a client waits on a lock, which none did here.`);
    }

    const statement = `${reached}${held}.${cutOff} ${cause}${who}${fullText}${monitorText}`;
    // The peak's sample as evidence: its states only when the capture counted them (the review of ebd1c6c3: "0 active, 0
    // idle, …" where they weren't), and a total past the limit as such, never "36 of 35 (103 %)".
    const ofLimit = limit === null ? "" : peak.total > limit ? `, over the ${limit} usable` : ` of ${limit} (${share} %)`;
    // RCA-PG-10 counts a client waiting on a lock as active too, so those are some of the active, never beside them (Final
    // tests' live round at d7df4f9f, O2: "29 active, …, 20 waiting on a lock" read as if they added up).
    const peakText = states
        ? `${peak.total} client connections${ofLimit}: ${active} active${waiting ? ` (${waiting} of them waiting on a lock)` : ""}, ${idle} idle, ${idleInTx} idle in a transaction, and the capture's own`
        : `${peak.total} client connections${ofLimit}, the capture's own among them; their states weren't captured, only the total`;
    const evidence: EvidenceRef[] = [
        ref(peak, peakText),
        ...(first.at.getTime() !== peak.at.getTime() ? [ref(first, `${first.total} client connections`)] : []),
        ...(last.at.getTime() !== peak.at.getTime() ? [ref(last, `${last.total} client connections`)] : []),
        ...(holders ? [holders.ref] : []),
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
            waves: waves.map((w) => ({ from: iso(w.from.at), to: iso(w.to.at), peak: w.peak.total, lowBefore: w.low })),
            samplesAtLimit: full.length,
            failedConnections: failed.length ? failedCount : null,
            captureEnded: input.openEnded && !input.readEnd ? iso(lastSample.at) : null,
            fellUnder: fell ? iso(fell.at) : null,
            readEnd: input.readEnd ? iso(input.readEnd) : null,
            ...(holders ? { holders: holders.details } : {}),
        },
    };
}
