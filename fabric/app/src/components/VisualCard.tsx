import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Code2, Copy, Download, Maximize2, Minimize2, RefreshCw, Table2 } from "lucide-react";

import { useApp } from "@/app-context";
import type { ColumnSpec, QuerySpec } from "@/data/queries";
import type { Row } from "@/data/query-client";
import { copyText } from "@/lib/clipboard";
import { csvFileName, downloadText, toCsv } from "@/lib/csv";
import { formatDateTimeUtc } from "@/lib/format";
import { DataTable } from "./DataTable";
import { DaxView } from "./DaxView";

export interface VisualTable {
    columns: ColumnSpec[];
    rows: Row[];
    caption: string;
}

export interface VisualCardProps {
    title: string;
    subtitle?: string;
    /** The queries that fed the visual; "Show the DAX" displays each one. */
    specs: Array<QuerySpec | null>;
    loading: boolean;
    error?: Error;
    empty?: boolean;
    emptyText?: string;
    /** The data the visual shows: the data table, the CSV download, and the copy. */
    table: VisualTable | null;
    /** One sentence that describes what the visual shows, for screen readers. */
    summary: string;
    className?: string;
    toolbar?: ReactNode;
    fetchedAt?: Date;
    onRefresh?: () => void;
    children: ReactNode;
}

function CardContent(props: VisualCardProps & { inFocus: boolean; onFocusToggle: () => void }) {
    const { notify } = useApp();
    const [showDax, setShowDax] = useState(false);
    const [showData, setShowData] = useState(false);
    const headingId = useId();
    const summaryId = useId();
    const specs = props.specs.filter((s): s is QuerySpec => s !== null);
    const csvText = () => (props.table ? toCsv(props.table.columns, props.table.rows) : "");

    const copyDax = async () => {
        const text = specs.map((s) => `// ${s.title}\n${s.dax}`).join("\n\n");
        notify((await copyText(text)) ? "DAX copied" : "Copy is blocked here: select the query and press Ctrl+C");
        if (!showDax) setShowDax(true);
    };
    const downloadCsv = () => {
        if (!props.table) return;
        downloadText(csvFileName(specs[0]?.id ?? props.title), csvText());
        notify("CSV downloaded");
    };
    const copyCsv = async () => {
        notify((await copyText(csvText())) ? "CSV copied" : "Copy is blocked here: use Download CSV");
    };

    return (
        <section className={`card glass ${props.inFocus ? "" : props.className ?? ""}`} aria-labelledby={headingId}>
            <div className="card-head">
                <div>
                    <h3 id={headingId}>{props.title}</h3>
                    {props.subtitle ? <p>{props.subtitle}</p> : null}
                </div>
                <div className="card-actions" role="toolbar" aria-label={`${props.title}: actions`}>
                    {props.toolbar}
                    <button type="button" className="icon-btn" aria-pressed={showDax} onClick={() => setShowDax((v) => !v)} title="Show the DAX query">
                        <Code2 aria-hidden="true" />
                        DAX
                    </button>
                    <button type="button" className="icon-btn" onClick={copyDax} title="Copy the DAX query" aria-label="Copy the DAX query">
                        <Copy aria-hidden="true" />
                    </button>
                    <button type="button" className="icon-btn" aria-pressed={showData} onClick={() => setShowData((v) => !v)} title="Show the data as a table" disabled={!props.table}>
                        <Table2 aria-hidden="true" />
                        Data
                    </button>
                    <button type="button" className="icon-btn" onClick={downloadCsv} title="Download the data as CSV" aria-label="Download the data as CSV" disabled={!props.table || props.table.rows.length === 0}>
                        <Download aria-hidden="true" />
                    </button>
                    {props.onRefresh ? (
                        <button type="button" className="icon-btn" onClick={props.onRefresh} title="Run the query again" aria-label="Run the query again">
                            <RefreshCw aria-hidden="true" />
                        </button>
                    ) : null}
                    <button
                        type="button"
                        className="icon-btn"
                        onClick={props.onFocusToggle}
                        title={props.inFocus ? "Leave focus mode (Esc)" : "Focus on this visual"}
                        aria-label={props.inFocus ? "Leave focus mode" : "Focus on this visual"}
                    >
                        {props.inFocus ? <Minimize2 aria-hidden="true" /> : <Maximize2 aria-hidden="true" />}
                    </button>
                </div>
            </div>

            {showDax
                ? specs.map((s) => (
                      <div key={s.id} className="dax-block">
                          <div className="dax-meta">
                              <strong>{s.title}</strong>
                              <span>Row bound {s.rowLimit.toLocaleString("en-US")} (resultSetRowCountLimit)</span>
                              <span>Runs through the read-only connector as the signed-in user</span>
                          </div>
                          <DaxView dax={s.dax} label={`DAX query: ${s.title}`} />
                      </div>
                  ))
                : null}

            <div className="card-body" role="group" aria-label={props.title} aria-describedby={summaryId}>
                <p id={summaryId} className="sr-only">
                    {props.summary}
                </p>
                {props.error ? (
                    <div className="error-box" role="alert">
                        <strong>This visual couldn't load.</strong>
                        <span>{props.error.message}</span>
                        {props.onRefresh ? (
                            <button type="button" className="icon-btn" onClick={props.onRefresh}>
                                Try again
                            </button>
                        ) : null}
                    </div>
                ) : props.loading && !props.table ? (
                    <div className="skeleton" aria-busy="true" />
                ) : props.empty ? (
                    <div className="empty">{props.emptyText ?? "No data in this selection."}</div>
                ) : (
                    props.children
                )}
            </div>

            {showData && props.table ? (
                <>
                    <DataTable columns={props.table.columns} rows={props.table.rows} caption={props.table.caption} />
                    <div className="dax-meta">
                        <button type="button" className="btn-link" onClick={copyCsv}>
                            Copy as CSV
                        </button>
                        {props.fetchedAt ? <span>Queried {formatDateTimeUtc(props.fetchedAt)}</span> : null}
                    </div>
                </>
            ) : null}
        </section>
    );
}

/** A visual with its extract actions: show and copy the DAX, the data as a table, CSV, and focus mode. */
export function VisualCard(props: VisualCardProps) {
    const [inFocus, setInFocus] = useState(false);
    const overlayRef = useRef<HTMLDivElement>(null);
    const returnFocus = useRef<HTMLElement | null>(null);

    useEffect(() => {
        if (!inFocus) return;
        const onKey = (event: KeyboardEvent) => {
            if (event.key === "Escape") setInFocus(false);
        };
        document.addEventListener("keydown", onKey);
        overlayRef.current?.querySelector<HTMLElement>("button")?.focus();
        return () => {
            document.removeEventListener("keydown", onKey);
            returnFocus.current?.focus();
        };
    }, [inFocus]);

    const toggle = () => {
        if (!inFocus) returnFocus.current = document.activeElement as HTMLElement | null;
        setInFocus((v) => !v);
    };

    return (
        <>
            <CardContent {...props} inFocus={false} onFocusToggle={toggle} />
            {inFocus
                ? createPortal(
                      <div className="focus-overlay" ref={overlayRef} role="dialog" aria-modal="true" aria-label={`${props.title}, focus mode`} onClick={(e) => e.target === e.currentTarget && setInFocus(false)}>
                          <CardContent {...props} inFocus onFocusToggle={toggle} />
                      </div>,
                      document.body,
                  )
                : null}
        </>
    );
}
