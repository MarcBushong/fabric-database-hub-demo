# Shared fakes for the subscription guard and the validated Azure CLI context (2026-10-21). Dot-sourced in
# BeforeAll after DbHubDemo is imported; not a test file. IDs are obvious placeholders, and tokens are built at
# run time so secret scanners don't flag them.

$script:GuardTestSubscriptionId = '11111111-2222-3333-4444-555555555555'
$script:GuardTestTenantId = '66666666-7777-8888-9999-000000000000'
$script:GuardTestObjectId = '88888888-8888-8888-8888-888888888888'

function ConvertTo-GuardTestBase64Url([string] $Text) {
    [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-GuardTestToken {
    <#
    A fake access token whose payload Get-DemoAccessToken can decode (tid and oid claims). The first segment
    isn't a JWT header, so the token doesn't match the logger's JWT pattern: only its registration as a
    secret redacts it, which is what the redaction tests check.
    #>
    param(
        [string] $TenantId = $script:GuardTestTenantId,
        [string] $ObjectId = $script:GuardTestObjectId,
        [string] $PrincipalType = 'User'
    )
    $claims = [ordered]@{ tid = $TenantId; oid = $ObjectId; idtyp = $(if ($PrincipalType -eq 'User') { 'user' } else { 'app' }); nonce = [guid]::NewGuid().ToString('N') }
    return ('tok{0}.{1}.sig{2}' -f [guid]::NewGuid().ToString('N'), (ConvertTo-GuardTestBase64Url ($claims | ConvertTo-Json -Compress)), [guid]::NewGuid().ToString('N'))
}

function ConvertTo-GuardTestTokenResult([string] $Token) {
    # What 'az account get-access-token --output json' prints, for a mocked Invoke-DemoAzCli.
    [pscustomobject]@{ ExitCode = 0; StdOut = (@{ accessToken = $Token; expiresOn = '2100-01-01 00:00:00.000000' } | ConvertTo-Json); StdErr = '' }
}

function Initialize-GuardTestContext {
    <#
    The documented unit-test hook: records a validated Azure CLI context in DbHubDemo (Set-DemoValidatedAzContext),
    so writes and token requests through Invoke-DemoAz are allowed without running the subscription guard.
    -Clear forgets it again.
    #>
    param(
        [string] $SubscriptionId = $script:GuardTestSubscriptionId,
        [string] $TenantId = $script:GuardTestTenantId,
        [string] $ObjectId = $script:GuardTestObjectId,
        [string] $PrincipalType = 'User',
        [switch] $Clear
    )
    $module = Get-Module -Name 'DbHubDemo'
    if ($Clear) {
        & $module { Clear-DemoValidatedAzContext }
        return
    }
    & $module {
        param($Subscription, $Tenant, $Object, $Type)
        $null = Set-DemoValidatedAzContext -SubscriptionId $Subscription -TenantId $Tenant -ObjectId $Object -PrincipalType $Type
    } $SubscriptionId $TenantId $ObjectId $PrincipalType
}
