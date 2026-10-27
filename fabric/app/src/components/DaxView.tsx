import { Fragment } from "react";

import { tokenizeDax } from "@/lib/dax";

export function DaxView({ dax, label }: { dax: string; label: string }) {
    return (
        <pre className="dax" tabIndex={0} aria-label={label}>
            <code>
                {tokenizeDax(dax).map((token, i) =>
                    token.kind === "p" ? (
                        <Fragment key={i}>{token.text}</Fragment>
                    ) : (
                        <span key={i} className={token.kind}>
                            {token.text}
                        </span>
                    ),
                )}
            </code>
        </pre>
    );
}
