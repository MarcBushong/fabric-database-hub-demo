import { useMemo, useState, type ReactNode } from "react";
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
import { describeRequest, notebookParameters, validateRequest, type ControlAction, type ControlRequest } from "@/lib/control";
import { parameterCellText } from "@/lib/manage-client";
import { formatAgo, formatDateTimeUtc, formatDuration } from "@/lib/format";
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
    if (request.action === "session") {
        return (
            <Field label="Duration (minutes)" hint={`${SESSION_MINUTES.min} to ${SESSION_MINUTES.max}`}>
                <SpinButton min={SESSION_MINUTES.min} max={SESSION_MINUTES.max} step={10} value={request.durationMinutes ?? SESSION_MINUTES.default} onChange={(_, d) => onChange({ ...request, durationMinutes: Number(d.value ?? d.displayValue) })} />
            </Field>
        );
    }
    if (request.action === "run") {
        const scenario = SCENARIOS.find((s) => s.id === request.scenario) ?? SCENARIOS[0];
        return (
            <div className="form-grid">
                <Field label="Scenario">
                    <Dropdown
                        value={scenario.title}
                        selectedOptions={[scenario.id]}
                        onOptionSelect={(_, d) => {
                            const next = SCENARIOS.find((s) => s.id === d.optionValue) ?? scenario;
                            onChange({ ...request, scenario: next.id, target: next.targets.includes(request.target ?? "T1") ? request.target : next.targets[0], durationMinutes: next.defaultMinutes });
                        }}
                    >
                        {SCENARIOS.map((s) => (
                            <Option key={s.id} value={s.id} text={s.title}>
                                {s.title}
                            </Option>
                        ))}
                    </Dropdown>
                </Field>
                <Field label="Target">
                    <Dropdown value={request.target ?? ""} selectedOptions={request.target ? [request.target] : []} onOptionSelect={(_, d) => onChange({ ...request, target: d.optionValue as FilterTarget })}>
                        {scenario.targets.map((t) => (
                            <Option key={t} value={t} text={t}>
                                <TargetChip target={t} full />
                            </Option>
                        ))}
                    </Dropdown>
                </Field>
                <Field label="Duration (minutes)" hint={`5 to ${scenario.maxMinutes}`}>
                    <SpinButton min={5} max={scenario.maxMinutes} value={request.durationMinutes ?? scenario.defaultMinutes} onChange={(_, d) => onChange({ ...request, durationMinutes: Number(d.value ?? d.displayValue) })} />
                </Field>
                <Field label="Intensity" hint="1 to 10; empty is the scenario's default">
                    <SpinButton min={1} max={10} value={request.intensity ?? null} onChange={(_, d) => onChange({ ...request, intensity: d.value === null || d.value === undefined ? undefined : Number(d.value) })} />
                </Field>
            </div>
        );
    }
    return null;
}

function ConfirmDialog({ request, onClose }: { request: ControlRequest | null; onClose: () => void }) {
    const { manage, notify, runtime } = useApp();
    const [draft, setDraft] = useState<ControlRequest | null>(request);
    const [prev, setPrev] = useState<ControlRequest | null>(request);
    const [sending, setSending] = useState(false);
    if (request !== prev) {
        setPrev(request);
        setDraft(request);
    }
    if (!draft) return null;
    const summary = describeRequest(draft);
    const problem = validateRequest(draft);
    const params = notebookParameters(draft);
    const replaces = manage.mode === "run" && manage.running && draft.action === "session" ? manage.running : null;

    const copyAndOpen = async () => {
        const copied = await copyText(parameterCellText(draft));
        if (runtime.links.controlNotebook) window.open(runtime.links.controlNotebook, "_blank", "noopener,noreferrer");
        notify(copied ? "Copied: paste it into a new cell under the parameters cell of NB_DatabaseHub_Control, then Run all" : "Copy is blocked here: select the request under The control request and press Ctrl+C", copied ? "success" : "info");
        onClose();
    };

    const send = async () => {
        if (!manage.send || problem) return;
        setSending(true);
        try {
            const answer = await manage.send(draft);
            if (answer.started) notify(`${summary.title}: NB_DatabaseHub_Control started as ${answer.requestedBy} (run ${answer.jobInstance.slice(0, 8)})`, "success");
            else notify(`${summary.title} wasn't sent: ${answer.reason}`, "error");
            onClose();
        } catch (error) {
            notify(`${summary.title} wasn't sent: ${error instanceof Error ? error.message : String(error)}`, "error");
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
                        <RequestForm request={draft} onChange={setDraft} />
                        {replaces ? (
                            <MessageBar intent="warning">
                                <MessageBarBody>
                                    <MessageBarTitle>It replaces the session that's running.</MessageBarTitle>
                                    {`The control's run started ${formatDateTimeUtc(new Date(replaces.startedAt))} follows the newest request, so this one takes over.`}
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
                                <Button appearance="primary" disabledFocusable={!manage.canRun || problem !== null || sending} icon={sending ? <Spinner size="tiny" /> : undefined} onClick={() => void send()}>
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
const DEFAULTS: Record<ControlAction, ControlRequest> = {
    session: { action: "session", durationMinutes: SESSION_MINUTES.default },
    run: { action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 10 },
    stop: { action: "stop" },
    reset: { action: "reset", targets: [] },
};

export default function ManagePage() {
    const { filters, manage, runtime } = useApp();
    const [pending, setPending] = useState<ControlRequest | null>(null);
    const sessionsSpec = useMemo(() => sessionsQuery(filters), [filters]);
    const sessionsState = useQuery(sessionsSpec);
    const sessions = useMemo(() => toSessions(sessionsState.data?.rows ?? []), [sessionsState.data]);
    const last = sessions[0] ?? null;

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
            {manage.mode === "run" && manage.running ? (
                <MessageBar intent="warning">
                    <MessageBarBody>{`The control is running a request, started ${formatDateTimeUtc(new Date(manage.running.startedAt))}. A new session replaces it: the control follows the newest request.`}</MessageBarBody>
                </MessageBar>
            ) : null}

            <section className="actions-grid span-12" aria-label="Actions">
                {ACTIONS.map((a) => (
                    <article key={a.action} className="action-card">
                        <h3>
                            <span aria-hidden="true">{a.icon}</span>
                            {a.title}
                        </h3>
                        <p>{a.summary}</p>
                        <div className="action-foot">
                            <Button appearance={a.tone === "primary" ? "primary" : "secondary"} onClick={() => setPending(DEFAULTS[a.action])}>
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
                    <li>Without the app's function, each action copies its request for the control notebook instead; viewers who aren't operators see this page read-only, with the reason.</li>
                </ul>
            </section>

            <ConfirmDialog request={pending} onClose={() => setPending(null)} />
        </div>
    );
}
