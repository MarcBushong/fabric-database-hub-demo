import { describe, expect, it, vi } from "vitest";

import { ALLOWED_ROUTES, readEstate, type EstateScope, type EstateView } from "../../rayfin/functions/src/estate-core";
import { catalogForCheck } from "@/data/queries";
import { INVESTIGATION_TOOL_NAMES } from "@/rca/tools";
import { checkDax, createToolRunner, daxCode, ESTATE_VIEWS, LIVE_NO_ANSWER, LIVE_UNAVAILABLE, plainCodeRefusal, resultForModel, stripDaxComments, toolSpecs, type DaxRun } from "./tools";

// Every route path the estate function can call, as text Copilot must never get (R925 review).
const ROUTE_TEXT = new RegExp(ALLOWED_ROUTES.map((r) => r.split(" ")[1].replace(/[/.]/g, "\\$&")).join("|"));

/** ASCII text in its fullwidth forms (U+FF01 to U+FF5E), spaces kept: what a lookalike name looks like. */
const fullwidth = (text: string) => text.replace(/[!-~]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 0xfee0));

const rows = [
    { "Bucket UTC": "2026-11-17T10:00:00.000Z", "Target Key": "T1", CpuPct: 41.23456 },
    { "Bucket UTC": "2026-11-17T10:05:00.000Z", "Target Key": "T1", CpuPct: 88.2 },
    { "Bucket UTC": "2026-11-17T10:00:00.000Z", "Target Key": "T3", CpuPct: 12 },
];

describe("checkDax", () => {
    it("accepts EVALUATE and DEFINE queries, comments first", () => {
        expect(checkDax("EVALUATE ROW(\"a\", 1)")).toBeNull();
        expect(checkDax("// why\n-- note\n/* block */ DEFINE VAR x = 1 EVALUATE ROW(\"a\", x)")).toBeNull();
        expect(stripDaxComments("/* a */ EVALUATE // b")).toBe("EVALUATE");
    });

    it("refuses anything that isn't a DAX query", () => {
        expect(checkDax("")).toMatch(/empty/);
        expect(checkDax("SELECT * FROM t")).toMatch(/EVALUATE/);
        expect(checkDax("DEFINE VAR x = 1")).toMatch(/no EVALUATE/);
        expect(checkDax(`EVALUATE ${"x".repeat(20_001)}`)).toMatch(/longer/);
    });

    // ADR 0031: the chat can't read the demo's answer key, even by writing DAX, nor through a measure that reads it.
    it("refuses the answer key's tables and the measures that read them, in plain words", () => {
        expect(checkDax("EVALUATE TOPN ( 20, 'Incident Windows' )")).toMatch(/^Incident Windows holds the demo's answer key/);
        expect(checkDax("EVALUATE FILTER ( 'analysis   findings', TRUE () )")).toMatch(/^Analysis Findings holds/);
        expect(checkDax("EVALUATE Scenario Runs")).toMatch(/^Scenario Runs holds/);
        expect(checkDax('EVALUATE ROW ( "n", [Incidents] )')).toMatch(/^\[Incidents\] reads the demo's answer key/);
        expect(checkDax("EVALUATE SUMMARIZECOLUMNS ( 'Telemetry Snapshots'[Bucket UTC], \"c\", [cpu in incident window] )")).toMatch(/^\[CPU In Incident Window\] reads/);
        expect(checkDax("EVALUATE SUMMARIZECOLUMNS ( 'Telemetry Snapshots'[Bucket UTC], \"CpuPct\", [CPU (%)], \"Blocked\", [Blocked Processes (peak)] )")).toBeNull();
    });

    // The review of 34a9732: a comment marker inside a string hid the rest of the query from the check, which then ran it.
    it("refuses the answer key behind a string that holds a comment marker", () => {
        for (const query of [
            `EVALUATE VAR s = "--" RETURN 'Scenario Runs'`,
            `EVALUATE VAR s = "a//" RETURN 'Scenario Runs'`,
            `EVALUATE VAR s = "/*"\nRETURN 'Scenario Runs'\n// */`,
            `EVALUATE VAR s = "--" RETURN ROW ( "n", [Injected Faults] )`,
            `EVALUATE VAR s = 'a--b' RETURN 'Incident Windows'`,
        ]) {
            expect(checkDax(query), query).toMatch(/answer key/);
        }
    });

    // The re-review of 817b81c: functions that read the whole model reached the answer key without naming it. COLUMNSTATISTICS
    // returned every column's range (the scenario IDs, the first and last injection, the number of faults), and
    // INFO.VIEW.MEASURES the descriptions that named scenarios.
    it("refuses the functions that read the whole model, however they're written", () => {
        for (const [query, refusal] of [
            ["EVALUATE COLUMNSTATISTICS ()", /^COLUMNSTATISTICS returns/],
            [`EVALUATE FILTER ( COLUMNSTATISTICS (), [Table Name] = "Scenario" & " Runs" )`, /^COLUMNSTATISTICS returns/],
            ["evaluate columnstatistics()", /^COLUMNSTATISTICS returns/],
            ["EVALUATE INFO.VIEW.MEASURES ()", /^INFO functions return/],
            [`EVALUATE SELECTCOLUMNS ( INFO.VIEW.MEASURES (), "d", [Description] )`, /^INFO functions return/],
            ["EVALUATE INFO.TABLES ()", /^INFO functions return/],
            ["EVALUATE info.view.columns()", /^INFO functions return/],
            ["EVALUATE INFO /* x */ . VIEW.TABLES ()", /^INFO functions return/],
            ["DEFINE VAR t = INFO.MEASURES () EVALUATE t", /^INFO functions return/],
            ["EVALUATE CALENDARAUTO ()", /^CALENDARAUTO reads/],
            ["EVALUATE CALENDARAUTO ( 6 )", /^CALENDARAUTO reads/],
            [`EVALUATE ROW ( "n", EXTERNALMEASURE ( "Injected" & " Faults", INTEGER ) )`, /^EXTERNALMEASURE names/],
        ] as const) {
            expect(checkDax(query), query).toMatch(refusal);
        }
    });

    it("refuses an answer-key measure however it's spaced, and only a function the query calls", () => {
        expect(checkDax('EVALUATE ROW ( "n", [ Injected Faults ] )')).toMatch(/^\[Injected Faults\] reads/);
        expect(checkDax("EVALUATE ROW ( \"n\", [Injected\n    Faults] )")).toMatch(/^\[Injected Faults\] reads/);
        // TABLEOF reaches a table only through a column or measure it names, and every measure an answer-key table hosts is refused.
        expect(checkDax("EVALUATE FILTER ( TABLEOF ( [Scenario Requests] ), TRUE () )")).toMatch(/^\[Scenario Requests\] reads/);
        expect(checkDax("EVALUATE TOPN ( 5, TABLEOF ( 'Telemetry Snapshots'[Metric] ) )")).toBeNull();
        expect(checkDax(`EVALUATE ROW ( "note", "INFO.VIEW and COLUMNSTATISTICS () aren't run" ) // CALENDARAUTO ()`)).toBeNull();
        expect(checkDax("EVALUATE SUMMARIZECOLUMNS ( 'Telemetry Snapshots'[Metric], \"Info\", [Wait Time (s)] )")).toBeNull();
    });

    // The coordinator's hardening of 9f3d35f: a key name spelled with lookalike or invisible characters passed the name
    // check, and the engine may compare names with a collation that doesn't tell them apart (width, a long s, a sharp s,
    // accents, or characters it gives no weight).
    it("refuses a key table or measure spelled with lookalike or invisible characters", () => {
        for (const [what, query, refusal] of [
            ["fullwidth", `EVALUATE TOPN ( 1, '${fullwidth("Incident Windows")}' )`, /^Incident Windows holds/],
            ["long s", "EVALUATE TOPN ( 1, 'Analy\u017Fis Findings' )", /^Analysis Findings holds/],
            ["zero-width joiner", "EVALUATE TOPN ( 1, 'Inci\u200Ddent Windows' )", /^Incident Windows holds/],
            ["soft hyphen", "EVALUATE TOPN ( 1, 'Scena\u00ADrio Runs' )", /^Scenario Runs holds/],
            ["an accent", "EVALUATE TOPN ( 1, 'Inc\u00EDdent Windows' )", /^Incident Windows holds/],
            ["a control inside", "EVALUATE TOPN ( 1, 'Incident\u0000 Windows' )", /^Incident Windows holds/],
            ["fullwidth measure", `EVALUATE ROW ( "n", [${fullwidth("Injected Faults")}] )`, /^\[Injected Faults\] reads/],
            ["long s measure", 'EVALUATE ROW ( "n", [Scenario Reque\u017Fts] )', /^\[Scenario Requests\] reads/],
            ["zero-width joiner measure", 'EVALUATE ROW ( "n", [Injec\u200Dted Faults] )', /^\[Injected Faults\] reads/],
            ["soft hyphen measure", 'EVALUATE ROW ( "n", [Injected Fa\u00ADults] )', /^\[Injected Faults\] reads/],
            ["sharp s measure", 'EVALUATE ROW ( "n", [History Freshne\u00DF Label] )', /^\[History Freshness Label\] reads/],
        ] as const) {
            expect(checkDax(query), what).toMatch(refusal);
        }
        // A whole-model function's name, too, folded before that check.
        expect(checkDax(`EVALUATE ${fullwidth("COLUMNSTATISTICS")} ()`)).toMatch(/^COLUMNSTATISTICS returns/);
        expect(checkDax("EVALUATE COLUMN\u200BSTATISTICS ()")).toMatch(/^COLUMNSTATISTICS returns/);
        expect(checkDax("EVALUATE INFO.VIEW.MEA\u00ADSURES ()")).toMatch(/^INFO functions return/);
    });

    // Every name in the model is plain ASCII (guide.test.ts), so the fold needn't know every character a collation ignores.
    it("refuses any other character outside plain ASCII in a query's code, and lets strings and comments hold any text", () => {
        for (const [what, query, char] of [
            ["a zero-width joiner for the space", "EVALUATE TOPN ( 1, 'Incident\u200DWindows' )", "U+200D"],
            ["an emoji, which an older collation may give no weight", "EVALUATE TOPN ( 1, 'Incident \u{1F600}Windows' )", "U+1F600 (\u{1F600})"],
            ["a Cyrillic I", "EVALUATE TOPN ( 1, '\u0406ncident Windows' )", "U+0406 (\u0406)"],
            ["a no-break space", "EVALUATE TOPN ( 1, 'Telemetry\u00A0Snapshots' )", "U+00A0"],
            ["a bell", "EVALUATE TOPN ( 1, 'Telemetry\u0007 Snapshots' )", "U+0007"],
            ["curly quotes", "EVALUATE TOPN ( 1, \u2018Telemetry Snapshots\u2019 )", "U+2018 (\u2018)"],
            ["an em dash for a minus", 'EVALUATE ROW ( "n", [CPU (%)] \u2014 1 )', "U+2014 (\u2014)"],
            // A column the query names itself, too: the rule can't tell it from the model's names, and says to rename it.
            ["a column the query names", "EVALUATE SUMMARIZECOLUMNS ( 'Target'[Target Key], \"\u0394 CPU\", [CPU (%)] ) ORDER BY [\u0394 CPU]", "U+0394 (\u0394)"],
        ] as const) {
            expect(checkDax(query), what).toMatch(/^The query has the character U\+[0-9A-F]{4,5}\b.*plain ASCII/);
            expect(checkDax(query), what).toContain(`the character ${char} outside a string`);
        }
        for (const query of [
            'EVALUATE ROW ( "Note", "Caf\u00E9 \u00B7 12 \u00B0C \u2014 \u{1F600}\u200B" )',
            "// R\u00E9sum\u00E9 \u2014 CPU per target\r\nEVALUATE SUMMARIZECOLUMNS ( 'Target'[Target Key], \"\u0394 CPU\", [CPU (%)] )",
            '/* \u00A0\u200B\u2028 */ EVALUATE ROW ( "a", 1 ) -- fin \u2713',
        ]) {
            expect(checkDax(query), query).toBeNull();
        }
    });

    // The same hardening: a line comment that ran past a line break the engine honors hid the code after it.
    it("ends a line comment at any line break the engine might honor, so no code hides behind one", () => {
        for (const [name, lineBreak] of [["CR", "\r"], ["NEL", "\u0085"], ["LS", "\u2028"], ["PS", "\u2029"]] as const) {
            expect(checkDax(`EVALUATE ROW ( "a", 1 ) // note${lineBreak}EVALUATE COLUMNSTATISTICS ()`), name).toMatch(/^COLUMNSTATISTICS returns/);
            expect(checkDax(`EVALUATE ROW ( "a", 1 ) -- note${lineBreak}EVALUATE INFO.VIEW.MEASURES ()`), name).toMatch(/^INFO functions return/);
        }
        expect(stripDaxComments('EVALUATE ROW ( "a", 1 ) // note\r\nEVALUATE ROW ( "b", 2 )')).toBe('EVALUATE ROW ( "a", 1 ) \r\nEVALUATE ROW ( "b", 2 )');
    });

    it("refuses none of the app's own queries for a character: the catalog's code is plain ASCII outside its strings", () => {
        const catalog = catalogForCheck(new Date(Date.UTC(2026, 10, 17)));
        expect(catalog.length).toBeGreaterThan(15);
        for (const spec of catalog) expect(plainCodeRefusal(spec.dax), spec.id).toBeNull();
    });

    it("reads strings and names whole when it strips comments, with their doubled quotes", () => {
        expect(stripDaxComments(`EVALUATE ROW ( "a", "--x" ) // tail`)).toBe(`EVALUATE ROW ( "a", "--x" )`);
        expect(stripDaxComments(`EVALUATE ROW ( "a", "say ""//"" here" ) -- tail`)).toBe(`EVALUATE ROW ( "a", "say ""//"" here" )`);
        expect(stripDaxComments(`EVALUATE 'a--b'[c /* d ]]] -- e`)).toBe(`EVALUATE 'a--b'[c /* d ]]]`);
        expect(stripDaxComments(`EVALUATE /* "a */ ROW ( "b", 1 )`)).toBe(`EVALUATE   ROW ( "b", 1 )`);
        expect(daxCode(`EVALUATE ROW ( "a", "INFO.X ()" ) // COLUMNSTATISTICS ()\n'b--c'[d /* e ]]] -- f`)).toBe(`EVALUATE ROW ( "", "" ) \n''[] `);
        // Naming a table in a comment is refused with it: the query runs as written.
        expect(checkDax(`EVALUATE ROW ( "a", 1 ) // not 'Scenario Runs'`)).toMatch(/^Scenario Runs holds/);
    });
});

describe("the tool runner", () => {
    it("runs DAX through the connector and answers with compact rows the chart can use", async () => {
        const runDax = vi.fn().mockResolvedValue(rows);
        const onDax = vi.fn();
        const runner = createToolRunner({ runDax, onDax });
        const out = await runner.run("run_dax", { query: "EVALUATE 'Telemetry Snapshots'", purpose: "CPU per bin" });
        expect(out.ok).toBe(true);
        const parsed = JSON.parse(out.text);
        expect(parsed).toMatchObject({ resultId: "r1", rowCount: 3, columns: ["Bucket UTC", "Target Key", "CpuPct"] });
        expect(parsed.rows[0]).toEqual(["2026-11-17T10:00:00Z", "T1", 41.2346]);
        expect(runDax).toHaveBeenCalledWith("EVALUATE 'Telemetry Snapshots'", 2000);
        expect(onDax.mock.calls[0][0]).toMatchObject({ id: "r1", purpose: "CPU per bin", rowCount: 3 });
    });

    it("reports a refused or failed query to Copilot and the viewer, without throwing", async () => {
        const onDax = vi.fn();
        const runner = createToolRunner({ runDax: vi.fn().mockRejectedValue(new Error("The model rejected the query: bad column")), onDax });
        expect(await runner.run("run_dax", { query: "DROP TABLE x", purpose: "p" })).toMatchObject({ ok: false, text: expect.stringMatching(/^Not run/) });
        expect(await runner.run("run_dax", { query: "EVALUATE x", purpose: "p" })).toMatchObject({ ok: false, text: expect.stringMatching(/bad column/) });
        expect(onDax).toHaveBeenCalledTimes(2);
        expect(onDax.mock.calls[1][0].error).toMatch(/bad column/);
    });

    it("draws a validated chart from a result, and refuses unknown columns or results", async () => {
        const onChart = vi.fn();
        const runner = createToolRunner({ runDax: vi.fn().mockResolvedValue(rows), onChart });
        await runner.run("run_dax", { query: "EVALUATE x", purpose: "p" });
        const ok = await runner.run("show_chart", { resultId: "r1", kind: "line", title: "T1 peaked at 88 %", x: "Bucket UTC", y: ["CpuPct"], series: "Target Key", unit: "percent" });
        expect(ok.ok).toBe(true);
        expect(onChart.mock.calls[0][0]).toMatchObject({ kind: "line", x: "Bucket UTC", y: "CpuPct", series: "Target Key", unit: "%", rows });
        expect(await runner.run("show_chart", { resultId: "r9", kind: "line", title: "t", x: "a", y: ["b"] })).toMatchObject({ ok: false });
        expect((await runner.run("show_chart", { resultId: "r1", kind: "bar", title: "t", x: "Nope", y: ["CpuPct"] })).text).toMatch(/Unknown column/);
        expect((await runner.run("show_chart", { resultId: "r1", kind: "line", title: "t", x: "Bucket UTC", y: ["CpuPct", "CpuPct"], series: "Target Key" })).text).toMatch(/one field/);
        expect((await runner.run("show_chart", { resultId: "r1", kind: "line", title: "t", x: "Bucket UTC", y: ["CpuPct"], unit: "constructor" })).ok).toBe(true);
    });

    it("shows follow-ups and says when the live estate isn't deployed", async () => {
        const onFollowups = vi.fn();
        const runner = createToolRunner({ runDax: vi.fn(), onFollowups });
        expect(await runner.run("suggest_followups", { questions: ["Why T1?", " ", "What next?"] })).toMatchObject({ ok: true });
        expect(onFollowups).toHaveBeenCalledWith(["Why T1?", "What next?"]);
        expect((await runner.run("estate_overview", { view: "health" })).text).toMatch(/isn't available/);
        expect((await runner.run("shell", {})).text).toMatch(/no tool named/);
    });

    it("shows the routes that answered in the dock's row, and gives Copilot the data without them", async () => {
        const onEstate = vi.fn();
        const estate = vi.fn().mockResolvedValue({ source: ["POST /savedView/resources/list"], data: { totalDatabases: 3 }, errors: [] });
        const runner = createToolRunner({ runDax: vi.fn(), estate, onEstate });
        const out = await runner.run("estate_overview", { view: "nonsense" });
        expect(estate).toHaveBeenCalledWith("inventory");
        expect(out.ok).toBe(true);
        expect(JSON.parse(out.text)).toMatchObject({ view: "inventory", data: { totalDatabases: 3 } });
        expect(JSON.parse(out.text).source).toBeUndefined();
        expect(out.text).not.toMatch(ROUTE_TEXT);
        expect(onEstate.mock.calls[0][0]).toMatchObject({ source: ["POST /savedView/resources/list"], result: { totalDatabases: 3 } });
    });

    // R925: Copilot repeated "401" from the route errors it was given. It gets plain words now; the routes stay in the function's log.
    it("gives Copilot one plain sentence when the live view isn't available, and doesn't call the function again", async () => {
        let off: string | null = null;
        const onEstate = vi.fn();
        // As the function answers: it lists each route it called in source, the failed ones too.
        const estate = vi.fn().mockResolvedValue({
            source: ["POST /health/v2/filtered-summary", "POST /cosmosDb/health/summary"],
            data: {},
            errors: ["POST /health/v2/filtered-summary: HTTP 401 Unauthorized", "POST /cosmosDb/health/summary: HTTP 401 Unauthorized"],
            unavailable: "Database Hub's live view isn't available to the app",
        });
        const runner = createToolRunner({ runDax: vi.fn(), estate, onEstate, liveOff: () => off, onLiveUnavailable: (r) => (off = r) });
        const first = await runner.run("estate_overview", { view: "health" });
        expect(first.ok).toBe(false);
        expect(first.text).toMatch(/^Database Hub's live view isn't available to the app\. Don't call estate_overview again/);
        expect(first.text).not.toMatch(/HTTP|401|\/health|cosmosDb/);
        expect(off).toBe("Database Hub's live view isn't available to the app.");
        expect(onEstate.mock.calls[0][0]).toMatchObject({ view: "health", source: [], error: "Database Hub's live view isn't available to the app." });
        const second = await runner.run("estate_overview", { view: "security" });
        expect(second).toMatchObject({ ok: false });
        expect(estate).toHaveBeenCalledTimes(1);
        // A sentence that carries a code or a route is replaced by the dock's own.
        const noisy = createToolRunner({ runDax: vi.fn(), estate: vi.fn().mockResolvedValue({ source: [], data: {}, unavailable: "HTTP 401 from /auth/warnings" }) });
        expect((await noisy.run("estate_overview", { view: "security" })).text).toMatch(new RegExp(`^${LIVE_UNAVAILABLE.replace(/\./g, "\\.")}`));
    });

    it("says in plain words when no route answered for another reason, without making it last the conversation", async () => {
        const onLiveUnavailable = vi.fn();
        const onEstate = vi.fn();
        // Every route failed: the function lists each one it called in source, with its reason in errors, and zeros in data.
        const routes = ["GET /auth/warnings", "GET /auditing/warnings", "GET /cmk/warnings"];
        const estate = vi.fn().mockResolvedValue({
            source: routes,
            data: { authentication: { warnings: [], warningCount: 0, complete: false }, auditing: { warnings: [], warningCount: 0, complete: false }, customerManagedKeys: { warnings: [], warningCount: 0, complete: false } },
            errors: routes.map((r) => `${r}: HTTP 503 Service Unavailable`),
        });
        const runner = createToolRunner({ runDax: vi.fn(), estate, onLiveUnavailable, onEstate });
        const out = await runner.run("estate_overview", { view: "security" });
        expect(out).toMatchObject({ ok: false });
        expect(out.text).toContain(LIVE_NO_ANSWER);
        expect(out.text).not.toMatch(/HTTP|503|warningCount/);
        expect(out.text).not.toMatch(ROUTE_TEXT);
        expect(onEstate.mock.calls[0][0]).toMatchObject({ view: "security", source: [], error: LIVE_NO_ANSWER });
        expect(onEstate.mock.calls[0][0].result).toBeUndefined();
        expect(onLiveUnavailable).not.toHaveBeenCalled();
        const thrown = createToolRunner({ runDax: vi.fn(), estate: vi.fn().mockRejectedValue(new Error("Function invoke failed: HTTP 500")) });
        const failed = await thrown.run("estate_overview", { view: "inventory" });
        expect(failed.text).toContain(LIVE_NO_ANSWER);
        expect(failed.text).not.toMatch(/HTTP|500/);
    });

    it("names a live answer's missing parts in plain words, with the data that came back", async () => {
        const onEstate = vi.fn();
        const estate = vi.fn().mockResolvedValue({
            source: ["POST /health/v2/filtered-summary", "POST /postgreSql/health/v2/summary"],
            data: { sql: { highCpu: 1 } },
            errors: ["POST /postgreSql/health/v2/summary: HTTP 502 Bad Gateway"],
        });
        const out = await createToolRunner({ runDax: vi.fn(), estate, onEstate }).run("estate_overview", { view: "health" });
        const body = JSON.parse(out.text);
        expect(body).toMatchObject({ view: "health", data: { sql: { highCpu: 1 } }, missing: ["the PostgreSQL health"] });
        expect(body.source).toBeUndefined();
        expect(out.text).not.toMatch(/HTTP|502/);
        expect(out.text).not.toMatch(ROUTE_TEXT);
        // The row lists only the route that answered.
        expect(onEstate.mock.calls[0][0].source).toEqual(["POST /health/v2/filtered-summary"]);
    });

    // The review of 754fc4c: the function lists a route in source before it calls it, so a total failure looked like an answer.
    it("never gives Copilot routes, HTTP codes, or the zeros of a failed read when every route answers 401 (the real estate function)", async () => {
        const scope: EstateScope = { subscriptionId: "11111111-2222-3333-4444-555555555555", resourceGroups: ["rg-dbhub-demo"] };
        // Built at run time so secret scanners never see a token-shaped literal.
        const token = ["eyJ", "x".repeat(24)].join("");
        const refused = vi.fn(async () => new Response(JSON.stringify({ errorCode: "InvalidTokenRefused", message: "Token validation failed" }), { status: 401 }));
        // Every route was called and failed (R924 keeps both: it sets unavailable for these, which the tool reads the same way).
        const direct = await readEstate("security", scope, token, refused);
        expect(direct.errors).toHaveLength(3);

        const onEstate = vi.fn();
        const runner = createToolRunner({ runDax: vi.fn(), estate: (view) => readEstate(view as EstateView, scope, token, refused), onEstate });
        for (const view of ESTATE_VIEWS) {
            const out = await runner.run("estate_overview", { view });
            expect(out.ok).toBe(false);
            expect(out.text).toMatch(/live view/);
            expect(out.text).toMatch(/run_dax/);
            expect(out.text).not.toMatch(/HTTP|401|InvalidTokenRefused|Token validation|warningCount|totalCount|"data"/);
            expect(out.text).not.toMatch(ROUTE_TEXT);
            const row = onEstate.mock.calls.at(-1)?.[0];
            expect(row).toMatchObject({ view, source: [] });
            expect(row.error).toBeTruthy();
            expect(row.error).not.toMatch(/HTTP|401|InvalidTokenRefused|Token validation/);
            expect(row.error).not.toMatch(ROUTE_TEXT);
            expect(row.result).toBeUndefined();
        }
    });

    // R924: a transient total failure (5xx, a timeout, the budget) returns data {} with errors only, and isn't unavailable.
    it("reads R924's shape for a transient total failure as no answer, and lets the next question try the live view again", async () => {
        let off: string | null = null;
        const onLiveUnavailable = vi.fn((reason: string) => (off = reason));
        const estate = vi
            .fn()
            .mockResolvedValueOnce({ source: [], data: {}, errors: ["POST /savedView/resources/list: HTTP 503 Service Unavailable"] })
            .mockResolvedValueOnce({ source: ["POST /savedView/resources/list"], data: {}, errors: ["Database Hub didn't answer within the budget"] })
            .mockResolvedValueOnce({ source: ["POST /savedView/resources/list"], data: { totalCount: 4 }, errors: [] });
        const runner = createToolRunner({ runDax: vi.fn(), estate, liveOff: () => off, onLiveUnavailable });
        for (let i = 0; i < 2; i++) {
            const out = await runner.run("estate_overview", { view: "inventory" });
            expect(out).toMatchObject({ ok: false });
            expect(out.text).toContain(LIVE_NO_ANSWER);
            expect(out.text).not.toMatch(/HTTP|503|budget/);
            expect(out.text).not.toMatch(ROUTE_TEXT);
        }
        const third = await runner.run("estate_overview", { view: "inventory" });
        expect(third.ok).toBe(true);
        expect(JSON.parse(third.text)).toMatchObject({ data: { totalCount: 4 } });
        expect(estate).toHaveBeenCalledTimes(3);
        expect(onLiveUnavailable).not.toHaveBeenCalled();
    });

    it("reminds Copilot to write the answer when it suggests follow-ups without one (R925)", async () => {
        let answered = false;
        const runner = createToolRunner({ runDax: vi.fn(), answered: () => answered });
        expect((await runner.run("suggest_followups", { questions: ["Why T2?"] })).text).toMatch(/haven't written the answer itself yet: write it now/);
        answered = true;
        expect((await runner.run("suggest_followups", { questions: ["Why T2?"] })).text).toBe("Shown under your answer.");
    });
});

describe("toolSpecs and resultForModel", () => {
    it("declares estate_overview only when the estate function is deployed, and the investigations only with the RCA tables", () => {
        expect(toolSpecs({ estate: false }).map((t) => t.name)).toEqual(["run_dax", "show_chart", "suggest_followups"]);
        expect(toolSpecs({ estate: true }).map((t) => t.name)).toContain("estate_overview");
        expect(toolSpecs({ estate: true, rca: true }).map((t) => t.name)).toEqual(["run_dax", "show_chart", "suggest_followups", "estate_overview", ...INVESTIGATION_TOOL_NAMES]);
    });

    it("routes the investigations to their runner, counts them as queries, and says so when they aren't offered", async () => {
        const investigations = { run: vi.fn().mockResolvedValue({ ok: true, text: "{}" }) };
        const runner = createToolRunner({ runDax: vi.fn(), investigations });
        expect(await runner.run("find_incidents", { at: "11:56" })).toEqual({ ok: true, text: "{}" });
        expect(investigations.run).toHaveBeenCalledWith("find_incidents", { at: "11:56" });
        expect(runner.isQuery("explain_locking")).toBe(true);
        expect(runner.isQuery("show_chart")).toBe(false);
        const without = createToolRunner({ runDax: vi.fn() });
        expect(await without.run("find_incidents", {})).toEqual({ ok: false, text: "There's no tool named find_incidents." });
    });

    it("bounds what Copilot reads to 120 rows", () => {
        const many = Array.from({ length: 500 }, (_, i) => ({ n: i }));
        const run: DaxRun = { id: "r1", query: "q", purpose: "p", columns: ["n"], rows: many, rowCount: 500, ms: 1, at: new Date(0) };
        expect(JSON.parse(resultForModel(run))).toMatchObject({ rowCount: 500, returnedRows: 120, truncated: true });
    });
});
