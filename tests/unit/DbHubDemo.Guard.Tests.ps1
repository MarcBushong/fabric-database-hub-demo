BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    # Obviously fake IDs: every group repeats one digit or letter.
    $subscriptionId = '11111111-2222-3333-4444-555555555555'
    $tenantId = '66666666-7777-8888-9999-000000000000'
    $script:GuardSubscription = $subscriptionId
    $script:GuardTenant = $tenantId
    $script:OtherTenant = '88888888-8888-8888-8888-888888888888'
    $script:CallerObjectId = 'aaaaaaaa-1111-2222-3333-444444444444'
    $script:CallerAccount = 'operator@contoso.example'
    $script:AppClientId = 'cccccccc-1111-2222-3333-444444444444'

    function New-TestJwt {
        # A fake, unsigned token built at run time, so no token-shaped literal is in the repository.
        param([System.Collections.IDictionary] $Claims)
        $encode = {
            param([string] $Text)
            [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        }
        $header = & $encode '{"alg":"none","typ":"JWT"}'
        $payload = & $encode ($Claims | ConvertTo-Json -Compress)
        return ('{0}.{1}.{2}' -f $header, $payload, (& $encode 'not-a-signature'))
    }

    function New-AzOk([string] $StdOut) {
        [pscustomobject]@{ ExitCode = 0; StdOut = $StdOut; StdErr = '' }
    }

    function Reset-GuardState {
        # Every value the mocked Azure CLI answers with. Tests change single entries.
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:issuedTokens = [System.Collections.Generic.List[string]]::new()
        $script:guardState = @{
            Account        = [ordered]@{ id = $script:GuardSubscription; tenantId = $script:GuardTenant; user = [ordered]@{ name = $script:CallerAccount; type = 'user' } }
            AccountExit    = 0
            GroupIds       = @("/subscriptions/$($script:GuardSubscription)/resourceGroups/rg-dbhub-demo")
            GroupExit      = 0
            Subscription   = [ordered]@{ subscriptionId = $script:GuardSubscription; tenantId = $script:GuardTenant; state = 'Enabled' }
            BaseClaims     = [ordered]@{ tid = $script:GuardTenant; oid = $script:CallerObjectId; upn = $script:CallerAccount; unique_name = $script:CallerAccount; idtyp = 'user'; scp = 'user_impersonation'; appid = 'dddddddd-1111-2222-3333-444444444444'; exp = 4102444800 }
            ClaimOverrides = @{}
            OrganizationId = $script:GuardTenant
            OrganizationOk = $true
        }
    }

    function Set-GuardMock {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $script:azCalls.Add($joined)
            if ($joined -like 'account show*') {
                if ($script:guardState.AccountExit -ne 0) {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = "ERROR: Subscription not found. Please run 'az login' to setup account." }
                }
                return New-AzOk ($script:guardState.Account | ConvertTo-Json -Depth 5)
            }
            if ($joined -like 'group list*') {
                if ($script:guardState.GroupExit -ne 0) {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (AuthorizationFailed) The client does not have authorization.' }
                }
                return New-AzOk (ConvertTo-Json -InputObject @($script:guardState.GroupIds))
            }
            if ($joined -like 'rest --method get --url https://management.azure.com/subscriptions/*') {
                return New-AzOk ($script:guardState.Subscription | ConvertTo-Json)
            }
            if ($joined -match '^account get-access-token --resource (\S+)') {
                $resource = $Matches[1]
                $claims = [ordered]@{}
                foreach ($key in $script:guardState.BaseClaims.Keys) {
                    $claims[$key] = $script:guardState.BaseClaims[$key]
                }
                if ($script:guardState.ClaimOverrides.ContainsKey($resource)) {
                    foreach ($entry in $script:guardState.ClaimOverrides[$resource].GetEnumerator()) {
                        if ($null -eq $entry.Value) {
                            $claims.Remove($entry.Key)
                        }
                        else {
                            $claims[$entry.Key] = $entry.Value
                        }
                    }
                }
                $token = New-TestJwt -Claims $claims
                $script:issuedTokens.Add($token)
                return New-AzOk (@{ accessToken = $token; expiresOn = '2100-01-01 00:00:00.000000'; tenant = $claims['tid'] } | ConvertTo-Json)
            }
            throw "Unexpected az call: $joined"
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            if (-not $script:guardState.OrganizationOk) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 403: Authorization_RequestDenied'; StatusCode = 403 }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = (@{ value = @(@{ id = $script:guardState.OrganizationId }) } | ConvertTo-Json -Depth 4); StdErr = ''; StatusCode = 200 }
        }
    }

    function Get-GuardFailure {
        param([string] $Account = $script:CallerAccount)
        try {
            Assert-DemoAzContext -SubscriptionId $script:GuardSubscription -TenantId $script:GuardTenant -Account $Account -Force | Out-Null
        }
        catch {
            return $_.Exception.Message
        }
        return ''
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Assert-DemoAzContext (subscription guard)' {
    BeforeEach {
        InModuleScope DbHubDemo { Clear-DemoValidatedAzContext }
        Reset-GuardState
        Set-GuardMock
    }

    It 'passes when every authentication path reaches the configured subscription and tenant as azureAccount' {
        $result = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount

        $result.status | Should -Be 'Pass'
        $result.checkId | Should -Be 'PREFLIGHT.GUARD.CONTEXT'
        $result.evidence.account | Should -Be $script:CallerAccount
        $result.evidence.objectId | Should -Be $script:CallerObjectId
        $result.evidence.principalType | Should -Be 'User'
        foreach ($check in 'account', 'canary.arm', 'canary.armRest', 'canary.armToken', 'canary.fabricToken', 'canary.kustoToken', 'canary.graphToken', 'canary.graphOrganization') {
            $result.evidence.checks[$check] | Should -Be 'Pass' -Because $check
        }
    }

    It 'targets every call with --subscription and never uses --tenant, the default subscription, or a context change' {
        Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount | Out-Null

        $script:azCalls.Count | Should -Be 7
        foreach ($call in $script:azCalls) {
            $call | Should -Match "--subscription $subscriptionId" -Because $call
            $call | Should -Not -Match '--tenant'
            $call | Should -Not -Match '^(login|logout|account set|account clear)'
        }
        $script:azCalls[0] | Should -BeLike 'account show*'
        $script:azCalls[1] | Should -BeLike 'group list*'
        $script:azCalls[2] | Should -BeLike "rest --method get --url https://management.azure.com/subscriptions/$subscriptionId`?api-version=2022-12-01*"
        @($script:azCalls | Where-Object { $_ -like 'account get-access-token*' } | ForEach-Object { ($_ -split ' ')[3] }) |
            Should -Be @('https://management.azure.com/', 'https://api.fabric.microsoft.com', 'https://kusto.kusto.windows.net', 'https://graph.microsoft.com')
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://graph.microsoft.com/v1.0/organization?$select=id' -and $Method -eq 'GET' -and $null -ne $Token
        }
    }

    It 'gives every Azure CLI call a time limit' {
        Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 7 -Exactly -ParameterFilter { $TimeoutSeconds -gt 0 }
    }

    It 'never returns, logs, or puts a token in its result' {
        $result = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount
        $json = $result | ConvertTo-Json -Depth 10
        $script:issuedTokens.Count | Should -Be 4
        foreach ($token in $script:issuedTokens) {
            $json | Should -Not -Match ([regex]::Escape($token))
            InModuleScope DbHubDemo -Parameters @{ Token = $token } { Protect-DemoText -Text "header $Token" } | Should -Not -Match ([regex]::Escape($token))
        }
    }

    It 'reports the signed-in account as a Warning when azureAccount is not set' {
        $result = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account ''

        $result.status | Should -Be 'Warning'
        $result.evidence.account | Should -Be $script:CallerAccount
        $result.evidence.azureAccountConfigured | Should -BeFalse
        $result.evidence.checks['account'] | Should -Be 'Warning'
        $result.remediation | Should -Match ([regex]::Escape("Set azureAccount to '$($script:CallerAccount)'"))
    }

    It 'fails closed on another account than azureAccount, before any canary' {
        $message = Get-GuardFailure -Account 'someone-else@contoso.example'

        $message | Should -Match "check 'account' failed"
        $message | Should -Match 'someone-else@contoso.example'
        $message | Should -Match 'Nothing was changed'
        $script:azCalls.Count | Should -Be 1
    }

    It 'fails closed when the Azure CLI has no account for the subscription, and points to az login --tenant, never az account set' {
        $script:guardState.AccountExit = 1
        $message = Get-GuardFailure

        $message | Should -Match "check 'account' failed"
        $message | Should -Match ([regex]::Escape("az login --tenant $tenantId"))
        $message | Should -Match "don't need to change your default subscription"
        $message | Should -Match 'AZURE_CONFIG_DIR'
        $message | Should -Not -Match 'account set'
    }

    It 'fails closed when the profile has the subscription in another tenant' {
        $script:guardState.Account.tenantId = $script:OtherTenant
        Get-GuardFailure | Should -Match "check 'account' failed.*not the configured tenant"
    }

    It 'fails closed when the Resource Manager canary fails' {
        $script:guardState.GroupExit = 1
        $message = Get-GuardFailure
        $message | Should -Match "check 'canary.arm' failed"
        $message | Should -Match 'AuthorizationFailed'
    }

    It 'fails closed when the Resource Manager canary returns another subscription''s groups' {
        $script:guardState.GroupIds = @('/subscriptions/99999999-9999-9999-9999-999999999999/resourceGroups/other')
        Get-GuardFailure | Should -Match "check 'canary.arm' failed"
    }

    It 'fails closed when az rest answers for another tenant' {
        $script:guardState.Subscription.tenantId = $script:OtherTenant
        Get-GuardFailure | Should -Match "check 'canary.armRest' failed"
    }

    It 'fails closed when a token is issued for another tenant: <Check>' -ForEach @(
        @{ Check = 'canary.armToken'; Resource = 'https://management.azure.com/' }
        @{ Check = 'canary.fabricToken'; Resource = 'https://api.fabric.microsoft.com' }
        @{ Check = 'canary.kustoToken'; Resource = 'https://kusto.kusto.windows.net' }
        @{ Check = 'canary.graphToken'; Resource = 'https://graph.microsoft.com' }
    ) {
        $script:guardState.ClaimOverrides[$Resource] = @{ tid = $script:OtherTenant }
        $message = Get-GuardFailure
        $message | Should -Match ("check '{0}' failed" -f [regex]::Escape($Check))
        $message | Should -Match 'not the configured tenant'
        foreach ($token in $script:issuedTokens) {
            $message | Should -Not -Match ([regex]::Escape($token))
        }
    }

    It 'fails closed when a token belongs to another identity: <Check>' -ForEach @(
        @{ Check = 'canary.fabricToken'; Resource = 'https://api.fabric.microsoft.com' }
        @{ Check = 'canary.kustoToken'; Resource = 'https://kusto.kusto.windows.net' }
        @{ Check = 'canary.graphToken'; Resource = 'https://graph.microsoft.com' }
    ) {
        $script:guardState.ClaimOverrides[$Resource] = @{ oid = 'bbbbbbbb-1111-2222-3333-444444444444' }
        Get-GuardFailure | Should -Match ("check '{0}' failed.*not the validated caller" -f [regex]::Escape($Check))
    }

    It 'fails closed when the Resource Manager token was issued to another user than the Azure CLI account' {
        $script:guardState.ClaimOverrides['https://management.azure.com/'] = @{ upn = 'default-user@fabrikam.example'; unique_name = 'default-user@fabrikam.example' }
        Get-GuardFailure | Should -Match "check 'canary.armToken' failed.*default-user@fabrikam.example"
    }

    It 'fails closed when Microsoft Graph answers for another tenant' {
        $script:guardState.OrganizationId = $script:OtherTenant
        Get-GuardFailure | Should -Match "check 'canary.graphOrganization' failed"
    }

    It 'warns, but passes the other checks, when Microsoft Graph refuses the organization read' {
        $script:guardState.OrganizationOk = $false
        $result = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount
        $result.status | Should -Be 'Warning'
        $result.evidence.checks['canary.graphOrganization'] | Should -Be 'Warning'
        $result.message | Should -Match 'HTTP 403'
        $result.evidence.Contains('graphChallenge') | Should -BeFalse
    }

    It 'passes, with a note, when Microsoft Graph answered after a claims challenge and one fresh token' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = (@{ value = @(@{ id = $script:GuardTenant }) } | ConvertTo-Json -Depth 4); StdErr = ''; StatusCode = 200; Retried = $true; Challenge = 'Claims challenge (Continuous Access Evaluation) on the cached token; the request succeeded with one fresh token.'; Authenticate = 'Bearer error="insufficient_claims", claims="<redacted>"' }
        }
        $result = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount

        $result.status | Should -Be 'Pass'
        $result.evidence.checks['canary.graphOrganization'] | Should -Be 'Pass'
        $result.message | Should -Match 'succeeded with one fresh token'
        $result.evidence.graphChallenge.retried | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 1 -Exactly -ParameterFilter { $ExpectedTenantId -eq $script:GuardTenant -and $ExpectedObjectId -eq $script:CallerObjectId -and $null -ne $Token }
    }

    It 'warns with the request, the status, and the redacted header when Microsoft Graph still refuses after the fresh token' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 401 on GET ...'; StatusCode = 401; Retried = $true; Challenge = 'Claims challenge (Continuous Access Evaluation) on the cached token, and the request failed again with one fresh token.'; Authenticate = 'Bearer error="insufficient_claims", claims="<redacted>"' }
        }
        $result = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount

        $result.status | Should -Be 'Warning'
        $result.evidence.checks['canary.graphOrganization'] | Should -Be 'Warning'
        $result.message | Should -Match 'HTTP 401.*failed again with one fresh token'
        $result.evidence.graphChallenge.request | Should -Be 'GET https://graph.microsoft.com/v1.0/organization?$select=id'
        $result.evidence.graphChallenge.status | Should -Be 401
        $result.evidence.graphChallenge.wwwAuthenticate | Should -Match 'claims="<redacted>"'
    }

    It 'accepts a service principal (GitHub Actions OpenID Connect) by client ID, without a Graph organization read' {
        $script:guardState.Account.user = [ordered]@{ name = $script:AppClientId; type = 'servicePrincipal' }
        $script:guardState.BaseClaims = [ordered]@{ tid = $tenantId; oid = $script:CallerObjectId; appid = $script:AppClientId; idtyp = 'app'; exp = 4102444800 }

        $result = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:AppClientId

        $result.status | Should -Be 'Pass'
        $result.evidence.accountKind | Should -Be 'ServicePrincipal'
        $result.evidence.principalType | Should -Be 'ServicePrincipal'
        $result.evidence.checks['canary.graphOrganization'] | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 0
    }

    It 'fails closed when the service principal token has another client ID than the Azure CLI account' {
        $script:guardState.Account.user = [ordered]@{ name = $script:AppClientId; type = 'servicePrincipal' }
        $script:guardState.BaseClaims = [ordered]@{ tid = $tenantId; oid = $script:CallerObjectId; appid = 'eeeeeeee-1111-2222-3333-444444444444'; idtyp = 'app'; exp = 4102444800 }
        Get-GuardFailure -Account $script:AppClientId | Should -Match "check 'canary.armToken' failed"
    }

    It 'handles a <Kind> account with --subscription, never --tenant, and checks the token''s tid claim' -ForEach @(
        @{ Kind = 'system-assigned managed identity'; User = [ordered]@{ name = 'systemAssignedIdentity'; type = 'servicePrincipal'; assignedIdentityInfo = 'MSI' }; Expected = 'ManagedIdentity' }
        @{ Kind = 'user-assigned managed identity'; User = [ordered]@{ name = 'userAssignedIdentity'; type = 'servicePrincipal'; assignedIdentityInfo = 'MSIClient-cccccccc-1111-2222-3333-444444444444' }; Expected = 'ManagedIdentity' }
        @{ Kind = 'Cloud Shell'; User = [ordered]@{ name = 'operator@contoso.example'; type = 'user'; cloudShellID = $true }; Expected = 'CloudShell' }
    ) {
        $script:guardState.Account.user = $User
        if ($Expected -eq 'ManagedIdentity') {
            $script:guardState.BaseClaims = [ordered]@{ tid = $tenantId; oid = $script:CallerObjectId; appid = $script:AppClientId; idtyp = 'app'; exp = 4102444800 }
        }
        $account = if ($Expected -eq 'ManagedIdentity') { $script:AppClientId } else { $script:CallerAccount }

        $result = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $account

        $result.status | Should -Be 'Pass'
        $result.evidence.accountKind | Should -Be $Expected
        $result.evidence.account | Should -Be $account
        @($script:azCalls | Where-Object { $_ -like 'account get-access-token*' }).Count | Should -Be 4
        @($script:azCalls | Where-Object { $_ -like 'account get-access-token*' -and $_ -notmatch "--subscription $subscriptionId" }) | Should -BeNullOrEmpty
        @($script:azCalls | Where-Object { $_ -match '--tenant' }) | Should -BeNullOrEmpty

        # The same account with a token for another tenant fails closed.
        Reset-GuardState
        $script:guardState.Account.user = $User
        $script:guardState.BaseClaims = [ordered]@{ tid = $script:OtherTenant; oid = $script:CallerObjectId; appid = $script:AppClientId; idtyp = 'app'; exp = 4102444800 }
        Get-GuardFailure -Account $account | Should -Match "check 'canary.armToken' failed.*not the configured tenant"
    }

    It 'validates once per process and answers later calls from the cache' {
        Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount | Out-Null
        $script:azCalls.Clear()

        $again = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount

        $again.status | Should -Be 'Pass'
        $again.evidence.cached | Should -BeTrue
        $again.message | Should -Match 'Validated earlier in this process'
        $script:azCalls.Count | Should -Be 0
    }

    It 'validates again with -Force or with another azureAccount' {
        Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account '' | Out-Null
        $script:azCalls.Clear()
        Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount | Out-Null
        $script:azCalls.Count | Should -Be 7
        $script:azCalls.Clear()
        Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount -Force | Out-Null
        $script:azCalls.Count | Should -Be 7
    }

    It 'forgets the validated context when a later validation fails, so writes are refused again' {
        Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount | Out-Null
        $script:guardState.GroupExit = 1
        Get-GuardFailure | Should -Match 'canary.arm'

        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'group', 'create', '--name', 'rg-x', '--location', 'westus3' } | Should -Throw '*Assert-DemoAzContext*'
    }

    It 'never sends a request that changes anything' {
        Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:CallerAccount | Out-Null
        foreach ($call in $script:azCalls) {
            $call | Should -Match '^(account show|group list|rest --method get|account get-access-token) ' -Because $call
        }
    }
}

Describe 'Assert-DemoAzContext in GitHub Actions: its message comes out masked (ADR 0022)' {
    BeforeAll {
        $script:savedActions = $env:GITHUB_ACTIONS
        $script:savedSummary = $env:GITHUB_STEP_SUMMARY
    }

    BeforeEach {
        InModuleScope DbHubDemo { Clear-DemoValidatedAzContext; $script:DemoLogMasks.Clear() }
        Reset-GuardState
        Set-GuardMock
        # The service principal that azure/login signs in as with OpenID Connect.
        $script:guardState.Account.user = [ordered]@{ name = $script:AppClientId; type = 'servicePrincipal' }
        $script:guardState.BaseClaims = [ordered]@{ tid = $tenantId; oid = $script:CallerObjectId; appid = $script:AppClientId; idtyp = 'app'; exp = 4102444800 }
        # The real log line, as the job log would show it, in the same stream as the add-mask commands.
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $true } -MockWith {
            # Host output, as Write-DemoLog's, so it shares one stream with the add-mask commands.
            Write-Information -MessageData ('LOG ' + (& (Get-Module -Name DbHubDemo) { param($Text) Protect-DemoLogText -Text $Text } $Message)) -InformationAction Continue
        }
        $env:GITHUB_ACTIONS = 'true'
        $script:summary = Join-Path -Path $TestDrive -ChildPath 'summary.md'
        $env:GITHUB_STEP_SUMMARY = $script:summary
    }

    AfterEach {
        $env:GITHUB_ACTIONS = $script:savedActions
        $env:GITHUB_STEP_SUMMARY = $script:savedSummary
        InModuleScope DbHubDemo { $script:DemoLogMasks.Clear() }
    }

    It 'masks the subscription, the tenant, and the account before its first log line, then the caller''s object ID' {
        $result = $null
        $lines = @(& { $script:guardResult = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:AppClientId } 6>&1 | ForEach-Object { [string]$_ })
        $result = $script:guardResult
        $firstLog = [array]::FindIndex([string[]]$lines, [System.Predicate[string]] { param($line) $line.StartsWith('LOG ') })
        $firstLog | Should -BeGreaterThan 0
        foreach ($value in $subscriptionId, $tenantId, $script:AppClientId) {
            $index = [array]::IndexOf([string[]]$lines, "::add-mask::$value")
            $index | Should -BeGreaterOrEqual 0 -Because "$value is masked"
            $index | Should -BeLessThan $firstLog -Because "$value is masked before the first log line"
        }
        $lines | Should -Contain "::add-mask::$($script:CallerObjectId)"
        $lines | Should -Contain "::add-mask::$($subscriptionId.ToUpperInvariant())"
        foreach ($line in $lines | Where-Object { $_.StartsWith('LOG ') }) {
            $line | Should -Not -Match ([regex]::Escape($subscriptionId))
        }
        # In memory the message names them, so nothing that reads the result changes.
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match ([regex]::Escape($subscriptionId))
    }

    It 'shows *** instead of the subscription, the tenant, the account, and the object ID in the job summary and the results' {
        $result = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:AppClientId 6>$null
        $path = Join-Path -Path $TestDrive -ChildPath 'out/preflight.jsonl'
        $report = @(Write-DemoResultReport -Result @($result) -Title 'preflight.ps1' 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        Export-DemoResult -Result @($result) -Path $path
        $written = @{ table = $report; results = (Get-Content -LiteralPath $path -Raw); summary = (Get-Content -LiteralPath $script:summary -Raw) }
        $written['table'] | Should -Match '\*\*\*'
        foreach ($name in 'results', 'summary') {
            $written[$name] | Should -Match 'reaches subscription \*\*\* in tenant \*\*\*|reaches subscription \\\*\\\*\\\* in tenant \\\*\\\*\\\*' -Because $name
        }
        foreach ($name in $written.Keys) {
            foreach ($value in $subscriptionId, $tenantId, $script:AppClientId, $script:CallerObjectId) {
                $written[$name] | Should -Not -Match ([regex]::Escape($value)) -Because "$name hides $value"
            }
        }
    }

    It 'masks another tenant''s ID that a failed check names' {
        $script:guardState.Subscription.tenantId = $script:OtherTenant
        $lines = @(& { try { Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:AppClientId -Force } catch { $script:guardError = $_.Exception.Message } } 6>&1 | ForEach-Object { [string]$_ })
        $script:guardError | Should -Match "check 'canary.armRest' failed"
        $lines | Should -Contain "::add-mask::$($script:OtherTenant)"
        $failure = New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $script:guardError
        $path = Join-Path -Path $TestDrive -ChildPath 'out/failed.jsonl'
        Export-DemoResult -Result @($failure) -Path $path
        (Get-Content -LiteralPath $path -Raw) | Should -Not -Match ([regex]::Escape($script:OtherTenant))
    }

    It 'masks nothing outside GitHub Actions' {
        $env:GITHUB_ACTIONS = ''
        $lines = @(& { $null = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Account $script:AppClientId } 6>&1 | ForEach-Object { [string]$_ })
        @($lines | Where-Object { $_ -like '::add-mask::*' }).Count | Should -Be 0
        ($lines | Where-Object { $_.StartsWith('LOG ') } | Select-Object -First 1) | Should -Match ([regex]::Escape($subscriptionId))
    }
}

Describe 'Invoke-DemoAz' {
    BeforeEach {
        InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId; Tenant = $tenantId } { $null = Set-DemoValidatedAzContext -SubscriptionId $Sub -TenantId $Tenant -ObjectId 'aaaaaaaa-1111-2222-3333-444444444444' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"name":"rg-dbhub-demo"}'; StdErr = '' }
        }
    }

    AfterEach {
        InModuleScope DbHubDemo { Clear-DemoValidatedAzContext }
    }

    It 'appends the configured subscription to every subscription-scoped command' {
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'group', 'show', '--name', 'rg-dbhub-demo' | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'group show --name rg-dbhub-demo --subscription 11111111-2222-3333-4444-555555555555'
        }
    }

    It 'keeps an explicit --subscription that matches the configuration' {
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'vm', 'list', '--subscription', $subscriptionId | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter {
            @($ArgumentList | Where-Object { $_ -eq '--subscription' }).Count -eq 1
        }
    }

    It 'does not add --subscription to local commands: <_>' -ForEach @('bicep', 'version') {
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $_, 'version' | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--subscription' }
    }

    It 'refuses to sign in, sign out, or change the CLI context: <_>' -ForEach @('login', 'logout', 'account set', 'account clear', 'config set', 'config unset', 'cloud set') {
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList ($_ -split ' ') } | Should -Throw '*never sign in*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'refuses another subscription' {
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'vm', 'list', '--subscription', '99999999-9999-9999-9999-999999999999' } | Should -Throw '*Only the configured subscription*'
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'vm', 'list', '--subscription=99999999-9999-9999-9999-999999999999' } | Should -Throw '*Only the configured subscription*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'refuses another subscription anywhere in the arguments, for example a scope' {
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'role', 'definition', 'list', '--name', 'Reader', '--scope', '/subscriptions/99999999-9999-9999-9999-999999999999' } | Should -Throw '*Only the configured subscription*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'refuses --ids in any form' -ForEach @(
        @{ Arguments = @('resource', 'show', '--ids', '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm') }
        @{ Arguments = @('vm', 'show', '--ids=/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm') }
    ) {
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $Arguments } | Should -Throw '*--ids*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'refuses the {subscriptionId} placeholder' {
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'rest', '--method', 'get', '--url', 'https://management.azure.com/subscriptions/{subscriptionId}/resourcegroups?api-version=2021-04-01' } | Should -Throw '*{subscriptionId}*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'refuses az ad, which calls Microsoft Graph with the default account: <_>' -ForEach @('ad group show --group 77777777-7777-7777-7777-777777777777', 'ad signed-in-user show', 'ad group member add --group 77777777-7777-7777-7777-777777777777 --member-id 88888888-8888-8888-8888-888888888888') {
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList ($_ -split ' ') } | Should -Throw '*Microsoft Graph*default account*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'refuses az rest calls to another subscription' {
        $url = 'https://management.azure.com/subscriptions/99999999-9999-9999-9999-999999999999/resourcegroups?api-version=2021-04-01'
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'rest', '--method', 'get', '--url', $url } | Should -Throw '*Only the configured subscription*'
    }

    It 'refuses az rest outside the configured subscription''s Resource Manager URLs: <_>' -ForEach @(
        'https://graph.microsoft.com/v1.0/organization'
        'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01'
        'https://management.azure.com/providers/Microsoft.Authorization/policyDefinitions/abc?api-version=2023-04-01'
        '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups?api-version=2021-04-01'
        'http://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555?api-version=2022-12-01'
        'https://management.azure.com/subscriptions/11111111-2222-3333-4444-5555555555556?api-version=2022-12-01'
    ) {
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'rest', '--method', 'get', '--url', $_ } | Should -Throw "*refuses 'az rest'*"
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'allows az rest on the configured subscription''s fully qualified URL, with --subscription added' {
        $url = "https://management.azure.com/subscriptions/$subscriptionId/resourcegroups?api-version=2021-04-01"
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'rest', '--method', 'get', '--url', $url | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq "rest --method get --url $url --subscription 11111111-2222-3333-4444-555555555555"
        }
    }

    It 'requests tokens with --subscription and a time limit, never --tenant' {
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'account', 'get-access-token', '--resource', 'https://api.fabric.microsoft.com', '--output', 'json' | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'account get-access-token --resource https://api.fabric.microsoft.com --output json --subscription 11111111-2222-3333-4444-555555555555' -and $TimeoutSeconds -eq 120
        }
    }

    It 'refuses a token request with --tenant: <_>' -ForEach @('--tenant', '-t', '--tenant=66666666-7777-8888-9999-000000000000') {
        $arguments = @('account', 'get-access-token', '--resource', 'https://api.fabric.microsoft.com')
        $arguments += if ($_ -like '*=*') { @($_) } else { @($_, '66666666-7777-8888-9999-000000000000') }
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $arguments } | Should -Throw '*--tenant*default account*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'refuses the subscription aliases on az account: <_>' -ForEach @('-s', '-n', '--name') {
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'account', 'show', $_, $subscriptionId } | Should -Throw '*only with --subscription*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'refuses role assignments that would resolve principals through Microsoft Graph: <Name>' -ForEach @(
        @{ Name = 'create with --assignee'; Arguments = @('role', 'assignment', 'create', '--assignee', 'someone@contoso.example', '--role', 'Reader', '--scope', '/subscriptions/11111111-2222-3333-4444-555555555555') }
        @{ Name = 'create without --assignee-principal-type'; Arguments = @('role', 'assignment', 'create', '--assignee-object-id', '88888888-8888-8888-8888-888888888888', '--role', 'Reader', '--scope', '/subscriptions/11111111-2222-3333-4444-555555555555') }
        @{ Name = 'list with --assignee'; Arguments = @('role', 'assignment', 'list', '--assignee', 'someone@contoso.example', '--fill-principal-name', 'false') }
        @{ Name = 'list without --fill-principal-name false'; Arguments = @('role', 'assignment', 'list', '--assignee-object-id', '88888888-8888-8888-8888-888888888888') }
    ) {
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $Arguments } | Should -Throw '*Microsoft Graph*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'allows a role assignment by object ID with its principal type' {
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'role', 'assignment', 'create', '--assignee-object-id', '88888888-8888-8888-8888-888888888888', '--assignee-principal-type', 'User', '--role', 'Reader', '--scope', "/subscriptions/$subscriptionId" | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly
    }

    It 'refuses writes and token requests until the guard has validated the context, and allows reads' {
        InModuleScope DbHubDemo { Clear-DemoValidatedAzContext }
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'group', 'create', '--name', 'rg-x', '--location', 'westus3' } | Should -Throw '*Assert-DemoAzContext*'
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'account', 'get-access-token', '--resource', 'https://api.fabric.microsoft.com' } | Should -Throw '*Assert-DemoAzContext*'
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'rest', '--method', 'put', '--url', "https://management.azure.com/subscriptions/$subscriptionId/resourcegroups/rg-x?api-version=2021-04-01" } | Should -Throw '*Assert-DemoAzContext*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0

        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'group', 'show', '--name', 'rg-dbhub-demo' | Out-Null
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'rest', '--method', 'get', '--url', "https://management.azure.com/subscriptions/${subscriptionId}?api-version=2022-12-01" | Out-Null
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'account', 'show' | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 3 -Exactly
    }

    It 'refuses writes for a subscription other than the validated one' {
        InModuleScope DbHubDemo { $null = Set-DemoValidatedAzContext -SubscriptionId '22222222-2222-2222-2222-222222222222' -TenantId '66666666-7777-8888-9999-000000000000' }
        { Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'group', 'create', '--name', 'rg-x', '--location', 'westus3' } | Should -Throw '*Assert-DemoAzContext*'
    }

    It 'passes -TimeoutSeconds to the Azure CLI runner' {
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'group', 'show', '--name', 'rg-dbhub-demo' -TimeoutSeconds 30 | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 30 }
    }

    It 'parses JSON output with -AsJson' {
        $result = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'group', 'show', '--name', 'rg-dbhub-demo' -AsJson
        $result.name | Should -Be 'rg-dbhub-demo'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '--output json' }
    }

    It 'redacts secrets from errors' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Download failed: https://st1.blob.core.windows.net/a/b?sp=r&sig=abcdefghijklmnop' }
        }
        $message = ''
        try {
            Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList 'storage', 'blob', 'show'
        }
        catch {
            $message = $_.Exception.Message
        }
        $message | Should -Match 'sig=\[REDACTED\]'
        $message | Should -Not -Match 'abcdefghijklmnop'
    }
}

Describe 'Get-DemoAccessToken' {
    BeforeEach {
        Reset-GuardState
        Set-GuardMock
        InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId; Tenant = $tenantId; ObjectId = $script:CallerObjectId } { $null = Set-DemoValidatedAzContext -SubscriptionId $Sub -TenantId $Tenant -ObjectId $ObjectId }
    }

    AfterEach {
        InModuleScope DbHubDemo { Clear-DemoValidatedAzContext }
    }

    It 'returns the verified token as a SecureString, registered for redaction, with its claims' {
        $issued = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://api.fabric.microsoft.com' }

        $issued.Error | Should -BeNullOrEmpty
        $issued.Token | Should -BeOfType [securestring]
        $issued.Claims.TenantId | Should -Be $tenantId
        $issued.Claims.ObjectId | Should -Be $script:CallerObjectId
        $issued.Claims.PrincipalType | Should -Be 'User'
        $token = $script:issuedTokens[0]
        [System.Net.NetworkCredential]::new('', $issued.Token).Password | Should -BeExactly $token
        InModuleScope DbHubDemo -Parameters @{ Token = $token } { Protect-DemoText -Text "value $Token" } | Should -Not -Match ([regex]::Escape($token))
        ($issued.Claims | ConvertTo-Json) | Should -Not -Match ([regex]::Escape($token))
        $script:azCalls | Should -Be @("account get-access-token --resource https://api.fabric.microsoft.com --output json --subscription $subscriptionId")
    }

    It 'accepts the Power BI REST audience, the only resource with a path, and keeps every check (Phase 19)' {
        $resource = 'https://analysis.windows.net/powerbi/api'
        $issued = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId; Resource = $resource } { Get-DemoAccessToken -SubscriptionId $Sub -Resource $Resource }

        $issued.Error | Should -BeNullOrEmpty
        $issued.Token | Should -BeOfType [securestring]
        $issued.Claims.TenantId | Should -Be $tenantId
        $issued.Claims.ObjectId | Should -Be $script:CallerObjectId
        $script:azCalls | Should -Be @("account get-access-token --resource $resource --output json --subscription $subscriptionId")

        $script:guardState.ClaimOverrides[$resource] = @{ tid = $script:OtherTenant }
        $other = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId; Resource = $resource } { Get-DemoAccessToken -SubscriptionId $Sub -Resource $Resource }
        $other.Token | Should -BeNullOrEmpty
        $other.Error | Should -Match 'not the configured tenant'

        $script:guardState.ClaimOverrides[$resource] = @{ oid = $null }
        $noCaller = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId; Resource = $resource } { Get-DemoAccessToken -SubscriptionId $Sub -Resource $Resource }
        $noCaller.Token | Should -BeNullOrEmpty
        $noCaller.Error | Should -Match 'no object ID'
    }

    It 'refuses any other resource with a path, a query, or plain HTTP: <_>' -ForEach @(
        'https://analysis.windows.net/powerbi/api/v2',
        'https://analysis.windows.net/other',
        'https://api.fabric.microsoft.com/v1',
        'https://analysis.windows.net/powerbi/api?x=1',
        'http://analysis.windows.net/powerbi/api'
    ) {
        $resource = $_
        { InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId; Resource = $resource } { Get-DemoAccessToken -SubscriptionId $Sub -Resource $Resource } } | Should -Throw '*Resource*'
        $script:azCalls.Count | Should -Be 0
    }

    It 'returns no token when it was issued for another tenant' {
        $script:guardState.ClaimOverrides['https://kusto.kusto.windows.net'] = @{ tid = $script:OtherTenant }
        $issued = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://kusto.kusto.windows.net' }
        $issued.Token | Should -BeNullOrEmpty
        $issued.Error | Should -Match ("issued for tenant {0}, not the configured tenant {1}" -f $script:OtherTenant, $tenantId)
    }

    It 'returns no token when it belongs to another caller than the validated one' {
        $script:guardState.ClaimOverrides['https://graph.microsoft.com'] = @{ oid = 'bbbbbbbb-1111-2222-3333-444444444444' }
        $issued = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://graph.microsoft.com' }
        $issued.Token | Should -BeNullOrEmpty
        $issued.Error | Should -Match 'not the validated caller'
    }

    It 'returns no token when its oid claim is missing' {
        $script:guardState.ClaimOverrides['https://graph.microsoft.com'] = @{ oid = $null }
        $issued = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://graph.microsoft.com' }
        $issued.Token | Should -BeNullOrEmpty
        $issued.Error | Should -Match 'no object ID'
    }

    It 'asks for nothing without a validated context' {
        InModuleScope DbHubDemo { Clear-DemoValidatedAzContext }
        $issued = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://graph.microsoft.com' }
        $issued.Token | Should -BeNullOrEmpty
        $issued.Error | Should -Match 'Assert-DemoAzContext'
        $script:azCalls.Count | Should -Be 0
    }

    It 'reports a failed request without the token' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'AADSTS50076: Due to a configuration change, you must use multi-factor authentication.' }
        }
        $issued = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId } { Get-DemoAccessToken -SubscriptionId $Sub -Resource 'https://api.fabric.microsoft.com' }
        $issued.Token | Should -BeNullOrEmpty
        $issued.Error | Should -Match 'AADSTS50076'
    }
}

Describe 'Invoke-DemoRestRequest' {
    BeforeAll {
        $script:secure = [System.Security.SecureString]::new()
        foreach ($character in ('fake-' + [guid]::NewGuid().ToString('N')).ToCharArray()) {
            $script:secure.AppendChar($character)
        }
        $script:secure.MakeReadOnly()
    }

    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -MockWith { [pscustomobject]@{ Token = $script:secure; Claims = $null; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"id":"x"}]}' } }
    }

    It 'calls <TargetUri> with a token for <TargetResource>, in the Authorization header only' -ForEach @(
        @{ TargetUri = 'https://graph.microsoft.com/v1.0/organization?$select=id'; TargetResource = 'https://graph.microsoft.com' }
        @{ TargetUri = 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01'; TargetResource = 'https://management.azure.com/' }
    ) {
        $script:targetUri = $TargetUri
        $script:targetResource = $TargetResource
        $result = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId; Target = $TargetUri } { Invoke-DemoRestRequest -SubscriptionId $Sub -Method 'GET' -Uri $Target }

        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Match '"id":"x"'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -Times 1 -Exactly -ParameterFilter { $Resource -eq $script:targetResource }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq $script:targetUri -and $Authentication -eq 'Bearer' -and $Token -eq $script:secure -and -not $Headers }
    }

    It 'reuses a token the caller passes' {
        InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId; Token = $script:secure } { Invoke-DemoRestRequest -SubscriptionId $Sub -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/organization' -Token $Token } | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -Times 0
    }

    It 'returns a redacted error for an HTTP failure' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"Authorization_RequestDenied"}}' } }
        $result = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId } { Invoke-DemoRestRequest -SubscriptionId $Sub -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/groups/77777777-7777-7777-7777-777777777777' }
        $result.ExitCode | Should -Be 1
        $result.StatusCode | Should -Be 403
        $result.StdErr | Should -Match 'HTTP 403.*Authorization_RequestDenied'
    }

    It 'sends nothing when no verified token is available' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -MockWith { [pscustomobject]@{ Token = $null; Claims = $null; Error = 'The token was issued for tenant x.' } }
        $result = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId } { Invoke-DemoRestRequest -SubscriptionId $Sub -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/organization' }
        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match 'tenant x'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 0
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'another host'; Uri = 'https://example.com/v1.0/organization' }
        @{ Name = 'Graph beta'; Uri = 'https://graph.microsoft.com/beta/organization' }
        @{ Name = 'plain HTTP'; Uri = 'http://management.azure.com/providers/x' }
        @{ Name = 'another subscription'; Uri = 'https://management.azure.com/subscriptions/99999999-9999-9999-9999-999999999999/resourcegroups?api-version=2021-04-01' }
        @{ Name = 'the {subscriptionId} placeholder'; Uri = 'https://management.azure.com/subscriptions/{subscriptionId}/resourcegroups?api-version=2021-04-01' }
    ) {
        { InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId; Uri = $Uri } { Invoke-DemoRestRequest -SubscriptionId $Sub -Method 'GET' -Uri $Uri } } | Should -Throw
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -Times 0
    }
}

Describe 'Resolve-DemoPrincipalType' {
    It 'maps Microsoft Graph object types to role assignment principal types' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            $value = @(
                @{ '@odata.type' = '#microsoft.graph.user'; id = '11111111-aaaa-bbbb-cccc-111111111111' }
                @{ '@odata.type' = '#microsoft.graph.servicePrincipal'; id = '22222222-aaaa-bbbb-cccc-222222222222' }
                @{ '@odata.type' = '#microsoft.graph.group'; id = '33333333-aaaa-bbbb-cccc-333333333333' }
            )
            [pscustomobject]@{ ExitCode = 0; StdOut = (@{ value = $value } | ConvertTo-Json -Depth 4); StdErr = ''; StatusCode = 200 }
        }
        $types = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId } { Resolve-DemoPrincipalType -SubscriptionId $Sub -ObjectId @('11111111-AAAA-bbbb-cccc-111111111111', '22222222-aaaa-bbbb-cccc-222222222222', '33333333-aaaa-bbbb-cccc-333333333333', '44444444-aaaa-bbbb-cccc-444444444444') }

        $types['11111111-aaaa-bbbb-cccc-111111111111'] | Should -Be 'User'
        $types['22222222-aaaa-bbbb-cccc-222222222222'] | Should -Be 'ServicePrincipal'
        $types['33333333-aaaa-bbbb-cccc-333333333333'] | Should -Be 'Group'
        $types.ContainsKey('44444444-aaaa-bbbb-cccc-444444444444') | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -eq 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' }
    }

    It 'returns nothing when Microsoft Graph refuses the read' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 403'; StatusCode = 403 } }
        $types = InModuleScope DbHubDemo -Parameters @{ Sub = $subscriptionId } { Resolve-DemoPrincipalType -SubscriptionId $Sub -ObjectId @('11111111-aaaa-bbbb-cccc-111111111111') }
        $types.Count | Should -Be 0
    }
}

Describe 'Guard hygiene in the repository' {
    BeforeAll {
        $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
        $scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts') -Recurse -File -Include '*.ps1', '*.psm1')
    }

    It 'only the guard records a validated context (Set-DemoValidatedAzContext is the unit-test hook)' {
        $callers = @($scriptFiles | Select-String -Pattern '\bSet-DemoValidatedAzContext\b' |
                Where-Object { $_.Filename -notin 'AzContext.ps1', 'Assert-DemoAzContext.ps1' -and $_.Line.TrimStart() -notmatch '^#' } |
                ForEach-Object { '{0}:{1}' -f $_.Filename, $_.LineNumber })
        $callers | Should -BeNullOrEmpty
    }

    It 'no script or module function passes ''account set'', ''login'', --ids, or --tenant to the Azure CLI' {
        $pattern = "'account',\s*'(set|clear)'|ArgumentList\s+@?\(?\s*'(login|logout)'|'--ids'\s*,|'get-access-token'[^\r\n]*'--tenant'"
        $hits = @($scriptFiles | Where-Object { $_.Name -ne 'Invoke-DemoAz.ps1' } | Select-String -Pattern $pattern |
                ForEach-Object { '{0}:{1}' -f $_.Filename, $_.LineNumber })
        $hits | Should -BeNullOrEmpty
    }

    It 'no PowerShell file runs the Azure CLI except Invoke-DemoAzCli' {
        # Every az call goes through Invoke-DemoAz, so it's targeted and checked; only the runner starts az.
        $hits = foreach ($file in $scriptFiles) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = $command.GetCommandName()
                $first = $command.CommandElements[0].Extent.Text
                $runsAz = $name -in 'az', 'az.cmd' -or ($command.InvocationOperator -ne 'Unknown' -and $first -match '^\$az\b')
                if ($runsAz -and $file.Name -ne 'Invoke-DemoAzCli.ps1') {
                    '{0}:{1}' -f $file.Name, $command.Extent.StartLineNumber
                }
            }
        }
        @($hits) | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DemoBatchArgument (quoting for az.cmd)' {
    It 'leaves an argument without cmd.exe metacharacters unchanged: <_>' -ForEach @('group', '--name', 'rg-dbhub-demo', '[0].value', '@C:\temp\p.json') {
        InModuleScope DbHubDemo -Parameters @{ Value = $_ } { ConvertTo-DemoBatchArgument -Argument $Value } | Should -BeExactly $_
    }

    It 'wraps an argument with cmd.exe metacharacters in quotes: <_>' -ForEach @('a&b', 'atScope()', 'a|b', 'x<y>z', 'caret^', 'two words', 'key=value', 'bang!') {
        InModuleScope DbHubDemo -Parameters @{ Value = $_ } { ConvertTo-DemoBatchArgument -Argument $Value } | Should -BeExactly ('"' + $_ + '"')
    }

    It 'quotes an empty argument so it is not dropped' {
        InModuleScope DbHubDemo { ConvertTo-DemoBatchArgument -Argument '' } | Should -BeExactly '""'
    }

    It 'doubles trailing backslashes before the closing quote' {
        InModuleScope DbHubDemo { ConvertTo-DemoBatchArgument -Argument 'C:\with space\' } | Should -BeExactly '"C:\with space\\"'
    }

    It 'refuses a double quote or a percent sign without echoing the value: <_>' -ForEach @('{"a":"b"}', 'p%PATH%q') {
        $value = $_
        $thrown = $null
        try { InModuleScope DbHubDemo -Parameters @{ Value = $value } { ConvertTo-DemoBatchArgument -Argument $Value } } catch { $thrown = $_.Exception.Message }
        $thrown | Should -Match "pass '@<path>'"
        $thrown | Should -Not -Match ([regex]::Escape($value))
    }
}

Describe 'Invoke-DemoAzCli through a batch-file wrapper' -Skip:(-not $IsWindows) {
    BeforeAll {
        # Same shape as az.cmd: an IF block that forwards %* to an interpreter that prints its parsed argv.
        $echoScript = Join-Path -Path $TestDrive -ChildPath 'echo-args.ps1'
        Set-Content -LiteralPath $echoScript -Encoding ascii -Value @(
            '$all = [System.Environment]::GetCommandLineArgs()'
            '$index = [array]::IndexOf($all, ''--dbhub-begin'')'
            'ConvertTo-Json -InputObject @($all | Select-Object -Skip ($index + 1)) -Compress'
        )
        $pwshPath = (Get-Process -Id $PID).Path
        $fakeAz = Join-Path -Path $TestDrive -ChildPath 'az.cmd'
        Set-Content -LiteralPath $fakeAz -Encoding ascii -Value @(
            '@IF EXIST "%~dp0echo-args.ps1" ('
            ('  "{0}" -NoLogo -NoProfile -NonInteractive -File "%~dp0echo-args.ps1" --dbhub-begin %*' -f $pwshPath)
            ') ELSE ('
            '  echo Failed to load the echo script. 1>&2'
            '  exit /b 1'
            ')'
        )
        # A wrapper that never finishes, like a token request waiting for an interactive prompt. The marker is unique
        # to this run, so the check below can't see the processes of another validation running on the same machine.
        $hangMarker = 'dbhub-guard-hang-{0}' -f [guid]::NewGuid().ToString('N')
        $hangingAz = Join-Path -Path $TestDrive -ChildPath 'hang\az.cmd'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $hangingAz -Parent) -Force
        Set-Content -LiteralPath $hangingAz -Encoding ascii -Value @(
            ('@"{0}" -NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 120 # {1}"' -f $pwshPath, $hangMarker)
        )
        $arguments = @(
            'rest'
            'https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft.Authorization/policyAssignments?$filter=atScope()&api-version=2023-04-01'
            "[?contains(name, 'x') && state != 'Deleted'].name"
            'a|b<c>d^e'
            'C:\path with space\'
            'adminPassword=Ab#*+-?_~xyz'
            'plain'
        )
    }

    It 'passes metacharacters and spaces through cmd.exe unchanged, with and without a time limit: <_>' -ForEach @(0, 60) {
        $timeout = $_
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'az' } -MockWith { [pscustomobject]@{ Source = $fakeAz } }

        $result = InModuleScope DbHubDemo -Parameters @{ Arguments = $arguments; Timeout = $timeout } { Invoke-DemoAzCli -ArgumentList $Arguments -TimeoutSeconds $Timeout }

        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $received = @($result.StdOut | ConvertFrom-Json)
        $received.Count | Should -Be $arguments.Count
        for ($i = 0; $i -lt $arguments.Count; $i++) {
            $received[$i] | Should -BeExactly $arguments[$i]
        }
    }

    It 'stops the Azure CLI and its child processes when the time limit passes' {
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'az' } -MockWith { [pscustomobject]@{ Source = $hangingAz } }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()

        $result = InModuleScope DbHubDemo { Invoke-DemoAzCli -ArgumentList @('account', 'get-access-token') -TimeoutSeconds 3 }

        $clock.Elapsed.TotalSeconds | Should -BeLessThan 60
        $result.ExitCode | Should -Be -1
        $result.StdErr | Should -Match 'did not finish within 3 seconds'
        $children = @()
        for ($wait = 0; $wait -lt 20; $wait++) {
            $children = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'pwsh.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($hangMarker) })
            if ($children.Count -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 500
        }
        $children | Should -BeNullOrEmpty
    }
}
