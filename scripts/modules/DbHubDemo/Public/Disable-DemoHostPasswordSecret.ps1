function Disable-DemoHostPasswordSecret {
    <#
    .SYNOPSIS
    Disables every readable version of a VM's one-time password in the opt-in Key Vault (keyVault.enabled,
    ADR 0009). stop-demo.ps1, the scheduled stop and bastion-cleanup workflows, and start-demo.ps1 (after a
    rotation or a failed set) call it.

    .DESCRIPTION
    Lists the versions of <vm>-one-time-password with 'az keyvault secret list-versions' (metadata only,
    never values) and disables each enabled one with 'az keyvault secret set-attributes --enabled false';
    a disabled version can't be read. Nothing is deleted, so the vault's soft delete and the secret's
    history stay intact. Not selected when the opt-in is off or the vault doesn't exist. A refusal, for
    example an identity without Key Vault Secrets Officer on the vault, is a Warning: the rotation that
    comes with it already makes the stored value useless.
    https://learn.microsoft.com/cli/azure/keyvault/secret#az-keyvault-secret-set-attributes

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER VmName
    The VM whose password it is; archost01 by default.

    .PARAMETER CheckId
    The result's check ID; STOP.KEYVAULT by default.

    .EXAMPLE
    Disable-DemoHostPasswordSecret -Config $config -VmName archost01
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName = 'archost01',

        [ValidatePattern('^[A-Z0-9]+(\.[A-Z0-9_]+)+$')]
        [string] $CheckId = 'STOP.KEYVAULT'
    )

    $target = if ($VmName -eq 'sqlvm01') { 'T1' } else { 'T2' }
    $docUrl = 'https://learn.microsoft.com/cli/azure/keyvault/secret#az-keyvault-secret-set-attributes'
    if (-not (Get-DemoKeyVaultSetting -Config $Config).Enabled) {
        return (New-DemoResult -CheckId $CheckId -Area 'infra' -Target $target -Status 'Not selected' -Message 'The Key Vault opt-in is off (keyVault.enabled), so there''s no stored password to disable.')
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $vault = Get-DemoKeyVaultTarget -Config $Config
    $exists = if ($vault.Name) { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('keyvault', 'show', '--name', $vault.Name, '--resource-group', $vault.ResourceGroup, '--query', 'id', '--output', 'tsv') -AllowFailure } else { $null }
    if ($null -eq $exists -or $exists.ExitCode -ne 0) {
        return (New-DemoResult -CheckId $CheckId -Area 'infra' -Target $target -Status 'Not selected' -Message 'The Key Vault doesn''t exist, so there''s no stored password to disable.')
    }
    $secretName = Get-DemoHostPasswordSecretName -VmName $VmName
    $evidence = [ordered]@{ vaultName = $vault.Name; secretName = $secretName }
    if (-not $PSCmdlet.ShouldProcess(('{0}/{1}' -f $vault.Name, $secretName), 'Disable every enabled version')) {
        return (New-DemoResult -CheckId $CheckId -Area 'infra' -Target $target -Status 'Not selected' -Message ('What if: {0} wasn''t disabled.' -f $secretName) -Evidence $evidence)
    }
    $outcome = Disable-DemoKeyVaultSecretVersion -SubscriptionId $subscriptionId -VaultName $vault.Name -SecretName $secretName -Confirm:$false
    $evidence['disabled'] = $outcome.Disabled
    $evidence['failed'] = $outcome.Failed
    $portal = 'In the Azure portal, open the key vault {0}, then Objects, Secrets, {1}, select each enabled version, and set Enabled to No.' -f $vault.Name, $secretName
    if ($outcome.Error) {
        return (New-DemoResult -CheckId $CheckId -Area 'infra' -Target $target -Status 'Warning' -Message ('The stored one-time password in {0} couldn''t be disabled: {1}' -f $vault.Name, $outcome.Error) -Evidence $evidence -Remediation ('{0} If a workflow identity runs this, add its object ID to keyVault.operatorObjectIds and run deploy.ps1 -FromStage Infrastructure -StopAfter Infrastructure.' -f $portal) -DocUrl $docUrl)
    }
    $message = if (-not $outcome.SecretFound) { 'No one-time password is stored in {0}.' -f $vault.Name } elseif ($outcome.Disabled -gt 0) { 'Disabled {0} version(s) of {1} in {2}; a disabled version can''t be read.' -f $outcome.Disabled, $secretName, $vault.Name } else { 'Every version of {0} in {1} was already disabled.' -f $secretName, $vault.Name }
    return (New-DemoResult -CheckId $CheckId -Area 'infra' -Target $target -Status 'Pass' -Message $message -Evidence $evidence -DocUrl $docUrl)
}
