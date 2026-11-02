# Architecture decision records

This folder holds the architecture decision records (ADRs) for the Fabric Database Hub hybrid SQL demo. Each ADR records one decision, the options considered, and the evidence behind it.

The ADRs follow the approved implementation plan, including **Revision 2** (plan §9: Contributor-minimum permissions, one-click deployment, the live-activity notebook, and cost and GitHub optimizations). Where Revision 2 conflicts with earlier plan sections, Revision 2 wins, and the ADRs reflect it.

## Conventions

- **Numbering:** four digits, never reused. A changed decision gets a new ADR that supersedes the old one.
- **Status:** `Proposed` → `Accepted` → (`Superseded by ADR-nnnn` | `Deprecated`). An ADR is accepted when the pull request that adds it merges.
- **Decision source:**
  - **User-directed:** decided by the repo owner (plan §5 questions Q0–Q8, and the Revision 2 request in plan §9). These aren't reopened without the owner.
  - **Engineering:** decided by the implementer within the approved plan. A later ADR can supersede it.
- **Validation pending:** some decisions rest on behavior the docs don't cover, such as Arc on a nested Hyper-V guest. Those ADRs name the live check that proves or disproves them and the phase that runs it. Until that check passes, the capability is reported as preview or **Manual action required**, never as **Pass**.
- **Sources:** every factual claim cites official documentation with the date it was checked. Previews change, so re-check a cited page before you implement against it.

## Index

| ADR | Title | Source | Status |
|---|---|---|---|
| [0001](0001-iac-bicep-avm-compiled-arm.md) | Infrastructure as code with Bicep, Azure Verified Modules, and a compiled `azuredeploy.json` | Engineering | Accepted |
| [0002](0002-resource-group-topology.md) | One demo resource group plus an optional control resource group | Engineering (Q4c, §9.1) | Accepted |
| [0003](0003-t2-host-size-security-type-bootstrap.md) | T2 host size, security type, and bootstrap state machine | Engineering | Accepted; validated live, except the Trusted Launch host test; Phase 28 amendment (chunk hygiene that doesn't stall) unit-tested |
| [0004](0004-guest-imds-isolation.md) | Isolating the nested guest from IMDS and the wire server | User-directed (Q5b) | Accepted; validated live, except the port-ACL-only test |
| [0005](0005-arc-onboarding-authentication.md) | Arc onboarding authentication | Engineering (§9.1) | Accepted; validated live with the operator's token |
| [0006](0006-sql-editions-and-licensing.md) | SQL Server editions, guest OS, and licensing | User-directed (Q1, Q2, §9.2; the guided stop, 2026-10-29) | Accepted; Phase 28 amendment (one command, one guided stop) not yet run live |
| [0007](0007-networking-modes-and-egress.md) | Networking modes and egress strictness | User-directed (Q4b, Q5) | Accepted |
| [0008](0008-identity-rbac-abac.md) | Identity and permissions: the Contributor-only model | User-directed (§9.1, Q4d) | Accepted |
| [0009](0009-secrets-handling.md) | Secrets handling | Engineering (§9.1); the guest's one automatic sign-in, owner-approved 2026-10-29 | Accepted; Phase 28 amendment not yet run live |
| [0010](0010-workload-generator-technology.md) | Workload generator technology and delivery | Engineering | Accepted |
| [0011](0011-control-surface-priority.md) | One orchestrator and the demo control surface | Engineering (§9.2) | Accepted |
| [0012](0012-validation-model.md) | Validation model and status taxonomy | Engineering | Accepted |
| [0013](0013-agent-experience.md) | Agent experience: in-Hub Database Agent first, skills as fallback | User-directed (Q3) | Accepted, validation pending (the owner's rehearsal) |
| [0014](0014-notebook-role-and-capacity.md) | Notebooks, their roles, and the Fabric capacity dependency | User-directed (Q0, Q7, §9.3) | Accepted |
| [0015](0015-mirroring-deferral.md) | Fabric mirroring deferred from v1 | User-directed (Q2c) | Accepted |
| [0016](0016-cost-profiles.md) | Cost profiles, ceilings, and guardrails | User-directed (Q6, §9.4) | Accepted |
| [0017](0017-outbound-access.md) | Outbound internet access for the VM subnets | Engineering (Phase 5) | Accepted |
| [0018](0018-fast-redeploy-parallel-tracks-golden-snapshot.md) | Fast redeploy: parallel tracks and a T2 golden snapshot | User-directed (2026-10-21, 2026-10-29), with the coordinator's guardrails | Accepted; Phase 28 amendment (one command, the clock with T4) not yet run live |
| [0019](0019-t4-postgresql-flexible-server.md) | T4, an Azure Database for PostgreSQL flexible server | User-directed (2026-10-23), with the coordinator's decisions | Accepted; validated live on 2026-10-26; Phase 28's Burstable fallback not yet run live |
| [0020](0020-on-demand-activity-control.md) | On-demand activity control from a Fabric notebook | User-directed (2026-10-23, 2026-10-26) | Accepted, validation pending (the live setup and test) |
| [0021](0021-fabric-resources-by-name.md) | Fabric resources by name, resolved at run time, and created when missing | User-directed (2026-10-26), with the coordinator's decisions | Accepted; the create path's live check runs after the merge |
| [0022](0022-public-repository-and-github-actions-hardening.md) | A public repository, and GitHub Actions hardened for it | User-directed (2026-10-26, 2026-10-27), with the coordinator's decisions | Accepted; the GitHub settings and a live Actions run pending until the public repository exists |
| [0023](0023-first-run-automation.md) | First-run automation: `init.ps1`, the P6 group, the Rayfin sign-in, and opt-in capacity and history steps | User-directed (2026-10-26, 2026-10-27), with the coordinator's decisions | Accepted; live check of `init.ps1` read-only, the rest pending; Phase 28: `deploy.ps1` runs the first run |

## Template

Copy this when you add an ADR.

```markdown
# ADR nnnn: Title

- **Status:** Proposed
- **Date:** YYYY-MM-DD
- **Decision source:** User-directed (Qn) | Engineering
- **Related:** ADR-nnnn, docs/...

## Context

The forces at play, with citations.

## Decision drivers

The criteria used to compare the options.

## Considered options

1. Option A
2. Option B

## Decision

The option chosen, stated so someone can implement it.

## Consequences

What gets easier, what gets harder, and which risks are accepted.

## Validation

How we'll know the decision works, and which phase checks it.

## Sources

Official documentation only, with the date you checked it.
```
