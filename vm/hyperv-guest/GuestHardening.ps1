# Guest isolation from IMDS and the wire server, and DNS through the host (ADR 0004).
# Windows PowerShell 5.1 on the Hyper-V host. Dot-sourced by vm/bootstrap/Invoke-HostBootstrap.ps1.

$script:DemoGuestHardeningBlock = {
    # Runs inside the guest over PowerShell Direct. With -Apply it converges; it always returns the state.
    param($Address, $PrefixLength, $Gateway, $DnsServers, $Blocked, $RulePrefix, $Apply)

    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object -Property ifIndex | Select-Object -First 1
    if ($Apply -and $adapter) {
        $current = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        if (-not ($current | Where-Object { $_.IPAddress -eq $Address })) {
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
            $current | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Address -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
        }
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DnsServers
        foreach ($blockedAddress in $Blocked) {
            $ruleName = $RulePrefix + $blockedAddress
            if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name $ruleName -DisplayName ('DbHubDemo: block {0} (ADR 0004)' -f $blockedAddress) -Direction Outbound -RemoteAddress $blockedAddress -Action Block -Profile Any -Enabled True | Out-Null
            }
        }
        foreach ($file in @('C:\Windows\Panther\unattend.xml', 'C:\Windows\Panther\Unattend\unattend.xml', 'C:\Windows\System32\Sysprep\unattend.xml')) {
            if (Test-Path -LiteralPath $file) {
                Remove-Item -LiteralPath $file -Force
            }
        }
    }

    $rules = @(foreach ($blockedAddress in $Blocked) {
            $rule = Get-NetFirewallRule -Name ($RulePrefix + $blockedAddress) -ErrorAction SilentlyContinue
            if ($rule -and [string]$rule.Enabled -eq 'True' -and [string]$rule.Direction -eq 'Outbound' -and [string]$rule.Action -eq 'Block') {
                $blockedAddress
            }
        })
    $addresses = @()
    $dns = @()
    if ($adapter) {
        $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
        $dns = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses)
    }
    [pscustomobject]@{
        ComputerName    = $env:COMPUTERNAME
        Addresses       = $addresses
        DnsServers      = $dns
        BlockedByRule   = $rules
        UnattendPresent = (Test-Path -LiteralPath 'C:\Windows\Panther\unattend.xml')
    }
}

function Get-DemoGuestHardeningState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Guest,

        [switch] $Apply
    )

    $arguments = @($Guest.IPAddress, [int]$Guest.PrefixLength, $Guest.Gateway, @($Guest.DnsServers), @($Guest.BlockedAddresses), $Guest.FirewallRulePrefix, [bool]$Apply)
    return (Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock $script:DemoGuestHardeningBlock -ArgumentList $arguments -ErrorAction Stop)
}

function Test-DemoHostPortAcl {
    # Host-enforced Hyper-V port ACLs deny each blocked address in both directions (ADR 0004).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string[]] $Address
    )

    $acls = @(Get-VMNetworkAdapterAcl -VMName $Name -ErrorAction SilentlyContinue)
    foreach ($blockedAddress in $Address) {
        foreach ($direction in @('Inbound', 'Outbound')) {
            $match = $acls | Where-Object { [string]$_.Action -eq 'Deny' -and [string]$_.Direction -eq $direction -and [string]$_.RemoteAddress -like ($blockedAddress + '*') }
            if (-not $match) {
                return $false
            }
        }
    }
    return $true
}

function Test-DemoGuestHardening {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Guest
    )

    if (-not (Test-DemoHostPortAcl -Name $Name -Address @($Guest.BlockedAddresses))) {
        return $false
    }
    $state = Get-DemoGuestHardeningState -Name $Name -Credential $Credential -Guest $Guest
    $dnsMatches = (@($state.DnsServers) -join ',') -eq (@($Guest.DnsServers) -join ',')
    $rulesComplete = @($state.BlockedByRule).Count -eq @($Guest.BlockedAddresses).Count
    return ([string]$state.ComputerName -eq [string]$Guest.Name -and @($state.Addresses) -contains $Guest.IPAddress -and $dnsMatches -and $rulesComplete -and -not $state.UnattendPresent)
}

function Invoke-DemoGuestHardening {
    <#
    .SYNOPSIS
    Applies the guest firewall blocks, static address, DNS through the host, and unattend cleanup inside
    the guest, plus host-enforced port ACLs that a guest administrator can't remove (ADR 0004).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Guest
    )

    foreach ($blockedAddress in @($Guest.BlockedAddresses)) {
        if (-not (Test-DemoHostPortAcl -Name $Name -Address @($blockedAddress))) {
            Add-VMNetworkAdapterAcl -VMName $Name -RemoteIPAddress $blockedAddress -Direction Both -Action Deny
        }
    }
    $state = Get-DemoGuestHardeningState -Name $Name -Credential $Credential -Guest $Guest -Apply
    if ([string]$state.ComputerName -ne [string]$Guest.Name) {
        Invoke-Command -VMName $Name -Credential $Credential -ArgumentList $Guest.Name -ScriptBlock {
            param($NewName)
            Rename-Computer -NewName $NewName -Force
            Restart-Computer -Force
        } -ErrorAction Stop
        Write-DemoVmLog -Message ('Renamed the guest to {0}; it restarts.' -f $Guest.Name)
        Start-Sleep -Seconds 30
        if (-not (Wait-DemoGuestOnline -Name $Name -Credential $Credential -TimeoutMinutes 10)) {
            return (New-DemoVmStepResult -Outcome 'InProgress' -Message 'The guest is restarting after the rename.')
        }
    }
}
