// What in an Ask context would hand the chat the demo's answer key (ADR 0031): an answer-key table or a measure that reads
// one, a scenario's name, or what was injected. The tests that check every Ask is blind share it.

import { answerKeyIn } from "@/copilot/answer-key";
import type { AskContext } from "@/copilot/contract";
import { ANSWER_KEY_MEASURES } from "@/copilot/model-guide.generated";
import { namesAScenario } from "@/rca/testdata/contract";

/** What in a context would hand the chat the answer key, or null when it's blind. */
export function answerKeyInContext(ctx: AskContext): string | null {
    for (const [field, value] of Object.entries(ctx)) {
        const text = JSON.stringify(value);
        const named = answerKeyIn(text, ANSWER_KEY_MEASURES);
        if (named) return `${named} (in ${field})`;
        const scenarios = namesAScenario(text);
        if (scenarios.length > 0) return `scenario ${scenarios.join(", ")} (in ${field})`;
        if (/\binject/i.test(text)) return `what was injected (in ${field})`;
    }
    return null;
}
