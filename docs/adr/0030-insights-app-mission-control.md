# ADR 0030: The Insights app's own look, and what only it can show (Wave 1)

- **Status:** Proposed (2026-11-19). Wave 1 is built and tested in the local preview with sample data, and an independent review's 10 findings are fixed ([Validation](#validation)); the release's final tests see it in a deployed app. The coordinator kept the palette and Mission Control's dark default for this release; they and the service names are the owner's to confirm ([below](#open-for-the-owner)).
- **Date:** 2026-11-19
- **Decision source:** User-directed (2026-11-19): "Make sure the Fabric Rayfin app can do things the Database Hub standalone can't and visually different. Brainstorm some cool things to show case the power of Rayfin apps to show a WOW of that with this." The owner chose "Wave 1 now, in this release" (ideas 1 to 6 of the coordinator's brainstorm). The coordinator made the look's calls (ContosoCare's palette, Mission Control dark by default), which the owner can change.
- **Related:** [ADR 0029](0029-insights-app-dba-console.md) (the DBA console; this ADR replaces its Fabric-teal theme), [ADR 0012](0012-validation-model.md) (statuses), [ADR 0026](0026-one-run-all-session.md) (one Run all, which records the session's plan), [ADR 0028](0028-ask-copilot-in-the-insights-app.md) (Ask Copilot), [the app's README](../../fabric/app/README.md)

## Context

- **The app looked like Database Hub:** Fluent 2 cards in Fabric teal. On a shared screen, the two blurred together.
- **Its hero was "Live now" from Database Hub,** which a real deployment can't show when Database Hub refuses the app's token (R924). What only the app knows was two or three clicks deep.
- **What only the app knows:** what the demo injected and when (`Scenario Runs`, the ground truth), every session's telemetry past Database Hub's 7 days, and the Database Agent beat's documented response. Database Hub sees the symptoms; it can't know the cause the demo planted.
- **Where the plan comes from:** `NB_DatabaseHub_Control`'s Run all passes the session's plan to `NB_DatabaseHub_LiveActivity` at the session's end, which records it in `scenario_runs` last: a `session:<id>` row (profile `session`, target `all`) and one `session:<id>:<NN>` row per beat on T1 to T3 (profile `incident:<scenario>`). T4's and T5's beats aren't recorded; their own metrics show them. So the history has a session's plan only after it ends.

## Decision

Six additions, frontend and read-only only: no new Azure resource, permission, role, private route, Rayfin service, or query in the deploy-time check.

### 1. Mission Control, the home page

- **The service map:** ContosoCare, with each target as the service it serves, its health from the history, a pulse, and a count of the session's events; a node opens its target's page. **Technical** shows each target's peak signal; **Business impact** the same in ContosoCare's words.
- **The session:** the latest session's plan, or the one picked, "as recorded at its end, as of" the newest capture. It's never presented as live: **Database Hub, live** opens Database Hub, and while Manage's function sees a session running, the page says so and links Database Hub. A session the address asks for that isn't in the period shows as missing, with **Show all history** and **Show the latest session**, never as another session in its place.
- **The ribbon and the numbers:** every injected fault on its target's lane (injected, signal visible, answered, recovered), T4's and T5's measured episodes dotted, and the big numbers: faults injected, signal visible, median times to detect and recover, the Database Agent loop's before and after, and T5's throttled share.
- **Overview stays** as a page, one below it in the navigation.

### 2. "Did we catch it?": the scoreboard

For each fault in `Scenario Runs`: when its signal was visible in the telemetry, when it was answered, and when it recovered, with the times to detect (injected to visible) and recover (injected to recovered), per engine and per fault type across the newest sessions (3, and the one picked).

- **"Signal visible in telemetry,"** never "detected by Database Hub": the app can't read what Database Hub raised, and Database Hub shows telemetry 3 to 15 minutes after its sample time. The time is the first bin's sample time.
- **Measured per signal, with the analysis notebook's own rules** (`src/lib/scoreboard.ts`): the families each scenario raises (`SCENARIO_SIGNALS`), the episode levels (`EPISODE_RULES`), the CPU correlation's 1.5 times and 10 points, and its 15 minutes of telemetry lag. A bin shows the signal at its episode level, or at 1.5 times its baseline when that's higher (for CPU, at 1.5 times and 10 points above its baseline when that's lower than 80 %), for the rule's bins in a row. The baseline is the median of the target's bins within 2 hours, outside the windows of faults that raise the same signal; with fewer than 5 such bins, the level alone. Each row says how it was measured.
- **Each fault in its own bins' step:** the history mixes bin sizes (the notebook bins a window of 120 minutes or less by the minute, 720 by 5, and longer by 15: a session of about 110 minutes or more, `stop-demo.ps1 -SaveHistory`, and deploy's snapshot), so a fault's step is the median gap between the target's bins in its window (or the hour around it), and its baseline reads bins of that size only, since a wait sums over its bin.
- **Recovered:** the first of 2 bins in a row under the bound, within 30 minutes of the fault's window. When the next fault with the same signal starts first, or the telemetry ends, the row says so instead of a time. A T5 episode recovers only at the notebook's measured recovery (one whose 429s only stopped has no recovery time), and a T4 episode whose metrics break off ends there, with its recovery unknown, never "still at the capture's end".
- **A query that fails** is named on the page with **Retry**, beside what still shows; when the telemetry fails, nothing is scored, rather than every fault "not visible".
- **Answered:** the Database Agent beat's response (the run forces the last good plan; its documented times), or a reset. Other faults have no response step, and the scoreboard says so rather than inventing one.
- **T4 and T5:** their beats aren't in `Scenario Runs`, so they show as measured episodes in their own metrics (CPU and read replica lag; normalized RU and 429s), without a time to detect.
- **Not visible:** a fault whose signal didn't show is a **Warning** with why (ADR 0012); one with no telemetry for its window is a **Warning** too, unless the notebook's own check of its incident window passed (then it's visible, without times), and a scenario with no signal in the history is **Not supported**.

### 3. The business impact lens

- **One file maps targets to ContosoCare's services** (`src/lib/business.ts`): T1 Billing, T2 Front desk, T3 Scheduling, T4 Reporting and its read replica the reports' DR copy, T5 Patient events. They come from the demo's story (the baseline's front desk, billing, and scheduling workload; T3's visit lookup; T5's `patient-events`); which of T1 and T2 is billing is this file's choice.
- **Impact sits next to the measurement it comes from:** "Patient events: 35 % of requests throttled for 9 min (normalized RU peak 100 %, 429s on …)". Every number is measured; there's no user latency, revenue, or patient count, because the history doesn't measure them.

### 4. The postmortem

- **Write the postmortem** on a session (Mission Control, the scoreboard, the replay): **Download Markdown** writes a deterministic postmortem from the data alone (summary, timeline, impact, cause, response, times to detect and recover, follow-ups, how it was measured, and the queries behind it), so it works without a GitHub sign-in. **Copy** copies it.
- **Draft with Copilot** asks the viewer's own GitHub Copilot through the existing `useCopilot().ask` contract, with the same rows and queries and a structured template (`src/lib/postmortem.ts`); nothing in `src/copilot/` changes. No OneLake storage in Wave 1.

### 5. The cinematic replay

One scrubber drives the service map (its states and a shockwave on each fault), all five engines' charts, and the event ribbon (injected, signal visible, answered, recovered), with "Next: … in N min" from the plan relative to the playhead. **Link to this moment** copies the frame's address with the session and the minute in it (the app's view-in-address mechanism, ADR 0029). Inside Fabric, that address is the app's hosted URL, which opens only from the app's item (the app's README, known limitation), so the toast says so: the browser reopens the app where it was left. The address takes the moment once it holds still for a second, on a pause or a seek, never at each step of the playback or a drag: WebKit refuses more than 100 address changes in 10 seconds. A screen reader hears play, pause, and each seek, never each step.

### 6. The kiosk

A chrome-free view (`#/kiosk`) that rotates Mission Control (20 seconds), the scoreboard (20), and the replay (45, playing the session through), for a booth or NOC screen. Space pauses it (WCAG 2.2.2), the arrows change scenes, and Esc leaves for Mission Control. **Full screen** uses the Fullscreen API when the frame allows it; otherwise the kiosk says to press F11. A screen reader hears the scene and whether it's paused, never the countdown. The kiosk keeps showing its last history while a query refreshes or after one fails (the app's queries keep their last result, `useQuery`'s `stale`), and asks again every 30 seconds.

### The look: ContosoCare's own

- **One set of tokens:** the brand ramp (`src/theme/identity.ts`: deep navy with cyan and magenta accents; `APP_BRAND` is the one swap point, and Fabric's teal stays there for a one-line swap back) themes the whole app through Fluent, and the stage tokens (`src/theme/stage.ts`) color the new pages in dark, light, and high contrast.
- **Mission Control, the scoreboard, the replay, and the kiosk sit on a dark stage** until the viewer picks a theme; a picked light or high-contrast theme applies to them too.
- **Visualization first:** a full-bleed map and a time ribbon, not a card grid. **Motion with a purpose:** health pulses and an incident shockwave, both off under `prefers-reduced-motion`, which the replay honors too.
- **Accessibility stays:** the contrast tests cover the new tokens (4.5:1 for text, 3:1 for marks, on every stage surface in every theme); every map node and control is reachable by keyboard, with a label, and every fault is a row in the scoreboard's table; status always has a shape and a word (ADR 0012).
- **The bundle:** the four pages load lazily, so the main chunk stays about where it was (+3.5 KB raw, about +1 KB gzip, from the routes).

### Open for the owner

1. The palette: ContosoCare's own app-wide (kept by the coordinator for this release), only on the new pages, or Fabric's teal (`APP_BRAND`).
2. Mission Control dark by default (kept by the coordinator for this release), or following the system (`stageTheme`).
3. The service names, T1 Billing and T2 Front desk especially (`SERVICES`).

## Consequences

- **Easier:** the app opens on what only it knows, in a look that's clearly its own, with Database Hub one click away for the live view. The same numbers serve the map, the scoreboard, the replay, the postmortem, and Copilot.
- **Harder:** the scoreboard mirrors the notebook's rules (`SCENARIO_SIGNALS`, `EPISODE_RULES`), so a change there needs the same change in `scoreboard.ts`; the tests pin both sides' numbers on the app's side only.
- **Accepted:** the plan is never live, only "as of" the session's end. T4's and T5's beats have no time to detect until the notebook records them (Wave 2). The scoreboard reads only the catalog's existing queries and the incident waits' queries, so the deploy-time check (`FABRIC.APP.QUERIES`, 21 queries) is unchanged.

## Validation

- **Built and tested (2026-11-19):** `npm run verify`; unit tests that fail without each piece: the scoreboard's detect, response, and recover times, the business map and its wording, and the postmortem's Markdown (`src/lib/mission.test.ts`); the tokens' contrast and the stage's dark default (`src/lib/app.test.ts`); and the pages, the kiosk's rotation, pause, and Esc, and reduced motion (`src/pages/mission.test.tsx`).
- **Reviewed (2026-11-19):** an independent review of 75fa62d found no way for `s` or `r` to reach DAX or the page unescaped, and 10 issues, each fixed with a test that fails without its fix: a fault read at the smallest bin step in the period (High); replay playback that wrote the address at every step, which WebKit stops after 100 in 10 seconds and which took the app down (High in Safari); failed queries shown as measured results; T5 episodes whose 429s only stopped called recovered; a kiosk that blanked when its cache expired and stayed so after a failed refresh; T4 episodes that broke off called ongoing; the postmortem's "every signal showed and recovered" when some hadn't; the DR copy at **Pass** without data; countdowns announced every second; and an unknown session shown as the latest. With them, high contrast's selected and hovered navigation item (white on cyan, 1.46:1) and two layout fixes on the map.
- **Screenshots** from the sample-data preview (Mission Control in dark, light, and high contrast, the business lens, the postmortem, the scoreboard, the replay mid-scrub, and the kiosk's three scenes), with the release's handoff.
- **Pending:** the deployed app in the release's final tests, on a real session's history.

## Sources

Checked 2026-11-19.

- [Fabric Apps overview](https://learn.microsoft.com/fabric/apps/overview), [hosting](https://learn.microsoft.com/fabric/apps/hosting), [connectors](https://learn.microsoft.com/fabric/apps/connectors)
- [Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)
- [Fullscreen API](https://developer.mozilla.org/docs/Web/API/Fullscreen_API) and [`prefers-reduced-motion`](https://developer.mozilla.org/docs/Web/CSS/@media/prefers-reduced-motion) (MDN)
- [WCAG 2.2: Pause, Stop, Hide](https://www.w3.org/WAI/WCAG22/Understanding/pause-stop-hide.html) and [Contrast (Minimum)](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)
