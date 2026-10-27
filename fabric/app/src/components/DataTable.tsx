import type { ColumnSpec } from "@/data/queries";
import type { Row } from "@/data/query-client";
import { formatCell } from "@/lib/format";
import { StatusBadge } from "./StatusBadge";

const NUMERIC = new Set(["int", "decimal", "percent", "seconds", "minutes", "mb"]);

/** The text alternative of a visual: its data as an accessible table. */
export function DataTable({ columns, rows, caption, limit = 200 }: { columns: ColumnSpec[]; rows: readonly Row[]; caption: string; limit?: number }) {
    const shown = rows.slice(0, limit);
    return (
        <div className="table-wrap" tabIndex={0} role="region" aria-label={caption}>
            <table className="data">
                <caption>
                    {caption}
                    {rows.length > limit ? ` (first ${limit} of ${rows.length} rows; download the CSV for all of them)` : ""}
                </caption>
                <thead>
                    <tr>
                        {columns.map((c) => (
                            <th key={c.key} scope="col">
                                {c.label}
                            </th>
                        ))}
                    </tr>
                </thead>
                <tbody>
                    {shown.map((row, i) => (
                        <tr key={i}>
                            {columns.map((c) => (
                                <td key={c.key} className={NUMERIC.has(c.kind) ? "num" : undefined}>
                                    {c.kind === "status" && row[c.key] ? (
                                        <StatusBadge status={row[c.key]} />
                                    ) : c.kind === "url" && typeof row[c.key] === "string" && /^https:\/\//.test(row[c.key] as string) ? (
                                        <a href={row[c.key] as string} target="_blank" rel="noopener noreferrer">
                                            Open
                                        </a>
                                    ) : (
                                        formatCell(c, row[c.key])
                                    )}
                                </td>
                            ))}
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    );
}
