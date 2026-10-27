function Test-DemoSemanticModelData {
    <#
    .SYNOPSIS
    Proves that the deployed SM_DatabaseHub_History semantic model returns data: row counts of its Direct Lake tables
    and every measure, evaluated with DAX through Execute Queries, read-only.

    .DESCRIPTION
    The data check after the refresh (configure-powerbi.ps1 runs it), and a deploy step that runs unattended: call it
    after Assert-DemoAzContext, with a token from Get-DemoPowerBIToken. It only reads.

    - FABRIC.SEMANTICMODEL.ROWS: COUNTROWS of each Direct Lake table (the TMDL partitions with an entityName). Pass
      when every table answers and the notebooks' history tables have rows; Warning when no notebook has written
      history yet; Fail when a table can't be read (framing or a missing column).
    - FABRIC.SEMANTICMODEL.MEASURE.<TABLE>.<MEASURE>, one per measure in the TMDL: EVALUATE ROW(...) in batches, and
      each measure alone when its batch fails. Pass when it returns a value. A measure that is blank over the whole
      history is evaluated once more per -Grain (a telemetry bin, an incident, a signal: what its visual puts in
      context), and passes when it returns a value for any of them. Warning when it's blank for every grain too, which
      is expected until a scenario runs or an incident window exists (Phase 20's end-to-end run checks again); Fail
      when the measure raises a DAX error.
    - FABRIC.SEMANTICMODEL.INFOMEASURES: EVALUATE INFO.MEASURES(), for measure errors the engine reports. Execute
      Queries doesn't support INFO functions, so a refusal is Not supported, and the per-measure queries are the check.
    - FABRIC.SEMANTICMODEL.DATA: the summary, with the worst status of the records above.
    Execute Queries needs the tenant setting "Dataset Execute Queries REST API"; when it's off, the summary is Manual
    action required with that step. With -WhatIf it sends nothing.

    - Execute Queries In Group: https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group
    - INFO.MEASURES: https://learn.microsoft.com/dax/info-measures-function-dax

    .PARAMETER DefinitionPath
    The TMDL definition folder the measures and tables are read from.

    .PARAMETER BatchSize
    Measures per query.

    .PARAMETER Grain
    Columns, as DAX references, that a measure blank over the whole history is evaluated over: it passes when it isn't
    blank for at least one of their values. The defaults are the axes the report's visuals put in context.

    .EXAMPLE
    Test-DemoSemanticModelData -WorkspaceId $workspaceId -SemanticModelId $modelId -Token $powerBIToken | Format-Table checkId, status, message
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SemanticModelId,

        [securestring] $Token,

        [string] $DefinitionPath = (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/powerbi/SM_DatabaseHub_History.SemanticModel/definition'),

        [ValidateRange(1, 50)]
        [int] $BatchSize = 12,

        [AllowEmptyCollection()]
        [string[]] $Grain = @("'Telemetry Snapshots'[Bucket UTC]", "'Incident Windows'[Incident Key]", "'Signal'[Signal]")
    )

    $docUrl = 'https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group'
    $measures = @(Get-DemoTmdlMeasure -DefinitionPath $DefinitionPath)
    $sources = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path -Path $DefinitionPath -ChildPath 'tables') -Filter '*.tmdl' -File | Sort-Object -Property Name) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text -match "(?m)^table\s+('(?:[^']|'')+'|\S+)\s*$" ) {
            $tableName = $Matches[1].Trim("'").Replace("''", "'")
            if ($text -match '(?m)^\s+entityName:\s*(\S+)\s*$') {
                $sources[$tableName] = $Matches[1]
            }
        }
    }
    $summary = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation = '')
        New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.DATA' -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl
    }

    if (-not $PSCmdlet.ShouldProcess("semantic model $SemanticModelId", 'Evaluate every measure with DAX (read-only)')) {
        return (& $summary 'Not selected' ('Dry run: would count the rows of {0} Direct Lake tables and evaluate {1} measures with DAX. No request was sent.' -f $sources.Count, $measures.Count) ([ordered]@{
                    plannedRequests = @(('POST {0}/groups/{1}/datasets/{2}/executeQueries (one EVALUATE per batch of {3} measures, and one per measure that is blank over the whole history, over {4} grains)' -f $script:PowerBIApiBaseUri, $WorkspaceId, $SemanticModelId, $BatchSize, $Grain.Count))
                    measures        = $measures.Count
                    tables          = @($sources.Values)
                }))
    }
    if ($null -eq $Token) {
        throw 'A Power BI token is required. Use Get-DemoPowerBIToken, or pass -Token.'
    }
    $query = { param([string] $Dax) Invoke-DemoDaxQuery -WorkspaceId $WorkspaceId -SemanticModelId $SemanticModelId -Query $Dax -Token $Token }
    $results = [System.Collections.Generic.List[object]]::new()

    # Row counts first: they explain blank measures, and an access or setting problem shows up here once.
    $columns = @(for ($index = 0; $index -lt $sources.Count; $index++) {
            '"r{0}", COUNTROWS ( {1} )' -f $index, ("'{0}'" -f ([string]@($sources.Keys)[$index]).Replace("'", "''"))
        })
    $rowsAnswer = & $query ('EVALUATE ROW ( {0} )' -f ($columns -join ', '))
    $rowCounts = [ordered]@{}
    if ($rowsAnswer.StatusCode -ne 200) {
        $evidence = [ordered]@{ httpStatus = $rowsAnswer.StatusCode; error = $rowsAnswer.Error }
        if ($rowsAnswer.StatusCode -in 401, 403 -or $rowsAnswer.Error -match 'ExecuteQueries.*(disabled|not enabled)|PowerBINotAuthorized|tenant setting') {
            return (& $summary 'Manual action required' ('Execute Queries was refused, so no measure was evaluated: {0}' -f $rowsAnswer.Error) $evidence `
                    'A Fabric administrator enables the tenant setting "Dataset Execute Queries REST API" (Admin portal, Tenant settings, Integration settings), and you need Build or write permission on the semantic model. Then run the script again.')
        }
        $results.Add((New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.ROWS' -Area 'fabric' -Target 'fabric' -Status 'Fail' `
                    -Message ('The Direct Lake tables couldn''t be read: {0}' -f $rowsAnswer.Error) -Evidence $evidence `
                    -Remediation 'Run NB_DatabaseHub_LiveActivity with SAVE_RESULTS true so the five tables exist with every column, refresh the model, and run the script again.' -DocUrl $docUrl))
    }
    else {
        $row = @($rowsAnswer.Rows) | Select-Object -First 1
        for ($index = 0; $index -lt $sources.Count; $index++) {
            $value = Get-DemoMemberValue -InputObject $row -Name ('[r{0}]' -f $index)
            $rowCounts[[string]@($sources.Values)[$index]] = if ($null -eq $value) { 0 } else { [long]$value }
        }
        $history = @($rowCounts.Keys | Where-Object { $_ -in 'validation_results', 'telemetry_snapshots', 'analysis_findings' -and $rowCounts[$_] -gt 0 })
        $empty = @($rowCounts.Keys | Where-Object { $rowCounts[$_] -eq 0 })
        $status = if ($history.Count -gt 0) { 'Pass' } else { 'Warning' }
        $message = '{0} Direct Lake tables answer: {1}.' -f $rowCounts.Count, (($rowCounts.Keys | ForEach-Object { '{0} {1}' -f $_, $rowCounts[$_] }) -join ', ')
        if ($empty.Count -gt 0) {
            $message += ' Empty until a scenario runs or the notebook records one: {0}.' -f ($empty -join ', ')
        }
        $remediation = if ($status -eq 'Warning') { 'Run NB_DatabaseHub_Deployment and NB_DatabaseHub_LiveActivity with SAVE_RESULTS true, refresh the model, and run the script again.' } else { '' }
        $results.Add((New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.ROWS' -Area 'fabric' -Target 'fabric' -Status $status -Message $message -Evidence $rowCounts -Remediation $remediation -DocUrl $docUrl))
    }

    # Every measure: batches, then each measure alone when its batch fails.
    $outcomes = @{}
    $evaluate = {
        param([object[]] $Batch)
        $parts = @(for ($index = 0; $index -lt $Batch.Count; $index++) {
                '"m{0}", {1}' -f $index, (ConvertTo-DemoDaxName -Table $Batch[$index].Table -Name $Batch[$index].Name)
            })
        & $query ('EVALUATE ROW ( {0} )' -f ($parts -join ', '))
    }
    for ($start = 0; $start -lt $measures.Count; $start += $BatchSize) {
        $batch = @($measures[$start..([System.Math]::Min($start + $BatchSize, $measures.Count) - 1)])
        $answer = & $evaluate $batch
        if ($answer.StatusCode -eq 200) {
            $row = @($answer.Rows) | Select-Object -First 1
            for ($index = 0; $index -lt $batch.Count; $index++) {
                $outcomes[('{0}|{1}' -f $batch[$index].Table, $batch[$index].Name)] = [pscustomobject]@{ Error = ''; Value = (Get-DemoMemberValue -InputObject $row -Name ('[m{0}]' -f $index)) }
            }
            continue
        }
        foreach ($measure in $batch) {
            $single = & $evaluate @(, $measure)
            $value = if ($single.StatusCode -eq 200) { Get-DemoMemberValue -InputObject (@($single.Rows) | Select-Object -First 1) -Name '[m0]' } else { $null }
            $outcomes[('{0}|{1}' -f $measure.Table, $measure.Name)] = [pscustomobject]@{ Error = $(if ($single.StatusCode -eq 200) { '' } else { $single.Error }); Value = $value }
        }
    }

    # A measure that is blank over the whole history may need what its visual puts in context (a telemetry bin, an
    # incident, or a signal): count the values of each grain it isn't blank for.
    $grainHits = @{}
    foreach ($measure in $measures) {
        $key = '{0}|{1}' -f $measure.Table, $measure.Name
        $outcome = $outcomes[$key]
        if ($Grain.Count -eq 0 -or $null -eq $outcome -or $outcome.Error -or -not [string]::IsNullOrEmpty([string]$outcome.Value)) {
            continue
        }
        $reference = ConvertTo-DemoDaxName -Table $measure.Table -Name $measure.Name
        $parts = @(for ($index = 0; $index -lt $Grain.Count; $index++) {
                '"g{0}", COUNTROWS ( FILTER ( VALUES ( {1} ), NOT ISBLANK ( {2} ) ) )' -f $index, $Grain[$index], $reference
            })
        $answer = & $query ('EVALUATE ROW ( {0} )' -f ($parts -join ', '))
        $hits = [ordered]@{}
        if ($answer.StatusCode -eq 200) {
            $row = @($answer.Rows) | Select-Object -First 1
            for ($index = 0; $index -lt $Grain.Count; $index++) {
                $count = if ($null -ne $row) { Get-DemoMemberValue -InputObject $row -Name ('[g{0}]' -f $index) } else { $null }
                $hits[$Grain[$index]] = if ($null -eq $count) { 0 } else { [long]$count }
            }
        }
        else {
            $hits['error'] = $answer.Error
        }
        $grainHits[$key] = $hits
    }

    $seen = @{}
    foreach ($measure in $measures) {
        $key = '{0}|{1}' -f $measure.Table, $measure.Name
        $outcome = $outcomes[$key]
        $checkId = 'FABRIC.SEMANTICMODEL.MEASURE.{0}.{1}' -f (ConvertTo-DemoCheckIdPart -Name $measure.Table), (ConvertTo-DemoCheckIdPart -Name $measure.Name)
        if ($seen.ContainsKey($checkId)) {
            $seen[$checkId]++
            $checkId = '{0}_{1}' -f $checkId, $seen[$checkId]
        }
        else {
            $seen[$checkId] = 1
        }
        $label = ConvertTo-DemoDaxName -Table $measure.Table -Name $measure.Name
        $evidence = [ordered]@{ table = $measure.Table; measure = $measure.Name; hidden = $measure.IsHidden }
        $entity = if ($sources.Contains($measure.Table)) { [string]$sources[$measure.Table] } else { '' }
        if ($null -eq $outcome) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('{0} wasn''t evaluated.' -f $label) -Evidence $evidence -DocUrl $docUrl))
        }
        elseif ($outcome.Error) {
            $evidence['error'] = $outcome.Error
            $results.Add((New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('{0} raised a DAX error: {1}' -f $label, $outcome.Error) -Evidence $evidence `
                        -Remediation 'Fix the measure in fabric/powerbi/SM_DatabaseHub_History.SemanticModel, then run configure-powerbi.ps1 again; it updates the model in place.' -DocUrl $docUrl))
        }
        elseif ([string]::IsNullOrEmpty([string]$outcome.Value)) {
            $hits = $grainHits[$key]
            $found = @(if ($hits) { $hits.Keys | Where-Object { $_ -ne 'error' -and $hits[$_] -gt 0 } })
            if ($hits) {
                $evidence['valuesPerGrain'] = $hits
            }
            if ($found.Count -gt 0) {
                $perGrain = ($found | ForEach-Object { '{0} {1}' -f $hits[$_], $_ }) -join ', '
                $results.Add((New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Pass' `
                            -Message ('{0} is blank over the whole history and returns a value in the context its visual sets, for {1} value(s).' -f $label, $perGrain) -Evidence $evidence -DocUrl $docUrl))
                continue
            }
            $why = if ($entity -and $rowCounts.Contains($entity) -and $rowCounts[$entity] -eq 0) {
                '{0} has no rows yet' -f $entity
            }
            else {
                'it needs data the lakehouse doesn''t have yet, such as a scenario request or an incident window'
            }
            $scope = if ($hits -and $hits.Contains('error')) {
                ' (the per-grain query failed: {0})' -f $hits['error']
            }
            elseif ($Grain.Count -gt 0) {
                ' and for every value of {0}' -f ($Grain -join ', ')
            }
            else {
                ''
            }
            $results.Add((New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Warning' `
                        -Message ('{0} returned blank over the whole history{1}: {2}.' -f $label, $scope, $why) -Evidence $evidence `
                        -Remediation 'Expected before a scenario runs. Run a bounded scenario and NB_DatabaseHub_LiveActivity (Phase 20''s end-to-end run does both), then run the check again.' -DocUrl $docUrl))
        }
        else {
            $value = $outcome.Value
            $preview = if ($value -is [double] -or $value -is [decimal] -or $value -is [float]) { ([double]$value).ToString('0.####', [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$value }
            if ($preview.Length -gt 120) {
                $preview = $preview.Substring(0, 117) + '...'
            }
            $evidence['value'] = $preview
            $results.Add((New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('{0} returned {1}.' -f $label, $preview) -Evidence $evidence -DocUrl $docUrl))
        }
    }

    # INFO.MEASURES(): Execute Queries documents that it doesn't run INFO functions, so a refusal is expected.
    $info = & $query 'EVALUATE SELECTCOLUMNS ( INFO.MEASURES (), "Name", [Name], "State", [State], "ErrorMessage", [ErrorMessage] )'
    if ($info.StatusCode -ne 200) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.INFOMEASURES' -Area 'fabric' -Target 'fabric' -Status 'Not supported' `
                    -Message ('Execute Queries didn''t run INFO.MEASURES() ({0}); the per-measure queries above are the check.' -f $info.Error) -Evidence ([ordered]@{ httpStatus = $info.StatusCode }) -DocUrl $docUrl))
    }
    else {
        $broken = @(foreach ($item in @($info.Rows)) {
                $errorMessage = [string](Get-DemoMemberValue -InputObject $item -Name '[ErrorMessage]')
                if ($errorMessage) {
                    '{0}: {1}' -f (Get-DemoMemberValue -InputObject $item -Name '[Name]'), $errorMessage
                }
            })
        $status = if ($broken.Count -eq 0) { 'Pass' } else { 'Fail' }
        $message = if ($broken.Count -eq 0) { 'INFO.MEASURES() lists {0} measures and no errors.' -f @($info.Rows).Count } else { 'INFO.MEASURES() reports {0} measure error(s): {1}' -f $broken.Count, (($broken | Select-Object -First 5) -join '; ') }
        $results.Add((New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.INFOMEASURES' -Area 'fabric' -Target 'fabric' -Status $status -Message $message -Evidence ([ordered]@{ measures = @($info.Rows).Count; errors = @($broken | Select-Object -First 20) }) -DocUrl 'https://learn.microsoft.com/dax/info-measures-function-dax'))
    }

    $measureResults = @($results | Where-Object { $_.checkId -like 'FABRIC.SEMANTICMODEL.MEASURE.*' })
    $counts = [ordered]@{
        measures  = $measureResults.Count
        withValue = @($measureResults | Where-Object { $_.status -eq 'Pass' }).Count
        perGrain  = @($measureResults | Where-Object { $_.status -eq 'Pass' -and $_.evidence.Contains('valuesPerGrain') }).Count
        blank     = @($measureResults | Where-Object { $_.status -eq 'Warning' }).Count
        errors    = @($measureResults | Where-Object { $_.status -eq 'Fail' }).Count
    }
    $statuses = @($results | Where-Object { $_.checkId -ne 'FABRIC.SEMANTICMODEL.INFOMEASURES' } | ForEach-Object { $_.status })
    $status = if ($statuses -contains 'Fail') { 'Fail' } elseif ($statuses -contains 'Warning') { 'Warning' } else { 'Pass' }
    $message = '{0} of {1} measures returned a value ({2} of them only in the context their visual sets), {3} returned blank, and {4} raised an error.' -f $counts['withValue'], $counts['measures'], $counts['perGrain'], $counts['blank'], $counts['errors']
    $remediation = switch ($status) {
        'Fail' { 'Fix the failing measures or tables above, then run configure-powerbi.ps1 again.' }
        'Warning' { 'Blank measures fill after a scenario runs and NB_DatabaseHub_LiveActivity records it; Phase 20''s end-to-end run checks them again.' }
        default { '' }
    }
    $results.Add((& $summary $status $message $counts $remediation))
    return $results.ToArray()
}
