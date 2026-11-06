# The Insights app's Rayfin CLI sign-in during deploy.ps1 (2026-11-05). It starts at the beginning of the run, while the
# person is still at the keyboard, and runs alongside preflight, the template, and the tracks, which never wait for it.
# Only the Insights app's own step waits for it, and never past its deadline; a sign-in that's cancelled, times out, or
# fails only leaves that step to say why. Nothing here is ever a Fail or Manual action required: the app never blocks
# DONE.
# Sources (checked 2026-11-05):
# - Rayfin CLI reference (rayfin login, rayfin login status): https://learn.microsoft.com/fabric/apps/cli-reference
# - Start-Process (-NoNewWindow, -Environment, -PassThru): https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process
# - Process.Kill(entireProcessTree): https://learn.microsoft.com/dotnet/api/system.diagnostics.process.kill
# - Get-Command (-CommandType Application; checked 2026-11-06): https://learn.microsoft.com/powershell/module/microsoft.powershell.core/get-command
# - How the Rayfin CLI opens its sign-in page with BROWSER isn't in its reference: read on 2026-11-06 from the pinned
#   package's own code (@microsoft/rayfin-cli 1.36.2, dist/auth/rayfin-auth.js).

# The sign-in this session started last, which Stop-DemoFabricAppSignIn ends when the run ends without settling it.
$script:DemoFabricAppSignIn = $null

function Start-DemoFabricAppSignIn {
    <#
    .SYNOPSIS
    Starts the Rayfin CLI's sign-in for the Insights app when it's needed, without waiting for it, and returns its state
    for Complete-DemoFabricAppSignIn. Internal.

    .DESCRIPTION
    The Insights app is part of every deployment, and deploys with the Rayfin CLI, whose service principal sign-in isn't
    supported yet, so a person signs it in once (prerequisite P14); the Fabric track's own process can't open a browser.
    At the start of the run:
    - A session that can't answer a browser sign-in (CI, or input redirected, as under an assistant;
      Test-DemoInteractiveSession): nothing starts, Not supported. The app's step still uses a sign-in this machine
      already has.
    - The stage's CLI, when it's installed, reads its own sign-in ('rayfin login status --json', at most 30 seconds,
      never a browser): signed in to the demo's tenant, Pass, and nothing starts.
    - Otherwise the pinned CLI's 'rayfin login --tenant <tenantId>' starts through npx (Start-DemoRayfinSignInProcess):
      on Windows in a console window of its own, elsewhere in this terminal, and the run goes on at once. Its browser
      opens for the person's sign-in. The status page's Fabric.AppSignIn row says so, with the deadline (-TimeoutMinutes),
      which the model keeps (run.appSignInUntil) for the app's step (Wait-DemoFabricAppSignIn).
    - No tenant, no Node.js or npx, or a start that fails: a Warning, and the app's step says what that means for it.
    Returns Process (or $null), TenantId (once the sign-in starts), StartedUtc, DeadlineUtc, TimeoutMinutes, Done,
    Reported, and Result (the DEPLOY.FABRIC.APPSIGNIN record once it's settled, which Complete-DemoFabricAppSignIn hands
    out once).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [ValidateRange(1, 120)]
        [int] $TimeoutMinutes = 15
    )

    $now = [System.DateTime]::UtcNow
    $state = [pscustomobject]@{ Process = $null; TenantId = ''; StartedUtc = $now; DeadlineUtc = $now.AddMinutes($TimeoutMinutes); TimeoutMinutes = $TimeoutMinutes; Done = $false; Reported = $false; Result = $null }
    $later = 'Run ./scripts/configure-fabric-app.ps1 -SignIn in a terminal: it opens a browser for your own sign-in (an assistant can''t do it for you), then adds the Insights app.'
    if (-not (Test-DemoInteractiveSession)) {
        Set-DemoFabricAppSignInResult -SignIn $state -ProgressPath $ProgressPath -Status 'Not supported' -Message 'This session can''t answer a browser sign-in (CI, or input redirected, as under an assistant), so the Rayfin CLI''s sign-in for the Insights app wasn''t started. The app''s step uses a sign-in this machine already has, if any.' -Remediation $later
        return $state
    }
    $tenantId = [string]$Config['tenantId']
    if ($tenantId -notmatch $script:GuidPattern) {
        Set-DemoFabricAppSignInResult -SignIn $state -ProgressPath $ProgressPath -Status 'Warning' -Message 'No tenant (tenantId) is configured, so the Rayfin CLI can''t be signed in for the Insights app.' -Remediation 'Run ./scripts/init.ps1, or set tenantId in the configuration.'
        return $state
    }
    # Already signed in: the stage's own CLI says so without a browser. A first run has no stage yet, and signs in.
    $stage = Join-Path -Path $script:RepoRoot -ChildPath 'out/fabric-app'
    if (Get-DemoRayfinCliPath -StagePath $stage) {
        # A read-only status query of the Rayfin CLI's own token cache, as Test-DemoFabricAppPrerequisite reads it.
        $statusQuery = @('login', 'status', '--json')
        try {
            $read = Invoke-DemoRayfinCli -StagePath $stage -ArgumentList $statusQuery -TimeoutSeconds 30
            $data = $read.Data
            if ($null -ne $data -and [string]$data['status'] -eq 'ok' -and [string]$data['tenant'] -ieq $tenantId) {
                Set-DemoFabricAppSignInResult -SignIn $state -ProgressPath $ProgressPath -Status 'Pass' -Message 'The Rayfin CLI is already signed in to the demo''s tenant, so no browser opened; the Insights app''s step uses that sign-in.'
                return $state
            }
        }
        catch {
            Write-DemoLog -Level Debug -Message ('The Rayfin CLI''s sign-in couldn''t be read, so its sign-in starts: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        }
    }
    if (-not $PSCmdlet.ShouldProcess('the Rayfin CLI', 'Start its sign-in to the demo''s tenant alongside the deployment (a browser opens)')) {
        Set-DemoFabricAppSignInResult -SignIn $state -ProgressPath $ProgressPath -Status 'Not selected' -Message 'What if: the Rayfin CLI''s sign-in for the Insights app would start alongside the deployment.'
        return $state
    }
    try {
        $state.Process = Start-DemoRayfinSignInProcess -TenantId $tenantId
        $state.TenantId = $tenantId
    }
    catch {
        Set-DemoFabricAppSignInResult -SignIn $state -ProgressPath $ProgressPath -Status 'Warning' -Message ('The Rayfin CLI''s sign-in for the Insights app couldn''t start: {0}' -f (Get-DemoExceptionText -Exception $_.Exception)) -Remediation $later
        return $state
    }
    $script:DemoFabricAppSignIn = $state
    $until = Get-DemoUnixTime -Value $state.DeadlineUtc
    $clock = Format-DemoProgressClock -Unix $until
    $where = if ($IsWindows) { 'in a window of its own' } else { 'in this terminal' }
    Set-DemoProgressValue -Path $ProgressPath -Section 'run' -Value ([ordered]@{ appSignInUntil = $until })
    Set-DemoProgressStep -Path $ProgressPath -Id 'Fabric.AppSignIn' -State 'Running' -Message ('A browser opens for your sign-in (the Rayfin CLI runs {0}). The deployment goes on meanwhile; only the Insights app waits for it, at most until {1}.' -f $where, $clock)
    Invoke-DemoAttention
    $lines = @(
        ('ONE SIGN-IN FOR THE INSIGHTS APP, NOW: a browser opens; sign in as the demo''s Fabric user. The Rayfin CLI runs {0}.' -f $where)
        ('The deployment goes on meanwhile; only the Insights app waits for this sign-in, at most until {0}. Skip it and the deployment still finishes: the app then isn''t created, the status page says why, and ./scripts/configure-fabric-app.ps1 -SignIn adds it later.' -f $clock)
    )
    Write-DemoConsoleBlock -Color 'Yellow' -Line $lines
    return $state
}

function Start-DemoRayfinSignInProcess {
    <#
    .SYNOPSIS
    Starts the pinned Rayfin CLI's 'rayfin login --tenant <tenantId>' through npx, without waiting, and returns its
    process. Internal; tests mock it.

    .DESCRIPTION
    On Windows it gets a console window of its own (Start-Process without -NoNewWindow), so it has its own input and
    output and this console goes on; elsewhere it runs in this terminal. npx runs the version config/versions.json pins
    (fabricApp.cliVersion), the one the Insights app's stage installs, so no stage is needed yet and the Fabric track's
    stage is never touched. The CLI's telemetry is off, and an ambient RAYFIN_TOKEN and a BROWSER the CLI can't start
    are removed, for the child only (Get-DemoRayfinSignInEnvironment); the CLI keeps its own token cache, and nothing
    of its output is captured or logged. Throws when npx isn't on PATH.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Its caller, Start-DemoFabricAppSignIn, asks ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $TenantId
    )

    $settings = Get-DemoFabricAppSetting
    $npx = Get-Command -Name 'npx' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $npx) {
        throw ('npx wasn''t found on PATH. Install Node.js {0} (LTS), which includes npm and npx.' -f (@($settings['supportedNodeMajors']) -join ', '))
    }
    $environment = Get-DemoRayfinSignInEnvironment -WorkingDirectory $script:RepoRoot
    $start = @{
        FilePath         = $npx.Source
        ArgumentList     = @('--yes', ('--package={0}@{1}' -f $settings['cliPackage'], $settings['cliVersion']), '--', 'rayfin', 'login', '--tenant', $TenantId)
        WorkingDirectory = $script:RepoRoot
        Environment      = $environment
        PassThru         = $true
        WhatIf           = $false
    }
    if (-not $IsWindows) {
        $start['NoNewWindow'] = $true
    }
    $process = Start-Process @start
    # Read the handle now, so the exit code can still be read after the process ends.
    $null = $process.Handle
    return $process
}

function Get-DemoRayfinSignInEnvironment {
    <#
    .SYNOPSIS
    The environment for the Rayfin CLI's sign-in process, as Start-Process -Environment takes it, so only that process
    changes: the CLI's telemetry off, no ambient RAYFIN_TOKEN, no colors, and no BROWSER that names nothing the CLI can
    start. Internal.

    .DESCRIPTION
    When BROWSER is set, the Rayfin CLI 1.36.2 opens its sign-in page with it, as "<BROWSER>" "<url>" through a shell,
    and doesn't check the result (dist/auth/rayfin-auth.js), so a value it can't start opens nothing, and the sign-in
    waits until its deadline. That happened live on 2026-11-06: BROWSER held a command line set for az login,
    '"<path>\msedge.exe" --inprivate %s', which Python's webbrowser module accepts. So a BROWSER that's set, but is
    neither the path of an existing file nor a program on PATH (Test-DemoBrowserCommand, from -WorkingDirectory, where
    the CLI runs), is removed ($null) for the CLI's process, which then opens the default browser, and one line says
    so. The caller's own environment never changes, and a usable BROWSER, such as a dev container's helper or a Linux
    desktop's browser, reaches the CLI as before. Either way 'rayfin login' asks which account to use.
    Used by both sign-ins: deploy.ps1's (Start-DemoRayfinSignInProcess) and configure-fabric-app.ps1 -SignIn's
    (Invoke-DemoRayfinInteractive). The CLI's other calls use --json, which never opens a browser.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    $environment = @{ RAYFIN_TELEMETRY_OPTOUT = '1'; RAYFIN_TOKEN = $null; NO_COLOR = '1' }
    $browser = [System.Environment]::GetEnvironmentVariable('BROWSER')
    if (-not [string]::IsNullOrEmpty($browser) -and -not (Test-DemoBrowserCommand -Value $browser -WorkingDirectory $WorkingDirectory)) {
        $environment['BROWSER'] = $null
        Write-DemoLog -Level Warning -Message ('The Rayfin CLI can''t open its sign-in page with BROWSER, which is neither the path of a file nor a program on PATH, so it opens your default browser instead (for the CLI only; BROWSER stays as it is in this terminal). BROWSER is: {0}' -f ($browser -replace '\p{Cc}', ' '))
    }
    return $environment
}

function Test-DemoBrowserCommand {
    <#
    .SYNOPSIS
    True when -Value, a BROWSER setting, names a program the Rayfin CLI's shell can start: the path of an existing file
    (a relative one from -WorkingDirectory, the CLI's), or a program on PATH (Get-Command -CommandType Application).
    False for anything else, such as a command line with arguments or %s, or a list of browsers. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    try {
        if ([System.IO.Path]::IsPathRooted($Value) -or $Value.IndexOfAny([char[]]'/\') -ge 0) {
            $path = [System.IO.Path]::GetFullPath($Value, (Resolve-DemoUserPath -Path $WorkingDirectory))
            return [System.IO.File]::Exists($path)
        }
        # A name, as the shell looks it up: on PATH, and with no wildcards.
        $found = Get-Command -Name ([System.Management.Automation.WildcardPattern]::Escape($Value)) -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        return ($null -ne $found)
    }
    catch {
        return $false
    }
}

function Set-DemoFabricAppSignInResult {
    # Settles the sign-in's state (Start-DemoFabricAppSignIn): its DEPLOY.FABRIC.APPSIGNIN record, and the status page's
    # Fabric.AppSignIn row: Pass is Done, Not supported and Not selected are Skipped, and a Warning is Action needed (the
    # Insights app's own row says what that means for the app). Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes an in-memory state and the Git-ignored local progress model only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SignIn,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Warning', 'Not supported', 'Not selected')]
        [string] $Status,

        [Parameter(Mandatory)]
        [string] $Message,

        [string] $Remediation = ''
    )

    $SignIn.Result = New-DemoResult -CheckId 'DEPLOY.FABRIC.APPSIGNIN' -Area 'fabric' -Target 'tenant' -Status $Status -Message $Message -Remediation $Remediation -DocUrl 'https://learn.microsoft.com/fabric/apps/cli-reference'
    $SignIn.Done = $true
    $rowState = switch ($Status) { 'Pass' { 'Done' } 'Warning' { 'Action needed' } default { 'Skipped' } }
    Set-DemoProgressStep -Path $ProgressPath -Id 'Fabric.AppSignIn' -State $rowState -Status $Status -Message $Message
}

function Complete-DemoFabricAppSignIn {
    <#
    .SYNOPSIS
    Settles the sign-in Start-DemoFabricAppSignIn started, and hands out its DEPLOY.FABRIC.APPSIGNIN record once.
    Internal.

    .DESCRIPTION
    When its process has ended, from its exit code: 0 is Pass; anything else (closed, cancelled, or failed) is a Warning.
    When its deadline has passed, or with -Final (the tracks are done), its process is ended, with every process it
    started, and it's a Warning. With -Wait (deploy.ps1 -Sequential, right before the Insights app's step), it first waits
    for the process to end, at most until the deadline. A window that's closed or stopped doesn't mean there's no sign-in,
    though: one can exist already, from another sign-in (live, 2026-11-06). So before a Warning, the CLI's own status is
    read once, at most a minute (Get-DemoRayfinSignInState): signed in to the demo's tenant is Pass, and the Warning says
    what it means only when the CLI isn't, or when that couldn't be read (never after Ctrl+C, so a stop stays quick).
    Returns the record when it settles, or when it settled at the start and wasn't handed out yet; nothing while it still
    runs, or once it's handed out. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object] $SignIn,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [switch] $Final,

        [switch] $Wait
    )

    if ($null -eq $SignIn) {
        return
    }
    try {
        if (-not [bool]$SignIn.Done) {
            $process = $SignIn.Process
            $ended = { try { $null -eq $process -or $process.HasExited } catch { $true } }
            if ($Wait) {
                while (-not (& $ended) -and [System.DateTime]::UtcNow -lt $SignIn.DeadlineUtc -and -not (Test-DemoRunCancelled)) {
                    Start-Sleep -Seconds 2
                }
            }
            $consequence = 'The deployment went on; without the sign-in the Insights app isn''t created, and its step says why. ./scripts/configure-fabric-app.ps1 -SignIn adds it later.'
            $remediation = 'Run ./scripts/configure-fabric-app.ps1 -SignIn in a terminal: it opens a browser for your own sign-in, then adds the Insights app.'
            # What happened to the sign-in's window, when it didn't finish: $why for a Warning, $window for a Pass.
            $why = ''
            $window = ''
            if (& $ended) {
                $code = -1
                try {
                    $code = [int]$process.ExitCode
                }
                catch {
                    $code = -1
                }
                if ($code -eq 0) {
                    Set-DemoFabricAppSignInResult -SignIn $SignIn -ProgressPath $ProgressPath -Status 'Pass' -Message 'The Rayfin CLI''s sign-in finished; the Insights app''s step uses it.'
                }
                else {
                    $why = 'The Rayfin CLI''s sign-in ended with exit code {0}: it was closed, cancelled, or failed.' -f $code
                    $window = 'its sign-in window was closed, with exit code {0}' -f $code
                }
            }
            elseif ($Final -or $Wait -or [System.DateTime]::UtcNow -ge $SignIn.DeadlineUtc) {
                try {
                    $process.Kill($true)
                }
                catch {
                    Write-DemoLog -Level Debug -Message ('The Rayfin CLI''s sign-in had already ended: {0}' -f $_.Exception.Message)
                }
                $why = if ([System.DateTime]::UtcNow -ge $SignIn.DeadlineUtc) { 'Nobody finished the Rayfin CLI''s sign-in within {0} minutes, so it was stopped.' -f $SignIn.TimeoutMinutes } else { 'The Rayfin CLI''s sign-in was still open when the Insights app''s step was over, so it was stopped.' }
                $window = 'its sign-in window was still open, so it was stopped'
            }
            else {
                return
            }
            if ($why) {
                $cli = if (Test-DemoRunCancelled) { 'Unknown' } else { Get-DemoRayfinSignInState -TenantId ([string](Get-DemoMemberValue -InputObject $SignIn -Name 'TenantId')) }
                if ($cli -eq 'SignedIn') {
                    Set-DemoFabricAppSignInResult -SignIn $SignIn -ProgressPath $ProgressPath -Status 'Pass' -Message ('The Rayfin CLI is signed in to the demo''s tenant ({0}, but a sign-in already exists); the Insights app''s step uses it.' -f $window)
                }
                elseif ($cli -eq 'NotSignedIn') {
                    Set-DemoFabricAppSignInResult -SignIn $SignIn -ProgressPath $ProgressPath -Status 'Warning' -Message ('{0} {1}' -f $why, $consequence) -Remediation $remediation
                }
                else {
                    Set-DemoFabricAppSignInResult -SignIn $SignIn -ProgressPath $ProgressPath -Status 'Warning' -Message ('{0} Whether the CLI is signed in another way couldn''t be read: the deployment went on, and the Insights app''s step uses a sign-in this machine already has, if any, or says why there''s none. ./scripts/configure-fabric-app.ps1 -SignIn adds the app later.' -f $why) -Remediation $remediation
                }
            }
            if ([object]::ReferenceEquals($script:DemoFabricAppSignIn, $SignIn)) {
                $script:DemoFabricAppSignIn = $null
            }
        }
        if ([bool]$SignIn.Reported -or $null -eq $SignIn.Result) {
            return
        }
        $SignIn.Reported = $true
        return $SignIn.Result
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The Rayfin CLI''s sign-in couldn''t be read: {0}' -f $_.Exception.Message)
    }
}

function Get-DemoRayfinSignInState {
    <#
    .SYNOPSIS
    Whether the Rayfin CLI is signed in to -TenantId, from 'rayfin login status --json', which never opens a browser:
    SignedIn; NotSignedIn (not signed in, or to another tenant); or Unknown (no tenant, or not read within
    -TimeoutSeconds). Never throws. Internal.

    .DESCRIPTION
    The stage's pinned CLI answers when it's installed (Invoke-DemoRayfinCli), as Start-DemoFabricAppSignIn and
    Test-DemoFabricAppPrerequisite read it. Otherwise the same pinned version answers through npx, as the sign-in itself
    runs (Start-DemoRayfinSignInProcess), because a first run has no stage until the Insights app's step; --prefer-offline
    uses the package that sign-in left in npm's cache without asking the registry again. Both read the CLI's own token
    cache, which is per user, so a sign-in from any of them counts. Measured on 2026-11-06 through npx: about 9 seconds
    warm, and more than 30 on a cold start, hence the minute. Only a debug line is logged when it can't be read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $TenantId = '',

        [ValidateRange(5, 300)]
        [int] $TimeoutSeconds = 60
    )

    if ($TenantId -notmatch $script:GuidPattern) {
        return 'Unknown'
    }
    # A read-only status query of the Rayfin CLI's own token cache; nothing here signs in or out.
    $statusQuery = @('login', 'status', '--json')
    try {
        $stage = Join-Path -Path $script:RepoRoot -ChildPath 'out/fabric-app'
        if (Get-DemoRayfinCliPath -StagePath $stage) {
            $data = (Invoke-DemoRayfinCli -StagePath $stage -ArgumentList $statusQuery -TimeoutSeconds $TimeoutSeconds).Data
        }
        else {
            $settings = Get-DemoFabricAppSetting
            $arguments = @('--yes', '--prefer-offline', ('--package={0}@{1}' -f $settings['cliPackage'], $settings['cliVersion']), '--', 'rayfin') + $statusQuery
            $run = Invoke-DemoFabricAppProcess -Tool 'npx' -ArgumentList $arguments -WorkingDirectory $script:RepoRoot -TimeoutSeconds $TimeoutSeconds -Environment @{ RAYFIN_TELEMETRY_OPTOUT = '1'; RAYFIN_TOKEN = $null; NO_COLOR = '1' }
            $data = ConvertFrom-DemoRayfinOutput -Text ([string]$run.StdOut)
        }
        $status = [string](Get-DemoMemberValue -InputObject $data -Name 'status')
        if ($status -eq 'ok') {
            if ([string](Get-DemoMemberValue -InputObject $data -Name 'tenant') -ieq $TenantId) {
                return 'SignedIn'
            }
            return 'NotSignedIn'
        }
        if ($status -eq 'not-signed-in') {
            return 'NotSignedIn'
        }
        Write-DemoLog -Level Debug -Message ('The Rayfin CLI''s sign-in status didn''t say: {0}' -f $(if ($status) { $status } else { 'no status' }))
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The Rayfin CLI''s sign-in status couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    return 'Unknown'
}

function Stop-DemoFabricAppSignIn {
    # Ends the sign-in's process when it still runs because the run ended or was stopped before it settled (deploy.ps1's
    # cleanup), with every process it started, and without a record; without -SignIn, the one this session started last.
    # Never throws. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Ends only the sign-in process this run started, when the run ends.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $SignIn = $null
    )

    if ($null -eq $SignIn) {
        $SignIn = $script:DemoFabricAppSignIn
    }
    if ($null -eq $SignIn) {
        return
    }
    try {
        $process = $SignIn.Process
        if ($null -ne $process -and -not $process.HasExited) {
            $process.Kill($true)
        }
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The Rayfin CLI''s sign-in couldn''t be ended: {0}' -f $_.Exception.Message)
    }
    if ([object]::ReferenceEquals($script:DemoFabricAppSignIn, $SignIn)) {
        $script:DemoFabricAppSignIn = $null
    }
}

function Wait-DemoFabricAppSignIn {
    <#
    .SYNOPSIS
    Right before the Insights app's step: while the run's sign-in (Start-DemoFabricAppSignIn) still waits for the person,
    waits for it, at most until its deadline (the model's run.appSignInUntil), so a sign-in finished meanwhile counts.
    Returns the seconds it waited. Internal.

    .DESCRIPTION
    Only the app's step waits, in the Fabric track's own process; nothing else in the run does, and it reads the progress
    model only, whose Fabric.AppSignIn row deploy.ps1 settles while it waits for the tracks (Complete-DemoFabricAppSignIn).
    Nothing without a model, or once the row isn't Running. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 5
    )

    if (-not $ProgressPath) {
        return 0
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $said = $false
    try {
        while ($true) {
            $model = Read-DemoProgress -Path $ProgressPath
            if ($null -eq $model) {
                break
            }
            $row = Find-DemoProgressStep -Model $model -Id 'Fabric.AppSignIn'
            $run = Get-DemoMemberValue -InputObject $model -Name 'run'
            $until = [long](Get-DemoMemberValue -InputObject $run -Name 'appSignInUntil')
            $now = Get-DemoUnixTime
            if ($null -eq $row -or [string]$row['state'] -ne 'Running' -or $until -le $now) {
                break
            }
            if (-not $said) {
                $said = $true
                $text = 'Waiting for the Rayfin CLI''s sign-in in the browser, at most until {0}; then the Insights app is created, or its step says why not.' -f (Format-DemoProgressClock -Unix $until)
                Set-DemoProgressStep -Path $ProgressPath -Id 'Fabric.App' -State 'Running' -Message $text
                Write-DemoLog -Message $text
            }
            Start-Sleep -Seconds ([int][System.Math]::Max(1, [System.Math]::Min($PollSeconds, $until - $now)))
        }
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The sign-in''s state couldn''t be read, so the Insights app''s step goes on: {0}' -f $_.Exception.Message)
    }
    return [int]$watch.Elapsed.TotalSeconds
}
