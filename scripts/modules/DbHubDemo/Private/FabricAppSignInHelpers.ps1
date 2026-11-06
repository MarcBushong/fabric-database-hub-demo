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
# - 'rayfin login status --json' prints {"status":"ok",...,"tenant":...} or {"status":"not-signed-in",...}, and has no
#   option but -h (its --help, and dist/commands/login.js in the same package, read on 2026-11-06).

# The sign-in this session started last, which Stop-DemoFabricAppSignIn ends when the run ends without settling it.
$script:DemoFabricAppSignIn = $null
# The read of the CLI's sign-in that this session's run started before its subscription guard
# (Start-DemoFabricAppSignInCheck), until Start-DemoFabricAppSignIn takes its answer; Stop-DemoFabricAppSignIn ends it
# when the run ends first.
$script:DemoFabricAppSignInCheck = $null

# How long the read of the CLI's sign-in may take before a browser opens anyway (2026-11-06 live finding: the stage's
# CLI answered in 44 seconds cold, after the 30 seconds it had, and in about 9 seconds warm).
$script:DemoRayfinStatusTimeoutSeconds = 90

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
    - The CLI's own status says whether it's signed in ('rayfin login status --json', never a browser;
      Receive-DemoRayfinSignInStatus): the stage's pinned CLI when it's installed, otherwise the same version through npx.
      deploy.ps1 starts that read before its subscription guard (-Check, from Start-DemoFabricAppSignInCheck), so it runs
      alongside the run's first steps; without -Check it starts here. It answers within 90 seconds of its start; while
      it's still reading, the status page and the console say so. Signed in to the demo's tenant: Pass, and nothing
      starts. Not signed in: an Info line says so. Not read in time, or at all: a Warning line says why (2026-11-06 live
      finding: a cold read took 44 seconds, after the 30 it had, so a browser opened for nothing and nothing said why).
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
        [int] $TimeoutMinutes = 15,

        # The read of the CLI's sign-in that the run started early (Start-DemoFabricAppSignInCheck).
        [AllowNull()]
        [object] $Check = $null
    )

    $now = [System.DateTime]::UtcNow
    $state = [pscustomobject]@{ Process = $null; TenantId = ''; StartedUtc = $now; DeadlineUtc = $now.AddMinutes($TimeoutMinutes); TimeoutMinutes = $TimeoutMinutes; Done = $false; Reported = $false; Result = $null }
    $later = 'Run ./scripts/configure-fabric-app.ps1 -SignIn in a terminal: it opens a browser for your own sign-in (an assistant can''t do it for you), then adds the Insights app.'
    if (-not (Test-DemoInteractiveSession)) {
        Stop-DemoRayfinSignInStatus -Status $Check
        Set-DemoFabricAppSignInResult -SignIn $state -ProgressPath $ProgressPath -Status 'Not supported' -Message 'This session can''t answer a browser sign-in (CI, or input redirected, as under an assistant), so the Rayfin CLI''s sign-in for the Insights app wasn''t started. The app''s step uses a sign-in this machine already has, if any.' -Remediation $later
        return $state
    }
    $tenantId = [string]$Config['tenantId']
    if ($tenantId -notmatch $script:GuidPattern) {
        Stop-DemoRayfinSignInStatus -Status $Check
        Set-DemoFabricAppSignInResult -SignIn $state -ProgressPath $ProgressPath -Status 'Warning' -Message 'No tenant (tenantId) is configured, so the Rayfin CLI can''t be signed in for the Insights app.' -Remediation 'Run ./scripts/init.ps1, or set tenantId in the configuration.'
        return $state
    }
    # Already signed in? The CLI's own status says so without a browser, a first run's too (through npx).
    if ($null -eq $Check -or [string](Get-DemoMemberValue -InputObject $Check -Name 'TenantId') -ne $tenantId) {
        Stop-DemoRayfinSignInStatus -Status $Check
        $Check = Start-DemoRayfinSignInStatus -TenantId $tenantId -TimeoutSeconds $script:DemoRayfinStatusTimeoutSeconds
    }
    if (Test-DemoRayfinSignInStatusRunning -Status $Check) {
        $until = ([System.DateTime]$Check.StartedUtc).AddSeconds([int]$Check.TimeoutSeconds)
        $text = 'Checking whether the Rayfin CLI is already signed in to the demo''s tenant, at most until {0}; a browser opens only if it isn''t.' -f (Format-DemoProgressClock -Unix (Get-DemoUnixTime -Value $until))
        Set-DemoProgressStep -Path $ProgressPath -Id 'Fabric.AppSignIn' -State 'Running' -Message $text
        Write-DemoLog -Message $text
    }
    $cli = Receive-DemoRayfinSignInStatus -Status $Check
    if ([object]::ReferenceEquals($script:DemoFabricAppSignInCheck, $Check)) {
        $script:DemoFabricAppSignInCheck = $null
    }
    $via = if ($cli.Via) { 'rayfin login status through {0}' -f $cli.Via } else { 'rayfin login status' }
    if ($cli.State -eq 'SignedIn') {
        Write-DemoLog -Message ('The Rayfin CLI is already signed in to the demo''s tenant ({0}, {1} seconds), so no browser opens for the Insights app.' -f $via, $cli.Seconds)
        Set-DemoFabricAppSignInResult -SignIn $state -ProgressPath $ProgressPath -Status 'Pass' -Message 'The Rayfin CLI is already signed in to the demo''s tenant, so no browser opened; the Insights app''s step uses that sign-in.'
        return $state
    }
    if ($cli.State -eq 'NotSignedIn') {
        Write-DemoLog -Message ('The Rayfin CLI is {0} ({1}, {2} seconds), so its sign-in for the Insights app starts: a browser opens.' -f $cli.Detail, $via, $cli.Seconds)
    }
    else {
        $settings = Get-DemoFabricAppSetting
        Write-DemoLog -Level Warning -Message ('Whether the Rayfin CLI is already signed in couldn''t be read ({0}; {1}), so its sign-in for the Insights app starts: a browser opens, even if it''s signed in. To read it yourself: npx --yes --package={2}@{3} -- rayfin login status' -f $cli.Detail, $via, $settings['cliPackage'], $settings['cliVersion'])
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
                $cli = if (Test-DemoRunCancelled) { $null } else { Get-DemoRayfinSignInState -TenantId ([string](Get-DemoMemberValue -InputObject $SignIn -Name 'TenantId')) }
                $cliState = [string](Get-DemoMemberValue -InputObject $cli -Name 'State')
                if ($cliState -eq 'SignedIn') {
                    Set-DemoFabricAppSignInResult -SignIn $SignIn -ProgressPath $ProgressPath -Status 'Pass' -Message ('The Rayfin CLI is signed in to the demo''s tenant ({0}, but a sign-in already exists); the Insights app''s step uses it.' -f $window)
                }
                elseif ($cliState -eq 'NotSignedIn') {
                    Set-DemoFabricAppSignInResult -SignIn $SignIn -ProgressPath $ProgressPath -Status 'Warning' -Message ('{0} {1}' -f $why, $consequence) -Remediation $remediation
                }
                else {
                    $unread = if ($null -eq $cli) { 'the run was stopped first' } else { [string]$cli.Detail }
                    Set-DemoFabricAppSignInResult -SignIn $SignIn -ProgressPath $ProgressPath -Status 'Warning' -Message ('{0} Whether the CLI is signed in another way couldn''t be read ({1}): the deployment went on, and the Insights app''s step uses a sign-in this machine already has, if any, or says why there''s none. ./scripts/configure-fabric-app.ps1 -SignIn adds the app later.' -f $why, $unread) -Remediation $remediation
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
    Whether the Rayfin CLI is signed in to -TenantId, read now and waited for, at most -TimeoutSeconds
    (Start-DemoRayfinSignInStatus, then Receive-DemoRayfinSignInStatus): State (SignedIn, NotSignedIn, or Unknown),
    Detail, Seconds, and Via. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $TenantId = '',

        [ValidateRange(5, 600)]
        [int] $TimeoutSeconds = 60
    )

    return (Receive-DemoRayfinSignInStatus -Status (Start-DemoRayfinSignInStatus -TenantId $TenantId -TimeoutSeconds $TimeoutSeconds))
}

function Start-DemoFabricAppSignInCheck {
    <#
    .SYNOPSIS
    Starts reading whether the Rayfin CLI is signed in at the start of a deploy.ps1 run, before its subscription guard,
    so the read runs alongside the run's first steps, and returns it for Start-DemoFabricAppSignIn -Check. $null, and
    nothing starts, where no sign-in could start: a session that can't answer a browser sign-in, or no tenant. Never
    throws. Internal.

    .DESCRIPTION
    The read took about 9 seconds warm and 44 seconds cold on 2026-11-06 (live), and the subscription guard alone took
    22 seconds in a timed run, so the run's start rarely waits for it. Stop-DemoFabricAppSignIn ends it when the run
    ends before Start-DemoFabricAppSignIn takes it, and the run ends it as soon as it knows the Fabric track won't run.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a read-only status query of the Rayfin CLI on this machine.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $tenantId = [string]$Config['tenantId']
    if ($tenantId -notmatch $script:GuidPattern -or -not (Test-DemoInteractiveSession)) {
        return $null
    }
    Stop-DemoRayfinSignInStatus -Status $script:DemoFabricAppSignInCheck
    $check = Start-DemoRayfinSignInStatus -TenantId $tenantId -TimeoutSeconds $script:DemoRayfinStatusTimeoutSeconds
    $script:DemoFabricAppSignInCheck = $check
    Write-DemoLog -Level Debug -Message ('Reading whether the Rayfin CLI is signed in (rayfin login status through {0}), alongside the run''s first steps.' -f $(if ($check.Via) { $check.Via } else { 'nothing: it couldn''t start' }))
    return $check
}

function Start-DemoRayfinSignInStatus {
    <#
    .SYNOPSIS
    Starts reading whether the Rayfin CLI is signed in to -TenantId ('rayfin login status --json', which never opens a
    browser) without waiting, and returns the read for Receive-DemoRayfinSignInStatus or Stop-DemoRayfinSignInStatus.
    Never throws. Internal.

    .DESCRIPTION
    The stage's pinned CLI answers when it's installed (out/fabric-app), with node, as Test-DemoFabricAppPrerequisite
    reads it. Otherwise the same pinned version answers through npx, as the sign-in itself runs
    (Start-DemoRayfinSignInProcess), because a first run, from a fresh clone too, has no stage until the Insights app's
    step; --prefer-offline uses the package npm's cache already has without asking the registry again. Both read the
    CLI's own token cache, which is per user, so a sign-in from either counts. The CLI's telemetry is off and an ambient
    RAYFIN_TOKEN is removed for the child only. A start that fails (no tenant, node or npx not on PATH) is kept in Error,
    for Receive-DemoRayfinSignInStatus to report.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a read-only status query of the Rayfin CLI on this machine.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $TenantId,

        [ValidateRange(5, 600)]
        [int] $TimeoutSeconds = 90
    )

    $status = [pscustomobject]@{ TenantId = $TenantId; Via = ''; Run = $null; StartedUtc = [System.DateTime]::UtcNow; TimeoutSeconds = $TimeoutSeconds; Error = ''; Result = $null }
    if ($TenantId -notmatch $script:GuidPattern) {
        $status.Error = 'no tenant (tenantId) is configured'
        return $status
    }
    # A read-only status query of the Rayfin CLI's own token cache; nothing here signs in or out.
    $statusQuery = @('login', 'status', '--json')
    $environment = @{ RAYFIN_TELEMETRY_OPTOUT = '1'; RAYFIN_TOKEN = $null; NO_COLOR = '1' }
    try {
        $stage = Join-Path -Path $script:RepoRoot -ChildPath 'out/fabric-app'
        $cli = Get-DemoRayfinCliPath -StagePath $stage
        if ($cli) {
            $status.Via = 'the stage''s CLI'
            $status.Run = Start-DemoFabricAppProcess -Tool 'node' -ArgumentList (@($cli) + $statusQuery) -WorkingDirectory $stage -TimeoutSeconds $TimeoutSeconds -Environment $environment
        }
        else {
            $settings = Get-DemoFabricAppSetting
            $status.Via = 'npx'
            $arguments = @('--yes', '--prefer-offline', ('--package={0}@{1}' -f $settings['cliPackage'], $settings['cliVersion']), '--', 'rayfin') + $statusQuery
            $status.Run = Start-DemoFabricAppProcess -Tool 'npx' -ArgumentList $arguments -WorkingDirectory $script:RepoRoot -TimeoutSeconds $TimeoutSeconds -Environment $environment
        }
        $status.StartedUtc = $status.Run.StartedUtc
    }
    catch {
        $status.Error = Protect-DemoText -Text $_.Exception.Message
    }
    return $status
}

function Test-DemoRayfinSignInStatusRunning {
    # True while a read Start-DemoRayfinSignInStatus started still runs: it started, wasn't read, and its process hasn't
    # ended. Never throws. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Status
    )

    if ($null -eq $Status -or $null -ne (Get-DemoMemberValue -InputObject $Status -Name 'Result')) {
        return $false
    }
    $run = Get-DemoMemberValue -InputObject $Status -Name 'Run'
    if ($null -eq $run -or [bool](Get-DemoMemberValue -InputObject $run -Name 'Closed')) {
        return $false
    }
    try {
        return (-not $run.Process.HasExited)
    }
    catch {
        return $false
    }
}

function Receive-DemoRayfinSignInStatus {
    <#
    .SYNOPSIS
    Waits for the read Start-DemoRayfinSignInStatus started, at most until its time limit from its start, and returns
    State: SignedIn (to its tenant), NotSignedIn (not signed in, or to another tenant), or Unknown (not read in time, or
    not at all); Detail, which says why, for a log line; Seconds, how long the read took; and Via (the stage's CLI, or
    npx). Reads it once, and gives the same answer after that. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Status
    )

    $known = Get-DemoMemberValue -InputObject $Status -Name 'Result'
    if ($null -ne $known) {
        return $known
    }
    $answer = {
        param([string] $State, [string] $Detail, [int] $Seconds)
        $value = [pscustomobject]@{ State = $State; Detail = $Detail; Seconds = $Seconds; Via = [string](Get-DemoMemberValue -InputObject $Status -Name 'Via') }
        $Status | Add-Member -NotePropertyName 'Result' -NotePropertyValue $value -Force
        $value
    }
    try {
        $problem = [string](Get-DemoMemberValue -InputObject $Status -Name 'Error')
        $run = Get-DemoMemberValue -InputObject $Status -Name 'Run'
        if ($problem -or $null -eq $run) {
            return (& $answer 'Unknown' ('it couldn''t start: {0}' -f $(if ($problem) { $problem } else { 'no process' })) 0)
        }
        $read = Receive-DemoFabricAppProcess -Handle $run
        if ([bool]$read.TimedOut) {
            return (& $answer 'Unknown' ('no answer within {0} seconds' -f $Status.TimeoutSeconds) ([int]$read.Seconds))
        }
        $data = ConvertFrom-DemoRayfinOutput -Text ([string]$read.StdOut)
        $said = [string](Get-DemoMemberValue -InputObject $data -Name 'status')
        if ($said -eq 'ok') {
            if ([string](Get-DemoMemberValue -InputObject $data -Name 'tenant') -ieq [string]$Status.TenantId) {
                return (& $answer 'SignedIn' 'signed in to the demo''s tenant' ([int]$read.Seconds))
            }
            return (& $answer 'NotSignedIn' 'signed in to another tenant than the demo''s' ([int]$read.Seconds))
        }
        if ($said -eq 'not-signed-in') {
            return (& $answer 'NotSignedIn' 'not signed in' ([int]$read.Seconds))
        }
        $message = [string](Get-DemoMemberValue -InputObject $data -Name 'error')
        if (-not $message) {
            foreach ($text in @([string]$read.StdErr, [string]$read.StdOut)) {
                $line = @($text -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -First 1
                if ($line) {
                    $message = [string]$line
                    break
                }
            }
        }
        if (-not $message) {
            $message = 'no output'
        }
        if ($message.Length -gt 300) {
            $message = $message.Substring(0, 300) + '...'
        }
        return (& $answer 'Unknown' ('exit code {0}: {1}' -f $read.ExitCode, $message) ([int]$read.Seconds))
    }
    catch {
        return (& $answer 'Unknown' ('it couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) 0)
    }
}

function Stop-DemoRayfinSignInStatus {
    # Ends a read Start-DemoRayfinSignInStatus started that's no longer needed (the run ends first, or won't sign in),
    # with every process it started, without waiting for it; a read that already answered keeps its answer. Never
    # throws. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Ends only a read-only status query this run started.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Status
    )

    if ($null -eq $Status) {
        return
    }
    try {
        if ($null -eq (Get-DemoMemberValue -InputObject $Status -Name 'Result')) {
            Stop-DemoFabricAppProcess -Handle (Get-DemoMemberValue -InputObject $Status -Name 'Run')
            $stopped = [pscustomobject]@{ State = 'Unknown'; Detail = 'it was stopped before it was read'; Seconds = 0; Via = [string](Get-DemoMemberValue -InputObject $Status -Name 'Via') }
            $Status | Add-Member -NotePropertyName 'Result' -NotePropertyValue $stopped -Force
        }
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The read of the Rayfin CLI''s sign-in couldn''t be ended: {0}' -f $_.Exception.Message)
    }
    if ([object]::ReferenceEquals($script:DemoFabricAppSignInCheck, $Status)) {
        $script:DemoFabricAppSignInCheck = $null
    }
}

function Stop-DemoFabricAppSignIn {
    # Ends the sign-in's process when it still runs because the run ended or was stopped before it settled (deploy.ps1's
    # cleanup), with every process it started, and without a record; without -SignIn, the one this session started last.
    # A read of the CLI's sign-in that the run started early and didn't use ends too (Start-DemoFabricAppSignInCheck).
    # Never throws. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Ends only the sign-in process this run started, when the run ends.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $SignIn = $null
    )

    Stop-DemoRayfinSignInStatus -Status $script:DemoFabricAppSignInCheck
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
