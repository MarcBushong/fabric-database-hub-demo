# Health reporting

`C:\ProgramData\DbHubDemo\health.json` on T1 and the T2 host summarizes the bootstrap after every run of the state machine. The validator reads it through Run Command ([ADR 0012](../../docs/adr/0012-validation-model.md)).

| File | Purpose |
|---|---|
| `health.schema.json` | JSON Schema (2020-12) for `health.json`. A Pester test validates the file the module writes against it. |
| `Get-DemoHealth.ps1` | Prints `health.json` in compact form, with steps reduced to a name-to-status map, so it fits in Run Command's 4 KB output. `-View Summary` (Phase 7) prints only what the orchestrator gates on: role, state, status, the first 500 characters of the message, the current step, the generation, the install mode, Arc onboarding, and the guest's state and SQL Server edition; since Phase 28 also the `PaygWizard` guided stop's state from `details.guidedSetup` (whether the guest's automatic sign-in is armed, `deploy.ps1`'s request, setup's sign-in preparation `guidedSignIn`, which must be `ready`, or `fallback` once the host stopped waiting for it, before anyone is asked, and the last cleanup). |

- **`state`** is the machine state: `InProgress`, `RebootPending`, `WaitingForArcOnboarding`, `WaitingForProductKey`, `WaitingForGuestSql` (the host's runner step waits for the guest's SQL Server, Phase 13), `WaitingForInput` (for example, the runner's chunks haven't all arrived), `ManualActionRequired`, `Ready`, or `Failed`.
- **`status`** maps it to the ADR 0012 model: `Ready` is **Pass** (**Warning** when warnings exist), `Failed` is **Fail**, `ManualActionRequired` is **Manual action required**, and in-flight states are **Warning**.
- **`instructions`** carries the exact operator steps when manual action is required, such as the `PaygWizard` setup-wizard steps.
- **`warnings`** lists non-blocking issues, such as media trusted on first use or the T1 sysadmin recovery.
- **`details`** holds role-specific facts. On the host: the install mode; size, zone, and Secure Boot from IMDS; Arc onboarding; and the guest's state, uptime, computer name, evaluation days left, and SQL Server edition and version, read over PowerShell Direct, plus the guest's workload runner (`details.guest.workload`). On T1: the SQL Server edition and version, whether `ContosoCare` exists, the data folder, and the workload runner (`details.workload`: the runner's SHA-256, the .NET version, the profile, setup results, whether T3 is enabled, and the task's state). A failure while collecting details is reported in `healthDetailError` and doesn't stop the run.

The file is written with the module's redaction and never holds secrets.
