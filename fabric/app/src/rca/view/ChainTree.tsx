// The blocking chain as a tree, head blocker first (ADR 0031): what each session ran, who ran it, what it waited for,
// and the lock it held. An accessible tree: the head is level 1, and each waiter sits under the session it waits on.

import type { ChainNodeView } from "../tools";

const seconds = (n: number | undefined) => (n === undefined ? null : `${n.toLocaleString("en-US", { maximumFractionDigits: 1 })} s`);

function facts(node: ChainNodeView): string {
    const parts = [
        node.status,
        node.waitType ? `waits ${node.waitType}${node.waitS !== undefined ? ` for ${seconds(node.waitS)}` : ""}` : null,
        node.idleS !== undefined && node.idleS > 0 ? `idle ${seconds(node.idleS)}` : null,
        node.openTransactions ? `${node.openTransactions} open transaction${node.openTransactions === 1 ? "" : "s"}` : null,
    ];
    return parts.filter(Boolean).join(" · ");
}

function lockText(node: ChainNodeView): string | null {
    const l = node.lock;
    if (!l) return null;
    const on = [l.type, l.object].filter(Boolean).join(" on ");
    const index = l.index ? ` (${l.index})` : "";
    const held = l.held ? `Holds ${l.held}` : null;
    const wanted = l.wanted ? `wants ${l.wanted}` : null;
    return `${[held, wanted].filter(Boolean).join(", ") || "Lock"}: ${on}${index}`;
}

function Node({ node }: { node: ChainNodeView }) {
    const head = node.level === 1;
    const who = [node.program, node.login ? `login ${node.login}` : null, node.host ? `host ${node.host}` : null].filter(Boolean).join(" · ");
    const lock = lockText(node);
    const detail = facts(node);
    return (
        <li role="treeitem" aria-level={node.level} aria-expanded={node.children.length > 0 ? true : undefined} aria-selected={false}>
            <div className={`rca-node${head ? " head" : ""}`}>
                <div>
                    <strong>{head ? `Head blocker · session ${node.session}` : `Session ${node.session}`}</strong>
                    {detail ? <span className="rca-muted"> · {detail}</span> : null}
                </div>
                {node.module ? (
                    <div>
                        <span className="rca-muted">Module </span>
                        <code>{node.module}</code>
                    </div>
                ) : null}
                {node.statement ? (
                    <div>
                        <span className="rca-muted">Statement </span>
                        <code>{node.statement}</code>
                    </div>
                ) : node.inputBuffer ? (
                    <div>
                        <span className="rca-muted">Last call </span>
                        <code>{node.inputBuffer}</code>
                    </div>
                ) : null}
                {who ? <div className="rca-muted">{who}</div> : null}
                {lock ? <div className="rca-muted">{lock}</div> : null}
            </div>
            {node.children.length > 0 ? (
                <ul role="group">
                    {node.children.map((child) => (
                        <Node key={child.session} node={child} />
                    ))}
                </ul>
            ) : null}
        </li>
    );
}

export function ChainTree({ root, label }: { root: ChainNodeView; label: string }) {
    return (
        <ul className="rca-tree" role="tree" aria-label={label}>
            <Node node={root} />
        </ul>
    );
}
