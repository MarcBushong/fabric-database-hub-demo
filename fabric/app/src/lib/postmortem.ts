// One-click postmortem (ADR 0030): a session's write-up from what the app alone knows (what was injected, when its
// signal showed, the response, the recovery), in two ways. Without Copilot: deterministic Markdown from the data alone,
// with every query behind it, so it works with no GitHub sign-in. With Copilot: the same rows and queries handed to the
// viewer's own Copilot through the app's existing ask contract (useCopilot().ask), with a structured template.

import type { AskContext, DataProvenance } from "@/copilot/contract";
import type { AgentBeat } from "@/data/model";
import type { ColumnSpec, QuerySpec } from "@/data/queries";
import { buildAskContext, joinDax } from "./ask";
import { serviceOf } from "./business";
import { formatDateTimeUtc, formatDayUtc, formatNumber, formatTimeUtc } from "./format";
import { boundText, EVENT_LABEL, minutesText, planEvents, RECOVERED_BINS, shortSessionId, summarize, TELEMETRY_LAG_MINUTES, type FaultScore, type MeasuredEpisode, type Plan } from "./scoreboard";

export interface PostmortemInput {
    plan: Plan;
    scores: readonly FaultScore[];
    /** T4's and T5's signal episodes in the plan's window, from their captured Azure Monitor metrics. */
    episodes: readonly MeasuredEpisode[];
    /** The Database Agent loop's beat in the plan, when it had one. */
    beat: AgentBeat | null;
    /** The history's newest capture. */
    asOf: Date | null;
    provenance: DataProvenance;
    /** The queries behind it, listed at its end. */
    specs: ReadonlyArray<QuerySpec | null | undefined>;
    generatedAt: Date;
}

export interface Postmortem {
    title: string;
    fileName: string;
    markdown: string;
}

/** A Markdown table cell: one line, with its pipes escaped. */
function cell(text: string): string {
    return text.replace(/\s+/g, " ").replace(/\|/g, "\\|").trim() || "–";
}

function table(head: readonly string[], rows: ReadonlyArray<readonly string[]>): string[] {
    return [`| ${head.join(" | ")} |`, `|${head.map(() => "---").join("|")}|`, ...rows.map((r) => `| ${r.map(cell).join(" | ")} |`)];
}

const time = (d: Date | null) => (d ? formatTimeUtc(d) : "–");

function planTitle(plan: Plan): string {
    return plan.kind === "session" ? `ContosoCare session ${shortSessionId(plan.key)}` : `ContosoCare incident request: ${plan.label}`;
}

function windowText(plan: Plan): string {
    return `${formatDayUtc(plan.start)} ${plan.start.getUTCFullYear()} ${formatTimeUtc(plan.start)}–${formatTimeUtc(plan.end)} UTC`;
}

const SOURCE: Record<DataProvenance, string> = {
    history: "the demo's history (SM_DatabaseHub_History)",
    live: "Database Hub's live estate",
    sample: "the local preview's made-up sample data",
};

function serviceName(target: string): string {
    return serviceOf(target)?.service ?? target;
}

/** The postmortem's file name: letters, digits, and dashes only. */
export function postmortemFileName(plan: Plan, generatedAt: Date): string {
    const id = (plan.kind === "session" ? shortSessionId(plan.key) : plan.key).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "plan";
    const stamp = generatedAt.toISOString().slice(0, 16).replace(/[-:]/g, "");
    return `contosocare-postmortem-${id}-${stamp}Z.md`;
}

/** The postmortem in Markdown, from the data alone: every figure is measured, and every query is listed. */
export function buildPostmortem(input: PostmortemInput): Postmortem {
    const { plan, scores, episodes, beat } = input;
    const title = `Postmortem: ${planTitle(plan)}`;
    const summary = summarize(scores);
    const lines: string[] = [];
    lines.push(`# ${title}`, "");
    lines.push(
        `**Window:** ${windowText(plan)} · **Source:** ${SOURCE[input.provenance]}${input.asOf ? `, as of ${formatDateTimeUtc(input.asOf)}` : ""} · **Written:** ${formatDateTimeUtc(input.generatedAt)} by Database Hub Insights, from measured data only`,
        "",
    );

    lines.push("## Summary", "");
    if (scores.length === 0) lines.push("- No fault was injected in this window: Scenario Runs has no incident request in it.");
    else {
        const targets = [...new Set(scores.map((s) => s.target))].sort().join(", ");
        lines.push(
            `- ${scores.length} fault${scores.length === 1 ? "" : "s"} injected by the demo's session control on ${targets} (Scenario Runs); ${summary.visible} had their signal visible in the telemetry${summary.notVisible ? `, ${summary.notVisible} didn't` : ""}${summary.unmeasured ? `, and ${summary.unmeasured} had no signal the history measures` : ""}.`,
        );
        lines.push(`- Median time to detect: ${minutesText(summary.ttdMedian)}. Median time to recover: ${minutesText(summary.ttrMedian)}.`);
    }
    if (beat?.regressAt && beat.respondAt) {
        const cpu = beat.cpuBefore !== null && beat.cpuAfter !== null ? `; ${beat.target}'s CPU fell from ${formatNumber(beat.cpuBefore, "percent")} to ${formatNumber(beat.cpuAfter, "percent")}` : "";
        lines.push(`- The Database Agent loop on ${beat.target}: the plan regressed at ${time(beat.regressAt)} UTC, and the run forced the last good plan at ${time(beat.respondAt)} UTC${cpu}.`);
    }
    for (const target of ["T5", "T4-replica", "T4"] as const) {
        const mine = episodes.filter((e) => e.target === target);
        if (mine.length) lines.push(`- ${serviceName(target)} (${target}): ${mine.length} episode${mine.length === 1 ? "" : "s"} of ${mine[0].signal} in its Azure Monitor metrics.`);
    }
    lines.push("");

    lines.push("## Timeline (UTC)", "");
    const events = planEvents(scores, episodes);
    if (events.length === 0) lines.push("No event in this window.");
    else lines.push(...table(["Time", "Target", "Event", "Detail"], events.map((e) => [time(e.at), e.target, EVENT_LABEL[e.kind], e.label])));
    lines.push("");

    const impacts = [
        ...scores.filter((s) => s.impact).map((s) => ({ at: s.visibleAt ?? s.injectedAt, target: s.target, impact: s.impact! })),
        ...episodes.map((e) => ({ at: e.visibleAt, target: e.target, impact: e.impact })),
    ].sort((a, b) => a.at.getTime() - b.at.getTime());
    lines.push("## Impact on ContosoCare", "");
    if (impacts.length === 0) lines.push("No measured impact: no signal showed in this window.");
    else lines.push(...table(["Service", "Target", "What it felt", "Measured signal"], impacts.map((i) => [i.impact.service, i.target, i.impact.headline.replace(/^[^:]+:\s*/, ""), i.impact.evidence])));
    lines.push("");

    lines.push("## Cause", "");
    if (scores.length > 0) {
        lines.push("Every fault was injected on purpose by the demo's session control (NB_DatabaseHub_Control), bounded in time, inside the ContosoCare database only, on sessions tagged `ContosoCare.Demo/`:", "");
        for (const s of scores) lines.push(`- **${s.title}** on ${s.target} (${serviceName(s.target)}), ${time(s.injectedAt)} to ${time(s.injectedEnd)} UTC.`);
    }
    if (episodes.length > 0) lines.push(`${scores.length > 0 ? "\n" : ""}T4's and T5's beats aren't in Scenario Runs; their episodes come from their own Azure Monitor metrics, as captured at the session's end.`);
    if (scores.length === 0 && episodes.length === 0) lines.push("Nothing was injected in this window.");
    lines.push("");

    lines.push("## Response", "");
    const answered = scores.filter((s) => s.answeredAt);
    for (const s of answered) lines.push(`- **${s.title}** on ${s.target}: ${s.answer}, at ${time(s.answeredAt)} UTC.`);
    const unanswered = scores.length - answered.length;
    if (unanswered > 0) lines.push(`- ${answered.length > 0 ? "The other" : "The"} ${unanswered} fault${unanswered === 1 ? "" : "s"} had no response step: each ended at its time limit.`);
    if (scores.length === 0) lines.push("- No response step in this window.");
    lines.push("");

    lines.push("## Times to detect and recover", "");
    if (scores.length > 0) {
        lines.push(
            ...table(
                ["Fault", "Target", "Injected", "Signal visible", "Time to detect", "Answered", "Recovered", "Time to recover", "Status"],
                scores.map((s) => [s.title, s.target, time(s.injectedAt), time(s.visibleAt), minutesText(s.ttdMin, s.binMinutes), time(s.answeredAt), time(s.recoveredAt), minutesText(s.ttrMin), s.status]),
            ),
            "",
        );
    }
    lines.push(
        `Time to detect runs from the injection to the signal visible in the telemetry, by its sample time; time to recover, from the injection to the signal back under its bound for ${RECOVERED_BINS} bins in a row. Database Hub shows the telemetry 3 to 15 minutes after its sample time; what Database Hub itself detected isn't in the history, so this postmortem doesn't say.`,
        "",
    );

    lines.push("## Follow-ups", "");
    const follow: string[] = [];
    for (const s of scores.filter((x) => x.status === "Warning")) follow.push(`**${s.title} on ${s.target} wasn't visible:** ${s.note} Check ${s.target}'s telemetry on Readiness, and that the request ran (What the control ran, on Manage).`);
    for (const s of scores.filter((x) => x.status === "Pass" && x.ongoing)) follow.push(`**${s.title} on ${s.target} hadn't recovered when the telemetry ends:** check ${s.target} in Database Hub now.`);
    if (beat?.respondAt) follow.push(`**Keep automatic plan correction on ${beat.target}:** the run put \`FORCE_LAST_GOOD_PLAN\` back as it found it; Database Hub's Database Agent closes its issue once the condition clears.`);
    if (episodes.some((e) => e.target === "T5")) follow.push("**Patient events (T5):** the story's fix is in the data model, a partition key that spreads the writes, not more throughput.");
    if (episodes.some((e) => e.target === "T4-replica")) follow.push("**Reports' DR copy (T4's read replica):** long reports on the replica hold back its replay; run them elsewhere, or accept the lag.");
    if (follow.length === 0) follow.push("None from the data: every signal showed and recovered.");
    lines.push(...follow.map((f) => `- ${f}`), "");

    lines.push("## How this was measured", "");
    lines.push(
        "- **What was injected:** Scenario Runs, which the analysis notebook writes at the session's end from the control's plan.",
        `- **Signal visible in telemetry:** the first bin, from the injection to ${TELEMETRY_LAG_MINUTES} minutes after its window, where the scenario's signal reaches the analysis notebook's level (CPU 80 %, or 1.5 times and 10 points above its baseline; blocked processes or Log Rate Governor waits above 0; Buffer IO waits 1 s; other wait categories 5 s per bin), for 2 bins in a row where the notebook's rule asks for them.`,
        `- **Recovered:** the first bin after its last bin at that level, with ${RECOVERED_BINS} bins under it in a row.`,
        "- **T4 and T5:** their captured Azure Monitor metrics: T5's throttling episodes (429s, normalized RU at 100 %) and their recovery, and T4's read replica lag at 60 s or more.",
        "",
    );
    const bounds = scores.filter((s) => s.bound);
    if (bounds.length > 0) {
        lines.push(...table(["Fault", "Target", "Signal", "Level"], bounds.map((s) => [s.title, s.target, s.signal, `${boundText(s.bound!, s.kind)} (${s.bound!.basis})`])), "");
    }

    lines.push("## Queries", "", "Every query ran read-only through the app's `history` connector, as the viewer:", "");
    const dax = joinDax(input.specs);
    lines.push("```dax", dax ?? "// No query.", "```", "");

    return { title, fileName: postmortemFileName(plan, input.generatedAt), markdown: lines.join("\n") };
}

/** The rows the postmortem rests on, one per fault and episode, for Copilot and the CSV. */
export const POSTMORTEM_COLUMNS: ColumnSpec[] = [
    { key: "target", label: "Target", kind: "text" },
    { key: "service", label: "ContosoCare service", kind: "text" },
    { key: "fault", label: "Fault or episode", kind: "text" },
    { key: "injected", label: "Injected (UTC)", kind: "datetime" },
    { key: "visible", label: "Signal visible in telemetry (UTC)", kind: "datetime" },
    { key: "ttdMin", label: "Time to detect (min)", kind: "minutes" },
    { key: "answered", label: "Answered (UTC)", kind: "datetime" },
    { key: "answer", label: "Response", kind: "text" },
    { key: "recovered", label: "Recovered (UTC)", kind: "datetime" },
    { key: "ttrMin", label: "Time to recover (min)", kind: "minutes" },
    { key: "status", label: "Status", kind: "status" },
    { key: "impact", label: "Impact, in business words", kind: "text" },
    { key: "evidence", label: "Measured signal", kind: "text" },
];

export function postmortemRows(scores: readonly FaultScore[], episodes: readonly MeasuredEpisode[]): Array<Record<string, unknown>> {
    return [
        ...scores.map((s) => ({
            target: s.target,
            service: serviceName(s.target),
            fault: s.title,
            injected: s.injectedAt,
            visible: s.visibleAt,
            ttdMin: s.ttdMin === null ? null : Math.round(s.ttdMin * 10) / 10,
            answered: s.answeredAt,
            answer: s.answer,
            recovered: s.recoveredAt,
            ttrMin: s.ttrMin === null ? null : Math.round(s.ttrMin * 10) / 10,
            status: s.status,
            impact: s.impact?.headline ?? "",
            evidence: s.impact?.evidence ?? s.note,
        })),
        ...episodes.map((e) => ({
            target: e.target,
            service: serviceName(e.target),
            fault: `${e.signal} episode (not in Scenario Runs)`,
            injected: null,
            visible: e.visibleAt,
            ttdMin: null,
            answered: null,
            answer: "",
            recovered: e.recoveredAt,
            ttrMin: null,
            status: "Pass",
            impact: e.impact.headline,
            evidence: e.impact.evidence,
        })),
    ];
}

/** The template Copilot follows: the sections, and the rules that keep it to the measured rows. */
export function postmortemPrompt(plan: Plan): string {
    return [
        `Write the postmortem of ${planTitle(plan)} (${windowText(plan)}) in Markdown, with exactly these sections: Summary, Timeline (UTC), Impact on ContosoCare, Cause, Response, Times to detect and recover, Follow-ups.`,
        "Use only the attached rows: each is a fault the demo injected on purpose (or an episode in T4's or T5's metrics), when its signal showed in the telemetry, when it was answered, and when it recovered, measured from the history.",
        "Every figure must come from the rows; write 'not measured' where a row has none, and never estimate user latency or cost.",
        "Say 'signal visible in telemetry', never that Database Hub detected something: the history doesn't record what Database Hub saw.",
        "Name each service with its target (for example Scheduling, T3). End with the queries behind it, from the attached DAX.",
    ].join(" ");
}

/** What Copilot gets: the template, the rows, and the queries, through the app's existing ask contract. */
export function postmortemAsk(input: PostmortemInput): AskContext {
    const rows = postmortemRows(input.scores, input.episodes);
    return buildAskContext({
        title: `Postmortem: ${planTitle(input.plan)}`,
        page: "scoreboard",
        visualId: "postmortem.plan",
        specs: input.specs,
        rows,
        columns: POSTMORTEM_COLUMNS,
        prompt: postmortemPrompt(input.plan),
        provenance: input.provenance,
        meta: null,
        asOf: input.asOf?.toISOString(),
    });
}
