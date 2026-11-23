import { describe, expect, it } from "vitest";
import { RECOMMENDATIONS } from "./catalog";

describe("the recommendation catalog", () => {
    // CPU-AUTO-CORRECT's risk said the setting "was held off on purpose in this demo beat": the RCA's own words naming
    // what the demo planned, which the chat quotes as it stands (ADR 0031, blind detection).
    it("recommends nothing that says what the demo planned or injected", () => {
        for (const r of Object.values(RECOMMENDATIONS)) expect(`${r.title} ${r.why} ${r.risk} ${r.learn.title}`, r.id).not.toMatch(/\bdemo\b|on purpose|\bbeat\b|scenario|inject|held off/i);
    });
});
