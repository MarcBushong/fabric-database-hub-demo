// One-click postmortem (ADR 0030): a session's write-up from what the app alone knows (what was injected, when its
// signal showed, the response, the recovery), in two ways. Without Copilot: deterministic Markdown from the data alone,
// with every query behind it, so it works with no GitHub sign-in. With Copilot: the same rows and queries handed to the
// viewer's own Copilot through the app's existing ask contract (useCopilot().ask), with a structured template. With the
// Incident RCA's tables, the Markdown's Cause is the blind investigation of the session's minutes (rca/postmortem.ts),
// and what was injected follows in a section of its own, labeled as the answer key (ADR 0031, section 9).

import type { AskContext, DataProvenance } from "@/copilot/contract";
import type { AgentBeat, SessionRun } from "@/data/model";
import type { ColumnSpec, QuerySpec } from "@/data/queries";
import { MAX_CAUSES, type BlindCauses } from "@/rca/postmortem";
import { buildAskContext, joinDax } from "./ask";
import { serviceOf } from "./business";
import { formatDateTimeUtc, formatDayUtc, formatNumber, formatTimeUtc } from "./format";
import {
    boundText,
    EVENT_LABEL,
    comparePlanEvents,
    minutesText,
    planEvents,
    RECOVERED_BINS,
    scenarioOf,
    scenarioTitle,
    shortSessionId,
    summarize,
    TELEMETRY_LAG_MINUTES,
    type FaultScore,
    type MeasuredEpisode,
    type Plan,
    type PlanEvent,
} from "./scoreboard";

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
    /** The measured ones only, with no answer-key table or measure: what a Copilot draft gets (ADR 0031). */
    askSpecs?: ReadonlyArray<QuerySpec | null | undefined>;
    /**
     * With the RCA tables (ADR 0031, section 9): for a session, the blind investigation of its minutes, which becomes the
     * Cause; for a lone incident request, "request": its minutes are its fault's own, so the Cause points to the Root
     * cause page instead of investigating them. What the demo injected then follows in a section of its own, labeled.
     * Without it, the Cause is what was injected.
     */
    rca?: BlindCauses | "request" | null;
    /** The next session's start, from the session control's record: the Cause's minutes end there at the latest. */
    nextSessionStart?: Date | null;
    /**
     * Every plan in the period, from Scenario Runs, on every target, before the page's filter: after the blind Cause, the
     * answer key also lists the session's faults on targets the filter hides, and other plans' faults that reach into its
     * minutes, labeled as outside this session, since the investigation reads every target (the reviews of feb64ad3 and
     * b4370565). The investigation never reads them.
     */
    plans?: readonly Plan[];
    /** T4's and T5's episodes on targets the page's filter hides, which the dialog loads for the answer key. */
    hidden?: HiddenCaptures | null;
    generatedAt: Date;
}

/** What the answer key reads on the targets the page's filter hides, which the page doesn't load (the review of b4370565). */
export interface HiddenCaptures {
    /** T4's and T5's episodes in the plan's window, from their Azure Monitor captures. */
    episodes: readonly MeasuredEpisode[];
    /** The queries behind them. */
    specs: readonly QuerySpec[];
    /** Each capture that couldn't be read, and why. */
    errors: readonly string[];
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

/**
 * The plan's faults when none is scored. What was injected is the plan's (Scenario Runs) and what showed is the scores',
 * and a plan is scored whole (scorePlan) or not at all: a plan with faults and no scores wasn't measured, because its
 * telemetry didn't load. That's never "nothing was injected".
 */
function unscoredOf(plan: Plan, scores: readonly FaultScore[]): SessionRun[] {
    return scores.length === 0 ? plan.faults : [];
}

const faultTitle = (run: SessionRun) => scenarioTitle(scenarioOf(run));

const NOT_MEASURED = "Not measured: the telemetry didn't load.";

/**
 * Why the impact table is empty, from what was measured (F23), said of every fault only when it's so of every fault: the
 * notebook's own check, when it saw every one; "not visible by its rule", when every one was measured and wasn't;
 * otherwise what the follow-ups give each fault.
 */
function noImpactText(scores: readonly FaultScore[], unscored: boolean): string {
    if (unscored) return NOT_MEASURED;
    if (scores.length === 0) return "No measured impact: nothing was injected or measured in this window.";
    if (scores.every((s) => s.status === "Pass" && !s.bound)) return "No impact in business words: the notebook's own check saw these faults' signals, and their bins aren't in this view.";
    if (scores.every((s) => s.status === "Warning" && s.bound)) return "No measured impact: no fault's signal was visible by its rule in this window; the follow-ups say what each one's signal reached.";
    return "No measured impact in this view; the follow-ups say what was measured for each fault, or why it wasn't.";
}

/** The postmortem's file name: letters, digits, and dashes only. */
export function postmortemFileName(plan: Plan, generatedAt: Date): string {
    const id = (plan.kind === "session" ? shortSessionId(plan.key) : plan.key).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "plan";
    const stamp = generatedAt.toISOString().slice(0, 16).replace(/[-:]/g, "");
    return `contosocare-postmortem-${id}-${stamp}Z.md`;
}

/** The postmortem's title: the dialog shows it while the Cause is still being investigated. */
export function postmortemTitle(plan: Plan): string {
    return `Postmortem: ${planTitle(plan)}`;
}

/**
 * The minutes the Cause investigates (ADR 0031, section 9): a session's, as the session control recorded them, and the
 * TELEMETRY_LAG_MINUTES after them, where the rest of the postmortem still reads a signal (episodesIn), but never into the
 * next session's (the review of 63fb530c). None for a lone incident request: its minutes are its fault's own, from
 * Scenario Runs, so aiming the investigation at them would tell it where the fault was.
 */
export function causeWindow(plan: Pick<Plan, "kind" | "start" | "end">, nextSessionStart: Date | null = null): { from: Date; to: Date } | null {
    if (plan.kind !== "session") return null;
    const end = plan.end.getTime();
    const after = end + TELEMETRY_LAG_MINUTES * 60_000;
    const next = nextSessionStart?.getTime();
    return { from: plan.start, to: new Date(next !== undefined && next < after ? Math.max(next, end) : after) };
}

/** The start of the first session after a plan's start, from the session control's record, or null when there's none. */
export function nextSessionStart(plans: readonly Plan[], plan: Pick<Plan, "key" | "start">): Date | null {
    const later = plans.filter((p) => p.kind === "session" && p.key !== plan.key && p.start.getTime() > plan.start.getTime());
    return later.reduce<Date | null>((first, p) => (first === null || p.start < first ? p.start : first), null);
}

/**
 * Other plans' faults that reach into the investigated minutes, or end up to TELEMETRY_LAG_MINUTES before them, where their
 * signal can still show: a lone incident request just before or after the session, or another session's (the re-review of
 * feb64ad3). The answer key lists them, labeled, so an incident the investigation explains in them isn't read as a false
 * alarm. Only the answer key reads them, after the investigation.
 */
function faultsFromOtherPlans(plans: readonly Plan[], plan: Pick<Plan, "key">, minutes: { from: Date; to: Date }): Array<{ plan: Plan; run: SessionRun }> {
    const from = minutes.from.getTime();
    const to = minutes.to.getTime();
    return plans
        .filter((p) => p.key !== plan.key)
        .flatMap((p) => p.faults.map((run) => ({ plan: p, run })))
        .filter(({ run }) => run.windowStart !== null && run.windowEnd !== null && run.windowStart.getTime() < to && run.windowEnd.getTime() + TELEMETRY_LAG_MINUTES * 60_000 > from)
        .sort((a, b) => (a.run.windowStart?.getTime() ?? 0) - (b.run.windowStart?.getTime() ?? 0) || a.run.target.localeCompare(b.run.target));
}

/**
 * The Cause from the blind investigation (ADR 0031, section 9): each incident in the Root cause view's order, with its
 * root cause, confidence, and the rows it cites, or why it has none; what wasn't captured; and a read that failed as such.
 */
function blindCauseLines(rca: BlindCauses, plan: Plan): string[] {
    const clock = (d: Date) => d.toISOString().slice(11, 19);
    const after = Math.round((rca.to.getTime() - plan.end.getTime()) / 60_000);
    const tail = after <= 0 ? "" : after < TELEMETRY_LAG_MINUTES ? `, and the ${after} minutes after them, up to the next session's start` : `, and the ${after} minutes after them, where a signal can still show`;
    const out = [
        `A blind investigation, the way a DBA would make it, of the session's minutes as the session control recorded them${tail} (${time(rca.from)} to ${time(rca.to)} UTC). It reads what the RCA capture, Database Hub's telemetry, and Azure Monitor recorded, and nothing about the faults the demo planned.`,
        "",
    ];
    if (rca.error) return [...out, `It couldn't run, so it gives no cause: ${rca.error}`];
    if (rca.causes.length === 0) out.push(rca.none ?? "Nothing abnormal in these minutes: the detector found no episode.");
    else {
        out.push("What it found, with the incidents the richest evidence explains first; the Root cause page has each one in full:", "");
        // One root cause behind two incidents (a chain's deadlock and its blocking) is said once, with its evidence.
        const said = new Map<string, string>();
        for (const c of rca.causes) {
            const name = `${c.target}, ${c.signal}, ${c.end ? `${clock(c.start)} to ${clock(c.end)}` : `from ${clock(c.start)}`} UTC`;
            const earlier = c.statement ? said.get(`${c.target}|${c.statement}`) : undefined;
            const sub = [...(earlier ? [] : c.evidence), ...c.notes, ...c.also.map((a) => `Also in these minutes: ${a}`)];
            if (c.failed) out.push(`- **${name}**: it couldn't be explained: ${c.failed}`);
            else if (earlier) out.push(`- **${name}** (confidence ${c.confidence}): the same root cause as **${earlier}** above.`);
            else if (c.statement) out.push(`- **${name}** (confidence ${c.confidence}): ${c.statement}`);
            else out.push(`- **${name}**: no root cause${c.notes.length > 0 ? ":" : " in what was recorded."}`);
            if (c.statement && !earlier) said.set(`${c.target}|${c.statement}`, name);
            for (const line of sub) out.push(`  - ${line}`);
        }
        if (rca.more) out.push("", rca.more);
    }
    if (rca.notCaptured.length > 0) out.push("", "**Not captured:**", "", ...rca.notCaptured.map((n) => `- ${n}`));
    return out;
}

/** The postmortem in Markdown, from the data alone: every figure is measured, and every query is listed. */
export function buildPostmortem(input: PostmortemInput): Postmortem {
    const { plan, scores, episodes, beat } = input;
    const title = postmortemTitle(plan);
    const summary = summarize(scores);
    const lines: string[] = [];
    lines.push(`# ${title}`, "");
    lines.push(
        `**Window:** ${windowText(plan)} · **Source:** ${SOURCE[input.provenance]}${input.asOf ? `, as of ${formatDateTimeUtc(input.asOf)}` : ""} · **Written:** ${formatDateTimeUtc(input.generatedAt)} by Database Hub Insights, from measured data only`,
        "",
    );

    lines.push("## Summary", "");
    const unscored = unscoredOf(plan, scores);
    const injected = scores.length + unscored.length;
    if (injected === 0) lines.push("- No fault was injected in this window: Scenario Runs has no incident request in it.");
    if (scores.length > 0) {
        const targets = [...new Set(scores.map((s) => s.target))].sort().join(", ");
        lines.push(
            `- ${scores.length} fault${scores.length === 1 ? "" : "s"} injected by the demo's session control on ${targets} (Scenario Runs); ${summary.visible} had their signal visible in the telemetry${summary.notVisible ? `, ${summary.notVisible} didn't` : ""}${summary.unmeasured ? `, and ${summary.unmeasured} had no signal the history measures` : ""}.`,
        );
        lines.push(`- Median time to signal: ${minutesText(summary.ttdMedian)}. Median time to recover: ${minutesText(summary.ttrMedian)}.`);
    }
    if (unscored.length > 0) {
        const targets = [...new Set(unscored.map((r) => r.target))].sort().join(", ");
        lines.push(`- ${unscored.length} fault${unscored.length === 1 ? "" : "s"} injected by the demo's session control on ${targets} (Scenario Runs) ${unscored.length === 1 ? "isn't" : "aren't"} measured here: the telemetry didn't load.`);
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
    const timeline: Array<{ event: Pick<PlanEvent, "at" | "kind" | "orderAt">; row: string[] }> = [
        ...planEvents(scores, episodes).map((e) => ({ event: e, row: [time(e.at), e.target, EVENT_LABEL[e.kind], e.label] })),
        // A fault that isn't measured still has its injection, from Scenario Runs.
        ...unscored.map((r) => ({ event: { at: r.windowStart ?? plan.start, kind: "injected" as const }, row: [time(r.windowStart), r.target, EVENT_LABEL.injected, `${faultTitle(r)} on ${r.target} (not measured)`] })),
    ].sort((a, b) => comparePlanEvents(a.event, b.event));
    if (timeline.length === 0) lines.push("No event in this window.");
    else lines.push(...table(["Time", "Target", "Event", "Detail"], timeline.map((t) => t.row)));
    lines.push("");

    const impacts = [
        ...scores.filter((s) => s.impact).map((s) => ({ at: s.visibleAt ?? s.injectedAt, target: s.target, impact: s.impact! })),
        ...episodes.map((e) => ({ at: e.visibleAt, target: e.target, impact: e.impact })),
    ].sort((a, b) => a.at.getTime() - b.at.getTime());
    lines.push("## Impact on ContosoCare", "");
    if (impacts.length === 0) lines.push(noImpactText(scores, unscored.length > 0));
    else lines.push(...table(["Service", "Target", "What it felt", "Measured signal"], impacts.map((i) => [i.impact.service, i.target, i.impact.headline.replace(/^[^:]+:\s*/, ""), i.impact.evidence])));
    lines.push("");

    // The Cause (ADR 0031, section 9): with the RCA tables, what the blind investigation found, the way a DBA would find it,
    // and then what the demo injected, in a section of its own, labeled as the answer key. Without them, what was injected.
    const others = input.rca && input.rca !== "request" ? faultsFromOtherPlans(input.plans ?? [], plan, input.rca) : [];
    // The answer key reads every target, as the investigation does, whatever the page's filter shows (the review of
    // b4370565): the session's faults on the targets it hides, from Scenario Runs before the filter, and T4's and T5's
    // episodes there, which the dialog loads. The sections above stay the filter's.
    const twin = input.rca && input.rca !== "request" ? input.plans?.find((p) => p.key === plan.key) : undefined;
    const hiddenFaults = twin ? twin.faults.filter((f) => !plan.faults.some((g) => g.requestId === f.requestId)) : [];
    const hidden = input.rca && input.rca !== "request" ? (input.hidden ?? null) : null;
    const hiddenEpisodes = hidden?.episodes ?? [];
    const hiddenLines = [
        ...hiddenFaults.map((r) => `- **${faultTitle(r)}** on ${r.target} (${serviceName(r.target)}), ${time(r.windowStart)} to ${time(r.windowEnd)} UTC.`),
        ...hiddenEpisodes.map((e) => {
            const end = e.recoveredAt ?? e.endAt;
            return `- **${e.signal}** on ${e.target} (${serviceName(e.target)}), ${end ? `${time(e.visibleAt)} to ${time(end)} UTC` : `from ${time(e.visibleAt)} UTC`}, an episode in its Azure Monitor metrics.`;
        }),
        ...(hidden?.errors ?? []).map((m) => `- ${m}`),
    ];
    const injectedLines: string[] = [];
    if (injected > 0) {
        injectedLines.push("Every fault was injected on purpose by the demo's session control (NB_DatabaseHub_Control), bounded in time, inside the ContosoCare database only, on sessions tagged `ContosoCare.Demo/`:", "");
        for (const s of scores) injectedLines.push(`- **${s.title}** on ${s.target} (${serviceName(s.target)}), ${time(s.injectedAt)} to ${time(s.injectedEnd)} UTC.`);
        for (const r of unscored) injectedLines.push(`- **${faultTitle(r)}** on ${r.target} (${serviceName(r.target)}), ${time(r.windowStart)} to ${time(r.windowEnd)} UTC.`);
    }
    if (episodes.length + hiddenEpisodes.length > 0) injectedLines.push(`${injected > 0 ? "\n" : ""}T4's and T5's beats aren't in Scenario Runs; their episodes come from their own Azure Monitor metrics, as captured at the session's end.`);
    if (hiddenLines.length > 0) {
        injectedLines.push(
            ...(injectedLines.length > 0 ? [""] : []),
            "**On targets this page's filter hides:** the investigation above reads every target, so the key does too, though the sections above leave these out:",
            "",
            ...hiddenLines,
        );
    }
    if (injected === 0 && episodes.length === 0 && hiddenLines.length === 0) injectedLines.push(others.length > 0 ? "This session's plan injected nothing." : "Nothing was injected in this window.");
    if (others.length > 0) {
        injectedLines.push(
            "",
            `**Outside this session:** other plans injected these faults in the investigated minutes, or up to ${TELEMETRY_LAG_MINUTES} minutes before them, where a signal can still show, so an incident above may be one of theirs:`,
            "",
            ...others.map(({ plan: p, run: r }) => `- **${faultTitle(r)}** on ${r.target} (${serviceName(r.target)}), ${time(r.windowStart)} to ${time(r.windowEnd)} UTC: ${p.kind === "session" ? `session ${shortSessionId(p.key)}'s plan` : "a lone incident request"}.`),
        );
    }
    lines.push("## Cause", "");
    if (input.rca === "request") {
        // A lone request's minutes are its fault's own (Scenario Runs), so a blind investigation isn't aimed at them (the
        // review of 63fb530c): the Root cause page finds and explains the incidents from the signals alone.
        lines.push(
            "This is one incident request's postmortem, and its minutes are its fault's own, from what the demo planned, so a blind investigation aimed at them would be told where the fault was. The Root cause page finds the incidents from the signals alone, in what the RCA capture, Database Hub's telemetry, and Azure Monitor recorded, and explains each one.",
            "",
        );
        lines.push("## What the demo injected (answer key)", "", "What the demo planned, from Scenario Runs: the answer key.", "");
    } else if (input.rca) {
        lines.push(...blindCauseLines(input.rca, plan), "");
        lines.push(
            "## What the demo injected (answer key)",
            "",
            "What the demo planned, from Scenario Runs: the answer key, for checking what the investigation above found. It took only the session's minutes from the session control's record, never the faults in them.",
            "",
        );
    }
    lines.push(...injectedLines);
    lines.push("");

    lines.push("## Response", "");
    const answered = scores.filter((s) => s.answeredAt);
    for (const s of answered) lines.push(`- **${s.title}** on ${s.target}: ${s.answer}, at ${time(s.answeredAt)} UTC.`);
    const unanswered = scores.length - answered.length;
    if (unanswered > 0) lines.push(`- ${answered.length > 0 ? "The other" : "The"} ${unanswered} fault${unanswered === 1 ? "" : "s"} had no response step: each ended at its time limit.`);
    if (unscored.length > 0) lines.push(`- ${NOT_MEASURED}`);
    else if (scores.length === 0) lines.push("- No response step in this window.");
    lines.push("");

    lines.push("## Times to signal and recover", "");
    if (unscored.length > 0) lines.push(NOT_MEASURED, "");
    if (scores.length > 0) {
        lines.push(
            ...table(
                ["Fault", "Target", "Injected", "Signal visible", "Time to signal", "Answered", "Recovered", "Time to recover", "Status"],
                scores.map((s) => [s.title, s.target, time(s.injectedAt), time(s.visibleAt), minutesText(s.ttdMin, s.binMinutes), time(s.answeredAt), s.recoveredAt ? time(s.recoveredAt) : s.recoveryWord || "–", minutesText(s.ttrMin), s.status]),
            ),
            "",
        );
    }
    lines.push(
        `Time to signal runs from the injection to the signal visible in the telemetry, by its sample time; time to recover, from the injection to the signal back under its bound for ${RECOVERED_BINS} bins in a row. Database Hub shows the telemetry 3 to 15 minutes after its sample time; what Database Hub itself detected isn't in the history, so this postmortem doesn't say.`,
        "",
    );

    lines.push("## Follow-ups", "");
    const follow: string[] = [];
    if (unscored.length > 0) follow.push(`**The telemetry didn't load, so ${unscored.length === 1 ? "its fault isn't" : `its ${unscored.length} faults aren't`} measured:** select Retry on the page, then write the postmortem again.`);
    for (const s of scores.filter((x) => x.status === "Warning")) follow.push(`**${s.title} on ${s.target} wasn't visible:** ${s.note} Check ${s.target}'s telemetry on Readiness, and that the request ran (What the control ran, on Manage).`);
    for (const s of scores.filter((x) => x.status === "Pass" && x.ongoing)) follow.push(`**${s.title} on ${s.target} hadn't recovered when the telemetry ends:** check ${s.target} in Database Hub now.`);
    for (const s of scores.filter((x) => x.status === "Pass" && !x.ongoing && !x.recoveredAt)) follow.push(`**${s.title} on ${s.target} has no recovery time:** ${s.recoveryNote || s.note}`);
    for (const s of scores.filter((x) => x.status === "Not supported")) follow.push(`**${s.title} on ${s.target} wasn't measured:** ${s.note}`);
    for (const e of episodes.filter((x) => !x.recoveredAt)) follow.push(`**${serviceName(e.target)} (${e.target}), ${e.signal} from ${time(e.visibleAt)} UTC, has no recovery time:** ${e.note}`);
    if (beat?.respondAt) follow.push(`**Keep automatic plan correction on ${beat.target}:** the run put \`FORCE_LAST_GOOD_PLAN\` back as it found it; Database Hub's Database Agent closes its issue once the condition clears.`);
    if (episodes.some((e) => e.target === "T5")) follow.push("**Patient events (T5):** the story's fix is in the data model, a partition key that spreads the writes, not more throughput.");
    if (episodes.some((e) => e.target === "T4-replica")) follow.push("**Reports' DR copy (T4's read replica):** long reports on the replica hold back its replay; run them elsewhere, or accept the lag.");
    // Said only when it's so: every fault and every episode has a measured recovery (each one that hasn't is listed above).
    const everyRecovered = scores.length + episodes.length > 0 && scores.every((s) => s.recoveredAt) && episodes.every((e) => e.recoveredAt);
    if (follow.length === 0) follow.push(everyRecovered ? "None from the data: every signal showed and recovered." : "None from the data: nothing was injected or measured in this window.");
    lines.push(...follow.map((f) => `- ${f}`), "");

    lines.push("## How this was measured", "");
    lines.push(
        "- **What was injected:** Scenario Runs, which the analysis notebook writes at the session's end from the control's plan.",
        `- **Signal visible in telemetry:** the first bin, from the injection to ${TELEMETRY_LAG_MINUTES} minutes after its window, where the scenario's signal reaches the analysis notebook's level (CPU 80 %, or 1.5 times and 10 points above its baseline; blocked processes or Log Rate Governor waits above 0; Buffer IO waits 1 s; other wait categories 5 s per bin), for 2 bins in a row where the notebook's rule asks for them. Its time is the bin's start: in the bin that holds the injection, that can be before the injection, so the time to signal is 0, written as at most one bin, and the timeline tells the injection first.`,
        `- **Recovered:** the first bin after its last bin at that level, with ${RECOVERED_BINS} bins under it in a row.`,
        "- **T4 and T5:** their captured Azure Monitor metrics: T5's throttling episodes (429s, normalized RU at 100 %) and their recovery, and T4's read replica lag at 60 s or more.",
        ...(input.rca === "request"
            ? ["- **Cause:** none here: a lone incident request's minutes are its fault's own, so the Root cause page finds and explains the incidents instead (ADR 0031)."]
            : input.rca
              ? [`- **Cause:** the Incident RCA's blind investigation of the session's minutes, as the session control recorded them, and the ${TELEMETRY_LAG_MINUTES} minutes after them, up to the next session's start: find_incidents, then explain_incident for each incident, at most ${MAX_CAUSES} in the Root cause page's order. It reads the RCA capture, Database Hub's telemetry, and Azure Monitor, and never the faults in Scenario Runs (ADR 0031).`]
              : []),
        "",
    );
    const bounds = scores.filter((s) => s.bound);
    if (bounds.length > 0) {
        lines.push(...table(["Fault", "Target", "Signal", "Level"], bounds.map((s) => [s.title, s.target, s.signal, `${boundText(s.bound!, s.kind)} (${s.bound!.basis})`])), "");
    }

    lines.push("## Queries", "", "Every query ran read-only through the app's `history` connector, as the viewer:", "");
    const dax = joinDax(input.specs);
    lines.push("```dax", dax ?? "// No query.", "```", "");
    const investigated = input.rca && input.rca !== "request" ? input.rca.queries : [];
    if (investigated.length > 0) lines.push("And the investigation's, behind the Cause, each once:", "", "```dax", investigated.map((q) => `// ${q.title}\n${q.dax}`).join("\n\n"), "```", "");
    const keyQueries = hidden ? joinDax(hidden.specs) : undefined;
    if (keyQueries) lines.push("And the answer key's, for the targets this page's filter hides:", "", "```dax", keyQueries, "```", "");

    return { title, fileName: postmortemFileName(plan, input.generatedAt), markdown: lines.join("\n") };
}

/** The rows the postmortem rests on, one per fault and episode, for Copilot and the CSV. */
export const POSTMORTEM_COLUMNS: ColumnSpec[] = [
    { key: "target", label: "Target", kind: "text" },
    { key: "service", label: "ContosoCare service", kind: "text" },
    { key: "fault", label: "Fault or episode", kind: "text" },
    { key: "injected", label: "Injected (UTC)", kind: "datetime" },
    { key: "visible", label: "Signal visible in telemetry (UTC)", kind: "datetime" },
    { key: "ttdMin", label: "Time to signal (min)", kind: "minutes" },
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

/**
 * The template Copilot follows for a draft. The chat is blind (ADR 0031): it gets the session's time range and what was
 * measured, never what the demo injected or how it was graded, so it investigates the window the way a DBA would. The
 * Markdown the app writes itself keeps the answer key, labeled.
 */
export function postmortemPrompt(plan: Plan): string {
    return [
        `Write the postmortem of what ContosoCare's databases went through ${windowPhrase(plan)}, in Markdown, with exactly these sections: Summary, Timeline (UTC), Impact on ContosoCare, Cause, Response, Follow-ups.`,
        "Investigate it from the measurements, the way a DBA would: the attached DAX reads that window's telemetry, the attached rows are T4's and T5's episodes in their own Azure Monitor metrics, and the investigation tools, when they're offered, read the root-cause capture.",
        "Every figure must come from what you read; write 'not measured' where nothing was, and never estimate user latency or cost.",
        "Say 'signal visible in telemetry', never that Database Hub detected something: the history doesn't record what Database Hub saw.",
        "Name each service with its target (for example Scheduling, T3). End with the queries behind it.",
    ].join(" ");
}

function windowPhrase(plan: Plan): string {
    return `from ${formatDayUtc(plan.start)} ${plan.start.getUTCFullYear()} ${formatTimeUtc(plan.start)} to ${formatTimeUtc(plan.end)} UTC`;
}

/** The measured rows a draft gets: T4's and T5's episodes, found in their own metrics. */
const EPISODE_COLUMNS: ColumnSpec[] = [
    { key: "target", label: "Target", kind: "text" },
    { key: "service", label: "ContosoCare service", kind: "text" },
    { key: "signal", label: "Signal", kind: "text" },
    { key: "visible", label: "Signal visible in telemetry (UTC)", kind: "datetime" },
    { key: "recovered", label: "Recovered or ended (UTC)", kind: "datetime" },
    { key: "peak", label: "Peak", kind: "decimal" },
    { key: "impact", label: "Measured impact", kind: "text" },
];

/**
 * Whether a plan's postmortem offers a Copilot draft: a session's only. A lone incident request's minutes are its fault's
 * own (toPlans), so a draft would aim the chat at what was injected (ADR 0031, decision 7; the re-review of feb64ad3).
 */
export function draftsWithCopilot(plan: Plan): boolean {
    return plan.kind === "session";
}

/** What Copilot gets: the template, the measured rows, and the measured queries, through the app's existing ask contract. */
export function postmortemAsk(input: PostmortemInput): AskContext {
    const rows = input.episodes.map((e) => ({ target: e.target, service: serviceName(e.target), signal: e.signal, visible: e.visibleAt, recovered: e.recoveredAt ?? e.endAt, peak: e.peak, impact: e.impact.sentence }));
    return buildAskContext({
        title: `Postmortem draft: ContosoCare ${windowPhrase(input.plan)}`,
        page: "scoreboard",
        visualId: "postmortem.plan",
        specs: input.askSpecs ?? [],
        rows,
        columns: EPISODE_COLUMNS,
        prompt: postmortemPrompt(input.plan),
        provenance: input.provenance,
        meta: null,
        asOf: input.asOf?.toISOString(),
    });
}
