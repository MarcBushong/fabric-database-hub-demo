function Set-DemoDeploymentState {
    <#
    .SYNOPSIS
    Records deploy.ps1's state in the demo resource group's tags (plan section 9.2).

    .DESCRIPTION
    Merges the given values into the group's tags with 'az tag update --operation Merge', which Contributor
    can do, so other tags stay. Keys are the property names of Get-DemoDeploymentState: Stage, BundleSha256,
    BundleChunkCount, RunnerSha256, RunnerChunkCount, BundleSentTo, RunnerSentTo (arrays become a comma list),
    NetworkMode, T3UseFreeLimit, T3AdminGroupName, BastionExpiresUtc, HostPasswordSet, FabricCapacityResumed and
    FabricCapacityResumedUtc (fabric.manageCapacity, Phase 26b), GuidedStopUtc and T4Sku (Phase 28), and T2BuildUtc (Phase
    28 review follow-up). A Stage value also
    sets StageUtc. A value that the Azure CLI can't carry safely on Windows (a double quote or a percent sign)
    is left out with a warning. The template keeps these tags on every redeployment, because deploy.ps1 passes
    the group's existing tags (ADR 0002).

    Source: az tag update, https://learn.microsoft.com/cli/azure/tag#az-tag-update (checked 2026-10-20).

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Value
    Keys and values to record. An empty value clears the tag's content.

    .EXAMPLE
    Set-DemoDeploymentState -Config $config -Value @{ Stage = 'Infrastructure' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Value
    )

    $names = Get-DemoDeploymentStateTagName
    $pairs = [System.Collections.Generic.List[string]]::new()
    $values = [ordered]@{}
    foreach ($key in $Value.Keys) {
        $values[[string]$key] = $Value[$key]
    }
    if ($values.Contains('Stage')) {
        $values['StageUtc'] = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    foreach ($key in $values.Keys) {
        if (-not $names.Contains($key)) {
            throw "Set-DemoDeploymentState doesn't know the key '$key'."
        }
        $item = $values[$key]
        $text = if ($item -is [bool]) {
            $item.ToString().ToLowerInvariant()
        }
        elseif ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
            (@($item | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join ',')
        }
        else {
            [string]$item
        }
        if ($text -match '["%]' -or $text.Length -gt 256) {
            Write-DemoLog -Level Warning -Message ('The state value for {0} isn''t recorded: a resource group tag can''t carry it safely.' -f $key)
            continue
        }
        $pairs.Add(('{0}={1}' -f $names[$key], $text))
    }
    if ($pairs.Count -eq 0) {
        return
    }
    $resourceGroupId = '/subscriptions/{0}/resourceGroups/{1}' -f $Config['subscriptionId'], (Get-DemoResourceGroupName -Config $Config)
    if (-not $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), ('Record the deployment state in tags: {0}' -f (($pairs | ForEach-Object { $_.Split('=')[0] }) -join ', ')))) {
        return
    }
    $arguments = [System.Collections.Generic.List[string]]::new([string[]]@('tag', 'update', '--resource-id', $resourceGroupId, '--operation', 'Merge', '--tags'))
    $arguments.AddRange($pairs)
    $result = Invoke-DemoAzWithConflictRetry -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList $arguments.ToArray() -Label 'Recording the deployment state'
    if ($result.ExitCode -ne 0) {
        throw ('Recording the deployment state failed: {0}' -f (Get-DemoDeploymentErrorText -Text $result.StdErr -MaxLength 400))
    }
}
