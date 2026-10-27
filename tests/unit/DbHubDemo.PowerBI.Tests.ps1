BeforeAll {
    # Phase 19: the Power BI history report's deploy step. Every request is mocked; no test touches the network, and
    # every ID is an obvious placeholder.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    Initialize-GuardTestContext -SubscriptionId $script:HubSubscriptionId -TenantId $script:HubTenantId
    $script:configurePowerBI = Join-Path -Path $repoRoot -ChildPath 'scripts/configure-powerbi.ps1'
    $script:fabricApi = 'https://api.fabric.microsoft.com/v1'
    $script:pbiApi = 'https://api.powerbi.com/v1.0/myorg'
    $script:workspaceId = '11111111-1111-1111-1111-111111111111'
    $script:lakehouseId = '22222222-2222-2222-2222-222222222222'
    $script:modelId = '33333333-3333-3333-3333-333333333333'
    $script:reportId = '44444444-4444-4444-4444-444444444444'
    $script:refreshId = '77777777-7777-7777-7777-777777777777'
    $script:token = ConvertTo-HubSecureString ('tok' + ('x' * 40))
    # Built at run time: PowerShell files in this repo are ASCII-only.
    $script:pages = @(('1 {0} Estate at a glance' -f [char]0x00B7), ('2 {0} The incident, minute by minute' -f [char]0x00B7), ('3 {0} Signal explorer' -f [char]0x00B7), ('4 {0} Readiness checks' -f [char]0x00B7))
    $script:modelPath = Join-Path -Path $repoRoot -ChildPath 'fabric/powerbi/SM_DatabaseHub_History.SemanticModel'

    function New-WebResponse([int] $Status, [object] $Body, [hashtable] $Headers = @{}) {
        $content = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 30 -Compress } else { '' }
        [pscustomobject]@{ StatusCode = $Status; Headers = $Headers; Content = $content }
    }

    # Records every Invoke-WebRequest call and answers it from routes: @{ Method; Match (regex on the URI); Responses },
    # or a Respond script block that gets the request.
    function Set-WebMock([object[]] $Routes) {
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:routes = foreach ($route in $Routes) {
            # Assign the queue directly: an if expression would unroll it into its items. Indexers keep this safe
            # under Set-StrictMode, where a missing hashtable key read with a dot throws.
            $queue = $null
            if ($route['Responses']) {
                $queue = [System.Collections.Generic.Queue[object]]::new([object[]]$route['Responses'])
            }
            [pscustomobject]@{
                Method    = $route['Method']
                Match     = $route['Match']
                Responses = $queue
                Respond   = $route['Respond']
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $request = [pscustomobject]@{
                Method         = $Method
                Uri            = [string]$Uri
                Body           = Get-Variable -Name 'Body' -ValueOnly -ErrorAction Ignore
                Authentication = Get-Variable -Name 'Authentication' -ValueOnly -ErrorAction Ignore
                Token          = Get-Variable -Name 'Token' -ValueOnly -ErrorAction Ignore
            }
            $requests.Add($request)
            foreach ($route in $routes) {
                if ($route.Method -eq $Method -and [string]$Uri -match $route.Match) {
                    if ($route.Respond) { return (& $route.Respond $request) }
                    if ($route.Responses.Count -gt 1) { return $route.Responses.Dequeue() }
                    return $route.Responses.Peek()
                }
            }
            throw "Unexpected request: $Method $Uri"
        }
    }

    function Get-SentDefinition([object] $Request, [string] $Path) {
        $body = $Request.Body | ConvertFrom-Json -AsHashtable -Depth 64
        $part = @($body['definition']['parts']) | Where-Object { $_['path'] -eq $Path } | Select-Object -First 1
        [System.Text.UTF8Encoding]::new($false).GetString([System.Convert]::FromBase64String($part['payload']))
    }

    # Answers Execute Queries: the row counts, INFO.MEASURES() (refused, as documented), measure batches, and the
    # per-grain retries of blank measures. -Blank and -Broken name measures that return blank or raise a DAX error;
    # -PerGrain names blank measures that return a value for 7 values of the first grain. The responder is a closure
    # with no $script: references, because configure-powerbi.ps1's own script scope is "$script:" while it runs.
    function Get-DaxResponder([string[]] $Blank = @(), [string[]] $Broken = @(), [hashtable] $Rows = @{}, [string[]] $PerGrain = @()) {
        $respond = {
            param($Request)
            $reply = {
                param([int] $Status, [object] $Body)
                [pscustomobject]@{ StatusCode = $Status; Headers = @{}; Content = ($Body | ConvertTo-Json -Depth 30 -Compress) }
            }
            $refusal = { param([string] $Text) & $reply 400 @{ error = @{ code = 'DatasetExecuteQueriesError'; 'pbi.error' = @{ details = @(@{ code = 'DetailsMessage'; detail = @{ type = 1; value = $Text } }) } } } }
            $query = (($Request.Body | ConvertFrom-Json -AsHashtable)['queries'])[0]['query']
            if ($query -match 'INFO\.MEASURES') {
                return (& $refusal 'INFO functions are not supported.')
            }
            $grains = [regex]::Matches($query, '"(?<alias>g\d+)", COUNTROWS \( FILTER \( VALUES \( [^)]+\), NOT ISBLANK \( ''(?:[^'']|'''')+''\[(?<name>[^\]]+)\] \) \) \)')
            if ($grains.Count -gt 0) {
                $row = [ordered]@{}
                foreach ($grain in $grains) {
                    $row[('[{0}]' -f $grain.Groups['alias'].Value)] = if ($PerGrain -contains $grain.Groups['name'].Value -and $grain.Groups['alias'].Value -eq 'g0') { 7 } else { $null }
                }
                return (& $reply 200 @{ results = @(@{ tables = @(@{ rows = @($row) }) }) })
            }
            $columns = [regex]::Matches($query, '"(?<alias>[rm]\d+)", (?<expr>(?:COUNTROWS \( )?''(?<table>(?:[^'']|'''')+)''(?:\[(?<name>[^\]]+)\])?(?: \))?)')
            foreach ($column in $columns) {
                if ($column.Groups['name'].Success -and $Broken -contains $column.Groups['name'].Value) {
                    return (& $refusal ('The measure {0} failed.' -f $column.Groups['name'].Value))
                }
            }
            $row = [ordered]@{}
            foreach ($column in $columns) {
                $alias = '[{0}]' -f $column.Groups['alias'].Value
                if ($column.Groups['alias'].Value.StartsWith('r')) {
                    $table = $column.Groups['table'].Value
                    $row[$alias] = if ($Rows.ContainsKey($table)) { $Rows[$table] } else { 10 }
                }
                elseif ($Blank -contains $column.Groups['name'].Value) {
                    $row[$alias] = $null
                }
                else {
                    $row[$alias] = 1.5
                }
            }
            & $reply 200 @{ results = @(@{ tables = @(@{ rows = @($row) }) }) }
        }
        return $respond.GetNewClosure()
    }

    function New-TestConfigFile {
        $config = Get-HubTestConfig
        $config['fabric']['workspaceId'] = $script:workspaceId
        $config['fabric']['lakehouseId'] = $script:lakehouseId
        $path = Join-Path -Path $TestDrive -ChildPath 'demo.config.json'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        return $path
    }

    $script:itemsUri = '^' + [regex]::Escape("$script:fabricApi/workspaces/$script:workspaceId/items") + '$'
}

AfterAll {
    Initialize-GuardTestContext -Clear
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoFabricSemanticModelDefinition' {
    It 'sends definition.pbism and every TMDL file, with the lakehouse filled in and no placeholder left' {
        $model = Get-DemoFabricSemanticModelDefinition -WorkspaceId $script:workspaceId -LakehouseId $script:lakehouseId
        $model.PSObject.TypeNames | Should -Contain 'DbHubDemo.FabricItemDefinition'
        $model.Type | Should -Be 'SemanticModel'
        $model.DisplayName | Should -Be 'SM_DatabaseHub_History'
        $paths = @($model.Definition.parts | ForEach-Object { $_.path })
        $paths | Should -Contain 'definition.pbism'
        $paths | Should -Contain 'definition/database.tmdl'
        $paths | Should -Contain 'definition/tables/Telemetry Snapshots.tmdl'
        $paths | Should -Not -Contain '.platform'
        @($paths | Where-Object { $_ -match '\\' }) | Should -BeNullOrEmpty
        $model.Evidence.tables | Should -Be 10
        $model.Evidence.measures | Should -Be 103
        $expressions = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((@($model.Definition.parts) | Where-Object { $_.path -eq 'definition/expressions.tmdl' }).payload))
        $expressions | Should -Match ([regex]::Escape("https://onelake.dfs.fabric.microsoft.com/$script:workspaceId/$script:lakehouseId"))
        foreach ($part in $model.Definition.parts) {
            [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($part.payload)) | Should -Not -Match '00000000-0000-0000-0000-000000000000'
        }
        (Get-DemoFabricSemanticModelDefinition -WorkspaceId $script:workspaceId -LakehouseId $script:lakehouseId).Sha256 | Should -Be $model.Sha256
    }

    It 'refuses a folder whose Direct Lake source isn''t the placeholder' {
        $copy = Join-Path -Path $TestDrive -ChildPath 'model'
        Copy-Item -LiteralPath $script:modelPath -Destination $copy -Recurse
        $expressions = Join-Path -Path $copy -ChildPath 'definition/expressions.tmdl'
        (Get-Content -LiteralPath $expressions -Raw).Replace('00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000', "$script:workspaceId/$script:lakehouseId") | Set-Content -LiteralPath $expressions -NoNewline
        { Get-DemoFabricSemanticModelDefinition -Path $copy -WorkspaceId $script:workspaceId -LakehouseId $script:lakehouseId } | Should -Throw '*placeholder exactly once*'
    }
}

Describe 'Get-DemoFabricReportDefinition' {
    It 'binds the PBIR report to the deployed model with the minimal byConnection form' {
        $report = Get-DemoFabricReportDefinition -SemanticModelId $script:modelId
        $report.Type | Should -Be 'Report'
        $report.PageNames | Should -Be $script:pages
        $report.Evidence.visuals | Should -Be 39
        $paths = @($report.Definition.parts | ForEach-Object { $_.path })
        $paths | Should -Contain 'definition/report.json'
        $paths | Should -Contain 'definition/pages/pages.json'
        @($paths | Where-Object { $_ -like 'StaticResources/RegisteredResources/DbHubCockpitDark-*.json' }).Count | Should -Be 1
        $paths | Should -Contain 'StaticResources/SharedResources/BaseThemes/Fluent2-CY26SU10.json'
        $paths | Should -Not -Contain '.platform'
        $pbir = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((@($report.Definition.parts) | Where-Object { $_.path -eq 'definition.pbir' }).payload)) | ConvertFrom-Json -AsHashtable
        $pbir['datasetReference'].Keys | Should -Be @('byConnection')
        $pbir['datasetReference']['byConnection']['connectionString'] | Should -BeExactly "semanticmodelid=$script:modelId"
    }
}

Describe 'Invoke-DemoSemanticModelRefresh' {
    It 'sends nothing under -WhatIf' {
        Set-WebMock @()
        $result = Invoke-DemoSemanticModelRefresh -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -WhatIf
        $result.status | Should -Be 'Not selected'
        $script:requests.Count | Should -Be 0
    }

    It 'posts one enhanced refresh and polls it by its request ID until Completed' {
        $refreshes = "$script:pbiApi/groups/$script:workspaceId/datasets/$script:modelId/refreshes"
        Set-WebMock @(
            @{ Method = 'Post'; Match = ('^' + [regex]::Escape($refreshes) + '$'); Responses = @(New-WebResponse 202 $null @{ 'x-ms-request-id' = @($script:refreshId); Location = @("$refreshes/$script:refreshId") }) }
            @{ Method = 'Get'; Match = ('^' + [regex]::Escape("$refreshes/$script:refreshId") + '$'); Responses = @((New-WebResponse 202 @{ status = 'InProgress' }), (New-WebResponse 200 @{ status = 'Completed'; extendedStatus = 'Completed' })) }
        )
        $result = Invoke-DemoSemanticModelRefresh -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token
        $result.checkId | Should -Be 'FABRIC.SEMANTICMODEL.REFRESH'
        $result.status | Should -Be 'Pass'
        $script:requests.Count | Should -Be 3
        $script:requests[0].Authentication | Should -Be 'Bearer'
        ($script:requests[0].Body | ConvertFrom-Json -AsHashtable) | Should -BeOfType [hashtable]
        $sent = $script:requests[0].Body | ConvertFrom-Json -AsHashtable
        $sent['type'] | Should -Be 'full'
        $sent['commitMode'] | Should -Be 'transactional'
        $sent.ContainsKey('notifyOption') | Should -BeFalse
    }

    It 'reports a failed refresh as Fail with its messages, and a paused capacity as Manual action required' {
        $refreshes = "$script:pbiApi/groups/$script:workspaceId/datasets/$script:modelId/refreshes"
        Set-WebMock @(
            @{ Method = 'Post'; Match = ('^' + [regex]::Escape($refreshes) + '$'); Responses = @(New-WebResponse 202 $null @{ 'x-ms-request-id' = @($script:refreshId) }) }
            @{ Method = 'Get'; Match = [regex]::Escape("$refreshes/$script:refreshId"); Responses = @(New-WebResponse 200 @{ status = 'Failed'; messages = @(@{ code = 'DirectLakeFraming'; message = 'Column report_date_utc was not found.' }) }) }
        )
        $failed = Invoke-DemoSemanticModelRefresh -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token
        $failed.status | Should -Be 'Fail'
        $failed.message | Should -Match 'report_date_utc'

        Set-WebMock @(@{ Method = 'Post'; Match = [regex]::Escape($refreshes); Responses = @(New-WebResponse 404 @{ error = @{ code = 'CapacityNotActive'; message = 'The capacity is paused.' } }) })
        $paused = Invoke-DemoSemanticModelRefresh -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token
        $paused.status | Should -Be 'Manual action required'
        $paused.remediation | Should -Match 'Resume'
    }

    Context 'when Direct Lake can''t see new tables yet (0xC14700DF)' {
        BeforeAll {
            $script:refreshesUri = "$script:pbiApi/groups/$script:workspaceId/datasets/$script:modelId/refreshes"
            # The service's own text, from the live check of 2026-10-27, with the model's table names.
            $script:notVisible = New-WebResponse 200 @{ status = 'Failed'; messages = @(
                    @{ code = ''; message = 'Retry attempts for failures while executing the refresh exceeded the retry limit set on the request.' }
                    @{ code = ''; message = '0xC14700DF We cannot refresh this semantic model because one or multiple source tables either do not exist or access was denied. Please contact a data source admin to verify that the tables exist and ensure that the owner of this semantic model does have read access to these tables: ''Incident Windows,Scenario Runs''' }
                ) }
            $script:posted = New-WebResponse 202 $null @{ 'x-ms-request-id' = @($script:refreshId) }
        }

        It 'refreshes again every -TableRetrySeconds and passes once the tables are visible' {
            Set-WebMock @(
                @{ Method = 'Post'; Match = ('^' + [regex]::Escape($script:refreshesUri) + '$'); Responses = @($script:posted) }
                @{ Method = 'Get'; Match = [regex]::Escape("$script:refreshesUri/$script:refreshId"); Responses = @($script:notVisible, $script:notVisible, (New-WebResponse 200 @{ status = 'Completed'; extendedStatus = 'Completed' })) }
            )
            $result = Invoke-DemoSemanticModelRefresh -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token -TableRetryMinutes 30 -TableRetrySeconds 120
            $result.status | Should -Be 'Pass'
            $result.message | Should -Match 'It took 3 attempts over about 4 minutes'
            $result.evidence.attempts | Should -Be 3
            @($script:requests | Where-Object { $_.Method -eq 'Post' }).Count | Should -Be 3
            Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 120 } -Times 2 -Exactly
        }

        It 'stops after -TableRetryMinutes and keeps the Fail, with both ways out' {
            Set-WebMock @(
                @{ Method = 'Post'; Match = ('^' + [regex]::Escape($script:refreshesUri) + '$'); Responses = @($script:posted) }
                @{ Method = 'Get'; Match = [regex]::Escape("$script:refreshesUri/$script:refreshId"); Responses = @($script:notVisible) }
            )
            $result = Invoke-DemoSemanticModelRefresh -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token -TableRetryMinutes 4 -TableRetrySeconds 120
            $result.status | Should -Be 'Fail'
            $result.message | Should -Match '0xC14700DF'
            $result.message | Should -Match 'still after 3 attempts over about 4 minutes'
            $result.remediation | Should -Match 'wait a few minutes'
            $result.remediation | Should -Match 'SAVE_RESULTS true'
            @($script:requests | Where-Object { $_.Method -eq 'Post' }).Count | Should -Be 3
        }

        It 'sends one refresh without -TableRetryMinutes, and never retries another failure' {
            Set-WebMock @(
                @{ Method = 'Post'; Match = ('^' + [regex]::Escape($script:refreshesUri) + '$'); Responses = @($script:posted) }
                @{ Method = 'Get'; Match = [regex]::Escape("$script:refreshesUri/$script:refreshId"); Responses = @($script:notVisible) }
            )
            (Invoke-DemoSemanticModelRefresh -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token).status | Should -Be 'Fail'
            @($script:requests | Where-Object { $_.Method -eq 'Post' }).Count | Should -Be 1

            Set-WebMock @(
                @{ Method = 'Post'; Match = ('^' + [regex]::Escape($script:refreshesUri) + '$'); Responses = @($script:posted) }
                @{ Method = 'Get'; Match = [regex]::Escape("$script:refreshesUri/$script:refreshId"); Responses = @(New-WebResponse 200 @{ status = 'Failed'; messages = @(@{ code = 'DirectLakeFraming'; message = 'Column report_date_utc was not found.' }) }) }
            )
            $other = Invoke-DemoSemanticModelRefresh -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token -TableRetryMinutes 30
            $other.status | Should -Be 'Fail'
            $other.message | Should -Not -Match 'attempts'
            @($script:requests | Where-Object { $_.Method -eq 'Post' }).Count | Should -Be 1
        }

        It 'is what configure-powerbi.ps1 asks for, for 30 minutes by default' {
            $text = Get-Content -LiteralPath $script:configurePowerBI -Raw
            $text | Should -Match '\[int\] \$RefreshRetryMinutes = 30'
            $text | Should -Match 'Invoke-DemoSemanticModelRefresh [^\r\n]*-TableRetryMinutes \$RefreshRetryMinutes'
        }
    }
}

Describe 'Test-DemoSemanticModelData' {
    BeforeAll {
        $script:queriesUri = '^' + [regex]::Escape("$script:pbiApi/groups/$script:workspaceId/datasets/$script:modelId/executeQueries") + '$'
    }

    It 'evaluates all 103 measures: values Pass, blanks Warning, DAX errors Fail, and INFO.MEASURES() is Not supported' {
        Set-WebMock @(@{ Method = 'Post'; Match = $script:queriesUri; Respond = (Get-DaxResponder -Blank @('Scenario Requests') -Broken @('Focus Verdict') -Rows @{ 'Scenario Runs' = 0 }) })
        $results = @(Test-DemoSemanticModelData -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token)
        $measures = @($results | Where-Object { $_.checkId -like 'FABRIC.SEMANTICMODEL.MEASURE.*' })
        $measures.Count | Should -Be 103
        @($measures.checkId | Sort-Object -Unique).Count | Should -Be 103
        ($results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.MEASURE.SCENARIO_RUNS.SCENARIO_REQUESTS' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.MEASURE.SCENARIO_RUNS.SCENARIO_REQUESTS' }).message | Should -Match 'scenario_runs has no rows yet'
        ($results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.MEASURE.INCIDENT_WINDOWS.FOCUS_VERDICT' }).status | Should -Be 'Fail'
        ($results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.MEASURE.TELEMETRY_SNAPSHOTS.CPU_PCT' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.ROWS' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.INFOMEASURES' }).status | Should -Be 'Not supported'
        $summary = $results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.DATA' }
        $summary.status | Should -Be 'Fail'
        $summary.evidence['blank'] | Should -Be 1
        $summary.evidence['errors'] | Should -Be 1
        @($script:requests | Where-Object { $_.Uri -notmatch $script:queriesUri }) | Should -BeNullOrEmpty
    }

    It 'is a Warning, not a Fail, when measures are blank only because no scenario ran yet' {
        Set-WebMock @(@{ Method = 'Post'; Match = $script:queriesUri; Respond = (Get-DaxResponder -Blank @('Scenario Requests', 'Incidents') -Rows @{ 'Scenario Runs' = 0 }) })
        $results = @(Test-DemoSemanticModelData -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token)
        ($results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.DATA' }).status | Should -Be 'Warning'
        @($results | Where-Object { $_.status -eq 'Fail' }) | Should -BeNullOrEmpty
    }

    It 'passes a measure that is blank over the whole history but returns a value in the context its visual sets' {
        Set-WebMock @(@{ Method = 'Post'; Match = $script:queriesUri; Respond = (Get-DaxResponder -Blank @('Focus Window Band', 'Blocking Incidents') -PerGrain @('Focus Window Band')) })
        $results = @(Test-DemoSemanticModelData -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token)
        $band = $results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.MEASURE.INCIDENT_WINDOWS.FOCUS_WINDOW_BAND' }
        $band.status | Should -Be 'Pass'
        $band.message | Should -Match ([regex]::Escape("7 'Telemetry Snapshots'[Bucket UTC]"))
        $blocking = $results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.MEASURE.ANALYSIS_FINDINGS.BLOCKING_INCIDENTS' }
        $blocking.status | Should -Be 'Warning'
        $blocking.message | Should -Match 'and for every value of'
        @($script:requests | Where-Object { [string]$_.Body -match 'NOT ISBLANK' }).Count | Should -Be 2
        $summary = $results | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.DATA' }
        $summary.status | Should -Be 'Warning'
        $summary.evidence['perGrain'] | Should -Be 1
        $summary.evidence['blank'] | Should -Be 1
    }

    It 'reports Manual action required when the tenant setting blocks Execute Queries' {
        Set-WebMock @(@{ Method = 'Post'; Match = $script:queriesUri; Responses = @(New-WebResponse 403 @{ error = @{ code = 'PowerBINotAuthorized' } }) })
        $results = @(Test-DemoSemanticModelData -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Token $script:token)
        $results.Count | Should -Be 1
        $results[0].status | Should -Be 'Manual action required'
        $results[0].remediation | Should -Match 'Dataset Execute Queries REST API'
    }
}

Describe 'Test-DemoPowerBIReport' {
    It 'passes when the report is bound to the model and has the four pages in order' {
        $pages = $script:pages
        Set-WebMock @(
            @{ Method = 'Get'; Match = ('^' + [regex]::Escape("$script:pbiApi/groups/$script:workspaceId/reports/$script:reportId") + '$'); Responses = @(New-WebResponse 200 @{ id = $script:reportId; datasetId = $script:modelId }) }
            @{ Method = 'Get'; Match = ('^' + [regex]::Escape("$script:pbiApi/groups/$script:workspaceId/reports/$script:reportId/pages") + '$'); Responses = @(New-WebResponse 200 @{ value = @(@{ name = 'b'; displayName = $pages[1]; order = 1 }, @{ name = 'a'; displayName = $pages[0]; order = 0 }, @{ name = 'c'; displayName = $pages[2]; order = 2 }, @{ name = 'd'; displayName = $pages[3]; order = 3 }) }) }
        )
        $results = @(Test-DemoPowerBIReport -WorkspaceId $script:workspaceId -ReportId $script:reportId -SemanticModelId $script:modelId -ExpectedPage $pages -Token $script:token)
        ($results | Where-Object { $_.checkId -eq 'FABRIC.REPORT.BINDING' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'FABRIC.REPORT.PAGES' }).status | Should -Be 'Pass'
    }
}

Describe 'Find-DemoSemanticModel' {
    It 'returns the ID only when exactly one semantic model has the name, ignoring case' {
        $datasets = '^' + [regex]::Escape("$script:pbiApi/groups/$script:workspaceId/datasets") + '$'
        Set-WebMock @(@{ Method = 'Get'; Match = $datasets; Responses = @(New-WebResponse 200 @{ value = @(@{ id = $script:modelId; name = 'SM_DatabaseHub_History' }, @{ id = $script:reportId; name = 'Other' }) }) })
        $found = Find-DemoSemanticModel -WorkspaceId $script:workspaceId -Name 'sm_databasehub_history' -Token $script:token
        $found.Id | Should -Be $script:modelId
        $found.Count | Should -Be 1
        Set-WebMock @(@{ Method = 'Get'; Match = $datasets; Responses = @(New-WebResponse 200 @{ value = @(@{ id = $script:modelId; name = 'SM_DatabaseHub_History' }, @{ id = $script:reportId; name = 'SM_DatabaseHub_History' }) }) })
        $twice = Find-DemoSemanticModel -WorkspaceId $script:workspaceId -Name 'SM_DatabaseHub_History' -Token $script:token
        $twice.Id | Should -BeNullOrEmpty
        $twice.Count | Should -Be 2
        Set-WebMock @(@{ Method = 'Get'; Match = $datasets; Responses = @(New-WebResponse 403 @{ error = @{ code = 'PowerBINotAuthorized' } }) })
        $denied = Find-DemoSemanticModel -WorkspaceId $script:workspaceId -Name 'SM_DatabaseHub_History' -Token $script:token
        $denied.StatusCode | Should -Be 403
        $denied.Id | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DemoPowerBIRequest' {
    It 'refuses to send the token anywhere but the Power BI REST API' {
        Set-WebMock @()
        { InModuleScope DbHubDemo -Parameters @{ Token = $script:token } { Invoke-DemoPowerBIRequest -Method Get -Uri 'https://example.com/v1.0/myorg/groups' -Token $Token } } | Should -Throw '*Refusing*'
        $script:requests.Count | Should -Be 0
    }
}

Describe 'configure-powerbi.ps1' {
    It 'plans every step under -WhatIf without a token or a request' {
        Set-WebMock @()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'No Azure CLI call is expected under -WhatIf.' }
        $output = Join-Path -Path $TestDrive -ChildPath 'whatif.jsonl'
        $null = & $script:configurePowerBI -ConfigPath (New-TestConfigFile) -OutputPath $output -WhatIf 6>&1
        $LASTEXITCODE | Should -Be 0
        $script:requests.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        @($records.checkId) | Should -Contain 'FABRIC.IMPORT.SM_DATABASEHUB_HISTORY'
        @($records.checkId) | Should -Contain 'FABRIC.IMPORT.RPT_DATABASEHUB_HISTORY'
        @($records.checkId | Where-Object { $_ -match 'ORGAPP|WORKSPACEAPP' }) | Should -BeNullOrEmpty
        @($records | Where-Object { $_.status -ne 'Not selected' }) | Should -BeNullOrEmpty
    }

    It 'stops with Fail and sends nothing when the subscription guard fails' {
        Set-WebMock @()
        Mock -CommandName Assert-DemoAzContext -MockWith { throw "Subscription guard: check 'account' failed: wrong tenant. Nothing was changed." }
        $output = Join-Path -Path $TestDrive -ChildPath 'guard.jsonl'
        $null = & $script:configurePowerBI -ConfigPath (New-TestConfigFile) -OutputPath $output 6>&1
        $LASTEXITCODE | Should -Be 1
        $script:requests.Count | Should -Be 0
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        ($records | Where-Object { $_.checkId -eq 'PREFLIGHT.GUARD.CONTEXT' }).status | Should -Be 'Fail'
    }

    It 'deploys the model and the report, refreshes, and checks the data in one unattended run, and creates no app' {
        $modelList = [regex]::Escape("$script:fabricApi/workspaces/$script:workspaceId/items?type=SemanticModel")
        $reportList = [regex]::Escape("$script:fabricApi/workspaces/$script:workspaceId/items?type=Report")
        $refreshes = "$script:pbiApi/groups/$script:workspaceId/datasets/$script:modelId/refreshes"
        $pages = $script:pages
        # Static, ordered responses only: while configure-powerbi.ps1 runs, "$script:" in a responder would be its scope.
        Set-WebMock @(
            @{ Method = 'Get'; Match = $modelList; Responses = @(New-WebResponse 200 @{ value = @() }) }
            @{ Method = 'Get'; Match = $reportList; Responses = @(New-WebResponse 200 @{ value = @() }) }
            @{ Method = 'Post'; Match = $script:itemsUri; Responses = @((New-WebResponse 201 @{ id = $script:modelId; type = 'SemanticModel' }), (New-WebResponse 201 @{ id = $script:reportId; type = 'Report' })) }
            @{ Method = 'Post'; Match = ('^' + [regex]::Escape($refreshes) + '$'); Responses = @(New-WebResponse 202 $null @{ 'x-ms-request-id' = @($script:refreshId) }) }
            @{ Method = 'Get'; Match = [regex]::Escape("$refreshes/$script:refreshId"); Responses = @(New-WebResponse 200 @{ status = 'Completed' }) }
            @{ Method = 'Post'; Match = [regex]::Escape("$script:pbiApi/groups/$script:workspaceId/datasets/$script:modelId/executeQueries"); Respond = (Get-DaxResponder) }
            @{ Method = 'Get'; Match = ('^' + [regex]::Escape("$script:pbiApi/groups/$script:workspaceId/reports/$script:reportId") + '$'); Responses = @(New-WebResponse 200 @{ datasetId = $script:modelId }) }
            @{ Method = 'Get'; Match = [regex]::Escape("$script:pbiApi/groups/$script:workspaceId/reports/$script:reportId/pages"); Responses = @(New-WebResponse 200 @{ value = @(for ($i = 0; $i -lt 4; $i++) { @{ name = "p$i"; displayName = $pages[$i]; order = $i } }) }) }
        )
        $output = Join-Path -Path $TestDrive -ChildPath 'deploy.jsonl'
        $null = & $script:configurePowerBI -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token -PowerBIToken $script:token 6>&1
        $LASTEXITCODE | Should -Be 0
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        foreach ($checkId in 'FABRIC.IMPORT.SM_DATABASEHUB_HISTORY', 'FABRIC.SEMANTICMODEL.REFRESH', 'FABRIC.SEMANTICMODEL.ROWS', 'FABRIC.SEMANTICMODEL.DATA', 'FABRIC.IMPORT.RPT_DATABASEHUB_HISTORY', 'FABRIC.REPORT.BINDING', 'FABRIC.REPORT.PAGES') {
            ($records | Where-Object { $_.checkId -eq $checkId }).status | Should -Be 'Pass' -Because $checkId
        }
        @($records.checkId | Where-Object { $_ -match 'ORGAPP|WORKSPACEAPP' }) | Should -BeNullOrEmpty
        $reportCreate = $script:requests | Where-Object { $_.Uri -match $script:itemsUri -and $_.Body -match '"type":"Report"' } | Select-Object -First 1
        (Get-SentDefinition $reportCreate 'definition.pbir') | Should -Match ([regex]::Escape("semanticmodelid=$script:modelId"))
        # Only the model and the report are created: the Fabric app (Rayfin) is a separate item, and no org app is made.
        @($script:requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -match $script:itemsUri }).Count | Should -Be 2
        @($script:requests | Where-Object { $_.Uri -match 'OrgApp|/apps' -or [string]$_.Body -match 'OrgApp' }) | Should -BeNullOrEmpty
        @($script:requests | Where-Object { $_.Uri -notmatch '^https://api\.(fabric\.microsoft\.com/v1|powerbi\.com/v1\.0/myorg)/' }) | Should -BeNullOrEmpty
    }

    It 'checks the deployed model alone with -CheckModelData: finds it by name with public functions and imports nothing' {
        Set-WebMock @(
            @{ Method = 'Get'; Match = ('^' + [regex]::Escape("$script:pbiApi/groups/$script:workspaceId/datasets") + '$'); Responses = @(New-WebResponse 200 @{ value = @(@{ id = $script:modelId; name = 'SM_DatabaseHub_History' }) }) }
            @{ Method = 'Post'; Match = [regex]::Escape("$script:pbiApi/groups/$script:workspaceId/datasets/$script:modelId/executeQueries"); Respond = (Get-DaxResponder) }
        )
        $output = Join-Path -Path $TestDrive -ChildPath 'check.jsonl'
        $null = & $script:configurePowerBI -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token -PowerBIToken $script:token -CheckModelData 6>&1
        $LASTEXITCODE | Should -Be 0
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        ($records | Where-Object { $_.checkId -eq 'FABRIC.SEMANTICMODEL.DATA' }).status | Should -Be 'Pass'
        @($records | Where-Object { $_.checkId -like 'FABRIC.IMPORT.*' -or $_.checkId -like 'FABRIC.REPORT.*' }) | Should -BeNullOrEmpty
        @($script:requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -notmatch '/executeQueries$' }) | Should -BeNullOrEmpty
    }
}
