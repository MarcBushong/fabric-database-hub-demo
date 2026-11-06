# FAQ

## Getting started

**What do I need?**
Contributor on an existing Azure subscription, Database Hub enabled in your Fabric tenant, and an Entra security group you own for the Azure SQL admin. The notebooks also need a Fabric workspace on a running F or Trial capacity. The full list, P1–P11, with who provides each item, is in [prerequisites](prerequisites.md): P1–P6 are required, and P7–P11 are optional. An Owner once per environment is recommended for the nightly safety stop's role (P16); without one, the deployment still ends **DONE**.

**Do I have to change my Azure CLI default subscription?**
No. If you aren't signed in to the demo's tenant, sign in yourself with `az login --tenant <tenantId>` and press Enter at the subscription selector for no changes. Every Azure call names the configured subscription, and the subscription guard checks that subscription's tenant and account before anything is written; the scripts never sign in or change your default. On a shared machine you can give the demo its own Azure CLI profile ([prerequisites](prerequisites.md#optional-a-separate-azure-cli-profile)).

**What's the one command?**
`./scripts/deploy.ps1`, after `az login`. Since Phase 28 it writes your configuration on the first run, deploys everything, waits for T2 (with no person needed in the default `JumpstartImage` mode, or one guided stop in the opt-in `PaygWizard` mode), keeps your PC awake, shows a live status page, and ends **DONE** or **NOT DONE** with the exact next command. Run it again with no parameters to continue where it stopped. The GitHub Actions `deploy` workflow runs the same stages ([deployment](deployment.md#one-command-one-guided-stop-phase-28)).

**How long does the first deployment take?**
About 1 to 2 hours in the default `JumpstartImage` mode, an estimate not measured yet: most of it is T2, whose host downloads Arc Jumpstart's prebuilt SQL Server guest disk (34 GiB) and prepares it, with no person needed. The opt-in `PaygWizard` mode takes about 2 to 3 hours (an estimate from documented step times): most of it is the T2 guest build, which downloads about 6.2 GB of media, and a person is needed once, about 60 to 90 minutes in, for about 10 minutes. `ProductKey` and `Developer` take about 1.5 to 2.5 hours with no person. Later runs skip what's already in place, and a redeploy from an optional golden snapshot takes about 30 to 45 minutes (an estimate). The [deployment guide](deployment.md#expected-duration) records the measured durations, all from before `JumpstartImage`.

**Is it safe to run `deploy.ps1` again?**
That's the design: every stage is idempotent, state lives in the resource group's tags, and Arc onboarding detects an existing machine instead of creating a duplicate (`T2.ARC.NODUPLICATES`). Reruns on the live environment converged with no duplicate Arc resources in Phases 20 and 22 ([acceptance checklist](implementation-report.md#acceptance-checklist)).

## Design choices

**Why Standard edition instead of Developer?**
Hub Performance needs Standard or Enterprise. On Developer, SQL VMs report only connection data, and Arc monitoring isn't supported ([ADR 0006](adr/0006-sql-editions-and-licensing.md)).

**Why a nested Hyper-V guest for the "on-premises" server?**
The Arc agent isn't supported on Azure VMs except for evaluation. A nested guest is a separate machine that can be Arc-enabled, and it worked live. The demo discloses it as a simulated on-premises server, never a real one.

**Is there a manual step on T2?**
Not in the default `JumpstartImage` mode: the T2 host downloads [Arc Jumpstart](https://github.com/Azure/arc_jumpstart_docs/blob/71a945c619f78acb441c6470d76a9b58347169fe/docs/azure_jumpstart_arcbox/ITPro/_index.md)'s prebuilt SQL Server 2022 Standard guest disk, makes it `arcsql01` at first boot while it has no network, checks it, and onboards it to Azure Arc with pay-as-you-go and monitoring, with no person, no product key, and no Bastion. In the opt-in `PaygWizard` mode, a person chooses pay-as-you-go once per guest build, with **Use Azure Login**, because pay-as-you-go SQL Server without a product key is documented only in the setup wizard; since Phase 28 it's a guided stop of about 10 minutes in the same `deploy.ps1` run: everything around the choice is automated, and setup opens pre-filled. `ProductKey` mode (P10) is fully unattended; `Developer` mode is unattended but gives T2 Estate only ([ADR 0006](adr/0006-sql-editions-and-licensing.md)).

**Can an AI assistant run the deployment for me?**
Yes. In the default `JumpstartImage` mode, nothing after your own `az login` needs a person, and `ProductKey` mode is fully unattended too. In the opt-in `PaygWizard` mode, an assistant can do everything apart from about 10 minutes at the guided stop, when you sign in through Bastion, choose pay-as-you-go and Standard, and sign in to Azure in setup; no assistant should do those sign-ins for you. The run prints `HUMAN ACTION REQUIRED: DEPLOY.T2.GUIDEDSTOP ...` for it to relay, and waits for you ([README](../README.md#running-it-with-an-ai-assistant)).

**Why is there no Key Vault?**
The default path needs only Contributor, and Contributor can't grant itself vault data roles. VM passwords are used once and discarded, and break-glass access is a VMAccess reset ([ADR 0009](adr/0009-secrets-handling.md)). An opt-in vault for the one-time host password exists for accounts that can assign roles ([deployment](deployment.md#opt-in-the-password-in-key-vault-instead-of-the-clipboard)).

**Why does `deploy.ps1` create a role assignment when I'm an Owner?**
For the nightly safety stop, the owner-approved exception to the Contributor-only default (2026-11-05): its identity needs a role to deallocate the VMs and stop T4 each night. The role, "DbHub Demo Safety Stop", can only read the demo's resources and deallocate its VMs and stop T4, at the demo resource group only. When you can't assign roles, nothing is assigned: the run still ends **DONE** and prints the one command for an Owner, `./scripts/grant-safety-stop.ps1` ([ADR 0024](adr/0024-nightly-safety-stop.md), [permissions](permissions.md#the-nightly-safety-stop)).

**Can I use Fabric mirroring with this demo?**
Not in v1. Hub doesn't need it. A future optional add-on would need a running capacity and, depending on the source, vCore Azure SQL, a gateway, or SQL Server 2025 with Arc ([ADR 0015](adr/0015-mirroring-deferral.md)).

## Database Hub and the Database Agent

**Does the repo automate the Database Agent?**
No. The in-Hub Database Agent is presenter-driven, and any action it proposes needs your approval. The repo produces the signals, validates the prerequisites, and provides prompts and fallbacks ([ADR 0013](adr/0013-agent-experience.md)).

**Which targets does the Database Agent cover?**
Microsoft doesn't document it yet. Every incident scenario runs on T1, T2, or T3, and the [live coverage record](../fabric/agent/README.md#live-coverage-record) captures what the agent covered in your tenant, with dates.

**How long until a new target shows up in Hub?**
Performance telemetry arrives a few minutes after the activity: live, T3's first sample came 2.8 minutes after it was created, and T2's 7 minutes after monitoring was turned on. Allow up to 15 minutes, and use `validate.ps1` or the walkthrough's readiness gates before a session.

**Can the notebooks start or stop the demo?**
Not directly: Fabric notebooks can't get an Azure Resource Manager token. With the optional P9 token, the live-activity notebook triggers the `demo-control` workflow; without it, it prints the command ([ADR 0014](adr/0014-notebook-role-and-capacity.md)).

## Cost and lifecycle

**What does it cost?**
On 2026-10-21 the `lowest-cost` profile estimated $7.41 for a 5-hour session and $65.12 for a light-use month, against ceilings of $15 and $250 (dated examples from live list prices). The Fabric capacity bills separately, outside that ceiling ([cost management](cost-management.md)).

**Do I need a Fabric capacity?**
Not for Database Hub: each Hub user needs only a Fabric Free license (P4). The notebooks and the Real-Time Dashboard (Phase 18) need a workspace on a running F or Trial capacity (P5), and so will the Power BI report (Phase 19, pending). A paid capacity bills by the hour while it runs, outside the demo's ceiling, so pause it when no workspace needs it ([cost management](cost-management.md#microsoft-fabric-capacity)).

**How do I stop paying between demos?**
`./scripts/stop-demo.ps1` deallocates the VMs, stops T4, and lets T3 auto-pause. If you forget, every evening at `autoShutdownTime` the VMs' auto-shutdown and the nightly safety stop deallocate the VMs and stop T4, then check that T3 paused ([what stops or pauses on its own](../README.md#what-stops-or-pauses-on-its-own)). `-ParkT2` stops only T2, and `-RemoveT3` deletes T3 until the next start. Pause the Fabric capacity when no workspace needs it. `./scripts/destroy.ps1` removes everything ([cleanup](cleanup.md)).

**How do I rebuild the T2 guest before its evaluation OS expires?**
Only the build modes (`PaygWizard`, `ProductKey`, and `Developer`) use the Windows Server evaluation, which lasts 180 days; the default `JumpstartImage` guest's Windows Server 2022 Standard isn't an evaluation. Since 2026-11-05 the host rearms an evaluation guest by itself when 30 or fewer days are left and a rearm is left, and warns you to rebuild T2 when none is. `reset-demo.ps1 -RebuildGuest` isn't supported yet, so rebuild with `destroy.ps1`, then `deploy.ps1`, which in `PaygWizard` mode asks for the setup-wizard step again ([limitations](limitations.md#targets-and-licensing)).

**Can I run it without GitHub?**
Yes. Every operation is a PowerShell script that runs in Cloud Shell or PowerShell 7. GitHub Actions is optional (P7).

**Where do I report a security problem?**
Privately, as [SECURITY.md](../SECURITY.md) describes. Never include secrets, tokens, or subscription or tenant IDs.
