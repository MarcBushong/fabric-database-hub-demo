function Set-DemoHostPasswordSecret {
    <#
    .SYNOPSIS
    Writes a VM's one-time administrator password to the opt-in Key Vault, never displaying it
    (keyVault.enabled, ADR 0009). start-demo.ps1 -Interactive -ResetAdminPassword calls it before it sets
    the password on the VM, so a password nobody can read is never set.

    .DESCRIPTION
    The secret is <vm>-one-time-password in kv-<prefix><environment>-<deploymentId>
    (Initialize-DemoKeyVault). The value reaches the Azure CLI in a file in a private temporary directory
    ('az keyvault secret set --file --encoding utf-8'), never on a command line, and the CLI returns only
    the secret's ID (--query id), never the value. The secret gets the content type password, the VM and
    its administrator's user name as tags, and the Bastion expiry as its expiry date. Older versions that
    are still enabled are then disabled, so only the new one can be read. A role assignment can take several
    minutes to reach Key Vault, so a Forbidden answer is retried for up to -RetryMinutes; a firewall refusal
    isn't (add your public address to keyVault.allowedIpRanges).

    Returns START.KEYVAULT: its evidence has the vault, the secret, and the version, and its message the
    portal steps. Azure Bastion's RDP form offers Microsoft Entra ID (preview), username and password, and
    Kerberos, and no Key Vault option (only its SSH form has one), so the operator copies the secret's value
    in the vault's Secrets page and pastes it into the username-and-password form.

    Sources (checked 2026-10-21):
    - az keyvault secret set: https://learn.microsoft.com/cli/azure/keyvault/secret#az-keyvault-secret-set
    - Copy a secret in the portal: https://learn.microsoft.com/azure/key-vault/secrets/quick-create-portal
    - Bastion RDP authentication: https://learn.microsoft.com/azure/bastion/bastion-connect-vm-rdp-windows

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER VmName
    The VM whose administrator password it is; archost01 by default.

    .PARAMETER Password
    The one-time password.

    .PARAMETER ExpiresUtc
    The secret's expiry (yyyy-MM-ddTHH:mm:ssZ); by default now plus bastionMaxHours.

    .PARAMETER RetryMinutes
    How long to retry while a new role assignment reaches Key Vault.

    .EXAMPLE
    Set-DemoHostPasswordSecret -Config $config -VmName archost01 -Password $password
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName = 'archost01',

        [Parameter(Mandatory)]
        [securestring] $Password,

        [ValidatePattern('^$|^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')]
        [string] $ExpiresUtc = '',

        [ValidateRange(0, 30)]
        [int] $RetryMinutes = 10
    )

    $target = if ($VmName -eq 'sqlvm01') { 'T1' } else { 'T2' }
    $docUrl = 'https://learn.microsoft.com/azure/key-vault/secrets/quick-create-portal'
    if (-not (Get-DemoKeyVaultSetting -Config $Config).Enabled) {
        return (New-DemoResult -CheckId 'START.KEYVAULT' -Area 'infra' -Target $target -Status 'Not selected' -Message 'The Key Vault opt-in is off (keyVault.enabled), so the one-time password wasn''t stored in a vault.')
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $vault = Get-DemoKeyVaultTarget -Config $Config
    $exists = if ($vault.Name) { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('keyvault', 'show', '--name', $vault.Name, '--resource-group', $vault.ResourceGroup, '--query', 'id', '--output', 'tsv') -AllowFailure } else { $null }
    if ($null -eq $exists -or $exists.ExitCode -ne 0) {
        return (New-DemoResult -CheckId 'START.KEYVAULT' -Area 'infra' -Target $target -Status 'Fail' -Message ('The Key Vault {0} doesn''t exist, so no one-time password was set.' -f $(if ($vault.Name) { $vault.Name } else { 'for this environment' })) -Remediation 'Run deploy.ps1 -FromStage Infrastructure -StopAfter Infrastructure, or start-demo.ps1 -Interactive -ResetAdminPassword, which creates it.' -DocUrl 'https://learn.microsoft.com/azure/key-vault/general/rbac-guide')
    }
    $user = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $vault.ResourceGroup, '--name', $VmName, '--query', 'osProfile.adminUsername', '--output', 'tsv') -AllowFailure
    $userName = ([string]$user.StdOut).Trim()
    if ($user.ExitCode -ne 0 -or $userName -notmatch '^[A-Za-z0-9._-]{1,20}$') {
        return (New-DemoResult -CheckId 'START.KEYVAULT' -Area 'infra' -Target $target -Status 'Fail' -Message ('The administrator account of {0} couldn''t be read, so no one-time password was stored.' -f $VmName) -DocUrl $docUrl)
    }
    $secretName = Get-DemoHostPasswordSecretName -VmName $VmName
    $expires = $ExpiresUtc
    if (-not $expires) {
        $hours = if ([int]$Config['bastionMaxHours'] -gt 0) { [int]$Config['bastionMaxHours'] } else { 4 }
        $expires = [DateTime]::UtcNow.AddHours($hours).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $evidence = [ordered]@{ vaultName = $vault.Name; secretName = $secretName; userName = $userName; vmName = $VmName; expiresUtc = $expires }
    if (-not $PSCmdlet.ShouldProcess(('{0}/{1}' -f $vault.Name, $secretName), 'Store the one-time password')) {
        return (New-DemoResult -CheckId 'START.KEYVAULT' -Area 'infra' -Target $target -Status 'Not selected' -Message ('What if: no password was stored in {0}.' -f $vault.Name) -Evidence $evidence)
    }

    $write = $null
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-keyvault'
    try {
        $plainText = [System.Net.NetworkCredential]::new('', $Password).Password
        # A SecureString bound to a [string] parameter becomes its type name; never store that.
        if ($plainText.Length -lt 12 -or $plainText -match '^System\.[A-Za-z.]+$') {
            return (New-DemoResult -CheckId 'START.KEYVAULT' -Area 'infra' -Target $target -Status 'Fail' -Message 'The one-time password was refused before anything was stored: it''s shorter than 12 characters or a type name, which means a conversion went wrong.' -Evidence $evidence)
        }
        Register-DemoSecret -Value $plainText
        $path = Write-DemoPrivateFile -Directory $directory -Name 'secret.txt' -Content $plainText
        $plainText = $null
        $arguments = @('keyvault', 'secret', 'set', '--vault-name', $vault.Name, '--name', $secretName, '--file', $path, '--encoding', 'utf-8', '--content-type', 'password', '--expires', $expires, '--tags', ('vmName={0}' -f $VmName), ('userName={0}' -f $userName), '--query', 'id', '--output', 'tsv')
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $write = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $arguments -AllowFailure
            if ($write.ExitCode -eq 0) {
                break
            }
            $text = [string]$write.StdErr
            $propagating = $text -match '(?i)Forbidden|not authorized|AuthorizationFailed' -and $text -notmatch '(?i)ForbiddenByFirewall|Client address'
            if (-not $propagating -or $watch.Elapsed.TotalMinutes -ge $RetryMinutes) {
                break
            }
            Write-DemoLog -Level Warning -Message ('Key Vault refused the write; a new role assignment can take several minutes to arrive. Retrying in 30 seconds ({0:N0} of {1} minutes).' -f $watch.Elapsed.TotalMinutes, $RetryMinutes)
            Start-Sleep -Seconds 30
        }
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
    if ($write.ExitCode -ne 0) {
        $text = [string]$write.StdErr
        $remediation = if ($text -match '(?i)ForbiddenByFirewall|Client address') {
            'The vault''s firewall refused this machine. Add its public IP address to keyVault.allowedIpRanges and run deploy.ps1 -FromStage Infrastructure -StopAfter Infrastructure. Nothing changed on the VM.'
        }
        elseif ($text -match '(?i)Forbidden|not authorized|AuthorizationFailed') {
            'Your account needs Key Vault Secrets Officer on the vault: run start-demo.ps1 -Interactive -ResetAdminPassword again (it adds missing role assignments, with assignRoles), or add your object ID to keyVault.operatorObjectIds. Nothing changed on the VM.'
        }
        else {
            'Run start-demo.ps1 -Interactive -ResetAdminPassword again. Nothing changed on the VM.'
        }
        return (New-DemoResult -CheckId 'START.KEYVAULT' -Area 'infra' -Target $target -Status 'Fail' -Message ('The one-time password couldn''t be stored in {0}: {1}' -f $vault.Name, (Get-DemoDeploymentErrorText -Text $text -MaxLength 600)) -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
    }
    $secretId = ([string]$write.StdOut).Trim()
    $version = $secretId.TrimEnd('/').Split('/')[-1]
    $evidence['version'] = $version
    $older = Disable-DemoKeyVaultSecretVersion -SubscriptionId $subscriptionId -VaultName $vault.Name -SecretName $secretName -KeepVersion $version -Confirm:$false
    $evidence['olderVersionsDisabled'] = $older.Disabled
    if ($older.Failed -gt 0 -or $older.Error) {
        Write-DemoLog -Level Warning -Message ('Older versions of {0} couldn''t all be disabled: {1}' -f $secretName, $older.Error)
    }
    $steps = 'To sign in, in the Azure portal open the key vault {0}, then Objects, Secrets, {1}, and the current version, and copy the secret value. Then open {2}, select Connect, then Bastion, choose Username and password (the RDP form has no Key Vault option), enter {3}, and paste the password.' -f $vault.Name, $secretName, $VmName, $userName
    return (New-DemoResult -CheckId 'START.KEYVAULT' -Area 'infra' -Target $target -Status 'Pass' -Message ('The one-time password for {0} on {1} is stored in Key Vault until {2}; it isn''t shown, logged, or copied anywhere else, and stop-demo.ps1 rotates it and disables the secret. {3}' -f $userName, $VmName, $expires, $steps) -Evidence $evidence -DocUrl $docUrl)
}
