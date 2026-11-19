# Demo walkthrough

Presenter scripts for the Fabric Database Hub hybrid SQL demo: the presenter's path with one **Run all**, the DBA moments it carries, a 15-minute and a 30-minute script, what to do before and after a session, a documented fallback for every agent beat, a cheat sheet for each incident scenario, and a recovery playbook. How the demo is built is in the [architecture](architecture.md); what's automated and what isn't is in the [automation support matrix](automation-support-matrix.md); which surface suits which audience, and what each viewer needs, is in [presentation surfaces](presentation.md).

> **Preview disclosure:** Database Hub is generally available (2026-11-17): its estate, performance, security, and optimization views, its real-time dashboards for SQL, PostgreSQL, and Cosmos DB, its SSMS and VS Code entry points, bulk monitoring enablement, and its CLI skill ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)). Copilot in Database Hub, Database Agents, alerts, and SQL Server on Azure VM monitoring are previews, as are unified inventory, the Arc SQL monitoring setting, the telemetry endpoint, and Fabric Apps, which the Insights app is built on ([what's generally available, and what's a preview](limitations.md#preview-disclosures)). Their behavior, coverage, and UI can change. This script never promises what an AI will answer: it names the signals to look for, and every beat that depends on a preview has a fallback.

## The presenter's path

One **Run all** in the control notebook runs a whole session, and both scripts below run inside one.

**Once per deployment:**

1. **Deploy:** `./scripts/deploy.ps1`, until it ends **DONE** ([demo it yourself](../README.md#demo-it-yourself)).
2. **Optional, about 30 seconds:** select T3 in Database Hub's **Manage agents** for [the Database Agent loop](#the-database-agent-loop-on-t3). Everything else runs without it.
3. **For Ask, the Copilot chat in the Insights app:** each viewer signs in with GitHub once per browser, on their own GitHub Copilot plan ([the Copilot chat](../README.md#the-copilot-chat-in-the-insights-app)).

**Each session:**

1. **Resume your Fabric capacity** if it's paused: in the Azure portal, open the capacity and select **Resume** ([pause and resume](https://learn.microsoft.com/fabric/enterprise/pause-resume)). It runs the notebook, and Run all never resumes it (`fabric.manageCapacity` lets `start-demo.ps1` and `stop-demo.ps1` do it for a capacity that's yours alone). It bills while it runs, outside every estimate, so pause it after. Don't resume it on stage: it takes minutes.
2. **Run all, about 30 minutes before your audience:** open `NB_DatabaseHub_Control` where **DONE** says, and select **Run all**, with nothing to edit. It starts the VMs, T4, T4's read replica, and T5's container, runs the 90-minute showcase of bounded incidents on all five targets, and prints a presenter's guide: each beat's time in your clock, and Copilot prompts with this session's names and times. The first data reaches Database Hub 10 to 35 minutes after Run all ([what fills each visual, and when](database-hub-visuals.md#what-fills-each-database-hub-visual-and-when)).
3. **Show the DBA moments, in order:** [Open at Overview](#open-at-overview), [T2 ready to migrate](#optimization-t2-ready-to-migrate), [the Database Agent loop on T3](#the-database-agent-loop-on-t3), and [T5's RU storm](#t5-azure-cosmos-dbs-ru-storm). Or follow [the 15-minute script](#the-15-minute-script) or [the 30-minute script](#the-30-minute-script).
4. **The end:** Run all stops everything, and saves the session's history once its telemetry has arrived, about 15 minutes after the session's end. Then [show the Insights app](#demo-it-yourself-the-insights-app), and pause your capacity when nothing else needs it.

**The session's clock,** in minutes after a target's activity starts: T1, T3, and T5 start at about the same time, T2 and T4 a few minutes later. The guide prints the exact times.

| Minutes | What runs |
|---|---|
| 0 to 10, then every 30 | T1's blocking chain |
| 3 to 13 and 18 to 26, then every 30 | T5's RU storms: normalized RU at 100%, with throttled requests (429s) |
| 13 to 23, and 73 to 83 | T3's locking and blocking |
| 33 | T3's plan regresses: the Database Agent loop starts |
| About 48 | Database Agents raises its issue on T3 |
| About 55 | "Now: T3 Respond": Run all forces the last good plan; T3's CPU falls a few minutes later |
| 50 to 59, on T4's clock | T4's read replica falls behind ([read replica lag](#read-replica-lag-t4)) |
| 90 | The session ends, and Run all stops everything |

To show the Database Agent loop live, start Run all about 50 to 60 minutes before your slot instead, or show the loop afterward, on the Insights app's **Incidents** page.

**The switches,** in the notebook's first cell, only when you need one ([the switches](../fabric/control/README.md#the-switches)):

- **Length:** `DURATION_MINUTES`, 90 by default (30 to 120). The Database Agent loop needs 60 or more.
- **Rehearse:** `MODE = "check"` shows the plan and the checks, and sends nothing.
- **End early:** `STOP_NOW = True`, then Run all. The session's history is still saved.
- **Reset:** `RESET_NOW = True`, then Run all. It resets the targets whose VM runs.

**During a Run all session, don't run `./scripts/demo-control.ps1` on a target:** it replaces that target's showcase, and on T3 it ends the Database Agent loop. The scripts below take their incidents from the session's own beats.

**Without the session control's roles,** Run all can't start a session, until an Owner runs `./scripts/grant-safety-stop.ps1` once. Meanwhile, run the session from a PC: `./scripts/start-demo.ps1`, then `./scripts/stop-demo.ps1 -SaveHistory` ([before the session](#before-the-session)).

## How to use this script

- **Two versions,** both inside a Run all session ([the presenter's path](#the-presenters-path)): [the 15-minute script](#the-15-minute-script) tells the story in four beats. [The 30-minute script](#the-30-minute-script) adds security and posture, an incident you watch start, a monitor from Database Hub's template next to the dashboard as code, Copilot's summary, and the notebooks. Both share the [preparation](#before-the-session) and the [cleanup](#after-the-session).
- **Every step has** these nine fields, in both scripts; `tests/unit/Docs.Walkthrough.Tests.ps1` checks them:
  1. **Time:** the range in the step's heading, such as `(0:00–3:00)`.
  2. **Presenter action:** `Show:` or `Do:`.
  3. **Narration:** `Say:`.
  4. **Expected visual:** `Look for:`, what's on screen.
  5. **Expected signal:** `Look for:`, the Hub or telemetry signal by name, where there is one.
  6. **Preview fallback:** `If it isn't there:`.
  7. **Reset instruction:** `Reset:`, the exact command, or "Nothing to reset".
  8. **Screenshot placeholder:** `Screenshot:`, the planned image path to capture in rehearsal.
  9. **Why the customer should care:** `Why it matters:`, tied to one of the value themes: faster detection, less tool switching, a consistent hybrid inventory, shared context, a guided investigation, and human-controlled action.
- **Markers:**
  - *Verify in rehearsal:* Microsoft Learn doesn't document it. Check it in your tenant before an audience sees it.
  - **Evaluation only:** the T2 fallback that runs the Arc agent on an Azure VM. Say it every time that fallback is on screen.
- **Statuses** follow the repo's model ([ADR 0012](adr/0012-validation-model.md)): **Pass**, **Fail**, **Warning**, **Manual action required**, **Not supported**, and **Not selected**. A deployment that succeeded is never a **Pass** on its own.
- **No prices:** cost figures come from `scripts/estimate-cost.ps1` on the day; [cost management](cost-management.md#at-a-glance) has dated examples.
- **No real IDs:** commands use placeholders such as `<tenantId>`. Don't put subscription, tenant, or object IDs on a shared screen.

## The DBA moments in a Run all session

**Run all** in `NB_DatabaseHub_Control` carries four moments a DBA audience remembers. They need nothing beyond the session itself (the Database Agent loop also needs T3's optional one-time selection, below), and the guide the notebook prints gives each one's time in the demo's clock.

### Open at Overview

1. **Show:** [Database Hub](https://app.fabric.microsoft.com/workloads/fdh/databaseHub) on **Overview**: **What needs attention**, then **Recent signal changes**. Say: "One place for the whole estate: what needs attention now, and what changed."
2. **Ask Copilot** the three starting questions in [overview.in-hub](../fabric/agent/prompts/overview.in-hub.md): "What changed in my databases?", "Which resource should I investigate next?", and "Which security findings should I address first?". Copilot is a preview and runs on the workspace's Fabric capacity; Database Hub's own pages need no capacity.
3. **If it isn't there:** read the two Overview cards aloud and open the first resource; Copilot answers from the same signals.

### Optimization: T2 ready to migrate

Database Hub's general availability adds **Optimization** insights: resources whose migration assessment is ready, license-model opportunities such as pay-as-you-go, and SQL Server instances that don't report usage ([announcement](https://techcommunity.microsoft.com/blog/azuresqlblog/database-hub-in-microsoft-fabric-is-generally-available-your-entire-database-est/4574212)). License and usage findings are issues: Overview's **Optimization** card in **What needs attention** counts them, and **Estate** shows them on the resource's row. A ready migration assessment isn't an issue, so T2 doesn't add to that count.

1. **Show:** Overview's **Optimization** card (scroll down), or **Estate** with **View: Microsoft SQL** and the demo resource group selected; then select T2 (`arcsql01`). Database Hub's data for T2 has its migration assessment: on 2026-11-18, **Ready** for Azure SQL Managed Instance and SQL Server on Azure Virtual Machines, and **Not ready** for Azure SQL Database. Where Database Hub's pages show that readiness isn't documented, so rehearse this step once in your tenant.
2. **Do:** open T2's migration assessment: its readiness for each Azure target and the recommended target with its size and monthly cost. The Azure portal always has it: open the SQL Server - Azure Arc resource `arcsql01`, then **Migration**, **Assessments**, and the **Recommended Target** banner ([migration assessment](https://learn.microsoft.com/sql/sql-server/azure-arc/migration-assessment)).
3. **Say:** "This server is on-premises, connected through Azure Arc. Azure has already assessed it for migration, at no charge, and says where it's ready to go and at what size. Nothing extra was installed for that: the Azure extension for SQL Server runs the assessment every week."
4. **Say, about licenses:** "T1 and T2 show no license-model finding, because they already use pay-as-you-go: Arc bills T2's SQL Server by the hour, and T1's Azure Marketplace image includes its license." Database Hub's data agrees: neither has a pay-as-you-go license finding (checked 2026-11-18). Other SQL Servers in your tenant can have one, such as an Arc Jumpstart ArcBox server.
5. **How it gets there:** `deploy.ps1`, in every run, and `configure-arc.ps1` turn T2's migration assessment on and start its first run, so it's ready after the first deploy and stays on through upgrades; then it runs every week, on Sundays at 23:00 on the server's clock. It's free. The first run uploads about 6 minutes after it starts. Right after the assessment is turned on, its start can fail until the Azure extension for SQL Server picks the setting up (about 40 minutes on 2026-11-18), so `deploy.ps1` tries again for up to 10 minutes once T2's host is ready, and a later `deploy.ps1` or `configure-arc.ps1` tries again too. `T2.ARC.MIGRATIONASSESSMENT` is **Pass** once an assessment has uploaded, with the readiness in its evidence, and a **Warning** until then, or when anything about the assessment fails: never a failure, because nothing else depends on it.
6. **If it isn't there:** an assessment that hasn't uploaded yet shows nothing in Database Hub: `./scripts/validate.ps1 -Area T2` says whether and when it uploaded, and the Azure portal's **Assessments** page has the same assessment.

### The Database Agent loop on T3

The agent's issue, Copilot's analysis of it, a manual response, and the issue closing, in one session. Database Agents is a preview: it detects and investigates without an LLM, explains with Copilot, and applies no change itself ("All scenarios require a manual response"), so the showcase makes the response, the way a DBA would ([Database Agents](https://learn.microsoft.com/fabric/database/hub/database-agents)).

**Optional, once per deployment, about 30 seconds.** Database Agents has no API, so no script can do it; `deploy.ps1` lists it under **Please confirm**, with the link and the exact database (`HUB.AGENT.T3`). Without it, the regression, the response, and T3's CPU drop still run, but Database Agents raises no issue:

1. Open Database Hub, select **Manage agents** (upper left), then **Database agent settings**, and turn **Enabled** on.
2. Select T3's database, `azuresql01-<deploymentId>/ContosoCare`; under **Agent policy**, turn on **Flag long-running queries**, **Force last known good plans**, and **Flag high CPU**; select **Apply**, then **Save**. The green **Database agent is active** message confirms it ([enable Database Agents](https://learn.microsoft.com/fabric/database/hub/enable-database-agents)).
3. Do it while T3 is awake: right after `deploy.ps1`, or during a session. Saving needs Azure write access on T3 (the account that deployed the demo has it, and `T3.AGENT` checks yours), and T3 must be in the region associated with your Fabric tenant's home region. The selection stays across sessions and upgrades; recreating T3 (`stop-demo.ps1 -RemoveT3`) needs it again.

**In every session** (Run all's guide prints the times; in a 90-minute session the beat runs from about 30 to 60 minutes after T3's activity starts, and a session of 60 minutes or more has the whole beat):

| When | What happens | What you do |
|---|---|---|
| 3 minutes into the beat | T3's lookup regresses to a scanning plan, and T3's CPU climbs. `FORCE_LAST_GOOD_PLAN` is held off, so automatic tuning doesn't fix it first | Show T3's CPU on **Performance** or the Real-Time Dashboard |
| About 15 minutes later | Database Agents raises an issue on T3, a new one each session | Open it from Database Hub's issue list. In **Recommended action**, select **Explain why**, then **Analyze slow query** beneath the captured query ([review an issue](https://learn.microsoft.com/fabric/database/hub/review-performance-issue)) |
| At 85% of the beat | **Respond:** Run all's T3 run forces the last good plan through Query Store, the issue's manual response, and turns `FORCE_LAST_GOOD_PLAN` back on. The notebook prints "Now: T3 Respond" | Say: "The agent investigated and recommended. A person decided, and the runbook made the change." |
| A few minutes after that | T3's CPU falls on the dashboards, and the notebook compares T3's CPU before and after the response (**Pass**, or a **Warning** that says why) | Show the drop. The issue closes when the agent sees the condition cleared; or close it yourself once you've checked, as Learn says |

- **What it looked like live** (2026-11-19, `lowest-cost`, T3 at 2 vCores): the lookup regressed 3 minutes into the beat, and T3's CPU in Azure Monitor went from 8% to 99% and stayed there for 21 minutes, with no automatic correction. At 85%, the response forced the plan automatic tuning recommended, and T3's CPU fell to 7% the next minute. Database Hub's telemetry shows the same drop 3 to 15 minutes later.
- **Say:** "That's the whole loop: the agent detects and investigates, Copilot explains, a person decides the response, and the agent tracks the issue to its close."
- **If it isn't there:** no issue after about 20 minutes means T3 isn't selected or the agent isn't active: check the green message, and `./scripts/validate.ps1 -Area T3` (`T3.AGENT`) names any gap Azure can see. **Explain why** and **Analyze slow query** need the capacity's Copilot. The regression and its CPU still show on **Performance**, and [plan-regression.in-hub](../fabric/agent/prompts/plan-regression.in-hub.md)'s prompts work in Copilot.
- **Afterward:** `./scripts/status.ps1` shows `FORCE_LAST_GOOD_PLAN` (`STATUS.T3.AUTOTUNING`). Every way a session ends puts it back: the response, the beat's end, reset, a cancel, a newer Run all, Stop now, `stop-demo.ps1`, and, after the nightly safety stop, the next run on T3; `deploy.ps1` does too ([plan regression](../scenarios/plan-regression/README.md)). Once the session's history is saved, the history report and the Insights app have the beat's `database_agent` finding: T3's CPU before and after the response, with **Pass** when it fell.

### T5: Azure Cosmos DB's RU storm

One hot partition uses up T5's 400 RU/s, Database Hub shows normalized RU at 100% with throttled requests (429s), and both recover when the storm ends ([ADR 0027](adr/0027-t5-cosmos-db.md)). Nothing to sign in to or set up: T1's managed identity has T5's data-plane role, and Database Hub reads T5's Azure Monitor metrics with your Reader access.

**In every session** (Run all's guide prints the times): Run all's showcase runs `ru-storm` on T5 at minutes 3 (10 minutes) and 18 (8 minutes) of each 30-minute cycle, and keeps T5's baseline running to the session's end: a storm that couldn't end at least 2 minutes before then doesn't start (since 2026-11-19), so none is running when the session ends.

**Its container, for each session:** T5's container exists only during a session (since 2026-11-19), so its 400 RU/s bill only while the demo runs. Run all and `./scripts/start-demo.ps1` create it at the start, in about a minute, and the stops delete it, so every session starts from the same empty container. Until the session control's role can create it again, it stays between sessions instead, and bills all month unless the subscription's free tier covers it: `DEPLOY.T5.LIFECYCLE` says which, and the fix is an Owner's `./scripts/grant-safety-stop.ps1`, once, or an Owner's `./scripts/deploy.ps1` ([cost](cost-management.md#t5-azure-cosmos-db-2026-11-18)). When the session control has no role at all (a Contributor's new deployment), Run all can't start a session: start it with `./scripts/start-demo.ps1`, or ask an Owner to run `./scripts/grant-safety-stop.ps1` once.

1. **Show:** in Database Hub, **Estate**, filter to Azure Cosmos DB and select `cosmos01-<deploymentId>`; then **Performance**. **Normalized RU Consumption** at 100% and **Throttled Requests (429s)** climbing, with **Total Request Units** flat at the **Provisioned Throughput** line. Its charts use an hourly grain, so look at the hour the storm falls in.
2. **Say:** "A bedside-monitor integration is stuck in a retry loop and hammering one patient's records. Cosmos DB rate-limits it to protect everyone else's throughput: a 429 isn't an outage, and **Availability** stays at 100%. The fix is the data model, a partition key that spreads the writes, not a bigger bill."
3. **The recovery:** between the waves and after the storm, normalized RU falls back to the baseline's few percent and the 429s stop.
4. **If it isn't there:** `./scripts/status.ps1` (`STATUS.T5`) gives the last 15 minutes' peak normalized RU and 429s from Azure Monitor, and the walkthrough's [RU storm (T5)](#ru-storm-t5) cheat sheet has the rehearsal steps and the command that starts a storm by itself.
5. **Afterward:** the session's history has T5's peak normalized RU, requests, 429s, and request units, with a `cosmosdb.T5.recovery` finding (**Pass** when T5 was back at its baseline before the capture ended).

### Reset, stop, and repeat

- **Repeat:** every Run all repeats the moments. The agent raises a new issue each session (closed ones stay in its history), and the beat unforces the plan at its next start. T5's storm upserts a fixed set of 100 documents and deletes them when it ends, however it ends, so every session's storm starts from the same data, RU, and no 429s.
- **Reset:** `RESET_NOW = True` in the notebook, then Run all, resets the targets whose VM runs; `./scripts/reset-demo.ps1` does the same from a PC. Either unforces the plan and puts back anything a run left, T5's storm documents included.
- **Stop:** Run all ends the session itself. To end it sooner, `STOP_NOW = True`, then Run all, which still saves the session's history; or `./scripts/stop-demo.ps1` from a PC.
- **Length and rehearsal:** `DURATION_MINUTES` sets the session's length (90 by default, 30 to 120; the Database Agent loop needs 60 or more), and `MODE = "check"` shows the plan and sends nothing ([the switches](../fabric/control/README.md#the-switches)).

## Demo it yourself: the Insights app

Anyone who deploys the demo shows the Insights app themselves, with nothing to set up in it ([the app's guide](../fabric/app/README.md#demo-it-yourself)). It's a Fabric Apps item, a preview. Open it after a session's end, when the session's history is saved.

1. **Open it:** in the Fabric portal, open the demo's workspace and select `APP_DatabaseHub_Insights`. It signs you in with your Fabric account and opens on **Overview**. Before the first session it says **No history yet**: Run all in `NB_DatabaseHub_Control`, and come back after the session's end.
2. **Show:** Overview's **Live now**, Database Hub's own view of the estate: its resources, high usage in the last 24 hours, security warnings, and Cosmos DB. **Say:** "One console for the estate: what Database Hub sees right now, and under it, what the history kept."
3. **Drill down:** a target's health tile opens its page; on T3, **Ask why** on the CPU peak asks Copilot about it, with the rows and the DAX behind them.
4. **The incident and the agent loop:** on **Incidents**, select T3's plan-regression window: its replay, then **From signal to fix**: detect, the evidence, the response (the last good plan forced at the beat's 85%), and T3's CPU before and after it. **Say:** "The agent detected and investigated, a person decided, the runbook responded, and here's the proof it worked."
5. **T5:** **Estate**, then T5: normalized RU at 100% in ru-storm's waves, the 429s, and the recovery. **Say:** "Same console, another engine: the throttling, and that it recovered by itself."
6. **T2, ready to migrate:** **Findings**, then **Optimization**, or **Estate**, then T2: `arcsql01`'s readiness for each Azure SQL target, from Database Hub's inventory, with when Azure Arc assessed it. **Ask Copilot** asks "Which of my servers can move to Azure, and to what?", and **Ask why** on a target that's not ready. **Say:** "An on-premises server, assessed for Azure every week at no charge: here's where it can go." Database Hub doesn't list a ready assessment as an issue; the app shows it here.
7. **Ask, the Copilot chat:** on any visual, **Ask Copilot** opens the chat's dock with what's on screen. The first time in each browser, sign in with GitHub: the chat runs on your own GitHub Copilot plan ([the Copilot chat](../README.md#the-copilot-chat-in-the-insights-app)). The top bar then shows your GitHub login next to your Fabric account.
8. **Manage:** **Reset** or **Start a session** (which bills) says what it will do and asks for confirmation. An operator's request goes to the session control; otherwise the app copies the request for Run all in the control notebook.

- **If it isn't there:** **Live · unavailable** means the app's live function isn't deployed: the pages show the history, and Database Hub has the live view. No T5 means the deployment has no Cosmos DB. Without the live source, **Ready to migrate** links `arcsql01` in the Azure portal, where the assessment is under **Migration**, **Assessments**. An empty agent loop means the session's history isn't saved yet: it's saved about 15 minutes after the session's end. An empty **Readiness** means no session has run yet: each Run all runs `NB_DatabaseHub_Deployment`'s read-only checks once its session runs, which fill it.
- **Repeat:** every session adds to the history, and Reset and the next Run all work the same way each time.

## Plan the session

### Pick the targets for the agent beats

Learn documents Database Agents, which raise issues, for Azure SQL Database only, T3 here, with how to turn it on and what it needs ([Database Agents](https://learn.microsoft.com/fabric/database/hub/database-agents)); [the Database Agent loop](#the-database-agent-loop-on-t3) uses it. The agent beats below are Copilot's questions in Database Hub: which SQL targets Copilot covers, and how long it takes, aren't documented. Every SQL incident scenario runs on T1, T2, and T3, apart from plan-regression, which runs only on T3; T4 and T5 have their own ([scenarios](../scenarios/README.md)). So plan each of these beats per target, from the beats the showcase runs there:

| Target | Why it's in the story | Database Agent plan | If the agent declines it or shows nothing |
|---|---|---|---|
| T3 `azuresql01-<deploymentId>` / `ContosoCare`, Azure SQL Database | The PaaS path: native inventory, CPU as a percentage of the service tier's limit, log-rate governance, and the most Hub security assessments | **Plan A for every agent beat.** Database Agents is documented for Azure SQL Database; Copilot's coverage isn't | Ask the same prompts about a beat on T1, such as its blocking chain (minutes 0 to 10 of every cycle), or switch to the [fallback](#the-documented-scriptable-fallback). The `microsoft-sql` diagnostics skills are written for Azure SQL Database, so T3 also has the best query-level fallback |
| T1 `sqlvm01`, SQL Server on an Azure VM | The IaaS path through the SQL IaaS Agent extension; the default target for locking | **Plan B.** Same prompts | The telemetry prompts in GitHub Copilot CLI. The GA `databasehub-cli` skill lists SQL Server on Azure VMs in its inventory, but its CPU, storage, and memory health covers Azure SQL Database and SQL Server enabled by Azure Arc, not SQL Server on Azure VMs ([its health routes](https://github.com/microsoft/skills-for-fabric/blob/e31422e7d1045ef3a0906df9ff5991f2338af010/skills/databasehub-cli/references/health-drilldowns.md)) |
| T2 `arcsql01`, SQL Server enabled by Azure Arc in a nested Hyper-V guest, disclosed as a simulated on-premises server | The hybrid path; the default target for CPU, IO, and missing index | **Plan C.** Arc monitoring is documented for SQL Server enabled by Azure Arc in general, and nested guests aren't mentioned. T2's telemetry reached the documented endpoint on 2026-10-21; whether the Hub's **Performance** page and the agent cover it is a rehearsal check | The telemetry prompts, then the instance's **Performance Dashboard** in the Azure portal ([Monitor SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring)) |

- **Before the live coverage record has entries,** pick a beat on T3 and one on T1 from the guide, and investigate T3 first.
- **After a rehearsal,** use the targets that the [live coverage record](../fabric/agent/README.md#live-coverage-record) marks **Pass**, and record every session there: the date, the status per target, and the latency.

### Keep T3 between demos for agent-focused sessions

The decision ([ADR 0016](adr/0016-cost-profiles.md)):

- A newly created T3 can show Database Hub security and posture findings, and Database Agent findings, **late**.
- **Recommendation:** keep a persistent T3 for agent-focused demos and for multi-day baseline-versus-incident demos. That's the default: `stop-demo.ps1` doesn't delete T3, and serverless auto-pause stops its compute when it's idle ([serverless auto-pause and auto-resume](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume)).
- Use `./scripts/stop-demo.ps1 -RemoveT3` only for long gaps between demos, when saving T3's standing costs matters more. The next `start-demo.ps1` recreates T3 under the same names, which takes about 10 more minutes, and its readiness gate reports a **Warning** with the measured lag until telemetry arrives.
- **Measured so far:** on 2026-10-20 the first telemetry sample arrived 2.8 minutes after T3 was created. The delay for posture and agent findings isn't measured yet (*verify in rehearsal*).
- Telemetry is keyed on the resource ID, and T3 keeps its names, so earlier sessions should stay queryable within the 7-day retention. A live recreate test is still pending.

### Know the cost before you start

- **Ceilings:** $20 a session (`sessionCeilingUsd`, a **Warning** above it) and $415 a month for a new configuration (`monthlyCeilingUsd`, a hard ceiling: preflight fails above it; a configuration keeps its own value); [cost management](cost-management.md#at-a-glance). The month counts T4's 7-day automatic restart: about a day per restart when a safety stop is in place (the nightly safety stop that every deployment sets up, or the control's daily T4 safety stop), the rest of the month otherwise ([what stops or pauses on its own](cost-management.md#what-stops-or-pauses-on-its-own)). The Azure budget on the resource group alerts at 50%, 80%, and 100% of the monthly ceiling.
- **Estimate on the day:** `./scripts/estimate-cost.ps1 -NetworkMode private`, or `public`, whichever mode preflight resolved. When the subscription guard passes, it includes the subscription's Microsoft Defender for Cloud plans and the T3 free offer. It prices everything from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) when you run it, so this script quotes no prices.
- **The start checks it too:** `start-demo.ps1` runs the cost guardrail before it starts anything: the live estimate against both ceilings (`PREFLIGHT.COST.SESSION` and `PREFLIGHT.COST.MONTHLY`), and this month's actual cost plus one session against `monthlyCeilingUsd` (`START.COST.ACTUAL`). A **Fail** stops the start. `-SkipCostCheck` starts anyway (`START.COST` **Not selected**), so use it only right after a check.
- **What a session adds:** VM hours, the SQL Server licenses that bill while the VMs run (T1's image license, and Arc pay-as-you-go per core-hour for T2), T3 compute while it's active, T4 and its read replica, T5's container while it exists, Defender plans on running VMs, Bastion with its public IP for every hour it exists, and Ask's chat relay, per second only while someone chats.
- **Outside every estimate:** your Fabric capacity, which runs the notebooks and bills while it runs, outside the demo's resource group; Fabric and Power BI licenses; and each viewer's GitHub Copilot plan.
- **Bastion only when needed:** for the optional T-SQL path, or a person running the missing-index fix; no deployment needs it since the `PaygWizard` setup-wizard step was retired (2026-11-09). The 15-minute script never needs it, and the 30-minute script needs it only for the missing-index story without Run all. `./scripts/start-demo.ps1 -Interactive` creates Bastion Basic (about 8 minutes), tagged to expire after `bastionMaxHours` (4 by default) ([Bastion overview](https://learn.microsoft.com/azure/bastion/bastion-overview)). Remove it with `./scripts/stop-demo.ps1 -RemoveBastionOnly` as soon as you're done.

### Label T2 honestly

- **Default (`t2Mode = Nested`, `t2SqlInstallMode = JumpstartImage`, since 2026-11-05):** T2 is a nested Hyper-V guest on the Azure VM `archost01`, onboarded to Azure Arc, running SQL Server 2022 Standard with pay-as-you-go billing through Arc. Present it as a **simulated** on-premises server. The guest comes from [Arc Jumpstart](https://github.com/Azure/arc_jumpstart_docs/blob/71a945c619f78acb441c6470d76a9b58347169fe/docs/azure_jumpstart_arcbox/ITPro/_index.md)'s prebuilt SQL Server Standard image, which the host downloads, checks, and makes `arcsql01`; no T2 step needs a person ([deployment](deployment.md)).
- **`PaygWizard` mode** (the default until 2026-11-05; retired 2026-11-09): a configuration that says it runs as `JumpstartImage`, so no guest is built in this mode any more. A guest it built whose setup wizard was finished is kept and presented the same way, SQL Server 2022 Standard with pay-as-you-go billing through Arc; one whose wizard was never finished is made again from the Jumpstart image ([deployment](deployment.md#an-older-demo-a-plain-deployps1-upgrades-it-2026-11-09)).
- **`ProductKey` mode** (prerequisite P10) is fully unattended. **`Developer` mode** shows T2 in Estate only: its Performance checks report **Not supported**, because Arc monitoring needs Standard or Enterprise edition ([Monitor SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring)).
- **Evaluation only (`t2Mode = EvaluationOnlyAzureVm`):** when nested virtualization isn't available, T2 can be an Azure VM running the Arc agent under Microsoft's procedure for evaluation and testing purposes only ([Evaluate Azure Arc-enabled servers on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)). Label it **evaluation only** on every slide and every time you mention it; every T2 result in that mode starts with "EVALUATION ONLY:". Never call it on-premises. That mode has no workload runner yet, so run every incident on T1 or T3.

## Before the session

With Run all, [the presenter's path](#the-presenters-path) is all a session needs: Run all starts the demo, warms it up, and runs the incidents. Use these steps the day before, to rehearse and check, and before a session; the ones only a session without Run all (`start-demo.ps1`) needs say so.

### Prepare a PowerShell session

Every command in this script runs in PowerShell 7.4 from the repository root, after you sign in yourself. Scripts and module functions never sign in or change your Azure CLI context, and they target the configured subscription explicitly, so don't run `az account set` or change your default subscription for the demo.

```powershell
# Sign in only if you aren't signed in to the demo's tenant. At the subscription selector, press Enter for no changes.
az login --tenant <tenantId>
Import-Module ./scripts/modules/DbHubDemo/DbHubDemo.psd1
$config = Get-DemoConfig -Path ./config/demo.config.json
Assert-DemoAzContext -SubscriptionId $config.subscriptionId -TenantId $config.tenantId -Account $config.azureAccount
```

`Assert-DemoAzContext` is the subscription guard. It checks the Azure CLI's sign-in for the configured subscription (`az account show --subscription`) against the configured tenant and `azureAccount`. Then it runs read-only canaries through every authentication path the scripts use, and stops if any check fails. It never reads or changes your default subscription, so the demo works even when the default is in another tenant. Every module function then passes `--subscription` on each Azure CLI call. Pressing Enter at the `az login` subscription selector keeps your current default ([Sign in with Azure CLI at a command line](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively)).

### The day before

1. **Rehearse** both versions against the live environment, and record the results in the [live coverage record](../fabric/agent/README.md#live-coverage-record).
2. **Estimate the session** (see [Know the cost before you start](#know-the-cost-before-you-start)). A session estimate above $20 is a **Warning**: shorten the session or the incident list.
3. **Check T2** while `archost01` runs: `(Get-DemoVmHealth -Config $config -VmName archost01).state`, or `./scripts/status.ps1 -Detail`, which also reads T2's activity profile.
   - `Ready`: go.
   - `ManualActionRequired` with the step `SqlSetupWizard`: an environment from before 2026-11-09 whose `PaygWizard` setup wizard was never finished. Don't finish it by hand: run `./scripts/deploy.ps1` now, never during a session; it makes T2 again from Arc Jumpstart's image with no person, about 27 minutes plus about 33 for Arc onboarding ([deployment](deployment.md#an-older-demo-a-plain-deployps1-upgrades-it-2026-11-09)).
   - Anything else: see the [recovery playbook](#recovery-playbook).
4. **Fabric:**
   - **Your Fabric capacity:** Run all, the notebooks, and the dashboards need it running. Resume it in the Azure portal before Run all, and pause it after; resuming it resumes its billing ([pause and resume your Fabric capacity](https://learn.microsoft.com/fabric/enterprise/pause-resume)). Run all never resumes it; `fabric.manageCapacity` lets `start-demo.ps1` and `stop-demo.ps1` resume and pause a capacity that's yours alone. `./scripts/configure-fabric.ps1 -SkipNotebookImport -SkipTelemetry` reports `FABRIC.P5.CAPACITY` **Pass** when the workspace's capacity is Active (P5). Don't resume it on stage, because it takes minutes: [beat 5](#beat-5-13001600-a-monitor-from-a-template-and-the-dashboard-as-code) and [beat 9](#beat-9-26002900-the-notebooks) have fallbacks that need no capacity.
   - **The notebooks:** `deploy.ps1` imports the notebooks and the dashboard when they're missing (`fabric.importNotebooks` also updates the notebooks on every run); if one is missing, run `./scripts/deploy.ps1`. `NB_DatabaseHub_LiveActivity` analyzes and saves only: Run all in `NB_DatabaseHub_Control` runs it at the session's end.
   - **The dashboard as code (30-minute version):** check that `RTD_DatabaseHub_LiveView` is in the workspace. If it isn't, run `./scripts/deploy.ps1`, or import it alone: `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -ImportDashboard -WhatIf`, then without `-WhatIf`; expect `FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW` and `FABRIC.READBACK.RTD_DATABASEHUB_LIVEVIEW` **Pass** ([Real-Time Dashboard as code](../fabric/realtime/README.md#import-it)). Open it once with **Target** on a target that has telemetry, and check every tile by eye: the read-back proves the definition, not the tiles (**Manual action required** until a rehearsal does).
   - **The template wizard (30-minute version):** run **Create SQL monitors from template** once in the rehearsal, and note its templates, the metrics in each, and how long it takes; Learn documents its steps, not its templates (*verify in rehearsal*). Choose where its dashboard goes: the demo workspace, on the running capacity, as a new dashboard named for the session, or a new page in a scratch dashboard from the rehearsal ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)).
   - **Viewers:** if attendees will open either dashboard themselves, they need Reader on the subscription and access to the dashboard; a Fabric Free license is enough. A presenter who shares their screen needs nothing more ([presentation surfaces](presentation.md#licensing-and-permissions)).
   - The Database Hub tenant setting must be on (P4). Database Hub itself needs no capacity ([Database Hub FAQ](https://learn.microsoft.com/fabric/database/hub/faq)); the notebooks and the dashboards do.
5. **The fallback host:** install GitHub Copilot CLI, the pinned `fabric-skills` plugin, which carries the GA Database Hub skill `databasehub-cli` from `microsoft/skills-for-fabric`, the pinned `microsoft-sql` plugin, and the Learn MCP server with the [agent guide](../fabric/agent/README.md). `copilot plugin list --json` should show version 0.3.22 for `fabric-skills` and 1.0.0 for `microsoft-sql`. If you installed the earlier `microsoft-sql-fdh` plugin, uninstall it first, as the guide says. Don't run `copilot plugin update` before a demo.
6. **Presenter access:** each presenter opens [Database Hub](https://app.fabric.microsoft.com/workloads/fdh/databaseHub) with their own account. They need Reader on the subscription (Contributors have it; others need P8), `Microsoft.Sql` registered, the tenant setting **Users can access the Database hub (preview)**, and My workspace on a capacity outside North Europe and West Europe ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql), [Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)).
7. **The calendar:** end the session at least 15 minutes before the nightly auto-shutdown, which is `autoShutdownTime` (19:00 by default) in `autoShutdownTimeZone` and deallocates both VMs ([auto-shutdown a VM](https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm)); at the same time the nightly safety stop deallocates a VM that's still running, stops T4, and deletes T5's container ([what stops or pauses on its own](cost-management.md#what-stops-or-pauses-on-its-own)). Activity profiles end 2 minutes before it by design, and a Run all session always ends before it.
8. **Screenshots:** capture each beat during the rehearsal. They're the last rung of every fallback.

### 60 minutes before: start and warm up

**Without Run all only:** Run all starts and warms up the demo itself.

1. **Start the demo and warm it up:**

   ```powershell
   ./scripts/start-demo.ps1 -WarmUpMinutes 30
   # Or steady targets only, to contrast one staged incident with them:
   # ./scripts/start-demo.ps1 -ActivityProfile baseline -WarmUpMinutes 30
   ```

   In order, it runs the cost guardrail (`PREFLIGHT.COST.SESSION`, `PREFLIGHT.COST.MONTHLY`, and `START.COST.ACTUAL`); starts `sqlvm01` and `archost01` (`START.VM_*`; the T2 guest starts with its host) and T4 (`START.T4.START`); creates T5's container when a stop deleted it (`START.T5.CONTAINER`); resumes T3, or recreates it if it was removed and runs its readiness gate; sets the activity profile on T1, T3, T4, T5, and T2 (`START.PROFILE_*`) for the profile's default 8 hours, and never past 2 minutes before the next auto-shutdown; creates T4's read replica (below); and returns, with the activity running in the background. `START.WARMUP` says when to check the telemetry; add `-WaitForWarmUp` to wait the 30 minutes and check that telemetry arrives. With it, allow about 40 minutes, and about 10 more when T3 is recreated; the rehearsal measures it. Add `-Interactive -ResetAdminPassword` only when you need Bastion.
   - **The profile:** the configured `activityProfile`, `business-day` by default since 2026-11-03: `start-demo.ps1` sets `baseline` first and switches to `business-day` once its own Run Commands on a VM are done (`START.INCIDENTS_*`), so no incident slows them. Its [hourly incidents](#the-hourly-incidents-business-day) give Performance's problem panels something to show before the session starts. To contrast one staged incident with steady targets, start with `-ActivityProfile baseline`, or keep `business-day` and point at its latest incident as well.
   - **T3's results:** `T3.WARMUP` **Pass** reports how long a paused T3 took to answer, and `T3.PROPERTY` **Pass** means the `MS_EnablePerformanceMonitoringPreview` extended property is set ([Enable performance monitoring for Microsoft SQL](https://learn.microsoft.com/fabric/database/hub/add-sql)).
   - **GitHub Actions** are optional, for maintainers, and no session needs them ([deployment](deployment.md#one-click-github-actions)).
   - **Start with the script, not from the Azure portal:** the VMs don't set an activity profile when they boot (`activityProfileOnBoot` is false by default), so a VM started some other way runs no workload, and doesn't keep T3 awake either ([ADR 0016](adr/0016-cost-profiles.md)).
   - **T4's read replica** ([ADR 0025](adr/0025-t4-read-replica.md)): `start-demo.ps1` also creates `pgreplica01-<deploymentId>`, a same-region read replica of T4, once T4 runs, about 9 minutes within the warm-up (`START.T4.REPLICA`), so Database Hub's **Read replica lag** has data for the session and the [read replica lag](#read-replica-lag-t4) beat is available. `-SkipT4Replica` leaves it out and saves its share of the session's cost; `stop-demo.ps1` deletes it.
2. **Let the baseline run:** the SYSTEM task `DbHubDemo-Workload` on each VM hosts the profile: T1, T3, T4, and T5 from `sqlvm01`, and T2 inside the guest. Give it at least 30 minutes before the session, so the Performance page has a "before" picture; `-WarmUpMinutes 30` gives it that time. With `business-day`, every target has had at least one incident after the first hour.
3. **Check the runners:** `./scripts/status.ps1 -Detail` reports each target's active profile and its end (`STATUS.PROFILE_*`), with the VMs, T3, Bastion, the month-to-date cost, and the next auto-shutdown. For each target's runs:

   ```powershell
   foreach ($target in 'T1', 'T2', 'T3', 'T4', 'T5') {
       Invoke-DemoWorkloadCommand -Config $config -Target $target -ArgumentList 'status', '--json' |
           Select-Object -Property Target, Status, StdOut
   }
   ```

   Expect **Pass**, the `business-day` profile (or `baseline` when you chose it), and a running `healthy-baseline` run on each target, with an incident's run beside it during that incident's minutes. T1, T3, T4, and T5 commands run on `sqlvm01`, so T3, T4, and T5 can't be driven while it's deallocated. T2 commands go through `archost01` into the guest.

### The hourly incidents (`business-day`)

`business-day`, the default activity profile since 2026-11-03, runs the baseline plus these bounded incidents at fixed minutes past each UTC hour, each inside `ContosoCare` only and ended by its own time limit ([activity profiles](../scenarios/activity-profiles.json), [ADR 0010](adr/0010-workload-generator-technology.md#activity-profiles-business-day-by-default-2026-11-03)). Database Hub shows each a few minutes after it starts. Performance's problem panels, such as **High CPU resources over time**, **High CPU resource details**, **CPU spikes over time**, and **Databases limited by service tier**, list only resources that have that problem, so with `baseline` alone they say "No results found" (observed on 2026-11-03; [Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql) describes the Performance page, not these panels). The last column is what each incident is built to show, from the [cheat sheet](#per-scenario-cheat-sheet); which panel lists it is *verify in rehearsal*.

| Minute (UTC) | Target | Incident, length | What it shows, and where |
|---|---|---|---|
| :05 | T2 | `cpu-pressure`, 8 min | CPU rising toward 100%: the high-CPU and CPU-spike panels |
| :08 | T4 | `connection-surge`, 4 min | Connections climbing, on the PostgreSQL dashboard |
| :10 | T1 | `locking-blocking`, 8 min | `Processes blocked` above 0 and Lock waits |
| :15 | T3 | `resource-governance`, 5 min | CPU at the service tier's limit: **Databases limited by service tier** and the high-CPU panels |
| :20 | T2 | `missing-index`, 8 min | CPU and logical reads above the baseline: the CPU-spike panel |
| :22 | T4 | `idle-in-transaction`, 8 min | Sessions idle in an open transaction, blocking writers: the PostgreSQL dashboard counts them in **Connections**, and the Azure portal's Metrics show their state |
| :25 | T5 | `ru-storm`, 8 min | Normalized RU at 100% and throttled (429) requests in waves, then the recovery, on the Cosmos DB view ([RU storm](#ru-storm-t5)) |
| :35 | T2 | `io-pressure`, 8 min | Storage IO, `Page reads/sec`, and `WRITELOG` waits |
| :40 | T1 | `locking-blocking` with a deadlock, 6 min | Blocking, and `Number of Deadlocks/sec` above 0 |
| :42 | T4 | `cpu-pressure`, 6 min | CPU at its ceiling, on the PostgreSQL dashboard |
| :45 | T3 | `log-rate-pressure`, 5 min | The `Log Rate Governor` wait at the tier's log-rate limit: **Databases limited by service tier** |
| :50 | T2 | `inefficient-query`, 6 min | CPU and `Batch Requests/sec` above the baseline: the CPU-spike panel |

- **One right now:** `./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25` runs it in place of T2's profile, and the target is quiet once it ends; `./scripts/demo-control.ps1 -Target T2 -Scenario business-day -Duration 240` brings T2's hourly incidents back. Not during a Run all session: there it replaces T2's showcase.
- **The quieter demo:** set `"activityProfile": "baseline"` in the configuration, or pass `-ActivityProfile baseline` to `start-demo.ps1`. The problem panels then stay empty until you start an incident.
- **What the scripts do:** `deploy.ps1` and `start-demo.ps1` set `baseline` while their own Run Commands on a VM run, and switch to `business-day` once those are done (`DEPLOY.INCIDENTS_*`, `START.INCIDENTS_*`), so the first incident never slows them. A VM that's already running when they start gets `baseline` first, without waiting, so an incident an earlier session left running ends early in the run; a VM they start gets it as soon as its SQL Server answers, and their own Run Commands there wait for it. A run that's stopped (Ctrl+C) or fails still sends the switch, without waiting for it. `stop-demo.ps1` turns the profile off and deallocates the VMs, even mid-incident.

### 15 minutes before: the readiness gates

The Database Hub checklist in `configure-fabric.ps1` only reads, apart from presenter role assignments when `assignRoles` is true. With Run all it's optional: the notebook's live view shows each target's telemetry as it arrives. With the T3 gate, T3 is ready only when it's in Azure Resource Graph, its extended property is set, and fresh telemetry rows arrive from the documented telemetry endpoint (`Test-DemoT3Readiness`, with telemetry from `Test-DemoHubTelemetry`). The property check below runs the T3 warm-up through T1, so it also resumes a paused T3:

```powershell
./scripts/configure-fabric.ps1 -SkipNotebookImport -WaitMinutes 15 -T3ReadinessGate -T3PerformanceMonitoringCheck {
    param($c)
    Invoke-DemoT3WarmUp -Config $c | Where-Object -Property checkId -EQ -Value 'T3.PROPERTY'
}
```

| Check | What it proves | Go | If it isn't a go |
|---|---|---|---|
| Subscription guard (`PREFLIGHT.GUARD.CONTEXT`) | The Azure CLI reaches the configured subscription in its tenant as `azureAccount`, through every authentication path the scripts use | **Pass** | **Warning:** set `azureAccount` to the account its evidence names. **Fail:** sign in again yourself as that account (`az login --tenant <tenantId>`), without changing your default subscription; nothing else runs until it passes |
| `HUB.ESTATE.T1`–`T3` | Each target is in Azure Resource Graph, the Hub's inventory source | **Pass** for every target you'll show | T2 isn't **Pass** while it isn't ready yet: present T1 and T3, and say why |
| `TELEMETRY.T1`–`T3` | Rows arrived from the telemetry endpoint, and the newest is at most 15 minutes old | **Pass** for the incident target, and for every target you'll show on the Performance page | **Warning** (stale): the VM is stopped or T3 is paused; start or warm it up and run the gate again. **Fail** (no rows): check monitoring with `./scripts/configure-monitoring.ps1 -Target T1 -WaitMinutes 15` for T1, or `./scripts/configure-monitoring.ps1 -Target T2` for T2, or pick another target |
| `T3.READINESS.GATE` | T3 is in Resource Graph, its extended property is set, and fresh telemetry arrives | **Pass** | A **Warning** with the measured lag: T3 was just created or is paused. Use T1 for the agent beat today, and keep T3 next time |
| `FABRIC.P4.HUBSETTING` | The Hub tenant setting | **Pass** when a Fabric administrator runs it; otherwise **Manual action required**, "Couldn't check ... please confirm it's enabled", is expected | If Database Hub opens for the presenter, the setting is on |
| `FABRIC.P5.WORKSPACE`, `FABRIC.P5.CAPACITY` | Your role in the notebooks' workspace, and that its capacity is Active | **Pass**: Run all, the notebooks, and the dashboards need it | `FABRIC.P5.CAPACITY` is **Manual action required** when your capacity is paused. Resume it in the Azure portal before Run all, not on stage, because it takes minutes; meanwhile, [beat 5](#beat-5-13001600-a-monitor-from-a-template-and-the-dashboard-as-code) and [beat 9](#beat-9-26002900-the-notebooks) have fallbacks that need no capacity |
| `PREFLIGHT.FABRIC.VIEWERLICENSE` | Whether people who view Power BI content from this workspace need Pro or PPU (P11) | **Not selected** since 2026-11-14: the viewers' licenses are assumed, so nothing is read | Present by sharing your screen. Database Hub and the Real-Time Dashboards aren't Power BI content ([presentation surfaces](presentation.md#licensing-and-permissions)) |
| `HUB.PRESENTER.*` | Reader for presenters who aren't Contributors, only when `assignRoles` is true | **Not selected** or **Pass** | **Manual action required** prints the `az role assignment create` command an administrator runs |

Then open Database Hub as the presenter and check by eye: Estate lists the targets you'll show, with only the database engine for `sqlvm01` (`./scripts/status.ps1` reports `T1.SQLVM.ASSOCIATEDSERVICES`), and the Performance page has data from the last 15 minutes for each of them.

**Go or no-go:** if the incident target's telemetry isn't **Pass** 10 minutes before you start, take the incident from your next planned target: its beat in the guide with Run all, or stage it there without Run all.

### 10 minutes before: stage the incident (15-minute version)

**Without Run all only.** In a Run all session, stage nothing: the showcase runs the incidents, and `demo-control.ps1` on a target replaces that target's showcase, which on T3 ends the Database Agent loop. Take the incident from the beats the guide prints instead ([the 15-minute script](#the-15-minute-script)).

Database Hub telemetry arrives a few minutes after the activity: most performance data within 3 to 5 minutes, some inventory-based data up to 15 ([Enable performance monitoring for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm)). A 15-minute slot can't wait for it, so start the incident before the audience arrives:

```powershell
./scripts/demo-control.ps1 -Target T3 -Scenario incident:locking-blocking -Duration 30
```

- `demo-control.ps1` sets the target's profile through Run Command, with `--not-after` at the next auto-shutdown, and reports `CONTROL.T3`.
- The run is bounded: it ends after 30 minutes (the scenario's maximum), or 2 minutes before the next auto-shutdown, whichever comes first. The baseline runs beside it for the incident's window only; after that, the target stays quiet until a profile is set again: `./scripts/demo-control.ps1 -Target T3 -Scenario baseline -Duration 240` returns it to the baseline.
- **No live coverage record yet?** Run the same command with `-Target T1` too, and investigate T3 first.
- **Write down the windows** for the prompts: `{incidentWindow}` is the run's start and deadline, from the runner's `status --json` or `demo.scenario_runs`; `{baselineWindow}` is a window of the same length before it.

### 5 minutes before: open the tabs

- Database Hub: **Overview**; **Estate** with **View: Microsoft SQL** and the demo resource group selected; **Performance**.
- Copilot in Database Hub: **Ask Copilot** is at the top right of **Overview**, **Estate**, and **Performance**, and its pane opens beside the page ([Copilot in Database Hub](https://techcommunity.microsoft.com/blog/azuresqlblog/ask-your-database-estate-a-question-copilot-in-database-hub-is-now-in-public-pre/4572704)). The guide calls it "Database Hub > Estate > a SQL target".
- `NB_DatabaseHub_Control`, where Run all printed the presenter's guide: each beat's time, and the Copilot prompts with this session's names and times. Keep it off the shared screen, or on a second screen.
- GitHub Copilot CLI, started outside this repo with the [agent guide's](../fabric/agent/README.md) deny rules (`--deny-tool=write`, and the `fabric-skills` bundle's three MCP servers), with [session-setup.skills](../fabric/agent/prompts/session-setup.skills.md) already run.
- The [Azure Data Explorer web UI](https://dataexplorer.azure.com), connected to the telemetry endpoint, with the Learn sample queries for your scenario ready ([Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)). A query that names a resource ID shows the subscription ID in it, so fill those in before you share the screen, and show the results.
- The PowerShell session from [Prepare a PowerShell session](#prepare-a-powershell-session), off the shared screen: it runs `status.ps1` and [beat 9](#beat-9-26002900-the-notebooks)'s fallback, and, without Run all, the demo controls.
- For the 30-minute version: `NB_DatabaseHub_LiveActivity`, with its helper cells already run, and beat 9's fallback ready either way.
- For the 30-minute version's beat 5: `RTD_DatabaseHub_LiveView` on its **Incident** page, with **Time range** on the last hour and **Target** on the incident target, and the workspace where the wizard's dashboard will go.
- The rehearsal screenshots.
- Close anything that shows IDs, email addresses, or tokens. Never share a terminal that printed a token.

## The 15-minute script

The story in four beats: one estate in Database Hub, then performance, then an incident, then Copilot's investigation with human approval. It runs inside a Run all session ([the presenter's path](#the-presenters-path)): start Run all about 30 minutes before, and take the incident from the beats the guide prints, such as T3's locking and blocking (minutes 13 to 23 of the first and third cycles) or T1's blocking chain (minutes 0 to 10 of every cycle). Stage nothing. It focuses on the three SQL targets; add [T5's RU storm](#t5-azure-cosmos-dbs-ru-storm) or T4's [read replica lag](#read-replica-lag-t4) when time allows. On screen, it shows no notebook. Without Run all, start the demo and stage the incident as [before the session](#before-the-session) says.

| Time | Beat | Where |
|---|---|---|
| 0:00–3:00 | 1. One estate | Database Hub **Overview**, then **Estate** |
| 3:00–6:00 | 2. Performance | **Performance** |
| 6:00–9:00 | 3. The incident | **Performance**, then the target in **Estate** |
| 9:00–14:00 | 4. Copilot investigates, with human approval | Copilot in Database Hub |
| 14:00–15:00 | Close | Back to **Overview** |

### Beat 1 (0:00–3:00): one estate

- **Say:** "Contoso Care runs SQL in three places: SQL Server on an Azure VM, an on-premises SQL Server, and Azure SQL Database. Today each has its own portal, metrics, and tools, so every investigation starts with switching tools."
- **Show:** [Database Hub](https://app.fabric.microsoft.com/workloads/fdh/databaseHub) **Overview**: the **What needs attention?** section, **Recent signal changes**, and the **Optimization** card; then **Estate** with **View: Microsoft SQL** and the demo resource group selected, where T2 has its migration assessment ready ([the DBA moments](#optimization-t2-ready-to-migrate)) ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)).
- **Say:** "One inventory across all three. Nothing moved: the databases stay in their subscriptions and on-premises, and Database Hub uses my own Microsoft Entra ID and Azure permissions. It's generally available, and free with a Fabric Free license." ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview), [FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
- **Say, about T2:** "This on-premises server is simulated: a Hyper-V guest inside an Azure VM, connected through Azure Arc the way a real one would be." With the **evaluation only** fallback, say instead: "This one is an Azure VM running the Arc agent for evaluation only."
- **Look for:** on screen, three resources in **Estate**: `sqlvm01` (SQL Server on an Azure VM, with its database engine only), `arcsql01` (SQL Server enabled by Azure Arc), and `ContosoCare` on `azuresql01-<deploymentId>` (Azure SQL Database), with issues as colored chips under a resource and suggestions as chips with a lightbulb. The signal behind the list is Azure Resource Graph, the Hub's inventory source, which the readiness gates checked as `HUB.ESTATE.T1`–`T3`; for T1, `T1.SQLVM.ASSOCIATEDSERVICES` **Pass** means unified inventory lists only the engine.
- **If it isn't there:** if T2 is missing because it isn't ready yet (`HUB.ESTATE.T2` isn't **Pass**), say so and continue with T1 and T3. Never present a missing target as healthy. If T1 also shows Analysis Services or Integration Services (`T1.SQLVM.ASSOCIATEDSERVICES` is a **Warning**), say that the Marketplace image installs them, the demo removes them, and the story uses the database engine. Other causes are in the [recovery playbook](#recovery-playbook).
- **Reset:** Nothing to reset: the beat only reads.
- **Why it matters:** a consistent hybrid inventory: every SQL estate in one list, wherever it runs, seen through each person's own permissions.
- **Screenshot:** `docs/images/walkthrough/15-beat-1-estate.png` (planned): **Estate** with **View: Microsoft SQL** and the demo resource group, showing the three targets and their chips.

### Beat 2 (3:00–6:00): performance

- **Show:** **Performance**, the **Microsoft SQL** dashboard, with the last hour and the three servers selected. Point at **Recent signal changes**, then CPU, memory, and storage ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Say:** "Over the last hour, this is the workload: a front desk, billing, and scheduling baseline on all three, with a few bounded problems on top of it. On Azure SQL Database, CPU is a percentage of the service tier's limit."
- **Look for:** on screen, each target's charts since its activity started: the baseline, with the session's beats rising above it, such as T2's CPU from minute 2 of each cycle. The incident for beat 3 may already show at the right edge for its target, and in **Recent signal changes**; leave it for beat 3. The signals behind the baseline, between the beats: low `SqlServerCPUUtilization`, steady `Batch Requests/sec` and `Transactions/sec`, and `Processes blocked` at 0 (the [healthy baseline](#healthy-baseline)). Check the resource selection before you treat a chart as the whole estate.
- **Say, if a target shows a gap:** "No data isn't zero and isn't healthy. This serverless database pauses when it's idle and sends nothing while it's paused." ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor), best practices)
- **Say (optional):** "On this page, **Create SQL monitors from template** turns this view into a Fabric Real-Time Dashboard the team can keep and share." ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)) Mention it only; running it needs a workspace on a running Fabric capacity, and the 30-minute version shows it with the dashboard as code.
- **If it isn't there:** if a target has no recent data, show the other two and say that telemetry arrives a few minutes behind the activity; resume a paused T3 with `Invoke-DemoT3WarmUp -Config $config` while you talk. If the page is empty, check the time range and the resource selection, then use the rehearsal screenshot ([recovery playbook](#recovery-playbook)).
- **Reset:** Nothing to reset. Keep the last hour selected for beat 3.
- **Why it matters:** less tool switching: one performance view across the VM, the on-premises server, and the PaaS database, instead of three portals.
- **Screenshot:** `docs/images/walkthrough/15-beat-2-performance.png` (planned): the **Microsoft SQL** dashboard over the last hour, with the three servers selected, the baseline, and the session's beats.

### Beat 3 (6:00–9:00): the incident

- **Say:** "A few minutes ago, a billing batch on this database began holding row locks in an open transaction, like an application that forgot to commit. The billing clerks are now blocked behind it."
- **Show:** **Performance** with the incident target selected; then **Estate**, the target's row, for any new issue. If an issue appears, open **Issue Details** and its **Summary** and **Recommended action** ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)). Whether a blocking issue appears, and when, isn't documented (*verify in rehearsal*).
- **Look for:** on screen, the incident target leaving its baseline on **Performance**, and possibly a new issue chip in **Estate**; which chart shows blocking isn't documented (*verify in rehearsal*). The signals in the telemetry behind it, from the [locking cheat sheet](#locking-and-blocking) (or the [blocking chain's](#deep-blocking-chain) on T1): `Processes blocked` above 0, Lock-category waits (`LCK_M_U`, `LCK_M_S`), `Active Transactions` held open, and `ContosoCare.Demo/locking-blocking` sessions waiting behind one head blocker. On T3, optimized locking and read committed snapshot are on, so readers don't wait on writers; the clerks' updates still block ([optimized locking](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking)).
- **If it isn't there:** say "telemetry arrives a few minutes after the activity", then switch to the other blocking beat in the guide, T3's locking or T1's blocking chain, or run Learn sample queries 8 and 5 in the Azure Data Explorer web UI for the incident window. If the incident didn't start, see the [recovery playbook](#recovery-playbook).
- **Reset:** Nothing to reset: the beat is the session's own, bounded, and ends at its time limit, and the guide prints when the next one runs. Without Run all, to run the beat again, reset the target, stage the incident again, and wait a few minutes for telemetry:

  ```powershell
  ./scripts/reset-demo.ps1 -Target T3
  ./scripts/demo-control.ps1 -Target T3 -Scenario incident:locking-blocking -Duration 30
  ```

- **Why it matters:** faster detection: the blocking surfaces as a signal in one place, before anyone signs in to the server or a user calls.
- **Screenshot:** `docs/images/walkthrough/15-beat-3-incident.png` (planned): **Performance** for the incident target leaving its baseline, and any new issue chip in **Estate**.

### Beat 4 (9:00–14:00): Copilot investigates, with human approval

- **Say:** "Copilot in Database Hub is a preview. It's presenter-driven, here in the UI, and it has no API. It answers from what Database Hub knows about the estate, within my own permissions, and I'm showing it on the target we checked in rehearsal." Database Agents, also a preview, is documented for Azure SQL Database: [the Database Agent loop](#the-database-agent-loop-on-t3) shows it in a Run all session.
- **Do:** select **Ask Copilot** at the top right of **Estate** or **Performance**, with the incident target selected; its pane opens beside the page ([Copilot in Database Hub](https://techcommunity.microsoft.com/blog/azuresqlblog/ask-your-database-estate-a-question-copilot-in-database-hub-is-now-in-public-pre/4572704)). Fill the placeholders with the beat's names and times from the guide, and ask, in order:
  1. [locking-blocking.in-hub](../fabric/agent/prompts/locking-blocking.in-hub.md), prompt 1: investigate the blocking.
  2. Same file, prompt 3: the supporting evidence.
  3. [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md), prompt 4: the safest next action, proposed only.
  4. Same file, prompt 5: which actions need approval.
- **Look for:** on screen, Copilot's answer, then its proposal and the approvals it needs. In the answer: the target, `ContosoCare`, and a UTC window that overlaps the run; at least one blocking signal by name, such as `Processes blocked` or Lock-category waits; and a plain statement of what Copilot couldn't see, such as the statement text. Judge the answer with the prompt file's rubric, not against a scripted answer. Once the beat's end in the guide has passed, its charts come back to the baseline a few minutes later.
- **The approval beat:**
  1. Read the proposal aloud: what it changes, where, and how to roll it back.
  2. Say who approves it in production, for example the on-call DBA, and with which permission. "Actions in Database Hub are explicit and always approved by a user who holds the permission; Database Hub then hands the execution to the authoritative service. There's no free-form execution." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
  3. **Don't apply it.** Copilot only proposes: it doesn't change your databases. In this demo, never approve an agent-proposed change ([agent guide](../fabric/agent/README.md), approval rules).
  4. Let the demo's own bound end the incident instead: the beat acts only on `ContosoCare.Demo/` sessions in `ContosoCare`, rolls back its transactions, and ends at its time limit, which the guide prints. Don't end it with `demo-control.ps1` during a Run all session: that replaces the target's showcase, and on T3 it ends the Database Agent loop. When your slot overlaps that loop, show its **Respond** step too: a person decided the response, and Run all made it ([the Database Agent loop](#the-database-agent-loop-on-t3)).
- **Say:** "Copilot did the investigation and proposed a fix. A person decides."
- **If it isn't there:** if **Ask Copilot** is missing (Copilot's tenant settings aren't on for you, which a Fabric administrator changes), Copilot declines the target, or it hasn't answered after about three minutes, say so plainly and move to the [fallback](#the-documented-scriptable-fallback): [locking-blocking.skills](../fabric/agent/prompts/locking-blocking.skills.md) prompts 1 and 2 in GitHub Copilot CLI, then [incident-wrap-up.skills](../fabric/agent/prompts/incident-wrap-up.skills.md) prompts 4 and 5. Keep the same approval beat.
- **Reset:** Nothing to reset: the beat ends at its time limit. Start a new Copilot conversation before a re-run. Without Run all, return the staged targets to the baseline, T1 too when you staged the incident there:

  ```powershell
  ./scripts/demo-control.ps1 -Target T3 -Scenario baseline -Duration 240
  ./scripts/demo-control.ps1 -Target T1 -Scenario baseline -Duration 240
  ```

- **Why it matters:** a guided investigation and human-controlled action: Copilot gathers the evidence and proposes, and a person approves before anything changes.
- **Screenshot:** `docs/images/walkthrough/15-beat-4-agent-approval.png` (planned): Copilot's answer with its evidence, and its proposal before anyone acts on it.

### Close (14:00–15:00)

- **Show:** back to **Overview**, the whole estate.
- **Say:** "Faster detection, less tool switching, one inventory across Azure, on-premises, and PaaS, a guided investigation, and a person in control of every action." ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview))
- **Say:** "Database Hub is generally available; its Copilot and Database Agents are previews, so their coverage and behavior can change."
- **Look for:** on screen, **Overview** with **What needs attention?** across the three targets. The incident target's issue, if one appeared, can stay open for a few minutes after the beat ends, because signals refresh behind the activity ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql), troubleshooting).
- **If it isn't there:** if **Overview** shows nothing new, close on the **Estate** list from beat 1 or on the rehearsal screenshot; the value story doesn't depend on a live chart.
- **Reset:** Nothing to reset: the session's beats end on their own, and Run all stops everything at the session's end and saves its history. For a back-to-back slot in the same session, take the next blocking beat the guide prints; for another session, Run all again. Without Run all, stage the incident again 10 minutes before the next slot:

  ```powershell
  ./scripts/demo-control.ps1 -Target T3 -Scenario incident:locking-blocking -Duration 30
  ```

  After the last session, follow [after the session](#after-the-session).
- **Why it matters:** shared context: everyone leaves with the same picture of the estate, the evidence, and the decision, from faster detection and less tool switching to human-controlled action.
- **Screenshot:** `docs/images/walkthrough/15-close-overview.png` (planned): **Overview** at the end of the session, with **What needs attention?** across the three targets.
- **Afterward:** the blocking clears in the next telemetry samples, a few minutes after the beat ends. Show it to anyone who stays, then follow [after the session](#after-the-session).

## The 30-minute script

The deeper version: the same story, plus security and posture, an incident you watch start, a monitor from Database Hub's template next to the dashboard as code, Copilot's investigation and summary, and the notebooks. It runs inside a Run all session too ([the presenter's path](#the-presenters-path)), so your Fabric capacity runs during it, for the dashboards and the notebooks (P5); beats 5 and 9 still have fallbacks that need no capacity. Pick the incident from the beats that start near your beat 1: the guide prints when each one runs ([choose the incident](#choose-the-incident)). It focuses on the three SQL targets; add [T5's RU storm](#t5-azure-cosmos-dbs-ru-storm) or T4's [read replica lag](#read-replica-lag-t4) when time allows, and when your slot overlaps [the Database Agent loop](#the-database-agent-loop-on-t3), show its issue in beat 6 and its response in beat 7. Without Run all, start the demo as [before the session](#before-the-session) says, and start the incident in beat 1 with `demo-control.ps1`.

| Time | Beat | Where |
|---|---|---|
| 0:00–3:00 | 1. Frame it, and the incident on the clock | The guide's line for the beat, in `NB_DatabaseHub_Control` |
| 3:00–6:00 | 2. One estate, three onboarding paths | **Overview**, **Estate**, resource details |
| 6:00–10:00 | 3. Security and posture | **Overview** security summary, **Issue Details** |
| 10:00–13:00 | 4. Performance, before and during | **Performance** |
| 13:00–16:00 | 5. A monitor from a template, and the dashboard as code | **Create SQL monitors from template**, then `RTD_DatabaseHub_LiveView` in Fabric |
| 16:00–21:00 | 6. Copilot investigates | **Issue Details**, Copilot in Database Hub |
| 21:00–24:00 | 7. Human approval and a bounded fix | Copilot in Database Hub, and the beat's end |
| 24:00–26:00 | 8. Copilot explains and summarizes | Copilot in Database Hub |
| 26:00–29:00 | 9. The notebooks | `NB_DatabaseHub_LiveActivity` in Fabric, or its PowerShell fallback |
| 29:00–30:00 | Close: recovery and value | **Performance**, **Overview** |

### Choose the incident

Pick one row the day before, on a target your rehearsal showed Copilot covers. In a Run all session, each is one of the showcase's beats, which the guide prints with its times; the minutes below are of each target's 30-minute cycle. If the live coverage record is still empty, plan B is a beat on T1 in the same slot, such as its blocking chain. Without Run all, start the scenario in beat 1 with `demo-control.ps1` instead: 25 minutes for the first two rows and the last (30 at most), 15 for the other two (20 at most for resource governance, 15 for log rate); and stage it on T1 ten minutes before the session as plan B, with the [staging command](#10-minutes-before-stage-the-incident-15-minute-version) and `-Target T1`. Every scenario's bounds are in the [cheat sheet](#per-scenario-cheat-sheet).

| Story | The showcase's beat | When, in each target's cycle | The approval moment | The recovery to show |
|---|---|---|---|---|
| An application forgot to commit (default) | `locking-blocking` on T3, or T1's `blocking-chain` | Minutes 13 to 23 of the first and third cycles on T3; 0 to 10 of every cycle on T1 | Ending the head blocker's session, approved by a DBA | `Processes blocked` back to 0; Lock waits gone |
| A bad plan on the "on-premises" server | `cpu-pressure` on T2 | Minutes 2 to 14 of every cycle | A query rewrite through change control | CPU back to the baseline |
| Too much demand for the tier | `resource-governance` on T3 | Minutes 1 to 13 of the first and fourth cycles, 5 to 15 of the third | Scaling up costs money, so a budget owner approves | CPU back under the tier limit |
| A write-heavy batch | `log-rate-pressure` on T3 | Minutes 25 to 30 of the first, third, and fourth cycles | Rescheduling the batch or changing the tier | Log writes back to the baseline |
| A missing index | `missing-index` on T3 (on T2 without Run all) | Minutes 1 to 10 of the second and fourth cycles | A person reviews and runs the index script; never the agent | Reads drop after the index. In a Run all session, describe it: the "after" needs a person, Bastion, and a session without Run all ([beat 7](#beat-7-21002400-human-approval-and-a-bounded-fix)) |

The showcase's other beats fit the same slot when the audience cares about one kind of wait: T1's deep blocking chain, log flushes, and deadlock storm; T2's memory grants, parallelism, and tempdb contention; and T3's slow client ([cheat sheet](#deep-blocking-chain)). Without Run all, so does a target at full capacity (`capacity-max`).

### Beat 1 (0:00–3:00): frame it, and the incident on the clock

- **Say:** "Three SQL estates, three sets of tools. The workload on them is live, and in a few minutes a problem starts on one of them. We'll find it in Database Hub in about ten minutes, the way an operator would."
- **Do:** in the presenter's guide that Run all printed, find the chosen beat and its start time, and point at it: zoom in on that line, so no link or ID shows. The notebook's live view prints each beat as it begins.
- **Say:** "It's bounded: one database, only sessions tagged `ContosoCare.Demo/`, and a hard maximum duration enforced three times, in T-SQL, in the runner, and by a watchdog." ([ADR 0010](adr/0010-workload-generator-technology.md))
- **Look for:** on screen, the guide's line for the beat: its target, its start and end, and from when Database Hub shows it. The signal: as the beat begins, the live view prints it, and within a few minutes the target's CPU, waits, or blocked processes move there. Database Hub shows nothing yet; telemetry follows a few minutes later.
- **If it isn't there:** if the guide has no beat on that target, its activity didn't start, and the notebook's steps say why, with the fix: take the same kind of beat on another target, such as T1's blocking chain, and see the [recovery playbook](#recovery-playbook).
- **Reset:** Nothing to reset: the session runs the beat, and a later cycle runs it again, at the time the guide prints. Without Run all, start the incident on camera with `demo-control.ps1`; to start over, for example on another target, return the target to a quiet state first:

  ```powershell
  ./scripts/reset-demo.ps1 -Target T3
  ./scripts/demo-control.ps1 -Target T3 -Scenario incident:locking-blocking -Duration 25
  ```

- **Why it matters:** faster detection: the clock starts now, and nobody will sign in to the server to find the problem.
- **Screenshot:** `docs/images/walkthrough/30-beat-1-start-incident.png` (planned): the guide's line for the chosen beat, with its start time, and no links, IDs, or tokens on screen.
- **Write down** the beat's start and end for `{incidentWindow}`; the guide's Copilot prompts already have this session's times.

### Beat 2 (3:00–6:00): one estate, three onboarding paths

- **Show:** **Overview**, then **Estate** with **View: Microsoft SQL** and the demo resource group. Select each resource name to open its detail pane, which helps you identify, connect to, locate, and manage it ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Say:** "Each target arrives through a documented path, and turning on performance monitoring costs nothing extra." ([Enable performance monitoring for Microsoft SQL](https://learn.microsoft.com/fabric/database/hub/add-sql))
  - **T1:** the SQL IaaS Agent extension. Performance monitoring is the `DatabaseWatcheronAzureVM` feature flag in the extension's settings, which uploads with the VM's managed identity ([Enable performance monitoring for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm)). The estate shows its database engine only: the demo removes the Analysis Services and Integration Services that the image installs.
  - **T2:** Azure Arc, "the mechanism for connecting on-premises SQL Server instances to Azure" ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq)), with the instance's monitoring setting on ([Monitor SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring)). It's SQL Server 2022 Standard with pay-as-you-go billing through Arc, on a simulated on-premises server, or **evaluation only** in the fallback mode. In the live run on 2026-10-21, its telemetry arrived about 7 minutes after monitoring was turned on.
  - **T3:** native, through Azure Resource Graph, plus the `MS_EnablePerformanceMonitoringPreview` extended property, which the deployment sets from T1. The **Enable Performance Monitoring** option on the **Estate** page is the documented manual alternative ([Enable performance monitoring for Microsoft SQL](https://learn.microsoft.com/fabric/database/hub/add-sql)).
- **Show (optional, when time allows):** save the filtered view with **View** > **Manage custom views** > **Save**, then **Share** > **Copy link**. "Sharing a view shares its filters, not access: each person sees only what their own permissions allow." ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor))
- **Look for:** on screen, each target's detail pane with its resource type: SQL Server on an Azure VM, SQL Server enabled by Azure Arc, and Azure SQL Database, and for `sqlvm01` the database engine only. The signals behind them: all three in Azure Resource Graph (`HUB.ESTATE.T1`–`T3`), monitoring on for each (`T1.SQLVM.MONITORING`, `T2.ARC.MONITORING`, and `T3.PROPERTY`), and `T1.SQLVM.ASSOCIATEDSERVICES` **Pass**.
- **If it isn't there:** if T2 is missing because it isn't ready yet, present T1 and T3 and say why, as in the [15-minute version](#beat-1-000300-one-estate), which also covers T1 showing Analysis Services or Integration Services; other causes are in the [recovery playbook](#recovery-playbook).
- **Reset:** Nothing to reset: the beat only reads, and a saved view is yours to keep.
- **Why it matters:** a consistent hybrid inventory: three onboarding paths, one inventory, and no data moved.
- **Screenshot:** `docs/images/walkthrough/30-beat-2-estate-paths.png` (planned): **Estate** with one target's detail pane open, showing how it's identified and where to manage it.

### Beat 3 (6:00–10:00): security and posture

- **Show:** on **Overview**, the **Issues** and **Suggestions** summaries for **Security**. Select an issue type, or **See affected resources**, to open **Estate** with that filter. Expand a resource, select the finding, and open **Issue Details** ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Say:** "Database Hub surfaces health and compliance signals from Azure Resource Graph metadata and SQL performance signals, so it doesn't need public connectivity to the databases, even behind a private endpoint." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
- **Look for:** on screen, the **Security** issue and suggestion counts on **Overview**, then an **Issue Details** pane with the assessment, the affected server, its **Summary**, and its **Recommended action**. The signals are the SQL security assessments that Learn lists for Database Hub ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)). The demo's own configuration suggests what you'll see; none of it is observed yet (*verify in rehearsal*):

  | Target | Assessments that apply | What the demo's configuration suggests |
  |---|---|---|
  | T3 | Microsoft Entra Authentication Enabled, Minimum TLS version 1.2 Required, Public Network Access Disabled, and Private Endpoint Enabled (issues); Auditing, Encryption at rest using Customer Managed Keys, Microsoft Entra Authentication Enforced, and SQL Ledger (suggestions) | Entra-only and TLS 1.2 by design. In private mode, public access is off and a private endpoint exists; in public mode, expect the two network issues. The server has no auditing, customer-managed key, or ledger, unless a tenant policy adds one, so suggestions for those are likely |
  | T2 | Microsoft Entra Authentication Enabled (issue), Microsoft Entra Authentication Enforced (suggestion) | The instance uses Windows authentication only, so an Entra authentication issue is likely |
  | T1 | Public Network Access Disabled (issue) | SQL connectivity is `LOCAL` and the VM has no public IP, so no issue is expected |

- **Say:** "These are real findings about this demo's configuration. Each one has a summary and a recommended action, and **Open in...** takes me to the Azure portal, where an approved change happens. Database Hub doesn't change it for me." Then select **Open in...** to show the target in the Azure portal, and change nothing.
- **If it isn't there:** a newly created T3 can show posture findings late (see [Keep T3 between demos](#keep-t3-between-demos-for-agent-focused-sessions)). Show T1 or T2 instead, or open the T3 server in the Azure portal. If no security summary appears at all, say the assessments vary by resource type during the preview, and move on.
- **Reset:** Nothing to reset: the beat changes nothing. Close the Azure portal tab that **Open in...** opened.
- **Why it matters:** shared context: security, platform, and database teams see the same posture findings, with the evidence, in one place.
- **Screenshot:** `docs/images/walkthrough/30-beat-3-security.png` (planned): the **Security** issues and suggestions on **Overview**, and one **Issue Details** pane with its **Summary** and **Recommended action**.

### Beat 4 (10:00–13:00): performance, before and during

- **Show:** **Performance** with a time range that covers the baseline and the last 15 minutes. Point at **Recent signal changes**, then select the incident target and compare it with the other two ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Say:** "The same telemetry is open to KQL, Power BI, notebooks, and agents, through a documented endpoint." ([Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry))
- **Look for:** on screen, the incident target leaving its baseline a few minutes after the beat started, next to the other two and their own beats; whether **Recent signal changes** lists it isn't documented (*verify in rehearsal*). The signals: the chosen scenario's, from the [cheat sheet](#per-scenario-cheat-sheet); for locking, `Processes blocked` above 0 and rising Lock-category waits.
- **If it isn't there:** if the incident isn't visible yet, show the baseline on the other targets, run the scenario's Learn sample queries in the Azure Data Explorer web UI for the minutes that have arrived, and come back to it in beat 5, whose dashboards show the same minutes.
- **Reset:** Nothing to reset: the beat runs on to its time limit, and beats 5 and 6 look at its window.
- **Why it matters:** less tool switching: before and during, side by side, for every target, without opening each server's own monitoring.
- **Screenshot:** `docs/images/walkthrough/30-beat-4-performance.png` (planned): **Performance** with **Recent signal changes**, and the incident target selected over a range that shows the baseline and the incident.

### Beat 5 (13:00–16:00): a monitor from a template, and the dashboard as code

- **Say:** "Database Hub can turn this view into a dashboard the on-call team keeps. Let me build one for the database in trouble, live."
- **Do:** on **Performance**, select **Create SQL monitors from template**, and follow its steps for the incident target ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)):
  1. Choose a template with the metrics for the incident, and select **Next**. Learn doesn't list the templates or their metrics: pick the one you noted in rehearsal (*verify in rehearsal*).
  2. Select only the incident target's database, for example `ContosoCare` on T3, and select **Next**.
  3. Select the destination workspace you chose the day before, on the running Fabric capacity.
  4. Create a new dashboard named for this session, or add a page to the scratch dashboard from the rehearsal.
  5. Open the result, a Fabric Real-Time Dashboard, and set its time range to the last hour.
- **Show:** then `RTD_DatabaseHub_LiveView`, the dashboard as code, on its **Incident** page with **Target** set to the incident target and the same time range: processes blocked, waits by category, active sessions, batch requests, and CPU, side by side ([Real-Time Dashboard as code](../fabric/realtime/README.md)). Finish on its **Estate pulse** page: every target's freshness at a glance.
- **Say:** "The same telemetry, governed and versioned. The wizard is the fastest way to start. This one lives in Git: its layout and its KQL, the live-activity notebook's own, are reviewed and tested, and a script imports it through a documented Fabric API and reads it back. Both query the telemetry as the person looking at them, so sharing a dashboard doesn't share the data."
- **Look for:** on screen, the wizard's new dashboard with charts for the incident target, then the dashboard as code with the incident on the same minutes. Which charts each template includes isn't documented (*verify in rehearsal*). The signals, for locking: **Processes blocked, latest sample** above 0 in red, the Lock category rising in **Waits by category**, and **Active sessions in ContosoCare** climbing; on **Estate pulse**, **Freshness per target** green for every target whose newest sample is at most 15 minutes old.
- **If it isn't there:** if the wizard is missing, can't save to the workspace, or takes more than a minute, say so, then open the dashboard you made in rehearsal, or only the dashboard as code. If its tiles are empty, check **Target** and the time range; a viewer without Reader on the subscription sees empty tiles. If your capacity isn't running, neither dashboard opens: don't resume it on stage; give the three minutes to beat 6, and show **Performance** instead.
- **Reset:** Nothing to reset during the session: both dashboards only read. After the session, keep or delete the wizard's dashboard ([after the session](#after-the-session)). If someone changed the dashboard as code in the editor, import it again from Git, which replaces their changes:

  ```powershell
  ./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -ImportDashboard
  ```

- **Why it matters:** shared context: a dashboard the whole team can open, built from Database Hub in a few clicks or kept in Git and tested, over the same telemetry and each viewer's own permissions.
- **Screenshot:** `docs/images/walkthrough/30-beat-5-template-dashboard.png` (planned): the wizard's new dashboard next to the **Incident** page of `RTD_DatabaseHub_LiveView`, for the incident target.

### Beat 6 (16:00–21:00): Copilot investigates

- **Show:** if an issue appeared for the target, start from its **Issue Details**: "Findings can come from agents, alerts, resource metadata, or telemetry." ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)) Then select **Ask Copilot** at the top right of **Estate** or **Performance**, with the target selected; its pane opens beside the page ([Copilot in Database Hub](https://techcommunity.microsoft.com/blog/azuresqlblog/ask-your-database-estate-a-question-copilot-in-database-hub-is-now-in-public-pre/4572704)). When your slot overlaps [the Database Agent loop](#the-database-agent-loop-on-t3), start from the agent's issue on T3 instead: **Explain why**, then **Analyze slow query**.
- **Say:** "Copilot in Database Hub is a preview. It's presenter-driven, here in the UI, with no API, and it only proposes: every action needs a person's explicit approval. It answers from what Database Hub knows, within my own permissions, and this incident runs on the target we checked in rehearsal." Database Agents raises its own issues on T3 in a Run all session ([the Database Agent loop](#the-database-agent-loop-on-t3)).
- **Do:** ask every prompt in the scenario's in-Hub file, in order, for example [locking-blocking.in-hub](../fabric/agent/prompts/locking-blocking.in-hub.md) prompts 1 to 3. The [cheat sheet](#per-scenario-cheat-sheet) names the file for each scenario.
- **Look for:** on screen, Copilot's answers in its pane, and **Issue Details** if a finding appeared. In the answers, the prompt file's rubric: the right target and database, a UTC window that overlaps the run, the scenario's signals by name (for locking, `Processes blocked` and Lock-category waits), no blame on signals that didn't move, and a plain list of what Copilot couldn't see.
- **If it isn't there:** if Copilot declines the target or shows nothing after about three minutes, say so, then switch to plan B or C from [Pick the targets](#pick-the-targets-for-the-agent-beats), or to the [fallback](#the-documented-scriptable-fallback) with the scenario's skills file. Record the result in the [live coverage record](../fabric/agent/README.md#live-coverage-record) afterward.
- **Reset:** Nothing to reset: the prompts are read-only. Keep the conversation open for beats 7 and 8, and start a new one for a re-run.
- **Why it matters:** a guided investigation: Copilot turns an operational question into a structured investigation, and names its evidence.
- **Screenshot:** `docs/images/walkthrough/30-beat-6-agent.png` (planned): Copilot's answer for the incident target, with its signals, its window, and what it couldn't see.

### Beat 7 (21:00–24:00): human approval and a bounded fix

- **Do:** ask [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md) prompt 4 (the safest next action, proposed only) and prompt 5 (which actions need approval).
- **The approval beat:** read the proposal, its scope, and its rollback aloud; say who approves it in production and with which permission; then don't apply it: Copilot only proposes, and it doesn't change your databases. Never approve an agent-proposed change in this demo. If a recommendation conflicts with the evidence, don't apply it ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql), troubleshooting).
- **Do:** show the demo's own bound instead of a fix: the beat acts only on `ContosoCare.Demo/` sessions in `ContosoCare`, rolls back its transactions, and ends at its time limit, which the guide printed. Don't end it with `demo-control.ps1` during a Run all session: that replaces the target's showcase, and on T3 it ends the Database Agent loop. When your slot overlaps that loop, show its response: the notebook prints "Now: T3 Respond" when Run all forces the last good plan, the response a person decided ([the Database Agent loop](#the-database-agent-loop-on-t3)). Without Run all, use the scenario's own bounded control from the [cheat sheet](#per-scenario-cheat-sheet); for locking, return the target to the baseline:

  ```powershell
  ./scripts/demo-control.ps1 -Target T3 -Scenario baseline -Duration 240
  ```

- **Say:** "This is the step Database Hub keeps human: an explicit, auditable proposal, approved by someone with the permission, executed by the authoritative service." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
- **Look for:** on screen, the proposal with its scope and rollback, the list of approvals it needs, and then the beat's end at the time the guide printed. The signal: the target's blocked processes and waits fall back in the notebook's live view; Database Hub shows the recovery a few minutes later.
- **If it isn't there:** if Copilot offers no proposal, ask the same prompts from [incident-wrap-up.skills](../fabric/agent/prompts/incident-wrap-up.skills.md) in GitHub Copilot CLI, or describe the proposal yourself from the scenario's cheat sheet entry; the approval beat stays the same. If the run doesn't end at its time, stop that run with `Invoke-DemoWorkloadCommand -Config $config -Target T3 -ArgumentList 'stop', '--scenario', 'locking-blocking'`, which doesn't change the target's profile, and see the [recovery playbook](#recovery-playbook).
- **The missing-index story (T2, without Run all only):** a person reviews and runs [`remediation.sql`](../scenarios/missing-index/remediation.sql) in `ContosoCare` on T2. That needs a SQL session inside the virtual network: through Bastion to `archost01`, then into the guest with Hyper-V Manager; in an elevated PowerShell on the host, `C:\ProgramData\DbHubDemo\Copy-GuestCredential.ps1` copies the guest's password to the clipboard without showing it, for **Clipboard** > **Type clipboard text** at the guest's sign-in (*verify in rehearsal*). So create Bastion when you start the demo, with `-Interactive -ResetAdminPassword` on the [start command](#60-minutes-before-start-and-warm-up); its one-time password is for `archost01` only. Don't run `start-demo.ps1` again mid-session: it sets every target's profile again, which ends the incident. Remove Bastion right after the fix with `./scripts/stop-demo.ps1 -RemoveBastionOnly`, which also rotates that password. Nothing in the repo applies the index automatically.
- **Reset:** Nothing to reset in a Run all session: the beat ended at its time limit. Without Run all, the bounded control above is the reset for the incident. After a missing-index session, once it's over, drop the indexes on T2, so the scenario starts from "before" next time; this also turns T2's profile off:

  ```powershell
  ./scripts/reset-demo.ps1 -Target T2 -UndoRemediation
  ```

- **Why it matters:** human-controlled action: nothing changes without an explicit, auditable proposal that a person with the permission approves.
- **Screenshot:** `docs/images/walkthrough/30-beat-7-approval.png` (planned): the proposal and its approval list, before anyone acts on it, next to the beat's end in the guide.

### Beat 8 (24:00–26:00): Copilot explains and summarizes

- **Say:** "Copilot is the conversational interface; agents are the engines behind it. Copilot explains and summarizes from the same scoped data and agent findings you see in the UI, and when it recommends an action, that action is backed by an explicit agent capability and an auditable proposal." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
- **Do:** in Copilot's pane, which **Ask Copilot** opened, ask [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md) prompt 1 (a customer-friendly root cause), prompt 3 (the baseline compared with the incident), and prompt 7 (a five-bullet incident summary).
- **Look for:** on screen, Copilot's three answers. In them: plain language with a confidence level; a table of the signals that moved, such as `Processes blocked` and Lock-category waits for locking, and of those that stayed flat; and exactly five bullets, with nothing presented as decided.
- **If it isn't there:** if Copilot isn't available, run the same prompts from [incident-wrap-up.skills](../fabric/agent/prompts/incident-wrap-up.skills.md) in GitHub Copilot CLI, or answer them yourself from the **Performance** page and the scenario record.
- **Reset:** Nothing to reset: the prompts are read-only.
- **Why it matters:** shared context: one plain-language summary that the application team, the on-call engineer, and management read the same way.
- **Screenshot:** `docs/images/walkthrough/30-beat-8-copilot.png` (planned): Copilot's five-bullet incident summary.

### Beat 9 (26:00–29:00): the notebooks

- **Show:** `NB_DatabaseHub_LiveActivity` in the Fabric workspace ([Fabric assets](../fabric/README.md)), with its helper cells already run; otherwise use the fallback below. Pick two of these sections:
  - Section 6, **Locks and blocking**, or section 7, **Overall consumption**, for the incident target.
  - Section 8, **Correlation**: did the recorded scenario window produce its expected signal?
  - Section 9, **See it in the Hub**: the agent prompts, filled in with this session's names and window.
  - Section 11, **Persist**: snapshots and findings in the lakehouse keep demo history beyond the telemetry's 7-day retention. The [history report](../fabric/powerbi/README.md) reads them; show it after the session, not in this beat.
- **Say:** "Database Hub is free and needs no capacity. These notebooks run on a Fabric capacity and query the same telemetry endpoint for custom analysis; the dashboard in beat 5 is built from their KQL. **Run all** runs them: the live-activity notebook analyzes and saves, and nothing drops a table unless you also set `PURGE_DEMO_TABLES`. The session itself runs from the control notebook."
- **Look for:** on screen, the chart with the scenario window shaded and the correlation table. The signal: the correlation cell's verdict for the window; for locking, `Processes blocked` and Lock-category wait deltas inside the window. Its thresholds are presenter heuristics, not product behavior ([ADR 0014](adr/0014-notebook-role-and-capacity.md)).
- **If it isn't there:** don't resume the capacity or import notebooks on stage. Show the same telemetry without Fabric, from the documented endpoint, with the incident target in `-Target` and in the check ID. Run it off the shared screen, then share only the tables, because the result's evidence holds resource IDs:

  ```powershell
  $telemetry = Test-DemoHubTelemetry -Config $config -Target T3 -LookbackMinutes 30 -Detail | Where-Object -Property checkId -EQ -Value 'TELEMETRY.T3'
  $telemetry.evidence.waitCategories | ForEach-Object -Process { [pscustomobject]$_ } | Format-Table
  $telemetry.evidence.gaugeCounters | ForEach-Object -Process { [pscustomobject]$_ } | Format-Table
  Get-DemoHubTelemetryKql -Name WaitCategoryDeltas -ResourceId $telemetry.evidence.resourceId -LookbackMinutes 30
  ```

  The tables show wait seconds per category and the blocking and load counters for the last 30 minutes. The last line prints the KQL to paste into the Azure Data Explorer web UI before you share that tab. The notebook's `kusto` token worked against the endpoint on 2026-10-21 (`HUB.TELEMETRY.TOKEN` **Pass**, R29 closed), but that path is undocumented: if the notebook's section 4, **Telemetry access**, reports **Manual action required**, every analysis cell prints its KQL; run it there too. Or give the three minutes to beat 6.
- **Reset:** Nothing to reset: the analysis cells and the fallback only read, and running **Persist** again replaces this run's rows. It changes no activity since 2026-11-14.
- **Why it matters:** shared context beyond the Hub: the same telemetry in a notebook or a query the team can share, with history past the 7-day retention for reviews and trends.
- **Screenshot:** `docs/images/walkthrough/30-beat-9-notebook.png` (planned): the live-activity notebook's correlation output, with the scenario window shaded on its chart, or the fallback's two tables when the notebooks aren't available.

### Close (29:00–30:00): recovery and value

- **Show:** **Performance** for the incident target: the signal returning to the baseline. Telemetry arrives a few minutes after the activity, so the recovery may still be arriving; say so.
- **Say:** "Faster detection, less tool switching, one hybrid inventory, shared context, a guided investigation, and human-controlled action. Database Hub is generally available; its Copilot and Database Agents are previews."
- **Look for:** on screen, the incident target's chart heading back to its baseline after the beat's end. The signal, for locking: `Processes blocked` back at 0 and no new Lock-category waits in the latest samples.
- **If it isn't there:** if the recovery hasn't arrived yet, say it's a few minutes behind, then show the latest samples on the **Incident** page of `RTD_DatabaseHub_LiveView`, which refreshes every minute, or in the notebook or [beat 9](#beat-9-26002900-the-notebooks)'s fallback. Otherwise show the rehearsal screenshot, and close on the value.
- **Reset:** Nothing to reset: the session's beats end on their own, so a back-to-back slot in the same session can start at beat 1 with the next beat the guide prints, and Run all stops everything at the session's end and saves its history. After the last session, follow [after the session](#after-the-session).
- **Why it matters:** all six together: faster detection, less tool switching, a consistent hybrid inventory, shared context, a guided investigation, and human-controlled action.
- **Screenshot:** `docs/images/walkthrough/30-close-recovery.png` (planned): **Performance** for the incident target, back at its baseline after the beat's end.
- **If asked about mirroring:** "Database Hub doesn't need it; it monitors the databases where they are. Fabric mirroring isn't part of this demo; it's a possible future add-on." ([ADR 0015](adr/0015-mirroring-deferral.md), [Mirroring in Fabric](https://learn.microsoft.com/fabric/mirroring/overview))

## The documented, scriptable fallback

Use it when the Database Agent or Copilot isn't visible in your tenant, declines the target, or doesn't answer within about three minutes. Every piece is documented, every prompt is read-only or asks only for a proposal, and the same prompts work on T1, T2, and T3. The decision is [ADR 0013](adr/0013-agent-experience.md); installation, pins, limitations, and safety rules are in the [agent guide](../fabric/agent/README.md).

### The ladder

1. **Copilot in Database Hub, and on T3 the Database Agents issue:** the showcase.
2. **Ask, the Copilot chat in the Insights app:** select **Ask Copilot** in `APP_DatabaseHub_Insights` and ask the same question. It answers from the demo's history and the live estate, on your own GitHub Copilot plan after a GitHub sign-in once per browser, with the query or the source behind every answer, and needs nothing installed ([the Copilot chat in the Insights app](../README.md#the-copilot-chat-in-the-insights-app), [ADR 0028](adr/0028-ask-copilot-in-the-insights-app.md)).
3. **The same scenario's skills prompts** (`<scenario>.skills.md`) in GitHub Copilot CLI, the primary host, or VS Code, after [session-setup.skills](../fabric/agent/prompts/session-setup.skills.md):
   - **The GA Database Hub skill, `databasehub-cli`** (in the `fabric-skills` plugin from [`microsoft/skills-for-fabric`](https://github.com/microsoft/skills-for-fabric/tree/main/skills/databasehub-cli), the Database Hub CLI skill of the [Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview); it replaced the `microsoft-sql-fdh` plugin on 2026-11-18): inventory; CPU, storage, and memory health for SQL and PostgreSQL; Azure Cosmos DB's availability and RU use; and security posture. It's read-only and runs as your delegated sign-in.
   - **The telemetry agent instructions block** on Learn ([Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry), "Agent instructions block"): the connection contract and the rules for querying the documented telemetry endpoint. The session-setup prompt has the agent read it through the Learn MCP server. The repo links to it and never copies it. It covers every incident on every target.
   - **The Microsoft Learn MCP server** at `https://learn.microsoft.com/api/mcp`, for grounding. It needs no sign-in ([Microsoft Learn MCP Server overview](https://learn.microsoft.com/training/support/mcp)).
   - **The `microsoft-sql` plugin's diagnostics skills** (blocking and deadlocks, resource pressure, slow queries, plans): optional, and **Not selected** by default. They need a SQL connection from inside the virtual network, through Bastion, and they're written for Azure SQL Database, so on T1 and T2 they can decline.
4. **No agent at all:** the Database Hub pages, plus the Learn sample queries that each prompt file names, in the [Azure Data Explorer web UI](https://dataexplorer.azure.com) ([Azure Data Explorer web UI query overview](https://learn.microsoft.com/azure/data-explorer/web-ui-query-overview)), or the telemetry tables from [beat 9](#beat-9-26002900-the-notebooks)'s fallback.
5. **Last resort:** the rehearsal screenshots.

### Run it in the session

```powershell
Set-Location -Path "$HOME\dbhub-agent-demo"
copilot --deny-tool=write --deny-tool=FabricIQ --deny-tool=powerbi-modeling-mcp --deny-tool=fabric-sqlendpoint
```

- **Start outside this repo:** its instructions are for coding it, not for demos.
- **The deny rules:** `--deny-tool=write` denies every file write, and the other three switch off the `fabric-skills` bundle's MCP servers, one of which can author semantic models. No prompt uses them, and deny rules win over any approval ([agent guide](../fabric/agent/README.md)).
- Paste the session-setup prompt first, then the scenario's skills prompts with the four placeholders filled in.
- **Approve one read command at a time,** after reading it. Reject `az login`, `az account set`, and anything that writes. Never start with `--allow-all-tools` or `--allow-all`.
- **Tokens:** never paste one into the chat. If one appears in the transcript, end the session, clear the terminal, and sign in again.
- **Say:** "Same telemetry, same permissions, another surface: the agent queries a documented, read-only endpoint as me, and it can't change anything."

### Out of scope

- **The Fabric data agent:** it works over OneLake data, not Database Hub signals.
- **Custom agents or scripts that call undocumented Database Hub routes, or automate the portal:** never.

## Per-scenario cheat sheet

Every SQL scenario runs on T1, T2, and T3, apart from plan-regression, which runs only on T3. T4 runs healthy-baseline, cpu-pressure, locking-blocking, io-pressure, missing-index, and its own connection-surge, idle-in-transaction, and replica-lag; T5 runs healthy-baseline and its own ru-storm ([scenarios](../scenarios/README.md)). Each runs within the demo's database only (`ContosoCare`, `contosocare` on T4 and T5), on sessions tagged `ContosoCare.Demo/<scenario>/<run>`, with a hard maximum duration ([ADR 0010](adr/0010-workload-generator-technology.md)). Telemetry shows a scenario a few minutes after it starts.

**During a Run all session,** the showcase runs these scenarios itself: `demo-control.ps1` and a runner `profile set` on a target replace that target's showcase, and on T3 they end the Database Agent loop.

### Commands for every scenario

```powershell
# Start an incident on one target: one bounded run, with the baseline beside it for the incident's window.
./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25

# Change a scenario parameter (incidents only). demo-control.ps1 takes -Concurrency and -Intensity but not
# --param, so call the runner; '--concurrency' and '--intensity' work the same way here.
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'profile', 'set', '--name', 'incident:cpu-pressure', '--param', 'variant=healthy', '--not-after', '{{NEXT_SHUTDOWN}}'

# Stop the incident and keep the baseline, for up to 240 minutes and never past the auto-shutdown.
# The runner stops a run within about 10 seconds.
./scripts/demo-control.ps1 -Target T2 -Scenario baseline -Duration 240

# Stop one scenario now, or everything (which also sets the profile to off).
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'stop', '--scenario', 'cpu-pressure'
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'stop', '--all'

# What's running: the profile, recent runs with their windows, live demo sessions and blocking, space headroom.
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'status', '--json'

# Back to a quiet, known state: profile off, leftover demo sessions killed, no open demo transaction, scratch tables emptied.
./scripts/reset-demo.ps1 -Target T2
```

- `{{NEXT_SHUTDOWN}}` becomes the VM's next auto-shutdown time, and every run ends at least 2 minutes before it. `demo-control.ps1` adds it for you.
- T1, T3, T4, and T5 commands run on `sqlvm01`; T2 commands run in the guest through `archost01`. The VM that carries the command must be running.
- The scenario entries below use the runner's own options, such as `--duration 25m`; with `demo-control.ps1`, that's `-Duration 25`. Their `reset` is the runner command that `reset-demo.ps1` runs on each target.
- **GitHub Actions** (optional, for maintainers): the **demo-control** workflow runs `demo-control.ps1` with the same inputs: `environment` (`demo` by default), `target` (`all`, or `T1` to `T5`; an incident on `all` runs on the scenario's default target), `scenario` (`baseline`, `business-day`, `off`, or `incident:<scenario>`), `duration` in minutes (1 to 240), `concurrency` and `intensity` (empty keeps the scenario's defaults), `reset-before`, and `auto-cleanup` ([deployment](deployment.md#workflows)).
- **Backup:** with the `business-day` profile, the default, each target runs bounded incidents at fixed minutes past every UTC hour, for example locking on T1 at :10 and :40 ([the hourly incidents](#the-hourly-incidents-business-day)), so a recent incident is in the telemetry even if a live start fails.

### Healthy baseline

- **Runs on:** every target, T1 to T5, all by default. It's the `baseline` activity profile and the "before" picture. On T3 it's one session at intensity 2, which keeps the serverless database awake while it runs.
- **Start and stop:** `start-demo.ps1` sets it on every target when the configured `activityProfile` is `baseline`, and as the steady part of `business-day`, the default since 2026-11-03, which adds the hourly incidents; either runs for the profile's default 8 hours, and never past 2 minutes before the next auto-shutdown; the VMs don't set it when they boot unless `activityProfileOnBoot` is true. Run all's showcase runs it under its beats. On one target, set it with `./scripts/demo-control.ps1 -Target <T1 to T5> -Scenario baseline -Duration 240`, and turn it off with `-Scenario off`.
- **Show in the Hub:** steady `Batch Requests/sec` and `Transactions/sec`, low and flat CPU, `Processes blocked` at 0, and a few `ContosoCare.Demo/healthy-baseline` sessions. No Database Agent finding is expected.
- **Prompts:** [healthy-baseline.in-hub](../fabric/agent/prompts/healthy-baseline.in-hub.md) 1 to 3; fallback [healthy-baseline.skills](../fabric/agent/prompts/healthy-baseline.skills.md).
- **Reset:** nothing to undo. Status changes toggle within their seeded values, and `reset` removes the workload's audit rows.

### Locking and blocking

- **Runs on:** T1 by default, T2, T3, and T4. On T3, read committed snapshot isolation and optimized locking are on, so plain readers don't block; the clerks' updates and their `READCOMMITTEDLOCK` reads still do, and writer waits can be on transaction ID (`XACT`) resources ([optimized locking](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking)). On T4 it shows row-lock queues, which Database Hub's PostgreSQL view shows as connections.
- **Bounds:** 10 minutes by default, 30 at most; 3 blocked sessions; the holder keeps its transaction open for `holdSeconds` (120) and always rolls back.
- **Start:** `incident:locking-blocking` with `--duration 25m`. Add `'--param', 'deadlock=true'` for a bounded deadlock.
- **Stop:** `profile set --name baseline`, or `stop --scenario locking-blocking`.
- **Show in the Hub:** `Processes blocked` above 0, Lock-category waits (`LCK_M_U`, `LCK_M_S`), `Active Transactions` held open, demo sessions waiting behind one head blocker, and, with the deadlock, `Number of Deadlocks/sec` above 0.
- **Prompts:** [locking-blocking.in-hub](../fabric/agent/prompts/locking-blocking.in-hub.md) 1 to 3, then [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md); fallback [locking-blocking.skills](../fabric/agent/prompts/locking-blocking.skills.md).
- **Reset:** every transaction rolls back, so the work items stay as seeded. `reset` kills leftover demo sessions and verifies that no demo transaction is open.

### CPU pressure

- **Runs on:** T2 by default, T1, T3, and T4, where its sessions follow T4's vCores. On T3, also use the resource-governance prompts.
- **Bounds:** 10 minutes by default, 30 at most; 2 sessions; `variant` is `problem` (the default) or `healthy`.
- **Start:** `incident:cpu-pressure`. For the "after", set it again with `'--param', 'variant=healthy'`: the same question, answered with an index seek.
- **Stop:** `profile set --name baseline`, or `stop --scenario cpu-pressure`.
- **Show in the Hub:** `SqlServerCPUUtilization` rising toward 100%, the CPU wait category (`SOS_SCHEDULER_YIELD`), and `ContosoCare.Demo/cpu-pressure` sessions running.
- **Prompts:** [cpu-pressure.in-hub](../fabric/agent/prompts/cpu-pressure.in-hub.md) 1 to 4; fallback [cpu-pressure.skills](../fabric/agent/prompts/cpu-pressure.skills.md). Query-level evidence is in Query Store ([Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store)), not in the telemetry.
- **Reset:** read-only; nothing to undo.

### IO pressure

- **Runs on:** T2 by default, T1, T3, and T4. The runner checks free space first.
- **Bounds:** 10 minutes by default, 30 at most; 2 sessions; `scratchMb` 1,024 (256 on T3, 6,144 at most).
- **Start:** `incident:io-pressure`. Add `'--param', 'scratchMb=2048'` to make more reads physical, within the file caps.
- **Stop:** `profile set --name baseline`, or `stop --scenario io-pressure`.
- **Show in the Hub:** storage IO reads, writes, and stalls on the data file; `Page reads/sec` and `Page writes/sec`; `WRITELOG` while the scratch set grows; `PAGEIOLATCH` waits only once the scratch set exceeds the memory SQL Server can use. Per-file IO latency from the telemetry isn't available for Azure SQL Database.
- **Prompts:** [io-pressure.in-hub](../fabric/agent/prompts/io-pressure.in-hub.md) 1 to 3; fallback [io-pressure.skills](../fabric/agent/prompts/io-pressure.skills.md).
- **Reset:** auto-cleanup and `reset` empty the scratch table; the space stays allocated for the next run. Business data is never touched.

### Missing index

- **Runs on:** T2 by default, T1, T3, and T4 (since 2026-11-04). On T3, Azure SQL Database can also raise its own index recommendation after enough executions. On T4, the same two lookups feed autonomous tuning ([below](#t4-autonomous-tuning-in-the-azure-portal)); `remediation.sql` and `-UndoRemediation` are for T1 to T3.
- **Bounds:** 10 minutes by default, 30 at most; 2 sessions.
- **Start:** `incident:missing-index`.
- **Stop:** `profile set --name baseline`, or `stop --scenario missing-index`.
- **Show in the Hub:** CPU and logical reads above the baseline, and `ContosoCare.Demo/missing-index` sessions.
- **Prompts:** [missing-index.in-hub](../fabric/agent/prompts/missing-index.in-hub.md) 1 to 3, which only propose; fallback [missing-index.skills](../fabric/agent/prompts/missing-index.skills.md).
- **The human-approved action:** a person reviews and runs [`remediation.sql`](../scenarios/missing-index/remediation.sql) in `ContosoCare`, through a SQL session inside the virtual network. Never the agent, and never automatically.
- **Reset:** `./scripts/reset-demo.ps1 -Target <T1, T2, or T3> -UndoRemediation` (the runner's `reset --undo-remediation`) drops the two indexes, so the scenario starts again from "before".

### Inefficient query

- **Runs on:** T2 and T3 by default, and T1.
- **Bounds:** 10 minutes by default, 30 at most; 4 sessions; `variant` is `problem` or `healthy`.
- **Start:** `incident:inefficient-query`; the "after" is `'--param', 'variant=healthy'`.
- **Stop:** `profile set --name baseline`, or `stop --scenario inefficient-query`.
- **Show in the Hub:** CPU and `Batch Requests/sec` above the baseline, and many short `ContosoCare.Demo/inefficient-query` requests. The telemetry describes resources; the query itself is in Query Store.
- **Prompts:** [inefficient-query.in-hub](../fabric/agent/prompts/inefficient-query.in-hub.md) 1 to 3, and on T3 [resource-governance.in-hub](../fabric/agent/prompts/resource-governance.in-hub.md); fallback [inefficient-query.skills](../fabric/agent/prompts/inefficient-query.skills.md).
- **Reset:** read-only; nothing to undo.

### Resource governance

- **Runs on:** T3 by default, T1, and T2. On T1 and T2 it shows as plain CPU saturation of the VM, not a service-objective cap.
- **Bounds:** 5 minutes by default, 20 at most; 4 sessions.
- **Cost:** it uses serverless vCore seconds, and the free offer's monthly allowance, while it runs. Keep runs short.
- **Start:** `incident:resource-governance` with `--duration 15m`.
- **Stop:** `profile set --name baseline`, or `stop --scenario resource-governance`.
- **Show in the Hub:** CPU at the tier limit on T3, CPU waits with sound plans, and parallel `ContosoCare.Demo/resource-governance` sessions. In the Azure portal: the database's CPU percentage and Workers percentage metrics.
- **Prompts:** [resource-governance.in-hub](../fabric/agent/prompts/resource-governance.in-hub.md) 1 to 3; fallback [resource-governance.skills](../fabric/agent/prompts/resource-governance.skills.md).
- **Reset:** read-only. Once no session is open, T3 auto-pauses after its delay.

### Log-rate pressure

- **Runs on:** T3 by default, T1, and T2.
- **Bounds:** 5 minutes by default, 15 at most; 2 sessions; `maxLogMb` 2,048 (1,024 on T2).
- **Start:** `incident:log-rate-pressure` with `--duration 15m`.
- **Stop:** `profile set --name baseline`, or `stop --scenario log-rate-pressure`.
- **Show in the Hub:** on T3, the `Log Rate Governor` wait category ([transaction log rate governance](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server)), with `avg_log_write_percent` near 100 in [`sys.dm_db_resource_stats`](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-resource-stats-azure-sql-database) and Log IO percentage in the [Azure portal metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-sql-servers-databases-metrics). On T1 and T2: `WRITELOG` waits and rising `Log Bytes Flushed/sec`.
- **Prompts:** [log-rate-pressure.in-hub](../fabric/agent/prompts/log-rate-pressure.in-hub.md) 1 to 3; fallback [log-rate-pressure.skills](../fabric/agent/prompts/log-rate-pressure.skills.md).
- **Reset:** auto-cleanup and `reset` empty the scratch table; business data is never touched.

### Deep blocking chain

- **Runs on:** T1 by default, T2, and T3. On T3, optimized locking makes the links wait on transaction-ID locks, and there's no lock escalation.
- **Bounds:** 10 minutes by default, 30 at most; 2 branches (`concurrency`, 4 at most) of `depth` 4 (3 to 6), so 26 sessions at most; each link waits 60 seconds at most; an escalation of `escalationRows` 10,000 (7,000 to 20,000) every 120 seconds, held 15 seconds; everything rolls back.
- **Start:** `incident:blocking-chain`. Add `'--param', 'depth=6'` for a deeper chain, or `'--param', 'escalation=false'` for the chain alone.
- **Stop:** `profile set --name baseline`, or `stop --scenario blocking-chain`.
- **Show in the Hub:** `Processes blocked` well above the locking incident's, long Lock waits (`LCK_M_U`; `LCK_M_IS` and `LCK_M_IX` during an escalation), and `Active Transactions`. The chain's depth isn't in the telemetry: show it with the skills prompts or `sys.dm_exec_requests`.
- **Prompts:** [blocking-chain.in-hub](../fabric/agent/prompts/blocking-chain.in-hub.md) 1 to 3; fallback [blocking-chain.skills](../fabric/agent/prompts/blocking-chain.skills.md).
- **Reset:** every transaction rolls back. `reset` kills leftover demo sessions and verifies that no demo transaction is open.

### Deadlock storm

- **Runs on:** T1 by default, T2, and T3, the same on all three.
- **Bounds:** 10 minutes by default, 30 at most; 2 pairs (8 at most); `maxRounds` 60 per session (300 at most); `shape` `mixed` (the default), `order`, or `conversion`; every round rolls back.
- **Start:** `incident:deadlock-storm`. Add `'--param', 'shape=order'` for the classic lock-order deadlock only.
- **Stop:** `profile set --name baseline`, or `stop --scenario deadlock-storm`.
- **Show in the Hub:** `Number of Deadlocks/sec` above 0 bin after bin, `Errors/sec` with it, and short Lock waits. The graphs are in the `system_health` session on T1 and T2, not in the telemetry.
- **Prompts:** [deadlock-storm.in-hub](../fabric/agent/prompts/deadlock-storm.in-hub.md) 1 to 3; fallback [deadlock-storm.skills](../fabric/agent/prompts/deadlock-storm.skills.md).
- **Reset:** every round rolls back, so the inventory rows stay as seeded.

### tempdb contention

- **Runs on:** T2 by default, T1, and T3. On T3, which manages tempdb itself, expect fewer latch waits and more CPU waits (seen at 1 vCore; T3's maximum is 2 vCores since 2026-11-18).
- **Bounds:** 10 minutes by default, 30 at most; 16 sessions (32 at most); `rowsPerTable` 200 (10 to 2,000). Its temporary tables belong to its own sessions in tempdb and are dropped every iteration, the one place outside `ContosoCare` a scenario writes.
- **Start:** `incident:tempdb-contention`. Add `-Concurrency 24` for more contention.
- **Stop:** `profile set --name baseline`, or `stop --scenario tempdb-contention`.
- **Show in the Hub:** Buffer Latch waits (`PAGELATCH_EX`, `PAGELATCH_SH`, `PAGELATCH_UP`), `Temp Tables Creation Rate` and `Active Temp Tables`, and `SQL Re-Compilations/sec`.
- **Prompts:** [tempdb-contention.in-hub](../fabric/agent/prompts/tempdb-contention.in-hub.md) 1 to 3; fallback [tempdb-contention.skills](../fabric/agent/prompts/tempdb-contention.skills.md).
- **Reset:** nothing persists; SQL Server drops any temporary table left when its session closes.

### Memory grant pressure

- **Runs on:** T2 by default, T1, and T3.
- **Bounds:** 10 minutes by default, 30 at most; 8 sessions (16 at most); `grantPercent` 100 (10 to 100). Read-only, and no server setting changes.
- **Start:** `incident:memory-grant-pressure`.
- **Stop:** `profile set --name baseline`, or `stop --scenario memory-grant-pressure`.
- **Show in the Hub:** Memory waits (`RESOURCE_SEMAPHORE`), `Granted Workspace Memory (KB)` at its ceiling, a growing `MEMORYCLERK_SQLQERESERVATIONS`, and `Page life expectancy` falling.
- **Prompts:** [memory-grant-pressure.in-hub](../fabric/agent/prompts/memory-grant-pressure.in-hub.md) 1 to 3; fallback [memory-grant-pressure.skills](../fabric/agent/prompts/memory-grant-pressure.skills.md).
- **Reset:** read-only; grants are released when each query ends.

### Parallelism waits

- **Runs on:** T2 by default, T1, and T3. On T3, at its 2-vCore maximum since 2026-11-18, the plans can run at DOP 2 too (*verify in rehearsal*); at 1 vCore they ran serially, with CPU waits instead of Parallelism waits.
- **Bounds:** 10 minutes by default, 30 at most; 4 sessions (8 at most); `maxdop` 4 (2 to 8), and never more threads than the target has schedulers (2 on T1 and T2).
- **Start:** `incident:parallel-scans`.
- **Stop:** `profile set --name baseline`, or `stop --scenario parallel-scans`.
- **Show in the Hub:** Parallelism waits (`CXPACKET`, `CXCONSUMER`, `CXSYNC_PORT`) with high CPU.
- **Prompts:** [parallel-scans.in-hub](../fabric/agent/prompts/parallel-scans.in-hub.md) 1 to 3; fallback [parallel-scans.skills](../fabric/agent/prompts/parallel-scans.skills.md).
- **Reset:** read-only; nothing to undo.

### Log flush waits

- **Runs on:** T1 by default, T2, and T3.
- **Bounds:** 10 minutes by default, 30 at most; 8 sessions (16 at most); `maxRows` 200,000 commits per session (1,000 to 2,000,000), each session deleting its rows every 1,000.
- **Start:** `incident:log-flush-waits`.
- **Stop:** `profile set --name baseline`, or `stop --scenario log-flush-waits`.
- **Show in the Hub:** many short Tran Log IO waits (`WRITELOG`), with `Log Flushes/sec` (SQL Server only), `Log Bytes Flushed/sec`, and `Transactions/sec`; on T3 also `Log Rate Governor` past the log-rate limit.
- **Prompts:** [log-flush-waits.in-hub](../fabric/agent/prompts/log-flush-waits.in-hub.md) 1 to 3; fallback [log-flush-waits.skills](../fabric/agent/prompts/log-flush-waits.skills.md).
- **Reset:** auto-cleanup and `reset` empty `demo.commit_scratch`; business data is never touched.

### Slow consumer

- **Runs on:** T3 by default, with T1's runner as the client across the network, T1, and T2.
- **Bounds:** 10 minutes by default, 30 at most; 4 sessions (8 at most); `rowsPerQuery` 100,000 (1,000 to 500,000); the intensity sets the client's pause between reads. Read-only.
- **Start:** `incident:slow-consumer`.
- **Stop:** `profile set --name baseline`, or `stop --scenario slow-consumer`.
- **Show in the Hub:** Network IO waits (`ASYNC_NETWORK_IO`) while CPU and IO stay flat, and `SQL Attention rate` when the runner cancels.
- **Prompts:** [slow-consumer.in-hub](../fabric/agent/prompts/slow-consumer.in-hub.md) 1 to 3; fallback [slow-consumer.skills](../fabric/agent/prompts/slow-consumer.skills.md).
- **Reset:** read-only; the runner cancels its queries and closes its sessions.

### Capacity maxed out

- **Runs on:** T1 by default, T2, and T3. On T3, also use the resource-governance prompts.
- **Bounds:** 10 minutes by default, 20 at most; 8 CPU sessions (2 to 16) and `ioWorkers` 4 (0 to 8); `scratchMb` 6,144 on T1, 4,096 on T2, and 2,048 on T3, after a free-space check.
- **Cost:** on T3 it uses serverless vCore seconds at the maximum while it runs. Keep runs short.
- **Start:** `incident:capacity-max`.
- **Stop:** `profile set --name baseline`, or `stop --scenario capacity-max`.
- **Show in the Hub:** CPU at or near 100% (of the tier limit on T3), `SOS_SCHEDULER_YIELD` with signal waits, `PAGEIOLATCH_SH` once the scratch set exceeds memory, and IO stalls on the data file.
- **Prompts:** [capacity-max.in-hub](../fabric/agent/prompts/capacity-max.in-hub.md) 1 to 3; fallback [capacity-max.skills](../fabric/agent/prompts/capacity-max.skills.md).
- **Reset:** auto-cleanup and `reset` empty `demo.io_scratch` once no `io-pressure` or `capacity-max` run uses it; the space stays allocated for the next run.

### Plan regression

- **Runs on:** T3 only. SQL Server 2022 Standard on T1 and T2 has no automatic tuning ([editions](https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2022)), so the procedure refuses to run there. The showcase runs it on T3 in its third cycle, and in its second cycle as [the Database Agent loop](#the-database-agent-loop-on-t3).
- **Bounds:** 10 minutes by default, 30 at most; 2 sessions (8 at most); `goodPercent` 35 (10 to 80), the share of the run on the fast plan; `respondPercent`, `holdAutoCorrection`, and `pauseMs` for the agent beat ([plan regression](../scenarios/plan-regression/README.md)). The lookups only read; the run recompiles and unforces only `demo.usp_visit_summary_lookup`'s plans.
- **Start:** `incident:plan-regression` on T3 with `--duration 15m`.
- **Stop:** `profile set --name baseline`, or `stop --scenario plan-regression`.
- **Show:** in Database Hub, CPU stepping up at the switch to the slow plan and back down once automatic tuning forces the fast one; the plans themselves aren't in the telemetry. In T3: `sys.dm_db_tuning_recommendations` (a `FORCE_LAST_GOOD_PLAN` recommendation, Verifying, then Success), the database's **Automatic tuning** page in the Azure portal, and Query Store's **Regressed Queries** and **Queries With Forced Plans** in SSMS ([automatic tuning](https://learn.microsoft.com/azure/azure-sql/database/automatic-tuning-overview)). Whether the plan is forced within one run isn't proven live yet ([limitations](limitations.md)).
- **Prompts:** [plan-regression.in-hub](../fabric/agent/prompts/plan-regression.in-hub.md) 1 to 3; fallback [plan-regression.skills](../fabric/agent/prompts/plan-regression.skills.md).
- **Reset:** a forced plan stays after the run, so it can be shown. The next run, or `reset`, unforces it, for the lookup's queries only (`forced-plan-unforced`).

### Connection surge (T4)

- **Runs on:** T4 only. The template sets `max_connections` to 50 on every T4 size, and 15 slots stay reserved ([the scenario](../scenarios/connection-surge/README.md)).
- **Bounds:** 5 minutes by default, 15 at most. Each wave fills the free connection slots, then, for 5 seconds at most, the last few too, while a few attempts past the limit are refused: at most 5 a minute and 30 a run. The reserved slots stay free for `reset` and an administrator.
- **Start:** `incident:connection-surge`. `business-day` runs it at :08 each hour for 4 minutes, and Run all's showcase at minutes 0 to 8 of each T4 cycle.
- **Stop:** `profile set --name baseline`, or `stop --scenario connection-surge`.
- **Show in the Hub:** on the PostgreSQL dashboard, **Connections** at the limit and **Failed connections** above 0. Not proven live yet ([limitations](limitations.md#targets-and-licensing)).
- **Prompts:** none in the pack: Copilot's prompts cover SQL, so show T4 on **Performance**'s PostgreSQL dashboard.
- **Reset:** nothing is written; `reset` ends any leftover demo session.

### Idle in transaction (T4)

- **Runs on:** T4 only.
- **Bounds:** 10 minutes by default, 30 at most; 3 idle sessions by default, each holding a `REPEATABLE READ` transaction on a few claims for `holdSeconds`, then rolling back, with writers queued on their row locks. Each session's `idle_in_transaction_session_timeout` ends it before the run's deadline ([the scenario](../scenarios/idle-in-transaction/README.md)).
- **Start:** `incident:idle-in-transaction`. `business-day` runs it at :22 each hour for 8 minutes, and Run all's showcase at minutes 10 to 20 of T4's odd cycles.
- **Stop:** `profile set --name baseline`, or `stop --scenario idle-in-transaction`.
- **Show in the Hub:** **Connections** on the PostgreSQL dashboard counts the idle sessions too. Their states, the oldest transaction, and the Lock waits are in the Azure portal's Metrics for T4 (**Sessions By State**, **Oldest Transaction**, **Sessions By WaitEventType**), not in Database Hub.
- **Prompts:** none in the pack, as for the connection surge.
- **Reset:** every transaction rolls back, so the claims stay as seeded; `reset` ends leftover demo sessions and verifies that no demo transaction is open.

### T4 autonomous tuning in the Azure portal

- **Runs on:** T4 with 4 or more vCores and `t4AutonomousTuning` on: the default, General Purpose `Standard_D4ds_v5`, since 2026-11-04. It runs "on any currently supported compute SKU with at least 4 vCores" ([autonomous tuning](https://learn.microsoft.com/azure/postgresql/monitor/concepts-autonomous-tuning), updated 2026-07-16, checked 2026-11-04). `Standard_B1ms`, `Standard_B2s`, and `Standard_D2ds_v5` turn it off: "Don't enable query store on the Burstable pricing tier as it causes performance problems" ([Query Store](https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store)).
- **What feeds it:** the showcase's T4 `missing-index` slot (minutes 20-29 of each 30-minute cycle, General Purpose only; since 2026-11-14 the odd cycles only when T1's profile host has T4's read replica, whose `replica-lag` beat takes the even cycles' slot), or `incident:missing-index` on T4: two selective, parameterized lookups on `care.claims` and `care.appointments` columns without an index, sent by the runner as top-level statements, so Query Store captures them (`pg_qs.query_capture_mode` `TOP`, `pg_qs.parameters_capture_mode` `capture_first_sample`).
- **When:** a tuning session runs every `index_tuning.analysis_interval` minutes while T4 runs: 60 here, the minimum (the default is 720). So the first recommendation comes at least about 60 minutes after the lookups start: near the end of a 90-minute showcase, or the next day if T4 ran the lookups the day before. Not proven live.
- **Show it (Database Hub, then the Azure portal):** Database Hub's PostgreSQL view shows metrics only ([monitor PostgreSQL](https://learn.microsoft.com/fabric/database/hub/monitor-postgresql)), so go from Database Hub **Estate** → T4 (`pgflex01-<deploymentId>`) → **Open in…** (the Azure portal) → the server's **Intelligent Performance** > **Autonomous tuning**: its index recommendations for those tables, and table recommendations, with what each would change.
- **From a shell:** the documented command group [`az postgres flexible-server autonomous-tuning`](https://learn.microsoft.com/cli/azure/postgres/flexible-server/autonomous-tuning) (checked 2026-11-04):

  ```powershell
  az postgres flexible-server autonomous-tuning show --resource-group <rg> --server-name pgflex01-<deploymentId>
  az postgres flexible-server autonomous-tuning list-index-recommendations --resource-group <rg> --server-name pgflex01-<deploymentId> --recommendation-type CreateIndex
  az postgres flexible-server autonomous-tuning list-table-recommendations --resource-group <rg> --server-name pgflex01-<deploymentId>
  ```

- **The human-approved action:** nothing applies a recommendation: `index_tuning.mode` is `REPORT`. A person may review one and create the index in `contosocare`; nothing in the repo creates or drops T4 indexes, so to show "before" again, drop that index yourself.
- **Cost:** the 4-vCore size bills more per hour while T4 runs than a Burstable size, and the session's read replica, at the same size, adds about as much again; `./scripts/estimate-cost.ps1` prices both at today's list prices ([cost management](cost-management.md#at-a-glance)).

### Read replica lag (T4)

- **Runs on:** T4 with its read replica, `pgreplica01-<deploymentId>`, which Run all and `start-demo.ps1` create for each session ([ADR 0025](adr/0025-t4-read-replica.md)). A Burstable T4 has no replica, and a session without one (`-SkipT4Replica`, a size Azure refused, or a notebook run with `MODE = "activities"`) refuses the run with that fix.
- **The story:** "A reporting workload on your DR copy put it N minutes behind." A read replica serves reports and is a copy to recover to; a long report on it holds back the replay of the primary's changes, so the copy falls behind while the primary is fine.
- **Bounds:** 10 minutes by default, 15 at most; one report on the replica and one writer on T4 each cycle; the report holds `demo.replica_lag_marks` for `holdSeconds` (240, 30 to 540), then a `pauseSeconds` (60) quiet gap. Only that table and `ContosoCare.Demo/replica-lag/<run>` sessions; T4 takes its lock for one short call ([the scenario](../scenarios/replica-lag/README.md)).
- **Start:** `./scripts/demo-control.ps1 -Target T4 -Scenario incident:replica-lag -Duration 10`. For a shorter climb: `Invoke-DemoWorkloadCommand -Config $config -Target T4 -ArgumentList 'profile', 'set', '--name', 'incident:replica-lag', '--param', 'holdSeconds=120', '--not-after', '{{NEXT_SHUTDOWN}}'`. The showcase runs it by itself (since 2026-11-14): 50 minutes after T4's profile is set (T4's second cycle, minute 20), for 9 minutes, climbing to about 3 minutes twice, and again in the fourth cycle of a 120-minute run.
- **Stop:** `profile set --name baseline`, or `stop --scenario replica-lag`; both end the report on the replica too.
- **Show in the Hub:** in **Estate**, filter to **View: PostgreSQL**: the replica is a flexible server of its own next to T4 (*verify in rehearsal*). Select `pgreplica01-<deploymentId>`, then **Performance** and the PostgreSQL dashboard: **Read replica lag** (`physical_replication_delay_in_seconds`, replicas only) climbs to about `holdSeconds` during each report and drops back to a few seconds once it ends. Outside the beat, a same-region replica idles at 2 to 6 seconds ([monitor PostgreSQL](https://learn.microsoft.com/fabric/database/hub/monitor-postgresql)). On T4 itself, the Azure portal's Metrics show **Max Physical Replication Lag** in bytes growing at the same time.
- **Afterward:** Run all's end, or `./scripts/stop-demo.ps1 -SaveHistory`, keeps the session's lag curve in the history, and the Insights app's T4 page (**Estate**, then T4) shows it; it reads the replica's metrics before it deletes the replica, whose Azure Monitor history goes with it.
- **Reset:** the marks are the only rows it writes; the auto-cleanup and `reset` delete them, and `reset` ends the demo's sessions on the replica.

### RU storm (T5)

The DBA moment for Azure Cosmos DB (since 2026-11-18, [ADR 0027](adr/0027-t5-cosmos-db.md)): one hot partition uses up the container's throughput, Database Hub shows normalized RU at 100% with throttled requests, and then both recover.

- **Runs on:** T5, `cosmos01-<deploymentId>`, the Azure Cosmos DB for NoSQL account that every deployment has (an older demo gets it from `./scripts/deploy.ps1`). Its container `patient-events` has 400 RU/s and exists only during a session (since 2026-11-19): `start-demo.ps1`, Run all, and `demo-control.ps1` create it first, in about a minute. T1's runner drives it, so `sqlvm01` must be running. Nothing to sign in to: T1's managed identity has its data-plane role, and Database Hub needs only your Reader access.
- **The story:** "A bedside-monitor integration got stuck in a retry loop and is hammering one patient's records. Cosmos DB protects everyone else's throughput by rate-limiting it: that's a 429, not an outage. The fix is in the data model, not a bigger bill."
- **Bounds:** 10 minutes by default, 30 at most; 8 writers in waves of `stormSeconds` (150), each followed by `calmSeconds` (90) with no storm writes. Writes are upserts over a fixed set of 100 documents in its own partition (`p-storm-01`), never new ones, and it deletes them when it ends, however it ends, so every session starts from the same data ([the scenario](../scenarios/ru-storm/README.md)).
- **Start:** `./scripts/demo-control.ps1 -Target T5 -Scenario incident:ru-storm -Duration 10`. `business-day` runs it at :25 each hour for 8 minutes; Run all's showcase runs it twice in each 30-minute cycle, from minute 3 for 10 minutes and from minute 18 for 8.
- **Stop:** `profile set --name baseline` (or the notebook's **Stop now**); the writers stop within seconds, and the run deletes its documents.
- **Rehearse it, then show it in the Hub:**
  1. Before the audience, start the demo (`./scripts/start-demo.ps1`, or Run all), which creates T5's container, then check that T5 is ready: `./scripts/validate.ps1 -Area T5` shows `T5.ACCOUNT` to `T5.ACCESS` **Pass** and `METRICS.T5` **Pass** (requests in the last 15 minutes). Between sessions `T5.CONTAINER` says the container isn't there, which is a **Pass**.
  2. Start the storm (above), or let Run all's showcase start it at minute 3. Within a minute, `./scripts/status.ps1` shows `STATUS.T5` with throttled (429) requests and normalized RU at or near 100% for the last 15 minutes.
  3. In Database Hub, **Estate**: filter to Azure Cosmos DB and select `cosmos01-<deploymentId>`; then **Performance**. **Normalized RU Consumption** rises to 100% in the storm's waves, and **Throttled Requests** (429) climbs with it; **Total Request Units** flattens at about 400 RU/s, the **Provisioned Throughput** line. Its charts use an hourly grain, so give it a few minutes after the first wave, and look at the hour the storm falls in (*verify in rehearsal*).
  4. Point out what stays fine: **Availability** stays at 100%, because a 429 isn't an availability error, and between the waves normalized RU falls back and the 429s stop: the recovery, live.
  5. Open **Security** for T5: Microsoft Entra only and no public network access pass; customer-managed keys stay a suggestion.
- **What to say about the fix:** a better partition key spreads the writes (a per-device key, or a synthetic key with a suffix); a retry policy that honors `x-ms-retry-after-ms`, which the runner does; and more RU/s or autoscale only when the load is real. The demo changes nothing; the storm ends on its own.
- **Afterward:** `./scripts/stop-demo.ps1 -SaveHistory` (or Run all's end) saves T5's peak normalized RU, requests, 429s, and request units to the history, then deletes T5's container, which the next session creates again, empty: only T5's private endpoint and DNS zone bill between sessions. Until the session control's role can create the container again, it stays instead, and `DEPLOY.T5.LIFECYCLE` says so: an Owner runs `./scripts/grant-safety-stop.ps1` once ([cost](cost-management.md#t5-azure-cosmos-db-2026-11-18)).
- **Reset:** nothing to do: the run deletes its storm documents. After a stopped VM cut a storm off, `./scripts/reset-demo.ps1 -Target T5` deletes any left over.

## Recovery playbook

When something isn't visible, say so plainly, keep the story moving on another target or surface, and fix it after the session. Never present missing data as healthy: "missing telemetry isn't zero utilization or proof that a server is healthy" ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).

| What you see | Likely cause | During the session | Afterward |
|---|---|---|---|
| Run all says "Nothing runs", and the job was refused: "Another DbHub-Control job ... is Running", or "A run is active until ..." | One run at a time: a run started another way is active. A Run all while a session runs follows that session instead, which is expected | Follow the running session, or end it first: `STOP_NOW = True`, then Run all | [Troubleshooting](troubleshooting.md#the-on-demand-activity-control) |
| Run all can't start a session: "The webhook URL couldn't be read from Key Vault", the session's status never says it runs, or the job says NoEnvironment | Usually the session control's roles aren't assigned yet: the deployer wasn't an Owner, and no Owner has run the grant | Run the session from a PC: `./scripts/start-demo.ps1`, then `./scripts/stop-demo.ps1 -SaveHistory` | An Owner runs `./scripts/grant-safety-stop.ps1` once; [troubleshooting](troubleshooting.md#the-on-demand-activity-control) has the other causes |
| T5 shows no data or no throttling | `sqlvm01` is deallocated (T1's runner drives T5); T5's container wasn't created (`START.T5.CONTAINER`, `CONTROL.T5.CONTAINER`, or the session's **T5 container** step says why); or its hour hasn't filled yet, because T5's charts use an hourly grain | Show the other targets; `./scripts/status.ps1` (`STATUS.T5`) gives the last 15 minutes' requests, 429s, and normalized RU from Azure Monitor | [Troubleshooting](troubleshooting.md#t5-azure-cosmos-db) |
| Ask, the Copilot chat in the Insights app, doesn't sign in or doesn't answer | The relay is waking from zero, which takes a few seconds; the GitHub account has no Copilot plan; an organization that restricts OAuth apps hasn't approved **Database Hub Insights Ask**; or the tenant setting "Enforce a strict content security policy for static-hosted Fabric Apps (preview)" is on | Ask again in a few seconds; otherwise use Copilot in Database Hub or the [fallback ladder](#the-ladder) | The chat says what's wrong and what to do ([troubleshooting](troubleshooting.md#ask-the-copilot-chat-in-the-insights-app-2026-11-18)) |
| A target has no recent data on **Performance**, or `TELEMETRY.<target>` is a **Warning** | Telemetry lag: data arrives a few minutes after the activity ([Enable performance monitoring for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm)) | Say "telemetry arrives a few minutes behind", show another target, or run the scenario's Learn sample queries in the Azure Data Explorer web UI for the minutes that have arrived. Come back later | `Test-DemoHubTelemetry -Config $config -Target T1, T2, T3 -WaitMinutes 15` reports rows, the newest sample, and the lag per target |
| **Performance**'s problem panels (**High CPU resources over time**, **High CPU resource details**, **CPU spikes over time**, **Databases limited by service tier**) say "No results found" or "No Rows To Show", while the other charts have data | No target had that problem in the time range: the `baseline` profile never causes one, the profile is `off`, or the next [hourly incident](#the-hourly-incidents-business-day) or showcase beat hasn't started or arrived yet | Widen the range to the last hour. `./scripts/status.ps1` says each target's profile (`STATUS.PROFILE_*`). In a Run all session, the guide says when the next beat on that target starts; without Run all, start one now with `./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25`, and come back to it a few minutes later | Use Run all, whose showcase brings its own incidents; or, without it, `business-day`, the default: remove `activityProfile` from the configuration, or set it to `business-day`, and start the session at least an hour after `start-demo.ps1` |
| T3 shows gaps or no data, or the agent says there's no data for it | Serverless auto-pause: no sessions for `t3AutoPauseMinutes` (15 by default), so it sends nothing while paused ([serverless auto-pause and auto-resume](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume)) | `Invoke-DemoT3WarmUp -Config $config` resumes it and reports how long that took; without Run all, you can also set T3's profile back to the baseline with `./scripts/demo-control.ps1 -Target T3 -Scenario baseline -Duration 240`. Both run from `sqlvm01`, which must be running. Telemetry follows a few minutes later | Start the baseline earlier next time, and keep its profile on until the session ends |
| T3 doesn't exist | It was removed with `stop-demo.ps1 -RemoveT3` | Use T1 for the agent beat, and say why | `./scripts/start-demo.ps1` recreates it (about 10 more minutes), and its readiness gate reports a **Warning** with the measured lag. Keep T3 between agent-focused demos |
| `sqlvm01` or `archost01` is deallocated, runner commands fail, and T1 or T2 telemetry is stale | The nightly auto-shutdown, or the nightly safety stop at the same time: `autoShutdownTime` (19:00 by default) in `autoShutdownTimeZone` ([auto-shutdown a VM](https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm)) | Start the demo again: Run all, or `./scripts/start-demo.ps1`, which starts the VMs and sets the configured profile, because the VMs don't set one when they boot. `start-demo.ps1` sets every target's profile, so stage a running incident again afterward. Telemetry follows a few minutes later; present the other targets meanwhile | VMs started after that day's shutdown time keep running, and keep T3 awake, until the next day's shutdown: always run the [after-the-session](#after-the-session) steps |
| T2 is missing from **Estate**; `HUB.ESTATE.T2` or `TELEMETRY.T2` is **Manual action required**; the host's state is `ManualActionRequired` with the step `SqlSetupWizard` | An environment from before 2026-11-09 whose `PaygWizard` setup wizard was never finished | Present T1 and T3, and disclose that T2 isn't set up | After the session, run `./scripts/deploy.ps1`: it makes T2 again from Arc Jumpstart's image with no person, about 27 minutes plus about 33 for Arc onboarding ([deployment](deployment.md#an-older-demo-a-plain-deployps1-upgrades-it-2026-11-09)). Don't finish the setup wizard by hand |
| T1 shows Analysis Services or Integration Services next to its database engine; `T1.SQLVM.ASSOCIATEDSERVICES` is a **Warning** | The Marketplace image installs them; T1's `AssociatedServices` bootstrap step removes them, and unified inventory dropped them about 6 minutes after a clean uninstall in the live run | Say the image installs them and the demo uses only the engine | On a VM whose bootstrap predates that step, `./scripts/deploy.ps1 -FromStage Artifacts` delivers the current bundle and starts a new bootstrap generation (`-Resume` only continues after the last recorded stage). Then `./scripts/status.ps1` reports the check again |
| `T2.ARC.DISCONNECTEDDAYS` is a **Warning** (21 days or more) or a **Fail** (more than 30) | The T2 host stayed deallocated for weeks | Present T1 and T3 | Start the host, run `./scripts/configure-arc.ps1`, and read the [Arc FAQ](https://learn.microsoft.com/sql/sql-server/azure-arc/faq) on pay-as-you-go billing after more than 30 days offline |
| **Ask Copilot** isn't there, Copilot declines the target, or there's no answer after about three minutes | Copilot's tenant settings aren't on for you (a Fabric administrator turns them on), or the preview's coverage or latency, which aren't documented | Say so plainly, then use plan B or C from [Pick the targets](#pick-the-targets-for-the-agent-beats), or the [fallback ladder](#the-ladder) | Record the date, target, status, and latency in the [live coverage record](../fabric/agent/README.md#live-coverage-record) |
| The agent or Copilot proposes a change | Expected: that's the approval beat | Read it aloud, name the approver, and don't apply it. The beat ends at its time limit; without Run all, use the demo's own control | Nothing; never approve during a demo |
| No issue or finding appears for the incident target | Findings can come from agents, alerts, resource metadata, or telemetry, and their timing isn't documented | Investigate from **Performance** and Copilot instead of **Issue Details** | Note the observed delay in the coverage record (*verify in rehearsal*) |
| Security findings are missing for T3 | A newly created T3 shows posture findings late, or that assessment isn't available | Show the findings for T1 or T2, or open the T3 server in the Azure portal | Keep T3 between demos |
| **Open in SSMS** or a VS Code link doesn't connect | No SQL endpoint is reachable from outside the demo's virtual network | Stay in Database Hub and the telemetry | Use Bastion only if you need query-level evidence |
| An incident didn't start: `status --json` shows no run | A run of the same scenario is already running, the database already has four runs, the free-space check refused it, `--not-after` is too close, or the VM that carries the command is off | Use the guide's next beat (or, without Run all, the `business-day` profile's next incident), or another target | Read the runner's message, run `./scripts/reset-demo.ps1 -Target <T1 to T5>`, and start it again |
| An incident won't stop | A stop request is pending, or a session is stuck | The runner's `stop --scenario <scenario>` on the target, which keeps its profile, or `stop --all`, which also sets the profile to off (in a Run all session, that ends the target's showcase), as in the [commands for every scenario](#commands-for-every-scenario); then `./scripts/reset-demo.ps1 -Target <T1 to T5>` | Nothing: 60 seconds after its deadline the watchdog cancels the run, and 15 seconds later it kills that run's sessions only |
| Database Hub doesn't load, or shows nothing at all | The tenant setting is off, My workspace is on a capacity in North Europe or West Europe, the presenter lacks Reader, or the wrong account is signed in ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)) | Switch to the presenter account you checked the day before, or to the fallback | `./scripts/configure-fabric.ps1 -SkipNotebookImport` run by a Fabric administrator (P4), and Reader for the presenter (P8) |
| The notebook won't open or run, or Run all doesn't start: the workspace's capacity is paused | Your Fabric capacity is paused (`FABRIC.P5.CAPACITY` is **Manual action required**), and Run all never resumes it | Use [beat 9](#beat-9-26002900-the-notebooks)'s fallback: `Test-DemoHubTelemetry -Detail` and the printed KQL. Don't resume the capacity or import anything on stage: it takes minutes | You, or the capacity's administrator, resume it in the Azure portal before Run all, and pause it after ([pause and resume your Fabric capacity](https://learn.microsoft.com/fabric/enterprise/pause-resume)). `deploy.ps1` imports the notebooks; a missing one comes back with `./scripts/deploy.ps1`, or with `./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook <name> -WhatIf`, then without `-WhatIf` |
| **Create SQL monitors from template** is missing, or its dashboard can't be saved | A preview UI change; no workspace you can write to on a running capacity; or a paused capacity | Open the dashboard you made in rehearsal, or `RTD_DatabaseHub_LiveView`; say the wizard builds the same kind of dashboard. Without a capacity, show **Performance** and move on to beat 6 | Check `FABRIC.P5.WORKSPACE` and `FABRIC.P5.CAPACITY`, and note what the wizard showed in the rehearsal notes |
| `RTD_DatabaseHub_LiveView` shows empty tiles, or **No data** on **Estate pulse** | The time range has no telemetry for that target, the viewer lacks Reader on the subscription (the dashboard queries as the viewer), or the data source didn't accept the telemetry endpoint (*verify in rehearsal*) | Widen the range, set **Target** to all, or show **Performance** in Database Hub instead | Reader for the viewer (P8, `Set-DemoPresenterAccess`); `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -CheckDashboardData` says which tiles are empty and why; `-ImportDashboard` instead of `-CheckDashboardData` restores the committed definition ([Real-Time Dashboard as code](../fabric/realtime/README.md#check-the-data)) |
| The notebook can't query telemetry: its **Telemetry access** check (`HUB.TELEMETRY.TOKEN` in the deployment notebook) is **Manual action required** | The endpoint didn't accept the notebook's `kusto` token. It did on 2026-10-21 (R29 closed), but that path is undocumented | Run the printed KQL in the Azure Data Explorer web UI | Record the result in [ADR 0014](adr/0014-notebook-role-and-capacity.md) |
| Activity stopped on its own near the end of the day | Profiles end 2 minutes before the next auto-shutdown, or earlier when their duration runs out: the session's end for Run all, 8 hours for the profile that `start-demo.ps1` sets, and `-Duration` for `demo-control.ps1` | Expected. Without Run all, to keep going, set it again with `./scripts/demo-control.ps1 -Target <T1 to T5> -Scenario business-day -Duration 240`, or `-Scenario baseline` for the steady mix only | Schedule sessions to end at least 15 minutes before the auto-shutdown |
| Bastion is still there after the session | It was created for the T-SQL path, or by an earlier guided stop, and not removed | Remove it: `./scripts/stop-demo.ps1 -RemoveBastionOnly` | `status.ps1` reports Bastion and its public IP as a **Warning** while either exists. With the schedules on (`DBHUB_SCHEDULES_ENABLED`), the hourly `bastion-cleanup.yml` removes it after `bastionMaxHours` (4 by default) |
| **Read replica lag** is empty, Estate has no `pgreplica01-<deploymentId>`, or `incident:replica-lag` isn't sent (`CONTROL.T4` says why) | This session has no read replica: `-SkipT4Replica`, a size Azure refused (`START.T4.REPLICA` says so), a notebook run with `MODE = "activities"`, a Burstable T4, or an environment deployed before the replica that `deploy.ps1` hasn't upgraded yet | Say the replica isn't part of this session, and show T4's own PostgreSQL dashboard | The next Run all or `./scripts/start-demo.ps1` creates it (about 9 minutes); for an older environment, `./scripts/deploy.ps1` first ([troubleshooting](troubleshooting.md#t4s-read-replica)) |

## After the session

**After a Run all session,** there's nothing to do: Run all stopped everything and saved the session's history, and `./scripts/status.ps1` shows it (step 4). Pause your Fabric capacity when nothing else needs it. The steps below are for a session without Run all, or one that Run all didn't end.

1. **Leave the targets clean, and turn the activity off,** while the VMs still run:

   ```powershell
   ./scripts/reset-demo.ps1
   ```

   On every target, it stops every scenario and profile, kills leftover `ContosoCare.Demo/` sessions, verifies that no demo transaction is open, empties the scratch tables, and sets the activity profile to `off` (`RESET.T1` to `RESET.T5`). Where someone applied the missing-index fix, add `-UndoRemediation`, for example `./scripts/reset-demo.ps1 -Target T2 -UndoRemediation`.
   - **Why off matters:** while an activity profile runs on T3, its sessions keep the serverless database awake, and its compute bills every hour ([ADR 0016](adr/0016-cost-profiles.md)). Resetting T3 resumes it if it was paused; with its profile off, it pauses again `t3AutoPauseMinutes` (15 by default) after its last session.
2. **Stop the demo,** unless another session follows soon: `./scripts/stop-demo.ps1`. It removes Bastion and its public IP, rotates the T2 host's one-time password if one was set, sets every activity profile to `off`, shuts the T2 guest down cleanly, deallocates `archost01` and `sqlvm01`, and deletes T5's container (`STOP.T5`), which the next session creates again. T3 persists, and serverless auto-pause stops its compute.
   - **It stops on time, even mid-incident:** it waits at most about 3 minutes for both VMs at once to turn the profiles off, then deallocates anyway; a VM that didn't answer in time gets a **Warning** that says it was deallocated anyway, which stopped the incident with it. The T2 guest's clean shutdown has the same bound; when it runs out, also when the host stays busy until then, the host's deallocation shuts the guest down through its automatic stop action.
   - `-ParkT2` stops only the T2 side, for sessions that use T1 and T3.
   - `-RemoveT3` also deletes T3 until the next start. Use it only between long gaps, never before an agent-focused or multi-day baseline-versus-incident demo ([Keep T3 between demos](#keep-t3-between-demos-for-agent-focused-sessions)).
   - It deletes T4's read replica and stops T4, so neither bills compute between sessions. Add `-SaveHistory` to keep the session's PostgreSQL metrics, the replica's lag included, in the history first: a deleted replica's metrics are gone. With the Fabric capacity paused, they're kept in `out/history-pending` instead, and `STOP.T4.HISTORY.PENDING` gives the command that adds them once it runs.
   - With the optional GitHub schedules on (`DBHUB_SCHEDULES_ENABLED`, for maintainers), `schedule-stop.yml` runs the same stop every night, at 01:00 UTC unless you edit its cron for your time zone.
3. **Confirm Bastion is gone.** It's the easiest thing to forget, because neither the nightly auto-shutdown nor the nightly safety stop touches it. `./scripts/stop-demo.ps1 -RemoveBastionOnly` removes only Bastion and its public IP, and rotates the host password.
4. **Check the state and the cost:** `./scripts/status.ps1` reports the power states (`STATUS.VM_*`), Bastion and its public IP (`STATUS.BASTION`, a **Warning** while either exists), T3's state, the next auto-shutdown, the nightly safety stop's last run (`STATUS.SAFETYSTOP`), and month-to-date spend from the [Cost Management query API](https://learn.microsoft.com/rest/api/cost-management/query/usage) against `monthlyCeilingUsd` (`STATUS.COST`). [Cost analysis](https://learn.microsoft.com/azure/cost-management-billing/costs/quick-acm-cost-analysis) in the Azure portal, scoped to the demo resource group, breaks the same spend down by resource.
   - **The ceilings:** $20 a session (`sessionCeilingUsd`, a **Warning** above it) and $415 a month for a new configuration (`monthlyCeilingUsd`, a hard ceiling: preflight fails above it; a configuration keeps its own value); [cost management](cost-management.md#at-a-glance). The month must stay below `monthlyCeilingUsd`, and the budget alerts at 50%, 80%, and 100% of it. Your Fabric capacity, Fabric and Power BI licenses, and each viewer's GitHub Copilot plan aren't in this spend or in any estimate.
   - If month-to-date spend grew by more than the session estimate, something ran longer than planned: usually Bastion, an evening start that ran until the next day's shutdown, or a T3 profile left on.
5. **Record what happened:** the date, the targets the agent covered, the latency, and any action it offered, in the [live coverage record](../fabric/agent/README.md#live-coverage-record); the beat timings; and every *verify in rehearsal* item you settled. Run all saves the session's history itself, past the telemetry's 7-day retention; without Run all, `./scripts/stop-demo.ps1 -SaveHistory` does (step 2).
6. **The wizard's dashboard** (30-minute version): keep it for the next session, or delete it from the workspace yourself. It's a manual step: nothing in the repo created it, so nothing removes it. `RTD_DatabaseHub_LiveView` stays in the workspace between sessions. `destroy.ps1` deletes the demo's workspace only when everything in it is the demo's, so a wizard's dashboard saved there keeps the workspace, and everything in it, until you delete that dashboard.

## Sources (checked 2026-10-20)

Every page below was read on 2026-10-20, except the rows marked *checked 2026-10-21*, which were added when this walkthrough was aligned with Phase 13 Milestone B and the live state on 2026-10-21. The rows marked *checked again 2026-10-21* were read again then. "Updated" is the page's own update date on Microsoft Learn.

| Page | What this walkthrough relies on | Updated |
|---|---|---|
| [Database Agents](https://learn.microsoft.com/fabric/database/hub/database-agents), [enable Database Agents](https://learn.microsoft.com/fabric/database/hub/enable-database-agents), [review a Database Agents issue](https://learn.microsoft.com/fabric/database/hub/review-performance-issue) | The Database Agent loop: Azure SQL Database in Database Hub, **Manage agents**, **Agent policy**, the 15-minute issue, Explain why and Analyze slow query, the manual response, and the issue's close (*checked 2026-11-18*) | 2026-11-17 |
| [Migration assessment for SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/migration-assessment) | T2's migration assessment: free, weekly, and its readiness per Azure target (*checked 2026-11-18*) | 2026-10-19 |
| [Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview) | General availability, a Fabric Free license and no capacity (*checked again 2026-11-18*); Overview, Estate, and Performance; agents and the operator review of their findings; the agent skills and the Learn MCP server; supported services; the **Enable Performance Monitoring** option; North and West Europe capacities; Resource Graph discovery | 2026-10-17 |
| [Database Hub FAQ](https://learn.microsoft.com/fabric/database/hub/faq) | Actions are explicit and approved by the user; Copilot is the conversational interface and agents are the engines, with auditable proposals and no free-form execution; no capacity needed; posture and health signals for databases behind private endpoints; Azure Arc for on-premises SQL Server | 2026-10-17 |
| [Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor) | Issues and suggestions for Security, Performance, and Optimization; **Issue Details** with **Summary** and **Recommended action**; findings from agents, alerts, metadata, or telemetry; **Open in...**; saved and shared views; **Recent signal changes**; missing telemetry isn't zero | 2026-10-17 |
| [Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql) | The tenant setting; **What needs attention?**; **View: Microsoft SQL**; the SQL security assessments; **Create SQL monitors from template** and its six steps, which create a Real-Time Dashboard or a page in an existing one (*checked again 2026-10-21*); the Azure Data Explorer connection; troubleshooting | 2026-10-17 |
| [Enable performance monitoring for Microsoft SQL](https://learn.microsoft.com/fabric/database/hub/add-sql) | No extra cost; `Microsoft.Sql` registration; the extended property for Azure SQL Database; the SQL IaaS Agent feature flag; supported regions | 2026-10-17 |
| [Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry) | The endpoint, Reader access, the sample queries, the REST errors, and the agent instructions block | 2026-10-17 |
| [Enable performance monitoring for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm) | T1's feature flag and managed identity; Standard edition; how soon data arrives | 2026-10-05 |
| [Unified inventory for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/unified-inventory-sql-vm) | T1's SQL Server instance resources: each instance on the VM is its own resource, and the inventory follows instances that are added or removed (*checked again 2026-10-21*) | 2026-09-30 |
| [Monitor SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring) | T2's monitoring prerequisites (Standard or Enterprise, pay-as-you-go or Software Assurance) and the Azure portal's Performance Dashboard | 2026-10-19 |
| [SQL Server enabled by Azure Arc FAQ](https://learn.microsoft.com/sql/sql-server/azure-arc/faq) | Pay-as-you-go billing after more than 30 days offline | 2026-10-19 |
| [Install SQL Server 2022 with the Installation Wizard](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-installation-wizard-setup?view=sql-server-ver16) | The retired `PaygWizard` mode's setup-wizard step: **Use pay-as-you-go billing through Microsoft Azure** on the **Edition** page, and **Use Azure Login** on the **Azure Extension for SQL Server** page, where an existing Arc connection fills in the subscription, resource group, and region (*checked 2026-10-21*) | 2026-10-19 |
| [Evaluate Azure Arc-enabled servers on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine) | The **evaluation only** fallback: evaluation and testing purposes only | 2026-04-28 |
| [Serverless auto-pause and auto-resume](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume) | T3's auto-pause conditions and resume triggers | 2026-10-19 |
| [Azure SQL Database free offer](https://learn.microsoft.com/azure/azure-sql/database/free-offer) | The monthly allowance that resource-governance runs consume | 2026-10-19 |
| [Resource management in Azure SQL Database](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server), [`sys.dm_db_resource_stats`](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-resource-stats-azure-sql-database), [Azure SQL Database metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-sql-servers-databases-metrics) | Log-rate governance, `avg_log_write_percent`, and the Log IO percentage metric | 2026-10-19, 2026-10-19, 2026-07-31 |
| [Optimized locking](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking), [Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store) | Blocking on T3; query-level evidence | 2026-10-19 |
| [NotebookUtils credentials](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials), [Create a Real-Time Dashboard](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create) | The notebooks' token audiences; SQL monitors from a template | 2026-09-23, 2026-10-07 |
| [Pause and resume your Fabric capacity](https://learn.microsoft.com/fabric/enterprise/pause-resume) | Resuming a paused capacity in the Azure portal, which also resumes its billing (*checked 2026-10-21*) | 2026-08-14 |
| [Real-Time Dashboard permissions](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-permissions) | Beat 5: pass-through identity is the default, and sharing a dashboard doesn't grant access to its data (*checked 2026-10-21*) | 2026-08-31 |
| [Fabric licenses](https://learn.microsoft.com/fabric/enterprise/licenses) | The viewer rule for Power BI content below F64 (P11); Real-Time Dashboards aren't in its list of Power BI items, so a Free license can view them on an F capacity (*checked 2026-10-21*) | 2026-08-05 |
| [Sign in with Azure CLI at a command line](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively) | The subscription selector at `az login`: Enter keeps the current default (*checked 2026-10-21*) | 2026-10-12 |
| [Microsoft Learn MCP Server overview](https://learn.microsoft.com/training/support/mcp), [Azure Data Explorer web UI query overview](https://learn.microsoft.com/azure/data-explorer/web-ui-query-overview) | The fallback's grounding and the no-agent rung | 2026-05-22, 2025-01-21 |
| [Auto-shutdown a VM](https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm), [Bastion overview](https://learn.microsoft.com/azure/bastion/bastion-overview) | The nightly shutdown and on-demand Bastion | 2026-06-24, 2026-07-01 |
| [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices), [Cost Management query API](https://learn.microsoft.com/rest/api/cost-management/query/usage), [cost analysis quickstart](https://learn.microsoft.com/azure/cost-management-billing/costs/quick-acm-cost-analysis) | Live estimates, month-to-date spend, and the portal check | 2026-01-06, 2026-08-13, 2026-03-17 |
| [Mirroring in Fabric](https://learn.microsoft.com/fabric/mirroring/overview) | Mirroring, only as a future add-on | 2026-08-28 |

Also checked on 2026-10-20, outside Microsoft Learn: the announcement of Database Agents with the Database Hub estate view ([Azure SQL blog, 2026-09-29](https://devblogs.microsoft.com/azure-sql/whats-new-across-microsoft-sql-at-sqlcon-fabcon-europe-2026/)), and GitHub's docs for [Copilot CLI plugins](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference), [allowing and denying tools](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools), and [`workflow_dispatch`](https://docs.github.com/actions/using-workflows/events-that-trigger-workflows).
