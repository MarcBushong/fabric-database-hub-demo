# ADR 0004: Isolating the nested guest from IMDS and the wire server

- **Status:** Accepted; validated live on 2026-10-20 (Phase 7), except the port-ACL-only test (see Validation)
- **Date:** 2026-10-19
- **Decision source:** User-directed (Q5b: IMDS and the wire server are blocked inside the guest; the host's Azure guest agent is never disabled), with engineering detail
- **Related:** [ADR 0003](0003-t2-host-size-security-type-bootstrap.md), [ADR 0005](0005-arc-onboarding-authentication.md), [ADR 0007](0007-networking-modes-and-egress.md), [security model](../security-model.md)

## Context

- The Azure Connected Machine agent isn't supported on Azure VMs except for evaluation. It detects an Azure VM through the Instance Metadata Service (IMDS) at `169.254.169.254`. Microsoft's evaluation procedure sets `MSFT_ARC_TEST`, disables the Azure guest agent, and blocks IMDS with a firewall rule.
- T2 is a nested Hyper-V guest behind the host's NAT, not an Azure VM. If guest traffic to `169.254.169.254` or `168.63.129.16` (the wire server, which also serves Azure-provided DNS) were forwarded through the NAT:
  - the agent could mistake the guest for an Azure VM; and
  - any process in the guest could request tokens for the host's managed identities, which is a privilege-escalation path across the host trust boundary.
- Arc Jumpstart blocks these addresses on the host by disabling the host's guest agent. That would break Run Command, extensions, and managed-identity tokens on our host, which the whole automation depends on.
- Blocking the wire server inside the guest also blocks Azure-provided DNS, which listens on the same address.
- Windows Firewall block rules take precedence over allow rules, so "block the wire server except DNS" can't be expressed as block-all plus allow-53 on the same address.

## Decision drivers

1. The Arc agent must see a non-Azure machine.
2. No path from the guest to the host's managed-identity tokens.
3. The host's guest agent, Run Command, and extensions keep working.
4. The guest can still resolve names.

## Considered options

1. Disable the host's guest agent and block on the host (Jumpstart). Rejected: breaks the host's automation.
2. Guest firewall rules only.
3. **Guest firewall rules, plus host-enforced Hyper-V port ACLs on the guest's network adapter, plus a DNS forwarder on the host.**
4. Set `MSFT_ARC_TEST` in the guest. Rejected: that is the evaluation procedure for Azure VMs, and the guest isn't one.

## Decision

Option 3. The bootstrap applies these in step 8 (ADR 0003), before any Arc component is installed:

1. **Guest firewall (the user-directed control):** outbound block rules in the guest for `169.254.169.254/32` and `168.63.129.16/32`, all ports and protocols, in every profile.
2. **Host-enforced port ACLs (defense in depth):** `Add-VMNetworkAdapterAcl` deny rules on the guest's virtual network adapter for the same two addresses, in both directions. They're enforced by the host's virtual switch, so an administrator inside the guest can't remove them. They don't touch the host's own traffic or guest agent.
3. **DNS through the host:** the host runs the in-box DNS Server role, listening only on the internal NAT gateway address `192.168.200.1` and forwarding to Azure-provided DNS. The guest's only DNS server is `192.168.200.1`. Nothing outside the host can reach the forwarder, because the NSG denies inbound traffic from the virtual network and the internet (ADR 0007).
4. **The host's guest agent is never disabled**, and `MSFT_ARC_TEST` is never set on the guest.

## Consequences

- **Positive:** the guest looks like an on-premises server to Arc. Host managed-identity tokens can't be reached from the guest even by a guest administrator. Host automation is unaffected.
- **Negative:** the DNS Server role is one more component on the host. Guest name resolution depends on the host, which is already the guest's only network path.
- **Risks accepted:** Arc support for nested guests isn't explicitly documented (plan risk R3). If validation fails, the documented opt-in **evaluation-only** fallback applies (ADR 0006), labeled as such everywhere.

## Validation

Phase 6 and Phase 7 (live, pending go-ahead), run over PowerShell Direct and recorded by `validate.ps1`:

- From the guest, an IMDS request (`http://169.254.169.254/metadata/instance` with the `Metadata: true` header) fails, and a TCP connection to `168.63.129.16:80` fails.
- With the guest firewall rules temporarily disabled in a test, the port ACLs still block both addresses.
- From the guest, `Resolve-DnsName management.azure.com` succeeds through `192.168.200.1`.
- `azcmagent connect` succeeds without `MSFT_ARC_TEST`, and `azcmagent show` reports **Connected**.
- On the host, Run Command and managed-identity token requests still succeed.

Results, as of 2026-10-21:

- **Live, 2026-10-20 (Phase 7):** the onboarding probe found IMDS and the wire server unreachable from inside the guest, and DNS resolving through the host; `azcmagent connect` reached **Connected** without `MSFT_ARC_TEST`; and the host's Run Commands kept working (implementation report, Phase 7 live results).
- **Phase 14 (as built):** `validate.ps1 -Area T2` runs the same read-only probe (`Invoke-DemoArcOnboard.ps1 -Action Probe`) whenever the host runs and reports `T2.GUEST.ISOLATION`: **Fail** if the guest reaches IMDS or the wire server, a Warning if DNS fails or the guest doesn't answer. While the host is deallocated, it's a Warning that says to start it.
- **Still manual:** the test with the guest firewall rules temporarily disabled, which checks the port ACLs on their own. It changes the guest, so validation doesn't do it (risk R221).

## Sources (checked 2026-10-19)

- Evaluate Azure Arc-enabled servers on an Azure VM: <https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine>
- Azure Instance Metadata Service: <https://learn.microsoft.com/azure/virtual-machines/instance-metadata-service>
- What is IP address 168.63.129.16: <https://learn.microsoft.com/azure/virtual-network/what-is-ip-address-168-63-129-16>
- `Add-VMNetworkAdapterAcl`: <https://learn.microsoft.com/powershell/module/hyper-v/add-vmnetworkadapteracl>
- DNS Server forwarders: <https://learn.microsoft.com/windows-server/networking/dns/manage-dns-forwarders>
- Nested virtualization: <https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/nested-virtualization>
