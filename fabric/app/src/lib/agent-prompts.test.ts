import { describe, expect, it } from "vitest";

import type { Incident, TargetNames } from "@/data/model";
import {
    agentPeriod,
    binMinutes,
    coveragePrompt,
    databaseHubUrl,
    describeTarget,
    incidentPrompts,
    isoMinute,
    libraryPrompts,
    NO_CHANGE,
    olderThanRetention,
    promptsAsText,
    PROPOSE_ONLY,
    signalClause,
    sqlHost,
    timesPhrase,
    windowPhrase,
    type LibraryContext,
} from "./agent-prompts";
import type { IncidentComparison } from "./insights";

const NAMES: TargetNames = {
    T1: { resource: "sqlvm01", resourceType: "virtualMachines", instance: "MSSQLSERVER", database: "ContosoCare" },
    T2: { resource: "arcsql01", resourceType: "machines", instance: "MSSQLSERVER", database: "ContosoCare" },
    T3: { resource: "azuresql01-test01/ContosoCare", resourceType: "servers/databases", instance: "azuresql01-test01", database: "ContosoCare" },
};

const at = (h: number, m: number, day = 22) => new Date(Date.UTC(2026, 9, day, h, m));

function incident(patch: Partial<Incident> = {}): Incident {
    return {
        key: "detected:T2:io:1",
        label: "T2 IO pressure",
        source: "Detected signal",
        target: "T2",
        scenario: "",
        family: "io",
        start: at(14, 5),
        end: at(14, 35),
        durationMin: 30,
        peakValue: 11.5,
        peakUnit: "s",
        verdict: "",
        ...patch,
    };
}

const COMPARISON: IncidentComparison = { signal: "Buffer IO (PAGEIOLATCH) waits", kind: "seconds", baseline: 2.9, during: 11.4, peak: 11.5, peakAt: at(14, 20), ratio: 11.4 / 2.9 };

/** Every prompt keeps the prompt pack's safety rule: it ends with "Don't change anything" or "propose only". */
function expectSafe(text: string) {
    expect(text.endsWith(PROPOSE_ONLY) || /Don't change anything(\.|: .+\.)$/.test(text)).toBe(true);
}

describe("incident prompts for the Database Agent", () => {
    it("writes the investigation prompt from the window's own numbers", () => {
        const [cause] = incidentPrompts(incident(), COMPARISON, { names: NAMES }, "hub");
        expect(cause.text).toBe(
            "On T2 (Arc-enabled SQL Server arcsql01) between 14:05 and 14:35 UTC on 2026-10-22, Buffer IO (PAGEIOLATCH) waits peaked at 11.5 s per bin " +
                "and averaged about 4 times the baseline (2.9 s per bin in the 30 minutes before). What caused it, which sessions and queries were involved, " +
                "and what should I check or change? Name each signal you used. Don't apply anything; propose only.",
        );
    });

    it("names the bin length when the replay knows it, and skips the baseline when the window barely moved", () => {
        expect(signalClause(incident(), COMPARISON, 5)).toContain("11.5 s per 5-minute bin");
        expect(signalClause(incident(), { ...COMPARISON, ratio: 1.1 }, 5)).toBe("Buffer IO (PAGEIOLATCH) waits peaked at 11.5 s per 5-minute bin");
        expect(signalClause(incident(), null)).toBe("Buffer IO (PAGEIOLATCH) waits peaked at 11.5 s");
        expect(signalClause(incident({ family: "cpu", peakValue: null }), null)).toBe("the history recorded a cpu pressure window");
        expect(signalClause(incident({ family: "cpu" }), { ...COMPARISON, kind: "percent", peak: 97.5, ratio: 2.4, baseline: 30 })).toBe(
            "CPU peaked at 97.5 % and averaged about 2.4 times the baseline (30.0 % in the 30 minutes before)",
        );
    });

    it("gives four hub prompts that never ask the agent to act", () => {
        const prompts = incidentPrompts(incident(), COMPARISON, { names: NAMES }, "hub");
        expect(prompts.map((p) => p.title)).toEqual(["What caused it", "What moved with it", "Against the baseline", "The evidence"]);
        prompts.forEach((p) => expectSafe(p.text));
        expect(prompts[1].text).toContain("which of CPU, memory, the other waits, active sessions, and blocking changed at the same time");
        expect(prompts[2].text).toContain("with the 30 minutes before it (between 13:35 and 14:05 UTC on 2026-10-22)");
        expect(new Set(prompts.map((p) => p.id)).size).toBe(4);
    });

    it("formats the same window for the skills fallback, with the family's telemetry tables and SQL skill", () => {
        const prompts = incidentPrompts(incident(), COMPARISON, { names: NAMES, resourceGroup: "rg-dbhub-test" }, "skills");
        prompts.forEach((p) => expectSafe(p.text));
        const [telemetry, baseline, sql] = prompts;
        expect(telemetry.text).toContain("Using the telemetry agent instructions, write a KQL query on SqlServerStorageIO for arcsql01 in resource group rg-dbhub-test from 2026-10-22T14:05Z to 2026-10-22T14:35Z");
        expect(telemetry.text).toContain("Follow the rule for cumulative counters");
        expect(baseline.text).toContain("(2026-10-22T13:35Z to 2026-10-22T14:05Z)");
        expect(sql.text).toContain("Use the diagnose-resource-pressure skill on the ContosoCare database of arcsql01, connected as me");
        expect(sql.text).toContain("never with a SQL login or password");
        expect(sql.text).toContain("if it doesn't apply to Arc-enabled SQL Server, say so");
    });

    it("uses the blocking skill and its guard for blocking windows, and the logical server for T3", () => {
        const blocking = incidentPrompts(incident({ target: "T3", family: "blocking", key: "k" }), null, { names: NAMES }, "skills");
        expect(blocking[0].text).toContain("check azuresql01-test01/ContosoCare for blocking");
        expect(blocking[2].text).toContain("Use the diagnose-blocking-and-deadlocks skill on the ContosoCare database of azuresql01-test01,");
        expect(blocking[2].text).not.toContain("documented for Azure SQL Database");
        expect(blocking[2].text).toMatch(/don't KILL a session, and don't reproduce the block\.$/);
    });

    it("falls back to the target kind when the telemetry hasn't reported names yet", () => {
        const [cause] = incidentPrompts(incident({ target: "T1" }), null, { names: {} }, "hub");
        expect(cause.text.startsWith("On T1 (SQL Server on an Azure VM) between")).toBe(true);
        expect(sqlHost("T3", {})).toBe("T3");
        expect(sqlHost("T3", { T3: { resource: "azuresql01-x/ContosoCare", resourceType: null, instance: null, database: null } })).toBe("azuresql01-x");
    });
});

describe("prompt library", () => {
    const now = at(18, 0, 22);
    const base: LibraryContext = { names: NAMES, resourceGroup: "rg-dbhub-test", targets: ["T1", "T2", "T3"], period: { from: at(0, 0, 16), to: at(0, 0, 22) }, latestDay: at(0, 0, 22), now };

    it("covers estate health, top waits, blocking chains, and what changed, on both surfaces", () => {
        for (const surface of ["hub", "skills"] as const) {
            const prompts = libraryPrompts(base, surface);
            expect(prompts.map((p) => p.title)).toEqual(["Estate health", "Top waits per target", "Blocking chains", "What changed since the baseline"]);
            prompts.forEach((p) => expectSafe(p.text));
        }
        const [health, waits, , changed] = libraryPrompts(base, "hub");
        expect(health.text).toContain(
            "in resource group rg-dbhub-test: T1 (SQL Server on an Azure VM sqlvm01), T2 (Arc-enabled SQL Server arcsql01), and T3 (Azure SQL Database azuresql01-test01/ContosoCare)",
        );
        expect(waits.text).toContain("from 2026-10-16 to 2026-10-22 UTC");
        expect(changed.text).toContain("Use 2026-10-21 UTC as the baseline");
        expect(changed.text).toContain("On 2026-10-22 UTC");
        expect(libraryPrompts(base, "skills")[0].text).toContain("Use the Database Hub skill to show the SQL resources in resource group rg-dbhub-test");
    });

    it("follows the target chips and keeps the period inside the agent's 7 days", () => {
        const two = libraryPrompts({ ...base, targets: ["T3", "T1"] }, "hub");
        expect(two[1].text).toContain("For each of T1 (SQL Server on an Azure VM sqlvm01) and T3 (Azure SQL Database azuresql01-test01/ContosoCare),");
        expect(two[1].text).not.toContain("arcsql01");
        expect(libraryPrompts({ ...base, period: { from: at(0, 0, 1), to: at(0, 0, 22) } }, "hub")[1].text).toContain("over the last 7 days");
        expect(libraryPrompts({ ...base, period: null }, "hub")[1].text).toContain("over the last 7 days");
        expect(libraryPrompts({ ...base, period: { from: at(0, 0, 22), to: at(0, 0, 22) } }, "hub")[1].text).toContain("on 2026-10-22 UTC");
        expect(libraryPrompts({ ...base, latestDay: null }, "hub")[3].text.startsWith("Use the day before as the baseline")).toBe(true);
    });

    it("adds a telemetry coverage prompt for the readiness check", () => {
        expect(coveragePrompt(base, "hub").text).toContain("does Database Hub show performance data for, and how old is each one's newest sample?");
        expect(coveragePrompt(base, "skills").text).toContain("adapt the Learn page's sample queries 1 and 2 to resource group rg-dbhub-test");
        expect(coveragePrompt({ ...base, resourceGroup: undefined }, "skills").text).toContain("to sqlvm01, arcsql01, and azuresql01-test01/ContosoCare");
    });
});

describe("prompt helpers", () => {
    it("phrases windows, ratios, and bins", () => {
        expect(windowPhrase(at(23, 50, 21), at(0, 20, 22))).toBe("between 2026-10-21 23:50 and 2026-10-22 00:20 UTC");
        expect(isoMinute(at(9, 5))).toBe("2026-10-22T09:05Z");
        expect(timesPhrase(3.93)).toBe("about 4 times");
        expect(timesPhrase(1.84)).toBe("about 1.8 times");
        expect(binMinutes([{ at: at(10, 0) }, { at: at(10, 5) }, { at: at(10, 15) }])).toBe(5);
        expect(binMinutes([{ at: at(10, 0) }])).toBeNull();
        expect(describeTarget("T2", NAMES)).toBe("T2 (Arc-enabled SQL Server arcsql01)");
    });

    it("knows Database Hub's 7-day retention", () => {
        const now = at(12, 0, 22);
        expect(olderThanRetention(at(11, 0, 15), now)).toBe(true);
        expect(olderThanRetention(at(13, 0, 15), now)).toBe(false);
        expect(agentPeriod({ from: at(0, 0, 10), to: at(0, 0, 12) }, now)).toBeNull();
        expect(agentPeriod({ from: at(0, 0, 20), to: at(0, 0, 22) }, now)).toEqual({ from: at(0, 0, 20), to: at(0, 0, 22) });
    });

    it("opens Database Hub in the demo's tenant", () => {
        expect(databaseHubUrl("https://app.fabric.microsoft.com/workloads/fdh/databaseHub?ctid=abc", "zzz")).toBe("https://app.fabric.microsoft.com/workloads/fdh/databaseHub?ctid=abc");
        expect(databaseHubUrl(undefined, "00000000-0000-0000-0000-000000000000", "https://app.fabric.microsoft.com/")).toBe(
            "https://app.fabric.microsoft.com/workloads/fdh/databaseHub?ctid=00000000-0000-0000-0000-000000000000",
        );
        expect(databaseHubUrl("javascript:alert(1)", undefined)).toBe("https://app.fabric.microsoft.com/workloads/fdh/databaseHub");
    });

    it("numbers every prompt for Copy all", () => {
        const text = promptsAsText([
            { id: "a", title: "One", purpose: "", text: `First. ${NO_CHANGE}` },
            { id: "b", title: "Two", purpose: "", text: `Second. ${NO_CHANGE}` },
        ]);
        expect(text).toBe(`1. One\nFirst. ${NO_CHANGE}\n\n2. Two\nSecond. ${NO_CHANGE}`);
    });
});
