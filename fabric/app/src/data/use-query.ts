import { createContext, useCallback, useContext, useEffect, useState } from "react";

import type { QuerySpec } from "./queries";
import type { QueryClient, QueryResult } from "./query-client";

export const QueryClientContext = createContext<QueryClient | null>(null);

export interface QueryState {
    data: QueryResult | undefined;
    error: Error | undefined;
    loading: boolean;
    refetch: () => void;
}

interface Settled {
    key: string;
    n: number;
    data?: QueryResult;
    error?: Error;
}

/** Runs a catalog query (or nothing for null), from the cache when it can, and again when its DAX changes. */
export function useQuery(spec: QuerySpec | null): QueryState {
    const client = useContext(QueryClientContext);
    const key = spec ? `${spec.id}\n${spec.dax}` : "";
    const [force, setForce] = useState<{ key: string; n: number }>({ key: "", n: 0 });
    const [settled, setSettled] = useState<Settled | null>(null);
    const forced = force.key === key ? force.n : 0;
    const cached = spec && client && forced === 0 ? client.peek(spec) : undefined;

    useEffect(() => {
        if (!spec || !client || cached) return;
        let cancelled = false;
        client.run(spec, { force: forced > 0 }).then(
            (data) => {
                if (!cancelled) setSettled({ key, n: forced, data });
            },
            (error: unknown) => {
                if (!cancelled) setSettled({ key, n: forced, error: error instanceof Error ? error : new Error(String(error)) });
            },
        );
        return () => {
            cancelled = true;
        };
        // `key` stands for the spec: its ID and exact DAX text.
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [key, client, forced, cached]);

    const refetch = useCallback(() => setForce((f) => ({ key, n: (f.key === key ? f.n : 0) + 1 })), [key]);

    if (!spec) return { data: undefined, error: undefined, loading: false, refetch };
    if (cached) return { data: cached, error: undefined, loading: false, refetch };
    if (settled && settled.key === key && settled.n === forced) {
        return { data: settled.data, error: settled.error, loading: false, refetch };
    }
    // While a refresh runs, keep showing what the visual already had.
    const stale = settled && settled.key === key ? settled.data : undefined;
    return { data: stale, error: undefined, loading: true, refetch };
}
