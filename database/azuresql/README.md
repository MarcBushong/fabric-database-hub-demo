# T3 database configuration

Azure SQL Database specifics for T3: logical server `azuresql01-<deploymentId>`, database `ContosoCare`. `Invoke-DemoT3SqlFromT1` (in the `DbHubDemo` module) runs them on T1, with T1's managed identity as a member of the P6 administrator group ([ADR 0008](../../docs/adr/0008-identity-rbac-abac.md)), through action Run Command. T1 reaches T3 through the private endpoint or the VNet rule ([ADR 0007](../../docs/adr/0007-networking-modes-and-egress.md)).

| File | Run in | Contents |
|---|---|---|
| `030-configure.sql` | `ContosoCare` | Query Store with T1's settings (read-write, 1 GB, 15-minute intervals) and the `contosocare_runner` role with data access to the `care` and `demo` schemas. No file caps or recovery model: Azure SQL Database manages them, and the template caps the database at 32 GB. |
| `040-performance-monitoring.sql` | `ContosoCare` | Microsoft's documented script for Database Hub performance monitoring: adds the database-level extended property `MS_EnablePerformanceMonitoringPreview = 'true'`, or updates it. Never in `master`. |
| `900-status.sql` | `ContosoCare` | Read-only status in one row: the extended property, Query Store state, the seed procedure and state, the runner role, and whether the connection is `dbo`. |

## Script sets

`Invoke-DemoT3SqlFromT1 -Name <set>` splits every file into batches on `GO` lines, as `sqlcmd` does.

| Set | Runs |
|---|---|
| `Setup` | Every `database/common/0??-*.sql` file in name order (today `010-schema.sql` and `020-seed.sql`), every `database/azuresql/0??-*.sql` file in name order, `EXEC demo.usp_seed_contosocare @scale = <profile seedScale>`, then `900-status.sql`. Every step is safe to re-run; a completed seed with the same scale is a no-op. |
| `Status` | `900-status.sql`. The warm-up and `Test-DemoT3` use it. |
| `PerformanceMonitoring` | `040-performance-monitoring.sql`, then `900-status.sql`. |

- **New common scripts join automatically.** Scripts that Phase 11 adds to `database/common/` (scenario control and procedures) run on T3 in the same order as on T1 and T2, so they must stay compatible with Azure SQL Database: no `USE`, filegroups, instance-level settings, or Windows logins.
- **No `000-create-database.sql`:** the template creates `ContosoCare`, and Azure SQL Database can't switch databases with `USE`.
- **Compatibility of the common scripts:** `010-schema.sql` and `020-seed.sql` run unchanged on Azure SQL Database. The common `900-status.sql` works too, but T3 uses its own, which adds the extended property.

## Users

No contained users are created by default. T1's identity and the DBAs reach T3 through the P6 group, the server's Entra administrator, so they connect as `dbo`; the over-privilege of T1 is accepted risk R26 ([ADR 0008](../../docs/adr/0008-identity-rbac-abac.md)). Presenter access is Phase 9.

The `contosocare_runner` role is ready for the hardened option: a contained user for T1, created without Microsoft Graph lookups with `CREATE USER [sqlvm01] WITH SID = <T1 client ID>, TYPE = E` ([CREATE USER, example K](https://learn.microsoft.com/sql/t-sql/statements/create-user-transact-sql)), added to the role, with T1 then taken out of the P6 group.

## Output limit

Action Run Command returns only the last 4,096 bytes of output ([Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command)). The T1 runner prints one JSON line with the last result set, at most 20 rows, so status queries return a single row.
