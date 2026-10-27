# Connection surge (capacity maxed)

A T4 incident (Azure Database for PostgreSQL flexible server, [ADR 0019](../../docs/adr/0019-t4-postgresql-flexible-server.md)): a burst of application connections fills the server's connection slots.

- **Definition:** [`scenario.json`](scenario.json) (5 minutes by default, 15 at most; 5 connections a second while a wave ramps up).
- **Sessions:** all tagged `ContosoCare.Demo/connection-surge/<run>`. Each wave reads `max_connections` and the reserved slots, opens connections until only `headroom` slots stay free, holds them for `holdSeconds` (each pings `demo.usp_scenario_connection_surge` now and then), tries `overshoot` more that the server refuses (SQLSTATE 53300), then closes them all and pauses `pauseSeconds`. `maxConnections` caps a wave whatever the server allows.
- **Bounds:** the reserved slots and `headroom` are never used, so `reset` and an administrator can still connect; every connection carries the run's statement, lock, and idle-in-transaction timeouts; the watchdog ends leftover sessions with `pg_terminate_backend`.
- **Size matters:** the default `max_connections` is 50 on `Standard_B1ms`, 429 on `Standard_B2s`, and 859 on `Standard_D2ds_v5` ([limits](https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-limits)). `maxConnections` (60 by default, 400 at most) stops a wave first on the two larger sizes, so there the surge shows as many idle connections and no refused ones (live on `Standard_D2ds_v5`, 2026-10-26).
- **Expected signals:** Database Hub's PostgreSQL dashboard shows **Connections** at the limit and **Failed connections** above 0; the Azure portal's Metrics show **Sessions By State** and **TCP Connection Backlog** (enhanced metrics).
- **Reset:** nothing is written; `reset` ends any leftover demo session.

```powershell
ContosoCare.Workload run --target T4 --server <fqdn> --scenario connection-surge --duration 5m --param overshoot=3
```
