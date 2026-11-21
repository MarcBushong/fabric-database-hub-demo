import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { buildGuideSource, MODEL_DIR, OUTPUT, withoutScenarioClauses } from "../../scripts/build-model-guide";
import { INVESTIGATION_PLAYBOOK } from "@/rca/playbook";
import { readContract, namesAScenario } from "@/rca/testdata/contract";
import { ANSWER_KEY_ANALYSES, ANSWER_KEY_TABLES } from "./answer-key";
import { contextPrompt, endedWithoutAnswer, hasAnswer, NO_ANSWER, recap, reduceConversation, retryPrompt, toMarkdown, type AssistantTurn, type Turn } from "./conversation";
import { buildSystemMessage } from "./guide";
import { closeOpenMarks } from "./markdown-blocks";
import { relayRegion } from "./messages";
import { ANSWER_KEY_MEASURES, MODEL_GUIDE } from "./model-guide.generated";
import { COSMOS_PROBE_DAX } from "./starters";
import { parseTable, reachesAnswerKey, toDaxRef } from "./tmdl";

describe("the model guide", () => {
    it("matches the history model's TMDL (run npm run guide:build after changing the model)", () => {
        expect(readFileSync(OUTPUT, "utf8").replace(/\r\n/g, "\n")).toBe(buildGuideSource());
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