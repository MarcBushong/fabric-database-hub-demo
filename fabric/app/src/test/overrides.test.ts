// @vitest-environment node
// package.json overrides two packages that the pinned Rayfin packages bring in, for security advisories, with releases
// outside the ranges those packages declare, so this file runs Rayfin's own code with each override:
// - zod (GHSA-mrhx-c7xc-m3w5; @microsoft/rayfin-tools-common 1.36.2 wants ~4.3.6): the template manifest validation
//   behind `rayfin init`, the only place Rayfin uses zod (the app's browser bundle has none). The expected results are
//   what the same calls returned with zod 4.3.6, but for the one difference noted below (Phase 27).
// - @azure/msal-node (GHSA-xcx6-jx8p-x3h5; @microsoft/rayfin-cli 1.36.2 wants ^5.5.0): the CLI's browser sign-in,
//   `rayfin login`, then `rayfin login status`, run as processes against rayfin-sign-in-harness.mjs, which stands in for
//   Microsoft Entra ID and the browser, offline (2026-11-09).
// Remove a test with its override once a Rayfin release depends on a fixed version.
import { parseManifestFromString, validateManifest } from "@microsoft/rayfin-tools-common/_internal/templates";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { afterAll, describe, expect, it } from "vitest";

describe("the zod override with the pinned Rayfin packages", () => {
    it("accepts valid template manifests, groups included", () => {
        const manifest = {
            apiVersion: "v1",
            metadata: { name: "dbhub", tags: ["demo"] },
            entries: [
                { name: "dataapp", path: "dataapp" },
                { group: { name: "more", displayName: "More", entries: [{ path: "templates/other" }] } },
            ],
        };
        expect(validateManifest(manifest)).toEqual([]);
        expect(parseManifestFromString("apiVersion: v1\nmetadata:\n  name: dbhub\nentries:\n  - path: dataapp\n")).toEqual({
            apiVersion: "v1",
            metadata: { name: "dbhub" },
            entries: [{ path: "dataapp" }],
        });
    });

    it("rejects invalid manifests with Rayfin's messages, at the same paths as with zod 4.3.6", () => {
        const errors = validateManifest({
            apiVersion: "v2",
            metadata: { name: "" },
            entries: [{ path: "../outside" }, { path: "dataapp", group: { name: "g" } }],
        });
        expect(errors.slice(0, 3)).toEqual([
            "apiVersion: apiVersion must be 'v1'",
            "metadata.name: metadata.name is required",
            "entries.0.path: path must be a relative path without '..' segments",
        ]);
        // The one difference from zod 4.3.6, which reported "entries.1: Invalid input" here: zod 4.6.7 names the issue of
        // the union branch that comes closest. The entry is rejected either way.
        expect(errors.slice(3)).toEqual(['entries.1: Unrecognized key: "group"']);
        expect(
            validateManifest({ apiVersion: "v1", metadata: { name: "x" }, entries: [{ path: "a", group: { name: "g", displayName: "G", entries: [{ path: "b" }] } }] }),
        ).toEqual(["entries.0: Invalid input"]);
        expect(validateManifest({ apiVersion: "v1", metadata: { name: "x" }, entries: [{ path: "C:\\temp" }] })).toEqual([
            "entries.0.path: path must be a relative path without '..' segments",
        ]);
        expect(
            validateManifest({ apiVersion: "v1", metadata: { name: "x" }, entries: [{ group: { name: "g", displayName: "G", entries: [] } }] }),
        ).toEqual(["entries.0.group.entries: group.entries must not be empty"]);
        expect(validateManifest({ apiVersion: "v1", metadata: { name: "x" }, entries: [] })).toEqual([
            "entries: entries must contain at least one entry",
        ]);
        expect(validateManifest({ apiVersion: "v1", metadata: { name: 5, tags: "t" }, entries: "nope" })).toEqual([
            "metadata.name: Invalid input: expected string, received number",
            "metadata.tags: Invalid input: expected array, received string",
            "entries: Invalid input: expected array, received string",
        ]);
    });

    it("runs Rayfin's checks after zod's, and throws for an invalid manifest", () => {
        expect(validateManifest({ apiVersion: "v1", metadata: { name: "x" }, entries: [{ path: "a" }, { path: "a" }, { name: "a", path: "b" }] })).toEqual([
            "entries[1].path 'a' is a duplicate",
            "entries[2].name 'a' collides with an entry path",
        ]);
        expect(() => parseManifestFromString("apiVersion: v1\nmetadata: {}\nentries: []\n")).toThrow(
            "Invalid template manifest:\n  - metadata.name: Invalid input: expected string, received undefined\n  - entries: entries must contain at least one entry",
        );
    });
});

type HarnessEvent = Record<string, unknown> & { kind: string };
type CliRun = { code: number | null; stdout: string; stderr: string };

describe("the @azure/msal-node override with the pinned Rayfin CLI", () => {
    const appRoot = resolve(import.meta.dirname, "../..");
    const cliRoot = join(appRoot, "node_modules/@microsoft/rayfin-cli");
    const cliMain = join(cliRoot, (JSON.parse(readFileSync(join(cliRoot, "package.json"), "utf8")) as { bin: { rayfin: string } }).bin.rayfin);
    const harness = pathToFileURL(join(import.meta.dirname, "rayfin-sign-in-harness.mjs")).href;
    const tenant = "11111111-2222-3333-4444-555555555555";
    // The CLI's own public client ID, read from its code, so this file holds no real ID (ADR 0021).
    const clientId = /DEFAULT_RAYFIN_CLIENT_ID = '([0-9a-f-]{36})'/.exec(readFileSync(join(cliRoot, "dist/auth/constants.js"), "utf8"))?.[1];
    const work = mkdtempSync(join(tmpdir(), "rayfin-sign-in-"));
    const log = join(work, "harness.jsonl");
    const env: NodeJS.ProcessEnv = {};
    for (const [name, value] of Object.entries(process.env)) {
        if (!/^(RAYFIN_|BROWSER$|NODE_OPTIONS$)/.test(name)) {
            env[name] = value;
        }
    }
    Object.assign(env, {
        // The CLI's token cache and state go to this test's folder, never the person's ~/.rayfin.
        RAYFIN_CONFIG_DIR: join(work, "config"),
        RAYFIN_TELEMETRY_OPTOUT: "1",
        RAYFIN_ENCRYPTION_FALLBACK_ENABLED: "true",
        NO_COLOR: "1",
        HARNESS_LOG: log,
        HARNESS_TENANT: tenant,
    });
    if (process.platform !== "win32") {
        // CI has no keyring, so the CLI's container path keeps the fake tokens in a plaintext file here; Windows uses DPAPI.
        env.DEVCONTAINER = "1";
    }

    const rayfin = (args: string[]): Promise<CliRun> =>
        new Promise((done, fail) => {
            const child = spawn(process.execPath, ["--import", harness, cliMain, ...args], { cwd: work, env, stdio: ["ignore", "pipe", "pipe"] });
            let stdout = "";
            let stderr = "";
            child.stdout.on("data", (chunk: Buffer) => (stdout += chunk.toString()));
            child.stderr.on("data", (chunk: Buffer) => (stderr += chunk.toString()));
            const timer = setTimeout(() => {
                child.kill();
                fail(new Error(`rayfin ${args.join(" ")} didn't finish within 150 seconds: ${stderr}`));
            }, 150_000);
            child.on("error", fail);
            child.on("close", (code) => {
                clearTimeout(timer);
                done({ code, stdout, stderr });
            });
        });
    const events = (): HarnessEvent[] =>
        readFileSync(log, "utf8")
            .split("\n")
            .filter((line) => line.trim())
            .map((line) => JSON.parse(line) as HarnessEvent);
    const tokenRequests = () => events().filter((event) => event.kind === "token");
    const statusOf = (run: CliRun) => JSON.parse(run.stdout.trim().split("\n").pop() ?? "{}") as Record<string, unknown>;

    afterAll(() => rmSync(work, { recursive: true, force: true }));

    it("is the version package.json overrides", () => {
        const overrides = (JSON.parse(readFileSync(join(appRoot, "package.json"), "utf8")) as { overrides: Record<string, string> }).overrides;
        const installed = (JSON.parse(readFileSync(join(appRoot, "node_modules/@azure/msal-node/package.json"), "utf8")) as { version: string }).version;
        expect(installed).toBe(overrides["@azure/msal-node"]);
    });

    it("signs in through the browser with PKCE and form_post, refuses a response with another request's state, and redeems only the code", async () => {
        expect(clientId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
        const login = await rayfin(["login", "--tenant", tenant]);
        expect(login.code, login.stderr).toBe(0);
        // With its output piped, the CLI writes its messages to stderr (plain mode).
        expect(login.stdout + login.stderr).toContain("Signed in successfully");
        expect(login.stdout + login.stderr).toContain("presenter@contoso.example");
        const seen = events();
        const authorize = seen.find((event) => event.kind === "authorize");
        expect(authorize).toMatchObject({
            path: `/${tenant}/oauth2/v2.0/authorize`,
            clientId,
            responseMode: "form_post",
            responseType: "code",
            codeChallengeMethod: "S256",
            hasCodeChallenge: true,
            hasState: true,
            prompt: "select_account",
            scopes: ["https://api.fabric.microsoft.com/.default", "offline_access", "openid", "profile"],
        });
        expect(String(authorize?.redirectUri)).toMatch(/^http:\/\/localhost:\d+$/);
        // MSAL Node 5.6.0, the CLI's declared range, took this response and redeemed its code; 7.2 binds the response to
        // its request's state.
        expect(seen.find((event) => event.kind === "forged-response")).toMatchObject({ status: 400, body: "Invalid authorization response state." });
        expect(tokenRequests()).toEqual([
            {
                kind: "token",
                grantType: "authorization_code",
                code: "fake-authorization-code",
                hasCodeVerifier: true,
                redirectUri: authorize?.redirectUri,
                clientId,
                hasRefreshToken: false,
            },
        ]);
        const page = seen.find((event) => event.kind === "response");
        expect(page).toMatchObject({ status: 200 });
        expect(String(page?.body)).toContain("Authentication successful");
        expect(seen.filter((event) => event.kind === "blocked" || event.kind === "browser-error")).toEqual([]);
    }, 300_000);

    it("reads the sign-in from the CLI's token cache, renews a token about to expire, and keeps the renewed one", async () => {
        const first = await rayfin(["login", "status", "--json"]);
        expect(first.code, first.stderr).toBe(0);
        expect(statusOf(first)).toMatchObject({ status: "ok", command: "login status", identityType: "user", tenant });
        expect(tokenRequests().slice(1)).toEqual([
            { kind: "token", grantType: "refresh_token", code: null, hasCodeVerifier: false, redirectUri: null, clientId, hasRefreshToken: true },
        ]);
        const second = await rayfin(["login", "status", "--json"]);
        expect(second.code, second.stderr).toBe(0);
        expect(statusOf(second)).toMatchObject({ status: "ok", tenant });
        expect(tokenRequests()).toHaveLength(2);
        expect(events().filter((event) => event.kind === "blocked")).toEqual([]);
    }, 300_000);
});
