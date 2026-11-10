function Invoke-DemoSelfUpdate {
    <#
    .SYNOPSIS
    deploy.ps1's first step (2026-11-09): when this checkout is a clean main that's behind GitHub's main, fast-forwards
    it and runs the script again, with the new code and the same parameters, in a fresh pwsh process; otherwise it says
    why it can't, with the exact command, and the run goes on with the code in this folder.

    .DESCRIPTION
    The owner's choice: "Update itself: fast-forward a clean checkout to the latest main, then run". deploy.ps1 runs the
    code in its own folder and never asked GitHub, so a tester's assistant that re-ran an older demo from a clone pulled
    before a fix merged hit the fixed problem again.

    It fetches origin's main (git fetch, 20 seconds at most, never a credential prompt), with the git on PATH or, when there's
    none, the first that runs from where Git is usually installed (Get-DemoGitLocation: Git for Windows, GitHub Desktop's,
    Visual Studio's; /usr/bin, /usr/local/bin, /opt/homebrew/bin), named in the result when it isn't on PATH. It updates
    only when all of these hold: Git is installed, this folder is a git checkout, the branch is main and tracks origin/main, no tracked
    file is modified or staged (the Git-ignored config/ and out/ files don't count), and HEAD is an ancestor of
    origin/main with commits to take. Then 'git merge --ff-only' to the fetched commit, one line that says from which
    commit to which and how many came from GitHub, and the script runs again: the same arguments
    (ConvertTo-DemoScriptArgument), the same console, the same folder, and its exit code is this run's. The restarted
    process carries DBHUB_SELF_UPDATED, so it never updates or restarts again, and it shows the update as the first note
    in the banner and on the status page (DEPLOY.SELFUPDATE Pass).

    Otherwise DEPLOY.SELFUPDATE is a Warning with the reason and the command, and the run goes on with the local code:
    local changes, another branch or a detached HEAD, a main that tracks another branch, diverged, -WhatIf, a fetch that
    fails or times out (offline), Git missing, or a folder that isn't a checkout (a downloaded zip). A checkout that has
    everything on GitHub's main is a Pass, even on another branch, with local changes, or with local commits on top. A
    check that fails never blocks the run.

    Not selected, with no git call: -NoSelfUpdate, DBHUB_NO_SELF_UPDATE set (1, true), and CI (GITHUB_ACTIONS, CI, or
    TF_BUILD), where the workflow checks out the commit it runs. Nothing at all (no result) with -Nested, when the
    repository's own code runs deploy.ps1 (a test, or another script).

    .PARAMETER ScriptPath
    The script to run again after the update ($PSCommandPath).

    .PARAMETER BoundParameters
    The script's $PSBoundParameters, passed on to the restarted script as they are.

    .PARAMETER RepositoryRoot
    The checkout (default: this module's repository).

    .PARAMETER NoSelfUpdate
    Don't check or update (Not selected).

    .PARAMETER Nested
    The repository's own code runs the script: no check and no result.

    .PARAMETER FetchTimeoutSeconds
    How long the fetch of origin's main may take (default 20).

    .PARAMETER ConfigPath
    The configuration file this run uses (absolute), which the advice to clone again names (2026-11-09).

    .EXAMPLE
    $selfUpdate = Invoke-DemoSelfUpdate -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
    if ($selfUpdate.Restarted) { exit $selfUpdate.ExitCode }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ScriptPath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary] $BoundParameters,

        [string] $RepositoryRoot = $script:RepoRoot,

        [switch] $NoSelfUpdate,

        [switch] $Nested,

        [ValidateRange(1, 300)]
        [int] $FetchTimeoutSeconds = 20,

        [AllowEmptyString()]
        [string] $ConfigPath = ''
    )

    # The advice to clone again names this run's configuration (2026-11-09).
    $adviceConfig = $ConfigPath
    $doc = 'https://git-scm.com/docs/git-merge#Documentation/git-merge.txt---ff-only'
    $outcome = { param([object] $Result, [string] $Note = '', [bool] $Restarted = $false, [int] $ExitCode = 0)
        [pscustomobject]@{ Restarted = $Restarted; ExitCode = $ExitCode; Result = $Result; Note = $Note }
    }
    $result = { param([string] $Status, [string] $Message, [string] $Remediation = '', [System.Collections.IDictionary] $Evidence = [ordered]@{})
        New-DemoResult -CheckId 'DEPLOY.SELFUPDATE' -Area 'preflight' -Target 'repo' -Status $Status -Message $Message -Remediation $Remediation -Evidence $Evidence -DocUrl $doc
    }
    if ($Nested) {
        return (& $outcome $null)
    }

    # The restarted process: the parent updated the checkout. Never again in this run (the loop guard).
    $marker = [System.Environment]::GetEnvironmentVariable($script:SelfUpdateMarkerVariable)
    if ($marker) {
        [System.Environment]::SetEnvironmentVariable($script:SelfUpdateMarkerVariable, $null)
        $parts = @($marker -split ';')
        $from = if ($parts.Count -gt 0) { $parts[0] } else { '' }
        $to = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $count = if ($parts.Count -gt 2) { $parts[2] } else { '' }
        # The git it used, when it wasn't on PATH (Format-DemoGitUsedText; 2026-11-09).
        $used = if ($parts.Count -gt 3) { $parts[3..($parts.Count - 1)] -join ';' } else { '' }
        $text = 'This copy was updated from GitHub''s main before this run started: {0} to {1}, {2} new commit(s). It runs the new code.{3}' -f $from, $to, $count, $used
        return (& $outcome (& $result 'Pass' $text '' ([ordered]@{ from = $from; to = $to; commits = $count; restarted = $true })) $text)
    }

    $environment = Get-DemoRunEnvironment
    $optOut = [string][System.Environment]::GetEnvironmentVariable($script:SelfUpdateOptOutVariable)
    if ($NoSelfUpdate -or ($optOut -and $optOut -notin '0', 'false')) {
        $how = if ($NoSelfUpdate) { '-NoSelfUpdate' } else { '{0} is set' -f $script:SelfUpdateOptOutVariable }
        return (& $outcome (& $result 'Not selected' ('This copy wasn''t checked against GitHub''s main ({0}); the run uses the code in this folder.' -f $how)))
    }
    if ($environment.Ci) {
        return (& $outcome (& $result 'Not selected' 'This copy wasn''t checked against GitHub''s main: in CI the workflow checks out the commit it runs.'))
    }

    $warn = { param([string] $Case, [object] $State = $null, [string] $Detail = '')
        $words = Get-DemoSelfUpdateWarning -Case $Case -State $State -Detail $Detail -ConfigPath $adviceConfig -RepositoryRoot $RepositoryRoot
        $message = 'This copy may be older than GitHub''s main: {0}. This run uses the code in this folder as it is.' -f $words.Reason
        Write-DemoLog -Level Warning -Message ('{0} To run the latest code: {1}' -f $message, $words.Command)
        $evidence = [ordered]@{ case = $Case }
        if ($State) {
            $evidence['branch'] = [string]$State.Branch
            $evidence['head'] = [string]$State.Head
            $evidence['originMain'] = [string]$State.Remote
            $evidence['behind'] = [int]$State.Behind
            $evidence['ahead'] = [int]$State.Ahead
            $evidence['git'] = [string]$State.GitPath
            $evidence['gitOnPath'] = [bool]$State.GitOnPath
        }
        $note = '{0} To run the latest code: {1}.' -f $message, $words.Command
        return (& $outcome (& $result 'Warning' $message $words.Command $evidence) $note)
    }

    try {
        $state = Get-DemoCheckoutState -RepositoryRoot $RepositoryRoot -FetchTimeoutSeconds $FetchTimeoutSeconds
    }
    catch {
        return (& $warn 'FetchFailed' $null (Protect-DemoText -Text $_.Exception.Message))
    }
    if ($state.Problem) {
        return (& $warn $state.Problem $state $state.FetchError)
    }
    $short = { param([string] $Sha) if ($Sha.Length -gt 7) { $Sha.Substring(0, 7) } else { $Sha } }
    $used = Format-DemoGitUsedText -Path ([string]$state.GitPath) -OnPath ([bool]$state.GitOnPath) -Source ([string]$state.GitSource)
    if ($state.Behind -eq 0) {
        $extra = @(
            $(if (-not $state.Branch) { 'on a detached HEAD' } elseif ($state.Branch -ne 'main') { 'on branch {0}' -f $state.Branch })
            $(if ($state.Ahead -gt 0) { 'with {0} local commit(s) on top' -f $state.Ahead })
            $(if (@($state.Dirty).Count -gt 0) { 'with local changes' })
        ) | Where-Object { $_ }
        $text = 'This copy has everything on GitHub''s main ({0}){1}.{2}' -f (& $short $state.Remote), $(if ($extra) { ', ' + ($extra -join ', ') } else { '' }), $used
        return (& $outcome (& $result 'Pass' $text '' ([ordered]@{ branch = $state.Branch; head = $state.Head; originMain = $state.Remote; ahead = $state.Ahead; git = [string]$state.GitPath; gitOnPath = [bool]$state.GitOnPath })))
    }
    if (-not $state.Branch) {
        return (& $warn 'Detached' $state)
    }
    if ($state.Branch -ne 'main') {
        return (& $warn 'OtherBranch' $state)
    }
    if ($state.Upstream -ne 'origin/main') {
        return (& $warn 'Upstream' $state)
    }
    if ($state.Ahead -gt 0) {
        return (& $warn 'Diverged' $state)
    }
    if (@($state.Dirty).Count -gt 0) {
        return (& $warn 'Dirty' $state)
    }
    if (-not $PSCmdlet.ShouldProcess($state.Root, ('Fast-forward main from {0} to {1} ({2} commits from GitHub) and run the script again' -f (& $short $state.Head), (& $short $state.Remote), $state.Behind))) {
        return (& $warn 'WhatIf' $state)
    }
    $merge = Invoke-DemoGit -GitPath ([string]$state.GitPath) -ArgumentList @('merge', '--ff-only', '--quiet', $state.Remote) -WorkingDirectory $state.Root -TimeoutSeconds 120
    $head = (Invoke-DemoGit -GitPath ([string]$state.GitPath) -ArgumentList @('rev-parse', 'HEAD') -WorkingDirectory $state.Root).StdOut
    if ($merge.ExitCode -ne 0 -or $head -ne $state.Remote) {
        $detail = if ($merge.TimedOut) { 'it didn''t finish within 120 seconds' } elseif ($merge.StdErr) { ($merge.StdErr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim() } else { 'HEAD is {0}' -f (& $short $head) }
        if ($head -eq $state.Head) {
            return (& $warn 'MergeFailed' $state $detail)
        }
        # Moved, but not to origin's main: the code in this folder isn't the one this process loaded, so it runs again.
        Write-DemoLog -Level Warning -Message ('The fast-forward ended at {0}, not {1} ({2}); deploy.ps1 starts again with the code that is now in this folder.' -f (& $short $head), (& $short $state.Remote), $detail)
    }
    $from = & $short $state.Head
    $to = & $short $head
    Write-DemoLog -Level Info -Message ('Updated this copy from GitHub''s main: {0} to {1}, {2} new commit(s).{3} deploy.ps1 starts again with the new code and the same parameters.' -f $from, $to, $state.Behind, $used)
    $arguments = ConvertTo-DemoScriptArgument -BoundParameters $BoundParameters
    try {
        $exitCode = Start-DemoSelfRestart -ScriptPath $ScriptPath -ArgumentList $arguments -Marker ('{0};{1};{2};{3}' -f $from, $to, $state.Behind, $used)
    }
    catch {
        # The checkout is updated, but this process holds the old code: it must not go on with it.
        Write-DemoLog -Level Error -Message ('This copy was updated, but deploy.ps1 couldn''t start again ({0}). Run ./scripts/deploy.ps1 again: it runs the new code.' -f (Protect-DemoText -Text $_.Exception.Message))
        $exitCode = 2
    }
    return (& $outcome $null '' $true $exitCode)
}
