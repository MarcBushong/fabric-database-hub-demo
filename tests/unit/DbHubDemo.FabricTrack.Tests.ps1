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

    It 'passes the workspace the Fabric step resolved, and never reports the optional app as a Fail (Phase 28 live finding)' {
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
        $listed.message | Should -Match '^Optional Insights app: Your Fabric workspaces couldn''t be listed'
        foreach ($record in $records) {
            $record.evidence.optional | Should -Be 'insightsApp' -Because $record.checkId
            (& (Get-Module -Name DbHubDemo) { param($r) Test-DemoOptionalResult -Result $r } $record) | Should -BeTrue -Because ('{0} never blocks DONE' -f $record.checkId)
        }
        $summary = & (Get-Module -Name DbHubDemo) { param($r) Get-DemoInsightsAppSummary -Result $r } $records
        $summary.State | Should -Be 'Skipped'
        $summary.Status | Should -Be 'Manual action required'
        $summary.Reason | Should -Match ([regex]::Escape('It wasn''t added: FABRIC.RESOLVE.WORKSPACE: Your Fabric workspaces couldn''t be listed: HTTP 429'))
        $summary.HowTo | Should -Match 'Check your Fabric access'
        $summary.HowTo | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))

        # Without a resolved workspace, the script looks it up itself, as before.
        $null = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoFabricAppStage -Config $c -WorkspaceId '' } $config
        $script:stepArgument.Contains('WorkspaceId') | Should -BeFalse
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

    It 'warns, and leaves the job running, when the wait runs out' {
        $script:states.Clear()
        foreach ($i in 1..200) { $script:states.Enqueue([pscustomobject]@{ status = 'InProgress'; startTimeUtc = '2026-10-22T16:00:00Z'; endTimeUtc = $null }) }
        $result = Invoke-DemoFabricNotebookRun -Config $config -Name 'NB_DatabaseHub_LiveActivity' -TimeoutMinutes 1 -PollSeconds 1
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'still InProgress'
    }
}
