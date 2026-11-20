// The chat's state and actions as the dock sees them (CopilotProvider.tsx implements them).

import type { AskContext } from "./contract";
import type { AskSettings, Turn } from "./conversation";
import type { GitHubSession } from "./github-session";
import type { GitHubUser } from "./relay";

/** The relay: not deployed, not asked yet, waking from zero, ready, or unreachable (with the reason). */
export type RelayStatus = "off" | "unknown" | "waking" | "ready" | "unreachable";

/** How the relay signs viewers in: GitHub's device flow, or not set up (no GitHub app's client ID). */
export type SignInMode = "device" | "off" | null;

export interface DeviceState {
    userCode: string;
    verificationUri: string;
    expiresAt: number;
    /** False when the browser refused the clipboard: the dock asks the viewer to copy the code. */
    copied: boolean;
    /** False when the browser (or the frame the app runs in) blocked the new tab: the dock shows where to go. */
    opened: boolean;
}

/** What GitHub Copilot says about the signed-in account, from the relay's check. */
export interface CopilotPlan {
    /** "Copilot Enterprise", "Copilot Business", "Copilot Pro", ... */
    label: string | null;
    /** null when it isn't known yet; false when the account can't use Copilot here (with the reason). */
    ok: boolean | null;
    detail?: string;
}

export interface ChatState {
    settings: AskSettings | null;
    relayStatus: RelayStatus;
    relayError: string | null;
    signIn: SignInMode;
    session: GitHubSession | null;
    user: GitHubUser | null;
    plan: CopilotPlan;
    device: DeviceState | null;
    authError: string | null;
    turns: Turn[];
    busy: boolean;
    connecting: boolean;
    /** The context an entry point attached with open(ctx), waiting for a question. */
    pending: AskContext | null;
    /** True once the history model is known to hold T5's (Azure Cosmos DB) metrics: the dock offers T5's starter. */
    cosmosHistory: boolean;
}

export interface ChatController {
    state: ChatState;
    send(text: string, ctx?: AskContext | null): void;
    /** For the last turn when it ended without an answer: asks the same conversation to write it (R925). */
    retry(): void;
    stop(): void;
    newChat(): void;
    signInWithGitHub(): void;
    cancelSignIn(): void;
    signOut(): void;
    clearPending(): void;
    exportMarkdown(): string;
    warmUp(): void;
}
