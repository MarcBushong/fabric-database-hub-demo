// Small parts the Wave 1 pages share: the broadcast-style numbers, the lens switch, the session picker, and a preview of
// the postmortem's own Markdown.

import { Fragment, type ReactNode } from "react";
import { Select, ToggleButton } from "@fluentui/react-components";

import type { Plan } from "@/lib/scoreboard";
import type { Lens } from "./ServiceMap";
import { planOption } from "./timeline";

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
            const items: string[] = [];
            while (i < lines.length && lines[i].startsWith("- ")) items.push(lines[i++].slice(2));
            out.push(
                <ul key={out.length}>
                    {items.map((t, k) => (
                        <li key={k}>{inline(t)}</li>
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
