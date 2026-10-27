@{
    # Desired state for the T2 host archost01 (ADR 0003, ADR 0004). Invoke-HostBootstrap.ps1 converges to it.
    # Sizes that vary by profile (guest vCPUs, memory, VHDX size) come from settings.json instead.

    # Roles. Hyper-V needs a restart; the DNS Server role is the guest's only resolver (ADR 0004).
    Features         = @('Hyper-V', 'DNS')

    # Internal switch plus NAT for the guest. The host is the gateway and the DNS server.
    SwitchName       = 'DbHubDemoNat'
    NatName          = 'DbHubDemoNat'
    NatPrefix        = '192.168.200.0/24'
    HostAddress      = '192.168.200.1'
    PrefixLength     = 24

    # The DNS Server listens only on the NAT gateway address and forwards to Azure-provided DNS.
    DnsListenAddress = '192.168.200.1'
    DnsForwarders    = @('168.63.129.16')

    # The data disk at LUN 0 holds the media and the guest VHDX. Without one (dataDiskSku None, the
    # lowest-cost default), they go under DbHubDemo\ on the OS disk (C:), after a free-space check: the
    # VHDX's maximum size, plus the media, plus OsDiskMarginGB.
    DataDisk         = @{
        Lun                = 0
        DriveLetter        = 'F'
        Label              = 'DbHubData'
        AllocationUnitSize = 65536
        MediaFolder        = 'DbHubDemo\media'
        VmFolder           = 'DbHubDemo\vms'
        OsDiskMarginGB     = 10
    }

    # Pinned media names in the bundle manifest (config/versions.json media).
    Media            = @{
        WindowsServer = 'windowsServer2022Eval'
        SqlServer     = 'sqlServer2022'
        SqlDeveloper  = 'sqlServer2022Developer'
    }

    # PaygWizard: the setup wizard's "Use Azure Login" signs in through the WebView2 runtime, which Windows
    # Server 2022 doesn't include; without it the sign-in window stays blank (live finding, 2026-10-21). The
    # Evergreen Standalone Installer carries the whole runtime over HTTPS; the bootstrapper downloads it over
    # HTTP (port 80), which the guest's NSG blocks. It's evergreen, so it's verified by its Microsoft
    # Authenticode signature instead of a pinned hash.
    # https://learn.microsoft.com/microsoft-edge/webview2/concepts/distribution
    WebView2         = @{
        Url                   = 'https://go.microsoft.com/fwlink/?linkid=2124701'
        FileName              = 'MicrosoftEdgeWebView2RuntimeInstallerX64.exe'
        SignerPattern         = 'O=Microsoft Corporation'
        InstallTimeoutMinutes = 20
    }

    # Marker file that Phase 7 orchestration writes after azcmagent connect succeeds in the guest.
    ArcMarkerFile    = 'arc-onboarded.json'

    # Bounded waits inside one scheduled-task run; longer waits continue on the next run.
    GuestBootTimeoutMinutes = 20
}
