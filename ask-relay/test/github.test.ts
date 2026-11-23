import { describe, expect, it } from "vitest";

import { safeVerificationUri, startDeviceFlow, VERIFICATION_URI } from "../src/github.js";

// GitHub's device flow answers with the page where the user enters the code. The app links only
// https://github.com/login/device; the relay passes on GitHub's verification_uri only when it's exactly that page, and
// otherwise that page (defense in depth, 2026-11-21).
function deviceAnswer(verificationUri: unknown) {
    return async () => new Response(JSON.stringify({ device_code: "dc", user_code: "ABCD-1234", verification_uri: verificationUri, expires_in: 900, interval: 5 }), { status: 200 });
}

describe("startDeviceFlow's verification page", () => {
    it("passes on GitHub's own device page", async () => {
        const start = await startDeviceFlow(deviceAnswer("https://github.com/login/device"), "Iv1.0123456789abcdef", "");
        expect(start.verificationUri).toBe("https://github.com/login/device");
        expect(VERIFICATION_URI).toBe("https://github.com/login/device");
    });

    it.each([
        ["plain http", "http://github.com/login/device"],
        ["another host", "https://evil.example/login/device"],
        ["a look-alike host", "https://github.com.evil.example/login/device"],
        ["a subdomain", "https://gist.github.com/login/device"],
        ["credentials in the address", "https://user:secret@github.com/login/device"],
        ["another port", "https://github.com:8443/login/device"],
        ["another page on github.com", "https://github.com/someone/phishing"],
        ["a query", "https://github.com/login/device?next=https://evil.example"],
        ["a fragment", "https://github.com/login/device#elsewhere"],
        ["a script", "javascript:alert(1)"],
        ["a data address", "data:text/html,hello"],
        ["no address at all", "not a url"],
        ["an empty string", ""],
    ])("answers the device page itself for %s", async (_case, value) => {
        const start = await startDeviceFlow(deviceAnswer(value), "Iv1.0123456789abcdef", "");
        expect(start.verificationUri).toBe(VERIFICATION_URI);
        expect(start.userCode).toBe("ABCD-1234");
    });

    it("normalizes the address it passes on", () => {
        expect(safeVerificationUri("https://GitHub.com/login/device")).toBe(VERIFICATION_URI);
        expect(safeVerificationUri("https://github.com:443/login/device")).toBe(VERIFICATION_URI);
    });

    it("still refuses an answer without a verification page", async () => {
        await expect(startDeviceFlow(deviceAnswer(42), "Iv1.0123456789abcdef", "")).rejects.toThrow("GitHub's answer had no device code.");
    });
});
