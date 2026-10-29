BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the host bootstrap's functions, GuestSetup.ps1's included (and imports DbHubDemo.Vm), without
    # running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1')

    function New-TestHostContext {
        $root = Join-Path -Path $TestDrive -ChildPath ('host-' + [guid]::NewGuid().ToString('N'))
        Initialize-DemoVmContext -Root $root -Role 'ArcHost' -BundleRoot $repoRoot | Out-Null
        $settings = [ordered]@{ role = 'ArcHost'; t2SqlInstallMode = 'PaygWizard'; seedScale = 1; guest = [ordered]@{ name = 'arcsql01'; vcpus = 2; memoryGiB = 8; vhdxGB = 64 } }
        Get-DemoHostContext -StateRoot $root -BundleRoot $repoRoot -Settings $settings
    }

    function Write-TestRequest {
        param([System.Collections.IDictionary] $Context, [datetime] $ExpiresUtc)
        $path = Get-DemoGuidedSetupPath -Root $Context.Root
        $request = [ordered]@{ schemaVersion = 1; requestId = 'request-0001'; expiresUtc = $ExpiresUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture); subscriptionId = '11111111-2222-3333-4444-555555555555'; resourceGroup = 'rg-dbhub-demo'; region = 'westus3'; tenantId = '66666666-7777-8888-9999-000000000000' }
        Write-DemoVmJsonFile -Path $path.HostRequest -InputObject $request
    }

    function New-TestCredential {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
        [System.Management.Automation.PSCredential]::new('Administrator', $secure)
    }

    function New-TestAutoLogonState([bool] $On) {
        [pscustomobject]@{ autoAdminLogon = $On; autoLogonCount = $On; defaultUserName = $On; defaultPassword = $false; lsaSecret = $On }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'The guided stop''s setup configuration file (Phase 28, brief item 5)' {
    BeforeAll {
        $sql = @{ Features = 'SQLENGINE'; InstanceName = 'MSSQLSERVER'; ServiceAccount = 'NT Service\MSSQLSERVER'; AgentAccount = 'NT Service\SQLSERVERAGENT'; SysAdminAccounts = 'BUILTIN\Administrators' }
    }

    It 'pre-fills every page documented parameters allow, in the wizard (UIMODE Normal), and holds no secret' {
        $text = Get-DemoGuidedSetupConfigurationText -Sql $sql -Azure @{ SubscriptionId = '11111111-2222-3333-4444-555555555555'; ResourceGroup = 'rg-dbhub-demo'; Region = 'westus3'; TenantId = '66666666-7777-8888-9999-000000000000' }
        $text | Should -Match '(?m)^\[OPTIONS\]\r?$'
        $text | Should -Match '(?m)^ACTION="Install"\r?$'
        $text | Should -Match '(?m)^UIMODE="Normal"\r?$'
        $text | Should -Match '(?m)^FEATURES=SQLENGINE,AZUREEXTENSION\r?$'
        $text | Should -Match '(?m)^INSTANCENAME="MSSQLSERVER"\r?$'
        $text | Should -Match '(?m)^SQLSYSADMINACCOUNTS="BUILTIN\\Administrators"\r?$'
        $text | Should -Match '(?m)^AZURESUBSCRIPTIONID="11111111-2222-3333-4444-555555555555"\r?$'
        $text | Should -Match '(?m)^AZURERESOURCEGROUP="rg-dbhub-demo"\r?$'
        $text | Should -Match '(?m)^AZUREREGION="westus3"\r?$'
        $text | Should -Not -Match '(?im)^\s*(PID|[A-Z]*PASSWORD|AZURESERVICEPRINCIPAL[A-Z]*|IACCEPTSQLSERVERLICENSETERMS|QUIET[A-Z]*)\s*='
    }

    It 'leaves out an Azure value that isn''t valid, and refuses a value the file can''t hold' {
        $text = Get-DemoGuidedSetupConfigurationText -Sql $sql -Azure @{ SubscriptionId = 'not-a-guid'; Region = 'West US 3' }
        $text | Should -Not -Match 'AZURESUBSCRIPTIONID'
        $text | Should -Not -Match 'AZUREREGION'
        $bad = $sql.Clone()
        $bad['InstanceName'] = 'MSSQL"SERVER'
        { Get-DemoGuidedSetupConfigurationText -Sql $bad } | Should -Throw '*can''t hold*'
    }

    It 'opens setup from a launcher that first clears the automatic sign-in that started the session' {
        $path = Get-DemoGuidedSetupPath -Root (Join-Path -Path $TestDrive -ChildPath 'launcher')
        $launcher = Get-DemoGuidedSetupLauncherText -IsoPath 'C:\DbHubDemo\media\SQLServer2022-x64-ENU.iso' -Path $path
        $launcher | Should -Match 'function Invoke-DemoGuestAutoLogonAction'
        $launcher | Should -Match 'Invoke-DemoGuestAutoLogonAction -Action Clear'
        $launcher | Should -Match ([regex]::Escape('/ConfigurationFile='))
        $launcher.IndexOf('Invoke-DemoGuestAutoLogonAction -Action Clear') | Should -BeLessThan $launcher.IndexOf('/ConfigurationFile=')
        { Get-DemoGuidedSetupLauncherText -IsoPath "C:\media\it's.iso" -Path $path } | Should -Throw
    }
}

Describe 'Automatic sign-in: kept only as the LSA secret, and always cleaned up (Phase 28, brief item 12)' {
    It 'arms with the LSA secret and AutoLogonCount 1, never the Winlogon DefaultPassword value' {
        $body = ${function:Invoke-DemoGuestAutoLogonAction}.ToString()
        $body | Should -Match "Store\('DefaultPassword', \`$Password\)"
        $body | Should -Match "Remove-ItemProperty -LiteralPath \`$winlogon -Name 'DefaultPassword'"
        $body | Should -Match "-Name 'AutoLogonCount' -PropertyType DWord -Value 1"
        $body | Should -Not -Match "Set-ItemProperty -LiteralPath \`$winlogon -Name 'DefaultPassword'"
        $body | Should -Match 'LsaStorePrivateData'
    }

    It 'counts automatic sign-in as clear only when nothing is left' {
        Test-DemoAutoLogonClear -State (New-TestAutoLogonState $false) | Should -BeTrue
        Test-DemoAutoLogonClear -State $null | Should -BeFalse
        foreach ($name in 'autoAdminLogon', 'autoLogonCount', 'defaultUserName', 'defaultPassword', 'lsaSecret') {
            $state = New-TestAutoLogonState $false
            $state.$name = $true
            Test-DemoAutoLogonClear -State $state | Should -BeFalse -Because $name
        }
    }

    Context 'the cleanup' {
        BeforeEach {
            $context = New-TestHostContext
            $script:path = Get-DemoGuidedSetupPath -Root $context.Root
            Save-DemoGuidedSetupArmed -Path $script:path -Value @{ schemaVersion = 1; requestId = 'request-0001'; arms = 1; armedUtc = '2026-10-29T15:00:00Z'; okSinceUtc = ''; lastLaunchUtc = '' }
            $script:order = [System.Collections.Generic.List[string]]::new()
            $script:after = New-TestAutoLogonState $false
            Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
            Mock -CommandName Invoke-DemoGuestSignOut -MockWith { $script:order.Add('signout'); 1 }
            Mock -CommandName Start-Sleep -MockWith { }
            Mock -CommandName Invoke-Command -MockWith {
                $action = @($ArgumentList)[0]
                $script:order.Add([string]$action)
                [pscustomobject]@{ action = $action; before = (New-TestAutoLogonState $true); after = $script:after }
            }
            Mock -CommandName Update-DemoGuestSecret -MockWith { $script:order.Add('rotate') }
        }

        It 'signs out, turns it off and deletes the secret and the values, rotates the password, checks, and drops the record' {
            Disable-DemoHostGuestAutoLogon -Context $context -Reason 'Installed'
            $script:order | Should -Be @('signout', 'Clear', 'rotate', 'Read')
            Test-Path -LiteralPath $script:path.HostArmed | Should -BeFalse
            $last = Read-DemoVmJsonFile -Path $script:path.HostLast
            $last['reason'] | Should -Be 'Installed'
            @($last['found']) | Should -Contain 'lsaSecret'
            @($last['problems']).Count | Should -Be 0
        }

        It 'runs on a failure or a timeout too, and fails closed, keeping the record, when anything is left' {
            foreach ($reason in 'Expired', 'NoRequest') {
                Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 1 }
                Disable-DemoHostGuestAutoLogon -Context $context -Reason $reason
                (Read-DemoVmJsonFile -Path $script:path.HostLast)['reason'] | Should -Be $reason
            }
            Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 1 }
            $script:after = New-TestAutoLogonState $true
            { Disable-DemoHostGuestAutoLogon -Context $context -Reason 'Expired' } | Should -Throw '*fail closed*'
            Test-Path -LiteralPath $script:path.HostArmed | Should -BeTrue -Because 'the next pass cleans up again'
            Mock -CommandName Update-DemoGuestSecret -MockWith { throw 'the guest is off' }
            $script:after = New-TestAutoLogonState $false
            { Disable-DemoHostGuestAutoLogon -Context $context -Reason 'Retry' } | Should -Throw '*rotating the guest password*'
            Test-Path -LiteralPath $script:path.HostArmed | Should -BeTrue
        }

        It 'runs before every pass of the host when nobody is expected any more, and never while deploy.ps1 waits' {
            Mock -CommandName Disable-DemoHostGuestAutoLogon -MockWith { $script:order.Add('disable ' + $Reason) }
            Mock -CommandName Resolve-DemoGuestPendingSecret -MockWith { }
            Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(30))
            Invoke-DemoHostGuidedSetupGuard -Context $context
            $script:order | Should -Not -Contain 'disable Expired'
            Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(-1))
            Invoke-DemoHostGuidedSetupGuard -Context $context
            $script:order | Should -Contain 'disable Expired'
            Remove-Item -LiteralPath $script:path.HostRequest
            Invoke-DemoHostGuidedSetupGuard -Context $context
            $script:order | Should -Contain 'disable NoRequest'
        }
    }
}

Describe 'The SqlSetupWizard step with the guided stop (Phase 28, brief items 5 and 6)' {
    BeforeEach {
        $context = New-TestHostContext
        $script:path = Get-DemoGuidedSetupPath -Root $context.Root
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:check = [pscustomobject]@{ Ok = $false; Problem = 'NotInstalled'; SetupRunning = $false; Message = 'SQL Server isn''t installed in arcsql01 yet.'; Fix = @() }
        $script:session = $false
        Mock -CommandName Get-DemoHostSetupCheck -MockWith { $script:check }
        Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
        Mock -CommandName Test-DemoGuestConsoleSession -MockWith { $script:session }
        Mock -CommandName Invoke-Command -MockWith { $script:calls.Add('start setup') }
        Mock -CommandName Enable-DemoHostGuestAutoLogon -MockWith { $script:calls.Add(('arm {0}' -f $Arms)); Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = $RequestId; arms = $Arms } }
        Mock -CommandName Disable-DemoHostGuestAutoLogon -MockWith { $script:calls.Add('disable ' + $Reason); Remove-Item -LiteralPath $script:path.HostArmed -ErrorAction SilentlyContinue }
        Mock -CommandName Remove-DemoHostGuidedSetup -MockWith { $script:calls.Add('remove tasks') }
    }

    It 'waits for deploy.ps1 when no person is expected, and tells the person to run it' {
        $result = Invoke-DemoHostGuidedSetupStep -Context $context
        $result.Outcome | Should -Be 'ManualActionRequired'
        $result.Message | Should -Match 'run \./scripts/deploy\.ps1'
        $script:calls.Count | Should -Be 0
    }

    It 'arms one automatic sign-in while deploy.ps1 waits, retries a few times, then gives the manual way' {
        Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(45))
        (Invoke-DemoHostGuidedSetupStep -Context $context).Message | Should -Match 'signs itself in once'
        $script:calls | Should -Be @('arm 1')
        Invoke-DemoHostGuidedSetupStep -Context $context | Out-Null
        $script:calls | Should -Be @('arm 1', 'disable Retry', 'arm 2')
        Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 3 }
        $manual = Invoke-DemoHostGuidedSetupStep -Context $context
        $manual.Message | Should -Match 'Copy-GuestCredential\.ps1'
        $script:calls[-1] | Should -Be 'arm 2' -Because 'it never arms more than three times'
    }

    It 'opens setup in a session that''s already signed in, without arming anything' {
        Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(45))
        $script:session = $true
        (Invoke-DemoHostGuidedSetupStep -Context $context).Message | Should -Match 'setup opens there now'
        $script:calls | Should -Be @('start setup')
    }

    It 'shows the documented fix for a wrong install and keeps waiting, without onboarding it' {
        Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(45))
        $script:session = $true
        $script:check = [pscustomobject]@{ Ok = $false; Problem = 'Edition'; SetupRunning = $false; Message = 'SQL Server in arcsql01 is Developer Edition (64-bit); the demo needs Standard with pay-as-you-go.'; Fix = @('Select Maintenance > Edition Upgrade.') }
        $result = Invoke-DemoHostGuidedSetupStep -Context $context
        $result.Outcome | Should -Be 'ManualActionRequired'
        $result.Message | Should -Match 'Fix: Select Maintenance > Edition Upgrade'
    }

    It 'cleans up once the right instance is installed, after setup closes' {
        Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(45))
        Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 1 }
        $script:check = [pscustomobject]@{ Ok = $true; Problem = ''; SetupRunning = $false; Message = 'SQL Server Standard runs in arcsql01 as the default instance, with the Azure extension.'; Fix = @() }
        Invoke-DemoHostGuidedSetupStep -Context $context
        $script:calls | Should -Be @('disable Installed', 'remove tasks')
    }

}

Describe 'The host''s setup check (Get-DemoHostSetupCheck, brief item 6)' {
    It 'reads a wrong install from the guest: Developer edition, a named instance, or no Azure extension' {
        $context = New-TestHostContext
        Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
        Mock -CommandName Get-DemoGuestSetupFact -MockWith { [pscustomobject]@{ DefaultInstance = $script:default; NamedInstances = $script:named; SetupProcess = @(); Features = $script:features } }
        Mock -CommandName Get-DemoGuestSqlInstance -MockWith { [pscustomobject]@{ Running = $true; Edition = $script:edition; IsSysAdmin = $true; Error = '' } }
        $script:default = $true; $script:named = @(); $script:features = 'SQLENGINE,AZUREEXTENSION'; $script:edition = 'Developer Edition (64-bit)'
        $check = Get-DemoHostSetupCheck -Context $context
        $check.Problem | Should -Be 'Edition'
        ($check.Fix -join ' ') | Should -Match 'Edition Upgrade'
        $script:default = $false; $script:named = @('SQLEXPRESS')
        (Get-DemoHostSetupCheck -Context $context).Problem | Should -Be 'NamedInstance'
        $script:default = $true; $script:named = @(); $script:features = 'SQLENGINE'; $script:edition = 'Standard Edition (64-bit)'
        (Get-DemoHostSetupCheck -Context $context).Problem | Should -Be 'NoAzureExtension'
        $script:features = 'SQLENGINE,AZUREEXTENSION'
        (Get-DemoHostSetupCheck -Context $context).Ok | Should -BeTrue
    }
}

Describe 'deploy.ps1''s request on the host (vm/bootstrap/Set-DemoGuidedSetupRequest.ps1)' {
    It 'holds identifiers and an expiry, never a secret' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Set-DemoGuidedSetupRequest.ps1') -Raw
        $text | Should -Match 'param\('
        $text | Should -Not -Match '(?i)\[(string|securestring)\]\s*\$(Password|Secret|Token|ProductKey)'
        $text | Should -Match 'ExpiresUtc'
    }
}
