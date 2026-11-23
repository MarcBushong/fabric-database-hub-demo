// The Root cause page's list, organized (ADR 0031, section 7; the owner's feedback of 2026-11-23): facets for severity,
// category, and server and database, each value with its count; the minutes it reads; and the incidents grouped by category
// or by target, sorted by severity or by time. Colors are theme tokens only (rca.css).

import { memo, useId, useState, type ReactNode } from "react";
import { Button, Input, Select, ToggleButton } from "@fluentui/react-components";

import { RCA_CATEGORIES, RCA_FACET_TARGETS, RCA_NEWEST_MINUTES, RCA_SEVERITIES, type RcaFilters, type RcaGroup, type RcaNewest, type RcaSeverity, type RcaSort } from "../facet-ids";
import { categoryLabel, facetCounts, type IncidentGroup } from "../facets";
import { bothTimes, offsetMs, resolveTime } from "../time";
import { MAX_WINDOW_HOURS, targetLabel, type ListedIncident, type ServerNames } from "./facts";

const NEWEST_LABEL: Record<RcaNewest, string> = { 90: "The newest 90 minutes", 360: "The newest 6 hours", 1440: "The newest 24 hours" };

const BARS: Record<RcaSeverity, number> = { high: 3, medium: 2, low: 1 };

/** High, Medium, or Low, with bars as well as a word, so it never rests on color alone. */
export function SeverityMark({ severity, reason }: { severity: RcaSeverity; reason?: string }) {
    const label = RCA_SEVERITIES.find((s) => s.id === severity)?.label ?? severity;
    return (
        <span className={`rca-sev rca-sev-${severity}`} title={reason}>
            <svg viewBox="0 0 14 12" aria-hidden="true" focusable="false">
                {[0, 1, 2].map((i) => (
                    <rect key={i} className={i < BARS[severity] ? "on" : "off"} x={1 + i * 4.5} y={8 - i * 3} width="3" height={3 + i * 3} rx="0.5" />
                ))}
            </svg>
            {label}
        </span>
    );
}

/** A local wall-clock time for an input of type datetime-local, in the viewer's time zone. */
const localInput = (at: Date, timeZone: string) => new Date(at.getTime() + offsetMs(at, timeZone)).toISOString().slice(0, 16);

function Facet({ name, children }: { name: string; children: ReactNode }) {
    return (
        <div className="rca-facet" role="group" aria-label={name}>
            <span className="rca-facet-name" aria-hidden="true">
                {name}
            </span>
            <span className="rca-facet-values">{children}</span>
        </div>
    );
}

export interface FacetBarProps {
    incidents: readonly ListedIncident[];
    filters: RcaFilters;
    onFilters: (patch: Partial<RcaFilters>) => void;
    names: ServerNames;
    timeZone: string;
    /** How many incidents the filters show, of all in the minutes read. */
    shown: number;
}

// Memoized, as is IncidentGroups: the page renders again as the report and the servers' names arrive, and these two
// change only with the list, the filters, and the names.
export const FacetBar = memo(function FacetBar({ incidents, filters, onFilters, names, timeZone, shown }: FacetBarProps) {
    const counts = facetCounts(incidents, filters);
    const toggle = <T extends string>(list: readonly T[], value: T) => (list.includes(value) ? list.filter((v) => v !== value) : [...list, value]);
    const filtered = filters.categories.length + filters.severities.length + filters.targets.length > 0;
    const id = useId();
    const custom = "from" in filters.window ? filters.window : null;
    const [choosing, setChoosing] = useState(false);
    const [from, setFrom] = useState("");
    const [to, setTo] = useState("");
    const [why, setWhy] = useState("");
    const windowValue = custom ? "custom" : choosing ? "choose" : String((filters.window as { newest: RcaNewest }).newest);
    const chip = (key: string, label: ReactNode, count: number, pressed: boolean, onClick: () => void, name: string) => (
        <ToggleButton key={key} size="small" appearance="outline" className="rca-facet-chip" checked={pressed} disabled={count === 0 && !pressed} onClick={onClick} aria-label={`${name}: ${count} incident${count === 1 ? "" : "s"}`}>
            {label}
            <span className="rca-count">{count}</span>
        </ToggleButton>
    );
    const apply = () => {
        const a = resolveTime(from, new Date(), timeZone);
        const b = resolveTime(to, new Date(), timeZone);
        if (!a || !b || b <= a) return setWhy("Give both times, the end after the start.");
        if (b.getTime() - a.getTime() > MAX_WINDOW_HOURS * 3_600_000) return setWhy(`At most ${MAX_WINDOW_HOURS} hours: ask the chat about a longer one.`);
        setWhy("");
        setChoosing(false);
        onFilters({ window: { from: a, to: b } });
    };
    return (
        <section className="rca-panel rca-facets" aria-label="Filter the incidents">
            <Facet name="Severity">
                {RCA_SEVERITIES.map((s) => chip(s.id, <SeverityMark severity={s.id} />, counts.severities[s.id], filters.severities.includes(s.id), () => onFilters({ severities: toggle(filters.severities, s.id) }), s.label))}
            </Facet>
            <Facet name="Category">
                {RCA_CATEGORIES.map((c) => chip(c.id, c.label, counts.categories[c.id], filters.categories.includes(c.id), () => onFilters({ categories: toggle(filters.categories, c.id) }), c.label))}
            </Facet>
            <Facet name="Server and database">
                {RCA_FACET_TARGETS.map((t) =>
                    chip(
                        t,
                        <>
                            <span className={`rca-dot rca-dot-${t.toLowerCase()}`} aria-hidden="true" />
                            {targetLabel(t, names)}
                        </>,
                        counts.targets[t] ?? 0,
                        filters.targets.includes(t),
                        () => onFilters({ targets: toggle(filters.targets, t) }),
                        targetLabel(t, names),
                    ),
                )}
            </Facet>
            <div className="rca-facet-view">
                <label className="rca-facet-name" htmlFor={`${id}-window`}>
                    Minutes
                </label>
                <Select
                    id={`${id}-window`}
                    size="small"
                    value={windowValue}
                    onChange={(_, data) => {
                        if (data.value === "choose") {
                            const end = custom?.to ?? new Date();
                            setFrom(localInput(custom?.from ?? new Date(end.getTime() - 90 * 60_000), timeZone));
                            setTo(localInput(end, timeZone));
                            setChoosing(true);
                        } else if (data.value !== "custom") {
                            setChoosing(false);
                            onFilters({ window: { newest: Number(data.value) as RcaNewest } });
                        }
                    }}
                >
                    {RCA_NEWEST_MINUTES.map((n) => (
                        <option key={n} value={String(n)}>
                            {NEWEST_LABEL[n]}
                        </option>
                    ))}
                    {custom ? <option value="custom">{`${bothTimes(custom.from, timeZone)} to ${bothTimes(custom.to, timeZone)}`}</option> : null}
                    <option value="choose">Choose the minutes…</option>
                </Select>
                <span className="rca-facet-name">Group by</span>
                <span className="mc-lens" role="group" aria-label="Group by">
                    {(["category", "target", "none"] as RcaGroup[]).map((g) => (
                        <ToggleButton key={g} size="small" appearance="subtle" checked={filters.group === g} onClick={() => onFilters({ group: g })}>
                            {g === "category" ? "Category" : g === "target" ? "Server" : "None"}
                        </ToggleButton>
                    ))}
                </span>
                <span className="rca-facet-name">Sort by</span>
                <span className="mc-lens" role="group" aria-label="Sort by">
                    {(["severity", "time"] as RcaSort[]).map((s) => (
                        <ToggleButton key={s} size="small" appearance="subtle" checked={filters.sort === s} onClick={() => onFilters({ sort: s })}>
                            {s === "severity" ? "Severity" : "Time"}
                        </ToggleButton>
                    ))}
                </span>
                {filtered ? (
                    <Button size="small" appearance="subtle" onClick={() => onFilters({ categories: [], severities: [], targets: [] })}>
                        Clear the filters
                    </Button>
                ) : null}
            </div>
            {choosing ? (
                <div className="rca-facet-view">
                    <label className="rca-facet-name" htmlFor={`${id}-from`}>
                        From
                    </label>
                    <Input id={`${id}-from`} size="small" type="datetime-local" value={from} onChange={(_, d) => setFrom(d.value)} />
                    <label className="rca-facet-name" htmlFor={`${id}-to`}>
                        To
                    </label>
                    <Input id={`${id}-to`} size="small" type="datetime-local" value={to} onChange={(_, d) => setTo(d.value)} />
                    <Button size="small" appearance="primary" onClick={apply}>
                        Read these minutes
                    </Button>
                    <Button size="small" appearance="subtle" onClick={() => setChoosing(false)}>
                        Cancel
                    </Button>
                    {why ? (
                        <span className="rca-muted" role="alert">
                            {why}
                        </span>
                    ) : null}
                </div>
            ) : null}
            <p className="rca-muted rca-facet-summary" aria-live="polite">
                {filtered ? `Showing ${shown} of ${incidents.length} incidents.` : `${incidents.length} incident${incidents.length === 1 ? "" : "s"}.`}
            </p>
        </section>
    );
});

export interface IncidentGroupsProps {
    groups: ReadonlyArray<IncidentGroup<ListedIncident>>;
    group: RcaGroup;
    selectedKey: string | null;
    onSelect: (key: string) => void;
    names: ServerNames;
    timeZone: string;
}

export const IncidentGroups = memo(function IncidentGroups({ groups, group, selectedKey, onSelect, names, timeZone }: IncidentGroupsProps) {
    const id = useId();
    return (
        <div className="rca-groups">
            {groups.map((g) => {
                const title = group === "category" ? categoryLabel(g.id as never) : group === "target" ? targetLabel(g.id, names) : null;
                const headingId = `${id}-${g.id}`;
                return (
                    <section key={g.id} className="rca-group" aria-labelledby={title ? headingId : undefined} aria-label={title ? undefined : "Incidents"}>
                        {title ? (
                            <h3 id={headingId}>
                                {group === "target" ? <span className={`rca-dot rca-dot-${g.id.toLowerCase()}`} aria-hidden="true" /> : null}
                                {title}
                                <span className="rca-count">{g.items.length}</span>
                            </h3>
                        ) : null}
                        <ul className="rca-episodes">
                            {g.items.map((e) => (
                                <li key={e.key}>
                                    <button type="button" className="rca-episode" aria-current={e.key === selectedKey ? "true" : undefined} onClick={() => onSelect(e.key)}>
                                        <span className="rca-episode-head">
                                            <SeverityMark severity={e.severity} reason={e.severityReason} />
                                            <strong>
                                                {e.target}: {e.signal}
                                            </strong>
                                        </span>
                                        <span className="rca-muted">
                                            {bothTimes(new Date(e.start), timeZone)} · peak {e.peak}
                                        </span>
                                        <span className="rca-muted">
                                            {e.support}, in {e.source}
                                        </span>
                                        <span className="sr-only">{e.severityReason}</span>
                                    </button>
                                </li>
                            ))}
                        </ul>
                    </section>
                );
            })}
        </div>
    );
});
