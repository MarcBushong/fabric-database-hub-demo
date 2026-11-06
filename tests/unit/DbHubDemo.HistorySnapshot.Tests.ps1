BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    # Obviously fake IDs: every group repeats one digit.
    $script:workspaceId = '13131313-1313-1313-1313-131313131313'
    $script:lakehouseId = '14141414-1414-1414-1414-141414141414'
    $script:notebookId = '15151515-1515-1515-1515-151515151515'
    $script:modelId = '16161616-1616-1616-1616-161616161616'

    function New-TestConfig([switch] $WithT4) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t4Enabled'] = [bool]$WithT4
        return $config
    }

    function New-TestResult([string] $CheckId, [string] $Status = 'Pass') {
        New-DemoResult -CheckId $CheckId -Area 'infra' -Target 'subscription' -Status $Status -Message ('{0} {1}' -f $CheckId, $Status)
    }

    # Every DONE requirement passing (brief item 16), for the default JumpstartImage mode without T4.
    function New-DoneResult {
        $ids = InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'JumpstartImage' -T4Off }
        foreach ($id in $ids) {
            New-TestResult $id
        }
    }

    function New-FinishedState {
        [pscustomobject]@{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = ''; TrackFabric = 'Fabric'; T4Sku = ''; GuidedStopUtc = ''; HostPasswordUtc = '' }
    }

    function New-HistoryRecord([string] $Status, [string] $Reported = '') {
        $evidence = [ordered]@{ nonBlocking = 'historySnapshot'; outcome = 'Failed' }
        if ($Reported) {
            $evidence['reportedStatus'] = $Reported
        }
        New-DemoResult -CheckId 'DEPLOY.FABRIC.HISTORY' -Area 'fabric' -Target 'fabric' -Status $Status -Message 'The history report got no snapshot: NB_DatabaseHub_LiveActivity failed: Py4JJavaError in cell 12.' -Remediation 'Open the notebook''s run in the workspace (Monitor hub). Then run ./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity.' -Evidence $evidence
    }

    function Get-TestRow([string] $Path, [string] $Id = 'Fabric.History') {
        $model = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        foreach ($track in @($model['tracks'])) {
            foreach ($item in @($track['steps'])) {
                if ([string]$item['id'] -eq $Id) {
                    return $item
                }
            }
        }
        return $null
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'The history snapshot''s parameters (2026-11-06)' {
    It 'sends NB_DatabaseHub_LiveActivity only its analyze-only switches, the 1440-minute window, and the demo''s resource group' {
        $config = New-TestConfig
        $config['prefix'] = 'contoso'
        $config['environment'] = 'pilot'
        $parameters = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoHistorySnapshotParameter -Config $Config }
        @($parameters.Keys) | Should -Be @('CONFIRM', 'STOP_ACTIVITY', 'SAVE_RESULTS', 'WINDOW_MINUTES', 'KEY_VAULT_URL', 'RESOURCE_GROUP')
        # CONFIRM false: the notebook's Run all would otherwise send its own 240-minute activity request through GitHub (P9).
        $parameters['CONFIRM'] | Should -BeFalse
        $parameters['CONFIRM'] | Should -BeOfType [bool]
        $parameters['STOP_ACTIVITY'] | Should -BeFalse
        $parameters['SAVE_RESULTS'] | Should -BeTrue
        $parameters['WINDOW_MINUTES'] | Should -Be 1440
        $parameters['WINDOW_MINUTES'] | Should -BeOfType [int]
        $parameters['KEY_VAULT_URL'] | Should -Be ''
        $parameters['RESOURCE_GROUP'] | Should -Be 'rg-contoso-pilot'
    }

    It 'names only parameters the live-activity notebook declares in its parameters cell' {
        $notebook = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks/NB_DatabaseHub_LiveActivity.ipynb') -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $cell = (@($notebook['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]['source']) -join ''
        $parameters = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoHistorySnapshotParameter -Config $Config }
        foreach ($name in $parameters.Keys) {
            $cell | Should -Match ('(?m)^{0} = ' -f [regex]::Escape($name)) -Because ('{0} must override the cell''s own value' -f $name)
        }
    }
}

Describe 'Invoke-DemoHistorySnapshotStep (2026-11-06)' {
    BeforeEach {
        $script:config = New-TestConfig
        $script:warned = [System.Collections.Generic.List[string]]::new()
        $script:capacityState = 'Active'
        $script:resolved = $true
        $script:notebookItems = @([pscustomobject]@{ id = $script:notebookId; displayName = 'NB_DatabaseHub_LiveActivity'; type = 'Notebook' })
        $script:runStatus = 'Pass'
        $script:jobStatus = 'Completed'
        $script:runMessage = 'NB_DatabaseHub_LiveActivity ran on demand and completed in about 140 seconds.'
        $script:runRemediation = ''
        $script:refreshStatus = 'Pass'
        $script:refreshMessage = 'Refreshed the semantic model (Direct Lake framing) in about 5 seconds.'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { if ($PesterBoundParameters['Level'] -eq 'Warning') { $script:warned.Add([string]$PesterBoundParameters['Message']) } }
        # Nothing reaches Azure or Fabric: a call these mocks don't cover fails the test that expects a Pass.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'unexpected Azure CLI call' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { [securestring]::new() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoPowerBIToken -MockWith { [securestring]::new() }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith {
            $copy = @{ subscriptionId = '11111111-2222-3333-4444-555555555555'; tenantId = '66666666-7777-8888-9999-000000000000'; prefix = 'dbhub'; environment = 'demo'; fabric = @{ workspaceName = 'Database Hub Demo'; lakehouseName = 'LH_DatabaseHub' } }
            if ($script:resolved) {
                $copy['fabric']['workspaceId'] = $script:workspaceId
                $copy['fabric']['lakehouseId'] = $script:lakehouseId
                return [pscustomobject]@{ Resolved = $true; Config = $copy; WorkspaceId = $script:workspaceId; WorkspaceName = 'Database Hub Demo'; LakehouseId = $script:lakehouseId; Results = @() }
            }
            $copy['fabric']['workspaceId'] = $script:workspaceId
            [pscustomobject]@{ Resolved = $false; Config = $copy; WorkspaceId = $script:workspaceId; WorkspaceName = 'Database Hub Demo'; LakehouseId = ''; Results = @(
                    (New-DemoResult -CheckId 'FABRIC.RESOLVE.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Found the workspace.')
                    (New-DemoResult -CheckId 'FABRIC.RESOLVE.LAKEHOUSE' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'The lakehouse "LH_DatabaseHub" isn''t in the workspace "Database Hub Demo".')
                ) }
        }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -MockWith {
            New-DemoResult -CheckId 'FABRIC.P5.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Contributor.'
            New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status $(if ($script:capacityState -eq 'Active') { 'Pass' } else { 'Manual action required' }) -Message 'capacity' -Evidence @{ state = $script:capacityState; capacityName = 'fabcap01'; sku = 'F2' }
        }
        Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith { [pscustomobject]@{ StatusCode = 200; Items = @($script:notebookItems); Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -MockWith {
            New-DemoResult -CheckId 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY' -Area 'fabric' -Target 'fabric' -Status $script:runStatus -Message $script:runMessage -Remediation $script:runRemediation -Evidence ([ordered]@{ notebook = 'NB_DatabaseHub_LiveActivity'; status = $script:jobStatus; seconds = 140 })
        }
        Mock -ModuleName DbHubDemo -CommandName Find-DemoSemanticModel -MockWith { [pscustomobject]@{ StatusCode = 200; Id = $script:modelId; Count = 1; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoSemanticModelRefresh -MockWith {
            New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.REFRESH' -Area 'fabric' -Target 'fabric' -Status $script:refreshStatus -Message $script:refreshMessage -Remediation $(if ($script:refreshStatus -eq 'Fail') { 'Run NB_DatabaseHub_LiveActivity with SAVE_RESULTS true, then run the script again.' } else { '' })
        }
        # The capacity is the user's: nothing here may resume, pause, or scale it.
        Mock -ModuleName DbHubDemo -CommandName Resume-DemoFabricCapacity -MockWith { throw 'resumed a capacity' }
        Mock -ModuleName DbHubDemo -CommandName Suspend-DemoFabricCapacity -MockWith { throw 'paused a capacity' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricCapacityTransition -MockWith { throw 'changed a capacity' }

        $script:progress = Join-Path -Path $TestDrive -ChildPath ('progress-' + [guid]::NewGuid().ToString('N') + '.json')
        InModuleScope DbHubDemo -Parameters @{ Path = $script:progress } { Initialize-DemoProgress -Path $Path -Model (New-DemoProgressModel -Catalog (Get-DemoProgressCatalog)) -Confirm:$false }
        $script:requirement = @(InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'JumpstartImage' -T4Off })
        $script:done = @(New-DoneResult)
        $script:invoke = {
            param([hashtable] $Extra = @{})
            $arguments = @{ Config = $script:config; Result = $script:done; Requirement = $script:requirement; DoneChecked = $true; Environment = [pscustomobject]@{ GitHubActions = $false }; ProgressPath = $script:progress }
            foreach ($key in $Extra.Keys) {
                $arguments[$key] = $Extra[$key]
            }
            InModuleScope DbHubDemo -Parameters @{ Arguments = $arguments } { Invoke-DemoHistorySnapshotStep @Arguments }
        }
    }

    It 'runs NB_DatabaseHub_LiveActivity once, analyze-only, as the deploying user, then frames the history model, and says plainly what stays partial' {
        $record = & $script:invoke
        $record.checkId | Should -Be 'DEPLOY.FABRIC.HISTORY'
        $record.status | Should -Be 'Pass'
        $record.evidence.outcome | Should -Be 'Saved'
        $record.evidence.nonBlocking | Should -Be 'historySnapshot'
        $record.evidence.parameters.CONFIRM | Should -BeFalse
        $record.evidence.parameters.STOP_ACTIVITY | Should -BeFalse
        $record.evidence.parameters.SAVE_RESULTS | Should -BeTrue
        $record.evidence.parameters.WINDOW_MINUTES | Should -Be 1440
        $record.evidence.refreshStatus | Should -Be 'Pass'
        $record.message | Should -Match '^Saved the history report''s snapshots: NB_DatabaseHub_LiveActivity ran once, analyze-only \(no activity request\), and saved the last 1440 minutes to the lakehouse in about 140 seconds, and the history model was refreshed'
        # Partial data, said plainly (the user's decision): incidents start only after DONE's checks.
        $record.message | Should -Match ([regex]::Escape('business-day''s incidents start only at the end of this run, after DONE''s checks, so incident measures such as Blocking Incidents stay blank until incidents have run and the notebook runs again'))
        $record.message | Should -Match ([regex]::Escape('./scripts/stop-demo.ps1 -SaveHistory'))
        $record.message | Should -Match ([regex]::Escape('./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity'))
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'NB_DatabaseHub_LiveActivity' -and $TimeoutMinutes -eq 10 -and
            $Parameter['CONFIRM'] -is [bool] -and -not $Parameter['CONFIRM'] -and $Parameter['STOP_ACTIVITY'] -is [bool] -and -not $Parameter['STOP_ACTIVITY'] -and
            $Parameter['SAVE_RESULTS'] -eq $true -and $Parameter['WINDOW_MINUTES'] -eq 1440 -and $Parameter['KEY_VAULT_URL'] -eq '' -and $Parameter['RESOURCE_GROUP'] -eq 'rg-dbhub-demo' -and
            -not $Parameter.Contains('PROFILE') -and -not $Parameter.Contains('DURATION_MINUTES') -and -not $Parameter.Contains('PURGE_DEMO_TABLES') -and
            $Config['fabric']['workspaceId'] -eq $script:workspaceId -and $Config['fabric']['lakehouseId'] -eq $script:lakehouseId
        }
        # Read-only: the Fabric track creates what's missing, and this step creates nothing.
        Should -Invoke -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -Times 1 -Exactly -ParameterFilter { -not $Create }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoSemanticModelRefresh -Times 1 -Exactly -ParameterFilter { $SemanticModelId -eq $script:modelId -and $WorkspaceId -eq $script:workspaceId -and $TableRetryMinutes -eq 0 -and $TimeoutSeconds -eq 300 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Find-DemoSemanticModel -Times 1 -Exactly -ParameterFilter { $Name -eq 'SM_DatabaseHub_History' }
        $row = Get-TestRow -Path $script:progress
        $row['state'] | Should -Be 'Done'
        $row['status'] | Should -Be 'Pass'
        $row['message'] | Should -Match 'Blocking Incidents stay blank'
        @($script:warned).Count | Should -Be 0
        (InModuleScope DbHubDemo -Parameters @{ R = @($record) } { Get-DemoHistorySnapshotItem -Result $R }) | Should -BeNullOrEmpty
    }

    It 'says the earlier measure check came before this snapshot, and what stays blank with the baseline profile' {
        $script:done = @(New-DoneResult) + @(New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.MEASURES' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'The history report is empty until NB_DatabaseHub_LiveActivity saves its first snapshots.')
        $record = & $script:invoke @{ ActivityProfile = [pscustomobject]@{ Name = 'baseline'; HasIncidents = $false } }
        $record.status | Should -Be 'Pass'
        $record.message | Should -Match ([regex]::Escape('the activity profile is baseline, with no incidents, so incident measures such as Blocking Incidents stay blank; after an incident (./scripts/demo-control.ps1)'))
        $record.message | Should -Match ([regex]::Escape('This run''s FABRIC.SEMANTICMODEL.* checks ran before this snapshot; ./scripts/configure-powerbi.ps1 -CheckModelData checks the measures again.'))
    }

    It 'is a Warning with the reason, and runs nothing, when the workspace''s capacity is paused; it never resumes, pauses, or scales it' {
        $script:capacityState = 'Inactive'
        $record = & $script:invoke
        $record.status | Should -Be 'Warning'
        $record.evidence.outcome | Should -Be 'CapacityPaused'
        $record.evidence.capacityState | Should -Be 'Inactive'
        $record.evidence.ContainsKey('reportedStatus') | Should -BeFalse
        $record.message | Should -Be 'The history report got no snapshot: the workspace''s capacity "fabcap01" is Inactive, so NB_DatabaseHub_LiveActivity couldn''t run. deploy.ps1 never resumes, pauses, or scales a capacity.'
        $record.remediation | Should -Match '^Resume the capacity, or ask its administrator to'
        $record.remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity'))
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoSemanticModelRefresh -Times 0 -Exactly
        foreach ($command in 'Resume-DemoFabricCapacity', 'Suspend-DemoFabricCapacity', 'Invoke-DemoFabricCapacityTransition') {
            Should -Invoke -ModuleName DbHubDemo -CommandName $command -Times 0 -Exactly
        }
        $row = Get-TestRow -Path $script:progress
        $row['state'] | Should -Be 'Action needed'
        $row['status'] | Should -Be 'Warning'
        $row['message'] | Should -Match 'is Inactive, so NB_DatabaseHub_LiveActivity couldn''t run\..*Resume the capacity'
        @($script:warned).Count | Should -Be 1
        $script:warned[0] | Should -Match '^The history snapshot didn''t work; it doesn''t block DONE\. The history report got no snapshot: the workspace''s capacity "fabcap01" is Inactive'
    }

    It 'is the same Warning when Fabric refuses the run because the capacity paused meanwhile (CapacityNotActive)' {
        $script:runStatus = 'Fail'
        $script:jobStatus = ''
        $script:runMessage = 'NB_DatabaseHub_LiveActivity wasn''t started: HTTP 404, CapacityNotActive: The capacity is not active.'
        $script:runRemediation = 'Check that the workspace''s capacity is running (the scripts never resume it), then run the notebook again.'
        $record = & $script:invoke
        $record.status | Should -Be 'Warning'
        $record.evidence.outcome | Should -Be 'CapacityPaused'
        $record.message | Should -Match 'capacity isn''t running, so NB_DatabaseHub_LiveActivity couldn''t start\. NB_DatabaseHub_LiveActivity wasn''t started: HTTP 404, CapacityNotActive'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoSemanticModelRefresh -Times 0 -Exactly
        (Get-TestRow -Path $script:progress)['state'] | Should -Be 'Action needed'
    }

    It 'stops waiting at its timeout: a job still running is a Warning, it keeps running in Fabric, and the model isn''t framed' {
        $script:runStatus = 'Warning'
        $script:jobStatus = 'InProgress'
        $script:runMessage = 'NB_DatabaseHub_LiveActivity is still InProgress after 4 minutes; it keeps running. Check its run in the workspace (Monitor hub).'
        $record = & $script:invoke @{ TimeoutMinutes = 4 }
        $record.status | Should -Be 'Warning'
        $record.evidence.outcome | Should -Be 'StillRunning'
        $record.evidence.timeoutMinutes | Should -Be 4
        $record.message | Should -Be 'NB_DatabaseHub_LiveActivity was still InProgress after 4 minutes, so deploy.ps1 stopped waiting: the run goes on in Fabric and saves its snapshots when it finishes, and the history model wasn''t refreshed for them.'
        $record.remediation | Should -Match 'Monitor hub'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 1 -Exactly -ParameterFilter { $TimeoutMinutes -eq 4 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoSemanticModelRefresh -Times 0 -Exactly
        (Get-TestRow -Path $script:progress)['state'] | Should -Be 'Action needed'

        # A run that another one deduplicated is a Warning too.
        $script:jobStatus = 'Deduped'
        $script:runMessage = 'NB_DatabaseHub_LiveActivity was already running, so this run was deduplicated; its results come from that run.'
        (& $script:invoke).evidence.outcome | Should -Be 'Deduped'
    }

    It 'bubbles a failed notebook''s error up: a Warning that reads Fail on its Failed row, in Needs attention, and in DONE, never a Fail record' {
        $script:runStatus = 'Fail'
        $script:jobStatus = 'Failed'
        $script:runMessage = 'NB_DatabaseHub_LiveActivity failed: Py4JJavaError in cell 12: Table or view not found: dbo.telemetry_snapshots'
        $script:runRemediation = 'Open the notebook''s run in the workspace (Monitor hub) for the cell that failed, fix it, and run it again.'
        $record = & $script:invoke
        $record.status | Should -Be 'Warning'
        $record.evidence.reportedStatus | Should -Be 'Fail'
        $record.evidence.outcome | Should -Be 'Failed'
        $record.message | Should -Be 'The history report got no snapshot: NB_DatabaseHub_LiveActivity failed: Py4JJavaError in cell 12: Table or view not found: dbo.telemetry_snapshots'
        $record.remediation | Should -Match '^Open the notebook''s run in the workspace \(Monitor hub\) for the cell that failed, fix it, and run it again\. Then run \./scripts/configure-fabric\.ps1'
        $row = Get-TestRow -Path $script:progress
        $row['state'] | Should -Be 'Failed'
        $row['status'] | Should -Be 'Fail'
        $row['nonBlocking'] | Should -BeTrue
        $row['message'] | Should -Match ([regex]::Escape('Py4JJavaError in cell 12'))
        $item = InModuleScope DbHubDemo -Parameters @{ R = @($record) } { Get-DemoHistorySnapshotItem -Result $R }
        $item['state'] | Should -Be 'Failed'
        $line = InModuleScope DbHubDemo -Parameters @{ I = $item } { Format-DemoNonBlockingLine -Item $I }
        $line | Should -Match ([regex]::Escape('Failed (doesn''t block DONE): the history report''s snapshot. The history report got no snapshot: NB_DatabaseHub_LiveActivity failed: Py4JJavaError in cell 12'))
        $line | Should -Match 'Monitor hub'
        @($script:warned).Count | Should -Be 1
    }

    It 'says the snapshots are saved, and why the report may not show them yet, when the model''s refresh doesn''t pass' {
        $script:refreshStatus = 'Fail'
        $script:refreshMessage = 'The refresh ended with status Failed: 0xC14700DF source tables either do not exist or access was denied'
        $record = & $script:invoke
        $record.status | Should -Be 'Warning'
        $record.evidence.outcome | Should -Be 'SavedNotRefreshed'
        $record.evidence.reportedStatus | Should -Be 'Fail'
        $record.message | Should -Match '^NB_DatabaseHub_LiveActivity ran once, analyze-only \(no activity request\), and saved the last 1440 minutes to the lakehouse in about 140 seconds, but the history model wasn''t refreshed: The refresh ended with status Failed'
        $record.remediation | Should -Match 'Keep your Direct Lake data up to date'
        (Get-TestRow -Path $script:progress)['state'] | Should -Be 'Failed'

        # A paused capacity at the refresh (Manual action required from the refresh) is a Warning without an error.
        $script:refreshStatus = 'Manual action required'
        $script:refreshMessage = 'The refresh request was refused: the workspace''s capacity is paused.'
        $record = & $script:invoke
        $record.evidence.ContainsKey('reportedStatus') | Should -BeFalse
        (Get-TestRow -Path $script:progress)['state'] | Should -Be 'Action needed'
    }

    It 'is Not selected, and calls nothing in Fabric, <Case>' -ForEach @(
        @{ Case = 'with -WhatIf'; Extra = @{ WhatIfRun = $true }; Pattern = '^What if: nothing ran\. A deployment runs NB_DatabaseHub_LiveActivity once at its end, analyze-only' }
        @{ Case = 'with -SkipFabric'; Extra = @{ SkipFabric = $true }; Pattern = '^The Fabric track was skipped \(-SkipFabric\), so NB_DatabaseHub_LiveActivity didn''t run' }
        @{ Case = 'in GitHub Actions'; Extra = @{ Environment = [pscustomobject]@{ GitHubActions = $true } }; Pattern = 'the demo has no supported way for it to run notebooks \(ADR 0014; deploy\.yml skips Fabric by default\)' }
        @{ Case = 'when DONE''s checks didn''t run'; Extra = @{ DoneChecked = $false }; Pattern = '^DONE''s checks didn''t run in this deployment \(a track didn''t finish, or a check failed\)' }
        @{ Case = 'when DONE''s telemetry checks didn''t pass'; Extra = @{}; StaleTelemetry = 'TELEMETRY.T2'; Pattern = '^DONE''s telemetry checks didn''t pass \(TELEMETRY\.T2\), so NB_DatabaseHub_LiveActivity didn''t run: it would have had nothing to save' }
    ) {
        $arguments = @{} + $Extra
        if ($_.ContainsKey('StaleTelemetry')) {
            $arguments['Result'] = @(New-DoneResult | Where-Object { $_.checkId -ne $StaleTelemetry }) + @(New-TestResult $StaleTelemetry 'Warning')
        }
        $record = & $script:invoke $arguments
        $record.checkId | Should -Be 'DEPLOY.FABRIC.HISTORY'
        $record.status | Should -Be 'Not selected'
        $record.evidence.outcome | Should -Be 'NotSelected'
        $record.message | Should -Match $Pattern
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 0 -Exactly
        $row = Get-TestRow -Path $script:progress
        $row['state'] | Should -Be 'Skipped'
        $row['status'] | Should -Be 'Not selected'
        @($script:warned).Count | Should -Be 0
        (InModuleScope DbHubDemo -Parameters @{ R = @($record) } { Get-DemoHistorySnapshotItem -Result $R }) | Should -BeNullOrEmpty
    }

    It 'reads GitHub Actions from the run''s environment when none is given' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRunEnvironment -MockWith { [pscustomobject]@{ GitHubActions = $true; Ci = $true; Interactive = $false; Codespaces = $false; Windows = $true } }
        $arguments = @{ Config = $script:config; Result = $script:done; Requirement = $script:requirement; DoneChecked = $true }
        $record = InModuleScope DbHubDemo -Parameters @{ Arguments = $arguments } { Invoke-DemoHistorySnapshotStep @Arguments }
        $record.status | Should -Be 'Not selected'
        $record.remediation | Should -Match ([regex]::Escape('From a terminal where you''re signed in to Azure: ./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity.'))
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 0 -Exactly
    }

    It 'is Not selected when the Fabric track didn''t create the lakehouse or import the notebook' {
        $script:resolved = $false
        $record = & $script:invoke
        $record.status | Should -Be 'Not selected'
        $record.message | Should -Match '^The Fabric track didn''t create the workspace or the lakehouse, so NB_DatabaseHub_LiveActivity didn''t run\. FABRIC\.RESOLVE\.LAKEHOUSE: The lakehouse "LH_DatabaseHub" isn''t in the workspace'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 0 -Exactly

        $script:resolved = $true
        $script:notebookItems = @()
        $record = & $script:invoke
        $record.status | Should -Be 'Not selected'
        $record.message | Should -Be 'The Fabric track didn''t import NB_DatabaseHub_LiveActivity: it isn''t in the workspace "Database Hub Demo", so the history report got no snapshot.'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 0 -Exactly
        (Get-TestRow -Path $script:progress)['state'] | Should -Be 'Skipped'
    }

    It 'turns an exception into its own Warning and never throws, but lets a stop of the run through' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { throw 'No verified Fabric token is available: AADSTS70043: The refresh token has expired.' }
        $record = & $script:invoke
        $record.status | Should -Be 'Warning'
        $record.evidence.reportedStatus | Should -Be 'Fail'
        $record.message | Should -Match '^The history snapshot stopped, so the history report got no snapshot: No verified Fabric token is available'
        $record.remediation | Should -Match 'it never blocks DONE'
        (Get-TestRow -Path $script:progress)['state'] | Should -Be 'Failed'

        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { throw [System.OperationCanceledException]::new('deploy.ps1 was stopped (Ctrl+C).') }
        { & $script:invoke } | Should -Throw -ExceptionType ([System.OperationCanceledException])
    }
}

Describe 'The history snapshot never blocks DONE (2026-11-06)' {
    It 'leaves a run DONE, with exit code 0, and names what didn''t work: <Case>' -ForEach @(
        @{ Case = 'a paused capacity'; Status = 'Warning'; Reported = ''; State = 'Action needed' }
        @{ Case = 'a failed notebook'; Status = 'Warning'; Reported = 'Fail'; State = 'Failed' }
        # Defense in depth: even a record that a future change made a Fail never blocks DONE (Test-DemoNonBlockingResult).
        @{ Case = 'a record that says Fail'; Status = 'Fail'; Reported = 'Fail'; State = 'Failed' }
        @{ Case = 'a record that says Manual action required'; Status = 'Manual action required'; Reported = ''; State = 'Action needed' }
    ) {
        $result = @(New-DoneResult) + @(New-HistoryRecord -Status $Status -Reported $Reported)
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $result; State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
        $outcome.ExitCode | Should -Be 0
        @($outcome.NonBlocking).Count | Should -Be 1
        $outcome.NonBlocking[0]['name'] | Should -Be 'the history report''s snapshot'
        $outcome.NonBlocking[0]['state'] | Should -Be $State
        $outcome.NonBlocking[0]['message'] | Should -Match 'Py4JJavaError in cell 12'
        $lines = (InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) -join ' '
        $lines | Should -Match ([regex]::Escape(('{0} (doesn''t block DONE): the history report''s snapshot.' -f $State)))
    }

    It 'keeps DEPLOY.SUMMARY and the run''s results free of a Fail, and names it there' {
        $result = @(New-DoneResult) + @(New-HistoryRecord -Status 'Warning' -Reported 'Fail')
        $summary = InModuleScope DbHubDemo -Parameters @{ Result = $result } { Get-DemoDeploySummary -Result $Result -FinishedText 'Every track and the validation finished.' }
        $summary.Status | Should -Be 'Pass'
        $summary.Message | Should -Be 'Every track and the validation finished.' -Because 'a Warning adds nothing to a summary that passed'
        (Get-DemoExitCode -Result $result) | Should -Be 0
        (Get-DemoExitCode -Result $result -TreatManualAsError) | Should -Be 0
        @($summary.Evidence.nonBlocking) | Should -HaveCount 1
        @($summary.Evidence.nonBlocking)[0] | Should -Match '^Failed \(doesn''t block DONE\): the history report''s snapshot\. '
    }

    It 'adds nothing for a snapshot that passed, or one that wasn''t selected' {
        foreach ($status in 'Pass', 'Not selected') {
            $record = New-DemoResult -CheckId 'DEPLOY.FABRIC.HISTORY' -Area 'fabric' -Target 'fabric' -Status $status -Message 'x' -Evidence @{ nonBlocking = 'historySnapshot' }
            $outcome = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult) + @($record)); State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
            $outcome.Kind | Should -Be 'Done'
            @($outcome.NonBlocking).Count | Should -Be 0
        }
    }

    It 'shows the row on the status page as not blocking DONE, with its error, and in the Needs attention box once the run ended' {
        $path = Join-Path -Path $TestDrive -ChildPath ('progress-' + [guid]::NewGuid().ToString('N') + '.json')
        $record = New-HistoryRecord -Status 'Warning' -Reported 'Fail'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = (@(New-DoneResult) + @($record)); State = (New-FinishedState); Config = (New-TestConfig) } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $html = InModuleScope DbHubDemo -Parameters @{ Path = $path; Outcome = $outcome } {
            Initialize-DemoProgress -Path $Path -Model (New-DemoProgressModel -Catalog (Get-DemoProgressCatalog)) -Confirm:$false
            Set-DemoProgressStep -Path $Path -Id 'Fabric.History' -State 'Failed' -Status 'Fail' -Message 'The history report got no snapshot: NB_DatabaseHub_LiveActivity failed: Py4JJavaError in cell 12.' -MaxLength 1200
            Set-DemoProgressValue -Path $Path -Section 'nonBlocking' -Value @($Outcome.NonBlocking)
            Set-DemoProgressValue -Path $Path -Section 'run' -Value ([ordered]@{ state = 'Done'; reason = 'Database Hub shows every target.' })
            ConvertTo-DemoProgressHtml -Model (Read-DemoProgress -Path $Path)
        }
        $html | Should -Match ([regex]::Escape('History report&#39;s snapshot (NB_DatabaseHub_LiveActivity, once, analyze-only) <span class="meta">(doesn''t block DONE)</span>'))
        $html | Should -Match '<h2>Needs attention</h2>'
        $html | Should -Match ([regex]::Escape('Failed (doesn&#39;t block DONE): the history report&#39;s snapshot. The history report got no snapshot: NB_DatabaseHub_LiveActivity failed: Py4JJavaError in cell 12.'))
    }
}
