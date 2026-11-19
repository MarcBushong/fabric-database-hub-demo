# ADR 0027: T5, an Azure Cosmos DB for NoSQL account

- **Status:** Accepted. Live validation: [below](#validation).
- **Date:** 2026-11-18
- **Decision source:** User-directed (2026-11-18: review item 2 of the Ignite 2026 announcements, "Azure Cosmos DB as T5", in "Create a new branch and do them all"; 2026-11-18: "Make sure to account for users signing in and demoing this themselves and repeatable. Simple and one click as possible"), with the coordinator's decisions (a private endpoint in both network modes rather than a service endpoint; the free tier when the subscription's one slot is free) and the implementer's engineering detail
- **Related:** [ADR 0008](0008-identity-rbac-abac.md) (Contributor only), [ADR 0010](0010-workload-generator-technology.md) (the runner and bounded workloads), [ADR 0012](0012-validation-model.md) (statuses), [ADR 0016](0016-cost-profiles.md) (cost), [ADR 0018](0018-fast-redeploy-parallel-tracks-golden-snapshot.md) (tracks and DONE), [ADR 0019](0019-t4-postgresql-flexible-server.md) (T4, the pattern T5 follows), [ADR 0026](0026-one-run-all-session.md) (Run all)

## Context

- **Database Hub in Microsoft Fabric is generally available (Ignite, 2026-11-17)**, and it covers Azure Cosmos DB: the account in Overview and Estate, its own Performance view, and its security posture ([monitor Azure Cosmos DB in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor-cosmos-db), checked 2026-11-18). The demo had SQL Server on a VM (T1), Arc-enabled SQL Server (T2), Azure SQL Database (T3), and PostgreSQL (T4), and no Cosmos DB.
- **Database Hub reads Cosmos DB from Azure Monitor platform metrics, with no setup** (the same page): Normalized RU Consumption (Maximum), Total Request Units (Total), Throttled Requests (`TotalRequests` with `StatusCode` 429, Count), Provisioned Throughput (Maximum, at a 5-minute grain or coarser), Avg Latency (`ServerSideLatencyDirect`, Average; direct-mode connections only), and Availability (`ServiceAvailability`, Average, hourly). Its charts use an hourly grain. The Security page evaluates Microsoft Entra-only access (local authentication off), public network access (an Issue when it's on), and customer-managed keys (a Suggestion).
- **Normalized RU Consumption** is the highest share of the provisioned RU/s that one partition key range used in a minute; 100% means requests beyond it are rate-limited with 429 ([normalized RU](https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units), [429s](https://learn.microsoft.com/azure/cosmos-db/nosql/troubleshoot-request-rate-too-large), checked 2026-11-18). That's the DBA moment the review asked for: a hot partition drives it to 100%, the 429s show, and both recover when the load stops.
- **Prices** (Azure Retail Prices API, 2026-11-18, West US 3, list, USD; dated examples, ADR 0016): provisioned throughput `Azure Cosmos DB / RUs / 100 RU/s` $0.008 an hour, so 400 RU/s is $0.032 an hour, $23.36 a month; storage $0.25 a GB-month; the Free Tier meters $0. Defender for Azure Cosmos DB `Standard 100 RU/s` $0.0012 an hour (about $3.50 a month at 400 RU/s). A private endpoint `Standard Private Endpoint` $0.01 an hour ($7.30 a month), its private DNS zone $0.50 a month. **The free tier** covers the first 1000 RU/s and 25 GB of one account per subscription, and Azure sets it only when an account is created ([free tier](https://learn.microsoft.com/azure/cosmos-db/free-tier), checked 2026-11-18).
- **An account can't be stopped or paused**: provisioned throughput bills every hour it exists.
- **Permissions:** the data plane's role-based access control is the account's own `sqlRoleAssignments`, not an Azure role assignment, and `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/write` is within Contributor ([grant data-plane access](https://learn.microsoft.com/azure/cosmos-db/nosql/how-to-grant-data-plane-access), checked 2026-11-18). With local authentication off (`disableLocalAuth`), no key works for data ([connect with role-based access control](https://learn.microsoft.com/azure/cosmos-db/how-to-connect-role-based-access-control)).

## Decision drivers

1. **One click, every time:** after `az login`, `./scripts/deploy.ps1` deploys T5 on a first deployment and adds it to an older demo, with nothing for a person to do, and anyone who deploys the demo can demo T5 themselves.
2. **No secrets** and **Contributor as the minimum** (ADR 0008, ADR 0009).
3. **Secure by default:** no public network access, so Database Hub's Security page shows no Issue for T5.
4. **The DBA moment, repeatable:** normalized RU to 100% with 429s, then recovery, in every Run all, with the data, the RU, and the 429s back at their baseline before the next session.
5. **Lowest cost**, priced at run time, and failures and fallbacks on the status page.

## Considered options

| Area | Option | Outcome |
|---|---|---|
| Capacity | Provisioned throughput, 400 RU/s manual, on the container | **Chosen**: the minimum, a fixed ceiling that a hot partition reaches, and the normalized RU and Provisioned Throughput charts Database Hub draws |
| | Autoscale (1000 RU/s maximum, 100 RU/s floor) | Rejected: a storm scales instead of throttling until it reaches the maximum, and it costs more at the peak |
| | Serverless | Rejected: no provisioned throughput, so Database Hub's normalized RU view has nothing to normalize against |
| Network | A private endpoint in both network modes, public network access off | **Chosen** (the coordinator's decision): the same in both modes, no Issue on the Security page, and no policy that blocks public data services can stop it. $7.80 a month with its DNS zone |
| | A service endpoint on T1's subnet in public mode | Rejected: the account would keep public network access on (an Issue), and two network shapes for one target |
| Authentication | Microsoft Entra only: T1's managed identity with Cosmos DB Built-in Data Contributor, scoped to the account | **Chosen**: no key exists anywhere, and the assignment is a child resource that Contributor creates |
| | Account keys in a Key Vault | Rejected: a secret, and a Key Vault, which the default path doesn't create (ADR 0009) |
| Client | The documented REST API from the existing .NET runner, with an Entra token, over HTTPS 443 (gateway) | **Chosen**: no new package, and only port 443 through the private endpoint. Database Hub's Avg Latency stays empty (it charts direct-mode latency only) |
| | The Azure Cosmos DB .NET SDK in direct mode | Rejected for now: a new dependency and ports 10250 to 10255 through the private endpoint, for one chart |
| Where it's deployed | In the main template, with T3 and T4, and T5's checks as a step of T1's track | **Chosen**: one template deployment, and the runner's checks go through T1, which runs one Run Command at a time |
| | A track of its own | Rejected: its only work that doesn't need T1 is a read |

## Decision

### The account

- **`cosmos01-<deploymentId>`** in `rg-<prefix>-<environment>` (`infra/modules/cosmos01.bicep`, `config/versions.json` `cosmosdb`): Azure Cosmos DB for NoSQL, one region without zone redundancy or automatic failover, Session consistency, `disableLocalAuth` and `disableKeyBasedMetadataWriteAccess` true, `publicNetworkAccess` Disabled, TLS 1.2. The database **`contosocare`** and the container **`patient-events`**, partitioned by **`/patientId`** (hash, version 2), at **400 RU/s** of manual throughput on the container. Every path is indexed except the documents' `payload` filler, which nothing queries, so a write costs its size and not its index.
- **No availability zones or continuous backup:** zones multiply standard provisioned throughput by 1.25 ([pricing](https://azure.microsoft.com/pricing/details/cosmos-db/standard-provisioned/)), and point-in-time restore isn't part of the demo, whose runner writes its data again, so the default periodic backup applies. `ps-rule.yaml` suppresses PSRule's `Azure.Cosmos.AvailabilityZone` and `Azure.Cosmos.ContinuousBackup` for `cosmos01` with that reason.
- **The private endpoint `pe-<prefix>-<environment>-cosmos01`** in `snet-pe`, group `Sql`, with the `privatelink.documents.azure.com` zone linked to the virtual network and a zone group, in both network modes. `snet-pe`'s network security group lets T1's subnet reach it on TCP 443 (`Allow-Cosmos-From-T1`).
- **T1's data-plane role** (`infra/modules/cosmos01-access.bicep`): a `sqlRoleAssignment` of Cosmos DB Built-in Data Contributor (`00000000-0000-0000-0000-000000000002`) to sqlvm01's system-assigned identity, scoped to the account, with a deterministic name, so a redeploy changes nothing. No Azure role assignment.
- **The free tier:** `deploy.ps1` decides it before the template (`Resolve-DemoT5FreeTier`, `DEPLOY.T5.FREETIER`): an existing account keeps what it has; a new one gets it when the subscription isn't internal and Azure Resource Graph lists no other account in the subscription with it, and not when Resource Graph can't be read. Azure refuses the free tier in internal subscriptions ("Free tier is not supported for Internal subscriptions", live 2026-11-18, `subscriptionPolicies.quotaId` `Internal_2014-09-01`), so the run reads the subscription's offer first ([Subscriptions - Get](https://learn.microsoft.com/rest/api/resources/subscriptions/get)) rather than lose a failed template's 7 minutes. A refusal deploys the template again without it, once, with a Warning that gives Azure's reason. `t5UseFreeTier` false never asks for it.
- **Turning it off:** `t5Enabled` false in the configuration leaves T5 out of the template, the checks, the activity, and DONE (`DEPLOY.T5.OFF`, Not selected); an account an earlier run created stays and keeps billing until `destroy.ps1`.

### Deployment, upgrade, and DONE

- **T1's track** has a **T5** step in stage T4, after T4's: `Test-DemoT5` (`T5.ACCOUNT`, `T5.ENTRAONLY`, `T5.NETWORK`, `T5.CONTAINER`, `T5.FREETIER`, `T5.ACCESS`), then the runner's warmup through T1 (`WORKLOAD.T5.WARMUP`: a token, a read of the container, an upsert and a point read of one document), tried again every 45 seconds for up to 10 minutes while the new data-plane role and the private DNS record come into effect. A T5 failure doesn't stop T1's track. The Activity step sets T5's profile with T1's.
- **The run's validation** checks T5 in Database Hub's estate (`HUB.ESTATE.T5`, Azure Resource Graph) and its Azure Monitor metrics (`METRICS.T5`: requests and normalized RU in the last 15 minutes). **DONE requires both**, when T5 is on.
- **An older demo:** `DEPLOY.T5.MISSING` makes a resumed run start from preflight when the account doesn't exist, so the template creates it; a plain `deploy.ps1` on a finished demo runs the template anyway. No step for a person.
- **The status page** has a T5 group (Account checks and T1's access; Metrics in Azure Monitor).

### The workload

- **The runner** (`workload-generator`, `--target T5 --server <account>.documents.azure.com`) talks to the documented REST API over HTTPS with an Entra token for T1's managed identity, acts only in `contosocare`/`patient-events`, and keeps a run store of its own (`C:\ProgramData\DbHubDemo\t5-runs.json`).
- **healthy-baseline** includes T5 (bounded upserts and point reads over a fixed set of ids, so the data stays flat). **ru-storm** (T5 only) drives normalized RU to 100% with 429s by writing to one hot partition key, then a calm phase lets it recover; its maximum duration bounds it (ADR 0010). It writes a bounded, deterministic set of documents and deletes them at its end, also when it's stopped or cancelled, and `reset-demo.ps1 -Target T5` removes any left over, so every session starts from the same data.
- **Run all's showcase timeline** (ADR 0026) runs ru-storm on T5 twice, and the session control's allow-lists include T5 and ru-storm.

### Stop, start, cost, and teardown

- **No stop:** `stop-demo.ps1` turns T5's activity off and says what bills on (`STOP.T5`, Not supported): the throughput (nothing on the free tier), the storage, and the private endpoint and its DNS zone. `start-demo.ps1` has nothing to start (`START.T5`) and sets T5's profile. The nightly safety stop has nothing to stop either.
- **Cost:** `estimate-cost.ps1`, preflight, and the Cost area price T5 as an idle cost, all month: the throughput (Free Tier meters when the account has or gets the free tier, list price otherwise or when it wasn't checked), about 1 GB of storage, the private endpoint, the DNS zone, and Defender for Azure Cosmos DB (`CosmosDbs`) when its plan is on Standard. Defender CSPM doesn't bill Cosmos DB accounts. Dated example (2026-11-18, West US 3): **$31.41 a month at list price, $7.80 on the free tier**, plus about $3.50 with Defender for Azure Cosmos DB.
- **Teardown:** `destroy.ps1` deletes the account with the resource group; the residual check is by tag and resource group, so it covers T5 with no change.

### Monitoring, status, and history

- `status.ps1` reads T5's state and its metrics (`STATUS.T5`), `validate.ps1 -Area T5` runs `Test-DemoT5 -IncludeMetrics`, and its Workload area reads the runner's T5 status.
- **History:** the session's T5 metrics are captured from the operator side, as T4's are (`COSMOS_METRICS`), and the live-activity notebook writes them to the history tables, so the history model has T5's peak normalized RU, requests, 429s, and RU consumed.

## Consequences

- Database Hub shows five targets, and T5's Performance view has a moment worth presenting: normalized RU at 100%, throttled requests, and the recovery.
- T5 bills every hour it exists, $7.80 to $31.41 a month (dated example), because an account has no stop; the estimate and `stop-demo.ps1` say so, and `destroy.ps1` is the way to stop it.
- The 429s are intended: the runner counts them as the scenario's signal, not as failures.
- Avg Latency stays empty (the runner uses the gateway), and Availability is hourly, so a 10-minute storm shows in normalized RU and throttled requests first.
- A subscription whose free-tier slot is taken pays list price; the run says which account has it.

## Validation

- **Unit tests:** `tests/unit/DbHubDemo.T5.Tests.ps1` (names, the free tier, the upgrade's resume, `Test-DemoT5`, `METRICS.T5`, `STOP.T5`, the warmup's retry), the cost estimate's T5 components (`DbHubDemo.Cost.Tests.ps1`), the tracks and the status page (`DbHubDemo.Tracks.Tests.ps1`, `DbHubDemo.Progress.Tests.ps1`), and the runner's own tests.
- **Live** (2026-11-18, `rg-dbhubc5-demo`, West US 3, private mode, an internal subscription; the [implementation report](../implementation-report.md#t5-azure-cosmos-db-for-nosql-2026-11-18) has the details): an environment that `main` deployed upgraded to T5 with a plain `./scripts/deploy.ps1` and ended **DONE** with no Fail, after two live findings fixed the same evening (a `METRICS.T5` crash when nothing was throttled, and the free tier in an internal subscription, which Azure refuses); `ru-storm` took normalized RU to 100% with up to 2,481 throttled requests a minute, then back to the baseline's 4% with no 429s, with Availability at 100%; Run all's 30-minute session ended its T5 activity at its baseline before the session's end and saved T5's history (`cosmosdb.T5.recovery` **Pass**). Database Hub's own pages have no API, so seeing T5 there stays a manual check.

## Sources

Checked 2026-11-18:

- [Monitor Azure Cosmos DB in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor-cosmos-db)
- [Normalized RU consumption](https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units)
- [Diagnose and troubleshoot request rate too large (429)](https://learn.microsoft.com/azure/cosmos-db/nosql/troubleshoot-request-rate-too-large)
- [Supported metrics for Microsoft.DocumentDB/databaseAccounts](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-documentdb-databaseaccounts-metrics)
- [Free tier](https://learn.microsoft.com/azure/cosmos-db/free-tier)
- [Grant data-plane access with role-based access control](https://learn.microsoft.com/azure/cosmos-db/nosql/how-to-grant-data-plane-access)
- [Connect with role-based access control and Microsoft Entra ID](https://learn.microsoft.com/azure/cosmos-db/how-to-connect-role-based-access-control)
- [Configure Azure Private Link for Azure Cosmos DB](https://learn.microsoft.com/azure/cosmos-db/how-to-configure-private-endpoints)
- [Access control on Azure Cosmos DB resources (REST)](https://learn.microsoft.com/rest/api/cosmos-db/access-control-on-cosmosdb-resources)
- [Database Accounts - Get](https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/database-accounts/get)
- [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Defender CSPM billable resources](https://learn.microsoft.com/azure/defender-for-cloud/concept-cloud-security-posture-management)
