// Ready-made prompts for Database Hub's built-in Database Agent (preview), and the same questions for the documented
// fallback: the microsoft-sql-fdh and microsoft-sql plugins in GitHub Copilot CLI or VS Code (fabric/agent/README.md).
// The agent is UI-only, so the app only builds text from the query results: it never sends a prompt or runs anything.
// Every prompt ends with the prompt pack's safety sentence (fabric/agent/prompts/README.md), so a copied prompt keeps it.

import { FAMILY_LABEL, type Incident, type TargetNames } from "../data/model";
import { SQL_TARGETS, type DateWindow, type TargetKey } from "./dax";
import { formatIsoDay, formatNumber, formatTimeUtc, type NumberKind } from "./format";
import { familySignal, incidentPadMinutes, type IncidentComparison } from "./insights";

export type AgentSurface = "hub" | "skills";

export const AGENT_SURFACES: ReadonlyArray<{ id: AgentSurface; label: string; short: string }> = [
    { id: "hub", label: "The Database Agent in Database Hub", short: "Database Agent" },
    { id: "skills", label: "GitHub Copilot CLI or VS Code with the microsoft-sql-fdh and microsoft-sql plugins", short: "Copilot CLI · VS Code" },
];

export interface AgentPrompt {
    id: string;
    title: string;
    /** One line on what the prompt is for. */
    purpose: string;
    text: string;
}

export interface AgentContext {
    names: TargetNames;
    /** The demo's resource group, from the deploy-time settings. */
    resourceGroup?: string;
}

export const NO_CHANGE = "Don't change anything.";
export const PROPOSE_ONLY = "Don't apply anything; propose only.";

/** Database Hub's telemetry keeps samples for 7 days or less. */
export const TELEMETRY_RETENTION_DAYS = 7;

const DAY_MS = 86400000;

const KIND_PHRASE: Record<TargetKey, string> = {
    T1: "SQL Server on an Azure VM",
    T2: "Arc-enabled SQL Server",
    T3: "Azure SQL Database",
};

/** What else to look at when the incident's own signal moved, by signal family. */
const OTHER_SIGNALS: Record<string, string> = {
    io: "CPU, memory, the other waits, active sessions, and blocking",
    cpu: "waits, memory, storage IO, active sessions, and blocking",
    blocking: "CPU, memory, storage IO, waits, and active sessions",
    log_rate: "CPU, memory, storage IO, the other waits, active sessions, and blocking",
};

/** 2026-10-22T14:05Z */
export function isoMinute(date: Date): string {
    return `${formatIsoDay(date)}T${formatTimeUtc(date)}Z`;
}

/** "between 14:05 and 14:35 UTC on 2026-10-22", with both days when the window crosses midnight. */
export function windowPhrase(start: Date, end: Date): string {
    if (formatIsoDay(start) === formatIsoDay(end)) return `between ${formatTimeUtc(start)} and ${formatTimeUtc(end)} UTC on ${formatIsoDay(start)}`;
    return `between ${formatIsoDay(start)} ${formatTimeUtc(start)} and ${formatIsoDay(end)} ${formatTimeUtc(end)} UTC`;
}

/** "T2 (Arc-enabled SQL Server arcsql01)", with the resource name the telemetry reported. */
export function describeTarget(key: TargetKey, names: TargetNames): string {
    const resource = names[key]?.resource;
    return resource ? `${key} (${KIND_PHRASE[key]} ${resource})` : `${key} (${KIND_PHRASE[key]})`;
}

/** The name Database Hub and the telemetry use, or the target key while it isn't known. */
export function resourceName(key: TargetKey, names: TargetNames): string {
    return names[key]?.resource ?? key;
}

/** The SQL host to connect to: the machine for T1 and T2, the logical server for T3. */
export function sqlHost(key: TargetKey, names: TargetNames): string {
    const name = names[key];
    if (key === "T3") return name?.instance ?? name?.resource?.split("/")[0] ?? key;
    return name?.resource ?? key;
}

function joinList(items: readonly string[]): string {
    if (items.length <= 1) return items.join("");
    if (items.length === 2) return `${items[0]} and ${items[1]}`;
    return `${items.slice(0, -1).join(", ")}, and ${items[items.length - 1]}`;
}

/** "about 4 times", "about 1.8 times" */
export function timesPhrase(ratio: number): string {
    return ratio >= 3 ? `about ${Math.round(ratio)} times` : `about ${ratio.toFixed(1)} times`;
}

/** The telemetry's bin length in minutes: the smallest gap between two bins in a row. */
export function binMinutes(bins: ReadonlyArray<{ at: Date }>): number | null {
    let best: number | null = null;
    for (let i = 1; i < bins.length; i++) {
        const gap = Math.round((bins[i].at.getTime() - bins[i - 1].at.getTime()) / 60000);
        if (gap > 0 && (best === null || gap < best)) best = gap;
    }
    return best;
}

function valuePhrase(value: number, kind: NumberKind, bin: number | null | undefined): string {
    const text = formatNumber(value, kind);
    if (kind !== "seconds" && kind !== "mb") return text;
    return bin ? `${text} per ${bin}-minute bin` : `${text} per bin`;
}

/** The incident's own signal in one clause: the replay's peak and baseline when its bins are loaded, else the recorded peak. */
export function signalClause(incident: Incident, comparison: IncidentComparison | null, bin?: number | null): string {
    const signal = familySignal(incident.family);
    if (comparison && comparison.peak !== null) {
        let clause = `${signal.label} peaked at ${valuePhrase(comparison.peak, signal.kind, bin)}`;
        if (comparison.ratio !== null && comparison.baseline !== null && comparison.ratio >= 1.2) {
            clause += ` and averaged ${timesPhrase(comparison.ratio)} the baseline (${valuePhrase(comparison.baseline, signal.kind, bin)} in the ${incidentPadMinutes(incident)} minutes before)`;
        }
        return clause;
    }
    if (incident.peakValue !== null) return `${signal.label} peaked at ${formatNumber(incident.peakValue, "decimal")}${incident.peakUnit ? ` ${incident.peakUnit}` : ""}`;
    return `the history recorded a ${(FAMILY_LABEL[incident.family] ?? "signal").toLowerCase()} window`;
}

/** True when the window ended before Database Hub's retention: the agent may not see it any more. */
export function olderThanRetention(end: Date, now: Date = new Date()): boolean {
    return now.getTime() - end.getTime() > TELEMETRY_RETENTION_DAYS * DAY_MS;
}

/** The app's period when the agent can still see all of it; null means "the last 7 days". */
export function agentPeriod(period: DateWindow | null, now: Date = new Date()): DateWindow | null {
    if (!period) return null;
    const days = Math.round((period.to.getTime() - period.from.getTime()) / DAY_MS) + 1;
    if (days > TELEMETRY_RETENTION_DAYS || olderThanRetention(new Date(period.from.getTime()), now)) return null;
    return period;
}

function periodPhrase(period: DateWindow | null): string {
    if (!period) return `over the last ${TELEMETRY_RETENTION_DAYS} days`;
    const from = formatIsoDay(period.from);
    const to = formatIsoDay(period.to);
    return from === to ? `on ${from} UTC` : `from ${from} to ${to} UTC`;
}

interface FamilySkills {
    telemetry: (where: string, span: string, database: string) => string;
    skill: string;
    ask: (span: string) => string;
    guard?: string;
}

const FAMILY_SKILLS: Record<string, FamilySkills> = {
    io: {
        telemetry: (where, span, database) =>
            `Using the telemetry agent instructions, write a KQL query on SqlServerStorageIO for ${where} from ${span}. Follow the rule for cumulative counters, and for each ${database} file report the delta of reads, writes, bytes read and written, and read and write stalls. Then adapt sample query 5 to show Buffer IO and Tran Log IO waits for the same window. ${NO_CHANGE}`,
        skill: "diagnose-resource-pressure",
        ask: (span) => `Read sys.dm_io_virtual_file_stats, including the queued stall columns, and tell me whether IO governance or storage was the limit from ${span}.`,
    },
    cpu: {
        telemetry: (where, span) =>
            `Using the telemetry agent instructions, adapt sample query 4 to show CPU on ${where} in 5-minute bins from ${span}, and sample query 5 to list its top waits for the same window, with the signal-wait share. Say when the pressure started and whether it was sustained. ${NO_CHANGE}`,
        skill: "diagnose-resource-pressure",
        ask: (span) => `Tell me whether CPU was the exhausted resource from ${span}, and list the top CPU consumers from Query Store or the plan cache with their execution counts.`,
        guard: "Don't change anything: no MAXDOP or configuration changes, no index changes, no scaling, and no re-running the workload.",
    },
    blocking: {
        telemetry: (where, span) =>
            `Using the telemetry agent instructions, check ${where} for blocking from ${span}. Adapt sample query 8 to that window, then sample query 5 to the target's ResourceID. Report processes blocked, Lock-category waits with their task counts and average wait, and active transactions. ${NO_CHANGE}`,
        skill: "diagnose-blocking-and-deadlocks",
        ask: (span) => `Show who blocked whom from ${span}, and for the head blocker its status, open transaction count, program_name, and last statement. If the block has ended, say so.`,
        guard: "Don't change anything: don't create tables or Extended Events sessions, don't grant permissions, don't KILL a session, and don't reproduce the block.",
    },
    log_rate: {
        telemetry: (where, span) =>
            `Using the telemetry agent instructions, adapt sample query 5 to ${where} from ${span} and report Log Rate Governor and Tran Log IO waits with their task counts and average waits, as deltas of the cumulative counters. Say whether the waits point to log-rate governance by the service tier or to the log disk of the machine. ${NO_CHANGE}`,
        skill: "diagnose-resource-pressure",
        ask: (span) => `From sys.dm_db_resource_stats, report the highest avg_log_write_percent from ${span} and how long it stayed near its limit.`,
        guard: "Don't change anything: no scaling and no configuration changes.",
    },
};

const OTHER_FAMILY: FamilySkills = {
    telemetry: (where, span) => `Using the telemetry agent instructions, adapt sample query 5 to ${where} from ${span} and list its top waits, as deltas of the cumulative counters. ${NO_CHANGE}`,
    skill: "diagnose-slow-query",
    ask: (span) => `From Query Store, find the queries whose cost rose most from ${span}, with the figures behind each.`,
};

export interface IncidentAgentContext extends AgentContext {
    /** The telemetry's bin length, from the replay's bins. */
    binMinutes?: number | null;
}

/** The prompts for one incident window, for the in-Hub Database Agent or for the skills fallback. */
export function incidentPrompts(incident: Incident, comparison: IncidentComparison | null, context: IncidentAgentContext, surface: AgentSurface): AgentPrompt[] {
    const target = describeTarget(incident.target, context.names);
    const pad = incidentPadMinutes(incident);
    const baselineStart = new Date(incident.start.getTime() - pad * 60000);
    const signal = familySignal(incident.family);
    const id = (name: string) => `${incident.key}:${surface}:${name}`;

    if (surface === "hub") {
        const window = windowPhrase(incident.start, incident.end);
        return [
            {
                id: id("cause"),
                title: "What caused it",
                purpose: "The cause, the sessions and queries involved, and what to check or change",
                text: `On ${target} ${window}, ${signalClause(incident, comparison, context.binMinutes)}. What caused it, which sessions and queries were involved, and what should I check or change? Name each signal you used. ${PROPOSE_ONLY}`,
            },
            {
                id: id("together"),
                title: "What moved with it",
                purpose: "Signals that changed at the same time, kept apart from the cause",
                text: `On ${target} ${window}, which of ${OTHER_SIGNALS[incident.family] ?? "CPU, memory, storage IO, waits, active sessions, and blocking"} changed at the same time as the ${signal.label}? Keep what happened at the same time apart from what caused it. ${NO_CHANGE}`,
            },
            {
                id: id("baseline"),
                title: "Against the baseline",
                purpose: `The window against the ${pad} minutes before it`,
                text: `Compare ${target} ${window} with the ${pad} minutes before it (${windowPhrase(baselineStart, incident.start)}): which waits, queries, and sessions differ, and by how much? ${NO_CHANGE}`,
            },
            {
                id: id("evidence"),
                title: "The evidence",
                purpose: "Metric names, the window, the values, and what the agent couldn't see",
                text: `List the evidence behind your conclusion about ${target} ${window}: the metric names, the UTC window, the values, and what you couldn't see. ${NO_CHANGE}`,
            },
        ];
    }

    const name = resourceName(incident.target, context.names);
    const where = context.resourceGroup ? `${name} in resource group ${context.resourceGroup}` : name;
    const span = `${isoMinute(incident.start)} to ${isoMinute(incident.end)}`;
    const database = context.names[incident.target]?.database ?? "ContosoCare";
    const family = FAMILY_SKILLS[incident.family] ?? OTHER_FAMILY;
    return [
        {
            id: id("telemetry"),
            title: "The window in the telemetry",
            purpose: "KQL on the telemetry endpoint, with the Learn telemetry agent instructions",
            text: family.telemetry(where, span, database),
        },
        {
            id: id("baseline"),
            title: "Against the baseline",
            purpose: `CPU, waits, blocking, and memory against the ${pad} minutes before`,
            text: `Using the telemetry agent instructions, compare ${where} from ${span} with the ${pad} minutes before (${isoMinute(baselineStart)} to ${isoMinute(incident.start)}): CPU (sample query 4), the top waits (sample query 5), and blocking and memory pressure (sample query 8), following the rule for cumulative counters. Say what changed and by how much, and keep what happened at the same time apart from what caused it. ${NO_CHANGE}`,
        },
        {
            id: id("sql"),
            title: "Sessions and queries",
            purpose: `The microsoft-sql plugin's ${family.skill} skill, over a SQL connection`,
            text: `Use the ${family.skill} skill on the ${database} database of ${sqlHost(incident.target, context.names)}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. ${family.ask(span)}${incident.target === "T3" ? "" : ` The skill is documented for Azure SQL Database: if it doesn't apply to ${KIND_PHRASE[incident.target]}, say so.`} ${family.guard ?? NO_CHANGE}`,
        },
        {
            id: id("evidence"),
            title: "The evidence",
            purpose: "Metric names, the window, the values, and the KQL and T-SQL it ran",
            text: `List the evidence behind your conclusion about ${name} from ${span}: the metric names, the UTC window, the values, what you couldn't see, and the KQL and T-SQL you ran. ${NO_CHANGE}`,
        },
    ];
}

export interface LibraryContext extends AgentContext {
    targets: readonly TargetKey[];
    /** The app's period; null means all history. */
    period: DateWindow | null;
    /** The newest day with telemetry, for "what changed since the baseline". */
    latestDay: Date | null;
    now?: Date;
}

/** The estate prompt library: estate health, the top waits per target, blocking chains, and what changed. */
export function libraryPrompts(context: LibraryContext, surface: AgentSurface): AgentPrompt[] {
    const keys = SQL_TARGETS.filter((t) => context.targets.includes(t));
    const described = joinList(keys.map((k) => describeTarget(k, context.names)));
    const names = joinList(keys.map((k) => resourceName(k, context.names)));
    const scope = context.resourceGroup ? `in resource group ${context.resourceGroup}` : "of the demo";
    const inGroup = context.resourceGroup ? ` in resource group ${context.resourceGroup}` : "";
    const period = periodPhrase(agentPeriod(context.period, context.now));
    const newest = context.latestDay ? formatIsoDay(context.latestDay) : null;
    const previous = context.latestDay ? formatIsoDay(new Date(context.latestDay.getTime() - DAY_MS)) : null;
    const id = (name: string) => `library:${surface}:${name}`;

    if (surface === "hub") {
        return [
            {
                id: id("health"),
                title: "Estate health",
                purpose: "Each target's kind, its performance data, and its open issues",
                text: `Summarize the health of the SQL resources ${scope}: ${described}. For each one, say what kind of resource it is, whether Database Hub has performance data for it, and which issues or suggestions are open. Use the last hour. ${NO_CHANGE}`,
            },
            {
                id: id("waits"),
                title: "Top waits per target",
                purpose: "Where each target spends its wait time",
                text: `For each of ${described}, list the top five wait categories ${period}, with the wait time and the share of the total, and say which target waits the most. ${NO_CHANGE}`,
            },
            {
                id: id("blocking"),
                title: "Blocking chains",
                purpose: "What was blocked, when, and the head of the chain",
                text: `Was anything blocked on ${described} ${period}? For each target, say which database, when it started and ended, how many sessions waited, and what you know about the session at the head of the chain. Name each signal you used. ${NO_CHANGE}`,
            },
            {
                id: id("changed"),
                title: "What changed since the baseline",
                purpose: newest && previous ? `${newest} against ${previous} as the baseline` : "The last day against the day before it",
                text:
                    newest && previous
                        ? `Use ${previous} UTC as the baseline for ${described}. On ${newest} UTC, which of CPU, waits, storage IO, active sessions, and blocking changed against that baseline, by how much, and on which target? Keep what happened at the same time apart from what caused it. ${NO_CHANGE}`
                        : `Use the day before as the baseline for ${described}. Over the last day, which of CPU, waits, storage IO, active sessions, and blocking changed against that baseline, by how much, and on which target? ${NO_CHANGE}`,
            },
        ];
    }

    return [
        {
            id: id("health"),
            title: "Estate health",
            purpose: "The microsoft-sql-fdh plugin's Database Hub skill",
            text: `Use the Database Hub skill to show the SQL resources ${scope}, grouped by engine and subscription, with CPU, storage, and memory health over the last hour: ${names}. Report coverage, partial results, and anything you couldn't read. ${NO_CHANGE}`,
        },
        {
            id: id("waits"),
            title: "Top waits per target",
            purpose: "Sample query 5 on the telemetry endpoint",
            text: `Using the telemetry agent instructions, adapt sample query 5 to each of ${names}${inGroup} ${period}, and list the top five wait categories per target with their wait time and share of the total, as deltas of the cumulative counters. ${NO_CHANGE}`,
        },
        {
            id: id("blocking"),
            title: "Blocking chains",
            purpose: "Sample queries 8 and 5 on the telemetry endpoint",
            text: `Using the telemetry agent instructions, adapt sample query 8 to ${names}${inGroup} ${period}, and report the processes blocked per target with the Lock-category waits from sample query 5, and when each blocking episode started and ended. ${NO_CHANGE}`,
        },
        {
            id: id("changed"),
            title: "What changed since the baseline",
            purpose: newest && previous ? `${newest} against ${previous} as the baseline` : "The last day against the day before it",
            text:
                newest && previous
                    ? `Using the telemetry agent instructions, compare ${newest} with ${previous} (UTC, the baseline) for ${names}: CPU (sample query 4), the top waits (sample query 5), and blocking and memory pressure (sample query 8), following the rule for cumulative counters. Say what changed, by how much, and on which target. ${NO_CHANGE}`
                    : `Using the telemetry agent instructions, compare the last day with the day before (the baseline) for ${names}: CPU (sample query 4), the top waits (sample query 5), and blocking and memory pressure (sample query 8), following the rule for cumulative counters. ${NO_CHANGE}`,
        },
    ];
}

/** The readiness question for the agent: which targets report performance data, and how fresh it is. */
export function coveragePrompt(context: LibraryContext, surface: AgentSurface): AgentPrompt {
    const keys = SQL_TARGETS.filter((t) => context.targets.includes(t));
    if (surface === "hub") {
        return {
            id: "coverage:hub",
            title: "Telemetry coverage",
            purpose: "Which targets report performance data, and how fresh it is",
            text: `Which of ${joinList(keys.map((k) => describeTarget(k, context.names)))} does Database Hub show performance data for, and how old is each one's newest sample? For any without data, say which prerequisite is missing: permissions, performance monitoring, the region, or the preview. ${NO_CHANGE}`,
        };
    }
    const scope = context.resourceGroup ? `resource group ${context.resourceGroup}` : joinList(keys.map((k) => resourceName(k, context.names)));
    return {
        id: "coverage:skills",
        title: "Telemetry coverage",
        purpose: "Sample queries 1 and 2 on the telemetry endpoint",
        text: `Using the telemetry agent instructions, adapt the Learn page's sample queries 1 and 2 to ${scope}. List each resource that reports, with its ResourceType, ResourceName, SqlServerInstanceName, last sample time, and the oldest sample available. ${NO_CHANGE}`,
    };
}

/** Every prompt, numbered, for "Copy all". */
export function promptsAsText(prompts: readonly AgentPrompt[]): string {
    return prompts.map((p, i) => `${i + 1}. ${p.title}\n${p.text}`).join("\n\n");
}

/** The Database Hub page in the demo's tenant: the deploy-time link, or one built from the portal and the tenant. */
export function databaseHubUrl(configured: string | undefined, tenantId: string | undefined, portalUrl = "https://app.fabric.microsoft.com"): string {
    if (configured && /^https:\/\//i.test(configured)) return configured;
    const base = `${portalUrl.replace(/\/+$/, "")}/workloads/fdh/databaseHub`;
    return tenantId ? `${base}?ctid=${encodeURIComponent(tenantId)}` : base;
}
