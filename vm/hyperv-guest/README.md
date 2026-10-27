# Hyper-V guest build

Builds and configures the T2 guest `arcsql01` on the host ([ADR 0003](../../docs/adr/0003-t2-host-size-security-type-bootstrap.md), [ADR 0004](../../docs/adr/0004-guest-imds-isolation.md), [ADR 0006](../../docs/adr/0006-sql-editions-and-licensing.md)). `Invoke-HostBootstrap.ps1` dot-sources these files; they run as SYSTEM on Windows PowerShell 5.1.

| File | Purpose |
|---|---|
| `GuestVhdx.ps1` | Builds the Generation 2 VHDX (GPT: EFI, MSR, Windows) with DISM from the evaluation ISO's Datacenter (Desktop Experience) image, adds the unattend file, and makes it bootable with `bcdboot`. A `.built` marker makes the step idempotent. |
| `unattend.template.xml` | Computer name, time zone, locale, OOBE settings, and the Administrator password token. It holds no secret; the host fills the tokens in memory and writes the result only inside the mounted VHDX. |
| `GuestVm.ps1` | Generates the guest password (DPAPI, LocalMachine), creates the VM (static memory, Secure Boot with the Microsoft Windows template, automatic start, `ShutDown` stop action, no checkpoints), and waits for PowerShell Direct. |
| `GuestHardening.ps1` | Inside the guest: static address, DNS through the host, outbound firewall blocks for `169.254.169.254` and `168.63.129.16`, and deletion of the unattend files. On the host: deny port ACLs for the same addresses, which the guest can't remove. |
| `GuestSql.ps1` | Copies files into the guest, mounts the SQL Server ISO, runs unattended setup with the switches from Microsoft Learn (`/PID` only in `ProductKey` mode), detects the instance and edition, and runs the `database/` scripts in the guest with Windows authentication. In `PaygWizard` mode it also installs the WebView2 runtime before the wizard, and afterward removes the sign-in data that setup leaves on the VM, verifies that none remains, and turns IE Enhanced Security Configuration back on. |
| `Copy-GuestCredential.ps1` | Operator helper for the `PaygWizard` step: copies the guest password to the clipboard and never prints it. `-Clear` empties the clipboard. The host bootstrap copies it to `C:\ProgramData\DbHubDemo\`. |
| `GuestWorkload.ps1` | The host's `WorkloadRunner` step (Phase 13, [ADR 0010](../../docs/adr/0010-workload-generator-technology.md#phase-13-delivery-and-hosting-as-built-2026-10-20)): waits (`WaitingForGuestSql`) until the guest's SQL Server runs, then copies the runner, the .NET runtime, and the wrapper into the guest, runs the runner's setup for T2, and registers the guest's `DbHubDemo-Workload` task. |

The media come from the URLs pinned in `config/versions.json` and are verified with SHA-256 before use. The guest's remaining evaluation days are reported in `health.json`; rebuilding the guest starts a new evaluation period.
