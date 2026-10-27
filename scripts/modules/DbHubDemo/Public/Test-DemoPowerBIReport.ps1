function Test-DemoPowerBIReport {
    <#
    .SYNOPSIS
    Checks the deployed RPT_DatabaseHub_History report through the Power BI REST API: bound to the expected semantic
    model, and with the expected pages in order. Read-only.

    .DESCRIPTION
    - FABRIC.REPORT.BINDING: Reports - Get Report In Group returns the report's datasetId; Pass when it's the
      semantic model the script deployed, Fail otherwise.
    - FABRIC.REPORT.PAGES: Reports - Get Pages In Group; Pass when the page display names, in order, are the ones
      in the PBIR definition, Fail otherwise.
    A refused token is Manual action required. With -WhatIf it sends nothing.

    - Get Report In Group: https://learn.microsoft.com/rest/api/power-bi/reports/get-report-in-group
    - Get Pages In Group: https://learn.microsoft.com/rest/api/power-bi/reports/get-pages-in-group

    .EXAMPLE
    Test-DemoPowerBIReport -WorkspaceId $workspaceId -ReportId $reportId -SemanticModelId $modelId -ExpectedPage $report.PageNames -Token $powerBIToken
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $ReportId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SemanticModelId,

        [Parameter(Mandatory)]
        [string[]] $ExpectedPage,

        [securestring] $Token
    )

    $reportUri = '{0}/groups/{1}/reports/{2}' -f $script:PowerBIApiBaseUri, $WorkspaceId, $ReportId
    $common = @{ Area = 'fabric'; Target = 'fabric' }
    if (-not $PSCmdlet.ShouldProcess("report $ReportId", 'Read the report and its pages through the Power BI REST API')) {
        return @(
            New-DemoResult @common -CheckId 'FABRIC.REPORT.BINDING' -Status 'Not selected' -Message 'Dry run: would read the report''s semantic model binding. No request was sent.' -Evidence ([ordered]@{ plannedRequests = @("GET $reportUri") })
            New-DemoResult @common -CheckId 'FABRIC.REPORT.PAGES' -Status 'Not selected' -Message 'Dry run: would read the report''s pages. No request was sent.' -Evidence ([ordered]@{ plannedRequests = @("GET $reportUri/pages") })
        )
    }
    if ($null -eq $Token) {
        throw 'A Power BI token is required. Use Get-DemoPowerBIToken, or pass -Token.'
    }
    $refused = {
        param([string] $CheckId, [pscustomobject] $Response, [string] $DocUrl)
        $status = if ($Response.StatusCode -eq 401) { 'Manual action required' } else { 'Fail' }
        $remediation = if ($Response.StatusCode -eq 401) { "Sign in again with 'az login --tenant <tenantId>' and run the script again." } else { 'Check that the report exists in the workspace, then run configure-powerbi.ps1 again.' }
        New-DemoResult @common -CheckId $CheckId -Status $status -Message ('The report couldn''t be read: {0}' -f (Get-DemoPowerBIErrorText -Response $Response)) `
            -Evidence ([ordered]@{ httpStatus = $Response.StatusCode; reportId = $ReportId }) -Remediation $remediation -DocUrl $DocUrl
    }

    $bindingDoc = 'https://learn.microsoft.com/rest/api/power-bi/reports/get-report-in-group'
    $report = Invoke-DemoPowerBIRequest -Method Get -Uri $reportUri -Token $Token
    if ($report.StatusCode -ne 200) {
        & $refused 'FABRIC.REPORT.BINDING' $report $bindingDoc
    }
    else {
        $datasetId = [string](Get-DemoMemberValue -InputObject $report.Body -Name 'datasetId')
        $evidence = [ordered]@{ reportId = $ReportId; datasetId = $datasetId; expectedSemanticModelId = $SemanticModelId.ToLowerInvariant() }
        if ($datasetId -ieq $SemanticModelId) {
            New-DemoResult @common -CheckId 'FABRIC.REPORT.BINDING' -Status 'Pass' -Message 'The report is bound to the deployed semantic model.' -Evidence $evidence -DocUrl $bindingDoc
        }
        else {
            New-DemoResult @common -CheckId 'FABRIC.REPORT.BINDING' -Status 'Fail' -Message ('The report is bound to semantic model {0}, not the deployed one.' -f $(if ($datasetId) { $datasetId } else { '(none)' })) `
                -Evidence $evidence -Remediation 'Run configure-powerbi.ps1 again; it rewrites definition.pbir with the deployed model''s ID.' -DocUrl $bindingDoc
        }
    }

    $pagesDoc = 'https://learn.microsoft.com/rest/api/power-bi/reports/get-pages-in-group'
    $pages = Invoke-DemoPowerBIRequest -Method Get -Uri "$reportUri/pages" -Token $Token
    if ($pages.StatusCode -ne 200) {
        & $refused 'FABRIC.REPORT.PAGES' $pages $pagesDoc
        return
    }
    $pageList = Get-DemoMemberValue -InputObject $pages.Body -Name 'value'
    $actual = @(@($pageList) | Sort-Object -Property { [int](Get-DemoMemberValue -InputObject $_ -Name 'order') } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') })
    $evidence = [ordered]@{ pages = $actual; expected = $ExpectedPage }
    if (($actual -join "`n") -ceq ($ExpectedPage -join "`n")) {
        New-DemoResult @common -CheckId 'FABRIC.REPORT.PAGES' -Status 'Pass' -Message ('The report has its {0} pages in order: {1}.' -f $actual.Count, ($actual -join ', ')) -Evidence $evidence -DocUrl $pagesDoc
    }
    else {
        New-DemoResult @common -CheckId 'FABRIC.REPORT.PAGES' -Status 'Fail' -Message ('The report''s pages are {0}; expected {1}.' -f ($actual -join ', '), ($ExpectedPage -join ', ')) -Evidence $evidence `
            -Remediation 'Run configure-powerbi.ps1 again; it overwrites the report definition with the committed PBIR.' -DocUrl $pagesDoc
    }
}
