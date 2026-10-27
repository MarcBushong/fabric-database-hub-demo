function Get-DemoKeyVaultSetting {
    <#
    .SYNOPSIS
    Returns the keyVault configuration with its defaults: Enabled, PurgeProtection, RetentionDays,
    AllowedIpRanges, OperatorObjectIds, and ReaderObjectIds (ADR 0009). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $section = $Config['keyVault']
    if ($section -isnot [System.Collections.IDictionary]) {
        $section = @{}
    }
    $ranges = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($section['allowedIpRanges'])) {
        if ($item) {
            $ranges.Add([string]$item)
        }
    }
    $lists = @{}
    foreach ($name in 'operatorObjectIds', 'readerObjectIds') {
        $ids = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($section[$name])) {
            $id = ([string]$item).ToLowerInvariant()
            if ($id -and -not $ids.Contains($id)) {
                $ids.Add($id)
            }
        }
        $lists[$name] = $ids.ToArray()
    }
    $retention = if ($null -ne $section['softDeleteRetentionDays']) { [int]$section['softDeleteRetentionDays'] } else { 7 }
    return [pscustomobject]@{
        Enabled           = [bool]$section['enabled']
        PurgeProtection   = [bool]$section['purgeProtection']
        RetentionDays     = $retention
        AllowedIpRanges   = $ranges.ToArray()
        OperatorObjectIds = $lists['operatorObjectIds']
        ReaderObjectIds   = $lists['readerObjectIds']
    }
}

function Get-DemoKeyVaultName {
    <#
    .SYNOPSIS
    The opt-in vault's name, kv-<prefix><environment>-<deploymentId>: at most 24 characters, the same every
    time the environment is deployed, so a deployment after destroy.ps1 finds the soft-deleted vault and
    recovers it. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]{6}$')]
        [string] $DeploymentId
    )

    $base = '{0}{1}' -f $Config['prefix'], $Config['environment']
    if ($base.Length -gt 14) {
        $base = $base.Substring(0, 14)
    }
    return ('kv-{0}-{1}' -f $base, $DeploymentId)
}

function Get-DemoHostPasswordSecretName {
    # The Key Vault secret that holds a VM's one-time administrator password. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName
    )

    return ('{0}-one-time-password' -f $VmName.ToLowerInvariant())
}

function Get-DemoKeyVaultTarget {
    <#
    .SYNOPSIS
    Resolves the opt-in vault from the resource group's deploymentId tag: Name, Id, ResourceGroup,
    DeploymentId, and Tags (the group's tags). Name is empty when the group or its tag is missing. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $tags = Get-DemoResourceGroupTag -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName
    $deploymentId = [string]$tags['deploymentId']
    $name = ''
    $id = ''
    if ($deploymentId -match '^[a-z0-9]{6}$') {
        $name = Get-DemoKeyVaultName -Config $Config -DeploymentId $deploymentId
        $id = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.KeyVault/vaults/{2}' -f $subscriptionId, $resourceGroupName, $name
    }
    return [pscustomobject]@{
        Name          = $name
        Id            = $id
        ResourceGroup = $resourceGroupName
        DeploymentId  = $deploymentId
        Tags          = $tags
    }
}

function Get-DemoCallerIdentity {
    <#
    .SYNOPSIS
    The signed-in caller's object ID and principal type (User or ServicePrincipal) in the configured tenant,
    from the context the subscription guard validated: the oid and idtyp claims of a token issued for the
    configured subscription's account. ObjectId is empty when the guard hasn't run in this process. Internal.

    .DESCRIPTION
    No Microsoft Graph call: 'az ad signed-in-user show' and 'az ad sp show' answer for the Azure CLI's default
    account, which can be in another tenant (live finding, 2026-10-21).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    $context = Get-DemoValidatedAzContext -SubscriptionId $SubscriptionId
    if ($null -eq $context -or -not $context.ObjectId) {
        return [pscustomobject]@{ ObjectId = ''; PrincipalType = 'User' }
    }
    return [pscustomobject]@{
        ObjectId      = [string]$context.ObjectId
        PrincipalType = [string]$context.PrincipalType
    }
}

function Get-DemoKeyVaultSecretVersion {
    <#
    .SYNOPSIS
    Lists a Key Vault secret's versions with 'az keyvault secret list-versions', which returns metadata
    only, never values: SecretFound, Versions (Id, Version, Enabled, ExpiresUtc), and Error. A secret that
    doesn't exist isn't an error. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $VaultName,

        [Parameter(Mandatory)]
        [string] $SecretName
    )

    $versions = [System.Collections.Generic.List[object]]::new()
    $list = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('keyvault', 'secret', 'list-versions', '--vault-name', $VaultName, '--name', $SecretName, '--output', 'json') -AllowFailure
    if ($list.ExitCode -ne 0) {
        $errorText = if ([string]$list.StdErr -match '(?i)SecretNotFound') { '' } else { Get-DemoDeploymentErrorText -Text $list.StdErr -MaxLength 400 }
        return [pscustomobject]@{ SecretFound = $false; Versions = $versions.ToArray(); Error = $errorText }
    }
    $items = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$list.StdOut)) {
        $items = @([string]$list.StdOut | ConvertFrom-Json -Depth 16)
    }
    foreach ($item in $items) {
        $id = [string](Get-DemoMemberValue -InputObject $item -Name 'id')
        if (-not $id) {
            continue
        }
        $attributes = Get-DemoMemberValue -InputObject $item -Name 'attributes'
        $expires = Get-DemoMemberValue -InputObject $attributes -Name 'expires'
        $versions.Add([pscustomobject]@{
                Id         = $id
                Version    = $id.TrimEnd('/').Split('/')[-1]
                Enabled    = [bool](Get-DemoMemberValue -InputObject $attributes -Name 'enabled')
                ExpiresUtc = $(if ($expires -is [datetime]) { $expires.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$expires })
            })
    }
    return [pscustomobject]@{ SecretFound = ($items.Count -gt 0); Versions = $versions.ToArray(); Error = '' }
}

function Disable-DemoKeyVaultSecretVersion {
    <#
    .SYNOPSIS
    Disables every enabled version of a Key Vault secret except -KeepVersion. Internal.

    .DESCRIPTION
    Reads the versions with Get-DemoKeyVaultSecretVersion (metadata only) and disables each enabled one with
    'az keyvault secret set-attributes --enabled false': a disabled version can't be read. Returns
    SecretFound, Disabled, Failed, and Error.
    https://learn.microsoft.com/cli/azure/keyvault/secret#az-keyvault-secret-set-attributes
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $VaultName,

        [Parameter(Mandatory)]
        [string] $SecretName,

        [string] $KeepVersion = ''
    )

    $listing = Get-DemoKeyVaultSecretVersion -SubscriptionId $SubscriptionId -VaultName $VaultName -SecretName $SecretName
    $outcome = [pscustomobject]@{ SecretFound = $listing.SecretFound; Disabled = 0; Failed = 0; Error = $listing.Error }
    foreach ($version in @($listing.Versions | Where-Object { $_.Enabled -and $_.Version -ne $KeepVersion })) {
        if (-not $PSCmdlet.ShouldProcess($version.Id, 'Disable the secret version')) {
            continue
        }
        $update = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('keyvault', 'secret', 'set-attributes', '--id', $version.Id, '--enabled', 'false', '--output', 'none') -AllowFailure
        if ($update.ExitCode -eq 0) {
            $outcome.Disabled++
        }
        else {
            $outcome.Failed++
            $outcome.Error = Get-DemoDeploymentErrorText -Text $update.StdErr -MaxLength 400
        }
    }
    return $outcome
}

function Get-DemoKeyVaultStatus {
    <#
    .SYNOPSIS
    STATUS.KEYVAULT for status.ps1: whether the opt-in vault exists, and whether a readable one-time password
    is in it, from metadata only (Get-DemoKeyVaultSecretVersion never reads a value). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $DeploymentId = '',

        [string] $VmName = 'archost01',

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $target = if ($VmName -eq 'sqlvm01') { 'T1' } else { 'T2' }
    $docUrl = 'https://learn.microsoft.com/azure/key-vault/general/rbac-guide'
    $create = 'deploy.ps1 -FromStage Infrastructure -StopAfter Infrastructure creates it, and so does start-demo.ps1 -Interactive -ResetAdminPassword.'
    if ($DeploymentId -notmatch '^[a-z0-9]{6}$') {
        return (New-DemoResult -CheckId 'STATUS.KEYVAULT' -Area 'infra' -Target $target -Status 'Warning' -Message 'keyVault.enabled is true, but the resource group has no deploymentId tag, so the vault has no name yet.' -Remediation $create -DocUrl $docUrl)
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $vaultName = Get-DemoKeyVaultName -Config $Config -DeploymentId $DeploymentId
    $exists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('keyvault', 'show', '--name', $vaultName, '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--query', 'id', '--output', 'tsv') -AllowFailure
    if ($exists.ExitCode -ne 0) {
        return (New-DemoResult -CheckId 'STATUS.KEYVAULT' -Area 'infra' -Target $target -Status 'Warning' -Message ('keyVault.enabled is true, but the vault {0} doesn''t exist yet.' -f $vaultName) -Remediation $create -DocUrl $docUrl)
    }
    $secretName = Get-DemoHostPasswordSecretName -VmName $VmName
    $listing = Get-DemoKeyVaultSecretVersion -SubscriptionId $subscriptionId -VaultName $vaultName -SecretName $secretName
    $readable = @($listing.Versions | Where-Object { $_.Enabled })
    $evidence = [ordered]@{ vaultName = $vaultName; secretName = $secretName; versions = @($listing.Versions).Count; readable = $readable.Count }
    if ($listing.Error) {
        return (New-DemoResult -CheckId 'STATUS.KEYVAULT' -Area 'infra' -Target $target -Status 'Warning' -Message ('The vault {0} exists, but its secrets couldn''t be listed: {1}' -f $vaultName, $listing.Error) -Evidence $evidence -Remediation 'Reading the list needs Key Vault Secrets Officer or Key Vault Secrets User on the vault (keyVault.operatorObjectIds, keyVault.readerObjectIds).' -DocUrl $docUrl)
    }
    if ($readable.Count -eq 0) {
        return (New-DemoResult -CheckId 'STATUS.KEYVAULT' -Area 'infra' -Target $target -Status 'Pass' -Message ('The vault {0} exists, and no one-time password can be read from it.' -f $vaultName) -Evidence $evidence -DocUrl $docUrl)
    }
    $expired = @($readable | Where-Object {
            $expiry = [datetime]::MinValue
            $_.ExpiresUtc -and [datetime]::TryParse([string]$_.ExpiresUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiry) -and $expiry -lt $NowUtc
        })
    if ($expired.Count -gt 0) {
        return (New-DemoResult -CheckId 'STATUS.KEYVAULT' -Area 'infra' -Target $target -Status 'Warning' -Message ('The vault {0} still lets {1} version(s) of {2} be read after their expiry.' -f $vaultName, $expired.Count, $secretName) -Evidence $evidence -Remediation 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly: it rotates the host password and disables the secret.' -DocUrl $docUrl)
    }
    $until = @($readable | ForEach-Object { $_.ExpiresUtc } | Where-Object { $_ } | Sort-Object -Descending) | Select-Object -First 1
    return (New-DemoResult -CheckId 'STATUS.KEYVAULT' -Area 'infra' -Target $target -Status 'Pass' -Message ('The vault {0} holds the one-time password for {1}{2}; stop-demo.ps1 rotates it and disables the secret.' -f $vaultName, $VmName, $(if ($until) { ' until ' + $until } else { '' })) -Evidence $evidence -DocUrl $docUrl)
}
