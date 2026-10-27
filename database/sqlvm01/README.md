# T1 database configuration

SQL Server on Azure VM specifics for `sqlvm01`, run by `vm/bootstrap/Invoke-SqlVmBootstrap.ps1` with Windows authentication.

| File | Run in | Contents |
|---|---|---|
| `000-create-database.sql` | `master` | Creates `ContosoCare` with its data and log files on the data disk (LUN 0), or, without one (`lowest-cost`), in SQL Server's default data and log folders on the OS disk. The bootstrap replaces `{{DATA_DIRECTORY}}` and `{{LOG_DIRECTORY}}` (`F:\SQLData` and `F:\SQLLog`, or the instance defaults) first. Data is capped at 16 GB and the log at 8 GB, growing in 256 MB steps. |
| `030-configure.sql` | `ContosoCare` | Query Store on (read-write, 1 GB, 15-minute intervals), simple recovery, the same file caps, and the `contosocare_runner` role with data access to the `care` and `demo` schemas. |

The runner role has no server-level permissions. Phase 11 creates the runner service's Windows login and adds its database user to the role.
