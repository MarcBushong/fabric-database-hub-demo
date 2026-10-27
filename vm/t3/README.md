# T3 runner

`Invoke-DemoT3Sql.ps1` runs T-SQL on T3 (Azure SQL Database) from T1 (`sqlvm01`) with T1's system-assigned managed identity. It runs as SYSTEM on **Windows PowerShell 5.1** and is ASCII-only; `tests/PSScriptAnalyzerSettings.Vm.psd1` checks the syntax against 5.1.

It isn't run directly. `Invoke-DemoT3SqlFromT1` in the `DbHubDemo` module fills in its placeholders (server FQDN, database, waits, and the T-SQL batches as gzip and Base64 with their SHA-256), writes the result to a temporary file, and sends it with `az vm run-command invoke --command-id RunPowerShellScript --scripts @<file>`, so no T-SQL, quote, or percent sign travels on a command line ([ADR 0007](../../docs/adr/0007-networking-modes-and-egress.md), [ADR 0008](../../docs/adr/0008-identity-rbac-abac.md)).

## What it does

1. Checks the embedded batches against their SHA-256, then decodes them.
2. Gets an access token for `https://database.windows.net/` from the instance metadata service ([documented for a VM's managed identity](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/tutorial-windows-managed-identities-vm-access)). The token stays in memory and is never printed.
3. Connects to the server's FQDN with `System.Data.SqlClient` and the token, encrypted, with the server certificate validated. Inside the VNet, the private DNS zone resolves the FQDN to the private endpoint in private mode.
4. Retries a failed login (error 18456) every 15 seconds for up to the login wait (600 seconds by default), because T1's membership in the P6 group can take time to apply. Retries Azure SQL's [documented transient errors](https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-errors-issues), such as 40613 while a paused serverless database resumes, every 10 seconds for up to the resume wait (300 seconds by default).
5. Runs the batches in order on one connection, reconnecting up to 3 times on a transient error, keeps the last result set (at most 20 rows and 24 columns), and stops at the first error.
6. Prints exactly one line, `DBHUBDEMO-T3SQL` followed by compact JSON, at most about 3,500 characters, because action Run Command returns only the last 4,096 bytes of output ([Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command)).

## Result

| Field | Meaning |
|---|---|
| `status` | `Pass`, `Warning` (the login never succeeded within the wait), or `Fail` |
| `batches`, `completed` | Batches sent and batches that ran |
| `attempts`, `loginFailures`, `transientFailures` | Connection attempts, and how many failed for each reason |
| `loginWaitSeconds` | Time from the first attempt to a successful login (or until it gave up): the measured lag of the group membership |
| `elapsedSeconds` | Total time on T1 |
| `errorNumber`, `error` | The SQL error number and a short, printable-ASCII message |
| `rows`, `rowsTruncated` | The last result set |

## Managed identity tokens are cached

The managed identity infrastructure caches tokens for each resource for up to about 24 hours ([managed identity best practices](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations)). So nothing on T1 should ask for an Azure SQL token before T1 joins the P6 group: `Add-DemoT1ToT3AdminGroup` runs first and waits until Microsoft Graph reports the membership. If the login still fails, the step reports a **Warning** with the measured wait; run it again later, or use the interactive fallback ([ADR 0007](../../docs/adr/0007-networking-modes-and-egress.md)).
