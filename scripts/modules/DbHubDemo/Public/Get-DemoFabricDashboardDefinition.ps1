function Get-DemoFabricDashboardDefinition {
    <#
    .SYNOPSIS
    Builds the Fabric REST API definition of the Real-Time Dashboard for one environment. Local only: no network
    calls.

    .DESCRIPTION
    Reads fabric/realtime/RealTimeDashboard.json (built by Export-DemoRealTimeDashboard) and validates it, fills in
    the {{ResourceGroup}} placeholder with the demo resource group as a KQL string literal (rg-<prefix>-<environment>
    from the configuration, or -ResourceGroup), validates the result again, and returns the documented definition:
    one part, RealTimeDashboard.json, whose payload is the UTF-8 JSON in InlineBase64. Import it with
    Import-DemoFabricItem (configure-fabric.ps1 -ImportDashboard).

    The definition holds no credential and no ID from your environment. Its data source is the documented SQL ADX
    proxy, and each viewer queries it with their own identity (pass-through, the default), so a viewer sees only the
    resources their own Azure access allows. With -OutFile it also writes the rendered JSON, for the dashboard's
    Manage > Replace with file when the REST import isn't available.

    - KQL dashboard item definition: https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/kql-dashboard-definition
    - Replace with file: https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create#update-or-restore-an-existing-dashboard-from-a-file
    - Pass-through identity: https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-permissions

    .PARAMETER Config
    Configuration from Get-DemoConfig; supplies the resource group (prefix and environment).

    .PARAMETER ResourceGroup
    The demo resource group, instead of -Config.

    .PARAMETER Path
    The definition template. Defaults to fabric/realtime/RealTimeDashboard.json.

    .PARAMETER DisplayName
    The item's name in the workspace. Defaults to databaseHub.realTimeDashboard.displayName in config/versions.json.

    .PARAMETER OutFile
    Also write the rendered JSON here, for example under out/ (Git ignores it).

    .EXAMPLE
    $dashboard = Get-DemoFabricDashboardDefinition -Config $config

    .EXAMPLE
    Get-DemoFabricDashboardDefinition -Config $config -OutFile ./out/RealTimeDashboard.json
    #>
    [CmdletBinding(DefaultParameterSetName = 'Config')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Config')]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory, ParameterSetName = 'ResourceGroup')]
        [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
        [string] $ResourceGroup,

        [string] $Path = (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/realtime/RealTimeDashboard.json'),

        [ValidatePattern('^[A-Za-z0-9 _.-]{1,256}$')]
        [string] $DisplayName,

        [string] $OutFile
    )

    $pin = Get-DemoDashboardPin
    if (-not $DisplayName) {
        $DisplayName = $pin.DisplayName
    }
    $group = $ResourceGroup
    if ($PSCmdlet.ParameterSetName -eq 'Config') {
        $group = Get-DemoResourceGroupName -Config $Config
        if ($group -notmatch '^[A-Za-z0-9._()-]{1,90}$') {
            throw ('The configured prefix and environment don''t make a valid resource group name: {0}.' -f $group)
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Dashboard definition not found: $Path. Build it with Export-DemoRealTimeDashboard."
    }
    $file = Get-Item -LiteralPath $Path
    $template = [System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($file.FullName))
    try {
        $parsed = $template | ConvertFrom-Json -AsHashtable -Depth 64
    }
    catch {
        throw "$($file.Name) isn't valid JSON: $($_.Exception.Message)"
    }
    $problems = @(Test-DemoDashboardDocument -Document $parsed)
    if ($problems.Count -gt 0) {
        throw ('{0} is invalid: {1}' -f $file.Name, ($problems -join ' '))
    }

    $rendered = $template.Replace('{{ResourceGroup}}', (ConvertTo-DemoKqlLiteral -Value $group -Type String))
    $document = $rendered | ConvertFrom-Json -AsHashtable -Depth 64
    $problems = @(Test-DemoDashboardDocument -Document $document -Rendered)
    if ($problems.Count -gt 0) {
        throw ('The rendered definition is invalid: {0}' -f ($problems -join ' '))
    }

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($rendered)
    if ($OutFile) {
        [System.IO.File]::WriteAllBytes((Resolve-DemoUserPath -Path $OutFile), $bytes)
    }
    [pscustomobject]@{
        PSTypeName  = 'DbHubDemo.FabricItemDefinition'
        DisplayName = $DisplayName
        Type        = $pin.ItemType
        Label       = 'Real-Time Dashboard'
        Path        = $file.FullName
        SizeBytes   = $bytes.Length
        Sha256      = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        Content     = $rendered
        Evidence    = [ordered]@{
            resourceGroup = $group
            schemaVersion = [string]$document['schema_version']
            pages         = @($document['pages']).Count
            tiles         = @($document['tiles']).Count
            queries       = @($document['queries']).Count
        }
        Definition  = [ordered]@{
            parts = @(
                [ordered]@{
                    path        = $pin.DefinitionPart
                    payload     = [System.Convert]::ToBase64String($bytes)
                    payloadType = 'InlineBase64'
                }
            )
        }
    }
}
