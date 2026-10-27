# Implementation report

How the demo was built and what was proven live: its current state, the acceptance checklist, the measured times, the risk register, and a short log entry for each phase. Statuses follow [ADR 0012](adr/0012-validation-model.md), so a successful deployment alone is never **Pass**. Every live result comes from one Azure subscription in West US 3 and one Fabric workspace, between 2026-10-19 and 2026-10-27. Times are single samples, and yours will differ; the linked docs have the details.

## Final report

**State as of 2026-10-27.** T1, T2, T3, and T4 were deployed and validated live. All four are in Database Hub's Estate through Azure Resource Graph; T1, T2, and T3 send performance telemetry, and T4 its Azure Monitor metrics. The Fabric items were deployed and checked live: the notebooks, the Real-Time Dashboard, the history model and report, and the Insights app. Destroy was verified in a disposable environment, and the demo environment was destroyed and redeployed from the T2 golden snapshot in Phases 20 and 22, with no manual step.

Phase 25d proved Phase 25b's eight newer scenarios and Phase 25c's on-demand activity control live on 2026-10-27. Not proven live yet: a fresh build with the parallel tracks and no snapshot, an end-to-end run with an identity that holds only Contributor, and Phase 26's first run end to end, with the creation of a missing Fabric workspace and lakehouse. Database Hub's pages and the Database Agent have no API, so checking them is the presenter's job (**Manual action required**).

### Live status per target

| Target | Status | Evidence |
|---|---|---|
| Foundation | **Pass** | The network, its NSGs, and the budget since 2026-10-19; `COST.BUDGET` and `COST.AUTOSHUTDOWN` **Pass**, and the nightly auto-shutdown deallocated both VMs on schedule |
| T1 `sqlvm01` | **Pass** | SQL Server 2022 Standard, pay-as-you-go, **Ready** on 2026-10-20. Telemetry arrived about 2 minutes after its SQL VM monitoring flag was set. Unified inventory lists only the database engine, after the image's Analysis Services and Integration Services were removed (Phase 7) |
| T2 `arcsql01` | **Pass** | Arc **Connected** on 2026-10-20, with IMDS and the wire server unreachable from the guest. SQL Server 2022 Standard, pay-as-you-go, through the setup wizard on 2026-10-21, with telemetry about 7 minutes after monitoring was turned on. Restored from the golden snapshot as Standard pay-as-you-go with monitoring in Phases 20 and 22 |
| T3 `azuresql01-<id>/ContosoCare` | **Pass** | General Purpose serverless and Microsoft Entra-only, with a private endpoint, because a tenant policy turns off public network access on SQL servers. The first telemetry came 2.8 minutes after creation (2026-10-20). The free offer wasn't available, because the subscription's free databases were in another region, so T3 runs as regular serverless with a preflight **Warning** |
| T4 `pgflex01-<id>` | **Pass** | Created on 2026-10-26 on General Purpose `Standard_D2ds_v5`, after the region refused `Standard_B1ms` and `Standard_B2s` (R441). `HUB.ESTATE.T4` through Resource Graph and `METRICS.T4` through Azure Monitor **Pass** ([Phase 24](#phase-24-t4-an-azure-database-for-postgresql-flexible-server)) |
| Fabric | **Pass** | Both notebooks imported and run; the Real-Time Dashboard's 14 tiles all returned data; the history model's 103 measures all returned data after Phase 20's scenarios; the report's four pages rendered; and every query of the Insights app returned rows |
| Database Hub pages and the Database Agent | **Manual action required** | Presenter-driven, with no API: a rehearsal checks them |

### Acceptance checklist

The original brief's acceptance criteria, verbatim, plus the 30-minute target set during the build. Where part of a criterion is proven and part is still owed, it has two rows.

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | A new user can fork/clone and understand prerequisites without reading code. | **Pass** | The [README](../README.md); [prerequisites](prerequisites.md), with who provides each item and how it's checked; [permissions](permissions.md), the [FAQ](faq.md), and [troubleshooting](troubleshooting.md). `init.ps1` writes the configuration from your sign-in (Phase 26b). Static validation resolves every relative link |
| 2 | Preflight catches missing Azure/Fabric/permission/provider/region/quota/nested-size/preview prerequisites. | **Pass** | `preflight.ps1`: the subscription guard, P1–P6, providers, region, quota and nested-capable sizes, security types, zones, the policy inventory and what-if, the free offer, T4's size, and both cost ceilings, with unit tests for the missing cases. It ran live in Phases 14, 16, 20, 22, and 24. Only a Fabric administrator can read the Hub tenant setting (P4), so that check is **Manual action required** by design |
| 3 | One primary action deploys all supported resources, and re-runs are safe with no duplicate Arc resources. | **Pass** | `deploy.ps1`: Phase 20's redeploy (38.8 minutes) and Phase 22's (63.7 minutes, no check **Fail**), each followed by a second run that changed nothing (21.8 and 19.2 minutes), with `T2.ARC.NODUPLICATES` **Pass** and exactly one Arc machine. With T4, a second run took 20.1 minutes (Phase 24) ([Phase 20](#phase-20-fast-redeploy-parallel-tracks-and-a-t2-golden-snapshot), [Phase 22](#phase-22-faster-redeploy-the-follow-up-overlaps-and-one-timed-destroy-and-redeploy)) |
| 4a | T1, T2, and T3 are healthy; they appear in Hub after the documented interval, and supported ones show performance telemetry. | **Pass** | `HUB.ESTATE.T1`–`T3` through Resource Graph, which is how Hub finds them, and `TELEMETRY.T1`–`T3`, with the first samples 2 to 7 minutes after monitoring started, within the documented interval of up to 15 minutes. T4 is in Estate through Resource Graph, with its metrics in Azure Monitor (Phase 24) |
| 4b | The same criterion, seen in the Database Hub UI | **Manual action required** | Hub has no API, so checking Estate and Performance is presenter-driven (`HUB.ESTATE.VISUAL`) |
| 5a | Every scenario starts and stops; locking is visible and safely recoverable. | **Pass** (the first eight scenarios, and T4's) | Phase 20 (2026-10-22): all eight scenarios on their default targets, then 11 ten-minute incidents across T1, T2, and T3, each within its bounds. Blocking chains showed in T1's DMVs (a sleeping head blocker with an open transaction, and sessions waiting on `LCK_M_U`) and in the runner's status for T2 and T3. `RESET.T1`, `.T2`, and `.T3` **Pass**, with no demo session or open demo transaction left. T4's scenarios ran live in Phase 24 |
| 5b | The same criterion, for the eight scenarios Phase 25b added | **Pass** | Phase 25d (2026-10-27): each ran for 8 minutes on T1, T2, and T3 at once, every start and reset **Pass**, and the telemetry showed each one's designed waits. A profile set twice in a row waited for its first run to end instead of being refused. `RESET.T1`–`T4` **Pass** at the end, with no demo session or open demo transaction left ([Phase 25d](#phase-25d-phases-25b-and-25c-live)) |
| 6 | Agent skills work on supported signals, or the repo states why not. | **Manual action required** | The repo states each documented limit: `microsoft-sql-fdh` is read-only and calls routes that aren't a public contract, the `microsoft-sql` diagnostics skills target Azure SQL Database and can decline on T1 and T2, and the Database Agent's coverage isn't documented ([agent guide](../fabric/agent/README.md#limitations), [ADR 0013](adr/0013-agent-experience.md)). The [live coverage record](../fabric/agent/README.md#live-coverage-record) waits for a rehearsal |
| 7 | Reset works without redeploy. | **Pass** | `RESET.T1`, `.T2`, and `.T3` **Pass** in Phase 20, more than once, without a redeploy |
| 8a | Compute stops after the demo. | **Pass** (the automatic stop) | The nightly auto-shutdown deallocated both VMs on schedule; the activity profiles ended two minutes before it, and T3 auto-paused 15 minutes after its last session (2026-10-20) |
| 8b | The same criterion, with `stop-demo.ps1` | **Pass** | Phase 20: four runs of 338 to 371 seconds, each exit 0, with the profiles off, the guest shut down cleanly in 30 seconds, and both VMs deallocated. Phase 24: T4 stopped too, in 6.7 and 6.2 minutes |
| 9 | Everything, including Arc resources, destroys cleanly. | **Pass**; one item isn't the demo's | Phase 16: the test environment's destroy removed the group, the Arc machine and its SQL instance, the deployment records, and the managed identities, and a subscription snapshot compared with the one before deploy found nothing left; destroy now also deletes the group's budget, which outlives the group ([Phase 16](#phase-16-cleanup-testing)). Phases 20 and 22 destroyed the demo environment with the Arc resources first and the golden group kept. A role assignment that a tenant's governance automation gave one of the demo's identities outside the demo isn't the demo's, and removing it needs Owner (R339) |
| 10 | No secrets in Git or logs. | **Warning** | **Pass:** gitleaks on every pull request, with every default rule plus a broader rule for JSON Web Tokens; a real-value scan of every change; `SECURITY.SECRETSCAN.RUNCOMMANDS` and `.DEPLOYMENTS` on the running environment (2026-10-23); and notebooks committed without outputs. Setup's interactive sign-in can leave sign-in data on the VM; the scripts remove it right after the wizard and verify none remains (R74). **Warning:** `SECURITY.SECRETSCAN.OUTPUT` reports a **Fail** for patterns inside the third-party packages that the Fabric App stages under `out/`, while the demo's own output is clean (a follow-up), and Actions logs are scanned only once someone downloads them (R212) |
| 11 | Every manual step exists only because no supported automation was found, and is documented. | **Warning** | Every manual step reports **Manual action required** with exact steps, and the [automation support matrix](automation-support-matrix.md#what-stays-manual-and-why) justifies each with a Microsoft Learn citation. Most exist because no supported automation exists: the setup wizard, the Hub tenant setting, the Hub UI, and the Database Agent. The rest are deliberate: human approval, permissions beyond Contributor, your own Azure CLI sign-in, and the GitHub environment settings, which `setup-github-oidc.ps1 -ConfigureGitHub` sets up on request (R283) |
| 12 | Deploy end to end in 30 minutes or less, repeatably, and measure it (set during the build) | **Fail** | 38.8 minutes in Phase 20, then 63.7 minutes with Phase 22's overlaps, which had T1 and T3 ready at 26.8 minutes. T2's SQL Server extension download (R72) keeps T2 on the critical path (R341) |

### Measured results

One sample each, in West US 3. [Deployment](deployment.md#parallel-tracks-phase-20) has the per-step timings.

| Step | Measured |
|---|---|
| Redeploy from the T2 golden snapshot, with the parallel tracks and Phase 22's overlaps (2026-10-23) | **63.7 minutes** end to end, with no check **Fail**: T1 and T3 ready at +26.8 minutes, the Fabric track done at +17.1 (on an F4 capacity), and T2 at +61.7, of which about 29.5 minutes waited for the SQL Server extension's download in the guest (R72). Within it: the subscription guard 22 seconds, preflight 169 with the cached policy inventory, and the infrastructure 449 |
| The same redeploy before Phase 22's overlaps (Phase 20, 2026-10-22) | **38.8 minutes**, with no manual step: T1 and T3 ready at +36.3 minutes, and T2 at +37.7 (the extension arrived in about 5 minutes). Within it: the guard 68 seconds, preflight 215, and the infrastructure 428. The Fabric track took about 2.4 minutes, in a second run after a fix |
| A fresh build on the sequential pipeline (Phase 16, a disposable test environment, `Developer` mode, 2026-10-21 and 2026-10-22) | T1's telemetry at +58.5 minutes, and T3's at +62.9. T2 was ready after about 103 minutes across two runs: the guest build took about 35 of them, and its onboarding needed Phase 16's DNS fix. In `PaygWizard` mode, the setup-wizard step comes on top |
| A fresh build with the parallel tracks, without a snapshot | Not measured |
| The deploy that created T4 (2026-10-26, without the Fabric track) | 40.3 minutes; the template took 8 minutes 45 seconds with T4, against about 2 minutes without it (R419) |
| A second `deploy.ps1` that changes nothing | 19.2 minutes (2026-10-23), 21.8 minutes (2026-10-22), and 20.1 minutes with T4 (2026-10-26); 25.9 minutes when the code had changed |
| Start (`start-demo.ps1`) | 481 seconds, every check **Pass** (2026-10-22); 7.9 minutes with T4 (2026-10-26) |
| Stop (`stop-demo.ps1`) | 349 and 367 seconds (2026-10-22); 6.7 and 6.2 minutes with T4 (2026-10-26); 4.2 minutes in the test environment, with T1 already stopped |
| Destroy (`destroy.ps1`) | 1,102 seconds (2026-10-22), then 1,127 and 1,191 seconds (2026-10-23). In the test environment, the resource group took 4 minutes, and the whole run 24 with the residual check's polling and the live teardown tests |
| Preflight alone | 215 seconds with the cached policy inventory (2026-10-22); 12.5 minutes without it, about 7 of them for the policy inventory (2026-10-21) |
| Proving a golden snapshot (`test-t2-golden.ps1 -Onboard`) | 4,492 seconds (75 minutes), the extension's download included (2026-10-22) |
| The setup-wizard step (`PaygWizard`, once per guest build) | About 1 hour, after about 8 minutes for Bastion (2026-10-21) |
| Fabric | The dashboard's import in 35 seconds and its tile check in 61 (2026-10-21); the model and the report in 265 seconds (2026-10-22); the Insights app in 265 seconds, of which 47 for `rayfin up` (2026-10-22); Phase 22's whole Fabric track in 371 seconds on an F4 capacity (2026-10-23) |
| Full validation (`validate.ps1`, every area) | 853 seconds for 89 checks (2026-10-22); 1,905 seconds (2026-10-23), most of it the output scan walking the Fabric App's stage |
| `status.ps1` | 58 seconds (2026-10-21) |
| Phase 25b's eight scenarios (Phase 25d, 2026-10-27) | Nine 8-minute rounds, the three targets at once, except `capacity-max`, which ran on T3 in a round of its own; 2 hours 16 minutes with a reset after each round. The 26 profile sets took 51 to 165 seconds, and the 23 resets 64 to 147, every one **Pass** |
| The on-demand activity control (Phase 25d, 2026-10-27) | Setup on the private path in 521 seconds, and the owner's `-GrantRole` in 79. A request's notebook run started in 107 to 166 seconds, its runbook 3 to 4 minutes after the request, and the activity within 2 minutes after that, with the stopped VM and T4 started. **Stop now** reached its runbook in about 3 minutes, and the VM was deallocated within 5 minutes of the request, with T4 stopping |

### Cost

Dated examples from `estimate-cost.ps1` at list prices from the Azure Retail Prices API, for West US 3 and the `lowest-cost` profile. They're examples, not quotes ([cost management](cost-management.md)).

- **A 5-hour session:** $7.41 (2026-10-21), against the $15 session ceiling; $10.30 with T4 on `Standard_D2ds_v5` (2026-10-26).
- **A light-use month:** $65.12 (2026-10-21), against the $250 hard ceiling; $229.75 with T4, including the worst case of a stopped T4 that starts on its own after seven days (2026-10-26).
- **The T2 golden snapshot:** at most about $6.40 a month in the estimate (2026-10-22). It bills until `destroy.ps1 -IncludeGolden` deletes it.
- **Measured:** Phase 16's two-day test cycle came to about $4.50: its measured hours at list price, not a billed amount.
- **Outside the ceiling:** the Fabric capacity, while it runs (an F16 is about $2.88 an hour at list price, 2026-10-21), and viewer licenses on a capacity smaller than F64 (P11).

### Security summary

- **Footprint:** Contributor only, by default. The default path creates no role assignments and no Key Vault, gives the VMs no public IPs and no inbound management ports, and creates Bastion only on demand; `SECURITY.RBAC.ROLEASSIGNMENTS`, `SECURITY.SECRETS.KEYVAULT`, `SECURITY.NETWORK.NOPUBLICIP`, and `SECURITY.NETWORK.INBOUND` **Pass** live. The optional on-demand activity control needs an Owner once, for its role and grants ([ADR 0020](adr/0020-on-demand-activity-control.md)).
- **Credentials:** Arc onboarding uses the T2 host's identity when it's attached, and otherwise the caller's short-lived token as a protected Run Command parameter, never stored; a sweep after every onboarding verifies that none of it stays on the VMs (Phase 26d). The guest can't reach IMDS or the wire server (live, 2026-10-20). VM passwords are generated per deployment and never stored, and the Run Command that sets one clears the Windows PowerShell log when it recorded the value (R528). T3 and T4 are Microsoft Entra-only. Setup's interactive sign-in can leave sign-in data on the VM; the scripts remove it right after the wizard and verify none remains; the build fails if any remains (R74).
- **Scanning:** gitleaks on every pull request; the demo's own scanner over script output (UTF-16 logs included), deployment history, and Run Command instance views; and actions pinned by full commit SHA.
- **Accepted trade-offs:** T1's identity administers T3 and T4 through the P6 group (R26, R402), NSGs can't restrict egress by FQDN (R7), the nested guest's licensing isn't documented (R21), and the Contributor-only path isn't proven end to end (R210). The [security model](security-model.md) has the threat model.

### Still to verify

- **Database Hub and the Database Agent:** the Hub pages and the agent on each target, in a rehearsal, with the live coverage record.
- **Phase 25d's fixes that only a deploy or a later run shows:** the T2 track's wait for its host, the deploy's restart of T1's monitoring plugin, and the runner's retries (R483, R485).
- **A fresh build with the parallel tracks and no golden snapshot,** timed.
- **An end-to-end run with an identity that holds only Contributor** (R210).
- **The first run from a new tenant:** `init.ps1`, then a deploy whose Fabric track creates the workspace and lakehouse by name (Phases 26a and 26b).
- **The Insights app's Database Agent prompts** in a browser (`FABRIC.APP.BROWSER`).
- **The output scan** without the Fabric App's third-party packages.

## Risk register

Every risk number that the docs, scripts, and tests cite, with its status: **Closed**, **Mitigated** (the risk remains, and the demo handles it), **Accepted** (by design, and documented), or **Open**. The first 30 numbers come from the original plan, and the phases numbered the rest.

| ID | Risk | Status |
|---|---|---|
| R2 | Database Hub, the Database Agent, and the telemetry endpoint are previews and can change | **Mitigated:** documented interfaces only; a changed shape is reported, never a silent **Pass** |
| R3 | Azure Arc on a nested Hyper-V guest isn't explicitly documented | **Closed:** it worked live (2026-10-20) |
| R7 | Network security groups can't restrict HTTPS egress by FQDN | **Accepted** ([ADR 0007](adr/0007-networking-modes-and-egress.md)) |
| R9 | A tenant's Azure Policy can deny part of the deployment | **Mitigated:** preflight's policy inventory and what-if name the assignment before anything is written |
| R21 | Licensing of a Windows guest in nested Hyper-V on Azure isn't documented | **Accepted** ([ADR 0006](adr/0006-sql-editions-and-licensing.md)) |
| R22 | The Arc telemetry role isn't listed in the built-in role catalog pages | **Mitigated:** resolved by name at run time, never pinned |
| R23 | The Database Agent can change, and nothing can test it from code | **Mitigated:** a prompt pack with fallbacks, and a rehearsal before each demo |
| R25 | The default `PaygWizard` mode keeps one manual setup-wizard step per guest build | **Accepted:** the golden snapshot keeps the finished guest, and the `ProductKey` and `Developer` modes avoid the step |
| R26 | T1's managed identity is a T3 administrator through the P6 group | **Accepted:** a single-purpose server with synthetic data; a hardened option is in [ADR 0008](adr/0008-identity-rbac-abac.md) |
| R27 | Some tenants don't allow the P6 group | **Mitigated:** the deploying user becomes T3's administrator and runs the T-SQL interactively |
| R28 | GitHub Actions needs a one-time administrator action (P7) | **Accepted:** `setup-github-oidc.ps1` prints the one command |
| R29 | The telemetry endpoint might not accept a notebook's own token | **Closed:** it did (2026-10-21); the printed-KQL fallback stays |
| R30 | Cloning needed a GitHub sign-in while the repository was private | **Closed:** the repository is public |
| R42 | The `demo-day` profile went over the monthly ceiling with P10 data disks | **Closed:** Standard SSD or Premium SSD v2 data disks by default ([ADR 0016](adr/0016-cost-profiles.md)); preflight warns above a ceiling |
| R45c | The policy inventory takes minutes in a large tenant | **Mitigated:** reused for up to 168 hours while the assignments are unchanged; `-SkipPolicyInventory` skips it |
| R49 | Policy-installed extensions can hold a VM's Run Commands for minutes | **Mitigated:** retried for about 12.5 minutes, with the cause named |
| R51 | Without data disks, the T2 host needs about 80 GB free on its 128 GiB OS disk | **Mitigated:** the free-space check fails early and points to `dataDiskSku` `E10` |
| R53 | Every guest build downloads about 6.2 GB of pinned media, and a changed file fails its SHA-256 check | **Mitigated:** resumable retries; update the pin after checking the new file's source |
| R71 | The WebView2 installer's link always serves the latest release, so only its signature can be checked | **Mitigated:** HTTPS and a valid Microsoft Authenticode signature, or the step fails |
| R72 | Extension downloads inside the T2 guest fail intermittently, so the SQL Server extension can take 30 minutes or more to arrive | **Open:** no documented fix; the agent retries, and it's T2's critical path on a redeploy (about 2 to 40 minutes measured) |
| R73 | A managed Run Command recreated soon after its deletion can return the previous run's result | **Mitigated:** detected by its start time, retried once, and otherwise failed closed |
| R74 | Setup's interactive sign-in can leave sign-in data on the VM; the scripts remove it right after the wizard and verify none remains; the build fails if any remains | **Mitigated** |
| R75 | Removing Analysis Services and Integration Services from T1 depends on the image's setup media | **Mitigated:** a failure is a health warning, and the services stay stopped and disabled |
| R80 | A managed identity token issued before T1 joined the P6 group can stay cached for up to about 24 hours | **Mitigated:** T1 joins before it asks for its first token; the step retries for 10 minutes, then warns |
| R83 | Recreating T3 right after deleting it can find the name not yet released | **Mitigated:** run `start-demo.ps1` again a few minutes later |
| R87 | A managed identity's new group membership can take hours to apply | **Mitigated:** the warning names the measured wait, and the fallback is documented |
| R121 | Fabric's notebook part path differed between Learn examples | **Closed:** Fabric accepted `notebook-content.ipynb` (2026-10-21) |
| R122 | The notebook parameters-cell tag isn't stated on Learn | **Closed:** a job's parameters overrode the tagged cell (2026-10-21) |
| R142 | The Hub tenant setting's internal name isn't documented, and its title can change | **Mitigated:** matched by title; reading it needs a Fabric administrator |
| R183 | While a T3 activity profile runs, T3's serverless database can't auto-pause | **Mitigated:** profiles end before the auto-shutdown, `stop-demo.ps1` turns them off, and a VM start doesn't restart them unless asked |
| R188 | The evaluation-only T2 mode has no workload runner | **Accepted:** an opt-in mode, reported as **Not selected** |
| R189 | Defender scanning newly extracted files made a folder rename fail | **Closed:** the files are extracted in place, with retries |
| R196 | Rebuilding the T2 guest without a full redeployment isn't supported | **Accepted:** `destroy.ps1`, then `deploy.ps1` |
| R201 | With the Key Vault opt-in, a new role assignment takes minutes to reach Key Vault | **Mitigated:** the first write retries for up to 10 minutes |
| R210 | The Contributor-only path isn't proven end to end: the live runs used an operator who could also assign roles | **Open:** the default path created no role assignment and no Key Vault, verified live |
| R211 | Run Command instance views can't be scanned while the VMs are deallocated | **Mitigated:** a **Warning** that says so; scanned after each start |
| R212 | GitHub Actions logs and notebook exports must be downloaded before they're scanned | **Mitigated:** the procedure in [ADR 0009](adr/0009-secrets-handling.md) |
| R213 | T3 keeps sending telemetry while it's paused, so a fresh sample doesn't prove it's awake | **Accepted:** the readiness gate also checks T3's extended property |
| R214 | The Windows PowerShell 5.1 analyzer profile is Windows Server 2019's, while the VMs run 2022 | **Accepted:** the VM-side tests run in Windows PowerShell 5.1 |
| R215 | Validation's Preflight area takes about 10 minutes in a large tenant, mostly for the policy inventory | **Mitigated:** the inventory cache, `-SkipPolicyInventory`, or `-Area` without Preflight |
| R216 | A few helpers delete temporary files with `Remove-Item`, which an inherited `-WhatIf` skips | **Accepted:** validation calls none of them under `-WhatIf` |
| R217 | `validate.ps1` exits 1, not 2, for **Manual action required** with `-TreatManualAsError` | **Accepted:** the contract with the validate workflow ([ADR 0012](adr/0012-validation-model.md)) |
| R218 | The secret scanner can flag look-alike text, and miss a secret that matches no rule | **Mitigated:** filters, registered values, and gitleaks on the repository |
| R219 | Right after a restart, the bootstrap loader can still report Pending | **Mitigated:** a **Warning**, never a **Fail** |
| R220 | The Marketplace image installs Analysis Services and Integration Services on T1 | **Closed:** T1's bootstrap removes them (Phase 7) |
| R221 | The guest's port ACLs haven't been tested on their own, with the guest firewall off | **Open:** both were verified together live (2026-10-20) |
| R222 | Validation's T3 checks through T1 resume a paused T3, which then bills until it auto-pauses | **Accepted:** only while T1 runs; `-Target` leaves T3 out |
| R223 | Validation creates temporary Run Commands, and a run that's killed leaves one behind | **Mitigated:** the next run deletes a leftover first |
| R224 | `COST.AUTOSHUTDOWN` reads the schedules by name and type instead of by ID | **Closed:** the cost checks passed in Phase 20's and Phase 22's validation runs |
| R225 | gitleaks can't read a token in a UTF-16 file | **Mitigated:** logs stay in the Git-ignored `out/`, and the demo's scanner decodes UTF-16 |
| R226 | The subscription guard depended on the Azure CLI's default subscription | **Closed:** it checks the configured subscription's own sign-in (2026-10-21) |
| R227 | The gitleaks configuration exempts the public commit pins in `config/versions.json` from one default rule | **Accepted:** one rule, one file, and those keys only; tests check the scope |
| R273 | Whether a budget at a resource group's scope outlives the group wasn't documented | **Closed:** it does, so `destroy.ps1` deletes it (2026-10-22) |
| R283 | GitHub environments and their secrets were set by hand, although GitHub documents an API for them | **Mitigated:** `setup-github-oidc.ps1 -ConfigureGitHub` sets them up on request, with your own GitHub CLI sign-in (Phase 26c); without it, the script prints the `gh` commands |
| R330 | Restoring a pay-as-you-go install from a disk snapshot isn't documented | **Accepted:** validated twice live (Standard, pay-as-you-go, and monitoring), and disclosed in [limitations](limitations.md) |
| R331 | The golden snapshot holds the hosts' secrets, such as password hashes and the guest's Arc agent key | **Mitigated:** no network access and no export; captured only after a clean sign-in sweep (Phase 26d), and the passwords are rotated at restore |
| R332 | Any Contributor on the subscription can create a disk from the snapshot | **Accepted:** restrict the golden group with a role assignment if the subscription is shared |
| R333 | A copy of a live source could check in as the captured Arc identity | **Mitigated:** the Release fails closed when it can't read the agent, and resets the copy unless its agent names another identity (proven live, 2026-10-23) |
| R334 | The guest's evaluation period runs on inside the snapshot | **Mitigated:** `status.ps1` and preflight warn 30 and 7 days before it ends; a new capture needs a fresh build |
| R335 | The SQL Server extension's download (R72) is on T2's path at every restore | **Open** (R72) |
| R336 | Policy-installed extensions can block Run Commands for a while | **Mitigated:** the conflict retry; deallocating and starting the host cleared a long block |
| R337 | The parallel tracks' processes share one Azure CLI token cache | **Mitigated:** staggered starts and the guard's token retry; no conflict seen |
| R338 | Azure Resource Graph lists deleted Arc resources for a while after their group is gone | **Open:** the explicit Arc deletes run first, and the residual check reports the lag |
| R339 | A tenant's governance automation can give a demo identity a role assignment outside the demo, which outlives destroy | **Accepted:** not the demo's; the residual check reports it, and removing it needs Owner or User Access Administrator |
| R340 | The budget outlives its group (R273) | **Closed** |
| R341 | The 30-minute deploy target isn't met | **Open:** 38.8 minutes, then 63.7 with the overlaps, which had T1 and T3 ready at 26.8; T2's extension download (R72) is the critical path |
| R342 | Unified inventory drops uninstalled features only after the SQL IaaS Agent restarts | **Closed:** T1's step restarts it, and validation fails if they're still listed 10 minutes later |
| R343 | `t2Source` `auto` builds T2 when no usable snapshot exists | **Accepted:** `PREFLIGHT.T2.SOURCE` says which source and why |
| R344 | A reused policy inventory can miss a changed definition behind an unchanged assignment | **Accepted:** the what-if still runs, and the cache lasts 168 hours at most |
| R345 | The parallel deploy differs from the sequential one in side effects | **Mitigated:** the two found live are fixed, and `-Sequential` stays |
| R346 | The runner's status can exceed Run Command's 4,096 bytes of output, so the bounds check can't read it | **Open:** with Phase 25b's longer outcomes, `WORKLOAD.<target>.BOUNDS` was a **Warning** on every target in Phase 25d's live run; the runner still clamps every scenario to its limits, and a compact status for the check is a follow-up |
| R347 | The golden snapshot's quarantine test needs quota for one more host and takes over an hour | **Accepted:** it checks the quota first |
| R348 | `configure-fabric-app.ps1` might take parameters the Fabric track doesn't pass | **Accepted:** the track passes only the parameters the script declares |
| R349 | The notebooks carried real Fabric workspace and lakehouse IDs | **Closed:** the notebooks carry no Fabric IDs, and the import injects the resolved ones (Phase 26a) |
| R400 | Updating an existing flexible server in a redeploy might be refused, or restart it | **Closed:** it succeeded, with the server ready throughout (2026-10-26) |
| R401 | T1's managed identity might not sign in to T4 as the P6 group's role | **Closed:** it did (2026-10-26) |
| R402 | T1's identity is a T4 administrator through the P6 group, as it is T3's | **Accepted** (R26) |
| R419 | Creating T4 makes a first deploy's template take longer: 8 minutes 45 seconds instead of about 2 | **Accepted:** only when T4 is created |
| R440 | A subscription's automation can switch a deallocated VM's disks to another type, which made the template fail | **Mitigated:** `deploy.ps1` keeps the current types with a **Warning**, and `status.ps1` reports the drift |
| R441 | Azure can refuse T4's size with `SkuNotAvailable` although the region lists it | **Mitigated:** a **Fail** that names the next size, chosen with `t4SkuName` and `t4AvailabilityZone` |
| R442 | T1's monitoring plugin may not come back after a start | **Mitigated:** the start waits up to 5 minutes for the plugin's status before it restarts the agent (Phase 25b); proven live in Phase 25d, where the plugin reported 36 seconds into one start and came back 209 seconds after a restart in another |
| R480 | Without a body, the runbooks' Windows PowerShell 5.1 sent a POST in a form encoding that the PostgreSQL resource provider refuses, so the control couldn't start or stop T4 | **Closed:** a POST without a body sends an empty JSON object; T4's start and stop through the runbooks proven live (Phase 25d) |
| R481 | A second run of `setup-activity-control.ps1` unlinked the daily T4 safety stop: Azure Automation names the schedule's time zone in another form, and refused the old link ID | **Closed:** setup compares the zones' rules and gives a new link a new ID; relinked and checked live (Phase 25d) |
| R482 | T4's profile lane can't end runs an earlier host left Running, so after a host restart T4's baseline waits for that run's deadline | **Open:** T4's refused starts are now tried again every 30 seconds, as on T1 to T3; recovering T4's runs is a follow-up |
| R483 | On a 2-vCPU target under `capacity-max`, sessions can time out waiting to open their connections, which failed the run on T2 | **Mitigated:** an open that timed out behind other opens is tried again within the connect window; not yet run live |
| R484 | `capacity-max` on T1 saturates `sqlvm01`, which also runs T3's and T4's sessions: T1's profile read took over 150 seconds, and T4's baseline couldn't connect | **Accepted:** the bounded reads and the retries keep each lane serving; T3's `capacity-max` runs in a round of its own |
| R485 | A deploy can leave T1's monitoring plugin not running, and the T2 track could pass while its host had failed | **Mitigated:** the deploy restarts the agent (`DEPLOY.T1.MONITORING`) and waits for T2's host (`DEPLOY.T2.READY`); unit-tested, not yet run live |
| R486 | An on-demand run's auto-stop counts from the request, so targets that start slowly get less of their activity | **Accepted:** the auto-stop bounds the cost; a T4 that can't start no longer delays the others |
| R487 | The control notebook's workspace needs a managed virtual network, so each request waits for a Spark start | **Accepted:** 107 to 166 seconds live; the demo's own workspace keeps its fast starts ([ADR 0020](adr/0020-on-demand-activity-control.md)) |
| R488 | `status.ps1` shows a VM's health **Warning** without its reason | **Open:** the reason is in the VM's health file (on `sqlvm01`, the one-time recovery of SQL Server administrator access); showing it is a follow-up |
| R489 | `-GrantRole -WhatIf` doesn't list A3, and setup's summary says ready while one of its steps warns | **Open:** the real run grants and checks A3 (**Pass** live); a follow-up |
| R523 | A file scan can't prove that deleted sign-in data is gone from a disk's free space, so the golden snapshot can hold fragments of its guest build's sign-in, which expired within about an hour | **Open:** `capture-t2-golden.ps1 -WipeFreeSpace` zero-fills the free space after the sweep; the recapture replaces the current snapshot, which stays until the new one is proven (Phase 26d) |
| R528 | Run Command hands protected parameters to a script as arguments, so the Windows PowerShell log records the one-time host password and, in `ProductKey` mode, the SQL Server product key | **Mitigated:** the Run Command that receives the value drops its own closing event and clears that log when it holds the value (a **Warning**: endpoint protection may notice); the sweep finds product keys in older entries. Left: a value from a Run Command stopped before its search (until the next rotation or `-Clean`), a copy that endpoint protection sent off the VM, and the Security log when process-creation auditing records command lines (**Manual action required**) (Phase 26f) |
| R530 | Direct Lake doesn't see tables that a notebook has just created in a new lakehouse for a while (about 20 minutes on 2026-10-27), so a first deploy's model refresh failed with 0xC14700DF | **Mitigated:** `configure-powerbi.ps1` refreshes again every 2 minutes for up to 30 minutes while that error lasts, and a **Fail** at the end says to wait or to run the notebook (Phase 26g; the retry itself isn't proven live yet) |

## Phase log

One short entry per phase, in order: what it built, what was proven live, and when. Phases 0–2 (the inspection, a documentation check, and the blocking questions) produced the plan. New phases add their entry at the end.

### Phase 3: Architecture and ADRs

2026-10-19. The architecture, the automation support matrix, the draft security model, the prerequisites and permissions, and ADRs 0001–0016, including the plan's second revision and the subscription guard rule. Documentation only; the 24 facts the ADRs depend on were checked against Microsoft Learn.

### Phase 4: Scaffolding

2026-10-19. The shared PowerShell module `DbHubDemo` (the redacting logger, the six-status result model, the configuration loader, and the subscription guard), the configuration schema, the static validation and CI, the .NET workload generator's skeleton, the devcontainer, and the repository's templates. No live work.

### Phase 5: Foundation infrastructure

2026-10-19 and 2026-10-20. Subscription-scope Bicep for the resource group, the network and its NSGs, and the budget; `preflight.ps1`, with a read-only Azure Policy inventory and a what-if; and `estimate-cost.ps1` on the Retail Prices API. Live: the foundation deployed in about a minute and converged on a redeploy. The policy inventory showed that the tenant's policies force storage accounts to turn off shared-key and public network access, so the planned artifact cache was dropped, and the bootstrap bundle travels in Run Command chunks instead. A policy that turns off public network access on SQL servers makes `networkMode` `auto` resolve to private. The $250 hard monthly ceiling was set here.

### Phase 6: T1 VM, T2 nested host and guest, SQL

2026-10-19 and 2026-10-20. T1 `sqlvm01` with SQL Server 2022 Standard pay-as-you-go; the T2 host `archost01` with its nested guest `arcsql01`, built from pinned evaluation media; the deterministic `ContosoCare` database; and bootstrap delivery in SHA-256-checked Run Command chunks, with no storage account. Live (2026-10-20): both VMs deployed in about 6.5 minutes, the chunks arrived, and T1 was **Ready** with `ContosoCare`. Two defects were found and fixed live: the bootstrap folder's permissions, and the guest image's boot files, which need `bcdboot /offline` on an updated host.

### Phase 7: T2 Arc onboarding, SQL Server enabled by Azure Arc, and T1 SQL VM monitoring

2026-10-20 and 2026-10-21. `configure-arc.ps1` onboards the guest with the caller's short-lived token as a protected parameter and converges the Azure extension for SQL Server with pay-as-you-go and monitoring; `configure-monitoring.ps1` turns on T1's SQL VM monitoring. Live: T1's telemetry about 2 minutes after its flag was set, and Arc **Connected** on 2026-10-20, with IMDS and the wire server unreachable from the guest. The setup-wizard step ran on 2026-10-21; its sign-in needed the WebView2 runtime in the guest, which a host step now installs. The SQL Server extension then took about 30 minutes to arrive (R72), and T2's telemetry came about 7 minutes after monitoring was on. Two more steps came out of that session: T1's bootstrap removes the image's Analysis Services and Integration Services, and a cleanup step removes the sign-in data that setup can leave on the VM (R74).

### Phase 8: Azure SQL Database (T3)

2026-10-20. T3: the General Purpose serverless `ContosoCare` database, Microsoft Entra-only with the P6 group as its administrator, private when policy requires it, on the free offer when it's available, and configured from T1 through its managed identity. Live (2026-10-20): deployed in about 3 minutes; T1 ran T3's 36 setup batches in 9 seconds over the private endpoint; and every T3 check passed, with the free-offer fallback as the expected **Warning**.

### Phase 9: Database Hub prerequisites and monitoring validation

2026-10-20. The Hub checks: Estate through Azure Resource Graph, telemetry for each target through the documented telemetry endpoint, T3's readiness gate, and presenter access. Live (2026-10-20): `HUB.ESTATE.T1` and `.T3` and `TELEMETRY.T1` and `.T3` **Pass**, with T3's first telemetry 2.8 minutes after its creation; T2 followed once it was onboarded.

### Phase 10: Agent skills (prompt pack and install guide)

2026-10-20. The Database Agent prompt pack, with an in-Hub and a skills prompt for each scenario and a fallback ladder, and the install guide for the `microsoft-sql-fdh` and `microsoft-sql` plugins, with a schema and tests for the prompts. Nothing can run the agent from code, so its live coverage record waits for a rehearsal.

### Phase 11: Scenarios and workload generator

2026-10-20. The `ContosoCare.Workload` runner; bounded scenario procedures with stop flags, and a reset that touches only `ContosoCare.Demo/` sessions; the healthy baseline and seven incidents; and the activity profiles. Tested against a local SQL Server, and run live in Phase 20.

### Phase 12: Fabric notebooks

2026-10-20 and 2026-10-21. `NB_DatabaseHub_Deployment`, the validator, and `NB_DatabaseHub_LiveActivity`, the live analysis, with their import through the Fabric REST API. Live (2026-10-21): a paused capacity blocked the first import, which now reports **Manual action required**. Once the capacity ran, both notebooks were imported and read back, and the deployment notebook ran read-only in 57 seconds; the telemetry endpoint accepted the notebook's own token (R29).

### Phase 13: One-click deployment, GitHub Actions, and the workload runner on the VMs

2026-10-20 and 2026-10-21. Milestone A installed the workload runner on the VMs. Milestone B added `deploy.ps1` with resumable stages; the lifecycle scripts (start, stop, status, reset, destroy, and demo-control); on-demand Bastion; the Key Vault opt-in; and the GitHub workflows with OpenID Connect. The guard update made every script independent of the Azure CLI's default subscription. Live: the runner ran the baseline on T1 and T3 until two minutes before the nightly auto-shutdown, and T3 auto-paused 15 minutes later (2026-10-20); the guard passed with another tenant's subscription as the default (2026-10-21).

### Phase 14: Validation and security

2026-10-21. `validate.ps1`, the live check catalog in eleven areas; the secret scanner, with UTF-16 logs; the gitleaks configuration; the Windows PowerShell 5.1 analyzer rules for the VM-side scripts; the final threat model; and the role matrix. Live (2026-10-21, read-only, T1 and T3): 73 checks, none **Fail**: 44 **Pass**, 18 **Warning** (mostly for a deallocated VM), 2 **Manual action required**, and 9 **Not selected**.

### Phase 15: Demo walkthrough

2026-10-20 and 2026-10-21. The 15- and 30-minute presenter scripts, each step with its time, narration, expected signal, fallback, and reset, and a test that checks them. The rehearsal is still to come.

### Phase 16: Cleanup testing

2026-10-21 and 2026-10-22. `destroy.ps1`'s manifest, the deletion of the deployment record and of the group's budget, and the residual check, with opt-in teardown tests and a deployment-stack trial. Live, in a disposable test environment: a fresh sequential build (T1 ready at +58.5 minutes, T3 at +62.9, and T2 after two runs), which found and fixed a race in the T2 host's DNS forwarder; the guard's retry after a Continuous Access Evaluation challenge; a stop in 4.2 minutes; and a destroy after which the residual check, and a subscription snapshot compared with the one before deploy, found nothing of the environment left. The cycle came to about $4.50 at list price ([cleanup](cleanup.md#tested-results)).

### Phase 17: Final docs and report

2026-10-21. Troubleshooting, the official sources, the FAQ, limitations, cost management, the automation matrix's final pass, and this report's first summary.

### Phase 18: The Real-Time Dashboard as code

2026-10-21. `RTD_DatabaseHub_LiveView`, a KQL dashboard defined as code over the telemetry endpoint, which queries as each viewer; its import and read-back; a check of each tile's data; the Hub's monitor-template wizard as a walkthrough moment; the presentation docs; and viewer licensing (P11). Live (2026-10-21): imported in 35 seconds, read back identical in content, and 14 of 14 tiles returned data.

### Phase 19: The Power BI history report and its semantic model

2026-10-21 and 2026-10-22. The live-activity notebook's report tables; `SM_DatabaseHub_History`, a Direct Lake model with 103 measures, as TMDL; `RPT_DatabaseHub_History`, four pages as PBIR from a deterministic generator; and `configure-powerbi.ps1`, which deploys, refreshes, and checks every measure with DAX. Live (2026-10-22): deployed in 265 seconds, with 98 of the 103 measures returning data (the other five need a scenario run), and the four pages rendered in Power BI Desktop. The org app that was planned was dropped in favor of the Fabric App.

### Phase 19b: The Insights app (a Fabric App over the history model)

2026-10-22. `APP_DatabaseHub_Insights`, a read-only Fabric App (preview) built with the Rayfin SDK: four pages, custom visuals, DAX and CSV export on every visual, and ready-made prompts for the Database Agent, deployed by `configure-fabric-app.ps1`. Live (2026-10-22): `rayfin up` updated the item in place in 47 seconds, every query in its catalog returned rows, and the app loaded and connected when opened from its workspace item. Opened from its hosted URL, the preview's sign-in hand-off fails.

### Phase 20: Fast redeploy (parallel tracks and a T2 golden snapshot)

2026-10-21 and 2026-10-22. `deploy.ps1` runs T1 with T3, T2, and Fabric as parallel tracks, and restores T2 from a golden snapshot of the finished host, captured once after the setup wizard and proven in quarantine first ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md)). Live (2026-10-22), in steps G1 to G11: the snapshot was captured (G1) and proven in quarantine in 75 minutes (G3); the demo environment was destroyed in 18.4 minutes (G5) and redeployed in 38.8 with no manual step (G6); validation ran in full (G7); all eight scenarios and 11 ten-minute incidents ran across T1, T2, and T3, with every reset **Pass** (G8); second deploys converged in 25.9 minutes with changed code and 21.8 with the same code (G9); and a stop and a timed start took about 6 minutes and 481 seconds (G10). The defects found live were fixed, among them the explicit Arc deletes, T1's inventory and monitoring plugin, and a Fabric track that stopped at once. The 30-minute target wasn't met ([deployment](deployment.md#parallel-tracks-phase-20)).

### Phase 21: The README front door

2026-10-22. The README: what's deployed; every step, automated or manual, with why, how long, and who; the prerequisites and how each is checked; redacted screenshots and command output; a quick start with measured times; and the presentation surfaces.

### Phase 22: Faster redeploy (the follow-up overlaps) and one timed destroy and redeploy

2026-10-23. The overlaps: the tracks' guards run while the template deploys, T2's restore starts as soon as its host exists and sends its artifacts during the Release, T1's bundle and runner go in one wave with its monitoring set up beside its bootstrap, and T3 is set up first. Live (2026-10-23): a destroy in 1,191 seconds, then a redeploy in 63.7 minutes with no check **Fail**. T1 and T3 were ready at +26.8 minutes, 9.5 minutes sooner, but T2 only at +61.7, because the SQL Server extension's download in its guest took about 29.5 minutes (R72). A second deploy converged in 19.2 minutes. The golden Release's identity reset was fixed and proven live ([deployment](deployment.md#faster-redeploy-phase-22)).

### Phase 24: T4, an Azure Database for PostgreSQL flexible server

Built 2026-10-23, live 2026-10-26. T4 `pgflex01-<id>`: PostgreSQL 18 with the `contosocare` database, Microsoft Entra only, virtual network integration, and its own bounded scenarios; a T4 track in the deploy; start and stop with the demo; and status, validation, and cost ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md)). Live (2026-10-26): West US 3 refused `Standard_B1ms` and `Standard_B2s` (R441), so T4 runs on `Standard_D2ds_v5`. The deploy that created it took 40.3 minutes, a second deploy 20.1, and a stop, a start, and a stop 6.7, 7.9, and 6.2 minutes. T1's identity signed in to T4 as the P6 group's role, and T4's scenarios ran. A redeploy also met VM disks that the subscription's automation had switched while the VMs were deallocated; `deploy.ps1` now keeps them, with a **Warning** (R440).

### Phase 25b: Diverse SQL incident scenarios, and Phase 25a's findings

2026-10-23 and 2026-10-26. Eight more bounded scenarios, one per wait family (`blocking-chain`, `deadlock-storm`, `tempdb-contention`, `memory-grant-pressure`, `parallel-scans`, `log-flush-waits`, `slow-consumer`, and `capacity-max`), with their prompts and notebook rules. Also the fixes for what Phase 25a's long incident program found on 2026-10-23: a supervised profile host with a heartbeat, retries for refused starts, T1's and T2's CPU from `SQLProcessCPUPercent` (`AvgCPUPercent` is 0 for SQL Server in this preview), and the Insights app check's time range; and, from Phase 24, the start's wait for T1's monitoring plugin (R442). Tested statically and against a local SQL Server; not yet run live.

### Phase 25c: The on-demand activity control

2026-10-26. The optional control: a Fabric notebook sends one bounded request to an Azure Automation webhook, whose runbook checks it against the scenario catalog, creates the run's auto-stop first, and starts the targets; **Stop now**, the auto-stop, and a daily T4 safety stop end it. `setup-activity-control.ps1` sets it up with Contributor, and an Owner grants its one custom role once; its vault is public or private, depending on the tenant's policy ([ADR 0020](adr/0020-on-demand-activity-control.md)). Unit-tested; not yet proven live.

### Phase 26a: Fabric resources by name

2026-10-27. The repository stores no Fabric ID ([ADR 0021](adr/0021-fabric-resources-by-name.md)). The configuration names the workspace, the lakehouse, and the capacity; the scripts resolve their IDs at run time through documented Fabric REST calls, and create a missing workspace and lakehouse while `fabric.createIfMissing` allows it, never changing a capacity. Every consumer uses the resolver: the Fabric scripts and the deploy's Fabric track, preflight's P5, `status.ps1`, `validate.ps1`, the activity control's setup, and the notebook runs. The notebooks carry no IDs: the import binds the resolved ones, and a first deploy imports missing notebooks without asking. Live (2026-10-27): the lookup by name, read-only, then the create path end to end in a test workspace (Phase 26g).

### Phase 26b: First-run automation

2026-10-27. A first run in another tenant takes `az login`, `./scripts/init.ps1 -CreateAdminGroup`, `./scripts/preflight.ps1`, and `./scripts/deploy.ps1` ([ADR 0023](adr/0023-first-run-automation.md)). `init.ps1` writes the Git-ignored configuration from your sign-in and asks only when there's a choice, and `-CreateAdminGroup` creates the P6 group with you as its owner where the tenant allows it. `configure-fabric-app.ps1 -SignIn` runs the Rayfin CLI's one-time sign-in; the opt-in `fabric.manageCapacity` resumes a paused capacity at start and pauses only what it resumed, for a capacity that's yours alone; `stop-demo.ps1 -SaveHistory` runs the live-activity notebook after the VMs stop, to save the session's history; and a dev container, also for GitHub Codespaces, carries every tool. Live (2026-10-27): `init.ps1` ran read-only against a live subscription; the first run end to end is still to be proven.

### Phase 26c: A public repository: fork-safe workflows, masked Actions logs, and the GitHub setup

2026-10-27. What a public repository needs ([ADR 0022](adr/0022-public-repository-and-github-actions-hardening.md)): workflows that are safe with forks (no `pull_request_target`, read-only permissions by default, and every workflow that reaches Azure run by hand or on a schedule, in a GitHub environment); the identifiers kept as environment secrets and masked in Actions logs, job summaries, and result files; `setup-github-oidc.ps1 -ConfigureGitHub`, which creates the environment with you as its required reviewer and sets its secrets, with an opt-in schedule environment; `setup-github-repo.ps1`, which applies a ruleset on the default branch, secret scanning with push protection, private vulnerability reporting, and Dependabot alerts; internal names in code and test fixtures replaced by the facts they stood for; and the community files and the README's "Getting help". Built and unit-tested; the GitHub setup scripts haven't run against a public repository yet.

### Phase 26d: No operator token left anywhere

2026-10-27. Nothing from the operator's sign-in stays on the VMs, in the T2 guest, in their logs, in Run Command resources, or in snapshots ([ADR 0009](adr/0009-secrets-handling.md#phase-26d-amendment-no-operator-token-left-anywhere-2026-10-27), [ADR 0005](adr/0005-arc-onboarding-authentication.md#amendment-the-host-identity-whenever-its-attached-phase-26d-2026-10-27)). A sweep finds token-shaped values on each VM and in the guest, reporting counts and locations only, and removes them after the setup wizard, after every Arc onboarding, before a golden capture, and in a copy of the snapshot; `check-sign-in-data.ps1` runs it on demand, and a result fails closed while anything is left. Arc onboarding uses the host's identity whenever it's attached, and otherwise hands the caller's token to the guest's agent in a protected file that's zeroed and deleted right after, with the command line only as a fallback that reports a **Warning**. `capture-t2-golden.ps1 -WipeFreeSpace` zeroes the guest's free space before a capture. The docs describe the sign-in data in neutral words, and a test keeps them that way. Live (2026-10-27): a read-only audit of the running VMs found sign-in data from an earlier onboarding in a host log, which the automatic flow now clears; the host-identity onboarding and the free-space wipe are proven with the next golden capture.

### Phase 26e: Public docs

2026-10-27. This report became a concise public summary of the build, with the risk register and this log. The docs, the README, and the changelog were generalized for the public repository: phase names instead of pull request numbers, the tenant's policies and governance automation without their internal names, no operator-specific details, and links that point to the public repository. No file names the archive repository any more: the JSON schemas' `$id` URLs and the Real-Time Dashboard's name-based element IDs follow the public repository's URL, and a conventions test keeps the old name out. The neutral-wording test now covers this report too.

### Phase 26f: Protected values in the host's PowerShell log

2026-10-27. Run Command hands protected parameters to a script as arguments, so the Windows PowerShell log recorded the one-time host password and, in `ProductKey` mode, the SQL Server product key (R528). The Run Commands that receive them now turn off their session's further engine events and, after use, search that log for the exact value in memory and clear it only when it's there: a **Warning**, because endpoint protection may notice, or **Manual action required** with the command when it can't be cleared. The Security log is never cleared. The sign-in data sweep also finds product-key-shaped values, ignoring placeholders and masked keys, so `-Clean` removes older entries ([ADR 0009](adr/0009-secrets-handling.md#phase-26d-amendment-no-operator-token-left-anywhere-2026-10-27)). Proven on Windows PowerShell 5.1 with a test value: turning the events off drops the session's closing event, and the exact search finds the other seven. The password's Run Command runs live with the next golden capture.

### Phase 26g: The create path, live

2026-10-27. A new user's Fabric side, proven from nothing, by name, with no ID in the configuration, in a uniquely named test workspace on the demo's capacity. `init.ps1 -NonInteractive` wrote the configuration: names only, `fabric.importNotebooks` true, and `fabric.manageCapacity` false. Preflight's P5 was a **Warning**, because the workspace didn't exist yet. Then the deploy's Fabric track ran. `configure-fabric.ps1` created the workspace on the capacity and the lakehouse with schemas, imported both notebooks without asking and the Real-Time Dashboard, and ran the live-activity notebook once, in 3.8 minutes. `configure-powerbi.ps1` created the model and the report, and `configure-fabric-app.ps1` deployed the Insights app in 4.8 minutes. One defect: the model's first refresh failed with 0xC14700DF, because Direct Lake didn't see two of the five new tables for about 20 minutes, and the same refresh passed later, unchanged. The refresh is now sent again every 2 minutes for up to 30 minutes while that error lasts (R530). The data check and the app's checks passed, apart from the **Warnings** for an empty history and the known **Manual action required** steps: the browser check, and a tenant setting only an administrator can read. The test workspace was deleted afterward with Delete Workspace.

### Phase 25d: Phases 25b and 25c, live

2026-10-27. The live proof of Phase 25b's eight scenarios and Phase 25c's on-demand activity control, with fixes for what it found. A converging deploy first failed the runner's setup on T1 and T2, because it looked for one procedure name per scenario, and three of the new scenarios name others; it now checks each scenario's own. Each new scenario then ran for 8 minutes on T1, T2, and T3 at once, and the telemetry showed the waits it's designed for: lock waits with 124 and 140 deadlocks in T1's and T2's windows, blocking chains of up to 9 sessions with lock escalation, tempdb page latches from about 120,000 temporary tables on T1 and on T2, memory-grant queues, parallelism, log flushes, network waits, and CPU at 97 to 100 %. On T3, at 1 vCore, the parallel reports ran serially, as designed. The profile host waited for a run still ending instead of refusing a new one, and ended the runs an earlier host had left Running. The live-activity notebook found CPU windows on T1 and T2 for the first time, among 46 incident windows, and every query of the Insights app returned rows. The control's setup chose the private path, the owner's grant created its role and three assignments, and notebook requests started the targets and their scenarios; a second request was refused while one was active, and **Stop now**, the run's auto-stop, and `start-demo.ps1`'s takeover each worked. Fixed along the way: the runbooks' T4 start and stop (R480), the safety stop's link on a second setup (R481), retries for T4's refused starts (R482) and for connections under `capacity-max` (R483), the deploy's T1 plugin restart and wait for T2's host (R485), a notebook drivable by the job API, and lookups that the Windows command line couldn't pass.
