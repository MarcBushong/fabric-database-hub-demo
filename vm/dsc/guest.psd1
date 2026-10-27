@{
    # Desired state for the nested guest arcsql01 (ADR 0003, ADR 0004, ADR 0006). The host converges to it
    # over PowerShell Direct. vCPUs, memory, and VHDX size come from settings.json (the profile).

    Name                 = 'arcsql01'
    Generation           = 2
    AdministratorName    = 'Administrator'
    TimeZone             = 'UTC'

    # Image applied with DISM from the Windows Server 2022 evaluation ISO: Datacenter with Desktop
    # Experience, because the PaygWizard step needs a desktop.
    ImageNamePattern     = '*Datacenter*Desktop Experience*'

    # Static addressing behind the host NAT. The host is the gateway and the only DNS server.
    IPAddress            = '192.168.200.10'
    PrefixLength         = 24
    Gateway              = '192.168.200.1'
    DnsServers           = @('192.168.200.1')

    # IMDS and the wire server: blocked by the guest firewall and by host-enforced port ACLs (ADR 0004).
    BlockedAddresses     = @('169.254.169.254', '168.63.129.16')
    FirewallRulePrefix   = 'DbHubDemo-Block-'

    # Folders inside the guest.
    MediaFolder          = 'C:\DbHubDemo\media'
    ToolsFolder          = 'C:\ProgramData\DbHubDemo'

    # SQL Server 2022 unattended setup (ProductKey and Developer modes). Switches follow "Install SQL
    # Server from the command prompt" on Microsoft Learn. The Azure extension feature is left out: Arc
    # onboarding is done by the orchestrator (ADR 0005).
    Sql                  = @{
        InstanceName     = 'MSSQLSERVER'
        Features         = 'SQLENGINE'
        SysAdminAccounts = 'BUILTIN\Administrators'
        ServiceAccount   = 'NT Service\MSSQLSERVER'
        AgentAccount     = 'NT Service\SQLSERVERAGENT'
        SetupTimeoutMinutes = 90
    }

    # Database file caps that respect the 64 GB guest VHDX (database/arcsql01).
    Database             = @{
        Name = 'ContosoCare'
    }
}
