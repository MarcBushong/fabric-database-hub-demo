BeforeAll {
    # deploy.ps1's self-update (2026-11-09, the owner's choice: "Update itself: fast-forward a clean checkout to the latest
    # main, then run"). The first Describe blocks mock git and the restart; the last one runs real git against a bare
    # repository in TestDrive and a real restart in a fresh pwsh, offline.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $script:modulePath = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $script:modulePath -Force
    $script:selfUpdateVariables = @('DBHUB_SELF_UPDATED', 'DBHUB_NO_SELF_UPDATE')
    $script:ciVariables = @('GITHUB_ACTIONS', 'CI', 'TF_BUILD')
    $script:savedEnvironment = @{}
    foreach ($name in $script:selfUpdateVariables + $script:ciVariables) {
        $script:savedEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name)
    }

    $script:old = 'a' * 40
    $script:new = 'b' * 40

    # What the mocked git answers. Each test changes what it needs, then calls Invoke-TestSelfUpdate.
    function Reset-TestGit {
        $script:git = @{
            Path       = 'git'
            OnPath     = $true
            Source     = 'PATH'
            Prefix     = ''
            Branch     = 'main'
            Upstream   = 'origin/main'
            Head       = $script:old
            Remote     = $script:new
            FetchExit  = 0
            FetchError = ''
            TimedOut   = $false
            Ahead      = 0
            Behind     = 3
            Dirty      = ''
            MergeExit  = 0
            MergeError = ''
        }
        $script:gitCalls = [System.Collections.Generic.List[string]]::new()
        $script:gitPaths = [System.Collections.Generic.List[string]]::new()
        $script:restarts = [System.Collections.Generic.List[object]]::new()
        $script:logs = [System.Collections.Generic.List[string]]::new()
    }

    function Invoke-TestSelfUpdate {
        param([System.Collections.IDictionary] $Bound = [ordered]@{}, [switch] $NoSelfUpdate, [switch] $Nested, [switch] $WhatIfRun, [string] $ConfigPath = '')
        Invoke-DemoSelfUpdate -ScriptPath (Join-Path -Path $script:root -ChildPath 'scripts/deploy.ps1') -BoundParameters $Bound -RepositoryRoot $script:root -NoSelfUpdate:$NoSelfUpdate -Nested:$Nested -WhatIf:$WhatIfRun -ConfigPath $ConfigPath
    }
}

AfterAll {
    foreach ($name in $script:savedEnvironment.Keys) {
        [System.Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
    }
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Invoke-DemoSelfUpdate: a clean main behind GitHub''s main updates and runs again; anything else warns and goes on (DEPLOY.SELFUPDATE, 2026-11-09)' {
    BeforeEach {
        foreach ($name in $script:selfUpdateVariables) {
            [System.Environment]::SetEnvironmentVariable($name, $null)
        }
        # A folder of its own for each test: TestDrive keeps what one test creates (a .git) for the next.
        $script:root = Join-Path -Path $TestDrive -ChildPath ('checkout-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:root -Force
        Reset-TestGit
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRunEnvironment -MockWith { [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $true; Codespaces = $false; Windows = $true } }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logs.Add(('{0}: {1}' -f $Level, $Message)) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoGitLocation -MockWith { [pscustomobject]@{ Path = $script:git.Path; OnPath = $script:git.OnPath; Source = $script:git.Source } }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoSelfRestart -MockWith {
            $script:restarts.Add([pscustomobject]@{ ScriptPath = $ScriptPath; ArgumentList = @($ArgumentList); Marker = $Marker })
            return 9
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGit -MockWith {
            $line = $ArgumentList -join ' '
            $script:gitCalls.Add($line)
            $script:gitPaths.Add([string]$GitPath)
            $answer = { param([int] $Code, [string] $Out = '', [string] $Err = '', [bool] $Late = $false) [pscustomobject]@{ ExitCode = $Code; StdOut = $Out; StdErr = $Err; TimedOut = $Late } }
            $g = $script:git
            switch -Regex ($line) {
                '^rev-parse --show-prefix$' { if ($null -ne $g.Prefix) { return (& $answer 0 $g.Prefix) } else { return (& $answer 128 '' 'fatal: not a git repository (or any of the parent directories): .git') } }
                '^symbolic-ref ' { if ($g.Branch) { return (& $answer 0 $g.Branch) } else { return (& $answer 1) } }
                '^rev-parse --abbrev-ref ' { if ($g.Upstream) { return (& $answer 0 $g.Upstream) } else { return (& $answer 128 '' 'fatal: no upstream configured') } }
                '^rev-parse HEAD$' { return (& $answer 0 $g.Head) }
                '^fetch ' { return (& $answer $(if ($g.TimedOut) { -1 } else { $g.FetchExit }) '' $g.FetchError $g.TimedOut) }
                '^rev-parse --verify ' { return (& $answer 0 $g.Remote) }
                '^rev-list ' { return (& $answer 0 ("{0}`t{1}" -f $g.Ahead, $g.Behind)) }
                '^status ' { return (& $answer 0 $g.Dirty) }
                '^merge ' {
                    if ($g.MergeExit -eq 0) {
                        $g.Head = $g.Remote
                    }
                    return (& $answer $g.MergeExit '' $g.MergeError)
                }
            }
            throw ('Unexpected git call: {0}' -f $line)
        }
    }

    Context 'updates and runs again' {
        It 'fast-forwards a clean main that tracks origin/main to the fetched commit, says so in one line, and runs the script again with the same arguments' {
            $bound = [ordered]@{ ConfigPath = 'C:\demo configs\it''s "mine".json'; Resume = [switch]::new($true); WaitForT2 = [switch]::new($false); FromStage = ''; T1WaitMinutes = 12 }
            $outcome = Invoke-TestSelfUpdate -Bound $bound
            $outcome.Restarted | Should -BeTrue
            $outcome.ExitCode | Should -Be 9
            $outcome.Result | Should -BeNullOrEmpty
            $script:gitCalls | Should -Contain 'fetch --quiet --no-tags --no-recurse-submodules origin +refs/heads/main:refs/remotes/origin/main'
            $script:gitCalls | Should -Contain ('merge --ff-only --quiet {0}' -f $script:new)
            $script:restarts.Count | Should -Be 1
            $script:restarts[0].ScriptPath | Should -Be (Join-Path -Path $script:root -ChildPath 'scripts/deploy.ps1')
            $script:restarts[0].ArgumentList | Should -Be @('-ConfigPath', 'C:\demo configs\it''s "mine".json', '-Resume', '-WaitForT2:$false', '-FromStage', '', '-T1WaitMinutes', '12')
            $script:restarts[0].Marker | Should -Be 'aaaaaaa;bbbbbbb;3;'
            @($script:logs | Where-Object { $_ -like 'Info: Updated this copy from GitHub''s main: aaaaaaa to bbbbbbb, 3 new commit(s).*' }).Count | Should -Be 1
        }

        It 'passes -WhatIf:$false, -Verbose, and other common parameters on as they were bound' {
            $null = Invoke-TestSelfUpdate -Bound ([ordered]@{ Verbose = [switch]::new($true); ErrorAction = [System.Management.Automation.ActionPreference]::Stop })
            $script:restarts[0].ArgumentList | Should -Be @('-Verbose', '-ErrorAction', 'Stop')
        }

        It 'never goes on with the old code when the restart can''t start: an Error, and exit code 2' {
            Mock -ModuleName DbHubDemo -CommandName Start-DemoSelfRestart -MockWith { throw 'pwsh (PowerShell 7) was not found to start the script again.' }
            $outcome = Invoke-TestSelfUpdate
            $outcome.Restarted | Should -BeTrue
            $outcome.ExitCode | Should -Be 2
            @($script:logs | Where-Object { $_ -like 'Error: This copy was updated, but deploy.ps1 couldn''t start again*Run ./scripts/deploy.ps1 again*' }).Count | Should -Be 1
        }

        It 'the restarted process (DBHUB_SELF_UPDATED) never checks or restarts again, and says what was updated (Pass, the first note)' {
            [System.Environment]::SetEnvironmentVariable('DBHUB_SELF_UPDATED', 'aaaaaaa;bbbbbbb;3')
            $outcome = Invoke-TestSelfUpdate
            $outcome.Restarted | Should -BeFalse
            $outcome.Result.status | Should -Be 'Pass'
            $outcome.Result.checkId | Should -Be 'DEPLOY.SELFUPDATE'
            $outcome.Result.message | Should -Be 'This copy was updated from GitHub''s main before this run started: aaaaaaa to bbbbbbb, 3 new commit(s). It runs the new code.'
            $outcome.Note | Should -Be $outcome.Result.message
            $script:gitCalls.Count | Should -Be 0
            $script:restarts.Count | Should -Be 0
            [System.Environment]::GetEnvironmentVariable('DBHUB_SELF_UPDATED') | Should -BeNullOrEmpty
        }
    }

    Context 'nothing to update' {
        It 'a main with everything on GitHub''s main is a Pass, with no merge and no restart' {
            $script:git.Behind = 0
            $script:git.Head = $script:new
            $outcome = Invoke-TestSelfUpdate
            $outcome.Restarted | Should -BeFalse
            $outcome.Result.status | Should -Be 'Pass'
            $outcome.Result.message | Should -Be 'This copy has everything on GitHub''s main (bbbbbbb).'
            $outcome.Note | Should -BeNullOrEmpty
            @($script:gitCalls | Where-Object { $_ -like 'merge *' }).Count | Should -Be 0
        }

        It 'is a Pass too, saying so, on another branch, ahead, or with local changes, when it has everything on GitHub''s main' {
            $script:git.Behind = 0
            $script:git.Branch = 'feature'
            $script:git.Ahead = 2
            $script:git.Dirty = ' M README.md'
            $outcome = Invoke-TestSelfUpdate
            $outcome.Result.status | Should -Be 'Pass'
            $outcome.Result.message | Should -Be 'This copy has everything on GitHub''s main (bbbbbbb), on branch feature, with 2 local commit(s) on top, with local changes.'
            $script:restarts.Count | Should -Be 0
        }
    }

    Context 'warns, with the exact command, and goes on with the local code' {
        It '<Case>' -ForEach @(
            @{ Case = 'local changes in tracked files'; Set = { $script:git.Dirty = " M scripts/deploy.ps1`nM  docs/x.md" }; Reason = 'tracked files have local changes (scripts/deploy.ps1, docs/x.md)'; Command = 'git stash; git pull --ff-only; git stash pop' }
            @{ Case = 'another branch'; Set = { $script:git.Branch = 'feature' }; Reason = 'on branch feature, not main, and 3 commit(s) behind'; Command = 'git switch main; git pull --ff-only' }
            @{ Case = 'a detached HEAD'; Set = { $script:git.Branch = ''; $script:git.Upstream = '' }; Reason = 'on a detached HEAD, 3 commit(s) behind'; Command = 'git switch main; git pull --ff-only' }
            @{ Case = 'a main that tracks another branch'; Set = { $script:git.Upstream = 'upstream/main' }; Reason = 'its main tracks upstream/main, not origin/main'; Command = 'git branch --set-upstream-to=origin/main main; git pull --ff-only' }
            @{ Case = 'a main with no upstream'; Set = { $script:git.Upstream = '' }; Reason = 'its main tracks no remote branch, not origin/main'; Command = 'git branch --set-upstream-to=origin/main main' }
            @{ Case = 'diverged'; Set = { $script:git.Ahead = 2 }; Reason = 'has 2 local commit(s) that GitHub''s main doesn''t, and it''s 3 commit(s) behind'; Command = 'git merge origin/main' }
            @{ Case = 'a fetch that fails (offline)'; Set = { $script:git.FetchExit = 128; $script:git.FetchError = "fatal: unable to access 'https://github.com/x/y.git/': Could not resolve host: github.com" }; Reason = 'GitHub couldn''t be reached to check for newer code (fatal: unable to access'; Command = 'git pull --ff-only (when GitHub can be reached)' }
            @{ Case = 'a fetch that times out'; Set = { $script:git.TimedOut = $true }; Reason = 'git fetch didn''t finish within 20 seconds'; Command = 'git pull --ff-only' }
            @{ Case = 'Git missing'; Set = { $script:git.Path = '' }; Reason = 'Git isn''t installed'; Command = 'Install Git (https://git-scm.com/downloads), then git clone https://github.com/MarcBushong/fabric-database-hub-demo.git' }
            @{ Case = 'not a git checkout (a downloaded zip)'; Set = { $script:git.Prefix = $null }; Reason = 'this folder isn''t a git checkout'; Command = 'git clone https://github.com/MarcBushong/fabric-database-hub-demo.git, then copy config/demo.config.json' }
            @{ Case = 'a folder inside another checkout'; Set = { $script:git.Prefix = 'checkout/' }; Reason = 'this folder isn''t a git checkout'; Command = 'git clone' }
            @{ Case = 'a fast-forward that fails'; Set = { $script:git.MergeExit = 1; $script:git.MergeError = "error: Your local changes to the following files would be overwritten by merge:`n`tscripts/new.ps1" }; Reason = 'the fast-forward failed (error: Your local changes'; Command = 'git status, then git pull --ff-only' }
        ) {
            & $Set
            $outcome = Invoke-TestSelfUpdate -Bound ([ordered]@{ Resume = [switch]::new($true) })
            $outcome.Restarted | Should -BeFalse
            $outcome.Result.checkId | Should -Be 'DEPLOY.SELFUPDATE'
            $outcome.Result.status | Should -Be 'Warning'
            $outcome.Result.message | Should -BeLike ('This copy may be older than GitHub''s main: *{0}*. This run uses the code in this folder as it is.' -f [WildcardPattern]::Escape($Reason))
            $outcome.Result.remediation | Should -BeLike ('*{0}*' -f [WildcardPattern]::Escape($Command))
            $outcome.Note | Should -BeLike ('*To run the latest code: *{0}*' -f [WildcardPattern]::Escape($Command))
            @($script:logs | Where-Object { $_ -like 'Warning: This copy may be older than GitHub''s main*To run the latest code:*' }).Count | Should -Be 1
            $script:restarts.Count | Should -Be 0
            if ($Case -ne 'a fast-forward that fails') {
                @($script:gitCalls | Where-Object { $_ -like 'merge *' }).Count | Should -Be 0
            }
        }

        It 'changes nothing with -WhatIf: a Warning that a run without -WhatIf updates it' {
            $outcome = Invoke-TestSelfUpdate -WhatIfRun
            $outcome.Result.status | Should -Be 'Warning'
            $outcome.Result.remediation | Should -BeLike '*without -WhatIf updates it first*'
            @($script:gitCalls | Where-Object { $_ -like 'merge *' }).Count | Should -Be 0
            $script:restarts.Count | Should -Be 0
        }

        It 'a check that throws is a Warning, never a stop' {
            Mock -ModuleName DbHubDemo -CommandName Get-DemoCheckoutState -MockWith { throw 'git crashed' }
            $outcome = Invoke-TestSelfUpdate
            $outcome.Result.status | Should -Be 'Warning'
            $outcome.Result.message | Should -BeLike '*(git crashed)*'
        }
    }

    Context 'Git off PATH, and no Git (2026-11-09 live finding)' {
        BeforeEach {
            $script:desktopGit = 'C:\Users\demo\AppData\Local\GitHubDesktop\app-3.4.9\resources\app\git\cmd\git.exe'
            $script:git.Path = $script:desktopGit
            $script:git.OnPath = $false
            $script:git.Source = 'GitHub Desktop''s Git (app-3.4.9)'
        }

        It 'updates with a git found off PATH, runs every git call with it by full path, and names it in the update line and the restarted run''s note' {
            $outcome = Invoke-TestSelfUpdate
            $outcome.Restarted | Should -BeTrue
            $script:gitCalls | Should -Contain ('merge --ff-only --quiet {0}' -f $script:new)
            @($script:gitPaths | Sort-Object -Unique) | Should -Be @($script:desktopGit)
            $used = ' It used the git at {0} (GitHub Desktop''s Git (app-3.4.9)), which isn''t on PATH.' -f $script:desktopGit
            @($script:logs | Where-Object { $_ -like ('Info: Updated this copy from GitHub''s main: aaaaaaa to bbbbbbb, 3 new commit(s).{0} deploy.ps1 starts again*' -f [WildcardPattern]::Escape($used)) }).Count | Should -Be 1
            $script:restarts[0].Marker | Should -Be ('aaaaaaa;bbbbbbb;3;{0}' -f $used)

            [System.Environment]::SetEnvironmentVariable('DBHUB_SELF_UPDATED', $script:restarts[0].Marker)
            $restarted = Invoke-TestSelfUpdate
            $restarted.Result.status | Should -Be 'Pass'
            $restarted.Result.message | Should -Be ('This copy was updated from GitHub''s main before this run started: aaaaaaa to bbbbbbb, 3 new commit(s). It runs the new code.{0}' -f $used)
        }

        It 'names the git found off PATH in the Pass, and in a Warning''s evidence' {
            $script:git.Behind = 0
            $outcome = Invoke-TestSelfUpdate
            $outcome.Result.status | Should -Be 'Pass'
            $outcome.Result.message | Should -BeLike ('This copy has everything on GitHub''s main (bbbbbbb). It used the git at {0} (*), which isn''t on PATH.' -f [WildcardPattern]::Escape($script:desktopGit))
            $outcome.Result.evidence['git'] | Should -Be $script:desktopGit
            $outcome.Result.evidence['gitOnPath'] | Should -BeFalse

            $script:git.Behind = 3
            $script:git.Branch = 'feature'
            $warning = Invoke-TestSelfUpdate
            $warning.Result.status | Should -Be 'Warning'
            $warning.Result.evidence['git'] | Should -Be $script:desktopGit
        }

        It 'says nothing about git when it''s on PATH' {
            $script:git.Path = 'git'
            $script:git.OnPath = $true
            $script:git.Behind = 0
            (Invoke-TestSelfUpdate).Result.message | Should -Be 'This copy has everything on GitHub''s main (bbbbbbb).'
        }

        It 'no Git, but a checkout (.git here): install Git, then git pull --ff-only in this folder, not a fresh clone' {
            $script:git.Path = ''
            $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:root -ChildPath '.git') -Force
            $outcome = Invoke-TestSelfUpdate -ConfigPath (Join-Path -Path $script:root -ChildPath 'config/demo.config.json')
            $outcome.Result.status | Should -Be 'Warning'
            $outcome.Result.message | Should -BeLike '*Git isn''t installed (it isn''t on PATH or where Git is usually installed), so deploy.ps1 can''t tell whether this checkout is behind GitHub''s main or update it*'
            $outcome.Result.remediation | Should -Be ('Install Git (https://git-scm.com/downloads), then run git pull --ff-only in {0}' -f [System.IO.Path]::GetFullPath($script:root))
            $outcome.Result.remediation | Should -Not -BeLike '*git clone*'
            $script:gitCalls.Count | Should -Be 0
        }

        It 'a worktree''s .git file counts as a checkout too' {
            $script:git.Path = ''
            Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath '.git') -Value 'gitdir: C:/elsewhere/.git/worktrees/x' -Encoding utf8NoBOM
            (Invoke-TestSelfUpdate).Result.remediation | Should -BeLike '*then run git pull --ff-only in *'
        }

        It 'no Git and no .git (a downloaded zip): install Git, clone, and bring this run''s configuration' {
            $script:git.Path = ''
            $outcome = Invoke-TestSelfUpdate -ConfigPath (Join-Path -Path $script:root -ChildPath 'config/demo.config.json')
            $outcome.Result.message | Should -BeLike '*Git isn''t installed (it isn''t on PATH or where Git is usually installed), and this folder isn''t a git checkout*'
            $outcome.Result.remediation | Should -Be 'Install Git (https://git-scm.com/downloads), then git clone https://github.com/MarcBushong/fabric-database-hub-demo.git, then copy config/demo.config.json, this run''s configuration, to config/ in the new folder and run ./scripts/deploy.ps1 there'
        }
    }

    Context 'the advice to clone names this run''s configuration' {
        It '<Case>' -ForEach @(
            @{ Case = 'the default, config/demo.config.json'; Relative = 'config/demo.config.json'; Outside = $false; Expected = 'git clone https://github.com/MarcBushong/fabric-database-hub-demo.git, then copy config/demo.config.json, this run''s configuration, to config/ in the new folder and run ./scripts/deploy.ps1 there' }
            @{ Case = 'another file in this folder'; Relative = 'config/proof.local.json'; Outside = $false; Expected = 'git clone https://github.com/MarcBushong/fabric-database-hub-demo.git, then copy config/proof.local.json, this run''s configuration, to the same place in the new folder and run ./scripts/deploy.ps1 -ConfigPath "./config/proof.local.json" there' }
            @{ Case = 'a file outside this folder'; Relative = ''; Outside = $true; Expected = 'git clone https://github.com/MarcBushong/fabric-database-hub-demo.git, then run ./scripts/deploy.ps1 -ConfigPath "<config>" in the new folder (this run''s configuration stays where it is)' }
            @{ Case = 'no configuration path given'; Relative = ''; Outside = $false; Expected = 'git clone https://github.com/MarcBushong/fabric-database-hub-demo.git, then copy config/demo.config.json, this run''s configuration, to config/ in the new folder and run ./scripts/deploy.ps1 there' }
        ) {
            $config = if ($Relative) { [System.IO.Path]::GetFullPath((Join-Path -Path $script:root -ChildPath $Relative)) } elseif ($Outside) { [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'elsewhere/my demo.json')) } else { '' }
            $expected = $Expected.Replace('<config>', $config)
            $script:git.Prefix = $null
            (Invoke-TestSelfUpdate -ConfigPath $config).Result.remediation | Should -Be $expected
            $script:git.Path = ''
            (Invoke-TestSelfUpdate -ConfigPath $config).Result.remediation | Should -Be ('Install Git (https://git-scm.com/downloads), then {0}' -f $expected)
        }
    }
    Context 'opted out' {
        It '<Case>: Not selected, with no git call' -ForEach @(
            @{ Case = '-NoSelfUpdate'; Set = { }; Switch = $true; Words = '-NoSelfUpdate' }
            @{ Case = 'DBHUB_NO_SELF_UPDATE=1'; Set = { [System.Environment]::SetEnvironmentVariable('DBHUB_NO_SELF_UPDATE', '1') }; Switch = $false; Words = 'DBHUB_NO_SELF_UPDATE is set' }
            @{ Case = 'DBHUB_NO_SELF_UPDATE=true'; Set = { [System.Environment]::SetEnvironmentVariable('DBHUB_NO_SELF_UPDATE', 'true') }; Switch = $false; Words = 'DBHUB_NO_SELF_UPDATE is set' }
            @{ Case = 'CI (GITHUB_ACTIONS)'; Set = { Mock -ModuleName DbHubDemo -CommandName Get-DemoRunEnvironment -MockWith { [pscustomobject]@{ GitHubActions = $true; Ci = $true; Interactive = $false; Codespaces = $false; Windows = $false } } }; Switch = $false; Words = 'in CI the workflow checks out the commit it runs' }
        ) {
            & $Set
            $outcome = Invoke-TestSelfUpdate -NoSelfUpdate:$Switch
            $outcome.Restarted | Should -BeFalse
            $outcome.Result.status | Should -Be 'Not selected'
            $outcome.Result.message | Should -BeLike ('*{0}*' -f [WildcardPattern]::Escape($Words))
            $script:gitCalls.Count | Should -Be 0
        }

        It 'DBHUB_NO_SELF_UPDATE=0 doesn''t opt out' {
            [System.Environment]::SetEnvironmentVariable('DBHUB_NO_SELF_UPDATE', '0')
            (Invoke-TestSelfUpdate).Restarted | Should -BeTrue
        }

        It 'does nothing, and records nothing, when the repository''s own code runs deploy.ps1 (-Nested: a test, or another script)' {
            $outcome = Invoke-TestSelfUpdate -Nested
            $outcome.Restarted | Should -BeFalse
            $outcome.Result | Should -BeNullOrEmpty
            $outcome.Note | Should -BeNullOrEmpty
            $script:gitCalls.Count | Should -Be 0
        }
    }
}

Describe 'deploy.ps1 and its self-update' {
    It 'checks right after loading DbHubDemo, before the transcript, the configuration, and anything that calls Azure, and exits with the restarted run''s code' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/deploy.ps1') -Raw
        $check = $text.IndexOf('$selfUpdate = Invoke-DemoSelfUpdate -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters')
        $check | Should -BeGreaterThan $text.IndexOf('Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath ''modules/DbHubDemo/DbHubDemo.psd1'')')
        foreach ($later in '$ConfigPath = Resolve-DemoUserPath', '= Start-Transcript -LiteralPath', '$firstRun = Initialize-DemoFirstRun', '$config = Get-DemoConfig', '$run = Start-DemoDeploymentRun', 'Invoke-DemoDeployment @parameters') {
            $text.IndexOf($later) | Should -BeGreaterThan 0 -Because "deploy.ps1 has $later"
            $check | Should -BeLessThan $text.IndexOf($later) -Because "$later comes after the self-update"
        }
        $text | Should -Match '(?s)if \(\$selfUpdate\.Restarted\) \{\s*exit \(\[int\]\$selfUpdate\.ExitCode\)\s*\}'
        $text | Should -Match '-ConfigPath \(Resolve-DemoUserPath -Path \$ConfigPath\) -NoSelfUpdate:\$NoSelfUpdate -Nested:\$entryNested'
        $text | Should -Match '-Note @\(\$selfUpdate\.Note\)'
        $text | Should -Match '\[switch\] \$NoSelfUpdate'
    }

    It 'puts the self-update''s note first in the banner and on the status page' {
        InModuleScope DbHubDemo {
            $expect = Get-DemoDeploymentExpectation -Note @('This copy was updated from GitHub''s main before this run started.', 'Another note.')
            $expect.Lines[1] | Should -Be '- This copy was updated from GitHub''s main before this run started.'
            $expect.Text | Should -BeLike '* This copy was updated from GitHub''s main before this run started. Another note.'
        }
        $command = Get-Command -Name Start-DemoDeploymentRun
        $command.Parameters.ContainsKey('Note') | Should -BeTrue
        $source = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/Public/Start-DemoDeploymentRun.ps1') -Raw
        $source | Should -Match '-Note @\(@\(\$Note\) \+ @\('
    }
}

Describe 'Finding git when it isn''t on PATH (2026-11-09 live finding: GitHub Desktop''s git, never on PATH)' {
    BeforeAll {
        $script:lookupVariables = @('ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA')
        $script:savedLookup = @{}
        foreach ($name in $script:lookupVariables) {
            $script:savedLookup[$name] = [System.Environment]::GetEnvironmentVariable($name)
        }
    }

    AfterAll {
        foreach ($name in $script:lookupVariables) {
            [System.Environment]::SetEnvironmentVariable($name, $script:savedLookup[$name])
        }
    }

    BeforeEach {
        $script:fake = Join-Path -Path $TestDrive -ChildPath ('pc-' + [guid]::NewGuid().ToString('N'))
        foreach ($pair in @(@('ProgramFiles', 'Program Files'), @('ProgramFiles(x86)', 'Program Files (x86)'), @('LOCALAPPDATA', 'AppData\Local'))) {
            [System.Environment]::SetEnvironmentVariable($pair[0], (Join-Path -Path $script:fake -ChildPath $pair[1]))
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVsWhere -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
    }

    It 'on Windows, tries Git for Windows (all users, 32-bit, this user), then GitHub Desktop''s newest app-* first, then each Visual Studio that vswhere lists' {
        $desktop = Join-Path -Path $script:fake -ChildPath 'AppData\Local\GitHubDesktop'
        foreach ($app in 'app-3.4.9', 'app-3.10.1', 'app-preview') {
            $null = New-Item -ItemType Directory -Path (Join-Path -Path $desktop -ChildPath $app) -Force
        }
        $null = New-Item -ItemType File -Path (Join-Path -Path $desktop -ChildPath 'app-9.9.9.txt') -Force
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVsWhere -MockWith { 'C:\VS\2026\Enterprise', 'C:\VS\2026\Preview' }
        $candidates = @(InModuleScope DbHubDemo { Get-DemoGitCandidatePath -Windows $true })
        $vsGit = 'Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\Git\cmd\git.exe'
        $candidates.Path | Should -Be @(
            (Join-Path -Path $script:fake -ChildPath 'Program Files\Git\cmd\git.exe')
            (Join-Path -Path $script:fake -ChildPath 'Program Files (x86)\Git\cmd\git.exe')
            (Join-Path -Path $script:fake -ChildPath 'AppData\Local\Programs\Git\cmd\git.exe')
            (Join-Path -Path $desktop -ChildPath 'app-3.10.1\resources\app\git\cmd\git.exe')
            (Join-Path -Path $desktop -ChildPath 'app-3.4.9\resources\app\git\cmd\git.exe')
            (Join-Path -Path $desktop -ChildPath 'app-preview\resources\app\git\cmd\git.exe')
            (Join-Path -Path 'C:\VS\2026\Enterprise' -ChildPath $vsGit)
            (Join-Path -Path 'C:\VS\2026\Preview' -ChildPath $vsGit)
        )
        $candidates.Source | Should -Be @('Git for Windows', 'Git for Windows (32-bit)', 'Git for Windows, installed for this user', 'GitHub Desktop''s Git (app-3.10.1)', 'GitHub Desktop''s Git (app-3.4.9)', 'GitHub Desktop''s Git (app-preview)', 'Visual Studio''s Git', 'Visual Studio''s Git')
    }

    It 'on Windows without GitHub Desktop, Visual Studio, or %ProgramFiles(x86)%, tries the rest' {
        [System.Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $null)
        @(InModuleScope DbHubDemo { Get-DemoGitCandidatePath -Windows $true }).Path | Should -Be @(
            (Join-Path -Path $script:fake -ChildPath 'Program Files\Git\cmd\git.exe')
            (Join-Path -Path $script:fake -ChildPath 'AppData\Local\Programs\Git\cmd\git.exe')
        )
    }

    It 'on macOS and Linux, tries /usr/bin/git, /usr/local/bin/git, and /opt/homebrew/bin/git' {
        @(InModuleScope DbHubDemo { Get-DemoGitCandidatePath -Windows $false }).Path | Should -Be @('/usr/bin/git', '/usr/local/bin/git', '/opt/homebrew/bin/git')
    }

    It 'vswhere: nothing when it isn''t installed' {
        @(InModuleScope DbHubDemo { Invoke-DemoVsWhere }).Count | Should -Be 0
    }

    It 'uses the git on PATH first, and looks nowhere else' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoGitOnPath -MockWith { 'C:\tools\git.exe' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoGitCandidatePath -MockWith { throw 'not expected' }
        $location = InModuleScope DbHubDemo { Get-DemoGitLocation }
        $location.Path | Should -Be 'C:\tools\git.exe'
        $location.OnPath | Should -BeTrue
        $location.Source | Should -Be 'PATH'
    }

    It 'off PATH, uses the first candidate that is a file and runs git --version, by full path' {
        $missing = Join-Path -Path $script:fake -ChildPath 'missing\git.exe'
        $broken = Join-Path -Path $script:fake -ChildPath 'broken\git.exe'
        $good = Join-Path -Path $script:fake -ChildPath 'desktop\git.exe'
        $later = Join-Path -Path $script:fake -ChildPath 'vs\git.exe'
        foreach ($file in $broken, $good, $later) {
            $null = New-Item -ItemType File -Path $file -Force
        }
        $script:candidateList = @(
            [pscustomobject]@{ Path = $missing; Source = 'Git for Windows' }
            [pscustomobject]@{ Path = $broken; Source = 'Git for Windows, installed for this user' }
            [pscustomobject]@{ Path = $good; Source = 'GitHub Desktop''s Git (app-3.4.9)' }
            [pscustomobject]@{ Path = $later; Source = 'Visual Studio''s Git' }
        )
        $script:probed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoGitOnPath -MockWith { '' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoGitCandidatePath -MockWith { $script:candidateList }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoGitExecutable -MockWith { $script:probed.Add($Path); $Path -ne $script:candidateList[1].Path }
        $location = InModuleScope DbHubDemo { Get-DemoGitLocation }
        $location.Path | Should -Be $good
        $location.OnPath | Should -BeFalse
        $location.Source | Should -Be 'GitHub Desktop''s Git (app-3.4.9)'
        $script:probed | Should -Be @($broken, $good) -Because 'a missing file isn''t run, and the search stops at the first git that runs'
        InModuleScope DbHubDemo { Get-DemoGitPath } | Should -Be $good
    }

    It 'finds nothing when no candidate runs' {
        $file = Join-Path -Path $script:fake -ChildPath 'broken\git.exe'
        $null = New-Item -ItemType File -Path $file -Force
        $script:candidateList = @([pscustomobject]@{ Path = $file; Source = 'Git for Windows' })
        Mock -ModuleName DbHubDemo -CommandName Get-DemoGitOnPath -MockWith { '' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoGitCandidatePath -MockWith { $script:candidateList }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoGitExecutable -MockWith { $false }
        (InModuleScope DbHubDemo { Get-DemoGitLocation }).Path | Should -Be ''
    }

    It 'git --version decides whether a file is git: a real git is, another program and a missing file aren''t' {
        $realGit = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($realGit) {
            InModuleScope DbHubDemo -Parameters @{ Git = $realGit.Source } { Test-DemoGitExecutable -Path $Git } | Should -BeTrue
        }
        InModuleScope DbHubDemo -Parameters @{ Other = [System.Environment]::ProcessPath } { Test-DemoGitExecutable -Path $Other } | Should -BeFalse
        InModuleScope DbHubDemo -Parameters @{ Missing = (Join-Path -Path $script:fake -ChildPath 'none\git.exe') } { Test-DemoGitExecutable -Path $Missing } | Should -BeFalse
    }
}
BeforeDiscovery {
    $hasGit = [bool](Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue)
}

Describe 'Invoke-DemoSelfUpdate with real git and a real restart, offline' {
    BeforeAll {
        $script:gitExe = (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        $script:pwshExe = [System.Environment]::ProcessPath
        if ([System.IO.Path]::GetFileNameWithoutExtension($script:pwshExe) -ne 'pwsh') {
            $script:pwshExe = (Get-Command -Name 'pwsh' -CommandType Application | Select-Object -First 1).Source
        }

        function Invoke-TestGitCommand {
            param([string] $Directory, [Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
            $output = & $script:gitExe -C $Directory -c user.name=SelfUpdateTest -c user.email=self-update@example.invalid -c commit.gpgsign=false @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ('git {0} failed: {1}' -f ($Arguments -join ' '), ($output -join ' '))
            }
            return (@($output) -join "`n").Trim()
        }

        # A stand-in for deploy.ps1: the same call, the same restart rule, then it prints its own marker and what it got.
        function Get-TestEntryScript([string] $Marker) {
            @(
                '[CmdletBinding(SupportsShouldProcess)]'
                'param([string] $ConfigPath = ''default.json'', [switch] $Resume, [string] $FromStage = '''', [int] $T1WaitMinutes = 45, [switch] $NoSelfUpdate)'
                '$ErrorActionPreference = ''Stop'''
                ('Import-Module -Name ''{0}'' -Force' -f $script:modulePath.Replace("'", "''"))
                '$selfUpdate = Invoke-DemoSelfUpdate -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -RepositoryRoot (Split-Path -Path $PSScriptRoot -Parent) -NoSelfUpdate:$NoSelfUpdate -WhatIf:([bool]$WhatIfPreference)'
                'if ($selfUpdate.Restarted) { exit ([int]$selfUpdate.ExitCode) }'
                ('Write-Output ''MARKER={0}''' -f $Marker)
                'Write-Output (''STATUS='' + $(if ($selfUpdate.Result) { $selfUpdate.Result.status } else { ''none'' }))'
                'Write-Output (''MESSAGE='' + $(if ($selfUpdate.Result) { $selfUpdate.Result.message } else { '''' }))'
                'Write-Output (''CONFIG=['' + $ConfigPath + '']'')'
                'Write-Output (''RESUME='' + [bool]$Resume)'
                'Write-Output (''FROM=['' + $FromStage + '']'')'
                'Write-Output (''T1='' + $T1WaitMinutes)'
                'exit 7'
            ) -join "`n"
        }

        # Runs the entry script in a fresh pwsh, as a person would, with no CI or self-update variables.
        function Invoke-TestEntry {
            param([string] $Checkout, [string[]] $ArgumentList = @(), [hashtable] $Environment = @{})
            $saved = @{}
            foreach ($name in $script:selfUpdateVariables + $script:ciVariables + @($Environment.Keys)) {
                $saved[$name] = [System.Environment]::GetEnvironmentVariable($name)
                [System.Environment]::SetEnvironmentVariable($name, $null)
            }
            foreach ($name in $Environment.Keys) {
                [System.Environment]::SetEnvironmentVariable($name, $Environment[$name])
            }
            try {
                $output = & $script:pwshExe -NoLogo -NoProfile -File (Join-Path -Path $Checkout -ChildPath 'scripts/entry.ps1') @ArgumentList 2>&1
                $code = $LASTEXITCODE
            }
            finally {
                foreach ($name in $saved.Keys) {
                    [System.Environment]::SetEnvironmentVariable($name, $saved[$name])
                }
            }
            $lines = @($output | ForEach-Object { [string]$_ })
            $value = { param([string] $Key) ($lines | Where-Object { $_ -like ('{0}=*' -f $Key) } | Select-Object -Last 1) -replace ('^{0}=' -f $Key), '' }
            return [pscustomobject]@{
                ExitCode = $code
                Text     = $lines -join "`n"
                Marker   = & $value 'MARKER'
                Status   = & $value 'STATUS'
                Message  = & $value 'MESSAGE'
                Config   = & $value 'CONFIG'
                Resume   = & $value 'RESUME'
                From     = & $value 'FROM'
                T1       = & $value 'T1'
                Markers  = @($lines | Where-Object { $_ -like 'MARKER=*' }).Count
            }
        }

        if ($script:gitExe) {
            # GitHub's main as a bare repository with two commits: the first, which every checkout starts from, and the
            # second, with a new marker in the entry script.
            $script:base = Join-Path -Path $TestDrive -ChildPath 'self update'
            $script:origin = Join-Path -Path $script:base -ChildPath 'origin.git'
            $seed = Join-Path -Path $script:base -ChildPath 'seed'
            $null = New-Item -ItemType Directory -Path $script:base -Force
            $null = Invoke-TestGitCommand $script:base init --quiet --bare --initial-branch=main $script:origin
            $null = Invoke-TestGitCommand $script:base init --quiet --initial-branch=main $seed
            $null = New-Item -ItemType Directory -Path (Join-Path -Path $seed -ChildPath 'scripts') -Force
            Set-Content -LiteralPath (Join-Path -Path $seed -ChildPath 'scripts/entry.ps1') -Value (Get-TestEntryScript -Marker 'old') -Encoding utf8NoBOM -NoNewline
            Set-Content -LiteralPath (Join-Path -Path $seed -ChildPath 'README.txt') -Value 'demo' -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path -Path $seed -ChildPath '.gitignore') -Value "config/`nout/" -Encoding utf8NoBOM
            $null = Invoke-TestGitCommand $seed add --all
            $null = Invoke-TestGitCommand $seed commit --quiet -m 'first'
            $null = Invoke-TestGitCommand $seed remote add origin $script:origin
            $null = Invoke-TestGitCommand $seed push --quiet origin main
            $script:first = Invoke-TestGitCommand $seed rev-parse HEAD
            # The checkouts are cloned now, at the first commit; GitHub's main then moves on.
            $script:checkouts = @{}
            foreach ($name in 'clean', 'dirty', 'diverged', 'offline', 'optout', 'branch') {
                $path = Join-Path -Path $script:base -ChildPath ('checkout {0}' -f $name)
                $null = Invoke-TestGitCommand $script:base clone --quiet $script:origin $path
                $script:checkouts[$name] = $path
            }
            Set-Content -LiteralPath (Join-Path -Path $seed -ChildPath 'scripts/entry.ps1') -Value (Get-TestEntryScript -Marker 'new') -Encoding utf8NoBOM -NoNewline
            $null = Invoke-TestGitCommand $seed commit --quiet --all -m 'second'
            $null = Invoke-TestGitCommand $seed push --quiet origin main
            $script:second = Invoke-TestGitCommand $seed rev-parse HEAD
        }
    }

    It 'fast-forwards a clean main, and the restarted process runs the new code with the same arguments and exits with its code' -Skip:(-not $hasGit) {
        $checkout = $script:checkouts['clean']
        # ConfigPath by position, as deploy.ps1 takes it, with spaces and quotes; a switch; an int; a stage.
        $config = Join-Path -Path $script:base -ChildPath 'my configs/it''s "demo".json'
        $run = Invoke-TestEntry -Checkout $checkout -ArgumentList @($config, '-Resume', '-FromStage', 'T2', '-T1WaitMinutes', '12')
        $run.ExitCode | Should -Be 7 -Because $run.Text
        $run.Text | Should -BeLike ('*Updated this copy from GitHub''s main: {0} to {1}, 1 new commit(s).*' -f $script:first.Substring(0, 7), $script:second.Substring(0, 7))
        $run.Markers | Should -Be 1 -Because 'the old script stops at the restart'
        $run.Marker | Should -Be 'new'
        $run.Status | Should -Be 'Pass'
        $run.Message | Should -BeLike 'This copy was updated from GitHub''s main before this run started*'
        $run.Config | Should -Be ('[{0}]' -f $config)
        $run.Resume | Should -Be 'True'
        $run.From | Should -Be '[T2]'
        $run.T1 | Should -Be '12'
        Invoke-TestGitCommand $checkout rev-parse HEAD | Should -Be $script:second
        Invoke-TestGitCommand $checkout status --porcelain | Should -BeNullOrEmpty

        # The next run finds it current: no restart.
        $again = Invoke-TestEntry -Checkout $checkout
        $again.Marker | Should -Be 'new'
        $again.Status | Should -Be 'Pass'
        $again.Message | Should -BeLike 'This copy has everything on GitHub''s main*'
        $again.Text | Should -Not -BeLike '*Updated this copy*'
    }

    It 'only warns with local changes in a tracked file, and leaves the checkout and the changes as they are; Git-ignored files don''t count' -Skip:(-not $hasGit) {
        $checkout = $script:checkouts['dirty']
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $checkout -ChildPath 'config') -Force
        Set-Content -LiteralPath (Join-Path -Path $checkout -ChildPath 'config/demo.config.json') -Value '{}' -Encoding utf8NoBOM
        Add-Content -LiteralPath (Join-Path -Path $checkout -ChildPath 'README.txt') -Value 'local change'
        $run = Invoke-TestEntry -Checkout $checkout -ArgumentList @('-Resume')
        $run.ExitCode | Should -Be 7 -Because $run.Text
        $run.Marker | Should -Be 'old'
        $run.Status | Should -Be 'Warning'
        $run.Message | Should -BeLike '*tracked files have local changes (README.txt)*'
        $run.Text | Should -BeLike '*git stash; git pull --ff-only; git stash pop*'
        Invoke-TestGitCommand $checkout rev-parse HEAD | Should -Be $script:first
        Invoke-TestGitCommand $checkout status --porcelain --untracked-files=no | Should -Be 'M README.txt'

        # Only the ignored configuration: it updates.
        $null = Invoke-TestGitCommand $checkout checkout --quiet -- README.txt
        $clean = Invoke-TestEntry -Checkout $checkout
        $clean.Marker | Should -Be 'new' -Because $clean.Text
        Test-Path -LiteralPath (Join-Path -Path $checkout -ChildPath 'config/demo.config.json') | Should -BeTrue
    }

    It 'only warns on a diverged main, and keeps its local commit' -Skip:(-not $hasGit) {
        $checkout = $script:checkouts['diverged']
        Add-Content -LiteralPath (Join-Path -Path $checkout -ChildPath 'README.txt') -Value 'local commit'
        $null = Invoke-TestGitCommand $checkout commit --quiet --all -m 'local'
        $local = Invoke-TestGitCommand $checkout rev-parse HEAD
        $run = Invoke-TestEntry -Checkout $checkout
        $run.ExitCode | Should -Be 7 -Because $run.Text
        $run.Marker | Should -Be 'old'
        $run.Status | Should -Be 'Warning'
        $run.Message | Should -BeLike '*1 local commit(s) that GitHub''s main doesn''t, and it''s 1 commit(s) behind*'
        Invoke-TestGitCommand $checkout rev-parse HEAD | Should -Be $local
    }

    It 'only warns on another branch' -Skip:(-not $hasGit) {
        $checkout = $script:checkouts['branch']
        $null = Invoke-TestGitCommand $checkout switch --quiet -c feature
        $run = Invoke-TestEntry -Checkout $checkout
        $run.Marker | Should -Be 'old' -Because $run.Text
        $run.Status | Should -Be 'Warning'
        $run.Message | Should -BeLike '*on branch feature, not main, and 1 commit(s) behind*'
    }

    It 'only warns when origin can''t be reached, within the time limit' -Skip:(-not $hasGit) {
        $checkout = $script:checkouts['offline']
        $null = Invoke-TestGitCommand $checkout remote set-url origin (Join-Path -Path $script:base -ChildPath 'missing.git')
        $run = Invoke-TestEntry -Checkout $checkout
        $run.ExitCode | Should -Be 7 -Because $run.Text
        $run.Marker | Should -Be 'old'
        $run.Status | Should -Be 'Warning'
        $run.Message | Should -BeLike '*GitHub couldn''t be reached to check for newer code*'
        Invoke-TestGitCommand $checkout rev-parse HEAD | Should -Be $script:first
    }

    It 'checks nothing with DBHUB_NO_SELF_UPDATE=1' -Skip:(-not $hasGit) {
        $checkout = $script:checkouts['optout']
        $run = Invoke-TestEntry -Checkout $checkout -Environment @{ DBHUB_NO_SELF_UPDATE = '1' }
        $run.Marker | Should -Be 'old' -Because $run.Text
        $run.Status | Should -Be 'Not selected'
        Invoke-TestGitCommand $checkout rev-parse HEAD | Should -Be $script:first
        # No fetch either: origin/main is still the first commit.
        Invoke-TestGitCommand $checkout rev-parse refs/remotes/origin/main | Should -Be $script:first
    }
}
