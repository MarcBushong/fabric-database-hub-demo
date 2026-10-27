function Test-DemoFabricViewerLicense {
    <#
    .SYNOPSIS
    Optional prerequisite P11: warns when the Fabric workspace's capacity is smaller than F64, where everyone who
    views Power BI content needs a Pro, PPU, or individual trial license (PREFLIGHT.FABRIC.VIEWERLICENSE).

    .DESCRIPTION
    Microsoft Learn (Fabric licenses, checked 2026-10-21): "On F SKUs smaller than F64, each user viewing Power BI
    content must have Pro, PPU, or an individual trial. On F64 or larger, users with only a Free license and a viewer
    role can view Power BI content." The demo's Power BI content is the history report and the Fabric app (Phase 19).
    Database Hub and the Real-Time Dashboard aren't Power BI items, and a presenter who shares their screen needs
    nothing more.

    The SKU comes from documented Fabric REST calls with the caller's Fabric token (-Token, or the Azure CLI through
    Phase 12's helpers), sent only as a SecureString bearer token:
    - Workspaces - Get Workspace for the workspace's capacityId;
    - Capacities - List Capacities for that capacity's SKU. It lists only capacities the caller administers or
      contributes to.
    With -CapacityResult (FABRIC.P5.CAPACITY from Test-DemoFabricWorkspace), the SKU comes from its evidence and no
    request is sent.

    Status: Pass for F64 or larger, and for P SKUs; Warning below F64, for A and EM SKUs, for a SKU the check doesn't
    recognize (a Trial acts like F64 for viewing, but its SKU string isn't documented), and when the SKU can't be
    read; Not selected without a resolved workspace (fabric.workspaceId, which Resolve-DemoFabricConfig fills in). Viewer licensing is optional (P11), so the
    check never fails. It never changes the capacity, which runs at the owner's choice.

    - Licenses: https://learn.microsoft.com/fabric/enterprise/licenses
    - Get Workspace: https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-workspace
    - List Capacities: https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities

    .PARAMETER Config
    Configuration from Get-DemoConfig (fabric.workspaceId).

    .PARAMETER Token
    A Fabric REST API token the operator already has, as a SecureString.

    .PARAMETER CapacityResult
    The FABRIC.P5.CAPACITY record from Test-DemoFabricWorkspace, to reuse the SKU it read.

    .PARAMETER MaxPages
    The most pages to read from List Capacities.

    .EXAMPLE
    Test-DemoFabricViewerLicense -Config $config
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [securestring] $Token,

        [AllowNull()]
        [object] $CapacityResult,

        [ValidateRange(1, 50)]
        [int] $MaxPages = 10
    )

    $fabric = (Get-DemoHubSetting)['fabric']
    $minimum = [int]$fabric['viewerLicense']['minimumFreeViewerFSku']
    $docUrl = [string]$fabric['viewerLicense']['docUrl']
    $base = [string]$fabric['apiBaseUrl']
    $workspaceId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')
    $rule = 'On F SKUs smaller than F{0}, each user who views Power BI content (the Phase 19 report and the Fabric app) needs a Pro, PPU, or individual trial license; on F{0} or larger, a Fabric Free license and a viewer role are enough. Database Hub and the Real-Time Dashboard aren''t Power BI content, and presenting by sharing your screen needs no viewer license.' -f $minimum
    $remediation = 'For viewers of the report or the app: assign Pro or PPU licenses, or have them start an individual trial (P11); or present by sharing your screen; or use a workspace on an F{0} or larger capacity. Don''t resize or pause the shared capacity yourself: it runs at the owner''s choice.' -f $minimum
    $evidence = [ordered]@{ workspaceId = $workspaceId }
    $report = {
        param([string] $Status, [string] $Message)
        $fix = if ($Status -eq 'Warning') { $remediation } else { '' }
        New-DemoResult -CheckId 'PREFLIGHT.FABRIC.VIEWERLICENSE' -Area 'preflight' -Target 'fabric' -Status $Status -Message $Message -Evidence $evidence -Remediation $fix -DocUrl $docUrl
    }

    if (-not $workspaceId) {
        return (& $report 'Not selected' 'No Fabric workspace was resolved (FABRIC.RESOLVE.WORKSPACE says why), so no Power BI content is presented from one yet.')
    }

    $sku = ''
    $unreadable = ''
    if ($null -ne $CapacityResult) {
        $capacityEvidence = Get-DemoMemberValue -InputObject $CapacityResult -Name 'evidence'
        $sku = [string](Get-DemoMemberValue -InputObject $capacityEvidence -Name 'sku')
        $evidence['capacityId'] = [string](Get-DemoMemberValue -InputObject $capacityEvidence -Name 'capacityId')
        $evidence['skuSource'] = 'FABRIC.P5.CAPACITY'
        if (-not $sku) {
            $unreadable = 'FABRIC.P5.CAPACITY couldn''t read it: {0}' -f (Get-DemoMemberValue -InputObject $CapacityResult -Name 'message')
        }
    }
    else {
        $evidence['skuSource'] = 'Get Workspace and List Capacities'
        $access = Get-DemoHubFabricAccess -SubscriptionId ([string]$Config['subscriptionId']) -Token $Token
        if (-not $access.Token) {
            $unreadable = $access.Error
        }
        else {
            $call = Invoke-DemoHubFabricGet -Uri ('{0}/workspaces/{1}' -f $base, $workspaceId) -Token $access.Token
            $capacityId = [string](Get-DemoMemberValue -InputObject $call.Body -Name 'capacityId')
            $evidence['capacityId'] = $capacityId
            if ($call.StatusCode -lt 200 -or $call.StatusCode -ge 300) {
                $unreadable = 'the workspace couldn''t be read: {0}' -f $call.Error
            }
            elseif (-not $capacityId) {
                $unreadable = 'the workspace isn''t on a capacity'
            }
            else {
                $capacities = Read-DemoHubFabricList -Uri ('{0}/capacities' -f $base) -Token $access.Token -MaxPages $MaxPages
                $capacity = if ($capacities.Succeeded) { $capacities.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'id') -ieq $capacityId } | Select-Object -First 1 } else { $null }
                if ($capacity) {
                    $sku = [string](Get-DemoMemberValue -InputObject $capacity -Name 'sku')
                }
                elseif ($capacities.Succeeded) {
                    $unreadable = 'List Capacities shows only capacities you administer or contribute to'
                }
                else {
                    $unreadable = 'the capacities couldn''t be listed: {0}' -f $capacities.Error
                }
            }
        }
    }

    $evidence['sku'] = $sku
    if (-not $sku) {
        $evidence['viewersNeedProOrPpu'] = $null
        return (& $report 'Warning' ('The capacity SKU of the Fabric workspace couldn''t be read ({0}), so the viewer licensing rule can''t be checked. {1}' -f $unreadable, $rule))
    }
    if ($sku -match '^F([0-9]+)$') {
        $size = [int]$Matches[1]
        $evidence['viewersNeedProOrPpu'] = $size -lt $minimum
        if ($size -ge $minimum) {
            return (& $report 'Pass' ('The workspace''s capacity is {0}, F{1} or larger: viewers with a Fabric Free license and a viewer role can view Power BI content.' -f $sku, $minimum))
        }
        return (& $report 'Warning' ('The workspace''s capacity is {0}, smaller than F{1}. {2}' -f $sku, $minimum, $rule))
    }
    if ($sku -match '^P[1-5]$') {
        $evidence['viewersNeedProOrPpu'] = $false
        return (& $report 'Pass' ('The workspace''s capacity is {0}, a Power BI Premium capacity: viewers with a Fabric Free license and a viewer role can view Power BI content.' -f $sku))
    }
    if ($sku -match '^(A[1-8]|EM[1-3])$') {
        $evidence['viewersNeedProOrPpu'] = $true
        return (& $report 'Warning' ('The workspace''s capacity is {0}, an embedded SKU: viewers of Power BI content need a Pro, PPU, or individual trial license. {1}' -f $sku, $rule))
    }
    $evidence['viewersNeedProOrPpu'] = $null
    & $report 'Warning' ('The workspace''s capacity SKU, {0}, isn''t one this check recognizes. A Fabric Trial acts like F{1} for viewing, but Learn doesn''t document its SKU string; confirm the rule for this capacity. {2}' -f $sku, $minimum, $rule)
}
