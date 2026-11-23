import { describe, expect, it } from "vitest";
import { createSourceClient } from "@/data/query-client";
import { sampleRows } from "@/preview/sample-data";
import { sampleRcaRows } from "@/preview/sample-rca";
import { createRcaClient } from "./client";
import { bounded } from "./tools";
import type { InvestigationResult } from "./types";

// The review of 90e9d914: each episode's category, severity, and severityReason, the reason repeated in triage's
// hypotheses, pushed the chat's results past 60,000 characters. On the preview, 6 hours lost their details, and 24 hours
// ended " [cut]", invalid JSON without notCaptured or nextSteps, yet answered ok.

const LIMIT = 60_000;

function previewTools() {
    const client = createSourceClient([{ provenance: "sample", answers: () => true, fetch: async (spec) => ({ rows: sampleRcaRows(spec) ?? sampleRows(spec), requestId: "sample" }) }]);
    return createRcaClient(client, { timeZone: "UTC" });
}

describe("the chat's results, within what one answer holds", () => {
    it(
        "returns the preview's 6 and 24 hours as JSON that parses, with what wasn't captured and the window's verdicts",
        async () => {
            const rca = previewTools();
            const latest = (await rca.latest())!;
            const tools = await rca.tools();
            for (const hours of [6, 24]) {
                const window = { from: new Date(latest.getTime() - hours * 3_600_000).toISOString(), to: latest.toISOString() };
                for (const name of ["find_incidents", "triage_window"]) {
                    const answer = await tools.run(name, window);
                    expect(answer.ok, `${name} ${hours} h`).toBe(true);
                    expect(answer.text.length, `${name} ${hours} h`).toBeLessThanOrEqual(LIMIT);
                    const result = JSON.parse(answer.text) as InvestigationResult;
                    expect(Array.isArray(result.notCaptured), `${name} ${hours} h`).toBe(true);
                    expect(result.details, `${name} ${hours} h`).toMatchObject({ nothingAbnormal: false, quiet: expect.any(Array) });
                    // Whole, or cut by what it says it left out, never by its text.
                    const full = (await tools.investigate(name, window)) as InvestigationResult;
                    const more = (result.details?.more ?? {}) as Record<string, number>;
                    expect(result.episodes.length + (more.episodes ?? 0), `${name} ${hours} h`).toBe(full.episodes.length);
                    expect(result.notCaptured).toEqual(full.notCaptured);
                    expect(result.nextSteps).toEqual(full.nextSteps);
                }
            }
        },
        120_000,
    );
});

describe("bounded", () => {
    const episode = (i: number, severity: "high" | "medium" | "low") => ({
        key: `T1-cpu-20261117T${String(10 + Math.floor(i / 60)).padStart(2, "0")}${String(i % 60).padStart(2, "0")}00Z`,
        target: "T1" as const,
        family: "cpu",
        signal: "CPU",
        support: "sustained" as const,
        source: "Database Hub's telemetry",
        start: "2026-11-17T10:00:00Z",
        end: null,
        peak: "91 %",
        category: "cpu" as const,
        severity,
        severityReason: `${severity}: ${"x".repeat(400)}`,
    });
    const result = (n: number): InvestigationResult => ({
        tool: "triage_window",
        version: 1,
        window: { fromUtc: "2026-11-17T00:00:00Z", toUtc: "2026-11-18T00:00:00Z" },
        targets: ["T1"],
        episodes: Array.from({ length: n }, (_, i) => episode(i, i % 3 === 0 ? "high" : i % 3 === 1 ? "medium" : "low")),
        findings: Array.from({ length: n }, (_, i) => ({ ruleId: "TRIAGE-CPU", target: "T1", title: `T1: CPU ${"y".repeat(300)} ${i}`, detail: "Next: run_dax.", severity: "warning", evidence: [] })),
        rootCause: null,
        recommendations: [],
        nextSteps: ["run_dax for T1"],
        notCaptured: ["T1: no RCA capture recorded for 10:00:00-11:00:00 UTC; only the telemetry (Telemetry Snapshots) is known"],
        details: {
            hypotheses: Array.from({ length: n }, (_, i) => ({ target: "T1", family: "cpu", summary: `${"z".repeat(300)} ${i}`, episodeKey: episode(i, "high").key })),
            quiet: ["T2"],
            nothingAbnormal: false,
            readStoppedAt: "2026-11-17T20:00:00Z",
            filters: { categories: ["cpu"], severities: [], targets: [] },
            leftOut: { episodes: 3, hypotheses: 3, notCaptured: 0, byCategory: { io: 3 }, byTarget: { T1: 3 } },
            trees: "w".repeat(5000),
        },
    });

    it("keeps a result that fits whole", () => {
        const small = result(3);
        expect(bounded(small)).toBe(JSON.stringify(small));
    });

    it("leaves out each episode's severityReason first, and keeps every episode while that's enough", () => {
        const r = result(40);
        const text = bounded(r, JSON.stringify(r).length - 1000);
        const got = JSON.parse(text) as InvestigationResult;
        expect(got.episodes).toHaveLength(40);
        expect(got.episodes.every((e) => !("severityReason" in e))).toBe(true);
        expect(got.details).toMatchObject({ trees: "w".repeat(5000), cut: expect.stringMatching(/^Each episode's severityReason is left out to fit/) });
    });

    it("then keeps the verdicts and the filters, and as many of the most severe episodes as fit, saying how many more", () => {
        const r = result(200);
        const text = bounded(r, 20_000);
        expect(text.length).toBeLessThanOrEqual(20_000);
        const got = JSON.parse(text) as InvestigationResult;
        expect(got.details).toMatchObject({ quiet: ["T2"], nothingAbnormal: false, readStoppedAt: "2026-11-17T20:00:00Z", filters: { categories: ["cpu"] }, leftOut: { episodes: 3 } });
        expect(got.details).not.toHaveProperty("trees");
        const more = got.details!.more as { episodes: number; findings: number; hypotheses: number };
        expect(got.episodes.length + more.episodes).toBe(200);
        expect(got.findings.length + more.findings).toBe(200);
        expect((got.details!.hypotheses as unknown[]).length + more.hypotheses).toBe(200);
        // The most severe first: every high one kept before any medium or low.
        const highs = r.episodes.filter((e) => e.severity === "high").length;
        expect(got.episodes.length).toBeLessThan(highs);
        expect(got.episodes.every((e) => e.severity === "high")).toBe(true);
        expect(got.details!.cut).toMatch(/Cut to fit: \d+ more episodes, \d+ more findings, \d+ more hypotheses, the least severe and the last, are left out\. Ask about a narrower window/);
        expect(got.notCaptured).toEqual(r.notCaptured);
        expect(got.nextSteps).toEqual(r.nextSteps);
    });

    it("never returns text that doesn't parse, however little fits", () => {
        const r = { ...result(5), notCaptured: Array.from({ length: 50 }, (_, i) => `T1: gap ${i} ${"g".repeat(200)}`) };
        for (const limit of [3000, 1200, 400]) expect(() => JSON.parse(bounded(r, limit))).not.toThrow();
        const tiny = JSON.parse(bounded(r, 3000)) as InvestigationResult;
        expect(tiny.notCaptured.at(-1)).toMatch(/^\d+ more lines of what wasn't captured are left out to fit\.$/);
    });
});
