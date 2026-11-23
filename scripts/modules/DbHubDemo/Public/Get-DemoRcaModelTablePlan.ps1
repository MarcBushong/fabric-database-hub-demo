function Get-DemoRcaModelTablePlan {
    <#
    .SYNOPSIS
    Which of the Incident RCA's tables the history model reads in this deployment (ADR 0031): those the lakehouse has.
    Returns Excluded (the model's names of the tables it leaves out) and Result, FABRIC.SEMANTICMODEL.RCA.

    .DESCRIPTION
    Direct Lake can't frame a table that doesn't exist, and an environment that updates to this release has the RCA tables
    only once this release's NB_DatabaseHub_LiveActivity has run (configure-fabric.ps1 runs it once when it updated the
    notebook and the lakehouse lacked a table the model reads; deploy.ps1's history snapshot runs it at the end). Until
    then configure-powerbi.ps1 leaves the missing ones out (Get-DemoFabricSemanticModelDefinition -ExcludeTable), and the
    rest of the model works as before. The RCA tables are the evidence document's eight and, since 2026-11-23, the
    sidecar's six (Get-DemoRcaHistoryTable; rca/README.md, The sidecar), so an environment from the release before gets
    the sidecar's the same way:
    - Pass: the lakehouse has all of them.
    - Warning: some are missing, with the fix; or the lakehouse's tables couldn't be listed, and all of them are left out,
      so the refresh can't fail on one that isn't there.
    The RCA tables relate only to Target and Date, and the report reads none of them, so leaving them out changes nothing
    else. Read-only: OneLake's Path - List (Get-DemoLakehouseTable) with a Storage token, from -Token, or from the Azure
    CLI for -Config's subscription after the subscription guard (Get-DemoStorageToken). The caller's workspace role reads
    it; nothing requests or assigns a role.
    - Direct Lake: https://learn.microsoft.com/fabric/fundamentals/direct-lake-overview
    - OneLake APIs: https://learn.microsoft.com/fabric/onelake/onelake-access-api

    .PARAMETER Config
    The demo configuration, for the Storage token's subscription. Without it and -Token, the plan leaves all of them out.

    .PARAMETER WorkspaceId
    The workspace that holds the lakehouse.

    .PARAMETER LakehouseId
    The lakehouse the model reads.

    .PARAMETER Token
    A Storage-audience token to use instead of the Azure CLI's.

    .EXAMPLE
    Get-DemoRcaModelTablePlan -Config $config -WorkspaceId $config.fabric.workspaceId -LakehouseId $config.fabric.lakehouseId
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $LakehouseId,

        [AllowNull()]
        [securestring] $Token
    )

    $tables = @(Get-DemoRcaHistoryTable)
    $docUrl = 'https://learn.microsoft.com/fabric/fundamentals/direct-lake-overview'
    $fix = 'Run ./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity -RunLiveActivity, which updates that notebook alone and runs it (it creates the tables), then ./scripts/configure-powerbi.ps1; ./scripts/deploy.ps1 does both, unless someone edited that notebook in Fabric while fabric.importNotebooks is false (follow-ups decision 2a).'
    $why = ''
    $names = @()
    try {
        if ($null -eq $Token) {
            if ($null -eq $Config -or -not [string]$Config['subscriptionId']) {
                throw 'without the configuration, no OneLake (Storage) token was requested'
            }
            $Token = Get-DemoStorageToken -SubscriptionId ([string]$Config['subscriptionId'])
        }
        $listing = Get-DemoLakehouseTable -WorkspaceId $WorkspaceId -LakehouseId $LakehouseId -Token $Token
        $why = [string]$listing.Error
        $names = @($listing.Names)
    }
    catch {
        $why = Get-DemoExceptionText -Exception $_.Exception
    }
    if ($why) {
        $result = New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.RCA' -Area 'fabric' -Target 'fabric' -Status 'Warning' `
            -Message ('The lakehouse''s tables couldn''t be listed ({0}), so the history model leaves the Incident RCA''s {1} tables out, in case they aren''t there yet: Direct Lake can''t read a missing table. The rest of the model is deployed as before.' -f (Protect-DemoText -Text $why).TrimEnd('.', ' '), $tables.Count) `
            -Evidence ([ordered]@{ excluded = @($tables | ForEach-Object Name); listed = $false }) -Remediation 'Run ./scripts/configure-powerbi.ps1 again once OneLake answers.' -DocUrl $docUrl
        return [pscustomobject]@{ Excluded = @($tables | ForEach-Object Model); Result = $result }
    }
    $missing = @($tables | Where-Object { $_.Name -notin $names })
    if ($missing.Count -eq 0) {
        $result = New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.RCA' -Area 'fabric' -Target 'fabric' -Status 'Pass' `
            -Message ('The lakehouse has the Incident RCA''s {0} tables (ADR 0031), so the history model reads them.' -f $tables.Count) -Evidence ([ordered]@{ excluded = @(); listed = $true }) -DocUrl $docUrl
        return [pscustomobject]@{ Excluded = @(); Result = $result }
    }
    $result = New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.RCA' -Area 'fabric' -Target 'fabric' -Status 'Warning' `
        -Message ('The lakehouse doesn''t have {0} of the Incident RCA''s {1} tables yet ({2}), so the history model leaves them out until it does: Direct Lake can''t read a missing table, and the Insights app says no RCA capture is recorded. This release''s NB_DatabaseHub_LiveActivity creates them on its next run. The rest of the model is deployed as before.' -f $missing.Count, $tables.Count, (@($missing | ForEach-Object Name) -join ', ')) `
        -Evidence ([ordered]@{ excluded = @($missing | ForEach-Object Name); listed = $true }) -Remediation $fix -DocUrl $docUrl
    return [pscustomobject]@{ Excluded = @($missing | ForEach-Object Model); Result = $result }
}
