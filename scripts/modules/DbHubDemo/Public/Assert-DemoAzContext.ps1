function Assert-DemoAzContext {
    <#
    .SYNOPSIS
    The subscription guard: confirms, once per process and without relying on the Azure CLI's default
    subscription, that every authentication path the scripts use reaches the configured subscription and
    tenant as the expected account. Fails closed.

    .DESCRIPTION
    The default subscription of a shared Azure CLI profile can belong to another tenant at any moment (live
    finding, 2026-10-21), so the guard neither reads nor changes it (ADR 0011, updated 2026-10-21). Every
    call goes through Invoke-DemoAz with '--subscription <id>' and a time limit:
    1. account: 'az account show --subscription <id>', the profile entry the Azure CLI uses for that
       subscription, must return the configured subscription and tenant. With -Account (the configuration's
       azureAccount: a user principal name, or the client ID of a service principal or managed identity), the
       entry's account must match it; without it, the account is reported and the result is a Warning.
    2. Read-only canaries, each explicitly targeted:
       - canary.arm: an Azure Resource Manager read through a CLI command ('az group list').
       - canary.armRest: 'az rest --method get' on https://management.azure.com/subscriptions/<id>; the
         answer's tenantId must be the configured tenant.
       - canary.armToken, canary.fabricToken, canary.kustoToken, canary.graphToken: tokens for Azure Resource
         Manager (Arc onboarding), Microsoft Fabric, the Hub telemetry endpoint's Kusto audience, and
         Microsoft Graph, from 'az account get-access-token --subscription <id>' (Get-DemoAccessToken). Each
         token's tid claim must be the configured tenant and its oid claim the same caller; the Resource
         Manager token's identity must be the account from step 1. Tokens are decoded locally and never
         logged or returned. '--tenant' isn't used: the Azure CLI then takes the identity from the default
         account, and it rejects --tenant together with --subscription.
       - canary.graphOrganization (users only): Microsoft Graph's /organization read with that token must
         answer for the configured tenant. A claims challenge (Continuous Access Evaluation revoked the cached
         token) is retried once with a fresh token, checked like the first; the evidence's graphChallenge
         records the request, the status, the outcome, and the WWW-Authenticate header with its claims value
         redacted. A refused read is a Warning, because the token's tenant is verified.
    On success the validated context is cached in the module for the rest of the process (a second call
    returns it without calling Azure), and Invoke-DemoAz allows writes and token requests. Any failed check
    clears it and throws, naming the check, so nothing is written. The guard never signs in, never changes
    the Azure CLI context, and never prints a token.
    In GitHub Actions, it first masks the subscription, the tenant, and the account, then the caller's object and
    client IDs and any other ID a failed check names (Register-DemoLogMask), so a public repository's job log,
    job summary, and results show them as *** (ADR 0022).
    Sources: https://learn.microsoft.com/cli/azure/account#az-account-show,
    https://learn.microsoft.com/cli/azure/account#az-account-get-access-token,
    https://learn.microsoft.com/cli/azure/reference-index#az-rest,
    https://learn.microsoft.com/rest/api/resources/subscriptions/get,
    https://learn.microsoft.com/graph/api/organization-get

    .PARAMETER Account
    The expected account (the configuration's azureAccount). Empty: report the account with a Warning.

    .PARAMETER Force
    Validate again even when this process already did.

    .EXAMPLE
    Assert-DemoAzContext -SubscriptionId $config.subscriptionId -TenantId $config.tenantId -Account $config.azureAccount
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $TenantId,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $Account = '',

        [switch] $Force
    )

    $SubscriptionId = $SubscriptionId.ToLowerInvariant()
    $TenantId = $TenantId.ToLowerInvariant()
    $Account = ([string]$Account).Trim()
    $checkId = 'PREFLIGHT.GUARD.CONTEXT'
    # In GitHub Actions only: the guard's messages name the subscription, the tenant, and the account, so they're
    # masked in the job log before the first line is written (ADR 0022).
    Register-DemoLogMask -Value @($SubscriptionId, $TenantId, $Account)

    $cached = Get-DemoValidatedAzContext -SubscriptionId $SubscriptionId
    if ($null -ne $cached -and -not $Force -and $cached.TenantId -eq $TenantId -and [string]$cached.ExpectedAccount -ieq $Account) {
        $evidence = [ordered]@{}
        foreach ($key in $cached.Evidence.Keys) {
            $evidence[$key] = $cached.Evidence[$key]
        }
        $evidence['cached'] = $true
        return (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'subscription' -Status $cached.Status -Message ('{0} (Validated earlier in this process, at {1}.)' -f $cached.Message, $cached.ValidatedAtUtc) -Evidence $evidence -Remediation $cached.Remediation)
    }

    Clear-DemoValidatedAzContext
    $signIn = "Sign in once with 'az login --tenant $TenantId' as the account that runs the demo. You don't need to change your default subscription, and the scripts never do. Where the Azure CLI profile is shared with other work, you can sign in under a separate AZURE_CONFIG_DIR instead (docs/prerequisites.md)."
    $timeLimit = 120
    $checks = [ordered]@{}

    function Deny-GuardCheck([string] $Check, [string] $Reason, [string] $Help = $signIn) {
        $checks[$Check] = 'Fail'
        # Another tenant's or subscription's ID in the reason is masked too, in GitHub Actions only.
        Register-DemoLogMask -Value @([regex]::Matches($Reason, $script:DemoLogGuidPattern) | ForEach-Object { $_.Value })
        throw ("Subscription guard: check '{0}' failed: {1} Nothing was changed. {2}" -f $Check, $Reason.Trim(), $Help)
    }
    function Get-ShortError([string] $Text) {
        $short = (Protect-DemoText -Text $Text).Trim()
        if ($short.Length -gt 300) {
            $short = $short.Substring(0, 300) + '...'
        }
        return $short
    }

    $script:DemoAzGuardActive = $true
    try {
        Write-DemoLog -Message ('Subscription guard: checking the Azure CLI account and every authentication path for subscription {0}, without the default subscription.' -f $SubscriptionId)

        # 1. The profile entry the Azure CLI uses for this subscription (local, no network call).
        $show = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('account', 'show', '--output', 'json') -AllowFailure -TimeoutSeconds 60
        $entry = $null
        if ($show.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$show.StdOut)) {
            $entry = [string]$show.StdOut | ConvertFrom-Json -Depth 16
        }
        if ($null -eq $entry) {
            Deny-GuardCheck 'account' ('the Azure CLI has no account for subscription {0}: {1}' -f $SubscriptionId, (Get-ShortError -Text ([string]$show.StdErr)))
        }
        $entryId = ([string](Get-DemoMemberValue -InputObject $entry -Name 'id')).ToLowerInvariant()
        $entryTenant = ([string](Get-DemoMemberValue -InputObject $entry -Name 'tenantId')).ToLowerInvariant()
        if ($entryId -ne $SubscriptionId) {
            Deny-GuardCheck 'account' ('the Azure CLI returned subscription {0} for subscription {1}.' -f $entryId, $SubscriptionId)
        }
        if ($entryTenant -ne $TenantId) {
            Deny-GuardCheck 'account' ('the Azure CLI has subscription {0} in tenant {1}, not the configured tenant {2}.' -f $SubscriptionId, $entryTenant, $TenantId)
        }
        $user = Get-DemoMemberValue -InputObject $entry -Name 'user'
        $userName = [string](Get-DemoMemberValue -InputObject $user -Name 'name')
        $userType = [string](Get-DemoMemberValue -InputObject $user -Name 'type')
        $assignedIdentity = [string](Get-DemoMemberValue -InputObject $user -Name 'assignedIdentityInfo')
        $kind = if ($userName -in 'systemAssignedIdentity', 'userAssignedIdentity') {
            'ManagedIdentity'
        }
        elseif ([bool](Get-DemoMemberValue -InputObject $user -Name 'cloudShellID')) {
            'CloudShell'
        }
        elseif ($userType -eq 'servicePrincipal') {
            'ServicePrincipal'
        }
        else {
            'User'
        }
        $signedIn = $userName
        if ($kind -eq 'ManagedIdentity') {
            $signedIn = if ($assignedIdentity -match '^MSIClient-(.+)$') { $Matches[1] } else { '' }
        }
        Register-DemoLogMask -Value @($signedIn)
        $accountHelp = "Sign in as the expected account ('az login --tenant $TenantId'), or correct azureAccount in the configuration. You don't need to change your default subscription."
        if ($Account -and $signedIn -and $signedIn -ine $Account) {
            Deny-GuardCheck 'account' ("the Azure CLI reaches subscription {0} as '{1}', not as azureAccount '{2}'." -f $SubscriptionId, $signedIn, $Account) $accountHelp
        }
        $checks['account'] = if ($Account) { 'Pass' } else { 'Warning' }

        # 2a. Azure Resource Manager through a CLI command.
        $groups = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('group', 'list', '--query', '[].id', '--output', 'json') -AllowFailure -TimeoutSeconds $timeLimit
        if ($groups.ExitCode -ne 0) {
            Deny-GuardCheck 'canary.arm' ('az group list --subscription {0} failed: {1}' -f $SubscriptionId, (Get-ShortError -Text ([string]$groups.StdErr)))
        }
        $groupIds = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$groups.StdOut)) {
            $groupIds = @([string]$groups.StdOut | ConvertFrom-Json -Depth 8)
        }
        $prefix = '/subscriptions/{0}/' -f $SubscriptionId
        if (@($groupIds | Where-Object { $_ -and -not ([string]$_).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
            Deny-GuardCheck 'canary.arm' ('az group list --subscription {0} returned resource groups of another subscription.' -f $SubscriptionId)
        }
        $checks['canary.arm'] = 'Pass'

        # 2b. az rest on the fully qualified subscription URL.
        $url = 'https://management.azure.com/subscriptions/{0}?api-version={1}' -f $SubscriptionId, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Resources/subscriptions')
        $rest = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $url, '--output', 'json') -AllowFailure -TimeoutSeconds $timeLimit
        if ($rest.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$rest.StdOut)) {
            Deny-GuardCheck 'canary.armRest' ('az rest --subscription {0} on the subscription URL failed: {1}' -f $SubscriptionId, (Get-ShortError -Text ([string]$rest.StdErr)))
        }
        $subscription = [string]$rest.StdOut | ConvertFrom-Json -Depth 16
        $restTenant = ([string](Get-DemoMemberValue -InputObject $subscription -Name 'tenantId')).ToLowerInvariant()
        $restId = ([string](Get-DemoMemberValue -InputObject $subscription -Name 'subscriptionId')).ToLowerInvariant()
        if ($restId -ne $SubscriptionId -or $restTenant -ne $TenantId) {
            Deny-GuardCheck 'canary.armRest' ('Azure Resource Manager answered for subscription {0} in tenant {1}.' -f $restId, $restTenant)
        }
        $checks['canary.armRest'] = 'Pass'

        # 2c. The Azure Resource Manager token: the reference identity for every other token.
        $arm = Get-DemoAccessToken -SubscriptionId $SubscriptionId -Resource $script:ArmTokenResource -ExpectedTenantId $TenantId -TimeoutSeconds $timeLimit
        if ($null -eq $arm.Token) {
            Deny-GuardCheck 'canary.armToken' $arm.Error
        }
        $claims = $arm.Claims
        Register-DemoLogMask -Value @($claims.ObjectId, $claims.ClientId)
        if ($kind -in 'User', 'CloudShell') {
            if (@($claims.Names).Count -gt 0 -and @($claims.Names | Where-Object { $_ -ieq $userName }).Count -eq 0) {
                Deny-GuardCheck 'canary.armToken' ("the token was issued to '{0}', not to the Azure CLI account '{1}'." -f (@($claims.Names)[0]), $userName)
            }
        }
        elseif ($kind -eq 'ServicePrincipal') {
            if ($claims.ClientId -ine $userName) {
                Deny-GuardCheck 'canary.armToken' ("the token was issued to client ID '{0}', not to the Azure CLI account '{1}'." -f $claims.ClientId, $userName)
            }
        }
        elseif ($signedIn) {
            if ($claims.ClientId -ine $signedIn) {
                Deny-GuardCheck 'canary.armToken' ("the token was issued to client ID '{0}', not to the managed identity '{1}'." -f $claims.ClientId, $signedIn)
            }
        }
        else {
            $signedIn = $claims.ClientId
            if ($Account -and $signedIn -ine $Account) {
                Deny-GuardCheck 'account' ("the Azure CLI reaches subscription {0} as the managed identity '{1}', not as azureAccount '{2}'." -f $SubscriptionId, $signedIn, $Account) $accountHelp
            }
        }
        $checks['canary.armToken'] = 'Pass'

        # 2d-f. Fabric, Kusto (Hub telemetry), and Microsoft Graph tokens: same tenant, same caller.
        $kustoResource = [string](Get-DemoHubSetting)['telemetry']['tokenAudience']
        $graph = $null
        foreach ($canary in @(
                @{ Check = 'canary.fabricToken'; Resource = $script:FabricTokenResource }
                @{ Check = 'canary.kustoToken'; Resource = $kustoResource }
                @{ Check = 'canary.graphToken'; Resource = $script:GraphTokenResource }
            )) {
            $issued = Get-DemoAccessToken -SubscriptionId $SubscriptionId -Resource $canary.Resource -ExpectedTenantId $TenantId -ExpectedObjectId $claims.ObjectId -TimeoutSeconds $timeLimit
            if ($null -eq $issued.Token) {
                Deny-GuardCheck $canary.Check $issued.Error
            }
            $checks[$canary.Check] = 'Pass'
            if ($canary.Check -eq 'canary.graphToken') {
                $graph = $issued.Token
            }
        }

        # 2g. Microsoft Graph answers for the configured tenant (users; an app needs Graph permissions to read it).
        # A claims challenge is retried once with a fresh token (Invoke-DemoRestRequest), checked for the same
        # tenant and caller.
        $notes = [System.Collections.Generic.List[string]]::new()
        $graphChallenge = $null
        if ($claims.PrincipalType -eq 'User') {
            $organizationUri = 'https://graph.microsoft.com/v1.0/organization?$select=id'
            $organization = Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'GET' -Uri $organizationUri -Token $graph -ExpectedTenantId $TenantId -ExpectedObjectId $claims.ObjectId -TimeoutSeconds 60
            $challenge = [string](Get-DemoMemberValue -InputObject $organization -Name 'Challenge')
            if ($challenge) {
                $graphChallenge = [ordered]@{
                    request         = 'GET ' + $organizationUri
                    status          = $organization.StatusCode
                    retried         = [bool](Get-DemoMemberValue -InputObject $organization -Name 'Retried')
                    outcome         = $challenge
                    wwwAuthenticate = [string](Get-DemoMemberValue -InputObject $organization -Name 'Authenticate')
                }
            }
            if ($organization.ExitCode -eq 0) {
                $organizationId = ([string](@(([string]$organization.StdOut | ConvertFrom-Json -Depth 16).value) | Select-Object -First 1 | ForEach-Object { Get-DemoMemberValue -InputObject $_ -Name 'id' })).ToLowerInvariant()
                if ($organizationId -ne $TenantId) {
                    Deny-GuardCheck 'canary.graphOrganization' ('Microsoft Graph answered for tenant {0}, not the configured tenant {1}.' -f $organizationId, $TenantId)
                }
                $checks['canary.graphOrganization'] = 'Pass'
                if ($challenge) {
                    $notes.Add(('Microsoft Graph: {0}' -f $challenge))
                }
            }
            else {
                $checks['canary.graphOrganization'] = 'Warning'
                $note = "Microsoft Graph refused the organization read (HTTP {0}); the Graph token's tenant was verified." -f $organization.StatusCode
                if ($challenge) {
                    $note += ' ' + $challenge
                }
                $notes.Add($note)
            }
        }
        else {
            $checks['canary.graphOrganization'] = 'Not selected'
        }
        $graph = $null
        $arm = $null

        $status = if (@($checks.Values | Where-Object { $_ -eq 'Warning' }).Count -gt 0) { 'Warning' } else { 'Pass' }
        $who = if ($signedIn) { $signedIn } else { $userName }
        $message = "The Azure CLI reaches subscription $SubscriptionId in tenant $TenantId as '$who' through every authentication path the scripts use (Azure Resource Manager through az and az rest, and Resource Manager, Fabric, Kusto, and Microsoft Graph tokens), without the default subscription."
        $remediation = ''
        if (-not $Account) {
            $message += " azureAccount isn't set, so any account that reaches the subscription passes."
            $remediation = "Set azureAccount to '$who' in the configuration, so another account fails the guard (docs/prerequisites.md)."
        }
        foreach ($note in $notes) {
            $message += ' ' + $note
        }
        $evidence = [ordered]@{
            subscriptionId         = $SubscriptionId
            tenantId               = $TenantId
            account                = $who
            accountKind            = $kind
            azureAccountConfigured = [bool]$Account
            principalType          = $claims.PrincipalType
            objectId               = $claims.ObjectId
            tokenExpiresOnUtc      = $claims.ExpiresOnUtc
            checks                 = $checks
            cached                 = $false
        }
        if ($null -ne $graphChallenge) {
            $evidence['graphChallenge'] = $graphChallenge
        }
        $null = Set-DemoValidatedAzContext -SubscriptionId $SubscriptionId -TenantId $TenantId -Account $who -ExpectedAccount $Account -AccountKind $kind -ObjectId $claims.ObjectId -PrincipalType $claims.PrincipalType -ClientId $claims.ClientId -Status $status -Message $message -Evidence $evidence -Remediation $remediation
        return (New-DemoResult -CheckId $checkId -Area 'preflight' -Target 'subscription' -Status $status -Message $message -Evidence $evidence -Remediation $remediation)
    }
    catch {
        Clear-DemoValidatedAzContext
        throw
    }
    finally {
        $script:DemoAzGuardActive = $false
    }
}
