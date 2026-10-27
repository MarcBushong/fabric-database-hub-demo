# ADR 0007: Networking modes and egress strictness

- **Status:** Accepted
- **Date:** 2026-10-19 (revised the same day for plan §9, Revision 2)
- **Decision source:** User-directed (Q4b: West US 3 with on-demand Bastion Basic; Q5a: public by default, private selectable; Q5b: NSG outbound 443 and DNS only, IMDS blocked in the guest, FQDN gap documented; 2026-10-20: `networkMode` `auto` by default, resolved from Azure Policy), with engineering detail
- **Related:** [ADR 0004](0004-guest-imds-isolation.md), [ADR 0008](0008-identity-rbac-abac.md), [ADR 0016](0016-cost-profiles.md), [architecture](../architecture.md)

## Context

- **West US 3** qualifies for Hub SQL performance monitoring and SQL VM unified inventory. Bastion Developer isn't offered there.
- Bastion Basic needs a subnet named `AzureBastionSubnet` of /26 or larger and a Standard static public IP. It bills hourly while it exists and takes about 10 minutes to provision.
- NSG service tags don't cover `*.<region>.arcdataservices.com` or `download.microsoft.com`, so an FQDN allow-list would need Azure Firewall at extra cost.
- The Arc Connected Machine agent uses only HTTPS on TCP 443; port 80 isn't used.
- Windows VMs in Azure activate against Azure KMS at `azkms.core.windows.net` on TCP 1688 (documented addresses `20.118.99.224` and `40.83.235.53`).
- **Platform traffic isn't governed by allow rules.** A VM's traffic to Azure-provided DNS (`168.63.129.16:53`), IMDS, and Windows licensing (KMS) is allowed by the platform regardless of NSG rules. The service tags `AzurePlatformDNS`, `AzurePlatformIMDS`, and `AzurePlatformLKM` exist only to **deny** that traffic; Azure rejects an Allow rule that uses them (`SecurityRuleInvalidAccessType`). The platform's licensing rule is disabled when a `0.0.0.0/0` route is configured.
- T3 is configured from T1 in both network modes (plan §9.2), so T1 needs a path to T3 in both modes.

## Decision drivers

1. No inbound exposure; no VM public IPs.
2. Lowest cost by default.
3. Least egress that still works for Arc, Hub telemetry, activation, and updates.
4. Honest documentation of what NSGs can't enforce.

## Decision

### Address plan

| Subnet | CIDR | Purpose |
|---|---|---|
| `snet-sqlvm` | `10.42.0.0/27` | T1. Service endpoint `Microsoft.Sql` in public mode. |
| `snet-archost` | `10.42.0.32/27` | T2 host. The guest sits behind the host's NAT (`192.168.200.0/24`). |
| `snet-pe` | `10.42.0.64/27` | Private endpoints (private mode only). |
| `AzureBastionSubnet` | `10.42.0.128/26` | On-demand Bastion. The subnet always exists and costs nothing. |

The virtual network is `10.42.0.0/24`.

### NSG rules for `snet-sqlvm` and `snet-archost`

| Direction | Priority | Rule | Action |
|---|---|---|---|
| Inbound | 100 | TCP 3389 from `AzureBastionSubnet` | Allow |
| Inbound | 4000 | Any from `VirtualNetwork` | Deny (overrides the default `AllowVnetInBound`) |
| Outbound | 100 | TCP 443 to `Internet` | Allow |
| Outbound | 120 | TCP 1688 to `20.118.99.224/32` and `40.83.235.53/32` (Azure KMS) | Allow |
| Outbound | 130 | `snet-sqlvm` only: TCP 1433 and 11000–11999 to the `Sql.<region>` service tag (T1 to T3 in public mode, including the redirect connection policy's ports) | Allow |
| Outbound | 200 | TCP 22 and 3389 to `VirtualNetwork` (lateral movement) | Deny |
| Outbound | 4000 | Any to `Internet` | Deny |

- **DNS:** there's no DNS rule. Azure-provided DNS is platform traffic that NSGs allow by default, so the 443-and-DNS intent of Q5b holds without one. *(Phase 5 live finding: the original design had an Allow rule for `AzurePlatformDNS`, which Azure rejects; see the addendum below.)*
- **KMS:** the platform already allows Windows activation, so this rule is belt-and-braces: it keeps activation working if the platform's licensing rule is disabled, for example by a `0.0.0.0/0` route. It's narrow (two documented addresses, one port).
- **Platform rules:** Azure Load Balancer probes and the wire server keep working (default rules and platform traffic).
- **Bastion:** `AzureBastionSubnet` gets the NSG rules that Bastion documents as required.
- **T1 SQL connectivity:** `LOCAL`. The runner and DBA tools run on T1 itself, so nothing needs network access to T1's SQL Server.

### Modes (`networkMode`)

| | `public` | `private` |
|---|---|---|
| T3 network access | Public endpoint enabled; no firewall IP rules; no "Allow Azure services"; one VNet rule for `snet-sqlvm` | Public network access disabled; private endpoint in `snet-pe`; `privatelink.database.windows.net` zone linked to the VNet |
| T3 authentication | Microsoft Entra-only, TLS 1.2 minimum | Same |
| How T1 reaches T3 | Service endpoint | Private endpoint |
| Extra cost | None | Private endpoint, per hour plus data, and the private DNS zone, per month (ADR 0016) |

- **`auto` (the default since 2026-10-20):** preflight's read-only policy inventory resolves it before anything is deployed. It becomes `private` when an enforced Azure Policy turns off (modify) or denies public network access on SQL servers, because public mode's VNet rule and the operator-IP fallback both need the public endpoint. Otherwise it becomes `public`, the cheaper mode. When the inventory is skipped (`-SkipPolicyInventory`) or can't read every policy, `auto` resolves to `private`, which works under any policy.
- **Explicit values:** `public` fails preflight (`PREFLIGHT.POLICY.SQLPUBLIC`) when such a policy applies; `private` is always accepted.
- **Where the result goes:** the effective mode is in the evidence of `PREFLIGHT.POLICY.SQLPUBLIC` (`effectiveNetworkMode`). Scripts pass it to the template, which accepts only `public` or `private`, and to the cost estimate. `Get-DemoDeploymentParameter` refuses an unresolved `auto`.

### Interactive access

- `start-demo.ps1 -Interactive` creates Bastion Basic and its Standard public IP. `stop-demo.ps1` removes both.
- A scheduled check (`status`) removes Bastion after `bastionMaxHours` (default 4) whether or not someone remembered (ADR 0016, C8).
- Automation never needs Bastion; it uses Run Command.

### Artifact delivery network (revised 2026-10-20)

- The artifact cache storage account was dropped (ADR 0016, C9), so there's no storage endpoint to secure.
- The bootstrap bundle reaches the VMs through Run Command, a control-plane path. Media downloads directly from Microsoft over HTTPS (TCP 443), which the rules above already allow, and is checked against its pinned SHA-256.

### Fallback interactive T-SQL (prerequisite P6 not met)

- **Public mode:** `configure-monitoring.ps1 -T3Interactive` adds a firewall rule for the operator's current public IP, runs the T-SQL with the operator's Entra token, and removes the rule in a `finally` block.
- **Private mode:** the operator runs the same script on T1 through Bastion.

### Documented FQDN gap

- NSGs allow any HTTPS destination. They can't restrict traffic to the Arc and telemetry FQDNs.
- A strict allow-list needs Azure Firewall. That isn't part of v1. The extra cost and design are documented in [limitations](../limitations.md).

## Consequences

- **Positive:** nothing is reachable from the internet. Egress is narrow and still covers Arc, telemetry, activation, and updates over HTTPS. Public mode costs nothing extra.
- **Negative:** HTTPS egress isn't limited by destination. Updates that need HTTP port 80 won't work; Arc doesn't need it.
- **Risks accepted:** the FQDN gap (plan risk R7). A Bastion left behind is bounded by the automatic removal.

## Phase 5 addendum: live finding on platform service tags (2026-10-20)

- **What happened:** the first live deployment failed on `nsg-<prefix>-<env>-sqlvm` and `nsg-<prefix>-<env>-archost` with `SecurityRuleInvalidAccessType`: "Value provided: Allow. Allowed values: Deny." The rule was `Allow-DNS-Outbound` to the `AzurePlatformDNS` service tag. What-if, the Bicep linter, and PSRule don't check this.
- **Why:** `AzurePlatformDNS`, `AzurePlatformIMDS`, and `AzurePlatformLKM` can be used only in Deny rules. The platform allows that traffic regardless of NSG rules, so no allow rule is needed.
- **Fix:** the DNS rule is removed, and the KMS rule is kept as belt-and-braces (see above). A Pester test now walks the compiled `azuredeploy.json` and fails if any Allow rule uses one of the three tags.
- **Second finding, same day:** the rewritten KMS rule description was 167 characters, and ARM's pre-deployment validation rejected it (`SecurityRuleDescriptionTooLong`; the limit is 140). It's shortened, and the same Pester test block now checks every rule description's length. Every template change is followed by a what-if before deploying.
- **No change in intent:** the subnets still allow only HTTPS, platform traffic (DNS, IMDS, licensing), KMS, and T1-to-T3 SQL, and deny everything else to the internet.

## Phase 5 addendum: network mode auto and subnet policies (2026-10-20)

- **Finding:** the tenant's policy set assigned at the tenant root management group includes a Modify policy that sets `publicNetworkAccess` to `Disabled` on SQL servers. Public mode can't work under it: T1's VNet rule and the operator-IP fallback both use T3's public endpoint.
- **Decision (user-directed):** `networkMode` gains `auto`, now the default, resolved by preflight as described in the modes section. The template keeps only `public` and `private`.
- **Subnet policies:** every subnet now sets `privateEndpointNetworkPolicies` explicitly. The VM and Bastion subnets use `Disabled`, their live value; without it, each what-if reported a change to `Enabled`. `snet-pe` keeps `NetworkSecurityGroupEnabled`, so `nsg-<prefix>-<env>-pe` filters traffic to the T3 private endpoint. A Pester test checks the compiled template.

## Phase 8 addendum: T3 as built (2026-10-20)

- **Template:** `infra/modules/azuresql01.bicep`, deployed by `demo.bicep` as `azuresql01`, with native resources (why not AVM: [architecture](../architecture.md#t3-as-built-phase-8)).
- **Both modes:** logical server `azuresql01-<deploymentId>`, Microsoft Entra-only from creation with the P6 group as administrator, minimum TLS 1.2, no SQL authentication, no IP firewall rules, and no "Allow Azure services" rule. A Pester test evaluates the compiled template in both modes.
- **Private mode** (what `auto` resolves to in this tenant):
  - Public network access `Disabled`.
  - Private endpoint `pe-<prefix>-<env>-azuresql01` in `snet-pe`, group `sqlServer`, with the fixed NIC name `pe-<prefix>-<env>-azuresql01-nic`. It's in the same subscription as the server, so its connection is approved automatically.
  - The `privatelink.database.windows.net` zone (built from the cloud's SQL host suffix), linked to `vnet-<prefix>-<env>` without auto-registration, and the endpoint's DNS zone group `default`, which writes its A record.
  - T1 connects to `<server>.database.windows.net`, which resolves to the endpoint inside the VNet. Microsoft documents that logins to the private IP or the `privatelink` name fail.
  - With the server's Default connection policy, connections through a private endpoint use Proxy on TCP 1433, the only port `nsg-<prefix>-<env>-pe` admits, and only from `snet-sqlvm`. Redirect would need TCP 1433–65535 to the endpoint, so it isn't used.
- **Public mode:** public network access `Enabled` with one VNet rule, for `snet-sqlvm`, through the subnet's `Microsoft.Sql` service endpoint. `ignoreMissingVnetServiceEndpoint` is false, so a missing service endpoint fails the deployment instead of leaving T1 locked out. From inside Azure, T1 uses Redirect through the existing `Allow-AzureSql-Outbound` rule.
- **Removal between demos** (`Remove-DemoT3`; `stop-demo.ps1 -RemoveT3` in Phase 13): the private endpoint goes first, which also removes its A record, then the server and its database. The zone and its VNet link stay, so a recreated T3 resolves as soon as its new endpoint registers. An incremental deployment never deletes a resource that a changed `networkMode` leaves out; `deploy.ps1` handles that ([ADR 0001](0001-iac-bicep-avm-compiled-arm.md#phase-5-addendum-deployment-stacks-evaluation-2026-10-19)).
- **Checks:** `Test-DemoT3` reports `T3.NETWORK`. Private: public network access off, the endpoint Succeeded and Approved for this server, a zone group for the zone, and the zone linked to the VNet. Public: a ready `snet-sqlvm` VNet rule and no IP firewall rule.
- **Fallback when P6 isn't met (hook):** `Add-DemoT1ToT3AdminGroup` reports **Manual action required** with the exact `az ad group member add` command for a group owner. Otherwise a member of the P6 group runs the `Setup` script set ([database/azuresql](../../database/azuresql/README.md)) interactively: on T1 through Bastion in private mode, or with a temporary firewall rule for the operator's IP in public mode. `configure-monitoring.ps1 -T3Interactive` (Phase 9) automates it.

## Validation

- **Phase 5 (static and live):** what-if shows the rules above (done 2026-10-20). Effective security rules on each NIC match, and Windows activation succeeds on T1 and the host (Phase 6, pending go-ahead).
- **Phase 7 and Phase 9 (live, pending go-ahead):** Arc reaches **Connected**; telemetry arrives from every target over 443.
- **Phase 8 (live, pending go-ahead):** T1 reaches T3 in both modes; a client outside the VNet can't; the private DNS zone resolves to the private endpoint.

## Sources (checked 2026-10-19)

- Arc network requirements: <https://learn.microsoft.com/azure/azure-arc/servers/network-requirements>
- Arc SQL prerequisites: <https://learn.microsoft.com/sql/sql-server/azure-arc/prerequisites>
- Azure KMS activation: <https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/custom-routes-enable-kms-activation>
- Service tags (`AzurePlatformDNS`, `AzurePlatformIMDS`, `AzurePlatformLKM`; deny-only): <https://learn.microsoft.com/azure/virtual-network/service-tags-overview>
- NSG overview, Azure platform considerations (DNS, IMDS, and licensing are platform traffic): <https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#azure-platform-considerations>
- Bastion configuration settings: <https://learn.microsoft.com/azure/bastion/configuration-settings>
- Bastion SKU comparison: <https://learn.microsoft.com/azure/bastion/bastion-sku-comparison>
- Bastion NSG requirements: <https://learn.microsoft.com/azure/bastion/bastion-nsg>
- Azure SQL private endpoints: <https://learn.microsoft.com/azure/azure-sql/database/private-endpoint-overview>
- Azure SQL connectivity settings (public network access; checked 2026-10-20): <https://learn.microsoft.com/azure/azure-sql/database/connectivity-settings>
- Private endpoint DNS zones (checked 2026-10-20): <https://learn.microsoft.com/azure/private-link/private-endpoint-dns>
- Policy assignments that apply to a subscription (`$filter=atScope()`; checked 2026-10-20): <https://learn.microsoft.com/rest/api/policy-authorization/policy-assignments/list>
- Azure SQL VNet rules: <https://learn.microsoft.com/azure/azure-sql/database/vnet-service-endpoint-rule-overview>
- Azure SQL connectivity architecture (redirect ports): <https://learn.microsoft.com/azure/azure-sql/database/connectivity-architecture>
- SQL Server VM connectivity: <https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/ways-to-connect-to-sql>
- Connection policy through a private endpoint, and the server FQDN requirement (checked 2026-10-20): <https://learn.microsoft.com/azure/azure-sql/database/private-endpoint-overview#use-redirect-connection-policy-with-private-endpoints>
- `Microsoft.Sql/servers` template reference, `administrators` (checked 2026-10-20): <https://learn.microsoft.com/azure/templates/microsoft.sql/servers>
- `Microsoft.Network/privateEndpoints` and `privateDnsZones` template references (checked 2026-10-20): <https://learn.microsoft.com/azure/templates/microsoft.network/privateendpoints>, <https://learn.microsoft.com/azure/templates/microsoft.network/privatednszones>
