function Get-DemoAskRelayEndpoint {
    <#
    .SYNOPSIS
    The https address of the Copilot dock's chat relay (Ask) in the demo's resource group, or an empty string when the
    resource group has none.

    .DESCRIPTION
    The relay is an Azure Container App that deploy.ps1 creates in the demo's resource group, tagged component=ask-relay.
    configure-fabric-app.ps1 writes its address into the app's dbhub-app.json, so the dock knows where to connect. A
    read only: it lists the resource group's container apps and reads the tagged one's ingress name.
    Source: https://learn.microsoft.com/azure/container-apps/ingress-overview

    .EXAMPLE
    Get-DemoAskRelayEndpoint -SubscriptionId $config.subscriptionId -ResourceGroupName 'rg-dbhub-demo'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[\w.()-]{1,90}$')]
        [string] $ResourceGroupName
    )

    $names = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('resource', 'list', '--resource-group', $ResourceGroupName, '--resource-type', 'Microsoft.App/containerApps', '--query', "[?tags.component=='ask-relay'].name", '--output', 'json') -AsJson -AllowFailure -TimeoutSeconds 120
    $name = @($names | Where-Object { $_ -is [string] -and $_ }) | Select-Object -First 1
    if (-not $name) {
        return ''
    }
    $fqdn = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('resource', 'show', '--resource-group', $ResourceGroupName, '--resource-type', 'Microsoft.App/containerApps', '--name', $name, '--query', 'properties.configuration.ingress.fqdn', '--output', 'json') -AsJson -AllowFailure -TimeoutSeconds 120
    if ($fqdn -is [string] -and $fqdn -match '^[a-z0-9.-]+\.azurecontainerapps\.io$') {
        return 'https://{0}' -f $fqdn
    }
    return ''
}
