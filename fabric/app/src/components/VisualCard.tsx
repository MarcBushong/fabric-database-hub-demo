// A visual's card: its title, where its data comes from, Ask Copilot, and the ways to take the data out (the data as a
// table, the DAX, CSV), with refresh and focus mode.

import { useId, useState, type ReactNode } from "react";
import { Button, Dialog, DialogBody, DialogSurface, DialogTitle, Menu, MenuDivider, MenuItem, MenuList, MenuPopover, MenuTrigger, Spinner, Tooltip } from "@fluentui/react-components";
import { ArrowClockwise16Regular, ArrowDownload16Regular, Code16Regular, Copy16Regular, Dismiss20Regular, FullScreenMaximize16Regular, MoreHorizontal20Regular, Sparkle16Filled, TableSimple16Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { useCopilot } from "@/copilot/use-copilot";
import type { ColumnSpec, QuerySpec } from "@/data/queries";
import type { Row } from "@/data/query-client";
import { buildAskContext } from "@/lib/ask";
import { copyText } from "@/lib/clipboard";
import { csvFileName, downloadText, toCsv } from "@/lib/csv";
import { formatDateTimeUtc } from "@/lib/format";
import { DataGrid } from "./DataGrid";
import { DaxView } from "./DaxView";
import { ProvenanceBadge } from "./ProvenanceBadge";

export interface VisualTable {
    columns: ColumnSpec[];
    rows: Row[];
    caption: string;
}

export interface LiveSource {
    at: string;
    source: readonly string[];
    errors: readonly string[];
}

export interface VisualCardProps {
    /** Stable visual ID ("overview.health"): Copilot's visualId and the CSV's name. */
    id: string;
    title: string;
    subtitle?: string;
    /** The queries behind the visual: Show DAX and Ask Copilot use them. */
    specs: Array<QuerySpec | null | undefined>;
    loading: boolean;
    error?: Error | null;
    empty?: boolean;
    emptyText?: ReactNode;
    /** The data the visual shows: the data table, the CSV, and Ask Copilot's rows. */
    table: VisualTable | null;
    /** One sentence for screen readers. */
    summary: string;
    className?: string;
    toolbar?: ReactNode;
    fetchedAt?: Date;
    onRefresh?: () => void;
    /** Ask Copilot's question; without it, Copilot explains the visual. */
    askPrompt?: string;
    /** Hide the provenance chip (a page that says it once already). */
    quiet?: boolean;
    /** Live data from Database Hub instead of the history: when it was read, the routes that answered, and the ones that failed. */
    live?: LiveSource | null;
    children: ReactNode;
}

function Body(props: VisualCardProps) {
    if (props.error) {
        return (
            <div className="vcard-error" role="alert">
                <strong>This visual couldn't load.</strong>
                <span>{props.error.message}</span>
                {props.onRefresh ? (
                    <Button size="small" onClick={props.onRefresh}>
                        Try again
                    </Button>
                ) : null}
            </div>
        );
    }
    if (props.loading && !props.table) {
        return (
            <div className="vcard-loading" aria-busy="true">
                <Spinner size="tiny" label="Loading" />
            </div>
        );
    }
    if (props.empty) return <div className="vcard-empty">{props.emptyText ?? "No data in this selection."}</div>;
    return <>{props.children}</>;
}

export function VisualCard(props: VisualCardProps) {
    const { notify, view, meta, filters, provenance } = useApp();
    const copilot = useCopilot();
    const [showDax, setShowDax] = useState(false);
    const [showData, setShowData] = useState(false);
    const [focus, setFocus] = useState(false);
    const headingId = useId();
    const summaryId = useId();
    const specs = props.specs.filter((s): s is QuerySpec => Boolean(s));
    const rows = props.table?.rows ?? [];
    const csvText = () => (props.table ? toCsv(props.table.columns, props.table.rows) : "");

    const ask = () =>
        copilot.ask(
            buildAskContext({
                title: props.title,
                page: view.page,
                visualId: props.id,
                specs: props.live ? [] : specs,
                rows: props.table?.rows,
                columns: props.table?.columns,
                prompt: props.askPrompt,
                provenance: props.live ? "live" : provenance,
                meta: props.live ? null : meta,
                asOf: props.live?.at,
                ...(props.live ? {} : { filters, window: view.window }),
            }),
        );

    const tools = (inFocus: boolean) => (
        <div className="vcard-tools" role="toolbar" aria-label={`${props.title}: actions`}>
            {props.toolbar}
            <Button size="small" appearance="subtle" className="ask-copilot" icon={<Sparkle16Filled />} onClick={ask} disabled={props.loading && !props.table}>
                Ask Copilot
            </Button>
            <Tooltip content={showData ? "Hide the data table" : "Show the data as a table"} relationship="label">
                <Button size="small" appearance="subtle" icon={<TableSimple16Regular />} aria-pressed={showData} onClick={() => setShowData((v) => !v)} disabled={!props.table} />
            </Tooltip>
            <Menu>
                <MenuTrigger disableButtonEnhancement>
                    <Tooltip content="More" relationship="label">
                        <Button size="small" appearance="subtle" icon={<MoreHorizontal20Regular />} />
                    </Tooltip>
                </MenuTrigger>
                <MenuPopover>
                    <MenuList>
                        {props.live ? (
                            <MenuItem icon={<Code16Regular />} onClick={() => setShowDax((v) => !v)}>
                                {showDax ? "Hide the Database Hub routes" : "Show the Database Hub routes"}
                            </MenuItem>
                        ) : (
                            <>
                                <MenuItem icon={<Code16Regular />} onClick={() => setShowDax((v) => !v)} disabled={specs.length === 0}>
                                    {showDax ? "Hide the DAX" : "Show the DAX"}
                                </MenuItem>
                                <MenuItem
                                    icon={<Copy16Regular />}
                                    disabled={specs.length === 0}
                                    onClick={async () => notify((await copyText(specs.map((s) => `// ${s.title}\n${s.dax}`).join("\n\n"))) ? "DAX copied" : "Copy is blocked here: select the query and press Ctrl+C", "info")}
                                >
                                    Copy the DAX
                                </MenuItem>
                            </>
                        )}
                        <MenuDivider />
                        <MenuItem
                            icon={<ArrowDownload16Regular />}
                            disabled={rows.length === 0}
                            onClick={() => {
                                downloadText(csvFileName(specs[0]?.id ?? props.id), csvText());
                                notify("CSV downloaded", "success");
                            }}
                        >
                            Download CSV
                        </MenuItem>
                        <MenuItem icon={<Copy16Regular />} disabled={rows.length === 0} onClick={async () => notify((await copyText(csvText())) ? "CSV copied" : "Copy is blocked here: use Download CSV", "info")}>
                            Copy as CSV
                        </MenuItem>
                        <MenuDivider />
                        {props.onRefresh ? (
                            <MenuItem icon={<ArrowClockwise16Regular />} onClick={props.onRefresh}>
                                Run the query again
                            </MenuItem>
                        ) : null}
                        {!inFocus ? (
                            <MenuItem icon={<FullScreenMaximize16Regular />} onClick={() => setFocus(true)}>
                                Focus mode
                            </MenuItem>
                        ) : null}
                    </MenuList>
                </MenuPopover>
            </Menu>
        </div>
    );

    const extras = (
        <>
            {showDax && props.live ? (
                <div className="vcard-dax">
                    <p className="vcard-meta">
                        <strong>Database Hub routes</strong> · read-only, through the app's function, scoped to the demo's resource groups
                    </p>
                    <pre className="vcard-routes" aria-label="Database Hub routes">
                        {[...props.live.source, ...props.live.errors.map((e) => `failed: ${e}`)].join("\n")}
                    </pre>
                </div>
            ) : null}
            {showDax && !props.live
                ? specs.map((s) => (
                      <div key={s.id} className="vcard-dax">
                          <p className="vcard-meta">
                              <strong>{s.title}</strong> · row bound {s.rowLimit.toLocaleString("en-US")} · runs through the read-only connector as you
                          </p>
                          <DaxView dax={s.dax} label={`DAX query: ${s.title}`} />
                      </div>
                  ))
                : null}
            {showData && props.table ? <DataGrid columns={props.table.columns} rows={props.table.rows} caption={props.table.caption} exportName={specs[0]?.id ?? props.id} /> : null}
        </>
    );

    return (
        <section className={`vcard ${props.className ?? ""}`} aria-labelledby={headingId}>
            <header className="vcard-head">
                <div className="vcard-titles">
                    <h3 id={headingId}>{props.title}</h3>
                    {props.subtitle ? <p>{props.subtitle}</p> : null}
                </div>
                {tools(false)}
            </header>
            <div className="vcard-body" role="group" aria-labelledby={headingId} aria-describedby={summaryId}>
                <p id={summaryId} className="sr-only">
                    {props.summary}
                </p>
                <Body {...props} />
            </div>
            {extras}
            {props.live ? (
                <footer className="vcard-foot">
                    <ProvenanceBadge provenance="live" asOf={new Date(props.live.at)} />
                    {props.live.errors.length > 0 ? <span className="vcard-partial">{`Partial: ${props.live.errors.length} of ${props.live.source.length + props.live.errors.length} routes failed`}</span> : null}
                </footer>
            ) : !props.quiet && (props.fetchedAt || provenance !== "history") ? (
                <footer className="vcard-foot">
                    <ProvenanceBadge provenance={provenance} asOf={meta?.latestCapture} compact />
                    {props.fetchedAt ? <span>Queried {formatDateTimeUtc(props.fetchedAt)}</span> : null}
                </footer>
            ) : null}

            <Dialog open={focus} onOpenChange={(_, data) => setFocus(data.open)}>
                <DialogSurface className="vcard-focus" aria-describedby={undefined}>
                    <DialogBody>
                        <DialogTitle
                            action={
                                <Tooltip content="Leave focus mode (Esc)" relationship="label">
                                    <Button appearance="subtle" icon={<Dismiss20Regular />} onClick={() => setFocus(false)} />
                                </Tooltip>
                            }
                        >
                            {props.title}
                        </DialogTitle>
                        <div className="vcard-focus-body">
                            {props.subtitle ? <p className="vcard-meta">{props.subtitle}</p> : null}
                            <Body {...props} />
                            {extras}
                        </div>
                    </DialogBody>
                </DialogSurface>
            </Dialog>
        </section>
    );
}
