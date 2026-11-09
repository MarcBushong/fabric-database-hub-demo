# Instructions for AI agents

These are for an agent asked to **set up, deploy, upgrade, or try** this demo for someone. To change the code, read [.github/copilot-instructions.md](.github/copilot-instructions.md) instead.

## Use the scripts, not a setup of your own

1. **Signed in?** Run `az account show`. If it fails, ask the person to run `az login` themselves (`az login --use-device-code` in a codespace). Never sign in for them, and never run `az account set`: the scripts use the subscription in the configuration.
2. **No `config/demo.config.json` yet?** Run `./scripts/init.ps1 -CreateAdminGroup`, or let `./scripts/deploy.ps1` write it on its first run. Neither asks how T2 gets SQL Server: the default, `JumpstartImage`, needs nobody.
3. **Deploy:** run `./scripts/deploy.ps1`. It's the one path for a new environment and for one that exists in the subscription already, an older demo included: it continues an unfinished run, starts stopped VMs, sends changed bootstraps, rebuilds a T2 guest whose SQL Server setup wizard was never finished from Arc Jumpstart's image (about 27 minutes), keeps a finished T2 guest as it is, creates T4 when it's missing, and sets up the nightly safety stop ([update an existing environment](docs/deployment.md#update-an-existing-environment)). An older configuration's `"t2SqlInstallMode": "PaygWizard"`, the default before 2026-11-05, runs as `JumpstartImage`, with no setup wizard; the run says so in one line.
4. **Interrupted, or NOT DONE?** Run `./scripts/deploy.ps1` again, or the exact command its banner prints. It continues where it stopped.

## Don't

- **Don't `git pull`, switch branches, stash, or reset yourself** before or between runs. `deploy.ps1` checks GitHub's `main` first: a clean checkout of `main` updates itself (fast-forward only) and starts again with the new code. When it can't (local changes, another branch, diverged, offline, no Git), it says so in a `DEPLOY.SELFUPDATE` **Warning** with the exact command, and runs the code it has; report that Warning to the person, and leave the command to them, because it touches their files ([updates from GitHub](docs/deployment.md#updates-from-github-2026-11-09)).
- **Don't assemble a partial setup by hand** in place of `deploy.ps1`: no starting VMs, repairing monitoring, onboarding Arc, or creating resources piece by piece with `az` or the portal. `deploy.ps1` does each of them in order and checks them, and a hand-made state can keep it from finishing.
- **Don't finish T2's SQL Server by hand,** and don't ask a person to: no Bastion sign-in to a VM and no setup wizard. `deploy.ps1` makes T2 from the Jumpstart image, and runs a configuration's `PaygWizard` as `JumpstartImage`. Don't change `t2SqlInstallMode` on your own.
- **Don't leave a target out on your own:** not T1, T2, T3, T4 (PostgreSQL), or Fabric. When `deploy.ps1` leaves T4 out, it says why in `DEPLOY.T4.OFF`; report that.
- **Don't read, print, or store a password, key, or token.**

## Report what deploy.ps1 says

- **The ending banner:** **DONE**, or **NOT DONE** with its reason and the exact next command it prints. Without **DONE**, the setup isn't finished; say so.
- **What it changed in an existing environment,** when these lines appear: `DEPLOY.T2.REBUILD`, `DEPLOY.T2.MODE`, `DEPLOY.T4.MISSING`, `DEPLOY.T4.RETRY`, and `DEPLOY.T4.OFF`.
- **Whether it updated itself from GitHub:** the first line, "Updated this copy from GitHub's main: ... to ...", or the `DEPLOY.SELFUPDATE` **Warning** with its command.
- **What it lists under Please confirm:** for example the Database Hub tenant setting, which only a Fabric administrator can read, and Database Hub's own pages, which have no API.

## Steps only a person can do

- `az login`.
- **The Insights app's one-time sign-in** (the Rayfin CLI, in a browser). `deploy.ps1` doesn't start it under an assistant, so ask the person to run `./scripts/configure-fabric-app.ps1 -SignIn` in their own terminal, before or after the deployment.
- **The Insights app's one-time browser confirmation,** listed under **Please confirm**.
- **Nothing for T2 or T4:** no setup wizard, and no step for PostgreSQL. T4 is part of every deployment; when Azure refuses every T4 size, the run ends **NOT DONE** with the fix (a Region access request, or `t4SkuName`), which only the person can act on.
- **When the person isn't an Owner:** an Owner runs `./scripts/grant-safety-stop.ps1` once, which **DONE** prints.

## Cost

- **Before you deploy, say what it costs:** `./scripts/estimate-cost.ps1` estimates it from Azure's list prices, with no sign-in. Preflight checks the same estimate against `monthlyCeilingUsd` and `sessionCeilingUsd` and stops at a hard ceiling.
- **When the person doesn't want new resources,** say what then won't work, rather than skipping parts quietly: for example, without `deploy.ps1` there's no T4, so no PostgreSQL in Database Hub, and no nightly safety stop, so T4 bills again after Azure starts it on its own 7 days after a stop.

More: [README](README.md#running-it-with-an-ai-assistant), [deployment](docs/deployment.md), and [troubleshooting](docs/troubleshooting.md).
