//-----------------------------------------------------------------------
// <copyright company="Microsoft Corporation">
//        Copyright (c) Microsoft Corporation.  All rights reserved.
//        Licensed under the MIT license. See LICENSE file in the project root for full license information.
// </copyright>
//-----------------------------------------------------------------------

import "@testing-library/jest-dom";
import { configure } from "@testing-library/react";
import { beforeEach } from "vitest";

// A page test waits for its queries and charts. On a busy machine (several runs at once, a shared CI runner, 97 to 100 %
// CPU), a page's first render with data comes 1 to 2 seconds after render(), measured on Overview, and Testing Library's
// default wait of 1 second then fails a correct test. 4 seconds stays well inside Vitest's 15-second test timeout; a
// test can still pass its own.
configure({ asyncUtilTimeout: 4000 });

// jsdom has no ResizeObserver; Fluent's MessageBar and the charts observe their size.
class ResizeObserverStub {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
}
if (typeof globalThis.ResizeObserver === "undefined") {
    globalThis.ResizeObserver = ResizeObserverStub as unknown as typeof ResizeObserver;
}

// Node 25 and later have Web Storage globals of their own, and localStorage is undefined without --localstorage-file
// (config/versions.json pins Node 26). Vitest's jsdom environment keeps a global that exists, so use jsdom's instead.
const dom = (globalThis as { jsdom?: { window: Window } }).jsdom;
for (const key of ["localStorage", "sessionStorage"] as const) {
    if (dom && !globalThis[key]) Object.defineProperty(globalThis, key, { value: dom.window[key], configurable: true, writable: true });
}

// Every test starts with empty Web Storage, so none depends on what an earlier test in its file left there: the view,
// the theme, the live view's remembered state (R924), or a GitHub session. A file's own storage stub still takes over.
beforeEach(() => {
    for (const key of ["localStorage", "sessionStorage"] as const) {
        try {
            globalThis[key]?.clear();
        } catch {
            // A stub without clear() (a test's own) starts as that test made it.
        }
    }
});
