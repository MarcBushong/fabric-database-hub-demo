//-----------------------------------------------------------------------
// <copyright company="Microsoft Corporation">
//        Copyright (c) Microsoft Corporation.  All rights reserved.
//        Licensed under the MIT license. See LICENSE file in the project root for full license information.
// </copyright>
//-----------------------------------------------------------------------

import "@testing-library/jest-dom";

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
