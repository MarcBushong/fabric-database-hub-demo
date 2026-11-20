// Locking RCA: blocking chains (head blocker first), lock escalation, and deadlocks, for SQL Server, Azure SQL Database,
// and PostgreSQL. Deterministic: the same rows always give the same answer.
// Learn: understand-resolve-blocking (its blocking-scenarios table), the locking guide's lock escalation, optimized
// locking, and the deadlocks guide; PostgreSQL's pg_blocking_pids and pg_locks.

import { recommend } from "./catalog";
import { during, hhmmss, iso, plural, type Confidence, type EventRow, type EvidenceRef, type Finding, type RcaTarget, type Recommendation, type SessionSample } from "./types";

const seconds = (ms: number | undefined) => (ms === undefined ? "?" : `${Math.round(ms / 1000)} s`);
const ref = (s: SessionSample, text: string): EvidenceRef => ({ table: "RCA Sessions", at: iso(s.capturedAt), target: s.target, text });

/** The documented special blocking_session_id owners (sys.dm_exec_requests). */
export const SPECIAL_BLOCKERS: Record<number, string> = {
    [-2]: "an orphaned distributed transaction",
    [-3]: "a deferred recovery transaction",
    [-4]: "a latch owner that couldn't be determined",
    [-5]: "a latch owner that isn't tracked for this latch type",
};

export type HeadKind = "idle-open-transaction" | "long-running" | "client-not-fetching" | "rollback" | "special" | "not-visible";

export interface ChainNode {
    session: number;
    level: number;
    row?: SessionSample;
    children: ChainNode[];
}

export interface Chain {
    target: RcaTarget;
    at: Date;
    head: ChainNode;
    headKind: HeadKind;
    blocked: number;
    depth: number;
    width: number;
    maxWaitMs: number;
    totalWaitMs: number;
}

/** The blocking forest of one sample: one chain per head blocker, head first. */
export function chainsOf(rows: readonly SessionSample[]): Chain[] {
    if (rows.length === 0) return [];
    const bySession = new Map(rows.map((r) => [r.session, r]));
    const children = new Map<number, number[]>();
    for (const r of rows) {
        // PostgreSQL can list several blockers; the first is the tree's parent, the rest are still blockers.
        const parent = r.blockedBy[0];
        if (parent === undefined || parent === 0) continue;
        children.set(parent, [...(children.get(parent) ?? []), r.session]);
    }
    const isBlocked = (s: number) => {
        const r = bySession.get(s);
        return !!r && r.blockedBy.some((b) => b !== 0 && b > 0 && bySession.has(b));
    };
    const heads = [...children.keys()].filter((s) => s < 0 || !isBlocked(s));
    const chains: Chain[] = [];
    for (const head of heads) {
        const seen = new Set<number>();
        const build = (session: number, level: number): ChainNode => {
            seen.add(session);
            const node: ChainNode = { session, level, row: bySession.get(session), children: [] };
            for (const child of (children.get(session) ?? []).sort((a, b) => a - b)) {
                if (!seen.has(child)) node.children.push(build(child, level + 1));
            }
            return node;
        };
        const root = build(head, 1);
        let blocked = 0;
        let depth = 1;
        let maxWaitMs = 0;
        let totalWaitMs = 0;
        const walk = (n: ChainNode) => {
            if (n.level > 1) {
                blocked += 1;
                maxWaitMs = Math.max(maxWaitMs, n.row?.waitMs ?? 0);
                totalWaitMs += n.row?.waitMs ?? 0;
            }
            depth = Math.max(depth, n.level);
            n.children.forEach(walk);
        };
        walk(root);
        chains.push({ target: rows[0].target, at: rows[0].capturedAt, head: root, headKind: headKind(root.row, head), blocked, depth, width: root.children.length, maxWaitMs, totalWaitMs });
    }
    return chains.sort((a, b) => b.blocked - a.blocked);
}

/** Learn's blocking scenarios, decided from the head blocker's row. */
export function headKind(row: SessionSample | undefined, session: number): HeadKind {
    if (session < 0) return "special";
    if (!row) return "not-visible";
    const status = row.status.toLowerCase();
    if (status === "rollback") return "rollback";
    if (status.startsWith("idle in transaction")) return "idle-open-transaction";
    if (status === "sleeping" && row.openTransactions > 0) return "idle-open-transaction";
    if (row.waitType === "ASYNC_NETWORK_IO" || row.waitType === "Client:ClientWrite") return "client-not-fetching";
    return "long-running";
}

function groupSamples(rows: readonly SessionSample[]): Map<string, SessionSample[]> {
    const out = new Map<string, SessionSample[]>();
    for (const r of rows) {
        const key = `${r.target}|${r.capturedAt.getTime()}`;
        out.set(key, [...(out.get(key) ?? []), r]);
    }
    return out;
}

export interface BlockingEpisode {
    target: RcaTarget;
    headSession: number;
    headKind: HeadKind;
    headRow?: SessionSample;
    first: Date;
    last: Date;
    samples: number;
    /** Separate formations of the chain: it cleared and formed again in between. */
    cycles: number;
    peak: Chain;
    /** The longest the head blocker was seen idle with its transaction open, over every sample. */
    maxIdleMs?: number;
    lockObject?: string;
    lockIndex?: string;
    lockMode?: string;
    lockResourceType?: string;
}

/** Chains across samples, per target and head blocker: when they formed, how often, and their peak. The capture keeps no
 *  rows while no chain exists, so a formation ends where its samples stop for more than 1.5 sample intervals. */
export function blockingEpisodes(rows: readonly SessionSample[]): BlockingEpisode[] {
    const samples = [...groupSamples(rows).values()].sort((a, b) => a[0].capturedAt.getTime() - b[0].capturedAt.getTime());
    const times = samples.map((s) => s[0].capturedAt.getTime());
    const gaps = times.slice(1).map((t, i) => t - times[i]).sort((a, b) => a - b);
    const interval = gaps.length ? gaps[Math.floor(gaps.length / 2)] : 10000;
    const episodes = new Map<string, BlockingEpisode & { lastSeen: number }>();
    samples.forEach((sample) => {
        for (const chain of chainsOf(sample)) {
            const identity = chain.head.row?.module ?? chain.head.row?.program ?? String(chain.head.session);
            const key = `${chain.target}|${identity}`;
            const known = episodes.get(key);
            const now = chain.at.getTime();
            if (!known) {
                episodes.set(key, {
                    target: chain.target, headSession: chain.head.session, headKind: chain.headKind, headRow: chain.head.row,
                    first: chain.at, last: chain.at, samples: 1, cycles: 1, peak: chain, lastSeen: now, maxIdleMs: chain.head.row?.idleMs,
                });
                continue;
            }
            if (now - known.lastSeen > 1.5 * interval) known.cycles += 1;
            known.lastSeen = now;
            if (chain.head.row?.idleMs !== undefined) known.maxIdleMs = Math.max(known.maxIdleMs ?? 0, chain.head.row.idleMs);
            known.last = chain.at;
            known.samples += 1;
            if (chain.blocked > known.peak.blocked || (chain.blocked === known.peak.blocked && chain.maxWaitMs > known.peak.maxWaitMs)) {
                known.peak = chain;
                known.headRow = chain.head.row;
                known.headSession = chain.head.session;
                known.headKind = chain.headKind;
            }
        }
    });
    return [...episodes.values()].map((known) => {
        const { lastSeen, ...e } = known;
        void lastSeen;
        // The lock the waiters want from the head: the first child that names one.
        const waiter = e.peak.head.children.map((c) => c.row).find((r) => r?.lockObject || r?.lockResourceType);
        return { ...e, lockObject: e.headRow?.lockObject ?? waiter?.lockObject, lockIndex: e.headRow?.lockIndex ?? waiter?.lockIndex, lockMode: e.headRow?.lockModeHeld ?? waiter?.lockModeWanted, lockResourceType: waiter?.lockResourceType ?? e.headRow?.lockResourceType };
    }).sort((a, b) => b.peak.blocked - a.peak.blocked);
}

/** A chain as indented text, head first: the shape the RCA view draws and the chat quotes. */
export function chainText(chain: Chain): string[] {
    const lines: string[] = [];
    const walk = (n: ChainNode, indent: string) => {
        const r = n.row;
        const who = n.session < 0 ? SPECIAL_BLOCKERS[n.session] : `session ${n.session}`;
        const what = r ? [r.module, r.waitType, r.waitMs !== undefined && n.level > 1 ? `waiting ${seconds(r.waitMs)}` : undefined, n.level === 1 && r.idleMs !== undefined ? `idle ${seconds(r.idleMs)}` : undefined, n.level === 1 ? r.status : undefined].filter(Boolean).join(", ") : "not visible";
        lines.push(`${indent}${n.level === 1 ? "HEAD " : `L${n.level} `}${who}: ${what}`);
        n.children.forEach((c) => walk(c, `${indent}  `));
    };
    walk(chain.head, "");
    return lines;
}

const KIND_TEXT: Record<HeadKind, string> = {
    "idle-open-transaction": "sat idle with its transaction open",
    "long-running": "was still running its statement",
    "client-not-fetching": "waited for its client to read results (ASYNC_NETWORK_IO) with its transaction open",
    rollback: "was rolling back",
    special: "is a special owner",
    "not-visible": "isn't visible to the capture",
};

export interface LockingAnalysis {
    episodes: BlockingEpisode[];
    escalations: EventRow[];
    /** One analysis per target that had deadlocks, most first. */
    deadlocks: DeadlockAnalysis[];
    findings: Finding[];
    rootCause: { statement: string; confidence: Confidence; ruleIds: string[]; evidence: EvidenceRef[] } | null;
    recommendations: Recommendation[];
    nextSteps: string[];
    chainLines: string[];
}

/** The locking investigation over one window. With `at`, chains active at that time come first, then the biggest. */
export function analyzeLocking(rows: readonly SessionSample[], events: readonly EventRow[], at?: Date): LockingAnalysis {
    const all = blockingEpisodes(rows);
    const activeAt = (e: BlockingEpisode) => !!at && e.first.getTime() - 15000 <= at.getTime() && at.getTime() <= e.last.getTime() + 15000;
    const episodes = at ? [...all.filter(activeAt), ...all.filter((e) => !activeAt(e))] : all;
    const escalations = events.filter((e) => e.kind === "escalation");
    const byTarget = new Map<RcaTarget, EventRow[]>();
    for (const e of events) byTarget.set(e.target, [...(byTarget.get(e.target) ?? []), e]);
    const deadlocks = [...byTarget.values()].map(analyzeDeadlocks).filter((d): d is DeadlockAnalysis => d !== null).sort((a, b) => b.count - a.count);
    const findings: Finding[] = [];
    const recIds = new Set<string>();
    const nextSteps: string[] = [];
    let rootCause: LockingAnalysis["rootCause"] = null;

    for (const e of episodes) {
        const head = e.headRow;
        const pg = e.target === "T4" || e.target === "T4-replica";
        const t3Xact = e.target === "T3" && (e.lockResourceType === "XACT" || /_XACT/.test(e.peak.head.children[0]?.row?.waitType ?? ""));
        const who = head ? [head.program, head.login && `login ${head.login}`, head.host && `host ${head.host}`].filter(Boolean).join(", ") : "not visible to the capture";
        // PostgreSQL's waiters wait for the holder's transaction ID; its row locks are on the table RCA-PG-11 names.
        const lock = e.lockResourceType === "transactionid"
            ? `its transaction's row locks${e.lockObject ? ` on ${e.lockObject}` : ""} (the waiters wait for its transaction ID)`
            : e.lockObject ? `${e.lockMode ?? ""} ${e.lockResourceType ?? ""} lock on ${e.lockObject}${e.lockIndex ? ` (${e.lockIndex})` : ""}`.replace(/\s+/g, " ").trim() : t3Xact ? "its transaction-ID (XACT) lock (optimized locking: the object is in the statements)" : "its locks";
        const idle = e.maxIdleMs !== undefined ? ` for up to ${seconds(e.maxIdleMs)}` : head?.idleMs !== undefined ? ` for ${seconds(head.idleMs)}` : "";
        const shape = e.peak.depth <= 2 ? `It blocked ${plural(e.peak.blocked, "session")}, ${e.peak.blocked === 1 ? "waiting" : "each waiting"} on it directly` : `It blocked ${plural(e.peak.blocked, "session")} in ${plural(e.peak.width, "branch", "branches")}, ${e.peak.depth} levels deep`;
        const detail = `${head?.module ?? `Session ${e.headSession}`} (session ${e.headSession}; ${who}) ${KIND_TEXT[e.headKind]}${idle}, holding ${lock}. ` +
            `${shape} at the peak (${hhmmss(e.peak.at)} UTC); the longest single wait was ${seconds(e.peak.maxWaitMs)}. ` +
            `The chain formed ${plural(e.cycles, "time")} ${during(e.first, e.last)} UTC (${plural(e.samples, "sample")}).`;
        const ruleId = e.headKind === "idle-open-transaction" ? (pg ? "BLK-PG-IDLE-IN-TRANSACTION" : "BLK-IDLE-HEAD") : e.headKind === "long-running" ? "BLK-LONG-RUNNING" : e.headKind === "client-not-fetching" ? "BLK-CLIENT-NOT-FETCHING" : "BLK-OTHER";
        findings.push({
            ruleId, target: e.target, severity: e.peak.blocked >= 3 ? "critical" : "warning",
            title: `${e.target}: ${plural(e.peak.blocked, "session")} blocked behind session ${e.headSession}`,
            detail,
            evidence: [
                ...(head ? [ref(head, `head ${e.headSession}: ${head.status}, open transactions ${head.openTransactions}${head.idleMs !== undefined ? `, idle ${seconds(head.idleMs)}` : ""}${head.module ? `, ${head.module}` : ""}`)] : []),
                ...e.peak.head.children.slice(0, 4).filter((c) => c.row).map((c) => ref(c.row!, `session ${c.session} waits on ${e.headSession}: ${c.row!.waitType ?? "?"} for ${seconds(c.row!.waitMs)}`)),
            ],
        });
        if (e.headKind === "idle-open-transaction") {
            (pg ? ["BLK-COMMIT", "PG-IDLE-TIMEOUT", "PG-LOCK-TIMEOUT"] : ["BLK-COMMIT", "BLK-XACT-ABORT", "BLK-LOCK-TIMEOUT", "BLK-KILL"]).forEach((id) => recIds.add(id));
        } else if (e.headKind === "client-not-fetching") {
            recIds.add("NET-CLIENT");
        } else {
            ["CPU-SARGABLE", "BLK-LOCK-TIMEOUT"].forEach((id) => recIds.add(id));
        }
        if (t3Xact) recIds.add("ESC-OPTIMIZED");
        if (!rootCause && (!at || activeAt(e))) {
            const consistent = e.samples >= 2 && !!head;
            rootCause = {
                statement: detail,
                confidence: consistent ? "high" : head ? "medium" : "low",
                ruleIds: [ruleId],
                evidence: findings[findings.length - 1].evidence,
            };
            nextSteps.push(
                head?.module ? `Find the code path that calls ${head.module} and leaves its transaction open; add the commit or rollback (and SET XACT_ABORT ON on SQL Server).` : `Identify what session ${e.headSession} runs (it wasn't visible to the capture).`,
                `Compare the chain with Database Hub's Performance view for ${e.target} (Processes blocked and lock waits) for the same minutes.`,
            );
        }
    }

    for (const esc of escalations) {
        findings.push({
            ruleId: "BLK-ESCALATION", target: esc.target, severity: "warning",
            title: `${esc.target}: lock escalation to a table lock on ${esc.object ?? "a table"}`,
            detail: `${esc.module ?? esc.program ?? "A session"} escalated to ${esc.mode ?? "X"} on ${esc.object ?? "the table"} at ${hhmmss(esc.at)} UTC: ${esc.detail}`,
            evidence: [{ table: "RCA Events", at: iso(esc.at), target: esc.target, text: esc.detail }],
        });
        recIds.add("ESC-BATCH");
        if (esc.target === "T3") recIds.add("ESC-OPTIMIZED");
    }

    for (const d of deadlocks) {
        findings.push(...d.findings);
        d.recommendationIds.forEach((id) => recIds.add(id));
        if (!rootCause && d.rootCause) rootCause = d.rootCause;
        nextSteps.push(...d.nextSteps);
    }
    // Asked about a time when no chain was active and no deadlock either: the biggest chain in the window still explains it.
    if (!rootCause && episodes[0]) {
        const f = findings.find((x) => x.target === episodes[0].target && x.ruleId.startsWith("BLK-"));
        if (f) rootCause = { statement: `${f.detail} It wasn't active at the time asked.`, confidence: "medium", ruleIds: [f.ruleId], evidence: f.evidence };
    }

    return {
        episodes, escalations, deadlocks, findings, rootCause,
        recommendations: recommend(...recIds),
        nextSteps: [...new Set(nextSteps)],
        chainLines: episodes[0] ? chainText(episodes[0].peak) : [],
    };
}

// ---- Deadlocks ---------------------------------------------------------------------------------------------------

export interface DeadlockAnalysis {
    count: number;
    byPattern: Record<string, number>;
    victims: Record<string, number>;
    findings: Finding[];
    rootCause: LockingAnalysis["rootCause"];
    recommendationIds: string[];
    nextSteps: string[];
}

/** "order" (two resources locked in opposite order) or "conversion" (both hold S on one resource and want X). */
export function deadlockPattern(e: EventRow): "order" | "conversion" | "unknown" {
    const d = e.deadlock;
    if (!d) return /conversion/i.test(e.detail) ? "conversion" : /order/i.test(e.detail) ? "order" : "unknown";
    const distinct = new Set(d.resources.map((r) => `${r.object}|${r.index}|${r.type}`)).size;
    if (distinct === 1 && d.processes.every((p) => /^S/.test(p.holds ?? "") && /X|U/.test(p.wants ?? ""))) return "conversion";
    if (distinct >= 2) return "order";
    return "unknown";
}

export function analyzeDeadlocks(events: readonly EventRow[]): DeadlockAnalysis | null {
    const deadlocks = events.filter((e) => e.kind === "deadlock" || e.code === "1205" || e.code === "40P01");
    if (deadlocks.length === 0) return null;
    // One deadlock can show as a graph and as its victim's error: count graphs when there are any.
    const graphs = deadlocks.filter((e) => e.kind === "deadlock");
    const counted = graphs.length > 0 ? graphs : deadlocks;
    const count = counted.reduce((n, e) => n + (e.count ?? 1), 0);
    const byPattern: Record<string, number> = {};
    for (const e of counted) byPattern[deadlockPattern(e)] = (byPattern[deadlockPattern(e)] ?? 0) + (e.count ?? 1);
    const victims: Record<string, number> = {};
    for (const e of counted) {
        const victim = e.deadlock?.processes.find((p) => p.session === e.deadlock?.victim);
        const name = victim?.module ?? e.module ?? e.program ?? "unknown";
        victims[name] = (victims[name] ?? 0) + (e.count ?? 1);
    }
    const target = counted[0].target;
    const pg = target === "T4";
    const first = counted.reduce((a, e) => (e.at < a ? e.at : a), counted[0].at);
    const last = counted.reduce((a, e) => (e.at > a ? e.at : a), counted[0].at);
    const sample = graphs[0]?.deadlock;
    const objects = [...new Set(graphs.flatMap((g) => g.deadlock?.resources.map((r) => `${r.object}${r.index ? ` (${r.index})` : ""}`) ?? []))].slice(0, 3);
    const patterns = Object.entries(byPattern).map(([p, n]) => `${n} ${p}`).join(", ");
    const statement = `${plural(count, "deadlock")} on ${target} ${during(first, last)} UTC (${patterns})${objects.length ? ` on ${objects.join(", ")}` : ""}. ` +
        `The victim was ${Object.entries(victims).map(([v, n]) => `${v} (${n})`).join(", ")}${pg ? " (SQLSTATE 40P01)" : " (error 1205)"}.` +
        (sample ? ` Each graph shows ${sample.processes.length} sessions running ${[...new Set(sample.processes.map((p) => p.module ?? p.program))].join(" and ")}.` : "");
    const ruleId = pg ? "DLK-PG" : byPattern.conversion && !byPattern.order ? "DLK-CONVERSION" : byPattern.order && !byPattern.conversion ? "DLK-ORDER" : "DLK-MIXED";
    const evidence: EvidenceRef[] = counted.slice(0, 3).map((e) => ({ table: "RCA Events", at: iso(e.at), target: e.target, text: e.detail }));
    const recommendationIds = pg ? ["DLK-PG"] : ["DLK-ORDER", ...(byPattern.conversion ? ["DLK-NO-HOLDLOCK"] : []), "DLK-RETRY", ...(target === "T3" ? ["DLK-AZURE"] : [])];
    return {
        count, byPattern, victims,
        findings: [{ ruleId, target, severity: count >= 5 ? "critical" : "warning", title: `${target}: ${plural(count, "deadlock")}`, detail: statement, evidence }],
        rootCause: { statement, confidence: graphs.length > 0 ? "high" : "medium", ruleIds: [ruleId], evidence },
        recommendationIds,
        nextSteps: [
            graphs.length > 0 ? "Open one deadlock graph (the evidence rows) and confirm the lock order of each statement." : "The graphs weren't captured; the counts come from the victims' errors.",
            "Check whether the victim's caller retries on the deadlock error.",
        ],
    };
}
