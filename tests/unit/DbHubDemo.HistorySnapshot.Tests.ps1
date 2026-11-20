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
        # T4 is part of every deployment (2026-11-09).
        $config['t4Enabled'] = $true
        return $config
    }

    function New-TestResult([string] $CheckId, [string] $Status = 'Pass') {
        New-DemoResult -CheckId $CheckId -Area 'infra' -Target 'subscription' -Status $Status -Message ('{0} {1}' -f $CheckId, $Status)
    }

    # Every DONE requirement passing (brief item 16), for the default JumpstartImage mode without T4.
    function New-DoneResult {
        $ids = InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'JumpstartImage' }
        foreach ($id in $ids) {
            New-TestResult $id
        }
    }

    function New-FinishedState {
        [pscustomobject]@{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = 'Telemetry'; TrackFabric = 'Fabric'; T4Sku = ''; GuidedStopUtc = ''; HostPasswordUtc = '' }
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

    It 'names only parameters the live-activity notebook declares in its parameters cell, besides the three an older copy reads' {
        $notebook = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks/NB_DatabaseHub_LiveActivity.ipynb') -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $cell = (@($notebook['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]['source']) -join ''
        $parameters = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoHistorySnapshotParameter -Config $Config }
        # A copy imported before 2026-11-14 reads these three, so its Run all sends no activity request through GitHub;
        # today's notebook has none of them (ADR 0026), and a job's parameter it doesn't declare changes nothing in it.
        $legacy = @('CONFIRM', 'STOP_ACTIVITY', 'KEY_VAULT_URL')
        foreach ($name in $parameters.Keys) {
            if ($legacy -contains $name) {
                $cell | Should -Not -Match ('(?m)^{0} = ' -f [regex]::Escape($name)) -Because ('{0} is only for a copy imported before 2026-11-14' -f $name)
                continue
            }
            $cell | Should -Match ('(?m)^{0} = ' -f [regex]::Escape($name)) -Because ('{0} must override the cell''s own value' -f $name)
        }
        @($parameters.Keys | Where-Object { $legacy -contains $_ }).Count | Should -Be 3
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
        # The resolver's lakehouse record when it isn't resolved; by default, a list that answered without it.
        $script:lakehouseRecord = $null
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
            $lakehouse = if ($null -ne $script:lakehouseRecord) { $script:lakehouseRecord } else { New-DemoResult -CheckId 'FABRIC.RESOLVE.LAKEHOUSE' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'The lakehouse "LH_DatabaseHub" isn''t in the workspace "Database Hub Demo".' }
            [pscustomobject]@{ Resolved = $false; Config = $copy; WorkspaceId = $script:workspaceId; WorkspaceName = 'Database Hub Demo'; LakehouseId = ''; Results = @(
                    (New-DemoResult -CheckId 'FABRIC.RESOLVE.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Found the workspace.')
                    $lakehouse
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
        # The Incident RCA's export (2026-11-20) has its own tests below; here it finds nothing, as on a demo without a runner.
        $script:rcaExport = [pscustomobject]@{ Evidence = ''; Documents = @(); Pending = @(); PendingFound = $false; Results = @(New-DemoResult -CheckId 'DEPLOY.RCA.EXPORT' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message 'No workload runner was deployed, so there''s no RCA evidence to export.') }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRcaScriptExport -MockWith { $script:rcaExport }

        $script:progress = Join-Path -Path $TestDrive -ChildPath ('progress-' + [guid]::NewGuid().ToString('N') + '.json')
        InModuleScope DbHubDemo -Parameters @{ Path = $script:progress } { Initialize-DemoProgress -Path $Path -Model (New-DemoProgressModel -Catalog (Get-DemoProgressCatalog)) -Confirm:$false }
        $script:requirement = @(InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'JumpstartImage' })
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

    It 'sends T5''s Azure Monitor metrics as COSMOS_METRICS when there are some, and says so in its evidence (2026-11-18, ADR 0027)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCosmosHistoryCapture -MockWith { [pscustomobject]@{ Json = '{"version":1,"accounts":[{"target":"T5","resourceName":"cosmos01-abc123"}]}'; Result = (New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'T5' -Status 'Pass' -Message 'captured') } }
        $record = & $script:invoke
        $record.status | Should -Be 'Pass'
        $record.evidence.parameters.COSMOS_METRICS | Should -Be 'sent'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCosmosHistoryCapture -Times 1 -Exactly -ParameterFilter { $WindowMinutes -eq 1440 -and $CheckId -eq 'DEPLOY.FABRIC.HISTORY.T5' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 1 -Exactly -ParameterFilter { $Parameter['COSMOS_METRICS'] -eq '{"version":1,"accounts":[{"target":"T5","resourceName":"cosmos01-abc123"}]}' }
        # Nothing to send: no parameter, and no Warning in the log either way.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCosmosHistoryCapture -MockWith { [pscustomobject]@{ Json = ''; Result = (New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'T5' -Status 'Not selected' -Message 'T5 is turned off.') } }
        $record = & $script:invoke
        $record.evidence.parameters.COSMOS_METRICS | Should -Be ''
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 1 -Exactly -ParameterFilter { -not $Parameter.Contains('COSMOS_METRICS') }
        @($script:warned).Count | Should -Be 0
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

    It 'is the same Warning, never "didn''t create", when Fabric refused the lakehouse list because the capacity is paused (live finding, 2026-11-10)' {
        $script:resolved = $false
        $error404 = 'HTTP 404: CapacityNotActive: Internal error CapacityNotActive.Capacity is not active.'
        $script:lakehouseRecord = New-DemoResult -CheckId 'FABRIC.RESOLVE.LAKEHOUSE' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message ('The lakehouses in the workspace "Database Hub Demo" couldn''t be listed, because its capacity is paused or inactive: {0}' -f $error404) -Evidence ([ordered]@{ lakehouseName = 'LH_DatabaseHub'; statusCode = 404; listed = $false; error = $error404; capacityInactive = $true })
        $record = & $script:invoke
        $record.status | Should -Be 'Warning'
        $record.evidence.outcome | Should -Be 'CapacityPaused'
        $record.evidence.ContainsKey('reportedStatus') | Should -BeFalse
        $record.message | Should -Be 'The history report got no snapshot: the workspace''s capacity isn''t running (HTTP 404: CapacityNotActive: Internal error CapacityNotActive.Capacity is not active), so NB_DatabaseHub_LiveActivity couldn''t run. deploy.ps1 never resumes, pauses, or scales a capacity.'
        $record.message | Should -Not -Match 'didn''t create'
        $record.remediation | Should -Match '^Resume the capacity, or ask its administrator to'
        foreach ($command in 'Invoke-DemoFabricNotebookRun', 'Invoke-DemoSemanticModelRefresh', 'Resume-DemoFabricCapacity', 'Suspend-DemoFabricCapacity', 'Invoke-DemoFabricCapacityTransition') {
            Should -Invoke -ModuleName DbHubDemo -CommandName $command -Times 0 -Exactly
        }
        (Get-TestRow -Path $script:progress)['state'] | Should -Be 'Action needed'
    }

    It 'says the Fabric items couldn''t be read, never "didn''t create", when the lakehouse list failed otherwise: <Case>' -ForEach @(
        @{ Case = 'HTTP 503'; Status = 'Fail'; Code = 503; ListError = 'HTTP 503: ServiceUnavailable: Try again later.' }
        @{ Case = 'HTTP 403'; Status = 'Manual action required'; Code = 403; ListError = 'HTTP 403: InsufficientPrivileges: The caller does not have sufficient permissions.' }
    ) {
        $script:resolved = $false
        $script:lakehouseRecord = New-DemoResult -CheckId 'FABRIC.RESOLVE.LAKEHOUSE' -Area 'fabric' -Target 'fabric' -Status $Status -Message ('The lakehouses in the workspace "Database Hub Demo" couldn''t be listed: {0}' -f $ListError) -Evidence ([ordered]@{ lakehouseName = 'LH_DatabaseHub'; statusCode = $Code; listed = $false; error = $ListError })
        $record = & $script:invoke
        $record.status | Should -Be 'Warning'
        $record.evidence.outcome | Should -Be 'Failed'
        $record.evidence.reportedStatus | Should -Be 'Fail'
        $record.message | Should -Match ('^The history report got no snapshot: the Fabric workspace and lakehouse couldn''t be read\. FABRIC\.RESOLVE\.LAKEHOUSE: .*HTTP {0}' -f $Code)
        $record.message | Should -Not -Match 'didn''t create'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 0 -Exactly
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

Describe 'The Incident RCA''s evidence from the scripts (2026-11-20, ADR 0031)' {
    BeforeAll {
        $script:rcaRoot = Join-Path -Path $repoRoot -ChildPath 'rca'
        $script:transportSchemaPath = Join-Path -Path $script:rcaRoot -ChildPath 'transport.schema.json'
        $script:inboxPattern = (Get-Content -LiteralPath $script:transportSchemaPath -Raw | ConvertFrom-Json -AsHashtable)['$defs']['evidenceFile']['pattern']
        # The two fixture documents from sqlvm01 (T1's blocking chain; T4's chain and its replica's lag), by document ID.
        $script:fixtureParts = [ordered]@{}
        foreach ($file in @(Get-ChildItem -Path (Join-Path -Path $script:rcaRoot -ChildPath 'fixtures') -Filter '*.parts.txt' -File | Sort-Object -Property Name)) {
            $lines = @(Get-Content -LiteralPath $file.FullName | Where-Object { $_ })
            $script:fixtureParts[$lines[0].Split(' ')[2]] = [string[]]$lines
        }

        # A document from T2's guest, gzipped and cut into part lines the way the runner's export does (rca/README.md, Part
        # lines); -NoiseBytes of incompressible text make it span several parts.
        function New-TestRcaPart([string] $DocumentId, [int] $NoiseBytes = 0) {
            $random = [System.Random]::new(7)
            $noise = [byte[]]::new($NoiseBytes)
            $random.NextBytes($noise)
            $document = [ordered]@{
                kind = 'ContosoCare.RcaEvidence'; version = 1; documentId = $DocumentId; sessionId = $null; producer = 'ContosoCare.Workload test'
                exportedUtc = '2026-11-20T17:31:00.000Z'; sequence = 1; final = $true; windowStartUtc = '2026-11-20T17:00:00.000Z'; windowEndUtc = '2026-11-20T17:15:00.000Z'
                targets = @('T2'); epochUtc = '2026-11-20T17:00:00.000Z'; strings = @('T2', 'RCA-SQL-09', [System.Convert]::ToBase64String($noise))
                tables = [ordered]@{ rca_coverage = [ordered]@{ rows = 1; columns = [ordered]@{ target = @(0); window_start_utc = @(0); window_end_utc = @(900000); captured = @($true); sources = @(1) } } }
                answerKey = [ordered]@{}
            }
            $plain = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $document -Depth 10 -Compress))
            $memory = [System.IO.MemoryStream]::new()
            $gzip = [System.IO.Compression.GZipStream]::new($memory, [System.IO.Compression.CompressionLevel]::Optimal, $true)
            $gzip.Write($plain, 0, $plain.Length)
            $gzip.Dispose()
            $bytes = $memory.ToArray()
            $sha = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            $count = [int][System.Math]::Ceiling($bytes.Length / 2400.0)
            return [string[]]@(for ($index = 0; $index -lt $count; $index++) {
                    'DBHUBDEMO-RCA 1 {0} {1}/{2} {3} {4}' -f $DocumentId, ($index + 1), $count, $sha, [System.Convert]::ToBase64String($bytes, $index * 2400, [System.Math]::Min(2400, $bytes.Length - $index * 2400))
                })
        }

        # What one Rca Run Command prints on a fake VM: the VM-side control's result line, then the runner's line.
        function Get-TestRcaOutput([string] $Vm, [System.Collections.IDictionary] $Request) {
            $line = { param([string] $Status, [string] $Message, [string] $Evidence = '{}') 'DBHUBDEMO-WORKLOAD {{"marker":"DBHUBDEMO-WORKLOAD","action":"Rca","status":"{0}","message":"{1}","evidence":{2}}}' -f $Status, $Message, $Evidence }
            if ($Request['command'] -eq 'export') {
                if ($script:fake.ExportOutput.Contains($Vm)) {
                    return $script:fake.ExportOutput[$Vm]
                }
                $documents = @(foreach ($id in @($script:fake.Listed[$Vm])) {
                        $lines = $script:fake.Stored[$Vm][$id]
                        [ordered]@{ documentId = $id; parts = $lines.Count; sha256 = $lines[0].Split(' ')[4] }
                    })
                if ($documents.Count -eq 0) {
                    return (& $line 'Not selected' 'runner rca export: nothing was captured since the last export.')
                }
                $index = ConvertTo-Json -InputObject ([ordered]@{ kind = 'ContosoCare.RcaExportIndex'; version = 1; documents = $documents; status = 'Pass'; message = 'exported' }) -Depth 5 -Compress
                return ((& $line 'Pass' 'runner rca export: its line follows.') + "`n" + 'DBHUBDEMO-RCA-INDEX ' + $index)
            }
            if ($script:fake.Hang.Contains(('{0}/{1}' -f $Request['documentId'], $Request['part']))) {
                return $null
            }
            $stored = $script:fake.Stored[$Vm]
            if (-not $stored.Contains([string]$Request['documentId'])) {
                return (& $line 'Fail' 'runner rca part: exit code 1.')
            }
            return ((& $line 'Pass' 'runner rca part: its line follows.') + "`n" + $stored[[string]$Request['documentId']][[int]$Request['part'] - 1])
        }

        # Managed Run Command on two fake VMs, through the module's one Azure CLI door (Invoke-DemoAz): create, read, list,
        # and delete. A delete on the T2 host takes one more read before the Run Command is gone, as Azure's do.
        function Initialize-TestRunCommandAzure {
            $script:t2Lines = New-TestRcaPart -DocumentId '20261120T170000Z-arcsql01-0001' -NoiseBytes 4000
            $script:fake = @{
                Commands     = @{ sqlvm01 = [ordered]@{}; archost01 = [ordered]@{} }
                Stored       = @{ sqlvm01 = [ordered]@{}; archost01 = [ordered]@{ '20261120T170000Z-arcsql01-0001' = $script:t2Lines } }
                Listed       = @{ sqlvm01 = @($script:fixtureParts.Keys); archost01 = @('20261120T170000Z-arcsql01-0001') }
                ExportOutput = [ordered]@{}
                Hang         = [ordered]@{}
                DeleteReads  = @{ sqlvm01 = 0; archost01 = 1 }
                MostAtOnce   = @{ sqlvm01 = 0; archost01 = 0 }
                Requests     = [System.Collections.Generic.List[object]]::new()
                Deleted      = [System.Collections.Generic.List[string]]::new()
                Calls        = [System.Collections.Generic.List[string]]::new()
            }
            foreach ($id in $script:fixtureParts.Keys) {
                $script:fake.Stored['sqlvm01'][$id] = $script:fixtureParts[$id]
            }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
                $list = @($ArgumentList)
                $script:fake.Calls.Add(($list -join ' '))
                $method = [string]$list[[array]::IndexOf($list, '--method') + 1]
                $url = [string]$list[[array]::IndexOf($list, '--url') + 1]
                $answer = { param([object] $Body) [pscustomobject]@{ ExitCode = 0; StdOut = $(if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 8 -Compress } else { '' }); StdErr = '' } }
                $gone = [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (NotFound) The Resource was not found.' }
                if ($list[0] -ne 'rest' -or $url -notmatch '^https://management\.azure\.com/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/virtualMachines/(?<vm>[^/]+)/runCommands(/(?<name>[^?]+))?\?api-version=') {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'not a Run Command call' }
                }
                $vm = $Matches['vm']
                $name = $Matches['name']
                $commands = $script:fake.Commands[$vm]
                if ($method -eq 'put') {
                    $body = Get-Content -LiteralPath ([string]$list[[array]::IndexOf($list, '--body') + 1]).Substring(1) -Raw | ConvertFrom-Json
                    $encoded = [regex]::Match([string]$body.properties.source.script, "-RequestBase64 '([A-Za-z0-9+/=]+)'").Groups[1].Value
                    $request = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded)) | ConvertFrom-Json -AsHashtable
                    $commands[$name] = @{ Request = $request; Reads = 0; Deleting = -1 }
                    $script:fake.Requests.Add([pscustomobject]@{ Vm = $vm; Name = $name; Request = $request; Action = [regex]::Match([string]$body.properties.source.script, "-Action '([A-Za-z]+)'").Groups[1].Value; AsyncExecution = $body.properties.asyncExecution })
                    $script:fake.MostAtOnce[$vm] = [System.Math]::Max($script:fake.MostAtOnce[$vm], $commands.Count)
                    return (& $answer @{})
                }
                if ($method -eq 'delete') {
                    if ($commands.Contains($name)) {
                        $script:fake.Deleted.Add(('{0}/{1}' -f $vm, $name))
                        if ($script:fake.DeleteReads[$vm] -le 0) {
                            $commands.Remove($name)
                        }
                        elseif ($commands[$name].Deleting -lt 0) {
                            $commands[$name].Deleting = $script:fake.DeleteReads[$vm]
                        }
                    }
                    return (& $answer $null)
                }
                if (-not $name) {
                    return (& $answer @{ value = @($commands.Keys | ForEach-Object { @{ name = $_; properties = @{ provisioningState = 'Succeeded'; instanceView = @{ executionState = 'Running' } } } }) })
                }
                if (-not $commands.Contains($name)) {
                    return $gone
                }
                $entry = $commands[$name]
                if ($entry.Deleting -ge 0) {
                    if ($entry.Deleting -eq 0) {
                        $commands.Remove($name)
                        return $gone
                    }
                    $entry.Deleting--
                    return (& $answer @{ properties = @{ provisioningState = 'Deleting'; instanceView = @{ executionState = 'Succeeded' } } })
                }
                $entry.Reads++
                $output = Get-TestRcaOutput -Vm $vm -Request $entry.Request
                if ($null -eq $output -or $entry.Reads -lt 2) {
                    return (& $answer @{ properties = @{ provisioningState = 'Creating'; instanceView = @{ executionState = 'Running' } } })
                }
                return (& $answer @{ properties = @{ provisioningState = 'Succeeded'; instanceView = @{ executionState = 'Succeeded'; exitCode = 0; output = $output; startTime = '2026-11-20T17:31:00Z' } } })
            }
        }
    }

    BeforeEach {
        $script:config = New-TestConfig
        $script:state = [pscustomobject]@{ RunnerSha256 = ('ab' * 32); RunnerSentTo = @('sqlvm01', 'archost01'); Tags = @{ deploymentId = 'abc123' } }
        $script:power = @{ sqlvm01 = 'PowerState/running'; archost01 = 'PowerState/running' }
        $script:pendingDirectory = Join-Path -Path $TestDrive -ChildPath ('pending-' + [guid]::NewGuid().ToString('N'))
        # A clock that moves 5 seconds a read, so a deadline comes without waiting for it.
        $script:clock = [datetime]::new(2026, 11, 20, 17, 30, 0, [System.DateTimeKind]::Utc)
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $script:clock = $script:clock.AddSeconds(5); $script:clock }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Initialize-TestRunCommandAzure
        $script:export = {
            param([hashtable] $Extra = @{})
            $arguments = @{ Config = $script:config; CheckPrefix = 'STOP'; Final = $true; State = $script:state; Power = $script:power; PendingDirectory = $script:pendingDirectory; PollSeconds = 1 }
            foreach ($key in $Extra.Keys) {
                $arguments[$key] = $Extra[$key]
            }
            InModuleScope DbHubDemo -Parameters @{ Arguments = $arguments } { Invoke-DemoRcaScriptExport @Arguments }
        }
    }

    It 'exports every document from both VMs through managed Run Commands and builds one RCA_EVIDENCE document the contract accepts' {
        $export = & $script:export
        $schemaErrors = $null
        Test-Json -Json $export.Evidence -SchemaFile $script:transportSchemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors | Should -BeTrue -Because ($schemaErrors | Out-String)
        $evidence = $export.Evidence | ConvertFrom-Json
        $evidence.kind | Should -Be 'ContosoCare.RcaEvidenceParts'
        $evidence.sessionId | Should -BeNullOrEmpty -Because 'the scripts export with --session none: any run writes such a document'
        $expected = @(@($script:fixtureParts.Values | ForEach-Object { $_ }) + @($script:t2Lines))
        @($evidence.parts | Sort-Object) | Should -Be @($expected | Sort-Object)
        $script:t2Lines.Count | Should -BeGreaterThan 1 -Because 'T2''s document spans several parts, which the T2 host fetches one at a time'
        @($export.Documents | ForEach-Object { '{0}@{1}' -f $_['documentId'], $_['vm'] } | Sort-Object) | Should -Be @(@($script:fixtureParts.Keys | ForEach-Object { '{0}@sqlvm01' -f $_ }) + '20261120T170000Z-arcsql01-0001@archost01' | Sort-Object)
        @($export.Pending).Count | Should -Be 0

        $exportResult = @($export.Results | Where-Object { $_.checkId -eq 'STOP.RCA.EXPORT' })[0]
        $exportResult.status | Should -Be 'Pass'
        $exportResult.message | Should -Match ('^3 RCA evidence document\(s\), {0} part\(s\), for the history run\. sqlvm01: 2 document\(s\) in 4 part\(s\)\. archost01: 1 document\(s\) in {1} part\(s\)\.$' -f $expected.Count, $script:t2Lines.Count)
        foreach ($target in 'T1', 'T2', 'T4', 'T4_REPLICA') {
            @($export.Results | Where-Object { $_.checkId -eq ('STOP.RCA.CAPTURE.{0}' -f $target) })[0].status | Should -Be 'Pass' -Because $target
        }
        @($export.Results | Where-Object { $_.checkId -eq 'STOP.RCA.CAPTURE.T3' }) | Should -BeNullOrEmpty -Because 'no document covers T3'

        # The runner's commands (rca/README.md): one export per VM with --final and no session, then one part per Run Command.
        $exports = @($script:fake.Requests | Where-Object { $_.Request['command'] -eq 'export' })
        @($exports | ForEach-Object { $_.Vm } | Sort-Object) | Should -Be @('archost01', 'sqlvm01')
        foreach ($item in $exports) {
            $item.Request['final'] | Should -BeTrue
            $item.Request['sessionId'] | Should -Be ''
        }
        @($script:fake.Requests | Where-Object { $_.Request['command'] -eq 'part' }).Count | Should -Be $expected.Count
        foreach ($item in $script:fake.Requests) {
            $item.Action | Should -Be 'Rca'
            $item.AsyncExecution | Should -BeFalse
            $item.Name | Should -Match ('^DbHubDemo-Rca-{0}-(x|[0-9]{{4}})-[0-9]{{14}}$' -f $item.Vm)
        }
        # Every Run Command is deleted once it's read, so no part of the evidence stays in an instance view; the T2 host gets
        # one at a time, each gone before the next (R871).
        @($script:fake.Deleted | Sort-Object) | Should -Be @($script:fake.Requests | ForEach-Object { '{0}/{1}' -f $_.Vm, $_.Name } | Sort-Object)
        $script:fake.MostAtOnce['archost01'] | Should -Be 1
        $script:fake.MostAtOnce['sqlvm01'] | Should -BeGreaterThan 1 -Because 'sqlvm01''s parts go in parallel'
        $script:fake.MostAtOnce['sqlvm01'] | Should -BeLessOrEqual 11
        # Nothing but managed Run Commands: no role assignment, no other Azure call.
        @($script:fake.Calls | Where-Object { $_ -notmatch '^rest --method (get|put|delete) --url https://management\.azure\.com/.+/virtualMachines/(sqlvm01|archost01)/runCommands' }) | Should -BeNullOrEmpty
        @($script:fake.Calls | Where-Object { $_ -match '(?i)role|assignment|grant' }) | Should -BeNullOrEmpty
    }

    It 'decodes the fixtures'' parts to the fixture documents, and refuses a document with a missing or broken part' {
        foreach ($id in $script:fixtureParts.Keys) {
            $expanded = InModuleScope DbHubDemo -Parameters @{ L = $script:fixtureParts[$id] } { Expand-DemoRcaDocument -Line $L }
            $expanded.Ok | Should -BeTrue
            $name = if ($id -like '*-0001') { 't1-blocking-chain' } else { 't4-replica-lag' }
            $fixture = Get-Content -LiteralPath (Join-Path -Path $script:rcaRoot -ChildPath ('fixtures/{0}.evidence.json' -f $name)) -Raw | ConvertFrom-Json -AsHashtable
            (ConvertTo-Json -InputObject $expanded.Document -Depth 30 -Compress) | Should -BeExactly (ConvertTo-Json -InputObject $fixture -Depth 30 -Compress)
        }
        $lines = [string[]]$script:fixtureParts[0]
        (InModuleScope DbHubDemo -Parameters @{ L = [string[]]@($lines[0]) } { Expand-DemoRcaDocument -Line $L }).Why | Should -Be '1 of its 2 part(s) arrived'
        $broken = [string[]]@($lines[0], ($lines[1] -replace '.{8}$', 'AAAAAAA='))
        (InModuleScope DbHubDemo -Parameters @{ L = $broken } { Expand-DemoRcaDocument -Line $L }).Why | Should -Be 'its SHA-256 doesn''t match'
    }

    It 'says so, with ./scripts/deploy.ps1 as the fix, when a VM''s runner or bootstrap bundle is from the release before the export' {
        $script:fake.ExportOutput['sqlvm01'] = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"Rca","status":"Not supported","message":"runner rca export: this VM''s runner predates the RCA export (ADR 0031), so nothing was exported; ./scripts/deploy.ps1 updates it.","evidence":{"oldRunner":true}}'
        $script:fake.ExportOutput['archost01'] = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"Rca","status":"Fail","message":"Unknown action; use EnableT3, EnableT4, Runner, or StopGuest.","evidence":{}}'
        $export = & $script:export
        $export.Evidence | Should -BeNullOrEmpty
        $exportResult = @($export.Results | Where-Object { $_.checkId -eq 'STOP.RCA.EXPORT' })[0]
        $exportResult.status | Should -Be 'Warning'
        $exportResult.message | Should -Match 'sqlvm01''s workload runner predates the RCA export, so nothing was exported from it; \./scripts/deploy\.ps1 updates it\.'
        $exportResult.message | Should -Match 'archost01''s bootstrap bundle predates the RCA export'
        $exportResult.remediation | Should -Match '^Run \./scripts/deploy\.ps1, which updates the runner and its bootstrap bundle on the VMs\.'
        $capture = @($export.Results | Where-Object { $_.checkId -eq 'STOP.RCA.CAPTURE.T1' })[0]
        $capture.status | Should -Be 'Warning'
        $capture.message | Should -Match '^T1: not exported\. '
        $capture.remediation | Should -Match 'deploy\.ps1'
        @($script:fake.Requests | Where-Object { $_.Request['command'] -eq 'part' }) | Should -BeNullOrEmpty
    }

    It 'is Not selected, and sends nothing, when no runner was deployed or the VMs don''t run' {
        $export = & $script:export @{ State = [pscustomobject]@{ RunnerSha256 = ''; RunnerSentTo = @() } }
        @($export.Results)[0].status | Should -Be 'Not selected'
        @($export.Results)[0].message | Should -Be 'No workload runner was deployed, so there''s no RCA evidence to export.'
        $export = & $script:export @{ Power = @{ sqlvm01 = 'PowerState/deallocated'; archost01 = 'PowerState/deallocated' } }
        @($export.Results)[0].status | Should -Be 'Not selected'
        @($export.Results)[0].message | Should -Match 'sqlvm01 isn''t running, so what its observer captured stays on it until the next export\.'
        @($export.Results).Count | Should -Be 1
        $script:fake.Requests.Count | Should -Be 0
    }

    It 'keeps what a save didn''t take in out/history-pending, fetches it again at the next save, and removes the list once it''s saved' {
        # T2's first part never ends before the deadline: its document stays on the T2 host.
        $script:fake.Hang['20261120T170000Z-arcsql01-0001/1'] = $true
        $first = & $script:export @{ Minutes = 2 }
        @($first.Pending | ForEach-Object { $_['documentId'] }) | Should -Be @('20261120T170000Z-arcsql01-0001')
        @($first.Documents).Count | Should -Be 2
        $exportResult = @($first.Results | Where-Object { $_.checkId -eq 'STOP.RCA.EXPORT' })[0]
        $exportResult.status | Should -Be 'Warning'
        $exportResult.message | Should -Match 'archost01: 0 document\(s\) in 0 part\(s\)\. 1 document\(s\) weren''t fetched whole in time; they stay on archost01 for the next save\.'
        # The Run Command that didn't end is deleted at the deadline.
        @($script:fake.Deleted | Where-Object { $_ -like 'archost01/DbHubDemo-Rca-archost01-0101-*' }).Count | Should -Be 1

        # The run took the two documents it got; T2's is kept.
        $pending = InModuleScope DbHubDemo -Parameters @{ C = $script:config; E = $first; D = $script:pendingDirectory } { Save-DemoRcaPending -Config $C -CheckPrefix STOP -Export $E -Saved -Directory $D -Confirm:$false }
        $pending.checkId | Should -Be 'STOP.RCA.PENDING'
        $pending.status | Should -Be 'Warning'
        $pending.message | Should -Match '^1 RCA evidence document\(s\) aren''t in the history yet\. The runner keeps them on archost01 for 7 days'
        $pending.remediation | Should -Match 'stop-demo\.ps1 -SaveHistory'
        $file = Join-Path -Path $script:pendingDirectory -ChildPath 'rca-pending-rg-dbhub-demo.json'
        $kept = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $kept.kind | Should -Be 'DbHubDemo.RcaPending'
        @($kept.documents.documentId) | Should -Be @('20261120T170000Z-arcsql01-0001')
        (Get-Content -LiteralPath $file -Raw) | Should -Not -Match 'DBHUBDEMO-RCA ' -Because 'the list holds references, none of the evidence'

        # The next save: nothing new to export, and the pending document is fetched again from the runner, which keeps it.
        $script:fake.Hang.Clear()
        $script:fake.Listed['sqlvm01'] = @()
        $script:fake.Listed['archost01'] = @()
        $second = & $script:export
        $second.PendingFound | Should -BeTrue
        @($second.Documents | ForEach-Object { $_['documentId'] }) | Should -Be @('20261120T170000Z-arcsql01-0001')
        @(($second.Evidence | ConvertFrom-Json).parts) | Should -Be $script:t2Lines
        @($second.Results | Where-Object { $_.checkId -eq 'STOP.RCA.EXPORT' })[0].status | Should -Be 'Pass'
        # Not saved this time (a paused capacity, say): it stays listed.
        $again = InModuleScope DbHubDemo -Parameters @{ C = $script:config; E = $second; D = $script:pendingDirectory } { Save-DemoRcaPending -Config $C -CheckPrefix STOP -Export $E -Why 'the history run didn''t complete' -Directory $D -Confirm:$false }
        $again.message | Should -Match '^1 RCA evidence document\(s\) aren''t in the history yet: the history run didn''t complete\.'
        Test-Path -LiteralPath $file | Should -BeTrue
        # Saved: the list goes.
        (InModuleScope DbHubDemo -Parameters @{ C = $script:config; E = $second; D = $script:pendingDirectory } { Save-DemoRcaPending -Config $C -CheckPrefix STOP -Export $E -Saved -Directory $D -Confirm:$false }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $file | Should -BeFalse
    }

    It 'stages the evidence in Files/rca/inbox with the operator''s Storage token, passes RCA_EVIDENCE_FILE, and deletes the file once the job ended' {
        $script:lake = [ordered]@{}
        $script:oneLake = [System.Collections.Generic.List[string]]::new()
        $script:jobStatus = 'Completed'
        $script:seenAtRun = ''
        Mock -ModuleName DbHubDemo -CommandName Get-DemoStorageToken -MockWith { [securestring]::new() }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoOneLakeRequest -MockWith {
            $script:oneLake.Add(('{0} {1}?{2}' -f $Method, $Path, $Query))
            $key = $Path.Substring(37)
            switch ($Method) {
                'Put' { $script:lake[$key] = ''; return [pscustomobject]@{ StatusCode = 201; Headers = @{}; Content = '' } }
                'Patch' {
                    if ($Query -like 'action=append*') { $script:lake[$key] += [System.Text.Encoding]::UTF8.GetString($Body); return [pscustomobject]@{ StatusCode = 202; Headers = @{}; Content = '' } }
                    return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '' }
                }
                'Delete' {
                    $children = @($script:lake.Keys | Where-Object { $_ -like ($key + '/*') })
                    if ($children.Count -gt 0) { return [pscustomobject]@{ StatusCode = 409; Headers = @{}; Content = '{"error":{"code":"DirectoryNotEmpty"}}' } }
                    $script:lake.Remove($key)
                    return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '' }
                }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricNotebookParameter -MockWith { [pscustomobject]@{ Known = $true; Has = $true; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -MockWith {
            $script:seenAtRun = [string]$script:lake[[string]$Parameter['RCA_EVIDENCE_FILE']]
            $status = switch ($script:jobStatus) { 'Completed' { 'Pass' } 'Failed' { 'Fail' } default { 'Warning' } }
            New-DemoResult -CheckId 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY' -Area 'fabric' -Target 'fabric' -Status $status -Message 'ran' -Evidence @{ status = $script:jobStatus; seconds = 90 }
        }
        $resolved = @{ subscriptionId = '11111111-2222-3333-4444-555555555555'; fabric = @{ workspaceId = $script:workspaceId; lakehouseId = $script:lakehouseId } }
        $evidence = (& $script:export).Evidence
        $runIt = { InModuleScope DbHubDemo -Parameters @{ C = $resolved; E = $evidence } { Invoke-DemoRcaNotebookRun -Config $C -Parameter ([ordered]@{ SAVE_RESULTS = $true }) -Token ([securestring]::new()) -Evidence $E } }

        $run = & $runIt
        $run.RcaSent | Should -BeTrue
        $run.RcaSaved | Should -BeTrue
        $run.RcaFile | Should -Match $script:inboxPattern
        $run.RcaFile | Should -Match '^Files/rca/inbox/[0-9]{8}T[0-9]{6}Z-[a-z0-9-]{1,64}\.json$' -Because 'the notebook''s day-old sweep reads the time in the name'
        $script:seenAtRun | Should -BeExactly $evidence -Because 'the notebook reads the file the run names'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 1 -Exactly -ParameterFilter { $Name -eq 'NB_DatabaseHub_LiveActivity' -and $Parameter['RCA_EVIDENCE_FILE'] -match '^Files/rca/inbox/' -and -not $Parameter.Contains('RCA_EVIDENCE') }
        # The file, then the empty inbox and Files/rca: nothing is left in Files/.
        @($script:lake.Keys) | Should -BeNullOrEmpty
        @($script:oneLake | Where-Object { $_ -like 'Delete *' }) | Should -Be @(('Delete {0}/{1}?' -f $script:lakehouseId, $run.RcaFile), ('Delete {0}/Files/rca/inbox?recursive=false' -f $script:lakehouseId), ('Delete {0}/Files/rca?recursive=false' -f $script:lakehouseId))
        @($script:oneLake | Where-Object { $_ -notmatch ('^(Put|Patch|Delete) {0}/Files/rca(/inbox(/[^?]+)?)?\?' -f $script:lakehouseId) }) | Should -BeNullOrEmpty -Because 'only the inbox in the demo lakehouse is touched'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoStorageToken -ParameterFilter { $SubscriptionId -eq '11111111-2222-3333-4444-555555555555' }

        # A job still running reads the file itself, and deletes it: it stays.
        $script:jobStatus = 'InProgress'
        $script:oneLake.Clear()
        $run = & $runIt
        $run.RcaSaved | Should -BeFalse
        $run.RcaNote | Should -Be 'the history run was still going when the wait ended'
        @($script:oneLake | Where-Object { $_ -like 'Delete *' }) | Should -BeNullOrEmpty
        $script:lake.Clear()

        # A failed job: the file goes, and the documents stay pending (RcaSaved false).
        $script:jobStatus = 'Failed'
        $run = & $runIt
        $run.RcaSaved | Should -BeFalse
        $run.RcaNote | Should -Be 'the history run didn''t complete'
        @($script:lake.Keys) | Should -BeNullOrEmpty

        # The current release's notebook, from before the Incident RCA: nothing is staged, and the run goes as before.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricNotebookParameter -MockWith { [pscustomobject]@{ Known = $true; Has = $false; Error = '' } }
        $script:jobStatus = 'Completed'
        $script:oneLake.Clear()
        $run = & $runIt
        $run.RcaSent | Should -BeFalse
        $run.RcaNote | Should -Be 'the workspace''s NB_DatabaseHub_LiveActivity is from before the Incident RCA (2026-11-20), so it would ignore it'
        $script:oneLake | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -ParameterFilter { -not $Parameter.Contains('RCA_EVIDENCE_FILE') } -Times 1 -Exactly
    }
}

Describe 'deploy.ps1''s history snapshot with the Incident RCA''s evidence (2026-11-20, ADR 0031)' {
    BeforeEach {
        $script:config = New-TestConfig
        $script:requirement = @(InModuleScope DbHubDemo { Get-DemoDoneRequirement -InstallMode 'JumpstartImage' })
        $script:done = @(New-DoneResult)
        $script:knowsFile = $true
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'unexpected Azure CLI call' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { [securestring]::new() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoPowerBIToken -MockWith { [securestring]::new() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoPostgresHistoryCapture -MockWith { $null }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCosmosHistoryCapture -MockWith { [pscustomobject]@{ Json = ''; Result = $null } }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith {
            $copy = @{ subscriptionId = '11111111-2222-3333-4444-555555555555'; tenantId = '66666666-7777-8888-9999-000000000000'; prefix = 'dbhub'; environment = 'demo'; fabric = @{ workspaceName = 'Database Hub Demo'; lakehouseName = 'LH_DatabaseHub'; workspaceId = $script:workspaceId; lakehouseId = $script:lakehouseId } }
            [pscustomobject]@{ Resolved = $true; Config = $copy; WorkspaceId = $script:workspaceId; WorkspaceName = 'Database Hub Demo'; LakehouseId = $script:lakehouseId; Results = @() }
        }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -MockWith { New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'capacity' -Evidence @{ state = 'Active'; capacityName = 'fabcap01' } }
        Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith { [pscustomobject]@{ StatusCode = 200; Items = @([pscustomobject]@{ id = $script:notebookId; displayName = 'NB_DatabaseHub_LiveActivity'; type = 'Notebook' }); Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -MockWith { New-DemoResult -CheckId 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'ran' -Evidence ([ordered]@{ status = 'Completed'; seconds = 140 }) }
        Mock -ModuleName DbHubDemo -CommandName Find-DemoSemanticModel -MockWith { [pscustomobject]@{ StatusCode = 200; Id = $script:modelId; Count = 1; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoSemanticModelRefresh -MockWith { New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.REFRESH' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'refreshed' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricNotebookParameter -MockWith { [pscustomobject]@{ Known = $true; Has = $script:knowsFile; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Send-DemoRcaEvidenceFile -MockWith { [pscustomobject]@{ Path = 'Files/rca/inbox/20261120T173000Z-script-1a2b3c4d.json'; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoRcaEvidenceFile -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Save-DemoRcaPending -MockWith {
            if ($Saved) { return $null }
            New-DemoResult -CheckId 'DEPLOY.RCA.PENDING' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('2 RCA evidence document(s) aren''t in the history yet: {0}. The runner keeps them on sqlvm01 for 7 days, and ./out/history-pending/rca-pending-rg-dbhub-demo.json lists them.' -f $Why) -Remediation 'The next history save adds them while the VMs run.' -Evidence @{ documents = @('a', 'b') }
        }
        $script:rcaEvidence = '{"kind":"ContosoCare.RcaEvidenceParts","version":1,"sessionId":null,"parts":["x"]}'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRcaScriptExport -MockWith {
            [pscustomobject]@{
                Evidence = $script:rcaEvidence; Documents = @([ordered]@{ documentId = 'a'; vm = 'sqlvm01' }, [ordered]@{ documentId = 'b'; vm = 'sqlvm01' }); Pending = @(); PendingFound = $false
                Results  = @(
                    (New-DemoResult -CheckId 'DEPLOY.RCA.EXPORT' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message '2 RCA evidence document(s), 4 part(s), for the history run. sqlvm01: 2 document(s) in 4 part(s).')
                    (New-DemoResult -CheckId 'DEPLOY.RCA.CAPTURE.T1' -Area 'workload' -Target 'T1' -Status 'Pass' -Message 'T1: the RCA observer captured.')
                )
            }
        }
        $script:invoke = {
            InModuleScope DbHubDemo -Parameters @{ Arguments = @{ Config = $script:config; Result = $script:done; Requirement = $script:requirement; DoneChecked = $true; Environment = [pscustomobject]@{ GitHubActions = $false } } } { Invoke-DemoHistorySnapshotStep @Arguments }
        }
    }

    It 'exports the evidence, not as a session''s last, passes it as RCA_EVIDENCE_FILE, and says so' {
        $record = & $script:invoke
        $record.status | Should -Be 'Pass'
        $record.evidence.parameters.RCA_EVIDENCE_FILE | Should -Be 'sent'
        $record.evidence.rca.export | Should -Be 'Pass'
        $record.evidence.rca.saved | Should -BeTrue
        @($record.evidence.rca.capture) | Should -Be @('T1: Pass')
        $record.message | Should -Match '2 RCA evidence document\(s\), 4 part\(s\), for the history run\. sqlvm01: 2 document\(s\) in 4 part\(s\)\.$'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRcaScriptExport -Times 1 -Exactly -ParameterFilter { $CheckPrefix -eq 'DEPLOY' -and -not $Final }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 1 -Exactly -ParameterFilter { $Parameter['RCA_EVIDENCE_FILE'] -eq 'Files/rca/inbox/20261120T173000Z-script-1a2b3c4d.json' -and $TimeoutMinutes -eq 10 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoRcaEvidenceFile -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Save-DemoRcaPending -Times 1 -Exactly -ParameterFilter { $Saved -and $CheckPrefix -eq 'DEPLOY' }
    }

    It 'updates an environment whose notebook is from the release before the Incident RCA: the snapshot runs as before, and a Warning says how the evidence follows' {
        $script:knowsFile = $false
        $script:config['fabric']['importNotebooks'] = $false
        $record = & $script:invoke
        $record.status | Should -Be 'Warning'
        $record.evidence.outcome | Should -Be 'Saved' -Because 'the history itself was saved and framed'
        $record.evidence.parameters.RCA_EVIDENCE_FILE | Should -Be ''
        $record.message | Should -Match 'aren''t in the history yet: the workspace''s NB_DatabaseHub_LiveActivity is from before the Incident RCA \(2026-11-20\), so it would ignore it\.'
        $record.remediation | Should -Be 'Run ./scripts/configure-fabric.ps1, which updates the notebook (fabric.importNotebooks is false, so deploy.ps1 keeps the workspace''s copy); the next history save then adds them.'
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoRcaEvidenceFile -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 1 -Exactly -ParameterFilter { -not $Parameter.Contains('RCA_EVIDENCE_FILE') }
        # Never in DONE's way.
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = (@($script:done) + @($record)); State = (New-FinishedState); Config = $script:config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config }
        $outcome.Kind | Should -Be 'Done'
    }
}
