# The PaygWizard guided stop inside the T2 guest (ADR 0006, ADR 0009, Phase 28). Windows PowerShell 5.1 on the Hyper-V
# host; every in-guest action runs over PowerShell Direct. Dot-sourced by vm/bootstrap/Invoke-HostBootstrap.ps1.
#
# What it automates, with documented mechanisms only, so the person at the guided stop only chooses pay-as-you-go and
# Standard, signs in to Azure on setup's Azure page, and selects Install:
# - SQL Server setup pre-filled from a configuration file (/ConfigurationFile, UIMODE Normal), which holds no secret:
#   https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-using-a-configuration-file and
#   https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt
# - A logon task in the guest that starts it, and a logon task on the host that opens Virtual Machine Connection to the
#   guest: https://learn.microsoft.com/powershell/module/scheduledtasks/new-scheduledtasktrigger and
#   https://learn.microsoft.com/windows-server/virtualization/hyper-v/virtual-machine-connection
# - The guest signs itself in once for the step: Windows automatic logon with AutoLogonCount 1, and a temporary password
#   kept only as the LSA DefaultPassword secret (LsaStorePrivateData), never as the Winlogon DefaultPassword value:
#   https://learn.microsoft.com/windows/win32/secauthn/protecting-the-automatic-logon-password,
#   https://learn.microsoft.com/windows/win32/secauthn/msgina-dll-features, and
#   https://learn.microsoft.com/sysinternals/downloads/autologon
# The automatic sign-in is armed only while deploy.ps1 waits for a person (a request it writes on the host, with an
# expiry), and its cleanup always runs: when setup has installed the right instance, when the request expires or goes,
# and before the next arm. The cleanup turns automatic sign-in off, deletes the LSA secret and the Winlogon
# DefaultUserName and DefaultPassword values, rotates the guest administrator's password, and signs the console out;
# GuestSignInCleanup then runs as before.

function Get-DemoGuidedSetupPath {
    # Where the guided setup's files live: in the guest, and in the host's state folder.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $guestFolder = 'C:\DbHubDemo\setup'
    return [pscustomobject]@{
        GuestFolder        = $guestFolder
        GuestConfiguration = $guestFolder + '\ConfigurationFile.ini'
        GuestLauncher      = $guestFolder + '\Start-GuidedSetup.ps1'
        GuestStatus        = $guestFolder + '\guided-setup-status.json'
        GuestLog           = $guestFolder + '\guided-setup.log'
        HostRequest        = Join-Path -Path $Root -ChildPath 'guided-setup-request.json'
        HostArmed          = Join-Path -Path $Root -ChildPath 'guided-setup-armed.json'
        HostLast           = Join-Path -Path $Root -ChildPath 'guided-setup-last.json'
        HostConsoleScript  = Join-Path -Path $Root -ChildPath 'Open-GuestConsole.ps1'
        HostSteps          = Join-Path -Path $Root -ChildPath 'guided-setup-steps.txt'
    }
}

function Get-DemoGuidedSetupConfigurationText {
    <#
    .SYNOPSIS
    The SQL Server setup configuration file for the guided stop: every page that documented parameters can pre-fill, and
    nothing secret. Pure, so tests read it on any operating system.

    .DESCRIPTION
    ACTION Install with UIMODE Normal shows every page with these values in place: the Database Engine and the Azure
    extension (FEATURES), the default instance, the virtual service accounts, BUILTIN\Administrators as sysadmins (the
    host connects as the guest's Administrator), TCP on, no product updates during setup, and the Azure extension's
    subscription, resource group, region, and tenant when they're given (the guest's existing Arc connection fills them
    in too). There is no /PID (pay-as-you-go without a product key is documented only on setup's Edition page), no
    service principal or secret, and no license acceptance: the person accepts the license terms in setup.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Sql,

        [System.Collections.IDictionary] $Azure = @{}
    )

    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $rules = @(
        @{ Name = 'AZURESUBSCRIPTIONID'; Key = 'SubscriptionId'; Pattern = $guid }
        @{ Name = 'AZURERESOURCEGROUP'; Key = 'ResourceGroup'; Pattern = '^[A-Za-z0-9._()-]{1,90}$' }
        @{ Name = 'AZUREREGION'; Key = 'Region'; Pattern = '^[a-z0-9]{2,40}$' }
        @{ Name = 'AZURETENANTID'; Key = 'TenantId'; Pattern = $guid }
    )
    $values = [ordered]@{
        ACTION              = 'Install'
        UIMODE              = 'Normal'
        FEATURES            = ('{0},AZUREEXTENSION' -f $Sql['Features'])
        INSTANCENAME        = [string]$Sql['InstanceName']
        INSTANCEID          = [string]$Sql['InstanceName']
        SQLSVCACCOUNT       = [string]$Sql['ServiceAccount']
        AGTSVCACCOUNT       = [string]$Sql['AgentAccount']
        AGTSVCSTARTUPTYPE   = 'Automatic'
        SQLSYSADMINACCOUNTS = [string]$Sql['SysAdminAccounts']
        TCPENABLED          = '1'
        UPDATEENABLED       = 'False'
    }
    foreach ($rule in $rules) {
        $value = ''
        if ($Azure.Contains($rule.Key)) {
            $value = [string]$Azure[$rule.Key]
        }
        if ($value -match $rule.Pattern) {
            $values[$rule.Name] = $value
        }
    }
    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $lines.Add('; Fabric Database Hub demo: SQL Server 2022 setup for the PaygWizard guided stop (Phase 28, ADR 0006).')
    $lines.Add('; Generated on the T2 host. It holds no secret. In setup you choose Use pay-as-you-go billing through Microsoft Azure')
    $lines.Add('; and Standard, accept the license terms, sign in with Use Azure Login on the Azure Extension page, and select Install.')
    $lines.Add('[OPTIONS]')
    foreach ($name in $values.Keys) {
        $value = [string]$values[$name]
        if ($value -match '["\r\n]') {
            throw ('The setup configuration value {0} contains a character the file can''t hold.' -f $name)
        }
        if ($name -eq 'FEATURES') {
            $lines.Add(('{0}={1}' -f $name, $value))
        }
        else {
            $lines.Add(('{0}="{1}"' -f $name, $value))
        }
    }
    $text = ($lines -join "`r`n") + "`r`n"
    if ($text -match '(?im)^\s*(PID|[A-Z]*PASSWORD|AZURESERVICEPRINCIPAL[A-Z]*|IACCEPTSQLSERVERLICENSETERMS)\s*=') {
        throw 'The setup configuration file must not carry a product key, a password, a service principal, or the license acceptance.'
    }
    return $text
}

function Invoke-DemoGuestAutoLogonAction {
    <#
    .SYNOPSIS
    Reads, arms, or clears Windows automatic sign-in on this machine. Self-contained: the host runs it in the guest over
    PowerShell Direct, and the guided setup launcher embeds it. Returns what it found; never a value.

    .DESCRIPTION
    Arm keeps the password only as the LSA DefaultPassword secret (LsaStorePrivateData, LSA_UNICODE_STRING from the
    SecureString's unmanaged copy, zeroed after), sets AutoAdminLogon 1, DefaultUserName, DefaultDomainName, and
    AutoLogonCount 1, and deletes a Winlogon DefaultPassword value: Windows signs in once at the next start. Clear sets
    AutoAdminLogon 0, deletes AutoLogonCount and the Winlogon DefaultPassword and DefaultUserName values, and deletes the
    LSA secret (LsaStorePrivateData with no data). Read reports each of them as present or not; the LSA secret's
    presence comes from LsaRetrievePrivateData, whose buffer is freed without being read.
    Sources: https://learn.microsoft.com/windows/win32/secauthn/protecting-the-automatic-logon-password,
    https://learn.microsoft.com/windows/win32/secauthn/msgina-dll-features,
    https://learn.microsoft.com/windows/win32/api/ntsecapi/nf-ntsecapi-lsastoreprivatedata, and
    https://learn.microsoft.com/windows/win32/api/ntsecapi/nf-ntsecapi-lsaretrieveprivatedata
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Read', 'Arm', 'Clear')]
        [string] $Action = 'Read',

        [securestring] $Password,

        [string] $UserName = 'Administrator',

        [string] $Domain = ''
    )

    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if (-not ('DbHubDemoLsa' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;

public static class DbHubDemoLsa
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LsaString { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }

    [StructLayout(LayoutKind.Sequential)]
    private struct LsaAttributes { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }

    [DllImport("advapi32.dll")] private static extern uint LsaOpenPolicy(IntPtr systemName, ref LsaAttributes attributes, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")] private static extern uint LsaStorePrivateData(IntPtr policy, ref LsaString keyName, IntPtr privateData);
    [DllImport("advapi32.dll")] private static extern uint LsaRetrievePrivateData(IntPtr policy, ref LsaString keyName, out IntPtr privateData);
    [DllImport("advapi32.dll")] private static extern uint LsaFreeMemory(IntPtr buffer);
    [DllImport("advapi32.dll")] private static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] private static extern int LsaNtStatusToWinError(uint status);

    private const uint GetPrivateInformation = 0x00000004;
    private const uint CreateSecret = 0x00000020;
    private const uint NameNotFound = 0xC0000034;

    private static IntPtr Open(uint access)
    {
        LsaAttributes attributes = new LsaAttributes();
        attributes.Length = Marshal.SizeOf(typeof(LsaAttributes));
        IntPtr policy;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, access, out policy);
        if (status != 0) { throw new Win32Exception(LsaNtStatusToWinError(status)); }
        return policy;
    }

    private static LsaString Name(string name, IntPtr buffer)
    {
        LsaString value = new LsaString();
        value.Buffer = buffer;
        value.Length = (ushort)(name.Length * 2);
        value.MaximumLength = (ushort)((name.Length + 1) * 2);
        return value;
    }

    public static bool Exists(string name)
    {
        IntPtr policy = Open(GetPrivateInformation);
        IntPtr nameBuffer = Marshal.StringToHGlobalUni(name);
        try
        {
            LsaString key = Name(name, nameBuffer);
            IntPtr data;
            uint status = LsaRetrievePrivateData(policy, ref key, out data);
            if (data != IntPtr.Zero) { LsaFreeMemory(data); }
            if (status == 0) { return true; }
            if (status == NameNotFound) { return false; }
            throw new Win32Exception(LsaNtStatusToWinError(status));
        }
        finally
        {
            Marshal.FreeHGlobal(nameBuffer);
            LsaClose(policy);
        }
    }

    public static void Store(string name, SecureString secret)
    {
        IntPtr policy = Open(CreateSecret);
        IntPtr nameBuffer = Marshal.StringToHGlobalUni(name);
        IntPtr secretBuffer = IntPtr.Zero;
        IntPtr secretValue = IntPtr.Zero;
        try
        {
            LsaString key = Name(name, nameBuffer);
            uint status;
            if (secret == null)
            {
                status = LsaStorePrivateData(policy, ref key, IntPtr.Zero);
                if (status == NameNotFound) { status = 0; }
            }
            else
            {
                secretBuffer = Marshal.SecureStringToGlobalAllocUnicode(secret);
                LsaString data = new LsaString();
                data.Buffer = secretBuffer;
                data.Length = (ushort)(secret.Length * 2);
                data.MaximumLength = (ushort)((secret.Length + 1) * 2);
                secretValue = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(LsaString)));
                Marshal.StructureToPtr(data, secretValue, false);
                status = LsaStorePrivateData(policy, ref key, secretValue);
            }
            if (status != 0) { throw new Win32Exception(LsaNtStatusToWinError(status)); }
        }
        finally
        {
            if (secretValue != IntPtr.Zero) { Marshal.FreeHGlobal(secretValue); }
            if (secretBuffer != IntPtr.Zero) { Marshal.ZeroFreeGlobalAllocUnicode(secretBuffer); }
            Marshal.FreeHGlobal(nameBuffer);
            LsaClose(policy);
        }
    }
}
'@
    }
    $read = {
        $item = Get-ItemProperty -LiteralPath $winlogon -ErrorAction SilentlyContinue
        $has = {
            param([string] $Name)
            return ($null -ne $item -and $null -ne $item.PSObject.Properties[$Name])
        }
        $autoAdminLogon = $false
        if (& $has 'AutoAdminLogon') {
            $autoAdminLogon = ([string]$item.AutoAdminLogon -eq '1')
        }
        $userName = $false
        if (& $has 'DefaultUserName') {
            $userName = -not [string]::IsNullOrEmpty([string]$item.DefaultUserName)
        }
        [pscustomobject]@{
            autoAdminLogon  = $autoAdminLogon
            autoLogonCount  = [bool](& $has 'AutoLogonCount')
            defaultUserName = $userName
            defaultPassword = [bool](& $has 'DefaultPassword')
            lsaSecret       = [DbHubDemoLsa]::Exists('DefaultPassword')
        }
    }
    $before = & $read
    if ($Action -eq 'Arm') {
        if ($null -eq $Password -or $Password.Length -lt 12) {
            throw 'Arming automatic sign-in needs the temporary password.'
        }
        [DbHubDemoLsa]::Store('DefaultPassword', $Password)
        Remove-ItemProperty -LiteralPath $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
        Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultUserName' -Value $UserName
        if ($Domain) {
            Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultDomainName' -Value $Domain
        }
        New-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonCount' -PropertyType DWord -Value 1 -Force | Out-Null
        Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -Value '1'
    }
    elseif ($Action -eq 'Clear') {
        Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -Value '0'
        foreach ($name in 'AutoLogonCount', 'DefaultPassword', 'DefaultUserName') {
            Remove-ItemProperty -LiteralPath $winlogon -Name $name -ErrorAction SilentlyContinue
        }
        [DbHubDemoLsa]::Store('DefaultPassword', $null)
    }
    $after = & $read
    return [pscustomobject]@{ action = $Action; before = $before; after = $after }
}

function Test-DemoAutoLogonClear {
    # True when Invoke-DemoGuestAutoLogonAction's state shows no automatic sign-in and nothing it keeps.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $State
    )

    if ($null -eq $State) {
        return $false
    }
    return (-not [bool]$State.autoAdminLogon -and -not [bool]$State.autoLogonCount -and -not [bool]$State.defaultUserName -and -not [bool]$State.defaultPassword -and -not [bool]$State.lsaSecret)
}

function Get-DemoGuidedSetupLauncherText {
    <#
    .SYNOPSIS
    The script the guest's logon task runs (Start-GuidedSetup.ps1): it first clears the automatic sign-in that started the
    session (its stored password isn't needed again), then opens SQL Server setup pre-filled from the configuration file,
    or the SQL Server Installation Center when an instance exists (for Maintenance > Edition Upgrade or a removal), and
    waits until setup closes. It writes its state to a JSON file and a log, never a value. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $IsoPath,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Path
    )

    foreach ($value in @($IsoPath, $Path.GuestConfiguration, $Path.GuestStatus, $Path.GuestLog)) {
        if ($value -match "['`r`n]") {
            throw 'A guided setup path contains a character the launcher can''t hold.'
        }
    }
    $function = 'function Invoke-DemoGuestAutoLogonAction {' + ${function:Invoke-DemoGuestAutoLogonAction}.ToString() + '}'
    $body = @'
$ErrorActionPreference = 'Stop'
$setupNames = @('ScenarioEngine', 'setup', 'SetupARP', 'LandingPage')
function Write-GuidedLog([string] $Message) {
    Add-Content -LiteralPath $logPath -Value ('{0} {1}' -f [DateTime]::UtcNow.ToString('o'), $Message) -Encoding ASCII
}
function Write-GuidedStatus([string] $State, [string] $Detail, [object] $ExitCode) {
    $value = [ordered]@{ schemaVersion = 1; state = $State; detail = $Detail; exitCode = $ExitCode; updatedUtc = [DateTime]::UtcNow.ToString('o') }
    [System.IO.File]::WriteAllText($statusPath, (ConvertTo-Json -InputObject $value -Compress), (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
}
try {
    try {
        $cleared = Invoke-DemoGuestAutoLogonAction -Action Clear
        Write-GuidedLog ('Cleared the automatic sign-in settings (the LSA secret was there before: {0}).' -f [bool]$cleared.before.lsaSecret)
    }
    catch {
        Write-GuidedLog ('Clearing the automatic sign-in settings failed; the host clears them: ' + $_.Exception.Message)
    }
    if (@(Get-Process -Name $setupNames -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-GuidedLog 'SQL Server setup is already open.'
        return
    }
    $image = Get-DiskImage -ImagePath $isoPath
    if (-not $image.Attached) {
        $image = Mount-DiskImage -ImagePath $isoPath -PassThru
    }
    $drive = [string]($image | Get-Volume).DriveLetter
    $setup = '{0}:\setup.exe' -f $drive
    $instances = @(Get-Service -Name 'MSSQLSERVER', 'MSSQL$*' -ErrorAction SilentlyContinue)
    if ($instances.Count -eq 0) {
        Write-GuidedStatus 'SetupOpen' 'A new installation, pre-filled from the configuration file.' $null
        Write-GuidedLog 'Opening SQL Server setup with the configuration file.'
        $process = Start-Process -FilePath $setup -ArgumentList ('/ConfigurationFile="{0}"' -f $configurationPath) -PassThru
    }
    else {
        Write-GuidedStatus 'InstallationCenter' 'An instance exists: the SQL Server Installation Center opens for Maintenance > Edition Upgrade or a removal.' $null
        Write-GuidedLog 'An instance exists; opening the SQL Server Installation Center.'
        $process = Start-Process -FilePath $setup -PassThru
    }
    $null = $process.Handle
    $process.WaitForExit()
    while (@(Get-Process -Name $setupNames -ErrorAction SilentlyContinue).Count -gt 0) {
        Start-Sleep -Seconds 10
    }
    Write-GuidedStatus 'Closed' 'Setup closed.' $process.ExitCode
    Write-GuidedLog ('Setup closed with exit code {0}.' -f $process.ExitCode)
}
catch {
    Write-GuidedStatus 'Failed' ([string]$_.Exception.Message) $null
    Write-GuidedLog ('The guided setup launcher failed: ' + $_.Exception.Message)
}
'@
    $header = @(
        '# Fabric Database Hub demo (Phase 28): the guest''s logon task runs this during the PaygWizard guided stop. It clears the'
        '# automatic sign-in that started the session, then opens SQL Server setup pre-filled from the configuration file. Generated'
        '# on the T2 host; it holds no secret.'
        ('$isoPath = ''{0}''' -f $IsoPath)
        ('$configurationPath = ''{0}''' -f $Path.GuestConfiguration)
        ('$statusPath = ''{0}''' -f $Path.GuestStatus)
        ('$logPath = ''{0}''' -f $Path.GuestLog)
    ) -join "`r`n"
    return ($header + "`r`n" + $function + "`r`n" + ($body -replace "(?<!`r)`n", "`r`n"))
}

function Get-DemoGuidedSetupTaskDefinition {
    <#
    .SYNOPSIS
    The guided stop's two logon tasks, as plain values: in the guest, DbHubDemo-GuidedSetup runs the launcher at the
    Administrator's logon (interactive, highest privileges); on the host, DbHubDemo-GuestConsole opens Virtual Machine
    Connection at any administrator's logon. Pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Guest', 'Host')]
        [string] $Kind,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Path,

        [string] $UserName = 'Administrator'
    )

    if ($Kind -eq 'Guest') {
        return [pscustomobject]@{
            TaskName    = 'DbHubDemo-GuidedSetup'
            Execute     = 'powershell.exe'
            Argument    = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Path.GuestLauncher
            UserId      = $UserName
            GroupId     = ''
            Description = 'Fabric Database Hub demo: opens the pre-filled SQL Server setup for the PaygWizard guided stop (Phase 28). Removed once the step is done.'
        }
    }
    return [pscustomobject]@{
        TaskName    = 'DbHubDemo-GuestConsole'
        Execute     = 'powershell.exe'
        Argument    = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Path.HostConsoleScript
        UserId      = ''
        GroupId     = 'BUILTIN\Administrators'
        Description = 'Fabric Database Hub demo: opens Virtual Machine Connection to the guest during the PaygWizard guided stop (Phase 28). Removed once the step is done.'
    }
}

function Register-DemoGuidedSetupTask {
    # Registers a task from Get-DemoGuidedSetupTaskDefinition where this runs: on the host, or in the guest over PowerShell
    # Direct (the definition crosses as a hashtable). Self-contained for that reason.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Definition
    )

    $action = New-ScheduledTaskAction -Execute $Definition['Execute'] -Argument $Definition['Argument']
    if ($Definition['GroupId']) {
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId $Definition['GroupId'] -RunLevel Highest
    }
    else {
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Definition['UserId']
        $principal = New-ScheduledTaskPrincipal -UserId $Definition['UserId'] -LogonType Interactive -RunLevel Highest
    }
    $taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $Definition['TaskName'] -Action $action -Trigger $trigger -Principal $principal -Settings $taskSettings -Description $Definition['Description'] -Force | Out-Null
}

function ConvertTo-DemoTaskHashtable {
    # A task definition as a hashtable, so it crosses PowerShell Direct intact.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Definition
    )

    $table = @{}
    foreach ($property in $Definition.PSObject.Properties) {
        $table[$property.Name] = [string]$property.Value
    }
    return $table
}

function Get-DemoGuestConsoleScriptText {
    # The host script the DbHubDemo-GuestConsole task runs: Virtual Machine Connection to the guest, and the steps beside it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $GuestName,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Path
    )

    if ($GuestName -notmatch '^[A-Za-z0-9-]{1,15}$' -or $Path.HostSteps -match "['`r`n]") {
        throw 'The guest name or the steps path isn''t valid.'
    }
    return (@(
            '# Fabric Database Hub demo (Phase 28): at your sign-in to the T2 host during the PaygWizard guided stop, opens Virtual'
            '# Machine Connection to the guest, where SQL Server setup waits pre-filled, and the steps beside it.'
            ('$guest = ''{0}''' -f $GuestName)
            ('$steps = ''{0}''' -f $Path.HostSteps)
            '$vmconnect = Join-Path -Path $env:SystemRoot -ChildPath ''System32\vmconnect.exe'''
            'if (Test-Path -LiteralPath $vmconnect) { Start-Process -FilePath $vmconnect -ArgumentList ''localhost'', $guest }'
            'if (Test-Path -LiteralPath $steps) { Start-Process -FilePath ''notepad.exe'' -ArgumentList (''"{0}"'' -f $steps) }'
        ) -join "`r`n") + "`r`n"
}

function Get-DemoGuidedSetupRequest {
    <#
    .SYNOPSIS
    The request deploy.ps1 writes on the host while it waits for a person at the guided stop
    (vm/bootstrap/Set-DemoGuidedSetupRequest.ps1): Valid while it hasn't expired. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Path,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $result = [ordered]@{ Exists = $false; Valid = $false; Expired = $false; RequestId = ''; ExpiresUtc = $null; Azure = @{} }
    if (-not (Test-Path -LiteralPath $Path.HostRequest -PathType Leaf)) {
        return [pscustomobject]$result
    }
    $result.Exists = $true
    try {
        $request = Read-DemoVmJsonFile -Path $Path.HostRequest
    }
    catch {
        return [pscustomobject]$result
    }
    if ($null -eq $request) {
        return [pscustomobject]$result
    }
    $expires = [datetime]::MinValue
    $parsed = [datetime]::TryParse([string]$request['expiresUtc'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expires)
    $result.RequestId = [string]$request['requestId']
    if ($parsed) {
        $result.ExpiresUtc = $expires
        $result.Valid = $expires -gt $NowUtc.ToUniversalTime() -and $result.RequestId -match '^[A-Za-z0-9-]{8,64}$'
        $result.Expired = $expires -le $NowUtc.ToUniversalTime()
    }
    $azure = @{}
    foreach ($key in 'SubscriptionId', 'ResourceGroup', 'Region', 'TenantId') {
        $name = $key.Substring(0, 1).ToLowerInvariant() + $key.Substring(1)
        if ($request.Contains($name)) {
            $azure[$key] = [string]$request[$name]
        }
    }
    $result.Azure = $azure
    return [pscustomobject]$result
}

function Get-DemoGuidedSetupArmed {
    # The host's record that automatic sign-in is armed in the guest (written before the arm), or $null.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Path
    )

    if (-not (Test-Path -LiteralPath $Path.HostArmed -PathType Leaf)) {
        return $null
    }
    try {
        $value = Read-DemoVmJsonFile -Path $Path.HostArmed
    }
    catch {
        $value = $null
    }
    if ($null -eq $value) {
        # An unreadable record still means "clean up": it's never ignored.
        return @{ requestId = ''; arms = 0; armedUtc = ''; okSinceUtc = ''; lastLaunchUtc = '' }
    }
    return $value
}

function Save-DemoGuidedSetupArmed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Value
    )

    Write-DemoVmJsonFile -Path $Path.HostArmed -InputObject $Value
}

function Get-DemoGuestSetupFact {
    # Over PowerShell Direct, read-only: the SQL Server instance services, setup processes, and the newest configuration
    # file setup generated for an installation (its documented log folder), with its FEATURES. Never a value.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential
    )

    return (Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
            $named = @(Get-Service -Name 'MSSQL$*' -ErrorAction SilentlyContinue | ForEach-Object { ([string]$_.Name).Substring(6) })
            $default = [bool](Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue)
            $setup = @(Get-Process -Name 'ScenarioEngine', 'setup', 'SetupARP', 'LandingPage' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.ProcessName } | Select-Object -Unique)
            $features = $null
            $files = @(Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\*\ConfigurationFile.ini' -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTimeUtc -Descending)
            foreach ($file in $files) {
                $text = [System.IO.File]::ReadAllText($file.FullName)
                if ($text -match '(?im)^\s*ACTION\s*=\s*"?Install"?\s*$' -and $text -match '(?im)^\s*FEATURES\s*=\s*"?([^"\r\n]+)"?\s*$') {
                    $features = [string]$Matches[1]
                    break
                }
            }
            [pscustomobject]@{ DefaultInstance = $default; NamedInstances = $named; SetupProcess = $setup; Features = $features }
        })
}

function Get-DemoHostSetupCheck {
    <#
    .SYNOPSIS
    Checks what the person installed at the guided stop (PaygWizard): the default instance MSSQLSERVER, running, with the
    guest's Administrator as sysadmin, Standard edition, and setup's Azure extension (which pay-as-you-go needs). Returns
    Ok, Problem, SetupRunning, Edition, Message, and Fix (the documented steps that fix what's wrong).

    .DESCRIPTION
    Pay-as-you-go itself can't be read in the guest before the Azure extension reports it; the Azure extension feature in
    setup's generated configuration file is the readable sign (setup's Edition page can't leave it out with
    pay-as-you-go). Setup's documented log folder holds that file:
    https://learn.microsoft.com/sql/database-engine/install-windows/view-and-read-sql-server-setup-log-files. The fixes
    follow https://learn.microsoft.com/sql/database-engine/install-windows/upgrade-downgrade-sql-server-edition-setup
    (Evaluation, Developer, and Express upgrade in place to Standard; Enterprise to Standard is a downgrade) and
    https://learn.microsoft.com/sql/sql-server/install/uninstall-an-existing-instance-of-sql-server-setup.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    $facts = Get-DemoGuestSetupFact -Name $Context.GuestName -Credential $credential
    $instance = Get-DemoGuestSqlInstance -Name $Context.GuestName -Credential $credential
    $guest = $Context.GuestName
    $remove = 'In {0}, open Settings > Apps > Installed apps, select Microsoft SQL Server 2022 (64-bit) > Uninstall, choose Remove, select the instance and all its features, and finish (Learn: Uninstall an existing instance of SQL Server). The deploy then reopens the pre-filled setup: choose Use pay-as-you-go billing through Microsoft Azure and Standard.' -f $guest
    $check = [ordered]@{ Ok = $false; Problem = ''; SetupRunning = (@($facts.SetupProcess).Count -gt 0); Edition = [string]$instance.Edition; AzureExtension = $null; Message = ''; Fix = @() }
    if ($null -ne $facts.Features) {
        $check.AzureExtension = ([string]$facts.Features -match '(?i)\bAZUREEXTENSION\b')
    }
    if (-not $facts.DefaultInstance -and @($facts.NamedInstances).Count -gt 0) {
        $check.Problem = 'NamedInstance'
        $check.Message = 'SQL Server was installed as the named instance {0}; the demo needs the default instance (MSSQLSERVER).' -f (@($facts.NamedInstances) -join ', ')
        $check.Fix = @($remove)
    }
    elseif (-not $facts.DefaultInstance) {
        $check.Problem = 'NotInstalled'
        $check.Message = 'SQL Server isn''t installed in {0} yet.' -f $guest
    }
    elseif (-not $instance.Running) {
        $check.Problem = 'Stopped'
        $check.Message = 'SQL Server is installed in {0}, but its service isn''t running.' -f $guest
        $check.Fix = @('Start the SQL Server (MSSQLSERVER) service in the guest, or finish setup.')
    }
    elseif ($instance.Error -or -not $instance.IsSysAdmin) {
        $check.Problem = 'NotSysadmin'
        $check.Message = 'SQL Server runs in {0}, but the guest''s Administrator can''t sign in to it as a sysadmin.' -f $guest
        $check.Fix = @($remove)
    }
    elseif ([string]$instance.Edition -like 'Enterprise*' -and [string]$instance.Edition -notlike '*Evaluation*') {
        $check.Problem = 'Edition'
        $check.Message = 'SQL Server in {0} is {1}; the demo needs Standard with pay-as-you-go, and Enterprise to Standard is a downgrade that setup can''t do in place.' -f $guest, $instance.Edition
        $check.Fix = @($remove)
    }
    elseif ([string]$instance.Edition -notlike 'Standard*') {
        $check.Problem = 'Edition'
        $check.Message = 'SQL Server in {0} is {1}; the demo needs Standard with pay-as-you-go.' -f $guest, $instance.Edition
        $check.Fix = @(
            ('In the SQL Server Installation Center that the deploy opens in {0}, select Maintenance > Edition Upgrade; on the Product Key page choose Standard (pay-as-you-go through Microsoft Azure, or your own Standard product key), accept the license terms, select the instance MSSQLSERVER, then Upgrade (Learn: In-place change of SQL Server edition: Evaluation, Developer, and Express upgrade to Standard).' -f $guest)
            ('Or: {0}' -f $remove)
        )
    }
    elseif ($check.AzureExtension -eq $false) {
        $check.Problem = 'NoAzureExtension'
        $check.Message = 'SQL Server Standard runs in {0}, but setup didn''t include the Azure extension for SQL Server, so pay-as-you-go wasn''t chosen.' -f $guest
        $check.Fix = @($remove)
    }
    else {
        $check.Ok = $true
        $check.Message = 'SQL Server Standard runs in {0} as the default instance, with the Azure extension.' -f $guest
    }
    return [pscustomobject]$check
}

function Test-DemoGuestConsoleSession {
    # True when someone is signed in at the guest's console (an explorer.exe session).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential
    )

    $sessions = @(Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
            @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.SessionId } | Where-Object { $_ -gt 0 } | Select-Object -Unique)
        })
    return ($sessions.Count -gt 0)
}

function Invoke-DemoGuestSignOut {
    # Signs out every interactive session in the guest (logoff <session id>; an explorer.exe session is one). Returns how
    # many. https://learn.microsoft.com/windows-server/administration/windows-commands/logoff
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential
    )

    return [int](Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
            $ids = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.SessionId } | Where-Object { $_ -gt 0 } | Select-Object -Unique)
            foreach ($id in $ids) {
                $previous = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                & logoff.exe $id 2>&1 | Out-Null
                $ErrorActionPreference = $previous
            }
            $ids.Count
        })
}

function Initialize-DemoHostGuidedSetup {
    <#
    .SYNOPSIS
    The GuidedSetup step (PaygWizard): puts the launcher and the configuration file in the guest with its logon task, and
    the console script, the steps, and the logon task on the host. Nothing is armed here, and nothing secret is written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $path = Get-DemoGuidedSetupPath -Root $Context.Root
    $request = Get-DemoGuidedSetupRequest -Path $path
    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    $configuration = Get-DemoGuidedSetupConfigurationText -Sql $Context.Guest.Sql -Azure $request.Azure
    $launcher = Get-DemoGuidedSetupLauncherText -IsoPath (Get-DemoHostGuestIsoPath -Context $Context) -Path $path
    $guestTask = ConvertTo-DemoTaskHashtable -Definition (Get-DemoGuidedSetupTaskDefinition -Kind 'Guest' -Path $path -UserName $Context.Guest.AdministratorName)
    $register = ${function:Register-DemoGuidedSetupTask}.ToString()
    Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ArgumentList $path.GuestFolder, $path.GuestConfiguration, $configuration, $path.GuestLauncher, $launcher, $guestTask, $register -ScriptBlock {
        param($Folder, $ConfigurationPath, $ConfigurationText, $LauncherPath, $LauncherText, $Task, $RegisterText)
        if (-not (Test-Path -LiteralPath $Folder)) {
            New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        }
        $ascii = New-Object -TypeName 'System.Text.ASCIIEncoding'
        [System.IO.File]::WriteAllText($ConfigurationPath, $ConfigurationText, $ascii)
        [System.IO.File]::WriteAllText($LauncherPath, $LauncherText, $ascii)
        $registerTask = [scriptblock]::Create($RegisterText)
        & $registerTask -Definition $Task
    }
    $ascii = New-Object -TypeName 'System.Text.ASCIIEncoding'
    [System.IO.File]::WriteAllText($path.HostConsoleScript, (Get-DemoGuestConsoleScriptText -GuestName $Context.GuestName -Path $path), $ascii)
    [System.IO.File]::WriteAllText($path.HostSteps, ((@(Get-DemoGuidedSetupStepText -GuestName $Context.GuestName) -join "`r`n") + "`r`n"), $ascii)
    Register-DemoGuidedSetupTask -Definition (ConvertTo-DemoTaskHashtable -Definition (Get-DemoGuidedSetupTaskDefinition -Kind 'Host' -Path $path))
    Write-DemoVmLog -Message ('Prepared the guided setup: the pre-filled SQL Server setup and its logon task in {0}, and Virtual Machine Connection at an administrator''s sign-in to this host.' -f $Context.GuestName)
}

function Test-DemoHostGuidedSetup {
    # The GuidedSetup step's check: the right instance is already installed, or the launcher, the configuration file, and
    # both logon tasks are in place. Never throws.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    try {
        if (Test-DemoHostSqlEdition -Context $Context) {
            return $true
        }
        $path = Get-DemoGuidedSetupPath -Root $Context.Root
        if (-not (Test-Path -LiteralPath $path.HostConsoleScript) -or -not (Get-ScheduledTask -TaskName 'DbHubDemo-GuestConsole' -ErrorAction SilentlyContinue)) {
            return $false
        }
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        return [bool](Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ArgumentList $path.GuestConfiguration, $path.GuestLauncher -ScriptBlock {
                param($ConfigurationPath, $LauncherPath)
                (Test-Path -LiteralPath $ConfigurationPath) -and (Test-Path -LiteralPath $LauncherPath) -and [bool](Get-ScheduledTask -TaskName 'DbHubDemo-GuidedSetup' -ErrorAction SilentlyContinue)
            })
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('Guided setup check: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Remove-DemoHostGuidedSetup {
    # After the step: removes both logon tasks, the host's console script and steps, and the guest's setup folder. Never
    # throws; what it couldn't remove is logged and stays harmless (the tasks only open a window and a pre-filled setup).
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    if (-not $PSCmdlet.ShouldProcess($Context.GuestName, 'Remove the guided setup''s logon tasks and files')) {
        return
    }
    $path = Get-DemoGuidedSetupPath -Root $Context.Root
    try {
        if (Get-ScheduledTask -TaskName 'DbHubDemo-GuestConsole' -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName 'DbHubDemo-GuestConsole' -Confirm:$false
        }
        foreach ($file in $path.HostConsoleScript, $path.HostSteps) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ArgumentList $path.GuestFolder -ScriptBlock {
            param($Folder)
            if (Get-ScheduledTask -TaskName 'DbHubDemo-GuidedSetup' -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName 'DbHubDemo-GuidedSetup' -Confirm:$false
            }
            Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The guided setup''s tasks and files couldn''t all be removed: {0}' -f $_.Exception.Message)
    }
}

function Enable-DemoHostGuestAutoLogon {
    <#
    .SYNOPSIS
    Arms the guest's one automatic sign-in for the guided stop: the record first (so a run that dies midway still cleans
    up), then a new random password for the guest's Administrator through the usual rotation, the LSA secret and the
    Winlogon values (AutoLogonCount 1), and a restart of the guest; its logon task then opens the pre-filled setup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [Parameter(Mandatory = $true)]
        [string] $RequestId,

        [int] $Arms = 1
    )

    $path = Get-DemoGuidedSetupPath -Root $Context.Root
    $record = @{ schemaVersion = 1; requestId = $RequestId; arms = $Arms; armedUtc = (Get-DemoVmUtcNow); okSinceUtc = ''; lastLaunchUtc = '' }
    Save-DemoGuidedSetupArmed -Path $path -Value $record
    Update-DemoGuestSecret -SecretPath $Context.SecretPath -Name $Context.GuestName -UserName $Context.Guest.AdministratorName
    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    $state = Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ScriptBlock ${function:Invoke-DemoGuestAutoLogonAction} -ArgumentList 'Arm', $credential.Password, $Context.Guest.AdministratorName, $Context.GuestName
    if (-not [bool]$state.after.autoAdminLogon -or -not [bool]$state.after.lsaSecret -or [bool]$state.after.defaultPassword) {
        throw 'Automatic sign-in wasn''t armed as expected in the guest (the LSA secret or AutoAdminLogon is missing, or a Winlogon DefaultPassword value exists).'
    }
    Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction SilentlyContinue -ScriptBlock { Restart-Computer -Force }
    Write-DemoVmLog -Message ('Armed one automatic sign-in in {0} for the guided stop (attempt {1}); the guest restarts, signs in, and opens the pre-filled SQL Server setup.' -f $Context.GuestName, $Arms)
}

function Disable-DemoHostGuestAutoLogon {
    <#
    .SYNOPSIS
    The guided stop's cleanup, which always runs (setup done, the request expired or gone, or before another arm): turns
    automatic sign-in off and deletes the LSA secret and the Winlogon DefaultUserName and DefaultPassword values, rotates
    the guest Administrator's password, signs the console out, and checks that nothing is left. The record goes only when
    every part worked, so a failed cleanup runs again at the next run; a leftover throws (fail closed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Installed', 'Expired', 'NoRequest', 'Retry', 'Leftover')]
        [string] $Reason
    )

    $path = Get-DemoGuidedSetupPath -Root $Context.Root
    $problems = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $found = $null
    $left = $null
    $signedOut = 0
    # Sign-out first: Windows records the last console user in DefaultUserName at a sign-in, so the values are cleared
    # once no session can write them again.
    try {
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        $signedOut = Invoke-DemoGuestSignOut -Name $Context.GuestName -Credential $credential
        if ($signedOut -gt 0) {
            Start-Sleep -Seconds 15
        }
    }
    catch {
        $problems.Add(('signing the console out ({0})' -f $_.Exception.Message))
    }
    try {
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        $cleared = Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ScriptBlock ${function:Invoke-DemoGuestAutoLogonAction} -ArgumentList 'Clear'
        $found = $cleared.before
        if (-not (Test-DemoAutoLogonClear -State $cleared.after)) {
            $problems.Add('the automatic sign-in settings')
        }
    }
    catch {
        $problems.Add(('clearing the automatic sign-in settings ({0})' -f $_.Exception.Message))
    }
    try {
        Update-DemoGuestSecret -SecretPath $Context.SecretPath -Name $Context.GuestName -UserName $Context.Guest.AdministratorName
    }
    catch {
        $problems.Add(('rotating the guest password ({0})' -f $_.Exception.Message))
    }
    try {
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        $left = (Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ScriptBlock ${function:Invoke-DemoGuestAutoLogonAction} -ArgumentList 'Read').after
        if (-not (Test-DemoAutoLogonClear -State $left)) {
            $problems.Add('a check after the cleanup')
        }
    }
    catch {
        $problems.Add(('checking after the cleanup ({0})' -f $_.Exception.Message))
    }
    $leftovers = @()
    if ($null -ne $found) {
        $leftovers = @('autoAdminLogon', 'autoLogonCount', 'defaultUserName', 'defaultPassword', 'lsaSecret' | Where-Object { [bool]$found.$_ })
    }
    $last = [ordered]@{ schemaVersion = 1; reason = $Reason; disarmedUtc = (Get-DemoVmUtcNow); found = $leftovers; signedOut = $signedOut; problems = @($problems) }
    Write-DemoVmJsonFile -Path $path.HostLast -InputObject $last
    if ($problems.Count -gt 0) {
        throw ('The guided stop''s cleanup in {0} didn''t finish ({1}); it runs again at the next run (fail closed).' -f $Context.GuestName, ($problems -join '; '))
    }
    Remove-Item -LiteralPath $path.HostArmed -Force -ErrorAction SilentlyContinue
    Write-DemoVmLog -Message ('Cleaned up the guided stop in {0} ({1}): automatic sign-in off and its LSA secret and Winlogon values gone (found: {2}), the guest password rotated, {3} console session(s) signed out.' -f $Context.GuestName, $Reason, $(if ($leftovers.Count) { $leftovers -join ', ' } else { 'nothing' }), $signedOut)
}

function Resolve-DemoGuestPendingSecret {
    # A rotation that stopped midway leaves guest-administrator.bin.pending: promote it when it's the one that signs in,
    # delete it when the main one still does. Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $pending = $Context.SecretPath + '.pending'
    if (-not (Test-Path -LiteralPath $pending -PathType Leaf)) {
        return
    }
    try {
        $main = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        if (Test-DemoGuestOnline -Name $Context.GuestName -Credential $main) {
            Remove-Item -LiteralPath $pending -Force
            return
        }
        $candidate = Get-DemoGuestCredential -SecretPath $pending -UserName $Context.Guest.AdministratorName
        if (Test-DemoGuestOnline -Name $Context.GuestName -Credential $candidate) {
            Move-Item -LiteralPath $pending -Destination $Context.SecretPath -Force
            Write-DemoVmLog -Message 'A guest password rotation had stopped midway; its new password is the one that signs in, so it was kept.'
        }
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('A pending guest password couldn''t be resolved yet: {0}' -f $_.Exception.Message)
    }
}

function Invoke-DemoHostGuidedSetupGuard {
    <#
    .SYNOPSIS
    Runs before every pass of the host's state machine: finishes a guest password rotation that stopped midway, and when
    automatic sign-in is armed but no person is expected any more (deploy.ps1's request expired or went), runs the
    cleanup. Cheap when nothing is armed. Never throws: a failed cleanup is logged and runs again 5 minutes later.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    Resolve-DemoGuestPendingSecret -Context $Context
    $path = Get-DemoGuidedSetupPath -Root $Context.Root
    $armed = Get-DemoGuidedSetupArmed -Path $path
    if ($null -eq $armed) {
        return
    }
    $request = Get-DemoGuidedSetupRequest -Path $path
    if ($request.Valid) {
        return
    }
    try {
        Disable-DemoHostGuestAutoLogon -Context $Context -Reason $(if ($request.Expired) { 'Expired' } else { 'NoRequest' })
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message $_.Exception.Message
    }
}

function Invoke-DemoHostGuidedSetupStep {
    <#
    .SYNOPSIS
    The SqlSetupWizard step's Set in PaygWizard mode (Phase 28): checks what's installed, cleans up once the right
    instance is there, and while deploy.ps1 waits for a person (a valid request), opens the pre-filled setup in the guest:
    in a session that's already signed in, or through one automatic sign-in. Returns a step result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [ValidateRange(1, 120)]
        [int] $CloseGraceMinutes = 15,

        [ValidateRange(1, 10)]
        [int] $MaxArms = 3
    )

    $path = Get-DemoGuidedSetupPath -Root $Context.Root
    $check = Get-DemoHostSetupCheck -Context $Context
    $armed = Get-DemoGuidedSetupArmed -Path $path
    $instructions = @(Get-DemoPaygWizardInstruction -GuestName $Context.GuestName)
    if ($check.Ok) {
        # Setup is done. While it still shows its Complete page, give the person a moment, then clean up anyway.
        if ($check.SetupRunning -and $null -ne $armed) {
            $since = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$armed['okSinceUtc'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$since)) {
                $armed['okSinceUtc'] = Get-DemoVmUtcNow
                Save-DemoGuidedSetupArmed -Path $path -Value $armed
                $since = [DateTime]::UtcNow
            }
            if ([DateTime]::UtcNow -lt $since.AddMinutes($CloseGraceMinutes)) {
                return (New-DemoVmStepResult -Outcome 'InProgress' -Message ('{0} Select Close in setup; within {1} minutes the host signs the guest out, rotates its password, and continues on its own.' -f $check.Message, $CloseGraceMinutes))
            }
        }
        Disable-DemoHostGuestAutoLogon -Context $Context -Reason 'Installed'
        Remove-DemoHostGuidedSetup -Context $Context
        return
    }

    $request = Get-DemoGuidedSetupRequest -Path $path
    $problem = ''
    if ($check.Problem -ne 'NotInstalled') {
        $problem = ' {0} Fix: {1}' -f $check.Message, (@($check.Fix) -join ' ')
    }
    if (-not $request.Valid) {
        if ($null -ne $armed) {
            Disable-DemoHostGuestAutoLogon -Context $Context -Reason $(if ($request.Expired) { 'Expired' } else { 'NoRequest' })
        }
        return (New-DemoVmStepResult -Outcome 'ManualActionRequired' -Message ('Arc is connected. The SQL Server setup step waits for you: run ./scripts/deploy.ps1, which opens Bastion and guides you, and the guest opens the pre-filled setup.{0}' -f $problem) -Instruction $instructions)
    }
    if ($check.SetupRunning) {
        return (New-DemoVmStepResult -Outcome 'ManualActionRequired' -Message ('SQL Server setup is open in {0}: choose Use pay-as-you-go billing through Microsoft Azure and Standard, sign in with Use Azure Login, then Install.{1}' -f $Context.GuestName, $problem) -Instruction $instructions)
    }
    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    if (Test-DemoGuestConsoleSession -Name $Context.GuestName -Credential $credential) {
        # Someone is signed in (the automatic sign-in, or a person): open setup, or the Installation Center for a fix, there.
        if ($null -eq $armed) {
            $armed = @{ schemaVersion = 1; requestId = $request.RequestId; arms = 0; armedUtc = ''; okSinceUtc = ''; lastLaunchUtc = '' }
        }
        $last = [datetime]::MinValue
        $known = [datetime]::TryParse([string]$armed['lastLaunchUtc'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$last)
        if (-not $known -or [DateTime]::UtcNow -ge $last.AddMinutes(4)) {
            Invoke-Command -VMName $Context.GuestName -Credential $credential -ErrorAction Stop -ScriptBlock { Start-ScheduledTask -TaskName 'DbHubDemo-GuidedSetup' }
            $armed['lastLaunchUtc'] = Get-DemoVmUtcNow
            Save-DemoGuidedSetupArmed -Path $path -Value $armed
        }
        return (New-DemoVmStepResult -Outcome 'ManualActionRequired' -Message ('The guest is signed in, and SQL Server setup opens there now.{0}' -f $problem) -Instruction $instructions)
    }
    $arms = 0
    if ($null -ne $armed -and [string]$armed['requestId'] -eq $request.RequestId) {
        $arms = [int]$armed['arms']
    }
    if ($arms -ge $MaxArms) {
        return (New-DemoVmStepResult -Outcome 'ManualActionRequired' -Message ('The guest''s automatic sign-in didn''t open setup after {0} tries. In Virtual Machine Connection, sign in to {1} as Administrator (C:\ProgramData\DbHubDemo\Copy-GuestCredential.ps1 copies the password), then run C:\DbHubDemo\setup\Start-GuidedSetup.ps1.{2}' -f $MaxArms, $Context.GuestName, $problem) -Instruction $instructions)
    }
    if ($null -ne $armed) {
        Disable-DemoHostGuestAutoLogon -Context $Context -Reason 'Retry'
    }
    Enable-DemoHostGuestAutoLogon -Context $Context -RequestId $request.RequestId -Arms ($arms + 1)
    return (New-DemoVmStepResult -Outcome 'ManualActionRequired' -Message ('The guest restarts, signs itself in once, and opens the pre-filled SQL Server setup in about 2 minutes.{0}' -f $problem) -Instruction $instructions)
}

function Test-DemoHostGuidedSetupDone {
    # The SqlSetupWizard step's check in PaygWizard mode: Standard runs as the default instance with the guest's
    # Administrator as sysadmin (as before Phase 28, so an existing or golden host converges unchanged), and nothing is
    # armed. While the guided stop is armed, the step's Set runs the full setup check, the Azure extension included.
    # Never throws.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    try {
        $path = Get-DemoGuidedSetupPath -Root $Context.Root
        if ($null -ne (Get-DemoGuidedSetupArmed -Path $path)) {
            return $false
        }
        return [bool](Test-DemoHostSqlEdition -Context $Context)
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('SQL Server setup check in the guest: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Get-DemoHostGuidedSetupDetail {
    # For health.json (details.guidedSetup): whether automatic sign-in is armed, deploy.ps1's request, and the last
    # cleanup (its reason, what it found, and what failed). Names and times only. Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $detail = [ordered]@{ armed = $false; request = 'none'; requestExpiresUtc = ''; lastReason = ''; lastDisarmedUtc = ''; lastFound = @(); lastProblems = @() }
    try {
        $path = Get-DemoGuidedSetupPath -Root $Context.Root
        $detail.armed = Test-Path -LiteralPath $path.HostArmed -PathType Leaf
        $request = Get-DemoGuidedSetupRequest -Path $path
        $detail.request = if ($request.Valid) { 'valid' } elseif ($request.Expired) { 'expired' } elseif ($request.Exists) { 'invalid' } else { 'none' }
        if ($null -ne $request.ExpiresUtc) {
            $detail.requestExpiresUtc = ([datetime]$request.ExpiresUtc).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $last = Read-DemoVmJsonFile -Path $path.HostLast
        if ($null -ne $last) {
            $detail.lastReason = [string]$last['reason']
            $detail.lastDisarmedUtc = [string]$last['disarmedUtc']
            $detail.lastFound = @($last['found'] | Where-Object { $_ })
            $detail.lastProblems = @($last['problems'] | Where-Object { $_ })
        }
    }
    catch {
        $detail['error'] = Protect-DemoVmText -Text $_.Exception.Message
    }
    return $detail
}

function Get-DemoGuidedSetupStepText {
    # The short steps the host's console task opens beside Virtual Machine Connection.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $GuestName
    )

    return @(
        ('Fabric Database Hub demo: the one step that needs you ({0}, SQL Server setup)' -f $GuestName)
        ''
        ('1. The Virtual Machine Connection window shows {0}, which signed itself in and opened SQL Server setup, pre-filled.' -f $GuestName)
        '2. On the Edition page, select "Use pay-as-you-go billing through Microsoft Azure", then Standard. Select Next.'
        '3. Accept the license terms. Select Next on the pages that follow.'
        '4. On the Azure Extension for SQL Server page, select "Use Azure Login" and sign in with your own Azure account. Never enter a service principal secret.'
        '5. Select Next on the pre-filled pages (features, the default instance, service accounts, administrators), then Install.'
        '6. When setup says Complete, select Close. The host signs the guest out, rotates its password, and continues on its own; deploy.ps1 then finishes T2.'
        ''
        ('If the window shows a sign-in screen instead: in an elevated PowerShell on this host, run C:\ProgramData\DbHubDemo\Copy-GuestCredential.ps1, then in Virtual Machine Connection select Clipboard > Type clipboard text, sign in as Administrator, and run C:\DbHubDemo\setup\Start-GuidedSetup.ps1.')
    )
}
