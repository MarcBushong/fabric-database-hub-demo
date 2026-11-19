# Demo walkthrough

How to present the demo: the presenter's path with one **Run all**, the DBA moments it carries, a 15-minute and a 30-minute script, a cheat sheet for every scenario, then the rehearsal, the fallbacks, and a recovery playbook. How the demo is built, and what's automated, are in the [architecture](architecture.md) and the [automation support matrix](automation-support-matrix.md).

**Where to show it:** **Database Hub** is the live product view, and the product you're demonstrating. The **Insights app** is the demo's own operations product: what each session ran and what it caught, from the saved history. Which surface suits which audience, and what each viewer needs, is in [presentation surfaces](presentation.md).

> **Preview disclosure:** Database Hub is generally available. Copilot in Database Hub, Database Agents, alerts, SQL Server on Azure VM monitoring, unified inventory, the Arc SQL monitoring setting, the telemetry endpoint, and Fabric Apps, which the Insights app is built on, are previews, so their behavior and UI can change ([what's generally available, and what's a preview](limitations.md#preview-disclosures)). This walkthrough never promises what an AI will answer: it names the signals to look for, and every beat that depends on a preview has a fallback.

## The presenter's path

One **Run all** in the control notebook runs a whole session, and both scripts below run inside one.

**Once per deployment:**

1. **Deploy:** `./scripts/deploy.ps1`, until it ends **DONE** ([demo it yourself](../README.md#demo-it-yourself)).
2. **Optional, about 30 seconds:** select T3 in Database Hub's **Manage agents** for [the Database Agent loop](#the-database-agent-loop-on-t3). Everything else runs without it.
3. **For Ask, the Copilot chat in the Insights app:** each viewer signs in with GitHub once per browser, on their own GitHub Copilot plan ([the Copilot chat](../README.md#the-copilot-chat-in-the-insights-app)).

**Each session:**

1. **Resume your Fabric capacity** if it's paused: in the Azure portal, open the capacity and select **Resume** ([pause and resume](https://learn.microsoft.com/fabric/enterprise/pause-resume)). It runs the notebook, and Run all never resumes it (`fabric.manageCapacity` lets `start-demo.ps1` and `stop-demo.ps1` do it for a capacity that's yours alone). It bills while it runs, outside every estimate, so pause it after. Don't resume it on stage: it takes minutes. To check it from a terminal: `./scripts/configure-fabric.ps1 -SkipNotebookImport -SkipTelemetry` reports `FABRIC.P5.CAPACITY` **Pass** when it's Active (P5).
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
- **End early:** `STOP_NOW = True`, then Run all. The session's history is still saved. From a PC: `./scripts/stop-demo.ps1 -SaveHistory`.
- **Reset:** `RESET_NOW = True`, then Run all, resets the targets whose VM runs; `./scripts/reset-demo.ps1` does the same from a PC. Either unforces T3's plan and puts back anything a run left, T5's storm documents included.

**Repeat:** every Run all repeats the moments. The agent raises a new issue each session (closed ones stay in its history), and T5's storm upserts a fixed set of 100 documents and deletes them when it ends, however it ends, so every session's storm starts from the same data.

**During a Run all session, don't run `./scripts/demo-control.ps1` on a target:** it replaces that target's showcase, and on T3 it ends the Database Agent loop. The scripts below take their incidents from the session's own beats.

**Without the session control's roles,** Run all can't start a session, until an Owner runs `./scripts/grant-safety-stop.ps1` once. Meanwhile, run the session from a PC: `./scripts/start-demo.ps1`, then `./scripts/stop-demo.ps1 -SaveHistory` ([without Run all](#without-run-all-the-powershell-path)).

## The DBA moments in a Run all session

**Run all** in `NB_DatabaseHub_Control` carries four moments a DBA audience remembers. They need nothing beyond the session (the Database Agent loop also needs T3's optional selection), and the guide gives each one's time.

### Open at Overview

1. **Show:** [Database Hub](https://app.fabric.microsoft.com/workloads/fdh/databaseHub) on **Overview**: **What needs attention**, then **Recent signal changes**. Say: "One place for the whole estate: what needs attention now, and what changed."
2. **Ask Copilot** the three starting questions in [overview.in-hub](../fabric/agent/prompts/overview.in-hub.md): "What changed in my databases?", "Which resource should I investigate next?", and "Which security findings should I address first?". Copilot runs on the workspace's Fabric capacity; Database Hub's own pages need none.
3. **If it isn't there:** read the two Overview cards aloud and open the first resource; Copilot answers from the same signals.

### Optimization: T2 ready to migrate

Database Hub's **Optimization** insights list resources whose migration assessment is ready, license-model opportunities such as pay-as-you-go, and SQL Server instances that don't report usage ([announcement](https://techcommunity.microsoft.com/blog/azuresqlblog/database-hub-in-microsoft-fabric-is-generally-available-your-entire-database-est/4574212)). License and usage findings are issues, which Overview's **Optimization** card counts; a ready migration assessment isn't, so T2 doesn't add to that count.

1. **Show:** Overview's **Optimization** card (scroll down), or **Estate** with **View: Microsoft SQL**, then T2 (`arcsql01`). Its assessment has so far been **Ready** for Azure SQL Managed Instance and SQL Server on Azure Virtual Machines, and **Not ready** for Azure SQL Database; where Database Hub's pages show it isn't documented, so rehearse this step once.
2. **Do:** open the assessment: each Azure target's readiness, and the recommended target with its size and monthly cost. The Azure portal always has it: `arcsql01` (SQL Server - Azure Arc), **Migration**, **Assessments**, and the **Recommended Target** banner ([migration assessment](https://learn.microsoft.com/sql/sql-server/azure-arc/migration-assessment)).
3. **Say:** "This server is on-premises, connected through Azure Arc. Azure has already assessed it for migration, at no charge, and says where it's ready to go and at what size. The Azure extension for SQL Server runs the assessment every week." About licenses: "T1 and T2 show no license-model finding: they already use pay-as-you-go, Arc by the hour for T2, and T1's Marketplace image includes its license."
4. **How it gets there:** every `deploy.ps1`, and `configure-arc.ps1`, turn the assessment on and start its first run, which uploads about 6 minutes later; then it runs every Sunday at 23:00 on the server's clock, free. `T2.ARC.MIGRATIONASSESSMENT` is **Pass** once one has uploaded, and a **Warning** until then or when anything about it fails, never a failure ([the fix](troubleshooting.md#t2-arc-and-the-guest)).
5. **If it isn't there:** `./scripts/validate.ps1 -Area T2` says whether and when it uploaded; the portal's **Assessments** page has the same assessment.

### The Database Agent loop on T3

The agent's issue, Copilot's analysis of it, a manual response, and the issue closing, in one session. Database Agents detects and investigates without an LLM, explains with Copilot, and applies no change itself ("All scenarios require a manual response"), so the showcase makes the response, the way a DBA would ([Database Agents](https://learn.microsoft.com/fabric/database/hub/database-agents)).

**Optional, once per deployment, about 30 seconds.** Database Agents has no API, so no script can do it; `deploy.ps1` lists it under **Please confirm**, with the link and the exact database (`HUB.AGENT.T3`). Without it, the regression, the response, and T3's CPU drop still run, but Database Agents raises no issue:

1. Open Database Hub, select **Manage agents** (upper left), then **Database agent settings**, and turn **Enabled** on.
2. Select T3's database, `azuresql01-<deploymentId>/ContosoCare`; under **Agent policy**, turn on **Flag long-running queries**, **Force last known good plans**, and **Flag high CPU**; select **Apply**, then **Save**. The green **Database agent is active** message confirms it ([enable Database Agents](https://learn.microsoft.com/fabric/database/hub/enable-database-agents)).
3. Do it while T3 is awake: right after `deploy.ps1`, or during a session. Saving needs Azure write access on T3 (the account that deployed the demo has it, and `T3.AGENT` checks yours), and T3 must be in the region associated with your Fabric tenant's home region. The selection stays across sessions and upgrades; recreating T3 (`stop-demo.ps1 -RemoveT3`) needs it again.

**In every session** (in a 90-minute session the beat runs from about 30 to 60 minutes after T3's activity starts; a session of 60 minutes or more has the whole beat):

| When | What happens | What you do |
|---|---|---|
| 3 minutes into the beat | T3's lookup regresses to a scanning plan, and T3's CPU climbs. `FORCE_LAST_GOOD_PLAN` is held off, so automatic tuning doesn't fix it first | Show T3's CPU on **Performance** or the Real-Time Dashboard |
| About 15 minutes later | Database Agents raises an issue on T3, a new one each session | Open it from Database Hub's issue list. In **Recommended action**, select **Explain why**, then **Analyze slow query** beneath the captured query ([review an issue](https://learn.microsoft.com/fabric/database/hub/review-performance-issue)) |
| At 85% of the beat | **Respond:** Run all's T3 run forces the last good plan through Query Store, the issue's manual response, and turns `FORCE_LAST_GOOD_PLAN` back on. The notebook prints "Now: T3 Respond" | Say: "The agent investigated and recommended. A person decided, and the runbook made the change." |
| A few minutes after that | T3's CPU falls, and the notebook compares T3's CPU before and after the response (**Pass**, or a **Warning** that says why) | Show the drop. The issue closes when the agent sees the condition cleared; or close it yourself once you've checked, as Learn says |

- **What it looked like live** (2026-11-19, `lowest-cost`, T3 at 2 vCores): the lookup regressed 3 minutes into the beat, and T3's CPU in Azure Monitor went from 8% to 99% and stayed there for 21 minutes, with no automatic correction. At 85%, the response forced the plan automatic tuning recommended, and T3's CPU fell to 7% the next minute. Database Hub's telemetry shows the same drop 3 to 15 minutes later.
- **Say:** "That's the whole loop: the agent detects and investigates, Copilot explains, a person decides the response, and the agent tracks the issue to its close."
- **If it isn't there:** no issue after about 20 minutes means T3 isn't selected or the agent isn't active: check the green message, and `./scripts/validate.ps1 -Area T3` (`T3.AGENT`). **Explain why** and **Analyze slow query** need the capacity's Copilot. The regression still shows on **Performance**, and [plan-regression.in-hub](../fabric/agent/prompts/plan-regression.in-hub.md)'s prompts work in Copilot.
- **Afterward:** `./scripts/status.ps1` shows `FORCE_LAST_GOOD_PLAN` (`STATUS.T3.AUTOTUNING`). Every way a session ends puts it back: the response, the beat's end, reset, a cancel, a newer Run all, Stop now, `stop-demo.ps1`, and, after the nightly safety stop, the next run on T3; `deploy.ps1` does too ([plan regression](../scenarios/plan-regression/README.md)). Once the history is saved, the history report and the Insights app have the beat's `database_agent` finding: T3's CPU before and after the response, **Pass** when it fell.

### T5: Azure Cosmos DB's RU storm

One hot partition uses up T5's 400 RU/s, Database Hub shows normalized RU at 100% with throttled requests (429s), and both recover when the storm ends ([ADR 0027](adr/0027-t5-cosmos-db.md)). Nothing to sign in to or set up: T1's managed identity has T5's data-plane role, and Database Hub reads T5's Azure Monitor metrics with your Reader access. T1's runner drives T5, so `sqlvm01` must be running.

**In every session,** the showcase runs `ru-storm` at minutes 3 (for 10 minutes) and 18 (for 8) of each 30-minute cycle, with T5's baseline to the session's end; a storm that couldn't end at least 2 minutes before then doesn't start, so none runs when the session ends.

**Its container,** with its 400 RU/s, exists only during a session: Run all and `./scripts/start-demo.ps1` create it in about a minute, and the stops delete it, so every session starts from the same empty container, and only T5's private endpoint and DNS zone bill between sessions. Until the session control's role can create it again, it stays between sessions and bills all month unless the subscription's free tier covers it: `DEPLOY.T5.LIFECYCLE` says which, and the fix is an Owner's `./scripts/grant-safety-stop.ps1`, once, or an Owner's `./scripts/deploy.ps1` ([cost](cost-management.md#t5-azure-cosmos-db-2026-11-18)).

1. **Show:** **Estate**, filtered to Azure Cosmos DB, then `cosmos01-<deploymentId>` and **Performance**: **Normalized RU Consumption** at 100% and **Throttled Requests (429s)** climbing in the storm's waves, with **Total Request Units** flat at about 400 RU/s, the **Provisioned Throughput** line. The charts use an hourly grain, so look at the storm's hour, a few minutes after its first wave (*verify in rehearsal*).
2. **Say:** "A bedside-monitor integration is stuck in a retry loop and hammering one patient's records. Cosmos DB rate-limits it to protect everyone else's throughput: a 429 isn't an outage, and **Availability** stays at 100%. The fix is the data model, a partition key that spreads the writes, not a bigger bill."
3. **The recovery:** between the waves and after the storm, normalized RU falls back to the baseline's few percent and the 429s stop.
4. **If asked about the fix:** a per-device or synthetic partition key spreads the writes; a retry policy honors `x-ms-retry-after-ms`, as the runner does; and more RU/s or autoscale only when the load is real. T5's **Security** passes Microsoft Entra only and no public network access; customer-managed keys stay a suggestion.
5. **If it isn't there:** `./scripts/status.ps1` (`STATUS.T5`) gives the last 15 minutes' peak normalized RU and 429s from Azure Monitor; `./scripts/validate.ps1 -Area T5` shows `T5.ACCOUNT` to `T5.ACCESS` and `METRICS.T5` (requests in the last 15 minutes) **Pass**, and `T5.CONTAINER` is a **Pass** between sessions, when the container isn't there.
6. **Afterward:** Run all's end, or `./scripts/stop-demo.ps1 -SaveHistory`, saves T5's peak normalized RU, requests, 429s, and request units to the history, with a `cosmosdb.T5.recovery` finding (**Pass** when T5 was back at its baseline before the capture ended), then deletes the container.

## Demo it yourself: the Insights app

Anyone who deploys the demo shows the Insights app, `APP_DatabaseHub_Insights` (Fabric Apps, a preview), with nothing to set up in it ([the app's guide](../fabric/app/README.md#demo-it-yourself)). Open it from its item in the demo's workspace once the session's history is saved, about 15 minutes after the session's end; before the first session it says **No history yet**.

1. **Overview's Live now:** Database Hub's own view of the estate: its resources, high usage in the last 24 hours, security warnings, and Cosmos DB. **Say:** "One console for the estate: what Database Hub sees now, and under it, what the history kept."
2. **Drill down:** a target's health tile opens its page; on T3, **Ask why** on the CPU peak asks Copilot about it, with the rows and the DAX behind them.
3. **Incidents:** T3's plan-regression window, its replay, then **From signal to fix**: detect, the evidence, the response (the last good plan forced at the beat's 85%), and T3's CPU before and after it. **Say:** "The agent detected and investigated, a person decided, the runbook responded, and here's the proof it worked."
4. **T5 and T2:** **Estate**, then T5: the storm's waves, the 429s, and the recovery. **Findings**, **Optimization**: `arcsql01`'s readiness for each Azure SQL target, with **Ask Copilot** ("Which of my servers can move to Azure, and to what?").
5. **Ask, the Copilot chat,** on any visual, with what's on screen, after a GitHub sign-in once per browser, on your own GitHub Copilot plan ([the Copilot chat](../README.md#the-copilot-chat-in-the-insights-app)). **Manage:** **Reset** or **Start a session** (which bills) says what it will do and asks first; an operator's request goes to the session control, and otherwise the app copies the request for Run all.

**If it isn't there:** **Live · unavailable** means the app's live function isn't deployed: the pages show the history, and Database Hub has the live view. No T5 means the deployment has no Cosmos DB. An empty agent loop means the history isn't saved yet; an empty **Readiness**, that no session has run yet (each Run all runs `NB_DatabaseHub_Deployment`'s read-only checks, which fill it).

## How the scripts are written

- **Two versions,** both inside a Run all session and both on the three SQL targets; add [T5's RU storm](#t5-azure-cosmos-dbs-ru-storm) or T4's [read replica lag](#read-replica-lag-t4) when time allows, and rehearse them [the day before](#the-day-before).
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
- **Markers:** *verify in rehearsal* means Microsoft Learn doesn't document it, so check it in your tenant first. **Evaluation only** marks the T2 fallback that runs the Arc agent on an Azure VM: say it every time it's on screen ([label T2 honestly](#label-t2-honestly)).
- **Statuses** are the repo's six ([ADR 0012](adr/0012-validation-model.md)), and a deployment that succeeded is never a **Pass** on its own. Costs come from `./scripts/estimate-cost.ps1` on the day ([cost management](cost-management.md#at-a-glance)), and commands use placeholders such as `<tenantId>`.

## The 15-minute script

One estate, performance, an incident, and Copilot's investigation with human approval. Start Run all about 30 minutes before, and take the incident from the guide's beats, such as T3's locking and blocking (minutes 13 to 23 of the first and third cycles) or T1's blocking chain (0 to 10 of every cycle); stage nothing, and show no notebook. Without Run all, [stage it](#10-minutes-before-stage-the-incident-15-minute-version) first.

| Time | Beat | Where |
|---|---|---|
| 0:00–3:00 | 1. One estate | Database Hub **Overview**, then **Estate** |
| 3:00–6:00 | 2. Performance | **Performance** |
| 6:00–9:00 | 3. The incident | **Performance**, then the target in **Estate** |
| 9:00–14:00 | 4. Copilot investigates, with human approval | Copilot in Database Hub |
| 14:00–15:00 | Close | Back to **Overview** |

### Beat 1 (0:00–3:00): one estate

- **Say:** "Contoso Care runs SQL in three places: SQL Server on an Azure VM, an on-premises SQL Server, and Azure SQL Database, each with its own portal and tools, so every investigation starts with switching tools."
- **Show:** [Database Hub](https://app.fabric.microsoft.com/workloads/fdh/databaseHub) **Overview** (**What needs attention?**, **Recent signal changes**, the **Optimization** card), then **Estate** with **View: Microsoft SQL** and the demo resource group ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)).
- **Say:** "One inventory across all three, and nothing moved: Database Hub uses my own Microsoft Entra ID and Azure permissions. It's generally available, and free with a Fabric Free license." ([overview](https://learn.microsoft.com/fabric/database/hub/overview), [FAQ](https://learn.microsoft.com/fabric/database/hub/faq)) About T2: "This on-premises server is simulated: a Hyper-V guest inside an Azure VM, connected through Azure Arc" (or **evaluation only**, in the fallback mode).
- **Look for:** `sqlvm01` (its database engine only), `arcsql01`, and `ContosoCare` on `azuresql01-<deploymentId>`, with issue chips and lightbulb suggestion chips; behind them, Azure Resource Graph (`HUB.ESTATE.T1`–`T3`) and `T1.SQLVM.ASSOCIATEDSERVICES` **Pass** ([unified inventory](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/unified-inventory-sql-vm)).
- **If it isn't there:** T2 not ready yet (`HUB.ESTATE.T2` isn't **Pass**): say so and show T1 and T3, never a missing target as healthy. T1 listing Analysis Services or Integration Services (a **Warning**): the image installs them, and the demo removes them. Others: the [recovery playbook](#recovery-playbook).
- **Reset:** Nothing to reset: the beat only reads.
- **Why it matters:** a consistent hybrid inventory: every SQL estate in one list, wherever it runs, through each person's own permissions.
- **Screenshot:** `docs/images/walkthrough/15-beat-1-estate.png` (planned): **Estate** with **View: Microsoft SQL**, showing the three targets and their chips.

### Beat 2 (3:00–6:00): performance

- **Show:** **Performance**, the **Microsoft SQL** dashboard, the last hour, the three servers: **Recent signal changes**, then CPU, memory, and storage ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Say:** "This is the last hour: a front desk, billing, and scheduling baseline on all three, with a few bounded problems on top. On Azure SQL Database, CPU is a percentage of the tier's limit." At a gap: "No data isn't zero and isn't healthy: this serverless database pauses when idle." Mention that **Create SQL monitors from template** turns this view into a dashboard; the 30-minute version runs it.
- **Look for:** the baseline (low `SqlServerCPUUtilization`, steady `Batch Requests/sec`, `Processes blocked` at 0; [healthy baseline](../scenarios/healthy-baseline/README.md)) with the session's beats above it, such as T2's CPU from minute 2 of each cycle. Beat 3's incident may already show at the right edge: leave it for beat 3.
- **If it isn't there:** show the other targets and say telemetry arrives a few minutes behind; resume a paused T3 with `Invoke-DemoT3WarmUp -Config $config`. An empty page: check the range and the selection, then the rehearsal screenshot.
- **Reset:** Nothing to reset. Keep the last hour selected for beat 3.
- **Why it matters:** less tool switching: one performance view across the VM, the on-premises server, and the PaaS database.
- **Screenshot:** `docs/images/walkthrough/15-beat-2-performance.png` (planned): the **Microsoft SQL** dashboard over the last hour, with the baseline and the session's beats.

### Beat 3 (6:00–9:00): the incident

- **Say:** "A few minutes ago, a billing batch began holding row locks in an open transaction, like an application that forgot to commit. The billing clerks are blocked behind it."
- **Show:** **Performance** with the incident target, then its row in **Estate**, and **Issue Details** (**Summary**, **Recommended action**) if an issue appears; whether and when one appears isn't documented (*verify in rehearsal*) ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Look for:** `Processes blocked` above 0, Lock waits (`LCK_M_U`, `LCK_M_S`), and `Active Transactions` held open, with demo sessions behind one head blocker ([locking-blocking](../scenarios/locking-blocking/README.md), T1's [blocking chain](../scenarios/blocking-chain/README.md)). On T3, optimized locking and read committed snapshot let readers through; the clerks' updates still block ([optimized locking](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking)).
- **If it isn't there:** say "telemetry arrives a few minutes after the activity", then switch to the guide's other blocking beat, or run Learn sample queries 8 and 5 in the Azure Data Explorer web UI.
- **Reset:** Nothing to reset: the beat ends at its time limit, and the guide prints the next one. Without Run all, [stage it again](#10-minutes-before-stage-the-incident-15-minute-version).
- **Why it matters:** faster detection: the blocking surfaces in one place, before anyone signs in to the server or a user calls.
- **Screenshot:** `docs/images/walkthrough/15-beat-3-incident.png` (planned): **Performance** for the incident target leaving its baseline, and any new issue chip.

### Beat 4 (9:00–14:00): Copilot investigates, with human approval

- **Say:** "Copilot in Database Hub is a preview, presenter-driven in the UI, with no API. It answers from what Database Hub knows, within my own permissions."
- **Do:** **Ask Copilot**, top right of **Estate** or **Performance**, with the target selected ([Copilot in Database Hub](https://techcommunity.microsoft.com/blog/azuresqlblog/ask-your-database-estate-a-question-copilot-in-database-hub-is-now-in-public-pre/4572704)), and ask, with the guide's names and times, [locking-blocking.in-hub](../fabric/agent/prompts/locking-blocking.in-hub.md) prompts 1 and 3, then [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md) prompts 4 (the safest action, proposed only) and 5 (what needs approval).
- **Look for:** the target, `ContosoCare`, a UTC window that overlaps the run, a blocking signal by name, what Copilot couldn't see (such as the statement text), then a proposal and its approvals. Judge it with the prompt file's rubric.
- **The approval beat:**
  1. Read the proposal aloud: what it changes, where, and how to roll it back.
  2. Name who approves it in production, and with which permission: "Actions in Database Hub are explicit and always approved by a user who holds the permission; Database Hub then hands the execution to the authoritative service. There's no free-form execution." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
  3. **Don't apply it:** Copilot only proposes, and nobody approves an agent-proposed change in this demo ([approval rules](../fabric/agent/README.md#use-it-safely-approval-rules-for-presenters)).
  4. Let the demo's bound end the incident: it touches only `ContosoCare.Demo/` sessions in `ContosoCare`, rolls back, and ends at the time the guide prints. When your slot overlaps [the Database Agent loop](#the-database-agent-loop-on-t3), show its **Respond** step too.
- **Say:** "Copilot did the investigation and proposed a fix. A person decides."
- **If it isn't there:** no **Ask Copilot** (a Fabric administrator turns on Copilot's tenant settings), a declined target, or no answer after about three minutes: say so and go to [the ladder](#the-ladder), with [locking-blocking.skills](../fabric/agent/prompts/locking-blocking.skills.md) prompts 1 and 2 and [incident-wrap-up.skills](../fabric/agent/prompts/incident-wrap-up.skills.md) prompts 4 and 5 in GitHub Copilot CLI, and the same approval beat.
- **Reset:** Nothing to reset: the beat ends at its time limit; start a new conversation before a re-run. Without Run all, return the staged targets to the baseline ([the commands](#10-minutes-before-stage-the-incident-15-minute-version)).
- **Why it matters:** a guided investigation and human-controlled action: Copilot gathers the evidence and proposes, and a person approves before anything changes.
- **Screenshot:** `docs/images/walkthrough/15-beat-4-agent-approval.png` (planned): Copilot's answer with its evidence, and its proposal before anyone acts on it.

### Close (14:00–15:00)

- **Show:** back to **Overview**, the whole estate.
- **Say:** "Faster detection, less tool switching, one inventory across Azure, on-premises, and PaaS, a guided investigation, and a person in control of every action. Database Hub is generally available; its Copilot and Database Agents are previews."
- **Look for:** **What needs attention?** across the three targets. The incident's issue can stay open a few minutes after the beat ends, and the blocking clears in the next samples ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql), troubleshooting).
- **If it isn't there:** close on beat 1's **Estate** list or the rehearsal screenshot; the story doesn't depend on a live chart.
- **Reset:** Nothing to reset: Run all ends the session and saves its history. For a back-to-back slot, take the guide's next blocking beat; for another session, Run all again; after the last, see [after the session](#after-the-session).
- **Why it matters:** shared context: everyone leaves with the same picture of the estate, the evidence, and the decision, from faster detection to human-controlled action.
- **Screenshot:** `docs/images/walkthrough/15-close-overview.png` (planned): **Overview** at the end, with **What needs attention?** across the three targets.

## The 30-minute script

The same story, deeper, with security, a monitor from a template beside the dashboard as code, Copilot's summary, and the notebooks; your Fabric capacity runs during it (P5), and beats 5 and 9 have fallbacks that need none. Pick the incident from the beats near your beat 1 ([choose the incident](#choose-the-incident)); when your slot overlaps [the Database Agent loop](#the-database-agent-loop-on-t3), show its issue in beat 6 and its response in beat 7. Without Run all, start the incident in beat 1 ([the PowerShell path](#without-run-all-the-powershell-path)).

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

Pick a row the day before, on a target your rehearsal showed Copilot covers ([pick the targets](#pick-the-targets-for-copilots-beats)); with no live coverage record yet, plan B is a beat on T1 in the same slot. The minutes are of each target's 30-minute cycle, and the guide prints each beat's times.

| Story | The showcase's beat | When | The approval moment | The recovery to show |
|---|---|---|---|---|
| An application forgot to commit (default) | `locking-blocking` on T3, or T1's `blocking-chain` | T3: 13 to 23 in the first and third cycles; T1: 0 to 10 of every cycle | Ending the head blocker's session, approved by a DBA | `Processes blocked` back to 0; Lock waits gone |
| A bad plan on the "on-premises" server | `cpu-pressure` on T2 | 2 to 14 of every cycle | A query rewrite through change control | CPU back to the baseline |
| Too much demand for the tier | `resource-governance` on T3 | 1 to 13 in the first and fourth cycles, 5 to 15 in the third | Scaling up costs money, so a budget owner approves | CPU back under the tier limit |
| A write-heavy batch | `log-rate-pressure` on T3 | 25 to 30 in the first, third, and fourth cycles | Rescheduling the batch or changing the tier | Log writes back to the baseline |
| A missing index | `missing-index` on T3 (on T2 without Run all) | 1 to 10 in the second and fourth cycles | A person reviews and runs the index script, never the agent | Reads drop after the index; in a Run all session, describe it, because the "after" needs [a person and Bastion](#the-missing-index-fix-by-a-person) |

The showcase's other beats suit an audience that cares about one kind of wait: T1's deep blocking chain, log flushes, and deadlock storm; T2's memory grants, parallelism, and tempdb contention; T3's slow client ([cheat sheet](#per-scenario-cheat-sheet)).

### Beat 1 (0:00–3:00): frame it, and the incident on the clock

- **Say:** "Three SQL estates, three sets of tools. The workload is live, and in a few minutes a problem starts on one of them. We'll find it in Database Hub in about ten minutes, the way an operator would."
- **Do:** zoom in on the chosen beat's line and start time in the guide, so no link or ID shows; the live view prints each beat as it begins.
- **Say:** "It's bounded: one database, only sessions tagged `ContosoCare.Demo/`, and a hard maximum duration enforced three times, in T-SQL, in the runner, and by a watchdog." ([ADR 0010](adr/0010-workload-generator-technology.md))
- **Look for:** the beat's target, start, and end; within a few minutes of its start, the target's CPU, waits, or blocked processes move in the live view, and Database Hub follows a few minutes later.
- **If it isn't there:** a target with no beat in the guide had no activity start, and the notebook's steps say why, with the fix; take the same kind of beat on another target.
- **Reset:** Nothing to reset: a later cycle runs the beat again. Without Run all, start it on camera with `./scripts/demo-control.ps1` ([the commands](#10-minutes-before-stage-the-incident-15-minute-version)).
- **Why it matters:** faster detection: the clock starts now, and nobody will sign in to the server to find the problem.
- **Screenshot:** `docs/images/walkthrough/30-beat-1-start-incident.png` (planned): the guide's line for the chosen beat, with no links, IDs, or tokens on screen.
- **Write down** the beat's start and end for `{incidentWindow}`; the guide's prompts already have this session's times.

### Beat 2 (3:00–6:00): one estate, three onboarding paths

- **Show:** **Overview**, then **Estate** with **View: Microsoft SQL**; select each resource name for its detail pane ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)). Optionally save the view (**View** > **Manage custom views** > **Save**) and share its link: "Sharing a view shares its filters, not access."
- **Say:** "Each target arrives through a documented path, and turning on performance monitoring costs nothing extra." ([Enable performance monitoring for Microsoft SQL](https://learn.microsoft.com/fabric/database/hub/add-sql))
  - **T1:** the SQL IaaS Agent extension's `DatabaseWatcheronAzureVM` feature flag, uploading with the VM's managed identity ([SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm)).
  - **T2:** Azure Arc, "the mechanism for connecting on-premises SQL Server instances to Azure" ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq)), with the instance's monitoring setting on ([Monitor SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring)): SQL Server 2022 Standard, pay-as-you-go through Arc, on a simulated on-premises server.
  - **T3:** native, through Azure Resource Graph, plus the `MS_EnablePerformanceMonitoringPreview` extended property the deployment sets; **Enable Performance Monitoring** on **Estate** is the manual alternative.
- **Look for:** each pane's resource type (SQL Server on an Azure VM, SQL Server enabled by Azure Arc, Azure SQL Database); the signals `HUB.ESTATE.T1`–`T3`, `T1.SQLVM.MONITORING`, `T2.ARC.MONITORING`, `T3.PROPERTY`, and `T1.SQLVM.ASSOCIATEDSERVICES` **Pass**.
- **If it isn't there:** as in the [15-minute version](#beat-1-000300-one-estate): present T1 and T3, and say why T2 is missing.
- **Reset:** Nothing to reset: the beat only reads, and a saved view is yours to keep.
- **Why it matters:** a consistent hybrid inventory: three onboarding paths, one inventory, and no data moved.
- **Screenshot:** `docs/images/walkthrough/30-beat-2-estate-paths.png` (planned): **Estate** with one target's detail pane open.

### Beat 3 (6:00–10:00): security and posture

- **Show:** **Overview**'s **Security** issues and suggestions; an issue type, or **See affected resources**, opens **Estate** filtered to it; then a finding's **Issue Details** ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Say:** "Database Hub surfaces health and compliance signals from Azure Resource Graph metadata and SQL performance signals, so it doesn't need public connectivity to the databases, even behind a private endpoint." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq)) Then: "Each finding has a summary and a recommended action, and **Open in...** takes me to the Azure portal, where an approved change happens." Select **Open in...**, and change nothing.
- **Look for:** **Issue Details** with the assessment, the server, **Summary**, and **Recommended action**, from the SQL assessments Learn lists ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)). The demo's configuration suggests (*verify in rehearsal*):

  | Target | Assessments that apply | What to expect |
  |---|---|---|
  | T3 | Issues: Microsoft Entra Authentication Enabled, Minimum TLS version 1.2 Required, Public Network Access Disabled, Private Endpoint Enabled. Suggestions: Auditing, Encryption at rest using Customer Managed Keys, Microsoft Entra Authentication Enforced, SQL Ledger | Entra-only and TLS 1.2 by design; the two network issues in public mode only; the suggestions, unless a tenant policy adds auditing, a key, or a ledger |
  | T2 | Microsoft Entra Authentication Enabled (issue), Microsoft Entra Authentication Enforced (suggestion) | Windows authentication only, so likely the Entra issue |
  | T1 | Public Network Access Disabled (issue) | SQL connectivity is `LOCAL` and the VM has no public IP, so no issue |

- **If it isn't there:** a newly created T3 shows posture findings late ([keep T3](#the-day-before)): show T1 or T2, or the T3 server in the Azure portal. With no security summary at all, say the assessments vary by resource type, and move on.
- **Reset:** Nothing to reset: the beat changes nothing. Close the tab **Open in...** opened.
- **Why it matters:** shared context: security, platform, and database teams see the same posture findings, with the evidence, in one place.
- **Screenshot:** `docs/images/walkthrough/30-beat-3-security.png` (planned): the **Security** summary on **Overview**, and one **Issue Details** pane.

### Beat 4 (10:00–13:00): performance, before and during

- **Show:** **Performance** over the baseline and the last 15 minutes: **Recent signal changes**, then the incident target beside the other two.
- **Say:** "The same telemetry is open to KQL, Power BI, notebooks, and agents, through a documented endpoint." ([Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry))
- **Look for:** the target leaving its baseline a few minutes after the beat started, with the scenario's signals from the [cheat sheet](#per-scenario-cheat-sheet), such as `Processes blocked` above 0 for locking; whether **Recent signal changes** lists it isn't documented (*verify in rehearsal*).
- **If it isn't there:** show the other targets' baseline and the scenario's Learn sample queries in the Azure Data Explorer web UI, and come back to it in beat 5.
- **Reset:** Nothing to reset: the beat runs on, and beats 5 and 6 look at its window.
- **Why it matters:** less tool switching: before and during, side by side, for every target.
- **Screenshot:** `docs/images/walkthrough/30-beat-4-performance.png` (planned): **Performance** with the incident target over the baseline and the incident.

### Beat 5 (13:00–16:00): a monitor from a template, and the dashboard as code

- **Say:** "Database Hub can turn this view into a dashboard the on-call team keeps. Let me build one for the database in trouble, live."
- **Do:** **Create SQL monitors from template** on **Performance** ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)): the template you noted in rehearsal (Learn doesn't list them, *verify in rehearsal*), only the incident target's database, the workspace on the running capacity, and a new dashboard named for the session (or a page in the rehearsal's scratch dashboard). Open it on the last hour.
- **Show:** `RTD_DatabaseHub_LiveView`, the [dashboard as code](../fabric/realtime/README.md), on **Incident** with **Target** on the incident target; finish on **Estate pulse**, every target's freshness.
- **Say:** "The same telemetry, governed and versioned. The wizard is the fastest way to start; this one lives in Git, reviewed and tested, imported and read back through a documented Fabric API. Both query as the person looking, so sharing a dashboard doesn't share the data." ([Real-Time Dashboard permissions](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-permissions))
- **Look for:** the same minutes on both: for locking, **Processes blocked, latest sample** above 0 in red, Lock rising in **Waits by category**, **Active sessions in ContosoCare** climbing; on **Estate pulse**, **Freshness per target** green where the newest sample is at most 15 minutes old.
- **If it isn't there:** a wizard that's missing, can't save, or takes over a minute: open the rehearsal's dashboard, or only the dashboard as code. Empty tiles: check **Target** and the range; a viewer without Reader sees none ([check the data](../fabric/realtime/README.md#check-the-data)). No running capacity: don't resume it on stage; give the time to beat 6.
- **Reset:** Nothing to reset: both dashboards only read; keep or delete the wizard's afterward ([after the session](#after-the-session)). To undo edits to the dashboard as code, import it again from Git:

  ```powershell
  ./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -ImportDashboard
  ```

- **Why it matters:** shared context: a dashboard the whole team can open, built in a few clicks or kept in Git, over each viewer's own permissions.
- **Screenshot:** `docs/images/walkthrough/30-beat-5-template-dashboard.png` (planned): the wizard's dashboard beside the **Incident** page of `RTD_DatabaseHub_LiveView`.

### Beat 6 (16:00–21:00): Copilot investigates

- **Show:** a new issue's **Issue Details**, if one appeared ("Findings can come from agents, alerts, resource metadata, or telemetry"), then **Ask Copilot** with the target selected. When your slot overlaps the Database Agent loop, start from the agent's issue on T3: **Explain why**, then **Analyze slow query**.
- **Say:** "Copilot is a preview, presenter-driven in the UI, with no API, and it only proposes: every action needs a person's explicit approval."
- **Do:** ask the scenario's in-Hub prompts in order, such as [locking-blocking.in-hub](../fabric/agent/prompts/locking-blocking.in-hub.md) 1 to 3 ([which file](#per-scenario-cheat-sheet)).
- **Look for:** the prompt file's rubric: the right target and database, a UTC window that overlaps the run, the scenario's signals by name, no blame on signals that didn't move, and what Copilot couldn't see.
- **If it isn't there:** say so, then plan B or C ([pick the targets](#pick-the-targets-for-copilots-beats)) or [the ladder](#the-ladder), and record it in the [live coverage record](../fabric/agent/README.md#live-coverage-record).
- **Reset:** Nothing to reset: the prompts are read-only. Keep the conversation for beats 7 and 8.
- **Why it matters:** a guided investigation: Copilot turns an operational question into a structured investigation, and names its evidence.
- **Screenshot:** `docs/images/walkthrough/30-beat-6-agent.png` (planned): Copilot's answer, with its signals, its window, and what it couldn't see.

### Beat 7 (21:00–24:00): human approval and a bounded fix

- **Do:** ask [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md) prompts 4 and 5, then [the approval beat](#beat-4-9001400-copilot-investigates-with-human-approval): read the proposal, its scope, and its rollback, name the approver, and don't apply it, nor a recommendation that conflicts with the evidence ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql), troubleshooting).
- **Do:** show the demo's own bound instead of a fix: the beat ends at the time the guide printed. When your slot overlaps the Database Agent loop, show "Now: T3 Respond", the response a person decided. For the missing-index story, a person runs the script ([the fix](#the-missing-index-fix-by-a-person)).
- **Say:** "This is the step Database Hub keeps human: an explicit, auditable proposal, approved by someone with the permission, executed by the authoritative service." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
- **Look for:** the proposal with its scope, rollback, and approvals, then the beat's end: blocked processes and waits fall in the live view, and in Database Hub a few minutes later.
- **If it isn't there:** without a proposal, ask [incident-wrap-up.skills](../fabric/agent/prompts/incident-wrap-up.skills.md) in GitHub Copilot CLI, or describe one from the scenario's cheat sheet row. A run that doesn't end on time: the [recovery playbook](#recovery-playbook).
- **Reset:** Nothing to reset in a Run all session. After a missing-index fix, once the session is over, drop the indexes (this also turns T2's profile off):

  ```powershell
  ./scripts/reset-demo.ps1 -Target T2 -UndoRemediation
  ```

- **Why it matters:** human-controlled action: nothing changes without an explicit, auditable proposal that a person with the permission approves.
- **Screenshot:** `docs/images/walkthrough/30-beat-7-approval.png` (planned): the proposal and its approvals, before anyone acts, beside the beat's end in the guide.

### Beat 8 (24:00–26:00): Copilot explains and summarizes

- **Say:** "Copilot is the conversational interface; agents are the engines behind it. It explains and summarizes from the same scoped data and agent findings you see, and an action it recommends is backed by an explicit agent capability and an auditable proposal." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
- **Do:** ask [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md) prompts 1 (a customer-friendly root cause), 3 (the baseline against the incident), and 7 (a five-bullet summary).
- **Look for:** plain language with a confidence level, a table of the signals that moved and those that stayed flat, and exactly five bullets, none presented as decided.
- **If it isn't there:** ask the same prompts from [incident-wrap-up.skills](../fabric/agent/prompts/incident-wrap-up.skills.md), or answer them yourself from **Performance**.
- **Reset:** Nothing to reset: the prompts are read-only.
- **Why it matters:** shared context: one plain-language summary that the application team, the on-call engineer, and management read the same way.
- **Screenshot:** `docs/images/walkthrough/30-beat-8-copilot.png` (planned): Copilot's five-bullet incident summary.

### Beat 9 (26:00–29:00): the notebooks

- **Show:** `NB_DatabaseHub_LiveActivity` ([Fabric assets](../fabric/README.md)), helper cells already run, with two of its sections: 6 or 7 (**Locks and blocking**, **Overall consumption**), 8 (**Correlation**: did the window produce its signal?), 9 (**See it in the Hub**), or 11 (**Persist**: the history past the 7-day retention, which the [history report](../fabric/powerbi/README.md) reads; show that after the session).
- **Say:** "Database Hub is free and needs no capacity. These notebooks run on a Fabric capacity over the same telemetry endpoint, and the dashboard in beat 5 uses their KQL. Run all runs this one at the session's end to analyze and save; nothing drops a table unless you set `PURGE_DEMO_TABLES`."
- **Look for:** the chart with the scenario window shaded, and the correlation cell's verdict; for locking, `Processes blocked` and Lock wait deltas in the window. Its thresholds are presenter heuristics ([ADR 0014](adr/0014-notebook-role-and-capacity.md)).
- **If it isn't there:** don't resume the capacity or import notebooks on stage. Off the shared screen, read the same telemetry from the documented endpoint (incident target in `-Target` and the check ID), and share only the tables, because the evidence holds resource IDs:

  ```powershell
  $telemetry = Test-DemoHubTelemetry -Config $config -Target T3 -LookbackMinutes 30 -Detail | Where-Object -Property checkId -EQ -Value 'TELEMETRY.T3'
  $telemetry.evidence.waitCategories | ForEach-Object -Process { [pscustomobject]$_ } | Format-Table
  $telemetry.evidence.gaugeCounters | ForEach-Object -Process { [pscustomobject]$_ } | Format-Table
  Get-DemoHubTelemetryKql -Name WaitCategoryDeltas -ResourceId $telemetry.evidence.resourceId -LookbackMinutes 30
  ```

  The tables show the last 30 minutes' wait seconds per category and the blocking and load counters; the last line prints the KQL for the Azure Data Explorer web UI. The notebook's token path is undocumented: when section 4, **Telemetry access** (`HUB.TELEMETRY.TOKEN`), says **Manual action required**, each analysis cell prints its KQL to run there.
- **Reset:** Nothing to reset: the cells and the fallback only read, **Persist** again replaces this run's rows, and the notebook changes no activity.
- **Why it matters:** shared context beyond the Hub: the same telemetry in a notebook or query the team shares, with history past the 7-day retention.
- **Screenshot:** `docs/images/walkthrough/30-beat-9-notebook.png` (planned): the correlation output with the window shaded, or the fallback's two tables.

### Close (29:00–30:00): recovery and value

- **Show:** **Performance** for the incident target, back toward its baseline; the recovery may still be arriving, so say so.
- **Say:** "Faster detection, less tool switching, one hybrid inventory, shared context, a guided investigation, and human-controlled action. Database Hub is generally available; its Copilot and Database Agents are previews."
- **Look for:** for locking, `Processes blocked` back at 0 and no new Lock waits in the latest samples.
- **If it isn't there:** the **Incident** page of `RTD_DatabaseHub_LiveView`, which refreshes every minute, [beat 9](#beat-9-26002900-the-notebooks)'s fallback, or the rehearsal screenshot.
- **Reset:** Nothing to reset: a back-to-back slot starts at beat 1 with the guide's next beat, and Run all ends the session and saves its history. After the last one, see [after the session](#after-the-session).
- **Why it matters:** all six together: faster detection, less tool switching, a consistent hybrid inventory, shared context, a guided investigation, and human-controlled action.
- **Screenshot:** `docs/images/walkthrough/30-close-recovery.png` (planned): **Performance** for the incident target, back at its baseline.
- **If asked about mirroring:** "Database Hub doesn't need it; it monitors the databases where they are. Mirroring is a possible future add-on." ([ADR 0015](adr/0015-mirroring-deferral.md), [Mirroring in Fabric](https://learn.microsoft.com/fabric/mirroring/overview))

## Per-scenario cheat sheet

Every SQL scenario runs on T1, T2, and T3, apart from plan-regression (T3 only); T4 and T5 have their own. Each runs only in the demo's database (`ContosoCare`; `contosocare` on T4 and T5), on sessions tagged `ContosoCare.Demo/<scenario>/<run>`, with a hard maximum duration ([ADR 0010](adr/0010-workload-generator-technology.md)), and shows in the telemetry a few minutes after it starts. Each scenario's page has its parameters, signals, and reset ([scenarios](../scenarios/README.md)). **In a Run all session,** the showcase runs them: `demo-control.ps1` or a runner `profile set` on a target replaces that target's showcase, and on T3 it ends the Database Agent loop.

**Prompts:** each SQL scenario's are `<scenario>.in-hub.md` in [the prompt pack](../fabric/agent/prompts/README.md) (prompts 1 to 3; 1 to 4 for cpu-pressure), then [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md), with the fallback's `<scenario>.skills.md` beside them. T4's and T5's scenarios have none: show their dashboards.

| Scenario | Runs on (default first) | Default / max | Show in Database Hub |
|---|---|---|---|
| [healthy-baseline](../scenarios/healthy-baseline/README.md) | T1 to T5 | 30 min / 4 h | Steady `Batch Requests/sec` and `Transactions/sec`, low flat CPU, `Processes blocked` at 0; it keeps T3 awake |
| [locking-blocking](../scenarios/locking-blocking/README.md) | T1, T2, T3, T4 | 10 / 30 min | `Processes blocked`, Lock waits (`LCK_M_U`, `LCK_M_S`), `Active Transactions`; `deadlock=true` adds deadlocks. On T4, row-lock queues, as connections |
| [cpu-pressure](../scenarios/cpu-pressure/README.md) | T2, T1, T3, T4 | 10 / 30 min | CPU toward 100%, `SOS_SCHEDULER_YIELD`; `variant=healthy` is the "after", and the query itself is in [Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store), not the telemetry |
| [io-pressure](../scenarios/io-pressure/README.md) | T2, T1, T3, T4 | 10 / 30 min | Storage IO and stalls, `Page reads/sec`, `WRITELOG`; `PAGEIOLATCH` only past memory |
| [missing-index](../scenarios/missing-index/README.md) | T2, T1, T3, T4 | 10 / 30 min | CPU and logical reads above the baseline; [the fix](#the-missing-index-fix-by-a-person) on T1 to T3, [autonomous tuning](#t4-autonomous-tuning-in-the-azure-portal) on T4 |
| [inefficient-query](../scenarios/inefficient-query/README.md) | T2, T3, T1 | 10 / 30 min | CPU and `Batch Requests/sec` from many short requests; `variant=healthy` is the "after" |
| [resource-governance](../scenarios/resource-governance/README.md) | T3, T1, T2 | 5 / 20 min | On T3, CPU at the tier limit (**Databases limited by service tier**); it spends T3's vCore seconds and [free offer](https://learn.microsoft.com/azure/azure-sql/database/free-offer), so keep runs short |
| [log-rate-pressure](../scenarios/log-rate-pressure/README.md) | T3, T1, T2 | 5 / 15 min | On T3, `Log Rate Governor` at the [log-rate limit](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server); elsewhere, `WRITELOG` |
| [blocking-chain](../scenarios/blocking-chain/README.md) | T1, T2, T3 | 10 / 30 min | `Processes blocked` well above locking's, long Lock waits; the depth isn't in the telemetry |
| [deadlock-storm](../scenarios/deadlock-storm/README.md) | T1, T2, T3 | 10 / 30 min | `Number of Deadlocks/sec` bin after bin, `Errors/sec`; graphs in `system_health` on T1 and T2 |
| [tempdb-contention](../scenarios/tempdb-contention/README.md) | T2, T1, T3 | 10 / 30 min | `PAGELATCH_*` waits, `Temp Tables Creation Rate`; on T3, more CPU waits instead |
| [memory-grant-pressure](../scenarios/memory-grant-pressure/README.md) | T2, T1, T3 | 10 / 30 min | `RESOURCE_SEMAPHORE`, `Granted Workspace Memory (KB)` at its ceiling, a growing `MEMORYCLERK_SQLQERESERVATIONS`, `Page life expectancy` falling |
| [parallel-scans](../scenarios/parallel-scans/README.md) | T2, T1, T3 | 10 / 30 min | Parallelism waits (`CXPACKET`, `CXCONSUMER`) with high CPU; DOP 2 on T3 (*verify in rehearsal*) |
| [log-flush-waits](../scenarios/log-flush-waits/README.md) | T1, T2, T3 | 10 / 30 min | Many short `WRITELOG` waits, `Log Flushes/sec` (SQL Server only), `Log Bytes Flushed/sec` |
| [slow-consumer](../scenarios/slow-consumer/README.md) | T3 (T1's runner as the client), T1, T2 | 10 / 30 min | `ASYNC_NETWORK_IO` while CPU and IO stay flat |
| [capacity-max](../scenarios/capacity-max/README.md) | T1, T2, T3 | 10 / 20 min | CPU near 100% (the tier limit on T3), `PAGEIOLATCH_SH`, IO stalls; keep runs short on T3 |
| [plan-regression](../scenarios/plan-regression/README.md) | T3 only: SQL Server 2022 Standard has no automatic tuning ([editions](https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2022)) | 10 / 30 min | CPU steps up at the slow plan, down once [automatic tuning](https://learn.microsoft.com/azure/azure-sql/database/automatic-tuning-overview) forces the fast one; plans in Query Store. In the showcase's third cycle, and its second as [the Database Agent loop](#the-database-agent-loop-on-t3) |
| [connection-surge](../scenarios/connection-surge/README.md) | T4 only | 5 / 15 min | **Connections** at the limit (`max_connections` 50, 15 reserved), **Failed connections** above 0; not proven live ([limitations](limitations.md#targets-and-licensing)) |
| [idle-in-transaction](../scenarios/idle-in-transaction/README.md) | T4 only | 10 / 30 min | **Connections** counts the idle sessions; T4's Metrics in the Azure portal show **Sessions By State**, **Oldest Transaction**, **Sessions By WaitEventType** |
| [replica-lag](#read-replica-lag-t4) | T4 and its read replica | 10 / 15 min | **Read replica lag** on the replica |
| [ru-storm](#ru-storm-t5) | T5 only | 10 / 30 min | Normalized RU at 100%, and 429s |

### Commands for every scenario

```powershell
# One bounded incident on one target, with the baseline beside it for the incident's window.
./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25

# A scenario parameter (incidents only): demo-control.ps1 takes -Concurrency and -Intensity, but not --param.
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'profile', 'set', '--name', 'incident:cpu-pressure', '--param', 'variant=healthy', '--not-after', '{{NEXT_SHUTDOWN}}'

# Back to the baseline, for up to 240 minutes and never past the auto-shutdown; the runner stops a run within about 10 seconds.
./scripts/demo-control.ps1 -Target T2 -Scenario baseline -Duration 240

# Stop one scenario now, or everything (which also sets the profile to off).
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'stop', '--scenario', 'cpu-pressure'
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'stop', '--all'

# What's running: the profile, recent runs with their windows, live demo sessions and blocking, space headroom.
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'status', '--json'

# Back to a quiet, known state: profile off, leftover demo sessions killed, no open demo transaction, scratch tables emptied.
./scripts/reset-demo.ps1 -Target T2
```

- Any scenario fits the same commands: `incident:<scenario>`, `stop --scenario <scenario>`, and `-Scenario baseline`, `business-day`, or `off` (which turns the activity off). `{{NEXT_SHUTDOWN}}` becomes the VM's next auto-shutdown time, and every run ends at least 2 minutes before it; `demo-control.ps1` adds it, and takes the runner's `--duration 25m` as `-Duration 25`.
- T1, T3, T4, and T5 commands run on `sqlvm01`, and T2's in the guest through `archost01`; that VM must be running, and they need [a PowerShell session](#prepare-a-powershell-session). The optional **demo-control** GitHub workflow, for maintainers, takes the same inputs ([workflows](deployment.md#workflows)).

### The hourly incidents (`business-day`)

`business-day`, the default activity profile outside Run all, runs the baseline plus these bounded incidents at fixed minutes past each UTC hour, each in `ContosoCare` only and ended by its own time limit ([activity profiles](../scenarios/activity-profiles.json), [ADR 0010](adr/0010-workload-generator-technology.md#activity-profiles-business-day-by-default-2026-11-03)); Database Hub shows each a few minutes after it starts. Performance's problem panels, such as **High CPU resources over time** and **Databases limited by service tier**, list only resources with that problem, so with `baseline` alone they say "No results found"; which panel lists each incident is *verify in rehearsal*.

| Minute (UTC) | Target | Incident, length | What it shows |
|---|---|---|---|
| :05 | T2 | `cpu-pressure`, 8 min | CPU toward 100%: the high-CPU and CPU-spike panels |
| :08 | T4 | `connection-surge`, 4 min | Connections climbing on the PostgreSQL dashboard |
| :10 | T1 | `locking-blocking`, 8 min | `Processes blocked` above 0, and Lock waits |
| :15 | T3 | `resource-governance`, 5 min | CPU at the tier's limit: **Databases limited by service tier** |
| :20 | T2 | `missing-index`, 8 min | CPU and logical reads above the baseline |
| :22 | T4 | `idle-in-transaction`, 8 min | Idle sessions in an open transaction, blocking writers, in **Connections** |
| :25 | T5 | `ru-storm`, 8 min | Normalized RU at 100% and 429s in waves, then the recovery |
| :35 | T2 | `io-pressure`, 8 min | Storage IO, `Page reads/sec`, and `WRITELOG` |
| :40 | T1 | `locking-blocking` with a deadlock, 6 min | Blocking, and `Number of Deadlocks/sec` above 0 |
| :42 | T4 | `cpu-pressure`, 6 min | CPU at its ceiling on the PostgreSQL dashboard |
| :45 | T3 | `log-rate-pressure`, 5 min | `Log Rate Governor` at the log-rate limit |
| :50 | T2 | `inefficient-query`, 6 min | CPU and `Batch Requests/sec` above the baseline |

`./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25` runs one right now in place of T2's profile, and `-Scenario business-day -Duration 240` brings the hourly incidents back. For a quieter demo, set `"activityProfile": "baseline"`, or pass `./scripts/start-demo.ps1 -ActivityProfile baseline`. The scripts set `baseline` while their own Run Commands run and switch to `business-day` after (`DEPLOY.INCIDENTS_*`, `START.INCIDENTS_*`) ([activity profiles](deployment.md#activity-profiles-and-boot-behavior)).

### T4 autonomous tuning in the Azure portal

On T4 with 4 or more vCores and `t4AutonomousTuning` on, as the default `Standard_D4ds_v5` has ("any currently supported compute SKU with at least 4 vCores", [autonomous tuning](https://learn.microsoft.com/azure/postgresql/monitor/concepts-autonomous-tuning)), Query Store captures the showcase's T4 `missing-index` lookups (minutes 20 to 29, General Purpose only; `replica-lag` takes the slot in even cycles when T1's profile host has T4's replica), or `incident:missing-index`'s, and a tuning session every `index_tuning.analysis_interval` (60 minutes here, the minimum; 720 by default) recommends their indexes: at least about an hour after the lookups start, near a 90-minute showcase's end or the next day; not proven live. `Standard_B1ms`, `Standard_B2s`, and `Standard_D2ds_v5` turn it off ("Don't enable query store on the Burstable pricing tier", [Query Store](https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store)).

- **Show it:** the PostgreSQL view is metrics only ([monitor PostgreSQL](https://learn.microsoft.com/fabric/database/hub/monitor-postgresql)), so go from **Estate** → `pgflex01-<deploymentId>` → **Open in…** → **Intelligent Performance** > **Autonomous tuning**, or use [`az postgres flexible-server autonomous-tuning`](https://learn.microsoft.com/cli/azure/postgres/flexible-server/autonomous-tuning):

  ```powershell
  az postgres flexible-server autonomous-tuning show --resource-group <rg> --server-name pgflex01-<deploymentId>
  az postgres flexible-server autonomous-tuning list-index-recommendations --resource-group <rg> --server-name pgflex01-<deploymentId> --recommendation-type CreateIndex
  az postgres flexible-server autonomous-tuning list-table-recommendations --resource-group <rg> --server-name pgflex01-<deploymentId>
  ```

- **The human-approved action:** nothing applies a recommendation (`index_tuning.mode` is `REPORT`). A person may create the index in `contosocare`; nothing in the repo creates or drops T4 indexes, so drop it yourself to show "before" again. The 4-vCore size, and the session's replica at the same size, bill more per hour than a Burstable size ([cost management](cost-management.md#at-a-glance)).

### Read replica lag (T4)

- **Runs on:** T4 with its read replica, `pgreplica01-<deploymentId>`, which Run all and `start-demo.ps1` create for each session ([ADR 0025](adr/0025-t4-read-replica.md)). A Burstable T4 has none, and a session without one (`-SkipT4Replica`, a size Azure refused, or `MODE = "activities"`) refuses the run with that fix.
- **The story:** "A reporting workload on your DR copy put it N minutes behind": a long report on the replica holds back the replay of the primary's changes, while the primary is fine.
- **When:** in the showcase, 50 minutes after T4's profile is set, for 9 minutes, climbing to about 3 minutes twice (again in a 120-minute session's fourth cycle). Outside one: `./scripts/demo-control.ps1 -Target T4 -Scenario incident:replica-lag -Duration 10`, or a shorter climb with `Invoke-DemoWorkloadCommand -Config $config -Target T4 -ArgumentList 'profile', 'set', '--name', 'incident:replica-lag', '--param', 'holdSeconds=120', '--not-after', '{{NEXT_SHUTDOWN}}'`; `stop --scenario replica-lag` or `profile set --name baseline` ends the report too.
- **Bounds:** 10 minutes by default, 15 at most; each cycle's report holds `demo.replica_lag_marks` for `holdSeconds` (240, 30 to 540), then pauses `pauseSeconds` (60) ([the scenario](../scenarios/replica-lag/README.md)).
- **Show in the Hub:** **Estate**, **View: PostgreSQL**, the replica as a server of its own (*verify in rehearsal*), then **Performance**: **Read replica lag** (`physical_replication_delay_in_seconds`) climbs to about `holdSeconds` during each report and drops back to a few seconds; idle, it's 2 to 6 ([monitor PostgreSQL](https://learn.microsoft.com/fabric/database/hub/monitor-postgresql)). T4's Metrics in the Azure portal show **Max Physical Replication Lag** in bytes.
- **Afterward:** Run all's end, or `./scripts/stop-demo.ps1 -SaveHistory`, reads the replica's metrics into the history (for the Insights app's T4 page) before it deletes the replica, whose Azure Monitor history goes with it. `reset` deletes the marks, the only rows it writes, and ends its sessions on the replica.

### RU storm (T5)

The story, what to show, and T5's container are in [T5: Azure Cosmos DB's RU storm](#t5-azure-cosmos-dbs-ru-storm).

- **Runs on:** T5, `cosmos01-<deploymentId>`, in its container `patient-events` (400 RU/s), which `start-demo.ps1`, Run all, and `demo-control.ps1` create when it isn't there. T1's runner drives it, so `sqlvm01` must be running.
- **Bounds:** 10 minutes by default, 30 at most; 8 writers in waves of `stormSeconds` (150), each followed by `calmSeconds` (90), upserting a fixed set of 100 documents in their own partition (`p-storm-01`), which the run deletes when it ends, however it ends ([the scenario](../scenarios/ru-storm/README.md)).
- **Start, outside a Run all session:** `./scripts/demo-control.ps1 -Target T5 -Scenario incident:ru-storm -Duration 10`; `business-day` runs it at :25 for 8 minutes. **Stop:** `profile set --name baseline`, or the notebook's **Stop now**.
- **Reset:** nothing to do; after a stopped VM cut a storm off, `./scripts/reset-demo.ps1 -Target T5` deletes any documents left.

## Before the session

With Run all, [the presenter's path](#the-presenters-path) is all a session needs: rehearse the day before, and open the tabs 5 minutes before. Without Run all, also follow [the PowerShell path](#without-run-all-the-powershell-path).

### The day before

1. **Rehearse** both versions, with `MODE = "check"` first, and capture each beat's screenshot, the last rung of every fallback. Record the date, the targets Copilot covered, the latency, and each *verify in rehearsal* item you settled in the [live coverage record](../fabric/agent/README.md#live-coverage-record).
2. **The cost:** `./scripts/estimate-cost.ps1 -NetworkMode private` (or `public`) prices a session and a month at the [Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)'s prices ([what it costs](../README.md#what-it-costs)). The ceilings: $20 a session (`sessionCeilingUsd`, a **Warning** above it) and $415 a month for a new configuration (`monthlyCeilingUsd`, a hard ceiling: preflight fails above it; a configuration keeps its own value); [cost management](cost-management.md#at-a-glance). Your Fabric capacity, Fabric and Power BI licenses, and each viewer's GitHub Copilot plan are outside every estimate.
3. **T2 and Fabric:** `./scripts/status.ps1 -Detail` while `archost01` runs says T2 is `Ready` (otherwise, see the [recovery playbook](#recovery-playbook)). `deploy.ps1` imported `NB_DatabaseHub_Control`, `NB_DatabaseHub_LiveActivity`, and `RTD_DatabaseHub_LiveView`; for a missing one, run `./scripts/deploy.ps1`. For the 30-minute version, check the dashboard's tiles by eye, because the read-back proves the definition, not the tiles ([dashboard as code](../fabric/realtime/README.md#import-it)), and run **Create SQL monitors from template** once, noting its templates, their metrics, how long it takes, and where its dashboard goes (*verify in rehearsal*).
4. **Access:** each presenter opens [Database Hub](https://app.fabric.microsoft.com/workloads/fdh/databaseHub) with their own account, with Reader on the subscription (Contributors have it; others need P8), `Microsoft.Sql` registered, the tenant setting **Users can access the Database hub (preview)** (P4), and Database Hub available in your tenant's region ([overview](https://learn.microsoft.com/fabric/database/hub/overview), [region availability](https://learn.microsoft.com/fabric/admin/region-availability)); Database Hub needs no capacity ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq)). Viewers who open a dashboard need Reader and access to it, with a Fabric Free license ([presentation surfaces](presentation.md#licensing-and-permissions)).
5. **The fallback host:** GitHub Copilot CLI with the pinned `fabric-skills` plugin (the GA skill `databasehub-cli`), the pinned `microsoft-sql` plugin, and the Learn MCP server, versions checked ([agent guide](../fabric/agent/README.md#part-2-skills-in-github-copilot-cli)); don't run `copilot plugin update` before a demo.
6. **The calendar:** end at least 15 minutes before `autoShutdownTime` (19:00 by default) in `autoShutdownTimeZone`, when the nightly auto-shutdown deallocates both VMs ([auto-shutdown](https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm)) and the nightly safety stop deallocates any VM still running, stops T4, and deletes T5's container ([what stops on its own](cost-management.md#what-stops-or-pauses-on-its-own)). A Run all session always ends before it.
7. **Keep T3:** a newly created T3 shows security, posture, and Database Agent findings late, so keep it, as `stop-demo.ps1` does by default; auto-pause stops its compute when idle ([serverless auto-pause](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume), [ADR 0016](adr/0016-cost-profiles.md)). `./scripts/stop-demo.ps1 -RemoveT3` is for long gaps: the next `start-demo.ps1` recreates it under the same names, about 10 minutes more, with a readiness **Warning** until telemetry arrives, and its Database Agents selection is needed again.

### Pick the targets for Copilot's beats

Database Agents covers Azure SQL Database only, T3 here ([Database Agents](https://learn.microsoft.com/fabric/database/hub/database-agents)); which SQL targets Copilot covers, and how fast, isn't documented. **Plan A is T3:** CPU against the tier's limit, log-rate governance, the most security assessments, and the best query-level fallback, since the `microsoft-sql` skills are written for Azure SQL Database. **Plan B is T1,** such as its blocking chain: the GA `databasehub-cli` skill's health covers only Azure SQL Database and Arc-enabled SQL Server ([its health routes](https://github.com/microsoft/skills-for-fabric/blob/e31422e7d1045ef3a0906df9ff5991f2338af010/skills/databasehub-cli/references/health-drilldowns.md)), so T1's fallback is the telemetry prompts. **Plan C is T2,** in a nested guest, which Arc monitoring doesn't mention: whether **Performance** and Copilot cover it is a rehearsal check, and its fallback is the telemetry prompts, then its **Performance Dashboard** in the Azure portal ([Arc monitoring](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring)). Until the [live coverage record](../fabric/agent/README.md#live-coverage-record) has entries, pick a beat on T3 and one on T1, and investigate T3 first; then use the targets it marks **Pass**.

### Label T2 honestly

- **By default** (`t2Mode = Nested`, `t2SqlInstallMode = JumpstartImage`), T2 is a nested Hyper-V guest on the Azure VM `archost01`, made with no person from [Arc Jumpstart](https://github.com/Azure/arc_jumpstart_docs/blob/71a945c619f78acb441c6470d76a9b58347169fe/docs/azure_jumpstart_arcbox/ITPro/_index.md)'s image, onboarded to Azure Arc, running SQL Server 2022 Standard pay-as-you-go through Arc: present it as a **simulated** on-premises server. An older configuration's `PaygWizard` runs as `JumpstartImage` ([deployment](deployment.md#an-older-demo-a-plain-deployps1-upgrades-it-2026-11-09)); `ProductKey` (P10) is unattended too; `Developer` shows T2 in Estate only, its Performance checks **Not supported**, because Arc monitoring needs Standard or Enterprise ([Arc monitoring](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring)).
- **Evaluation only (`t2Mode = EvaluationOnlyAzureVm`):** without nested virtualization, T2 can be an Azure VM running the Arc agent under Microsoft's procedure for evaluation and testing purposes only ([Evaluate Azure Arc-enabled servers on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)). Label it **evaluation only** on every slide and every time you mention it (every T2 result then starts with "EVALUATION ONLY:"), and never call it on-premises. It has no workload runner yet, so run every incident on T1 or T3.

### 5 minutes before: open the tabs

- Database Hub on **Overview**, **Estate** (**View: Microsoft SQL**, the demo resource group), and **Performance**; **Ask Copilot** is at the top right of each ([Copilot in Database Hub](https://techcommunity.microsoft.com/blog/azuresqlblog/ask-your-database-estate-a-question-copilot-in-database-hub-is-now-in-public-pre/4572704)), which the guide calls "Database Hub > Estate > a SQL target".
- `NB_DatabaseHub_Control` with the guide, off the shared screen; GitHub Copilot CLI with the deny rules and [session-setup.skills](../fabric/agent/prompts/session-setup.skills.md) run ([run it in the session](#run-it-in-the-session)); and a [PowerShell session](#prepare-a-powershell-session) for `status.ps1` and beat 9's fallback.
- The [Azure Data Explorer web UI](https://dataexplorer.azure.com) on the telemetry endpoint, with the scenario's Learn sample queries ([Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)); fill in a query's resource ID, which shows the subscription ID, before you share the screen.
- For the 30-minute version: `NB_DatabaseHub_LiveActivity` with its helper cells run, `RTD_DatabaseHub_LiveView` on **Incident** (the last hour, **Target** on the incident target), and the wizard's workspace.
- The rehearsal screenshots. Close anything that shows IDs, email addresses, or tokens, and never share a terminal that printed a token.

## Without Run all: the PowerShell path

Run a session from a PC when the session control's roles aren't assigned yet (an Owner runs `./scripts/grant-safety-stop.ps1` once), or to stage one incident yourself, outside a Run all session. Every step and check of [`start-demo.ps1`](deployment.md#start-start-demops1) and [`stop-demo.ps1`](deployment.md#stop-stop-demops1) is in deployment.

### Prepare a PowerShell session

Every command here runs in PowerShell 7.4 from the repository root, after you sign in yourself; the scripts never sign in or change your Azure CLI context, so don't run `az account set` either.

```powershell
# Sign in only if you aren't signed in to the demo's tenant. At the subscription selector, press Enter for no changes.
az login --tenant <tenantId>
Import-Module ./scripts/modules/DbHubDemo/DbHubDemo.psd1
$config = Get-DemoConfig -Path ./config/demo.config.json
Assert-DemoAzContext -SubscriptionId $config.subscriptionId -TenantId $config.tenantId -Account $config.azureAccount
```

`Assert-DemoAzContext`, the subscription guard, checks that sign-in against the configured tenant and `azureAccount`, never changing your default subscription ([sign in with Azure CLI](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively), [when it stops](troubleshooting.md#the-guard-stops-a-script)).

### 60 minutes before: start and warm up

```powershell
./scripts/start-demo.ps1 -WarmUpMinutes 30
```

It checks the cost (`START.COST.ACTUAL`; a **Fail** stops it, and `-SkipCostCheck`, which makes `START.COST` **Not selected**, is only for right after a check), starts the VMs (`START.VM_*`) and T4 (`START.T4.START`), creates T5's container, resumes T3 (`T3.WARMUP` **Pass** says how long it took to answer), sets the activity on all five targets for 8 hours (`START.PROFILE_*`), creates T4's read replica in about 9 minutes (`START.T4.REPLICA`; `-SkipT4Replica` leaves it out), and returns with the activity running. `-WaitForWarmUp` waits the 30 minutes and checks that telemetry arrives; `-ActivityProfile baseline` keeps the targets steady around one staged incident; `-Interactive -ResetAdminPassword` adds Bastion, only for [the missing-index fix](#the-missing-index-fix-by-a-person). Start with the script, not the Azure portal: the VMs set no profile when they boot (`activityProfileOnBoot` is false), so a VM started another way runs no workload and doesn't keep T3 awake. `./scripts/status.ps1 -Detail` gives each target's profile and its end (`STATUS.PROFILE_*`).

### 15 minutes before: the readiness gates

Optional with Run all, whose live view shows the telemetry. The checklist only reads (apart from presenter roles with `assignRoles`); the T3 gate checks Azure Resource Graph, the extended property, and fresh telemetry, and its property check warms T3 up through T1:

```powershell
./scripts/configure-fabric.ps1 -SkipNotebookImport -WaitMinutes 15 -T3ReadinessGate -T3PerformanceMonitoringCheck {
    param($c)
    Invoke-DemoT3WarmUp -Config $c | Where-Object -Property checkId -EQ -Value 'T3.PROPERTY'
}
```

| Check | Go | If it isn't a go |
|---|---|---|
| `PREFLIGHT.GUARD.CONTEXT`, the subscription guard | **Pass** | **Warning:** set `azureAccount` to the account its evidence names. **Fail:** sign in again yourself as that account (`az login --tenant <tenantId>`) |
| `HUB.ESTATE.T1`–`T3`, the targets in Azure Resource Graph | **Pass** for each target you'll show | T2 isn't ready yet: present T1 and T3, and say why |
| `TELEMETRY.T1`–`T3`, rows at most 15 minutes old | **Pass** for every target you'll show | **Warning** (stale): start or warm the target up and check again. **Fail** (no rows): `./scripts/configure-monitoring.ps1 -Target T1 -WaitMinutes 15`, or `-Target T2`, or another target |
| `T3.READINESS.GATE` | **Pass** | A **Warning** with the lag (T3 just created or paused): use T1 for Copilot today |
| `FABRIC.P4.HUBSETTING`, the tenant setting | **Pass** for a Fabric administrator; **Manual action required** otherwise | Database Hub opening for the presenter means it's on |
| `FABRIC.P5.WORKSPACE`, `FABRIC.P5.CAPACITY` | **Pass** | **Manual action required** while your capacity is paused: resume it before the session |
| `PREFLIGHT.FABRIC.VIEWERLICENSE` | **Not selected**: viewers' licenses are assumed | Share your screen ([licensing](presentation.md#licensing-and-permissions)) |
| `HUB.PRESENTER.*`, Reader for presenters, with `assignRoles` | **Not selected** or **Pass** | **Manual action required** prints the `az role assignment create` command for an administrator |

Check by eye that **Estate** lists the targets (only the engine for `sqlvm01`) and **Performance** has the last 15 minutes. If the incident target's telemetry isn't **Pass** 10 minutes before you start, stage the incident on your next target.

### 10 minutes before: stage the incident (15-minute version)

Not in a Run all session, where the showcase runs the incidents. Telemetry arrives 3 to 5 minutes after the activity, some inventory data up to 15 ([SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm)), so start it before the audience arrives:

```powershell
./scripts/demo-control.ps1 -Target T3 -Scenario incident:locking-blocking -Duration 30
```

- It sets the target's profile through Run Command, with `--not-after` at the next auto-shutdown (`CONTROL.T3`); the run ends after 30 minutes, its maximum, or 2 minutes before the auto-shutdown, with the baseline beside it for that window only. **Plan B:** with no live coverage record yet, also run it with `-Target T1`, and investigate T3 first.
- **The prompts' windows:** `{incidentWindow}` is the run's start and deadline (`status --json`, or `demo.scenario_runs`); `{baselineWindow}` is as long, just before it.
- **The 30-minute version** starts its incident on camera in beat 1: `-Duration 25` for locking, `cpu-pressure` on T2, and `missing-index` on T2 (30 at most); 15 for `resource-governance` (20 at most) and `log-rate-pressure` (15 at most).
- **Again, or back to the baseline:** `./scripts/reset-demo.ps1 -Target T3`, then the same command; `./scripts/demo-control.ps1 -Target T3 -Scenario baseline -Duration 240` (T1 too, when you staged it there). Don't run `start-demo.ps1` again mid-session: it sets every profile again, which ends the incident.

### The missing-index fix, by a person

The "after" of the missing-index story, on T2, without Run all: a person reviews and runs [`remediation.sql`](../scenarios/missing-index/remediation.sql) in `ContosoCare` from a SQL session inside the virtual network; nothing applies the index automatically, and never the agent.

1. **Bastion:** `./scripts/start-demo.ps1 -Interactive -ResetAdminPassword` also creates Bastion Basic (about 8 minutes), tagged to expire after `bastionMaxHours` (4 by default) ([Bastion](https://learn.microsoft.com/azure/bastion/bastion-overview)), with a one-time password for `archost01` only. Nothing else in either script needs Bastion.
2. **The session:** Bastion to `archost01`, then the guest in Hyper-V Manager; in an elevated PowerShell on the host, `C:\ProgramData\DbHubDemo\Copy-GuestCredential.ps1` copies the guest's password to the clipboard unseen, for **Clipboard** > **Type clipboard text** at its sign-in (*verify in rehearsal*).
3. **Then:** `./scripts/stop-demo.ps1 -RemoveBastionOnly` removes Bastion and rotates the password, and, after the session, `./scripts/reset-demo.ps1 -Target T2 -UndoRemediation` drops the indexes, so the next run starts from "before".

## The documented, scriptable fallback

Use it when the Database Agent or Copilot isn't visible in your tenant, declines the target, or doesn't answer within about three minutes. Every piece is documented, every prompt is read-only or asks only for a proposal, and the same prompts work on T1, T2, and T3. The decision is [ADR 0013](adr/0013-agent-experience.md); installation, pins, limitations, and safety rules are in the [agent guide](../fabric/agent/README.md).

### The ladder

1. **Copilot in Database Hub, and on T3 the Database Agents issue:** the showcase.
2. **Ask, the Copilot chat in the Insights app:** **Ask Copilot** in `APP_DatabaseHub_Insights`, with the same question. It answers from the demo's history and the live estate, on your own GitHub Copilot plan after a GitHub sign-in once per browser, shows the query or source behind each answer, and needs nothing installed ([the Copilot chat](../README.md#the-copilot-chat-in-the-insights-app), [ADR 0028](adr/0028-ask-copilot-in-the-insights-app.md)).
3. **The scenario's skills prompts** (`<scenario>.skills.md`) in GitHub Copilot CLI, the primary host, or VS Code, after [session-setup.skills](../fabric/agent/prompts/session-setup.skills.md), with the GA Database Hub skill `databasehub-cli` from [`microsoft/skills-for-fabric`](https://github.com/microsoft/skills-for-fabric/tree/main/skills/databasehub-cli) ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview); read-only, as your delegated sign-in: inventory, health for SQL and PostgreSQL, Cosmos DB's availability and RU use, and security posture), Learn's telemetry "Agent instructions block", which covers every incident on every target ([Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)), and the [Learn MCP server](https://learn.microsoft.com/training/support/mcp). The `microsoft-sql` plugin's diagnostics skills are optional (**Not selected**): they need a SQL connection through Bastion, and on T1 and T2 they can decline.
4. **No agent at all:** the Database Hub pages, plus each prompt file's Learn sample queries in the [Azure Data Explorer web UI](https://dataexplorer.azure.com) ([web UI queries](https://learn.microsoft.com/azure/data-explorer/web-ui-query-overview)), or [beat 9](#beat-9-26002900-the-notebooks)'s telemetry tables.
5. **Last resort:** the rehearsal screenshots.

### Run it in the session

```powershell
Set-Location -Path "$HOME\dbhub-agent-demo"
copilot --deny-tool=write --deny-tool=FabricIQ --deny-tool=powerbi-modeling-mcp --deny-tool=fabric-sqlendpoint
```

Start it outside this repo, with the deny rules, and approve one read command at a time, as the [agent guide](../fabric/agent/README.md#5-start-a-safe-session) says; never paste a token into the chat. Paste the session-setup prompt first, then the scenario's skills prompts with the four placeholders filled in. **Say:** "Same telemetry, same permissions, another surface: the agent queries a documented, read-only endpoint as me, and it can't change anything."

### Out of scope

- **The Fabric data agent:** it works over OneLake data, not Database Hub signals.
- **Custom agents or scripts that call undocumented Database Hub routes, or automate the portal:** never, with one exception for the routes only: the Insights app's estate function reads the GA `databasehub-cli` skill's 8 read-only routes, scoped to the demo's resource group ([ADR 0013's amendment](adr/0013-agent-experience.md#amendment-2026-11-18-the-ga-skill-and-one-narrow-exception)).

## Recovery playbook

When something isn't visible, say so plainly, keep the story moving on another target or surface, and fix it after the session. Never present missing data as healthy: "missing telemetry isn't zero utilization or proof that a server is healthy" ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)). Each script step has its own fallback, and [troubleshooting](troubleshooting.md) has the fixes by check ID.

| What you see | Why | What to do |
|---|---|---|
| Run all says "Nothing runs": "Another DbHub-Control job ... is Running", or "A run is active until ..." | One run at a time; a Run all during a session follows it, as expected | Follow the running session, or end it first: `STOP_NOW = True`, then Run all ([the session control](troubleshooting.md#the-on-demand-activity-control)) |
| Run all can't start a session: "The webhook URL couldn't be read from Key Vault", no status says it runs, or NoEnvironment | Usually the session control's roles aren't assigned: the deployer wasn't an Owner | Now: `./scripts/start-demo.ps1`, later `./scripts/stop-demo.ps1 -SaveHistory`. After: an Owner runs `./scripts/grant-safety-stop.ps1` once ([other causes](troubleshooting.md#the-on-demand-activity-control)) |
| The notebook won't run, or Run all doesn't start; `FABRIC.P5.CAPACITY` is **Manual action required** | Your Fabric capacity is paused, and Run all never resumes it | Now: [beat 9](#beat-9-26002900-the-notebooks)'s fallback; don't resume or import on stage. After: resume it before Run all and pause it after ([pause and resume](https://learn.microsoft.com/fabric/enterprise/pause-resume)); a missing notebook comes back with `./scripts/deploy.ps1`, or `./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook <name> -WhatIf`, then without `-WhatIf` |
| A target has no recent data, or `TELEMETRY.<target>` is a **Warning** | Telemetry lags the activity by a few minutes | Say so, show another target or the scenario's Learn sample queries, and come back. After: `Test-DemoHubTelemetry -Config $config -Target T1, T2, T3 -WaitMinutes 15` gives each target's rows, newest sample, and lag |
| **Performance**'s problem panels (**High CPU resources over time**, **High CPU resource details**, **CPU spikes over time**, **Databases limited by service tier**) say "No results found" or "No Rows To Show" | No target had that problem in the range: `baseline` never causes one, the profile is `off`, or the next [hourly incident](#the-hourly-incidents-business-day) or beat hasn't arrived | Widen the range; `./scripts/status.ps1` gives each profile (`STATUS.PROFILE_*`), and the guide the next beat; without Run all, `./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25`. After: Run all, or `business-day` (remove `activityProfile`, or set it so) started at least an hour ahead |
| T3 shows gaps or no data | Serverless auto-pause after `t3AutoPauseMinutes` (15 by default) without a session ([auto-pause](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume)) | `Invoke-DemoT3WarmUp -Config $config`, from `sqlvm01`, which must run; without Run all, also `./scripts/demo-control.ps1 -Target T3 -Scenario baseline -Duration 240`. After: keep T3's profile on to the end |
| T3 doesn't exist | `stop-demo.ps1 -RemoveT3` removed it | Use T1 for Copilot's beat. After: `./scripts/start-demo.ps1` recreates it, about 10 minutes more |
| `sqlvm01` or `archost01` is deallocated, and runner commands fail | The nightly auto-shutdown and safety stop, at `autoShutdownTime` (19:00 by default) in `autoShutdownTimeZone` | Run all again, or `./scripts/start-demo.ps1`, which sets every profile again (stage a running incident again after). A VM started after the shutdown time runs until the next day's: always do [after the session](#after-the-session) |
| T5 shows no data or no throttling | `sqlvm01` is deallocated; the container wasn't created (`START.T5.CONTAINER`, `CONTROL.T5.CONTAINER`, or the session's **T5 container** step says why); or the hour hasn't filled (hourly grain) | Show the other targets; `./scripts/status.ps1` (`STATUS.T5`) has the last 15 minutes ([T5](troubleshooting.md#t5-azure-cosmos-db)) |
| **Read replica lag** is empty, Estate has no `pgreplica01-<deploymentId>`, or `incident:replica-lag` isn't sent (`CONTROL.T4` says why) | No replica this session: `-SkipT4Replica`, a size Azure refused (`START.T4.REPLICA`), `MODE = "activities"`, a Burstable T4, or an older environment not yet upgraded | Show T4's own dashboard. After: the next Run all or `./scripts/start-demo.ps1` creates it (about 9 minutes), after `./scripts/deploy.ps1` for an older environment ([the replica](troubleshooting.md#t4s-read-replica)) |
| T2 is missing; `HUB.ESTATE.T2` or `TELEMETRY.T2` is **Manual action required**; the host is `ManualActionRequired` at `SqlSetupWizard` | An environment from before 2026-11-09 whose `PaygWizard` setup wizard was never finished | Present T1 and T3, and say T2 isn't set up. After: `./scripts/deploy.ps1` makes T2 again from Arc Jumpstart's image with no person, about 27 minutes plus about 33 for Arc ([deployment](deployment.md#an-older-demo-a-plain-deployps1-upgrades-it-2026-11-09)); don't finish the wizard by hand |
| Ask, the Copilot chat, doesn't sign in or answer | The relay is waking from zero (seconds); the GitHub account has no Copilot plan; an organization that restricts OAuth apps hasn't approved **Database Hub Insights Ask**; or "Enforce a strict content security policy for static-hosted Fabric Apps (preview)" is on | Ask again in a few seconds, or use Copilot in Database Hub or [the ladder](#the-ladder); the chat says what to do ([Ask](troubleshooting.md#ask-the-copilot-chat-in-the-insights-app-2026-11-18)) |
| An incident didn't start: `status --json` shows no run | The same scenario already runs, the database has four runs, the free-space check refused it, `--not-after` is too close, or the VM is off | The guide's next beat (without Run all, `business-day`'s next incident), or another target. After: read the runner's message, `./scripts/reset-demo.ps1 -Target <T1 to T5>`, and start it again |
| An incident won't stop | A stop request is pending, or a session is stuck | `stop --scenario <scenario>` keeps the profile; `stop --all` turns it off, which in a Run all session ends the target's showcase ([commands](#commands-for-every-scenario)); then `./scripts/reset-demo.ps1 -Target <T1 to T5>`. The watchdog cancels the run 60 seconds after its deadline and kills its sessions 15 seconds later |
| Database Hub doesn't load, or shows nothing | The tenant setting is off, Database Hub isn't available in your tenant's region, no Reader, or the wrong account | The presenter account you checked the day before, or the fallback. After: `./scripts/configure-fabric.ps1 -SkipNotebookImport` by a Fabric administrator (P4), and Reader (P8) |
| **Open in SSMS** or a VS Code link doesn't connect | No SQL endpoint is reachable from outside the virtual network | Stay in Database Hub and the telemetry; Bastion only for query-level evidence |

## After the session

**After a Run all session,** there's nothing to do: Run all stopped everything and saved the session's history. Check with `./scripts/status.ps1` (step 4), and pause your Fabric capacity when nothing else needs it. For a session without Run all, or one Run all didn't end:

1. **Reset, while the VMs run:** `./scripts/reset-demo.ps1` stops every scenario and profile on every target, kills leftover `ContosoCare.Demo/` sessions, verifies no demo transaction is open, empties the scratch tables, and turns the profile `off` (`RESET.T1` to `RESET.T5`); add `-UndoRemediation` after the missing-index fix. With its profile off, T3 pauses `t3AutoPauseMinutes` (15 by default) after its last session; one left on keeps it awake and billing ([ADR 0016](adr/0016-cost-profiles.md)).
2. **Stop,** unless another session follows soon: `./scripts/stop-demo.ps1` removes Bastion, turns the profiles off, deallocates both VMs (even mid-incident), deletes T4's read replica, stops T4, and deletes T5's container (`STOP.T5`); T3 persists and auto-pauses. `-SaveHistory` saves the history first, the replica's lag included, since a deleted replica's metrics are gone (with the capacity paused, they wait in `out/history-pending`: `STOP.T4.HISTORY.PENDING`); `-ParkT2` stops only T2's side; `-RemoveT3` is for long gaps only ([every step](deployment.md#stop-stop-demops1)).
3. **Confirm Bastion is gone:** neither the nightly auto-shutdown nor the safety stop touches it. `./scripts/stop-demo.ps1 -RemoveBastionOnly` removes it and rotates the host password; with the optional GitHub schedules on (`DBHUB_SCHEDULES_ENABLED`), `bastion-cleanup.yml` removes it after `bastionMaxHours` (4 by default).
4. **Check the state and the cost:** `./scripts/status.ps1` gives the power states (`STATUS.VM_*`), Bastion (`STATUS.BASTION`, a **Warning** while it exists), T3, the next auto-shutdown, the nightly safety stop's last run (`STATUS.SAFETYSTOP`), and month-to-date spend from the [Cost Management query API](https://learn.microsoft.com/rest/api/cost-management/query/usage) against `monthlyCeilingUsd` (`STATUS.COST`), whose budget alerts at 50%, 80%, and 100%; [cost analysis](https://learn.microsoft.com/azure/cost-management-billing/costs/quick-acm-cost-analysis) breaks it down. Spend above the session estimate usually means Bastion, an evening start that ran until the next day's shutdown, or a T3 profile left on.
5. **Record** the date, the targets Copilot covered, the latency, any action it offered, the beat timings, and the *verify in rehearsal* items you settled in the [live coverage record](../fabric/agent/README.md#live-coverage-record).
6. **The wizard's dashboard** (30-minute version) is yours to keep or delete: nothing in the repo created it, so nothing removes it, and while it's in the demo's workspace, `destroy.ps1` keeps that workspace.
