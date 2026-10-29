# SQL Server media, setup, and database configuration inside the T2 guest (ADR 0003, ADR 0006).
# Windows PowerShell 5.1 on the Hyper-V host; every in-guest action runs over PowerShell Direct.
# Dot-sourced by vm/bootstrap/Invoke-HostBootstrap.ps1.

function Test-DemoGuestFile {
    # True when the guest file exists and has the expected SHA-256.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedSha256
    )

    $hash = Invoke-Command -VMName $Name -Credential $Credential -ArgumentList $Path -ErrorAction Stop -ScriptBlock {
        param($FilePath)
        if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
            (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return ([string]$hash -eq $ExpectedSha256.ToLowerInvariant())
}

function Copy-DemoGuestFile {
    <#
    .SYNOPSIS
    Copies a host file into the guest over PowerShell Direct and verifies its SHA-256 there (fail closed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedSha256
    )

    $session = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop
    try {
        $folder = Split-Path -Path $DestinationPath -Parent
        Invoke-Command -Session $session -ScriptBlock { New-Item -ItemType Directory -Path $using:folder -Force | Out-Null }
        Copy-Item -ToSession $session -Path $SourcePath -Destination $DestinationPath -Force
    }
    finally {
        Remove-PSSession -Session $session
    }
    if (-not (Test-DemoGuestFile -Name $Name -Credential $Credential -Path $DestinationPath -ExpectedSha256 $ExpectedSha256)) {
        Invoke-Command -VMName $Name -Credential $Credential -ArgumentList $DestinationPath -ScriptBlock {
            param($FilePath)
            Remove-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue
        }
        throw ('The copy of {0} in the guest does not match SHA-256 {1}; it was deleted (fail closed).' -f (Split-Path -Path $SourcePath -Leaf), $ExpectedSha256)
    }
    Write-DemoVmLog -Message ('Copied {0} into the guest and verified its SHA-256.' -f (Split-Path -Path $SourcePath -Leaf))
}

function Test-DemoGuestWebView2 {
    # True when the guest has a per-machine WebView2 runtime: the documented 'pv' value under the EdgeUpdate
    # client key exists and isn't 0.0.0.0 (https://learn.microsoft.com/microsoft-edge/webview2/concepts/distribution).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential
    )

    $version = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
        $item = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -Name 'pv' -ErrorAction SilentlyContinue
        if ($item) {
            [string]$item.pv
        }
    }
    return (-not [string]::IsNullOrEmpty([string]$version) -and [string]$version -ne '0.0.0.0')
}

function Install-DemoGuestWebView2 {
    # Runs the WebView2 standalone installer silently in the guest ('/silent /install') and waits for it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [string] $InstallerPath,

        [ValidateRange(1, 60)]
        [int] $TimeoutMinutes = 20
    )

    $exitCode = Invoke-Command -VMName $Name -Credential $Credential -ArgumentList $InstallerPath, $TimeoutMinutes -ErrorAction Stop -ScriptBlock {
        param($Path, $Minutes)
        $process = Start-Process -FilePath $Path -ArgumentList '/silent', '/install' -PassThru
        # Reading the handle now keeps ExitCode available after the process ends.
        $null = $process.Handle
        if (-not $process.WaitForExit($Minutes * 60000)) {
            throw ('The WebView2 installer was still running after {0} minutes.' -f $Minutes)
        }
        $process.ExitCode
    }
    if ([int]$exitCode -ne 0) {
        throw ('The WebView2 installer exited with code {0} in the guest.' -f $exitCode)
    }
}

# Sign-in data in the guest (ADR 0009). The setup wizard's interactive sign-in (PaygWizard) and every Arc onboarding
# can leave sign-in data in the guest. Invoke-DemoSignInSweep (vm/bootstrap/Invoke-DemoSignInResidue.ps1, which the
# host bootstrap dot-sources) removes it and verifies that none remains. The functions below run it and the other
# checks in the guest over PowerShell Direct, or locally on the evaluation-only VM. They never output a value.

function Get-DemoSetupProcess {
    # Names of SQL Server setup processes still running: the wizard's window (ScenarioEngine) and the programs that
    # start it. Runs where it's called: in the guest over PowerShell Direct, or locally on the evaluation-only VM.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(Get-Process -Name 'ScenarioEngine', 'setup', 'SetupARP' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.ProcessName } | Select-Object -Unique)
}

function Test-DemoIeEscEnabled {
    # True when Internet Explorer Enhanced Security Configuration is on for administrators and for users, the
    # Windows Server default. An operator may turn it off during the wizard, though the Azure sign-in doesn't need
    # that (it needs WebView2). A component that doesn't exist counts as on.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $Root = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components'
    )

    foreach ($id in '{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}', '{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}') {
        $item = Get-ItemProperty -LiteralPath ('{0}\{1}' -f $Root, $id) -Name 'IsInstalled' -ErrorAction SilentlyContinue
        if ($item -and [int]$item.IsInstalled -ne 1) {
            return $false
        }
    }
    return $true
}

function Enable-DemoIeEsc {
    # Turns IE Enhanced Security Configuration back on for administrators and users.
    [CmdletBinding()]
    param(
        [string] $Root = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components'
    )

    foreach ($id in '{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}', '{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}') {
        $path = '{0}\{1}' -f $Root, $id
        if (Test-Path -LiteralPath $path) {
            Set-ItemProperty -LiteralPath $path -Name 'IsInstalled' -Value 1
        }
    }
}

function Get-DemoGuestSignInResidue {
    # Over PowerShell Direct, read-only: the sweep with the browser and broker caches, whether IE ESC is on, and the
    # setup processes still running. Pass is the sweep's result.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential
    )

    $sweep = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock ${function:Invoke-DemoSignInSweep} -ArgumentList $false, $true
    $ieEsc = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock ${function:Test-DemoIeEscEnabled}
    $setup = @(Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock ${function:Get-DemoSetupProcess})
    return [pscustomobject]@{ Pass = [bool]$sweep.pass; SecurityLogTokens = [int]$sweep.found.securityLogTokens; Sweep = $sweep; IeEscEnabled = [bool]$ieEsc; SetupProcess = @($setup | Where-Object { $_ }) }
}

function Clear-DemoGuestSignInResidue {
    # Over PowerShell Direct: removes the sign-in data in the guest and scans again (the sweep's Clean, with the
    # browser and broker caches), then turns IE ESC back on. Returns the sweep's result.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential
    )

    $sweep = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock ${function:Invoke-DemoSignInSweep} -ArgumentList $true, $true
    Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock ${function:Enable-DemoIeEsc}
    return $sweep
}

function Get-DemoSignInStepResult {
    # After a cleanup that passed: Manual action required when a token-shaped value is in a Security log, which
    # nothing clears on its own; Done with a warning when the cleanup cleared an event log, which endpoint
    # protection may report; nothing otherwise. Sweep and Label are parallel arrays (one per machine); VmName is the
    # Azure VM that check-sign-in-data.ps1 reaches them through.
    [CmdletBinding()]
    param(
        [object[]] $Sweep,

        [string[]] $Label,

        [string] $VmName = 'archost01'
    )

    $security = @()
    $cleared = @()
    for ($index = 0; $index -lt @($Sweep).Count; $index++) {
        $item = @($Sweep)[$index]
        if ($null -eq $item -or -not $item.PSObject.Properties['remaining']) {
            continue
        }
        if ([int]$item.remaining.securityLogTokens -gt 0) {
            $security += @($Label)[$index]
        }
        if ($item.PSObject.Properties['actions'] -and $null -ne $item.actions) {
            foreach ($log in @($item.actions.eventLogsCleared)) {
                if ($log) {
                    $cleared += ('{0} on {1}' -f $log, @($Label)[$index])
                }
            }
        }
    }
    if ($security.Count -gt 0) {
        $steps = @(
            ('The Security log on {0} holds token-shaped values. Nothing clears that log on its own, because clearing it erases the audit trail and endpoint protection may report it.' -f ($security -join ' and '))
            ('After you review it, clear it from your PC with ./scripts/check-sign-in-data.ps1 -VmName {0} -Clean -ClearSecurityLog, or on each machine in an elevated prompt with: wevtutil clear-log Security' -f $VmName)
            'The host checks again within about 5 minutes and continues on its own.'
        )
        return (New-DemoVmStepResult -Outcome 'ManualActionRequired' -Message $steps[0] -Instruction $steps)
    }
    if ($cleared.Count -gt 0) {
        return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage ('The sign-in cleanup cleared {0}, because they held token-shaped values; endpoint protection may report a cleared event log.' -f ($cleared -join ', ')))
    }
    return $null
}

function Format-DemoSignInSweep {
    # One line for the log and the step's message: what the sweep found, did, and left. Counts and location names
    # only, never a value.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Sweep,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    if ($null -eq $Sweep -or -not $Sweep.PSObject.Properties['found'] -or $null -eq $Sweep.found) {
        return ('{0}: not checked.' -f $Label)
    }
    $member = {
        param([string] $Name)
        $property = $Sweep.PSObject.Properties[$Name]
        if ($property) {
            return $property.Value
        }
        return $null
    }
    $describe = {
        param($Counts)
        if ($null -eq $Counts) {
            return 'nothing'
        }
        $parts = @()
        $userData = [int]$Counts.userTokens + [int]$Counts.otherTokens
        if ($userData -gt 0) { $parts += ('{0} sign-in token(s) in {1} file(s)' -f $userData, [int]$Counts.filesWithUserData) }
        if ([int]$Counts.eventLogUserTokens -gt 0) { $parts += ('{0} in event logs' -f [int]$Counts.eventLogUserTokens) }
        if ($Counts.PSObject.Properties['securityLogTokens'] -and [int]$Counts.securityLogTokens -gt 0) { $parts += ('{0} in the Security log' -f [int]$Counts.securityLogTokens) }
        if ($Counts.PSObject.Properties['productKeys'] -and [int]$Counts.productKeys + [int]$Counts.eventLogKeys -gt 0) { $parts += ('{0} product key(s)' -f ([int]$Counts.productKeys + [int]$Counts.eventLogKeys)) }
        if ([int]$Counts.browserCaches -gt 0) { $parts += ('{0} browser sign-in cache(s)' -f [int]$Counts.browserCaches) }
        if ([int]$Counts.archives -gt 0) { $parts += ('{0} archive(s) in setup''s log folders that couldn''t be checked' -f [int]$Counts.archives) }
        if ([int]$Counts.filesUnverified -gt 0) { $parts += ('{0} unreadable file(s)' -f [int]$Counts.filesUnverified) }
        if ([int]$Counts.appTokens + [int]$Counts.eventLogAppTokens -gt 0) { $parts += ('{0} token(s) of an application or managed identity' -f ([int]$Counts.appTokens + [int]$Counts.eventLogAppTokens)) }
        $autoLogon = @('autoLogonEnabled', 'autoLogonSecrets', 'autoLogonPasswords', 'autoLogonUnverified' | Where-Object { $Counts.PSObject.Properties[$_] -and [int]$Counts.$_ -gt 0 })
        if ($autoLogon.Count -gt 0) { $parts += ('automatic sign-in left armed ({0})' -f ($autoLogon -join ', ')) }
        if ($Counts.PSObject.Properties['autoLogonUserNames'] -and [int]$Counts.autoLogonUserNames -gt 0) { $parts += 'the Winlogon DefaultUserName value' }
        if ($parts.Count -eq 0) { return 'nothing' }
        return ($parts -join ', ')
    }
    $places = @(@(& $member 'foundLocations') | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.location } | Select-Object -Unique)
    $logs = @(@(& $member 'foundEventLogs') | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.log })
    $text = '{0}: found {1}' -f $Label, (& $describe $Sweep.found)
    if ($places.Count -gt 0 -or $logs.Count -gt 0) {
        $text += ' (in {0})' -f ((@($places) + @($logs)) -join ', ')
    }
    $actions = & $member 'actions'
    if ([bool](& $member 'cleaned') -and $null -ne $actions) {
        $text += '; redacted {0} file(s), deleted {1}, removed {2} cache(s), cleared {3} event log(s); left: {4}' -f [int]$actions.filesRedacted, [int]$actions.filesDeleted, ([int]$actions.cachesRemoved + [int]$actions.brokerEntriesRemoved), @($actions.eventLogsCleared).Count, (& $describe (& $member 'remaining'))
    }
    return ($text + '.')
}
function Copy-DemoGuestTool {
    # Puts the VM module and the database scripts in the guest, so SQL runs locally there.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [string] $BundleRoot,

        [Parameter(Mandatory = $true)]
        [string] $GuestToolsFolder
    )

    $session = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop
    try {
        $moduleFolder = Join-Path -Path $GuestToolsFolder -ChildPath 'module'
        $databaseFolder = Join-Path -Path $GuestToolsFolder -ChildPath 'database'
        Invoke-Command -Session $session -ScriptBlock {
            New-Item -ItemType Directory -Path $using:moduleFolder -Force | Out-Null
            New-Item -ItemType Directory -Path $using:databaseFolder -Force | Out-Null
        }
        $moduleSource = [System.IO.Path]::Combine($BundleRoot, 'vm', 'bootstrap')
        foreach ($item in @('DbHubDemo.Vm.psd1', 'DbHubDemo.Vm.psm1', 'lib')) {
            Copy-Item -ToSession $session -Path (Join-Path -Path $moduleSource -ChildPath $item) -Destination $moduleFolder -Recurse -Force
        }
        Copy-Item -ToSession $session -Path (Join-Path -Path $BundleRoot -ChildPath 'database\*') -Destination $databaseFolder -Recurse -Force
    }
    finally {
        Remove-PSSession -Session $session
    }
}

function Mount-DemoGuestIso {
    # Mounts the SQL Server ISO inside the guest (if needed) and returns its drive letter.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [string] $IsoPath
    )

    return [string](Invoke-Command -VMName $Name -Credential $Credential -ArgumentList $IsoPath -ErrorAction Stop -ScriptBlock {
            param($ImagePath)
            $image = Get-DiskImage -ImagePath $ImagePath
            if (-not $image.Attached) {
                $image = Mount-DiskImage -ImagePath $ImagePath -PassThru
            }
            ($image | Get-Volume).DriveLetter
        })
}

function Get-DemoGuestSqlInstance {
    <#
    .SYNOPSIS
    Reports the default instance in the guest: service state, and edition and version when it can connect.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential
    )

    return (Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
            $service = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
            $result = [ordered]@{ ServiceExists = [bool]$service; Running = $false; Edition = ''; ProductVersion = ''; IsSysAdmin = $false; Error = '' }
            if ($service) {
                $result.Running = [string]$service.Status -eq 'Running'
            }
            if ($result.Running) {
                try {
                    $connection = New-Object -TypeName 'System.Data.SqlClient.SqlConnection' -ArgumentList 'Data Source=.;Initial Catalog=master;Integrated Security=True;Application Name=DbHubDemo.Bootstrap;Connect Timeout=15'
                    $connection.Open()
                    $command = $connection.CreateCommand()
                    $command.CommandText = "SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)), IS_SRVROLEMEMBER('sysadmin')"
                    $reader = $command.ExecuteReader()
                    if ($reader.Read()) {
                        $result.Edition = [string]$reader.GetValue(0)
                        $result.ProductVersion = [string]$reader.GetValue(1)
                        $result.IsSysAdmin = ([string]$reader.GetValue(2) -eq '1')
                    }
                    $reader.Dispose()
                    $connection.Dispose()
                }
                catch {
                    $result.Error = $_.Exception.Message
                }
            }
            [pscustomobject]$result
        })
}

function Get-DemoSqlSetupArgument {
    <#
    .SYNOPSIS
    The unattended SQL Server 2022 setup switches from "Install SQL Server from the command prompt" (Microsoft
    Learn), shared by the nested guest and the evaluation-only Azure VM (ADR 0006). /PID comes only from
    protected input and is registered for redaction; the Developer media has its key predefined.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Sql,

        [securestring] $ProductKey
    )

    $arguments = @(
        '/Q'
        '/ACTION=Install'
        ('/FEATURES={0}' -f $Sql.Features)
        ('/INSTANCENAME={0}' -f $Sql.InstanceName)
        ('/SQLSVCACCOUNT="{0}"' -f $Sql.ServiceAccount)
        ('/AGTSVCACCOUNT="{0}"' -f $Sql.AgentAccount)
        '/AGTSVCSTARTUPTYPE=Automatic'
        ('/SQLSYSADMINACCOUNTS="{0}"' -f $Sql.SysAdminAccounts)
        '/TCPENABLED=1'
        '/UPDATEENABLED=False'
        '/USESQLRECOMMENDEDMEMORYLIMITS'
        '/IACCEPTSQLSERVERLICENSETERMS'
        '/SUPPRESSPRIVACYSTATEMENTNOTICE'
    )
    if ($null -ne $ProductKey) {
        $key = ConvertFrom-DemoSecureString -SecureValue $ProductKey
        Register-DemoVmSecret -Value $key
        $arguments += ('/PID="{0}"' -f $key)
    }
    return $arguments
}

function Install-DemoGuestSql {
    <#
    .SYNOPSIS
    Unattended SQL Server 2022 setup in the guest, with switches from "Install SQL Server from the command
    prompt" (Microsoft Learn). ProductKey mode passes /PID from protected input; the Developer media has
    its product key predefined, so Developer mode passes none. Returns setup's exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [string] $IsoPath,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Sql,

        [securestring] $ProductKey
    )

    $arguments = Get-DemoSqlSetupArgument -Sql $Sql -ProductKey $ProductKey
    $drive = Mount-DemoGuestIso -Name $Name -Credential $Credential -IsoPath $IsoPath
    Write-DemoVmLog -Message ('Running SQL Server setup in the guest from {0}: (this takes 10 to 30 minutes).' -f $drive)
    $outcome = Invoke-Command -VMName $Name -Credential $Credential -ArgumentList $drive, $arguments -ErrorAction Stop -ScriptBlock {
        param($Drive, $SetupArguments)
        $process = Start-Process -FilePath ('{0}:\setup.exe' -f $Drive) -ArgumentList $SetupArguments -Wait -PassThru -WindowStyle Hidden
        $summary = Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
        $tail = ''
        if ($summary) {
            $tail = (Get-Content -LiteralPath $summary.FullName -Tail 15) -join ' | '
        }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Summary = $tail }
    }
    if ($outcome.ExitCode -ne 0 -and $outcome.ExitCode -ne 3010) {
        throw ('SQL Server setup failed with exit code {0}. Summary: {1}' -f $outcome.ExitCode, (Protect-DemoVmText -Text $outcome.Summary))
    }
    Write-DemoVmLog -Message ('SQL Server setup finished with exit code {0}.' -f $outcome.ExitCode)
    return [int]$outcome.ExitCode
}

function Invoke-DemoGuestSqlScript {
    # Runs bundle SQL files inside the guest with the copied VM module (Windows authentication only).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [string] $GuestToolsFolder,

        [Parameter(Mandatory = $true)]
        [string[]] $RelativePath,

        [Parameter(Mandatory = $true)]
        [string] $Database,

        [hashtable] $Token = @{}
    )

    Invoke-Command -VMName $Name -Credential $Credential -ArgumentList $GuestToolsFolder, $RelativePath, $Database, $Token -ErrorAction Stop -ScriptBlock {
        param($Folder, $Paths, $DatabaseName, $Tokens)
        Import-Module -Name (Join-Path -Path $Folder -ChildPath 'module\DbHubDemo.Vm.psd1') -Force
        foreach ($relative in $Paths) {
            Invoke-DemoVmSqlScript -Path (Join-Path -Path (Join-Path -Path $Folder -ChildPath 'database') -ChildPath $relative) -Database $DatabaseName -Token $Tokens
        }
    }
}

function Invoke-DemoGuestSqlQuery {
    # One query inside the guest; returns rows.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [string] $GuestToolsFolder,

        [Parameter(Mandatory = $true)]
        [string] $Query,

        [string] $Database = 'master'
    )

    return (Invoke-Command -VMName $Name -Credential $Credential -ArgumentList $GuestToolsFolder, $Query, $Database -ErrorAction Stop -ScriptBlock {
            param($Folder, $Text, $DatabaseName)
            Import-Module -Name (Join-Path -Path $Folder -ChildPath 'module\DbHubDemo.Vm.psd1') -Force
            Invoke-DemoVmSql -Query $Text -Database $DatabaseName -TimeoutSeconds 3600
        })
}
