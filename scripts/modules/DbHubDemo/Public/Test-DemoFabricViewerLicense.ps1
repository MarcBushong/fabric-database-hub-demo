function Test-DemoFabricViewerLicense {
    <#
    .SYNOPSIS
    Optional prerequisite P11, Power BI viewer licenses: assumed since 2026-11-14, so nothing is read or checked
    (PREFLIGHT.FABRIC.VIEWERLICENSE, Not selected).

    .DESCRIPTION
    Microsoft Learn (Fabric licenses, checked 2026-10-21): "On F SKUs smaller than F64, each user viewing Power BI
    content must have Pro, PPU, or an individual trial. On F64 or larger, users with only a Free license and a viewer
    role can view Power BI content." The demo's Power BI content is the history report and the Insights app; Database
    Hub and the Real-Time Dashboard aren't Power BI items.

    The user, 2026-11-14: "Make the assumption that the PBI licenses are sorted out." So the demo assumes that its
    viewers have the licenses Fabric asks for. The check reads nothing and returns Not selected with the rule, where it
    used to read the capacity's SKU and warn on every deployment below F64. Nothing in the demo detects, assigns, or
    works around licenses, and nothing changes the capacity, which runs at the owner's choice.

    - Licenses: https://learn.microsoft.com/fabric/enterprise/licenses

    .PARAMETER Config
    Configuration from Get-DemoConfig (fabric.workspaceId, kept in the evidence).

    .EXAMPLE
    Test-DemoFabricViewerLicense -Config $config
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $fabric = (Get-DemoHubSetting)['fabric']
    $minimum = [int]$fabric['viewerLicense']['minimumFreeViewerFSku']
    $docUrl = [string]$fabric['viewerLicense']['docUrl']
    $workspaceId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')
    $message = 'Power BI viewer licenses are assumed, so nothing is checked (P11): everyone who views the history report or the Insights app has what Fabric asks for, which is Pro, PPU, or an individual trial on a capacity smaller than F{0}, and a Fabric Free license with a viewer role on F{0} or larger.' -f $minimum
    New-DemoResult -CheckId 'PREFLIGHT.FABRIC.VIEWERLICENSE' -Area 'preflight' -Target 'fabric' -Status 'Not selected' -Message $message -Evidence ([ordered]@{ workspaceId = $workspaceId; assumed = $true }) -DocUrl $docUrl
}