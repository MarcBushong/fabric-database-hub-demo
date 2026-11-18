import { fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { validateChartSpec, type ChartSpec } from "@/copilot/contract";
import { buildChartModel, describeModel, detectXKind, formatValue, nearestIndex, yDomain } from "./chart-kit";
import { ChartView } from "./ChartView";

const CPU: ChartSpec = {
    kind: "line",
    title: "CPU per target",
    unit: "%",
    x: "at",
    series: "target",
    y: "cpu",
    rows: [
        { at: "2026-11-17T14:00:00Z", target: "T1", cpu: 12.5 },
        { at: "2026-11-17T14:00:00Z", target: "T3", cpu: 40.2 },
        { at: "2026-11-17T14:05:00Z", target: "T1", cpu: 15 },
        { at: "2026-11-17T14:05:00Z", target: "T3", cpu: 97.5 },
        { at: "2026-11-17T14:10:00Z", target: "T3", cpu: 60 },
    ],
};

describe("validateChartSpec", () => {
    it("accepts a well-formed spec and returns it", () => {
        const result = validateChartSpec(CPU);
        expect(result.ok).toBe(true);
        if (result.ok) expect(result.spec.series).toBe("target");
    });

    it("rejects what a model might get wrong, with the reason", () => {
        expect(validateChartSpec({ ...CPU, kind: "pie" })).toEqual({ ok: false, error: expect.stringMatching(/^kind must be one of line, area/) });
        expect(validateChartSpec({ ...CPU, title: " " })).toEqual({ ok: false, error: "title is required." });
        expect(validateChartSpec({ ...CPU, rows: [1, 2] })).toEqual({ ok: false, error: "Each row must be an object." });
        expect(validateChartSpec({ ...CPU, y: ["a", "b"] })).toEqual({ ok: false, error: "With series, y is one field." });
        expect(validateChartSpec({ ...CPU, rows: Array.from({ length: 5001 }, () => ({})) })).toEqual({ ok: false, error: "rows can hold at most 5000 rows." });
        expect(validateChartSpec(null)).toEqual({ ok: false, error: "A chart spec is an object." });
    });
});

describe("the chart kit", () => {
    it("splits long rows into one series per target over a UTC time axis", () => {
        const model = buildChartModel(CPU);
        expect(model.xKind).toBe("time");
        expect(model.series.map((s) => s.key)).toEqual(["T1", "T3"]);
        expect(model.xs).toEqual([Date.UTC(2026, 10, 17, 14, 0), Date.UTC(2026, 10, 17, 14, 5), Date.UTC(2026, 10, 17, 14, 10)]);
        expect(model.series[1].points.map((p) => p.y)).toEqual([40.2, 97.5, 60]);
    });

    it("makes one series per measure from wide rows, and finds the measures when y is missing", () => {
        const model = buildChartModel({ kind: "bar", title: "Waits", x: "target", rows: [{ target: "T1", lock: 2, io: 5 }, { target: "T2", lock: 1, io: 9 }] });
        expect(model.xKind).toBe("category");
        expect(model.yFields).toEqual(["lock", "io"]);
        expect(model.xs).toEqual(["T1", "T2"]);
    });

    it("reads zone-less ISO text as UTC, the way the history model stores it", () => {
        expect(detectXKind([{ t: "2026-10-21T10:00:00" }], "t")).toBe("time");
        expect(buildChartModel({ kind: "line", title: "x", x: "t", y: "v", rows: [{ t: "2026-10-21T10:00:00", v: 1 }] }).xs).toEqual([Date.UTC(2026, 9, 21, 10)]);
        expect(detectXKind([{ t: 3 }, { t: 4 }], "t")).toBe("number");
        expect(detectXKind([{ t: "T1" }], "t")).toBe("category");
        expect(detectXKind([{}], undefined)).toBe("index");
    });

    it("formats values with their unit and keeps percentages on a 0 to 100 axis", () => {
        expect(formatValue(97.5, "%")).toBe("97.5 %");
        expect(formatValue(241.4, "s")).toBe("241 s");
        expect(formatValue(12345, "count")).toBe("12.3K");
        expect(formatValue(null, "%")).toBe("–");
        const model = buildChartModel(CPU);
        expect(yDomain(model, model.series, false)).toEqual([0, 100]);
        const stacked = buildChartModel({ kind: "stackedBar", title: "s", x: "t", y: ["a", "b"], rows: [{ t: "x", a: 3, b: 4 }] });
        expect(yDomain(stacked, stacked.series, true)[1]).toBeCloseTo(7.42);
    });

    it("finds the nearest x and describes the chart for screen readers", () => {
        expect(nearestIndex([0, 10, 20], 14)).toBe(1);
        expect(nearestIndex([0, 10, 20], 16)).toBe(2);
        expect(nearestIndex([], 1)).toBe(-1);
        expect(describeModel(buildChartModel(CPU), "CPU per target")).toBe(
            "CPU per target from 17 Nov 14:00 UTC to 17 Nov 14:10 UTC. T1: from 12.5 % to 15 %, last 15 %; T3: from 40.2 % to 97.5 %, last 60 %.",
        );
    });
});

describe("ChartView", () => {
    it("draws one line per series without NaN, with a legend that hides a series", () => {
        const { container } = render(<ChartView spec={CPU} />);
        const lines = [...container.querySelectorAll("path.chart-line")].map((p) => p.getAttribute("d") ?? "");
        expect(lines).toHaveLength(2);
        for (const d of lines) {
            expect(d).toMatch(/^M[\d.]+,[\d.]+/);
            expect(d).not.toContain("NaN");
        }
        expect(container.querySelector("path.chart-line")?.getAttribute("stroke")).toBe("var(--target-t1)");
        const legend = screen.getByRole("group", { name: "CPU per target: series" });
        fireEvent.click(within(legend).getByRole("button", { name: "T1" }));
        expect(within(legend).getByRole("button", { name: "T1" })).toHaveAttribute("aria-pressed", "false");
        expect(container.querySelectorAll("path.chart-line")).toHaveLength(1);
    });

    it("reads values with the keyboard and announces them", () => {
        render(<ChartView spec={CPU} />);
        const plot = screen.getByRole("group", { name: "CPU per target" });
        fireEvent.keyDown(plot, { key: "End" });
        expect(screen.getByText("17 Nov 14:10 UTC: T1 –, T3 60 %")).toBeInTheDocument();
        fireEvent.keyDown(plot, { key: "ArrowLeft" });
        expect(screen.getByText("17 Nov 14:05 UTC: T1 15 %, T3 97.5 %")).toBeInTheDocument();
    });

    it("draws the app's annotations: an incident band, a warning line, and a peak marker", () => {
        const { container } = render(
            <ChartView
                spec={CPU}
                annotations={{
                    bands: [{ from: "2026-11-17T14:03:00Z", to: "2026-11-17T14:08:00Z", label: "Incident" }],
                    thresholds: [{ value: 80, label: "80 %: warning" }],
                    markers: [{ x: "2026-11-17T14:05:00Z", y: 97.5, label: "peak 97.5 %" }],
                }}
            />,
        );
        expect(container.querySelector(".chart-band rect")).not.toBeNull();
        expect(screen.getByText("80 %: warning")).toBeInTheDocument();
        expect(screen.getByText("peak 97.5 %")).toBeInTheDocument();
    });

    it("draws grouped and stacked bars", () => {
        const spec: ChartSpec = { kind: "bar", title: "Waits", x: "target", y: ["lock", "io"], unit: "s", rows: [{ target: "T1", lock: 2, io: 5 }, { target: "T2", lock: 1, io: 9 }] };
        const { container, rerender } = render(<ChartView spec={spec} />);
        expect(container.querySelectorAll("rect.chart-bar")).toHaveLength(4);
        rerender(<ChartView spec={{ ...spec, kind: "stackedBar" }} />);
        expect(container.querySelectorAll("rect.chart-bar")).toHaveLength(4);
    });

    it("shows KPI tiles and a sortable table", () => {
        const { rerender } = render(<ChartView spec={{ kind: "kpi", title: "Now", unit: "%", y: ["CPU", "Memory"], rows: [{ CPU: 42, Memory: 63.5 }] }} />);
        expect(screen.getByText("42 %")).toBeInTheDocument();
        expect(screen.getByText("63.5 %")).toBeInTheDocument();
        rerender(<ChartView spec={{ kind: "table", title: "Targets", rows: [{ target: "T2", cpu: 9 }, { target: "T1", cpu: 30 }] }} />);
        const table = screen.getByRole("table");
        fireEvent.click(within(table).getByRole("button", { name: "cpu" }));
        expect(within(table).getAllByRole("row")[1]).toHaveTextContent("T2");
        fireEvent.click(within(table).getByRole("button", { name: "cpu" }));
        expect(within(table).getAllByRole("row")[1]).toHaveTextContent("T1");
        expect(within(table).getByRole("columnheader", { name: "cpu" })).toHaveAttribute("aria-sort", "descending");
    });

    it("says so when there's nothing to chart", () => {
        render(<ChartView spec={{ kind: "line", title: "Empty", rows: [] }} />);
        expect(screen.getByText("No data to chart.")).toBeInTheDocument();
    });
});
