import { Button, Tooltip } from "@fluentui/react-components";
import { Sparkle16Filled } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import type { AnomalyContext } from "@/copilot/contract";
import { useCopilot } from "@/copilot/use-copilot";
import type { ColumnSpec, QuerySpec } from "@/data/queries";
import { buildAskContext } from "@/lib/ask";

export interface AskWhyProps {
    /** The question, with the anomaly's own numbers. */
    prompt: string;
    title: string;
    visualId: string;
    anomaly: AnomalyContext;
    specs?: ReadonlyArray<QuerySpec | null | undefined>;
    rows?: ReadonlyArray<Record<string, unknown>>;
    columns?: readonly ColumnSpec[];
    label?: string;
}

/** "Ask why" on an anomaly: asks Copilot the anomaly's own question, with the rows and the DAX behind it. */
export function AskWhy({ label = "Ask why", ...props }: AskWhyProps) {
    const { view, meta, filters, provenance } = useApp();
    const copilot = useCopilot();
    return (
        <Tooltip content={props.prompt} relationship="description" withArrow>
            <Button
                size="small"
                appearance="transparent"
                className="ask-why"
                icon={<Sparkle16Filled />}
                onClick={(event) => {
                    event.stopPropagation();
                    copilot.ask(
                        buildAskContext({
                            title: props.title,
                            page: view.page,
                            visualId: props.visualId,
                            specs: props.specs,
                            rows: props.rows,
                            columns: props.columns,
                            prompt: props.prompt,
                            provenance,
                            meta,
                            filters,
                            window: view.window,
                            anomaly: props.anomaly,
                        }),
                    );
                }}
            >
                {label}
            </Button>
        </Tooltip>
    );
}
