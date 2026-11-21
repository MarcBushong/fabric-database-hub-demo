// A small Markdown renderer for Copilot's answers: headings, paragraphs, lists, tables, quotes, code, bold,
// italics, inline code, and https links. It builds React elements only (never HTML strings), so nothing in an
// answer can run script or change the page.

import { Fragment, type ReactNode } from "react";

import { parseBlocks } from "./markdown-blocks";

const INLINE = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*\s][^*]*\*|_[^_\s][^_]*_)|(\[[^\]]+\]\((https:\/\/[^)\s]+)\))/;

function renderInline(text: string, keyPrefix = "i"): ReactNode[] {
    const out: ReactNode[] = [];
    let rest = text;
    let n = 0;
    while (rest) {
        const m = INLINE.exec(rest);
        if (!m) {
            out.push(rest);
            break;
        }
        if (m.index > 0) out.push(rest.slice(0, m.index));
        const token = m[0];
        const key = `${keyPrefix}-${n++}`;
        if (m[1]) out.push(<code key={key}>{token.slice(1, -1)}</code>);
        else if (m[2]) out.push(<strong key={key}>{renderInline(token.slice(2, -2), key)}</strong>);
        else if (m[3]) out.push(<em key={key}>{renderInline(token.slice(1, -1), key)}</em>);
        else if (m[4] && m[5]) {
            const label = token.slice(1, token.indexOf("]("));
            out.push(
                <a key={key} href={m[5]} target="_blank" rel="noopener noreferrer">
                    {label}
                </a>,
            );
        }
        rest = rest.slice(m.index + token.length);
    }
    return out;
}

export function Markdown({ text }: { text: string }) {
    const blocks = parseBlocks(text);
    return (
        <div className="cp-md">
            {blocks.map((b, i) => {
                const key = `b${i}`;
                switch (b.kind) {
                    case "heading": {
                        const level = Math.min(6, b.level + 2);
                        const Tag = `h${level}` as "h3" | "h4" | "h5" | "h6";
                        return <Tag key={key}>{renderInline(b.text, key)}</Tag>;
                    }
                    case "paragraph":
                        return <p key={key}>{renderInline(b.text, key)}</p>;
                    case "list": {
                        const items = b.items.map((item, j) => <li key={`${key}-${j}`}>{renderInline(item, `${key}-${j}`)}</li>);
                        return b.ordered ? <ol key={key}>{items}</ol> : <ul key={key}>{items}</ul>;
                    }
                    case "code":
                        return (
                            <pre key={key} className="cp-code" tabIndex={0}>
                                <code>{b.text}</code>
                            </pre>
                        );
                    case "table":
                        return (
                            <div key={key} className="cp-table-wrap" tabIndex={0}>
                                <table>
                                    <thead>
                                        <tr>
                                            {b.head.map((h, j) => (
                                                <th key={j} scope="col">
                                                    {renderInline(h, `${key}-h${j}`)}
                                                </th>
                                            ))}
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {b.rows.map((r, j) => (
                                            <tr key={j}>
                                                {r.map((c, k) => (
                                                    <td key={k}>{renderInline(c, `${key}-${j}-${k}`)}</td>
                                                ))}
                                            </tr>
                                        ))}
                                    </tbody>
                                </table>
                            </div>
                        );
                    case "quote":
                        return <blockquote key={key}>{renderInline(b.text, key)}</blockquote>;
                    case "rule":
                        return <hr key={key} />;
                    default:
                        return <Fragment key={key} />;
                }
            })}
        </div>
    );
}
