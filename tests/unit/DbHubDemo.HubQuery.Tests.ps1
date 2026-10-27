BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    $versions = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $queryUrl = $versions.databaseHub.telemetry.queryUrl
    $script:okJson = ConvertTo-HubSummaryJson -Entry @(@{ Id = $script:HubT1Id; Type = 'virtualMachines'; Name = 'sqlvm01'; Rows = 5; First = $script:HubNow.AddMinutes(-10); Last = $script:HubNow.AddMinutes(-1) })
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Invoke-DemoHubHttp (the token travels only as a SecureString bearer token)' {
    BeforeEach {
        Clear-DemoSecret
        $script:token = Get-HubFakeToken
        $script:secureToken = ConvertTo-HubSecureString $script:token
        $script:captured = $null
    }

    It 'sends the bearer token with -Authentication, never in a header string, the URI, or the body, without throwing on HTTP errors' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-RestMethod -MockWith {
            # PowerShell 7.4 renamed -TimeoutSec to -ConnectionTimeoutSeconds and kept TimeoutSec as an alias.
            $timeout = foreach ($name in 'ConnectionTimeoutSeconds', 'TimeoutSec') {
                $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
                if ($value) { $value; break }
            }
            $script:captured = [pscustomobject]@{ Headers = $Headers.Clone(); Authentication = [string]$Authentication; Token = $Token; Uri = [string]$Uri; Body = [string]$Body; Skip = [bool]$SkipHttpErrorCheck; Timeout = $timeout; ContentType = $ContentType }
            [pscustomobject]@{ ok = $true }
        }
        $response = InModuleScope -ModuleName DbHubDemo -Parameters @{ Token = $script:secureToken; Url = $queryUrl } {
            param($Token, $Url)
            Invoke-DemoHubHttp -Method Post -Uri $Url -Token $Token -Body '{"db":"ArcSqlTelemetry","csl":"print 1"}' -TimeoutSec 45
        }
        $response.Content.ok | Should -BeTrue
        $script:captured.Authentication | Should -Be 'Bearer'
        $script:captured.Token | Should -BeOfType [securestring]
        ConvertFrom-HubSecureString $script:captured.Token | Should -Be $script:token
        $script:captured.Headers.ContainsKey('Authorization') | Should -BeFalse
        ($script:captured.Headers.Values -join ' ') | Should -Not -Match ([regex]::Escape($script:token))
        $script:captured.Headers['Accept'] | Should -Be 'application/json'
        $script:captured.Uri | Should -Not -Match ([regex]::Escape($script:token))
        $script:captured.Body | Should -Not -Match ([regex]::Escape($script:token))
        $script:captured.Skip | Should -BeTrue
        $script:captured.Timeout | Should -Be 45
        $script:captured.ContentType | Should -Match '^application/json'
    }

    It 'returns status 0 and a redacted error on a network failure' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-RestMethod -MockWith { throw ('connection reset while sending Bearer ' + [System.Net.NetworkCredential]::new('', $Token).Password) }
        $response = InModuleScope -ModuleName DbHubDemo -Parameters @{ Token = $script:secureToken; Plain = $script:token; Url = $queryUrl } {
            param($Token, $Plain, $Url)
            Register-DemoSecret -Value $Plain
            Invoke-DemoHubHttp -Method Get -Uri $Url -Token $Token
        }
        $response.StatusCode | Should -Be 0
        $response.Error | Should -Match 'connection reset'
        $response.Error | Should -Not -Match ([regex]::Escape($script:token))
    }
}

Describe 'Invoke-DemoHubTelemetryQuery' {
    BeforeEach {
        Clear-DemoSecret
        $script:token = Get-HubFakeToken
        Initialize-HubAzMock -Token $script:token
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
    }

    It 'posts the documented body to the documented endpoint with a Kusto token and maps the rows' {
        Initialize-HubHttpMock -Handler { ConvertTo-HubHttpResponse -Json $script:okJson }
        $result = Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query 'SqlServerCPUUtilization | where SampleTimeUTC > ago(5m) | take 1'
        $result.Succeeded | Should -BeTrue
        $result.Rows.Count | Should -Be 1
        $result.Rows[0].ResourceName | Should -Be 'sqlvm01'
        $result.Attempts | Should -Be 1
        $script:HubHttpCalls.Count | Should -Be 1
        $script:HubHttpCalls[0].Method | Should -Be 'Post'
        $script:HubHttpCalls[0].Uri | Should -Be $queryUrl
        $script:HubHttpCalls[0].Token | Should -Be $script:token
        $body = $script:HubHttpCalls[0].Body | ConvertFrom-Json -AsHashtable
        $body.db | Should -Be 'ArcSqlTelemetry'
        $body.csl | Should -BeOfType [string]
        $body.csl | Should -Be 'SqlServerCPUUtilization | where SampleTimeUTC > ago(5m) | take 1'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter {
            $joined = $ArgumentList -join ' '
            $joined -eq "account get-access-token --resource https://kusto.kusto.windows.net --output json --subscription $($script:HubSubscriptionId)" -and $TimeoutSeconds -gt 0
        }
        # The token is registered as a secret the moment it's issued.
        Protect-DemoText -Text ('value ' + $script:token) | Should -Be 'value [REDACTED]'
    }

    It 'does not retry HTTP 403 and reports it as Forbidden' {
        Initialize-HubHttpMock -Handler { ConvertTo-HubHttpResponse -StatusCode 403 -Json '{"error":{"code":"Forbidden","message":"Principal is not authorized"}}' }
        $result = Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query 'print 1'
        $result.Succeeded | Should -BeFalse
        $result.ErrorKind | Should -Be 'Forbidden'
        $result.StatusCode | Should -Be 403
        $result.Error | Should -Match 'not authorized'
        $script:HubHttpCalls.Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0
    }

    It 'reports HTTP 400 as BadRequest and HTTP 500 as ServerError, without retries' {
        Initialize-HubHttpMock -Handler { ConvertTo-HubHttpResponse -StatusCode 400 }
        (Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query 'print 1').ErrorKind | Should -Be 'BadRequest'
        Initialize-HubHttpMock -Handler { ConvertTo-HubHttpResponse -StatusCode 500 }
        (Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query 'print 1').ErrorKind | Should -Be 'ServerError'
        $script:HubHttpCalls.Count | Should -Be 1
    }

    It 'gets one fresh token after HTTP 401 and tries again' {
        $script:seen = 0
        Initialize-HubHttpMock -Handler {
            $script:seen++
            if ($script:seen -eq 1) { ConvertTo-HubHttpResponse -StatusCode 401 } else { ConvertTo-HubHttpResponse -Json $script:okJson }
        }
        $result = Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query 'print 1'
        $result.Succeeded | Should -BeTrue
        $result.Attempts | Should -Be 2
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 2 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'get-access-token' }
    }

    It 'honors Retry-After on HTTP 429 and retries' {
        $script:seen = 0
        Initialize-HubHttpMock -Handler {
            $script:seen++
            if ($script:seen -eq 1) { ConvertTo-HubHttpResponse -StatusCode 429 -RetryAfterSeconds 7 } else { ConvertTo-HubHttpResponse -Json $script:okJson }
        }
        (Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query 'print 1').Succeeded | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
    }

    It 'stops after MaxAttempts network failures' {
        Initialize-HubHttpMock -Handler { ConvertTo-HubHttpResponse -StatusCode 0 -ErrorText 'The request timed out.' }
        $result = Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query 'print 1' -MaxAttempts 3
        $result.ErrorKind | Should -Be 'Network'
        $result.Attempts | Should -Be 3
        $result.Error | Should -Match 'timed out'
        $script:HubHttpCalls.Count | Should -Be 3
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly
    }

    It 'reports a missing token without calling the endpoint' {
        Initialize-HubAzMock -Token $script:token -TokenFails
        Initialize-HubHttpMock -Handler { throw 'must not be called' }
        $result = Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query 'print 1'
        $result.ErrorKind | Should -Be 'Token'
        $result.Error | Should -Match 'without interaction'
        $script:HubHttpCalls.Count | Should -Be 0
    }

    It 'keeps the rows of a partial failure but marks it' {
        $script:partialBody = '{"Tables":[{"TableName":"Table_0","Columns":[{"ColumnName":"Rows","DataType":"Int64","ColumnType":"long"}],"Rows":[[5],{"Exceptions":["partial"]}]}]}'
        Initialize-HubHttpMock -Handler { ConvertTo-HubHttpResponse -Json $script:partialBody }
        $result = Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query 'print 1'
        $result.Succeeded | Should -BeFalse
        $result.ErrorKind | Should -Be 'PartialFailure'
        $result.Rows.Count | Should -Be 1
    }

    It 'reports a body without the documented shape as InvalidResponse' {
        Initialize-HubHttpMock -Handler { ConvertTo-HubHttpResponse -Json '{"value":[]}' }
        (Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query 'print 1').ErrorKind | Should -Be 'InvalidResponse'
    }

    It 'refuses management (dot) commands' {
        Initialize-HubHttpMock -Handler { throw 'must not be called' }
        { Invoke-DemoHubTelemetryQuery -SubscriptionId $script:HubSubscriptionId -Query "// comment`n  .show database schema as json" } | Should -Throw '*read-only KQL only*'
        $script:HubHttpCalls.Count | Should -Be 0
    }
}
