# T2 database configuration

Arc-enabled SQL Server specifics for `arcsql01`, run inside the guest over PowerShell Direct by `vm/bootstrap/Invoke-HostBootstrap.ps1` with Windows authentication.

| File | Run in | Contents |
|---|---|---|
| `000-create-database.sql` | `master` | Creates `ContosoCare` in the instance's default folders. |
| `030-configure.sql` | `ContosoCare` | Query Store on (read-write, 512 MB, 15-minute intervals), simple recovery, file caps that respect the 64 GB guest VHDX (data 8 GB and log 4 GB, growing in 256 MB steps), and the `contosocare_runner` role with data access to the `care` and `demo` schemas. |

The runner role has no server-level permissions. Phase 11 creates the runner service's Windows login and adds its database user to the role.
