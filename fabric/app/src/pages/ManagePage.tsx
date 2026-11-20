import { useEffect, useMemo, useState, type ReactNode } from "react";
import {
    Button,
    Dialog,
    DialogActions,
    DialogBody,
    DialogContent,
    DialogSurface,
    DialogTitle,
    Dropdown,
    Field,
    MessageBar,
    MessageBarBody,
    MessageBarTitle,
    Option,
    SpinButton,
    Spinner,
    Tooltip,
} from "@fluentui/react-components";
import { ArrowCounterclockwise20Regular, Copy16Regular, Flash20Regular, LockClosed16Regular, Open16Regular, Play20Regular, ShieldCheckmark16Regular, Stop20Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { EmptyState } from "@/components/EmptyState";
import { StatusBadge } from "@/components/StatusBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import { toSessions } from "@/data/model";
import { sessionsQuery } from "@/data/queries";
import { useQuery } from "@/data/use-query";
import { copyText } from "@/lib/clipboard";
import { describeRequest, notebookParameters, runMinutes, validateRequest, type ControlAction, type ControlRequest } from "@/lib/control";
import { parameterCellText, type ManageJobAnswer } from "@/lib/manage-client";
import { clause, formatAgo, formatDateTimeUtc, formatDuration } from "@/lib/format";
import { profileLabel, SCENARIOS, SESSION_MINUTES } from "@/lib/scenarios";
import type { FilterTarget } from "@/lib/view-state";
import { PageHeader } from "@/shell/PageHeader";

interface ActionInfo {
    action: ControlAction;
    title: string;
    icon: ReactNode;
    summary: string;
    button: string;
    tone: "primary" | "secondary";
}

const ACTIONS: ActionInfo[] = [
    { action: "session", title: "Start a session", icon: <Play20Regular />, summary: "What Run all does: start every target, run the showcase's incidents and T3's Database Agent beat, and stop everything at its end.", button: "Start a session…", tone: "primary" },
    { action: "run", title: "Run an incident", icon: <Flash20Regular />, summary: "One bounded scenario from the catalog on one target, with the baseline beside it.", button: "Run an incident…", tone: "secondary" },
    { action: "stop", title: "Stop now", icon: <Stop20Regular />, summary: "End the session now, as its end would: save the history and stop what costs money.", button: "Stop now…", tone: "secondary" },
    { action: "reset", title: "Reset", icon: <ArrowCounterclockwise20Regular />, summary: "Return ContosoCare to its seed state on the running targets, and remove what a cut-off RU storm left on T5.", button: "Reset…", tone: "secondary" },
];

function RequestForm({ request, onChange }: { request: ControlRequest; onChange: (next: ControlRequest) => void }) {
    const { manage } = useApp();
    // The control's own targets when the Manage function says (T5 only while it's on); else the catalog's.
    const allowed = (targets: readonly FilterTarget[]) => targets.filter((t) => manage.mode !== "run" || !manage.targets || manage.targets.includes(t));
    if (request.action === "session") {
        return (
            <Field label="Duration (minutes)" hint={`${SESSION_MINUTES.min} to ${SESSION_MINUTES.max}`}>
                <SpinButton min={SESSION_MINUTES.min} max={SESSION_MINUTES.max} step={10} value={request.durationMinutes ?? SESSION_MINUTES.default} onChange={(_, d) => onChange({ ...request, durationMinutes: Number(d.value ?? d.displayValue) })} />
            </Field>
        );
    }
    if (request.action === "run") {
        const choices = SCENARIOS.filter((s) => allowed(s.targets).length > 0);
        const scenario = choices.find((s) => s.id === request.scenario) ?? choices[0] ?? SCENARIOS[0];
        const targets = allowed(scenario.targets);
        const minutes = runMinutes(scenario);
        return (
            <div className="form-grid">
                <Field label="Scenario">
                    <Dropdown
                        value={scenario.title}
                        selectedOptions={[scenario.id]}
                        onOptionSelect={(_, d) => {
                            const next = choices.find((s) => s.id === d.optionValue) ?? scenario;
                            const nextTargets = allowed(next.targets);
                            onChange({ ...request, scenario: next.id, target: nextTargets.includes(request.target ?? "T1") ? request.target : nextTargets[0], durationMinutes: runMinutes(next).default });
                        }}
                    >
                        {choices.map((s) => (
                            <Option key={s.id} value={s.id} text={s.title}>
                                {s.title}
                            </Option>
                        ))}
                    </Dropdown>
                </Field>
                <Field label="Target">
                    <Dropdown value={request.target ?? ""} selectedOptions={request.target ? [request.target] : []} onOptionSelect={(_, d) => onChange({ ...request, target: d.optionValue as FilterTarget })}>
                        {targets.map((t) => (
                            <Option key={t} value={t} text={t}>
                                <TargetChip target={t} full />
                            </Option>
                        ))}
                    </Dropdown>
                </Field>
                <Field label="Duration (minutes)" hint={`${minutes.min} to ${minutes.max}`}>
                    <SpinButton min={minutes.min} max={minutes.max} value={request.durationMinutes ?? minutes.default} onChange={(_, d) => onChange({ ...request, durationMinutes: Number(d.value ?? d.displayValue) })} />
                </Field>
                <Field label="Intensity" hint="1 to 10; empty is the scenario's default">
                    <SpinButton min={1} max={10} value={request.intensity ?? null} onChange={(_, d) => onChange({ ...request, intensity: d.value === null || d.value === undefined ? undefined : Number(d.value) })} />
                </Field>
            </div>
        );
    }
    return null;
}

function ConfirmDialog({ request, onClose, onStarted }: { request: ControlRequest | null; onClose: () => void; onStarted: (run: { id: string; title: string }) => void }) {
    const { manage, notify, runtime } = useApp();
    const [draft, setDraft] = useState<ControlRequest | null>(request);
    const [prev, setPrev] = useState<ControlRequest | null>(request);
    const [sending, setSending] = useState(false);
    const [notice, setNotice] = useState<{ title: string; text: string } | null>(null);
    if (request !== prev) {
        setPrev(request);
        setDraft(request);
        setNotice(null);
    }
    if (!draft) return null;
    const summary = describeRequest(draft);
    const params = notebookParameters(draft);
    // The control takes one request at a time: while one of its runs is in progress, only Stop now goes (the function refuses
    // the others too). The page reads that run again when an action opens, so Confirm waits for that read.
    const checking = manage.mode === "run" && manage.refreshing === true;
    const running = manage.mode === "run" ? (manage.running ?? null) : null;
    const runningText = running ? `A run of NB_DatabaseHub_Control is ${running.status === "NotStarted" ? "queued" : "in progress"}${running.startedAt ? `, since ${formatDateTimeUtc(new Date(running.startedAt))}` : ""}` : "";
    const busy = running && draft.action !== "stop" ? `${runningText}, and the control takes one request at a time: wait for it to end. Stop now ends whatever it runs, as a session's end would, its history saved.` : null;
    const problem = validateRequest(draft, manage.mode === "run" ? manage.targets : undefined) ?? busy;

    const copyAndOpen = async () => {
        const copied = await copyText(parameterCellText(draft));
        if (runtime.links.controlNotebook) window.open(runtime.links.controlNotebook, "_blank", "noopener,noreferrer");
        notify(copied ? "Copied: paste it into a new cell under the parameters cell of NB_DatabaseHub_Control, then Run all" : "Copy is blocked here: select the request under The control request and press Ctrl+C", copied ? "success" : "info");
        onClose();
    };

    const send = async () => {
        if (!manage.send || problem || checking) return;
        setSending(true);
        try {
            const answer = await manage.send(draft);
            if (answer.started) {
                const cancelled = answer.cancelled?.length ? ", after cancelling the run in progress" : "";
                notify(`${summary.title}: NB_DatabaseHub_Control started as ${answer.requestedBy}${answer.jobInstance ? ` (run ${answer.jobInstance.slice(0, 8)})` : ""}${cancelled}`, "success");
                if (answer.jobInstance) onStarted({ id: answer.jobInstance, title: summary.title });
                void manage.refresh?.();
                onClose();
            } else if (answer.copy && manage.fallBack) {
                // The function couldn't send it, but Run all can: this dialog and the page now copy the request instead.
                setNotice({ title: answer.cancelled?.length ? "Stop now cancelled the control's run, but the stop didn't start." : "The app couldn't send it.", text: answer.reason });
                manage.fallBack(answer.reason);
            } else {
                notify(`${summary.title} wasn't sent: ${answer.reason}`, "error");
                // A run that started meanwhile shows on the page.
                void manage.refresh?.();
                onClose();
            }
        } catch (error) {
            const reason = `The app couldn't reach its Manage function (${clause(error instanceof Error ? error.message : String(error))}), so each action copies its request for NB_DatabaseHub_Control, where Run all sends it.`;
            if (manage.fallBack) {
                setNotice({ title: "The app couldn't send it.", text: reason });
                manage.fallBack(reason);
            } else {
                notify(`${summary.title} wasn't sent: ${reason}`, "error");
                onClose();
            }
        } finally {
            setSending(false);
        }
    };

    return (
        <Dialog open={request !== null} onOpenChange={(_, d) => !d.open && onClose()}>
            <DialogSurface>
                <DialogBody>
                    <DialogTitle>{summary.title}</DialogTitle>
                    <DialogContent>
                        {notice ? (
                            <MessageBar intent="warning">
                                <MessageBarBody>
                                    <MessageBarTitle>{notice.title}</MessageBarTitle>
                                    {notice.text} Copy it below instead.
                                </MessageBarBody>
                            </MessageBar>
                        ) : null}
                        <RequestForm request={draft} onChange={setDraft} />
                        {checking ? <Spinner size="extra-tiny" labelPosition="after" label="Checking NB_DatabaseHub_Control's runs…" /> : null}
                        {running && draft.action === "stop" ? (
                            <MessageBar intent="warning">
                                <MessageBarBody>
                                    <MessageBarTitle>Stop now cancels the control's run first.</MessageBarTitle>
                                    {`${runningText}. On a small capacity, Stop now couldn't start until it ended, so it's cancelled first, and Stop now waits for it to end. If that run was ending a session, Stop now saves the session's history itself; either way, the session ends as its end would.`}
                                </MessageBarBody>
                            </MessageBar>
                        ) : null}
                        <p className="confirm-head">This will:</p>
                        <ol className="confirm-list">
                            {summary.effects.map((e) => (
                                <li key={e}>{e}</li>
                            ))}
                        </ol>
                        <p className="confirm-head">Whatever happens:</p>
                        <ul className="confirm-list">
                            {summary.bounds.map((b) => (
                                <li key={b}>{b}</li>
                            ))}
                        </ul>
                        <details className="confirm-details" open={manage.mode === "copy"}>
                            <summary>The control request</summary>
                            <p className="muted">
                                {manage.mode === "copy" ? "Paste it into a new cell under NB_DatabaseHub_Control's parameters cell, then Run all; the notebook checks it and sends it. No credential is in it." : "NB_DatabaseHub_Control runs with these parameters; no credential is in them or in this app."}
                            </p>
                            <code className="params">{manage.mode === "copy" ? parameterCellText(draft) : Object.entries(params).map(([k, v]) => `${k} = ${JSON.stringify(v.value)}`).join("\n")}</code>
                        </details>
                        {problem ? (
                            <MessageBar intent="error">
                                <MessageBarBody>{problem}</MessageBarBody>
                            </MessageBar>
                        ) : null}
                        {manage.mode === "run" && !manage.canRun ? (
                            <MessageBar intent="info" icon={<LockClosed16Regular />}>
                                <MessageBarBody>{manage.reason}</MessageBarBody>
                            </MessageBar>
                        ) : null}
                    </DialogContent>
                    <DialogActions>
                        <Button appearance="secondary" onClick={onClose}>
                            Cancel
                        </Button>
                        {manage.mode === "copy" ? (
                            <Button appearance="primary" icon={<Copy16Regular />} disabledFocusable={problem !== null} onClick={() => void copyAndOpen()}>
                                {runtime.links.controlNotebook ? "Copy and open the notebook" : "Copy the request"}
                            </Button>
                        ) : (
                            <Tooltip content={manage.canRun ? "Send it to the session control" : manage.reason} relationship="description">
                                <Button appearance="primary" disabledFocusable={!manage.canRun || problem !== null || sending || checking} icon={sending ? <Spinner size="tiny" /> : undefined} onClick={() => void send()}>
                                    {sending ? "Sending…" : "Confirm"}
                                </Button>
                            </Tooltip>
                        )}
                    </DialogActions>
                </DialogBody>
            </DialogSurface>
        </Dialog>
    );
}
/** Polls one of the control's runs until it ends (every 10 seconds, then every 30 after two minutes), for its real state. */
function useControlRun(id: string | null, read: ((jobInstance: string) => Promise<ManageJobAnswer>) | undefined): ManageJobAnswer | null {
    const [state, setState] = useState<{ id: string; answer: ManageJobAnswer } | null>(null);
    useEffect(() => {
        if (!id || !read) return;
        let alive = true;
        let polls = 0;
        let timer: ReturnType<typeof setTimeout> | undefined;
        const next = () => {
            polls += 1;
            if (alive && polls < 240) timer = setTimeout(poll, polls < 12 ? 10_000 : 30_000);
        };
        const poll = () => {
            read(id).then(
                (answer) => {
                    if (!alive) return;
                    setState({ id, answer });
                    if (answer.status === "NotStarted" || answer.status === "InProgress" || answer.status === "Unknown") next();
                },
                () => next(),
            );
        };
        poll();
        return () => {
            alive = false;
            if (timer) clearTimeout(timer);
        };
    }, [id, read]);
    return state && state.id === id ? state.answer : null;
}

/** A run's real state, as the Fabric job API has it, failures included. */
function RunState({ title, id, job }: { title: string; id: string; job: ManageJobAnswer | null }) {
    const run = `run ${id.slice(0, 8)}`;
    const at = (value: string | null | undefined) => (value ? formatDateTimeUtc(new Date(value)) : "");
    const bar = (intent: "info" | "success" | "warning" | "error", text: string, busy = false) => (
        <MessageBar intent={intent} icon={busy ? <Spinner size="extra-tiny" /> : undefined} aria-live="polite">
            <MessageBarBody>{text}</MessageBarBody>
        </MessageBar>
    );
    if (!job) return bar("info", `${title}: reading ${run}…`, true);
    switch (job.status) {
        case "NotStarted":
            return bar("info", `${title}: ${run} is queued. On a small capacity (F2 or F4), it waits for the capacity's Spark session.`, true);
        case "InProgress":
            return bar("info", `${title}: ${run} is in progress${job.startedAt ? `, since ${at(job.startedAt)}` : ""}.`, true);
        case "Completed":
            return bar("success", `${title}: ${run} completed${job.endedAt ? ` at ${at(job.endedAt)}` : ""}.`);
        case "Failed":
            return bar("error", `${title}: ${run} failed${job.endedAt ? ` at ${at(job.endedAt)}` : ""}: ${clause(job.failureReason || "Fabric gave no reason")}. Its output is in the notebook's run history.`);
        case "Cancelled":
            return bar("warning", `${title}: ${run} was cancelled.`);
        case "Deduped":
            return bar("info", `${title}: Fabric merged ${run} with a run already queued.`);
        default:
            return bar("warning", `${title}: ${run}'s state couldn't be read (${clause(job.failureReason || "no answer")}).`);
    }
}

const DEFAULTS: Record<ControlAction, ControlRequest> = {
    session: { action: "session", durationMinutes: SESSION_MINUTES.default },
    run: { action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 10 },
    stop: { action: "stop" },
    reset: { action: "reset", targets: [] },
};

export default function ManagePage() {
    const { filters, manage, runtime } = useApp();
    const [pending, setPending] = useState<ControlRequest | null>(null);
    // The run this page follows: the one it just started, else the control's run in progress.
    const [started, setStarted] = useState<{ id: string; title: string } | null>(null);
    const followed = started ?? (manage.mode === "run" && manage.running ? { id: manage.running.id, title: "The control's run" } : null);
    const job = useControlRun(followed?.id ?? null, manage.mode === "run" ? manage.job : undefined);
    const sessionsSpec = useMemo(() => sessionsQuery(filters), [filters]);
    const sessionsState = useQuery(sessionsSpec);
    const sessions = useMemo(() => toSessions(sessionsState.data?.rows ?? []), [sessionsState.data]);
    const last = sessions[0] ?? null;
    // Each action reads the control's run in progress again first: the state read when the page opened may be old.
    const openAction = (action: ControlAction) => {
        setPending(DEFAULTS[action]);
        void manage.refresh?.();
    };

    return (
        <div className="page">
            <PageHeader
                title="Manage"
                description="Bounded, confirmed actions through the demo's own session control. Each one says what it does before anything runs."
                filter={false}
                actions={
                    runtime.links.controlNotebook ? (
                        <Button as="a" href={runtime.links.controlNotebook} target="_blank" rel="noopener noreferrer" icon={<Open16Regular />} iconPosition="after">
                            Open NB_DatabaseHub_Control
                        </Button>
                    ) : null
                }
            />

            {manage.checking ? (
                <MessageBar intent="info" icon={<Spinner size="extra-tiny" />}>
                    <MessageBarBody>{manage.reason}</MessageBarBody>
                </MessageBar>
            ) : manage.mode === "copy" ? (
                <MessageBar intent="info" icon={<Copy16Regular />}>
                    <MessageBarBody>
                        <MessageBarTitle>Each action copies its request for the control notebook.</MessageBarTitle>
                        {manage.reason}
                    </MessageBarBody>
                </MessageBar>
            ) : (
                <MessageBar intent={manage.canRun ? "success" : "info"} icon={manage.canRun ? <ShieldCheckmark16Regular /> : <LockClosed16Regular />}>
                    <MessageBarBody>
                        <MessageBarTitle>{manage.canRun ? `You can run these actions${manage.who ? `, as ${manage.who}` : ""}.` : "Read-only for you."}</MessageBarTitle>
                        {manage.canRun ? "Every action asks for confirmation first. The control's allow-lists and caps apply to each request, and it records who sent it." : manage.reason}
                    </MessageBarBody>
                </MessageBar>
            )}
            {followed ? <RunState title={followed.title} id={followed.id} job={job} /> : null}

            <section className="actions-grid span-12" aria-label="Actions">
                {ACTIONS.map((a) => (
                    <article key={a.action} className="action-card">
                        <h3>
                            <span aria-hidden="true">{a.icon}</span>
                            {a.title}
                        </h3>
                        <p>{a.summary}</p>
                        <div className="action-foot">
                            <Button appearance={a.tone === "primary" ? "primary" : "secondary"} onClick={() => openAction(a.action)}>
                                {a.button}
                            </Button>
                            {manage.mode === "run" && !manage.canRun && !manage.checking ? (
                                <span className="muted">
                                    <LockClosed16Regular aria-hidden={true} /> Read-only
                                </span>
                            ) : null}
                        </div>
                    </article>
                ))}
            </section>

            <VisualCard
                id="manage.sessions"
                className="span-12"
                title="What the control ran"
                subtitle="Every session plan and activity request the notebooks recorded in the period, newest first."
                specs={[sessionsSpec]}
                loading={sessionsState.loading}
                error={sessionsState.error}
                empty={!sessionsState.loading && sessions.length === 0}
                emptyText={<EmptyState compact title="No session yet">Run all in NB_DatabaseHub_Control starts one; it shows here when it ends.</EmptyState>}
                table={sessionsState.data ? { columns: sessionsSpec.columns, rows: sessionsState.data.rows, caption: "Sessions and activity requests" } : null}
                summary={last ? `The last request was ${formatAgo(last.requestedAt)}.` : "No session yet."}
                askPrompt="Summarize what the session control ran recently and whether anything failed."
                // What the control ran is the demo's plan, the answer key: no Ask (ADR 0031).
                ask={false}
            >
                <ol className="feed">
                    {sessions.slice(0, 12).map((s) => (
                        <li key={s.requestId || `${s.requestedAt?.getTime()}-${s.target}`}>
                            <TargetChip target={s.target || "all"} />
                            <StatusBadge status={s.status} short />
                            <span className="feed-text">
                                <strong>{profileLabel(s.profile)}</strong> <span>{s.message || s.status}</span>
                                {s.durationMin !== null ? <span className="muted">{` · ${formatDuration(s.durationMin)}`}</span> : null}
                            </span>
                            <time>{formatDateTimeUtc(s.requestedAt)}</time>
                        </li>
                    ))}
                </ol>
            </VisualCard>

            <section className="panel span-12" aria-labelledby="safety-title">
                <h3 id="safety-title">How the app's actions stay safe</h3>
                <ul className="confirm-list">
                    <li>Run all in NB_DatabaseHub_Control stays the demo's one action; these come in addition to it and do the same things.</li>
                    <li>No secret reaches the browser: the control's webhook URL stays in Key Vault, read by the control notebook.</li>
                    <li>From the app, only operators send: the app's function verifies who you are from your sign-in, never from what the browser sends, and checks the operators list deploy.ps1 writes (the deployer and the demo's admin group; a redeploy refreshes it).</li>
                    <li>Every request goes through the control's allow-lists and caps, and the runbook checks it again: the targets, the catalog's scenarios, and their maximum durations. The control records who sent it.</li>
                    <li>The workload acts only inside ContosoCare, on sessions tagged ContosoCare.Demo/.</li>
                    <li>Without the app's function, or when it can't confirm who you are or start the run, each action copies its request for the control notebook instead; viewers who aren't operators see this page read-only, with the reason.</li>
                </ul>
            </section>

            <ConfirmDialog request={pending} onClose={() => setPending(null)} onStarted={setStarted} />
        </div>
    );
}
