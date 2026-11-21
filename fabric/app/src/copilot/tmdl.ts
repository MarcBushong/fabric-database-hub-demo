// Reads the history model's TMDL into a compact guide for Copilot: every table with its description, columns,
// measures, and the rows of its small calculated tables, plus the relationships. scripts/build-model-guide.ts
// writes it to model-guide.generated.ts, and a test keeps that file in step with the TMDL.

import { foldNames } from "./answer-key";

export interface TmdlColumn {
    name: string;
    dataType: string;
    description: string;
    hidden: boolean;
}

export interface TmdlMeasure {
    name: string;
    description: string;
    folder: string;
    format: string;
    hidden: boolean;
    /** Its DAX and properties, as written: what reachesAnswerKey reads for the tables and measures it uses. */
    body: string;
}

export interface TmdlTable {
    name: string;
    description: string;
    source: string;
    columns: TmdlColumn[];
    measures: TmdlMeasure[];
    rows: string[];
}

const unquote = (name: string) => name.trim().replace(/^'(.*)'$/, "$1").replace(/''/g, "'");
const indentOf = (line: string) => line.length - line.replace(/^[\t ]+/, "").length;

export function parseTable(text: string): TmdlTable {
    const lines = text.replace(/\r\n/g, "\n").split("\n");
    const table: TmdlTable = { name: "", description: "", source: "", columns: [], measures: [], rows: [] };
    let doc: string[] = [];
    let current: TmdlColumn | TmdlMeasure | null = null;
    // Members (columns, measures, partitions) sit one level under the table; their properties and DAX sit deeper.
    let memberIndent = -1;
    let inPartition = false;
    for (const raw of lines) {
        const line = raw.trim();
        const indent = indentOf(raw);
        if (!line) continue;
        if (line.startsWith("///")) {
            doc.push(line.replace(/^\/\/\/\s?/, ""));
            continue;
        }
        const tableMatch = /^table\s+(.+)$/.exec(line);
        if (tableMatch && indent === 0) {
            table.name = unquote(tableMatch[1]);
            table.description = doc.join(" ");
            doc = [];
            continue;
        }
        const member = /^(column|measure|partition|hierarchy|annotation|variation)\s+('(?:[^']|'')+'|[^\s=]+)/.exec(line);
        if (member && indent > 0 && (memberIndent < 0 || indent === memberIndent)) {
            memberIndent = indent;
            inPartition = member[1] === "partition";
            current = null;
            if (member[1] === "column") {
                current = { name: unquote(member[2]), dataType: "", description: doc.join(" "), hidden: false };
                table.columns.push(current);
            } else if (member[1] === "measure") {
                const dax = line.slice(member[0].length).replace(/^\s*=\s*/, "");
                current = { name: unquote(member[2]), description: doc.join(" "), folder: "", format: "", hidden: false, body: dax };
                table.measures.push(current);
            } else if (inPartition) {
                const kind = /=\s*(\w+)/.exec(line);
                if (kind?.[1] === "entity") table.source = "lakehouse";
                if (kind?.[1] === "calculated") table.source = "calculated";
            }
            doc = [];
            continue;
        }
        doc = [];
        if (inPartition) {
            const entity = /^entityName:\s*(\S+)/.exec(line);
            if (entity) table.source = `lakehouse table dbo.${entity[1]}`;
            if (/^\{\s*".*\}\s*,?$/.test(line)) table.rows.push(line.replace(/,\s*$/, ""));
            continue;
        }
        if (!current) continue;
        const prop = /^(\w+)\s*:\s*(.*)$/.exec(line);
        if ("dataType" in current) {
            if (prop?.[1] === "dataType") current.dataType = prop[2];
            if (line === "isHidden") current.hidden = true;
        } else {
            current.body = current.body ? `${current.body}\n${line}` : line;
            if (prop?.[1] === "displayFolder") current.folder = prop[2];
            if (prop?.[1] === "formatString") current.format = prop[2];
            if (line === "isHidden") current.hidden = true;
        }
    }
    return table;
}

export interface Relationship {
    from: string;
    to: string;
    /** Its other properties as TMDL writes them (crossFilteringBehavior, fromCardinality, toCardinality, ...); a flag is "true". */
    properties?: Record<string, string>;
}

export function parseRelationships(text: string): Relationship[] {
    const out: Relationship[] = [];
    let current: Required<Relationship> | null = null;
    const done = (r: Required<Relationship> | null) => {
        if (r?.from && r.to) out.push(r);
    };
    for (const raw of text.replace(/\r\n/g, "\n").split("\n")) {
        const line = raw.trim();
        if (!line || line.startsWith("///")) continue;
        if (indentOf(raw) === 0) {
            done(current);
            current = /^relationship\s/.test(line) ? { from: "", to: "", properties: {} } : null;
            continue;
        }
        if (!current) continue;
        const prop = /^(\w+)\s*:\s*(.*)$/.exec(line);
        if (prop?.[1] === "fromColumn") current.from = prop[2];
        else if (prop?.[1] === "toColumn") current.to = prop[2];
        else if (prop) current.properties[prop[1]] = prop[2];
        else if (/^\w+$/.test(line)) current.properties[line] = "true";
    }
    done(current);
    return out;
}

/** The table of a TMDL column reference, 'Table'.'Column' or Table.Column. */
export function tableOfRef(tmdlRef: string): string {
    const m = /^('(?:[^']|'')+'|[^.]+)\./.exec(tmdlRef.trim());
    return m ? unquote(m[1]) : "";
}

export interface TmdlMember {
    /** column, measure, partition, expression, calculationGroup, and so on, or the name of a property of the table itself. */
    kind: string;
    /** Its name, unquoted, when it has one. */
    name: string;
    /** Its line and every line under it, its ``` blocks included, without the /// descriptions. */
    text: string;
}

/** A TMDL table file's members and the table's own properties, each with every line under it: all the DAX it holds. */
export function tableMembers(text: string): TmdlMember[] {
    return splitObjects(text, null, /^table\s/);
}

/** A model-level TMDL file's objects (expressions.tmdl, for one), each with every line under it. */
export function modelObjects(text: string): TmdlMember[] {
    return splitObjects(text, 0);
}

/**
 * Splits TMDL into objects, each with its line, every deeper line, and every line of a ``` block it opens. TMDL reads a
 * block verbatim, whatever its indentation, and the block's closing delimiter, not the file's indentation, sets its left
 * edge (learn.microsoft.com/analysis-services/tmdl/tmdl-overview#expressions; the review of 9f3d35f: a block at column 0,
 * or one that closed left of the members, escaped the model guard). Objects start at `level`, or, when it's null, at
 * the first indented line's indentation. A line before the first object that `skip` matches (a table's own line) is
 * skipped; any other line at column 0 outside a block belongs to the object above it.
 */
function splitObjects(text: string, level: number | null, skip?: RegExp): TmdlMember[] {
    const out: TmdlMember[] = [];
    let at = level;
    let inBlock = false;
    const add = (line: string) => {
        if (out.length === 0) out.push({ kind: "", name: "", text: line });
        else out[out.length - 1].text += `\n${line}`;
    };
    for (const raw of text.replace(/\r\n/g, "\n").split("\n")) {
        const line = raw.trim();
        if (inBlock) {
            add(line);
            inBlock = line !== "```";
            continue;
        }
        if (!line || line.startsWith("///")) continue;
        const indent = indentOf(raw);
        if (out.length === 0 && indent === 0 && skip?.test(line)) continue;
        if (at === null && indent > 0) at = indent;
        if (at !== null && indent <= at && (indent > 0 || at === 0)) {
            const m = /^(\w+)(?:\s+('(?:[^']|'')+'|[^\s=:]+))?/.exec(line);
            out.push({ kind: m?.[1] ?? "", name: m?.[2] ? unquote(m[2]) : "", text: line });
        } else {
            add(line);
        }
        inBlock = /=\s*```$/.test(line);
    }
    return out;
}

/** DAX as the answer-key checks compare it (answer-key.ts, foldNames), with [ name ] read as [name]. */
const comparable = (dax: string) => foldNames(dax).replace(/\[ /g, "[").replace(/ \]/g, "]");

/** A column or measure reference in DAX form: 'Table'[Name]. */
const ref = (table: string, name: string) => `'${table.replace(/'/g, "''")}'[${name}]`;

/**
 * The measures that read one of these tables, directly or through another measure, with every measure the tables
 * hold: the guide leaves them out and run_dax refuses them, because DAX names a measure without its table.
 */
export function reachesAnswerKey(tables: TmdlTable[], keyTables: readonly string[]): string[] {
    const measures = tables.flatMap((t) => t.measures.map((m) => ({ table: t.name, name: m.name, body: comparable(m.body) })));
    const reached = new Set(measures.filter((m) => keyTables.includes(m.table) || keyTables.some((k) => m.body.includes(foldNames(k)))).map((m) => m.name));
    for (let grew = true; grew; ) {
        grew = false;
        for (const m of measures) {
            if (reached.has(m.name)) continue;
            if ([...reached].some((name) => m.body.includes(`[${foldNames(name)}]`))) {
                reached.add(m.name);
                grew = true;
            }
        }
    }
    return [...reached].sort((a, b) => a.localeCompare(b));
}

/** 'Table'.'Column' or Table.Column (TMDL) as 'Table'[Column] (DAX). */
export function toDaxRef(tmdlRef: string): string {
    const m = /^('(?:[^']|'')+'|[^.]+)\.('(?:[^']|'')+'|.+)$/.exec(tmdlRef.trim());
    return m ? ref(unquote(m[1]), unquote(m[2])) : tmdlRef;
}

// Measures that only drive a report visual's color, text, or picker; Copilot never needs them.
const VISUAL_ONLY = /(Color|Font|Glyph|Rail|Alt Text|Headline|Tile Context|Label|Narrative|Band)$|^(Focus |Explorer|Active Filters)/;

/** The guide text: compact, but with every name exactly as DAX needs it. */
export function formatGuide(tables: TmdlTable[], relationships: Relationship[]): string {
    const out: string[] = [];
    const facts = tables.filter((t) => t.source.startsWith("lakehouse"));
    const dims = tables.filter((t) => !t.source.startsWith("lakehouse"));
    for (const t of [...facts, ...dims]) {
        out.push(`## '${t.name}' (${t.source || "table"})`);
        if (t.description) out.push(t.description);
        if (t.columns.length > 0) {
            out.push("Columns:");
            for (const c of t.columns) out.push(`- ${ref(t.name, c.name)} ${c.dataType}${c.description ? `: ${c.description}` : ""}`);
        }
        if (t.rows.length > 0) {
            out.push("Rows:");
            for (const r of t.rows) out.push(`  ${r}`);
        }
        const measures = t.measures.filter((m) => !VISUAL_ONLY.test(m.name));
        if (measures.length > 0) {
            out.push("Measures:");
            for (const m of measures) out.push(`- [${m.name}]${m.folder ? ` (${m.folder})` : ""}${m.description ? `: ${m.description}` : ""}`);
        }
        out.push("");
    }
    out.push("## Relationships (many-to-one: filters flow from the dimension to the fact)");
    for (const r of relationships) out.push(`- ${toDaxRef(r.from)} -> ${toDaxRef(r.to)}`);
    return out.join("\n");
}
