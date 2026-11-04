# Connection surge (capacity maxed)

A T4 incident (Azure Database for PostgreSQL flexible server, [ADR 0019](../../docs/adr/0019-t4-postgresql-flexible-server.md)): a burst of application connections fills the server's connection slots.

- **Definition:** [`scenario.json`](scenario.json) (5 minutes by default, 15 at most; 5 connections a second while a wave ramps up).
- **Sessions:** all tagged `ContosoCare.Demo/connection-surge/<run>`, all to `contosocare`. Each wave reads `max_connections` and the reserved slots, opens connections until only `headroom` slots stay free, then overshoots: it fills those `headroom` slots, tries `overshoot` more that the server refuses (SQLSTATE 53300, too many connections), and closes the slots it filled. It holds the rest for `holdSeconds` (each pings `demo.usp_scenario_connection_surge` now and then), closes them all, and pauses `pauseSeconds`. `maxConnections` caps a wave whatever the server allows.
- **Bounds on the overshoot (2026-11-03):**
  - The headroom is filled for **5 seconds at most**, one connection at a time; an attempt still open at that limit is cut off, and every connection the overshoot opened is closed right after.
  - At most **5 refused attempts in any minute and 30 in a run**, whatever `overshoot` is set to (fixed in the runner, `SurgeBounds`). A refusal during a wave's ramp counts too, so a wave starts only while one more is allowed.
  - Refusals come only from the connection limit: every attempt signs in like any other runner session, with T1's managed identity. A sign-in failure ends the surge, so it never repeats a failed sign-in, which Microsoft Defender could read as a brute-force attempt.
  - Everything ends within the run's own duration (15 minutes at most).
- **Other bounds:** the reserved slots are never used, and the headroom only during the overshoot, so `reset` and an administrator can still connect. The other T4 lanes, the baseline and any other slot, treat a 53300 refusal they meet during those seconds as transient: their connection opens retry for up to 90 seconds, so they record no failure. Every connection carries the run's statement, lock, and idle-in-transaction timeouts, and the watchdog ends leftover sessions with `pg_terminate_backend`.
- **Every size:** the template sets `max_connections` to 50 on every T4 size (ADR 0019, 2026-11-03): `Standard_B1ms`'s own default, below `maxConnections` (60 by default), so `Standard_B2s` and `Standard_D2ds_v5` (defaults 429 and 859) reach the limit and refuse the overshoot too. 15 slots stay reserved, which leaves 35 for the runner ([server parameters](https://learn.microsoft.com/azure/postgresql/server-parameters/param-connections-authentication-connection-settings), [limits](https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-limits)). `max_connections` is a static parameter: a new value takes effect at a restart, which `deploy.ps1` does before T1 sets T4 up (`DEPLOY.T4.RESTART`); `validate.ps1 -Area T4` shows it (`T4.MAXCONNECTIONS`). On a server whose limit is above what a wave can hold, the event log says so and nothing is past the limit.
- **Proven live:** not yet. The overshoot and the refused attempts on each size are unproven until the owner's live check ([limitations](../../docs/limitations.md)).
- **Expected signals:** Database Hub's PostgreSQL dashboard shows **Connections** at the limit and **Failed connections** above 0; the Azure portal's Metrics show **Sessions By State** and **TCP Connection Backlog** (enhanced metrics).
- **Reset:** nothing is written; `reset` ends any leftover demo session.

```powershell
ContosoCare.Workload run --target T4 --server <fqdn> --scenario connection-surge --duration 5m --param overshoot=3
```
