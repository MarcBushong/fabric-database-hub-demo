import { describe, expect, it, vi } from "vitest";

import { checkDax, createToolRunner, resultForModel, stripDaxComments, toolSpecs, type DaxRun } from "./tools";

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

    it("passes the live estate's source with its answer", async () => {
        const onEstate = vi.fn();
        const estate = vi.fn().mockResolvedValue({ source: ["POST /health/v2/filtered-summary"], data: { totalDatabases: 3 } });
        const runner = createToolRunner({ runDax: vi.fn(), estate, onEstate });
        const out = await runner.run("estate_overview", { view: "nonsense" });
        expect(estate).toHaveBeenCalledWith("inventory");
        expect(JSON.parse(out.text)).toMatchObject({ view: "inventory", data: { totalDatabases: 3 } });
        expect(onEstate.mock.calls[0][0].source[0]).toMatch(/filtered-summary/);
    });
});

describe("toolSpecs and resultForModel", () => {
    it("declares estate_overview only when the estate function is deployed", () => {
        expect(toolSpecs({ estate: false }).map((t) => t.name)).toEqual(["run_dax", "show_chart", "suggest_followups"]);
        expect(toolSpecs({ estate: true }).map((t) => t.name)).toContain("estate_overview");
    });

    it("bounds what Copilot reads to 120 rows", () => {
        const many = Array.from({ length: 500 }, (_, i) => ({ n: i }));
        const run: DaxRun = { id: "r1", query: "q", purpose: "p", columns: ["n"], rows: many, rowCount: 500, ms: 1, at: new Date(0) };
        expect(JSON.parse(resultForModel(run))).toMatchObject({ rowCount: 500, returnedRows: 120, truncated: true });
    });
});
