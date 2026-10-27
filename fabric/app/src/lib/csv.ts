// CSV export (RFC 4180) of exactly the data a visual shows.

export interface CsvColumn {
    key: string;
    label: string;
}

function cell(value: unknown): string {
    if (value === null || value === undefined) return "";
    let text = value instanceof Date ? value.toISOString() : String(value);
    // Spreadsheet formula guard: text that a spreadsheet would run as a formula is prefixed with a quote.
    if (typeof value === "string" && /^[=+\-@\t\r]/.test(text)) text = `'${text}`;
    return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

export function toCsv(columns: readonly CsvColumn[], rows: ReadonlyArray<Record<string, unknown>>): string {
    const lines = [columns.map((c) => cell(c.label)).join(",")];
    for (const row of rows) lines.push(columns.map((c) => cell(row[c.key])).join(","));
    return `${lines.join("\r\n")}\r\n`;
}

/** A safe file name: letters, digits, dot, dash, and underscore. */
export function csvFileName(stem: string, at: Date = new Date()): string {
    const safe = stem.toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "data";
    const stamp = at.toISOString().slice(0, 16).replace(/[:T]/g, "").replace(/-/g, "");
    return `dbhub-${safe}-${stamp}Z.csv`;
}

export function downloadText(fileName: string, text: string, type = "text/csv;charset=utf-8"): void {
    const blob = new Blob([`\uFEFF${text}`], { type });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = fileName;
    link.rel = "noopener";
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
}
