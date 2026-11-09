// Loaded with `node --import` into the pinned Rayfin CLI by overrides.test.ts, so the CLI's own browser sign-in runs with
// the @azure/msal-node that package.json overrides, offline. It stands in for Microsoft Entra ID (MSAL Node calls the
// global fetch) and for the browser (the CLI opens its sign-in page with child_process.exec), and refuses every other
// request, so nothing leaves the machine. Each step is appended to HARNESS_LOG as one JSON line. The tenant, the user,
// and every token are fakes built here at run time.
import childProcess from "node:child_process";
import { appendFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";

const log = process.env.HARNESS_LOG;
const tenant = process.env.HARNESS_TENANT;
if (!log || !tenant) {
    throw new Error("HARNESS_LOG and HARNESS_TENANT must be set.");
}
const host = "https://login.microsoftonline.com";
const user = { oid: "00000000-0000-0000-0000-0000000000a1", upn: "presenter@contoso.example", name: "Demo Presenter" };
const realFetch = globalThis.fetch;
const record = (event) => appendFileSync(log, `${JSON.stringify(event)}\n`);
const encode = (value) => Buffer.from(typeof value === "string" ? value : JSON.stringify(value)).toString("base64url");
// MSAL Node reads a token's claims but never checks a signature, so the fakes carry a placeholder one.
const fakeJwt = (claims) => [encode({ alg: "RS256", typ: "JWT", kid: "test" }), encode(claims), encode("signature")].join(".");
const json = (body) => new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
let nonce = null;
let tokenCount = 0;

function tokenResponse(grantType, clientId) {
    const now = Math.floor(Date.now() / 1000);
    // The first access token expires within MSAL's 5-minute renewal window, so the next silent request refreshes it.
    const lifetime = grantType === "authorization_code" ? 60 : 3600;
    tokenCount += 1;
    return {
        token_type: "Bearer",
        scope: "https://api.fabric.microsoft.com/.default",
        expires_in: lifetime,
        ext_expires_in: lifetime,
        access_token: fakeJwt({ aud: "https://api.fabric.microsoft.com", tid: tenant, oid: user.oid, iat: now, exp: now + lifetime }),
        refresh_token: `fake-refresh-token-${tokenCount}`,
        id_token: fakeJwt({
            aud: clientId,
            iss: `${host}/${tenant}/v2.0`,
            iat: now,
            nbf: now,
            exp: now + 3600,
            name: user.name,
            oid: user.oid,
            preferred_username: user.upn,
            sub: "fake-subject",
            tid: tenant,
            ver: "2.0",
            ...(nonce ? { nonce } : {}),
        }),
        client_info: encode({ uid: user.oid, utid: tenant }),
    };
}

globalThis.fetch = async (input, init = {}) => {
    const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
    const method = String(init.method ?? input.method ?? "GET").toUpperCase();
    if (url.origin === host && method === "GET" && url.pathname === "/common/discovery/instance") {
        record({ kind: "discovery" });
        return json({
            tenant_discovery_endpoint: `${host}/${tenant}/v2.0/.well-known/openid-configuration`,
            "api-version": "1.1",
            metadata: [{ preferred_network: "login.microsoftonline.com", preferred_cache: "login.windows.net", aliases: ["login.microsoftonline.com", "login.windows.net", "login.microsoft.com", "sts.windows.net"] }],
        });
    }
    if (url.origin === host && method === "GET" && url.pathname === `/${tenant}/v2.0/.well-known/openid-configuration`) {
        record({ kind: "metadata" });
        return json({
            issuer: `${host}/${tenant}/v2.0`,
            authorization_endpoint: `${host}/${tenant}/oauth2/v2.0/authorize`,
            token_endpoint: `${host}/${tenant}/oauth2/v2.0/token`,
            device_authorization_endpoint: `${host}/${tenant}/oauth2/v2.0/devicecode`,
            end_session_endpoint: `${host}/${tenant}/oauth2/v2.0/logout`,
            jwks_uri: `${host}/${tenant}/discovery/v2.0/keys`,
            response_modes_supported: ["query", "fragment", "form_post"],
            response_types_supported: ["code", "id_token", "code id_token", "id_token token"],
            scopes_supported: ["openid", "profile", "email", "offline_access"],
            subject_types_supported: ["pairwise"],
            id_token_signing_alg_values_supported: ["RS256"],
            cloud_instance_name: "microsoftonline.com",
        });
    }
    if (url.origin === host && method === "POST" && url.pathname === `/${tenant}/oauth2/v2.0/token`) {
        const form = new URLSearchParams(String(init.body ?? ""));
        const grantType = form.get("grant_type");
        record({
            kind: "token",
            grantType,
            code: form.get("code"),
            hasCodeVerifier: Boolean(form.get("code_verifier")),
            redirectUri: form.get("redirect_uri"),
            clientId: form.get("client_id"),
            hasRefreshToken: Boolean(form.get("refresh_token")),
        });
        return json(tokenResponse(grantType, form.get("client_id")));
    }
    record({ kind: "blocked", method, url: `${url.origin}${url.pathname}` });
    throw new TypeError(`The sign-in harness refuses ${method} ${url.origin}${url.pathname}: it allows only the fake Entra ID.`);
};

// The browser: answers the sign-in page's URL the way Entra ID does after a sign-in, with a form_post to the CLI's
// loopback address. A forged response with another request's state comes first, and MSAL Node 7.2 must refuse it.
async function browse(authorizeUrl) {
    const query = authorizeUrl.searchParams;
    nonce = query.get("nonce");
    const redirectUri = query.get("redirect_uri");
    const state = query.get("state");
    record({
        kind: "authorize",
        path: authorizeUrl.pathname,
        clientId: query.get("client_id"),
        responseMode: query.get("response_mode"),
        responseType: query.get("response_type"),
        codeChallengeMethod: query.get("code_challenge_method"),
        hasCodeChallenge: Boolean(query.get("code_challenge")),
        hasState: Boolean(state),
        prompt: query.get("prompt"),
        scopes: String(query.get("scope") ?? "").split(" ").filter(Boolean).sort(),
        redirectUri,
    });
    const post = (fields) =>
        realFetch(redirectUri, {
            method: "POST",
            headers: { "content-type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams(fields).toString(),
        });
    if (process.env.HARNESS_SKIP_FORGED !== "1") {
        const forged = await post({ code: "forged-authorization-code", state: `${state}-other-request`, client_info: encode({ uid: "attacker", utid: tenant }) });
        record({ kind: "forged-response", status: forged.status, body: await forged.text() });
    }
    const answer = await post({ code: "fake-authorization-code", state, client_info: encode({ uid: user.oid, utid: tenant }), session_state: "fake-session" });
    record({ kind: "response", status: answer.status, body: await answer.text() });
}

const realExec = childProcess.exec;
childProcess.exec = (command, ...rest) => {
    const match = /"(https:\/\/login\.microsoftonline\.com\/[^"]+)"/.exec(String(command));
    if (!match) {
        return realExec.call(childProcess, command, ...rest);
    }
    browse(new URL(match[1])).catch((error) => record({ kind: "browser-error", message: String(error) }));
    return { on: () => undefined, once: () => undefined, unref: () => undefined };
};
syncBuiltinESMExports();
