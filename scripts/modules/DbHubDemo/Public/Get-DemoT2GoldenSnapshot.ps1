function Get-DemoT2GoldenSnapshot {
    <#
    .SYNOPSIS
    Lists the T2 golden snapshots of the configured prefix in rg-<prefix>-golden, newest first (ADR 0018).

    .DESCRIPTION
    Read-only: 'az snapshot list' in the golden resource group, keeping the snapshots tagged dbhubRole
    t2-golden for this prefix. Each comes back with its tags parsed (ConvertFrom-DemoGoldenSnapshot): the
    capture time, the guest's Windows evaluation expiry and days left, the bundle and runner hashes, the SQL
    Server version and update level, the install mode, the host size and security type, the used GiB, and
    when it was disk-, boot-, and onboard-verified. Returns nothing when the group doesn't exist.

    Source: az snapshot list (https://learn.microsoft.com/cli/azure/snapshot#az-snapshot-list, checked 2026-10-21).

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER NowUtc
    The time the evaluation days left are counted from.

    .EXAMPLE
    Get-DemoT2GoldenSnapshot -Config $config | Select-Object -First 1
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $groupName = Get-DemoGoldenResourceGroupName -Config $Config
    $exists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $groupName) -AllowFailure
    if ($exists.ExitCode -ne 0 -or ([string]$exists.StdOut).Trim() -ne 'true') {
        return @()
    }
    $listed = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('snapshot', 'list', '--resource-group', $groupName, '--output', 'json') -AsJson -AllowFailure
    $names = Get-DemoGoldenTagName
    $snapshots = foreach ($item in @($listed)) {
        if ($null -eq $item) {
            continue
        }
        $tags = Get-DemoMemberValue -InputObject $item -Name 'tags'
        if ([string](Get-DemoMemberValue -InputObject $tags -Name $names['Role']) -ne 't2-golden') {
            continue
        }
        if ([string](Get-DemoMemberValue -InputObject $tags -Name $names['Prefix']) -ne [string]$Config['prefix']) {
            continue
        }
        ConvertFrom-DemoGoldenSnapshot -Snapshot $item -NowUtc $NowUtc
    }
    return @($snapshots | Sort-Object -Property @{ Expression = { if ($null -ne $_.CapturedUtc) { $_.CapturedUtc } else { [datetime]::MinValue } }; Descending = $true })
}
