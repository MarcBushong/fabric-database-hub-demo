BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    $script:sub = $script:GuardTestSubscriptionId
    $script:tenant = $script:GuardTestTenantId
    $script:caller = $script:GuardTestObjectId
    $script:otherTenant = 'abababab-abab-abab-abab-abababababab'
    $script:organizationUri = 'https://graph.microsoft.com/v1.0/organization?$select=id'

    function ConvertTo-TestSecureString([string] $Text) {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in $Text.ToCharArray()) {
            $secure.AppendChar($character)
        }
        $secure.MakeReadOnly()
        return $secure
    }

    # A claims challenge in the form Learn documents, and the 401 body Microsoft Graph sent on 2026-10-22. The
    # claims value and the tokens are built at run time, so no secret-shaped literal is in the repository.
    $script:claimsValue = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(('{{"access_token":{{"nbf":{{"essential":true,"value":"{0}"}}}}}}' -f [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds())))
    $script:challengeHeader = 'Bearer realm="", authorization_uri="https://login.microsoftonline.com/common/oauth2/authorize", error="insufficient_claims", claims="{0}"' -f $script:claimsValue
    $script:caeBody = '{"error":{"code":"InvalidAuthenticationToken","message":"Continuous access evaluation resulted in challenge with result: InteractionRequired and code: TokenCreatedWithOutdatedPolicies"}}'

    function New-TestResponse([int] $Status, [string] $Content = '{"value":[{"id":"x"}]}', [string] $Authenticate = '') {
        $headers = @{}
        if ($Authenticate) {
            $headers['WWW-Authenticate'] = @($Authenticate)
        }
        return [pscustomobject]@{ StatusCode = $Status; Content = $Content; Headers = $headers }
    }

    function Set-RestMock {
        # Invoke-WebRequest answers from -Response in order; Get-DemoAccessToken hands out the cached token, or
        # with -Refresh the fresh one ($null: no token, with -RefreshError).
        param([object[]] $Response, [AllowNull()] [string] $Fresh = ('fresh-' + [guid]::NewGuid().ToString('N')), [string] $RefreshError = '')
        $script:responses = [System.Collections.Generic.Queue[object]]::new([object[]]$Response)
        $script:sentTokens = [System.Collections.Generic.List[string]]::new()
        $script:cachedToken = 'cached-' + [guid]::NewGuid().ToString('N')
        $script:freshToken = $Fresh
        $script:refreshError = $RefreshError
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $script:sentTokens.Add([System.Net.NetworkCredential]::new('', $Token).Password)
            $script:responses.Dequeue()
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -MockWith {
            $value = if ($PesterBoundParameters.ContainsKey('Refresh') -and $PesterBoundParameters['Refresh']) { $script:freshToken } else { $script:cachedToken }
            if (-not $value) {
                return [pscustomobject]@{ Token = $null; Claims = $null; Error = $script:refreshError }
            }
            [pscustomobject]@{ Token = (ConvertTo-TestSecureString $value); Claims = $null; Error = '' }
        }
    }

    function Invoke-TestRequest {
        param([securestring] $Token, [switch] $WithExpected, [string] $Method = 'GET', [string] $Uri = $script:organizationUri)
        $parameters = @{ SubscriptionId = $script:sub; Method = $Method; Uri = $Uri }
        if ($Token) {
            $parameters['Token'] = $Token
        }
        if ($WithExpected) {
            $parameters['ExpectedTenantId'] = $script:tenant
            $parameters['ExpectedObjectId'] = $script:caller
        }
        InModuleScope DbHubDemo -Parameters @{ Request = $parameters } { Invoke-DemoRestRequest @Request }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Invoke-DemoRestRequest after a claims challenge (Continuous Access Evaluation)' {
    It 'drops the refused token and retries once with one fresh token (challenge in <Where>)' -ForEach @(
        @{ Where = 'the WWW-Authenticate header'; Header = 'challenge'; Body = '{"error":{"code":"InvalidAuthenticationToken"}}' }
        @{ Where = 'the response body'; Header = ''; Body = 'cae' }
    ) {
        $header = if ($Header) { $script:challengeHeader } else { '' }
        $content = if ($Body -eq 'cae') { $script:caeBody } else { $Body }
        Set-RestMock -Response @((New-TestResponse -Status 401 -Content $content -Authenticate $header), (New-TestResponse -Status 200))

        $result = Invoke-TestRequest

        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Match '"id":"x"'
        $result.Retried | Should -BeTrue
        $result.Challenge | Should -Match 'succeeded with one fresh token'
        $script:sentTokens | Should -Be @($script:cachedToken, $script:freshToken)
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -Times 1 -Exactly -ParameterFilter { $Refresh }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 2 -Exactly
    }

    It 'drops a refused token that the caller passed, and never sends it again' {
        Set-RestMock -Response @((New-TestResponse -Status 401 -Content $script:caeBody -Authenticate $script:challengeHeader), (New-TestResponse -Status 200))
        $passed = ConvertTo-TestSecureString $script:cachedToken

        $result = Invoke-TestRequest -Token $passed

        $result.ExitCode | Should -Be 0
        $script:sentTokens | Should -Be @($script:cachedToken, $script:freshToken)
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -Times 0 -ParameterFilter { -not $Refresh }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -Times 1 -Exactly -ParameterFilter { $Refresh }
    }

    It 'sends nothing again when the Azure CLI returns the same token, and says so' {
        Set-RestMock -Response @((New-TestResponse -Status 401 -Content $script:caeBody -Authenticate $script:challengeHeader))
        $script:freshToken = $script:cachedToken

        $result = Invoke-TestRequest

        $result.ExitCode | Should -Be 1
        $result.StatusCode | Should -Be 401
        $result.Retried | Should -BeFalse
        $result.Challenge | Should -Match 'returned the same token \(equal SHA-256 hashes\)'
        $result.StdErr | Should -Match ([regex]::Escape('HTTP 401 on GET ' + $script:organizationUri))
        $result.StdErr | Should -Not -Match ([regex]::Escape($script:cachedToken))
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 1 -Exactly
    }

    It 'names the request, the status, and the header with its claims value redacted when the fresh token is refused too' {
        Set-RestMock -Response @(
            (New-TestResponse -Status 401 -Content $script:caeBody -Authenticate $script:challengeHeader)
            (New-TestResponse -Status 401 -Content $script:caeBody -Authenticate $script:challengeHeader)
        )

        $result = Invoke-TestRequest

        $result.ExitCode | Should -Be 1
        $result.Retried | Should -BeTrue
        $result.Challenge | Should -Match 'failed again with one fresh token'
        $result.StdErr | Should -Match ([regex]::Escape('HTTP 401 on GET ' + $script:organizationUri))
        $result.StdErr | Should -Match 'TokenCreatedWithOutdatedPolicies'
        $result.StdErr | Should -Match ([regex]::Escape('error="insufficient_claims", claims="<redacted>"'))
        $result.Authenticate | Should -Match ([regex]::Escape('claims="<redacted>"'))
        foreach ($text in $result.StdErr, $result.Authenticate, $result.Challenge) {
            $text | Should -Not -Match ([regex]::Escape($script:claimsValue))
            $text | Should -Not -Match ([regex]::Escape($script:freshToken))
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -Times 1 -Exactly -ParameterFilter { $Refresh }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 2 -Exactly
    }

    It 'reports a refresh that gives no token without sending the request again' {
        Set-RestMock -Response @((New-TestResponse -Status 401 -Content $script:caeBody -Authenticate $script:challengeHeader)) -Fresh '' -RefreshError 'AADSTS50076: multi-factor authentication is required.'

        $result = Invoke-TestRequest

        $result.ExitCode | Should -Be 1
        $result.Retried | Should -BeFalse
        $result.Challenge | Should -Match 'no fresh token without interaction: AADSTS50076'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 1 -Exactly
    }

    It 'checks the fresh token against the expected tenant and caller it was given' {
        Set-RestMock -Response @((New-TestResponse -Status 401 -Content $script:caeBody -Authenticate $script:challengeHeader), (New-TestResponse -Status 200))

        Invoke-TestRequest -WithExpected | Out-Null

        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -Times 2 -Exactly -ParameterFilter { $ExpectedTenantId -eq $script:tenant -and $ExpectedObjectId -eq $script:caller }
    }

    It 'retries a POST once too, because a 401 means it was not carried out' {
        Set-RestMock -Response @((New-TestResponse -Status 401 -Content $script:caeBody -Authenticate $script:challengeHeader), (New-TestResponse -Status 200))
        $result = Invoke-TestRequest -Method 'POST' -Uri 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds'
        $result.ExitCode | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 2 -Exactly
    }

    It 'does not retry <Name>' -ForEach @(
        @{ Name = 'a 401 without a claims challenge (an expired token)'; Status = 401; Content = '{"error":{"code":"InvalidAuthenticationToken","message":"Lifetime validation failed, the token is expired."}}'; Header = 'Bearer error="invalid_token"' }
        @{ Name = 'a 403, even with a claims parameter'; Status = 403; Content = '{"error":{"code":"Authorization_RequestDenied"}}'; Header = 'Bearer error="insufficient_claims", claims="e30="' }
        @{ Name = 'a success'; Status = 200; Content = '{"value":[]}'; Header = '' }
    ) {
        Set-RestMock -Response @((New-TestResponse -Status $Status -Content $Content -Authenticate $Header))

        $result = Invoke-TestRequest

        $result.Retried | Should -BeFalse
        $result.Challenge | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -Times 0 -ParameterFilter { $Refresh }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 1 -Exactly
        if ($Status -ge 400) {
            $result.ExitCode | Should -Be 1
            $result.StdErr | Should -Match ('^HTTP {0}: ' -f $Status)
        }
    }
}

Describe 'Get-DemoAccessToken -Refresh' {
    BeforeEach {
        Initialize-GuardTestContext
        InModuleScope DbHubDemo { $script:DemoTokenResourceInUse.Clear() }
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:tokenTenant = @{}
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $script:azCalls.Add($joined)
            $tenant = $script:GuardTestTenantId
            if ($joined -match '--resource (\S+)' -and $script:tokenTenant.ContainsKey($Matches[1])) {
                $tenant = $script:tokenTenant[$Matches[1]]
            }
            ConvertTo-GuardTestTokenResult (Get-GuardTestToken -TenantId $tenant)
        }
    }

    AfterEach {
        Initialize-GuardTestContext -Clear
        InModuleScope DbHubDemo { $script:DemoTokenResourceInUse.Clear() }
    }

    It 'asks for the other spelling of the Microsoft Graph audience and keeps it for the rest of the process' {
        $fresh = InModuleScope DbHubDemo -Parameters @{ Sub = $script:sub } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://graph.microsoft.com' -Refresh }
        $next = InModuleScope DbHubDemo -Parameters @{ Sub = $script:sub } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://graph.microsoft.com' }

        $fresh.Error | Should -BeNullOrEmpty
        $fresh.Token | Should -BeOfType [securestring]
        $next.Token | Should -BeOfType [securestring]
        $script:azCalls | Should -Be @(
            ('account get-access-token --resource https://graph.microsoft.com/ --output json --subscription {0}' -f $script:sub)
            ('account get-access-token --resource https://graph.microsoft.com/ --output json --subscription {0}' -f $script:sub))
    }

    It 'switches spelling again on a second refresh' {
        InModuleScope DbHubDemo -Parameters @{ Sub = $script:sub } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://graph.microsoft.com' -Refresh } | Out-Null
        InModuleScope DbHubDemo -Parameters @{ Sub = $script:sub } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://graph.microsoft.com' -Refresh } | Out-Null
        $script:azCalls[1] | Should -Match '--resource https://graph\.microsoft\.com --output'
    }

    It 'keeps the tenant check for the fresh token, and keeps the old spelling when it fails' {
        $script:tokenTenant['https://graph.microsoft.com/'] = $script:otherTenant
        $fresh = InModuleScope DbHubDemo -Parameters @{ Sub = $script:sub } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://graph.microsoft.com' -Refresh }
        InModuleScope DbHubDemo -Parameters @{ Sub = $script:sub } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://graph.microsoft.com' } | Out-Null

        $fresh.Token | Should -BeNullOrEmpty
        $fresh.Error | Should -Match ('issued for tenant {0}, not the configured tenant' -f $script:otherTenant)
        $script:azCalls[1] | Should -Match '--resource https://graph\.microsoft\.com --output'
    }

    It 'gets no token for Azure Resource Manager, which needs its trailing slash, and asks the Azure CLI nothing' {
        $fresh = InModuleScope DbHubDemo -Parameters @{ Sub = $script:sub } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://management.azure.com/' -Refresh }
        $fresh.Token | Should -BeNullOrEmpty
        $fresh.Error | Should -Match 'cannot skip a cached token'
        $script:azCalls.Count | Should -Be 0
    }

    It 'works inside the guard, before the context is validated, with the expected tenant and caller' {
        Initialize-GuardTestContext -Clear
        $fresh = InModuleScope DbHubDemo -Parameters @{ Sub = $script:sub; Tenant = $script:tenant; Caller = $script:caller } {
            $script:DemoAzGuardActive = $true
            try {
                Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://graph.microsoft.com' -ExpectedTenantId $Tenant -ExpectedObjectId $Caller -Refresh
            }
            finally {
                $script:DemoAzGuardActive = $false
            }
        }
        $fresh.Token | Should -BeOfType [securestring]
        $fresh.Claims.ObjectId | Should -Be $script:caller
    }
}
