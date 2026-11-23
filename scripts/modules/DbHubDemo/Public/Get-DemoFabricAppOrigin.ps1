function Get-DemoFabricAppOrigin {
    <#
    .SYNOPSIS
    The Insights app's hosting origin (https://<name>-<region>.webapp.fabricapps.net): from the hosting URL that this
    run's rayfin up reported, else from the deploy stage's rayfin/.deployments.json, which records the app's last
    deployment. '' when neither has one. Ask's chat relay serves this origin only (ADR 0028).

    .EXAMPLE
    Get-DemoFabricAppOrigin -HostingUrl $hostingUrl -StagePath ./out/fabric-app
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $HostingUrl = '',

        [AllowEmptyString()]
        [string] $StagePath = ''
    )

    $origin = Get-DemoAskOrigin -Url $HostingUrl
    if ($origin) {
        return $origin
    }
    return (Get-DemoFabricAppHostingOrigin -StagePath $StagePath)
}
