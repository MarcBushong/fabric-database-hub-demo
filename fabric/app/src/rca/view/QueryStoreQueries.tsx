// The next steps' ready-to-run, read-only queries of a target's own Query Store for an incident's minutes, each with a
// Copy button (ADR 0031, section 8): explain_incident's details.queryStoreQueries, shown as the tools built them from the
// incident's measured target, family, and times. The view adds no fact of its own, and shows nothing it doesn't recognize.

import { useEffect, useState } from "react";
import { Button } from "@fluentui/react-components";
import { Checkmark16Regular, Copy16Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { copyText } from "@/lib/clipboard";
import type { QueryStoreQuery } from "../query-store";
import { bothTimes } from "../time";
import type { InvestigationResult } from "../types";

const FIELDS = ["target", "database", "fromUtc", "toUtc", "text"] as const;

/** The result's queries, each as the tools built it: anything else in its place is left out. */
function queriesOf(result: InvestigationResult): QueryStoreQuery[] {
    const list = result.details?.queryStoreQueries;
    if (!Array.isArray(list)) return [];
    return list.filter((q: unknown): q is QueryStoreQuery => {
        if (!q || typeof q !== "object") return false;
        const r = q as Record<string, unknown>;
        return FIELDS.every((k) => typeof r[k] === "string" && r[k] !== "") && (r.language === "tsql" || r.language === "postgresql") && !Number.isNaN(Date.parse(r.fromUtc as string)) && !Number.isNaN(Date.parse(r.toUtc as string));
    });
}

export function QueryStoreQueries({ incident, timeZone }: { incident: InvestigationResult; timeZone: string }) {
    const { notify } = useApp();
    const [copied, setCopied] = useState<number | null>(null);

    useEffect(() => {
        if (copied === null) return;
        const timer = window.setTimeout(() => setCopied(null), 2200);
        return () => window.clearTimeout(timer);
    }, [copied]);

    const queries = queriesOf(incident);
    if (queries.length === 0) return null;

    const copy = async (i: number, q: QueryStoreQuery) => {
        const ok = await copyText(q.text);
        notify(ok ? `Query copied: run it in ${q.database} on ${q.target}` : "Copy is blocked here: select the query and press Ctrl+C", ok ? "success" : "warning");
        if (ok) setCopied(i);
    };

    return (
        <>
            {queries.map((q, i) => {
                const from = new Date(q.fromUtc);
                const to = new Date(q.toUtc);
                const minutes = from.getTime() === to.getTime() ? `at ${bothTimes(from, timeZone)}` : `from ${bothTimes(from, timeZone)} to ${bothTimes(to, timeZone)}`;
                const about = `${q.target}'s Query Store in ${q.database}, ${minutes}`;
                return (
                    <figure key={`${i}-${q.target}-${q.fromUtc}`} className="rca-query">
                        <figcaption className="rca-query-head">
                            <span>{`Read-only query of ${about}`}</span>
                            <Button size="small" appearance="subtle" icon={copied === i ? <Checkmark16Regular /> : <Copy16Regular />} aria-label={`Copy the query of ${about}`} onClick={() => void copy(i, q)}>
                                {copied === i ? "Copied" : "Copy"}
                            </Button>
                        </figcaption>
                        <pre className="rca-code">{q.text}</pre>
                    </figure>
                );
            })}
        </>
    );
}
