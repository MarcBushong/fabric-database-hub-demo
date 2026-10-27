# ADR 0015: Fabric mirroring deferred from v1

- **Status:** Accepted
- **Date:** 2026-10-19
- **Decision source:** User-directed (Q2c: mirroring excluded from v1, documented only as a future add-on)
- **Related:** [ADR 0006](0006-sql-editions-and-licensing.md), [ADR 0016](0016-cost-profiles.md), [faq](../faq.md), [limitations](../limitations.md)

## Context

- Database Hub doesn't need mirroring. Discovery comes from Azure Resource Graph, and monitoring comes from the SQL telemetry pipeline.
- **Requirements, if mirroring were added later:**
  - **Azure SQL Database:** vCore purchasing model or at least 100 DTUs; a server managed identity as the primary identity; and a running Fabric capacity.
  - **SQL Server 2025:** mirroring requires Azure Arc.
  - **Earlier SQL Server versions:** depend on a data gateway, which adds compute and network design.
- The brief says not to assume mirroring is required and to add it only if it materially improves the demo, as an independently deployable and removable piece.

## Decision

- v1 neither deploys nor configures mirroring.
- The docs describe it as a future, optional add-on, with its capacity, gateway, network, SQL version, and permission needs ([faq](../faq.md), [limitations](../limitations.md)).
- **Sketch of a future add-on:** a separate script, `scripts/optional/enable-mirroring.ps1`, and a separate notebook section. They would be added and removed without touching the core deployment, and kept out of the cost ceilings unless enabled.
- The deployment notebook keeps a short "Optional mirroring (deferred)" section that states this decision.

## Consequences

- **Positive:** lower cost, fewer prerequisites, and a demo focused on Hub.
- **Negative:** no OneLake analytics over the demo data in v1.

## Validation

Not applicable to v1. The validator reports mirroring as **Not selected**.

## Sources (checked 2026-10-19)

- Mirroring overview: <https://learn.microsoft.com/fabric/mirroring/overview>
- Mirroring Azure SQL Database: <https://learn.microsoft.com/fabric/mirroring/azure-sql-database>
- Mirroring SQL Server: <https://learn.microsoft.com/fabric/mirroring/sql-server>
