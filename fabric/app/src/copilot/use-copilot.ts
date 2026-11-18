// The Copilot context and its hooks. The shell and the entry points use only useCopilot() and useCopilotDock();
// the chat replaces the stub behind them (CopilotProvider.tsx) without changing these signatures.

import { createContext, useContext } from "react";

import type { AskContext, CopilotAccountState, CopilotApi, CopilotDockState } from "./contract";

/** What the stub keeps: the context the last entry point attached or asked about, for the placeholder dock. */
export interface AttachedContext {
    ctx: AskContext;
    /** True when it came from ask(), false from open(ctx). */
    asked: boolean;
    at: number;
}

export interface CopilotContextValue {
    api: CopilotApi;
    dock: CopilotDockState;
    account: CopilotAccountState;
    attached: AttachedContext | null;
}

export const CopilotContext = createContext<CopilotContextValue | null>(null);

const NOOP_API: CopilotApi = { open: () => undefined, ask: () => undefined };
const NOOP_DOCK: CopilotDockState = { isOpen: false, setOpen: () => undefined };
const NO_ACCOUNT: CopilotAccountState = { status: "unavailable", detail: "Copilot chat isn't connected.", signIn: () => undefined, signOut: () => undefined };

/** The entry points' API. Outside a provider (a visual rendered alone, a test) it does nothing. */
export function useCopilot(): CopilotApi {
    return useContext(CopilotContext)?.api ?? NOOP_API;
}

/** Whether the dock is open, for the shell. */
export function useCopilotDock(): CopilotDockState {
    return useContext(CopilotContext)?.dock ?? NOOP_DOCK;
}

/** The GitHub account behind the chat, for the shell's account chip. */
export function useCopilotAccount(): CopilotAccountState {
    return useContext(CopilotContext)?.account ?? NO_ACCOUNT;
}

/** The stub's attached context, for its placeholder dock. */
export function useCopilotAttached(): AttachedContext | null {
    return useContext(CopilotContext)?.attached ?? null;
}
