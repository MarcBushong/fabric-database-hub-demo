import { cpSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { ANSWER_KEY_LAKEHOUSE_TABLES, buildGuideSource, denylistProblems, lakehouseTablesIn, MODEL_DIR, OUTPUT, readModel, withoutScenarioClauses, type ModelFiles } from "../../scripts/build-model-guide";
import { INVESTIGATION_PLAYBOOK } from "@/rca/playbook";
import { readContract, namesAScenario } from "@/rca/testdata/contract";
import { ANSWER_KEY_ANALYSES, ANSWER_KEY_TABLES } from "./answer-key";
import { contextPrompt, endedWithoutAnswer, hasAnswer, NO_ANSWER, recap, reduceConversation, retryPrompt, toMarkdown, type AssistantTurn, type Turn } from "./conversation";
import { buildSystemMessage } from "./guide";
import { closeOpenMarks } from "./markdown-blocks";
import { relayRegion } from "./messages";
import { ANSWER_KEY_MEASURES, MODEL_GUIDE, SIDECAR_GUIDE } from "./model-guide.generated";
import { formatSidecarGuide, SIDECAR_GUIDE_TABLES, sidecarGuideProblems, sidecarModelTables, type ContractColumn, type HistoryContract } from "./sidecar-guide";
import { COSMOS_PROBE_DAX } from "./starters";
import { parseRelationships, parseTable, reachesAnswerKey, tableMembers, tableOfRef, toDaxRef } from "./tmdl";

describe("the model guide", () => {
    it("matches the history model's TMDL (run npm run guide:build after changing the model)", () => {
        expect(readFileSync(OUTPUT, "utf8").replace(/\r\n/g, "\n")).toBe(buildGuideSource());
    });

    // The coordinator's decision after review-qs-b: Query Store's six tables took about 20,000 of the always-on guide's
    // 57,000 characters. They get a compact section instead, which a conversation gets only when the model has them.
    it("leaves a sidecar table and its relationships out of the always-on guide", () => {
        const dir = mkdtempSync(join(tmpdir(), "dbhub-model-"));
        try {
            cpSync(MODEL_DIR, dir, { recursive: true });
            // A sidecar table as the model would hold it: an RCA table's shape under a sidecar table's name, related to Target.
            const resource = readFileSync(join(dir, "tables", "RCA Resource.tmdl"), "utf8");
            writeFileSync(join(dir, "tables", "RCA Query Stats.tmdl"), resource.replace("table 'RCA Resource'", "table 'RCA Query Stats'"), "utf8");
            const relationships = join(dir, "relationships.tmdl");
            writeFileSync(relationships, `${readFileSync(relationships, "utf8")}\nrelationship 'RCA Query Stats to Target'\n    fromColumn: 'RCA Query Stats'.'Target Key'\n    toColumn: Target.'Target Key'\n`, "utf8");
            const source = buildGuideSource(dir);
            const guide = JSON.parse(/export const MODEL_GUIDE = (".*");/.exec(source)![1]) as string;
            expect(guide).not.toContain("'RCA Query Stats'");
            expect(guide).toContain("'RCA Resource'[At UTC]");
            expect(source).toBe(readFileSync(OUTPUT, "utf8").replace(/\r\n/g, "\n"));
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    });

    it("gives the sidecar's tables a compact section from the contract: the columns to group or filter by, the measures, and the rule", () => {
        const contract = readContract<HistoryContract & { notebookColumns: ContractColumn[] }>("history-tables.json");
        const sidecar = sidecarModelTables(contract);
        expect([...sidecar].sort()).toEqual(["RCA Connections", "RCA Query Coverage", "RCA Query Events", "RCA Query Plans", "RCA Query Stats", "RCA Query Waits"]);
        for (const table of sidecar) {
            expect(MODEL_GUIDE).not.toContain(`'${table}'`);
            expect(SIDECAR_GUIDE).toContain(`- '${table}', `);
        }
        const measures = contract.measures.filter((m) => sidecar.includes(m.table));
        expect(measures).toHaveLength(7);
        for (const m of measures) expect(SIDECAR_GUIDE).toContain(`- [${m.name}] on '${m.table}': ${m.description}`);
        for (const g of SIDECAR_GUIDE_TABLES) for (const [column] of g.columns) expect(SIDECAR_GUIDE).toContain(`[${column}]`);
        expect(SIDECAR_GUIDE).toContain("use these measures, which take each interval's latest read, and never sum the tables' numeric columns");
        // No hidden column, and no source view.
        const hidden = [...contract.notebookColumns, ...contract.tables.filter((t) => sidecar.includes(t.model)).flatMap((t) => t.columns)].filter((c) => c.model.hidden).map((c) => c.model.column);
        expect(hidden).toEqual(expect.arrayContaining(["Run ID", "Document ID", "Report Date UTC", "Target Key", "Run Token"]));
        const columns = SIDECAR_GUIDE.slice(SIDECAR_GUIDE.indexOf("Columns to group or filter by:"));
        for (const column of hidden) {
            expect(columns).not.toContain(`[${column}]`);
            for (const table of sidecar) expect(SIDECAR_GUIDE).not.toContain(`'${table}'[${column}]`);
        }
        expect(SIDECAR_GUIDE).not.toMatch(/lakehouse table|dbo\./);
        expect(SIDECAR_GUIDE.length).toBeGreaterThan(3000);
        expect(SIDECAR_GUIDE.length).toBeLessThan(5000);
        expect(SIDECAR_GUIDE).not.toMatch(/scenario|inject|fixed minutes|incident window/i);
        expect(namesAScenario(SIDECAR_GUIDE)).toEqual([]);
    });

    it("writes no sidecar section for a contract its tables and columns don't match", () => {
        const contract = readContract<HistoryContract>("history-tables.json");
        expect(sidecarGuideProblems(contract)).toEqual([]);
        const changed = structuredClone(contract);
        const stats = changed.tables.find((t) => t.model === "RCA Query Stats")!;
        stats.columns.find((c) => c.model.column === "Module")!.model.column = "Object";
        stats.columns.find((c) => c.model.column === "Login")!.model.hidden = true;
        changed.tables.push({ ...stats, name: "rca_query_more", model: "RCA Query More" });
        expect(sidecarGuideProblems(changed)).toEqual([
            "'RCA Query More' is a sidecar table the guide doesn't describe.",
            "'RCA Query Stats'[Login] is hidden in the model.",
            "'RCA Query Stats'[Module] isn't in the contract.",
        ]);
        expect(() => formatSidecarGuide(changed)).toThrow(/doesn't match rca\/history-tables\.json/);
    });

    it("names the model's tables, measures, and target keys exactly as DAX needs them", () => {
        for (const name of ["'Telemetry Snapshots'[Bucket UTC]", "[CPU (%)]", "[Wait Time (s)]", "'Validation Results'", "{ \"T4\", \"T4 · Azure Database for PostgreSQL\""]) {
            expect(MODEL_GUIDE).toContain(name);
        }
        expect(MODEL_GUIDE).not.toMatch(/\[Focus /);
        expect(MODEL_GUIDE).toContain("'Telemetry Snapshots'[Target Key] -> 'Target'[Target Key]");
    });

    // ADR 0031: the chat investigates the way a DBA's tools would, so nothing it reads describes what the demo injected.
    it("leaves the demo's answer key out: its tables, every measure that reads them, the grading rows, and scenario wording", () => {
        const contract = readContract<{ answerKey: { modelTables: string[]; telemetryAnalyses: string[] }; chat: { modelGuideExcludes: string[] } }>("blind-detection.json");
        expect([...ANSWER_KEY_TABLES].sort()).toEqual([...contract.answerKey.modelTables].sort());
        expect([...ANSWER_KEY_TABLES].sort()).toEqual([...contract.chat.modelGuideExcludes].sort());
        expect([...ANSWER_KEY_ANALYSES].sort()).toEqual([...contract.answerKey.telemetryAnalyses].sort());
        for (const table of ANSWER_KEY_TABLES) expect(MODEL_GUIDE).not.toContain(table);
        // Through another measure, too: [CPU In Incident Window] reads [In Incident Window], which reads 'Incident Windows'.
        expect(ANSWER_KEY_MEASURES).toEqual(expect.arrayContaining(["In Incident Window", "CPU In Incident Window", "Incidents", "Findings", "Latest Capture UTC"]));
        for (const measure of ANSWER_KEY_MEASURES) expect(MODEL_GUIDE).not.toContain(`[${measure}]`);
        for (const analysis of ANSWER_KEY_ANALYSES) expect(MODEL_GUIDE).not.toContain(`{ "${analysis}"`);
        expect(MODEL_GUIDE).not.toMatch(/scenario|inject/i);
        expect(MODEL_GUIDE).toContain("[Log Rate Governor Wait (s)] (Waits and IO): Seconds of Log Rate Governor waits: Azure SQL Database's log-rate governance, which limits how fast a database writes its transaction log.");
        // run_dax refuses a measure by its name alone, so none may also name a column the chat can query.
        const columns = new Set([...MODEL_GUIDE.matchAll(/'[^']+'\[([^\]]+)\]/g)].map((m) => m[1].toLowerCase()));
        expect(ANSWER_KEY_MEASURES.filter((m) => columns.has(m.toLowerCase()))).toEqual([]);
    });

    it("finds the measures that reach a table, directly or through other measures, and drops scenario clauses", () => {
        const measure = (name: string, body: string) => ({ name, body, description: "", folder: "", format: "", hidden: false });
        const table = (name: string, measures: ReturnType<typeof measure>[]) => ({ name, description: "", source: "", columns: [], rows: [], measures });
        const reached = reachesAnswerKey(
            [
                table("Key", [measure("Hosted", "COUNTROWS ( 'Key' )"), measure("Constant", "1")]),
                table("Facts", [measure("Direct", "MAX ( 'Key'[At] )"), measure("Through", "IF ( [hosted], 1 )"), measure("Twice", "[Through] + 1"), measure("Clean", "SUM ( 'Facts'[Value] )")]),
            ],
            ["Key"],
        );
        // A measure the key hosts is refused whatever it reads: TABLEOF ( [Constant] ) would return the key's table.
        expect(reached).toEqual(["Constant", "Direct", "Hosted", "Through", "Twice"]);
        expect(withoutScenarioClauses("Seconds of Log Rate Governor waits: Azure SQL Database's log-rate governance, the T3 log-rate scenario's signature.")).toBe(
            "Seconds of Log Rate Governor waits: Azure SQL Database's log-rate governance.",
        );
        expect(withoutScenarioClauses("CPU per bin. Shows the injected scenario. Per target.")).toBe("CPU per bin. Per target.");
    });

    // The review of 34a9732: the guide still named two scenarios by their IDs ("missing-index", "ru-storm", and "IO-pressure"
    // in another case), with or without the RCA tables.
    it("names no scenario by its ID, in any case, in the guide or a description it keeps", () => {
        expect(namesAScenario(MODEL_GUIDE)).toEqual([]);
        expect(namesAScenario(MODEL_GUIDE.toLowerCase())).toEqual([]);
        expect(withoutScenarioClauses("The IO-pressure and missing-index signal. Buffer IO waits.")).toBe("Buffer IO waits.");
        expect(withoutScenarioClauses("Normalized RU per minute, 0 to 100 %, an ru-storm leaves it at 100 %.")).toBe("Normalized RU per minute, 0 to 100 %.");
    });

    // The re-review of 817b81c: INFO.VIEW.MEASURES () read scenario names from the model's own descriptions. run_dax refuses
    // the INFO functions now, and the model holds none to read: no description in any table names a scenario, and nothing in a
    // table the chat may query, or in the model's other files, mentions one. The answer-key tables hold them as their data.
    it("holds no scenario name in the model's metadata, where a metadata query could read it", () => {
        const tableDir = join(MODEL_DIR, "tables");
        const files = readdirSync(tableDir).filter((f) => f.endsWith(".tmdl"));
        expect(files.length).toBeGreaterThan(10);
        const isKey = (file: string) => (ANSWER_KEY_TABLES as readonly string[]).includes(file.replace(/\.tmdl$/, ""));
        for (const file of files) {
            const text = readFileSync(join(tableDir, file), "utf8");
            const descriptions = text.split(/\r?\n/).filter((line) => line.trim().startsWith("///")).join("\n");
            expect(namesAScenario(descriptions.toLowerCase()), file).toEqual([]);
            if (isKey(file)) continue;
            expect(namesAScenario(text.toLowerCase()), file).toEqual([]);
            expect(descriptions, file).not.toMatch(/scenario|inject/i);
        }
        for (const file of readdirSync(MODEL_DIR).filter((f) => f.endsWith(".tmdl"))) {
            expect(namesAScenario(readFileSync(join(MODEL_DIR, file), "utf8").toLowerCase()), file).toEqual([]);
        }
        // TABLEOF reaches a measure's or a calendar's table, so every measure an answer-key table hosts is refused, whatever it
        // reads, and no answer-key table has a calendar.
        const hosted = files.filter(isKey).flatMap((f) => parseTable(readFileSync(join(tableDir, f), "utf8")).measures.map((m) => m.name));
        expect(hosted).toEqual(expect.arrayContaining(["Injected Faults", "Scenario Requests", "Throttling Episodes"]));
        expect(ANSWER_KEY_MEASURES).toEqual(expect.arrayContaining(hosted));
        for (const file of files.filter(isKey)) expect(readFileSync(join(tableDir, file), "utf8"), file).not.toMatch(/^\s*calendar\s/m);
    });

    // The final review of 9b1896c: run_dax's denylist rests on the model's shape, which a later model change could weaken
    // quietly. The generator writes no guide for a model that breaks it, and these pin each rule.
    it("keeps the shape the denylist rests on: key names with a space, one-way many-to-one relationships with the key on the many side, and no other DAX that reads the key", () => {
        const model = readModel();
        expect(denylistProblems(model, ANSWER_KEY_MEASURES)).toEqual([]);
        // Not vacuous: every key table's relationships were read, and so was every calculated table.
        const keyed = model.relationships.filter((r) => (ANSWER_KEY_TABLES as readonly string[]).includes(tableOfRef(r.from)));
        expect(new Set(keyed.map((r) => tableOfRef(r.from)))).toEqual(new Set(ANSWER_KEY_TABLES));
        expect(keyed.length).toBeGreaterThanOrEqual(12);
        const calculated = model.tables.filter((t) => tableMembers(t.text).some((m) => m.kind === "partition" && /=\s*calculated/.test(m.text)));
        expect(calculated.map((t) => t.name)).toEqual(expect.arrayContaining(["Analysis", "Date", "Signal", "Status", "Target"]));
        // And each key table's partition reads its own key lakehouse table, which the guard flags in any other table.
        const keySources = model.tables
            .filter((t) => (ANSWER_KEY_TABLES as readonly string[]).includes(t.name))
            .flatMap((t) => lakehouseTablesIn(tableMembers(t.text).filter((m) => m.kind === "partition").map((m) => m.text).join("\n")));
        expect(keySources.sort()).toEqual([...ANSWER_KEY_LAKEHOUSE_TABLES].sort());
        expect(model.expressions.map((e) => e.name)).toEqual(["DirectLake - LH_DatabaseHub"]);
    });

    // The review of 9f3d35f: TMDL reads a ``` block verbatim, whatever its indentation, so the guard does too.
    it("reads a table's members with their ``` blocks, whatever the blocks' indentation", () => {
        const members = tableMembers(["table T", "    measure M = ```", "SUM ( 1 )", "  ```", "    column C", "        dataType: int64"].join("\n"));
        expect(members.map((m) => [m.kind, m.name])).toEqual([["measure", "M"], ["column", "C"]]);
        expect(members[0].text.split("\n")).toEqual(["measure M = ```", "SUM ( 1 )", "```"]);
    });

    // The coordinator's hardening of 9f3d35f: run_dax refuses any character outside plain ASCII in a query's code, which
    // costs the chat no query only while every name it may query is plain ASCII.
    it("names every table, column, measure, and hierarchy the chat may query in plain ASCII", () => {
        const blind = readModel().tables.filter((t) => !(ANSWER_KEY_TABLES as readonly string[]).includes(t.name));
        const names = blind.flatMap((t) => [t.name, ...[...t.text.matchAll(/^\s*(?:column|measure|hierarchy|level|calculationItem|calendar)\s+('(?:[^']|'')+'|[^\s=]+)/gm)].map((m) => m[1])]);
        expect(names.length).toBeGreaterThan(250);
        expect(names.filter((name) => /[^\x20-\x7E]/.test(name))).toEqual([]);
    });

    describe("finds each way a model change could let a query reach the key without naming it", () => {
        const table = (name: string, ...lines: string[]) => ({ name, text: [`table '${name}'`, ...lines].join("\n") });
        const relationship = (from: string, to: string, ...properties: string[]) =>
            parseRelationships(["relationship r", `    fromColumn: ${from}`, `    toColumn: ${to}`, ...properties.map((p) => `    ${p}`)].join("\n"))[0];
        const clean: ModelFiles = {
            tables: [table("Facts", "    measure Rows = COUNTROWS ( 'Facts' )", "    measure 'Injected Faults' = COUNTROWS ( 'RCA Answer Key' )")],
            relationships: [relationship("'Scenario Runs'.'Target Key'", "Target.'Target Key'")],
            expressions: [{ kind: "expression", name: "DirectLake - LH_DatabaseHub", text: "expression 'DirectLake - LH_DatabaseHub' =\nlet\nSource = AzureStorage.DataLake(\"https://onelake.dfs.fabric.microsoft.com/w/l\")\nin\nSource" }],
            other: [],
        };
        // A refused measure may read the key, wherever it's hosted: run_dax refuses it by name.
        it("passes a model that keeps the shape", () => expect(denylistProblems(clean, ["Injected Faults"])).toEqual([]));
        const broken: Array<[string, Partial<ModelFiles>, RegExp]> = [
            ["both ways", { relationships: [relationship("'Scenario Runs'.'Target Key'", "Target.'Target Key'", "crossFilteringBehavior: bothDirections")] }, /filters bothDirections: it must filter one way/],
            ["automatic", { relationships: [relationship("'Incident Windows'.'Report Date UTC'", "Date.Date", "crossFilteringBehavior: automatic")] }, /filters automatic/],
            ["the key on the one side", { relationships: [relationship("'Telemetry Snapshots'.'Run ID'", "'Scenario Runs'.'Run ID'")] }, /puts 'Scenario Runs' on its one side/],
            ["many-to-many", { relationships: [relationship("'RCA Answer Key'.'Target Key'", "Target.'Target Key'", "toCardinality: many")] }, /isn't many-to-one/],
            ["one-to-one", { relationships: [relationship("'Analysis Findings'.'Target Key'", "Target.'Target Key'", "fromCardinality: one")] }, /isn't many-to-one/],
            ["a calculated column", { tables: [table("Facts", "    column Scenario = RELATED ( 'Scenario Runs'[Scenario] )", "        dataType: string")] }, /'Facts' column Scenario = RELATED .* reads Scenario Runs/],
            ["a calculated table", { tables: [table("Copy", "    partition Copy = calculated", "        source =", "                FILTER ( 'Incident  Windows', TRUE () )")] }, /'Copy' partition Copy = calculated reads Incident Windows/],
            ["a calculation item", { tables: [table("Lens", "    calculationGroup", "        calculationItem Key = CALCULATE ( SELECTEDMEASURE (), [ Injected Faults ] > 0 )")] }, /'Lens' calculationGroup reads \[Injected Faults\]/],
            ["a measure the refused list missed", { tables: [table("Facts", "    measure Leak = COUNTROWS ( 'Analysis Findings' )")] }, /'Facts' measure Leak = .* reads Analysis Findings/],
            ["a model function", { other: [{ file: "functions.tmdl", text: "function Faults = () => 'RCA Answer Key'" }] }, /functions\.tmdl reads RCA Answer Key/],
            // The coordinator's hardening of 9f3d35f: a name in lookalike or invisible characters reads the key too.
            ["a lookalike name", { tables: [table("Facts", "    column Leak = RELATED ( 'Scena\u00ADrio Runs'[Scenario] )", "        dataType: string")] }, /'Facts' column Leak = RELATED .* reads Scenario Runs/],
            // The review of 9f3d35f: TMDL reads a ``` block verbatim, whatever its indentation, column 0 included, and its
            // closing delimiter sets its left edge (learn.microsoft.com/analysis-services/tmdl/tmdl-overview#expressions).
            ["a calculated column's block at column 0", { tables: [table("Facts", "    column Leak = ```", "CALCULATE ( MAX ( 'Scenario Runs'[Profile] ) )", "```", "        dataType: string")] }, /'Facts' column Leak = ``` reads Scenario Runs/],
            ["a calculated table's block at column 0", { tables: [table("Copy", "    partition Copy = calculated", "        source = ```", "FILTER ( 'Incident Windows', TRUE () )", "```")] }, /'Copy' partition Copy = calculated reads Incident Windows/],
            [
                "a block that closes left of the members, after a refused measure",
                { tables: [table("Facts", "    measure 'Injected Faults' = COUNTROWS ( 'RCA Answer Key' )", "    column Leak = ```", "        CALCULATE ( MAX ( 'Scenario Runs'[Profile] ) )", "  ```")] },
                /'Facts' column Leak = ``` reads Scenario Runs/,
            ],
            // The review of 9f3d35f: a blind table's rows can come from a lakehouse table that holds the key.
            [
                "a Direct Lake partition on a key lakehouse table",
                { tables: [table("Copy", "    partition Copy = entity", "        mode: directLake", "        source", "            entityName: scenario_runs", "            schemaName: dbo", "            expressionSource: 'DirectLake - LH_DatabaseHub'")] },
                /'Copy' partition Copy = entity reads the lakehouse table scenario_runs, which holds the answer key/,
            ],
            [
                "an M partition on one",
                { tables: [table("Copy", "    partition Copy = m", "        mode: import", "        source =", "            let", '                Source = Lakehouse.Contents(null){[workspaceId = "w"]}[Data]{[lakehouseId = "l"]}[Data],', '                Rows = Source{[Id = "Incident_Windows", ItemKind = "Table"]}[Data]', "            in", "                Rows")] },
                /'Copy' partition Copy = m reads the lakehouse table incident_windows/,
            ],
            [
                "a shared expression that reads one",
                {
                    tables: [table("Copy", "    partition Copy = m", "        mode: import", "        source = #\"Key Rows\"")],
                    expressions: [{ kind: "expression", name: "Key Rows", text: 'expression \'Key Rows\' =\nlet\nSource = Sql.Database("s", "d"),\nRows = Source{[Schema = "dbo", Item = "rca_answer_key"]}[Data]\nin\nRows' }],
                },
                /'Copy' partition Copy = m reads Key Rows, which reads the lakehouse table rca_answer_key/,
            ],
        ];
        it.each(broken)("finds %s", (_what, change, problem) => {
            expect(denylistProblems({ ...clean, ...change }, ["Injected Faults"]).join("\n")).toMatch(problem);
        });
        it("finds a key table's name without a space", () => {
            expect(denylistProblems(clean, ["Injected Faults"], ["Scenario Runs", "Runs"])).toEqual(["'Runs' has no space in its name, so DAX could name it without quotes."]);
        });
    });

    it("writes no guide for a model that breaks that shape", () => {
        const dir = mkdtempSync(join(tmpdir(), "dbhub-model-"));
        try {
            cpSync(MODEL_DIR, dir, { recursive: true });
            const file = join(dir, "relationships.tmdl");
            const text = readFileSync(file, "utf8").replace(/(toColumn: Target\.'Target Key')(\r?\n\r?\nrelationship 'Scenario Runs to Status')/, "$1\n    crossFilteringBehavior: bothDirections$2");
            expect(text).toContain("crossFilteringBehavior: bothDirections");
            writeFileSync(file, text, "utf8");
            expect(() => buildGuideSource(dir)).toThrow(/reach the demo's answer key without naming it[\s\S]*'Scenario Runs'\.'Target Key' to Target\.'Target Key' filters bothDirections/);
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    });

    it("parses a table's description, columns, measures, and calculated rows", () => {
        const table = parseTable(
            [
                "/// The targets.",
                "table Target",
                "",
                "    /// Join key.",
                "    column 'Target Key'",
                "        dataType: string",
                "        isHidden",
                "",
                "    /// Busy.",
                "    measure 'Busy %' =",
                "            DIVIDE ( 1, 2 )",
                "        formatString: 0.0",
                "        displayFolder: CPU",
                "",
                "    partition Target = calculated",
                "        source =",
                "                DATATABLE ( \"K\", STRING, {",
                "                        { \"T1\" },",
                "                        { \"T2\" }",
                "                    } )",
            ].join("\n"),
        );
        expect(table).toMatchObject({ name: "Target", description: "The targets.", source: "calculated", rows: ['{ "T1" }', '{ "T2" }'] });
        expect(table.columns).toEqual([{ name: "Target Key", dataType: "string", description: "Join key.", hidden: true }]);
        expect(table.measures[0]).toMatchObject({ name: "Busy %", folder: "CPU", format: "0.0", description: "Busy." });
        expect(toDaxRef("'Analysis Findings'.'Status Key'")).toBe("'Analysis Findings'[Status Key]");
        expect(toDaxRef("Status.Status")).toBe("'Status'[Status]");
    });

    it("goes into the system message with the rules and the live source when it's deployed", () => {
        const withLive = buildSystemMessage({ estate: true, resourceGroup: "rg-dbhub-demo" });
        expect(withLive).toContain("estate_overview");
        expect(withLive).toContain("rg-dbhub-demo");
        expect(withLive).toContain("suggest_followups");
        expect(withLive).toContain(MODEL_GUIDE.slice(0, 200));
        expect(buildSystemMessage({ estate: false })).toMatch(/LIVE estate: not available/);
    });

    it("is blind, and adds the investigation playbook only when the model has the RCA tables (ADR 0031)", () => {
        const plain = buildSystemMessage({ estate: false });
        const rca = buildSystemMessage({ estate: false, rca: true });
        for (const message of [plain, rca]) {
            expect(message).not.toMatch(/scenario|inject|fixed minutes|incident window/i);
            for (const table of ANSWER_KEY_TABLES) expect(message).not.toContain(table);
        }
        expect(plain).not.toContain(INVESTIGATION_PLAYBOOK);
        expect(rca.endsWith(INVESTIGATION_PLAYBOOK)).toBe(true);
        expect(rca).toContain("times as the investigation tools state them");
        expect(new TextEncoder().encode(rca).length).toBeLessThan(96 * 1024);
    });

    it("adds Query Store's compact guide only when the model has the RCA tables and the sidecar's, before the playbook", () => {
        const both = buildSystemMessage({ estate: false, rca: true, sidecar: true });
        expect(both).toContain(`${MODEL_GUIDE}\n\n${SIDECAR_GUIDE}\n\n${INVESTIGATION_PLAYBOOK}`);
        expect(both.endsWith(INVESTIGATION_PLAYBOOK)).toBe(true);
        expect(new TextEncoder().encode(both).length).toBeLessThan(96 * 1024);
        for (const message of [buildSystemMessage({ estate: false, rca: true }), buildSystemMessage({ estate: false, sidecar: true })]) expect(message).not.toContain(SIDECAR_GUIDE);
    });

    // R925: the model ended a turn with suggest_followups and no answer, and said "401" to the audience.
    it("tells Copilot to finish with a written answer, never with codes or routes, and what to do when the live view isn't available", () => {
        const message = buildSystemMessage({ estate: true });
        expect(message).toContain("Always finish with a written answer");
        expect(message).toContain("never replaces the answer");
        expect(message).toContain("Never show HTTP status codes, error codes, route names, or raw error text");
        expect(message).not.toContain("End every answer by calling suggest_followups");
        const off = buildSystemMessage({ estate: true, liveUnavailable: "Database Hub's live view isn't available to the app" });
        expect(off).toContain("- LIVE estate: Database Hub's live view isn't available to the app. For questions about right now, answer from the history model");
        expect(off).toContain("Database Hub's own pages in the Fabric portal");
        expect(off).not.toContain("the estate_overview tool reads");
    });

    it("teaches T5 (Azure Cosmos DB) from its latest capture, with columns and measures the model has", () => {
        const message = buildSystemMessage({ estate: false });
        const rules = message.slice(0, message.indexOf("# The history model"));
        expect(rules).toContain(`TREATAS ( { "T5" }, 'Target'[Target Key] ), TREATAS ( LatestRun, 'Telemetry Snapshots'[Run ID] )`);
        const columns = new Set(rules.match(/'[^']+'\[[^\]]+\]/g));
        expect(columns.size).toBeGreaterThan(8);
        for (const column of columns) expect(MODEL_GUIDE).toContain(column);
        for (const measure of ["[CPU (%)]", "[Wait Time (s)]", "[Peak Norm RU (%)]", "[Throttled Requests (429s)]", "[RU Consumed]", "[Has Cosmos DB Bins]"]) {
            expect(rules).toContain(measure);
            expect(MODEL_GUIDE).toContain(measure);
        }
        expect(COSMOS_PROBE_DAX).toContain("[Has Cosmos DB Bins]");
    });

    // The owner, 2026-11-23: the chat said "T1 doesn't have Query Store". The tables no capture writes yet say so, and that
    // their emptiness says nothing about a target, so the chat can't read an empty RCA Queries as a target without one.
    it("says the RCA tables no capture writes yet are empty for that reason, never because a target has no Query Store", () => {
        const description = (table: string) => MODEL_GUIDE.split(`## '${table}' (lakehouse table dbo.`)[1].split("\n")[1];
        expect(description("RCA Queries")).toMatch(/^Not written yet: the capture doesn't collect Query Store's statistics yet, so this table is empty, and its emptiness says nothing about a target's Query Store: never that a target has none \(validate\.ps1's T1\.QUERYSTORE to T3\.QUERYSTORE say whether it's on\)\. /);
        expect(description("RCA Waits")).toMatch(/^Not written yet: the capture doesn't diff the wait statistics yet, so this table is empty, and its emptiness says nothing about the targets' waits or their Query Store; Telemetry Snapshots holds T1 to T3's waits by category\. /);
        // The tables the capture writes don't say it.
        for (const table of ["RCA Sessions", "RCA Events", "RCA Resource", "RCA Replica", "RCA Coverage"]) expect(description(table)).not.toMatch(/^Not written yet/);
        expect(MODEL_GUIDE).not.toMatch(/(?:has no|doesn't have|lacks|without)(?: a| any)? Query Store|Query Store (?:is|was) (?:off|not on)/i);
    });

    // F35 (i): the measures take each interval from its finest save once history is resolved, so overlapping saves no
    // longer both count in them; a raw sum of Value still does.
    it("teaches the measures over a raw sum of Value, without saying that overlapping captures both count in them (F35)", () => {
        const message = buildSystemMessage({ estate: false });
        const rules = message.slice(0, message.indexOf("# The history model"));
        expect(rules).toContain("Use the measures instead of summing 'Telemetry Snapshots'[Value] yourself");
        expect(rules).toContain("the measures take each interval from its finest save once history is resolved");
        expect(rules).not.toContain("both count in sums");
        expect(rules).not.toContain("pick each bin's latest capture");
    });
});

describe("the conversation", () => {
    it("streams deltas into one text part, then takes the final message", () => {
        let turns: Turn[] = [];
        turns = reduceConversation(turns, { type: "user", id: "u1", text: "Why?", at: 1 });
        turns = reduceConversation(turns, { type: "assistant-start", id: "a1", at: 2 });
        turns = reduceConversation(turns, { type: "delta", messageId: "m1", text: "T1 " });
        turns = reduceConversation(turns, { type: "delta", messageId: "m1", text: "peaked" });
        turns = reduceConversation(turns, { type: "followups", questions: ["And T3?"] });
        turns = reduceConversation(turns, { type: "message", messageId: "m1", text: "T1 peaked at 88 %." });
        turns = reduceConversation(turns, { type: "idle" });
        const answer = turns[1];
        expect(answer).toMatchObject({ role: "assistant", streaming: false, followups: ["And T3?"], parts: [{ type: "text", text: "T1 peaked at 88 %." }] });
        expect(recap(turns)).toBe("Viewer: Why?\nYou: T1 peaked at 88 %.");
        expect(reduceConversation(turns, { type: "reset" })).toEqual([]);
    });

    it("exports Markdown with every query's DAX", () => {
        let turns: Turn[] = [{ role: "user", id: "u", text: "CPU?", at: 0 }];
        turns = reduceConversation(turns, { type: "assistant-start", id: "a", at: 1 });
        turns = reduceConversation(turns, { type: "dax", run: { id: "r1", query: "EVALUATE ROW(\"a\", 1)", purpose: "CPU per target", columns: ["a"], rows: [{ a: 1 }], rowCount: 1, ms: 5, at: new Date(0) } });
        turns = reduceConversation(turns, { type: "error", message: "Copilot stopped." });
        const md = toMarkdown(turns);
        expect(md).toContain("```dax\nEVALUATE ROW(\"a\", 1)\n```");
        expect(md).toContain("> Copilot stopped.");
    });

    it("knows an answer from text before a query, and resumes a turn that ended without one (R925)", () => {
        const run = { id: "r1", query: "EVALUATE x", purpose: "Peak CPU", columns: ["a"], rows: [{ a: 1 }], rowCount: 1, ms: 5, at: new Date(0) };
        let turns: Turn[] = [{ role: "user", id: "u", text: "How is my estate?", at: 0 }];
        turns = reduceConversation(turns, { type: "assistant-start", id: "a", at: 1 });
        turns = reduceConversation(turns, { type: "message", messageId: "m1", text: "I'll check the history." });
        turns = reduceConversation(turns, { type: "dax", run });
        turns = reduceConversation(turns, { type: "followups", questions: ["Why T2?"] });
        turns = reduceConversation(turns, { type: "idle" });
        const ended = turns[1] as AssistantTurn;
        expect(hasAnswer(ended)).toBe(false);
        expect(endedWithoutAnswer(ended)).toBe(true);
        expect(toMarkdown(turns)).toContain(`> ${NO_ANSWER}.`);
        expect(retryPrompt("How is my estate?")).toContain('You didn\'t write an answer to my last question: "How is my estate?"');
        turns = reduceConversation(turns, { type: "resume" });
        expect(turns[1]).toMatchObject({ streaming: true });
        expect(endedWithoutAnswer(turns[1] as AssistantTurn)).toBe(false);
        turns = reduceConversation(turns, { type: "message", messageId: "m2", text: "T2 needs attention first." });
        turns = reduceConversation(turns, { type: "idle" });
        expect(hasAnswer(turns[1] as AssistantTurn)).toBe(true);
        expect(toMarkdown(turns)).not.toContain(NO_ANSWER);
        // A chart after the explanation is still an answer; a turn with no query needs only its text.
        const charted = { ...(turns[1] as AssistantTurn), parts: [{ type: "dax", run }, { type: "text", messageId: "m", text: "T2 peaked." }, { type: "chart", chart: { kind: "kpi", title: "t", rows: [] }, runId: "r1" }] } as AssistantTurn;
        expect(hasAnswer(charted)).toBe(true);
        expect(hasAnswer({ ...charted, parts: [{ type: "text", messageId: "m", text: "Hello." }] })).toBe(true);
        expect(hasAnswer({ ...charted, parts: [] })).toBe(false);
    });

    it("puts a visual's context in the prompt: source, filters, anomaly, DAX, and trimmed rows", () => {
        const rows = Array.from({ length: 150 }, (_, i) => ({ bucket: `2026-11-17T10:${String(i % 60).padStart(2, "0")}:00Z`, cpu: i, note: "x".repeat(60) }));
        const text = contextPrompt({
            title: "CPU per target",
            page: "performance",
            dax: "EVALUATE x",
            rows,
            totalRows: 900,
            truncated: true,
            source: "history",
            asOf: "2026-11-17T12:00:00Z",
            filters: { targets: ["T1", "T3"], period: "7d" },
            anomaly: { metric: "CPU", target: "T1", at: "2026-11-17T10:05:00Z", value: 88, baseline: 40, unit: "%" },
        });
        expect(text.startsWith("Why did CPU on T1 move at 2026-11-17T10:05:00Z?")).toBe(true);
        expect(text).toContain("Source: the lakehouse history (snapshots, not live), newest 2026-11-17T12:00:00Z.");
        expect(text).toContain("Filters: targets T1, T3; period 7d.");
        expect(text).toContain("value 88 % against a baseline of 40 %");
        expect(text).toMatch(/Its rows \(\d+ of 900, trimmed by the app\)/);
        expect(text.length).toBeLessThanOrEqual(7800);
    });
});

describe("streaming text and sign-in wording", () => {
    it("closes a bold, inline code, or code fence that hasn't finished streaming, and leaves balanced text alone", () => {
        expect(closeOpenMarks("**T2 (Arc-enab")).toBe("**T2 (Arc-enab**");
        expect(closeOpenMarks("Run `EVALUATE")).toBe("Run `EVALUATE`");
        expect(closeOpenMarks("```dax\nEVALUATE")).toBe("```dax\nEVALUATE\n```");
        expect(closeOpenMarks("**T2** ran `hot`")).toBe("**T2** ran `hot`");
        expect(closeOpenMarks("```\na ** b\n```\nok")).toBe("```\na ** b\n```\nok");
    });

    it("names the relay's Azure region from its Container Apps address, which is where GitHub sees the request come from", () => {
        expect(relayRegion("https://ca-dbhub-ask.blacksmoke-c858da71.westus3.azurecontainerapps.io")).toBe("westus3");
        expect(relayRegion("http://127.0.0.1:8788")).toBeNull();
        expect(relayRegion(null)).toBeNull();
    });
});