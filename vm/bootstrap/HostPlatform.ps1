# Host-level helpers for Invoke-HostBootstrap.ps1 (ADR 0003, ADR 0004). Windows PowerShell 5.1.

function Test-DemoNestedVirtualization {
    <#
    .SYNOPSIS
    True when this VM can run Hyper-V guests.

    .DESCRIPTION
    Before Hyper-V is installed, the processor must expose virtualization extensions to this VM. Once the
    hypervisor runs, Windows hides those flags, so an installed and running Hyper-V service counts instead.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $feature = Get-WindowsFeature -Name 'Hyper-V'
    if ($feature -and $feature.InstallState -eq 'Installed') {
        $service = Get-Service -Name 'vmms' -ErrorAction SilentlyContinue
        return ($null -ne $service)
    }
    $processor = @(Get-CimInstance -ClassName Win32_Processor)[0]
    return ([bool]$processor.VirtualizationFirmwareEnabled -and [bool]$processor.VMMonitorModeExtensions -and [bool]$processor.SecondLevelAddressTranslationExtensions)
}

function Get-DemoHostInstanceInfo {
    # Size and security type from the host's own IMDS endpoint (the guest can't reach it, ADR 0004).
    [CmdletBinding()]
    param()

    try {
        $compute = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' -Headers @{ Metadata = 'true' } -TimeoutSec 5 -UseBasicParsing
        $secureBoot = $null
        if ($compute.PSObject.Properties['securityProfile']) {
            $secureBoot = $compute.securityProfile.secureBootEnabled
        }
        return [ordered]@{ vmSize = [string]$compute.vmSize; zone = [string]$compute.zone; secureBootEnabled = [string]$secureBoot }
    }
    catch {
        return [ordered]@{ vmSize = 'unknown'; zone = ''; secureBootEnabled = 'unknown' }
    }
}

function Get-DemoNestedVirtualizationFailure {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $info = Get-DemoHostInstanceInfo
    return ('Nested virtualization is not available on this VM (size {0}, Secure Boot {1}). Use a Dsv5, Dasv5, Dsv6, Esv5, or Esv6 size with securityType Standard (ADR 0003), or opt in to the labeled evaluation-only fallback, t2Mode = EvaluationOnlyAzureVm (ADR 0006).' -f $info.vmSize, $info.secureBootEnabled)
}

function Confirm-DemoNestedVirtualization {
    <#
    .SYNOPSIS
    Decides nested-virtualization support by installing the Hyper-V role when the processor flags don't show it.

    .DESCRIPTION
    The Win32_Processor flags inside an Azure VM are only a fast path. The deciding signal is the Hyper-V
    role install: on a VM without nested virtualization, its prerequisite check fails with "The processor
    does not have required virtualization capabilities". That error is a final Failed result that points to
    the evaluation-only fallback; any other error is retried. A successful install asks for a restart, and
    the step is checked again after it.
    #>
    [CmdletBinding()]
    param()

    try {
        return (Install-DemoHostFeature -Name 'Hyper-V')
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -match 'virtualization capabilit|processor does not') {
            return (New-DemoVmStepResult -Outcome 'Failed' -Message ('{0} Hyper-V setup reported: {1}' -f (Get-DemoNestedVirtualizationFailure), $message))
        }
        throw
    }
}

function Test-DemoHostFeature {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $feature = Get-WindowsFeature -Name $Name
    return ($null -ne $feature -and $feature.InstallState -eq 'Installed')
}

function Install-DemoHostFeature {
    # Returns a RebootRequired step result when Windows asks for a restart.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $result = Install-WindowsFeature -Name $Name -IncludeManagementTools
    if (-not $result.Success) {
        throw ('Install-WindowsFeature {0} failed with exit code {1}.' -f $Name, $result.ExitCode)
    }
    if ([string]$result.RestartNeeded -eq 'Yes' -or (Get-WindowsFeature -Name $Name).InstallState -eq 'InstallPending') {
        return (New-DemoVmStepResult -Outcome 'RebootRequired' -Message ('{0} is installed and needs a restart.' -f $Name))
    }
}

function Test-DemoHostNatNetwork {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $HostConfig
    )

    $switch = Get-VMSwitch -Name $HostConfig.SwitchName -ErrorAction SilentlyContinue
    if (-not $switch -or [string]$switch.SwitchType -ne 'Internal') {
        return $false
    }
    $address = Get-NetIPAddress -IPAddress $HostConfig.HostAddress -ErrorAction SilentlyContinue
    if (-not $address -or [int]$address.PrefixLength -ne [int]$HostConfig.PrefixLength -or [string]$address.AddressState -ne 'Preferred') {
        return $false
    }
    $nat = Get-NetNat -Name $HostConfig.NatName -ErrorAction SilentlyContinue
    return ($null -ne $nat -and $nat.InternalIPInterfaceAddressPrefix -eq $HostConfig.NatPrefix)
}

function Wait-DemoHostAddressReady {
    <#
    .SYNOPSIS
    Waits until a host address can take sockets (AddressState Preferred). True when it did within -TimeoutSeconds.

    .DESCRIPTION
    A new address stays Tentative for a few seconds while Windows checks it for duplicates, and nothing can bind
    to it until then (Get-NetIPAddress, AddressState). Live finding, 2026-10-21: the DNS Server restarted on
    192.168.200.1 two seconds after the NatNetwork step added it, couldn't bind it (DNS Server events 404, 407,
    and 408), and answered no query from the guest until the host restarted, so Arc onboarding failed with
    'lookup management.azure.com: no such host'.
    https://learn.microsoft.com/powershell/module/nettcpip/get-netipaddress
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $IPAddress,

        [ValidateRange(2, 600)]
        [int] $TimeoutSeconds = 120
    )

    $checks = [int][math]::Ceiling($TimeoutSeconds / 2)
    for ($check = 1; $check -le $checks; $check++) {
        $address = @(Get-NetIPAddress -IPAddress $IPAddress -ErrorAction SilentlyContinue)
        if ($address.Count -gt 0 -and [string]$address[0].AddressState -eq 'Preferred') {
            return $true
        }
        if ($check -lt $checks) {
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Test-DemoHostDnsListener {
    <#
    .SYNOPSIS
    True when the DNS Server has bound UDP and TCP port 53 on -IPAddress, not just been configured to.
    https://learn.microsoft.com/powershell/module/nettcpip/get-netudpendpoint
    https://learn.microsoft.com/powershell/module/nettcpip/get-nettcpconnection
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $IPAddress
    )

    $udp = @(Get-NetUDPEndpoint -LocalAddress $IPAddress -LocalPort 53 -ErrorAction SilentlyContinue)
    $tcp = @(Get-NetTCPConnection -LocalAddress $IPAddress -LocalPort 53 -State Listen -ErrorAction SilentlyContinue)
    return ($udp.Count -gt 0 -and $tcp.Count -gt 0)
}

function Initialize-DemoHostNatNetwork {
    <#
    .SYNOPSIS
    Internal switch, gateway address, and NAT for the guest ("Set up a NAT network", Hyper-V docs).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $HostConfig
    )

    if (-not (Get-VMSwitch -Name $HostConfig.SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -SwitchName $HostConfig.SwitchName -SwitchType Internal | Out-Null
    }
    $adapter = Get-NetAdapter | Where-Object { $_.Name -eq ('vEthernet ({0})' -f $HostConfig.SwitchName) } | Select-Object -First 1
    if (-not $adapter) {
        throw ('The host adapter for switch {0} was not found.' -f $HostConfig.SwitchName)
    }
    if (-not (Get-NetIPAddress -IPAddress $HostConfig.HostAddress -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -IPAddress $HostConfig.HostAddress -PrefixLength $HostConfig.PrefixLength -InterfaceIndex $adapter.ifIndex | Out-Null
    }
    $nat = Get-NetNat -Name $HostConfig.NatName -ErrorAction SilentlyContinue
    if ($nat -and $nat.InternalIPInterfaceAddressPrefix -ne $HostConfig.NatPrefix) {
        Remove-NetNat -Name $HostConfig.NatName -Confirm:$false
        $nat = $null
    }
    if (-not $nat) {
        New-NetNat -Name $HostConfig.NatName -InternalIPInterfaceAddressPrefix $HostConfig.NatPrefix | Out-Null
    }
    if (-not (Wait-DemoHostAddressReady -IPAddress $HostConfig.HostAddress)) {
        throw ('The gateway address {0} on vEthernet ({1}) did not become usable (AddressState Preferred) within 120 seconds.' -f $HostConfig.HostAddress, $HostConfig.SwitchName)
    }
}

function Test-DemoHostDnsForwarder {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $HostConfig
    )

    $service = Get-Service -Name 'DNS' -ErrorAction SilentlyContinue
    if (-not $service -or [string]$service.Status -ne 'Running') {
        return $false
    }
    $forwarder = Get-DnsServerForwarder
    $forwarders = @($forwarder.IPAddress | ForEach-Object { [string]$_ })
    if (($forwarders -join ',') -ne (@($HostConfig.DnsForwarders) -join ',') -or $forwarder.UseRootHint) {
        return $false
    }
    $listening = @((Get-DnsServerSetting -All).ListeningIPAddress | ForEach-Object { [string]$_ })
    if ($listening.Count -ne 1 -or $listening[0] -ne $HostConfig.DnsListenAddress) {
        return $false
    }
    # The setting alone isn't proof: the server must have bound the address (Wait-DemoHostAddressReady).
    return (Test-DemoHostDnsListener -IPAddress $HostConfig.DnsListenAddress)
}

function Initialize-DemoHostDnsForwarder {
    <#
    .SYNOPSIS
    The DNS Server listens only on the NAT gateway address and forwards to Azure-provided DNS (ADR 0004).

    .DESCRIPTION
    The DNS Server binds its listening address when it starts (or when the address appears) and doesn't try
    again after a failure, so the restart waits until the address is usable, and the sockets are confirmed
    afterwards: up to three restarts, then the step fails instead of converging without a listener.
    https://learn.microsoft.com/powershell/module/dnsserver/set-dnsserversetting
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $HostConfig
    )

    Set-Service -Name 'DNS' -StartupType Automatic
    Start-Service -Name 'DNS'
    Set-DnsServerForwarder -IPAddress @($HostConfig.DnsForwarders) -UseRootHint $false | Out-Null
    $settings = Get-DnsServerSetting -All
    $settings.ListeningIPAddress = @($HostConfig.DnsListenAddress)
    Set-DnsServerSetting -InputObject $settings | Out-Null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (-not (Wait-DemoHostAddressReady -IPAddress $HostConfig.DnsListenAddress)) {
            throw ('The DNS listening address {0} is not usable (AddressState is not Preferred), so the DNS Server cannot bind it.' -f $HostConfig.DnsListenAddress)
        }
        Restart-Service -Name 'DNS'
        for ($check = 1; $check -le 5; $check++) {
            if (Test-DemoHostDnsListener -IPAddress $HostConfig.DnsListenAddress) {
                return
            }
            Start-Sleep -Seconds 2
        }
        Write-DemoVmLog -Level 'Warning' -Message ('The DNS Server did not bind {0}:53 after restart {1} of 3.' -f $HostConfig.DnsListenAddress, $attempt)
    }
    throw ('The DNS Server did not bind UDP and TCP port 53 on {0} after 3 restarts; DNS Server events 404, 407, and 408 name the cause.' -f $HostConfig.DnsListenAddress)
}

function Test-DemoArcOnboarded {
    <#
    .SYNOPSIS
    True when the orchestrator's marker says the guest is Arc-connected.

    .DESCRIPTION
    Contract with Phase 7: after azcmagent connect succeeds in the guest, the orchestrator writes
    C:\ProgramData\DbHubDemo\arc-onboarded.json on the host with at least
    { "schemaVersion": 1, "machineName": "arcsql01", "status": "Connected", "resourceId": "...", "connectedUtc": "..." }.
    Phase 7 adds "guestVmId", the Hyper-V VM ID of the guest it onboarded. With -GuestVmId, a marker for
    another guest (the guest was rebuilt, so it has a new VM ID) doesn't count, and the host waits in
    WaitingForArcOnboarding again; configure-arc.ps1 then removes the stale Arc machine before onboarding.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MarkerPath,

        [Parameter(Mandatory = $true)]
        [string] $MachineName,

        [AllowEmptyString()]
        [string] $GuestVmId = ''
    )

    try {
        $marker = Read-DemoVmJsonFile -Path $MarkerPath
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The Arc marker {0} is not valid JSON.' -f $MarkerPath)
        return $false
    }
    if ($null -eq $marker) {
        return $false
    }
    if ([string]$marker['status'] -ne 'Connected' -or [string]$marker['machineName'] -ne $MachineName) {
        return $false
    }
    $markerGuestVmId = ''
    if ($marker.Contains('guestVmId')) {
        $markerGuestVmId = [string]$marker['guestVmId']
    }
    if ($GuestVmId -and $markerGuestVmId -and $markerGuestVmId -ne $GuestVmId) {
        Write-DemoVmLog -Level 'Warning' -Message ('The Arc marker belongs to an earlier build of {0} (VM ID {1}, now {2}); waiting for onboarding again.' -f $MachineName, $markerGuestVmId, $GuestVmId)
        return $false
    }
    return $true
}

function Get-DemoHostGuestVmId {
    <#
    .SYNOPSIS
    The guest's Hyper-V VM ID, which changes when the guest is rebuilt, or an empty string. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    try {
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if ($vm) {
            return [string]$vm.VMId
        }
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The VM ID of {0} could not be read: {1}' -f $Name, $_.Exception.Message)
    }
    return ''
}

function Get-DemoProtectedSqlProductKey {
    <#
    .SYNOPSIS
    Phase 7 hook: returns the SQL Server product key (prerequisite P10) as a SecureString, or $null.

    .DESCRIPTION
    The key comes only from protected input: the orchestrator runs vm/bootstrap/Set-DemoSqlProductKey.ps1
    in a managed Run Command whose protectedParameters carry the key. That script stores it with DPAPI
    (LocalMachine) in C:\ProgramData\DbHubDemo\protected\sql-product-key.bin, readable only by SYSTEM and
    Administrators. The install step deletes it after setup succeeds (ADR 0006, ADR 0009).
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $plain = Unprotect-DemoVmSecret -Path $Path
    $secure = New-Object -TypeName 'System.Security.SecureString'
    foreach ($character in $plain.ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    return $secure
}

function Get-DemoPaygWizardInstruction {
    <#
    .SYNOPSIS
    The exact steps of the PaygWizard guided stop (ADR 0006, Phase 28, docs/deployment.md). deploy.ps1 brings the person
    here: Bastion is ready, the guest has signed itself in once, and SQL Server setup waits pre-filled.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $GuestName,

        [string] $MediaDrive = ''
    )

    $setupPath = 'C:\DbHubDemo\setup\Start-GuidedSetup.ps1 (it opens setup pre-filled)'
    if ($MediaDrive) {
        $setupPath = '{0}:\setup.exe (the SQL Server media is mounted), or C:\DbHubDemo\setup\Start-GuidedSetup.ps1 to open it pre-filled' -f $MediaDrive
    }
    return @(
        'Run ./scripts/deploy.ps1 on your PC: it creates Bastion, opens it in your browser, and tells you when this step is ready (it continues where it stopped).'
        'In the Azure portal, connect to archost01 with Bastion (Connect > Bastion), with the user name and password the deploy gives you, or with a password you set under Help > Reset password.'
        ('A Virtual Machine Connection window to {0} opens on its own: the guest has signed itself in once and opened SQL Server setup, pre-filled.' -f $GuestName)
        'On the Edition page, select Use pay-as-you-go billing through Microsoft Azure, then Standard. Accept the license terms.'
        'On the Azure Extension for SQL Server page, select Use Azure Login and sign in with your own Azure account. Pay-as-you-go needs this page, and the subscription, resource group, and region are locked to the existing Arc connection. Never enter a service principal secret. The sign-in window is an Internet Explorer-based control, so the host turns IE Enhanced Security Configuration off for administrators before setup opens, and back on afterward. If Internet Explorer still says content from a site is blocked by Enhanced Security Configuration, select Add... for each site it names, then Use Azure Login again. If the window stays blank, close setup, turn IE Enhanced Security Configuration off for Administrators (Server Manager > Local Server), and open setup again with C:\DbHubDemo\setup\Start-GuidedSetup.ps1: a change made while setup is open doesn''t reach it.'
        'Select Next on the pre-filled pages (Database Engine Services and Azure Extension for SQL Server, the default instance MSSQLSERVER, the service accounts, and BUILTIN\Administrators as administrators), then Install.'
        'When setup says Complete, select Close. Within a few minutes the host checks the edition and the instance, signs the guest out, rotates its password, removes the sign-in data that setup leaves in the guest, checks that none remains, and continues on its own.'
        ('If the window shows a sign-in screen instead: in an elevated PowerShell on archost01, run C:\ProgramData\DbHubDemo\Copy-GuestCredential.ps1 (it never displays the password), use Clipboard > Type clipboard text to sign in to {0} as Administrator, and run {1}.' -f $GuestName, $setupPath)
    )
}
