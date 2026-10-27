<#
.SYNOPSIS
Phase 20 (ADR 0018): inspects the T2 host and guest for a golden snapshot, prepares the capture (sign-in
cleanup and the guest air gap), and releases a restored or captured host (Arc identity reset on a copy,
guest password rotation, then the guest's network back).

.DESCRIPTION
The orchestrator runs this script on the T2 host archost01 in a managed Run Command. Windows PowerShell 5.1,
ASCII-only. It's self-contained on purpose: a host restored from a golden snapshot still has the bundle it
was captured with, so the script uses no function from the installed bundle. It reaches the guest arcsql01
over PowerShell Direct, which works without a network connection
(https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct).

Actions:
- Inspect: read-only. The host's Azure VM ID (Instance Metadata Service), health.json, the bundle and runner
  hashes, the used space on C:, the built-in administrator's PasswordLastSet, the product key file, the
  capture record, the guest's start action and network adapter; in the guest, the Windows evaluation expiry,
  SQL Server's edition, version, and update level, the Arc agent's identity, sign-in data that setup leaves
  on the VM (token-shaped values and the sign-in caches), and IE Enhanced Security Configuration. The full
  sign-in data sweep (Invoke-DemoSignInResidue.ps1, ADR 0009) runs before Prepare.
- Prepare: the capture's guest-side steps. Removes the sign-in data that setup leaves on the VM again and
  checks that none remains, turns IE ESC back on when it's off, writes the capture record
  C:\ProgramData\DbHubDemo\golden\capture.json (the snapshot name, this host's Azure VM ID, and the guest's
  Arc identity), applies the air gap (the guest's automatic start action becomes Nothing, and its network
  adapter is disconnected), then shuts the guest down cleanly and confirms it's off.
- Release: on the host the snapshot was captured from (its Azure VM ID matches the record), only reconnects
  the guest. On a copy, the guest starts with its adapter disconnected, and the script waits (up to 5
  minutes) until 'azcmagent show -j' reports the agent's state; if it never does, it stops with the guest
  still air-gapped, because "no answer" must not pass for "no identity". Unless the agent names another
  identity than the captured one, the copy is reset: an air-gapped agent can report a status (for example
  "failed") without its resource while it still holds the captured identity (live, 2026-10-23), so "names
  nothing" is treated like the captured identity (Get-GoldenResetDecision). The reset: stops the extension
  manager, removes every Arc extension locally, runs
  'azcmagent disconnect --force-local-only', checks that the agent names no resource, renames the host's
  Arc marker so the host waits for onboarding like a fresh build, waits for SQL Server's delayed automatic
  start (starting it after 8 minutes if it's still stopped), checks that it runs Standard edition, and
  rotates the guest's password; then reconnects the adapter and restores the automatic start.
  With ProveIsolation, the adapter is connected before the reset, and the reset runs only after
  'azcmagent check' and direct TCP tests show that no Arc endpoint answers (the boot test's network
  security group denies all outbound traffic). With KeepIsolated, the adapter stays disconnected.
- RotateGuestPassword: a new random password for the guest administrator, stored with DPAPI as pending,
  set in the guest, proven with a new session, then promoted; the old one is set back if the new one fails.

Sources (checked 2026-10-21):
- https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-disconnect (--force-local-only)
- https://learn.microsoft.com/azure/azure-arc/servers/uninstall-agent (remove extensions before disconnecting)
- https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-extension (local removal, extension manager stopped)
- https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-check
- https://learn.microsoft.com/powershell/module/hyper-v/set-vm (-AutomaticStartAction)
- https://learn.microsoft.com/powershell/module/hyper-v/disconnect-vmnetworkadapter
- https://learn.microsoft.com/azure/virtual-machines/instance-metadata-service (compute/vmId)

The last line of output is one compact JSON object; errors go to standard error. Exit code 0 means the
action succeeded.

.PARAMETER Action
Inspect, Prepare, Release, or RotateGuestPassword.

.PARAMETER SnapshotName
The golden snapshot's name, recorded by Prepare.

.PARAMETER Region
The Azure region for 'azcmagent check' (Release with ProveIsolation).

.PARAMETER ProveIsolation
'true' to prove from the guest that the Arc endpoints are unreachable before the reset (the boot test).

.PARAMETER KeepIsolated
'true' to leave the guest's adapter disconnected after the reset.

.PARAMETER SkipRotation
'true' to skip the guest password rotation in Release.
#>
[CmdletBinding()]
param(
    [string] $Action = 'Inspect',
    [string] $SnapshotName = '',
    [string] $Region = '',
    [string] $ProveIsolation = 'false',
    [string] $KeepIsolated = 'false',
    [string] $SkipRotation = 'false',
    [string] $GuestName = 'arcsql01',
    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:JwtPattern = 'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
$script:Notes = New-Object -TypeName 'System.Collections.Generic.List[string]'

function Add-GoldenNote {
    param([string] $Text)
    $script:Notes.Add($Text)
}

function Get-GoldenHostSetting {
    # The NAT switch and the guest administrator, from the installed bundle when present; defaults otherwise.
    [CmdletBinding()]
    param()

    $result = @{ SwitchName = 'DbHubDemoNat'; AdministratorName = 'Administrator'; ArcMarkerFile = 'arc-onboarded.json'; BundleSha256 = ''; RunnerSha256 = ''; Generation = ''; InstallMode = '' }
    $settingsPath = Join-Path -Path $script:Options.Root -ChildPath 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return $result
    }
    $settings = [System.IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
    foreach ($pair in @(@('bundleSha256', 'BundleSha256'), @('generation', 'Generation'), @('t2SqlInstallMode', 'InstallMode'))) {
        $property = $settings.PSObject.Properties[$pair[0]]
        if ($property) {
            $result[$pair[1]] = [string]$property.Value
        }
    }
    $workload = $settings.PSObject.Properties['workload']
    if ($workload -and $null -ne $workload.Value) {
        $runner = $workload.Value.PSObject.Properties['runnerSha256']
        if ($runner) {
            $result['RunnerSha256'] = [string]$runner.Value
        }
    }
    $bundlePath = $settings.PSObject.Properties['bundlePath']
    if ($bundlePath -and $bundlePath.Value) {
        $hostFile = [System.IO.Path]::Combine([string]$bundlePath.Value, 'vm', 'dsc', 'host.psd1')
        $guestFile = [System.IO.Path]::Combine([string]$bundlePath.Value, 'vm', 'dsc', 'guest.psd1')
        if (Test-Path -LiteralPath $hostFile -PathType Leaf) {
            $hostConfig = Import-PowerShellDataFile -Path $hostFile
            if ($hostConfig.SwitchName) { $result['SwitchName'] = [string]$hostConfig.SwitchName }
            if ($hostConfig.ArcMarkerFile) { $result['ArcMarkerFile'] = [string]$hostConfig.ArcMarkerFile }
        }
        if (Test-Path -LiteralPath $guestFile -PathType Leaf) {
            $guestConfig = Import-PowerShellDataFile -Path $guestFile
            if ($guestConfig.AdministratorName) { $result['AdministratorName'] = [string]$guestConfig.AdministratorName }
        }
    }
    return $result
}

function Get-GoldenImdsVmId {
    # The host's own Azure VM ID. The host can reach IMDS; only the guest is blocked from it (ADR 0004).
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $request = [System.Net.WebRequest]::Create('http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-02-01&format=text')
    $request.Headers.Add('Metadata', 'true')
    $request.Proxy = New-Object -TypeName 'System.Net.WebProxy'
    $request.Timeout = 10000
    $response = $request.GetResponse()
    try {
        $reader = New-Object -TypeName 'System.IO.StreamReader' -ArgumentList $response.GetResponseStream()
        return $reader.ReadToEnd().Trim()
    }
    finally {
        $response.Close()
    }
}

function Read-GoldenJson {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Write-GoldenJson {
    param([string] $Path, [object] $Value)
    $folder = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $temporary = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 6), (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-GoldenSecretPath {
    return [System.IO.Path]::Combine($script:Options.Root, 'protected', 'guest-administrator.bin')
}

function Unprotect-GoldenSecret {
    # DPAPI, LocalMachine scope, UTF-8: the format the host bootstrap writes (ADR 0009).
    param([string] $Path)
    Add-Type -AssemblyName 'System.Security'
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([System.IO.File]::ReadAllBytes($Path), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Protect-GoldenSecret {
    param([string] $Value, [string] $Path)
    Add-Type -AssemblyName 'System.Security'
    $protected = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($Value), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [System.IO.File]::WriteAllBytes($Path, $protected)
}

function ConvertTo-GoldenSecureString {
    param([string] $Text)
    $secure = New-Object -TypeName 'System.Security.SecureString'
    foreach ($character in $Text.ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    return $secure
}

function ConvertTo-GoldenCredential {
    param([string] $UserName, [securestring] $Secret)
    return (New-Object -TypeName 'System.Management.Automation.PSCredential' -ArgumentList $UserName, $Secret)
}

function Get-GoldenGuestCredential {
    param([string] $UserName)
    return (ConvertTo-GoldenCredential -UserName $UserName -Secret (ConvertTo-GoldenSecureString -Text (Unprotect-GoldenSecret -Path (Get-GoldenSecretPath))))
}

function Enter-GoldenLock {
    # The host bootstrap's own lock, so its scheduled run never touches the guest during a reset or a
    # password change; the run that finds it held exits and tries again 5 minutes later.
    param([int] $TimeoutSeconds = 900)
    $path = Join-Path -Path $script:Options.Root -ChildPath 'bootstrap.lock'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            return (New-Object -TypeName 'System.IO.FileStream' -ArgumentList @($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None))
        }
        catch {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw ('The host bootstrap held its lock for more than {0} seconds.' -f $TimeoutSeconds)
            }
            Start-Sleep -Seconds 10
        }
    }
}

function Get-GoldenRandomSecret {
    # 24 characters from a cryptographic generator, every class present, starting with a letter; the same
    # alphabet as the host bootstrap's guest password.
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $symbols = '#%*+-=?^_~'
    $all = $upper + $lower + $digits + $symbols
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = {
        param([string] $Set)
        $buffer = New-Object -TypeName 'byte[]' -ArgumentList 4
        $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$Set.Length)
        while ($true) {
            $generator.GetBytes($buffer)
            $value = [System.BitConverter]::ToUInt32($buffer, 0)
            if ($value -lt $limit) {
                return $Set[[int]($value % [uint32]$Set.Length)]
            }
        }
    }
    try {
        $chars = New-Object -TypeName 'System.Collections.Generic.List[char]'
        $chars.Add((& $pick ($upper + $lower)))
        foreach ($set in @($upper, $lower, $digits, $symbols)) {
            $chars.Add((& $pick $set))
            $chars.Add((& $pick $set))
        }
        while ($chars.Count -lt 24) {
            $chars.Add((& $pick $all))
        }
        return (-join $chars.ToArray())
    }
    finally {
        $generator.Dispose()
    }
}

function Test-GoldenGuestSession {
    param([pscredential] $Credential)
    try {
        $name = Invoke-Command -VMName $GuestName -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
        return [bool]$name
    }
    catch {
        return $false
    }
}

function Wait-GoldenGuest {
    # Waits for PowerShell Direct and returns the credential that signed in. A pending password left by a
    # rotation that stopped midway is tried too, and promoted when it's the one that works.
    param([string] $UserName, [int] $TimeoutSeconds = 900)
    $secretPath = Get-GoldenSecretPath
    $pendingPath = $secretPath + '.pending'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $main = Get-GoldenGuestCredential -UserName $UserName
        if (Test-GoldenGuestSession -Credential $main) {
            return [pscustomobject]@{ Credential = $main; Seconds = [int]$watch.Elapsed.TotalSeconds }
        }
        if (Test-Path -LiteralPath $pendingPath) {
            $pending = ConvertTo-GoldenCredential -UserName $UserName -Secret (ConvertTo-GoldenSecureString -Text (Unprotect-GoldenSecret -Path $pendingPath))
            if (Test-GoldenGuestSession -Credential $pending) {
                Move-Item -LiteralPath $pendingPath -Destination $secretPath -Force
                Add-GoldenNote 'A pending guest password from an earlier rotation was the one that worked, so it was promoted.'
                return [pscustomobject]@{ Credential = $pending; Seconds = [int]$watch.Elapsed.TotalSeconds }
            }
        }
        Start-Sleep -Seconds 10
    }
    throw ('The guest {0} did not answer over PowerShell Direct within {1} seconds.' -f $GuestName, $TimeoutSeconds)
}

function Get-GoldenAdapterState {
    $adapters = @(Get-VMNetworkAdapter -VMName $GuestName)
    $connected = @($adapters | Where-Object { [string]$_.SwitchName })
    return [ordered]@{ count = $adapters.Count; connected = $connected.Count; switches = @($connected | ForEach-Object { [string]$_.SwitchName }) }
}

function Connect-GoldenAdapter {
    param([string] $SwitchName)
    foreach ($adapter in @(Get-VMNetworkAdapter -VMName $GuestName)) {
        if (-not [string]$adapter.SwitchName) {
            Connect-VMNetworkAdapter -VMNetworkAdapter $adapter -SwitchName $SwitchName
        }
    }
}

function Disconnect-GoldenAdapter {
    foreach ($adapter in @(Get-VMNetworkAdapter -VMName $GuestName)) {
        if ([string]$adapter.SwitchName) {
            Disconnect-VMNetworkAdapter -VMNetworkAdapter $adapter
        }
    }
}

$script:GuestInspectBlock = {
    param($JwtPattern)
    $ErrorActionPreference = 'Continue'
    $result = [ordered]@{}
    $license = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" | Select-Object -First 1
    if ($license) {
        $minutes = [double]$license.GracePeriodRemaining
        $result['evaluationMinutesLeft'] = $minutes
        $result['evaluationExpiresUtc'] = [DateTime]::UtcNow.AddMinutes($minutes).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $result['licenseDescription'] = [string]$license.Description
        $result['licenseStatus'] = [int]$license.LicenseStatus
    }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $result['osCaption'] = [string]$os.Caption
    $service = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
    $result['sqlService'] = if ($service) { [string]$service.Status } else { 'Missing' }
    $result['sqlEdition'] = ''
    $serviceInfo = Get-CimInstance -ClassName Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction SilentlyContinue
    if ($serviceInfo) {
        $result['sqlStartMode'] = [string]$serviceInfo.StartMode
        $result['sqlDelayedStart'] = [bool]$serviceInfo.DelayedAutoStart
        $result['sqlServiceExitCode'] = [int]$serviceInfo.ExitCode
    }
    if ($service -and [string]$service.Status -ne 'Running') {
        # Why it isn't running: the service control manager's events, SQL Server's errors, and its error log's end.
        $since = (Get-Date).AddHours(-24)
        $scm = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = $since } -MaxEvents 500 -ErrorAction SilentlyContinue | Where-Object { [string]$_.Message -match 'MSSQLSERVER' } | Select-Object -First 3)
        $result['sqlServiceEvents'] = @($scm | ForEach-Object { $text = ([string]$_.Message -replace '\s+', ' '); '{0} {1} {2}' -f $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $_.Id, $text.Substring(0, [Math]::Min(140, $text.Length)) })
        $sqlErrors = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MSSQLSERVER'; StartTime = $since; Level = 1, 2 } -MaxEvents 3 -ErrorAction SilentlyContinue)
        $result['sqlErrorEvents'] = @($sqlErrors | ForEach-Object { $text = ([string]$_.Message -replace '\s+', ' '); '{0} {1} {2}' -f $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $_.Id, $text.Substring(0, [Math]::Min(140, $text.Length)) })
        $errorLog = Get-Item -Path (Join-Path -Path $env:ProgramFiles -ChildPath 'Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\Log\ERRORLOG') -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($errorLog) {
            $result['sqlErrorLogUtc'] = $errorLog.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
            $result['sqlErrorLogTail'] = @(Get-Content -LiteralPath $errorLog.FullName -Tail 4 -ErrorAction SilentlyContinue | ForEach-Object { $line = [string]$_; $line.Substring(0, [Math]::Min(140, $line.Length)) })
        }
    }
    if ($service -and [string]$service.Status -eq 'Running') {
        try {
            $connection = New-Object -TypeName 'System.Data.SqlClient.SqlConnection' -ArgumentList 'Server=.;Database=master;Integrated Security=SSPI;Connect Timeout=20'
            $connection.Open()
            $command = $connection.CreateCommand()
            $command.CommandText = "SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)), CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(64)), CAST(ISNULL(SERVERPROPERTY('ProductUpdateLevel'), '') AS nvarchar(64)), CAST(ISNULL(SERVERPROPERTY('ProductUpdateReference'), '') AS nvarchar(64)), (SELECT COUNT(*) FROM sys.databases WHERE name = N'ContosoCare')"
            $reader = $command.ExecuteReader()
            if ($reader.Read()) {
                $result['sqlEdition'] = [string]$reader.GetValue(0)
                $result['sqlVersion'] = [string]$reader.GetValue(1)
                $result['sqlLevel'] = [string]$reader.GetValue(2)
                $result['sqlUpdateLevel'] = [string]$reader.GetValue(3)
                $result['sqlUpdateReference'] = [string]$reader.GetValue(4)
                $result['contosoCare'] = [int]$reader.GetValue(5)
            }
            $reader.Close()
            $connection.Close()
        }
        catch {
            $result['sqlError'] = ([string]$_.Exception.Message).Substring(0, [Math]::Min(200, ([string]$_.Exception.Message).Length))
        }
    }
    $exe = Join-Path -Path $env:ProgramFiles -ChildPath 'AzureConnectedMachineAgent\azcmagent.exe'
    $result['agentInstalled'] = Test-Path -LiteralPath $exe
    $result['agentJson'] = ''
    if ($result['agentInstalled']) {
        $result['agentJson'] = ((& $exe show -j 2>$null) | ForEach-Object { [string]$_ }) -join "`n"
        $extensions = ((& $exe extension list 2>$null) | ForEach-Object { [string]$_ }) -join "`n"
        $result['extensionListLength'] = $extensions.Length
    }
    $logFiles = @()
    $sqlRoot = Join-Path -Path $env:ProgramFiles -ChildPath 'Microsoft SQL Server'
    if (Test-Path -LiteralPath $sqlRoot) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $sqlRoot -Directory -ErrorAction SilentlyContinue)) {
            $log = Join-Path -Path $folder.FullName -ChildPath 'Setup Bootstrap\Log'
            if (Test-Path -LiteralPath $log) {
                $logFiles += @(Get-ChildItem -LiteralPath $log -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.xml', '.txt', '.log', '.ini', '.json' })
            }
        }
    }
    $withToken = @($logFiles | Where-Object { Select-String -LiteralPath $_.FullName -Pattern $JwtPattern -Quiet -ErrorAction SilentlyContinue })
    $result['setupLogFiles'] = $logFiles.Count
    $result['setupLogFilesWithToken'] = $withToken.Count
    $caches = @()
    foreach ($userFolder in @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
        $local = Join-Path -Path $userFolder.FullName -ChildPath 'AppData\Local'
        if (-not (Test-Path -LiteralPath $local)) {
            continue
        }
        $caches += @(Get-ChildItem -LiteralPath $local -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'EBWebView' -or $_.Name -eq '.IdentityService' } | ForEach-Object { $_.FullName })
        $caches += @(Get-ChildItem -LiteralPath $local -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'msal*cache*' } | ForEach-Object { $_.FullName })
    }
    $result['signInCaches'] = @($caches | Select-Object -Unique)
    $esc = [ordered]@{}
    foreach ($pair in @(@('administrators', '{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'), @('users', '{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}'))) {
        $key = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\' + $pair[1]
        $value = $null
        if (Test-Path -LiteralPath $key) {
            $value = (Get-ItemProperty -LiteralPath $key -Name 'IsInstalled' -ErrorAction SilentlyContinue).IsInstalled
        }
        $esc[$pair[0]] = $value
    }
    $result['ieEsc'] = $esc
    $task = Get-ScheduledTask -TaskName 'DbHubDemo-Workload' -ErrorAction SilentlyContinue
    $result['workloadTask'] = if ($task) { [string]$task.State } else { 'Missing' }
    [pscustomobject]$result
}

$script:GuestCleanBlock = {
    # Removes the sign-in data that setup leaves on the VM (the caches and token-shaped values), and turns IE ESC on.
    param($JwtPattern, $Caches)
    $ErrorActionPreference = 'Continue'
    $removed = 0
    foreach ($path in @($Caches)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $path)) {
                $removed++
            }
        }
    }
    $redacted = 0
    $sqlRoot = Join-Path -Path $env:ProgramFiles -ChildPath 'Microsoft SQL Server'
    if (Test-Path -LiteralPath $sqlRoot) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $sqlRoot -Directory -ErrorAction SilentlyContinue)) {
            $log = Join-Path -Path $folder.FullName -ChildPath 'Setup Bootstrap\Log'
            if (-not (Test-Path -LiteralPath $log)) {
                continue
            }
            foreach ($file in @(Get-ChildItem -LiteralPath $log -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.xml', '.txt', '.log', '.ini', '.json' })) {
                $text = [System.IO.File]::ReadAllText($file.FullName)
                if ($text -match $JwtPattern) {
                    [System.IO.File]::WriteAllText($file.FullName, ([regex]::Replace($text, $JwtPattern, '[REDACTED]')))
                    $redacted++
                }
            }
        }
    }
    foreach ($id in @('{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}', '{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}')) {
        $key = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\' + $id
        if ((Test-Path -LiteralPath $key) -and (Get-ItemProperty -LiteralPath $key -Name 'IsInstalled' -ErrorAction SilentlyContinue).IsInstalled -ne 1) {
            Set-ItemProperty -LiteralPath $key -Name 'IsInstalled' -Value 1
        }
    }
    [pscustomobject]@{ cachesRemoved = $removed; logFilesRedacted = $redacted }
}

$script:GuestAgentBlock = {
    # Only the Arc agent's state, for the wait until 'azcmagent show -j' can be read.
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path -Path $env:ProgramFiles -ChildPath 'AzureConnectedMachineAgent\azcmagent.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{ installed = $false; json = '' }
    }
    [pscustomobject]@{ installed = $true; json = (((& $exe show -j 2>$null) | ForEach-Object { [string]$_ }) -join "`n") }
}

$script:GuestResetBlock = {
    # Local only: works with the guest's adapter disconnected.
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path -Path $env:ProgramFiles -ChildPath 'AzureConnectedMachineAgent\azcmagent.exe'
    $steps = @()
    $service = Get-Service -Name 'ExtensionService' -ErrorAction SilentlyContinue
    if ($service -and [string]$service.Status -ne 'Stopped') {
        Stop-Service -Name 'ExtensionService' -Force -ErrorAction SilentlyContinue
        $steps += 'ExtensionService stopped'
    }
    $removeOutput = ((& $exe extension remove --all 2>&1) | ForEach-Object { [string]$_ }) -join ' '
    $removeCode = $LASTEXITCODE
    $steps += ('extension remove --all exited {0}' -f $removeCode)
    $disconnectOutput = ((& $exe disconnect --force-local-only 2>&1) | ForEach-Object { [string]$_ }) -join ' '
    $disconnectCode = $LASTEXITCODE
    $steps += ('disconnect --force-local-only exited {0}' -f $disconnectCode)
    if ($service) {
        Start-Service -Name 'ExtensionService' -ErrorAction SilentlyContinue
    }
    $after = ((& $exe show -j 2>$null) | ForEach-Object { [string]$_ }) -join "`n"
    [pscustomobject]@{
        steps            = $steps
        removeExitCode   = $removeCode
        disconnectCode   = $disconnectCode
        removeOutput     = $removeOutput.Substring(0, [Math]::Min(300, $removeOutput.Length))
        disconnectOutput = $disconnectOutput.Substring(0, [Math]::Min(300, $disconnectOutput.Length))
        agentJsonAfter   = $after
    }
}

$script:GuestSqlWaitBlock = {
    # SQL Server starts with a delayed automatic start, which a cold-booted guest can take ten minutes to reach
    # (live, 2026-10-22). Waits for it, and starts it once after StartAfterSeconds if it's still stopped.
    param($TimeoutSeconds, $StartAfterSeconds)
    $ErrorActionPreference = 'Continue'
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $false
    while ($clock.Elapsed.TotalSeconds -lt [int]$TimeoutSeconds) {
        $service = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
        if (-not $service -or [string]$service.Status -eq 'Running') {
            break
        }
        if (-not $started -and $clock.Elapsed.TotalSeconds -ge [int]$StartAfterSeconds -and [string]$service.Status -eq 'Stopped') {
            Start-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
            $started = $true
        }
        Start-Sleep -Seconds 10
    }
    $final = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
    [pscustomobject]@{ status = $(if ($final) { [string]$final.Status } else { 'Missing' }); seconds = [int]$clock.Elapsed.TotalSeconds; startedByScript = $started }
}

$script:GuestIsolationBlock = {
    # Proves from the guest that the Arc endpoints are unreachable: azcmagent check, plus direct TCP tests.
    param($RegionName)
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path -Path $env:ProgramFiles -ChildPath 'AzureConnectedMachineAgent\azcmagent.exe'
    $checkText = ''
    $checkCode = $null
    if ($RegionName -and (Test-Path -LiteralPath $exe)) {
        $checkText = ((& $exe check --location $RegionName --extensions sql 2>&1) | ForEach-Object { [string]$_ }) -join "`n"
        $checkCode = $LASTEXITCODE
    }
    $hosts = @('gbl.his.arc.azure.com', 'agentserviceapi.guestconfiguration.azure.com', 'login.microsoftonline.com', 'management.azure.com', 'pas.windows.net', 'download.microsoft.com')
    if ($RegionName) {
        $hosts += @(('{0}-gas.guestconfiguration.azure.com' -f $RegionName), ('telemetry.{0}.arcdataservices.com' -f $RegionName))
    }
    $reachable = @()
    foreach ($name in $hosts) {
        $client = New-Object -TypeName 'System.Net.Sockets.TcpClient'
        try {
            $attempt = $client.BeginConnect($name, 443, $null, $null)
            if ($attempt.AsyncWaitHandle.WaitOne(5000) -and $client.Connected) {
                $reachable += $name
            }
        }
        catch {
            $null = $_
        }
        finally {
            $client.Close()
        }
    }
    $checkReachable = @()
    foreach ($line in @($checkText -split "`n")) {
        # The table's columns are ENDPOINT | REACHABLE | PRIVATE | TLS | PROXY.
        $cells = @($line -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -ge 2 -and $cells[0] -match '([a-z0-9-]+\.)+[a-z]{2,}' -and $cells[1] -eq 'true') {
            $checkReachable += $cells[0]
        }
    }
    [pscustomobject]@{
        tested           = $hosts
        reachable        = $reachable
        checkExitCode    = $checkCode
        checkReachable   = @($checkReachable | Select-Object -Unique)
        checkTextLength  = $checkText.Length
        checkSample      = $checkText.Substring(0, [Math]::Min(600, $checkText.Length))
    }
}

function ConvertFrom-GoldenAgentJson {
    # The agent identity from 'azcmagent show -j'. Key names beyond status vary by version, so several are tried.
    param([string] $Text)
    $agent = [ordered]@{ status = ''; resourceName = ''; resourceGroup = ''; subscriptionId = ''; vmId = ''; keys = @() }
    if (-not $Text) {
        return $agent
    }
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) {
        return $agent
    }
    try {
        $parsed = $Text.Substring($start, $end - $start + 1) | ConvertFrom-Json
    }
    catch {
        return $agent
    }
    $agent.keys = @($parsed.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $lookup = @{ status = @('status', 'agentStatus'); resourceName = @('resourceName'); resourceGroup = @('resourceGroup', 'resourceGroupName'); subscriptionId = @('subscriptionId'); vmId = @('vmId', 'vmUuid') }
    foreach ($key in @($lookup.Keys)) {
        foreach ($candidate in $lookup[$key]) {
            $property = $parsed.PSObject.Properties[$candidate]
            if ($property -and -not $agent[$key] -and $null -ne $property.Value) {
                $agent[$key] = [string]$property.Value
            }
        }
    }
    return $agent
}

function Get-GoldenResetDecision {
    # Whether a restored copy's guest is reset before it reaches the network. Reset unless the agent names an
    # identity other than the captured one: an air-gapped agent can answer 'azcmagent show -j' with a status
    # (live, 2026-10-23: "failed") and no resource while it still holds the captured identity, so naming nothing
    # never proves there's nothing to reset. Returns Action (Reset or Skip) and Reason (CapturedIdentity,
    # IdentityUnknown, OtherIdentity, or NoCapturedIdentity).
    param($Agent, $Capture)
    $capturedName = [string]$Capture.arcResourceName
    $capturedGroup = [string]$Capture.arcResourceGroup
    $name = [string]$Agent.resourceName
    if ($capturedName -and $name -and [string]::Equals($name, $capturedName, [System.StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$Agent.resourceGroup, $capturedGroup, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Action = 'Reset'; Reason = 'CapturedIdentity' }
    }
    if ($name) {
        return [pscustomobject]@{ Action = 'Skip'; Reason = 'OtherIdentity' }
    }
    if ($capturedName) {
        return [pscustomobject]@{ Action = 'Reset'; Reason = 'IdentityUnknown' }
    }
    return [pscustomobject]@{ Action = 'Skip'; Reason = 'NoCapturedIdentity' }
}

function Read-GoldenAgentState {
    # The guest's Arc agent state, read until 'azcmagent show -j' answers with a status. Right after a cold boot
    # the agent's HIMDS service isn't up yet and the command prints no JSON, which must never be taken for "no
    # identity" (live, 2026-10-22: a restored copy's Release read nothing and skipped the reset). Poll-count
    # bounded. Returns installed, readable, seconds, and agent (ConvertFrom-GoldenAgentJson).
    param(
        [System.Management.Automation.PSCredential] $Credential,
        [int] $TimeoutSeconds = 300,
        [int] $PollSeconds = 10
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $polls = [Math]::Max(1, [int][Math]::Ceiling($TimeoutSeconds / [double][Math]::Max(1, $PollSeconds)))
    for ($poll = 1; $poll -le $polls; $poll++) {
        $probe = Invoke-Command -VMName $GuestName -Credential $Credential -ScriptBlock $script:GuestAgentBlock -ErrorAction Stop
        if (-not $probe.installed) {
            return [pscustomobject]@{ installed = $false; readable = $true; seconds = [int]$watch.Elapsed.TotalSeconds; agent = (ConvertFrom-GoldenAgentJson -Text '') }
        }
        $agent = ConvertFrom-GoldenAgentJson -Text ([string]$probe.json)
        if ($agent.status) {
            return [pscustomobject]@{ installed = $true; readable = $true; seconds = [int]$watch.Elapsed.TotalSeconds; agent = $agent }
        }
        if ($poll -lt $polls) {
            Start-Sleep -Seconds $PollSeconds
        }
    }
    return [pscustomobject]@{ installed = $true; readable = $false; seconds = [int]$watch.Elapsed.TotalSeconds; agent = (ConvertFrom-GoldenAgentJson -Text '') }
}

function Get-GoldenHostFact {
    param([hashtable] $Setting)
    $facts = [ordered]@{}
    try {
        $facts['azureVmId'] = Get-GoldenImdsVmId
    }
    catch {
        $facts['azureVmId'] = ''
        Add-GoldenNote ('IMDS could not be read: {0}' -f $_.Exception.Message)
    }
    $health = Read-GoldenJson -Path (Join-Path -Path $script:Options.Root -ChildPath 'health.json')
    $facts['hostState'] = if ($health -and $health.PSObject.Properties['state']) { [string]$health.state } else { '' }
    $facts['bundleSha256'] = $Setting['BundleSha256']
    $facts['runnerSha256'] = $Setting['RunnerSha256']
    $facts['generation'] = $Setting['Generation']
    $facts['installMode'] = $Setting['InstallMode']
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
    $facts['usedGiB'] = [Math]::Round(([double]$disk.Size - [double]$disk.FreeSpace) / 1GB, 1)
    $facts['sizeGiB'] = [Math]::Round([double]$disk.Size / 1GB, 1)
    $administrator = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-21-*-500' } | Select-Object -First 1
    $facts['administratorPasswordLastSetUtc'] = if ($administrator -and $administrator.PasswordLastSet) { $administrator.PasswordLastSet.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }
    $facts['productKeyFile'] = Test-Path -LiteralPath ([System.IO.Path]::Combine($script:Options.Root, 'protected', 'sql-product-key.bin'))
    $capturePath = [System.IO.Path]::Combine($script:Options.Root, 'golden', 'capture.json')
    $capture = Read-GoldenJson -Path $capturePath
    $facts['captureRecord'] = $null -ne $capture
    $marker = Read-GoldenJson -Path (Join-Path -Path $script:Options.Root -ChildPath $Setting['ArcMarkerFile'])
    $facts['arcMarker'] = if ($marker -and $marker.PSObject.Properties['status']) { [string]$marker.status } else { '' }
    $vm = Get-VM -Name $GuestName -ErrorAction SilentlyContinue
    if ($vm) {
        $facts['guestState'] = [string]$vm.State
        $facts['guestStartAction'] = [string]$vm.AutomaticStartAction
        $facts['guestHyperVId'] = [string]$vm.VMId
        $facts['guestAdapter'] = Get-GoldenAdapterState
    }
    else {
        $facts['guestState'] = 'Missing'
    }
    return $facts
}

function Invoke-GoldenInspect {
    param([hashtable] $Setting)
    $result = [ordered]@{ action = 'Inspect'; succeeded = $false }
    $result['host'] = Get-GoldenHostFact -Setting $Setting
    if ($result['host']['guestState'] -ne 'Running') {
        Add-GoldenNote 'The guest is not running, so nothing was read inside it.'
        $result['succeeded'] = $true
        return $result
    }
    $credential = (Wait-GoldenGuest -UserName $Setting['AdministratorName'] -TimeoutSeconds 120).Credential
    $guest = Invoke-Command -VMName $GuestName -Credential $credential -ScriptBlock $script:GuestInspectBlock -ArgumentList $script:JwtPattern -ErrorAction Stop
    $agent = ConvertFrom-GoldenAgentJson -Text ([string]$guest.agentJson)
    $summary = [ordered]@{}
    foreach ($name in @('evaluationExpiresUtc', 'evaluationMinutesLeft', 'licenseDescription', 'osCaption', 'sqlService', 'sqlStartMode', 'sqlDelayedStart', 'sqlServiceExitCode', 'sqlServiceEvents', 'sqlErrorEvents', 'sqlErrorLogUtc', 'sqlErrorLogTail', 'sqlEdition', 'sqlVersion', 'sqlLevel', 'sqlUpdateLevel', 'sqlUpdateReference', 'contosoCare', 'sqlError', 'agentInstalled', 'setupLogFiles', 'setupLogFilesWithToken', 'ieEsc', 'workloadTask')) {
        $property = $guest.PSObject.Properties[$name]
        if ($property) {
            $summary[$name] = $property.Value
        }
    }
    $summary['signInCacheCount'] = @($guest.signInCaches).Count
    $summary['signInCaches'] = @(@($guest.signInCaches) | Select-Object -First 4 | ForEach-Object { if ($_.Length -gt 90) { '...' + $_.Substring($_.Length - 87) } else { $_ } })
    $summary['agent'] = $agent
    $result['guest'] = $summary
    $result['succeeded'] = $true
    return $result
}

function Invoke-GoldenPrepare {
    param([hashtable] $Setting)
    if ($script:Options.SnapshotName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
        throw 'Prepare needs a valid SnapshotName.'
    }
    $result = [ordered]@{ action = 'Prepare'; succeeded = $false }
    $hostFacts = Get-GoldenHostFact -Setting $Setting
    if ($hostFacts['guestState'] -ne 'Running') {
        throw ('The guest is {0}; Prepare reads and cleans it, so it must be running.' -f $hostFacts['guestState'])
    }
    if (-not $hostFacts['azureVmId']) {
        throw 'The host''s Azure VM ID could not be read from IMDS, so the capture record would be incomplete.'
    }
    $credential = (Wait-GoldenGuest -UserName $Setting['AdministratorName'] -TimeoutSeconds 300).Credential
    $before = Invoke-Command -VMName $GuestName -Credential $credential -ScriptBlock $script:GuestInspectBlock -ArgumentList $script:JwtPattern -ErrorAction Stop
    $clean = Invoke-Command -VMName $GuestName -Credential $credential -ScriptBlock $script:GuestCleanBlock -ArgumentList $script:JwtPattern, @($before.signInCaches) -ErrorAction Stop
    $after = Invoke-Command -VMName $GuestName -Credential $credential -ScriptBlock $script:GuestInspectBlock -ArgumentList $script:JwtPattern -ErrorAction Stop
    $result['cachesRemoved'] = [int]$clean.cachesRemoved
    $result['logFilesRedacted'] = [int]$clean.logFilesRedacted
    $result['signInCachesLeft'] = @($after.signInCaches).Count
    $result['setupLogFilesWithToken'] = [int]$after.setupLogFilesWithToken
    $result['ieEsc'] = $after.ieEsc
    if ($result['signInCachesLeft'] -gt 0 -or $result['setupLogFilesWithToken'] -gt 0) {
        throw ('Sign-in residue is left in the guest ({0} cache(s), {1} log file(s) with a token); nothing was captured.' -f $result['signInCachesLeft'], $result['setupLogFilesWithToken'])
    }
    if ([string]$after.sqlEdition -notmatch 'Standard') {
        throw ('SQL Server in the guest reports edition ''{0}'', not Standard; nothing was captured.' -f [string]$after.sqlEdition)
    }
    $agent = ConvertFrom-GoldenAgentJson -Text ([string]$after.agentJson)
    $record = [ordered]@{
        schemaVersion        = 1
        snapshotName         = $script:Options.SnapshotName
        capturedUtc          = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        sourceAzureVmId      = $hostFacts['azureVmId']
        guestHyperVId        = $hostFacts['guestHyperVId']
        arcResourceName      = $agent.resourceName
        arcResourceGroup     = $agent.resourceGroup
        arcSubscriptionId    = $agent.subscriptionId
        arcVmId              = $agent.vmId
        evaluationExpiresUtc = [string]$after.evaluationExpiresUtc
        released             = $false
    }
    Write-GoldenJson -Path ([System.IO.Path]::Combine($script:Options.Root, 'golden', 'capture.json')) -Value $record
    Set-VM -Name $GuestName -AutomaticStartAction Nothing
    Disconnect-GoldenAdapter
    $result['airGap'] = [ordered]@{ startAction = [string](Get-VM -Name $GuestName).AutomaticStartAction; adapter = Get-GoldenAdapterState }
    # A guest operating system shutdown through the Hyper-V shutdown integration service; -Force only skips
    # the prompt a signed-in session would raise (the same call as Invoke-DemoWorkloadControl.ps1 StopGuest).
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    Stop-VM -Name $GuestName -Force -AsJob | Out-Null
    while ($clock.Elapsed.TotalMinutes -lt 15 -and [string](Get-VM -Name $GuestName).State -ne 'Off') {
        Start-Sleep -Seconds 5
    }
    $state = [string](Get-VM -Name $GuestName).State
    $result['guestState'] = $state
    $result['guestShutdownSeconds'] = [int]$clock.Elapsed.TotalSeconds
    if ($state -ne 'Off') {
        throw ('The guest did not shut down cleanly within 15 minutes (state {0}); it was not turned off by force.' -f $state)
    }
    $result['record'] = $record
    $result['succeeded'] = $true
    return $result
}

$script:GuestSetSecretBlock = {
    # The SecureString crosses PowerShell Direct encrypted with the session key.
    param($AccountName, $Secret)
    Set-LocalUser -Name $AccountName -Password $Secret
}

function Invoke-GoldenPasswordRotation {
    # Pending first, then the guest, then a new session proves it, then the pending value is promoted. The
    # caller has already proven the current credential with Wait-GoldenGuest, which also finishes a rotation
    # that stopped midway.
    param([hashtable] $Setting)
    $secretPath = Get-GoldenSecretPath
    $pendingPath = $secretPath + '.pending'
    $user = $Setting['AdministratorName']
    $oldSecret = ConvertTo-GoldenSecureString -Text (Unprotect-GoldenSecret -Path $secretPath)
    $session = New-PSSession -VMName $GuestName -Credential (ConvertTo-GoldenCredential -UserName $user -Secret $oldSecret) -ErrorAction Stop
    try {
        $newText = Get-GoldenRandomSecret
        Protect-GoldenSecret -Value $newText -Path $pendingPath
        $newSecret = ConvertTo-GoldenSecureString -Text $newText
        $newText = $null
        Invoke-Command -Session $session -ScriptBlock $script:GuestSetSecretBlock -ArgumentList $user, $newSecret -ErrorAction Stop
        if (Test-GoldenGuestSession -Credential (ConvertTo-GoldenCredential -UserName $user -Secret $newSecret)) {
            Move-Item -LiteralPath $pendingPath -Destination $secretPath -Force
            return 'Rotated'
        }
        Invoke-Command -Session $session -ScriptBlock $script:GuestSetSecretBlock -ArgumentList $user, $oldSecret -ErrorAction Stop
        Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
        throw 'The new guest password could not sign in, so the old one was set back.'
    }
    finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

function Invoke-GoldenRelease {
    param([hashtable] $Setting)
    $result = [ordered]@{ action = 'Release'; succeeded = $false }
    $capturePath = [System.IO.Path]::Combine($script:Options.Root, 'golden', 'capture.json')
    $capture = Read-GoldenJson -Path $capturePath
    $vm = Get-VM -Name $GuestName -ErrorAction Stop
    if ($null -eq $capture) {
        $result['captured'] = $false
        $result['guestState'] = [string]$vm.State
        $result['adapter'] = Get-GoldenAdapterState
        $result['succeeded'] = $true
        return $result
    }
    $result['captured'] = $true
    $result['snapshotName'] = [string]$capture.snapshotName
    $azureVmId = Get-GoldenImdsVmId
    $isSource = [string]::Equals($azureVmId, [string]$capture.sourceAzureVmId, [System.StringComparison]::OrdinalIgnoreCase)
    $result['role'] = if ($isSource) { 'Source' } else { 'Copy' }
    $alreadyReset = $capture.PSObject.Properties['resetUtc'] -and [string]$capture.resetUtc

    if (-not $isSource -and -not $alreadyReset) {
        if ([string]$vm.State -ne 'Running') {
            Start-VM -Name $GuestName
        }
        $wait = Wait-GoldenGuest -UserName $Setting['AdministratorName'] -TimeoutSeconds 1200
        $credential = $wait.Credential
        $result['guestBootSeconds'] = $wait.Seconds
        if ($script:Options.ProveIsolation) {
            Connect-GoldenAdapter -SwitchName $Setting['SwitchName']
            Start-Sleep -Seconds 20
            $isolation = Invoke-Command -VMName $GuestName -Credential $credential -ScriptBlock $script:GuestIsolationBlock -ArgumentList $Region -ErrorAction Stop
            $result['isolation'] = [ordered]@{ tested = @($isolation.tested).Count; reachable = @($isolation.reachable); checkExitCode = $isolation.checkExitCode; checkReachable = @($isolation.checkReachable); checkSample = ([string]$isolation.checkSample).Substring(0, [Math]::Min(300, ([string]$isolation.checkSample).Length)) }
            if (@($isolation.reachable).Count -gt 0 -or @($isolation.checkReachable).Count -gt 0) {
                Disconnect-GoldenAdapter
                throw ('Isolation failed: {0} answered from the guest; nothing was reset, and the guest''s adapter is disconnected again.' -f ((@($isolation.reachable) + @($isolation.checkReachable) | Select-Object -Unique) -join ', '))
            }
        }
        $state = Read-GoldenAgentState -Credential $credential
        $agent = $state.agent
        $result['agentBefore'] = [ordered]@{ status = $agent.status; resourceName = $agent.resourceName; resourceGroup = $agent.resourceGroup; installed = $state.installed; readSeconds = $state.seconds }
        if (-not $state.readable) {
            Disconnect-GoldenAdapter
            throw ('The guest''s Arc agent didn''t report its state within {0} seconds (azcmagent show -j), so it can''t be told whether the copy still holds the captured identity. Nothing was released, and the guest stays air-gapped; run the release again.' -f $state.seconds)
        }
        $decision = Get-GoldenResetDecision -Agent $agent -Capture $capture
        $result['resetDecision'] = $decision.Reason
        if ($decision.Action -eq 'Reset') {
            $reset = Invoke-Command -VMName $GuestName -Credential $credential -ScriptBlock $script:GuestResetBlock -ErrorAction Stop
            $after = ConvertFrom-GoldenAgentJson -Text ([string]$reset.agentJsonAfter)
            $result['reset'] = [ordered]@{ reason = $decision.Reason; steps = @($reset.steps); removeExitCode = $reset.removeExitCode; disconnectExitCode = $reset.disconnectCode; agentAfter = [ordered]@{ status = $after.status; resourceName = $after.resourceName } }
            if ($after.resourceName) {
                throw ('The agent still names {0} after azcmagent disconnect --force-local-only: {1}' -f $after.resourceName, [string]$reset.disconnectOutput)
            }
        }
        elseif ($decision.Reason -eq 'OtherIdentity') {
            Add-GoldenNote ('The agent names {0} in {1}, not the captured identity, so it was not reset.' -f $agent.resourceName, $agent.resourceGroup)
            $result['reset'] = 'SkippedOtherIdentity'
        }
        else {
            $result['reset'] = 'SkippedNoIdentity'
        }
        $markerPath = Join-Path -Path $script:Options.Root -ChildPath $Setting['ArcMarkerFile']
        if (Test-Path -LiteralPath $markerPath) {
            Move-Item -LiteralPath $markerPath -Destination ('{0}.reset-{1}' -f $markerPath, [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')) -Force
            $result['markerRenamed'] = $true
        }
        # A cold-booted guest reaches SQL Server's delayed automatic start only after about ten minutes, so it's
        # started right away (live, 2026-10-22); starting a service that's already starting does no harm.
        $sqlWait = Invoke-Command -VMName $GuestName -Credential $credential -ScriptBlock $script:GuestSqlWaitBlock -ArgumentList 900, 0 -ErrorAction Stop
        $result['sqlWait'] = [ordered]@{ status = [string]$sqlWait.status; seconds = [int]$sqlWait.seconds; startedByScript = [bool]$sqlWait.startedByScript }
        $inspect = Invoke-Command -VMName $GuestName -Credential $credential -ScriptBlock $script:GuestInspectBlock -ArgumentList $script:JwtPattern -ErrorAction Stop
        $result['sqlEdition'] = [string]$inspect.sqlEdition
        $result['sqlService'] = [string]$inspect.sqlService
        if ([string]$inspect.sqlService -ne 'Running' -or [string]$inspect.sqlEdition -notmatch 'Standard') {
            throw ('SQL Server in the restored guest is {0} with edition ''{1}'', not a running Standard edition.' -f [string]$inspect.sqlService, [string]$inspect.sqlEdition)
        }
        if (-not $script:Options.SkipRotation) {
            $result['guestPassword'] = Invoke-GoldenPasswordRotation -Setting $Setting
        }
        $capture | Add-Member -NotePropertyName 'resetUtc' -NotePropertyValue ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
        $capture | Add-Member -NotePropertyName 'resetOnAzureVmId' -NotePropertyValue $azureVmId -Force
        Write-GoldenJson -Path $capturePath -Value $capture
    }

    if (-not $script:Options.KeepIsolated) {
        Connect-GoldenAdapter -SwitchName $Setting['SwitchName']
        Set-VM -Name $GuestName -AutomaticStartAction Start -AutomaticStartDelay 0
        if ([string](Get-VM -Name $GuestName).State -ne 'Running') {
            Start-VM -Name $GuestName
        }
        $capture | Add-Member -NotePropertyName 'released' -NotePropertyValue $true -Force
        $capture | Add-Member -NotePropertyName 'releasedUtc' -NotePropertyValue ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
        Write-GoldenJson -Path $capturePath -Value $capture
    }
    $final = Get-VM -Name $GuestName
    $result['guestState'] = [string]$final.State
    $result['startAction'] = [string]$final.AutomaticStartAction
    $result['adapter'] = Get-GoldenAdapterState
    $result['succeeded'] = $true
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        if ($Action -notin 'Inspect', 'Prepare', 'Release', 'RotateGuestPassword') {
            throw ('Unknown action {0}.' -f $Action)
        }
        if ($GuestName -notmatch '^[A-Za-z0-9-]{1,15}$') {
            throw 'GuestName is not valid.'
        }
        if ($Region -and $Region -notmatch '^[a-z0-9]{2,40}$') {
            throw 'Region is not valid.'
        }
        $script:Options = @{
            Root           = $Root
            SnapshotName   = $SnapshotName
            ProveIsolation = ($ProveIsolation -eq 'true')
            KeepIsolated   = ($KeepIsolated -eq 'true')
            SkipRotation   = ($SkipRotation -eq 'true')
        }
        $setting = Get-GoldenHostSetting
        $lock = $null
        if ($Action -ne 'Inspect') {
            $lock = Enter-GoldenLock
        }
        try {
            $outcome = switch ($Action) {
                'Inspect' { Invoke-GoldenInspect -Setting $setting }
                'Prepare' { Invoke-GoldenPrepare -Setting $setting }
                'Release' { Invoke-GoldenRelease -Setting $setting }
                'RotateGuestPassword' {
                    $null = Wait-GoldenGuest -UserName $setting['AdministratorName'] -TimeoutSeconds 300
                    [ordered]@{ action = 'RotateGuestPassword'; outcome = (Invoke-GoldenPasswordRotation -Setting $setting); succeeded = $true }
                }
            }
        }
        finally {
            if ($null -ne $lock) {
                $lock.Dispose()
            }
        }
        $outcome['notes'] = @($script:Notes)
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $outcome -Compress -Depth 6))
        if ($outcome['succeeded']) {
            $exitCode = 0
        }
    }
    catch {
        $message = [string]$_.Exception.Message
        $message = [regex]::Replace($message, $script:JwtPattern, '[REDACTED]')
        [Console]::Error.WriteLine('DbHubDemo golden ' + $Action + ' failed: ' + $message)
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([ordered]@{ action = $Action; succeeded = $false; error = $message; notes = @($script:Notes) }) -Compress -Depth 4))
    }
    exit $exitCode
}
