# ADR 0005: Arc onboarding authentication

- **Status:** Accepted. Validated live with the operator's token on 2026-10-20 (onboarding, **Connected**) and 2026-10-21 (a rerun skipped onboarding and requested no token). Still open: the GitHub identity's token, a guest rebuild, and the opt-in host identity.
- **Date:** 2026-10-19 (revised the same day for plan §9, Revision 2)
- **Decision source:** Engineering (approved plan §3 row 16, §4.4, §9.1, §9.2)
- **Related:** [ADR 0003](0003-t2-host-size-security-type-bootstrap.md), [ADR 0004](0004-guest-imds-isolation.md), [ADR 0008](0008-identity-rbac-abac.md), [ADR 0009](0009-secrets-handling.md), [security model](../security-model.md)

## Context

- `azcmagent connect --access-token` is documented: the token can come from `Get-AzAccessToken` or any other Microsoft Entra client. Using a token issued to the host's managed identity isn't explicitly documented.
- The deploying identity is assumed to hold Contributor on the subscription (plan §9.1). Contributor can write `Microsoft.HybridCompute/machines` and can delete stale Arc resources, but can't create role assignments, so it can't grant a dedicated onboarding identity the **Azure Connected Machine Onboarding** role.
- `azcmagent connect` fails with **AZCM0044** when a machine resource with the same name already exists. No cascade from `machines` to `sqlServerInstances` is documented.
- The token has to cross two boundaries: from the orchestrator to the host (Run Command), and from the host into the guest (PowerShell Direct).
- `azcmagent connect` takes the token on its command line.

## Decision drivers

1. Works with Contributor alone.
2. No stored secret anywhere.
3. Re-runs and guest rebuilds never create duplicate Arc resources.
4. The narrowest exposure window for the token.

## Considered options

1. **The caller's short-lived token** (the user in `deploy.ps1`, the GitHub identity in `deploy.yml`).
2. A dedicated user-assigned identity with only the Onboarding role, attached to the host, with the host requesting the token from IMDS. Needs a role assignment.
3. A service principal with a client secret. Rejected: a stored secret, and an app registration.

## Decision

Option 1 by default; option 2 as an opt-in enhancement when `assignRoles=true`.

### Default: caller's token

1. The orchestrator gets a short-lived Azure Resource Manager token for the caller (`az account get-access-token`) at the moment it's needed. It's never written to disk, logs, or outputs, and it's masked in Actions.
2. It creates a managed Run Command on the host with the token in `protectedParameters`. The platform delivers protected parameters through the extension's encrypted protected settings, and they're never returned by reads.
3. The host script passes the token into the guest over PowerShell Direct as an argument (not as script text), and runs `azcmagent connect --access-token <token> --resource-group <rg> --location <region> --resource-name arcsql01 --tags deploymentId=...,solution=...`.
4. The orchestrator deletes the Run Command resource as soon as it finishes, whatever the result.

### When onboarding runs

- **`ProductKey` and `Developer` install modes:** after the SQL Server instance is detected (plan §9.2).
- **`PaygWizard` mode (default):** before the manual setup-wizard step (ADR 0003, ADR 0006). This refines plan §9.2 for this one mode.
  - **Validated live (2026-10-21):** with the machine already Connected, the wizard's Azure Extension page locks the subscription, resource group, and region to the existing Arc connection. It still needs an Azure sign-in, because the extension can't be unticked with pay-as-you-go: Next without a sign-in fails with "requires all input values for AZURESERVICEPRINCIPAL".
  - The operator selects **Use Azure Login** and signs in with their own account; the demo never hands out a service principal secret.
  - The sign-in window is an Internet Explorer-based control (live finding, 2026-10-30): the host turns IE Enhanced Security Configuration off for administrators in the guest before setup opens and back on after, and the `GuestWebView2` host step still installs the WebView2 runtime beforehand ([ADR 0009](0009-secrets-handling.md#setups-azure-sign-in-ie-enhanced-security-configuration-live-finding-2026-10-30)).

### Idempotency and duplicates

- **Already connected:** if `azcmagent show` in the guest reports **Connected** with the expected resource ID, onboarding is skipped.
- **Stale resource:** if the Azure resource exists but the guest isn't connected to it (for example, after a guest rebuild), the orchestrator deletes the stale `sqlServerInstances` resources and then `machines/arcsql01`, using the caller's Contributor rights, before it onboards. This prevents **AZCM0044** and duplicates.
- **After onboarding:** the orchestrator verifies the Arc SQL instance (Standard edition, license type, monitoring enabled) when the SQL Server extension has reported it (ADR 0006, plan §9.2).

### Opt-in enhancement: least-privilege host identity

- With `assignRoles=true` (the caller needs `Microsoft.Authorization/roleAssignments/write`), the template creates `id-<prefix>-arc-onboard`, a user-assigned identity with only the Azure Connected Machine Onboarding role on the demo resource group, attached to the host.
- The host requests that identity's token from IMDS (selecting it by client ID) and passes it into the guest the same way. The guest never reaches IMDS itself (ADR 0004).
- This path is undocumented. It becomes the recommended path only after Phase 7 validates it.

## Consequences

- **Positive:** fully automated onboarding with only Contributor; no stored secret; no duplicate machines.
- **Negative:** the default token carries the caller's full rights, which is Contributor on the subscription, for its lifetime of about an hour, inside the guest's memory. The token also appears on the `azcmagent` process command line inside the guest while it runs.
- **Mitigations:** short lifetime; memory only; the guest is a single-purpose machine built by this repo; IMDS isolation; process-creation command-line auditing is off by default and the docs tell operators not to turn it on in the guest; the least-privilege enhancement for tenants that allow role assignments. Recorded in the [security model](../security-model.md).

## Validation

Phase 7 (live, pending go-ahead):

- Onboarding with a user token and with the GitHub identity's token both reach **Connected**.
- A second run skips onboarding.
- A guest rebuild re-onboards with no duplicate `machines` or `sqlServerInstances`.
- The Run Command resource is gone afterward.
- A log scan across script output, Run Command instance views, and Actions logs finds no token.
- With `assignRoles=true`, the host-identity path is tried and its result recorded here.

## Phase 7 implementation notes (2026-10-20)

Implemented and statically tested; every item still needs the live validation above.

- **Entry point:** `scripts/configure-arc.ps1` runs `Invoke-DemoArcConfiguration`. It runs the subscription guard first and stops if it fails. It reads the host's health with a read-only Run Command (`vm/health/Get-DemoHealth.ps1 -View Summary`) and onboards only while the host reports `WaitingForArcOnboarding` (or with `-Force`); otherwise it reports the host's state. `-WaitForHostMinutes` reads the health again every 5 minutes.
- **Probe:** `vm/bootstrap/Invoke-DemoArcOnboard.ps1 -Action Probe` runs on the host and reaches the guest over PowerShell Direct. It reports reachability, IMDS and wire-server reachability (onboarding fails closed if either answers), DNS, and `azcmagent show -j`.
- **Decision table** (`Get-DemoArcOnboardingDecision`):
  - **AlreadyConnected:** the marker is written again and no token is requested.
  - **CleanupStaleThenOnboard:** the machine's `sqlServerInstances` go first, then the machine. Each delete is waited on.
  - **DisconnectLocalThenOnboard:** the agent is configured for a machine that was deleted in Azure, so `azcmagent disconnect --force-local-only` resets it first.
  - **AgentNotConnected**, **ConnectedElsewhere**, **ConnectedUnverified:** nothing is deleted, and the result says why.
  - **Onboard:** the default when nothing is connected.
- **Token:** `az account get-access-token --resource https://management.azure.com/ --query accessToken --output tsv` runs through `Invoke-DemoAz` and the result goes to `Register-DemoSecret` at once.
  - It's passed only in the `protectedParameters` of the Run Command `DbHubDemo-ArcOnboard`.
  - The request body is written to a private temporary directory (current-user ACL on Windows, mode 700 elsewhere) and passed as `--body @<file>`. The file is deleted right after the PUT.
  - `Invoke-DemoVmRunCommand` deletes the Run Command in `finally`.
- **Agent package:** the documented download link `https://aka.ms/AzureConnectedMachineAgent` always serves the latest MSI, and Microsoft publishes no hash for it. So the host checks for a valid Authenticode signature whose signer subject contains `O=Microsoft Corporation`, or for the pinned SHA-256 when `arc.agent.sha256` in `config/versions.json` is set. A package that fails is deleted (fail closed).
  - The host caches the package for up to 7 days.
  - The package is copied into the guest, where its SHA-256 is checked again, and installed with `msiexec /i ... /qn /l*v`.
- **Connect:** the token is the first argument of the remote script block, never script text. The tags are the resource group's demo tags; `autoShutdown` is left out because its value has spaces. The flags are `--cloud AzureCloud` and `--correlation-id <guid>`.
- **Marker:** the Phase 6 contract, plus `guestVmId` (the guest's Hyper-V VM ID), `agentVersion`, `tokenSource`, `correlationId`, and `evaluationOnly`.
  - The host's `Test-DemoArcOnboarded -GuestVmId` now ignores a marker that was written for an earlier build of the guest. A rebuilt guest therefore waits in `WaitingForArcOnboarding` again, and `configure-arc.ps1` deletes the stale machine before it onboards, so there are no duplicates.
- **Opt-in host identity:** the template parameter `assignArcOnboardingRole` (`deploy.ps1` sets it from `assignRoles`, nested mode only) creates `id-<prefix>-<env>-arc-onboard`, with **Azure Connected Machine Onboarding** on the resource group, and attaches it to `archost01`.
  - The name follows the Phase 7 brief. The text above said `id-<prefix>-arc-onboard`.
  - `configure-arc.ps1 -UseHostIdentity` sends only the identity's client ID. The host requests the token from IMDS (`api-version=2018-02-01`, `client_id=`).
  - Deleting a stale machine still uses the caller's rights, because the Onboarding role can't delete.
- **New consequence:** managed Run Command passes protected parameters to a Windows script as `-Name value` arguments. While the onboarding Run Command runs, the token is therefore on the host's `powershell.exe` command line, where the host's local administrators and process-creation auditing on the host can see it.
  - The mitigations are unchanged: a short lifetime, an administrators-only host, and auditing off.
  - `-UseHostIdentity` avoids it.
  - Recorded in the [security model](../security-model.md).
- **TODO(verify):**
  - The `azcmagent show -j` keys other than `status` and `lastHeartbeat` (Learn documents only those two). The code falls back to comparing `vmId`, and the probe returns the key names as evidence.
  - Whether `azcmagent connect --access-token` accepts a token issued to the host's user-assigned identity.

## Amendment: the host identity whenever it's attached (Phase 26d, 2026-10-27)

- **Owner decision (2026-10-27):** with `assignRoles: true`, `deploy.ps1` creates `id-<prefix>-<env>-arc-onboard` with **Azure Connected Machine Onboarding** on `rg-<prefix>-<env>` and attaches it to `archost01`, and every onboarding uses it whenever it's attached: `configure-arc.ps1`, the golden restore's reconnect, and `test-t2-golden.ps1 -Onboard` (its test group gets its own). `-UseHostIdentity` now means "require it"; `-UseCallerToken` skips it. Contributor-only callers keep the caller's token (option 1), documented with its exposure in [ADR 0009](0009-secrets-handling.md#phase-26d-amendment-no-operator-token-left-anywhere-2026-10-27).
- **In the guest,** `azcmagent connect` takes the token from a protected config file (`--config`), not its command line, and a sweep removes what's left of the token on the host and in the guest right after onboarding (ADR 0009).
- **Propagation:** a connect that Azure refuses for authorization with the host identity is retried after 30, 60, 120, 120, and 120 seconds.
- **Still to prove live:** whether `azcmagent connect` accepts the managed identity's token (the TODO above), with the golden recapture's `test-t2-golden.ps1 -Onboard`. The owner updates the master configuration only after that.

## Sources (checked 2026-10-19)

Rechecked on 2026-10-20 for Phase 7: `azcmagent connect` and `show`, the Windows install steps, managed Run Command, the Machines REST API (2026-07-15), and Delete SQL Server from Azure Arc.

- `azcmagent connect`: <https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-connect>
- `azcmagent show`: <https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-show>
- Connect hybrid machines from the portal (Windows install steps and the download link): <https://learn.microsoft.com/azure/azure-arc/servers/onboard-portal>
- Machines REST API: <https://learn.microsoft.com/rest/api/hybridcompute/machines>
- Managed identity token from IMDS: <https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token>
- Troubleshoot onboarding (AZCM0044): <https://learn.microsoft.com/azure/azure-arc/servers/troubleshoot-agent-onboard>
- Managed Run Command (protected parameters): <https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed>
- Delete SQL Server from Azure Arc: <https://learn.microsoft.com/sql/sql-server/azure-arc/delete-from-azure-arc>
- Azure built-in roles (Azure Connected Machine Onboarding): <https://learn.microsoft.com/azure/role-based-access-control/built-in-roles>
- PowerShell Direct: <https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct>
