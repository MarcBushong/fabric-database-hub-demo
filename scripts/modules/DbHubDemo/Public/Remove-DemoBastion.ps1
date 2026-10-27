function Remove-DemoBastion {
    <#
    .SYNOPSIS
    Deletes the on-demand Bastion host, then its public IP, idempotently, including a public IP left over after
    an interrupted delete (plan section 9.4, C8).

    .DESCRIPTION
    Uses 'az resource delete' for the host and 'az network public-ip delete' for its IP (the Azure CLI's
    Bastion commands need an extension that can't be installed without a prompt). The order matters: the IP
    can't go while the host uses it. The IP is deleted even when the host is already gone, because an
    interrupted Bastion delete left it behind, still billing (Phase 13 live finding, 2026-10-20); while the
    host's own delete is still running, the IP delete is retried for up to 10 minutes. With -IfExpired, a
    host goes only after its DbHubBastionExpiresUtc tag, as the scheduled bastion-cleanup workflow does; a
    leftover IP goes at once.
    Returns STOP.BASTION: Pass when something was deleted and nothing is left, Not selected when there's
    nothing to delete or the host hasn't expired, and Warning when the group can't be read.

    Sources (checked 2026-10-20): https://learn.microsoft.com/cli/azure/resource#az-resource-delete,
    https://learn.microsoft.com/cli/azure/network/public-ip#az-network-public-ip-delete

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER IfExpired
    Delete a host only after its expiry tag.

    .PARAMETER NowUtc
    For tests: the current time.

    .PARAMETER InUseRetrySeconds
    For tests: seconds between the public IP's retries while the host's delete still holds it.

    .EXAMPLE
    Remove-DemoBastion -Config $config -IfExpired
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $IfExpired,

        [datetime] $NowUtc = [DateTime]::UtcNow,

        [ValidateRange(0, 300)]
        [int] $InUseRetrySeconds = 30
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $docUrl = 'https://learn.microsoft.com/azure/bastion/bastion-overview'
    $bastion = Get-DemoBastionInfo -Config $Config
    if ($null -eq $bastion) {
        return (New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('{0} couldn''t be listed, so Bastion wasn''t checked.' -f $resourceGroupName) -Remediation 'Run stop-demo.ps1 -RemoveBastionOnly again, or check for bas-* and pip-*-bastion in the portal: both bill by the hour.' -DocUrl $docUrl)
    }
    if (-not $bastion.HostExists -and -not $bastion.PublicIpExists) {
        return (New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Not selected' -Message 'There''s no Bastion host or Bastion public IP to remove.')
    }
    if ($IfExpired -and $bastion.HostExists) {
        $expires = [datetime]::MinValue
        $known = [datetime]::TryParse($bastion.ExpiresUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expires)
        if ($known -and $expires -gt $NowUtc) {
            return (New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Not selected' -Message ('{0} stays until {1}.' -f $bastion.Name, $bastion.ExpiresUtc))
        }
    }
    $what = if ($bastion.HostExists) { 'Delete Bastion {0}, then {1}' -f $bastion.Name, $bastion.PublicIpName } else { 'Delete the leftover public IP {0}' -f $bastion.PublicIpName }
    if (-not $PSCmdlet.ShouldProcess($resourceGroupName, $what)) {
        return (New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Not selected' -Message ('What if: {0} wasn''t done.' -f $what))
    }
    $deleted = [System.Collections.Generic.List[string]]::new()
    if ($bastion.HostExists) {
        Write-DemoLog -Message ('Deleting {0}; this takes a few minutes.' -f $bastion.Name)
        $hostDelete = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList @('resource', 'delete', '--resource-group', $resourceGroupName, '--name', $bastion.Name, '--resource-type', 'Microsoft.Network/bastionHosts') -Label ('Deleting {0}' -f $bastion.Name)
        if ($hostDelete.ExitCode -ne 0 -and -not (Test-DemoAzNotFound -Text ([string]$hostDelete.StdErr))) {
            return (New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('Deleting {0} failed: {1}' -f $bastion.Name, (Get-DemoDeploymentErrorText -Text $hostDelete.StdErr -MaxLength 400)) -Remediation 'Run stop-demo.ps1 -RemoveBastionOnly again, or delete the Bastion and then its public IP in the portal; both bill by the hour.' -DocUrl $docUrl)
        }
        $deleted.Add($bastion.Name)
    }

    # Idempotent: the IP goes whether or not the host was there, and a missing IP is fine.
    $ip = $null
    for ($attempt = 1; $attempt -le 21; $attempt++) {
        $ip = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList @('network', 'public-ip', 'delete', '--resource-group', $resourceGroupName, '--name', $bastion.PublicIpName) -Label ('Deleting {0}' -f $bastion.PublicIpName)
        if ($ip.ExitCode -eq 0 -or $attempt -eq 21 -or [string]$ip.StdErr -notmatch '(?i)InUse|in use|is referenced|still allocated') {
            break
        }
        Write-DemoLog -Level Warning -Message ('{0} is still attached to a Bastion that''s being deleted; retrying in {1} seconds ({2} of 20).' -f $bastion.PublicIpName, $InUseRetrySeconds, $attempt)
        Start-Sleep -Seconds $InUseRetrySeconds
    }
    if ($ip.ExitCode -ne 0 -and -not (Test-DemoAzNotFound -Text ([string]$ip.StdErr))) {
        $prefix = if ($deleted.Count -gt 0) { '{0} is gone, but deleting' -f ($deleted -join ', ') } else { 'Deleting' }
        return (New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Fail' -Message ('{0} {1} failed: {2}' -f $prefix, $bastion.PublicIpName, (Get-DemoDeploymentErrorText -Text $ip.StdErr -MaxLength 400)) -Remediation 'Run stop-demo.ps1 -RemoveBastionOnly again, or delete the public IP in the portal; it bills while it exists.' -DocUrl $docUrl)
    }
    if ($bastion.PublicIpExists) {
        $deleted.Add($bastion.PublicIpName)
    }
    try {
        Set-DemoDeploymentState -Config $Config -Value @{ BastionExpiresUtc = '' } -Confirm:$false
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The Bastion expiry wasn''t cleared on the resource group: {0}' -f $_.Exception.Message)
    }
    $message = if ($bastion.Leftover) { 'Deleted the public IP {0} that an interrupted Bastion delete had left behind.' -f $bastion.PublicIpName } else { 'Deleted {0}.' -f ($deleted -join ' and ') }
    return (New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Pass' -Message $message -Evidence ([ordered]@{ deleted = $deleted.ToArray(); leftover = [bool]$bastion.Leftover }) -DocUrl $docUrl)
}
