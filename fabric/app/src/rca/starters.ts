// The investigation starters: the questions the dock offers once the history model has the RCA tables. Apart from the
// playbook, so the app's first load carries only these lines; the playbook loads with the chat.

/** The starters the dock offers once the model has the RCA tables (src/copilot/starters.ts adds them). With no time, the tools read the history's newest 90 minutes. */
export const INVESTIGATION_STARTERS: ReadonlyArray<{ label: string; prompt: string }> = [
    { label: "What caused the latest incident?", prompt: "What was the latest incident, and what caused it? Find it in the history, then give its root cause with the evidence and times, the recommendations, and the next steps." },
    { label: "Who blocked whom?", prompt: "Who blocked whom in the latest blocking, and what should we do? Show the chain with the head blocker first." },
    { label: "Why did the replica fall behind?", prompt: "When did T4's read replica last fall behind, and why? Explain the cause with its evidence and times." },
    { label: "What errors did the app hit?", prompt: "What errors did the app hit in the latest incident, by class and minute, and what should we do about them?" },
];
