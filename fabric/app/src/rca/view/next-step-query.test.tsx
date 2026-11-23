import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { queryStoreQuery, type QueryStoreQuery } from "@/rca/query-store";
import { namesAScenario } from "@/rca/testdata/contract";
import type { InvestigationResult } from "@/rca/types";
import { RcaReport } from "@/rca/view/RcaReport";
import { renderWithApp } from "@/test/render";

// The next steps' ready-to-run Query Store queries in the Root cause view, each with its Copy button (ADR 0031, section 8):
// the tools build them from the incident's measured target, family, and times (tools.test.ts), and the view shows and
// copies them as they are.

const now = new Date("2026-11-20T16:00:00Z");
const minutes = { start: new Date("2026-11-20T15:40:00Z"), end: new Date("2026-11-20T15:50:00Z"), last: new Date("2026-11-20T15:49:00Z") };
const t1 = queryStoreQuery({ target: "T1", family: "cpu", ...minutes }, now) as QueryStoreQuery;
const t4 = queryStoreQuery({ target: "T4", family: "cpu", ...minutes }, now) as QueryStoreQuery;

function incidentWith(details: Record<string, unknown>): InvestigationResult {
    return {
        tool: "explain_incident",
        version: 1,
        window: { fromUtc: "2026-11-20T15:40:00Z", toUtc: "2026-11-20T15:50:00Z" },
        targets: ["T1", "T4"],
        episodes: [],
        findings: [],
        rootCause: null,
        recommendations: [],
        nextSteps: ["Read Query Store on T1 for the queries and plans that used the CPU.", "Read Query Store on T4 for the queries that took the most time."],
        notCaptured: [],
        details,
    };
}

const writeText = vi.fn(async (text: string) => {
    void text;
});

beforeEach(() => {
    writeText.mockReset();
    vi.stubGlobal("isSecureContext", true);
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
});

afterEach(() => {
    cleanup();
    Reflect.deleteProperty(navigator, "clipboard");
    vi.unstubAllGlobals();
});

describe("the next steps' Query Store queries", () => {
    it("shows each as the tools built it, with its target, database, and minutes, and copies it exactly", async () => {
        const { notify } = renderWithApp(<RcaReport incident={incidentWith({ queryStoreQueries: [t1, t4] })} errors={null} timeZone="America/New_York" logs={[]} />);
        const next = screen.getByRole("region", { name: "Next steps" });
        expect([...next.querySelectorAll("pre")].map((p) => p.textContent)).toEqual([t1.text, t4.text]);
        const t1About = "T1's Query Store in ContosoCare, from 10:40 EST (15:40 UTC) to 10:50 EST (15:50 UTC)";
        const t4About = "T4's Query Store in azure_sys, from 10:40 EST (15:40 UTC) to 10:50 EST (15:50 UTC)";
        expect(within(next).getByText(`Read-only query of ${t1About}`)).toBeInTheDocument();
        expect(within(next).getByText(`Read-only query of ${t4About}`)).toBeInTheDocument();

        fireEvent.click(within(next).getByRole("button", { name: `Copy the query of ${t4About}` }));
        await waitFor(() => expect(notify).toHaveBeenCalledWith("Query copied: run it in azure_sys on T4", "success"));
        expect(writeText).toHaveBeenCalledTimes(1);
        expect(writeText).toHaveBeenCalledWith(t4.text);
        expect(within(next).getByRole("button", { name: `Copy the query of ${t4About}` })).toHaveTextContent(/^Copied$/);
        expect(within(next).getByRole("button", { name: `Copy the query of ${t1About}` })).toHaveTextContent(/^Copy$/);
        // The tools' text, so blind: the section names no scenario.
        expect(namesAScenario(next.textContent ?? "")).toEqual([]);
        expect(namesAScenario((next.textContent ?? "").toLowerCase())).toEqual([]);
    });

    it("says one instant 'at' it", () => {
        const instant = queryStoreQuery({ target: "T3", family: "cpu", start: new Date("2026-11-20T15:45:00Z"), end: null, last: new Date("2026-11-20T15:45:00Z") }, now) as QueryStoreQuery;
        renderWithApp(<RcaReport incident={incidentWith({ queryStoreQueries: [instant] })} errors={null} timeZone="America/New_York" logs={[]} />);
        expect(screen.getByText("Read-only query of T3's Query Store in ContosoCare, at 10:45 EST (15:45 UTC)")).toBeInTheDocument();
    });

    it("says how many more the tools left out, and nothing for anything but a whole count", () => {
        renderWithApp(<RcaReport incident={incidentWith({ queryStoreQueries: [t1, t4], queryStoreQueriesLeftOut: 2 })} errors={null} timeZone="UTC" logs={[]} />);
        expect(within(screen.getByRole("region", { name: "Next steps" })).getByText("2 more queries for these minutes aren't shown here: select each incident in the list for its own.")).toBeInTheDocument();
        cleanup();
        renderWithApp(<RcaReport incident={incidentWith({ queryStoreQueries: [t1], queryStoreQueriesLeftOut: 1 })} errors={null} timeZone="UTC" logs={[]} />);
        expect(screen.getByText("1 more query for these minutes isn't shown here: select each incident in the list for its own.")).toBeInTheDocument();
        cleanup();
        for (const leftOut of [0, -1, 1.5, "2", null]) {
            renderWithApp(<RcaReport incident={incidentWith({ queryStoreQueries: [t1], queryStoreQueriesLeftOut: leftOut })} errors={null} timeZone="UTC" logs={[]} />);
            expect(screen.queryByText(/ more quer/), String(leftOut)).toBeNull();
            cleanup();
        }
    });

    it("asks the viewer to copy it by hand when the browser blocks the clipboard", async () => {
        writeText.mockRejectedValue(new Error("Write permission denied."));
        const execCommand = vi.fn(() => false);
        Object.defineProperty(document, "execCommand", { value: execCommand, configurable: true });
        try {
            const { notify } = renderWithApp(<RcaReport incident={incidentWith({ queryStoreQueries: [t1] })} errors={null} timeZone="UTC" logs={[]} />);
            const button = screen.getByRole("button", { name: /^Copy the query of T1's Query Store/ });
            fireEvent.click(button);
            await waitFor(() => expect(notify).toHaveBeenCalledWith("Copy is blocked here: select the query and press Ctrl+C", "warning"));
            expect(execCommand).toHaveBeenCalledWith("copy");
            expect(button).toHaveTextContent(/^Copy$/);
        } finally {
            Reflect.deleteProperty(document, "execCommand");
        }
    });

    it("shows nothing that isn't one of the tools' queries, and keeps the next steps", () => {
        const odd = [null, "SELECT 1", { ...t1, language: "sql" }, { ...t1, fromUtc: "not a time" }, { ...t1, text: "" }, { target: "T1" }];
        for (const details of [{ queryStoreQueries: odd }, { queryStoreQueries: "SELECT 1" }, {}]) {
            renderWithApp(<RcaReport incident={incidentWith(details)} errors={null} timeZone="UTC" logs={[]} />);
            const next = screen.getByRole("region", { name: "Next steps" });
            expect(next.querySelectorAll("pre, figure")).toHaveLength(0);
            expect(within(next).queryByRole("button", { name: /^Copy the query/ })).toBeNull();
            expect(within(next).getAllByRole("listitem")).toHaveLength(2);
            cleanup();
        }
    });
});
