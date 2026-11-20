// The Copilot dock's investigation tools (ADR 0031). Like run_dax, each runs in the viewer's browser as the viewer: it
// reads the RCA evidence and the telemetry through the history connector (DAX, executeQuery only), finds the window's
// incidents with the blind detector, applies the deterministic rules, and returns facts with their times, a root cause
// with its confidence, the catalog's recommendations, next steps, and what wasn't captured. Blind: nothing here reads
// what anyone planned or ran. The relay forwards at most 16 tools (ask-relay/src/protocol.ts): the dock's 4 and these 6.

import { COSMOS_METRICS, cosmosSeries, POSTGRES_METRICS, postgresSeries, type Bin, type CosmosCapture, type PostgresCapture } from "@/data/model";
import { describeEpisode, findEpisodes } from "./detector";
import { analyzeErrorsResult, AZURE_MONITOR } from "./errors";
import { analyzeLocking } from "./locking";
import { analyzeReplicaLag, LAG_METRIC } from "./replica";
import { bothTimes, resolveTime, windowAround } from "./time";
import { triageWindow } from "./triage";
import { emptyEvidence, hhmmss, iso, plural, RCA_TARGETS, type Confidence, type Episode, type EventRow, type Evidence, type InvestigationResult, type MetricPoint, type RcaTarget } from "./types";

/** The relay's ToolSpec shape (ask-relay/src/protocol.ts). */
export interface ToolSpec {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
}

const TIME = { type: "string", description: "A time as the viewer said it: 'HH:MM' (the viewer's time zone, on the history's newest day), 'HH:MM UTC', or an ISO timestamp." };
const TARGETS = { type: "array", items: { type: "string", enum: RCA_TARGETS }, description: "The targets to look at; all of them when omitted." };
/** With no time, the window is the history's newest minutes: a session's length. */
const NEWEST_MINUTES = 90;
const WINDOW_PROPS = {
    at: { ...TIME, description: `${TIME.description} Without at, or from and to: the history's newest ${NEWEST_MINUTES} minutes.` },
    from: { ...TIME, description: "The window's start, instead of at." },
    to: { ...TIME, description: "The window's end, with from." },
    minutesBefore: { type: "integer", minimum: 0, maximum: 120, description: "With at: minutes before it (default 5)." },
    minutesAfter: { type: "integer", minimum: 0, maximum: 120, description: "With at: minutes after it (default 5)." },
    targets: TARGETS,
};
const COMMON =
    " It reads the demo's saved history (what the capture recorded, and the telemetry from Database Hub and Azure Monitor), never the live estate, as the signed-in viewer. " +
    "It returns JSON: window (UTC and the viewer's local time), episodes (what the detector found, each with its support and source), findings with evidence rows (table, target, time), " +
    "rootCause with its confidence, recommendations (each with its Microsoft Learn page), nextSteps, and notCaptured. Quote its facts and times; don't add causes it doesn't give.";

export const INVESTIGATION_TOOL_SPECS: ToolSpec[] = [
    {
        name: "find_incidents",
        description: "Lists the incidents around a time or in a window, per target: the episodes the detector finds in the capture and the telemetry (blocking, deadlocks, CPU, wait classes, error bursts, read replica lag, T4's connections, T5's throttling), each with its key, how it was seen, and whether the capture covered it. Use it when the viewer asks what happened, or to find an incident's key." + COMMON,
        parameters: { type: "object", properties: WINDOW_PROPS, additionalProperties: false },
    },
    {
        name: "triage_window",
        description: "First-line triage for a time or window: what was abnormal on each target (blocking, deadlocks, CPU, wait classes, errors, T5 throttling, read replica lag), ranked, each with the tool that explains it. Call it first for 'why was it slow at ...' questions; it also says when nothing was abnormal." + COMMON,
        parameters: { type: "object", properties: WINDOW_PROPS, additionalProperties: false },
    },
    {
        name: "explain_incident",
        description: "The full root cause analysis of one incident: its episodeKey from find_incidents or triage_window (or a target with from and to). It runs the investigations that fit its signal, ranks the causes it finds in those minutes by confidence, and returns one combined answer. The RCA view's 'Explain this incident' and the postmortem's Cause use it." + COMMON,
        parameters: {
            type: "object",
            properties: { episodeKey: { type: "string", description: "The episode's key." }, target: { type: "string", enum: RCA_TARGETS, description: "Instead of a key: the target, with from and to." }, from: WINDOW_PROPS.from, to: WINDOW_PROPS.to },
            additionalProperties: false,
        },
    },
    {
        name: "explain_locking",
        description: "Blocking and locks in a window: each blocking chain as a tree with its head blocker first (its module or statement, program, login, host, status, open transaction, how long it was idle, the lock it held and on what), how many sessions it blocked, the chain's depth and width, the longest wait; lock escalations to table locks; and deadlocks (victim, resources, both statements, the pattern). SQL Server, Azure SQL Database (optimized locking), and PostgreSQL." + COMMON,
        parameters: { type: "object", properties: WINDOW_PROPS, additionalProperties: false },
    },
    {
        name: "explain_errors",
        description: "The errors in a window by class, with counts, first and last times, targets, and who hit them: deadlock victims, lock timeouts, timeouts and cancels (attentions), refused connections and failed logins (T4's failed connections from Azure Monitor), resource governance, replica queries cancelled by replay, PostgreSQL SQLSTATE classes, and T5's 429s; each with its usual cause and the tool that explains it." + COMMON,
        parameters: { type: "object", properties: WINDOW_PROPS, additionalProperties: false },
    },
    {
        name: "explain_replica_lag",
        description: "Why T4's read replica lagged around a time: the lag's rise, peak, and recovery (Read Replica Lag, or the replica's own replay samples), and the reason: catch-up after a restart, replay standing still behind a lock a replica query held (hot standby conflict), slow replay, WAL not shipped, or an idle primary; with the replica query, the relation, both lock modes, the WAL rate, and max_standby_streaming_delay." + COMMON,
        parameters: { type: "object", properties: { at: TIME, minutesBefore: WINDOW_PROPS.minutesBefore, minutesAfter: WINDOW_PROPS.minutesAfter }, required: ["at"], additionalProperties: false },
    },
];

export const INVESTIGATION_TOOL_NAMES: readonly string[] = INVESTIGATION_TOOL_SPECS.map((s) => s.name);

/** The telemetry the detector reads beside the capture: Database Hub's bins (T1 to T3) and Azure Monitor's captures (T4, T5). */
export interface Telemetry {
    bins?: readonly Bin[];
    postgres?: PostgresCapture | null;
    cosmos?: CosmosCapture | null;
}

export interface InvestigationDeps {
    /** The RCA evidence of a window (production: loader.ts's DAX through the history connector; tests: the fixtures). */
    load: (from: Date, to: Date, targets: readonly RcaTarget[]) => Promise<Evidence>;
    /** The telemetry of a window, when the app has it. */
    telemetry?: (from: Date, to: Date, targets: readonly RcaTarget[]) => Promise<Telemetry>;
    timeZone: string;
    /** The history's newest day, which bare times are on. */
    latestDay: Date;
    /** The history's newest telemetry time: without a time, a window is the NEWEST_MINUTES before it. */
    latest?: Date;
}

const RESULT_CHARS = 60_000;
const MIN = 60_000;
/** The detector's baselines read the minutes before a window. */
const LEAD_MINUTES = 30;

function windowOf(args: Record<string, unknown>, deps: InvestigationDeps): { from: Date; to: Date; at?: Date } | string {
    const str = (k: string) => (typeof args[k] === "string" ? (args[k] as string) : undefined);
    const num = (k: string, d: number) => (typeof args[k] === "number" && Number.isFinite(args[k]) ? Math.max(0, Math.min(120, args[k] as number)) : d);
    if (str("from") && str("to")) {
        const from = resolveTime(str("from")!, deps.latestDay, deps.timeZone);
        const to = resolveTime(str("to")!, deps.latestDay, deps.timeZone);
        if (!from || !to || to <= from) return "from and to must be times, with from before to.";
        return { from, to };
    }
    const at = str("at") ? resolveTime(str("at")!, deps.latestDay, deps.timeZone) : null;
    if (!at && !str("at") && deps.latest) return { from: new Date(deps.latest.getTime() - NEWEST_MINUTES * MIN), to: deps.latest };
    if (!at) return "Give at (a time), or from and to.";
    return { ...windowAround(at, num("minutesBefore", 5), num("minutesAfter", 5)), at };
}

function targetsOf(args: Record<string, unknown>): RcaTarget[] {
    const list = Array.isArray(args.targets) ? args.targets.filter((t): t is RcaTarget => RCA_TARGETS.includes(t as RcaTarget)) : [];
    return list.length ? list : [...RCA_TARGETS];
}

/** The Azure Monitor series the investigations read, as metric points: the replica's lag, T4's failed connections and CPU, T5's 429s and RU. */
export function monitorMetrics(telemetry: Telemetry): MetricPoint[] {
    const out: MetricPoint[] = [];
    const pg = telemetry.postgres ?? null;
    for (const p of postgresSeries(pg, "T4-replica", POSTGRES_METRICS.lag)) out.push({ target: "T4-replica", at: p.at, metric: LAG_METRIC, value: p.value });
    for (const target of ["T4", "T4-replica"] as const) {
        for (const p of postgresSeries(pg, target, POSTGRES_METRICS.failed)) out.push({ target, at: p.at, metric: POSTGRES_METRICS.failed, value: p.value });
        for (const p of postgresSeries(pg, target, POSTGRES_METRICS.cpu)) out.push({ target, at: p.at, metric: POSTGRES_METRICS.cpu, value: p.value });
    }
    const cosmos = telemetry.cosmos ?? null;
    for (const metric of [COSMOS_METRICS.throttled, COSMOS_METRICS.normalizedRu]) for (const p of cosmosSeries(cosmos, metric)) out.push({ target: "T5", at: p.at, metric, value: p.value });
    return out.sort((a, b) => a.at.getTime() - b.at.getTime());
}

/** Error counts the telemetry and the capture's counters hold, as events: T4's failed connections and deadlocks, T5's 429s. */
function countedErrors(evidence: Evidence, from: Date, to: Date, targets: readonly RcaTarget[]): EventRow[] {
    const inside = (at: Date) => at >= from && at <= to;
    const out: EventRow[] = [];
    for (const m of evidence.metrics) {
        if (!targets.includes(m.target) || !inside(m.at) || m.value === null || m.value <= 0) continue;
        if (m.metric === POSTGRES_METRICS.failed) out.push({ target: m.target, at: m.at, kind: "error", name: AZURE_MONITOR, code: "connections_failed", count: m.value, program: `${m.target}'s clients`, detail: `${plural(m.value, "failed connection")} in the interval (Azure Monitor)` });
        if (m.metric === COSMOS_METRICS.throttled) out.push({ target: m.target, at: m.at, kind: "error", name: AZURE_MONITOR, code: "429", count: m.value, program: "the container's clients", detail: `${plural(m.value, "throttled request")} (429) in the interval (Azure Monitor)` });
    }
    // PostgreSQL logs a deadlock's graph only to its server log; the capture counts them (pg_stat_database.deadlocks).
    for (const r of evidence.resource) {
        if (r.metric === "deadlocks" && r.source.startsWith("RCA-PG") && r.value > 0 && targets.includes(r.target) && inside(r.at)) {
            out.push({ target: r.target, at: r.at, kind: "error", name: "pg_stat_database.deadlocks", code: "40P01", count: r.value, detail: `pg_stat_database.deadlocks rose by ${r.value}` });
        }
    }
    return out;
}

interface Gathered {
    evidence: Evidence;
    episodes: Episode[];
}

const episodeView = (e: Episode) => ({
    key: e.key,
    target: e.target,
    family: e.family,
    signal: e.signal,
    support: e.support,
    source: e.source,
    start: iso(e.start),
    end: e.end ? iso(e.end) : null,
    peak: `${Math.round(e.peak * 10) / 10}${e.unit === "%" ? " %" : ` ${e.unit}`}`,
});

function envelope(tool: string, from: Date, to: Date, targets: readonly RcaTarget[], deps: InvestigationDeps, g: Gathered, at?: Date): InvestigationResult {
    const coverage = g.evidence.coverage.filter((c) => targets.includes(c.target) && c.to >= from && c.from <= to);
    // No coverage row at all: the capture didn't run then (history saved before the environment had it, or T5, which has no observer).
    const unknown = targets
        .filter((t) => !coverage.some((c) => c.target === t))
        .map((t) => `${t}: no RCA capture recorded for ${hhmmss(from)}-${hhmmss(to)} UTC; only the telemetry (Telemetry Snapshots) is known`);
    const notCaptured = [
        ...coverage.flatMap((c) => (c.captured ? c.gaps.map((gap) => `${c.target}: ${gap}`) : [`${c.target}: no RCA evidence for ${hhmmss(c.from)}-${hhmmss(c.to)} UTC${c.gaps.length ? ` (${c.gaps.join("; ")})` : ""}`])),
        ...unknown,
        ...(g.evidence.cut ?? []).map((table) => `${table}: the window holds more rows than one query returns, so its latest rows weren't read; ask about a narrower window`),
    ];
    return {
        tool,
        version: 1,
        window: { fromUtc: iso(from), toUtc: iso(to), local: `${bothTimes(from, deps.timeZone)} to ${bothTimes(to, deps.timeZone)}`, ...(at ? { asked: bothTimes(at, deps.timeZone) } : {}) },
        targets: [...targets],
        episodes: g.episodes.filter((e) => targets.includes(e.target) && e.start <= to && (e.end ?? e.last) >= from).map(episodeView),
        findings: [],
        rootCause: null,
        recommendations: [],
        nextSteps: [],
        notCaptured,
    };
}

function bounded(result: InvestigationResult): string {
    let text = JSON.stringify(result);
    if (text.length <= RESULT_CHARS) return text;
    const trimmed = { ...result, details: { note: "Details cut to fit; ask a narrower question." }, findings: result.findings.slice(0, 8).map((f) => ({ ...f, evidence: f.evidence.slice(0, 3) })) };
    text = JSON.stringify(trimmed);
    return text.length <= RESULT_CHARS ? text : `${text.slice(0, RESULT_CHARS)} [cut]`;
}

const RANK: Record<Confidence, number> = { high: 3, medium: 2, low: 1 };
const KEY = /^(T1|T2|T3|T4|T4-replica|T5)-([a-z_]+)-(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/;

export function createInvestigationTools(deps: InvestigationDeps) {
    /** The window's evidence (from LEAD_MINUTES before it, for the baselines), its telemetry, and its episodes. */
    async function gather(from: Date, to: Date, targets: readonly RcaTarget[]): Promise<Gathered> {
        const lead = new Date(from.getTime() - LEAD_MINUTES * MIN);
        const [loaded, telemetry] = await Promise.all([deps.load(lead, to, targets), deps.telemetry ? deps.telemetry(lead, to, targets) : Promise.resolve<Telemetry>({})]);
        const evidence: Evidence = { ...emptyEvidence(), ...loaded, metrics: [...loaded.metrics, ...monitorMetrics(telemetry)] };
        const episodes = findEpisodes({ evidence, bins: telemetry.bins, postgres: telemetry.postgres, cosmos: telemetry.cosmos }, from, to).filter((e) => targets.includes(e.target));
        return { evidence, episodes };
    }

    async function locking(args: Record<string, unknown>): Promise<InvestigationResult | string> {
        const w = windowOf(args, deps);
        if (typeof w === "string") return w;
        const targets = targetsOf(args);
        const g = await gather(w.from, w.to, targets);
        const inside = (at: Date) => at >= w.from && at <= w.to;
        const sessions = g.evidence.sessions.filter((s) => targets.includes(s.target) && inside(s.capturedAt));
        const events = [...g.evidence.events.filter((e) => targets.includes(e.target) && inside(e.at)), ...countedErrors(g.evidence, w.from, w.to, targets).filter((e) => e.code === "40P01")];
        const a = analyzeLocking(sessions, events, w.at);
        return {
            ...envelope("explain_locking", w.from, w.to, targets, deps, g, w.at),
            findings: a.findings,
            rootCause: a.rootCause,
            recommendations: a.recommendations,
            nextSteps: a.nextSteps,
            details: {
                chain: a.chainLines,
                chains: a.episodes.map((e) => ({ target: e.target, head: e.headSession, kind: e.headKind, blocked: e.peak.blocked, depth: e.peak.depth, width: e.peak.width, formations: e.cycles, first: iso(e.first), last: iso(e.last), activeAtAskedTime: !!w.at && e.first.getTime() - 15000 <= w.at.getTime() && w.at.getTime() <= e.last.getTime() + 15000 })),
                deadlocks: a.deadlocks.map((d) => ({ target: d.findings[0]?.target, count: d.count, byPattern: d.byPattern, victims: d.victims })),
            },
        };
    }

    async function errors(args: Record<string, unknown>): Promise<InvestigationResult | string> {
        const w = windowOf(args, deps);
        if (typeof w === "string") return w;
        const targets = targetsOf(args);
        const g = await gather(w.from, w.to, targets);
        const events = [...g.evidence.events.filter((e) => targets.includes(e.target) && e.at >= w.from && e.at <= w.to), ...countedErrors(g.evidence, w.from, w.to, targets)];
        const base = envelope("explain_errors", w.from, w.to, targets, deps, g, w.at);
        const a = analyzeErrorsResult(events);
        return { ...base, ...a, notCaptured: events.length === 0 ? [...base.notCaptured, "No errors, cancels, failed connections, or 429s were recorded in the window."] : base.notCaptured };
    }

    async function replica(args: Record<string, unknown>): Promise<InvestigationResult | string> {
        const w = windowOf({ minutesBefore: 10, minutesAfter: 5, ...args }, deps);
        if (typeof w === "string" || !w.at) return typeof w === "string" ? w : "Give at.";
        const targets: RcaTarget[] = ["T4", "T4-replica"];
        const g = await gather(w.from, w.to, targets);
        const inside = (at: Date) => at >= w.from && at <= w.to;
        const a = analyzeReplicaLag({ at: w.at, metrics: g.evidence.metrics.filter((m) => inside(m.at)), samples: g.evidence.replica.filter((r) => inside(r.at)), events: g.evidence.events });
        const base = envelope("explain_replica_lag", w.from, w.to, targets, deps, g, w.at);
        return {
            ...base,
            findings: a.findings,
            rootCause: a.rootCause,
            recommendations: a.recommendations,
            nextSteps: a.nextSteps,
            notCaptured: [...base.notCaptured, ...a.notCaptured],
            details: a.rise ? { source: a.rise.source, lag: a.rise.points.map((p) => ({ at: iso(p.at), seconds: Math.round(p.value * 10) / 10 })), slopeSPerS: a.rise.slope, peak: { at: iso(a.rise.peak.at), seconds: Math.round(a.rise.peak.value * 10) / 10 } } : {},
        };
    }

    async function triage(args: Record<string, unknown>, tool = "triage_window"): Promise<InvestigationResult | string> {
        const w = windowOf(args, deps);
        if (typeof w === "string") return w;
        const targets = targetsOf(args);
        const g = await gather(w.from, w.to, targets);
        const t = triageWindow(g, w.from, w.to, targets);
        const base = envelope(tool, w.from, w.to, targets, deps, g, w.at);
        return {
            ...base,
            findings: t.hypotheses.map((h) => ({ ruleId: `TRIAGE-${h.family.toUpperCase()}`, target: h.target, severity: h.score >= 9 ? "critical" : "warning", title: h.summary, detail: `Next: ${h.nextTool}${h.episodeKey ? ` (episodeKey ${h.episodeKey})` : ""}.`, evidence: [] })),
            rootCause: null,
            nextSteps: t.hypotheses.slice(0, 3).map((h) => `${h.nextTool} for ${h.target}${h.episodeKey ? ` (episode ${h.episodeKey})` : ""}`),
            details: { hypotheses: t.hypotheses, quiet: t.quiet, nothingAbnormal: t.hypotheses.length === 0 },
        };
    }

    /** One episode's investigation, by its family. CPU and the wait classes have only the telemetry in Phase 1. */
    async function explainEpisode(e: Episode): Promise<InvestigationResult | string | null> {
        const span = { from: e.start.toISOString(), to: new Date((e.end ?? e.last).getTime() + MIN).toISOString(), targets: [e.target] };
        if (e.family === "blocking" || e.family === "deadlock") return locking(span);
        if (e.family === "replica_lag") return replica({ at: e.peakAt.toISOString() });
        if (e.family === "errors" || e.family === "connections" || e.family === "throttling" || e.family === "ru") return errors(span);
        return null;
    }

    async function incident(args: Record<string, unknown>): Promise<InvestigationResult | string> {
        const key = typeof args.episodeKey === "string" ? args.episodeKey.trim() : "";
        let from: Date;
        let to: Date;
        let targets: RcaTarget[];
        if (key) {
            const m = KEY.exec(key);
            if (!m) return `No episode ${JSON.stringify(key)}: call find_incidents for the keys.`;
            from = new Date(Date.UTC(+m[3], +m[4] - 1, +m[5], +m[6], +m[7], +m[8]));
            to = new Date(from.getTime() + 120 * MIN);
            targets = [m[1] as RcaTarget];
        } else {
            const w = windowOf(args, deps);
            const target = RCA_TARGETS.includes(args.target as RcaTarget) ? (args.target as RcaTarget) : null;
            if (typeof w === "string" || !target) return "Give episodeKey, or target with from and to.";
            ({ from, to } = w);
            targets = [target];
        }
        const g = await gather(from, to, targets);
        const chosen = key ? g.episodes.filter((e) => e.key === key) : g.episodes.filter((e) => e.start <= to && (e.end ?? e.last) >= from);
        if (key && chosen.length === 0) return `No episode ${JSON.stringify(key)}: call find_incidents for the keys.`;
        const span = chosen.length ? { from: new Date(Math.min(...chosen.map((e) => e.start.getTime()))), to: new Date(Math.max(...chosen.map((e) => (e.end ?? e.last).getTime()))) } : { from, to };
        const base = envelope("explain_incident", span.from, span.to, targets, deps, g);
        if (chosen.length === 0) {
            return { ...base, notCaptured: [...base.notCaptured, `Nothing abnormal on ${targets.join(", ")} from ${hhmmss(from)} to ${hhmmss(to)} UTC: the detector found no episode there.`], details: { nothingAbnormal: true } };
        }
        const parts = (await Promise.all(chosen.map(explainEpisode))).filter((p): p is InvestigationResult => !!p && typeof p !== "string");
        // A signal Phase 1 doesn't investigate yet (CPU, the wait classes): the episode is the fact, and its cause isn't captured.
        const telemetryOnly = chosen.filter((e) => !["blocking", "deadlock", "replica_lag", "errors", "connections", "throttling", "ru"].includes(e.family));
        const causes = [
            ...parts.filter((p) => p.rootCause).map((p) => p.rootCause!),
            ...telemetryOnly.map((e) => ({
                statement: `${describeEpisode(e)} What drove it (the plans and waits per query) isn't captured yet.`,
                confidence: "low" as Confidence,
                ruleIds: ["TELEMETRY-ONLY"],
                evidence: [{ table: e.source === "the RCA capture" ? "RCA Resource" : "Telemetry Snapshots", at: iso(e.peakAt), target: e.target, text: `${e.signal} ${Math.round(e.peak * 10) / 10} ${e.unit} (peak)` }],
            })),
        ].sort((a, b) => RANK[b.confidence] - RANK[a.confidence]);
        const [rootCause, ...others] = causes;
        return {
            ...base,
            findings: parts.flatMap((p) => p.findings),
            rootCause: rootCause ?? null,
            recommendations: [...new Map(parts.flatMap((p) => p.recommendations).map((r) => [r.id, r])).values()],
            nextSteps: [...new Set(parts.flatMap((p) => p.nextSteps))],
            notCaptured: [...new Set([...base.notCaptured, ...parts.flatMap((p) => p.notCaptured), ...telemetryOnly.map((e) => `${e.target}: the ${e.signal}'s cause (Query Store's plans, waits per query) isn't captured yet.`)])],
            details: {
                episodes: chosen.map((e) => ({ ...episodeView(e), text: describeEpisode(e) })),
                alsoInTheseMinutes: others.map((c) => c.statement),
                parts: parts.map((p) => ({ tool: p.tool, details: p.details })),
            },
        };
    }

    const handlers: Record<string, (args: Record<string, unknown>) => Promise<InvestigationResult | string>> = {
        find_incidents: (a) => triage(a, "find_incidents"),
        triage_window: (a) => triage(a),
        explain_incident: incident,
        explain_locking: locking,
        explain_errors: errors,
        explain_replica_lag: replica,
    };

    return {
        specs: INVESTIGATION_TOOL_SPECS,
        /** The window's episodes, for the RCA view's list. */
        episodes: async (from: Date, to: Date, targets: readonly RcaTarget[] = RCA_TARGETS) => (await gather(from, to, targets)).episodes,
        /** Structured, for the RCA view and the tests. */
        async investigate(name: string, args: Record<string, unknown>): Promise<InvestigationResult | string> {
            const handler = handlers[name];
            return handler ? handler(args) : `There's no tool named ${name}.`;
        },
        /** As the dock's tool runner returns it: ok and the text Copilot reads. */
        async run(name: string, args: unknown): Promise<{ ok: boolean; text: string }> {
            const input = typeof args === "object" && args !== null && !Array.isArray(args) ? (args as Record<string, unknown>) : {};
            try {
                const result = await this.investigate(name, input);
                return typeof result === "string" ? { ok: false, text: result } : { ok: true, text: bounded(result) };
            } catch (err) {
                return { ok: false, text: `The investigation failed: ${err instanceof Error ? err.message : String(err)}` };
            }
        },
    };
}

export type InvestigationTools = ReturnType<typeof createInvestigationTools>;
