# Guest VM creation, credentials, and PowerShell Direct reachability (ADR 0003, ADR 0009).
# Windows PowerShell 5.1 on the Hyper-V host. Dot-sourced by vm/bootstrap/Invoke-HostBootstrap.ps1.

function Initialize-DemoGuestSecret {
    <#
    .SYNOPSIS
    Generates the guest administrator password once and keeps it on the host with DPAPI (LocalMachine).
    It never leaves the host and is never logged (ADR 0009).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SecretPath
    )

    if (Test-Path -LiteralPath $SecretPath -PathType Leaf) {
        return
    }
    $value = Build-DemoVmPassword -Length 24
    Protect-DemoVmSecret -Value $value -Path $SecretPath
    Write-DemoVmLog -Message 'Generated the guest administrator password and stored it on the host with DPAPI.'
}

function Get-DemoGuestCredential {
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SecretPath,

        [string] $UserName = 'Administrator'
    )

    $plain = Unprotect-DemoVmSecret -Path $SecretPath
    $secure = New-Object -TypeName 'System.Security.SecureString'
    foreach ($character in $plain.ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    return (New-Object -TypeName 'System.Management.Automation.PSCredential' -ArgumentList $UserName, $secure)
}

function Update-DemoGuestSecret {
    <#
    .SYNOPSIS
    Rotates the guest administrator's password the way the golden rotation does (vm/bootstrap/Invoke-DemoGoldenGuest.ps1,
    RotateGuestPassword): the new random value is stored with DPAPI as pending first, then set in the guest over
    PowerShell Direct with the current credential, proven with a new session, and only then promoted; if it can't sign
    in, the old one is set back. It's never logged or returned (ADR 0009).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SecretPath,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [string] $UserName = 'Administrator'
    )

    if (-not $PSCmdlet.ShouldProcess($Name, 'Rotate the guest administrator password')) {
        return
    }
    $pendingPath = $SecretPath + '.pending'
    $old = Get-DemoGuestCredential -SecretPath $SecretPath -UserName $UserName
    $session = New-PSSession -VMName $Name -Credential $old -ErrorAction Stop
    try {
        $value = Build-DemoVmPassword -Length 24
        Protect-DemoVmSecret -Value $value -Path $pendingPath
        $value = $null
        $new = Get-DemoGuestCredential -SecretPath $pendingPath -UserName $UserName
        $setSecret = {
            param($Account, $Secret)
            Set-LocalUser -Name $Account -Password $Secret
        }
        Invoke-Command -Session $session -ScriptBlock $setSecret -ArgumentList $UserName, $new.Password -ErrorAction Stop
        if (Test-DemoGuestOnline -Name $Name -Credential $new) {
            Move-Item -LiteralPath $pendingPath -Destination $SecretPath -Force
            Write-DemoVmLog -Message 'Rotated the guest administrator password; the new one is stored on the host with DPAPI.'
            return
        }
        Invoke-Command -Session $session -ScriptBlock $setSecret -ArgumentList $UserName, $old.Password -ErrorAction Stop
        Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
        throw 'The new guest password could not sign in, so the old one was set back.'
    }
    finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

function Test-DemoGuestVm {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [int] $VCpu,

        [Parameter(Mandatory = $true)]
        [int] $MemoryGiB
    )

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        return $false
    }
    return ([int]$vm.Generation -eq 2 -and [int]$vm.ProcessorCount -eq $VCpu -and -not $vm.DynamicMemoryEnabled -and
        [int64]$vm.MemoryStartup -eq ([int64]$MemoryGiB * 1GB) -and [string]$vm.AutomaticStartAction -eq 'Start' -and
        [string]$vm.AutomaticStopAction -eq 'ShutDown' -and [string]$vm.State -eq 'Running')
}

function Initialize-DemoGuestVm {
    <#
    .SYNOPSIS
    Creates or reconfigures the Generation 2 guest: static memory, automatic start, ShutDown stop action
    (so host auto-shutdown and deallocation shut the guest down cleanly), Secure Boot, no checkpoints.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $VhdxPath,

        [Parameter(Mandatory = $true)]
        [string] $VmFolder,

        [Parameter(Mandatory = $true)]
        [string] $SwitchName,

        [Parameter(Mandatory = $true)]
        [int] $VCpu,

        [Parameter(Mandatory = $true)]
        [int] $MemoryGiB
    )

    $memory = [int64]$MemoryGiB * 1GB
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        New-VM -Name $Name -Generation 2 -MemoryStartupBytes $memory -VHDPath $VhdxPath -SwitchName $SwitchName -Path $VmFolder | Out-Null
        Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
        Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface'
        Write-DemoVmLog -Message ('Created the guest VM {0}.' -f $Name)
    }
    elseif ([int]$vm.ProcessorCount -ne $VCpu -or [int64]$vm.MemoryStartup -ne $memory -or $vm.DynamicMemoryEnabled) {
        if ([string]$vm.State -ne 'Off') {
            Stop-VM -Name $Name -Force
        }
    }
    if ([string](Get-VM -Name $Name).State -eq 'Off') {
        Set-VM -Name $Name -ProcessorCount $VCpu -StaticMemory -MemoryStartupBytes $memory -CheckpointType Disabled
    }
    Set-VM -Name $Name -AutomaticStartAction Start -AutomaticStartDelay 0 -AutomaticStopAction ShutDown
    if ([string](Get-VM -Name $Name).State -ne 'Running') {
        Start-VM -Name $Name
    }
}

function Test-DemoGuestOnline {
    # One PowerShell Direct probe; PowerShell Direct uses VMBus, not the network.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential
    )

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm -or [string]$vm.State -ne 'Running') {
        return $false
    }
    try {
        $value = Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
        return (-not [string]::IsNullOrEmpty([string]$value))
    }
    catch {
        return $false
    }
}

function Wait-DemoGuestOnline {
    # Bounded wait inside one task run; the next run continues if the guest is still in OOBE.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [ValidateRange(1, 120)]
        [int] $TimeoutMinutes = 20
    )

    if ([string](Get-VM -Name $Name).State -ne 'Running') {
        Start-VM -Name $Name
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-DemoGuestOnline -Name $Name -Credential $Credential) {
            return $true
        }
        Start-Sleep -Seconds 20
    }
    return $false
}
