// The local preview's Incident RCA (ADR 0031): the contract's two fixture documents, shifted onto the sample session (T1's
// blocking chain into its second blocking beat, T4's chain and its replica's stall onto the sample's replica lag), answering
// the RCA's own DAX the way the history model would, with the model's column names. Preview only: Vite builds only
// index.html, so none of this ships, and the fixtures stay in rca/fixtures (vite.config.ts lets the preview read them).

import t1Text from "../../../../rca/fixtures/t1-blocking-chain.evidence.json?raw";
import t4Text from "../../../../rca/fixtures/t4-replica-lag.evidence.json?raw";
import type { QuerySpec } from "@/data/queries";
import type { Row } from "@/data/query-client";
import { NEWEST_BIN_DAX } from "@/rca/client";
import { RCA_PRESENCE_DAX } from "@/rca/loader";
import { RCA_SPEC, type RcaTableKey } from "@/rca/spec";
import { sampleRows } from "./sample-data";
import { SESSION_END } from "./sample-session";

interface FixtureDocument {
    epochUtc: string;
    strings: string[];
    tables: Record<string, { rows: number; columns: Record<string, unknown[]> }>;
}

/** Each target's shift from the fixtures' 20 Nov onto the sample session's 17 Nov. */
const SHIFT: Record<string, number> = {
    T1: Date.UTC(2026, 10, 17, 14, 2, 30) - Date.UTC(2026, 10, 20, 16, 52, 30),
    T4: Date.UTC(2026, 10, 17, 14, 21, 15) - Date.UTC(2026, 10, 20, 17, 11, 15),
    "T4-replica": Date.UTC(2026, 10, 17, 14, 21, 15) - Date.UTC(2026, 10, 20, 17, 11, 15),
};

const TABLES = Object.keys(RCA_SPEC) as RcaTableKey[];

/** A row with its time and target; an interval's row (RCA Coverage, RCA Waits) also has its end. */
interface SampleRow {
    at: number;
    end: number | null;
    target: string;
    row: Row;
}

let cached: Map<string, SampleRow[]> | null = null;

/** The detection tables' rows by model table, each with its time and target, keyed by the model's column names. */
function modelRows(): Map<string, SampleRow[]> {
    if (cached) return cached;
    const out = new Map<string, SampleRow[]>();
    for (const doc of [JSON.parse(t1Text) as FixtureDocument, JSON.parse(t4Text) as FixtureDocument]) {
        const epoch = Date.parse(doc.epochUtc);
        for (const key of TABLES) {
            const spec = RCA_SPEC[key];
            const table = doc.tables[spec.lake];
            if (!table) continue;
            const fields = spec.fields as Record<string, { lake: string; model: string; kind: string }>;
            const timeField = fields[spec.time as string];
            const endField = spec.time === "from" ? fields.to : undefined;
            const list = out.get(spec.model) ?? [];
            for (let i = 0; i < table.rows; i++) {
                const targetIndex = table.columns.target?.[i];
                const target = typeof targetIndex === "number" ? doc.strings[targetIndex] : "";
                const shift = SHIFT[target] ?? 0;
                const row: Row = {};
                for (const def of Object.values(fields)) {
                    const raw = table.columns[def.lake]?.[i];
                    if (raw === null || raw === undefined) row[def.model] = null;
                    else if (def.kind === "string") row[def.model] = doc.strings[raw as number];
                    else if (def.kind === "timestamp") row[def.model] = new Date(epoch + (raw as number) + shift).toISOString();
                    else row[def.model] = raw;
                }
                const at = Date.parse(String(row[timeField.model]));
                const end = endField && row[endField.model] ? Date.parse(String(row[endField.model])) : null;
                list.push({ at, end, target, row });
            }
            out.set(spec.model, list);
        }
    }
    cached = out;
    return out;
}

const BOUND = /(>=|<=) DATE \( (\d+), (\d+), (\d+) \) \+ TIME \( (\d+), (\d+), (\d+) \)/g;

function bounds(dax: string): { from: number; to: number } {
    let from = -Infinity;
    let to = Infinity;
    for (const m of dax.matchAll(BOUND)) {
        const t = Date.UTC(+m[2], +m[3] - 1, +m[4], +m[5], +m[6], +m[7]);
        if (m[1] === ">=") from = t;
        else to = t;
    }
    return { from, to };
}

const list = (text: string | undefined) => (text ?? "").split(",").map((s) => s.trim().replace(/^"|"$/g, "")).filter(Boolean);

/** The sample's answer to the RCA's own queries, or null for any other query. */
export function sampleRcaRows(spec: QuerySpec): Row[] | null {
    if (spec.dax === RCA_PRESENCE_DAX) return [{ Rows: modelRows().get(RCA_SPEC.coverage.model)?.length ?? 0 }];
    if (spec.dax === NEWEST_BIN_DAX) return [{ Newest: new Date(SESSION_END).toISOString() }];
    const table = /CALCULATETABLE \(\s*'(RCA [A-Za-z]+)'/.exec(spec.dax)?.[1];
    if (table) {
        const { from, to } = bounds(spec.dax);
        const targets = list(/TREATAS \( \{ ([^}]*) \}, 'Target'\[Target Key\] \)/.exec(spec.dax)?.[1]);
        return (modelRows().get(table) ?? [])
            // As the history model answers rcaDax: an interval when it overlaps the window, any other row when its time is in it.
            .filter((r) => (r.end !== null ? r.end >= from : r.at >= from) && r.at <= to && (targets.length === 0 || targets.includes(r.target)))
            .sort((a, b) => a.at - b.at)
            .map((r) => r.row);
    }
    if (spec.dax.includes(`'Telemetry Snapshots'[Analysis Key] IN { "postgresql", "cosmosdb" }`)) {
        const { from, to } = bounds(spec.dax);
        const targets = list(/'Telemetry Snapshots'\[Target Key\] IN \{ ([^}]*) \}/.exec(spec.dax)?.[1]);
        const monitor: Row[] = [...sampleRows({ ...spec, id: "postgres-series" }), ...sampleRows({ ...spec, id: "cosmos-series" }).map((r): Row => ({ TargetKey: "T5", ...r }))];
        return monitor.filter((r) => {
            const at = Date.parse(String(r.Bucket).endsWith("Z") ? String(r.Bucket) : `${String(r.Bucket)}Z`);
            return at >= from && at <= to && targets.includes(String(r.TargetKey));
        });
    }
    return null;
}
