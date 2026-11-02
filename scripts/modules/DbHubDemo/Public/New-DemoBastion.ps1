function New-DemoBastion {
    <#
    .SYNOPSIS
    Deploys on-demand Azure Bastion Basic and its public IP for the T2 setup-wizard step, with an expiry tag
    that the bastion-cleanup workflow honors (plan section 9.4, C8).

    .DESCRIPTION
    Deploys infra/modules/bastion.bicep into the demo resource group with 'az deployment group create' (the
    Azure CLI's Bastion commands need an extension that can't be installed without a prompt). The host uses
    the AzureBastionSubnet and its NSG from the foundation (ADR 0007). The deployment took about 8 minutes live
    and is idempotent; a policy that appends ipTags to the public IP doesn't get in its way. The expiry is now
    plus bastionMaxHours (4 by default), and a longer -Hours is capped at it; stop-demo.ps1 and the scheduled
    bastion-cleanup workflow delete Bastion after it.

    Sources (checked 2026-10-20):
    - Bastion SKUs and settings: https://learn.microsoft.com/azure/bastion/configuration-settings
    - az deployment group create: https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-create

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Hours
    Hours until the bastion-cleanup workflow removes it; defaults to bastionMaxHours, and is capped at it.

    .PARAMETER NoWait
    Start the deployment and return at once (az deployment group create --no-wait), for deploy.ps1's guided stop,
    which prepares the guest meanwhile and then waits for the deployment named bastion-on-demand (Phase 28).

    .EXAMPLE
    New-DemoBastion -Config $config
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(0, 24)]
        [int] $Hours = 0,

        [switch] $NoWait
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $bastionName = 'bas-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $publicIpName = 'pip-{0}-{1}-bastion' -f $Config['prefix'], $Config['environment']
    $docUrl = 'https://learn.microsoft.com/azure/bastion/configuration-settings'
    $maxHours = if ([int]$Config['bastionMaxHours'] -gt 0) { [int]$Config['bastionMaxHours'] } else { 4 }
    if ($Hours -le 0 -or $Hours -gt $maxHours) {
        if ($Hours -gt $maxHours) {
            Write-DemoLog -Level Warning -Message ('Bastion is capped at bastionMaxHours ({0}), not {1} hours (ADR 0016, C8).' -f $maxHours, $Hours)
        }
        $Hours = $maxHours
    }
    $expires = [DateTime]::UtcNow.AddHours($Hours).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    if (-not $PSCmdlet.ShouldProcess($resourceGroupName, ('Deploy Azure Bastion Basic ({0}) until {1}' -f $bastionName, $expires))) {
        return (New-DemoResult -CheckId 'START.BASTION' -Area 'infra' -Target 'T2' -Status 'Not selected' -Message ('What if: {0} wasn''t deployed.' -f $bastionName))
    }
    $tags = Get-DemoResourceGroupTag -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName
    $stateTags = @((Get-DemoDeploymentStateTagName).Values)
    $keep = @{}
    foreach ($key in $tags.Keys) {
        if ($key -notin $stateTags) {
            $keep[$key] = $tags[$key]
        }
    }
    $parameters = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{
            vnetName     = @{ value = ('vnet-{0}-{1}' -f $Config['prefix'], $Config['environment']) }
            bastionName  = @{ value = $bastionName }
            publicIpName = @{ value = $publicIpName }
            expiresUtc   = @{ value = $expires }
            tags         = @{ value = $keep }
        }
    }
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-bastion'
    try {
        $path = Write-DemoPrivateFile -Directory $directory -Name 'bastion.parameters.json' -Content ($parameters | ConvertTo-Json -Depth 10)
        Write-DemoLog -Message ('Deploying {0} (Basic) and {1}; this takes about 8 minutes.' -f $bastionName, $publicIpName)
        $arguments = [System.Collections.Generic.List[string]]::new([string[]]@('deployment', 'group', 'create', '--resource-group', $resourceGroupName, '--name', 'bastion-on-demand', '--template-file', (Join-Path -Path $script:RepoRoot -ChildPath 'infra/modules/bastion.bicep'), '--parameters', "@$path"))
        if ($NoWait) {
            $arguments.Add('--no-wait')
        }
        $run = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $arguments.ToArray() -AllowFailure
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    if ($run.ExitCode -ne 0) {
        return (New-DemoResult -CheckId 'START.BASTION' -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('Deploying Bastion failed: {0}' -f (Get-DemoDeploymentErrorText -Text $run.StdErr -MaxLength 600)) -Remediation 'Check the AzureBastionSubnet and the public IP quota (preflight PREFLIGHT.P3.PUBLICIP), then run start-demo.ps1 -Interactive again.' -DocUrl $docUrl)
    }
    try {
        Set-DemoDeploymentState -Config $Config -Value @{ BastionExpiresUtc = $expires } -Confirm:$false
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The Bastion expiry wasn''t recorded on the resource group: {0}' -f $_.Exception.Message)
    }
    if ($NoWait) {
        return (New-DemoResult -CheckId 'START.BASTION' -Area 'infra' -Target 'T2' -Status 'Pass' -Message ('{0} is being deployed (about 8 minutes) and stays until {1}.' -f $bastionName, $expires) -Evidence ([ordered]@{ bastionName = $bastionName; publicIpName = $publicIpName; expiresUtc = $expires; noWait = $true }) -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId 'START.BASTION' -Area 'infra' -Target 'T2' -Status 'Pass' -Message ('{0} is ready until {1}. In the Azure portal, open archost01, select Connect, then Bastion.' -f $bastionName, $expires) -Evidence ([ordered]@{ bastionName = $bastionName; publicIpName = $publicIpName; expiresUtc = $expires }) -DocUrl $docUrl)
}
