// Session 2233e0ae on dbhubrb, 2026-11-21 (Final tests' live run), and B's sessions after it: T4's read replica, T4's
// connection surges, and T5's normalized RU, as the investigations read them. These are the history model's own rows
// (live-rb-2233e0ae.rows.json), which Final tests' harness read through the app's own DAX at 4e2c65ed
// (evidence/rca-rb-4e2c65ed/rca-dax-rows.json), deduplicated, and decoded here as the app decodes them: the loader's row
// mappers (ROW_MAPPERS) for the RCA tables, and the telemetry query's newest capture per bin (toPostgresCapture,
// toCosmosCapture) for Azure Monitor's. Each read keeps the rows its DAX would: a table by its time column, RCA Coverage
// by overlap, and Telemetry Snapshots by bucket. They replace the rows rebuilt from the live answers, whose connection
// states were modeled (the review of 4e2c65ed). What the file leaves out is in its note.
// live-rb-2233e0ae.answer-key.json is the answer key's record of the same surges, for grading in the tests only: the RCA
// never reads it.
// A's two connection surges (dbhubra, the same day) come the same way, from live-ra-4e2c65ed.rows.json and its answer key:
// liveSources("ra") and liveAnswerKey("ra").

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { toCosmosCapture, toPostgresCapture } from "@/data/model";
import { ROW_MAPPERS, toDate } from "../rows";
import { finestPerInterval } from "../sources";
import { PHASE_1_TABLES, RCA_SPEC, type RcaTableKey } from "../spec";
import type { Telemetry } from "../tools";
import { emptyEvidence, type Evidence, type RcaTarget } from "../types";

export const LIVE_DAY = "2026-11-21";
/** A UTC time on the live day: "16:17:12" or "16:17:12.3". */
export const live = (hms: string) => new Date(`${LIVE_DAY}T${hms}Z`);

export const LIVE_KEYS = {
    replicaFirst: "T4-replica-replica_lag-20261121T161712Z",
    replicaSecond: "T4-replica-replica_lag-20261121T162142Z",
    connections: "T4-connections-20261121T152641Z",
    /** Session ea2b7967's surge, cut off by Stop now: the capture recorded no end. */
    connectionsCutOff: "T4-connections-20261121T185152Z",
    /** Session 2718f9a2's surge, 37 minutes later. */
    connectionsNext: "T4-connections-20261121T193006Z",
    /** T5's first storm, from 15:31: the session's own 1-minute save (the day-long save's 15:30 is 15 minutes). */
    ru: "T5-ru-20261121T153100Z",
} as const;

/** A's surges: the capture's episodes, which 4e2c65ed explained. */
export const LIVE_A_KEYS = { first: "T4-connections-20261121T130832Z", second: "T4-connections-20261121T140836Z" } as const;

/** Which environment's rows: B's (dbhubrb) or A's (dbhubra). */
export type LiveEnv = "rb" | "ra";
const FILES: Record<LiveEnv, string> = { rb: "live-rb-2233e0ae", ra: "live-ra-4e2c65ed" };

type Row = Record<string, unknown>;
interface Table {
    cols: string[];
    rows: unknown[][];
}
const loaded = new Map<LiveEnv, { tables: Record<string, Table> }>();
function fileOf(env: LiveEnv): { tables: Record<string, Table> } {
    let file = loaded.get(env);
    if (!file) {
        file = JSON.parse(readFileSync(resolve(import.meta.dirname, `${FILES[env]}.rows.json`), "utf8")) as { tables: Record<string, Table> };
        loaded.set(env, file);
    }
    return file;
}
const MONITOR = "Telemetry Snapshots (Azure Monitor)";

function rowsOf(env: LiveEnv, name: string): Row[] {
    const t = fileOf(env).tables[name];
    return t ? t.rows.map((r) => Object.fromEntries(t.cols.map((c, i) => [c, r[i]]))) : [];
}

/** One RCA table's rows for a window and its targets, decoded as loadEvidence decodes them. */
function read(env: LiveEnv, key: RcaTableKey, from: Date, to: Date, targets: readonly RcaTarget[]): unknown[] {
    const spec = RCA_SPEC[key];
    const fields = spec.fields as Record<string, { model: string }>;
    const time = fields[spec.time].model;
    const end = spec.time === "from" && fields.to ? fields.to.model : null;
    const map = ROW_MAPPERS[key] as (get: (field: string) => unknown) => unknown;
    return rowsOf(env, spec.model)
        .filter((row) => targets.includes(row["Target Key"] as RcaTarget) && (toDate(row[end ?? time]) ?? from) >= from && (toDate(row[time]) ?? to) <= to)
        .map((row) => map((field) => (fields[field] ? row[fields[field].model] : undefined)))
        .filter((r) => r !== null);
}

/** The investigations' sources over one environment's rows (B's unless "ra"), as the loader and the telemetry query read them. */
export function liveSources(env: LiveEnv = "rb"): { load: (from: Date, to: Date, targets: readonly RcaTarget[]) => Promise<Evidence>; telemetry: (from: Date, to: Date, targets: readonly RcaTarget[]) => Promise<Telemetry> } {
    const monitor = rowsOf(env, MONITOR);
    return {
        load: async (from, to, targets) => {
            const evidence = emptyEvidence();
            for (const key of PHASE_1_TABLES) (evidence[key] as unknown[]).push(...read(env, key, from, to, targets));
            return evidence;
        },
        telemetry: async (from, to, targets) => {
            const inside = (row: Row) => {
                const at = toDate(row.Bucket);
                return !!at && at >= from && at <= to;
            };
            const { kept: rows, intervals } = finestPerInterval(monitor.filter((row) => targets.includes(row.TargetKey as RcaTarget) && inside(row)));
            return {
                postgres: toPostgresCapture(rows.filter((r) => r.TargetKey === "T4" || r.TargetKey === "T4-replica")),
                cosmos: toCosmosCapture(rows.filter((r) => r.TargetKey === "T5")),
                intervals,
            };
        },
    };
}

/** One environment's answer-key rows for its connection surges: grading data for the tests, never the RCA's input. */
export function liveAnswerKey(env: LiveEnv = "rb"): Array<{ at: Date; kind: string; name: string | null; detail: string | null }> {
    const file = JSON.parse(readFileSync(resolve(import.meta.dirname, `${FILES[env]}.answer-key.json`), "utf8")) as { rows: Array<Record<string, string | null>> };
    return file.rows.map((r) => ({ at: toDate(r["[Event Time UTC]"]) as Date, kind: String(r["[Kind]"]), name: r["[Event Name]"], detail: r["[Detail]"] }));
}