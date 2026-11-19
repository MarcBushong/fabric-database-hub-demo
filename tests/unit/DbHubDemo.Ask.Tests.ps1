BeforeAll {
    # Ask, the Copilot chat in the Insights app (ADR 0028): its settings and names, its relay's setup against a fake Azure
    # (the template, its parameters, the origin it keeps, a failure as a Warning), the relay's health and sign-in checks,
    # the strict-CSP tenant setting, and how deploy.ps1 shows it (never blocking DONE). Azure is a fake behind
    # Invoke-DemoAzCli, so Invoke-DemoAz (the subscription guard) and the private parameters file run for real. IDs and
    # names are placeholders.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')

    $script:sub = '11111111-2222-3333-4444-555555555555'
    $script:appOrigin = 'https://contoso-app-westus3.webapp.fabricapps.net'
    $script:endpoint = 'https://ca-dbhub-demo-ask.blue-rock-1234.westus3.azurecontainerapps.io'
    $script:image = 'ghcr.io/contoso/fabric-database-hub-demo/ask-relay@sha256:' + ('a' * 64)

    function New-AskConfig([hashtable] $Ask = @{}) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = $script:sub
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        foreach ($key in $Ask.Keys) {
            $config['ask'][$key] = $Ask[$key]
        }
        return $config
    }

    function New-AzResult([int] $ExitCode = 0, [string] $StdOut = '', [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
    }

    function Get-ArgumentValue([object[]] $Arguments, [string] $Name) {
        $index = [array]::IndexOf($Arguments, $Name)
        if ($index -ge 0 -and $index + 1 -lt $Arguments.Count) {
            return [string]$Arguments[$index + 1]
        }
        return ''
    }

    function Reset-FakeAzure {
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:deployments = [System.Collections.Generic.List[object]]::new()
        $script:providerState = 'Registered'
        $script:templateFails = $false
        $script:relayExists = $false
        $script:relayOrigins = ''
    }

    function Register-FakeAzure {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $words = @($ArgumentList)
            $text = $words -join ' '
            $script:azCalls.Add($text)
            foreach ($word in $words) {
                if ([string]$word -match '["%]') {
                    throw "An Azure CLI argument contains '`"' or '%', which cmd.exe can't pass to az.cmd unchanged."
                }
            }
            switch -Wildcard ($text) {
                'provider show*' { return (New-AzResult -StdOut $script:providerState) }
                'provider register*' {
                    $script:providerState = 'Registered'
                    return (New-AzResult)
                }
                'resource show*Microsoft.App/containerApps*' {
                    if (-not $script:relayExists) {
                        return (New-AzResult -ExitCode 3 -StdErr 'ERROR: (ResourceNotFound) The Resource ''Microsoft.App/containerApps/ca-dbhub-demo-ask'' was not found.')
                    }
                    $data = @{ image = $script:image; env = @(@{ name = 'ALLOWED_ORIGINS'; value = $script:relayOrigins }, @{ name = 'GITHUB_CLIENT_ID'; value = 'Ov23liExampleClientId' }); fqdn = ([uri]$script:endpoint).Host }
                    return (New-AzResult -StdOut (ConvertTo-Json -InputObject $data -Depth 5 -Compress))
                }
                'group show*' {
                    return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ name = 'rg-dbhub-demo'; tags = @{ solution = 'fabric-database-hub-demo'; owner = 'owner@contoso.example'; environment = 'demo'; unrelated = 'x' } } -Depth 4 -Compress))
                }
                'deployment group create*' {
                    $file = (Get-ArgumentValue $words '--parameters').Substring(1)
                    $script:deployments.Add([pscustomobject]@{ Text = $text; Raw = (Get-Content -LiteralPath $file -Raw); Parameters = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable) })
                    if ($script:templateFails) {
                        return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (RequestDisallowedByPolicy) Resource ''ca-dbhub-demo-ask'' was disallowed by policy.')
                    }
                    $script:relayExists = $true
                    $script:relayOrigins = [string]$script:deployments[-1].Parameters['parameters']['allowedOrigins']['value']
                    return (New-AzResult -StdOut (ConvertTo-Json -InputObject @{ endpoint = @{ type = 'String'; value = $script:endpoint } } -Depth 4))
                }
            }
            return (New-AzResult -ExitCode 1 -StdErr ('ERROR: the fake has no answer for: {0}' -f $text))
        }
    }
}

Describe 'Ask settings and names' {
    It 'uses the pinned client ID and image by default, and the configuration''s when it sets them' {
        $versions = @{ askRelay = @{ image = $script:image; githubClientId = 'Ov23liPinnedClientId'; containerApp = @{ cpu = '1.0'; memory = '2Gi'; maxReplicas = 1 } } }
        InModuleScope DbHubDemo -Parameters @{ Config = (New-AskConfig); Versions = $versions } {
            param($Config, $Versions)
            $setting = Get-DemoAskSetting -Config $Config -Versions $Versions
            $setting.Enabled | Should -BeTrue
            $setting.ImageSource | Should -Be 'pinned'
            $setting.GithubClientId | Should -Be 'Ov23liPinnedClientId'
            $setting.ClientIdSource | Should -Be 'pinned'
        }
        $own = 'registry.contoso.example/relay@sha256:' + ('b' * 64)
        InModuleScope DbHubDemo -Parameters @{ Config = (New-AskConfig -Ask @{ image = $own; githubClientId = 'Ov23liMyOwnClientId1' }); Versions = $versions } {
            param($Config, $Versions)
            $setting = Get-DemoAskSetting -Config $Config -Versions $Versions
            $setting.ImageSource | Should -Be 'config'
            $setting.ClientIdSource | Should -Be 'config'
            $setting.GithubClientId | Should -Be 'Ov23liMyOwnClientId1'
        }
    }

    It 'turns off only with "enabled": false, and an older configuration without an ask block gets it on' {
        $config = New-AskConfig
        $config.Remove('ask')
        InModuleScope DbHubDemo -Parameters @{ Config = $config } {
            param($Config)
            (Get-DemoAskSetting -Config $Config -Versions @{}).Enabled | Should -BeTrue
        }
        InModuleScope DbHubDemo -Parameters @{ Config = (New-AskConfig -Ask @{ enabled = $false }) } {
            param($Config)
            (Get-DemoAskSetting -Config $Config -Versions @{}).Enabled | Should -BeFalse
        }
    }

    It 'names the relay within Container Apps'' limits, for the longest prefix and environment the schema allows' {
        $config = New-AskConfig
        $config['prefix'] = 'abcdefgh'
        $config['environment'] = 'stuvwxyz'
        InModuleScope DbHubDemo -Parameters @{ Config = $config } {
            param($Config)
            $name = Get-DemoAskRelayName -Config $Config
            $name.App | Should -Be 'ca-abcdefgh-stuvwxyz-ask'
            $name.App.Length | Should -BeLessOrEqual 32
            $name.App | Should -Match '^[a-z][a-z0-9-]*[a-z0-9]$'
            $name.Environment | Should -Be 'cae-abcdefgh-stuvwxyz-ask'
            $name.ResourceGroup | Should -Be 'rg-abcdefgh-stuvwxyz'
        }
    }

    It 'takes the app''s origin from its hosting URL, else from the stage''s deployment record, and only for https' {
        Get-DemoFabricAppOrigin -HostingUrl ($script:appOrigin + '/index.html') | Should -Be $script:appOrigin
        Get-DemoFabricAppOrigin -HostingUrl 'http://insecure.example' | Should -Be ''
        $stage = Join-Path -Path $TestDrive -ChildPath 'stage'
        New-Item -ItemType Directory -Path (Join-Path -Path $stage -ChildPath 'rayfin') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $stage -ChildPath 'rayfin/.deployments.json') -Value (ConvertTo-Json -InputObject @{ active = 'demo'; deployments = @{ demo = @{ hostingUrl = $script:appOrigin.ToUpperInvariant() + '/' } } } -Depth 4)
        Get-DemoFabricAppOrigin -HostingUrl '' -StagePath $stage | Should -Be $script:appOrigin
        Get-DemoFabricAppOrigin -HostingUrl '' -StagePath (Join-Path -Path $TestDrive -ChildPath 'none') | Should -Be ''
    }
}

Describe 'Ask''s relay setup (Invoke-DemoAskRelaySetup)' {
    BeforeEach {
        Initialize-GuardTestContext
        Reset-FakeAzure
        Register-FakeAzure
    }

    AfterEach {
        Initialize-GuardTestContext -Clear
    }

    It 'deploys the relay on the configured image with the app''s origin, the public client ID, and the demo''s own tags only' {
        $config = New-AskConfig -Ask @{ image = $script:image; githubClientId = 'Ov23liExampleClientId' }
        $out = Invoke-DemoAskRelaySetup -Config $config -AllowedOrigin ($script:appOrigin + '/') -Confirm:$false
        $out.Results[0].checkId | Should -Be 'ASK.RELAY'
        $out.Results[0].status | Should -Be 'Pass'
        $out.Endpoint | Should -Be $script:endpoint
        $out.AllowedOrigins | Should -Be $script:appOrigin
        $out.ClientIdSource | Should -Be 'config'
        $script:deployments.Count | Should -Be 1
        $script:deployments[0].Text | Should -BeLike '*--template-file*infra*ask*ask-relay.bicep*'
        $parameters = $script:deployments[0].Parameters['parameters']
        $parameters['image']['value'] | Should -Be $script:image
        $parameters['allowedOrigins']['value'] | Should -Be $script:appOrigin
        $parameters['githubClientId']['value'] | Should -Be 'Ov23liExampleClientId'
        $parameters['appName']['value'] | Should -Be 'ca-dbhub-demo-ask'
        $parameters['tags']['value']['component'] | Should -Be 'ask-relay'
        $parameters['tags']['value'].Contains('unrelated') | Should -BeFalse
        $script:deployments[0].Raw | Should -Not -Match '(?i)secret|password|gh[opusr]_'
    }

    It 'keeps the origin the relay already serves on an upgrade without a stage, and registers Microsoft.App first when it isn''t' {
        $script:relayExists = $true
        $script:relayOrigins = $script:appOrigin
        $script:providerState = 'NotRegistered'
        $out = Invoke-DemoAskRelaySetup -Config (New-AskConfig -Ask @{ image = $script:image }) -Confirm:$false
        $script:azCalls | Where-Object { $_ -like 'provider register*Microsoft.App*--wait*' } | Should -Not -BeNullOrEmpty
        $script:deployments[0].Parameters['parameters']['allowedOrigins']['value'] | Should -Be $script:appOrigin
        $out.Results[0].status | Should -Be 'Pass'
    }

    It 'reports a deployment that fails as a Warning with the actual reason, never a Fail, and keeps the relay it had' {
        $script:templateFails = $true
        $script:relayExists = $true
        $out = Invoke-DemoAskRelaySetup -Config (New-AskConfig -Ask @{ image = $script:image }) -Confirm:$false
        $out.Results[0].status | Should -Be 'Warning'
        $out.Results[0].message | Should -BeLike '*RequestDisallowedByPolicy*'
        $out.Results[0].remediation | Should -BeLike '*configure-fabric-app.ps1*'
        $out.Endpoint | Should -Be $script:endpoint
    }

    It 'deploys nothing without an image (a Warning) or with ask.enabled false (Not selected)' {
        $versionsPath = Join-Path -Path $repoRoot -ChildPath 'config/versions.json'
        $pinned = (Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json -AsHashtable)['askRelay']['image']
        if (-not $pinned) {
            $none = Invoke-DemoAskRelaySetup -Config (New-AskConfig) -Confirm:$false
            $none.Results[0].status | Should -Be 'Warning'
            $none.Results[0].message | Should -BeLike '*no relay image is pinned yet*'
        }
        $off = Invoke-DemoAskRelaySetup -Config (New-AskConfig -Ask @{ enabled = $false; image = $script:image }) -Confirm:$false
        $off.Results[0].status | Should -Be 'Not selected'
        $off.Endpoint | Should -Be ''
        $script:deployments.Count | Should -Be 0
    }
}

Describe 'Ask''s relay checks and the tenant setting' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
    }

    It 'passes when the relay answers and allows exactly the app''s origin, with GitHub sign-in on' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true,"version":"abc123","signIn":"device","sessions":0}'; Headers = @{ 'Access-Control-Allow-Origin' = @($script:appOrigin) } }
        }
        $results = Test-DemoAskRelay -Endpoint $script:endpoint -Origin $script:appOrigin -ClientIdSource 'pinned'
        ($results | Where-Object checkId -EQ 'ASK.RELAY.HEALTH').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'ASK.SIGNIN').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 1 -ParameterFilter { $Headers['Origin'] -eq $script:appOrigin -and $Uri -eq ($script:endpoint + '/healthz') }
    }

    It 'waits while the relay''s earlier revision still answers for another origin, then passes on the new one (live, 2026-11-19)' {
        $script:answers = 0
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $script:answers++
            $allowed = if ($script:answers -lt 3) { 'http://localhost:5173' } else { $script:appOrigin }
            [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true,"version":"abc123","signIn":"device","sessions":0}'; Headers = @{ 'Access-Control-Allow-Origin' = @($allowed) } }
        }
        $results = Test-DemoAskRelay -Endpoint $script:endpoint -Origin $script:appOrigin
        ($results | Where-Object checkId -EQ 'ASK.RELAY.HEALTH').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 3 -Exactly
    }

    It 'warns when the relay allows another origin, when sign-in is off, and when it doesn''t answer' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true,"version":"abc123","signIn":"off"}'; Headers = @{ 'Access-Control-Allow-Origin' = @('https://elsewhere.example') } }
        }
        $results = Test-DemoAskRelay -Endpoint $script:endpoint -Origin $script:appOrigin
        ($results | Where-Object checkId -EQ 'ASK.RELAY.HEALTH').status | Should -Be 'Warning'
        ($results | Where-Object checkId -EQ 'ASK.SIGNIN').status | Should -Be 'Warning'
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { throw 'The operation has timed out.' }
        $silent = @(Test-DemoAskRelay -Endpoint $script:endpoint -Origin $script:appOrigin -TimeoutSeconds 10)
        $silent.Count | Should -Be 1
        $silent[0].status | Should -Be 'Warning'
        $silent[0].message | Should -BeLike '*didn''t answer*'
    }

    It 'reads the strict-CSP tenant setting: off passes, on warns with the steps, unreadable is Not selected' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoHubFabricAccess -MockWith { $token = [System.Security.SecureString]::new(); foreach ($character in 'not-a-real-token'.ToCharArray()) { $token.AppendChar($character) }; [pscustomobject]@{ Token = $token; Error = '' } }
        foreach ($case in @(@{ Enabled = $false; Expected = 'Pass' }, @{ Enabled = $true; Expected = 'Warning' })) {
            $enabled = $case.Enabled
            Mock -ModuleName DbHubDemo -CommandName Read-DemoHubFabricList -MockWith { [pscustomobject]@{ Succeeded = $true; StatusCode = 200; Items = @([pscustomobject]@{ settingName = 'EnforceStrictCspForStaticHostedFabricApps'; title = 'Enforce a strict content security policy for static-hosted Fabric Apps (preview)'; enabled = $enabled }); Error = '' } }.GetNewClosure()
            (Test-DemoAskCspSetting -Config (New-AskConfig)).status | Should -Be $case.Expected
        }
        Mock -ModuleName DbHubDemo -CommandName Read-DemoHubFabricList -MockWith { [pscustomobject]@{ Succeeded = $false; StatusCode = 403; Items = @(); Error = 'Forbidden' } }
        $unread = Test-DemoAskCspSetting -Config (New-AskConfig)
        $unread.status | Should -Be 'Not selected'
        $unread.message | Should -BeLike '*needs a Fabric administrator*'
    }
}

Describe 'How deploy.ps1 shows Ask' {
    It 'shows Ask''s own row and a Warning line that never blocks DONE' {
        InModuleScope DbHubDemo {
            $warning = New-DemoResult -CheckId 'ASK.RELAY' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message 'Ask''s chat relay couldn''t be deployed (12 s): policy.' -Remediation 'Fix the cause, then run ./scripts/configure-fabric-app.ps1 again.'
            $record = ConvertTo-DemoInsightsAppRecord -Record $warning
            $record.message | Should -Not -BeLike 'Insights app:*'
            Test-DemoNonBlockingResult -Result $record | Should -BeTrue
            $summary = Get-DemoAskSummary -Result @($record)
            $summary.State | Should -Be 'Action needed'
            $summary.Warning | Should -BeTrue
            $items = @(Get-DemoNonBlockingItem -Result @($record))
            $line = Format-DemoNonBlockingLine -Item ($items | Where-Object { $_['name'] -like '*Ask*' } | Select-Object -First 1)
            $line | Should -BeLike 'Warning (doesn''t block DONE): the Copilot chat in the Insights app (Ask).*policy*configure-fabric-app.ps1*'
            (Get-DemoInsightsAppSummary -Result @($record, (New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'deployed'))).State | Should -Be 'Done'
        }
    }

    It 'keeps it a Warning on the status page''s Needs attention box, not Failed (live, 2026-11-19)' {
        $path = Join-Path -Path $TestDrive -ChildPath 'progress-ask.json'
        $problems = @(InModuleScope DbHubDemo -Parameters @{ Path = $path } {
            $model = New-DemoProgressModel -Catalog (Get-DemoProgressCatalog -InstallMode 'JumpstartImage') -Environment 'demo' -ResourceGroup 'rg-dbhub-demo' -NowUnix (Get-DemoUnixTime)
            Initialize-DemoProgress -Path $Path -Model $model -Confirm:$false
            $warning = New-DemoResult -CheckId 'ASK.RELAY.HEALTH' -Area 'fabric' -Target 'subscription' -Status 'Warning' -Message 'Ask''s chat relay answers, but doesn''t allow the Insights app''s origin yet.' -Remediation 'Run ./scripts/configure-fabric-app.ps1 again.'
            Set-DemoProgressValue -Path $Path -Section 'nonBlocking' -Value @(Get-DemoNonBlockingItem -Result @($warning))
            Set-DemoProgressValue -Path $Path -Section 'run' -Value ([ordered]@{ state = 'Done'; endedAt = (Get-DemoUnixTime); reason = ''; next = ''; nextCommand = ''; exitCode = 0; activity = '' })
            $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            @($saved['nonBlocking'])[0]['state'] | Should -Be 'Warning'
            Get-DemoProgressProblem -Model $saved
        })
        $problems.Count | Should -Be 1
        $problems[0] | Should -BeLike 'Warning (doesn''t block DONE): the Copilot chat in the Insights app (Ask).*'
    }

    It 'shows Done when the relay is up and Skipped when Ask is off' {
        InModuleScope DbHubDemo {
            $up = @(
                (New-DemoResult -CheckId 'ASK.RELAY' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'deployed')
                (New-DemoResult -CheckId 'ASK.RELAY.HEALTH' -Area 'fabric' -Target 'subscription' -Status 'Pass' -Message 'answers')
                (New-DemoResult -CheckId 'ASK.CSP' -Area 'fabric' -Target 'tenant' -Status 'Not selected' -Message 'not read')
            )
            (Get-DemoAskSummary -Result $up).State | Should -Be 'Done'
            (Get-DemoAskSummary -Result @(New-DemoResult -CheckId 'ASK.RELAY' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message 'off')).State | Should -Be 'Skipped'
            Get-DemoAskSummary -Result @() | Should -BeNullOrEmpty
            @(Get-DemoProgressStepId -Track 'Fabric' -Step 'Fabric') | Should -Contain 'Fabric.Ask'
        }
    }
}

Describe 'Ask''s pins stay in step' {
    BeforeAll {
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $askRelay = $versions['askRelay']
    }

    It 'builds the relay from the pinned MCR images and SDK, and pins the image by digest when it''s set' {
        $dockerfile = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'ask-relay/Dockerfile') -Raw
        $dockerfile | Should -BeLikeExactly ('*ARG BUILD_IMAGE={0}*' -f $askRelay['buildImage'])
        $dockerfile | Should -BeLikeExactly ('*ARG RUNTIME_IMAGE={0}*' -f $askRelay['runtimeImage'])
        $askRelay['runtimeImage'] | Should -Match '^mcr\.microsoft\.com/azurelinux/distroless/nodejs:.+-nonroot-.+@sha256:[0-9a-f]{64}$'
        $dockerfile | Should -Match '(?m)^USER nonroot$'
        $package = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'ask-relay/package.json') -Raw | ConvertFrom-Json -AsHashtable
        $package['dependencies']['@microsoft/copilot-sdk'] | Should -Be $askRelay['copilotSdk']
        $askRelay['githubClientId'] | Should -Match '^[A-Za-z0-9.]{16,40}$'
        if ($askRelay['image']) {
            $askRelay['image'] | Should -BeLikeExactly ($askRelay['imageRepository'] + '@sha256:*')
            $askRelay['image'] | Should -Match '@sha256:[0-9a-f]{64}$'
        }
    }

    It 'publishes the image only from this repository''s workflow, with least privilege and pinned actions' {
        $workflow = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath '.github/workflows/ask-relay-image.yml') -Raw
        # A read-only token at the top; only the job that publishes may write packages (ADR 0022).
        $workflow | Should -Match '(?m)^permissions:\s*\n  contents: read\s*\n\s*\n'
        $workflow | Should -Match '(?m)^    permissions:\s*\n      contents: read\s*\n      packages: write\s*$'
        $workflow | Should -Match "(?m)^    if: github\.event_name == 'workflow_dispatch' \|\| github\.event\.repository\.visibility == 'public' \|\| vars\.ASK_RELAY_IMAGE_ENABLED == 'true'$"
        foreach ($uses in [regex]::Matches($workflow, 'uses:\s*(\S+)')) {
            $uses.Groups[1].Value | Should -Match '@[0-9a-f]{40}$'
        }
        $workflow | Should -Match 'persist-credentials: false'
        $workflow | Should -Not -Match 'pull_request_target'
    }
}
