<#
.SYNOPSIS
Workload control on a demo VM, run through action Run Command by the DbHubDemo module (ADR 0010, ADR 0011).

.DESCRIPTION
The module's inline Run Command script finds this file through settings.json (bundlePath) and calls it with
an action and a Base64-encoded JSON request. It prints exactly one result line, 'DBHUBDEMO-WORKLOAD <json>',
with the action, an ADR 0012 status, a message, and evidence. The action Run Command returns only the last
4,096 bytes of output, so the line is kept under about 3,500 characters. Nothing here is secret: T1 and T2
use Windows authentication, T3 the VM's managed identity, and the guest password stays DPAPI-protected on
the host. Windows PowerShell 5.1.

Actions:
- EnableT3 (sqlvm01) { serverFqdn }: runs the runner's setup on T3 with T1's managed identity (after
  Add-DemoT1ToT3AdminGroup and Invoke-DemoT3SqlFromT1 -Name Setup), records t3-workload.json, sets T3's
  activity profile until the next auto-shutdown, and restarts DbHubDemo-Workload so its host adds T3.
- EnableT4 (sqlvm01) { serverFqdn, adminRole, runnerRole, runnerObjectId, seedScale }: T4 (Phase 24, ADR
  0019). T1's managed identity signs in to the PostgreSQL flexible server as adminRole, the P6 group's
  display name (it's a member, Add-DemoT1ToT3AdminGroup), creates runnerRole for runnerObjectId (its own
  object ID), applies and seeds the schema, records t4-workload.json, sets T4's activity profile, and
  restarts DbHubDemo-Workload so its host adds T4.
- Runner (sqlvm01 for T1, T3, and T4; archost01 relays T2 into the guest over PowerShell Direct)
  { target, arguments[], timeoutSeconds, readySeconds }: runs one runner command. The token {{NEXT_SHUTDOWN}}
  in an argument becomes the next auto-shutdown time, T3 commands get the server's FQDN, and T4 commands the
  flexible server's FQDN and the runner's role. The evidence keeps the end of the runner's output, and the active
  profile's name and expiry, read from the whole output first (re-review of PR 16, 2026-11-04). Before a command
  that starts activity ('profile set' with a profile other than off, or 'run'), the target must accept connections
  within readySeconds (10 minutes by default, 20 for T2; 0 skips the wait): the runner's warmup is retried while it
  fails with a documented transient error (Wait-DemoControlTargetReady), so a cold start doesn't fail the command.
  On archost01 the guest is made ready first (Invoke-DemoControlGuestReady): a golden snapshot's source that the
  capture left air-gapped is released, a restored copy whose Arc identity wasn't reset is never started, and a
  guest that's off starts.
- StopGuest (archost01) { timeoutMinutes }: shuts the guest down cleanly (Stop-VM) and waits until it's
  off, so the host can be deallocated.

.PARAMETER Action
EnableT3, EnableT4, Runner, or StopGuest.

.PARAMETER RequestBase64
The request as Base64-encoded UTF-8 JSON.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.
#>
[CmdletBinding()]
param(
    [string] $Action = '',
    [string] $RequestBase64 = '',
    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ControlBundleRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$script:ControlMarker = 'DBHUBDEMO-WORKLOAD'
# Connection errors that pass by themselves (Test-DemoControlTransientFailure; sources in its help). SqlClient's built-in
# transient list, and -2, its client timeout.
$script:ControlSqlTransient = @(233, 997, 10060, 4060, 4221, 1204, 1205, 1222, 10928, 10929, 40501, 49918, 49919, 49920, 40143, 40197, 40540, 40613, 42108, 42109, -2)
# A local instance that isn't running yet: the network-related or instance-specific errors.
$script:ControlSqlStarting = @(2, 26, 40, 53, -1, 10061)
# Azure SQL Database's transient fault list.
$script:ControlAzureSqlTransient = @(615, 926, 4060, 4221, 40197, 40501, 40613, 49918, 49919, 49920)
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Vm.psd1') -Force

function Write-DemoControlLine {
    # The one line the module parses; a separate function so tests can capture it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    [Console]::Out.WriteLine($Line)
}

function Write-DemoControlResult {
    # Prints the one result line. Long text is cut from the front, so the end of an error survives.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ActionName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')]
        [string] $Status,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Message,

        [System.Collections.IDictionary] $Evidence = @{}
    )

    $safeMessage = Protect-DemoVmText -Text $Message
    if ($safeMessage.Length -gt 800) {
        $safeMessage = '...' + $safeMessage.Substring($safeMessage.Length - 800)
    }
    $result = [ordered]@{
        marker   = $script:ControlMarker
        action   = $ActionName
        status   = $Status
        message  = $safeMessage
        evidence = $Evidence
    }
    $json = Protect-DemoVmText -Text (ConvertTo-Json -InputObject $result -Depth 6 -Compress)
    Write-DemoControlLine -Line ($script:ControlMarker + ' ' + $json)
}

function Get-DemoControlRequest {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{}
    }
    $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value.Trim()))
    $request = ConvertTo-DemoVmHashtable -InputObject ($text | ConvertFrom-Json)
    if ($null -eq $request) {
        return @{}
    }
    return $request
}

function Get-DemoControlTail {
    # The last Length characters of a text, for output that must fit in the Run Command's 4 KB.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [int] $Length = 1500
    )

    $value = ([string]$Text).Trim()
    if ($value.Length -gt $Length) {
        return ('...' + $value.Substring($value.Length - $Length))
    }
    return $value
}

function Get-DemoControlRunnerProfile {
    <#
    .SYNOPSIS
    The active profile's name and expiry from a runner command's whole output, read before Get-DemoControlTail cuts it:
    'status --json' and 'profile get --json' write the profile near the top and the host node last, so once a status
    lists two or more runs, the tail the result keeps has the host node but not the profile, which validate.ps1's
    WORKLOAD.<target>.HOST needs (re-review of PR 16, 2026-11-04). $null for output without a profile node.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    $value = [string]$Text
    $start = $value.IndexOf('{')
    $end = $value.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) {
        return $null
    }
    try {
        $document = $value.Substring($start, $end - $start + 1) | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if ($null -eq $document -or $null -eq $document.PSObject.Properties['profile']) {
        return $null
    }
    $node = $document.profile
    if ($null -eq $node -or $node -is [string] -or $null -eq $node.PSObject.Properties['name']) {
        return $null
    }
    $expires = $null
    if ($null -ne $node.PSObject.Properties['expiresAt'] -and $null -ne $node.expiresAt) {
        $expires = $node.expiresAt
        if ($expires -is [datetime]) {
            $expires = $expires.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $expires = [string]$expires
    }
    return [ordered]@{ name = [string]$node.name; expiresAt = $expires }
}

function Get-DemoControlArgument {
    <#
    .SYNOPSIS
    Validates the runner arguments from a request and replaces {{NEXT_SHUTDOWN}} with the next auto-shutdown.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [string] $NextShutdown
    )

    $arguments = @()
    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            continue
        }
        $text = [string]$item
        if ($text.Length -gt 512 -or $text -match '[\r\n\x00]') {
            throw 'A runner argument is too long or holds a line break.'
        }
        $arguments += $text.Replace('{{NEXT_SHUTDOWN}}', $NextShutdown)
    }
    if ($arguments.Count -eq 0) {
        throw 'The request has no runner arguments.'
    }
    if ($arguments -contains '--target' -or $arguments -contains '-t') {
        throw 'The request must not set --target; the target is a separate field.'
    }
    return , $arguments
}

function Invoke-DemoControlEnableT3 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Request
    )

    $fqdn = ([string]$Request['serverFqdn']).ToLowerInvariant()
    if ($fqdn -notmatch '^[a-z0-9][a-z0-9.-]{1,252}$') {
        Write-DemoControlResult -ActionName 'EnableT3' -Status 'Fail' -Message 'The request has no valid serverFqdn.'
        return
    }
    $paths = Get-DemoVmWorkloadPath -Root $StateRoot
    $install = Read-DemoVmJsonFile -Path $paths.InstallRecord
    if ($null -eq $install -or -not (Test-Path -LiteralPath ([string]$install['dotnetExe']) -PathType Leaf) -or -not (Test-Path -LiteralPath ([string]$install['runnerDll']) -PathType Leaf)) {
        Write-DemoControlResult -ActionName 'EnableT3' -Status 'Fail' -Message 'The workload runner is not installed on T1 yet. Wait for the WorkloadRunner step in health.json (Wait-DemoBootstrapLoader, then the bootstrap task), then run this again.'
        return
    }
    $dotnet = [string]$install['dotnetExe']
    $runner = [string]$install['runnerDll']
    $setup = Invoke-DemoVmRunnerSetup -DotNetExe $dotnet -RunnerDll $runner -Target 'T3' -Server $fqdn
    $evidence = [ordered]@{ serverFqdn = $fqdn; setup = $setup.Status; setupExitCode = $setup.ExitCode }
    if ($setup.Status -notin @('Pass', 'Warning')) {
        Write-DemoControlResult -ActionName 'EnableT3' -Status $setup.Status -Message $setup.Message -Evidence $evidence
        return
    }

    $now = Get-DemoVmUtcNow
    Write-DemoVmJsonFile -Path $paths.T3Marker -InputObject ([ordered]@{ schemaVersion = 1; serverFqdn = $fqdn; enabledUtc = $now; setup = $setup.Status }) -Redact
    $setupRecord = $install['setup']
    if ($null -eq $setupRecord) {
        $setupRecord = [ordered]@{}
    }
    $setupRecord['T3'] = [ordered]@{ status = $setup.Status; utc = $now; message = $setup.Message }
    $install['setup'] = $setupRecord
    Write-DemoVmWorkloadInstall -Root $StateRoot -Record $install

    $status = $setup.Status
    $messages = @($setup.Message)
    $shutdown = Get-DemoVmNextShutdown -Time ([string]$install['autoShutdownTime']) -TimeZoneId ([string]$install['autoShutdownTimeZone'])
    $evidence['notAfter'] = $shutdown.Iso
    if ($shutdown.MinutesLeft -ge 10) {
        $activityProfile = [string]$install['activityProfile']
        $set = Set-DemoVmActivityProfile -DotNetExe $dotnet -RunnerDll $runner -Target 'T3' -Server $fqdn -Name $activityProfile -NotAfter $shutdown.Iso -RequestedBy 'Enable-DemoT3Workload' -Confirm:$false
        $evidence['profile'] = $activityProfile
        $evidence['profileSet'] = $set.Status
        $messages += $set.Message
        if ($set.Status -ne 'Pass' -and $status -eq 'Pass') {
            $status = 'Warning'
        }
    }
    else {
        $evidence['profileSet'] = 'Not selected'
        $messages += ('The next auto-shutdown is {0:N0} minutes away, so no T3 activity was started.' -f $shutdown.MinutesLeft)
    }
    Stop-DemoVmWorkload -Root $StateRoot -Confirm:$false
    Start-DemoVmWorkload -Confirm:$false
    $messages += 'DbHubDemo-Workload was restarted and now hosts T1 and T3.'
    Write-DemoControlResult -ActionName 'EnableT3' -Status $status -Message ($messages -join ' ') -Evidence $evidence
}

function Invoke-DemoControlEnableT4 {
    # T4 (Phase 24, ADR 0019): T1's identity signs in as the P6 group's role (adminRole), creates the runner's
    # role for its own object ID, applies and seeds the schema, records t4-workload.json, sets T4's profile,
    # and restarts DbHubDemo-Workload so its host adds T4. No token or password is in the request.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Request
    )

    $fqdn = ([string]$Request['serverFqdn']).ToLowerInvariant()
    $adminRole = [string]$Request['adminRole']
    $runnerRole = [string]$Request['runnerRole']
    $objectId = [string]$Request['runnerObjectId']
    $seedScale = 1
    if ($Request.Contains('seedScale') -and [int]$Request['seedScale'] -ge 1) {
        $seedScale = [System.Math]::Min(50, [int]$Request['seedScale'])
    }
    $problem = ''
    if ($fqdn -notmatch '^[a-z0-9][a-z0-9.-]{1,252}$') {
        $problem = 'The request has no valid serverFqdn.'
    }
    elseif ($adminRole -notmatch '^[A-Za-z0-9_().-][A-Za-z0-9 _().-]{0,61}[A-Za-z0-9_().-]$') {
        $problem = 'The request has no valid adminRole (the P6 group''s display name).'
    }
    elseif ($runnerRole -notmatch '^[a-z_][a-z0-9_]{0,62}$') {
        $problem = 'The request has no valid runnerRole.'
    }
    elseif ($objectId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $problem = 'The request has no valid runnerObjectId (T1''s managed identity object ID).'
    }
    if ($problem) {
        Write-DemoControlResult -ActionName 'EnableT4' -Status 'Fail' -Message $problem
        return
    }
    $paths = Get-DemoVmWorkloadPath -Root $StateRoot
    $install = Read-DemoVmJsonFile -Path $paths.InstallRecord
    if ($null -eq $install -or -not (Test-Path -LiteralPath ([string]$install['dotnetExe']) -PathType Leaf) -or -not (Test-Path -LiteralPath ([string]$install['runnerDll']) -PathType Leaf)) {
        Write-DemoControlResult -ActionName 'EnableT4' -Status 'Fail' -Message 'The workload runner is not installed on T1 yet. Wait for the WorkloadRunner step in health.json (Wait-DemoBootstrapLoader, then the bootstrap task), then run this again.'
        return
    }
    if (-not (Test-DemoVmNameResolve -HostName $fqdn)) {
        Write-DemoControlResult -ActionName 'EnableT4' -Status 'Fail' -Message ('{0} does not resolve on T1: the private DNS zone that T4''s virtual network integration links to the network has no record for it yet.' -f $fqdn) -Evidence @{ serverFqdn = $fqdn }
        return
    }
    $dotnet = [string]$install['dotnetExe']
    $runner = [string]$install['runnerDll']
    $setup = Invoke-DemoVmRunnerSetup -DotNetExe $dotnet -RunnerDll $runner -Target 'T4' -Server $fqdn -User $adminRole -IncludeBaseSchema -SeedScale $seedScale -GrantEntraObjectId $objectId -RunnerRole $runnerRole
    $evidence = [ordered]@{ serverFqdn = $fqdn; runnerRole = $runnerRole; seedScale = $seedScale; setup = $setup.Status; setupExitCode = $setup.ExitCode }
    if ($setup.Status -notin @('Pass', 'Warning')) {
        Write-DemoControlResult -ActionName 'EnableT4' -Status $setup.Status -Message $setup.Message -Evidence $evidence
        return
    }

    $now = Get-DemoVmUtcNow
    Write-DemoVmJsonFile -Path $paths.T4Marker -InputObject ([ordered]@{ schemaVersion = 1; serverFqdn = $fqdn; adminRole = $adminRole; runnerRole = $runnerRole; enabledUtc = $now; setup = $setup.Status }) -Redact
    $setupRecord = $install['setup']
    if ($null -eq $setupRecord) {
        $setupRecord = [ordered]@{}
    }
    $setupRecord['T4'] = [ordered]@{ status = $setup.Status; utc = $now; message = $setup.Message }
    $install['setup'] = $setupRecord
    Write-DemoVmWorkloadInstall -Root $StateRoot -Record $install

    $status = $setup.Status
    $messages = @($setup.Message)
    $shutdown = Get-DemoVmNextShutdown -Time ([string]$install['autoShutdownTime']) -TimeZoneId ([string]$install['autoShutdownTimeZone'])
    $evidence['notAfter'] = $shutdown.Iso
    if ($shutdown.MinutesLeft -ge 10) {
        $activityProfile = [string]$install['activityProfile']
        $set = Set-DemoVmActivityProfile -DotNetExe $dotnet -RunnerDll $runner -Target 'T4' -Server $fqdn -Name $activityProfile -NotAfter $shutdown.Iso -RequestedBy 'Enable-DemoT4Workload' -Confirm:$false
        $evidence['profile'] = $activityProfile
        $evidence['profileSet'] = $set.Status
        $messages += $set.Message
        if ($set.Status -ne 'Pass' -and $status -eq 'Pass') {
            $status = 'Warning'
        }
    }
    else {
        $evidence['profileSet'] = 'Not selected'
        $messages += ('The next auto-shutdown is {0:N0} minutes away, so no T4 activity was started.' -f $shutdown.MinutesLeft)
    }
    Stop-DemoVmWorkload -Root $StateRoot -Confirm:$false
    Start-DemoVmWorkload -Confirm:$false
    $messages += 'DbHubDemo-Workload was restarted and now also hosts T4.'
    Write-DemoControlResult -ActionName 'EnableT4' -Status $status -Message ($messages -join ' ') -Evidence $evidence
}

function Get-DemoControlUtcNow {
    # The readiness waits' clock, in a function of its own so tests can move it.
    [CmdletBinding()]
    [OutputType([datetime])]
    param()

    return [DateTime]::UtcNow
}

function Test-DemoControlActivityCommand {
    <#
    .SYNOPSIS
    True for runner arguments that start activity: 'profile set' with any profile but off, or 'run'. Only those wait
    for their target, and on T2 make the guest ready first; a read, a stop, or a reset changes nothing beforehand.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyCollection()]
        [string[]] $Arguments = @()
    )

    $list = @($Arguments)
    if ($list.Count -ge 1 -and $list[0] -eq 'run') {
        return $true
    }
    if ($list.Count -lt 2 -or $list[0] -ne 'profile' -or $list[1] -ne 'set') {
        return $false
    }
    for ($index = 2; $index -lt $list.Count - 1; $index++) {
        if ($list[$index] -eq '--name') {
            return ($list[$index + 1] -ne 'off')
        }
    }
    return $true
}

function Get-DemoControlReadyTimeout {
    # How long a target may take to accept connections before its activity starts: the request's readySeconds (0 to
    # 1800; 0 skips the wait), or 20 minutes for T2, whose guest may have to start first, and 10 for the others.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Target,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Request
    )

    if ($Request.Contains('readySeconds') -and $null -ne $Request['readySeconds']) {
        return [int][System.Math]::Max(0, [System.Math]::Min(1800, [int]$Request['readySeconds']))
    }
    if ($Target -eq 'T2') {
        return 1200
    }
    return 600
}

function Test-DemoControlTransientFailure {
    <#
    .SYNOPSIS
    True when a runner's failure (its standard error and output, or an exception's text) is a connection error that
    passes by itself on that target, so the readiness wait tries again. Pure.

    .DESCRIPTION
    - T1 and T2, SQL Server on the VM or in the guest: SqlClient's built-in transient errors (233, 997, 10060, 4060,
      4221, 1204, 1205, 1222, 10928, 10929, 40501, 49918, 49919, 49920, 40143, 40197, 40540, 40613, 42108, 42109), its
      client timeout (-2), and the network-related or instance-specific errors of an instance that isn't running yet
      (2, 26, 40, 53, -1, 10061). Live, 2026-11-03: T1's 'profile set' ran 2 minutes before SQL Server accepted
      connections and failed with SQL error 2. On T2 also a PowerShell Direct session that a guest's start ended.
    - T3, Azure SQL Database serverless: SqlClient's list and Azure SQL Database's transient faults (615, 926, 4060,
      4221, 40197, 40501, 40613, 49918, 49919, 49920), 40613 above all while a paused database resumes.
    - T4, the PostgreSQL flexible server: a connection that can't be opened while the server starts, SQLSTATE class 08
      (connection exception), 57P01, 57P02, 57P03 (shutdown, crash shutdown, cannot connect now) and 53300 (too many
      connections), or Npgsql's failure to connect (a refused or timed-out socket).
    - Any target: the managed identity endpoint not answering yet right after a boot, and a warmup that ran out of time.
    Anything else means the target answered.
    Sources (checked 2026-11-03):
    - https://learn.microsoft.com/sql/connect/ado-net/internal-retry-logic-providers-sqlclient (built-in transient list)
    - https://learn.microsoft.com/troubleshoot/sql/database-engine/connect/network-related-or-instance-specific-error-occurred-while-establishing-connection
    - https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-errors-issues (transient fault list)
    - https://learn.microsoft.com/azure/postgresql/troubleshoot/concepts-connectivity, and PostgreSQL's error codes:
      https://www.postgresql.org/docs/current/errcodes-appendix.html
    - https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token (retry guidance)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    $value = [string]$Text
    if (-not $value.Trim()) {
        return $false
    }
    if ($value -match '(?i)did not finish within \d+ seconds') {
        return $true
    }
    if ($value -match '(?i)ManagedIdentityCredential' -and $value -match '(?i)unavailable|timed out|no response|not respond|refused|\b(404|410|429|5\d\d)\b') {
        return $true
    }
    if ($Target -eq 'T4') {
        if ($value -match '(?i)PostgreSQL error (08[0-9A-Z]{3}|57P0[123]|53300)\b') {
            return $true
        }
        return [bool]($value -match '(?i)failed to connect|exception while connecting|actively refused|connection refused|no connection could be made|timeout during|timed out|database system is starting up')
    }
    if ($Target -eq 'T2' -and $value -match '(?i)not in running state|session might have ended') {
        return $true
    }
    $known = $script:ControlSqlTransient + $script:ControlSqlStarting
    if ($Target -eq 'T3') {
        $known = $script:ControlSqlTransient + $script:ControlAzureSqlTransient
    }
    $numbers = @([regex]::Matches($value, '(?i)\bSQL error (-?\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
    foreach ($number in $numbers) {
        if ($known -contains $number) {
            return $true
        }
    }
    return [bool]($numbers.Count -eq 0 -and $value -match '(?i)TimeoutException|timeout expired')
}

function Wait-DemoControlTargetReady {
    <#
    .SYNOPSIS
    Waits, bounded, until a target accepts connections: Probe runs the runner's 'warmup' (a connection and a light
    query) once per attempt, with the attempt's time limit as its argument, and returns the run (ExitCode, StdOut,
    StdErr). A transient failure (Test-DemoControlTransientFailure) is tried again after 5 seconds, then twice as long
    each time up to 60 seconds, as Learn recommends for Azure SQL and PostgreSQL connections. Any other failure means
    the target answered: the caller's command goes on and reports anything that's still wrong. Returns Status (Ready,
    Answered, or TimedOut), Attempts, Seconds, and LastError.
    Sources: https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-errors-issues#implement-retry-logic,
    https://learn.microsoft.com/azure/postgresql/troubleshoot/concepts-connectivity (checked 2026-11-03).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target,

        [Parameter(Mandatory = $true)]
        [scriptblock] $Probe,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 600,

        [ValidateRange(1, 300)]
        [int] $FirstDelaySeconds = 5,

        [ValidateRange(1, 300)]
        [int] $MaxDelaySeconds = 60
    )

    $start = Get-DemoControlUtcNow
    $deadline = $start.AddSeconds($TimeoutSeconds)
    $delay = $FirstDelaySeconds
    $attempts = 0
    $lastError = ''
    while ($true) {
        $attempts++
        $left = [int][System.Math]::Ceiling(($deadline - (Get-DemoControlUtcNow)).TotalSeconds)
        $passed = $false
        $text = ''
        try {
            $run = & $Probe ([System.Math]::Max(30, [System.Math]::Min(300, $left)))
            if ($null -ne $run -and [int]$run.ExitCode -eq 0) {
                $passed = $true
            }
            elseif ($null -ne $run) {
                $text = Get-DemoControlTail -Text (([string]$run.StdErr) + ' ' + ([string]$run.StdOut)) -Length 600
            }
        }
        catch {
            $text = Get-DemoControlTail -Text ([string]$_.Exception.Message) -Length 600
        }
        $seconds = [int][System.Math]::Max(0, ((Get-DemoControlUtcNow) - $start).TotalSeconds)
        if ($passed) {
            return [pscustomobject]@{ Status = 'Ready'; Attempts = $attempts; Seconds = $seconds; LastError = $lastError }
        }
        $lastError = $text
        if (-not (Test-DemoControlTransientFailure -Target $Target -Text $text)) {
            return [pscustomobject]@{ Status = 'Answered'; Attempts = $attempts; Seconds = $seconds; LastError = $lastError }
        }
        if ((Get-DemoControlUtcNow).AddSeconds($delay) -ge $deadline) {
            return [pscustomobject]@{ Status = 'TimedOut'; Attempts = $attempts; Seconds = $seconds; LastError = $lastError }
        }
        Start-Sleep -Seconds $delay
        $delay = [System.Math]::Min($MaxDelaySeconds, $delay * 2)
    }
}

function Get-DemoControlTargetArgument {
    <#
    .SYNOPSIS
    The target options a runner command gets on sqlvm01: --target, and the server (T3's FQDN; T4's FQDN and the runner's
    role) from the install record unless the arguments name one. Returns Arguments, or Error when the target isn't set
    up on this VM.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Target,

        [AllowEmptyCollection()]
        [string[]] $Arguments = @(),

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Install
    )

    $full = @($Arguments) + @('--target', $Target)
    if ($Target -eq 'T3' -and $full -notcontains '--server') {
        $t3 = $null
        if ($Install.Contains('t3')) {
            $t3 = $Install['t3']
        }
        if ($null -eq $t3 -or -not $t3['serverFqdn']) {
            return [pscustomobject]@{ Arguments = @(); Error = 'T1 has no T3 server in its workload settings.' }
        }
        $full += @('--server', [string]$t3['serverFqdn'])
    }
    if ($Target -eq 'T4') {
        $t4 = $null
        if ($Install.Contains('t4')) {
            $t4 = $Install['t4']
        }
        if ($null -eq $t4 -or -not $t4['serverFqdn']) {
            return [pscustomobject]@{ Arguments = @(); Error = 'T1 has no T4 server in its workload settings: T4 is off (t4Enabled), or T1 was bootstrapped before T4 existed (deploy.ps1 -Resume updates it).' }
        }
        if ($full -notcontains '--server') {
            $full += @('--server', [string]$t4['serverFqdn'])
        }
        if ($full -notcontains '--user' -and $t4['runnerRole']) {
            $full += @('--user', [string]$t4['runnerRole'])
        }
    }
    return [pscustomobject]@{ Arguments = $full; Error = '' }
}

function Get-DemoControlGoldenDecision {
    <#
    .SYNOPSIS
    What T2's relay does with a golden snapshot's capture record before activity starts (ADR 0018, sections 4 and 5).
    Returns Action (None, Release, or Refuse) and Reason (NoCapture, Released, Source, ResetCopy, CopyNotReset, or
    VmIdUnknown). Pure.

    .DESCRIPTION
    - No record, or one that's released: nothing to do.
    - The host's Azure VM ID is the record's sourceAzureVmId: the capture's source, which the capture may have left
      air-gapped. The golden script's own Release releases it: on the source it only reconnects the guest's adapter and
      restores its automatic start, because the Arc identity is still its own.
    - A copy whose Arc identity was reset (resetUtc): the same Release, which skips the reset it already did.
    - A copy that wasn't reset may still hold the captured identity, so it's never started here: deploy.ps1 resets it
      while it's air-gapped. Nor is a host whose VM ID couldn't be read, because it can't be told from such a copy.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Capture,

        [AllowEmptyString()]
        [string] $AzureVmId = ''
    )

    if ($null -eq $Capture) {
        return [pscustomobject]@{ Action = 'None'; Reason = 'NoCapture' }
    }
    $read = {
        param([string] $Name)
        $property = $Capture.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) {
            return ''
        }
        return [string]$property.Value
    }
    if ((& $read 'released') -eq 'True') {
        return [pscustomobject]@{ Action = 'None'; Reason = 'Released' }
    }
    if (-not $AzureVmId) {
        return [pscustomobject]@{ Action = 'Refuse'; Reason = 'VmIdUnknown' }
    }
    $source = & $read 'sourceAzureVmId'
    if ($source -and [string]::Equals($source, $AzureVmId, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Action = 'Release'; Reason = 'Source' }
    }
    if (& $read 'resetUtc') {
        return [pscustomobject]@{ Action = 'Release'; Reason = 'ResetCopy' }
    }
    return [pscustomobject]@{ Action = 'Refuse'; Reason = 'CopyNotReset' }
}

function Invoke-DemoControlGuestCommand {
    # One script block in the guest over PowerShell Direct (VMBus, no network); a function of its own so tests can mock it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $GuestName,

        [Parameter(Mandatory = $true)]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,

        [AllowEmptyCollection()]
        [object[]] $ArgumentList = @()
    )

    return (Invoke-Command -VMName $GuestName -Credential $Credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop)
}

$script:ControlGuestWarmupBlock = {
    # In the guest: one 'warmup --target T2', with the guest's own runner. Only functions every guest module has.
    param($Folder, $TimeoutSeconds)
    $modulePath = Join-Path -Path $Folder -ChildPath 'module\DbHubDemo.Vm.psd1'
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw 'T2 isn''t set up yet: the guest gets its demo module after SQL Server setup, so the workload runner is not installed in the guest yet.'
    }
    Import-Module -Name $modulePath -Force
    $install = Read-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $Folder).InstallRecord
    if ($null -eq $install) {
        throw 'The workload runner is not installed in the guest yet.'
    }
    Invoke-DemoVmRunnerProcess -DotNetExe ([string]$install['dotnetExe']) -RunnerDll ([string]$install['runnerDll']) -ArgumentList @('warmup', '--target', 'T2', '--json') -TimeoutSeconds $TimeoutSeconds
}

function Invoke-DemoControlGuestReady {
    <#
    .SYNOPSIS
    T2's guest, made ready before activity starts on it: a golden snapshot's source that the capture left air-gapped
    is released, a restored copy whose Arc identity wasn't reset is refused, a guest that's off starts, and then,
    within TimeoutSeconds, the guest runs with a heartbeat, answers over PowerShell Direct, runs SQL Server, and accepts
    connections. Returns Status (Pass or Fail), Message, Evidence, and Credential (the one that signed in).

    .DESCRIPTION
    Live, 2026-11-03: a capture on 10-28 left its source's guest off, with no automatic start and its adapter
    disconnected, and only start-demo.ps1 or deploy.ps1 released it, so every start from the Fabric notebook found
    the guest off ("The virtual machine arcsql01 is not in running state") and T2 was missing for six days.
    The golden script from this bundle (Invoke-DemoGoldenGuest.ps1) is dot-sourced and its functions are reused: the
    capture record, the host's Azure VM ID, the bootstrap lock, the Release (on the source it only reconnects the
    adapter, sets the automatic start back to Start, starts the guest, and records released and releasedUtc; on a reset
    copy it skips the reset), the guest wait that also tries a pending password, and the SQL Server wait (SQL Server is
    started at once if its delayed automatic start hasn't started it). The snapshot's tag dbhubSourceReleasedUtc isn't
    written here (the host has no rights on rg-<prefix>-golden): start-demo.ps1 or deploy.ps1 writes it later, and
    their Release finds the source released and only confirms it. A guest that's off without a capture record gets
    the automatic start action Start, its designed state (GuestVm.ps1), and starts.
    Sources: https://learn.microsoft.com/powershell/module/hyper-v/get-vm, https://learn.microsoft.com/powershell/module/hyper-v/set-vm,
    https://learn.microsoft.com/powershell/module/hyper-v/start-vm,
    https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct (checked 2026-11-03).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [string] $GuestName,

        [Parameter(Mandatory = $true)]
        [string] $AdministratorName,

        [Parameter(Mandatory = $true)]
        [string] $ToolsFolder,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 1200
    )

    $start = Get-DemoControlUtcNow
    $deadline = $start.AddSeconds($TimeoutSeconds)
    $left = { [int][System.Math]::Max(1, [System.Math]::Ceiling(($deadline - (Get-DemoControlUtcNow)).TotalSeconds)) }
    $evidence = [ordered]@{ guest = $GuestName }
    $fail = {
        param([string] $Message)
        $evidence['seconds'] = [int][System.Math]::Max(0, ((Get-DemoControlUtcNow) - $start).TotalSeconds)
        return [pscustomobject]@{ Status = 'Fail'; Message = $Message; Evidence = $evidence; Credential = $null }
    }

    # The golden script's functions, from this bundle; dot-sourcing runs nothing.
    . ([System.IO.Path]::Combine($script:ControlBundleRoot, 'vm', 'bootstrap', 'Invoke-DemoGoldenGuest.ps1')) -GuestName $GuestName -Root $StateRoot
    $script:Options = @{ Root = $StateRoot; SnapshotName = ''; ProveIsolation = $false; KeepIsolated = $false; SkipRotation = $true }
    $capture = Read-GoldenJson -Path ([System.IO.Path]::Combine($StateRoot, 'golden', 'capture.json'))
    $decision = Get-DemoControlGoldenDecision -Capture $capture
    if ($decision.Reason -eq 'VmIdUnknown') {
        # A record whose air gap isn't released: is this host its source, or a copy?
        $vmId = ''
        try {
            $vmId = Get-GoldenImdsVmId
        }
        catch {
            $vmId = ''
        }
        $decision = Get-DemoControlGoldenDecision -Capture $capture -AzureVmId $vmId
    }
    $evidence['golden'] = $decision.Reason
    if ($decision.Action -eq 'Refuse') {
        if ($decision.Reason -eq 'CopyNotReset') {
            return (& $fail ('{0} runs a copy restored from the golden snapshot {1}, and its Arc identity hasn''t been reset yet, so its guest stays off and air-gapped. Run ./scripts/deploy.ps1: its T2 track resets the copy while the guest is still air-gapped, then releases it. Never reconnect it by hand.' -f $env:COMPUTERNAME, [string]$capture.snapshotName))
        }
        return (& $fail ('The capture record names a golden snapshot ({0}) whose air gap isn''t released, and this host''s Azure VM ID couldn''t be read, so it can''t tell the snapshot''s source from a copy and leaves the guest off. Run ./scripts/start-demo.ps1 (it releases a capture''s source), or ./scripts/deploy.ps1 for a restored copy.' -f [string]$capture.snapshotName))
    }
    if ($decision.Action -eq 'Release') {
        $lock = $null
        try {
            $lock = Enter-GoldenLock -TimeoutSeconds ([System.Math]::Min(300, (& $left)))
            $release = Invoke-GoldenRelease -Setting (Get-GoldenHostSetting)
            $evidence['released'] = [string]$release['role']
        }
        catch {
            return (& $fail ('The air gap that a golden capture left on {0} couldn''t be released: {1} Run ./scripts/start-demo.ps1, which releases it too.' -f $GuestName, [string]$_.Exception.Message))
        }
        finally {
            if ($null -ne $lock) {
                $lock.Dispose()
            }
        }
    }

    $vm = Get-VM -Name $GuestName -ErrorAction SilentlyContinue
    if (-not $vm) {
        return (& $fail ('T2 isn''t set up yet: the host hasn''t created its guest {0}.' -f $GuestName))
    }
    $evidence['stateBefore'] = [string]$vm.State
    if ([string]$vm.State -in 'Off', 'Saved') {
        if ([string]$vm.AutomaticStartAction -ne 'Start') {
            $evidence['startActionBefore'] = [string]$vm.AutomaticStartAction
            Set-VM -Name $GuestName -AutomaticStartAction Start -AutomaticStartDelay 0
        }
        try {
            Start-VM -Name $GuestName -ErrorAction Stop
        }
        catch {
            # Hyper-V's own automatic start may have started it a moment earlier.
            $now = Get-VM -Name $GuestName -ErrorAction SilentlyContinue
            if (-not $now -or [string]$now.State -notin 'Running', 'Starting') {
                return (& $fail ('{0} is {1} and couldn''t be started: {2}' -f $GuestName, [string]$vm.State, [string]$_.Exception.Message))
            }
        }
        $evidence['started'] = $true
    }

    # Running, with a heartbeat from its integration services.
    $vm = Get-VM -Name $GuestName -ErrorAction SilentlyContinue
    while (-not ($vm -and [string]$vm.State -eq 'Running' -and [string]$vm.Heartbeat -like 'Ok*')) {
        if ((Get-DemoControlUtcNow).AddSeconds(10) -ge $deadline) {
            $state = if ($vm) { '{0}, heartbeat {1}' -f [string]$vm.State, [string]$vm.Heartbeat } else { 'missing' }
            return (& $fail ('{0} didn''t run with a heartbeat within {1} seconds ({2}).' -f $GuestName, $TimeoutSeconds, $state))
        }
        Start-Sleep -Seconds 10
        $vm = Get-VM -Name $GuestName -ErrorAction SilentlyContinue
    }

    # PowerShell Direct, with the stored credential or a pending one that a rotation left.
    try {
        $wait = Wait-GoldenGuest -UserName $AdministratorName -TimeoutSeconds (& $left)
    }
    catch {
        return (& $fail ([string]$_.Exception.Message))
    }
    $credential = $wait.Credential

    # SQL Server's service: started at once if its delayed automatic start hasn't started it yet.
    try {
        $sql = Invoke-DemoControlGuestCommand -GuestName $GuestName -Credential $credential -ScriptBlock $script:GuestSqlWaitBlock -ArgumentList @((& $left), 0)
    }
    catch {
        return (& $fail ('SQL Server''s service in {0} couldn''t be checked: {1}' -f $GuestName, [string]$_.Exception.Message))
    }
    $evidence['sqlService'] = [string]$sql.status
    $evidence['sqlStartedHere'] = [bool]$sql.startedByScript
    if ([string]$sql.status -ne 'Running') {
        return (& $fail ('SQL Server''s service in {0} is {1} after {2} seconds.' -f $GuestName, [string]$sql.status, [int]$sql.seconds))
    }

    # Connections: the guest's runner warmup, tried again while it fails with a transient error.
    $guestFolder = $ToolsFolder
    $probe = {
        param($AttemptSeconds)
        Invoke-DemoControlGuestCommand -GuestName $GuestName -Credential $credential -ScriptBlock $script:ControlGuestWarmupBlock -ArgumentList @($guestFolder, $AttemptSeconds)
    }
    $ready = Wait-DemoControlTargetReady -Target 'T2' -Probe $probe -TimeoutSeconds (& $left)
    $evidence['ready'] = $ready.Status
    $evidence['readyAttempts'] = $ready.Attempts
    $evidence['seconds'] = [int][System.Math]::Max(0, ((Get-DemoControlUtcNow) - $start).TotalSeconds)
    if ($ready.Status -eq 'TimedOut') {
        return (& $fail ('SQL Server in {0} didn''t accept connections within {1} seconds: {2}' -f $GuestName, $TimeoutSeconds, (Get-DemoControlTail -Text $ready.LastError -Length 300)))
    }
    return [pscustomobject]@{ Status = 'Pass'; Message = ''; Evidence = $evidence; Credential = $credential }
}

function Invoke-DemoControlRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Request,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Settings
    )

    $target = [string]$Request['target']
    $timeout = 1800
    if ($Request.Contains('timeoutSeconds') -and [int]$Request['timeoutSeconds'] -ge 30) {
        $timeout = [System.Math]::Min(5400, [int]$Request['timeoutSeconds'])
    }
    $workload = Get-DemoVmWorkloadSetting -Settings $Settings
    $shutdown = Get-DemoVmNextShutdown -Time $workload.AutoShutdownTime -TimeZoneId $workload.AutoShutdownTimeZone
    $arguments = Get-DemoControlArgument -Value $Request['arguments'] -NextShutdown $shutdown.Iso
    $role = [string]$Settings['role']
    $label = 'runner ' + (@($arguments | Select-Object -First 2) -join ' ') + ' --target ' + $target
    # Activity waits for its target, bounded; reads, stops, and resets don't (Test-DemoControlActivityCommand).
    $activity = Test-DemoControlActivityCommand -Arguments $arguments
    $readySeconds = Get-DemoControlReadyTimeout -Target $target -Request $Request
    $readyNote = [ordered]@{}

    if ($role -eq 'SqlVm' -and $target -in @('T1', 'T3', 'T4')) {
        $install = Read-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $StateRoot).InstallRecord
        if ($null -eq $install) {
            Write-DemoControlResult -ActionName 'Runner' -Status 'Fail' -Message 'The workload runner is not installed on T1 yet.'
            return
        }
        $targetArguments = Get-DemoControlTargetArgument -Target $target -Arguments $arguments -Install $install
        if ($targetArguments.Error) {
            Write-DemoControlResult -ActionName 'Runner' -Status 'Fail' -Message $targetArguments.Error
            return
        }
        $full = $targetArguments.Arguments
        $dotnet = [string]$install['dotnetExe']
        $runnerDll = [string]$install['runnerDll']
        if ($activity -and $readySeconds -gt 0) {
            # The same target options as the command, so the warmup connects exactly as the command will.
            $warmup = (Get-DemoControlTargetArgument -Target $target -Arguments @('warmup', '--json') -Install $install).Arguments
            $probe = {
                param($AttemptSeconds)
                Invoke-DemoVmRunnerProcess -DotNetExe $dotnet -RunnerDll $runnerDll -ArgumentList $warmup -TimeoutSeconds $AttemptSeconds
            }
            $ready = Wait-DemoControlTargetReady -Target $target -Probe $probe -TimeoutSeconds $readySeconds
            $readyNote['ready'] = $ready.Status
            $readyNote['readySeconds'] = $ready.Seconds
            $readyNote['readyAttempts'] = $ready.Attempts
            if ($ready.Status -eq 'TimedOut') {
                $evidence = [ordered]@{ target = $target; ready = $ready.Status; readySeconds = $ready.Seconds; readyAttempts = $ready.Attempts; lastError = (Get-DemoControlTail -Text $ready.LastError -Length 400) }
                Write-DemoControlResult -ActionName 'Runner' -Status 'Fail' -Message ('{0}: {1} didn''t accept connections within {2} seconds ({3} attempts), so nothing was set. The last error: {4}' -f $label, $target, $readySeconds, $ready.Attempts, (Get-DemoControlTail -Text $ready.LastError -Length 300)) -Evidence $evidence
                return
            }
        }
        $run = Invoke-DemoVmRunnerProcess -DotNetExe $dotnet -RunnerDll $runnerDll -ArgumentList $full -TimeoutSeconds $timeout
    }
    elseif ($role -eq 'ArcHost' -and $target -eq 'T2') {
        $guest = Import-PowerShellDataFile -Path ([System.IO.Path]::Combine($script:ControlBundleRoot, 'vm', 'dsc', 'guest.psd1'))
        $guestName = [string]$guest.Name
        if ($Settings.Contains('guest') -and $null -ne $Settings['guest'] -and $Settings['guest']['name']) {
            $guestName = [string]$Settings['guest']['name']
        }
        if ($activity) {
            # Live, 2026-11-03: the control's start found the guest off and air-gapped since a golden capture.
            $prepared = Invoke-DemoControlGuestReady -StateRoot $StateRoot -GuestName $guestName -AdministratorName ([string]$guest.AdministratorName) -ToolsFolder ([string]$guest.ToolsFolder) -TimeoutSeconds ([System.Math]::Max(60, $readySeconds))
            foreach ($key in $prepared.Evidence.Keys) {
                $readyNote[$key] = $prepared.Evidence[$key]
            }
            if ($prepared.Evidence.Contains('seconds')) {
                $readyNote['readySeconds'] = [int]$prepared.Evidence['seconds']
            }
            if ($prepared.Status -ne 'Pass') {
                $evidence = [ordered]@{ target = $target }
                foreach ($key in $readyNote.Keys) {
                    $evidence[$key] = $readyNote[$key]
                }
                Write-DemoControlResult -ActionName 'Runner' -Status $prepared.Status -Message ('{0}: {1}' -f $label, $prepared.Message) -Evidence $evidence
                return
            }
            $credential = $prepared.Credential
        }
        else {
            . ([System.IO.Path]::Combine($script:ControlBundleRoot, 'vm', 'hyperv-guest', 'GuestVm.ps1'))
            $credential = Get-DemoGuestCredential -SecretPath ([System.IO.Path]::Combine($StateRoot, 'protected', 'guest-administrator.bin')) -UserName $guest.AdministratorName
        }
        $full = @($arguments) + @('--target', 'T2')
        $run = Invoke-DemoControlGuestCommand -GuestName $guestName -Credential $credential -ArgumentList @($guest.ToolsFolder, $full, $timeout) -ScriptBlock {
            param($Folder, $Arguments, $TimeoutSeconds)
            $modulePath = Join-Path -Path $Folder -ChildPath 'module\DbHubDemo.Vm.psd1'
            if (-not (Test-Path -LiteralPath $modulePath)) {
                # Before SQL Server setup, the guest has no demo module yet (Phase 28 live finding): the caller reports
                # Not selected, not a Warning.
                throw 'T2 isn''t set up yet: the guest gets its demo module after SQL Server setup, so the workload runner is not installed in the guest yet.'
            }
            Import-Module -Name $modulePath -Force
            $install = Read-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $Folder).InstallRecord
            if ($null -eq $install) {
                throw 'The workload runner is not installed in the guest yet.'
            }
            Invoke-DemoVmRunnerProcess -DotNetExe ([string]$install['dotnetExe']) -RunnerDll ([string]$install['runnerDll']) -ArgumentList $Arguments -TimeoutSeconds $TimeoutSeconds
        }
    }
    else {
        Write-DemoControlResult -ActionName 'Runner' -Status 'Fail' -Message ('Target {0} is not driven from this VM (role {1}): T1, T3, and T4 run on sqlvm01, T2 through archost01.' -f $target, $role)
        return
    }

    $outcome = Get-DemoVmRunnerOutcome -Run $run -Label $label
    $evidence = [ordered]@{
        target   = $target
        exitCode = [int]$run.ExitCode
        stdout   = Get-DemoControlTail -Text $run.StdOut -Length 1800
        stderr   = Get-DemoControlTail -Text $run.StdErr -Length 500
    }
    foreach ($key in $readyNote.Keys) {
        $evidence[$key] = $readyNote[$key]
    }
    # The profile from the whole output, which the cut stdout can no longer show (re-review of PR 16, 2026-11-04).
    $runnerProfile = Get-DemoControlRunnerProfile -Text $run.StdOut
    if ($null -ne $runnerProfile) {
        $evidence['profile'] = $runnerProfile
    }
    $message = $outcome.Message
    if ($readyNote.Contains('readySeconds') -and [int]$readyNote['readySeconds'] -gt 0) {
        $message = '{0} ({1} accepted connections after {2} seconds.)' -f $message, $target, [int]$readyNote['readySeconds']
    }
    Write-DemoControlResult -ActionName 'Runner' -Status $outcome.Status -Message $message -Evidence $evidence
}

function Invoke-DemoControlStopGuest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Request,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Settings
    )

    $guest = Import-PowerShellDataFile -Path ([System.IO.Path]::Combine($script:ControlBundleRoot, 'vm', 'dsc', 'guest.psd1'))
    $guestName = [string]$guest.Name
    if ($Settings.Contains('guest') -and $null -ne $Settings['guest'] -and $Settings['guest']['name']) {
        $guestName = [string]$Settings['guest']['name']
    }
    $minutes = 10
    if ($Request.Contains('timeoutMinutes') -and [int]$Request['timeoutMinutes'] -ge 1) {
        $minutes = [System.Math]::Min(30, [int]$Request['timeoutMinutes'])
    }
    $vm = Get-VM -Name $guestName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-DemoControlResult -ActionName 'StopGuest' -Status 'Pass' -Message ('There is no guest {0} on this host.' -f $guestName) -Evidence @{ guest = $guestName; state = 'NotCreated' }
        return
    }
    if ([string]$vm.State -eq 'Off') {
        Write-DemoControlResult -ActionName 'StopGuest' -Status 'Pass' -Message ('{0} is already off.' -f $guestName) -Evidence @{ guest = $guestName; state = 'Off' }
        return
    }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    # A guest operating system shutdown through the Hyper-V shutdown integration service; -Force only skips
    # the prompt that a signed-in session would otherwise raise.
    Stop-VM -Name $guestName -Force -AsJob | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes($minutes)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ([string](Get-VM -Name $guestName).State -eq 'Off') {
            Write-DemoControlResult -ActionName 'StopGuest' -Status 'Pass' -Message ('{0} shut down cleanly in {1:N0} seconds.' -f $guestName, $clock.Elapsed.TotalSeconds) -Evidence @{ guest = $guestName; state = 'Off'; seconds = [int]$clock.Elapsed.TotalSeconds }
            return
        }
        Start-Sleep -Seconds 5
    }
    $state = [string](Get-VM -Name $guestName).State
    Write-DemoControlResult -ActionName 'StopGuest' -Status 'Warning' -Message ('{0} was still {1} after {2} minutes. Deallocating the host shuts it down through its automatic stop action (ShutDown).' -f $guestName, $state, $minutes) -Evidence @{ guest = $guestName; state = $state; seconds = [int]$clock.Elapsed.TotalSeconds }
}

function Invoke-DemoWorkloadControl {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $ActionName,

        [AllowEmptyString()]
        [string] $Request,

        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    $settings = Read-DemoVmJsonFile -Path (Join-Path -Path $StateRoot -ChildPath 'settings.json')
    if ($null -eq $settings) {
        Write-DemoControlResult -ActionName $ActionName -Status 'Fail' -Message 'settings.json is missing; the bootstrap loader has not run on this VM.'
        return
    }
    $role = [string]$settings['role']
    Initialize-DemoVmContext -Root $StateRoot -Role $role -BundleRoot $script:ControlBundleRoot | Out-Null
    $body = Get-DemoControlRequest -Value $Request
    switch ($ActionName) {
        'EnableT3' {
            if ($role -ne 'SqlVm') {
                Write-DemoControlResult -ActionName $ActionName -Status 'Fail' -Message 'EnableT3 runs on T1 (sqlvm01).'
                return
            }
            Invoke-DemoControlEnableT3 -StateRoot $StateRoot -Request $body
        }
        'EnableT4' {
            if ($role -ne 'SqlVm') {
                Write-DemoControlResult -ActionName $ActionName -Status 'Fail' -Message 'EnableT4 runs on T1 (sqlvm01).'
                return
            }
            Invoke-DemoControlEnableT4 -StateRoot $StateRoot -Request $body
        }
        'Runner' {
            Invoke-DemoControlRunner -StateRoot $StateRoot -Request $body -Settings $settings
        }
        'StopGuest' {
            if ($role -ne 'ArcHost') {
                Write-DemoControlResult -ActionName $ActionName -Status 'Fail' -Message 'StopGuest runs on the T2 host (archost01).'
                return
            }
            Invoke-DemoControlStopGuest -Request $body -Settings $settings
        }
        default {
            Write-DemoControlResult -ActionName ([string]$ActionName) -Status 'Fail' -Message 'Unknown action; use EnableT3, EnableT4, Runner, or StopGuest.'
        }
    }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-DemoWorkloadControl -ActionName $Action -Request $RequestBase64 -StateRoot $Root
    }
    catch {
        Write-DemoControlResult -ActionName ([string]$Action) -Status 'Fail' -Message ('The control action failed: {0}' -f $_.Exception.Message)
    }
    exit 0
}
