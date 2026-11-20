import { afterEach, describe, expect, it, vi } from "vitest";

import { LIVE_NO_SCOPE, LIVE_REFUSED, type EstateView } from "../../rayfin/functions/src/estate-core";
import { readEstate } from "./estate";
import { forgetLiveAnswers, liveRefusedAsAWhole, noteLiveAnswer, onLiveRefusal } from "./live-refusal";

// The app's estate function, as estate.ts reaches it through the Rayfin client.
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@/lib/rayfin-client", () => ({ getRayfinClient: () => ({ functions: { estateOverview: { invoke } } }) }));

const VIEWS: readonly EstateView[] = ["inventory", "health", "security"];
const scope = { subscriptionId: "11111111-2222-3333-4444-555555555555", resourceGroups: ["rg-dbhub-demo"] };
const at = "2026-11-19T22:00:00Z";
// The function's answers (R924): refused on every route, an outage on every route, and an answer.
const refused = (view: EstateView) => ({ view, source: ["GET /auth/warnings"], scope, data: {}, errors: ["GET /auth/warnings: HTTP 401 Unauthorized"], at, unavailable: LIVE_REFUSED });
const outage = (view: EstateView) => ({ view, source: ["GET /auth/warnings"], scope, data: {}, errors: ["GET /auth/warnings: HTTP 503 Service Unavailable"], at });
const answered = (view: EstateView) => ({ view, source: ["POST /savedView/resources/list"], scope, data: { totalCount: 4 }, errors: [], at });

afterEach(() => {
    forgetLiveAnswers();
    invoke.mockReset();
});

describe("whether Database Hub refuses the app as a whole", () => {
    it("is refused only when every view is unavailable, keeps it through an outage, and lifts once any view answers", () => {
        const changes = vi.fn();
        const stop = onLiveRefusal(changes);
        noteLiveAnswer("inventory", refused("inventory"));
        noteLiveAnswer("health", refused("health"));
        // Two views of three: a partial refusal, which the dock doesn't treat as a whole one.
        expect(liveRefusedAsAWhole()).toBeNull();
        // An outage is neither a refusal nor an answer: it changes nothing.
        noteLiveAnswer("security", outage("security"));
        expect(liveRefusedAsAWhole()).toBeNull();
        noteLiveAnswer("security", refused("security"));
        expect(liveRefusedAsAWhole()).toBe(LIVE_REFUSED);
        noteLiveAnswer("health", outage("health"));
        expect(liveRefusedAsAWhole()).toBe(LIVE_REFUSED);
        expect(changes).toHaveBeenCalledTimes(1);
        noteLiveAnswer("health", answered("health"));
        expect(liveRefusedAsAWhole()).toBeNull();
        expect(changes).toHaveBeenCalledTimes(2);
        stop();
        noteLiveAnswer("health", refused("health"));
        expect(changes).toHaveBeenCalledTimes(2);
    });

    it("counts a function without a scope as a whole refusal too", () => {
        for (const view of VIEWS) noteLiveAnswer(view, { data: {}, unavailable: LIVE_NO_SCOPE });
        expect(liveRefusedAsAWhole()).toBe(LIVE_NO_SCOPE);
    });

    it("learns it from the reads the pages and the dock share (estate.ts)", async () => {
        invoke.mockImplementation(async (input: { view: EstateView }) => refused(input.view));
        for (const view of VIEWS) await readEstate(view, { force: true });
        expect(liveRefusedAsAWhole()).toBe(LIVE_REFUSED);
        invoke.mockImplementation(async (input: { view: EstateView }) => answered(input.view));
        await readEstate("inventory", { force: true });
        expect(liveRefusedAsAWhole()).toBeNull();
    });
});
