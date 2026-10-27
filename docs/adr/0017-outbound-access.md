# ADR 0017: Outbound internet access for the VM subnets

- **Status:** Accepted
- **Date:** 2026-10-19
- **Decision source:** Engineering (Phase 5 finding)
- **Related:** [ADR 0007](0007-networking-modes-and-egress.md), [ADR 0016](0016-cost-profiles.md), [architecture](../architecture.md)

## Context

- **Default outbound access is retiring.** Subnets created with Azure networking API versions released after 2026-03-31 are private by default (`defaultOutboundAccess: false`). VMs in a private subnet have no internet egress unless an explicit method is configured: a NAT gateway, Standard Load Balancer outbound rules, or an instance-level public IP. Setting `defaultOutboundAccess: true` explicitly is still supported, but Microsoft recommends an explicit method.
- **The VMs need egress.** T1 and the T2 host have no public IPs (ADR 0007), but they need HTTPS egress for Arc, Hub telemetry, extension and media downloads, and Windows activation.
- **Cost:** a NAT gateway bills every hour it exists, plus data processed, and needs a Standard public IP. Together with the always-on disks and storage, it would have pushed idle-plus-light-use cost above the original $75 monthly ceiling. The ceiling is now a hard $250 (2026-10-20), but every default stays the cheapest working option (ADR 0016). `estimate-cost.ps1` prices it live.

## Considered options

1. **Set `defaultOutboundAccess: true` explicitly on the VM subnets.**
2. NAT gateway with a Standard public IP.
3. A public IP on each VM. Rejected: it contradicts the no-VM-public-IP rule (ADR 0007).
4. Standard Load Balancer outbound rules. Rejected: similar cost to a NAT gateway, with more moving parts.

## Decision

`outboundMode` parameter, default `DefaultOutboundAccess`:

| Mode | VM subnets | Extra resources | Cost |
|---|---|---|---|
| `DefaultOutboundAccess` (default) | `defaultOutboundAccess: true`, set explicitly | None | None |
| `NatGateway` | `defaultOutboundAccess: false` plus a NAT gateway association | NAT gateway `ng-<prefix>-<env>` and Standard public IP `pip-<prefix>-<env>-nat` | Hourly plus data processed, priced by `estimate-cost.ps1` |

- The private-endpoint subnet always sets `defaultOutboundAccess: false`.
- The NSG rules (ADR 0007) are the same in both modes.
- PSRule's `Azure.VNET.PrivateSubnet` finding is suppressed in `ps-rule.yaml`, with this ADR as the justification.
- **Switching modes:** plain incremental deployments don't remove resources that leave the template. When the mode changes from `NatGateway` back to `DefaultOutboundAccess`, `deploy.ps1` deletes the NAT gateway and its public IP explicitly (Phase 13), and `destroy` removes them with the resource group.

## Consequences

- **Positive:** no extra cost or resources by default; the egress path is explicit in the template rather than implied by an API version.
- **Negative:** the default relies on a path Microsoft is phasing out, and the outbound IP isn't fixed or owned.
- **Risk accepted:** if explicit default outbound access stops being supported, `NatGateway` mode is the ready fallback.

## Validation

- **Phase 5 (static):** the compiled template sets `defaultOutboundAccess` explicitly on every subnet; PSRule passes with the documented suppression.
- **Phase 6 (live, pending go-ahead):** in each mode, T1 and the host reach Arc, telemetry, and download endpoints over HTTPS, and Windows activation succeeds.

## Sources (checked 2026-10-19)

- Default outbound access: <https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access>
- NAT gateway: <https://learn.microsoft.com/azure/nat-gateway/nat-overview>
- PSRule rule `Azure.VNET.PrivateSubnet`: <https://azure.github.io/PSRule.Rules.Azure/en/rules/Azure.VNET.PrivateSubnet/>
