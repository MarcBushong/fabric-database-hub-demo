function Invoke-DemoDotNet {
    <#
    .SYNOPSIS
    Runs the .NET SDK (dotnet) with an argument array in a working directory and captures exit code, standard
    output, and standard error. Internal; tests mock it.

    .DESCRIPTION
    The working directory matters: the SDK reads workload-generator/global.json from it, which pins the SDK
    version (config/versions.json tools.dotnetSdk). Output is returned redacted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    $dotnet = Get-Command -Name 'dotnet' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dotnet) {
        throw 'The .NET SDK (dotnet) was not found on PATH. Install the SDK pinned in config/versions.json (tools.dotnetSdk), or use the devcontainer or Cloud Shell.'
    }
    $PSNativeCommandUseErrorActionPreference = $false
    $errorFile = [System.IO.Path]::GetTempFileName()
    Push-Location -LiteralPath $WorkingDirectory
    try {
        $stdout = & $dotnet.Source @ArgumentList 2> $errorFile
        $exitCode = $LASTEXITCODE
        $stderr = Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue
    }
    finally {
        Pop-Location
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = Protect-DemoText -Text (@($stdout) -join [System.Environment]::NewLine)
        StdErr   = Protect-DemoText -Text ([string]$stderr)
    }
}

function Get-DemoWorkloadSourceHash {
    <#
    .SYNOPSIS
    SHA-256 of everything that goes into the runner build: its source, the build and package pins, global.json,
    the embedded scenario catalog and demo T-SQL, the runtime identifier, the SDK pin, and the publish
    properties. Internal and pure.

    .DESCRIPTION
    Publish-DemoWorkloadRunner names the zip after this hash and reuses a zip with the same hash, so
    'deploy.ps1 -Resume' doesn't build again, change the runner's SHA-256, and resend it to the VMs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $RuntimeIdentifier,

        [Parameter(Mandatory)]
        [string] $SdkVersion,

        [string[]] $BuildProperty = @()
    )

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $generator = Join-Path -Path $root -ChildPath 'workload-generator'
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $source = Join-Path -Path $generator -ChildPath 'src'
    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
        if ($file.FullName -notmatch '[\\/](bin|obj)[\\/]') {
            $files.Add($file)
        }
    }
    foreach ($name in 'Directory.Build.props', 'Directory.Packages.props', 'global.json') {
        $path = Join-Path -Path $generator -ChildPath $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $files.Add((Get-Item -LiteralPath $path))
        }
    }
    $scenarios = Join-Path -Path $root -ChildPath 'scenarios'
    if (Test-Path -LiteralPath $scenarios) {
        foreach ($file in Get-ChildItem -LiteralPath $scenarios -Recurse -File -Filter '*.json') {
            $files.Add($file)
        }
    }
    $common = Join-Path -Path $root -ChildPath 'database/common'
    if (Test-Path -LiteralPath $common) {
        foreach ($file in Get-ChildItem -LiteralPath $common -File -Filter '*.sql') {
            $files.Add($file)
        }
    }
    $lines = foreach ($file in $files) {
        $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        # Line endings are normalized, so a checkout with CRLF hashes like one with LF.
        $text = [System.IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
        $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.UTF8Encoding]::new($false).GetBytes($text))).ToLowerInvariant()
        '{0}  {1}' -f $hash, $relative
    }
    $sorted = [System.Collections.Generic.List[string]]::new([string[]]@($lines))
    $sorted.Sort([System.StringComparer]::Ordinal)
    $listing = (@("rid=$RuntimeIdentifier", "sdk=$SdkVersion") + @($BuildProperty | ForEach-Object { "build=$_" }) + $sorted) -join "`n"
    return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.UTF8Encoding]::new($false).GetBytes($listing))).ToLowerInvariant()
}

function Invoke-DemoActionRunCommand {
    <#
    .SYNOPSIS
    Runs a PowerShell script on a VM through action Run Command ('az vm run-command invoke --command-id
    RunPowerShellScript --scripts @<file>') and returns the CLI result. Internal.

    .DESCRIPTION
    The script goes in a temporary file, so no quote or percent sign reaches the az.cmd command line. A Run
    Command that's busy (Conflict, or another operation in progress, for example while a policy updates
    MDE.Windows, R49) is retried for about 12.5 minutes; a VM that isn't running fails at once with a clear
    message. Action Run Command runs one script at a time per VM and returns only the last 4,096 bytes of
    output (https://learn.microsoft.com/azure/virtual-machines/windows/run-command).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $Script,

        [ValidateRange(1, 13)]
        [int] $Attempts = 10
    )

    if ($Script -match '[^\x00-\x7F]') {
        throw 'The Run Command script must be ASCII-only for Windows PowerShell 5.1.'
    }
    $scriptPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dbhub-action-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
    $run = $null
    try {
        [System.IO.File]::WriteAllText($scriptPath, $Script, [System.Text.Encoding]::ASCII)
        $arguments = @('vm', 'run-command', 'invoke', '--resource-group', $ResourceGroupName, '--name', $VmName, '--command-id', 'RunPowerShellScript', '--scripts', "@$scriptPath", '--output', 'json')
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            $run = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList $arguments -AllowFailure
            if ($run.ExitCode -ne 0 -and (Test-DemoAzVmNotRunning -Text ([string]$run.StdErr))) {
                $run = [pscustomobject]@{ ExitCode = $run.ExitCode; StdOut = $run.StdOut; StdErr = ('{0} isn''t running (deallocated), so Run Command can''t reach it; start it first (start-demo.ps1). {1}' -f $VmName, $run.StdErr) }
                break
            }
            if ($run.ExitCode -eq 0 -or $attempt -eq $Attempts -or $run.StdErr -notmatch '(?i)conflict|in progress|another operation') {
                break
            }
            $delay = Get-DemoConflictDelay -Attempt $attempt
            Write-DemoLog -Level Warning -Message ('A Run Command or an extension that a policy installs or updates (for example MDE.Windows) is busy on {0}; retrying in {1} seconds ({2} of {3}).' -f $VmName, $delay, $attempt, ($Attempts - 1))
            Start-Sleep -Seconds $delay
        }
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
    return $run
}

function Get-DemoWorkloadControlScript {
    <#
    .SYNOPSIS
    The inline Run Command script that calls vm/bootstrap/Invoke-DemoWorkloadControl.ps1 from the bundle on the
    VM. Internal and pure.

    .DESCRIPTION
    The action name and the Base64 request are checked before they go into single-quoted strings, so nothing
    can break out of them. The script finds the bundle through settings.json (bundlePath), which the loader
    writes, and prints a Fail line in the same format when anything is missing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('EnableT3', 'EnableT4', 'Runner', 'StopGuest')]
        [string] $Action,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Request
    )

    $json = ConvertTo-Json -InputObject $Request -Depth 6 -Compress
    $encoded = [System.Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($json))
    if ($encoded -notmatch '^[A-Za-z0-9+/=]*$') {
        throw 'The request did not encode to Base64.'
    }
    return (Get-DemoWorkloadControlTemplate).Replace('__ACTION__', $Action).Replace('__REQUEST__', $encoded)
}

function Get-DemoWorkloadControlTemplate {
    <#
    .SYNOPSIS
    The inline Run Command script's template, with the placeholders __ACTION__ and __REQUEST__: what
    Get-DemoWorkloadControlScript fills for one action, and what the on-demand control's DbHub-Control runbook fills
    once per target (ADR 0020), so both reach the VM-side control script the same way. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $template = @'
# DbHubDemo workload control (ADR 0010, ADR 0011). Generated by the DbHubDemo module; it holds no secrets.
$ErrorActionPreference = 'Stop'
$marker = 'DBHUBDEMO-WORKLOAD'
try {
    $settingsPath = 'C:\ProgramData\DbHubDemo\settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw 'settings.json is missing; the bootstrap loader has not run on this VM.'
    }
    $settings = [System.IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
    $control = [System.IO.Path]::Combine([string]$settings.bundlePath, 'vm', 'bootstrap', 'Invoke-DemoWorkloadControl.ps1')
    if (-not (Test-Path -LiteralPath $control)) {
        throw 'The bootstrap bundle on this VM has no Invoke-DemoWorkloadControl.ps1; deploy the current bundle (deploy.ps1 -Resume).'
    }
    & $control -Action '__ACTION__' -RequestBase64 '__REQUEST__'
}
catch {
    $result = @{ marker = $marker; action = '__ACTION__'; status = 'Fail'; message = $_.Exception.Message; evidence = @{} }
    [Console]::Out.WriteLine($marker + ' ' + ($result | ConvertTo-Json -Compress))
}
'@
    return $template.Replace("`r`n", "`n")
}

function Invoke-DemoWorkloadAction {
    <#
    .SYNOPSIS
    Runs one workload control action on a VM (vm/bootstrap/Invoke-DemoWorkloadControl.ps1) through action Run
    Command and returns its result line as a hashtable, or a Fail record when the Run Command itself failed.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('sqlvm01', 'archost01')]
        [string] $VmName,

        [Parameter(Mandatory)]
        [ValidateSet('EnableT3', 'EnableT4', 'Runner', 'StopGuest')]
        [string] $Action,

        [System.Collections.IDictionary] $Request = @{}
    )

    $resourceGroup = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $script = Get-DemoWorkloadControlScript -Action $Action -Request $Request
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-DemoActionRunCommand -SubscriptionId $Config['subscriptionId'] -ResourceGroupName $resourceGroup -VmName $VmName -Script $script
    $seconds = [int]$clock.Elapsed.TotalSeconds
    if ($run.ExitCode -ne 0) {
        $errorText = (Protect-DemoText -Text ([string]$run.StdErr)).Trim()
        if ($errorText.Length -gt 500) {
            $errorText = $errorText.Substring(0, 500) + '...'
        }
        return @{ marker = 'DBHUBDEMO-WORKLOAD'; action = $Action; status = 'Fail'; message = ('The Run Command on {0} failed: {1}' -f $VmName, $errorText); evidence = @{ operatorSeconds = $seconds } }
    }
    $response = $null
    try {
        $response = [string]$run.StdOut | ConvertFrom-Json -Depth 32
    }
    catch {
        $response = $null
    }
    $parsed = ConvertFrom-DemoT3RunCommandOutput -Response $response -Marker 'DBHUBDEMO-WORKLOAD'
    $data = $parsed.Data
    if ($null -eq $data -or [string]$data['marker'] -ne 'DBHUBDEMO-WORKLOAD' -or [string]$data['status'] -notin $script:ValidStatuses) {
        $detail = if ($parsed.StdErr) { $parsed.StdErr } else { 'no result line' }
        return @{ marker = 'DBHUBDEMO-WORKLOAD'; action = $Action; status = 'Fail'; message = ('{0} returned no workload result: {1}' -f $VmName, $detail); evidence = @{ operatorSeconds = $seconds } }
    }
    if (-not $data.ContainsKey('evidence') -or $data['evidence'] -isnot [System.Collections.IDictionary]) {
        $data['evidence'] = @{}
    }
    $data['evidence']['operatorSeconds'] = $seconds
    return $data
}

function ConvertFrom-DemoRunnerRecord {
    <#
    .SYNOPSIS
    The --json records in a runner command's standard output: the items of a JSON array ('reset', 'stop'), or one
    JSON object as one record ('profile get', 'status', and 'run' each write one object). Nothing when there's no
    whole JSON document, for example when a Run Command kept only the output's tail. Internal.

    .DESCRIPTION
    The document starts at the first '[' or '{', whichever comes first, and ends at the last matching bracket. When
    that doesn't parse, the other kind is tried, so a bracket in text before the document can't hide it.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $StdOut
    )

    $text = [string]$StdOut
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($pair in @(@([char]'[', [char]']'), @([char]'{', [char]'}'))) {
        $start = $text.IndexOf($pair[0])
        $end = $text.LastIndexOf($pair[1])
        if ($start -ge 0 -and $end -gt $start) {
            $candidates.Add([pscustomobject]@{ Start = $start; End = $end })
        }
    }
    foreach ($candidate in @($candidates | Sort-Object -Property Start)) {
        try {
            $records = @($text.Substring($candidate.Start, $candidate.End - $candidate.Start + 1) | ConvertFrom-Json -Depth 16)
        }
        catch {
            Write-Verbose -Message 'This part of the runner output isn''t one whole JSON document.'
            continue
        }
        return $records
    }
}