// F35's live check against a deployed history model: reads rows.dax's rows (fabric/powerbi/checks/f35) as JSON and writes
// what snapshot-value-bins.dax's F35 column and window-f35.dax must return for them, by the model's rule, with the shared
// finestPerInterval's window totals and peaks beside them.
// Usage: tsx scripts/f35-reference.ts <rows.json> [from, ISO UTC] [to, ISO UTC]
//   rows.json: rows as objects, or as arrays beside their column names (cols or columns), bare or under rows, Execute
//   Queries' results[0].tables[0], or a harness's tables by name (the first); keys with or without brackets. The
//   window defaults to 2026-11-21 15:00 to 17:15 UTC, the checks' own.
import { readFileSync } from "node:fs";

import { f35Check } from "../src/data/snapshot-value";

type Row = Record<string, unknown>;

function tableOf(json: unknown): { cols?: unknown[]; rows: unknown[] } {
    if (Array.isArray(json)) {
        const first: unknown = json[0];
        return first && typeof first === "object" && !Array.isArray(first) && "rows" in first ? tableOf(first) : { rows: json };
    }
    if (json && typeof json === "object") {
        const o = json as Record<string, unknown>;
        if (Array.isArray(o.rows)) return { cols: Array.isArray(o.cols) ? o.cols : Array.isArray(o.columns) ? o.columns : undefined, rows: o.rows };
        if (Array.isArray(o.results)) return tableOf((o.results[0] as Record<string, unknown> | undefined)?.tables);
        if (o.tables && typeof o.tables === "object") return tableOf(Array.isArray(o.tables) ? o.tables : Object.values(o.tables)[0]);
    }
    return { rows: [] };
}

function rowsOf(json: unknown): Row[] {
    const { cols, rows } = tableOf(json);
    const names = (cols ?? []).map((c) => String(c && typeof c === "object" ? (c as { name?: unknown }).name : c));
    const bare = (key: string) => key.replace(/^.*\[/, "").replace(/\]$/, "");
    return rows.map((r) => {
        const out: Row = {};
        if (Array.isArray(r)) r.forEach((value: unknown, i) => (out[bare(names[i] ?? String(i))] = value));
        else for (const [key, value] of Object.entries(r as Row)) out[bare(key)] = value;
        return out;
    });
}

const [file, fromArg, toArg] = process.argv.slice(2);
if (!file) {
    console.error("Usage: tsx scripts/f35-reference.ts <rows.json> [from] [to]");
    process.exit(2);
}
const from = new Date(fromArg ?? "2026-11-21T15:00:00Z");
const to = new Date(toArg ?? "2026-11-21T17:15:00Z");
const check = f35Check(rowsOf(JSON.parse(readFileSync(file, "utf8"))), from, to);
console.log(JSON.stringify({ from: from.toISOString(), to: to.toISOString(), ...check }, null, 2));