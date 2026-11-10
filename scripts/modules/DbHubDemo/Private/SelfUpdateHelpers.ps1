# deploy.ps1's self-update (2026-11-09, the owner's choice: "Update itself: fast-forward a clean checkout to the latest
# main, then run"). A tester's assistant re-ran an older demo from a clone pulled before a fix merged and got the fixed
# refusal again, because deploy.ps1 runs the code in its folder and never asked GitHub. Invoke-DemoSelfUpdate uses these.

# The variable that marks deploy.ps1's restarted process (the loop guard): <from>;<to>;<commits>. The opt-out variable.
$script:SelfUpdateMarkerVariable = 'DBHUB_SELF_UPDATED'
$script:SelfUpdateOptOutVariable = 'DBHUB_NO_SELF_UPDATE'
$script:SelfUpdateCloneUrl = 'https://github.com/MarcBushong/fabric-database-hub-demo.git'

function Get-DemoGitOnPath {
    <#
    .SYNOPSIS
    The git executable on PATH, or ''. Internal; tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $command = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return [string]$command.Source
    }
    return ''
}

function Invoke-DemoVsWhere {
    <#
    .SYNOPSIS
    The installation folders of Visual Studio that vswhere lists (every instance, prereleases included), or none when
    vswhere isn't there. Internal; tests mock it.

    .DESCRIPTION
    vswhere.exe is at a fixed place that the Visual Studio Installer keeps
    (https://github.com/microsoft/vswhere/wiki/Installing): %ProgramFiles(x86)%\Microsoft Visual Studio\Installer.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $programFilesX86 = [System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not $programFilesX86) {
        return
    }
    $vswhere = Join-Path -Path $programFilesX86 -ChildPath 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        return
    }
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $vswhere -all -prerelease -products '*' -property installationPath 2>$null
        return @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
    catch {
        Write-DemoLog -Level Debug -Message ('vswhere couldn''t list Visual Studio: {0}' -f $_.Exception.Message)
        return
    }
}

function Get-DemoGitCandidatePath {
    <#
    .SYNOPSIS
    Where Git is usually installed when it isn't on PATH, in the order deploy.ps1 tries them (2026-11-09 live finding: a
    clone made where the only git was an app's bundled one never updated itself). Internal.

    .DESCRIPTION
    Returns Path and Source (who installed it) for each candidate that could exist; Get-DemoGitLocation keeps the ones
    that are files and runs them.
    - Windows: Git for Windows for all users (%ProgramFiles%, then %ProgramFiles(x86)%) and per user
      (%LOCALAPPDATA%\Programs\Git), each git.exe in its cmd folder (https://gitforwindows.org/); GitHub Desktop's bundled
      Git, in %LOCALAPPDATA%\GitHubDesktop\app-<version>\resources\app\git\cmd, the newest version first; and Visual
      Studio's bundled Git, in each installation that vswhere lists (Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\
      Team Explorer\Git\cmd).
    - macOS and Linux: /usr/bin/git, /usr/local/bin/git, and /opt/homebrew/bin/git (Homebrew on Apple silicon).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [bool] $Windows = [bool]$IsWindows
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    $add = { param([string] $Path, [string] $Source) if ($Path) { $candidates.Add([pscustomobject]@{ Path = $Path; Source = $Source }) } }
    if (-not $Windows) {
        & $add '/usr/bin/git' 'the system''s Git'
        & $add '/usr/local/bin/git' 'Git in /usr/local'
        & $add '/opt/homebrew/bin/git' 'Homebrew''s Git'
        return $candidates.ToArray()
    }
    $under = { param([string] $Variable, [string] $Child) $base = [System.Environment]::GetEnvironmentVariable($Variable); if ($base) { Join-Path -Path $base -ChildPath $Child } else { '' } }
    & $add (& $under 'ProgramFiles' 'Git\cmd\git.exe') 'Git for Windows'
    & $add (& $under 'ProgramFiles(x86)' 'Git\cmd\git.exe') 'Git for Windows (32-bit)'
    & $add (& $under 'LOCALAPPDATA' 'Programs\Git\cmd\git.exe') 'Git for Windows, installed for this user'
    $desktop = & $under 'LOCALAPPDATA' 'GitHubDesktop'
    if ($desktop -and (Test-Path -LiteralPath $desktop -PathType Container)) {
        $versionOf = {
            param([string] $Name)
            $parsed = $null
            if ([System.Version]::TryParse(($Name -replace '^app-', ''), [ref]$parsed)) { $parsed } else { [System.Version]::new(0, 0) }
        }
        $apps = @(Get-ChildItem -LiteralPath $desktop -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | Sort-Object -Property @{ Expression = { & $versionOf $_.Name }; Descending = $true }, @{ Expression = 'LastWriteTimeUtc'; Descending = $true })
        foreach ($app in $apps) {
            & $add (Join-Path -Path $app.FullName -ChildPath 'resources\app\git\cmd\git.exe') ('GitHub Desktop''s Git ({0})' -f $app.Name)
        }
    }
    foreach ($installation in @(Invoke-DemoVsWhere)) {
        & $add (Join-Path -Path $installation -ChildPath 'Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\Git\cmd\git.exe') 'Visual Studio''s Git'
    }
    return $candidates.ToArray()
}

function Test-DemoGitExecutable {
    <#
    .SYNOPSIS
    Whether a git executable runs: 'git --version' within 10 seconds, answering 'git version ...'. Internal; tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    try {
        $run = Invoke-DemoGit -GitPath $Path -ArgumentList @('--version') -WorkingDirectory ([System.IO.Path]::GetTempPath()) -TimeoutSeconds 10
        return ($run.ExitCode -eq 0 -and $run.StdOut -like 'git version*')
    }
    catch {
        return $false
    }
}

function Get-DemoGitLocation {
    <#
    .SYNOPSIS
    The git that deploy.ps1's self-update uses: the one on PATH, or else the first well-known one that runs
    (Get-DemoGitCandidatePath, Test-DemoGitExecutable). Returns Path ('' when there's none), OnPath, and Source. PATH
    itself is never changed. Internal; tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $onPath = Get-DemoGitOnPath
    if ($onPath) {
        return [pscustomobject]@{ Path = $onPath; OnPath = $true; Source = 'PATH' }
    }
    foreach ($candidate in @(Get-DemoGitCandidatePath)) {
        if ((Test-Path -LiteralPath $candidate.Path -PathType Leaf) -and (Test-DemoGitExecutable -Path $candidate.Path)) {
            return [pscustomobject]@{ Path = [string]$candidate.Path; OnPath = $false; Source = [string]$candidate.Source }
        }
    }
    return [pscustomobject]@{ Path = ''; OnPath = $false; Source = '' }
}

function Get-DemoGitPath {
    <#
    .SYNOPSIS
    The git executable to run (Get-DemoGitLocation's Path), or '' when Git can't be found. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [string](Get-DemoGitLocation).Path
}

function Format-DemoGitUsedText {
    <#
    .SYNOPSIS
    ' It used the git at <path> (<source>), which isn't on PATH.' for a git found off PATH, '' otherwise. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Path = '',

        [bool] $OnPath = $true,

        [AllowEmptyString()]
        [string] $Source = ''
    )

    if (-not $Path -or $OnPath) {
        return ''
    }
    return (' It used the git at {0}{1}, which isn''t on PATH.' -f $Path, $(if ($Source) { ' ({0})' -f $Source } else { '' }))
}

function Invoke-DemoGit {
    <#
    .SYNOPSIS
    Runs git with an argument array in a folder, with a time limit, and returns ExitCode, StdOut, StdErr (redacted and
    trimmed), and TimedOut. Internal; tests mock it.

    .DESCRIPTION
    Standard input is closed and git never prompts: GIT_TERMINAL_PROMPT=0 stops its own prompt for a user name or
    password, and GCM_INTERACTIVE=never Git Credential Manager's window, so a fetch that needs a credential fails at
    once instead of waiting for a person (https://git-scm.com/docs/git#Documentation/git.txt-codeGITTERMINALPROMPTcode).
    When the time limit passes, git and its children are stopped and ExitCode is -1. The arguments go to git as they
    are (ProcessStartInfo.ArgumentList), with no quoting.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 30,

        [string] $GitPath = ''
    )

    $git = if ($GitPath) { $GitPath } else { Get-DemoGitPath }
    if (-not $git) {
        throw 'git was not found on PATH or where Git is usually installed.'
    }
    $info = [System.Diagnostics.ProcessStartInfo]::new($git)
    foreach ($argument in $ArgumentList) {
        $info.ArgumentList.Add($argument)
    }
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $info.Environment['GCM_INTERACTIVE'] = 'never'
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            try {
                $process.Kill($true)
            }
            catch {
                Write-DemoLog -Level Debug -Message ('git couldn''t be stopped after its time limit: {0}' -f $_.Exception.Message)
            }
            $null = $process.WaitForExit(5000)
        }
        else {
            # Waits for the output to be read to its end, too.
            $process.WaitForExit()
        }
        $out = if ($stdout.Wait(5000)) { [string]$stdout.Result } else { '' }
        $err = if ($stderr.Wait(5000)) { [string]$stderr.Result } else { '' }
        return [pscustomobject]@{
            ExitCode = $(if ($timedOut) { -1 } else { $process.ExitCode })
            # Only the end: a porcelain status line starts with a space (' M file').
            StdOut   = (Protect-DemoText -Text $out).TrimEnd()
            StdErr   = (Protect-DemoText -Text $err).Trim()
            TimedOut = $timedOut
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-DemoCheckoutState {
    <#
    .SYNOPSIS
    Where this checkout stands against GitHub's main: Git found, a checkout of this folder, the branch and its upstream,
    the fetch of origin's main (with a time limit), the commits it's behind and ahead, and the tracked files with local
    changes. Reads only, but for the fetch, which updates refs/remotes/origin/main. Internal.

    .DESCRIPTION
    Stops at the first thing it can't learn, with Problem set: NoGit (no Git found, and no .git here), NoGitCheckout (no
    Git found, but a .git here), NotCheckout, or FetchFailed (FetchError says why; TimedOut when the fetch outlived
    -FetchTimeoutSeconds). Branch is '' for a detached HEAD. Dirty lists tracked files
    that are modified or staged (git status --untracked-files=no), so the Git-ignored config/ and out/ files never count.
    GitPath, GitOnPath, and GitSource say which git ran every call (Get-DemoGitLocation).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [ValidateRange(1, 300)]
        [int] $FetchTimeoutSeconds = 20
    )

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $state = [ordered]@{
        Problem    = ''
        FetchError = ''
        TimedOut   = $false
        Root       = $root
        Branch     = ''
        Upstream   = ''
        Head       = ''
        Remote     = ''
        Behind     = 0
        Ahead      = 0
        Dirty      = @()
        GitPath    = ''
        GitOnPath  = $true
        GitSource  = ''
    }
    $done = { param([string] $Problem) $state.Problem = $Problem; return [pscustomobject]$state }
    $location = Get-DemoGitLocation
    if (-not $location.Path) {
        # A .git folder (or a worktree's .git file) says it's a checkout even without Git: then git pull is the fix, not a
        # fresh clone (2026-11-09 live finding).
        return (& $done $(if (Test-Path -LiteralPath (Join-Path -Path $root -ChildPath '.git')) { 'NoGitCheckout' } else { 'NoGit' }))
    }
    $state.GitPath = [string]$location.Path
    $state.GitOnPath = [bool]$location.OnPath
    $state.GitSource = [string]$location.Source
    $gitPath = $state.GitPath
    $git = { param([string[]] $Arguments, [int] $Seconds = 15) Invoke-DemoGit -GitPath $gitPath -ArgumentList $Arguments -WorkingDirectory $root -TimeoutSeconds $Seconds }

    # A downloaded zip has no .git; a folder inside some other checkout has a prefix there. The prefix needs no path
    # comparison, which a short (8.3) or differently cased path would fool.
    $prefix = & $git @('rev-parse', '--show-prefix')
    if ($prefix.ExitCode -ne 0 -or $prefix.StdOut.Trim()) {
        return (& $done 'NotCheckout')
    }
    $branch = & $git @('symbolic-ref', '--quiet', '--short', 'HEAD')
    $state.Branch = if ($branch.ExitCode -eq 0) { $branch.StdOut } else { '' }
    if ($state.Branch) {
        $upstream = & $git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', ('{0}@{{upstream}}' -f $state.Branch))
        $state.Upstream = if ($upstream.ExitCode -eq 0) { $upstream.StdOut } else { '' }
    }
    $state.Head = (& $git @('rev-parse', 'HEAD')).StdOut

    $fetch = & $git @('fetch', '--quiet', '--no-tags', '--no-recurse-submodules', 'origin', '+refs/heads/main:refs/remotes/origin/main') $FetchTimeoutSeconds
    if ($fetch.ExitCode -ne 0) {
        $state.TimedOut = [bool]$fetch.TimedOut
        $state.FetchError = if ($fetch.TimedOut) { 'git fetch didn''t finish within {0} seconds' -f $FetchTimeoutSeconds } elseif ($fetch.StdErr) { ($fetch.StdErr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim() } else { 'git fetch ended with exit code {0}' -f $fetch.ExitCode }
        return (& $done 'FetchFailed')
    }
    $state.Remote = (& $git @('rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main^{commit}')).StdOut
    $counts = & $git @('rev-list', '--left-right', '--count', 'HEAD...refs/remotes/origin/main')
    if ($counts.ExitCode -ne 0 -or -not $state.Remote) {
        $state.FetchError = 'origin''s main couldn''t be compared with HEAD'
        return (& $done 'FetchFailed')
    }
    $parts = @($counts.StdOut -split '\s+' | Where-Object { $_ })
    $state.Ahead = [int]$parts[0]
    $state.Behind = [int]$parts[1]
    $status = & $git @('status', '--porcelain=v1', '--untracked-files=no')
    $state.Dirty = @($status.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Where-Object { $_.Length -gt 3 } | ForEach-Object { $_.Substring(3).Trim() })
    return [pscustomobject]$state
}

function ConvertTo-DemoScriptArgument {
    <#
    .SYNOPSIS
    A script's bound parameters as the argument array that 'pwsh -File <script>' binds the same way: -Name value for a
    value, -Name for a switch that's set, and -Name:$false for one set to false. Pure. Internal.

    .DESCRIPTION
    Each value is one array item, so the caller's native argument passing quotes it (a path with spaces or quotes stays
    one argument), and an empty string stays an empty argument. Common parameters (-Verbose, -WhatIf, -ErrorAction, and
    so on) are passed the same way. 'pwsh -File' takes -Name:$false for a switch
    (https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_pwsh#-file---f).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary] $BoundParameters
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($BoundParameters.Keys)) {
        $value = $BoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
            if ([bool]$value) {
                $arguments.Add(('-{0}' -f $name))
            }
            else {
                $arguments.Add(('-{0}:$false' -f $name))
            }
            continue
        }
        foreach ($item in @($value)) {
            $arguments.Add(('-{0}' -f $name))
            $arguments.Add([string]$item)
        }
    }
    return , $arguments.ToArray()
}

function Get-DemoPwshPath {
    <#
    .SYNOPSIS
    The PowerShell 7 executable to restart a script with: this process's own when it's pwsh, otherwise the pwsh on PATH.
    Internal; tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $own = [System.Environment]::ProcessPath
    if ($own -and [System.IO.Path]::GetFileNameWithoutExtension($own) -eq 'pwsh') {
        return $own
    }
    $command = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return [string]$command.Source
    }
    return ''
}

function Start-DemoSelfRestart {
    <#
    .SYNOPSIS
    Runs a script again in a fresh pwsh process, in this console, with the given arguments and the self-update marker
    set for it only, waits for it, and returns its exit code. Internal; tests mock it.

    .DESCRIPTION
    A fresh process, so no code that was loaded before the update runs again (the old DbHubDemo stays in this process,
    which only waits). -NoProfile, as the deployment's own track processes start; the child inherits this process's
    environment (an execution policy set for the process included), its console, and its current folder, so a relative
    -ConfigPath means the same file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Runs the caller''s script again on its behalf; the caller decided.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $ScriptPath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $Marker
    )

    $pwsh = Get-DemoPwshPath
    if (-not $pwsh) {
        throw 'pwsh (PowerShell 7) was not found to start the script again.'
    }
    # Process.Start with nothing redirected: the child writes to this console itself, colors and prompts included, and
    # reads its keyboard; '& pwsh' in a function would capture its output as the function's. ArgumentList passes each
    # argument as it is, with no quoting to get wrong.
    $info = [System.Diagnostics.ProcessStartInfo]::new($pwsh)
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $ScriptPath) + @($ArgumentList)) {
        $info.ArgumentList.Add([string]$argument)
    }
    $info.UseShellExecute = $false
    $info.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    $info.Environment[$script:SelfUpdateMarkerVariable] = $Marker
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $process.WaitForExit()
        return [int]$process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Get-DemoSelfUpdateWarning {
    <#
    .SYNOPSIS
    The Warning's reason and exact command for a checkout deploy.ps1 doesn't update (Get-DemoCheckoutState's state and
    why it stopped). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Case,

        [pscustomobject] $State = $null,

        [string] $Detail = '',

        [AllowEmptyString()]
        [string] $ConfigPath = '',

        [AllowEmptyString()]
        [string] $RepositoryRoot = ''
    )

    $behind = if ($State) { [int]$State.Behind } else { 0 }
    $lag = '{0} commit(s) behind GitHub''s main' -f $behind
    # The clone advice names the configuration this run used (2026-11-09 live finding: it always said
    # config/demo.config.json): one inside this folder is copied to the same place in the new one; one outside it stays.
    $root = if ($RepositoryRoot) { [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/') } else { '' }
    $relative = ''
    if ($ConfigPath -and $root -and $ConfigPath.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $ConfigPath.Substring($root.Length + 1) -replace '\\', '/'
    }
    $clone = if (-not $ConfigPath -or $relative -eq 'config/demo.config.json') {
        'git clone {0}, then copy config/demo.config.json, this run''s configuration, to config/ in the new folder and run ./scripts/deploy.ps1 there' -f $script:SelfUpdateCloneUrl
    }
    elseif ($relative) {
        'git clone {0}, then copy {1}, this run''s configuration, to the same place in the new folder and run ./scripts/deploy.ps1 -ConfigPath "./{1}" there' -f $script:SelfUpdateCloneUrl, $relative
    }
    else {
        'git clone {0}, then run ./scripts/deploy.ps1 -ConfigPath "{1}" in the new folder (this run''s configuration stays where it is)' -f $script:SelfUpdateCloneUrl, $ConfigPath
    }
    switch ($Case) {
        'NoGit' {
            return [pscustomobject]@{ Reason = 'Git isn''t installed (it isn''t on PATH or where Git is usually installed), and this folder isn''t a git checkout, so deploy.ps1 can''t tell whether this copy is behind GitHub''s main'; Command = ('Install Git (https://git-scm.com/downloads), then {0}' -f $clone) }
        }
        'NoGitCheckout' {
            $where = if ($root) { $root } else { 'this folder' }
            return [pscustomobject]@{ Reason = 'Git isn''t installed (it isn''t on PATH or where Git is usually installed), so deploy.ps1 can''t tell whether this checkout is behind GitHub''s main or update it'; Command = ('Install Git (https://git-scm.com/downloads), then run git pull --ff-only in {0}' -f $where) }
        }
        'NotCheckout' {
            return [pscustomobject]@{ Reason = 'this folder isn''t a git checkout (a downloaded zip, for example), so deploy.ps1 can''t tell whether it''s behind GitHub''s main or update it'; Command = $clone }
        }
        'FetchFailed' {
            return [pscustomobject]@{ Reason = ('GitHub couldn''t be reached to check for newer code ({0})' -f $Detail); Command = 'git pull --ff-only (when GitHub can be reached), then ./scripts/deploy.ps1' }
        }
        'Detached' {
            return [pscustomobject]@{ Reason = ('this checkout is on a detached HEAD, {0}' -f $lag); Command = 'git switch main; git pull --ff-only' }
        }
        'OtherBranch' {
            return [pscustomobject]@{ Reason = ('this checkout is on branch {0}, not main, and {1}' -f $State.Branch, $lag); Command = 'git switch main; git pull --ff-only' }
        }
        'Upstream' {
            $tracks = if ($State.Upstream) { 'tracks {0}' -f $State.Upstream } else { 'tracks no remote branch' }
            return [pscustomobject]@{ Reason = ('its main {0}, not origin/main, and it''s {1}' -f $tracks, $lag); Command = 'git branch --set-upstream-to=origin/main main; git pull --ff-only' }
        }
        'Diverged' {
            return [pscustomobject]@{ Reason = ('its main has {0} local commit(s) that GitHub''s main doesn''t, and it''s {1}' -f $State.Ahead, $lag); Command = 'git merge origin/main (keeps your local commits), or git reset --hard origin/main (discards them)' }
        }
        'Dirty' {
            $files = @($State.Dirty | Select-Object -First 5)
            $more = if (@($State.Dirty).Count -gt $files.Count) { ', and {0} more' -f (@($State.Dirty).Count - $files.Count) } else { '' }
            return [pscustomobject]@{ Reason = ('it''s {0}, and tracked files have local changes ({1}{2})' -f $lag, ($files -join ', '), $more); Command = 'git stash; git pull --ff-only; git stash pop (or commit your changes first)' }
        }
        'WhatIf' {
            return [pscustomobject]@{ Reason = ('it''s {0}, and -WhatIf changes nothing, this checkout included' -f $lag); Command = './scripts/deploy.ps1 without -WhatIf updates it first; or git pull --ff-only' }
        }
        'MergeFailed' {
            return [pscustomobject]@{ Reason = ('it''s {0}, and the fast-forward failed ({1})' -f $lag, $Detail); Command = 'git status, then git pull --ff-only' }
        }
    }
    throw ('Unknown self-update case: {0}' -f $Case)
}
