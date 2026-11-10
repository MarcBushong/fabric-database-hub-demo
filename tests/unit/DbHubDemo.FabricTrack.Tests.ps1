BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # Obviously fake IDs: every group repeats one digit.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['fabric']['workspaceId'] = '22222222-2222-2222-2222-222222222222'
        $config['fabric']['lakehouseId'] = '33333333-3333-3333-3333-333333333333'
        return $config
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Invoke-DemoFabricScriptStep' {
    BeforeEach {
        $config = New-TestConfig
        $script:folder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:folder -Force | Out-Null
    }

    It 'passes only the parameters the script declares and returns the records it wrote' {
        $path = Join-Path -Path $script:folder -ChildPath 'writes-records.ps1'
        Set-Content -LiteralPath $path -Value @'
param([string] $ConfigPath, [string] $OutputPath, [switch] $CheckModelData)
$record = [ordered]@{ checkId = 'FABRIC.SEMANTICMODEL.DATA'; status = $(if ($CheckModelData) { 'Pass' } else { 'Warning' }); message = ('config {0}' -f (Test-Path -LiteralPath $ConfigPath)) }
Set-Content -LiteralPath $OutputPath -Value ($record | ConvertTo-Json -Compress)
exit 0
'@
        $records = @(& (Get-Module -Name DbHubDemo) { param($c, $p) Invoke-DemoFabricScriptStep -Config $c -ScriptPath $p -CheckId 'DEPLOY.POWERBI' -Argument @{ CheckModelData = $true } } $config $path)
        $records.Count | Should -Be 1
        $records[0].checkId | Should -Be 'FABRIC.SEMANTICMODEL.DATA'
        $records[0].status | Should -Be 'Pass'
        $records[0].message | Should -Be 'config True'
    }

    It 'runs the script outside the module''s session state, so module functions keep their own script scope' {
        # Live, 2026-10-22: run with the call operator from module code, configure-fabric.ps1's Get-DemoConfig
        # couldn't read $script:RepoRoot, and deploy.ps1's Fabric track stopped at once.
        $path = Join-Path -Path $script:folder -ChildPath 'reads-config.ps1'
        Set-Content -LiteralPath $path -Value @'
param([string] $ConfigPath, [string] $OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$loaded = Get-DemoConfig -Path $ConfigPath
$record = [ordered]@{ checkId = 'FABRIC.TEST.SCOPE'; status = 'Pass'; message = [string]$loaded['location'] }
Set-Content -LiteralPath $OutputPath -Value ($record | ConvertTo-Json -Compress)
'@
        $example = Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json'
        $records = @(& (Get-Module -Name DbHubDemo) { param($c, $p, $e) Invoke-DemoFabricScriptStep -Config $c -ConfigPath $e -ScriptPath $p -CheckId 'DEPLOY.POWERBI' } $config $path $example)
        $records.Count | Should -Be 1
        $records[0].status | Should -Be 'Pass' -Because ([string]$records[0].message)
        $records[0].message | Should -Be 'westus3'
        (& (Get-Module -Name DbHubDemo) { $script:RepoRoot }) | Should -Be $repoRoot
    }

    It 'reports a script that throws, or writes nothing, as a Fail' {
        $throws = Join-Path -Path $script:folder -ChildPath 'throws.ps1'
        Set-Content -LiteralPath $throws -Value "param([string] `$ConfigPath, [string] `$OutputPath)`nthrow 'the capacity is paused'"
        $silent = Join-Path -Path $script:folder -ChildPath 'silent.ps1'
        Set-Content -LiteralPath $silent -Value 'param([string] $ConfigPath)'
        $first = @(& (Get-Module -Name DbHubDemo) { param($c, $p) Invoke-DemoFabricScriptStep -Config $c -ScriptPath $p -CheckId 'DEPLOY.FABRIC.APP' } $config $throws)
        $first[0].status | Should -Be 'Fail'
        $first[0].message | Should -Match 'the capacity is paused'
        $second = @(& (Get-Module -Name DbHubDemo) { param($c, $p) Invoke-DemoFabricScriptStep -Config $c -ScriptPath $p -CheckId 'DEPLOY.FABRIC.APP' } $config $silent)
        $second[0].status | Should -Be 'Fail'
        $second[0].message | Should -Match 'wrote no results'
    }
}

Describe 'Invoke-DemoPowerBIStage and Invoke-DemoFabricAppStage' {
    BeforeEach {
        $config = New-TestConfig
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricScriptStep -MockWith {
            $script:stepScript = Split-Path -Path $ScriptPath -Leaf
            # The app step passes no -Argument, which strict mode can't read as a variable.
            $script:stepArgument = Get-Variable -Name 'Argument' -ValueOnly -ErrorAction SilentlyContinue
            New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.DATA' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'ok'
        }
    }

    It 'runs configure-powerbi.ps1, with -CheckModelData when asked' {
        $records = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoPowerBIStage -Config $c -CheckModelData } $config)
        $records[0].checkId | Should -Be 'FABRIC.SEMANTICMODEL.DATA'
        $script:stepScript | Should -Be 'configure-powerbi.ps1'
        $script:stepArgument['CheckModelData'] | Should -BeTrue
    }

    It 'calls configure-fabric-app.ps1 only when it exists (Phase 19b), and is Not selected otherwise' {
        $exists = Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/configure-fabric-app.ps1')
        $records = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoFabricAppStage -Config $c } $config)
        if ($exists) {
            $script:stepScript | Should -Be 'configure-fabric-app.ps1'
        }
        else {
            $records[0].checkId | Should -Be 'DEPLOY.FABRIC.APP'
            $records[0].status | Should -Be 'Not selected'
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricScriptStep -Times 0 -Exactly
        }
    }

    It 'passes the workspace the Fabric step resolved, and never reports the Insights app as a Fail of the run, while its own row reads Fail (Phase 28 live finding; 2026-11-05)' {
        # Live: the app's own lookup of the workspace, right after the Fabric step created it, failed; the app was
        # skipped with a Fail, and nothing said why.
        $workspaceId = '44444444-4444-4444-4444-444444444444'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricScriptStep -MockWith {
            $script:stepArgument = Get-Variable -Name 'Argument' -ValueOnly -ErrorAction SilentlyContinue
            # As configure-fabric-app.ps1 writes them: JSON records.
            @(
                [ordered]@{ checkId = 'FABRIC.APP.SOURCE'; status = 'Pass'; message = 'fabric/app is ready.'; remediation = ''; evidence = $null }
                [ordered]@{ checkId = 'FABRIC.RESOLVE.WORKSPACE'; status = 'Fail'; message = 'Your Fabric workspaces couldn''t be listed: HTTP 429: Too many requests.'; remediation = 'Check your Fabric access (sign in again with ''az login --tenant <tenantId>'' if the session expired), then run the script again.'; evidence = [ordered]@{ statusCode = 429 } }
                [ordered]@{ checkId = 'FABRIC.APP.DEPLOY'; status = 'Not selected'; message = 'The Fabric workspace isn''t resolved, so nothing was deployed.'; remediation = ''; evidence = $null }
            ) | ForEach-Object { $_ | ConvertTo-Json -Compress | ConvertFrom-Json }
        }
        $records = @(& (Get-Module -Name DbHubDemo) { param($c, $w) Invoke-DemoFabricAppStage -Config $c -WorkspaceId $w } $config $workspaceId)
        $script:stepArgument['WorkspaceId'] | Should -Be $workspaceId
        @($records | Where-Object { $_.status -eq 'Fail' }).Count | Should -Be 0
        $listed = $records | Where-Object { $_.checkId -eq 'FABRIC.RESOLVE.WORKSPACE' }
        $listed.status | Should -Be 'Manual action required'
        $listed.evidence.reportedStatus | Should -Be 'Fail'
        $listed.evidence.statusCode | Should -Be 429
        $listed.message | Should -Match '^Insights app: Your Fabric workspaces couldn''t be listed'
        # In deploy.ps1 the app is always selected, so a deploy that didn't happen is something to act on, never a choice.
        $deploy = $records | Where-Object { $_.checkId -eq 'FABRIC.APP.DEPLOY' }
        $deploy.status | Should -Be 'Manual action required'
        $deploy.evidence.reportedStatus | Should -Be 'Not selected'
        $deploy.remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
        foreach ($record in $records) {
            $record.evidence.nonBlocking | Should -Be 'insightsApp' -Because $record.checkId
            (& (Get-Module -Name DbHubDemo) { param($r) Test-DemoNonBlockingResult -Result $r } $record) | Should -BeTrue -Because ('{0} never blocks DONE' -f $record.checkId)
        }
        $summary = & (Get-Module -Name DbHubDemo) { param($r) Get-DemoInsightsAppSummary -Result $r } $records
        $summary.State | Should -Be 'Failed'
        $summary.Status | Should -Be 'Fail'
        $summary.Failed | Should -BeTrue
        $summary.Reason | Should -Match ([regex]::Escape('It wasn''t created: FABRIC.RESOLVE.WORKSPACE: Your Fabric workspaces couldn''t be listed: HTTP 429'))
        $summary.HowTo | Should -Match '^To add it: Check your Fabric access'
        $summary.HowTo | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
        $summary.StepMessage | Should -Not -Match '(?i)optional'

        # Without a resolved workspace, the script looks it up itself, as before.
        $null = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoFabricAppStage -Config $c -WorkspaceId '' } $config
        $script:stepArgument.Contains('WorkspaceId') | Should -BeFalse
    }

    It 'asks for configure-fabric-app.ps1, never a rerun of the whole deployment, when a network error stopped the app''s step (2026-11-05)' {
        # Invoke-DemoFabricScriptStep's own record for a network error says to run deploy.ps1 again, which is right for the
        # steps DONE needs, but not for the app, which DONE never waits for.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricScriptStep -MockWith {
            New-DemoResult -CheckId 'DEPLOY.FABRIC.APP' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'configure-fabric-app.ps1 stopped: A network error reached api.fabric.microsoft.com on each of 4 attempts: The SSL connection could not be established.' -Evidence ([ordered]@{ networkError = $true }) -Remediation 'Run ./scripts/deploy.ps1 again: it resumes where it stopped. A network error stopped it (requests that are safe to repeat were retried).'
        }
        $records = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoFabricAppStage -Config $c } $config)
        $records.Count | Should -Be 1
        $records[0].status | Should -Be 'Manual action required'
        $records[0].evidence.networkError | Should -BeTrue
        $records[0].evidence.reportedStatus | Should -Be 'Fail'
        $records[0].remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
        $records[0].remediation | Should -Not -Match 'deploy\.ps1'
        (& (Get-Module -Name DbHubDemo) { param($r) Test-DemoNonBlockingResult -Result $r } $records[0]) | Should -BeTrue
        $summary = & (Get-Module -Name DbHubDemo) { param($r) Get-DemoInsightsAppSummary -Result $r } $records
        $summary.State | Should -Be 'Failed'
        $summary.Reason | Should -Match 'A network error reached api\.fabric\.microsoft\.com'
        $summary.HowTo | Should -Not -Match 'deploy\.ps1'
    }

    It 'reads the app''s state from its records: Done, Done with the browser check to confirm, Failed while deployed, or Skipped only without the script (2026-11-05)' {
        $module = Get-Module -Name DbHubDemo
        $record = {
            param([string] $CheckId, [string] $Status, [string] $Message = 'x', [string] $Remediation = '')
            & $module { param($i, $s, $m, $f) ConvertTo-DemoInsightsAppRecord -Record (New-DemoResult -CheckId $i -Area 'fabric' -Target 'fabric' -Status $s -Message $m -Remediation $f) } $CheckId $Status $Message $Remediation
        }
        $summary = { param([object[]] $Records) & $module { param($r) Get-DemoInsightsAppSummary -Result $r } $Records }

        $checked = & $summary @((& $record 'FABRIC.APP.DEPLOY' 'Pass'), (& $record 'FABRIC.APP.QUERIES' 'Pass'))
        $checked.State | Should -Be 'Done'
        $checked.Failed | Should -BeFalse
        $checked.Deployed | Should -BeTrue

        $browser = & $summary @((& $record 'FABRIC.APP.DEPLOY' 'Pass'), (& $record 'FABRIC.APP.BROWSER' 'Manual action required' 'Confirm it in the browser.' 'Open its item.'))
        $browser.State | Should -Be 'Done'
        $browser.ConfirmOnly | Should -BeTrue
        $browser.Failed | Should -BeFalse

        $broken = & $summary @((& $record 'FABRIC.APP.DEPLOY' 'Pass'), (& $record 'FABRIC.APP.QUERIES' 'Fail' 'Every query failed: HTTP 401.' 'Turn on Dataset Execute Queries REST API.'))
        $broken.State | Should -Be 'Failed'
        $broken.Status | Should -Be 'Fail'
        $broken.Reason | Should -Be 'It''s deployed, but FABRIC.APP.QUERIES: Every query failed: HTTP 401.'
        $broken.HowTo | Should -Match '^To fix it: Turn on Dataset Execute Queries REST API'

        $skipped = & $summary @((New-DemoResult -CheckId 'DEPLOY.FABRIC.APP' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'scripts/configure-fabric-app.ps1 (Phase 19b) isn''t in this checkout, so the Insights app wasn''t deployed.'))
        $skipped.State | Should -Be 'Skipped'
        $skipped.Failed | Should -BeFalse

        (& $summary @((New-DemoResult -CheckId 'FABRIC.ITEMS.REQUIRED' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'The workspace has every item.'))) | Should -BeNullOrEmpty
    }

    It 'finds the workspace configure-fabric.ps1 resolved: found, created, or the override, and not a failed one' {
        $resolved = {
            param([string] $Status, [string] $Id)
            New-DemoResult -CheckId 'FABRIC.RESOLVE.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status $Status -Message 'x' -Evidence ([ordered]@{ workspaceId = $Id })
        }
        $module = Get-Module -Name DbHubDemo
        & $module { param($r) Get-DemoResolvedWorkspaceId -Result $r } @((& $resolved 'Pass' '44444444-4444-4444-4444-44444444ABCD')) | Should -Be '44444444-4444-4444-4444-44444444abcd'
        & $module { param($r) Get-DemoResolvedWorkspaceId -Result $r } @((& $resolved 'Not selected' '55555555-5555-5555-5555-555555555555')) | Should -Be '55555555-5555-5555-5555-555555555555'
        & $module { param($r) Get-DemoResolvedWorkspaceId -Result $r } @((& $resolved 'Fail' '66666666-6666-6666-6666-666666666666')) | Should -Be ''
        & $module { param($r) Get-DemoResolvedWorkspaceId -Result $r } @((& $resolved 'Pass' '00000000-0000-0000-0000-000000000000')) | Should -Be ''
        & $module { param($r) Get-DemoResolvedWorkspaceId -Result $r } @() | Should -Be ''
    }
}

Describe 'Invoke-DemoInsightsAppStep (2026-11-05)' {
    BeforeEach {
        $config = New-TestConfig
        $script:warned = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { if ($PesterBoundParameters['Level'] -eq 'Warning') { $script:warned.Add([string]$PesterBoundParameters['Message']) } }
        $script:progress = Join-Path -Path $TestDrive -ChildPath ('progress-' + [guid]::NewGuid().ToString('N') + '.json')
        & (Get-Module -Name DbHubDemo) { param($p) Initialize-DemoProgress -Path $p -Model (New-DemoProgressModel -Catalog (Get-DemoProgressCatalog)) -Confirm:$false } $script:progress
        $script:readRow = {
            $model = Get-Content -LiteralPath $script:progress -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            @(foreach ($track in @($model['tracks'])) { foreach ($item in @($track['steps'])) { if ([string]$item['id'] -eq 'Fabric.App') { $item } } })[0]
        }
        $script:invoke = { & (Get-Module -Name DbHubDemo) { param($c, $p) Invoke-DemoInsightsAppStep -Config $c -ProgressPath $p } $config $script:progress }
    }

    It 'turns an exception into the app''s own record and a Failed row with the error, and never throws' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppStage -MockWith { throw [System.InvalidOperationException]::new('The stage folder is locked by another process.') }
        $records = @(& $script:invoke)
        $records.Count | Should -Be 1
        $records[0].checkId | Should -Be 'DEPLOY.FABRIC.APP'
        $records[0].status | Should -Be 'Manual action required'
        $records[0].evidence.reportedStatus | Should -Be 'Fail'
        $records[0].evidence.nonBlocking | Should -Be 'insightsApp'
        $records[0].message | Should -Be 'The Insights app step stopped: The stage folder is locked by another process.'
        $row = & $script:readRow
        $row['state'] | Should -Be 'Failed'
        $row['status'] | Should -Be 'Fail'
        $row['message'] | Should -Match ([regex]::Escape('It wasn''t created: DEPLOY.FABRIC.APP: The Insights app step stopped: The stage folder is locked by another process.'))
        @($script:warned).Count | Should -Be 1
        $script:warned[0] | Should -Match '^The Insights app step failed; it doesn''t block DONE, and the deployment goes on\.'
    }

    It 'contains a network error and a timeout as the app''s failure, with configure-fabric-app.ps1 as the fix' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppStage -MockWith {
            $failure = [System.Net.Http.HttpRequestException]::new('A network error reached api.fabric.microsoft.com on each of 4 attempts: The SSL connection could not be established.')
            throw $failure
        }
        $records = @(& $script:invoke)
        $records[0].evidence.networkError | Should -BeTrue
        $records[0].remediation | Should -Not -Match 'deploy\.ps1'
        (& $script:readRow)['state'] | Should -Be 'Failed'

        # An HTTP client's timeout is a TaskCanceledException, an OperationCanceledException: it's the app's failure, not a
        # stop of the run, while nobody pressed Ctrl+C.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $false }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppStage -MockWith { throw [System.Threading.Tasks.TaskCanceledException]::new('The request was canceled due to the configured HttpClient.Timeout of 100 seconds elapsing.') }
        $records = @(& $script:invoke)
        $records[0].message | Should -Match 'HttpClient\.Timeout of 100 seconds'
        (& $script:readRow)['state'] | Should -Be 'Failed'

        # rayfin up that ran past its time limit is the script's own Fail record.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppStage -MockWith {
            & (Get-Module -Name DbHubDemo) { ConvertTo-DemoInsightsAppRecord -Record (New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'rayfin up didn''t deploy APP_DatabaseHub_Insights (exit code -1, 1200 s): node did not finish within 1200 seconds and was stopped.' -Remediation 'Fix the reported problem and run the script again; nothing is deleted, and a re-run reuses the item.') }
        }
        $null = & $script:invoke
        $row = & $script:readRow
        $row['state'] | Should -Be 'Failed'
        $row['message'] | Should -Match 'did not finish within 1200 seconds'
    }

    It 'lets a stop of the run through, and nothing else' {
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppStage -MockWith { throw [System.OperationCanceledException]::new('deploy.ps1 was stopped (Ctrl+C).') }
        { & $script:invoke } | Should -Throw -ExceptionType ([System.OperationCanceledException])
    }

    It 'shows a deployed and checked app as Done, and a missing sign-in as Failed with the sign-in to run' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppStage -MockWith {
            & (Get-Module -Name DbHubDemo) {
                foreach ($record in @(
                        (New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'rayfin up deployed the Fabric app item APP_DatabaseHub_Insights in 40 s.')
                        (New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Every query returned rows.')
                    )) {
                    ConvertTo-DemoInsightsAppRecord -Record $record
                }
            }
        }
        $null = & $script:invoke
        $row = & $script:readRow
        $row['state'] | Should -Be 'Done'
        @($script:warned).Count | Should -Be 0

        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppStage -MockWith {
            & (Get-Module -Name DbHubDemo) {
                foreach ($record in @(
                        (New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'The Rayfin CLI isn''t signed in, so the app can''t be deployed unattended.' -Remediation 'Sign in once as the demo''s Fabric user.')
                        (New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'Not deployed: FABRIC.APP.SIGNIN needs attention first.')
                    )) {
                    ConvertTo-DemoInsightsAppRecord -Record $record
                }
            }
        }
        $null = & $script:invoke
        $row = & $script:readRow
        $row['state'] | Should -Be 'Failed'
        $row['status'] | Should -Be 'Manual action required'
        $row['message'] | Should -Match ([regex]::Escape('It wasn''t created: FABRIC.APP.SIGNIN: The Rayfin CLI isn''t signed in'))
        $row['message'] | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
    }
}

Describe 'Invoke-DemoFabricNotebookRun' {
    BeforeEach {
        $config = New-TestConfig
        $script:submitted = $null
        $script:states = [System.Collections.Generic.Queue[object]]::new()
        $script:states.Enqueue([pscustomobject]@{ status = 'InProgress'; startTimeUtc = '2026-10-22T16:00:00Z'; endTimeUtc = $null })
        $script:states.Enqueue([pscustomobject]@{ status = 'Completed'; startTimeUtc = '2026-10-22T16:00:00Z'; endTimeUtc = '2026-10-22T16:03:00Z' })
        $script:submitStatus = 202
        $script:items = @([pscustomobject]@{ id = '44444444-4444-4444-4444-444444444444'; displayName = 'NB_DatabaseHub_LiveActivity' })
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { [securestring]::new() }
        Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith { [pscustomobject]@{ StatusCode = 200; Items = @($script:items); Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -MockWith {
            if ($Method -eq 'Post') {
                $script:submitted = [pscustomobject]@{ Uri = $Uri; Body = $Body }
                return [pscustomobject]@{ StatusCode = $script:submitStatus; Headers = @{ Location = @('https://api.fabric.microsoft.com/v1/workspaces/22222222-2222-2222-2222-222222222222/items/44444444-4444-4444-4444-444444444444/jobs/instances/55555555-5555-5555-5555-555555555555') }; Body = [pscustomobject]@{ errorCode = 'CapacityNotActive'; message = 'The capacity is paused.' } }
            }
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = $script:states.Dequeue() }
        }
    }

    It 'submits RunNotebook with typed parameters and passes when the job completes' {
        $result = Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity' -Parameter ([ordered]@{ SAVE_RESULTS = $true; WINDOW_MINUTES = 1440; KEY_VAULT_URL = '' })
        $result.checkId | Should -Be 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY'
        $result.status | Should -Be 'Pass'
        $script:submitted.Uri | Should -Be 'https://api.fabric.microsoft.com/v1/workspaces/22222222-2222-2222-2222-222222222222/items/44444444-4444-4444-4444-444444444444/jobs/instances?jobType=RunNotebook'
        $parameters = $script:submitted.Body['executionData']['parameters']
        $parameters['SAVE_RESULTS']['type'] | Should -Be 'bool'
        $parameters['SAVE_RESULTS']['value'] | Should -Be 'true'
        $parameters['WINDOW_MINUTES']['type'] | Should -Be 'int'
        $parameters['WINDOW_MINUTES']['value'] | Should -Be '1440'
        $parameters['KEY_VAULT_URL']['type'] | Should -Be 'string'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -Times 2 -Exactly -ParameterFilter { $Method -eq 'Get' }
    }

    It 'fails with the job''s failure reason' {
        $script:states.Clear()
        $script:states.Enqueue([pscustomobject]@{ status = 'Failed'; startTimeUtc = '2026-10-22T16:00:00Z'; endTimeUtc = '2026-10-22T16:01:00Z'; failureReason = [pscustomobject]@{ errorCode = 'JobInstanceStatusFailed'; message = 'Cell 7 failed.' } })
        $result = Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity'
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'Cell 7 failed'
    }

    It 'fails when the run isn''t accepted, for example on a paused capacity, and never touches the capacity' {
        $script:submitStatus = 400
        $result = Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity'
        $result.status | Should -Be 'Fail'
        $result.remediation | Should -Match 'never resume'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -Times 0 -Exactly -ParameterFilter { $Uri -match '/capacities/' }
    }

    It 'fails when the notebook isn''t in the workspace, and is Not selected without a workspace' {
        $script:items = @()
        (Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity').status | Should -Be 'Fail'
        $config['fabric']['workspaceId'] = ''
        (Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity').status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -Times 0 -Exactly
    }

    It 'says a notebook list that failed isn''t a missing notebook: a paused capacity is Manual action required with the resume, anything else a rerun (live finding, 2026-11-10)' {
        Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith { [pscustomobject]@{ StatusCode = 404; Items = @(); Error = 'HTTP 404 CapacityNotActive The capacity is not active.' } }
        $paused = Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity'
        $paused.status | Should -Be 'Manual action required'
        $paused.message | Should -Be 'NB_DatabaseHub_LiveActivity didn''t run: the workspace''s capacity is paused or inactive (HTTP 404 CapacityNotActive The capacity is not active).'
        $paused.remediation | Should -Be 'Resume the capacity, or ask its administrator to (Azure portal: Microsoft Fabric, the capacity, Resume; that resumes its billing too). Then run it again.'

        Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith { [pscustomobject]@{ StatusCode = 503; Items = @(); Error = 'HTTP 503 ServiceUnavailable' } }
        $unanswered = Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity'
        $unanswered.status | Should -Be 'Fail'
        $unanswered.message | Should -Be 'NB_DatabaseHub_LiveActivity didn''t run: the workspace couldn''t be read (HTTP 503 ServiceUnavailable).'
        $unanswered.remediation | Should -Be 'Run it again in a few minutes: the workspace''s notebooks couldn''t be listed.'
        $unanswered.remediation | Should -Not -Match 'Import the notebooks'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -Times 0 -Exactly
    }

    It 'warns, and leaves the job running, when the wait runs out' {
        $script:states.Clear()
        foreach ($i in 1..200) { $script:states.Enqueue([pscustomobject]@{ status = 'InProgress'; startTimeUtc = '2026-10-22T16:00:00Z'; endTimeUtc = $null }) }
        $result = Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity' -TimeoutMinutes 1 -PollSeconds 1
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'still InProgress'
    }

    It 'counts -TimeoutMinutes in elapsed time, the reads included, when every read pays its retries (review of c7c86ec)' {
        # Each read answers HTTP 503 after its attempts and backoff, about 50 seconds; before, the polls were counted, not the time.
        $script:reads = 0
        $script:now = [datetime]::new(2026, 11, 2, 15, 0, 0, [System.DateTimeKind]::Utc)
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $script:now }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $script:now = $script:now.AddSeconds([int]$PesterBoundParameters['Seconds']) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -ParameterFilter { $Method -eq 'Get' } -MockWith {
            $script:reads++
            $script:now = $script:now.AddSeconds(50)
            [pscustomobject]@{ StatusCode = 503; Headers = @{}; Body = $null }
        }
        $start = $script:now
        $result = Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity' -TimeoutMinutes 2 -PollSeconds 15
        $result.status | Should -Be 'Warning'
        $script:reads | Should -BeLessOrEqual 3 -Because 'eight polls of 65 seconds each would take more than 8 minutes'
        ($script:now - $start).TotalMinutes | Should -BeLessOrEqual 3
    }
}
