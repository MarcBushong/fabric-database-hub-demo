// The stub provider: it opens the dock and remembers what an entry point attached or asked about, so the shell and the
// entry points work end to end before the chat lands. The chat replaces this file and keeps useCopilot() and
// useCopilotDock() (use-copilot.ts) as they are.

import { useCallback, useMemo, useState, type ReactNode } from "react";

import type { AskContext, CopilotAccountState, CopilotApi, CopilotDockState } from "./contract";
import { CopilotContext, type AttachedContext, type CopilotContextValue } from "./use-copilot";

export function CopilotProvider({ children, initialOpen = false }: { children: ReactNode; initialOpen?: boolean }) {
    const [isOpen, setIsOpen] = useState(initialOpen);
    const [attached, setAttached] = useState<AttachedContext | null>(null);

    const open = useCallback((ctx?: AskContext) => {
        if (ctx) setAttached({ ctx, asked: false, at: Date.now() });
        setIsOpen(true);
    }, []);
    const ask = useCallback((ctx: AskContext) => {
        setAttached({ ctx, asked: true, at: Date.now() });
        setIsOpen(true);
    }, []);
    const setOpen = useCallback((value: boolean) => setIsOpen(value), []);

    const api = useMemo<CopilotApi>(() => ({ open, ask }), [open, ask]);
    const dock = useMemo<CopilotDockState>(() => ({ isOpen, setOpen }), [isOpen, setOpen]);
    // The stub has no GitHub sign-in; the chip says so, and selecting it opens the dock.
    const account = useMemo<CopilotAccountState>(
        () => ({ status: "unavailable", detail: "Copilot chat isn't connected in this build.", signIn: () => setIsOpen(true), signOut: () => undefined }),
        [],
    );
    const value = useMemo<CopilotContextValue>(() => ({ api, dock, account, attached }), [api, dock, account, attached]);

    return <CopilotContext.Provider value={value}>{children}</CopilotContext.Provider>;
}
