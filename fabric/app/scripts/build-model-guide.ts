// Writes src/copilot/model-guide.generated.ts from the history model's TMDL, the guide Copilot gets about
// SM_DatabaseHub_History's tables, columns, measures, and relationships. It leaves out the demo's answer key
// (src/copilot/answer-key.ts, ADR 0031): its tables and relationships, every measure that reads them, the grading
// analyses' rows, and any description clause that names a scenario. The chat investigates without them, the way a
// DBA's tools would, and run_dax refuses the measures this file lists (ANSWER_KEY_MEASURES). It writes nothing for a
// model that would let a query reach the answer key without naming it (denylistProblems).
// Usage: npm run guide:build   (src/copilot/guide.test.ts fails while the file is out of step with the TMDL)
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { ANSWER_KEY_ANALYSES, ANSWER_KEY_TABLES, answerKeyIn } from "../src/copilot/answer-key";
import { formatGuide, modelObjects, parseRelationships, parseTable, reachesAnswerKey, tableMembers, tableOfRef, type Relationship, type TmdlMember, type TmdlTable } from "../src/copilot/tmdl";

export const MODEL_DIR = resolve(import.meta.dirname, "../../powerbi/SM_DatabaseHub_History.SemanticModel/definition");
export const OUTPUT = resolve(import.meta.dirname, "../src/copilot/model-guide.generated.ts");

const isAnswerKey = (name: string) => (ANSWER_KEY_TABLES as readonly string[]).includes(name);
const touchesAnswerKey = (ref: string) => ANSWER_KEY_TABLES.some((table) => ref.includes(table));
/** The scenario catalog's IDs (the folders of scenarios/): a description that names one tells the chat what the demo runs. */
export const SCENARIO_IDS: readonly string[] = readdirSync(resolve(import.meta.dirname, "../../../scenarios"), { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);
const SCENARIO_TOKEN = new RegExp(`(?<![A-Za-z0-9_./-])(?:${SCENARIO_IDS.map((id) => id.replace(/[-]/g, "\\-")).join("|")})(?![A-Za-z0-9_./-])`, "i");
/** Text that names a scenario: the word, what was injected, or a scenario's ID in any case ("IO-pressure" too; the review of 34a9732). */
const namesScenario = (text: string) => /scenario|inject/i.test(text) || SCENARIO_TOKEN.test(text);

/** The text without the sentences or comma clauses that name a scenario: the model's descriptions are written for the presenter. */
export function withoutScenarioClauses(text: string): string {
    if (!namesScenario(text)) return text;
    return text
        .split(/(?<=[.!?])\s+/)
        .map((sentence) => {
            if (!namesScenario(sentence)) return sentence;
            const clauses = sentence.replace(/[.!?]$/, "").split(/,\s+/);
            const kept = clauses.filter((clause) => !namesScenario(clause));
            return kept.length > 0 ? `${kept.join(", ")}.` : "";
        })
        .filter(Boolean)
        .join(" ");
}

/** The tables Copilot may know: no answer-key table, measure, or grading row, and no description that names a scenario. */
export function blindTables(all: TmdlTable[]): { tables: TmdlTable[]; answerKeyMeasures: string[] } {
    const answerKeyMeasures = reachesAnswerKey(all, ANSWER_KEY_TABLES);
    const tables = all
        .filter((t) => !isAnswerKey(t.name))
        .map((t) => ({
            ...t,
            description: withoutScenarioClauses(t.description),
            columns: t.columns.map((c) => ({ ...c, description: withoutScenarioClauses(c.description) })),
            measures: t.measures.filter((m) => !answerKeyMeasures.includes(m.name)).map((m) => ({ ...m, description: withoutScenarioClauses(m.description) })),
            rows: t.rows.filter((r) => !namesScenario(r) && !ANSWER_KEY_ANALYSES.some((a) => r.startsWith(`{ "${a}"`))),
        }));
    return { tables, answerKeyMeasures };
}

/** The model as the denylist's checks read it: each table's TMDL, the relationships, the shared expressions, and the model's other DAX. */
export interface ModelFiles {
    tables: { name: string; text: string }[];
    relationships: Relationship[];
    /** Its shared expressions (expressions.tmdl), which a partition can read its rows through. */
    expressions: TmdlMember[];
    /** Its functions (functions.tmdl) and its roles' filters (roles/), when it has them. */
    other: { file: string; text: string }[];
}

export function readModel(modelDir: string = MODEL_DIR): ModelFiles {
    const read = (...path: string[]) => readFileSync(join(modelDir, ...path), "utf8");
    const tmdlIn = (dir: string) => (existsSync(join(modelDir, dir)) ? readdirSync(join(modelDir, dir)).filter((f) => f.endsWith(".tmdl")).sort() : []);
    return {
        tables: tmdlIn("tables").map((f) => {
            const text = read("tables", f);
            return { name: parseTable(text).name, text };
        }),
        relationships: parseRelationships(read("relationships.tmdl")),
        expressions: existsSync(join(modelDir, "expressions.tmdl")) ? modelObjects(read("expressions.tmdl")).filter((o) => o.kind === "expression") : [],
        other: [
            ...(existsSync(join(modelDir, "functions.tmdl")) ? [{ file: "functions.tmdl", text: read("functions.tmdl") }] : []),
            ...tmdlIn("roles").map((f) => ({ file: `roles/${f}`, text: read("roles", f) })),
        ],
    };
}

/** The lakehouse tables that hold the answer key (rca/blind-detection.json, answerKey.lakehouseTables). */
export const ANSWER_KEY_LAKEHOUSE_TABLES: readonly string[] = (
    JSON.parse(readFileSync(resolve(import.meta.dirname, "../../../rca/blind-detection.json"), "utf8")) as { answerKey: { lakehouseTables: string[] } }
).answerKey.lakehouseTables;

/** The key lakehouse tables a source names as whole names, in any case: a Direct Lake entityName, or an M source's Item, Id, or path. */
export function lakehouseTablesIn(text: string, tables: readonly string[] = ANSWER_KEY_LAKEHOUSE_TABLES): string[] {
    return tables.filter((t) => new RegExp(`(?<![A-Za-z0-9_])${t.replace(/[^A-Za-z0-9_]/g, "\\$&")}(?![A-Za-z0-9_])`, "i").test(text));
}

/** Whether TMDL or M text names an object, as written ('Key Rows', #"Key Rows", or KeyRows), in any case. */
const namesObject = (text: string, name: string) => new RegExp(`(?<![A-Za-z0-9_])${name.replace(/[^A-Za-z0-9_ ]/g, "\\$&")}(?![A-Za-z0-9_])`, "i").test(text);

/**
 * What in the model would let a DAX query reach the answer key without naming it, which run_dax's denylist rules out
 * (ADR 0031, section 8; the final review of 9b1896c). buildGuideSource writes no guide while there's any:
 * - a key table's name without a space, which DAX could write without quotes;
 * - a relationship that puts a key table on its one side, filters both ways (or automatically), or isn't many-to-one,
 *   so a filter on the key would reach another table, or another table's expanded table would hold the key's columns
 *   (learn.microsoft.com/dotnet/api/microsoft.analysisservices.tabular.crossfilteringbehavior);
 * - DAX outside the key's own tables and the refused measures that names a key table or a refused measure: a calculated
 *   column or table, a calculation item, detail rows, a model function, or a role's filter would read the key under a
 *   name run_dax doesn't refuse, in a ``` block at any indentation too (tableMembers);
 * - a partition of another table that reads a lakehouse table holding the key, by its entityName, its M source, or a
 *   shared expression that names one: that table would hold the key's rows under a name run_dax doesn't refuse (the
 *   review of 9f3d35f).
 */
export function denylistProblems(
    model: ModelFiles,
    refused: readonly string[],
    keyTables: readonly string[] = ANSWER_KEY_TABLES,
    lakehouseTables: readonly string[] = ANSWER_KEY_LAKEHOUSE_TABLES,
): string[] {
    const problems: string[] = [];
    const isKey = (name: string) => keyTables.some((k) => k.toLowerCase() === name.toLowerCase());
    const isRefused = (name: string) => refused.some((m) => m.toLowerCase() === name.toLowerCase());
    for (const table of keyTables) if (!/\s/.test(table)) problems.push(`'${table}' has no space in its name, so DAX could name it without quotes.`);
    for (const r of model.relationships) {
        const from = tableOfRef(r.from);
        const to = tableOfRef(r.to);
        if (!isKey(from) && !isKey(to)) continue;
        const what = `The relationship from ${r.from} to ${r.to}`;
        const p = r.properties ?? {};
        if (isKey(to)) problems.push(`${what} puts '${to}' on its one side: the key must be on the many side.`);
        if ((p.crossFilteringBehavior ?? "oneDirection") !== "oneDirection") problems.push(`${what} filters ${p.crossFilteringBehavior}: it must filter one way.`);
        if ((p.fromCardinality ?? "many") !== "many" || (p.toCardinality ?? "one") !== "one") problems.push(`${what} isn't many-to-one.`);
    }
    const keyExpressions = model.expressions.map((e) => ({ name: e.name, reads: lakehouseTablesIn(e.text, lakehouseTables) })).filter((e) => e.reads.length > 0);
    for (const table of model.tables.filter((t) => !isKey(t.name))) {
        for (const member of tableMembers(table.text)) {
            if (member.kind === "measure" && isRefused(member.name)) continue;
            const first = member.text.split("\n")[0];
            const named = answerKeyIn(member.text, refused, keyTables);
            if (named) problems.push(`'${table.name}' ${first} reads ${named}.`);
            if (member.kind !== "partition") continue;
            for (const source of lakehouseTablesIn(member.text, lakehouseTables)) problems.push(`'${table.name}' ${first} reads the lakehouse table ${source}, which holds the answer key.`);
            for (const e of keyExpressions.filter((x) => namesObject(member.text, x.name))) problems.push(`'${table.name}' ${first} reads ${e.name}, which reads the lakehouse table ${e.reads.join(", ")}.`);
        }
    }
    for (const { file, text } of model.other) {
        const named = answerKeyIn(text, refused, keyTables);
        if (named) problems.push(`${file} reads ${named}.`);
    }
    return problems;
}

export function buildGuideSource(modelDir: string = MODEL_DIR): string {
    const model = readModel(modelDir);
    const { tables, answerKeyMeasures } = blindTables(model.tables.map((t) => parseTable(t.text)));
    const problems = denylistProblems(model, answerKeyMeasures);
    if (problems.length > 0) {
        throw new Error(`The history model would let run_dax reach the demo's answer key without naming it (ADR 0031, section 8). Change the model:\n- ${problems.join("\n- ")}`);
    }
    const relationships = model.relationships.filter((r) => !touchesAnswerKey(r.from) && !touchesAnswerKey(r.to));
    const guide = formatGuide(tables, relationships);
    return [
        "// Generated by scripts/build-model-guide.ts from fabric/powerbi/SM_DatabaseHub_History.SemanticModel. Don't edit:",
        "// change the TMDL, then run npm run guide:build.",
        `export const MODEL_GUIDE = ${JSON.stringify(guide)};`,
        "",
        "/** The measures that read the demo's answer key, directly or through another measure: run_dax refuses them (ADR 0031). */",
        `export const ANSWER_KEY_MEASURES: readonly string[] = ${JSON.stringify(answerKeyMeasures)};`,
        "",
    ].join("\n");
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(import.meta.filename)) {
    writeFileSync(OUTPUT, buildGuideSource(), "utf8");
    console.log(`Wrote ${OUTPUT}`);
}
