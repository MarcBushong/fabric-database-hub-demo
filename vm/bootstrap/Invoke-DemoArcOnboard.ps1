<#
.SYNOPSIS
Phase 7: probes the T2 guest's Azure Connected Machine agent, onboards the guest to Azure Arc with a
short-lived token, and writes the Arc marker the host state machine waits for (ADR 0004, ADR 0005).

.DESCRIPTION
The orchestrator (Invoke-DemoArcOnboarding) runs this script on the T2 host archost01 in a managed Run Command.
Windows PowerShell 5.1. It loads the DbHubDemo.Vm module and the guest helpers from the installed bootstrap
bundle (settings.json, bundlePath), so it needs a host that the Phase 6 loader has bootstrapped.

Actions:
- Probe: read-only. Reports whether the guest answers over PowerShell Direct, whether it can reach IMDS or
  the wire server (it must not, ADR 0004), whether DNS works, and the agent's state from 'azcmagent show -j'.
- Onboard: checks the guest's isolation again (fail closed), downloads the Windows Installer package from the
  documented link, verifies it (pinned SHA-256 when one is set, otherwise a valid Authenticode signature
  whose subject matches AgentSignerPattern), copies it into the guest over PowerShell Direct (SHA-256 checked
  again there), installs it silently (msiexec /i /qn /l*v), and runs 'azcmagent connect --config <file>
  --subscription-id --tenant-id --resource-group --location --resource-name --tags --cloud --correlation-id'
  INSIDE the guest. The token reaches the guest only as an argument to the remote script block, and the agent
  only in that JSON file ("access-token", the agent's common flag --config), in a folder that only SYSTEM and
  Administrators can read; the file is overwritten with zeros and deleted right after, so the token is never on
  a command line, in script text, or in a log (ADR 0009). Only if the agent rejects the file or waits for a
  sign-in does it get the token on its command line, once, and the result says so. With the host identity, a
  connect that Azure refuses for authorization is retried after 30, 60, 120, 120, and 120 seconds, because a new
  role assignment can take minutes to propagate. With DisconnectLocalFirst, 'azcmagent disconnect --force-local-only'
  resets an agent whose Azure resource was deleted. When the agent is already Connected to the expected
  machine, connect is skipped. Then it checks that the agent is Connected, writes the marker
  C:\ProgramData\DbHubDemo\arc-onboarded.json ({ schemaVersion 1, machineName, status Connected, resourceId,
  connectedUtc }, plus guestVmId so a rebuilt guest doesn't reuse it), and starts the DbHubDemo-Bootstrap task.
- WriteMarker: checks that the agent is Connected to the expected machine, then writes the marker and starts
  the task.

MSFT_ARC_TEST is never set in the nested guest, and the host's Azure guest agent is never touched (ADR 0004).
In the opt-in evaluation-only mode (Mode EvaluationOnlyAzureVm, ADR 0006) there's no guest: the same steps
run locally on the Azure VM arcsql01, following Microsoft's evaluation procedure (MSFT_ARC_TEST set, IMDS
blocked; the bootstrap disables the Azure guest agent last).

The last line of output is one compact JSON object; errors go to standard error, redacted. Exit code 0 means
the action succeeded.

.PARAMETER Action
Probe, Onboard, or WriteMarker.

.PARAMETER AgentSignerPatternBase64
The required Authenticode signer subject text, Base64-encoded UTF-8 because it contains spaces and Run
Command passes parameters as '-Name value' arguments. Empty means 'O=Microsoft Corporation'.

.PARAMETER AccessToken
The caller's Azure Resource Manager token, passed only as a protected Run Command parameter (ADR 0005). Run
Command passes protected parameters to the script as arguments, so the host's PowerShell can log it; the
sign-in data sweep after onboarding removes it (ADR 0009). With the host identity, nothing is passed.

.PARAMETER TokenSource
Parameter (the default: AccessToken) or HostIdentity (the least-privilege identity id-<prefix>-<env>-arc-onboard;
a token from the host's IMDS with IdentityClientId, which never leaves the host and the guest).
#>
[CmdletBinding()]
param(
    [string] $Action = 'Probe',
    [string] $SubscriptionId = '',
    [string] $TenantId = '',
    [string] $ResourceGroup = '',
    [string] $Location = '',
    [string] $MachineName = 'arcsql01',
    [string] $Tags = '',
    [string] $CorrelationId = '',
    [string] $Cloud = 'AzureCloud',
    [string] $AgentUrl = 'https://aka.ms/AzureConnectedMachineAgent',
    [string] $AgentSha256 = '',
    [string] $AgentSignerPatternBase64 = '',
    [string] $AgentMaxCacheDays = '7',
    [string] $DisconnectLocalFirst = 'false',
    [string] $TokenSource = 'Parameter',
    [string] $IdentityClientId = '',
    [string] $Mode = 'Nested',
    [string] $AccessToken = '',
    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DemoArcBlock {
    <#
    .SYNOPSIS
    The script blocks that run in the guest over PowerShell Direct, or locally in the evaluation-only mode.

    .DESCRIPTION
    Probe is read-only. Install installs the agent from a verified package, and is skipped when the agent is
    already installed. Connect receives the token only as an argument and clears its copy before returning.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Probe', 'Install', 'Connect')]
        [string] $Name
    )

    if ($Name -eq 'Probe') {
        return {
            param($CheckWireServer)
            $ErrorActionPreference = 'Continue'
            function Test-DemoPort {
                param([string] $Address, [int] $Port)
                $client = New-Object -TypeName 'System.Net.Sockets.TcpClient'
                try {
                    $attempt = $client.BeginConnect($Address, $Port, $null, $null)
                    if (-not $attempt.AsyncWaitHandle.WaitOne(3000)) {
                        return $false
                    }
                    return [bool]$client.Connected
                }
                catch {
                    return $false
                }
                finally {
                    $client.Close()
                }
            }
            $exe = Join-Path -Path $env:ProgramFiles -ChildPath 'AzureConnectedMachineAgent\azcmagent.exe'
            $dns = $false
            try {
                $dns = @(Resolve-DnsName -Name 'management.azure.com' -QuickTimeout -ErrorAction Stop).Count -gt 0
            }
            catch {
                $dns = $false
            }
            $wire = $false
            if ($CheckWireServer) {
                $wire = Test-DemoPort -Address '168.63.129.16' -Port 80
            }
            $agentJson = ''
            if (Test-Path -LiteralPath $exe) {
                $agentJson = ((& $exe show -j 2>$null) | ForEach-Object { [string]$_ }) -join "`n"
            }
            [pscustomobject]@{
                ComputerName        = $env:COMPUTERNAME
                AgentInstalled      = (Test-Path -LiteralPath $exe)
                AgentJson           = $agentJson
                ImdsReachable       = (Test-DemoPort -Address '169.254.169.254' -Port 80)
                WireServerReachable = $wire
                DnsResolves         = $dns
                MsftArcTest         = [string][Environment]::GetEnvironmentVariable('MSFT_ARC_TEST', 'Machine')
            }
        }
    }
    if ($Name -eq 'Install') {
        return {
            param($MsiPath, $LogPath)
            $ErrorActionPreference = 'Continue'
            $exe = Join-Path -Path $env:ProgramFiles -ChildPath 'AzureConnectedMachineAgent\azcmagent.exe'
            if (Test-Path -LiteralPath $exe) {
                return [pscustomobject]@{ ExitCode = 0; Skipped = $true }
            }
            $logFolder = Split-Path -Path $LogPath -Parent
            if (-not (Test-Path -LiteralPath $logFolder)) {
                New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
            }
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', ('"{0}"' -f $MsiPath), '/qn', '/l*v', ('"{0}"' -f $LogPath)) -Wait -PassThru -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Skipped = $false }
        }
    }
    return {
        param($Token, $Subscription, $Tenant, $Group, $Region, $Name, $CloudName, $Correlation, $TagText, $DisconnectFirst, $Evaluation, $TimeoutSeconds, $AgentPath, $TokenFolder)
        $ErrorActionPreference = 'Continue'
        $exe = [string]$AgentPath
        if (-not $exe) {
            $exe = Join-Path -Path $env:ProgramFiles -ChildPath 'AzureConnectedMachineAgent\azcmagent.exe'
        }
        $folder = [string]$TokenFolder
        if (-not $folder) {
            $folder = Join-Path -Path $env:ProgramData -ChildPath 'DbHubDemo\arc-connect'
        }
        $seconds = 600
        if ($TimeoutSeconds) {
            $seconds = [int]$TimeoutSeconds
        }
        if ($Evaluation) {
            $env:MSFT_ARC_TEST = 'true'
        }
        function Invoke-DemoAgentProcess {
            # Runs the agent with a time limit, so a sign-in prompt it might wait for can't hold the onboarding.
            param([string[]] $ArgumentList)
            $text = @($ArgumentList | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
            $info = New-Object -TypeName 'System.Diagnostics.ProcessStartInfo' -ArgumentList $exe, $text
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.CreateNoWindow = $true
            $process = [System.Diagnostics.Process]::Start($info)
            try {
                $out = $process.StandardOutput.ReadToEndAsync()
                $err = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit($seconds * 1000)) {
                    try {
                        $process.Kill()
                    }
                    catch {
                        Write-Verbose -Message 'The agent had already exited.'
                    }
                    return [pscustomobject]@{ ExitCode = -1; Output = ('azcmagent was stopped after {0} seconds.' -f $seconds); TimedOut = $true }
                }
                $process.WaitForExit()
                return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = ([string]$out.Result + [string]$err.Result); TimedOut = $false }
            }
            finally {
                $process.Dispose()
            }
        }
        $notes = @()
        if ($DisconnectFirst) {
            $null = & $exe disconnect --force-local-only 2>&1
            $notes += ('azcmagent disconnect --force-local-only exited with {0}.' -f $LASTEXITCODE)
        }
        $common = @('--subscription-id', $Subscription, '--tenant-id', $Tenant, '--resource-group', $Group, '--location', $Region, '--resource-name', $Name, '--cloud', $CloudName, '--correlation-id', $Correlation)
        if ($TagText) {
            $common += @('--tags', $TagText)
        }
        # The token reaches the agent in a file that only SYSTEM, Administrators, and the account running this can
        # read, never on its command line, which process auditing and endpoint protection can record (the agent's
        # common flag --config takes any option from a JSON file). The file is overwritten with zeros and deleted
        # right after.
        $file = Join-Path -Path $folder -ChildPath ([guid]::NewGuid().ToString('N') + '.json')
        $passedBy = 'ConfigFile'
        $run = $null
        try {
            if (-not (Test-Path -LiteralPath $folder)) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
            }
            if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
                $acl = New-Object -TypeName 'System.Security.AccessControl.DirectorySecurity'
                $acl.SetAccessRuleProtection($true, $false)
                $accounts = @((New-Object -TypeName 'System.Security.Principal.SecurityIdentifier' -ArgumentList 'S-1-5-18'), (New-Object -TypeName 'System.Security.Principal.SecurityIdentifier' -ArgumentList 'S-1-5-32-544'), [System.Security.Principal.WindowsIdentity]::GetCurrent().User)
                foreach ($account in $accounts) {
                    $acl.AddAccessRule((New-Object -TypeName 'System.Security.AccessControl.FileSystemAccessRule' -ArgumentList $account, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
                }
                Set-Acl -LiteralPath $folder -AclObject $acl
            }
            $content = ConvertTo-Json -InputObject @{ 'access-token' = [string]$Token } -Compress
            [System.IO.File]::WriteAllText($file, $content, (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
            $content = $null
            $run = Invoke-DemoAgentProcess -ArgumentList (@('connect', '--config', $file) + $common)
        }
        finally {
            if (Test-Path -LiteralPath $file) {
                try {
                    $length = [int](Get-Item -LiteralPath $file).Length
                    $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $stream.Write((New-Object -TypeName 'byte[]' -ArgumentList $length), 0, $length)
                        $stream.Flush($true)
                    }
                    finally {
                        $stream.Dispose()
                    }
                }
                catch {
                    $notes += 'The token file couldn''t be overwritten before it was deleted.'
                }
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }
        # Only when the agent didn't take the token from the file (it rejected the file, found no credential, or
        # tried a sign-in of its own): once, on its command line. The sign-in data sweep after onboarding removes
        # what that leaves (ADR 0009).
        if ($null -ne $run -and $run.ExitCode -ne 0 -and ($run.TimedOut -or [string]$run.Output -match '(?i)AZCM00(12|16|19|27|41)|browser|device code|devicelogin')) {
            $notes += ('azcmagent didn''t take the token from its config file ({0}), so it got it on its command line once.' -f $(if ($run.TimedOut) { 'it timed out' } else { 'exit code ' + $run.ExitCode }))
            $passedBy = 'CommandLine'
            $run = Invoke-DemoAgentProcess -ArgumentList (@('connect', '--access-token', [string]$Token) + $common)
        }
        $Token = $null
        $code = -1
        $output = ''
        if ($null -ne $run) {
            $code = $run.ExitCode
            $output = [string]$run.Output
        }
        [pscustomobject]@{ ExitCode = $code; Output = (@($notes) + @($output)) -join "`n"; TokenPassedBy = $passedBy; TokenFileLeft = [bool](Test-Path -LiteralPath $file) }
    }
}

function Test-DemoArcAuthorizationError {
    # True when azcmagent connect failed because Azure Resource Manager refused authorization, which a new role
    # assignment causes until it propagates (minutes).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Text = ''
    )

    return [bool]($Text -match '(?i)AuthorizationFailed|does not have authorization|\bForbidden\b|\b403\b')
}

function Get-DemoArcBundleRoot {
    # The installed bootstrap bundle, from settings.json, which the Phase 6 loader writes.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    $settingsPath = Join-Path -Path $StateRoot -ChildPath 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        throw ('{0} is missing: the bootstrap loader has not run on this VM (deploy.ps1 -Resume).' -f $settingsPath)
    }
    $settings = [System.IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
    $property = $settings.PSObject.Properties['bundlePath']
    $bundlePath = ''
    if ($property) {
        $bundlePath = [string]$property.Value
    }
    if (-not $bundlePath -or -not (Test-Path -LiteralPath ([System.IO.Path]::Combine($bundlePath, 'vm', 'bootstrap', 'DbHubDemo.Vm.psd1')))) {
        throw 'The installed bootstrap bundle was not found; run deploy.ps1 -Resume to send it again.'
    }
    return $bundlePath
}

function Test-DemoArcInput {
    # Validates the non-secret inputs of the Onboard and WriteMarker actions; the messages never echo the token.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $InputValue
    )

    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $rules = [ordered]@{
        SubscriptionId = $guid
        TenantId       = $guid
        ResourceGroup  = '^[A-Za-z0-9._()-]{1,90}$'
        Location       = '^[a-z0-9]{2,40}$'
        MachineName    = '^[A-Za-z0-9._-]{1,54}$'
        CorrelationId  = $guid
        Cloud          = '^(AzureCloud|AzureUSGovernment|AzureChinaCloud)$'
    }
    foreach ($name in $rules.Keys) {
        if ([string]$InputValue[$name] -notmatch $rules[$name]) {
            throw ('The {0} parameter is missing or not valid.' -f $name)
        }
    }
    if ([string]$InputValue['Tags'] -and [string]$InputValue['Tags'] -notmatch '^[A-Za-z0-9._:/@+=,-]{1,1024}$') {
        throw 'The Tags parameter is not valid.'
    }
}

function ConvertFrom-DemoArcAgentJson {
    <#
    .SYNOPSIS
    Reads the agent's state from 'azcmagent show -j' output (https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-show).

    .DESCRIPTION
    Learn documents the JSON keys status and lastHeartbeat. The resource keys (resourceName, resourceGroup,
    subscriptionId, vmId, agentVersion) are read when present: TODO(verify) on a live agent. The key names
    are returned so the live run can confirm them; values are never needed beyond these.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    $result = [ordered]@{ status = ''; resourceName = ''; resourceGroup = ''; subscriptionId = ''; vmId = ''; agentVersion = ''; keys = @() }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $result
    }
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) {
        return $result
    }
    try {
        $agent = $Text.Substring($start, $end - $start + 1) | ConvertFrom-Json
    }
    catch {
        return $result
    }
    $names = @($agent.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $result.keys = $names
    $lookup = [ordered]@{
        status         = @('status', 'agentStatus')
        resourceName   = @('resourceName')
        resourceGroup  = @('resourceGroup', 'resourceGroupName')
        subscriptionId = @('subscriptionId')
        vmId           = @('vmId')
        agentVersion   = @('agentVersion', 'version')
    }
    foreach ($key in $lookup.Keys) {
        foreach ($candidate in $lookup[$key]) {
            $property = $agent.PSObject.Properties[$candidate]
            if ($property -and -not $result[$key]) {
                $result[$key] = [string]$property.Value
            }
        }
    }
    return $result
}

function Get-DemoArcGuestVmId {
    # The Hyper-V VM ID of the guest; it changes when the guest is rebuilt. Empty in the evaluation-only mode.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $GuestName,

        [Parameter(Mandatory = $true)]
        [string] $Mode
    )

    if ($Mode -eq 'EvaluationOnlyAzureVm') {
        return ''
    }
    $vm = Get-VM -Name $GuestName -ErrorAction SilentlyContinue
    if ($vm) {
        return [string]$vm.VMId
    }
    return ''
}

function Invoke-DemoArcGuestBlock {
    # Runs a block in the guest over PowerShell Direct, or locally in the evaluation-only mode.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Mode,

        [Parameter(Mandatory = $true)]
        [string] $GuestName,

        [AllowNull()]
        [pscredential] $Credential,

        [Parameter(Mandatory = $true)]
        [scriptblock] $Block,

        [object[]] $ArgumentList = @()
    )

    if ($Mode -eq 'EvaluationOnlyAzureVm') {
        return (& $Block @ArgumentList)
    }
    return (Invoke-Command -VMName $GuestName -Credential $Credential -ScriptBlock $Block -ArgumentList $ArgumentList -ErrorAction Stop)
}

function Get-DemoArcGuestState {
    # Probe: guest reachability, isolation, DNS, and the agent's state.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Mode,

        [Parameter(Mandatory = $true)]
        [string] $GuestName,

        [AllowNull()]
        [pscredential] $Credential
    )

    $state = [ordered]@{ guestReachable = $false; imdsReachable = $false; wireServerReachable = $false; dnsResolves = $false; agentInstalled = $false; agent = (ConvertFrom-DemoArcAgentJson -Text ''); msftArcTest = '' }
    if ($Mode -ne 'EvaluationOnlyAzureVm' -and -not (Test-DemoGuestOnline -Name $GuestName -Credential $Credential)) {
        return $state
    }
    $probe = Invoke-DemoArcGuestBlock -Mode $Mode -GuestName $GuestName -Credential $Credential -Block (Get-DemoArcBlock -Name 'Probe') -ArgumentList @(($Mode -ne 'EvaluationOnlyAzureVm'))
    $state.guestReachable = $true
    $state.imdsReachable = [bool]$probe.ImdsReachable
    $state.wireServerReachable = [bool]$probe.WireServerReachable
    $state.dnsResolves = [bool]$probe.DnsResolves
    $state.agentInstalled = [bool]$probe.AgentInstalled
    $state.agent = ConvertFrom-DemoArcAgentJson -Text ([string]$probe.AgentJson)
    $state.msftArcTest = [string]$probe.MsftArcTest
    return $state
}

function Get-DemoArcAuthenticodeSignature {
    # Wrapper so tests can stand in for Get-AuthenticodeSignature.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return (Get-AuthenticodeSignature -FilePath $Path)
}

function Test-DemoArcAgentPackage {
    <#
    .SYNOPSIS
    Verifies the agent package: the pinned SHA-256 when one is set; otherwise a valid Authenticode signature
    whose signer subject contains SignerPattern. Returns Valid, Method, Sha256, Signer, and Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [AllowEmptyString()]
        [string] $Sha256 = '',

        [Parameter(Mandatory = $true)]
        [string] $SignerPattern
    )

    $actual = Get-DemoVmFileSha256 -Path $Path
    if ($Sha256) {
        $valid = $actual -eq $Sha256.ToLowerInvariant()
        return [pscustomobject]@{ Valid = $valid; Method = 'Sha256'; Sha256 = $actual; Signer = ''; Detail = ('expected SHA-256 {0}, found {1}' -f $Sha256.ToLowerInvariant(), $actual) }
    }
    $signature = Get-DemoArcAuthenticodeSignature -Path $Path
    $subject = ''
    if ($null -ne $signature -and $null -ne $signature.SignerCertificate) {
        $subject = [string]$signature.SignerCertificate.Subject
    }
    $status = ''
    if ($null -ne $signature) {
        $status = [string]$signature.Status
    }
    $valid = $status -eq 'Valid' -and $subject -and $subject.Contains($SignerPattern)
    return [pscustomobject]@{ Valid = [bool]$valid; Method = 'Authenticode'; Sha256 = $actual; Signer = $subject; Detail = ('signature status {0}, signer {1}' -f $status, $subject) }
}

function Invoke-DemoArcWebDownload {
    # The only network call for the package; tests stand in for it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object -TypeName 'System.Net.WebClient'
    try {
        $client.DownloadFile($Url, $Path)
    }
    finally {
        $client.Dispose()
    }
}

function Get-DemoArcAgentPackage {
    <#
    .SYNOPSIS
    Returns a verified agent package in Folder, downloading it when there's none younger than MaxCacheDays.
    A package that fails verification is deleted and the step fails closed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,

        [AllowEmptyString()]
        [string] $Sha256 = '',

        [Parameter(Mandatory = $true)]
        [string] $SignerPattern,

        [ValidateRange(0, 90)]
        [int] $MaxCacheDays = 7,

        [Parameter(Mandatory = $true)]
        [string] $Folder,

        [ValidateRange(1, 10)]
        [int] $MaxAttempts = 4
    )

    if (-not (Test-Path -LiteralPath $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }
    $path = Join-Path -Path $Folder -ChildPath 'AzureConnectedMachineAgent.msi'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $age = [DateTime]::UtcNow - (Get-Item -LiteralPath $path).LastWriteTimeUtc
        $cached = Test-DemoArcAgentPackage -Path $path -Sha256 $Sha256 -SignerPattern $SignerPattern
        if ($age.TotalDays -le $MaxCacheDays -and $cached.Valid) {
            Write-DemoVmLog -Message ('Using the cached Connected Machine agent package ({0}).' -f $cached.Detail)
            return [pscustomobject]@{ Path = $path; Verification = $cached }
        }
        Remove-Item -LiteralPath $path -Force
    }
    $partial = $path + '.partial'
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            Write-DemoVmLog -Message ('Downloading the Connected Machine agent package (attempt {0} of {1}).' -f $attempt, $MaxAttempts)
            Invoke-DemoArcWebDownload -Url $Url -Path $partial
            Move-Item -LiteralPath $partial -Destination $path
            break
        }
        catch {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            if ($attempt -ge $MaxAttempts) {
                throw ('Downloading the Connected Machine agent package failed after {0} attempts: {1}' -f $MaxAttempts, (Protect-DemoVmText -Text $_.Exception.Message))
            }
            Start-Sleep -Seconds (15 * $attempt)
        }
    }
    $check = Test-DemoArcAgentPackage -Path $path -Sha256 $Sha256 -SignerPattern $SignerPattern
    if (-not $check.Valid) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw ('The Connected Machine agent package failed verification ({0}); it was deleted (fail closed).' -f $check.Detail)
    }
    Write-DemoVmLog -Message ('Connected Machine agent package verified ({0}: {1}).' -f $check.Method, $check.Detail)
    return [pscustomobject]@{ Path = $path; Verification = $check }
}

function Get-DemoArcHostIdentityToken {
    <#
    .SYNOPSIS
    Optional least-privilege path (ADR 0005, assignRoles): an Azure Resource Manager token for the host's
    user-assigned identity, from the host's own IMDS endpoint, selected by client ID
    (https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token).
    The guest can't reach IMDS (ADR 0004); the token reaches it only as an argument.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $ClientId
    )

    $uri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F&client_id=' + $ClientId
    $response = Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30 -UseBasicParsing
    $token = [string]$response.access_token
    if (-not $token) {
        throw 'IMDS returned no token for the onboarding identity.'
    }
    Register-DemoVmSecret -Value $token
    return $token
}

function Write-DemoArcMarker {
    # The Phase 6 contract, plus guestVmId so a rebuilt guest doesn't reuse an old marker.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Marker
    )

    $path = Join-Path -Path $StateRoot -ChildPath 'arc-onboarded.json'
    Write-DemoVmJsonFile -Path $path -InputObject $Marker -Redact
    Write-DemoVmLog -Message ('Wrote the Arc marker for {0} ({1}).' -f $Marker['machineName'], $Marker['resourceId'])
    return $path
}

function Invoke-DemoArcBootstrapTask {
    # Starts the state machine right away instead of at its next 5-minute run.
    [CmdletBinding()]
    param()

    try {
        Start-ScheduledTask -TaskName 'DbHubDemo-Bootstrap' -ErrorAction Stop
        return $true
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('The DbHubDemo-Bootstrap task could not be started; it runs within 5 minutes anyway: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Test-DemoArcAgentMatch {
    # True when the agent reports Connected to the expected machine (resource details compared when present).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Agent,

        [Parameter(Mandatory = $true)]
        [string] $MachineName,

        [AllowEmptyString()]
        [string] $ResourceGroup = '',

        [AllowEmptyString()]
        [string] $SubscriptionId = ''
    )

    if ([string]$Agent['status'] -ne 'Connected') {
        return $false
    }
    if ([string]$Agent['resourceName'] -and [string]$Agent['resourceName'] -ne $MachineName) {
        return $false
    }
    if ($ResourceGroup -and [string]$Agent['resourceGroup'] -and [string]$Agent['resourceGroup'] -ne $ResourceGroup) {
        return $false
    }
    if ($SubscriptionId -and [string]$Agent['subscriptionId'] -and [string]$Agent['subscriptionId'] -ne $SubscriptionId) {
        return $false
    }
    return $true
}

function Invoke-DemoArcOnboardAction {
    <#
    .SYNOPSIS
    Runs one action and returns an ordered result: action, succeeded, outcome, message, and non-secret details.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Probe', 'Onboard', 'WriteMarker')]
        [string] $ActionName,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $InputValue,

        [AllowEmptyString()]
        [string] $Token = '',

        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [string] $BundleRoot,

        # Waits between connect attempts that Azure refuses for authorization, with the host identity only: its new
        # role assignment can take minutes to propagate. At most 7.5 minutes in all.
        [int[]] $AuthorizationRetrySeconds = @(30, 60, 120, 120, 120),

        [ValidateRange(60, 1800)]
        [int] $ConnectTimeoutSeconds = 600
    )

    $mode = [string]$InputValue['Mode']
    if ($mode -ne 'EvaluationOnlyAzureVm') {
        $mode = 'Nested'
    }
    $evaluation = $mode -eq 'EvaluationOnlyAzureVm'
    $guestConfig = Import-PowerShellDataFile -Path ([System.IO.Path]::Combine($BundleRoot, 'vm', 'dsc', 'guest.psd1'))
    $guestName = [string]$InputValue['MachineName']
    if (-not $guestName) {
        $guestName = [string]$guestConfig.Name
    }
    $credential = $null
    if (-not $evaluation) {
        $credential = Get-DemoGuestCredential -SecretPath ([System.IO.Path]::Combine($StateRoot, 'protected', 'guest-administrator.bin')) -UserName ([string]$guestConfig.AdministratorName)
    }
    $result = [ordered]@{ action = $ActionName; mode = $mode; succeeded = $false; outcome = ''; message = ''; resourceId = ''; guestVmId = ''; agentVersion = ''; agentStatus = '' }

    $state = Get-DemoArcGuestState -Mode $mode -GuestName $guestName -Credential $credential
    $result.guestVmId = Get-DemoArcGuestVmId -GuestName $guestName -Mode $mode
    if ($ActionName -eq 'Probe') {
        $agent = $state.agent
        foreach ($key in 'guestReachable', 'imdsReachable', 'wireServerReachable', 'dnsResolves', 'agentInstalled', 'msftArcTest') {
            $result[$key] = $state[$key]
        }
        $result.agentStatus = [string]$agent['status']
        $result.agentResourceName = [string]$agent['resourceName']
        $result.agentResourceGroup = [string]$agent['resourceGroup']
        $result.agentSubscriptionId = [string]$agent['subscriptionId']
        $result.agentVmId = [string]$agent['vmId']
        $result.agentVersion = [string]$agent['agentVersion']
        $result.agentKeys = @($agent['keys'])
        $marker = Read-DemoVmJsonFile -Path (Join-Path -Path $StateRoot -ChildPath 'arc-onboarded.json')
        $result.markerStatus = ''
        if ($null -ne $marker) {
            $result.markerStatus = [string]$marker['status']
        }
        $result.succeeded = $true
        $result.outcome = 'Probed'
        $result.message = 'Probe finished.'
        return $result
    }

    Test-DemoArcInput -InputValue $InputValue
    $resourceId = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.HybridCompute/machines/{2}' -f $InputValue['SubscriptionId'], $InputValue['ResourceGroup'], $guestName
    $result.resourceId = $resourceId
    if (-not $state.guestReachable) {
        throw ('{0} did not answer over PowerShell Direct; it may be starting. Nothing was changed.' -f $guestName)
    }
    if ($state.imdsReachable -or ($state.wireServerReachable -and -not $evaluation)) {
        throw ('{0} can reach the Azure Instance Metadata Service or the wire server, so onboarding stops (fail closed, ADR 0004). Run the GuestHardening step again.' -f $guestName)
    }

    $connected = Test-DemoArcAgentMatch -Agent $state.agent -MachineName $guestName -ResourceGroup ([string]$InputValue['ResourceGroup']) -SubscriptionId ([string]$InputValue['SubscriptionId'])
    if ($ActionName -eq 'WriteMarker' -and -not $connected) {
        throw ('The agent in {0} is not Connected to {0} (status {1}); the marker was not written.' -f $guestName, $state.agent['status'])
    }
    $result.outcome = 'AlreadyConnected'
    if ($ActionName -eq 'Onboard' -and -not $connected) {
        if ($evaluation) {
            # Microsoft's evaluation procedure for an Azure VM: MSFT_ARC_TEST at machine level before the agent runs.
            [Environment]::SetEnvironmentVariable('MSFT_ARC_TEST', 'true', [EnvironmentVariableTarget]::Machine)
        }
        if (-not $Token) {
            throw 'No access token was provided.'
        }
        if (-not $state.agentInstalled) {
            $hostFolder = [System.IO.Path]::Combine($StateRoot, 'downloads', 'arc-agent')
            $maxCacheDays = 7
            [int]::TryParse([string]$InputValue['AgentMaxCacheDays'], [ref]$maxCacheDays) | Out-Null
            $package = Get-DemoArcAgentPackage -Url ([string]$InputValue['AgentUrl']) -Sha256 ([string]$InputValue['AgentSha256']) -SignerPattern ([string]$InputValue['AgentSignerPattern']) -MaxCacheDays $maxCacheDays -Folder $hostFolder
            $msiPath = $package.Path
            if (-not $evaluation) {
                # A guest path: Join-Path would resolve the drive on the machine running this script.
                $msiPath = '{0}\AzureConnectedMachineAgent.msi' -f ([string]$guestConfig.MediaFolder).TrimEnd('\')
                Copy-DemoGuestFile -Name $guestName -Credential $credential -SourcePath $package.Path -DestinationPath $msiPath -ExpectedSha256 $package.Verification.Sha256
            }
            $install = Invoke-DemoArcGuestBlock -Mode $mode -GuestName $guestName -Credential $credential -Block (Get-DemoArcBlock -Name 'Install') -ArgumentList @($msiPath, 'C:\DbHubDemo\logs\azcmagent-setup.log')
            if ([int]$install.ExitCode -ne 0 -and [int]$install.ExitCode -ne 3010) {
                throw ('Installing the Connected Machine agent failed with msiexec exit code {0}; the log is C:\DbHubDemo\logs\azcmagent-setup.log in {1}.' -f $install.ExitCode, $guestName)
            }
            Write-DemoVmLog -Message ('Installed the Connected Machine agent in {0} (exit code {1}).' -f $guestName, $install.ExitCode)
        }
        $disconnectFirst = [string]$InputValue['DisconnectLocalFirst'] -eq 'true'
        $hostIdentity = [string]$InputValue['TokenSource'] -eq 'HostIdentity'
        $result.connectAttempts = 0
        $result.authorizationWaitSeconds = 0
        while ($true) {
            $result.connectAttempts++
            $connectArguments = @($Token, $InputValue['SubscriptionId'], $InputValue['TenantId'], $InputValue['ResourceGroup'], $InputValue['Location'], $guestName, $InputValue['Cloud'], $InputValue['CorrelationId'], [string]$InputValue['Tags'], $disconnectFirst, $evaluation, $ConnectTimeoutSeconds)
            $connect = Invoke-DemoArcGuestBlock -Mode $mode -GuestName $guestName -Credential $credential -Block (Get-DemoArcBlock -Name 'Connect') -ArgumentList $connectArguments
            $connectArguments = $null
            $disconnectFirst = $false
            $retry = $result.connectAttempts - 1
            if ([int]$connect.ExitCode -eq 0 -or -not $hostIdentity -or $retry -ge @($AuthorizationRetrySeconds).Count -or -not (Test-DemoArcAuthorizationError -Text ([string]$connect.Output))) {
                break
            }
            $wait = [int]@($AuthorizationRetrySeconds)[$retry]
            Write-DemoVmLog -Level 'Warning' -Message ('Azure refused the onboarding identity''s connect for authorization (attempt {0}); its role assignment may still be propagating. Retrying in {1} seconds.' -f $result.connectAttempts, $wait)
            Start-Sleep -Seconds $wait
            $result.authorizationWaitSeconds += $wait
        }
        $passedBy = $connect.PSObject.Properties['TokenPassedBy']
        $result.tokenPassedBy = if ($passedBy) { [string]$passedBy.Value } else { '' }
        $tail = Protect-DemoVmText -Text ([string]$connect.Output)
        if ($tail.Length -gt 800) {
            $tail = $tail.Substring($tail.Length - 800)
        }
        if ([int]$connect.ExitCode -ne 0) {
            throw ('azcmagent connect failed with exit code {0}: {1}' -f $connect.ExitCode, $tail)
        }
        Write-DemoVmLog -Message ('azcmagent connect finished in {0}.' -f $guestName)
        $result.outcome = 'Onboarded'
        for ($attempt = 1; $attempt -le 6 -and -not $connected; $attempt++) {
            $state = Get-DemoArcGuestState -Mode $mode -GuestName $guestName -Credential $credential
            $connected = Test-DemoArcAgentMatch -Agent $state.agent -MachineName $guestName -ResourceGroup ([string]$InputValue['ResourceGroup']) -SubscriptionId ([string]$InputValue['SubscriptionId'])
            if (-not $connected -and $attempt -lt 6) {
                Start-Sleep -Seconds 10
            }
        }
        if (-not $connected) {
            throw ('azcmagent connect succeeded, but the agent in {0} reports status {1}, not Connected.' -f $guestName, $state.agent['status'])
        }
    }

    $result.agentStatus = [string]$state.agent['status']
    $result.agentVersion = [string]$state.agent['agentVersion']
    $marker = [ordered]@{
        schemaVersion  = 1
        machineName    = $guestName
        status         = 'Connected'
        resourceId     = $resourceId
        connectedUtc   = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        guestVmId      = $result.guestVmId
        agentVersion   = $result.agentVersion
        tokenSource    = [string]$InputValue['TokenSource']
        correlationId  = [string]$InputValue['CorrelationId']
        evaluationOnly = $evaluation
    }
    Write-DemoArcMarker -StateRoot $StateRoot -Marker $marker | Out-Null
    $result.taskStarted = Invoke-DemoArcBootstrapTask
    $result.succeeded = $true
    if ($result.outcome -eq 'AlreadyConnected') {
        $result.message = ('{0} was already Connected; the marker was written again.' -f $guestName)
    }
    else {
        $result.message = ('{0} is Connected to Azure Arc; the marker was written.' -f $guestName)
    }
    return $result
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        $bundleRoot = Get-DemoArcBundleRoot -StateRoot $Root
        Import-Module -Name ([System.IO.Path]::Combine($bundleRoot, 'vm', 'bootstrap', 'DbHubDemo.Vm.psd1')) -Force
        foreach ($helper in @('GuestVm.ps1', 'GuestSql.ps1')) {
            . ([System.IO.Path]::Combine($bundleRoot, 'vm', 'hyperv-guest', $helper))
        }
        $role = 'ArcHost'
        if ($Mode -eq 'EvaluationOnlyAzureVm') {
            $role = 'EvalArcVm'
        }
        Initialize-DemoVmContext -Root $Root -Role $role -BundleRoot $bundleRoot | Out-Null
        $token = ''
        if ($Action -eq 'Onboard') {
            if ($TokenSource -eq 'HostIdentity') {
                $token = Get-DemoArcHostIdentityToken -ClientId $IdentityClientId
            }
            else {
                $token = $AccessToken
                Register-DemoVmSecret -Value $token
            }
        }
        $signerPattern = 'O=Microsoft Corporation'
        if ($AgentSignerPatternBase64) {
            $signerPattern = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($AgentSignerPatternBase64))
        }
        $values = @{
            SubscriptionId       = $SubscriptionId
            TenantId             = $TenantId
            ResourceGroup        = $ResourceGroup
            Location             = $Location
            MachineName          = $MachineName
            Tags                 = $Tags
            CorrelationId        = $CorrelationId
            Cloud                = $Cloud
            AgentUrl             = $AgentUrl
            AgentSha256          = $AgentSha256
            AgentSignerPattern   = $signerPattern
            AgentMaxCacheDays    = $AgentMaxCacheDays
            DisconnectLocalFirst = $DisconnectLocalFirst
            TokenSource          = $TokenSource
            Mode                 = $Mode
        }
        $outcome = Invoke-DemoArcOnboardAction -ActionName $Action -InputValue $values -Token $token -StateRoot $Root -BundleRoot $bundleRoot
        $token = $null
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $outcome -Compress -Depth 6))
        if ($outcome['succeeded']) {
            $exitCode = 0
        }
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($AccessToken) {
            $message = $message.Replace($AccessToken, '[REDACTED]')
        }
        if (Get-Command -Name 'Protect-DemoVmText' -ErrorAction SilentlyContinue) {
            $message = Protect-DemoVmText -Text $message
            Write-DemoVmLog -Level 'Error' -Message ('Arc {0} failed: {1}' -f $Action, $message)
        }
        [Console]::Error.WriteLine('DbHubDemo Arc ' + $Action + ' failed: ' + $message)
    }
    finally {
        $AccessToken = $null
    }
    exit $exitCode
}
