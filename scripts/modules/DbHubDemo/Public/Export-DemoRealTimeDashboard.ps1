function Export-DemoRealTimeDashboard {
    <#
    .SYNOPSIS
    Builds the Real-Time Dashboard definition, fabric/realtime/RealTimeDashboard.json, from its layout spec and the
    shared KQL. Local only: no network calls.

    .DESCRIPTION
    Reads fabric/realtime/dashboard.spec.psd1 and the KQL in scripts/modules/DbHubDemo/Kql: Live.Prelude.kql, the
    Live.* bodies that NB_DatabaseHub_LiveActivity runs, and the Dashboard.* fragments that add the Target parameter
    and each tile's shape. It writes the dashboard JSON in the KQL dashboard item definition format, at the schema
    version pinned in config/versions.json (databaseHub.realTimeDashboard), after validating it.

    The output holds no real IDs: element IDs are deterministic UUIDs derived from the spec's keys, the data source
    is the documented SQL ADX proxy (database ArcSqlTelemetry), and the resource group stays the {{ResourceGroup}}
    placeholder that Get-DemoFabricDashboardDefinition fills in at import time. Rebuilding without a change gives
    the same bytes. Run it after you change the spec or the KQL, and commit both; tests/unit/Fabric.Dashboard.Tests.ps1
    fails while the committed file is out of date.

    - KQL dashboard item definition: https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/kql-dashboard-definition
    - The dashboard JSON and its $schema: https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create#export-dashboards

    .PARAMETER SpecPath
    The layout spec. Defaults to fabric/realtime/dashboard.spec.psd1.

    .PARAMETER Path
    Where to write the definition. Defaults to fabric/realtime/RealTimeDashboard.json.

    .PARAMETER PassThru
    Also return the JSON text. With -WhatIf, returns it without writing.

    .EXAMPLE
    Export-DemoRealTimeDashboard

    .EXAMPLE
    Export-DemoRealTimeDashboard -WhatIf -PassThru
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [string] $SpecPath = (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/realtime/dashboard.spec.psd1'),

        [string] $Path = (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/realtime/RealTimeDashboard.json'),

        [switch] $PassThru
    )

    $json = ConvertTo-DemoDashboardJson -Document (ConvertTo-DemoDashboardDocument -SpecPath $SpecPath)
    $parsed = $json | ConvertFrom-Json -AsHashtable -Depth 64
    $problems = @(Test-DemoDashboardDocument -Document $parsed)
    if ($problems.Count -gt 0) {
        throw ('The generated dashboard definition is invalid: {0}' -f ($problems -join ' '))
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Write the Real-Time Dashboard definition')) {
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
        Write-DemoLog -Message ('Wrote {0}: {1} pages, {2} tiles, {3} queries.' -f $Path, @($parsed['pages']).Count, @($parsed['tiles']).Count, @($parsed['queries']).Count)
    }
    if ($PassThru) {
        return $json
    }
}
