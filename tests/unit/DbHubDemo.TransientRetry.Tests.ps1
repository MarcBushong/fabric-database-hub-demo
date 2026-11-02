BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    # Obviously fake IDs: every group repeats one character.
    $script:subscriptionId = '11111111-2222-3333-4444-555555555555'
    $script:workspaceId = '22222222-2222-2222-2222-222222222222'
    $script:itemId = '33333333-3333-3333-3333-333333333333'
    $script:groupId = '44444444-4444-4444-4444-444444444444'
    # Built at run time so secret scanners don't flag the fixture.
    $script:plainToken = 'ey' + 'J' + ('t' * 24) + '.' + 'ey' + 'J' + ('p' * 24) + '.' + ('s' * 24)
    $script:token = [System.Security.SecureString]::new()
    foreach ($character in $script:plainToken.ToCharArray()) {
        $script:token.AppendChar($character)
    }
    $script:token.MakeReadOnly()

    function New-TestResponse([int] $Status, [object] $Body = $null, [hashtable] $Headers = @{}) {
        $content = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { '' }
        [pscustomobject]@{ StatusCode = $Status; Headers = $Headers; Content = $content }
    }

    # What Invoke-WebRequest threw live (2026-10-30): a TLS handshake that failed, before the request was sent.
    function New-TlsFailure {
        $alert = [System.Security.Authentication.AuthenticationException]::new('Authentication failed because the remote party sent a TLS alert: ''HandshakeFailure''.')
        [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::SecureConnectionError, 'The SSL connection could not be established, see inner exception.', $alert, $null)
    }

    # A timeout, which can come after the service processed the request.
    function New-Timeout {
        [System.Threading.Tasks.TaskCanceledException]::new('The request was canceled due to the configured HttpClient.Timeout of 120 seconds elapsing.', [System.TimeoutException]::new('The operation was canceled.'))
    }

    # Answers each Invoke-WebRequest from a queue (an exception in it is thrown), and records what was sent, slept, and logged.
    function Set-WebMock([object[]] $Answers) {
        $script:answers = [System.Collections.Generic.Queue[object]]::new()
        foreach ($answer in $Answers) {
            $script:answers.Enqueue($answer)
        }
        $script:sent = [System.Collections.Generic.List[string]]::new()
        $script:slept = [System.Collections.Generic.List[int]]::new()
        $script:logged = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $script:slept.Add([int]$PesterBoundParameters['Seconds']) }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add([string]$PesterBoundParameters['Message']) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $script:sent.Add(('{0} {1}' -f $PesterBoundParameters['Method'], $PesterBoundParameters['Uri']))
            $next = $script:answers.Dequeue()
            if ($next -is [System.Exception]) {
                throw $next
            }
            $next
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'One transient-retry policy for the REST helpers (Phase 28 live finding, 2026-10-30)' {
    # Live: configure-powerbi.ps1 stopped on "The SSL connection could not be established, see inner exception." during the
    # history model or report import, and the run ended NOT DONE; the helpers retried only HTTP 429.

    It 'sends a request again after a TLS handshake that failed, and returns the answer that came back, with one console line' {
        Set-WebMock @((New-TlsFailure), (New-TestResponse 200 @{ value = @() }))
        $response = InModuleScope DbHubDemo -Parameters @{ Token = $script:token } { Invoke-DemoPowerBIRequest -Method Get -Uri 'https://api.powerbi.com/v1.0/myorg/groups' -Token $Token }
        $response.StatusCode | Should -Be 200
        $script:sent.Count | Should -Be 2
        @($script:slept) | Should -Be @(5)
        @($script:logged) | Should -Be @('A network error reached api.powerbi.com; retrying in 5 s (attempt 2 of 4); no action needed.')
    }

    It 'retries HTTP 503, 502, 504, and 408, and 429 after its Retry-After, then returns the answer' {
        Set-WebMock @((New-TestResponse 503), (New-TestResponse 429 @{ errorCode = 'RequestBlocked' } @{ 'Retry-After' = @('7') }), (New-TestResponse 200 @{ value = @() }))
        $response = InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Uri = ('https://api.fabric.microsoft.com/v1/workspaces/{0}/items' -f $script:workspaceId) } { Invoke-DemoFabricRequest -Method Get -Uri $Uri -Token $Token }
        $response.StatusCode | Should -Be 200
        @($script:slept) | Should -Be @(5, 7)
        @($script:logged) | Should -Be @(
            'api.fabric.microsoft.com answered HTTP 503; retrying in 5 s (attempt 2 of 4); no action needed.'
            'api.fabric.microsoft.com answered HTTP 429; retrying in 7 s (attempt 3 of 4); no action needed.'
        )
        foreach ($code in 502, 504, 408) {
            Set-WebMock @((New-TestResponse $code), (New-TestResponse 200 @{ value = @() }))
            (InModuleScope DbHubDemo -Parameters @{ Token = $script:token } { Invoke-DemoPowerBIRequest -Method Get -Uri 'https://api.powerbi.com/v1.0/myorg/groups' -Token $Token }).StatusCode | Should -Be 200
            $script:sent.Count | Should -Be 2
        }
    }

    It 'throws a clear error after four network errors: the host, the attempts, and the innermost cause, never "see inner exception"' {
        Set-WebMock @((New-TlsFailure), (New-TlsFailure), (New-TlsFailure), (New-TlsFailure))
        $caught = $null
        try {
            InModuleScope DbHubDemo -Parameters @{ Token = $script:token } { Invoke-DemoPowerBIRequest -Method Get -Uri 'https://api.powerbi.com/v1.0/myorg/groups' -Token $Token } | Out-Null
        }
        catch {
            $caught = $_.Exception
        }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Message | Should -Be 'A network error reached api.powerbi.com on each of 4 attempts: The SSL connection could not be established: Authentication failed because the remote party sent a TLS alert: ''HandshakeFailure''.'
        $caught.Message | Should -Not -Match 'inner exception'
        (InModuleScope DbHubDemo -Parameters @{ Failure = $caught } { Test-DemoNetworkFailure -Exception $Failure }) | Should -BeTrue
        $script:sent.Count | Should -Be 4
        @($script:slept) | Should -Be @(5, 15, 30)
        @($script:logged) | Should -Be @(
            'A network error reached api.powerbi.com; retrying in 5 s (attempt 2 of 4); no action needed.'
            'A network error reached api.powerbi.com; retrying in 15 s (attempt 3 of 4); no action needed.'
            'A network error reached api.powerbi.com; retrying in 30 s (attempt 4 of 4); no action needed.'
        )

        # An HTTP failure that lasts comes back as the answer, for the caller's own message.
        Set-WebMock @((New-TestResponse 503), (New-TestResponse 503), (New-TestResponse 503), (New-TestResponse 503))
        (InModuleScope DbHubDemo -Parameters @{ Token = $script:token } { Invoke-DemoPowerBIRequest -Method Get -Uri 'https://api.powerbi.com/v1.0/myorg/groups' -Token $Token }).StatusCode | Should -Be 503
        $script:sent.Count | Should -Be 4
    }

    It 'sends a request that starts something again only when it never reached the service, or on HTTP 429' {
        $submit = 'https://api.fabric.microsoft.com/v1/workspaces/{0}/items/{1}/jobs/instances?jobType=RunNotebook' -f $script:workspaceId, $script:itemId
        Set-WebMock @((New-TlsFailure), (New-TestResponse 202))
        (InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Uri = $submit } { Invoke-DemoFabricRequest -Method Post -Uri $Uri -Token $Token -NotIdempotent }).StatusCode | Should -Be 202
        $script:sent.Count | Should -Be 2 -Because 'a TLS handshake that failed sent nothing'

        Set-WebMock @((New-TestResponse 503))
        (InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Uri = $submit } { Invoke-DemoFabricRequest -Method Post -Uri $Uri -Token $Token -NotIdempotent }).StatusCode | Should -Be 503
        $script:sent.Count | Should -Be 1 -Because 'the service may have started the run'

        Set-WebMock @((New-TestResponse 429 $null @{ 'Retry-After' = @('3') }), (New-TestResponse 202))
        (InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Uri = $submit } { Invoke-DemoFabricRequest -Method Post -Uri $Uri -Token $Token -NotIdempotent }).StatusCode | Should -Be 202
        @($script:slept) | Should -Be @(3)

        Set-WebMock @((New-Timeout))
        { InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Uri = $submit } { Invoke-DemoFabricRequest -Method Post -Uri $Uri -Token $Token -NotIdempotent } } |
            Should -Throw -ExpectedMessage 'A network error reached api.fabric.microsoft.com, and the request wasn''t sent again, because the server may have processed it: The request was canceled due to the configured HttpClient.Timeout of 120 seconds elapsing: The operation was canceled.'
        $script:sent.Count | Should -Be 1
    }

    It 'leaves everything else alone: an HTTP 404 comes back at once, and an error that isn''t a network error is thrown at once' {
        Set-WebMock @((New-TestResponse 404 @{ errorCode = 'ItemNotFound' }))
        (InModuleScope DbHubDemo -Parameters @{ Token = $script:token } { Invoke-DemoPowerBIRequest -Method Get -Uri 'https://api.powerbi.com/v1.0/myorg/groups' -Token $Token }).StatusCode | Should -Be 404
        $script:sent.Count | Should -Be 1
        Set-WebMock @([System.InvalidOperationException]::new('A script error.'))
        { InModuleScope DbHubDemo -Parameters @{ Token = $script:token } { Invoke-DemoPowerBIRequest -Method Get -Uri 'https://api.powerbi.com/v1.0/myorg/groups' -Token $Token } } | Should -Throw -ExpectedMessage 'A script error.'
        $script:sent.Count | Should -Be 1
        @($script:slept).Count | Should -Be 0
        # The allow-list holds before anything is sent.
        { InModuleScope DbHubDemo -Parameters @{ Token = $script:token } { Invoke-DemoPowerBIRequest -Method Get -Uri 'https://example.com/v1.0/myorg/groups' -Token $Token } } | Should -Throw '*Refusing*'
        $script:sent.Count | Should -Be 1
    }

    It 'sends a read again in Invoke-DemoRestRequest, and a POST that adds a member only when it never reached the service' {
        $read = 'https://management.azure.com/subscriptions/{0}/resourceGroups?api-version=2021-04-01' -f $script:subscriptionId
        Set-WebMock @((New-TlsFailure), (New-TestResponse 200 @{ value = @() }))
        $call = InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Uri = $read; Subscription = $script:subscriptionId } { Invoke-DemoRestRequest -SubscriptionId $Subscription -Method GET -Uri $Uri -Token $Token }
        $call.ExitCode | Should -Be 0
        $script:sent.Count | Should -Be 2

        $add = 'https://graph.microsoft.com/v1.0/groups/{0}/members/$ref' -f $script:groupId
        Set-WebMock @((New-TestResponse 503))
        $call = InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Uri = $add; Subscription = $script:subscriptionId } { Invoke-DemoRestRequest -SubscriptionId $Subscription -Method POST -Uri $Uri -Body '{}' -Token $Token }
        $call.ExitCode | Should -Be 1
        $script:sent.Count | Should -Be 1

        Set-WebMock @((New-TestResponse 503), (New-TestResponse 200 @{ value = @() }))
        $call = InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Subscription = $script:subscriptionId } { Invoke-DemoRestRequest -SubscriptionId $Subscription -Method POST -Uri 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' -Body '{}' -Token $Token }
        $call.ExitCode | Should -Be 0 -Because 'getByIds only reads'

        Set-WebMock @((New-TlsFailure), (New-TlsFailure), (New-TlsFailure), (New-TlsFailure))
        $call = InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Uri = $read; Subscription = $script:subscriptionId } { Invoke-DemoRestRequest -SubscriptionId $Subscription -Method GET -Uri $Uri -Token $Token }
        $call.ExitCode | Should -Be 1
        $call.StdErr | Should -Match '^A network error reached management\.azure\.com on each of 4 attempts: The SSL connection could not be established: Authentication failed'
    }

    It 'turns a retried create that finds the item its first attempt made into an update (POST safety)' {
        # The first create reached Fabric, but its answer was lost (HTTP 502); the second finds the name taken.
        $itemsUri = 'https://api.fabric.microsoft.com/v1/workspaces/{0}/items' -f $script:workspaceId
        Set-WebMock @(
            (New-TestResponse 200 @{ value = @() })
            (New-TestResponse 502)
            (New-TestResponse 400 @{ errorCode = 'ItemDisplayNameAlreadyInUse'; message = 'Item display name is already used.' })
            (New-TestResponse 200 @{ value = @(@{ id = $script:itemId; displayName = 'NB_Test'; type = 'Notebook' }) })
            (New-TestResponse 200)
        )
        $item = [pscustomobject]@{ PSTypeName = 'DbHubDemo.FabricItemDefinition'; DisplayName = 'NB_Test'; Type = 'Notebook'; Definition = [ordered]@{ format = 'ipynb'; parts = @() }; Sha256 = ('a' * 64); SizeBytes = 10 }
        $result = InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Workspace = $script:workspaceId; Item = $item } { Import-DemoFabricItem -WorkspaceId $Workspace -Item $Item -Token $Token -Confirm:$false }
        $result.status | Should -Be 'Pass'
        $result.evidence.operation | Should -Be 'updated'
        @($script:sent | Where-Object { $_ -eq ('Post {0}' -f $itemsUri) }).Count | Should -Be 2
        $script:sent[-1] | Should -Be ('Post {0}/{1}/updateDefinition' -f $itemsUri, $script:itemId)
    }

    It 'reports an import a network error stopped with its innermost cause, evidence networkError, and a rerun as the fix' {
        Set-WebMock @((New-TlsFailure), (New-TlsFailure), (New-TlsFailure), (New-TlsFailure))
        $item = [pscustomobject]@{ PSTypeName = 'DbHubDemo.FabricItemDefinition'; DisplayName = 'SM_Test'; Type = 'SemanticModel'; Definition = [ordered]@{ parts = @() }; Sha256 = ('b' * 64); SizeBytes = 10 }
        $result = InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Workspace = $script:workspaceId; Item = $item } { Import-DemoFabricItem -WorkspaceId $Workspace -Item $Item -Token $Token -Confirm:$false }
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'stopped: A network error reached api\.fabric\.microsoft\.com on each of 4 attempts: The SSL connection could not be established: Authentication failed'
        $result.evidence.networkError | Should -BeTrue
        $result.remediation | Should -Be 'Run the script again: the import is idempotent. A network error stopped it (requests that are safe to repeat were retried).'
        (InModuleScope DbHubDemo -Parameters @{ Result = $result } { Test-DemoNetworkResult -Result $Result }) | Should -BeTrue
    }
}

Describe 'Get-DemoExceptionText, Test-DemoNetworkFailure, and Test-DemoUnsentRequest' {
    It 'names the innermost cause instead of "see inner exception", redacted' {
        InModuleScope DbHubDemo -Parameters @{ Failure = (New-TlsFailure) } { Get-DemoExceptionText -Exception $Failure } |
            Should -Be 'The SSL connection could not be established: Authentication failed because the remote party sent a TLS alert: ''HandshakeFailure''.'
        InModuleScope DbHubDemo { Get-DemoExceptionText -Exception ([System.InvalidOperationException]::new('Just one message')) } | Should -Be 'Just one message.'
        $withToken = [System.InvalidOperationException]::new('Outer, see inner exception.', [System.IO.IOException]::new(('Bearer {0} was refused.' -f $script:plainToken)))
        $text = InModuleScope DbHubDemo -Parameters @{ Failure = $withToken } { Get-DemoExceptionText -Exception $Failure }
        $text | Should -Not -Match ([regex]::Escape($script:plainToken))
        $text | Should -Match '^Outer: Bearer \[REDACTED'
    }

    It 'tells a network failure from any other error, and one that never reached the server from one that may have' {
        InModuleScope DbHubDemo -Parameters @{ Failure = (New-TlsFailure) } { (Test-DemoNetworkFailure -Exception $Failure), (Test-DemoUnsentRequest -Exception $Failure) } | Should -Be @($true, $true)
        InModuleScope DbHubDemo -Parameters @{ Failure = (New-Timeout) } { (Test-DemoNetworkFailure -Exception $Failure), (Test-DemoUnsentRequest -Exception $Failure) } | Should -Be @($true, $false)
        $reset = [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::ResponseEnded, 'The response ended prematurely.', $null, $null)
        InModuleScope DbHubDemo -Parameters @{ Failure = $reset } { (Test-DemoNetworkFailure -Exception $Failure), (Test-DemoUnsentRequest -Exception $Failure) } | Should -Be @($true, $false)
        $dns = [System.Net.Http.HttpRequestException]::new('No such host is known.', [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::HostNotFound))
        InModuleScope DbHubDemo -Parameters @{ Failure = $dns } { Test-DemoUnsentRequest -Exception $Failure } | Should -BeTrue
        InModuleScope DbHubDemo { Test-DemoNetworkFailure -Exception ([System.InvalidOperationException]::new('Refusing to send the Fabric token outside the API.')) } | Should -BeFalse
    }
}

Describe 'deploy.ps1 after a network error that lasted (Phase 28 live finding, 2026-10-30)' {
    BeforeAll {
        $script:config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $script:config['subscriptionId'] = $script:subscriptionId
        $script:config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $script:config['t4Enabled'] = $false
    }

    It 'reports a Fabric script a network error stopped with evidence networkError and a rerun of deploy.ps1, not the script''s own output' {
        $folder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $path = Join-Path -Path $folder -ChildPath 'network-error.ps1'
        Set-Content -LiteralPath $path -Value @'
param([string] $ConfigPath, [string] $OutputPath)
$failure = [System.Net.Http.HttpRequestException]::new('A network error reached api.powerbi.com on each of 4 attempts: The SSL connection could not be established: Received an unexpected EOF or 0 bytes from the transport stream.')
$failure.Data['DbHubDemo.NetworkError'] = $true
throw $failure
'@
        $records = @(InModuleScope DbHubDemo -Parameters @{ Config = $script:config; Path = $path } { Invoke-DemoFabricScriptStep -Config $Config -ScriptPath $Path -CheckId 'DEPLOY.POWERBI' })
        $records[0].status | Should -Be 'Fail'
        $records[0].message | Should -Be 'network-error.ps1 stopped: A network error reached api.powerbi.com on each of 4 attempts: The SSL connection could not be established: Received an unexpected EOF or 0 bytes from the transport stream.'
        $records[0].evidence.networkError | Should -BeTrue
        $records[0].remediation | Should -Be 'Run ./scripts/deploy.ps1 again: it resumes where it stopped. A network error stopped it (requests that are safe to repeat were retried).'
    }

    It 'says to run deploy.ps1 again, which resumes, when a network error stopped a step, and keeps each other failure''s own fix' {
        $network = New-DemoResult -CheckId 'DEPLOY.POWERBI' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'configure-powerbi.ps1 stopped: A network error reached api.powerbi.com on each of 4 attempts: The SSL connection could not be established.' -Remediation 'Run ./scripts/configure-powerbi.ps1 yourself to see its output.'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Results = @($network); Config = $script:config } { Get-DemoDeploymentOutcome -Result $Results -Config $Config -Command './scripts/deploy.ps1' }
        $outcome.Done | Should -BeFalse
        $outcome.Next | Should -Be 'Run ./scripts/deploy.ps1 again: it resumes where it stopped. A network error stopped it (requests that are safe to repeat were retried).'
        $outcome.NextCommand | Should -Be './scripts/deploy.ps1'

        # Review of c7c86ec: a request that starts something was sent once, so "lasted through the retries" wasn't true.
        $once = New-DemoResult -CheckId 'DEPLOY.POWERBI' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'The refresh stopped: A network error reached api.powerbi.com, and the request wasn''t sent again, because the server may have processed it: The operation was canceled.' -Remediation 'Run the script again; the refresh is idempotent.'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Results = @($once); Config = $script:config } { Get-DemoDeploymentOutcome -Result $Results -Config $Config -Command './scripts/deploy.ps1' }
        $outcome.Next | Should -Be 'Run ./scripts/deploy.ps1 again: it resumes where it stopped. A network error stopped it (requests that are safe to repeat were retried).'
        $outcome.Next | Should -Not -Match 'lasted through'

        $other = New-DemoResult -CheckId 'DEPLOY.POWERBI' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'configure-powerbi.ps1 stopped: the capacity is paused' -Remediation 'Run ./scripts/configure-powerbi.ps1 yourself to see its output.'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Results = @($other); Config = $script:config } { Get-DemoDeploymentOutcome -Result $Results -Config $Config -Command './scripts/deploy.ps1' }
        $outcome.Next | Should -Be 'Run ./scripts/configure-powerbi.ps1 yourself to see its output. Then run ./scripts/deploy.ps1.'
    }

    It 'logs one console line as soon as a track step fails: what failed, why, and that a rerun resumes it' {
        InModuleScope DbHubDemo { Get-DemoStepFailureLine -Label (Get-DemoProgressStepLabel -Id 'Fabric.Report') -Message 'configure-powerbi.ps1 stopped: A network error reached api.powerbi.com on each of 4 attempts.' } |
            Should -Be 'The history report step failed: configure-powerbi.ps1 stopped: A network error reached api.powerbi.com on each of 4 attempts. The other tracks continue; the run ends NOT DONE, and ./scripts/deploy.ps1 resumes it.'
        InModuleScope DbHubDemo { (Get-DemoProgressStepLabel -Id 'T1.Monitoring'), (Get-DemoProgressStepLabel -Id 'T3.Setup'), (Get-DemoProgressStepLabel -Id 'T2.GuidedStop'), (Get-DemoProgressStepLabel -Id 'T2.Monitoring') } |
            Should -Be @('monitoring', 'T3 setup from T1', 'guided stop', 'PAYG and monitoring')
    }
}

Describe 'A lasting outage costs one request''s retries, not one per item or poll (review of c7c86ec)' {
    BeforeAll {
        # An instant DNS failure on every request, as the reviewer reproduced it.
        function New-DnsFailure([string] $HostName) {
            [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::NameResolutionError, ('No such host is known. ({0}:443)' -f $HostName), [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::HostNotFound), $null)
        }
        function Set-OutageMock {
            $script:sent = [System.Collections.Generic.List[string]]::new()
            $script:warned = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
            Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { if ($PesterBoundParameters['Level'] -eq 'Warning') { $script:warned.Add([string]$PesterBoundParameters['Message']) } }
            Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
                $script:sent.Add(('{0} {1}' -f $PesterBoundParameters['Method'], $PesterBoundParameters['Uri']))
                throw (New-DnsFailure -HostName ([uri][string]$PesterBoundParameters['Uri']).Host)
            }
        }
        $script:policyConfig = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $script:policyConfig['subscriptionId'] = $script:subscriptionId
        $script:policyConfig['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $script:policyConfig['networkMode'] = 'auto'
    }

    It 'says a request a network error stopped is one, in Invoke-DemoRestRequest''s answer' {
        Set-OutageMock
        $read = 'https://management.azure.com/providers/Microsoft.Authorization/policyDefinitions/demo-0?api-version=2023-04-01'
        $call = InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Uri = $read; Subscription = $script:subscriptionId } { Invoke-DemoRestRequest -SubscriptionId $Subscription -Method GET -Uri $Uri -Token $Token }
        $call.ExitCode | Should -Be 1
        $call.StatusCode | Should -Be 0
        $call.NetworkError | Should -BeTrue
        $script:sent.Count | Should -Be 4
    }

    It 'stops waiting for a workspace''s capacity assignment at the first read a network error stopped' {
        # Before: each poll paid its own 4 attempts, 244 requests where the wait had made 61.
        Set-OutageMock
        $wait = InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Workspace = $script:workspaceId } { Wait-DemoFabricCapacityAssignment -WorkspaceId $Workspace -Token $Token -TimeoutSeconds 300 }
        $wait.NetworkError | Should -BeTrue
        $wait.Progress | Should -Be 'Unknown'
        $wait.Error | Should -Match '^No response: A network error reached api\.fabric\.microsoft\.com on each of 4 attempts: No such host is known'
        $script:sent.Count | Should -Be 4
    }

    It 'counts the capacity wait in elapsed time, the reads included' {
        $script:sent = [System.Collections.Generic.List[string]]::new()
        $script:now = [datetime]::new(2026, 11, 2, 15, 0, 0, [System.DateTimeKind]::Utc)
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $script:now = $script:now.AddSeconds([int]$PesterBoundParameters['Seconds']) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $script:now }
        # Each read answers after 60 seconds of HTTP 503 and its retries, then InProgress.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -MockWith {
            $script:sent.Add([string]$Uri)
            $script:now = $script:now.AddSeconds(60)
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = [pscustomobject]@{ id = $script:workspaceId; capacityAssignmentProgress = 'InProgress' } }
        }
        $start = $script:now
        $wait = InModuleScope DbHubDemo -Parameters @{ Token = $script:token; Workspace = $script:workspaceId } { Wait-DemoFabricCapacityAssignment -WorkspaceId $Workspace -Token $Token -TimeoutSeconds 120 -PollSeconds 5 }
        $wait.Progress | Should -Be 'InProgress'
        $script:sent.Count | Should -BeLessOrEqual 3 -Because 'before, the wait counted only its own 5-second sleeps and read 25 times'
        ($script:now - $start).TotalSeconds | Should -BeLessOrEqual 190
    }

    It 'stops reading policy definitions after the first one a network error stopped, and counts the rest as unreadable, with one Warning' {
        # Before: 20 unreadable definitions took 80 requests and about 17 minutes.
        Set-OutageMock
        Mock -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -MockWith { [pscustomobject]@{ Token = $script:token; Error = '' } }
        $script:assignmentList = ConvertTo-Json -Depth 10 -InputObject @{ value = @(foreach ($index in 1..20) {
                    @{ name = ('demo-{0}' -f $index); properties = @{ displayName = ('Demo policy {0}' -f $index); scope = ('/subscriptions/{0}' -f $script:subscriptionId); enforcementMode = 'Default'; policyDefinitionId = ('/providers/Microsoft.Authorization/policyDefinitions/demo-{0}' -f $index) } }
                }) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:assignmentList; StdErr = '' } }
        $policy = InModuleScope DbHubDemo -Parameters @{ Config = $script:policyConfig } { Get-DemoPolicyConstraint -Config $Config }
        $script:sent.Count | Should -Be 4
        $inventory = $policy.Results | Where-Object { $_.checkId -eq 'PREFLIGHT.POLICY.INVENTORY' }
        $inventory.status | Should -Be 'Warning'
        $inventory.message | Should -Match 'definition demo-1 \(built-in\) in assignment "Demo policy 1" \(A network error reached management\.azure\.com on each of 4 attempts: No such host is known'
        $inventory.message | Should -Match '19 more definition\(s\) and set\(s\), not read after the network error'
        @($script:warned | Where-Object { $_ -match '^Policy inventory: a network error lasted through the attempts to read a definition, so no more are read' }).Count | Should -Be 1
        ($policy.Results | Where-Object { $_.checkId -eq 'PREFLIGHT.POLICY.SQLPUBLIC' }).evidence.effectiveNetworkMode | Should -Be 'private' -Because 'networkMode auto resolves to private when the inventory isn''t complete'
    }
}
