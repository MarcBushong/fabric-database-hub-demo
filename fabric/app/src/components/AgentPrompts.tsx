import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Bot, Check, Copy, ExternalLink, Eye, ShieldCheck, SquareTerminal, TriangleAlert, X } from "lucide-react";

import { useApp } from "@/app-context";
import { AGENT_SURFACES, databaseHubUrl, promptsAsText, TELEMETRY_RETENTION_DAYS, type AgentPrompt, type AgentSurface } from "@/lib/agent-prompts";
import { copyText } from "@/lib/clipboard";
import { useAgentSurface } from "@/lib/hooks";

export interface AgentPanelProps {
    /** Builds the prompts for the chosen surface from the data on screen. */
    build: (surface: AgentSurface) => AgentPrompt[];
    /** One sentence on what the prompts are about. */
    lead: ReactNode;
    /** A caveat for these prompts, such as a window older than Database Hub's retention. */
    warning?: string | null;
}

/** Ready-made prompts with copy buttons. The app never sends them: Database Hub's agent is UI-only, so the user pastes. */
function AgentPanel({ build, lead, warning }: AgentPanelProps) {
    const { runtime, notify } = useApp();
    const [surface, setSurface] = useAgentSurface();
    const [copied, setCopied] = useState<string | null>(null);
    const prompts = build(surface);
    const hubUrl = databaseHubUrl(runtime.links.databaseHub, runtime.expectedTenantId ?? runtime.tenantId, runtime.portalUrl);
    const where = surface === "hub" ? "the Database Agent" : "Copilot CLI or VS Code chat";

    useEffect(() => {
        if (!copied) return;
        const timer = window.setTimeout(() => setCopied(null), 2200);
        return () => window.clearTimeout(timer);
    }, [copied]);

    const copy = async (id: string, text: string, done: string) => {
        const ok = await copyText(text);
        notify(ok ? done : "Copy is blocked here: select the prompt and press Ctrl+C");
        if (ok) setCopied(id);
    };

    return (
        <div className="agent">
            <ul className="agent-labels" aria-label="About these prompts">
                <li className="pill pill-preview">Preview</li>
                <li className="pill">
                    <ShieldCheck aria-hidden="true" />
                    The agent proposes; you approve each action
                </li>
                <li className="pill">
                    <Eye aria-hidden="true" />
                    Investigation only: this app never runs anything
                </li>
            </ul>

            <div className="agent-bar">
                <p className="agent-lead">{lead}</p>
                <div className="segmented" role="group" aria-label="Where you'll ask">
                    {AGENT_SURFACES.map((s) => (
                        <button key={s.id} type="button" aria-pressed={surface === s.id} title={s.label} onClick={() => setSurface(s.id)}>
                            {s.id === "hub" ? <Bot aria-hidden="true" /> : <SquareTerminal aria-hidden="true" />}
                            {s.short}
                        </button>
                    ))}
                </div>
            </div>

            {warning ? (
                <p className="agent-warning" role="note">
                    <TriangleAlert aria-hidden="true" />
                    {warning}
                </p>
            ) : null}

            <ol className="agent-prompts" aria-label={`Prompts for ${AGENT_SURFACES.find((s) => s.id === surface)?.label ?? "the agent"}`}>
                {prompts.map((p, i) => (
                    <li key={p.id} className="agent-bubble">
                        <div className="agent-bubble-head">
                            <span className="agent-num" aria-hidden="true">
                                {i + 1}
                            </span>
                            <strong>{p.title}</strong>
                            <span className="agent-purpose">{p.purpose}</span>
                        </div>
                        <p className="agent-text">{p.text}</p>
                        <div className="agent-bubble-actions">
                            <button type="button" className="icon-btn" aria-label={`Copy prompt ${i + 1}: ${p.title}`} onClick={() => copy(p.id, p.text, `Prompt copied: paste it into ${where}`)}>
                                {copied === p.id ? <Check aria-hidden="true" /> : <Copy aria-hidden="true" />}
                                {copied === p.id ? "Copied" : "Copy"}
                            </button>
                            {surface === "hub" ? (
                                <a
                                    className="icon-btn"
                                    href={hubUrl}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    aria-label={`Copy prompt ${i + 1} and open Database Hub in a new tab`}
                                    onClick={() => void copy(p.id, p.text, "Prompt copied: paste it into the Database Agent in the new tab")}
                                >
                                    <ExternalLink aria-hidden="true" />
                                    Copy and open Database Hub
                                </a>
                            ) : null}
                        </div>
                    </li>
                ))}
            </ol>

            <div className="agent-go">
                {surface === "hub" ? (
                    <ol className="agent-howto" aria-label="How to ask">
                        <li>Copy a prompt</li>
                        <li>Open Database Hub</li>
                        <li>Paste it into the Database Agent</li>
                    </ol>
                ) : (
                    <ol className="agent-howto" aria-label="How to ask">
                        <li>Install the microsoft-sql-fdh and microsoft-sql plugins</li>
                        <li>Run the session-setup prompt</li>
                        <li>Paste it into Copilot CLI or VS Code chat</li>
                    </ol>
                )}
                <div className="agent-go-actions">
                    <button type="button" className="icon-btn" onClick={() => copy("all", promptsAsText(prompts), `All ${prompts.length} prompts copied: paste one at a time into ${where}`)}>
                        {copied === "all" ? <Check aria-hidden="true" /> : <Copy aria-hidden="true" />}
                        {`Copy all ${prompts.length}`}
                    </button>
                    {surface === "hub" ? (
                        <a className="btn-primary" href={hubUrl} target="_blank" rel="noopener noreferrer">
                            Open Database Hub <ExternalLink aria-hidden="true" width={16} height={16} />
                        </a>
                    ) : null}
                </div>
            </div>

            <p className="agent-fine">
                {surface === "hub"
                    ? `Database Hub's Database Agent is a preview with no API, so this app can't send a prompt: copy one, open Database Hub in a new tab, and paste it into the Database Agent. The agent proposes actions, and each one runs only after you explicitly approve it there; in this demo, read a proposal aloud, then cancel it. The agent sees ${TELEMETRY_RETENTION_DAYS} days of telemetry or less; this app's history goes further back.`
                    : "The documented fallback (fabric/agent/README.md): GitHub Copilot CLI or VS Code with the microsoft-sql-fdh and microsoft-sql plugins from the pinned marketplace commit, and the telemetry agent instructions from Microsoft Learn. Approve only read commands, one at a time; every prompt forbids changes."}
            </p>
        </div>
    );
}

function AgentTitle({ id, title, subtitle }: { id: string; title: string; subtitle?: string }) {
    return (
        <div className="agent-title">
            <span className="agent-orb" aria-hidden="true">
                <Bot />
            </span>
            <div>
                <h3 id={id}>{title}</h3>
                {subtitle ? <p>{subtitle}</p> : null}
            </div>
        </div>
    );
}

/** A card of ready-made prompts for the Database Agent, in the page grid. */
export function AgentCard({ className, title, subtitle, ...panel }: AgentPanelProps & { className?: string; title: string; subtitle?: string }) {
    const headingId = useId();
    return (
        <section className={`card glass agent-card ${className ?? ""}`} aria-labelledby={headingId}>
            <div className="card-head">
                <AgentTitle id={headingId} title={title} subtitle={subtitle} />
            </div>
            <AgentPanel {...panel} />
        </section>
    );
}

/** The same prompts in a dialog over the page: Esc or the close button closes it and focus returns to the opener. */
export function AgentDialog({ open, onClose, title, subtitle, ...panel }: AgentPanelProps & { open: boolean; onClose: () => void; title: string; subtitle?: string }) {
    const headingId = useId();
    const dialogRef = useRef<HTMLElement>(null);
    const closeRef = useRef(onClose);

    useEffect(() => {
        closeRef.current = onClose;
    }, [onClose]);

    useEffect(() => {
        if (!open) return;
        const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
        const onKey = (event: KeyboardEvent) => {
            if (event.key === "Escape") closeRef.current();
        };
        document.addEventListener("keydown", onKey);
        dialogRef.current?.querySelector<HTMLElement>("button")?.focus();
        return () => {
            document.removeEventListener("keydown", onKey);
            opener?.focus();
        };
    }, [open]);

    if (!open) return null;
    return createPortal(
        <div className="focus-overlay" onClick={(e) => e.target === e.currentTarget && onClose()}>
            <section ref={dialogRef} className="card glass agent-card agent-dialog" role="dialog" aria-modal="true" aria-labelledby={headingId}>
                <div className="card-head">
                    <AgentTitle id={headingId} title={title} subtitle={subtitle} />
                    <button type="button" className="icon-btn" onClick={onClose} aria-label="Close" title="Close (Esc)">
                        <X aria-hidden="true" />
                    </button>
                </div>
                <AgentPanel {...panel} />
            </section>
        </div>,
        document.body,
    );
}
