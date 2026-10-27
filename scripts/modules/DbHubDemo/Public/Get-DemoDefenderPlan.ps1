function Get-DemoDefenderPlan {
    <#
    .SYNOPSIS
    Reads the subscription's Microsoft Defender for Cloud plans (read-only).

    .DESCRIPTION
    Runs 'az security pricing list' through Invoke-DemoAz, so the call carries --subscription and never
    signs in. Returns one object per plan with name, pricingTier (Free or Standard), and subPlan: the
    shape that Get-DemoCostEstimate -DefenderPlans takes. Call Assert-DemoAzContext first.

    .PARAMETER SubscriptionId
    The configured subscription.

    .EXAMPLE
    Get-DemoCostEstimate -Config $config -DefenderPlans @(Get-DemoDefenderPlan -SubscriptionId $config.subscriptionId)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId
    )

    $response = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList 'security', 'pricing', 'list' -AsJson

    # Older Azure CLI versions wrap the list in a 'value' property.
    $wrapped = Get-DemoMemberValue -InputObject $response -Name 'value'
    $plans = if ($null -ne $wrapped) { $wrapped } else { $response }
    foreach ($plan in @($plans)) {
        if ($null -eq $plan) {
            continue
        }
        [pscustomobject]@{
            name        = [string](Get-DemoMemberValue -InputObject $plan -Name 'name')
            pricingTier = [string](Get-DemoMemberValue -InputObject $plan -Name 'pricingTier')
            subPlan     = [string](Get-DemoMemberValue -InputObject $plan -Name 'subPlan')
        }
    }
}
