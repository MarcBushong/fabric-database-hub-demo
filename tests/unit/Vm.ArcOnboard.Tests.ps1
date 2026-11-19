BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the host bootstrap's functions (and imports DbHubDemo.Vm), then the onboarding
    # script's functions, without running either.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1')
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoArcOnboard.ps1')

    # A token-shaped value built at run time, so no scanner sees a token in the repository.
    $script:fakeToken = ('ey' + 'J') + ('d' * 24) + '.' + ('ey' + 'J') + ('e' * 24) + '.' + ('f' * 32)

    function New-TestStateRoot {
        $root = Join-Path -Path $TestDrive -ChildPath ('state-' + [guid]::NewGuid().ToString('N'))
        Initialize-DemoVmContext -Root $root -Role 'ArcHost' -BundleRoot $repoRoot | Out-Null
        return $root
    }

    function New-TestInput {
        @{
            SubscriptionId       = '11111111-2222-3333-4444-555555555555'
            TenantId             = '66666666-7777-8888-9999-000000000000'
            ResourceGroup        = 'rg-dbhub-demo'
            Location             = 'westus3'
            MachineName          = 'arcsql01'
            Tags                 = 'solution=fabric-database-hub-demo,owner=demo-owner'
            CorrelationId        = '22222222-3333-4444-5555-666666666666'
            Cloud                = 'AzureCloud'
            AgentUrl             = 'https://aka.ms/AzureConnectedMachineAgent'
            AgentSha256          = ''
            AgentSignerPattern   = 'O=Microsoft Corporation'
            AgentMaxCacheDays    = '7'
            DisconnectLocalFirst = 'false'
            TokenSource          = 'Parameter'
            Mode                 = 'Nested'
        }
    }

    function New-TestGuestState {
        param([string] $Status = '', [string] $Name = '', [bool] $Installed = $false, [bool] $Imds = $false, [bool] $Reachable = $true)
        $agent = [ordered]@{ status = $Status; resourceName = $Name; resourceGroup = ''; subscriptionId = ''; vmId = ''; agentVersion = '1.60.0'; keys = @('status', 'resourceName') }
        if ($Name) {
            $agent.resourceGroup = 'rg-dbhub-demo'
            $agent.subscriptionId = '11111111-2222-3333-4444-555555555555'
        }
        [ordered]@{ guestReachable = $Reachable; imdsReachable = $Imds; wireServerReachable = $false; dnsResolves = $true; agentInstalled = $Installed; agent = $agent; msftArcTest = '' }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'Connected Machine agent package' {
    BeforeEach {
        Mock -CommandName Write-DemoVmLog -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }
        $script:package = Join-Path -Path $TestDrive -ChildPath ('agent-' + [guid]::NewGuid().ToString('N') + '.msi')
        Set-Content -LiteralPath $script:package -Value 'not really an installer'
    }

    It 'accepts an unpinned package only with a valid signature from the expected signer' {
        Mock -CommandName Get-DemoArcAuthenticodeSignature -MockWith { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } } }
        $valid = Test-DemoArcAgentPackage -Path $script:package -SignerPattern 'O=Microsoft Corporation'
        $valid.Valid | Should -BeTrue
        $valid.Method | Should -Be 'Authenticode'

        Mock -CommandName Get-DemoArcAuthenticodeSignature -MockWith { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        (Test-DemoArcAgentPackage -Path $script:package -SignerPattern 'O=Microsoft Corporation').Valid | Should -BeFalse

        Mock -CommandName Get-DemoArcAuthenticodeSignature -MockWith { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Contoso, O=Contoso Ltd' } } }
        (Test-DemoArcAgentPackage -Path $script:package -SignerPattern 'O=Microsoft Corporation').Valid | Should -BeFalse

        Mock -CommandName Get-DemoArcAuthenticodeSignature -MockWith { [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = 'O=Microsoft Corporation' } } }
        (Test-DemoArcAgentPackage -Path $script:package -SignerPattern 'O=Microsoft Corporation').Valid | Should -BeFalse
    }

    It 'checks a pinned SHA-256 instead of the signature' {
        Mock -CommandName Get-DemoArcAuthenticodeSignature -MockWith { throw 'should not run' }
        $hash = (Get-FileHash -LiteralPath $script:package -Algorithm SHA256).Hash
        (Test-DemoArcAgentPackage -Path $script:package -Sha256 $hash -SignerPattern 'O=Microsoft Corporation').Valid | Should -BeTrue
        (Test-DemoArcAgentPackage -Path $script:package -Sha256 ('0' * 64) -SignerPattern 'O=Microsoft Corporation').Valid | Should -BeFalse
        Should -Invoke -CommandName Get-DemoArcAuthenticodeSignature -Times 0 -Exactly
    }

    It 'deletes a downloaded package that fails verification (fail closed)' {
        $folder = Join-Path -Path $TestDrive -ChildPath ('cache-' + [guid]::NewGuid().ToString('N'))
        Mock -CommandName Invoke-DemoArcWebDownload -MockWith { Set-Content -LiteralPath $Path -Value 'tampered' }
        Mock -CommandName Get-DemoArcAuthenticodeSignature -MockWith { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        { Get-DemoArcAgentPackage -Url 'https://aka.ms/AzureConnectedMachineAgent' -SignerPattern 'O=Microsoft Corporation' -Folder $folder } | Should -Throw '*fail closed*'
        Test-Path -LiteralPath (Join-Path -Path $folder -ChildPath 'AzureConnectedMachineAgent.msi') | Should -BeFalse
    }

    It 'reuses a fresh verified package and downloads a stale one again' {
        $folder = Join-Path -Path $TestDrive -ChildPath ('cache-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $cached = Join-Path -Path $folder -ChildPath 'AzureConnectedMachineAgent.msi'
        Set-Content -LiteralPath $cached -Value 'cached'
        Mock -CommandName Invoke-DemoArcWebDownload -MockWith { Set-Content -LiteralPath $Path -Value 'fresh' }
        Mock -CommandName Get-DemoArcAuthenticodeSignature -MockWith { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'O=Microsoft Corporation' } } }

        (Get-DemoArcAgentPackage -Url 'https://aka.ms/AzureConnectedMachineAgent' -SignerPattern 'O=Microsoft Corporation' -Folder $folder).Path | Should -Be $cached
        Should -Invoke -CommandName Invoke-DemoArcWebDownload -Times 0 -Exactly

        (Get-Item -LiteralPath $cached).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-10)
        Get-DemoArcAgentPackage -Url 'https://aka.ms/AzureConnectedMachineAgent' -SignerPattern 'O=Microsoft Corporation' -Folder $folder -MaxCacheDays 7 | Out-Null
        Should -Invoke -CommandName Invoke-DemoArcWebDownload -Times 1 -Exactly
        (Get-Content -LiteralPath $cached -Raw).Trim() | Should -Be 'fresh'
    }
}

Describe 'Agent state from azcmagent show -j' {
    It 'reads the documented status and the resource keys when present' {
        $agent = ConvertFrom-DemoArcAgentJson -Text "noise`n{""status"":""Connected"",""lastHeartbeat"":""2026-10-20T00:00:00Z"",""resourceName"":""arcsql01"",""resourceGroup"":""rg-dbhub-demo"",""agentVersion"":""1.60.0""}"
        $agent.status | Should -Be 'Connected'
        $agent.resourceName | Should -Be 'arcsql01'
        $agent.resourceGroup | Should -Be 'rg-dbhub-demo'
        $agent.keys | Should -Contain 'lastHeartbeat'
        (ConvertFrom-DemoArcAgentJson -Text 'not json').status | Should -Be ''
        (ConvertFrom-DemoArcAgentJson -Text '').keys.Count | Should -Be 0
    }

    It 'matches only the expected machine' {
        Test-DemoArcAgentMatch -Agent @{ status = 'Connected'; resourceName = 'arcsql01'; resourceGroup = 'rg-dbhub-demo' } -MachineName 'arcsql01' -ResourceGroup 'rg-dbhub-demo' | Should -BeTrue
        Test-DemoArcAgentMatch -Agent @{ status = 'Disconnected'; resourceName = 'arcsql01' } -MachineName 'arcsql01' | Should -BeFalse
        Test-DemoArcAgentMatch -Agent @{ status = 'Connected'; resourceName = 'other' } -MachineName 'arcsql01' | Should -BeFalse
        Test-DemoArcAgentMatch -Agent @{ status = 'Connected'; resourceName = 'arcsql01'; resourceGroup = 'rg-other' } -MachineName 'arcsql01' -ResourceGroup 'rg-dbhub-demo' | Should -BeFalse
    }

    It 'passes the token to the connect block only as its first argument, and to the agent in a config file' {
        $block = Get-DemoArcBlock -Name 'Connect'
        $block.Ast.ParamBlock.Parameters[0].Name.VariablePath.UserPath | Should -Be 'Token'
        $text = $block.ToString()
        $text | Should -Match ([regex]::Escape("@('connect', '--config', `$file) + `$common"))
        $text | Should -Match ([regex]::Escape("@{ 'access-token' = [string]`$Token }"))
        # The command line gets the token only in the fallback, when the agent rejected the file or waited for a sign-in.
        @([regex]::Matches($text, "'--access-token'")).Count | Should -Be 1
        $text | Should -Match ([regex]::Escape("`$run.TimedOut -or [string]`$run.Output -match '(?i)AZCM00(12|16|19|27|41)|browser|device code|devicelogin'"))
        $text | Should -Not -Match 'MSFT_ARC_TEST.*Machine'
    }

    It 'overwrites and deletes the token file whatever the agent does, and never returns the token' {
        $block = Get-DemoArcBlock -Name 'Connect'
        $folder = Join-Path -Path $TestDrive -ChildPath ('arc-connect-' + [guid]::NewGuid().ToString('N'))
        # The current PowerShell stands in for the agent: it rejects 'connect' as a script name and exits non-zero.
        $agent = (Get-Process -Id $PID).Path
        $outcome = & $block $script:fakeToken '11111111-2222-3333-4444-555555555555' '66666666-7777-8888-9999-000000000000' 'rg-dbhub-demo' 'westus3' 'arcsql01' 'AzureCloud' '22222222-3333-4444-5555-666666666666' 'solution=demo' $false $false 120 $agent $folder
        $outcome.ExitCode | Should -Not -Be 0
        $outcome.TokenPassedBy | Should -Be 'ConfigFile'
        $outcome.TokenFileLeft | Should -BeFalse
        @(Get-ChildItem -LiteralPath $folder -Force).Count | Should -Be 0
        ($outcome | ConvertTo-Json) | Should -Not -Match ([regex]::Escape($script:fakeToken))
    }

    It 'recognizes an authorization refusal from Azure Resource Manager' {
        Test-DemoArcAuthorizationError -Text 'AZCM0042: Failed to create the resource: (AuthorizationFailed) The client does not have authorization to perform action' | Should -BeTrue
        Test-DemoArcAuthorizationError -Text 'StatusCode=403 Forbidden' | Should -BeTrue
        Test-DemoArcAuthorizationError -Text 'AZCM0044: A resource with the same name already exists' | Should -BeFalse
        Test-DemoArcAuthorizationError -Text '' | Should -BeFalse
    }
}

Describe 'Invoke-DemoArcOnboardAction' {
    BeforeEach {
        $script:root = New-TestStateRoot
        $script:blocks = [System.Collections.Generic.List[object]]::new()
        $script:connected = $false
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Get-DemoGuestCredential -MockWith {
            $secure = [System.Security.SecureString]::new()
            foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
            [System.Management.Automation.PSCredential]::new('Administrator', $secure)
        }
        Mock -CommandName Get-DemoArcGuestVmId -MockWith { '77777777-8888-9999-0000-111111111111' }
        Mock -CommandName Get-DemoArcGuestState -MockWith { if ($script:connected) { New-TestGuestState -Status 'Connected' -Name 'arcsql01' -Installed $true } else { New-TestGuestState } }
        Mock -CommandName Get-DemoArcAgentPackage -MockWith { [pscustomobject]@{ Path = 'C:\ProgramData\DbHubDemo\downloads\arc-agent\AzureConnectedMachineAgent.msi'; Verification = [pscustomobject]@{ Sha256 = ('a' * 64); Method = 'Authenticode' } } }
        Mock -CommandName Copy-DemoGuestFile -MockWith { }
        Mock -CommandName Invoke-DemoArcBootstrapTask -MockWith { $true }
        Mock -CommandName Invoke-DemoArcGuestBlock -MockWith {
            $Block = $PesterBoundParameters['Block']
            $script:blocks.Add([pscustomobject]@{ Text = $Block.ToString(); Arguments = @($PesterBoundParameters['ArgumentList']) })
            if ($Block.ToString() -match 'azcmagent|--access-token') {
                $script:connected = $true
                return [pscustomobject]@{ ExitCode = 0; Output = 'Connected machine to Azure' }
            }
            return [pscustomobject]@{ ExitCode = 0; Skipped = $false }
        }
    }

    It 'installs the agent in the guest, connects with the token as an argument, and writes the marker' {
        $result = Invoke-DemoArcOnboardAction -ActionName 'Onboard' -InputValue (New-TestInput) -Token $script:fakeToken -StateRoot $script:root -BundleRoot $repoRoot
        $result.succeeded | Should -BeTrue
        $result.outcome | Should -Be 'Onboarded'
        Should -Invoke -CommandName Copy-DemoGuestFile -Times 1 -Exactly -ParameterFilter { $DestinationPath -eq 'C:\DbHubDemo\media\AzureConnectedMachineAgent.msi' -and $ExpectedSha256 -eq ('a' * 64) }

        $connect = @($script:blocks | Where-Object { $_.Text -match '--access-token' })
        $connect.Count | Should -Be 1
        $connect[0].Arguments[0] | Should -Be $script:fakeToken
        $connect[0].Text | Should -Not -Match ([regex]::Escape($script:fakeToken))
        $connect[0].Arguments[5] | Should -Be 'arcsql01'
        $connect[0].Arguments[10] | Should -BeFalse

        $markerText = Get-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'arc-onboarded.json') -Raw
        $marker = $markerText | ConvertFrom-Json
        $marker.schemaVersion | Should -Be 1
        $marker.machineName | Should -Be 'arcsql01'
        $marker.status | Should -Be 'Connected'
        $marker.resourceId | Should -Be '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.HybridCompute/machines/arcsql01'
        $marker.guestVmId | Should -Be '77777777-8888-9999-0000-111111111111'
        [datetime]::Parse($marker.connectedUtc).Year | Should -BeGreaterThan 2000
        $markerText | Should -Not -Match ([regex]::Escape($script:fakeToken))
        ($result | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($script:fakeToken))
        $logs = Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'logs') -File | Get-Content -Raw
        ($logs -join ' ') | Should -Not -Match ([regex]::Escape($script:fakeToken))
        Test-DemoArcOnboarded -MarkerPath (Join-Path -Path $script:root -ChildPath 'arc-onboarded.json') -MachineName 'arcsql01' -GuestVmId '77777777-8888-9999-0000-111111111111' | Should -BeTrue
    }

    It 'skips connect and writes the marker again when the agent is already Connected' {
        $script:connected = $true
        $result = Invoke-DemoArcOnboardAction -ActionName 'Onboard' -InputValue (New-TestInput) -Token $script:fakeToken -StateRoot $script:root -BundleRoot $repoRoot
        $result.outcome | Should -Be 'AlreadyConnected'
        $script:blocks.Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path -Path $script:root -ChildPath 'arc-onboarded.json') | Should -BeTrue
    }

    It 'stops before changing anything when the guest can reach IMDS' {
        Mock -CommandName Get-DemoArcGuestState -MockWith { New-TestGuestState -Imds $true }
        { Invoke-DemoArcOnboardAction -ActionName 'Onboard' -InputValue (New-TestInput) -Token $script:fakeToken -StateRoot $script:root -BundleRoot $repoRoot } | Should -Throw '*fail closed*'
        $script:blocks.Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path -Path $script:root -ChildPath 'arc-onboarded.json') | Should -BeFalse
    }

    It 'refuses to write the marker for an agent that is not Connected' {
        { Invoke-DemoArcOnboardAction -ActionName 'WriteMarker' -InputValue (New-TestInput) -StateRoot $script:root -BundleRoot $repoRoot } | Should -Throw '*marker was not written*'
        Test-Path -LiteralPath (Join-Path -Path $script:root -ChildPath 'arc-onboarded.json') | Should -BeFalse
    }

    It 'retries a connect that Azure refuses for authorization with the host identity, after bounded waits' {
        $script:refusals = 2
        Mock -CommandName Invoke-DemoArcGuestBlock -MockWith {
            $Block = $PesterBoundParameters['Block']
            $script:blocks.Add([pscustomobject]@{ Text = $Block.ToString(); Arguments = @($PesterBoundParameters['ArgumentList']) })
            if ($Block.ToString() -match '--config') {
                if ($script:refusals -gt 0) {
                    $script:refusals--
                    return [pscustomobject]@{ ExitCode = 42; Output = 'AZCM0042: (AuthorizationFailed) does not have authorization'; TokenPassedBy = 'ConfigFile'; TokenFileLeft = $false }
                }
                $script:connected = $true
                return [pscustomobject]@{ ExitCode = 0; Output = 'Connected machine to Azure'; TokenPassedBy = 'ConfigFile'; TokenFileLeft = $false }
            }
            return [pscustomobject]@{ ExitCode = 0; Skipped = $false }
        }
        $values = New-TestInput
        $values['TokenSource'] = 'HostIdentity'
        $values['DisconnectLocalFirst'] = 'true'
        $result = Invoke-DemoArcOnboardAction -ActionName 'Onboard' -InputValue $values -Token $script:fakeToken -StateRoot $script:root -BundleRoot $repoRoot -AuthorizationRetrySeconds @(5, 7, 9)
        $result.succeeded | Should -BeTrue
        $result.connectAttempts | Should -Be 3
        $result.authorizationWaitSeconds | Should -Be 12
        $result.tokenPassedBy | Should -Be 'ConfigFile'
        Should -Invoke -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        Should -Invoke -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
        $connects = @($script:blocks | Where-Object { $_.Text -match '--config' })
        @($connects | ForEach-Object { $_.Arguments[9] }) | Should -Be @($true, $false, $false) -Because 'only the first attempt resets the agent'
    }

    It 'stops retrying after the last wait, and never retries the caller''s token' {
        Mock -CommandName Invoke-DemoArcGuestBlock -MockWith {
            $Block = $PesterBoundParameters['Block']
            $script:blocks.Add([pscustomobject]@{ Text = $Block.ToString(); Arguments = @($PesterBoundParameters['ArgumentList']) })
            if ($Block.ToString() -match '--config') {
                return [pscustomobject]@{ ExitCode = 42; Output = 'AZCM0042: (AuthorizationFailed)'; TokenPassedBy = 'ConfigFile'; TokenFileLeft = $false }
            }
            return [pscustomobject]@{ ExitCode = 0; Skipped = $false }
        }
        $values = New-TestInput
        $values['TokenSource'] = 'HostIdentity'
        { Invoke-DemoArcOnboardAction -ActionName 'Onboard' -InputValue $values -Token $script:fakeToken -StateRoot $script:root -BundleRoot $repoRoot -AuthorizationRetrySeconds @(1, 1) } | Should -Throw '*azcmagent connect failed*'
        @($script:blocks | Where-Object { $_.Text -match '--config' }).Count | Should -Be 3
        $script:blocks.Clear()
        { Invoke-DemoArcOnboardAction -ActionName 'Onboard' -InputValue (New-TestInput) -Token $script:fakeToken -StateRoot $script:root -BundleRoot $repoRoot -AuthorizationRetrySeconds @(1, 1) } | Should -Throw '*azcmagent connect failed*'
        @($script:blocks | Where-Object { $_.Text -match '--config' }).Count | Should -Be 1
    }

    It 'rejects invalid inputs without echoing the token' {
        $values = New-TestInput
        $values['SubscriptionId'] = 'not-a-guid'
        { Invoke-DemoArcOnboardAction -ActionName 'Onboard' -InputValue $values -Token $script:fakeToken -StateRoot $script:root -BundleRoot $repoRoot } | Should -Throw '*SubscriptionId parameter*'
    }

    It 'probes read-only and reports the agent''s keys' {
        $result = Invoke-DemoArcOnboardAction -ActionName 'Probe' -InputValue @{ Mode = 'Nested'; MachineName = 'arcsql01' } -StateRoot $script:root -BundleRoot $repoRoot
        $result.outcome | Should -Be 'Probed'
        $result.guestReachable | Should -BeTrue
        $result.agentKeys | Should -Contain 'status'
        $script:blocks.Count | Should -Be 0
        Should -Invoke -CommandName Get-DemoArcAgentPackage -Times 0 -Exactly
    }
}

Describe 'Arc marker after a guest rebuild' {
    BeforeAll {
        Mock -CommandName Write-DemoVmLog -MockWith { }
        function Write-TestMarker([hashtable] $Marker) {
            $path = Join-Path -Path $TestDrive -ChildPath ('marker-' + [guid]::NewGuid().ToString('N') + '.json')
            Set-Content -LiteralPath $path -Value ($Marker | ConvertTo-Json)
            return $path
        }
    }

    It 'ignores a marker written for an earlier build of the guest' {
        $path = Write-TestMarker @{ schemaVersion = 1; machineName = 'arcsql01'; status = 'Connected'; resourceId = 'x'; connectedUtc = '2026-10-20T00:00:00Z'; guestVmId = 'old-vm-id' }
        Test-DemoArcOnboarded -MarkerPath $path -MachineName 'arcsql01' -GuestVmId 'old-vm-id' | Should -BeTrue
        Test-DemoArcOnboarded -MarkerPath $path -MachineName 'arcsql01' -GuestVmId 'new-vm-id' | Should -BeFalse
        Test-DemoArcOnboarded -MarkerPath $path -MachineName 'arcsql01' | Should -BeTrue
    }

    It 'still accepts a marker without guestVmId (the Phase 6 contract)' {
        $path = Write-TestMarker @{ schemaVersion = 1; machineName = 'arcsql01'; status = 'Connected'; resourceId = 'x'; connectedUtc = '2026-10-20T00:00:00Z' }
        Test-DemoArcOnboarded -MarkerPath $path -MachineName 'arcsql01' -GuestVmId 'new-vm-id' | Should -BeTrue
    }

    It 'compares the guest''s VM ID in both Arc waits of the host plan' {
        $root = New-TestStateRoot
        $settings = [ordered]@{ role = 'ArcHost'; t2SqlInstallMode = 'PaygWizard'; seedScale = 1; guest = [ordered]@{ name = 'arcsql01'; vcpus = 2; memoryGiB = 8; vhdxGB = 64 } }
        $plan = Get-DemoHostStepPlan -Context (Get-DemoHostContext -StateRoot $root -BundleRoot $repoRoot -Settings $settings)
        foreach ($name in 'ArcOnboarding', 'ArcOnboardingBeforeWizard') {
            ($plan | Where-Object { $_.Name -eq $name }).Test.ToString() | Should -Match 'GuestVmId \(Get-DemoHostGuestVmId'
        }
    }

    It 'reads no VM ID, without throwing, when Hyper-V or the guest is missing' {
        Get-DemoHostGuestVmId -Name 'dbhub-no-such-guest' | Should -Be ''
    }
}

Describe 'A broken PowerShell Direct channel into the guest (issue #65)' {
    BeforeAll {
        # Stand-ins with the parameters the code uses, so Pester can mock these Hyper-V cmdlets where the module isn't installed.
        foreach ($stub in @(
                @{ Name = 'Get-VM'; Body = 'param([string] $Name)' }
                @{ Name = 'Stop-VM'; Body = 'param([string] $Name, [switch] $Force, [switch] $AsJob, [switch] $TurnOff)' }
                @{ Name = 'Start-VM'; Body = 'param([string] $Name)' }
            )) {
            if (-not (Get-Command -Name $stub.Name -ErrorAction SilentlyContinue)) {
                New-Item -Path ('function:global:' + $stub.Name) -Value ([scriptblock]::Create('[CmdletBinding()] ' + $stub.Body)) | Out-Null
            }
        }
        $script:brokenText = 'The background process reported an error with the following message: "The Hyper-V socket target process has ended.".'
        function New-TestCredential {
            $secure = [System.Security.SecureString]::new()
            foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
            [System.Management.Automation.PSCredential]::new('Administrator', $secure)
        }
    }

    BeforeEach {
        $script:root = New-TestStateRoot
        $script:vm = @{ State = 'Running'; Heartbeat = 'OkApplicationsHealthy'; Uptime = [timespan]::FromMinutes(42) }
        $script:broken = $true
        Mock -CommandName Get-VM -MockWith { [pscustomobject]@{ Name = 'arcsql01'; State = $script:vm.State; Heartbeat = $script:vm.Heartbeat; Uptime = $script:vm.Uptime; VMId = '77777777-8888-9999-0000-111111111111' } }
        Mock -CommandName Stop-VM -MockWith { $script:vm.State = 'Off' }
        # A restart clears the leftover server, so the channel works again.
        Mock -CommandName Start-VM -MockWith { $script:vm.State = 'Running'; $script:vm.Uptime = [timespan]::FromSeconds(40); $script:broken = $false }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Get-DemoGuestComputerName -MockWith { if ($script:broken) { throw $script:brokenText } 'ARCSQL01' }
        Mock -CommandName Wait-DemoGuestOnline -MockWith { -not $script:broken }
        Mock -CommandName Enter-DemoGuestRecoveryLock -MockWith { [pscustomobject]@{ Lock = 'test' } }
        Mock -CommandName Exit-DemoGuestRecoveryLock -MockWith { }
        $script:credential = New-TestCredential
    }

    It 'tells a broken channel from a guest that''s off, starting, or refusing the credential' {
        Test-DemoGuestChannelBroken -Text $script:brokenText | Should -BeTrue
        Test-DemoGuestChannelBroken -Text 'Connecting to the guest failed. (2100,PSSessionStateBroken)' | Should -BeTrue
        foreach ($other in 'The credential is invalid.', 'The virtual machine arcsql01 is not in running state.', 'An error has occurred which Windows PowerShell cannot handle. A remote session might have ended.', '') {
            Test-DemoGuestChannelBroken -Text $other | Should -BeFalse
        }
        $probe = Test-DemoGuestChannel -Name 'arcsql01' -Credential $script:credential -Attempts 3
        $probe.Broken | Should -BeTrue
        Should -Invoke -CommandName Get-DemoGuestComputerName -Times 3 -Exactly
        $script:vm.Heartbeat = 'LostCommunication'
        (Test-DemoGuestChannel -Name 'arcsql01' -Credential $script:credential).Broken | Should -BeFalse -Because 'a guest without a healthy heartbeat isn''t a broken channel'
    }

    It 'decides <Expected> for <Case>' -ForEach @(
        @{ Case = 'a broken channel in a guest that runs'; State = 'Running'; Heartbeat = 'OkApplicationsHealthy'; Uptime = 42; Broken = $true; Key = 'deploy-aaaaaaaaaaaa'; Capture = $false; Expected = 'Restart' }
        @{ Case = 'another run''s key'; State = 'Running'; Heartbeat = 'OkApplicationsUnknown'; Uptime = 42; Broken = $true; Key = 'deploy-bbbbbbbbbbbb'; Capture = $false; Expected = 'Restart' }
        @{ Case = 'the run that restarted it already'; State = 'Running'; Heartbeat = 'OkApplicationsHealthy'; Uptime = 42; Broken = $true; Key = 'deploy-cccccccccccc'; Capture = $false; Expected = 'Exhausted' }
        @{ Case = 'a guest that started 2 minutes ago'; State = 'Running'; Heartbeat = 'OkApplicationsHealthy'; Uptime = 2; Broken = $true; Key = 'deploy-aaaaaaaaaaaa'; Capture = $false; Expected = 'Wait' }
        @{ Case = 'a guest without a healthy heartbeat'; State = 'Running'; Heartbeat = 'LostCommunication'; Uptime = 42; Broken = $true; Key = 'deploy-aaaaaaaaaaaa'; Capture = $false; Expected = 'None' }
        @{ Case = 'a guest that''s off'; State = 'Off'; Heartbeat = ''; Uptime = 0; Broken = $false; Key = 'deploy-aaaaaaaaaaaa'; Capture = $false; Expected = 'None' }
        @{ Case = 'another failure'; State = 'Running'; Heartbeat = 'OkApplicationsHealthy'; Uptime = 42; Broken = $false; Key = 'deploy-aaaaaaaaaaaa'; Capture = $false; Expected = 'None' }
        @{ Case = 'a golden capture in progress'; State = 'Running'; Heartbeat = 'OkApplicationsHealthy'; Uptime = 42; Broken = $true; Key = 'deploy-aaaaaaaaaaaa'; Capture = $true; Expected = 'None' }
    ) {
        $record = [ordered]@{ schemaVersion = 1; restarts = @([ordered]@{ key = 'deploy-cccccccccccc'; startedUtc = '2026-11-18T18:50:00.0000000Z' }) }
        $decision = Get-DemoGuestRecoveryDecision -State $State -Heartbeat $Heartbeat -UptimeMinutes $Uptime -Broken $Broken -Record $record -Key $Key -CaptureInProgress $Capture
        $decision.Action | Should -Be $Expected
        $decision.Reason | Should -Not -BeNullOrEmpty
    }

    It 'restarts the guest once for a run, through a clean shutdown, records it, and doesn''t restart it again for that run' {
        $first = Invoke-DemoGuestRecovery -Name 'arcsql01' -Credential $script:credential -Key 'deploy-aaaaaaaaaaaa' -By 'Arc onboarding' -StateRoot $script:root -Confirm:$false
        $first.Action | Should -Be 'Restart'
        $first.Restarted | Should -BeTrue
        $first.Recovered | Should -BeTrue
        $first.StoppedBy | Should -Be 'Shutdown'
        $first.Reason | Should -Match 'Hyper-V socket target process has ended'
        Should -Invoke -CommandName Stop-VM -Times 1 -Exactly -ParameterFilter { $Force -and $AsJob -and -not $TurnOff }
        Should -Invoke -CommandName Start-VM -Times 1 -Exactly
        $record = Get-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'guest-recovery.json') -Raw | ConvertFrom-Json
        @($record.restarts).Count | Should -Be 1
        $record.restarts[0].key | Should -Be 'deploy-aaaaaaaaaaaa'
        $record.restarts[0].recovered | Should -BeTrue
        $record.restarts[0].endedUtc | Should -Not -BeNullOrEmpty

        # It breaks again later in the same run: no second restart, and the caller says why.
        $script:broken = $true
        $script:vm.Uptime = [timespan]::FromMinutes(30)
        $again = Invoke-DemoGuestRecovery -Name 'arcsql01' -Credential $script:credential -Key 'deploy-aaaaaaaaaaaa' -By 'the T2 relay' -StateRoot $script:root -Confirm:$false
        $again.Action | Should -Be 'Exhausted'
        $again.Recovered | Should -BeFalse
        $again.Message | Should -Match 'already restarted the guest once'
        Should -Invoke -CommandName Stop-VM -Times 1 -Exactly
    }

    It 'restarts nothing when another restart already cleared it, or while the guest starts' {
        $script:broken = $false
        (Invoke-DemoGuestRecovery -Name 'arcsql01' -Credential $script:credential -Key 'deploy-aaaaaaaaaaaa' -By 'Arc onboarding' -StateRoot $script:root -Confirm:$false).Action | Should -Be 'Healed'
        $script:broken = $true
        $script:vm.Uptime = [timespan]::FromMinutes(2)
        $wait = Invoke-DemoGuestRecovery -Name 'arcsql01' -Credential $script:credential -Key 'deploy-aaaaaaaaaaaa' -By 'Arc onboarding' -StateRoot $script:root -Confirm:$false
        $wait.Action | Should -Be 'Wait'
        Should -Invoke -CommandName Wait-DemoGuestOnline -Times 1 -Exactly
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path -Path $script:root -ChildPath 'guest-recovery.json') | Should -BeFalse
    }

    It 'runs WriteMarker again after the restart that clears a broken channel (live, 2026-11-18)' {
        Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
        $script:actions = 0
        Mock -CommandName Invoke-DemoArcOnboardAction -MockWith {
            $script:actions++
            if ($script:broken) {
                throw ('{0}' -f $script:brokenText)
            }
            [ordered]@{ action = 'WriteMarker'; succeeded = $true; outcome = 'AlreadyConnected'; message = 'arcsql01 was already Connected; the marker was written again.' }
        }
        $result = Invoke-DemoArcOnboardWithRecovery -ActionName 'WriteMarker' -InputValue (New-TestInput) -StateRoot $script:root -BundleRoot $repoRoot -RecoveryKey 'deploy-aaaaaaaaaaaa'
        $result.succeeded | Should -BeTrue
        $script:actions | Should -Be 2
        $result.guestRecovery.restarted | Should -BeTrue
        $result.guestRecovery.recovered | Should -BeTrue
        $result.guestRecovery.key | Should -Be 'deploy-aaaaaaaaaaaa'
        $result.guestRecovery.reason | Should -Match 'Hyper-V socket target process has ended'
    }

    It 'runs WriteMarker again, without a restart, after a break that''s over when it''s checked (the user''s demo, 2026-11-18: about 2 seconds)' {
        Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
        $script:broken = $false
        $script:actions = 0
        Mock -CommandName Invoke-DemoArcOnboardAction -MockWith {
            $script:actions++
            if ($script:actions -eq 1) {
                throw $script:brokenText
            }
            [ordered]@{ action = 'WriteMarker'; succeeded = $true; outcome = 'AlreadyConnected'; message = 'arcsql01 was already Connected; the marker was written again.' }
        }
        $result = Invoke-DemoArcOnboardWithRecovery -ActionName 'WriteMarker' -InputValue (New-TestInput) -StateRoot $script:root -BundleRoot $repoRoot -RecoveryKey 'deploy-aaaaaaaaaaaa'
        $result.succeeded | Should -BeTrue
        $script:actions | Should -Be 2
        $result.guestRecovery.action | Should -Be 'Healed'
        $result.guestRecovery.restarted | Should -BeFalse
        $result.guestRecovery.atUtc | Should -Not -BeNullOrEmpty
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path -Path $script:root -ChildPath 'guest-recovery.json') | Should -BeFalse
    }

    It 'gives a failure that isn''t a broken channel back as it was, without restarting anything' {
        Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
        $script:broken = $false
        Mock -CommandName Invoke-DemoArcOnboardAction -MockWith { throw 'The agent in arcsql01 is not Connected to arcsql01 (status Disconnected); the marker was not written.' }
        { Invoke-DemoArcOnboardWithRecovery -ActionName 'WriteMarker' -InputValue (New-TestInput) -StateRoot $script:root -BundleRoot $repoRoot } | Should -Throw '*marker was not written*'
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
    }

    It 'clears a broken channel for the host''s bootstrap once per generation, and never in a guest that isn''t onboarded yet' {
        $secret = Join-Path -Path $script:root -ChildPath 'protected\guest-administrator.bin'
        Set-Content -LiteralPath $secret -Value 'not-a-real-secret'
        Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
        Mock -CommandName Get-DemoHostGuestVmId -MockWith { '77777777-8888-9999-0000-111111111111' }
        $script:onboarded = $false
        Mock -CommandName Test-DemoArcOnboarded -MockWith { $script:onboarded }
        $context = @{ Root = $script:root; SecretPath = $secret; GuestName = 'arcsql01'; Guest = @{ AdministratorName = 'Administrator' }; Settings = @{ generation = '6a85c5d88e3a-20261118134518' }; ArcMarkerPath = (Join-Path -Path $script:root -ChildPath 'arc-onboarded.json') }
        Test-DemoHostGuestReachable -Context $context | Should -BeFalse -Because 'a guest that''s still being built is never restarted'
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
        $script:onboarded = $true
        Test-DemoHostGuestReachable -Context $context | Should -BeTrue
        Should -Invoke -CommandName Stop-VM -Times 1 -Exactly
        (Get-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'guest-recovery.json') -Raw | ConvertFrom-Json).restarts[0].key | Should -Be 'bootstrap-6a85c5d88e3a-20261118134518'
    }
}

Describe 'A restart of the guest that its process didn''t finish (review of #65)' {
    BeforeAll {
        foreach ($stub in @(
                @{ Name = 'Get-VM'; Body = 'param([string] $Name)' }
                @{ Name = 'Stop-VM'; Body = 'param([string] $Name, [switch] $Force, [switch] $AsJob, [switch] $TurnOff)' }
                @{ Name = 'Start-VM'; Body = 'param([string] $Name)' }
            )) {
            if (-not (Get-Command -Name $stub.Name -ErrorAction SilentlyContinue)) {
                New-Item -Path ('function:global:' + $stub.Name) -Value ([scriptblock]::Create('[CmdletBinding()] ' + $stub.Body)) | Out-Null
            }
        }
        $script:vmId = '77777777-8888-9999-0000-111111111111'
        function Set-TestUnfinishedRestart([string] $Root, [string] $VmId = $script:vmId, [string] $StartedUtc = '2026-11-18T18:50:00Z') {
            $record = [ordered]@{ schemaVersion = 1; restarts = @([ordered]@{ id = 'a1'; key = 'deploy-aaaaaaaaaaaa'; by = 'Arc onboarding'; reason = 'The Hyper-V socket target process has ended.'; vmId = $VmId; startedUtc = $StartedUtc; endedUtc = ''; seconds = 0; stoppedBy = ''; recovered = $false }) }
            Set-Content -LiteralPath (Join-Path -Path $Root -ChildPath 'guest-recovery.json') -Value ($record | ConvertTo-Json -Depth 4)
        }
        function Get-TestLastRestart([string] $Root) {
            @((Get-Content -LiteralPath (Join-Path -Path $Root -ChildPath 'guest-recovery.json') -Raw | ConvertFrom-Json).restarts)[-1]
        }
        $secure = [System.Security.SecureString]::new()
        foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
        $script:credential = [System.Management.Automation.PSCredential]::new('Administrator', $secure)
    }

    BeforeEach {
        $script:root = New-TestStateRoot
        # The process that restarted the guest ended after Stop-VM: the guest is off, and nothing answers.
        $script:vm = @{ State = 'Off'; Heartbeat = ''; Uptime = [timespan]::Zero }
        $script:answers = $false
        Mock -CommandName Get-VM -MockWith { [pscustomobject]@{ Name = 'arcsql01'; State = $script:vm.State; Heartbeat = $script:vm.Heartbeat; Uptime = $script:vm.Uptime; VMId = $script:vmId } }
        Mock -CommandName Stop-VM -MockWith { $script:vm.State = 'Off' }
        Mock -CommandName Start-VM -MockWith { $script:vm.State = 'Running'; $script:vm.Heartbeat = 'OkApplicationsHealthy'; $script:answers = $true }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Wait-DemoGuestOnline -MockWith { $script:answers }
        Mock -CommandName Get-DemoGuestComputerName -MockWith { if ($script:answers) { 'ARCSQL01' } else { throw 'The virtual machine arcsql01 is not in running state.' } }
        Mock -CommandName Enter-DemoGuestRecoveryLock -MockWith { [pscustomobject]@{ Lock = 'test' } }
        Mock -CommandName Exit-DemoGuestRecoveryLock -MockWith { }
    }

    It 'starts the guest it left off once, waits until it answers, and completes its entry' {
        Set-TestUnfinishedRestart -Root $script:root
        $done = Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false
        $done.Action | Should -Be 'Interrupted'
        $done.Restarted | Should -BeTrue
        $done.Recovered | Should -BeTrue
        $done.StoppedBy | Should -Be 'Interrupted'
        $done.AtUtc | Should -Not -BeNullOrEmpty
        Should -Invoke -CommandName Start-VM -Times 1 -Exactly
        $last = Get-TestLastRestart -Root $script:root
        $last.stoppedBy | Should -Be 'Interrupted'
        $last.recovered | Should -BeTrue
        $last.endedUtc | Should -Not -BeNullOrEmpty
        # Finished: nothing to do the next time.
        Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false | Should -BeNullOrEmpty
        Should -Invoke -CommandName Start-VM -Times 1 -Exactly
    }

    It 'never starts a guest that''s off for another reason: no unfinished entry, another guest, a golden capture, a copy not released, or the host''s own stop' {
        Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false | Should -BeNullOrEmpty
        Set-TestUnfinishedRestart -Root $script:root -VmId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false | Should -BeNullOrEmpty
        Set-TestUnfinishedRestart -Root $script:root
        New-Item -ItemType Directory -Path (Join-Path -Path $script:root -ChildPath 'golden') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture-in-progress.json') -Value '{"snapshotName":"snap-dbhub-t2golden-202611182200"}'
        Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false | Should -BeNullOrEmpty
        Remove-Item -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture-in-progress.json')
        Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture.json') -Value '{"snapshotName":"snap-dbhub-t2golden-202611182200","released":false}'
        Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false | Should -BeNullOrEmpty
        Remove-Item -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture.json')
        Close-DemoGuestRecoveryUnfinished -StateRoot $script:root -Confirm:$false
        (Get-TestLastRestart -Root $script:root).stoppedBy | Should -Be 'HostStop'
        Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false | Should -BeNullOrEmpty
        Should -Invoke -CommandName Start-VM -Times 0 -Exactly
    }

    It 'is finished by the host''s bootstrap, every run, with no deploy.ps1 running' {
        Set-TestUnfinishedRestart -Root $script:root
        $secret = Join-Path -Path $script:root -ChildPath 'protected\guest-administrator.bin'
        Set-Content -LiteralPath $secret -Value 'not-a-real-secret'
        Mock -CommandName Get-DemoGuestCredential -MockWith { $script:credential }
        Invoke-DemoHostGuestRecoveryRepair -Context @{ Root = $script:root; SecretPath = $secret; GuestName = 'arcsql01'; Guest = @{ AdministratorName = 'Administrator' } }
        Should -Invoke -CommandName Start-VM -Times 1 -Exactly
        (Get-TestLastRestart -Root $script:root).stoppedBy | Should -Be 'Interrupted'
    }

    It 'lets Arc onboarding''s probe start the guest again and probe once more (Ctrl+C during a restart, then a rerun)' {
        Set-TestUnfinishedRestart -Root $script:root
        Mock -CommandName Get-DemoGuestCredential -MockWith { $script:credential }
        Mock -CommandName Invoke-DemoArcOnboardAction -MockWith { [ordered]@{ action = 'Probe'; guestReachable = $script:answers } }
        $result = Invoke-DemoArcOnboardWithRecovery -ActionName 'Probe' -InputValue (New-TestInput) -StateRoot $script:root -BundleRoot $repoRoot -RecoveryKey 'deploy-bbbbbbbbbbbb'
        $result.guestReachable | Should -BeTrue
        $result.guestRecovery.action | Should -Be 'Interrupted'
        $result.guestRecovery.restarted | Should -BeTrue
        Should -Invoke -CommandName Start-VM -Times 1 -Exactly
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
    }

    It 'keeps the failure, or the Probe''s result, as it is on a host whose bundle has no recovery yet (an older bundle)' {
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'Complete-DemoGuestRecoveryInterrupted' } -MockWith { $null }
        Mock -CommandName Invoke-DemoArcOnboardAction -MockWith { [ordered]@{ action = 'Probe'; guestReachable = $false } }
        $probe = Invoke-DemoArcOnboardWithRecovery -ActionName 'Probe' -InputValue (New-TestInput) -StateRoot $script:root -BundleRoot $repoRoot
        $probe.guestReachable | Should -BeFalse
        $probe.Contains('guestRecovery') | Should -BeFalse
        Mock -CommandName Invoke-DemoArcOnboardAction -MockWith { throw 'DbHubDemo Arc WriteMarker failed: The background process reported an error with the following message: "The Hyper-V socket target process has ended.".' }
        { Invoke-DemoArcOnboardWithRecovery -ActionName 'WriteMarker' -InputValue (New-TestInput) -StateRoot $script:root -BundleRoot $repoRoot } | Should -Throw 'DbHubDemo Arc WriteMarker failed: *target process has ended*'
        Should -Invoke -CommandName Start-VM -Times 0 -Exactly
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
    }

    It 'waits for a guest that was still shutting down when its restart was cut short, then starts it (second review of #65)' {
        # Hyper-V says Running until the guest's operating system powers off: the same boot as when the entry was written.
        $script:vm.State = 'Running'
        $script:vm.Heartbeat = 'OkApplicationsHealthy'
        $script:vm.Uptime = [timespan]::FromHours(3)
        Set-TestUnfinishedRestart -Root $script:root -StartedUtc ([DateTime]::UtcNow.AddMinutes(-4).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $done = Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false
        $done.Recovered | Should -BeTrue
        Should -Invoke -CommandName Stop-VM -Times 1 -Exactly -ParameterFilter { $Force -and $AsJob -and -not $TurnOff }
        Should -Invoke -CommandName Start-VM -Times 1 -Exactly
        (Get-TestLastRestart -Root $script:root).stoppedBy | Should -Be 'Interrupted'
    }

    It 'only completes the entry of a guest that booted since, and never closes one while the guest stays off' {
        $script:vm.State = 'Running'
        $script:vm.Heartbeat = 'OkApplicationsHealthy'
        $script:vm.Uptime = [timespan]::FromMinutes(2)
        $script:answers = $true
        Set-TestUnfinishedRestart -Root $script:root -StartedUtc ([DateTime]::UtcNow.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        (Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false).Recovered | Should -BeTrue
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
        Should -Invoke -CommandName Start-VM -Times 0 -Exactly

        # A guest that doesn't come up: its entry stays open for the next run.
        $script:vm.State = 'Off'
        $script:answers = $false
        Mock -CommandName Start-VM -MockWith { }
        Set-TestUnfinishedRestart -Root $script:root
        (Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false).Recovered | Should -BeFalse
        (Get-TestLastRestart -Root $script:root).endedUtc | Should -BeNullOrEmpty
    }

    It 'never restarts a guest that still runs its old boot under a golden capture, and keeps its entry for later (review of the #65 follow-up)' {
        Mock -CommandName Get-DemoGuestHostVmId -MockWith { '' }
        $script:vm.State = 'Running'
        $script:vm.Heartbeat = 'OkApplicationsHealthy'
        $script:vm.Uptime = [timespan]::FromHours(3)
        Set-TestUnfinishedRestart -Root $script:root -StartedUtc ([DateTime]::UtcNow.AddMinutes(-4).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        New-Item -ItemType Directory -Path (Join-Path -Path $script:root -ChildPath 'golden') -Force | Out-Null
        # A marker that names no host counts as a capture in progress (fail closed).
        Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture-in-progress.json') -Value '{"snapshotName":"snap-dbhub-t2golden-202611190400"}'
        Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false | Should -BeNullOrEmpty
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
        Should -Invoke -CommandName Start-VM -Times 0 -Exactly
        (Get-TestLastRestart -Root $script:root).endedUtc | Should -BeNullOrEmpty
        # Once the capture is over, a run finishes it.
        Remove-Item -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture-in-progress.json')
        (Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false).Recovered | Should -BeTrue
        Should -Invoke -CommandName Stop-VM -Times 1 -Exactly
        Should -Invoke -CommandName Start-VM -Times 1 -Exactly
    }

    It 'takes a running guest whose uptime rounds to 0 as restarted, so it only completes its entry (review of the #65 follow-up)' {
        $script:vm.State = 'Running'
        $script:vm.Heartbeat = 'OkApplicationsHealthy'
        $script:vm.Uptime = [timespan]::FromSeconds(2)
        $script:answers = $true
        Set-TestUnfinishedRestart -Root $script:root -StartedUtc ([DateTime]::UtcNow.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        (Complete-DemoGuestRecoveryInterrupted -Name 'arcsql01' -Credential $script:credential -StateRoot $script:root -Confirm:$false).Recovered | Should -BeTrue
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
        Should -Invoke -CommandName Start-VM -Times 0 -Exactly
        (Get-TestLastRestart -Root $script:root).stoppedBy | Should -Be 'Interrupted'
        # Only a running guest: one that's off, or one without an uptime, can't tell.
        $since = [DateTime]::UtcNow.AddMinutes(-1)
        Test-DemoGuestRestartedSince -Vm ([pscustomobject]@{ State = 'Off'; Uptime = [timespan]::Zero }) -SinceUtc $since | Should -BeFalse
        Test-DemoGuestRestartedSince -Vm ([pscustomobject]@{ State = 'Running' }) -SinceUtc $since | Should -BeFalse
        Test-DemoGuestRestartedSince -Vm ([pscustomobject]@{ State = 'Running'; Uptime = [timespan]::FromHours(1) }) -SinceUtc $since | Should -BeFalse
    }
}

Describe 'A golden capture marker, read as Get-GoldenCaptureProgress reads it (second review of #65)' {
    BeforeEach {
        $script:root = New-TestStateRoot
        New-Item -ItemType Directory -Path (Join-Path -Path $script:root -ChildPath 'golden') -Force | Out-Null
        $script:hostVmId = 'aaaaaaaa-1111-2222-3333-444444444444'
        Mock -CommandName Get-DemoGuestHostVmId -MockWith { $script:hostVmId }
        function Set-TestMarker([string] $Source, [datetime] $StartedUtc) {
            $marker = [ordered]@{ schemaVersion = 1; snapshotName = 'snap-dbhub-t2golden-202611181200'; startedUtc = $StartedUtc.ToString("yyyy-MM-dd'T'HH':'mm':'ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture); sourceAzureVmId = $Source }
            Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture-in-progress.json') -Value ($marker | ConvertTo-Json)
        }
        $script:now = [datetime]::new(2026, 11, 18, 13, 0, 0, [System.DateTimeKind]::Utc)
    }

    It 'counts on the capture''s source only, for 6 hours, and fails closed when it can''t tell' {
        Test-DemoGuestCaptureInProgress -StateRoot $script:root -NowUtc $script:now | Should -BeFalse -Because 'there is no marker'
        # Every copy restored from the snapshot carries its source's marker: there it means nothing.
        Set-TestMarker -Source 'bbbbbbbb-1111-2222-3333-444444444444' -StartedUtc $script:now.AddMinutes(-30)
        Test-DemoGuestCaptureInProgress -StateRoot $script:root -NowUtc $script:now | Should -BeFalse -Because 'a restored copy'
        Set-TestMarker -Source $script:hostVmId -StartedUtc $script:now.AddMinutes(-30)
        Test-DemoGuestCaptureInProgress -StateRoot $script:root -NowUtc $script:now | Should -BeTrue -Because 'the capture''s source, during its capture'
        Set-TestMarker -Source $script:hostVmId -StartedUtc $script:now.AddHours(-7)
        Test-DemoGuestCaptureInProgress -StateRoot $script:root -NowUtc $script:now | Should -BeFalse -Because 'an interrupted capture''s marker stops counting after 6 hours'
        $script:hostVmId = ''
        Set-TestMarker -Source 'bbbbbbbb-1111-2222-3333-444444444444' -StartedUtc $script:now.AddMinutes(-30)
        Test-DemoGuestCaptureInProgress -StateRoot $script:root -NowUtc $script:now | Should -BeTrue -Because 'this host''s VM ID can''t be read'
        Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture-in-progress.json') -Value 'not json'
        Test-DemoGuestCaptureInProgress -StateRoot $script:root -NowUtc $script:now | Should -BeTrue -Because 'only Prepare writes it'
    }

    It 'lets the recovery restart a restored copy that carries its source''s marker' {
        Set-TestMarker -Source 'bbbbbbbb-1111-2222-3333-444444444444' -StartedUtc ([DateTime]::UtcNow.AddMinutes(-30))
        $secure = [System.Security.SecureString]::new()
        foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
        $credential = [System.Management.Automation.PSCredential]::new('Administrator', $secure)
        $script:vm = @{ State = 'Running'; Heartbeat = 'OkApplicationsHealthy'; Uptime = [timespan]::FromMinutes(42) }
        $script:broken = $true
        Mock -CommandName Get-VM -MockWith { [pscustomobject]@{ Name = 'arcsql01'; State = $script:vm.State; Heartbeat = $script:vm.Heartbeat; Uptime = $script:vm.Uptime; VMId = '77777777-8888-9999-0000-111111111111' } }
        Mock -CommandName Stop-VM -MockWith { $script:vm.State = 'Off' }
        Mock -CommandName Start-VM -MockWith { $script:vm.State = 'Running'; $script:vm.Uptime = [timespan]::FromSeconds(40); $script:broken = $false }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Get-DemoGuestComputerName -MockWith { if ($script:broken) { throw 'The Hyper-V socket target process has ended.' } 'ARCSQL01' }
        Mock -CommandName Wait-DemoGuestOnline -MockWith { -not $script:broken }
        Mock -CommandName Enter-DemoGuestRecoveryLock -MockWith { [pscustomobject]@{ Lock = 'test' } }
        Mock -CommandName Exit-DemoGuestRecoveryLock -MockWith { }
        $recovery = Invoke-DemoGuestRecovery -Name 'arcsql01' -Credential $credential -Key 'deploy-aaaaaaaaaaaa' -By 'Arc onboarding' -StateRoot $script:root -Confirm:$false
        $recovery.Action | Should -Be 'Restart'
        $recovery.Recovered | Should -BeTrue
    }
}
