import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { buildGuideSource, OUTPUT } from "../../scripts/build-model-guide";
import { contextPrompt, recap, reduceConversation, toMarkdown, type Turn } from "./conversation";
import { buildSystemMessage } from "./guide";
import { closeOpenMarks } from "./markdown-blocks";
import { relayRegion } from "./messages";
import { MODEL_GUIDE } from "./model-guide.generated";
import { parseTable, toDaxRef } from "./tmdl";

describe("the model guide", () => {
    it("matches the history model's TMDL (run npm run guide:build after changing the model)", () => {
        expect(readFileSync(OUTPUT, "utf8").replace(/\r\n/g, "\n")).toBe(buildGuideSource());
    });

    it("names the model's tables, measures, and target keys exactly as DAX needs them", () => {
        for (const name of ["'Telemetry Snapshots'[Bucket UTC]", "[CPU (%)]", "[Wait Time (s)]", "'Incident Windows'[Window Start UTC]", "{ \"T4\", \"T4 · Azure Database for PostgreSQL\""]) {
            expect(MODEL_GUIDE).toContain(name);
        }
        expect(MODEL_GUIDE).not.toMatch(/\[Focus /);
        expect(MODEL_GUIDE).toContain("'Telemetry Snapshots'[Target Key] -> 'Target'[Target Key]");
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