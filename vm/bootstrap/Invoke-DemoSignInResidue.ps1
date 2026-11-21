<#
.SYNOPSIS
Finds and removes sign-in data left on a demo VM and in the T2 guest, and verifies that none remains
(ADR 0009). It reports counts and locations only, never a value.

.DESCRIPTION
Windows PowerShell 5.1, ASCII-only, self-contained: it needs no function from the installed bootstrap
bundle, so the orchestrator can send it in a managed Run Command to any VM (sqlvm01, archost01, or the
evaluation-only arcsql01), including a host restored from a golden snapshot with an older bundle; only a
guest sweep's recovery (below) uses the bundle's, when the bundle has it. The host
bootstrap and the evaluation-only bootstrap dot-source it for their sign-in cleanup step; dot-sourcing only
defines the functions.

What it looks for: values shaped like access tokens (three base64url segments starting with eyJ, and
JSON properties named like access, refresh, or ID tokens), values shaped like a product key (five groups of
five letters or digits, which a Run Command for ProductKey mode receives; Phase 26f), and the caches of an
interactive browser sign-in
(WebView2 user data, MSAL caches, and the Web Account Manager's token broker caches). Each token-shaped
value is decoded in memory only to tell a user's token (the operator's sign-in) from an application's or a
managed identity's; nothing is printed, logged, or kept. Since Phase 28 it also looks for Windows automatic
sign-in left armed, which the PaygWizard guided stop uses once in the T2 guest: AutoAdminLogon on (or
AutoLogonCount), the LSA DefaultPassword secret, the Winlogon DefaultPassword value, and, where the setup
wizard signs in (IncludeBrowserCache), the Winlogon DefaultUserName value. Any of them fails the result, and
Clean turns automatic sign-in off and deletes them. The LSA secret alone, with none of the others, isn't
automatic sign-in left armed: Azure's Windows provisioning leaves one on every VM the demo creates (live
finding, 2026-11-06). It's counted apart (autoLogonLoneSecrets) and still fails the result, because it's a
stored password nothing needs; Clean deletes only that secret. AutoLogonOnly checks automatic sign-in and
nothing else (T1's bootstrap).

Where it looks, on every machine: SQL Server setup's log folders, the Windows and user temporary folders,
PowerShell history and transcripts (including a transcription policy's folder), the managed Run Command
handlers' folders, the Azure VM agent's logs and configuration, the Connected Machine agent's and machine
configuration's logs, the demo's own state and log folders, and the PowerShell, Application, and Security
(process creation) event logs. With IncludeBrowserCache (the T2 guest and the evaluation-only VM, where the
setup wizard signs in), the browser and broker caches in every local profile too.

Actions:
- Scan: read-only.
- Clean: replaces every token-shaped value in those files with [REDACTED] (keeping each file's encoding),
  deletes an archive in setup's log folders that holds one or can't be checked, deletes the browser and
  broker caches (IncludeBrowserCache), and clears a PowerShell or Application event log only when it holds a
  token-shaped value (ClearEventLogs), once more if a process that was still running wrote another one right
  after. It never clears the Security log on its own: that takes an operator's explicit request
  (ClearSecurityLog). Then it scans again. Clearing an event log removes all its events, and endpoint
  protection may report the clearing.

Archives in setup's log folders are checked inside: a .cab is expanded with Windows' expand.exe, a .zip with
.NET's ZipFile, and a .gz with GZipStream, into a temporary folder that is deleted right after; an archive
whose files hold no token-shaped value passes. One that can't be expanded or read (such as a .7z) fails the
result until Clean deletes it.

Scope: Local (this machine), Guest (the T2 guest over PowerShell Direct, which works without a network
connection), or Both. The result passes only when no user's token, unclassified token, browser cache, or
unreadable file in setup's log folders or the Run Command handlers' folders is left, in files or in the
PowerShell and Application logs. A managed identity's or an application's token is reported, and removed by
Clean, but doesn't fail the result. A token-shaped value in the Security log is counted apart
(securityLogTokens), because only an operator clears that log.

The host's own sweep (the host bootstrap's GuestSignInCleanup step, which runs right after Arc onboarding) and this
script never sweep the guest at the same time (live, 2026-11-19: this one's guest sweep failed to connect while the
host's GuestSignInCleanup checked the guest after a first onboarding). With ResidueLockMinutes, a Guest or Both sweep
first takes the host bootstrap's own lock (bootstrap.lock in ResidueStateRoot, which every bootstrap run holds from its
start to its end): it waits while a run holds it, and a run that starts meanwhile exits and runs again 5 minutes later.
When the lock isn't free within ResidueLockMinutes, nothing is swept, and the result says so (lock.timedOut; fail closed).

A guest sweep that fails while the guest runs runs again, up to three more times after pauses of 10, 30, and 60
seconds. When the host's installed bootstrap bundle has issue #65's recovery (vm/hyperv-guest/GuestVm.ps1): a broken
PowerShell Direct channel is probed three times, 10 seconds apart, and when it stays broken the guest is restarted once
for the caller's run (RecoveryKey; Invoke-DemoGuestRecovery), and a guest that isn't running is waited for up to 5
minutes, never started. The result then has guestRecovery: what broke, what was done, and how many times the sweep ran.
A guest sweep that still fails is reported with PowerShell Direct's own error (guest.error); a file that disappears while
the sweep runs is skipped, as it holds nothing any more.

Sources (checked 2026-10-27):
- Managed Run Command passes parameters to a Windows script as arguments:
  https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed
- PowerShell logging, transcription, and process creation auditing, and wevtutil clear-log:
  https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/debug-customscriptextension-runcommand-scripts
- EventLogSession.ClearLog: https://learn.microsoft.com/dotnet/api/system.diagnostics.eventing.reader.eventlogsession.clearlog
- SQL Server setup's log folder: https://learn.microsoft.com/sql/database-engine/install-windows/view-and-read-sql-server-setup-log-files
- WebView2 user data folders: https://learn.microsoft.com/microsoft-edge/webview2/concepts/user-data-folder
- PowerShell Direct: https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct
- expand (a .cab's files): https://learn.microsoft.com/windows-server/administration/windows-commands/expand
- ZipFile.ExtractToDirectory: https://learn.microsoft.com/dotnet/api/system.io.compression.zipfile.extracttodirectory
- Automatic sign-in and its LSA secret (Phase 28, checked 2026-10-29):
  https://learn.microsoft.com/windows/win32/secauthn/protecting-the-automatic-logon-password,
  https://learn.microsoft.com/windows/win32/secauthn/msgina-dll-features, and
  https://learn.microsoft.com/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon

The last line of output is one compact JSON object; errors go to standard error. Exit code 0 means the
action ran; the JSON's pass says whether anything is left.

.PARAMETER ResidueAction
Scan or Clean.

.PARAMETER ResidueScope
Local, Guest, or Both.

.PARAMETER IncludeBrowserCache
'true' to include the browser and broker caches on this machine (Local and Both). The guest always
includes them.

.PARAMETER ClearEventLogs
'false' to never clear a PowerShell or Application event log in Clean.

.PARAMETER ClearSecurityLog
'true' to clear the Security log in Clean when it holds a token-shaped value: only on an operator's explicit
request (check-sign-in-data.ps1 -ClearSecurityLog), never automatically.

.PARAMETER GuestVmName
The T2 guest's Hyper-V name.

.PARAMETER ResidueStateRoot
The demo's state folder on the host, where the guest's administrator password is kept (DPAPI).

.PARAMETER ResidueLockMinutes
With Scope Guest or Both: how many minutes to wait for the host bootstrap's lock (bootstrap.lock in ResidueStateRoot)
before the sweep, so it never runs beside the host's own sign-in cleanup. '0' (the default) doesn't take it.

.PARAMETER RecoveryKey
The caller's run (deploy.ps1's run), so a broken PowerShell Direct channel restarts the guest at most once for it;
without it, at most once an hour.
#>
[CmdletBinding()]
param(
    [string] $ResidueAction = 'Scan',
    [string] $ResidueScope = 'Local',
    [string] $IncludeBrowserCache = 'false',
    [string] $ClearEventLogs = 'true',
    [string] $ClearSecurityLog = 'false',
    [string] $GuestVmName = 'arcsql01',
    [string] $ResidueStateRoot = 'C:\ProgramData\DbHubDemo',
    [string] $ResidueLockMinutes = '0',
    [string] $RecoveryKey = ''
)

Set-StrictMode -Version Latest

function Invoke-DemoSignInSweep {
    <#
    .SYNOPSIS
    Scans this machine for sign-in data and, with Clean, removes it and scans again. Self-contained, so the
    host can run it in the guest with Invoke-Command -VMName -ScriptBlock ${function:Invoke-DemoSignInSweep}.
    Returns counts and locations only.
    #>
    [CmdletBinding()]
    param(
        [bool] $Clean = $false,
        [bool] $IncludeBrowserCache = $false,
        [bool] $ClearEventLogs = $true,
        [bool] $ClearSecurityLog = $false,
        [int] $MaxPaths = 40,
        [long] $MaxFileBytes = 67108864,
        [System.Collections.IDictionary] $Folder = @{},
        [scriptblock] $EventLogReader = $null,
        [scriptblock] $EventLogClearer = $null,
        [scriptblock] $ArchiveExpander = $null,
        [long] $MaxArchiveBytes = 268435456,
        [scriptblock] $AutoLogonProvider = $null,
        [bool] $AutoLogonOnly = $false
    )

    $ErrorActionPreference = 'Continue'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $tokenPattern = 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*'
    $propertyPattern = '(?i)(["](?:access_?token|refresh_?token|id_?token)["]\s*[:=]\s*["])([^"\s]{20,})(["])'
    $keyPattern = '(?i)\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b'
    $archiveExtensions = @('.cab', '.zip', '.7z', '.gz')
    $blockingLocations = @('SetupLogs', 'RunCommand')
    # The nested functions read these through dynamic scope. Folder overrides the machine's folders (tests).
    $options = @{ IncludeBrowserCache = $IncludeBrowserCache; MaxPaths = $MaxPaths; MaxFileBytes = $MaxFileBytes; EventLogReader = $EventLogReader; ArchiveExpander = $ArchiveExpander; MaxArchiveBytes = $MaxArchiveBytes; AutoLogonProvider = $AutoLogonProvider; AutoLogonOnly = $AutoLogonOnly }
    $base = @{
        ProgramFiles = $env:ProgramFiles
        ProgramData  = $env:ProgramData
        Windows      = $env:windir
        SystemRoot   = $env:SystemDrive + '\'
        Users        = Join-Path -Path ($env:SystemDrive + '\') -ChildPath 'Users'
        ExpandRoot   = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'DbHubDemo-sweep'
    }
    foreach ($key in @($Folder.Keys)) {
        $base[[string]$key] = [string]$Folder[$key]
    }

    function Get-SweepTokenKind {
        # User, App, or Other. The payload is decoded in memory and never kept: a delegated (user) token has
        # scp, a user name claim, or idtyp user; a managed identity's or an application's has xms_mirid,
        # idtyp app, roles, or an application ID without scp.
        param([string] $Value)
        $parts = $Value.Split('.')
        if ($parts.Count -lt 3) {
            return 'Other'
        }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
            1 { return 'Other' }
        }
        $json = ''
        try {
            $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        }
        catch {
            return 'Other'
        }
        $kind = 'Other'
        if ($json -match '["](?:scp|upn|unique_name|preferred_username)["]\s*:' -or $json -match '["]idtyp["]\s*:\s*["]user["]') {
            $kind = 'User'
        }
        elseif ($json -match '["](?:xms_mirid|roles|appid|azp)["]\s*:' -or $json -match '["]idtyp["]\s*:\s*["]app["]') {
            $kind = 'App'
        }
        $json = $null
        return $kind
    }

    function Measure-SweepText {
        # Counts the token-shaped values in one text by kind.
        param([string] $Text)
        $count = @{ User = 0; App = 0; Other = 0; Key = 0 }
        if ([string]::IsNullOrEmpty($Text)) {
            return $count
        }
        foreach ($found in [regex]::Matches($Text, $keyPattern)) {
            # A placeholder (one or two characters) or a masked key (a group of one repeated character) isn't a key.
            $value = $found.Value.ToUpperInvariant()
            $masked = @($value.Split('-') | Where-Object { @($_.ToCharArray() | Select-Object -Unique).Count -eq 1 }).Count -gt 0
            if (-not $masked -and @($value.Replace('-', '').ToCharArray() | Select-Object -Unique).Count -gt 2) {
                $count['Key']++
            }
        }
        if ($Text.IndexOf('eyJ', [System.StringComparison]::Ordinal) -ge 0) {
            foreach ($found in [regex]::Matches($Text, $tokenPattern)) {
                $count[(Get-SweepTokenKind -Value $found.Value)]++
            }
        }
        if ($Text.IndexOf('token', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            foreach ($found in [regex]::Matches($Text, $propertyPattern)) {
                $value = $found.Groups[2].Value
                if ($value.StartsWith('[REDACTED', [System.StringComparison]::Ordinal) -or $value -match ('^' + $tokenPattern)) {
                    continue
                }
                $count['Other']++
            }
        }
        return $count
    }

    function Read-SweepFile {
        # Status Text (with Text and Encoding), Binary, TooLarge, or Unreadable. UTF-16 without a byte order
        # mark is told by its NUL bytes, because Windows PowerShell 5.1 and Windows tools write UTF-16 logs.
        param([System.IO.FileInfo] $File)
        if ($File.Length -gt $options.MaxFileBytes) {
            return @{ Status = 'TooLarge' }
        }
        $bytes = $null
        try {
            $stream = New-Object -TypeName 'System.IO.FileStream' -ArgumentList $File.FullName, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), ([System.IO.FileShare]'ReadWrite, Delete')
            try {
                $buffer = New-Object -TypeName 'System.IO.MemoryStream'
                $stream.CopyTo($buffer)
                $bytes = $buffer.ToArray()
            }
            finally {
                $stream.Dispose()
            }
        }
        catch {
            return @{ Status = 'Unreadable' }
        }
        $length = $bytes.Length
        if ($length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            return @{ Status = 'Text'; Text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $length - 3); Encoding = (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $true) }
        }
        if ($length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            return @{ Status = 'Text'; Text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, ($length - 2) - (($length - 2) % 2)); Encoding = (New-Object -TypeName 'System.Text.UnicodeEncoding' -ArgumentList $false, $true) }
        }
        if ($length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            return @{ Status = 'Text'; Text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, ($length - 2) - (($length - 2) % 2)); Encoding = (New-Object -TypeName 'System.Text.UnicodeEncoding' -ArgumentList $true, $true) }
        }
        $probe = [System.Math]::Min($length, 8000)
        if ($probe -eq 0 -or [System.Array]::IndexOf($bytes, [byte]0, 0, $probe) -lt 0) {
            return @{ Status = 'Text'; Text = [System.Text.Encoding]::UTF8.GetString($bytes); Encoding = (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false) }
        }
        $pairs = [int][System.Math]::Floor($probe / 2)
        $evenZero = 0
        $oddZero = 0
        for ($index = 0; $index -lt 2 * $pairs; $index += 2) {
            if ($bytes[$index] -eq 0) { $evenZero++ }
            if ($bytes[$index + 1] -eq 0) { $oddZero++ }
        }
        if ($pairs -gt 0 -and $oddZero -ge 0.3 * $pairs -and $evenZero -le 0.02 * $pairs) {
            return @{ Status = 'Text'; Text = [System.Text.Encoding]::Unicode.GetString($bytes, 0, $length - ($length % 2)); Encoding = (New-Object -TypeName 'System.Text.UnicodeEncoding' -ArgumentList $false, $false) }
        }
        return @{ Status = 'Binary' }
    }

    function Measure-SweepArchive {
        # Expands an archive into a temporary folder that's deleted right after, and counts the token-shaped
        # values in its files. Status Scanned, or Unverified when it can't be expanded or a file in it can't be read.
        param([System.IO.FileInfo] $File)
        $result = @{ Status = 'Unverified'; User = 0; App = 0; Other = 0; Key = 0; Files = 0 }
        if ($File.Length -gt $options.MaxArchiveBytes) {
            return $result
        }
        $extension = $File.Extension.ToLowerInvariant()
        $temp = Join-Path -Path $base.ExpandRoot -ChildPath ([guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $temp -Force | Out-Null
            $expanded = $false
            if ($null -ne $options.ArchiveExpander) {
                $expanded = [bool](& $options.ArchiveExpander $File.FullName $temp)
            }
            elseif ($extension -eq '.cab') {
                $tool = [System.IO.Path]::Combine([string]$env:windir, 'System32', 'expand.exe')
                if (Test-Path -LiteralPath $tool) {
                    $null = & $tool $File.FullName '-F:*' $temp 2>&1
                    $expanded = $LASTEXITCODE -eq 0
                }
            }
            elseif ($extension -eq '.zip') {
                Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
                [System.IO.Compression.ZipFile]::ExtractToDirectory($File.FullName, $temp)
                $expanded = $true
            }
            elseif ($extension -eq '.gz') {
                $source = [System.IO.File]::OpenRead($File.FullName)
                try {
                    $gzip = New-Object -TypeName 'System.IO.Compression.GZipStream' -ArgumentList $source, ([System.IO.Compression.CompressionMode]::Decompress)
                    $target = [System.IO.File]::Create((Join-Path -Path $temp -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($File.Name))))
                    try {
                        $gzip.CopyTo($target)
                    }
                    finally {
                        $target.Dispose()
                        $gzip.Dispose()
                    }
                }
                finally {
                    $source.Dispose()
                }
                $expanded = $true
            }
            # expand.exe can exit 0 for a damaged archive, so a check needs at least one text file from it (below).
            $innerFiles = @(Get-ChildItem -LiteralPath $temp -Recurse -File -Force -ErrorAction SilentlyContinue)
            if (-not $expanded -or $innerFiles.Count -eq 0) {
                return $result
            }
            foreach ($inner in $innerFiles) {
                $read = Read-SweepFile -File $inner
                if ($read.Status -eq 'Binary') {
                    continue
                }
                if ($read.Status -ne 'Text') {
                    return $result
                }
                $count = Measure-SweepText -Text $read.Text
                $read = $null
                $result.User += $count['User']
                $result.App += $count['App']
                $result.Other += $count['Other']
                $result.Key += $count['Key']
                $result.Files++
            }
            # Setup's archives hold text logs. Without one, the archive wasn't really expanded: expand.exe copies a
            # file it can't read as a cabinet, as it is.
            if ($result.Files -gt 0) {
                $result.Status = 'Scanned'
            }
            return $result
        }
        catch {
            $result.Status = 'Unverified'
            return $result
        }
        finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Get-SweepRoot {
        # The folders to read: Location, Path, Recurse, and Filter.
        $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $add = {
            param([string] $Location, [string] $Path, [bool] $Recurse = $true, [string] $Filter = '')
            if ($Path -and (Test-Path -LiteralPath $Path -PathType Container)) {
                $list.Add(@{ Location = $Location; Path = $Path; Recurse = $Recurse; Filter = $Filter })
            }
        }
        $sqlRoot = Join-Path -Path $base.ProgramFiles -ChildPath 'Microsoft SQL Server'
        foreach ($folder in @(Get-ChildItem -LiteralPath $sqlRoot -Directory -ErrorAction SilentlyContinue)) {
            & $add 'SetupLogs' ([System.IO.Path]::Combine($folder.FullName, 'Setup Bootstrap', 'Log'))
        }
        & $add 'Temp' (Join-Path -Path $base.Windows -ChildPath 'Temp')
        foreach ($profileFolder in @(Get-SweepProfile)) {
            & $add 'Temp' ([System.IO.Path]::Combine($profileFolder, 'AppData', 'Local', 'Temp'))
            & $add 'History' ([System.IO.Path]::Combine($profileFolder, 'AppData', 'Roaming', 'Microsoft', 'Windows', 'PowerShell', 'PSReadLine'))
            & $add 'Transcripts' (Join-Path -Path $profileFolder -ChildPath 'Documents') $false 'PowerShell_transcript*'
        }
        foreach ($key in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription', 'HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\Transcription')) {
            $setting = Get-ItemProperty -LiteralPath $key -Name 'OutputDirectory' -ErrorAction SilentlyContinue
            if ($setting -and $setting.OutputDirectory) {
                & $add 'Transcripts' ([System.Environment]::ExpandEnvironmentVariables([string]$setting.OutputDirectory))
            }
        }
        foreach ($handler in @('Microsoft.CPlat.Core.RunCommandHandlerWindows', 'Microsoft.CPlat.Core.RunCommandWindows')) {
            & $add 'RunCommand' ([System.IO.Path]::Combine($base.SystemRoot, 'Packages', 'Plugins', $handler))
        }
        & $add 'AzureAgent' ([System.IO.Path]::Combine($base.SystemRoot, 'WindowsAzure', 'Logs'))
        & $add 'AzureAgent' ([System.IO.Path]::Combine($base.SystemRoot, 'WindowsAzure', 'Config'))
        & $add 'ArcAgent' ([System.IO.Path]::Combine($base.ProgramData, 'AzureConnectedMachineAgent', 'Log'))
        & $add 'ArcAgent' (Join-Path -Path $base.ProgramData -ChildPath 'GuestConfig')
        & $add 'DemoFiles' (Join-Path -Path $base.ProgramData -ChildPath 'DbHubDemo')
        & $add 'DemoFiles' ([System.IO.Path]::Combine($base.SystemRoot, 'DbHubDemo', 'logs'))
        return $list
    }

    function Get-SweepProfile {
        # Every local profile folder (not the junctions), plus the SYSTEM profile that Run Commands use.
        $folders = @(Get-ChildItem -LiteralPath $base.Users -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } | ForEach-Object { $_.FullName })
        $folders += [System.IO.Path]::Combine($base.Windows, 'System32', 'config', 'systemprofile')
        return $folders
    }

    function Get-SweepCache {
        # The browser and broker caches of an interactive sign-in: WebView2 user data (EBWebView), the
        # identity service and MSAL caches (verified), and the token broker's caches (removed, not verified:
        # Windows can rebuild them for its own accounts, and their content is encrypted).
        $verified = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $broker = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $searchRoots = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($profileFolder in @(Get-SweepProfile)) {
            $searchRoots.Add((Join-Path -Path $profileFolder -ChildPath 'AppData'))
            foreach ($brokerFolder in @(
                    [System.IO.Path]::Combine($profileFolder, 'AppData', 'Local', 'Microsoft', 'TokenBroker', 'Cache')
                    @(Get-ChildItem -Path ([System.IO.Path]::Combine($profileFolder, 'AppData', 'Local', 'Packages', 'Microsoft.AAD.BrokerPlugin_*')) -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.Path]::Combine($_.FullName, 'AC', 'TokenBroker', 'Accounts') })
                )) {
                if ($brokerFolder -and (Test-Path -LiteralPath $brokerFolder -PathType Container)) {
                    foreach ($item in @(Get-ChildItem -LiteralPath $brokerFolder -Force -ErrorAction SilentlyContinue)) {
                        $broker.Add($item.FullName)
                    }
                }
            }
        }
        $searchRoots.Add((Join-Path -Path $base.Windows -ChildPath 'Temp'))
        $sqlRoot = Join-Path -Path $base.ProgramFiles -ChildPath 'Microsoft SQL Server'
        foreach ($folder in @(Get-ChildItem -LiteralPath $sqlRoot -Directory -ErrorAction SilentlyContinue)) {
            $searchRoots.Add((Join-Path -Path $folder.FullName -ChildPath 'Setup Bootstrap'))
        }
        foreach ($root in $searchRoots) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                continue
            }
            foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue)) {
                $isCacheFolder = $item.PSIsContainer -and ($item.Name -eq 'EBWebView' -or $item.Name -eq '.IdentityService')
                $isCacheFile = (-not $item.PSIsContainer) -and $item.Name -like 'msal*cache*'
                if (($isCacheFolder -or $isCacheFile) -and -not $verified.Contains($item.FullName)) {
                    $verified.Add($item.FullName)
                }
            }
        }
        # A cache inside another one is removed with it.
        $separator = [string][System.IO.Path]::DirectorySeparatorChar
        $outer = @($verified | Sort-Object -Property Length | Where-Object {
                $candidate = $_
                -not @($verified | Where-Object { $_ -ne $candidate -and $candidate.StartsWith($_ + $separator, [System.StringComparison]::OrdinalIgnoreCase) }).Count
            })
        return @{ Verified = $outer; Broker = @($broker) }
    }

    function Get-SweepEventLog {
        # Event logs that can hold a command line or parameter values: the PowerShell logs (engine events
        # carry the host's command line), Application, and Security's process creation events.
        $logs = @(
            @{ Name = 'Windows PowerShell'; XPath = '*'; Security = $false }
            @{ Name = 'Microsoft-Windows-PowerShell/Operational'; XPath = '*'; Security = $false }
            @{ Name = 'PowerShellCore/Operational'; XPath = '*'; Security = $false }
            @{ Name = 'Application'; XPath = '*'; Security = $false }
            @{ Name = 'Security'; XPath = '*[System[(EventID=4688)]]'; Security = $true }
        )
        $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($log in $logs) {
            $entry = [ordered]@{ log = $log.Name; read = $false; events = 0; user = 0; app = 0; other = 0; key = 0; firstUtc = ''; lastUtc = ''; security = $log.Security }
            $records = $null
            try {
                if ($null -ne $options.EventLogReader) {
                    $records = @(& $options.EventLogReader $log.Name $log.XPath)
                }
                else {
                    $records = @(Get-WinEvent -LogName $log.Name -FilterXPath $log.XPath -ErrorAction Stop)
                }
                $entry.read = $true
            }
            catch {
                # No events match, or the log doesn't exist on this machine.
                $entry.read = ([string]$_.FullyQualifiedErrorId -match 'NoMatchingEventsFound')
                $records = @()
            }
            $first = $null
            $last = $null
            foreach ($record in $records) {
                $entry.events++
                $text = (@($record.Properties) | ForEach-Object { [string]$_.Value }) -join "`n"
                $count = Measure-SweepText -Text $text
                $text = $null
                if ($count['User'] + $count['App'] + $count['Other'] + $count['Key'] -eq 0) {
                    continue
                }
                $entry.user += $count['User']
                $entry.app += $count['App']
                $entry.other += $count['Other']
                $entry.key += $count['Key']
                if ($count['User'] + $count['Other'] + $count['Key'] -gt 0) {
                    $time = $record.TimeCreated.ToUniversalTime()
                    if ($null -eq $first -or $time -lt $first) { $first = $time }
                    if ($null -eq $last -or $time -gt $last) { $last = $time }
                }
            }
            if ($null -ne $first) {
                $entry.firstUtc = $first.ToString('yyyy-MM-ddTHH:mm:ssZ')
                $entry.lastUtc = $last.ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            $results.Add($entry)
        }
        return $results
    }

    function Invoke-SweepAutoLogon {
        # Windows automatic sign-in on this machine (Phase 28): Read reports AutoAdminLogon on (or AutoLogonCount), the
        # LSA DefaultPassword secret, and the Winlogon DefaultPassword and DefaultUserName values; Clear turns it off and
        # deletes them; DeleteSecret deletes only the LSA secret (the one Azure's provisioning leaves, with automatic
        # sign-in off). The guided stop arms it in the T2 guest for one sign-in, and its cleanup removes all of it, so
        # anything found is a leftover. DefaultUserName counts only where the setup wizard signs in (IncludeBrowserCache):
        # elsewhere Windows writes it as the last console user. The secret's presence comes from LsaRetrievePrivateData,
        # whose buffer is freed without being read (https://learn.microsoft.com/windows/win32/secauthn/protecting-the-automatic-logon-password).
        # Returns Enabled, Secret (the LSA secret), PlainValue (the Winlogon DefaultPassword value), and UserName, each 0 or 1.
        param([string] $Mode)
        if ($null -ne $options.AutoLogonProvider) {
            return (& $options.AutoLogonProvider $Mode)
        }
        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        if (-not ('DbHubDemoSweepLsa' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DbHubDemoSweepLsa
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
        IntPtr policy = Open(0x00000004);
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

    public static void Delete(string name)
    {
        IntPtr policy = Open(0x00000020);
        IntPtr nameBuffer = Marshal.StringToHGlobalUni(name);
        try
        {
            LsaString key = Name(name, nameBuffer);
            uint status = LsaStorePrivateData(policy, ref key, IntPtr.Zero);
            if (status != 0 && status != NameNotFound) { throw new Win32Exception(LsaNtStatusToWinError(status)); }
        }
        finally
        {
            Marshal.FreeHGlobal(nameBuffer);
            LsaClose(policy);
        }
    }
}
'@
        }
        if ($Mode -eq 'Clear') {
            Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -Value '0' -ErrorAction SilentlyContinue
            $names = @('AutoLogonCount', 'DefaultPassword')
            if ($options.IncludeBrowserCache) {
                $names += 'DefaultUserName'
            }
            foreach ($name in $names) {
                Remove-ItemProperty -LiteralPath $winlogon -Name $name -ErrorAction SilentlyContinue
            }
            [DbHubDemoSweepLsa]::Delete('DefaultPassword')
        }
        elseif ($Mode -eq 'DeleteSecret') {
            [DbHubDemoSweepLsa]::Delete('DefaultPassword')
        }
        $item = Get-ItemProperty -LiteralPath $winlogon -ErrorAction SilentlyContinue
        $has = {
            param([string] $Name)
            return ($null -ne $item -and $null -ne $item.PSObject.Properties[$Name])
        }
        $enabled = (& $has 'AutoLogonCount') -or ((& $has 'AutoAdminLogon') -and [string]$item.AutoAdminLogon -eq '1')
        $userName = (& $has 'DefaultUserName') -and -not [string]::IsNullOrEmpty([string]$item.DefaultUserName)
        return @{
            Enabled  = [int][bool]$enabled
            Secret   = [int][DbHubDemoSweepLsa]::Exists('DefaultPassword')
            PlainValue = [int][bool](& $has 'DefaultPassword')
            UserName = [int][bool]$userName
        }
    }

    function Invoke-SweepScan {
        # One read-only pass. Returns the counts, the files to clean, and the locations (no values).
        $summary = [ordered]@{
            filesScanned = 0; filesSkipped = 0; filesUnverified = 0; userTokens = 0; appTokens = 0; otherTokens = 0
            filesWithUserData = 0; filesWithAppTokens = 0; archives = 0; archivesChecked = 0; browserCaches = 0; brokerEntries = 0
            eventLogUserTokens = 0; eventLogAppTokens = 0; securityLogTokens = 0; productKeys = 0; eventLogKeys = 0
            autoLogonEnabled = 0; autoLogonSecrets = 0; autoLogonLoneSecrets = 0; autoLogonPasswords = 0; autoLogonUserNames = 0; autoLogonUnverified = 0
        }
        $expandRoot = $base.ExpandRoot.TrimEnd('\', '/')
        $toClean = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $locations = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        $roots = @()
        if (-not $options.AutoLogonOnly) {
            $roots = @(Get-SweepRoot)
        }
        foreach ($root in $roots) {
            $items = @()
            if ($root.Filter) {
                $items = @(Get-ChildItem -LiteralPath $root.Path -Filter $root.Filter -File -Force -ErrorAction SilentlyContinue)
            }
            elseif ($root.Recurse) {
                $items = @(Get-ChildItem -LiteralPath $root.Path -Recurse -File -Force -ErrorAction SilentlyContinue)
            }
            else {
                $items = @(Get-ChildItem -LiteralPath $root.Path -File -Force -ErrorAction SilentlyContinue)
            }
            foreach ($file in $items) {
                if (-not $seen.Add($file.FullName) -or $file.FullName.StartsWith($expandRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                if ($root.Location -eq 'SetupLogs' -and $archiveExtensions -contains $file.Extension.ToLowerInvariant()) {
                    $inside = Measure-SweepArchive -File $file
                    if ($inside.Status -eq 'Scanned') {
                        $summary.archivesChecked++
                        if ($inside.User + $inside.App + $inside.Other + $inside.Key -eq 0) {
                            continue
                        }
                        # Only setup's logs are in it, so an archive that holds a token-shaped value is deleted.
                        $summary.userTokens += $inside.User
                        $summary.appTokens += $inside.App
                        $summary.otherTokens += $inside.Other
                        $summary.productKeys += $inside.Key
                        if ($inside.User + $inside.Other + $inside.Key -gt 0) {
                            $summary.filesWithUserData++
                        }
                        else {
                            $summary.filesWithAppTokens++
                        }
                        $toClean.Add(@{ Path = $file.FullName; Action = 'Delete'; Location = $root.Location })
                        if ($locations.Count -lt $options.MaxPaths) {
                            $locations.Add([ordered]@{ location = $root.Location; path = $file.FullName; kind = 'Archive'; user = $inside.User; app = $inside.App; other = $inside.Other; key = $inside.Key })
                        }
                        continue
                    }
                    $summary.archives++
                    $toClean.Add(@{ Path = $file.FullName; Action = 'Delete'; Location = $root.Location })
                    if ($locations.Count -lt $options.MaxPaths) {
                        $locations.Add([ordered]@{ location = $root.Location; path = $file.FullName; kind = 'ArchiveUnverified'; user = 0; app = 0; other = 0; key = 0 })
                    }
                    continue
                }
                $read = Read-SweepFile -File $file
                if ($read.Status -ne 'Text') {
                    $summary.filesSkipped++
                    if ($read.Status -ne 'Binary' -and $blockingLocations -contains $root.Location) {
                        $summary.filesUnverified++
                        if ($locations.Count -lt $options.MaxPaths) {
                            $locations.Add([ordered]@{ location = $root.Location; path = $file.FullName; kind = $read.Status; user = 0; app = 0; other = 0; key = 0 })
                        }
                    }
                    continue
                }
                $summary.filesScanned++
                $count = Measure-SweepText -Text $read.Text
                $read = $null
                if ($count['User'] + $count['App'] + $count['Other'] + $count['Key'] -eq 0) {
                    continue
                }
                $summary.userTokens += $count['User']
                $summary.appTokens += $count['App']
                $summary.otherTokens += $count['Other']
                $summary.productKeys += $count['Key']
                if ($count['User'] + $count['Other'] + $count['Key'] -gt 0) {
                    $summary.filesWithUserData++
                }
                else {
                    $summary.filesWithAppTokens++
                }
                $toClean.Add(@{ Path = $file.FullName; Action = 'Redact'; Location = $root.Location })
                if ($locations.Count -lt $options.MaxPaths) {
                    $locations.Add([ordered]@{ location = $root.Location; path = $file.FullName; kind = 'File'; user = $count['User']; app = $count['App']; other = $count['Other']; key = $count['Key'] })
                }
            }
        }
        $caches = @{ Verified = @(); Broker = @() }
        if ($options.IncludeBrowserCache -and -not $options.AutoLogonOnly) {
            $caches = Get-SweepCache
            $summary.browserCaches = @($caches.Verified).Count
            $summary.brokerEntries = @($caches.Broker).Count
            foreach ($path in @($caches.Verified)) {
                if ($locations.Count -lt $options.MaxPaths) {
                    $locations.Add([ordered]@{ location = 'BrowserCache'; path = $path; kind = 'Cache'; user = 0; app = 0; other = 0; key = 0 })
                }
            }
        }
        $eventLogs = @()
        if (-not $options.AutoLogonOnly) {
            $eventLogs = @(Get-SweepEventLog)
        }
        foreach ($entry in $eventLogs) {
            if ($entry.security) {
                $summary.securityLogTokens += $entry.user + $entry.app + $entry.other + $entry.key
                continue
            }
            $summary.eventLogUserTokens += $entry.user + $entry.other
            $summary.eventLogAppTokens += $entry.app
            $summary.eventLogKeys += $entry.key
        }
        # Automatic sign-in left armed (Phase 28) fails the result: it keeps a password and signs someone in. The LSA secret
        # alone, with automatic sign-in off and none of its values (the one Azure's provisioning leaves), is counted apart:
        # it still fails the result, because it's a stored password nothing needs, and Clean deletes only it.
        try {
            $auto = Invoke-SweepAutoLogon -Mode 'Read'
            $summary.autoLogonEnabled = [int]$auto['Enabled']
            $summary.autoLogonPasswords = [int]$auto['PlainValue']
            if ($options.IncludeBrowserCache) {
                $summary.autoLogonUserNames = [int]$auto['UserName']
            }
            if ([int]$auto['Secret'] -gt 0 -and ($summary.autoLogonEnabled + $summary.autoLogonPasswords + $summary.autoLogonUserNames) -eq 0) {
                $summary.autoLogonLoneSecrets = 1
            }
            else {
                $summary.autoLogonSecrets = [int]$auto['Secret']
            }
        }
        catch {
            $summary.autoLogonUnverified = 1
        }
        # The Security log is reported apart: it's never cleared automatically (securityLogTokens).
        $autoLogon = $summary.autoLogonEnabled + $summary.autoLogonSecrets + $summary.autoLogonLoneSecrets + $summary.autoLogonPasswords + $summary.autoLogonUserNames + $summary.autoLogonUnverified
        $summary.pass = ($summary.userTokens + $summary.otherTokens + $summary.productKeys + $summary.archives + $summary.browserCaches + $summary.filesUnverified + $summary.eventLogUserTokens + $summary.eventLogKeys + $autoLogon) -eq 0
        return @{
            Summary   = $summary
            ToClean   = $toClean
            Caches    = $caches
            EventLogs = $eventLogs
            Locations = $locations
        }
    }

    function Clear-SweepFile {
        # Replaces the token-shaped values in one file, keeping its encoding. True when it changed. A file that's gone by
        # now holds nothing: it's skipped without an error, which over PowerShell Direct would end the whole sweep on the
        # host (live, 2026-11-19); the scan after the cleanup says what's left.
        param([string] $Path)
        $file = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($null -eq $file) {
            return $false
        }
        $read = Read-SweepFile -File $file
        if ($read.Status -ne 'Text') {
            return $false
        }
        $text = [regex]::Replace($read.Text, $tokenPattern, '[REDACTED]')
        $text = [regex]::Replace($text, $propertyPattern, '$1[REDACTED]$3')
        $text = [regex]::Replace($text, $keyPattern, '[REDACTED]')
        [System.IO.File]::WriteAllText($Path, $text, $read.Encoding)
        $text = $null
        return $true
    }

    $before = Invoke-SweepScan
    $actions = [ordered]@{ filesRedacted = 0; filesDeleted = 0; filesFailed = 0; cachesRemoved = 0; brokerEntriesRemoved = 0; eventLogsCleared = @(); eventLogsNotCleared = @(); autoLogonCleared = 0; logonNameRemoved = 0; loneSecretDeleted = 0 }
    $after = $before
    if ($Clean) {
        $armed = $before.Summary.autoLogonEnabled + $before.Summary.autoLogonSecrets + $before.Summary.autoLogonPasswords
        if ($armed + $before.Summary.autoLogonUserNames -gt 0) {
            try {
                $null = Invoke-SweepAutoLogon -Mode 'Clear'
                if ($armed -gt 0) {
                    $actions.autoLogonCleared = 1
                }
                if ($before.Summary.autoLogonUserNames -gt 0) {
                    $actions.logonNameRemoved = 1
                }
            }
            catch {
                $actions.filesFailed++
            }
        }
        elseif ($before.Summary.autoLogonLoneSecrets -gt 0) {
            # Automatic sign-in is off, so only the secret goes; the Winlogon values stay as they are.
            try {
                $null = Invoke-SweepAutoLogon -Mode 'DeleteSecret'
                $actions.loneSecretDeleted = 1
            }
            catch {
                $actions.filesFailed++
            }
        }
        foreach ($item in $before.ToClean) {
            try {
                if ($item.Action -eq 'Delete') {
                    Remove-Item -LiteralPath $item.Path -Force -ErrorAction Stop
                    $actions.filesDeleted++
                }
                elseif (Clear-SweepFile -Path $item.Path) {
                    $actions.filesRedacted++
                }
            }
            catch {
                $actions.filesFailed++
            }
        }
        foreach ($path in @($before.Caches.Verified) + @($before.Caches.Broker)) {
            if (-not (Test-Path -LiteralPath $path)) {
                continue
            }
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $path)) {
                if (@($before.Caches.Verified) -contains $path) {
                    $actions.cachesRemoved++
                }
                else {
                    $actions.brokerEntriesRemoved++
                }
            }
        }
        $logs = @($before.EventLogs)
        for ($round = 1; $round -le 2; $round++) {
            $clearedNow = 0
            foreach ($entry in $logs) {
                # Only a log that holds a token-shaped value is cleared. The Security log only on an explicit request.
                if ($entry.user + $entry.app + $entry.other + $entry.key -eq 0) {
                    continue
                }
                $allowed = if ($entry.security) { $ClearSecurityLog } else { $ClearEventLogs }
                if (-not $allowed) {
                    if ($actions.eventLogsNotCleared -notcontains $entry.log) {
                        $actions.eventLogsNotCleared += $entry.log
                    }
                    continue
                }
                try {
                    if ($null -ne $EventLogClearer) {
                        & $EventLogClearer $entry.log
                    }
                    else {
                        [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($entry.log)
                    }
                    $clearedNow++
                    if ($actions.eventLogsCleared -notcontains $entry.log) {
                        $actions.eventLogsCleared += $entry.log
                    }
                }
                catch {
                    if ($actions.eventLogsNotCleared -notcontains $entry.log) {
                        $actions.eventLogsNotCleared += $entry.log
                    }
                }
            }
            $after = Invoke-SweepScan
            # A process that was still running, such as the onboarding Run Command's PowerShell, can write one
            # more event right after the clearing: one more round for the logs the rule lets it clear.
            $logs = @($after.EventLogs | Where-Object { -not $_.security -and $ClearEventLogs -and ($_.user + $_.app + $_.other + $_.key) -gt 0 })
            if ($clearedNow -eq 0 -or $logs.Count -eq 0) {
                break
            }
        }
    }

    $eventLogFindings = @($after.EventLogs | Where-Object { $_.user + $_.app + $_.other + $_.key -gt 0 } | ForEach-Object { [pscustomobject]$_ })
    $foundLogs = @($before.EventLogs | Where-Object { $_.user + $_.app + $_.other + $_.key -gt 0 } | ForEach-Object { [pscustomobject]$_ })
    return [pscustomobject]@{
        computer       = $env:COMPUTERNAME
        cleaned        = [bool]$Clean
        pass           = [bool]$after.Summary.pass
        found          = [pscustomobject]$before.Summary
        foundEventLogs = $foundLogs
        foundLocations = @($before.Locations | ForEach-Object { [pscustomobject]$_ })
        actions        = [pscustomobject]$actions
        remaining      = [pscustomobject]$after.Summary
        eventLogs      = $eventLogFindings
        locations      = @($after.Locations | ForEach-Object { [pscustomobject]$_ })
        eventLogsRead  = @($after.EventLogs | Where-Object { $_.read } | ForEach-Object { $_.log })
        seconds        = [int]$watch.Elapsed.TotalSeconds
    }
}

function ConvertTo-DemoSignInSummary {
    <#
    .SYNOPSIS
    A compact summary of one machine's sweep for the Run Command's output, whose instance view keeps only the
    last 4 KB: counts, the actions, the event logs with sign-in data, and the first locations, with each path
    shortened from the left. Never a value.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Sweep,

        [ValidateRange(0, 40)]
        [int] $MaxLocations = 6
    )

    if ($null -eq $Sweep) {
        return $null
    }
    $reachable = $true
    if ($Sweep.PSObject.Properties['reachable']) {
        $reachable = [bool]$Sweep.reachable
    }
    if (-not $reachable -or -not $Sweep.PSObject.Properties['found']) {
        $unreachable = [ordered]@{ reachable = $false; pass = $false }
        foreach ($name in 'state', 'error', 'firstError') {
            if ($Sweep.PSObject.Properties[$name]) {
                $unreachable[$name] = [string]$Sweep.$name
            }
        }
        return $unreachable
    }
    $counts = {
        param($Counts)
        $read = {
            param([string] $Name)
            if ($Counts.PSObject.Properties[$Name]) { [int]$Counts.$Name } else { 0 }
        }
        [ordered]@{
            scanned = [int]$Counts.filesScanned; user = [int]$Counts.userTokens; other = [int]$Counts.otherTokens; app = [int]$Counts.appTokens
            files = [int]$Counts.filesWithUserData; archives = [int]$Counts.archives; checked = [int]$Counts.archivesChecked; caches = [int]$Counts.browserCaches
            unverified = [int]$Counts.filesUnverified; logUser = [int]$Counts.eventLogUserTokens; logApp = [int]$Counts.eventLogAppTokens
            security = [int]$Counts.securityLogTokens; keys = [int]$Counts.productKeys; logKeys = [int]$Counts.eventLogKeys
            autologon = (& $read 'autoLogonEnabled') + (& $read 'autoLogonSecrets') + (& $read 'autoLogonPasswords') + (& $read 'autoLogonUnverified')
            logonName = & $read 'autoLogonUserNames'
            loneSecret = & $read 'autoLogonLoneSecrets'
        }
    }
    $place = {
        param($Entry)
        $path = [string]$Entry.path
        if ($path.Length -gt 64) {
            $path = '...' + $path.Substring($path.Length - 61)
        }
        '{0}|{1}|u{2} a{3} o{4} k{5}|{6}' -f $Entry.location, $Entry.kind, $Entry.user, $Entry.app, $Entry.other, $Entry.key, $path
    }
    $summary = [ordered]@{
        computer  = [string]$Sweep.computer
        reachable = $true
        pass      = [bool]$Sweep.pass
        found     = & $counts $Sweep.found
        remaining = & $counts $Sweep.remaining
        eventLogs = @(@($Sweep.foundEventLogs) | Where-Object { $null -ne $_ } | ForEach-Object { '{0}|u{1} a{2} o{3} k{4}|{5}..{6}' -f $_.log, $_.user, $_.app, $_.other, $_.key, $_.firstUtc, $_.lastUtc })
        found_at  = @(@($Sweep.foundLocations) | Where-Object { $null -ne $_ } | Select-Object -First $MaxLocations | ForEach-Object { & $place $_ })
        left_at   = @(@($Sweep.locations) | Where-Object { $null -ne $_ } | Select-Object -First $MaxLocations | ForEach-Object { & $place $_ })
        seconds   = [int]$Sweep.seconds
    }
    if ([bool]$Sweep.cleaned) {
        $actions = $Sweep.actions
        $summary['actions'] = [ordered]@{
            redacted = [int]$actions.filesRedacted; deleted = [int]$actions.filesDeleted; failed = [int]$actions.filesFailed
            caches = [int]$actions.cachesRemoved; broker = [int]$actions.brokerEntriesRemoved
            logsCleared = @($actions.eventLogsCleared); logsNotCleared = @($actions.eventLogsNotCleared)
            autologon = $(if ($actions.PSObject.Properties['autoLogonCleared']) { [int]$actions.autoLogonCleared } else { 0 })
            logonName = $(if ($actions.PSObject.Properties['logonNameRemoved']) { [int]$actions.logonNameRemoved } else { 0 })
            loneSecret = $(if ($actions.PSObject.Properties['loneSecretDeleted']) { [int]$actions.loneSecretDeleted } else { 0 })
        }
    }
    return $summary
}

function Get-DemoSignInGuestCredential {
    # The guest administrator's credential from the host's DPAPI store (LocalMachine scope, the format the
    # host bootstrap writes), or the pending one a password rotation left; tried in that order by the caller.
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [string] $UserName = 'Administrator'
    )

    Add-Type -AssemblyName 'System.Security'
    $credentials = @()
    $path = [System.IO.Path]::Combine($Root, 'protected', 'guest-administrator.bin')
    foreach ($candidate in @($path, ($path + '.pending'))) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([System.IO.File]::ReadAllBytes($candidate), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $secure = New-Object -TypeName 'System.Security.SecureString'
        foreach ($character in [System.Text.Encoding]::UTF8.GetString($bytes).ToCharArray()) {
            $secure.AppendChar($character)
        }
        [System.Array]::Clear($bytes, 0, $bytes.Length)
        $secure.MakeReadOnly()
        $credentials += New-Object -TypeName 'System.Management.Automation.PSCredential' -ArgumentList $UserName, $secure
    }
    return $credentials
}

function Enter-DemoSignInBootstrapLock {
    <#
    .SYNOPSIS
    Takes the host bootstrap's own lock, bootstrap.lock in Root, the way its runs do (Enter-DemoVmLock: an exclusive handle
    that the operating system closes when the process ends), waiting up to Seconds while a bootstrap run holds it. A
    bootstrap run that starts meanwhile exits and runs again 5 minutes later, so the host's own sign-in cleanup never sweeps
    the guest beside this one (live, 2026-11-19). Returns Stream (the handle; $null without a state folder, where no
    bootstrap runs, or when the lock wasn't free in time), Seconds (how long it waited), and TimedOut.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [ValidateRange(1, 7200)]
        [int] $Seconds = 1800,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [pscustomobject]@{ Stream = $null; Seconds = 0; TimedOut = $false }
    }
    $path = [System.IO.Path]::Combine($Root, 'bootstrap.lock')
    while ($true) {
        try {
            $stream = New-Object -TypeName 'System.IO.FileStream' -ArgumentList @($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $text = [System.Text.Encoding]::ASCII.GetBytes(('pid={0} runId=sign-in-data startedUtc={1}' -f $PID, [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)))
            $stream.SetLength(0)
            $stream.Write($text, 0, $text.Length)
            $stream.Flush()
            return [pscustomobject]@{ Stream = $stream; Seconds = [int]$watch.Elapsed.TotalSeconds; TimedOut = $false }
        }
        catch {
            $exception = $_.Exception
            while ($null -ne $exception.InnerException -and $exception -isnot [System.IO.IOException]) {
                $exception = $exception.InnerException
            }
            if ($exception -isnot [System.IO.IOException]) {
                throw
            }
        }
        $left = $Seconds - $watch.Elapsed.TotalSeconds
        if ($left -le 0) {
            return [pscustomobject]@{ Stream = $null; Seconds = [int]$watch.Elapsed.TotalSeconds; TimedOut = $true }
        }
        Start-Sleep -Milliseconds ([int]([System.Math]::Max(100, [System.Math]::Min($PollSeconds, $left) * 1000)))
    }
}

function Get-DemoSignInBundleRoot {
    # The host's installed bootstrap bundle (settings.json's bundlePath, which the loader writes) when it has the module and
    # the guest helpers, or '' when it doesn't. Never throws.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    try {
        $settingsPath = [System.IO.Path]::Combine($Root, 'settings.json')
        if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
            return ''
        }
        $settings = [System.IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
        $property = $settings.PSObject.Properties['bundlePath']
        $bundlePath = ''
        if ($null -ne $property) {
            $bundlePath = [string]$property.Value
        }
        if (-not $bundlePath -or -not (Test-Path -LiteralPath ([System.IO.Path]::Combine($bundlePath, 'vm', 'bootstrap', 'DbHubDemo.Vm.psd1')) -PathType Leaf) -or -not (Test-Path -LiteralPath ([System.IO.Path]::Combine($bundlePath, 'vm', 'hyperv-guest', 'GuestVm.ps1')) -PathType Leaf)) {
            return ''
        }
        return $bundlePath
    }
    catch {
        return ''
    }
}

function Test-DemoSignInRecoveryReady {
    # Whether issue #65's recovery is loaded: the installed bundle's GuestVm.ps1 and DbHubDemo.Vm, since issue #65. An
    # older bundle doesn't have it, and the sweep then only runs again after a pause.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $names = @('Test-DemoGuestChannelBroken', 'Test-DemoGuestChannel', 'Test-DemoGuestOnline', 'Invoke-DemoGuestRecovery', 'Get-DemoGuestRecoveryKey', 'Complete-DemoGuestRecoveryInterrupted', 'Get-DemoVmUtcNow')
    return (@($names | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) }).Count -eq 0)
}

function Invoke-DemoSignInGuestAttempt {
    # One run of Invoke-DemoSignInSweep in the guest over PowerShell Direct, with each credential in turn. Returns Result
    # (the guest's result, or $null when no credential got one) and Error: PowerShell Direct's error, with its error ID,
    # which tells a broken channel from the other failures. It's the first credential's (the current one; the other is a
    # password rotation's pending one), so a pending one's sign-in failure doesn't hide why the current one failed.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential[]] $Credential,

        [bool] $Clean = $false,

        [bool] $ClearEventLogs = $true,

        [bool] $ClearSecurityLog = $false
    )

    $errors = @()
    foreach ($candidate in $Credential) {
        $text = ''
        try {
            $result = Invoke-Command -VMName $Name -Credential $candidate -ScriptBlock ${function:Invoke-DemoSignInSweep} -ArgumentList $Clean, $true, $ClearEventLogs, $ClearSecurityLog -ErrorAction Stop
            if ($null -ne $result) {
                return [pscustomobject]@{ Result = $result; Error = '' }
            }
            $text = 'PowerShell Direct returned no result.'
        }
        catch {
            $text = ([string]$_.Exception.Message).Trim()
            $id = [string]$_.FullyQualifiedErrorId
            if ($id -and $text -notmatch [regex]::Escape($id)) {
                $text = '{0} ({1})' -f $text, $id
            }
        }
        $errors += $text
    }
    $chosen = @($errors | Where-Object { $_ }) | Select-Object -First 1
    return [pscustomobject]@{ Result = $null; Error = [string]$chosen }
}

function ConvertTo-DemoSignInRecoveryEvidence {
    <#
    .SYNOPSIS
    The guest sweep's recovery for the Run Command's output, in the shape the Arc onboarding's has, which deploy.ps1 reports
    as DEPLOY.T2.GUESTRETRY or DEPLOY.T2.GUESTRESTART: action, restarted, recovered (true only when the guest then answered
    the sweep), tries (how many times the sweep ran), ranAgain, seconds, atUtc, restartUtc, stoppedBy, by, key, reason,
    message, and guest. Without a restart, a sweep that then got its answer is a break that was over (Healed), whatever was
    waited for; one that didn't keeps the recovery's decision (None, Exhausted, Busy) or is a Retry, which the sweep's own
    result reports. Pure.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Recovery,

        [Parameter(Mandatory = $true)]
        [string] $Guest,

        [AllowEmptyString()]
        [string] $Reason = '',

        [bool] $Succeeded = $false,

        [ValidateRange(0, 10)]
        [int] $Tries = 0
    )

    $properties = $Recovery.PSObject.Properties
    $read = {
        param([string] $Property)
        $item = $properties[$Property]
        if ($null -ne $item) { $item.Value } else { $null }
    }
    $restarted = [bool](& $read 'Restarted')
    $action = [string](& $read 'Action')
    if (-not $restarted) {
        if ($Succeeded) {
            $action = 'Healed'
        }
        elseif ($action -notin 'None', 'Exhausted', 'Busy') {
            $action = 'Retry'
        }
    }
    $short = {
        param([string] $Text)
        $Text = [regex]::Replace([string]$Text, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*', '[REDACTED]').Trim()
        $Text.Substring(0, [System.Math]::Min(200, $Text.Length))
    }
    $why = [string](& $read 'Reason')
    if (-not $why) {
        $why = $Reason
    }
    $at = [string](& $read 'AtUtc')
    if (-not $at) {
        $at = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [ordered]@{
        action     = $action
        restarted  = $restarted
        recovered  = [bool](& $read 'Recovered') -and $Succeeded
        tries      = $Tries
        ranAgain   = $Tries -gt 1
        seconds    = [int](& $read 'Seconds')
        atUtc      = $at
        restartUtc = [string](& $read 'RestartUtc')
        stoppedBy  = [string](& $read 'StoppedBy')
        by         = [string](& $read 'By')
        key        = [string](& $read 'Key')
        reason     = & $short $why
        message    = & $short ([string](& $read 'Message'))
        guest      = $Guest
    }
}

function Invoke-DemoSignInGuestSweep {
    <#
    .SYNOPSIS
    Runs Invoke-DemoSignInSweep in the guest over PowerShell Direct, with the browser and broker caches.
    Returns the guest's result, or a result with reachable false when the guest is off or doesn't answer.

    .DESCRIPTION
    A sweep that fails while the guest runs runs again, up to once for each of RetryDelaySeconds (10, 30, and 60 seconds:
    about a minute and a half of pauses), so a session that failed within a second while another process opened its own
    doesn't fail the check (live, 2026-11-19: a first onboarding's sweep failed to connect while the host's own sign-in
    cleanup checked the guest). With Recover, the installed bundle's GuestVm.ps1 is loaded, and issue #65's recovery comes
    first: a broken channel goes once to Invoke-DemoGuestRecovery, which probes the guest three times, 10 seconds apart,
    and restarts it once for RecoveryKey when it stays broken; a guest that isn't running (another recovery restarts it)
    is waited for up to OnlineMinutes, without being started; otherwise the next try comes after its pause. A guest that
    an interrupted restart left off is started again first (Complete-DemoGuestRecoveryInterrupted, which leaves a guest
    that a golden capture keeps off alone); nothing else here starts a guest that's off. Without Recover (an older bundle),
    each try comes after its pause. The result then has guestRecovery (ConvertTo-DemoSignInRecoveryEvidence); one that
    still fails has PowerShell Direct's error (error, and firstError when the first try's differed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential[]] $Credential,

        [bool] $Clean = $false,

        [bool] $ClearEventLogs = $true,

        [bool] $ClearSecurityLog = $false,

        [bool] $Recover = $false,

        [AllowEmptyString()]
        [string] $RecoveryKey = '',

        [string] $StateRoot = 'C:\ProgramData\DbHubDemo',

        [ValidateCount(0, 5)]
        [ValidateRange(0, 600)]
        [int[]] $RetryDelaySeconds = @(10, 30, 60),

        [ValidateRange(1, 30)]
        [int] $OnlineMinutes = 5
    )

    $by = 'the sign-in data cleanup'
    $recovery = $null
    $reason = ''
    $tries = 0
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($Recover -and $null -ne $vm -and [string]$vm.State -ne 'Running') {
        $recovery = Complete-DemoGuestRecoveryInterrupted -Name $Name -Credential $Credential[0] -StateRoot $StateRoot -Confirm:$false
        if ($null -ne $recovery) {
            $reason = [string]$recovery.Reason
            $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        }
    }
    if ($null -eq $vm -or [string]$vm.State -ne 'Running') {
        $state = 'Missing'
        if ($vm) {
            $state = [string]$vm.State
        }
        $off = [pscustomobject]@{ reachable = $false; state = $state; pass = $false }
        if ($null -ne $recovery) {
            $off | Add-Member -NotePropertyName 'guestRecovery' -NotePropertyValue (ConvertTo-DemoSignInRecoveryEvidence -Recovery $recovery -Guest $Name -Reason $reason -Succeeded $false)
        }
        return $off
    }
    $attempt = Invoke-DemoSignInGuestAttempt -Name $Name -Credential $Credential -Clean $Clean -ClearEventLogs $ClearEventLogs -ClearSecurityLog $ClearSecurityLog
    $tries = 1
    $firstError = ''
    if ($null -eq $attempt.Result) {
        $firstError = $attempt.Error
        $reason = $firstError
        $failedUtc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        $key = $RecoveryKey
        if ($Recover) {
            $key = Get-DemoGuestRecoveryKey -Key $RecoveryKey -Prefix 'signin'
        }
        $restartAsked = $false
        $paused = 0
        $stopped = ''
        foreach ($delay in $RetryDelaySeconds) {
            if ($null -ne $attempt.Result) {
                break
            }
            $lastError = [string]$attempt.Error
            $again = $true
            $probe = $null
            $broken = $false
            if ($Recover) {
                $broken = Test-DemoGuestChannelBroken -Text $lastError
                if (-not $broken) {
                    $probe = Test-DemoGuestChannel -Name $Name -Credential $Credential[0]
                    $broken = [bool]$probe.Broken
                }
            }
            if ($broken -and -not $restartAsked) {
                # Issue #65: a break that's over by now only waits for the guest to answer; one that stays restarts it once.
                $restartAsked = $true
                $recovery = Invoke-DemoGuestRecovery -Name $Name -Credential $Credential[0] -Key $key -By $by -Reason $lastError -StateRoot $StateRoot -Confirm:$false
                $again = [bool]$recovery.Recovered
                if (-not $again) {
                    $stopped = [string]$recovery.Message
                }
            }
            elseif ($null -ne $probe -and [string]$probe.State -ne 'Running') {
                # Not running (another recovery restarts it, for example): a bounded wait that never starts it, so a guest
                # that something keeps off on purpose (a golden capture) stays off.
                $online = $false
                for ($poll = 0; $poll -lt [int][System.Math]::Ceiling($OnlineMinutes * 3) -and -not $online; $poll++) {
                    Start-Sleep -Seconds 20
                    $paused += 20
                    $online = [bool](Test-DemoGuestOnline -Name $Name -Credential $Credential[0])
                }
                $again = $online
                if (-not $online) {
                    $stopped = '{0} didn''t answer over PowerShell Direct within {1} minutes ({2}).' -f $Name, $OnlineMinutes, [string]$probe.State
                }
            }
            else {
                # It answers, or it runs: the next try after a pause, longer each time.
                Start-Sleep -Seconds $delay
                $paused += $delay
            }
            if (-not $again) {
                break
            }
            $attempt = Invoke-DemoSignInGuestAttempt -Name $Name -Credential $Credential -Clean $Clean -ClearEventLogs $ClearEventLogs -ClearSecurityLog $ClearSecurityLog
            $tries++
        }
        # A restart, or the recovery's reason for none, says what was done; otherwise the tries and their pauses do.
        $keepRecovery = $null -ne $recovery -and ([bool]$recovery.Restarted -or ($null -eq $attempt.Result -and [string]$recovery.Action -in 'None', 'Exhausted', 'Busy'))
        if (-not $keepRecovery) {
            $message = if ($null -ne $attempt.Result) {
                '{0} answered the sweep on try {1}, after {2} seconds of pauses.' -f $Name, $tries, $paused
            }
            elseif ($stopped) {
                $stopped
            }
            else {
                '{0} tries over {1} seconds of pauses all failed.' -f $tries, $paused
            }
            $recovery = [pscustomobject]@{ Action = 'Retry'; Restarted = $false; Recovered = ($null -ne $attempt.Result); Seconds = $paused; Reason = $firstError; By = $by; Key = $key; AtUtc = $failedUtc; RestartUtc = ''; StoppedBy = ''; Message = $message }
        }
    }
    if ($null -ne $attempt.Result) {
        $result = $attempt.Result
        $result | Add-Member -NotePropertyName 'reachable' -NotePropertyValue $true -Force
        $result | Add-Member -NotePropertyName 'state' -NotePropertyValue 'Running' -Force
        if ($null -ne $recovery) {
            $result | Add-Member -NotePropertyName 'guestRecovery' -NotePropertyValue (ConvertTo-DemoSignInRecoveryEvidence -Recovery $recovery -Guest $Name -Reason $reason -Succeeded $true -Tries $tries) -Force
        }
        return $result
    }
    $lastError = [string]$attempt.Error
    $endVm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    $endState = if ($endVm) { [string]$endVm.State } else { 'Missing' }
    $failed = [pscustomobject]@{ reachable = $false; state = $endState; pass = $false; error = $lastError.Substring(0, [System.Math]::Min(300, $lastError.Length)) }
    if ($firstError -and $firstError -ne $lastError) {
        $failed | Add-Member -NotePropertyName 'firstError' -NotePropertyValue $firstError.Substring(0, [System.Math]::Min(300, $firstError.Length))
    }
    if ($null -ne $recovery) {
        $failed | Add-Member -NotePropertyName 'guestRecovery' -NotePropertyValue (ConvertTo-DemoSignInRecoveryEvidence -Recovery $recovery -Guest $Name -Reason $reason -Succeeded $false -Tries $tries)
    }
    return $failed
}
# Dot-sourcing (the bootstrap scripts, tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $exitCode = 1
    $lock = $null
    try {
        if ($ResidueAction -notin 'Scan', 'Clean') {
            throw ('Unknown action {0}.' -f $ResidueAction)
        }
        if ($ResidueScope -notin 'Local', 'Guest', 'Both') {
            throw ('Unknown scope {0}.' -f $ResidueScope)
        }
        if ($GuestVmName -notmatch '^[A-Za-z0-9-]{1,15}$') {
            throw 'GuestVmName is not valid.'
        }
        $clean = $ResidueAction -eq 'Clean'
        $clearLogs = $ClearEventLogs -ne 'false'
        $clearSecurity = $ClearSecurityLog -eq 'true'
        $guestScope = $ResidueScope -in 'Guest', 'Both'
        $local = $null
        $guest = $null
        $passes = @()
        # The host bootstrap's lock first, so the host's own sign-in cleanup never sweeps the guest beside this one.
        $lockInfo = $null
        $lockMinutes = 0.0
        if (-not [double]::TryParse([string]$ResidueLockMinutes, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$lockMinutes)) {
            $lockMinutes = 0.0
        }
        if ($guestScope -and $lockMinutes -gt 0) {
            $lockSeconds = [int][System.Math]::Max(1, [System.Math]::Min(7200, [System.Math]::Round($lockMinutes * 60)))
            $lock = Enter-DemoSignInBootstrapLock -Root $ResidueStateRoot -Seconds $lockSeconds
            $lockInfo = [ordered]@{ minutes = $lockMinutes; seconds = [int]$lock.Seconds; timedOut = [bool]$lock.TimedOut }
        }
        if ($null -ne $lockInfo -and [bool]$lockInfo['timedOut']) {
            # Fail closed: nothing is swept beside the host's own sign-in cleanup, and the caller runs this again.
            $busy = [ordered]@{ reachable = $false; state = 'Busy'; pass = $false; error = ('The host bootstrap held its lock (bootstrap.lock) for {0} seconds, so nothing was swept beside its own sign-in cleanup.' -f $lockInfo['seconds']) }
            if ($ResidueScope -eq 'Both') {
                $local = [pscustomobject]$busy
            }
            $guest = [pscustomobject]$busy
            $passes += $false
        }
        else {
            if ($ResidueScope -in 'Local', 'Both') {
                $local = Invoke-DemoSignInSweep -Clean $clean -IncludeBrowserCache ($IncludeBrowserCache -eq 'true') -ClearEventLogs $clearLogs -ClearSecurityLog $clearSecurity
                $passes += [bool]$local.pass
            }
            if ($guestScope) {
                $credentials = @(Get-DemoSignInGuestCredential -Root $ResidueStateRoot)
                if ($credentials.Count -eq 0) {
                    $guest = [pscustomobject]@{ reachable = $false; state = 'NoCredential'; pass = $false }
                }
                else {
                    # Issue #65's recovery comes from the host's installed bundle when it has it (an older one doesn't).
                    $recover = $false
                    $bundleRoot = Get-DemoSignInBundleRoot -Root $ResidueStateRoot
                    if ($bundleRoot) {
                        try {
                            Import-Module -Name ([System.IO.Path]::Combine($bundleRoot, 'vm', 'bootstrap', 'DbHubDemo.Vm.psd1')) -Force
                            . ([System.IO.Path]::Combine($bundleRoot, 'vm', 'hyperv-guest', 'GuestVm.ps1'))
                            Initialize-DemoVmContext -Root $ResidueStateRoot -Role 'ArcHost' -BundleRoot $bundleRoot | Out-Null
                            $recover = Test-DemoSignInRecoveryReady
                        }
                        catch {
                            $recover = $false
                        }
                    }
                    $guest = Invoke-DemoSignInGuestSweep -Name $GuestVmName -Credential $credentials -Clean $clean -ClearEventLogs $clearLogs -ClearSecurityLog $clearSecurity -Recover $recover -RecoveryKey $RecoveryKey -StateRoot $ResidueStateRoot
                }
                $passes += [bool]$guest.pass
            }
        }
        $recoveryEvidence = $null
        if ($null -ne $guest -and $null -ne $guest.PSObject.Properties['guestRecovery']) {
            $recoveryEvidence = $guest.guestRecovery
        }
        # The instance view keeps only the last 4 KB of output, so locations are dropped until the line fits.
        $maxLocations = 6
        do {
            $outcome = [ordered]@{
                action    = $ResidueAction
                scope     = $ResidueScope
                succeeded = $true
                pass      = ($passes.Count -gt 0 -and @($passes | Where-Object { -not $_ }).Count -eq 0)
                local     = ConvertTo-DemoSignInSummary -Sweep $local -MaxLocations $maxLocations
                guest     = ConvertTo-DemoSignInSummary -Sweep $guest -MaxLocations $maxLocations
            }
            if ($null -ne $lockInfo) {
                $outcome['lock'] = $lockInfo
            }
            if ($null -ne $recoveryEvidence) {
                $outcome['guestRecovery'] = $recoveryEvidence
            }
            $line = ConvertTo-Json -InputObject $outcome -Compress -Depth 6
            $maxLocations--
        } while ($line.Length -gt 3800 -and $maxLocations -ge 0)
        [Console]::Out.WriteLine($line)
        $exitCode = 0
    }
    catch {
        $message = [regex]::Replace([string]$_.Exception.Message, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*', '[REDACTED]')
        [Console]::Error.WriteLine('DbHubDemo sign-in data ' + $ResidueAction + ' failed: ' + $message)
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([ordered]@{ action = $ResidueAction; scope = $ResidueScope; succeeded = $false; error = $message }) -Compress))
    }
    finally {
        if ($null -ne $lock -and $null -ne $lock.Stream) {
            $lock.Stream.Dispose()
        }
    }
    exit $exitCode
}
