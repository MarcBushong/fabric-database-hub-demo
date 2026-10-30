function Set-DemoValidatedAzContext {
    <#
    .SYNOPSIS
    Records the Azure CLI context that the subscription guard validated, for this process only. Internal.

    .DESCRIPTION
    Assert-DemoAzContext calls it once every check has passed. From then on, Invoke-DemoAz allows writes and
    token requests for that subscription, and Get-DemoAccessToken checks every token against the tenant and
    object ID recorded here.

    It's also the documented unit-test hook: a test that exercises a write or a token request against a
    mocked Invoke-DemoAzCli calls it inside the module, for example
    InModuleScope DbHubDemo { Set-DemoValidatedAzContext -SubscriptionId $sub -TenantId $tenant }
    and Clear-DemoValidatedAzContext afterwards. A Pester test checks that no script and no other module
    function calls it, so a real run always goes through the guard.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $TenantId,

        [AllowEmptyString()]
        [string] $Account = '',

        [AllowEmptyString()]
        [string] $ExpectedAccount = '',

        [ValidateSet('User', 'ServicePrincipal', 'ManagedIdentity', 'CloudShell')]
        [string] $AccountKind = 'User',

        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $ObjectId = '',

        [ValidateSet('User', 'ServicePrincipal')]
        [string] $PrincipalType = 'User',

        [AllowEmptyString()]
        [string] $ClientId = '',

        [ValidateSet('Pass', 'Warning')]
        [string] $Status = 'Pass',

        [AllowEmptyString()]
        [string] $Message = '',

        [System.Collections.IDictionary] $Evidence = @{},

        [AllowEmptyString()]
        [string] $Remediation = ''
    )

    if (-not $PSCmdlet.ShouldProcess($SubscriptionId, 'Record the validated Azure CLI context for this process')) {
        return
    }
    $script:DemoAzContext = [pscustomobject]@{
        SubscriptionId  = $SubscriptionId.ToLowerInvariant()
        TenantId        = $TenantId.ToLowerInvariant()
        Account         = $Account
        ExpectedAccount = $ExpectedAccount
        AccountKind     = $AccountKind
        ObjectId        = $ObjectId.ToLowerInvariant()
        PrincipalType   = $PrincipalType
        ClientId        = $ClientId
        Status          = $Status
        Message         = $Message
        Evidence        = $Evidence
        Remediation     = $Remediation
        ValidatedAtUtc  = [System.DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $script:DemoAzContext
}

function Clear-DemoValidatedAzContext {
    # Forgets the validated Azure CLI context, so writes and token requests are refused again. Internal.
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($PSCmdlet.ShouldProcess('the validated Azure CLI context', 'Clear')) {
        $script:DemoAzContext = $null
    }
}

function Get-DemoValidatedAzContext {
    # The validated Azure CLI context for -SubscriptionId, or $null. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $SubscriptionId = ''
    )

    $context = $script:DemoAzContext
    if ($null -eq $context) {
        return $null
    }
    if ($SubscriptionId -and $context.SubscriptionId -ne $SubscriptionId.ToLowerInvariant()) {
        return $null
    }
    return $context
}

function Get-DemoAzArgumentValue {
    <#
    .SYNOPSIS
    The value of the first of -Name found in an Azure CLI argument list ('--flag value' or '--flag=value'),
    and whether it was found. Internal; Invoke-DemoAz uses it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string[]] $Name
    )

    for ($index = 0; $index -lt $ArgumentList.Count; $index++) {
        $argument = [string]$ArgumentList[$index]
        foreach ($flag in $Name) {
            if ($argument -ceq $flag) {
                $value = if ($index + 1 -lt $ArgumentList.Count) { [string]$ArgumentList[$index + 1] } else { '' }
                return [pscustomobject]@{ Found = $true; Value = $value }
            }
            if ($flag.StartsWith('--') -and $argument.StartsWith($flag + '=', [System.StringComparison]::Ordinal)) {
                return [pscustomobject]@{ Found = $true; Value = $argument.Substring($flag.Length + 1) }
            }
        }
    }
    return [pscustomobject]@{ Found = $false; Value = '' }
}

function ConvertFrom-DemoJwtPayload {
    <#
    .SYNOPSIS
    Decodes the payload (the claims) of a JSON Web Token locally. Internal.

    .DESCRIPTION
    Base64url-decodes the second segment and parses it as JSON. No signature check: the token came straight
    from the Azure CLI, and the claims are read only to confirm which tenant and identity it was issued for.
    Errors never include the token.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Token
    )

    $segments = $Token.Split('.')
    if ($segments.Count -lt 3) {
        throw 'The access token is not a JSON Web Token.'
    }
    $payload = $segments[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        1 { throw 'The access token payload is not valid base64url.' }
        2 { $payload += '==' }
        3 { $payload += '=' }
    }
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        return ($json | ConvertFrom-Json -Depth 16)
    }
    catch {
        throw 'The access token payload could not be decoded.'
    }
}

function Get-DemoAccessToken {
    <#
    .SYNOPSIS
    Gets an access token for -Resource from the Azure CLI account of the configured subscription, checks its
    tenant and caller locally, registers it as a secret, and returns it only as a SecureString. Internal.

    .DESCRIPTION
    Runs 'az account get-access-token --resource <resource> --output json' through Invoke-DemoAz, which adds
    '--subscription <id>' and a time limit. The CLI takes the account (user, service principal, or managed
    identity) and the tenant from that subscription's entry, so the token doesn't depend on the default
    subscription. '--tenant' isn't used: the CLI then takes the identity from the default account, which can
    be a different user, and it rejects --tenant together with --subscription (azure-cli 2.91.0, _profile.py
    get_raw_token; live finding, 2026-10-21: a --tenant request for this demo's tenant hung under the Web
    Account Manager while the default account was in another tenant).

    The token is registered with Register-DemoSecret at once, so every log line and result redacts it. Its
    payload is decoded here (ConvertFrom-DemoJwtPayload) and never logged: the tid claim must be the
    expected tenant (the validated context's, or -ExpectedTenantId while the guard runs), and the oid claim
    the validated caller when that's known. A mismatch returns no token.

    -Resource is an https host, plus one audience with a path: the Power BI REST API's
    https://analysis.windows.net/powerbi/api (Phase 19: refresh and Execute Queries in configure-powerbi.ps1).

    Returns Token (SecureString, or $null), Claims (TenantId, ObjectId, ClientId, PrincipalType, Names,
    ExpiresOnUtc: no token material), and Error.

    -Refresh is for a claims challenge (Invoke-DemoRestRequest): the token the Azure CLI cached for -Resource
    was revoked by Continuous Access Evaluation and stays in its cache until it expires, and the CLI can't be
    told to skip it. -Refresh asks for the other spelling of the audience instead ($script:TokenResourceAlternates),
    which the CLI caches separately, so it returns a token issued under the current policies. Every check above
    still applies. Once that token passes, the rest of the process uses that spelling for -Resource. Resources
    without another spelling return no token and an Error.
    https://learn.microsoft.com/cli/azure/account#az-account-get-access-token
    https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group
    https://learn.microsoft.com/entra/identity-platform/app-resilience-continuous-access-evaluation
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidatePattern('^https://[A-Za-z0-9.-]+/?$|^https://analysis\.windows\.net/powerbi/api$')]
        [string] $Resource,

        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $ExpectedTenantId = '',

        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $ExpectedObjectId = '',

        [ValidateRange(1, 600)]
        [int] $TimeoutSeconds = 120,

        [switch] $Refresh
    )

    $context = Get-DemoValidatedAzContext -SubscriptionId $SubscriptionId
    if (-not $ExpectedTenantId -and $null -ne $context) {
        $ExpectedTenantId = $context.TenantId
    }
    if (-not $ExpectedObjectId -and $null -ne $context) {
        $ExpectedObjectId = $context.ObjectId
    }
    $failure = {
        param([string] $Reason)
        [pscustomobject]@{ Token = $null; Claims = $null; Error = $Reason }
    }
    if (-not $ExpectedTenantId) {
        return (& $failure 'No validated Azure CLI context for this subscription: run Assert-DemoAzContext first.')
    }
    $requested = $Resource
    if ($script:DemoTokenResourceInUse.ContainsKey($Resource)) {
        $requested = [string]$script:DemoTokenResourceInUse[$Resource]
    }
    if ($Refresh) {
        if (-not $script:TokenResourceAlternates.ContainsKey($requested)) {
            return (& $failure ('No fresh token for {0}: the Azure CLI cannot skip a cached token for this resource, and replaces it when it expires.' -f $Resource))
        }
        $requested = [string]$script:TokenResourceAlternates[$requested]
    }

    $result = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('account', 'get-access-token', '--resource', $requested, '--output', 'json') -AllowFailure -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        $reason = (Protect-DemoText -Text ([string]$result.StdErr)).Trim()
        if ($reason.Length -gt 400) {
            $reason = $reason.Substring(0, 400) + '...'
        }
        return (& $failure ('No token for {0} is available without interaction: {1}' -f $Resource, $reason))
    }

    $plain = ''
    try {
        $plain = [string](([string]$result.StdOut | ConvertFrom-Json -Depth 8).accessToken)
    }
    catch {
        $plain = ''
    }
    $result = $null
    if (-not $plain) {
        return (& $failure ('The Azure CLI returned no token for {0}.' -f $Resource))
    }
    Register-DemoSecret -Value $plain

    try {
        $claims = ConvertFrom-DemoJwtPayload -Token $plain
    }
    catch {
        $plain = $null
        return (& $failure ('The token for {0} could not be read: {1}' -f $Resource, $_.Exception.Message))
    }

    $tenant = ([string](Get-DemoMemberValue -InputObject $claims -Name 'tid')).ToLowerInvariant()
    $objectId = ([string](Get-DemoMemberValue -InputObject $claims -Name 'oid')).ToLowerInvariant()
    $clientId = [string](Get-DemoMemberValue -InputObject $claims -Name 'appid')
    if (-not $clientId) {
        $clientId = [string](Get-DemoMemberValue -InputObject $claims -Name 'azp')
    }
    $identityType = [string](Get-DemoMemberValue -InputObject $claims -Name 'idtyp')
    $principalType = if ($identityType -eq 'app') { 'ServicePrincipal' } elseif ($identityType -eq 'user' -or (Get-DemoMemberValue -InputObject $claims -Name 'scp')) { 'User' } else { 'ServicePrincipal' }
    $names = @(foreach ($claim in 'upn', 'unique_name', 'preferred_username', 'email') {
            $value = [string](Get-DemoMemberValue -InputObject $claims -Name $claim)
            if ($value) {
                $value -replace '^live\.com#', ''
            }
        }) | Select-Object -Unique
    $expires = Get-DemoMemberValue -InputObject $claims -Name 'exp'
    $expiresOn = if ($expires -as [long]) { [System.DateTimeOffset]::FromUnixTimeSeconds([long]$expires).UtcDateTime.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
    $claims = $null
    $summary = [pscustomobject]@{
        TenantId      = $tenant
        ObjectId      = $objectId
        ClientId      = $clientId
        PrincipalType = $principalType
        Names         = @($names)
        ExpiresOnUtc  = $expiresOn
    }

    if ($tenant -ne $ExpectedTenantId.ToLowerInvariant()) {
        $plain = $null
        return [pscustomobject]@{ Token = $null; Claims = $summary; Error = ('The token for {0} was issued for tenant {1}, not the configured tenant {2}.' -f $Resource, $(if ($tenant) { $tenant } else { '(none)' }), $ExpectedTenantId) }
    }
    if (-not $objectId) {
        $plain = $null
        return [pscustomobject]@{ Token = $null; Claims = $summary; Error = ('The token for {0} has no object ID (oid claim), so its caller cannot be confirmed.' -f $Resource) }
    }
    if ($ExpectedObjectId -and $objectId -ne $ExpectedObjectId.ToLowerInvariant()) {
        $plain = $null
        return [pscustomobject]@{ Token = $null; Claims = $summary; Error = ('The token for {0} belongs to object ID {1}, not the validated caller {2}.' -f $Resource, $objectId, $ExpectedObjectId) }
    }

    $secure = [System.Security.SecureString]::new()
    foreach ($character in $plain.ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    $plain = $null
    if ($Refresh) {
        $script:DemoTokenResourceInUse[$Resource] = $requested
    }
    return [pscustomobject]@{ Token = $secure; Claims = $summary; Error = '' }
}

function Get-DemoSecureStringSha256 {
    # SHA-256 (hex) of a SecureString's value, so two tokens can be compared without keeping or logging either. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [securestring] $Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes([System.Net.NetworkCredential]::new('', $Value).Password)
    try {
        return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
    }
    finally {
        [System.Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Get-DemoClaimsChallenge {
    <#
    .SYNOPSIS
    Whether an HTTP answer is a claims challenge, and its WWW-Authenticate header with the claims value
    redacted. Internal; Invoke-DemoRestRequest uses it.

    .DESCRIPTION
    A claims challenge is a 401 whose WWW-Authenticate header carries error="insufficient_claims" or a claims
    parameter: Continuous Access Evaluation revoked the token, or a policy needs other claims. Microsoft Graph
    can also answer 401 InvalidAuthenticationToken with a Continuous Access Evaluation code in the body
    (TokenCreatedWithOutdatedPolicies or TokenIssuedBeforeRevocationTimestamp; live finding, 2026-10-22). Any
    other 401 (an expired or malformed token) and every other status are not challenges.
    - https://learn.microsoft.com/entra/identity-platform/claims-challenge
    - https://learn.microsoft.com/entra/identity-platform/app-resilience-continuous-access-evaluation
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [int] $StatusCode,

        [AllowEmptyString()]
        [string] $Authenticate = '',

        [AllowEmptyString()]
        [string] $Content = ''
    )

    $isChallenge = $StatusCode -eq 401 -and (
        $Authenticate -match '(?i)\bclaims\s*=|insufficient_claims' -or
        $Content -match '(?i)TokenCreatedWithOutdatedPolicies|TokenIssuedBeforeRevocationTimestamp|insufficient_claims|Continuous access evaluation')
    $redacted = [regex]::Replace($Authenticate, '(?i)\bclaims\s*=\s*("[^"]*"|[^,\s]*)', 'claims="<redacted>"')
    return [pscustomobject]@{ IsChallenge = [bool]$isChallenge; Authenticate = (Protect-DemoText -Text $redacted).Trim() }
}

function Invoke-DemoRestRequest {
    <#
    .SYNOPSIS
    Sends one HTTPS request to Azure Resource Manager or Microsoft Graph with a token that Get-DemoAccessToken
    verified for the configured tenant and caller. Internal; tests mock it.

    .DESCRIPTION
    'az rest' takes its token's account from the subscription in an Azure Resource Manager URL, and from the
    Azure CLI's default account for every other URL; 'az ad' always uses the default account. In a shared
    profile that account can be in another tenant (live finding, 2026-10-21: 'az rest --subscription <id>'
    on Microsoft Graph's /organization answered for the default account's tenant, and a Resource Graph query
    was refused with AccessDenied). Invoke-DemoAz therefore refuses those, and they come here instead: Resource
    Graph and tenant-level Resource Manager reads (built-in and management group policy definitions), and
    Microsoft Graph (the P6 group checks and T1's membership).

    Only https://management.azure.com/ and https://graph.microsoft.com/v1.0/ are allowed. The token travels
    only in the Authorization header (Invoke-WebRequest -Authentication Bearer), is never logged, and comes
    from -Token when the caller already holds a verified one. -ExpectedTenantId and -ExpectedObjectId go to
    Get-DemoAccessToken, for the guard, which calls this before the context is validated.

    A claims challenge (Get-DemoClaimsChallenge: Continuous Access Evaluation revoked the token) is retried
    once: the refused token is dropped, Get-DemoAccessToken -Refresh gets one fresh token, and the same request
    is sent again with it. When the Azure CLI hands back the same token (equal SHA-256 hashes; the values are
    never compared or kept), or gives none, nothing is retried. A failure after a challenge names the request,
    the status, and the WWW-Authenticate header with its claims value redacted.

    A transient failure (a network error, HTTP 408, 429, 502, 503, or 504) is sent again by Invoke-DemoTransientRetry,
    up to 4 attempts: reads, PUTs, and the POSTs that only read; a request that creates or adds something only when it
    never reached the service, or on HTTP 429 (Phase 28 live finding, 2026-10-30). A network error that lasts is StdErr,
    with its innermost cause.

    Returns the shape of an Azure CLI call: ExitCode (0 for a 2xx answer, 1 otherwise), StdOut (the response
    body), StdErr (the redacted error), and StatusCode, plus Retried (the request was sent again with a fresh
    token), Challenge (what happened after a claims challenge, or ''), and Authenticate (the redacted
    WWW-Authenticate header of a challenge, or '').
    - az rest: https://learn.microsoft.com/cli/azure/reference-index#az-rest
    - Microsoft Graph REST API: https://learn.microsoft.com/graph/use-the-api
    - Claims challenges: https://learn.microsoft.com/entra/identity-platform/claims-challenge
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Uri,

        [AllowEmptyString()]
        [string] $Body = '',

        [securestring] $Token,

        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $ExpectedTenantId = '',

        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $ExpectedObjectId = '',

        [ValidateRange(5, 600)]
        [int] $TimeoutSeconds = 120
    )

    $resource = if ($Uri -cmatch '^https://management\.azure\.com/') {
        $script:ArmTokenResource
    }
    elseif ($Uri -cmatch '^https://graph\.microsoft\.com/v1\.0/') {
        $script:GraphTokenResource
    }
    else {
        throw 'Invoke-DemoRestRequest calls only https://management.azure.com/ and https://graph.microsoft.com/v1.0/.'
    }
    if ($Uri -match '(?i)\{subscriptionId\}') {
        throw 'Invoke-DemoRestRequest refuses the {subscriptionId} placeholder: put the configured subscription in the URL.'
    }
    foreach ($match in [regex]::Matches($Uri, '(?i)/subscriptions/([0-9a-f-]{36})')) {
        if ($match.Groups[1].Value -ne $SubscriptionId) {
            throw ("Invoke-DemoRestRequest refuses subscription '{0}'. Only the configured subscription is allowed." -f $match.Groups[1].Value)
        }
    }

    $answer = {
        param([int] $ExitCode, [string] $StdOut, [string] $StdErr, [int] $StatusCode, [bool] $Retried = $false, [string] $Challenge = '', [string] $Authenticate = '')
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr; StatusCode = $StatusCode; Retried = $Retried; Challenge = $Challenge; Authenticate = $Authenticate }
    }
    $tokenRequest = @{ SubscriptionId = $SubscriptionId; Resource = $resource }
    if ($ExpectedTenantId) {
        $tokenRequest['ExpectedTenantId'] = $ExpectedTenantId
    }
    if ($ExpectedObjectId) {
        $tokenRequest['ExpectedObjectId'] = $ExpectedObjectId
    }

    $secure = $Token
    if ($null -eq $secure) {
        $issued = Get-DemoAccessToken @tokenRequest
        if ($null -eq $issued.Token) {
            return (& $answer 1 '' $issued.Error 0)
        }
        $secure = $issued.Token
    }

    $request = @{
        Method             = $Method
        Uri                = $Uri
        Authentication     = 'Bearer'
        Token              = $secure
        SkipHttpErrorCheck = $true
        TimeoutSec         = $TimeoutSeconds
        ErrorAction        = 'Stop'
    }
    if ($Body) {
        $request['Body'] = $Body
        $request['ContentType'] = 'application/json'
    }
    # A transient failure is sent again (Invoke-DemoTransientRetry; Phase 28 live finding, 2026-10-30): any read, a PUT, and
    # the POSTs that only read (Microsoft Graph's getByIds and checkMemberGroups, Resource Graph queries); a request that
    # creates or adds something only when it never reached the service, or on HTTP 429.
    $repeatable = $Method -in 'GET', 'PUT' -or ($Method -eq 'POST' -and $Uri -match '(?i)/directoryObjects/getByIds$|/checkMemberGroups$|/providers/Microsoft\.ResourceGraph/resources\?')
    $send = {
        try {
            $response = Invoke-DemoTransientRetry -Send { param([hashtable] $Call) Invoke-WebRequest @Call } -State $request -Target ([uri]$Uri).Host -NotIdempotent:(-not $repeatable)
        }
        catch {
            return [pscustomobject]@{ Status = 0; Content = ''; Authenticate = ''; Error = (Get-DemoExceptionText -Exception $_.Exception) }
        }
        $content = if ($response.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
        $headers = Get-DemoMemberValue -InputObject $response -Name 'Headers'
        $authenticate = Get-DemoMemberValue -InputObject $headers -Name 'WWW-Authenticate'
        [pscustomobject]@{ Status = [int]$response.StatusCode; Content = $content; Authenticate = ((@($authenticate) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join ', '); Error = '' }
    }

    $sent = & $send
    $retried = $false
    $challenge = ''
    $authenticateHeader = ''
    $claims = Get-DemoClaimsChallenge -StatusCode $sent.Status -Authenticate $sent.Authenticate -Content $sent.Content
    if ($claims.IsChallenge) {
        $authenticateHeader = $claims.Authenticate
        $refusedHash = Get-DemoSecureStringSha256 -Value $secure
        $secure = $null
        $request['Token'] = $null
        $fresh = Get-DemoAccessToken @tokenRequest -Refresh
        if ($null -eq $fresh.Token) {
            $challenge = 'Claims challenge (Continuous Access Evaluation) on the cached token, and the Azure CLI gave no fresh token without interaction: {0}' -f $fresh.Error
        }
        elseif ((Get-DemoSecureStringSha256 -Value $fresh.Token) -eq $refusedHash) {
            $challenge = 'Claims challenge (Continuous Access Evaluation) on the cached token, and the Azure CLI returned the same token (equal SHA-256 hashes), so the request was not sent again.'
        }
        else {
            $request['Token'] = $fresh.Token
            $sent = & $send
            $retried = $true
            $challenge = if ($sent.Status -ge 200 -and $sent.Status -lt 300) {
                'Claims challenge (Continuous Access Evaluation) on the cached token; the request succeeded with one fresh token.'
            }
            else {
                'Claims challenge (Continuous Access Evaluation) on the cached token, and the request failed again with one fresh token.'
            }
            $again = Get-DemoClaimsChallenge -StatusCode $sent.Status -Authenticate $sent.Authenticate -Content $sent.Content
            if ($again.Authenticate) {
                $authenticateHeader = $again.Authenticate
            }
        }
        $fresh = $null
    }
    $request = $null

    if ($sent.Status -eq 0) {
        return (& $answer 1 '' $sent.Error 0 $retried $challenge $authenticateHeader)
    }
    if ($sent.Status -ge 200 -and $sent.Status -lt 300) {
        return (& $answer 0 $sent.Content '' $sent.Status $retried $challenge $authenticateHeader)
    }
    $failureText = 'HTTP {0}: {1}' -f $sent.Status, $sent.Content
    if ($challenge) {
        $failureText = 'HTTP {0} on {1} {2}: {3} {4} WWW-Authenticate: {5}' -f $sent.Status, $Method, $Uri, $sent.Content, $challenge, $(if ($authenticateHeader) { $authenticateHeader } else { '(none)' })
    }
    return (& $answer 1 '' (Protect-DemoText -Text $failureText) $sent.Status $retried $challenge $authenticateHeader)
}

function Resolve-DemoPrincipalType {
    <#
    .SYNOPSIS
    The principal type (User, Group, or ServicePrincipal) of each object ID, from Microsoft Graph with a
    verified token, so role assignments can pass --assignee-principal-type and the Azure CLI never looks the
    principal up in its default account's tenant. Internal.

    .DESCRIPTION
    POST https://graph.microsoft.com/v1.0/directoryObjects/getByIds through Invoke-DemoRestRequest. Returns a
    hashtable keyed by lowercase object ID; IDs Graph didn't return (or couldn't be read) are absent.
    https://learn.microsoft.com/graph/api/directoryobject-getbyids
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [AllowEmptyCollection()]
        [string[]] $ObjectId = @()
    )

    $types = @{}
    $ids = @($ObjectId | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    if ($ids.Count -eq 0) {
        return $types
    }
    $body = [ordered]@{ ids = $ids; types = @('user', 'group', 'servicePrincipal') } | ConvertTo-Json -Compress
    $call = Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'POST' -Uri 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' -Body $body
    if ($call.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$call.StdOut)) {
        return $types
    }
    $map = @{ '#microsoft.graph.user' = 'User'; '#microsoft.graph.group' = 'Group'; '#microsoft.graph.servicePrincipal' = 'ServicePrincipal' }
    foreach ($item in @(([string]$call.StdOut | ConvertFrom-Json -Depth 16).value)) {
        $id = ([string](Get-DemoMemberValue -InputObject $item -Name 'id')).ToLowerInvariant()
        $type = [string](Get-DemoMemberValue -InputObject $item -Name '@odata.type')
        if ($id -and $map.ContainsKey($type)) {
            $types[$id] = $map[$type]
        }
    }
    return $types
}
