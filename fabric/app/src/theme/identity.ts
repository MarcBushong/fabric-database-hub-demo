// The Insights app's own identity (ADR 0030): ContosoCare's palette, so the app never reads as Database Hub on a shared
// screen. Swap the look here and in stage.ts: APP_BRAND is the Fluent brand ramp (buttons, links, focus); stage.ts holds
// the surfaces and accents that Mission Control, the scoreboard, the replay, and the kiosk draw on.

import type { BrandVariants } from "@fluentui/react-components";

/** ContosoCare: deep navy through azure to cyan. Brand 80 (light) and 110 (dark) are the link colors. */
export const CONTOSOCARE_BRAND: BrandVariants = {
    10: "#02060F",
    20: "#071230",
    30: "#0A1B45",
    40: "#0D2459",
    50: "#102E6E",
    60: "#133883",
    70: "#164398",
    80: "#1A4FAE",
    90: "#2361C2",
    100: "#2F76D3",
    110: "#45A3EA",
    120: "#5DBDF0",
    130: "#7FD3F5",
    140: "#A6E3F8",
    150: "#CBF0FB",
    160: "#E9F9FE",
};

/** The ramp the app's Fluent themes use. Fabric's teal (FABRIC_BRAND in fluent.ts) is the one-line swap back. */
export const APP_BRAND: BrandVariants = CONTOSOCARE_BRAND;
