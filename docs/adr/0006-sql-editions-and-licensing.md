# ADR 0006: SQL Server editions, guest OS, and licensing

- **Status:** Accepted
- **Date:** 2026-10-19 (revised the same day for plan §9, Revision 2; amended 2026-10-29 for Phase 28: one command, one guided stop; and 2026-10-30: setup's Azure sign-in and IE Enhanced Security Configuration)
- **Decision source:** User-directed (Q1a, Q1b, Q2a, Q2b, Q2c) and plan §9.2 (T2 install modes), §9.4 (C6); the owner's decision of 2026-10-29 for the guided stop (user-directed)
- **Related:** [ADR 0003](0003-t2-host-size-security-type-bootstrap.md), [ADR 0005](0005-arc-onboarding-authentication.md), [ADR 0009](0009-secrets-handling.md), [ADR 0015](0015-mirroring-deferral.md), [ADR 0016](0016-cost-profiles.md), [ADR 0018](0018-fast-redeploy-parallel-tracks-golden-snapshot.md), [limitations](../limitations.md)

## Context

- **Hub Performance needs Standard or Enterprise.**
  - SQL Server on Azure VMs: Developer, Express, and Evaluation get only partial monitoring (connection data).
  - SQL Server enabled by Azure Arc: monitoring needs Standard or Enterprise with a pay-as-you-go (PAYG) or Software Assurance license type, and the Azure extension for SQL Server at version 1.1.2504.99 or later.
- **T1:** the Marketplace image `MicrosoftSQLServer:sql2022-ws2022:standard-gen2` bills the SQL Server Standard license per hour while the VM runs.
- **T2 PAYG without a product key** is documented only in the interactive setup wizard: on the Edition page, choose "Use pay-as-you-go billing through Microsoft Azure". The command-line reference has Azure-extension parameters but no PAYG edition option, and omitting `/PID` installs Evaluation.
- **Arc PAYG billing** for Standard is per core-hour. The example list price is $0.10 per core-hour (Retail Prices API, 2026-10-19; `estimate-cost.ps1` recomputes it live). The billable core count for a 2-vCPU guest is to be confirmed in Phase 7, from the `sqlServerInstance` or the extension's billing data.
- **Disconnection:** per the licensing docs, a PAYG installation that stays disconnected for more than 30 days is no longer authorized for use until it reconnects.
- **Guest OS:** Windows Server 2022 Datacenter Evaluation lasts 180 days. How Windows guests in nested Hyper-V on Azure are licensed isn't documented; the owner accepted this (Q1a, risk R21).

## Decision

### T1 `sqlvm01`

- SQL Server 2022 **Standard** from `MicrosoftSQLServer:sql2022-ws2022:standard-gen2`.
- `Microsoft.SqlVirtualMachine/sqlVirtualMachines` with `sqlServerLicenseType: PAYG`.

### T2 `arcsql01`: guest OS

- Windows Server 2022 Datacenter **Evaluation**, Desktop Experience.
- The media URL and SHA-256 are pinned in `config/versions.json` and can be overridden by parameters. The media downloads directly from that Microsoft URL and is checked against the SHA-256; the artifact cache that used to hold a copy was dropped on 2026-10-20 (ADR 0016, C9).
- `status.ps1` warns 30 days and 7 days before the evaluation expires. `reset-demo.ps1 -RebuildGuest` rebuilds the guest.

### T2: SQL Server install modes (`t2SqlInstallMode`)

| Mode | How | Manual steps | Hub Performance | Arc license type |
|---|---|---|---|---|
| `PaygWizard` (default, Q2b) | Guest build is automated; **one documented setup-wizard step** per guest build: "Use pay-as-you-go billing through Microsoft Azure", then Standard. Since Phase 28, a guided stop in `deploy.ps1`'s run, with setup pre-filled ([amendment](#amendment-one-command-one-guided-stop-phase-28-2026-10-29)) | One per guest build; automation resumes when it detects the instance | Yes | PAYG |
| `ProductKey` (prerequisite P10) | Unattended `/PID` install. The key is a secure input passed only in protected Run Command parameters and never stored (ADR 0009). | None | Yes | PAYG or Paid (Software Assurance), per the customer's entitlement, which they attest to |
| `Developer` | Unattended Developer edition install | None | **No. Estate only.** | Not applicable |

- In every mode, the resource-group tag `ArcSQLServerExtensionDeployment=PAYG` drives the extension's license type at auto-deploy, and the orchestrator verifies or sets the instance's license type afterward.
- **Order:** `PaygWizard` onboards Arc before the wizard; the other modes onboard after the install (ADR 0005).
- The wizard steps are in [deployment](../deployment.md) and in the **Manual action required** message, with an on-demand Bastion link.

### Opt-in Azure Hybrid Benefit (C6)

- `windowsHybridBenefit` sets `licenseType: Windows_Server` on T1 and the T2 host.
- `sqlHybridBenefit` sets T1's `sqlServerLicenseType: AHUB`.
- Each needs an explicit entitlement attestation parameter. Without it, deployment fails closed.

### Evaluation-only fallback (Q1b)

- If the nested preflight fails **and** the operator opts in with `t2Mode = EvaluationOnlyAzureVm`, T2 becomes an Azure VM onboarded with Microsoft's documented evaluation procedure.
- It's labeled **evaluation only** in the docs, in every validator result (`evaluationOnly: true`), and in the walkthrough. It's never used silently.

### Mirroring

Excluded from v1 (Q2c, ADR 0015).

## Consequences

- **Positive:** every target can show Hub Performance in the default and `ProductKey` modes. Zero-touch options exist for customers who need them.
- **Negative:**
  - SQL licenses bill while the VMs run (ADR 0016).
  - The default mode keeps one manual step per guest build (plan risk R25); since Phase 28 it's a guided stop of about 10 minutes in `deploy.ps1`'s run, and a golden snapshot (ADR 0018) still removes it from redeploys.
  - A T2 host left deallocated for more than 30 days breaks Arc PAYG. `status.ps1` warns at 21 and 28 days disconnected, and the expiry workflow can park or destroy T2 (C4).
- **Risks accepted:** guest OS licensing in nested Hyper-V isn't documented (R21). The owner confirmed the evaluation approach.

## Validation

- **Phase 6 (live, pending go-ahead):** each install mode produces the expected edition (`SERVERPROPERTY('Edition')`). `PaygWizard` done on 2026-10-21: Standard Edition (64-bit).
- **Phase 7 (live, pending go-ahead):** the Arc `sqlServerInstance` shows the expected edition and license type; monitoring is enabled; the billable core count is recorded. Done for `PaygWizard` on 2026-10-21 (see "Live validation" below).
- **Phase 9 (live, pending go-ahead):** telemetry arrives from T2 in `PaygWizard` and `ProductKey` modes. In `Developer` mode, the validator reports T2 Performance as **Not supported**. `PaygWizard` done on 2026-10-21.

## Phase 7 implementation notes (2026-10-20)

Implemented and statically tested; live validation pending.

- **Billable cores:** "Metering software usage" in manage-license-billing documents the rule for SQL Server on a VM: usage is metered on the virtual cores available to the OSE, with a minimum of four cores per OSE (checked 2026-10-20). `config/versions.json` records it as `arc.billing.minimumCoresPerOse = 4`.
  - `T2.ARC.SQLINSTANCE` records the instance's `vCore` and `cores` and estimates `billableCores` as the larger of 4 and `cores`. That evidence replaces the `t2ArcBillableCores` assumption.
  - The cost estimate defaults `t2ArcBillableCores` to the larger of the guest's vCPU count and the four-core minimum, so the 2-vCPU guest is estimated at 4 billable cores (rechecked on Learn 2026-10-20). Set `t2ArcBillableCores` only to override it.
- **Expectations per mode** (`Get-DemoArcExpectation`):
  - `PaygWizard`: Standard edition, license type PAYG.
  - `ProductKey`: Standard or Enterprise, PAYG or Paid.
  - `Developer`: Developer edition, any license type, and monitoring **Not supported**.
- **Azure extension for SQL Server:** `WindowsAgent.SqlServer` from publisher `Microsoft.AzureData`, version 1.1.2504.99 or later.
  - The resource-group tag `ArcSQLServerExtensionDeployment=PAYG` deploys it automatically, and the Phase 5 template already sets the tag.
  - If SQL Server is detected and the extension is still missing, `configure-arc.ps1` installs it through Machine Extensions - Create Or Update (2026-07-15) with `{ "SqlManagement": { "IsEnabled": true }, "LicenseType": "PAYG" }`.
  - A wrong license type is corrected with all the other settings copied, because an update overwrites every setting.
- **Monitoring:** `az resource update --set properties.monitoring.enabled=true --api-version 2023-09-01-preview`, as sql-monitoring documents. The instance is named with `--resource-group`, `--name`, and `--resource-type` instead of `--ids`, because `Invoke-DemoAz` adds `--subscription` to every call.
- **Disconnection:** `T2.ARC.DISCONNECTEDDAYS` reports:
  - **Pass** under 21 days.
  - **Warning** from 21 days.
  - A stronger **Warning** ("Reconnect now") from 28 days.
  - **Fail** after more than 30 days.
- **Evaluation-only fallback:** `t2Mode = EvaluationOnlyAzureVm` in the template deploys `infra/modules/arcsql01-eval.bicep` instead of `archost01`.
  - The VM is built from the plain Windows Server 2022 Datacenter Gen2 image, at the T2 host's size, in `snet-archost`. It has no data disk, no SQL IaaS Agent registration, and the tag `evaluationOnly=true`.
  - Its bootstrap role `EvalArcVm` (`vm/bootstrap/Invoke-EvalArcVmBootstrap.ps1`) runs these steps: `ArcEvaluationPrep` (`MSFT_ARC_TEST=true` at machine level, and the firewall rule `BlockAzureIMDS` for 169.254.169.254 and 169.254.169.253), the SQL Server media, the unattended install or the wizard step, the Arc wait, T1's SQL helpers with the `arcsql01` scripts, and finally `DisableAzureGuestAgent`.
  - Preflight reports `PREFLIGHT.T2.MODE` as a **Warning** labeled EVALUATION ONLY, and every T2 result in this mode carries the label.
- **Deviations from the evaluation procedure:**
  1. The procedure removes the VM's extensions and disables the Azure guest agent before the agent is installed. Here the guest agent is disabled **last**, at least 15 minutes after the Arc marker, because Run Command, which is itself an extension, carries the bootstrap and the onboarding. Until then, policy-installed extensions may stay.
  2. After the guest agent is disabled, Run Command no longer works on that VM, so `health.json` can't be read. T2 is then checked through its Azure Arc resources.
  3. `deploy.ps1`, still a stub, must send the bundle to `arcsql01` instead of `archost01` in this mode.
- **T1's associated services (live, 2026-10-20):** the SQL Server 2022 Standard pay-as-you-go Marketplace image installs Analysis Services and Integration Services next to the engine.
  - Unified inventory lists each as its own SQL Server instance resource (`serviceType` SSAS and SSIS).
  - All three instance resources report license type `LicenseOnly`. T1 is billed through the SQL virtual machine resource, which reports `PAYG`: unified inventory notes that SQL Server VM features are managed through the SQL virtual machines resource.
  - `T1.SQLVM.ASSOCIATEDSERVICES` reports the list, read-only.
  - Whether to stop or disable SSAS and SSIS on the 8 GiB VM was an open question for the owner. **Decided 2026-10-21:** turn them off, as the lightest default. The T1 bootstrap's `AssociatedServices` step (settings in `vm/dsc/sqlvm.psd1`):
    - stops and disables `MSSQLServerOLAPService`, `MsDtsServer160`, `SSASTELEMETRY`, and `SSISTELEMETRY160`;
    - then uninstalls the `AS` and `IS` features with the image's setup media (`C:\SQLServerFull\setup.exe /QUIET /ACTION=Uninstall /FEATURES=AS,IS /INSTANCENAME=MSSQLSERVER`), because unified inventory kept listing the instances while their services were only stopped.
    - A failed uninstall is only a warning in `health.json`; the services stay stopped and disabled.
  - **Live, 2026-10-21:**
    - The uninstall took 2.1 minutes, reported `Final result: Passed`, and removed all four services and both features' registry keys.
    - The engine and `ContosoCare` were unaffected.
    - About 6 minutes after the SQL IaaS Agent service restarted, both instance resources were gone. Resource Graph now lists only the engine, and `T1.SQLVM.ASSOCIATEDSERVICES` reports **Pass**; it now reports a **Warning** while associated services are still listed.

## Live validation of `PaygWizard` (2026-10-21)

- **The wizard step:** the Edition page's pay-as-you-go option, then Standard, installed Standard Edition. The Azure Extension for SQL Server page can't be skipped with pay-as-you-go and needs the operator's Azure Login (ADR 0005), which needs the WebView2 runtime; the host's `GuestWebView2` step installs it.
- **The instance resource:** `arcsql01` shows Standard edition, license type PAYG, SQL Server 2022, and about 4 billable cores for the 2-vCPU guest, which matches the four-core minimum the estimate uses.
- **The extension:** the wizard deployed `WindowsAgent.SqlServer` 1.1.3547.472 with an empty `LicenseType` setting; `configure-arc.ps1` set it to PAYG with the other settings kept. Provisioning took about 30 minutes because of intermittent download failures inside the guest (R72 in the implementation report).
- **Monitoring:** turned on by `configure-arc.ps1`; Phase 9's validator saw T2 telemetry about 7 minutes later.

## Amendment: one command, one guided stop (Phase 28, 2026-10-29)

**The owner's decision (2026-10-29, verbatim):** "I want the build to run and not give a template that is reliant on me. This whole thing should be one click independent for anyone." And: "I need to have performance data and database agent findings. I also need it to be straightforward for the user to spin up and deploy."

- **T2's default stays `PaygWizard`, as a guided wizard:** one command (`./scripts/deploy.ps1` after `az login`) with one prompted stop, after which the deploy finishes T2 by itself, with no second command ([deployment](../deployment.md#the-guided-stop-paygwizard), [ADR 0018](0018-fast-redeploy-parallel-tracks-golden-snapshot.md#amendments-2026-10-29-phase-28-one-command-one-guided-stop)).
- **The opt-in modes stay as they are:** `ProductKey` is fully unattended with the user's own Standard key and license type PAYG or Paid; `Developer` is fully unattended, with T2 in Estate only and no T2 performance data or Database Agent findings, which the deploy's **DONE** banner says plainly.
- **No shared golden image:** nothing depends on the owner's resources. A golden snapshot is per environment, captured by whoever deployed it (ADR 0018), so a first run anywhere builds T2 and has the guided stop.
- **The facts behind it** (Microsoft Learn, checked 2026-10-29): pay-as-you-go without a product key is documented only in setup's wizard: from the command prompt, `/PID` is optional and installs Evaluation without it, and there's no parameter that selects pay-as-you-go ([install from the command prompt](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt)). Arc monitoring, which feeds Hub Performance, needs Standard or Enterprise with license type PAYG or Software Assurance ([Arc SQL monitoring](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring)).

**What's automated around the person's choice**, with documented mechanisms only:

- **Setup pre-filled from a configuration file** ([install using a configuration file](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-using-a-configuration-file); `ACTION="Install"` with `UIMODE="Normal"`, so every page shows with its values in place): the Database Engine and the Azure extension (`FEATURES=...,AZUREEXTENSION`), the default instance, the virtual service accounts, `BUILTIN\Administrators` as sysadmins, TCP, no product updates during setup, and the Azure extension's subscription, resource group, region, and tenant (`AZURESUBSCRIPTIONID`, `AZURERESOURCEGROUP`, `AZUREREGION`, `AZURETENANTID`). The file holds no secret: generating it refuses `PID`, any password, a service principal, and the license acceptance, so the person accepts the license terms in setup. What's left for the person: **Use pay-as-you-go billing through Microsoft Azure** and **Standard** on the **Edition** page, **Use Azure Login** on the **Azure Extension for SQL Server** page, and **Install**.
- **The hops to that page:** a logon task in the guest opens the pre-filled setup, a logon task on the host opens [Virtual Machine Connection](https://learn.microsoft.com/windows-server/virtualization/hyper-v/virtual-machine-connection) to the guest at the operator's sign-in ([New-ScheduledTaskTrigger -AtLogOn](https://learn.microsoft.com/powershell/module/scheduledtasks/new-scheduledtasktrigger)), and the guest signs itself in once for the step ([ADR 0009](0009-secrets-handling.md#phase-28-amendment-the-guests-one-automatic-sign-in-and-the-portal-password-reset-2026-10-29)). Both tasks and the guest's setup folder are removed afterward.
- **Setup's Azure sign-in** (live finding, 2026-10-30): **Use Azure Login** is an Internet Explorer-based control, which IE Enhanced Security Configuration blocked though the WebView2 runtime was installed; MSAL.NET documents that legacy web view for Microsoft Entra ID authorities ([using WebView2 with MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/advanced/webview2)). So the 2026-10-21 reading above, that the sign-in needs WebView2, was at best half of it: IE ESC had been turned off by hand that day too. Before anyone is asked and before setup opens, the host checks WebView2 (installing it when it's missing), turns IE ESC off for administrators, and adds Microsoft's sign-in hosts to Trusted sites for the guest's Administrator; the guided stop's cleanup undoes both ([ADR 0009](0009-secrets-handling.md#setups-azure-sign-in-ie-enhanced-security-configuration-live-finding-2026-10-30), [deployment](../deployment.md#setups-azure-sign-in-ie-enhanced-security-configuration)). If the dialog still appears, the person selects **Add...** for each site it names.
- **The check of the person's result**, before anything is onboarded or configured: the default instance `MSSQLSERVER` runs, the guest's Administrator is sysadmin, the edition is Standard, and setup's generated `ConfigurationFile.ini` in its [log folder](https://learn.microsoft.com/sql/database-engine/install-windows/view-and-read-sql-server-setup-log-files) lists `AZUREEXTENSION`. Pay-as-you-go itself can't be read in the guest before the extension reports it; with pay-as-you-go, setup's Edition page can't leave the extension out, so the feature is the readable sign, and `T2.ARC.SQLINSTANCE` then checks the license type in Azure. A wrong install isn't onboarded: Evaluation, Developer, or Express gets setup's documented [edition upgrade](https://learn.microsoft.com/sql/database-engine/install-windows/upgrade-downgrade-sql-server-edition-setup) to Standard, and Enterprise (a downgrade), a named instance, a missing sysadmin, or no Azure extension get the documented [uninstall](https://learn.microsoft.com/sql/sql-server/install/uninstall-an-existing-instance-of-sql-server-setup) and a new install; the deploy keeps waiting and checks again.
- **Unchanged:** `GuestSignInCleanup` right after setup, Arc's PAYG and monitoring through `configure-arc.ps1`, and the `ProductKey` and `Developer` paths.

Unit-tested (`tests/unit/Vm.GuidedSetup.Tests.ps1`, `tests/unit/Vm.HostPlan.Tests.ps1`); not yet run live. A live proof needs a person at the guided stop.

## Sources (checked 2026-10-19)

Rechecked on 2026-10-20 for Phase 7: manage-license-billing, manage-autodeploy, manage-configuration, sql-monitoring, the SQL Server instance REST API (2026-01-01), and the evaluation procedure.

- Manage the Azure extension for SQL Server (license type and automatic deployment): <https://learn.microsoft.com/sql/sql-server/azure-arc/manage-autodeploy>
- Configure SQL Server enabled by Azure Arc (extension settings): <https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration>
- SQL Server Instances - Get (REST, 2026-01-01): <https://learn.microsoft.com/rest/api/arcdata/sql-server-instances/get>
- SQL Server on Azure VM performance monitoring: <https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm>
- Arc SQL monitoring: <https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring>
- Arc license types and billing: <https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing>
- Setup wizard: <https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-installation-wizard-setup>
- Command-prompt install: <https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt>
- SQL Server VM pricing guidance: <https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/pricing-guidance>
- Azure Hybrid Benefit for Windows Server: <https://learn.microsoft.com/azure/virtual-machines/windows/hybrid-use-benefit-licensing>
- Evaluate Arc-enabled servers on an Azure VM: <https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine>
