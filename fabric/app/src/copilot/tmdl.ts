// Reads the history model's TMDL into a compact guide for Copilot: every table with its description, columns,
// measures, and the rows of its small calculated tables, plus the relationships. scripts/build-model-guide.ts
// writes it to model-guide.generated.ts, and a test keeps that file in step with the TMDL.

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
                current = { name: unquote(member[2]), description: doc.join(" "), folder: "", format: "", hidden: false };
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
}

export function parseRelationships(text: string): Relationship[] {
    const out: Relationship[] = [];
    let from = "";
    for (const raw of text.replace(/\r\n/g, "\n").split("\n")) {
        const line = raw.trim();
        const f = /^fromColumn:\s*(.+)$/.exec(line);
        const t = /^toColumn:\s*(.+)$/.exec(line);
        if (f) from = f[1];
        if (t && from) {
            out.push({ from, to: t[1] });
            from = "";
        }
    }
    return out;
}

/** A column or measure reference in DAX form: 'Table'[Name]. */
const ref = (table: string, name: string) => `'${table.replace(/'/g, "''")}'[${name}]`;

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
