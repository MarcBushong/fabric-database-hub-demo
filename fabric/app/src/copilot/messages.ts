// Plain-language text for what a viewer can run into: no Copilot on the account, an organization that blocks the
// app, an expired sign-in, a relay that's starting from zero, and the Copilot plan's display name.

import { RelayError } from "./relay";

/** The Copilot runtime's plan key as GitHub names the plan: "enterprise" is "Copilot Enterprise". */
export function planLabel(plan: string | null | undefined): string | null {
    const p = (plan ?? "").toLowerCase();
    if (!p) return null;
    if (p.includes("enterprise")) return "Copilot Enterprise";
    if (p.includes("business")) return "Copilot Business";
    if (p.includes("pro_plus") || p.includes("proplus") || p.includes("pro+")) return "Copilot Pro+";
    if (p.includes("pro")) return "Copilot Pro";
    if (p.includes("free")) return "Copilot Free";
    if (p.includes("individual")) return "Copilot Individual";
    return `Copilot (${plan})`;
}

/**
 * The Azure region the chat relay runs in, from its Container Apps address (`<app>.<env>.<region>.azurecontainerapps.io`).
 * GitHub's device page shows where the sign-in request came from, which is the relay's region, not the viewer's.
 */
export function relayRegion(relayUrl: string | null | undefined): string | null {
    try {
        const host = new URL(relayUrl ?? "").hostname.toLowerCase();
        const match = /\.([a-z0-9]+)\.azurecontainerapps\.io$/.exec(host);
        return match ? match[1] : null;
    } catch {
        return null;
    }
}

export function describeAskError(err: unknown): string {
    const message = err instanceof Error ? err.message : String(err);
    if (err instanceof RelayError) {
        if (err.code === "unreachable") return "The chat relay is starting (it scales to zero when nobody asks). Try again in a few seconds.";
        if (err.code === "signin") return "Sign in with GitHub first.";
        if (err.code === "rate_limited") return "Too many requests from this browser in a minute. Wait a moment and ask again.";
    }
    if (/organization|org .*(approv|restrict)|third-party|oauth app access|SAML/i.test(message)) {
        return `${message} An owner of the GitHub organization that gives you Copilot can approve the app "Database Hub Insights Ask" (Organization settings, Third-party access, OAuth app policy), or authorize it for SAML single sign-on.`;
    }
    return message;
}
