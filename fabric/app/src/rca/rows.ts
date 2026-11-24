// Turns one table row into the typed evidence row, whatever it came from: an evidence document (evidence.ts, by its
// lakehouse columns) or a DAX result (loader.ts, by its model columns). A row without its required values is dropped,
// never guessed.

import { RCA_SPEC, type RcaTableKey } from "./spec";
import { isRcaTarget, type Coverage, type DeadlockSummary, type EventKind, type EventRow, type ReplicaSample, type ResourcePoint, type SessionSample, type WaitDelta } from "./types";

/** A row's value by the spec's field name. */
export type Get = (field: string) => unknown;

const EVENT_KINDS: readonly EventKind[] = ["error", "attention", "deadlock", "escalation", "tuning", "capture"];

export function toDate(value: unknown): Date | undefined {
    if (value instanceof Date) return Number.isFinite(value.getTime()) ? value : undefined;
    if (typeof value === "string" && value.trim()) {
        // The connector returns model datetimes without a zone; the history's times are UTC.
        const text = /[zZ]|[+-]\d\d:?\d\d$/.test(value.trim()) ? value.trim() : `${value.trim()}Z`;
        const d = new Date(text);
        return Number.isFinite(d.getTime()) ? d : undefined;
    }
    if (typeof value === "number" && Number.isFinite(value)) return new Date(value);
    return undefined;
}

export function toNum(value: unknown): number | undefined {
    if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
    if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) return Number(value);
    return undefined;
}

export function toStr(value: unknown): string | undefined {
    if (typeof value === "string") return value.length > 0 ? value : undefined;
    if (typeof value === "number" || typeof value === "boolean") return String(value);
    return undefined;
}

export function toBool(value: unknown): boolean | undefined {
    if (typeof value === "boolean") return value;
    if (value === 1 || value === "1" || value === "true" || value === "True" || value === "TRUE") return true;
    if (value === 0 || value === "0" || value === "false" || value === "False" || value === "FALSE") return false;
    return undefined;
}

/** "63" or "20432, 9772" into session IDs; empty when it isn't blocked. */
export function parseBlockedBy(value: unknown): number[] {
    const text = toStr(value);
    if (!text) return [];
    return text
        .split(/[\s,;]+/)
        .map((part) => Number(part))
        .filter((n) => Number.isInteger(n) && n !== 0);
}

const lines = (value: unknown, split: RegExp) =>
    (toStr(value) ?? "")
        .split(split)
        .map((s) => s.trim())
        .filter(Boolean);

/** The deadlock graph's JSON, or undefined when it's missing or not the contract's shape. */
export function parseDeadlock(value: unknown): DeadlockSummary | undefined {
    const text = toStr(value);
    if (!text) return undefined;
    try {
        const parsed = JSON.parse(text) as Partial<DeadlockSummary>;
        if (typeof parsed.victim !== "number" || !Array.isArray(parsed.processes) || !Array.isArray(parsed.resources)) return undefined;
        return { victim: parsed.victim, processes: parsed.processes, resources: parsed.resources };
    } catch {
        return undefined;
    }
}

/** Only the fields with a value, so optional fields stay absent rather than undefined. */
function clean<T extends object>(row: T): T {
    for (const key of Object.keys(row) as Array<keyof T>) if (row[key] === undefined) delete row[key];
    return row;
}

export function sessionFrom(get: Get): SessionSample | null {
    const target = get("target");
    const capturedAt = toDate(get("capturedAt"));
    const session = toNum(get("session"));
    if (!isRcaTarget(target) || !capturedAt || session === undefined) return null;
    return clean<SessionSample>({
        target,
        capturedAt,
        session,
        blockedBy: parseBlockedBy(get("blockedBy")),
        status: toStr(get("status")) ?? "",
        waitType: toStr(get("waitType")),
        waitMs: toNum(get("waitMs")),
        waitResource: toStr(get("waitResource")),
        lockResourceType: toStr(get("lockResourceType")),
        lockObject: toStr(get("lockObject")),
        lockIndex: toStr(get("lockIndex")),
        lockModeWanted: toStr(get("lockModeWanted")),
        lockModeHeld: toStr(get("lockModeHeld")),
        openTransactions: toNum(get("openTransactions")) ?? 0,
        transactionAgeMs: toNum(get("transactionAgeMs")),
        idleMs: toNum(get("idleMs")),
        login: toStr(get("login")),
        host: toStr(get("host")),
        program: toStr(get("program")),
        runToken: toStr(get("runToken")),
        module: toStr(get("module")),
        statement: toStr(get("statement")),
        inputBuffer: toStr(get("inputBuffer")),
        backendType: toStr(get("backendType")),
        isDemo: toBool(get("isDemo")) ?? false,
    });
}

export function eventFrom(get: Get): EventRow | null {
    const target = get("target");
    const at = toDate(get("at"));
    const kind = toStr(get("kind")) as EventKind | undefined;
    if (!isRcaTarget(target) || !at || !kind || !EVENT_KINDS.includes(kind)) return null;
    return clean<EventRow>({
        target,
        at,
        kind,
        name: toStr(get("name")),
        session: toNum(get("session")),
        program: toStr(get("program")),
        runToken: toStr(get("runToken")),
        login: toStr(get("login")),
        host: toStr(get("host")),
        module: toStr(get("module")),
        code: toStr(get("code")),
        severity: toNum(get("severity")),
        intercepted: toBool(get("intercepted")),
        count: toNum(get("count")) ?? 1,
        object: toStr(get("object")),
        mode: toStr(get("mode")),
        detail: toStr(get("detail")) ?? "",
        deadlock: parseDeadlock(get("deadlock")),
    });
}

export function resourceFrom(get: Get): ResourcePoint | null {
    const target = get("target");
    const at = toDate(get("at"));
    const metric = toStr(get("metric"));
    const value = toNum(get("value"));
    if (!isRcaTarget(target) || !at || !metric || value === undefined) return null;
    return clean<ResourcePoint>({ target, at, source: toStr(get("source")) ?? "", metric, value, unit: toStr(get("unit")) });
}

export function replicaFrom(get: Get): ReplicaSample | null {
    const target = get("target");
    const at = toDate(get("at"));
    const side = toStr(get("side"));
    if (!isRcaTarget(target) || !at || (side !== "primary" && side !== "replica")) return null;
    return clean<ReplicaSample>({
        target,
        at,
        side,
        standby: toStr(get("standby")),
        sinceLastReplayS: toNum(get("sinceLastReplayS")),
        receivedNotReplayedBytes: toNum(get("receivedNotReplayedBytes")),
        replayLagS: toNum(get("replayLagS")),
        writeLagS: toNum(get("writeLagS")),
        flushLagS: toNum(get("flushLagS")),
        sendGapBytes: toNum(get("sendGapBytes")),
        walBytesPerS: toNum(get("walBytesPerS")),
        startupWait: toStr(get("startupWait")),
        conflictRelation: toStr(get("conflictRelation")),
        conflictWantedMode: toStr(get("conflictWantedMode")),
        conflictWaitStart: toDate(get("conflictWaitStart")),
        conflictHolder: toNum(get("conflictHolder")),
        conflictHolderMode: toStr(get("conflictHolderMode")),
        conflictHolderProgram: toStr(get("conflictHolderProgram")),
        conflictHolderRunToken: toStr(get("conflictHolderRunToken")),
        conflictHolderStatement: toStr(get("conflictHolderStatement")),
        conflictsCancelled: toNum(get("conflictsCancelled")),
        maxStandbyStreamingDelayS: toNum(get("maxStandbyStreamingDelayS")),
    });
}

export function coverageFrom(get: Get): Coverage | null {
    const target = get("target");
    const from = toDate(get("from"));
    const to = toDate(get("to"));
    if (!isRcaTarget(target) || !from || !to) return null;
    return { target, from, to, captured: toBool(get("captured")) ?? false, sources: lines(get("sources"), /,/), gaps: lines(get("gaps"), /\r?\n/) };
}

export function waitFrom(get: Get): WaitDelta | null {
    const target = get("target");
    const from = toDate(get("from"));
    const to = toDate(get("to"));
    const waitType = toStr(get("waitType"));
    const waitMs = toNum(get("waitMs"));
    const phase = toStr(get("phase"));
    if (!isRcaTarget(target) || !from || !to || !waitType || waitMs === undefined || (phase !== "baseline" && phase !== "episode")) return null;
    return clean<WaitDelta>({
        target,
        episodeId: toStr(get("episodeId")),
        phase,
        from,
        to,
        waitType,
        category: toStr(get("category")),
        waitMs,
        waitingTasks: toNum(get("waitingTasks")),
        signalMs: toNum(get("signalMs")),
        maxWaitMs: toNum(get("maxWaitMs")),
    });
}

export const ROW_MAPPERS = {
    sessions: sessionFrom,
    events: eventFrom,
    resource: resourceFrom,
    replica: replicaFrom,
    coverage: coverageFrom,
    waits: waitFrom,
} as const satisfies Record<RcaTableKey, (get: Get) => unknown>;

/** The spec's fields of a table, for a getter that reads a row by lakehouse or model column. */
export const fieldsOf = (table: RcaTableKey) => RCA_SPEC[table].fields as Record<string, { lake: string; model: string }>;
