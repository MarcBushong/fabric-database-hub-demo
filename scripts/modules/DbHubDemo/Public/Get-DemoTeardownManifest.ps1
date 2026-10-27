function Get-DemoTeardownManifest {
    <#
    .SYNOPSIS
    Records, read-only, what a destroy removes and what the residual check looks for afterward (ADR 0002,
    Phase 16). destroy.ps1 takes it before it deletes anything.

    .DESCRIPTION
    Some of what a destroy must leave clean can't be found once the resource group is gone, so it's read first:
    - the resource group's ID and its deploymentId tag; when the group is already gone, the deploymentId comes
      from the outputs of the subscription-scope deployment dbhub-<environment>-main, if it still exists;
    - the Microsoft Entra principals that live and die with demo resources: the system-assigned identities of
      the VMs, the Arc machine, and the T3 server, and any user-assigned identity in the group (the optional Arc
      onboarding identity), from one Azure Resource Graph query (through Invoke-DemoRestRequest with a verified
      token), after a canary shows that Resource Graph lists the configured subscription for this sign-in, since
      it trims its answer to what the caller can read; IdentitiesRecorded says whether that read happened;
    - the resources in the group by type, for the evidence;
    - the names the check needs: the deployment, the budget, the P6 group, and, with the opt-in, the vault.
    It changes nothing and holds no secret, only names and IDs.

    Sources (checked 2026-10-21):
    - Azure Resource Graph REST: https://learn.microsoft.com/rest/api/azureresourcegraph/resourcegraph/resources/resources
    - az deployment sub show: https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-show

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .EXAMPLE
    Get-DemoTeardownManifest -Config $config | ConvertTo-Json -Depth 5
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $deploymentName = 'dbhub-{0}-main' -f $Config['environment']
    $groupExists = Test-DemoResourceGroupExist -Config $Config
    $notes = [System.Collections.Generic.List[string]]::new()

    $deploymentId = ''
    if ($groupExists) {
        $deploymentId = [string](Get-DemoResourceGroupTag -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName)['deploymentId']
    }
    if (-not $deploymentId) {
        $output = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('deployment', 'sub', 'show', '--name', $deploymentName, '--query', 'properties.outputs.deploymentId.value', '--output', 'tsv') -AllowFailure
        if ($output.ExitCode -eq 0) {
            $deploymentId = ([string]$output.StdOut).Trim()
        }
    }
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        $deploymentId = ''
        $notes.Add('The deploymentId is unknown: neither the resource group''s tag nor the subscription deployment''s output could be read.')
    }

    $principals = [System.Collections.Generic.List[object]]::new()
    $types = [ordered]@{}
    $resourceCount = 0
    $identitiesRecorded = $false
    if ($groupExists) {
        # Resource Graph trims its answer to what the caller can read; an empty answer for a subscription it can't
        # read mustn't be recorded as "no identities".
        $reach = Get-DemoResourceGraphReach -SubscriptionId $subscriptionId
        $query = "resources | where resourceGroup =~ '{0}' | extend principalId = coalesce(tostring(identity.principalId), tostring(properties.principalId)) | project name, type = tolower(type), principalId" -f $resourceGroupName
        $graph = if ($reach.Reached) { Invoke-DemoHubResourceGraph -SubscriptionId $subscriptionId -Query $query } else { $null }
        if ($null -eq $graph) {
            $notes.Add(('The group''s identities weren''t recorded: {0}' -f $reach.Error))
        }
        elseif ($graph.Succeeded) {
            $identitiesRecorded = $true
            foreach ($row in @($graph.Rows)) {
                $resourceCount++
                $type = [string](Get-DemoMemberValue -InputObject $row -Name 'type')
                $types[$type] = 1 + [int]$types[$type]
                $principalId = [string](Get-DemoMemberValue -InputObject $row -Name 'principalId')
                if ($principalId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    $principals.Add([pscustomobject]@{ Name = [string](Get-DemoMemberValue -InputObject $row -Name 'name'); Type = $type; PrincipalId = $principalId.ToLowerInvariant() })
                }
            }
        }
        else {
            $notes.Add(('Resource Graph couldn''t list the group''s resources and identities: {0}' -f $graph.Error))
        }
    }

    $vaultName = ''
    if ((Get-DemoKeyVaultSetting -Config $Config).Enabled -and $deploymentId) {
        $vaultName = Get-DemoKeyVaultName -Config $Config -DeploymentId $deploymentId
    }

    return [pscustomobject]@{
        RecordedUtc          = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        SubscriptionId       = $subscriptionId
        Environment          = [string]$Config['environment']
        ResourceGroupName    = $resourceGroupName
        ResourceGroupId      = ('/subscriptions/{0}/resourceGroups/{1}' -f $subscriptionId, $resourceGroupName)
        ResourceGroupExisted = [bool]$groupExists
        IdentitiesRecorded   = $identitiesRecorded
        DeploymentId         = $deploymentId
        DeploymentName       = $deploymentName
        BudgetName           = ('budget-{0}-{1}' -f $Config['prefix'], $Config['environment'])
        T3AdminGroupObjectId = [string]$Config['t3AdminGroupObjectId']
        KeyVaultName         = $vaultName
        Principals           = $principals.ToArray()
        ResourceCount        = $resourceCount
        ResourceTypes        = $types
        Notes                = $notes.ToArray()
    }
}
