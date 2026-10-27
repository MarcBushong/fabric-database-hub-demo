BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the host bootstrap's functions (and imports DbHubDemo.Vm) without running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1')

    function New-TestHostContext {
        param([string] $Mode, [string] $DataDiskTier = '')
        $root = Join-Path -Path $TestDrive -ChildPath ('host-' + [guid]::NewGuid().ToString('N'))
        Initialize-DemoVmContext -Root $root -Role 'ArcHost' -BundleRoot $repoRoot | Out-Null
        $settings = [ordered]@{
            role             = 'ArcHost'
            t2SqlInstallMode = $Mode
            seedScale        = 1
            guest            = [ordered]@{ name = 'arcsql01'; vcpus = 2; memoryGiB = 8; vhdxGB = 64 }
        }
        if ($DataDiskTier) {
            $settings['dataDiskTier'] = $DataDiskTier
        }
        Get-DemoHostContext -StateRoot $root -BundleRoot $repoRoot -Settings $settings
    }

    function Set-ReadyHostMock {
        # Everything up to the SQL Server install is already in place.
        Mock -CommandName Test-DemoNestedVirtualization -MockWith { $true }
        Mock -CommandName Test-DemoHostFeature -MockWith { $true }
        Mock -CommandName Test-DemoHostNatNetwork -MockWith { $true }
        Mock -CommandName Test-DemoHostDnsForwarder -MockWith { $true }
        Mock -CommandName Get-DemoVmDataVolume -MockWith { [pscustomobject]@{ DriveLetter = 'F'; FileSystemLabel = 'DbHubData' } }
        Mock -CommandName Test-DemoHostMedia -MockWith { $true }
        Mock -CommandName Test-DemoGuestVhdx -MockWith { $true }
        Mock -CommandName Test-DemoGuestVm -MockWith { $true }
        Mock -CommandName Test-DemoHostGuestReachable -MockWith { $true }
        Mock -CommandName Wait-DemoHostGuest -MockWith { $true }
        Mock -CommandName Get-DemoGuestCredential -MockWith {
            $secure = [System.Security.SecureString]::new()
            foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
            [System.Management.Automation.PSCredential]::new('Administrator', $secure)
        }
        Mock -CommandName Test-DemoGuestHardening -MockWith { $true }
        Mock -CommandName Test-DemoHostGuestSqlMedia -MockWith { $true }
        Mock -CommandName Test-DemoHostGuestWebView2 -MockWith { $true }
        Mock -CommandName Test-DemoHostGuestSignInClean -MockWith { $true }
        Mock -CommandName Get-DemoHostGuestIsoPath -MockWith { 'C:\DbHubDemo\media\SQLServer2022-x64-ENU.iso' }
        Mock -CommandName Mount-DemoGuestIso -MockWith { 'E' }
        Mock -CommandName Test-DemoArcOnboarded -MockWith { $script:arcConnected }
        Mock -CommandName Test-DemoHostSqlEdition -MockWith { $script:sqlReady }
        Mock -CommandName Get-DemoGuestSqlInstance -MockWith { [pscustomobject]@{ ServiceExists = $false; Running = $false; Edition = ''; ProductVersion = ''; IsSysAdmin = $false; Error = '' } }
        Mock -CommandName Install-DemoGuestSql -MockWith { $script:sqlReady = $true; 0 }
        Mock -CommandName Test-DemoHostDatabase -MockWith { if ($Seeded) { $script:seeded } else { $script:configured } }
        Mock -CommandName Initialize-DemoHostDatabase -MockWith { $script:configured = $true }
        Mock -CommandName Invoke-DemoHostSeed -MockWith { $script:seeded = $true }
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRestart -MockWith { }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'T2 host step plan' {
    It 'follows the ADR 0003 order' {
        $plan = Get-DemoHostStepPlan -Context (New-TestHostContext -Mode 'PaygWizard')
        $plan.Name | Should -Be @(
            'NestedVirtualization', 'HyperVRole', 'DnsServerRole', 'NatNetwork', 'DnsForwarder', 'DataDisk', 'GuestOsMedia',
            'GuestVhdx', 'GuestVm', 'GuestOnline', 'GuestHardening', 'SqlMedia', 'GuestWebView2', 'SqlUnattendedInstall', 'ArcOnboarding',
            'ArcOnboardingBeforeWizard', 'SqlSetupWizard', 'GuestSignInCleanup', 'ConfigureSql', 'SeedDatabase', 'WorkloadRunner')
    }

    It 'reads guest sizing from settings.json and the network from vm/dsc/host.psd1' {
        $context = New-TestHostContext -Mode 'Developer'
        $context.VCpu | Should -Be 2
        $context.MemoryGiB | Should -Be 8
        $context.Host.HostAddress | Should -Be '192.168.200.1'
        $context.Guest.BlockedAddresses | Should -Contain '169.254.169.254'
        $context.Guest.BlockedAddresses | Should -Contain '168.63.129.16'
        $context.StatusQuery | Should -Match 'query_store_state'
    }

    It 'fails without retry and points to the evaluation-only fallback when Hyper-V reports no virtualization support' {
        $context = New-TestHostContext -Mode 'PaygWizard'
        Mock -CommandName Test-DemoNestedVirtualization -MockWith { $false }
        Mock -CommandName Install-DemoHostFeature -MockWith { throw 'A prerequisite check for the Hyper-V feature failed. Hyper-V cannot be installed: The processor does not have required virtualization capabilities.' }
        Mock -CommandName Get-DemoHostInstanceInfo -MockWith { [ordered]@{ vmSize = 'Standard_B2s'; zone = ''; secureBootEnabled = 'true' } }
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRestart -MockWith { }
        Invoke-DemoVmStateMachine -Step (Get-DemoHostStepPlan -Context $context) -Generation 'g1' | Should -Be 'Failed'
        $state = Get-DemoVmState
        $state['steps']['NestedVirtualization']['status'] | Should -Be 'Failed'
        $state['steps']['NestedVirtualization']['lastError'] | Should -Match 'EvaluationOnlyAzureVm'
        $state['steps']['NestedVirtualization']['lastError'] | Should -Match 'virtualization capabilities'
        $state['steps'].Contains('HyperVRole') | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRestart -Times 0
    }

    It 'installs Hyper-V to decide when the processor flags are hidden, then resumes after the restart' {
        $context = New-TestHostContext -Mode 'PaygWizard'
        $script:hyperVInstalled = $false
        Mock -CommandName Test-DemoNestedVirtualization -MockWith { $script:hyperVInstalled }
        Mock -CommandName Install-DemoHostFeature -MockWith { $script:hyperVInstalled = $true; New-DemoVmStepResult -Outcome 'RebootRequired' -Message 'Hyper-V needs a restart.' }
        Mock -CommandName Test-DemoHostFeature -MockWith { $Name -eq 'Hyper-V' -and $script:hyperVInstalled }
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRestart -MockWith { }
        $plan = Get-DemoHostStepPlan -Context $context

        Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'RebootPending'
        Should -Invoke -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRestart -Times 1 -Exactly

        # After the restart: nested virtualization and the Hyper-V role pass their checks; the DNS role is next.
        Mock -CommandName Install-DemoHostFeature -MockWith { New-DemoVmStepResult -Outcome 'RebootRequired' -Message 'DNS needs a restart.' }
        Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'RebootPending'
        $state = Get-DemoVmState
        $state['steps']['NestedVirtualization']['status'] | Should -Be 'Succeeded'
        $state['steps']['HyperVRole']['status'] | Should -Be 'Succeeded'
        $state['steps']['DnsServerRole']['status'] | Should -Be 'RebootPending'
    }

    Context 'PaygWizard' {
        It 'waits for Arc first, then asks for the setup wizard, then configures and seeds' {
            $context = New-TestHostContext -Mode 'PaygWizard'
            Set-ReadyHostMock
            $script:arcConnected = $false
            $script:sqlReady = $false
            $script:configured = $false
            $script:seeded = $false
            $plan = Get-DemoHostStepPlan -Context $context

            Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'WaitingForArcOnboarding'
            $state = Get-DemoVmState
            $state['steps']['SqlUnattendedInstall']['status'] | Should -Be 'NotSelected'
            $state['steps']['ArcOnboarding']['status'] | Should -Be 'NotSelected'
            $state['steps']['ArcOnboardingBeforeWizard']['status'] | Should -Be 'Waiting'
            $state['steps'].Contains('SqlSetupWizard') | Should -BeFalse

            $script:arcConnected = $true
            Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'ManualActionRequired'
            $health = Get-Content -LiteralPath (Join-Path -Path $context.Root -ChildPath 'health.json') -Raw | ConvertFrom-Json
            $health.status | Should -Be 'Manual action required'
            ($health.instructions -join ' ') | Should -Match 'pay-as-you-go'
            ($health.instructions -join ' ') | Should -Match 'E:\\setup.exe'
            ($health.instructions -join ' ') | Should -Match 'Copy-GuestCredential.ps1'
            Should -Invoke -CommandName Install-DemoGuestSql -Times 0

            # The operator finished the wizard: Standard is detected and the run continues on its own.
            $script:sqlReady = $true
            Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'Ready'
            $state = Get-DemoVmState
            $state['steps']['ConfigureSql']['status'] | Should -Be 'Succeeded'
            $state['steps']['SeedDatabase']['status'] | Should -Be 'Succeeded'
            $state['steps']['WorkloadRunner']['status'] | Should -Be 'NotSelected'
        }
    }

    Context 'ProductKey' {
        It 'waits for the protected product key, installs with it, then waits for Arc' {
            $context = New-TestHostContext -Mode 'ProductKey'
            Set-ReadyHostMock
            $script:arcConnected = $false
            $script:sqlReady = $false
            $script:configured = $false
            $script:seeded = $false
            $script:key = $null
            Mock -CommandName Get-DemoProtectedSqlProductKey -MockWith { $script:key }
            $plan = Get-DemoHostStepPlan -Context $context

            Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'WaitingForProductKey'
            Should -Invoke -CommandName Install-DemoGuestSql -Times 0

            $script:key = [System.Security.SecureString]::new()
            foreach ($character in 'fake-key-for-test'.ToCharArray()) { $script:key.AppendChar($character) }
            Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'WaitingForArcOnboarding'
            Should -Invoke -CommandName Install-DemoGuestSql -Times 1 -Exactly -ParameterFilter { $null -ne $ProductKey }
            (Get-DemoVmState)['steps']['ArcOnboarding']['status'] | Should -Be 'Waiting'

            $script:arcConnected = $true
            Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'Ready'
            $state = Get-DemoVmState
            $state['steps']['ArcOnboardingBeforeWizard']['status'] | Should -Be 'NotSelected'
            $state['steps']['SqlSetupWizard']['status'] | Should -Be 'NotSelected'
            Should -Invoke -CommandName Install-DemoGuestSql -Times 1 -Exactly
        }
    }

    Context 'Developer' {
        It 'installs from the Developer media without a product key, then waits for Arc' {
            $context = New-TestHostContext -Mode 'Developer'
            Set-ReadyHostMock
            $script:arcConnected = $false
            $script:sqlReady = $false
            $script:configured = $false
            $script:seeded = $false
            Mock -CommandName Get-DemoProtectedSqlProductKey -MockWith { throw 'Developer mode must not read a product key.' }
            $plan = Get-DemoHostStepPlan -Context $context

            Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'WaitingForArcOnboarding'
            Should -Invoke -CommandName Install-DemoGuestSql -Times 1 -Exactly -ParameterFilter { $null -eq $ProductKey }
            Get-DemoHostSqlMediaName -Context $context | Should -Be 'sqlServer2022Developer'
        }
    }
}

Describe 'T2 host storage without a data disk' {
    BeforeAll {
        # Sizes from config/versions.json, as the bundle manifest carries them.
        $script:mediaPins = @{
            windowsServer2022Eval  = @{ url = 'https://download.example.invalid/server.iso'; sha256 = ('a' * 64); fileName = 'SERVER_EVAL_x64FRE_en-us.iso'; sizeBytes = 5044094976 }
            sqlServer2022          = @{ url = 'https://download.example.invalid/sql.iso'; sha256 = ('b' * 64); fileName = 'SQLServer2022-x64-ENU.iso'; sizeBytes = 1163051008 }
            sqlServer2022Developer = @{ url = 'https://download.example.invalid/dev.iso'; sha256 = ('c' * 64); fileName = 'SQLServer2022-x64-ENU-Dev.iso'; sizeBytes = 1163053056 }
        }
    }

    BeforeEach {
        $script:osDrive = Join-Path -Path $TestDrive -ChildPath ('os-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:osDrive -Force | Out-Null
        Mock -CommandName Get-DemoHostSystemDrive -MockWith { $script:osDrive }
        Mock -CommandName Get-DemoVmMediaPin -MockWith { $script:mediaPins[$Name] }
        Mock -CommandName Get-DemoVmDataVolume -MockWith { throw 'There is no data disk to look for.' }
        Mock -CommandName Initialize-DemoVmDataDisk -MockWith { throw 'There is no data disk to format.' }
    }

    It 'puts the media and the guest VHDX under DbHubDemo on the OS disk' {
        # The VM scripts run on Windows; separators are normalized so the test also runs on Linux CI.
        $context = New-TestHostContext -Mode 'PaygWizard' -DataDiskTier 'None'
        (Get-DemoHostDataPath -Context $context -Kind 'Media').Replace('/', '\') | Should -Be ('{0}\DbHubDemo\media' -f $script:osDrive).Replace('/', '\')
        (Get-DemoHostVhdxPath -Context $context).Replace('/', '\') | Should -Be ('{0}\DbHubDemo\vms\arcsql01\arcsql01.vhdx' -f $script:osDrive).Replace('/', '\')
        (Get-DemoHostMediaFile -Context $context -MediaName 'sqlServer2022').Path.Replace('/', '\') | Should -Be ('{0}\DbHubDemo\media\SQLServer2022-x64-ENU.iso' -f $script:osDrive).Replace('/', '\')
        Should -Invoke -CommandName Get-DemoVmDataVolume -Times 0
    }

    It 'needs the VHDX maximum, the media for the install mode, and a 10 GB margin' {
        $need = Get-DemoHostOsDiskRequirement -Context (New-TestHostContext -Mode 'Developer' -DataDiskTier 'None')
        $need.VhdxBytes | Should -Be (64 * 1GB)
        $need.MediaBytes | Should -Be (5044094976 + 1163053056)
        $need.MarginBytes | Should -Be (10 * 1GB)
        $need.TotalBytes | Should -Be ($need.VhdxBytes + $need.MediaBytes + $need.MarginBytes)
    }

    It 'checks the free space, then creates the folders on the OS disk' {
        $context = New-TestHostContext -Mode 'PaygWizard' -DataDiskTier 'None'
        Mock -CommandName Get-DemoHostDriveFreeSpace -MockWith { 100GB }
        Test-DemoHostStorage -Context $context | Should -BeFalse

        Initialize-DemoHostStorage -Context $context | Should -BeNullOrEmpty

        Test-DemoHostStorage -Context $context | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $script:osDrive -ChildPath 'DbHubDemo\vms') | Should -BeTrue
        Should -Invoke -CommandName Get-DemoHostDriveFreeSpace -Times 1 -Exactly -ParameterFilter { $Drive -eq $script:osDrive }
        Should -Invoke -CommandName Initialize-DemoVmDataDisk -Times 0
    }

    It 'fails the DataDisk step with a clear message when the OS disk is too small, and creates nothing' {
        $context = New-TestHostContext -Mode 'PaygWizard' -DataDiskTier 'None'
        Set-ReadyHostMock
        Mock -CommandName Get-DemoVmDataVolume -MockWith { throw 'There is no data disk to look for.' }
        Mock -CommandName Get-DemoHostDriveFreeSpace -MockWith { 60GB }

        Invoke-DemoVmStateMachine -Step (Get-DemoHostStepPlan -Context $context) -Generation 'g1' | Should -Be 'Failed'

        $step = (Get-DemoVmState)['steps']['DataDisk']
        $step['status'] | Should -Be 'Failed'
        $step['lastError'] | Should -Match 'Not enough free space on .+: 60\.0 GB free, 79\.8 GB needed \(VHDX up to 64 GB, media 5\.8 GB, and a 10 GB margin\)'
        $step['lastError'] | Should -Match 'dataDiskSku to E10'
        Test-Path -LiteralPath (Join-Path -Path $script:osDrive -ChildPath 'DbHubDemo') | Should -BeFalse
        (Get-DemoVmState)['steps'].Contains('GuestOsMedia') | Should -BeFalse
    }

    It 'still formats the data disk at LUN 0 when the profile has one' {
        $context = New-TestHostContext -Mode 'PaygWizard' -DataDiskTier 'E10'
        Mock -CommandName Initialize-DemoVmDataDisk -MockWith { [pscustomobject]@{ DriveLetter = 'F' } }
        Mock -CommandName Get-DemoHostDriveFreeSpace -MockWith { throw 'The OS disk is not checked with a data disk.' }
        Initialize-DemoHostStorage -Context $context | Should -BeNullOrEmpty
        Should -Invoke -CommandName Initialize-DemoVmDataDisk -Times 1 -Exactly -ParameterFilter { $Lun -eq 0 -and $Label -eq 'DbHubData' }
        Should -Invoke -CommandName Get-DemoHostDriveFreeSpace -Times 0
    }
}

Describe 'Host helpers' {
    It 'reads the Arc marker contract that Phase 7 writes' {
        $marker = Join-Path -Path $TestDrive -ChildPath 'arc-onboarded.json'
        Test-DemoArcOnboarded -MarkerPath $marker -MachineName 'arcsql01' | Should -BeFalse
        '{"schemaVersion":1,"machineName":"arcsql01","status":"Connected","resourceId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dbhub-demo/providers/Microsoft.HybridCompute/machines/arcsql01","connectedUtc":"2026-10-19T00:00:00Z"}' |
            Set-Content -LiteralPath $marker
        Test-DemoArcOnboarded -MarkerPath $marker -MachineName 'arcsql01' | Should -BeTrue
        Test-DemoArcOnboarded -MarkerPath $marker -MachineName 'other' | Should -BeFalse
    }

    It 'fills the unattend template in memory, escaped, with no token left' {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in 'Fake<&>Value1'.ToCharArray()) { $secure.AppendChar($character) }
        $guestName = 'arcsql01'
        $xml = Format-DemoUnattendXml -TemplatePath (Join-Path -Path $repoRoot -ChildPath 'vm/hyperv-guest/unattend.template.xml') -ComputerName $guestName -TimeZone 'UTC' -AdministratorPassword $secure
        $document = [xml]$xml
        $document.unattend.settings[0].component.ComputerName | Should -Be $guestName
        $xml | Should -Match 'Fake&lt;&amp;&gt;Value1'
        $xml | Should -Not -Match '\{\{[A-Z_]+\}\}'
    }

    It 'keeps the unattend template free of secrets' {
        $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/hyperv-guest/unattend.template.xml') -Raw
        $template | Should -Match '\{\{ADMINISTRATOR_SECRET\}\}'
        ([xml]$template.Replace('{{', '').Replace('}}', '')).unattend | Should -Not -BeNullOrEmpty
    }

    It 'passes bcdboot /offline when the host''s bcdboot lists it, because the guest image is offline' {
        # Live finding (2026-10-20): a patched host's bcdboot picked bootex boot files the evaluation image doesn't
        # have and failed with exit code 3; /offline succeeded.
        Mock -CommandName Invoke-DemoVmNativeCommand -ParameterFilter { $ArgumentList -contains '/?' } -MockWith {
            [pscustomobject]@{ ExitCode = 1; Output = @('  /bootex    Use the bootex binaries for servicing if necessary conditions are met.', '  /offline   Forces boot file servicing to be handled in an offline manner. Boot') }
        }
        Get-DemoBcdbootArgument -BcdbootPath 'bcdboot.exe' -WindowsLetter 'F' -SystemLetter 'E' | Should -Be @('F:\Windows', '/s', 'E:', '/f', 'UEFI', '/offline')
    }

    It 'leaves /offline out for a bcdboot that does not have it' {
        Mock -CommandName Invoke-DemoVmNativeCommand -ParameterFilter { $ArgumentList -contains '/?' } -MockWith {
            [pscustomobject]@{ ExitCode = 1; Output = @('  /c         Specifies that any existing objects described by the template', '  /addlast   Specifies that the windows boot manager firmware entry') }
        }
        Get-DemoBcdbootArgument -BcdbootPath 'bcdboot.exe' -WindowsLetter 'F' -SystemLetter 'E' | Should -Be @('F:\Windows', '/s', 'E:', '/f', 'UEFI')
    }

    It 'calls bcdboot with Get-DemoBcdbootArgument in the guest VHDX build' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/hyperv-guest/GuestVhdx.ps1') -Raw
        $text | Should -Match 'Invoke-DemoVmNativeCommand -FilePath \$bcdboot -ArgumentList \(Get-DemoBcdbootArgument '
    }
}

Describe 'GuestWebView2 step (PaygWizard)' {
    # Live finding (2026-10-21): the setup wizard's "Use Azure Login" signs in through WebView2, which Windows
    # Server 2022 lacks; the Evergreen bootstrapper downloads over HTTP, which the guest's NSG blocks.

    It 'is selected only in PaygWizard mode' {
        foreach ($case in @(@{ Mode = 'PaygWizard'; Selected = $true }, @{ Mode = 'ProductKey'; Selected = $false }, @{ Mode = 'Developer'; Selected = $false })) {
            $step = Get-DemoHostStepPlan -Context (New-TestHostContext -Mode $case.Mode) | Where-Object { $_.Name -eq 'GuestWebView2' }
            [bool](& $step.When $step) | Should -Be $case.Selected -Because $case.Mode
        }
    }

    It 'installs WebView2 in the guest before waiting for Arc, then skips it once it''s there' {
        $context = New-TestHostContext -Mode 'PaygWizard'
        Set-ReadyHostMock
        $script:arcConnected = $false
        $script:sqlReady = $false
        $script:webView2 = $false
        Mock -CommandName Test-DemoHostGuestWebView2 -MockWith { $script:webView2 }
        Mock -CommandName Install-DemoHostGuestWebView2 -MockWith { $script:webView2 = $true }
        $plan = Get-DemoHostStepPlan -Context $context

        Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'WaitingForArcOnboarding'
        Should -Invoke -CommandName Install-DemoHostGuestWebView2 -Times 1 -Exactly
        (Get-DemoVmState)['steps']['GuestWebView2']['status'] | Should -Be 'Succeeded'

        Invoke-DemoVmStateMachine -Step $plan -Generation 'g2' | Should -Be 'WaitingForArcOnboarding'
        Should -Invoke -CommandName Install-DemoHostGuestWebView2 -Times 1 -Exactly
    }

    It 'accepts only a valid Microsoft Authenticode signature' {
        $file = Join-Path -Path $TestDrive -ChildPath 'installer.exe'
        Set-Content -LiteralPath $file -Value 'not a real installer'
        $microsoft = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        Mock -CommandName Get-DemoHostFileSignature -MockWith { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $microsoft } } }
        Test-DemoHostSignedFile -Path $file -SignerPattern 'O=Microsoft Corporation' | Should -BeTrue
        Mock -CommandName Get-DemoHostFileSignature -MockWith { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        Test-DemoHostSignedFile -Path $file -SignerPattern 'O=Microsoft Corporation' | Should -BeFalse
        Mock -CommandName Get-DemoHostFileSignature -MockWith { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Contoso, O=Contoso' } } }
        Test-DemoHostSignedFile -Path $file -SignerPattern 'O=Microsoft Corporation' | Should -BeFalse
        Test-DemoHostSignedFile -Path (Join-Path -Path $TestDrive -ChildPath 'missing.exe') -SignerPattern 'O=Microsoft Corporation' | Should -BeFalse
    }

    It 'downloads the standalone installer over HTTPS and keeps it only when Microsoft signed it' {
        $context = New-TestHostContext -Mode 'PaygWizard'
        $context.Host.WebView2.Url | Should -Match '^https://'
        $context.Host.WebView2.FileName | Should -Be 'MicrosoftEdgeWebView2RuntimeInstallerX64.exe'
        $media = Join-Path -Path $TestDrive -ChildPath ('media-' + [guid]::NewGuid().ToString('N'))
        Mock -CommandName Get-DemoHostDataPath -MockWith { $media }
        Mock -CommandName Invoke-WebRequest -MockWith { Set-Content -LiteralPath $OutFile -Value 'downloaded' }
        $script:signed = $true
        Mock -CommandName Get-DemoHostFileSignature -MockWith {
            if ($script:signed) { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation' } } }
            else { [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = $null } }
        }

        $path = Save-DemoHostWebView2Installer -Context $context
        $path | Should -Be ('{0}\MicrosoftEdgeWebView2RuntimeInstallerX64.exe' -f $media)
        Should -Invoke -CommandName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://go.microsoft.com/fwlink/?linkid=2124701' }

        # A valid cached copy is reused without a download.
        Save-DemoHostWebView2Installer -Context $context | Out-Null
        Should -Invoke -CommandName Invoke-WebRequest -Times 1 -Exactly

        # A download that isn't validly signed is deleted, and the step fails closed.
        $script:signed = $false
        { Save-DemoHostWebView2Installer -Context $context } | Should -Throw '*not validly signed by Microsoft*'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'copies the verified installer into the guest media folder, then installs it' {
        $context = New-TestHostContext -Mode 'PaygWizard'
        Mock -CommandName Save-DemoHostWebView2Installer -MockWith { 'F:\DbHubDemo\media\MicrosoftEdgeWebView2RuntimeInstallerX64.exe' }
        Mock -CommandName Get-DemoGuestCredential -MockWith {
            $secure = [System.Security.SecureString]::new()
            foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
            [System.Management.Automation.PSCredential]::new('Administrator', $secure)
        }
        Mock -CommandName Get-DemoVmFileSha256 -MockWith { 'd' * 64 }
        Mock -CommandName Copy-DemoGuestFile -MockWith { }
        Mock -CommandName Install-DemoGuestWebView2 -MockWith { }
        Install-DemoHostGuestWebView2 -Context $context
        Should -Invoke -CommandName Copy-DemoGuestFile -Times 1 -Exactly -ParameterFilter { $DestinationPath -eq 'C:\DbHubDemo\media\MicrosoftEdgeWebView2RuntimeInstallerX64.exe' -and $ExpectedSha256 -eq ('d' * 64) }
        Should -Invoke -CommandName Install-DemoGuestWebView2 -Times 1 -Exactly -ParameterFilter { $InstallerPath -eq 'C:\DbHubDemo\media\MicrosoftEdgeWebView2RuntimeInstallerX64.exe' -and $TimeoutMinutes -eq 20 }
    }

    It 'tells the operator to use Azure Login on the Azure extension page' {
        $text = (Get-DemoPaygWizardInstruction -GuestName 'arcsql01' -MediaDrive 'E') -join ' '
        $text | Should -Match 'Use Azure Login'
        $text | Should -Match 'WebView2'
        $text | Should -Match 'Never enter a service principal secret'
        $text | Should -Not -Match 'Do not enter credentials'
    }
}

Describe 'GuestSignInCleanup step' {
    BeforeAll {
        function New-TestSweep {
            # A sweep result (Invoke-DemoSignInSweep) with counts only.
            param([bool] $Pass = $true, [bool] $Cleaned = $false, [int] $Security = 0, [string[]] $Cleared = @())
            $counts = [pscustomobject]@{ userTokens = [int](-not $Pass); otherTokens = 0; filesWithUserData = [int](-not $Pass); eventLogUserTokens = 0; browserCaches = 0; archives = 0; filesUnverified = 0; appTokens = 0; eventLogAppTokens = 0; securityLogTokens = $Security }
            [pscustomobject]@{
                pass = $Pass; cleaned = $Cleaned; found = $counts; remaining = $counts
                actions = [pscustomobject]@{ filesRedacted = 0; filesDeleted = 0; cachesRemoved = 0; brokerEntriesRemoved = 0; eventLogsCleared = $Cleared }
                foundLocations = @([pscustomobject]@{ location = 'SetupLogs' }); foundEventLogs = @()
            }
        }
    }

    It 'runs in every mode, because Arc onboarding uses a token in every mode' {
        foreach ($mode in 'PaygWizard', 'ProductKey', 'Developer') {
            $step = Get-DemoHostStepPlan -Context (New-TestHostContext -Mode $mode) | Where-Object { $_.Name -eq 'GuestSignInCleanup' }
            $step.Contains('When') | Should -BeFalse -Because $mode
        }
    }

    It 'cleans up right after the wizard, before the database steps' {
        $context = New-TestHostContext -Mode 'PaygWizard'
        Set-ReadyHostMock
        $script:arcConnected = $true
        $script:sqlReady = $true
        $script:configured = $false
        $script:seeded = $false
        $script:clean = $false
        Mock -CommandName Test-DemoHostGuestSignInClean -MockWith { $script:clean }
        Mock -CommandName Clear-DemoHostGuestSignIn -MockWith { $script:clean = $true }
        $plan = @(Get-DemoHostStepPlan -Context $context | Where-Object { $_.Name -ne 'WorkloadRunner' })

        Invoke-DemoVmStateMachine -Step $plan -Generation 'g1' | Should -Be 'Ready'
        Should -Invoke -CommandName Clear-DemoHostGuestSignIn -Times 1 -Exactly
        $state = Get-DemoVmState
        $state['steps']['GuestSignInCleanup']['status'] | Should -Be 'Succeeded'
        [datetime]$state['steps']['GuestSignInCleanup']['lastStartedUtc'] | Should -BeLessThan ([datetime]$state['steps']['ConfigureSql']['lastStartedUtc']).AddSeconds(1)
    }

    It 'never throws from its check, so an unreachable guest only means "not clean yet"' {
        $context = New-TestHostContext -Mode 'PaygWizard'
        Mock -CommandName Get-DemoGuestCredential -MockWith { throw 'The guest secret is missing.' }
        Test-DemoHostGuestSignInClean -Context $context | Should -BeFalse
        Mock -CommandName Get-DemoGuestCredential -MockWith {
            $secure = [System.Security.SecureString]::new()
            foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
            [System.Management.Automation.PSCredential]::new('Administrator', $secure)
        }
        Mock -CommandName Invoke-DemoSignInSweep -MockWith { New-TestSweep -Pass $true }
        Mock -CommandName Get-DemoGuestSignInResidue -MockWith { [pscustomobject]@{ Pass = $false; SecurityLogTokens = 0; IeEscEnabled = $true; SetupProcess = @() } }
        Test-DemoHostGuestSignInClean -Context $context | Should -BeFalse
        Mock -CommandName Get-DemoGuestSignInResidue -MockWith { [pscustomobject]@{ Pass = $true; SecurityLogTokens = 0; IeEscEnabled = $false; SetupProcess = @() } }
        Test-DemoHostGuestSignInClean -Context $context | Should -BeFalse
        Mock -CommandName Get-DemoGuestSignInResidue -MockWith { [pscustomobject]@{ Pass = $true; SecurityLogTokens = 0; IeEscEnabled = $true; SetupProcess = @('ScenarioEngine') } }
        Test-DemoHostGuestSignInClean -Context $context | Should -BeFalse -Because 'setup can still write while it runs'
        Mock -CommandName Get-DemoGuestSignInResidue -MockWith { [pscustomobject]@{ Pass = $true; SecurityLogTokens = 1; IeEscEnabled = $true; SetupProcess = @() } }
        Test-DemoHostGuestSignInClean -Context $context | Should -BeFalse -Because 'only an operator clears the Security log'
        Mock -CommandName Get-DemoGuestSignInResidue -MockWith { [pscustomobject]@{ Pass = $true; SecurityLogTokens = 0; IeEscEnabled = $true; SetupProcess = @() } }
        Test-DemoHostGuestSignInClean -Context $context | Should -BeTrue
        Mock -CommandName Invoke-DemoSignInSweep -MockWith { New-TestSweep -Pass $false }
        Test-DemoHostGuestSignInClean -Context $context | Should -BeFalse -Because 'sign-in data on the host counts too'
    }

    It 'waits while setup runs in the guest, then cleans the guest and the host, and fails closed when anything is left' {
        $context = New-TestHostContext -Mode 'PaygWizard'
        Mock -CommandName Get-DemoGuestCredential -MockWith {
            $secure = [System.Security.SecureString]::new()
            foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
            [System.Management.Automation.PSCredential]::new('Administrator', $secure)
        }
        Mock -CommandName Invoke-Command -MockWith { 'ScenarioEngine' }
        Mock -CommandName Clear-DemoGuestSignInResidue -MockWith { throw 'should not run while setup is open' }
        $waiting = Clear-DemoHostGuestSignIn -Context $context
        $waiting.Outcome | Should -Be 'InProgress'
        $waiting.Message | Should -Match 'Close the setup wizard'

        Mock -CommandName Invoke-Command -MockWith { }
        Mock -CommandName Clear-DemoGuestSignInResidue -MockWith { New-TestSweep -Pass $true -Cleaned $true }
        Mock -CommandName Invoke-DemoSignInSweep -MockWith { New-TestSweep -Pass $true -Cleaned $true }
        Clear-DemoHostGuestSignIn -Context $context
        Should -Invoke -CommandName Invoke-DemoSignInSweep -Times 1 -Exactly -ParameterFilter { $Clean }

        Mock -CommandName Invoke-DemoSignInSweep -MockWith { New-TestSweep -Pass $true -Cleaned $true -Cleared @('Windows PowerShell') }
        $warned = Clear-DemoHostGuestSignIn -Context $context
        $warned.Outcome | Should -Be 'Done'
        $warned.WarningMessage[0] | Should -Match 'Windows PowerShell on archost01.*endpoint protection may report'

        Mock -CommandName Invoke-DemoSignInSweep -MockWith { New-TestSweep -Pass $true -Cleaned $true -Security 2 }
        $manual = Clear-DemoHostGuestSignIn -Context $context
        $manual.Outcome | Should -Be 'ManualActionRequired'
        ($manual.Instruction -join ' ') | Should -Match ([regex]::Escape('./scripts/check-sign-in-data.ps1 -VmName archost01 -Clean -ClearSecurityLog'))
        ($manual.Instruction -join ' ') | Should -Match 'wevtutil clear-log Security'

        Mock -CommandName Invoke-DemoSignInSweep -MockWith { New-TestSweep -Pass $false -Cleaned $true }
        { Clear-DemoHostGuestSignIn -Context $context } | Should -Throw '*fail closed*'
    }
}

Describe 'Sign-in residue functions (run in the guest or on the evaluation-only VM)' {
    It 'describes a sweep in counts and location names only' {
        $counts = [pscustomobject]@{ userTokens = 2; otherTokens = 0; filesWithUserData = 1; eventLogUserTokens = 1; browserCaches = 1; archives = 0; filesUnverified = 0; appTokens = 0; eventLogAppTokens = 0; securityLogTokens = 0 }
        $none = [pscustomobject]@{ userTokens = 0; otherTokens = 0; filesWithUserData = 0; eventLogUserTokens = 0; browserCaches = 0; archives = 0; filesUnverified = 0; appTokens = 0; eventLogAppTokens = 0; securityLogTokens = 0 }
        $sweep = [pscustomobject]@{
            pass = $true; cleaned = $true; found = $counts; remaining = $none
            actions = [pscustomobject]@{ filesRedacted = 1; filesDeleted = 0; cachesRemoved = 1; brokerEntriesRemoved = 2; eventLogsCleared = @('Windows PowerShell') }
            foundLocations = @([pscustomobject]@{ location = 'SetupLogs' }, [pscustomobject]@{ location = 'BrowserCache' })
            foundEventLogs = @([pscustomobject]@{ log = 'Windows PowerShell' })
        }
        $text = Format-DemoSignInSweep -Sweep $sweep -Label 'arcsql01'
        $text | Should -Be 'arcsql01: found 2 sign-in token(s) in 1 file(s), 1 in event logs, 1 browser sign-in cache(s) (in SetupLogs, BrowserCache, Windows PowerShell); redacted 1 file(s), deleted 0, removed 3 cache(s), cleared 1 event log(s); left: nothing.'
        Format-DemoSignInSweep -Sweep $null -Label 'This host' | Should -Be 'This host: not checked.'
    }
    It 'checks and turns on IE Enhanced Security Configuration for administrators and users' {
        $script:ieEsc = @{ '{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' = 0; '{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' = 1 }
        Mock -CommandName Get-ItemProperty -MockWith {
            $id = Split-Path -Path $LiteralPath -Leaf
            if ($script:ieEsc.Contains($id)) { [pscustomobject]@{ IsInstalled = $script:ieEsc[$id] } }
        }
        Mock -CommandName Test-Path -ParameterFilter { $LiteralPath -like 'HKLM:*' } -MockWith { $true }
        Mock -CommandName Set-ItemProperty -MockWith { $script:ieEsc[(Split-Path -Path $LiteralPath -Leaf)] = $Value }

        Test-DemoIeEscEnabled | Should -BeFalse
        Enable-DemoIeEsc
        Should -Invoke -CommandName Set-ItemProperty -Times 2 -Exactly -ParameterFilter { $Name -eq 'IsInstalled' -and $Value -eq 1 }
        Test-DemoIeEscEnabled | Should -BeTrue
    }

    It 'treats missing IE ESC components (Server Core) as on' {
        Mock -CommandName Get-ItemProperty -MockWith { }
        Test-DemoIeEscEnabled | Should -BeTrue
    }
}