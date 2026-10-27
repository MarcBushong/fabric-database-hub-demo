BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the host bootstrap's functions (and imports DbHubDemo.Vm) without running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1')
    $script:hostConfig = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/dsc/host.psd1')
    $script:listenAddress = [string]$script:hostConfig.DnsListenAddress

    # The Hyper-V, NAT, DNS Server, TCP/IP, and service cmdlets exist only on Windows (the DNS Server ones only
    # with the role), so stubs with the parameters the host code uses are defined before they're mocked.
    $stubs = @{
        'Get-NetIPAddress'       = 'param([string] $IPAddress)'
        'New-NetIPAddress'       = 'param([string] $IPAddress, [int] $PrefixLength, [int] $InterfaceIndex)'
        'Get-NetUDPEndpoint'     = 'param([string] $LocalAddress, [int] $LocalPort)'
        'Get-NetTCPConnection'   = 'param([string] $LocalAddress, [int] $LocalPort, [string] $State)'
        'Get-NetAdapter'         = 'param()'
        'Get-NetNat'             = 'param([string] $Name)'
        'New-NetNat'             = 'param([string] $Name, [string] $InternalIPInterfaceAddressPrefix)'
        'Remove-NetNat'          = 'param([string] $Name)'
        'Get-VMSwitch'           = 'param([string] $Name)'
        'New-VMSwitch'           = 'param([string] $SwitchName, [string] $SwitchType)'
        'Get-Service'            = 'param([string] $Name)'
        'Set-Service'            = 'param([string] $Name, [string] $StartupType)'
        'Start-Service'          = 'param([string] $Name)'
        'Restart-Service'        = 'param([string] $Name)'
        'Get-DnsServerForwarder' = 'param()'
        'Set-DnsServerForwarder' = 'param([string[]] $IPAddress, [bool] $UseRootHint)'
        'Get-DnsServerSetting'   = 'param([switch] $All)'
        'Set-DnsServerSetting'   = 'param([object] $InputObject)'
    }
    $script:createdStubs = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            New-Item -Path ('function:global:' + $name) -Value ([scriptblock]::Create('[CmdletBinding()] ' + $stubs[$name])) | Out-Null
            $script:createdStubs.Add($name)
        }
    }

    function New-TestAddress([string] $State) {
        [pscustomobject]@{ IPAddress = $script:listenAddress; PrefixLength = 24; AddressState = $State }
    }

    function Set-HostDnsMock {
        # A configured DNS Server: the address states and socket bindings are set per test.
        param(
            [string[]] $AddressStates = @('Preferred'),
            [int] $BoundAfterRestart = 1
        )
        $script:addressStates = [System.Collections.Generic.Queue[string]]::new([string[]]$AddressStates)
        $script:lastAddressState = $AddressStates[-1]
        $script:addressChecks = 0
        $script:restarts = 0
        $script:checksBeforeRestart = [System.Collections.Generic.List[int]]::new()
        $script:boundAfterRestart = $BoundAfterRestart
        Mock -CommandName Get-NetIPAddress -MockWith {
            $script:addressChecks++
            $state = if ($script:addressStates.Count -gt 0) { $script:addressStates.Dequeue() } else { $script:lastAddressState }
            if ($state -eq 'Missing') {
                return
            }
            New-TestAddress -State $state
        }
        Mock -CommandName Restart-Service -MockWith {
            $script:restarts++
            $script:checksBeforeRestart.Add($script:addressChecks)
        }
        Mock -CommandName Get-NetUDPEndpoint -MockWith {
            if ($script:boundAfterRestart -gt 0 -and $script:restarts -ge $script:boundAfterRestart) {
                [pscustomobject]@{ LocalAddress = $script:listenAddress; LocalPort = 53 }
            }
        }
        Mock -CommandName Get-NetTCPConnection -MockWith {
            if ($script:boundAfterRestart -gt 0 -and $script:restarts -ge $script:boundAfterRestart) {
                [pscustomobject]@{ LocalAddress = $script:listenAddress; LocalPort = 53; State = 'Listen' }
            }
        }
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Name = 'DNS'; Status = 'Running' } }
        Mock -CommandName Set-Service -MockWith { }
        Mock -CommandName Start-Service -MockWith { }
        Mock -CommandName Get-DnsServerForwarder -MockWith { [pscustomobject]@{ IPAddress = @($script:hostConfig.DnsForwarders); UseRootHint = $false } }
        Mock -CommandName Set-DnsServerForwarder -MockWith { }
        Mock -CommandName Get-DnsServerSetting -MockWith { [pscustomobject]@{ ListeningIPAddress = @($script:listenAddress) } }
        Mock -CommandName Set-DnsServerSetting -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-DemoVmLog -MockWith { }
    }
}

AfterAll {
    foreach ($name in $script:createdStubs) {
        Remove-Item -Path ('function:global:' + $name) -ErrorAction SilentlyContinue
    }
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'T2 host DNS forwarder binds the NAT gateway address (live finding, 2026-10-21)' {
    Context 'Wait-DemoHostAddressReady' {
        It 'returns once a new address leaves the Tentative state' {
            Set-HostDnsMock -AddressStates 'Tentative', 'Tentative', 'Preferred'
            Wait-DemoHostAddressReady -IPAddress $script:listenAddress | Should -BeTrue
            $script:addressChecks | Should -Be 3
            Should -Invoke -CommandName Start-Sleep -Times 2 -Exactly
        }

        It 'gives up when the address stays <State>' -ForEach @(
            @{ State = 'Tentative' }
            @{ State = 'Duplicate' }
            @{ State = 'Missing' }
        ) {
            Set-HostDnsMock -AddressStates $State
            Wait-DemoHostAddressReady -IPAddress $script:listenAddress -TimeoutSeconds 10 | Should -BeFalse
            $script:addressChecks | Should -Be 5
        }
    }

    Context 'Test-DemoHostDnsListener' {
        It 'needs both the UDP and the TCP socket on port 53 (UDP <Udp>, TCP <Tcp>)' -ForEach @(
            @{ Udp = $true; Tcp = $true; Expected = $true }
            @{ Udp = $true; Tcp = $false; Expected = $false }
            @{ Udp = $false; Tcp = $true; Expected = $false }
            @{ Udp = $false; Tcp = $false; Expected = $false }
        ) {
            $script:udpBound = $Udp
            $script:tcpBound = $Tcp
            Mock -CommandName Get-NetUDPEndpoint -MockWith { if ($script:udpBound) { [pscustomobject]@{ LocalPort = 53 } } }
            Mock -CommandName Get-NetTCPConnection -MockWith { if ($script:tcpBound) { [pscustomobject]@{ LocalPort = 53 } } }
            Test-DemoHostDnsListener -IPAddress $script:listenAddress | Should -Be $Expected
            Should -Invoke -CommandName Get-NetUDPEndpoint -Times 1 -Exactly -ParameterFilter { $LocalAddress -eq $script:listenAddress -and $LocalPort -eq 53 }
        }
    }

    Context 'Test-DemoHostDnsForwarder' {
        It 'fails when the DNS Server is configured for the address but has no socket on it' {
            Set-HostDnsMock -BoundAfterRestart 0
            Test-DemoHostDnsForwarder -HostConfig $script:hostConfig | Should -BeFalse
        }

        It 'passes when the DNS Server is configured and listening' {
            Set-HostDnsMock -BoundAfterRestart 0
            Mock -CommandName Get-NetUDPEndpoint -MockWith { [pscustomobject]@{ LocalPort = 53 } }
            Mock -CommandName Get-NetTCPConnection -MockWith { [pscustomobject]@{ LocalPort = 53 } }
            Test-DemoHostDnsForwarder -HostConfig $script:hostConfig | Should -BeTrue
        }
    }

    Context 'Initialize-DemoHostDnsForwarder' {
        It 'restarts the DNS Server only after the address is usable, and confirms the sockets' {
            Set-HostDnsMock -AddressStates 'Tentative', 'Tentative', 'Preferred'
            Initialize-DemoHostDnsForwarder -HostConfig $script:hostConfig
            $script:restarts | Should -Be 1
            $script:checksBeforeRestart[0] | Should -Be 3
            Should -Invoke -CommandName Set-DnsServerForwarder -Times 1 -Exactly -ParameterFilter { $UseRootHint -eq $false }
            Should -Invoke -CommandName Write-DemoVmLog -Times 0
        }

        It 'restarts again when a restart leaves no listener' {
            Set-HostDnsMock -BoundAfterRestart 2
            Initialize-DemoHostDnsForwarder -HostConfig $script:hostConfig
            $script:restarts | Should -Be 2
            Should -Invoke -CommandName Write-DemoVmLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'restart 1 of 3' }
        }

        It 'fails instead of converging without a listener' {
            Set-HostDnsMock -BoundAfterRestart 0
            { Initialize-DemoHostDnsForwarder -HostConfig $script:hostConfig } | Should -Throw -ExpectedMessage '*did not bind UDP and TCP port 53*after 3 restarts*'
            $script:restarts | Should -Be 3
        }

        It 'fails without a restart when the address never becomes usable' {
            Set-HostDnsMock -AddressStates 'Tentative'
            { Initialize-DemoHostDnsForwarder -HostConfig $script:hostConfig } | Should -Throw -ExpectedMessage '*is not usable*'
            $script:restarts | Should -Be 0
        }
    }

    Context 'NAT network' {
        BeforeEach {
            Mock -CommandName Get-VMSwitch -MockWith { [pscustomobject]@{ Name = $script:hostConfig.SwitchName; SwitchType = 'Internal' } }
            Mock -CommandName New-VMSwitch -MockWith { }
            Mock -CommandName Get-NetAdapter -MockWith { [pscustomobject]@{ Name = ('vEthernet ({0})' -f $script:hostConfig.SwitchName); ifIndex = 12 } }
            Mock -CommandName New-NetIPAddress -MockWith { }
            Mock -CommandName Get-NetNat -MockWith { [pscustomobject]@{ Name = $script:hostConfig.NatName; InternalIPInterfaceAddressPrefix = $script:hostConfig.NatPrefix } }
            Mock -CommandName New-NetNat -MockWith { }
            Mock -CommandName Remove-NetNat -MockWith { }
        }

        It 'reports a Tentative gateway address as not ready' {
            Set-HostDnsMock -AddressStates 'Tentative'
            Test-DemoHostNatNetwork -HostConfig $script:hostConfig | Should -BeFalse
        }

        It 'reports a Preferred gateway address as ready' {
            Set-HostDnsMock -AddressStates 'Preferred'
            Test-DemoHostNatNetwork -HostConfig $script:hostConfig | Should -BeTrue
        }

        It 'waits until the new gateway address is usable before the step converges' {
            Set-HostDnsMock -AddressStates 'Missing', 'Tentative', 'Preferred'
            Initialize-DemoHostNatNetwork -HostConfig $script:hostConfig
            Should -Invoke -CommandName New-NetIPAddress -Times 1 -Exactly
            $script:addressChecks | Should -Be 3
        }

        It 'fails when the gateway address stays Tentative' {
            Set-HostDnsMock -AddressStates 'Tentative'
            { Initialize-DemoHostNatNetwork -HostConfig $script:hostConfig } | Should -Throw -ExpectedMessage '*did not become usable*'
        }
    }
}
