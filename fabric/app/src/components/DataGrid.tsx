// The app's table: sort by any column, filter the rows, and take them out as CSV. Rows can open a drill-down.

import { useMemo, useState, type KeyboardEvent, type ReactNode } from "react";
import { Button, Input, Table, TableBody, TableCell, TableHeader, TableHeaderCell, TableRow, Tooltip } from "@fluentui/react-components";
import { ArrowDownload16Regular, Copy16Regular, Search16Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import type { ColumnKind } from "@/data/queries";
import { copyText } from "@/lib/clipboard";
import { csvFileName, downloadText, toCsv } from "@/lib/csv";
import { formatCell, toDate } from "@/lib/format";
import { StatusBadge } from "./StatusBadge";

export interface GridColumn<R> {
    key: string;
    label: string;
    kind?: ColumnKind;
    /** A custom cell; the CSV and the filter still use the raw value. */
    render?: (row: R) => ReactNode;
    /** The value to sort by, when it isn't the raw value. */
    sortValue?: (row: R) => number | string | null;
    /** Right-aligned, tabular figures. */
    numeric?: boolean;
    width?: string;
}

const NUMERIC = new Set<ColumnKind>(["int", "decimal", "percent", "seconds", "minutes", "mb"]);

export interface DataGridProps<R extends Record<string, unknown>> {
    columns: ReadonlyArray<GridColumn<R>>;
    rows: readonly R[];
    caption: string;
    /** The CSV file's stem. */
    exportName: string;
    onRowClick?: (row: R) => void;
    /** What a row's click opens, for screen readers ("Open T3"). */
    rowLabel?: (row: R) => string;
    filterable?: boolean;
    exportable?: boolean;
    maxRows?: number;
    emptyText?: string;
    defaultSort?: { key: string; dir: 1 | -1 };
    size?: "small" | "medium";
}

function rawSortValue(value: unknown): number | string {
    if (typeof value === "number") return value;
    const date = typeof value === "string" ? toDate(value) : value instanceof Date ? value : null;
    if (date && typeof value === "string" && /^\d{4}-\d{2}-\d{2}T/.test(value)) return date.getTime();
    return value === null || value === undefined ? "" : String(value).toLowerCase();
}

export function DataGrid<R extends Record<string, unknown>>(props: DataGridProps<R>) {
    const { notify } = useApp();
    const [filter, setFilter] = useState("");
    const [sort, setSort] = useState<{ key: string; dir: 1 | -1 } | null>(props.defaultSort ?? null);
    const max = props.maxRows ?? 200;

    const filtered = useMemo(() => {
        const needle = filter.trim().toLowerCase();
        if (!needle) return props.rows;
        return props.rows.filter((row) => props.columns.some((c) => String(row[c.key] ?? "").toLowerCase().includes(needle)));
    }, [props.rows, props.columns, filter]);

    const sorted = useMemo(() => {
        if (!sort) return filtered;
        const column = props.columns.find((c) => c.key === sort.key);
        const value = (row: R) => (column?.sortValue ? column.sortValue(row) ?? "" : rawSortValue(row[sort.key]));
        return [...filtered].sort((a, b) => {
            const va = value(a);
            const vb = value(b);
            if (typeof va === "number" && typeof vb === "number") return (va - vb) * sort.dir;
            return String(va).localeCompare(String(vb)) * sort.dir;
        });
    }, [filtered, sort, props.columns]);

    const shown = sorted.slice(0, max);
    // Columns keep a readable width; a narrow container (the dock open, a laptop) scrolls the table sideways instead.
    const minWidth = props.columns.reduce((sum, c) => sum + (c.width ? Number.parseInt(c.width, 10) || 120 : c.kind === "datetime" ? 150 : c.numeric || (c.kind && NUMERIC.has(c.kind)) ? 96 : 130), 0);
    const csv = () => toCsv(props.columns, sorted);
    const toggleSort = (key: string) => setSort((s) => (s?.key === key ? (s.dir === 1 ? { key, dir: -1 } : null) : { key, dir: 1 }));
    const onRowKey = (event: KeyboardEvent<HTMLTableRowElement>, row: R) => {
        if (props.onRowClick && (event.key === "Enter" || event.key === " ")) {
            event.preventDefault();
            props.onRowClick(row);
        }
    };

    return (
        <div className="grid">
            {props.filterable !== false || props.exportable !== false ? (
                <div className="grid-tools">
                    {props.filterable !== false ? (
                        <Input
                            size="small"
                            className="grid-filter"
                            contentBefore={<Search16Regular aria-hidden={true} />}
                            placeholder="Filter rows"
                            aria-label={`Filter ${props.caption}`}
                            value={filter}
                            onChange={(_, data) => setFilter(data.value)}
                        />
                    ) : null}
                    <span className="grid-count" aria-live="polite">
                        {filter ? `${filtered.length} of ${props.rows.length} rows` : `${props.rows.length} row${props.rows.length === 1 ? "" : "s"}`}
                    </span>
                    {props.exportable !== false ? (
                        <>
                            <Tooltip content="Download the rows as CSV" relationship="label">
                                <Button
                                    size="small"
                                    appearance="subtle"
                                    icon={<ArrowDownload16Regular />}
                                    disabled={sorted.length === 0}
                                    onClick={() => {
                                        downloadText(csvFileName(props.exportName), csv());
                                        notify("CSV downloaded", "success");
                                    }}
                                />
                            </Tooltip>
                            <Tooltip content="Copy the rows as CSV" relationship="label">
                                <Button size="small" appearance="subtle" icon={<Copy16Regular />} disabled={sorted.length === 0} onClick={async () => notify((await copyText(csv())) ? "CSV copied" : "Copy is blocked here: use Download", "info")} />
                            </Tooltip>
                        </>
                    ) : null}
                </div>
            ) : null}
            <div className="grid-scroll" tabIndex={0} role="region" aria-label={props.caption}>
                <Table size={props.size === "medium" ? "medium" : "small"} sortable aria-label={props.caption} className="grid-table" style={{ minWidth: `max(100%, ${minWidth}px)` }}>
                    <TableHeader>
                        <TableRow>
                            {props.columns.map((c) => (
                                <TableHeaderCell
                                    key={c.key}
                                    sortDirection={sort?.key === c.key ? (sort.dir === 1 ? "ascending" : "descending") : undefined}
                                    onClick={() => toggleSort(c.key)}
                                    className={c.numeric || (c.kind && NUMERIC.has(c.kind)) ? "num" : undefined}
                                    style={c.width ? { width: c.width } : undefined}
                                >
                                    {c.label}
                                </TableHeaderCell>
                            ))}
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {shown.map((row, i) => (
                            <TableRow
                                key={i}
                                className={props.onRowClick ? "grid-row-action" : undefined}
                                onClick={props.onRowClick ? () => props.onRowClick?.(row) : undefined}
                                onKeyDown={props.onRowClick ? (e) => onRowKey(e, row) : undefined}
                                tabIndex={props.onRowClick ? 0 : undefined}
                                aria-label={props.onRowClick && props.rowLabel ? props.rowLabel(row) : undefined}
                            >
                                {props.columns.map((c) => (
                                    <TableCell key={c.key} className={c.numeric || (c.kind && NUMERIC.has(c.kind)) ? "num" : undefined}>
                                        {c.render ? (
                                            c.render(row)
                                        ) : c.kind === "status" ? (
                                            <StatusBadge status={row[c.key]} short />
                                        ) : c.kind === "url" && typeof row[c.key] === "string" && /^https:\/\//.test(row[c.key] as string) ? (
                                            <a href={row[c.key] as string} target="_blank" rel="noopener noreferrer">
                                                Open
                                            </a>
                                        ) : (
                                            formatCell({ kind: c.kind ?? "text" }, row[c.key])
                                        )}
                                    </TableCell>
                                ))}
                            </TableRow>
                        ))}
                    </TableBody>
                </Table>
                {shown.length === 0 ? <p className="grid-empty">{filter ? "No row matches the filter." : props.emptyText ?? "No rows."}</p> : null}
            </div>
            {sorted.length > max ? <p className="grid-note">{`Showing the first ${max} of ${sorted.length} rows; the CSV has all of them.`}</p> : null}
        </div>
    );
}
