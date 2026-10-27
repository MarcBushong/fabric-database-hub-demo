function Remove-DemoT3 {
    <#
    .SYNOPSIS
    Deletes T3: the logical server, with its database, and its private endpoint. Keeps the private DNS zone.

    .DESCRIPTION
    The owner's on-demand cleanup between demos, wired to 'stop-demo.ps1 -RemoveT3' in Phase 13 (ADR 0016).
    It stops T3's standing charges (Defender for Azure SQL, Defender CSPM, and the private endpoint) and
    deletes ContosoCare with its data. The next start recreates T3 under the same names
    (azuresql01-<deploymentId>, ContosoCare) by deploying again.
    - The private endpoint goes first ('az network private-endpoint delete'), which also removes its DNS
      record, then the server ('az sql server delete'), which deletes its databases and VNet rule.
    - The privatelink DNS zone and its VNet link stay, so a recreated T3 resolves as soon as its new
      endpoint registers; the zone bills per month whether T3 exists or not. T1's membership in the P6
      group stays too.
    - Idempotent: anything already gone is reported, not treated as an error.
    - With -WhatIf nothing is read or changed.
    A deleted free-offer database can take up to an hour to free its slot in the subscription's ten.

    Returns one T3.REMOVE result: Pass when both are gone, or Fail with the Azure CLI error.

    Sources (checked 2026-10-20):
    - az sql server delete: https://learn.microsoft.com/cli/azure/sql/server
    - az network private-endpoint delete: https://learn.microsoft.com/cli/azure/network/private-endpoint
    - Free offer slots after deletion: https://learn.microsoft.com/azure/azure-sql/database/free-offer-faq

    .PARAMETER DeploymentId
    The deployment's six-character suffix. Read from the resource group's deploymentId tag when omitted.

    .EXAMPLE
    Remove-DemoT3 -Config $config -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = ''
    )

    $names = Get-DemoT3Name -Config $Config -DeploymentId $DeploymentId -NoLookup
    $serverText = if ($names.ServerName) { $names.ServerName } else { 'azuresql01-<deploymentId>' }
    $target = 'T3 in {0}: logical server {1} with database {2}, and private endpoint {3}' -f $names.ResourceGroup, $serverText, $names.DatabaseName, $names.PrivateEndpointName
    if (-not $PSCmdlet.ShouldProcess($target, 'Delete')) {
        return
    }

    $subscriptionId = $Config['subscriptionId']
    $docUrl = 'https://learn.microsoft.com/cli/azure/sql/server'
    if (-not $names.ServerName) {
        $names = Get-DemoT3Name -Config $Config
    }
    if (-not $names.ServerName) {
        return New-DemoResult -CheckId 'T3.REMOVE' -Area 't3' -Target 'T3' -Status 'Fail' -Message ("T3's server name couldn't be resolved: the resource group {0} has no deploymentId tag." -f $names.ResourceGroup) -Remediation 'Pass -DeploymentId, the six-character suffix of the azuresql01-<deploymentId> server.' -DocUrl $docUrl
    }

    $evidence = @{ server = $names.ServerName; privateEndpoint = $names.PrivateEndpointName; keptPrivateDnsZone = $true }
    $steps = @(
        @{ Key = 'privateEndpoint'; Show = @('network', 'private-endpoint', 'show', '--name', $names.PrivateEndpointName, '--resource-group', $names.ResourceGroup); Delete = @('network', 'private-endpoint', 'delete', '--name', $names.PrivateEndpointName, '--resource-group', $names.ResourceGroup) }
        @{ Key = 'server'; Show = @('sql', 'server', 'show', '--name', $names.ServerName, '--resource-group', $names.ResourceGroup); Delete = @('sql', 'server', 'delete', '--name', $names.ServerName, '--resource-group', $names.ResourceGroup, '--yes') }
    )
    foreach ($step in $steps) {
        $existing = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $step.Show -AsJson -AllowFailure
        if ($null -eq $existing) {
            $evidence[$step.Key + 'State'] = 'absent'
            continue
        }
        Write-DemoLog -Message ('Deleting {0} {1}.' -f $step.Key, ($step.Delete[($step.Delete.IndexOf('--name') + 1)]))
        $deleted = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $step.Delete -AllowFailure
        if ($deleted.ExitCode -ne 0) {
            $errorText = (Protect-DemoText -Text ([string]$deleted.StdErr)).Trim()
            if ($errorText.Length -gt 300) {
                $errorText = $errorText.Substring(0, 300) + '...'
            }
            $evidence[$step.Key + 'State'] = 'failed'
            return New-DemoResult -CheckId 'T3.REMOVE' -Area 't3' -Target 'T3' -Status 'Fail' -Message ('Deleting the T3 {0} failed: {1}' -f $step.Key, $errorText) -Evidence $evidence -Remediation 'Check for a resource lock or a running operation on T3, then run this again; it skips what is already gone.' -DocUrl $docUrl
        }
        $evidence[$step.Key + 'State'] = 'deleted'
    }

    $message = if ($evidence['serverState'] -eq 'absent' -and $evidence['privateEndpointState'] -eq 'absent') {
        'T3 was already removed; the private DNS zone and its VNet link stay for the next start.'
    }
    else {
        'T3 was removed: logical server {0} (with ContosoCare) and private endpoint {1}. The private DNS zone and its VNet link stay, and the next start recreates T3 under the same names.' -f $names.ServerName, $names.PrivateEndpointName
    }
    New-DemoResult -CheckId 'T3.REMOVE' -Area 't3' -Target 'T3' -Status 'Pass' -Message $message -Evidence $evidence -DocUrl $docUrl
}
