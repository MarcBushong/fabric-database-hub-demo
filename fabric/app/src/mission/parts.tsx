// Small parts the Wave 1 pages share: the broadcast-style numbers, the lens switch, the session picker, the postmortem's
// button and a preview of its own Markdown, and what a page says when part of its history didn't load or its session
// isn't in the period.

import { Fragment, type ReactNode } from "react";
import { Button, MessageBar, MessageBarActions, MessageBarBody, Select, ToggleButton, Tooltip } from "@fluentui/react-components";
import { DocumentText16Regular } from "@fluentui/react-icons";

import { EmptyState } from "@/components/EmptyState";
import type { Plan } from "@/lib/scoreboard";
import type { Lens } from "./ServiceMap";
import { planOption } from "./timeline";

/** Why the postmortem waits while the telemetry hasn't loaded. */
export const POSTMORTEM_WAITS = "The telemetry didn't load, so no fault is measured yet: select Retry, then write the postmortem.";

/**
 * "Write the postmortem", once the session's faults are scored: not while they load, and not while the telemetry they're
 * scored from has failed, when the page names the failure with Retry (a postmortem then would have no measured fault).
 */
export function PostmortemButton({ ready, scoreError, onClick }: { ready: boolean; scoreError: Error | null; onClick: () => void }) {
    const waits = ready && scoreError !== null;
    const button = (
        <Button size="small" icon={<DocumentText16Regular />} disabled={!ready} disabledFocusable={waits} onClick={onClick}>
            Write the postmortem
        </Button>
    );
    return waits ? (
        <Tooltip content={POSTMORTEM_WAITS} relationship="description">
            {button}
        </Tooltip>
    ) : (
        button
    );
}

/** A big number with its label and what it rests on. */
export function BigStat({ label, value, sub, tone }: { label: string; value: string; sub?: ReactNode; tone?: "alert" | "good" | "quiet" }) {
    return (
        <div className={`mc-stat${tone ? ` mc-stat-${tone}` : ""}`}>
            <span className="mc-stat-label">{label}</span>
            <span className="mc-stat-value">{value}</span>
            {sub ? <span className="mc-stat-sub">{sub}</span> : null}
        </div>
    );
}

/** Technical or business words on the map and in the tables. */
export function LensSwitch({ lens, onChange }: { lens: Lens; onChange: (lens: Lens) => void }) {
    return (
        <div className="mc-lens" role="group" aria-label="Lens">
            <ToggleButton size="small" appearance="subtle" checked={lens === "technical"} onClick={() => onChange("technical")}>
                Technical
            </ToggleButton>
            <ToggleButton size="small" appearance="subtle" checked={lens === "business"} onClick={() => onChange("business")}>
                Business impact
            </ToggleButton>
        </div>
    );
}

/** Which session the page is about: the newest by default. */
export function PlanPicker({ plans, value, onChange, id }: { plans: readonly Plan[]; value: string | null; onChange: (key: string) => void; id: string }) {
    if (plans.length === 0) return null;
    return (
        <span className="mc-picker">
            <label htmlFor={id}>Session</label>
            <Select id={id} size="small" value={value ?? plans[0].key} onChange={(_, data) => onChange(data.value)}>
                {plans.map((p, i) => (
                    <option key={p.key} value={p.key}>
                        {`${planOption(p)}${i === 0 ? " (latest)" : ""}`}
                    </option>
                ))}
            </Select>
        </span>
    );
}

function inline(text: string): ReactNode[] {
    return text.split(/(\*\*[^*]+\*\*|`[^`]+`)/).map((part, i) =>
        part.startsWith("**") && part.endsWith("**") ? (
            <strong key={i}>{part.slice(2, -2)}</strong>
        ) : part.startsWith("`") && part.endsWith("`") && part.length > 1 ? (
            <code key={i}>{part.slice(1, -1)}</code>
        ) : (
            <Fragment key={i}>{part}</Fragment>
        ),
    );
}

const cells = (row: string) =>
    row
        .replace(/^\|\s?|\s?\|$/g, "")
        .split(/\s\|\s/)
        .map((c) => c.replace(/\\\|/g, "|"));

/** The postmortem's Markdown as the dialog shows it: its headings, lists, tables, and code, nothing else. */
export function MarkdownView({ markdown }: { markdown: string }) {
    const lines = markdown.split("\n");
    const out: ReactNode[] = [];
    let i = 0;
    while (i < lines.length) {
        const text = lines[i];
        if (text.startsWith("```")) {
            const code: string[] = [];
            i++;
            while (i < lines.length && !lines[i].startsWith("```")) code.push(lines[i++]);
            out.push(
                <pre key={out.length} className="pm-code">
                    {code.join("\n")}
                </pre>,
            );
            i++;
        } else if (text.startsWith("| ")) {
            const rows: string[] = [];
            while (i < lines.length && lines[i].startsWith("|")) rows.push(lines[i++]);
            const [head, , ...body] = rows;
            out.push(
                <div key={out.length} className="pm-table">
                    <table>
                        <thead>
                            <tr>
                                {cells(head).map((c, j) => (
                                    <th key={j}>{c}</th>
                                ))}
                            </tr>
                        </thead>
                        <tbody>
                            {body.map((r, k) => (
                                <tr key={k}>
                                    {cells(r).map((c, j) => (
                                        <td key={j}>{inline(c)}</td>
                                    ))}
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>,
            );
        } else if (text.startsWith("- ")) {
            // A list, with one nested level: "  - " lines belong to the item above them (the postmortem's evidence).
            const items: Array<{ text: string; sub: string[] }> = [];
            while (i < lines.length && (lines[i].startsWith("- ") || (items.length > 0 && lines[i].startsWith("  - ")))) {
                const line = lines[i++];
                if (line.startsWith("- ")) items.push({ text: line.slice(2), sub: [] });
                else items[items.length - 1].sub.push(line.slice(4));
            }
            out.push(
                <ul key={out.length}>
                    {items.map((t, k) => (
                        <li key={k}>
                            {inline(t.text)}
                            {t.sub.length > 0 ? (
                                <ul>
                                    {t.sub.map((s, j) => (
                                        <li key={j}>{inline(s)}</li>
                                    ))}
                                </ul>
                            ) : null}
                        </li>
                    ))}
                </ul>,
            );
        } else if (text.startsWith("## ")) {
            out.push(<h4 key={out.length}>{text.slice(3)}</h4>);
            i++;
        } else if (text.startsWith("# ")) {
            out.push(<h3 key={out.length}>{text.slice(2)}</h3>);
            i++;
        } else {
            if (text.trim()) out.push(<p key={out.length}>{inline(text)}</p>);
            i++;
        }
    }
    return <div className="pm-view">{out}</div>;
}

/** Part of the page's history didn't load: which queries, and why, beside what the page still shows. */
export function LoadNotice({ error, onRetry }: { error: Error | null; onRetry: () => void }) {
    if (!error) return null;
    return (
        <MessageBar intent="warning" className="mc-notice" layout="multiline">
            <MessageBarBody>{error.message}</MessageBarBody>
            <MessageBarActions>
                <Button size="small" onClick={onRetry}>
                    Retry
                </Button>
            </MessageBarActions>
        </MessageBar>
    );
}

/** The address asks for a session the period's history doesn't have: say so, rather than show another session in its place. */
export function MissingSession({ session, onAllHistory, onLatest }: { session: string; onAllHistory: () => void; onLatest: () => void }) {
    const id = session.startsWith("session:") ? session.slice("session:".length, "session:".length + 8) : session.slice(0, 24);
    return (
        <EmptyState
            title={`Session ${id} isn't in this period`}
            actions={
                <>
                    <Button size="small" appearance="primary" onClick={onAllHistory}>
                        Show all history
                    </Button>
                    <Button size="small" onClick={onLatest}>
                        Show the latest session
                    </Button>
                </>
            }
        >
            <p>The link asks for a session that the history doesn't have in the period picked: pick All history, or show the latest session.</p>
        </EmptyState>
    );
}
