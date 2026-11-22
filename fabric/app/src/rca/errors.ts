// Errors by class: deadlock victims, lock timeouts, timeouts and attentions, refused connections and failed logins,
// resource governance and throttling, recovery conflicts on the replica, PostgreSQL SQLSTATE classes, and T5's 429s.
// Each class says what usually causes it and which investigation names the cause. Blind: the evidence is the observer's
// event session and Azure Monitor's counts (T4's failed connections, T5's 429s), never the workload's own account of them.

import { recommend } from "./catalog";
import { during, hhmmss, iso, type EventRow, type EvidenceRef, type Finding, type InvestigationResult, type RcaTarget } from "./types";

export interface ErrorClass {
    id: string;
    title: string;
    codes: string[];
    cause: string;
    followUp: string;
    recommendationIds: string[];
}

export const ERROR_CLASSES: ErrorClass[] = [
    { id: "deadlock-victim", title: "Deadlock victims", codes: ["1205", "40P01"], cause: "Two transactions waited on each other's locks; the engine rolled one back.", followUp: "explain_locking", recommendationIds: ["DLK-ORDER", "DLK-RETRY"] },
    { id: "lock-timeout", title: "Lock timeouts", codes: ["1222", "55P03"], cause: "A statement waited longer than its lock timeout behind a blocker.", followUp: "explain_locking", recommendationIds: ["BLK-COMMIT", "BLK-LOCK-TIMEOUT"] },
    { id: "timeout-or-cancel", title: "Timeouts and cancels (attentions)", codes: ["attention", "57014"], cause: "The client cancelled the query, or its command timeout expired, while the query waited or ran long.", followUp: "triage_window", recommendationIds: ["TMO-CAUSE"] },
    { id: "connection-refused", title: "Refused connections and failed logins", codes: ["53300", "53400", "18456", "4060", "40613", "08001", "08006", "connections_failed"], cause: "The server refused new connections: too many clients (53300), or the login failed.", followUp: "triage_window", recommendationIds: ["PG-POOL", "PG-MAXCONN"] },
    { id: "governance", title: "Resource governance and memory", codes: ["10928", "10929", "40501", "40544", "40549", "40551", "49918", "49919", "49920", "701", "8645", "8651"], cause: "A resource limit was reached: workers, sessions, memory, or the database's size.", followUp: "triage_window", recommendationIds: ["GOV-SCALE", "MEM-GRANTS"] },
    { id: "recovery-conflict", title: "Replica queries cancelled by replay", codes: ["40001-replica"], cause: "A query on the read replica held up replay longer than max_standby_streaming_delay, so recovery cancelled it.", followUp: "explain_replica_lag", recommendationIds: ["RPL-STANDBY-DELAY", "RPL-SHORT-REPORTS"] },
    { id: "throttled", title: "Throttled requests (429)", codes: ["429"], cause: "A partition key range had used all of its share of the RU/s in that second, so the request was refused with the time to wait before retrying it.", followUp: "triage_window", recommendationIds: ["RU-RETRY"] },
    { id: "service-unavailable", title: "Timeouts and unavailability (408, 503)", codes: ["408", "503"], cause: "Requests timed out or the service couldn't be reached.", followUp: "triage_window", recommendationIds: ["RU-RETRY"] },
];

/** The event name of an error count that comes from Azure Monitor's metrics (Telemetry Snapshots), not the event session. */
export const AZURE_MONITOR = "Azure Monitor";

/** PostgreSQL's SQLSTATE classes (the first two characters), for codes no class above lists. */
export const PG_SQLSTATE_CLASS: Record<string, string> = {
    "08": "Connection exception",
    "22": "Data exception",
    "23": "Integrity constraint violation",
    "25": "Invalid transaction state",
    "40": "Transaction rollback",
    "42": "Syntax error or access rule violation",
    "53": "Insufficient resources",
    "55": "Object not in prerequisite state",
    "57": "Operator intervention",
    "58": "System error",
};

const POSTGRES_TARGETS: readonly RcaTarget[] = ["T4", "T4-replica"];

export function classOf(e: EventRow): ErrorClass | { id: string; title: string; codes: string[]; cause: string; followUp: string; recommendationIds: string[] } {
    const code = e.kind === "attention" ? "attention" : e.code === "40001" && e.target === "T4-replica" ? "40001-replica" : e.code ?? "";
    const known = ERROR_CLASSES.find((c) => c.codes.includes(code));
    if (known) return known;
    // SQLSTATE classes are PostgreSQL's: on SQL Server, 40197 or 40552 is an error number, not class 40 (the review of 34a9732).
    if (POSTGRES_TARGETS.includes(e.target) && /^[0-9A-Z]{5}$/.test(code) && PG_SQLSTATE_CLASS[code.slice(0, 2)]) {
        return { id: `sqlstate-${code.slice(0, 2)}`, title: `SQLSTATE class ${code.slice(0, 2)}: ${PG_SQLSTATE_CLASS[code.slice(0, 2)]}`, codes: [code], cause: "See PostgreSQL's error codes appendix.", followUp: "triage_window", recommendationIds: [] };
    }
    return { id: "other", title: "Other errors", codes: [code], cause: "Unclassified.", followUp: "triage_window", recommendationIds: [] };
}

export interface ErrorSummary {
    classId: string;
    title: string;
    count: number;
    targets: RcaTarget[];
    first: Date;
    /** When the last one was: an event's time, or the end of the interval of an Azure Monitor count (the review of ebd1c6c3). */
    last: Date;
    intercepted: number;
    top: string;
    cause: string;
    followUp: string;
    recommendationIds: string[];
    evidence: EvidenceRef[];
}

/** Errors in a window by class, most first. Attentions and 429s count as errors here, as a DBA reads them. With `stoppedAt`, a read that stopped short: each count is at least what's read, through where it stopped (the review of d431edb4). */
export function summarizeErrors(events: readonly EventRow[], stoppedAt?: Date): { classes: ErrorSummary[]; findings: Finding[] } {
    const relevant = events.filter((e) => e.kind === "error" || e.kind === "attention");
    const groups = new Map<string, EventRow[]>();
    for (const e of relevant) {
        const c = classOf(e);
        groups.set(c.id, [...(groups.get(c.id) ?? []), e]);
    }
    const classes: ErrorSummary[] = [...groups.entries()].map(([id, rows]) => {
        const c = classOf(rows[0]);
        const sorted = rows.sort((a, b) => a.at.getTime() - b.at.getTime());
        // An Azure Monitor count stands for its whole interval: 10382 429s counted at 12:15 and 12:30 in 15-minute intervals
        // ran to 12:45, not 12:30 (the review of ebd1c6c3).
        const last = new Date(Math.max(...rows.map((r) => r.at.getTime() + (r.intervalMs ?? 0))));
        const tally = new Map<string, number>();
        for (const r of rows) {
            const who = r.module ?? r.program ?? r.detail.slice(0, 60);
            tally.set(who, (tally.get(who) ?? 0) + (r.count ?? 1));
        }
        return {
            classId: id, title: c.title,
            count: rows.reduce((n, r) => n + (r.count ?? 1), 0),
            targets: [...new Set(rows.map((r) => r.target))],
            first: sorted[0].at, last,
            intercepted: rows.filter((r) => r.intercepted).reduce((n, r) => n + (r.count ?? 1), 0),
            top: [...tally.entries()].sort((a, b) => b[1] - a[1])[0][0],
            cause: c.cause, followUp: c.followUp, recommendationIds: c.recommendationIds,
            evidence: sorted.slice(0, 3).map((r) => ({ table: r.name === AZURE_MONITOR ? "Telemetry Snapshots" : "RCA Events", at: iso(r.at), target: r.target, text: `${r.code ?? r.kind}: ${r.detail}` })),
        };
    }).sort((a, b) => b.count - a.count);
    const findings: Finding[] = classes.map((c) => ({
        ruleId: `ERR-${c.classId.toUpperCase()}`,
        target: c.targets[0],
        severity: c.count >= 100 ? "critical" : "warning",
        title: `${c.title}: ${stoppedAt ? "at least " : ""}${c.count}`,
        detail: `${stoppedAt ? `At least ${c.count} ${c.title.toLowerCase()} on ${c.targets.join(", ")} from ${hhmmss(c.first)} UTC through ${hhmmss(stoppedAt)} UTC, where the read stopped` : `${c.count} ${c.title.toLowerCase()} on ${c.targets.join(", ")} ${during(c.first, c.last)} UTC`}, mostly ${c.top}${c.intercepted ? ` (${c.intercepted} caught by the code's own TRY...CATCH)` : ""}. ${c.cause}`,
        evidence: c.evidence,
    }));
    return { classes, findings };
}

/** The errors investigation's part of an InvestigationResult: the classes, and the biggest one's usual cause. With `stoppedAt`, the read stopped short there. */
export function analyzeErrorsResult(events: readonly EventRow[], stoppedAt?: Date): Pick<InvestigationResult, "findings" | "rootCause" | "recommendations" | "nextSteps" | "details"> {
    const { classes, findings } = summarizeErrors(events, stoppedAt);
    const top = classes[0];
    const span = (c: ErrorSummary) => (stoppedAt ? `at least ${c.count}, ${hhmmss(c.first)} through ${hhmmss(stoppedAt)} UTC, where the read stopped` : `${c.count}, ${hhmmss(c.first)} to ${hhmmss(c.last)} UTC`);
    return {
        findings,
        rootCause: top
            ? {
                  statement: `Most errors were ${top.title.toLowerCase()} (${span(top)}, mostly ${top.top}). ${top.cause} The cause behind them is what ${top.followUp} finds for the same minutes.`,
                  confidence: "medium",
                  ruleIds: [`ERR-${top.classId.toUpperCase()}`],
                  evidence: top.evidence,
              }
            : null,
        recommendations: recommend(...new Set(classes.flatMap((c) => c.recommendationIds))),
        nextSteps: classes.slice(0, 3).map((c) => `${c.followUp} for ${c.targets.join(", ")} (${c.title.toLowerCase()})`),
        details: { classes: classes.map((c) => ({ class: c.classId, title: c.title, count: c.count, targets: c.targets, first: iso(c.first), last: iso(c.last), intercepted: c.intercepted, top: c.top })), ...(stoppedAt ? { countsAtLeast: true, readStoppedAt: iso(stoppedAt) } : {}) },
    };
}
