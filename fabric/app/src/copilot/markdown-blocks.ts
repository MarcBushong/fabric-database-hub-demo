// Splits a Copilot answer's Markdown into blocks for the dock's renderer (markdown.tsx). Pure, so it's tested on its own.

export type Block =
    | { kind: "heading"; level: number; text: string }
    | { kind: "paragraph"; text: string }
    | { kind: "list"; ordered: boolean; items: string[] }
    | { kind: "code"; lang: string; text: string }
    | { kind: "table"; head: string[]; rows: string[][] }
    | { kind: "quote"; text: string }
    | { kind: "rule" };

const splitRow = (line: string) =>
    line
        .trim()
        .replace(/^\|/, "")
        .replace(/\|$/, "")
        .split("|")
        .map((c) => c.trim());

/**
 * While an answer streams, closes a code fence, bold, or inline code whose closing marker hasn't arrived yet, so the
 * partial text renders formatted instead of showing raw markers. Display only: the stored text is never changed.
 */
export function closeOpenMarks(markdown: string): string {
    const fences = (markdown.match(/^```/gm) ?? []).length;
    if (fences % 2 === 1) return `${markdown}\n\`\`\``;
    const prose = markdown.replace(/^```[\s\S]*?^```/gm, "");
    let closed = markdown;
    if ((prose.replace(/``+/g, "").match(/`/g) ?? []).length % 2 === 1) closed += "`";
    if ((prose.replace(/`[^`\n]*`/g, "").match(/\*\*/g) ?? []).length % 2 === 1) closed += "**";
    return closed;
}

export function parseBlocks(markdown: string): Block[] {
    const lines = markdown.replace(/\r\n/g, "\n").split("\n");
    const blocks: Block[] = [];
    let i = 0;
    while (i < lines.length) {
        const line = lines[i];
        const trimmed = line.trim();
        if (!trimmed) {
            i++;
            continue;
        }
        const fence = /^```\s*([\w+-]*)/.exec(trimmed);
        if (fence) {
            const body: string[] = [];
            i++;
            while (i < lines.length && !/^```/.test(lines[i].trim())) body.push(lines[i++]);
            i++;
            blocks.push({ kind: "code", lang: fence[1] ?? "", text: body.join("\n") });
            continue;
        }
        const heading = /^(#{1,4})\s+(.*)$/.exec(trimmed);
        if (heading) {
            blocks.push({ kind: "heading", level: heading[1].length, text: heading[2] });
            i++;
            continue;
        }
        if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
            blocks.push({ kind: "rule" });
            i++;
            continue;
        }
        if (trimmed.startsWith("|") && i + 1 < lines.length && /^\|?\s*:?-{2,}/.test(lines[i + 1].trim())) {
            const head = splitRow(trimmed);
            const rows: string[][] = [];
            i += 2;
            while (i < lines.length && lines[i].trim().startsWith("|")) rows.push(splitRow(lines[i++]));
            blocks.push({ kind: "table", head, rows });
            continue;
        }
        if (/^>\s?/.test(trimmed)) {
            const body: string[] = [];
            while (i < lines.length && /^>\s?/.test(lines[i].trim())) body.push(lines[i++].trim().replace(/^>\s?/, ""));
            blocks.push({ kind: "quote", text: body.join(" ") });
            continue;
        }
        const bullet = /^([-*+]|\d+[.)])\s+/;
        if (bullet.test(trimmed)) {
            const ordered = /^\d/.test(trimmed);
            const items: string[] = [];
            while (i < lines.length && lines[i].trim()) {
                const t = lines[i].trim();
                if (bullet.test(t)) items.push(t.replace(bullet, ""));
                else if (items.length > 0) items[items.length - 1] += ` ${t}`;
                i++;
            }
            blocks.push({ kind: "list", ordered, items });
            continue;
        }
        const body: string[] = [];
        while (i < lines.length && lines[i].trim() && !/^(#{1,4}\s|```|>|\||[-*+]\s|\d+[.)]\s)/.test(lines[i].trim())) body.push(lines[i++].trim());
        if (body.length === 0) body.push(lines[i++].trim());
        blocks.push({ kind: "paragraph", text: body.join(" ") });
    }
    return blocks;
}

